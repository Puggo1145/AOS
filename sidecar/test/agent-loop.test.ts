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
import { ContextObserver, type DevContextSnapshot } from "../src/agent/context-observer";
import { Conversation } from "../src/agent/conversation";
import { SessionManager } from "../src/agent/session/manager";
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

/// Build a fresh SessionManager + bootstrap session and return the bits each
/// test needs. Replaces the Stage-0 "construct Conversation+TurnRegistry by
/// hand" pattern: per docs/designs/session-management.md the loop now reads
/// per-session state from the manager, so tests must allocate one too.
function setupSession() {
  const manager = new SessionManager();
  const session = manager.create();
  return { manager, sessionId: session.id, convo: session.conversation };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test("happy path: ack + turnStarted + thinking + tokens + done", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, convo, sessionId } = setupSession();
  registerAgentHandlers(dispatcher, { manager });

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
    params: { sessionId, turnId: "T1", prompt: "hi", citedContext: {} },
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
  expect(captured.notifications[1].params).toEqual({ sessionId, turnId: "T1", status: "thinking" });

  const tokens = captured.notifications.filter((n) => n.method === "ui.token");
  expect(tokens.map((t) => t.params.delta).join("")).toBe("Hello, world");

  const last = captured.notifications.at(-1)!;
  expect(last).toEqual({ method: "ui.status", params: { sessionId, turnId: "T1", status: "done" } });

  // Conversation now holds the completed turn with both the streamed reply
  // and the assistant AssistantMessage in the flat history (range covers it).
  expect(convo.turns).toHaveLength(1);
  expect(convo.turns[0].status).toBe("done");
  expect(convo.turns[0].reply).toBe("Hello, world");
  // Flat-history layout (post tool-use refactor): one user, one assistant.
  expect(convo.messages).toHaveLength(2);
  expect(convo.messages[1].role).toBe("assistant");
});

test("thinking lifecycle: thinking_delta and thinking_end are forwarded as ui.thinking before ui.token", async () => {
  // Reasoning-trace deltas must reach the Shell on the dedicated `ui.thinking`
  // channel with `kind: "delta"`, the explicit `thinking_end` event must be
  // forwarded as `kind: "end"`, and both must precede the first `ui.token`
  // so the Shell's reasoning affordance closes before the reply renders.
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, convo, sessionId } = setupSession();
  registerAgentHandlers(dispatcher, { manager });

  nextStream = (model) => {
    const s = new AssistantMessageEventStream();
    queueMicrotask(async () => {
      const partial = fakeAssistantMessage(model);
      s.push({ type: "thinking_delta", contentIndex: 0, delta: "Considering ", partial });
      s.push({ type: "thinking_delta", contentIndex: 0, delta: "the request…", partial });
      s.push({ type: "thinking_end", contentIndex: 0, content: "Considering the request…", partial });
      s.push({ type: "text_delta", contentIndex: 1, delta: "Answer", partial });
      s.push({ type: "done", reason: "stop", message: partial });
      s.end();
    });
    return s;
  };

  pushInbound({ jsonrpc: "2.0", id: 1, method: "agent.submit", params: { sessionId, turnId: "TT", prompt: "hi", citedContext: {} } });
  await flush(80);

  const thinking = captured.notifications.filter((n) => n.method === "ui.thinking");
  expect(thinking).toHaveLength(3);
  expect(thinking[0].params).toEqual({ sessionId, turnId: "TT", kind: "delta", delta: "Considering " });
  expect(thinking[1].params).toEqual({ sessionId, turnId: "TT", kind: "delta", delta: "the request…" });
  expect(thinking[2].params).toEqual({ sessionId, turnId: "TT", kind: "end" });

  // Ordering invariant: every ui.thinking precedes every ui.token.
  const lastThinkingIdx = captured.notifications
    .map((n, i) => ({ n, i }))
    .filter(({ n }) => n.method === "ui.thinking")
    .at(-1)!.i;
  const firstTokenIdx = captured.notifications.findIndex((n) => n.method === "ui.token");
  expect(firstTokenIdx).toBeGreaterThan(lastThinkingIdx);
});

