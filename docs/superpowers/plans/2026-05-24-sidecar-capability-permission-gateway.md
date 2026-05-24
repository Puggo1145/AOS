# Sidecar Capability Permission Gateway Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Add a capability-based Permission Gateway that strictly wraps Sidecar agent tool effects before execution.

**Architecture:** The Gateway lives in `sidecar/src/agent/permissions/` and is injected from `index.ts` into the agent runtime. Tool Core remains unchanged: permissions are an independent `toolName -> policy` catalog checked against registered internal tools at startup. The Gateway authorizes validated tool calls before execution, asks Shell through a Bun→Shell approval request when needed, and keeps turn-scoped Computer Use grants in memory only.

**Tech Stack:** Bun, TypeScript, JSON-RPC 2.0 over stdio, existing sidecar tool registry, Bun test runner.

---

## File Structure

- Create `sidecar/src/agent/permissions/types.ts`: permission decision, policy, approval payload, capability, and group types.
- Create `sidecar/src/agent/permissions/path.ts`: pure path helpers for workspace containment.
- Create `sidecar/src/agent/permissions/policies.ts`: built-in `toolName -> PermissionPolicy` catalog and coverage assertion.
- Create `sidecar/src/agent/permissions/gateway.ts`: `PermissionGateway` with allow/ask flow, Shell approval request, in-memory turn group grants, and turn cleanup.
- Create `sidecar/src/agent/permissions/index.ts`: public exports.
- Modify `sidecar/src/rpc/rpc-types.ts`: add `permission.requestApproval` wire method, payload/result types, `awaitingPermission`, and `permissionDenied` tool phase.
- Modify `sidecar/src/rpc/method-catalog.ts`: register `permission.requestApproval` as Bun→Shell request.
- Modify `sidecar/src/index.ts`: instantiate Gateway, assert internal permission catalog coverage after built-in tool registration, inject Gateway into agent handlers.
- Modify `sidecar/src/agent/loop.ts`: accept injected Gateway and clear turn grants when a turn exits.
- Modify `sidecar/src/agent/turn/round.ts`: authorize validated tool calls before `runTool`, publish `awaitingPermission`, handle `permissionDenied` terminal tool phase, and append permission tool results.
- Add/modify sidecar tests for RPC schema, policy coverage, Gateway decisions, and agent tool-loop behavior.

## Tasks

### Task 1: RPC Wire Contract

**Files:**
- Modify: `sidecar/src/rpc/rpc-types.ts`
- Modify: `sidecar/src/rpc/method-catalog.ts`
- Test: `sidecar/test/rpc-roundtrip.test.ts`
- Test: `sidecar/test/rpc-method-catalog.test.ts`

- [x] **Step 1: Write failing RPC tests**

Add tests asserting:

```ts
RPCMethod.permissionRequestApproval === "permission.requestApproval";
rpcMethodSemantics(RPCMethod.permissionRequestApproval) matches {
  direction: "bunToShell",
  kind: "request",
};
UIStatus accepts "awaitingPermission";
UIToolCallParams accepts phase "permissionDenied";
```

- [x] **Step 2: Run failing tests**

Run: `cd sidecar && bun test test/rpc-roundtrip.test.ts test/rpc-method-catalog.test.ts`

Expected: fail because the RPC method, status, and phase do not exist.

- [x] **Step 3: Implement wire types**

Add:

```ts
permissionRequestApproval: "permission.requestApproval"
```

Add:

```ts
export interface PermissionCapabilityView {
  capability: string;
  action: string;
  target?: string;
  details?: JSONValue;
}

export interface PermissionRequestApprovalParams {
  sessionId: string;
  turnId: string;
  toolCallId: string;
  toolName: string;
  title: string;
  message: string;
  risk: "low" | "medium" | "high";
  capabilities: PermissionCapabilityView[];
}

export interface PermissionRequestApprovalResult {
  decision: "allow" | "deny";
}
```

Extend:

