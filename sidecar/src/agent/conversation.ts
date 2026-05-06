// Sidecar-owned conversation state.
//
// Storage model (post tool-use refactor):
//   - `_messages` is the single flat LLM history — `Message[]` exactly as
//     the model sees it. user / assistant / toolResult interleave naturally
//     (one turn may contribute many messages once tool calls land).
//   - `_turns` carries wire/UI metadata: id, citedContext, status, the live
//     `reply` mirror for `ui.token`, and a `[messageStart, messageEnd)`
//     range pointing back into `_messages`. The range is the only link
//     between the two views, and it grows append-only as the loop pushes
//     messages during a turn.
//
// This was previously stored as `prompt + reply + finalAssistant` per turn —
// fine for one user/assistant pair but it falls apart once a turn produces
// `assistant(toolCall) → toolResult → assistant(toolCall) → ... → assistant(text)`.
// Going flat aligns with how every LLM SDK already models history and
// removes the awkward `intermediate` bucket.
//
// Mutator contract (P1.2):
//   Each mutator returns `boolean` — true when applied, false when the
//   `turnId` is unknown. "Unknown" is the documented race after `agent.reset`
//   or `agent.cancel`: the in-flight stream may emit one more delta between
//   the abort signal firing and the loop's next `signal.aborted` check, and
//   that emission must NOT be promoted to a `ui.*` notification.
//
// Concurrency assumption: turns inside one Conversation are processed
// sequentially. Two turns in flight at once on the same session would
// interleave message ranges incoherently. The agent.submit handler is the
// only producer and it is single-threaded per session in practice; if
// concurrent turns ever ship, this storage needs revisiting.

import type { Message, AssistantMessage, ToolCall, ToolResultMessage } from "../llm/types";
import type {
  CitedContext,
  ConversationTurnWire,
  TurnStatus,
} from "../rpc/rpc-types";
import { buildUserMessage } from "./prompt";

/// Synthetic user-role text appended at the end of a cancelled turn's slice.
/// Tells the next LLM round explicitly that the user pressed stop, rather
/// than letting it infer from a half-finished transcript. Kept terse so
/// it doesn't dominate prompt context, and stable so `finalizeCancellation`
/// can detect "already finalized" by comparing the last message.
const INTERRUPT_MARKER_TEXT =
  "[The user interrupted the conversation here.]";

export interface ConversationTurn {
  id: string;
  prompt: string;
  citedContext: CitedContext;
  /// Mirror of the assistant text streamed so far this turn — `ui.token`
  /// deltas accumulate here. Spans across multiple LLM rounds when tool
  /// calls happen mid-turn; the user sees the concatenation.
  reply: string;
  status: TurnStatus;
  errorMessage?: string;
  errorCode?: number;
  /// Milliseconds since epoch.
  startedAt: number;
  /// Half-open range into the parent Conversation's `_messages` array
  /// covering every message this turn produced (its user message and
  /// every assistant / toolResult appended during the loop).
  messageStart: number;
  messageEnd: number;
}

export class Conversation {
  private _turns: ConversationTurn[] = [];
  private _messages: Message[] = [];
  /// Pre-history messages produced by a manual `compactAll`. When the user
  /// folds every turn into a summary, `_turns` becomes empty but the
  /// LLM still needs the boundary + summary in its prompt — those live
  /// here. `llmMessages()` prepends this slot so the summary survives
  /// across new turns until the next compact pass overwrites/clears it.
  /// Auto-path `compact()` and `reset()` clear this slot.
  private _preface: Message[] = [];
  /// Most recent provider-reported `usage.totalTokens` value (= input +
  /// output + cacheRead + cacheWrite). Updated by the agent loop after
  /// every LLM round (via `recordTotalTokens`). The auto-compact
  /// threshold check reads this — `contextWindow - lastTotalTokens` is
  /// our running estimate of next-turn headroom. We deliberately use the
  /// *total* and not just `usage.input` because:
  ///   - `input` excludes cacheRead/cacheWrite — for any provider with
  ///     prompt caching ON, `input` is just the uncached delta and
  ///     drastically underestimates how full the prompt actually was.
  ///   - The assistant `output` we just got was appended into the flat
  ///     history; the next request's prompt will include those tokens
  ///     too, so the right baseline for "how close to overflow next
  ///     time" is the full round total, not the prompt-only slice.
  /// Same value the Shell composer's context ring renders, by design —
  /// one notion of "context fill" across the system.
  /// A fresh session reads 0, which is intentional: the first turn never
  /// triggers compact because there's nothing to compact yet.
  private _lastTotalTokens = 0;

