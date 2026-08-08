# Dependency and layering architecture review 2026-08-08 (zdtd)

| | |
|---|---|
| Date | 2026-08-08 |
| Audit start | `8638918` (branch main, ahead 5 of origin/main) |
| Audit end | `b78e8bd` + sibling WIP in the working tree (main ahead 10 of origin/main) |
| Scope | `src/` import graph: `scripts/lint-architecture.sh` enforced edges, full-depth `@import` scan, import cycles, facade aggregation, plugin host seam |
| Mode | Audit first, small safe fixes only. No code change was needed: zero forbidden edges, zero missing barrel exports, no bad imports found |
| Companion docs | `docs/reviews/WASM_REVIEW_2026-08-08.md` (plugin seam), `docs/ECS_SYSTEMS.md`, `docs/adr/0020` |

Branch caveat: main advanced during the audit. A sibling agent landed
`a6c7fc5` (remove dead `trade.zig`), `b8509fe` (drop it from the barrel),
`f4cae2a` (remove dead `chunk_stream.zig`), `6d4e029` (drop it from the
barrel), `b78e8bd` (remove dead module-level Game method duplicates), and has
uncommitted work in `src/ecs/{aidirector,systems,world}.zig`,
`src/server/{admin_console,game,sleeper}.zig`, `src/wire/packages.zig` at the
time of delivery. All counts and cycle lists below were re-verified against
the delivery-time working tree; where a number changed during the audit it is
noted. The dead-code removals shrank the server-layer cycle (see section 3).

Method: (1) ran `bash scripts/lint-architecture.sh` (clean, at start and at
delivery), (2) read the lint to extract the enforced edge list, (3) parsed
every `@import("...")` in all `src/**/*.zig` files, resolved paths relative to
the importing file, and built the full package and file graph, (4) ran Tarjan
SCC for cycles, (5) compared actual edges against both the lint and each
`src/*/root.zig` dependency note, (6) re-ran the forbidden-edge greps at any
`../` depth, (7) ran `make check` twice (see flake note below).

## Outcome

| Question | Result |
|---|---|
| `lint-architecture.sh` at start and at delivery | **clean** (exit 0) |
| Forbidden package edges (lint depth and full depth) | **0 occurrences** of every documented forbidden edge |
| `ecs -> assets` / `ecs -> server` / `world -> wire` | **0** (confirmed at any `../` depth) |
| `assets -> server` | **0** (assets never imports server; server imports assets 41x) |
| `wire -> ecs` | **allowed** by `wire/root.zig` note; actual 2 (pure component shapes only) |
| Imports escaping `src/` or jumping 3+ layers | **0** |
| Missing root.zig barrel exports (strict `@import` check) | **0** |
| Missing `packages.zig` stock body re-exports | **0** |
| Import cycles beyond the documented Game <-> shard delegation | **2, both intra-package, benign in Zig, not documented** (C1 ecs 7 files, C2 world 3 files); refactor to break, not trivially safe, left for follow-up |
| Plugin host seam | **clean**: plugin imports only `std` + `util`; hooks pass primitives; `HostCtx.data` opaque |
| Fixes applied | **none** (nothing trivially safe to fix; no violations) |

---

## 1. Enforced edge list (scripts/lint-architecture.sh)

`check_edges` (line 16) greps `@import\("\.\./(<forbidden>)/"` under each package
dir; the enforced blacklist (lines 28-39) is:

| Package | Forbidden to import | Line |
|---|---|---|
| util | server, wire, world, ecs, assets, litenet, apm | 28 |
| apm | server, wire, world, ecs, assets, litenet | 29 |
| litenet | server, world, ecs, assets, apm (wire deliberately exempt) | 30 |
| plugin | server, wire, world, ecs, assets, litenet, apm | 31 |
| assets | server, wire, world, litenet, apm (ecs allowed, pure shapes) | 36 |
| ecs | server, wire, world, assets, litenet, apm (util only) | 37 |
| world | server, wire, litenet, apm (util, assets, pure ecs allowed) | 38 |
| wire | server, litenet, apm (util, assets, ecs shapes, world TE types allowed) | 39 |

