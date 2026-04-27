// Update tool — replace `old_text` with `new_text` in a file.
//
// This is the playground's `edit_file` renamed: the model supplies an exact
// substring it wants to replace, and the tool swaps it. `old_text` must match
// exactly once — zero matches and multi-match are both hard errors so the
// model can't silently mutate the wrong site. The model is expected to widen
// `old_text` (more surrounding context) until it pins a unique location.
//
// Why a substring tool instead of a line/range tool: it composes with the
// `read` tool's plain text output. The model reads, picks an unambiguous
// chunk verbatim, then asks update to swap it. No line numbering contract
// to keep in sync between read and update.

import { promises as fs } from "node:fs";
import { homedir } from "node:os";
import { resolve } from "node:path";
import { ToolUserError, type ToolHandler, type ToolExecContext, type ToolExecResult } from "./types";

interface UpdateArgs {
  path: string;
  old_text: string;
  new_text: string;
}

interface UpdateDetails {
  resolvedPath: string;
  bytesBefore: number;
  bytesAfter: number;
}

export function createUpdateTool(): ToolHandler<UpdateArgs, UpdateDetails> {
  return {
    spec: {
      name: "update",
      description:
        `Replace \`old_text\` with \`new_text\` in the file at \`path\`. \`old_text\` must ` +
        `match exactly once (whitespace and indentation included); zero or multiple matches are ` +
        `errors. Make \`old_text\` long enough to uniquely identify the edit site. Path is NOT ` +
        `sandboxed — pass an absolute path or one starting with \`~\`.`,
      parameters: {
        type: "object",
        properties: {
          path: {
            type: "string",
            description: "Absolute path, or one starting with `~` for the user's home directory.",
          },
          old_text: {
            type: "string",
            description: "Exact substring to find. Must match verbatim and exactly once.",
          },
          new_text: {
            type: "string",
            description: "Replacement text. May be empty to delete `old_text`.",
          },
        },
        required: ["path", "old_text", "new_text"],
      },
    },
    execute: (args, ctx) => runUpdate(args, ctx),
  };
}

async function runUpdate(args: UpdateArgs, ctx: ToolExecContext): Promise<ToolExecResult<UpdateDetails>> {
  if (args.old_text.length === 0) {
    // Empty old_text would match at every byte position — replace().replace
    // semantics with an empty needle is a footgun, not a feature. Force the
    // model to be explicit about the edit site.
    throw new ToolUserError(`update: \`old_text\` must be non-empty.`);
  }

  const resolved = resolveUserPath(args.path);

  let original: string;
  try {
    original = await fs.readFile(resolved, { encoding: "utf-8", signal: ctx.signal });
  } catch (err) {
    throw new ToolUserError(`update: ${(err as Error).message}`);
  }

  const occurrences = countOccurrences(original, args.old_text);
  if (occurrences === 0) {
    throw new ToolUserError(
      `update: \`old_text\` not found in ${resolved}. The substring must match verbatim.`,
    );
  }
  if (occurrences > 1) {
    throw new ToolUserError(
      `update: \`old_text\` matched ${occurrences} times in ${resolved}; ` +
        `make it longer or more specific so exactly one site matches.`,
    );
  }

  const idx = original.indexOf(args.old_text);
  const updated =
    original.slice(0, idx) + args.new_text + original.slice(idx + args.old_text.length);

  if (ctx.signal.aborted) {
    throw new ToolUserError(`update: aborted before write.`);
  }

  try {
    await fs.writeFile(resolved, updated, { encoding: "utf-8", signal: ctx.signal });
  } catch (err) {
    throw new ToolUserError(`update: ${(err as Error).message}`);
  }

  const bytesBefore = Buffer.byteLength(original, "utf-8");
  const bytesAfter = Buffer.byteLength(updated, "utf-8");

  return {
    content: [
      {
        type: "text",
        text: `Updated ${resolved} (${bytesBefore} → ${bytesAfter} bytes).`,
      },
    ],
    details: { resolvedPath: resolved, bytesBefore, bytesAfter },
    isError: false,
  };
}

function countOccurrences(haystack: string, needle: string): number {
  if (needle.length === 0) return 0;
  let count = 0;
  let from = 0;
  while (true) {
    const i = haystack.indexOf(needle, from);
    if (i === -1) break;
    count += 1;
    from = i + needle.length;
  }
  return count;
}

function resolveUserPath(path: string): string {
  if (path.startsWith("~/") || path === "~") {
    return resolve(homedir(), path.slice(path === "~" ? 1 : 2));
  }
  return resolve(path);
}
