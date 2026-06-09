import { afterEach, beforeEach, expect, test } from "bun:test";
import {
	chmodSync,
	mkdtempSync,
	readFileSync,
	statSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { rmSync } from "node:fs";
import {
	McpOAuthStorage,
	type McpOAuthTokenRecord,
} from "../src/mcp/auth/storage";

let root: string;

beforeEach(() => {
	root = mkdtempSync(join(tmpdir(), "notch-agent-mcp-auth-storage-test-"));
});

afterEach(() => {
	chmodSync(root, 0o700);
	rmSync(root, { recursive: true, force: true });
});

function token(): McpOAuthTokenRecord {
	return {
		accessToken: "access",
		refreshToken: "refresh",
		expiresAt: Date.now() + 60_000,
		tokenType: "Bearer",
		scopes: ["read"],
		resource: "https://example.com/mcp",
		authorizationServerUrl: "https://auth.example.com",
	};
}

test("token path is ~/.notch-agent/auth/mcp/<serverId>/tokens.json", () => {
	const storage = new McpOAuthStorage({ homeDir: root });
	expect(storage.paths("linear").tokens).toBe(
		join(root, ".notch-agent", "auth", "mcp", "linear", "tokens.json"),
	);
});

test("writes token/client/verifier/discovery files atomically with 0600 mode", () => {
	const storage = new McpOAuthStorage({ homeDir: root });

	storage.writeTokens("linear", token());
	storage.writeClient("linear", {
		client_id: "client",
		client_secret: "secret",
	});
	storage.writeVerifier("linear", {
		codeVerifier: "verifier",
		state: "state",
		redirectUri: "http://127.0.0.1:1234/mcp/oauth/callback",
		resource: "https://example.com/mcp",
		scope: "read",
	});
	storage.writeDiscovery("linear", {
		authorizationServerUrl: "https://auth.example.com",
		resource: "https://example.com/mcp",
	});

	const paths = storage.paths("linear");
	for (const file of [
		paths.tokens,
		paths.client,
		paths.verifier,
		paths.discovery,
	]) {
		expect(statSync(file).mode & 0o777).toBe(0o600);
		expect(readFileSync(file, "utf-8")).toStartWith("{");
	}
});

test("auth directory is created with 0700 mode", () => {
	const storage = new McpOAuthStorage({ homeDir: root });

	storage.writeTokens("linear", token());

	expect(statSync(storage.paths("linear").dir).mode & 0o777).toBe(0o700);
});

test("read missing token returns null for passive status", () => {
	const storage = new McpOAuthStorage({ homeDir: root });

	expect(storage.readTokens("linear", { passive: true })).toBeNull();
});

test("active token read throws typed error for malformed token file", () => {
	const storage = new McpOAuthStorage({ homeDir: root });
	storage.writeTokens("linear", token());
	writeFileSync(storage.paths("linear").tokens, "{broken", "utf-8");

	expect(() => storage.readTokens("linear")).toThrow(/Malformed MCP OAuth/);
});

test("clear server auth deletes token, client, verifier, and discovery files", () => {
	const storage = new McpOAuthStorage({ homeDir: root });
	storage.writeTokens("linear", token());
	storage.writeClient("linear", { client_id: "client" });
	storage.writeVerifier("linear", {
		codeVerifier: "verifier",
		state: "state",
		redirectUri: "http://127.0.0.1:1234/mcp/oauth/callback",
		resource: "https://example.com/mcp",
	});
	storage.writeDiscovery("linear", {
		authorizationServerUrl: "https://auth.example.com",
		resource: "https://example.com/mcp",
	});

	expect(storage.clearServerAuth("linear")).toBe(true);
	expect(storage.readTokens("linear", { passive: true })).toBeNull();
	expect(storage.readClient("linear", { passive: true })).toBeNull();
	expect(storage.readVerifier("linear", { passive: true })).toBeNull();
	expect(storage.readDiscovery("linear", { passive: true })).toBeNull();
});
