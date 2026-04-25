// Provider login runtime — owns the in-flight `LoginSession`.
//
// Per docs/plans/onboarding.md §"Cancel / abort 硬契约":
//   - one in-flight login at a time; second startLogin returns
//     ErrLoginInProgress (-32200)
//   - 5min timer triggers ErrLoginTimeout (-32202)
//   - cancel triggers ErrLoginCancelled (-32201)
//   - all three abort the LoopbackHandle, reject the codePromise, and the
//     background task funnels into a single `loginStatus { failed, ... }`
//     notification
//   - successful exchange writes `chatgpt.json` (and removes any stale
//     `.invalid` sibling), emits `loginStatus { success }`, then a
//     `statusChanged { ready }` so Shell ProviderService flips state

import { existsSync, unlinkSync } from "node:fs";
import { randomUUID } from "node:crypto";

import {
  RPCErrorCode,
  RPCMethod,
  type ProviderCancelLoginParams,
  type ProviderCancelLoginResult,
  type ProviderStartLoginParams,
  type ProviderStartLoginResult,
  type ProviderStatusResult,
} from "../rpc/rpc-types";
import { Dispatcher, RPCMethodError } from "../rpc/dispatcher";
import { logger } from "../log";
import { startCallbackServer, AbortError } from "./loopback";
import { getProvider, listProviderInfos } from "./providers";
import {
  CHATGPT_PLAN_CLIENT_ID,
  CHATGPT_PLAN_REDIRECT_PATH,
  CHATGPT_PLAN_REDIRECT_PORT,
  CHATGPT_PLAN_REDIRECT_URI,
  chatgptPlanOAuthProvider,
  generateCodeVerifier,
  generateState,
} from "../llm/auth/oauth/chatgpt-plan";
import { PROVIDER_IDS } from "../llm";
import {
  writeChatGPTPlanToken,
  chatgptTokenPath,
} from "../llm/auth/oauth/storage";

const LOGIN_TIMEOUT_MS = 5 * 60 * 1000;

interface LoginSession {
  loginId: string;
  providerId: string;
  controller: AbortController;
  /// Set when the session is finalized (success/failed). Cancel of a
  /// finalized session returns `{ cancelled: false }` and does not change
  /// the session state.
  done: boolean;
}

let inflight: LoginSession | null = null;

// ---------------------------------------------------------------------------
// Public API (also used by cli.ts)
// ---------------------------------------------------------------------------

export interface StartLoginContext {
  dispatcher: Dispatcher;
}

