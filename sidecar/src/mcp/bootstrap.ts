import type { ToolRegistry } from "../agent/tools";
import { readMcpConfig, type McpConfig } from "./config";
import {
	McpHostService,
	type McpClientSessionLike,
	type McpHostServiceOptions,
} from "./host-service";
import { registerMcpTools } from "./tools";

export interface McpBootstrapOptions {
	config?: McpConfig;
	createSession?: McpHostServiceOptions["createSession"];
	authRuntime?: McpHostServiceOptions["authRuntime"];
}

export function bootstrapMcpHost(
	registry: ToolRegistry,
	options: McpBootstrapOptions = {},
): McpHostService {
	const config = options.config ?? readMcpConfig();
	const hostService = new McpHostService(config, {
		createSession: options.createSession,
		authRuntime: options.authRuntime,
	});
	registerMcpTools(registry, hostService);
	return hostService;
}

export type { McpClientSessionLike };
