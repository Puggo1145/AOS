import { test, expect } from "bun:test";
import { ComputerUseStateCache } from "../src/agent/session/computer-use-state-cache";
import { COMPUTER_USE_TOOL_SPECS } from "../src/agent/tools/computer-use/catalog";
import { renderComputerUseAppStateText } from "../src/agent/tools/computer-use/rendering";
import { prepareMouseEventParams, recordAppStateCoordinateSpace } from "../src/agent/tools/computer-use/state";
import { validateAXArgs, validateKeyboardArgs, validateMouseArgs } from "../src/agent/tools/computer-use/validation";
import type { ToolExecContext } from "../src/agent/tools";
import type { ComputerUseGetAppStateResult } from "../src/rpc/rpc-types";

function execContext(stateCache = new ComputerUseStateCache()): ToolExecContext {
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
    computerUse: {
      appSession: { pid: 98530, windowId: 77 },
      stateCache,
    },
    signal: new AbortController().signal,
  };
}

test("computer use tool catalog is a dispatcher-free LLM spec surface", () => {
  expect(COMPUTER_USE_TOOL_SPECS.map((spec) => spec.name)).toEqual([
    "list_apps",
    "list_windows",
    "get_app_state",
    "start_app_session",
    "stop_app_session",
    "use_mouse",
    "use_keyboard",
    "perform_AX_action",
  ]);

  expect(COMPUTER_USE_TOOL_SPECS.find((spec) => spec.name === "get_app_state")?.parameters).toEqual({
    type: "object",
    properties: {
      windowId: { type: "integer" },
      captureMode: { type: "string", enum: ["vision", "ax"] },
    },
    required: ["windowId", "captureMode"],
    additionalProperties: false,
  });
});

test("computer use event validation runs without a dispatcher or tool handler", () => {
  expect(() =>
    validateMouseArgs({
      windowId: 77,
      stateId: "state-1",
      event: { kind: "click", button: "left" },
    }),
  ).toThrow("event.point is required");

  expect(() =>
    validateKeyboardArgs({
      windowId: 77,
      event: { kind: "hotkey", modifiers: [], key: "k" },
    }),
  ).toThrow("event.modifiers is required and must contain at least one non-empty string");

  expect(() =>
    validateAXArgs({
      windowId: 77,
      stateId: "state-1",
      elementIndex: 9,
      event: { kind: "scroll", direction: "down", pages: 0 },
    }),
  ).toThrow("event.pages is required and must be greater than 0");
});

test("computer use coordinate state records app screenshots and prepares mouse RPC params", () => {
  const stateCache = new ComputerUseStateCache();
  const appState: ComputerUseGetAppStateResult = {
    pid: 98530,
    stateId: "state-1",
    bundleId: "com.apple.Safari",
    appName: "Safari",
    elementCount: 4,
    treeMarkdown: "0 window",
    screenshot: {
      imagePath: "/tmp/not-read-by-this-test.png",
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

  const ctx = execContext(stateCache);
  recordAppStateCoordinateSpace(appState, { windowId: 77, captureMode: "vision" }, ctx);

  expect(
    prepareMouseEventParams(
      {
        windowId: 77,
        stateId: "state-1",
        event: {
          kind: "click",
          button: "left",
          point: { x: 400, y: 300 },
        },
      },
      ctx,
    ),
  ).toEqual({
    windowId: 77,
    stateId: "state-1",
    event: {
      kind: "click",
      button: "left",
      point: { x: 400, y: 300 },
    },
  });
});

test("computer use app state rendering is independent from RPC dispatch", () => {
  expect(
    renderComputerUseAppStateText({
      pid: 98530,
      stateId: "state-1",
      bundleId: "com.apple.Safari",
      appName: "Safari",
      elementCount: 4,
      treeMarkdown: 'Window: "Apple", App: Safari.\n0 standard window Apple',
    }),
  ).toBe(
    '<app_state>\n' +
      'App=com.apple.Safari (pid 98530)\n' +
      'State ID: state-1\n' +
      'Elements: 4\n' +
      'Window: "Apple", App: Safari.\n' +
      '0 standard window Apple\n' +
      '</app_state>',
  );
});
