import { expect, test } from "bun:test";
import { homedir } from "node:os";
import { resolve } from "node:path";
import {
  FILE_TOOL_PATH_PARAMETER_DESCRIPTION,
  FILE_TOOL_PATH_POLICY_TEXT,
  resolveFileToolPath,
} from "../src/agent/tools/builtins/files/path-policy";

test("file tool path policy resolves absolute paths without changing their root", () => {
  expect(resolveFileToolPath("/tmp/notch-agent/../path-policy.txt")).toBe(
    resolve("/tmp/notch-agent/../path-policy.txt"),
  );
});

test("file tool path policy resolves relative paths against the sidecar cwd", () => {
  expect(resolveFileToolPath("notes/today.md")).toBe(resolve("notes/today.md"));
});

test("file tool path policy expands home-directory paths", () => {
  expect(resolveFileToolPath("~")).toBe(resolve(homedir()));
  expect(resolveFileToolPath("~/notes/today.md")).toBe(resolve(homedir(), "notes/today.md"));
});

test("file tool path policy does not expand non-home tilde prefixes", () => {
  expect(resolveFileToolPath("~not-home/file.txt")).toBe(resolve("~not-home/file.txt"));
});

test("file tool path policy text describes only the tilde forms it expands", () => {
  expect(FILE_TOOL_PATH_POLICY_TEXT).toContain("bare `~` or `~/...`");
  expect(FILE_TOOL_PATH_PARAMETER_DESCRIPTION).toContain("bare `~` or `~/...`");
  expect(FILE_TOOL_PATH_POLICY_TEXT).not.toContain("starting with `~`");
  expect(FILE_TOOL_PATH_PARAMETER_DESCRIPTION).not.toContain("starting with `~`");
});
