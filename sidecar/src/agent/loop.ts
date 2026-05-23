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
// public surface re-exported from `../llm`.

import {
  getDefaultModel,
  getModel,
  PROVIDER_IDS,
  effectiveEffort,
  type Model,
  type Api,
  type Message,
} from "../llm";
import { readUserConfig } from "../config/storage";
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
import { Dispatcher, RPCMethodError } from "../rpc/dispatcher";
import { Conversation } from "./conversation";
import { contextObserver as defaultContextObserver, ContextObserver } from "./context-observer";
import { SessionManager } from "./session/manager";
import { Session } from "./session/session";
import { toolRegistry } from "./tools";
import { type TodoItem } from "./todos/manager";
import { autoCompactIfNeeded, compactBreaker, compactConversation, COMPACT_NOOP_EMPTY } from "./compact";
import { buildSystemPrompt } from "./system-prompt";
import { AgentRoundRunner } from "./turn/round";
import { logger } from "../log";

export { pickErrorCode } from "./turn/round";

/// Hard ceiling on *consecutive* tool-call rounds in which the assistant
/// produced no visible text. Prevents a model stuck in a silent self-call
/// cycle from looping forever, while letting genuine long workflows proceed
/// as long as the model keeps narrating progress to the user between tool
/// bursts. Thinking is intentionally NOT counted as narration — only
/// user-visible text resets the counter. Surfaces as `internalError` when
/// hit.
const MAX_CONSECUTIVE_TOOL_ROUNDS = 25;

// ---------------------------------------------------------------------------
// Test injection point.
//
// Tests substitute the model resolver so a fake model + fake stream provider
// can be wired in without touching the global model / api registries. The
// production resolver reads the user's saved selection from the global config
// (set via the Shell settings panel → `config.set`); on a missing or stale
// selection it falls back to the catalog's `DEFAULT_MODEL_PER_PROVIDER`.
// Catalog stays the single source of truth — runtime code does not hardcode
// provider ids or model ids.
// ---------------------------------------------------------------------------

type ModelResolver = () => Model<Api>;

/// Resolve the model the agent loop should drive.
///
/// Per P2.4: stale and malformed config are different. A *missing* selection
/// (user has never picked) silently falls back to the catalog default — that
/// is the documented first-run path. A *stale* selection (saved id no longer
/// in the catalog) throws so `runTurn`'s top-level catch surfaces it as a
/// `ui.error`. Malformed config also throws (raised by `readUserConfig`).
/// Both error paths reach the user instead of silently swapping their model.
const defaultResolver: ModelResolver = () => {
  const cfg = readUserConfig();
  if (cfg.selection) {
    try {
      return getModel(cfg.selection.providerId, cfg.selection.modelId);
    } catch {
      throw new Error(
        `Configured model "${cfg.selection.providerId}/${cfg.selection.modelId}" is no longer available. ` +
          `Open Settings and pick a model.`,
      );
    }
  }
  return getDefaultModel(PROVIDER_IDS.chatgptPlan);
};
let modelResolver: ModelResolver = defaultResolver;

export function setModelResolver(fn: ModelResolver): void {
  modelResolver = fn;
}

export function resetModelResolver(): void {
  modelResolver = defaultResolver;
}

// ---------------------------------------------------------------------------
// Handler registration
// ---------------------------------------------------------------------------

export interface RegisterAgentOptions {
  /// SessionManager owning the per-session Conversation + TurnRegistry pair.
  /// Required. In production, `src/index.ts` constructs a fresh one; tests
  /// inject their own and pre-create as many sessions as needed.
  manager: SessionManager;
  /// Override the context observer used by Dev Mode.
  contextObserver?: ContextObserver;
}

