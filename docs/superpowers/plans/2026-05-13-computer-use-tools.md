# Computer Use Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose the approved `ComputerUseCore` business API surface to the sidecar agent as exactly eight tools.

**Architecture:** Shell owns live macOS Computer Use execution and answers `computerUse.*` JSON-RPC requests. Sidecar tools are thin RPC clients that present agent-friendly JSON schemas and return the Shell result without hidden fallback logic. Swift `Codable` structs remain the wire schema source of truth, with TypeScript mirrors updated manually.

**Tech Stack:** SwiftPM, Swift `Codable`, Bun/TypeScript, JSON-RPC 2.0 over stdio, Bun tests, Swift Testing.

---

### Task 1: Lock Tool Names and RPC Calls

**Files:**
- Create: `sidecar/test/computer-use-tools.test.ts`
- Modify: `sidecar/src/agent/tools/builtins/register.ts`
- Create: `sidecar/src/agent/tools/builtins/computer-use.ts`

- [ ] **Step 1: Write failing tests**

Create `sidecar/test/computer-use-tools.test.ts` that imports a `registerComputerUseTools` function, registers tools into a fresh `ToolRegistry`, and asserts the names are exactly:

```ts
[
  "list_apps",
  "list_windows",
  "get_app_state",
  "start_app_session",
  "stop_app_session",
  "use_mouse",
  "use_keyboard",
  "perform_AX_action",
]
```

Add one execution test that invokes `use_mouse` and verifies it calls dispatcher method `computerUse.postMouseEvent` with the same args.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd sidecar && bun test test/computer-use-tools.test.ts`

Expected: FAIL because `computer-use.ts` does not exist.

- [ ] **Step 3: Implement minimal TS tool registration**

Create `sidecar/src/agent/tools/builtins/computer-use.ts` with `createComputerUseTools(dispatcher)` and `registerComputerUseTools(registry, dispatcher)`. Each tool validates through the shared zod tool schema layer and calls one `RPCMethod.computerUse*` constant.

- [ ] **Step 4: Register builtins**

Modify `registerBuiltinTools` to accept an optional dispatcher or add a separate call from `index.ts` after the dispatcher is constructed. Use the separate call so computer-use tools get the live dispatcher dependency explicitly.

- [ ] **Step 5: Run focused Bun test**

Run: `cd sidecar && bun test test/computer-use-tools.test.ts`

Expected: PASS.

### Task 2: Add Wire Schema

**Files:**
- Create: `Sources/RPCSchema/ComputerUse.swift`
- Modify: `Sources/RPCSchema/Messages.swift`
- Modify: `sidecar/src/rpc/rpc-types.ts`
- Modify: `sidecar/src/rpc/method-catalog.ts`

- [ ] **Step 1: Write failing schema/direction tests**

Add Bun assertions that `RPCMethod.computerUseListApps === "computerUse.listApps"` and the dispatcher allows Bun outbound requests for `computerUse.*`.

- [ ] **Step 2: Run tests to verify failure**

Run: `cd sidecar && bun test test/computer-use-tools.test.ts test/dispatcher.test.ts`

Expected: FAIL because constants and namespace direction are missing.

- [ ] **Step 3: Add Swift and TS DTOs**

Define params/results for the eight methods and value DTOs for apps, windows, screenshots, mouse events, keyboard events, and AX element events. Use discriminated unions with `kind` fields for events.

- [ ] **Step 4: Add method constants and direction**

Add Swift and TS `RPCMethod` constants for `computerUse.listApps`, `computerUse.listWindows`, `computerUse.getAppState`, `computerUse.startAppSession`, `computerUse.stopAppSession`, `computerUse.postMouseEvent`, `computerUse.postKeyboardEvent`, and `computerUse.postEventToAXElement`. Add namespace direction `computerUse: "bunToShell"` in `method-catalog.ts`.

### Task 3: Shell RPC Service

**Files:**
- Create: `Sources/Shell/Agent/ComputerUseRPCService.swift`
- Modify: `Sources/Shell/App/CompositionRoot.swift`
- Create: `Tests/ShellTests/ComputerUseRPCServiceTests.swift`

- [ ] **Step 1: Write failing Swift mapping tests**

Create tests with a fake `ShellComputerUseClient` that records calls. Verify `handleListApps`, `handleUseMouse`, and `handlePerformAXAction` map wire params into the expected core calls.

- [ ] **Step 2: Run test to verify failure**

Run: `swift test --filter ComputerUseRPCServiceTests`

Expected: FAIL because `ComputerUseRPCService` does not exist.

- [ ] **Step 3: Implement service**

Add a Shell-local protocol mirroring the eight core methods. Extend `ComputerUseCore` to conform. Register all eight `computerUse.*` request handlers on `RPCClient`.

- [ ] **Step 4: Wire composition**

Instantiate `ComputerUseRPCService(rpc: client, core: computerUseCore)` in `CompositionRoot.start()` after `RPCClient` creation and retain it.

### Task 4: Verify End to End Build

**Files:**
- All files touched above.

- [ ] **Step 1: Run focused tests**

Run:

```bash
swift test --filter ComputerUseRPCServiceTests
cd sidecar && bun test test/computer-use-tools.test.ts
```

Expected: PASS.

- [ ] **Step 2: Run schema and registry tests**

Run:

```bash
swift test --filter RPCSchemaTests
cd sidecar && bun test test/tool-registry.test.ts test/dispatcher.test.ts
```

Expected: PASS.

- [ ] **Step 3: Run type checks via tests**

Run:

```bash
cd sidecar && bun test
swift test
```

Expected: PASS or report unrelated environment/macOS permission blockers explicitly.
