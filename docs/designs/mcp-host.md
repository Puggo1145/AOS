# MCP Host 设计

## 目标

为 Notch Agent sidecar 接入 Model Context Protocol，使 Notch Agent 成为 MCP host：

- 从 `~/.notch-agent/mcp.json` 读取用户配置的 MCP servers。
- 按 progressive discovery 暴露 MCP 能力，避免把所有 server 的所有 tool schema 一次性塞进模型上下文。
- 通过 MCP client session 连接单个 server，并支持 stdio、Streamable HTTP 与认证机制。
- 由 Notch Agent host 层统一管理配置、连接生命周期、权限、人机确认、凭据策略、tool discovery 和 tool execution broker。

## 非目标

- 不把每个 MCP server tool 注册成独立 Notch tool。
- 不做 legacy SSE fallback；remote server 首发只支持 Streamable HTTP。
- 不做 programmatic tool calling / code mode；该模式需要 sandbox、stub interception、资源限制和更复杂的授权模型。
- 不让 MCP server 直接接触 LLM provider、Shell RPC 或 Notch Agent 内部 session 状态。
- 不在业务层吞掉 MCP 配置、连接或协议错误；配置错误和连接错误必须 fail fast。

## Host / Client / Server 术语边界

Notch Agent 在 MCP 架构里是 host，不只是 client。

```
Notch Agent Sidecar = MCP Host runtime
  - owns config, UX policy, permissions, credentials policy, discovery policy
  - exposes stable meta-tools to the model
  - brokers calls into MCP client sessions

MCP Client Session
  - one protocol session to one MCP server
  - Client + Transport + optional AuthProvider
  - owns initialize, tools/list, tools/call, notifications, close

MCP Server
  - external capability provider
  - exposes tools/resources/prompts over stdio or Streamable HTTP
```

`Client` 本身是协议会话机制，不是产品层能力。它可以包含 stdio / Streamable HTTP transport 和 HTTP auth provider，但 host 负责决定何时创建 client session、使用哪些凭据、如何做权限确认、如何把发现结果暴露给模型。

## 配置文件

MCP 配置独立写入：

```
~/.notch-agent/mcp.json
```

首发配置形态：

```jsonc
{
  "servers": {
    "filesystem": {
      "description": "Read and write selected local project files.",
      "transport": {
        "type": "stdio",
        "command": "npx",
        "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
        "env": {
          "EXAMPLE": "value"
        }
      }
    },
    "linear": {
      "description": "Linear issue and project management.",
      "transport": {
        "type": "streamableHttp",
        "url": "https://example.com/mcp",
        "headers": {
          "Authorization": "Bearer ${LINEAR_MCP_TOKEN}"
        }
      }
    }
  }
}
```

规则：

- 文件不存在表示用户未配置 MCP servers，是 documented first-run path。
- 文件存在但 JSON 无法解析、schema 不匹配、server id 非法或 transport 字段缺失时抛错。
- `servers` key 必须是 object；server id 是稳定 wire id，只允许简单 ASCII 标识符：`[A-Za-z0-9_-]+`。
- 每个 server 必须有非空 `description`，供 progressive discovery 的 server-level catalog 使用。
- `stdio` 必须有非空 `command`，`args` 默认 `[]`，`env` 默认 `{}`。
- `streamableHttp` 必须有合法 URL；`headers` 默认 `{}`。
- 环境变量插值只支持完整字符串形式 `${NAME}`。变量不存在时抛错，不替换为空字符串。

## 架构总览

