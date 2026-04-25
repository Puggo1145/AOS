// Environment-driven API key lookup.
//
// Per docs/designs/llm-provider.md "Token → Provider 桥接": for the
// `chatgpt-plan` provider we return the `<authenticated>` sentinel
// when a stored token exists, signalling the openai-responses provider
// to read the bearer token at request time via `readChatGPTToken()`.
// Other providers fall through to env-var lookup; only `openai` is
// wired this round.

import { hasChatGPTPlanToken } from "./oauth/storage";
import { PROVIDER_IDS } from "../models/catalog";

export const AUTHENTICATED_SENTINEL = "<authenticated>";

export function getEnvApiKey(provider: string): string | undefined {
  if (provider === PROVIDER_IDS.chatgptPlan) {
    return hasChatGPTPlanToken() ? AUTHENTICATED_SENTINEL : undefined;
  }
  if (provider === "openai") return process.env.OPENAI_API_KEY;
  return undefined;
}
