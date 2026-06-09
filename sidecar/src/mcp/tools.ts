import { z } from "zod";
import type { ToolRegistry } from "../agent/tools";
import { defineTool, ToolUserError } from "../agent/tools";
import type { ToolExecResult } from "../agent/tools";
import type { ToolResultContent } from "../llm/types";
import type {
	McpToolDetails,
	McpToolDetailLevel,
	McpToolSearchResult,
} from "./host-service";
import {
	McpAuthInvalidatedError,
	McpAuthRequiredError,
	McpInsufficientScopeError,
} from "./auth/errors";

export interface McpHostServiceLike {
	searchTools(
		query: string,
		detailLevel?: McpToolDetailLevel,
	): Promise<McpToolSearchResult>;
	getToolDetails(name: string): Promise<McpToolDetails>;
	callTool(
		name: string,
		args: Record<string, unknown>,
	): Promise<{ content?: unknown[]; isError?: boolean }>;
}

const searchSchema = z.strictObject({
	query: z.string().trim().min(1),
	detailLevel: z.enum(["names", "descriptions", "schemas"]).optional(),
});

const detailsSchema = z.strictObject({
	name: z.string().min(1),
});

const callSchema = z.strictObject({
	name: z.string().min(1),
	arguments: z.record(z.string(), z.unknown()),
});

export function registerMcpTools(
	registry: ToolRegistry,
	hostService: McpHostServiceLike,
): void {
	registry.register(createMcpSearchToolsTool(hostService), "mcp");
	registry.register(createMcpGetToolDetailsTool(hostService), "mcp");
	registry.register(createMcpCallTool(hostService), "mcp");
}

export function createMcpSearchToolsTool(hostService: McpHostServiceLike) {
	return defineTool({
		name: "mcp_search_tools",
		description:
			"Search configured MCP servers for relevant tools. Returns compact metadata by default; call mcp_get_tool_details for a full schema before execution.",
		parameters: searchSchema,
		async execute(args) {
			try {
				const result = await hostService.searchTools(
					args.query,
					args.detailLevel,
				);
				return jsonResult(result);
			} catch (err) {
				const authResult = authErrorResult(err);
				if (authResult) return authResult;
				throw err;
			}
		},
	});
}

export function createMcpGetToolDetailsTool(hostService: McpHostServiceLike) {
	return defineTool({
		name: "mcp_get_tool_details",
		description:
			"Inspect one MCP tool by canonical name and return its full input schema.",
		parameters: detailsSchema,
		async execute(args) {
			try {
				const result = await hostService.getToolDetails(args.name);
				return jsonResult(result);
			} catch (err) {
				const authResult = authErrorResult(err);
				if (authResult) return authResult;
				throw err;
			}
		},
	});
}

export function createMcpCallTool(hostService: McpHostServiceLike) {
	return defineTool({
		name: "mcp_call_tool",
		description:
			"Execute one configured MCP tool by canonical name after inspecting its schema.",
		parameters: callSchema,
		async execute(args) {
			try {
				const result = await hostService.callTool(args.name, args.arguments);
				return {
					content: convertMcpContent(result.content ?? []),
					isError: result.isError === true,
				};
			} catch (err) {
				const authResult = authErrorResult(err);
				if (authResult) return authResult;
				throw err;
			}
		},
	});
}

function jsonResult(value: unknown, isError = false): ToolExecResult {
	return {
		content: [{ type: "text", text: JSON.stringify(value, null, 2) }],
		isError,
	};
}

function convertMcpContent(content: unknown[]): ToolResultContent[] {
	const converted = content.map(convertMcpContentBlock);
	if (converted.length === 0) {
		return [{ type: "text", text: "MCP tool returned no content." }];
	}
	return converted;
}

function convertMcpContentBlock(block: unknown): ToolResultContent {
	if (block === null || typeof block !== "object" || Array.isArray(block)) {
		throw new ToolUserError("MCP tool returned an unsupported content block.");
	}
	const obj = block as Record<string, unknown>;
	if (obj.type === "text" && typeof obj.text === "string") {
		return { type: "text", text: obj.text };
	}
	if (
		obj.type === "image" &&
		typeof obj.data === "string" &&
		typeof obj.mimeType === "string"
	) {
		return { type: "image", data: obj.data, mimeType: obj.mimeType };
	}
	throw new ToolUserError(
		`MCP tool returned unsupported content type ${JSON.stringify(obj.type)}.`,
	);
}

function authErrorResult(err: unknown): ToolExecResult | null {
	if (err instanceof McpAuthRequiredError) {
		return jsonResult(
			{
				error: "login required",
				serverId: err.serverId,
				message: err.message,
			},
			true,
		);
	}
	if (err instanceof McpAuthInvalidatedError) {
		return jsonResult(
			{
				error: "auth invalidated",
				serverId: err.serverId,
				message: err.message,
			},
			true,
		);
	}
	if (err instanceof McpInsufficientScopeError) {
		return jsonResult(
			{
				error: "insufficient scope",
				serverId: err.serverId,
				scope: err.scope,
				message: err.message,
			},
			true,
		);
	}
	return null;
}
