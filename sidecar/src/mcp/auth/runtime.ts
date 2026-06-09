import { randomUUID } from "node:crypto";
import {
	auth,
	type AuthResult,
	type FetchLike,
	type OAuthClientProvider,
} from "@modelcontextprotocol/client";
import {
	RPCMethod,
	type McpAuthCancelLoginParams,
	type McpAuthCancelLoginResult,
	type McpAuthLogoutParams,
	type McpAuthLogoutResult,
	type McpAuthStartLoginParams,
	type McpAuthStartLoginResult,
	type McpAuthStatusResult,
} from "../../rpc/rpc-types";
import {
	AbortError,
	startCallbackServer,
	type LoopbackHandle,
} from "../../auth/loopback";
import type { McpConfig, McpServerConfig } from "../config";
import { McpAuthError } from "./errors";
import { NotchMcpOAuthProvider } from "./provider";
import type { McpOAuthStorage } from "./storage";

const DEFAULT_CALLBACK_PATH = "/mcp/oauth/callback";

export type McpAuthRunAuth = (
	provider: OAuthClientProvider,
	options: {
		serverUrl: string;
		authorizationCode?: string;
		scope?: string;
		fetchFn?: FetchLike;
	},
) => Promise<AuthResult>;

export interface McpAuthRuntimeOptions {
	config: McpConfig;
	storage: McpOAuthStorage;
	notify?(method: string, params: object): void;
	runAuth?: McpAuthRunAuth;
	fetchFn?: FetchLike;
}

interface LoginSession {
	loginId: string;
	serverId: string;
	controller: AbortController;
	handle: LoopbackHandle;
	done: boolean;
	completion: Promise<void>;
	resolveCompletion(): void;
	rejectCompletion(err: unknown): void;
}

export class McpAuthRuntime {
	private readonly config: McpConfig;
	private readonly storage: McpOAuthStorage;
	private readonly notify?: (method: string, params: object) => void;
	private readonly runAuth: McpAuthRunAuth;
	private readonly fetchFn?: FetchLike;
	private readonly inflight = new Map<string, LoginSession>();

	constructor(options: McpAuthRuntimeOptions) {
		this.config = options.config;
		this.storage = options.storage;
		this.notify = options.notify;
		this.runAuth =
			options.runAuth ??
			((provider, authOptions) =>
				auth(provider, {
					serverUrl: authOptions.serverUrl,
					authorizationCode: authOptions.authorizationCode,
					scope: authOptions.scope,
					fetchFn: authOptions.fetchFn,
				}));
		this.fetchFn = options.fetchFn;
	}

	status(): McpAuthStatusResult {
		return {
			servers: Object.entries(this.config.servers).map(([serverId, server]) => {
				if (server.transport.type === "stdio") {
					return { serverId, state: "notConfigured", authType: "none" };
				}
				if (!server.transport.auth) {
					const hasHeaders = Object.keys(server.transport.headers).length > 0;
					return {
						serverId,
						state: hasHeaders ? "ready" : "notConfigured",
						authType: hasHeaders ? "headers" : "none",
					};
				}
				const token = this.storage.readTokens(serverId, { passive: true });
				const discovery = this.storage.readDiscovery(serverId, {
					passive: true,
				});
				return {
					serverId,
					state: token ? "ready" : "unauthenticated",
					authType: "oauth",
					authorizationServerUrl: discovery?.authorizationServerUrl,
					resource: token?.resource ?? discovery?.resource,
					scopes: token?.scopes,
				};
			}),
		};
	}

	async startLogin(
		params: McpAuthStartLoginParams,
	): Promise<McpAuthStartLoginResult> {
		const server = this.oauthServer(params.serverId);
		if (this.inflight.has(params.serverId)) {
			throw new McpAuthError(
				`MCP OAuth login already in progress for "${params.serverId}"`,
			);
		}
		const loginId = randomUUID();
		const controller = new AbortController();
		const state = randomUUID();
		const redirect = redirectConfig(server);
		const handle = await startCallbackServer({
			expectedState: state,
			signal: controller.signal,
			host: redirect.host,
			port: redirect.port,
			path: redirect.path,
		});
		handle.codePromise.catch(() => {});
		const redirectUrl = `http://${redirect.host}:${handle.port}${redirect.path}`;
		let resolveCompletion!: () => void;
		let rejectCompletion!: (err: unknown) => void;
		const completion = new Promise<void>((resolve, reject) => {
			resolveCompletion = resolve;
			rejectCompletion = reject;
		});
		completion.catch(() => {});
		const session: LoginSession = {
			loginId,
			serverId: params.serverId,
			controller,
			handle,
			done: false,
			completion,
			resolveCompletion,
			rejectCompletion,
		};
		this.inflight.set(params.serverId, session);
		this.notify?.(RPCMethod.mcpAuthLoginStatus, {
			loginId,
			serverId: params.serverId,
			state: "starting",
		});
		let authorizeUrl: string | undefined;
		const provider = new NotchMcpOAuthProvider({
			serverId: params.serverId,
			serverUrl: server.transport.url,
			authConfig: server.transport.auth,
			storage: this.storage,
			redirectUrl,
			state,
			loginId,
			scope: params.scope,
			notifyLoginStatus: (notification) => {
				if (notification.authorizeUrl) authorizeUrl = notification.authorizeUrl;
				this.notify?.(RPCMethod.mcpAuthLoginStatus, notification);
			},
			notifyStatusChanged: (notification) => {
				this.notify?.(RPCMethod.mcpAuthStatusChanged, notification);
			},
		});
		try {
			await this.runAuth(provider, {
				serverUrl: server.transport.url,
				scope: params.scope,
				fetchFn: this.fetchFn,
			});
			if (!authorizeUrl) {
				throw new McpAuthError(
					"MCP OAuth auth flow did not produce authorizeUrl",
				);
			}
		} catch (err) {
			this.finishBeforeRedirectFailure(session, err);
			throw err;
		}
		void this.finishLogin(
			session,
			provider,
			server.transport.url,
			params.scope,
		);
		return { loginId, authorizeUrl };
	}

