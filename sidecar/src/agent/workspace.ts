// AOS-owned working directory.
//
// `~/.aos/workspace/` is the agent's personal scratch space. The system
// prompt tells the model this is its default location for drafts, generated
// artifacts, and temp files. Tools (notably `bash`) do NOT pin their cwd to
// this path — the agent is encouraged to `cd` elsewhere when the user asks
// for work in a specific directory. AOS is an OS-level helper, not a
// chrooted sandbox.
//
// `workspaceDir()` is a pure path computation (safe to call from tests).
// `ensureWorkspace()` is the one place that touches the filesystem — invoked
// once from sidecar boot in `index.ts`.

import { mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export function workspaceDir(): string {
  return join(homedir(), ".aos", "workspace");
}

export function ensureWorkspace(): void {
  mkdirSync(workspaceDir(), { recursive: true });
}