Plus two aggregation checks: every package file (one subfolder level) must be
referenced by basename + quote in its `root.zig` (lines 48-73), and every
`wire/stock_*.zig` must be re-exported from `wire/packages.zig` (lines 75-84).
The enforced set matches the dependency notes in `src/*/root.zig` exactly;
nothing in the docs is enforced more strictly or more loosely.

## 2. Edge table: enforced / documented / actual

Actual counts are unique `@import` lines resolved to package level, from the
full-depth scan of the delivery-time tree (all `../` depths, not just the
lint's one-level pattern).

| From | To | Lint (enforced) | root.zig doc | Actual | Verdict |
|---|---|---|---|---|---|
| util | any pkg | forbidden | forbidden | 0 | OK |
| apm | util | allowed | allowed | 2 (clock) | OK |
| apm | other pkg | forbidden | forbidden | 0 | OK |
| litenet | util | allowed | allowed | 1 (clock) | OK |
| litenet | wire | allowed | allowed, Capture only | 1 (`peer.zig:38`, inside `pub const Capture`) | OK, exception is exactly as documented |
| litenet | server/ecs/world/assets/apm | forbidden | forbidden | 0 | OK |
| plugin | util | allowed | allowed | 1 (`wasm.zig` -> io_fs) | OK |
| plugin | other pkg | forbidden | forbidden | 0 | OK |
| assets | ecs | allowed | allowed, pure shapes | 7 (components/quest/inventory) | OK |
| assets | util | allowed | allowed | 25 (io_fs, rng) | OK |
| assets | server/wire/world/litenet/apm | forbidden | forbidden | 0 | OK |
| ecs | util | allowed | allowed | 4 (parallel, rng, toml_bind) | OK |
| ecs | server/wire/world/assets/litenet/apm | forbidden | forbidden | 0 | OK |
| world | util | allowed | allowed | 15 | OK |
| world | assets | allowed | allowed | 13 | OK |
| world | ecs | allowed | allowed, pure shapes | 2 (components) | OK |
| world | server/wire/litenet/apm | forbidden | forbidden | 0 | OK |
| wire | util | allowed | allowed | 0 (binary/frame are package-local) | OK |
| wire | assets | allowed | allowed (id pins, unity hash) | 8 | OK |
| wire | ecs | allowed | allowed (component shapes) | 2 (components) | OK |
| wire | world | allowed | allowed (TE domain types) | 2 (containers, workstations) | OK |
| wire | server/litenet/apm | forbidden | forbidden | 0 | OK |
| server | apm | allowed | allowed | 4 (facade) | OK |
| server | assets | allowed | allowed | 41 (leaf) | OK |
| server | ecs | allowed | allowed | 40 leaf + 20 facade | OK |
| server | litenet | allowed | allowed | 21 (leaf) | OK |
| server | plugin | allowed | allowed | 2 (facade) | OK |
| server | util | allowed | allowed | 33 (leaf) | OK |
| server | wire | allowed | allowed | 19 leaf + 24 facade (`packages.zig`) | OK |
| server | world | allowed | allowed | 42 (leaf) | OK |
| any | top-level `protocol.zig`/`version.zig` | unconstrained | documented in `wire/root.zig` (protocol) | server 2 protocol + 4 version, wire 1 protocol, main 1 + 1 | OK, see lint recommendation R4 |

**Violations: none.** Every actual edge is inside the documented envelope, at
both the lint's one-level depth and the full recursive depth. The counts above
are slightly lower than the audit-start tree because the sibling's dead-code
removals (`trade.zig`, `chunk_stream.zig`) took their import lines with them
(start: server->world 47, server->assets 45, server->util 35, server->wire 47,
server->ecs 63, server->apm 5, server->litenet 24).

## 3. Import cycles

The one documented cycle is the server-layer delegation pattern: `game.zig`
imports `game/*` shards, `c2s/*`, `persist`, `replicate_te`, `admin_console`,
and every one of those imports the `Game` type back. At audit start this SCC
had 26 files (including `chunk_stream.zig`); the sibling's dead-code removal
(`f4cae2a`/`6d4e029`) dropped it to 25 at delivery. `trade.zig` was never in
the SCC. This is the sanctioned "Game <-> shard delegation" and is excluded
from findings.

Two additional SCCs exist and are **not** documented anywhere:

### C1: ecs internal cycle (7 files)

`ecs/world.zig` <-> `ecs/{aidirector,command,observers}.zig` and
`ecs/systems.zig` <-> `ecs/{query,schedule}.zig`, joined by
`ecs/world.zig -> aidirector -> systems -> query -> world`.

- `world.zig` imports `aidirector` (11 uses), `command` (5), `observers` (2)
- `aidirector` imports `world` (61 uses) and `systems` (3)
- `systems` imports `world` (152), `query`, `schedule`
- `query` imports `world` (96), `schedule` imports `world` + `systems` (17),
  `command` imports `world` (4), `observers` imports `world` (12)

All back-edges are type uses (`*World`, `Slot`, `max_entities`). This compiles
and tests green (Zig permits import cycles; no comptime evaluation cycle), but
it defeats the SoA "one owner per column" intent: the hub `world.zig` reaches
into its own subsystems. Breaking it requires extracting `World`, `Slot`, and
`NetId` into a lower types file (or moving the director/command/observers
state out of `World`) - a refactor, not a trivially safe edit. **Flagged,
not fixed.** Note: the sibling's in-flight edits touch `ecs/world.zig`,
`ecs/systems.zig`, and `ecs/aidirector.zig`; re-check this cycle after that
work lands.

### C2: world internal cycle (3 files)

`world/store.zig` -> `world/prefabs.zig` -> `world/deco_mirror.zig` ->
`world/store.zig`.

- `store.zig` uses `prefabs.Index` and `prefabs.loadFromWorldDir` (5 uses)
- `prefabs.zig` uses `deco_mirror.offsetsFor`, `childRaw`, `ischild_bit` (5 uses)
- `deco_mirror.zig` takes `*store.World` in `apply` and `isMultiBlockAnchor`
  and calls `store.World.worldToChunk` (10 uses)

The back-edge is the `*store.World` parameter in `deco_mirror`'s API. Breaking
it means inverting the call (store drives deco mirror with a narrow slice of
chunk/block data) or extracting the chunk/world type used by both. Refactor,
**flagged, not fixed.**

Both cycles are a design smell, not a defect: `zig build test` is green and no
comptime cycle exists. They are the top candidates for the cycle lint (R2).

## 4. Tight coupling

- **server importing world internals directly:** yes, 42 leaf imports of
  `world/*.zig` files (store, containers, vending, workstations, sleepers,
  weather, deco_mirror, ...) and 0 through the `world/root.zig` facade. This is
  **legal by design**: AGENTS.md says "Leaf files stay importable" and the
  lint's job is that the barrel aggregates everything, not that callers must
  use it. The codebase convention is leaf imports everywhere (server -> assets
  41 leaf, server -> util 33 leaf, server -> ecs 40 leaf, server -> litenet 21
  leaf). Facades are used for apm (4/4), plugin (2/2), and the stock wire
  bodies (24 via `packages.zig`); ecs root is mixed (20 facade / 40 leaf).
  Not a violation; see R5 for a possible convention check.
- **ecs importing world/store:** **0** occurrences (ecs has no import of world
  at any depth).
- **`..` layer jumps:** none. All cross-package imports resolve one package
  level up; subfolder files (`server/c2s/*`, `server/game/*`) use `../../pkg/`
  which is the same single-layer jump; no import escapes `src/`; no
  `../../../`.

## 5. Facades

All eight `root.zig` barrels exist and aggregate their packages: `util` (7),
`apm` (4), `litenet` (4), `plugin` (4), `assets` (26), `ecs` (27), `world`
(19), `server` (41 including `game/*` and `c2s/*`). Strict check: every `.zig`
file in each package dir and one subfolder level is `@import`-ed by its root
(0 missing, re-verified at delivery; the sibling's barrel drops for
`trade.zig`/`chunk_stream.zig` kept the aggregate exactly in sync with the
removals). `wire/packages.zig` re-exports all 10 `wire/stock_*.zig` plus
`te_types` (0 missing). No `root.zig` imports across packages; each root is a
pure barrel of its own package. Leaf files stay importable, confirmed by the
leaf-import convention above.

## 6. Assets <-> server direction

One-way and correct: `assets -> server` = 0 (any depth); `server -> assets` =
41 leaf imports. `assets/root.zig` documents "Must not import world, server, or
wire" and the actual graph matches. The allowed `assets -> ecs` edge (7, pure
shapes: `components.zig`, `quest.zig`, `inventory.zig`) is exactly the
documented catalog-to-sim mapping.

