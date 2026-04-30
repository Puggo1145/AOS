// Wire built-in ambient providers into the global registry.
//
// Idempotent — `index.ts` calls this once at boot. Tests that want a
// clean slate use `ambientRegistry.clear()` then re-register only the
// providers they want exercised, so they do NOT call this function.

import { ambientRegistry } from "./registry";
import { todosAmbientProvider } from "./providers/todos";

let registered = false;

export function registerBuiltinAmbient(): void {
  if (registered) return;
  registered = true;
  ambientRegistry.register(todosAmbientProvider);
}
