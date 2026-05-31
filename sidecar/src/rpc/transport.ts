// NDJSON stdio transport for the Notch Agent sidecar RPC channel.
//
// Per docs/designs/rpc-protocol.md:
//   - Framing: one JSON object per line, '\n' separated, UTF-8.
//   - Single-line cap: 2 MB. Exceeding the cap is fatal — the transport
//     closes and reports overflow so the Shell can respawn the sidecar.
//   - Writes from any task must be serialized via a single writer queue,
//     so partial-line interleaving cannot happen.
//
// The transport does no JSON parsing — that lives in the Dispatcher. It only
// owns byte framing and overflow detection.

import { logger } from "../log";

export const MAX_LINE_BYTES = 2 * 1024 * 1024; // 2 MB

/// Minimal Readable shape we need: an async iterable of byte chunks.
export type ByteSource = AsyncIterable<Uint8Array | Buffer | string>;

/// Minimal Writable shape: something we can `.write(string)` to. Returns a
/// boolean (Node-style backpressure) which we don't currently honour beyond
/// the serialization queue.
export interface ByteSink {
	write(chunk: string): boolean;
}

/// `process.stdin` does not implement AsyncIterable<Uint8Array> directly in
/// types, but Node/Bun runtime supports `for await (const chunk of stdin)`.
/// We accept a permissive ByteSource to keep the test surface easy.
export class StdioTransport {
	private closed = false;
	private writeChain: Promise<void> = Promise.resolve();
	private readonly source: ByteSource;
	private readonly sink: ByteSink;

	constructor(source?: ByteSource, sink?: ByteSink) {
		// process.stdin in Bun/Node is an AsyncIterable<Buffer> at runtime.
		this.source = source ?? (process.stdin as unknown as ByteSource);
		this.sink = sink ?? (process.stdout as unknown as ByteSink);
	}

	/// Yield NDJSON lines (without the trailing '\n'). Throws if a single
	/// unterminated line exceeds MAX_LINE_BYTES — this is unrecoverable per
	/// the protocol spec.
	async *readLines(): AsyncIterable<string> {
		let buf = "";
		for await (const chunk of this.source) {
			if (this.closed) return;
			const piece =
				typeof chunk === "string" ? chunk : Buffer.from(chunk).toString("utf8");
			buf += piece;
			let nl = buf.indexOf("\n");
			while (nl !== -1) {
				const line = buf.slice(0, nl);
				buf = buf.slice(nl + 1);
				if (line.length > 0) yield line;
				nl = buf.indexOf("\n");
			}
			if (buf.length > MAX_LINE_BYTES) {
				const err = new Error(
					`NDJSON line exceeded ${MAX_LINE_BYTES} bytes; closing transport`,
				);
				logger.error("transport overflow", {
					limit: MAX_LINE_BYTES,
					bufferLen: buf.length,
				});
				this.closed = true;
				throw err;
			}
		}
		// Trailing partial line at EOF is silently dropped — JSON-RPC peers must
		// newline-terminate every frame.
	}

	/// Append '\n' and write atomically. Concurrent calls are serialized
	/// through a Promise chain so writes never interleave on stdout.
	writeLine(json: string): Promise<void> {
		if (this.closed) return Promise.reject(new Error("transport closed"));
		const line = `${json}\n`;
		const next = this.writeChain.then(() => {
			this.sink.write(line);
		});
		// Suppress unhandled rejection on the chain itself; callers await `next`.
		this.writeChain = next.catch(() => {});
		return next;
	}

	close(): void {
		this.closed = true;
	}

	get isClosed(): boolean {
		return this.closed;
	}
}
