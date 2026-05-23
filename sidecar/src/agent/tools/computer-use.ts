import type { Dispatcher } from "../../rpc/dispatcher";
import type { ToolHandler } from "./types";
import type { ToolRegistry } from "./registry";
import { createComputerUseToolHandlers } from "./computer-use/tools";

export function registerComputerUseTools(registry: ToolRegistry, dispatcher: Dispatcher): void {
  for (const tool of createComputerUseTools(dispatcher)) {
    registry.register(tool);
  }
}

export function createComputerUseTools(dispatcher: Dispatcher): ToolHandler[] {
  return createComputerUseToolHandlers(dispatcher);
}