  get turns(): ReadonlyArray<ConversationTurn> {
    return this._turns;
  }

  /// Test / observability accessor — the raw flat history. Loop callers
  /// should go through `llmMessages()` so the preface is prepended and
  /// stale screenshots are stripped.
  get messages(): ReadonlyArray<Message> {
    return this._messages;
  }

  /// Provider-reported total-token count from the most recent LLM round
  /// (input + output + cacheRead + cacheWrite), or 0 if no round has
  /// completed yet. See `_lastTotalTokens` for why this is the right
  /// figure for the auto-compact threshold check.
  get lastTotalTokens(): number {
    return this._lastTotalTokens;
  }

  /// Capture the total-token figure from a completed round's usage frame.
  /// The loop fires once per round; later rounds simply overwrite.
  recordTotalTokens(n: number): void {
    if (Number.isFinite(n) && n >= 0) this._lastTotalTokens = n;
  }

  /// Register a new turn under the caller-supplied id and append its user
  /// message to the flat history. Throws on duplicate id — callers (the
  /// agent.submit handler) should reject the request before reaching here.
  startTurn(input: { id: string; prompt: string; citedContext: CitedContext }): ConversationTurn {
    if (this._turns.some((t) => t.id === input.id)) {
      throw new Error(`turnId already in conversation: ${input.id}`);
    }
    const startedAt = Date.now();
    const start = this._messages.length;
    this._messages.push(
      buildUserMessage({
        prompt: input.prompt,
        citedContext: input.citedContext,
        startedAt,
      }),
    );
    const turn: ConversationTurn = {
      id: input.id,
      prompt: input.prompt,
      citedContext: input.citedContext,
      reply: "",
      status: "working",
      startedAt,
      messageStart: start,
      messageEnd: this._messages.length,
    };
    this._turns.push(turn);
    return turn;
  }

  /// Append streamed assistant text to the visible reply mirror. Returns
  /// `false` when the turn no longer exists (post-reset/cancel race);
  /// callers must NOT emit a matching `ui.token` in that case. This does
  /// NOT touch `_messages` — the assistant's complete `AssistantMessage`
  /// is appended once via `appendAssistant` when the LLM round finishes.
  appendDelta(turnId: string, delta: string): boolean {
    const t = this.find(turnId);
    if (!t) return false;
    t.reply += delta;
    return true;
  }

  /// Push a complete assistant message produced by the current LLM round
  /// into the flat history and extend the turn's range. Used for both
  /// intermediate tool-call rounds and the final response.
  appendAssistant(turnId: string, msg: AssistantMessage): boolean {
    const t = this.find(turnId);
    if (!t) return false;
    this._messages.push(msg);
    t.messageEnd = this._messages.length;
    return true;
  }

  /// Append a completed assistant round and record the usage figure that
  /// future auto-compaction reads. This keeps the transcript mutation and
  /// token-accounting invariant at the Conversation seam instead of requiring
  /// every caller to remember the ordering.
  appendAssistantRound(turnId: string, msg: AssistantMessage): boolean {
    if (!this.appendAssistant(turnId, msg)) return false;
    this.recordTotalTokens(msg.usage.totalTokens);
    return true;
  }

  /// Push a tool-result message produced by executing one of the
  /// assistant's tool calls.
  appendToolResult(turnId: string, msg: ToolResultMessage): boolean {
    const t = this.find(turnId);
    if (!t) return false;
    this._messages.push(msg);
    t.messageEnd = this._messages.length;
    return true;
  }

  setStatus(turnId: string, status: TurnStatus): boolean {
    const t = this.find(turnId);
    if (!t) return false;
    t.status = status;
    return true;
  }

