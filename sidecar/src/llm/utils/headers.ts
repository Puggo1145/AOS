// Header helpers used by provider transports.

export function mergeHeaders(
	...sources: (Record<string, string> | undefined | null)[]
): Record<string, string> {
	const out: Record<string, string> = {};
	for (const src of sources) {
		if (!src) continue;
		for (const [k, v] of Object.entries(src)) {
			if (v !== undefined && v !== null) out[k] = v;
		}
	}
	return out;
}

/// Convert a Fetch `Headers` instance into a plain record (lowercased keys).
export function headersToRecord(h: Headers): Record<string, string> {
	const out: Record<string, string> = {};
	h.forEach((value, key) => {
		out[key.toLowerCase()] = value;
	});
	return out;
}
