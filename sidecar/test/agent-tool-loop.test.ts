// Agent loop — tool sub-loop integration.
//
// Verifies the s02 contract on top of the existing single-turn machinery:
//   - The model's tool calls reach the registered handler with validated args.
//   - ToolResultMessages land in the flat conversation history in order.
//   - `ui.toolCall { phase: "called" }` fires on toolcall_end, `phase:
//     "result"` fires after handler completion, with isError + outputText.
//   - `ui.status` cycles working → waiting → working → done across
//     rounds.
//   - The loop re-issues `streamSimple` with the appended tool results so a
//     second-round text-only response terminates the turn.
//   - Unknown tools / handler exceptions surface as isError tool results
//     instead of killing the turn.

import { test, expect, beforeEach, afterEach } from "bun:test";
import { Dispatcher } from "../src/rpc/dispatcher";
import { StdioTransport, type ByteSink, type ByteSource } from "../src/rpc/transport";
import { registerAgentHandlers, setModelResolver, resetModelResolver } from "../src/agent/loop";
import { SessionManager } from "../src/agent/session/manager";
import { toolRegistry } from "../src/agent/tools/registry";
import { ToolUserError } from "../src/agent/tools";
import {
  registerApiProvider,
  unregisterApiProviders,
  type Model,
  type Api,
  type AssistantMessage,
  type ToolCall,
} from "../src/llm";
import { AssistantMessageEventStream } from "../src/llm/utils/event-stream";

const FAKE_SOURCE_ID = "test-tool-loop";

function makeFakeModel(): Model<Api> {
  return {
    id: "fake-tool-model",
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
    usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
    stopReason: stop,
    timestamp: Date.now(),
  };
}

// Each call to the fake provider consumes the head of this queue. Lets a
// test script a multi-round dialog: round 1 tool call, round 2 final reply.
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
});

afterEach(() => {
  unregisterApiProviders(FAKE_SOURCE_ID);
  resetModelResolver();
  toolRegistry.clear();
  scriptedRounds = [];
  observedContexts = [];
});

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

async function flush(ms = 80): Promise<void> {
  await new Promise((r) => setTimeout(r, ms));
}

function setupSession() {
  const manager = new SessionManager();
  const session = manager.create();
  return { manager, sessionId: session.id, convo: session.conversation };
}

function emitStream(events: (s: AssistantMessageEventStream) => void): AssistantMessageEventStream {
  const s = new AssistantMessageEventStream();
  queueMicrotask(() => {
    events(s);
    s.end();
  });
  return s;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test("two-round tool-use: assistant calls a tool, then produces a final reply", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, convo, sessionId } = setupSession();
  registerAgentHandlers(dispatcher, { manager });

  // Echo tool: returns its `text` argument verbatim.
  let receivedArgs: unknown = null;
  toolRegistry.register({
    spec: {
      name: "echo",
      description: "Echo a string",
      parameters: {
        type: "object",
        properties: { text: { type: "string" } },
        required: ["text"],
      },
    },
    execute: async (args) => {
      receivedArgs = args;
      return { content: [{ type: "text", text: `echoed: ${(args as any).text}` }], isError: false };
    },
  });

  // Round 1: assistant emits a single toolCall, stopReason "toolUse".
  scriptedRounds.push((model) => {
    const tc: ToolCall = { type: "toolCall", id: "tc_1", name: "echo", arguments: { text: "hi" } };
    return emitStream((s) => {
      const partial = fakeAssistant(model, [tc], "toolUse");
      s.push({ type: "toolcall_end", contentIndex: 0, toolCall: tc, partial });
      s.push({ type: "done", reason: "toolUse", message: partial });
    });
  });
  // Round 2: assistant produces a text reply, stopReason "stop". This
  // terminates the loop.
  scriptedRounds.push((model) => {
    return emitStream((s) => {
      const partial = fakeAssistant(model, [{ type: "text", text: "all done" }], "stop");
      s.push({ type: "text_delta", contentIndex: 0, delta: "all done", partial });
      s.push({ type: "done", reason: "stop", message: partial });
    });
  });

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.submit",
    params: { sessionId, turnId: "T1", prompt: "say hi via echo", citedContext: {} },
  });

  await flush();

  // Tool received the validated args (not the raw ToolCall).
  expect(receivedArgs).toEqual({ text: "hi" });

  // ui.toolCall lifecycle: called → result.
  const toolNotifs = captured.notifications.filter((n) => n.method === "ui.toolCall");
  expect(toolNotifs).toHaveLength(2);
  expect(toolNotifs[0].params).toMatchObject({
    phase: "called",
    toolCallId: "tc_1",
    toolName: "echo",
    args: { text: "hi" },
  });
  expect(toolNotifs[1].params).toMatchObject({
    phase: "result",
    toolCallId: "tc_1",
    toolName: "echo",
    isError: false,
    outputText: "echoed: hi",
  });

  // ui.status cycle: working (initial) → waiting (tool round) →
  // working (round 2) → done (terminal). Filter for the unique sequence.
  const statuses = captured.notifications
    .filter((n) => n.method === "ui.status")
    .map((n) => n.params.status);
  expect(statuses).toEqual(["working", "waiting", "working", "done"]);

  // Conversation flat history: user → assistant(toolCall) → toolResult →
  // assistant(text). The tool result must reference the originating call.
  expect(convo.messages.map((m) => m.role)).toEqual(["user", "assistant", "toolResult", "assistant"]);
  expect((convo.messages[2] as any).toolCallId).toBe("tc_1");
  expect((convo.messages[2] as any).isError).toBe(false);

  // Round 2 must have seen all three prior messages (replay carries tool
  // call + result back to the model).
  expect(observedContexts).toHaveLength(2);
  expect(observedContexts[1].messages.map((m: any) => m.role)).toEqual(["user", "assistant", "toolResult"]);

  expect(convo.turns[0].status).toBe("done");
  expect(convo.turns[0].reply).toBe("all done");
});

