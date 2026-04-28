// Computer Use tools — agent-facing wrappers around the Shell's
// `computerUse.*` JSON-RPC methods.
//
// Per docs/designs/computer-use.md §"RPC 方法" + rpc-protocol.md
// §"computerUse.*". Every tool below maps 1:1 onto a method; the
// handler is a thin shell that calls `dispatcher.request("computerUse.*",
// args)` and surfaces the structured result to the LLM as a text block.
//
// Design note: every description starts with "background, no focus
// stealing" so the planner doesn't need separate signalling for that
// invariant — it's universal across the namespace.

import {
  RPCMethod,
  RPCErrorCode,
  type ComputerUseListAppsResult,
  type ComputerUseListWindowsParams,
  type ComputerUseListWindowsResult,
  type ComputerUseGetAppStateParams,
  type ComputerUseGetAppStateResult,
  type ComputerUseClickByElementParams,
  type ComputerUseClickByCoordsParams,
  type ComputerUseClickResult,
  type ComputerUseDragParams,
  type ComputerUseDragResult,
  type ComputerUseTypeTextParams,
  type ComputerUseTypeTextResult,
  type ComputerUsePressKeyParams,
  type ComputerUsePressKeyResult,
  type ComputerUseScrollParams,
  type ComputerUseScrollResult,
  type ComputerUseDoctorResult,
} from "../../rpc/rpc-types";
import { Dispatcher, RPCMethodError } from "../../rpc/dispatcher";
import type { ToolResultContent } from "../../llm/types";
import { supportsVision } from "../../llm/models/capabilities";
import { toolRegistry } from "./registry";
import { ToolUserError, type ToolExecContext, type ToolHandler } from "./types";

// ---------------------------------------------------------------------------
// Per-method timeouts (ms) — `docs/designs/rpc-protocol.md` "Dispatcher 并发模型".
// Spec lists Shell→Bun as un-timeouted ("Shell 决定何时超时重试"), but the
// agent loop IS the caller here and the same table applies to its outbound
// requests too — without a budget a hung AX walk freezes the turn AND the
// closed-bar tool indicator until the user cancels. Mirror Shell's table.
// ---------------------------------------------------------------------------

const COMPUTER_USE_TIMEOUTS_MS: Record<string, number> = {
  [RPCMethod.computerUseListApps]: 2_000,
  [RPCMethod.computerUseListWindows]: 2_000,
  [RPCMethod.computerUseDoctor]: 2_000,
  [RPCMethod.computerUseGetAppState]: 10_000,
  [RPCMethod.computerUseClickByElement]: 5_000,
  [RPCMethod.computerUseClickByCoords]: 5_000,
  [RPCMethod.computerUseDrag]: 5_000,
  [RPCMethod.computerUseTypeText]: 5_000,
  [RPCMethod.computerUsePressKey]: 5_000,
  [RPCMethod.computerUseScroll]: 5_000,
};

/// Codes the model can act on next round. The `-32100..-32199` segment is
/// the entire `computerUse.*` recoverable family per `docs/designs/rpc-protocol.md`
/// "错误模型" (stateStale / operationFailed / windowMismatch / windowOffSpace).
/// Plus a few generic codes that also map to "model can fix this": bad params,
/// payload too large (model can ask for `captureMode: 'ax'` next time),
/// permission denied (model can call doctor), and timeout (transient).
function isRecoverableComputerUseError(code: number): boolean {
  if (code <= -32100 && code >= -32199) return true;
  return (
    code === RPCErrorCode.invalidParams ||
    code === RPCErrorCode.payloadTooLarge ||
    code === RPCErrorCode.permissionDenied ||
    code === RPCErrorCode.timeout
  );
}

