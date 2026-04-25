// OAuth PKCE loopback callback server.
//
// Extracted from `llm/auth/oauth/chatgpt-plan.ts` so both the runtime
// `provider.startLogin` path and the standalone `auth/cli.ts` login command
// share one implementation. Per docs/plans/onboarding.md §"OAuth loopback
// server 跑在 sidecar":
//
//   - bind 127.0.0.1:0 (kernel-assigned ephemeral port); Shell composes the
//     authorize URL using the returned port
//   - resolve `codePromise` with the validated `code` query param
//   - reject `codePromise` with AbortError on `signal.abort()` or `close()`
//     before the callback arrives
//   - `close()` is idempotent
//
// The HTTP server is a separate socket from the stdio NDJSON channel, so
// running it inside the sidecar process does not conflict with RPC.

import { createServer } from "node:http";
import type { AddressInfo } from "node:net";

export interface LoopbackHandle {
  port: number;
  /// Resolves with the validated `code` query param, or rejects on
  /// state mismatch / abort / handle close.
  codePromise: Promise<string>;
  /// Idempotent. Closes the server and rejects pending codePromise with
  /// AbortError if not yet resolved.
  close(): void;
}

export interface StartCallbackServerOptions {
  expectedState: string;
  signal: AbortSignal;
  /// Bind port. `0` lets the kernel pick (default for tests). Real OAuth
  /// providers register a fixed redirect URI server-side; the runtime
  /// caller must pass the matching port.
  port?: number;
  /// HTTP path that the redirect URI will hit. Defaults to `/callback`.
  /// ChatGPT plan uses `/auth/callback`.
  path?: string;
  /// Optional bind host. Defaults to `127.0.0.1`. Note that some providers
  /// only accept `localhost` in the registered redirect URI even though
  /// they bind to the same loopback interface.
  host?: string;
}

export class AbortError extends Error {
  constructor(message = "aborted") {
    super(message);
    this.name = "AbortError";
  }
}

export function startCallbackServer(
  opts: StartCallbackServerOptions,
): Promise<LoopbackHandle> {
  return new Promise((resolveStart, rejectStart) => {
    let resolveCode: (code: string) => void;
    let rejectCode: (err: Error) => void;
    const codePromise = new Promise<string>((res, rej) => {
      resolveCode = res;
      rejectCode = rej;
    });

    let closed = false;
    let settled = false;
    const settle = (): boolean => {
      if (settled) return false;
      settled = true;
      return true;
    };

    const expectedPath = opts.path ?? "/callback";
    const server = createServer((req, res) => {
      try {
        if (!req.url) {
          res.writeHead(400).end("Bad request");
          return;
        }
        const url = new URL(req.url, "http://127.0.0.1");
        if (url.pathname !== expectedPath) {
          res.writeHead(404).end("Not found");
          return;
        }
        const code = url.searchParams.get("code");
        const state = url.searchParams.get("state");
        if (!code || !state) {
          res.writeHead(400).end("Missing code or state");
          if (settle()) rejectCode(new Error("OAuth callback missing code or state"));
          return;
        }
        if (state !== opts.expectedState) {
          res.writeHead(400).end("State mismatch");
          if (settle()) rejectCode(new Error("OAuth state mismatch"));
          return;
        }
        res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
        res.end(
          "<html><body><p>Login successful, you can close this tab.</p></body></html>",
        );
        if (settle()) resolveCode(code);
      } catch (err) {
        if (settle()) rejectCode(err instanceof Error ? err : new Error(String(err)));
      }
    });

    const close = (): void => {
      if (closed) return;
      closed = true;
      try { server.close(); } catch {}
      if (settle()) rejectCode(new AbortError("loopback closed"));
    };

    if (opts.signal.aborted) {
      close();
      rejectStart(new AbortError("aborted before listen"));
      return;
    }
    const onAbort = () => close();
    opts.signal.addEventListener("abort", onAbort, { once: true });

    server.once("error", (err) => {
      opts.signal.removeEventListener("abort", onAbort);
      rejectStart(err);
    });
    const bindPort = opts.port ?? 0;
    const bindHost = opts.host ?? "127.0.0.1";
    server.listen(bindPort, bindHost, () => {
      const addr = server.address() as AddressInfo;
      resolveStart({
        port: addr.port,
        codePromise,
        close,
      });
    });
  });
}
