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
  validateToolArguments,
  type AssistantMessage,
  type Model,
  type Api,
  type ToolCall,
  type ToolResultMessage,
  type ToolResultContent,
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
  type JSONValue,
} from "../rpc/rpc-types";
import { Dispatcher, RPCMethodError } from "../rpc/dispatcher";
import { TurnRegistry } from "./registry";
import { Conversation } from "./conversation";
import { contextObserver as defaultContextObserver, ContextObserver } from "./context-observer";
import { SessionManager } from "./session/manager";
import { toolRegistry, ToolUserError, type ToolHandler, type ToolExecResult } from "./tools";
import { buildSystemPrompt } from "./system-prompt";
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

    // Single-active-turn invariant. `Conversation` stores each turn's LLM
    // history as a contiguous `[messageStart, messageEnd)` range over a
    // shared `_messages` array; interleaving two turns on the same session
    // would let T1's range absorb T2's user message, producing duplicated /
    // cross-turn content on the next `llmMessages()`. The Shell currently
    // serializes user submits per session, but the sidecar RPC boundary must
    // hold its own invariant so any future caller (or a misbehaving Shell)
    // cannot corrupt the conversation store.
    if (reg.size > 0) {
      throw new RPCMethodError(
        RPCErrorCode.invalidRequest,
        `session ${session.id} already has an in-flight turn; cancel or wait before submitting another`,
      );
    }

    // Register the turn in the Conversation *before* the ack so any
    // observer that subscribes after seeing the ack still finds the turn
    // in the store. The notification is fired here too — it is part of the
    // submit ack contract, not an out-of-band signal.
    const turn = convo.startTurn({ id: turnId, prompt, citedContext });
    dispatcher.notify(RPCMethod.conversationTurnStarted, {
      sessionId: session.id,
      turn: Conversation.toWire(turn),
    });

    // First-prompt title derivation. listChanged covers both the title flip
    // and the lastActivityAt advance from createdAt → turn.startedAt.
    const titleChanged = manager.maybeDeriveTitle(session.id, prompt);
    if (titleChanged || convo.turns.length === 1) {
      manager.notifyListChanged();
    }

    const controller = reg.add(turnId);

    // Detached: ack must return inside agent.submit's 1s budget.
    void runTurn(dispatcher, convo, {
      sessionId: session.id,
      turnId,
      signal: controller.signal,
      observer,
      onDone: () => manager.notifyListChanged(),
    })
      .catch((err) => logger.error("agent loop fatal", { sessionId: session.id, turnId, err: String(err) }))
      .finally(() => reg.remove(turnId));

    return { accepted: true };
  });

  dispatcher.registerRequest(RPCMethod.agentCancel, async (raw): Promise<AgentCancelResult> => {
    const { sessionId, turnId } = (raw ?? {}) as AgentCancelParams;
    if (typeof turnId !== "string") {
      throw new RPCMethodError(RPCErrorCode.invalidParams, "agent.cancel requires { sessionId, turnId }");
    }
    const session = resolveSession(sessionId);
    const cancelled = session.turns.abort(turnId);
    if (cancelled) {
      // Mark the turn cancelled so future `llmMessages()` builds skip it.
      // The boolean return is an `unknown turnId` no-op — only happens if
      // the turn was concurrently reset, which is a tolerated race.
      session.conversation.setStatus(turnId, "cancelled");
    }
    return { cancelled };
  });

  dispatcher.registerRequest(RPCMethod.agentReset, async (raw): Promise<AgentResetResult> => {
    const { sessionId } = (raw ?? {}) as AgentResetParams;
    const session = resolveSession(sessionId);
    session.turns.abortAll();
    session.conversation.reset();
    dispatcher.notify(RPCMethod.conversationReset, { sessionId: session.id });
    // turnCount/lastActivityAt regress; surface to history list.
    manager.notifyListChanged();
    return { ok: true };
  });
}

// ---------------------------------------------------------------------------
// runTurn — exported for tests
// ---------------------------------------------------------------------------