/// Single chokepoint for every `computerUse.*` request out of a tool. Threads
/// `ctx.signal` (so `agent.cancel` actually aborts AX walks / capture stalls)
/// and the per-method timeout, then converts recoverable RPC errors into
/// `ToolUserError` so the model sees them as tool output instead of the turn
/// being killed by `runTurn`'s top-level catch.
async function callCU<R>(
  dispatcher: Dispatcher,
  method: string,
  params: object,
  ctx: ToolExecContext,
): Promise<R> {
  try {
    return await dispatcher.request<R>(method, params, {
      signal: ctx.signal,
      timeoutMs: COMPUTER_USE_TIMEOUTS_MS[method],
    });
  } catch (err) {
    if (err instanceof RPCMethodError && isRecoverableComputerUseError(err.code)) {
      const dataSuffix =
        err.data !== undefined ? ` data=${JSON.stringify(err.data)}` : "";
      throw new ToolUserError(
        `${method} failed: ${err.message} (code=${err.code}${dataSuffix})`,
      );
    }
    throw err;
  }
}

/// Background-app-control invariant repeated in every spec description so
/// the LLM doesn't need a separate prompt to be reminded.
const BACKGROUND_NOTE =
  "Operates the target app entirely in the background — does not steal focus, does not move the user's cursor, does not raise the target window. ";

/// Build the computer-use tool set bound to a dispatcher. Called once
/// from `index.ts` after the dispatcher has been constructed.
export function registerComputerUseTools(dispatcher: Dispatcher): void {
  toolRegistry.register(buildListApps(dispatcher));
  toolRegistry.register(buildListWindows(dispatcher));
  toolRegistry.register(buildGetAppState(dispatcher));
  toolRegistry.register(buildClickByElement(dispatcher));
  toolRegistry.register(buildClickByCoords(dispatcher));
  toolRegistry.register(buildDrag(dispatcher));
  toolRegistry.register(buildTypeText(dispatcher));
  toolRegistry.register(buildPressKey(dispatcher));
  toolRegistry.register(buildScroll(dispatcher));
  toolRegistry.register(buildDoctor(dispatcher));
}

// ---------------------------------------------------------------------------
// Builders
// ---------------------------------------------------------------------------

function buildListApps(dispatcher: Dispatcher): ToolHandler<Record<string, never>, ComputerUseListAppsResult> {
  return {
    spec: {
      name: "computer_use_list_apps",
      description:
        BACKGROUND_NOTE +
        "Enumerate the operable on-screen macOS apps (NSApplicationActivationPolicyRegular). " +
        "Use this first when you need the pid of an app you intend to operate.",
      parameters: { type: "object", properties: {}, required: [] },
    },
    execute: async (_args, ctx) => {
      const result = await callCU<ComputerUseListAppsResult>(
        dispatcher,
        RPCMethod.computerUseListApps,
        {},
        ctx,
      );
      return {
        content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
        details: result,
        isError: false,
      };
    },
  };
}

function buildListWindows(
  dispatcher: Dispatcher,
): ToolHandler<ComputerUseListWindowsParams, ComputerUseListWindowsResult> {
  return {
    spec: {
      name: "computer_use_list_windows",
      description:
        BACKGROUND_NOTE +
        "List every layer-0 window owned by `pid` along with bounds, on-screen state, " +
        "and current-Space membership. Required before any state / click / type call — " +
        "the Kit refuses to implicitly pick a window.",
      parameters: {
        type: "object",
        properties: {
          pid: { type: "number", description: "macOS pid (from computer_use_list_apps)." },
        },
        required: ["pid"],
      },
    },
    execute: async (args, ctx) => {
      const result = await callCU<ComputerUseListWindowsResult>(
        dispatcher,
        RPCMethod.computerUseListWindows,
        args,
        ctx,
      );
      return {
        content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
        details: result,
        isError: false,
      };
    },
  };
}

