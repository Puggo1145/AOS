// Errored-turn preservation contract.
//
// Bug fix: when a turn errored (network blip, provider 5xx, expired token,
// stalled stream), `Conversation.llmMessages()` used to filter the entire
// turn out — including the user's prompt and any successful pre-error work.
// The next prompt in the same session would silently start cold, defeating
// the obvious "just retry" recovery for transient infra faults.
//
// New contract:
//   - errored turns stay in `llmMessages()` (only `cancelled` is filtered)
//   - the agent loop owns the invariant that a preserved errored slice is
//     replayable: orphan `tool_use` blocks are repaired inline at the
//     dispatch site, and runaway tool-loop bailouts collapse the slice via
//     `collapseToReminder` before marking error
//
// These tests cover the Conversation-side guarantees in isolation; the loop
// integration is exercised by `agent-tool-loop.test.ts`.

import { test, expect } from "bun:test";
import { Conversation } from "../src/agent/conversation";
import type { AssistantMessage } from "../src/llm";

function fakeAssistantText(text: string): AssistantMessage {
  return {
    role: "assistant",
    content: [{ type: "text", text }],
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

test("llmMessages keeps errored turns so a retry resumes from where the failure landed", () => {
  const c = new Conversation();
  // Turn 1 — completes normally.
  c.startTurn({ id: "T1", prompt: "hello", citedContext: {} });
  c.appendAssistant("T1", fakeAssistantText("hi back"));
  c.markDone("T1");
  // Turn 2 — errors before the assistant message lands (e.g. stream-level
  // network failure). Slice is just the user prompt.
  c.startTurn({ id: "T2", prompt: "do thing", citedContext: {} });
  c.setError("T2", -32603, "ECONNRESET");

  // Both turns' user prompts are visible to the next LLM call. The errored
  // turn's prompt would have been silently dropped by the old filter.
  const msgs = c.llmMessages();
  expect(msgs).toHaveLength(3);
  expect(msgs[0].role).toBe("user");
  expect(msgs[1].role).toBe("assistant");
  expect(msgs[2].role).toBe("user");
  // Errored turn stayed marked as error (UI signal preserved).
  expect(c.turns[1].status).toBe("error");
});

test("llmMessages still drops cancelled turns", () => {
  // Cancellation is the user's explicit "abandon this work" signal — partial
  // streamed reply is dead context and must not leak into the next round.
  const c = new Conversation();
  c.startTurn({ id: "T1", prompt: "abandon me", citedContext: {} });
  c.appendDelta("T1", "half a reply");
  c.setStatus("T1", "cancelled");

  expect(c.llmMessages()).toEqual([]);
});

test("collapseToReminder replaces a runaway turn's slice with [user prompt, reminder]", () => {
  // Runaway tool-loop bailout path: 25+ silent assistant rounds plus a
  // pending orphan `tool_use` are dead weight on the next request. Collapsing
  // the slice keeps the original prompt visible (the user can still see what
  // they asked) and adds a reminder so the model knows why the previous
  // attempt was cut.
  const c = new Conversation();
  c.startTurn({ id: "T1", prompt: "loop forever", citedContext: {} });
  c.appendAssistant("T1", fakeAssistantText("noise round 1"));
  c.appendAssistant("T1", fakeAssistantText("noise round 2"));

  c.collapseToReminder("T1", "<reminder>previous attempt was cut</reminder>");

  const msgs = c.llmMessages();
  expect(msgs).toHaveLength(2);
  expect(msgs[0].role).toBe("user");
  expect(msgs[1].role).toBe("user");
  expect(msgs[1].content).toContain("previous attempt was cut");
});

test("collapseToReminder rejects non-last turns to protect message-range alignment", () => {
  // The collapse truncates `_messages` past the turn's user prompt; doing
  // that for a turn that isn't the last would shift every later turn's
  // [start, end) range out of alignment. The runaway-bailout caller is
  // always operating on the in-flight turn, which is by invariant the last.
  const c = new Conversation();
  c.startTurn({ id: "T1", prompt: "first", citedContext: {} });
  c.markDone("T1");
  c.startTurn({ id: "T2", prompt: "second", citedContext: {} });
  c.markDone("T2");

  expect(() =>
    c.collapseToReminder("T1", "should fail"),
  ).toThrow(/last turn/);
});
