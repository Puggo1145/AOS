import type {
  ComputerUseGetAppStateParams,
  ComputerUseGetAppStateResult,
  ComputerUseMouseEvent,
  ComputerUsePostMouseEventParams,
} from "../../../rpc/rpc-types";
import {
  ToolUserError,
  type ToolExecContext,
  type ToolExecResult,
  type ToolRuntimeEffects,
} from "../types";
import type { ComputerUseArgs } from "./types";
import {
  requireCaptureMode,
  requireEvent,
  requireInteger,
  requireString,
  validateMouseEventWithinScreenshot,
} from "./validation";

export function stopAppSessionParams(ctx: ToolExecContext): { pid: number } {
  const appSession = ctx.computerUse?.appSession;
  if (!appSession) {
    throw new ToolUserError("no app session was started by this agent session.");
  }
  return { pid: appSession.pid };
}

export function recordStartedAppSession(
  _result: ToolExecResult<unknown>,
  args: ComputerUseArgs,
  _ctx: ToolExecContext,
  effects: ToolRuntimeEffects,
): void {
  effects.computerUse.setAppSession({
    pid: requireInteger(args, "pid"),
    windowId: requireInteger(args, "windowId"),
  });
}

export function clearStartedAppSession(
  _result: ToolExecResult<unknown>,
  _args: ComputerUseArgs,
  _ctx: ToolExecContext,
  effects: ToolRuntimeEffects,
): void {
  effects.computerUse.clearAppSession();
}

export function getAppStateParams(args: ComputerUseArgs): ComputerUseGetAppStateParams {
  return {
    windowId: requireInteger(args, "windowId"),
    captureMode: requireCaptureMode(args),
  };
}

export function prepareMouseEventParams(args: ComputerUseArgs, ctx: ToolExecContext): ComputerUsePostMouseEventParams {
  const stateId = requireString(args, "stateId");
  const stateCache = requireComputerUseRuntime(ctx).stateCache;
  const lookup = stateCache.lookup(stateId);
  if (lookup.kind === "expired") {
    throw new ToolUserError(`stale screenshot coordinate space for stateId ${stateId}. Call get_app_state with captureMode "vision" again.`);
  }
  if (lookup.kind === "missing") {
    throw new ToolUserError(`no screenshot coordinate space found for stateId ${stateId}. Call get_app_state with captureMode "vision" first.`);
  }
  const { record } = lookup;
  const windowId = requireInteger(args, "windowId");
  if (record.windowId !== windowId) {
    throw new ToolUserError(`stateId ${stateId} belongs to window ${record.windowId}, not window ${windowId}.`);
  }
  const event = requireEvent(args);
  validateMouseEventWithinScreenshot(event, record.coordinateSpace.pixelSize);
  return {
    windowId,
    stateId,
    event: event as ComputerUseMouseEvent,
  };
}

export function recordAppStateCoordinateSpace(result: unknown, args: ComputerUseArgs, ctx: ToolExecContext): void {
  const state = result as ComputerUseGetAppStateResult;
  if (!state.screenshot) return;
  requireComputerUseRuntime(ctx).stateCache.record({
    stateId: state.stateId,
    windowId: requireInteger(args, "windowId"),
    coordinateSpace: state.screenshot.coordinateSpace,
  });
}

function requireComputerUseRuntime(ctx: ToolExecContext): NonNullable<ToolExecContext["computerUse"]> {
  if (!ctx.computerUse) {
    throw new ToolUserError("computer use runtime is unavailable.");
  }
  return ctx.computerUse;
}