export async function startLogin(
  ctx: StartLoginContext,
  params: ProviderStartLoginParams,
): Promise<ProviderStartLoginResult> {
  const { providerId } = params;
  if (typeof providerId !== "string") {
    throw new RPCMethodError(RPCErrorCode.invalidParams, "providerId is required");
  }
  const provider = getProvider(providerId);
  if (!provider) {
    throw new RPCMethodError(RPCErrorCode.unknownProvider, `unknown provider: ${providerId}`);
  }
  if (inflight && !inflight.done) {
    throw new RPCMethodError(RPCErrorCode.loginInProgress, "another login is already in progress");
  }

  // Provider-specific config gate. Only chatgpt-plan this round.
  if (providerId === PROVIDER_IDS.chatgptPlan && !CHATGPT_PLAN_CLIENT_ID) {
    throw new RPCMethodError(
      RPCErrorCode.loginNotConfigured,
      "CHATGPT_PLAN_CLIENT_ID is not configured",
    );
  }

  const loginId = randomUUID();
  const controller = new AbortController();
  const codeVerifier = generateCodeVerifier();
  const state = generateState();

  // ChatGPT plan's redirect_uri is registered server-side as a fixed URL.
  // We bind the loopback to exactly that port+path; if the port is busy
  // (e.g. an old session), startCallbackServer rejects with EADDRINUSE
  // which surfaces as the start-login Promise rejection.
  let handle;
  try {
    handle = await startCallbackServer({
      expectedState: state,
      signal: controller.signal,
      port: CHATGPT_PLAN_REDIRECT_PORT,
      path: CHATGPT_PLAN_REDIRECT_PATH,
    });
  } catch (err) {
    throw new RPCMethodError(
      RPCErrorCode.internalError,
      `failed to bind loopback ${CHATGPT_PLAN_REDIRECT_PORT}: ${err instanceof Error ? err.message : String(err)}`,
    );
  }
  const redirectUri = CHATGPT_PLAN_REDIRECT_URI;
  const authorizeUrl = chatgptPlanOAuthProvider.buildAuthorizeUrl({
    codeVerifier,
    redirectUri,
    state,
  });

  const session: LoginSession = { loginId, providerId, controller, done: false };
  inflight = session;

  // 5min timeout — abort triggers loopback close, which rejects codePromise.
  const timeoutTimer = setTimeout(() => {
    if (!session.done) {
      session.controller.abort(new TimeoutAbort());
    }
  }, LOGIN_TIMEOUT_MS);

  // Detached driver. Single funnel for success / cancel / timeout / errors:
  // every terminal path emits exactly one `loginStatus` notification.
  void (async () => {
    try {
      // emit awaitingCallback after returning startLogin's result; the
      // microtask boundary below ensures Shell sees the request reply first.
      queueMicrotask(() => {
        if (session.done) return;
        ctx.dispatcher.notify(RPCMethod.providerLoginStatus, {
          loginId,
          providerId,
          state: "awaitingCallback",
        });
      });

      const code = await handle.codePromise;

      if (session.done) return;
      ctx.dispatcher.notify(RPCMethod.providerLoginStatus, {
        loginId,
        providerId,
        state: "exchanging",
      });

      const tokens = await chatgptPlanOAuthProvider.exchangeCode({
        code,
        codeVerifier,
        redirectUri,
        signal: controller.signal,
      });

      const record = {
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        expiresAt: Date.now() + tokens.expiresIn * 1000,
        accountId: tokens.accountId,
      };
      writeChatGPTPlanToken(record);

      // Login success — clear any stale `.invalid` sibling left by a prior
      // refresh failure so future invariants ("only chatgpt.json matters")
      // hold without operator cleanup.
      const invalidPath = chatgptTokenPath() + ".invalid";
      try {
        if (existsSync(invalidPath)) unlinkSync(invalidPath);
      } catch {
        // best-effort
      }

      session.done = true;
      ctx.dispatcher.notify(RPCMethod.providerLoginStatus, {
        loginId,
        providerId,
        state: "success",
      });
      ctx.dispatcher.notify(RPCMethod.providerStatusChanged, {
        providerId,
        state: "ready",
      });
    } catch (err) {
      if (session.done) return;
      session.done = true;
      const errorCode = mapLoginError(err, controller.signal);
      const message = err instanceof Error ? err.message : String(err);
      ctx.dispatcher.notify(RPCMethod.providerLoginStatus, {
        loginId,
        providerId,
        state: "failed",
        message,
        errorCode,
      });
    } finally {
      clearTimeout(timeoutTimer);
      try { handle.close(); } catch {}
      if (inflight === session) inflight = null;
    }
  })();

  return { loginId, authorizeUrl };
}

class TimeoutAbort extends Error {
  constructor() {
    super("login timeout");
    this.name = "TimeoutAbort";
  }
}

function mapLoginError(err: unknown, signal: AbortSignal): number {
  if (signal.aborted) {
    const reason = (signal as AbortSignal & { reason?: unknown }).reason;
    if (reason instanceof TimeoutAbort) return RPCErrorCode.loginTimeout;
    return RPCErrorCode.loginCancelled;
  }
  if (err instanceof AbortError) return RPCErrorCode.loginCancelled;
  return RPCErrorCode.internalError;
}

export function cancelLogin(params: ProviderCancelLoginParams): ProviderCancelLoginResult {
  const { loginId } = params;
  if (typeof loginId !== "string") {
    throw new RPCMethodError(RPCErrorCode.invalidParams, "loginId is required");
  }
  if (!inflight || inflight.loginId !== loginId || inflight.done) {
    return { cancelled: false };
  }
  inflight.controller.abort();
  return { cancelled: true };
}

export function getStatus(): ProviderStatusResult {
  return { providers: listProviderInfos() };
}

// ---------------------------------------------------------------------------
// Test seam — reset module-level inflight between tests
// ---------------------------------------------------------------------------

export function _resetForTesting(): void {
  if (inflight && !inflight.done) {
    try { inflight.controller.abort(); } catch {}
  }
  inflight = null;
}

export function _hasInflight(): boolean {
  return inflight !== null && !inflight.done;
}
