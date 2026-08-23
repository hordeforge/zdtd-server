# MCP Server Addon - Design (`MCP_DESIGN.md`)

**Status:** implements [MCP_PRD.md](MCP_PRD.md) and
[ADR 0031](adr/0031-mcp-wasm-module.md). Decisions below are recorded in the
ADR; this document fixes the concrete shape: layout, transport bridge, frame
flow, caps, tests.

---

## 1. Goal and inputs

Ship an MCP server as a drop-in Wasm plugin: guest owns protocol, host owns
transport and JSON parsing (ADR 0031 D1/D3). One `.wasm` in `[plugin] modules`
plus one new host file, one new guest export (`on_mcp_frame`), the host
std.json capability (`json_*` imports), and an `[mcp]` config section.
Nothing on the tick path except one hook call per pending frame, no hot-path
heap, and no stock wire involvement.

## 2. Module layout

```
mods/zdtd_mcp/
  zdtd_mcp.c        guest: JSON-RPC 2.0 + MCP session + tool registry
  zdtd_mcp.wasm     committed build artifact (clang, freestanding wasm32)

src/server/mcp_transport.zig   host: listener + sessions + frame rings + auth
                               (new; registered beside webui.zig, gated by [mcp])
```

Guest build (mirrors `mods/zdtd_bot/`; the `.wasm` is committed). `-fno-builtin`
keeps clang from lowering the guest's small loops into libc calls (strlen,
memcmp) that freestanding wasm32 has no definitions for:

```bash
clang --target=wasm32 -nostdlib -O2 -fno-builtin -Wl,--no-entry -Wl,--export-all \
  -o mods/zdtd_mcp/zdtd_mcp.wasm mods/zdtd_mcp/zdtd_mcp.c
```

Guest exports: `on_enable`, `on_shutdown`, `on_mcp_frame`, `_zdtd_requires`
(all hooks listed in `_zdtd_requires` so a typo fails load, ADR 0030).
Guest imports (PLUGIN_DEV.md + the std.json capability, ADR 0031 D3):
`zdtd` . `log`, `tick`, `sense`, `query`, `queue`, `json_parse`, `json_str`,
`json_raw`, `json_obj`. No WASI, no libc, no socket, no JSON parser in the
guest.

## 3. Host transport bridge (`src/server/mcp_transport.zig`)

One `Transport` struct, constructed when `--mcp-port != 0`, in the same style
as `webui.zig`. **Polled from the main loop like webui/admin (ADR 0012
single-threaded tick) — there are no transport threads, queues, or condvars:**
one connection and one complete request per `poll()` call, processed
synchronously through the frame handler.

- **Listener:** `util/tcp_listen` + `std.http.Server`; only `POST /mcp` is
  served. Wrong path/method, transfer encoding, an oversized frame
  (`max_frame_kib`), and a missing token are HTTP errors, never a half-read
  frame.
- **Auth:** `--mcp-token` (empty = loopback only, no token) is checked against
  `Authorization: Bearer` and `X-Zdtd-Secret` in constant time
  (`util/secret.zig`); default bind is `127.0.0.1`. No new trust boundary
  (ADR 0031 D2).
- **Frame handling:** the poll reads a full request, then calls the Game's
  frame handler (`mcpFrameThunk` -> the plugin exporting `on_mcp_frame`):
  `on_mcp_frame(frame_ptr, frame_len, out_ptr, out_cap)`. The guest's response
  bytes are served as `application/json`; zero bytes (a notification, a closed
  session, an overflowed response) are served as `202 Accepted` with no body
  (MCP notification semantics). A guest that trapped is already disabled
  (ADR 0020) and replies nothing.
- **SSE:** not held open in MVP. The transport always answers POSTs with
  `application/json` (the spec permits this when the server has nothing to
  push); there are no server-initiated messages in MVP (no notifications, no
  `listChanged`).
- **Allocation:** recv/response buffers are fixed module consts; nothing is
  allocated per request.

Frame/response caps live in `mcp_transport.zig` (`max_frame`, `max_resp`).

## 4. Config (CLI flags, mirroring the webui precedent)

The transport is configured with CLI flags in `main.zig`, the same way the
operator WebUI is (webui is the HTTP-listener precedent in this codebase; a
toml section can follow later if operators ask):

