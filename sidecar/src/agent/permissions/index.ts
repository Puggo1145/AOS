export { isPathWithinRoot } from "./path";
export { allow, ask } from "./decision";
export { PermissionApprovalError, PermissionGateway } from "./gateway";
export {
  assertRegisteredToolsMatchPermissionPolicies,
  builtinPermissionPolicyCatalog,
  evaluatePermissionPolicy,
} from "./policies";
export type { PermissionAuthorizeInput, PermissionAuthorizeResult, PermissionAuthorizer } from "./gateway";
export type {
  CapabilityId,
  PermissionCapabilityRequest,
  PermissionGroupId,
  PermissionPolicy,
  PermissionPolicyCatalog,
  PermissionPolicyContext,
  PermissionPolicyDecision,
  PermissionRisk,
} from "./types";
export { PermissionPolicyConfigurationError } from "./types";
