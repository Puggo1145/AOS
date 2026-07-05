// Public surface of the LLM auth subpackage.
//
// Consumed by `src/auth` (the provider login/logout RPC flow: `register.ts`,
// `runtime.ts`, `providers.ts`, `cli.ts`) only. Deliberately NOT folded into
// the top-level `src/llm/index.ts` — the agent layer must never see OAuth
// internals, so this is a second, narrower public surface with its own
// contract: exactly the symbols the provider login flow needs, nothing from
// `./env-api-keys` (only consumed internally by `../providers/*`).

export {
	CHATGPT_PLAN_CLIENT_ID,
	CHATGPT_PLAN_REDIRECT_PATH,
	CHATGPT_PLAN_REDIRECT_PORT,
	CHATGPT_PLAN_REDIRECT_URI,
	chatgptPlanOAuthProvider,
	generateCodeVerifier,
	generateState,
} from "./oauth/chatgpt-plan";
export {
	chatgptTokenPath,
	hasChatGPTPlanToken,
	writeChatGPTPlanToken,
} from "./oauth/storage";
