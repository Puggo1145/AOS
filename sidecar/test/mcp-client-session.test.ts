import { expect, test } from "bun:test";
import type { McpServerConfig } from "../src/mcp/config";
import {
	McpClientSession,
	type McpSdkClientLike,
	type McpSdkFactories,
} from "../src/mcp/client-session";
import { McpAuthRequiredError } from "../src/mcp/auth/errors";

function stdioConfig(): McpServerConfig {
	return {
		description: "Local tools",
		transport: {
			type: "stdio",
			command: "node",
			args: ["server.js"],
			env: { API_TOKEN: "token" },
		},
	};
}

function httpConfig(): McpServerConfig {
	return {
		description: "Remote tools",
		transport: {
			type: "streamableHttp",
			url: "https://example.com/mcp",
			headers: { Authorization: "token" },
		},
	};
}

function oauthHttpConfig(): McpServerConfig {
	return {
		description: "Remote tools",
		transport: {
			type: "streamableHttp",
			url: "https://example.com/mcp",
			headers: { "X-Test": "ok" },
			auth: { type: "oauth", registration: { type: "dynamic" } },
		},
	};
}

function createHarness(config: McpServerConfig) {
	const calls = {
		createClient: 0,
		createStdioTransport: [] as unknown[],
		createStreamableHttpTransport: [] as unknown[],
		connect: [] as unknown[],
		listTools: 0,
		callTool: [] as unknown[],
		close: 0,
		terminateSession: 0,
	};
	let listChangedHandler: (() => void) | undefined;
	const client: McpSdkClientLike = {
		setNotificationHandler(method, handler) {
			if (method === "notifications/tools/list_changed") {
				listChangedHandler = handler;
			}
		},
		async connect(transport) {
			calls.connect.push(transport);
		},
		async listTools() {
			calls.listTools += 1;
			return {
				tools: [
					{
						name: "read_file",
						description: "Read a file",
						inputSchema: { type: "object" },
					},
				],
			};
		},
		async callTool(input) {
			calls.callTool.push(input);
			return {
				content: [{ type: "text", text: "ok" }],
				isError: false,
			};
		},
		async close() {
			calls.close += 1;
		},
	};
	const factories: McpSdkFactories = {
		createClient() {
			calls.createClient += 1;
			return client;
		},
		createStdioTransport(input) {
			calls.createStdioTransport.push(input);
			return { kind: "stdio", input };
		},
		createStreamableHttpTransport(url, options) {
			calls.createStreamableHttpTransport.push({ url, options });
			return {
				kind: "http",
				url,
				options,
				async terminateSession() {
					calls.terminateSession += 1;
				},
			};
		},
	};
	return {
		calls,
		session: new McpClientSession("server", config, {
			factories,
			createOAuthProvider() {
				return { token: async () => "access-token" };
			},
			hasOAuthTokens() {
				return true;
			},
		}),
		fireListChanged() {
			if (!listChangedHandler) throw new Error("list_changed handler missing");
			listChangedHandler();
		},
	};
}

function createFailingConnectHarness(config: McpServerConfig) {
	const calls = {
		close: 0,
		terminateSession: 0,
	};
	const client: McpSdkClientLike = {
		setNotificationHandler() {},
		async connect() {
			throw new Error("connect failed after opening transport");
		},
		async listTools() {
			throw new Error("listTools should not run");
		},
		async callTool() {
			throw new Error("callTool should not run");
		},
		async close() {
			calls.close += 1;
		},
	};
	const factories: McpSdkFactories = {
		createClient() {
			return client;
		},
		createStdioTransport(input) {
			return {
				kind: "stdio",
				input,
				async terminateSession() {
					calls.terminateSession += 1;
				},
			};
		},
		createStreamableHttpTransport() {
			throw new Error("HTTP transport should not be created");
		},
	};
	return {
		calls,
		session: new McpClientSession("server", config, { factories }),
	};
}

function deferred<T>() {
	let resolve!: (value: T) => void;
	let reject!: (reason?: unknown) => void;
	const promise = new Promise<T>((res, rej) => {
		resolve = res;
		reject = rej;
	});
	return { promise, resolve, reject };
}

test("stdio config creates a stdio SDK transport and connects once", async () => {
	const { calls, session } = createHarness(stdioConfig());

	await session.connect();
	await session.connect();

	expect(calls.createClient).toBe(1);
	expect(calls.createStdioTransport).toEqual([
		{ command: "node", args: ["server.js"], env: { API_TOKEN: "token" } },
	]);
	expect(calls.connect.length).toBe(1);
});