test("thinking lifecycle: error mid-thinking synthesizes a {kind:end} before ui.error", async () => {
  // Provider can bail out of reasoning without ever emitting `thinking_end`.
  // The Shell no longer infers the close from `ui.error`, so the sidecar
  // must synthesize the end itself or the shimmer keeps animating.
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, convo, sessionId } = setupSession();
  registerAgentHandlers(dispatcher, { manager });

  nextStream = (model) => {
    const s = new AssistantMessageEventStream();
    queueMicrotask(async () => {
      const partial = fakeAssistantMessage(model);
      s.push({ type: "thinking_delta", contentIndex: 0, delta: "considering…", partial });
      const errMsg = fakeAssistantMessage(model, { errorMessage: "boom" });
      s.push({ type: "error", reason: "error", error: errMsg });
      s.end();
    });
    return s;
  };

  pushInbound({ jsonrpc: "2.0", id: 1, method: "agent.submit", params: { sessionId, turnId: "TE1", prompt: "hi", citedContext: {} } });
  await flush(80);

  const events = captured.notifications.map((n) => ({ method: n.method, params: n.params }));
  // Expected order: ...thinking_delta, then synthesized thinking end, then ui.error.
  const lastThinkingIdx = events
    .map((e, i) => ({ e, i }))
    .filter(({ e }) => e.method === "ui.thinking")
    .at(-1)!.i;
  expect(events[lastThinkingIdx].params).toEqual({ sessionId, turnId: "TE1", kind: "end" });
  const errorIdx = events.findIndex((e) => e.method === "ui.error");
  expect(errorIdx).toBeGreaterThan(lastThinkingIdx);
});

test("thinking lifecycle: cancel mid-thinking synthesizes a {kind:end} before ui.status done", async () => {
  // Cancel path: the loop breaks on `signal.aborted` and emits `ui.status
  // done` from the natural-completion tail. The thinking block must close
  // before that done so the Shell's per-turn timer freezes correctly.
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, convo, sessionId } = setupSession();
  registerAgentHandlers(dispatcher, { manager });

  nextStream = (model, signal) => {
    const s = new AssistantMessageEventStream();
    queueMicrotask(async () => {
      const partial = fakeAssistantMessage(model);
      s.push({ type: "thinking_delta", contentIndex: 0, delta: "considering…", partial });
      await new Promise<void>((resolve) => {
        if (signal?.aborted) return resolve();
        signal?.addEventListener("abort", () => resolve());
      });
      const terminal = fakeAssistantMessage(model);
      terminal.stopReason = "aborted";
      s.push({ type: "done", reason: "stop", message: terminal });
      s.end();
    });
    return s;
  };

  pushInbound({ jsonrpc: "2.0", id: 1, method: "agent.submit", params: { sessionId, turnId: "TC1", prompt: "hi", citedContext: {} } });
  await flush(30);
  pushInbound({ jsonrpc: "2.0", id: 2, method: "agent.cancel", params: { sessionId, turnId: "TC1" } });
  await flush(80);

  const thinking = captured.notifications.filter((n) => n.method === "ui.thinking");
  // delta + synthesized end
  expect(thinking).toHaveLength(2);
  expect(thinking[0].params).toMatchObject({ kind: "delta" });
  expect(thinking[1].params).toEqual({ sessionId, turnId: "TC1", kind: "end" });

  const lastThinkingIdx = captured.notifications
    .map((n, i) => ({ n, i }))
    .filter(({ n }) => n.method === "ui.thinking")
    .at(-1)!.i;
  const doneIdx = captured.notifications.findIndex(
    (n) => n.method === "ui.status" && n.params.status === "done",
  );
  expect(doneIdx).toBeGreaterThan(lastThinkingIdx);
});

test("thinking lifecycle: end is not duplicated when provider already sent thinking_end", async () => {
  // Sanity: the synthesized end must not double-fire on the happy path
  // where the provider closes the block itself.
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, convo, sessionId } = setupSession();
  registerAgentHandlers(dispatcher, { manager });

  nextStream = (model) => {
    const s = new AssistantMessageEventStream();
    queueMicrotask(async () => {
      const partial = fakeAssistantMessage(model);
      s.push({ type: "thinking_delta", contentIndex: 0, delta: "x", partial });
      s.push({ type: "thinking_end", contentIndex: 0, content: "x", partial });
      s.push({ type: "text_delta", contentIndex: 1, delta: "y", partial });
      s.push({ type: "done", reason: "stop", message: partial });
      s.end();
    });
    return s;
  };

  pushInbound({ jsonrpc: "2.0", id: 1, method: "agent.submit", params: { sessionId, turnId: "TD1", prompt: "hi", citedContext: {} } });
  await flush(80);

  const ends = captured.notifications.filter(
    (n) => n.method === "ui.thinking" && n.params.kind === "end",
  );
  expect(ends).toHaveLength(1);
});

