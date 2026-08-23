# AGENTS.md - zdtd-server

**Zeven Days to Die**: clean-room Zig dedi for stock 7DTD **client wire** (EAC off). Research clone, not a Unity mod host.

Canonical modding guide: [MODDING_BEST_PRACTICES.md](https://github.com/hordeforge/.github/blob/main/MODDING_BEST_PRACTICES.md)

| | |
|---|---|
| Workspace | [`../AGENTS.md`](../AGENTS.md) |
| Architecture | [`docs/ZIG_CLONE.md`](docs/ZIG_CLONE.md) |
| Wire | [`../7dtd-engine-research/docs/protocol.md`](../7dtd-engine-research/docs/protocol.md) |
| **Status hub** | [`docs/STATUS.md`](docs/STATUS.md) |
| Gaps / plan | [`docs/GAP_ANALYSIS.md`](docs/GAP_ANALYSIS.md), [`docs/IMPLEMENTATION_PLAN.md`](docs/IMPLEMENTATION_PLAN.md) |
| Backlog | [`TODO.md`](TODO.md) |
| Doc index | [`docs/INDEX.md`](docs/INDEX.md) |
| Metrics | [`docs/APM.md`](docs/APM.md) · `src/apm/` |

Target: **V3.1.0 b14** (Mono) wire, Zig **0.16+**, **20 TPS** (50 ms) tick. Validate via loadgen + stock client (EAC off) + **zdtd** apm dumps.

## Principles

Governs every rule below. When in doubt, these decide.

1. **Clean-room.** Only stock client wire/sim. Never ship, embed, or depend on TFP DLLs, decompiled C#, or runtime assets. Stock content loads as data from operator install.
2. **Stock wire/sim only.** No invented terrain, packages, FX, or journal blobs. One stock shape → one builder the client `Read`s.
3. **Missing beats fake.** Prefer documented gaps over fabrication. A partial failing stock `Read` is worse than nothing.
4. **Ground truth is RE.** Wire/sim derive from decompiled `Assembly-CSharp.dll` (IL) and real prefabs/saves, cited (`../7dtd-engine-research/docs`, loadgen goldens). Fix code to RE, not the reverse; update RE only with evidence. **RE tooling/artifacts** (IL dumps, DLL-surface parity, format probes) live in `../7dtd-engine-research`, not zdtd.
5. **Not a mod host.** Research clone, not Unity host. No IModApi, Harmony, or `Mods/` code loading. Pure XML/assetbundle modlets (`Mods/<name>/Config` XPath patches, `Bundles/`, `Localization.csv`) are stock **data** and load as such ([PRD 0003](docs/prd/0003-modlets.md)): patched catalogs + join-phase config sync; DLLs are never hosted. Connect mod is test harness only; client tooling is join/automation only. **Hardcoding (ADR 0010):** stock content → game data (XML/AssignIds); server policy → config (`serverconfig`/`zdtd.toml`); sim/wire → Zig systems with data params + sandboxed Wasm plugins (ADR 0020).
6. **Correctness/security > minimalism > style.** Server authoritative, validates at trust boundaries; illegal states unrepresentable; YAGNI + **Zig Zen** (intent, edge cases, one obvious way, memory is a resource). Prefer idiomatic Zig **stdlib abstractions** (`std.Io`, …) over shelling/OS syscall glue (rule 26).
7. **Hold the 20 TPS budget.** 50 ms tick is the constraint. Validate via loadgen + stock client (EAC off) + zdtd apm dumps, not unit tests alone.
8. **Wire is contract; internals are not.** Client sees only binary wire. Never copy Mono per-entity heaps, Unity field order, or GC layouts into sim — prefer idiomatic measurable Zig (SoA, pools, serialize-once) judged by `apm` dumps, not RE visual similarity.

## Owns / does not own

| Owns | Does not own |
|---|---|
| Zig dedi process, wire, sim, world store | Stock Unity dedicated process |
| Protocol from RE + golden/loadgen tests | **Code mods** (Harmony, ModAPI, DLL modlets, EfficientServer, RealEarth) |
| XML/assetbundle modlet data loading: `Mods/` Config XPath patches → patched catalogs + `NetPackageConfigFile` join sync (PRD 0003) | Code mod hosting / IModApi |
| Join / spawn / chunk / inv play path for stock client + bots | Shipping TFP content/assets (load from user `game-dir`) |
| Native metrics (`src/apm/`) | **7dtd-server-apm** (Mono bridge; different process) |
| SoA ECS + serialize-once interest | Copying stock Mono architecture line-for-line |
| Bot brains = **Wasm plugins only** (ADR 0026): target selection, aim, movement and combat decisions live in `mods/zdtd_bot` (the `.wasm` guest); the host `BotManager` is a servant (spawn/replicate/move/LOS gate/sense fill/`bot` verbs) and must not grow native decision logic | Native bot AI in Zig |
| Behavioral/policy add-ons = **Wasm plugins by default** (ADR 0020): bots, chat commands/filters, announcements/kill-feeds, event observers, custom verdicts | Native Zig for discretionary gameplay behavior that belongs in a plugin |

## Critical rules

1. **Zig only** for server code. Wire facts from `../7dtd-engine-research/docs` + loadgen goldens.
2. **No game DLL or bulk IL** in this repo.
3. **Milestones** follow ZIG_CLONE then `IMPLEMENTATION_PLAN` (M7+). Don't skip join/terrain/inv fidelity for AI/scale.
4. **Package IDs dynamic.** Resolve via negotiated name→id map. Never treat numeric id as stable across versions (fixtures may pin maps for tests).
5. **Validate with loadgen + stock client + zdtd apm.** Never require 7dtd-server-apm.
6. **Instrument hot paths** (net, sim, interest, chunk stream) with `apm` as they land.
7. **No em dashes. No AI attribution** in commits, docs, comments, or PRs.
8. Prefer **SoA + serialize-once interest** over stock Mono shapes.
9. **Server owns missing features.** Fix stock-client gaps (chunks, deco, signs, inv direction, spawn/UI unlock, entity state) here with correct wire/sim. Never make `7dtd-fastconnect`/client mods invent world data, skip server steps, or suppress protocol errors. Client tooling is join/automation only. Workspace rule 10.
10. **Stock fidelity: missing > fake.** No invented terrain shells, fake FX, or incomplete journal blobs failing stock `Read`.
11. **New tunable = struct field, not parse arm.** `util/toml_bind.zig` binds `zdtd.toml`/mode packs by walking the dest struct — adding a field auto-configures/validates/documents it. Never hand-write `std.mem.eql(u8, key, ...)` chains (ADR 0021). Sim params live in `ecs/rules.zig`; a `Rules` value is a **floor** — per-entity stock data wins where present.
12. **Markup is not a string literal.** Webui pages are `.html` under `src/server/webui/` (CSS inline, JS compiled from TypeScript) embedded via `@embedFile`. Nothing read from disk at runtime. JS is authored as TypeScript in `src/server/webui/ts/` and compiled into the committed pages by `scripts/build-webui-ts.sh` (tsc, version-pinned; `make webui-ts`); `scripts/lint-webui.sh` (tsc `--noEmit` + oxlint with the anti-slop + strict rule set in `.oxlintrc.jsonc`, the dmmulroy/anti-slop plugin vendored as source at a pinned SHA fetched into the cache, plus a page-freshness gate) and `scripts/lint-html.sh` (vnu, `vnu-filter.txt`) are both part of `make lint`.
13. **Name for what it does.** Don't call a streaming throttle `world_enabled`. Confusing names are defects.
14. **One stock package shape → one builder.** No second "almost stock" encoder.
15. **Don't hardcode game asset data.** Full policy: [`docs/ASSETS.md`](docs/ASSETS.md). Every src file needs a provenance row in [`docs/PROVENANCE.md`](docs/PROVENANCE.md) (bucket A stock-data / R RE-cited / Z zdtd-owned + source); `tools/provenance_scan.py` in `make check` fails new files without one — add the row with the change. Stock `Data/Config`, prefabs, DTM, TTS, XML catalogs, etc. must be **read from assets** (runtime `game-dir`/`assets/*` or **comptime** embed/parse generating tables).
    - **Block/item wire ids** = AssignIds dump (`idByName`) only. Never sequential XML order; never invent parallel id spaces.
    - **Properties** (MaxDamage, Texture, Class, stack, HP, prices) from matching XML after name resolve.
    - **Biomemap colors/layers** from `biomes.xml`, not RGB switch tables.
    - **Fail closed:** missing name → omit / not placeable / skip deco. Wrong id worse than missing.
    - **Fixtures** under `assets/fixtures/` are offline tests only.
    - **OK hardcodes:** wire RE constants, Unity hashes from stock **names**, ConfigFile LoadLocal name list (protocol).
16. **RE before wire.** Field order, types, lengths, and join sequence come from `../7dtd-engine-research/docs`, loadgen goldens, or verified stock `Read`/`Write`. Don't guess layouts. If RE and code disagree, fix code (or update RE with evidence), not the client.
17. **Server authoritative.** Sim owns blocks, inv, TE, entity HP/alive, quests, locks, time. C2S is a request: validate (bounds, ownership, phase, rates), apply/reject, broadcast **resulting** state. Never blindly apply client world/inv blobs; never let C2S overwrite another player's slots or distant chunks without stock-legal path.
18. **Join/channel phase gates.** Accept only packages legal for peer's SM state (challenge → ids → login → enter → spawn → playing). Drop/disconnect illegal early/late C2S. Don't send play-world packages before client is ready per stock order.
19. **Interest, no self-echo.** Entity/chunk/TE/stream updates only to observing peers. Don't echo own movement or redundant full state unless stock does. Serialize-once per tick where interest already does.
20. **Bounds/caps on all untrusted/hot inputs.** Range-check C2S coords, slot indices, counts, string lengths, fragments. Cap streaming queues (chunks, deco, entity spawn) so one peer can't stall the 50 ms tick or OOM.
21. **Persist via store.** Mutations surviving restart go through `world/*`/save paths (e.g. ZCH3 `.zch`, player data), not just in-memory interest caches. Green join ≠ persist.
22. **Deterministic sim.** Stable tick order for shared data. RNG (loot/AI/director) uses explicit seeded state, not ad-hoc `std.crypto`/time noise. Same seed+inputs → same outcomes where claimed.
23. **Stock hashes/type ids.** Unity/string hashes, AssignIds class ids, block/item ids follow stock formulas/tables. Don't invent parallel id spaces diverging from client.
24. **Fail closed on encode.** If body can't be built correctly (missing catalog entry, buffer too small, unknown TE), omit or send stock empty/error form. Never truncate mid-field, zero-pad to guessed size, or desync `BinaryReader`.
25. **Keep `make check` green.** No "fix later" or skipped asserts. New wire/sim → unit or `scenarios.zig` test if non-trivial; join/spawn/chunk/inv → loadgen smoke when practical.
26. **Stdlib, not OS guts.** Prefer highest stable Zig 0.16 API: `std.Io`/`Dir`/`File`/`Threaded`, `std.mem`, `std.fmt`, `std.Thread` (via `util/parallel`), etc. No OOP abstract classes — **stdlib interfaces** (`std.Io` vtable) + thin helpers (`util/io_fs.zig`) are idiomatic. Don't open-code `std.os.linux.*`, raw `std.posix` file loops, or `std.c` for ordinary FS — use `util/io_fs`/`std.Io`. OS-specific socket/clock calls confined to `litenet/udp_socket.zig`, `util/tcp_listen.zig`, `util/clock.zig`. Optional webui HTTP body via `std.http.Server` (see `docs/STD_ABSTRACTIONS.md`). Don't shell out when in-process API exists (workspace Native APIs rule). Follow [Zig Zen](https://ziglang.org/documentation/master/#Zen).
27. **Typed tools > shell.** Use `ast-grep` for structural edits, `ripgrep` (`rg`) for text search, `semcode` for semantic/cross-file search over bare `sed`/`grep`. Keep `Read`/`Glob`/`Grep` wrappers for workspace-aware search.
28. **Bots stay Wasm plugins (ADR 0026).** All bot brain logic — target selection, aim, movement and combat decisions — lives in the `mods/zdtd_bot` guest; the host `BotManager` stays a servant (spawn/replicate/move/LOS gate/sense fill/`bot` verbs + host policy knobs). Never port brain decisions into Zig, and never let the host drive bots without the module.
29. **Wasm-first for behavioral add-ons (ADR 0020).** Anything that is *technically* expressible over the plugin boundary — `zdtd.sense` / `zdtd.queue` / `zdtd.query` + the hooks and verdicts — ships as a Wasm plugin: bots, chat commands/filters, announcements and kill-feeds, event observers, custom verdicts, admin tooling, reward scaling. Native Zig is for what the boundary *cannot* express: wire encode/emit, LiteNet, interest/replication and the chunk stream, direct sim mutation (ECS authority, inventory, blocks, quests, trading), world store and persistence, config loading, the plugin runtime, APM instrumentation. "It is core" is not a reason to keep something native; prove that the boundary cannot carry it. When a feature needs an affordance the boundary lacks, extend the boundary (an ADR-worthy decision) rather than adding native behavior.
30. **Spatiotemporal composability for plugins (Cordis paper, adopted 2026-08-20).** Plugins are runtime components, so their lifecycle and effects must be bounded the way the paper's fibers are: (a) **reloadable** — a module can be disposed and reinstantiated in place without a server restart (`plugin reload <name>`; dispose runs `on_shutdown`, reclaims fuel/memory, re-arms the budget, re-activates `on_enable`); (b) **revertible effects** — every `zdtd.queue` command is attributed to its issuing plugin (1-based slot src) and a disabled/trapped module's still-pending effects are withdrawn before the drain; never let a broken module's queued effects execute; (c) **declarative dependencies** — modules export `_zdtd_requires` naming the hooks + host verbs they need, validated fail-closed at load (a typo'd hook must be a loud load rejection, not a silent never-fire). When adding a plugin affordance, keep it compatible with all three; review plugin-runtime changes against `docs/prompts/plugin-composability-review.md`.

## Commands

```bash
zig build              # Debug → zig-out/bin/zdtd
zig build test         # unit + scenario tests (must stay green)
zig build run
make check             # version/toolchain pin + lint + build + test + fuzz
make release           # ReleaseSafe + strip (operator binary)
make clean             # zig-out + .zig-cache + .zdtd_cfg_cache
```

```bash
# Flat default world
zig-out/bin/zdtd --port 27002 --world worlds/zdtd_default

# Stock map (DTM + prefabs + water + Data/Config)
GAME="$HOME/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server"
zig-out/bin/zdtd --port 27002 --game-dir "$GAME" --world-name Navezgane --world worlds/nav_save
# or: --map "$GAME/Data/Worlds/Pregen06k01"
```

## Validation (once listening)

```bash
# From sibling 7dtd-loadgen (port must match zdtd --port)
./src/LoadGen/bin/Release/net8.0/7dtd-loadgen \
  --join --host 127.0.0.1 --port 27004 --count 2 --actions 20
# LiteNet is ServerPort+2 (zdtd --port 27002 → loadgen --port 27004)

# Metrics: zdtd text/JSON snapshot (docs/APM.md), not 7dtd-server-apm sessions
```

Join/spawn/chunk/inv changes: loadgen smoke **and** stock client (EAC off) when practical. Unit green alone insufficient.

## Layout

```text
src/main.zig           CLI, DebugAllocator, construct Game, run loop
src/protocol.zig       wire constants (challenge, tick rate; package ids in wire/)
src/server/game.zig    join SM; delegating façade — most paths in game/*, c2s/*
src/server/game/*      per-domain Game helpers (net, tick, world, player, join) — each takes *Game
src/server/c2s/*       C2S handlers by domain (join, move, blocks, inv, quest, misc); each exposes handle(*Game,*Client,*Peer,name,body) anyerror!bool, routed by dispatch.zig
src/server/*           admin TCP, GSI, config, persistence, scenarios, webui
src/ecs/*              SoA world, systems, inventory, quests, interest
src/world/*            chunks, TTS, prefabs, sleepers, containers, DTM, biomes
src/wire/*             package bodies (stock_*), binary LE, frames
src/litenet/*          LiteNet framing, peers, std.Io.net UDP
src/assets/*           blocks/items/recipes/loot/quests/entities XML tables
src/apm/*              counters, section timers, dumps (not 7dtd-server-apm)
src/plugin/*           Wasm plugin host, hook table, budgets (ADR 0020)
src/util/parallel.zig  optional range split (AI, turrets, chunk save)
src/util/toml_bind.zig comptime-reflected TOML binder (ADR 0021)
src/ecs/rules.zig      sim rule params, overlaid by mode packs (ADR 0021)
src/server/webui/      webui markup, @embedFile'd (never Zig string literal); linted by scripts/lint-webui.sh (JS) + lint-html.sh (HTML/CSS)
assets/fixtures/       offline XML and .wasm fixtures for tests
modes/                 gamemode packs (`--mode <name>`)
scripts/               release, lint and smoke gates called by Makefile
docs/                  STATUS, gaps, plan, APM, wire/map notes; numbered PRD/RFC/ADR series in docs/{prd,rfc,adr}
worlds/                local save overlays (ZCH3 `.zch`, player data)
```

| Concern | Lives in | Does not live in |
|---|---|---|
| Stock package body layout | `wire/stock_*.zig`, `packages.zig` | `game.zig` open-coded writes |
| C2S handlers | `server/c2s/*` (`handle` per domain, phase-gated) | `game.zig` large if/else chain |
| Game helpers | `server/game/*` (`net`, `tick`, `world`, `player`, `join`, `chunk_stream`, `trader`), `server/persist.zig` | `game.zig` inline bodies |
| Block/world mutation | `world/*`, `ecs` | LiteNet / package id tables |
| Syscalls / sockets | `litenet/udp_socket.zig`, `util/tcp_listen.zig` (Io.net + thin posix) | package builders, ECS systems |
| XML / config load | `assets/*`, `server/config.zig` | tick path |
| Metrics | `apm/*` via `Game.harness` | 7dtd-server-apm bridge |

- Import **facades** when they exist: `*/root.zig` per package (`util`, `apm`, `litenet`, `wire`, `assets`, `ecs`, `world`, `server`) and `wire/packages.zig` for stock bodies. Leaf files stay importable. Avoid cycles; world must not import wire (TE domain types in world, wire re-exports).
- `src/server/c2s/` and `src/server/game/` are subfolders of `server`; every file there is aggregated via `src/server/root.zig` (lint recurses one level, so new helpers must be added there or tests silently drop).
- `pub` only for intended API. Helpers file-private by default.
- Dependency edges **enforced**: `scripts/lint-architecture.sh` (`make check`) fails on forbidden `@import`. Adding one requires changing the lint and justifying the edge.

## Docs: PRD / RFC / ADR series

Numbered doc series under `docs/`, one directory per series; the registry for
each series is its README. Numbers are 4-digit zero-padded and never reused;
PRD and RFC numbers pair by addon (the design answering PRD NNNN lives in
RFC NNNN).

| Series | Lives in | Registry |
|---|---|---|
| ADR (architecture decision) | `docs/adr/NNNN-slug.md` | `docs/adr/README.md` |
| PRD (product requirements) | `docs/prd/NNNN-slug.md` | `docs/prd/README.md` |
| RFC (request for comments: proposal / design) | `docs/rfc/NNNN-slug.md` | `docs/rfc/README.md` |

How to use:

- **ADR** records a decision that has been made (context → decision →
  consequences); a later reversal supersedes, never edits. A decision still
  being made is an RFC, not a proposed ADR.
- **PRD** says what a feature or addon must do and why (problem, requirements
  R1…, acceptance). New feature with a spec-able product intent: PRD, then
  RFC, then ADRs for the architecture calls it forces.
- **RFC** (request for comments) proposes the how — the technical
  spec/design/plan answering the PRD — for review; the decision it forces is
  recorded in an ADR. Carries the same number as its PRD.
- Adding a doc: start from the series' `TEMPLATE.md`, take the next free
  number from the series README, name the file `NNNN-kebab-slug.md`, put
  `**Number:** <SERIES> NNNN` in the header block, and add a row to the series
  README plus the `docs/INDEX.md` document series section.
- Referencing: cite by number (`PRD 0003 §8`, `RFC 0001 §3`, `ADR 0026`), and
  keep links and cross-references in sync when a doc moves or renumbers.

## Zig style

Zig **0.16**. Shaped by wire fidelity, 20 TPS, SoA sim, and loadgen/stock-client evidence. Naming/memory follow usual Zig house style ([agave](https://github.com/hordeforge/agave/blob/main/AGENTS.md) is one reference); rest is dedi-specific.

### Naming

| Kind | Style | Example |
|---|---|---|
| Functions / methods | `camelCase` | `buildPlayerIdBody`, `setBlockWorld`, `sendJoinBundle` |
| Variables / fields / params | `snake_case` | `entity_id`, `world_dir`, `body_buf`, `view_radius` |
| Types | `PascalCase` | `Game`, `World`, `PackageName`, `StockSlot` |
| Files | `snake_case.zig` | `stock_quest.zig`, `udp_socket.zig` |
| Constants | `snake_case` module `const` | `max_streamed_chunks`, `pending_cap` |
| Stock type / package names | Match TFP strings | `NetPackagePlayerId`, `PackageName` cases |

**No magic numbers** on wire/tick paths. Field sizes, AssignIds/mapping captures, bit masks, buffer caps, RE version pins are named module `const` (often with one-line RE comment or `../7dtd-engine-research/docs` path).

### Wire and packages

- Bodies into **caller buffer** (`Game.body_buf`, stack `[N]u8` in tests): `buildXxxBody(buf, …) ![]u8`. Prefer over per-send allocation.
- Use `wire/binary.zig` (`Reader`/writers) for .NET BinaryReader/Writer: LE ints, 7-bit string lengths. No second endian path.
- Resolve package ids via negotiated map (`PackageIds`/`default_mappings` in fixtures).
- Document non-obvious field order next to writes (RE/stock `Read` order).
- Never send incomplete packages failing stock `Read` to "look busy." Correct empty/omit beats fake body. Server owns gaps; don't paper over in clients.

### Memory

- Root: `DebugAllocator` in `main`, pass `allocator` to `Game`/long-lived stores. No global allocator for sim/wire.
- Allocators explicit: `std.mem.Allocator` or caller-owned buffers. `defer deinit` after acquire; `errdefer` for error-only paths.
- **Hot path: no heap alloc.** Tick, per-packet C2S/S2C, interest/replicate, chunk stream, ECS systems must not `alloc`/`create`/`dupe`/`allocPrint`, grow `ArrayList`/`HashMap`, or create arenas. Reuse `recv_buf`/`send_buf`/`body_buf`, fixed client slots, SoA columns, pools, stack/`bufPrint`. At cap: drop/omit (named const), don't realloc.
- Init/load/admin may allocate (maps, TTS cache, XML, prefabs, first-touch chunk **slot** fill into pre-reserved storage). Cache by stable keys; never re-parse XML per tick.
- `page_allocator` not for tick/package work. Tests use `std.testing.allocator` (or `DebugAllocator`) so leaks fail CI.

### Tick path (20 TPS / 50 ms)

Main sim + net loop is effectively single-threaded for game rules.

- **No heap alloc** (see Memory). No unbounded growth.
- No new threads per tick (`util/parallel` pool only).
- Syscalls on existing poll/`recv`/`sendto` batch path (LiteNet + GSI). No file opens or XML re-read mid-tick.
- Parallelism only via `util/parallel.zig`, never ad-hoc `std.Thread.spawn` in builders/join SM.
- New cost on net/sim/interest/chunk stream: `apm` sections/counters. Judge regressions from **zdtd** dumps, not 7dtd-server-apm.

Init, map load, admin commands may take longer; amortize into caches.

### Comptime and Zig 0.16

- `comptime` for closed sets (package enum maps, bit layouts, small parsers). `inline` only for tiny hot helpers, not large builders.
- Prefer `@memcpy`/`@memset`, `@bitCast`/`@intCast`/`@truncate`, `@min`/`@max` over bulk loops when clear.
- `ArrayList`: `.empty`, pass allocator to methods (`append(allocator, v)`).
- Prefer `@Int`/`@Enum`/`@Struct`/`@Union` over removed `@Type()`.
- `main` takes `std.process.Init.Minimal` (or full `Init`); thread allocator from there. No pre-0.16 shims.
- Build in `build.zig`/`build.zig.zon`. `Debug` for safety; `ReleaseFast` for soak. Thin Makefile OK; don't hide real build in Make alone.

### Filesystem and I/O (Zig 0.16)

- **Default:** `std.Io.Threaded` (or process Io) + `std.Io.Dir`/`File`. Ex: `Dir.cwd().writeFile(io, .{ .sub_path, .data })`, `Dir.cwd().openDir(io, path, .{ .iterate = true })`, `createDirPath`, `openFile` + read helpers.
- Shared helpers: `src/util/io_fs.zig` (mkdir/write/read/list via `std.Io` only).
- Config + `--config-overrides` via `assets/paths.zig` + `io_fs`, never raw open/getdents.
- **Forbidden:** `std.os.linux.*` for ordinary files, ad-hoc `posix`/`std.c` file loops, `/tmp` for large caches (use project or `~/.cache`).
- **Layering:** app → `io_fs` (optional) → `std.Io` → (std internals). Don't skip to bottom from game/assets/world.
- **UDP/LiteNet:** `litenet/udp_socket.zig` via `std.Io.net`. **TCP:** `util/tcp_listen.zig`. Optional HTTP: `std.http.Server` (see `docs/STD_ABSTRACTIONS.md`). Don't invent second raw-syscall net stack.

### Zig Zen (tie-break)

When two correct approaches exist, pick the [Zig Zen](https://ziglang.org/documentation/master/#Zen) one: precise intent, edge cases, readable code, one obvious way, fail at compile time when possible, incremental migration off legacy I/O, **memory is a resource** (no hot-path heap), dealloc always succeeds (`defer`). Full rubric: [`docs/prompts/zig-idiomatic-review.md`](docs/prompts/zig-idiomatic-review.md).

### Errors and safety

- Explicit error sets + `try`/`catch`. Empty `catch {}` only for true best-effort shutdown or documented non-fatal RE fallback (comment why). Never `catch undefined`.
- `std.debug.assert` for internal invariants (slot bounds, buffer caps, streamed_n).
- Malformed client packets: reject/drop/disconnect per join SM; don't crash whole process on one bad peer when avoidable.

### Documentation in code

- File-level `//!`: purpose and non-goals.
- Public APIs: `///` with ownership (who frees / whose buffer) and non-obvious errors.
- No narrating comments on obvious code. RE/layout comments on wire fields welcome.

### Testing and evidence

- Unit `test` blocks at **bottom** of owning file.
- Multi-system join/inv/chunk paths: extend `src/server/scenarios.zig`, don't duplicate harnesses.
- Wire: golden layout tests (sizes, markers, fixture mappings). Builders the stock client `Read`s need tests or explicit join-path scenario.
- `zig build test` must stay green. Listen/join changes: loadgen smoke when practical.
- **Tests never write into repo.** Use `std.testing.tmpDir` (self-cleaning) and pass path in. Writing to working dir (= repo root) has produced accidental committed scratch files and dirty `git status` depending on whether a scenario ran. `.zdtd_test_*` is gitignored as backstop, not licence.
- Tests leaving state fail on second `make check`. If a scenario needs a world, give it one it removes.

## Stock-game research -> 7dtd-engine-research

Stock dedi research belongs in [`../7dtd-engine-research/`](../7dtd-engine-research/), not here: RE narratives (`docs/`), Mono.Cecil dump tooling (`tools/`), wire/protocol analysis, engine cost/loop RE. This repo is the Zig reimplementation; it doesn't host RE docs/dumpers. When RE is needed, add it under `../7dtd-engine-research/` and link back. How to RE: [`../7dtd-engine-research/docs/re-methodology.md`](../7dtd-engine-research/docs/re-methodology.md).
