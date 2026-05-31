// Write tool — overwrite (or create) a UTF-8 text file.
//
// Whole-file write semantics: the model supplies the full final content,
// not a diff. Parent directories are created as needed so a fresh
// `~/.notch-agent/workspace/notes/today.md` works on the first call. Existing files
// are overwritten without a backup — the model is expected to `read` first
// when it cares about preserving prior content.
//
// Like the other file tools, the path is NOT sandboxed; the system prompt
// nudges the model toward `~/.notch-agent/workspace/` for scratch artifacts.

import { promises as fs } from "node:fs";
import { dirname } from "node:path";
import {
	FILE_TOOL_PATH_PARAMETER_DESCRIPTION,
	FILE_TOOL_PATH_POLICY_TEXT,
	resolveFileToolPath,
} from "./path-policy";
import { defineTool } from "../../core/schema";
import {
	ToolUserError,
	type ToolHandler,
	type ToolExecContext,
	type ToolExecResult,
} from "../../core/types";
import { z } from "zod";

interface WriteArgs {
	path: string;
	content: string;
}

interface WriteDetails {
	resolvedPath: string;
	bytesWritten: number;
	created: boolean;
}

const writeParameterSchema = z
	.object({
		path: z.string().describe(FILE_TOOL_PATH_PARAMETER_DESCRIPTION),
		content: z
			.string()
			.describe(
				"Full file contents (UTF-8). The previous file, if any, is overwritten.",
			),
	})
	.strict();

export function createWriteTool(): ToolHandler<WriteArgs, WriteDetails> {
	return defineTool({
		name: "write",
		description:
			`Write \`content\` to \`path\` as UTF-8, creating parent directories as needed and ` +
			`overwriting any existing file. ${FILE_TOOL_PATH_POLICY_TEXT} Use \`update\` instead ` +
			`when you need to change part of an existing file.`,
		parameters: writeParameterSchema,
		execute: (args, ctx) => runWrite(args, ctx),
	});
}

async function runWrite(
	args: WriteArgs,
	ctx: ToolExecContext,
): Promise<ToolExecResult<WriteDetails>> {
	const resolved = resolveFileToolPath(args.path);

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
		await fs.writeFile(resolved, args.content, {
			encoding: "utf-8",
			signal: ctx.signal,
		});
	} catch (err) {
		throw new ToolUserError(`write: ${(err as Error).message}`);
	}

	const bytesWritten = Buffer.byteLength(args.content, "utf-8");
	const verb = created ? "Created" : "Overwrote";
	return {
		content: [
			{ type: "text", text: `${verb} ${resolved} (${bytesWritten} bytes).` },
		],
		details: { resolvedPath: resolved, bytesWritten, created },
		isError: false,
	};
}
