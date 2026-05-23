import { expect, test } from "bun:test";
import {
  conversationSnapshotToWire,
  conversationTurnToWire,
  sessionToListItem,
} from "../src/agent/rpc-projection";
import { Session } from "../src/agent/session/session";

function appendEmptyAssistantAndMarkDone(session: Session, turnId: string, timestamp: number): void {
  session.conversation.appendAssistant(turnId, {
    role: "assistant",
    content: [],
    api: "openai-responses",
    provider: "test",
    model: "fake",
    usage: {
      input: 0,
      output: 0,
      cacheRead: 0,
      cacheWrite: 0,
      totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
    },
    stopReason: "stop",
    timestamp,
  });
  session.conversation.markDone(turnId);
}

test("sessionToListItem projects runtime session state to the session wire list shape", () => {
  const session = new Session({
    id: "sess_projection",
    title: "Projection Test",
    createdAt: 100,
  });

  expect(sessionToListItem(session)).toEqual({
    id: "sess_projection",
    title: "Projection Test",
    createdAt: 100,
    turnCount: 0,
    lastActivityAt: 100,
  });

  const first = session.conversation.startTurn({ id: "t1", prompt: "hello", citedContext: {} });
  expect(sessionToListItem(session).turnCount).toBe(0);

  appendEmptyAssistantAndMarkDone(session, first.id, first.startedAt);
  expect(sessionToListItem(session)).toEqual({
    id: "sess_projection",
    title: "Projection Test",
    createdAt: 100,
    turnCount: 1,
    lastActivityAt: first.startedAt,
  });
});

test("conversationTurnToWire projects only Shell-authoritative turn fields", () => {
  const session = new Session({
    id: "sess_projection",
    title: "Projection Test",
    createdAt: 100,
  });
  const turn = session.conversation.startTurn({
    id: "t1",
    prompt: "hello",
    citedContext: { app: { bundleId: "com.example.app", name: "Example", pid: 42 } },
  });
  session.conversation.appendDelta(turn.id, "hi");
  const current = session.conversation.turns[0]!;

  expect(conversationTurnToWire(current)).toEqual({
    id: "t1",
    prompt: "hello",
    citedContext: { app: { bundleId: "com.example.app", name: "Example", pid: 42 } },
    reply: "hi",
    status: "working",
    startedAt: turn.startedAt,
  });
});

test("conversationSnapshotToWire preserves runtime turn order for session.activate", () => {
  const session = new Session({
    id: "sess_projection",
    title: "Projection Test",
    createdAt: 100,
  });
  session.conversation.startTurn({ id: "t1", prompt: "first", citedContext: {} });
  session.conversation.startTurn({ id: "t2", prompt: "second", citedContext: {} });

  expect(conversationSnapshotToWire(session.conversation).map((turn) => turn.id)).toEqual(["t1", "t2"]);
});
