import { McpAuthError } from "./errors";

export interface BearerChallenge {
	scheme: "Bearer";
	resourceMetadata?: string;
	scope?: string;
	error?: string;
	errorDescription?: string;
}

export function parseBearerChallenge(header: string): BearerChallenge {
	const trimmed = header.trim();
	const firstSpace = trimmed.indexOf(" ");
	const scheme = firstSpace < 0 ? trimmed : trimmed.slice(0, firstSpace);
	if (scheme.toLowerCase() !== "bearer") {
		throw new McpAuthError(
			"MCP OAuth requires a Bearer WWW-Authenticate challenge",
		);
	}
	const paramsText = firstSpace < 0 ? "" : trimmed.slice(firstSpace + 1).trim();
	const params = parseParams(paramsText);
	const challenge: BearerChallenge = { scheme: "Bearer" };
	if (params.resource_metadata !== undefined) {
		challenge.resourceMetadata = params.resource_metadata;
	}
	if (params.scope !== undefined) challenge.scope = params.scope;
	if (params.error !== undefined) challenge.error = params.error;
	if (params.error_description !== undefined) {
		challenge.errorDescription = params.error_description;
	}
	return challenge;
}

function parseParams(value: string): Record<string, string> {
	const out: Record<string, string> = {};
	let i = 0;
	while (i < value.length) {
		i = skipSeparators(value, i);
		if (i >= value.length) break;
		const keyStart = i;
		while (i < value.length && /[A-Za-z0-9_.-]/.test(value[i] ?? "")) i += 1;
		if (i === keyStart) throw malformed(value);
		const key = value.slice(keyStart, i);
		i = skipSpaces(value, i);
		if (value[i] !== "=") throw malformed(value);
		i += 1;
		i = skipSpaces(value, i);
		const parsed = parseValue(value, i);
		out[key] = parsed.value;
		i = parsed.next;
		i = skipSpaces(value, i);
		if (i < value.length && value[i] !== ",") throw malformed(value);
	}
	return out;
}

function parseValue(
	input: string,
	start: number,
): { value: string; next: number } {
	if (input[start] === '"') {
		let i = start + 1;
		let value = "";
		while (i < input.length) {
			const char = input[i];
			if (char === '"') return { value, next: i + 1 };
			if (char === "\\") {
				i += 1;
				if (i >= input.length) throw malformed(input);
				value += input[i];
				i += 1;
				continue;
			}
			value += char;
			i += 1;
		}
		throw malformed(input);
	}
	const tokenStart = start;
	let i = start;
	while (i < input.length && input[i] !== "," && !/\s/.test(input[i] ?? "")) {
		i += 1;
	}
	if (i === tokenStart) throw malformed(input);
	return { value: input.slice(tokenStart, i), next: i };
}

function skipSeparators(value: string, start: number): number {
	let i = start;
	while (i < value.length && (value[i] === "," || /\s/.test(value[i] ?? ""))) {
		i += 1;
	}
	return i;
}

function skipSpaces(value: string, start: number): number {
	let i = start;
	while (i < value.length && /\s/.test(value[i] ?? "")) i += 1;
	return i;
}

function malformed(value: string): McpAuthError {
	return new McpAuthError(
		`Malformed Bearer WWW-Authenticate challenge: ${value}`,
	);
}
