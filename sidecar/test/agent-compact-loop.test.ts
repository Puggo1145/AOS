// Agent loop — auto-compact integration end-to-end.
//
// Verifies the s06 contract on top of the existing single-turn machinery:
//   - When `convo.lastTotalTokens` is close to `model.contextWindow` at
//     runTurn entry (remaining < 20K), the loop compacts BEFORE issuing
//     the new turn's first LLM round, and emits `ui.compact` lifecycle
//     notifications.
//   - The post-compact request the loop sends carries the boundary +
//     summary + active-turn slice — past turns no longer leak into the
//     model's view.
//   - When remaining context is comfortable, no compaction runs.
//   - Failing summarization → `ui.compact failed`, conversation is
//     untouched, and the loop proceeds with the original history.
//   - After compact, the ambient block (todos) is still appended on the
//     next round — proving the ambient subsystem is the intended
//     replacement for explicit todo re-injection.

import { test, expect, beforeEach, afterEach } from "bun:test";
import { registerAgentHandlers, setModelResolver, resetModelResolver } from "../src/agent/loop";
import { SessionManager } from "../src/agent/session/manager";
import { toolRegistry } from "../src/agent/tools/registry";
import { ambientRegistry } from "../src/agent/ambient/registry";
import { todosAmbientProvider } from "../src/agent/ambient/providers/todos";
import { compactBreaker } from "../src/agent/compact";
import {
  registerApiProvider,
  unregisterApiProviders,
  type Model,
  type Api,
  type AssistantMessage,
} from "../src/llm";
import { AssistantMessageEventStream } from "../src/llm/utils/event-stream";
import {
  flush,
  makeCapturingDispatcher,
  makeFakeModel as baseFakeModel,
} from "./support/agent-harness";

const FAKE_SOURCE_ID = "test-compact-loop";

function makeFakeModel(): Model<Api> {
  return baseFakeModel({ id: "fake-compact-model" });
}

