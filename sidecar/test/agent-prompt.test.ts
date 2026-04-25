// Conversation prompt assembly tests.
//
// Per P1.1 — proves that `citedContext` actually reaches the LLM via the
// rolling `Conversation.llmMessages()` projection. If this test ever
// regresses, the OS Sense Read loop has been broken in the sidecar again.

import { test, expect } from "bun:test";
import { Conversation } from "../src/agent/conversation";
import { formatCitedContext, buildUserMessage } from "../src/agent/prompt";
import type { CitedContext } from "../src/rpc/rpc-types";
import type { AssistantMessage } from "../src/llm";

function fullCitedContext(): CitedContext {
  return {
    app: { bundleId: "com.apple.Safari", name: "Safari", pid: 4242 },
    window: { title: "AOS — Notch agent", windowId: 987654 },
    behaviors: [
      {
        kind: "browser.tab",
        citationKey: "browser.tab",
        displaySummary: "AOS — Notch agent",
        payload: { url: "https://example.com/aos", pageTitle: "AOS — Notch agent" },
      },
    ],
    clipboard: { kind: "text", content: "hello clipboard" },
  };
}

test("buildUserMessage with empty CitedContext returns the bare prompt", () => {
  const msg = buildUserMessage({ prompt: "what's open?", citedContext: {}, startedAt: 1 });
  expect(msg.role).toBe("user");
  expect(msg.content).toBe("what's open?");
});

test("buildUserMessage prepends an <os-context> block when CitedContext has data", () => {
  const ctx = fullCitedContext();
  const msg = buildUserMessage({ prompt: "what's open?", citedContext: ctx, startedAt: 1 });
  expect(msg.role).toBe("user");
  const content = msg.content as string;
  // Block boundary tags so the LLM can split context from prompt.
  expect(content).toContain("<os-context>");
  expect(content).toContain("</os-context>");
  // App identity must be visible.
  expect(content).toContain("Safari");
  expect(content).toContain("com.apple.Safari");
  // Window title.
  expect(content).toContain("AOS — Notch agent");
  // Behavior kind + summary.
  expect(content).toContain("browser.tab");
  expect(content).toContain("AOS — Notch agent");
  // Opaque payload is JSON-serialized through.
  expect(content).toContain("https://example.com/aos");
  // Clipboard preview.
  expect(content).toContain("hello clipboard");
  // The user's prompt comes AFTER the context block.
  expect(content.indexOf("what's open?")).toBeGreaterThan(content.indexOf("</os-context>"));
});

test("formatCitedContext returns empty string for fully empty input", () => {
  expect(formatCitedContext({})).toBe("");
});

test("Conversation.llmMessages emits the cited context for the in-flight turn", () => {
  // Regression test for the original bug: prior implementation passed only
  // `t.prompt` to the LLM, so the agent never saw OS Sense data. Asserting
  // the projection by behavior summary keeps any future change honest.
  const convo = new Conversation();
  const ctx = fullCitedContext();
  convo.startTurn({ id: "T1", prompt: "describe the current tab", citedContext: ctx });

  const msgs = convo.llmMessages();
  expect(msgs).toHaveLength(1);
  expect(msgs[0].role).toBe("user");
  const content = (msgs[0] as { content: string }).content;
  expect(content).toContain("<os-context>");
  expect(content).toContain("browser.tab");
  expect(content).toContain("describe the current tab");
});

test("Conversation.llmMessages keeps the cited context on prior done turns", () => {
  // Replay across turns: the rolling history keeps each turn's context with
  // its user message so the LLM can disambiguate references like "that page".
  const convo = new Conversation();
  const ctx = fullCitedContext();
  convo.startTurn({ id: "T1", prompt: "first", citedContext: ctx });

  const fakeAssistant: AssistantMessage = {
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
  convo.markDone("T1", fakeAssistant);
  convo.startTurn({ id: "T2", prompt: "second", citedContext: {} });

  const msgs = convo.llmMessages();
  expect(msgs).toHaveLength(3);
  expect(msgs[0].role).toBe("user");
  expect((msgs[0] as { content: string }).content).toContain("<os-context>");
  expect((msgs[0] as { content: string }).content).toContain("first");
  expect(msgs[1].role).toBe("assistant");
  expect(msgs[2].role).toBe("user");
  // Second turn had empty citedContext → bare prompt only.
  expect((msgs[2] as { content: string }).content).toBe("second");
});
