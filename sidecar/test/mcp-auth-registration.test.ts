import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { McpOAuthStorage } from "../src/mcp/auth/storage";
import { resolveClientRegistration } from "../src/mcp/auth/registration";
import type { McpOAuthAuthConfig } from "../src/mcp/auth/config";
import type { AuthorizationServerMetadata } from "@modelcontextprotocol/client";

let root: string;

beforeEach(() => {
	root = mkdtempSync(join(tmpdir(), "notch-agent-mcp-auth-registration-test-"));
});

afterEach(() => {
	rmSync(root, { recursive: true, force: true });
});

function metadata(
	overrides: Partial<AuthorizationServerMetadata> = {},
): AuthorizationServerMetadata {
	return {
		issuer: "https://auth.example.com",
		authorization_endpoint: "https://auth.example.com/authorize",
		token_endpoint: "https://auth.example.com/token",
		response_types_supported: ["code"],
		code_challenge_methods_supported: ["S256"],
		...overrides,
	};
}

test("uses preRegistered client information first", async () => {
	const authConfig: McpOAuthAuthConfig = {
		type: "oauth",
		registration: {
			type: "preRegistered",
			clientId: "client",
			clientSecret: "secret",
		},
	};

	const result = await resolveClientRegistration({
		serverId: "linear",
		authConfig,
		authorizationServerMetadata: metadata({
			registration_endpoint: "https://auth.example.com/register",
		}),
		storage: new McpOAuthStorage({ homeDir: root }),
		fetch: async () => {
			throw new Error("registration endpoint must not be called");
		},
		redirectUri: "http://127.0.0.1:1234/mcp/oauth/callback",
	});

	expect(result).toEqual({ client_id: "client", client_secret: "secret" });
});

test("uses client id metadata document when server advertises support and config supplies HTTPS client id", async () => {
	const authConfig: McpOAuthAuthConfig = {
		type: "oauth",
		registration: {
			type: "clientIdMetadataDocument",
			clientId: "https://notch.example.com/oauth/mcp-client.json",
		},
	};

	const result = await resolveClientRegistration({
		serverId: "linear",
		authConfig,
		authorizationServerMetadata: metadata({
			client_id_metadata_document_supported: true,
		}),
		storage: new McpOAuthStorage({ homeDir: root }),
		fetch: async () => {
			throw new Error("metadata document is external, not fetched by sidecar");
		},
		redirectUri: "http://127.0.0.1:1234/mcp/oauth/callback",
	});

	expect(result).toEqual({
		client_id: "https://notch.example.com/oauth/mcp-client.json",
		redirect_uris: ["http://127.0.0.1:1234/mcp/oauth/callback"],
		client_name: "Notch Agent",
	});
});

test("uses dynamic registration when registration_endpoint exists", async () => {
	const storage = new McpOAuthStorage({ homeDir: root });
	const result = await resolveClientRegistration({
		serverId: "linear",
		authConfig: { type: "oauth", registration: { type: "dynamic" } },
		authorizationServerMetadata: metadata({
			registration_endpoint: "https://auth.example.com/register",
		}),
		storage,
		fetch: async (url, init) => {
			expect(String(url)).toBe("https://auth.example.com/register");
			expect(init?.method).toBe("POST");
			return new Response(
				JSON.stringify({
					client_id: "dynamic-client",
					client_secret: "dynamic-secret",
				}),
				{ status: 201, headers: { "content-type": "application/json" } },
			);
		},
		redirectUri: "http://127.0.0.1:1234/mcp/oauth/callback",
	});

	expect(result.client_id).toBe("dynamic-client");
	expect(storage.readClient("linear")?.client_id).toBe("dynamic-client");
});

test("fails loudly when no automatic registration path exists", async () => {
	await expect(
		resolveClientRegistration({
			serverId: "linear",
			authConfig: { type: "oauth", registration: { type: "dynamic" } },
			authorizationServerMetadata: metadata(),
			storage: new McpOAuthStorage({ homeDir: root }),
			fetch: async () => {
				throw new Error("fetch must not be called");
			},
			redirectUri: "http://127.0.0.1:1234/mcp/oauth/callback",
		}),
	).rejects.toThrow(/user-provided/);
});

test("dynamic registration persists returned client information", async () => {
	const storage = new McpOAuthStorage({ homeDir: root });

	await resolveClientRegistration({
		serverId: "linear",
		authConfig: { type: "oauth", registration: { type: "dynamic" } },
		authorizationServerMetadata: metadata({
			registration_endpoint: "https://auth.example.com/register",
		}),
		storage,
		fetch: async () =>
			new Response(JSON.stringify({ client_id: "dynamic-client" }), {
				status: 201,
				headers: { "content-type": "application/json" },
			}),
		redirectUri: "http://127.0.0.1:1234/mcp/oauth/callback",
	});

	expect(storage.readClient("linear")).toEqual({ client_id: "dynamic-client" });
});
