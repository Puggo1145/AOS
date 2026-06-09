export class McpAuthError extends Error {
	constructor(message: string) {
		super(message);
		this.name = "McpAuthError";
	}
}

export class McpAuthRequiredError extends McpAuthError {
	constructor(
		public readonly serverId: string,
		message = `MCP server "${serverId}" requires OAuth login`,
	) {
		super(message);
		this.name = "McpAuthRequiredError";
	}
}

export class McpAuthInvalidatedError extends McpAuthError {
	constructor(
		public readonly serverId: string,
		message = `MCP server "${serverId}" OAuth credentials were invalidated`,
	) {
		super(message);
		this.name = "McpAuthInvalidatedError";
	}
}

export class McpInsufficientScopeError extends McpAuthError {
	constructor(
		public readonly serverId: string,
		public readonly scope: string,
		message = `MCP server "${serverId}" requires OAuth scope "${scope}"`,
	) {
		super(message);
		this.name = "McpInsufficientScopeError";
	}
}
