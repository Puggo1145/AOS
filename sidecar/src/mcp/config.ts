import { errorText } from "../errors";
import {
	existsSync,
	mkdirSync,
	readFileSync,
	renameSync,
	writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";
import { randomUUID } from "node:crypto";
import {
	parseMcpOAuthAuthConfig,
	type McpOAuthAuthConfig,
} from "./auth/config";

export interface McpConfig {
	servers: Record<string, McpServerConfig>;
}

export interface McpServerConfig {
	description: string;
	autoConnect?: boolean;
	transport: McpTransportConfig;
}

export type McpTransportConfig =
	| McpStdioTransportConfig
	| McpHttpTransportConfig;

export interface McpStdioTransportConfig {
	type: "stdio";
	command: string;
	args: string[];
	env: Record<string, string>;
}

export interface McpHttpTransportConfig {
	type: "streamableHttp";
	url: string;
	headers: Record<string, string>;
	auth?: McpOAuthAuthConfig;
}

export type McpConfigAuthType = "none" | "headers" | "oauth";

export interface AddMcpServerConfigInput {
	serverId: string;
	description: string;
	autoConnect?: boolean;
	transportType: "stdio" | "streamableHttp";
	authType?: McpConfigAuthType;
	command?: string;
	args?: string[];
	env?: Record<string, string>;
	url?: string;
	headers?: Record<string, string>;
}

export type UpdateMcpServerConfigInput = AddMcpServerConfigInput;

export interface McpServerConfigEditInfo {
	serverId: string;
	description: string;
	autoConnect?: boolean;
	transportType: "stdio" | "streamableHttp";
	authType?: McpConfigAuthType;
	command?: string;
	args?: string[];
	env?: Record<string, string>;
	url?: string;
	headers?: Record<string, string>;
}

export type MalformedMcpConfigKind = "read" | "parse" | "schema";

export class MalformedMcpConfigError extends Error {
	constructor(
		public readonly kind: MalformedMcpConfigKind,
		message: string,
		public readonly cause?: unknown,
	) {
		super(message);
		this.name = "MalformedMcpConfigError";
	}
}

function notchHome(): string {
	return process.env.HOME && process.env.HOME.length > 0
		? process.env.HOME
		: homedir();
}

export function mcpConfigPath(): string {
	return join(notchHome(), ".notch-agent", "mcp.json");
}

export function readMcpConfig(): McpConfig {
	const path = mcpConfigPath();
	if (!existsSync(path)) return { servers: {} };

	let raw: string;
	try {
		raw = readFileSync(path, "utf-8");
	} catch (err) {
		throw new MalformedMcpConfigError(
			"read",
			`Failed to read MCP config at ${path}: ${errorMessage(err)}`,
			err,
		);
	}

	let parsed: unknown;
	try {
		parsed = JSON.parse(raw);
	} catch (err) {
		throw new MalformedMcpConfigError(
			"parse",
			`MCP config file ${path} is not valid JSON: ${errorMessage(err)}`,
			err,
		);
	}

	return parseMcpConfig(parsed, path);
}

export function addMcpServerConfig(input: AddMcpServerConfigInput): McpConfig {
	const serverId = nonEmptyString(input.serverId, "MCP server id");
	if (!/^[A-Za-z0-9_-]+$/.test(serverId)) {
		throw schemaError(`MCP server id "${serverId}" must match [A-Za-z0-9_-]+`);
	}
	const path = mcpConfigPath();
	const rawRoot = readRawMcpConfig(path);
	const servers = objectRecord(rawRoot.servers ?? {}, `MCP config "servers"`);
	if (Object.hasOwn(servers, serverId)) {
		throw schemaError(`MCP server "${serverId}" already exists`);
	}
	servers[serverId] = buildRawServerConfig(input);
	rawRoot.servers = servers;
	const parsed = parseMcpConfig(rawRoot, path);
	writeRawMcpConfig(path, rawRoot);
	return parsed;
}

export function getMcpServerConfig(serverId: string): McpServerConfigEditInfo {
	if (!/^[A-Za-z0-9_-]+$/.test(serverId)) {
		throw schemaError(`MCP server id "${serverId}" must match [A-Za-z0-9_-]+`);
	}
	const path = mcpConfigPath();
	const rawRoot = readRawMcpConfig(path);
	const servers = objectRecord(rawRoot.servers ?? {}, `MCP config "servers"`);
	const rawServer = servers[serverId];
	if (rawServer === undefined) {
		throw schemaError(`Unknown MCP server "${serverId}"`);
	}
	parseMcpConfig(rawRoot, path);
	return rawServerConfigToEditInfo(serverId, rawServer);
}

export function updateMcpServerConfig(
	input: UpdateMcpServerConfigInput,
): McpConfig {
	const serverId = nonEmptyString(input.serverId, "MCP server id");
	if (!/^[A-Za-z0-9_-]+$/.test(serverId)) {
		throw schemaError(`MCP server id "${serverId}" must match [A-Za-z0-9_-]+`);
	}
	const path = mcpConfigPath();
	const rawRoot = readRawMcpConfig(path);
	const servers = objectRecord(rawRoot.servers ?? {}, `MCP config "servers"`);
	const existing = servers[serverId];
	if (existing === undefined) {
		throw schemaError(`Unknown MCP server "${serverId}"`);
	}
	servers[serverId] = buildRawServerConfig(input, existing);
	rawRoot.servers = servers;
	const parsed = parseMcpConfig(rawRoot, path);
	writeRawMcpConfig(path, rawRoot);
	return parsed;
}

export function deleteMcpServerConfig(serverId: string): McpConfig {
	if (!/^[A-Za-z0-9_-]+$/.test(serverId)) {
		throw schemaError(`MCP server id "${serverId}" must match [A-Za-z0-9_-]+`);
	}
	const path = mcpConfigPath();
	const rawRoot = readRawMcpConfig(path);
	const servers = objectRecord(rawRoot.servers ?? {}, `MCP config "servers"`);
	if (!Object.hasOwn(servers, serverId)) {
		throw schemaError(`Unknown MCP server "${serverId}"`);
	}
	delete servers[serverId];
	rawRoot.servers = servers;
	const parsed = parseMcpConfig(rawRoot, path);
	writeRawMcpConfig(path, rawRoot);
	return parsed;
}

function parseMcpConfig(value: unknown, path: string): McpConfig {
	const root = objectRecord(value, `MCP config file ${path}`);
	const serversValue = root.servers ?? {};
	const serversObject = objectRecord(serversValue, `MCP config "servers"`);
	const servers: Record<string, McpServerConfig> = {};
	for (const [serverId, serverValue] of Object.entries(serversObject)) {
		if (!/^[A-Za-z0-9_-]+$/.test(serverId)) {
			throw schemaError(
				`MCP server id "${serverId}" must match [A-Za-z0-9_-]+`,
			);
		}
		servers[serverId] = parseServerConfig(serverId, serverValue);
	}
	return { servers };
}

function buildRawServerConfig(
	input: AddMcpServerConfigInput,
	existingRawServer?: unknown,
): Record<string, unknown> {
	const description = nonEmptyString(
		input.description,
		"MCP server description",
	);
	const server: Record<string, unknown> = { description };
	if (input.autoConnect === true) server.autoConnect = true;
	if (input.transportType === "stdio") {
		if (
			input.url !== undefined ||
			input.headers !== undefined ||
			input.authType === "headers" ||
			input.authType === "oauth"
		) {
			throw schemaError(
				"MCP stdio server cannot include url, headers, or auth",
			);
		}
		return {
			...server,
			transport: {
				type: "stdio",
				command: nonEmptyString(input.command, "MCP stdio command"),
				args: input.args ?? [],
				env: input.env ?? {},
			},
		};
	}
	if (input.transportType === "streamableHttp") {
		if (
			input.command !== undefined ||
			input.args !== undefined ||
			input.env !== undefined
		) {
			throw schemaError(
				"MCP streamableHttp server cannot include command, args, or env",
			);
		}
		const transport: Record<string, unknown> = {
			type: "streamableHttp",
			url: nonEmptyString(input.url, "MCP streamableHttp url"),
		};
		const existingAuth = existingStreamableHttpAuth(existingRawServer);
		const authType =
			input.authType ?? (existingAuth === undefined ? "headers" : "oauth");
		if (authType === "oauth") {
			transport.headers = input.headers ?? {};
			transport.auth = existingAuth ?? {
				type: "oauth",
				registration: { type: "dynamic" },
			};
		} else if (authType === "headers") {
			transport.headers = input.headers ?? {};
		} else if (authType === "none") {
			if (
				input.headers !== undefined &&
				Object.keys(input.headers).length > 0
			) {
				throw schemaError(
					"MCP streamableHttp authType none cannot include headers",
				);
			}
			transport.headers = {};
		} else {
			throw schemaError(
				`MCP streamableHttp authType must be "none", "headers", or "oauth"`,
			);
		}
		return { ...server, transport };
	}
	throw schemaError(`MCP transport type must be "stdio" or "streamableHttp"`);
}

function rawServerConfigToEditInfo(
	serverId: string,
	value: unknown,
): McpServerConfigEditInfo {
	const server = objectRecord(value, `MCP server "${serverId}"`);
	const description = nonEmptyString(
		server.description,
		`MCP server "${serverId}" description`,
	);
	const autoConnect = optionalBoolean(
		server.autoConnect,
		`MCP server "${serverId}" autoConnect`,
	);
	const transport = objectRecord(
		server.transport,
		`MCP server "${serverId}" transport`,
	);
	if (transport.type === "stdio") {
		return {
			serverId,
			description,
			...(autoConnect === true ? { autoConnect } : {}),
			transportType: "stdio",
			command: nonEmptyString(
				transport.command,
				`MCP server "${serverId}" stdio command`,
			),
			args: optionalStringArray(
				transport.args,
				`MCP server "${serverId}" stdio args`,
			),
			env: optionalStringMap(
				transport.env,
				`MCP server "${serverId}" stdio env`,
			),
		};
	}
	if (transport.type === "streamableHttp") {
		const headers = optionalStringMap(
			transport.headers,
			`MCP server "${serverId}" streamableHttp headers`,
		);
		return {
			serverId,
			description,
			...(autoConnect === true ? { autoConnect } : {}),
			transportType: "streamableHttp",
			authType:
				transport.auth === undefined
					? Object.keys(headers).length === 0
						? "none"
						: "headers"
					: "oauth",
			url: nonEmptyString(
				transport.url,
				`MCP server "${serverId}" streamableHttp url`,
			),
			headers,
		};
	}
	throw schemaError(
		`MCP server "${serverId}" transport type must be "stdio" or "streamableHttp"`,
	);
}

function existingStreamableHttpAuth(existingRawServer: unknown): unknown {
	if (existingRawServer === undefined) return undefined;
	const server = objectRecord(existingRawServer, "Existing MCP server");
	const transport = objectRecord(
		server.transport,
		"Existing MCP server transport",
	);
	if (transport.type !== "streamableHttp") return undefined;
	return transport.auth;
}

function readRawMcpConfig(path: string): Record<string, unknown> {
	if (!existsSync(path)) return { servers: {} };
	let raw: string;
	try {
		raw = readFileSync(path, "utf-8");
	} catch (err) {
		throw new MalformedMcpConfigError(
			"read",
			`Failed to read MCP config at ${path}: ${errorMessage(err)}`,
			err,
		);
	}
	let parsed: unknown;
	try {
		parsed = JSON.parse(raw);
	} catch (err) {
		throw new MalformedMcpConfigError(
			"parse",
			`MCP config file ${path} is not valid JSON: ${errorMessage(err)}`,
			err,
		);
	}
	return objectRecord(parsed, `MCP config file ${path}`);
}

function writeRawMcpConfig(path: string, root: Record<string, unknown>): void {
	mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
	const tmp = join(dirname(path), `.${basename(path)}.${randomUUID()}.tmp`);
	writeFileSync(tmp, `${JSON.stringify(root, null, 2)}\n`, {
		mode: 0o600,
	});
	renameSync(tmp, path);
}

function parseServerConfig(serverId: string, value: unknown): McpServerConfig {
	const server = objectRecord(value, `MCP server "${serverId}"`);
	const description = nonEmptyString(
		server.description,
		`MCP server "${serverId}" description`,
	);
	const autoConnect = optionalBoolean(
		server.autoConnect,
		`MCP server "${serverId}" autoConnect`,
	);
	const transport = parseTransportConfig(serverId, server.transport);
	return {
		description,
		...(autoConnect === true ? { autoConnect } : {}),
		transport,
	};
}

function parseTransportConfig(
	serverId: string,
	value: unknown,
): McpTransportConfig {
	const transport = objectRecord(value, `MCP server "${serverId}" transport`);
	if (transport.type === "stdio") {
		if (transport.auth !== undefined) {
			throw schemaError(
				`MCP server "${serverId}" stdio transport does not support OAuth auth`,
			);
		}
		return {
			type: "stdio",
			command: nonEmptyString(
				transport.command,
				`MCP server "${serverId}" stdio command`,
			),
			args: optionalStringArray(
				transport.args,
				`MCP server "${serverId}" stdio args`,
			),
			env: resolveStringMap(
				optionalStringMap(transport.env, `MCP server "${serverId}" stdio env`),
				`MCP server "${serverId}" stdio env`,
			),
		};
	}
	if (transport.type === "streamableHttp") {
		const url = nonEmptyString(
			transport.url,
			`MCP server "${serverId}" streamableHttp url`,
		);
		try {
			new URL(url);
		} catch (err) {
			throw schemaError(
				`MCP server "${serverId}" streamableHttp url must be a valid URL: ${errorMessage(err)}`,
			);
		}
		const headers = resolveStringMap(
			optionalStringMap(
				transport.headers,
				`MCP server "${serverId}" streamableHttp headers`,
			),
			`MCP server "${serverId}" streamableHttp headers`,
		);
		const auth =
			transport.auth === undefined
				? undefined
				: parseMcpOAuthAuthConfig(
						transport.auth,
						`MCP server "${serverId}" streamableHttp auth`,
						{
							objectRecord,
							nonEmptyString,
							resolveEnvReference,
							schemaError,
						},
					);
		if (auth && hasAuthorizationHeader(headers)) {
			throw schemaError(
				`MCP server "${serverId}" streamableHttp headers.Authorization cannot be used with OAuth auth`,
			);
		}
		return {
			type: "streamableHttp",
			url,
			headers,
			auth,
		};
	}
	throw schemaError(
		`MCP server "${serverId}" transport type must be "stdio" or "streamableHttp"`,
	);
}

function objectRecord(value: unknown, label: string): Record<string, unknown> {
	if (value === null || typeof value !== "object" || Array.isArray(value)) {
		throw schemaError(`${label} must be a JSON object`);
	}
	return value as Record<string, unknown>;
}

function nonEmptyString(value: unknown, label: string): string {
	if (typeof value !== "string" || value.length === 0) {
		throw schemaError(`${label} must be a non-empty string`);
	}
	return value;
}

function optionalStringArray(value: unknown, label: string): string[] {
	if (value === undefined) return [];
	if (!Array.isArray(value) || value.some((item) => typeof item !== "string")) {
		throw schemaError(`${label} must be an array of strings`);
	}
	return [...value];
}

function optionalBoolean(value: unknown, label: string): boolean | undefined {
	if (value === undefined) return undefined;
	if (typeof value !== "boolean") {
		throw schemaError(`${label} must be a boolean`);
	}
	return value;
}

function optionalStringMap(
	value: unknown,
	label: string,
): Record<string, string> {
	if (value === undefined) return {};
	const obj = objectRecord(value, label);
	const out: Record<string, string> = {};
	for (const [key, item] of Object.entries(obj)) {
		if (typeof item !== "string") {
			throw schemaError(`${label}.${key} must be a string`);
		}
		out[key] = item;
	}
	return out;
}

function resolveStringMap(
	map: Record<string, string>,
	label: string,
): Record<string, string> {
	const out: Record<string, string> = {};
	for (const [key, value] of Object.entries(map)) {
		out[key] = resolveEnvReference(value, `${label}.${key}`);
	}
	return out;
}

function resolveEnvReference(value: string, label: string): string {
	const match = value.match(/^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$/);
	if (!value.includes("${")) return value;
	if (!match) {
		throw schemaError(
			`${label} environment interpolation must use the full-string form "\${NAME}"`,
		);
	}
	const envValue = process.env[match[1]];
	if (envValue === undefined) {
		throw schemaError(
			`${label} references missing environment variable ${match[1]}`,
		);
	}
	return envValue;
}

function hasAuthorizationHeader(headers: Record<string, string>): boolean {
	return Object.keys(headers).some(
		(key) => key.toLowerCase() === "authorization",
	);
}

function schemaError(message: string): MalformedMcpConfigError {
	return new MalformedMcpConfigError("schema", message);
}

function errorMessage(err: unknown): string {
	return errorText(err);
}