test("cancel path: agent.cancel aborts the stream and emits status done", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, convo, sessionId } = setupSession();
  registerAgentHandlers(dispatcher, { manager });

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

  pushInbound({ jsonrpc: "2.0", id: 1, method: "agent.submit", params: { sessionId, turnId: "T2", prompt: "hi", citedContext: {} } });
  await flush(30);
  pushInbound({ jsonrpc: "2.0", id: 2, method: "agent.cancel", params: { sessionId, turnId: "T2" } });
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

test("error path: typed authInvalidated reason maps to permissionDenied", async () => {
  // Per P3.8: pickErrorCode trusts only the typed `errorReason` field. The
  // provider MUST tag auth failures with `errorReason: "authInvalidated"`;
  // a free-text "401" in `errorMessage` no longer takes a special path.
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, convo, sessionId } = setupSession();
  registerAgentHandlers(dispatcher, { manager });

  nextStream = (model) => {
    const s = new AssistantMessageEventStream();
    queueMicrotask(async () => {
      const errMsg = fakeAssistantMessage(model, { errorMessage: "token expired" });
      errMsg.errorReason = "authInvalidated";
      errMsg.errorProviderId = "chatgpt-plan";
      s.push({ type: "error", reason: "error", error: errMsg });
      s.end();
    });
    return s;
  };

  pushInbound({ jsonrpc: "2.0", id: 1, method: "agent.submit", params: { sessionId, turnId: "T3", prompt: "hi", citedContext: {} } });
  await flush(60);

  const errs = captured.notifications.filter((n) => n.method === "ui.error");
  expect(errs).toHaveLength(1);
  expect(errs[0].params.code).toBe(RPCErrorCode.permissionDenied);

  // The agent loop also projects the typed reason to provider.statusChanged
  // so the Shell's onboard panel can flip to unauthenticated.
  const statusChanges = captured.notifications.filter((n) => n.method === "provider.statusChanged");
  expect(statusChanges).toHaveLength(1);
  expect(statusChanges[0].params).toMatchObject({
    providerId: "chatgpt-plan",
    state: "unauthenticated",
    reason: "authInvalidated",
  });

  // Only the initial "thinking" is emitted before the error short-circuit.
  const statuses = captured.notifications.filter((n) => n.method === "ui.status");
  expect(statuses.map((s) => s.params.status)).toEqual(["thinking"]);
});

test("error path: untyped errors fall through to internalError", async () => {
  // No regex tail anymore: a stream error without `errorReason` is plain
  // internalError. Providers that wrap auth must tag the typed reason.
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, convo, sessionId } = setupSession();
  registerAgentHandlers(dispatcher, { manager });

  nextStream = (model) => {
    const s = new AssistantMessageEventStream();
    queueMicrotask(async () => {
      const errMsg = fakeAssistantMessage(model, { errorMessage: "ECONNREFUSED 8443" });
      s.push({ type: "error", reason: "error", error: errMsg });
      s.end();
    });
    return s;
  };

  pushInbound({ jsonrpc: "2.0", id: 1, method: "agent.submit", params: { sessionId, turnId: "T4", prompt: "hi", citedContext: {} } });
  await flush(60);

  const errs = captured.notifications.filter((n) => n.method === "ui.error");
  expect(errs).toHaveLength(1);
  expect(errs[0].params.code).toBe(RPCErrorCode.internalError);
  expect(captured.notifications.find((n) => n.method === "provider.statusChanged")).toBeUndefined();
});

