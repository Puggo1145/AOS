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
  type AgentResetParams,
  type ConversationTurnStartedParams,
  type ConversationResetParams,
  type ConfigGetParams,
  type ConfigSetParams,
  type ConfigSetEffortParams,
  type UITokenParams,
  type UIThinkingParams,
  type UIToolCallParams,
  type UIStatusParams,
  type UIErrorParams,
  type UIUsageParams,
  type ProviderStatusParams,
  type ProviderStartLoginParams,
  type ProviderCancelLoginParams,
  type ProviderLoginStatusParams,
  type ProviderStatusChangedParams,
  type ProviderSetApiKeyParams,
  type ProviderClearApiKeyParams,
  type ProviderLogoutParams,
  type DevContextGetParams,
  type DevContextChangedParams,
  type UITodoParams,
  type SessionCreateParams,
  type SessionListParams,
  type SessionActivateParams,
  type SessionCreatedNotificationParams,
  type SessionActivatedNotificationParams,
  type SessionListChangedNotificationParams,
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
  expect(req.params.citedContext.clipboards?.[0]?.kind).toBe("text");
});

test("agent.cancel fixture roundtrips byte-equal", () => {
  assertRoundtrip("agent.cancel.json");
  const { parsed } = loadFixture("agent.cancel.json");
  const req = parsed as RPCRequest<AgentCancelParams>;
  expect(req.method).toBe(RPCMethod.agentCancel);
  expect(typeof req.params.turnId).toBe("string");
});

test("agent.reset fixture roundtrips byte-equal", () => {
  assertRoundtrip("agent.reset.json");
  const { parsed } = loadFixture("agent.reset.json");
  const req = parsed as RPCRequest<AgentResetParams>;
  expect(req.method).toBe(RPCMethod.agentReset);
});

test("conversation.turnStarted fixture roundtrips byte-equal", () => {
  assertRoundtrip("conversation.turnStarted.json");
  const { parsed } = loadFixture("conversation.turnStarted.json");
  const note = parsed as RPCNotification<ConversationTurnStartedParams>;
  expect(note.method).toBe(RPCMethod.conversationTurnStarted);
  expect(note.params.turn.status).toBe("working");
});

test("conversation.reset fixture roundtrips byte-equal", () => {
  assertRoundtrip("conversation.reset.json");
  const { parsed } = loadFixture("conversation.reset.json");
  const note = parsed as RPCNotification<ConversationResetParams>;
  expect(note.method).toBe(RPCMethod.conversationReset);
});

test("config.get fixture roundtrips byte-equal", () => {
  assertRoundtrip("config.get.json");
  const { parsed } = loadFixture("config.get.json");
  const req = parsed as RPCRequest<ConfigGetParams>;
  expect(req.method).toBe(RPCMethod.configGet);
});

test("config.set fixture roundtrips byte-equal", () => {
  assertRoundtrip("config.set.json");
  const { parsed } = loadFixture("config.set.json");
  const req = parsed as RPCRequest<ConfigSetParams>;
  expect(req.method).toBe(RPCMethod.configSet);
  expect(req.params.providerId).toBe("chatgpt-plan");
  expect(req.params.modelId).toBe("gpt-5.5");
});

test("config.setEffort fixture roundtrips byte-equal", () => {
  assertRoundtrip("config.setEffort.json");
  const { parsed } = loadFixture("config.setEffort.json");
  const req = parsed as RPCRequest<ConfigSetEffortParams>;
  expect(req.method).toBe(RPCMethod.configSetEffort);
  expect(req.params.effort).toBe("medium");
});

test("ui.token fixture roundtrips byte-equal", () => {
  assertRoundtrip("ui.token.json");
  const { parsed } = loadFixture("ui.token.json");
  const note = parsed as RPCNotification<UITokenParams>;
  expect(note.method).toBe(RPCMethod.uiToken);
  expect(typeof note.params.delta).toBe("string");
});

test("ui.thinking.delta fixture roundtrips byte-equal", () => {
  assertRoundtrip("ui.thinking.delta.json");
  const { parsed } = loadFixture("ui.thinking.delta.json");
  const note = parsed as RPCNotification<UIThinkingParams>;
  expect(note.method).toBe(RPCMethod.uiThinking);
  expect(note.params.kind).toBe("delta");
  if (note.params.kind === "delta") {
    expect(typeof note.params.delta).toBe("string");
  }
});

