// config.* RPC handlers — read/write the global user config and project the
// catalog (provider + model list + per-provider default + capability flags)
// for the Shell's settings UI. The catalog is the single source of truth;
// this module just translates it to the wire-friendly shape and validates
// incoming selections.

import { Dispatcher, RPCMethodError } from "../rpc/dispatcher";
import {
  RPCErrorCode,
  RPCMethod,
  type ConfigGetResult,
  type ConfigProviderEntry,
  type ConfigSetParams,
  type ConfigSetResult,
  type ConfigSetEffortParams,
  type ConfigSetEffortResult,
  type ConfigMarkOnboardingCompletedResult,
} from "../rpc/rpc-types";
import {
  DEFAULT_MODEL_PER_PROVIDER,
  MODELS,
  PROVIDER_NAMES,
  type KnownProvider,
} from "../llm/models/catalog";
import { defaultEffort, supportedEfforts, supportsEffort, supportsThinking } from "../llm/models/effort";
import type { Api, Model } from "../llm/types";
import { readUserConfig, writeUserConfig, MalformedConfigError } from "./storage";

function buildProviderCatalog(): ConfigProviderEntry[] {
  return (Object.keys(MODELS) as KnownProvider[]).map((id) => {
    const inner = MODELS[id] as Record<string, Model<Api>>;
    return {
      id,
      name: PROVIDER_NAMES[id],
      defaultModelId: DEFAULT_MODEL_PER_PROVIDER[id] as string,
      // `supportedEfforts` is the wire-side single source of truth: an
      // empty array means "no reasoning UI for this model"; a non-empty
      // list is exactly the picker rows the Shell should render. The
      // Shell never re-derives capabilities from `model.id`.
      models: Object.values(inner).map((m) => ({
        id: m.id,
        name: m.name,
        supportedEfforts: supportedEfforts(m).map((e) => ({ value: e.value, label: e.label })),
        defaultEffort: defaultEffort(m),
      })),
    };
  });
}

function isKnownSelection(providerId: string, modelId: string): boolean {
  const provider = (MODELS as Record<string, Record<string, unknown>>)[providerId];
  if (!provider) return false;
  return modelId in provider;
}

/// Returns the catalog `Model` for the user's current selection, falling
/// back to the first provider's default model if no valid selection has
/// been persisted yet (first-run / freshly-recovered config).
function resolveSelectedModel(selection: { providerId: string; modelId: string } | undefined): Model<Api> {
  if (selection && isKnownSelection(selection.providerId, selection.modelId)) {
    const inner = (MODELS as Record<string, Record<string, Model<Api>>>)[selection.providerId]!;
    return inner[selection.modelId]!;
  }
  const firstProvider = Object.keys(MODELS)[0] as KnownProvider;
  const defaultModelId = DEFAULT_MODEL_PER_PROVIDER[firstProvider] as string;
  return (MODELS as Record<string, Record<string, Model<Api>>>)[firstProvider]![defaultModelId]!;
}