function fakeAssistant(model: Model<Api>, text: string, stop: "stop" | "toolUse" = "stop"): AssistantMessage {
  return {
    role: "assistant",
    content: [{ type: "text", text }],
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

interface ProviderCall {
  systemPrompt: string;
  messages: any[];
  toolsArg: unknown;
}

let scriptedRounds: ((model: Model<Api>, signal?: AbortSignal) => AssistantMessageEventStream)[] = [];
let providerCalls: ProviderCall[] = [];

beforeEach(() => {
  registerApiProvider({
    api: "openai-responses",
    sourceId: FAKE_SOURCE_ID,
    stream: (model, ctx, options) => {
      providerCalls.push({
        systemPrompt: ctx.systemPrompt ?? "",
        messages: JSON.parse(JSON.stringify(ctx.messages)),
        toolsArg: ctx.tools,
      });
      const next = scriptedRounds.shift();
      if (!next) throw new Error("test ran out of scripted rounds");
      return next(model, options?.signal);
    },
  });
  setModelResolver(() => makeFakeModel());
  toolRegistry.clear();
  ambientRegistry.clear();
  compactBreaker.clear();
});

afterEach(() => {
  unregisterApiProviders(FAKE_SOURCE_ID);
  resetModelResolver();
  toolRegistry.clear();
  ambientRegistry.clear();
  compactBreaker.clear();
  scriptedRounds = [];
  providerCalls = [];
});

function emitTextStream(text: string): (m: Model<Api>) => AssistantMessageEventStream {
  return (model) => {
    const s = new AssistantMessageEventStream();
    queueMicrotask(() => {
      const partial = fakeAssistant(model, text);
      s.push({ type: "text_delta", contentIndex: 0, delta: text, partial });
      s.push({ type: "done", reason: "stop", message: partial });
      s.end();
    });
    return s;
  };
}

function makeSessionWithHistory(turnsCount: number): {
  manager: SessionManager;
  session: ReturnType<SessionManager["create"]>;
  sessionId: string;
} {
  const manager = new SessionManager();
  const session = manager.create();
  for (let i = 0; i < turnsCount; i++) {
    const id = `T_prior_${i}`;
    session.conversation.startTurn({ id, prompt: `prior ${i}`, citedContext: {} });
    session.conversation.appendAssistant(id, fakeAssistant(makeFakeModel(), `reply ${i}`));
    session.conversation.markDone(id);
  }
  return { manager, session, sessionId: session.id };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test("auto-compact runs at runTurn entry when remaining context is below threshold and rewrites the conversation before the first round", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, session, sessionId } = makeSessionWithHistory(3);
  registerAgentHandlers(dispatcher, { manager });

  // Push the running estimate near the ceiling so the next turn's
  // remaining context (= contextWindow - lastTotalTokens = 100K - 90K =
  // 10K) lands under the 20K threshold.
  session.conversation.recordTotalTokens(90_000);

  // Round 1 (compact summarizer) — must not run a tool, must produce text.
  scriptedRounds.push(emitTextStream("Intent: X. Progress: Y. Current: Z. Anchors: foo."));
  // Round 2 (post-compact main turn) — terminal text reply.
  scriptedRounds.push(emitTextStream("ack"));

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.submit",
    params: { sessionId, turnId: "T_active", prompt: "go", citedContext: {} },
  });
  await flush();

  // Two LLM calls landed: the summarizer + the post-compact main round.
  expect(providerCalls).toHaveLength(2);
  const [compactCall, mainCall] = providerCalls;
  expect(compactCall.toolsArg).toBeUndefined();
  expect(compactCall.systemPrompt).toContain("Respond with TEXT ONLY");

  // The MAIN call's messages must be the post-compact shape:
  //   [boundary, summary, activeTurnUserPrompt(, ambientTail?)].
  const mainMsgs = mainCall.messages;
  expect(mainMsgs[0].content).toContain("<compactionBoundary");
  expect(mainMsgs[1].content).toContain("[Compressed]");
  expect(mainMsgs[1].content).toContain("Intent: X");
  // The active turn's user prompt is preserved.
  const activePrompt = mainMsgs.find(
    (m: any) => typeof m.content === "string" && m.content.includes("go"),
  );
  expect(activePrompt).toBeDefined();
  // No "prior 0..2" content survives in the model's view.
  for (const m of mainMsgs) {
    if (typeof m.content === "string") {
      expect(m.content).not.toMatch(/prior \d/);
    }
  }

  // ui.compact lifecycle notifications fired in order: started → done.
  const compactNotes = captured.notifications.filter((n) => n.method === "ui.compact");
  expect(compactNotes.map((n) => n.params.phase)).toEqual(["started", "done"]);

  // Conversation state is the post-compact shape as well.
  expect(session.conversation.turns).toHaveLength(1);
  expect(session.conversation.turns[0]!.id).toBe("T_active");
});

test("queued submit during auto-compact waits for the active turn's first reply", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, session, sessionId } = makeSessionWithHistory(3);
  registerAgentHandlers(dispatcher, { manager });
  session.conversation.recordTotalTokens(90_000);

  let finishCompact: () => void = () => {};
  scriptedRounds.push((model) => {
    const s = new AssistantMessageEventStream();
    queueMicrotask(() => {
      finishCompact = () => {
        const msg = fakeAssistant(model, "Intent: active. Progress: compacted.");
        s.push({ type: "text_delta", contentIndex: 0, delta: "Intent: active. Progress: compacted.", partial: msg });
        s.push({ type: "done", reason: "stop", message: msg });
        s.end();
      };
    });
    return s;
  });
  scriptedRounds.push(emitTextStream("active reply"));
  scriptedRounds.push(emitTextStream("queued reply"));

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.submit",
    params: { sessionId, turnId: "T_active", prompt: "first prompt", citedContext: {} },
  });
  await flush(40);
  pushInbound({
    jsonrpc: "2.0",
    id: 2,
    method: "agent.submit",
    params: { sessionId, turnId: "T_queued", prompt: "second prompt", citedContext: {} },
  });
  await flush(40);

  expect(captured.notifications.filter((n) => n.method === "conversation.turnStarted").map((n) => n.params.turn.id)).toEqual([
    "T_active",
  ]);
  expect(providerCalls).toHaveLength(1);

  finishCompact();
  await flush(160);

  expect(captured.notifications.filter((n) => n.method === "conversation.turnStarted").map((n) => n.params.turn.id)).toEqual([
    "T_active",
    "T_queued",
  ]);
  expect(session.conversation.turns.map((t) => [t.id, t.reply, t.status])).toEqual([
    ["T_active", "active reply", "done"],
    ["T_queued", "queued reply", "done"],
  ]);
});

