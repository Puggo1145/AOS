// StdioTransport unit tests — verify NDJSON line splitting, write
// serialization, and 2 MB overflow detection per docs/designs/rpc-protocol.md
// §"二进制 payload 规则".

import { test, expect } from "bun:test";
import {
	StdioTransport,
	MAX_LINE_BYTES,
	type ByteSink,
	type ByteSource,
} from "../src/rpc/transport";

function bytesSource(chunks: (string | Uint8Array)[]): ByteSource {
	return (async function* () {
		for (const c of chunks) {
			// Yield typed buffers to exercise the Buffer→string path.
			yield typeof c === "string" ? Buffer.from(c, "utf8") : c;
		}
	})();
}

class CollectingSink implements ByteSink {
	public lines: string[] = [];
	write(chunk: string): boolean {
		this.lines.push(chunk);
		return true;
	}
}

test("readLines splits on newline regardless of chunk boundaries", async () => {
	const src = bytesSource(['{"a":1}\n{"b":', '2}\n{"c":3}', "\n"]);
	const t = new StdioTransport(src, new CollectingSink());
	const out: string[] = [];
	for await (const line of t.readLines()) out.push(line);
	expect(out).toEqual(['{"a":1}', '{"b":2}', '{"c":3}']);
});

test("readLines drops empty lines and trailing partial line at EOF", async () => {
	const src = bytesSource(['\n\n{"a":1}\npartial-no-newline']);
	const t = new StdioTransport(src, new CollectingSink());
	const out: string[] = [];
	for await (const line of t.readLines()) out.push(line);
	expect(out).toEqual(['{"a":1}']);
});

test("readLines throws when single line exceeds 2 MB cap", async () => {
	// Construct a line that grows past the cap without ever including '\n'.
	const big = "x".repeat(MAX_LINE_BYTES + 100);
	const src = bytesSource([big]);
	const t = new StdioTransport(src, new CollectingSink());
	let threw = false;
	try {
		for await (const _ of t.readLines()) {
			/* drain */
		}
	} catch (err) {
		threw = true;
		expect(String(err)).toContain("exceeded");
	}
	expect(threw).toBe(true);
	expect(t.isClosed).toBe(true);
});

test("writeLine serializes concurrent writes via promise chain", async () => {
	const sink = new CollectingSink();
	const src = bytesSource([]); // no input
	const t = new StdioTransport(src, sink);
	// Fire many writes in parallel; the sink should record them in order.
	const N = 50;
	await Promise.all(
		Array.from({ length: N }, (_, i) => t.writeLine(`line-${i}`)),
	);
	expect(sink.lines).toHaveLength(N);
	for (let i = 0; i < N; i++) {
		expect(sink.lines[i]).toBe(`line-${i}\n`);
	}
});

test("writeLine rejects after close", async () => {
	const t = new StdioTransport(bytesSource([]), new CollectingSink());
	t.close();
	let threw = false;
	try {
		await t.writeLine("nope");
	} catch {
		threw = true;
	}
	expect(threw).toBe(true);
});
