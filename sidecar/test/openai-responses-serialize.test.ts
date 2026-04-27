// Regression tests for the OpenAI Responses input serializer.
//
// The codex backend rejects content blocks of type `reasoning` or
// `function_call` ("Invalid value: 'reasoning'. Supported values are:
// 'input_text', 'input_image', 'output_text', 'refusal', 'input_file',
// 'computer_screenshot', 'summary_text'." → HTTP 400). Reasoning items,
// function calls, and assistant messages must each be emitted as their own
// top-level input item; only `output_text` is a valid assistant content type.

import { test, expect } from "bun:test";
import { buildPayload, streamOpenaiResponses } from "../src/llm/providers/openai-responses";
import type {
  AssistantMessage,
  Context,
  Model,
  ThinkingContent,
  ToolResultMessage,
  UserMessage,
} from "../src/llm/types";

function makeModel(): Model<"openai-responses"> {
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
  };
}

function emptyUsage() {
  return { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
}

function makeContext(messages: Context["messages"]): Context {
  return { systemPrompt: "you are AOS", messages, tools: [] };
}

test("assistant thinking + toolCall flatten to top-level reasoning + function_call items", () => {
  const reasoningItem = { type: "reasoning", id: "rs_1", summary: [{ type: "summary_text", text: "thinking..." }], encrypted_content: "ENC" };
  const assistant: AssistantMessage = {
    role: "assistant",
    content: [
      { type: "thinking", thinking: "thinking...", thinkingSignature: JSON.stringify(reasoningItem) },
      { type: "text", text: "hello" },
      { type: "toolCall", id: "call_42", name: "do_thing", arguments: { x: 1 } },
    ],
    api: "openai-responses",
    provider: "chatgpt-plan",
    model: "gpt-5-2",
    usage: emptyUsage(),
    stopReason: "stop",
    timestamp: 0,
  };

  const payload = buildPayload(makeModel(), makeContext([assistant]), { reasoning: "medium" });
  const input = payload["input"] as Array<Record<string, unknown>>;

  // Three top-level items, in order: reasoning, message, function_call.
  expect(input).toHaveLength(3);
  expect(input[0]).toEqual(reasoningItem);
  expect(input[1]?.["type"]).toBe("message");
  expect(input[1]?.["role"]).toBe("assistant");
  const content = input[1]?.["content"] as Array<Record<string, unknown>>;
  expect(content).toHaveLength(1);
  expect(content[0]?.["type"]).toBe("output_text");
  expect(content[0]?.["text"]).toBe("hello");
  expect(input[2]).toMatchObject({
    type: "function_call",
    call_id: "call_42",
    name: "do_thing",
    arguments: JSON.stringify({ x: 1 }),
  });

  // No content block of these top-level types appears inside any message.
  for (const item of input) {
    const itemContent = item["content"];
    if (Array.isArray(itemContent)) {
      for (const c of itemContent as Array<Record<string, unknown>>) {
        expect(c["type"]).not.toBe("reasoning");
        expect(c["type"]).not.toBe("function_call");
      }
    }
  }

  // `include` is set so that future replays can reuse encrypted_content,
  // and `reasoning.summary: "auto"` is required for the codex backend to
  // emit `response.reasoning_summary_*` events.
  expect(payload["include"]).toEqual(["reasoning.encrypted_content"]);
  expect(payload["reasoning"]).toEqual({ effort: "medium", summary: "auto" });
});

test("reasoning + include omitted when reasoning effort is not set", () => {
  const u: UserMessage = { role: "user", content: "hi", timestamp: 0 };
  const payload = buildPayload(makeModel(), makeContext([u]));
  expect(payload["reasoning"]).toBeUndefined();
  expect(payload["include"]).toBeUndefined();
});

test("malformed thinkingSignature throws on serialize (no silent fallback)", () => {
  const assistant: AssistantMessage = {
    role: "assistant",
    content: [{ type: "thinking", thinking: "x", thinkingSignature: "{not json" }],
    api: "openai-responses",
    provider: "chatgpt-plan",
    model: "gpt-5-2",
    usage: emptyUsage(),
    stopReason: "stop",
    timestamp: 0,
  };
  expect(() => buildPayload(makeModel(), makeContext([assistant]))).toThrow();
});

test("thinking blocks without thinkingSignature are dropped on serialize", () => {
  const assistant: AssistantMessage = {
    role: "assistant",
    content: [
      { type: "thinking", thinking: "ephemeral" },
      { type: "text", text: "ok" },
    ],
    api: "openai-responses",
    provider: "chatgpt-plan",
    model: "gpt-5-2",
    usage: emptyUsage(),
    stopReason: "stop",
    timestamp: 0,
  };

  const payload = buildPayload(makeModel(), makeContext([assistant]));
  const input = payload["input"] as Array<Record<string, unknown>>;
  expect(input).toHaveLength(1);
  expect(input[0]?.["type"]).toBe("message");
});

test("toolResult emits function_call_output with string output (no images)", () => {
  const tr: ToolResultMessage = {
    role: "toolResult",
    toolCallId: "call_42",
    toolName: "do_thing",
    content: [{ type: "text", text: "result-text" }],
    isError: false,
    timestamp: 0,
  };
  const payload = buildPayload(makeModel(), makeContext([tr]));
  const input = payload["input"] as Array<Record<string, unknown>>;
  expect(input[0]).toEqual({ type: "function_call_output", call_id: "call_42", output: "result-text" });
});

// =============================================================================
// Streaming dispatch tests (drive a fake SSE response through the provider)
// =============================================================================

function sseEvent(name: string, data: Record<string, unknown>): string {
  return `event: ${name}\ndata: ${JSON.stringify(data)}\n\n`;
}

function sseResponse(events: string[]): Response {
  const body = new ReadableStream<Uint8Array>({
    start(controller) {
      const enc = new TextEncoder();
      for (const e of events) controller.enqueue(enc.encode(e));
      controller.close();
    },
  });
  return new Response(body, { status: 200, headers: { "content-type": "text/event-stream" } });
}

async function collect<T>(stream: AsyncIterable<T>): Promise<T[]> {
  const out: T[] = [];
  for await (const ev of stream) out.push(ev);
  return out;
}

test("reasoning_summary_* events feed thinking; output_item.done captures signature", async () => {
  const reasoningItem = {
    type: "reasoning",
    id: "rs_1",
    summary: [
      { type: "summary_text", text: "step one" },
      { type: "summary_text", text: "step two" },
    ],
    encrypted_content: "ENC",
  };
  const events = [
    sseEvent("response.created", { response: { id: "resp_1" } }),
    sseEvent("response.output_item.added", { item: { type: "reasoning", id: "rs_1" } }),
    sseEvent("response.reasoning_summary_part.added", { item_id: "rs_1", summary_index: 0, part: { type: "summary_text", text: "" } }),
    sseEvent("response.reasoning_summary_text.delta", { item_id: "rs_1", delta: "step one" }),
    sseEvent("response.reasoning_summary_part.done", { item_id: "rs_1", summary_index: 0 }),
    sseEvent("response.reasoning_summary_part.added", { item_id: "rs_1", summary_index: 1, part: { type: "summary_text", text: "" } }),
    sseEvent("response.reasoning_summary_text.delta", { item_id: "rs_1", delta: "step two" }),
    sseEvent("response.reasoning_summary_part.done", { item_id: "rs_1", summary_index: 1 }),
    sseEvent("response.output_item.done", { item: reasoningItem }),
    sseEvent("response.completed", { response: { id: "resp_1", status: "completed", usage: { input_tokens: 1, output_tokens: 1 } } }),
  ];

  const originalFetch = globalThis.fetch;
  globalThis.fetch = (async () => sseResponse(events)) as unknown as typeof fetch;
  try {
    const stream = streamOpenaiResponses(
      makeModel(),
      makeContext([{ role: "user", content: "go", timestamp: 0 }]),
      { apiKey: "sk-test", reasoning: "medium" },
    );
    const all = await collect(stream);
    const done = all.find((e) => e.type === "done");
    expect(done).toBeDefined();
    if (done?.type !== "done") throw new Error("expected done event");
    const thinking = done.message.content.find((c): c is ThinkingContent => c.type === "thinking");
    expect(thinking).toBeDefined();
    expect(thinking?.thinking).toBe("step one\n\nstep two");
    expect(thinking?.thinkingSignature).toBe(JSON.stringify(reasoningItem));
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("delta event referencing unknown item_id throws (no silent skip)", async () => {
  const events = [
    sseEvent("response.created", { response: { id: "resp_2" } }),
    // No output_item.added before this delta — protocol violation.
    sseEvent("response.output_text.delta", { item_id: "ghost", delta: "boom" }),
    sseEvent("response.completed", { response: { id: "resp_2", status: "completed", usage: {} } }),
  ];
  const errors: string[] = [];
  const originalWrite = process.stderr.write.bind(process.stderr);
  process.stderr.write = ((chunk: string | Uint8Array) => {
    errors.push(typeof chunk === "string" ? chunk : new TextDecoder().decode(chunk));
    return true;
  }) as typeof process.stderr.write;
  const originalFetch = globalThis.fetch;
  globalThis.fetch = (async () => sseResponse(events)) as unknown as typeof fetch;
  try {
    const stream = streamOpenaiResponses(
      makeModel(),
      makeContext([{ role: "user", content: "go", timestamp: 0 }]),
      { apiKey: "sk-test" },
    );
    await collect(stream);
    expect(errors.some((e) => e.includes("references unknown item_id"))).toBe(true);
  } finally {
    process.stderr.write = originalWrite;
    globalThis.fetch = originalFetch;
  }
});

test("user message serializes content as input_text / input_image", () => {
  const u: UserMessage = {
    role: "user",
    content: [
      { type: "text", text: "hi" },
      { type: "image", mimeType: "image/png", data: "BASE64" },
    ],
    timestamp: 0,
  };
  const payload = buildPayload(makeModel(), makeContext([u]));
  const input = payload["input"] as Array<Record<string, unknown>>;
  expect(input).toHaveLength(1);
  const content = input[0]?.["content"] as Array<Record<string, unknown>>;
  expect(content[0]).toEqual({ type: "input_text", text: "hi" });
  expect(content[1]).toEqual({ type: "input_image", image_url: "data:image/png;base64,BASE64" });
});
