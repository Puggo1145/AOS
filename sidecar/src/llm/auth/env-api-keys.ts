// Per-provider API key lookup.
//
// Lookup order for non-OAuth providers:
//   1. The in-memory `api-key-store` (populated by the Shell via
//      `provider.setApiKey` from Keychain at startup, or by the user
//      saving a key in Settings).
//   2. The environment variable (developer convenience for CLI/test).
//
// For `chatgpt-plan` we return the `<authenticated>` sentinel when a
// stored OAuth token exists — the openai-responses provider then reads
// the bearer token at request time via `readChatGPTToken()`.

import { hasChatGPTPlanToken } from "./oauth/storage";
import { PROVIDER_IDS } from "../models/catalog";
import { getApiKey as getStoredApiKey } from "../../auth/api-key-store";

export const AUTHENTICATED_SENTINEL = "<authenticated>";

export function getEnvApiKey(provider: string): string | undefined {
	if (provider === PROVIDER_IDS.chatgptPlan) {
		return hasChatGPTPlanToken() ? AUTHENTICATED_SENTINEL : undefined;
	}
	const stored = getStoredApiKey(provider);
	if (stored) return stored;
	if (provider === "openai") return process.env.OPENAI_API_KEY;
	if (provider === "deepseek") return process.env.DEEPSEEK_API_KEY;
	return undefined;
}
