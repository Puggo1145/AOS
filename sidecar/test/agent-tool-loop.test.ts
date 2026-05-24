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
import { join } from "node:path";
import { mkdirSync } from "node:fs";
import { z } from "zod";
import { registerAgentHandlers, setModelResolver, resetModelResolver } from "../src/agent/loop";
import { SessionManager } from "../src/agent/session/manager";
import { toolRegistry } from "../src/agent/tools/core/registry";
import { defineTool, ToolUserError } from "../src/agent/tools";
import { registerComputerUseTools } from "../src/agent/tools/builtins/computer-use";
import { workspaceDir } from "../src/agent/workspace";
import { RPCMethod } from "../src/rpc/rpc-types";
import {
  PermissionGateway,
  PermissionPolicyConfigurationError,
  builtinPermissionPolicyCatalog,
} from "../src/agent/permissions";
import {
  registerApiProvider,
  unregisterApiProviders,
  type Model,
  type Api,
  type AssistantMessage,
  type ToolCall,
} from "../src/llm";
import { AssistantMessageEventStream } from "../src/llm/utils/event-stream";
import {
  flush,
  allowAllPermissionGateway,
  makeCapturingDispatcher,
  makeFakeModel as baseFakeModel,
  setupSession,
} from "./support/agent-harness";

const FAKE_SOURCE_ID = "test-tool-loop";

