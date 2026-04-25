// Byte-equal fixture roundtrip tests for the TS side of the AOS RPC schema.
//
// For every fixture in `tests/rpc-fixtures/*.json`:
//   1. Read raw bytes
//   2. JSON.parse
//   3. Recursively canonicalize (sort keys at every nesting level, no whitespace)
//   4. Assert the canonical re-serialization is byte-equal to the original
//
// This guards `sidecar/src/rpc/rpc-types.ts` against schema drift. The Swift
// side runs the same assertion in `Tests/AOSRPCSchemaTests/RoundtripTests.swift`.

import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import {
  AOS_PROTOCOL_VERSION,
  RPCMethod,
  type RPCRequest,
  type RPCNotification,
  type HelloParams,
  type PingParams,
  type AgentSubmitParams,
  type AgentCancelParams,
  type UITokenParams,
  type UIStatusParams,
  type UIErrorParams,
  type ProviderStatusParams,
  type ProviderStartLoginParams,
  type ProviderCancelLoginParams,
  type ProviderLoginStatusParams,
  type ProviderStatusChangedParams,
} from "../src/rpc/rpc-types";

// Resolve repo root by walking up from this test file.
const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "..", "..");
const fixturesDir = join(repoRoot, "tests", "rpc-fixtures");

function loadFixture(name: string): { raw: string; parsed: unknown } {
  const raw = readFileSync(join(fixturesDir, name), "utf8");
  const parsed = JSON.parse(raw);
  return { raw, parsed };
}

/**
 * Serialize a value to JSON with keys sorted recursively at every object level
 * and no whitespace. Matches Swift `JSONEncoder` with `.sortedKeys`.
 */
function canonicalize(value: unknown): string {
  return JSON.stringify(sortKeys(value));
}

function sortKeys(value: unknown): unknown {
  if (value === null) return null;
  if (Array.isArray(value)) {
    return value.map(sortKeys);
  }
  if (typeof value === "object") {
    const obj = value as Record<string, unknown>;
    const sorted: Record<string, unknown> = {};
    for (const key of Object.keys(obj).sort()) {
      sorted[key] = sortKeys(obj[key]);
    }
    return sorted;
  }
  return value;
}

function assertRoundtrip(name: string) {
  const { raw, parsed } = loadFixture(name);
  const reSerialized = canonicalize(parsed);
  expect(reSerialized).toBe(raw);
}

test("rpc.hello fixture roundtrips byte-equal", () => {
  assertRoundtrip("rpc.hello.json");
  // Type-level assertion: fixture decodes into the declared shape.
  const { parsed } = loadFixture("rpc.hello.json");
  const req = parsed as RPCRequest<HelloParams>;
  expect(req.method).toBe(RPCMethod.rpcHello);
  expect(req.params.protocolVersion).toBe(AOS_PROTOCOL_VERSION);
  expect(req.params.clientInfo.name).toBe("aos-sidecar");
});

test("rpc.ping fixture roundtrips byte-equal", () => {
  assertRoundtrip("rpc.ping.json");
  const { parsed } = loadFixture("rpc.ping.json");
  const req = parsed as RPCRequest<PingParams>;
  expect(req.method).toBe(RPCMethod.rpcPing);
});

test("agent.submit fixture roundtrips byte-equal", () => {
  assertRoundtrip("agent.submit.json");
  const { parsed } = loadFixture("agent.submit.json");
  const req = parsed as RPCRequest<AgentSubmitParams>;
  expect(req.method).toBe(RPCMethod.agentSubmit);
  expect(req.params.citedContext.app?.bundleId).toBe("com.apple.Safari");
  expect(req.params.citedContext.behaviors?.length).toBe(1);
  expect(req.params.citedContext.clipboard?.kind).toBe("text");
});

test("agent.cancel fixture roundtrips byte-equal", () => {
  assertRoundtrip("agent.cancel.json");
  const { parsed } = loadFixture("agent.cancel.json");
  const req = parsed as RPCRequest<AgentCancelParams>;
  expect(req.method).toBe(RPCMethod.agentCancel);
  expect(typeof req.params.turnId).toBe("string");
});

test("ui.token fixture roundtrips byte-equal", () => {
  assertRoundtrip("ui.token.json");
  const { parsed } = loadFixture("ui.token.json");
  const note = parsed as RPCNotification<UITokenParams>;
  expect(note.method).toBe(RPCMethod.uiToken);
  expect(typeof note.params.delta).toBe("string");
});

test("ui.status fixture roundtrips byte-equal", () => {
  assertRoundtrip("ui.status.json");
  const { parsed } = loadFixture("ui.status.json");
  const note = parsed as RPCNotification<UIStatusParams>;
  expect(note.method).toBe(RPCMethod.uiStatus);
  expect(["thinking", "tool_calling", "waiting_input", "done"]).toContain(
    note.params.status
  );
});

test("ui.error fixture roundtrips byte-equal", () => {
  assertRoundtrip("ui.error.json");
  const { parsed } = loadFixture("ui.error.json");
  const note = parsed as RPCNotification<UIErrorParams>;
  expect(note.method).toBe(RPCMethod.uiError);
  expect(typeof note.params.code).toBe("number");
});

test("provider.status fixture roundtrips byte-equal", () => {
  assertRoundtrip("provider.status.json");
  const { parsed } = loadFixture("provider.status.json");
  const req = parsed as RPCRequest<ProviderStatusParams>;
  expect(req.method).toBe(RPCMethod.providerStatus);
});

test("provider.startLogin fixture roundtrips byte-equal", () => {
  assertRoundtrip("provider.startLogin.json");
  const { parsed } = loadFixture("provider.startLogin.json");
  const req = parsed as RPCRequest<ProviderStartLoginParams>;
  expect(req.method).toBe(RPCMethod.providerStartLogin);
  expect(req.params.providerId).toBe("chatgpt-plan");
});

test("provider.cancelLogin fixture roundtrips byte-equal", () => {
  assertRoundtrip("provider.cancelLogin.json");
  const { parsed } = loadFixture("provider.cancelLogin.json");
  const req = parsed as RPCRequest<ProviderCancelLoginParams>;
  expect(req.method).toBe(RPCMethod.providerCancelLogin);
  expect(typeof req.params.loginId).toBe("string");
});

test("provider.loginStatus fixture roundtrips byte-equal", () => {
  assertRoundtrip("provider.loginStatus.json");
  const { parsed } = loadFixture("provider.loginStatus.json");
  const note = parsed as RPCNotification<ProviderLoginStatusParams>;
  expect(note.method).toBe(RPCMethod.providerLoginStatus);
  expect(["awaitingCallback", "exchanging", "success", "failed"]).toContain(
    note.params.state
  );
});

test("provider.statusChanged fixture roundtrips byte-equal", () => {
  assertRoundtrip("provider.statusChanged.json");
  const { parsed } = loadFixture("provider.statusChanged.json");
  const note = parsed as RPCNotification<ProviderStatusChangedParams>;
  expect(note.method).toBe(RPCMethod.providerStatusChanged);
  expect(["ready", "unauthenticated"]).toContain(note.params.state);
});

test("AOS_PROTOCOL_VERSION equals 1.0.0", () => {
  expect(AOS_PROTOCOL_VERSION).toBe("1.0.0");
});
