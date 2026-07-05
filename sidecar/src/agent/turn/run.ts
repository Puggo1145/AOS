// Agent turn loop — bridges `agent.submit` / `agent.cancel` / `agent.reset`
// to the sidecar's `Conversation` store, the `llm/` stream, and the tool
// registry.
//
// Per docs/designs/rpc-protocol.md §"流式语义":
//   1. agent.submit Request returns { accepted: true } immediately. The actual
//      LLM streaming happens in a detached background task. *Before* the ack
//      we register the turn into the Conversation and broadcast
//      `conversation.turnStarted` so observers see the turn appear before any
//      streamed token.
//   2. While streaming, ui.token / ui.thinking / ui.toolCall / ui.status /
//      ui.error notifications are pushed AND the matching turn in the
//      Conversation is mutated in place. This dual write is intentional:
//      ui.token is the cheap streaming transport (no full snapshot per
//      character); the Conversation is the durable store that drives the
//      next request's LLM context.
//   3. agent.cancel triggers the per-turn AbortController; the stream loop
//      observes `signal.aborted`, breaks out, and emits `ui.status done`.
//   4. agent.reset aborts every live stream, wipes the Conversation, and
//      emits `conversation.reset` so observers can drop their mirrors.
//
// Tool-use sub-loop (s02):
//   When the model returns `stopReason: "toolUse"`, we execute every tool
//   call from that assistant message, push each result back into the
//   conversation as a `ToolResultMessage`, and re-issue `streamSimple` with
//   the updated history. Loop until the model returns `stopReason: "stop"`
//   (terminal) or hits `MAX_CONSECUTIVE_TOOL_ROUNDS` consecutive tool-only
//   rounds without the assistant emitting any visible text (safety cap;
//   surfaces as an internal error to break runaway tool-call cycles).
//   Visible assistant text resets the counter; thinking does NOT — only
//   user-facing speech proves the model is still narrating progress rather
//   than spinning silently.
//
// Per docs/designs/llm-provider.md §"包边界" the loop only depends on the
// public surface re-exported from `../../llm`.

import { errorText } from "../../errors";
import { effectiveEffort, type Model, type Api, type Message } from "../../llm";
import { readUserConfig } from "../../config/storage";
import {
	RPCErrorCode,
	RPCMethod,
	type AgentSubmitParams,
} from "../../rpc/rpc-types";
import type { Dispatcher } from "../../rpc/dispatcher";
import {
	contextObserver as defaultContextObserver,
	type ContextObserver,
} from "../context-observer";
import type { Session } from "../session/session";
import { toolRegistry } from "../tools";
import type { TodoItem } from "../todos/manager";
import { autoCompactIfNeeded } from "../compact";
import { buildSystemPrompt } from "../system-prompt";
import { AgentRoundRunner } from "./round";
import { TurnEmitter } from "./emitter";
import { logger } from "../../log";
import type { PermissionAuthorizer } from "../permissions";
import { resolveModel } from "../model-resolver";

/// Hard ceiling on *consecutive* tool-call rounds in which the assistant
/// produced no visible text. Prevents a model stuck in a silent self-call
/// cycle from looping forever, while letting genuine long workflows proceed
/// as long as the model keeps narrating progress to the user between tool
/// bursts. Thinking is intentionally NOT counted as narration — only
/// user-visible text resets the counter. Surfaces as `internalError` when
/// hit.
const MAX_CONSECUTIVE_TOOL_ROUNDS = 25;

// ---------------------------------------------------------------------------
// runTurn — exported for tests
// ---------------------------------------------------------------------------

