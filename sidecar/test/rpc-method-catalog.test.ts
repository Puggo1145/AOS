// RPC Method Catalog contract tests.
//
// The catalog is the Sidecar-local routing source of truth. These tests pin
// method semantics in one place so adding an RPC method cannot silently omit
// request/notification kind, direction, timeout, or fast-path metadata.

import { test, expect } from "bun:test";
import { RPCMethod } from "../src/rpc/rpc-types";
import {
  DEFAULT_INBOUND_HANDLER_TIMEOUT_MS,
  allRpcMethodSemantics,
  rpcMethodSemantics,
} from "../src/rpc/method-catalog";

const allMethodConstants = Object.values(RPCMethod).sort();

test("catalog has one complete semantic entry for every RPC method constant", () => {
  const semantics = allRpcMethodSemantics();

  expect(semantics.map((entry) => entry.method).sort()).toEqual(allMethodConstants);
  for (const entry of semantics) {
    expect(entry.namespace).toBe(entry.method.slice(0, entry.method.indexOf(".")));
    expect(entry.kind === "request" || entry.kind === "notification").toBe(true);
    expect(entry.direction === "shellToBun" || entry.direction === "bunToShell" || entry.direction === "both").toBe(
      true,
    );
    expect(entry.inboundTimeoutMs).toBeGreaterThan(0);
    expect(typeof entry.fastPath).toBe("boolean");
  }
});

test("method-level semantics distinguish request and notification routes inside mixed namespaces", () => {
  expect(rpcMethodSemantics(RPCMethod.providerSetApiKey)).toMatchObject({
    direction: "shellToBun",
    kind: "request",
  });
  expect(rpcMethodSemantics(RPCMethod.providerStatusChanged)).toMatchObject({
    direction: "bunToShell",
    kind: "notification",
  });
  expect(rpcMethodSemantics(RPCMethod.sessionActivate)).toMatchObject({
    direction: "shellToBun",
    kind: "request",
  });
  expect(rpcMethodSemantics(RPCMethod.sessionActivated)).toMatchObject({
    direction: "bunToShell",
    kind: "notification",
  });
  expect(rpcMethodSemantics(RPCMethod.devContextGet)).toMatchObject({
    direction: "shellToBun",
    kind: "request",
  });
  expect(rpcMethodSemantics(RPCMethod.devContextChanged)).toMatchObject({
    direction: "bunToShell",
    kind: "notification",
  });
  expect(rpcMethodSemantics(RPCMethod.permissionRequestApproval)).toMatchObject({
    direction: "bunToShell",
    kind: "request",
  });
  expect(rpcMethodSemantics(RPCMethod.permissionApprovalCancelled)).toMatchObject({
    direction: "bunToShell",
    kind: "notification",
  });
});

test("timeout and fast-path metadata live on the same method semantic entries", () => {
  expect(rpcMethodSemantics(RPCMethod.rpcPing)).toMatchObject({
    kind: "request",
    direction: "both",
    inboundTimeoutMs: 1_000,
    fastPath: true,
  });
  expect(rpcMethodSemantics(RPCMethod.agentCancel)).toMatchObject({
    kind: "request",
    direction: "shellToBun",
    inboundTimeoutMs: 1_000,
    fastPath: true,
  });
  expect(rpcMethodSemantics(RPCMethod.agentCompact)).toMatchObject({
    kind: "request",
    direction: "shellToBun",
    inboundTimeoutMs: 130_000,
    fastPath: false,
  });
  expect(rpcMethodSemantics(RPCMethod.sessionCreate)).toMatchObject({
    inboundTimeoutMs: DEFAULT_INBOUND_HANDLER_TIMEOUT_MS,
    fastPath: false,
  });
});
