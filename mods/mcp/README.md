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

## Methods

`initialize` and `ping` answer before the session is ready; `tools/list` and
`tools/call` answer after `initialize` + `notifications/initialized`, and are
`-32002` before that. Frames without an `id` are notifications and get no
response body. Anything else is `-32601`; malformed JSON is `-32700`; a batch
array or a non-object frame is `-32600`.

## Tools (`tools/list`)

| Tool | Arguments | Result |
|---|---|---|
| `server_status` | none | text: `ticks=`, `entities=`, `players=`, `zombies=`, `bots=` from the sense snapshot |
| `player_list` | none | text: one `id= x= y= z= hp=` line per player, or `no players in snapshot` |
| `admin_command` | `verb` (string, required) | text: the queued verb, or the failure |

A tool that cannot answer returns `isError: true` with a one-line reason (no
world data, verb not in allowlist, verb too long, queue rejected) rather than a
guessed value. `admin_command` verbs are matched by prefix against the
`mcp.allowlist` query surface, so an allowlist entry `say` permits `say hi`.

## Config

`[mcp]`-adjacent server settings are CLI/zdtd.toml (`--mcp-port`,
`--mcp-token`, `--mcp-allowlist`; `docs/rfc/0002-mcp-server-design.md`).

## Enable

Auto-discovered (`tier = "official"`); needs `--mcp-port N` to serve.

## Layout (self-contained)

- `manifest.toml`, `mcp.wasm`, `mcp.zig` + `main.zig` (source), `README.md`
