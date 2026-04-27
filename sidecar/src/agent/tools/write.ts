// Write tool — overwrite (or create) a UTF-8 text file.
//
// Whole-file write semantics: the model supplies the full final content,
// not a diff. Parent directories are created as needed so a fresh
// `~/.aos/workspace/notes/today.md` works on the first call. Existing files
// are overwritten without a backup — the model is expected to `read` first
// when it cares about preserving prior content.
//
// Like the other file tools, the path is NOT sandboxed; the system prompt
// nudges the model toward `~/.aos/workspace/` for scratch artifacts.

import { promises as fs } from "node:fs";
import { homedir } from "node:os";
import { dirname, resolve } from "node:path";
import { ToolUserError, type ToolHandler, type ToolExecContext, type ToolExecResult } from "./types";

interface WriteArgs {
  path: string;
  content: string;
}

interface WriteDetails {
  resolvedPath: string;
  bytesWritten: number;
  created: boolean;
}

export function createWriteTool(): ToolHandler<WriteArgs, WriteDetails> {
  return {
    spec: {
      name: "write",
      description:
        `Write \`content\` to \`path\` as UTF-8, creating parent directories as needed and ` +
        `overwriting any existing file. Path is NOT sandboxed — pass an absolute path or one ` +
        `starting with \`~\`. Use \`update\` instead when you need to change part of an existing file.`,
      parameters: {
        type: "object",
        properties: {
          path: {
            type: "string",
            description: "Absolute path, or one starting with `~` for the user's home directory.",
          },
          content: {
            type: "string",
            description: "Full file contents (UTF-8). The previous file, if any, is overwritten.",
          },
        },
        required: ["path", "content"],
      },
    },
    execute: (args, ctx) => runWrite(args, ctx),
  };
}

async function runWrite(args: WriteArgs, ctx: ToolExecContext): Promise<ToolExecResult<WriteDetails>> {
  const resolved = resolveUserPath(args.path);

  // `created` is observable at the wire level: the model often wants to know
  // whether it just clobbered something or made a fresh file. Only ENOENT
  // means "didn't exist" — anything else (EACCES on a parent dir, EIO, etc.)
  // is a real failure that should not be silently relabelled as "created".
  let created: boolean;
  try {
    await fs.stat(resolved);
    created = false;
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== "ENOENT") {
      throw new ToolUserError(`write: ${(err as Error).message}`);
    }
    created = true;
  }

  if (ctx.signal.aborted) {
    throw new ToolUserError(`write: aborted before write.`);
  }

  try {
    await fs.mkdir(dirname(resolved), { recursive: true });
    await fs.writeFile(resolved, args.content, { encoding: "utf-8", signal: ctx.signal });
  } catch (err) {
    throw new ToolUserError(`write: ${(err as Error).message}`);
  }

  const bytesWritten = Buffer.byteLength(args.content, "utf-8");
  const verb = created ? "Created" : "Overwrote";
  return {
    content: [{ type: "text", text: `${verb} ${resolved} (${bytesWritten} bytes).` }],
    details: { resolvedPath: resolved, bytesWritten, created },
    isError: false,
  };
}

function resolveUserPath(path: string): string {
  if (path.startsWith("~/") || path === "~") {
    return resolve(homedir(), path.slice(path === "~" ? 1 : 2));
  }
  return resolve(path);
}
