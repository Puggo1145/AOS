import { test, expect } from "bun:test";
import { validateToolArguments } from "../src/llm/utils/validation";
import type { Tool, ToolCall } from "../src/llm/types";

function call(arguments_: Record<string, unknown>): ToolCall {
  return {
    type: "toolCall",
    id: "call-1",
    name: "strict_tool",
    arguments: arguments_,
  };
}

test("validator rejects unknown root object keys when additionalProperties is false", () => {
  const tool: Tool = {
    name: "strict_tool",
    description: "Strict root object",
    parameters: {
      type: "object",
      properties: {
        windowId: { type: "integer" },
      },
      required: ["windowId"],
      additionalProperties: false,
    },
  };

  expect(() => validateToolArguments(tool, call({ windowId: 77, pid: 1234 }))).toThrow(/pid/);
});

test("validator rejects unknown nested object keys when additionalProperties is false", () => {
  const tool: Tool = {
    name: "strict_tool",
    description: "Strict nested object",
    parameters: {
      type: "object",
      properties: {
        event: {
          type: "object",
          properties: {
            kind: { type: "string", enum: ["click"] },
          },
          required: ["kind"],
          additionalProperties: false,
        },
      },
      required: ["event"],
      additionalProperties: false,
    },
  };

  expect(() => validateToolArguments(tool, call({ event: { kind: "click", pid: 1234 } }))).toThrow(/event\.pid/);
});
