# Server Hot Restart - Product Requirements (PRD)

> **Purpose:** hot-restart continuity contract — what must survive a full process restart, inventoried in one place.

**Number:** PRD 0004
**Status:** shipped (v1). One new requirement (R1, webui operator-session continuity,
shipped 2026-08-23); everything else in section 5 is an inventory of
persistence that already ships, collected here so "what survives a restart"
has a single checklist instead of scattered STATUS rows and WORK_PLAN tasks.

| | |
|---|---|
| Owner | operator tooling (webui, admin TCP) + `world/*` save paths |
| Related | [WEBUI.md](../WEBUI.md) (security model), [CLIENT_PLAYTEST.md](../CLIENT_PLAYTEST.md) (persist suite), `src/server/persist.zig`, [WORK_PLAN.md](../WORK_PLAN.md) T37, [ADRs](../adr/) |
| Gate | loadgen join + `7dtd-playtest` `persist` suite + stock client rejoin |
| Also see | [STATE_MACHINES.md](../STATE_MACHINES.md) (persistence), [GAME_OPTIONS.md](../GAME_OPTIONS.md) (config), [PLUGIN_API.md](../PLUGIN_API.md) (plugin reload) |

## 1. Background and problem

zdtd is a single-process dedicated server. A restart (operator `shutdown`,
crash, host reboot, or a deploy) drops every connection and rebuilds the
world from persistent state. Before restarting, an operator must be able to
answer "what comes back?" and "what do I have to redo?". That answer was
spread across STATUS rows, WORK_PLAN tasks, and TODO entries; this PRD
collects the contract into one place and adds the one piece that was missing:
the operator's webui session should survive the restart too.

"Hot" here means the continuity contract of a full stop + start, not
zero-downtime: the process restarts, connections re-establish, and
server-owned state comes back from disk.

## 2. Personas

- **Operator** (primary): runs the dedi headless, drives it from the webui
  dashboard and admin TCP. Wants a restart to be boring: world, players,
  trader/quest progress, and their dashboard login all survive.
- **Playtest harness** (secondary): `7dtd-playtest` `persist` suite and
  loadgen drive restart scenarios automatically and must stay green.

## 3. Goals

1. Define the hot-restart contract: what must survive a full process restart.
2. Inventory the shipped persistence formats so restart behavior is auditable
   from one document.
3. Make the operator's webui session survive a restart without a re-login
   (R1, shipped).

## 4. Scope

### In scope (MVP)

- Full stop + start of the same binary, world dir, and config (the
  `restart_pair.sh` / playtest `persist` suite shape).
- Server-owned state: world, players, claims, clock, weather, workstations,
  cleared sleepers, trader stock, config, webui operator session.
- Client rejoin: stock client (EAC off) and bots reconnect after restart.

### Out of scope (explicitly)

- Rolling / zero-downtime multi-process failover (no second zdtd process).
- Live migration of in-flight net state: packets, interest caches, per-peer
  reliable windows all reset; peers reconnect.
- Plugin runtime state: Wasm modules reload at start and their fuel/memory
  budgets re-arm (ADR 0030); plugin state is not persisted.
- apm history: counters and histograms are per-process by design
  ([APM.md](../APM.md)).
- Admin TCP sessions: telnet is a fresh connection per attach.

## 5. Persistence inventory (what survives today)

Every row below already round-trips through a restart and is covered by a
save/load test or scenario. Format IDs are the magic in the store files.

| State | Store | Format | Reference |
|---|---|---|---|
| Player records (inventory, XP, quests, journal, bedroll, last logout) | `players.zsv` | ZPV10 (reads ZPV2+) | `src/server/persist.zig` |
| Persistent entities | `entities.zen` | ZENT1 | `src/server/persist.zig` |
| Land claims | `claims.zlc` | ZCLC | `src/server/persist.zig` |
| World clock + blood-moon schedule | `clock.zcl` | ZCL2 | `src/server/game/clock_persist.zig` |
| Weather state | `weather.zwt` | ZWTH1 | `src/server/persist.zig` |
| Workstation fuel/input/output + smelting queue (craft-complete, melt) | `workstations.zws` | ZWS1 | TODO "Workstation persistence" |
| Cleared sleeper volumes (cleared POI stays clear) | `sleepers_cleared.zsc` | ZSCL1 | `src/world/sleepers.zig` |
| Chunk terrain + blockmeta | `*.zch` | ZCH3 | `src/world/` |
| Trader stock | `traders.zst` | ZTR1 | `src/server/persist.zig` |
| Operator config | zdtd.toml / serverconfig + modlet patches | - | [GAME_OPTIONS.md](../GAME_OPTIONS.md), [PRD 0003](../prd/0003-modlets.md) |
| Webui operator session | derived, no file | HMAC(secret, fixed label) | R1 below, [WEBUI.md](../WEBUI.md) |

## 6. Requirements

### R1. Webui operator session survives a restart (SHIPPED 2026-08-23)

A browser session authenticated before a restart stays valid after it, with
no re-login, for the same webui secret.

- Token is `HMAC-SHA256(secret, "zdtd-webui-session-v1")`, deterministic per
  secret, re-derived identically at every boot (`webui.zig` init and login).
- The cookie's own `Max-Age` (12 h) still expires it in the browser; `logout`
  clears it via `Max-Age=0`; changing the webui secret rotates all sessions.
- Trade-off accepted: a token captured before a logout becomes valid again
  after a restart, because logout is not persisted. Loopback-only threat
  model; noted in [WEBUI.md](../WEBUI.md) security.

Acceptance:
- `curl` login, restart with the same secret: the same cookie returns `200`
  on `GET /` without a re-login.
- Restart with a different secret: the cookie returns `401`.
- Unit test: `session token is deterministic per secret across restarts`
  (`zig build test`).

### R2. Persistence inventory regression gate (SHIPPED, keep green)

The section 5 rows are the contract. Every row keeps its round-trip proof
green under `make check` and the playtest `persist` suite:

- `zig build test`: save/load unit tests per store (ZPV9/ZPV10 restore, ZCL2
  schedule, ZWS1 queue, chunk round-trip, ...).
- `7dtd-playtest` `--suite persist`: setup -> saveworld -> restart -> rejoin,
  including `dig_survives_rejoin`.
- loadgen `--join` smoke against a restarted server (join/spawn/chunk/inv
  intact).
- Stock client (EAC off) rejoin after restart.

A change that adds a store format or a persistence field must add its
round-trip proof in the same change (rule 21, "persist via store").

## 7. Test strategy

| Layer | What |
|---|---|
| Unit | per-store save/load round-trips (`zig build test`) |
| Scenario | `7dtd-playtest` `persist` suite (multi-phase restart) |
| Load | loadgen join + actions against a restarted server |
| Ops | webui cookie round-trip across a restart (R1 acceptance, curl or browser) |
| Client | stock client rejoin (EAC off) for join/spawn/chunk/inv |

## 8. Open questions

- Should webui session persistence be a switch for operators who want
  sessions to die with the process? Today it is deterministic and always on;
  a `--webui-session-persist off` would restore the old fresh-nonce behavior.
  Not needed for the loopback ops use case, so parked.
- Does the restart contract need to cover plugin in-memory state (e.g., a
  chat filter's custom verdict counters)? ADR 0030 already makes plugins
  reloadable and re-armed, so persistence is out of scope unless a plugin
  proves it needs durable state across the boundary.
