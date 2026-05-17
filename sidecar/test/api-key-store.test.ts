// Tests for the in-memory API key store and the provider.setApiKey /
// provider.clearApiKey RPC handlers.
//
// RPC handlers are exercised end-to-end through a paired Dispatcher
// (mirrors the pattern in dispatcher.test.ts).

import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdirSync, rmSync, writeFileSync, chmodSync, existsSync } from "node:fs";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  _resetForTesting,
  clearApiKey,
  getApiKey,
  hasApiKey,
  onChange,
  setApiKey,
} from "../src/auth/api-key-store";
import { getEnvApiKey } from "../src/llm/auth/env-api-keys";
import { listProviderInfos } from "../src/auth/providers";
import { Dispatcher, RPCMethodError } from "../src/rpc/dispatcher";
import { StdioTransport, type ByteSink, type ByteSource } from "../src/rpc/transport";
import { registerProviderHandlers } from "../src/auth/register";
import { RPCErrorCode, RPCMethod } from "../src/rpc/rpc-types";

beforeEach(() => {
  _resetForTesting();
});

// ---------------------------------------------------------------------------
// In-memory paired dispatcher (copy of the helper from dispatcher.test.ts)
// ---------------------------------------------------------------------------

class Pipe {
  buf: string[] = [];
  waiters: ((s: string) => void)[] = [];
  closed = false;
  push(c: string): void {
    if (this.closed) return;
    if (this.waiters.length > 0) this.waiters.shift()!(c);
    else this.buf.push(c);
  }
  close(): void {
    this.closed = true;
    while (this.waiters.length > 0) this.waiters.shift()!("");
  }
  asSink(): ByteSink {
    return { write: (s: string) => { this.push(s); return true; } };
  }
  asSource(): ByteSource {
    const self = this;
    return (async function* () {
      while (true) {
        if (self.buf.length > 0) {
          yield Buffer.from(self.buf.shift()!, "utf8");
          continue;
        }
        if (self.closed) return;
        const next = await new Promise<string>((r) => self.waiters.push(r));
        if (next === "" && self.closed) return;
        yield Buffer.from(next, "utf8");
      }
    })();
  }
}

function makePair() {
  const ab = new Pipe();
  const ba = new Pipe();
  const aDispatcher = new Dispatcher(new StdioTransport(ba.asSource(), ab.asSink()));
  const bDispatcher = new Dispatcher(new StdioTransport(ab.asSource(), ba.asSink()));
  void aDispatcher.start();
  void bDispatcher.start();
  return {
    client: aDispatcher,
    server: bDispatcher,
    close: () => { aDispatcher.stop(); bDispatcher.stop(); ab.close(); ba.close(); },
  };
}

/// Capture notifications received by `client` for a given method.
function captureNotifications(client: Dispatcher, method: string, sink: unknown[]) {
  client.registerNotification(method, async (params) => { sink.push(params); });
}

// ---------------------------------------------------------------------------
// Store-level
// ---------------------------------------------------------------------------

test("set/get/has/clear basic flow", () => {
  expect(hasApiKey("deepseek")).toBe(false);
  setApiKey("deepseek", "sk-abc");
  expect(hasApiKey("deepseek")).toBe(true);
  expect(getApiKey("deepseek")).toBe("sk-abc");
  expect(clearApiKey("deepseek")).toBe(true);
  expect(hasApiKey("deepseek")).toBe(false);
  expect(clearApiKey("deepseek")).toBe(false); // idempotent
});

test("rejects empty key — fail loud not silent", () => {
  expect(() => setApiKey("deepseek", "")).toThrow();
  expect(() => setApiKey("", "sk-abc")).toThrow();
});

test("onChange listener fires only on transitions (not idempotent overwrites)", () => {
  const calls: Array<[string, boolean]> = [];
  onChange((id, has) => calls.push([id, has]));
  setApiKey("deepseek", "k1");
  setApiKey("deepseek", "k2"); // overwrite — no transition
  clearApiKey("deepseek");
  clearApiKey("deepseek"); // already cleared — no transition
  expect(calls).toEqual([["deepseek", true], ["deepseek", false]]);
});

