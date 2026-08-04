# Server web UI design (HTMX + Alpine.js)

Operator-facing **ops dashboard** for zdtd. Not a stock Steam browser clone, not
a Unity GUI, not a mod host. Complements existing **admin TCP** and **apm**
dumps with a browser UI.

| | |
|---|---|
| Status | **Design only** (no code) |
| Stack | HTMX + Alpine.js + minimal CSS (no React/Vue build chain) |
| Server | Zig HTTP on a dedicated bind (loopback default) |
| Related | [APM.md](APM.md), [AUTHORITY.md](AUTHORITY.md), `src/server/admin.zig`, [PLUGIN_API.md](PLUGIN_API.md) |

## Goals

1. **See** live server health: tick budget, joins, peers, chunks, zombies, apm.
2. **Act** safely: same command surface as admin TCP (give, tele, kick, time, …).
3. **Configure** visibility: read-only serverconfig / effective options; write only
   where we already allow hot reload (or explicit restart-required flags).
4. **Stay out of the 50 ms tick:** all UI I/O off the sim hot path (or
   command-queue only).
5. **Secure by default:** loopback bind, shared secret or cookie session, no
   anonymous open internet admin.

## Non-goals

- Stock client replacement or in-game HUD.
- Full telnet parity day one (incremental command coverage).
- Real-time 3D map editor or RWG designer (link worldgen later if at all).
- Embedding a Node/npm SPA build into the dedi binary.
- Harmony / ModAPI / Steam browser protocol.

## Why HTMX + Alpine

| Choice | Rationale |
|---|---|
| **HTMX** | HTML over the wire; server renders fragments; progressive enhancement; fits Zig string templates or simple HTML writers |
| **Alpine.js** | Tiny client state (modals, tabs, poll toggles) without a bundler |
| **No SPA** | One binary serves static assets + HTML; no `node_modules` in CI |
| **CDN or embed** | Ship hashed vendor files under `web/static/` or comptime-embed small JS/CSS |

Zig Zen fit: one obvious way (HTTP + HTML partials), readable handlers, no
parallel JSON-RPC + REST + GraphQL stacks.

## Architecture

```text
  Browser
    |  GET /  (shell)
    |  GET /partials/*  (HTMX swaps)
    |  POST /api/cmd    (forms / hx-post)
    |  GET /api/apm.json  (optional Alpine poll)
    v
  zdtd  --webui-port 8080  (default 127.0.0.1 only)
    |
    +-- webui HTTP listener  (std.Io / std.http when suitable; not on tick)
    |     auth middleware
    |     router → handlers
    |     static files
    |
    +-- command queue  (mutex / channel)
    |     webui enqueues AdminCommand
    |     Game.step / admin pump dequeues  (same path as admin TCP)
    |
    +-- read snapshots
          apm harness copy
          client list, clock, world stats  (RCU or tick-end snapshot)
```

**Critical separation**

| Path | Allowed |
|---|---|
| HTTP thread / async accept | parse request, auth, build HTML, enqueue cmd |
| Tick (50 ms) | drain **bounded** cmd queue; update **snapshot** struct for readers |
| Never on tick | template render of large pages, disk walk, TLS handshake bulk |

Same rule as admin TCP: loopback-first; give/kick are privileged.

## Security model

| Control | Default |
|---|---|
| Bind | `127.0.0.1` only (`--webui-bind 0.0.0.0` explicit opt-in) |
| Auth | Shared secret header or login form → httpOnly session cookie (HMAC) |
| CSRF | SameSite cookie + POST token on mutating forms |
| TLS | Optional reverse proxy (Caddy/nginx); v1 plain HTTP on loopback only |
| Rate limit | Per-IP cmd rate (reuse join-style throttle ideas) |
| Audit log | Append-only ops log: who/when/cmd (file under world dir) |
| Read vs write | GET partials need auth; POST cmds need auth + CSRF |

**Do not** expose webui on public WAN without TLS + strong secret + firewall.
Document that loudly in README / GAME_OPTIONS.

## Information architecture (pages)

Shell: top nav + Alpine tabs or HTMX boosted links. Partial updates via
`hx-get` / `hx-target`.

| Route | Purpose | Data source |
|---|---|---|
| `GET /` | Dashboard shell | static + first partials |
| `GET /partials/status` | Day/time, BM, players, zombies, chunks, tick overrun | snapshot |
| `GET /partials/players` | Table: slot, name, entity, pos, ping proxy | clients[] |
| `GET /partials/apm` | Counters + section p50/p99 | apm harness |
| `GET /partials/world` | World name, seed/mode, stream caps (read-only) | Game opts |
| `GET /partials/console` | Command form + last N log lines | ops log ring |
| `POST /api/cmd` | Run one admin command | queue → admin parser |
| `GET /api/apm.json` | Machine-readable apm (loadgen/tools) | snapshot |
| `GET /login` / `POST /login` | Session | config secret |
| `GET /static/*` | htmx.min.js, alpine, app.css | embed or files |

