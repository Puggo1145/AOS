export function operationScopeKey(input: {
	serverId: string;
	operation: string;
	scope: string;
}): string {
	return `${input.serverId}\u0000${input.operation}\u0000${input.scope}`;
}

export class McpStepUpTracker {
	private readonly attempted = new Set<string>();

	claim(input: {
		serverId: string;
		operation: string;
		scope: string;
	}): boolean {
		const key = operationScopeKey(input);
		if (this.attempted.has(key)) return false;
		this.attempted.add(key);
		return true;
	}
}
