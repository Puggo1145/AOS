// readUserConfig fail-fast tests (P2.4).
//
// Missing file ⇒ {} (first-run is a documented default, not a fallback).
// Malformed file ⇒ MalformedConfigError (must reach the user, not silently
// swap their saved selection for the catalog default).

import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readUserConfig, writeUserConfig, MalformedConfigError } from "../src/config/storage";

let originalHome: string | undefined;
let tmpHome: string;

beforeEach(() => {
  originalHome = process.env.HOME;
  tmpHome = mkdtempSync(join(tmpdir(), "aos-config-test-"));
  process.env.HOME = tmpHome;
});

afterEach(() => {
  if (originalHome === undefined) delete process.env.HOME;
  else process.env.HOME = originalHome;
  rmSync(tmpHome, { recursive: true, force: true });
});

function configPath(): string {
  return join(tmpHome, ".aos", "config.json");
}

function writeRaw(content: string): void {
  mkdirSync(join(tmpHome, ".aos"), { recursive: true });
  writeFileSync(configPath(), content, "utf-8");
}

test("missing config file returns empty object (documented first-run path)", () => {
  expect(readUserConfig()).toEqual({});
});

test("malformed JSON throws MalformedConfigError", () => {
  writeRaw("{ this is not valid json");
  expect(() => readUserConfig()).toThrow(MalformedConfigError);
});

test("top-level non-object throws MalformedConfigError", () => {
  writeRaw('"just a string"');
  expect(() => readUserConfig()).toThrow(MalformedConfigError);
});

test("selection with wrong types throws MalformedConfigError", () => {
  writeRaw('{ "selection": { "providerId": 42, "modelId": "gpt-5.5" } }');
  expect(() => readUserConfig()).toThrow(MalformedConfigError);
});

test("effort with unknown enum value throws MalformedConfigError", () => {
  writeRaw('{ "effort": "ludicrous" }');
  expect(() => readUserConfig()).toThrow(MalformedConfigError);
});

test("valid round trip: writeUserConfig then readUserConfig", () => {
  writeUserConfig({
    selection: { providerId: "chatgpt-plan", modelId: "gpt-5.5" },
    effort: "medium",
  });
  expect(readUserConfig()).toEqual({
    selection: { providerId: "chatgpt-plan", modelId: "gpt-5.5" },
    effort: "medium",
  });
});

test("valid file with no selection / no effort returns empty object (still no fallback to catalog default)", () => {
  writeRaw("{}");
  expect(readUserConfig()).toEqual({});
});
