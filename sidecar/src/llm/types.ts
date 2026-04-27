// Unified LLM types for AOS sidecar.
//
// Mirrors the Message / Content / Event / Model / Options / Capability /
// Tool / Usage / StopReason contracts described in
// docs/guide/llm-providers-guide.md §2 / §3 / §7 / §8 / §9 and reused
// verbatim by docs/designs/llm-provider.md.
//
// Field names and discriminated-union variants are intentionally left
// open even when AOS does not yet emit them this round (thinking,
// toolCall, image input). Keeping the full surface lets future provider
// variants and turn-replay paths drop in without breaking call sites.

// ---------------------------------------------------------------------------
// API & Provider identity
// ---------------------------------------------------------------------------

/// Wire protocol families. AOS only registers `openai-responses` this round,
/// but the union is forward-compatible so cross-model `transformMessages`
/// can already reason about same-source vs cross-source replay.
export type Api =
  | "openai-responses"
  | "openai-completions"
  | "deepseek"
  | "anthropic-messages"
  | "google-generative-ai"
  | "bedrock-converse-stream";

/// Open string: concrete providers register themselves into the registry.
/// AOS only ships `chatgpt-plan` this round.
export type Provider = string;

// ---------------------------------------------------------------------------
// Tool / JSON Schema
// ---------------------------------------------------------------------------

/// Minimal JSON Schema description used by the in-house validator
/// (`utils/validation.ts`). We do not pull in TypeBox / AJV; the validator
/// only needs to traverse a plain JSON Schema object.
export interface JSONSchema {
  type?: "string" | "number" | "integer" | "boolean" | "object" | "array" | "null";
  description?: string;
  properties?: Record<string, JSONSchema>;
  required?: string[];
  items?: JSONSchema;
  enum?: unknown[];
  additionalProperties?: boolean | JSONSchema;
  // Pass-through for any provider-specific extensions:
  [key: string]: unknown;
}

export interface Tool<TParameters extends JSONSchema = JSONSchema> {
  name: string;
  description: string;
  parameters: TParameters;
}

// ---------------------------------------------------------------------------
// Content blocks (guide §2.2)
// ---------------------------------------------------------------------------

export interface TextContent {
  type: "text";
  text: string;
  /// Provider-specific metadata (e.g. OpenAI Responses message id).
  /// Cross-source `transformMessages` strips this.
  textSignature?: string;
}

export interface ThinkingContent {
  type: "thinking";
  thinking: string;
  /// Opaque signature required to replay reasoning back to the same model.
  thinkingSignature?: string;
  /// When the upstream redacted the thinking, `thinking` is a placeholder
  /// (e.g. "[Reasoning redacted]") and the real payload lives encrypted in
  /// `thinkingSignature`.
  redacted?: boolean;
}

export interface ImageContent {
  type: "image";
  data: string;        // base64
  mimeType: string;
}

export interface ToolCall {
  type: "toolCall";
  id: string;
  name: string;
  arguments: Record<string, unknown>;
  /// Google-specific reasoning context signature. Stripped on cross-source.
  thoughtSignature?: string;
}

export type UserContent = TextContent | ImageContent;
export type AssistantContent = TextContent | ThinkingContent | ToolCall;
export type ToolResultContent = TextContent | ImageContent;

// ---------------------------------------------------------------------------
// Messages (guide §2.1)
// ---------------------------------------------------------------------------

export interface UserMessage {
  role: "user";
  content: string | UserContent[];
  timestamp: number;
}

export interface AssistantMessage {
  role: "assistant";
  content: AssistantContent[];
  api: Api;
  provider: Provider;
  model: string;
  responseId?: string;
  usage: Usage;
  stopReason: StopReason;
  errorMessage?: string;
  /// Open-ended typed error reason. Currently used by the agent loop to
  /// detect `"authInvalidated"` and project to `provider.statusChanged`.
  /// Per docs/plans/onboarding.md §"typed auth error 传播".
  errorReason?: "authInvalidated" | "contextOverflow" | "permissionDenied";
  errorProviderId?: string;
  timestamp: number;
}

export interface ToolResultMessage<TDetails = unknown> {
  role: "toolResult";
  toolCallId: string;
  toolName: string;
  content: ToolResultContent[];
  details?: TDetails;
  isError: boolean;
  timestamp: number;
}

export type Message = UserMessage | AssistantMessage | ToolResultMessage;

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

export interface Context {
  systemPrompt?: string;
  messages: Message[];
  tools?: Tool[];
}

// ---------------------------------------------------------------------------
// Usage & StopReason (guide §8 / §9)
// ---------------------------------------------------------------------------

export interface UsageCost {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
  total: number;
}

export interface Usage {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
  totalTokens: number;
  cost: UsageCost;
}

export type StopReason = "stop" | "length" | "toolUse" | "error" | "aborted";

// ---------------------------------------------------------------------------
// Model (guide §1.1)
// ---------------------------------------------------------------------------

export type CapabilityInput = "text" | "image";

export interface ModelCost {
  input: number;       // $ per million tokens
  output: number;
  cacheRead: number;
  cacheWrite: number;
}

