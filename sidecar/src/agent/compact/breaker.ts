// Per-session circuit breaker for auto-compact.
//
// If three consecutive auto-compact attempts fail (LLM error, transport
// failure, etc.) on a single session, further auto-compact attempts in
// that session are suppressed until the session is reset. Without the
// breaker, a session whose compact prompt itself overflows would loop
// forever — every turn triggers the same failing summarization, never
// makes progress, and burns tokens.
//
// Manual /compact triggers must NOT consult this state — the user is
// explicitly asking, the cost decision is theirs. The breaker is keyed
// on `sessionId` and lives in module scope (mirrors `ambient/registry`)
// rather than on the Session class so the compact module owns its own
// failure-tracking concern end-to-end.

const FAILURE_LIMIT = 3;

interface BreakerState {
	consecutiveFailures: number;
	disabled: boolean;
}

const states = new Map<string, BreakerState>();

function get(sessionId: string): BreakerState {
	let s = states.get(sessionId);
	if (!s) {
		s = { consecutiveFailures: 0, disabled: false };
		states.set(sessionId, s);
	}
	return s;
}

export const compactBreaker = {
	/// Whether auto-compact should be skipped for this session. Manual
	/// triggers (future RPC entry) must not call this — the breaker only
	/// gates the implicit per-turn auto path.
	isAutoDisabled(sessionId: string): boolean {
		return get(sessionId).disabled;
	},

	recordSuccess(sessionId: string): void {
		const s = get(sessionId);
		s.consecutiveFailures = 0;
		// Note: we do NOT auto-revive a tripped breaker on success — once it
		// trips it stays tripped for the session's lifetime. A successful
		// manual compact does not imply auto-compact is now safe (the auto
		// path's failures usually come from a different cause: prompt size,
		// not transient network).
	},

	recordFailure(sessionId: string): void {
		const s = get(sessionId);
		s.consecutiveFailures += 1;
		if (s.consecutiveFailures >= FAILURE_LIMIT) s.disabled = true;
	},

	/// Drop a session's tracked state. Called from `agent.reset` and
	/// `session.delete` so a fresh session does not inherit a tripped
	/// breaker from a previous run with the same id (test setup churn,
	/// mainly).
	forget(sessionId: string): void {
		states.delete(sessionId);
	},

	/// Test-only: wipe all tracked sessions.
	clear(): void {
		states.clear();
	},

	/// Test-only: read current counter state.
	inspect(sessionId: string): {
		consecutiveFailures: number;
		disabled: boolean;
	} {
		return { ...get(sessionId) };
	},
};

export const COMPACT_FAILURE_LIMIT = FAILURE_LIMIT;
