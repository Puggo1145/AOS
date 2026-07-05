import { errorText } from "../../errors";
import { validateConfiguredResourceSyntax } from "./resource";

export type McpOAuthRegistrationConfig =
	| { type: "dynamic" }
	| { type: "clientIdMetadataDocument"; clientId: string }
	| { type: "preRegistered"; clientId: string; clientSecret?: string };

export interface McpOAuthAuthConfig {
	type: "oauth";
	resource?: string;
	redirect?: {
		host?: "127.0.0.1" | "localhost";
		port?: number;
		path?: string;
	};
	registration: McpOAuthRegistrationConfig;
}

export interface OAuthConfigParserDeps {
	objectRecord(value: unknown, label: string): Record<string, unknown>;
	nonEmptyString(value: unknown, label: string): string;
	resolveEnvReference(value: string, label: string): string;
	schemaError(message: string): Error;
}

export function parseMcpOAuthAuthConfig(
	value: unknown,
	label: string,
	deps: OAuthConfigParserDeps,
): McpOAuthAuthConfig {
	const auth = deps.objectRecord(value, label);
	if (auth.type !== "oauth") {
		throw deps.schemaError(`${label}.type must be "oauth"`);
	}
	const registration = parseRegistration(auth.registration, label, deps);
	const redirect = parseRedirect(auth.redirect, label, deps);
	const resource =
		auth.resource === undefined
			? undefined
			: deps.nonEmptyString(auth.resource, `${label}.resource`);
	if (resource !== undefined) {
		try {
			validateConfiguredResourceSyntax(resource, `${label}.resource`);
		} catch (err) {
			throw deps.schemaError(errorText(err));
		}
	}
	return { type: "oauth", registration, redirect, resource };
}

function parseRegistration(
	value: unknown,
	label: string,
	deps: OAuthConfigParserDeps,
): McpOAuthRegistrationConfig {
	const registration = deps.objectRecord(value, `${label}.registration`);
	if (registration.type === "dynamic") {
		assertOnlyKeys(registration, ["type"], `${label}.registration`, deps);
		return { type: "dynamic" };
	}
	if (registration.type === "userProvided") {
		throw deps.schemaError(
			`${label}.registration.type "userProvided" requires Shell credential entry and is not supported yet`,
		);
	}
	if (registration.type === "preRegistered") {
		assertOnlyKeys(
			registration,
			["type", "clientId", "clientSecret"],
			`${label}.registration`,
			deps,
		);
		const clientId = deps.resolveEnvReference(
			deps.nonEmptyString(
				registration.clientId,
				`${label}.registration.clientId`,
			),
			`${label}.registration.clientId`,
		);
		const clientSecret =
			registration.clientSecret === undefined
				? undefined
				: deps.resolveEnvReference(
						deps.nonEmptyString(
							registration.clientSecret,
							`${label}.registration.clientSecret`,
						),
						`${label}.registration.clientSecret`,
					);
		return { type: "preRegistered", clientId, clientSecret };
	}
	if (registration.type === "clientIdMetadataDocument") {
		assertOnlyKeys(
			registration,
			["type", "clientId"],
			`${label}.registration`,
			deps,
		);
		const clientId = deps.resolveEnvReference(
			deps.nonEmptyString(
				registration.clientId,
				`${label}.registration.clientId`,
			),
			`${label}.registration.clientId`,
		);
		assertClientIdMetadataDocumentUrl(
			clientId,
			`${label}.registration.clientId`,
			deps,
		);
		return { type: "clientIdMetadataDocument", clientId };
	}
	throw deps.schemaError(
		`${label}.registration.type must be "dynamic", "clientIdMetadataDocument", or "preRegistered"`,
	);
}

function parseRedirect(
	value: unknown,
	label: string,
	deps: OAuthConfigParserDeps,
): McpOAuthAuthConfig["redirect"] {
	if (value === undefined) return undefined;
	const redirect = deps.objectRecord(value, `${label}.redirect`);
	assertOnlyKeys(redirect, ["host", "port", "path"], `${label}.redirect`, deps);
	const host = redirect.host;
	if (host !== undefined && host !== "127.0.0.1" && host !== "localhost") {
		throw deps.schemaError(
			`${label}.redirect.host must be "127.0.0.1" or "localhost"`,
		);
	}
	const port = redirect.port;
	if (
		port !== undefined &&
		(!Number.isInteger(port) ||
			(port as number) < 0 ||
			(port as number) > 65535)
	) {
		throw deps.schemaError(`${label}.redirect.port must be an integer 0-65535`);
	}
	const path =
		redirect.path === undefined
			? undefined
			: deps.nonEmptyString(redirect.path, `${label}.redirect.path`);
	if (path !== undefined && !path.startsWith("/")) {
		throw deps.schemaError(`${label}.redirect.path must start with "/"`);
	}
	return {
		host: host as "127.0.0.1" | "localhost" | undefined,
		port: port as number | undefined,
		path,
	};
}

function assertClientIdMetadataDocumentUrl(
	value: string,
	label: string,
	deps: OAuthConfigParserDeps,
): void {
	let url: URL;
	try {
		url = new URL(value);
	} catch (err) {
		throw deps.schemaError(
			`${label} must be a valid HTTPS URL: ${errorMessage(err)}`,
		);
	}
	if (url.protocol !== "https:" || url.pathname === "/") {
		throw deps.schemaError(`${label} must be an HTTPS URL with a path`);
	}
}

function assertOnlyKeys(
	value: Record<string, unknown>,
	allowed: string[],
	label: string,
	deps: OAuthConfigParserDeps,
): void {
	const allowedSet = new Set(allowed);
	for (const key of Object.keys(value)) {
		if (!allowedSet.has(key)) {
			throw deps.schemaError(`${label}.${key} is not supported`);
		}
	}
}

function errorMessage(err: unknown): string {
	return errorText(err);
}
