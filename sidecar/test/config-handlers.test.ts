// Behavioral tests for the config.* RPC handlers — specifically the
// onboarding latch's interaction with the on-disk config file. The
// concern is that `config.markOnboardingCompleted` is fired automatically
// by the Shell (not a user recovery moment), so it must NOT silently
// rewrite a malformed config file with `{ hasCompletedOnboarding: true }`
// and lose the user's `selection` / `effort`.

import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { registerConfigHandlers } from "../src/config/handlers";
import { readUserConfig, writeUserConfig } from "../src/config/storage";
import { RPCErrorCode, RPCMethod } from "../src/rpc/rpc-types";
import { RPCMethodError, type RequestHandler } from "../src/rpc/dispatcher";

let originalHome: string | undefined;
let tmpHome: string;

beforeEach(() => {
  originalHome = process.env.HOME;
  tmpHome = mkdtempSync(join(tmpdir(), "aos-handler-test-"));
  process.env.HOME = tmpHome;
});

afterEach(() => {
  if (originalHome === undefined) delete process.env.HOME;
  else process.env.HOME = originalHome;
  rmSync(tmpHome, { recursive: true, force: true });
});

function writeRaw(content: string): void {
  mkdirSync(join(tmpHome, ".aos"), { recursive: true });
  writeFileSync(join(tmpHome, ".aos", "config.json"), content, "utf-8");
}

/// Minimal dispatcher stub that just captures the handlers
/// registerConfigHandlers binds, so we can invoke them directly.
function captureHandlers(): Map<string, RequestHandler> {
  const handlers = new Map<string, RequestHandler>();
  const fakeDispatcher = {
    registerRequest(method: string, handler: RequestHandler) {
      handlers.set(method, handler);
    },
  };
  registerConfigHandlers(fakeDispatcher as any);
  return handlers;
}

test("markOnboardingCompleted preserves existing selection and effort", async () => {
  writeUserConfig({
    selection: { providerId: "chatgpt-plan", modelId: "gpt-5.5" },
    effort: "medium",
  });

  const handlers = captureHandlers();
  const handler = handlers.get(RPCMethod.configMarkOnboardingCompleted)!;
  await handler({}, { id: "1" });

  expect(readUserConfig()).toEqual({
    selection: { providerId: "chatgpt-plan", modelId: "gpt-5.5" },
    effort: "medium",
    hasCompletedOnboarding: true,
  });
});

test("markOnboardingCompleted refuses to overwrite a malformed config", async () => {
  // Defensive edge case: in normal flow `config.get` runs at startup and
  // auto-resets corruption, so this handler should never see a malformed
  // file. But if the user manually corrupts it mid-session, the latch
  // must NOT silently rewrite (would lose selection/effort).
  writeRaw('{ "selection": { "providerId": 42, "modelId": "gpt-5.5" } }');

  const handlers = captureHandlers();
  const handler = handlers.get(RPCMethod.configMarkOnboardingCompleted)!;

  let threw: unknown;
  try {
    await handler({}, { id: "1" });
  } catch (err) {
    threw = err;
  }
  expect(threw).toBeInstanceOf(RPCMethodError);
  expect((threw as RPCMethodError).code).toBe(RPCErrorCode.agentConfigInvalid);
});

test("configGet auto-resets a malformed config and signals recoveredFromCorruption", async () => {
  // Closed-enum effort validation no longer exists; use a structural
  // breakage (selection with non-string field) to trigger the schema
  // recovery path.
  writeRaw('{ "selection": { "providerId": 42, "modelId": "gpt-5.5" } }');

  const handlers = captureHandlers();
  const handler = handlers.get(RPCMethod.configGet)!;
  const result = await handler({}, { id: "1" });

  expect(result.recoveredFromCorruption).toBe(true);
  expect(result.selection).toBe(null);
  expect(result.effort).toBe(null);
  expect(result.hasCompletedOnboarding).toBe(false);
  // File on disk should now be valid empty config.
  expect(readUserConfig()).toEqual({});
});

test("configGet on a healthy config does not signal recovery", async () => {
  writeUserConfig({
    selection: { providerId: "chatgpt-plan", modelId: "gpt-5.5" },
    effort: "high",
  });

  const handlers = captureHandlers();
  const handler = handlers.get(RPCMethod.configGet)!;
  const result = await handler({}, { id: "1" });

  expect(result.recoveredFromCorruption).toBe(false);
  expect(result.selection).toEqual({ providerId: "chatgpt-plan", modelId: "gpt-5.5" });
  expect(result.effort).toBe("high");
});

test("setEffort accepts a value supported by the currently-selected model", async () => {
  // GPT-5.5's native vocabulary is low|medium|high|xhigh. Picking "high"
  // must round-trip onto disk untouched (no closed-enum gating, no
  // translation).
  writeUserConfig({ selection: { providerId: "chatgpt-plan", modelId: "gpt-5.5" } });

  const handlers = captureHandlers();
  const handler = handlers.get(RPCMethod.configSetEffort)!;
  const result = await handler({ effort: "xhigh" }, { id: "1" });

  expect(result).toEqual({ effort: "xhigh" });
  expect(readUserConfig().effort).toBe("xhigh");
});

test("setEffort rejects a value not in the selected model's effort list", async () => {
  // GPT-5.5 does NOT accept "max" (DeepSeek's vocabulary). Persisting
  // it would be silently masked by `effectiveEffort` at request time —
  // the boundary must reject loudly so UI bugs / external RPC callers
  // can't poison the on-disk config.
  writeUserConfig({ selection: { providerId: "chatgpt-plan", modelId: "gpt-5.5" } });

  const handlers = captureHandlers();
  const handler = handlers.get(RPCMethod.configSetEffort)!;

  let threw: unknown;
  try {
    await handler({ effort: "max" }, { id: "1" });
  } catch (err) {
    threw = err;
  }
  expect(threw).toBeInstanceOf(RPCMethodError);
  expect((threw as RPCMethodError).code).toBe(RPCErrorCode.invalidParams);
  // Disk must NOT have been touched.
  expect(readUserConfig().effort).toBeUndefined();
});

test("setEffort with no persisted selection falls back to the default model and validates against ITS vocabulary", async () => {
  // Fresh config — nothing persisted. The handler must resolve to the
  // catalog's default model (chatgpt-plan/gpt-5.5) and reject an
  // off-vocabulary effort instead of writing it to disk.
  const handlers = captureHandlers();
  const handler = handlers.get(RPCMethod.configSetEffort)!;

  let threw: unknown;
  try {
    await handler({ effort: "definitely-not-an-effort" }, { id: "1" });
  } catch (err) {
    threw = err;
  }
  expect(threw).toBeInstanceOf(RPCMethodError);
  expect((threw as RPCMethodError).code).toBe(RPCErrorCode.invalidParams);
});

test("markOnboardingCompleted is idempotent on already-completed config", async () => {
  writeUserConfig({ hasCompletedOnboarding: true, effort: "low" });

  const handlers = captureHandlers();
  const handler = handlers.get(RPCMethod.configMarkOnboardingCompleted)!;
  await handler({}, { id: "1" });
  await handler({}, { id: "2" });

  expect(readUserConfig()).toEqual({
    hasCompletedOnboarding: true,
    effort: "low",
  });
});