```
--mcp-port N          MCP streamable-HTTP endpoint (0 = off; needs an MCP wasm plugin)
--mcp-bind ADDR       loopback only: 127.0.0.1 or localhost (default 127.0.0.1)
--mcp-token STR       shared token for /mcp (empty = loopback only, no token)
--mcp-allowlist LIST  comma-separated SimCommand prefixes the admin_command
                      tool may queue, e.g. "bot count,say" (default: none)
```

The allowlist is served to the guest as the `mcp.allowlist` query
(newline-separated prefixes) and enforced in the guest before `zdtd.queue`.

## 5. Guest design (`mods/zdtd_mcp/zdtd_mcp.c`)

Static memory only (no heap, no libc):

- `frame_buf[16 KiB]` (copied in by the host), `out_buf[8 KiB]` (copied out),
  `result_buf[8 KiB]` for tool results, small static strings for the
  `json_*` lookups (`sbuf`/`rbuf`/`vbuf`, 96/96/128 bytes).
- **JSON access:** the guest calls `zdtd.json_parse(frame_ptr, frame_len)`
  once per frame; the host parses with `std.json` into the plugin's fixed
  buffer (`json_buf_max`, 64 KiB, reset per frame — also the nesting bound).
  Fields are then read by dot-path: `json_str("method")`,
  `json_str("params.name")`, `json_obj("params.arguments")`,
  `json_str("params.arguments.verb")`, and `json_raw("id")` for the verbatim
  id echo. `json_str`/`json_raw` return the FULL length so the guest detects
  truncation against its buffer caps and refuses (fail closed).
  Unparseable input -> `-32700 Parse error`; a non-object frame (batch array,
  scalar) -> `-32600 Invalid request`. Batches are not supported and are
  answered with `-32600` (JSON-RPC 2.0 allows refusing batches).

Session state machine (in guest):

```
idle -> awaiting_initialize (only initialize and ping accepted)
     -> init_sent (initialize answered; only the initialized notification is
        accepted, other methods answer -32002)
     -> ready (initialized notification accepted; all methods live)
     -> closed (on_shutdown / reload)
```

Methods and their responses, per the pinned spec version (baseline
2025-06-18):

| Method | Kind | Guest behavior |
|---|---|---|
| `initialize` | request | negotiate protocol version, return capabilities `{ tools: { listChanged: false } }`; only tool capability in MVP |
| `initialized` | notification | no response; enters `ready` |
| `ping` | request | `{}` result (also accepted pre-initialize) |
| `tools/list` | request | JSON-Schema tool list from the registry (below) |
| `tools/call` | request | validate args against the registered schema, run the tool, return `{ content: [{ type: "text", text }] }` |
| anything else | - | `-32601 Method not found` (or `-32600` if malformed) |

Tool registry (bounded table; each tool has name, description, JSON-Schema
input):

- `server_status` - world name, uptime/ticks, player count, TPS. Reads a
  `sense`/`query` snapshot; host-authoritative values only.
- `player_list` - connected players (name, entity id, position). Same source.
- `admin_command` - args `{ verb: string }`. The verb is checked against the
  allowlist obtained from the host via `zdtd.query` (new query key
  `mcp.allowlist`; newline-separated verb prefixes, so `bot count` also allows
  `bot count 6`); allowed verbs are issued as SimCommands via `zdtd.queue` and
  the result returned. The allowlist is host policy read through the boundary;
  the transport token is the security boundary (see §8).

No tool may produce a result over `out_buf` cap; oversized results are
truncated to a spec error or an omitted field, never a partial frame
(ADR 0014, rule 24).

## 6. One request, end to end

1. Client POSTs `{jsonrpc:"2.0", id:1, method:"tools/call", params:{name:
   "server_status"}}` to `http://host:port/mcp` with the token (if set).
2. Listener thread verifies auth, copies the body into the session inbound
   ring, signals the tick.
3. Next tick: host drain copies the frame into `frame_buf`, calls
   `on_mcp_frame`; the guest parses via `json_parse` + `json_str`/`json_obj`,
   reads its snapshot via `sense`/`query`, renders the result into `out_buf`,
   returns the length.