Optional later:

| Route | Purpose |
|---|---|
| `/partials/bans` | ban list CRUD |
| `/partials/config` | effective serverconfig (restart badges) |
| `/healthz` | unauthenticated liveness (no secrets) for k8s |

## UI sketch (dashboard)

```text
+------------------------------------------------------------------+
| zdtd  ·  Navezgane  ·  day 7 22:14  ·  BM in 0d   [Logout]       |
+----------+-------------------------------------------------------+
| Status   |  Tick 48ms p99 · overruns 2 · joined 3/8 · peers 3    |
| Players  |  chunks 420 · zombies 12 · stream errs 0              |
| APM      |  [====tick====][net][sim][repl][stream]               |
| World    |                                                       |
| Console  |  Players                                              |
|          |  #  Name     Ent    X Y Z           | Kick | TP spawn |
|          |  0  Alice    107   120 72 -40       | ...  | ...      |
|          |                                                       |
|          |  Console                                              |
|          |  > give 0 meleeWpnClubT0WoodenClub 1                  |
|          |  ok                                                   |
+----------+-------------------------------------------------------+
```

Alpine: tab highlight, auto-refresh toggle (`hx-trigger="every 2s"` when on).
HTMX: swap player table and status cards without full reload.

## Command surface (v1)

Reuse **exactly** `admin.zig` / `Game` console verbs so TCP and web stay one path:

| Cmd | Web UI |
|---|---|
| `lp` / listplayers | Players table (auto) |
| `kick <slot>` | Row button |
| `give <slot> <item> <n>` | Form (name resolve via items table) |
| `tp` / tele | Form or "TP to spawn" |
| `settime` | Day/night buttons + custom |
| `say` | Broadcast form |
| `killall` / spawnentity | Confirm modal (Alpine) |
| `save` / `shutdown` | Confirm + danger class |
| `help` | Collapsible cheatsheet |

Unknown cmds: show parser error in console partial (same strings as TCP).

**Item picker:** typeahead from loaded item **names** (not bare ids) when
game-dir catalogs present; fail closed if unknown name.

## Data snapshot (tick-safe read model)

At end of `Game.step` (or every N ticks), copy into a `WebSnapshot` behind a
mutex or double-buffer:

```text
WebSnapshot {
  tick_n, day, hours, bloodmoon_day
  joined, entered, peers_alive, max_players
  zombies, animals, chunk_count
  tick_overruns, encode_errors, stream_errors, ...
  apm_counters[…]
  apm_sections p50/p99 (pre-summarized)
  players: [{ slot, name, entity_id, x, y, z, entered }]
  world_name, terrain_source, seed_opt
  version strings
}
```

HTTP handlers **only read** the snapshot (clone under lock, then render). No
walking live `clients` from the HTTP thread without the snapshot protocol.

Command queue:

```text
WebCmd { id, session, raw_line, enqueued_ns }
// capacity e.g. 32; drop + 429 if full
```

Drain ≤ K cmds per tick (e.g. 4) so one operator cannot stall sim.

## Implementation plan (phased)

### WU0 — Skeleton (1–2 PRs)

- [x] `src/server/webui.zig` (minimal HTTP/1.1, non-blocking poll from Game.step)
- [x] CLI: `--webui-port 0` (off), `--webui-bind 127.0.0.1`, `--webui-secret`
- [x] GAME_OPTIONS + INDEX; design in this file
- [x] HTTP: `GET /healthz` (no auth), `GET /` (Bearer / X-Zdtd-Secret / `?token=`)
- [x] Disabled by default (port 0); secret required when enabled

**Exit:** curl with secret shows hello; without → 401; off → nothing listens; `make check` green.

```bash
zig-out/bin/zdtd --port 27002 --world worlds/zdtd_default \
  --webui-port 8080 --webui-secret change-me --once
curl -sS -H 'Authorization: Bearer change-me' http://127.0.0.1:8080/
curl -sS http://127.0.0.1:8080/healthz
```

### WU1 — Read-only dashboard

- [ ] Tick-end `WebSnapshot` fill
- [ ] Partials: status, players, apm (HTML)
- [ ] HTMX auto-refresh 2s (toggle)
- [ ] `GET /api/apm.json` for scripts
- [ ] APM counters already include tick_overruns / encode_errors

**Exit:** operator watches live join/tick without TCP client.

### WU2 — Commands

- [ ] Shared command parse path (admin TCP + web POST)
- [ ] `POST /api/cmd` → queue → drain on tick
- [ ] Console partial with response lines
- [ ] CSRF + session cookie
- [ ] Ops audit log file

**Exit:** give/kick/settime from browser matches admin TCP semantics.

### WU3 — UX polish

- [ ] Alpine modals for destructive cmds
- [ ] Player row actions
- [ ] Item name typeahead (from ItemTable)
- [ ] Basic CSS (readable dark theme, no framework lock-in)
- [ ] Embed vendor JS (htmx, alpine) for offline ops

