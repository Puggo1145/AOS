// Compact orchestration.
//
// `compactConversation` is the single function both the auto-compact
// path (called from `runTurn` entry) and the future manual `/compact`
// RPC entry will invoke. It is intentionally indifferent to which entry
// path called it — breaker accounting and threshold gating are the
// caller's job (see `autoCompactIfNeeded` below for the auto-path
// wrapper).
//
// The shape of work:
//
//   1. Ask Conversation for the messages strictly preceding the active turn.
//      The active turn (the user's just-submitted prompt + anything the
//      agent has produced for it so far) is preserved verbatim and
//      re-anchored on top of the summary. Compacting INTO the active
//      turn would mean the user's fresh prompt gets folded into the
//      summary, which is both wasteful and confusing — the model would
//      see "[Compressed]\n\n... user just asked X ..." and then have to
//      re-process X.
//   2. Issue a non-streaming-ish summarization call: same `streamSimple`
//      machinery as the main loop, but with NO tools, the compact system
//      prompt, and the snapshot wrapped with a final user nudge. We
//      consume the stream ourselves and pluck out the assistant text.
//   3. Hand the summary to `Conversation.compact`, which atomically
//      replaces the message buffer and prunes `_turns` down to the
//      active turn alone.
//
// All errors propagate. The auto wrapper translates them into breaker
// failures; the future manual wrapper will surface them as RPC errors.

import { streamSimple, type AssistantMessage, type Api, type Message, type Model } from "../../llm";
import type { Session } from "../session/session";
import { COMPACT_FINAL_REQUEST, COMPACT_SYSTEM_PROMPT } from "./prompt";
import { compactBreaker } from "./breaker";

/// Auto-compact threshold. When the model's remaining context (i.e.
/// `model.contextWindow - convo.lastTotalTokens`) falls under this
/// many tokens at runTurn entry, the auto-compact path runs before
/// any LLM round of the new turn. 20K is a deliberate over-buffer:
/// a single tool result can easily be 4–8K, and we'd rather compact
/// one turn early than one turn too late and crash the round.
export const AUTO_COMPACT_REMAINING_THRESHOLD = 20_000;

export interface CompactResult {
  /// How many turns from the original `_turns` array got folded into
  /// the summary. Useful for logging / wire telemetry.
  compactedTurnCount: number;
  /// The raw summary text the LLM produced (without the `[Compressed]`
  /// prefix that `Conversation.compact` adds when it lays out the
  /// stored message). Exposed so callers can log / inspect.
  summary: string;
}

/// Returned from manual `compactConversation` when the session has no
/// history to compact (the user invoked `/compact` on a fresh or fully
/// reset session). Distinct from a thrown error so the RPC handler can
/// surface a documented no-op via `AgentCompactResult` rather than an
/// internal error.
export const COMPACT_NOOP_EMPTY = Symbol("compact-noop-empty");
export type CompactNoop = typeof COMPACT_NOOP_EMPTY;

