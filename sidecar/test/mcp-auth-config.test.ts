import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
	MalformedMcpConfigError,
	mcpConfigPath,
	readMcpConfig,
} from "../src/mcp/config";

let originalHome: string | undefined;
let originalClientId: string | undefined;
let originalClientSecret: string | undefined;
let tmpHome: string;

beforeEach(() => {
	originalHome = process.env.HOME;
	originalClientId = process.env.MCP_CLIENT_ID;
	originalClientSecret = process.env.MCP_CLIENT_SECRET;
	tmpHome = mkdtempSync(join(tmpdir(), "notch-agent-mcp-auth-config-test-"));
	process.env.HOME = tmpHome;
	delete process.env.MCP_CLIENT_ID;
	delete process.env.MCP_CLIENT_SECRET;
});

afterEach(() => {
	if (originalHome === undefined) delete process.env.HOME;
	else process.env.HOME = originalHome;
	if (originalClientId === undefined) delete process.env.MCP_CLIENT_ID;
	else process.env.MCP_CLIENT_ID = originalClientId;
	if (originalClientSecret === undefined) delete process.env.MCP_CLIENT_SECRET;
	else process.env.MCP_CLIENT_SECRET = originalClientSecret;
	rmSync(tmpHome, { recursive: true, force: true });
});

function writeConfig(value: unknown): void {
	mkdirSync(join(tmpHome, ".notch-agent"), { recursive: true });
	writeFileSync(mcpConfigPath(), JSON.stringify(value), "utf-8");
}

test("oauth auth is valid only for streamableHttp transports", () => {
	writeConfig({
		servers: {
			local: {
				description: "Local",
				transport: {
					type: "stdio",
					command: "node",
					auth: { type: "oauth", registration: { type: "dynamic" } },
				},
			},
		},
	});

	expect(() => readMcpConfig()).toThrow(MalformedMcpConfigError);
});

test("headers Authorization and oauth auth are mutually exclusive", () => {
	writeConfig({
		servers: {
			remote: {
				description: "Remote",
				transport: {
					type: "streamableHttp",
					url: "https://example.com/mcp",
					headers: { Authorization: "Bearer token", "X-Test": "ok" },
					auth: { type: "oauth", registration: { type: "dynamic" } },
				},
			},
		},
	});

	expect(() => readMcpConfig()).toThrow(MalformedMcpConfigError);
});

test("preRegistered client id and secret support full-string env interpolation", () => {
	process.env.MCP_CLIENT_ID = "client-123";
	process.env.MCP_CLIENT_SECRET = "secret-456";
	writeConfig({
		servers: {
			remote: {
				description: "Remote",
				transport: {
					type: "streamableHttp",
					url: "https://example.com/mcp",
					headers: { "X-Test": "ok" },
					auth: {
						type: "oauth",
						registration: {
							type: "preRegistered",
							clientId: "$" + "{MCP_CLIENT_ID}",
							clientSecret: "$" + "{MCP_CLIENT_SECRET}",
						},
					},
				},
			},
		},
	});

	expect(readMcpConfig().servers.remote?.transport).toMatchObject({
		type: "streamableHttp",
		auth: {
			type: "oauth",
			registration: {
				type: "preRegistered",
				clientId: "client-123",
				clientSecret: "secret-456",
			},
		},
	});
});

test("clientIdMetadataDocument requires HTTPS clientId URL with path", () => {
	writeConfig({
		servers: {
			remote: {
				description: "Remote",
				transport: {
					type: "streamableHttp",
					url: "https://example.com/mcp",
					auth: {
						type: "oauth",
						registration: {
							type: "clientIdMetadataDocument",
							clientId: "https://notch.example.com",
						},
					},
				},
			},
		},
	});

	expect(() => readMcpConfig()).toThrow(MalformedMcpConfigError);
});

test("dynamic registration accepts no client credentials", () => {
	writeConfig({
		servers: {
			remote: {
				description: "Remote",
				transport: {
					type: "streamableHttp",
					url: "https://example.com/mcp",
					auth: {
						type: "oauth",
						registration: { type: "dynamic", clientId: "unexpected" },
					},
				},
			},
		},
	});

	expect(() => readMcpConfig()).toThrow(MalformedMcpConfigError);
});

test("userProvided registration is rejected until Shell credential entry exists", () => {
	writeConfig({
		servers: {
			remote: {
				description: "Remote",
				transport: {
					type: "streamableHttp",
					url: "https://example.com/mcp",
					auth: {
						type: "oauth",
						registration: { type: "userProvided" },
					},
				},
			},
		},
	});

	expect(() => readMcpConfig()).toThrow(MalformedMcpConfigError);
});

test("resource override must be an absolute URI without fragment", () => {
	writeConfig({
		servers: {
			remote: {
				description: "Remote",
				transport: {
					type: "streamableHttp",
					url: "https://example.com/mcp",
					auth: {
						type: "oauth",
						resource: "https://example.com/mcp#fragment",
						registration: { type: "dynamic" },
					},
				},
			},
		},
	});

	expect(() => readMcpConfig()).toThrow(MalformedMcpConfigError);
});
