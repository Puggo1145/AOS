// Three-tier streaming JSON parser used for tool call argument deltas.
//
// Tier 1: standard JSON.parse for finished payloads.
// Tier 2: `partial-json` for partial / in-progress streams.
// Tier 3: a small in-house repair pass for known LLM mistakes (raw control
//         characters and bare \n / \t / \r inside strings) followed by
//         partial-json again.
//
// Returns `{}` instead of throwing — callers (UI / agent loop) consume
// the latest snapshot opportunistically.

import { parse as partialParseRaw, Allow } from "partial-json";

function partialParse(s: string): unknown {
	return partialParseRaw(s, Allow.ALL);
}

/// Repair pass: within string literals, escape raw control characters
/// (\n, \r, \t and any 0x00–0x1F byte) so the result is a valid JSON
/// string. We track string boundaries with a manual scanner so escape
/// sequences and quoted braces are handled correctly.
export function repairJson(input: string): string {
	let out = "";
	let inString = false;
	let escaped = false;
	for (let i = 0; i < input.length; i++) {
		const ch = input[i]!;
		if (!inString) {
			if (ch === '"') {
				inString = true;
			}
			out += ch;
			continue;
		}
		// inside a string
		if (escaped) {
			out += ch;
			escaped = false;
			continue;
		}
		if (ch === "\\") {
			out += ch;
			escaped = true;
			continue;
		}
		if (ch === '"') {
			inString = false;
			out += ch;
			continue;
		}
		const code = ch.charCodeAt(0);
		if (code < 0x20) {
			switch (ch) {
				case "\n":
					out += "\\n";
					break;
				case "\r":
					out += "\\r";
					break;
				case "\t":
					out += "\\t";
					break;
				case "\b":
					out += "\\b";
					break;
				case "\f":
					out += "\\f";
					break;
				default:
					out += `\\u${code.toString(16).padStart(4, "0")}`;
			}
			continue;
		}
		out += ch;
	}
	return out;
}

export function parseStreamingJson<T = Record<string, unknown>>(
	partial: string | undefined,
): T {
	if (!partial || partial.trim() === "") return {} as T;
	try {
		return JSON.parse(partial) as T;
	} catch {
		try {
			return (partialParse(partial) ?? {}) as T;
		} catch {
			try {
				return (partialParse(repairJson(partial)) ?? {}) as T;
			} catch {
				return {} as T;
			}
		}
	}
}
