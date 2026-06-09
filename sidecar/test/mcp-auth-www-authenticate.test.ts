import { expect, test } from "bun:test";
import { parseBearerChallenge } from "../src/mcp/auth/www-authenticate";

test("parses Bearer resource_metadata and scope", () => {
	expect(
		parseBearerChallenge(
			'Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp", scope="tools:read tools:call"',
		),
	).toEqual({
		scheme: "Bearer",
		resourceMetadata:
			"https://mcp.example.com/.well-known/oauth-protected-resource/mcp",
		scope: "tools:read tools:call",
	});
});

test("parses insufficient_scope error", () => {
	expect(
		parseBearerChallenge(
			'Bearer error="insufficient_scope", scope="tools:call"',
		),
	).toMatchObject({
		error: "insufficient_scope",
		scope: "tools:call",
	});
});

test("rejects non-Bearer challenge for MCP OAuth", () => {
	expect(() => parseBearerChallenge('Basic realm="mcp"')).toThrow(/Bearer/);
});

test("handles comma inside quoted error_description", () => {
	expect(
		parseBearerChallenge(
			'Bearer error="invalid_token", error_description="expired, revoked, or malformed"',
		).errorDescription,
	).toBe("expired, revoked, or malformed");
});

test("rejects malformed quoted parameters loudly", () => {
	expect(() =>
		parseBearerChallenge('Bearer resource_metadata="https://example.com'),
	).toThrow(/malformed/i);
});
