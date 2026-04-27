// OpenAI Chat Completions API streaming provider.
//
// A subset port of pi-mono's `openai-completions.ts` (~1100 lines). We kept
// only what AOS needs in this round: streaming text + reasoning + tool calls,
// usage + cost, transformMessages-driven cross-source replay normalization.
//
// Stripped (intentional, YAGNI):
//   - Anthropic cache_control / OpenRouter routing / Vercel Gateway / Copilot
//     headers / Z.AI / Qwen / Moonshot thinking variants / prompt_cache_key
//     plumbing / session affinity headers / reasoning_details replay.
//   - Assistant thinking replay: chat-completions providers (notably DeepSeek)
//     reject `reasoning_content` echoed in conversation history. We drop
//     `thinking` blocks at convertMessages time instead of plumbing a
//     per-provider signature field.
//
// Design boundary: `runCompletionsStream` is generic over `Api` so a thin
// per-provider wrapper (e.g. `deepseek.ts`) can supply its own compat profile
// and reuse the engine without touching this file.

import { createParser, type EventSourceMessage } from "eventsource-parser";

import type {
  Api,
  AssistantMessage,
  AssistantContent,
  Context,
  Message,
  Model,
  ProviderStreamOptions,
  SimpleStreamFunction,
  SimpleStreamOptions,
  StopReason,
  StreamFunction,
  TextContent,
  ToolCall,
  ToolResultContent,
  ThinkingLevel,
  Usage,
} from "../types";
import { AssistantMessageEventStream } from "../utils/event-stream";
import { calculateCost } from "../models/cost";
import { sanitizeSurrogates } from "../utils/sanitize-unicode";
import { mergeHeaders } from "../utils/headers";
import { parseStreamingJson } from "../utils/json-parse";
import { getEnvApiKey } from "../auth/env-api-keys";
import { transformMessages } from "./transform-messages";
import { buildBaseOptions } from "./simple-options";
import { supportsThinking } from "../models/effort";

// ---------------------------------------------------------------------------
// Public option / compat surface
// ---------------------------------------------------------------------------

export interface OpenAICompletionsOptions extends ProviderStreamOptions {
  reasoningEffort?: ThinkingLevel;
  toolChoice?: "auto" | "none" | "required" | { type: "function"; function: { name: string } };
}

/// Per-model compat knobs. Wrappers (deepseek.ts) construct one of these
/// and hand it to `runCompletionsStream`. Defaults match vanilla OpenAI.
export interface OpenAICompletionsCompat {
  /// Send `store: false`. OpenAI Chat Completions accepts it; some
  /// non-OpenAI compatible endpoints 400 on unknown fields.
  supportsStore?: boolean;
  /// Use the `developer` role instead of `system` for system prompts.
  /// Reasoning OpenAI models (o-series, gpt-5) prefer this.
  supportsDeveloperRole?: boolean;
  /// Send the `reasoning_effort` param. DeepSeek does NOT accept it.
  supportsReasoningEffort?: boolean;
  /// `max_tokens` (legacy / DeepSeek) vs `max_completion_tokens` (OpenAI).
  maxTokensField?: "max_tokens" | "max_completion_tokens";
  /// Streaming chunk delta field carrying reasoning text.
  /// OpenAI: not exposed via Chat Completions (use Responses API).
  /// DeepSeek: `reasoning_content`.
  /// Some other OpenAI-compat endpoints: `reasoning` or `reasoning_text`.
  reasoningField?: "reasoning_content" | "reasoning" | "reasoning_text";
  /// Tool result message must include the `name` field.
  requiresToolResultName?: boolean;
}

const DEFAULT_COMPAT: Required<OpenAICompletionsCompat> = {
  supportsStore: true,
  supportsDeveloperRole: true,
  supportsReasoningEffort: true,
  maxTokensField: "max_completion_tokens",
  reasoningField: "reasoning_content",
  requiresToolResultName: false,
};