function makeFakeModel(): Model<Api> {
  return baseFakeModel({ id: "fake-tool-model" });
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
let scriptedRounds: ((model: Model<Api>, signal?: AbortSignal) => AssistantMessageEventStream)[] = [];
let observedContexts: { messages: any[] }[] = [];

beforeEach(() => {
  mkdirSync(workspaceDir(), { recursive: true });
  registerApiProvider({
    api: "openai-responses",
    sourceId: FAKE_SOURCE_ID,
    stream: (model, ctx, options) => {
      observedContexts.push({ messages: ctx.messages });
      const next = scriptedRounds.shift();
      if (!next) throw new Error("test ran out of scripted rounds");
      return next(model, options?.signal);
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
  registerAgentHandlers(dispatcher, { manager, permissionGateway: allowAllPermissionGateway() });

  // Echo tool: returns its `text` argument verbatim.
  let receivedArgs: unknown = null;
  toolRegistry.register(defineTool({
    name: "echo",
    description: "Echo a string",
    parameters: z.object({ text: z.string() }).strict(),
    execute: async (args) => {
      receivedArgs = args;
      return { content: [{ type: "text", text: `echoed: ${args.text}` }], isError: false };
    },
  }));

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

test("computer-use app session is stopped after the terminal assistant reply", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const computerUseRequests: { method: string; params: object }[] = [];
  (dispatcher as any).request = async (method: string, params: object) => {
    computerUseRequests.push({ method, params });
    if (method === RPCMethod.computerUseStopAppSession) return { stopped: true, pid: 123 };
    return { pid: 123 };
  };
  const { manager, convo, sessionId } = setupSession();
  registerComputerUseTools(toolRegistry, dispatcher);
  registerAgentHandlers(dispatcher, { manager, permissionGateway: allowAllPermissionGateway() });

  scriptedRounds.push((model) => {
    const tc: ToolCall = {
      type: "toolCall",
      id: "tc_start",
      name: "start_app_session",
      arguments: { pid: 123, windowId: 456 },
    };
    return emitStream((s) => {
      const partial = fakeAssistant(model, [tc], "toolUse");
      s.push({ type: "toolcall_end", contentIndex: 0, toolCall: tc, partial });
      s.push({ type: "done", reason: "toolUse", message: partial });
    });
  });
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
    params: { sessionId, turnId: "T1", prompt: "use app then answer", citedContext: {} },
  });

  await flush();

  expect(computerUseRequests).toEqual([
    { method: RPCMethod.computerUseStartAppSession, params: { pid: 123, windowId: 456 } },
    { method: RPCMethod.computerUseStopAppSession, params: { pid: 123 } },
  ]);
  const doneIdx = captured.notifications.findIndex(
    (n) => n.method === "ui.status" && n.params.status === "done",
  );
  expect(doneIdx).toBeGreaterThan(-1);
  expect(convo.turns[0].status).toBe("done");
});

test("computer-use stop is not requested after terminal assistant reply without a recorded start", async () => {
  const { dispatcher, pushInbound } = makeCapturingDispatcher();
  const computerUseRequests: { method: string; params: object }[] = [];
  (dispatcher as any).request = async (method: string, params: object) => {
    computerUseRequests.push({ method, params });
    return { stopped: false };
  };
  const { manager, convo, sessionId } = setupSession();
  registerAgentHandlers(dispatcher, { manager, permissionGateway: allowAllPermissionGateway() });

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
    params: { sessionId, turnId: "T1", prompt: "answer normally", citedContext: {} },
  });

  await flush();

  expect(computerUseRequests).toEqual([]);
  expect(convo.turns[0].status).toBe("done");
});

test("terminal reply in another agent session does not stop this session's app session", async () => {
  const { dispatcher, pushInbound } = makeCapturingDispatcher();
  const computerUseRequests: { method: string; params: object }[] = [];
  (dispatcher as any).request = async (method: string, params: object) => {
    computerUseRequests.push({ method, params });
    if (method === RPCMethod.computerUseStopAppSession) return { stopped: true, pid: 123 };
    return { pid: 123 };
  };
  const manager = new SessionManager();
  const sessionA = manager.create();
  const sessionB = manager.create();
  registerComputerUseTools(toolRegistry, dispatcher);
  registerAgentHandlers(dispatcher, { manager, permissionGateway: allowAllPermissionGateway() });

  scriptedRounds.push((model) => {
    const tc: ToolCall = {
      type: "toolCall",
      id: "tc_start_b",
      name: "start_app_session",
      arguments: { pid: 123, windowId: 456 },
    };
    return emitStream((s) => {
      const partial = fakeAssistant(model, [tc], "toolUse");
      s.push({ type: "toolcall_end", contentIndex: 0, toolCall: tc, partial });
      s.push({ type: "done", reason: "toolUse", message: partial });
    });
  });
  scriptedRounds.push((_model, signal) => {
    const s = new AssistantMessageEventStream();
    signal?.addEventListener(
      "abort",
      () => {
        const terminal = fakeAssistant(_model, [], "stop");
        terminal.stopReason = "aborted";
        s.push({ type: "done", reason: "stop", message: terminal });
        s.end();
      },
      { once: true },
    );
    return s;
  });
  scriptedRounds.push((model) => {
    return emitStream((s) => {
      const partial = fakeAssistant(model, [{ type: "text", text: "A done" }], "stop");
      s.push({ type: "text_delta", contentIndex: 0, delta: "A done", partial });
      s.push({ type: "done", reason: "stop", message: partial });
    });
  });

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.submit",
    params: { sessionId: sessionB.id, turnId: "TB", prompt: "start app session", citedContext: {} },
  });
  await flush();

  pushInbound({
    jsonrpc: "2.0",
    id: 2,
    method: "agent.submit",
    params: { sessionId: sessionA.id, turnId: "TA", prompt: "answer normally", citedContext: {} },
  });
  await flush();

  expect(computerUseRequests).toEqual([
    { method: RPCMethod.computerUseStartAppSession, params: { pid: 123, windowId: 456 } },
  ]);

  pushInbound({
    jsonrpc: "2.0",
    id: 3,
    method: "agent.cancel",
    params: { sessionId: sessionB.id, turnId: "TB" },
  });
  await flush();
});

