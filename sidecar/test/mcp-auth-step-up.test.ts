import { expect, test } from "bun:test";
import type { McpConfig } from "../src/mcp/config";
import type { McpClientSessionLike } from "../src/mcp/host-service";
import { McpHostService } from "../src/mcp/host-service";
import { McpInsufficientScopeError } from "../src/mcp/auth/errors";

function config(): McpConfig {
	return {
		servers: {
			linear: {
				description: "Issue tracker",
				transport: {
					type: "streamableHttp",
					url: "https://example.com/mcp",
					headers: {},
					auth: { type: "oauth", registration: { type: "dynamic" } },
				},
			},
		},
	};
}

test("step-up success retries original tool call once", async () => {
	let callCount = 0;
	const stepUps: unknown[] = [];
	const session: McpClientSessionLike = {
		async listTools() {
			return [{ name: "create_issue", description: "Create issue" }];
		},
		async callTool() {
			callCount += 1;
			if (callCount === 1)
				throw new McpInsufficientScopeError("linear", "write");
			return { content: [{ type: "text", text: "ok" }], isError: false };
		},
		invalidateToolCache() {},
		async close() {},
	};
	const service = new McpHostService(config(), {
		createSession: () => session,
		authRuntime: {
			async startStepUp(input) {
				stepUps.push(input);
			},
		},
	});

	expect(await service.callTool("linear.create_issue", {})).toEqual({
		content: [{ type: "text", text: "ok" }],
		isError: false,
	});
	expect(stepUps).toEqual([
		{ serverId: "linear", operation: "create_issue", scope: "write" },
	]);
});

test("repeated step-up for same server operation and scope fails permanently", async () => {
	const session: McpClientSessionLike = {
		async listTools() {
			return [{ name: "create_issue", description: "Create issue" }];
		},
		async callTool() {
			throw new McpInsufficientScopeError("linear", "write");
		},
		invalidateToolCache() {},
		async close() {},
	};
	const service = new McpHostService(config(), {
		createSession: () => session,
		authRuntime: {
			async startStepUp() {},
		},
	});

	await expect(service.callTool("linear.create_issue", {})).rejects.toThrow(
		McpInsufficientScopeError,
	);
});
