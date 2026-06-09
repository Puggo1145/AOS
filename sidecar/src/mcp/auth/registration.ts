import type {
	AuthorizationServerMetadata,
	FetchLike,
	OAuthClientInformationMixed,
	OAuthClientMetadata,
} from "@modelcontextprotocol/client";
import type { McpOAuthAuthConfig } from "./config";
import { McpAuthError } from "./errors";
import type { McpOAuthStorage } from "./storage";

export async function resolveClientRegistration(input: {
	serverId: string;
	authConfig: McpOAuthAuthConfig;
	authorizationServerMetadata: AuthorizationServerMetadata;
	storage: McpOAuthStorage;
	fetch: FetchLike;
	redirectUri: string;
	scope?: string;
	signal?: AbortSignal;
}): Promise<OAuthClientInformationMixed> {
	const cached = input.storage.readClient(input.serverId, { passive: true });
	if (cached) return cached;

	const registration = input.authConfig.registration;
	if (registration.type === "preRegistered") {
		const info: OAuthClientInformationMixed = {
			client_id: registration.clientId,
		};
		if (registration.clientSecret)
			info.client_secret = registration.clientSecret;
		input.storage.writeClient(input.serverId, info);
		return info;
	}

	if (registration.type === "clientIdMetadataDocument") {
		if (
			input.authorizationServerMetadata
				.client_id_metadata_document_supported !== true
		) {
			throw new McpAuthError(
				"Authorization server does not support Client ID Metadata Documents",
			);
		}
		const info: OAuthClientInformationMixed = {
			client_id: registration.clientId,
			redirect_uris: [input.redirectUri],
			client_name: "Notch Agent",
		};
		input.storage.writeClient(input.serverId, info);
		return info;
	}

	if (registration.type === "dynamic") {
		const endpoint = input.authorizationServerMetadata.registration_endpoint;
		if (typeof endpoint === "string" && endpoint.length > 0) {
			const info = await dynamicRegister({
				endpoint,
				fetch: input.fetch,
				redirectUri: input.redirectUri,
				scope: input.scope,
				signal: input.signal,
			});
			input.storage.writeClient(input.serverId, info);
			return info;
		}
	}

	throw new McpAuthError(
		"MCP OAuth requires user-provided client information; no automatic registration path is available",
	);
}

function clientMetadata(
	redirectUri: string,
	scope: string | undefined,
): OAuthClientMetadata {
	return {
		redirect_uris: [redirectUri],
		client_name: "Notch Agent",
		grant_types: ["authorization_code", "refresh_token"],
		response_types: ["code"],
		token_endpoint_auth_method: "none",
		...(scope ? { scope } : {}),
	};
}

async function dynamicRegister(input: {
	endpoint: string;
	fetch: FetchLike;
	redirectUri: string;
	scope?: string;
	signal?: AbortSignal;
}): Promise<OAuthClientInformationMixed> {
	const response = await input.fetch(input.endpoint, {
		method: "POST",
		headers: { "content-type": "application/json", accept: "application/json" },
		body: JSON.stringify(clientMetadata(input.redirectUri, input.scope)),
		signal: input.signal,
	});
	if (!response.ok) {
		throw new McpAuthError(
			`Dynamic MCP OAuth client registration failed with HTTP ${response.status}`,
		);
	}
	const info = (await response.json()) as OAuthClientInformationMixed;
	if (typeof info.client_id !== "string" || info.client_id.length === 0) {
		throw new McpAuthError(
			"Dynamic MCP OAuth registration response lacks client_id",
		);
	}
	return info;
}
