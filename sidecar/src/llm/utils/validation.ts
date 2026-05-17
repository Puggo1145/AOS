// In-house tool argument validator.
//
// Implements a small recursive walk of plain JSON Schema. Scope is what
// LLM tool calls need in practice:
//   - type checks ("string"/"number"/"integer"/"boolean"/"object"/"array"/"null")
//   - required fields on objects
//   - enum constraints (deep-equality on primitives)
//   - nested properties / items
//
// We deliberately do NOT pull in AJV: Notch Agent only validates short tool call
// payloads in this round. Coercion is intentionally minimal — we accept
// numeric strings as numbers and the strings "true"/"false" as booleans
// to absorb the most common LLM mistakes per guide §4.5; everything else
// fails loudly so the model can self-correct on the next turn.

import type { JSONSchema, Tool, ToolCall } from "../types";

interface ValidationError {
  path: string;
  message: string;
}

function pushError(errors: ValidationError[], path: string, message: string): void {
  errors.push({ path, message });
}

function coerce(schema: JSONSchema, value: unknown): unknown {
  if (typeof value === "string") {
    if (schema.type === "number" || schema.type === "integer") {
      const n = Number(value);
      if (!Number.isNaN(n)) return schema.type === "integer" ? Math.trunc(n) : n;
    }
    if (schema.type === "boolean") {
      if (value === "true") return true;
      if (value === "false") return false;
    }
    if (schema.type === "null" && value === "null") return null;
  }
  return value;
}

function checkValue(schema: JSONSchema, value: unknown, path: string, errors: ValidationError[]): unknown {
  // enum
  if (schema.enum && Array.isArray(schema.enum)) {
    if (!schema.enum.some((e) => deepEqual(e, value))) {
      pushError(errors, path, `value must be one of ${JSON.stringify(schema.enum)}`);
      return value;
    }
  }
  switch (schema.type) {
    case "string":
      if (typeof value !== "string") pushError(errors, path, `expected string, got ${typeOf(value)}`);
      return value;
    case "integer":
      if (typeof value !== "number" || !Number.isInteger(value)) pushError(errors, path, `expected integer, got ${typeOf(value)}`);
      return value;
    case "number":
      if (typeof value !== "number" || Number.isNaN(value)) pushError(errors, path, `expected number, got ${typeOf(value)}`);
      return value;
    case "boolean":
      if (typeof value !== "boolean") pushError(errors, path, `expected boolean, got ${typeOf(value)}`);
      return value;
    case "null":
      if (value !== null) pushError(errors, path, `expected null, got ${typeOf(value)}`);
      return value;
    case "array": {
      if (!Array.isArray(value)) {
        pushError(errors, path, `expected array, got ${typeOf(value)}`);
        return value;
      }
      if (schema.items) {
        const out: unknown[] = [];
        for (let i = 0; i < value.length; i++) {
          const coerced = coerce(schema.items, value[i]);
          out.push(checkValue(schema.items, coerced, `${path}[${i}]`, errors));
        }
        return out;
      }
      return value;
    }
    case "object":
    default: {
      if (schema.type === "object" || schema.properties || schema.required) {
        if (typeof value !== "object" || value === null || Array.isArray(value)) {
          pushError(errors, path, `expected object, got ${typeOf(value)}`);
          return value;
        }
        const obj = value as Record<string, unknown>;
        const out: Record<string, unknown> = {};
        // required
        for (const req of schema.required ?? []) {
          if (!(req in obj)) pushError(errors, path ? `${path}.${req}` : req, `required field missing`);
        }
        // properties
        if (schema.properties) {
          for (const [key, propSchema] of Object.entries(schema.properties)) {
            if (key in obj) {
              const childPath = path ? `${path}.${key}` : key;
              const coerced = coerce(propSchema, obj[key]);
              out[key] = checkValue(propSchema, coerced, childPath, errors);
            }
          }
        }
        // pass-through unknown keys unless the schema explicitly closes the object.
        for (const k of Object.keys(obj)) {
          if (schema.properties && k in schema.properties) continue;
          const childPath = path ? `${path}.${k}` : k;
          if (schema.additionalProperties === false) {
            pushError(errors, childPath, "unknown field");
            continue;
          }
          if (schema.additionalProperties && typeof schema.additionalProperties === "object") {
            const coerced = coerce(schema.additionalProperties, obj[k]);
            out[k] = checkValue(schema.additionalProperties, coerced, childPath, errors);
            continue;
          }
          out[k] = obj[k];
        }
        return out;
      }
      return value;
    }
  }
}

function typeOf(v: unknown): string {
  if (v === null) return "null";
  if (Array.isArray(v)) return "array";
  return typeof v;
}

function deepEqual(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (typeof a !== typeof b) return false;
  if (a && b && typeof a === "object") {
    if (Array.isArray(a) !== Array.isArray(b)) return false;
    if (Array.isArray(a) && Array.isArray(b)) {
      if (a.length !== b.length) return false;
      return a.every((v, i) => deepEqual(v, b[i]));
    }
    const ao = a as Record<string, unknown>;
    const bo = b as Record<string, unknown>;
    const ak = Object.keys(ao);
    const bk = Object.keys(bo);
    if (ak.length !== bk.length) return false;
    return ak.every((k) => deepEqual(ao[k], bo[k]));
  }
  return false;
}

/// Validate (and lightly coerce) tool arguments against the tool's JSON
/// Schema. Throws a single Error whose message lists every validation
/// failure — this is the message that gets fed back as a `toolResult`
/// with `isError: true` for the model to self-correct on the next turn.
export function validateToolArguments<T = Record<string, unknown>>(tool: Tool, toolCall: ToolCall): T {
  const errors: ValidationError[] = [];
  const cloned = structuredClone(toolCall.arguments);
  const coerced = coerce(tool.parameters, cloned);
  const result = checkValue(tool.parameters, coerced, "", errors);
  if (errors.length > 0) {
    const formatted = errors.map((e) => `  - ${e.path || "<root>"}: ${e.message}`).join("\n");
    throw new Error(
      `Validation failed for tool "${toolCall.name}":\n${formatted}\n\nReceived arguments:\n${JSON.stringify(toolCall.arguments, null, 2)}`,
    );
  }
  return result as T;
}

/// Validate a tool call against a registry of tools. Throws if the tool
/// is unknown; otherwise returns the (possibly coerced) arguments.
export function validateToolCall(tools: Tool[], toolCall: ToolCall): unknown {
  const tool = tools.find((t) => t.name === toolCall.name);
  if (!tool) {
    throw new Error(`Unknown tool "${toolCall.name}". Known tools: ${tools.map((t) => t.name).join(", ") || "<none>"}`);
  }
  return validateToolArguments(tool, toolCall);
}
