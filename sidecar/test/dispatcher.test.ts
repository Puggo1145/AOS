// Dispatcher tests — uses two StdioTransport instances cross-wired through
// in-memory queues so we can exercise both ends of an RPC conversation
// without actually spawning a subprocess.
//
// Coverage targets per docs/designs/rpc-protocol.md:
//   - Request/response roundtrip with typed result
//   - Inbound handler timeout (ErrTimeout -32002)
//   - Outbound direction enforcement (Bun-side cannot initiate agent.* / ui.*)
//   - Inbound direction enforcement (ui.* request → MethodNotFound)
//   - Notification dispatch (no response)
//   - pending requests rejected on stop()

import { test, expect } from "bun:test";
import { StdioTransport, type ByteSink, type ByteSource } from "../src/rpc/transport";
import { Dispatcher, RPCMethodError, DispatcherStopped } from "../src/rpc/dispatcher";
import { RPCErrorCode, RPCMethod } from "../src/rpc/rpc-types";
import { directionOf } from "../src/rpc/method-catalog";

// ---------------------------------------------------------------------------
// In-memory bidirectional pipe between two transports.
// ---------------------------------------------------------------------------

class Pipe {
  buf: string[] = [];
  waiters: ((s: string) => void)[] = [];
  closed = false;

  push(chunk: string): void {
    if (this.closed) return;
    if (this.waiters.length > 0) {
      this.waiters.shift()!(chunk);
    } else {
      this.buf.push(chunk);
    }
  }

  close(): void {
    this.closed = true;
    while (this.waiters.length > 0) this.waiters.shift()!("");
  }

  asSink(): ByteSink {
    return {
      write: (s: string) => {
        this.push(s);
        return true;
      },
    };
  }

  asSource(): ByteSource {
    const self = this;
    return (async function* () {
      while (true) {
        if (self.buf.length > 0) {
          const s = self.buf.shift()!;
          yield Buffer.from(s, "utf8");
          continue;
        }
        if (self.closed) return;
        const next = await new Promise<string>((r) => self.waiters.push(r));
        if (next === "" && self.closed) return;
        yield Buffer.from(next, "utf8");
      }
    })();
  }
}

interface Pair {
  a: Dispatcher;
  b: Dispatcher;
  close: () => void;
}

