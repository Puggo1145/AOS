// Mutable model registry. Bootstraps from the built-in catalog on module
// load; user-supplied or plugin-registered models can be inserted later
// via direct mutation (out of scope for this round).

import type { Api, Model } from "../types";
import { DEFAULT_MODEL_PER_PROVIDER, MODELS } from "./catalog";

// ReasoningSpec invariant validation lives in `catalog.ts` itself (runs
// at module load), so by the time we read MODELS here every entry is
// already validated.

const modelRegistry: Map<string, Map<string, Model<Api>>> = new Map();

function bootstrap(): void {
  for (const [provider, models] of Object.entries(MODELS)) {
    const inner = new Map<string, Model<Api>>();
    for (const [id, model] of Object.entries(models as Record<string, Model<Api>>)) {
      inner.set(id, model);
    }
    modelRegistry.set(provider, inner);
  }
}
bootstrap();

export function getModel<TApi extends Api = Api>(provider: string, modelId: string): Model<TApi> {
  const inner = modelRegistry.get(provider);
  if (!inner) throw new Error(`Unknown provider: ${provider}`);
  const model = inner.get(modelId);
  if (!model) throw new Error(`Unknown model: ${provider}/${modelId}`);
  return model as Model<TApi>;
}

export function getProviders(): string[] {
  return [...modelRegistry.keys()];
}

export function getModels(provider: string): Model<Api>[] {
  const inner = modelRegistry.get(provider);
  if (!inner) return [];
  return [...inner.values()];
}

export function getDefaultModel<TApi extends Api = Api>(provider: string): Model<TApi> {
  const id = (DEFAULT_MODEL_PER_PROVIDER as Record<string, string | undefined>)[provider];
  if (!id) throw new Error(`No default model registered for provider: ${provider}`);
  return getModel<TApi>(provider, id);
}

export function modelsAreEqual(a: Model<Api>, b: Model<Api>): boolean {
  return a.id === b.id && a.provider === b.provider;
}
