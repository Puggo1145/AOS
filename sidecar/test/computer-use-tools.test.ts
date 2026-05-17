import { test, expect } from "bun:test";
import { existsSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ToolRegistry } from "../src/agent/tools/registry";
import { registerComputerUseTools } from "../src/agent/tools/computer-use";
import { ComputerUseStateCache } from "../src/agent/session/computer-use-state-cache";
import { Session } from "../src/agent/session/session";
import { validateToolArguments } from "../src/llm/utils/validation";
import { RPCMethod } from "../src/rpc/rpc-types";
import type { Dispatcher } from "../src/rpc/dispatcher";
import type { ComputerUseGetAppStateResult } from "../src/rpc/rpc-types";

function tempScreenshotPath(bytes = "fake-image-bytes"): string {
  const dir = mkdtempSync(join(tmpdir(), "aos-computer-use-screenshot-"));
  const path = join(dir, "screenshot.png");
  writeFileSync(path, bytes);
  return path;
}

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
      input: ["text", "image"],
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

test("use_mouse forwards screenshot-local click coordinates and stateId for Shell-side conversion", async () => {
  const registry = new ToolRegistry();
  const { dispatcher, calls } = makeDispatcherSpy();
  registerComputerUseTools(registry, dispatcher);

  const result = await registry.get("use_mouse")!.execute(
    {
      windowId: 77,
      stateId: "state-1",
      event: {
        kind: "click",
        button: "left",
        point: { x: 400, y: 300 },
        count: 2,
      },
    },
    {
      ...execContext(),
      computerUseStateCache: {
        lookup: () => ({
          kind: "found",
          record: {
            stateId: "state-1",
            windowId: 77,
            recordedAt: 1_000,
            coordinateSpace: {
              windowFrame: { x: 10, y: 20, width: 400, height: 300 },
              windowBounds: { x: 10, y: 20, width: 400, height: 300 },
              pixelSize: { width: 800, height: 600 },
            },
          },
        }),
        record: () => {},
        clear: () => {},
      },
    } as any,
  );

  expect(result.isError).toBe(false);
  expect(calls).toEqual([
    {
      method: RPCMethod.computerUsePostMouseEvent,
      params: {
        windowId: 77,
        stateId: "state-1",
        event: {
          kind: "click",
          button: "left",
          point: { x: 400, y: 300 },
          count: 2,
        },
      },
    },
  ]);
});

test("get_app_state records screenshot coordinate space for later mouse conversion", async () => {
  const registry = new ToolRegistry();
  const appState: ComputerUseGetAppStateResult = {
    pid: 98530,
    stateId: "state-1",
    bundleId: "com.apple.Safari",
    appName: "Safari",
    elementCount: 4,
    treeMarkdown: "0 window",
    screenshot: {
      imagePath: tempScreenshotPath(),
      format: "png",
      width: 800,
      height: 600,
      scaleFactor: 2,
      coordinateSpace: {
        windowFrame: { x: 10, y: 20, width: 400, height: 300 },
        windowBounds: { x: 10, y: 20, width: 400, height: 300 },
        pixelSize: { width: 800, height: 600 },
      },
    },
  };
  const records: unknown[] = [];
  const dispatcher = {
    request: async () => appState,
  } as unknown as Dispatcher;
  registerComputerUseTools(registry, dispatcher);

  const result = await registry.get("get_app_state")!.execute(
    { windowId: 77, captureMode: "vision" },
    {
      ...execContext(),
      computerUseStateCache: {
        lookup: () => undefined,
        record: (record: unknown) => records.push(record),
        clear: () => {},
      },
    } as any,
  );

  expect(result.isError).toBe(false);
  const screenshot = appState.screenshot;
  if (!screenshot) throw new Error("test setup expected a screenshot");
  expect(records).toEqual([
    {
      stateId: "state-1",
      windowId: 77,
      coordinateSpace: screenshot.coordinateSpace,
    },
  ]);
});

