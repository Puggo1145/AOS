// Agent loop — ambient injection end-to-end.
//
// Verifies that `runTurn` appends a transient `<ambient>...</ambient>`
// user message at the tail of every outbound LLM request, that the
// message is NOT persisted into the Conversation, and that multi-round
// tool flows see a fresh ambient on every round.
//
// Test rig mirrors `agent-tool-loop.test.ts`: scripted multi-round LLM
// stream, capturing dispatcher, real SessionManager + TodoManager.

import { test, expect, beforeEach, afterEach } from "bun:test";
import { Dispatcher } from "../src/rpc/dispatcher";
import { StdioTransport, type ByteSink, type ByteSource } from "../src/rpc/transport";
import { registerAgentHandlers, setModelResolver, resetModelResolver } from "../src/agent/loop";
import { ContextObserver } from "../src/agent/context-observer";
import { SessionManager } from "../src/agent/session/manager";
import { toolRegistry } from "../src/agent/tools/registry";
import { registerTodoTool } from "../src/agent/tools/todo";
import { ambientRegistry } from "../src/agent/ambient/registry";
import { todosAmbientProvider } from "../src/agent/ambient/providers/todos";
import {
  registerApiProvider,
  unregisterApiProviders,
  type Model,
  type Api,
  type AssistantMessage,
  type ToolCall,
} from "../src/llm";
import { AssistantMessageEventStream } from "../src/llm/utils/event-stream";

const FAKE_SOURCE_ID = "test-ambient-loop";