test("unknown tool surfaces as isError result, loop continues to terminal reply", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, convo, sessionId } = setupSession();
  registerAgentHandlers(dispatcher, { manager });

  // Registry left empty — no tools at all.
  scriptedRounds.push((model) => {
    const tc: ToolCall = { type: "toolCall", id: "tc_x", name: "missing_tool", arguments: {} };
    return emitStream((s) => {
      const partial = fakeAssistant(model, [tc], "toolUse");
      s.push({ type: "toolcall_end", contentIndex: 0, toolCall: tc, partial });
      s.push({ type: "done", reason: "toolUse", message: partial });
    });
  });
  scriptedRounds.push((model) => {
    return emitStream((s) => {
      const partial = fakeAssistant(model, [{ type: "text", text: "giving up" }], "stop");
      s.push({ type: "text_delta", contentIndex: 0, delta: "giving up", partial });
      s.push({ type: "done", reason: "stop", message: partial });
    });
  });

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.submit",
    params: { sessionId, turnId: "T1", prompt: "do the thing", citedContext: {} },
  });

  await flush();

  // Unknown tool surfaces on the wire as `rejected` (handler never ran), not
  // `result`. The model still gets the failure as a tool result message in
  // its conversation history so it can self-correct.
  const rejected = captured.notifications.filter(
    (n) => n.method === "ui.toolCall" && n.params.phase === "rejected",
  );
  expect(rejected).toHaveLength(1);
  expect(rejected[0].params.errorMessage).toContain("Unknown tool");
  const toolResults = captured.notifications.filter(
    (n) => n.method === "ui.toolCall" && n.params.phase === "result",
  );
  expect(toolResults).toHaveLength(0);

  // Turn still completes (terminal reply observed).
  expect(convo.turns[0].status).toBe("done");
  expect(convo.turns[0].reply).toBe("giving up");
});

test("handler ToolUserError surfaces as isError result without aborting the turn", async () => {
  // ToolUserError is the documented "model can fix this" signal — laundered
  // into a recoverable tool result. Distinct from a plain throw, which is a
  // harness fault and terminates the turn (see next test).
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, convo, sessionId } = setupSession();
  registerAgentHandlers(dispatcher, { manager });

  toolRegistry.register({
    spec: {
      name: "soft_fail",
      description: "Throws ToolUserError",
      parameters: { type: "object", properties: {} },
    },
    execute: async () => {
      throw new ToolUserError("file not found");
    },
  });

  scriptedRounds.push((model) => {
    const tc: ToolCall = { type: "toolCall", id: "tc_s", name: "soft_fail", arguments: {} };
    return emitStream((s) => {
      const partial = fakeAssistant(model, [tc], "toolUse");
      s.push({ type: "toolcall_end", contentIndex: 0, toolCall: tc, partial });
      s.push({ type: "done", reason: "toolUse", message: partial });
    });
  });
  scriptedRounds.push((model) => {
    return emitStream((s) => {
      const partial = fakeAssistant(model, [{ type: "text", text: "noted, retrying later" }], "stop");
      s.push({ type: "text_delta", contentIndex: 0, delta: "noted, retrying later", partial });
      s.push({ type: "done", reason: "stop", message: partial });
    });
  });

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.submit",
    params: { sessionId, turnId: "T1", prompt: "trigger soft fail", citedContext: {} },
  });

  await flush();

  const toolResults = captured.notifications.filter(
    (n) => n.method === "ui.toolCall" && n.params.phase === "result",
  );
  expect(toolResults).toHaveLength(1);
  expect(toolResults[0].params.isError).toBe(true);
  expect(toolResults[0].params.outputText).toBe("file not found");

  expect(convo.turns[0].status).toBe("done");
});