test("get_app_state does not expose or forward image dimension controls", async () => {
  const registry = new ToolRegistry();
  const calls: { method: string; params: object }[] = [];
  const dispatcher = {
    request: async (_method: string, _params: object) => {
      calls.push({ method: _method, params: _params });
      return {
        pid: 98530,
        stateId: "state-1",
        elementCount: 1,
        treeMarkdown: "0 window",
      } satisfies ComputerUseGetAppStateResult;
    },
  } as unknown as Dispatcher;
  registerComputerUseTools(registry, dispatcher);

  const tool = registry.get("get_app_state")!.spec;
  expect(tool.parameters).toEqual({
    type: "object",
    properties: {
      windowId: { type: "integer" },
      captureMode: { type: "string", enum: ["vision", "ax"] },
    },
    required: ["windowId", "captureMode"],
    additionalProperties: false,
  });

  await registry.get("get_app_state")!.execute(
    { windowId: 77, captureMode: "vision" },
    {
      ...execContext(),
      computerUseStateCache: {
        lookup: () => undefined,
        record: () => {},
        clear: () => {},
      },
    } as any,
  );

  expect(calls).toEqual([
    {
      method: RPCMethod.computerUseGetAppState,
      params: { windowId: 77, captureMode: "vision" },
    },
  ]);
});

test("use_mouse rejects expired screenshot coordinate state before RPC dispatch", async () => {
  const registry = new ToolRegistry();
  const { dispatcher, calls } = makeDispatcherSpy();
  let now = 1_000;
  const cache = new ComputerUseStateCache({ ttlMilliseconds: 30_000, now: () => now });
  cache.record({
    stateId: "state-1",
    windowId: 77,
    coordinateSpace: {
      windowFrame: { x: 10, y: 20, width: 400, height: 300 },
      windowBounds: { x: 10, y: 20, width: 400, height: 300 },
      pixelSize: { width: 800, height: 600 },
    },
  });
  now = 31_001;
  registerComputerUseTools(registry, dispatcher);

  let caught: unknown;
  try {
    await registry.get("use_mouse")!.execute(
      {
        windowId: 77,
        stateId: "state-1",
        event: {
          kind: "click",
          button: "left",
          point: { x: 400, y: 300 },
        },
      },
      {
        ...execContext(),
        computerUseStateCache: cache,
      },
    );
  } catch (err) {
    caught = err;
  }

  expect(String(caught)).toContain("stale screenshot coordinate space");
  expect(calls).toEqual([]);
});

test("use_mouse rejects screenshot coordinates outside cached pixel bounds before RPC dispatch", async () => {
  const registry = new ToolRegistry();
  const { dispatcher, calls } = makeDispatcherSpy();
  registerComputerUseTools(registry, dispatcher);

  let caught: unknown;
  try {
    await registry.get("use_mouse")!.execute(
      {
        windowId: 77,
        stateId: "state-1",
        event: {
          kind: "click",
          button: "left",
          point: { x: 801, y: 300 },
        },
      },
      {
        ...execContext(),
        computerUseStateCache: {
          lookup: () => ({
            kind: "found",
            record: {
              stateId: "state-1",
              windowId: 77,
              recordedAt: 1_000,
              coordinateSpace: {
                windowFrame: { x: 10, y: 20, width: 400, height: 300 },
                windowBounds: { x: 10, y: 20, width: 400, height: 300 },
                pixelSize: { width: 800, height: 600 },
              },
            },
          }),
          record: () => {},
          clear: () => {},
        },
      } as any,
    );
  } catch (err) {
    caught = err;
  }

  expect(String(caught)).toContain("screenshot point 801,300 is outside screenshot 800x600");
  expect(calls).toEqual([]);
});

test("replacing the computer use app session clears screenshot coordinate state", () => {
  const session = new Session({ id: "session-1", createdAt: 0, title: "Test" });
  session.setComputerUseAppSession({ pid: 123, windowId: 456 });
  session.computerUseStateCache.record({
    stateId: "state-1",
    windowId: 456,
    coordinateSpace: {
      windowFrame: { x: 10, y: 20, width: 400, height: 300 },
      windowBounds: { x: 10, y: 20, width: 400, height: 300 },
      pixelSize: { width: 800, height: 600 },
    },
  });

  expect(session.computerUseStateCache.lookup("state-1").kind).toBe("found");

  session.setComputerUseAppSession({ pid: 789, windowId: 999 });

  expect(session.computerUseStateCache.lookup("state-1").kind).toBe("missing");
});

test("stop_app_session sends the agent session owned pid to computerUse.stopAppSession", async () => {
  const registry = new ToolRegistry();
  const { dispatcher, calls } = makeDispatcherSpy();
  registerComputerUseTools(registry, dispatcher);

  const result = await registry.get("stop_app_session")!.execute(
    {},
    { ...execContext(), computerUseAppSession: { pid: 123, windowId: 456 } },
  );

  expect(result.isError).toBe(false);
  expect(calls).toEqual([
    {
      method: RPCMethod.computerUseStopAppSession,
      params: { pid: 123 },
    },
  ]);
});

