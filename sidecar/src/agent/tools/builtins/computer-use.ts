import { readFileSync, unlinkSync } from "node:fs";
import { z, type ZodType } from "zod";
import { supportsVision } from "../../../llm/models/capabilities";
import type { Tool, ToolResultContent } from "../../../llm/types";
import type { Dispatcher } from "../../../rpc/dispatcher";
import {
  RPCMethod,
  type ComputerUseBounds,
  type ComputerUseGetAppStateParams,
  type ComputerUseGetAppStateResult,
  type ComputerUseListAppsParams,
  type ComputerUseListWindowsParams,
  type ComputerUsePostEventToAXElementParams,
  type ComputerUsePostKeyboardEventParams,
  type ComputerUsePostMouseEventParams,
  type ComputerUseStartAppSessionParams,
} from "../../../rpc/rpc-types";
import { defineTool, zodParametersToJSONSchema } from "../core/schema";
import type { ToolRegistry } from "../core/registry";
import {
  ToolUserError,
  type ToolExecContext,
  type ToolExecResult,
  type ToolHandler,
  type ToolRuntimeEffects,
} from "../core/types";

export type ComputerUseStopAppSessionArgs = Record<string, never>;

export type ComputerUseArgs =
  | ComputerUseListAppsParams
  | ComputerUseListWindowsParams
  | ComputerUseGetAppStateParams
  | ComputerUseStartAppSessionParams
  | ComputerUseStopAppSessionArgs
  | ComputerUsePostMouseEventParams
  | ComputerUsePostKeyboardEventParams
  | ComputerUsePostEventToAXElementParams;

const pointSchema = z.object({
  x: z.number(),
  y: z.number(),
}).strict();

const modifierSchema = z.enum(["command", "shift", "option", "control", "function"]);

const mouseEventSchema = z.discriminatedUnion("kind", [
  z.object({
    kind: z.literal("click"),
    button: z.enum(["left", "right"]),
    point: pointSchema,
    count: z.number().int().optional(),
  }).strict(),
  z.object({
    kind: z.literal("drag"),
    button: z.enum(["left", "right"]),
    from: pointSchema,
    to: pointSchema,
  }).strict(),
]);

const keyboardEventSchema = z.discriminatedUnion("kind", [
  z.object({
    kind: z.literal("text"),
    text: z.string(),
    delayMilliseconds: z.number().int().optional(),
  }).strict(),
  z.object({
    kind: z.literal("keyPress"),
    key: z.string(),
    modifiers: z.array(modifierSchema).optional(),
    count: z.number().int().optional(),
  }).strict(),
  z.object({
    kind: z.literal("hotkey"),
    modifiers: z.array(modifierSchema),
    key: z.string(),
  }).strict(),
]);

const axEventSchema = z.discriminatedUnion("kind", [
  z.object({
    kind: z.literal("focus"),
  }).strict(),
  z.object({
    kind: z.literal("action"),
    action: z.enum([
      "press",
      "showMenu",
      "pick",
      "confirm",
      "cancel",
      "open",
      "increment",
      "decrement",
      "scrollToVisible",
    ]),
  }).strict(),
  z.object({
    kind: z.literal("setValue"),
    value: z.string(),
  }).strict(),
  z.object({
    kind: z.literal("setSelectedText"),
    value: z.string(),
  }).strict(),
  z.object({
    kind: z.literal("scroll"),
    direction: z.enum(["up", "down", "left", "right"]),
    pages: z.number(),
  }).strict(),
]);

export const COMPUTER_USE_TOOL_NAMES = [
  "list_apps",
  "list_windows",
  "get_app_state",
  "start_app_session",
  "stop_app_session",
  "use_mouse",
  "use_keyboard",
  "perform_AX_action",
] as const;

export type ComputerUseToolName = (typeof COMPUTER_USE_TOOL_NAMES)[number];

export type ComputerUseToolSpec = Tool & {
  name: ComputerUseToolName;
};

interface ComputerUseToolDefinition {
  name: ComputerUseToolName;
  description: string;
  parameters: ZodType<ComputerUseArgs, any, any>;
}

interface ComputerUseRpcToolBinding {
  method: string;
  prepare?: (args: ComputerUseArgs, ctx: ToolExecContext) => object;
  render?: (result: unknown, ctx: ToolExecContext) => ToolResultContent[];
  applyRuntimeEffects?: (
    result: ToolExecResult<unknown>,
    args: ComputerUseArgs,
    ctx: ToolExecContext,
    effects: ToolRuntimeEffects,
  ) => void;
}

