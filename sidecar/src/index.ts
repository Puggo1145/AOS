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
import { registerAgentHandlers } from "./agent/loop";
import { SessionManager } from "./agent/session/manager";
import { registerSessionHandlers } from "./agent/session/handlers";
import { registerProviderHandlers } from "./auth/register";
import { registerConfigHandlers } from "./config/handlers";
import { registerBuiltinTools } from "./agent/tools";
import { toolRegistry } from "./agent/tools";
import { registerTodoTool } from "./agent/tools/todo";
import { registerComputerUseTools } from "./agent/tools/computer-use";
import { registerBuiltinAmbient } from "./agent/ambient";
import { ensureWorkspace } from "./agent/workspace";
import { logger } from "./log";
import { NOTCH_PROTOCOL_VERSION, RPCMethod, type HelloResult } from "./rpc/rpc-types";

// Side-effect: triggers register-builtins (api providers + model catalog).
import "./llm";

async function main(): Promise<void> {
  process.stderr.write(`[notch-agent-sidecar] starting; protocol ${NOTCH_PROTOCOL_VERSION}\n`);

  // Side-effect bootstrap: ensure ~/.notch-agent/workspace/ exists (the agent's
  // default scratch directory) and register every built-in tool into the
  // global ToolRegistry before the agent loop ever runs.
  ensureWorkspace();
  registerBuiltinTools();
  // Built-in ambient providers: today only the per-session todos block.
  // Registered alongside the tool registry so every turn assembled below
  // sees a populated ambient registry.
  registerBuiltinAmbient();

  const transport = new StdioTransport();
  const dispatcher = new Dispatcher(transport);
  registerComputerUseTools(toolRegistry, dispatcher);

  // Single process-wide SessionManager. Manager starts EMPTY; the Shell
  // issues `session.create` after `rpc.hello` to obtain its bootstrap
  // sessionId. No implicit/default session — see docs/designs/session-management.md.
  const sessions = new SessionManager();
  // s03 TodoWrite tool — needs the SessionManager to resolve per-session
  // todo state, so it registers AFTER the manager exists but BEFORE the
  // agent loop attaches (the loop snapshots the tool registry per turn).
  registerTodoTool(sessions);
  registerSessionHandlers(dispatcher, sessions);
  registerAgentHandlers(dispatcher, { manager: sessions });
  registerProviderHandlers(dispatcher);
  registerConfigHandlers(dispatcher);
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
      logger.error("protocol major mismatch", { remote: result.protocolVersion, local: NOTCH_PROTOCOL_VERSION });
      process.exit(2);
    }
    logger.info("rpc.hello ok", { protocolVersion: result.protocolVersion });
  } catch (err) {
    logger.error("rpc.hello failed", { err: String(err) });
    process.exit(2);
  }

  // Keep the process alive — the dispatcher reader loop owns liveness.
  await new Promise<void>(() => {
    /* never resolves; process exits via signal or dispatcher reader EOF */
  });
}

main().catch((err) => {
  logger.error("sidecar fatal", { err: String(err) });
  process.exit(1);
});
