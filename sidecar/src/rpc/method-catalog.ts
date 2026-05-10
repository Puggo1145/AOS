// RPC method catalog.
//
// The dispatcher consumes this as the single local source for method-level
// routing metadata: namespace direction, split request/notification kind,
// inbound handler timeout, and fast-path scheduling. Wire schemas still live
// in `rpc-types.ts`; this module owns how the sidecar is allowed to move
// those methods across the channel.

import { RPCMethod } from "./rpc-types";

export type Direction = "shellToBun" | "bunToShell" | "both";
export type SplitMethodKind = "request" | "notification";

const DEFAULT_HANDLER_TIMEOUT_MS = 5_000;

function namespaceOf(method: string): string {
  const i = method.indexOf(".");
  return i < 0 ? method : method.slice(0, i);
}

const NAMESPACE_DIRECTIONS: Record<string, Direction> = {
  rpc: "both",
  session: "both",
  provider: "both",
  dev: "both",
  agent: "shellToBun",
  settings: "shellToBun",
  config: "shellToBun",
  ui: "bunToShell",
  conversation: "bunToShell",
};

const SPLIT_METHOD_KINDS: Record<string, SplitMethodKind> = {
  [RPCMethod.providerStatus]: "request",
  [RPCMethod.providerStartLogin]: "request",
  [RPCMethod.providerCancelLogin]: "request",
  [RPCMethod.providerLoginStatus]: "notification",
  [RPCMethod.providerStatusChanged]: "notification",

  [RPCMethod.devContextGet]: "request",
  [RPCMethod.devContextChanged]: "notification",

  [RPCMethod.sessionCreate]: "request",
  [RPCMethod.sessionList]: "request",
  [RPCMethod.sessionActivate]: "request",
  [RPCMethod.sessionCreated]: "notification",
  [RPCMethod.sessionActivated]: "notification",
  [RPCMethod.sessionListChanged]: "notification",
};

const INBOUND_HANDLER_TIMEOUTS: Record<string, number> = {
  [RPCMethod.rpcPing]: 1_000,
  [RPCMethod.agentSubmit]: 1_000,
  [RPCMethod.agentCancel]: 1_000,
  // Manual /compact awaits a full summarization LLM round inline. The Shell
  // side allows 120s (RPCClient.timeout); pad slightly so the dispatcher
  // does not timeout before the Shell does.
  [RPCMethod.agentCompact]: 130_000,
};

const FAST_PATH_METHODS = new Set<string>([
  RPCMethod.rpcPing,
  RPCMethod.agentCancel,
]);

export function directionOf(method: string): Direction {
  const ns = namespaceOf(method);
  return NAMESPACE_DIRECTIONS[ns] ?? "shellToBun";
}

export function splitKindOf(method: string): SplitMethodKind | undefined {
  return SPLIT_METHOD_KINDS[method];
}

export function inboundTimeoutMs(method: string): number {
  return INBOUND_HANDLER_TIMEOUTS[method] ?? DEFAULT_HANDLER_TIMEOUT_MS;
}

export function isFastPathMethod(method: string): boolean {
  return FAST_PATH_METHODS.has(method);
}
