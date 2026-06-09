import { expect, test } from "bun:test";
import { ToolRegistry } from "../src/agent/tools";
import { validateToolArguments } from "../src/agent/tools/core/schema";
import type { ToolExecContext } from "../src/agent/tools";
import type { JSONSchema } from "../src/llm/types";
import {
	createMcpCallTool,
	createMcpGetToolDetailsTool,
	createMcpSearchToolsTool,
	registerMcpTools,
	type McpHostServiceLike,
} from "../src/mcp/tools";
import {
	McpAuthInvalidatedError,
	McpAuthRequiredError,
} from "../src/mcp/auth/errors";

const inputSchema: JSONSchema = {
	type: "object",
	properties: { path: { type: "string" } },
	required: ["path"],
};

function context(): ToolExecContext {
	return {
		sessionId: "sess_mcp",
		turnId: "turn_mcp",
		toolCallId: "tc_mcp",
		signal: new AbortController().signal,
		model: {
			id: "test-model",
			name: "Test Model",
			api: "openai-responses",
			provider: "test",
			baseUrl: "https://example.com",
			reasoning: false,
			input: ["text", "image"],
			cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
			contextWindow: 128_000,
			maxTokens: 4096,
		},
	};
}

function createHost(): McpHostServiceLike & {
	calls: Array<{ name: string; args: Record<string, unknown> }>;
} {
	const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
	return {
		calls,
		async searchTools() {
			return {
				matches: [
					{
						serverId: "filesystem",
						description: "Local files",
						tools: [
							{
								name: "filesystem.read_file",
								serverId: "filesystem",
								toolName: "read_file",
								description: "Read a file",
							},
						],
					},
				],
			};
		},
		async getToolDetails() {
			return {
				name: "filesystem.read_file",
				serverId: "filesystem",
				toolName: "read_file",
				description: "Read a file",
				inputSchema,
				annotations: { readOnlyHint: true },
			};
		},
		async callTool(name, args) {
			calls.push({ name, args });
			return {
				content: [{ type: "text", text: "ok" }],
				isError: false,
			};
		},
	};
}

test("registerMcpTools exposes exactly the stable MCP meta-tool names", () => {
	const registry = new ToolRegistry();
	registerMcpTools(registry, createHost());

	expect(registry.list().map((handler) => handler.spec.name)).toEqual([
		"mcp_search_tools",
		"mcp_get_tool_details",
		"mcp_call_tool",
	]);
});

test("mcp_search_tools returns compact JSON without schemas by default", async () => {
	const tool = createMcpSearchToolsTool(createHost());

	const result = await tool.execute({ query: "read file" }, context());

	expect(result.isError).toBe(false);
	expect(result.content).toEqual([
		{
			type: "text",
			text: JSON.stringify(
				{
					matches: [
						{
							serverId: "filesystem",
							description: "Local files",
							tools: [
								{
									name: "filesystem.read_file",
									serverId: "filesystem",
									toolName: "read_file",
									description: "Read a file",
								},
							],
						},
					],
				},
				null,
				2,
			),
		},
	]);
	expect(
		result.content[0]?.type === "text" && result.content[0].text,
	).not.toContain("inputSchema");
});

test("mcp_search_tools rejects whitespace-only queries before host lookup", () => {
	const tool = createMcpSearchToolsTool(createHost());

	expect(() =>
		validateToolArguments(tool, {
			type: "toolCall",
			id: "tc_blank",
			name: "mcp_search_tools",
			arguments: { query: "   " },
		}),
	).toThrow('Validation failed for tool "mcp_search_tools"');
});

test("mcp_get_tool_details returns the full input schema", async () => {
	const tool = createMcpGetToolDetailsTool(createHost());

	const result = await tool.execute(
		{ name: "filesystem.read_file" },
		context(),
	);

	expect(result.isError).toBe(false);
	expect(
		result.content[0]?.type === "text" && result.content[0].text,
	).toContain('"inputSchema"');
});

test("mcp_call_tool forwards canonical name and arguments to the host service", async () => {
	const host = createHost();
	const tool = createMcpCallTool(host);

	const result = await tool.execute(
		{ name: "filesystem.read_file", arguments: { path: "/tmp/a.txt" } },
		context(),
	);

	expect(result).toEqual({
		content: [{ type: "text", text: "ok" }],
		isError: false,
	});
	expect(host.calls).toEqual([
		{ name: "filesystem.read_file", args: { path: "/tmp/a.txt" } },
	]);
});

test("mcp_call_tool maps MCP isError true into a recoverable Notch tool error", async () => {
	const host: McpHostServiceLike = {
		async searchTools() {
			throw new Error("unused");
		},
		async getToolDetails() {
			throw new Error("unused");
		},
		async callTool() {
			return {
				content: [{ type: "text", text: "remote failed" }],
				isError: true,
			};
		},
	};
	const tool = createMcpCallTool(host);

	const result = await tool.execute(
		{ name: "filesystem.read_file", arguments: {} },
		context(),
	);

	expect(result).toEqual({
		content: [{ type: "text", text: "remote failed" }],
		isError: true,
	});
});

test("mcp_call_tool converts MCP image content when data and MIME type are present", async () => {
	const host: McpHostServiceLike = {
		async searchTools() {
			throw new Error("unused");
		},
		async getToolDetails() {
			throw new Error("unused");
		},
		async callTool() {
			return {
				content: [{ type: "image", data: "abc123", mimeType: "image/png" }],
				isError: false,
			};
		},
	};
	const tool = createMcpCallTool(host);

	const result = await tool.execute(
		{ name: "filesystem.screenshot", arguments: {} },
		context(),
	);

	expect(result.content).toEqual([
		{ type: "image", data: "abc123", mimeType: "image/png" },
	]);
});

test("auth required during search returns recoverable login-required tool result", async () => {
	const host: McpHostServiceLike = {
		async searchTools() {
			throw new McpAuthRequiredError("linear");
		},
		async getToolDetails() {
			throw new Error("unused");
		},
		async callTool() {
			throw new Error("unused");
		},
	};
	const tool = createMcpSearchToolsTool(host);

	const result = await tool.execute({ query: "issue" }, context());

	expect(result.isError).toBe(true);
	expect(result.content[0]).toMatchObject({
		type: "text",
		text: expect.stringContaining("login required"),
	});
});

test("auth invalidated during call returns recoverable auth-invalidated tool result", async () => {
	const host: McpHostServiceLike = {
		async searchTools() {
			throw new Error("unused");
		},
		async getToolDetails() {
			throw new Error("unused");
		},
		async callTool() {
			throw new McpAuthInvalidatedError("linear");
		},
	};
	const tool = createMcpCallTool(host);

	const result = await tool.execute(
		{ name: "linear.create_issue", arguments: {} },
		context(),
	);

	expect(result.isError).toBe(true);
	expect(result.content[0]).toMatchObject({
		type: "text",
		text: expect.stringContaining("auth invalidated"),
	});
});

test("protocol failures still throw as tool failures", async () => {
	const host: McpHostServiceLike = {
		async searchTools() {
			throw new Error("protocol failed");
		},
		async getToolDetails() {
			throw new Error("unused");
		},
		async callTool() {
			throw new Error("unused");
		},
	};
	const tool = createMcpSearchToolsTool(host);

	await expect(tool.execute({ query: "issue" }, context())).rejects.toThrow(
		"protocol failed",
	);
});
