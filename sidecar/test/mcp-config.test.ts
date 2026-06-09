import { afterEach, beforeEach, expect, test } from "bun:test";
import {
	mkdirSync,
	mkdtempSync,
	readFileSync,
	rmSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
	MalformedMcpConfigError,
	addMcpServerConfig,
	deleteMcpServerConfig,
	getMcpServerConfig,
	mcpConfigPath,
	readMcpConfig,
	updateMcpServerConfig,
} from "../src/mcp/config";

let originalHome: string | undefined;
let originalEnvToken: string | undefined;
let tmpHome: string;

beforeEach(() => {
	originalHome = process.env.HOME;
	originalEnvToken = process.env.MCP_TEST_TOKEN;
	tmpHome = mkdtempSync(join(tmpdir(), "notch-agent-mcp-config-test-"));
	process.env.HOME = tmpHome;
	delete process.env.MCP_TEST_TOKEN;
});

afterEach(() => {
	if (originalHome === undefined) delete process.env.HOME;
	else process.env.HOME = originalHome;
	if (originalEnvToken === undefined) delete process.env.MCP_TEST_TOKEN;
	else process.env.MCP_TEST_TOKEN = originalEnvToken;
	rmSync(tmpHome, { recursive: true, force: true });
});

function writeMcpRaw(content: string): void {
	mkdirSync(join(tmpHome, ".notch-agent"), { recursive: true });
	writeFileSync(mcpConfigPath(), content, "utf-8");
}

test("mcpConfigPath points to ~/.notch-agent/mcp.json", () => {
	expect(mcpConfigPath()).toBe(join(tmpHome, ".notch-agent", "mcp.json"));
});

test("missing MCP config returns an empty server registry", () => {
	expect(readMcpConfig()).toEqual({ servers: {} });
});

test("malformed JSON throws MalformedMcpConfigError", () => {
	writeMcpRaw("{ not json");
	expect(() => readMcpConfig()).toThrow(MalformedMcpConfigError);
});

test("top-level non-object throws MalformedMcpConfigError", () => {
	writeMcpRaw('"nope"');
	expect(() => readMcpConfig()).toThrow(MalformedMcpConfigError);
});

test("server missing description throws MalformedMcpConfigError", () => {
	writeMcpRaw(
		JSON.stringify({
			servers: {
				filesystem: {
					transport: { type: "stdio", command: "node" },
				},
			},
		}),
	);
	expect(() => readMcpConfig()).toThrow(MalformedMcpConfigError);
});

test("stdio transport requires a non-empty command", () => {
	writeMcpRaw(
		JSON.stringify({
			servers: {
				filesystem: {
					description: "Local filesystem tools",
					transport: { type: "stdio", command: "" },
				},
			},
		}),
	);
	expect(() => readMcpConfig()).toThrow(MalformedMcpConfigError);
});

test("streamable HTTP transport requires a valid URL", () => {
	writeMcpRaw(
		JSON.stringify({
			servers: {
				linear: {
					description: "Issue tracker",
					transport: { type: "streamableHttp", url: "not a url" },
				},
			},
		}),
	);
	expect(() => readMcpConfig()).toThrow(MalformedMcpConfigError);
});

test("server ids must be stable ASCII wire identifiers", () => {
	writeMcpRaw(
		JSON.stringify({
			servers: {
				"bad id": {
					description: "Bad id",
					transport: { type: "stdio", command: "node" },
				},
			},
		}),
	);
	expect(() => readMcpConfig()).toThrow(MalformedMcpConfigError);
});

test("environment interpolation only accepts present full-string references", () => {
	process.env.MCP_TEST_TOKEN = "secret-token";
	writeMcpRaw(
		JSON.stringify({
			servers: {
				linear: {
					description: "Issue tracker",
					transport: {
						type: "streamableHttp",
						url: "https://example.com/mcp",
						headers: { Authorization: "$" + "{MCP_TEST_TOKEN}" },
					},
				},
			},
		}),
	);

	expect(readMcpConfig()).toEqual({
		servers: {
			linear: {
				description: "Issue tracker",
				transport: {
					type: "streamableHttp",
					url: "https://example.com/mcp",
					headers: { Authorization: "secret-token" },
				},
			},
		},
	});
});

test("missing environment interpolation variable throws", () => {
	writeMcpRaw(
		JSON.stringify({
			servers: {
				linear: {
					description: "Issue tracker",
					transport: {
						type: "streamableHttp",
						url: "https://example.com/mcp",
						headers: { Authorization: "$" + "{MCP_TEST_TOKEN}" },
					},
				},
			},
		}),
	);
	expect(() => readMcpConfig()).toThrow(MalformedMcpConfigError);
});

