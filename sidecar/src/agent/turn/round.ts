// Agent Turn round execution.
//
// `runTurn` owns the outer Agent Turn lifecycle: submit/compact/steer/final
// cleanup. This module owns one model round inside that lifecycle: prompt
// assembly, stream event application, tool replayability, and the matching
// wire projection.

import {
  streamSimple,
  isContextOverflow,
  type Api,
  type AssistantMessage,
  type Message,
  type Model,
  type Tool,
  type ToolCall,
  type ToolResultMessage,
} from "../../llm";
import { logger } from "../../log";
import { Dispatcher } from "../../rpc/dispatcher";
import { RPCErrorCode, RPCMethod, type JSONValue } from "../../rpc/rpc-types";
import { Conversation } from "../conversation";
import { ContextObserver } from "../context-observer";
import { Session } from "../session/session";
import type { ToolExecResult, ToolHandler } from "../tools";
import { buildOutboundMessages, publishTurnContext } from "./outbound";
import {
  assistantSpoke,
  extractToolCalls,
  prepareToolCall,
  renderToolResultForWire,
  runTool,
  type ToolCallOutcome,
} from "./tool-dispatch";

export type AgentRoundOutcome =
  | { kind: "continue"; consecutiveSilentToolRounds: number }
  | { kind: "done"; markedDone: boolean; consecutiveSilentToolRounds: number }
  | { kind: "terminal"; dropQueuedSteer: boolean; consecutiveSilentToolRounds: number };

export interface AgentRoundRunnerOptions {
  dispatcher: Dispatcher;
  conversation: Conversation;
  session: Session;
  model: Model<Api>;
  effort: string | undefined;
  systemPrompt: string;
  observer: ContextObserver;
  toolSpecs: Tool[];
  toolByName: ReadonlyMap<string, ToolHandler<any, any>>;
  maxConsecutiveSilentToolRounds: number;
}

export function pickErrorCode(msg: AssistantMessage): number {
  if (msg.errorReason === "authInvalidated") return RPCErrorCode.permissionDenied;
  return RPCErrorCode.internalError;
}

export class AgentRoundRunner {
  private thinkingOpen = false;

  constructor(private readonly options: AgentRoundRunnerOptions) {}

