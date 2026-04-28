// Conversation screenshot dedup tests.
//
// Concrete regression we are locking down: every `computer_use_get_app_state`
// tool result carries a base64 screenshot. The agent loop replays the full
// flat history on each round, so after N captures the next request to codex
// `/responses` ships N full PNGs. We observed two real failures from this:
//   1. The codex backend stalls — SSE stays open with no events, the loop's
//      `for await` hangs and the user sees the agent frozen on the last tool
//      call.
//   2. `dev.context.get` over JSON-RPC times out because the `messagesJson`
//      payload is huge.
//
// Fix: `Conversation.llmMessages()` keeps the screenshot only on the most
// recent `get_app_state` result per `(pid, windowId)`; older results have
// their image blocks replaced with a text placeholder. AX text + stateId
// stay intact so reasoning over earlier interactions still works.

import { test, expect } from "bun:test";
import { Conversation } from "../src/agent/conversation";
import type { AssistantMessage, ToolResultMessage } from "../src/llm";

const PNG_DATA = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=";
const PLACEHOLDER = "[screenshot omitted: superseded by a later capture for this window]";

function assistantWithGetAppStateCall(callId: string, pid: number, windowId: number): AssistantMessage {
  return {
    role: "assistant",
    content: [
      {
        type: "toolCall",
        id: callId,
        name: "computer_use_get_app_state",
        arguments: { pid, windowId, captureMode: "som" },
      },
    ],
    api: "openai-responses",
    provider: "chatgpt-plan",
    model: "gpt-5",
    usage: {
      input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
    },
    stopReason: "toolUse",
    timestamp: 1,
  };
}

function getAppStateResult(callId: string): ToolResultMessage {
  return {
    role: "toolResult",
    toolCallId: callId,
    toolName: "computer_use_get_app_state",
    content: [
      { type: "text", text: "AX tree summary…" },
      { type: "image", data: PNG_DATA, mimeType: "image/png" },
    ],
    isError: false,
    timestamp: 2,
  };
}

function seedTurnWithToolRoundtrip(
  convo: Conversation,
  turnId: string,
  prompt: string,
  rounds: Array<{ callId: string; pid: number; windowId: number }>,
) {
  convo.startTurn({ id: turnId, prompt, citedContext: {} });
  for (const r of rounds) {
    convo.appendAssistant(turnId, assistantWithGetAppStateCall(r.callId, r.pid, r.windowId));
    convo.appendToolResult(turnId, getAppStateResult(r.callId));
  }
  convo.markDone(turnId);
}

test("only the latest get_app_state result keeps its screenshot per (pid, windowId)", () => {
  const convo = new Conversation();
  seedTurnWithToolRoundtrip(convo, "T1", "look", [
    { callId: "call_a", pid: 100, windowId: 1 },
    { callId: "call_b", pid: 100, windowId: 1 },
    { callId: "call_c", pid: 100, windowId: 1 },
  ]);

  const msgs = convo.llmMessages();
  // 1 user + 3 (assistant + toolResult) = 7 messages
  expect(msgs).toHaveLength(7);

  const toolResults = msgs.filter((m): m is ToolResultMessage => m.role === "toolResult");
  expect(toolResults).toHaveLength(3);

  // First two: image stripped, replaced with placeholder text.
  for (const tr of toolResults.slice(0, 2)) {
    expect(tr.content.some((b) => b.type === "image")).toBe(false);
    expect(tr.content.some((b) => b.type === "text" && b.text === PLACEHOLDER)).toBe(true);
    // Original AX text preserved.
    expect(tr.content.some((b) => b.type === "text" && b.text === "AX tree summary…")).toBe(true);
  }
  // Latest keeps the image untouched.
  const latest = toolResults[2];
  const img = latest.content.find((b) => b.type === "image");
  expect(img).toBeDefined();
  expect(img && img.type === "image" && img.data).toBe(PNG_DATA);
});

test("dedup is keyed per (pid, windowId) — different windows keep their own latest", () => {
  const convo = new Conversation();
  seedTurnWithToolRoundtrip(convo, "T1", "two windows", [
    { callId: "call_w1_a", pid: 100, windowId: 1 },
    { callId: "call_w2_a", pid: 100, windowId: 2 },
    { callId: "call_w1_b", pid: 100, windowId: 1 },
    { callId: "call_w2_b", pid: 100, windowId: 2 },
  ]);

  const msgs = convo.llmMessages();
  const toolResultsById = new Map<string, ToolResultMessage>();
  for (const m of msgs) if (m.role === "toolResult") toolResultsById.set(m.toolCallId, m);

  // Earlier capture of each window: stripped.
  expect(toolResultsById.get("call_w1_a")!.content.some((b) => b.type === "image")).toBe(false);
  expect(toolResultsById.get("call_w2_a")!.content.some((b) => b.type === "image")).toBe(false);
  // Latest of each window: image kept.
  expect(toolResultsById.get("call_w1_b")!.content.some((b) => b.type === "image")).toBe(true);
  expect(toolResultsById.get("call_w2_b")!.content.some((b) => b.type === "image")).toBe(true);
});

test("dedup spans turns — earlier-turn captures get stripped once a later turn re-captures the same window", () => {
  const convo = new Conversation();
  seedTurnWithToolRoundtrip(convo, "T1", "first turn", [
    { callId: "old_call", pid: 7, windowId: 42 },
  ]);
  seedTurnWithToolRoundtrip(convo, "T2", "second turn", [
    { callId: "new_call", pid: 7, windowId: 42 },
  ]);

  const msgs = convo.llmMessages();
  const oldTr = msgs.find((m) => m.role === "toolResult" && m.toolCallId === "old_call") as ToolResultMessage;
  const newTr = msgs.find((m) => m.role === "toolResult" && m.toolCallId === "new_call") as ToolResultMessage;

  expect(oldTr.content.some((b) => b.type === "image")).toBe(false);
  expect(newTr.content.some((b) => b.type === "image")).toBe(true);
});

test("non-screenshot tool results pass through untouched even when adjacent to get_app_state", () => {
  // Sanity: the dedup is scoped to `computer_use_get_app_state`. A bash /
  // file / read result should never have its content rewritten.
  const convo = new Conversation();
  convo.startTurn({ id: "T1", prompt: "mixed", citedContext: {} });
  convo.appendAssistant("T1", {
    role: "assistant",
    content: [
      { type: "toolCall", id: "bash_1", name: "bash", arguments: { command: "ls" } },
    ],
    api: "openai-responses",
    provider: "chatgpt-plan",
    model: "gpt-5",
    usage: {
      input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
    },
    stopReason: "toolUse",
    timestamp: 1,
  });
  convo.appendToolResult("T1", {
    role: "toolResult",
    toolCallId: "bash_1",
    toolName: "bash",
    content: [{ type: "text", text: "file_a\nfile_b" }],
    isError: false,
    timestamp: 2,
  });
  convo.markDone("T1");

  const msgs = convo.llmMessages();
  const tr = msgs.find((m) => m.role === "toolResult") as ToolResultMessage;
  expect(tr.content).toEqual([{ type: "text", text: "file_a\nfile_b" }]);
});

test("history with a single get_app_state capture keeps its screenshot — there's nothing to supersede", () => {
  const convo = new Conversation();
  seedTurnWithToolRoundtrip(convo, "T1", "one shot", [
    { callId: "only_call", pid: 9, windowId: 9 },
  ]);
  const msgs = convo.llmMessages();
  const tr = msgs.find((m) => m.role === "toolResult") as ToolResultMessage;
  expect(tr.content.some((b) => b.type === "image")).toBe(true);
});
