// Known LLM providers + per-provider sync status query.
//
// Per docs/plans/onboarding.md §"模块布局":
//   - this round registers exactly one provider: `chatgpt-plan`
//   - `provider.status` does NOT do network refresh; it only checks disk
//     existence + schema. Refresh validation is the LLM call's job.
//
// `chatgpt.json.invalid` (the quarantine file written by readChatGPTToken
// on refresh failure) is naturally ignored because we only look at
// `chatgpt.json`.

import { hasChatGPTPlanToken } from "../llm/auth/oauth/storage";
import { PROVIDER_IDS, PROVIDER_NAMES } from "../llm";
import type { ProviderInfo, ProviderState } from "../rpc/rpc-types";

export interface ProviderDescriptor {
  id: string;
  name: string;
  /// Disk-only sync probe. Returns the wire `ProviderState`.
  status(): ProviderState;
}

export const KNOWN_PROVIDERS: ProviderDescriptor[] = [
  {
    id: PROVIDER_IDS.chatgptPlan,
    name: PROVIDER_NAMES[PROVIDER_IDS.chatgptPlan],
    status: () => (hasChatGPTPlanToken() ? "ready" : "unauthenticated"),
  },
];

export function getProvider(id: string): ProviderDescriptor | undefined {
  return KNOWN_PROVIDERS.find((p) => p.id === id);
}

export function listProviderInfos(): ProviderInfo[] {
  return KNOWN_PROVIDERS.map((p) => ({
    id: p.id,
    name: p.name,
    state: p.status(),
  }));
}
