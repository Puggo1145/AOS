import { expect, test } from "bun:test";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { mkdirSync } from "node:fs";
import { PermissionGateway, builtinPermissionPolicyCatalog } from "../src/agent/permissions";
import { RPCMethod, type PermissionRequestApprovalParams } from "../src/rpc/rpc-types";
import { workspaceDir } from "../src/agent/workspace";

interface RequestCall {
  method: string;
  params: PermissionRequestApprovalParams;
  opts?: { signal?: AbortSignal; timeoutMs?: number };
}

interface NotifyCall {
  method: string;
  params: Record<string, unknown>;
}

function createGateway(
  decisions: Array<"allow" | "deny" | Error | object>,
  permissionLevelProvider?: () => "default" | "fullAccess",
) {
  mkdirSync(workspaceDir(), { recursive: true });
  const calls: RequestCall[] = [];
  const notifications: NotifyCall[] = [];
  const dispatcher = {
    async request<R>(method: string, params: object, opts?: { signal?: AbortSignal; timeoutMs?: number }): Promise<R> {
      calls.push({ method, params: params as PermissionRequestApprovalParams, opts });
      const next = decisions.shift() ?? "allow";
      if (next instanceof Error) throw next;
      if (typeof next === "object") return next as R;
      return { decision: next } as R;
    },
    notify(method: string, params: object): void {
      notifications.push({ method, params: params as Record<string, unknown> });
    },
  };
  return {
    gateway: new PermissionGateway(dispatcher, builtinPermissionPolicyCatalog, permissionLevelProvider),
    calls,
    notifications,
  };
}

function createGatewayWithPermissionLevel(
  permissionLevel: "default" | "fullAccess",
  decisions: Array<"allow" | "deny" | Error | object>,
) {
  return createGateway(decisions, () => permissionLevel);
}

function authInput(toolName: string, args: Record<string, unknown>, turnId = "turn_gateway") {
  return {
    sessionId: "sess_gateway",
    turnId,
    toolCallId: `tc_${crypto.randomUUID()}`,
    toolName,
    args,
    signal: new AbortController().signal,
  };
}

test("allow policy returns allowed without requesting Shell approval", async () => {
  const { gateway, calls } = createGateway([]);
  const decision = await gateway.authorize(authInput("read", {
    path: join(workspaceDir(), `gateway-${crypto.randomUUID()}.txt`),
  }));

  expect(decision).toEqual({ kind: "allowed" });
  expect(calls).toHaveLength(0);
});

test("ask policy sends approval request without timeout and allows on user approval", async () => {
  const { gateway, calls } = createGateway(["allow"]);
  const path = join(tmpdir(), `gateway-${crypto.randomUUID()}.txt`);

  const decision = await gateway.authorize(authInput("write", { path, content: "hello" }));

  expect(decision).toEqual({ kind: "allowed" });
  expect(calls).toHaveLength(1);
  expect(calls[0]?.method).toBe(RPCMethod.permissionRequestApproval);
  expect(calls[0]?.opts?.timeoutMs).toBeUndefined();
  expect(calls[0]?.params).toMatchObject({
    toolName: "write",
    title: "Allow file write?",
    risk: "high",
    capabilities: [{ capability: "filesystem.write", action: "Write file", target: path }],
  });
});

test("fullAccess permission level allows ask policies without Shell approval", async () => {
  const { gateway, calls } = createGatewayWithPermissionLevel("fullAccess", ["deny"]);
  const path = join(tmpdir(), `gateway-${crypto.randomUUID()}.txt`);

  const decision = await gateway.authorize(authInput("write", { path, content: "hello" }));

  expect(decision).toEqual({ kind: "allowed" });
  expect(calls).toHaveLength(0);
});

