// Agent-turn tool dispatch.
//
// The agent loop decides *when* tools run. This module owns *how* a model
// tool call becomes a validated handler invocation and how handler output is
// rendered back onto the UI wire.

import type {
  Api,
  AssistantMessage,
  Model,
  ToolCall,
  ToolResultContent,
} from "../../llm";
import { validateToolArguments } from "../../llm";
import { ToolUserError, type ToolExecResult, type ToolHandler } from "../tools";

export type ToolCallOutcome =
  | { kind: "ready"; args: Record<string, unknown>; handler: ToolHandler<any, any> }
  | { kind: "rejected"; errorMessage: string };

export interface ToolDispatchCtx {
  sessionId: string;
  turnId: string;
  toolCallId: string;
  model: Model<Api>;
  signal: AbortSignal;
}

export function extractToolCalls(msg: AssistantMessage): ToolCall[] {
  const out: ToolCall[] = [];
  for (const c of msg.content) {
    if (c.type === "toolCall") out.push(c);
  }
  return out;
}

export function assistantSpoke(msg: AssistantMessage): boolean {
  return msg.content.some((c) => c.type === "text" && c.text.trim().length > 0);
}

export function prepareToolCall(
  call: ToolCall,
  byName: ReadonlyMap<string, ToolHandler<any, any>>,
): ToolCallOutcome {
  const handler = byName.get(call.name);
  if (!handler) {
    const known = Array.from(byName.keys()).join(", ") || "<none>";
    return {
      kind: "rejected",
      errorMessage: `Unknown tool "${call.name}". Available tools: ${known}.`,
    };
  }
  try {
    const args = validateToolArguments(handler.spec, call) as Record<string, unknown>;
    return { kind: "ready", args, handler };
  } catch (err) {
    return {
      kind: "rejected",
      errorMessage: err instanceof Error ? err.message : String(err),
    };
  }
}

export async function runTool(
  handler: ToolHandler<any, any>,
  args: Record<string, unknown>,
  toolName: string,
  ctx: ToolDispatchCtx,
): Promise<ToolExecResult> {
  try {
    return await handler.execute(args, ctx);
  } catch (err) {
    if (err instanceof ToolUserError) {
      return {
        content: [{ type: "text", text: err.message }],
        isError: true,
      };
    }
    if (ctx.signal.aborted) {
      return {
        content: [{ type: "text", text: `${toolName} cancelled` }],
        isError: true,
      };
    }
    const inner = err instanceof Error ? err : new Error(String(err));
    const wrapped = new Error(`Tool "${toolName}" threw: ${inner.message}`);
    (wrapped as Error & { cause?: unknown }).cause = inner;
    throw wrapped;
  }
}

export function renderToolResultForWire(content: ToolResultContent[]): string {
  const out: string[] = [];
  for (const c of content) {
    if (c.type === "text") out.push(c.text);
    else if (c.type === "image") out.push(`[image ${c.mimeType}]`);
  }
  return out.join("\n");
}