export function registerAgentHandlers(dispatcher: Dispatcher, opts: RegisterAgentOptions): void {
  const observer = opts.contextObserver ?? defaultContextObserver;
  const manager = opts.manager;

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
      throw new RPCMethodError(RPCErrorCode.invalidParams, "missing or non-string sessionId");
    }
    const s = manager.get(sessionId);
    if (!s) {
      throw new RPCMethodError(RPCErrorCode.unknownSession, `unknown sessionId: ${sessionId}`);
    }
    return s;
  };

  dispatcher.registerRequest(RPCMethod.agentSubmit, async (raw): Promise<AgentSubmitResult> => {
    const params = (raw ?? {}) as AgentSubmitParams;
    const { sessionId, turnId, prompt, citedContext } = params;
    if (typeof turnId !== "string" || typeof prompt !== "string" || citedContext === undefined) {
      throw new RPCMethodError(
        RPCErrorCode.invalidParams,
        "agent.submit requires { sessionId, turnId, prompt, citedContext }",
      );
    }
    const session = resolveSession(sessionId);
    const convo = session.conversation;
    const reg = session.turns;

    if (reg.get(turnId)) {
      throw new RPCMethodError(RPCErrorCode.invalidRequest, `turnId already active: ${turnId}`);
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
  });

  dispatcher.registerRequest(RPCMethod.agentCancel, async (raw): Promise<AgentCancelResult> => {
    const { sessionId, turnId } = (raw ?? {}) as AgentCancelParams;
    if (typeof turnId !== "string") {
      throw new RPCMethodError(RPCErrorCode.invalidParams, "agent.cancel requires { sessionId, turnId }");
    }
    const session = resolveSession(sessionId);
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
  });

  dispatcher.registerRequest(RPCMethod.agentCompact, async (raw): Promise<AgentCompactResult> => {
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
    const model = modelResolver();
    session.setCompacting(true);
    const lifecycleTurnId = "";
    dispatcher.notify(RPCMethod.uiCompact, {
      sessionId: session.id,
      turnId: lifecycleTurnId,
      phase: "started",
    });
    try {
      const result = await compactConversation(session, model, { mode: "manual" });
      if (result === COMPACT_NOOP_EMPTY) {
        // Documented short-circuit: empty session, nothing to fold. Emit
        // a `done` with no count so the Shell's lifecycle still closes
        // cleanly and any in-progress divider goes away.
        dispatcher.notify(RPCMethod.uiCompact, {
          sessionId: session.id,
          turnId: lifecycleTurnId,
          phase: "done",
        });
        session.setCompacting(false);
        startQueuedTurnIfIdle(session);
        return { ok: true };
      }
      dispatcher.notify(RPCMethod.uiCompact, {
        sessionId: session.id,
        turnId: lifecycleTurnId,
        phase: "done",
        compactedTurnCount: result.compactedTurnCount,
      });
      session.setCompacting(false);
      startQueuedTurnIfIdle(session);
      return { ok: true, compactedTurnCount: result.compactedTurnCount };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      logger.error("manual compact failed", { sessionId: session.id, err: String(err) });
      dispatcher.notify(RPCMethod.uiCompact, {
        sessionId: session.id,
        turnId: lifecycleTurnId,
        phase: "failed",
        errorMessage: message,
      });
      session.setCompacting(false);
      startQueuedTurnIfIdle(session);
      throw new RPCMethodError(RPCErrorCode.internalError, message);
    }
  });

  dispatcher.registerRequest(RPCMethod.agentReset, async (raw): Promise<AgentResetResult> => {
    const { sessionId } = (raw ?? {}) as AgentResetParams;
    const session = resolveSession(sessionId);
    session.turns.abortAll();
    session.consumeSteer();
    session.setCompacting(false);
    session.conversation.reset();
    // s03: a wiped conversation owns no plan — clear and broadcast the
    // empty list so the Shell's todo panel collapses in lockstep with the
    // history.
    session.todos.clear();
    // s06: drop the compact breaker too. A reset session starts fresh —
    // any auto-compact failures from the prior history must not carry
    // over and silently disable compaction for the new run.
    compactBreaker.forget(session.id);
    dispatcher.notify(RPCMethod.conversationReset, { sessionId: session.id });
    dispatcher.notify(RPCMethod.uiTodo, { sessionId: session.id, items: [] });
    // turnCount/lastActivityAt regress; surface to history list.
    manager.notifyListChanged();
    return { ok: true };
  });

  const startAndLaunchTurn = (
    session: Session,
    input: { turnId: string; prompt: string; citedContext: AgentSubmitParams["citedContext"] },
  ): void => {
    const convo = session.conversation;
    const reg = session.turns;
    const turn = convo.startTurn({ id: input.turnId, prompt: input.prompt, citedContext: input.citedContext });
    dispatcher.notify(RPCMethod.conversationTurnStarted, {
      sessionId: session.id,
      turn: Conversation.toWire(turn),
    });

    const titleChanged = manager.maybeDeriveTitle(session.id, input.prompt);
    if (titleChanged || convo.turns.length === 1) {
      manager.notifyListChanged();
    }

    const controller = reg.add(input.turnId);
    void runTurn(dispatcher, convo, {
      session,
      turnId: input.turnId,
      signal: controller.signal,
      observer,
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
          turn: Conversation.toWire(next),
        });
        manager.notifyListChanged();
      },
    })
      .catch((err) => logger.error("agent loop fatal", { sessionId: session.id, turnId: input.turnId, err: String(err) }))
      .finally(() => reg.clear());
  };

  const startQueuedTurnIfIdle = (session: Session): void => {
    if (session.turns.size > 0 || session.isCompacting) return;
    const queued = session.consumeSteer();
    if (!queued) return;
    startAndLaunchTurn(session, queued);
  };
}

