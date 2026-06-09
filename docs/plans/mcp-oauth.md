# MCP OAuth Host Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add spec-compliant OAuth Host support for Streamable HTTP MCP servers.

**Architecture:** Keep OAuth behind `sidecar/src/mcp/auth/*`. `McpClientSession` receives an SDK `OAuthClientProvider`; Shell-facing status/login/logout uses new `mcp.auth.*` RPC methods. Existing progressive discovery and `mcp_call_tool` permissions stay stable.

**Tech Stack:** Bun, TypeScript, `@modelcontextprotocol/client`, Sidecar stdio JSON-RPC, existing loopback OAuth helper, TDD with `bun test`.

---

Design basis: [docs/designs/mcp-oauth.md](../designs/mcp-oauth.md)

## File Structure

- Create `sidecar/src/mcp/auth/config.ts`: OAuth config types and parser helpers used by `sidecar/src/mcp/config.ts`.
- Create `sidecar/src/mcp/auth/storage.ts`: server-scoped token/client/verifier/discovery storage under `~/.notch-agent/auth/mcp/<serverId>/`.
- Create `sidecar/src/mcp/auth/resource.ts`: canonical resource URI resolution and validation.
- Create `sidecar/src/mcp/auth/www-authenticate.ts`: strict Bearer `WWW-Authenticate` parser.
- Create `sidecar/src/mcp/auth/discovery.ts`: RFC9728 protected resource metadata and RFC8414/OIDC discovery.
- Create `sidecar/src/mcp/auth/registration.ts`: registration priority resolver.
- Create `sidecar/src/mcp/auth/provider.ts`: `NotchMcpOAuthProvider` implementing SDK `OAuthClientProvider`.
- Create `sidecar/src/mcp/auth/runtime.ts`: login/cancel/logout/status orchestration.
- Create `sidecar/src/mcp/auth/errors.ts`: typed MCP auth errors.
- Modify `sidecar/src/mcp/config.ts`: support `transport.auth`.
- Modify `sidecar/src/mcp/client-session.ts`: create OAuth provider for Streamable HTTP transports.
- Modify `sidecar/src/mcp/bootstrap.ts` and `sidecar/src/index.ts`: construct auth runtime and register RPC handlers.
- Modify `sidecar/src/rpc/rpc-types.ts`, `sidecar/src/rpc/method-catalog.ts`, and fixtures: add `mcp.auth.*`.
- Modify Shell RPC generated/types as required by the repo’s RPC generation flow.
- Add tests under `sidecar/test/mcp-auth-*.test.ts`.

## Stage 1: OAuth Config Schema

- [ ] **Write failing config tests**

Create `sidecar/test/mcp-auth-config.test.ts` covering:

```ts
test("oauth auth is valid only for streamableHttp transports", () => {});
test("headers Authorization and oauth auth are mutually exclusive", () => {});
test("preRegistered client id and secret support full-string env interpolation", () => {});
test("clientIdMetadataDocument requires HTTPS clientId URL with path", () => {});
test("dynamic registration accepts no client credentials", () => {});
test("resource override must be an absolute URI without fragment", () => {});
```

Run:

```bash
cd sidecar
bun test test/mcp-auth-config.test.ts
```

Expected: fail because config support does not exist.

- [ ] **Implement config types and parsing**

Create `sidecar/src/mcp/auth/config.ts` with:

```ts
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
```

Modify `sidecar/src/mcp/config.ts` so `streamableHttp` transport can include:

```ts
auth?: McpOAuthAuthConfig;
headers?: Record<string, string>;
```

Rules:

- `auth.type === "oauth"` invalid for stdio.
- `headers.Authorization` invalid when OAuth is enabled.
- `clientIdMetadataDocument.clientId` must be HTTPS URL with path.
- `resource` must be absolute URI and must not include fragment.
- Env interpolation uses the existing full-string rule only.

- [ ] **Run config tests**

```bash
cd sidecar
bun test test/mcp-auth-config.test.ts test/mcp-config.test.ts
```

Expected: all pass.

## Stage 2: Secure MCP OAuth Storage

- [ ] **Write failing storage tests**

Create `sidecar/test/mcp-auth-storage.test.ts` covering:

```ts
test("token path is ~/.notch-agent/auth/mcp/<serverId>/tokens.json", () => {});
test("writes token/client/verifier/discovery files atomically with 0600 mode", () => {});
test("auth directory is created with 0700 mode", () => {});
test("read missing token returns null for passive status", () => {});
test("active token read throws typed error for malformed token file", () => {});
test("clear server auth deletes token, client, verifier, and discovery files", () => {});
```

Run:

```bash
cd sidecar
bun test test/mcp-auth-storage.test.ts
```

Expected: fail because storage module does not exist.

- [ ] **Implement storage module**

Create `sidecar/src/mcp/auth/storage.ts` with:

```ts
export interface McpOAuthTokenRecord {
  accessToken: string;
  refreshToken?: string;
  expiresAt?: number;
  tokenType: "Bearer";
  scopes: string[];
  resource: string;
  authorizationServerUrl: string;
}
```

Also define persisted records for:

- `McpOAuthClientRecord`
- `McpOAuthVerifierRecord`
- `McpOAuthDiscoveryRecord`

Use atomic temp write + rename. Do not swallow filesystem errors except `ENOENT` in explicit delete paths.

- [ ] **Run storage tests**

```bash
cd sidecar
bun test test/mcp-auth-storage.test.ts
```

Expected: pass.

## Stage 3: Resource URI Canonicalization

- [ ] **Write failing resource tests**

Create `sidecar/test/mcp-auth-resource.test.ts` covering:

```ts
test("canonical resource preserves endpoint path when present", () => {});
test("canonical resource lowercases scheme and host", () => {});
test("canonical resource removes fragment and rejects configured fragments", () => {});
test("trailing slash is removed unless path is semantically non-root", () => {});
test("configured resource must match the server origin or exact endpoint policy", () => {});
```

Run:

```bash
cd sidecar
bun test test/mcp-auth-resource.test.ts
```

Expected: fail.

- [ ] **Implement resource module**

Create `sidecar/src/mcp/auth/resource.ts`:

```ts
export function canonicalMcpResourceUri(serverUrl: string): string;
export function validateConfiguredResource(serverUrl: string, resource: string): string;
```

Follow the design: absolute URI required, fragment forbidden, default derived from MCP endpoint URL.

- [ ] **Run resource tests**

```bash
cd sidecar
bun test test/mcp-auth-resource.test.ts
```

Expected: pass.

## Stage 4: WWW-Authenticate Parsing

- [ ] **Write failing parser tests**

Create `sidecar/test/mcp-auth-www-authenticate.test.ts` covering:

```ts
test("parses Bearer resource_metadata and scope", () => {});
test("parses insufficient_scope error", () => {});
test("rejects non-Bearer challenge for MCP OAuth", () => {});
test("handles comma inside quoted error_description", () => {});
test("rejects malformed quoted parameters loudly", () => {});
```

Run:

```bash
cd sidecar
bun test test/mcp-auth-www-authenticate.test.ts
```

Expected: fail.

- [ ] **Implement parser**

Create `sidecar/src/mcp/auth/www-authenticate.ts`:

```ts
export interface BearerChallenge {
  scheme: "Bearer";
  resourceMetadata?: string;
  scope?: string;
  error?: string;
  errorDescription?: string;
}

export function parseBearerChallenge(header: string): BearerChallenge;
```

No best-effort parsing. Malformed challenge throws typed auth error.

- [ ] **Run parser tests**

```bash
cd sidecar
bun test test/mcp-auth-www-authenticate.test.ts
```

Expected: pass.

## Stage 5: Protected Resource And Authorization Server Discovery

- [ ] **Write failing discovery tests**

Create `sidecar/test/mcp-auth-discovery.test.ts` with fake fetch covering:

```ts
test("uses resource_metadata from 401 challenge before well-known fallback", () => {});
test("falls back to endpoint-path protected resource metadata URL first", () => {});
test("falls back to root protected resource metadata URL second", () => {});
test("requires authorization_servers in protected resource metadata", () => {});
test("discovers OAuth authorization server metadata for path issuer in spec order", () => {});
test("discovers OIDC metadata fallback for path issuer", () => {});
test("requires code_challenge_methods_supported to include S256", () => {});
```