test("partial environment interpolation is rejected", () => {
	process.env.MCP_TEST_TOKEN = "secret-token";
	writeMcpRaw(
		JSON.stringify({
			servers: {
				linear: {
					description: "Issue tracker",
					transport: {
						type: "streamableHttp",
						url: "https://example.com/mcp",
						headers: { Authorization: "Bearer $" + "{MCP_TEST_TOKEN}" },
					},
				},
			},
		}),
	);
	expect(() => readMcpConfig()).toThrow(MalformedMcpConfigError);
});

test("addMcpServerConfig writes a stdio server without replacing existing config", () => {
	writeMcpRaw(
		JSON.stringify({
			version: 1,
			servers: {
				linear: {
					description: "Issue tracker",
					transport: {
						type: "streamableHttp",
						url: "https://example.com/mcp",
						headers: {},
					},
				},
			},
		}),
	);

	const parsed = addMcpServerConfig({
		serverId: "filesystem",
		description: "Local filesystem tools",
		transportType: "stdio",
		command: "npx",
		args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
		env: { MCP_MODE: "test" },
	});

	expect(parsed.servers.filesystem).toEqual({
		description: "Local filesystem tools",
		transport: {
			type: "stdio",
			command: "npx",
			args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
			env: { MCP_MODE: "test" },
		},
	});
	const raw = JSON.parse(readFileSync(mcpConfigPath(), "utf-8"));
	expect(raw.version).toBe(1);
	expect(Object.keys(raw.servers).sort()).toEqual(["filesystem", "linear"]);
});

test("addMcpServerConfig writes a streamable HTTP server with headers", () => {
	const parsed = addMcpServerConfig({
		serverId: "linear",
		description: "Issue tracker",
		transportType: "streamableHttp",
		authType: "headers",
		url: "https://example.com/mcp",
		headers: { "X-Test": "one" },
	});

	expect(parsed.servers.linear).toEqual({
		description: "Issue tracker",
		transport: {
			type: "streamableHttp",
			url: "https://example.com/mcp",
			headers: { "X-Test": "one" },
		},
	});
});

test("addMcpServerConfig writes a streamable HTTP server with OAuth auth", () => {
	const parsed = addMcpServerConfig({
		serverId: "notion",
		description: "Notion workspace",
		transportType: "streamableHttp",
		authType: "oauth",
		autoConnect: true,
		url: "https://mcp.notion.com/mcp",
	});

	expect(parsed.servers.notion).toEqual({
		description: "Notion workspace",
		autoConnect: true,
		transport: {
			type: "streamableHttp",
			url: "https://mcp.notion.com/mcp",
			headers: {},
			auth: {
				type: "oauth",
				registration: { type: "dynamic" },
			},
		},
	});
	const raw = JSON.parse(readFileSync(mcpConfigPath(), "utf-8"));
	expect(raw.servers.notion.autoConnect).toBe(true);
	expect(raw.servers.notion.transport.auth).toEqual({
		type: "oauth",
		registration: { type: "dynamic" },
	});
});

test("addMcpServerConfig fails loudly for duplicate server ids", () => {
	writeMcpRaw(
		JSON.stringify({
			servers: {
				filesystem: {
					description: "Local filesystem tools",
					transport: { type: "stdio", command: "node" },
				},
			},
		}),
	);

	expect(() =>
		addMcpServerConfig({
			serverId: "filesystem",
			description: "Duplicate",
			transportType: "stdio",
			command: "node",
		}),
	).toThrow(MalformedMcpConfigError);
});

test("getMcpServerConfig returns raw editable values without resolving env references", () => {
	writeMcpRaw(
		JSON.stringify({
			servers: {
				linear: {
					description: "Issue tracker",
					transport: {
						type: "streamableHttp",
						url: "https://example.com/mcp",
						headers: { Authorization: "$" + "{MCP_TEST_TOKEN}" },
					},
				},
			},
		}),
	);
	process.env.MCP_TEST_TOKEN = "secret-token";

	expect(getMcpServerConfig("linear")).toEqual({
		serverId: "linear",
		description: "Issue tracker",
		transportType: "streamableHttp",
		authType: "headers",
		url: "https://example.com/mcp",
		headers: { Authorization: "$" + "{MCP_TEST_TOKEN}" },
	});
});

