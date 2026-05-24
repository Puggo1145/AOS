import { test, expect } from "bun:test";
import {
  COMPUTER_USE_TOOL_SPECS,
  createComputerUseTools,
  renderComputerUseAppStateText,
} from "../src/agent/tools/builtins/computer-use";
import { validateToolArguments } from "../src/agent/tools/core/schema";

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

  expect(COMPUTER_USE_TOOL_SPECS.find((spec) => spec.name === "get_app_state")?.parameters).toMatchObject({
    type: "object",
    properties: {
      windowId: { type: "integer" },
      captureMode: { type: "string", enum: ["vision", "ax"] },
    },
    required: ["windowId", "captureMode"],
    additionalProperties: false,
  });
});

test("computer use event validation runs through the shared zod tool schema", () => {
  const tools = createComputerUseTools({ request: async () => ({ ok: true }) } as any);
  const byName = new Map(tools.map((tool) => [tool.spec.name, tool]));

  expect(() =>
    validateToolArguments(byName.get("use_mouse")!, {
      type: "toolCall",
      id: "tool-1",
      name: "use_mouse",
      arguments: {
        windowId: 77,
        stateId: "state-1",
        event: { kind: "click", button: "left" },
      },
    }),
  ).toThrow(/event\.point/);

  expect(() =>
    validateToolArguments(byName.get("use_keyboard")!, {
      type: "toolCall",
      id: "tool-2",
      name: "use_keyboard",
      arguments: {
        windowId: 77,
        event: { kind: "hotkey", modifiers: ["bad"], key: "k" },
      },
    }),
  ).toThrow(/event\.modifiers/);

  expect(() =>
    validateToolArguments(byName.get("perform_AX_action")!, {
      type: "toolCall",
      id: "tool-3",
      name: "perform_AX_action",
      arguments: {
        windowId: 77,
        stateId: "state-1",
        elementIndex: 9,
        event: { kind: "scroll", direction: "down" },
      },
    }),
  ).toThrow(/event\.pages/);
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
