// Wire built-in tools into the global registry.
//
// Idempotent — `index.ts` calls this once at boot. Tests that want a clean
// slate use `toolRegistry.clear()` then re-register only the handlers they
// want exercised, so they do NOT call this function.

import { createBashTool } from "./bash";
import { toolRegistry } from "./registry";

let registered = false;

export function registerBuiltinTools(): void {
  if (registered) return;
  registered = true;
  toolRegistry.register(createBashTool());
}
