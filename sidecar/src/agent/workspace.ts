// Notch Agent-owned working directory.
//
// `~/.notch-agent/workspace/` is the agent's personal scratch space. The system
// prompt tells the model this is its default location for drafts, generated
// artifacts, and temp files. The bash tool starts commands in this directory
// by default; the agent can still `cd` elsewhere when the user asks for work
// in a specific directory. Notch Agent is an OS-level helper, not a chrooted sandbox.
//
// `workspaceDir()` is a pure path computation (safe to call from tests).
// `ensureWorkspace()` is the one place that touches the filesystem — invoked
// once from sidecar boot in `index.ts`.

import { mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export function workspaceDir(): string {
	return join(homedir(), ".notch-agent", "workspace");
}

export function ensureWorkspace(): void {
	mkdirSync(workspaceDir(), { recursive: true });
}
