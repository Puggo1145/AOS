# MCP OAuth Host 设计

依据：

- MCP Authorization specification 2025-11-25: <https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization>
- Existing MCP host design: [docs/designs/mcp-host.md](./mcp-host.md)

## 目标

为 Streamable HTTP MCP servers 增加符合 MCP Authorization 2025-11-25 的 OAuth Host 能力：

- Sidecar 作为 MCP Host / OAuth Client，按 spec 完成 protected resource discovery、authorization server discovery、client registration、PKCE、token exchange、refresh、step-up scope upgrade 和 token storage。
- `McpClientSession` 为 `StreamableHTTPClientTransport` 注入 SDK `OAuthClientProvider`，而不是把 bearer token 暴露给模型或工具参数。
- Shell 提供用户可见的 login/logout/status UX，Sidecar 持有协议状态机和 token 文件。
- stdio transport 不走 MCP OAuth；stdio server 仍然通过 `env` / process config 获取凭据。

## 非目标

- 不实现自有 OAuth authorization server。
- 不把 MCP access token、refresh token、client secret、authorization code、PKCE verifier、state 传给模型。
- 不把 OAuth 登录复用到 LLM provider 的 `provider.*` RPC；MCP server 登录是 server-scoped，不是 provider-scoped。
- 不绕过 `mcp_call_tool` 的权限审批。OAuth 只证明“Notch 有权访问 MCP server”，不证明“这次工具执行安全”。
- 不支持 legacy SSE fallback。

## 规范约束

### Transport Scope

MCP Authorization 只适用于 HTTP-based transports。Sidecar 对 `transport.type === "streamableHttp"` 支持 OAuth；对 `stdio` 明确拒绝 `auth.type === "oauth"`。

### Discovery Requirements

Host 必须支持两层 discovery：

1. Protected Resource Metadata discovery:
   - 优先解析 `401 WWW-Authenticate` header 中的 `resource_metadata`。
   - 没有 header URL 时按 well-known URI fallback：
     - endpoint path form: `/.well-known/oauth-protected-resource/<mcp-path>`
     - root form: `/.well-known/oauth-protected-resource`
   - 如 `WWW-Authenticate` 提供 `scope`，当前请求必须以该 scope 为准。
2. Authorization Server Metadata discovery:
   - 支持 OAuth Authorization Server Metadata。
   - 支持 OpenID Connect Discovery。
   - 对 path issuer 按 spec 顺序尝试 path insertion / OIDC path insertion / OIDC path append。

### Client Registration Priority

Host 支持 spec 中所有 registration approaches，并按优先级选择：

1. Pre-registered client information from `mcp.json` or Shell secure settings.
2. OAuth Client ID Metadata Documents, when authorization server advertises `client_id_metadata_document_supported` and config provides a HTTPS metadata URL.
3. Dynamic Client Registration, when authorization server exposes `registration_endpoint`.
4. User-entered client information through Shell settings.

Desktop app 本身不能假装有公开 HTTPS metadata document。若没有 Notch-owned HTTPS metadata URL 或用户配置的 metadata URL，Client ID Metadata Documents path 必须 fail fast，而不是降级为不符合规范的 localhost metadata document。

### PKCE

Authorization Code flow 必须使用 PKCE S256。Host 必须在 auth server metadata 中确认 `code_challenge_methods_supported` 包含 `S256`；字段缺失或不包含 `S256` 时拒绝登录。

### Resource Indicator

Host 必须在 authorization request 和 token request 中包含 `resource` 参数。默认 canonical resource URI 来自 MCP endpoint URL：

- 保留 scheme、host、port、必要 path。
- 移除 fragment。
- 默认去掉无语义 trailing slash。
- 用户可在 config 中覆盖 `resource`，但必须是带 scheme 的 absolute URI 且不能包含 fragment。

### Token Usage

Host 必须通过 HTTP `Authorization: Bearer <access-token>` header 发送 token。禁止 query string token。所有发往 MCP HTTP server 的 requests 都必须带 token，包括同一 logical session 后续请求。

### Scope Selection And Step-Up

初始 scope selection：

1. 使用 initial `WWW-Authenticate` challenge 的 `scope`。
2. 无 challenge scope 时，使用 Protected Resource Metadata 的 `scopes_supported` 全集。
3. 如果没有 `scopes_supported`，authorization request 不带 `scope`。

Runtime insufficient scope:

- 解析 `403 WWW-Authenticate` 中的 `error="insufficient_scope"`、`scope`、`resource_metadata`。
- 发起 step-up authorization。
- 重新连接 / 重试原始请求，但对同一 server + operation 有 retry 上限。
- 超过上限后作为 permanent auth failure 暴露给 Shell 和 tool result。

## 配置

扩展 `~/.notch-agent/mcp.json`：

