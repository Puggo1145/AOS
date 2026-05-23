import type { Tool } from "../../../llm/types";

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

export const COMPUTER_USE_TOOL_SPECS: ComputerUseToolSpec[] = [
  {
    name: "list_apps",
    description: "List macOS applications available to Notch Agent Computer Use.",
    parameters: {
      type: "object",
      properties: {
        mode: { type: "string", enum: ["running", "all"], description: "Use running unless installed apps are needed." },
      },
      required: ["mode"],
      additionalProperties: false,
    },
  },
  {
    name: "list_windows",
    description: "List windows for a running macOS app pid.",
    parameters: {
      type: "object",
      properties: {
        pid: { type: "integer", description: "Target app process id." },
      },
      required: ["pid"],
      additionalProperties: false,
    },
  },
  {
    name: "get_app_state",
    description:
      "Read a target window's AX tree and optionally a screenshot in the active Computer Use app session. Returns stateId for AX element actions and screenshot-local mouse actions.",
    parameters: {
      type: "object",
      properties: {
        windowId: { type: "integer" },
        captureMode: { type: "string", enum: ["vision", "ax"] },
      },
      required: ["windowId", "captureMode"],
      additionalProperties: false,
    },
  },
  {
    name: "start_app_session",
    description: "Start a Computer Use app session for app state reads and mouse, keyboard, and AX element actions.",
    parameters: {
      type: "object",
      properties: {
        pid: { type: "integer" },
        windowId: { type: "integer" },
      },
      required: ["pid", "windowId"],
      additionalProperties: false,
    },
  },
  {
    name: "stop_app_session",
    description: "Stop the active Computer Use app session and run cleanup.",
    parameters: {
      type: "object",
      properties: {},
      additionalProperties: false,
    },
  },
  {
    name: "use_mouse",
    description:
      "Post a mouse event to a window in the active Computer Use app session. " +
      "Use the stateId from the get_app_state screenshot you are pointing at. " +
      "event variants: " +
      "{kind:\"click\", button:\"left\"|\"right\", point:{x:number,y:number}, count?:positive integer}; " +
      "{kind:\"drag\", button:\"left\"|\"right\", from:{x:number,y:number}, to:{x:number,y:number}}. " +
      "Coordinates are screenshot-local pixels in that get_app_state image.",
    parameters: {
      type: "object",
      properties: {
        windowId: { type: "integer" },
        stateId: { type: "string", description: "State ID from the get_app_state screenshot used for these coordinates." },
        event: {
          ...passthroughEventSchema,
          description:
            "Mouse event: {kind:'click', button:'left'|'right', point:{x,y}, count?} or {kind:'drag', button:'left'|'right', from:{x,y}, to:{x,y}}. Coordinates are screenshot-local pixels from the referenced get_app_state image.",
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
      required: ["windowId", "stateId", "event"],
      additionalProperties: false,
    },
  },
  {
    name: "use_keyboard",
    description:
      "Post a keyboard event to a window in the active Computer Use app session. " +
      "event variants: " +
      "{kind:\"text\", text:string, delayMilliseconds?:integer 0..200}; " +
      "{kind:\"keyPress\", key:string, modifiers?:modifier[], count?:positive integer}; " +
      "{kind:\"hotkey\", modifiers:non-empty modifier[], key:string}. " +
      "modifier = \"command\"|\"shift\"|\"option\"|\"control\"|\"function\".",
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
      "{kind:\"scroll\", direction:\"up\"|\"down\"|\"left\"|\"right\", pages:number > 0}.",
    parameters: {
      type: "object",
      properties: {
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
      required: ["windowId", "stateId", "elementIndex", "event"],
      additionalProperties: false,
    },
  },
];
