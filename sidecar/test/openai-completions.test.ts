// Tests for the chat-completions provider engine and the DeepSeek wrapper.
//
// We exercise three layers:
//   1. `buildPayload` — wire-shape contract per compat profile.
//   2. `convertMessages` (via buildPayload) — assistant thinking is dropped,
//      tool_calls / tool_results round-trip cleanly.
//   3. `runCompletionsStream` — SSE chunks → AssistantMessageEvent stream.
//
// DeepSeek scenarios verify the wrapper's compat overrides actually flow
// through to the wire payload AND that `delta.reasoning_content` chunks
// surface as `thinking_*` events.

import { test, expect } from "bun:test";
import {
  buildPayload,
  resolveCompat,
  runCompletionsStream,
  streamOpenAICompletions,
  type OpenAICompletionsCompat,
  type OpenAICompletionsOptions,
} from "../src/llm/providers/openai-completions";
import {
  streamDeepseek,
  streamSimpleDeepseek,
} from "../src/llm/providers/deepseek";
import type {
  AssistantMessage,
  AssistantMessageEvent,
  Context,
  Message,
  Model,
  TextContent,
  ThinkingContent,
  ToolCall,
} from "../src/llm/types";

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

function makeOpenAIModel(): Model<"openai-completions"> {
  return {
    id: "gpt-4o",
    name: "GPT-4o",
    api: "openai-completions",
    provider: "openai",
    baseUrl: "https://api.openai.com/v1",
    reasoning: false,
    input: ["text"],
    cost: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0 },
    // (reasoning: false here marks the OpenAI test fixture as a non-
    // reasoning model; specific tests below override it with a spec.)
    contextWindow: 128_000,
    maxTokens: 16_384,
  };
}

function makeDeepseekModel(): Model<"deepseek"> {
  return {
    id: "deepseek-v4-flash",
    name: "DeepSeek V4 Flash",
    api: "deepseek",
    provider: "deepseek",
    baseUrl: "https://api.deepseek.com",
    reasoning: {
      efforts: [
        { value: "high", label: "High" },
        { value: "max", label: "Max" },
      ],
      default: "high",
    },
    input: ["text"],
    cost: { input: 0.14, output: 0.28, cacheRead: 0.0028, cacheWrite: 0 },
    contextWindow: 1_000_000,
    maxTokens: 384_000,
  };
}

// Mirrors the production DeepSeek compat in `src/llm/providers/deepseek.ts`.
// V4 chat-completions DOES accept `reasoning_effort` (with the model-native
// values `high` / `max`); keep this fixture in sync so payload-level tests
// validate the actually-shipped behavior rather than a stale snapshot.
const DEEPSEEK_COMPAT_RAW: OpenAICompletionsCompat = {
  supportsStore: false,
  supportsDeveloperRole: false,
  supportsReasoningEffort: true,
  maxTokensField: "max_tokens",
  reasoningField: "reasoning_content",
};
const DEEPSEEK_COMPAT = resolveCompat(DEEPSEEK_COMPAT_RAW);
const DEFAULT_COMPAT = resolveCompat();

function ctx(messages: Message[], systemPrompt = "you are AOS"): Context {
  return { systemPrompt, messages, tools: [] };
}

