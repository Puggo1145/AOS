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
  // A corrupt file would lose `selection`/`effort` if the handler fell back
  // to `{}`. The latch is automatic, not a user recovery action — must throw.
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