```ts
export type UIStatus = "working" | "waiting" | "awaitingPermission" | "done";
```

Add `UIToolCallParams` variant:

```ts
{
  sessionId: string;
  turnId: string;
  phase: "permissionDenied";
  toolCallId: string;
  toolName: string;
  args: JSONValue;
  errorMessage: string;
}
```

- [x] **Step 4: Register method catalog entry**

Register `permission.requestApproval` as Bun→Shell request. Do not add an outbound timeout; `Dispatcher.request()` already defaults to no timeout unless `timeoutMs` is passed.

- [x] **Step 5: Verify**

Run: `cd sidecar && bun test test/rpc-roundtrip.test.ts test/rpc-method-catalog.test.ts`

Expected: pass.

### Task 2: Permission Policy Catalog

**Files:**
- Create: `sidecar/src/agent/permissions/types.ts`
- Create: `sidecar/src/agent/permissions/path.ts`
- Create: `sidecar/src/agent/permissions/policies.ts`
- Create: `sidecar/src/agent/permissions/index.ts`
- Test: `sidecar/test/permission-policies.test.ts`

- [x] **Step 1: Write failing policy tests**

Cover:

```ts
assertRegisteredToolsMatchPermissionPolicies(["read"], catalogWithoutRead) throws missing policy;
assertRegisteredToolsMatchPermissionPolicies(["read"], catalogWithReadAndStaleWrite) throws stale policy;
read/write/update inside workspace resolve allow;
read/write/update outside workspace resolve ask;
bash resolves ask;
computer read tools resolve allow;
computer actuate tools resolve ask with groupId "computer-use";
stop_app_session resolves allow;
todo_write resolves allow via permission kind "none";
```

- [x] **Step 2: Run failing policy tests**

Run: `cd sidecar && bun test test/permission-policies.test.ts`

Expected: fail because module does not exist.

- [x] **Step 3: Implement types and helpers**

Implement:

```ts
type CapabilityId =
  | "filesystem.read"
  | "filesystem.write"
  | "process.spawn"
  | "computer.read"
  | "computer.actuate"
  | "computer.cleanup";
type PermissionGroupId = "computer-use";
type PermissionRisk = "low" | "medium" | "high";
type PermissionDecision = "allow" | "ask";
```

Path helpers must use `resolveFileToolPath()` and `workspaceDir()`, and containment must use `path.relative`, not string prefix.

- [x] **Step 4: Implement built-in policy catalog**

Map:

```text
read -> filesystem.read
write -> filesystem.write
update -> filesystem.write
bash -> process.spawn
list_apps/list_windows/get_app_state -> computer.read
start_app_session/use_mouse/use_keyboard/perform_AX_action -> computer.actuate, group computer-use
stop_app_session -> computer.cleanup
todo_write -> none
```

Filesystem policy:

```text
inside ~/.notch-agent/workspace -> allow
outside -> ask
```

- [x] **Step 5: Verify**

Run: `cd sidecar && bun test test/permission-policies.test.ts`

Expected: pass.

### Task 3: Permission Gateway

**Files:**
- Create: `sidecar/src/agent/permissions/gateway.ts`
- Modify: `sidecar/src/agent/permissions/index.ts`
- Test: `sidecar/test/permission-gateway.test.ts`

- [x] **Step 1: Write failing Gateway tests**

Cover:

```ts
allow policy returns allowed without Shell approval request;
ask policy sends permission.requestApproval without timeoutMs;
user deny returns denied with isError=false result text;
approval RPC failure returns error result and does not allow execution;
computer-use allow records same-turn group grant;
same session+turn+group skips second approval;
next turn asks again;
clearTurnGrants removes grants.
```

- [x] **Step 2: Run failing Gateway tests**

Run: `cd sidecar && bun test test/permission-gateway.test.ts`

Expected: fail because Gateway does not exist.

- [x] **Step 3: Implement Gateway**

`PermissionGateway.authorize()` receives already validated args:

```ts
{
  sessionId,
  turnId,
  toolCallId,
  toolName,
  args,
  signal,
}
```

