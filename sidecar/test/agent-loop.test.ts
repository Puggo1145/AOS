// Agent loop tests — verify the agent.submit/agent.cancel handlers wire the
// LLM stream into ui.token / ui.status / ui.error notifications correctly.
//
// Strategy: register a fake api provider on the public llm api-registry, build
// an in-memory model object, and inject it via setModelResolver(). The fake
// stream lets us deterministically push text deltas, errors, or hang for cancel.

import { test, expect, beforeEach, afterEach } from "bun:test";
import { Dispatcher } from "../src/rpc/dispatcher";
import { StdioTransport, type ByteSink, type ByteSource } from "../src/rpc/transport";
import { registerAgentHandlers, setModelResolver, resetModelResolver } from "../src/agent/loop";
import { TurnRegistry } from "../src/agent/registry";
import { Conversation } from "../src/agent/conversation";
import {
  registerApiProvider,
  unregisterApiProviders,
  type Model,
  type Api,
  type AssistantMessage,
} from "../src/llm";
import { AssistantMessageEventStream } from "../src/llm/utils/event-stream";
import { RPCErrorCode } from "../src/rpc/rpc-types";

// ---------------------------------------------------------------------------
// Fake provider plumbing.
// We register under api: "openai-responses" with a unique sourceId so we can
// unregister between tests; the loop only ever asks for the model returned by
// the injected resolver, so the api string doesn't have to match a real one.
// ---------------------------------------------------------------------------

const FAKE_SOURCE_ID = "test-agent-loop";

function makeFakeModel(): Model<Api> {
  return {
    id: "fake-model",
    name: "Fake",
    api: "openai-responses",
    provider: "test",
    baseUrl: "",
    reasoning: false,
    input: ["text"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 100_000,
    maxTokens: 1_000,
  };
}

function fakeAssistantMessage(model: Model<Api>, opts: { errorMessage?: string } = {}): AssistantMessage {
  return {
    role: "assistant",
    content: [],
    api: model.api,
    provider: model.provider,
    model: model.id,
    usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
    stopReason: opts.errorMessage ? "error" : "stop",
    errorMessage: opts.errorMessage,
    timestamp: Date.now(),
  };
}

// Each test installs its own stream behavior via this mutable ref.
let nextStream: ((model: Model<Api>, signal?: AbortSignal) => AssistantMessageEventStream) | null = null;

beforeEach(() => {
  registerApiProvider({
    api: "openai-responses",
    sourceId: FAKE_SOURCE_ID,
    stream: (model, _ctx, options) => {
      if (!nextStream) throw new Error("test forgot to set nextStream");
      return nextStream(model, options?.signal);
    },
  });
  setModelResolver(() => makeFakeModel());
});

afterEach(() => {
  unregisterApiProviders(FAKE_SOURCE_ID);
  resetModelResolver();
  nextStream = null;
});

// ---------------------------------------------------------------------------
// Capturing dispatcher: collects outbound notifications + answers ack requests.
// We don't need a real peer for these tests — we wire a one-sided dispatcher
// whose stdout sink captures every frame.
// ---------------------------------------------------------------------------

interface Captured {
  notifications: { method: string; params: any }[];
  responses: { id: any; result?: any; error?: any }[];
}

function makeCapturingDispatcher(): { dispatcher: Dispatcher; captured: Captured; pushInbound: (frame: object) => void } {
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test("happy path: ack + turnStarted + thinking + tokens + done", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const convo = new Conversation();
  registerAgentHandlers(dispatcher, { registry: new TurnRegistry(), conversation: convo });

  nextStream = (model) => {
    const s = new AssistantMessageEventStream();
    queueMicrotask(async () => {
      const partial = fakeAssistantMessage(model);
      s.push({ type: "text_delta", contentIndex: 0, delta: "Hello", partial });
      s.push({ type: "text_delta", contentIndex: 0, delta: ", world", partial });
      s.push({ type: "done", reason: "stop", message: partial });
      s.end();
    });
    return s;
  };

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.submit",
    params: { turnId: "T1", prompt: "hi", citedContext: {} },
  });

  await flush(80);

  // Ack must come back with accepted: true.
  expect(captured.responses).toHaveLength(1);
  expect(captured.responses[0].result).toEqual({ accepted: true });

  // First two notifications: conversation.turnStarted (snapshot of the
  // freshly registered turn) then ui.status thinking. Order matters — the
  // turn must exist in observers' mirrors before any token / status delta
  // can land on it.
  const methods = captured.notifications.map((n) => n.method);
  expect(methods.slice(0, 2)).toEqual(["conversation.turnStarted", "ui.status"]);
  expect(captured.notifications[0].params.turn).toMatchObject({
    id: "T1",
    prompt: "hi",
    reply: "",
    status: "thinking",
  });
  expect(captured.notifications[1].params).toEqual({ turnId: "T1", status: "thinking" });

  const tokens = captured.notifications.filter((n) => n.method === "ui.token");
  expect(tokens.map((t) => t.params.delta).join("")).toBe("Hello, world");

  const last = captured.notifications.at(-1)!;
  expect(last).toEqual({ method: "ui.status", params: { turnId: "T1", status: "done" } });

  // Conversation now holds the completed turn with both the streamed reply
  // and the AssistantMessage stash needed to replay this turn into the next
  // request's LLM context.
  expect(convo.turns).toHaveLength(1);
  expect(convo.turns[0].status).toBe("done");
  expect(convo.turns[0].reply).toBe("Hello, world");
  expect(convo.turns[0].finalAssistant).toBeDefined();
});