  /// Mark a successful completion. The final AssistantMessage was already
  /// pushed via `appendAssistant`; this only flips status.
  markDone(turnId: string): boolean {
    const t = this.find(turnId);
    if (!t) return false;
    t.status = "done";
    return true;
  }

  setError(turnId: string, code: number, message: string): boolean {
    const t = this.find(turnId);
    if (!t) return false;
    t.status = "error";
    t.errorCode = code;
    t.errorMessage = message;
    return true;
  }

  /// Finalize a user-cancelled turn so its slice stays in `llmMessages()`
  /// without breaking provider invariants. Two pieces:
  ///
  ///   1. Synthesize "Cancelled by user" tool_results for every orphan
  ///      tool_use in the turn's slice. Cancellation can fire mid
  ///      tool-loop, leaving the assistant's `tool_use` blocks for tools
  ///      the loop never got to execute — sending the slice to the
  ///      provider as-is would error (orphan tool_use without tool_result).
  ///
  ///   2. Append a synthetic user-role marker so the next round sees an
  ///      explicit "the user interrupted here" signal instead of a silently
  ///      truncated transcript. Without this the model would keep going as
  ///      if its previous reply was fine.
  ///
  /// Idempotent: a second call (e.g. cancel handler raced the loop's
  /// terminal site) is a no-op. Safe to call without first calling
  /// `setStatus("cancelled")` — the method flips status itself.
  finalizeCancellation(turnId: string): boolean {
    const t = this.find(turnId);
    if (!t) return false;
    if (this.hasInterruptMarker(t)) {
      t.status = "cancelled";
      return true;
    }

    const toolUses = new Map<string, ToolCall>();
    const haveResultFor = new Set<string>();
    for (let i = t.messageStart; i < t.messageEnd; i++) {
      const m = this._messages[i]!;
      if (m.role === "assistant") {
        for (const c of m.content) {
          if (c.type === "toolCall") toolUses.set(c.id, c);
        }
      } else if (m.role === "toolResult") {
        haveResultFor.add(m.toolCallId);
      }
    }

    const now = Date.now();
    for (const [id, tc] of toolUses) {
      if (haveResultFor.has(id)) continue;
      const cancelled: ToolResultMessage = {
        role: "toolResult",
        toolCallId: id,
        toolName: tc.name,
        content: [{ type: "text", text: "Cancelled by user" }],
        isError: true,
        timestamp: now,
      };
      this._messages.push(cancelled);
      t.messageEnd = this._messages.length;
    }

    this._messages.push({
      role: "user",
      content: INTERRUPT_MARKER_TEXT,
      timestamp: now,
    });
    t.messageEnd = this._messages.length;
    t.status = "cancelled";
    return true;
  }