/// Run a single compaction pass. Throws on:
///   - the active turn not being the conversation's last turn
///   - the active turn being the conversation's only turn (nothing to
///     compact yet — caller's threshold check should have prevented this)
///   - the LLM returning an error event or no usable text
///   - any transport / provider failure during the summarization stream
///
/// Auto callers wrap this with `autoCompactIfNeeded`. Manual callers
/// (future RPC) call this directly and translate exceptions into wire
/// errors.
export async function compactConversation(
  session: Session,
  model: Model<Api>,
  options?: { signal?: AbortSignal; mode?: "auto" | "manual" },
): Promise<CompactResult | CompactNoop> {
  const convo = session.conversation;
  const mode = options?.mode ?? "auto";

  // Source the history through `llmMessages()` rather than the raw
  // `_messages` buffer: that view prepends the preface, normalizes
  // cancelled turns (orphan tool_use filled + interrupt marker).
  //
  // Auto vs. manual scope:
  //   - Auto runs at runTurn entry. The last turn is the brand-new
  //     just-submitted prompt with no agent reply yet; we MUST preserve
  //     it verbatim and re-anchor the summary above it. Folding it in
  //     would discard the user's fresh prompt into a summary the model
  //     then has to re-process.
  //   - Manual runs from idle (no in-flight turn). EVERY turn is
  //     completed history that the user explicitly asked us to fold —
  //     preserving the last turn would mean "compact" silently leaves
  //     the most recent exchange untouched, which surprised the user.
  let priorMessages: Message[];
  let activeTurnId: string | null;
  if (mode === "manual") {
    const allFiltered = convo.llmMessages();
    if (allFiltered.length === 0) {
      // Documented no-op: `/compact` on an empty session shouldn't fail.
      // Caller (RPC handler) translates this to `AgentCompactResult`
      // with `compactedTurnCount` omitted and a `done` lifecycle.
      return COMPACT_NOOP_EMPTY;
    }
    priorMessages = allFiltered;
    activeTurnId = null;
  } else {
    const compactionInput = convo.activeTurnCompactionInput();
    if (!compactionInput) {
      if (!convo.hasActiveTurn()) {
        throw new Error("compactConversation: no active turn to compact around");
      }
      // No prior history (active turn is first) — nothing meaningful to
      // summarize.
      throw new Error("compactConversation: no prior history to compact");
    }
    priorMessages = compactionInput.priorMessages;
    activeTurnId = compactionInput.activeTurnId;
  }
  const summarizationInput: Message[] = [
    ...priorMessages,
    {
      role: "user",
      content: COMPACT_FINAL_REQUEST,
      timestamp: Date.now(),
    },
  ];

  const stream = streamSimple(
    model,
    {
      systemPrompt: COMPACT_SYSTEM_PROMPT,
      messages: summarizationInput,
      // No tools at all: the prompt forbids them, but we also do not
      // hand the spec list down so a misbehaving provider physically
      // cannot emit a tool_use block.
      tools: undefined,
    },
    { signal: options?.signal },
  );

  let final: AssistantMessage | undefined;
  for await (const ev of stream) {
    if (ev.type === "done") final = ev.message;
    else if (ev.type === "error") {
      const m = ev.error.errorMessage ?? "compaction stream error";
      throw new Error(`compactConversation: ${m}`);
    }
  }
  if (!final) throw new Error("compactConversation: stream ended without a final message");

  const summary = final.content
    .filter((c): c is { type: "text"; text: string } => c.type === "text")
    .map((c) => c.text)
    .join("\n")
    .trim();
  if (summary.length === 0) {
    throw new Error("compactConversation: model returned no summary text");
  }

  let result: { compactedTurnCount: number } | null;
  if (activeTurnId === null) {
    result = convo.compactAll(summary);
  } else {
    result = convo.compact(activeTurnId, summary);
    if (!result) {
      // `Conversation.compact` only returns null when the active turn
      // disappeared mid-flight (race with reset) or has no prior
      // history. Surface as an error rather than swallow.
      throw new Error("compactConversation: Conversation.compact rejected the apply");
    }
  }

  return { compactedTurnCount: result.compactedTurnCount, summary };
}

/// Auto-path wrapper. Returns the `CompactResult` when a compaction
/// actually ran, or `null` when it was skipped (no headroom problem,
/// breaker tripped, no prior history). Records breaker success / failure
/// on every non-skipped attempt.
///
/// The optional `onStart` callback fires AFTER all skip gates pass and
/// JUST BEFORE the LLM summarization call begins. Callers (the agent loop)
/// use it to emit the `ui.compact: started` lifecycle frame only on turns
/// where compaction will actually run — pairing the eventual `done` /
/// `failed` frame with a real start. Firing `started` unconditionally on
/// every turn (and then sending nothing on the skip case) leaves the Shell
/// hanging on a half-open lifecycle.
export async function autoCompactIfNeeded(
  session: Session,
  model: Model<Api>,
  options?: { signal?: AbortSignal; onStart?: () => void },
): Promise<CompactResult | null> {
  if (compactBreaker.isAutoDisabled(session.id)) return null;
  const remaining = model.contextWindow - session.conversation.lastTotalTokens;
  if (remaining > AUTO_COMPACT_REMAINING_THRESHOLD) return null;

  // No prior history → don't try (would throw). Conversation owns the
  // distinction between "first turn" and "manual compact preface plus
  // fresh active turn"; the auto wrapper only needs the yes/no.
  if (!session.conversation.hasActiveTurnCompactionInput()) return null;

  options?.onStart?.();
  try {
    const result = await compactConversation(session, model, { signal: options?.signal });
    compactBreaker.recordSuccess(session.id);
    // The auto path's own guards above ensure we never reach this with
    // truly empty history — but if `compactConversation` does return the
    // noop sentinel for any reason, normalize it to "skipped" rather
    // than leaking the symbol up the auto stack.
    if (result === COMPACT_NOOP_EMPTY) return null;
    return result;
  } catch (err) {
    compactBreaker.recordFailure(session.id);
    throw err;
  }
}
