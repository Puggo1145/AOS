// Wire `provider.*` request handlers onto the dispatcher.
//
// Per docs/plans/onboarding.md §"Provider 方向约束". The notifications
// (`provider.loginStatus`, `provider.statusChanged`) are emitted from
// `runtime.ts` and `api-key-handlers.ts`; only Shell→Bun requests are
// registered here.

import { unlinkSync } from "node:fs";

import {
	RPCErrorCode,
	RPCMethod,
	type ProviderClearApiKeyParams,
	type ProviderClearApiKeyResult,
	type ProviderLogoutParams,
	type ProviderLogoutResult,
	type ProviderSetApiKeyParams,
	type ProviderSetApiKeyResult,
} from "../rpc/rpc-types";
import { type Dispatcher, RPCMethodError } from "../rpc/dispatcher";
import { startLogin, cancelLogin, getStatus } from "./runtime";
import { clearApiKey, setApiKey } from "./api-key-store";
import { getProvider } from "./providers";
import { chatgptTokenPath } from "../llm/auth";

export function registerProviderHandlers(dispatcher: Dispatcher): void {
	dispatcher.registerRequest(RPCMethod.providerStatus, async () => getStatus());

	dispatcher.registerRequest(RPCMethod.providerStartLogin, async (raw) => {
		return startLogin({ dispatcher }, raw as { providerId: string });
	});

	dispatcher.registerRequest(RPCMethod.providerCancelLogin, async (raw) => {
		return cancelLogin(raw as { loginId: string });
	});

	dispatcher.registerRequest(
		RPCMethod.providerSetApiKey,
		async (raw): Promise<ProviderSetApiKeyResult> => {
			const params = raw as ProviderSetApiKeyParams;
			if (
				typeof params?.providerId !== "string" ||
				typeof params?.apiKey !== "string" ||
				params.apiKey.length === 0
			) {
				throw new RPCMethodError(
					RPCErrorCode.invalidParams,
					"provider.setApiKey requires { providerId, apiKey }",
				);
			}
			const provider = getProvider(params.providerId);
			if (!provider) {
				throw new RPCMethodError(
					RPCErrorCode.unknownProvider,
					`unknown provider: ${params.providerId}`,
				);
			}
			if (provider.authMethod !== "apiKey") {
				throw new RPCMethodError(
					RPCErrorCode.invalidParams,
					`provider.setApiKey is only valid for apiKey-auth providers; ${params.providerId} uses ${provider.authMethod}`,
				);
			}
			setApiKey(params.providerId, params.apiKey);
			// Project to statusChanged so any Shell mirror flips ready without
			// a follow-up `provider.status` round-trip. We only emit on transitions
			// by checking the descriptor — `setApiKey` is idempotent at the store
			// level but state ↔ ready transition matters for the UI.
			dispatcher.notify(RPCMethod.providerStatusChanged, {
				providerId: params.providerId,
				state: "ready",
			});
			return { ok: true };
		},
	);

	dispatcher.registerRequest(
		RPCMethod.providerClearApiKey,
		async (raw): Promise<ProviderClearApiKeyResult> => {
			const params = raw as ProviderClearApiKeyParams;
			if (typeof params?.providerId !== "string") {
				throw new RPCMethodError(
					RPCErrorCode.invalidParams,
					"provider.clearApiKey requires { providerId }",
				);
			}
			const provider = getProvider(params.providerId);
			if (!provider) {
				throw new RPCMethodError(
					RPCErrorCode.unknownProvider,
					`unknown provider: ${params.providerId}`,
				);
			}
			if (provider.authMethod !== "apiKey") {
				throw new RPCMethodError(
					RPCErrorCode.invalidParams,
					`provider.clearApiKey is only valid for apiKey-auth providers; ${params.providerId} uses ${provider.authMethod}`,
				);
			}
			const cleared = clearApiKey(params.providerId);
			if (cleared) {
				dispatcher.notify(RPCMethod.providerStatusChanged, {
					providerId: params.providerId,
					state: "unauthenticated",
					reason: "loggedOut",
				});
			}
			return { cleared };
		},
	);

	// Auth-method-agnostic logout. The Settings UI uses this for both
	// OAuth (delete token file) and apiKey (clear in-memory store) so the
	// user can re-auth a previously-signed-in provider with a single
	// action. Idempotent: returns `cleared: false` when nothing to wipe.
	dispatcher.registerRequest(
		RPCMethod.providerLogout,
		async (raw): Promise<ProviderLogoutResult> => {
			const params = raw as ProviderLogoutParams;
			if (typeof params?.providerId !== "string") {
				throw new RPCMethodError(
					RPCErrorCode.invalidParams,
					"provider.logout requires { providerId }",
				);
			}
			const provider = getProvider(params.providerId);
			if (!provider) {
				throw new RPCMethodError(
					RPCErrorCode.unknownProvider,
					`unknown provider: ${params.providerId}`,
				);
			}

			let cleared = false;
			if (provider.authMethod === "apiKey") {
				cleared = clearApiKey(params.providerId);
			} else {
				// OAuth — only chatgpt-plan today. Delete both the live token and
				// the `.invalid` quarantine sibling so the next startLogin starts
				// from a clean slate.
				const path = chatgptTokenPath();
				const invalidPath = `${path}.invalid`;
				for (const p of [path, invalidPath]) {
					try {
						unlinkSync(p);
						if (p === path) cleared = true;
					} catch (err) {
						// ENOENT is the only acceptable swallow: file already gone is
						// the same observable end-state. Anything else (EACCES, EBUSY,
						// EROFS) leaves the token on disk while the UI thinks we're
						// signed out — fail fast so the caller can show an error.
						const code = (err as NodeJS.ErrnoException)?.code;
						if (code !== "ENOENT") {
							throw new RPCMethodError(
								RPCErrorCode.internalError,
								`failed to delete oauth token at ${p}: ${(err as Error)?.message ?? String(err)}`,
							);
						}
					}
				}
			}

			if (cleared) {
				dispatcher.notify(RPCMethod.providerStatusChanged, {
					providerId: params.providerId,
					state: "unauthenticated",
					reason: "loggedOut",
				});
			}
			return { cleared };
		},
	);
}