/// One effort level for a reasoning model.
///   - `value`  is what we put on the wire — exactly the string the
///              provider's API expects (e.g. OpenAI `"high"`, DeepSeek
///              `"max"`). Providers MUST forward it untouched; no
///              cross-provider mapping table.
///   - `label`  is the human-readable name shown in the picker UI.
export interface EffortLevel {
  value: string;
  label: string;
}

/// Per-model reasoning capability. `false` for non-reasoning models;
/// otherwise declares the model's native effort levels (each carrying
/// both wire value and UI label) and a default. The catalog is the
/// single source of truth — runtime code MUST NOT pattern-match on
/// `model.id`, and providers MUST NOT translate effort strings.
export interface ReasoningSpec {
  /// Effort levels accepted by this model, in canonical low→high order.
  /// Picker rows render exactly these entries; `value` goes on the wire
  /// untouched.
  efforts: readonly EffortLevel[];
  /// Default effort `value` (must match one of `efforts[].value`).
  /// Used when the user has never picked or has stale config from a
  /// different model.
  default: string;
}

export interface Model<TApi extends Api = Api> {
  id: string;
  name: string;
  api: TApi;
  provider: Provider;
  baseUrl: string;
  /// `false` → non-reasoning model (effort UI disabled, no
  /// `reasoning_effort` sent on the wire). Otherwise: which efforts the
  /// model accepts. See `ReasoningSpec`.
  reasoning: false | ReasoningSpec;
  input: CapabilityInput[];
  cost: ModelCost;
  contextWindow: number;
  maxTokens: number;
  headers?: Record<string, string>;
  /// Provider-specific compat overrides. Forward-compatible bag.
  compat?: Record<string, unknown>;
}

// ---------------------------------------------------------------------------
// Options (guide §7)
// ---------------------------------------------------------------------------

export interface StreamOptions {
  temperature?: number;
  maxTokens?: number;
  signal?: AbortSignal;
  apiKey?: string;
  transport?: "sse" | "websocket" | "auto";
  cacheRetention?: "none" | "short" | "long";
  sessionId?: string;
  onPayload?: (payload: unknown, model: Model<Api>) => unknown | undefined | Promise<unknown | undefined>;
  onResponse?: (response: { status: number; headers: Record<string, string> }, model: Model<Api>) => void | Promise<void>;
  headers?: Record<string, string>;
  maxRetryDelayMs?: number;
  metadata?: Record<string, unknown>;
}

export type ProviderStreamOptions = StreamOptions & Record<string, unknown>;

/// Reasoning effort is a free-form string whose value space is owned by
/// each model's `ReasoningSpec.efforts` in the catalog. There is no
/// universal enum — GPT models use `low|medium|high|xhigh`, DeepSeek
/// uses `high|max`, and providers send whatever string the catalog
/// declares straight onto the wire. `ThinkingLevel` survives as a name
/// so older imports keep compiling, but it is just `string`.
export type ThinkingLevel = string;

export interface SimpleStreamOptions extends StreamOptions {
  reasoning?: ThinkingLevel;
}

// ---------------------------------------------------------------------------
// Streaming events (guide §3.1)
// ---------------------------------------------------------------------------

export type AssistantMessageEvent =
  | { type: "start"; partial: AssistantMessage }
  | { type: "text_start"; contentIndex: number; partial: AssistantMessage }
  | { type: "text_delta"; contentIndex: number; delta: string; partial: AssistantMessage }
  | { type: "text_end"; contentIndex: number; content: string; partial: AssistantMessage }
  | { type: "thinking_start"; contentIndex: number; partial: AssistantMessage }
  | { type: "thinking_delta"; contentIndex: number; delta: string; partial: AssistantMessage }
  | { type: "thinking_end"; contentIndex: number; content: string; partial: AssistantMessage }
  | { type: "toolcall_start"; contentIndex: number; partial: AssistantMessage }
  | { type: "toolcall_delta"; contentIndex: number; delta: string; partial: AssistantMessage }
  | { type: "toolcall_end"; contentIndex: number; toolCall: ToolCall; partial: AssistantMessage }
  | { type: "done"; reason: "stop" | "length" | "toolUse"; message: AssistantMessage }
  | { type: "error"; reason: "aborted" | "error"; error: AssistantMessage };

// ---------------------------------------------------------------------------
// Stream function shape (guide §1.3)
// ---------------------------------------------------------------------------

import type { AssistantMessageEventStream } from "./utils/event-stream";

export type StreamFunction<TApi extends Api = Api, TOptions extends ProviderStreamOptions = ProviderStreamOptions> = (
  model: Model<TApi>,
  context: Context,
  options?: TOptions,
) => AssistantMessageEventStream;

export type SimpleStreamFunction<TApi extends Api = Api> = (
  model: Model<TApi>,
  context: Context,
  simpleOptions?: SimpleStreamOptions,
) => AssistantMessageEventStream;

export interface ApiProviderEntry<TApi extends Api = Api> {
  api: TApi;
  stream: StreamFunction<TApi>;
  streamSimple?: SimpleStreamFunction<TApi>;
  /// Optional id to support batch unregistration when a plugin module unloads.
  sourceId?: string;
}