test("getEnvApiKey prefers stored key over env var", () => {
  const prev = process.env.DEEPSEEK_API_KEY;
  process.env.DEEPSEEK_API_KEY = "env-fallback";
  try {
    expect(getEnvApiKey("deepseek")).toBe("env-fallback");
    setApiKey("deepseek", "stored-wins");
    expect(getEnvApiKey("deepseek")).toBe("stored-wins");
    clearApiKey("deepseek");
    expect(getEnvApiKey("deepseek")).toBe("env-fallback");
  } finally {
    if (prev === undefined) delete process.env.DEEPSEEK_API_KEY;
    else process.env.DEEPSEEK_API_KEY = prev;
  }
});

test("listProviderInfos surfaces deepseek with apiKey authMethod and live status", () => {
  let infos = listProviderInfos();
  const ds = infos.find((p) => p.id === "deepseek");
  expect(ds).toBeDefined();
  expect(ds?.authMethod).toBe("apiKey");
  expect(ds?.state).toBe("unauthenticated");

  setApiKey("deepseek", "sk-abc");
  infos = listProviderInfos();
  expect(infos.find((p) => p.id === "deepseek")?.state).toBe("ready");
});

// ---------------------------------------------------------------------------
// RPC handlers (end-to-end through paired dispatchers)
// ---------------------------------------------------------------------------

test("provider.setApiKey stores key and notifies statusChanged ready", async () => {
  const { client, server, close } = makePair();
  registerProviderHandlers(server);
  const notes: unknown[] = [];
  captureNotifications(client, RPCMethod.providerStatusChanged, notes);

  const result = await client.request(RPCMethod.providerSetApiKey, {
    providerId: "deepseek",
    apiKey: "sk-1234",
  });
  expect(result).toEqual({ ok: true });
  expect(getApiKey("deepseek")).toBe("sk-1234");

  // Allow the notification to flush across the pipe.
  await new Promise((r) => setTimeout(r, 10));
  expect(notes).toContainEqual({ providerId: "deepseek", state: "ready" });
  close();
});

test("provider.setApiKey rejects oauth-auth providers", async () => {
  const { client, server, close } = makePair();
  registerProviderHandlers(server);

  let caught: unknown;
  try {
    await client.request(RPCMethod.providerSetApiKey, {
      providerId: "chatgpt-plan",
      apiKey: "sk-doesnotmatter",
    });
  } catch (e) { caught = e; }
  expect(caught).toBeInstanceOf(RPCMethodError);
  expect((caught as RPCMethodError).code).toBe(RPCErrorCode.invalidParams);
  close();
});

test("provider.setApiKey rejects unknown provider", async () => {
  const { client, server, close } = makePair();
  registerProviderHandlers(server);

  let caught: unknown;
  try {
    await client.request(RPCMethod.providerSetApiKey, {
      providerId: "nonexistent",
      apiKey: "sk-x",
    });
  } catch (e) { caught = e; }
  expect(caught).toBeInstanceOf(RPCMethodError);
  expect((caught as RPCMethodError).code).toBe(RPCErrorCode.unknownProvider);
  close();
});

test("provider.clearApiKey rejects oauth-auth providers", async () => {
  const { client, server, close } = makePair();
  registerProviderHandlers(server);

  let caught: unknown;
  try {
    await client.request(RPCMethod.providerClearApiKey, { providerId: "chatgpt-plan" });
  } catch (e) { caught = e; }
  expect(caught).toBeInstanceOf(RPCMethodError);
  expect((caught as RPCMethodError).code).toBe(RPCErrorCode.invalidParams);
  close();
});

test("provider.clearApiKey rejects unknown provider", async () => {
  const { client, server, close } = makePair();
  registerProviderHandlers(server);

  let caught: unknown;
  try {
    await client.request(RPCMethod.providerClearApiKey, { providerId: "nonexistent" });
  } catch (e) { caught = e; }
  expect(caught).toBeInstanceOf(RPCMethodError);
  expect((caught as RPCMethodError).code).toBe(RPCErrorCode.unknownProvider);
  close();
});