test("fullAccess permission level bypasses policy catalog checks", async () => {
  const dispatcher = {
    async request(): Promise<never> {
      throw new Error("approval should not be requested");
    },
    notify(): void {},
  };
  const gateway = new PermissionGateway(dispatcher, new Map(), () => "fullAccess");

  const decision = await gateway.authorize(authInput("unknown_tool", { value: crypto.randomUUID() }));

  expect(decision).toEqual({ kind: "allowed" });
});

test("user denial returns a non-error permission denial result", async () => {
  const { gateway } = createGateway(["deny"]);
  const path = join(tmpdir(), `gateway-${crypto.randomUUID()}.txt`);

  const decision = await gateway.authorize(authInput("write", { path, content: "hello" }));

  expect(decision).toEqual({
    kind: "denied",
    isError: false,
    message: `Permission denied: user did not allow Write file for ${path}.`,
  });
});

test("approval RPC failure fails loudly instead of becoming a tool result", async () => {
  const { gateway } = createGateway([new Error("approval channel broke")]);
  const path = join(tmpdir(), `gateway-${crypto.randomUUID()}.txt`);

  await expect(gateway.authorize(authInput("write", { path, content: "hello" }))).rejects.toThrow(
    "Permission approval failed: approval channel broke",
  );
});

test("malformed approval decision fails loudly instead of becoming user denial", async () => {
  const { gateway } = createGateway([{ decision: "allowed" }]);
  const path = join(tmpdir(), `gateway-${crypto.randomUUID()}.txt`);

  await expect(gateway.authorize(authInput("write", { path, content: "hello" }))).rejects.toThrow(
    'Permission approval returned invalid decision "allowed"',
  );
});

test("aborted approval notifies Shell to clear pending approval UI", async () => {
  const { gateway, notifications } = createGateway([new Error("cancelled")]);
  const controller = new AbortController();
  controller.abort();
  const input = {
    ...authInput("write", { path: join(tmpdir(), `gateway-${crypto.randomUUID()}.txt`), content: "hello" }),
    signal: controller.signal,
  };

  const decision = await gateway.authorize(input);

  expect(decision).toEqual({ kind: "aborted" });
  expect(notifications).toEqual([
    {
      method: RPCMethod.permissionApprovalCancelled,
      params: {
        sessionId: input.sessionId,
        turnId: input.turnId,
        toolCallId: input.toolCallId,
      },
    },
  ]);
});

test("computer-use turn grant skips subsequent same-turn approval and is not cross-turn", async () => {
  const { gateway, calls } = createGateway(["allow", "allow"]);
  const first = authInput("use_keyboard", {
    windowId: 42,
    event: { kind: "keyPress", key: "a" },
  }, "turn_one");
  const second = authInput("use_mouse", {
    windowId: 42,
    event: { kind: "click", button: "left", point: { x: 1, y: 2 } },
  }, "turn_one");
  const third = authInput("use_mouse", {
    windowId: 42,
    event: { kind: "click", button: "left", point: { x: 1, y: 2 } },
  }, "turn_two");

  expect(await gateway.authorize(first)).toEqual({ kind: "allowed" });
  expect(await gateway.authorize(second)).toEqual({ kind: "allowed" });
  expect(await gateway.authorize(third)).toEqual({ kind: "allowed" });

  expect(calls).toHaveLength(2);
  expect(calls[0]?.params.title).toBe("Allow Computer Use?");
  expect(calls[0]?.params.capabilities[0]?.capability).toBe("computer.actuate");
  expect(calls[1]?.params.turnId).toBe("turn_two");
});

test("clearTurnGrants removes in-memory group grants", async () => {
  const { gateway, calls } = createGateway(["allow", "allow"]);
  const input = authInput("use_keyboard", {
    windowId: 42,
    event: { kind: "keyPress", key: "a" },
  }, "turn_clear");

  expect(await gateway.authorize(input)).toEqual({ kind: "allowed" });
  gateway.clearTurnGrants(input.sessionId, input.turnId);
  expect(await gateway.authorize(input)).toEqual({ kind: "allowed" });

  expect(calls).toHaveLength(2);
});