```
┌──────────────────────────────────────────────────────────────┐
│ Bun Sidecar                                                   │
│                                                               │
│  agent loop                                                   │
│    │ stable tools array                                       │
│    ▼                                                          │
│  MCP meta-tools                                               │
│    - mcp_search_tools                                         │
│    - mcp_get_tool_details                                     │
│    - mcp_call_tool                                            │
│    │                                                          │
│    ▼                                                          │
│  mcp/host-service.ts                                          │
│    - reads ~/.notch-agent/mcp.json                            │
│    - owns server registry                                     │
│    - owns discovery index                                     │
│    - owns permission context                                  │
│    │                                                          │
│    ├── McpClientSession(filesystem) ── stdio transport         │
│    ├── McpClientSession(linear) ─────── Streamable HTTP + auth │
│    └── McpClientSession(...)                                  │
└──────────────────────────────────────────────────────────────┘
```

The host service is the sidecar boundary. It does not leak SDK client objects into agent loop or tool registry code.

## Progressive Discovery

Notch Agent follows MCP client best practices for progressive tool discovery:

- Fetch tool definitions with MCP `tools/list`, but do not inject every definition into model context upfront.
- Give the model a small stable set of meta-tools.
- Return concise search results first; return full schemas only when the model asks for details.
- Route execution through one stable broker tool so the provider `tools` array remains stable across turns.

### Layer 1: Catalog

`mcp_search_tools({ query, detailLevel? })`

Returns concise matches grouped by source server:

```jsonc
{
  "matches": [
    {
      "name": "filesystem.read_file",
      "serverId": "filesystem",
      "toolName": "read_file",
      "description": "Read a file from the configured filesystem root."
    }
  ]
}
```

Behavior:

- Search uses a local keyword/BM25-style index over server id, server description, tool name and tool description.
- The index is host-side and may connect to a server on demand to fetch `tools/list`.
- The result is intentionally compact: no full JSON schema unless `detailLevel` asks for it and the result set is small.
- Search results use canonical tool names: `<serverId>.<toolName>`.

### Layer 2: Inspect

`mcp_get_tool_details({ name })`

Returns exactly one tool's complete definition:

```jsonc
{
  "name": "filesystem.read_file",
  "serverId": "filesystem",
  "toolName": "read_file",
  "description": "...",
  "inputSchema": { "type": "object", "properties": {}, "required": [] },
  "annotations": {}
}
```

Behavior:

- Connects to the server if needed.
- Uses cached `tools/list` data when valid.
- Throws if the server or tool does not exist.
- Does not execute the tool.

### Layer 3: Execute

`mcp_call_tool({ name, arguments })`

Routes one call to the target MCP server:

```jsonc
{
  "name": "filesystem.read_file",
  "arguments": {
    "path": "/tmp/example.txt"
  }
}
```

Behavior:

- Resolves `name` into `{ serverId, toolName }`.
- Connects to the server if needed.
- Calls MCP `tools/call`.
- Converts MCP content blocks into Notch Agent `ToolResultContent`.
- Preserves MCP `isError: true` as recoverable tool output, not as a transport failure.
- Throws transport/protocol failures; the existing tool dispatch path reports those as tool failures.

## Dynamic Server Management

Default behavior is lazy:

- Read `mcp.json` at sidecar boot.
- Do not connect every server at startup.
- Connect when search/inspect/execute needs that server.
- Keep connected sessions alive for the sidecar process unless the host explicitly refreshes or shuts down.

This matches general-purpose agent behavior: the user's intent is not known upfront, so server connections and tool schemas enter the host cache only when needed.

Shell Settings exposes the configured server registry through a small Host
management RPC surface:

- `mcp.status()` returns all configured servers from `mcp.json` with
  transport type, connection state, auth state and any last connection error.
- `mcp.getConfig({ serverId })` returns the editable raw config fields for a
  single server so Settings can prefill the Edit form without exposing the
  full `mcp.json` document editor.
- `mcp.add({ serverId, description, transportType, ... })` validates and
  atomically writes a new server entry to `mcp.json`, then registers it in the
  Sidecar Host/Auth runtimes without requiring a Sidecar restart. Duplicate
  `serverId` values fail loudly; Add never overwrites existing config.
- `mcp.update({ serverId, description, transportType, ... })` validates and
  atomically replaces an existing server entry, closes any live session, clears
  cached tool definitions and keeps the same `serverId`. The first Settings
  version does not support renaming server IDs.
