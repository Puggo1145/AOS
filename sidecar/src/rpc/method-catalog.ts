// RPC method catalog.
//
// The dispatcher consumes this as the single local source for method-level
// routing metadata: method direction, split request/notification kind,
// inbound handler timeout, and fast-path scheduling. Wire schemas still live
// in `rpc-types.ts`; this module owns how the sidecar is allowed to move
// those methods across the channel.

import { RPCMethod } from "./rpc-types";

export type Direction = "shellToBun" | "bunToShell" | "both";
export type SplitMethodKind = "request" | "notification";
export type RPCMethodName = (typeof RPCMethod)[keyof typeof RPCMethod];

export const DEFAULT_INBOUND_HANDLER_TIMEOUT_MS = 5_000;

export interface RPCMethodSemantics {
  readonly method: RPCMethodName;
  readonly namespace: string;
  readonly direction: Direction;
  readonly kind: SplitMethodKind;
  readonly inboundTimeoutMs: number;
  readonly fastPath: boolean;
}

function namespaceOf(method: string): string {
  const i = method.indexOf(".");
  return i < 0 ? method : method.slice(0, i);
}

function method(
  methodName: RPCMethodName,
  direction: Direction,
  kind: SplitMethodKind,
  overrides: Partial<Pick<RPCMethodSemantics, "inboundTimeoutMs" | "fastPath">> = {},
): RPCMethodSemantics {
  return {
    method: methodName,
    namespace: namespaceOf(methodName),
    direction,
    kind,
    inboundTimeoutMs: overrides.inboundTimeoutMs ?? DEFAULT_INBOUND_HANDLER_TIMEOUT_MS,
    fastPath: overrides.fastPath ?? false,
  };
}

