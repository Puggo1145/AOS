// Errored-turn preservation contract.
//
// Bug fix: when a turn errored (network blip, provider 5xx, expired token,
// stalled stream), `Conversation.llmMessages()` used to filter the entire
// turn out — including the user's prompt and any successful pre-error work.
// The next prompt in the same session would silently start cold, defeating
// the obvious "just retry" recovery for transient infra faults.
//
// New contract:
//   - errored turns stay in `llmMessages()`; cancelled turns also stay,
//     but their slice is rewritten by `finalizeCancellation` (orphan
//     tool_use filled + interrupt marker appended)
//   - the agent loop owns the invariant that a preserved errored slice is
//     replayable: orphan `tool_use` blocks get synthesized aborted
//     `tool_result` messages inline, including the runaway tool-loop
//     bailout — the prior tool history is preserved so the user's next
//     prompt continues from real context, not from a wiped slice
//
// These tests cover the Conversation-side guarantees in isolation; the loop
// integration is exercised by `agent-tool-loop.test.ts`.

import { test, expect } from "bun:test";
import { Conversation } from "../src/agent/conversation";
import type { AssistantMessage, ToolResultMessage } from "../src/llm";

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

function fakeAssistantToolCall(id: string): AssistantMessage {
  return {
    role: "assistant",
    content: [{ type: "toolCall", id, name: "get_app_state", arguments: {} }],
    api: "openai-responses",
    provider: "test",
    model: "fake",
    usage: {
      input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
    },
    stopReason: "toolUse",
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

test("finalizeCancellation keeps the slice and appends an interrupt marker", () => {
  // Bug: dropping the entire cancelled turn erased completed pre-cancel
  // rounds, so the next prompt started cold. New behavior: the user
  // prompt and any completed assistant/toolResult rounds stay; the only
  // thing dropped is the in-flight (mid-stream) round, and a synthetic
  // user-role marker tells the next round the user pressed stop.
  const c = new Conversation();
  c.startTurn({ id: "T1", prompt: "abandon me", citedContext: {} });
  // Mid-stream cancel: streamed delta lives in t.reply only; nothing
  // assistant-side has been appended via appendAssistant yet.
  c.appendDelta("T1", "half a reply");
  c.finalizeCancellation("T1");

  expect(c.turns[0].status).toBe("cancelled");
  const msgs = c.llmMessages();
  // user prompt + interrupt marker
  expect(msgs).toHaveLength(2);
  expect(msgs[0].role).toBe("user");
  expect(msgs[1].role).toBe("user");
  expect(typeof msgs[1].content).toBe("string");
  expect(msgs[1].content as string).toContain("interrupted");
});

test("finalizeCancellation synthesizes cancelled tool_results for orphan tool_use", () => {
  // Cancel during tool execution: the assistant tool_use round was
  // appended, then some tools ran, others didn't. The unran ones leave
  // orphan tool_use blocks; the slice must stay replayable.
  const c = new Conversation();
  c.startTurn({ id: "T1", prompt: "do parallel work", citedContext: {} });
  const assistant: AssistantMessage = {
    role: "assistant",
    content: [
      { type: "toolCall", id: "tc_a", name: "tool_a", arguments: {} },
      { type: "toolCall", id: "tc_b", name: "tool_b", arguments: {} },
    ],
    api: "openai-responses",
    provider: "test",
    model: "fake",
    usage: {
      input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
    },
    stopReason: "toolUse",
    timestamp: 1,
  };
  c.appendAssistant("T1", assistant);
  // Only tool_a's result was produced before cancel.
  c.appendToolResult("T1", {
    role: "toolResult",
    toolCallId: "tc_a",
    toolName: "tool_a",
    content: [{ type: "text", text: "ok" }],
    isError: false,
    timestamp: 2,
  });
  c.finalizeCancellation("T1");

  const msgs = c.llmMessages();
  // user, assistant(tool_use × 2), toolResult(tc_a), toolResult(tc_b synth), user(marker)
  expect(msgs).toHaveLength(5);
  const synth = msgs[3];
  expect(synth.role).toBe("toolResult");
  expect((synth as ToolResultMessage).toolCallId).toBe("tc_b");
  expect((synth as ToolResultMessage).isError).toBe(true);
  expect(msgs[4].role).toBe("user");
  expect(msgs[4].content as string).toContain("interrupted");
});

test("finalizeCancellation is idempotent", () => {
  const c = new Conversation();
  c.startTurn({ id: "T1", prompt: "stop", citedContext: {} });
  c.finalizeCancellation("T1");
  const beforeLen = c.llmMessages().length;
  c.finalizeCancellation("T1");
  expect(c.llmMessages().length).toBe(beforeLen);
});

test("llmMessages keeps a fresh screenshot for the next round but strips it after an assistant consumes it", () => {
  const c = new Conversation();
  c.startTurn({ id: "T1", prompt: "inspect the app", citedContext: {} });
  c.appendAssistant("T1", fakeAssistantToolCall("tc_state"));
  c.appendToolResult("T1", {
    role: "toolResult",
    toolCallId: "tc_state",
    toolName: "get_app_state",
    content: [
      { type: "text", text: "<app_state>...</app_state>" },
      { type: "image", data: "large-screenshot-base64", mimeType: "image/png" },
    ],
    isError: false,
    timestamp: 2,
  });

  const nextRoundMessages = c.llmMessages();
  expect((nextRoundMessages[2] as ToolResultMessage).content.some((block) => block.type === "image")).toBe(true);

  c.appendAssistant("T1", fakeAssistantText("I read the screenshot."));
  c.markDone("T1");

  const replayMessages = c.llmMessages();
  const replayedToolResult = replayMessages[2] as ToolResultMessage;
  expect(replayedToolResult.content.some((block) => block.type === "image")).toBe(false);
  expect(c.messages[2]).toMatchObject({
    role: "toolResult",
    content: [
      { type: "text", text: "<app_state>...</app_state>" },
      { type: "image", data: "large-screenshot-base64", mimeType: "image/png" },
    ],
  });
});
