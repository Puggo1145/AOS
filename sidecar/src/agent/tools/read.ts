// Read tool — load a UTF-8 text file from disk.
//
// Takes a path plus an optional 1-based inclusive line range. Omitted `end`
// returns 500 lines from `start` (default: 1). Like `bash`, the path is NOT
// sandboxed — Notch Agent is an OS-level helper, not a chroot. The model is nudged
// toward `~/.notch-agent/workspace/` via the system prompt.
//
// The implementation streams line-by-line rather than loading the file into
// memory. We still scan to EOF so the trailing remaining-line marker is exact.

import { promises as fs } from "node:fs";
import { createReadStream } from "node:fs";
import { createInterface } from "node:readline/promises";
import { FILE_TOOL_PATH_PARAMETER_DESCRIPTION, resolveFileToolPath } from "./file-path-policy";
import { ToolUserError, type ToolHandler, type ToolExecContext, type ToolExecResult } from "./types";

const DEFAULT_LINE_COUNT = 500;

interface ReadArgs {
  path: string;
  /// 1-based first line to return. Defaults to 1.
  start?: number;
  /// 1-based inclusive final line to return. Defaults to start + 499.
  end?: number;
}

interface ReadDetails {
  resolvedPath: string;
  /// Number of file lines actually returned.
  returnedLines: number;
  truncated: boolean;
  /// Number of lines after the requested range.
  remainingLines: number;
}

export function createReadTool(): ToolHandler<ReadArgs, ReadDetails> {
  return {
    spec: {
      name: "read",
      description:
        `Read a UTF-8 text file. Returns a 1-based inclusive line range as plain text. ` +
        `Defaults to 500 lines from \`start\` (default: 1). `,
      parameters: {
        type: "object",
        properties: {
          path: {
            type: "string",
            description: FILE_TOOL_PATH_PARAMETER_DESCRIPTION,
          },
          start: {
            type: "number",
            description: "Optional. 1-based first line to return. Defaults to 1.",
          },
          end: {
            type: "number",
            description: "Optional. 1-based inclusive final line to return. Defaults to start + 499.",
          },
        },
        required: ["path"],
      },
    },
    execute: (args, ctx) => runRead(args, ctx),
  };
}

async function runRead(args: ReadArgs, ctx: ToolExecContext): Promise<ToolExecResult<ReadDetails>> {
  const resolved = resolveFileToolPath(args.path);
  const start = normalizeLineNumber(args.start ?? 1, "start");
  const end = args.end === undefined
    ? start + DEFAULT_LINE_COUNT - 1
    : normalizeLineNumber(args.end, "end");
  if (end < start) {
    throw new ToolUserError(`read: invalid range ${start}-${end}; end must be >= start.`);
  }
  const requestedLineCount = end - start + 1;
  if (requestedLineCount > DEFAULT_LINE_COUNT) {
    throw new ToolUserError(
      `read: range too large (${requestedLineCount} lines); maximum is ${DEFAULT_LINE_COUNT} lines.`,
    );
  }

  // Stat first so missing-file / EISDIR / EACCES yield a clean ToolUserError
  // before we touch the stream.
  try {
    const st = await fs.stat(resolved);
    if (!st.isFile()) {
      throw new ToolUserError(`read: ${resolved} is not a regular file.`);
    }
  } catch (err) {
    if (err instanceof ToolUserError) throw err;
    throw new ToolUserError(`read: ${(err as Error).message}`);
  }

  const stream = createReadStream(resolved, { encoding: "utf8" });
  const rl = createInterface({ input: stream, crlfDelay: Infinity });

  const kept: string[] = [];
  let lineNumber = 0;
  try {
    for await (const line of rl) {
      if (ctx.signal.aborted) throw new ToolUserError(`read: aborted.`);
      lineNumber += 1;
      if (lineNumber >= start && lineNumber <= end) {
        kept.push(formatNumberedLine(lineNumber, line));
      }
    }
  } finally {
    rl.close();
    stream.destroy();
  }

  const remainingLines = Math.max(0, lineNumber - end);
  const truncated = remainingLines > 0;
  let body = kept.join("\n");
  if (truncated) {
    const note = `[You still have ${remainingLines} more lines to read]`;
    body = body.length > 0 ? `${body}\n${note}` : note;
  }

  const display = body.length > 0
    ? body
    : lineNumber > 0
      ? `(requested range starts after EOF; file has ${lineNumber} lines)`
      : "(empty file)";

  return {
    content: [{ type: "text", text: display }],
    details: {
      resolvedPath: resolved,
      returnedLines: kept.length,
      truncated,
      remainingLines,
    },
    isError: false,
  };
}

function normalizeLineNumber(value: number, name: string): number {
  if (!Number.isInteger(value) || value <= 0) {
    throw new ToolUserError(`read: invalid ${name} ${value}; must be a positive integer.`);
  }
  return value;
}

function formatNumberedLine(lineNumber: number, line: string): string {
  return `${lineNumber} | ${line}`;
}
