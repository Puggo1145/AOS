// Agent-turn tool dispatch.
//
// The agent loop decides *when* tools run. This module owns *how* a model
// tool call becomes a validated handler invocation and how handler output is
// rendered back onto the UI wire.

import { errorText } from "../../errors";
import type {
	Api,
	AssistantMessage,
	Model,
	ToolCall,
	ToolResultContent,
	ToolResultMessage,
} from "../../llm";
import { logger } from "../../log";
import type { Dispatcher } from "../../rpc/dispatcher";
import { RPCMethod, type JSONValue } from "../../rpc/rpc-types";
import type { Conversation } from "../conversation";
import {
	PermissionApprovalError,
	PermissionPolicyConfigurationError,
	type PermissionAuthorizer,
} from "../permissions";
import type { Session } from "../session/session";
import { validateToolArguments } from "../tools/core/schema";
import {
	ToolUserError,
	type ToolExecContext,
	type ToolExecResult,
	type ToolHandler,
	type ToolRuntimeEffects,
} from "../tools";
import type { TurnEmitter } from "./emitter";

export type ToolCallOutcome =
	| {
			kind: "ready";
			args: Record<string, unknown>;
			handler: ToolHandler<any, any>;
	  }
	| { kind: "rejected"; errorMessage: string };

export type ToolDispatchCtx = ToolExecContext;

export function extractToolCalls(msg: AssistantMessage): ToolCall[] {
	const out: ToolCall[] = [];
	for (const c of msg.content) {
		if (c.type === "toolCall") out.push(c);
	}
	return out;
}

export function assistantSpoke(msg: AssistantMessage): boolean {
	return msg.content.some((c) => c.type === "text" && c.text.trim().length > 0);
}

export function prepareToolCall(
	call: ToolCall,
	byName: ReadonlyMap<string, ToolHandler<any, any>>,
): ToolCallOutcome {
	const handler = byName.get(call.name);
	if (!handler) {
		const known = Array.from(byName.keys()).join(", ") || "<none>";
		return {
			kind: "rejected",
			errorMessage: `Unknown tool "${call.name}". Available tools: ${known}.`,
		};
	}
	try {
		const args = validateToolArguments(handler, call) as Record<
			string,
			unknown
		>;
		return { kind: "ready", args, handler };
	} catch (err) {
		return {
			kind: "rejected",
			errorMessage: errorText(err),
		};
	}
}

export async function runTool(
	handler: ToolHandler<any, any>,
	args: Record<string, unknown>,
	toolName: string,
	ctx: ToolDispatchCtx,
	effects: ToolRuntimeEffects,
): Promise<ToolExecResult> {
	try {
		const result = await handler.execute(args, ctx);
		if (!result.isError) {
			handler.applyRuntimeEffects?.(result, args, ctx, effects);
		}
		return result;
	} catch (err) {
		if (err instanceof ToolUserError) {
			return {
				content: [{ type: "text", text: err.message }],
				isError: true,
			};
		}
		if (ctx.signal.aborted) {
			return {
				content: [{ type: "text", text: `${toolName} cancelled` }],
				isError: true,
			};
		}
		const inner = err instanceof Error ? err : new Error(String(err));
		const wrapped = new Error(`Tool "${toolName}" threw: ${inner.message}`);
		(wrapped as Error & { cause?: unknown }).cause = inner;
		throw wrapped;
	}
}

export function renderToolResultForWire(content: ToolResultContent[]): string {
	const out: string[] = [];
	for (const c of content) {
		if (c.type === "text") out.push(c.text);
		else if (c.type === "image") out.push(`[image ${c.mimeType}]`);
	}
	return out.join("\n");
}

export function toolDispatchContext(input: {
	session: Session;
	turnId: string;
	toolCallId: string;
	model: Model<Api>;
	signal: AbortSignal;
}): ToolDispatchCtx {
	const { session } = input;
	return {
		sessionId: session.id,
		turnId: input.turnId,
		toolCallId: input.toolCallId,
		model: input.model,
		computerUse: {
			get appSession() {
				return session.computerUseAppSession;
			},
		},
		signal: input.signal,
	};
}

export function toolRuntimeEffects(session: Session): ToolRuntimeEffects {
	return {
		computerUse: {
			setAppSession: (info) => session.setComputerUseAppSession(info),
			clearAppSession: () => session.clearComputerUseAppSession(),
		},
	};
}

