// Idle-timeout regression for openai-responses SSE reader.
//
// Codex `/responses` was observed leaving the SSE connection open with
// zero events when fed an oversized payload (the accumulated tool-result
// screenshots case). The agent loop's `for await (const ev of stream)`
// would hang indefinitely. `readWithIdleTimeout` bounds that wait so a
// stuck stream surfaces as a `ui.error` instead of a frozen UI.

import { test, expect } from "bun:test";
import { readWithIdleTimeout } from "../src/llm/providers/openai-responses";

test("readWithIdleTimeout rejects when the underlying read never resolves", async () => {
  const reader = {
    read: () => new Promise<{ value?: Uint8Array; done: boolean }>(() => { /* never resolves */ }),
  };
  await expect(readWithIdleTimeout(reader, 30)).rejects.toThrow(/idle for 30ms/);
});

test("readWithIdleTimeout returns the chunk when read resolves before the deadline", async () => {
  const payload = new TextEncoder().encode("hello");
  const reader = {
    read: async () => ({ value: payload, done: false }),
  };
  const result = await readWithIdleTimeout(reader, 1000);
  expect(result.done).toBe(false);
  expect(result.value).toBe(payload);
});

test("readWithIdleTimeout propagates a normal stream end", async () => {
  const reader = {
    read: async () => ({ done: true }),
  };
  const result = await readWithIdleTimeout(reader, 1000);
  expect(result.done).toBe(true);
});