test("cancel path: agent.cancel aborts the stream and emits status done", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const convo = new Conversation();
  registerAgentHandlers(dispatcher, { registry: new TurnRegistry(), conversation: convo });

  let abortFired = false;
  nextStream = (model, signal) => {
    const s = new AssistantMessageEventStream();
    queueMicrotask(async () => {
      const partial = fakeAssistantMessage(model);
      s.push({ type: "text_delta", contentIndex: 0, delta: "first", partial });
      // Wait until the abort signal fires, then end without further events.
      await new Promise<void>((resolve) => {
        if (signal?.aborted) return resolve();
        signal?.addEventListener("abort", () => {
          abortFired = true;
          resolve();
        });
      });
      // Terminate with a final message so the EventStream's `result()` promise
      // resolves cleanly (rather than rejecting on a missing final).
      const terminal = fakeAssistantMessage(model);
      terminal.stopReason = "aborted";
      s.push({ type: "done", reason: "stop", message: terminal });
      s.end();
    });
    return s;
  };

  pushInbound({ jsonrpc: "2.0", id: 1, method: "agent.submit", params: { turnId: "T2", prompt: "hi", citedContext: {} } });
  await flush(30);
  pushInbound({ jsonrpc: "2.0", id: 2, method: "agent.cancel", params: { turnId: "T2" } });
  await flush(80);

  // agent.cancel ack: { cancelled: true }
  const cancelResp = captured.responses.find((r) => r.id === 2);
  expect(cancelResp?.result).toEqual({ cancelled: true });
  expect(abortFired).toBe(true);

  // Final notification is ui.status done.
  const last = captured.notifications.at(-1)!;
  expect(last.method).toBe("ui.status");
  expect(last.params.status).toBe("done");

  // No ui.token events emitted after cancel acked. (We only sent one delta
  // before abort, so the count should be 1.)
  const tokens = captured.notifications.filter((n) => n.method === "ui.token");
  expect(tokens).toHaveLength(1);

  // Conversation marks the turn cancelled so the next request's
  // llmMessages() drops it (a half-streamed reply is dead context).
  expect(convo.turns[0].status).toBe("cancelled");
  expect(convo.llmMessages()).toEqual([]);
});

test("error path: stream error event maps to ui.error with picked code", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const convo = new Conversation();
  registerAgentHandlers(dispatcher, { registry: new TurnRegistry(), conversation: convo });

  nextStream = (model) => {
    const s = new AssistantMessageEventStream();
    queueMicrotask(async () => {
      const errMsg = fakeAssistantMessage(model, { errorMessage: "401 unauthorized: token expired" });
      s.push({ type: "error", reason: "error", error: errMsg });
      s.end();
    });
    return s;
  };

  pushInbound({ jsonrpc: "2.0", id: 1, method: "agent.submit", params: { turnId: "T3", prompt: "hi", citedContext: {} } });
  await flush(60);

  const errs = captured.notifications.filter((n) => n.method === "ui.error");
  expect(errs).toHaveLength(1);
  expect(errs[0].params.code).toBe(RPCErrorCode.permissionDenied);
  expect(errs[0].params.message).toContain("401");

  // No ui.status done after error path returns early.
  const statuses = captured.notifications.filter((n) => n.method === "ui.status");
  // Only the initial "thinking" is emitted before the error short-circuit.
  expect(statuses.map((s) => s.params.status)).toEqual(["thinking"]);
});