Run:

```bash
cd sidecar
bun test test/mcp-auth-discovery.test.ts
```

Expected: fail.

- [ ] **Implement discovery module**

Create `sidecar/src/mcp/auth/discovery.ts`:

```ts
export async function discoverProtectedResource(input: {
  serverUrl: string;
  challengeHeader?: string;
  fetch: typeof fetch;
  signal?: AbortSignal;
}): Promise<ProtectedResourceMetadata>;

export async function discoverAuthorizationServer(input: {
  issuer: string;
  fetch: typeof fetch;
  signal?: AbortSignal;
}): Promise<AuthorizationServerMetadata>;
```

Persist discovery via storage only from runtime/provider, not inside pure discovery helpers.

- [ ] **Run discovery tests**

```bash
cd sidecar
bun test test/mcp-auth-discovery.test.ts
```

Expected: pass.

## Stage 6: Registration Resolution

- [ ] **Write failing registration tests**

Create `sidecar/test/mcp-auth-registration.test.ts` covering:

```ts
test("uses preRegistered client information first", () => {});
test("uses client id metadata document when server advertises support and config supplies HTTPS client id", () => {});
test("uses dynamic registration when registration_endpoint exists", () => {});
test("fails loudly when no automatic registration path exists", () => {});
test("dynamic registration persists returned client information", () => {});
```

Run:

```bash
cd sidecar
bun test test/mcp-auth-registration.test.ts
```

Expected: fail.

- [ ] **Implement registration module**

Create `sidecar/src/mcp/auth/registration.ts`:

```ts
export async function resolveClientRegistration(input: {
  serverId: string;
  authConfig: McpOAuthAuthConfig;
  authorizationServerMetadata: AuthorizationServerMetadata;
  storage: McpOAuthStorage;
  fetch: typeof fetch;
  signal?: AbortSignal;
}): Promise<McpOAuthClientRecord>;
```

Do not invent a public metadata URL. If config does not provide one, skip that registration path.

- [ ] **Run registration tests**

```bash
cd sidecar
bun test test/mcp-auth-registration.test.ts
```

Expected: pass.

## Stage 7: NotchMcpOAuthProvider

- [ ] **Write failing provider tests**

Create `sidecar/test/mcp-auth-provider.test.ts` covering:

```ts
test("tokens reads and saves server-scoped token records", () => {});
test("saveCodeVerifier and codeVerifier use verifier storage", () => {});
test("redirectToAuthorization emits Shell-openable login status", () => {});
test("validateResourceURL rejects resource mismatch", () => {});
test("invalidateCredentials deletes requested scopes and notifies statusChanged", () => {});
test("public clients leave token request authentication to the SDK default", () => {});
```

Run:

```bash
cd sidecar
bun test test/mcp-auth-provider.test.ts
```

Expected: fail.

- [ ] **Implement SDK provider adapter**

Create `sidecar/src/mcp/auth/provider.ts`:

```ts
export class NotchMcpOAuthProvider implements OAuthClientProvider {
  constructor(input: NotchMcpOAuthProviderInput);
}
```

Map every SDK method listed in [docs/designs/mcp-oauth.md](../designs/mcp-oauth.md). Keep SDK-specific imports isolated to this file and `client-session.ts`.

- [ ] **Run provider tests**

```bash
cd sidecar
bun test test/mcp-auth-provider.test.ts
```

Expected: pass.

## Stage 8: MCP Auth RPC Types And Fixtures

- [ ] **Write failing RPC fixture tests**

Add fixtures under `sidecar/test/fixtures/rpc/` for:

- `mcp.auth.status`
- `mcp.auth.startLogin`
- `mcp.auth.cancelLogin`
- `mcp.auth.logout`
- `mcp.auth.loginStatus`
- `mcp.auth.statusChanged`

Extend `sidecar/test/rpc-roundtrip.test.ts` and `sidecar/test/rpc-method-catalog.test.ts`.

Run:

```bash
cd sidecar
bun test test/rpc-roundtrip.test.ts test/rpc-method-catalog.test.ts
```

Expected: fail because methods are missing.

- [ ] **Implement RPC method definitions**

Modify:

- `sidecar/src/rpc/rpc-types.ts`
- `sidecar/src/rpc/method-catalog.ts`