function resolveCompat(c?: OpenAICompletionsCompat): Required<OpenAICompletionsCompat> {
  if (!c) return DEFAULT_COMPAT;
  return { ...DEFAULT_COMPAT, ...c };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function emptyUsage(): Usage {
  return {
    input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
  };
}

function makeOutput<TApi extends Api>(model: Model<TApi>): AssistantMessage {
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

function mapStopReason(reason: string | null | undefined): { stopReason: StopReason; errorMessage?: string } {
  if (reason == null || reason === "stop" || reason === "end") return { stopReason: "stop" };
  if (reason === "length") return { stopReason: "length" };
  if (reason === "tool_calls" || reason === "function_call") return { stopReason: "toolUse" };
  if (reason === "content_filter") return { stopReason: "error", errorMessage: "Provider finish_reason: content_filter" };
  return { stopReason: "error", errorMessage: `Provider finish_reason: ${reason}` };
}

/// Parse a usage payload from a streaming chunk.
/// Handles both OpenAI's `prompt_tokens_details.cached_tokens` and DeepSeek's
/// flat `prompt_cache_hit_tokens` / `prompt_cache_miss_tokens` layout.
function parseChunkUsage<TApi extends Api>(
  raw: Record<string, unknown>,
  model: Model<TApi>,
): Usage {
  const promptTokens = Number(raw["prompt_tokens"] ?? 0);
  const completionTokens = Number(raw["completion_tokens"] ?? 0);
  const details = (raw["prompt_tokens_details"] as Record<string, unknown> | undefined) ?? {};
  const cacheHit =
    Number(raw["prompt_cache_hit_tokens"] ?? details["cached_tokens"] ?? 0);
  const input = Math.max(0, promptTokens - cacheHit);
  const usage: Usage = {
    input,
    output: completionTokens,
    cacheRead: cacheHit,
    cacheWrite: 0,
    totalTokens: input + completionTokens + cacheHit,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
  };
  calculateCost(model, usage);
  return usage;
}

// ---------------------------------------------------------------------------
// Message conversion
// ---------------------------------------------------------------------------

interface ChatMessage {
  role: "system" | "developer" | "user" | "assistant" | "tool";
  content?: unknown;
  name?: string;
  tool_calls?: Array<{ id: string; type: "function"; function: { name: string; arguments: string } }>;
  tool_call_id?: string;
}

function isText(b: AssistantContent | UserContentBlock): b is TextContent {
  return b.type === "text";
}

type UserContentBlock = TextContent | { type: "image"; data: string; mimeType: string };

/// Normalize tool call ids: native OpenAI strict-mode caps at 40 chars;
/// `|` from openai-responses ids must be stripped for any chat-completions
/// endpoint regardless of provider.
function normalizeToolCallId<TApi extends Api>(id: string, model: Model<TApi>): string {
  if (id.includes("|")) {
    const head = id.split("|")[0]!;
    return head.replace(/[^a-zA-Z0-9_-]/g, "_").slice(0, 40);
  }
  if (model.provider === "openai") return id.length > 40 ? id.slice(0, 40) : id;
  return id;
}

function convertMessages<TApi extends Api>(
  context: Context,
  model: Model<TApi>,
  compat: Required<OpenAICompletionsCompat>,
): ChatMessage[] {
  const out: ChatMessage[] = [];
  const transformed = transformMessages(context.messages, model, (id) => normalizeToolCallId(id, model));

  if (context.systemPrompt) {
    const role = supportsThinking(model) && compat.supportsDeveloperRole ? "developer" : "system";
    out.push({ role, content: sanitizeSurrogates(context.systemPrompt) });
  }

  for (const msg of transformed) {
    if (msg.role === "user") {
      if (typeof msg.content === "string") {
        out.push({ role: "user", content: sanitizeSurrogates(msg.content) });
      } else {
        const parts = msg.content.map((b) =>
          b.type === "text"
            ? { type: "text", text: sanitizeSurrogates(b.text) }
            : { type: "image_url", image_url: { url: `data:${b.mimeType};base64,${b.data}` } },
        );
        if (parts.length > 0) out.push({ role: "user", content: parts });
      }
      continue;
    }

    if (msg.role === "assistant") {
      // We deliberately drop `thinking` blocks — the chat-completions wire
      // protocol has no replayable reasoning payload (see file header).
      const textParts = msg.content
        .filter(isText)
        .filter((b) => b.text.trim().length > 0)
        .map((b) => sanitizeSurrogates(b.text));
      const toolCalls = msg.content.filter((b): b is ToolCall => b.type === "toolCall");

      const am: ChatMessage = { role: "assistant" };
      if (textParts.length > 0) am.content = textParts.join("");
      if (toolCalls.length > 0) {
        am.tool_calls = toolCalls.map((tc) => ({
          id: tc.id,
          type: "function" as const,
          function: { name: tc.name, arguments: JSON.stringify(tc.arguments) },
        }));
      }
      // Skip empty assistant turns — providers reject "no content + no tools".
      if (am.content === undefined && !am.tool_calls) continue;
      if (am.content === undefined) am.content = null;
      out.push(am);
      continue;
    }

    // toolResult — group images into a synthetic following user message.
    const tr = msg;
    const text = tr.content.filter(isText).map((b) => b.text).join("\n");
    const tm: ChatMessage = {
      role: "tool",
      content: sanitizeSurrogates(text || "(see attached image)"),
      tool_call_id: tr.toolCallId,
    };
    if (compat.requiresToolResultName) tm.name = tr.toolName;
    out.push(tm);

    const images = tr.content.filter((b): b is Extract<ToolResultContent, { type: "image" }> => b.type === "image");
    if (images.length > 0 && model.input.includes("image")) {
      out.push({
        role: "user",
        content: [
          { type: "text", text: "Attached image(s) from tool result:" },
          ...images.map((b) => ({ type: "image_url", image_url: { url: `data:${b.mimeType};base64,${b.data}` } })),
        ],
      });
    }
  }

  return out;
}

// ---------------------------------------------------------------------------
// Payload
// ---------------------------------------------------------------------------

export function buildPayload<TApi extends Api>(
  model: Model<TApi>,
  context: Context,
  options: OpenAICompletionsOptions | undefined,
  compat: Required<OpenAICompletionsCompat>,
): Record<string, unknown> {
  const payload: Record<string, unknown> = {
    model: model.id,
    messages: convertMessages(context, model, compat),
    stream: true,
    stream_options: { include_usage: true },
  };
  if (compat.supportsStore) payload["store"] = false;

  if (options?.maxTokens !== undefined) {
    payload[compat.maxTokensField] = options.maxTokens;
  }
  if (options?.temperature !== undefined) payload["temperature"] = options.temperature;

  if (context.tools && context.tools.length > 0) {
    payload["tools"] = context.tools.map((t) => ({
      type: "function",
      function: { name: t.name, description: t.description, parameters: t.parameters },
    }));
  }

  if (options?.toolChoice) payload["tool_choice"] = options.toolChoice;

  if (options?.reasoningEffort && supportsThinking(model) && compat.supportsReasoningEffort) {
    payload["reasoning_effort"] = options.reasoningEffort;
  }

  return payload;
}

// ---------------------------------------------------------------------------
// Engine
// ---------------------------------------------------------------------------

/// Generic chat-completions streaming engine. Per-provider wrappers (e.g.
/// `deepseek.ts`) thin-wrap this with their own compat profile.
export function runCompletionsStream<TApi extends Api>(
  model: Model<TApi>,
  context: Context,
  options: OpenAICompletionsOptions | undefined,
  compat: Required<OpenAICompletionsCompat>,
): AssistantMessageEventStream {
  const stream = new AssistantMessageEventStream();
  const output = makeOutput(model);

  // Per-content scratch state. `partialJson` accumulates streamed argument
  // chunks for tool calls; `streamIndex` disambiguates parallel calls when
  // the upstream emits chunks out-of-order keyed by their array index.
  interface BlockState { kind: "text" | "thinking" | "toolCall"; partialJson?: string; streamIndex?: number }
  const blocks: BlockState[] = [];
  let currentIdx = -1;

  const finishCurrent = () => {
    if (currentIdx < 0) return;
    const meta = blocks[currentIdx]!;
    const block = output.content[currentIdx]!;
    if (meta.kind === "text" && block.type === "text") {
      stream.push({ type: "text_end", contentIndex: currentIdx, content: block.text, partial: output });
    } else if (meta.kind === "thinking" && block.type === "thinking") {
      stream.push({ type: "thinking_end", contentIndex: currentIdx, content: block.thinking, partial: output });
    } else if (meta.kind === "toolCall" && block.type === "toolCall") {
      block.arguments = parseStreamingJson(meta.partialJson);
      stream.push({ type: "toolcall_end", contentIndex: currentIdx, toolCall: block, partial: output });
    }
    currentIdx = -1;
  };

  const openBlock = (kind: BlockState["kind"], init: () => AssistantContent, streamIndex?: number): number => {
    finishCurrent();
    const block = init();
    output.content.push(block);
    const idx = output.content.length - 1;
    blocks.push({ kind, partialJson: kind === "toolCall" ? "" : undefined, streamIndex });
    currentIdx = idx;
    if (kind === "text") stream.push({ type: "text_start", contentIndex: idx, partial: output });
    else if (kind === "thinking") stream.push({ type: "thinking_start", contentIndex: idx, partial: output });
    else stream.push({ type: "toolcall_start", contentIndex: idx, partial: output });
    return idx;
  };

  void (async () => {
    try {
      const apiKey = options?.apiKey ?? getEnvApiKey(model.provider);
      if (typeof apiKey !== "string" || apiKey.length === 0) {
        throw new Error(`No API key for provider: ${model.provider}`);
      }

      const headers = mergeHeaders(
        {
          "content-type": "application/json",
          accept: "text/event-stream",
          authorization: `Bearer ${apiKey}`,
        },
        model.headers,
        options?.headers,
      );

      let payload: unknown = buildPayload(model, context, options, compat);
      if (options?.onPayload) {
        const overridden = await options.onPayload(payload, model);
        if (overridden !== undefined) payload = overridden;
      }

      stream.push({ type: "start", partial: output });

      const url = `${model.baseUrl.replace(/\/$/, "")}/chat/completions`;
      const res = await fetch(url, {
        method: "POST",
        headers,
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

      const parser = createParser({
        onEvent: (ev: EventSourceMessage) => {
          if (!ev.data || ev.data === "[DONE]") return;
          let chunk: Record<string, unknown>;
          try {
            chunk = JSON.parse(ev.data);
          } catch (err) {
            process.stderr.write(`[openai-completions] bad chunk JSON: ${String(err)}\n`);
            return;
          }
          handleChunk(chunk);
        },
      });

      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      while (true) {
        if (options?.signal?.aborted) throw new DOMException("aborted", "AbortError");
        const { value, done } = await reader.read();
        if (done) break;
        parser.feed(decoder.decode(value, { stream: true }));
      }

      finishCurrent();
      stream.push({ type: "done", reason: output.stopReason === "length" ? "length" : output.stopReason === "toolUse" ? "toolUse" : "stop", message: output });
      stream.end();
    } catch (error) {
      output.stopReason = options?.signal?.aborted ? "aborted" : "error";
      output.errorMessage = error instanceof Error ? error.message : JSON.stringify(error);
      stream.push({ type: "error", reason: output.stopReason, error: output });
      stream.end();
    }
  })();

  function handleChunk(chunk: Record<string, unknown>): void {
    const usage = chunk["usage"] as Record<string, unknown> | undefined;
    if (usage) output.usage = parseChunkUsage(usage, model);

    output.responseId ??= chunk["id"] as string | undefined;

    const choices = chunk["choices"] as Array<Record<string, unknown>> | undefined;
    const choice = choices?.[0];
    if (!choice) return;

    const finishReason = choice["finish_reason"] as string | null | undefined;
    if (finishReason) {
      const r = mapStopReason(finishReason);
      output.stopReason = r.stopReason;
      if (r.errorMessage) output.errorMessage = r.errorMessage;
    }

    const delta = choice["delta"] as Record<string, unknown> | undefined;
    if (!delta) return;

    // Reasoning text first — DeepSeek emits reasoning_content before
    // switching to content. Order matters so the visible text block opens
    // after the thinking block closes.
    const reasoningField = compat.reasoningField;
    const reasoningRaw = reasoningField ? delta[reasoningField] : undefined;
    if (typeof reasoningRaw === "string" && reasoningRaw.length > 0) {
      let idx = currentIdx;
      const meta = idx >= 0 ? blocks[idx] : undefined;
      if (!meta || meta.kind !== "thinking") {
        idx = openBlock("thinking", () => ({ type: "thinking", thinking: "" }));
      }
      const block = output.content[idx]! as { type: "thinking"; thinking: string };
      block.thinking += reasoningRaw;
      stream.push({ type: "thinking_delta", contentIndex: idx, delta: reasoningRaw, partial: output });
    }

    const contentRaw = delta["content"];
    if (typeof contentRaw === "string" && contentRaw.length > 0) {
      let idx = currentIdx;
      const meta = idx >= 0 ? blocks[idx] : undefined;
      if (!meta || meta.kind !== "text") {
        idx = openBlock("text", () => ({ type: "text", text: "" }));
      }
      const block = output.content[idx]! as TextContent;
      block.text += contentRaw;
      stream.push({ type: "text_delta", contentIndex: idx, delta: contentRaw, partial: output });
    }

    const toolCallDeltas = delta["tool_calls"] as
      | Array<{ index?: number; id?: string; function?: { name?: string; arguments?: string } }>
      | undefined;
    if (toolCallDeltas) {
      for (const tcd of toolCallDeltas) {
        const sIdx = typeof tcd.index === "number" ? tcd.index : undefined;
        let idx = currentIdx;
        let meta = idx >= 0 ? blocks[idx] : undefined;
        const sameCall =
          meta?.kind === "toolCall" &&
          ((sIdx !== undefined && meta.streamIndex === sIdx) ||
            (sIdx === undefined && tcd.id !== undefined && (output.content[idx!] as ToolCall).id === tcd.id));
        if (!sameCall) {
          idx = openBlock(
            "toolCall",
            () => ({ type: "toolCall", id: tcd.id ?? "", name: tcd.function?.name ?? "", arguments: {} }),
            sIdx,
          );
          meta = blocks[idx];
        }
        const block = output.content[idx!] as ToolCall;
        if (!block.id && tcd.id) block.id = tcd.id;
        if (!block.name && tcd.function?.name) block.name = tcd.function.name;
        const argDelta = tcd.function?.arguments ?? "";
        if (argDelta.length > 0) {
          meta!.partialJson = (meta!.partialJson ?? "") + argDelta;
          block.arguments = parseStreamingJson(meta!.partialJson) as Record<string, unknown>;
          stream.push({ type: "toolcall_delta", contentIndex: idx!, delta: argDelta, partial: output });
        }
      }
    }
  }

  return stream;
}

// ---------------------------------------------------------------------------
// Public stream functions for the generic `openai-completions` Api
// ---------------------------------------------------------------------------

export const streamOpenAICompletions: StreamFunction<"openai-completions", OpenAICompletionsOptions> = (
  model,
  context,
  options,
) => runCompletionsStream(model, context, options, DEFAULT_COMPAT);

export const streamSimpleOpenAICompletions: SimpleStreamFunction<"openai-completions"> = (
  model,
  context,
  simple?: SimpleStreamOptions,
) => {
  const base = buildBaseOptions(simple);
  return runCompletionsStream(model, context, { ...base, reasoningEffort: simple?.reasoning }, DEFAULT_COMPAT);
};

// Re-exported so `deepseek.ts` (and future per-provider wrappers) can
// build their compat object without re-deriving defaults.
export { resolveCompat };