	async startStepUp(input: {
		serverId: string;
		operation: string;
		scope: string;
	}): Promise<void> {
		this.notify?.(RPCMethod.mcpAuthStatusChanged, {
			serverId: input.serverId,
			state: "authenticating",
			reason: "insufficientScope",
			message: `MCP operation ${input.operation} requires scope ${input.scope}`,
		});
		await this.startLogin({ serverId: input.serverId, scope: input.scope });
		const session = this.inflight.get(input.serverId);
		if (!session) {
			throw new McpAuthError(
				`MCP OAuth step-up session missing for "${input.serverId}"`,
			);
		}
		await session.completion;
	}

	cancelLogin(params: McpAuthCancelLoginParams): McpAuthCancelLoginResult {
		const session = Array.from(this.inflight.values()).find(
			(candidate) => candidate.loginId === params.loginId,
		);
		if (!session || session.done) return { cancelled: false };
		session.done = true;
		session.controller.abort();
		session.handle.close();
		this.storage.clearScope(session.serverId, "verifier");
		this.inflight.delete(session.serverId);
		session.rejectCompletion(new AbortError("MCP OAuth login cancelled"));
		this.notify?.(RPCMethod.mcpAuthLoginStatus, {
			loginId: session.loginId,
			serverId: session.serverId,
			state: "cancelled",
		});
		this.notify?.(RPCMethod.mcpAuthStatusChanged, {
			serverId: session.serverId,
			state: "unauthenticated",
		});
		return { cancelled: true };
	}

	logout(params: McpAuthLogoutParams): McpAuthLogoutResult {
		this.oauthServer(params.serverId);
		const cleared = this.storage.clearServerAuth(params.serverId);
		if (cleared) {
			this.notify?.(RPCMethod.mcpAuthStatusChanged, {
				serverId: params.serverId,
				state: "unauthenticated",
				reason: "loggedOut",
			});
		}
		return { cleared };
	}

	addServer(serverId: string, config: McpServerConfig): void {
		if (this.config.servers[serverId]) {
			throw new McpAuthError(`MCP server "${serverId}" already exists`);
		}
		this.config.servers[serverId] = config;
	}

	updateServer(serverId: string, config: McpServerConfig): void {
		const existing = this.config.servers[serverId];
		if (!existing) {
			throw new McpAuthError(`Unknown MCP server "${serverId}"`);
		}
		if (
			config.transport.type !== "streamableHttp" ||
			!config.transport.auth ||
			oauthAuthMaterialChanged(existing, config)
		) {
			const session = this.inflight.get(serverId);
			if (session && !session.done) {
				this.cancelLogin({ loginId: session.loginId });
			}
			this.storage.clearServerAuth(serverId);
		}
		this.config.servers[serverId] = config;
	}

	hasServer(serverId: string): boolean {
		return this.config.servers[serverId] !== undefined;
	}

	removeServer(serverId: string): void {
		const session = this.inflight.get(serverId);
		if (session && !session.done) {
			this.cancelLogin({ loginId: session.loginId });
		}
		this.storage.clearServerAuth(serverId);
		delete this.config.servers[serverId];
	}

	hasTokens(serverId: string): boolean {
		this.oauthServer(serverId);
		return this.storage.readTokens(serverId, { passive: true }) !== null;
	}

	createProviderForSession(serverId: string): OAuthClientProvider {
		const server = this.oauthServer(serverId);
		return new NotchMcpOAuthProvider({
			serverId,
			serverUrl: server.transport.url,
			authConfig: server.transport.auth,
			storage: this.storage,
			redirectUrl: sessionRedirectUrl(server),
			notifyStatusChanged: (notification) => {
				this.notify?.(RPCMethod.mcpAuthStatusChanged, notification);
			},
		});
	}

