import type {
	OAuthClientInformationMixed,
	OAuthClientMetadata,
	OAuthClientProvider,
	OAuthDiscoveryState,
	OAuthTokens,
} from "@modelcontextprotocol/client";
import type { McpOAuthAuthConfig } from "./config";
import { McpAuthError } from "./errors";
import {
	canonicalMcpResourceUri,
	validateConfiguredResource,
} from "./resource";
import type { McpOAuthStorage } from "./storage";

export type McpLoginStatusState =
	| "starting"
	| "awaitingBrowser"
	| "awaitingCallback"
	| "exchanging"
	| "success"
	| "failed"
	| "cancelled";

export interface McpLoginStatusNotification {
	loginId: string;
	serverId: string;
	state: McpLoginStatusState;
	authorizeUrl?: string;
	message?: string;
}

export interface McpStatusChangedNotification {
	serverId: string;
	state: "unauthenticated" | "authenticating" | "ready" | "failed";
	reason?:
		| "loginRequired"
		| "authInvalidated"
		| "insufficientScope"
		| "loggedOut";
	message?: string;
}

export interface NotchMcpOAuthProviderInput {
	serverId: string;
	serverUrl: string;
	authConfig: McpOAuthAuthConfig;
	storage: McpOAuthStorage;
	redirectUrl: string;
	state?: string;
	loginId?: string;
	scope?: string;
	notifyLoginStatus?(params: McpLoginStatusNotification): void;
	notifyStatusChanged?(params: McpStatusChangedNotification): void;
}

export class NotchMcpOAuthProvider implements OAuthClientProvider {
	public readonly clientMetadataUrl?: string;
	private readonly serverId: string;
	private readonly serverUrl: string;
	private readonly authConfig: McpOAuthAuthConfig;
	private readonly storage: McpOAuthStorage;
	private readonly redirect: string;
	private readonly oauthState: string;
	private readonly loginId?: string;
	private readonly scope?: string;
	private readonly notifyLoginStatus?: (
		params: McpLoginStatusNotification,
	) => void;
	private readonly notifyStatusChanged?: (
		params: McpStatusChangedNotification,
	) => void;

	constructor(input: NotchMcpOAuthProviderInput) {
		this.serverId = input.serverId;
		this.serverUrl = input.serverUrl;
		this.authConfig = input.authConfig;
		this.storage = input.storage;
		this.redirect = input.redirectUrl;
		this.oauthState = input.state ?? crypto.randomUUID();
		this.loginId = input.loginId;
		this.scope = input.scope;
		this.notifyLoginStatus = input.notifyLoginStatus;
		this.notifyStatusChanged = input.notifyStatusChanged;
		if (input.authConfig.registration.type === "clientIdMetadataDocument") {
			this.clientMetadataUrl = input.authConfig.registration.clientId;
		}
	}

	get redirectUrl(): string {
		return this.redirect;
	}

	get clientMetadata(): OAuthClientMetadata {
		return {
			redirect_uris: [this.redirect],
			client_name: "Notch Agent",
			grant_types: ["authorization_code", "refresh_token"],
			response_types: ["code"],
			token_endpoint_auth_method: clientAuthMethod(this.authConfig),
			...(this.scope ? { scope: this.scope } : {}),
		};
	}

	state(): string {
		return this.oauthState;
	}

	clientInformation(): OAuthClientInformationMixed | undefined {
		const configured = this.configuredClientInformation();
		if (configured) return configured;
		return (
			this.storage.readClient(this.serverId, { passive: true }) ?? undefined
		);
	}

	saveClientInformation(clientInformation: OAuthClientInformationMixed): void {
		this.storage.writeClient(this.serverId, clientInformation);
	}

	tokens(): OAuthTokens | undefined {
		const record = this.storage.readTokens(this.serverId, { passive: true });
		return record ? this.storage.toSdkTokens(record) : undefined;
	}

	saveTokens(tokens: OAuthTokens): void {
		const discovery = this.storage.readDiscovery(this.serverId, {
			passive: true,
		});
		this.storage.writeTokens(
			this.serverId,
			this.storage.fromSdkTokens(tokens, {
				resource:
					discovery?.resource ??
					this.authConfig.resource ??
					canonicalMcpResourceUri(this.serverUrl),
				authorizationServerUrl:
					discovery?.authorizationServerUrl ?? this.serverUrl,
				scope: this.scope,
			}),
		);
	}

