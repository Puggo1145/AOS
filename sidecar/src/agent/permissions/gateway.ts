import { logger } from "../../log";
import {
	RPCMethod,
	type PermissionRequestApprovalParams,
	type PermissionRequestApprovalResult,
} from "../../rpc/rpc-types";
import type { PermissionLevel } from "../../config/storage";
import { evaluatePermissionPolicy } from "./policies";
import type {
	PermissionGroupId,
	PermissionPolicyCatalog,
	PermissionPolicyDecision,
	PermissionPolicyContext,
} from "./types";

interface ApprovalDispatcher {
	request<R>(
		method: string,
		params: object,
		opts?: { signal?: AbortSignal; timeoutMs?: number },
	): Promise<R>;
	notify(method: string, params: object): void;
}

export interface PermissionAuthorizeInput extends PermissionPolicyContext {
	signal: AbortSignal;
	onApprovalStart?: () => void;
	onApprovalEnd?: () => void;
}

export type PermissionAuthorizeResult =
	| { kind: "allowed" }
	| { kind: "denied"; message: string; isError: false }
	| { kind: "aborted" };

export interface PermissionAuthorizer {
	authorize(
		input: PermissionAuthorizeInput,
	): Promise<PermissionAuthorizeResult>;
	clearTurnGrants(sessionId: string, turnId: string): void;
}

export class PermissionApprovalError extends Error {
	override readonly name = "PermissionApprovalError";
}

export class PermissionGateway implements PermissionAuthorizer {
	private readonly turnGroupGrants = new Set<string>();

	constructor(
		private readonly dispatcher: ApprovalDispatcher,
		private readonly catalog: PermissionPolicyCatalog,
		private readonly permissionLevelProvider: () => PermissionLevel = () =>
			"default",
	) {}

	async authorize(
		input: PermissionAuthorizeInput,
	): Promise<PermissionAuthorizeResult> {
		if (this.permissionLevelProvider() === "fullAccess") {
			this.logFullAccessDecision(input);
			return { kind: "allowed" };
		}

		const decision = evaluatePermissionPolicy(
			this.catalog.get(input.toolName),
			input,
		);
		if (decision.behavior === "allow") {
			this.logDecision(input, decision, "allow");
			return { kind: "allowed" };
		}

		if (
			decision.groupId &&
			decision.groupGrantScope === "turn" &&
			this.hasTurnGrant(input, decision.groupId)
		) {
			this.logDecision(input, decision, "allow");
			return { kind: "allowed" };
		}

		input.onApprovalStart?.();
		let result: PermissionRequestApprovalResult;
		try {
			result = await this.dispatcher.request<PermissionRequestApprovalResult>(
				RPCMethod.permissionRequestApproval,
				approvalParams(input, decision),
				{ signal: input.signal },
			);
		} catch (err) {
			if (input.signal.aborted) {
				this.dispatcher.notify(RPCMethod.permissionApprovalCancelled, {
					sessionId: input.sessionId,
					turnId: input.turnId,
					toolCallId: input.toolCallId,
				});
				return { kind: "aborted" };
			}
			const message = err instanceof Error ? err.message : String(err);
			logger.error("permission approval failed", {
				sessionId: input.sessionId,
				turnId: input.turnId,
				toolCallId: input.toolCallId,
				toolName: input.toolName,
				err: message,
			});
			throw new PermissionApprovalError(
				`Permission approval failed: ${message}`,
			);
		} finally {
			input.onApprovalEnd?.();
		}

		const approvalDecision = parseApprovalDecision(result);
		if (approvalDecision === "allow") {
			if (decision.groupId && decision.groupGrantScope === "turn") {
				this.turnGroupGrants.add(
					turnGrantKey(input.sessionId, input.turnId, decision.groupId),
				);
				this.logDecision(input, decision, "allow");
			}
			return { kind: "allowed" };
		}
		this.logDecision(input, decision, "deny");
		return {
			kind: "denied",
			isError: false,
			message: deniedMessage(decision),
		};
	}

	clearTurnGrants(sessionId: string, turnId: string): void {
		const prefix = `${sessionId}\u0000${turnId}\u0000`;
		for (const key of this.turnGroupGrants) {
			if (key.startsWith(prefix)) this.turnGroupGrants.delete(key);
		}
	}

	private hasTurnGrant(
		input: PermissionAuthorizeInput,
		groupId: PermissionGroupId,
	): boolean {
		return this.turnGroupGrants.has(
			turnGrantKey(input.sessionId, input.turnId, groupId),
		);
	}

	private logDecision(
		input: PermissionAuthorizeInput,
		decision: PermissionPolicyDecision,
		resolved: "allow" | "deny",
	): void {
		logger.info("permission decision", {
			sessionId: input.sessionId,
			turnId: input.turnId,
			toolCallId: input.toolCallId,
			toolName: input.toolName,
			resolved,
			behavior: decision.behavior,
			groupId: decision.behavior === "ask" ? decision.groupId : undefined,
			capabilities: decision.capabilities.map((c) => c.capability),
		});
	}

	private logFullAccessDecision(input: PermissionAuthorizeInput): void {
		logger.info("permission decision", {
			sessionId: input.sessionId,
			turnId: input.turnId,
			toolCallId: input.toolCallId,
			toolName: input.toolName,
			resolved: "allow",
			behavior: "fullAccess",
			capabilities: [],
		});
	}
}

function turnGrantKey(
	sessionId: string,
	turnId: string,
	groupId: PermissionGroupId,
): string {
	return `${sessionId}\u0000${turnId}\u0000${groupId}`;
}

function approvalParams(
	input: PermissionAuthorizeInput,
	decision: Extract<PermissionPolicyDecision, { behavior: "ask" }>,
): PermissionRequestApprovalParams {
	return {
		sessionId: input.sessionId,
		turnId: input.turnId,
		toolCallId: input.toolCallId,
		toolName: input.toolName,
		title: decision.title,
		message: decision.message,
		risk: decision.risk,
		capabilities: decision.capabilities,
	};
}

function deniedMessage(
	decision: Extract<PermissionPolicyDecision, { behavior: "ask" }>,
): string {
	const first = decision.capabilities[0];
	if (!first) return "Permission denied: user did not allow this action.";
	const suffix = first.target ? ` for ${first.target}` : "";
	return `Permission denied: user did not allow ${first.action}${suffix}.`;
}

function parseApprovalDecision(
	result: PermissionRequestApprovalResult,
): "allow" | "deny" {
	if (result.decision === "allow" || result.decision === "deny") {
		return result.decision;
	}
	throw new PermissionApprovalError(
		`Permission approval returned invalid decision ${JSON.stringify(result.decision)}`,
	);
}