It returns:

```ts
{ kind: "allowed" }
{ kind: "denied"; message: string; isError: false }
{ kind: "failed"; message: string; isError: true }
```

For `ask`, call:

```ts
dispatcher.request(RPCMethod.permissionRequestApproval, approvalPayload, { signal })
```

Do not pass `timeoutMs`.

- [x] **Step 4: Verify**

Run: `cd sidecar && bun test test/permission-gateway.test.ts`

Expected: pass.

### Task 4: Agent Runtime Integration

**Files:**
- Modify: `sidecar/src/index.ts`
- Modify: `sidecar/src/agent/loop.ts`
- Modify: `sidecar/src/agent/turn/round.ts`
- Test: `sidecar/test/agent-tool-loop.test.ts`
- Test: `sidecar/test/computer-use-tools.test.ts`

- [x] **Step 1: Write failing integration tests**

Add tests proving:

```ts
workspace write executes without approval;
outside-workspace write asks, user deny does not run handler, emits permissionDenied, appends ToolResult isError=false;
bash asks before execution;
approval failure appends ToolResult isError=true;
computer.read tool executes without approval;
first computer.actuate approval allows later same-turn computer.actuate call without second approval;
next turn asks computer.actuate again;
pending approval aborted by turn cancel does not create permissionDenied tool result.
```

- [x] **Step 2: Run failing integration tests**

Run: `cd sidecar && bun test test/agent-tool-loop.test.ts test/computer-use-tools.test.ts`

Expected: fail because runtime does not call Gateway.

- [x] **Step 3: Inject Gateway**

`index.ts` creates:

```ts
const permissionGateway = new PermissionGateway(dispatcher, builtinPermissionPolicyCatalog);
assertRegisteredToolsMatchPermissionPolicies(toolRegistry.list(), builtinPermissionPolicyCatalog);
registerAgentHandlers(dispatcher, { manager: sessions, permissionGateway });
```

- [x] **Step 4: Authorize before runTool**

In `AgentRoundRunner`, after `prepareToolCall()` succeeds and before `runTool()`:

```text
authorize -> allowed -> runTool
authorize -> denied -> ui.toolCall permissionDenied + append ToolResult isError=false
authorize -> failed -> append ToolResult isError=true
```

Send `ui.status awaitingPermission` only while an approval request is pending, then return to `waiting`.

- [x] **Step 5: Clear turn grants**

When `runTurn` exits, call:

```ts
permissionGateway.clearTurnGrants(session.id, turnId)
```

- [x] **Step 6: Verify**

Run: `cd sidecar && bun test test/agent-tool-loop.test.ts test/computer-use-tools.test.ts`

Expected: pass.

### Task 5: Final Verification

**Files:**
- `sidecar/package.json`

- [x] **Step 1: Run focused test set**

Run:

```sh
cd sidecar && bun test \
  test/permission-policies.test.ts \
  test/permission-gateway.test.ts \
  test/rpc-method-catalog.test.ts \
  test/rpc-roundtrip.test.ts \
  test/agent-tool-loop.test.ts \
  test/computer-use-tools.test.ts
```

Expected: pass.

- [x] **Step 2: Run sidecar typecheck**

Run: `cd sidecar && bun run typecheck`

Expected: pass.

- [x] **Step 3: Run all sidecar tests if time permits**

Run: `cd sidecar && bun test`

Expected: pass or report unrelated failures explicitly.

## Self-Review

- Spec coverage: The plan covers Gateway scope, tool-name policy catalog, startup strict matching, filesystem/bash/computer policies, approval request with no timeout, turn-scoped in-memory Computer Use grants, UI/conversation semantics, cancellation, and tests.
- Placeholder scan: No `TBD`, `TODO`, or open-ended “add tests” placeholders remain.
- Type consistency: `permission.requestApproval`, `awaitingPermission`, `permissionDenied`, `computer-use`, and capability ids are named consistently across tasks.