test("auto-compact does not run when remaining context is comfortably above threshold", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, sessionId } = makeSessionWithHistory(3);
  registerAgentHandlers(dispatcher, { manager });

  // No recordTotalTokens call → lastTotalTokens stays 0 → remaining = 100K.

  scriptedRounds.push(emitTextStream("ok"));

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.submit",
    params: { sessionId, turnId: "T_active", prompt: "go", citedContext: {} },
  });
  await flush();

  // Only the main round ran — no summarization call.
  expect(providerCalls).toHaveLength(1);
  // No ui.compact at all — `started` only fires when compaction actually
  // begins (post-gating), so a skipped turn is wire-silent on this method.
  // This pairs every `started` with a matching `done`/`failed`.
  const compactNotes = captured.notifications.filter((n) => n.method === "ui.compact");
  expect(compactNotes).toEqual([]);
});

test("auto-compact failure surfaces ui.compact failed and leaves the conversation untouched", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, session, sessionId } = makeSessionWithHistory(2);
  registerAgentHandlers(dispatcher, { manager });
  session.conversation.recordTotalTokens(95_000);

  // Round 1 (summarizer) — emit an error event.
  scriptedRounds.push((model) => {
    const s = new AssistantMessageEventStream();
    queueMicrotask(() => {
      s.push({
        type: "error",
        reason: "error",
        error: {
          role: "assistant",
          content: [],
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
          stopReason: "error",
          errorMessage: "kaboom",
          timestamp: Date.now(),
        },
      });
      s.end();
    });
    return s;
  });
  // Round 2 (main turn) — must still proceed with the ORIGINAL (oversized)
  // history even though compact failed.
  scriptedRounds.push(emitTextStream("ack"));

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.submit",
    params: { sessionId, turnId: "T_active", prompt: "go", citedContext: {} },
  });
  await flush();

  expect(providerCalls).toHaveLength(2);
  const compactNotes = captured.notifications.filter((n) => n.method === "ui.compact");
  expect(compactNotes.map((n) => n.params.phase)).toEqual(["started", "failed"]);
  expect(typeof compactNotes[1]!.params.errorMessage).toBe("string");

  // Conversation: 3 turns survive (2 prior + 1 active). Compact left state
  // alone on failure.
  expect(session.conversation.turns).toHaveLength(3);
});

test("after a successful compact, the next round still receives the ambient todos block", async () => {
  ambientRegistry.register(todosAmbientProvider);

  const { dispatcher, pushInbound } = makeCapturingDispatcher();
  const { manager, session, sessionId } = makeSessionWithHistory(2);
  registerAgentHandlers(dispatcher, { manager });
  session.conversation.recordTotalTokens(95_000);
  session.todos.update([{ id: "1", text: "post-compact step", status: "in_progress" }]);

  scriptedRounds.push(emitTextStream("Summary text."));
  scriptedRounds.push(emitTextStream("ack"));

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.submit",
    params: { sessionId, turnId: "T_active", prompt: "go", citedContext: {} },
  });
  await flush();

  const mainCall = providerCalls[1]!;
  // The very last message in the post-compact request is the ambient
  // tail — proves ambient survives the rewrite and re-attaches every
  // round, no manual re-injection needed.
  const last = mainCall.messages[mainCall.messages.length - 1];
  expect(last.role).toBe("user");
  expect(typeof last.content).toBe("string");
  expect(last.content).toContain("<ambient>");
  expect(last.content).toContain("post-compact step");
});