// One entry per wire method. Wire payload schemas remain in `rpc-types.ts`;
// this catalog owns the Sidecar-local routing semantics consumed by Dispatcher.
const RPC_METHOD_CATALOG = {
  [RPCMethod.rpcHello]: method(RPCMethod.rpcHello, "bunToShell", "request"),
  [RPCMethod.rpcPing]: method(RPCMethod.rpcPing, "both", "request", {
    inboundTimeoutMs: 1_000,
    fastPath: true,
  }),

  [RPCMethod.agentSubmit]: method(RPCMethod.agentSubmit, "shellToBun", "request", { inboundTimeoutMs: 1_000 }),
  [RPCMethod.agentCancel]: method(RPCMethod.agentCancel, "shellToBun", "request", {
    inboundTimeoutMs: 1_000,
    fastPath: true,
  }),
  [RPCMethod.agentReset]: method(RPCMethod.agentReset, "shellToBun", "request"),
  // Manual /compact awaits a full summarization LLM round inline. The Shell
  // side allows 120s (RPCClient.timeout); pad slightly so the dispatcher
  // does not timeout before the Shell does.
  [RPCMethod.agentCompact]: method(RPCMethod.agentCompact, "shellToBun", "request", { inboundTimeoutMs: 130_000 }),

  [RPCMethod.conversationTurnStarted]: method(RPCMethod.conversationTurnStarted, "bunToShell", "notification"),
  [RPCMethod.conversationReset]: method(RPCMethod.conversationReset, "bunToShell", "notification"),

  [RPCMethod.uiToken]: method(RPCMethod.uiToken, "bunToShell", "notification"),
  [RPCMethod.uiThinking]: method(RPCMethod.uiThinking, "bunToShell", "notification"),
  [RPCMethod.uiToolCall]: method(RPCMethod.uiToolCall, "bunToShell", "notification"),
  [RPCMethod.uiStatus]: method(RPCMethod.uiStatus, "bunToShell", "notification"),
  [RPCMethod.uiError]: method(RPCMethod.uiError, "bunToShell", "notification"),
  [RPCMethod.uiUsage]: method(RPCMethod.uiUsage, "bunToShell", "notification"),
  [RPCMethod.uiTodo]: method(RPCMethod.uiTodo, "bunToShell", "notification"),
  [RPCMethod.uiCompact]: method(RPCMethod.uiCompact, "bunToShell", "notification"),

  [RPCMethod.permissionRequestApproval]: method(RPCMethod.permissionRequestApproval, "bunToShell", "request"),
  [RPCMethod.permissionApprovalCancelled]: method(RPCMethod.permissionApprovalCancelled, "bunToShell", "notification"),

  [RPCMethod.providerStatus]: method(RPCMethod.providerStatus, "shellToBun", "request"),
  [RPCMethod.providerStartLogin]: method(RPCMethod.providerStartLogin, "shellToBun", "request"),
  [RPCMethod.providerCancelLogin]: method(RPCMethod.providerCancelLogin, "shellToBun", "request"),
  [RPCMethod.providerLoginStatus]: method(RPCMethod.providerLoginStatus, "bunToShell", "notification"),
  [RPCMethod.providerStatusChanged]: method(RPCMethod.providerStatusChanged, "bunToShell", "notification"),
  [RPCMethod.providerSetApiKey]: method(RPCMethod.providerSetApiKey, "shellToBun", "request"),
  [RPCMethod.providerClearApiKey]: method(RPCMethod.providerClearApiKey, "shellToBun", "request"),
  [RPCMethod.providerLogout]: method(RPCMethod.providerLogout, "shellToBun", "request"),

  [RPCMethod.configGet]: method(RPCMethod.configGet, "shellToBun", "request"),
  [RPCMethod.configSet]: method(RPCMethod.configSet, "shellToBun", "request"),
  [RPCMethod.configSetEffort]: method(RPCMethod.configSetEffort, "shellToBun", "request"),
  [RPCMethod.configMarkOnboardingCompleted]: method(RPCMethod.configMarkOnboardingCompleted, "shellToBun", "request"),

  [RPCMethod.computerUseListApps]: method(RPCMethod.computerUseListApps, "bunToShell", "request"),
  [RPCMethod.computerUseListWindows]: method(RPCMethod.computerUseListWindows, "bunToShell", "request"),
  [RPCMethod.computerUseGetAppState]: method(RPCMethod.computerUseGetAppState, "bunToShell", "request"),
  [RPCMethod.computerUseStartAppSession]: method(RPCMethod.computerUseStartAppSession, "bunToShell", "request"),
  [RPCMethod.computerUseStopAppSession]: method(RPCMethod.computerUseStopAppSession, "bunToShell", "request"),
  [RPCMethod.computerUsePostMouseEvent]: method(RPCMethod.computerUsePostMouseEvent, "bunToShell", "request"),
  [RPCMethod.computerUsePostKeyboardEvent]: method(RPCMethod.computerUsePostKeyboardEvent, "bunToShell", "request"),
  [RPCMethod.computerUsePostEventToAXElement]: method(
    RPCMethod.computerUsePostEventToAXElement,
    "bunToShell",
    "request",
  ),

  [RPCMethod.devContextGet]: method(RPCMethod.devContextGet, "shellToBun", "request"),
  [RPCMethod.devContextChanged]: method(RPCMethod.devContextChanged, "bunToShell", "notification"),

  [RPCMethod.sessionCreate]: method(RPCMethod.sessionCreate, "shellToBun", "request"),
  [RPCMethod.sessionList]: method(RPCMethod.sessionList, "shellToBun", "request"),
  [RPCMethod.sessionActivate]: method(RPCMethod.sessionActivate, "shellToBun", "request"),
  [RPCMethod.sessionCreated]: method(RPCMethod.sessionCreated, "bunToShell", "notification"),
  [RPCMethod.sessionActivated]: method(RPCMethod.sessionActivated, "bunToShell", "notification"),
  [RPCMethod.sessionListChanged]: method(RPCMethod.sessionListChanged, "bunToShell", "notification"),
} satisfies Record<RPCMethodName, RPCMethodSemantics>;

const RPC_METHOD_SEMANTICS = new Map<string, RPCMethodSemantics>(
  Object.values(RPC_METHOD_CATALOG).map((entry) => [entry.method, entry]),
);

export function rpcMethodSemantics(method: string): RPCMethodSemantics | undefined {
  return RPC_METHOD_SEMANTICS.get(method);
}

export function allRpcMethodSemantics(): RPCMethodSemantics[] {
  return Object.values(RPC_METHOD_CATALOG);
}

function requireRpcMethodSemantics(method: string): RPCMethodSemantics {
  const semantics = rpcMethodSemantics(method);
  if (!semantics) throw new Error(`unknown RPC method: ${method}`);
  return semantics;
}

export function directionOf(method: string): Direction {
  return requireRpcMethodSemantics(method).direction;
}

export function splitKindOf(method: string): SplitMethodKind | undefined {
  return rpcMethodSemantics(method)?.kind;
}

export function inboundTimeoutMs(method: string): number {
  return requireRpcMethodSemantics(method).inboundTimeoutMs;
}

export function isFastPathMethod(method: string): boolean {
  return requireRpcMethodSemantics(method).fastPath;
}