  private hasInterruptMarker(t: ConversationTurn): boolean {
    if (t.messageEnd <= t.messageStart) return false;
    const last = this._messages[t.messageEnd - 1]!;
    return (
      last.role === "user" &&
      typeof last.content === "string" &&
      last.content === INTERRUPT_MARKER_TEXT
    );
  }

/// Compact-replace history. Called after the LLM has produced a summary
  /// of all messages strictly preceding the current (last) turn.
  ///
  /// Result shape — `_messages = [boundary, summary, ...currentSlice]`:
  ///   - `boundary` is a synthetic user-role message carrying compaction
  ///     metadata (timestamp + count of compacted turns) so the model can
  ///     recognize "history was just summarized" from context alone, even
  ///     without external signals.
  ///   - `summary` is a user-role message with the LLM-generated summary,
  ///     prefixed `[Compressed]` to mark it as historical reference rather
  ///     than a fresh user prompt.
  ///   - `currentSlice` is the active turn's existing slice, untouched.
  ///
  /// `_turns` is pruned down to just the active turn with its range
  /// re-anchored at index 2. Past turns are dropped entirely — both from
  /// the LLM view and the wire view. Callers that care about UI
  /// continuity should fire whatever wire notification their Shell
  /// expects after this returns.
  ///
  /// Returns `false` if the active turn is unknown or not the last turn —
  /// the single-active-turn invariant of the loop guarantees the latter
  /// in production paths. Returns `false` and does nothing when there is
  /// nothing to compact (the active turn IS the first turn — no prior
  /// history exists yet).
  compact(
    activeTurnId: string,
    summaryText: string,
  ): { compactedTurnCount: number } | null {
    const idx = this._turns.findIndex((t) => t.id === activeTurnId);
    if (idx === -1) return null;
    if (idx !== this._turns.length - 1) {
      throw new Error(`compact requires ${activeTurnId} to be the last turn`);
    }
    if (idx === 0 && this._turns[0]!.messageStart === 0 && this._preface.length === 0) {
      // Active turn is the first turn AND there is no prior preface to
      // re-summarize. With a preface present (e.g. after a manual
      // compactAll), the auto path may legitimately want to fold the
      // preface plus the active turn into a fresh summary.
      return null;
    }

    const activeTurn = this._turns[idx]!;
    const currentSlice = this._messages.slice(activeTurn.messageStart, activeTurn.messageEnd);
    const compactedTurnCount = idx; // turns 0..idx-1 get folded into the summary
    const now = Date.now();

    const boundary: Message = {
      role: "user",
      content:
        `<compactionBoundary turns="${compactedTurnCount}" at="${new Date(now).toISOString()}" />`,
      timestamp: now,
    };
    const summary: Message = {
      role: "user",
      content: `[Compressed]\n\n${summaryText}`,
      timestamp: now,
    };

    this._messages = [boundary, summary, ...currentSlice];
    // The new boundary + summary subsume any prior compactAll preface;
    // the previous summary text was already part of `priorMessages` via
    // `llmMessages()` and got folded into the new summary.
    this._preface = [];
    // The active turn now owns the boundary + summary as part of its
    // slice. Conceptually those two messages are pre-history, not
    // produced by this turn; the alternative (a synthetic
    // "compaction" turn at index 0) requires extra wire shape and
    // brings little value at v1. Folding into the active turn keeps
    // every message inside some range, so `llmMessages()` continues
    // to emit them. Wire-side, the turn's `prompt` / `reply` fields
    // are unchanged — the compaction prefix is invisible to the UI.
    activeTurn.messageStart = 0;
    activeTurn.messageEnd = 2 + currentSlice.length;
    this._turns = [activeTurn];
    return { compactedTurnCount };
  }

  reset(): void {
    this._turns = [];
    this._messages = [];
    this._preface = [];
    this._lastTotalTokens = 0;
  }

  /// True iff there is any LLM-visible content to summarize: at least
  /// one turn, or a non-empty preface from a prior compactAll pass. Used
  /// by both auto and manual entry points to gate "no prior history"
  /// early-out vs. an LLM call that would throw on empty input.
  /// Cancelled turns count — `finalizeCancellation` keeps their slice
  /// (user prompt + work done before the cancel + interrupt marker), all
  /// of which is meaningful context for the summarizer.
  hasContentToCompact(): boolean {
    if (this._preface.length > 0) return true;
    return this._turns.length > 0;
  }

  /// Manual-path counterpart to `compact()`. Folds EVERY turn (and any
  /// prior preface) into a single summary, leaving `_turns` empty and
  /// `_preface = [boundary, summary]`. The next `agent.submit` will
  /// append a fresh turn at `messageStart = 0`; `llmMessages()` keeps
  /// emitting the summary as pre-history until the next compact pass
  /// overwrites it.
  ///
  /// Returns the count of turns folded (0 if the conversation was
  /// already in a "preface only" state — a no-op compact-of-compact).
  compactAll(summaryText: string): { compactedTurnCount: number } {
    const compactedTurnCount = this._turns.length;
    const now = Date.now();
    const boundary: Message = {
      role: "user",
      content:
        `<compactionBoundary turns="${compactedTurnCount}" at="${new Date(now).toISOString()}" />`,
      timestamp: now,
    };
    const summary: Message = {
      role: "user",
      content: `[Compressed]\n\n${summaryText}`,
      timestamp: now,
    };
    this._preface = [boundary, summary];
    this._messages = [];
    this._turns = [];
    return { compactedTurnCount };
  }

