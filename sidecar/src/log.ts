// Tiny stderr-only structured logger for the sidecar.
//
// Per docs/designs/rpc-protocol.md the RPC channel is stdio NDJSON; logs MUST
// go to stderr to stay physically separate from the wire protocol. Output is a
// single JSON object per line so the Shell can pick it up and forward to its
// log system without further parsing.

type Level = "info" | "warn" | "error";

function log(level: Level, msg: string, extra?: Record<string, unknown>): void {
	const line = JSON.stringify({ t: Date.now(), level, msg, ...extra });
	process.stderr.write(`${line}\n`);
}

export const logger = {
	info: (m: string, e?: Record<string, unknown>) => log("info", m, e),
	warn: (m: string, e?: Record<string, unknown>) => log("warn", m, e),
	error: (m: string, e?: Record<string, unknown>) => log("error", m, e),
};