export async function runTurn(
	dispatcher: Dispatcher,
	params: {
		/// The session that owns this turn. The loop reads `session.todos` for
		/// `ui.todo` projection and threads the whole session into `renderAmbient`
		/// so future ambient providers (worktree path, current time, etc.) can
		/// pull from any session-scoped state without re-plumbing this signature.
		session: Session;
		turnId: string;
		signal: AbortSignal;
		observer?: ContextObserver;
		/// Called when the turn lands in a terminal `done` state (post-`markDone`).
		/// Loop uses this to fire `session.listChanged` (turnCount + lastActivityAt
		/// changed). Errored / cancelled paths do not increment turnCount, so they
		/// don't invoke this hook.
		onDone?: () => void;
		/// Materialize a queued steer prompt into the Conversation and Shell
		/// mirror. The loop calls this only at provider-safe boundaries.
		startSteerTurn?: (steer: {
			turnId: string;
			prompt: string;
			citedContext: AgentSubmitParams["citedContext"];
		}) => void;
		/// Move the abort-controller registry key when a steer prompt becomes
		/// the active visible turn.
		onSteerActivated?: (fromTurnId: string, toTurnId: string) => void;
		permissionGateway: PermissionAuthorizer;
	},
): Promise<void> {
	const { session, signal } = params;
	const convo = session.conversation;
	let turnId = params.turnId;
	const sessionId = session.id;
	const observer = params.observer ?? defaultContextObserver;
	const todos = session.todos;
	// One TurnEmitter per runTurn invocation. turnId is threaded through
	// method calls (not captured here) because a steer activation swaps the
	// active turnId partway through this function; sessionId does not change.
	const emitter = new TurnEmitter({
		sink: dispatcher,
		sessionId,
		conversation: convo,
	});

	const dropQueuedSteer = (): void => {
		session.consumeSteer();
	};

	emitter.status(turnId, "working");

	let model: Model<Api>;
	let cfg: ReturnType<typeof readUserConfig>;
	try {
		model = resolveModel();
		cfg = readUserConfig();
	} catch (err) {
		// Covers both `modelResolver` failures (missing model, malformed config
		// raised inside its own readUserConfig call) and the bare `readUserConfig`
		// call below. Deliberately NOT routed through `emitter.error` (which
		// gates the notify on the mutation applying): the boolean return
		// signals whether the durable mutation landed, but we ALWAYS notify on
		// this top-level boot failure because the turn was just registered and
		// the caller deserves a visible error.
		const message = errorText(err);
		logger.error("model/config resolution failed", {
			turnId,
			err: String(err),
		});
		dropQueuedSteer();
		convo.setError(turnId, RPCErrorCode.internalError, message);
		dispatcher.notify(RPCMethod.uiError, {
			sessionId,
			turnId,
			code: RPCErrorCode.internalError,
			message,
		});
		return;
	}

	const effort: string | undefined = effectiveEffort(model, cfg.effort);
	const systemPrompt = buildSystemPrompt();

	// Snapshot the available tools once per turn. The same set is reused on
	// every LLM round inside the tool sub-loop — reading the registry mid-turn
	// would let tool-pack hot-swaps happen between rounds, which is a footgun
	// for callers; freezing per turn keeps the model's view stable.
	const tools = toolRegistry.list();
	const toolSpecs = tools.map((t) => t.spec);
	const toolByName = new Map(tools.map((t) => [t.spec.name, t] as const));

	const roundRunner = new AgentRoundRunner({
		dispatcher,
		emitter,
		conversation: convo,
		session,
		model,
		effort,
		systemPrompt,
		observer,
		toolSpecs,
		toolByName,
		permissionGateway: params.permissionGateway,
		maxConsecutiveSilentToolRounds: MAX_CONSECUTIVE_TOOL_ROUNDS,
	});

	const activateQueuedSteer = (previousAlreadyDone = false): boolean => {
		const steer = session.consumeSteer();
		if (!steer) return false;
		if (!params.startSteerTurn || !params.onSteerActivated) {
			throw new Error("runTurn missing steer activation callbacks");
		}
		const previousTurnId = turnId;
		params.permissionGateway.clearTurnGrants(sessionId, previousTurnId);
		if (!previousAlreadyDone) {
			const ok = convo.markDone(previousTurnId);
			emitter.status(previousTurnId, "done");
			if (ok) params.onDone?.();
		}
		params.startSteerTurn(steer);
		params.onSteerActivated(previousTurnId, steer.turnId);
		turnId = steer.turnId;
		emitter.status(turnId, "working");
		return true;
	};

	// s03: subscribe to the per-session TodoManager so every successful
	// `todo_write` call (i.e. one that passed validation and replaced the
	// list) projects onto the wire as `ui.todo`. The subscriber fires
	// synchronously inside `manager.update()`, so the wire ordering is
	// tool-result → ui.todo → next round, matching what the Shell mirror
	// expects. We unsubscribe at the bottom of the try/finally so a turn
	// that errors out doesn't keep emitting after it has terminated.
	const unsubTodo = todos.subscribe((items) => {
		emitter.todo(todoItemsForWire(items));
	});

	try {
		// s06 auto-compact: at turn entry, before any LLM round, check
		// whether the running estimate of remaining context (`contextWindow
		// - lastTotalTokens`) has fallen under the threshold. If yes,
		// summarize all prior history into one synthetic user message and
		// re-anchor the active turn on top. The breaker (3 consecutive
		// failures = disabled for this session) gates the auto path; the
		// wrapper does its own breaker accounting and short-circuits cleanly
		// when there is no prior history to compact.
		//
		// Failures here are non-fatal: we surface `ui.compact failed` for
		// observability and let the turn proceed with the original history.
		// The next round may overflow and surface as `agentContextOverflow`,
		// but at least one of "auto-compact ran" / "explicit overflow error"
		// happens — the user is never silently stuck.
		// `started` fires inside `onStart` — only after all skip gates pass
		// and immediately before the summarization LLM call begins. This
		// pairs every `started` with a matching `done` or `failed`; sending
		// `started` unconditionally up here would leave the Shell hanging on
		// a half-open lifecycle for every turn where compaction was a no-op.
		try {
			const result = await autoCompactIfNeeded(session, model, {
				signal,
				onStart: () => {
					emitter.compact(turnId, "started");
				},
			});
			if (result) {
				emitter.compact(turnId, "done", {
					compactedTurnCount: result.compactedTurnCount,
				});
			}
			// result === null is the silent-skip path: under threshold, breaker
			// disabled, or no prior history. No `started` was emitted, so no
			// closer is owed.
		} catch (err) {
			const message = errorText(err);
			logger.error("auto-compact failed", {
				sessionId,
				turnId,
				err: String(err),
			});
			emitter.compact(turnId, "failed", { errorMessage: message });
		}

		// Counts tool rounds since the assistant last emitted visible text.
		// Reset on any round whose final AssistantMessage carries a non-empty
		// text content block; incremented on each tool-bearing round. When it
		// exceeds MAX_CONSECUTIVE_TOOL_ROUNDS the turn bails as a runaway loop.
		//
		// Mirrored onto `session.silentToolRounds` so the silent-progress
		// ambient provider can read it on the next round and decide whether
		// to inject a "tell the user where you are" reminder. We reset the
		// session field at turn entry so a previous turn's residual count
		// never leaks into a fresh user prompt.
		let consecutiveSilentToolRounds = 0;
		session.setSilentToolRounds(0);
		while (true) {
			const outcome = await roundRunner.run({
				turnId,
				signal,
				consecutiveSilentToolRounds,
			});
			consecutiveSilentToolRounds = outcome.consecutiveSilentToolRounds;

			if (outcome.kind === "terminal") {
				if (outcome.dropQueuedSteer) dropQueuedSteer();
				return;
			}

			if (outcome.kind === "done") {
				if (outcome.markedDone) params.onDone?.();
				if (activateQueuedSteer(true)) {
					consecutiveSilentToolRounds = 0;
					session.setSilentToolRounds(0);
					continue;
				}
				return;
			}

			if (activateQueuedSteer()) {
				consecutiveSilentToolRounds = 0;
				session.setSilentToolRounds(0);
				continue;
			}

			roundRunner.resumeWorking(turnId);
		}
	} catch (err) {
		const message = errorText(err);
		logger.error("runTurn failed", { turnId, err: String(err) });
		emitter.closeThinkingIfOpen(turnId);
		emitter.error(turnId, RPCErrorCode.internalError, message);
		dropQueuedSteer();
	} finally {
		params.permissionGateway.clearTurnGrants(sessionId, turnId);
		unsubTodo();
	}
}

/// Project a TodoManager snapshot onto the wire shape. Identity transform
/// (the manager's `TodoItem` already matches `TodoItemWire`); kept as a
/// dedicated function so the call site reads as "convert internal to wire"
/// and tests can assert against the wire shape directly.
function todoItemsForWire(items: TodoItem[]): TodoItem[] {
	return items.map((it) => ({ id: it.id, text: it.text, status: it.status }));
}

// Re-export for tests that touch llmMessages-derived behavior without
// caring about the broader surface.
export type { Message };
