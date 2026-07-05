// Notch Agent sidecar entry point. Bun executes this file as the child process.
//
// Lifecycle (per docs/designs/rpc-protocol.md §"版本协商"):
//   1. Start the dispatcher reader so we can receive the rpc.hello response.
//   2. Send rpc.hello as the FIRST frame on the wire. Shell rejects any
//      business method before this handshake completes.
//   3. On MAJOR version mismatch, exit non-zero so the Shell can surface the
//      error and stop respawning.
//   4. Register the long-lived business handlers (agent.submit / agent.cancel
//      via registerAgentHandlers, rpc.ping for health checks) and idle.

import { StdioTransport } from "./rpc/transport";
import { Dispatcher } from "./rpc/dispatcher";
import { registerAgentHandlers } from "./agent/handlers";
import { SessionManager } from "./agent/session/manager";
import { registerSessionHandlers } from "./agent/session/handlers";
import { registerProviderHandlers } from "./auth/register";
import { registerConfigHandlers } from "./config/handlers";
import { readPermissionLevel } from "./config/storage";
import {
	registerBuiltinTools,
	registerComputerUseTools,
	registerTodoTool,
	toolRegistry,
} from "./agent/tools";
import { registerBuiltinAmbient } from "./agent/ambient";
import {
	assertRegisteredToolsMatchPermissionPolicies,
	builtinPermissionPolicyCatalog,
	PermissionGateway,
} from "./agent/permissions";
import { ensureWorkspace } from "./agent/workspace";
import { logger } from "./log";
import {
	NOTCH_PROTOCOL_VERSION,
	RPCMethod,
	type HelloResult,
} from "./rpc/rpc-types";
import { bootstrapMcpHost } from "./mcp/bootstrap";
import { McpClientSession } from "./mcp/client-session";
import { readMcpConfig } from "./mcp/config";
import { McpOAuthStorage } from "./mcp/auth/storage";
import { McpAuthRuntime } from "./mcp/auth/runtime";
import { registerMcpAuthHandlers } from "./mcp/auth/handlers";
import { registerMcpHandlers } from "./mcp/handlers";
import { registerBuiltinLlmProviders } from "./llm";

/// Global, transport-independent bootstrap: register built-in LLM API
/// providers (openai-responses, openai-completions, deepseek), ensure the
/// agent's workspace directory exists, and register every built-in tool +
/// ambient provider into their respective global registries.
///
/// Ordering constraint that must survive any future edit here: LLM provider
/// registration must run first — session/tool bootstrap doesn't touch models,
/// but any future ordering change must keep this ahead of model resolution.
function bootstrapAgentRuntime(): void {
	registerBuiltinLlmProviders();
	// Side-effect bootstrap: ensure ~/.notch-agent/workspace/ exists (the agent's
	// default scratch directory) and register every built-in tool into the
	// global ToolRegistry before the agent loop ever runs.
	ensureWorkspace();
	registerBuiltinTools();
	// Built-in ambient providers: today only the per-session todos block.
	// Registered alongside the tool registry so every turn assembled below
	// sees a populated ambient registry.
	registerBuiltinAmbient();
}

/// Construct the MCP host service + auth runtime. Depends on `dispatcher`
/// (auth runtime notifies over it) and the global `toolRegistry` (the host
/// service registers each connected server's tools into it) — must run
/// after `registerComputerUseTools` and before the permission-catalog
/// assertion, since both register tools that assertion checks against.
function bootstrapMcp(dispatcher: Dispatcher): {
	mcpAuthRuntime: McpAuthRuntime;
	mcpHostService: ReturnType<typeof bootstrapMcpHost>;
} {
	const mcpConfig = readMcpConfig();
	const mcpAuthRuntime = new McpAuthRuntime({
		config: mcpConfig,
		storage: new McpOAuthStorage(),
		notify(method, params) {
			dispatcher.notify(method, params);
		},
	});
	const mcpHostService = bootstrapMcpHost(toolRegistry, {
		config: mcpConfig,
		createSession(serverId, serverConfig) {
			return new McpClientSession(serverId, serverConfig, {
				createOAuthProvider(id) {
					return mcpAuthRuntime.createProviderForSession(id);
				},
				hasOAuthTokens(id) {
					return mcpAuthRuntime.hasTokens(id);
				},
			});
		},
		authRuntime: mcpAuthRuntime,
	});
	return { mcpAuthRuntime, mcpHostService };
}

