import { test, expect } from "bun:test";
import { z } from "zod";
import { Session } from "../src/agent/session/session";
import { Conversation } from "../src/agent/conversation";
import {
	executeToolCalls,
	finishToolRuntimeAfterTerminalAssistantReply,
	runTool,
	toolDispatchContext,
	toolRuntimeEffects,
	type ToolCallOutcome,
} from "../src/agent/turn/tool-dispatch";
import { TurnEmitter, type WireSink } from "../src/agent/turn/emitter";
import { RPCMethod } from "../src/rpc/rpc-types";
import { defineTool } from "../src/agent/tools/core/schema";
import type { ToolHandler } from "../src/agent/tools";
import type { Dispatcher } from "../src/rpc/dispatcher";
import type {
	PermissionAuthorizeInput,
	PermissionAuthorizeResult,
	PermissionAuthorizer,
} from "../src/agent/permissions";
import type { ToolCall } from "../src/llm";

function fakeModel(): any {
	return {
		api: "openai-responses",
		provider: "fake",
		id: "fake",
		name: "fake",
		input: ["text"],
		contextWindow: 1000,
		maxOutputTokens: 100,
	};
}

test("terminal tool runtime cleanup is not cancelled by the completed turn signal", async () => {
	const session = new Session({ id: "session-1", createdAt: 0, title: "Test" });
	session.setComputerUseAppSession({ pid: 123, windowId: 456 });
	const controller = new AbortController();
	controller.abort();
	const calls: { method: string; params: object; options: unknown }[] = [];
	const dispatcher = {
		request: async (method: string, params: object, options?: unknown) => {
			calls.push({ method, params, options });
			return { stopped: true };
		},
	} as unknown as Dispatcher;

	await finishToolRuntimeAfterTerminalAssistantReply({
		dispatcher,
		session,
		signal: controller.signal,
	} as any);

	expect(calls).toEqual([
		{
			method: RPCMethod.computerUseStopAppSession,
			params: { pid: 123 },
			options: undefined,
		},
	]);
	expect(session.computerUseAppSession).toBeUndefined();
});

test("tool execution context exposes Computer Use state without mutation authority", async () => {
	const session = new Session({ id: "session-1", createdAt: 0, title: "Test" });
	session.setComputerUseAppSession({ pid: 123, windowId: 456 });
	const handler: ToolHandler = defineTool({
		name: "inspect_context",
		description: "inspect context",
		parameters: z.object({}).strict(),
		execute: async (_args, ctx) => {
			const computerUse = ctx.computerUse as any;
			expect(computerUse.appSession).toEqual({ pid: 123, windowId: 456 });
			expect(computerUse.setAppSession).toBeUndefined();
			expect(computerUse.clearAppSession).toBeUndefined();
			return { content: [{ type: "text", text: "ok" }], isError: false };
		},
	});

	const result = await runTool(
		handler,
		{},
		"inspect_context",
		toolDispatchContext({
			session,
			turnId: "turn-1",
			toolCallId: "tool-1",
			model: fakeModel(),
			signal: new AbortController().signal,
		}),
		toolRuntimeEffects(session),
	);

	expect(result.isError).toBe(false);
	expect(session.computerUseAppSession).toEqual({ pid: 123, windowId: 456 });
});

function fakeSink(): WireSink & {
	notifications: { method: string; params: object }[];
} {
	const notifications: { method: string; params: object }[] = [];
	return {
		notifications,
		notify: (method, params) => {
			notifications.push({ method, params });
		},
		request: async () => {
			throw new Error("not used in this test");
		},
	};
}

test("executeToolCalls: a denied call does not run the handler and skips the result frame", async () => {
	const session = new Session({ id: "session-1", createdAt: 0, title: "Test" });
	const conversation = new Conversation();
	conversation.startTurn({ id: "turn-1", prompt: "go", citedContext: {} });
	const sink = fakeSink();
	const emitter = new TurnEmitter({
		sink,
		sessionId: session.id,
		conversation,
	});

	let executed = false;
	const handler: ToolHandler = defineTool({
		name: "write",
		description: "write",
		parameters: z.object({}).strict(),
		execute: async () => {
			executed = true;
			return { content: [{ type: "text", text: "wrote" }], isError: false };
		},
	});

	const permissionGateway: PermissionAuthorizer = {
		async authorize(
			_input: PermissionAuthorizeInput,
		): Promise<PermissionAuthorizeResult> {
			return { kind: "denied", isError: false, message: "denied by policy" };
		},
		clearTurnGrants() {},
	};

	const tc: ToolCall = {
		type: "toolCall",
		id: "tc_1",
		name: "write",
		arguments: {},
	};
	const callOutcomes = new Map<string, ToolCallOutcome>([
		["tc_1", { kind: "ready", args: {}, handler }],
	]);

	const outcome = await executeToolCalls({
		session,
		turnId: "turn-1",
		signal: new AbortController().signal,
		toolCalls: [tc],
		callOutcomes,
		permissionGateway,
		emitter,
		conversation,
		model: fakeModel(),
	});

	expect(outcome).toEqual({ kind: "completed" });
	expect(executed).toBe(false);
	expect(sink.notifications).toEqual([
		{
			method: RPCMethod.uiToolCall,
			params: {
				sessionId: session.id,
				turnId: "turn-1",
				phase: "permissionDenied",
				toolCallId: "tc_1",
				toolName: "write",
				args: {},
				errorMessage: "denied by policy",
			},
		},
	]);
	const toolResult = conversation.messages.find(
		(m) => m.role === "toolResult" && m.toolCallId === "tc_1",
	);
	expect(toolResult).toMatchObject({ isError: false });
});

test("executeToolCalls: appendToolResult returning false (turn raced away) reports turnGone", async () => {
	const session = new Session({ id: "session-1", createdAt: 0, title: "Test" });
	// No turn started — appendToolResult will find nothing and return false,
	// mirroring the `agent.reset`/`agent.cancel` race this return kind exists for.
	const conversation = new Conversation();
	const sink = fakeSink();
	const emitter = new TurnEmitter({
		sink,
		sessionId: session.id,
		conversation,
	});

	const tc: ToolCall = {
		type: "toolCall",
		id: "tc_gone",
		name: "unknown_tool",
		arguments: {},
	};
	const callOutcomes = new Map<string, ToolCallOutcome>([
		["tc_gone", { kind: "rejected", errorMessage: "unused" }],
	]);
	const permissionGateway: PermissionAuthorizer = {
		async authorize(): Promise<PermissionAuthorizeResult> {
			throw new Error("must not be called for a rejected outcome");
		},
		clearTurnGrants() {},
	};

	const outcome = await executeToolCalls({
		session,
		turnId: "turn-gone",
		signal: new AbortController().signal,
		toolCalls: [tc],
		callOutcomes,
		permissionGateway,
		emitter,
		conversation,
		model: fakeModel(),
	});

	expect(outcome).toEqual({ kind: "turnGone" });
});