test("concurrent connect calls share one in-flight SDK connection", async () => {
	const gate = deferred<void>();
	const calls = {
		createClient: 0,
		connect: 0,
		listTools: 0,
	};
	const client: McpSdkClientLike = {
		setNotificationHandler() {},
		async connect() {
			calls.connect += 1;
			await gate.promise;
		},
		async listTools() {
			calls.listTools += 1;
			return { tools: [] };
		},
		async callTool() {
			throw new Error("callTool should not run");
		},
		async close() {},
	};
	const session = new McpClientSession("server", stdioConfig(), {
		createClient() {
			calls.createClient += 1;
			return client;
		},
		createStdioTransport(input) {
			return { kind: "stdio", input };
		},
		createStreamableHttpTransport() {
			throw new Error("HTTP transport should not be created");
		},
	});

	const first = session.listTools();
	const second = session.listTools();
	await Promise.resolve();
	expect(calls.createClient).toBe(1);
	expect(calls.connect).toBe(1);

	gate.resolve();
	await expect(Promise.all([first, second])).resolves.toEqual([[], []]);
	expect(calls.createClient).toBe(1);
	expect(calls.connect).toBe(1);
	expect(calls.listTools).toBe(2);
});

test("streamable HTTP config creates an HTTP SDK transport with resolved headers", async () => {
	const { calls, session } = createHarness(httpConfig());

	await session.connect();

	expect(calls.createStreamableHttpTransport).toHaveLength(1);
	expect(calls.createStreamableHttpTransport[0]).toMatchObject({
		url: new URL("https://example.com/mcp"),
		options: { requestInit: { headers: { Authorization: "token" } } },
	});
});

test("oauth streamableHttp config passes authProvider into StreamableHTTP transport", async () => {
	const { calls, session } = createHarness(oauthHttpConfig());

	await session.connect();

	expect(calls.createStreamableHttpTransport[0]).toMatchObject({
		options: {
			requestInit: { headers: { "X-Test": "ok" } },
			authProvider: { token: expect.any(Function) },
		},
	});
});

test("missing token surfaces McpAuthRequiredError without connecting silently", async () => {
	const { calls } = createHarness(oauthHttpConfig());
	const session = new McpClientSession("server", oauthHttpConfig(), {
		factories: {
			createClient: () => {
				throw new Error("client must not be created");
			},
			createStdioTransport: calls.createStdioTransport as never,
			createStreamableHttpTransport:
				calls.createStreamableHttpTransport as never,
		},
		createOAuthProvider() {
			return { token: async () => undefined };
		},
		hasOAuthTokens() {
			return false;
		},
	});

	await expect(session.connect()).rejects.toThrow(McpAuthRequiredError);
});

test("listTools memoizes until explicit invalidation", async () => {
	const { calls, session } = createHarness(stdioConfig());

	expect(await session.listTools()).toHaveLength(1);
	expect(await session.listTools()).toHaveLength(1);
	expect(calls.listTools).toBe(1);

	session.invalidateToolCache();
	expect(await session.listTools()).toHaveLength(1);
	expect(calls.listTools).toBe(2);
});

test("notifications/tools/list_changed invalidates cached tool definitions", async () => {
	const { calls, fireListChanged, session } = createHarness(stdioConfig());

	await session.listTools();
	fireListChanged();
	await session.listTools();

	expect(calls.listTools).toBe(2);
});

test("callTool forwards a single MCP tool call to the connected client", async () => {
	const { calls, session } = createHarness(stdioConfig());

	expect(await session.callTool("read_file", { path: "/tmp/a.txt" })).toEqual({
		content: [{ type: "text", text: "ok" }],
		isError: false,
	});
	expect(calls.callTool).toEqual([
		{ name: "read_file", arguments: { path: "/tmp/a.txt" } },
	]);
});

test("close terminates HTTP sessions then closes the SDK client", async () => {
	const { calls, session } = createHarness(httpConfig());

	await session.connect();
	await session.close();

	expect(calls.terminateSession).toBe(1);
	expect(calls.close).toBe(1);
});

test("failed SDK connect still closes the opened transport and client", async () => {
	const { calls, session } = createFailingConnectHarness(stdioConfig());

	await expect(session.connect()).rejects.toThrow(
		"connect failed after opening transport",
	);

	expect(calls.terminateSession).toBe(1);
	expect(calls.close).toBe(1);
});
