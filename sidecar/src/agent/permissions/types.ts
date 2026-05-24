import type { JSONValue, PermissionCapabilityView } from "../../rpc/rpc-types";

export type CapabilityId =
  | "filesystem.read"
  | "filesystem.write"
  | "process.spawn"
  | "computer.read"
  | "computer.actuate"
  | "computer.cleanup";

export type PermissionGroupId = "computer-use";
export type PermissionRisk = "low" | "medium" | "high";
export const INTERNAL_TOOL_NAMES = [
  "bash",
  "read",
  "write",
  "update",
  "list_apps",
  "list_windows",
  "get_app_state",
  "start_app_session",
  "stop_app_session",
  "use_mouse",
  "use_keyboard",
  "perform_AX_action",
  "todo_write",
] as const;

export type InternalToolName = (typeof INTERNAL_TOOL_NAMES)[number];

export interface PermissionPolicyContext {
  sessionId: string;
  turnId: string;
  toolCallId: string;
  toolName: string;
  args: Record<string, unknown>;
}

export interface PermissionCapabilityRequest extends PermissionCapabilityView {
  capability: CapabilityId;
  details?: JSONValue;
}

export type PermissionPolicyDecision =
  | {
      behavior: "allow";
      capabilities: PermissionCapabilityRequest[];
    }
  | {
      behavior: "ask";
      title: string;
      message: string;
      risk: PermissionRisk;
      capabilities: PermissionCapabilityRequest[];
      groupId?: PermissionGroupId;
      groupGrantScope?: "turn";
    };

export interface PermissionPolicy {
  readonly toolName: InternalToolName;
  evaluate(ctx: PermissionPolicyContext): PermissionPolicyDecision;
}

export type PermissionPolicyEvaluator = (ctx: PermissionPolicyContext) => PermissionPolicyDecision;

export type PermissionPolicyCatalog = ReadonlyMap<string, PermissionPolicy>;

export class PermissionPolicyConfigurationError extends Error {
  override readonly name = "PermissionPolicyConfigurationError";
}