  async run(input: {
    turnId: string;
    signal: AbortSignal;
    consecutiveSilentToolRounds: number;
  }): Promise<AgentRoundOutcome> {
    const { dispatcher, conversation: convo, session, model, effort, systemPrompt, toolSpecs } = this.options;
    const sessionId = session.id;
    const turnId = input.turnId;
    let consecutiveSilentToolRounds = input.consecutiveSilentToolRounds;

    const messagesForRound = buildOutboundMessages(convo, session);
    this.publishContext(turnId, messagesForRound);

    const eventStream = streamSimple(
      model,
      {
        systemPrompt,
        messages: messagesForRound,
        tools: toolSpecs.length > 0 ? toolSpecs : undefined,
      },
      { signal: input.signal, reasoning: effort },
    );

    const callOutcomes = new Map<string, ToolCallOutcome>();
    let final: AssistantMessage | undefined;
    let bailed = false;
    for await (const ev of eventStream) {
      if (input.signal.aborted) {
        bailed = true;
        break;
      }
      if (ev.type === "thinking_delta") {
        this.thinkingOpen = true;
        dispatcher.notify(RPCMethod.uiThinking, {
          sessionId,
          turnId,
          kind: "delta",
          delta: ev.delta,
        });
      } else if (ev.type === "thinking_end") {
        this.closeThinkingIfOpen(turnId);
      } else if (ev.type === "text_delta") {
        if (convo.appendDelta(turnId, ev.delta)) {
          dispatcher.notify(RPCMethod.uiToken, { sessionId, turnId, delta: ev.delta });
        }
      } else if (ev.type === "toolcall_end") {
        this.recordToolCallOutcome(turnId, ev.toolCall, callOutcomes);
      } else if (ev.type === "done") {
        final = ev.message;
      } else if (ev.type === "error") {
        const code = pickErrorCode(ev.error);
        const message = ev.error.errorMessage ?? "agent error";
        this.closeThinkingIfOpen(turnId);
        if (convo.setError(turnId, code, message)) {
          dispatcher.notify(RPCMethod.uiError, { sessionId, turnId, code, message });
          if (ev.error.errorReason === "authInvalidated" && ev.error.errorProviderId) {
            dispatcher.notify(RPCMethod.providerStatusChanged, {
              providerId: ev.error.errorProviderId,
              state: "unauthenticated",
              reason: "authInvalidated",
              message,
            });
          }
        }
        return { kind: "terminal", dropQueuedSteer: true, consecutiveSilentToolRounds };
      }
    }

    if (bailed || input.signal.aborted) {
      this.closeThinkingIfOpen(turnId);
      convo.finalizeCancellation(turnId);
      dispatcher.notify(RPCMethod.uiStatus, { sessionId, turnId, status: "done" });
      return { kind: "terminal", dropQueuedSteer: true, consecutiveSilentToolRounds };
    }

    if (!final) {
      this.closeThinkingIfOpen(turnId);
      const message = "stream ended without a final assistant message";
      if (convo.setError(turnId, RPCErrorCode.internalError, message)) {
        dispatcher.notify(RPCMethod.uiError, {
          sessionId,
          turnId,
          code: RPCErrorCode.internalError,
          message,
        });
      }
      return { kind: "terminal", dropQueuedSteer: true, consecutiveSilentToolRounds };
    }

    if (isContextOverflow(final, model.contextWindow)) {
      this.closeThinkingIfOpen(turnId);
      if (convo.setError(turnId, RPCErrorCode.agentContextOverflow, "Context too long")) {
        dispatcher.notify(RPCMethod.uiError, {
          sessionId,
          turnId,
          code: RPCErrorCode.agentContextOverflow,
          message: "Context too long",
        });
      }
      return { kind: "terminal", dropQueuedSteer: true, consecutiveSilentToolRounds };
    }

    if (!convo.appendAssistantRound(turnId, final)) {
      return { kind: "terminal", dropQueuedSteer: true, consecutiveSilentToolRounds };
    }

    dispatcher.notify(RPCMethod.uiUsage, {
      sessionId,
      turnId,
      inputTokens: final.usage.input,
      outputTokens: final.usage.output,
      cacheReadTokens: final.usage.cacheRead,
      cacheWriteTokens: final.usage.cacheWrite,
      totalTokens: final.usage.totalTokens,
      contextWindow: model.contextWindow,
      modelId: model.id,
    });

    const toolCalls = extractToolCalls(final);

    if (toolCalls.length === 0) {
      if (session.computerUseAppSession) {
        await dispatcher.request(
          RPCMethod.computerUseStopAppSession,
          { pid: session.computerUseAppSession.pid },
        );
        session.clearComputerUseAppSession();
      }
      const markedDone = convo.markDone(turnId);
      this.publishContext(turnId, buildOutboundMessages(convo, session));
      this.closeThinkingIfOpen(turnId);
      dispatcher.notify(RPCMethod.uiStatus, { sessionId, turnId, status: "done" });
      return { kind: "done", markedDone, consecutiveSilentToolRounds };
    }

    const spokeThisRound = assistantSpoke(final);
    if (spokeThisRound) {
      consecutiveSilentToolRounds = 0;
    } else {
      consecutiveSilentToolRounds++;
    }
    session.setSilentToolRounds(consecutiveSilentToolRounds);
    if (consecutiveSilentToolRounds > this.options.maxConsecutiveSilentToolRounds) {
      this.closeThinkingIfOpen(turnId);
      return this.failToolBudget(turnId, toolCalls, callOutcomes, consecutiveSilentToolRounds);
    }

    this.closeThinkingIfOpen(turnId);
    convo.setStatus(turnId, "waiting");
    dispatcher.notify(RPCMethod.uiStatus, { sessionId, turnId, status: "waiting" });

    for (const tc of toolCalls) {
      if (input.signal.aborted) break;
      const outcome = callOutcomes.get(tc.id) ?? {
        kind: "rejected" as const,
        errorMessage: `internal: missing call outcome for ${tc.id}`,
      };
      let result: ToolExecResult;
      if (outcome.kind === "rejected") {
        result = {
          content: [{ type: "text", text: outcome.errorMessage }],
          isError: true,
        };
      } else {
        try {
          result = await runTool(outcome.handler, outcome.args, tc.name, {
            sessionId,
            turnId,
            toolCallId: tc.id,
            model,
            computerUseAppSession: session.computerUseAppSession,
            computerUseStateCache: session.computerUseStateCache,
            signal: input.signal,
          });
        } catch (err) {
          const message = err instanceof Error ? err.message : String(err);
          logger.error("tool execution threw", {
            sessionId,
            turnId,
            toolCallId: tc.id,
            toolName: tc.name,
            err: String(err),
          });
          result = {
            content: [{ type: "text", text: `Tool "${tc.name}" failed: ${message}` }],
            isError: true,
          };
        }
      }
      const toolResultMsg: ToolResultMessage = {
        role: "toolResult",
        toolCallId: tc.id,
        toolName: tc.name,
        content: result.content,
        isError: result.isError,
        timestamp: Date.now(),
      };
      if (!convo.appendToolResult(turnId, toolResultMsg)) {
        return { kind: "terminal", dropQueuedSteer: true, consecutiveSilentToolRounds };
      }
      if (outcome.kind === "ready") {
        dispatcher.notify(RPCMethod.uiToolCall, {
          sessionId,
          turnId,
          phase: "result",
          toolCallId: tc.id,
          toolName: tc.name,
          isError: result.isError,
          outputText: renderToolResultForWire(result.content),
        });
        if (!result.isError && tc.name === "start_app_session") {
          session.setComputerUseAppSession({
            pid: outcome.args.pid as number,
            windowId: outcome.args.windowId as number,
          });
        } else if (!result.isError && tc.name === "stop_app_session") {
          session.clearComputerUseAppSession();
        }
      }
    }

    if (input.signal.aborted) {
      convo.finalizeCancellation(turnId);
      dispatcher.notify(RPCMethod.uiStatus, { sessionId, turnId, status: "done" });
      return { kind: "terminal", dropQueuedSteer: true, consecutiveSilentToolRounds };
    }

    return { kind: "continue", consecutiveSilentToolRounds };
  }

