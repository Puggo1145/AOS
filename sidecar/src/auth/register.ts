// Wire `provider.*` request handlers onto the dispatcher.
//
// Per docs/plans/onboarding.md §"Provider 方向约束". The notifications
// (`provider.loginStatus`, `provider.statusChanged`) are emitted from
// `runtime.ts`; only the three Shell→Bun requests are registered here.

import { RPCMethod } from "../rpc/rpc-types";
import { Dispatcher } from "../rpc/dispatcher";
import { startLogin, cancelLogin, getStatus } from "./runtime";

export function registerProviderHandlers(dispatcher: Dispatcher): void {
  dispatcher.registerRequest(RPCMethod.providerStatus, async () => getStatus());

  dispatcher.registerRequest(RPCMethod.providerStartLogin, async (raw) => {
    return startLogin({ dispatcher }, raw as { providerId: string });
  });

  dispatcher.registerRequest(RPCMethod.providerCancelLogin, async (raw) => {
    return cancelLogin(raw as { loginId: string });
  });
}
