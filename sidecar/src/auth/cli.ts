// Standalone OAuth login CLI.
//
// Per docs/plans/onboarding.md §"模块布局": dev / troubleshooting path that
// does NOT depend on the Shell. Reuses the same loopback + exchange code
// as the runtime, but prints the authorize URL to stdout and writes the
// token to the on-disk path directly.
//
//   bun run sidecar/src/auth/cli.ts login
//
// Multiple runs overwrite the token file. The runtime path
// (`provider.startLogin`) and this CLI never run concurrently — they are
// alternative entry points to the same OAuth machinery.

import {
  CHATGPT_PLAN_CLIENT_ID,
  CHATGPT_PLAN_REDIRECT_PATH,
  CHATGPT_PLAN_REDIRECT_PORT,
  CHATGPT_PLAN_REDIRECT_URI,
  chatgptPlanOAuthProvider,
  generateCodeVerifier,
  generateState,
} from "../llm/auth/oauth/chatgpt-plan";
import { writeChatGPTPlanToken, chatgptTokenPath } from "../llm/auth/oauth/storage";
import { startCallbackServer } from "./loopback";
import { existsSync, unlinkSync } from "node:fs";

async function runLoginCLI(): Promise<void> {
  if (!CHATGPT_PLAN_CLIENT_ID) {
    process.stderr.write(
      "CHATGPT_PLAN_CLIENT_ID is not configured. Set the constant in chatgpt-plan.ts before running login.\n",
    );
    process.exit(2);
  }
  const codeVerifier = generateCodeVerifier();
  const state = generateState();
  const controller = new AbortController();

  const handle = await startCallbackServer({
    expectedState: state,
    signal: controller.signal,
    port: CHATGPT_PLAN_REDIRECT_PORT,
    path: CHATGPT_PLAN_REDIRECT_PATH,
  });
  const redirectUri = CHATGPT_PLAN_REDIRECT_URI;
  const authorizeUrl = chatgptPlanOAuthProvider.buildAuthorizeUrl({
    codeVerifier,
    redirectUri,
    state,
  });

  process.stdout.write(
    `\nOpen the following URL in your browser to log in:\n\n  ${authorizeUrl}\n\nWaiting for callback on ${redirectUri} ...\n`,
  );

  try {
    const code = await handle.codePromise;
    const tokens = await chatgptPlanOAuthProvider.exchangeCode({
      code,
      codeVerifier,
      redirectUri,
      signal: controller.signal,
    });
    writeChatGPTPlanToken({
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      expiresAt: Date.now() + tokens.expiresIn * 1000,
      accountId: tokens.accountId,
    });
    const invalidPath = chatgptTokenPath() + ".invalid";
    try {
      if (existsSync(invalidPath)) unlinkSync(invalidPath);
    } catch {}
    process.stdout.write("Login successful. Token saved.\n");
  } finally {
    handle.close();
  }
}

if ((import.meta as unknown as { main?: boolean }).main) {
  runLoginCLI().catch((err) => {
    process.stderr.write(`login failed: ${err instanceof Error ? err.message : String(err)}\n`);
    process.exit(1);
  });
}

export { runLoginCLI };
