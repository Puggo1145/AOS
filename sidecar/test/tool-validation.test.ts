import { test, expect } from "bun:test";
import { z } from "zod";
import { defineTool, validateToolArguments } from "../src/agent/tools/core/schema";
import type { ToolCall } from "../src/llm/types";

function call(arguments_: Record<string, unknown>): ToolCall {
  return {
    type: "toolCall",
    id: "call-1",
    name: "strict_tool",
    arguments: arguments_,
  };
}

test("validator rejects unknown root object keys when additionalProperties is false", () => {
  const handler = defineTool({
    name: "strict_tool",
    description: "Strict root object",
    parameters: z.object({
      windowId: z.number().int(),
    }).strict(),
    execute: async () => ({ content: [{ type: "text", text: "ok" }], isError: false }),
  });

  expect(handler.spec.parameters).toMatchObject({
    type: "object",
    properties: {
      windowId: { type: "integer" },
    },
    required: ["windowId"],
    additionalProperties: false,
  });
  expect(() => validateToolArguments(handler, call({ windowId: 77, pid: 1234 }))).toThrow(/pid/);
});

test("validator rejects unknown nested object keys when additionalProperties is false", () => {
  const handler = defineTool({
    name: "strict_tool",
    description: "Strict nested object",
    parameters: z.object({
      event: z.object({
        kind: z.literal("click"),
      }).strict(),
    }).strict(),
    execute: async () => ({ content: [{ type: "text", text: "ok" }], isError: false }),
  });

  expect(() => validateToolArguments(handler, call({ event: { kind: "click", pid: 1234 } }))).toThrow(/event\.pid/);
});

test("validator rejects numeric strings instead of coercing model arguments", () => {
  const handler = defineTool({
    name: "strict_tool",
    description: "Strict numeric object",
    parameters: z.object({
      windowId: z.number().int(),
    }).strict(),
    execute: async () => ({ content: [{ type: "text", text: "ok" }], isError: false }),
  });

  expect(() => validateToolArguments(handler, call({ windowId: "77" }))).toThrow(/windowId/);
});
