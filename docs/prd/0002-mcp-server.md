# MCP Server Addon - Product Requirements (PRD)

> **Purpose:** product requirements for the MCP server addon - what the MCP bridge must do and how it is validated.

**Number:** PRD 0002
**Status:** shipped (module + transport live: `mods/mcp/`,
`src/server/mcp_transport.zig`; design recorded in [ADR 0031](../adr/0031-mcp-wasm-module.md)
and [RFC 0002](../rfc/0002-mcp-server-design.md)).
**Owner:** server operators / dev tooling (the addon is not a stock feature).
**Ships as:** an **official mod** (PRD 0005 tier model: shipped in-tree under
`mods/mcp/`, auto-discovered via `manifest.toml`, disable-able via
`[mods] disabled`, overridable by user mods via `override = "mcp"`). The
module is Wasm (ADR 0020 / ADR 0030) + a minimal host transport bridge.
**Protocol reference:** Model Context Protocol (open spec,
`modelcontextprotocol.io`), JSON-RPC 2.0 based; spec version pinned in
ADR 0031.
**Related:** [RFC 0002](../rfc/0002-mcp-server-design.md) (design) · [ADR 0031](../adr/0031-mcp-wasm-module.md) (decision) · [PLUGIN_API.md](../PLUGIN_API.md) · [PLUGIN_DEV.md](../PLUGIN_DEV.md)

---

## 1. Background and problem

zdtd is a headless clean-room dedicated server. Everything it knows is inside
the process: world state, connected players, ticks, admin surface. Today the
only ways to reach that state are the admin console (TCP), the operator WebUI,
and the plugin boundary itself. Each of those is bespoke.

The Model Context Protocol is the emerging standard for giving AI assistants
and external tooling a uniform way to query and command a service: a client
discovers capabilities, lists tools, and calls them over JSON-RPC 2.0. An
operator who runs an AI assistant, a bot, or a homegrown control script wants
one standard doorway into the server instead of re-parsing console output.

The plugin boundary (ADR 0020) already has the verbs an MCP server would need:
`zdtd.sense` / `zdtd.query` for reads, `zdtd.queue` for actions, all host
validated and server-authoritative. What is missing is a **transport** a client
can connect to. So this addon implements the MCP server as a Wasm plugin, with
the protocol logic in the guest, the transport bridged by the host, and JSON
parsing done host-side with std.json (exposed as `json_*` imports, ADR 0031
D3). This keeps ADR 0020 intact: the guest never touches the wire, never
invents state, never parses JSON, and every action it requests goes through
the same authority rules as a console command.

## 2. Personas

- **Operator** - runs a zdtd server, wants to hand an AI assistant or control
  script a standard MCP interface to monitor the server and issue bounded admin
  actions, with auth and allowlists intact.
- **AI assistant / MCP client** - Claude, claude code, or any spec-compliant
  client; cares only that the server speaks MCP correctly.
- **Developer/QA** - scripts an MCP client for smoke checks and dashboards;
  wants deterministic, bounded behavior and spec error responses, not crashes.
- **Player** - unaffected; vanilla client, no client mod, no new wire traffic.

## 3. Goals

1. MCP server as a drop-in addon (one `.wasm` in `[plugin] modules`), no host
   fork, no client mod.
2. Protocol logic lives in the **guest** (session lifecycle, tool registry,
   spec error responses over a parsed view); the host provides the transport
   bridge **and the JSON parsing** (Zig std.json exposed as `json_*` imports,
   ADR 0031 D3) - the guest never parses JSON itself.
3. Tools map 1:1 onto the existing plugin boundary: reads via `sense`/`query`,
   actions via `queue` verbs with a config allowlist. No new authority model.
4. Fail closed: malformed frames get spec JSON-RPC errors, unknown tools error,
   privileged actions stay host-validated and module-attributed (ADR 0030).
5. Bounded and deterministic: off the tick path, no hot-path heap, fuel
   budgeted and reloadable like every other module (ADR 0020 / 0030).

## 4. Scope

### In scope (MVP)

- Documentation: this PRD, ADR 0031 (guest/host boundary, transport choice,
  tool surface), design plan ([RFC 0002](../rfc/0002-mcp-server-design.md)).
- A `.wasm` MCP guest module: `initialize` handshake with pinned spec version +
  capabilities, `ping`, `tools/list`, `tools/call`; JSON-RPC 2.0 error
  responses (parse, invalid request, method not found, invalid params,
  internal); bounded frame and result buffers; no libc, freestanding wasm32
  (mirrors `mods/fps_bot/`).
- A minimal host transport bridge (candidates: streamable-HTTP endpoint on the
  existing WebUI HTTP server, or a dedicated TCP port; the ADR decides, and it
  is reviewed against ADR 0030 composability).
- Initial tool set: read tools `server_status` and `player_list`; action tool
  `admin_command` executing only allowlisted `queue` verbs (allowlist default
  empty, so actions are opt-in).
- Unit tests for the JSON-RPC/MCP logic + an end-to-end harness test running a
  real MCP client against the bridged transport.
- PROVENANCE/index rows for the new files.

### Out of scope (later, only with demand)

