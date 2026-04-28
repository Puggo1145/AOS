// OpenAI Responses API streaming provider.
//
// =====================================================================
// INTEGRATION NOTE — VERIFY before first real-endpoint smoke test
// =====================================================================
// The exact SSE event names emitted by the OpenAI Responses API are
// subject to upstream protocol revision and (for the ChatGPT plan
// endpoint specifically) have not been formally published.
//
// Below we map a best-effort dispatch table covering the documented
// `response.created`, `response.output_item.added/.done`,
// `response.output_text.delta/.done`,
// `response.reasoning_text.delta/.done`,
// `response.function_call_arguments.delta/.done`,
// `response.completed`, `response.failed` events.
//
// The dispatch is centralized in `mapResponsesEventToAssistantEvent` so
// that adjusting it for the real endpoint requires editing one function.
// Unknown events are logged to stderr and otherwise ignored (per design
// doc "风险" item: "OpenAI Responses 协议未来字段变更" → only log).
// =====================================================================

import { createParser, type EventSourceMessage } from "eventsource-parser";

import type {
  AssistantMessage,
  AssistantMessageEvent,
  Context,
  Message,
  Model,
  ProviderStreamOptions,
  SimpleStreamFunction,
  SimpleStreamOptions,
  StreamFunction,
  TextContent,
  ThinkingContent,
  ToolCall,
  Usage,
} from "../types";
import { AssistantMessageEventStream } from "../utils/event-stream";
import { calculateCost } from "../models/cost";
import { sanitizeSurrogates } from "../utils/sanitize-unicode";
import { mergeHeaders } from "../utils/headers";
import { parseStreamingJson } from "../utils/json-parse";
import {
  AUTHENTICATED_SENTINEL,
  getEnvApiKey,
} from "../auth/env-api-keys";
import { readChatGPTToken, AuthInvalidatedError } from "../auth/oauth/chatgpt-plan";
import { buildBaseOptions } from "./simple-options";

