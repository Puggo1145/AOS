// ToolRegistry — registration, lookup, source-tagged unregister, and the
// "no double registration" failure mode.

import { test, expect, beforeEach } from "bun:test";
import { ToolRegistry } from "../src/agent/tools/registry";
import type { ToolHandler } from "../src/agent/tools/types";

function fakeHandler(name: string): ToolHandler {
  return {
    spec: {
      name,
      description: `${name} test handler`,
      parameters: { type: "object", properties: {} },
    },
    execute: async () => ({ content: [{ type: "text", text: name }], isError: false }),
  };
}

let reg: ToolRegistry;
beforeEach(() => {
  reg = new ToolRegistry();
});

test("register + get + list returns the handler in registration order", () => {
  reg.register(fakeHandler("alpha"));
  reg.register(fakeHandler("beta"));
  expect(reg.list().map((h) => h.spec.name)).toEqual(["alpha", "beta"]);
  expect(reg.get("beta")?.spec.name).toBe("beta");
});

test("get returns undefined for unknown tool name", () => {
  expect(reg.get("missing")).toBeUndefined();
});

test("double-register of the same name throws (programmer error, not silent overwrite)", () => {
  reg.register(fakeHandler("dup"));
  expect(() => reg.register(fakeHandler("dup"))).toThrow(/already registered/);
});

test("unregisterBySource only drops handlers tagged with that source id", () => {
  reg.register(fakeHandler("keep"), "core");
  reg.register(fakeHandler("drop1"), "plugin-a");
  reg.register(fakeHandler("drop2"), "plugin-a");
  reg.unregisterBySource("plugin-a");
  expect(reg.list().map((h) => h.spec.name)).toEqual(["keep"]);
});

test("clear() drops everything regardless of source", () => {
  reg.register(fakeHandler("a"), "x");
  reg.register(fakeHandler("b"), "y");
  reg.clear();
  expect(reg.list()).toEqual([]);
});