Add exact request/result/notification types from the design.

- [ ] **Regenerate Swift/TS schema if repo requires it**

Follow the repo’s RPC generation command. If no generator is available, update generated schema files manually only after reading the existing generation pattern.

- [ ] **Run RPC tests**

```bash
cd sidecar
bun test test/rpc-roundtrip.test.ts test/rpc-method-catalog.test.ts
```

Expected: pass.

## Stage 9: MCP Auth Runtime

- [ ] **Write failing runtime tests**

Create `sidecar/test/mcp-auth-runtime.test.ts` covering:

```ts
test("status reports oauth server unauthenticated when token is missing", () => {});
test("startLogin emits starting then awaitingBrowser with authorizeUrl", () => {});
test("callback success exchanges code, stores token, and emits success plus statusChanged ready", () => {});
test("cancelLogin closes loopback and emits cancelled exactly once", () => {});
test("logout clears server-scoped auth files and emits loggedOut", () => {});
test("login failure emits failed exactly once and leaves no verifier file", () => {});
test("startLogin pre-redirect failure clears inflight session and verifier", () => {});
```

Run:

```bash
cd sidecar
bun test test/mcp-auth-runtime.test.ts
```

Expected: fail.

- [ ] **Implement runtime**

Create `sidecar/src/mcp/auth/runtime.ts`:

```ts
export class McpAuthRuntime {
  status(): McpAuthStatusResult;
  startLogin(params: { serverId: string }): Promise<McpAuthStartLoginResult>;
  cancelLogin(params: { loginId: string }): McpAuthCancelLoginResult;
  logout(params: { serverId: string }): McpAuthLogoutResult;
}
```

Reuse `sidecar/src/auth/loopback.ts`. Do not reuse `provider.*` runtime.

- [ ] **Register handlers**

Create `sidecar/src/mcp/auth/handlers.ts` and register from `sidecar/src/index.ts`.

- [ ] **Run runtime tests**

```bash
cd sidecar
bun test test/mcp-auth-runtime.test.ts
```

Expected: pass.

## Stage 10: Client Session Integration

- [ ] **Write failing client-session tests**

Extend `sidecar/test/mcp-client-session.test.ts` covering:

```ts
test("oauth streamableHttp config passes authProvider into StreamableHTTP transport", () => {});
test("missing token surfaces McpAuthRequiredError without connecting silently", () => {});
test("stdio with oauth config cannot create a session", () => {});
```

Run:

```bash
cd sidecar
bun test test/mcp-client-session.test.ts
```

Expected: fail.

- [ ] **Modify client session factory**

Modify `sidecar/src/mcp/client-session.ts`:

- Accept `McpAuthRuntime` or `McpOAuthProviderFactory`.
- For `streamableHttp.auth.type === "oauth"`, pass `{ authProvider }` to SDK transport.
- Keep static non-auth headers.
- Never construct OAuth provider for stdio.

- [ ] **Run client-session tests**

```bash
cd sidecar
bun test test/mcp-client-session.test.ts
```

Expected: pass.

## Stage 11: Tool/Host Auth Error Projection

- [ ] **Write failing host/tool tests**

Extend `sidecar/test/mcp-host-service.test.ts` and `sidecar/test/mcp-tools.test.ts` covering:

```ts
test("auth required during search returns recoverable login-required tool result", () => {});
test("auth invalidated during call returns recoverable auth-invalidated tool result", () => {});
test("protocol failures still throw as tool failures", () => {});
```

Run:

```bash
cd sidecar
bun test test/mcp-host-service.test.ts test/mcp-tools.test.ts
```

Expected: fail.

- [ ] **Implement typed errors**

Create `sidecar/src/mcp/auth/errors.ts`:

```ts
export class McpAuthRequiredError extends Error {}
export class McpAuthInvalidatedError extends Error {}
export class McpInsufficientScopeError extends Error {}
```

Modify host/tools to project typed auth errors into recoverable `isError: true` tool results. Do not swallow non-auth exceptions.

- [ ] **Run host/tool tests**

```bash
cd sidecar
bun test test/mcp-host-service.test.ts test/mcp-tools.test.ts
```

Expected: pass.

