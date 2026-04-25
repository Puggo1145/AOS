// Agent turn loop — bridges `agent.submit` / `agent.cancel` / `agent.reset`
// to the sidecar's `Conversation` store and the `llm/` stream.
//
// Per docs/designs/rpc-protocol.md §"流式语义":
//   1. agent.submit Request returns { accepted: true } immediately. The actual
//      LLM streaming happens in a detached background task. *Before* the ack
//      we register the turn into the Conversation and broadcast
//      `conversation.turnStarted` so observers see the turn appear before any
//      streamed token.
//   2. While streaming, ui.token / ui.status / ui.error notifications are
//      pushed AND the matching turn in the Conversation is mutated in place.
//      This dual write is intentional: ui.token is the cheap streaming
//      transport (no full snapshot per character); the Conversation is the
//      durable store that drives the next request's LLM context.
//   3. agent.cancel triggers the per-turn AbortController; the stream loop
//      observes `signal.aborted`, breaks out, and emits `ui.status done`.
//   4. agent.reset aborts every live stream, wipes the Conversation, and
//      emits `conversation.reset` so observers can drop their mirrors.
//
// Per docs/designs/llm-provider.md §"包边界" the loop only depends on the
// public surface re-exported from `../llm`.

import { streamSimple, getDefaultModel, getModel, isContextOverflow, PROVIDER_IDS, DEFAULT_EFFORT, type AssistantMessage, type Model, type Api, type Effort } from "../llm";
import { readUserConfig } from "../config/storage";
import {
  RPCErrorCode,
  RPCMethod,
  type AgentSubmitParams,
  type AgentSubmitResult,
  type AgentCancelParams,
  type AgentCancelResult,
  type AgentResetResult,
} from "../rpc/rpc-types";
import { Dispatcher, RPCMethodError } from "../rpc/dispatcher";
import { turns, type TurnRegistry } from "./registry";
import { conversation as defaultConversation, Conversation } from "./conversation";
import { logger } from "../log";

const SYSTEM_PROMPT = "You are AOS, an AI agent embedded in macOS via the notch UI. Be concise and helpful.";

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