test("stop_app_session fails before RPC dispatch without a session owned app session", async () => {
  const registry = new ToolRegistry();
  const { dispatcher, calls } = makeDispatcherSpy();
  registerComputerUseTools(registry, dispatcher);

  let caught: unknown;
  try {
    await registry.get("stop_app_session")!.execute({}, execContext());
  } catch (err) {
    caught = err;
  }

  expect(String(caught)).toContain("no app session was started by this agent session");
  expect(calls).toEqual([]);
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
      },
    }),
  ).toThrow(/pid/);
});

test("get_app_state renders app state as a readable tagged text block", async () => {
  const registry = new ToolRegistry();
  const imagePath = tempScreenshotPath("base64-image");
  const appState: ComputerUseGetAppStateResult = {
    pid: 98530,
    stateId: "state-1",
    bundleId: "com.apple.Safari",
    appName: "Safari",
    elementCount: 4,
    treeMarkdown: 'Window: "Apple", App: Safari.\n0 standard window Apple\n\t1 button Store',
    screenshot: {
      imagePath,
      format: "png",
      width: 800,
      height: 600,
      scaleFactor: 2,
      coordinateSpace: {
        windowFrame: { x: 10, y: 20, width: 400, height: 300 },
        windowBounds: { x: 0, y: 0, width: 400, height: 300 },
        pixelSize: { width: 800, height: 600 },
      },
    },
  };
  const dispatcher = {
    request: async () => appState,
  } as unknown as Dispatcher;
  registerComputerUseTools(registry, dispatcher);

  const result = await registry.get("get_app_state")!.execute(
    { windowId: 77, captureMode: "vision" },
    execContext(),
  );

  expect(result.content[0]).toEqual({
    type: "text",
    text:
      '<app_state>\n' +
      'App=com.apple.Safari (pid 98530)\n' +
      'State ID: state-1\n' +
      'Elements: 4\n' +
      'Screenshot: png 800x600 px @2x\n' +
      'Screenshot windowFrame: x=10 y=20 width=400 height=300\n' +
      'Screenshot windowBounds: x=0 y=0 width=400 height=300\n' +
      'Screenshot pixelSize: 800x600 px\n' +
      'Window: "Apple", App: Safari.\n' +
      '0 standard window Apple\n' +
      '\t1 button Store\n' +
      '</app_state>',
  });
  expect(result.content[1]).toEqual({ type: "image", data: "YmFzZTY0LWltYWdl", mimeType: "image/png" });
  expect(existsSync(imagePath)).toBe(false);
});

test("get_app_state deletes screenshot file even when the model cannot receive images", async () => {
  const registry = new ToolRegistry();
  const imagePath = tempScreenshotPath("image-for-text-model");
  const appState: ComputerUseGetAppStateResult = {
    pid: 98530,
    stateId: "state-1",
    elementCount: 1,
    treeMarkdown: "0 window",
    screenshot: {
      imagePath,
      format: "png",
      width: 800,
      height: 600,
      scaleFactor: 2,
      coordinateSpace: {
        windowFrame: { x: 10, y: 20, width: 400, height: 300 },
        windowBounds: { x: 0, y: 0, width: 400, height: 300 },
        pixelSize: { width: 800, height: 600 },
      },
    },
  };
  const dispatcher = {
    request: async () => appState,
  } as unknown as Dispatcher;
  registerComputerUseTools(registry, dispatcher);

  const context = execContext();
  context.model.input = ["text"];
  const result = await registry.get("get_app_state")!.execute(
    { windowId: 77, captureMode: "vision" },
    context,
  );

  expect(result.content).toHaveLength(1);
  expect(existsSync(imagePath)).toBe(false);
});

test("event tool descriptions expose variant-specific required fields and enum values", () => {
  const registry = new ToolRegistry();
  const { dispatcher } = makeDispatcherSpy();
  registerComputerUseTools(registry, dispatcher);

  const mouse = registry.get("use_mouse")!.spec.description;
  expect(mouse).toContain("stateId from the get_app_state screenshot");
  expect(mouse).toContain("{kind:\"click\", button:\"left\"|\"right\", point:{x:number,y:number}, count?:positive integer}");
  expect(mouse).toContain("{kind:\"drag\", button:\"left\"|\"right\", from:{x:number,y:number}, to:{x:number,y:number}}");
  expect(mouse).toContain("screenshot-local pixels");

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
        stateId: "state-1",
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
        stateId: "state-1",
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
