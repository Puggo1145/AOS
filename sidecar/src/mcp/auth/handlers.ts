import {
	RPCMethod,
	type McpAuthCancelLoginParams,
	type McpAuthLogoutParams,
	type McpAuthStartLoginParams,
} from "../../rpc/rpc-types";
import type { Dispatcher } from "../../rpc/dispatcher";
import type { McpAuthRuntime } from "./runtime";

export function registerMcpAuthHandlers(
	dispatcher: Dispatcher,
	runtime: McpAuthRuntime,
): void {
	dispatcher.registerRequest(RPCMethod.mcpAuthStatus, async () =>
		runtime.status(),
	);
	dispatcher.registerRequest(RPCMethod.mcpAuthStartLogin, async (raw) =>
		runtime.startLogin(raw as McpAuthStartLoginParams),
	);
	dispatcher.registerRequest(RPCMethod.mcpAuthCancelLogin, async (raw) =>
		runtime.cancelLogin(raw as McpAuthCancelLoginParams),
	);
	dispatcher.registerRequest(RPCMethod.mcpAuthLogout, async (raw) =>
		runtime.logout(raw as McpAuthLogoutParams),
	);
}
