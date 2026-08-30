# ADR 0031: MCP server as a Wasm module: guest protocol, host transport

- **Status:** accepted
- **Date:** 2026-08-22
- **Related:** [ADR 0020](0020-wasm-only-plugin-api.md) (Wasm is the only plugin
  format), [ADR 0030](0030-plugin-spatiotemporal-composability.md) (plugin
  lifecycle, effect withdrawal, declarative `_zdtd_requires`), [ADR 0004](0004-server-authoritative-c2s.md)
  (server is authoritative), [ADR 0026](0026-fps-bot-wasm-module.md) (guest
  owns decisions, host owns the body), [ADR 0014](0014-missing-beats-fake.md)
  (missing beats fake), [ADR 0019](0019-validation-triad.md) (validation
  triad). Product context: [PRD 0002](../prd/0002-mcp-server.md).

## Context

Operators want a standard doorway for AI assistants and external tooling to
query and command the server. The Model Context Protocol (MCP, open spec,
JSON-RPC 2.0 based) is that standard: a client negotiates a session
(`initialize`), discovers capabilities, lists tools, and calls them. The
alternative today is parsing the admin console or the WebUI, both bespoke.

The plugin boundary already carries what an MCP server needs on the zdtd side:
`zdtd.sense` / `zdtd.query` are read-only, host-validated views of the sim, and
`zdtd.queue` lands commands that the ECS drains with full authority (ADR 0004).
What the boundary does **not** have is a transport: no guest import touches a
socket (PLUGIN_DEV.md "Host imports", PLUGIN_API.md "The boundary"), and that
is deliberate. So "MCP server as a Wasm module" is only expressible if the host
adds a transport bridge. This ADR fixes exactly how much host surface that
takes, so the authority model, the 20 TPS budget, and the composability rules
of ADR 0030 stay intact.

## Decision

### D1. Guest owns protocol; host owns transport and JSON parsing

The guest module (`mods/mcp`) owns everything that is MCP semantics:
JSON-RPC 2.0 framing and validation over the parsed view, session state
(`initialize`, `notifications/initialized`), capabilities, the tool registry
(name / description / JSON-Schema input), `ping`, `tools/list`, `tools/call`,
and the spec error table (parse -32700, invalid request -32600, method not
found -32601, invalid params -32602, internal error -32603).

The host owns everything that is bytes on a wire or a parser: the listener,
HTTP/SSE framing, per-session queues, auth, the bounded copy of frames into and
out of guest memory, **and the JSON parsing itself** - the host parses each
frame with Zig's `std.json` and exposes the parsed document to the guest
through the `zdtd.json_*` imports (D3). The guest never parses JSON, never sees
a socket, never parses HTTP, and never touches the game wire. This is the same
guest/host split ADR 0026 made for bots: the guest is the brain, the host is
the body - plus the parser, because hand-rolling JSON in a freestanding guest
is exactly the kind of correctness risk the boundary exists to absorb.

### D2. Transport: MCP Streamable HTTP on a dedicated listener

The transport is MCP **Streamable HTTP** (spec version pinned in
[RFC 0002](../rfc/0002-mcp-server-design.md); baseline 2025-06-18): client to server is JSON-RPC over HTTP
POST; server to client messages would go over SSE when the client requests
it, but the MVP has no server-initiated messages, so every POST is answered
with `application/json` (the spec permits this when the server has nothing to
push). The host implements it with the existing stack: `util/tcp_listen`
(`std.Io.net`) + `std.http.Server`, the same pair the operator WebUI uses
(`src/server/webui.zig`).

The listener is **dedicated**, not bolted onto the WebUI port: MCP is an
external tooling interface, the WebUI is an operator dashboard, and their auth,
rate, and config lives differ. Defaults: **disabled or bind-localhost** (no
new trust boundary by default), optional shared token reusing the existing
admin/webui credential path; exact keys in the design doc.

Rejected alternatives:

- **stdio transport** - the server's stdin is the admin console surface
  (`src/server/admin_console.zig`); hijacking it breaks console workflows.
- **Raw TCP** - MCP has no raw-TCP transport; a nonstandard wire would defeat
  the "standard doorway" goal.
- **WebUI `/mcp` endpoint** - couples tooling traffic to the dashboard port and
  its session model; rejected on config/ops separation, not on feasibility.

### D3. New affordance: one guest export and four std.json imports

The boundary grows by one guest export, following the existing `on_chat`
idiom (host fills guest memory, guest writes an answer):

- Export: `on_mcp_frame(frame_ptr: i32, frame_len: i32, out_ptr: i32, out_cap: i32) -> i32`
  - the host copies the next pending client frame into guest memory at
    `frame_ptr` (bounded by a named const), the guest parses it and writes its
    response (a JSON-RPC result/error, or a notification) to `out_ptr`;
    returns response bytes (0 = nothing to send).
  - a malformed response from the guest (bad length, OOB) is dropped, never
    forwarded; a guest that traps on the frame disables only itself
    (ADR 0020).

