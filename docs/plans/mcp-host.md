# MCP Host 实现计划

设计依据：[docs/designs/mcp-host.md](../designs/mcp-host.md)

## Stage 1：MCP 配置存储

- 新增 `sidecar/src/mcp/config.ts`。
- 实现 `mcpConfigPath()` 指向 `~/.notch-agent/mcp.json`。
- 实现 `readMcpConfig()`：
  - missing file -> `{ servers: {} }`
  - malformed JSON -> typed error
  - invalid schema -> typed error
  - invalid server id -> typed error
  - missing env interpolation -> typed error
- 支持 transport union：
  - `{ type: "stdio", command, args?, env? }`
  - `{ type: "streamableHttp", url, headers? }`
- 测试：
  - missing file returns empty config
  - malformed JSON throws
  - top-level non-object throws
  - server missing description throws
  - stdio missing command throws
  - HTTP invalid URL throws
  - `${ENV_NAME}` interpolates only when env exists

## Stage 2：SDK 依赖和 Client Session

- 引入官方 MCP TypeScript SDK client dependency。
- 新增 `sidecar/src/mcp/client-session.ts`。
- 定义 `McpClientSession`：
  - `connect()`
  - `listTools()`
  - `callTool(toolName, args)`
  - `close()`
  - `invalidateToolCache()`
- 根据 config 创建 transport：
  - stdio -> SDK `StdioClientTransport`
  - Streamable HTTP -> SDK `StreamableHTTPClientTransport`
- 为 Streamable HTTP headers 接入 host-resolved header map。
- 注册 `notifications/tools/list_changed` handler，触发 tool cache invalidation。
- 测试：
  - stdio config creates stdio session factory input
  - HTTP config creates HTTP session factory input
  - `listTools()` memoizes until invalidated
  - `tools/list_changed` invalidates cached definitions
  - `close()` closes SDK client

## Stage 3：Host Service 和 Discovery Index

- 新增 `sidecar/src/mcp/host-service.ts`。
- Host service 负责：
  - 持有 server registry
  - 延迟创建 `McpClientSession`
  - 维护 canonical tool name `<serverId>.<toolName>`
  - 维护 keyword search index
  - 按需 connect/list tools
- 实现：
  - `searchTools(query, detailLevel?)`
  - `getToolDetails(name)`
  - `callTool(name, arguments)`
  - `refreshServer(serverId)`
  - `closeAll()`
- 搜索首发用简单可测的 keyword scoring，不引入 embedding/subagent。
- 测试：
  - search returns server-grouped concise matches
  - search can use server description before connection
  - inspecting a tool connects and returns exactly one schema
  - calling unknown server/tool throws
  - duplicate canonical names throw during index build

## Stage 4：MCP Meta-Tools

- 新增 `sidecar/src/agent/tools/builtins/mcp.ts` 或 `sidecar/src/mcp/tools.ts`。
- 注册三个稳定 meta-tools：
  - `mcp_search_tools`
  - `mcp_get_tool_details`
  - `mcp_call_tool`
- Tool schemas must be strict:
  - `mcp_search_tools`: `{ query: string, detailLevel?: "names" | "descriptions" | "schemas" }`
  - `mcp_get_tool_details`: `{ name: string }`
  - `mcp_call_tool`: `{ name: string, arguments: object }`
- `mcp_call_tool` converts MCP content into Notch `ToolResultContent`:
  - text -> text
  - image -> image when MIME/data are present
  - unsupported content -> explicit text error or typed throw, not silent drop
- Tests:
  - meta-tools appear in registry with stable names
  - search tool does not return full schemas by default
  - inspect returns full input schema
  - call forwards canonical name and arguments to host service
  - MCP `isError: true` becomes Notch recoverable `isError: true`

## Stage 5：Permissions

- Extend permission policy types so dynamic host-brokered MCP execution does not require a static policy per remote tool.
- Add policies:
  - `mcp_search_tools` -> allow
  - `mcp_get_tool_details` -> allow
  - `mcp_call_tool` -> ask
- Approval payload for `mcp_call_tool` includes:
  - server id
  - MCP tool name
  - canonical name
  - arguments summary
