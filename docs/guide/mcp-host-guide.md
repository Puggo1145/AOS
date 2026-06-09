# MCP Host Guide

Notch Agent Sidecar acts as an MCP host. It reads server configuration from:

```text
~/.notch-agent/mcp.json
```

If the file is missing, MCP starts with an empty server registry. If the file exists but is malformed, Sidecar fails loudly during bootstrap.

## Example

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
          "EXAMPLE_TOKEN": "${FILESYSTEM_MCP_TOKEN}"
        }
      }
    },
    "linear": {
      "description": "Linear issue and project management.",
      "transport": {
        "type": "streamableHttp",
        "url": "https://example.com/mcp",
        "headers": {
          "Authorization": "${LINEAR_MCP_TOKEN}"
        }
      }
    }
  }
}
```

## Supported Transports

- `stdio`: spawns a local MCP server process with `command`, optional `args`, and optional `env`.
- `streamableHttp`: connects to a remote MCP endpoint with `url` and optional static `headers`.

## Auth

Supported auth:

- Static HTTP headers in `mcp.json`.
- Full-string environment interpolation: `"${ENV_NAME}"`.
- Streamable HTTP OAuth via server-scoped `mcp.auth.*` login/logout/status RPC.
- Dynamic client registration, pre-registered clients, and HTTPS Client ID Metadata Document client IDs.

Partial interpolation such as `"Bearer ${TOKEN}"` is rejected. Put the complete header value in the environment variable instead.

OAuth example:

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
    }
  }
}
```

Pre-registered clients use `registration.type: "preRegistered"` with `clientId` and optional `clientSecret`. Client ID Metadata Document clients use `registration.type: "clientIdMetadataDocument"` and an HTTPS `clientId` URL with a non-root path. OAuth tokens are stored under `~/.notch-agent/auth/mcp/<serverId>/`, not in `mcp.json`.

## Tool Discovery

Sidecar registers three stable Notch tools:

- `mcp_search_tools`
- `mcp_get_tool_details`
- `mcp_call_tool`

Remote MCP tools are not registered directly as Notch tools. The model searches compact metadata first, asks for one full schema when needed, then executes through the stable call broker.

## Unsupported In The First Version

- Legacy SSE fallback.
- Programmatic/code-mode MCP tool calling.
- Per-remote-tool permission policies.
