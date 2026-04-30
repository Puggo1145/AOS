// Ambient renderer — composition of registered providers into a single
// `<ambient>...</ambient>` block. Pins the wrapping convention and the
// "skip when nothing to say" rule.

import { test, expect, beforeEach, afterEach } from "bun:test";
import { ambientRegistry } from "../src/agent/ambient/registry";
import { renderAmbient } from "../src/agent/ambient/render";
import { Session } from "../src/agent/session/session";

function makeSession(): Session {
  return new Session({ id: "sess_test", createdAt: 0, title: "t" });
}

beforeEach(() => {
  ambientRegistry.clear();
});

// `ambientRegistry` is module-scoped state; without an afterEach the last
// case's providers leak into other test files (e.g. `agent-loop.test.ts`
// would observe a phantom ambient tail it did not register).
afterEach(() => {
  ambientRegistry.clear();
});

test("empty registry returns null — loop must skip ambient injection entirely", () => {
  expect(renderAmbient(makeSession())).toBeNull();
});

test("a single provider returning null is omitted; with no other providers the whole block is null", () => {
  ambientRegistry.register({ name: "noop", render: () => null });
  expect(renderAmbient(makeSession())).toBeNull();
});

test("a single provider with content yields a wrapped block", () => {
  ambientRegistry.register({ name: "todos", render: () => "[ ] #1: do thing" });
  const out = renderAmbient(makeSession());
  expect(out).toBe(
    "<ambient>\n<todos>\n[ ] #1: do thing\n</todos>\n</ambient>",
  );
});

test("multiple providers render in registration order, joined by newlines inside the wrapper", () => {
  ambientRegistry.register({ name: "todos", render: () => "todo body" });
  ambientRegistry.register({ name: "worktree", render: () => "/tmp/wt" });
  expect(renderAmbient(makeSession())).toBe(
    "<ambient>\n<todos>\ntodo body\n</todos>\n<worktree>\n/tmp/wt\n</worktree>\n</ambient>",
  );
});

test("null providers are skipped while non-null providers compose normally", () => {
  ambientRegistry.register({ name: "todos", render: () => "todo body" });
  ambientRegistry.register({ name: "skipme", render: () => null });
  ambientRegistry.register({ name: "now", render: () => "2026-04-29" });
  expect(renderAmbient(makeSession())).toBe(
    "<ambient>\n<todos>\ntodo body\n</todos>\n<now>\n2026-04-29\n</now>\n</ambient>",
  );
});

test("session is forwarded to each provider — used for per-session state lookups", () => {
  const sess = makeSession();
  const received: Session[] = [];
  ambientRegistry.register({
    name: "probe",
    render: (s) => {
      received.push(s);
      return "ok";
    },
  });
  renderAmbient(sess);
  expect(received).toHaveLength(1);
  expect(received[0]).toBe(sess);
});
