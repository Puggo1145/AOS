import { test, expect } from "bun:test";
import { z } from "zod";
import { Session } from "../src/agent/session/session";
import {
	finishToolRuntimeAfterTerminalAssistantReply,
	runTool,
	toolDispatchContext,
	toolRuntimeEffects,
} from "../src/agent/turn/tool-dispatch";
import { RPCMethod } from "../src/rpc/rpc-types";
import { defineTool } from "../src/agent/tools/core/schema";
import type { ToolHandler } from "../src/agent/tools";
import type { Dispatcher } from "../src/rpc/dispatcher";

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