test("ui.thinking.end fixture roundtrips byte-equal", () => {
  assertRoundtrip("ui.thinking.end.json");
  const { parsed } = loadFixture("ui.thinking.end.json");
  const note = parsed as RPCNotification<UIThinkingParams>;
  expect(note.method).toBe(RPCMethod.uiThinking);
  expect(note.params.kind).toBe("end");
  // `end` variant must not carry a `delta` field.
  expect("delta" in note.params).toBe(false);
});

test("ui.toolCall.called fixture roundtrips byte-equal", () => {
  assertRoundtrip("ui.toolCall.called.json");
  const { parsed } = loadFixture("ui.toolCall.called.json");
  const note = parsed as RPCNotification<UIToolCallParams>;
  expect(note.method).toBe(RPCMethod.uiToolCall);
  expect(note.params.phase).toBe("called");
  if (note.params.phase === "called") {
    expect(note.params.toolName).toBe("bash");
    expect(typeof note.params.args).toBe("object");
  }
  // `result`-only fields must not be on a called frame.
  expect("isError" in note.params).toBe(false);
  expect("outputText" in note.params).toBe(false);
});

test("ui.toolCall.result fixture roundtrips byte-equal", () => {
  assertRoundtrip("ui.toolCall.result.json");
  const { parsed } = loadFixture("ui.toolCall.result.json");
  const note = parsed as RPCNotification<UIToolCallParams>;
  expect(note.method).toBe(RPCMethod.uiToolCall);
  expect(note.params.phase).toBe("result");
  if (note.params.phase === "result") {
    expect(note.params.isError).toBe(false);
    expect(typeof note.params.outputText).toBe("string");
  }
  expect("args" in note.params).toBe(false);
});

test("ui.toolCall.rejected fixture roundtrips byte-equal", () => {
  assertRoundtrip("ui.toolCall.rejected.json");
  const { parsed } = loadFixture("ui.toolCall.rejected.json");
  const note = parsed as RPCNotification<UIToolCallParams>;
  expect(note.method).toBe(RPCMethod.uiToolCall);
  expect(note.params.phase).toBe("rejected");
  if (note.params.phase === "rejected") {
    expect(note.params.toolName).toBe("bash");
    expect(typeof note.params.errorMessage).toBe("string");
    expect(typeof note.params.args).toBe("object");
  }
  // `result`-only fields must not appear on a rejected frame — phase is the
  // failure signal.
  expect("isError" in note.params).toBe(false);
  expect("outputText" in note.params).toBe(false);
});

