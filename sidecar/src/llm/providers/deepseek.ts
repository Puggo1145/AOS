// DeepSeek provider — thin wrapper over `openai-completions`.
//
// DeepSeek is OpenAI Chat-Completions compatible, but rejects a handful of
// fields that vanilla OpenAI accepts. We isolate those quirks in a single
// `compat` object and delegate the actual streaming engine to
// `runCompletionsStream`. Per docs/designs/llm-provider.md "包边界" this file
// is the *only* place that knows about DeepSeek-specific behavior.
//
// Quirks captured here (sourced from api-docs.deepseek.com, 2026-04-26):
//   - Rejects `store: false` and the `developer` system role → both off.
//   - `reasoning_effort` IS supported on V4, with a model-native value
//     space: `"high"` (default) and `"max"`. The catalog declares those
//     two values verbatim, so the string the user picks goes onto the
//     wire untouched — no cross-provider mapping table here.
//   - Reasoning text streams via `delta.reasoning_content` (not
//     `reasoning`).
//   - The `max_tokens` field is the legacy spelling — DeepSeek's docs use
//     it exclusively, `max_completion_tokens` is unrecognized.
//   - V4 thinking mode REQUIRES prior-turn `reasoning_content` to be echoed
//     back on the assistant message — omitting it 400s with "The
//     reasoning_content in the thinking mode must be passed back to the API"
//     on the next round (most visibly on tool-call follow-ups). The replay
//     is wired in `openai-completions.ts::convertMessages`, gated on
//     `compat.reasoningField` + `supportsThinking(model)`.

import type {
  SimpleStreamFunction,
  SimpleStreamOptions,
  StreamFunction,
} from "../types";
import {
  type OpenAICompletionsCompat,
  type OpenAICompletionsOptions,
  resolveCompat,
  runCompletionsStream,
} from "./openai-completions";
import { buildBaseOptions } from "./simple-options";

const DEEPSEEK_COMPAT_RAW: OpenAICompletionsCompat = {
  supportsStore: false,
  supportsDeveloperRole: false,
  supportsReasoningEffort: true,
  maxTokensField: "max_tokens",
  reasoningField: "reasoning_content",
  requiresToolResultName: false,
};

const DEEPSEEK_COMPAT = resolveCompat(DEEPSEEK_COMPAT_RAW);

export const streamDeepseek: StreamFunction<"deepseek", OpenAICompletionsOptions> = (
  model,
  context,
  options,
) => runCompletionsStream(model, context, options, DEEPSEEK_COMPAT);

export const streamSimpleDeepseek: SimpleStreamFunction<"deepseek"> = (
  model,
  context,
  simple?: SimpleStreamOptions,
) => {
  const base = buildBaseOptions(simple);
  return runCompletionsStream(
    model,
    context,
    { ...base, reasoningEffort: simple?.reasoning },
    DEEPSEEK_COMPAT,
  );
};
