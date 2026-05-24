// session.* dispatcher tests — direction enforcement + handler smoke tests.
//
// The RPC Method Catalog gives each `session.*` method explicit direction and
// request/notification semantics. This file proves both halves: (a) sidecar
// emits `session.created` etc. as notifications and the dispatcher accepts
// that path, (b) sending a session.* request method as a notification (or vice
// versa) throws programmer errors.

import { test, expect } from "bun:test";
import { Dispatcher } from "../src/rpc/dispatcher";
import { StdioTransport, type ByteSink, type ByteSource } from "../src/rpc/transport";
import { SessionManager } from "../src/agent/session/manager";
import { registerSessionHandlers } from "../src/agent/session/handlers";

// Minimal capturing dispatcher — same shape as agent-loop.test.ts but trimmed
// to what session tests need (no LLM stream, no agent.* handlers).
interface Captured {
  notifications: { method: string; params: any }[];
  responses: { id: any; result?: any; error?: any }[];
}

function makeCapturingDispatcher(): {
  dispatcher: Dispatcher;
  captured: Captured;
  pushInbound: (frame: object) => void;
} {
  const inbound: string[] = [];
  const inboundWaiters: ((s: string) => void)[] = [];
  const source: ByteSource = (async function* () {
    while (true) {
      if (inbound.length > 0) {
        yield Buffer.from(inbound.shift()!, "utf8");
        continue;
      }
      yield Buffer.from(await new Promise<string>((r) => inboundWaiters.push(r)), "utf8");
    }
  })();
  const captured: Captured = { notifications: [], responses: [] };
  const sink: ByteSink = {
    write(line: string): boolean {
      const trimmed = line.endsWith("\n") ? line.slice(0, -1) : line;
      const frame = JSON.parse(trimmed);
      if ("method" in frame && !("id" in frame)) {
        captured.notifications.push({ method: frame.method, params: frame.params });
      } else if ("id" in frame) {
        captured.responses.push({ id: frame.id, result: frame.result, error: frame.error });
      }
      return true;
    },
  };
  const transport = new StdioTransport(source, sink);
  const dispatcher = new Dispatcher(transport);
  void dispatcher.start();
  return {
    dispatcher,
    captured,
    pushInbound: (frame: object) => {
      const line = JSON.stringify(frame) + "\n";
      if (inboundWaiters.length > 0) inboundWaiters.shift()!(line);
      else inbound.push(line);
    },
  };
}

async function flush(ms = 30): Promise<void> {
  await new Promise((r) => setTimeout(r, ms));
}

test("session.create over the wire emits created+activated and returns a SessionListItem", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const manager = new SessionManager();
  registerSessionHandlers(dispatcher, manager);

  pushInbound({ jsonrpc: "2.0", id: 1, method: "session.create", params: { title: "alpha" } });
  await flush(20);

  // Response carries the freshly created SessionListItem.
  expect(captured.responses).toHaveLength(1);
  const result = captured.responses[0].result;
  expect(result.session.id).toMatch(/^sess_/);
  expect(result.session.title).toBe("alpha");
  expect(result.session.turnCount).toBe(0);

  // Sink fired both `session.created` and `session.activated` because manager
  // auto-activates on create.
  const methods = captured.notifications.map((n) => n.method);
  expect(methods).toEqual(["session.created", "session.activated"]);
});

test("session.list returns activeId + sessions in creation order", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const manager = new SessionManager();
  registerSessionHandlers(dispatcher, manager);
  const a = manager.create({ title: "a" });
  const b = manager.create({ title: "b" });

  pushInbound({ jsonrpc: "2.0", id: 1, method: "session.list", params: {} });
  await flush(20);

  const result = captured.responses.find((r) => r.id === 1)?.result;
  expect(result.activeId).toBe(b.id);
  expect(result.sessions.map((s: any) => s.id)).toEqual([a.id, b.id]);
});

test("session.activate returns the conversation snapshot", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const manager = new SessionManager();
  registerSessionHandlers(dispatcher, manager);
  const a = manager.create();
  // Seed a turn on A so activate snapshot is non-empty.
  a.conversation.startTurn({ id: "t1", prompt: "hi", citedContext: {} });
  manager.create(); // B is now active.

  pushInbound({ jsonrpc: "2.0", id: 1, method: "session.activate", params: { sessionId: a.id } });
  await flush(20);

  const result = captured.responses.find((r) => r.id === 1)?.result;
  expect(result.snapshot).toHaveLength(1);
  expect(result.snapshot[0].id).toBe("t1");
  // Active flipped back to A.
  expect(manager.activeId).toBe(a.id);
});

test("session.activate with unknown id returns unknownSession (-32400)", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const manager = new SessionManager();
  registerSessionHandlers(dispatcher, manager);

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "session.activate",
    params: { sessionId: "sess_doesnotexist" },
  });
  await flush(20);

  const resp = captured.responses.find((r) => r.id === 1);
  expect(resp?.error?.code).toBe(-32400);
});

test("dispatcher rejects session.create as a notification", () => {
  const { dispatcher } = makeCapturingDispatcher();
  expect(() => dispatcher.notify("session.create", {})).toThrow(/notification/);
});

test("dispatcher rejects session.created as an outbound request", async () => {
  const { dispatcher } = makeCapturingDispatcher();
  await expect(dispatcher.request("session.created", {})).rejects.toThrow(/notification method/);
});
