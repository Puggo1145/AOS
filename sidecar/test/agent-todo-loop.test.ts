// Agent loop — s03 TodoWrite integration.
//
// Pins the wire-level effects of the `todo_write` tool round:
//   - A successful `todo_write` call emits `ui.todo` with the new plan.
//   - The handler returns the rendered list as text content (visible to the
//     model).
//   - `agent.reset` clears the per-session plan and emits an empty `ui.todo`.
//
// The per-round todo surfacing now lives in the ambient subsystem
// (`agent-ambient-loop.test.ts`); the legacy `<reminder>` nag mechanism is
// removed.
//
// Test rig mirrors `agent-tool-loop.test.ts`: scripted multi-round LLM
// stream, capturing dispatcher, real SessionManager + TodoManager.

import { test, expect, beforeEach, afterEach } from "bun:test";
import { Dispatcher } from "../src/rpc/dispatcher";
import { StdioTransport, type ByteSink, type ByteSource } from "../src/rpc/transport";
import { registerAgentHandlers, setModelResolver, resetModelResolver } from "../src/agent/loop";
import { SessionManager } from "../src/agent/session/manager";
import { toolRegistry } from "../src/agent/tools/registry";
import { registerTodoTool } from "../src/agent/tools/todo";
import { ambientRegistry } from "../src/agent/ambient/registry";
import {
  registerApiProvider,
  unregisterApiProviders,
  type Model,
  type Api,
  type AssistantMessage,
  type ToolCall,
} from "../src/llm";
import { AssistantMessageEventStream } from "../src/llm/utils/event-stream";

const FAKE_SOURCE_ID = "test-todo-loop";

function makeFakeModel(): Model<Api> {
  return {
    id: "fake-todo-model",
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

function fakeAssistant(model: Model<Api>, content: AssistantMessage["content"], stop: "stop" | "toolUse"): AssistantMessage {
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
      observedContexts.push({ messages: ctx.messages });
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

test("todo_write tool round emits ui.todo with the new plan and stores it on the session", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, session, sessionId } = setupSession();
  registerAgentHandlers(dispatcher, { manager });

  const items = [
    { id: "1", text: "draft section", status: "in_progress" },
    { id: "2", text: "review", status: "pending" },
  ];

  // Round 1: assistant calls todo_write.
  scriptedRounds.push((model) => {
    const tc: ToolCall = {
      type: "toolCall",
      id: "tc_todo",
      name: "todo_write",
      arguments: { items },
    };
    return emitStream((s) => {
      const partial = fakeAssistant(model, [tc], "toolUse");
      s.push({ type: "toolcall_end", contentIndex: 0, toolCall: tc, partial });
      s.push({ type: "done", reason: "toolUse", message: partial });
    });
  });
  // Round 2: terminal text reply to close the turn.
  scriptedRounds.push((model) => {
    return emitStream((s) => {
      const partial = fakeAssistant(model, [{ type: "text", text: "planned" }], "stop");
      s.push({ type: "text_delta", contentIndex: 0, delta: "planned", partial });
      s.push({ type: "done", reason: "stop", message: partial });
    });
  });

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.submit",
    params: { sessionId, turnId: "T1", prompt: "plan it", citedContext: {} },
  });

  await flush();

  // Session-level state captures the new plan.
  expect(session.todos.items).toHaveLength(2);
  expect(session.todos.items[0]).toMatchObject({ id: "1", status: "in_progress" });
  expect(session.todos.items[1]).toMatchObject({ id: "2", status: "pending" });

  // ui.todo notification carries the same shape as the manager.
  const todoNotifs = captured.notifications.filter((n) => n.method === "ui.todo");
  expect(todoNotifs).toHaveLength(1);
  expect(todoNotifs[0].params.sessionId).toBe(sessionId);
  expect(todoNotifs[0].params.items).toHaveLength(2);
  expect(todoNotifs[0].params.items[0]).toMatchObject({
    id: "1",
    text: "draft section",
    status: "in_progress",
  });

  // The tool result content surfaces the rendered list to the model so it
  // can verify its update landed.
  const toolResult = captured.notifications.find(
    (n) => n.method === "ui.toolCall" && n.params.phase === "result",
  );
  expect(toolResult?.params.outputText).toContain("[>] #1: draft section");
  expect(toolResult?.params.outputText).toContain("[ ] #2: review");
});

test("invalid todo_write args (multiple in_progress) surface as a recoverable isError result", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, session, sessionId } = setupSession();
  registerAgentHandlers(dispatcher, { manager });

  scriptedRounds.push((model) => {
    const tc: ToolCall = {
      type: "toolCall",
      id: "tc_bad",
      name: "todo_write",
      arguments: {
        items: [
          { id: "1", text: "a", status: "in_progress" },
          { id: "2", text: "b", status: "in_progress" },
        ],
      },
    };
    return emitStream((s) => {
      const partial = fakeAssistant(model, [tc], "toolUse");
      s.push({ type: "toolcall_end", contentIndex: 0, toolCall: tc, partial });
      s.push({ type: "done", reason: "toolUse", message: partial });
    });
  });
  scriptedRounds.push((model) => {
    return emitStream((s) => {
      const partial = fakeAssistant(model, [{ type: "text", text: "noted" }], "stop");
      s.push({ type: "text_delta", contentIndex: 0, delta: "noted", partial });
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

  // ToolUserError lands as `result` with isError=true (not `rejected` —
  // schema validated, the manager enforced semantic validity).
  const toolResults = captured.notifications.filter(
    (n) => n.method === "ui.toolCall" && n.params.phase === "result",
  );
  expect(toolResults).toHaveLength(1);
  expect(toolResults[0].params.isError).toBe(true);
  expect(toolResults[0].params.outputText).toMatch(/Only one task can be in_progress/);

  // The manager rejected the write — list is still empty.
  expect(session.todos.items).toHaveLength(0);

  // No ui.todo notification fires for a rejected write — the wire reflects
  // the manager's "nothing landed" state rather than emitting an empty
  // snapshot that would clobber any prior plan.
  const todoNotifs = captured.notifications.filter((n) => n.method === "ui.todo");
  expect(todoNotifs).toHaveLength(0);
});

test("agent.reset clears the per-session plan and emits an empty ui.todo", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, session, sessionId } = setupSession();
  registerAgentHandlers(dispatcher, { manager });

  // Seed the plan directly so we can isolate the reset behavior — no need
  // to run a turn first.
  session.todos.update([
    { id: "1", text: "a", status: "in_progress" },
    { id: "2", text: "b", status: "pending" },
  ]);
  expect(session.todos.items).toHaveLength(2);

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.reset",
    params: { sessionId },
  });
  await flush(60);

  expect(session.todos.items).toHaveLength(0);

  const todoNotifs = captured.notifications.filter((n) => n.method === "ui.todo");
  expect(todoNotifs).toHaveLength(1);
  expect(todoNotifs[0].params).toEqual({ sessionId, items: [] });
});