async function main(): Promise<void> {
	process.stderr.write(
		`[notch-agent-sidecar] starting; protocol ${NOTCH_PROTOCOL_VERSION}\n`,
	);

	bootstrapAgentRuntime();

	const transport = new StdioTransport();
	const dispatcher = new Dispatcher(transport);
	const stdinClosed = new Promise<void>((resolve) => {
		const done = () => {
			process.stdin.off("end", done);
			process.stdin.off("close", done);
			resolve();
		};
		process.stdin.once("end", done);
		process.stdin.once("close", done);
	});
	process.stdin.resume();
	registerComputerUseTools(toolRegistry, dispatcher);

	// Single process-wide SessionManager. Manager starts EMPTY; the Shell
	// issues `session.create` after `rpc.hello` to obtain its bootstrap
	// sessionId. No implicit/default session — see docs/designs/session-management.md.
	const sessions = new SessionManager();
	// s03 TodoWrite tool — needs the SessionManager to resolve per-session
	// todo state, so it registers AFTER the manager exists but BEFORE the
	// agent loop attaches (the loop snapshots the tool registry per turn).
	registerTodoTool(sessions);
	const { mcpAuthRuntime, mcpHostService } = bootstrapMcp(dispatcher);
	assertRegisteredToolsMatchPermissionPolicies(
		toolRegistry.list(),
		builtinPermissionPolicyCatalog,
	);
	const permissionGateway = new PermissionGateway(
		dispatcher,
		builtinPermissionPolicyCatalog,
		readPermissionLevel,
	);
	registerSessionHandlers(dispatcher, sessions);
	registerAgentHandlers(dispatcher, { manager: sessions, permissionGateway });
	registerProviderHandlers(dispatcher);
	registerConfigHandlers(dispatcher);
	registerMcpHandlers(dispatcher, mcpHostService, mcpAuthRuntime);
	registerMcpAuthHandlers(dispatcher, mcpAuthRuntime);
	let shuttingDown = false;
	const shutdown = async (): Promise<void> => {
		if (shuttingDown) return;
		shuttingDown = true;
		dispatcher.stop();
		await mcpHostService.closeAll();
	};
	for (const signal of ["SIGINT", "SIGTERM"] as const) {
		process.once(signal, () => {
			shutdown()
				.then(() => process.exit(0))
				.catch((err) => {
					logger.error("sidecar shutdown failed", { err: String(err) });
					process.exit(1);
				});
		});
	}
	// rpc.ping handler — installed before the reader sees any inbound frames so
	// the Shell can immediately health-check us after the handshake.
	dispatcher.registerRequest(RPCMethod.rpcPing, async () => ({}));

	await dispatcher.start();

	// rpc.hello — first frame Bun sends. 5s budget gives the Shell time to
	// attach its reader after spawn.
	try {
		const result = await dispatcher.request<HelloResult>(
			RPCMethod.rpcHello,
			{
				protocolVersion: NOTCH_PROTOCOL_VERSION,
				clientInfo: { name: "notch-agent-sidecar", version: "0.1.0" },
			},
			{ timeoutMs: 5_000 },
		);
		const remoteMajor = result.protocolVersion.split(".")[0];
		const localMajor = NOTCH_PROTOCOL_VERSION.split(".")[0];
		if (remoteMajor !== localMajor) {
			logger.error("protocol major mismatch", {
				remote: result.protocolVersion,
				local: NOTCH_PROTOCOL_VERSION,
			});
			process.exit(2);
		}
		logger.info("rpc.hello ok", { protocolVersion: result.protocolVersion });
	} catch (err) {
		logger.error("rpc.hello failed", { err: String(err) });
		process.exit(2);
	}

	void mcpHostService
		.autoConnectServers(mcpAuthRuntime.status().servers)
		.then((servers) => {
			for (const server of servers) {
				dispatcher.notify(RPCMethod.mcpStatusChanged, { server });
			}
		})
		.catch((err) => {
			logger.error("mcp auto-connect failed", { err: String(err) });
		});

	// Keep the process alive until Shell closes stdin. Then tear down any live
	// MCP transports before allowing the child process to exit normally.
	await stdinClosed;
	await shutdown();
}

main().catch((err) => {
	logger.error("sidecar fatal", { err: String(err) });
	process.exit(1);
});
