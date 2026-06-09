import {
	RPCMethod,
	type McpAddParams,
	type McpConnectParams,
	type McpDeleteParams,
	type McpDisconnectParams,
	type McpGetConfigParams,
	type McpServerStatusInfo,
	type McpUpdateParams,
} from "../rpc/rpc-types";
import type { Dispatcher } from "../rpc/dispatcher";
import {
	addMcpServerConfig,
	deleteMcpServerConfig,
	getMcpServerConfig,
	updateMcpServerConfig,
} from "./config";
import type { McpHostService } from "./host-service";
import type { McpAuthRuntime } from "./auth/runtime";

export function registerMcpHandlers(
	dispatcher: Dispatcher,
	hostService: McpHostService,
	authRuntime: McpAuthRuntime,
): void {
	const authStatuses = () => authRuntime.status().servers;
	const notifyStatus = (server: McpServerStatusInfo) => {
		dispatcher.notify(RPCMethod.mcpStatusChanged, { server });
	};
	const statusFor = (serverId: string): McpServerStatusInfo => {
		const server = hostService
			.status(authStatuses())
			.find((candidate) => candidate.serverId === serverId);
		if (!server) throw new Error(`Unknown MCP server "${serverId}"`);
		return server;
	};

	dispatcher.registerRequest(RPCMethod.mcpStatus, async () => ({
		servers: hostService.status(authStatuses()),
	}));
	dispatcher.registerRequest(RPCMethod.mcpGetConfig, async (raw) => {
		const params = raw as McpGetConfigParams;
		return { config: getMcpServerConfig(params.serverId) };
	});
	dispatcher.registerRequest(RPCMethod.mcpAdd, async (raw) => {
		const params = raw as McpAddParams;
		if (
			hostService.hasServer(params.serverId) ||
			authRuntime.hasServer(params.serverId)
		) {
			throw new Error(`MCP server "${params.serverId}" already exists`);
		}
		const nextConfig = addMcpServerConfig(params);
		const serverConfig = nextConfig.servers[params.serverId];
		if (!serverConfig)
			throw new Error(`MCP server "${params.serverId}" was not written`);
		authRuntime.addServer(params.serverId, serverConfig);
		const server = hostService.addServer(
			params.serverId,
			serverConfig,
			authStatuses(),
		);
		notifyStatus(server);
		return { server };
	});
	dispatcher.registerRequest(RPCMethod.mcpUpdate, async (raw) => {
		const params = raw as McpUpdateParams;
		if (
			!hostService.hasServer(params.serverId) ||
			!authRuntime.hasServer(params.serverId)
		) {
			throw new Error(`Unknown MCP server "${params.serverId}"`);
		}
		const nextConfig = updateMcpServerConfig(params);
		const serverConfig = nextConfig.servers[params.serverId];
		if (!serverConfig)
			throw new Error(`MCP server "${params.serverId}" was not written`);
		authRuntime.updateServer(params.serverId, serverConfig);
		const server = await hostService.updateServer(
			params.serverId,
			serverConfig,
			authStatuses(),
		);
		notifyStatus(server);
		return { server };
	});
	dispatcher.registerRequest(RPCMethod.mcpConnect, async (raw) => {
		const params = raw as McpConnectParams;
		try {
			const server = await hostService.connectServer(
				params.serverId,
				authStatuses(),
			);
			notifyStatus(server);
			return { server };
		} catch (err) {
			notifyStatus(statusFor(params.serverId));
			throw err;
		}
	});
	dispatcher.registerRequest(RPCMethod.mcpDisconnect, async (raw) => {
		const params = raw as McpDisconnectParams;
		const server = await hostService.disconnectServer(
			params.serverId,
			authStatuses(),
		);
		notifyStatus(server);
		return { server };
	});
	dispatcher.registerRequest(RPCMethod.mcpDelete, async (raw) => {
		const params = raw as McpDeleteParams;
		await hostService.disconnectServer(params.serverId, authStatuses());
		deleteMcpServerConfig(params.serverId);
		await hostService.removeServer(params.serverId);
		authRuntime.removeServer(params.serverId);
		return { deleted: true };
	});
}