test("unknown tool surfaces as isError result, loop continues to terminal reply", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, convo, sessionId } = setupSession();
  registerAgentHandlers(dispatcher, { manager, permissionGateway: allowAllPermissionGateway() });

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
  registerAgentHandlers(dispatcher, { manager, permissionGateway: allowAllPermissionGateway() });

  toolRegistry.register(defineTool({
    name: "soft_fail",
    description: "Throws ToolUserError",
    parameters: z.object({}).strict(),
    execute: async () => {
      throw new ToolUserError("file not found");
    },
  }));

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
  registerAgentHandlers(dispatcher, { manager, permissionGateway: allowAllPermissionGateway() });

  toolRegistry.register(defineTool({
    name: "boom",
    description: "Always throws plain Error",
    parameters: z.object({}).strict(),
    execute: async () => {
      throw new Error("kaboom");
    },
  }));

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
  registerAgentHandlers(dispatcher, { manager, permissionGateway: allowAllPermissionGateway() });

  // Tool blocks on a 5s sleep, racing the abort signal. When the test
  // sends `agent.cancel` mid-call, the abort listener rejects — same
  // shape as Dispatcher.request rejecting on signal.aborted.
  toolRegistry.register(defineTool({
    name: "slow",
    description: "Sleeps until cancelled",
    parameters: z.object({}).strict(),
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
  }));

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
  registerAgentHandlers(dispatcher, { manager, permissionGateway: allowAllPermissionGateway() });

  toolRegistry.register(defineTool({
    name: "needs_text",
    description: "Requires text",
    parameters: z.object({ text: z.string() }).strict(),
    execute: async () => ({ content: [{ type: "text", text: "ok" }], isError: false }),
  }));

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

test("permission denial does not execute the tool and records a non-error tool result", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, convo, sessionId } = setupSession();
  const permissionGateway = new PermissionGateway(dispatcher, builtinPermissionPolicyCatalog);
  registerAgentHandlers(dispatcher, { manager, permissionGateway });

  let executed = false;
  toolRegistry.register(defineTool({
    name: "write",
    description: "Write outside workspace",
    parameters: z.object({ path: z.string(), content: z.string() }).strict(),
    execute: async () => {
      executed = true;
      return { content: [{ type: "text", text: "wrote" }], isError: false };
    },
  }));

  const path = `/tmp/notch-permission-${crypto.randomUUID()}.txt`;
  scriptedRounds.push((model) => {
    const tc: ToolCall = { type: "toolCall", id: "tc_perm_write", name: "write", arguments: { path, content: "hello" } };
    return emitStream((s) => {
      const partial = fakeAssistant(model, [tc], "toolUse");
      s.push({ type: "toolcall_end", contentIndex: 0, toolCall: tc, partial });
      s.push({ type: "done", reason: "toolUse", message: partial });
    });
  });
  scriptedRounds.push((model) => emitStream((s) => {
    const partial = fakeAssistant(model, [{ type: "text", text: "permission denied noted" }], "stop");
    s.push({ type: "text_delta", contentIndex: 0, delta: "permission denied noted", partial });
    s.push({ type: "done", reason: "stop", message: partial });
  }));

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.submit",
    params: { sessionId, turnId: "T1", prompt: "write file", citedContext: {} },
  });
  await flush(60);

  const approval = captured.requests.find((r) => r.method === RPCMethod.permissionRequestApproval);
  expect(approval).toBeDefined();
  expect(captured.notifications.some((n) => n.method === "ui.status" && n.params.status === "awaitingPermission")).toBe(true);
  pushInbound({ jsonrpc: "2.0", id: approval!.id, result: { decision: "deny" } });
  await flush();

  expect(executed).toBe(false);
  const denied = captured.notifications.filter(
    (n) => n.method === "ui.toolCall" && n.params.phase === "permissionDenied",
  );
  expect(denied).toHaveLength(1);
  expect(denied[0].params.toolName).toBe("write");
  const resultFrames = captured.notifications.filter(
    (n) => n.method === "ui.toolCall" && n.params.phase === "result" && n.params.toolCallId === "tc_perm_write",
  );
  expect(resultFrames).toHaveLength(0);

  const toolResult = convo.messages.find((m) => m.role === "toolResult" && m.toolCallId === "tc_perm_write");
  expect(toolResult).toMatchObject({
    role: "toolResult",
    toolName: "write",
    isError: false,
  });
});

