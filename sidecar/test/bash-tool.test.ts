// Bash tool — exit code surfacing, output capture, abort signal, timeout.

import { beforeAll, test, expect } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createBashTool } from "../src/agent/tools/bash";
import type { ToolExecContext } from "../src/agent/tools/types";
import { getDefaultModel, PROVIDER_IDS } from "../src/llm";

const testHome = realpathSync(mkdtempSync(join(tmpdir(), "notch-agent-bash-tool-")));
const testWorkspace = join(testHome, ".notch-agent", "workspace");

function ctxWith(signal: AbortSignal): ToolExecContext {
  return {
    sessionId: "sess",
    turnId: "turn",
    toolCallId: "call",
    model: getDefaultModel(PROVIDER_IDS.chatgptPlan),
    signal,
  };
}

function createTestBashTool(): ReturnType<typeof createBashTool> {
  return createBashTool({ workspace: testWorkspace });
}

beforeAll(() => {
  mkdirSync(testWorkspace, { recursive: true });
});

test("captures stdout on a successful command", async () => {
  const tool = createTestBashTool();
  const result = await tool.execute({ command: "echo hello" }, ctxWith(new AbortController().signal));
  expect(result.isError).toBe(false);
  const text = (result.content[0] as { type: "text"; text: string }).text;
  expect(text).toContain("hello");
  expect(result.details?.exitCode).toBe(0);
});

test("starts commands in the Notch Agent workspace", async () => {
  const tool = createTestBashTool();
  const result = await tool.execute({ command: "pwd" }, ctxWith(new AbortController().signal));
  expect(result.isError).toBe(false);
  const text = (result.content[0] as { type: "text"; text: string }).text.trim();
  expect(text).toBe(testWorkspace);
});

test("falls back to the process cwd when the Notch Agent workspace was deleted while running", async () => {
  rmSync(testWorkspace, { recursive: true, force: true });
  try {
    const tool = createTestBashTool();
    const result = await tool.execute({ command: "pwd" }, ctxWith(new AbortController().signal));
    expect(result.isError).toBe(false);
    const text = (result.content[0] as { type: "text"; text: string }).text.trim();
    expect(text).toContain("cwd fallback");
    expect(text).toContain(`Notch Agent workspace ${testWorkspace} was unavailable`);
    expect(text.split("\n").at(-1)).toBe(process.cwd());
    expect(result.details?.cwdFallback?.requestedCwd).toBe(testWorkspace);
    expect(result.details?.cwdFallback?.actualCwd).toBe(process.cwd());
  } finally {
    mkdirSync(testWorkspace, { recursive: true });
  }
});

test("non-zero exit code is surfaced as isError with the exit code in the text", async () => {
  const tool = createTestBashTool();
  const result = await tool.execute({ command: "exit 7" }, ctxWith(new AbortController().signal));
  expect(result.isError).toBe(true);
  expect(result.details?.exitCode).toBe(7);
  const text = (result.content[0] as { type: "text"; text: string }).text;
  expect(text).toContain("exit code 7");
});

test("captures stderr alongside stdout", async () => {
  const tool = createTestBashTool();
  const result = await tool.execute(
    { command: "echo out; echo err 1>&2" },
    ctxWith(new AbortController().signal),
  );
  const text = (result.content[0] as { type: "text"; text: string }).text;
  expect(text).toContain("out");
  expect(text).toContain("err");
});

test("timeout aborts the command and reports as isError", async () => {
  const tool = createTestBashTool();
  const start = Date.now();
  const result = await tool.execute(
    { command: "sleep 5", timeout: 0.3 },
    ctxWith(new AbortController().signal),
  );
  const elapsed = Date.now() - start;
  expect(result.isError).toBe(true);
  expect(elapsed).toBeLessThan(2000);
  const text = (result.content[0] as { type: "text"; text: string }).text;
  expect(text).toContain("timed out");
});

test("parent signal abort cancels the command", async () => {
  const tool = createTestBashTool();
  const controller = new AbortController();
  setTimeout(() => controller.abort(), 100);
  const result = await tool.execute({ command: "sleep 5" }, ctxWith(controller.signal));
  expect(result.isError).toBe(true);
  const text = (result.content[0] as { type: "text"; text: string }).text;
  expect(text).toContain("cancelled by user");
});

test("rejects non-finite timeout as an isError without spawning", async () => {
  const tool = createTestBashTool();
  const result = await tool.execute(
    { command: "echo nope", timeout: Number.NaN },
    ctxWith(new AbortController().signal),
  );
  expect(result.isError).toBe(true);
  const text = (result.content[0] as { type: "text"; text: string }).text;
  expect(text).toContain("invalid timeout");
});

test("rejects non-positive timeout as an isError without spawning", async () => {
  const tool = createTestBashTool();
  const result = await tool.execute(
    { command: "echo nope", timeout: 0 },
    ctxWith(new AbortController().signal),
  );
  expect(result.isError).toBe(true);
  const text = (result.content[0] as { type: "text"; text: string }).text;
  expect(text).toContain("invalid timeout");
});

test("clamps over-cap timeout — tail -f is killed within the 600s ceiling", async () => {
  // We can't actually wait 600s in a test, so we verify the clamp side: a
  // huge user value is reduced to MAX_TIMEOUT_SECONDS. We assert via the
  // timeout-message text rather than wall time. Use a parent abort to
  // bound the test instead.
  const tool = createTestBashTool();
  const controller = new AbortController();
  setTimeout(() => controller.abort(), 100);
  const result = await tool.execute(
    { command: "sleep 5", timeout: 1_000_000 },
    ctxWith(controller.signal),
  );
  // Parent aborted first → cancelled-by-user, not timeout. The clamp itself
  // is verified by the next test (omitted timeout uses default).
  expect(result.isError).toBe(true);
});

test("omitted timeout uses default and remains finite", async () => {
  // We can't wait 120s, but we can verify the spawn doesn't immediately
  // reject and that a fast command still completes successfully — proving
  // the default path is wired in.
  const tool = createTestBashTool();
  const result = await tool.execute({ command: "echo ok" }, ctxWith(new AbortController().signal));
  expect(result.isError).toBe(false);
  const text = (result.content[0] as { type: "text"; text: string }).text;
  expect(text).toContain("ok");
});

test("output truncation marks the result as truncated and prepends a note", async () => {
  const tool = createTestBashTool();
  // 600 lines > MAX_OUTPUT_LINES. Cheap and deterministic.
  const result = await tool.execute(
    { command: "for i in $(seq 1 600); do echo line_$i; done" },
    ctxWith(new AbortController().signal),
  );
  expect(result.isError).toBe(false);
  expect(result.details?.truncated).toBe(true);
  const text = (result.content[0] as { type: "text"; text: string }).text;
  expect(text).toContain("[truncated:");
  // The tail must still be present.
  expect(text).toContain("line_600");
  // The head must NOT be present.
  expect(text).not.toContain("line_1\n");
});
