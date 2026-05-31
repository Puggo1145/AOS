// Context overflow detection.
//
// Two paths per guide §10.3:
//   1. Text mode: the assistant's `errorMessage` matches one of the
//      OVERFLOW_PATTERNS (and does NOT match a NON_OVERFLOW_PATTERNS
//      such as a generic rate-limit message).
//   2. Silent overflow: the assistant returned `stop` but reported
//      `usage.input + usage.cacheRead > contextWindow`. Some providers
//      truncate quietly without an error string.

import type { AssistantMessage } from "../types";

export const OVERFLOW_PATTERNS: RegExp[] = [
	/prompt is too long/i,
	/request_too_large/i,
	/input is too long for requested model/i,
	/exceeds the context window/i,
	/input token count.*exceeds the maximum/i,
	/maximum prompt length is \d+/i,
	/reduce the length of the messages/i,
	/maximum context length is \d+ tokens/i,
	/exceeds the limit of \d+/i,
	/context[_ ]length[_ ]exceeded/i,
	/token limit exceeded/i,
	/^4(?:00|13)\s*(?:status code)?\s*\(no body\)/i,
];

export const NON_OVERFLOW_PATTERNS: RegExp[] = [
	/^(Throttling error|Service unavailable):/i,
	/rate limit/i,
	/too many requests/i,
];

export function isContextOverflow(
	msg: AssistantMessage,
	contextWindow?: number,
): boolean {
	if (msg.stopReason === "error" && msg.errorMessage) {
		if (NON_OVERFLOW_PATTERNS.some((p) => p.test(msg.errorMessage!)))
			return false;
		if (OVERFLOW_PATTERNS.some((p) => p.test(msg.errorMessage!))) return true;
	}
	if (contextWindow && msg.stopReason === "stop") {
		const input = msg.usage.input + msg.usage.cacheRead;
		if (input > contextWindow) return true;
	}
	return false;
}