test("workspace write is allowed without approval", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, convo, sessionId } = setupSession();
  const permissionGateway = new PermissionGateway(dispatcher, builtinPermissionPolicyCatalog);
  registerAgentHandlers(dispatcher, { manager, permissionGateway });

  const path = join(workspaceDir(), `agent-write-${crypto.randomUUID()}.txt`);
  let executed = false;
  toolRegistry.register(defineTool({
    name: "write",
    description: "Write workspace file",
    parameters: z.object({ path: z.string(), content: z.string() }).strict(),
    execute: async () => {
      executed = true;
      return { content: [{ type: "text", text: "wrote workspace file" }], isError: false };
    },
  }));

  scriptedRounds.push((model) => {
    const tc: ToolCall = { type: "toolCall", id: "tc_workspace_write", name: "write", arguments: { path, content: "hello" } };
    return emitStream((s) => {
      const partial = fakeAssistant(model, [tc], "toolUse");
      s.push({ type: "toolcall_end", contentIndex: 0, toolCall: tc, partial });
      s.push({ type: "done", reason: "toolUse", message: partial });
    });
  });
  scriptedRounds.push((model) => emitStream((s) => {
    const partial = fakeAssistant(model, [{ type: "text", text: "done" }], "stop");
    s.push({ type: "text_delta", contentIndex: 0, delta: "done", partial });
    s.push({ type: "done", reason: "stop", message: partial });
  }));

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.submit",
    params: { sessionId, turnId: "T1", prompt: "write workspace file", citedContext: {} },
  });
  await flush();

  expect(executed).toBe(true);
  expect(captured.requests.filter((r) => r.method === RPCMethod.permissionRequestApproval)).toHaveLength(0);
  expect(convo.messages.find((m) => m.role === "toolResult" && m.toolCallId === "tc_workspace_write")).toMatchObject({
    isError: false,
  });
});

test("bash asks for approval before execution", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, sessionId } = setupSession();
  const permissionGateway = new PermissionGateway(dispatcher, builtinPermissionPolicyCatalog);
  registerAgentHandlers(dispatcher, { manager, permissionGateway });

  let executed = false;
  const command = `echo ${crypto.randomUUID()}`;
  toolRegistry.register(defineTool({
    name: "bash",
    description: "Run command",
    parameters: z.object({ command: z.string(), timeout: z.number().optional() }).strict(),
    execute: async () => {
      executed = true;
      return { content: [{ type: "text", text: "command ran" }], isError: false };
    },
  }));

  scriptedRounds.push((model) => {
    const tc: ToolCall = { type: "toolCall", id: "tc_bash", name: "bash", arguments: { command, timeout: 5 } };
    return emitStream((s) => {
      const partial = fakeAssistant(model, [tc], "toolUse");
      s.push({ type: "toolcall_end", contentIndex: 0, toolCall: tc, partial });
      s.push({ type: "done", reason: "toolUse", message: partial });
    });
  });
  scriptedRounds.push((model) => emitStream((s) => {
    const partial = fakeAssistant(model, [{ type: "text", text: "done" }], "stop");
    s.push({ type: "text_delta", contentIndex: 0, delta: "done", partial });
    s.push({ type: "done", reason: "stop", message: partial });
  }));

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.submit",
    params: { sessionId, turnId: "T1", prompt: "run command", citedContext: {} },
  });
  await flush(60);

  const approval = captured.requests.find((r) => r.method === RPCMethod.permissionRequestApproval);
  expect(approval).toBeDefined();
  expect(approval!.params).toMatchObject({
    toolName: "bash",
    title: "Allow command?",
    capabilities: [{ capability: "process.spawn", target: command }],
  });
  expect(executed).toBe(false);

  pushInbound({ jsonrpc: "2.0", id: approval!.id, result: { decision: "allow" } });
  await flush();

  expect(executed).toBe(true);
});

