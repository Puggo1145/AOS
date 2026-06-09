import { expect, test } from "bun:test";
import { join } from "node:path";
import { McpHostService } from "../src/mcp/host-service";

test("local stdio MCP server connects, discovers, inspects, and executes through the host broker", async () => {
	const service = new McpHostService({
		servers: {
			fake: {
				description: "Fake echo MCP server",
				transport: {
					type: "stdio",
					command: process.execPath,
					args: [join(import.meta.dir, "fixtures", "fake-mcp-server.ts")],
					env: {},
				},
			},
		},
	});

	try {
		const search = await service.searchTools("echo");
		expect(search.matches).toEqual([
			{
				serverId: "fake",
				description: "Fake echo MCP server",
				tools: [
					{
						name: "fake.echo",
						serverId: "fake",
						toolName: "echo",
						description: "Echo a message",
					},
				],
			},
		]);
		expect(JSON.stringify(search)).not.toContain("inputSchema");

		const details = await service.getToolDetails("fake.echo");
		expect(details.inputSchema).toMatchObject({
			type: "object",
			properties: { message: { type: "string" } },
		});

		const result = await service.callTool("fake.echo", { message: "hello" });
		expect(result.content).toEqual([{ type: "text", text: "echo:hello" }]);
		expect(result.isError ?? false).toBe(false);
	} finally {
		await service.closeAll();
	}
});
