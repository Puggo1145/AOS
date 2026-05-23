// Compact manager — pure unit tests, no agent loop, no RPC.
//
// Pins the contract of `compactConversation` and `autoCompactIfNeeded`:
//   - The summarization stream is invoked with NO tools and the compact
//     system prompt.
//   - Only messages strictly preceding the active turn are sent for
//     summarization; the active turn's slice is preserved verbatim and
//     re-anchored on top of the summary.
//   - `Conversation.compact` lays out `[boundary, summary, ...slice]` and
//     prunes `_turns` down to the active turn.
//   - The auto-path threshold (`AUTO_COMPACT_REMAINING_THRESHOLD`)
//     decides whether `autoCompactIfNeeded` runs.
//   - The breaker trips after `COMPACT_FAILURE_LIMIT` consecutive
//     failures and silently no-ops every subsequent auto attempt.

import { test, expect, beforeEach, afterEach } from "bun:test";
import { SessionManager } from "../src/agent/session/manager";
import {
  compactConversation,
  autoCompactIfNeeded,
  AUTO_COMPACT_REMAINING_THRESHOLD,
  compactBreaker,
  COMPACT_FAILURE_LIMIT,
  COMPACT_SYSTEM_PROMPT,
} from "../src/agent/compact";
import {
  registerApiProvider,
  unregisterApiProviders,
  type Model,
  type Api,
  type AssistantMessage,
} from "../src/llm";
import { AssistantMessageEventStream } from "../src/llm/utils/event-stream";

const FAKE_SOURCE_ID = "test-compact-manager";

function makeFakeModel(contextWindow: number): Model<Api> {
  return {
    id: "fake-compact-model",
    name: "Fake",
    api: "openai-responses",
    provider: "test",
    baseUrl: "",
    reasoning: false,
    input: ["text"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow,
    maxTokens: 1_000,
  };
}

function fakeAssistant(
  model: Model<Api>,
  text: string,
): AssistantMessage {
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
    stopReason: "stop",
    timestamp: Date.now(),
  };
}

interface Capture {
  systemPrompts: string[];
  messageBatches: any[][];
  toolsArgs: unknown[];
}

let capture: Capture;
let summaryText: string | null;
let throwError: Error | null;

beforeEach(() => {
  capture = { systemPrompts: [], messageBatches: [], toolsArgs: [] };
  summaryText = "Intent: do X. Progress: did Y. Current: Z. Anchors: file.ts.";
  throwError = null;
  registerApiProvider({
    api: "openai-responses",
    sourceId: FAKE_SOURCE_ID,
    stream: (model, ctx) => {
      capture.systemPrompts.push(ctx.systemPrompt ?? "");
      capture.messageBatches.push(ctx.messages.map((m) => ({ ...m })));
      capture.toolsArgs.push(ctx.tools);
      const stream = new AssistantMessageEventStream();
      queueMicrotask(() => {
        if (throwError) {
          stream.push({
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
              errorMessage: throwError.message,
              timestamp: Date.now(),
            },
          });
        } else if (summaryText !== null) {
          stream.push({ type: "done", reason: "stop", message: fakeAssistant(model, summaryText) });
        }
        stream.end();
      });
      return stream;
    },
  });
  compactBreaker.clear();
});

afterEach(() => {
  unregisterApiProviders(FAKE_SOURCE_ID);
  compactBreaker.clear();
});

// ---------------------------------------------------------------------------
// Helpers — bring a session to a state with N prior turns + 1 active turn.
// ---------------------------------------------------------------------------

function seedSessionWithHistory(turnsCount: number): {
  session: ReturnType<SessionManager["create"]>;
  manager: SessionManager;
  activeTurnId: string;
} {
  const manager = new SessionManager();
  const session = manager.create();
  for (let i = 0; i < turnsCount; i++) {
    const id = `T_prior_${i}`;
    session.conversation.startTurn({ id, prompt: `prior ${i}`, citedContext: {} });
    // Mark each prior turn done with a synthetic assistant message so it
    // contributes a stable two-message slice.
    session.conversation.appendAssistant(id, fakeAssistant(makeFakeModel(100_000), `reply ${i}`));
    session.conversation.markDone(id);
  }
  const activeTurnId = "T_active";
  session.conversation.startTurn({ id: activeTurnId, prompt: "active", citedContext: {} });
  return { session, manager, activeTurnId };
}

// ---------------------------------------------------------------------------
// compactConversation core
// ---------------------------------------------------------------------------

