// Push/pull event queue used as the unified streaming primitive.
//
// Every provider returns one of these synchronously from `stream()`. Errors
// arriving asynchronously are surfaced as a final `error` event rather than
// rejecting the outer promise (guide §3.4).
//
// Single-consumer by contract: only the first `for await` iterator on the
// stream receives events; spawning a second iterator yields no events.
// `result()` may be awaited from anywhere and resolves with the terminal
// `done.message` or `error.error` payload.

import type { AssistantMessage, AssistantMessageEvent } from "../types";

type Resolver<T> = (r: IteratorResult<T>) => void;

export class EventStream<T, R = T> implements AsyncIterable<T> {
	private queue: T[] = [];
	private waiting: Resolver<T>[] = [];
	private closed = false;
	private finalResult: R | undefined;
	private finalResultResolve!: (r: R) => void;
	private finalResultReject!: (e: unknown) => void;
	private finalResultPromise: Promise<R>;

	constructor(
		private readonly isComplete: (e: T) => boolean,
		private readonly extractResult: (e: T) => R,
	) {
		this.finalResultPromise = new Promise<R>((resolve, reject) => {
			this.finalResultResolve = resolve;
			this.finalResultReject = reject;
		});
	}

	/// Push an event. If iterators are awaiting, the next waiter is woken.
	/// If the event is "complete" (per `isComplete`), we capture the final
	/// result for `result()` callers; subsequent pushes are dropped.
	push(event: T): void {
		if (this.closed) return;
		if (this.isComplete(event)) {
			this.finalResult = this.extractResult(event);
		}
		const waiter = this.waiting.shift();
		if (waiter) {
			waiter({ value: event, done: false });
		} else {
			this.queue.push(event);
		}
	}

	/// Mark the stream as ended. Any pending iterator waiters resolve with
	/// `done: true`. `result()` resolves with the final captured payload (or
	/// the explicit `result` argument), or rejects if neither was provided.
	end(result?: R): void {
		if (this.closed) return;
		this.closed = true;
		const final = result ?? this.finalResult;
		if (final !== undefined) {
			this.finalResultResolve(final as R);
		} else {
			this.finalResultReject(
				new Error("EventStream closed without final result"),
			);
		}
		while (this.waiting.length > 0) {
			const w = this.waiting.shift()!;
			w({ value: undefined, done: true });
		}
	}

	async *[Symbol.asyncIterator](): AsyncIterator<T> {
		while (true) {
			if (this.queue.length > 0) {
				const value = this.queue.shift()!;
				yield value;
				if (this.closed && this.queue.length === 0) return;
				continue;
			}
			if (this.closed) return;
			const next = await new Promise<IteratorResult<T>>((resolve) => {
				this.waiting.push(resolve);
			});
			if (next.done) return;
			yield next.value;
		}
	}

	result(): Promise<R> {
		return this.finalResultPromise;
	}
}

/// Specialized stream where the terminal events are `done` / `error`,
/// both carrying an `AssistantMessage` payload.
export class AssistantMessageEventStream extends EventStream<
	AssistantMessageEvent,
	AssistantMessage
> {
	constructor() {
		super(
			(e) => e.type === "done" || e.type === "error",
			(e) =>
				e.type === "done"
					? e.message
					: e.type === "error"
						? e.error
						: (undefined as unknown as AssistantMessage),
		);
	}
}