## Stage 12: Step-Up Scope Handling

- [ ] **Write failing step-up tests**

Create `sidecar/test/mcp-auth-step-up.test.ts` covering:

```ts
test("403 insufficient_scope parses required scope and starts step-up login", () => {});
test("step-up success retries original tool call once", () => {});
test("repeated step-up for same server operation and scope fails permanently", () => {});
test("403 without insufficient_scope does not start OAuth login", () => {});
```

Run:

```bash
cd sidecar
bun test test/mcp-auth-step-up.test.ts
```

Expected: fail.

- [ ] **Implement bounded step-up**

Add step-up tracking to `McpAuthRuntime` or a focused `sidecar/src/mcp/auth/step-up.ts`:

```ts
export function operationScopeKey(input: {
  serverId: string;
  operation: string;
  scope: string;
}): string;
```

Integrate with `McpClientSession.callTool()` and `listTools()` only through typed auth errors; keep broker permissions unchanged.

- [ ] **Run step-up tests**

```bash
cd sidecar
bun test test/mcp-auth-step-up.test.ts
```

Expected: pass.

## Stage 13: Streamable HTTP OAuth Integration Test

- [ ] **Create fake OAuth MCP server fixture**

Create `sidecar/test/fixtures/fake-oauth-mcp-server.ts` or a test-local HTTP server that:

- Serves MCP Streamable HTTP endpoint.
- Returns 401 with `WWW-Authenticate: Bearer resource_metadata=..., scope=...`.
- Serves protected resource metadata.
- Serves authorization server metadata with `S256`.
- Serves token endpoint.
- Validates bearer token on MCP requests.
- Returns 403 insufficient_scope for one tool until step-up token is issued.

- [ ] **Write failing integration test**

Create `sidecar/test/mcp-oauth-integration.test.ts` covering:

```ts
test("oauth MCP server discovers, logs in, lists tools, and calls through broker", () => {});
test("insufficient scope performs step-up and retries with bounded loop", () => {});
```

Run:

```bash
cd sidecar
bun test test/mcp-oauth-integration.test.ts
```

Expected: fail until runtime/session integration is complete.

- [ ] **Make integration pass**

Wire missing pieces exposed by the integration test. Do not add fallback paths not specified in the design.

- [ ] **Run integration test**

```bash
cd sidecar
bun test test/mcp-oauth-integration.test.ts
```

Expected: pass.

## Stage 14: Documentation

- [ ] **Update user guide**

Modify [docs/guide/mcp-host-guide.md](../guide/mcp-host-guide.md):

- OAuth config examples for dynamic, pre-registered, and client ID metadata document.
- Login/logout/status behavior.
- Security notes: no tokens in config, no query-string token, `resource` required.

- [ ] **Update MCP host design**

Modify [docs/designs/mcp-host.md](../designs/mcp-host.md) auth section to point to [docs/designs/mcp-oauth.md](../designs/mcp-oauth.md) and replace “future support” wording.

- [ ] **Run doc self-check**

```bash
rg -n "future support: O[A]uth|OAuth login UI.*unsupport[e]d" docs/designs docs/plans docs/guide
```

Expected: no stale statement claiming MCP OAuth is unsupported after implementation.

## Verification Standard

- [ ] `cd sidecar && bun run format:check`
- [ ] `cd sidecar && bun run lint`
- [ ] `cd sidecar && bun run typecheck`
- [ ] `cd sidecar && bun test`
- [ ] Local fake OAuth MCP integration proves:
  - protected resource discovery from `WWW-Authenticate`
  - authorization server metadata discovery
  - PKCE S256 enforcement
  - `resource` in authorize and token requests
  - token storage under `~/.notch-agent/auth/mcp/<serverId>/`
  - `StreamableHTTPClientTransport` receives SDK `OAuthClientProvider`
  - `tools/list` and `tools/call` use bearer auth
  - insufficient-scope step-up is bounded

## Open Implementation Decisions

- Shell UI design for MCP auth settings can be minimal first: status row, login, cancel, logout.
- If no Notch-owned HTTPS Client ID Metadata Document exists, the implementation still supports the mechanism through config-provided HTTPS `clientId`; it must not invent a localhost metadata document.
