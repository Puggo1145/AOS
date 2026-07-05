import { errorText } from "../../errors";
import { McpAuthError } from "./errors";

export function canonicalMcpResourceUri(serverUrl: string): string {
	const url = parseAbsoluteUrl(serverUrl, "MCP server URL");
	url.hash = "";
	url.protocol = url.protocol.toLowerCase();
	url.hostname = url.hostname.toLowerCase();
	if (url.pathname !== "/" && url.pathname.endsWith("/")) {
		url.pathname = url.pathname.slice(0, -1);
	}
	if (url.pathname === "/") {
		url.pathname = "";
	}
	return url.toString();
}

export function validateConfiguredResource(
	serverUrl: string,
	resource: string,
): string {
	const resourceUrl = parseAbsoluteUrl(resource, "MCP OAuth resource");
	if (resourceUrl.hash.length > 0) {
		throw new McpAuthError("MCP OAuth resource must not include a fragment");
	}
	const server = new URL(canonicalMcpResourceUri(serverUrl));
	const configured = new URL(canonicalMcpResourceUri(resource));
	if (configured.origin !== server.origin) {
		throw new McpAuthError(
			`MCP OAuth resource origin ${configured.origin} must match server origin ${server.origin}`,
		);
	}
	if (
		server.pathname.length > 0 &&
		configured.pathname !== "/" &&
		configured.pathname !== server.pathname
	) {
		throw new McpAuthError(
			`MCP OAuth resource path ${configured.pathname} must be empty or match server path ${server.pathname}`,
		);
	}
	return configured.toString();
}

export function validateConfiguredResourceSyntax(
	resource: string,
	label: string,
): void {
	const url = parseAbsoluteUrl(resource, label);
	if (url.hash.length > 0) {
		throw new McpAuthError(`${label} must not include a fragment`);
	}
}

function parseAbsoluteUrl(value: string, label: string): URL {
	let url: URL;
	try {
		url = new URL(value);
	} catch (err) {
		throw new McpAuthError(
			`${label} must be an absolute URI: ${errorText(err)}`,
		);
	}
	if (!url.protocol || !url.hostname) {
		throw new McpAuthError(`${label} must include scheme and host`);
	}
	return url;
}
