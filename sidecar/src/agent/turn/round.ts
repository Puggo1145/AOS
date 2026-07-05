// Agent Turn round execution.
//
// `runTurn` owns the outer Agent Turn lifecycle: submit/compact/steer/final
// cleanup. This module owns one model round inside that lifecycle: prompt
// assembly, stream event application, tool replayability, and the matching
// wire projection.

import {
	streamSimple,
	isContextOverflow,
	type Api,
	type AssistantMessage,
	type AssistantMessageEvent,
	type Message,
	type Model,
	type Tool,
	type ToolCall,
	type ToolResultMessage,
} from "../../llm";
import type { Dispatcher } from "../../rpc/dispatcher";
import { RPCErrorCode, RPCMethod, type JSONValue } from "../../rpc/rpc-types";
import type { Conversation } from "../conversation";
import type { ContextObserver } from "../context-observer";
import type { PermissionAuthorizer } from "../permissions";
import type { Session } from "../session/session";
import type { ToolHandler } from "../tools";
import type { TurnEmitter } from "./emitter";
import { buildOutboundMessages, publishTurnContext } from "./outbound";
import {
	assistantSpoke,
	executeToolCalls,
	extractToolCalls,
	finishToolRuntimeAfterTerminalAssistantReply,
	prepareToolCall,
	type ToolCallOutcome,
} from "./tool-dispatch";

export type AgentRoundOutcome =
	| { kind: "continue"; consecutiveSilentToolRounds: number }
	| { kind: "done"; markedDone: boolean; consecutiveSilentToolRounds: number }
	| {
			kind: "terminal";
			dropQueuedSteer: boolean;
			consecutiveSilentToolRounds: number;
	  };

export interface AgentRoundRunnerOptions {
	/// Turn-scoped `ui.*` wire emission — owns the dual-write invariant and
	/// the thinking-open/close bookkeeping. See `./emitter.ts`.
	emitter: TurnEmitter;
	/// Raw dispatcher, kept alongside `emitter` ONLY for the two things that
	/// don't fit the emitter's turn-scoped `ui.*` seam: the outbound
	/// `computerUse.stopAppSession` *request* in
	/// `finishToolRuntimeAfterTerminalAssistantReply`, and the
	/// `provider.statusChanged` notify (session/provider-scoped, not a
	/// turn-scoped `ui.*` frame) fired alongside an auth-invalidated stream
	/// error.
	dispatcher: Dispatcher;
	conversation: Conversation;
	session: Session;
	model: Model<Api>;
	effort: string | undefined;
	systemPrompt: string;
	observer: ContextObserver;
	toolSpecs: Tool[];
	toolByName: ReadonlyMap<string, ToolHandler<any, any>>;
	permissionGateway: PermissionAuthorizer;
	maxConsecutiveSilentToolRounds: number;
}

export function pickErrorCode(msg: AssistantMessage): number {
	if (msg.errorReason === "authInvalidated")
		return RPCErrorCode.permissionDenied;
	return RPCErrorCode.internalError;
}

/// Result of draining one LLM round's event stream, classified for `run()`
/// to branch on. "final" carries everything downstream phases need (the
/// terminal AssistantMessage plus the per-call outcomes recorded from
/// `toolcall_end` events); the other three kinds are already-terminal states
/// with any matching wire frames already emitted by `consumeStream` itself
/// (the `error` branch needs the specific `ev.error` payload, so that frame
/// can't be hoisted out to `run()` without threading the event back up).
type ConsumeStreamResult =
	| {
			kind: "final";
			final: AssistantMessage;
			callOutcomes: Map<string, ToolCallOutcome>;
	  }
	| { kind: "aborted" }
	| { kind: "streamError" }
	| { kind: "noFinal" };

export class AgentRoundRunner {
	constructor(private readonly options: AgentRoundRunnerOptions) {}

