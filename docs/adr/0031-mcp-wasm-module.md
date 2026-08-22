# 0031. MCP server as a Wasm module: guest protocol, host transport

- **Status:** accepted
- **Date:** 2026-08-22
- **Related:** [ADR 0020](0020-wasm-only-plugin-api.md) (Wasm is the only plugin
  format), [ADR 0030](0030-plugin-spatiotemporal-composability.md) (plugin
  lifecycle, effect withdrawal, declarative `_zdtd_requires`), [ADR 0004](0004-server-authoritative-c2s.md)
  (server is authoritative), [ADR 0026](0026-fps-bot-wasm-module.md) (guest
  owns decisions, host owns the body), [ADR 0014](0014-missing-beats-fake.md)
  (missing beats fake), [ADR 0019](0019-validation-triad.md) (validation
  triad). Product context: [MCP_PRD.md](../MCP_PRD.md).

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

## Decisions

### D1. Guest owns protocol; host owns transport

The guest module (`mods/zdtd_mcp`) owns everything that is MCP semantics:
JSON-RPC 2.0 framing and validation, session state (`initialize`,
`initialized`), capabilities, the tool registry (name / description /
JSON-Schema input), `ping`, `tools/list`, `tools/call`, and the spec error
table (parse -32700, invalid request -32600, method not found -32601, invalid
params -32602, internal error -32603).

The host owns everything that is bytes on a wire: the listener, HTTP/SSE
framing, per-session queues, auth, and the bounded copy of frames into and out
of guest memory. The guest never sees a socket, never parses HTTP, and never
touches the game wire. This is the same guest/host split ADR 0026 made for
bots: the guest is the brain, the host is the body.

### D2. Transport: MCP Streamable HTTP on a dedicated listener

The transport is MCP **Streamable HTTP** (spec version pinned in
`MCP_DESIGN.md`; baseline 2025-06-18): client to server is JSON-RPC over HTTP
POST, server to client messages (notifications) over SSE when the client
requests it. The host implements it with the existing stack: `util/tcp_listen`
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

### D3. New affordance: one guest export, `on_mcp_frame`

The boundary grows by exactly one guest export, following the existing
`on_chat` idiom (host fills guest memory, guest writes an answer):

- Export: `on_mcp_frame(frame_ptr: i32, frame_len: i32, out_ptr: i32, out_cap: i32) -> i32`
  - the host copies the next pending client frame into guest memory at
    `frame_ptr` (bounded by a named const), the guest parses it and writes its
    response (a JSON-RPC result/error, or a notification) to `out_ptr`;
    returns response bytes (0 = nothing to send).
  - a malformed response from the guest (bad length, OOB) is dropped, never
    forwarded; a guest that traps on the frame disables only itself
    (ADR 0020).

No new imports are needed: reads already exist (`sense`, `query`), actions
already exist (`queue`), and clock/tick already exists. The transport bridge is
the only new host surface, and it is a bounded frame queue plus the copy
outlined above, not a new authority.

Per ADR 0030, the module declares `_zdtd_requires` with `on_mcp_frame` (plus
the imports it uses); a typo'd hook fails load loudly instead of never firing.

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
- A harness end-to-end test: a real MCP client (in-process test) speaks
  Streamable HTTP to the listener and drives `initialize` / `ping` /
  `tools/list` / `tools/call`.
- `zig build test` and `make check` stay green. No loadgen/stock-client leg:
  this addon never touches stock wire or the client (ADR 0019 applies to wire
  changes; this is an internal-boundary addon, per MCP_PRD.md NFR-5).

## Consequences

Positive:

- One standard, client-agnostic doorway into the server, delivered as a
  drop-in `.wasm` addon per ADR 0020/0030.
- The authority model is untouched: the guest can only read what `sense`/
  `query` show and request what the host already validates.
- The host surface is minimal and auditable: a listener, bounded frame queues,
  one hook invocation. No new imports, no wire changes, nothing on the tick
  path beyond one hook call per pending frame.
- Clean-room is trivially satisfied: MCP is a public spec, the module is
  zdtd-owned (provenance bucket Z).

Negative:

- The transport (listener + HTTP/SSE + session queues) is permanent host
  surface once shipped; it is kept minimal and versioned.
- The guest must parse JSON in freestanding wasm32 with no libc; mitigated by
  a small bounded parser, frame caps, and golden tests (design doc M1).
- MCP sessions are host-side state and do not survive module reload; accepted
  as normal MCP behavior.

Not decided here: exact config keys, buffer sizes, the JSON parser layout, and
the per-verb action mapping - these are design-doc details
(`docs/MCP_DESIGN.md`).
