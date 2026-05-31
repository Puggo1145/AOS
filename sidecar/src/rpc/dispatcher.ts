// JSON-RPC 2.0 dispatcher for the Notch Agent sidecar.
//
// Implements the contract in docs/designs/rpc-protocol.md §"Dispatcher 并发模型"
// and §"Namespace 规则":
//   - Single reader loop over StdioTransport.readLines().
//   - Inbound Request: spawn a fresh async task per request so the reader
//     loop never blocks on handler execution.
//   - rpc.ping and agent.cancel are FAST PATH: dispatched inline ahead of any
//     queued long-running handler. (No long-running handlers exist this round
//     — agent.submit acks immediately and runs the LLM stream in a detached
//     background task — but the bypass is implemented for design correctness.)
//   - Per-method ack timeout. agent.submit and agent.cancel ack within 1s;
//     rpc.ping within 1s. Timeout reply is ErrTimeout (-32002).
//   - Direction enforcement per RPC Method Catalog direction:
//       agent.*, settings.* — Shell→Bun only. Bun calling request("agent.*")
//         is a programmer error.
//       ui.*  — Bun→Shell only. Inbound Request from Shell on this namespace
//         is rejected with MethodNotFound.
//       provider.* / dev.* / session.* mixed namespaces are enforced per
//         method direction and request vs notification kind.
//   - Outbound `request` keeps a pending map keyed by RPCId; resolved on
//     response. `stop()` rejects all pending with DispatcherStopped.

import {
	RPCErrorCode,
	type RPCErrorResponse,
	type RPCId,
	type RPCRequest,
	type RPCResponse,
	type RPCNotification,
	type JSONValue,
} from "./rpc-types";
import type { StdioTransport } from "./transport";
import { logger } from "../log";
import { rpcMethodSemantics } from "./method-catalog";

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

export type RequestHandler = (params: any, ctx: { id: RPCId }) => Promise<any>;
export type NotificationHandler = (params: any) => Promise<void>;

export interface RequestOptions {
	signal?: AbortSignal;
	/// Optional override; default is no timeout for outbound requests
	/// (per spec: Shell→Bun requests don't have client-side timeouts; the
	/// caller decides). For Bun→Shell handshake we pass an explicit signal.
	timeoutMs?: number;
}

export type DispatcherEndpoint = "bun" | "shell";

export interface DispatcherOptions {
	/// The production Sidecar dispatcher runs as the Bun endpoint. Tests may
	/// instantiate a Shell endpoint when using this TS dispatcher as a peer.
	endpoint?: DispatcherEndpoint;
}

export class RPCMethodError extends Error {
	constructor(
		public readonly code: number,
		message: string,
		public readonly data?: JSONValue,
	) {
		super(message);
		this.name = "RPCMethodError";
	}
}

export class DispatcherStopped extends Error {
	constructor() {
		super("dispatcher stopped");
		this.name = "DispatcherStopped";
	}
}

// ---------------------------------------------------------------------------
// Dispatcher
// ---------------------------------------------------------------------------

interface Pending {
	resolve: (value: any) => void;
	reject: (err: unknown) => void;
	timer?: ReturnType<typeof setTimeout>;
	signalCleanup?: () => void;
}

export class Dispatcher {
	private readonly requestHandlers = new Map<string, RequestHandler>();
	private readonly notificationHandlers = new Map<
		string,
		NotificationHandler
	>();
	private readonly pending = new Map<RPCId, Pending>();
	private nextId = 1;
	private started = false;
	private stopped = false;
	private readerPromise?: Promise<void>;
	private readonly endpoint: DispatcherEndpoint;

	constructor(
		private readonly transport: StdioTransport,
		opts: DispatcherOptions = {},
	) {
		this.endpoint = opts.endpoint ?? "bun";
	}

	// -------------------------------------------------------------------------
	// Registration
	// -------------------------------------------------------------------------

