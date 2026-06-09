import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ToolRegistry } from "../src/agent/tools";
import { MalformedMcpConfigError, mcpConfigPath } from "../src/mcp/config";
import { bootstrapMcpHost } from "../src/mcp/bootstrap";

let originalHome: string | undefined;
let tmpHome: string;

beforeEach(() => {
	originalHome = process.env.HOME;
	tmpHome = mkdtempSync(join(tmpdir(), "notch-agent-mcp-bootstrap-test-"));
	process.env.HOME = tmpHome;
});

afterEach(() => {
	if (originalHome === undefined) delete process.env.HOME;
	else process.env.HOME = originalHome;
	rmSync(tmpHome, { recursive: true, force: true });
});

function writeMcpRaw(content: string): void {
	mkdirSync(join(tmpHome, ".notch-agent"), { recursive: true });
	writeFileSync(mcpConfigPath(), content, "utf-8");
}

test("valid empty MCP config registers the stable meta-tools", () => {
	const registry = new ToolRegistry();

	bootstrapMcpHost(registry);

	expect(registry.list().map((handler) => handler.spec.name)).toEqual([
		"mcp_search_tools",
		"mcp_get_tool_details",
		"mcp_call_tool",
	]);
});

test("invalid MCP config fails loudly during bootstrap", () => {
	writeMcpRaw("{ not json");
	const registry = new ToolRegistry();

	expect(() => bootstrapMcpHost(registry)).toThrow(MalformedMcpConfigError);
});

test("configured MCP servers are lazy and do not create client sessions during bootstrap", () => {
	const registry = new ToolRegistry();
	let created = 0;

	bootstrapMcpHost(registry, {
		config: {
			servers: {
				filesystem: {
					description: "Local tools",
					transport: { type: "stdio", command: "node", args: [], env: {} },
				},
			},
		},
		createSession() {
			created += 1;
			throw new Error("session creation should be lazy");
		},
	});

	expect(created).toBe(0);
	expect(registry.get("mcp_search_tools")).toBeDefined();
});
