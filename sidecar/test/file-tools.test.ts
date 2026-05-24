// Read / write / update tools — round-trip and error-path coverage.

import { test, expect } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join, relative } from "node:path";
import { createReadTool } from "../src/agent/tools/builtins/files/read";
import { createWriteTool } from "../src/agent/tools/builtins/files/write";
import { createUpdateTool } from "../src/agent/tools/builtins/files/update";
import { ToolUserError, type ToolExecContext } from "../src/agent/tools/core/types";
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
  return mkdtempSync(join(tmpdir(), `notch-agent-tools-${Math.random().toString(36).slice(2)}-`));
}

function textOf(result: { content: { type: string; text?: string }[] }): string {
  return (result.content[0] as { text: string }).text;
}

async function withHomeTemp<T>(run: (fixture: { root: string; tildePath: (path: string) => string }) => Promise<T>): Promise<T> {
  const name = `.notch-agent-file-tools-${Math.random().toString(36).slice(2)}`;
  const root = join(homedir(), name);
  const tildePath = (path: string) => `~/${name}/${path}`;
  try {
    return await run({ root, tildePath });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

// --- read ---

test("read returns the file contents", async () => {
  const dir = tempDir();
  const path = join(dir, "hello.txt");
  await Bun.write(path, "hello\nworld");
  const r = await createReadTool().execute({ path }, ctx());
  expect(r.isError).toBe(false);
  expect(textOf(r)).toBe("1 | hello\n2 | world");
  expect(r.details?.returnedLines).toBe(2);
  expect(r.details?.truncated).toBe(false);
});

test("read defaults to 500 lines from start and appends remaining-line marker", async () => {
  const dir = tempDir();
  const path = join(dir, "lines.txt");
  const content = Array.from({ length: 503 }, (_, i) => `line-${i + 1}`).join("\n");
  await Bun.write(path, content);
  const r = await createReadTool().execute({ path }, ctx());
  expect(r.isError).toBe(false);
  const t = textOf(r);
  expect(t.startsWith("1 | line-1\n2 | line-2")).toBe(true);
  expect(t).toContain("500 | line-500");
  expect(t).not.toContain("501 | line-501");
  expect(t.endsWith("[You still have 3 more lines to read]")).toBe(true);
  expect(r.details?.truncated).toBe(true);
  expect(r.details?.returnedLines).toBe(500);
});

test("read on a missing file throws ToolUserError (recoverable)", async () => {
  const tool = createReadTool();
  await expect(
    tool.execute({ path: join(tempDir(), "nope.txt") }, ctx()),
  ).rejects.toBeInstanceOf(ToolUserError);
});

test("read returns an inclusive start/end range and reports lines after end", async () => {
  const dir = tempDir();
  const path = join(dir, "range.txt");
  await Bun.write(path, "a\nb\nc\nd\ne\nf");
  const r = await createReadTool().execute({ path, start: 3, end: 4 }, ctx());
  expect(r.isError).toBe(false);
  expect(textOf(r)).toBe("3 | c\n4 | d\n[You still have 2 more lines to read]");
  expect(r.details?.returnedLines).toBe(2);
  expect(r.details?.truncated).toBe(true);
});

test("read with start and no end returns 500 lines from start", async () => {
  const dir = tempDir();
  const path = join(dir, "start.txt");
  const content = Array.from({ length: 1002 }, (_, i) => `line-${i + 1}`).join("\n");
  await Bun.write(path, content);
  const r = await createReadTool().execute({ path, start: 501 }, ctx());
  expect(r.isError).toBe(false);
  const t = textOf(r);
  expect(t.startsWith("501 | line-501\n502 | line-502")).toBe(true);
  expect(t).toContain("1000 | line-1000");
  expect(t).not.toContain("1001 | line-1001");
  expect(t.endsWith("[You still have 2 more lines to read]")).toBe(true);
  expect(r.details?.returnedLines).toBe(500);
});

test("read omits remaining-line marker when range reaches EOF", async () => {
  const dir = tempDir();
  const path = join(dir, "whole.txt");
  await Bun.write(path, "a\nb\nc");
  const r = await createReadTool().execute({ path, start: 2, end: 3 }, ctx());
  expect(r.isError).toBe(false);
  expect(textOf(r)).toBe("2 | b\n3 | c");
  expect(r.details?.truncated).toBe(false);
});

test("read reports when start is beyond EOF", async () => {
  const dir = tempDir();
  const path = join(dir, "short.txt");
  await Bun.write(path, "a\nb\nc");
  const r = await createReadTool().execute({ path, start: 10 }, ctx());
  expect(r.isError).toBe(false);
  expect(textOf(r)).toBe("(requested range starts after EOF; file has 3 lines)");
  expect(r.details?.returnedLines).toBe(0);
  expect(r.details?.truncated).toBe(false);
  expect(r.details?.remainingLines).toBe(0);
});

test("read rejects an invalid range", async () => {
  const dir = tempDir();
  const path = join(dir, "x.txt");
  await Bun.write(path, "x");
  await expect(
    createReadTool().execute({ path, start: 2, end: 1 }, ctx()),
  ).rejects.toThrow(/invalid range/);
});

test("read rejects explicit ranges larger than 500 lines", async () => {
  const dir = tempDir();
  const path = join(dir, "x.txt");
  await Bun.write(path, "x");
  await expect(
    createReadTool().execute({ path, start: 1, end: 501 }, ctx()),
  ).rejects.toThrow(/range too large/);
});

test("read expands a leading ~ to the user's home directory", async () => {
  // Tool should resolve ~ to $HOME — we verify via the error message
  // surfaced when the resolved path doesn't exist.
  const home = process.env.HOME ?? "";
  await expect(
    createReadTool().execute({ path: "~/__notch_does_not_exist__" }, ctx()),
  ).rejects.toThrow(new RegExp(home.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
});

test("read resolves relative paths through the shared file path policy", async () => {
  const dir = tempDir();
  const absolutePath = join(dir, "relative-read.txt");
  const relativePath = relative(process.cwd(), absolutePath);
  await Bun.write(absolutePath, "from relative path");

  const r = await createReadTool().execute({ path: relativePath }, ctx());

  expect(r.isError).toBe(false);
  expect(textOf(r)).toBe("1 | from relative path");
  expect(r.details?.resolvedPath).toBe(absolutePath);
});

test("read expands home paths through the shared file path policy", async () => {
  await withHomeTemp(async ({ root, tildePath }) => {
    const path = join(root, "notes", "home-read.txt");
    mkdirSync(join(root, "notes"), { recursive: true });
    await Bun.write(path, "from home path");

    const r = await createReadTool().execute({ path: tildePath("notes/home-read.txt") }, ctx());

    expect(r.isError).toBe(false);
    expect(textOf(r)).toBe("1 | from home path");
    expect(r.details?.resolvedPath).toBe(path);
  });
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

test("write resolves relative paths through the shared file path policy", async () => {
  const dir = tempDir();
  const absolutePath = join(dir, "relative", "write.txt");
  const relativePath = relative(process.cwd(), absolutePath);

  const r = await createWriteTool().execute({ path: relativePath, content: "relative write" }, ctx());

  expect(r.isError).toBe(false);
  expect(readFileSync(absolutePath, "utf-8")).toBe("relative write");
  expect(r.details?.resolvedPath).toBe(absolutePath);
});

test("write expands home paths through the shared file path policy", async () => {
  await withHomeTemp(async ({ root, tildePath }) => {
    const path = join(root, "notes", "home-write.txt");

    const r = await createWriteTool().execute({ path: tildePath("notes/home-write.txt"), content: "home write" }, ctx());

    expect(r.isError).toBe(false);
    expect(readFileSync(path, "utf-8")).toBe("home write");
    expect(r.details?.resolvedPath).toBe(path);
  });
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

test("update resolves relative paths through the shared file path policy", async () => {
  const dir = tempDir();
  const absolutePath = join(dir, "relative-update.txt");
  const relativePath = relative(process.cwd(), absolutePath);
  await Bun.write(absolutePath, "alpha beta");

  const r = await createUpdateTool().execute(
    { path: relativePath, old_text: "beta", new_text: "BETA" },
    ctx(),
  );

  expect(r.isError).toBe(false);
  expect(readFileSync(absolutePath, "utf-8")).toBe("alpha BETA");
  expect(r.details?.resolvedPath).toBe(absolutePath);
});

test("update expands home paths through the shared file path policy", async () => {
  await withHomeTemp(async ({ root, tildePath }) => {
    const path = join(root, "notes", "home-update.txt");
    mkdirSync(join(root, "notes"), { recursive: true });
    await Bun.write(path, "alpha beta");

    const r = await createUpdateTool().execute(
      { path: tildePath("notes/home-update.txt"), old_text: "beta", new_text: "BETA" },
      ctx(),
    );

    expect(r.isError).toBe(false);
    expect(readFileSync(path, "utf-8")).toBe("alpha BETA");
    expect(r.details?.resolvedPath).toBe(path);
  });
});
