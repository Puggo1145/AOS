// Unit tests for the EventStream / AssistantMessageEventStream primitive.
// Covers: ordered iteration, buffer-then-iterate, iterate-then-push,
// `result()` payload extraction, and the documented single-consumer
// semantics.

import { test, expect } from "bun:test";
import {
	AssistantMessageEventStream,
	EventStream,
} from "../src/llm/utils/event-stream";
import type { AssistantMessage } from "../src/llm/types";

function emptyMsg(): AssistantMessage {
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
	};
}

test("push then iterate drains the buffer in order", async () => {
	const s = new AssistantMessageEventStream();
	const m = emptyMsg();
	s.push({ type: "start", partial: m });
	s.push({ type: "text_delta", contentIndex: 0, delta: "a", partial: m });
	s.push({ type: "done", reason: "stop", message: m });
	s.end();
	const types: string[] = [];
	for await (const ev of s) types.push(ev.type);
	expect(types).toEqual(["start", "text_delta", "done"]);
});

test("iterate then push wakes the waiter", async () => {
	const s = new AssistantMessageEventStream();
	const m = emptyMsg();
	const collected: string[] = [];
	const reader = (async () => {
		for await (const ev of s) collected.push(ev.type);
	})();
	// schedule producer asynchronously
	await Promise.resolve();
	s.push({ type: "start", partial: m });
	s.push({ type: "done", reason: "stop", message: m });
	s.end();
	await reader;
	expect(collected).toEqual(["start", "done"]);
});

test("result() resolves with the done message", async () => {
	const s = new AssistantMessageEventStream();
	const m = emptyMsg();
	m.stopReason = "stop";
	s.push({ type: "done", reason: "stop", message: m });
	s.end();
	const final = await s.result();
	expect(final.stopReason).toBe("stop");
});

test("result() resolves with the error message on error path", async () => {
	const s = new AssistantMessageEventStream();
	const m = emptyMsg();
	m.stopReason = "error";
	m.errorMessage = "boom";
	s.push({ type: "error", reason: "error", error: m });
	s.end();
	const final = await s.result();
	expect(final.errorMessage).toBe("boom");
});

test("single-consumer: events are not duplicated across iterators", async () => {
	// Documented behavior: the stream is single-consumer. Each pushed
	// event is delivered to exactly one waiter (the first in line); a
	// second concurrent iterator never sees the same event twice. The
	// total events observed across both iterators must equal the total
	// pushed.
	const s = new EventStream<number, number>(
		(e) => e === 0,
		(e) => e,
	);
	const a: number[] = [];
	const b: number[] = [];
	const ra = (async () => {
		for await (const v of s) a.push(v);
	})();
	const rb = (async () => {
		for await (const v of s) b.push(v);
	})();
	await Promise.resolve();
	s.push(1);
	s.push(2);
	s.push(0);
	s.end();
	await Promise.all([ra, rb]);
	// No duplication: each value appears in at most one consumer.
	const all = [...a, ...b].sort();
	expect(all).toEqual([0, 1, 2]);
});

test("end() without final result rejects result()", async () => {
	const s = new EventStream<number, number>(
		(e) => e < 0,
		(e) => e,
	);
	s.end();
	await expect(s.result()).rejects.toThrow();
});
