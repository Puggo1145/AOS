// Agent loop model resolution — reads the user's saved model selection and
// falls back to the catalog default on first run.
//
// Per docs/designs/llm-provider.md §"包边界" the loop only depends on the
// public surface re-exported from `../llm`.

import {
	getDefaultModel,
	getModel,
	PROVIDER_IDS,
	type Model,
	type Api,
} from "../llm";
import { readUserConfig } from "../config/storage";

// ---------------------------------------------------------------------------
// Test injection point.
//
// Tests substitute the model resolver so a fake model + fake stream provider
// can be wired in without touching the global model / api registries. The
// production resolver reads the user's saved selection from the global config
// (set via the Shell settings panel → `config.set`); on a missing or stale
// selection it falls back to the catalog's `DEFAULT_MODEL_PER_PROVIDER`.
// Catalog stays the single source of truth — runtime code does not hardcode
// provider ids or model ids.
// ---------------------------------------------------------------------------

export type ModelResolver = () => Model<Api>;

/// Resolve the model the agent loop should drive.
///
/// Per P2.4: stale and malformed config are different. A *missing* selection
/// (user has never picked) silently falls back to the catalog default — that
/// is the documented first-run path. A *stale* selection (saved id no longer
/// in the catalog) throws so `runTurn`'s top-level catch surfaces it as a
/// `ui.error`. Malformed config also throws (raised by `readUserConfig`).
/// Both error paths reach the user instead of silently swapping their model.
export const defaultResolver: ModelResolver = () => {
	const cfg = readUserConfig();
	if (cfg.selection) {
		try {
			return getModel(cfg.selection.providerId, cfg.selection.modelId);
		} catch {
			throw new Error(
				`Configured model "${cfg.selection.providerId}/${cfg.selection.modelId}" is no longer available. ` +
					`Open Settings and pick a model.`,
			);
		}
	}
	return getDefaultModel(PROVIDER_IDS.chatgptPlan);
};

let modelResolver: ModelResolver = defaultResolver;

export function setModelResolver(fn: ModelResolver): void {
	modelResolver = fn;
}

export function resetModelResolver(): void {
	modelResolver = defaultResolver;
}

/// Resolve the model the agent loop should drive for this turn/compact pass.
/// Indirection through the module-level `modelResolver` variable is the test
/// seam — see `setModelResolver`/`resetModelResolver` above.
export function resolveModel(): Model<Api> {
	return modelResolver();
}