test("approval RPC failure is a turn-level failure instead of a model-visible tool result", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, convo, sessionId } = setupSession();
  const permissionGateway = new PermissionGateway(dispatcher, builtinPermissionPolicyCatalog);
  registerAgentHandlers(dispatcher, { manager, permissionGateway });

  let executed = false;
  const path = `/tmp/notch-approval-failure-${crypto.randomUUID()}.txt`;
  toolRegistry.register(defineTool({
    name: "write",
    description: "Write outside workspace",
    parameters: z.object({ path: z.string(), content: z.string() }).strict(),
    execute: async () => {
      executed = true;
      return { content: [{ type: "text", text: "wrote" }], isError: false };
    },
  }));

  scriptedRounds.push((model) => {
    const tc: ToolCall = { type: "toolCall", id: "tc_approval_failure", name: "write", arguments: { path, content: "hello" } };
    return emitStream((s) => {
      const partial = fakeAssistant(model, [tc], "toolUse");
      s.push({ type: "toolcall_end", contentIndex: 0, toolCall: tc, partial });
      s.push({ type: "done", reason: "toolUse", message: partial });
    });
  });
  scriptedRounds.push((model) => emitStream((s) => {
    const partial = fakeAssistant(model, [{ type: "text", text: "noted" }], "stop");
    s.push({ type: "text_delta", contentIndex: 0, delta: "noted", partial });
    s.push({ type: "done", reason: "stop", message: partial });
  }));

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.submit",
    params: { sessionId, turnId: "T1", prompt: "write outside", citedContext: {} },
  });
  await flush(60);

  const approval = captured.requests.find((r) => r.method === RPCMethod.permissionRequestApproval);
  expect(approval).toBeDefined();
  pushInbound({
    jsonrpc: "2.0",
    id: approval!.id,
    error: { code: -32000, message: "approval UI failed" },
  });
  await flush();

  expect(executed).toBe(false);
  const toolResult = convo.messages.find((m) => m.role === "toolResult" && m.toolCallId === "tc_approval_failure");
  expect(toolResult).toBeUndefined();
  expect(captured.notifications).toContainEqual({
    method: RPCMethod.uiError,
    params: {
      sessionId,
      turnId: "T1",
      code: -32603,
      message: "Permission approval failed: approval UI failed",
    },
  });
});

test("permission configuration errors are turn-level failures instead of model-visible tool results", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, convo, sessionId } = setupSession();
  registerAgentHandlers(dispatcher, {
    manager,
    permissionGateway: {
      async authorize() {
        throw new PermissionPolicyConfigurationError("missing permission policy for tool \"echo\"");
      },
      clearTurnGrants() {},
    },
  });

  let executed = false;
  toolRegistry.register(defineTool({
    name: "echo",
    description: "Echo",
    parameters: z.object({ text: z.string() }).strict(),
    execute: async () => {
      executed = true;
      return { content: [{ type: "text", text: "echoed" }], isError: false };
    },
  }));

  scriptedRounds.push((model) => {
    const tc: ToolCall = { type: "toolCall", id: "tc_missing_permission", name: "echo", arguments: { text: "hi" } };
    return emitStream((s) => {
      const partial = fakeAssistant(model, [tc], "toolUse");
      s.push({ type: "toolcall_end", contentIndex: 0, toolCall: tc, partial });
      s.push({ type: "done", reason: "toolUse", message: partial });
    });
  });

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.submit",
    params: { sessionId, turnId: "T1", prompt: "echo", citedContext: {} },
  });
  await flush();

  expect(executed).toBe(false);
  expect(convo.messages.find((m) => m.role === "toolResult" && m.toolCallId === "tc_missing_permission")).toBeUndefined();
  expect(captured.notifications).toContainEqual({
    method: RPCMethod.uiError,
    params: {
      sessionId,
      turnId: "T1",
      code: -32603,
      message: "missing permission policy for tool \"echo\"",
    },
  });
});