export interface OpenAIResponsesOptions extends ProviderStreamOptions {
  reasoning?: import("../types").ThinkingLevel;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function emptyUsage(): Usage {
  return {
    input: 0,
    output: 0,
    cacheRead: 0,
    cacheWrite: 0,
    totalTokens: 0,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
  };
}

function makeOutput<TApi extends "openai-responses">(model: Model<TApi>): AssistantMessage {
  return {
    role: "assistant",
    content: [],
    api: model.api,
    provider: model.provider,
    model: model.id,
    usage: emptyUsage(),
    stopReason: "stop",
    timestamp: Date.now(),
  };
}

export function buildPayload(model: Model<"openai-responses">, context: Context, options?: OpenAIResponsesOptions): Record<string, unknown> {
  const input: Array<Record<string, unknown>> = [];
  for (const msg of context.messages) {
    for (const item of serializeMessage(msg)) input.push(item);
  }
  // ChatGPT codex backend (chatgpt.com/backend-api/codex/responses) rejects
  // requests without a top-level `instructions` field ("HTTP 400: Instructions
  // are required"). The system prompt belongs here, not as a `role: system`
  // message inside `input` — the codex backend ignores the latter and still
  // 400s. Mirrors pi-mono's openai-codex-responses provider.
  const payload: Record<string, unknown> = {
    model: model.id,
    input,
    stream: true,
    store: false,
    instructions: context.systemPrompt ? sanitizeSurrogates(context.systemPrompt) : "",
  };
  if (options?.maxTokens) payload["max_output_tokens"] = options.maxTokens;
  if (options?.temperature !== undefined) payload["temperature"] = options.temperature;
  if (options?.reasoning) {
    // `summary: "auto"` is required: without it the codex backend never emits
    // `response.reasoning_summary_*` events and the thinking stream stays
    // empty. `include: ["reasoning.encrypted_content"]` is required because
    // we run with `store: false` — without inlined ciphertext the next
    // request cannot replay reasoning, leaving function_call items unpaired.
    payload["reasoning"] = { effort: options.reasoning, summary: "auto" };
    payload["include"] = ["reasoning.encrypted_content"];
  }
  if (context.tools && context.tools.length > 0) {
    payload["tools"] = context.tools.map((t) => ({
      type: "function",
      name: t.name,
      description: t.description,
      parameters: t.parameters,
    }));
  }
  return payload;
}

// Each AOS `Message` may expand into multiple Responses-API input items:
// reasoning, message, and function_call are all top-level items, not content
// blocks of a single message. Only `output_text` is a valid assistant
// content-block type — sending `{type:"reasoning"}` inside `content` triggers
// `Invalid value: 'reasoning'` (HTTP 400) from the codex backend.
function serializeMessage(msg: Message): Record<string, unknown>[] {
  if (msg.role === "user") {
    const content = typeof msg.content === "string"
      ? [{ type: "input_text", text: sanitizeSurrogates(msg.content) }]
      : msg.content.map((b) => b.type === "text"
          ? { type: "input_text", text: sanitizeSurrogates(b.text) }
          : { type: "input_image", image_url: `data:${b.mimeType};base64,${b.data}` });
    return [{ role: "user", content }];
  }
  if (msg.role === "assistant") {
    // Preserve the original block order — reasoning items must precede the
    // function_call items they paired with on output, otherwise the codex
    // backend treats the function_call as unpaired.
    const items: Record<string, unknown>[] = [];
    for (const block of msg.content) {
      if (block.type === "text") {
        items.push({
          type: "message",
          role: "assistant",
          content: [{ type: "output_text", text: sanitizeSurrogates(block.text), annotations: [] }],
        });
      } else if (block.type === "thinking") {
        // Replay reasoning only if we captured the full upstream item in the
        // signature; without `encrypted_content` the codex backend rejects a
        // synthesized reasoning item, so we drop it here. A present-but-malformed
        // signature is a bug in the capture path — let JSON.parse throw loudly.
        if (block.thinkingSignature) {
          items.push(JSON.parse(block.thinkingSignature) as Record<string, unknown>);
        }
      } else if (block.type === "toolCall") {
        items.push({
          type: "function_call",
          call_id: block.id,
          name: block.name,
          arguments: JSON.stringify(block.arguments),
        });
      }
    }
    return items;
  }
  // toolResult — `function_call_output.output` is a string by spec; only the
  // image-bearing variant uses the structured list form.
  const textParts = msg.content.filter((b): b is import("../types").TextContent => b.type === "text").map((b) => b.text);
  const hasImage = msg.content.some((b) => b.type === "image");
  let output: unknown;
  if (hasImage) {
    output = msg.content.map((b) => b.type === "text"
      ? { type: "input_text", text: sanitizeSurrogates(b.text) }
      : { type: "input_image", image_url: `data:${b.mimeType};base64,${b.data}` });
  } else {
    output = sanitizeSurrogates(textParts.join("\n"));
  }
  return [{ type: "function_call_output", call_id: msg.toolCallId, output }];
}

function mapStopReason(status: string | undefined, incompleteReason: string | undefined): "stop" | "length" | "toolUse" | "error" {
  if (status === "completed") return "stop";
  if (status === "incomplete") {
    if (incompleteReason === "max_output_tokens") return "length";
    if (incompleteReason === "content_filter") return "error";
    throw new Error(`Unhandled incomplete reason: ${incompleteReason}`);
  }
  if (status === "failed") return "error";
  if (status === "requires_action" || status === "in_progress") return "toolUse";
  throw new Error(`Unhandled response status: ${status}`);
}

function applyUsage(model: Model<"openai-responses">, output: AssistantMessage, raw: Record<string, unknown> | undefined): void {
  if (!raw) return;
  const input = Number(raw["input_tokens"] ?? 0);
  const outputTokens = Number(raw["output_tokens"] ?? 0);
  const details = (raw["input_tokens_details"] as Record<string, unknown> | undefined) ?? {};
  const cacheRead = Number(details["cached_tokens"] ?? 0);
  const cacheWrite = Number(details["cache_creation_tokens"] ?? 0);
  output.usage.input = input - cacheRead - cacheWrite;
  if (output.usage.input < 0) output.usage.input = input;
  output.usage.output = outputTokens;
  output.usage.cacheRead = cacheRead;
  output.usage.cacheWrite = cacheWrite;
  output.usage.totalTokens = output.usage.input + output.usage.output + output.usage.cacheRead + output.usage.cacheWrite;
  calculateCost(model, output.usage);
}

// ---------------------------------------------------------------------------
// Main stream function
// ---------------------------------------------------------------------------

export const streamOpenaiResponses: StreamFunction<"openai-responses", OpenAIResponsesOptions> = (model, context, options) => {
  const stream = new AssistantMessageEventStream();
  const output = makeOutput(model);

  const blocks = new Map<number, { kind: "text" | "thinking" | "toolCall"; partialJson?: string }>();

  // Resolve a unique content index across all kinds (matches the
  // event protocol's `contentIndex` field). We assign the index when
  // an output_item is "added" and reuse it for delta / done.
  const itemIndexToContent = new Map<string, number>();

  void (async () => {
    try {
      // 1. Auth
      const headers: Record<string, string> = {
        "content-type": "application/json",
        accept: "text/event-stream",
      };
      const apiKey = options?.apiKey ?? getEnvApiKey(model.provider);
      if (apiKey === AUTHENTICATED_SENTINEL) {
        const token = await readChatGPTToken();
        headers["authorization"] = `Bearer ${token.accessToken}`;
        if (token.accountId) headers["chatgpt-account-id"] = token.accountId;
      } else if (typeof apiKey === "string" && apiKey.length > 0) {
        headers["authorization"] = `Bearer ${apiKey}`;
      } else {
        throw new Error("ChatGPT 订阅未授权");
      }
      const finalHeaders = mergeHeaders(headers, model.headers, options?.headers);

      // 2. Build payload
      let payload: unknown = buildPayload(model, context, options);
      if (options?.onPayload) {
        const overridden = await options.onPayload(payload, model);
        if (overridden !== undefined) payload = overridden;
      }

      // 3. Issue request
      stream.push({ type: "start", partial: output });

      const url = `${model.baseUrl.replace(/\/$/, "")}/responses`;
      const res = await fetch(url, {
        method: "POST",
        headers: finalHeaders,
        body: JSON.stringify(payload),
        signal: options?.signal,
      });
      if (options?.onResponse) {
        const hr: Record<string, string> = {};
        res.headers.forEach((v, k) => { hr[k.toLowerCase()] = v; });
        await options.onResponse({ status: res.status, headers: hr }, model);
      }
      if (!res.ok || !res.body) {
        const text = await res.text().catch(() => "");
        throw new Error(`HTTP ${res.status}: ${text || "(no body)"}`);
      }

      // 4. SSE parse
      const parser = createParser({
        onEvent: (ev: EventSourceMessage) => {
          try {
            mapResponsesEventToAssistantEvent(ev, model, output, blocks, itemIndexToContent, stream);
          } catch (err) {
            // Per design doc: unknown events log to stderr but do not abort.
            process.stderr.write(`[openai-responses] event mapping error: ${err instanceof Error ? err.message : String(err)}\n`);
          }
        },
      });

      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      // Idle watchdog: if codex stops emitting SSE for this long we abort
      // the read instead of hanging forever. Concrete trigger we observed:
      // an oversized `/responses` payload (accumulated tool-result
      // screenshots) could leave the connection open with no events,
      // making the agent loop wait indefinitely. Surfacing this as an
      // `ui.error` is strictly better than the user staring at the
      // shimmer until they cancel by hand.
      while (true) {
        if (options?.signal?.aborted) throw new DOMException("aborted", "AbortError");
        const { value, done } = await readWithIdleTimeout(reader, RESPONSES_IDLE_TIMEOUT_MS);
        if (done) break;
        parser.feed(decoder.decode(value, { stream: true }));
      }

      // 5. Cleanup partial fields and emit `done`.
      cleanupPartials(output);
      stream.push({ type: "done", reason: output.stopReason === "length" ? "length" : output.stopReason === "toolUse" ? "toolUse" : "stop", message: output });
      stream.end();
    } catch (error) {
      cleanupPartials(output);
      output.stopReason = options?.signal?.aborted ? "aborted" : "error";
      output.errorMessage = error instanceof Error ? error.message : JSON.stringify(error);
      // Typed auth error: surface `errorReason` so the agent loop can project
      // to `provider.statusChanged` without scraping the message string.
      if (error instanceof AuthInvalidatedError) {
        output.errorReason = "authInvalidated";
        output.errorProviderId = error.providerId;
      }
      stream.push({ type: "error", reason: output.stopReason, error: output });
      stream.end();
    }
  })();

  return stream;
};

/// 60s without a single SSE byte from codex is treated as a hung stream.
/// Real reasoning + tool turns interleave keepalives / partial deltas at
/// sub-second cadence; a full minute of silence is never normal traffic.
const RESPONSES_IDLE_TIMEOUT_MS = 60_000;

/// Exported for direct unit testing — exercising the 60s default by waiting
/// in a real test would cripple the suite. Production paths only call this
/// through the SSE read loop above.
export async function readWithIdleTimeout<T>(
  reader: { read(): Promise<{ value?: T; done: boolean }> },
  timeoutMs: number,
): Promise<{ value?: T; done: boolean }> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const idle = new Promise<never>((_, reject) => {
    timer = setTimeout(
      () =>
        reject(
          new Error(
            `OpenAI Responses stream idle for ${timeoutMs}ms — aborted. ` +
              `Likely cause: oversized request payload (e.g. accumulated tool-result screenshots) ` +
              `causing the codex backend to stall without emitting events.`,
          ),
        ),
      timeoutMs,
    );
  });
  try {
    return await Promise.race([reader.read(), idle]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

function cleanupPartials(output: AssistantMessage): void {
  for (const block of output.content as unknown as Array<Record<string, unknown>>) {
    delete block["partialJson"];
    delete block["index"];
  }
}

// ---------------------------------------------------------------------------
// SSE event → AssistantMessageEvent dispatch
// ---------------------------------------------------------------------------

function mapResponsesEventToAssistantEvent(
  ev: EventSourceMessage,
  model: Model<"openai-responses">,
  output: AssistantMessage,
  blocks: Map<number, { kind: "text" | "thinking" | "toolCall"; partialJson?: string }>,
  itemIndexToContent: Map<string, number>,
  stream: AssistantMessageEventStream,
): void {
  if (!ev.event || !ev.data) return;
  // SSE data for the Responses API is always JSON; parse failure is a
  // protocol violation, not a recoverable case — let it throw and surface
  // through the outer dispatcher's stderr log.
  const payload: Record<string, unknown> = JSON.parse(ev.data);

  const type = ev.event;

  if (type === "response.created" || type === "response.in_progress") {
    const usage = (payload["response"] as Record<string, unknown> | undefined)?.["usage"] as Record<string, unknown> | undefined;
    applyUsage(model, output, usage);
    return;
  }

  if (type === "response.output_item.added") {
    const item = payload["item"] as Record<string, unknown> | undefined;
    if (!item) throw new Error("response.output_item.added missing `item`");
    const itemId = item["id"];
    if (typeof itemId !== "string" || itemId.length === 0) {
      throw new Error("response.output_item.added missing `item.id`");
    }
    const itemType = item["type"];
    const contentIndex = output.content.length;
    itemIndexToContent.set(itemId, contentIndex);

    if (itemType === "message") {
      const block: TextContent = { type: "text", text: "" };
      output.content.push(block);
      blocks.set(contentIndex, { kind: "text" });
      stream.push({ type: "text_start", contentIndex, partial: output });
    } else if (itemType === "reasoning") {
      const block: ThinkingContent = { type: "thinking", thinking: "" };
      output.content.push(block);
      blocks.set(contentIndex, { kind: "thinking" });
      stream.push({ type: "thinking_start", contentIndex, partial: output });
    } else if (itemType === "function_call") {
      const callId = item["call_id"];
      const name = item["name"];
      if (typeof callId !== "string" || typeof name !== "string") {
        throw new Error("response.output_item.added function_call missing `call_id` or `name`");
      }
      const block: ToolCall = { type: "toolCall", id: callId, name, arguments: {} };
      output.content.push(block);
      blocks.set(contentIndex, { kind: "toolCall", partialJson: "" });
      stream.push({ type: "toolcall_start", contentIndex, partial: output });
    } else {
      throw new Error(`response.output_item.added unknown item.type: ${String(itemType)}`);
    }
    return;
  }

  // Helper: every per-item event must reference an item we already saw
  // via `output_item.added`. A miss is a protocol violation, not a no-op.
  const requireBlock = <K extends "text" | "thinking" | "toolCall">(kind: K): { idx: number; meta: { kind: "text" | "thinking" | "toolCall"; partialJson?: string } } => {
    const itemId = payload["item_id"];
    if (typeof itemId !== "string") throw new Error(`${type} missing string \`item_id\``);
    const idx = itemIndexToContent.get(itemId);
    if (idx === undefined) throw new Error(`${type} references unknown item_id: ${itemId}`);
    const meta = blocks.get(idx);
    if (!meta || meta.kind !== kind) throw new Error(`${type} expected block kind ${kind}, got ${meta?.kind}`);
    return { idx, meta };
  };

  if (type === "response.output_text.delta") {
    const { idx } = requireBlock("text");
    const delta = String(payload["delta"]);
    (output.content[idx] as TextContent).text += delta;
    stream.push({ type: "text_delta", contentIndex: idx, delta, partial: output });
    return;
  }

  if (type === "response.output_text.done") {
    const { idx } = requireBlock("text");
    const text = String(payload["text"]);
    (output.content[idx] as TextContent).text = text;
    stream.push({ type: "text_end", contentIndex: idx, content: text, partial: output });
    return;
  }

  // The codex backend emits reasoning text exclusively through
  // `reasoning_summary_*` (gated on `reasoning.summary: "auto"`). The older
  // `response.reasoning_text.*` events are a different OpenAI surface and
  // never fire on this endpoint — handling them was dead code.
  if (type === "response.reasoning_summary_part.added") {
    // No text yet, just acknowledge the part. The reasoning block was
    // already created by `output_item.added`.
    requireBlock("thinking");
    return;
  }

  if (type === "response.reasoning_summary_text.delta") {
    const { idx } = requireBlock("thinking");
    const delta = String(payload["delta"]);
    (output.content[idx] as ThinkingContent).thinking += delta;
    stream.push({ type: "thinking_delta", contentIndex: idx, delta, partial: output });
    return;
  }

  if (type === "response.reasoning_summary_part.done") {
    // Multiple summary parts in one reasoning item are separated by a blank
    // line in the visible thinking stream. The block-level `thinking_end`
    // is emitted from `response.output_item.done`.
    const { idx } = requireBlock("thinking");
    (output.content[idx] as ThinkingContent).thinking += "\n\n";
    stream.push({ type: "thinking_delta", contentIndex: idx, delta: "\n\n", partial: output });
    return;
  }

  if (type === "response.function_call_arguments.delta") {
    const { idx, meta } = requireBlock("toolCall");
    const delta = String(payload["delta"]);
    meta.partialJson = (meta.partialJson ?? "") + delta;
    const block = output.content[idx] as ToolCall;
    block.arguments = parseStreamingJson(meta.partialJson) as Record<string, unknown>;
    stream.push({ type: "toolcall_delta", contentIndex: idx, delta, partial: output });
    return;
  }

  if (type === "response.function_call_arguments.done") {
    const { idx, meta } = requireBlock("toolCall");
    const final = payload["arguments"];
    if (typeof final !== "string") throw new Error("response.function_call_arguments.done missing string `arguments`");
    meta.partialJson = final;
    const block = output.content[idx] as ToolCall;
    block.arguments = JSON.parse(final) as Record<string, unknown>;
    stream.push({ type: "toolcall_end", contentIndex: idx, toolCall: block, partial: output });
    return;
  }

  if (type === "response.output_item.done") {
    const item = payload["item"] as Record<string, unknown> | undefined;
    if (!item) throw new Error("response.output_item.done missing `item`");
    const itemId = item["id"];
    if (typeof itemId !== "string") throw new Error("response.output_item.done missing `item.id`");
    const idx = itemIndexToContent.get(itemId);
    if (idx === undefined) throw new Error(`response.output_item.done references unknown item_id: ${itemId}`);

    if (item["type"] === "reasoning") {
      // Reconcile thinking text from the canonical summary parts and capture
      // the full item (with `encrypted_content`) into `thinkingSignature` so
      // the next request can replay it verbatim. Without this, function_call
      // items from reasoning models become unpaired on replay.
      const summary = item["summary"] as Array<{ text: string }> | undefined;
      const text = summary ? summary.map((s) => s.text).join("\n\n") : "";
      const block = output.content[idx] as ThinkingContent;
      block.thinking = text;
      block.thinkingSignature = JSON.stringify(item);
      stream.push({ type: "thinking_end", contentIndex: idx, content: text, partial: output });
    }
    // `message` and `function_call` finalization is already covered by
    // `output_text.done` and `function_call_arguments.done` respectively.
    return;
  }

  if (type === "response.completed") {
    const response = payload["response"] as Record<string, unknown> | undefined;
    applyUsage(model, output, response?.["usage"] as Record<string, unknown> | undefined);
    const status = response?.["status"] as string | undefined;
    const incomplete = (response?.["incomplete_details"] as Record<string, unknown> | undefined)?.["reason"] as string | undefined;
    output.responseId = response?.["id"] as string | undefined;
    output.stopReason = mapStopReason(status, incomplete);
    return;
  }

  if (type === "response.failed" || type === "error") {
    const errObj = (payload["response"] as Record<string, unknown> | undefined)?.["error"] ?? payload["error"] ?? payload;
    const message = (errObj as Record<string, unknown>)?.["message"] ?? JSON.stringify(errObj);
    throw new Error(typeof message === "string" ? message : JSON.stringify(message));
  }

  // Unknown / future events: silently ignored at this level.
}

// ---------------------------------------------------------------------------
// Simple wrapper
// ---------------------------------------------------------------------------

export const streamSimpleOpenaiResponses: SimpleStreamFunction<"openai-responses"> = (model, context, simple?: SimpleStreamOptions) => {
  const base = buildBaseOptions(simple);
  return streamOpenaiResponses(model, context, { ...base, reasoning: simple?.reasoning });
};