	async run(input: {
		turnId: string;
		signal: AbortSignal;
		consecutiveSilentToolRounds: number;
	}): Promise<AgentRoundOutcome> {
		const {
			dispatcher,
			emitter,
			conversation: convo,
			session,
			model,
			effort,
			systemPrompt,
			toolSpecs,
		} = this.options;
		const turnId = input.turnId;
		let consecutiveSilentToolRounds = input.consecutiveSilentToolRounds;

		const messagesForRound = buildOutboundMessages(convo, session);
		this.publishContext(turnId, messagesForRound);

		const eventStream = streamSimple(
			model,
			{
				systemPrompt,
				messages: messagesForRound,
				tools: toolSpecs.length > 0 ? toolSpecs : undefined,
			},
			{ signal: input.signal, reasoning: effort },
		);

		const streamResult = await this.consumeStream(
			turnId,
			input.signal,
			eventStream,
		);

		if (streamResult.kind === "streamError") {
			return this.terminal(consecutiveSilentToolRounds);
		}

		if (streamResult.kind === "aborted") {
			emitter.closeThinkingIfOpen(turnId);
			convo.finalizeCancellation(turnId);
			emitter.status(turnId, "done");
			return this.terminal(consecutiveSilentToolRounds);
		}

		if (streamResult.kind === "noFinal") {
			emitter.closeThinkingIfOpen(turnId);
			emitter.error(
				turnId,
				RPCErrorCode.internalError,
				"stream ended without a final assistant message",
			);
			return this.terminal(consecutiveSilentToolRounds);
		}

		const { final, callOutcomes } = streamResult;

		if (isContextOverflow(final, model.contextWindow)) {
			emitter.closeThinkingIfOpen(turnId);
			emitter.error(
				turnId,
				RPCErrorCode.agentContextOverflow,
				"Context too long",
			);
			return this.terminal(consecutiveSilentToolRounds);
		}

		if (!convo.appendAssistantRound(turnId, final)) {
			return this.terminal(consecutiveSilentToolRounds);
		}

		emitter.usage(turnId, final, model);

		const toolCalls = extractToolCalls(final);

		if (toolCalls.length === 0) {
			await finishToolRuntimeAfterTerminalAssistantReply({
				dispatcher,
				session,
			});
			const markedDone = convo.markDone(turnId);
			this.publishContext(turnId, buildOutboundMessages(convo, session));
			emitter.closeThinkingIfOpen(turnId);
			emitter.status(turnId, "done");
			return { kind: "done", markedDone, consecutiveSilentToolRounds };
		}

		const spokeThisRound = assistantSpoke(final);
		if (spokeThisRound) {
			consecutiveSilentToolRounds = 0;
		} else {
			consecutiveSilentToolRounds++;
		}
		session.setSilentToolRounds(consecutiveSilentToolRounds);
		if (
			consecutiveSilentToolRounds > this.options.maxConsecutiveSilentToolRounds
		) {
			emitter.closeThinkingIfOpen(turnId);
			return this.failToolBudget(
				turnId,
				toolCalls,
				callOutcomes,
				consecutiveSilentToolRounds,
			);
		}

		emitter.closeThinkingIfOpen(turnId);
		emitter.statusPersisted(turnId, "waiting");

		const dispatchResult = await executeToolCalls({
			session,
			turnId,
			signal: input.signal,
			toolCalls,
			callOutcomes,
			permissionGateway: this.options.permissionGateway,
			emitter,
			conversation: convo,
			model,
		});

		if (dispatchResult.kind === "turnGone") {
			return this.terminal(consecutiveSilentToolRounds);
		}

		if (dispatchResult.kind === "aborted") {
			convo.finalizeCancellation(turnId);
			emitter.status(turnId, "done");
			return this.terminal(consecutiveSilentToolRounds);
		}

		return { kind: "continue", consecutiveSilentToolRounds };
	}

	/// Drain one LLM round's event stream and classify the outcome. Owns the
	/// per-event wire projection (thinking/token/toolCall "called"/"rejected")
	/// and the `error` event's terminal frame emission (needs `ev.error`'s
	/// code/message/provider fields, so it can't be generically hoisted to
	/// `run()`). Returns `"aborted"` both when the signal fires between events
	/// and when it fires mid-iteration (checked at the top of the loop body,
	/// same as the inline loop this replaced) — `run()` owns the
	/// finalizeCancellation/status-done side effects for that case since they
	/// are shared with `executeToolCalls`'s abort path.
	private async consumeStream(
		turnId: string,
		signal: AbortSignal,
		eventStream: AsyncIterable<AssistantMessageEvent>,
	): Promise<ConsumeStreamResult> {
		const { emitter, dispatcher } = this.options;
		const callOutcomes = new Map<string, ToolCallOutcome>();
		let final: AssistantMessage | undefined;
		for await (const ev of eventStream) {
			if (signal.aborted) return { kind: "aborted" };
			if (ev.type === "thinking_delta") {
				emitter.thinkingDelta(turnId, ev.delta);
			} else if (ev.type === "thinking_end") {
				emitter.closeThinkingIfOpen(turnId);
			} else if (ev.type === "text_delta") {
				emitter.token(turnId, ev.delta);
			} else if (ev.type === "toolcall_end") {
				this.recordToolCallOutcome(turnId, ev.toolCall, callOutcomes);
			} else if (ev.type === "done") {
				final = ev.message;
			} else if (ev.type === "error") {
				const code = pickErrorCode(ev.error);
				const message = ev.error.errorMessage ?? "agent error";
				emitter.closeThinkingIfOpen(turnId);
				if (emitter.error(turnId, code, message)) {
					if (
						ev.error.errorReason === "authInvalidated" &&
						ev.error.errorProviderId
					) {
						// `provider.statusChanged` is session/provider-scoped, not a
						// turn-scoped `ui.*` frame — stays on the raw dispatcher.
						dispatcher.notify(RPCMethod.providerStatusChanged, {
							providerId: ev.error.errorProviderId,
							state: "unauthenticated",
							reason: "authInvalidated",
							message,
						});
					}
				}
				return { kind: "streamError" };
			}
		}

		if (signal.aborted) return { kind: "aborted" };
		if (!final) return { kind: "noFinal" };
		return { kind: "final", final, callOutcomes };
	}

