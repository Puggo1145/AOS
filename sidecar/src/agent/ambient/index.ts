// Public surface of the ambient subsystem. Loop and `index.ts` consume
// only these exports.

export { ambientRegistry, AmbientRegistry } from "./registry";
export type { AmbientProvider } from "./provider";
export { renderAmbient } from "./render";
export { registerBuiltinAmbient } from "./register-builtins";
