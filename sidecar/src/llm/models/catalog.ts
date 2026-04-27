// Built-in model & provider catalog — single source of truth.
//
// Runtime code MUST NOT hardcode provider ids, model ids, display names,
// default-model selection, OR per-model reasoning capability. Import
// the constants/types exported here and the helpers in `./effort.ts`
// for everything reasoning-related.
//
// Reasoning effort is per-model. Each model's `ReasoningSpec.efforts`
// declares the EXACT strings the provider's API accepts (so GPT models
// list `low|medium|high|xhigh`, DeepSeek lists `high|max`). Providers
// forward the chosen `value` to the wire untouched — no cross-provider
// mapping table, no glue code.

import type { Api, EffortLevel, Model, ReasoningSpec } from "../types";
import { validateModelReasoning } from "./effort";

// ---------------------------------------------------------------------------
// Per-model reasoning specs
// ---------------------------------------------------------------------------

/// Codex Subscription (ChatGPT plan) reasoning models. The GPT-5.x line
/// accepts `low | medium | high | xhigh` for `reasoning.effort` (the
/// `minimal` tier from older OpenAI docs is not part of this family).
const GPT_REASONING: ReasoningSpec = {
  efforts: [
    { value: "low", label: "Low" },
    { value: "medium", label: "Medium" },
    { value: "high", label: "High" },
    { value: "xhigh", label: "Extra High" },
  ],
  default: "medium",
};

/// DeepSeek V4 reasoning models. Per api-docs.deepseek.com (verified
/// 2026-04-26) the V4 chat-completions endpoint accepts `high` (default)
/// and `max` for `reasoning_effort`. We expose both as picker rows.
const DEEPSEEK_REASONING: ReasoningSpec = {
  efforts: [
    { value: "high", label: "High" },
    { value: "max", label: "Max" },
  ],
  default: "high",
};

export const MODELS = {
  "chatgpt-plan": {
    "gpt-5.5": {
      id: "gpt-5.5",
      name: "GPT-5.5",
      api: "openai-responses",
      provider: "chatgpt-plan",
      baseUrl: "https://chatgpt.com/backend-api/codex",
      reasoning: GPT_REASONING,
      input: ["text", "image"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 400_000,
      maxTokens: 128_000,
    },
    "gpt-5.4": {
      id: "gpt-5.4",
      name: "GPT-5.4",
      api: "openai-responses",
      provider: "chatgpt-plan",
      baseUrl: "https://chatgpt.com/backend-api/codex",
      reasoning: GPT_REASONING,
      input: ["text", "image"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 272_000,
      maxTokens: 128_000,
    },
    "gpt-5.3-codex": {
      id: "gpt-5.3-codex",
      name: "GPT-5.3 Codex",
      api: "openai-responses",
      provider: "chatgpt-plan",
      baseUrl: "https://chatgpt.com/backend-api/codex",
      reasoning: GPT_REASONING,
      input: ["text", "image"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 272_000,
      maxTokens: 128_000,
    },
  },
  // Sourced from api-docs.deepseek.com (2026-04-26). Both models stream
  // reasoning via `delta.reasoning_content` and bill cache reads at a steep
  // discount; cache writes are not separately billed (`cacheWrite: 0`).
  "deepseek": {
    "deepseek-v4-flash": {
      id: "deepseek-v4-flash",
      name: "DeepSeek V4 Flash",
      api: "deepseek",
      provider: "deepseek",
      baseUrl: "https://api.deepseek.com",
      reasoning: DEEPSEEK_REASONING,
      input: ["text"],
      cost: { input: 0.14, output: 0.28, cacheRead: 0.0028, cacheWrite: 0 },
      contextWindow: 1_000_000,
      maxTokens: 384_000,
    },
    "deepseek-v4-pro": {
      id: "deepseek-v4-pro",
      name: "DeepSeek V4 Pro",
      api: "deepseek",
      provider: "deepseek",
      baseUrl: "https://api.deepseek.com",
      reasoning: DEEPSEEK_REASONING,
      input: ["text"],
      cost: { input: 0.435, output: 0.87, cacheRead: 0.003625, cacheWrite: 0 },
      contextWindow: 1_000_000,
      maxTokens: 384_000,
    },
  },
} as const satisfies Record<string, Record<string, Model<Api>>>;

export type KnownProvider = keyof typeof MODELS;
export type KnownModelId<P extends KnownProvider> = keyof (typeof MODELS)[P];

/// Stable provider-id constants. Runtime code references these rather
/// than the bare string literal, so a future rename only touches this
/// file. `satisfies` ensures every value is an actual catalog key.
export const PROVIDER_IDS = {
  chatgptPlan: "chatgpt-plan",
  deepseek: "deepseek",
} as const satisfies Record<string, KnownProvider>;

/// Human-readable display names (shown in Onboarding cards, model
/// pickers, etc). Keyed by the same provider id as `MODELS`.
export const PROVIDER_NAMES: Record<KnownProvider, string> = {
  "chatgpt-plan": "Codex Subscription",
  "deepseek": "DeepSeek",
};

/// Default model id per provider. Used when no explicit selection is
/// configured (boot, fresh session, etc).
export const DEFAULT_MODEL_PER_PROVIDER: { [P in KnownProvider]: KnownModelId<P> } = {
  "chatgpt-plan": "gpt-5.5",
  "deepseek": "deepseek-v4-flash",
};

// Re-export the effort types so callers that already import from this
// module don't need a second import path for the same concept.
export type { EffortLevel };

/// Convenience: look up a model object's `api` field from the catalog.
/// Used by callers that want to keep `Api` types tight.
export type ModelApiOf<P extends KnownProvider, M extends KnownModelId<P>> =
  (typeof MODELS)[P][M] extends Model<infer A extends Api> ? A : never;

// Catalog-load fail-fast: every consumer of MODELS imports this module,
// so validating here (rather than in registry bootstrap) guarantees the
// invariant fires for every code path — including `config/handlers.ts`,
// which reads MODELS directly without going through the registry.
for (const inner of Object.values(MODELS)) {
  for (const model of Object.values(inner as Record<string, Model<Api>>)) {
    validateModelReasoning(model);
  }
}