function buildGetAppState(
  dispatcher: Dispatcher,
): ToolHandler<ComputerUseGetAppStateParams, ComputerUseGetAppStateResult> {
  return {
    spec: {
      name: "computer_use_get_app_state",
      description:
        BACKGROUND_NOTE +
        "Snapshot the state of `(pid, windowId)`. `captureMode` selects the payload: " +
        "'som' (default — AX tree + screenshot), 'vision' (screenshot only), 'ax' (AX tree only). " +
        "AX walks return a Markdown tree where actionable elements carry `[index]` you can pass " +
        "to `computer_use_click_element` as `elementIndex`. Returns a `stateId` that's valid for 30s " +
        "and is required for element-indexed clicks (use `computer_use_click_at` if you only have pixel coordinates). " +
        "Screenshots are attached as an image content block only when the active model declares " +
        "vision capability in the catalog; otherwise the image is omitted with an inline note and " +
        "you should rely on the AX tree (prefer `captureMode: 'ax'` to skip the wasted capture).",
      parameters: {
        type: "object",
        properties: {
          pid: { type: "number" },
          windowId: { type: "number" },
          captureMode: { type: "string", enum: ["som", "vision", "ax"] },
          maxImageDimension: {
            type: "number",
            description:
              "Optional cap so neither side of the screenshot exceeds this many pixels. Use to keep payloads small.",
          },
        },
        required: ["pid", "windowId"],
      },
    },
    execute: async (args, ctx) => {
      const result = await callCU<ComputerUseGetAppStateResult>(
        dispatcher,
        RPCMethod.computerUseGetAppState,
        args,
        ctx,
      );
      // Capability gate: only attach the screenshot to the LLM stream when
      // the active model can actually consume images. The catalog
      // (`Model.input`) is the single source of truth — see
      // ToolExecContext's contract on why we don't branch on `model.id`.
      // For non-vision models the image still rides in `details` (Shell
      // / Dev Mode reads it independently), but the LLM-visible content
      // is text-only with an explicit note so the model can switch to
      // `captureMode: 'ax'` next round and stop paying for unused captures.
      //
      // This path is intentionally separate from the per-turn user-window
      // screenshot in `agent/prompt.ts`: that one is user-driven (Shell
      // attaches the focused window when submitting a prompt); this one
      // is agent-driven (model wants to look at the app it's controlling).
      // They share only the `ImageContent` wire shape from `llm/types.ts`.
      const modelHasVision = supportsVision(ctx.model);
      // Report screenshot dims in plain WxH pixels — the only coord space
      // the agent should ever reference. The previous `WxH@scaleFactor`
      // form leaked the backing-scale and tempted the model to divide
      // pixel coords by the scale factor before passing them to
      // `computer_use_click_at`, producing systematic offset bugs on
      // retina displays. The Shell now consumes the real screenshot
      // pixel dimensions (recorded server-side in StateCache) when
      // converting the model's coords back to a window-local point.
      const summary = {
        stateId: result.stateId,
        bundleId: result.bundleId,
        appName: result.appName,
        elementCount: result.elementCount,
        screenshotPixelSize: result.screenshot
          ? { width: result.screenshot.width, height: result.screenshot.height }
          : null,
        screenshotAttached: result.screenshot != null && modelHasVision,
      };
      const sections: string[] = [JSON.stringify(summary, null, 2)];
      if (result.screenshot && !modelHasVision) {
        sections.push(
          "[screenshot omitted: active model has no vision capability — " +
            "use captureMode: 'ax' on the next call to skip capture cost]",
        );
      }
      if (result.axTree) sections.push(result.axTree);
      const content: ToolResultContent[] = [{ type: "text", text: sections.join("\n\n") }];
      if (result.screenshot && modelHasVision) {
        content.push({
          type: "image",
          data: result.screenshot.imageBase64,
          mimeType: result.screenshot.format === "jpeg" ? "image/jpeg" : "image/png",
        });
      }
      return {
        content,
        details: result,
        isError: false,
      };
    },
  };
}

// Click was historically a single tool with two arms (element vs. coords)
// gated on optional fields. The model kept filling both arms with placeholder
// dummies and the dispatcher would greedily pick element-mode, hit a missing
// stateId, and fail with `stateStale`. Splitting into two physical tools
// makes it impossible to conflate the modes — each spec lists only the
// fields its mode actually accepts.

