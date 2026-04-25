// Persistent global user config at ~/.aos/config.json.
//
// Layout:
//   ~/.aos/config.json   mode 0600
//   ~/.aos/              mode 0700 (created on demand)
//
// Atomic-write pattern (sibling tmpfile + rename) so a crash during write
// can never produce a torn file. Schema is intentionally minimal — this
// round only persists the user's selected provider/model.
//
// Fail-fast contract (P2.4):
//   - file does not exist → return {} (first-run path; documented default)
//   - file exists but JSON parse fails OR a present field has the wrong type
//     → throw `MalformedConfigError`. Silently returning {} would let a
//     corrupt config silently swap the user's selected model — exactly the
//     kind of "fallback inside business state" AGENTS.md "Coding tastes"
//     forbids.
//   - missing optional fields with valid surrounding JSON → return without
//     them populated (still treated as not-set).

import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync, chmodSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";

function aosHome(): string {
  return process.env.HOME && process.env.HOME.length > 0 ? process.env.HOME : homedir();
}

export function userConfigPath(): string {
  return join(aosHome(), ".aos", "config.json");
}

export interface ModelSelection {
  providerId: string;
  modelId: string;
}

import { EFFORT_LEVELS, type Effort } from "../llm/models/catalog";

export interface UserConfig {
  selection?: ModelSelection;
  /// Global reasoning effort. Mirrors pi's `defaultThinkingLevel` — single
  /// value applied to whichever model is currently selected. Provider
  /// clamps it (or forces "off" for non-reasoning models) at request time.
  effort?: Effort;
  /// Onboarding completion gate. Flips `true` the first time the Shell
  /// observes both runtime permissions granted AND a ready provider.
  /// Once `true`, the Shell stops routing the user back to the onboard
  /// panels even if a permission or provider drops — those failures
  /// surface as inline warnings + Settings affordances instead. Cleared
  /// only by deleting `~/.aos/config.json`.
  hasCompletedOnboarding?: boolean;
}

/// Raised when the on-disk config file exists but cannot be parsed or
/// contains a field whose type does not match the schema. Distinct from
/// "file missing" so callers can surface the corruption to the user.
export class MalformedConfigError extends Error {
  constructor(message: string, public readonly cause?: unknown) {
    super(message);
    this.name = "MalformedConfigError";
  }
}

function ensureDir(path: string): void {
  const dir = dirname(path);
  if (!existsSync(dir)) {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
  }
}

export function readUserConfig(): UserConfig {
  const path = userConfigPath();
  if (!existsSync(path)) return {};

  let raw: string;
  try {
    raw = readFileSync(path, "utf-8");
  } catch (err) {
    throw new MalformedConfigError(
      `Failed to read config at ${path}: ${err instanceof Error ? err.message : String(err)}`,
      err,
    );
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    throw new MalformedConfigError(
      `Config file ${path} is not valid JSON: ${err instanceof Error ? err.message : String(err)}`,
      err,
    );
  }

  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new MalformedConfigError(
      `Config file ${path} must be a JSON object at the top level`,
    );
  }

  const obj = parsed as Record<string, unknown>;
  const out: UserConfig = {};

  // selection: either undefined OR a fully-formed { providerId, modelId } object.
  if (obj.selection !== undefined) {
    const sel = obj.selection;
    if (sel === null || typeof sel !== "object") {
      throw new MalformedConfigError(
        `Config "selection" must be an object with { providerId, modelId }`,
      );
    }
    const s = sel as Record<string, unknown>;
    if (typeof s.providerId !== "string" || typeof s.modelId !== "string") {
      throw new MalformedConfigError(
        `Config "selection" requires string providerId and modelId`,
      );
    }
    out.selection = { providerId: s.providerId, modelId: s.modelId };
  }

  // effort: undefined OR one of EFFORT_LEVELS.
  if (obj.effort !== undefined) {
    if (typeof obj.effort !== "string" || !(EFFORT_LEVELS as readonly string[]).includes(obj.effort)) {
      throw new MalformedConfigError(
        `Config "effort" must be one of ${EFFORT_LEVELS.join("|")}, got: ${JSON.stringify(obj.effort)}`,
      );
    }
    out.effort = obj.effort as Effort;
  }

  // hasCompletedOnboarding: undefined OR boolean.
  if (obj.hasCompletedOnboarding !== undefined) {
    if (typeof obj.hasCompletedOnboarding !== "boolean") {
      throw new MalformedConfigError(
        `Config "hasCompletedOnboarding" must be boolean, got: ${JSON.stringify(obj.hasCompletedOnboarding)}`,
      );
    }
    out.hasCompletedOnboarding = obj.hasCompletedOnboarding;
  }

  return out;
}

export function writeUserConfig(cfg: UserConfig): void {
  const path = userConfigPath();
  ensureDir(path);
  const tmp = path + ".tmp";
  writeFileSync(tmp, JSON.stringify(cfg, null, 2), { encoding: "utf-8", mode: 0o600 });
  try { chmodSync(tmp, 0o600); } catch {}
  renameSync(tmp, path);
  try { chmodSync(path, 0o600); } catch {}
}
