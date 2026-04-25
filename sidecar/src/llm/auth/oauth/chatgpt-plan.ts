// ChatGPT plan OAuth (PKCE) provider — pure functions only.
//
// Per docs/plans/onboarding.md §"模块布局":
//   - login orchestration (loopback, session lifecycle) lives in
//     `sidecar/src/auth/runtime.ts` and `sidecar/src/auth/cli.ts`
//   - this file exposes `buildAuthorizeUrl`, `exchangeCode`, `refresh`,
//     `readChatGPTToken`, and `AuthInvalidatedError`
//   - refresh failure renames `chatgpt.json` → `chatgpt.json.invalid` and
//     throws `AuthInvalidatedError`; the agent loop projects that to
//     `provider.statusChanged`
//
// VERIFY: endpoint URLs, client_id, and scope strings below remain
// PROVISIONAL until the real ChatGPT plan auth endpoint is confirmed.

import { createHash, randomBytes } from "node:crypto";
import { renameSync, existsSync } from "node:fs";

import type {
  AuthorizeOptions,
  ExchangeOptions,
  OAuthProviderInterface,
  TokenSet,
} from "./types";
import {
  writeChatGPTPlanToken,
  readChatGPTPlanToken,
  chatgptTokenPath,
} from "./storage";
import { PROVIDER_IDS } from "../../models/catalog";

// Public OAuth parameters for ChatGPT Plus/Pro (Codex Subscription).
// These are the same values used by the upstream Codex CLI and the
// pi-mono `openai-codex` OAuth provider. The redirect URI is FIXED
// server-side: any other port / path will be rejected by the authorize
// endpoint, which is why our loopback must bind exactly 127.0.0.1:1455
// and serve `/auth/callback`.
export const CHATGPT_PLAN_AUTHORIZE_URL = "https://auth.openai.com/oauth/authorize";
export const CHATGPT_PLAN_TOKEN_URL = "https://auth.openai.com/oauth/token";
export const CHATGPT_PLAN_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";
export const CHATGPT_PLAN_SCOPES = ["openid", "profile", "email", "offline_access"];
export const CHATGPT_PLAN_REDIRECT_HOST = "127.0.0.1";
export const CHATGPT_PLAN_REDIRECT_PORT = 1455;
export const CHATGPT_PLAN_REDIRECT_PATH = "/auth/callback";
export const CHATGPT_PLAN_REDIRECT_URI = `http://localhost:${CHATGPT_PLAN_REDIRECT_PORT}${CHATGPT_PLAN_REDIRECT_PATH}`;
/// `originator` identifies which client variant is initiating the flow.
/// Codex CLI uses "codex_cli_rs"; pi-mono uses "pi". AOS uses its own.
export const CHATGPT_PLAN_ORIGINATOR = "aos";
/// JWT claim path that carries the `chatgpt_account_id`. Required for
/// downstream API calls.
const JWT_CLAIM_PATH = "https://api.openai.com/auth";

// ---------------------------------------------------------------------------
// PKCE primitives
// ---------------------------------------------------------------------------

export function base64url(bytes: Buffer | Uint8Array): string {
  return Buffer.from(bytes)
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

export function generateCodeVerifier(): string {
  return base64url(randomBytes(32));
}

export function computeCodeChallenge(codeVerifier: string): string {
  return base64url(createHash("sha256").update(codeVerifier).digest());
}

export function generateState(): string {
  return base64url(randomBytes(16));
}

// ---------------------------------------------------------------------------
// Typed auth error — flows from refresh-fail / 401 stream to agent loop
// ---------------------------------------------------------------------------

/// Thrown by `readChatGPTToken` (and propagated through the LLM stream's
/// top-level catch) when the persisted token is missing-or-broken AND no
/// usable refresh path exists. The agent loop checks `instanceof
/// AuthInvalidatedError` to project to `ui.error -32003` plus
/// `provider.statusChanged { unauthenticated, authInvalidated }`.
export class AuthInvalidatedError extends Error {
  constructor(
    public readonly providerId: string,
    public readonly reason: string,
  ) {
    super(`provider ${providerId} auth invalidated: ${reason}`);
    this.name = "AuthInvalidatedError";
  }
}

// ---------------------------------------------------------------------------
// Provider implementation
// ---------------------------------------------------------------------------

export const chatgptPlanOAuthProvider: OAuthProviderInterface = {
  name: PROVIDER_IDS.chatgptPlan,

  buildAuthorizeUrl(opts: AuthorizeOptions): string {
    const challenge = computeCodeChallenge(opts.codeVerifier);
    const params = new URLSearchParams({
      response_type: "code",
      client_id: CHATGPT_PLAN_CLIENT_ID,
      redirect_uri: opts.redirectUri,
      scope: CHATGPT_PLAN_SCOPES.join(" "),
      state: opts.state,
      code_challenge: challenge,
      code_challenge_method: "S256",
      // Codex-flow flags expected by the OpenAI authorize endpoint. Without
      // these, the resulting access_token JWT does not carry the
      // chatgpt_account_id claim that downstream API calls require.
      id_token_add_organizations: "true",
      codex_cli_simplified_flow: "true",
      originator: CHATGPT_PLAN_ORIGINATOR,
    });
    return `${CHATGPT_PLAN_AUTHORIZE_URL}?${params.toString()}`;
  },

  async exchangeCode(opts: ExchangeOptions & { signal?: AbortSignal }): Promise<TokenSet> {
    const body = new URLSearchParams({
      grant_type: "authorization_code",
      code: opts.code,
      redirect_uri: opts.redirectUri,
      client_id: CHATGPT_PLAN_CLIENT_ID,
      code_verifier: opts.codeVerifier,
    });
    const res = await fetch(CHATGPT_PLAN_TOKEN_URL, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
      body: body.toString(),
      signal: opts.signal,
    });
    if (!res.ok) {
      const text = await res.text().catch(() => "");
      throw new Error(`token exchange failed: ${res.status} ${text}`);
    }
    const json = (await res.json()) as Record<string, unknown>;
    return parseTokenResponse(json);
  },

  async refresh(refreshToken: string, opts?: { signal?: AbortSignal }): Promise<TokenSet> {
    const body = new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: refreshToken,
      client_id: CHATGPT_PLAN_CLIENT_ID,
    });
    const res = await fetch(CHATGPT_PLAN_TOKEN_URL, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
      body: body.toString(),
      signal: opts?.signal,
    });
    if (!res.ok) {
      const text = await res.text().catch(() => "");
      throw new Error(`token refresh failed: ${res.status} ${text}`);
    }
    const json = (await res.json()) as Record<string, unknown>;
    return parseTokenResponse(json);
  },
};

