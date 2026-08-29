# mcp

Official MCP server addon (ADR 0031): JSON-RPC 2.0 over the host transport
bridge.

## What it is

A Model Context Protocol server shipped as a Wasm plugin. Protocol logic lives
in the guest; the host provides a streamable-HTTP endpoint
(`--mcp-port`, loopback + optional `--mcp-token`) and std.json parsing
(`json_*` imports) - the guest never parses JSON.

## Hooks / surface

- `on_mcp_frame` (request/reply: one JSON-RPC frame per call)
- Host verbs: `zdtd.json_parse`, `zdtd.json_str`, `zdtd.json_raw`,
  `zdtd.json_obj`, `zdtd.queue`

## Config

`[mcp]`-adjacent server settings are CLI/zdtd.toml (`--mcp-port`,
`--mcp-token`, `--mcp-allowlist`; `docs/rfc/0002-mcp-server-design.md`).

## Enable

Auto-discovered (`tier = "official"`); needs `--mcp-port N` to serve.

## Layout (self-contained)

- `manifest.toml`, `mcp.wasm`, `mcp.zig` + `main.zig` (source), `README.md`