	registerRequest(method: string, handler: RequestHandler): void {
		const semantics = this.requireRegisteredMethod(method);
		if (semantics.kind === "notification") {
			throw new Error(
				`programmer error: '${method}' is a notification method, cannot register request handler`,
			);
		}
		if (!this.canReceive(semantics.direction)) {
			throw new Error(
				`programmer error: ${this.endpoint} endpoint cannot receive request '${method}'`,
			);
		}
		if (this.requestHandlers.has(method)) {
			throw new Error(`request handler already registered: ${method}`);
		}
		this.requestHandlers.set(method, handler);
	}

	registerNotification(method: string, handler: NotificationHandler): void {
		const semantics = this.requireRegisteredMethod(method);
		if (semantics.kind === "request") {
			throw new Error(
				`programmer error: '${method}' is a request method, cannot register notification handler`,
			);
		}
		if (!this.canReceive(semantics.direction)) {
			throw new Error(
				`programmer error: ${this.endpoint} endpoint cannot receive notification '${method}'`,
			);
		}
		if (this.notificationHandlers.has(method)) {
			throw new Error(`notification handler already registered: ${method}`);
		}
		this.notificationHandlers.set(method, handler);
	}

	// -------------------------------------------------------------------------
	// Outbound
	// -------------------------------------------------------------------------

	request<R>(
		method: string,
		params: object,
		opts?: RequestOptions,
	): Promise<R> {
		if (this.stopped) return Promise.reject(new DispatcherStopped());
		const semantics = rpcMethodSemantics(method);
		if (!semantics) {
			return Promise.reject(
				new Error(`programmer error: unknown RPC method '${method}'`),
			);
		}
		if (!this.canSend(semantics.direction)) {
			// Bun is initiating a method whose contract is Shell→Bun-only.
			return Promise.reject(
				new Error(
					`programmer error: Bun cannot initiate '${method}' (method direction shellToBun)`,
				),
			);
		}
		// Within `both`-direction namespaces (provider.*, dev.*) some methods are
		// notifications, not requests. Initiating one as a request is a
		// programmer error and must fail loudly — same shape as `notify` below.
		if (semantics.kind === "notification") {
			return Promise.reject(
				new Error(
					`programmer error: '${method}' is a notification method, cannot be sent as request`,
				),
			);
		}

		const id: RPCId = `bun-${this.nextId++}`;
		const frame: RPCRequest<object> = { jsonrpc: "2.0", id, method, params };

		return new Promise<R>((resolve, reject) => {
			const pending: Pending = { resolve, reject };

			if (opts?.timeoutMs && opts.timeoutMs > 0) {
				pending.timer = setTimeout(() => {
					this.pending.delete(id);
					reject(
						new RPCMethodError(
							RPCErrorCode.timeout,
							`outbound request '${method}' timed out`,
						),
					);
				}, opts.timeoutMs);
			}

			if (opts?.signal) {
				if (opts.signal.aborted) {
					reject(new Error("request aborted before send"));
					return;
				}
				const onAbort = () => {
					const p = this.pending.get(id);
					if (!p) return;
					this.pending.delete(id);
					if (p.timer) clearTimeout(p.timer);
					reject(new Error(`request '${method}' aborted`));
				};
				opts.signal.addEventListener("abort", onAbort, { once: true });
				pending.signalCleanup = () =>
					opts.signal!.removeEventListener("abort", onAbort);
			}

			this.pending.set(id, pending);
			this.transport.writeLine(JSON.stringify(frame)).catch((err) => {
				this.pending.delete(id);
				if (pending.timer) clearTimeout(pending.timer);
				pending.signalCleanup?.();
				reject(err);
			});
		});
	}