```jsonc
{
  "servers": {
    "linear": {
      "description": "Linear issue and project management.",
      "transport": {
        "type": "streamableHttp",
        "url": "https://example.com/mcp",
        "auth": {
          "type": "oauth",
          "redirect": {
            "host": "127.0.0.1",
            "port": 0,
            "path": "/mcp/oauth/callback"
          },
          "registration": {
            "type": "dynamic"
          }
        }
      }
    },
    "preRegistered": {
      "description": "Pre-registered MCP server.",
      "transport": {
        "type": "streamableHttp",
        "url": "https://mcp.example.com/mcp",
        "auth": {
          "type": "oauth",
          "resource": "https://mcp.example.com/mcp",
          "registration": {
            "type": "preRegistered",
            "clientId": "${MCP_CLIENT_ID}",
            "clientSecret": "${MCP_CLIENT_SECRET}"
          }
        }
      }
    },
    "metadataDoc": {
      "description": "MCP server using Client ID Metadata Documents.",
      "transport": {
        "type": "streamableHttp",
        "url": "https://mcp.example.com",
        "auth": {
          "type": "oauth",
          "registration": {
            "type": "clientIdMetadataDocument",
            "clientId": "https://notch.example.com/oauth/mcp-client.json"
          }
        }
      }
    }
  }
}
```

Rules:

- `auth.type === "oauth"` only valid for `streamableHttp`.
- `headers` and `auth.type === "oauth"` are mutually exclusive for `Authorization`; non-auth static headers remain valid.
- Env interpolation follows existing full-string `${NAME}` rule.
- Missing or invalid OAuth config fails during MCP config load.
- OAuth runtime-discovered metadata and tokens are not written to `mcp.json`.

## Storage

OAuth state lives under:

```text
~/.notch-agent/auth/mcp/<serverId>/
  tokens.json
  client.json
  verifier.json
  discovery.json
```

File responsibilities:

- `tokens.json`: access token, refresh token, expiry, granted scopes, token type, authorization server issuer, resource URI.
- `client.json`: dynamically registered client information, or cached user-entered/pre-registered metadata when needed.
- `verifier.json`: in-flight PKCE code verifier + state + redirect URI + resource + requested scope. Deleted after success/failure/cancel.
- `discovery.json`: protected resource metadata URL, protected resource metadata, authorization server metadata, selected authorization server URL.

All files are mode `0600`; directory is mode `0700`; writes are atomic sibling tmpfile + rename. Malformed token/client/verifier/discovery files fail loudly for explicit auth paths and surface unauthenticated for passive status reads.

## Sidecar Modules

```text
sidecar/src/mcp/auth/
  config.ts              # OAuth config schema helpers; imported by mcp/config.ts
  storage.ts             # server-scoped token/client/verifier/discovery persistence
  discovery.ts           # RFC9728 + RFC8414/OIDC discovery helpers
  resource.ts            # canonical resource URI resolution and validation
  registration.ts        # preRegistered / clientIdMetadataDocument / dynamic helper tests
  provider.ts            # NotchMcpOAuthProvider implements SDK OAuthClientProvider
  runtime.ts             # login/cancel/logout/status orchestration
  errors.ts              # typed auth errors for Shell/tool/session projection
```

`McpClientSession` only sees an `OAuthClientProvider` instance. It must not know where tokens are stored or how the Shell starts login.

## SDK OAuthClientProvider Mapping

`NotchMcpOAuthProvider(serverId, config, runtime)` implements the SDK provider surface:

- `redirectUrl`: loopback redirect URI for this auth attempt.
- `clientMetadata`: metadata for pre-registered, metadata-document, or dynamic registration.
- `state()`: returns persisted state for the current login attempt.
- `clientInformation()` / `saveClientInformation()`: read/write `client.json`.
- `tokens()` / `saveTokens()`: read/write `tokens.json`.
- `redirectToAuthorization(url)`: notify Shell with authorize URL; Shell opens browser.
- `saveCodeVerifier()` / `codeVerifier()`: write/read `verifier.json`.
- `invalidateCredentials(scope)`: delete scoped token/client/verifier/discovery files and notify Shell.
- `validateResourceURL(serverUrl, resource)`: enforce configured/canonical resource URI matches the MCP server.
- `saveAuthorizationServerUrl()` / `authorizationServerUrl()`: persist selected authorization server.
- `saveResourceUrl()` / `resourceUrl()`: persist protected resource URI.
- `saveDiscoveryState()` / `discoveryState()`: persist discovery state.
- Token request parameters, `resource`, PKCE params, public-client `client_id`, and configured client-secret authentication stay on the SDK default auth/token exchange path. The provider must not partially override that path.

If the SDK changes this interface, `provider.ts` is the only module that should absorb the difference.

## Login Flow

1. Shell calls `mcp.auth.startLogin { serverId }`.
2. Sidecar validates server exists and is `streamableHttp` + OAuth.
3. Sidecar starts loopback callback server.
4. Sidecar performs protected resource and authorization server discovery.
5. Sidecar resolves client registration using the priority order.
6. Sidecar verifies PKCE S256 support.
7. Sidecar computes resource URI and requested scope.
8. Sidecar persists verifier state.
9. SDK/provider builds authorization URL with `response_type=code`, `client_id`, `redirect_uri`, `state`, `code_challenge`, `code_challenge_method=S256`, `resource`, and optional `scope`.
10. Sidecar notifies Shell with login status and authorize URL.
11. Shell opens browser.
12. Loopback validates path, state, and code.
13. Sidecar exchanges code for tokens using `resource` and `code_verifier`.
14. Sidecar writes `tokens.json`, deletes verifier, closes loopback, notifies Shell ready.

