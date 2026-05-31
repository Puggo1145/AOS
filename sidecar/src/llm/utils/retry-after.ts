// Extract a server-requested retry delay (milliseconds) from a response.
//
// Per guide §10.2:
//   - Prefer the `retry-after` HTTP header (seconds OR HTTP-date).
//   - Fall back to body regex matches like
//       "Please retry in 12.5s"
//       "retryDelay": "34s"
//       "retry after 5 minutes"
//
// Returns `undefined` when nothing can be derived. Caller decides whether
// to clamp against `maxRetryDelayMs` and either sleep+retry or surface
// the delay to the agent layer.

const BODY_PATTERNS: RegExp[] = [
	/retry[- ]after\s*[:=]?\s*"?(\d+(?:\.\d+)?)\s*s/i,
	/retry[_ ]?delay"?\s*[:=]\s*"?(\d+(?:\.\d+)?)\s*s/i,
	/retry in\s+(\d+(?:\.\d+)?)\s*s(?:econds)?/i,
	/retry after\s+(\d+(?:\.\d+)?)\s*s(?:econds)?/i,
	/retry in\s+(\d+(?:\.\d+)?)\s*m(?:inutes)?/i,
	/retry after\s+(\d+(?:\.\d+)?)\s*m(?:inutes)?/i,
];

export function extractRetryAfter(
	headers: Headers | Record<string, string> | undefined,
	body: string | undefined,
): number | undefined {
	// Header path
	const headerVal = headers
		? headers instanceof Headers
			? headers.get("retry-after")
			: (headers["retry-after"] ?? headers["Retry-After"])
		: null;
	if (headerVal) {
		const asNumber = Number(headerVal);
		if (!Number.isNaN(asNumber)) return asNumber * 1000;
		const asDate = Date.parse(headerVal);
		if (!Number.isNaN(asDate)) {
			const delta = asDate - Date.now();
			if (delta > 0) return delta;
		}
	}
	// Body path
	if (body) {
		for (const pat of BODY_PATTERNS) {
			const m = body.match(pat);
			if (m) {
				const n = Number(m[1]);
				if (!Number.isNaN(n)) {
					const isMinutes =
						/m(?:inutes)?/i.test(m[0]) && !/s(?:econds)?/i.test(m[0]);
					return isMinutes ? n * 60_000 : n * 1000;
				}
			}
		}
	}
	return undefined;
}
