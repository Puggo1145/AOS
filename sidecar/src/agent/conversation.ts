// Sidecar-owned conversation state.
//
// AOS Stage 0 runs a single global agent attached to the notch. The sidecar
// is the source of truth for everything the LLM needs to see across turns
// (the rolling Message[] history) AND for everything the Shell mirrors to
// render the conversation panel. Storing this on the Shell side led to two
// parallel sources of truth and an LLM that forgot every prior turn — moving
// it here per the architectural correction.
//
// Multi-session support is intentionally not built yet: we have one agent
// loop, one notch, one chat. When sessions land, this becomes keyed by
// sessionId; the public surface (turns, mutators, llmMessages) is designed
// so that switch is mechanical.

import type { Message, AssistantMessage } from "../llm/types";
import type {
  CitedContext,
  ConversationTurnWire,
  TurnStatus,
} from "../rpc/rpc-types";

export interface ConversationTurn {
  id: string;
  prompt: string;
  citedContext: CitedContext;
  reply: string;
  status: TurnStatus;
  errorMessage?: string;
  errorCode?: number;
  /// Milliseconds since epoch.
  startedAt: number;
  /// The final AssistantMessage handed back by the stream on `done`. Stored
  /// so `llmMessages()` can replay successful turns to the next request
  /// without rebuilding metadata (api/provider/model/usage).
  finalAssistant?: AssistantMessage;
}

export class Conversation {
  private _turns: ConversationTurn[] = [];

  get turns(): ReadonlyArray<ConversationTurn> {
    return this._turns;
  }

  /// Register a new turn under the caller-supplied id. Throws on duplicate
  /// id — callers (the agent.submit handler) should reject the request
  /// before reaching here.
  startTurn(input: { id: string; prompt: string; citedContext: CitedContext }): ConversationTurn {
    if (this._turns.some((t) => t.id === input.id)) {
      throw new Error(`turnId already in conversation: ${input.id}`);
    }
    const turn: ConversationTurn = {
      id: input.id,
      prompt: input.prompt,
      citedContext: input.citedContext,
      reply: "",
      status: "thinking",
      startedAt: Date.now(),
    };
    this._turns.push(turn);
    return turn;
  }

  appendDelta(turnId: string, delta: string): void {
    const t = this.findOrThrow(turnId);
    t.reply += delta;
  }

  setStatus(turnId: string, status: TurnStatus): void {
    const t = this.findOrThrow(turnId);
    t.status = status;
  }

  /// Mark a successful completion. Stores the final AssistantMessage so the
  /// next request can replay this turn into the LLM context verbatim.
  markDone(turnId: string, finalAssistant: AssistantMessage): void {
    const t = this.findOrThrow(turnId);
    t.status = "done";
    t.finalAssistant = finalAssistant;
    // The streamed `reply` and the AssistantMessage's text content should
    // already match; we don't re-derive `reply` from `content` to avoid an
    // ordering/race surprise if `appendDelta` and `markDone` arrive out of
    // step. The text the user reads is what was streamed.
  }

  setError(turnId: string, code: number, message: string): void {
    const t = this.findOrThrow(turnId);
    t.status = "error";
    t.errorCode = code;
    t.errorMessage = message;
  }

  reset(): void {
    this._turns = [];
  }

  /// Build the LLM-facing message list for the next request.
  ///
  /// Rules:
  ///   - A successful prior turn (status: "done") contributes both the user
  ///     message and the stored AssistantMessage. This is what carries
  ///     conversational memory across turns.
  ///   - The current in-flight turn (thinking/working/waiting) contributes
  ///     only its user message — its assistant reply hasn't been produced
  ///     yet.
  ///   - Errored / cancelled turns are skipped entirely. A failed request
  ///     shouldn't pollute the next attempt's context.
  llmMessages(): Message[] {
    const out: Message[] = [];
    for (const t of this._turns) {
      const isCurrent = t.status === "thinking" || t.status === "working" || t.status === "waiting";
      if (t.status === "done" || isCurrent) {
        out.push({ role: "user", content: t.prompt, timestamp: t.startedAt });
        if (t.status === "done" && t.finalAssistant) {
          out.push(t.finalAssistant);
        }
      }
    }
    return out;
  }

  /// Wire-format projection for `conversation.turnStarted` and any future
  /// snapshot endpoint. The internal `finalAssistant` is intentionally
  /// dropped — it's metadata for the LLM context, not for the UI.
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

  private findOrThrow(turnId: string): ConversationTurn {
    const t = this._turns.find((x) => x.id === turnId);
    if (!t) throw new Error(`unknown turnId: ${turnId}`);
    return t;
  }
}

/// Singleton: AOS Stage 0 has exactly one conversation. Tests can construct
/// throwaway `Conversation` instances and inject them via the loop's options.
export const conversation = new Conversation();