test("permission policy callback errors are turn-level failures instead of model-visible tool results", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, convo, sessionId } = setupSession();
  const permissionGateway = new PermissionGateway(dispatcher, builtinPermissionPolicyCatalog);
  registerAgentHandlers(dispatcher, { manager, permissionGateway });

  let executed = false;
  toolRegistry.register(defineTool({
    name: "write",
    description: "Write with a deliberately mismatched schema",
    parameters: z.object({ path: z.string() }).strict(),
    execute: async () => {
      executed = true;
      return { content: [{ type: "text", text: "wrote" }], isError: false };
    },
  }));

  scriptedRounds.push((model) => {
    const tc: ToolCall = {
      type: "toolCall",
      id: "tc_policy_callback_error",
      name: "write",
      arguments: { path: `/tmp/notch-policy-callback-${crypto.randomUUID()}.txt` },
    };
    return emitStream((s) => {
      const partial = fakeAssistant(model, [tc], "toolUse");
      s.push({ type: "toolcall_end", contentIndex: 0, toolCall: tc, partial });
      s.push({ type: "done", reason: "toolUse", message: partial });
    });
  });

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.submit",
    params: { sessionId, turnId: "T1", prompt: "write", citedContext: {} },
  });
  await flush();

  expect(executed).toBe(false);
  expect(convo.messages.find((m) => m.role === "toolResult" && m.toolCallId === "tc_policy_callback_error")).toBeUndefined();
  expect(captured.notifications).toContainEqual({
    method: RPCMethod.uiError,
    params: {
      sessionId,
      turnId: "T1",
      code: -32603,
      message: 'permission policy "write" failed for tool "write": permission policy expected content to be a string',
    },
  });
});

test("computer read tools execute without approval", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, sessionId } = setupSession();
  const permissionGateway = new PermissionGateway(dispatcher, builtinPermissionPolicyCatalog);
  registerAgentHandlers(dispatcher, { manager, permissionGateway });

  let executed = false;
  toolRegistry.register(defineTool({
    name: "list_apps",
    description: "List apps",
    parameters: z.object({ mode: z.string().optional() }).strict(),
    execute: async () => {
      executed = true;
      return { content: [{ type: "text", text: "Finder" }], isError: false };
    },
  }));

  scriptedRounds.push((model) => {
    const tc: ToolCall = { type: "toolCall", id: "tc_list_apps", name: "list_apps", arguments: { mode: "running" } };
    return emitStream((s) => {
      const partial = fakeAssistant(model, [tc], "toolUse");
      s.push({ type: "toolcall_end", contentIndex: 0, toolCall: tc, partial });
      s.push({ type: "done", reason: "toolUse", message: partial });
    });
  });
  scriptedRounds.push((model) => emitStream((s) => {
    const partial = fakeAssistant(model, [{ type: "text", text: "done" }], "stop");
    s.push({ type: "text_delta", contentIndex: 0, delta: "done", partial });
    s.push({ type: "done", reason: "stop", message: partial });
  }));

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.submit",
    params: { sessionId, turnId: "T1", prompt: "list apps", citedContext: {} },
  });
  await flush();

  expect(executed).toBe(true);
  expect(captured.requests.filter((r) => r.method === RPCMethod.permissionRequestApproval)).toHaveLength(0);
});