function buildClickByElement(
  dispatcher: Dispatcher,
): ToolHandler<ComputerUseClickByElementParams, ComputerUseClickResult> {
  return {
    spec: {
      name: "computer_use_click_element",
      description:
        BACKGROUND_NOTE +
        "Semantic click on an AX-tree element addressed by `(stateId, elementIndex)`. " +
        "Pre-condition: you must already have a fresh `stateId` from `computer_use_get_app_state` " +
        "(TTL 30s) and an `elementIndex` you read from that snapshot's `[index]` markers. " +
        "Use this whenever an element is available — it's more reliable than coordinates because " +
        "the Kit walks the AX action → AX attribute → eventPost degradation chain. " +
        "If you only have pixel coordinates (vision-only mode, or no AX node at the target), use " +
        "`computer_use_click_at` instead. Returns which layer landed: 'axAction', 'axAttribute', or 'eventPost'.",
      parameters: {
        type: "object",
        properties: {
          pid: { type: "number" },
          windowId: { type: "number" },
          stateId: {
            type: "string",
            description: "stateId returned by the most recent computer_use_get_app_state for this (pid, windowId).",
          },
          elementIndex: {
            type: "number",
            description: "Index marker `[N]` from the AX tree. Must exist in the snapshot — there are no sentinel values.",
          },
          action: { type: "string", description: "AX action name (default 'AXPress')." },
        },
        required: ["pid", "windowId", "stateId", "elementIndex"],
      },
    },
    execute: async (args, ctx) => {
      const result = await callCU<ComputerUseClickResult>(
        dispatcher,
        RPCMethod.computerUseClickByElement,
        args,
        ctx,
      );
      return {
        content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
        details: result,
        isError: false,
      };
    },
  };
}

function buildClickByCoords(
  dispatcher: Dispatcher,
): ToolHandler<ComputerUseClickByCoordsParams, ComputerUseClickResult> {
  return {
    spec: {
      name: "computer_use_click_at",
      description:
        BACKGROUND_NOTE +
        "Coordinate click at `(x, y)` in window-local screenshot pixels (top-left origin) within " +
        "`(pid, windowId)`. Use this when you don't have an AX `elementIndex` — typically vision-only " +
        "flows reading directly off a screenshot, or when the target has no AX node. Optional `count` " +
        "1-3 for single/double/triple click. " +
        "When an AX element is available, prefer `computer_use_click_element` — it's more robust.",
      parameters: {
        type: "object",
        properties: {
          pid: { type: "number" },
          windowId: { type: "number" },
          x: { type: "number", description: "Window-local x in screenshot pixels (top-left origin). Pass the raw pixel coordinate you read off the attached image — the Shell knows the real screenshot dimensions and converts internally. Do NOT pre-divide by any scale factor." },
          y: { type: "number", description: "Window-local y in screenshot pixels (top-left origin). Pass the raw pixel coordinate you read off the attached image — the Shell knows the real screenshot dimensions and converts internally. Do NOT pre-divide by any scale factor." },
          count: { type: "number", description: "1, 2 (double), or 3 (triple). Default 1." },
          modifiers: {
            type: "array",
            items: { type: "string" },
            description: "Subset of: cmd/command, shift, option/alt, ctrl/control, fn.",
          },
        },
        required: ["pid", "windowId", "x", "y"],
      },
    },
    execute: async (args, ctx) => {
      const result = await callCU<ComputerUseClickResult>(
        dispatcher,
        RPCMethod.computerUseClickByCoords,
        args,
        ctx,
      );
      return {
        content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
        details: result,
        isError: false,
      };
    },
  };
}

function buildDrag(dispatcher: Dispatcher): ToolHandler<ComputerUseDragParams, ComputerUseDragResult> {
  return {
    spec: {
      name: "computer_use_drag",
      description:
        BACKGROUND_NOTE +
        "Drag from one window-local pixel to another within `(pid, windowId)`. " +
        "12-step linear interpolation; both endpoints must be inside the target window's bounds.",
      parameters: {
        type: "object",
        properties: {
          pid: { type: "number" },
          windowId: { type: "number" },
          from: {
            type: "object",
            properties: { x: { type: "number" }, y: { type: "number" } },
            required: ["x", "y"],
          },
          to: {
            type: "object",
            properties: { x: { type: "number" }, y: { type: "number" } },
            required: ["x", "y"],
          },
        },
        required: ["pid", "windowId", "from", "to"],
      },
    },
    execute: async (args, ctx) => {
      const result = await callCU<ComputerUseDragResult>(
        dispatcher,
        RPCMethod.computerUseDrag,
        args,
        ctx,
      );
      return {
        content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
        details: result,
        isError: false,
      };
    },
  };
}