- stdio transport (the server's stdin is the console/admin surface).
- Server-to-client streaming (SSE push), MCP sampling.
- Resources and prompts beyond what the tools already expose.
- Authentication beyond existing server auth (WebUI/admin creds, bind
  localhost by default).
- Multi-session / multi-client management, or third-party MCP SDKs in the
  guest.

## 5. User stories

- As an **operator**, I add `mods/mcp/mcp.wasm` to `[plugin] modules`; an MCP
  client connects, lists `server_status` and `player_list`, and reads them.
- As an **operator**, I grant `admin_command` an allowlist; a tool call for an
  allowed verb (e.g. `bot count 6`) executes through the host exactly like the
  console command, and an unlisted verb is rejected.
- As an **AI assistant**, I get spec-compliant JSON-RPC: capabilities on
  `initialize`, clean `ping`, JSON-Schema tool definitions, and standard error
  objects when I send a malformed frame.
- As a **developer**, I run the harness client; malformed JSON returns
  `-32700`, an unknown method returns `-32601`, and a module that burns fuel is
  disabled alone, never taking the server down.
- As a **QA engineer**, I verify that a disabled/reloaded module withdraws its
  queued effects and drops the session (ADR 0030), and that the tick budget is
  untouched by MCP traffic.

## 6. Functional requirements

- **FR-1 (session):** `initialize` negotiates a pinned spec version and
  advertises capabilities; `initialized` notification is accepted; unknown
  methods and notifications error or no-op per the spec.
- **FR-2 (methods):** `ping`, `tools/list`, `tools/call` in both request and
  notification forms where the spec allows.
- **FR-3 (framing):** JSON-RPC 2.0 frames are parsed by the host std.json
  capability (`json_*` imports, ADR 0031 D3) and validated in the guest; error
  responses for parse (-32700), invalid request (-32600), method not found
  (-32601), invalid params (-32602), internal error (-32603); fail closed on
  encode (ADR rule 24).
- **FR-4 (tool registry):** bounded table of name / description / JSON-Schema
  input; `tools/call` validates arguments before any side effect.
- **FR-5 (reads):** read tools fill from bounded `sense`/`query` snapshots;
  results are server-authoritative, never guest-invented (ADR 0004).
- **FR-6 (actions):** `admin_command` maps to `queue` verbs gated by a config
  allowlist; every queued command is attributed to the module slot so a
  disabled module's pending effects are withdrawn (ADR 0030).
- **FR-7 (transport):** the host bridge delivers frames in / responses out over
  the chosen transport with bounded queues; backpressure or drop at a named
  cap, never a tick stall.
- **FR-8 (lifecycle):** `on_enable`/`on_shutdown` clean, reload support,
  fuel budget, `_zdtd_requires` declarations validated at load (ADR 0030).

## 7. Non-functional requirements

- **NFR-1 (performance):** MCP traffic runs off the tick path; frame and result
  buffers are capped at named consts; no hot-path heap in host or guest; a
  guest that exhausts fuel is disabled, not fatal (ADR 0020).
- **NFR-2 (correctness):** spec version pinned in ADR 0031; golden JSON-RPC
  layout tests for framing and errors; fail closed on any malformed input.
- **NFR-3 (clean-room):** MCP is a public open spec (not TFP); the module is
  zdtd-owned (provenance bucket Z) with no stock code involved.
- **NFR-4 (isolation):** a broken MCP module disables only itself; the server
  and other plugins are unaffected (ADR 0020).
- **NFR-5 (validation):** unit tests + the harness e2e replace the loadgen leg
  here, because this addon never touches stock wire (ADR 0019 applies to wire
  changes; this is an internal boundary addon). `make check` must stay green.
- **NFR-6 (security):** the transport defaults to bind-localhost and reuses
  existing server auth; action tools are allowlisted off by default; no new
  trust boundary.

## 8. Acceptance criteria (product)

- AC-1. With the module enabled, a spec-compliant MCP client completes
  `initialize` and lists the declared tools.
- AC-2. `ping` and the read tools return correct results; `player_list` reflects
  the actual connected players.
- AC-3. Malformed frames return spec JSON-RPC errors and never crash the server
  or the module.
- AC-4. Allowlisted action verbs execute through the host and are visible as
  normal commands; unlisted verbs are rejected with a clear error.
- AC-5. Reload/disable drops the session cleanly and withdraws pending effects
  (ADR 0030); no queued commands fire after disable.
- AC-6. `make check` is green, including the new unit and harness tests.

## 9. Risks and mitigations

- **The transport is new host surface:** keep it minimal, decide it in the ADR,
  review against ADR 0030 composability, and cover it with the harness test.
- **JSON parsing in freestanding wasm32 without libc:** a small bounded parser
  with frame caps; no unbounded growth; golden tests pin the layout.
- **Wasm heap limits:** cap frames and tool results at named consts; large
  results are truncated/omitted fail-closed rather than OOM (ADR rule 24).
- **Exposing server control to AI tooling:** default bind-localhost, reuse
  existing auth, action allowlist empty by default; reads first, actions opt-in.

## 10. Milestones (see [RFC 0002](../rfc/0002-mcp-server-design.md))

- **M0** - docs: this PRD, ADR 0031, design plan.
- **M1** - guest protocol core: framing + session + `ping` + `tools/list` +
  error table, with unit tests.
- **M2** - host transport bridge + read tools (`server_status`, `player_list`).
- **M3** - `admin_command` allowlist + harness e2e + `make check` green + docs
  final pass.

## 11. Out-of-scope signpost

stdio transport, SSE push, MCP sampling, resources/prompts beyond the tool
surface, multi-session management, third-party MCP SDKs in the guest -
deliberately deferred; revisit only with real demand, not speculative scope.
