import { expect, test } from "bun:test";
import type { McpConfig } from "../src/mcp/config";
import type { JSONSchema } from "../src/llm/types";
import {
	McpHostService,
	type McpClientSessionLike,
} from "../src/mcp/host-service";

const inputSchema: JSONSchema = {
	type: "object",
	properties: { path: { type: "string" } },
	required: ["path"],
};

type FakeMcpTool = {
	name: string;
	description: string;
	inputSchema: JSONSchema;
	annotations?: Record<string, unknown>;
};

function config(): McpConfig {
	return {
		servers: {
			filesystem: {
				description: "Read and write local project files",
				transport: { type: "stdio", command: "node", args: [], env: {} },
			},
			linear: {
				description: "Issue tracker and project management",
				transport: {
					type: "streamableHttp",
					url: "https://example.com/mcp",
					headers: {},
				},
			},
		},
	};
}

function createHarness(overrides?: {
	tools?: Record<string, FakeMcpTool[]>;
	listToolsError?: Record<string, Error>;
}) {
	const calls = {
		created: [] as string[],
		listTools: [] as string[],
		callTool: [] as Array<{
			serverId: string;
			toolName: string;
			args: Record<string, unknown>;
		}>,
		close: [] as string[],
	};
	const tools: Record<string, FakeMcpTool[]> = overrides?.tools ?? {
		filesystem: [
			{
				name: "read_file",
				description: "Read a file",
				inputSchema,
				annotations: { readOnlyHint: true },
			},
			{
				name: "write_file",
				description: "Write a file",
				inputSchema,
			},
		],
		linear: [
			{
				name: "create_issue",
				description: "Create an issue",
				inputSchema: { type: "object" },
			},
		],
	};
	const service = new McpHostService(config(), {
		createSession(serverId) {
			calls.created.push(serverId);
			const session: McpClientSessionLike = {
				async listTools() {
					calls.listTools.push(serverId);
					const error = overrides?.listToolsError?.[serverId];
					if (error) throw error;
					return tools[serverId] ?? [];
				},
				async callTool(toolName, args) {
					calls.callTool.push({ serverId, toolName, args });
					return {
						content: [{ type: "text", text: `${serverId}.${toolName}` }],
						isError: false,
					};
				},
				invalidateToolCache() {},
				async close() {
					calls.close.push(serverId);
				},
			};
			return session;
		},
	});
	return { calls, service };
}

