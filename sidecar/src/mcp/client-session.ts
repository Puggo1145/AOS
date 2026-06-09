import {
	Client,
	StdioClientTransport,
	StreamableHTTPClientTransport,
	type CallToolResult,
	type AuthProvider,
	type OAuthClientProvider,
	type ListToolsResult,
	type Tool,
} from "@modelcontextprotocol/client";
import type { McpServerConfig } from "./config";
import { McpAuthRequiredError } from "./auth/errors";

export interface McpSdkClientLike {
	setNotificationHandler(
		method: "notifications/tools/list_changed",
		handler: () => void | Promise<void>,
	): void;
	connect(transport: unknown): Promise<void>;
	listTools(): Promise<Pick<ListToolsResult, "tools">>;
	callTool(input: {
		name: string;
		arguments: Record<string, unknown>;
	}): Promise<CallToolResult>;
	close(): Promise<void>;
}

export interface McpSdkFactories {
	createClient(serverId: string): McpSdkClientLike;
	createStdioTransport(input: {
		command: string;
		args: string[];
		env: Record<string, string>;
	}): unknown;
	createStreamableHttpTransport(
		url: URL,
		options: {
			requestInit: { headers: Record<string, string> };
			authProvider?: AuthProvider | OAuthClientProvider;
		},
	): unknown;
}

export interface McpClientSessionOptions {
	factories?: McpSdkFactories;
	createOAuthProvider?(
		serverId: string,
		config: McpServerConfig,
	): AuthProvider | OAuthClientProvider;
	hasOAuthTokens?(serverId: string, config: McpServerConfig): boolean;
}

interface TerminableTransport {
	terminateSession(): Promise<void>;
}

export const defaultMcpSdkFactories: McpSdkFactories = {
	createClient(serverId) {
		return new Client({ name: `notch-agent-${serverId}`, version: "0.1.0" });
	},
	createStdioTransport(input) {
		return new StdioClientTransport(input);
	},
	createStreamableHttpTransport(url, options) {
		return new StreamableHTTPClientTransport(url, options);
	},
};

export class McpClientSession {
	private client?: McpSdkClientLike;
	private transport?: unknown;
	private connected = false;
	private connectPromise?: Promise<void>;
	private toolCache?: Tool[];

	constructor(
		public readonly serverId: string,
		private readonly config: McpServerConfig,
		options: McpClientSessionOptions | McpSdkFactories = {},
	) {
		this.options =
			"isOptionsObject" in { isOptionsObject: true } &&
			isMcpClientSessionOptions(options)
				? options
				: { factories: options as McpSdkFactories };
		this.factories = this.options.factories ?? defaultMcpSdkFactories;
	}

	private readonly options: McpClientSessionOptions;
	private readonly factories: McpSdkFactories;

	async connect(): Promise<void> {
		if (this.connected) return;
		if (this.connectPromise) {
			await this.connectPromise;
			return;
		}
		const promise = this.openConnection();
		this.connectPromise = promise;
		try {
			await promise;
		} finally {
			if (this.connectPromise === promise) {
				this.connectPromise = undefined;
			}
		}
	}

	private async openConnection(): Promise<void> {
		if (
			this.config.transport.type === "streamableHttp" &&
			this.config.transport.auth &&
			this.options.hasOAuthTokens?.(this.serverId, this.config) === false
		) {
			throw new McpAuthRequiredError(this.serverId);
		}
		const client = this.factories.createClient(this.serverId);
		client.setNotificationHandler("notifications/tools/list_changed", () => {
			this.invalidateToolCache();
		});
		this.client = client;
		let transport: unknown;
		try {
			transport = this.createTransport();
			this.transport = transport;
			await client.connect(transport);
		} catch (err) {
			if (this.client === client) this.client = undefined;
			if (this.transport === transport) this.transport = undefined;
			this.connected = false;
			await closeSdkHandles(client, transport);
			throw err;
		}
		if (this.client !== client || this.transport !== transport) {
			await closeSdkHandles(client, transport);
			throw new Error(`MCP client ${this.serverId} closed while connecting`);
		}
		this.connected = true;
	}

	async listTools(): Promise<Tool[]> {
		if (this.toolCache) return this.toolCache;
		await this.connect();
		if (!this.client)
			throw new Error(`MCP client ${this.serverId} not connected`);
		const result = await this.client.listTools();
		this.toolCache = result.tools;
		return this.toolCache;
	}

	async callTool(
		toolName: string,
		args: Record<string, unknown>,
	): Promise<CallToolResult> {
		await this.connect();
		if (!this.client)
			throw new Error(`MCP client ${this.serverId} not connected`);
		return this.client.callTool({ name: toolName, arguments: args });
	}

	invalidateToolCache(): void {
		this.toolCache = undefined;
	}

	async close(): Promise<void> {
		const client = this.client;
		const transport = this.transport;
		this.client = undefined;
		this.transport = undefined;
		this.connected = false;
		this.invalidateToolCache();
		await closeSdkHandles(client, transport);
	}

	private createTransport(): unknown {
		if (this.config.transport.type === "stdio") {
			return this.factories.createStdioTransport({
				command: this.config.transport.command,
				args: this.config.transport.args,
				env: this.config.transport.env,
			});
		}
		const authProvider = this.config.transport.auth
			? this.options.createOAuthProvider?.(this.serverId, this.config)
			: undefined;
		return this.factories.createStreamableHttpTransport(
			new URL(this.config.transport.url),
			{
				requestInit: { headers: this.config.transport.headers },
				...(authProvider ? { authProvider } : {}),
			},
		);
	}
}

async function closeSdkHandles(
	client: McpSdkClientLike | undefined,
	transport: unknown,
): Promise<void> {
	if (isTerminableTransport(transport)) {
		await transport.terminateSession();
	}
	if (client) await client.close();
}

function isMcpClientSessionOptions(
	value: McpClientSessionOptions | McpSdkFactories,
): value is McpClientSessionOptions {
	return (
		!("createClient" in value) ||
		"factories" in value ||
		"createOAuthProvider" in value ||
		"hasOAuthTokens" in value
	);
}

function isTerminableTransport(value: unknown): value is TerminableTransport {
	return (
		value !== null &&
		typeof value === "object" &&
		"terminateSession" in value &&
		typeof value.terminateSession === "function"
	);
}