function makePair(): Pair {
  const ab = new Pipe(); // a writes, b reads
  const ba = new Pipe(); // b writes, a reads
  const ta = new StdioTransport(ba.asSource(), ab.asSink());
  const tb = new StdioTransport(ab.asSource(), ba.asSink());
  const a = new Dispatcher(ta);
  const b = new Dispatcher(tb, { endpoint: "shell" });
  void a.start();
  void b.start();
  return {
    a,
    b,
    close: () => {
      a.stop();
      b.stop();
      ab.close();
      ba.close();
    },
  };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test("request/response roundtrip", async () => {
  const { a, b, close } = makePair();
  // 'b' acts as Shell: handles rpc.ping (bidirectional namespace).
  b.registerRequest("rpc.ping", async () => ({ ok: true }));
  const r = await a.request<{ ok: boolean }>("rpc.ping", {});
  expect(r).toEqual({ ok: true });
  close();
});

test("handler timeout fires ErrTimeout", async () => {
  const { a, b, close } = makePair();
  // Use rpc.ping (1s timeout) and have the handler hang.
  b.registerRequest("rpc.ping", async () => {
    await new Promise(() => {}); // never resolves
  });
  let caught: unknown;
  try {
    await a.request("rpc.ping", {});
  } catch (e) {
    caught = e;
  }
  expect(caught).toBeInstanceOf(RPCMethodError);
  expect((caught as RPCMethodError).code).toBe(RPCErrorCode.timeout);
  close();
}, 5_000);

test("outbound direction enforcement: Bun cannot initiate agent.*", async () => {
  const { a, close } = makePair();
  let caught: unknown;
  try {
    await a.request("agent.submit", { turnId: "t", prompt: "hi" });
  } catch (e) {
    caught = e;
  }
  expect(String(caught)).toContain("Bun cannot initiate");
  close();
});

test("outbound method direction enforcement rejects Shell-owned mixed namespace requests", async () => {
  const { a, close } = makePair();
  for (const method of [RPCMethod.providerStatus, RPCMethod.devContextGet, RPCMethod.sessionCreate]) {
    let caught: unknown;
    try {
      await a.request(method, {});
    } catch (e) {
      caught = e;
    }
    expect(String(caught)).toContain("Bun cannot initiate");
  }
  close();
});

test("outbound method direction enforcement allows Bun-owned Shell requests", async () => {
  const input = new Pipe();
  const output = new Pipe();
  const dispatcher = new Dispatcher(new StdioTransport(input.asSource(), output.asSink()));

  const pending = dispatcher.request(RPCMethod.computerUseListApps, { mode: "running" }).catch((err) => err);
  await new Promise((r) => setTimeout(r, 10));
  const frame = JSON.parse(output.buf.shift()!);

  expect(frame.method).toBe(RPCMethod.computerUseListApps);
  expect(frame.params).toEqual({ mode: "running" });

  dispatcher.stop();
  await pending;
  input.close();
  output.close();
});

test("method catalog marks computerUse.* as Bun to Shell", () => {
  expect(directionOf("computerUse.listApps")).toBe("bunToShell");
});

test("inbound ui.* request triggers MethodNotFound (low-level)", async () => {
  // Direct-injection variant: we wire up only Bun-side `a` and feed the pipe
  // a hand-crafted ui.token Request frame, then assert the error response.
  const inPipe = new Pipe();
  const outPipe = new Pipe();
  const transport = new StdioTransport(inPipe.asSource(), outPipe.asSink());
  const d = new Dispatcher(transport);
  await d.start();
  // Hand-craft a Request from 'Shell' targeting ui.token (forbidden direction).
  inPipe.push(JSON.stringify({ jsonrpc: "2.0", id: "x1", method: "ui.token", params: {} }) + "\n");
  // Read response from outPipe by polling its buffer.
  const responseLine = await new Promise<string>((resolve) => {
    const tick = setInterval(() => {
      if (outPipe.buf.length > 0) {
        clearInterval(tick);
        resolve(outPipe.buf.shift()!);
      }
    }, 5);
  });
  const resp = JSON.parse(responseLine);
  expect(resp.id).toBe("x1");
  expect(resp.error?.code).toBe(RPCErrorCode.methodNotFound);
  d.stop();
});

test("notification dispatch with no response", async () => {
  const { a, b, close } = makePair();
  let received: any = undefined;
  b.registerNotification(RPCMethod.devContextChanged, async (params) => {
    received = params;
  });
  a.notify(RPCMethod.devContextChanged, { hello: "world" });
  // Allow the microtask + I/O to flush.
  await new Promise((r) => setTimeout(r, 50));
  expect(received).toEqual({ hello: "world" });
  close();
});

test("registration validates request and notification method semantics", () => {
  const { a, close } = makePair();

  expect(() => a.registerRequest(RPCMethod.providerStatusChanged, async () => ({}))).toThrow(/notification method/);
  expect(() => a.registerNotification(RPCMethod.providerStatus, async () => {})).toThrow(/request method/);
  expect(() => a.registerRequest("unknown.method", async () => ({}))).toThrow(/unknown RPC method/);
  expect(() => a.registerNotification("unknown.method", async () => {})).toThrow(/unknown RPC method/);

  close();
});

// ---------------------------------------------------------------------------
// dev.* split-direction enforcement (P2.1 fix).
//
// Mixed namespaces contain request methods (`dev.context.get`) and notification
// methods (`dev.context.changed`). The RPC Method Catalog catches "wrong shape"
// misuse at the boundary instead of letting it fail silently downstream.
// ---------------------------------------------------------------------------

test("split-direction: notify('dev.context.get', ...) throws programmer error", () => {
  const { a, close } = makePair();
  expect(() => a.notify("dev.context.get", {})).toThrow(/notification/);
  close();
});

test("split-direction: request('dev.context.changed', ...) rejects with programmer error", async () => {
  const { a, close } = makePair();
  let caught: unknown;
  try {
    await a.request("dev.context.changed", {});
  } catch (e) {
    caught = e;
  }
  expect(String(caught)).toContain("notification method");
  close();
});

// Symmetric guard for provider.* — exercises the same `splitKindOf` lookup so
// regressions in the unified table are caught for both namespaces, not just
// the newly added one.
test("split-direction: notify('provider.status', ...) still throws (provider.* parity)", () => {
  const { a, close } = makePair();
  expect(() => a.notify("provider.status", {})).toThrow(/request method/);
  close();
});

test("stop() rejects all pending outbound requests with DispatcherStopped", async () => {
  const { a, b, close } = makePair();
  // b never registers a handler so this would hang otherwise.
  // Use a handler that resolves super-late so we have time to stop().
  b.registerRequest("rpc.ping", async () => {
    await new Promise((r) => setTimeout(r, 5_000));
    return {};
  });
  const p = a.request("rpc.ping", {});
  // Stop after a tick to ensure the pending entry is registered.
  setTimeout(() => a.stop(), 10);
  let caught: unknown;
  try {
    await p;
  } catch (e) {
    caught = e;
  }
  expect(caught).toBeInstanceOf(DispatcherStopped);
  close();
});
