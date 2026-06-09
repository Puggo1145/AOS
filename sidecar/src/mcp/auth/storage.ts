import {
	existsSync,
	mkdirSync,
	readFileSync,
	renameSync,
	rmSync,
	writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";
import { randomUUID } from "node:crypto";
import type {
	OAuthClientInformationMixed,
	OAuthDiscoveryState,
	OAuthTokens,
} from "@modelcontextprotocol/client";
import { McpAuthError } from "./errors";

export interface McpOAuthTokenRecord {
	accessToken: string;
	refreshToken?: string;
	expiresAt?: number;
	tokenType: "Bearer";
	scopes: string[];
	resource: string;
	authorizationServerUrl: string;
}

export type McpOAuthClientRecord = OAuthClientInformationMixed;

export interface McpOAuthVerifierRecord {
	codeVerifier: string;
	state: string;
	redirectUri: string;
	resource: string;
	scope?: string;
	authorizationServerUrl?: string;
}

export interface McpOAuthDiscoveryRecord extends Partial<OAuthDiscoveryState> {
	authorizationServerUrl: string;
	resource?: string;
}

export interface McpOAuthStorageOptions {
	homeDir?: string;
}

export interface McpOAuthServerPaths {
	dir: string;
	tokens: string;
	client: string;
	verifier: string;
	discovery: string;
}

export class McpOAuthStorage {
	private readonly homeDir: string;

	constructor(options: McpOAuthStorageOptions = {}) {
		this.homeDir =
			options.homeDir ??
			(process.env.HOME && process.env.HOME.length > 0
				? process.env.HOME
				: homedir());
	}

	paths(serverId: string): McpOAuthServerPaths {
		const dir = join(this.homeDir, ".notch-agent", "auth", "mcp", serverId);
		return {
			dir,
			tokens: join(dir, "tokens.json"),
			client: join(dir, "client.json"),
			verifier: join(dir, "verifier.json"),
			discovery: join(dir, "discovery.json"),
		};
	}

	readTokens(
		serverId: string,
		options: { passive?: boolean } = {},
	): McpOAuthTokenRecord | null {
		return this.readJson(serverId, "tokens", options, isTokenRecord);
	}

	writeTokens(serverId: string, record: McpOAuthTokenRecord): void {
		this.writeJson(serverId, "tokens", record);
	}

	readClient(
		serverId: string,
		options: { passive?: boolean } = {},
	): McpOAuthClientRecord | null {
		return this.readJson(serverId, "client", options, isClientRecord);
	}

	writeClient(serverId: string, record: McpOAuthClientRecord): void {
		this.writeJson(serverId, "client", record);
	}

	readVerifier(
		serverId: string,
		options: { passive?: boolean } = {},
	): McpOAuthVerifierRecord | null {
		return this.readJson(serverId, "verifier", options, isVerifierRecord);
	}

	writeVerifier(serverId: string, record: McpOAuthVerifierRecord): void {
		this.writeJson(serverId, "verifier", record);
	}

	readDiscovery(
		serverId: string,
		options: { passive?: boolean } = {},
	): McpOAuthDiscoveryRecord | null {
		return this.readJson(serverId, "discovery", options, isDiscoveryRecord);
	}

	writeDiscovery(serverId: string, record: McpOAuthDiscoveryRecord): void {
		this.writeJson(serverId, "discovery", record);
	}

	clearServerAuth(serverId: string): boolean {
		const paths = this.paths(serverId);
		let cleared = false;
		for (const path of [
			paths.tokens,
			paths.client,
			paths.verifier,
			paths.discovery,
		]) {
			try {
				rmSync(path);
				cleared = true;
			} catch (err) {
				if ((err as NodeJS.ErrnoException).code !== "ENOENT") throw err;
			}
		}
		return cleared;
	}

	clearScope(
		serverId: string,
		scope: "all" | "client" | "tokens" | "verifier" | "discovery",
	): void {
		if (scope === "all") {
			this.clearServerAuth(serverId);
			return;
		}
		const path = this.paths(serverId)[scope];
		try {
			rmSync(path);
		} catch (err) {
			if ((err as NodeJS.ErrnoException).code !== "ENOENT") throw err;
		}
	}

	toSdkTokens(record: McpOAuthTokenRecord): OAuthTokens {
		const tokens: OAuthTokens = {
			access_token: record.accessToken,
			token_type: record.tokenType,
			scope: record.scopes.join(" "),
		};
		if (record.refreshToken) tokens.refresh_token = record.refreshToken;
		if (record.expiresAt) {
			tokens.expires_in = Math.max(
				0,
				Math.floor((record.expiresAt - Date.now()) / 1000),
			);
		}
		return tokens;
	}

	fromSdkTokens(
		tokens: OAuthTokens,
		input: {
			resource: string;
			authorizationServerUrl: string;
			scope?: string;
		},
	): McpOAuthTokenRecord {
		const expiresIn =
			typeof tokens.expires_in === "number" ? tokens.expires_in : undefined;
		return {
			accessToken: tokens.access_token,
			refreshToken: tokens.refresh_token,
			expiresAt:
				expiresIn === undefined ? undefined : Date.now() + expiresIn * 1000,
			tokenType: "Bearer",
			scopes: scopeList(tokens.scope ?? input.scope),
			resource: input.resource,
			authorizationServerUrl: input.authorizationServerUrl,
		};
	}

	private readJson<T>(
		serverId: string,
		kind: keyof Omit<McpOAuthServerPaths, "dir">,
		options: { passive?: boolean },
		validate: (value: unknown) => value is T,
	): T | null {
		const path = this.paths(serverId)[kind];
		if (!existsSync(path)) return null;
		let parsed: unknown;
		try {
			parsed = JSON.parse(readFileSync(path, "utf-8"));
		} catch (err) {
			if (options.passive) return null;
			throw new McpAuthError(
				`Malformed MCP OAuth ${kind} file for server "${serverId}": ${err instanceof Error ? err.message : String(err)}`,
			);
		}
		if (!validate(parsed)) {
			if (options.passive) return null;
			throw new McpAuthError(
				`Malformed MCP OAuth ${kind} file for server "${serverId}"`,
			);
		}
		return parsed;
	}

	private writeJson(
		serverId: string,
		kind: keyof Omit<McpOAuthServerPaths, "dir">,
		value: unknown,
	): void {
		const paths = this.paths(serverId);
		mkdirSync(paths.dir, { recursive: true, mode: 0o700 });
		const path = paths[kind];
		const tmp = join(dirname(path), `.${basename(path)}.${randomUUID()}.tmp`);
		writeFileSync(tmp, `${JSON.stringify(value, null, 2)}\n`, {
			mode: 0o600,
		});
		renameSync(tmp, path);
	}
}

function isTokenRecord(value: unknown): value is McpOAuthTokenRecord {
	const obj = record(value);
	return (
		obj !== null &&
		typeof obj.accessToken === "string" &&
		(obj.refreshToken === undefined || typeof obj.refreshToken === "string") &&
		(obj.expiresAt === undefined || typeof obj.expiresAt === "number") &&
		obj.tokenType === "Bearer" &&
		Array.isArray(obj.scopes) &&
		obj.scopes.every((scope) => typeof scope === "string") &&
		typeof obj.resource === "string" &&
		typeof obj.authorizationServerUrl === "string"
	);
}

function isClientRecord(value: unknown): value is McpOAuthClientRecord {
	const obj = record(value);
	return obj !== null && typeof obj.client_id === "string";
}

function isVerifierRecord(value: unknown): value is McpOAuthVerifierRecord {
	const obj = record(value);
	return (
		obj !== null &&
		typeof obj.codeVerifier === "string" &&
		typeof obj.state === "string" &&
		typeof obj.redirectUri === "string" &&
		typeof obj.resource === "string" &&
		(obj.scope === undefined || typeof obj.scope === "string")
	);
}

function isDiscoveryRecord(value: unknown): value is McpOAuthDiscoveryRecord {
	const obj = record(value);
	return obj !== null && typeof obj.authorizationServerUrl === "string";
}

function record(value: unknown): Record<string, unknown> | null {
	if (value === null || typeof value !== "object" || Array.isArray(value)) {
		return null;
	}
	return value as Record<string, unknown>;
}

function scopeList(scope: string | undefined): string[] {
	if (!scope) return [];
	return scope
		.split(/\s+/)
		.map((part) => part.trim())
		.filter((part) => part.length > 0);
}