const defaultResolver: ModelResolver = () => {
  const cfg = readUserConfig();
  if (cfg.selection) {
    try {
      return getModel(cfg.selection.providerId, cfg.selection.modelId);
    } catch {
      // Selection points at a removed provider/model; fall through.
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
/// surfaced as a generic InternalError until the agent.* error segment
/// (-32300 ~ -32399) is finalized.
export function pickErrorCode(msg: AssistantMessage): number {
  if (msg.errorReason === "authInvalidated") return RPCErrorCode.permissionDenied;
  const text = msg.errorMessage ?? "";
  if (/auth|unauthorized|401|<authenticated>/i.test(text)) {
    return RPCErrorCode.permissionDenied;
  }
  return RPCErrorCode.internalError;
}

// ---------------------------------------------------------------------------
// Handler registration
// ---------------------------------------------------------------------------

export interface RegisterAgentOptions {
  /// Override the registry (tests use a private one to avoid leaking state).
  registry?: TurnRegistry;
  /// Override the conversation store (tests inject a fresh instance so each
  /// test starts from an empty history).
  conversation?: Conversation;
}

export function registerAgentHandlers(dispatcher: Dispatcher, opts: RegisterAgentOptions = {}): void {
  const reg = opts.registry ?? turns;
  const convo = opts.conversation ?? defaultConversation;

  dispatcher.registerRequest(RPCMethod.agentSubmit, async (raw): Promise<AgentSubmitResult> => {
    const params = raw as AgentSubmitParams;
    const { turnId, prompt, citedContext } = params;
    if (typeof turnId !== "string" || typeof prompt !== "string" || citedContext === undefined) {
      throw new RPCMethodError(RPCErrorCode.invalidParams, "agent.submit requires { turnId, prompt, citedContext }");
    }
    if (reg.get(turnId)) {
      throw new RPCMethodError(RPCErrorCode.invalidRequest, `turnId already active: ${turnId}`);
    }

    // Register the turn in the Conversation *before* the ack so any
    // observer that subscribes after seeing the ack still finds the turn
    // in the store. The notification is fired here too — it is part of the
    // submit ack contract, not an out-of-band signal.
    const turn = convo.startTurn({ id: turnId, prompt, citedContext });
    dispatcher.notify(RPCMethod.conversationTurnStarted, { turn: Conversation.toWire(turn) });

    const controller = reg.add(turnId);

    // Detached: ack must return inside agent.submit's 1s budget.
    void runTurn(dispatcher, convo, { turnId, signal: controller.signal })
      .catch((err) => logger.error("agent loop fatal", { turnId, err: String(err) }))
      .finally(() => reg.remove(turnId));

    return { accepted: true };
  });

  dispatcher.registerRequest(RPCMethod.agentCancel, async (raw): Promise<AgentCancelResult> => {
    const { turnId } = raw as AgentCancelParams;
    if (typeof turnId !== "string") {
      throw new RPCMethodError(RPCErrorCode.invalidParams, "agent.cancel requires { turnId }");
    }
    const cancelled = reg.abort(turnId);
    if (cancelled) {
      // Mark the turn so future llmMessages() builds know to skip it.
      // Wrapped in try/catch because the turn may already have transitioned
      // out of an active state by the time the cancel reaches us.
      try { convo.setStatus(turnId, "cancelled"); } catch { /* ignore */ }
    }
    return { cancelled };
  });

  dispatcher.registerRequest(RPCMethod.agentReset, async (): Promise<AgentResetResult> => {
    reg.abortAll();
    convo.reset();
    dispatcher.notify(RPCMethod.conversationReset, {});
    return { ok: true };
  });
}

// ---------------------------------------------------------------------------
// runTurn — exported for tests
// ---------------------------------------------------------------------------

export async function runTurn(
  dispatcher: Dispatcher,
  convo: Conversation,
  params: { turnId: string; signal: AbortSignal },
): Promise<void> {
  const { turnId, signal } = params;

  dispatcher.notify(RPCMethod.uiStatus, { turnId, status: "thinking" });

  let model: Model<Api>;
  try {
    model = modelResolver();
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    logger.error("model resolution failed", { turnId, err: String(err) });
    try { convo.setError(turnId, RPCErrorCode.internalError, message); } catch { /* ignore */ }
    dispatcher.notify(RPCMethod.uiError, {
      turnId,
      code: RPCErrorCode.internalError,
      message,
    });
    return;
  }

  // Effort: read the user's saved choice, fall back to catalog default.
  // Non-reasoning models drop effort entirely; the provider further clamps
  // (e.g. xhigh→high) per `clampReasoning` for models that don't support
  // the highest tier.
  const cfg = readUserConfig();
  const effort: Effort | undefined = model.reasoning ? (cfg.effort ?? DEFAULT_EFFORT) : undefined;

  try {
    // Pull the rolling LLM history from the Conversation. This is the
    // single change that gives the LLM cross-turn memory: prior successful
    // turns contribute their (user, assistant) pair; the just-started turn
    // contributes its user message; errored/cancelled turns are skipped.
    const eventStream = streamSimple(
      model,
      {
        systemPrompt: SYSTEM_PROMPT,
        messages: convo.llmMessages(),
      },
      { signal, reasoning: effort },
    );

    let final: AssistantMessage | undefined;
    for await (const ev of eventStream) {
      if (signal.aborted) break;
      if (ev.type === "text_delta") {
        // Dual write: append to the durable Conversation AND push the
        // streaming notification. See top-of-file note on why.
        try { convo.appendDelta(turnId, ev.delta); } catch { /* turn may have been wiped by reset */ }
        dispatcher.notify(RPCMethod.uiToken, { turnId, delta: ev.delta });
      } else if (ev.type === "done") {
        final = ev.message;
      } else if (ev.type === "error") {
        const code = pickErrorCode(ev.error);
        const message = ev.error.errorMessage ?? "agent error";
        try { convo.setError(turnId, code, message); } catch { /* ignore */ }
        dispatcher.notify(RPCMethod.uiError, {
          turnId,
          code,
          message,
        });
        // Project typed auth invalidation to provider.statusChanged so Shell
        // ProviderService flips to unauthenticated and the next opened-state
        // shows the onboard panel. Per docs/plans/onboarding.md "typed auth
        // error 传播": llm/ does not import dispatcher; the projection lives
        // here at the agent loop boundary.
        if (ev.error.errorReason === "authInvalidated" && ev.error.errorProviderId) {
          dispatcher.notify(RPCMethod.providerStatusChanged, {
            providerId: ev.error.errorProviderId,
            state: "unauthenticated",
            reason: "authInvalidated",
            message,
          });
        }
        return;
      }
    }

    if (final && isContextOverflow(final, model.contextWindow)) {
      try {
        convo.setError(turnId, RPCErrorCode.invalidParams, "Context too long");
      } catch { /* ignore */ }
      dispatcher.notify(RPCMethod.uiError, {
        turnId,
        // TBD: agent.* error segment (-32300 ~ -32399) per rpc-protocol.md
        // risk note. Until that's allocated, surface as InvalidParams so the
        // Shell-side error UI distinguishes it from a generic internal fault.
        code: RPCErrorCode.invalidParams,
        message: "Context too long",
      });
      return;
    }

    // Natural completion vs. cancellation:
    //   - natural: store the final AssistantMessage so the next request
    //     replays this turn into the LLM context.
    //   - cancellation: leave status in `cancelled` (set by agent.cancel) so
    //     llmMessages() skips it. We still emit `ui.status done` so the
    //     Notch UI reaches the same terminal emoji state.
    if (final && !signal.aborted) {
      try { convo.markDone(turnId, final); } catch { /* ignore */ }
    }
    dispatcher.notify(RPCMethod.uiStatus, { turnId, status: "done" });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    logger.error("runTurn failed", { turnId, err: String(err) });
    try { convo.setError(turnId, RPCErrorCode.internalError, message); } catch { /* ignore */ }
    dispatcher.notify(RPCMethod.uiError, {
      turnId,
      code: RPCErrorCode.internalError,
      message,
    });
  }
}