	private async finishLogin(
		session: LoginSession,
		provider: OAuthClientProvider,
		serverUrl: string,
		scope: string | undefined,
	): Promise<void> {
		try {
			this.notify?.(RPCMethod.mcpAuthLoginStatus, {
				loginId: session.loginId,
				serverId: session.serverId,
				state: "awaitingCallback",
			});
			const code = await session.handle.codePromise;
			if (session.done) return;
			this.notify?.(RPCMethod.mcpAuthLoginStatus, {
				loginId: session.loginId,
				serverId: session.serverId,
				state: "exchanging",
			});
			await this.runAuth(provider, {
				serverUrl,
				authorizationCode: code,
				scope,
				fetchFn: this.fetchFn,
			});
			if (session.done) return;
			session.done = true;
			this.storage.clearScope(session.serverId, "verifier");
			this.notify?.(RPCMethod.mcpAuthLoginStatus, {
				loginId: session.loginId,
				serverId: session.serverId,
				state: "success",
			});
			this.notify?.(RPCMethod.mcpAuthStatusChanged, {
				serverId: session.serverId,
				state: "ready",
			});
			session.resolveCompletion();
		} catch (err) {
			if (session.done || err instanceof AbortError) return;
			session.done = true;
			this.storage.clearScope(session.serverId, "verifier");
			session.rejectCompletion(err);
			this.notify?.(RPCMethod.mcpAuthLoginStatus, {
				loginId: session.loginId,
				serverId: session.serverId,
				state: "failed",
				message: err instanceof Error ? err.message : String(err),
			});
		} finally {
			if (!session.done) {
				session.rejectCompletion(new AbortError("MCP OAuth login ended"));
			}
			session.handle.close();
			this.inflight.delete(session.serverId);
		}
	}

	private finishBeforeRedirectFailure(
		session: LoginSession,
		err: unknown,
	): void {
		if (session.done) return;
		session.done = true;
		session.controller.abort();
		session.handle.close();
		this.storage.clearScope(session.serverId, "verifier");
		this.inflight.delete(session.serverId);
		session.rejectCompletion(err);
		this.notify?.(RPCMethod.mcpAuthLoginStatus, {
			loginId: session.loginId,
			serverId: session.serverId,
			state: "failed",
			message: err instanceof Error ? err.message : String(err),
		});
	}

	private oauthServer(serverId: string): McpServerConfig & {
		transport: Extract<
			McpServerConfig["transport"],
			{ type: "streamableHttp" }
		> & {
			auth: NonNullable<
				Extract<
					McpServerConfig["transport"],
					{ type: "streamableHttp" }
				>["auth"]
			>;
		};
	} {
		const server = this.config.servers[serverId];
		if (!server) throw new McpAuthError(`Unknown MCP server "${serverId}"`);
		if (server.transport.type !== "streamableHttp" || !server.transport.auth) {
			throw new McpAuthError(
				`MCP server "${serverId}" is not configured for OAuth`,
			);
		}
		return server as ReturnType<McpAuthRuntime["oauthServer"]>;
	}
}

function redirectConfig(server: McpServerConfig): {
	host: "127.0.0.1" | "localhost";
	port: number;
	path: string;
} {
	if (server.transport.type !== "streamableHttp" || !server.transport.auth) {
		throw new McpAuthError("MCP OAuth redirect requested for non-OAuth server");
	}
	return {
		host: server.transport.auth.redirect?.host ?? "127.0.0.1",
		port: server.transport.auth.redirect?.port ?? 0,
		path: server.transport.auth.redirect?.path ?? DEFAULT_CALLBACK_PATH,
	};
}

function sessionRedirectUrl(server: McpServerConfig): string {
	const redirect = redirectConfig(server);
	const port = redirect.port === 0 ? 1 : redirect.port;
	return `http://${redirect.host}:${port}${redirect.path}`;
}

function oauthAuthMaterialChanged(
	before: McpServerConfig,
	after: McpServerConfig,
): boolean {
	if (before.transport.type !== "streamableHttp" || !before.transport.auth) {
		return false;
	}
	if (after.transport.type !== "streamableHttp" || !after.transport.auth) {
		return true;
	}
	return oauthAuthMaterialKey(before) !== oauthAuthMaterialKey(after);
}

function oauthAuthMaterialKey(server: McpServerConfig): string {
	if (server.transport.type !== "streamableHttp" || !server.transport.auth) {
		throw new McpAuthError("OAuth auth material requested for non-OAuth server");
	}
	return JSON.stringify({
		url: server.transport.url,
		headers: server.transport.headers,
		auth: server.transport.auth,
	});
}