test("agent.reset clears the compact breaker so a fresh session starts unobstructed", async () => {
  const { dispatcher, pushInbound } = makeCapturingDispatcher();
  const { manager, session, sessionId } = makeSessionWithHistory(2);
  registerAgentHandlers(dispatcher, { manager });
  session.conversation.recordTotalTokens(95_000);

  // Trip the breaker with three failing summarizer calls.
  for (let i = 0; i < 3; i++) {
    scriptedRounds.push((model) => {
      const s = new AssistantMessageEventStream();
      queueMicrotask(() => {
        s.push({
          type: "error",
          reason: "error",
          error: {
            role: "assistant",
            content: [],
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
            stopReason: "error",
            errorMessage: "n/a",
            timestamp: Date.now(),
          },
        });
        s.end();
      });
      return s;
    });
    // Each main turn after a failed summarizer.
    scriptedRounds.push(emitTextStream("ack"));
  }

  // Three separate turns, each crossing the threshold, each tripping a
  // failure. Different turnIds so the single-active-turn invariant
  // doesn't reject the resubmissions. After each turn, the fake
  // provider's main reply reports `usage.input = 0`, which the loop
  // dutifully records — so we re-inflate `lastTotalTokens` back to a
  // threshold-tripping figure before the next submit, otherwise turn 2
  // and 3 would skip compact altogether.
  for (let i = 0; i < 3; i++) {
    session.conversation.recordTotalTokens(95_000);
    pushInbound({
      jsonrpc: "2.0",
      id: i + 1,
      method: "agent.submit",
      params: { sessionId, turnId: `T_a${i}`, prompt: `go ${i}`, citedContext: {} },
    });
    await flush();
  }

  expect(compactBreaker.isAutoDisabled(sessionId)).toBe(true);

  // Reset wipes the breaker.
  pushInbound({
    jsonrpc: "2.0",
    id: 99,
    method: "agent.reset",
    params: { sessionId },
  });
  await flush();
  expect(compactBreaker.isAutoDisabled(sessionId)).toBe(false);
});

// ---------------------------------------------------------------------------
// Manual compact (agent.compact)
// ---------------------------------------------------------------------------

test("agent.compact: manual entry runs compact, emits ui.compact lifecycle, and returns compactedTurnCount", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, sessionId } = makeSessionWithHistory(3);
  registerAgentHandlers(dispatcher, { manager });

  // Summarizer round.
  scriptedRounds.push(emitTextStream("Intent: A. Progress: B. Current: C. Anchors: D."));

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.compact",
    params: { sessionId },
  });
  await flush();

  // Exactly one summarizer LLM call landed.
  expect(providerCalls).toHaveLength(1);
  // Lifecycle: started → done with compactedTurnCount, both with empty turnId.
  const phases = captured.notifications
    .filter((n) => n.method === "ui.compact")
    .map((n) => ({ phase: n.params.phase, turnId: n.params.turnId, n: n.params.compactedTurnCount }));
  expect(phases).toEqual([
    { phase: "started", turnId: "", n: undefined },
    // Manual compact folds EVERY turn (3) — the auto-path's "preserve
    // active turn" semantics don't apply when the user explicitly
    // requests a compact pass from idle.
    { phase: "done", turnId: "", n: 3 },
  ]);
});

test("agent.compact: rejects when a turn is in flight on the session", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, sessionId } = makeSessionWithHistory(2);
  registerAgentHandlers(dispatcher, { manager });

  // Long-running first turn — never completes during this test.
  scriptedRounds.push((model) => {
    const s = new AssistantMessageEventStream();
    // Deliberately never emit `done` — this turn stays in flight.
    return s;
  });

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.submit",
    params: { sessionId, turnId: "T_busy", prompt: "go", citedContext: {} },
  });
  await flush();

  // Now try a manual compact — must be refused.
  pushInbound({
    jsonrpc: "2.0",
    id: 2,
    method: "agent.compact",
    params: { sessionId },
  });
  await flush();

  // Exactly the main turn's stream call landed; no summarizer call.
  expect(providerCalls).toHaveLength(1);
  // No ui.compact emitted — the handler bails before lifecycle frames.
  expect(captured.notifications.filter((n) => n.method === "ui.compact")).toEqual([]);
});