test("conversation history: prior turn's user+assistant messages are replayed into the next request", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, convo, sessionId } = setupSession();
  registerAgentHandlers(dispatcher, { manager });

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

  pushInbound({ jsonrpc: "2.0", id: 1, method: "agent.submit", params: { sessionId, turnId: "T1", prompt: "first", citedContext: {} } });
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

  pushInbound({ jsonrpc: "2.0", id: 2, method: "agent.submit", params: { sessionId, turnId: "T2", prompt: "second", citedContext: {} } });
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

test("dev context observer: terminal publish includes the assistant reply", async () => {
  // Regression guard for the second `observer.publish(...)` after
  // `convo.markDone(...)`. Without it, Dev Mode would only ever see the
  // pre-call input snapshot (user message only) and miss the assistant turn.
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const observer = new ContextObserver();

  const { manager, convo, sessionId } = setupSession();
  registerAgentHandlers(dispatcher, { manager, contextObserver: observer });
  // `registerAgentHandlers` installs its own sink that forwards to the
  // dispatcher; read the published snapshots back from `dev.context.changed`
  // notifications rather than overriding that sink.
  const snapshots = (): DevContextSnapshot[] =>
    captured.notifications
      .filter((n) => n.method === "dev.context.changed")
      .map((n) => n.params.snapshot as DevContextSnapshot);

  nextStream = (model) => {
    const s = new AssistantMessageEventStream();
    queueMicrotask(async () => {
      const partial = fakeAssistantMessage(model);
      s.push({ type: "text_delta", contentIndex: 0, delta: "the-reply", partial });
      // The terminal AssistantMessage carries the content the loop will
      // store via `convo.markDone(...)`. Dev Mode must reflect this in the
      // post-completion snapshot.
      const terminal = fakeAssistantMessage(model);
      terminal.content = [{ type: "text", text: "the-reply" }];
      s.push({ type: "done", reason: "stop", message: terminal });
      s.end();
    });
    return s;
  };

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.submit",
    params: { sessionId, turnId: "T1", prompt: "ping", citedContext: {} },
  });
  await flush(80);

  // Two snapshots: pre-call (user only) and post-markDone (user + assistant).
  const snaps = snapshots();
  expect(snaps).toHaveLength(2);

  const pre = JSON.parse(snaps[0].messagesJson);
  expect(pre).toHaveLength(1);
  expect(pre[0]).toMatchObject({ role: "user", content: "ping" });

  const post = JSON.parse(snaps[1].messagesJson);
  expect(post).toHaveLength(2);
  expect(post[0]).toMatchObject({ role: "user", content: "ping" });
  expect(post[1].role).toBe("assistant");
  expect(post[1].content).toEqual([{ type: "text", text: "the-reply" }]);
});

test("agent.reset wipes conversation, aborts in-flight turn, and emits conversation.reset", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, convo, sessionId } = setupSession();
  registerAgentHandlers(dispatcher, { manager });

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

  pushInbound({ jsonrpc: "2.0", id: 1, method: "agent.submit", params: { sessionId, turnId: "T1", prompt: "hi", citedContext: {} } });
  await flush(30);
  expect(convo.turns).toHaveLength(1);

  pushInbound({ jsonrpc: "2.0", id: 2, method: "agent.reset", params: { sessionId } });
  await flush(80);

  const resetResp = captured.responses.find((r) => r.id === 2);
  expect(resetResp?.result).toEqual({ ok: true });
  expect(abortFired).toBe(true);
  expect(convo.turns).toEqual([]);
  expect(captured.notifications.find((n) => n.method === "conversation.reset")).toBeDefined();
});

