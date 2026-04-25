// JSON-RPC 2.0 dispatcher for the AOS sidecar.
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
//   - Direction enforcement per Namespace table:
//       agent.*, settings.* — Shell→Bun only. Bun calling request("agent.*")
//         is a programmer error.
//       computerUse.*, ui.*  — Bun→Shell only. Inbound Request from Shell on
//         these namespaces is rejected with MethodNotFound.
//       rpc.*               — bidirectional.
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
import { StdioTransport } from "./transport";
import { logger } from "../log";

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

export class RPCMethodError extends Error {
  constructor(public readonly code: number, message: string, public readonly data?: JSONValue) {
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
// Inbound timeouts (ms) — per rpc-protocol.md "Dispatcher 并发模型".
// Only methods this round handles need entries. Unknown methods get the
// generic default; handlers that hang past the budget receive ErrTimeout.
// ---------------------------------------------------------------------------

const INBOUND_HANDLER_TIMEOUTS: Record<string, number> = {
  "rpc.ping": 1_000,
  "agent.submit": 1_000, // ack budget; the streaming work is detached
  "agent.cancel": 1_000,
};

const DEFAULT_HANDLER_TIMEOUT_MS = 5_000;

// Methods that bypass the (currently nonexistent) long-running queue and run
// as inline fast-path tasks. Encoded as a Set so the reader loop check is O(1).
const FAST_PATH_METHODS = new Set<string>(["rpc.ping", "agent.cancel"]);

// ---------------------------------------------------------------------------
// Namespace direction enforcement
// ---------------------------------------------------------------------------

type Direction = "shellToBun" | "bunToShell" | "both";

function namespaceOf(method: string): string {
  const i = method.indexOf(".");
  return i < 0 ? method : method.slice(0, i);
}

function directionOf(method: string): Direction {
  const ns = namespaceOf(method);
  switch (ns) {
    case "rpc":
      return "both";
    case "agent":
    case "settings":
    case "config":
      return "shellToBun";
    case "computerUse":
    case "ui":
    case "conversation":
      return "bunToShell";
    case "provider":
      // Method-level direction: status/startLogin/cancelLogin are Shell→Bun
      // (inbound requests we handle), while loginStatus/statusChanged are
      // Bun→Shell notifications. The namespace is `both`; the per-method
      // restriction is enforced via PROVIDER_METHOD_DIRECTIONS below so
      // dispatcher.notify("provider.status", ...) throws (request method
      // shouldn't be sent as a notification).
      return "both";
    default:
      // Unknown namespace: be conservative — treat as "no direction allowed".
      // Inbound: MethodNotFound; outbound: programmer error.
      return "shellToBun"; // accept inbound; outbound will hit handler-not-found
  }
}

/// Per-method direction within `provider.*`. Requests are Shell→Bun;
/// notifications are Bun→Shell. Unknown methods fall through to
/// MethodNotFound on the inbound side and a programmer-error on outbound.
type ProviderMethodKind = "request" | "notification";
const PROVIDER_METHOD_KINDS: Record<string, ProviderMethodKind> = {
  "provider.status": "request",
  "provider.startLogin": "request",
  "provider.cancelLogin": "request",
  "provider.loginStatus": "notification",
  "provider.statusChanged": "notification",
};

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
  private readonly notificationHandlers = new Map<string, NotificationHandler>();
  private readonly pending = new Map<RPCId, Pending>();
  private nextId = 1;
  private started = false;
  private stopped = false;
  private readerPromise?: Promise<void>;

  constructor(private readonly transport: StdioTransport) {}

  // -------------------------------------------------------------------------
  // Registration
  // -------------------------------------------------------------------------

  registerRequest(method: string, handler: RequestHandler): void {
    if (this.requestHandlers.has(method)) {
      throw new Error(`request handler already registered: ${method}`);
    }
    this.requestHandlers.set(method, handler);
  }

  registerNotification(method: string, handler: NotificationHandler): void {
    if (this.notificationHandlers.has(method)) {
      throw new Error(`notification handler already registered: ${method}`);
    }
    this.notificationHandlers.set(method, handler);
  }

  // -------------------------------------------------------------------------
  // Outbound
  // -------------------------------------------------------------------------

  request<R>(method: string, params: object, opts?: RequestOptions): Promise<R> {
    if (this.stopped) return Promise.reject(new DispatcherStopped());
    const dir = directionOf(method);
    if (dir === "shellToBun") {
      // Bun is initiating a method whose contract is Shell→Bun-only.
      return Promise.reject(
        new Error(`programmer error: Bun cannot initiate '${method}' (namespace direction shellToBun)`),
      );
    }

    const id: RPCId = `bun-${this.nextId++}`;
    const frame: RPCRequest<object> = { jsonrpc: "2.0", id, method, params };

    return new Promise<R>((resolve, reject) => {
      const pending: Pending = { resolve, reject };

      if (opts?.timeoutMs && opts.timeoutMs > 0) {
        pending.timer = setTimeout(() => {
          this.pending.delete(id);
          reject(new RPCMethodError(RPCErrorCode.timeout, `outbound request '${method}' timed out`));
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
        pending.signalCleanup = () => opts.signal!.removeEventListener("abort", onAbort);
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
    const dir = directionOf(method);
    if (dir === "shellToBun") {
      throw new Error(`programmer error: Bun cannot send notification '${method}' (direction shellToBun)`);
    }
    // provider.* is `both` at namespace level, but request methods must not
    // be sent as notifications (and vice versa).
    const kind = PROVIDER_METHOD_KINDS[method];
    if (kind === "request") {
      throw new Error(`programmer error: '${method}' is a request method, cannot be sent as notification`);
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
      this.dispatchResponse(obj as unknown as RPCResponse<unknown> | RPCErrorResponse);
    } else {
      logger.warn("dropped frame: cannot classify");
    }
  }

  private dispatchRequest(req: RPCRequest<unknown>): void {
    const { id, method, params } = req;

    // Direction enforcement: ui.* / computerUse.* are Bun→Shell only;
    // receiving them as inbound Request is a misuse — reply MethodNotFound.
    const dir = directionOf(method);
    if (dir === "bunToShell") {
      this.replyError(id, RPCErrorCode.methodNotFound, `method '${method}' is Bun→Shell only`);
      return;
    }

    const handler = this.requestHandlers.get(method);
    if (!handler) {
      this.replyError(id, RPCErrorCode.methodNotFound, `unknown method '${method}'`);
      return;
    }

    const timeoutMs = INBOUND_HANDLER_TIMEOUTS[method] ?? DEFAULT_HANDLER_TIMEOUT_MS;

    // Fast path is currently equivalent to spawning a microtask, since this
    // round has no long-running queued handlers. The branch is preserved so a
    // future scheduler with a queued worker can short-circuit ping/cancel.
    const isFastPath = FAST_PATH_METHODS.has(method);
    const launch = () => this.runHandler(handler, params, id, method, timeoutMs);
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
        reject(new RPCMethodError(RPCErrorCode.timeout, `handler for '${method}' timed out after ${timeoutMs}ms`));
      }, timeoutMs);
    });
    try {
      const result = await Promise.race([handler(params, { id }), timeoutPromise]);
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
    const handler = this.notificationHandlers.get(note.method);
    if (!handler) {
      // Unknown notifications are silently ignored per JSON-RPC 2.0.
      return;
    }
    queueMicrotask(() => {
      handler(note.params).catch((err) => {
        logger.error("notification handler threw", { method: note.method, err: String(err) });
      });
    });
  }

  private dispatchResponse(resp: RPCResponse<unknown> | RPCErrorResponse): void {
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
      pending.reject(new RPCMethodError(resp.error.code, resp.error.message, resp.error.data));
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

  private replyError(id: RPCId, code: number, message: string, data?: JSONValue): void {
    const frame: RPCErrorResponse = {
      jsonrpc: "2.0",
      id,
      error: data === undefined ? { code, message } : { code, message, data },
    };
    this.transport.writeLine(JSON.stringify(frame)).catch((err) => {
      logger.error("reply error write failed", { id: String(id), err: String(err) });
    });
  }
}
