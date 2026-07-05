// Compact subsystem barrel.
//
// `compactConversation` is the function both the auto-path (loop entry)
// and the future manual `/compact` RPC entry call. `CompactBreaker` is the
// per-session circuit breaker (owned by `Session`) that gates the auto path
// after repeated failures (manual triggers must NOT consult it).

export {
	compactConversation,
	autoCompactIfNeeded,
	AUTO_COMPACT_REMAINING_THRESHOLD,
	COMPACT_NOOP_EMPTY,
	type CompactResult,
	type CompactNoop,
} from "./manager";
export { CompactBreaker, COMPACT_FAILURE_LIMIT } from "./breaker";
export { COMPACT_SYSTEM_PROMPT, COMPACT_FINAL_REQUEST } from "./prompt";
