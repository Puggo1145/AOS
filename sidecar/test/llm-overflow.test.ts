// Tests for `isContextOverflow` covering the six representative
// branches (text overflow match, rate-limit non-match, silent overflow,
// normal stop, generic error without overflow text, abort).

import { test, expect } from "bun:test";
import { isContextOverflow } from "../src/llm/utils/overflow";
import type { AssistantMessage } from "../src/llm/types";

function msg(overrides: Partial<AssistantMessage>): AssistantMessage {
	return {
		role: "assistant",
		content: [],
		api: "openai-responses",
		provider: "chatgpt-plan",
		model: "gpt-5-2",
		usage: {
			input: 0,
			output: 0,
			cacheRead: 0,
			cacheWrite: 0,
			totalTokens: 0,
			cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
		},
		stopReason: "stop",
		timestamp: 0,
		...overrides,
	};
}

test("text overflow match", () => {
	const m = msg({
		stopReason: "error",
		errorMessage: "Error: prompt is too long for this model",
	});
	expect(isContextOverflow(m)).toBe(true);
});

test("rate limit is not overflow", () => {
	const m = msg({
		stopReason: "error",
		errorMessage: "rate limit exceeded, please slow down",
	});
	expect(isContextOverflow(m)).toBe(false);
});

test("silent overflow via usage > contextWindow", () => {
	const m = msg({
		stopReason: "stop",
		usage: {
			input: 300_000,
			output: 0,
			cacheRead: 50_000,
			cacheWrite: 0,
			totalTokens: 350_000,
			cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
		},
	});
	expect(isContextOverflow(m, 200_000)).toBe(true);
});

test("normal stop within window is not overflow", () => {
	const m = msg({
		stopReason: "stop",
		usage: {
			input: 1000,
			output: 200,
			cacheRead: 0,
			cacheWrite: 0,
			totalTokens: 1200,
			cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
		},
	});
	expect(isContextOverflow(m, 200_000)).toBe(false);
});

test("generic error without overflow text is not overflow", () => {
	const m = msg({
		stopReason: "error",
		errorMessage: "unexpected JSON parse failure",
	});
	expect(isContextOverflow(m)).toBe(false);
});

test("aborted stopReason is not overflow", () => {
	const m = msg({ stopReason: "aborted", errorMessage: "aborted" });
	expect(isContextOverflow(m)).toBe(false);
});
