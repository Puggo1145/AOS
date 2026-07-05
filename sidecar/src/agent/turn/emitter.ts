// TurnEmitter — the single seam between Agent Turn execution and the
// turn-scoped `ui.*` wire frames.
//
// Why this exists: before this seam, `runTurn` / `AgentRoundRunner` /
// `tool-dispatch` each called `dispatcher.notify(RPCMethod.ui*, {sessionId,
// turnId, ...})` inline, and every mutation that has a matching wire frame
// (setError → ui.error, appendDelta → ui.token, ...) hand-repeated the same
// "only notify if the mutation actually applied" guard. Centralizing both
// concerns here means:
//   - the dual-write invariant (see below) is enforced in ONE place instead
//     of ~10 call sites that could silently drift out of sync;
//   - the thinking-open/close bookkeeping (pure wire-protocol state — the
//     Shell needs an explicit "end" frame to close a reasoning block) lives
//     next to the frames it toggles instead of on the round runner;
//   - adding/renaming a `ui.*` frame touches one file.
//
// Dual-write invariant (moved from the old inline comments in loop.ts /
// round.ts): `Conversation` mutators return `boolean` — false means the
// `turnId` is unknown, which happens after `agent.reset` or `agent.cancel`
// race the in-flight stream (one more stream event can land between the
// abort signal firing and the loop's next `signal.aborted` check). When a
// mutator returns false, the matching `ui.*` notify MUST NOT fire — the
// Shell has already dropped its mirror of that turn.
//
// turnId is passed explicitly on every call (not captured at construction)
// because a steer prompt activating mid-`runTurn` changes which turnId is
// "active" partway through — sessionId does not change, turnId does.

import type { Api, AssistantMessage, Model } from "../../llm";
import {
	RPCMethod,
	type JSONValue,
	type UICompactPhase,
	type UIStatus,
	type TodoItemWire,
} from "../../rpc/rpc-types";
import type { Conversation } from "../conversation";

/// Structural subset of `Dispatcher` this module depends on. The concrete
/// `rpc/dispatcher.ts` `Dispatcher` class satisfies this shape already — kept
/// as its own interface (mirroring `permissions/gateway.ts`'s
/// `ApprovalDispatcher`) so tests can construct a bare fake without pulling in
/// the real transport/dispatcher machinery.
export interface WireSink {
	notify(method: string, params: object): void;
	request<R>(
		method: string,
		params: object,
		opts?: { signal?: AbortSignal; timeoutMs?: number },
	): Promise<R>;
}

/// Discriminated `ui.toolCall` payload, sessionId/turnId stripped (the
/// emitter supplies both). Mirrors `UIToolCallParams` in `rpc-types.ts`.
export type TurnToolCallFrame =
	| { phase: "called"; toolCallId: string; toolName: string; args: JSONValue }
	| {
			phase: "result";
			toolCallId: string;
			toolName: string;
			isError: boolean;
			outputText: string;
	  }
	| {
			phase: "rejected";
			toolCallId: string;
			toolName: string;
			args: JSONValue;
			errorMessage: string;
	  }
	| {
			phase: "permissionDenied";
			toolCallId: string;
			toolName: string;
			args: JSONValue;
			errorMessage: string;
	  };

export interface TurnEmitterOptions {
	sink: WireSink;
	sessionId: string;
	conversation: Conversation;
}

export class TurnEmitter {
	/// Whether a `ui.thinking` "delta" block is currently open without a
	/// matching "end" yet. Purely wire-protocol bookkeeping — the Shell
	/// renders a live reasoning block between delta/end and needs an explicit
	/// close even when the round terminates via error/cancel/budget-exceeded
	/// rather than a clean `thinking_end` stream event.
	private thinkingOpen = false;

	constructor(private readonly opts: TurnEmitterOptions) {}

	/// Plain `ui.status` notify — no conversation mutation accompanies this
	/// status change (e.g. the initial "working", "done" after a steer
	/// activation, "awaitingPermission" during a permission prompt).
	status(turnId: string, status: UIStatus): void {
		this.opts.sink.notify(RPCMethod.uiStatus, {
			sessionId: this.opts.sessionId,
			turnId,
			status,
		});
	}