function makeFakeModel(): Model<Api> {
  return {
    id: "fake-ambient-model",
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

function fakeAssistant(
  model: Model<Api>,
  content: AssistantMessage["content"],
  stop: "stop" | "toolUse",
): AssistantMessage {
  return {
    role: "assistant",
    content,
    api: model.api,
    provider: model.provider,
    model: model.id,
    usage: {
      input: 0,
      output: 0,
      cacheRead: 0,
      cacheWrite: 0,
      totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
    },
    stopReason: stop,
    timestamp: Date.now(),
  };
}

let scriptedRounds: ((model: Model<Api>) => AssistantMessageEventStream)[] = [];
let observedContexts: { messages: any[] }[] = [];

beforeEach(() => {
  registerApiProvider({
    api: "openai-responses",
    sourceId: FAKE_SOURCE_ID,
    stream: (model, ctx) => {
      // Deep-clone the messages snapshot so later mutations to the
      // persisted Conversation don't bleed into earlier observations.
      observedContexts.push({ messages: JSON.parse(JSON.stringify(ctx.messages)) });
      const next = scriptedRounds.shift();
      if (!next) throw new Error("test ran out of scripted rounds");
      return next(model);
    },
  });
  setModelResolver(() => makeFakeModel());
  toolRegistry.clear();
  ambientRegistry.clear();
});

afterEach(() => {
  unregisterApiProviders(FAKE_SOURCE_ID);
  resetModelResolver();
  toolRegistry.clear();
  ambientRegistry.clear();
  scriptedRounds = [];
  observedContexts = [];
});

interface Captured {
  notifications: { method: string; params: any }[];
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
  const captured: Captured = { notifications: [] };
  const sink: ByteSink = {
    write(line: string): boolean {
      const trimmed = line.endsWith("\n") ? line.slice(0, -1) : line;
      const frame = JSON.parse(trimmed);
      if ("method" in frame && !("id" in frame)) {
        captured.notifications.push({ method: frame.method, params: frame.params });
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

async function flush(ms = 80): Promise<void> {
  await new Promise((r) => setTimeout(r, ms));
}

function emitStream(events: (s: AssistantMessageEventStream) => void): AssistantMessageEventStream {
  const s = new AssistantMessageEventStream();
  queueMicrotask(() => {
    events(s);
    s.end();
  });
  return s;
}

function setupSession() {
  const manager = new SessionManager();
  registerTodoTool(manager);
  const session = manager.create();
  return { manager, session, sessionId: session.id };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test("ambient block is appended to outbound messages when the session has open todos", async () => {
  ambientRegistry.register(todosAmbientProvider);
  const { dispatcher, pushInbound } = makeCapturingDispatcher();
  const { manager, session, sessionId } = setupSession();
  registerAgentHandlers(dispatcher, { manager });

  // Seed the plan so the very first round sees ambient injected.
  session.todos.update([{ id: "1", text: "do thing", status: "in_progress" }]);

  scriptedRounds.push((model) => {
    return emitStream((s) => {
      const partial = fakeAssistant(model, [{ type: "text", text: "ok" }], "stop");
      s.push({ type: "text_delta", contentIndex: 0, delta: "ok", partial });
      s.push({ type: "done", reason: "stop", message: partial });
    });
  });

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.submit",
    params: { sessionId, turnId: "T1", prompt: "go", citedContext: {} },
  });
  await flush();

  expect(observedContexts).toHaveLength(1);
  const msgs = observedContexts[0].messages;
  // The trailing message is the ambient transient.
  const last = msgs[msgs.length - 1];
  expect(last.role).toBe("user");
  expect(typeof last.content).toBe("string");
  expect(last.content).toContain("<ambient>");
  expect(last.content).toContain("<todos>");
  expect(last.content).toContain("[>] #1: do thing");
  expect(last.content).toContain("</todos>");
  expect(last.content).toContain("</ambient>");
});

test("no ambient message is appended when no provider has anything to say", async () => {
  // Builtins (todos provider) intentionally not registered here; the
  // session also has no todos. Ambient should collapse to null and
  // `runTurn` should pass the unmodified `messages` to streamSimple.
  const { dispatcher, pushInbound } = makeCapturingDispatcher();
  const { manager, sessionId } = setupSession();
  registerAgentHandlers(dispatcher, { manager });

  scriptedRounds.push((model) => {
    return emitStream((s) => {
      const partial = fakeAssistant(model, [{ type: "text", text: "ok" }], "stop");
      s.push({ type: "text_delta", contentIndex: 0, delta: "ok", partial });
      s.push({ type: "done", reason: "stop", message: partial });
    });
  });

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.submit",
    params: { sessionId, turnId: "T1", prompt: "hi", citedContext: {} },
  });
  await flush();

  const msgs = observedContexts[0].messages;
  // Only the user prompt — no trailing ambient message.
  expect(msgs).toHaveLength(1);
  expect(msgs[0].role).toBe("user");
  const containsAmbient = msgs.some(
    (m: any) => typeof m.content === "string" && m.content.includes("<ambient>"),
  );
  expect(containsAmbient).toBe(false);
});

test("the ambient message does not persist in the Conversation after the turn completes", async () => {
  ambientRegistry.register(todosAmbientProvider);
  const { dispatcher, pushInbound } = makeCapturingDispatcher();
  const { manager, session, sessionId } = setupSession();
  registerAgentHandlers(dispatcher, { manager });

  session.todos.update([{ id: "1", text: "step", status: "in_progress" }]);

  scriptedRounds.push((model) => {
    return emitStream((s) => {
      const partial = fakeAssistant(model, [{ type: "text", text: "done" }], "stop");
      s.push({ type: "text_delta", contentIndex: 0, delta: "done", partial });
      s.push({ type: "done", reason: "stop", message: partial });
    });
  });

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.submit",
    params: { sessionId, turnId: "T1", prompt: "go", citedContext: {} },
  });
  await flush();

  // Durable history holds exactly the user prompt + assistant reply. The
  // ambient transient lived only inside the request envelope.
  const persisted = session.conversation.messages;
  expect(persisted.map((m) => m.role)).toEqual(["user", "assistant"]);
  for (const m of persisted) {
    if (typeof (m as any).content === "string") {
      expect((m as any).content).not.toContain("<ambient>");
    }
  }
  // llmMessages() (what the next turn would send) carries no ambient
  // either — recomputed fresh each round.
  const replay = session.conversation.llmMessages();
  for (const m of replay) {
    if (typeof (m as any).content === "string") {
      expect((m as any).content).not.toContain("<ambient>");
    }
  }
});

test("multi-round tool flow re-injects a fresh ambient on every round", async () => {
  ambientRegistry.register(todosAmbientProvider);
  const { dispatcher, pushInbound } = makeCapturingDispatcher();
  const { manager, sessionId } = setupSession();
  registerAgentHandlers(dispatcher, { manager });

  // Round 1: write the plan via todo_write so the ambient picks it up
  // from round 2 onward.
  scriptedRounds.push((model) => {
    const tc: ToolCall = {
      type: "toolCall",
      id: "tc_init",
      name: "todo_write",
      arguments: {
        items: [{ id: "1", text: "step", status: "in_progress" }],
      },
    };
    return emitStream((s) => {
      const partial = fakeAssistant(model, [tc], "toolUse");
      s.push({ type: "toolcall_end", contentIndex: 0, toolCall: tc, partial });
      s.push({ type: "done", reason: "toolUse", message: partial });
    });
  });

  // A no-op tool the model can call across multiple rounds.
  toolRegistry.register({
    spec: {
      name: "noop",
      description: "Noop",
      parameters: { type: "object", properties: {} },
    },
    execute: async () => ({ content: [{ type: "text", text: "ok" }], isError: false }),
  });

  // Rounds 2 & 3: the model uses noop. Both rounds must see ambient.
  for (let i = 0; i < 2; i++) {
    scriptedRounds.push((model) => {
      const tc: ToolCall = { type: "toolCall", id: `tc_n${i}`, name: "noop", arguments: {} };
      return emitStream((s) => {
        const partial = fakeAssistant(model, [tc], "toolUse");
        s.push({ type: "toolcall_end", contentIndex: 0, toolCall: tc, partial });
        s.push({ type: "done", reason: "toolUse", message: partial });
      });
    });
  }
  // Round 4: terminal text reply. Must also see ambient appended.
  scriptedRounds.push((model) => {
    return emitStream((s) => {
      const partial = fakeAssistant(model, [{ type: "text", text: "done" }], "stop");
      s.push({ type: "text_delta", contentIndex: 0, delta: "done", partial });
      s.push({ type: "done", reason: "stop", message: partial });
    });
  });

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.submit",
    params: { sessionId, turnId: "T1", prompt: "go", citedContext: {} },
  });
  await flush(160);

  expect(observedContexts).toHaveLength(4);

  // Round 0 fired before any todo_write landed — ambient is null because
  // the session's plan was empty. Subsequent rounds (1, 2, 3) see ambient
  // because the plan now has open work and the renderer recomputes per
  // round.
  const tailIs = (idx: number, predicate: (m: any) => boolean) => {
    const msgs = observedContexts[idx].messages;
    return predicate(msgs[msgs.length - 1]);
  };
  const isAmbient = (m: any) =>
    m?.role === "user" && typeof m.content === "string" && m.content.includes("<ambient>");

  expect(tailIs(0, isAmbient)).toBe(false);
  expect(tailIs(1, isAmbient)).toBe(true);
  expect(tailIs(2, isAmbient)).toBe(true);
  expect(tailIs(3, isAmbient)).toBe(true);
});

