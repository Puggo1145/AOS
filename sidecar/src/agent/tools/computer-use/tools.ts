import { RPCMethod } from "../../../rpc/rpc-types";
import type { Dispatcher } from "../../../rpc/dispatcher";
import type { ToolHandler } from "../types";
import { createComputerUseRpcTool, type ComputerUseRpcToolBinding } from "./adapter";
import { COMPUTER_USE_TOOL_SPECS, type ComputerUseToolName } from "./catalog";
import { renderComputerUseAppStateResult } from "./rendering";
import {
  clearStartedAppSession,
  getAppStateParams,
  prepareMouseEventParams,
  recordAppStateCoordinateSpace,
  recordStartedAppSession,
  stopAppSessionParams,
} from "./state";
import { validateAXArgs, validateKeyboardArgs, validateMouseArgs } from "./validation";

const COMPUTER_USE_TOOL_BINDINGS = {
  list_apps: {
    method: RPCMethod.computerUseListApps,
  },
  list_windows: {
    method: RPCMethod.computerUseListWindows,
  },
  get_app_state: {
    method: RPCMethod.computerUseGetAppState,
    prepare: getAppStateParams,
    render: renderComputerUseAppStateResult,
    afterResult: recordAppStateCoordinateSpace,
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
    validate: validateMouseArgs,
    prepare: prepareMouseEventParams,
  },
  use_keyboard: {
    method: RPCMethod.computerUsePostKeyboardEvent,
    validate: validateKeyboardArgs,
  },
  perform_AX_action: {
    method: RPCMethod.computerUsePostEventToAXElement,
    validate: validateAXArgs,
  },
} satisfies Record<ComputerUseToolName, ComputerUseRpcToolBinding>;

export function createComputerUseToolHandlers(dispatcher: Dispatcher): ToolHandler[] {
  return COMPUTER_USE_TOOL_SPECS.map((spec) => createComputerUseRpcTool(spec, COMPUTER_USE_TOOL_BINDINGS[spec.name], dispatcher));
}