test("multi-session: notifications carry the correct sessionId; reset of A does not affect B", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const manager = new SessionManager();
  const a = manager.create();
  const b = manager.create();
  registerAgentHandlers(dispatcher, { manager });

  // Both sessions get a finite-but-async stream so submit ack doesn't race.
  nextStream = (model) => {
    const s = new AssistantMessageEventStream();
    queueMicrotask(async () => {
      const partial = fakeAssistantMessage(model);
      s.push({ type: "text_delta", contentIndex: 0, delta: "x", partial });
      s.push({ type: "done", reason: "stop", message: partial });
      s.end();
    });
    return s;
  };

  pushInbound({ jsonrpc: "2.0", id: 1, method: "agent.submit", params: { sessionId: a.id, turnId: "TA", prompt: "from-a", citedContext: {} } });
  pushInbound({ jsonrpc: "2.0", id: 2, method: "agent.submit", params: { sessionId: b.id, turnId: "TB", prompt: "from-b", citedContext: {} } });
  await flush(120);

  // Every ui.* / conversation.* notification routed by sessionId.
  const aTokens = captured.notifications.filter((n) => n.params?.sessionId === a.id && n.method === "ui.token");
  const bTokens = captured.notifications.filter((n) => n.params?.sessionId === b.id && n.method === "ui.token");
  expect(aTokens.map((n) => n.params.turnId)).toEqual(["TA"]);
  expect(bTokens.map((n) => n.params.turnId)).toEqual(["TB"]);
  // Sessions don't share turnIds in their notifications.
  expect(aTokens.find((n) => n.params.turnId === "TB")).toBeUndefined();
  expect(bTokens.find((n) => n.params.turnId === "TA")).toBeUndefined();

  // Reset A, B's conversation untouched.
  pushInbound({ jsonrpc: "2.0", id: 3, method: "agent.reset", params: { sessionId: a.id } });
  await flush(40);
  expect(a.conversation.turns).toEqual([]);
  expect(b.conversation.turns).toHaveLength(1);
  expect(b.conversation.turns[0].id).toBe("TB");

  // Reset notification carried A's sessionId.
  const resetEvents = captured.notifications.filter((n) => n.method === "conversation.reset");
  expect(resetEvents.map((n) => n.params.sessionId)).toContain(a.id);
  expect(resetEvents.find((n) => n.params.sessionId === b.id)).toBeUndefined();
});

test("agent.submit rejects a second concurrent turn on the same session", async () => {
  // The Conversation store relies on contiguous [messageStart, messageEnd)
  // ranges; interleaving two turns on the same session would let one absorb
  // the other's user message. Sidecar enforces "one active turn per session"
  // independently of the Shell's serialization.
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, sessionId } = setupSession();
  registerAgentHandlers(dispatcher, { manager });

  // A long-hanging stream so T1 is still active when T2 lands.
  let resolveStream: () => void = () => {};
  nextStream = (model) => {
    const s = new AssistantMessageEventStream();
    queueMicrotask(() => {
      // Hold open until the test resolves it.
      resolveStream = () => {
        const partial = fakeAssistantMessage(model);
        s.push({ type: "text_delta", contentIndex: 0, delta: "ok", partial });
        s.push({ type: "done", reason: "stop", message: partial });
        s.end();
      };
    });
    return s;
  };

  pushInbound({ jsonrpc: "2.0", id: 1, method: "agent.submit", params: { sessionId, turnId: "T1", prompt: "first", citedContext: {} } });
  await flush(40);

  pushInbound({ jsonrpc: "2.0", id: 2, method: "agent.submit", params: { sessionId, turnId: "T2", prompt: "second", citedContext: {} } });
  await flush(40);

  const r1 = captured.responses.find((r) => r.id === 1);
  expect(r1?.result).toEqual({ accepted: true });
  const r2 = captured.responses.find((r) => r.id === 2);
  expect(r2?.error?.code).toBe(RPCErrorCode.invalidRequest);
  expect(r2?.error?.message).toMatch(/in-flight turn/);

  // Let T1 finish so the test cleanly winds down.
  resolveStream();
  await flush(40);
});

test("agent.submit / cancel / reset return unknownSession for an unknown sessionId", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const manager = new SessionManager();
  manager.create(); // an active session exists, but the request will pass a bogus id.
  registerAgentHandlers(dispatcher, { manager });

  pushInbound({ jsonrpc: "2.0", id: 1, method: "agent.submit", params: { sessionId: "sess_nope", turnId: "T1", prompt: "x", citedContext: {} } });
  pushInbound({ jsonrpc: "2.0", id: 2, method: "agent.cancel", params: { sessionId: "sess_nope", turnId: "T1" } });
  pushInbound({ jsonrpc: "2.0", id: 3, method: "agent.reset", params: { sessionId: "sess_nope" } });
  await flush(40);

  for (const id of [1, 2, 3]) {
    const resp = captured.responses.find((r) => r.id === id);
    expect(resp?.error?.code).toBe(RPCErrorCode.unknownSession);
  }
});
