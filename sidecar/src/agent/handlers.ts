// Agent RPC handler registration — wires `agent.submit` / `agent.cancel` /
// `agent.compact` / `agent.reset` and `dev.context.get` onto the dispatcher,
// resolving sessions and launching turns via `./turn/run`'s `runTurn`.
//
// Per docs/designs/rpc-protocol.md §"流式语义":
//   1. agent.submit Request returns { accepted: true } immediately. The actual
//      LLM streaming happens in a detached background task. *Before* the ack
//      we register the turn into the Conversation and broadcast
//      `conversation.turnStarted` so observers see the turn appear before any
//      streamed token.
//   3. agent.cancel triggers the per-turn AbortController; the stream loop
//      observes `signal.aborted`, breaks out, and emits `ui.status done`.
//   4. agent.reset aborts every live stream, wipes the Conversation, and
//      emits `conversation.reset` so observers can drop their mirrors.

import { errorText } from "../errors";
import {
	RPCErrorCode,
	RPCMethod,
	type AgentSubmitParams,
	type AgentSubmitResult,
	type AgentCancelParams,
	type AgentCancelResult,
	type AgentResetParams,
	type AgentResetResult,
	type AgentCompactParams,
	type AgentCompactResult,
} from "../rpc/rpc-types";
import { type Dispatcher, RPCMethodError } from "../rpc/dispatcher";
import {
	contextObserver as defaultContextObserver,
	type ContextObserver,
} from "./context-observer";
import { conversationTurnToWire } from "./rpc-projection";
import type { SessionManager } from "./session/manager";
import type { Session } from "./session/session";
import { compactConversation, COMPACT_NOOP_EMPTY } from "./compact";
import { TurnEmitter } from "./turn/emitter";
import { runTurn } from "./turn/run";
import { resolveModel } from "./model-resolver";
import { logger } from "../log";
import type { PermissionAuthorizer } from "./permissions";

export interface RegisterAgentOptions {
	/// SessionManager owning the per-session Conversation + TurnRegistry pair.
	/// Required. In production, `src/index.ts` constructs a fresh one; tests
	/// inject their own and pre-create as many sessions as needed.
	manager: SessionManager;
	/// Override the context observer used by Dev Mode.
	contextObserver?: ContextObserver;
	/// Required Gateway boundary for every agent-originated tool effect.
	permissionGateway: PermissionAuthorizer;
}