## 7. Plugin host seam (src/plugin)

Verified clean on all three layers:

- `plugin/api.zig`: static hook table only; hooks take primitives (`peer_slot:
  u16`, `entity_id: i32`, `x/y/z: i32`, `dmg: i32`) and a narrow `Host` view
  (version, tick, log fn). No `*Game`, no ecs/world types.
- `plugin/host.zig`: fixed 8-slot table; imports only `std`, `api`,
  `sample_hello`.
- `plugin/wasm.zig`: imports only `std`, `zwasm`, `util/io_fs`. `HostCtx.data`
  is `?*anyopaque` and the file never dereferences it (`wasm.zig:50`); the
  owner (`game.zig`) casts. No sim internals cross into the plugin layer.

Direction: server imports plugin via `plugin/root.zig` (`game.zig:94`,
`game/types.zig`); plugin never imports server, ecs, world, wire, or assets
(lint-enforced and actual 0). The hooks are invoked from `game.zig` after core
validation (chat, admin command, join gate) with primitive arguments only.

## 8. Transient test flake (watch item, not a dependency defect)

One of two `make check` runs at audit start failed in `zig build test` with an
internal test runner `EndOfStream` (SIGABRT) right after
`PASS workstations-zws`. The same seed (`0x8a407c07`) did not reproduce, and
three subsequent `zig build test` runs plus a full `make check` re-run were
green (exit 0). This looks like the known Zig test-runner/compiler-server pipe
flake class, unrelated to the dependency graph. Watch item only.

