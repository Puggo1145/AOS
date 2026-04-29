// `todo_write` tool — model-facing entry to the per-session TodoManager.
//
// Whole-list semantics: every call replaces the plan in its entirety. The
// model owns the canonical list; the harness validates and stores. Mirrors
// the s03 playground reference (`code-examples/s03_todo_write.py`).
//
// Why not `todo_add` / `todo_complete` micro-edits: partial edits invite
// merge races and hide the model's full plan. With whole-list semantics
// the model rewrites the list every time it changes status, the harness
// simply renders the new state, and the user always sees one coherent plan.

import type { SessionManager } from "../session/manager";
import { TodoManager, type TodoItem } from "../todos/manager";
import { toolRegistry } from "./registry";
import { ToolUserError, type ToolHandler, type ToolExecResult } from "./types";

export const TODO_WRITE_TOOL_NAME = "todo_write";

interface TodoWriteArgs {
  items: unknown;
}

interface TodoWriteDetails {
  items: TodoItem[];
}

/// Build the tool handler. The factory closes over `getManager` so the
/// handler can resolve the session-scoped `TodoManager` at call time —
/// `ToolExecContext` carries `sessionId` but not the SessionManager itself
/// (keeping the context thin). A lookup miss is treated as a programmer
/// fault and rethrown so it surfaces as a `ui.error`; tools should never
/// see an unknown sessionId in normal operation.
export function createTodoWriteTool(opts: {
  getManager: (sessionId: string) => TodoManager | null;
}): ToolHandler<TodoWriteArgs, TodoWriteDetails> {
  return {
    spec: {
      name: TODO_WRITE_TOOL_NAME,
      description:
        `Plan and track multi-step tasks. Replaces the entire to-do list with the supplied ` +
        `items. Use this BEFORE starting non-trivial work so the user can see the plan, then ` +
        `update item statuses as you progress. Constraints: at most one item may be ` +
        `in_progress at a time; max 20 items; status is one of pending | in_progress | ` +
        `completed. Returns the rendered list so you can verify the new state.`,
      parameters: {
        type: "object",
        properties: {
          items: {
            type: "array",
            description:
              `Full replacement list. Order is the rendering order shown to the user.`,
            items: {
              type: "object",
              properties: {
                id: {
                  type: "string",
                  description:
                    `Stable identifier for this item. Reuse the same id across updates so ` +
                    `the UI can track per-item state.`,
                },
                text: {
                  type: "string",
                  description: `One-line description of the step.`,
                },
                status: {
                  type: "string",
                  enum: ["pending", "in_progress", "completed"],
                  description:
                    `Current state. Only one item across the whole list may be in_progress.`,
                },
              },
              required: ["id", "text", "status"],
            },
          },
        },
        required: ["items"],
      },
    },
    execute: async (args, ctx): Promise<ToolExecResult<TodoWriteDetails>> => {
      const manager = opts.getManager(ctx.sessionId);
      if (!manager) {
        // Programmer fault — by the time a tool runs, the session that owns
        // it must exist. Throwing surfaces it via `ui.error` rather than
        // laundering it into a recoverable tool result.
        throw new Error(
          `todo_write: no TodoManager for sessionId ${ctx.sessionId}`,
        );
      }
      let rendered: string;
      try {
        rendered = manager.update(args.items);
      } catch (err) {
        // Validation failure — the model can fix it on the next round.
        throw new ToolUserError(
          err instanceof Error ? err.message : String(err),
        );
      }
      return {
        content: [{ type: "text", text: rendered }],
        details: { items: manager.snapshot() },
        isError: false,
      };
    },
  };
}

/// Register the todo tool against the global `toolRegistry`. Kept separate
/// from `registerBuiltinTools` because the tool needs a handle to the
/// SessionManager to resolve per-session state — and the builtin set is
/// designed to be context-free. Mirrors `registerComputerUseTools` (also
/// dispatcher-bound).
export function registerTodoTool(sessionManager: SessionManager): void {
  toolRegistry.register(
    createTodoWriteTool({
      getManager: (sessionId) => sessionManager.get(sessionId)?.todos ?? null,
    }),
  );
}