function buildTypeText(
  dispatcher: Dispatcher,
): ToolHandler<ComputerUseTypeTextParams, ComputerUseTypeTextResult> {
  return {
    spec: {
      name: "computer_use_type_text",
      description:
        BACKGROUND_NOTE +
        "Type Unicode text into the focused field of `(pid, windowId)` using " +
        "`CGEventKeyboardSetUnicodeString` — accents, symbols, and emoji all go through. " +
        "30ms inter-character delay (IME / autocomplete friendly). The caller is " +
        "responsible for ensuring an input field has focus first (e.g. via a click).",
      parameters: {
        type: "object",
        properties: {
          pid: { type: "number" },
          windowId: { type: "number" },
          text: { type: "string" },
        },
        required: ["pid", "windowId", "text"],
      },
    },
    execute: async (args, ctx) => {
      if (typeof args.text !== "string") {
        throw new ToolUserError("computer_use_type_text: text must be a string.");
      }
      const result = await callCU<ComputerUseTypeTextResult>(
        dispatcher,
        RPCMethod.computerUseTypeText,
        args,
        ctx,
      );
      return {
        content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
        details: result,
        isError: false,
      };
    },
  };
}

function buildPressKey(
  dispatcher: Dispatcher,
): ToolHandler<ComputerUsePressKeyParams, ComputerUsePressKeyResult> {
  return {
    spec: {
      name: "computer_use_press_key",
      description:
        BACKGROUND_NOTE +
        "Press a single virtual key in `(pid, windowId)`, optionally with modifiers. " +
        "Named keys: return/enter, tab, space, delete/backspace, escape, left/right/up/down, " +
        "home/end, pageup/pagedown, f1..f12. Single letter / digit names also accepted. " +
        "Modifiers: cmd/command, shift, option/alt, ctrl/control, fn.",
      parameters: {
        type: "object",
        properties: {
          pid: { type: "number" },
          windowId: { type: "number" },
          key: { type: "string" },
          modifiers: { type: "array", items: { type: "string" } },
        },
        required: ["pid", "windowId", "key"],
      },
    },
    execute: async (args, ctx) => {
      const result = await callCU<ComputerUsePressKeyResult>(
        dispatcher,
        RPCMethod.computerUsePressKey,
        args,
        ctx,
      );
      return {
        content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
        details: result,
        isError: false,
      };
    },
  };
}

function buildScroll(dispatcher: Dispatcher): ToolHandler<ComputerUseScrollParams, ComputerUseScrollResult> {
  return {
    spec: {
      name: "computer_use_scroll",
      description:
        BACKGROUND_NOTE +
        "Pixel-quantized wheel scroll at `(x, y)` in `(pid, windowId)`. `dy > 0` scrolls " +
        "content up; `dx > 0` scrolls content right (CGEvent convention).",
      parameters: {
        type: "object",
        properties: {
          pid: { type: "number" },
          windowId: { type: "number" },
          x: { type: "number" },
          y: { type: "number" },
          dx: { type: "number" },
          dy: { type: "number" },
        },
        required: ["pid", "windowId", "x", "y", "dx", "dy"],
      },
    },
    execute: async (args, ctx) => {
      const result = await callCU<ComputerUseScrollResult>(
        dispatcher,
        RPCMethod.computerUseScroll,
        args,
        ctx,
      );
      return {
        content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
        details: result,
        isError: false,
      };
    },
  };
}

function buildDoctor(
  dispatcher: Dispatcher,
): ToolHandler<Record<string, never>, ComputerUseDoctorResult> {
  return {
    spec: {
      name: "computer_use_doctor",
      description:
        BACKGROUND_NOTE +
        "Diagnose Computer Use prerequisites: Accessibility / Screen Recording grants and " +
        "the resolved status of each SkyLight private SPI the Kit depends on. Call this " +
        "before issuing any operation when uncertain about permissions or SPI availability.",
      parameters: { type: "object", properties: {}, required: [] },
    },
    execute: async (_args, ctx) => {
      const result = await callCU<ComputerUseDoctorResult>(
        dispatcher,
        RPCMethod.computerUseDoctor,
        {},
        ctx,
      );
      return {
        content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
        details: result,
        isError: false,
      };
    },
  };
}
