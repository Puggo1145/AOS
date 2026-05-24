import type {
  PermissionPolicy,
  PermissionPolicyCatalog,
  PermissionPolicyContext,
  PermissionPolicyDecision,
  PermissionPolicyEvaluator,
} from "./types";
import { PermissionPolicyConfigurationError } from "./types";
import { builtinPermissionPoliciesByToolName } from "./rules";

type RegisteredToolLike = string | { spec: { name: string } };

function toolName(tool: RegisteredToolLike): string {
  return typeof tool === "string" ? tool : tool.spec.name;
}

export function assertRegisteredToolsMatchPermissionPolicies(
  tools: RegisteredToolLike[],
  catalog: PermissionPolicyCatalog = builtinPermissionPolicyCatalog,
): void {
  const registered = new Set(tools.map(toolName));
  const policyNames = new Set(catalog.keys());

  const missing = Array.from(registered).filter((name) => !policyNames.has(name)).sort();
  if (missing.length > 0) {
    throw new Error(`missing permission policy for registered tool(s): ${missing.join(", ")}`);
  }

  const stale = Array.from(policyNames).filter((name) => !registered.has(name)).sort();
  if (stale.length > 0) {
    throw new Error(`permission policy registered for unknown tool(s): ${stale.join(", ")}`);
  }
}

export function evaluatePermissionPolicy(
  policy: PermissionPolicy | undefined,
  ctx: PermissionPolicyContext,
): PermissionPolicyDecision {
  if (!policy) {
    throw new PermissionPolicyConfigurationError(`missing permission policy for tool "${ctx.toolName}"`);
  }
  if (policy.toolName !== ctx.toolName) {
    throw new PermissionPolicyConfigurationError(
      `permission policy "${policy.toolName}" cannot evaluate tool "${ctx.toolName}"`,
    );
  }
  try {
    return policy.evaluate(ctx);
  } catch (err) {
    if (err instanceof PermissionPolicyConfigurationError) {
      throw err;
    }
    const message = err instanceof Error ? err.message : String(err);
    throw new PermissionPolicyConfigurationError(
      `permission policy "${policy.toolName}" failed for tool "${ctx.toolName}": ${message}`,
    );
  }
}

export const builtinPermissionPolicyCatalog: PermissionPolicyCatalog = new Map(
  Object.entries(builtinPermissionPoliciesByToolName).map(([toolName, evaluate]) => {
    const policy: PermissionPolicy = {
      toolName: toolName as PermissionPolicy["toolName"],
      evaluate: evaluate as PermissionPolicyEvaluator,
    };
    return [policy.toolName, policy] as const;
  }),
);
