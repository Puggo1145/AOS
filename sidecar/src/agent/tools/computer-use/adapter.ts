import type { Tool, ToolResultContent } from "../../../llm/types";
import type { Dispatcher } from "../../../rpc/dispatcher";
import type {
  ToolExecContext,
  ToolExecResult,
  ToolHandler,
  ToolRuntimeEffects,
} from "../types";
import type { ComputerUseArgs } from "./types";

export interface ComputerUseRpcToolBinding {
  method: string;
  validate?: (args: ComputerUseArgs) => void;
  prepare?: (args: ComputerUseArgs, ctx: ToolExecContext) => object;
  render?: (result: unknown, ctx: ToolExecContext) => ToolResultContent[];
  afterResult?: (result: unknown, args: ComputerUseArgs, ctx: ToolExecContext) => void;
  applyRuntimeEffects?: (
    result: ToolExecResult<unknown>,
    args: ComputerUseArgs,
    ctx: ToolExecContext,
    effects: ToolRuntimeEffects,
  ) => void;
}

export function createComputerUseRpcTool(
  spec: Tool,
  binding: ComputerUseRpcToolBinding,
  dispatcher: Dispatcher,
): ToolHandler<ComputerUseArgs, unknown> {
  return {
    spec,
    execute: async (args, ctx) => {
      binding.validate?.(args);
      const rpcArgs = binding.prepare ? binding.prepare(args, ctx) : args;
      const result = await dispatcher.request(binding.method, rpcArgs, { signal: ctx.signal });
      binding.afterResult?.(result, args, ctx);
      return {
        content: binding.render ? binding.render(result, ctx) : [{ type: "text", text: JSON.stringify(result, null, 2) }],
        details: result,
        isError: false,
      } satisfies ToolExecResult;
    },
    applyRuntimeEffects: binding.applyRuntimeEffects,
  };
}
