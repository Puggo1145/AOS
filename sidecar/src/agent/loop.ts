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
  streamSimple,
  getDefaultModel,
  getModel,
  isContextOverflow,
  PROVIDER_IDS,
  effectiveEffort,
  type AssistantMessage,
  type Model,
  type Api,
  type ToolResultMessage,
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
  type JSONValue,
} from "../rpc/rpc-types";
import { Dispatcher, RPCMethodError } from "../rpc/dispatcher";
import { TurnRegistry } from "./registry";
import { Conversation } from "./conversation";
import { contextObserver as defaultContextObserver, ContextObserver } from "./context-observer";
import { SessionManager } from "./session/manager";
import { Session } from "./session/session";
import { toolRegistry, type ToolExecResult } from "./tools";
import { type TodoItem } from "./todos/manager";
import { autoCompactIfNeeded, compactBreaker, compactConversation, COMPACT_NOOP_EMPTY } from "./compact";
import { buildSystemPrompt } from "./system-prompt";
import { buildOutboundMessages, publishTurnContext } from "./turn/outbound";
import {
  assistantSpoke,
  extractToolCalls,
  prepareToolCall,
  renderToolResultForWire,
  runTool,
  type ToolCallOutcome,
} from "./turn/tool-dispatch";
import { logger } from "../log";

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
// Error code mapping
// ---------------------------------------------------------------------------

