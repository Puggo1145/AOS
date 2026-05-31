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
import type {
	ProviderAuthMethod,
	ProviderInfo,
	ProviderState,
} from "../rpc/rpc-types";
import { hasApiKey } from "./api-key-store";

export interface ProviderDescriptor {
	id: string;
	name: string;
	/// How the user authenticates with this provider.
	///   - `oauth`: per-provider login flow + on-disk token (chatgpt-plan).
	///   - `apiKey`: user pastes a key; persisted by Shell (Keychain) and
	///     pushed to sidecar in-memory via `provider.setApiKey`.
	authMethod: ProviderAuthMethod;
	/// Sync probe: looks at disk (oauth) or the in-memory store (apiKey).
	/// Never makes a network call.
	status(): ProviderState;
}

export const KNOWN_PROVIDERS: ProviderDescriptor[] = [
	{
		id: PROVIDER_IDS.chatgptPlan,
		name: PROVIDER_NAMES[PROVIDER_IDS.chatgptPlan],
		authMethod: "oauth",
		status: () => (hasChatGPTPlanToken() ? "ready" : "unauthenticated"),
	},
	{
		id: PROVIDER_IDS.deepseek,
		name: PROVIDER_NAMES[PROVIDER_IDS.deepseek],
		authMethod: "apiKey",
		status: () =>
			hasApiKey(PROVIDER_IDS.deepseek) ? "ready" : "unauthenticated",
	},
];

export function getProvider(id: string): ProviderDescriptor | undefined {
	return KNOWN_PROVIDERS.find((p) => p.id === id);
}

export function listProviderInfos(): ProviderInfo[] {
	return KNOWN_PROVIDERS.map((p) => ({
		id: p.id,
		name: p.name,
		authMethod: p.authMethod,
		state: p.status(),
	}));
}