export function registerAgentHandlers(
	dispatcher: Dispatcher,
	opts: RegisterAgentOptions,
): void {
	const observer = opts.contextObserver ?? defaultContextObserver;
	const manager = opts.manager;
	const permissionGateway = opts.permissionGateway;

	// Wire the observer's sink to the dispatcher. The agent loop only ever
	// calls `observer.publish(...)`; this is the single edge where the
	// dev-mode signal crosses into the wire protocol.
	observer.setSink((snapshot) => {
		dispatcher.notify(RPCMethod.devContextChanged, { snapshot });
	});

	dispatcher.registerRequest(RPCMethod.devContextGet, async () => {
		return { snapshot: observer.latest() };
	});

	/// Resolve a sessionId to its Session, or throw `unknownSession`. Used by
	/// every `agent.*` handler — none of them fall back to `manager.activeId`
	/// per the design's "active session 显式投影到 wire" principle.
	const resolveSession = (sessionId: unknown) => {
		if (typeof sessionId !== "string") {
			throw new RPCMethodError(
				RPCErrorCode.invalidParams,
				"missing or non-string sessionId",
			);
		}
		const s = manager.get(sessionId);
		if (!s) {
			throw new RPCMethodError(
				RPCErrorCode.unknownSession,
				`unknown sessionId: ${sessionId}`,
			);
		}
		return s;
	};

	dispatcher.registerRequest(
		RPCMethod.agentSubmit,
		async (raw): Promise<AgentSubmitResult> => {
			const params = (raw ?? {}) as AgentSubmitParams;
			const { sessionId, turnId, prompt, citedContext } = params;
			if (
				typeof turnId !== "string" ||
				typeof prompt !== "string" ||
				citedContext === undefined
			) {
				throw new RPCMethodError(
					RPCErrorCode.invalidParams,
					"agent.submit requires { sessionId, turnId, prompt, citedContext }",
				);
			}
			const session = resolveSession(sessionId);
			const reg = session.turns;

			if (reg.get(turnId)) {
				throw new RPCMethodError(
					RPCErrorCode.invalidRequest,
					`turnId already active: ${turnId}`,
				);
			}

			if (session.pendingSteer) {
				throw new RPCMethodError(
					RPCErrorCode.invalidRequest,
					`session ${session.id} already has a queued steer prompt`,
				);
			}

			if (reg.size > 0 || session.isCompacting) {
				session.queueSteer({ turnId, prompt, citedContext });
				return { accepted: true };
			}

			startAndLaunchTurn(session, { turnId, prompt, citedContext });

			return { accepted: true };
		},
	);

	dispatcher.registerRequest(
		RPCMethod.agentCancel,
		async (raw): Promise<AgentCancelResult> => {
			const { sessionId, turnId } = (raw ?? {}) as AgentCancelParams;
			if (typeof turnId !== "string") {
				throw new RPCMethodError(
					RPCErrorCode.invalidParams,
					"agent.cancel requires { sessionId, turnId }",
				);
			}
			const session = resolveSession(sessionId);
			if (turnId === "" && session.isCompacting) {
				return { cancelled: session.cancelCompact() };
			}
			if (session.cancelSteer(turnId)) {
				return { cancelled: true };
			}
			const cancelled = session.turns.abort(turnId);
			if (cancelled) {
				// Flip status now so the Shell mirror can render the turn as
				// cancelled before the loop reaches its terminal cancel site. The
				// slice-level cleanup (orphan tool_use fill + interrupt marker) is
				// deferred to `runTurn`'s cancel sites: doing it here would race
				// with any tool result the loop is about to append between the
				// signal firing and the loop noticing it. The loop calls
				// `finalizeCancellation` once it has stopped touching the slice.
				session.conversation.setStatus(turnId, "cancelled");
			}
			return { cancelled };
		},
	);

	dispatcher.registerRequest(
		RPCMethod.agentCompact,
		async (raw): Promise<AgentCompactResult> => {
			// Manual `/compact` entry. Layer 3 of the compact stack: user
			// explicitly asks for a context-compact pass right now. Differences
			// from the auto path (`autoCompactIfNeeded` inside runTurn):
			//   - Bypasses the auto-compact breaker. Manual intent overrides
			//     past auto failures; a user repeatedly hitting `/compact` after
			//     transient summarizer errors shouldn't be silently gated.
			//   - Rejected if a turn is in flight on this session — that would
			//     interleave a second LLM stream with the running runTurn's
			//     stream, plus the active turn's slice would shift mid-stream.
			//   - Wire turnId on the lifecycle frames is the empty string. There
			//     is no "next turn" the marker should visually precede; Shell
			//     renders the marker at the tail of history.
			const { sessionId } = (raw ?? {}) as AgentCompactParams;
			const session = resolveSession(sessionId);
			if (session.turns.size > 0) {
				throw new RPCMethodError(
					RPCErrorCode.invalidRequest,
					`session ${session.id} has an in-flight turn; cancel or wait before compacting`,
				);
			}
			if (session.isCompacting) {
				throw new RPCMethodError(
					RPCErrorCode.invalidRequest,
					`session ${session.id} is already compacting`,
				);
			}
			const model = resolveModel();
			const compactController = session.beginCompact();
			const lifecycleTurnId = "";
			const emitter = new TurnEmitter({
				sink: dispatcher,
				sessionId: session.id,
				conversation: session.conversation,
			});
			emitter.compact(lifecycleTurnId, "started");
			// Cleanup (`clearCompact` + kicking off any queued steer turn) must
			// run exactly once no matter which of the four exit paths below is
			// taken (noop-empty, success, cancelled, error) — hoisted into a
			// single `finally` instead of repeating the pair on every branch.
			try {
				const result = await compactConversation(session, model, {
					mode: "manual",
					signal: compactController.signal,
				});
				if (result === COMPACT_NOOP_EMPTY) {
					// Documented short-circuit: empty session, nothing to fold. Emit
					// a `done` with no count so the Shell's lifecycle still closes
					// cleanly and any in-progress divider goes away.
					emitter.compact(lifecycleTurnId, "done");
					return { ok: true };
				}
				emitter.compact(lifecycleTurnId, "done", {
					compactedTurnCount: result.compactedTurnCount,
				});
				return { ok: true, compactedTurnCount: result.compactedTurnCount };
			} catch (err) {
				if (compactController.signal.aborted) {
					emitter.compact(lifecycleTurnId, "failed", {
						errorMessage: "compact cancelled",
					});
					return { ok: false };
				}
				const message = errorText(err);
				logger.error("manual compact failed", {
					sessionId: session.id,
					err: String(err),
				});
				emitter.compact(lifecycleTurnId, "failed", { errorMessage: message });
				throw new RPCMethodError(RPCErrorCode.internalError, message);
			} finally {
				session.clearCompact(compactController);
				startQueuedTurnIfIdle(session);
			}
		},
	);

	dispatcher.registerRequest(
		RPCMethod.agentReset,
		async (raw): Promise<AgentResetResult> => {
			const { sessionId } = (raw ?? {}) as AgentResetParams;
			const session = resolveSession(sessionId);
			session.turns.abortAll();
			session.consumeSteer();
			session.abortCompact();
			session.conversation.reset();
			// s03: a wiped conversation owns no plan — clear and broadcast the
			// empty list so the Shell's todo panel collapses in lockstep with the
			// history.
			session.todos.clear();
			// s06: drop the compact breaker too. A reset session starts fresh —
			// any auto-compact failures from the prior history must not carry
			// over and silently disable compaction for the new run.
			session.compactBreaker.reset();
			dispatcher.notify(RPCMethod.conversationReset, { sessionId: session.id });
			dispatcher.notify(RPCMethod.uiTodo, { sessionId: session.id, items: [] });
			// turnCount/lastActivityAt regress; surface to history list.
			manager.notifyListChanged();
			return { ok: true };
		},
	);

	const startAndLaunchTurn = (
		session: Session,
		input: {
			turnId: string;
			prompt: string;
			citedContext: AgentSubmitParams["citedContext"];
		},
	): void => {
		const convo = session.conversation;
		const reg = session.turns;
		const turn = convo.startTurn({
			id: input.turnId,
			prompt: input.prompt,
			citedContext: input.citedContext,
		});
		dispatcher.notify(RPCMethod.conversationTurnStarted, {
			sessionId: session.id,
			turn: conversationTurnToWire(turn),
		});

		const titleChanged = manager.maybeDeriveTitle(session.id, input.prompt);
		if (titleChanged || convo.turns.length === 1) {
			manager.notifyListChanged();
		}

		const controller = reg.add(input.turnId);
		void runTurn(dispatcher, {
			session,
			turnId: input.turnId,
			signal: controller.signal,
			observer,
			permissionGateway,
			onDone: () => manager.notifyListChanged(),
			onSteerActivated: (fromTurnId, toTurnId) => {
				reg.replace(fromTurnId, toTurnId);
			},
			startSteerTurn: (steer) => {
				const next = convo.startTurn({
					id: steer.turnId,
					prompt: steer.prompt,
					citedContext: steer.citedContext,
				});
				dispatcher.notify(RPCMethod.conversationTurnStarted, {
					sessionId: session.id,
					turn: conversationTurnToWire(next),
				});
				manager.notifyListChanged();
			},
		})
			.catch((err) =>
				logger.error("agent loop fatal", {
					sessionId: session.id,
					turnId: input.turnId,
					err: String(err),
				}),
			)
			.finally(() => reg.clear());
	};

	const startQueuedTurnIfIdle = (session: Session): void => {
		if (session.turns.size > 0 || session.isCompacting) return;
		const queued = session.consumeSteer();
		if (!queued) return;
		startAndLaunchTurn(session, queued);
	};
}
