import { Buffer } from "node:buffer";
import type { JSONValue } from "../../rpc/rpc-types";
import { resolveFileToolPath } from "../tools/builtins/files/path-policy";
import { workspaceDir } from "../workspace";
import { allow, ask } from "./decision";
import { isPathWithinRootRealpath } from "./path";
import type {
	CapabilityId,
	InternalToolName,
	PermissionCapabilityRequest,
	PermissionPolicyContext,
	PermissionPolicyDecision,
	PermissionPolicyEvaluator,
	PermissionRisk,
} from "./types";

type FilesystemPolicyInput = {
	readonly capability: Extract<
		CapabilityId,
		"filesystem.read" | "filesystem.write"
	>;
	readonly action: string;
	readonly pathArg: string;
	readonly details?: (ctx: PermissionPolicyContext) => JSONValue | undefined;
	readonly ask: {
		readonly title: string;
		readonly message: string;
		readonly risk: PermissionRisk;
	};
};

export const builtinPermissionPoliciesByToolName = {
	read: (ctx) =>
		allowWorkspacePathElseAsk(ctx, {
			capability: "filesystem.read",
			action: "Read file",
			pathArg: "path",
			ask: {
				title: "Allow file read?",
				message:
					"Agent wants to read a file outside the Notch Agent workspace.",
				risk: "medium",
			},
		}),

	write: (ctx) =>
		allowWorkspacePathElseAsk(ctx, {
			capability: "filesystem.write",
			action: "Write file",
			pathArg: "path",
			details({ args }): JSONValue {
				return {
					bytes: Buffer.byteLength(stringArg(args, "content"), "utf8"),
					mode: "overwrite-or-create",
				};
			},
			ask: {
				title: "Allow file write?",
				message:
					"Agent wants to write a file outside the Notch Agent workspace.",
				risk: "high",
			},
		}),

	update: (ctx) =>
		allowWorkspacePathElseAsk(ctx, {
			capability: "filesystem.write",
			action: "Update file",
			pathArg: "path",
			details({ args }): JSONValue {
				return {
					oldTextBytes: Buffer.byteLength(stringArg(args, "old_text"), "utf8"),
					newTextBytes: Buffer.byteLength(stringArg(args, "new_text"), "utf8"),
				};
			},
			ask: {
				title: "Allow file update?",
				message:
					"Agent wants to update a file outside the Notch Agent workspace.",
				risk: "high",
			},
		}),

	bash: (ctx) =>
		ask({
			title: "Allow command?",
			message: "Agent wants to run a shell command.",
			risk: "high",
			capabilities: [
				{
					capability: "process.spawn",
					action: "Run shell command",
					target: stringArg(ctx.args, "command"),
					details: {
						cwd: workspaceDir(),
						timeoutSeconds: numberArgOrDefault(ctx.args, "timeout", 120),
					},
				},
			],
		}),

	list_apps: () =>
		allow([{ capability: "computer.read", action: "List apps" }]),

	list_windows: () =>
		allow([{ capability: "computer.read", action: "List windows" }]),

	get_app_state: () =>
		allow([{ capability: "computer.read", action: "Read app state" }]),

	start_app_session: (ctx) => askComputerUse(ctx, "Start app session"),

	stop_app_session: () =>
		allow([{ capability: "computer.cleanup", action: "Stop app session" }]),

	use_mouse: (ctx) => askComputerUse(ctx, "Use mouse"),

	use_keyboard: (ctx) => askComputerUse(ctx, "Use keyboard"),

	perform_AX_action: (ctx) => askComputerUse(ctx, "Perform AX action"),

	todo_write: () => allow(),

	mcp_search_tools: (ctx) =>
		askMcpDiscovery(
			"Allow MCP discovery?",
			"Agent wants to inspect configured MCP server tools.",
			"Search MCP tools",
			stringArg(ctx.args, "query"),
		),

	mcp_get_tool_details: (ctx) =>
		askMcpDiscovery(
			"Allow MCP discovery?",
			"Agent wants to inspect a configured MCP server tool schema.",
			"Inspect MCP tool",
			stringArg(ctx.args, "name"),
		),

	mcp_call_tool: (ctx) =>
		ask({
			title: "Allow MCP tool?",
			message: "Agent wants to execute a configured MCP server tool.",
			risk: "high",
			capabilities: [
				{
					capability: "mcp.execute",
					action: "Execute MCP tool",
					target: stringArg(ctx.args, "name"),
					details: mcpCallDetails(ctx.args),
				},
			],
		}),
} satisfies { readonly [K in InternalToolName]: PermissionPolicyEvaluator };

function allowWorkspacePathElseAsk(
	ctx: PermissionPolicyContext,
	input: FilesystemPolicyInput,
): PermissionPolicyDecision {
	const resolved = resolveFileToolPath(stringArg(ctx.args, input.pathArg));
	const capability: PermissionCapabilityRequest = {
		capability: input.capability,
		action: input.action,
		target: resolved,
		details: input.details?.(ctx),
	};
	if (isPathWithinRootRealpath(resolved, workspaceDir())) {
		return allow([capability]);
	}
	return ask({
		title: input.ask.title,
		message: input.ask.message,
		risk: input.ask.risk,
		capabilities: [capability],
	});
}

function askComputerUse(
	ctx: PermissionPolicyContext,
	action: string,
): PermissionPolicyDecision {
	return ask({
		title: "Allow Computer Use?",
		message: "Agent wants to use Computer Use to control an app.",
		risk: "high",
		groupId: "computer-use",
		groupGrantScope: "turn",
		capabilities: [
			{
				capability: "computer.actuate",
				action,
				target: `window ${requiredValue(ctx.args, "windowId")}`,
			},
		],
	});
}

function askMcpDiscovery(
	title: string,
	message: string,
	action: string,
	target: string,
): PermissionPolicyDecision {
	return ask({
		title,
		message,
		risk: "medium",
		capabilities: [
			{
				capability: "mcp.execute",
				action,
				target,
			},
		],
	});
}

function stringArg(args: Record<string, unknown>, name: string): string {
	const value = args[name];
	if (typeof value !== "string") {
		throw new Error(`permission policy expected ${name} to be a string`);
	}
	return value;
}

function numberArgOrDefault(
	args: Record<string, unknown>,
	name: string,
	defaultValue: number,
): number {
	const value = args[name];
	if (value === undefined) return defaultValue;
	if (typeof value !== "number") {
		throw new Error(`permission policy expected ${name} to be a number`);
	}
	return value;
}

function requiredValue(args: Record<string, unknown>, name: string): unknown {
	const value = args[name];
	if (value === undefined || value === null) {
		throw new Error(`permission policy expected ${name} to be present`);
	}
	return value;
}

function mcpCallDetails(args: Record<string, unknown>): JSONValue {
	const canonicalName = stringArg(args, "name");
	const dot = canonicalName.indexOf(".");
	if (dot <= 0 || dot === canonicalName.length - 1) {
		throw new Error(
			`permission policy expected MCP tool name to use <serverId>.<toolName>`,
		);
	}
	const toolArguments = args.arguments;
	if (
		toolArguments === null ||
		typeof toolArguments !== "object" ||
		Array.isArray(toolArguments)
	) {
		throw new Error(`permission policy expected arguments to be an object`);
	}
	return {
		serverId: canonicalName.slice(0, dot),
		toolName: canonicalName.slice(dot + 1),
		canonicalName,
		argumentsSummary: JSON.stringify(toolArguments),
	};
}
