// Public surface of the tool subsystem. Loop and index.ts consume only
// these exports.

export { toolRegistry, ToolRegistry } from "./core/registry";
export { registerBuiltinTools } from "./builtins/register";
export { registerTodoTool } from "./builtins/todo";
export { registerComputerUseTools } from "./builtins/computer-use";
export type {
	ToolHandler,
	ToolExecContext,
	ToolExecResult,
	ToolRuntimeEffects,
} from "./core/types";
export { ToolUserError } from "./core/types";
export { defineTool, validateToolArguments } from "./core/schema";