test("search returns compact server-grouped matches without schemas by default", async () => {
	const { service } = createHarness();

	const result = await service.searchTools("read file");

	expect(result).toEqual({
		matches: [
			{
				serverId: "filesystem",
				description: "Read and write local project files",
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
	});
	expect(JSON.stringify(result)).not.toContain("inputSchema");
});

test("search uses server description to decide which lazy server to inspect", async () => {
	const { calls, service } = createHarness();

	const result = await service.searchTools("issue tracker");

	expect(calls.created).toEqual(["linear"]);
	expect(result.matches[0]?.tools[0]?.name).toBe("linear.create_issue");
});

test("getToolDetails connects lazily and returns exactly one full tool definition", async () => {
	const { calls, service } = createHarness();

	expect(await service.getToolDetails("filesystem.read_file")).toEqual({
		name: "filesystem.read_file",
		serverId: "filesystem",
		toolName: "read_file",
		description: "Read a file",
		inputSchema,
		annotations: { readOnlyHint: true },
	});
	expect(calls.created).toEqual(["filesystem"]);
});

test("callTool resolves canonical names and forwards to the target MCP session", async () => {
	const { calls, service } = createHarness();

	expect(
		await service.callTool("filesystem.read_file", { path: "/tmp/a.txt" }),
	).toEqual({
		content: [{ type: "text", text: "filesystem.read_file" }],
		isError: false,
	});
	expect(calls.callTool).toEqual([
		{
			serverId: "filesystem",
			toolName: "read_file",
			args: { path: "/tmp/a.txt" },
		},
	]);
});

test("unknown canonical server or tool throws loudly", async () => {
	const { service } = createHarness();

	await expect(service.getToolDetails("missing.read_file")).rejects.toThrow(
		'Unknown MCP server "missing"',
	);
	await expect(service.getToolDetails("filesystem.missing")).rejects.toThrow(
		'Unknown MCP tool "filesystem.missing"',
	);
});

test("duplicate canonical names throw during index build", async () => {
	const { service } = createHarness({
		tools: {
			filesystem: [
				{ name: "read_file", description: "A", inputSchema },
				{ name: "read_file", description: "B", inputSchema },
			],
		},
	});

	await expect(service.searchTools("read")).rejects.toThrow(
		'Duplicate MCP tool canonical name "filesystem.read_file"',
	);
});

test("refreshServer invalidates and closes the existing lazy session", async () => {
	const { calls, service } = createHarness();

	await service.getToolDetails("filesystem.read_file");
	await service.refreshServer("filesystem");
	await service.getToolDetails("filesystem.read_file");

	expect(calls.close).toEqual(["filesystem"]);
	expect(calls.created).toEqual(["filesystem", "filesystem"]);
});

test("closeAll closes all created sessions", async () => {
	const { calls, service } = createHarness();

	await service.getToolDetails("filesystem.read_file");
	await service.getToolDetails("linear.create_issue");
	await service.closeAll();

	expect(calls.close.sort()).toEqual(["filesystem", "linear"]);
});

test("status reports configured MCP servers without connecting lazily", () => {
	const { calls, service } = createHarness();

	expect(service.status()).toEqual([
		{
			serverId: "filesystem",
			name: "filesystem",
			description: "Read and write local project files",
			transportType: "stdio",
			connectionState: "disconnected",
			authState: "notConfigured",
			authType: "none",
		},
		{
			serverId: "linear",
			name: "linear",
			description: "Issue tracker and project management",
			transportType: "streamableHttp",
			connectionState: "disconnected",
			authState: "notConfigured",
			authType: "none",
		},
	]);
	expect(calls.created).toEqual([]);
});

test("addServer registers a new MCP server without connecting lazily", () => {
	const { calls, service } = createHarness();

	const server = service.addServer("github", {
		description: "Code host",
		transport: {
			type: "streamableHttp",
			url: "https://example.com/github/mcp",
			headers: {},
		},
	});

	expect(server).toMatchObject({
		serverId: "github",
		description: "Code host",
		transportType: "streamableHttp",
		connectionState: "disconnected",
	});
	expect(service.status().map((entry) => entry.serverId)).toEqual([
		"filesystem",
		"github",
		"linear",
	]);
	expect(calls.created).toEqual([]);
});

test("updateServer closes the current session and reports the new config", async () => {
	const { calls, service } = createHarness();

	await service.connectServer("filesystem");
	const server = await service.updateServer("filesystem", {
		description: "Edited local files",
		transport: { type: "stdio", command: "node", args: ["edited.js"], env: {} },
	});

	expect(server).toMatchObject({
		serverId: "filesystem",
		description: "Edited local files",
		connectionState: "disconnected",
	});
	expect(calls.close).toEqual(["filesystem"]);
});

test("connectServer loads tools and disconnectServer closes the session", async () => {
	const { calls, service } = createHarness();

	const connected = await service.connectServer("filesystem");
	const disconnected = await service.disconnectServer("filesystem");

	expect(connected.connectionState).toBe("connected");
	expect(disconnected.connectionState).toBe("disconnected");
	expect(calls.listTools).toEqual(["filesystem"]);
	expect(calls.close).toEqual(["filesystem"]);
});

test("autoConnectServers connects enabled servers and skips unauthenticated OAuth", async () => {
	const { calls, service } = createHarness({
		tools: {
			filesystem: [
				{ name: "read_file", description: "Read a file", inputSchema },
			],
			linear: [
				{ name: "create_issue", description: "Create an issue", inputSchema },
			],
		},
	});
	await service.updateServer("filesystem", {
		description: "Read and write local project files",
		autoConnect: true,
		transport: { type: "stdio", command: "node", args: [], env: {} },
	});
	await service.updateServer("linear", {
		description: "Issue tracker and project management",
		autoConnect: true,
		transport: {
			type: "streamableHttp",
			url: "https://example.com/mcp",
			headers: {},
			auth: { type: "oauth", registration: { type: "dynamic" } },
		},
	});

	const authStatuses = [
		{
			serverId: "linear",
			state: "unauthenticated",
			authType: "oauth",
		},
	] as const;
	const statuses = await service.autoConnectServers([...authStatuses]);

	expect(calls.listTools).toEqual(["filesystem"]);
	expect(statuses).toEqual([
		expect.objectContaining({
			serverId: "filesystem",
			connectionState: "connected",
		}),
	]);
	expect(
		service
			.status([...authStatuses])
			.find((server) => server.serverId === "linear"),
	).toMatchObject({
		connectionState: "disconnected",
		authState: "unauthenticated",
		authType: "oauth",
	});
});

test("connectServer records failed state and clears the broken session", async () => {
	const { calls, service } = createHarness({
		listToolsError: { linear: new Error("boom") },
	});

	await expect(service.connectServer("linear")).rejects.toThrow("boom");

	expect(
		service.status().find((server) => server.serverId === "linear"),
	).toMatchObject({
		connectionState: "failed",
		message: "boom",
	});
	expect(calls.close).toEqual(["linear"]);
});

test("removeServer closes the session and removes the server from status", async () => {
	const { calls, service } = createHarness();

	await service.connectServer("filesystem");
	await service.removeServer("filesystem");

	expect(service.status().map((server) => server.serverId)).toEqual(["linear"]);
	expect(calls.close).toEqual(["filesystem"]);
});