## 9. Recommended new lint rules

| ID | Rule | Shape | Priority |
|---|---|---|---|
| R1 | **Deepen `check_edges` to any `../` depth.** Line 20 only matches `@import("\.\./<pkg>/"`, so `../../` imports from subfolders evade it. Today only `server` has subfolders and server may import everything, so nothing is missed, but a future restricted package with subfolders would silently bypass the lint. Change the pattern to `@import\("(\.\./)+<pkg>/"` and drop hits whose resolved target stays inside `src/<package>` (no current false positives). | `scripts/lint-architecture.sh` | High |
| R2 | **Cycle detection.** Add a small SCC script (python or zig) over `@import` edges; fail on any SCC not fully inside `src/server/` (the documented Game <-> shard delegation) unless explicitly allow-listed. This would have caught C1 (ecs) and C2 (world). Fix the two cycles first, or start with an allow-list carrying a follow-up note. | new `scripts/lint-cycles.sh`, wired into `make lint` | High |
| R3 | **Narrow the litenet -> wire exception.** The lint deliberately excludes `wire` from litenet's blacklist because of `peer.Capture`; nothing stops a second litenet -> wire import. Add a focused check: exactly one `@import("\.\./wire/` under `src/litenet`, and it must be `peer.zig` (line 38, inside `pub const Capture`). | `scripts/lint-architecture.sh` | Medium |
| R4 | **Whitelist top-level constants.** `src/protocol.zig` and `src/version.zig` are currently unconstrained. Document and enforce: `protocol.zig` only from `main.zig`, `server/**`, `wire/**` (actual: main 1, server 2, wire 1); `version.zig` only from `main.zig`, `server/**` (actual: main 1, server 4). Actual usage already matches. | `scripts/lint-architecture.sh` | Low |
| R5 | **Facade-first convention (optional, informational).** Leaf imports are legal and pervasive; do not make facade usage a hard rule (would churn ~150 imports with no correctness gain). Optionally add an informational counter (not a failure) so facade coverage can trend. | note in AGENTS.md, not a lint | Low |

## 10. Fixes applied

None. The audit found zero forbidden edges, zero missing root.zig exports, zero
bad imports, and no trivially safe item to fix. The two intra-package cycles
(C1, C2) are refactor-sized and left as flagged follow-ups. No changes to
`docs/STATE_MACHINES.md`, `docs/GAMEPLAY.md`, or `docs/INDEX.md` (untouched per
instruction). The only change in this review is this document. The working tree
also carries the sibling agent's in-flight edits; those are not mine and are
left untouched.
