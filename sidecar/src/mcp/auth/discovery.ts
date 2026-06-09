import type {
	AuthorizationServerMetadata,
	FetchLike,
	OAuthProtectedResourceMetadata,
} from "@modelcontextprotocol/client";
import { McpAuthError } from "./errors";
import { parseBearerChallenge } from "./www-authenticate";

export interface ProtectedResourceMetadata
	extends OAuthProtectedResourceMetadata {
	challengeScope?: string;
	resourceMetadataUrl: string;
}

export async function discoverProtectedResource(input: {
	serverUrl: string;
	challengeHeader?: string;
	fetch: FetchLike;
	signal?: AbortSignal;
}): Promise<ProtectedResourceMetadata> {
	const urls = protectedResourceMetadataUrls(
		input.serverUrl,
		input.challengeHeader,
	);
	const challengeScope = input.challengeHeader
		? parseBearerChallenge(input.challengeHeader).scope
		: undefined;
	for (const url of urls) {
		const response = await input.fetch(url, { signal: input.signal });
		if (response.status === 404) continue;
		if (!response.ok) {
			throw new McpAuthError(
				`Protected resource metadata request failed with HTTP ${response.status}`,
			);
		}
		const metadata = (await response.json()) as OAuthProtectedResourceMetadata;
		validateProtectedResourceMetadata(metadata);
		return {
			...metadata,
			challengeScope,
			resourceMetadataUrl: url.toString(),
		};
	}
	throw new McpAuthError("MCP protected resource metadata was not found");
}

export async function discoverAuthorizationServer(input: {
	issuer: string;
	fetch: FetchLike;
	signal?: AbortSignal;
}): Promise<AuthorizationServerMetadata> {
	for (const url of authorizationServerMetadataUrls(input.issuer)) {
		const response = await input.fetch(url, { signal: input.signal });
		if (response.status === 404) continue;
		if (!response.ok) {
			throw new McpAuthError(
				`Authorization server metadata request failed with HTTP ${response.status}`,
			);
		}
		const metadata = (await response.json()) as AuthorizationServerMetadata;
		validateAuthorizationServerMetadata(metadata);
		return metadata;
	}
	throw new McpAuthError("Authorization server metadata was not found");
}

export function protectedResourceMetadataUrls(
	serverUrl: string,
	challengeHeader?: string,
): URL[] {
	if (challengeHeader) {
		const challenge = parseBearerChallenge(challengeHeader);
		if (challenge.resourceMetadata)
			return [new URL(challenge.resourceMetadata)];
	}
	const server = new URL(serverUrl);
	const path = server.pathname.replace(/^\/+/, "");
	const endpoint = new URL(server.origin);
	endpoint.pathname =
		path.length === 0
			? "/.well-known/oauth-protected-resource"
			: `/.well-known/oauth-protected-resource/${path}`;
	const root = new URL(server.origin);
	root.pathname = "/.well-known/oauth-protected-resource";
	return endpoint.toString() === root.toString() ? [root] : [endpoint, root];
}

export function authorizationServerMetadataUrls(issuer: string): URL[] {
	const url = new URL(issuer);
	const path = url.pathname === "/" ? "" : url.pathname.replace(/^\/+/, "");
	const origin = url.origin;
	if (path.length === 0) {
		return [
			new URL("/.well-known/oauth-authorization-server", origin),
			new URL("/.well-known/openid-configuration", origin),
		];
	}
	return [
		new URL(`/.well-known/oauth-authorization-server/${path}`, origin),
		new URL(`/.well-known/openid-configuration/${path}`, origin),
		new URL(
			`${url.pathname.replace(/\/$/, "")}/.well-known/openid-configuration`,
			origin,
		),
	];
}

function validateProtectedResourceMetadata(
	metadata: OAuthProtectedResourceMetadata,
): void {
	if (
		!Array.isArray(metadata.authorization_servers) ||
		metadata.authorization_servers.length === 0 ||
		metadata.authorization_servers.some((item) => typeof item !== "string")
	) {
		throw new McpAuthError(
			"MCP protected resource metadata must include authorization_servers",
		);
	}
}

function validateAuthorizationServerMetadata(
	metadata: AuthorizationServerMetadata,
): void {
	if (
		typeof metadata.authorization_endpoint !== "string" ||
		typeof metadata.token_endpoint !== "string"
	) {
		throw new McpAuthError(
			"Authorization server metadata must include authorization_endpoint and token_endpoint",
		);
	}
	if (
		!Array.isArray(metadata.code_challenge_methods_supported) ||
		!metadata.code_challenge_methods_supported.includes("S256")
	) {
		throw new McpAuthError(
			"Authorization server metadata must support PKCE S256",
		);
	}
}
