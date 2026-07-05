import { errorText } from "../errors";
import type { CallToolResult, Tool } from "@modelcontextprotocol/client";
import type { JSONSchema } from "../llm";
import type { McpAuthServerInfo, McpServerStatusInfo } from "../rpc/rpc-types";
import type { McpConfig, McpServerConfig } from "./config";
import { McpClientSession } from "./client-session";
import { McpInsufficientScopeError } from "./auth/errors";
import { McpStepUpTracker } from "./auth/step-up";

export type McpToolDetailLevel = "names" | "descriptions" | "schemas";

export interface McpToolSummary {
	name: string;
	serverId: string;
	toolName: string;
	description?: string;
	inputSchema?: JSONSchema;
}

export interface McpToolSearchGroup {
	serverId: string;
	description: string;
	tools: McpToolSummary[];
}

export interface McpToolSearchResult {
	matches: McpToolSearchGroup[];
}

export interface McpToolDetails extends McpToolSummary {
	description?: string;
	inputSchema?: JSONSchema;
	annotations?: unknown;
}

export interface McpClientSessionLike {
	listTools(): Promise<
		Array<Pick<Tool, "name" | "description"> & Record<string, unknown>>
	>;
	callTool(
		toolName: string,
		args: Record<string, unknown>,
	): Promise<CallToolResult>;
	invalidateToolCache(): void;
	close(): Promise<void>;
}

export interface McpHostServiceOptions {
	createSession?(
		serverId: string,
		config: McpServerConfig,
	): McpClientSessionLike;
	authRuntime?: {
		startStepUp(input: {
			serverId: string;
			operation: string;
			scope: string;
		}): Promise<void>;
	};
}

interface ServerRecord {
	serverId: string;
	config: McpServerConfig;
	session?: McpClientSessionLike;
	tools?: McpToolDetails[];
	lastError?: string;
}

interface ParsedCanonicalName {
	serverId: string;
	toolName: string;
	canonicalName: string;
}

export class McpHostService {
	private readonly servers = new Map<string, ServerRecord>();
	private readonly createSession: (
		serverId: string,
		config: McpServerConfig,
	) => McpClientSessionLike;
	private readonly stepUpTracker = new McpStepUpTracker();
	private readonly authRuntime?: McpHostServiceOptions["authRuntime"];

	constructor(config: McpConfig, options: McpHostServiceOptions = {}) {
		for (const [serverId, serverConfig] of Object.entries(config.servers)) {
			this.servers.set(serverId, { serverId, config: serverConfig });
		}
		this.createSession =
			options.createSession ??
			((serverId, serverConfig) =>
				new McpClientSession(serverId, serverConfig));
		this.authRuntime = options.authRuntime;
	}

	async searchTools(
		query: string,
		detailLevel: McpToolDetailLevel = "descriptions",
	): Promise<McpToolSearchResult> {
		const queryTerms = tokenize(query);
		const serverRecords = this.searchCandidateServers(queryTerms);
		const groups: McpToolSearchGroup[] = [];
		for (const record of serverRecords) {
			const details = await this.loadToolDetails(record);
			const scored = details
				.map((tool) => ({
					tool,
					score: toolScore(queryTerms, record, tool),
					ownMatchedTermCount: matchedTermCount(
						queryTerms,
						`${tool.toolName} ${tool.description ?? ""}`,
					),
				}))
				.filter(({ score }) => score > 0);
			const allTermsMatched = scored.filter(
				({ ownMatchedTermCount }) => ownMatchedTermCount === queryTerms.length,
			);
			const selected = allTermsMatched.length > 0 ? allTermsMatched : scored;
			const summaries = selected
				.sort(
					(a, b) => b.score - a.score || a.tool.name.localeCompare(b.tool.name),
				)
				.map(({ tool }) => summarizeTool(tool, detailLevel));
			if (summaries.length > 0) {
				groups.push({
					serverId: record.serverId,
					description: record.config.description,
					tools: summaries,
				});
			}
		}
		return { matches: groups };
	}

	async getToolDetails(name: string): Promise<McpToolDetails> {
		const parsed = this.parseCanonicalName(name);
		const record = this.requiredServer(parsed.serverId);
		const tools = await this.loadToolDetails(record);
		const tool = tools.find(
			(candidate) => candidate.toolName === parsed.toolName,
		);
		if (!tool) {
			throw new Error(`Unknown MCP tool "${parsed.canonicalName}"`);
		}
		return tool;
	}