function emptyUsage() {
  return { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
           cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
}

// ---------------------------------------------------------------------------
// SSE helpers
// ---------------------------------------------------------------------------

function sseChunk(data: Record<string, unknown> | "[DONE]"): string {
  return `data: ${data === "[DONE]" ? "[DONE]" : JSON.stringify(data)}\n\n`;
}

function sseResponse(chunks: string[]): Response {
  const body = new ReadableStream<Uint8Array>({
    start(c) {
      const enc = new TextEncoder();
      for (const ch of chunks) c.enqueue(enc.encode(ch));
      c.close();
    },
  });
  return new Response(body, { status: 200, headers: { "content-type": "text/event-stream" } });
}

async function collect(stream: AsyncIterable<AssistantMessageEvent>): Promise<AssistantMessageEvent[]> {
  const out: AssistantMessageEvent[] = [];
  for await (const e of stream) out.push(e);
  return out;
}

// =============================================================================
// buildPayload — compat profile contract
// =============================================================================

test("default compat: system role + max_completion_tokens + store false", () => {
  const payload = buildPayload(
    makeOpenAIModel(),
    ctx([{ role: "user", content: "hi", timestamp: 0 }]),
    { maxTokens: 1024 },
    DEFAULT_COMPAT,
  );
  expect(payload["model"]).toBe("gpt-4o");
  expect(payload["stream"]).toBe(true);
  expect(payload["store"]).toBe(false);
  expect(payload["max_completion_tokens"]).toBe(1024);
  expect(payload["max_tokens"]).toBeUndefined();
  const messages = payload["messages"] as Array<Record<string, unknown>>;
  expect(messages[0]).toEqual({ role: "system", content: "you are AOS" });
});

test("DeepSeek compat: max_tokens (not max_completion_tokens), no store, no developer role", () => {
  const payload = buildPayload(
    makeDeepseekModel(),
    ctx([{ role: "user", content: "hi", timestamp: 0 }]),
    { maxTokens: 2048 },
    DEEPSEEK_COMPAT,
  );
  expect(payload["max_tokens"]).toBe(2048);
  expect(payload["max_completion_tokens"]).toBeUndefined();
  expect(payload).not.toHaveProperty("store");
  const messages = payload["messages"] as Array<Record<string, unknown>>;
  // DeepSeek model has reasoning:true, but supportsDeveloperRole is false
  // → must stay `system`, not `developer`.
  expect(messages[0]!["role"]).toBe("system");
});

test("DeepSeek compat forwards reasoning_effort onto the wire (V4 native vocab)", () => {
  for (const effort of ["high", "max"]) {
    const payload = buildPayload(
      makeDeepseekModel(),
      ctx([{ role: "user", content: "hi", timestamp: 0 }]),
      { reasoningEffort: effort } as OpenAICompletionsOptions,
      DEEPSEEK_COMPAT,
    );
    expect(payload["reasoning_effort"]).toBe(effort);
  }
});

test("streamSimpleDeepseek translates simple `reasoning` into wire `reasoning_effort`", async () => {
  // Production path: the agent loop hands the resolved effort string off
  // to `streamSimple*`, which must thread it through to the chat-completions
  // engine as `reasoning_effort` (NOT swallowed by buildBaseOptions).
  let captured: Record<string, unknown> | null = null;
  const originalFetch = globalThis.fetch;
  globalThis.fetch = (async (_url: string, init?: { body?: string }) => {
    captured = JSON.parse(init?.body ?? "{}") as Record<string, unknown>;
    return sseResponse([sseChunk({ id: "c1", choices: [{ index: 0, delta: {}, finish_reason: "stop" }] }), sseChunk("[DONE]")]);
  }) as unknown as typeof fetch;
  try {
    const stream = streamSimpleDeepseek(
      makeDeepseekModel(),
      ctx([{ role: "user", content: "go", timestamp: 0 }]),
      { apiKey: "sk-test", reasoning: "max" },
    );
    await collect(stream);
    expect(captured).not.toBeNull();
    expect(captured!["reasoning_effort"]).toBe("max");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("default compat sends reasoning_effort for reasoning models", () => {
  const m = {
    ...makeOpenAIModel(),
    reasoning: {
      efforts: [
        { value: "low", label: "Low" },
        { value: "medium", label: "Medium" },
        { value: "high", label: "High" },
        { value: "xhigh", label: "Extra High" },
      ],
      default: "medium",
    } as const,
  };
  const payload = buildPayload(
    m,
    ctx([{ role: "user", content: "hi", timestamp: 0 }]),
    { reasoningEffort: "high" } as OpenAICompletionsOptions,
    DEFAULT_COMPAT,
  );
  expect(payload["reasoning_effort"]).toBe("high");
});

// =============================================================================
// convertMessages (observed via payload.messages)
// =============================================================================

test("assistant thinking blocks are replayed via reasoning_content on DeepSeek thinking mode", () => {
  // DeepSeek V4 thinking mode rejects the next round with HTTP 400 unless
  // the prior assistant message carries its `reasoning_content` field.
  // This test pins the contract for the bash-tool follow-up that broke.
  const assistant: AssistantMessage = {
    role: "assistant",
    content: [
      { type: "thinking", thinking: "internal monologue", thinkingSignature: "sig" } as ThinkingContent,
      { type: "text", text: "answer" } as TextContent,
    ],
    api: "deepseek",
    provider: "deepseek",
    model: "deepseek-v4-flash",
    usage: emptyUsage(),
    stopReason: "stop",
    timestamp: 0,
  };
  const payload = buildPayload(
    makeDeepseekModel(),
    ctx([
      { role: "user", content: "q", timestamp: 0 },
      assistant,
      { role: "user", content: "follow-up", timestamp: 0 },
    ]),
    {},
    DEEPSEEK_COMPAT,
  );
  const messages = payload["messages"] as Array<Record<string, unknown>>;
  // [system, user, assistant, user]
  expect(messages).toHaveLength(4);
  const am = messages[2]!;
  expect(am["role"]).toBe("assistant");
  expect(am["content"]).toBe("answer");
  expect(am["reasoning_content"]).toBe("internal monologue");
});

test("non-thinking model does not get reasoning_content even if compat declares the field", () => {
  // Guard: the gate on `supportsThinking(model)` keeps us from sending the
  // field to providers/models that don't accept it (e.g. vanilla OpenAI
  // Chat Completions, where the default compat still names "reasoning_content"
  // as the *streaming* field but the request endpoint rejects it as input).
  const assistant: AssistantMessage = {
    role: "assistant",
    content: [
      { type: "thinking", thinking: "should not leak", thinkingSignature: "sig" } as ThinkingContent,
      { type: "text", text: "answer" } as TextContent,
    ],
    api: "openai-completions",
    provider: "openai",
    model: "gpt-4o",
    usage: emptyUsage(),
    stopReason: "stop",
    timestamp: 0,
  };
  const payload = buildPayload(
    makeOpenAIModel(),
    ctx([
      { role: "user", content: "q", timestamp: 0 },
      assistant,
      { role: "user", content: "follow-up", timestamp: 0 },
    ]),
    {},
    DEFAULT_COMPAT,
  );
  const messages = payload["messages"] as Array<Record<string, unknown>>;
  const am = messages[2]!;
  expect(am).not.toHaveProperty("reasoning_content");
});

test("toolCall + toolResult round-trip cleanly", () => {
  const assistant: AssistantMessage = {
    role: "assistant",
    content: [{ type: "toolCall", id: "call_1", name: "do_thing", arguments: { x: 1 } } as ToolCall],
    api: "openai-completions",
    provider: "openai",
    model: "gpt-4o",
    usage: emptyUsage(),
    stopReason: "toolUse",
    timestamp: 0,
  };
  const payload = buildPayload(
    makeOpenAIModel(),
    ctx([
      { role: "user", content: "q", timestamp: 0 },
      assistant,
      {
        role: "toolResult",
        toolCallId: "call_1",
        toolName: "do_thing",
        content: [{ type: "text", text: "ok" }],
        isError: false,
        timestamp: 0,
      },
    ]),
    {},
    DEFAULT_COMPAT,
  );
  const messages = payload["messages"] as Array<Record<string, unknown>>;
  const am = messages[2]!;
  const tm = messages[3]!;
  expect(am["tool_calls"]).toEqual([
    { id: "call_1", type: "function", function: { name: "do_thing", arguments: '{"x":1}' } },
  ]);
  expect(tm).toEqual({ role: "tool", content: "ok", tool_call_id: "call_1" });
});

test("tools array converts to function-typed entries", () => {
  const payload = buildPayload(
    makeOpenAIModel(),
    {
      systemPrompt: "",
      messages: [{ role: "user", content: "hi", timestamp: 0 }],
      tools: [{ name: "echo", description: "echo it", parameters: { type: "object" } }],
    },
    {},
    DEFAULT_COMPAT,
  );
  expect(payload["tools"]).toEqual([
    { type: "function", function: { name: "echo", description: "echo it", parameters: { type: "object" } } },
  ]);
});

// =============================================================================
// Streaming — runCompletionsStream
// =============================================================================

test("text content delta surfaces as text_start/delta/end + done", async () => {
  const chunks = [
    sseChunk({ id: "c1", choices: [{ index: 0, delta: { content: "Hel" } }] }),
    sseChunk({ id: "c1", choices: [{ index: 0, delta: { content: "lo" } }] }),
    sseChunk({ id: "c1", choices: [{ index: 0, delta: {}, finish_reason: "stop" }] }),
    sseChunk({ id: "c1", choices: [], usage: { prompt_tokens: 3, completion_tokens: 1 } }),
    sseChunk("[DONE]"),
  ];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = (async () => sseResponse(chunks)) as unknown as typeof fetch;
  try {
    const stream = streamOpenAICompletions(
      makeOpenAIModel(),
      ctx([{ role: "user", content: "say hi", timestamp: 0 }]),
      { apiKey: "sk-test" },
    );
    const events = await collect(stream);
    expect(events.find((e) => e.type === "text_start")).toBeDefined();
    const deltas = events.filter((e) => e.type === "text_delta");
    expect(deltas.map((e) => (e as { delta: string }).delta).join("")).toBe("Hello");
    const done = events.find((e) => e.type === "done");
    expect(done).toBeDefined();
    if (done?.type !== "done") throw new Error("expected done");
    const text = done.message.content.find((c): c is TextContent => c.type === "text");
    expect(text?.text).toBe("Hello");
    expect(done.message.usage.input).toBe(3);
    expect(done.message.usage.output).toBe(1);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("DeepSeek reasoning_content delta surfaces as thinking_* events ahead of text", async () => {
  const chunks = [
    sseChunk({ id: "c1", choices: [{ index: 0, delta: { reasoning_content: "think " } }] }),
    sseChunk({ id: "c1", choices: [{ index: 0, delta: { reasoning_content: "more" } }] }),
    sseChunk({ id: "c1", choices: [{ index: 0, delta: { content: "Answer" } }] }),
    sseChunk({ id: "c1", choices: [{ index: 0, delta: {}, finish_reason: "stop" }] }),
    sseChunk({ id: "c1", choices: [], usage: { prompt_tokens: 4, completion_tokens: 2, prompt_cache_hit_tokens: 2 } }),
    sseChunk("[DONE]"),
  ];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = (async () => sseResponse(chunks)) as unknown as typeof fetch;
  try {
    const stream = streamDeepseek(
      makeDeepseekModel(),
      ctx([{ role: "user", content: "go", timestamp: 0 }]),
      { apiKey: "sk-test" },
    );
    const events = await collect(stream);
    const thinkingDeltas = events.filter((e) => e.type === "thinking_delta");
    expect(thinkingDeltas.map((e) => (e as { delta: string }).delta).join("")).toBe("think more");
    const textStart = events.findIndex((e) => e.type === "text_start");
    const lastThinking = events.map((e) => e.type).lastIndexOf("thinking_delta");
    expect(textStart).toBeGreaterThan(lastThinking); // thinking ends before text begins
    const done = events.find((e) => e.type === "done");
    if (done?.type !== "done") throw new Error("expected done");
    expect(done.message.content.map((c) => c.type)).toEqual(["thinking", "text"]);
    // DeepSeek-style cache fields parsed: cacheRead=2, input=prompt-2=2.
    expect(done.message.usage.input).toBe(2);
    expect(done.message.usage.cacheRead).toBe(2);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("tool_calls argument streaming accumulates into final ToolCall block", async () => {
  const chunks = [
    sseChunk({
      id: "c1",
      choices: [{ index: 0, delta: { tool_calls: [{ index: 0, id: "call_1", function: { name: "echo", arguments: '{"x":' } }] } }],
    }),
    sseChunk({
      id: "c1",
      choices: [{ index: 0, delta: { tool_calls: [{ index: 0, function: { arguments: '1}' } }] } }],
    }),
    sseChunk({ id: "c1", choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }] }),
    sseChunk({ id: "c1", choices: [], usage: { prompt_tokens: 2, completion_tokens: 5 } }),
    sseChunk("[DONE]"),
  ];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = (async () => sseResponse(chunks)) as unknown as typeof fetch;
  try {
    const stream = streamOpenAICompletions(
      makeOpenAIModel(),
      ctx([{ role: "user", content: "call it", timestamp: 0 }]),
      { apiKey: "sk-test" },
    );
    const events = await collect(stream);
    const done = events.find((e) => e.type === "done");
    if (done?.type !== "done") throw new Error("expected done");
    expect(done.message.stopReason).toBe("toolUse");
    const tc = done.message.content.find((c): c is ToolCall => c.type === "toolCall");
    expect(tc).toBeDefined();
    expect(tc?.id).toBe("call_1");
    expect(tc?.name).toBe("echo");
    expect(tc?.arguments).toEqual({ x: 1 });
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("HTTP non-2xx surfaces as error event with response body in message", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = (async () =>
    new Response("model overloaded", { status: 503, headers: { "content-type": "text/plain" } })) as unknown as typeof fetch;
  try {
    const stream = streamOpenAICompletions(
      makeOpenAIModel(),
      ctx([{ role: "user", content: "hi", timestamp: 0 }]),
      { apiKey: "sk-test" },
    );
    const events = await collect(stream);
    const err = events.find((e) => e.type === "error");
    expect(err).toBeDefined();
    if (err?.type !== "error") throw new Error("expected error");
    expect(err.error.errorMessage).toContain("HTTP 503");
    expect(err.error.errorMessage).toContain("model overloaded");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("missing API key produces error event without making a fetch", async () => {
  let fetchCalled = false;
  const originalFetch = globalThis.fetch;
  globalThis.fetch = (async () => {
    fetchCalled = true;
    return new Response("", { status: 200 });
  }) as unknown as typeof fetch;
  try {
    const stream = streamOpenAICompletions(
      makeOpenAIModel(),
      ctx([{ role: "user", content: "hi", timestamp: 0 }]),
      // no apiKey, no env DEEPSEEK_API_KEY/OPENAI_API_KEY guarantee — but
      // this test is for the OpenAI provider; clear env to make it deterministic.
      { apiKey: undefined },
    );
    const prevEnv = process.env.OPENAI_API_KEY;
    delete process.env.OPENAI_API_KEY;
    try {
      const events = await collect(stream);
      const err = events.find((e) => e.type === "error");
      expect(err).toBeDefined();
      if (err?.type !== "error") throw new Error("expected error");
      expect(err.error.errorMessage).toContain("No API key");
      expect(fetchCalled).toBe(false);
    } finally {
      if (prevEnv !== undefined) process.env.OPENAI_API_KEY = prevEnv;
    }
  } finally {
    globalThis.fetch = originalFetch;
  }
});

// =============================================================================
// Usage cost — verify cost calc fires
// =============================================================================

test("DeepSeek cost calculation reflects per-1M pricing on cache-miss + cache-hit + output", async () => {
  const chunks = [
    sseChunk({ id: "c1", choices: [{ index: 0, delta: { content: "hi" } }] }),
    sseChunk({ id: "c1", choices: [{ index: 0, delta: {}, finish_reason: "stop" }] }),
    // 1M cache miss + 1M cache hit + 1M output → $0.14 + $0.0028 + $0.28 = $0.4228
    sseChunk({ id: "c1", choices: [], usage: { prompt_tokens: 2_000_000, completion_tokens: 1_000_000, prompt_cache_hit_tokens: 1_000_000 } }),
    sseChunk("[DONE]"),
  ];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = (async () => sseResponse(chunks)) as unknown as typeof fetch;
  try {
    const stream = streamDeepseek(
      makeDeepseekModel(),
      ctx([{ role: "user", content: "go", timestamp: 0 }]),
      { apiKey: "sk-test" },
    );
    const events = await collect(stream);
    const done = events.find((e) => e.type === "done");
    if (done?.type !== "done") throw new Error("expected done");
    const u = done.message.usage;
    expect(u.input).toBe(1_000_000);
    expect(u.cacheRead).toBe(1_000_000);
    expect(u.output).toBe(1_000_000);
    expect(u.cost.input).toBeCloseTo(0.14, 5);
    expect(u.cost.cacheRead).toBeCloseTo(0.0028, 6);
    expect(u.cost.output).toBeCloseTo(0.28, 5);
    expect(u.cost.total).toBeCloseTo(0.14 + 0.0028 + 0.28, 5);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
