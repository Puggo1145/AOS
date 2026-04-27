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

import type { Message, AssistantMessage, ToolResultMessage } from "../llm/types";
import type {
  CitedContext,
  ConversationTurnWire,
  TurnStatus,
} from "../rpc/rpc-types";
import { buildUserMessage } from "./prompt";

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

  get turns(): ReadonlyArray<ConversationTurn> {
    return this._turns;
  }

  /// Test / observability accessor — the raw flat history. Loop callers
  /// should go through `llmMessages()` so cancelled/errored turns are
  /// filtered.
  get messages(): ReadonlyArray<Message> {
    return this._messages;
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
      status: "thinking",
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

  reset(): void {
    this._turns = [];
    this._messages = [];
  }

  /// Build the LLM-facing message list for the next request.
  ///
  /// Walks turns in order and pulls each turn's slice of `_messages`,
  /// skipping turns whose final status is `error` or `cancelled` — those
  /// shouldn't pollute the next attempt's context. In-flight turns
  /// (`thinking`/`working`/`waiting`) and successfully completed turns
  /// (`done`) both contribute their full message slice.
  llmMessages(): Message[] {
    const out: Message[] = [];
    for (const t of this._turns) {
      if (t.status === "error" || t.status === "cancelled") continue;
      for (let i = t.messageStart; i < t.messageEnd; i++) {
        out.push(this._messages[i]);
      }
    }
    return out;
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
