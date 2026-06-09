import { McpServer, StdioServerTransport } from "@modelcontextprotocol/server";
import * as z from "zod/v4";

const server = new McpServer({
	name: "notch-agent-fake-mcp-server",
	version: "0.1.0",
});

server.registerTool(
	"echo",
	{
		description: "Echo a message",
		inputSchema: z.object({ message: z.string() }),
	},
	async ({ message }) => ({
		content: [{ type: "text", text: `echo:${message}` }],
	}),
);

await server.connect(new StdioServerTransport());
