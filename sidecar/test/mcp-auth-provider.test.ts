import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { McpOAuthStorage } from "../src/mcp/auth/storage";
import { NotchMcpOAuthProvider } from "../src/mcp/auth/provider";
import type { McpOAuthAuthConfig } from "../src/mcp/auth/config";

let root: string;

beforeEach(() => {
	root = mkdtempSync(join(tmpdir(), "notch-agent-mcp-auth-provider-test-"));
});

afterEach(() => {
	rmSync(root, { recursive: true, force: true });
});

function config(): McpOAuthAuthConfig {
	return {
		type: "oauth",
		registration: { type: "preRegistered", clientId: "client" },
	};
}

test("tokens reads and saves server-scoped token records", async () => {
	const storage = new McpOAuthStorage({ homeDir: root });
	storage.writeDiscovery("linear", {
		authorizationServerUrl: "https://auth.example.com",
		resource: "https://example.com/mcp",
	});
	const provider = new NotchMcpOAuthProvider({
		serverId: "linear",
		serverUrl: "https://example.com/mcp",
		authConfig: {
			type: "oauth",
			registration: {
				type: "preRegistered",
				clientId: "client",
				clientSecret: "secret",
			},
		},
		storage,
		redirectUrl: "http://127.0.0.1:1234/mcp/oauth/callback",
	});

	await provider.saveTokens({
		access_token: "access",
		refresh_token: "refresh",
		token_type: "Bearer",
		expires_in: 60,
		scope: "tools:read",
	});

	expect(await provider.tokens()).toMatchObject({
		access_token: "access",
		refresh_token: "refresh",
		token_type: "Bearer",
		scope: "tools:read",
	});
});

test("saveCodeVerifier and codeVerifier use verifier storage", async () => {
	const storage = new McpOAuthStorage({ homeDir: root });
	const provider = new NotchMcpOAuthProvider({
		serverId: "linear",
		serverUrl: "https://example.com/mcp",
		authConfig: config(),
		storage,
		redirectUrl: "http://127.0.0.1:1234/mcp/oauth/callback",
		state: "state-123",
	});

	await provider.saveCodeVerifier("verifier-123");

	expect(await provider.codeVerifier()).toBe("verifier-123");
	expect(storage.readVerifier("linear")?.state).toBe("state-123");
});

test("redirectToAuthorization emits Shell-openable login status", async () => {
	const notifications: unknown[] = [];
	const provider = new NotchMcpOAuthProvider({
		serverId: "linear",
		serverUrl: "https://example.com/mcp",
		authConfig: config(),
		storage: new McpOAuthStorage({ homeDir: root }),
		redirectUrl: "http://127.0.0.1:1234/mcp/oauth/callback",
		loginId: "login-123",
		notifyLoginStatus: (params) => notifications.push(params),
	});

	await provider.redirectToAuthorization(new URL("https://auth.example.com/a"));

	expect(notifications).toEqual([
		{
			loginId: "login-123",
			serverId: "linear",
			state: "awaitingBrowser",
			authorizeUrl: "https://auth.example.com/a",
		},
	]);
});

test("validateResourceURL rejects resource mismatch", async () => {
	const provider = new NotchMcpOAuthProvider({
		serverId: "linear",
		serverUrl: "https://example.com/mcp",
		authConfig: config(),
		storage: new McpOAuthStorage({ homeDir: root }),
		redirectUrl: "http://127.0.0.1:1234/mcp/oauth/callback",
	});

	await expect(
		provider.validateResourceURL(
			"https://example.com/mcp",
			"https://other.example.com/mcp",
		),
	).rejects.toThrow(/origin/);
});

test("invalidateCredentials deletes requested scopes and notifies statusChanged", async () => {
	const storage = new McpOAuthStorage({ homeDir: root });
	const notifications: unknown[] = [];
	storage.writeTokens("linear", {
		accessToken: "access",
		tokenType: "Bearer",
		scopes: ["tools:read"],
		resource: "https://example.com/mcp",
		authorizationServerUrl: "https://auth.example.com",
	});
	const provider = new NotchMcpOAuthProvider({
		serverId: "linear",
		serverUrl: "https://example.com/mcp",
		authConfig: config(),
		storage,
		redirectUrl: "http://127.0.0.1:1234/mcp/oauth/callback",
		notifyStatusChanged: (params) => notifications.push(params),
	});

	await provider.invalidateCredentials("tokens");

	expect(storage.readTokens("linear", { passive: true })).toBeNull();
	expect(notifications).toEqual([
		{
			serverId: "linear",
			state: "unauthenticated",
			reason: "authInvalidated",
		},
	]);
});

test("public clients leave token request authentication to the SDK default", () => {
	const provider = new NotchMcpOAuthProvider({
		serverId: "linear",
		serverUrl: "https://example.com/mcp",
		authConfig: config(),
		storage: new McpOAuthStorage({ homeDir: root }),
		redirectUrl: "http://127.0.0.1:1234/mcp/oauth/callback",
	});

	expect("addClientAuthentication" in provider).toBe(false);
});