test("getMcpServerConfig returns OAuth auth type for editable HTTP servers", () => {
	writeMcpRaw(
		JSON.stringify({
			servers: {
				notion: {
					description: "Notion workspace",
					autoConnect: true,
					transport: {
						type: "streamableHttp",
						url: "https://mcp.notion.com/mcp",
						headers: {},
						auth: {
							type: "oauth",
							registration: { type: "dynamic" },
						},
					},
				},
			},
		}),
	);

	expect(getMcpServerConfig("notion")).toEqual({
		serverId: "notion",
		description: "Notion workspace",
		autoConnect: true,
		transportType: "streamableHttp",
		authType: "oauth",
		url: "https://mcp.notion.com/mcp",
		headers: {},
	});
});

test("updateMcpServerConfig edits one server and removes OAuth auth when auth type is none", () => {
	writeMcpRaw(
		JSON.stringify({
			servers: {
				linear: {
					description: "Issue tracker",
					transport: {
						type: "streamableHttp",
						url: "https://example.com/mcp",
						headers: {},
						auth: {
							type: "oauth",
							registration: { type: "dynamic" },
						},
					},
				},
				filesystem: {
					description: "Local filesystem tools",
					transport: { type: "stdio", command: "node" },
				},
			},
		}),
	);

	const parsed = updateMcpServerConfig({
		serverId: "linear",
		description: "Edited issue tracker",
		transportType: "streamableHttp",
		authType: "none",
		url: "https://example.com/edited-mcp",
	});

	expect(parsed.servers.linear?.description).toBe("Edited issue tracker");
	const raw = JSON.parse(readFileSync(mcpConfigPath(), "utf-8"));
	expect(raw.servers.linear.transport.auth).toBeUndefined();
	expect(raw.servers.linear.transport.headers).toEqual({});
	expect(raw.servers.filesystem.description).toBe("Local filesystem tools");
});

test("updateMcpServerConfig preserves advanced OAuth auth when auth stays OAuth", () => {
	writeMcpRaw(
		JSON.stringify({
			servers: {
				linear: {
					description: "Issue tracker",
					transport: {
						type: "streamableHttp",
						url: "https://example.com/mcp",
						headers: {},
						auth: {
							type: "oauth",
							resource: "https://example.com/mcp",
							redirect: {
								host: "localhost",
								port: 49231,
								path: "/oauth/callback",
							},
							registration: {
								type: "clientIdMetadataDocument",
								clientId: "https://client.example.com/oauth/client-metadata.json",
							},
						},
					},
				},
			},
		}),
	);

	const parsed = updateMcpServerConfig({
		serverId: "linear",
		description: "Edited issue tracker",
		transportType: "streamableHttp",
		authType: "oauth",
		url: "https://example.com/edited-mcp",
	});

	expect(parsed.servers.linear?.description).toBe("Edited issue tracker");
	const raw = JSON.parse(readFileSync(mcpConfigPath(), "utf-8"));
	expect(raw.servers.linear.transport.auth).toEqual({
		type: "oauth",
		resource: "https://example.com/mcp",
		redirect: {
			host: "localhost",
			port: 49231,
			path: "/oauth/callback",
		},
		registration: {
			type: "clientIdMetadataDocument",
			clientId: "https://client.example.com/oauth/client-metadata.json",
		},
	});
});

test("updateMcpServerConfig fails loudly for unknown server ids", () => {
	writeMcpRaw(JSON.stringify({ servers: {} }));

	expect(() =>
		updateMcpServerConfig({
			serverId: "missing",
			description: "Missing",
			transportType: "stdio",
			command: "node",
		}),
	).toThrow(MalformedMcpConfigError);
});

test("deleteMcpServerConfig removes only the requested server from mcp.json", () => {
	process.env.MCP_TEST_TOKEN = "secret-token";
	writeMcpRaw(
		JSON.stringify({
			servers: {
				filesystem: {
					description: "Local filesystem tools",
					transport: { type: "stdio", command: "node", args: ["server.js"] },
				},
				linear: {
					description: "Issue tracker",
					transport: {
						type: "streamableHttp",
						url: "https://example.com/mcp",
						headers: { Authorization: "$" + "{MCP_TEST_TOKEN}" },
					},
				},
			},
		}),
	);

	const parsed = deleteMcpServerConfig("filesystem");

	expect(Object.keys(parsed.servers)).toEqual(["linear"]);
	const raw = JSON.parse(readFileSync(mcpConfigPath(), "utf-8"));
	expect(raw.servers.filesystem).toBeUndefined();
	expect(raw.servers.linear.transport.headers.Authorization).toBe(
		"$" + "{MCP_TEST_TOKEN}",
	);
});

test("deleteMcpServerConfig fails loudly for unknown server ids", () => {
	writeMcpRaw(JSON.stringify({ servers: {} }));
	expect(() => deleteMcpServerConfig("missing")).toThrow(
		MalformedMcpConfigError,
	);
});
