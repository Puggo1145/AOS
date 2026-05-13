import { supportsVision } from "../../llm/models/capabilities";
import type { ToolResultContent } from "../../llm/types";
import { RPCMethod, type ComputerUseGetAppStateResult } from "../../rpc/rpc-types";
import type { Dispatcher } from "../../rpc/dispatcher";
import { ToolUserError, type ToolExecContext, type ToolExecResult, type ToolHandler } from "./types";
import type { ToolRegistry } from "./registry";

type ComputerUseArgs = Record<string, unknown>;

const pointSchema = {
  type: "object" as const,
  properties: {
    x: { type: "number" as const },
    y: { type: "number" as const },
  },
  required: ["x", "y"],
  additionalProperties: false,
};

const passthroughEventSchema = {
  type: "object" as const,
  properties: {
    kind: { type: "string" as const },
  },
  required: ["kind"],
  additionalProperties: true,
};

const modifierSchema = {
  type: "array" as const,
  items: { type: "string" as const, enum: ["command", "shift", "option", "control", "function"] },
};

export function registerComputerUseTools(registry: ToolRegistry, dispatcher: Dispatcher): void {
  for (const tool of createComputerUseTools(dispatcher)) {
    registry.register(tool);
  }
}

export function createComputerUseTools(dispatcher: Dispatcher): ToolHandler[] {
  return [
    rpcTool({
      name: "list_apps",
      description: "List macOS applications available to AOS Computer Use.",
      method: RPCMethod.computerUseListApps,
      parameters: {
        type: "object",
        properties: {
          mode: { type: "string", enum: ["running", "all"], description: "Use running unless installed apps are needed." },
        },
        required: ["mode"],
        additionalProperties: false,
      },
      dispatcher,
    }),
    rpcTool({
      name: "list_windows",
      description: "List windows for a running macOS app pid.",
      method: RPCMethod.computerUseListWindows,
      parameters: {
        type: "object",
        properties: {
          pid: { type: "integer", description: "Target app process id." },
        },
        required: ["pid"],
        additionalProperties: false,
      },
      dispatcher,
    }),
    rpcTool({
      name: "get_app_state",
      description: "Read a target window's AX tree and optionally a screenshot. Returns stateId for AX element actions.",
      method: RPCMethod.computerUseGetAppState,
      parameters: {
        type: "object",
        properties: {
          pid: { type: "integer" },
          windowId: { type: "integer" },
          captureMode: { type: "string", enum: ["vision", "ax"] },
          maxImageDimension: { type: "integer", description: "0 means no explicit dimension cap" },
        },
        required: ["pid", "windowId", "captureMode", "maxImageDimension"],
        additionalProperties: false,
      },
      dispatcher,
      render: renderAppStateResult,
    }),
    rpcTool({
      name: "start_app_session",
      description: "Start a Computer Use app session for coordinate mouse and keyboard events.",
      method: RPCMethod.computerUseStartAppSession,
      parameters: {
        type: "object",
        properties: {
          pid: { type: "integer" },
          windowId: { type: "integer" },
        },
        required: ["pid", "windowId"],
        additionalProperties: false,
      },
      dispatcher,
    }),
    rpcTool({
      name: "stop_app_session",
      description: "Stop the active Computer Use app session and run cleanup.",
      method: RPCMethod.computerUseStopAppSession,
      parameters: {
        type: "object",
        properties: {},
        additionalProperties: false,
      },
      dispatcher,
    }),
    rpcTool({
      name: "use_mouse",
      description:
        "Post a mouse event to a window in the active Computer Use app session. " +
        "event variants: " +
        "{kind:\"click\", button:\"left\"|\"right\", point:{x:number,y:number}, count?:positive integer}; " +
        "{kind:\"drag\", button:\"left\"|\"right\", from:{x:number,y:number}, to:{x:number,y:number}}. " +
        "Coordinates are screen points.",
      method: RPCMethod.computerUsePostMouseEvent,
      parameters: {
        type: "object",
        properties: {
          windowId: { type: "integer" },
          event: {
            ...passthroughEventSchema,
            description:
              "Mouse event: {kind:'click', button:'left'|'right', point:{x,y}, count?} or {kind:'drag', button:'left'|'right', from:{x,y}, to:{x,y}}. Coordinates are screen points.",
            properties: {
              kind: { type: "string", enum: ["click", "drag"] },
              button: { type: "string", enum: ["left", "right"] },
              point: pointSchema,
              count: { type: "integer" },
              from: pointSchema,
              to: pointSchema,
            },
          },
        },
        required: ["windowId", "event"],
        additionalProperties: false,
      },
      dispatcher,
      validate: validateMouseArgs,
    }),
    rpcTool({
      name: "use_keyboard",
      description:
        "Post a keyboard event to a window in the active Computer Use app session. " +
        "event variants: " +
        "{kind:\"text\", text:string, delayMilliseconds?:integer 0..200}; " +
        "{kind:\"keyPress\", key:string, modifiers?:modifier[], count?:positive integer}; " +
        "{kind:\"hotkey\", modifiers:non-empty modifier[], key:string}. " +
        "modifier = \"command\"|\"shift\"|\"option\"|\"control\"|\"function\".",
      method: RPCMethod.computerUsePostKeyboardEvent,
      parameters: {
        type: "object",
        properties: {
          windowId: { type: "integer" },
          event: {
            ...passthroughEventSchema,
            description:
              "Keyboard event: {kind:'text', text, delayMilliseconds? [0..200]}, {kind:'keyPress', key, modifiers?, count? > 0}, or {kind:'hotkey', modifiers (non-empty), key}.",
            properties: {
              kind: { type: "string", enum: ["text", "keyPress", "hotkey"] },
              text: { type: "string" },
              delayMilliseconds: { type: "integer", description: "Typing delay in milliseconds, 0 through 200." },
              key: { type: "string" },
              modifiers: modifierSchema,
              count: { type: "integer", description: "Positive key press repeat count." },
            },
          },
        },
        required: ["windowId", "event"],
        additionalProperties: false,
      },
      dispatcher,
      validate: validateKeyboardArgs,
    }),
    rpcTool({
      name: "perform_AX_action",
      description:
        "Perform a semantic AX event on an element from a prior get_app_state result. " +
        "event variants: " +
        "{kind:\"focus\"}; " +
        "{kind:\"action\", action:\"press\"|\"showMenu\"|\"pick\"|\"confirm\"|\"cancel\"|\"open\"|\"increment\"|\"decrement\"|\"scrollToVisible\"}; " +
        "{kind:\"setValue\", value:string}; " +
        "{kind:\"setSelectedText\", value:string}; " +
        "{kind:\"scroll\", direction:\"up\"|\"down\"|\"left\"|\"right\", pages:number > 0}.",
      method: RPCMethod.computerUsePostEventToAXElement,
      parameters: {
        type: "object",
        properties: {
          pid: { type: "integer" },
          windowId: { type: "integer" },
          stateId: { type: "string" },
          elementIndex: { type: "integer" },
          event: {
            ...passthroughEventSchema,
            description:
              "AX event: {kind:'focus'}, {kind:'action', action}, {kind:'setValue', value}, {kind:'setSelectedText', value}, or {kind:'scroll', direction, pages}.",
            properties: {
              kind: { type: "string", enum: ["focus", "action", "setValue", "setSelectedText", "scroll"] },
              action: {
                type: "string",
                enum: [
                  "press",
                  "showMenu",
                  "pick",
                  "confirm",
                  "cancel",
                  "open",
                  "increment",
                  "decrement",
                  "scrollToVisible",
                ],
              },
              value: { type: "string" },
              direction: { type: "string", enum: ["up", "down", "left", "right"] },
              pages: { type: "number", description: "Positive page count." },
            },
          },
        },
        required: ["pid", "windowId", "stateId", "elementIndex", "event"],
        additionalProperties: false,
      },
      dispatcher,
      validate: validateAXArgs,
    }),
  ];
}

