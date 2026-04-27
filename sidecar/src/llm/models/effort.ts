// Reasoning-effort helpers. Single home for every decision driven by a
// model's `ReasoningSpec`.
//
// Each model declares its own native effort vocabulary (catalog.ts).
// There is no universal effort enum and no cross-model translation —
// callers feed the user's pick straight through and the provider sends
// the same string on the wire. The only logic here is "is this effort
// in this model's list, and if not what's the fallback".

import type { Api, Model, ReasoningSpec } from "../types";

function spec<TApi extends Api>(model: Model<TApi>): ReasoningSpec | null {
  return model.reasoning === false ? null : model.reasoning;
}

/// `true` iff the model has any reasoning capability at all.
export function supportsThinking<TApi extends Api>(model: Model<TApi>): boolean {
  return spec(model) !== null;
}

/// `true` iff the user can pick this exact effort `value` for this model.
export function supportsEffort<TApi extends Api>(
  model: Model<TApi>,
  value: string,
): boolean {
  const s = spec(model);
  return s !== null && s.efforts.some((e) => e.value === value);
}

/// All effort levels the model accepts, in canonical low→high order.
/// Empty for non-reasoning models. Wire surface (`config.get`) and the
/// Shell's effort picker both consume this directly.
export function supportedEfforts<TApi extends Api>(
  model: Model<TApi>,
): readonly { value: string; label: string }[] {
  return spec(model)?.efforts ?? [];
}

/// The model's default effort `value` (or `null` for non-reasoning
/// models). Surfaced over RPC so the Shell knows what to show in the
/// picker before the user has ever made a pick.
export function defaultEffort<TApi extends Api>(model: Model<TApi>): string | null {
  return spec(model)?.default ?? null;
}

/// Resolve the effort `value` to put on the wire for an actual request.
/// Returns `undefined` for non-reasoning models — call sites must drop
/// the field rather than send a placeholder.
///
/// Resolution order:
///   1. user's explicit pick, IF it's one of the model's supported values
///   2. the model's declared default (catalog validation guarantees it
///      exists in `efforts`, so no further fallback is needed)
export function effectiveEffort<TApi extends Api>(
  model: Model<TApi>,
  userPick: string | undefined,
): string | undefined {
  const s = spec(model);
  if (s === null) return undefined;
  if (userPick && s.efforts.some((e) => e.value === userPick)) return userPick;
  return s.default;
}

/// Bootstrap-time invariant check for a single model's `ReasoningSpec`.
/// Throws synchronously so a malformed catalog crashes the sidecar at
/// import rather than silently dispatching an unintended wire value.
///
/// Invariants enforced:
///   - reasoning models declare a non-empty `efforts` list
///   - every `efforts[].value` is a non-empty string
///   - `default` matches one of the declared `efforts[].value`s
///
/// Non-reasoning models (`reasoning: false`) have nothing to validate.
export function validateModelReasoning<TApi extends Api>(model: Model<TApi>): void {
  const s = spec(model);
  if (s === null) return;
  if (s.efforts.length === 0) {
    throw new Error(`catalog: model ${model.provider}/${model.id} declares reasoning but has no efforts`);
  }
  for (const e of s.efforts) {
    if (typeof e.value !== "string" || e.value.length === 0) {
      throw new Error(`catalog: model ${model.provider}/${model.id} has an effort with empty value`);
    }
  }
  if (!s.efforts.some((e) => e.value === s.default)) {
    throw new Error(
      `catalog: model ${model.provider}/${model.id} default ${JSON.stringify(s.default)} is not in efforts list`,
    );
  }
}