export function registerConfigHandlers(dispatcher: Dispatcher): void {
  dispatcher.registerRequest(RPCMethod.configGet, async (): Promise<ConfigGetResult> => {
    // Auto-recover from corruption: AOS's user config is small (selection
    // / effort / onboarding flag) and trivially re-set, so a one-shot
    // reset + banner is a better UX than blocking the user behind a parse
    // error they can't read. The Shell shows a notice via
    // `recoveredFromCorruption` so the data loss isn't silent.
    let cfg: ReturnType<typeof readUserConfig>;
    let recoveredFromCorruption = false;
    try {
      cfg = readUserConfig();
    } catch (err) {
      // Only auto-reset content corruption (`parse` / `schema`). A `read`
      // failure means the file may still be intact (permission glitch,
      // disk error, …); overwriting it could destroy valid data, so we
      // surface the error and let the user investigate.
      if (err instanceof MalformedConfigError && err.kind !== "read") {
        writeUserConfig({});
        cfg = {};
        recoveredFromCorruption = true;
      } else if (err instanceof MalformedConfigError) {
        throw new RPCMethodError(RPCErrorCode.agentConfigInvalid, err.message);
      } else {
        throw err;
      }
    }
    return {
      selection: cfg.selection ?? null,
      effort: cfg.effort ?? null,
      providers: buildProviderCatalog(),
      hasCompletedOnboarding: cfg.hasCompletedOnboarding ?? false,
      recoveredFromCorruption,
    };
  });

  dispatcher.registerRequest(RPCMethod.configSet, async (raw): Promise<ConfigSetResult> => {
    const params = raw as ConfigSetParams;
    if (typeof params?.providerId !== "string" || typeof params?.modelId !== "string") {
      throw new RPCMethodError(RPCErrorCode.invalidParams, "config.set requires { providerId, modelId }");
    }
    if (!isKnownSelection(params.providerId, params.modelId)) {
      throw new RPCMethodError(
        RPCErrorCode.invalidParams,
        `unknown selection: ${params.providerId}/${params.modelId}`,
      );
    }
    const selection = { providerId: params.providerId, modelId: params.modelId };
    // If the existing file is corrupt, the user picking a new selection is
    // exactly the recovery moment — write a fresh config rather than refuse.
    const existing = readMergedConfigOrEmpty();
    writeUserConfig({ ...existing, selection });
    return { selection };
  });

  dispatcher.registerRequest(RPCMethod.configSetEffort, async (raw): Promise<ConfigSetEffortResult> => {
    const params = raw as ConfigSetEffortParams;
    if (typeof params?.effort !== "string" || params.effort.length === 0) {
      throw new RPCMethodError(
        RPCErrorCode.invalidParams,
        `config.setEffort requires { effort: non-empty string }`,
      );
    }
    // Validate against the currently-selected model's native effort
    // vocabulary. Persisting an unsupported value would be silently
    // masked by `effectiveEffort` at request time — better to reject
    // here so UI bugs / external RPC callers fail loud. (Cross-model
    // staleness — saved value valid for the previous model but not the
    // newly-selected one — is a separate concern handled by the runtime
    // fallback in `effectiveEffort`.)
    const existing = readMergedConfigOrEmpty();
    const model = resolveSelectedModel(existing.selection);
    if (!supportsThinking(model)) {
      throw new RPCMethodError(
        RPCErrorCode.invalidParams,
        `config.setEffort: model ${model.provider}/${model.id} does not support reasoning effort`,
      );
    }
    if (!supportsEffort(model, params.effort)) {
      throw new RPCMethodError(
        RPCErrorCode.invalidParams,
        `config.setEffort: ${JSON.stringify(params.effort)} is not a supported effort for ${model.provider}/${model.id}`,
      );
    }
    writeUserConfig({ ...existing, effort: params.effort });
    return { effort: params.effort };
  });

  dispatcher.registerRequest(RPCMethod.configMarkOnboardingCompleted, async (): Promise<ConfigMarkOnboardingCompletedResult> => {
    // Idempotent latch fired automatically by the Shell — NOT a user
    // recovery moment, so unlike `config.set` we must not paper over a
    // malformed file with `{}` (would silently lose `selection`/`effort`).
    // Surface the typed error and let the user fix the file by hand.
    let existing: ReturnType<typeof readUserConfig>;
    try {
      existing = readUserConfig();
    } catch (err) {
      if (err instanceof MalformedConfigError) {
        throw new RPCMethodError(RPCErrorCode.agentConfigInvalid, err.message);
      }
      throw err;
    }
    writeUserConfig({ ...existing, hasCompletedOnboarding: true });
    return { hasCompletedOnboarding: true };
  });
}

/// Used by `config.set` and `config.setEffort` to merge a user's incoming
/// change with the existing on-disk config. If the existing file is corrupt,
/// treat it as empty: the user's `set` action is the recovery path.
function readMergedConfigOrEmpty(): ReturnType<typeof readUserConfig> {
  try {
    return readUserConfig();
  } catch (err) {
    if (err instanceof MalformedConfigError) return {};
    throw err;
  }
}
