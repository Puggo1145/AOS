// Agent-turn outbound prompt and Dev Mode projection.
//
// This module owns the exact prompt surface that leaves the agent turn:
// persisted conversation history plus a freshly-rendered ambient tail. The
// same message list is also projected into Dev Mode so the inspectable view
// matches what the model received.

import type { Api, Message, Model } from "../../llm";
import { ContextObserver } from "../context-observer";
import type { Conversation } from "../conversation";
import { renderAmbient } from "../ambient";
import type { Session } from "../session/session";

export function buildOutboundMessages(convo: Conversation, session: Session): Message[] {
  const base = convo.llmMessages();
  const ambient = renderAmbient(session);
  if (!ambient) return base;
  return [
    ...base,
    { role: "user", content: ambient, timestamp: Date.now() },
  ];
}

export function publishTurnContext(input: {
  observer: ContextObserver;
  sessionId: string;
  turnId: string;
  model: Model<Api>;
  effort: string | undefined;
  systemPrompt: string;
  messages: Message[];
}): void {
  input.observer.publish({
    capturedAt: Date.now(),
    sessionId: input.sessionId,
    turnId: input.turnId,
    modelId: input.model.id,
    providerId: input.model.provider,
    effort: input.effort ?? null,
    systemPrompt: input.systemPrompt,
    messagesJson: ContextObserver.renderMessages(input.messages),
  });
}