  resumeWorking(turnId: string): void {
    this.options.conversation.setStatus(turnId, "working");
    this.options.dispatcher.notify(RPCMethod.uiStatus, {
      sessionId: this.options.session.id,
      turnId,
      status: "working",
    });
  }

  closeThinkingIfOpen(turnId: string): void {
    if (!this.thinkingOpen) return;
    this.thinkingOpen = false;
    this.options.dispatcher.notify(RPCMethod.uiThinking, {
      sessionId: this.options.session.id,
      turnId,
      kind: "end",
    });
  }

  private publishContext(turnId: string, messages: Message[]): void {
    const { observer, session, model, effort, systemPrompt } = this.options;
    publishTurnContext({
      observer,
      sessionId: session.id,
      turnId,
      model,
      effort,
      systemPrompt,
      messages,
    });
  }

  private recordToolCallOutcome(
    turnId: string,
    toolCall: ToolCall,
    callOutcomes: Map<string, ToolCallOutcome>,
  ): void {
    const outcome = prepareToolCall(toolCall, this.options.toolByName);
    callOutcomes.set(toolCall.id, outcome);
    if (outcome.kind === "ready") {
      this.options.dispatcher.notify(RPCMethod.uiToolCall, {
        sessionId: this.options.session.id,
        turnId,
        phase: "called",
        toolCallId: toolCall.id,
        toolName: toolCall.name,
        args: outcome.args as JSONValue,
      });
    } else {
      this.options.dispatcher.notify(RPCMethod.uiToolCall, {
        sessionId: this.options.session.id,
        turnId,
        phase: "rejected",
        toolCallId: toolCall.id,
        toolName: toolCall.name,
        args: (toolCall.arguments ?? {}) as JSONValue,
        errorMessage: outcome.errorMessage,
      });
    }
  }

  private failToolBudget(
    turnId: string,
    toolCalls: ReturnType<typeof extractToolCalls>,
    callOutcomes: ReadonlyMap<string, ToolCallOutcome>,
    consecutiveSilentToolRounds: number,
  ): AgentRoundOutcome {
    const { dispatcher, conversation: convo, session, maxConsecutiveSilentToolRounds } = this.options;
    const overflowMsg = `tool-call budget exceeded (${maxConsecutiveSilentToolRounds} consecutive tool rounds without assistant text)`;
    const stopText = `Stopped by system: tool-call budget exceeded (${maxConsecutiveSilentToolRounds} consecutive tool calls without assistant text). Tell the user where you got and ask before continuing.`;
    for (const tc of toolCalls) {
      const stopMsg: ToolResultMessage = {
        role: "toolResult",
        toolCallId: tc.id,
        toolName: tc.name,
        content: [{ type: "text", text: stopText }],
        isError: true,
        timestamp: Date.now(),
      };
      if (!convo.appendToolResult(turnId, stopMsg)) {
        return { kind: "terminal", dropQueuedSteer: true, consecutiveSilentToolRounds };
      }
      if (callOutcomes.get(tc.id)?.kind === "ready") {
        dispatcher.notify(RPCMethod.uiToolCall, {
          sessionId: session.id,
          turnId,
          phase: "result",
          toolCallId: tc.id,
          toolName: tc.name,
          isError: true,
          outputText: stopText,
        });
      }
    }
    if (convo.setError(turnId, RPCErrorCode.internalError, overflowMsg)) {
      dispatcher.notify(RPCMethod.uiError, {
        sessionId: session.id,
        turnId,
        code: RPCErrorCode.internalError,
        message: overflowMsg,
      });
    }
    return { kind: "terminal", dropQueuedSteer: true, consecutiveSilentToolRounds };
  }
}
