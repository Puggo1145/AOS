// Persistent global user config at ~/.aos/config.json.
//
// Layout:
//   ~/.aos/config.json   mode 0600
//   ~/.aos/              mode 0700 (created on demand)
//
// Atomic-write pattern (sibling tmpfile + rename) so a crash during write
// can never produce a torn file. Schema is intentionally minimal — this
// round only persists the user's selected provider/model.

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
  try {
    const parsed = JSON.parse(readFileSync(path, "utf-8")) as Record<string, unknown>;
    const out: UserConfig = {};
    const sel = parsed.selection as Record<string, unknown> | undefined;
    if (
      sel &&
      typeof sel.providerId === "string" &&
      typeof sel.modelId === "string"
    ) {
      out.selection = { providerId: sel.providerId, modelId: sel.modelId };
    }
    if (typeof parsed.effort === "string" && (EFFORT_LEVELS as readonly string[]).includes(parsed.effort)) {
      out.effort = parsed.effort as Effort;
    }
    return out;
  } catch {
    return {};
  }
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