- `mcp.connect({ serverId })` explicitly opens the server session and loads
  `tools/list`. For OAuth servers, Shell may first drive `mcp.auth.startLogin`
  and continue connect after login success.
- `mcp.disconnect({ serverId })` closes the MCP transport/client session and
  clears cached tool definitions without deleting config or OAuth tokens.
- `mcp.delete({ serverId })` removes the server from `mcp.json`, closes any
  live session and clears server-scoped MCP OAuth files.
- `mcp.statusChanged` notifies Shell after connect/disconnect/failure so the
  Settings page does not poll while visible.

The Settings page renders the initial view as configured MCP item cards:
server name on the left; connection/auth status, Connect/Disconnect button
and an ellipsis menu on the right. The ellipsis menu owns Edit and destructive
config deletion. The same MCP page has an Add MCP entry point that opens a
focused form for `stdio` and Streamable HTTP config. Args, env and headers are
parsed as JSON in Shell and revalidated by the Sidecar config parser before
write.

## Tool Definition Cache and Refresh

Each `McpClientSession` memoizes the most recent `tools/list` result.

Invalidation rules:

- Receiving `notifications/tools/list_changed` for a server invalidates that server's cached tool list and search index entries.
- Manual host refresh invalidates all cached tool lists and closes existing client sessions.
- Sidecar restart starts from an empty in-memory cache.

The cache is host-side only. It does not mean the full schemas are always present in model context.

## Permission Model

MCP meta-tools participate in the existing permission gateway:

| Tool | Policy |
|---|---|
| `mcp_search_tools` | allow; only reads configured capability metadata |
| `mcp_get_tool_details` | allow; only reads one tool schema |
| `mcp_call_tool` | ask by default; `fullAccess` bypasses approval like other tools |

`mcp_call_tool` approval UI must include:

- MCP server id
- MCP tool name
- Canonical name
- Arguments summary
- Risk label `high` by default

The host cannot assume a dynamic MCP tool is safe from its name or schema alone. Per-tool policy can be added later, but the first version uses a single conservative external-tool execution policy.

## Prompt Caching

The agent loop should see a stable Notch tool array:

- Built-in tools.
- The three MCP meta-tools.

It should not add/remove a dynamic MCP tool definition mid-conversation. This preserves provider prompt cache behavior better than registering a dynamic Notch tool for every MCP server tool.

## Auth and Credentials

The MCP client session layer can use SDK auth providers for HTTP transports, but host owns credential policy.

Implemented first-version support:

- `headers` from `mcp.json` for Streamable HTTP.
- Environment variable interpolation in header values.
- Streamable HTTP OAuth through server-scoped `mcp.auth.*` RPC, Sidecar token storage, SDK `OAuthClientProvider`, PKCE, and bounded step-up authorization.

OAuth protocol details are specified separately in
[docs/designs/mcp-oauth.md](./mcp-oauth.md).

Credentials are never shown to the model. The model sees server ids, tool names, descriptions and schemas only.

## SDK Choice

Use the official TypeScript SDK for MCP client sessions. The exact package/import path should follow the stable SDK generation used at implementation time. The design boundary is:

- `Client` for one MCP protocol session.
- `StdioClientTransport` for local process-spawned servers.
- `StreamableHTTPClientTransport` for remote servers.
- SDK auth provider hooks for authenticated HTTP transports.

## Error Handling

Fail fast and loudly:

- Malformed `mcp.json` throws a typed config error.
- Unknown transport type throws.
- Missing environment variable referenced by config throws.
- Duplicate canonical tool names throw.
- Server connection failure surfaces as the meta-tool result failure or sidecar boot failure if triggered during boot validation.
- MCP `isError: true` from `tools/call` is not a transport failure; it is returned to the model as recoverable tool output.

No silent fallback to SSE, no empty-header substitution, no best-effort partial config loading.