test("provider.clearApiKey removes key and notifies; idempotent without notify", async () => {
  const { client, server, close } = makePair();
  registerProviderHandlers(server);
  const notes: unknown[] = [];
  captureNotifications(client, RPCMethod.providerStatusChanged, notes);

  setApiKey("deepseek", "sk-existing");

  const r1 = await client.request(RPCMethod.providerClearApiKey, { providerId: "deepseek" });
  expect(r1).toEqual({ cleared: true });
  expect(hasApiKey("deepseek")).toBe(false);
  await new Promise((r) => setTimeout(r, 10));
  expect(notes).toContainEqual({ providerId: "deepseek", state: "unauthenticated", reason: "loggedOut" });

  const before = notes.length;
  const r2 = await client.request(RPCMethod.providerClearApiKey, { providerId: "deepseek" });
  expect(r2).toEqual({ cleared: false });
  await new Promise((r) => setTimeout(r, 10));
  expect(notes.length).toBe(before); // no extra notify on idempotent clear
  close();
});

// ---------------------------------------------------------------------------
// provider.logout — exercises both apiKey + oauth branches and the
// fail-fast filesystem behavior fixed in this change.
// ---------------------------------------------------------------------------

let prevHome: string | undefined;
let tempHome: string | undefined;

function withTempHome(): string {
  prevHome = process.env.HOME;
  tempHome = mkdtempSync(join(tmpdir(), "notch-agent-logout-test-"));
  process.env.HOME = tempHome;
  return tempHome;
}

afterEach(() => {
  if (tempHome) {
    // Restore directory perms before cleanup so EACCES tests don't leak.
    try { chmodSync(join(tempHome, ".notch-agent", "auth"), 0o700); } catch {}
    try { rmSync(tempHome, { recursive: true, force: true }); } catch {}
    tempHome = undefined;
  }
  if (prevHome === undefined) delete process.env.HOME;
  else process.env.HOME = prevHome;
  prevHome = undefined;
});

test("provider.logout (apiKey) wipes in-memory key and notifies", async () => {
  const { client, server, close } = makePair();
  registerProviderHandlers(server);
  const notes: unknown[] = [];
  captureNotifications(client, RPCMethod.providerStatusChanged, notes);

  setApiKey("deepseek", "sk-existing");
  const r = await client.request(RPCMethod.providerLogout, { providerId: "deepseek" });
  expect(r).toEqual({ cleared: true });
  expect(hasApiKey("deepseek")).toBe(false);
  await new Promise((r) => setTimeout(r, 10));
  expect(notes).toContainEqual({ providerId: "deepseek", state: "unauthenticated", reason: "loggedOut" });
  close();
});

test("provider.logout (oauth) deletes token file and is idempotent on missing file", async () => {
  const home = withTempHome();
  const tokenDir = join(home, ".notch-agent", "auth");
  mkdirSync(tokenDir, { recursive: true, mode: 0o700 });
  const tokenPath = join(tokenDir, "chatgpt.json");
  writeFileSync(tokenPath, "{}", { mode: 0o600 });

  const { client, server, close } = makePair();
  registerProviderHandlers(server);

  const r1 = await client.request(RPCMethod.providerLogout, { providerId: "chatgpt-plan" });
  expect(r1).toEqual({ cleared: true });
  expect(existsSync(tokenPath)).toBe(false);

  // Idempotent: ENOENT on second pass returns cleared:false, no throw.
  const r2 = await client.request(RPCMethod.providerLogout, { providerId: "chatgpt-plan" });
  expect(r2).toEqual({ cleared: false });
  close();
});

test("provider.logout (oauth) fails loud on non-ENOENT filesystem errors", async () => {
  const home = withTempHome();
  const tokenDir = join(home, ".notch-agent", "auth");
  mkdirSync(tokenDir, { recursive: true, mode: 0o700 });
  const tokenPath = join(tokenDir, "chatgpt.json");
  writeFileSync(tokenPath, "{}", { mode: 0o600 });
  // Strip write permission from the parent dir → unlink raises EACCES,
  // not ENOENT. Per the fail-fast rule the handler must surface this.
  chmodSync(tokenDir, 0o500);

  const { client, server, close } = makePair();
  registerProviderHandlers(server);

  let caught: unknown;
  try {
    await client.request(RPCMethod.providerLogout, { providerId: "chatgpt-plan" });
  } catch (e) { caught = e; }
  expect(caught).toBeInstanceOf(RPCMethodError);
  expect((caught as RPCMethodError).code).toBe(RPCErrorCode.internalError);
  // File must remain on disk — UI thinking "logged out" while the token
  // sits there is precisely the bug this guards against.
  expect(existsSync(tokenPath)).toBe(true);
  close();
});
