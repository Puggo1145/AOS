// Read tool — load a UTF-8 text file from disk.
//
// Mirrors the playground reference (`run_read`) at the contract level: take a
// path, optionally cap the number of lines from the head, and return the
// content as plain text. Like `bash`, the path is NOT sandboxed — AOS is an
// OS-level helper, not a chroot. The model is nudged toward
// `~/.aos/workspace/` via the system prompt.
//
// Truncation strategy: bound the IO itself at MAX_OUTPUT_BYTES — we open the
// file and pull only that many bytes off disk, so a stray `read /var/log/...`
// can't allocate a multi-GB buffer in the sidecar. Decoded text is then
// optionally head-bounded by `limit` (lines). Both bounds get a one-line
// marker appended so the model can tell the content is partial.
//
// UTF-8 safety: we feed the byte slice through `StringDecoder` and never call
// `end()` on a truncated read — that drops any incomplete trailing multi-byte
// sequence cleanly instead of producing a U+FFFD replacement char.

import { promises as fs } from "node:fs";
import { homedir } from "node:os";
import { resolve } from "node:path";
import { StringDecoder } from "node:string_decoder";
import { ToolUserError, type ToolHandler, type ToolExecContext, type ToolExecResult } from "./types";

const MAX_OUTPUT_BYTES = 50_000;

interface ReadArgs {
  path: string;
  /// Max number of lines from the head. Omit to read the whole file (still
  /// capped to MAX_OUTPUT_BYTES).
  limit?: number;
}

interface ReadDetails {
  resolvedPath: string;
  /// Number of lines actually returned (after byte + line truncation).
  /// We deliberately do NOT report a `totalLines` figure: we never read past
  /// the byte cap, so the true total is unknown for large files.
  returnedLines: number;
  truncated: boolean;
  /// Bytes actually read off disk. Equal to file size when not truncated.
  bytesRead: number;
}

export function createReadTool(): ToolHandler<ReadArgs, ReadDetails> {
  return {
    spec: {
      name: "read",
      description:
        `Read a UTF-8 text file. Returns its contents as plain text, head-truncated to ` +
        `\`limit\` lines (when provided) and capped at ${MAX_OUTPUT_BYTES / 1000}KB read off disk. ` +
        `Path is NOT sandboxed — pass an absolute path or one starting with \`~\`.`,
      parameters: {
        type: "object",
        properties: {
          path: {
            type: "string",
            description: "Absolute path, or one starting with `~` for the user's home directory.",
          },
          limit: {
            type: "number",
            description: "Optional. Maximum number of lines to return from the head of the file.",
          },
        },
        required: ["path"],
      },
    },
    execute: (args, ctx) => runRead(args, ctx),
  };
}

async function runRead(args: ReadArgs, ctx: ToolExecContext): Promise<ToolExecResult<ReadDetails>> {
  if (args.limit !== undefined && (!Number.isFinite(args.limit) || args.limit <= 0)) {
    throw new ToolUserError(`read: invalid limit ${args.limit}; must be a positive finite number.`);
  }

  const resolved = resolveUserPath(args.path);

  // Stat first so missing-file / EISDIR / EACCES yield a clean ToolUserError
  // before we touch a file handle, and so we can detect "file is larger than
  // the cap" without ever reading the tail.
  let fileSize: number;
  try {
    const st = await fs.stat(resolved);
    if (!st.isFile()) {
      throw new ToolUserError(`read: ${resolved} is not a regular file.`);
    }
    fileSize = st.size;
  } catch (err) {
    if (err instanceof ToolUserError) throw err;
    throw new ToolUserError(`read: ${(err as Error).message}`);
  }

  const truncatedByBytes = fileSize > MAX_OUTPUT_BYTES;
  const readBudget = truncatedByBytes ? MAX_OUTPUT_BYTES : fileSize;

  // Bounded read: allocate exactly readBudget bytes and stop. We never load
  // the tail of a large file into memory.
  let bytesRead = 0;
  let text: string;
  const fh = await fs.open(resolved, "r");
  try {
    const buf = Buffer.allocUnsafe(readBudget);
    while (bytesRead < readBudget) {
      if (ctx.signal.aborted) throw new ToolUserError(`read: aborted.`);
      const { bytesRead: n } = await fh.read(buf, bytesRead, readBudget - bytesRead, bytesRead);
      if (n === 0) break; // file shrunk between stat and read
      bytesRead += n;
    }
    const decoder = new StringDecoder("utf8");
    text = decoder.write(buf.subarray(0, bytesRead));
    // Only flush trailing bytes when we read the full file. On a byte-truncated
    // read, leftover incomplete multi-byte sequences are intentionally dropped
    // (skipping `end()`) so the output stays valid UTF-8.
    if (!truncatedByBytes) text += decoder.end();
  } finally {
    await fh.close();
  }

  const lines = text.split("\n");
  let kept = lines;
  let truncatedByLimit = false;
  if (args.limit !== undefined && args.limit < lines.length) {
    kept = lines.slice(0, args.limit);
    truncatedByLimit = true;
  }

  let body = kept.join("\n");
  const truncated = truncatedByLimit || truncatedByBytes;
  if (truncated) {
    const note = truncatedByBytes
      ? `[truncated: file is ${fileSize} bytes; showing first ${MAX_OUTPUT_BYTES} bytes]`
      : `[truncated: ${lines.length - kept.length} more lines]`;
    body = `${body}\n${note}`;
  }

  const display = body.length > 0 ? body : "(empty file)";

  return {
    content: [{ type: "text", text: display }],
    details: {
      resolvedPath: resolved,
      returnedLines: kept.length,
      truncated,
      bytesRead,
    },
    isError: false,
  };
}

/// Expand a leading `~` to the current user's home and resolve to an
/// absolute path. We accept relative paths too — they resolve against the
/// sidecar's cwd, matching the bash tool's "no pinned cwd" stance.
function resolveUserPath(path: string): string {
  if (path.startsWith("~/") || path === "~") {
    return resolve(homedir(), path.slice(path === "~" ? 1 : 2));
  }
  return resolve(path);
}
