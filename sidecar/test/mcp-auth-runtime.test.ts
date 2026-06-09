import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { OAuthClientProvider } from "@modelcontextprotocol/client";
import { McpAuthRuntime } from "../src/mcp/auth/runtime";
import { McpOAuthStorage } from "../src/mcp/auth/storage";
import type { McpConfig } from "../src/mcp/config";

let root: string;

beforeEach(() => {
	root = mkdtempSync(join(tmpdir(), "notch-agent-mcp-auth-runtime-test-"));
});

afterEach(() => {
	rmSync(root, { recursive: true, force: true });
});

function config(): McpConfig {
	return {
		servers: {
			local: {
				description: "Local",
				transport: { type: "stdio", command: "node", args: [], env: {} },
			},
			linear: {
				description: "Linear",
				transport: {
					type: "streamableHttp",
					url: "https://mcp.example.com/mcp",
					headers: {},
					auth: { type: "oauth", registration: { type: "dynamic" } },
				},
			},
		},
	};
}

async function waitUntil(
	predicate: () => boolean,
	label: string,
): Promise<void> {
	const deadline = Date.now() + 1_000;
	while (Date.now() < deadline) {
		if (predicate()) return;
		await new Promise((resolve) => setTimeout(resolve, 5));
	}
	throw new Error(`Timed out waiting for ${label}`);
}

async function resolveRedirectUrl(
	provider: OAuthClientProvider,
): Promise<string> {
	const value = await provider.redirectUrl;
	if (value === undefined)
		throw new Error("OAuth provider redirectUrl missing");
	return value.toString();
}

async function resolveState(provider: OAuthClientProvider): Promise<string> {
	const value = await provider.state?.();
	if (value === undefined) throw new Error("OAuth provider state missing");
	return value;
}

test("status reports oauth server unauthenticated when token is missing", () => {
	const runtime = new McpAuthRuntime({
		config: config(),
		storage: new McpOAuthStorage({ homeDir: root }),
	});

	expect(runtime.status().servers).toContainEqual({
		serverId: "linear",
		state: "unauthenticated",
		authType: "oauth",
	});
});

test("status reports streamable HTTP static headers as headers auth", () => {
	const base = config();
	base.servers.headers = {
		description: "Headers",
		transport: {
			type: "streamableHttp",
			url: "https://mcp.example.com/mcp",
			headers: { "X-API-Key": "secret" },
		},
	};
	const runtime = new McpAuthRuntime({
		config: base,
		storage: new McpOAuthStorage({ homeDir: root }),
	});

	expect(runtime.status().servers).toContainEqual({
		serverId: "headers",
		state: "ready",
		authType: "headers",
	});
});

test("startLogin emits starting then awaitingBrowser with authorizeUrl", async () => {
	const notifications: unknown[] = [];
	const runtime = new McpAuthRuntime({
		config: config(),
		storage: new McpOAuthStorage({ homeDir: root }),
		notify: (method, params) => notifications.push({ method, params }),
		runAuth: async (provider: OAuthClientProvider) => {
			await provider.redirectToAuthorization(
				new URL("https://auth.example.com/a"),
			);
			await provider.saveCodeVerifier("verifier");
			return "REDIRECT";
		},
	});

	const result = await runtime.startLogin({ serverId: "linear" });

	expect(result.authorizeUrl).toBe("https://auth.example.com/a");
	expect(
		notifications
			.map((n) => (n as { params: { state: string } }).params.state)
			.slice(0, 2),
	).toEqual(["starting", "awaitingBrowser"]);
});

test("cancelLogin closes loopback and emits cancelled exactly once", async () => {
	const notifications: unknown[] = [];
	const storage = new McpOAuthStorage({ homeDir: root });
	const runtime = new McpAuthRuntime({
		config: config(),
		storage,
		notify: (method, params) => notifications.push({ method, params }),
		runAuth: async (provider: OAuthClientProvider) => {
			await provider.saveCodeVerifier("verifier");
			await provider.redirectToAuthorization(
				new URL("https://auth.example.com/a"),
			);
			return "REDIRECT";
		},
	});
	const { loginId } = await runtime.startLogin({ serverId: "linear" });

	expect(runtime.cancelLogin({ loginId })).toEqual({ cancelled: true });
	await new Promise((resolve) => setTimeout(resolve, 5));

	expect(
		notifications.filter(
			(n) => (n as { params: { state?: string } }).params.state === "cancelled",
		),
	).toHaveLength(1);
	expect(notifications).toContainEqual({
		method: "mcp.auth.statusChanged",
		params: {
			serverId: "linear",
			state: "unauthenticated",
		},
	});
	expect(storage.readVerifier("linear", { passive: true })).toBeNull();
});

test("startLogin pre-redirect failure clears inflight session and verifier", async () => {
	const notifications: unknown[] = [];
	const storage = new McpOAuthStorage({ homeDir: root });
	let attempts = 0;
	const runtime = new McpAuthRuntime({
		config: config(),
		storage,
		notify: (method, params) => notifications.push({ method, params }),
		runAuth: async (provider: OAuthClientProvider) => {
			attempts += 1;
			await provider.saveCodeVerifier(`verifier-${attempts}`);
			if (attempts === 1) {
				throw new Error("metadata unavailable");
			}
			await provider.redirectToAuthorization(
				new URL("https://auth.example.com/a"),
			);
			return "REDIRECT";
		},
	});

	await expect(runtime.startLogin({ serverId: "linear" })).rejects.toThrow(
		/metadata unavailable/,
	);
	expect(storage.readVerifier("linear", { passive: true })).toBeNull();
	expect(
		notifications.some(
			(n) => (n as { params: { state?: string } }).params.state === "failed",
		),
	).toBe(true);

	const second = await runtime.startLogin({ serverId: "linear" });
	expect(second.authorizeUrl).toBe("https://auth.example.com/a");
});