Every terminal path sends exactly one login status notification: `success`, `failed`, or `cancelled`.

## Runtime Auth Flow

When `McpClientSession.connect()` creates `StreamableHTTPClientTransport`:

- If `auth.type === "oauth"`, pass `authProvider: NotchMcpOAuthProvider`.
- If no token exists, session connect fails with typed `McpAuthRequiredError`.
- `mcp_search_tools`, `mcp_get_tool_details`, and `mcp_call_tool` surface this as a recoverable tool result telling the model/user that the server needs login; Shell also receives MCP auth status.
- If token exists but is expired and refresh token exists, provider refreshes before request.
- On refresh failure, provider quarantines tokens and reports unauthenticated.

## Step-Up Flow

For `403 insufficient_scope`:

1. Parse `WWW-Authenticate`.
2. Store pending operation key: `serverId + canonical tool name + requested scope`.
3. Start login with upgraded scope.
4. Retry the original MCP request once after success.
5. Refuse repeated step-up loops for the same operation/scope during the process lifetime.

For `401` without valid token:

- Invalidate token.
- Request login.
- Do not silently retry without user authorization.

## RPC Surface

Add MCP-specific auth RPC. These are separate from `provider.*` because MCP auth is per configured server.

```ts
mcp.auth.status(): {
  servers: Array<{
    serverId: string
    state: "notConfigured" | "unauthenticated" | "authenticating" | "ready" | "failed"
    authType: "none" | "headers" | "oauth"
    authorizationServerUrl?: string
    resource?: string
    scopes?: string[]
    message?: string
  }>
}

mcp.auth.startLogin({ serverId: string }): {
  loginId: string
  authorizeUrl: string
}

mcp.auth.cancelLogin({ loginId: string }): {
  cancelled: boolean
}

mcp.auth.logout({ serverId: string }): {
  cleared: boolean
}

mcp.auth.loginStatus notification:
{
  loginId: string
  serverId: string
  state: "starting" | "awaitingBrowser" | "awaitingCallback" | "exchanging" | "success" | "failed" | "cancelled"
  authorizeUrl?: string
  message?: string
}

mcp.auth.statusChanged notification:
{
  serverId: string
  state: "unauthenticated" | "authenticating" | "ready" | "failed"
  reason?: "loginRequired" | "authInvalidated" | "insufficientScope" | "loggedOut"
  message?: string
}
```

Shell is responsible for opening the browser and rendering status. Sidecar is responsible for all OAuth protocol validation and token persistence.

## Error Handling

Fail fast and loudly:

- OAuth configured for stdio throws config error.
- Missing `S256` support throws auth setup error.
- Invalid resource URI throws config/runtime auth error.
- No compatible client registration path throws auth setup error.
- Malformed token/client/discovery files throw on active login/connect paths.
- Token refresh failure invalidates/quarantines token and surfaces unauthenticated.
- Repeated step-up attempts for same operation/scope stop with a permanent auth error.

Recoverable model-visible errors:

- Server requires login.
- User cancelled login.
- Insufficient scope requires user authorization.

Security failures are not recoverable silently.

## Security

- Store tokens in Sidecar-owned files with `0600` permissions; future Shell Keychain migration can replace storage behind `storage.ts`.
- Never log token values, authorization codes, refresh tokens, client secrets, or verifier.
- Never include tokens in query strings.
- Always send `resource` during authorization and token requests.
- Validate redirect `state`.
- Use loopback only for redirect, with exact path check.
- Treat Client ID Metadata Document URLs as HTTPS-only; no localhost metadata document.
- Do not accept token passthrough from user config.
- Do not let MCP server-provided metadata choose arbitrary redirect URIs.

## Testing Strategy

- Unit tests for config validation and transport/auth combinations.
- Unit tests for resource URI canonicalization.
- Unit tests for `WWW-Authenticate` parsing and protected resource metadata fallback order.
- Unit tests for authorization server metadata discovery endpoint order.
- Unit tests for registration priority and each registration approach.
- Unit tests for PKCE S256 enforcement.
- Unit tests for storage permissions and malformed file handling.
- Unit tests for `NotchMcpOAuthProvider` method mapping.
- RPC roundtrip fixtures for `mcp.auth.*`.
- Runtime tests for login success/cancel/failure terminal notifications.
- Integration test with local fake Streamable HTTP MCP server requiring OAuth:
  - 401 challenge discovery.
  - browser URL generation includes `resource` and PKCE.
  - callback exchange stores token.
  - MCP `tools/list` succeeds with bearer token.
  - 403 insufficient scope triggers step-up and bounded retry.
