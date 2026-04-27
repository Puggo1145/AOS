// Public surface of the tool subsystem. Loop and index.ts consume only
// these exports.

export { toolRegistry, ToolRegistry } from "./registry";
export { registerBuiltinTools } from "./register-builtins";
export type { ToolHandler, ToolExecContext, ToolExecResult } from "./types";
export { ToolUserError } from "./types";
