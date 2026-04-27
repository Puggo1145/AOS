// Wire built-in tools into the global registry.
//
// Idempotent — `index.ts` calls this once at boot. Tests that want a clean
// slate use `toolRegistry.clear()` then re-register only the handlers they
// want exercised, so they do NOT call this function.

import { createBashTool } from "./bash";
import { createReadTool } from "./read";
import { createUpdateTool } from "./update";
import { createWriteTool } from "./write";
import { toolRegistry } from "./registry";

let registered = false;

export function registerBuiltinTools(): void {
  if (registered) return;
  registered = true;
  toolRegistry.register(createBashTool());
  toolRegistry.register(createReadTool());
  toolRegistry.register(createWriteTool());
  toolRegistry.register(createUpdateTool());
}