test("agent.compact: rejects a second compact while manual compact is running", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, sessionId } = makeSessionWithHistory(2);
  registerAgentHandlers(dispatcher, { manager });

  scriptedRounds.push(() => new AssistantMessageEventStream());

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.compact",
    params: { sessionId },
  });
  await flush(40);

  pushInbound({
    jsonrpc: "2.0",
    id: 2,
    method: "agent.compact",
    params: { sessionId },
  });
  await flush(40);

  expect(providerCalls).toHaveLength(1);
  expect(captured.notifications.filter((n) => n.method === "ui.compact").map((n) => n.params.phase)).toEqual([
    "started",
  ]);
  const second = captured.responses.find((r) => r.id === 2);
  expect(second?.error?.message).toContain("already compacting");
});

test("agent.cancel interrupts a running manual compact", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, session } = makeSessionWithHistory(2);
  const sessionId = session.id;
  registerAgentHandlers(dispatcher, { manager });

  let abortFired = false;
  scriptedRounds.push((model, signal) => {
    const s = new AssistantMessageEventStream();
    signal?.addEventListener(
      "abort",
      () => {
        abortFired = true;
        s.push({ type: "error", reason: "error", error: fakeAssistant(model, "compact cancelled") });
        s.end();
      },
      { once: true },
    );
    return s;
  });

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.compact",
    params: { sessionId },
  });
  await flush(40);

  pushInbound({
    jsonrpc: "2.0",
    id: 2,
    method: "agent.cancel",
    params: { sessionId, turnId: "" },
  });
  await flush(120);

  expect(abortFired).toBe(true);
  expect(session.isCompacting).toBe(false);
  expect(captured.responses.find((r) => r.id === 2)?.result).toEqual({ cancelled: true });
  expect(captured.responses.find((r) => r.id === 1)?.result).toEqual({ ok: false });
  expect(captured.notifications.filter((n) => n.method === "ui.compact").map((n) => n.params.phase)).toEqual([
    "started",
    "failed",
  ]);
});

test("agent.submit during manual compact waits until compact finishes before starting the turn", async () => {
  const { dispatcher, captured, pushInbound } = makeCapturingDispatcher();
  const { manager, session, sessionId } = makeSessionWithHistory(2);
  registerAgentHandlers(dispatcher, { manager });

  let finishCompact: () => void = () => {};
  scriptedRounds.push((model) => {
    const s = new AssistantMessageEventStream();
    queueMicrotask(() => {
      finishCompact = () => {
        const msg = fakeAssistant(model, "manual summary");
        s.push({ type: "text_delta", contentIndex: 0, delta: "manual summary", partial: msg });
        s.push({ type: "done", reason: "stop", message: msg });
        s.end();
      };
    });
    return s;
  });
  scriptedRounds.push(emitTextStream("queued reply"));

  pushInbound({
    jsonrpc: "2.0",
    id: 1,
    method: "agent.compact",
    params: { sessionId },
  });
  await flush(40);
  pushInbound({
    jsonrpc: "2.0",
    id: 2,
    method: "agent.submit",
    params: { sessionId, turnId: "T_after_compact", prompt: "continue after compact", citedContext: {} },
  });
  await flush(40);

  expect(captured.notifications.filter((n) => n.method === "conversation.turnStarted")).toEqual([]);
  expect(providerCalls).toHaveLength(1);

  finishCompact();
  await flush(120);

  const compactPhases = captured.notifications
    .filter((n) => n.method === "ui.compact")
    .map((n) => n.params.phase);
  expect(compactPhases).toEqual(["started", "done"]);
  const started = captured.notifications.filter((n) => n.method === "conversation.turnStarted");
  expect(started).toHaveLength(1);
  expect(started[0].params.turn).toMatchObject({
    id: "T_after_compact",
    prompt: "continue after compact",
  });
  expect(providerCalls).toHaveLength(2);
  expect(session.conversation.turns.map((t) => [t.id, t.status])).toEqual([
    ["T_after_compact", "done"],
  ]);
});
