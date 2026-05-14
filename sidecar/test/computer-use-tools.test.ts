import { test, expect } from "bun:test";
import { ToolRegistry } from "../src/agent/tools/registry";
import { registerComputerUseTools } from "../src/agent/tools/computer-use";
import { validateToolArguments } from "../src/llm/utils/validation";
import { RPCMethod } from "../src/rpc/rpc-types";
import type { Dispatcher } from "../src/rpc/dispatcher";

function makeDispatcherSpy(): { dispatcher: Dispatcher; calls: { method: string; params: object }[] } {
  const calls: { method: string; params: object }[] = [];
  const dispatcher = {
    request: async (_method: string, _params: object) => {
      calls.push({ method: _method, params: _params });
      return { ok: true };
    },
  } as unknown as Dispatcher;
  return { dispatcher, calls };
}

function execContext() {
  return {
    sessionId: "session-1",
    turnId: "turn-1",
    toolCallId: "tool-1",
    model: {
      api: "openai-responses",
      provider: "fake",
      id: "fake",
      name: "fake",
      contextWindow: 1000,
      maxOutputTokens: 100,
    } as any,
    signal: new AbortController().signal,
  };
}

test("registerComputerUseTools exposes exactly the approved tool names", () => {
  const registry = new ToolRegistry();
  const { dispatcher } = makeDispatcherSpy();

  registerComputerUseTools(registry, dispatcher);

  expect(registry.list().map((handler) => handler.spec.name)).toEqual([
    "list_apps",
    "list_windows",
    "get_app_state",
    "start_app_session",
    "stop_app_session",
    "use_mouse",
    "use_keyboard",
    "perform_AX_action",
  ]);
});

test("use_mouse calls computerUse.postMouseEvent with the supplied event payload", async () => {
  const registry = new ToolRegistry();
  const { dispatcher, calls } = makeDispatcherSpy();
  registerComputerUseTools(registry, dispatcher);

  const result = await registry.get("use_mouse")!.execute(
    {
      windowId: 77,
      event: {
        kind: "click",
        button: "left",
        point: { x: 12, y: 34 },
        count: 2,
      },
    },
    execContext(),
  );

  expect(result.isError).toBe(false);
  expect(calls).toEqual([
    {
      method: RPCMethod.computerUsePostMouseEvent,
      params: {
        windowId: 77,
        event: {
          kind: "click",
          button: "left",
          point: { x: 12, y: 34 },
          count: 2,
        },
      },
    },
  ]);
});

test("computerUse namespace is available for Bun to call Shell", async () => {
  expect(RPCMethod.computerUseListApps).toBe("computerUse.listApps");
  expect(RPCMethod.computerUsePostEventToAXElement).toBe("computerUse.postEventToAXElement");
});

test("get_app_state rejects stale pid arguments before RPC dispatch", () => {
  const registry = new ToolRegistry();
  const { dispatcher } = makeDispatcherSpy();
  registerComputerUseTools(registry, dispatcher);

  const tool = registry.get("get_app_state")!.spec;

  expect(() =>
    validateToolArguments(tool, {
      type: "toolCall",
      id: "tool-1",
      name: "get_app_state",
      arguments: {
        pid: 1234,
        windowId: 77,
        captureMode: "ax",
        maxImageDimension: 0,
      },
    }),
  ).toThrow(/pid/);
});

test("event tool descriptions expose variant-specific required fields and enum values", () => {
  const registry = new ToolRegistry();
  const { dispatcher } = makeDispatcherSpy();
  registerComputerUseTools(registry, dispatcher);

  const mouse = registry.get("use_mouse")!.spec.description;
  expect(mouse).toContain("{kind:\"click\", button:\"left\"|\"right\", point:{x:number,y:number}, count?:positive integer}");
  expect(mouse).toContain("{kind:\"drag\", button:\"left\"|\"right\", from:{x:number,y:number}, to:{x:number,y:number}}");

  const keyboard = registry.get("use_keyboard")!.spec.description;
  expect(keyboard).toContain("{kind:\"text\", text:string, delayMilliseconds?:integer 0..200}");
  expect(keyboard).toContain("{kind:\"keyPress\", key:string, modifiers?:modifier[], count?:positive integer}");
  expect(keyboard).toContain("{kind:\"hotkey\", modifiers:non-empty modifier[], key:string}");
  expect(keyboard).toContain("modifier = \"command\"|\"shift\"|\"option\"|\"control\"|\"function\"");

  const ax = registry.get("perform_AX_action")!.spec.description;
  expect(ax).toContain("{kind:\"focus\"}");
  expect(ax).toContain("{kind:\"action\", action:\"press\"|\"showMenu\"|\"pick\"|\"confirm\"|\"cancel\"|\"open\"|\"increment\"|\"decrement\"|\"scrollToVisible\"}");
  expect(ax).toContain("{kind:\"setValue\", value:string}");
  expect(ax).toContain("{kind:\"setSelectedText\", value:string}");
  expect(ax).toContain("{kind:\"scroll\", direction:\"up\"|\"down\"|\"left\"|\"right\", pages:number > 0}");
});

