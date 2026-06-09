import { expect, test } from "bun:test";
import {
	discoverAuthorizationServer,
	discoverProtectedResource,
} from "../src/mcp/auth/discovery";

function json(data: unknown, init: ResponseInit = {}): Response {
	return new Response(JSON.stringify(data), {
		status: init.status ?? 200,
		headers: { "content-type": "application/json", ...init.headers },
	});
}

function notFound(): Response {
	return new Response("not found", { status: 404 });
}

test("uses resource_metadata from 401 challenge before well-known fallback", async () => {
	const calls: string[] = [];
	const fetchFn = async (url: string | URL) => {
		calls.push(String(url));
		return json({
			resource: "https://mcp.example.com/mcp",
			authorization_servers: ["https://auth.example.com"],
			scopes_supported: ["tools:read"],
		});
	};

	const metadata = await discoverProtectedResource({
		serverUrl: "https://mcp.example.com/mcp",
		challengeHeader:
			'Bearer resource_metadata="https://mcp.example.com/prm", scope="tools:call"',
		fetch: fetchFn,
	});

	expect(metadata.authorization_servers).toEqual(["https://auth.example.com"]);
	expect(metadata.challengeScope).toBe("tools:call");
	expect(calls).toEqual(["https://mcp.example.com/prm"]);
});

test("falls back to endpoint-path protected resource metadata URL first", async () => {
	const calls: string[] = [];
	const fetchFn = async (url: string | URL) => {
		calls.push(String(url));
		return json({
			resource: "https://mcp.example.com/mcp",
			authorization_servers: ["https://auth.example.com"],
		});
	};

	await discoverProtectedResource({
		serverUrl: "https://mcp.example.com/mcp",
		fetch: fetchFn,
	});

	expect(calls[0]).toBe(
		"https://mcp.example.com/.well-known/oauth-protected-resource/mcp",
	);
});

test("falls back to root protected resource metadata URL second", async () => {
	const calls: string[] = [];
	const fetchFn = async (url: string | URL) => {
		calls.push(String(url));
		if (calls.length === 1) return notFound();
		return json({
			resource: "https://mcp.example.com/mcp",
			authorization_servers: ["https://auth.example.com"],
		});
	};

	await discoverProtectedResource({
		serverUrl: "https://mcp.example.com/mcp",
		fetch: fetchFn,
	});

	expect(calls).toEqual([
		"https://mcp.example.com/.well-known/oauth-protected-resource/mcp",
		"https://mcp.example.com/.well-known/oauth-protected-resource",
	]);
});

test("requires authorization_servers in protected resource metadata", async () => {
	await expect(
		discoverProtectedResource({
			serverUrl: "https://mcp.example.com/mcp",
			fetch: async () => json({ resource: "https://mcp.example.com/mcp" }),
		}),
	).rejects.toThrow(/authorization_servers/);
});

test("discovers OAuth authorization server metadata for path issuer in spec order", async () => {
	const calls: string[] = [];
	const fetchFn = async (url: string | URL) => {
		calls.push(String(url));
		return json({
			issuer: "https://auth.example.com/tenant",
			authorization_endpoint: "https://auth.example.com/tenant/authorize",
			token_endpoint: "https://auth.example.com/tenant/token",
			code_challenge_methods_supported: ["S256"],
		});
	};

	const metadata = await discoverAuthorizationServer({
		issuer: "https://auth.example.com/tenant",
		fetch: fetchFn,
	});

	expect(metadata.token_endpoint).toBe("https://auth.example.com/tenant/token");
	expect(calls[0]).toBe(
		"https://auth.example.com/.well-known/oauth-authorization-server/tenant",
	);
});

test("discovers OIDC metadata fallback for path issuer", async () => {
	const calls: string[] = [];
	const fetchFn = async (url: string | URL) => {
		calls.push(String(url));
		if (calls.length < 2) return notFound();
		return json({
			issuer: "https://auth.example.com/tenant",
			authorization_endpoint: "https://auth.example.com/tenant/authorize",
			token_endpoint: "https://auth.example.com/tenant/token",
			code_challenge_methods_supported: ["S256"],
		});
	};

	await discoverAuthorizationServer({
		issuer: "https://auth.example.com/tenant",
		fetch: fetchFn,
	});

	expect(calls[1]).toBe(
		"https://auth.example.com/.well-known/openid-configuration/tenant",
	);
});

test("requires code_challenge_methods_supported to include S256", async () => {
	await expect(
		discoverAuthorizationServer({
			issuer: "https://auth.example.com",
			fetch: async () =>
				json({
					issuer: "https://auth.example.com",
					authorization_endpoint: "https://auth.example.com/authorize",
					token_endpoint: "https://auth.example.com/token",
					code_challenge_methods_supported: ["plain"],
				}),
		}),
	).rejects.toThrow(/S256/);
});