test("unexpected handler exception is surfaced as an isError tool result and the loop continues", async () => {
  // A handler throwing a plain Error (i.e. not a `ToolUserError`) used to
  // terminate the whole turn as a harness-fault `ui.error`. The new policy:
  // one tool blowing up is recoverable. The dispatch site catches the
  // exception, writes a synthetic isError tool result into the conversation,
  // emits a `phase: "result"` frame, and lets the loop run another round so
  // the model can react. This keeps the conversation slice consistent
  // (no orphan `tool_use`) — important because errored turns now stay in
  // the next request's context for retry.
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, convo, sessionId } = setupSession();
  registerAgentHandlers(dispatcher, { manager });

  toolRegistry.register({
    spec: {
      name: "boom",
      description: "Always throws plain Error",
      parameters: { type: "object", properties: {} },
    },
    execute: async () => {
      throw new Error("kaboom");
    },
  });

  scriptedRounds.push((model) => {
    const tc: ToolCall = { type: "toolCall", id: "tc_b", name: "boom", arguments: {} };
    return emitStream((s) => {
      const partial = fakeAssistant(model, [tc], "toolUse");
      s.push({ type: "toolcall_end", contentIndex: 0, toolCall: tc, partial });
      s.push({ type: "done", reason: "toolUse", message: partial });
    });
  });
  // Second round IS reached: the loop must continue past the failing tool.
  // The model "sees" the isError result and replies with text, terminating
  // the turn cleanly.
  scriptedRounds.push((model) => {
    return emitStream((s) => {
      const partial = fakeAssistant(model, [{ type: "text", text: "ok, recovering" }], "stop");
      s.push({ type: "text_delta", contentIndex: 0, delta: "ok, recovering", partial });
      s.push({ type: "done", reason: "stop", message: partial });
    });
  });

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.submit",
    params: { sessionId, turnId: "T1", prompt: "trigger boom", citedContext: {} },
  });

  await flush();

  // The wire still gets a closing `result` frame so the Shell row doesn't
  // dangle; isError + the exception text round-trip to the UI.
  const toolResults = captured.notifications.filter(
    (n) => n.method === "ui.toolCall" && n.params.phase === "result",
  );
  expect(toolResults).toHaveLength(1);
  expect(toolResults[0].params.toolCallId).toBe("tc_b");
  expect(toolResults[0].params.isError).toBe(true);
  expect(toolResults[0].params.outputText).toContain("kaboom");

  // No turn-level ui.error: the throw is treated as a recoverable tool
  // failure, not a harness fault.
  const errorEvents = captured.notifications.filter((n) => n.method === "ui.error");
  expect(errorEvents).toHaveLength(0);

  // Loop continued and the second round's text reply settled the turn done.
  expect(convo.turns[0].status).toBe("done");
  expect(convo.turns[0].reply).toBe("ok, recovering");

  // The synthetic tool result is in the durable history so the next LLM
  // round (and any session retry) sees the failure inline rather than an
  // orphan tool_use.
  const tr = convo.messages.find(
    (m) => m.role === "toolResult" && m.toolCallId === "tc_b",
  );
  expect(tr).toBeDefined();
});

