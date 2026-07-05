import { z, type ZodIssue, type ZodType } from "zod";
import type { JSONSchema, ToolCall } from "../../../llm";
import type {
	ToolExecContext,
	ToolExecResult,
	ToolHandler,
	ToolRuntimeEffects,
} from "./types";

type AnyZodType = ZodType<any, any, any>;

export interface DefineToolInput<TSchema extends AnyZodType, TDetails> {
	name: string;
	description: string;
	parameters: TSchema;
	execute(
		args: z.infer<TSchema>,
		ctx: ToolExecContext,
	): Promise<ToolExecResult<TDetails>>;
	applyRuntimeEffects?(
		result: ToolExecResult<TDetails>,
		args: z.infer<TSchema>,
		ctx: ToolExecContext,
		effects: ToolRuntimeEffects,
	): void;
}

/// Define a tool from a zod parameter schema. The zod schema is retained for
/// dispatch-time validation, while the model receives the generated JSON
/// Schema in `spec.parameters`.
export function defineTool<TSchema extends AnyZodType, TDetails = unknown>(
	input: DefineToolInput<TSchema, TDetails>,
): ToolHandler<z.infer<TSchema>, TDetails> {
	return {
		parameterSchema: input.parameters,
		spec: {
			name: input.name,
			description: input.description,
			parameters: zodParametersToJSONSchema(input.parameters),
		},
		execute: async (args, ctx) =>
			input.execute(
				parseToolArguments(input.name, input.parameters, args),
				ctx,
			),
		applyRuntimeEffects: input.applyRuntimeEffects,
	};
}

export function validateToolArguments<TArgs>(
	handler: ToolHandler<TArgs, unknown>,
	toolCall: ToolCall,
): TArgs {
	return parseToolArguments(
		handler.spec.name,
		handler.parameterSchema,
		toolCall.arguments,
	);
}

function parseToolArguments<TArgs>(
	toolName: string,
	schema: ZodType<TArgs, any, any>,
	args: unknown,
): TArgs {
	const parsed = schema.safeParse(structuredClone(args));
	if (!parsed.success) {
		const formatted = parsed.error.issues
			.flatMap(formatIssue)
			.map((line) => `  - ${line}`)
			.join("\n");
		throw new Error(
			`Validation failed for tool "${toolName}":\n${formatted}\n\nReceived arguments:\n${JSON.stringify(args, null, 2)}`,
		);
	}
	return parsed.data;
}

export function zodParametersToJSONSchema(schema: ZodType): JSONSchema {
	const json = z.toJSONSchema(schema) as JSONSchema & { $schema?: unknown };
	const { $schema: _schema, ...parameters } = json;
	return parameters as JSONSchema;
}

function formatIssue(issue: ZodIssue): string[] {
	if (issue.code === "unrecognized_keys") {
		const prefix = formatPath(issue.path);
		return issue.keys.map(
			(key) => `${prefix ? `${prefix}.` : ""}${key}: unknown field`,
		);
	}
	return [`${formatPath(issue.path) || "<root>"}: ${issue.message}`];
}

function formatPath(path: PropertyKey[]): string {
	let out = "";
	for (const part of path) {
		if (typeof part === "number") {
			out += `[${part}]`;
			continue;
		}
		out += out.length === 0 ? String(part) : `.${String(part)}`;
	}
	return out;
}
