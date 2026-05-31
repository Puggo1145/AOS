// Tests for the pure parts of the ChatGPT plan OAuth flow:
//   - PKCE code_challenge computation against the RFC 7636 golden vector
//   - authorize URL contains all required PKCE / state params
//   - token storage roundtrip + 0600 file mode
//
// HTTP exchange is NOT tested here (out of scope).

import { test, expect, afterEach } from "bun:test";
import { existsSync, statSync, rmSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
	base64url,
	computeCodeChallenge,
	generateCodeVerifier,
	generateState,
	chatgptPlanOAuthProvider,
	CHATGPT_PLAN_AUTHORIZE_URL,
} from "../src/llm/auth/oauth/chatgpt-plan";

import {
	readChatGPTPlanToken,
	writeChatGPTPlanToken,
	chatgptTokenPath,
} from "../src/llm/auth/oauth/storage";

const ORIGINAL_HOME = process.env.HOME;

function setTempHome(): string {
	const home = mkdtempSync(join(tmpdir(), "notch-agent-pkce-test-"));
	process.env.HOME = home;
	return home;
}

afterEach(() => {
	if (ORIGINAL_HOME !== undefined) process.env.HOME = ORIGINAL_HOME;
});

test("PKCE code_challenge golden vector (RFC 7636 §B.1)", () => {
	// From RFC 7636 Appendix B: verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
	// → challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
	const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
	const challenge = computeCodeChallenge(verifier);
	expect(challenge).toBe("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
});

test("base64url has no padding or +/", () => {
	const buf = Buffer.from([255, 254, 253, 252, 251]);
	const out = base64url(buf);
	expect(out).not.toContain("=");
	expect(out).not.toContain("+");
	expect(out).not.toContain("/");
});

test("generateCodeVerifier / generateState produce sufficient entropy", () => {
	const a = generateCodeVerifier();
	const b = generateCodeVerifier();
	expect(a).not.toBe(b);
	expect(a.length).toBeGreaterThanOrEqual(32);
	const sa = generateState();
	expect(sa.length).toBeGreaterThanOrEqual(16);
});

test("buildAuthorizeUrl contains all required PKCE params", () => {
	const verifier = generateCodeVerifier();
	const url = chatgptPlanOAuthProvider.buildAuthorizeUrl({
		codeVerifier: verifier,
		redirectUri: "http://127.0.0.1:54321/callback",
		state: "STATE",
	});
	expect(url.startsWith(CHATGPT_PLAN_AUTHORIZE_URL)).toBe(true);
	const u = new URL(url);
	expect(u.searchParams.get("response_type")).toBe("code");
	expect(u.searchParams.get("code_challenge_method")).toBe("S256");
	expect(u.searchParams.get("code_challenge")).toBe(
		computeCodeChallenge(verifier),
	);
	expect(u.searchParams.get("state")).toBe("STATE");
	expect(u.searchParams.get("redirect_uri")).toBe(
		"http://127.0.0.1:54321/callback",
	);
	expect(u.searchParams.get("client_id")).toBeTruthy();
	expect(u.searchParams.get("scope")).toBeTruthy();
});

test("token storage roundtrip + 0600 file mode", () => {
	const home = setTempHome();
	try {
		const token = {
			accessToken: `at-${Math.random().toString(36).slice(2)}`,
			refreshToken: `rt-${Math.random().toString(36).slice(2)}`,
			expiresAt: Date.now() + 3600_000,
			accountId: `acct-${Math.random().toString(36).slice(2)}`,
		};
		writeChatGPTPlanToken(token);
		const path = chatgptTokenPath();
		expect(existsSync(path)).toBe(true);
		const mode = statSync(path).mode & 0o777;
		expect(mode).toBe(0o600);
		const back = readChatGPTPlanToken();
		expect(back).toEqual(token);
	} finally {
		rmSync(home, { recursive: true, force: true });
	}
});

test("storage returns null when file is missing or malformed", () => {
	const home = setTempHome();
	try {
		expect(readChatGPTPlanToken()).toBeNull();
	} finally {
		rmSync(home, { recursive: true, force: true });
	}
});