function rpcTool(options: {
  name: string;
  description: string;
  method: string;
  parameters: ToolHandler["spec"]["parameters"];
  dispatcher: Dispatcher;
  validate?: (args: ComputerUseArgs) => void;
  render?: (result: unknown, ctx: ToolExecContext) => ToolResultContent[];
}): ToolHandler<ComputerUseArgs, unknown> {
  return {
    spec: {
      name: options.name,
      description: options.description,
      parameters: options.parameters,
    },
    execute: async (args, ctx) => {
      options.validate?.(args);
      const result = await options.dispatcher.request(options.method, args, { signal: ctx.signal });
      return {
        content: options.render ? options.render(result, ctx) : [{ type: "text", text: JSON.stringify(result, null, 2) }],
        details: result,
        isError: false,
      } satisfies ToolExecResult;
    },
  };
}

function validateMouseArgs(args: ComputerUseArgs): void {
  const event = requireEvent(args);
  const kind = requireString(event, "event.kind");
  switch (kind) {
    case "click":
      requireEnum(event, "event.button", ["left", "right"]);
      requirePoint(event, "point", "event.point");
      if ("count" in event) requirePositiveInteger(event, "event.count");
      return;
    case "drag":
      requireEnum(event, "event.button", ["left", "right"]);
      requirePoint(event, "from", "event.from");
      requirePoint(event, "to", "event.to");
      return;
    default:
      throw new ToolUserError(`event.kind must be one of click, drag.`);
  }
}

function validateKeyboardArgs(args: ComputerUseArgs): void {
  const event = requireEvent(args);
  const kind = requireString(event, "event.kind");
  switch (kind) {
    case "text":
      requireString(event, "event.text");
      if ("delayMilliseconds" in event) requireIntegerRange(event, "event.delayMilliseconds", 0, 200);
      return;
    case "keyPress":
      requireString(event, "event.key");
      if ("modifiers" in event) requireStringArray(event, "event.modifiers");
      if ("count" in event) requirePositiveInteger(event, "event.count");
      return;
    case "hotkey":
      requireNonEmptyStringArray(event, "event.modifiers");
      requireString(event, "event.key");
      return;
    default:
      throw new ToolUserError(`event.kind must be one of text, keyPress, hotkey.`);
  }
}

