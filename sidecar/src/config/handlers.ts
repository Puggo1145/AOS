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
  DEFAULT_EFFORT,
  DEFAULT_MODEL_PER_PROVIDER,
  EFFORT_LEVELS,
  MODELS,
  PROVIDER_NAMES,
  type Effort,
  type KnownProvider,
} from "../llm/models/catalog";
import { supportsXhigh } from "../llm/models/capabilities";
import type { Api, Model } from "../llm/types";
import { readUserConfig, writeUserConfig, MalformedConfigError } from "./storage";

function buildProviderCatalog(): ConfigProviderEntry[] {
  return (Object.keys(MODELS) as KnownProvider[]).map((id) => {
    const inner = MODELS[id] as Record<string, Model<Api>>;
    return {
      id,
      name: PROVIDER_NAMES[id],
      defaultModelId: DEFAULT_MODEL_PER_PROVIDER[id] as string,
      models: Object.values(inner).map((m) => ({
        id: m.id,
        name: m.name,
        reasoning: m.reasoning,
        supportsXhigh: supportsXhigh(m),
      })),
    };
  });
}

function isKnownSelection(providerId: string, modelId: string): boolean {
  const provider = (MODELS as Record<string, Record<string, unknown>>)[providerId];
  if (!provider) return false;
  return modelId in provider;
}

function isKnownEffort(value: unknown): value is Effort {
  return typeof value === "string" && (EFFORT_LEVELS as readonly string[]).includes(value);
}

export function registerConfigHandlers(dispatcher: Dispatcher): void {
  dispatcher.registerRequest(RPCMethod.configGet, async (): Promise<ConfigGetResult> => {
    let cfg: ReturnType<typeof readUserConfig>;
    try {
      cfg = readUserConfig();
    } catch (err) {
      // Malformed config surfaces as a typed RPC error so the Shell can show
      // a "your config file is corrupt" affordance instead of silently
      // restoring defaults. Per P2.4 fail-fast contract.
      if (err instanceof MalformedConfigError) {
        throw new RPCMethodError(RPCErrorCode.agentConfigInvalid, err.message);
      }
      throw err;
    }
    return {
      selection: cfg.selection ?? null,
      effort: cfg.effort ?? null,
      defaultEffort: DEFAULT_EFFORT,
      providers: buildProviderCatalog(),
      hasCompletedOnboarding: cfg.hasCompletedOnboarding ?? false,
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
    if (!isKnownEffort(params?.effort)) {
      throw new RPCMethodError(
        RPCErrorCode.invalidParams,
        `config.setEffort requires { effort: one of ${EFFORT_LEVELS.join("|")} }`,
      );
    }
    const existing = readMergedConfigOrEmpty();
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