test("compactConversation: invokes the LLM with NO tools and the compact system prompt", async () => {
  const { session } = seedSessionWithHistory(2);
  const model = makeFakeModel(100_000);
  await compactConversation(session, model);
  expect(capture.systemPrompts).toEqual([COMPACT_SYSTEM_PROMPT]);
  // tools must be undefined: the prompt forbids them, and we also do not
  // hand the spec list down — defense in depth.
  expect(capture.toolsArgs).toEqual([undefined]);
});

test("compactConversation: only sends prior history (not the active turn) to the summarizer", async () => {
  const { session } = seedSessionWithHistory(2);
  const model = makeFakeModel(100_000);
  await compactConversation(session, model);
  expect(capture.messageBatches).toHaveLength(1);
  const batch = capture.messageBatches[0]!;
  // The summarization input is `[...priorMessages, finalNudge]`. With
  // 2 prior turns and one user+assistant pair each = 4 messages, plus
  // the trailing nudge = 5.
  expect(batch).toHaveLength(5);
  // Active turn's prompt ("active") must NOT appear in the input.
  for (const m of batch) {
    if (typeof m.content === "string") {
      expect(m.content).not.toContain("active");
    }
  }
  // The trailing message is the final-request nudge — a user message.
  expect(batch[batch.length - 1].role).toBe("user");
});

test("Conversation exposes active-turn compaction input without leaking message ranges", () => {
  const { session, activeTurnId } = seedSessionWithHistory(2);

  const input = session.conversation.activeTurnCompactionInput();

  expect(input).not.toBeNull();
  expect(input!.activeTurnId).toBe(activeTurnId);
  expect(input!.priorMessages.map((m) => m.role)).toEqual([
    "user",
    "assistant",
    "user",
    "assistant",
  ]);
  for (const message of input!.priorMessages) {
    if (typeof message.content === "string") {
      expect(message.content).not.toContain("active");
    }
  }
});

test("Conversation treats a manual compact preface as active-turn compaction input", () => {
  const manager = new SessionManager();
  const session = manager.create();

  session.conversation.startTurn({ id: "T1", prompt: "older request", citedContext: {} });
  session.conversation.appendAssistant("T1", fakeAssistant(makeFakeModel(100_000), "older reply"));
  session.conversation.markDone("T1");
  session.conversation.compactAll("manual summary");
  session.conversation.startTurn({ id: "T2", prompt: "fresh request", citedContext: {} });

  const input = session.conversation.activeTurnCompactionInput();

  expect(input).not.toBeNull();
  expect(input!.activeTurnId).toBe("T2");
  expect(input!.priorMessages).toHaveLength(2);
  expect(input!.priorMessages[0]!.role).toBe("user");
  expect((input!.priorMessages[0] as any).content).toContain("<compactionBoundary");
  expect((input!.priorMessages[1] as any).content).toContain("[Compressed]");
  expect((input!.priorMessages[1] as any).content).toContain("manual summary");
});

test("compactConversation: result lays out [boundary, summary, ...activeSlice] and re-anchors the active turn", async () => {
  const { session, activeTurnId } = seedSessionWithHistory(3);
  const model = makeFakeModel(100_000);

  const result = await compactConversation(session, model);
  if (typeof result === "symbol") throw new Error("expected CompactResult, got noop sentinel");
  expect(result.compactedTurnCount).toBe(3);
  expect(result.summary.length).toBeGreaterThan(0);

  const msgs = session.conversation.messages;
  expect(msgs).toHaveLength(3);
  expect(msgs[0].role).toBe("user");
  expect(typeof (msgs[0] as any).content).toBe("string");
  expect((msgs[0] as any).content).toContain("<compactionBoundary");
  expect((msgs[0] as any).content).toContain('turns="3"');
  expect((msgs[1] as any).content).toContain("[Compressed]");
  expect((msgs[1] as any).content).toContain(result.summary);

  const turns = session.conversation.turns;
  expect(turns).toHaveLength(1);
  expect(turns[0]!.id).toBe(activeTurnId);
  expect(session.conversation.llmMessages().map((m) => m.role)).toEqual([
    "user",
    "user",
    "user",
  ]);
  expect((session.conversation.llmMessages()[2] as any).content).toContain("active");
});

test("compactConversation: throws when there is no prior history to summarize", async () => {
  const manager = new SessionManager();
  const session = manager.create();
  session.conversation.startTurn({ id: "T1", prompt: "hi", citedContext: {} });
  const model = makeFakeModel(100_000);
  await expect(compactConversation(session, model)).rejects.toThrow(/no prior history/);
});

