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
// explicitly asking, the cost decision is theirs. The breaker is a
// per-session value object owned by `Session` (constructed alongside
// conversation/turns/todos) so its lifetime is tied to the session's —
// no separate forget-on-reset bookkeeping required.

const FAILURE_LIMIT = 3;

export class CompactBreaker {
	private _consecutiveFailures = 0;
	private _disabled = false;

	get consecutiveFailures(): number {
		return this._consecutiveFailures;
	}

	get disabled(): boolean {
		return this._disabled;
	}

	/// Whether auto-compact should be skipped for this session. Manual
	/// triggers (future RPC entry) must not call this — the breaker only
	/// gates the implicit per-turn auto path.
	isAutoDisabled(): boolean {
		return this._disabled;
	}

	recordSuccess(): void {
		this._consecutiveFailures = 0;
		// Note: we do NOT auto-revive a tripped breaker on success — once it
		// trips it stays tripped for the session's lifetime. A successful
		// manual compact does not imply auto-compact is now safe (the auto
		// path's failures usually come from a different cause: prompt size,
		// not transient network).
	}

	recordFailure(): void {
		this._consecutiveFailures += 1;
		if (this._consecutiveFailures >= FAILURE_LIMIT) this._disabled = true;
	}

	/// Drop tracked state. Called from `agent.reset` via `session.compactBreaker.reset()`
	/// so a fresh session does not inherit a tripped breaker from the prior
	/// history run.
	reset(): void {
		this._consecutiveFailures = 0;
		this._disabled = false;
	}
}

export const COMPACT_FAILURE_LIMIT = FAILURE_LIMIT;
