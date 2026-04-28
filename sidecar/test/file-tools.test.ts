// Read / write / update tools — round-trip and error-path coverage.

import { test, expect } from "bun:test";
import { mkdtempSync, existsSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createReadTool } from "../src/agent/tools/read";
import { createWriteTool } from "../src/agent/tools/write";
import { createUpdateTool } from "../src/agent/tools/update";
import { ToolUserError, type ToolExecContext } from "../src/agent/tools/types";
import { getDefaultModel, PROVIDER_IDS } from "../src/llm";

function ctx(signal?: AbortSignal): ToolExecContext {
  return {
    sessionId: "sess",
    turnId: "turn",
    toolCallId: "call",
    model: getDefaultModel(PROVIDER_IDS.chatgptPlan),
    signal: signal ?? new AbortController().signal,
  };
}

function tempDir(): string {
  return mkdtempSync(join(tmpdir(), `aos-tools-${Math.random().toString(36).slice(2)}-`));
}

function textOf(result: { content: { type: string; text?: string }[] }): string {
  return (result.content[0] as { text: string }).text;
}

// --- read ---

test("read returns the file contents", async () => {
  const dir = tempDir();
  const path = join(dir, "hello.txt");
  await Bun.write(path, "hello\nworld");
  const r = await createReadTool().execute({ path }, ctx());
  expect(r.isError).toBe(false);
  expect(textOf(r)).toBe("hello\nworld");
  expect(r.details?.returnedLines).toBe(2);
  expect(r.details?.truncated).toBe(false);
});

test("read with limit head-truncates and appends a marker", async () => {
  const dir = tempDir();
  const path = join(dir, "lines.txt");
  await Bun.write(path, "a\nb\nc\nd\ne");
  const r = await createReadTool().execute({ path, limit: 2 }, ctx());
  expect(r.isError).toBe(false);
  const t = textOf(r);
  expect(t.startsWith("a\nb")).toBe(true);
  expect(t).toContain("[truncated:");
  expect(r.details?.truncated).toBe(true);
  expect(r.details?.returnedLines).toBe(2);
});

test("read on a missing file throws ToolUserError (recoverable)", async () => {
  const tool = createReadTool();
  await expect(
    tool.execute({ path: join(tempDir(), "nope.txt") }, ctx()),
  ).rejects.toBeInstanceOf(ToolUserError);
});

test("read rejects a non-positive limit", async () => {
  const dir = tempDir();
  const path = join(dir, "x.txt");
  await Bun.write(path, "x");
  await expect(
    createReadTool().execute({ path, limit: 0 }, ctx()),
  ).rejects.toThrow(/invalid limit/);
});