/// Outcome of running every tool call from one assistant round. The round
/// runner maps this onto `AgentRoundOutcome`:
///   - "completed": every call ran (or was rejected/denied) and its result
///     landed in the Conversation — the round runner proceeds to its own
///     post-loop abort check before continuing to the next LLM round.
///   - "aborted": the turn's AbortSignal fired mid-loop (either before a call
///     started or while awaiting permission) — the loop stopped early WITHOUT
///     appending a result for the call in flight.
///   - "turnGone": `conversation.appendToolResult` returned false, meaning the
///     turnId raced an `agent.reset`/`agent.cancel` and no longer exists in
///     the Conversation. The round runner's `terminal()` helper wraps this.
export type ExecuteToolCallsResult =
	| { kind: "completed" }
	| { kind: "aborted" }
	| { kind: "turnGone" };

/// Run every tool call from one assistant round: outcome lookup (already
/// validated on `toolcall_end` by `prepareToolCall`), permission
/// authorization with `awaitingPermission`/`waiting` status bracketing,
/// handler invocation, error laundering into an `isError` tool result, and
/// appending + wire-projecting each result in order. Moved out of
/// `AgentRoundRunner.run` verbatim (same frame order, same error messages) so
/// the round runner's own method stays a readable top-level orchestration.
export async function executeToolCalls(input: {
	session: Session;
	turnId: string;
	signal: AbortSignal;
	toolCalls: ToolCall[];
	callOutcomes: ReadonlyMap<string, ToolCallOutcome>;
	permissionGateway: PermissionAuthorizer;
	emitter: TurnEmitter;
	conversation: Conversation;
	model: Model<Api>;
}): Promise<ExecuteToolCallsResult> {
	const {
		session,
		turnId,
		signal,
		toolCalls,
		callOutcomes,
		permissionGateway,
		emitter,
		conversation: convo,
		model,
	} = input;
	for (const tc of toolCalls) {
		if (signal.aborted) break;
		const outcome = callOutcomes.get(tc.id) ?? {
			kind: "rejected" as const,
			errorMessage: `internal: missing call outcome for ${tc.id}`,
		};
		let result: ToolExecResult;
		let notifyResult = outcome.kind === "ready";
		if (outcome.kind === "rejected") {
			result = {
				content: [{ type: "text", text: outcome.errorMessage }],
				isError: true,
			};
		} else {
			try {
				const permission = await permissionGateway.authorize({
					sessionId: session.id,
					turnId,
					toolCallId: tc.id,
					toolName: tc.name,
					args: outcome.args,
					signal,
					onApprovalStart: () => {
						emitter.status(turnId, "awaitingPermission");
					},
					onApprovalEnd: () => {
						emitter.status(turnId, "waiting");
					},
				});
				if (permission.kind === "aborted" || signal.aborted) break;
				if (permission.kind !== "allowed") {
					result = {
						content: [{ type: "text", text: permission.message }],
						isError: permission.isError,
					};
					notifyResult = false;
					emitter.toolCall(turnId, {
						phase: "permissionDenied",
						toolCallId: tc.id,
						toolName: tc.name,
						args: outcome.args as JSONValue,
						errorMessage: permission.message,
					});
				} else {
					const toolCtx = toolDispatchContext({
						session,
						turnId,
						toolCallId: tc.id,
						model,
						signal,
					});
					result = await runTool(
						outcome.handler,
						outcome.args,
						tc.name,
						toolCtx,
						toolRuntimeEffects(session),
					);
				}
			} catch (err) {
				if (
					err instanceof PermissionPolicyConfigurationError ||
					err instanceof PermissionApprovalError
				) {
					throw err;
				}
				const message = errorText(err);
				logger.error("tool execution threw", {
					sessionId: session.id,
					turnId,
					toolCallId: tc.id,
					toolName: tc.name,
					err: String(err),
				});
				result = {
					content: [
						{ type: "text", text: `Tool "${tc.name}" failed: ${message}` },
					],
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
			return { kind: "turnGone" };
		}
		if (notifyResult) {
			emitter.toolCall(turnId, {
				phase: "result",
				toolCallId: tc.id,
				toolName: tc.name,
				isError: result.isError,
				outputText: renderToolResultForWire(result.content),
			});
		}
	}

	if (signal.aborted) return { kind: "aborted" };
	return { kind: "completed" };
}

export async function finishToolRuntimeAfterTerminalAssistantReply(input: {
	dispatcher: Dispatcher;
	session: Session;
}): Promise<void> {
	const appSession = input.session.computerUseAppSession;
	if (!appSession) return;
	await input.dispatcher.request(RPCMethod.computerUseStopAppSession, {
		pid: appSession.pid,
	});
	input.session.clearComputerUseAppSession();
}
