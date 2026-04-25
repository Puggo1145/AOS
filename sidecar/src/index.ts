// AOS sidecar entry point. Bun executes this file as the child process.
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
import { registerProviderHandlers } from "./auth/register";
import { registerConfigHandlers } from "./config/handlers";
import { logger } from "./log";
import { AOS_PROTOCOL_VERSION, RPCMethod, type HelloResult } from "./rpc/rpc-types";

// Side-effect: triggers register-builtins (api providers + model catalog).
import "./llm";

async function main(): Promise<void> {
  process.stderr.write(`[aos-sidecar] starting; protocol ${AOS_PROTOCOL_VERSION}\n`);

  const transport = new StdioTransport();
  const dispatcher = new Dispatcher(transport);

  registerAgentHandlers(dispatcher);
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
        protocolVersion: AOS_PROTOCOL_VERSION,
        clientInfo: { name: "aos-sidecar", version: "0.1.0" },
      },
      { timeoutMs: 5_000 },
    );
    const remoteMajor = result.protocolVersion.split(".")[0];
    const localMajor = AOS_PROTOCOL_VERSION.split(".")[0];
    if (remoteMajor !== localMajor) {
      logger.error("protocol major mismatch", { remote: result.protocolVersion, local: AOS_PROTOCOL_VERSION });
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