test("cancelling during pending permission approval does not create a permission denial result", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, convo, sessionId } = setupSession();
  const permissionGateway = new PermissionGateway(dispatcher, builtinPermissionPolicyCatalog);
  registerAgentHandlers(dispatcher, { manager, permissionGateway });

  let executed = false;
  const path = `/tmp/notch-cancel-approval-${crypto.randomUUID()}.txt`;
  toolRegistry.register(defineTool({
    name: "write",
    description: "Write outside workspace",
    parameters: z.object({ path: z.string(), content: z.string() }).strict(),
    execute: async () => {
      executed = true;
      return { content: [{ type: "text", text: "wrote" }], isError: false };
    },
  }));

  scriptedRounds.push((model) => {
    const tc: ToolCall = { type: "toolCall", id: "tc_cancel_permission", name: "write", arguments: { path, content: "hello" } };
    return emitStream((s) => {
      const partial = fakeAssistant(model, [tc], "toolUse");
      s.push({ type: "toolcall_end", contentIndex: 0, toolCall: tc, partial });
      s.push({ type: "done", reason: "toolUse", message: partial });
    });
  });
  scriptedRounds.push(() => {
    throw new Error("loop should not continue after cancellation while waiting for permission");
  });

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.submit",
    params: { sessionId, turnId: "T1", prompt: "write outside", citedContext: {} },
  });
  await flush(60);

  expect(captured.requests.find((r) => r.method === RPCMethod.permissionRequestApproval)).toBeDefined();
  pushInbound({
    jsonrpc: "2.0",
    id: 2,
    method: "agent.cancel",
    params: { sessionId, turnId: "T1" },
  });
  await flush(120);

  expect(executed).toBe(false);
  expect(captured.notifications).toContainEqual({
    method: RPCMethod.permissionApprovalCancelled,
    params: { sessionId, turnId: "T1", toolCallId: "tc_cancel_permission" },
  });
  expect(captured.notifications.filter((n) => n.method === "ui.toolCall" && n.params.phase === "permissionDenied")).toHaveLength(0);
  const toolResult = convo.messages.find((m) => m.role === "toolResult" && m.toolCallId === "tc_cancel_permission");
  expect(toolResult).toMatchObject({
    role: "toolResult",
    toolName: "write",
    isError: true,
    content: [{ type: "text", text: "Cancelled by user" }],
  });
  expect(convo.turns[0].status).toBe("cancelled");
});

test("computer-use turn grant allows subsequent same-turn actuating tools without another approval", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, sessionId } = setupSession();
  const permissionGateway = new PermissionGateway(dispatcher, builtinPermissionPolicyCatalog);
  registerAgentHandlers(dispatcher, { manager, permissionGateway });

  const executed: string[] = [];
  for (const name of ["use_keyboard", "use_mouse"]) {
    toolRegistry.register(defineTool({
      name,
      description: name,
      parameters: z.object({ windowId: z.number(), event: z.any() }).strict(),
      execute: async () => {
        executed.push(name);
        return { content: [{ type: "text", text: `${name} ok` }], isError: false };
      },
    }));
  }

  scriptedRounds.push((model) => {
    const keyboard: ToolCall = {
      type: "toolCall",
      id: "tc_keyboard",
      name: "use_keyboard",
      arguments: { windowId: 42, event: { kind: "keyPress", key: "a" } },
    };
    const mouse: ToolCall = {
      type: "toolCall",
      id: "tc_mouse",
      name: "use_mouse",
      arguments: { windowId: 42, event: { kind: "click", button: "left", point: { x: 1, y: 2 } } },
    };
    return emitStream((s) => {
      const partial = fakeAssistant(model, [keyboard, mouse], "toolUse");
      s.push({ type: "toolcall_end", contentIndex: 0, toolCall: keyboard, partial });
      s.push({ type: "toolcall_end", contentIndex: 1, toolCall: mouse, partial });
      s.push({ type: "done", reason: "toolUse", message: partial });
    });
  });
  scriptedRounds.push((model) => emitStream((s) => {
    const partial = fakeAssistant(model, [{ type: "text", text: "done" }], "stop");
    s.push({ type: "text_delta", contentIndex: 0, delta: "done", partial });
    s.push({ type: "done", reason: "stop", message: partial });
  }));

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.submit",
    params: { sessionId, turnId: "T1", prompt: "use computer", citedContext: {} },
  });
  await flush(60);

  const approval = captured.requests.find((r) => r.method === RPCMethod.permissionRequestApproval);
  expect(approval?.params.title).toBe("Allow Computer Use?");
  pushInbound({ jsonrpc: "2.0", id: approval!.id, result: { decision: "allow" } });
  await flush();

  expect(executed).toEqual(["use_keyboard", "use_mouse"]);
  const approvalRequests = captured.requests.filter((r) => r.method === RPCMethod.permissionRequestApproval);
  expect(approvalRequests).toHaveLength(1);
});