	async callTool(
		name: string,
		args: Record<string, unknown>,
	): Promise<CallToolResult> {
		const parsed = this.parseCanonicalName(name);
		const record = this.requiredServer(parsed.serverId);
		await this.getToolDetails(parsed.canonicalName);
		try {
			return await this.sessionFor(record).callTool(parsed.toolName, args);
		} catch (err) {
			if (!(err instanceof McpInsufficientScopeError) || !this.authRuntime) {
				throw err;
			}
			if (
				!this.stepUpTracker.claim({
					serverId: parsed.serverId,
					operation: parsed.toolName,
					scope: err.scope,
				})
			) {
				throw err;
			}
			await this.authRuntime.startStepUp({
				serverId: parsed.serverId,
				operation: parsed.toolName,
				scope: err.scope,
			});
			return this.sessionFor(record).callTool(parsed.toolName, args);
		}
	}

	status(authStatuses: McpAuthServerInfo[] = []): McpServerStatusInfo[] {
		const authByServer = new Map(
			authStatuses.map((status) => [status.serverId, status]),
		);
		return Array.from(this.servers.values())
			.map((record) =>
				this.statusFor(record, authByServer.get(record.serverId)),
			)
			.sort((a, b) => a.serverId.localeCompare(b.serverId));
	}

	hasServer(serverId: string): boolean {
		return this.servers.has(serverId);
	}

	addServer(
		serverId: string,
		config: McpServerConfig,
		authStatuses: McpAuthServerInfo[] = [],
	): McpServerStatusInfo {
		if (this.servers.has(serverId)) {
			throw new Error(`MCP server "${serverId}" already exists`);
		}
		const record: ServerRecord = { serverId, config };
		this.servers.set(serverId, record);
		const auth = authStatuses.find((status) => status.serverId === serverId);
		return this.statusFor(record, auth);
	}

	async updateServer(
		serverId: string,
		config: McpServerConfig,
		authStatuses: McpAuthServerInfo[] = [],
	): Promise<McpServerStatusInfo> {
		const record = this.requiredServer(serverId);
		const session = record.session;
		record.config = config;
		record.session = undefined;
		record.tools = undefined;
		record.lastError = undefined;
		if (session) await session.close();
		const auth = authStatuses.find((status) => status.serverId === serverId);
		return this.statusFor(record, auth);
	}

	async connectServer(
		serverId: string,
		authStatuses: McpAuthServerInfo[] = [],
	): Promise<McpServerStatusInfo> {
		const record = this.requiredServer(serverId);
		try {
			await this.loadToolDetails(record);
			record.lastError = undefined;
		} catch (err) {
			record.lastError = errorText(err);
			const session = record.session;
			record.session = undefined;
			record.tools = undefined;
			if (session) await session.close();
			throw err;
		}
		const auth = authStatuses.find((status) => status.serverId === serverId);
		return this.statusFor(record, auth);
	}

	async autoConnectServers(
		authStatuses: McpAuthServerInfo[] = [],
	): Promise<McpServerStatusInfo[]> {
		const authByServer = new Map(
			authStatuses.map((status) => [status.serverId, status]),
		);
		const statuses: McpServerStatusInfo[] = [];
		for (const record of Array.from(this.servers.values()).sort((a, b) =>
			a.serverId.localeCompare(b.serverId),
		)) {
			if (record.config.autoConnect !== true) continue;
			const auth = authByServer.get(record.serverId);
			if (auth?.authType === "oauth" && auth.state !== "ready") continue;
			try {
				statuses.push(await this.connectServer(record.serverId, authStatuses));
			} catch {
				statuses.push(this.statusFor(record, auth));
			}
		}
		return statuses;
	}

	async disconnectServer(
		serverId: string,
		authStatuses: McpAuthServerInfo[] = [],
	): Promise<McpServerStatusInfo> {
		const record = this.requiredServer(serverId);
		const session = record.session;
		record.session = undefined;
		record.tools = undefined;
		record.lastError = undefined;
		if (session) await session.close();
		const auth = authStatuses.find((status) => status.serverId === serverId);
		return this.statusFor(record, auth);
	}

	async removeServer(serverId: string): Promise<void> {
		const record = this.requiredServer(serverId);
		const session = record.session;
		if (session) await session.close();
		this.servers.delete(serverId);
	}

	async refreshServer(serverId: string): Promise<void> {
		const record = this.requiredServer(serverId);
		const session = record.session;
		record.session = undefined;
		record.tools = undefined;
		record.lastError = undefined;
		if (session) await session.close();
	}

	async closeAll(): Promise<void> {
		const sessions = Array.from(
			this.servers.values(),
			(record) => record.session,
		).filter(
			(session): session is McpClientSessionLike => session !== undefined,
		);
		for (const record of this.servers.values()) {
			record.session = undefined;
			record.tools = undefined;
		}
		await Promise.all(sessions.map((session) => session.close()));
	}

