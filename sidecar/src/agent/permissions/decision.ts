import type {
	PermissionCapabilityRequest,
	PermissionGroupId,
	PermissionPolicyDecision,
	PermissionRisk,
} from "./types";

export function allow(
	capabilities: readonly PermissionCapabilityRequest[] = [],
): PermissionPolicyDecision {
	return { behavior: "allow", capabilities: [...capabilities] };
}

export function ask(input: {
	readonly title: string;
	readonly message: string;
	readonly risk: PermissionRisk;
	readonly capabilities: readonly PermissionCapabilityRequest[];
	readonly groupId?: PermissionGroupId;
	readonly groupGrantScope?: "turn";
}): PermissionPolicyDecision {
	return {
		behavior: "ask",
		title: input.title,
		message: input.message,
		risk: input.risk,
		capabilities: [...input.capabilities],
		groupId: input.groupId,
		groupGrantScope: input.groupGrantScope,
	};
}