test("use_keyboard rejects malformed text events before RPC dispatch", async () => {
  const registry = new ToolRegistry();
  const { dispatcher, calls } = makeDispatcherSpy();
  registerComputerUseTools(registry, dispatcher);

  let caught: unknown;
  try {
    await registry.get("use_keyboard")!.execute(
      {
        windowId: 77,
        event: { kind: "text" },
      },
      execContext(),
    );
  } catch (err) {
    caught = err;
  }

  expect(String(caught)).toContain("event.text is required");
  expect(calls).toEqual([]);
});

test("perform_AX_action rejects malformed scroll events before RPC dispatch", async () => {
  const registry = new ToolRegistry();
  const { dispatcher, calls } = makeDispatcherSpy();
  registerComputerUseTools(registry, dispatcher);

  let caught: unknown;
  try {
    await registry.get("perform_AX_action")!.execute(
      {
        windowId: 77,
        stateId: "state-1",
        elementIndex: 9,
        event: { kind: "scroll", direction: "down" },
      },
      execContext(),
    );
  } catch (err) {
    caught = err;
  }

  expect(String(caught)).toContain("event.pages is required");
  expect(calls).toEqual([]);
});

test("use_mouse rejects malformed click events before RPC dispatch", async () => {
  const registry = new ToolRegistry();
  const { dispatcher, calls } = makeDispatcherSpy();
  registerComputerUseTools(registry, dispatcher);

  let caught: unknown;
  try {
    await registry.get("use_mouse")!.execute(
      {
        windowId: 77,
        event: { kind: "click", button: "left" },
      },
      execContext(),
    );
  } catch (err) {
    caught = err;
  }

  expect(String(caught)).toContain("event.point is required");
  expect(calls).toEqual([]);
});

test("use_mouse rejects non-positive click counts before RPC dispatch", async () => {
  const registry = new ToolRegistry();
  const { dispatcher, calls } = makeDispatcherSpy();
  registerComputerUseTools(registry, dispatcher);

  let caught: unknown;
  try {
    await registry.get("use_mouse")!.execute(
      {
        windowId: 77,
        event: {
          kind: "click",
          button: "left",
          point: { x: 12, y: 34 },
          count: 0,
        },
      },
      execContext(),
    );
  } catch (err) {
    caught = err;
  }

  expect(String(caught)).toContain("event.count must be a positive integer");
  expect(calls).toEqual([]);
});

test("use_keyboard rejects out-of-range text delay before RPC dispatch", async () => {
  const registry = new ToolRegistry();
  const { dispatcher, calls } = makeDispatcherSpy();
  registerComputerUseTools(registry, dispatcher);

  let caught: unknown;
  try {
    await registry.get("use_keyboard")!.execute(
      {
        windowId: 77,
        event: { kind: "text", text: "hello", delayMilliseconds: 201 },
      },
      execContext(),
    );
  } catch (err) {
    caught = err;
  }

  expect(String(caught)).toContain("event.delayMilliseconds must be an integer between 0 and 200");
  expect(calls).toEqual([]);
});

test("use_keyboard rejects hotkeys without modifiers before RPC dispatch", async () => {
  const registry = new ToolRegistry();
  const { dispatcher, calls } = makeDispatcherSpy();
  registerComputerUseTools(registry, dispatcher);

  let caught: unknown;
  try {
    await registry.get("use_keyboard")!.execute(
      {
        windowId: 77,
        event: { kind: "hotkey", modifiers: [], key: "k" },
      },
      execContext(),
    );
  } catch (err) {
    caught = err;
  }

  expect(String(caught)).toContain("event.modifiers is required and must contain at least one non-empty string");
  expect(calls).toEqual([]);
});

test("perform_AX_action rejects non-positive scroll pages before RPC dispatch", async () => {
  const registry = new ToolRegistry();
  const { dispatcher, calls } = makeDispatcherSpy();
  registerComputerUseTools(registry, dispatcher);

  let caught: unknown;
  try {
    await registry.get("perform_AX_action")!.execute(
      {
        windowId: 77,
        stateId: "state-1",
        elementIndex: 9,
        event: { kind: "scroll", direction: "down", pages: 0 },
      },
      execContext(),
    );
  } catch (err) {
    caught = err;
  }

  expect(String(caught)).toContain("event.pages is required and must be greater than 0");
  expect(calls).toEqual([]);
});