const COMPUTER_USE_TOOL_DEFINITIONS: ComputerUseToolDefinition[] = [
  {
    name: "list_apps",
    description: "List macOS applications available to Notch Agent Computer Use.",
    parameters: z.object({
      mode: z.enum(["running", "all"]).describe("Use running unless installed apps are needed."),
    }).strict(),
  },
  {
    name: "list_windows",
    description: "List windows for a running macOS app pid.",
    parameters: z.object({
      pid: z.number().int().describe("Target app process id."),
    }).strict(),
  },
  {
    name: "get_app_state",
    description:
      "Read a target window's AX tree and optionally a screenshot in the active Computer Use app session. Returns stateId for AX element actions and screenshot-local mouse actions.",
    parameters: z.object({
      windowId: z.number().int(),
      captureMode: z.enum(["vision", "ax"]),
    }).strict(),
  },
  {
    name: "start_app_session",
    description: "Start a Computer Use app session for app state reads and mouse, keyboard, and AX element actions.",
    parameters: z.object({
      pid: z.number().int(),
      windowId: z.number().int(),
    }).strict(),
  },
  {
    name: "stop_app_session",
    description: "Stop the active Computer Use app session and run cleanup.",
    parameters: z.object({}).strict(),
  },
  {
    name: "use_mouse",
    description:
      "Post a mouse event to a window in the active Computer Use app session. " +
      "Use the stateId from the get_app_state screenshot you are pointing at. " +
      "event variants: " +
      "{kind:\"click\", button:\"left\"|\"right\", point:{x:number,y:number}, count?:integer}; " +
      "{kind:\"drag\", button:\"left\"|\"right\", from:{x:number,y:number}, to:{x:number,y:number}}. " +
      "Coordinates are screenshot-local pixels in that get_app_state image.",
    parameters: z.object({
      windowId: z.number().int(),
      stateId: z.string().describe("State ID from the get_app_state screenshot used for these coordinates."),
      event: mouseEventSchema.describe(
        "Mouse event: {kind:'click', button:'left'|'right', point:{x,y}, count?} or {kind:'drag', button:'left'|'right', from:{x,y}, to:{x,y}}. Coordinates are screenshot-local pixels from the referenced get_app_state image.",
      ),
    }).strict(),
  },
  {
    name: "use_keyboard",
    description:
      "Post a keyboard event to a window in the active Computer Use app session. " +
      "event variants: " +
      "{kind:\"text\", text:string, delayMilliseconds?:integer}; " +
      "{kind:\"keyPress\", key:string, modifiers?:modifier[], count?:integer}; " +
      "{kind:\"hotkey\", modifiers:modifier[], key:string}. " +
      "modifier = \"command\"|\"shift\"|\"option\"|\"control\"|\"function\".",
    parameters: z.object({
      windowId: z.number().int(),
      event: keyboardEventSchema.describe(
        "Keyboard event: {kind:'text', text, delayMilliseconds?}, {kind:'keyPress', key, modifiers?, count?}, or {kind:'hotkey', modifiers, key}.",
      ),
    }).strict(),
  },
  {
    name: "perform_AX_action",
    description:
      "Perform a semantic AX event on an element from a prior get_app_state result. " +
      "event variants: " +
      "{kind:\"focus\"}; " +
      "{kind:\"action\", action:\"press\"|\"showMenu\"|\"pick\"|\"confirm\"|\"cancel\"|\"open\"|\"increment\"|\"decrement\"|\"scrollToVisible\"}; " +
      "{kind:\"setValue\", value:string}; " +
      "{kind:\"setSelectedText\", value:string}; " +
      "{kind:\"scroll\", direction:\"up\"|\"down\"|\"left\"|\"right\", pages:number}.",
    parameters: z.object({
      windowId: z.number().int(),
      stateId: z.string(),
      elementIndex: z.number().int(),
      event: axEventSchema.describe(
        "AX event: {kind:'focus'}, {kind:'action', action}, {kind:'setValue', value}, {kind:'setSelectedText', value}, or {kind:'scroll', direction, pages}.",
      ),
    }).strict(),
  },
];

const COMPUTER_USE_TOOL_BINDINGS = {
  list_apps: {
    method: RPCMethod.computerUseListApps,
  },
  list_windows: {
    method: RPCMethod.computerUseListWindows,
  },
  get_app_state: {
    method: RPCMethod.computerUseGetAppState,
    render: renderComputerUseAppStateResult,
  },
  start_app_session: {
    method: RPCMethod.computerUseStartAppSession,
    applyRuntimeEffects: recordStartedAppSession,
  },
  stop_app_session: {
    method: RPCMethod.computerUseStopAppSession,
    prepare: (_args, ctx) => stopAppSessionParams(ctx),
    applyRuntimeEffects: clearStartedAppSession,
  },
  use_mouse: {
    method: RPCMethod.computerUsePostMouseEvent,
  },
  use_keyboard: {
    method: RPCMethod.computerUsePostKeyboardEvent,
  },
  perform_AX_action: {
    method: RPCMethod.computerUsePostEventToAXElement,
  },
} satisfies Record<ComputerUseToolName, ComputerUseRpcToolBinding>;