  /// LLM-facing message list. ALL turns contribute their slice — including
  /// `cancelled` turns. A user-cancel earlier in the session should not
  /// erase the work that preceded the cancel point; instead
  /// `finalizeCancellation` rewrote the cancelled turn's slice to be
  /// replayable (orphan `tool_use` filled with synthetic results) and
  /// appended an explicit interrupt marker so the next round sees "the
  /// user pressed stop here" rather than a silently truncated transcript.
  /// Errored turns are kept too so a transient failure (network, 5xx,
  /// auth) doesn't wipe the prompt + pre-error progress on retry — the
  /// loop is responsible for keeping each preserved slice replayable.
  llmMessages(): Message[] {
    const out: Message[] = [...this._preface];
    for (const t of this._turns) {
      for (let i = t.messageStart; i < t.messageEnd; i++) {
        out.push(this._messages[i]);
      }
    }
    return stripStaleScreenshots(out);
  }

  /// Wire-format projection for `conversation.turnStarted` and the
  /// `session.activate` snapshot. Shell only renders prompt + visible
  /// reply per turn this round; tool-call detail flows over `ui.toolCall`
  /// notifications and is not (yet) reconstructable from this shape.
  static toWire(turn: ConversationTurn): ConversationTurnWire {
    return {
      id: turn.id,
      prompt: turn.prompt,
      citedContext: turn.citedContext,
      reply: turn.reply,
      status: turn.status,
      errorMessage: turn.errorMessage,
      errorCode: turn.errorCode,
      startedAt: turn.startedAt,
    };
  }

  private find(turnId: string): ConversationTurn | undefined {
    return this._turns.find((x) => x.id === turnId);
  }
}

/// Per (pid, windowId), keep the screenshot only on the most recent
/// `computer_use_get_app_state` tool result and strip image blocks from
/// every earlier result, replacing them with a text placeholder. Older
/// captures are dead context: the model only ever needs the latest view of
/// a window, and accumulated base64 PNGs were both (a) blowing past codex
/// `/responses` payload limits — symptom: SSE silently never returns —
/// and (b) making `dev.context.get` time out because the rendered context
/// payload was huge. AX text + stateId stay intact so the model can still
/// reason about earlier element interactions.
const STALE_SCREENSHOT_PLACEHOLDER =
  "[screenshot omitted: superseded by a later capture for this window]";

const GET_APP_STATE_TOOL = "computer_use_get_app_state";

function stripStaleScreenshots(messages: Message[]): Message[] {
  // 1) toolCallId → "pid:windowId" for every get_app_state call we can see
  //    in this history. A call with non-numeric pid/windowId (model
  //    hallucinated args) is just skipped — its result wasn't keyed and
  //    won't be touched, leaving any image alone.
  const keyByCallId = new Map<string, string>();
  for (const m of messages) {
    if (m.role !== "assistant") continue;
    for (const block of m.content) {
      if (block.type !== "toolCall") continue;
      const tc = block as ToolCall;
      if (tc.name !== GET_APP_STATE_TOOL) continue;
      const args = tc.arguments as Record<string, unknown> | undefined;
      const pid = args?.["pid"];
      const windowId = args?.["windowId"];
      if (typeof pid === "number" && typeof windowId === "number") {
        keyByCallId.set(tc.id, `${pid}:${windowId}`);
      }
    }
  }
  if (keyByCallId.size === 0) return messages;

  // 2) Latest tool-result index per key.
  const latestIdxByKey = new Map<string, number>();
  for (let i = 0; i < messages.length; i++) {
    const m = messages[i]!;
    if (m.role !== "toolResult") continue;
    const key = keyByCallId.get(m.toolCallId);
    if (key !== undefined) latestIdxByKey.set(key, i);
  }
  if (latestIdxByKey.size === 0) return messages;

  // 3) Strip images from every non-latest get_app_state tool result.
  return messages.map((m, i) => {
    if (m.role !== "toolResult") return m;
    const key = keyByCallId.get(m.toolCallId);
    if (key === undefined) return m;
    if (latestIdxByKey.get(key) === i) return m;
    const hasImage = m.content.some((b) => b.type === "image");
    if (!hasImage) return m;
    const newContent = m.content.map((b) =>
      b.type === "image"
        ? { type: "text" as const, text: STALE_SCREENSHOT_PLACEHOLDER }
        : b,
    );
    return { ...m, content: newContent } satisfies ToolResultMessage;
  });
}