test("dev-mode context snapshot includes the ambient tail so it can be inspected", async () => {
  ambientRegistry.register(todosAmbientProvider);
  const observer = new ContextObserver();
  const { dispatcher, pushInbound } = makeCapturingDispatcher();
  const { manager, session, sessionId } = setupSession();
  registerAgentHandlers(dispatcher, { manager, contextObserver: observer });

  session.todos.update([{ id: "1", text: "debug me", status: "in_progress" }]);

  scriptedRounds.push((model) => {
    return emitStream((s) => {
      const partial = fakeAssistant(model, [{ type: "text", text: "ok" }], "stop");
      s.push({ type: "text_delta", contentIndex: 0, delta: "ok", partial });
      s.push({ type: "done", reason: "stop", message: partial });
    });
  });

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.submit",
    params: { sessionId, turnId: "T1", prompt: "go", citedContext: {} },
  });
  await flush();

  // The snapshot the Dev Mode window will see must contain ambient — the
  // whole point of this hook is debuggability of what the model actually
  // received, not what's persisted.
  const snap = observer.latest();
  expect(snap).not.toBeNull();
  expect(snap!.messagesJson).toContain("<ambient>");
  expect(snap!.messagesJson).toContain("<todos>");
  expect(snap!.messagesJson).toContain("[>] #1: debug me");
});
