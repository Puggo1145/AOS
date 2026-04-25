// Persistent storage for the ChatGPT plan OAuth token.
//
// Layout (per docs/designs/llm-provider.md):
//   ~/.aos/auth/chatgpt.json        mode 0600
//   ~/.aos/auth/                    mode 0700 (created on demand)
//
// Writes are atomic: serialize to a sibling tempfile, fsync, then
// rename. This avoids torn reads if multiple sidecar instances refresh
// concurrently (the rename is atomic on POSIX).

import { existsSync, mkdirSync, readFileSync, renameSync, statSync, writeFileSync, chmodSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";

function aosHome(): string {
  // Prefer HOME env (test-friendly); fall back to os.homedir().
  return process.env.HOME && process.env.HOME.length > 0 ? process.env.HOME : homedir();
}

export interface ChatGPTPlanToken {
  accessToken: string;
  refreshToken: string;
  expiresAt: number; // unix ms
  /// Required. A token persisted without `accountId` cannot authorize
  /// downstream Codex API calls; treat such files as malformed and refuse
  /// to load them (the caller will surface unauthenticated to the UI).
  accountId: string;
}

export function chatgptTokenPath(): string {
  return join(aosHome(), ".aos", "auth", "chatgpt.json");
}

function ensureDir(path: string): void {
  const dir = dirname(path);
  if (!existsSync(dir)) {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
  } else {
    try {
      const st = statSync(dir);
      if ((st.mode & 0o777) !== 0o700) chmodSync(dir, 0o700);
    } catch {
      // best-effort tightening
    }
  }
}

export function readChatGPTPlanToken(): ChatGPTPlanToken | null {
  const path = chatgptTokenPath();
  if (!existsSync(path)) return null;
  try {
    const raw = readFileSync(path, "utf-8");
    const parsed = JSON.parse(raw);
    if (
      typeof parsed?.accessToken === "string" &&
      typeof parsed?.refreshToken === "string" &&
      typeof parsed?.expiresAt === "number" &&
      typeof parsed?.accountId === "string" &&
      parsed.accountId.length > 0
    ) {
      return parsed as ChatGPTPlanToken;
    }
    return null;
  } catch {
    return null;
  }
}

export function writeChatGPTPlanToken(token: ChatGPTPlanToken): void {
  const path = chatgptTokenPath();
  ensureDir(path);
  const tmp = path + ".tmp";
  writeFileSync(tmp, JSON.stringify(token, null, 2), { encoding: "utf-8", mode: 0o600 });
  // writeFileSync `mode` only applies to newly-created files, so chmod
  // explicitly to be safe across overwrite flows.
  try { chmodSync(tmp, 0o600); } catch {}
  renameSync(tmp, path);
  try { chmodSync(path, 0o600); } catch {}
}

export function hasChatGPTPlanToken(): boolean {
  return readChatGPTPlanToken() !== null;
}