function validateAXArgs(args: ComputerUseArgs): void {
  const event = requireEvent(args);
  const kind = requireString(event, "event.kind");
  switch (kind) {
    case "focus":
      return;
    case "action":
      requireEnum(event, "event.action", [
        "press",
        "showMenu",
        "pick",
        "confirm",
        "cancel",
        "open",
        "increment",
        "decrement",
        "scrollToVisible",
      ]);
      return;
    case "setValue":
    case "setSelectedText":
      requireString(event, "event.value");
      return;
    case "scroll":
      requireEnum(event, "event.direction", ["up", "down", "left", "right"]);
      requirePositiveNumber(event, "event.pages");
      return;
    default:
      throw new ToolUserError(`event.kind must be one of focus, action, setValue, setSelectedText, scroll.`);
  }
}

function requireEvent(args: ComputerUseArgs): Record<string, unknown> {
  const event = args.event;
  if (!event || typeof event !== "object" || Array.isArray(event)) {
    throw new ToolUserError("event must be an object.");
  }
  return event as Record<string, unknown>;
}

function requireString(obj: Record<string, unknown>, path: string): string {
  const key = leafKey(path);
  const value = obj[key];
  if (typeof value !== "string" || value.length === 0) {
    throw new ToolUserError(`${path} is required and must be a non-empty string.`);
  }
  return value;
}

function requireEnum(obj: Record<string, unknown>, path: string, values: string[]): string {
  const value = requireString(obj, path);
  if (!values.includes(value)) {
    throw new ToolUserError(`${path} must be one of ${values.join(", ")}.`);
  }
  return value;
}

function requireInteger(obj: Record<string, unknown>, path: string): number {
  const value = obj[leafKey(path)];
  if (typeof value !== "number" || !Number.isInteger(value)) {
    throw new ToolUserError(`${path} must be an integer.`);
  }
  return value;
}

function requirePositiveInteger(obj: Record<string, unknown>, path: string): number {
  const value = requireInteger(obj, path);
  if (value <= 0) {
    throw new ToolUserError(`${path} must be a positive integer.`);
  }
  return value;
}

function requireIntegerRange(obj: Record<string, unknown>, path: string, min: number, max: number): number {
  const value = requireInteger(obj, path);
  if (value < min || value > max) {
    throw new ToolUserError(`${path} must be an integer between ${min} and ${max}.`);
  }
  return value;
}

function requireNumber(obj: Record<string, unknown>, path: string): number {
  const value = obj[leafKey(path)];
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new ToolUserError(`${path} is required and must be a number.`);
  }
  return value;
}

function requirePositiveNumber(obj: Record<string, unknown>, path: string): number {
  const value = requireNumber(obj, path);
  if (value <= 0) {
    throw new ToolUserError(`${path} is required and must be greater than 0.`);
  }
  return value;
}

function requireStringArray(obj: Record<string, unknown>, path: string): string[] {
  const value = obj[leafKey(path)];
  if (!Array.isArray(value) || !value.every((item) => typeof item === "string" && item.length > 0)) {
    throw new ToolUserError(`${path} is required and must be an array of non-empty strings.`);
  }
  return value;
}

function requireNonEmptyStringArray(obj: Record<string, unknown>, path: string): string[] {
  const value = requireStringArray(obj, path);
  if (value.length === 0) {
    throw new ToolUserError(`${path} is required and must contain at least one non-empty string.`);
  }
  return value;
}

function requirePoint(obj: Record<string, unknown>, key: string, path: string): void {
  const value = obj[key];
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new ToolUserError(`${path} is required and must be an object.`);
  }
  const point = value as Record<string, unknown>;
  requireNumber(point, `${path}.x`);
  requireNumber(point, `${path}.y`);
}

function leafKey(path: string): string {
  const parts = path.split(".");
  return parts[parts.length - 1]!;
}

function renderAppStateResult(result: unknown, ctx: ToolExecContext): ToolResultContent[] {
  const state = result as ComputerUseGetAppStateResult;
  const screenshot = state.screenshot;
  const textState = screenshot
    ? {
        ...state,
        screenshot: {
          ...screenshot,
          imageBase64: `[base64 ${screenshot.imageBase64.length} chars]`,
        },
      }
    : state;
  const content: ToolResultContent[] = [{ type: "text", text: JSON.stringify(textState, null, 2) }];
  if (screenshot && supportsVision(ctx.model)) {
    content.push({
      type: "image",
      data: screenshot.imageBase64,
      mimeType: screenshot.format === "jpeg" ? "image/jpeg" : "image/png",
    });
  }
  return content;
}