test("ui.status fixture roundtrips byte-equal", () => {
  assertRoundtrip("ui.status.json");
  const { parsed } = loadFixture("ui.status.json");
  const note = parsed as RPCNotification<UIStatusParams>;
  expect(note.method).toBe(RPCMethod.uiStatus);
  expect(["working", "waiting", "done"]).toContain(
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

test("ui.usage fixture roundtrips byte-equal", () => {
  assertRoundtrip("ui.usage.json");
  const { parsed } = loadFixture("ui.usage.json");
  const note = parsed as RPCNotification<UIUsageParams>;
  expect(note.method).toBe(RPCMethod.uiUsage);
  expect(typeof note.params.inputTokens).toBe("number");
  expect(typeof note.params.outputTokens).toBe("number");
  expect(typeof note.params.cacheReadTokens).toBe("number");
  expect(typeof note.params.cacheWriteTokens).toBe("number");
  expect(typeof note.params.totalTokens).toBe("number");
  expect(typeof note.params.contextWindow).toBe("number");
  expect(typeof note.params.modelId).toBe("string");
  expect(note.params.contextWindow).toBeGreaterThan(0);
});

test("ui.todo fixture roundtrips byte-equal", () => {
  assertRoundtrip("ui.todo.json");
  const { parsed } = loadFixture("ui.todo.json");
  const note = parsed as RPCNotification<UITodoParams>;
  expect(note.method).toBe(RPCMethod.uiTodo);
  expect(typeof note.params.sessionId).toBe("string");
  expect(Array.isArray(note.params.items)).toBe(true);
  for (const item of note.params.items) {
    expect(typeof item.id).toBe("string");
    expect(typeof item.text).toBe("string");
    expect(["pending", "in_progress", "completed"]).toContain(item.status);
  }
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

test("provider.setApiKey fixture roundtrips byte-equal", () => {
  assertRoundtrip("provider.setApiKey.json");
  const { parsed } = loadFixture("provider.setApiKey.json");
  const req = parsed as RPCRequest<ProviderSetApiKeyParams>;
  expect(req.method).toBe(RPCMethod.providerSetApiKey);
  expect(typeof req.params.providerId).toBe("string");
  expect(typeof req.params.apiKey).toBe("string");
  expect(req.params.apiKey.length).toBeGreaterThan(0);
});

test("provider.clearApiKey fixture roundtrips byte-equal", () => {
  assertRoundtrip("provider.clearApiKey.json");
  const { parsed } = loadFixture("provider.clearApiKey.json");
  const req = parsed as RPCRequest<ProviderClearApiKeyParams>;
  expect(req.method).toBe(RPCMethod.providerClearApiKey);
  expect(typeof req.params.providerId).toBe("string");
});

test("provider.logout fixture roundtrips byte-equal", () => {
  assertRoundtrip("provider.logout.json");
  const { parsed } = loadFixture("provider.logout.json");
  const req = parsed as RPCRequest<ProviderLogoutParams>;
  expect(req.method).toBe(RPCMethod.providerLogout);
  expect(typeof req.params.providerId).toBe("string");
});

test("dev.context.get fixture roundtrips byte-equal", () => {
  assertRoundtrip("dev.context.get.json");
  const { parsed } = loadFixture("dev.context.get.json");
  const req = parsed as RPCRequest<DevContextGetParams>;
  expect(req.method).toBe(RPCMethod.devContextGet);
});

test("dev.context.changed fixture roundtrips byte-equal", () => {
  assertRoundtrip("dev.context.changed.json");
  const { parsed } = loadFixture("dev.context.changed.json");
  const note = parsed as RPCNotification<DevContextChangedParams>;
  expect(note.method).toBe(RPCMethod.devContextChanged);
  expect(note.params.snapshot.modelId).toBe("gpt-5.5");
  expect(note.params.snapshot.providerId).toBe("chatgpt-plan");
  expect(note.params.snapshot.effort).toBe("medium");
  expect(typeof note.params.snapshot.messagesJson).toBe("string");
});

test("session.create fixture roundtrips byte-equal", () => {
  assertRoundtrip("session.create.json");
  const { parsed } = loadFixture("session.create.json");
  const req = parsed as RPCRequest<SessionCreateParams>;
  expect(req.method).toBe(RPCMethod.sessionCreate);
});

test("session.list fixture roundtrips byte-equal", () => {
  assertRoundtrip("session.list.json");
  const { parsed } = loadFixture("session.list.json");
  const req = parsed as RPCRequest<SessionListParams>;
  expect(req.method).toBe(RPCMethod.sessionList);
});

test("session.activate fixture roundtrips byte-equal", () => {
  assertRoundtrip("session.activate.json");
  const { parsed } = loadFixture("session.activate.json");
  const req = parsed as RPCRequest<SessionActivateParams>;
  expect(req.method).toBe(RPCMethod.sessionActivate);
  expect(typeof req.params.sessionId).toBe("string");
});

test("session.created fixture roundtrips byte-equal", () => {
  assertRoundtrip("session.created.json");
  const { parsed } = loadFixture("session.created.json");
  const note = parsed as RPCNotification<SessionCreatedNotificationParams>;
  expect(note.method).toBe(RPCMethod.sessionCreated);
  expect(typeof note.params.session.id).toBe("string");
  expect(note.params.session.turnCount).toBe(0);
});

test("session.activated fixture roundtrips byte-equal", () => {
  assertRoundtrip("session.activated.json");
  const { parsed } = loadFixture("session.activated.json");
  const note = parsed as RPCNotification<SessionActivatedNotificationParams>;
  expect(note.method).toBe(RPCMethod.sessionActivated);
});

test("session.listChanged fixture roundtrips byte-equal", () => {
  assertRoundtrip("session.listChanged.json");
  const { parsed } = loadFixture("session.listChanged.json");
  const note = parsed as RPCNotification<SessionListChangedNotificationParams>;
  expect(note.method).toBe(RPCMethod.sessionListChanged);
});

test("AOS_PROTOCOL_VERSION equals 2.0.0", () => {
  expect(AOS_PROTOCOL_VERSION).toBe("2.0.0");
});