test("compactConversation: surfaces stream errors as thrown exceptions", async () => {
  const { session } = seedSessionWithHistory(2);
  throwError = new Error("upstream is grumpy");
  const model = makeFakeModel(100_000);
  await expect(compactConversation(session, model)).rejects.toThrow(/grumpy/);
  // Conversation must be untouched on failure — the user can still see
  // their original history and the next turn proceeds with it.
  expect(session.conversation.turns).toHaveLength(3);
});

test("compactConversation: throws when the model returns no usable text", async () => {
  const { session } = seedSessionWithHistory(2);
  summaryText = "";
  const model = makeFakeModel(100_000);
  await expect(compactConversation(session, model)).rejects.toThrow(/no summary text/);
});

// ---------------------------------------------------------------------------
// autoCompactIfNeeded: threshold gating + breaker
// ---------------------------------------------------------------------------

test("autoCompactIfNeeded: skips when remaining context is comfortably above threshold", async () => {
  const { session } = seedSessionWithHistory(2);
  // 100K window, 0 input tokens recorded → remaining = 100K, way above 20K.
  const model = makeFakeModel(100_000);
  const ran = await autoCompactIfNeeded(session, model);
  expect(ran).toBeNull();
  expect(capture.messageBatches).toHaveLength(0);
});

test("autoCompactIfNeeded: runs when remaining context drops under the threshold", async () => {
  const { session } = seedSessionWithHistory(2);
  const model = makeFakeModel(100_000);
  // Remaining = 100K - 90K = 10K, below 20K → compact.
  session.conversation.recordTotalTokens(90_000);
  const ran = await autoCompactIfNeeded(session, model);
  expect(ran).not.toBeNull();
  expect(ran!.compactedTurnCount).toBe(2);
  expect(capture.messageBatches).toHaveLength(1);
  expect(session.conversation.turns).toHaveLength(1);
});

test("autoCompactIfNeeded: skips on first turn even if remaining context is tiny", async () => {
  // Active turn is the first turn — no prior history to summarize. The
  // threshold check is satisfied (remaining tiny) but the wrapper must
  // still short-circuit cleanly.
  const manager = new SessionManager();
  const session = manager.create();
  session.conversation.startTurn({ id: "T1", prompt: "hi", citedContext: {} });
  session.conversation.recordTotalTokens(99_000);
  const model = makeFakeModel(100_000);
  const ran = await autoCompactIfNeeded(session, model);
  expect(ran).toBeNull();
});

test("autoCompactIfNeeded: trips the breaker after consecutive failures and silently no-ops thereafter", async () => {
  const { session } = seedSessionWithHistory(2);
  const model = makeFakeModel(100_000);
  session.conversation.recordTotalTokens(95_000);
  throwError = new Error("LLM nope");

  // First N failures: each call propagates the error and increments the
  // breaker. After the limit, further calls must no-op (return false)
  // without firing a stream call.
  for (let i = 0; i < COMPACT_FAILURE_LIMIT; i++) {
    await expect(autoCompactIfNeeded(session, model)).rejects.toThrow(/nope/);
  }
  expect(compactBreaker.isAutoDisabled(session.id)).toBe(true);
  expect(capture.messageBatches).toHaveLength(COMPACT_FAILURE_LIMIT);

  // Next attempt — even though the threshold is still tripped — must
  // be silently skipped.
  const ran = await autoCompactIfNeeded(session, model);
  expect(ran).toBeNull();
  expect(capture.messageBatches).toHaveLength(COMPACT_FAILURE_LIMIT);
});

test("autoCompactIfNeeded: a successful run zeroes the breaker counter", async () => {
  const { session } = seedSessionWithHistory(2);
  const model = makeFakeModel(100_000);
  session.conversation.recordTotalTokens(95_000);

  throwError = new Error("flake");
  await expect(autoCompactIfNeeded(session, model)).rejects.toThrow();
  expect(compactBreaker.inspect(session.id).consecutiveFailures).toBe(1);

  throwError = null;
  await autoCompactIfNeeded(session, model);
  expect(compactBreaker.inspect(session.id).consecutiveFailures).toBe(0);
});

test("AUTO_COMPACT_REMAINING_THRESHOLD is the documented 20K", () => {
  // Pin the contract — changing this number is a behavior change worth a
  // PR review, not a silent tweak.
  expect(AUTO_COMPACT_REMAINING_THRESHOLD).toBe(20_000);
});