function parseTokenResponse(json: Record<string, unknown>): TokenSet {
  const accessToken = json["access_token"];
  const refreshToken = json["refresh_token"];
  const expiresIn = json["expires_in"];
  if (typeof accessToken !== "string" || typeof refreshToken !== "string" || typeof expiresIn !== "number") {
    throw new Error(`malformed token response: ${JSON.stringify(json)}`);
  }
  // `chatgpt_account_id` is delivered inside the JWT access_token, not the
  // top-level token response (per Codex / pi-mono behaviour). We require
  // it: a token without accountId cannot authorize Codex API calls, so
  // accepting one would be a silent fallback to a broken credential.
  const accountId = extractAccountIdFromAccessToken(accessToken);
  if (!accountId) {
    throw new Error(
      "token response is missing chatgpt_account_id (JWT claim https://api.openai.com/auth.chatgpt_account_id)",
    );
  }
  return {
    accessToken,
    refreshToken,
    expiresIn,
    accountId,
  };
}

/// Decode the access_token JWT and extract `chatgpt_account_id` from the
/// `https://api.openai.com/auth` claim. Returns `undefined` on any decode
/// or shape failure — callers decide whether that is fatal.
export function extractAccountIdFromAccessToken(accessToken: string): string | undefined {
  try {
    const parts = accessToken.split(".");
    if (parts.length !== 3) return undefined;
    const payloadB64 = parts[1] ?? "";
    // base64url → base64
    const padded = payloadB64
      .replace(/-/g, "+")
      .replace(/_/g, "/")
      .padEnd(payloadB64.length + ((4 - (payloadB64.length % 4)) % 4), "=");
    const json = JSON.parse(Buffer.from(padded, "base64").toString("utf8")) as Record<string, unknown>;
    const claim = json[JWT_CLAIM_PATH] as Record<string, unknown> | undefined;
    const id = claim?.["chatgpt_account_id"];
    return typeof id === "string" && id.length > 0 ? id : undefined;
  } catch {
    return undefined;
  }
}

// ---------------------------------------------------------------------------
// Runtime token read / refresh (used by openai-responses provider)
// ---------------------------------------------------------------------------

const REFRESH_LEAD_MS = 60_000;
let refreshInflight: Promise<{ accessToken: string; refreshToken: string; expiresAt: number; accountId: string }> | null = null;

/// Read the persisted token; if it is within `REFRESH_LEAD_MS` of expiry,
/// transparently refresh and rewrite the file before returning. Refresh
/// failures rename the token file to `chatgpt.json.invalid` and throw
/// `AuthInvalidatedError` so the agent loop can project to
/// `provider.statusChanged`.
export async function readChatGPTToken(): Promise<{
  accessToken: string;
  refreshToken: string;
  expiresAt: number;
  accountId: string;
}> {
  const stored = readChatGPTPlanToken();
  if (!stored) {
    throw new AuthInvalidatedError(PROVIDER_IDS.chatgptPlan, "token missing");
  }
  if (stored.expiresAt - Date.now() > REFRESH_LEAD_MS) return stored;
  if (refreshInflight) return refreshInflight;
  refreshInflight = (async () => {
    try {
      const next = await chatgptPlanOAuthProvider.refresh(stored.refreshToken);
      const record = {
        accessToken: next.accessToken,
        refreshToken: next.refreshToken,
        expiresAt: Date.now() + next.expiresIn * 1000,
        accountId: next.accountId,
      };
      writeChatGPTPlanToken(record);
      return record;
    } catch (err) {
      // Quarantine the file so subsequent disk-only checks (`provider.status`)
      // see no token. The login success path deletes any stale `.invalid`
      // sibling so it does not pile up.
      const path = chatgptTokenPath();
      try {
        if (existsSync(path)) renameSync(path, path + ".invalid");
      } catch {
        // best-effort
      }
      throw new AuthInvalidatedError(
        PROVIDER_IDS.chatgptPlan,
        err instanceof Error ? err.message : String(err),
      );
    } finally {
      refreshInflight = null;
    }
  })();
  return refreshInflight;
}