test("read expands a leading ~ to the user's home directory", async () => {
  // Tool should resolve ~ to $HOME — we verify via the error message
  // surfaced when the resolved path doesn't exist.
  const home = process.env.HOME ?? "";
  await expect(
    createReadTool().execute({ path: "~/__aos_does_not_exist__" }, ctx()),
  ).rejects.toThrow(new RegExp(home.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
});

test("read caps oversized files at the byte budget and reports truncated", async () => {
  // Make the file comfortably larger than the 50 KB cap so we exercise the
  // bounded-IO path. The output must end with a truncation marker and
  // bytesRead must equal the cap, not the file size.
  const dir = tempDir();
  const path = join(dir, "big.txt");
  const big = "x".repeat(120_000);
  await Bun.write(path, big);
  const r = await createReadTool().execute({ path }, ctx());
  expect(r.isError).toBe(false);
  expect(r.details?.truncated).toBe(true);
  expect(r.details?.bytesRead).toBe(50_000);
  const t = textOf(r);
  expect(t).toContain("[truncated: file is 120000 bytes");
});

test("read produces valid UTF-8 when truncating mid multi-byte char", async () => {
  // Build a payload where the byte cap lands in the middle of a 3-byte CJK
  // sequence (U+4E2D `中` = E4 B8 AD). Filler is exactly 49,999 bytes so the
  // cap at 50,000 falls one byte into the multi-byte char. The decoder must
  // drop the partial sequence rather than emit U+FFFD.
  const dir = tempDir();
  const path = join(dir, "utf8.txt");
  const filler = "a".repeat(49_999);
  const payload = filler + "中" + "尾巴".repeat(1000);
  await Bun.write(path, payload);
  const r = await createReadTool().execute({ path }, ctx());
  expect(r.isError).toBe(false);
  const t = textOf(r);
  // Body part before the truncation marker must contain no replacement char.
  const bodyEnd = t.indexOf("\n[truncated:");
  const body = bodyEnd === -1 ? t : t.slice(0, bodyEnd);
  expect(body).not.toContain("�");
  expect(body.startsWith(filler)).toBe(true);
  // The partial `中` byte must have been dropped, not appended as garbage.
  expect(body.length).toBe(filler.length);
});

// --- write ---

test("write creates a new file and reports `Created`", async () => {
  const dir = tempDir();
  const path = join(dir, "nested", "out.txt");
  const r = await createWriteTool().execute({ path, content: "hi" }, ctx());
  expect(r.isError).toBe(false);
  expect(textOf(r)).toContain("Created");
  expect(readFileSync(path, "utf-8")).toBe("hi");
  expect(r.details?.created).toBe(true);
  expect(r.details?.bytesWritten).toBe(2);
});

test("write overwrites an existing file and reports `Overwrote`", async () => {
  const dir = tempDir();
  const path = join(dir, "out.txt");
  await Bun.write(path, "old");
  const r = await createWriteTool().execute({ path, content: "new content" }, ctx());
  expect(r.isError).toBe(false);
  expect(textOf(r)).toContain("Overwrote");
  expect(readFileSync(path, "utf-8")).toBe("new content");
  expect(r.details?.created).toBe(false);
});

test("write refuses to run when already aborted and does not create the file", async () => {
  const dir = tempDir();
  const path = join(dir, "out.txt");
  const ac = new AbortController();
  ac.abort();
  await expect(
    createWriteTool().execute({ path, content: "hi" }, ctx(ac.signal)),
  ).rejects.toBeInstanceOf(ToolUserError);
  expect(existsSync(path)).toBe(false);
});

// --- update ---

test("update replaces a unique occurrence of old_text", async () => {
  const dir = tempDir();
  const path = join(dir, "src.txt");
  await Bun.write(path, "alpha beta gamma");
  const r = await createUpdateTool().execute(
    { path, old_text: "beta", new_text: "BETA" },
    ctx(),
  );
  expect(r.isError).toBe(false);
  expect(readFileSync(path, "utf-8")).toBe("alpha BETA gamma");
});

test("update rejects ambiguous old_text and leaves the file untouched", async () => {
  const dir = tempDir();
  const path = join(dir, "src.txt");
  await Bun.write(path, "x x x");
  await expect(
    createUpdateTool().execute({ path, old_text: "x", new_text: "Y" }, ctx()),
  ).rejects.toThrow(/matched 3 times/);
  expect(readFileSync(path, "utf-8")).toBe("x x x");
});

test("update throws when old_text is missing and leaves the file untouched", async () => {
  const dir = tempDir();
  const path = join(dir, "src.txt");
  await Bun.write(path, "alpha");
  await expect(
    createUpdateTool().execute({ path, old_text: "missing", new_text: "x" }, ctx()),
  ).rejects.toThrow(/not found/);
  expect(readFileSync(path, "utf-8")).toBe("alpha");
});

test("update rejects empty old_text", async () => {
  const dir = tempDir();
  const path = join(dir, "src.txt");
  await Bun.write(path, "alpha");
  await expect(
    createUpdateTool().execute({ path, old_text: "", new_text: "x" }, ctx()),
  ).rejects.toThrow(/non-empty/);
});

test("update on a missing file throws and does not create it", async () => {
  const path = join(tempDir(), "nope.txt");
  await expect(
    createUpdateTool().execute({ path, old_text: "a", new_text: "b" }, ctx()),
  ).rejects.toBeInstanceOf(ToolUserError);
  expect(existsSync(path)).toBe(false);
});
