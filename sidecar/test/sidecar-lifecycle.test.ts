// Sidecar process lifecycle tests.
//
// These exercise the real Bun entry point because crash / force-quit cleanup
// depends on process-level stdio EOF behavior, not only the in-memory
// dispatcher unit tests.

import { test, expect } from "bun:test";
import { spawn } from "node:child_process";

test("sidecar exits cleanly when shell closes stdin after handshake", async () => {
  const startedAt = Date.now();
  const child = spawn("bun", ["run", "src/index.ts"], {
    cwd: process.cwd(),
    stdio: ["pipe", "pipe", "pipe"],
  });

  let stdout = "";
  let stderr = "";

  const result = await new Promise<{ code: number | null; signal: NodeJS.Signals | null; elapsedMs: number }>(
    (resolve, reject) => {
      const timeout = setTimeout(() => {
        child.kill("SIGKILL");
        reject(new Error(`sidecar did not exit after stdin EOF; stderr=${stderr}`));
      }, 1_500);

      child.stderr.on("data", (chunk) => {
        stderr += chunk.toString();
      });

      child.stdout.on("data", (chunk) => {
        stdout += chunk.toString();
        let newlineIndex: number;
        while ((newlineIndex = stdout.indexOf("\n")) !== -1) {
          const line = stdout.slice(0, newlineIndex);
          stdout = stdout.slice(newlineIndex + 1);
          if (line.trim().length === 0) continue;

          const frame = JSON.parse(line);
          if (frame.method !== "rpc.hello") continue;

          child.stdin.write(
            JSON.stringify({
              jsonrpc: "2.0",
              id: frame.id,
              result: {
                protocolVersion: frame.params.protocolVersion,
                serverInfo: {
                  name: "lifecycle-test-shell",
                  version: frame.params.protocolVersion,
                },
              },
            }) + "\n",
          );
          child.stdin.end();
        }
      });

      child.on("error", (error) => {
        clearTimeout(timeout);
        reject(error);
      });

      child.on("exit", (code, signal) => {
        clearTimeout(timeout);
        resolve({ code, signal, elapsedMs: Date.now() - startedAt });
      });
    },
  );

  expect(result.code).toBe(0);
  expect(result.signal).toBeNull();
  expect(result.elapsedMs).toBeLessThan(1_500);
});
