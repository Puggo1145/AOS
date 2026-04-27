// Tests for `transformMessages` covering image downgrade, thinking
// same-source preserve, thinking cross-source drop, toolCall id
// normalization with toolResult rewrite, orphan toolCall synthesis,
// and `error`/`aborted` assistant message dropping.

import { test, expect } from "bun:test";
import { transformMessages, normalizeOpenAIResponsesToolCallId } from "../src/llm/providers/transform-messages";
import type {
  AssistantMessage,
  ImageContent,
  Message,
  Model,
  TextContent,
  ThinkingContent,
  ToolCall,
  ToolResultMessage,
  UserMessage,
} from "../src/llm/types";

function makeModel(overrides: Partial<Model> = {}): Model {
  return {
    id: "gpt-5-2",
    name: "GPT-5.2",
    api: "openai-responses",
    provider: "chatgpt-plan",
    baseUrl: "https://example.test",
    reasoning: {
      efforts: [
        { value: "low", label: "Low" },
        { value: "medium", label: "Medium" },
        { value: "high", label: "High" },
        { value: "xhigh", label: "Extra High" },
      ],
      default: "medium",
    },
    input: ["text", "image"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 200_000,
    maxTokens: 16_384,
    ...overrides,
  };
}

function emptyAssistant(extras: Partial<AssistantMessage>): AssistantMessage {
  return {
    role: "assistant",
    content: [],
    api: "openai-responses",
    provider: "chatgpt-plan",
    model: "gpt-5-2",
    usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
    stopReason: "stop",
    timestamp: 0,
    ...extras,
  };
}

test("image downgraded when model lacks vision", () => {
  const model = makeModel({ input: ["text"] });
  const user: UserMessage = {
    role: "user",
    timestamp: 0,
    content: [
      { type: "image", data: "AAAA", mimeType: "image/png" } as ImageContent,
      { type: "image", data: "BBBB", mimeType: "image/png" } as ImageContent,
      { type: "text", text: "after" } as TextContent,
    ],
  };
  const out = transformMessages([user], model);
  const u = out[0] as UserMessage;
  expect(Array.isArray(u.content)).toBe(true);
  const arr = u.content as Array<TextContent | ImageContent>;
  // Two consecutive images should fold into a single placeholder, then text.
  expect(arr.length).toBe(2);
  expect(arr[0]!.type).toBe("text");
  expect(arr[1]!.type).toBe("text");
  expect((arr[1] as TextContent).text).toBe("after");
});

test("thinking same-source preserved verbatim", () => {
  const model = makeModel();
  const a = emptyAssistant({
    content: [{ type: "thinking", thinking: "deep", thinkingSignature: "sig" } as ThinkingContent],
  });
  const out = transformMessages([a], model);
  const ao = out[0] as AssistantMessage;
  const block = ao.content[0] as ThinkingContent;
  expect(block.type).toBe("thinking");
  expect(block.thinkingSignature).toBe("sig");
});

test("thinking cross-source downgraded to text", () => {
  const model = makeModel();
  const a = emptyAssistant({
    provider: "anthropic", api: "anthropic-messages", model: "claude-x",
    content: [{ type: "thinking", thinking: "from claude", thinkingSignature: "secret" } as ThinkingContent],
  });
  const out = transformMessages([a], model);
  const ao = out[0] as AssistantMessage;
  expect(ao.content.length).toBe(1);
  const block = ao.content[0] as TextContent;
  expect(block.type).toBe("text");
  expect(block.text).toBe("from claude");
  expect("textSignature" in block).toBe(false);
});

test("toolCall id normalization + toolResult rewrite", () => {
  const model = makeModel({ provider: "anthropic", api: "anthropic-messages", id: "claude-y" });
  const longId = "fc_" + "x".repeat(80) + "|abc";
  const a = emptyAssistant({
    provider: "openai", api: "openai-responses", model: "gpt-5-2",
    content: [{ type: "toolCall", id: longId, name: "read_file", arguments: { path: "/tmp/a" } } as ToolCall],
  });
  const tr: ToolResultMessage = {
    role: "toolResult",
    toolCallId: longId,
    toolName: "read_file",
    content: [{ type: "text", text: "ok" } as TextContent],
    isError: false,
    timestamp: 0,
  };
  const normalize = (id: string) => normalizeOpenAIResponsesToolCallId(id).replace(/[^a-zA-Z0-9_-]/g, "_").slice(0, 64);
  const out = transformMessages([a, tr], model, normalize);
  const ao = out[0] as AssistantMessage;
  const tco = ao.content[0] as ToolCall;
  expect(tco.id.length).toBeLessThanOrEqual(64);
  expect(tco.id).not.toContain("|");
  const tro = out[1] as ToolResultMessage;
  expect(tro.toolCallId).toBe(tco.id);
});

test("orphan toolCall is given a synthesized error toolResult", () => {
  const model = makeModel();
  const a = emptyAssistant({
    content: [{ type: "toolCall", id: "tc1", name: "foo", arguments: {} } as ToolCall],
  });
  const out = transformMessages([a], model);
  expect(out.length).toBe(2);
  const tr = out[1] as ToolResultMessage;
  expect(tr.role).toBe("toolResult");
  expect(tr.toolCallId).toBe("tc1");
  expect(tr.isError).toBe(true);
});

test("assistant messages with stopReason error/aborted are dropped", () => {
  const model = makeModel();
  const errMsg = emptyAssistant({ stopReason: "error", errorMessage: "boom", content: [{ type: "text", text: "x" } as TextContent] });
  const ok: UserMessage = { role: "user", timestamp: 0, content: "hi" };
  const aborted = emptyAssistant({ stopReason: "aborted", content: [{ type: "text", text: "y" } as TextContent] });
  const out = transformMessages([errMsg, ok, aborted], model);
  expect(out.length).toBe(1);
  expect(out[0]!.role).toBe("user");
});

test("normalizeOpenAIResponsesToolCallId conforms to /[A-Za-z0-9_-]{1,64}/", () => {
  const norm = normalizeOpenAIResponsesToolCallId("call|" + "z".repeat(100));
  expect(norm.length).toBeLessThanOrEqual(64);
  expect(norm).toMatch(/^[A-Za-z0-9_-]+$/);
});
