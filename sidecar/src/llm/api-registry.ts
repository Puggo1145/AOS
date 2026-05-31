// Per-API stream function registry.
//
// Built-in providers are lazily registered by `providers/register-builtins.ts`
// on first import of the public `index.ts`. Third parties can register
// their own custom api implementations and tag them with a `sourceId`
// so that bulk unregistration on plugin unload becomes possible.

import type { Api, ApiProviderEntry } from "./types";

const registry: Map<Api, ApiProviderEntry> = new Map();

export function registerApiProvider<TApi extends Api>(
	entry: ApiProviderEntry<TApi>,
): void {
	registry.set(entry.api, entry as unknown as ApiProviderEntry);
}

export function getApiProvider<TApi extends Api>(
	api: TApi,
): ApiProviderEntry<TApi> | undefined {
	return registry.get(api) as ApiProviderEntry<TApi> | undefined;
}

/// Bulk remove every provider registered with the given sourceId.
export function unregisterApiProviders(sourceId: string): void {
	for (const [api, entry] of [...registry.entries()]) {
		if (entry.sourceId === sourceId) registry.delete(api);
	}
}