export async function runTurn(
  dispatcher: Dispatcher,
  convo: Conversation,
  params: {
    sessionId: string;
    turnId: string;
    signal: AbortSignal;
    observer?: ContextObserver;
    /// Called when the turn lands in a terminal `done` state (post-`markDone`).
    /// Loop uses this to fire `session.listChanged` (turnCount + lastActivityAt
    /// changed). Errored / cancelled paths do not increment turnCount, so they
    /// don't invoke this hook.
    onDone?: () => void;
  },
): Promise<void> {
  const { sessionId, turnId, signal } = params;
  const observer = params.observer ?? defaultContextObserver;

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
  type CallOutcome =
    | { kind: "ready"; args: Record<string, unknown>; handler: ToolHandler<any, any> }
    | { kind: "rejected"; errorMessage: string };
  const callOutcomes = new Map<string, CallOutcome>();

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

  const publishContext = (): void => {
    observer.publish({
      capturedAt: Date.now(),
      sessionId,
      turnId,
      modelId: model.id,
      providerId: model.provider,
      effort: effort ?? null,
      systemPrompt,
      messagesJson: ContextObserver.renderMessages(convo.llmMessages()),
    });
  };

  try {
    // Counts tool rounds since the assistant last emitted visible text.
    // Reset on any round whose final AssistantMessage carries a non-empty
    // text content block; incremented on each tool-bearing round. When it
    // exceeds MAX_CONSECUTIVE_TOOL_ROUNDS the turn bails as a runaway loop.
    let consecutiveSilentToolRounds = 0;
    while (true) {
      const messages = convo.llmMessages();

      // Dev-mode observability: capture the exact (systemPrompt, messages)
      // pair we are about to hand to the LLM. Publish BEFORE the network
      // call so a Dev Mode window opened mid-turn always sees the latest
      // input, not a stale snapshot.
      publishContext();

      const eventStream = streamSimple(
        model,
        {
          systemPrompt,
          messages,
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
          return;
        }
      }

      if (bailed || signal.aborted) {
        // Cancellation path. `agent.cancel` already flipped the turn to
        // `cancelled` and the visible reply has been mirrored via ui.token.
        // Close the reasoning block (if any) and surface the terminal
        // status; do NOT call `markDone` (we didn't complete normally) and
        // do NOT call `onDone` (turnCount stays put).
        closeThinkingIfOpen();
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
        return;
      }

      // Persist the assistant message into the flat history regardless of
      // whether it carries tool calls or not. For tool-call rounds it is
      // the bridge to the next round; for the terminal round it is the
      // final reply.
      if (!convo.appendAssistant(turnId, final)) {
        // Turn was reset/cancelled mid-flight. Silently drop the message —
        // matches the appendDelta race policy.
        return;
      }

      const toolCalls = extractToolCalls(final);

      if (toolCalls.length === 0) {
        // Terminal: model produced text-only output. Mark done, republish
        // the dev snapshot so the post-call view includes the assistant
        // turn, then fire the visible-status closer.
        const ok = convo.markDone(turnId);
        publishContext();
        closeThinkingIfOpen();
        dispatcher.notify(RPCMethod.uiStatus, { sessionId, turnId, status: "done" });
        if (ok) params.onDone?.();
        return;
      }

      // Update the consecutive-silent-tool-round counter. Visible text in
      // the round just streamed proves the assistant is still narrating
      // progress to the user — reset and let the loop continue. Thinking
      // blocks are deliberately ignored: silent reasoning between tool
      // bursts is the exact failure mode this cap exists to break.
      const spokeThisRound = final.content.some(
        (c) => c.type === "text" && c.text.trim().length > 0,
      );
      if (spokeThisRound) {
        consecutiveSilentToolRounds = 0;
      } else {
        consecutiveSilentToolRounds++;
      }
      if (consecutiveSilentToolRounds > MAX_CONSECUTIVE_TOOL_ROUNDS) {
        closeThinkingIfOpen();
        const overflowMsg = `tool-call budget exceeded (${MAX_CONSECUTIVE_TOOL_ROUNDS} consecutive tool rounds without assistant text)`;
        if (convo.setError(turnId, RPCErrorCode.internalError, overflowMsg)) {
          dispatcher.notify(RPCMethod.uiError, {
            sessionId,
            turnId,
            code: RPCErrorCode.internalError,
            message: overflowMsg,
          });
        }
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
              signal,
            });
          } catch (err) {
            // `runTool` only re-throws unexpected exceptions (non-
            // ToolUserError). The wire already announced `phase: "called"`
            // for this id; without a terminal frame the Shell mirror would
            // leave the row stuck in `.calling` forever even after the
            // turn-level `ui.error` lands. Emit a closing `result` so the
            // tool row visibly fails, THEN re-throw so runTurn's top-level
            // catch fires `ui.error` and ends the turn — fail-fast intact.
            const message = err instanceof Error ? err.message : String(err);
            dispatcher.notify(RPCMethod.uiToolCall, {
              sessionId,
              turnId,
              phase: "result",
              toolCallId: tc.id,
              toolName: tc.name,
              isError: true,
              outputText: message,
            });
            throw err;
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
            outputText: renderResultForWire(result.content),
          });
        }
      }

      if (signal.aborted) {
        // Cancellation surfaced during tool execution. Close out the same
        // way as the streaming-cancel path above.
        dispatcher.notify(RPCMethod.uiStatus, { sessionId, turnId, status: "done" });
        return;
      }

      // Loop back: the next round's `streamSimple` will see the appended
      // tool results in `llmMessages()` and either produce more tool calls
      // or a terminal text response.
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
  }
}