// ---------------------------------------------------------------------------
// runTurn — exported for tests
// ---------------------------------------------------------------------------

export async function runTurn(
  dispatcher: Dispatcher,
  convo: Conversation,
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
    startSteerTurn?: (steer: { turnId: string; prompt: string; citedContext: AgentSubmitParams["citedContext"] }) => void;
    /// Move the abort-controller registry key when a steer prompt becomes
    /// the active visible turn.
    onSteerActivated?: (fromTurnId: string, toTurnId: string) => void;
  },
): Promise<void> {
  const { session, signal } = params;
  let turnId = params.turnId;
  const sessionId = session.id;
  const observer = params.observer ?? defaultContextObserver;
  const todos = session.todos;

  const dropQueuedSteer = (): void => {
    session.consumeSteer();
  };

  dispatcher.notify(RPCMethod.uiStatus, { sessionId, turnId, status: "working" });

  let model: Model<Api>;
  let cfg: ReturnType<typeof readUserConfig>;
  try {
    model = modelResolver();
    cfg = readUserConfig();
  } catch (err) {
    // Covers both `modelResolver` failures (missing model, malformed config
    // raised inside its own readUserConfig call) and the bare `readUserConfig`
    // call below. The boolean return signals whether the durable mutation
    // landed; we ALWAYS notify on this top-level boot failure because the
    // turn was just registered and the caller deserves a visible error.
    const message = err instanceof Error ? err.message : String(err);
    logger.error("model/config resolution failed", { turnId, err: String(err) });
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
    conversation: convo,
    session,
    model,
    effort,
    systemPrompt,
    observer,
    toolSpecs,
    toolByName,
    maxConsecutiveSilentToolRounds: MAX_CONSECUTIVE_TOOL_ROUNDS,
  });

  const activateQueuedSteer = (previousAlreadyDone = false): boolean => {
    const steer = session.consumeSteer();
    if (!steer) return false;
    if (!params.startSteerTurn || !params.onSteerActivated) {
      throw new Error("runTurn missing steer activation callbacks");
    }
    const previousTurnId = turnId;
    if (!previousAlreadyDone) {
      const ok = convo.markDone(previousTurnId);
      dispatcher.notify(RPCMethod.uiStatus, { sessionId, turnId: previousTurnId, status: "done" });
      if (ok) params.onDone?.();
    }
    params.startSteerTurn(steer);
    params.onSteerActivated(previousTurnId, steer.turnId);
    turnId = steer.turnId;
    dispatcher.notify(RPCMethod.uiStatus, { sessionId, turnId, status: "working" });
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
    dispatcher.notify(RPCMethod.uiTodo, {
      sessionId,
      items: todoItemsForWire(items),
    });
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
          dispatcher.notify(RPCMethod.uiCompact, { sessionId, turnId, phase: "started" });
        },
      });
      if (result) {
        dispatcher.notify(RPCMethod.uiCompact, {
          sessionId,
          turnId,
          phase: "done",
          compactedTurnCount: result.compactedTurnCount,
        });
      }
      // result === null is the silent-skip path: under threshold, breaker
      // disabled, or no prior history. No `started` was emitted, so no
      // closer is owed.
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      logger.error("auto-compact failed", { sessionId, turnId, err: String(err) });
      dispatcher.notify(RPCMethod.uiCompact, {
        sessionId,
        turnId,
        phase: "failed",
        errorMessage: message,
      });
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
    const message = err instanceof Error ? err.message : String(err);
    logger.error("runTurn failed", { turnId, err: String(err) });
    roundRunner.closeThinkingIfOpen(turnId);
    if (convo.setError(turnId, RPCErrorCode.internalError, message)) {
      dispatcher.notify(RPCMethod.uiError, {
        sessionId,
        turnId,
        code: RPCErrorCode.internalError,
        message,
      });
    }
    dropQueuedSteer();
  } finally {
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
