// SessionManager unit tests — verify the session abstraction in isolation,
// without spinning up a dispatcher.

import { test, expect } from "bun:test";
import { SessionManager } from "../src/agent/session/manager";
import type { SessionEvent } from "../src/agent/session/types";

test("create assigns a unique id and auto-activates", () => {
  const m = new SessionManager();
  const a = m.create();
  expect(a.id).toMatch(/^sess_[0-9a-f]{16}$/);
  expect(m.activeId).toBe(a.id);

  const b = m.create();
  expect(b.id).not.toBe(a.id);
  // create auto-activates the newly created session.
  expect(m.activeId).toBe(b.id);
});

test("sink fires created + activated on create, activated on activate", () => {
  const m = new SessionManager();
  const events: SessionEvent[] = [];
  m.setSink((e) => events.push(e));

  const a = m.create({ title: "first" });
  // Two events: created then activated, in that order.
  expect(events.map((e) => e.kind)).toEqual(["created", "activated"]);
  if (events[0].kind === "created") {
    expect(events[0].session.id).toBe(a.id);
    expect(events[0].session.title).toBe("first");
  }

  const b = m.create();
  // Two more for the second create.
  expect(events.map((e) => e.kind)).toEqual([
    "created",
    "activated",
    "created",
    "activated",
  ]);

  // Activate back to A: only one `activated` event, no spurious created.
  m.activate(a.id);
  expect(events.length).toBe(5);
  expect(events.at(-1)).toEqual({ kind: "activated", sessionId: a.id });

  // Re-activating the already-active id is a no-op — no extra event.
  m.activate(a.id);
  expect(events.length).toBe(5);
  void b;
});

test("activate throws on unknown sessionId", () => {
  const m = new SessionManager();
  m.create();
  expect(() => m.activate("sess_doesnotexist")).toThrow(/unknown sessionId/);
});

test("each session owns its own conversation + turn registry", () => {
  const m = new SessionManager();
  const a = m.create();
  const b = m.create();
  expect(a.conversation).not.toBe(b.conversation);
  expect(a.turns).not.toBe(b.turns);

  // Mutating a doesn't leak to b.
  a.conversation.startTurn({ id: "t1", prompt: "hi", citedContext: {} });
  expect(a.conversation.turns).toHaveLength(1);
  expect(b.conversation.turns).toHaveLength(0);
});

test("toListItem reflects current turnCount + lastActivityAt", () => {
  const m = new SessionManager();
  const s = m.create();
  const initial = s.toListItem();
  expect(initial.turnCount).toBe(0);
  expect(initial.lastActivityAt).toBe(initial.createdAt);

  // Spin up a turn and drive it to done — turnCount should pick up the +1.
  const t = s.conversation.startTurn({ id: "t1", prompt: "hi", citedContext: {} });
  expect(s.toListItem().turnCount).toBe(0); // still thinking
  s.conversation.appendAssistant(t.id, {
    role: "assistant",
    content: [],
    api: "openai-responses",
    provider: "test",
    model: "fake",
    usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
    stopReason: "stop",
    timestamp: t.startedAt,
  });
  s.conversation.markDone(t.id);
  const after = s.toListItem();
  expect(after.turnCount).toBe(1);
  expect(after.lastActivityAt).toBe(t.startedAt);
});

test("maybeDeriveTitle only fires while title is the default", () => {
  const m = new SessionManager();
  const s = m.create();
  // First derivation: clamps to ≤32 codepoints, takes first non-empty line.
  const derived = m.maybeDeriveTitle(s.id, "  \nFirst line — meaningful content here that is long enough to clip");
  expect(derived).toBe(true);
  expect(s.info.title.startsWith("First line —")).toBe(true);
  // Subsequent calls are no-ops.
  expect(m.maybeDeriveTitle(s.id, "another prompt")).toBe(false);

  // Pre-set title also blocks derivation.
  const t = m.create({ title: "manual" });
  expect(m.maybeDeriveTitle(t.id, "anything")).toBe(false);
});

test("title default falls back when first prompt has no non-empty line", () => {
  const m = new SessionManager();
  const s = m.create();
  m.maybeDeriveTitle(s.id, "   \n\n   "); // pure whitespace
  // Per design: "新对话" stays as the title — derivation only matters when
  // there is signal to derive from.
  expect(s.info.title).toBe("新对话");
});
