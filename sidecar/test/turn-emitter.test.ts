// Unit tests for TurnEmitter — the seam that owns turn-scoped `ui.*` wire
// emission and the dual-write invariant (conversation mutation applied ⇒
// notify fires; mutation is a no-op on an unknown/reset turn ⇒ notify must
// NOT fire). See src/agent/turn/emitter.ts for the design rationale.

import { expect, test } from "bun:test";
import { Conversation } from "../src/agent/conversation";
import { TurnEmitter, type WireSink } from "../src/agent/turn/emitter";
import { RPCMethod } from "../src/rpc/rpc-types";

interface CapturedNotify {
	method: string;
	params: object;
}

function fakeSink(): { sink: WireSink; notifications: CapturedNotify[] } {
	const notifications: CapturedNotify[] = [];
	return {
		notifications,
		sink: {
			notify(method: string, params: object): void {
				notifications.push({ method, params });
			},
			async request<R>(): Promise<R> {
				throw new Error("unexpected request() call in TurnEmitter test");
			},
		},
	};
}

function makeTurn(convo: Conversation): string {
	const turnId = `T_${crypto.randomUUID()}`;
	convo.startTurn({ id: turnId, prompt: "hello", citedContext: {} });
	return turnId;
}

test("token: dual-write fires ui.token only when appendDelta applies", () => {
	const convo = new Conversation();
	const turnId = makeTurn(convo);
	const { sink, notifications } = fakeSink();
	const sessionId = `sess_${crypto.randomUUID()}`;
	const emitter = new TurnEmitter({ sink, sessionId, conversation: convo });

	const applied = emitter.token(turnId, "hi");

	expect(applied).toBe(true);
	expect(notifications).toEqual([
		{ method: RPCMethod.uiToken, params: { sessionId, turnId, delta: "hi" } },
	]);
	expect(convo.turns.find((t) => t.id === turnId)?.reply).toBe("hi");
});

test("token: unknown turnId (post-reset/cancel race) applies nothing and does not notify", () => {
	const convo = new Conversation();
	const turnId = makeTurn(convo);
	convo.reset(); // simulates agent.reset firing before a stray stream event lands
	const { sink, notifications } = fakeSink();
	const emitter = new TurnEmitter({
		sink,
		sessionId: `sess_${crypto.randomUUID()}`,
		conversation: convo,
	});

	const applied = emitter.token(turnId, "late delta");

	expect(applied).toBe(false);
	expect(notifications).toEqual([]);
});

test("error: dual-write fires ui.error only when setError applies", () => {
	const convo = new Conversation();
	const turnId = makeTurn(convo);
	const { sink, notifications } = fakeSink();
	const sessionId = `sess_${crypto.randomUUID()}`;
	const emitter = new TurnEmitter({ sink, sessionId, conversation: convo });

	const applied = emitter.error(turnId, 12345, "boom");

	expect(applied).toBe(true);
	expect(notifications).toEqual([
		{
			method: RPCMethod.uiError,
			params: { sessionId, turnId, code: 12345, message: "boom" },
		},
	]);
	const turn = convo.turns.find((t) => t.id === turnId);
	expect(turn?.status).toBe("error");
	expect(turn?.errorCode).toBe(12345);
	expect(turn?.errorMessage).toBe("boom");
});

test("error: gated by conversation mutation on an unknown turn", () => {
	const convo = new Conversation();
	const { sink, notifications } = fakeSink();
	const emitter = new TurnEmitter({
		sink,
		sessionId: `sess_${crypto.randomUUID()}`,
		conversation: convo,
	});

	const applied = emitter.error(`T_${crypto.randomUUID()}`, 1, "boom");

	expect(applied).toBe(false);
	expect(notifications).toEqual([]);
});

test("thinking: delta opens the block, closeThinkingIfOpen closes exactly once", () => {
	const convo = new Conversation();
	const turnId = makeTurn(convo);
	const { sink, notifications } = fakeSink();
	const sessionId = `sess_${crypto.randomUUID()}`;
	const emitter = new TurnEmitter({ sink, sessionId, conversation: convo });

	emitter.thinkingDelta(turnId, "reasoning...");
	emitter.closeThinkingIfOpen(turnId);
	// Idempotent: calling again without a new delta must NOT emit a second
	// "end" frame — several round.ts exit paths (error, cancel, tool-budget)
	// all call this defensively on the same turn.
	emitter.closeThinkingIfOpen(turnId);

	expect(notifications).toEqual([
		{
			method: RPCMethod.uiThinking,
			params: { sessionId, turnId, kind: "delta", delta: "reasoning..." },
		},
		{
			method: RPCMethod.uiThinking,
			params: { sessionId, turnId, kind: "end" },
		},
	]);
});

test("thinking: closeThinkingIfOpen without a preceding delta is a no-op", () => {
	const convo = new Conversation();
	const turnId = makeTurn(convo);
	const { sink, notifications } = fakeSink();
	const emitter = new TurnEmitter({
		sink,
		sessionId: `sess_${crypto.randomUUID()}`,
		conversation: convo,
	});

	emitter.closeThinkingIfOpen(turnId);

	expect(notifications).toEqual([]);
});