test("conversation history: prior turn's user+assistant messages are replayed into the next request", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const convo = new Conversation();
  registerAgentHandlers(dispatcher, { registry: new TurnRegistry(), conversation: convo });

  // Capture the messages array the streamSimple wrapper sees on each call so
  // we can prove the second turn carried turn 1's full history.
  const seenMessages: any[][] = [];
  nextStream = (model) => {
    const s = new AssistantMessageEventStream();
    queueMicrotask(async () => {
      const partial = fakeAssistantMessage(model);
      s.push({ type: "text_delta", contentIndex: 0, delta: "first-reply", partial });
      s.push({ type: "done", reason: "stop", message: partial });
      s.end();
    });
    return s;
  };
  // Hook the existing fake provider to record context.messages on each call.
  const original = nextStream;
  nextStream = (model, signal) => {
    // We can't easily reach Context here from the closure; instead intercept
    // via re-registering the api provider. Simpler: read convo.llmMessages()
    // *before* the stream runs, which is exactly what the loop does.
    seenMessages.push(convo.llmMessages().map((m) => ({ role: m.role, content: m.content })));
    return original(model, signal);
  };

  pushInbound({ jsonrpc: "2.0", id: 1, method: "agent.submit", params: { turnId: "T1", prompt: "first", citedContext: {} } });
  await flush(80);

  // Reset stream for turn 2 so it can finish its own done.
  nextStream = (model, signal) => {
    seenMessages.push(convo.llmMessages().map((m) => ({ role: m.role, content: m.content })));
    const s = new AssistantMessageEventStream();
    queueMicrotask(async () => {
      const partial = fakeAssistantMessage(model);
      s.push({ type: "text_delta", contentIndex: 0, delta: "second-reply", partial });
      s.push({ type: "done", reason: "stop", message: partial });
      s.end();
    });
    return s;
  };

  pushInbound({ jsonrpc: "2.0", id: 2, method: "agent.submit", params: { turnId: "T2", prompt: "second", citedContext: {} } });
  await flush(80);

  // Turn 1 saw only its own user message.
  expect(seenMessages[0].map((m) => [m.role, m.content])).toEqual([["user", "first"]]);

  // Turn 2 saw turn 1's (user + assistant) followed by its own user message.
  // This is the "agent has memory across turns" assertion that broke before
  // conversation state moved into the sidecar.
  expect(seenMessages[1]).toHaveLength(3);
  expect(seenMessages[1][0]).toMatchObject({ role: "user", content: "first" });
  expect(seenMessages[1][1].role).toBe("assistant");
  expect(seenMessages[1][2]).toMatchObject({ role: "user", content: "second" });

  expect(captured.notifications.filter((n) => n.method === "conversation.turnStarted")).toHaveLength(2);
});

test("agent.reset wipes conversation, aborts in-flight turn, and emits conversation.reset", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const convo = new Conversation();
  registerAgentHandlers(dispatcher, { registry: new TurnRegistry(), conversation: convo });

  let abortFired = false;
  nextStream = (model, signal) => {
    const s = new AssistantMessageEventStream();
    queueMicrotask(async () => {
      const partial = fakeAssistantMessage(model);
      s.push({ type: "text_delta", contentIndex: 0, delta: "partial", partial });
      await new Promise<void>((resolve) => {
        if (signal?.aborted) return resolve();
        signal?.addEventListener("abort", () => { abortFired = true; resolve(); });
      });
      const terminal = fakeAssistantMessage(model);
      terminal.stopReason = "aborted";
      s.push({ type: "done", reason: "stop", message: terminal });
      s.end();
    });
    return s;
  };

  pushInbound({ jsonrpc: "2.0", id: 1, method: "agent.submit", params: { turnId: "T1", prompt: "hi", citedContext: {} } });
  await flush(30);
  expect(convo.turns).toHaveLength(1);

  pushInbound({ jsonrpc: "2.0", id: 2, method: "agent.reset", params: {} });
  await flush(80);

  const resetResp = captured.responses.find((r) => r.id === 2);
  expect(resetResp?.result).toEqual({ ok: true });
  expect(abortFired).toBe(true);
  expect(convo.turns).toEqual([]);
  expect(captured.notifications.find((n) => n.method === "conversation.reset")).toBeDefined();
});