	private searchCandidateServers(queryTerms: string[]): ServerRecord[] {
		const records = Array.from(this.servers.values());
		const directMatches = records.filter(
			(record) => serverScore(queryTerms, record) > 0,
		);
		return directMatches.length > 0 ? directMatches : records;
	}

	private async loadToolDetails(
		record: ServerRecord,
	): Promise<McpToolDetails[]> {
		if (record.tools) return record.tools;
		const seen = new Set<string>();
		const tools = await this.sessionFor(record).listTools();
		record.tools = tools.map((tool) => {
			const toolName = stringField(tool.name, "MCP tool name");
			const canonicalName = canonicalToolName(record.serverId, toolName);
			if (seen.has(canonicalName)) {
				throw new Error(`Duplicate MCP tool canonical name "${canonicalName}"`);
			}
			seen.add(canonicalName);
			return {
				name: canonicalName,
				serverId: record.serverId,
				toolName,
				description:
					typeof tool.description === "string" ? tool.description : undefined,
				inputSchema: isJsonSchema(tool.inputSchema)
					? tool.inputSchema
					: undefined,
				annotations: tool.annotations,
			};
		});
		return record.tools;
	}

	private sessionFor(record: ServerRecord): McpClientSessionLike {
		if (!record.session) {
			record.session = this.createSession(record.serverId, record.config);
		}
		return record.session;
	}

	private statusFor(
		record: ServerRecord,
		auth?: McpAuthServerInfo,
	): McpServerStatusInfo {
		return {
			serverId: record.serverId,
			name: record.serverId,
			description: record.config.description,
			transportType: record.config.transport.type,
			connectionState: record.lastError
				? "failed"
				: record.session
					? "connected"
					: "disconnected",
			authState: auth?.state ?? "notConfigured",
			authType: auth?.authType ?? "none",
			...(record.lastError ? { message: record.lastError } : {}),
		};
	}

	private requiredServer(serverId: string): ServerRecord {
		const record = this.servers.get(serverId);
		if (!record) throw new Error(`Unknown MCP server "${serverId}"`);
		return record;
	}

	private parseCanonicalName(name: string): ParsedCanonicalName {
		const dot = name.indexOf(".");
		if (dot <= 0 || dot === name.length - 1) {
			throw new Error(
				`MCP tool name "${name}" must use canonical form <serverId>.<toolName>`,
			);
		}
		const serverId = name.slice(0, dot);
		const toolName = name.slice(dot + 1);
		return { serverId, toolName, canonicalName: name };
	}
}

function summarizeTool(
	tool: McpToolDetails,
	detailLevel: McpToolDetailLevel,
): McpToolSummary {
	const summary: McpToolSummary = {
		name: tool.name,
		serverId: tool.serverId,
		toolName: tool.toolName,
	};
	if (detailLevel === "descriptions" || detailLevel === "schemas") {
		summary.description = tool.description;
	}
	if (detailLevel === "schemas") {
		summary.inputSchema = tool.inputSchema;
	}
	return summary;
}

function canonicalToolName(serverId: string, toolName: string): string {
	return `${serverId}.${toolName}`;
}

function tokenize(value: string): string[] {
	return value
		.toLowerCase()
		.split(/[^a-z0-9_]+/)
		.filter((part) => part.length > 0);
}

function serverScore(queryTerms: string[], record: ServerRecord): number {
	return scoreText(
		queryTerms,
		`${record.serverId} ${record.config.description}`,
	);
}

function toolScore(
	queryTerms: string[],
	record: ServerRecord,
	tool: McpToolDetails,
): number {
	return scoreText(
		queryTerms,
		`${record.serverId} ${record.config.description} ${tool.toolName} ${tool.description ?? ""}`,
	);
}

function scoreText(queryTerms: string[], text: string): number {
	if (queryTerms.length === 0) return 1;
	const tokens = new Set(tokenize(text));
	let score = 0;
	for (const term of queryTerms) {
		if (tokens.has(term)) score += 2;
		else if (Array.from(tokens).some((token) => token.includes(term)))
			score += 1;
	}
	return score;
}

function matchedTermCount(queryTerms: string[], text: string): number {
	if (queryTerms.length === 0) return 0;
	const tokens = new Set(tokenize(text));
	let count = 0;
	for (const term of queryTerms) {
		if (
			tokens.has(term) ||
			Array.from(tokens).some((token) => token.includes(term))
		) {
			count += 1;
		}
	}
	return count;
}

function stringField(value: unknown, label: string): string {
	if (typeof value !== "string" || value.length === 0) {
		throw new Error(`${label} must be a non-empty string`);
	}
	return value;
}

function isJsonSchema(value: unknown): value is JSONSchema {
	return value !== null && typeof value === "object" && !Array.isArray(value);
}
