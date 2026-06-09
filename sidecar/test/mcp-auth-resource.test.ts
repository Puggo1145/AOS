import { expect, test } from "bun:test";
import {
	canonicalMcpResourceUri,
	validateConfiguredResource,
} from "../src/mcp/auth/resource";

test("canonical resource preserves endpoint path when present", () => {
	expect(canonicalMcpResourceUri("https://example.com/mcp")).toBe(
		"https://example.com/mcp",
	);
});

test("canonical resource lowercases scheme and host", () => {
	expect(canonicalMcpResourceUri("HTTPS://EXAMPLE.COM/MCP")).toBe(
		"https://example.com/MCP",
	);
});

test("canonical resource removes fragment and rejects configured fragments", () => {
	expect(canonicalMcpResourceUri("https://example.com/mcp#token")).toBe(
		"https://example.com/mcp",
	);
	expect(() =>
		validateConfiguredResource(
			"https://example.com/mcp",
			"https://example.com/mcp#token",
		),
	).toThrow(/fragment/);
});

test("trailing slash is removed unless path is semantically non-root", () => {
	expect(canonicalMcpResourceUri("https://example.com/")).toBe(
		"https://example.com/",
	);
	expect(canonicalMcpResourceUri("https://example.com/mcp/")).toBe(
		"https://example.com/mcp",
	);
});

test("configured resource must match the server origin or exact endpoint policy", () => {
	expect(
		validateConfiguredResource(
			"https://example.com/mcp",
			"https://example.com/mcp",
		),
	).toBe("https://example.com/mcp");
	expect(
		validateConfiguredResource(
			"https://example.com/mcp",
			"https://example.com",
		),
	).toBe("https://example.com/");
	expect(() =>
		validateConfiguredResource(
			"https://example.com/mcp",
			"https://other.example.com/mcp",
		),
	).toThrow(/origin/);
	expect(() =>
		validateConfiguredResource(
			"https://example.com/mcp",
			"https://example.com/other",
		),
	).toThrow(/path/);
});