export const COMPUTER_USE_TOOL_SPECS: ComputerUseToolSpec[] = COMPUTER_USE_TOOL_DEFINITIONS.map((tool) => ({
  name: tool.name,
  description: tool.description,
  parameters: zodParametersToJSONSchema(tool.parameters),
}));

export function registerComputerUseTools(registry: ToolRegistry, dispatcher: Dispatcher): void {
  for (const tool of createComputerUseTools(dispatcher)) {
    registry.register(tool);
  }
}

export function createComputerUseTools(dispatcher: Dispatcher): ToolHandler<ComputerUseArgs, unknown>[] {
  return COMPUTER_USE_TOOL_DEFINITIONS.map((definition) =>
    createComputerUseRpcTool(definition, COMPUTER_USE_TOOL_BINDINGS[definition.name], dispatcher)
  );
}

function createComputerUseRpcTool(
  definition: ComputerUseToolDefinition,
  binding: ComputerUseRpcToolBinding,
  dispatcher: Dispatcher,
): ToolHandler<ComputerUseArgs, unknown> {
  return defineTool({
    name: definition.name,
    description: definition.description,
    parameters: definition.parameters,
    execute: async (args, ctx) => {
      const rpcArgs = binding.prepare ? binding.prepare(args, ctx) : args;
      const result = await dispatcher.request(binding.method, rpcArgs, { signal: ctx.signal });
      return {
        content: binding.render ? binding.render(result, ctx) : [{ type: "text", text: JSON.stringify(result, null, 2) }],
        details: result,
        isError: false,
      } satisfies ToolExecResult;
    },
    applyRuntimeEffects: binding.applyRuntimeEffects,
  });
}

function stopAppSessionParams(ctx: ToolExecContext): { pid: number } {
  const appSession = ctx.computerUse?.appSession;
  if (!appSession) {
    throw new ToolUserError("no app session was started by this agent session.");
  }
  return { pid: appSession.pid };
}

function recordStartedAppSession(
  _result: ToolExecResult<unknown>,
  args: ComputerUseArgs,
  _ctx: ToolExecContext,
  effects: ToolRuntimeEffects,
): void {
  const { pid, windowId } = args as ComputerUseStartAppSessionParams;
  effects.computerUse.setAppSession({
    pid,
    windowId,
  });
}

function clearStartedAppSession(
  _result: ToolExecResult<unknown>,
  _args: ComputerUseArgs,
  _ctx: ToolExecContext,
  effects: ToolRuntimeEffects,
): void {
  effects.computerUse.clearAppSession();
}

function renderComputerUseAppStateResult(result: unknown, ctx: ToolExecContext): ToolResultContent[] {
  const state = result as ComputerUseGetAppStateResult;
  const screenshot = state.screenshot;
  const content: ToolResultContent[] = [{ type: "text", text: renderComputerUseAppStateText(state) }];
  if (screenshot) {
    const imageContent = consumeScreenshotFile(screenshot, ctx);
    if (imageContent) content.push(imageContent);
  }
  return content;
}

export function renderComputerUseAppStateText(state: ComputerUseGetAppStateResult): string {
  const lines = [
    "<app_state>",
    `App=${renderAppIdentity(state)} (pid ${state.pid})`,
    `State ID: ${state.stateId}`,
    `Elements: ${state.elementCount}`,
  ];
  if (state.screenshot) {
    lines.push(
      `Screenshot: ${state.screenshot.format} ${state.screenshot.width}x${state.screenshot.height} px @${state.screenshot.scaleFactor}x`,
      `Screenshot windowFrame: ${renderBounds(state.screenshot.coordinateSpace.windowFrame)}`,
      `Screenshot windowBounds: ${renderBounds(state.screenshot.coordinateSpace.windowBounds)}`,
      `Screenshot pixelSize: ${state.screenshot.coordinateSpace.pixelSize.width}x${state.screenshot.coordinateSpace.pixelSize.height} px`,
    );
  }
  const tree = state.treeMarkdown.trim();
  if (tree.length > 0) lines.push(tree);
  lines.push("</app_state>");
  return lines.join("\n");
}

function consumeScreenshotFile(
  screenshot: NonNullable<ComputerUseGetAppStateResult["screenshot"]>,
  ctx: ToolExecContext,
): ToolResultContent | null {
  try {
    if (!supportsVision(ctx.model)) return null;
    return {
      type: "image",
      data: readFileSync(screenshot.imagePath).toString("base64"),
      mimeType: screenshot.format === "jpeg" ? "image/jpeg" : "image/png",
    };
  } finally {
    unlinkSync(screenshot.imagePath);
  }
}

function renderBounds(bounds: ComputerUseBounds): string {
  return `x=${bounds.x} y=${bounds.y} width=${bounds.width} height=${bounds.height}`;
}

function renderAppIdentity(state: ComputerUseGetAppStateResult): string {
  if (state.bundleId) return state.bundleId;
  if (state.appName) return state.appName;
  return "unknown";
}