	/// Build the `{ kind: "terminal" }` outcome shared by every early-exit
	/// branch in `run()` and `failToolBudget` — always drops the queued steer
	/// and carries whatever `consecutiveSilentToolRounds` count was live at
	/// the exit point.
	private terminal(consecutiveSilentToolRounds: number): AgentRoundOutcome {
		return {
			kind: "terminal",
			dropQueuedSteer: true,
			consecutiveSilentToolRounds,
		};
	}

	/// Transition back to "working" after a tool round completes and another
	/// LLM round is about to start. One of the two spots that persist the
	/// status onto the Conversation AND notify with the same value — see
	/// `TurnEmitter.statusPersisted`.
	resumeWorking(turnId: string): void {
		this.options.emitter.statusPersisted(turnId, "working");
	}

	private publishContext(turnId: string, messages: Message[]): void {
		const { observer, session, model, effort, systemPrompt } = this.options;
		publishTurnContext({
			observer,
			sessionId: session.id,
			turnId,
			model,
			effort,
			systemPrompt,
			messages,
		});
	}

	private recordToolCallOutcome(
		turnId: string,
		toolCall: ToolCall,
		callOutcomes: Map<string, ToolCallOutcome>,
	): void {
		const outcome = prepareToolCall(toolCall, this.options.toolByName);
		callOutcomes.set(toolCall.id, outcome);
		if (outcome.kind === "ready") {
			this.options.emitter.toolCall(turnId, {
				phase: "called",
				toolCallId: toolCall.id,
				toolName: toolCall.name,
				args: outcome.args as JSONValue,
			});
		} else {
			this.options.emitter.toolCall(turnId, {
				phase: "rejected",
				toolCallId: toolCall.id,
				toolName: toolCall.name,
				args: (toolCall.arguments ?? {}) as JSONValue,
				errorMessage: outcome.errorMessage,
			});
		}
	}

	private failToolBudget(
		turnId: string,
		toolCalls: ReturnType<typeof extractToolCalls>,
		callOutcomes: ReadonlyMap<string, ToolCallOutcome>,
		consecutiveSilentToolRounds: number,
	): AgentRoundOutcome {
		const {
			emitter,
			conversation: convo,
			maxConsecutiveSilentToolRounds,
		} = this.options;
		const overflowMsg = `tool-call budget exceeded (${maxConsecutiveSilentToolRounds} consecutive tool rounds without assistant text)`;
		const stopText = `Stopped by system: tool-call budget exceeded (${maxConsecutiveSilentToolRounds} consecutive tool calls without assistant text). Tell the user where you got and ask before continuing.`;
		for (const tc of toolCalls) {
			const stopMsg: ToolResultMessage = {
				role: "toolResult",
				toolCallId: tc.id,
				toolName: tc.name,
				content: [{ type: "text", text: stopText }],
				isError: true,
				timestamp: Date.now(),
			};
			if (!convo.appendToolResult(turnId, stopMsg)) {
				return this.terminal(consecutiveSilentToolRounds);
			}
			if (callOutcomes.get(tc.id)?.kind === "ready") {
				emitter.toolCall(turnId, {
					phase: "result",
					toolCallId: tc.id,
					toolName: tc.name,
					isError: true,
					outputText: stopText,
				});
			}
		}
		emitter.error(turnId, RPCErrorCode.internalError, overflowMsg);
		return this.terminal(consecutiveSilentToolRounds);
	}
}