test("status: plain notify carries no conversation mutation", () => {
	const convo = new Conversation();
	const turnId = makeTurn(convo);
	const { sink, notifications } = fakeSink();
	const sessionId = `sess_${crypto.randomUUID()}`;
	const emitter = new TurnEmitter({ sink, sessionId, conversation: convo });

	emitter.status(turnId, "awaitingPermission");

	expect(notifications).toEqual([
		{
			method: RPCMethod.uiStatus,
			params: { sessionId, turnId, status: "awaitingPermission" },
		},
	]);
	// setStatus was never called — the turn's durable status is untouched.
	expect(convo.turns.find((t) => t.id === turnId)?.status).toBe("working");
});

test("statusPersisted: folds conversation.setStatus + notify into one call", () => {
	const convo = new Conversation();
	const turnId = makeTurn(convo);
	const { sink, notifications } = fakeSink();
	const sessionId = `sess_${crypto.randomUUID()}`;
	const emitter = new TurnEmitter({ sink, sessionId, conversation: convo });

	emitter.statusPersisted(turnId, "waiting");

	expect(convo.turns.find((t) => t.id === turnId)?.status).toBe("waiting");
	expect(notifications).toEqual([
		{
			method: RPCMethod.uiStatus,
			params: { sessionId, turnId, status: "waiting" },
		},
	]);
});

test("toolCall: forwards the discriminated frame with sessionId/turnId attached", () => {
	const convo = new Conversation();
	const turnId = makeTurn(convo);
	const { sink, notifications } = fakeSink();
	const sessionId = `sess_${crypto.randomUUID()}`;
	const emitter = new TurnEmitter({ sink, sessionId, conversation: convo });
	const toolCallId = `tc_${crypto.randomUUID()}`;

	emitter.toolCall(turnId, {
		phase: "called",
		toolCallId,
		toolName: "read_file",
		args: { path: "/tmp/x" },
	});

	expect(notifications).toEqual([
		{
			method: RPCMethod.uiToolCall,
			params: {
				sessionId,
				turnId,
				phase: "called",
				toolCallId,
				toolName: "read_file",
				args: { path: "/tmp/x" },
			},
		},
	]);
});

test("usage: projects final assistant message usage + model onto the wire shape", () => {
	const convo = new Conversation();
	const turnId = makeTurn(convo);
	const { sink, notifications } = fakeSink();
	const sessionId = `sess_${crypto.randomUUID()}`;
	const emitter = new TurnEmitter({ sink, sessionId, conversation: convo });

	emitter.usage(
		turnId,
		{
			role: "assistant",
			content: [],
			api: "openai-responses",
			provider: "test",
			model: "fake-model",
			usage: {
				input: 10,
				output: 20,
				cacheRead: 1,
				cacheWrite: 2,
				totalTokens: 33,
				cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
			},
			stopReason: "stop",
			timestamp: Date.now(),
		} as any,
		{ id: "fake-model", contextWindow: 100_000 } as any,
	);

	expect(notifications).toEqual([
		{
			method: RPCMethod.uiUsage,
			params: {
				sessionId,
				turnId,
				inputTokens: 10,
				outputTokens: 20,
				cacheReadTokens: 1,
				cacheWriteTokens: 2,
				totalTokens: 33,
				contextWindow: 100_000,
				modelId: "fake-model",
			},
		},
	]);
});

test("compact: forwards phase + optional extras", () => {
	const convo = new Conversation();
	const turnId = makeTurn(convo);
	const { sink, notifications } = fakeSink();
	const sessionId = `sess_${crypto.randomUUID()}`;
	const emitter = new TurnEmitter({ sink, sessionId, conversation: convo });

	emitter.compact(turnId, "started");
	emitter.compact(turnId, "done", { compactedTurnCount: 3 });
	emitter.compact(turnId, "failed", { errorMessage: "boom" });

	expect(notifications).toEqual([
		{
			method: RPCMethod.uiCompact,
			params: { sessionId, turnId, phase: "started" },
		},
		{
			method: RPCMethod.uiCompact,
			params: { sessionId, turnId, phase: "done", compactedTurnCount: 3 },
		},
		{
			method: RPCMethod.uiCompact,
			params: { sessionId, turnId, phase: "failed", errorMessage: "boom" },
		},
	]);
});

test("todo: session-scoped, carries no turnId", () => {
	const convo = new Conversation();
	const { sink, notifications } = fakeSink();
	const sessionId = `sess_${crypto.randomUUID()}`;
	const emitter = new TurnEmitter({ sink, sessionId, conversation: convo });
	const items = [{ id: "1", text: "do a thing", status: "pending" as const }];

	emitter.todo(items);

	expect(notifications).toEqual([
		{ method: RPCMethod.uiTodo, params: { sessionId, items } },
	]);
});