### WU4 — Optional depth (park until asked)

- [ ] Ban list UI
- [ ] Config viewer (effective knobs, restart-required tags)
- [ ] Chunk/interest heat numbers from apm
- [ ] Reverse-proxy TLS notes + example Caddyfile
- [ ] SSE/EventSource stream instead of poll (still snapshot-based)
- [ ] Read-only public status page (separate secret or none; no cmds)

## Zig module layout (proposed)

```text
src/server/webui.zig          # listener, router, auth
src/server/webui_snap.zig     # WebSnapshot + cmd queue
src/server/webui_html.zig     # HTML fragments (or templates/)
web/static/htmx.min.js
web/static/alpine.min.js
web/static/app.css
web/templates/shell.html      # optional file templates via io_fs at init
```

Facades: `server/root.zig` exports webui init. **No** import of webui from
`wire/` or `ecs/` (only `game.zig` fills snapshot + drains cmds).

HTTP stack preference (in order):

1. Zig 0.16 `std.http` / `std.Io` if adequate for small static + simple POST
2. Thin internal server (accept + parse HTTP/1.1 subset) if std is awkward
3. **Not** a second raw linux socket style copied from LiteNet unless forced;
   prefer std abstractions (AGENTS rule 24)

## Config / CLI

| Key | Default | Notes |
|---|---|---|
| `--webui-port` | `0` (disabled) | e.g. `8080` |
| `--webui-bind` | `127.0.0.1` | WAN requires explicit bind + secret |
| `--webui-secret` | empty → refuse start if port≠0 | or env `ZDTD_WEBUI_SECRET` |
| serverconfig (optional later) | `WebUiPort`, `WebUiBind` | document in GAME_OPTIONS |

Precedence: CLI > env > serverconfig > defaults.

## Testing

| Layer | What |
|---|---|
| Unit | cmd queue bounds; snapshot copy; HTML escape; auth HMAC |
| Unit | parse same strings as admin.zig |
| Integration | start Game with webui port on 127.0.0.1; HTTP GET status; POST give |
| Manual | browser checklist in docs |
| Load | webui poll must not move tick_overruns under loadgen |

**Escape all user-controlled strings** in HTML (names, cmd echo) to prevent XSS
against the operator session.

## Relationship to existing surfaces

| Surface | Role vs webui |
|---|---|
| Admin TCP | Keep; webui shares command backend |
| In-game console packages | Unchanged; webui is out-of-band |
| apm text/JSON dump | webui displays live; dumps remain for CI |
| 7dtd-apm | Never integrate |
| Playtest orchestrator | May use `/api/apm.json` or keep TCP |

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Tick stalls from HTTP | Snapshot + cmd queue; time-box drain |
| Auth bypass | Default off; refuse listen without secret; loopback default |
| XSS via player names | HTML escape; CSP headers basic |
| Scope creep to full CMS | Phases WU0–2 only until STATUS asks |
| Dual command parsers | One `parseCommand` used by TCP and web |
| Large HTML on hot path | Pre-render not required; build strings on HTTP thread only |

## Success criteria (product)

- [ ] Disabled by default; zero impact on `make check` and join path when off
- [ ] With port+secret on loopback: see players/apm; run give/kick/settime
- [ ] Under loadgen, webui poll does not cause systematic tick_overruns
- [ ] Docs: WEBUI.md, GAME_OPTIONS, README snippet, SECURITY notes
- [ ] No em dashes / AI attribution in implementation commits

## Open decisions (resolve at WU0)

1. **std.http vs minimal parser** — spike in WU0.
2. **Embed vs disk static** — prefer embed for single-binary ops; disk override
   path for CSS tweaks optional.
3. **Session store** — signed cookie only (stateless) vs server-side session map
   (cap 16 sessions).
4. **Command identity** — log “webui” vs TCP peer address for audit.

## Suggested first issue breakdown

1. ADR or STATUS line: "Web UI design accepted; implementation parked at WU0"
2. WU0 PR: flag + bind + hello world + auth stub
3. WU1 PR: snapshot + status/players/apm partials
4. WU2 PR: cmd queue + console + CSRF
5. WU3 PR: polish + embed assets

---

## Appendix: example HTMX fragments (illustrative)

```html
<!-- shell -->
<div id="status" hx-get="/partials/status" hx-trigger="every 2s" hx-swap="innerHTML"></div>
<div id="players" hx-get="/partials/players" hx-trigger="every 2s"></div>

<form hx-post="/api/cmd" hx-target="#console-out" hx-swap="innerHTML">
  <input type="hidden" name="csrf" value="...">
  <input name="line" placeholder="give 0 resourceWood 10" autocomplete="off">
  <button type="submit">Run</button>
</form>
<div id="console-out"></div>
```

Server returns HTML snippets only (no JSON required for v1 UI except `/api/apm.json`).