test("cancellation mid-tool closes the turn quietly — no ui.error", async () => {
  // Regression: agent.cancel during a tool call used to surface as a
  // turn-fatal `ui.error`. The dispatcher rejects an aborted outbound
  // request with a plain `Error("... aborted")` (NOT an `RPCMethodError`),
  // so the recoverable-error filter in computer-use's `callCU` doesn't
  // catch it and it bubbled to runTurn's top-level catch. runTool now
  // checks `ctx.signal.aborted` in its catch and returns a closing
  // `isError` result instead of rethrowing, so runTurn's existing
  // `if (signal.aborted)` branch closes the turn via `ui.status: done`.
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, convo, sessionId } = setupSession();
  registerAgentHandlers(dispatcher, { manager });

  // Tool blocks on a 5s sleep, racing the abort signal. When the test
  // sends `agent.cancel` mid-call, the abort listener rejects — same
  // shape as Dispatcher.request rejecting on signal.aborted.
  toolRegistry.register({
    spec: {
      name: "slow",
      description: "Sleeps until cancelled",
      parameters: { type: "object", properties: {} },
    },
    execute: async (_args, ctx) => {
      await new Promise<void>((resolve, reject) => {
        if (ctx.signal.aborted) {
          reject(new Error("aborted before start"));
          return;
        }
        const onAbort = () => {
          clearTimeout(timer);
          reject(new Error("request 'slow' aborted"));
        };
        const timer = setTimeout(() => {
          ctx.signal.removeEventListener("abort", onAbort);
          resolve();
        }, 5000);
        ctx.signal.addEventListener("abort", onAbort, { once: true });
      });
      return { content: [{ type: "text", text: "should not reach" }], isError: false };
    },
  });

  scriptedRounds.push((model) => {
    const tc: ToolCall = { type: "toolCall", id: "tc_slow", name: "slow", arguments: {} };
    return emitStream((s) => {
      const partial = fakeAssistant(model, [tc], "toolUse");
      s.push({ type: "toolcall_end", contentIndex: 0, toolCall: tc, partial });
      s.push({ type: "done", reason: "toolUse", message: partial });
    });
  });
  // Subsequent rounds MUST NOT run — cancellation should end the turn.
  scriptedRounds.push(() => {
    throw new Error("loop should not have advanced past the cancelled tool");
  });

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.submit",
    params: { sessionId, turnId: "T1", prompt: "start slow tool", citedContext: {} },
  });
  // Let the loop reach the tool's await before cancelling.
  await flush(60);
  pushInbound({
    jsonrpc: "2.0",
    id: 2,
    method: "agent.cancel",
    params: { sessionId, turnId: "T1" },
  });
  await flush(120);

  // No ui.error fired — that's the bug we're regressing against.
  const errorEvents = captured.notifications.filter((n) => n.method === "ui.error");
  expect(errorEvents).toHaveLength(0);

  // The toolCall row must have a closing `result` frame so the UI
  // doesn't strand it in `.calling`. The closing frame is isError=true
  // with a "cancelled" message; that's what runTool returns on abort.
  const toolResults = captured.notifications.filter(
    (n) => n.method === "ui.toolCall" && n.params.phase === "result",
  );
  expect(toolResults).toHaveLength(1);
  expect(toolResults[0].params.toolCallId).toBe("tc_slow");
  expect(toolResults[0].params.isError).toBe(true);
  expect(toolResults[0].params.outputText).toContain("cancelled");

  // Turn ends in `cancelled` state (set by the agent.cancel handler),
  // not `error`.
  expect(convo.turns[0].status).toBe("cancelled");
});

test("invalid tool arguments produce an isError result with the validator's message", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, convo, sessionId } = setupSession();
  registerAgentHandlers(dispatcher, { manager });

  toolRegistry.register({
    spec: {
      name: "needs_text",
      description: "Requires text",
      parameters: {
        type: "object",
        properties: { text: { type: "string" } },
        required: ["text"],
      },
    },
    execute: async () => ({ content: [{ type: "text", text: "ok" }], isError: false }),
  });

  scriptedRounds.push((model) => {
    // Missing required `text` field.
    const tc: ToolCall = { type: "toolCall", id: "tc_v", name: "needs_text", arguments: {} };
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

  // Schema-validation failure routes to the `rejected` phase, not `result` —
  // the handler never executed. The validator's message is on the rejection
  // and also lands in the conversation as a tool result for the model.
  const rejected = captured.notifications.filter(
    (n) => n.method === "ui.toolCall" && n.params.phase === "rejected",
  );
  expect(rejected).toHaveLength(1);
  expect(rejected[0].params.errorMessage).toContain("Validation failed");
  const toolResults = captured.notifications.filter(
    (n) => n.method === "ui.toolCall" && n.params.phase === "result",
  );
  expect(toolResults).toHaveLength(0);
  expect(convo.turns[0].status).toBe("done");
});
