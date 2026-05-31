// In-memory per-provider API key store.
//
// Persistence is owned by the Shell (macOS Keychain). At process startup the
// Shell pushes whatever it has via `provider.setApiKey`. The sidecar never
// writes a key to disk and never logs one — so a sidecar crash leaks nothing
// beyond whatever the OS gave us in process memory.
//
// Listeners exist so the `provider.*` runtime can emit `statusChanged`
// (ready ↔ unauthenticated) when a key appears or disappears, without each
// caller polling.

type Listener = (providerId: string, hasKey: boolean) => void;

const store = new Map<string, string>();
const listeners = new Set<Listener>();

export function setApiKey(providerId: string, apiKey: string): void {
	if (typeof providerId !== "string" || providerId.length === 0) {
		throw new Error("providerId must be a non-empty string");
	}
	if (typeof apiKey !== "string" || apiKey.length === 0) {
		throw new Error("apiKey must be a non-empty string");
	}
	const had = store.has(providerId);
	store.set(providerId, apiKey);
	if (!had) emit(providerId, true);
}

/// Returns true iff a key was actually removed.
export function clearApiKey(providerId: string): boolean {
	const removed = store.delete(providerId);
	if (removed) emit(providerId, false);
	return removed;
}

export function getApiKey(providerId: string): string | undefined {
	return store.get(providerId);
}

export function hasApiKey(providerId: string): boolean {
	return store.has(providerId);
}

export function onChange(listener: Listener): () => void {
	listeners.add(listener);
	return () => listeners.delete(listener);
}

function emit(providerId: string, hasKey: boolean): void {
	for (const l of listeners) {
		try {
			l(providerId, hasKey);
		} catch {
			/* listener faults must not poison the store */
		}
	}
}

// ---------------------------------------------------------------------------
// Test seam
// ---------------------------------------------------------------------------

export function _resetForTesting(): void {
	store.clear();
	listeners.clear();
}