	redirectToAuthorization(authorizationUrl: URL): void {
		if (!this.loginId || !this.notifyLoginStatus) return;
		this.notifyLoginStatus({
			loginId: this.loginId,
			serverId: this.serverId,
			state: "awaitingBrowser",
			authorizeUrl: authorizationUrl.toString(),
		});
	}

	saveCodeVerifier(codeVerifier: string): void {
		const discovery = this.storage.readDiscovery(this.serverId, {
			passive: true,
		});
		this.storage.writeVerifier(this.serverId, {
			codeVerifier,
			state: this.oauthState,
			redirectUri: this.redirect,
			resource:
				discovery?.resource ??
				this.authConfig.resource ??
				canonicalMcpResourceUri(this.serverUrl),
			scope: this.scope,
			authorizationServerUrl: discovery?.authorizationServerUrl,
		});
	}

	codeVerifier(): string {
		const verifier = this.storage.readVerifier(this.serverId);
		if (!verifier) {
			throw new McpAuthError(
				`MCP OAuth code verifier missing for server "${this.serverId}"`,
			);
		}
		return verifier.codeVerifier;
	}

	async validateResourceURL(
		serverUrl: string | URL,
		resource?: string,
	): Promise<URL | undefined> {
		const configured =
			this.authConfig.resource ??
			resource ??
			canonicalMcpResourceUri(serverUrl.toString());
		return new URL(
			validateConfiguredResource(serverUrl.toString(), configured),
		);
	}

	invalidateCredentials(
		scope: "all" | "client" | "tokens" | "verifier" | "discovery",
	): void {
		this.storage.clearScope(this.serverId, scope);
		this.notifyStatusChanged?.({
			serverId: this.serverId,
			state: "unauthenticated",
			reason: "authInvalidated",
		});
	}

	saveAuthorizationServerUrl(authorizationServerUrl: string): void {
		const current = this.storage.readDiscovery(this.serverId, {
			passive: true,
		});
		this.storage.writeDiscovery(this.serverId, {
			...current,
			authorizationServerUrl,
		});
	}

	authorizationServerUrl(): string | undefined {
		return (
			this.storage.readDiscovery(this.serverId, { passive: true })
				?.authorizationServerUrl ?? undefined
		);
	}

	saveResourceUrl(resourceUrl: string): void {
		const current = this.storage.readDiscovery(this.serverId, {
			passive: true,
		});
		this.storage.writeDiscovery(this.serverId, {
			authorizationServerUrl:
				current?.authorizationServerUrl ??
				canonicalMcpResourceUri(this.serverUrl),
			...current,
			resource: resourceUrl,
		});
	}

	resourceUrl(): string | undefined {
		return (
			this.storage.readDiscovery(this.serverId, { passive: true })?.resource ??
			undefined
		);
	}

	saveDiscoveryState(state: OAuthDiscoveryState): void {
		this.storage.writeDiscovery(this.serverId, {
			...state,
			resource: state.resourceMetadata?.resource,
		});
	}

	discoveryState(): OAuthDiscoveryState | undefined {
		const state = this.storage.readDiscovery(this.serverId, { passive: true });
		if (!state) return undefined;
		return {
			authorizationServerUrl: state.authorizationServerUrl,
			resourceMetadataUrl: state.resourceMetadataUrl,
			resourceMetadata: state.resourceMetadata,
			authorizationServerMetadata: state.authorizationServerMetadata,
		};
	}

	private configuredClientInformation():
		| OAuthClientInformationMixed
		| undefined {
		const registration = this.authConfig.registration;
		if (registration.type !== "preRegistered") return undefined;
		const info: OAuthClientInformationMixed = {
			client_id: registration.clientId,
		};
		if (registration.clientSecret)
			info.client_secret = registration.clientSecret;
		return info;
	}
}

function clientAuthMethod(config: McpOAuthAuthConfig): string {
	return config.registration.type === "preRegistered" &&
		config.registration.clientSecret
		? "client_secret_basic"
		: "none";
}
