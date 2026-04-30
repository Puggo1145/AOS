// Ambient registry — registration, ordering, removal, source grouping.
//
// Mirrors the contract of `tool-registry.test.ts` because the registries
// share a pattern (named entries, sourceId batch unregister, throw on
// duplicate name). The renderer integration is exercised separately in
// `ambient-render.test.ts`.

import { test, expect, beforeEach, afterEach } from "bun:test";
import { ambientRegistry } from "../src/agent/ambient/registry";
import type { AmbientProvider } from "../src/agent/ambient/provider";

function makeProvider(name: string, body: string | null = "x"): AmbientProvider {
  return { name, render: () => body };
}

beforeEach(() => {
  ambientRegistry.clear();
});

// Module-scoped registry: clear in afterEach too so the last test's
// providers do not leak into adjacent test files.
afterEach(() => {
  ambientRegistry.clear();
});

test("register exposes the provider via list() in registration order", () => {
  ambientRegistry.register(makeProvider("a"));
  ambientRegistry.register(makeProvider("b"));
  ambientRegistry.register(makeProvider("c"));
  expect(ambientRegistry.list().map((p) => p.name)).toEqual(["a", "b", "c"]);
});

test("registering the same name twice throws — silent overwrite would mask the dispatcher's choice", () => {
  ambientRegistry.register(makeProvider("a"));
  expect(() => ambientRegistry.register(makeProvider("a"))).toThrow(/already registered/);
});

test("unregister removes a single named provider, leaves others intact", () => {
  ambientRegistry.register(makeProvider("a"));
  ambientRegistry.register(makeProvider("b"));
  ambientRegistry.unregister("a");
  expect(ambientRegistry.list().map((p) => p.name)).toEqual(["b"]);
});

test("unregister on an unknown name is a silent no-op", () => {
  ambientRegistry.register(makeProvider("a"));
  expect(() => ambientRegistry.unregister("nope")).not.toThrow();
  expect(ambientRegistry.list().map((p) => p.name)).toEqual(["a"]);
});

test("unregisterBySource drops every provider tagged with the source", () => {
  ambientRegistry.register(makeProvider("a"), "plugin-x");
  ambientRegistry.register(makeProvider("b"), "plugin-x");
  ambientRegistry.register(makeProvider("c"), "plugin-y");
  ambientRegistry.unregisterBySource("plugin-x");
  expect(ambientRegistry.list().map((p) => p.name)).toEqual(["c"]);
});

test("clear() empties the registry — test helper for isolated runs", () => {
  ambientRegistry.register(makeProvider("a"));
  ambientRegistry.register(makeProvider("b"));
  ambientRegistry.clear();
  expect(ambientRegistry.list()).toEqual([]);
});
