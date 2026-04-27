// Conversation mutator boolean-return tests (P1.2).
//
// Documented race: after `agent.reset` (or `agent.cancel`), an in-flight
// stream may emit one more event before its AbortController propagates.
// The Conversation must signal "turn unknown" to the caller so the loop
// can suppress the matching `ui.*` notification — letting the Shell
// mirror diverge from sidecar truth would silently break the
// "sidecar owns agent state" boundary.

import { test, expect } from "bun:test";
import { Conversation } from "../src/agent/conversation";
import type { AssistantMessage } from "../src/llm";

function fakeFinal(): AssistantMessage {
  return {
    role: "assistant",
    content: [{ type: "text", text: "ok" }],
    api: "openai-responses",
    provider: "test",
    model: "fake",
    usage: {
      input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
    },
    stopReason: "stop",
    timestamp: 1,
  };
}

test("appendDelta returns true while the turn is alive, false after reset", () => {
  const c = new Conversation();
  c.startTurn({ id: "T1", prompt: "hi", citedContext: {} });

  expect(c.appendDelta("T1", "Hello")).toBe(true);
  expect(c.turns[0].reply).toBe("Hello");

  c.reset();
  expect(c.turns).toHaveLength(0);

  // Delta arriving after reset must be a clean no-op.
  expect(c.appendDelta("T1", " world")).toBe(false);
});

test("setStatus returns false for an unknown turnId without throwing", () => {
  const c = new Conversation();
  // No startTurn — turn never registered.
  expect(c.setStatus("ghost", "cancelled")).toBe(false);
});

test("markDone returns false after the turn has been wiped", () => {
  const c = new Conversation();
  c.startTurn({ id: "T1", prompt: "hi", citedContext: {} });
  c.reset();
  expect(c.markDone("T1")).toBe(false);
});

test("appendAssistant returns false after the turn has been wiped", () => {
  const c = new Conversation();
  c.startTurn({ id: "T1", prompt: "hi", citedContext: {} });
  c.reset();
  expect(c.appendAssistant("T1", fakeFinal())).toBe(false);
});

test("setError returns false after the turn has been wiped", () => {
  const c = new Conversation();
  c.startTurn({ id: "T1", prompt: "hi", citedContext: {} });
  c.reset();
  expect(c.setError("T1", -32603, "oops")).toBe(false);
});

test("startTurn still throws on duplicate id (programmer error, not race)", () => {
  // Duplicate ids are a contract violation by the caller, not a tolerated
  // race — must surface loud.
  const c = new Conversation();
  c.startTurn({ id: "T1", prompt: "hi", citedContext: {} });
  expect(() => c.startTurn({ id: "T1", prompt: "again", citedContext: {} })).toThrow();
});