test("successful login deletes verifier after token exchange", async () => {
	const storage = new McpOAuthStorage({ homeDir: root });
	const notifications: unknown[] = [];
	let redirectUrl = "";
	let state = "";
	const runtime = new McpAuthRuntime({
		config: config(),
		storage,
		notify: (method, params) => notifications.push({ method, params }),
		runAuth: async (provider: OAuthClientProvider, options) => {
			if (!options.authorizationCode) {
				redirectUrl = await resolveRedirectUrl(provider);
				state = await resolveState(provider);
				await provider.saveCodeVerifier("verifier-success");
				await provider.redirectToAuthorization(
					new URL("https://auth.example.com/a"),
				);
				return "REDIRECT";
			}
			await provider.saveTokens({
				access_token: "access",
				token_type: "Bearer",
				scope: "tools:read",
			});
			return "AUTHORIZED";
		},
	});

	await runtime.startLogin({ serverId: "linear" });
	await fetch(`${redirectUrl}?code=code-123&state=${state}`);
	await waitUntil(
		() =>
			notifications.some(
				(n) => (n as { params: { state?: string } }).params.state === "success",
			),
		"successful MCP OAuth login",
	);

	expect(storage.readVerifier("linear", { passive: true })).toBeNull();
});

test("token exchange failure deletes verifier and emits failed", async () => {
	const storage = new McpOAuthStorage({ homeDir: root });
	const notifications: unknown[] = [];
	let redirectUrl = "";
	let state = "";
	const runtime = new McpAuthRuntime({
		config: config(),
		storage,
		notify: (method, params) => notifications.push({ method, params }),
		runAuth: async (provider: OAuthClientProvider, options) => {
			if (!options.authorizationCode) {
				redirectUrl = await resolveRedirectUrl(provider);
				state = await resolveState(provider);
				await provider.saveCodeVerifier("verifier-failure");
				await provider.redirectToAuthorization(
					new URL("https://auth.example.com/a"),
				);
				return "REDIRECT";
			}
			throw new Error("token exchange failed");
		},
	});

	await runtime.startLogin({ serverId: "linear" });
	await fetch(`${redirectUrl}?code=code-123&state=${state}`);
	await waitUntil(
		() =>
			notifications.some(
				(n) => (n as { params: { state?: string } }).params.state === "failed",
			),
		"failed MCP OAuth login",
	);

	expect(storage.readVerifier("linear", { passive: true })).toBeNull();
});

test("logout clears server-scoped auth files and emits loggedOut", () => {
	const storage = new McpOAuthStorage({ homeDir: root });
	storage.writeTokens("linear", {
		accessToken: "access",
		tokenType: "Bearer",
		scopes: [],
		resource: "https://mcp.example.com/mcp",
		authorizationServerUrl: "https://auth.example.com",
	});
	const notifications: unknown[] = [];
	const runtime = new McpAuthRuntime({
		config: config(),
		storage,
		notify: (method, params) => notifications.push({ method, params }),
	});

	expect(runtime.logout({ serverId: "linear" })).toEqual({ cleared: true });
	expect(storage.readTokens("linear", { passive: true })).toBeNull();
	expect(notifications).toEqual([
		{
			method: "mcp.auth.statusChanged",
			params: {
				serverId: "linear",
				state: "unauthenticated",
				reason: "loggedOut",
			},
		},
	]);
});

test("updating OAuth transport auth material clears stored server auth", () => {
	const storage = new McpOAuthStorage({ homeDir: root });
	storage.writeTokens("linear", {
		accessToken: "access",
		tokenType: "Bearer",
		scopes: [],
		resource: "https://mcp.example.com/mcp",
		authorizationServerUrl: "https://auth.example.com",
	});
	storage.writeDiscovery("linear", {
		authorizationServerUrl: "https://auth.example.com",
		resource: "https://mcp.example.com/mcp",
	});
	const runtime = new McpAuthRuntime({
		config: config(),
		storage,
	});

	runtime.updateServer("linear", {
		description: "Linear",
		transport: {
			type: "streamableHttp",
			url: "https://other.example.com/mcp",
			headers: {},
			auth: { type: "oauth", registration: { type: "dynamic" } },
		},
	});

	expect(storage.readTokens("linear", { passive: true })).toBeNull();
	expect(storage.readDiscovery("linear", { passive: true })).toBeNull();
});

test("updating only OAuth server description preserves stored server auth", () => {
	const storage = new McpOAuthStorage({ homeDir: root });
	storage.writeTokens("linear", {
		accessToken: "access",
		tokenType: "Bearer",
		scopes: [],
		resource: "https://mcp.example.com/mcp",
		authorizationServerUrl: "https://auth.example.com",
	});
	const runtime = new McpAuthRuntime({
		config: config(),
		storage,
	});

	runtime.updateServer("linear", {
		description: "Renamed Linear",
		transport: {
			type: "streamableHttp",
			url: "https://mcp.example.com/mcp",
			headers: {},
			auth: { type: "oauth", registration: { type: "dynamic" } },
		},
	});

	expect(storage.readTokens("linear", { passive: true })?.accessToken).toBe(
		"access",
	);
});