// ---------------------------------------------------------------------------
// Tool dispatch
// ---------------------------------------------------------------------------

function extractToolCalls(msg: AssistantMessage): ToolCall[] {
  const out: ToolCall[] = [];
  for (const c of msg.content) {
    if (c.type === "toolCall") out.push(c);
  }
  return out;
}

interface ToolDispatchCtx {
  sessionId: string;
  turnId: string;
  toolCallId: string;
  model: Model<Api>;
  signal: AbortSignal;
}

/// Resolve a tool call's handler and validate its arguments without running
/// anything. Returns `ready` with the validated args + handler on success,
/// or `rejected` with a human-readable failure on missing-tool / schema
/// violation. The agent loop calls this at `toolcall_end` time so the wire
/// can decide between `ui.toolCall.called` and `ui.toolCall.rejected` before
/// the dispatch round even starts.
function prepareToolCall(
  call: ToolCall,
  byName: ReadonlyMap<string, ToolHandler<any, any>>,
):
  | { kind: "ready"; args: Record<string, unknown>; handler: ToolHandler<any, any> }
  | { kind: "rejected"; errorMessage: string } {
  const handler = byName.get(call.name);
  if (!handler) {
    const known = Array.from(byName.keys()).join(", ") || "<none>";
    return {
      kind: "rejected",
      errorMessage: `Unknown tool "${call.name}". Available tools: ${known}.`,
    };
  }
  try {
    const args = validateToolArguments(handler.spec, call) as Record<string, unknown>;
    return { kind: "ready", args, handler };
  } catch (err) {
    return {
      kind: "rejected",
      errorMessage: err instanceof Error ? err.message : String(err),
    };
  }
}

/// Run a pre-validated tool call. The args + handler come from
/// `prepareToolCall`; this function only owns the handler's runtime
/// behavior.
///
/// Error policy (P2-1, AGENTS.md fail-fast):
///   - Handler returns `{ isError: true }` → recoverable; surfaced to the
///     model as the tool's output.
///   - Handler throws `ToolUserError` → recoverable; same path, the message
///     becomes the model-visible text. Sugar for handlers that prefer
///     throwing over building the envelope.
///   - Handler throws anything else → harness/programmer fault. We RE-THROW
///     so `runTurn`'s top-level catch surfaces it as a `ui.error` (turn
///     terminates). Swallowing it would let a real bug masquerade as
///     model-correctable feedback and silently corrupt subsequent rounds.
async function runTool(
  handler: ToolHandler<any, any>,
  args: Record<string, unknown>,
  toolName: string,
  ctx: ToolDispatchCtx,
): Promise<ToolExecResult> {
  try {
    return await handler.execute(args, ctx);
  } catch (err) {
    if (err instanceof ToolUserError) {
      return {
        content: [{ type: "text", text: err.message }],
        isError: true,
      };
    }
    // Cancellation propagated through the tool. The dispatcher rejects
    // an aborted outbound request with a plain `Error("... aborted")`
    // — NOT an `RPCMethodError` — so the recoverable-error filter in
    // computer-use's `callCU` doesn't catch it and it would otherwise
    // bubble all the way to `runTurn`'s top-level catch, fire `ui.error`,
    // and mark the turn as failed. The user pressed cancel; that's not
    // an error. Return a closing frame so the toolCall row doesn't
    // dangle in `.calling`, and let the outer `if (signal.aborted)`
    // check in `runTurn` close the turn via `ui.status: done`.
    //
    // We trust the signal as the cancel oracle (not error message
    // string-matching): only convert when the signal is actually
    // aborted. Other transient I/O errors that happen to coincide with
    // a non-aborted signal still fail loudly.
    if (ctx.signal.aborted) {
      return {
        content: [{ type: "text", text: `${toolName} cancelled` }],
        isError: true,
      };
    }
    // Unexpected — let runTurn handle it. Annotate the message so the
    // ui.error surface still tells the user which tool blew up.
    const inner = err instanceof Error ? err : new Error(String(err));
    const wrapped = new Error(`Tool "${toolName}" threw: ${inner.message}`);
    (wrapped as Error & { cause?: unknown }).cause = inner;
    throw wrapped;
  }
}

/// Render a tool result's content blocks down to a single string for the
/// Shell's `ui.toolCall` notification. Concatenates text blocks and replaces
/// images with a placeholder — Shell renders raw text in the panel today,
/// and image bytes have no place on this notification (the model already
/// got them via the ToolResultMessage).
function renderResultForWire(content: ToolResultContent[]): string {
  const out: string[] = [];
  for (const c of content) {
    if (c.type === "text") out.push(c.text);
    else if (c.type === "image") out.push(`[image ${c.mimeType}]`);
  }
  return out.join("\n");
}

// Re-export for tests that touch llmMessages-derived behavior without
// caring about the broader surface.
export type { Message };
