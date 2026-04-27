// Tool subsystem — type contract.
//
// Two layers cleanly separated:
//   1. `Tool` (from `llm/types.ts`) is the LLM-facing spec: name, description,
//      JSON Schema parameters. It rides on the wire to the model.
//   2. `ToolHandler` is the harness-facing executable wrapper: same `spec`
//      plus an `execute` function. Lives only in the sidecar.
//
// Keeping the wire shape and the executable shape in different types means
// the LLM payload never accidentally carries a function reference, and the
// harness can attach handler-only concerns (signal, sessionId, structured
// details) without polluting the model's view.

import type { Tool, ToolResultContent } from "../../llm/types";

/// Per-call context handed to a tool's `execute`. Carries the abort signal
/// (shared with the parent turn — cancellation propagates), plus identity
/// fields tools may want for logging or wire notifications.
export interface ToolExecContext {
  sessionId: string;
  turnId: string;
  toolCallId: string;
  /// Aborted when the parent turn is cancelled or reset. Tools MUST honor
  /// it to avoid leaking subprocesses / file handles.
  signal: AbortSignal;
}

/// Successful or recoverable-error tool output.
///
///   - `content` is the LLM-visible payload (text/image blocks). For errors
///     this is the message the model sees and can self-correct from.
///   - `details` is sidecar-side structured metadata (e.g. truncation info,
///     exit code, full output path). Never sent to the LLM; reserved for
///     future Shell rendering or local logging.
///   - `isError` distinguishes "tool ran but failed" from a genuine result.
///     Handlers can either return `{ isError: true }` directly or throw a
///     `ToolUserError` — both reach the model as recoverable feedback.
export interface ToolExecResult<TDetails = unknown> {
  content: ToolResultContent[];
  details?: TDetails;
  isError: boolean;
}

/// Recoverable failure that the model can be expected to fix on its next
/// round (bad input, missing target, transient state). Throw this from a
/// handler to surface a clean `isError` result without building the
/// `ToolExecResult` envelope by hand.
///
/// Why this exists vs catching every exception: AOS follows fail-fast
/// (AGENTS.md). Plain exceptions are treated as harness/programmer faults
/// — they bubble out of the tool dispatch and terminate the turn with a
/// `ui.error`, the same way a thrown `Error` from any other agent-loop
/// component would. Only `ToolUserError` is laundered into a recoverable
/// tool result.
export class ToolUserError extends Error {
  override readonly name = "ToolUserError";
  constructor(message: string) {
    super(message);
  }
}

/// A tool handler bundles the LLM-visible spec with the executable
/// implementation. The registry stores these; the loop picks them by
/// `spec.name` when an assistant emits a `toolCall`.
export interface ToolHandler<TArgs = Record<string, unknown>, TDetails = unknown> {
  spec: Tool;
  execute(args: TArgs, ctx: ToolExecContext): Promise<ToolExecResult<TDetails>>;
}
