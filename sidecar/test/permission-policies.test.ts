import { expect, test } from "bun:test";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { mkdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import {
  assertRegisteredToolsMatchPermissionPolicies,
  builtinPermissionPolicyCatalog,
  evaluatePermissionPolicy,
  isPathWithinRoot,
} from "../src/agent/permissions";
import { workspaceDir } from "../src/agent/workspace";

const baseContext = {
  sessionId: "sess_policy",
  turnId: "turn_policy",
  toolCallId: "tc_policy",
};

function evaluate(toolName: string, args: Record<string, unknown>) {
  return evaluatePermissionPolicy(
    builtinPermissionPolicyCatalog.get(toolName)!,
    { ...baseContext, toolName, args },
  );
}

test("permission catalog must exactly match registered internal tools", () => {
  const registered = [
    "bash",
    "read",
    "write",
    "update",
    "list_apps",
    "list_windows",
    "get_app_state",
    "start_app_session",
    "stop_app_session",
    "use_mouse",
    "use_keyboard",
    "perform_AX_action",
    "todo_write",
  ].map((name) => ({ spec: { name } }));

  expect(() => assertRegisteredToolsMatchPermissionPolicies(registered, builtinPermissionPolicyCatalog)).not.toThrow();

  const missingRead = new Map(builtinPermissionPolicyCatalog);
  missingRead.delete("read");
  expect(() => assertRegisteredToolsMatchPermissionPolicies(registered, missingRead)).toThrow(
    'missing permission policy for registered tool(s): read',
  );

  const stalePolicy = new Map(builtinPermissionPolicyCatalog);
  stalePolicy.set("stale_tool", stalePolicy.get("read")!);
  expect(() => assertRegisteredToolsMatchPermissionPolicies(registered, stalePolicy)).toThrow(
    'permission policy registered for unknown tool(s): stale_tool',
  );
});

test("filesystem policies allow workspace paths and ask for every other path", () => {
  mkdirSync(workspaceDir(), { recursive: true });
  const workspaceFile = join(workspaceDir(), `policy-${crypto.randomUUID()}.txt`);
  const outsideFile = join(tmpdir(), `policy-${crypto.randomUUID()}.txt`);

  expect(evaluate("read", { path: workspaceFile })).toMatchObject({
    behavior: "allow",
    capabilities: [{ capability: "filesystem.read", action: "Read file", target: workspaceFile }],
  });
  expect(evaluate("write", { path: workspaceFile, content: "hello" })).toMatchObject({
    behavior: "allow",
    capabilities: [{ capability: "filesystem.write", action: "Write file", target: workspaceFile }],
  });
  expect(evaluate("update", { path: workspaceFile, old_text: "a", new_text: "b" })).toMatchObject({
    behavior: "allow",
    capabilities: [{ capability: "filesystem.write", action: "Update file", target: workspaceFile }],
  });

  expect(evaluate("read", { path: outsideFile })).toMatchObject({ behavior: "ask", risk: "medium" });
  expect(evaluate("write", { path: outsideFile, content: "hello" })).toMatchObject({ behavior: "ask", risk: "high" });
  expect(evaluate("update", { path: outsideFile, old_text: "a", new_text: "b" })).toMatchObject({
    behavior: "ask",
    risk: "high",
  });
});

test("filesystem policies ask when a workspace symlink escapes the workspace", () => {
  mkdirSync(workspaceDir(), { recursive: true });
  const outsideRoot = join(tmpdir(), `notch-policy-outside-${crypto.randomUUID()}`);
  const linkPath = join(workspaceDir(), `policy-link-${crypto.randomUUID()}`);
  mkdirSync(outsideRoot, { recursive: true });
  symlinkSync(outsideRoot, linkPath, "dir");
  try {
    const existingTarget = join(linkPath, "secret.txt");
    writeFileSync(join(outsideRoot, "secret.txt"), "secret");
    const newTarget = join(linkPath, "new-secret.txt");

    expect(evaluate("read", { path: existingTarget })).toMatchObject({ behavior: "ask", risk: "medium" });
    expect(evaluate("write", { path: existingTarget, content: "hello" })).toMatchObject({
      behavior: "ask",
      risk: "high",
    });
    expect(evaluate("write", { path: newTarget, content: "hello" })).toMatchObject({
      behavior: "ask",
      risk: "high",
    });
  } finally {
    rmSync(linkPath, { force: true });
    rmSync(outsideRoot, { recursive: true, force: true });
  }
});

test("process policy asks for every bash call and includes command context", () => {
  const decision = evaluate("bash", { command: "bun test", timeout: 30 });
  expect(decision).toMatchObject({
    behavior: "ask",
    title: "Allow command?",
    risk: "high",
    capabilities: [
      {
        capability: "process.spawn",
        action: "Run shell command",
        target: "bun test",
        details: { cwd: workspaceDir(), timeoutSeconds: 30 },
      },
    ],
  });
});

test("computer use policies allow read and cleanup but ask for actuating tools with a turn group", () => {
  expect(evaluate("list_apps", { mode: "running" })).toMatchObject({
    behavior: "allow",
    capabilities: [{ capability: "computer.read" }],
  });
  expect(evaluate("list_windows", { pid: 123 })).toMatchObject({
    behavior: "allow",
    capabilities: [{ capability: "computer.read" }],
  });
  expect(evaluate("get_app_state", { windowId: 42, captureMode: "ax" })).toMatchObject({
    behavior: "allow",
    capabilities: [{ capability: "computer.read" }],
  });
  expect(evaluate("stop_app_session", {})).toMatchObject({
    behavior: "allow",
    capabilities: [{ capability: "computer.cleanup" }],
  });

  const decision = evaluate("use_keyboard", {
    windowId: 42,
    event: { kind: "keyPress", key: "a" },
  });
  expect(decision).toMatchObject({
    behavior: "ask",
    title: "Allow Computer Use?",
    risk: "high",
    groupId: "computer-use",
    groupGrantScope: "turn",
    capabilities: [{ capability: "computer.actuate", action: "Use keyboard", target: "window 42" }],
  });
});

test("todo_write declares no external permission and resolves allow", () => {
  expect(evaluate("todo_write", { items: [] })).toMatchObject({
    behavior: "allow",
    capabilities: [],
  });
});

test("path containment uses path boundaries instead of string prefixes", () => {
  const root = join(tmpdir(), `root-${crypto.randomUUID()}`);
  expect(isPathWithinRoot(join(root, "child.txt"), root)).toBe(true);
  expect(isPathWithinRoot(`${root}-sibling/child.txt`, root)).toBe(false);
});