/// Per design risk note: ErrPermissionDenied (-32003) covers auth failures
/// (missing/expired ChatGPT token, 401 from upstream). Everything else is
/// surfaced as the generic agent-segment internal error.
///
/// We trust the typed `errorReason` field exclusively. Provider implementations
/// MUST tag auth failures with `errorReason: "authInvalidated"`; relying on
/// regex over `errorMessage` would let provider wording drift silently change
/// the surfaced code. If an auth failure slips through without the typed tag,
/// it will surface as InternalError — the right pressure to make providers
/// emit the typed reason.
export function pickErrorCode(msg: AssistantMessage): number {
  if (msg.errorReason === "authInvalidated") return RPCErrorCode.permissionDenied;
  return RPCErrorCode.internalError;
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

  // Per-call validation outcome cache, populated at `toolcall_end` time and
  // consumed by the dispatch loop after streaming completes. We validate
  // up-front so the wire's `called` / `rejected` decision is made before the
  // notification fires — preserving the strict per-phase invariant that
  // `called` only ever ships validated args.
  const callOutcomes = new Map<string, ToolCallOutcome>();

  // Tracks whether a reasoning block has been opened on the wire and not yet
  // closed. The provider stream's `thinking_end` is the happy-path closer,
  // but providers can also bail out of thinking with an error, the user can
  // cancel mid-trace, or an exception can propagate before the provider
  // emits `thinking_end`. In every one of those terminal paths we MUST
  // synthesize a `{ kind: "end" }` before the terminal `ui.error` /
  // `ui.status done`, otherwise the Shell's shimmer keeps animating
  // indefinitely.
  let thinkingOpen = false;
  const closeThinkingIfOpen = (): void => {
    if (!thinkingOpen) return;
    thinkingOpen = false;
    dispatcher.notify(RPCMethod.uiThinking, { sessionId, turnId, kind: "end" });
  };

  const publishContext = (messages: Message[]): void => {
    publishTurnContext({
      observer,
      sessionId,
      turnId,
      model,
      effort,
      systemPrompt,
      messages,
    });
  };

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
      // Ambient injection. `buildOutboundMessages` returns the persisted
      // history plus a freshly-rendered `<ambient>...</ambient>` tail
      // (when any provider returned non-null). The ambient block rides
      // as a transient user-role message at the tail of the request —
      // it is NOT persisted into the Conversation, so the next round (or
      // a retry) recomputes it.
      //
      // Cache-control note: the sidecar does not yet plumb prompt-cache
      // markers (`cache_control: ephemeral` or equivalent) through any
      // provider. The current call surface (`streamSimple`) accepts a
      // plain `Message[]` with no per-message cache annotation. Appending
      // ambient at the tail therefore cannot break a cache layer that
      // does not exist. When provider-side caching lands, the marker
      // belongs on the LAST persisted message (the final entry of
      // `messages`, i.e. NOT the ambient tail) so the cached prefix stays
      // stable across rounds — ambient sits past that boundary and is
      // naturally outside the cached region.
      const messagesForRound = buildOutboundMessages(convo, session);

      // Dev-mode observability: capture the exact (systemPrompt, messages)
      // pair we are about to hand to the LLM, ambient tail included. Publish
      // BEFORE the network call so a Dev Mode window opened mid-turn always
      // sees the latest input, not a stale snapshot.
      publishContext(messagesForRound);

      const eventStream = streamSimple(
        model,
        {
          systemPrompt,
          messages: messagesForRound,
          tools: toolSpecs.length > 0 ? toolSpecs : undefined,
        },
        { signal, reasoning: effort },
      );

      let final: AssistantMessage | undefined;
      let bailed = false;
      for await (const ev of eventStream) {
        if (signal.aborted) {
          bailed = true;
          break;
        }
        if (ev.type === "thinking_delta") {
          thinkingOpen = true;
          dispatcher.notify(RPCMethod.uiThinking, {
            sessionId,
            turnId,
            kind: "delta",
            delta: ev.delta,
          });
        } else if (ev.type === "thinking_end") {
          closeThinkingIfOpen();
        } else if (ev.type === "text_delta") {
          // Dual write: durable Conversation first, then streaming notify.
          // The boolean tells us whether the turn still exists — false means
          // it was wiped by `agent.reset` / advanced past by `agent.cancel`,
          // which is the only legitimate race. In that case we MUST NOT emit
          // a `ui.token` for a turn the Shell mirror has already dropped.
          if (convo.appendDelta(turnId, ev.delta)) {
            dispatcher.notify(RPCMethod.uiToken, { sessionId, turnId, delta: ev.delta });
          }
        } else if (ev.type === "toolcall_end") {
          // Validate up-front so the wire's `called` vs `rejected` decision
          // is made before the notification fires. The Shell's strict per-
          // phase invariant says `called` only ships validated args; sending
          // raw args here would leak unverified shapes into the UI's tool
          // presenter and drift the contract.
          const outcome = prepareToolCall(ev.toolCall, toolByName);
          callOutcomes.set(ev.toolCall.id, outcome);
          if (outcome.kind === "ready") {
            dispatcher.notify(RPCMethod.uiToolCall, {
              sessionId,
              turnId,
              phase: "called",
              toolCallId: ev.toolCall.id,
              toolName: ev.toolCall.name,
              args: outcome.args as JSONValue,
            });
          } else {
            // `rejected` — handler will not run. Send the model's raw args so
            // the UI can show what was attempted, plus the validator's
            // message. The Shell mirror synthesizes a completed isError
            // record from this single frame.
            dispatcher.notify(RPCMethod.uiToolCall, {
              sessionId,
              turnId,
              phase: "rejected",
              toolCallId: ev.toolCall.id,
              toolName: ev.toolCall.name,
              args: (ev.toolCall.arguments ?? {}) as JSONValue,
              errorMessage: outcome.errorMessage,
            });
          }
        } else if (ev.type === "done") {
          final = ev.message;
        } else if (ev.type === "error") {
          const code = pickErrorCode(ev.error);
          const message = ev.error.errorMessage ?? "agent error";
          closeThinkingIfOpen();
          if (convo.setError(turnId, code, message)) {
            dispatcher.notify(RPCMethod.uiError, { sessionId, turnId, code, message });
            // Project typed auth invalidation to provider.statusChanged so the
            // Shell ProviderService flips to unauthenticated and the next
            // opened-state shows the onboard panel.
            if (ev.error.errorReason === "authInvalidated" && ev.error.errorProviderId) {
              dispatcher.notify(RPCMethod.providerStatusChanged, {
                providerId: ev.error.errorProviderId,
                state: "unauthenticated",
                reason: "authInvalidated",
                message,
              });
            }
          }
          dropQueuedSteer();
          return;
        }
      }

      if (bailed || signal.aborted) {
        // Cancellation path. `agent.cancel` already flipped the turn to
        // `cancelled` and the visible reply has been mirrored via ui.token.
        // Close the reasoning block (if any) and finalize the turn's slice
        // — we may have one or more completed assistant+toolResult rounds
        // ahead of this aborted stream that should stay in history; the
        // finalize step appends the interrupt marker so the next round
        // sees an explicit "user pressed stop" signal. No orphan tool_use
        // here because the in-flight round never reached `appendAssistant`,
        // but `finalizeCancellation` handles either case. Then surface
        // the terminal status; do NOT call `markDone` (we didn't complete
        // normally) and do NOT call `onDone` (turnCount stays put).
        closeThinkingIfOpen();
        convo.finalizeCancellation(turnId);
        dropQueuedSteer();
        dispatcher.notify(RPCMethod.uiStatus, { sessionId, turnId, status: "done" });
        return;
      }

      if (!final) {
        // Stream ended without a `done` event — provider bug. Treat as
        // internal error rather than silently dropping the turn.
        closeThinkingIfOpen();
        const message = "stream ended without a final assistant message";
        if (convo.setError(turnId, RPCErrorCode.internalError, message)) {
          dispatcher.notify(RPCMethod.uiError, {
            sessionId,
            turnId,
            code: RPCErrorCode.internalError,
            message,
          });
        }
        dropQueuedSteer();
        return;
      }

      if (isContextOverflow(final, model.contextWindow)) {
        // Allocated agent.* segment (-32300 ~ -32399) per rpc-protocol.md.
        // contextOverflow = -32300; distinguishes overflow from generic
        // internal faults so the Shell error UI can render a tailored message.
        closeThinkingIfOpen();
        if (convo.setError(turnId, RPCErrorCode.agentContextOverflow, "Context too long")) {
          dispatcher.notify(RPCMethod.uiError, {
            sessionId,
            turnId,
            code: RPCErrorCode.agentContextOverflow,
            message: "Context too long",
          });
        }
        dropQueuedSteer();
        return;
      }

      // Persist the assistant message into the flat history regardless of
      // whether it carries tool calls or not, and record the provider usage
      // figure at the same transcript seam for the next auto-compact check.
      if (!convo.appendAssistantRound(turnId, final)) {
        // Turn was reset/cancelled mid-flight. Silently drop the message —
        // matches the appendDelta race policy.
        dropQueuedSteer();
        return;
      }

      // Surface usage to the Shell composer's context-usage ring. Fired
      // PER round (not once per turn) so multi-round tool flows show the
      // window fill incrementally — see UIUsageParams. We deliberately emit
      // after `appendAssistant` so the wire ordering matches the durable
      // store: the assistant message exists before its usage frame lands.
      dispatcher.notify(RPCMethod.uiUsage, {
        sessionId,
        turnId,
        inputTokens: final.usage.input,
        outputTokens: final.usage.output,
        cacheReadTokens: final.usage.cacheRead,
        cacheWriteTokens: final.usage.cacheWrite,
        totalTokens: final.usage.totalTokens,
        contextWindow: model.contextWindow,
        modelId: model.id,
      });

      const toolCalls = extractToolCalls(final);

      if (toolCalls.length === 0) {
        // Terminal: model produced text-only output. Ask Shell to stop any
        // app session, mark done, republish the dev snapshot so the post-call
        // view includes the assistant turn (and a fresh ambient tail
        // reflecting any state changes), then fire the visible-status closer.
        if (session.computerUseAppSession) {
          await dispatcher.request(
            RPCMethod.computerUseStopAppSession,
            { pid: session.computerUseAppSession.pid },
          );
          session.clearComputerUseAppSession();
        }
        const ok = convo.markDone(turnId);
        publishContext(buildOutboundMessages(convo, session));
        closeThinkingIfOpen();
        dispatcher.notify(RPCMethod.uiStatus, { sessionId, turnId, status: "done" });
        if (ok) params.onDone?.();
        if (activateQueuedSteer(true)) {
          consecutiveSilentToolRounds = 0;
          session.setSilentToolRounds(0);
          continue;
        }
        return;
      }

      // Update the consecutive-silent-tool-round counter. Visible text in
      // the round just streamed proves the assistant is still narrating
      // progress to the user — reset and let the loop continue. Thinking
      // blocks are deliberately ignored: silent reasoning between tool
      // bursts is the exact failure mode this cap exists to break.
      const spokeThisRound = assistantSpoke(final);
      if (spokeThisRound) {
        consecutiveSilentToolRounds = 0;
      } else {
        consecutiveSilentToolRounds++;
      }
      session.setSilentToolRounds(consecutiveSilentToolRounds);
      if (consecutiveSilentToolRounds > MAX_CONSECUTIVE_TOOL_ROUNDS) {
        closeThinkingIfOpen();
        const overflowMsg = `tool-call budget exceeded (${MAX_CONSECUTIVE_TOOL_ROUNDS} consecutive tool rounds without assistant text)`;
        // Preserve the slice. The hard cap fires after the assistant
        // round just appended a tool-bearing message; if we returned now
        // the next user prompt would carry orphan `tool_use` blocks with
        // no matching `tool_result` and the provider would reject the
        // request. Synthesize aborted tool_result messages instead — the
        // tool calls executed during this turn (and the rounds that led
        // up to the cap) stay in history, which is the user's expectation
        // when they continue the conversation after seeing the limit hit.
        const stopText = `Stopped by system: tool-call budget exceeded (${MAX_CONSECUTIVE_TOOL_ROUNDS} consecutive tool calls without assistant text). Tell the user where you got and ask before continuing.`;
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
            dropQueuedSteer();
            return;
          }
          if (callOutcomes.get(tc.id)?.kind === "ready") {
            dispatcher.notify(RPCMethod.uiToolCall, {
              sessionId,
              turnId,
              phase: "result",
              toolCallId: tc.id,
              toolName: tc.name,
              isError: true,
              outputText: stopText,
            });
          }
        }
        if (convo.setError(turnId, RPCErrorCode.internalError, overflowMsg)) {
          dispatcher.notify(RPCMethod.uiError, {
            sessionId,
            turnId,
            code: RPCErrorCode.internalError,
            message: overflowMsg,
          });
        }
        dropQueuedSteer();
        return;
      }

      // Tool round. Switch the visible status so the Notch UI shows a
      // "waiting" affordance while tools execute. We also close any open
      // thinking block here — between rounds, reasoning ends and a fresh
      // trace will open on the next streamSimple call if the model resumes.
      closeThinkingIfOpen();
      convo.setStatus(turnId, "waiting");
      dispatcher.notify(RPCMethod.uiStatus, { sessionId, turnId, status: "waiting" });

      // Sequential execution per s02. Each tool gets the parent turn's
      // signal so `agent.cancel` propagates into long-running subprocesses.
      for (const tc of toolCalls) {
        if (signal.aborted) break;
        // toolcall_end always populates the outcome map for every emitted
        // call. A miss would mean the streaming loop dropped a tool call
        // event — surface it as a synthesized rejection so the model still
        // gets feedback rather than a silent gap in the transcript.
        const outcome = callOutcomes.get(tc.id) ?? {
          kind: "rejected" as const,
          errorMessage: `internal: missing call outcome for ${tc.id}`,
        };
        let result: ToolExecResult;
        if (outcome.kind === "rejected") {
          // Validation already failed; the wire `rejected` notification has
          // been sent. Skip the handler entirely but STILL appendToolResult
          // so the model sees the validator's message on the next round and
          // can self-correct. We do NOT emit a `result` notification — the
          // `rejected` frame is the terminal UI event for this call.
          result = {
            content: [{ type: "text", text: outcome.errorMessage }],
            isError: true,
          };
        } else {
          try {
            result = await runTool(outcome.handler, outcome.args, tc.name, {
              sessionId,
              turnId,
              toolCallId: tc.id,
              model,
              computerUseAppSession: session.computerUseAppSession,
              signal,
            });
          } catch (err) {
            // Unexpected handler throw → recoverable tool failure. Synthesize
            // an isError result so the loop continues and the slice stays
            // replayable (no orphan `tool_use` on retry). Logged so genuine
            // harness bugs are still observable.
            const message = err instanceof Error ? err.message : String(err);
            logger.error("tool execution threw", {
              sessionId,
              turnId,
              toolCallId: tc.id,
              toolName: tc.name,
              err: String(err),
            });
            result = {
              content: [{ type: "text", text: `Tool "${tc.name}" failed: ${message}` }],
              isError: true,
            };
          }
        }
        const toolResultMsg: ToolResultMessage = {
          role: "toolResult",
          toolCallId: tc.id,
          toolName: tc.name,
          content: result.content,
          isError: result.isError,
          timestamp: Date.now(),
        };
        if (!convo.appendToolResult(turnId, toolResultMsg)) {
          // Turn went away mid-tool. Drop the result and exit; the cancel
          // path already published its terminal events.
          dropQueuedSteer();
          return;
        }
        if (outcome.kind === "ready") {
          dispatcher.notify(RPCMethod.uiToolCall, {
            sessionId,
            turnId,
            phase: "result",
            toolCallId: tc.id,
            toolName: tc.name,
            isError: result.isError,
            outputText: renderToolResultForWire(result.content),
          });
          if (!result.isError && tc.name === "start_app_session") {
            session.setComputerUseAppSession({
              pid: outcome.args.pid as number,
              windowId: outcome.args.windowId as number,
            });
          } else if (!result.isError && tc.name === "stop_app_session") {
            session.clearComputerUseAppSession();
          }
        }
      }

      if (signal.aborted) {
        // Cancellation surfaced during tool execution. The for-loop above
        // breaks at the top of an iteration, so any tool we already
        // started has its result appended; tools we never iterated leave
        // orphan `tool_use` blocks on the assistant message that just
        // landed. Finalize the slice — synthesize cancelled tool_results
        // for those orphans and append the interrupt marker — before the
        // terminal status, otherwise the next round's request would carry
        // un-paired `tool_use` and the provider would reject it.
        convo.finalizeCancellation(turnId);
        dropQueuedSteer();
        dispatcher.notify(RPCMethod.uiStatus, { sessionId, turnId, status: "done" });
        return;
      }

      if (activateQueuedSteer()) {
        consecutiveSilentToolRounds = 0;
        session.setSilentToolRounds(0);
        continue;
      }

      // Loop back: the next round's `streamSimple` will see the appended
      // tool results in `llmMessages()` and either produce more tool calls
      // or a terminal text response. Open todos resurface automatically
      // through the ambient block at the top of the next iteration — no
      // counter, no reminder injection.
      convo.setStatus(turnId, "working");
      dispatcher.notify(RPCMethod.uiStatus, { sessionId, turnId, status: "working" });
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    logger.error("runTurn failed", { turnId, err: String(err) });
    closeThinkingIfOpen();
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