4. The transport serves the response as the HTTP 200 JSON body; a zero-byte
   reply (notification, closed session, overflow) is served as `202 Accepted`
   with no body.

Latency is one poll plus the hook call; the guest never blocks the tick, and
each `poll()` serves at most one request so a flooding client is bounded by
the per-request caps, not a queue.

## 7. Buffers and caps

| Cap | Value | Note |
|---|---|---|
| `max_frame` | 16 KiB | inbound JSON-RPC body (MCP_DESIGN `max_frame_kib`) |
| `max_resp` | 8 KiB | guest response + tool result |
| `max_req` | 20 KiB | full HTTP request (frame + headers) |
| `json_buf_max` | 64 KiB | host std.json fixed buffer per plugin (also the nesting bound) |
| `max_client_polls` | 800 | incomplete-request drop (~10 s at 4 polls per tick) |

All named module consts, no magic numbers on the path.

## 8. Security

- Default `bind = 127.0.0.1`, `--mcp-port 0` (off). A non-loopback bind is an
  explicit operator choice.
- `--mcp-token` uses `util/secret.zig` constant-time compare; no token logging.
- `admin_command` defaults to an empty allowlist: reads are on by default,
  actions are explicit opt-in. The allowlist is host policy delivered through
  `zdtd.query`; a buggy guest is a trusted-module failure mode, and the token
  is the actual trust boundary.

## 9. Lifecycle (ADR 0030)

- `_zdtd_requires` declares `on_mcp_frame` + used imports; load fails loudly on
  typos.
- `on_shutdown` runs on dispose/reload: guest closes sessions.
- Host side of reload: the transport keeps listening but the frame handler
  finds no plugin exporting `on_mcp_frame` and answers 503 until a module is
  (re)loaded; a disabled module's queued SimCommands are already withdrawn by
  slot attribution before drain.
- Re-enable re-arms the budget and re-runs `on_enable`; clients reconnect.

## 10. Test plan

1. **Guest protocol unit tests** (host-side harness loading the committed
   `mods/zdtd_mcp/zdtd_mcp.wasm` through `WasmHost`): initialize/ping/
   tools/list/tools/call golden responses; error table (-32700/-32600/-32601/
   -32602); batch rejection; allowlist prefix matching; queue attribution.
2. **Transport unit tests** (`src/server/mcp_transport.zig`): auth accept/
   reject, path/method gates, frame cap (413), transfer-encoding rejection,
   notification 202, loopback-only binding.
3. **Harness e2e** (`mcp_transport.zig` test, server side — the transport is
   top-of-stack and may load the plugin runtime): the real
   `mods/zdtd_mcp/zdtd_mcp.wasm` behind the transport's test-mode HTTP framing
   (same pattern as webui's testServeHttp — raw requests in, captured
   responses out, no kernel socket), driven through initialize ->
   notifications/initialized -> tools/list -> tools/call(server_status) ->
   tools/call(admin_command) with a sense/query Cap standing in for Game.
4. Gates: `zig build test` and `make check` stay green. No loadgen/stock
   client leg (no stock wire; MCP_PRD NFR-5, ADR 0031 D7).

## 11. Milestones

- **M1** - guest protocol core: session, error table, `ping`, `tools/list`;
  protocol unit tests green. **Done.**
- **M2** - host transport bridge + read tools (`server_status`,
  `player_list`) + `admin_command` allowlist wiring; transport unit tests +
  harness e2e green. **This milestone.**
- **M3** - docs final pass; PROVENANCE/index rows; `make check` green.

## 12. Doc updates shipped with the code

- `docs/PROVENANCE.md` file map: row for `src/server/mcp_transport.zig`
  (bucket Z: zdtd-owned; protocol from the public MCP spec, cited
  `modelcontextprotocol.io` + ADR 0031; `mods/zdtd_mcp/zdtd_mcp.c` is a plugin
  module, not `src/`, and follows the same Z provenance claim).
- `docs/INDEX.md`: rows for `MCP_PRD.md`, `MCP_DESIGN.md`, and
  `adr/0031-mcp-wasm-module.md` (already in the ADR table).
- `docs/PLUGIN_DEV.md`: document `on_mcp_frame` and the `mcp.allowlist`
  query key.