	notify(method: string, params: object): void {
		if (this.stopped) return;
		const semantics = rpcMethodSemantics(method);
		if (!semantics) {
			throw new Error(`programmer error: unknown RPC method '${method}'`);
		}
		// provider.* / dev.* are `both` at namespace level, but request methods
		// must not be sent as notifications (and vice versa).
		if (semantics.kind === "request") {
			throw new Error(
				`programmer error: '${method}' is a request method, cannot be sent as notification`,
			);
		}
		if (!this.canSend(semantics.direction)) {
			throw new Error(
				`programmer error: Bun cannot send notification '${method}' (direction shellToBun)`,
			);
		}
		const frame: RPCNotification<object> = { jsonrpc: "2.0", method, params };
		this.transport.writeLine(JSON.stringify(frame)).catch((err) => {
			logger.error("notify write failed", { method, err: String(err) });
		});
	}

	// -------------------------------------------------------------------------
	// Lifecycle
	// -------------------------------------------------------------------------

	async start(): Promise<void> {
		if (this.started) return;
		this.started = true;
		this.readerPromise = this.runReader();
		// Don't await — the reader runs forever.
	}

	stop(): void {
		if (this.stopped) return;
		this.stopped = true;
		for (const [id, p] of this.pending) {
			if (p.timer) clearTimeout(p.timer);
			p.signalCleanup?.();
			p.reject(new DispatcherStopped());
			this.pending.delete(id);
		}
		this.transport.close();
	}

	/// Await the reader loop's exit (mostly for tests).
	async waitForReaderExit(): Promise<void> {
		await this.readerPromise;
	}

	// -------------------------------------------------------------------------
	// Reader loop
	// -------------------------------------------------------------------------

	private async runReader(): Promise<void> {
		try {
			for await (const line of this.transport.readLines()) {
				if (this.stopped) break;
				this.handleLine(line);
			}
		} catch (err) {
			logger.error("dispatcher reader exited with error", { err: String(err) });
		} finally {
			this.stop();
		}
	}

	private handleLine(line: string): void {
		let parsed: unknown;
		try {
			parsed = JSON.parse(line);
		} catch (err) {
			logger.warn("dropped invalid JSON frame", { err: String(err) });
			return;
		}
		if (!parsed || typeof parsed !== "object") {
			logger.warn("dropped non-object frame");
			return;
		}
		const obj = parsed as Record<string, unknown>;

		if ("method" in obj && "id" in obj) {
			this.dispatchRequest(obj as unknown as RPCRequest<unknown>);
		} else if ("method" in obj) {
			this.dispatchNotification(obj as unknown as RPCNotification<unknown>);
		} else if ("id" in obj && ("result" in obj || "error" in obj)) {
			this.dispatchResponse(
				obj as unknown as RPCResponse<unknown> | RPCErrorResponse,
			);
		} else {
			logger.warn("dropped frame: cannot classify");
		}
	}

	private dispatchRequest(req: RPCRequest<unknown>): void {
		const { id, method, params } = req;

		// Direction enforcement: ui.* is Bun→Shell only; receiving it as inbound
		// Request is a misuse — reply MethodNotFound.
		const semantics = rpcMethodSemantics(method);
		if (!semantics) {
			this.replyError(
				id,
				RPCErrorCode.methodNotFound,
				`unknown method '${method}'`,
			);
			return;
		}
		if (!this.canReceive(semantics.direction)) {
			this.replyError(
				id,
				RPCErrorCode.methodNotFound,
				`method '${method}' is Bun→Shell only`,
			);
			return;
		}
		if (semantics.kind === "notification") {
			this.replyError(
				id,
				RPCErrorCode.methodNotFound,
				`method '${method}' is a notification method`,
			);
			return;
		}

		const handler = this.requestHandlers.get(method);
		if (!handler) {
			this.replyError(
				id,
				RPCErrorCode.methodNotFound,
				`unknown method '${method}'`,
			);
			return;
		}

		const timeoutMs = semantics.inboundTimeoutMs;

		// Fast path is currently equivalent to spawning a microtask, since this
		// round has no long-running queued handlers. The branch is preserved so a
		// future scheduler with a queued worker can short-circuit ping/cancel.
		const isFastPath = semantics.fastPath;
		const launch = () =>
			this.runHandler(handler, params, id, method, timeoutMs);
		if (isFastPath) {
			// Run inline (still async, but not deferred behind any queue).
			void launch();
		} else {
			// Spawn detached so the reader loop is never blocked.
			queueMicrotask(() => void launch());
		}
	}