- Preserve current startup assertion for static registered tools by adding policies for the three meta-tools, not for every MCP server tool.
- Tests:
  - startup policy assertion passes with MCP meta-tools
  - search/details are allowed without Shell approval
  - call requests approval in default mode
  - call is allowed in `fullAccess`

## Stage 6：Sidecar Bootstrap

- In `sidecar/src/index.ts`:
  - read `mcp.json`
  - construct process-wide `McpHostService`
  - register MCP meta-tools before agent loop runs
  - ensure `closeAll()` is reachable for process shutdown paths where practical
- Do not connect all configured servers at boot.
- Boot should fail only for invalid local config, not for a lazy server that is merely configured but unused.
- Tests:
  - valid empty MCP config boots with meta-tools
  - invalid MCP config fails loudly
  - configured lazy server is not connected during bootstrap

## Stage 7：Shell Settings MCP Management

- Add `mcp.*` RPC schema and fixtures:
  - `mcp.status`
  - `mcp.getConfig`
  - `mcp.add`
  - `mcp.update`
  - `mcp.connect`
  - `mcp.disconnect`
  - `mcp.delete`
  - `mcp.statusChanged`
- Extend `McpHostService` with:
  - Settings-facing status projection
  - add server after persisted config creation
  - update server after persisted config edit, closing any live session
  - explicit connect/disconnect
  - failed connection state with last error
  - remove server after persisted config deletion
- Add `deleteMcpServerConfig(serverId)` that edits
  `~/.notch-agent/mcp.json` atomically and preserves unrelated raw server
  config.
- Add `addMcpServerConfig(...)` that validates `serverId`, transport-specific
  fields, duplicate IDs and structured args/env/headers before atomically
  writing a new server entry.
- Add `getMcpServerConfig(serverId)` and `updateMcpServerConfig(...)` for the
  Settings Edit flow. Edit keeps the same `serverId`; renaming is out of scope.
- Add `McpService` in Shell:
  - `refreshStatus()`
  - `config(serverId:)`
  - `add(_:)`
  - `update(_:)`
  - `connect(serverId:)`
  - `disconnect(serverId:)`
  - `delete(serverId:)`
  - handle `mcp.statusChanged`, `mcp.auth.statusChanged`,
    `mcp.auth.loginStatus`
- Shell Settings UI:
  - main page shows MCP summary row
  - MCP subpage lists configured item cards
  - MCP subpage exposes Add MCP
  - Add MCP form supports `stdio` command/args/env and Streamable HTTP
    url/headers
  - card left: server name/description
  - card right: connection/auth status, Connect/Disconnect button, ellipsis menu
  - ellipsis menu edits or deletes the MCP config
- Tests:
  - RPC fixtures roundtrip on Swift and TS sides
  - Sidecar config add writes only the new server and rejects duplicates
  - Sidecar config get/update preserves raw editable values and rejects missing
    server IDs
  - Sidecar config deletion removes only target server
  - Host status/connect/disconnect/failure/update/remove behavior
  - Shell service requests `mcp.add` and inserts the returned server
  - Shell service requests `mcp.getConfig` and `mcp.update` for Edit
  - Shell service requests `mcp.status` and starts OAuth before transport
    connect when auth is missing

## Stage 8：Documentation and User Configuration Examples

- Add example `mcp.json` snippets to developer guide or README.
- Document supported transports:
  - stdio
  - Streamable HTTP
- Document current auth support:
  - static headers
  - environment variable interpolation
  - OAuth via MCP Settings Connect flow
- Document unsupported first-version items:
  - legacy SSE fallback
  - programmatic/code-mode tool calling

## Verification Standard

- `bun test` passes in `sidecar/`.
- `bun run typecheck` passes in `sidecar/`.
- Permission policy assertion catches any registered MCP meta-tool without a policy.
- A local fake MCP server test proves:
  - host can connect
  - host can discover tools
  - model-visible search result is compact
  - inspect returns full schema
  - call executes through the broker
- No test should merely assert that mocked code was called if it does not prove the Notch-facing behavior.