	/// Fold `conversation.setStatus` + the matching `ui.status` notify into one
	/// call for the two spots that today do both back-to-back with the same
	/// value: the "waiting" transition before tool execution, and
	/// `resumeWorking` after a tool round completes. Unlike `error`/`token`,
	/// `setStatus` cannot fail on the current turn (the caller already holds a
	/// live turnId at these two call sites), so there is no boolean to gate
	/// on — this always notifies. Narrowed to the two statuses both call
	/// sites actually use — `TurnStatus` (Conversation-internal) and
	/// `UIStatus` (wire) are different enums and only partially overlap.
	statusPersisted(turnId: string, status: "working" | "waiting"): void {
		this.opts.conversation.setStatus(turnId, status);
		this.status(turnId, status);
	}

	/// Dual-write: `conversation.setError` + `ui.error`. Returns whether the
	/// mutation (and therefore the notify) applied, so callers that need to
	/// chain an additional non-turn-scoped notify (e.g.
	/// `provider.statusChanged` on an auth-invalidated error) can gate on it.
	error(turnId: string, code: number, message: string): boolean {
		if (!this.opts.conversation.setError(turnId, code, message)) return false;
		this.opts.sink.notify(RPCMethod.uiError, {
			sessionId: this.opts.sessionId,
			turnId,
			code,
			message,
		});
		return true;
	}

	/// Dual-write: `conversation.appendDelta` + `ui.token`. `ui.token` is the
	/// cheap per-character streaming transport; the Conversation mirror is the
	/// durable store the next LLM request reads from.
	token(turnId: string, delta: string): boolean {
		if (!this.opts.conversation.appendDelta(turnId, delta)) return false;
		this.opts.sink.notify(RPCMethod.uiToken, {
			sessionId: this.opts.sessionId,
			turnId,
			delta,
		});
		return true;
	}

	/// Open (or keep open) a `ui.thinking` reasoning block and stream a delta.
	thinkingDelta(turnId: string, delta: string): void {
		this.thinkingOpen = true;
		this.opts.sink.notify(RPCMethod.uiThinking, {
			sessionId: this.opts.sessionId,
			turnId,
			kind: "delta",
			delta,
		});
	}

	/// Idempotent close: emits `ui.thinking end` only if a block is actually
	/// open. Safe to call from every terminal round exit (clean stop, error,
	/// cancel, tool-budget exceeded) without double-closing.
	closeThinkingIfOpen(turnId: string): void {
		if (!this.thinkingOpen) return;
		this.thinkingOpen = false;
		this.opts.sink.notify(RPCMethod.uiThinking, {
			sessionId: this.opts.sessionId,
			turnId,
			kind: "end",
		});
	}

	/// `ui.toolCall` lifecycle frame — called/result/rejected/permissionDenied.
	toolCall(turnId: string, frame: TurnToolCallFrame): void {
		this.opts.sink.notify(RPCMethod.uiToolCall, {
			sessionId: this.opts.sessionId,
			turnId,
			...frame,
		});
	}

	/// Token-usage snapshot emitted once per completed LLM round.
	usage(turnId: string, final: AssistantMessage, model: Model<Api>): void {
		this.opts.sink.notify(RPCMethod.uiUsage, {
			sessionId: this.opts.sessionId,
			turnId,
			inputTokens: final.usage.input,
			outputTokens: final.usage.output,
			cacheReadTokens: final.usage.cacheRead,
			cacheWriteTokens: final.usage.cacheWrite,
			totalTokens: final.usage.totalTokens,
			contextWindow: model.contextWindow,
			modelId: model.id,
		});
	}

	/// `ui.compact` lifecycle frame — started/done/failed, for both the
	/// auto-compact path (inside `runTurn`) and the manual `/compact` RPC.
	compact(
		turnId: string,
		phase: UICompactPhase,
		extras?: { compactedTurnCount?: number; errorMessage?: string },
	): void {
		this.opts.sink.notify(RPCMethod.uiCompact, {
			sessionId: this.opts.sessionId,
			turnId,
			phase,
			...extras,
		});
	}

	/// `ui.todo` — session-scoped (no turnId), projects the TodoWrite plan.
	todo(items: TodoItemWire[]): void {
		this.opts.sink.notify(RPCMethod.uiTodo, {
			sessionId: this.opts.sessionId,
			items,
		});
	}
}