	private async runHandler(
		handler: RequestHandler,
		params: unknown,
		id: RPCId,
		method: string,
		timeoutMs: number,
	): Promise<void> {
		let timer: ReturnType<typeof setTimeout> | undefined;
		let timedOut = false;
		const timeoutPromise = new Promise<never>((_, reject) => {
			timer = setTimeout(() => {
				timedOut = true;
				reject(
					new RPCMethodError(
						RPCErrorCode.timeout,
						`handler for '${method}' timed out after ${timeoutMs}ms`,
					),
				);
			}, timeoutMs);
		});
		try {
			const result = await Promise.race([
				handler(params, { id }),
				timeoutPromise,
			]);
			if (timer) clearTimeout(timer);
			if (timedOut) return; // already replied via catch path
			this.replyResult(id, result);
		} catch (err) {
			if (timer) clearTimeout(timer);
			if (err instanceof RPCMethodError) {
				this.replyError(id, err.code, err.message, err.data);
			} else {
				const msg = err instanceof Error ? err.message : String(err);
				this.replyError(id, RPCErrorCode.internalError, msg);
			}
		}
	}

	private dispatchNotification(note: RPCNotification<unknown>): void {
		const semantics = rpcMethodSemantics(note.method);
		if (
			semantics?.kind !== "notification" ||
			!this.canReceive(semantics.direction)
		) {
			return;
		}
		const handler = this.notificationHandlers.get(note.method);
		if (!handler) {
			// Unknown notifications are silently ignored per JSON-RPC 2.0.
			return;
		}
		queueMicrotask(() => {
			handler(note.params).catch((err) => {
				logger.error("notification handler threw", {
					method: note.method,
					err: String(err),
				});
			});
		});
	}

	private dispatchResponse(
		resp: RPCResponse<unknown> | RPCErrorResponse,
	): void {
		const id = resp.id;
		const pending = this.pending.get(id);
		if (!pending) {
			logger.warn("response for unknown id", { id: String(id) });
			return;
		}
		this.pending.delete(id);
		if (pending.timer) clearTimeout(pending.timer);
		pending.signalCleanup?.();
		if ("error" in resp) {
			pending.reject(
				new RPCMethodError(
					resp.error.code,
					resp.error.message,
					resp.error.data,
				),
			);
		} else {
			pending.resolve(resp.result);
		}
	}

	private replyResult(id: RPCId, result: unknown): void {
		const frame: RPCResponse<unknown> = { jsonrpc: "2.0", id, result };
		this.transport.writeLine(JSON.stringify(frame)).catch((err) => {
			logger.error("reply write failed", { id: String(id), err: String(err) });
		});
	}

	private replyError(
		id: RPCId,
		code: number,
		message: string,
		data?: JSONValue,
	): void {
		const frame: RPCErrorResponse = {
			jsonrpc: "2.0",
			id,
			error: data === undefined ? { code, message } : { code, message, data },
		};
		this.transport.writeLine(JSON.stringify(frame)).catch((err) => {
			logger.error("reply error write failed", {
				id: String(id),
				err: String(err),
			});
		});
	}

	private requireRegisteredMethod(
		method: string,
	): NonNullable<ReturnType<typeof rpcMethodSemantics>> {
		const semantics = rpcMethodSemantics(method);
		if (!semantics)
			throw new Error(`programmer error: unknown RPC method '${method}'`);
		return semantics;
	}

	private canSend(direction: "shellToBun" | "bunToShell" | "both"): boolean {
		if (direction === "both") return true;
		return this.endpoint === "bun"
			? direction === "bunToShell"
			: direction === "shellToBun";
	}

	private canReceive(direction: "shellToBun" | "bunToShell" | "both"): boolean {
		if (direction === "both") return true;
		return this.endpoint === "bun"
			? direction === "shellToBun"
			: direction === "bunToShell";
	}
}
