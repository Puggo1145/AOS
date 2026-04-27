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
// Read contract:
//   - file does not exist → return {} (first-run path; documented default)
//   - file content is invalid (JSON parse fail OR field with wrong type)
//     → throw `MalformedConfigError(kind: "parse" | "schema")`. The config.get
//     handler turns this into an explicit, user-visible reset (banner +
//     fresh `{}`); it is NOT a silent fallback.
//   - file IO fails (permission denied, disk error, …)
//     → throw `MalformedConfigError(kind: "read")`. Callers MUST NOT treat
//     this as content corruption — auto-resetting on a transient IO error
//     could destroy a still-good config. `config.get` lets these propagate
//     so the user sees the error.
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

export interface UserConfig {
  selection?: ModelSelection;
  /// Global reasoning effort, stored as the wire `value` of one of the
  /// currently-selected model's `supportedEfforts`. Per-model effort
  /// vocabulary lives in the catalog; we do not validate the string
  /// against a closed enum here — `effectiveEffort` decides whether the
  /// saved pick is still usable for the active model and falls back to
  /// the model's default otherwise.
  effort?: string;
  /// Onboarding completion gate. Flips `true` the first time the Shell
  /// observes both runtime permissions granted AND a ready provider.
  /// Once `true`, the Shell stops routing the user back to the onboard
  /// panels even if a permission or provider drops — those failures
  /// surface as inline warnings + Settings affordances instead. Cleared
  /// only by deleting `~/.aos/config.json`.
  hasCompletedOnboarding?: boolean;
}

/// Raised when the on-disk config file exists but cannot be loaded.
/// `kind` tells callers what failed: `read` is an IO error (permission /
/// disk), `parse` is JSON malformed, `schema` is JSON valid but a field
/// has the wrong type. `config.get` auto-recovers `parse`/`schema` (the
/// content is unrecoverable anyway) but propagates `read` (the file may
/// still be intact — don't overwrite blindly).
export type MalformedConfigKind = "read" | "parse" | "schema";

export class MalformedConfigError extends Error {
  constructor(
    public readonly kind: MalformedConfigKind,
    message: string,
    public readonly cause?: unknown,
  ) {
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
      "read",
      `Failed to read config at ${path}: ${err instanceof Error ? err.message : String(err)}`,
      err,
    );
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    throw new MalformedConfigError(
      "parse",
      `Config file ${path} is not valid JSON: ${err instanceof Error ? err.message : String(err)}`,
      err,
    );
  }

  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new MalformedConfigError(
      "schema",
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
        "schema",
        `Config "selection" must be an object with { providerId, modelId }`,
      );
    }
    const s = sel as Record<string, unknown>;
    if (typeof s.providerId !== "string" || typeof s.modelId !== "string") {
      throw new MalformedConfigError(
        "schema",
        `Config "selection" requires string providerId and modelId`,
      );
    }
    out.selection = { providerId: s.providerId, modelId: s.modelId };
  }

  // effort: undefined OR an arbitrary non-empty string. The catalog,
  // not this validator, decides which strings are meaningful for which
  // model — see `effectiveEffort` in `models/effort.ts`.
  if (obj.effort !== undefined) {
    if (typeof obj.effort !== "string" || obj.effort.length === 0) {
      throw new MalformedConfigError(
        "schema",
        `Config "effort" must be a non-empty string, got: ${JSON.stringify(obj.effort)}`,
      );
    }
    out.effort = obj.effort;
  }

  // hasCompletedOnboarding: undefined OR boolean.
  if (obj.hasCompletedOnboarding !== undefined) {
    if (typeof obj.hasCompletedOnboarding !== "boolean") {
      throw new MalformedConfigError(
        "schema",
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