And four imports that expose Zig's `std.json` to the sandbox, all in the
`zdtd` module namespace (capability-gated like `sense`/`query`):

| Import | Signature | Notes |
|---|---|---|
| `json_parse` | `(ptr: i32, len: i32) -> i32` | Parse the JSON doc at guest memory (ptr, len) with std.json into a per-plugin fixed buffer; 0 = ok, <0 = parse error (invalid JSON, or the fixed buffer cap exhausted, which also bounds nesting) |
| `json_str` | `(path_ptr, path_len, out_ptr, out_cap) -> i32` | Decoded string at a dot-separated key path; returns the FULL length, 0 = missing/not a string, <0 = error. The guest compares the length against its buffer cap |
| `json_raw` | `(path_ptr, path_len, out_ptr, out_cap) -> i32` | Raw JSON of the value at a path (used to echo the JSON-RPC `id` verbatim); full length, 0 = missing, <0 = error |
| `json_obj` | `(path_ptr, path_len) -> i32` | 1 = value at path is an object, 0 = absent/other, <0 = error |

The parsed document is per-plugin state, one frame at a time (frames are
processed one at a time on the tick), stored in a lazily allocated fixed
buffer (`json_buf_max`, 64 KiB) reset per frame, so the tick path never
touches the heap and a pathological document fails closed instead of growing
(ADR rule 20). The capability is generic: any plugin may parse JSON this way,
and the guest never needs a JSON parser.

The rest of the boundary is unchanged: reads already exist (`sense`,
`query`), actions already exist (`queue`), clock already exists (`tick`).
The transport bridge remains the only new socket-facing host surface, and it
is a bounded frame queue plus the copy outlined above, not a new authority.

Per ADR 0030, the module declares `_zdtd_requires` with `on_mcp_frame` and the
imports it uses; a typo'd hook or verb fails load loudly instead of silently
never-firing.

### D4. Tool surface: reads from sense/query, actions through existing authority

- **Read tools** (`server_status`, `player_list`) fill from bounded
  `sense`/`query` snapshots. Results are server-authoritative; the guest never
  invents state (ADR 0004).
- **Action tool** (`admin_command`) executes only through paths the host
  already validates: either `zdtd.queue` SimCommands drained by the ECS, or
  the admin console `runAdminLine` runner. Which one per verb is a design
  detail; the authority is not. Every action is attributed to the module slot
  so a disabled module's pending effects are withdrawn (ADR 0030).
- Actions are gated by a **config allowlist, default empty**. Reads are safe by
  default; actions are explicit opt-in.

### D5. Fail closed

Malformed client frames produce the spec JSON-RPC error, never a crash. Frames
over the size cap are dropped at the named const. A tool call the guest cannot
encode (unknown tool, bad args, result over buffer cap) returns the spec error
or an omitted result, never a truncated frame that desyncs the client
(ADR 0014, "missing beats fake"; AGENTS rule 24).

### D6. Lifecycle under ADR 0030

Reload/dispose runs `on_shutdown`, drops the MCP sessions and any frames still
queued in the transport, and reclaims fuel/memory. A disabled module's queued
commands are withdrawn before drain (already guaranteed by slot attribution).
An MCP session does not survive a reload; clients reconnect, which is normal
for MCP.

### D7. Validation

- Unit tests for the guest-facing protocol core: framing, session, error
  table, tool registry, `tools/call` argument validation.
- A harness end-to-end test: the real guest `.wasm` behind the transport's
  HTTP framing (same test-mode capture as webui - raw requests in, responses
  out), driving `initialize` / `notifications/initialized` / `tools/list` /
  `tools/call` including an allowlisted `admin_command`.
- `zig build test` and `make check` stay green. No loadgen/stock-client leg:
  this addon never touches stock wire or the client (ADR 0019 applies to wire
  changes; this is an internal-boundary addon, per PRD 0002 NFR-5).

## Consequences

Positive:

- One standard, client-agnostic doorway into the server, delivered as a
  drop-in `.wasm` addon per ADR 0020/0030.
- The authority model is untouched: the guest can only read what `sense`/
  `query` show and request what the host already validates.
- The host surface is minimal and auditable: a listener, bounded frame queues,
  one hook invocation plus the std.json imports. No wire changes, nothing on
  the tick path beyond one hook call per pending frame.
- Clean-room is trivially satisfied: MCP is a public spec, the module is
  zdtd-owned (provenance bucket Z).

Negative:

- The transport (listener + HTTP/SSE + session queues) is permanent host
  surface once shipped; it is kept minimal and versioned.
- The std.json capability adds four permanent imports and per-plugin parse
  state (a lazily allocated fixed buffer); both are generic and audited, and
  the buffer is bounded and fail-closed (D3).
- MCP sessions are host-side state and do not survive module reload; accepted
  as normal MCP behavior.

Not decided here: exact config keys, buffer sizes, the JSON path schema, and
the per-verb action mapping - these are design-doc details
([RFC 0002](../rfc/0002-mcp-server-design.md)).
