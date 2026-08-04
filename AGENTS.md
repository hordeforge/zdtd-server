# AGENTS.md - zdtd

**Zig Days To Die**: clean-room dedicated server in Zig for the stock 7DTD
**client wire** (EAC off). Research clone, not a stock Unity host for mods.

| | |
|---|---|
| Workspace | [`../AGENTS.md`](../AGENTS.md) |
| Architecture | [`docs/zig-clone.md`](docs/zig-clone.md) |
| Wire | [`../7dtd-research/docs/protocol.md`](../7dtd-research/docs/protocol.md) |
| **Status hub** | [`docs/STATUS.md`](docs/STATUS.md) |
| Gaps / plan | [`docs/MISSING_FEATURES.md`](docs/MISSING_FEATURES.md), [`docs/IMPLEMENTATION_PLAN.md`](docs/IMPLEMENTATION_PLAN.md) |
| Backlog | [`TODO.md`](TODO.md) |
| Doc index | [`docs/INDEX.md`](docs/INDEX.md) |
| Metrics | [`docs/APM.md`](docs/APM.md) · `src/apm/` |

Target: game **V3.x Mono** client wire, Zig **0.16+**, **20 TPS** (50 ms) main
tick. Validate with loadgen + stock client (EAC off) + **zdtd** apm dumps.

## Principles

The operating principles behind every rule below. When in doubt, these decide.

1. **Clean-room.** Implement the stock client's wire and sim behavior only.
   Never ship, embed, or depend on TFP DLLs, decompiled C#, or assets as
   runtime. Stock content loads as data from the operator's install.
2. **Stock wire and sim only.** No invented terrain, packages, FX, or journal
   blobs. One stock shape maps to one builder that the client will `Read`.
3. **Missing beats fake.** Prefer an honest, documented gap over fabricated
   content or behavior. A partial that fails stock `Read` is worse than nothing.
4. **Ground truth is RE.** Wire formats and sim behavior derive from the
   decompiled `Assembly-CSharp.dll` (IL) and real prefab / save files, and are
   cited (`../7dtd-research/docs`, loadgen goldens). Fix code to match RE, not
   the reverse; update RE only with evidence. **Reversing tooling and artifacts
   (IL dumps, DLL-surface parity tools, format probes) live in the
   `../7dtd-research` project, not in zdtd.** zdtd holds only the clean-room
   server.
5. **Not a mod host.** zdtd is a research clone, not a Unity host for mods. No
   IModApi, Harmony, or `Mods/` loading. The connect mod is a test harness only,
   never a product; client tooling stays join / automation. **Hardcoding policy
   (ADR 0010):** stock content → game data (XML/AssignIds); server policy →
   config (`serverconfig` / `zdtd.toml`); sim/wire → Zig systems with
   data-driven parameters + native plugins (ADR 0005). No script VM in core.
6. **Correctness and security first, then minimalism, then style.** Server is
   authoritative and validates at trust boundaries; make illegal states
   unrepresentable; apply YAGNI and **Zig Zen** (intent, edge cases, one obvious
   way, memory is a resource). Prefer idiomatic Zig **stdlib abstractions**
   (`std.Io`, …) over shelling out or OS-specific syscall glue (rule 24).
7. **Hold the 20 TPS budget.** The 50 ms tick is the constraint. Validate with
   loadgen plus a real stock client (EAC off) plus zdtd apm dumps, not by unit
   tests alone.
8. **Never leave a broken build.** Keep `make check` green and tests passing;
   no "fix later," no skipped assertions to land a feature.

## Owns / does not own

| Owns | Does not own |
|---|---|
| Zig dedi process, wire, sim, world store | Stock Unity dedicated process |
| Protocol from RE + golden/loadgen tests | **Mods** (Harmony, ModAPI, XML modlets, EfficientServer, RealEarth) |
| Join / spawn / chunk / inv play path for stock client + bots | Shipping TFP content or assets (load from user `game-dir`) |
| Native metrics (`src/apm/`) | **7dtd-apm** (Mono bridge; different process) |
| SoA ECS + serialize-once interest | Copying stock Mono architecture line-for-line |

## Explicit non-goals

1. **Not mod-compatible.** No IModApi, Harmony, or `Mods/` loading.
2. **Not a 7dtd-apm target.** Grow `src/apm/` only (counters, section latency, dump).
3. **Not EAC-on.** EAC-off stock clients and loadgen bots only.
4. **Not a content ship.** Runtime load of stock XML/maps from the operator's game install.

## Critical rules

1. **Zig only** for server code. Wire facts from `../7dtd-research/docs` + loadgen goldens.
2. **No game DLL or bulk IL** in this repo.
3. **Milestones** follow zig-clone then `IMPLEMENTATION_PLAN` (M7+). Do not skip
   join/terrain/inv fidelity to chase AI or scale theatre.
4. **Package IDs are dynamic.** Resolve via negotiated name→id map. Never treat a
   numeric id as permanent across versions (fixtures may pin maps for tests).
5. **Validate with loadgen + stock client + zdtd apm.** Never require 7dtd-apm.
6. **Instrument hot paths** (net, sim, interest, chunk stream) with `apm` as they land.
7. **No em dashes. No AI attribution** in commits, docs, comments, or PRs.
8. Prefer **SoA + serialize-once interest** over stock Mono shapes.
9. **Server owns missing features.** Stock-client playability gaps (chunks, deco,
   signs, inv direction, spawn/UI unlock, entity state) are fixed **here** with
   correct wire and sim. Never teach `7dtd-connect` or any client mod to invent
   world data, skip server-driven steps, or suppress protocol errors. Client
   tooling stays join/automation only. Workspace rule 10.
10. **Proper stock fidelity.** Prefer **missing** over fake content (no invented
    terrain shells, fake FX, or incomplete journal blobs that fail stock `Read`).
11. **Name for what it does.** A flag that only throttles streaming is not
    `world_enabled`. Confusing names are defects.
12. **One stock package shape → one builder.** No second "almost stock" encoder.
13. **Do not hardcode game asset data.** Full policy: [`docs/ASSETS.md`](docs/ASSETS.md).
    Anything stock ships in `Data/Config`, prefabs, DTM, TTS, XML catalogs, or
    other install files must be **read from those assets** (runtime via
    `game-dir` / `assets/*`, or **comptime** embed/parse that generates tables).
    Rules of thumb:
    - **Block/item wire ids** = AssignIds dump (`idByName`) only. Never sequential
      XML declaration order, never invent parallel id spaces.
    - **Properties** (MaxDamage, Texture, Class, stack, HP, prices) from the
      matching XML after name resolve.
    - **Biomemap colors/layers** from `biomes.xml`, not RGB switch tables.
    - **Fail closed:** missing name → omit / not placeable / skip deco object.
      Wrong id is worse than missing.
    - **Fixtures** under `assets/fixtures/` are offline tests only.
    - **OK hardcodes:** wire layout RE constants, Unity hashes computed from
      stock **names**, ConfigFile LoadLocal name list (protocol).
14. **RE before inventing wire.** Package field order, types, lengths, and join
    sequence come from `../7dtd-research/docs`, loadgen goldens, or verified stock
    `Read`/`Write`. Do not guess layouts from "what seems right." If RE and
    code disagree, fix the code (or update RE with evidence), not the client.
15. **Server is authoritative.** World blocks, inventory, TE contents, entity
    HP/alive, quests, locks, and time are owned by sim. C2S is a request:
    validate (bounds, ownership, join phase, rates), apply or reject, then
    broadcast the **resulting** state. Never apply client-supplied world/inv
    blobs blindly; never let C2S overwrite another player's slots or distant
    chunks without a stock-legal path.
16. **Join and channel phase gates.** Only accept packages legal for the peer's
    current SM state (challenge → ids → login → enter → spawn → playing).
    Drop or disconnect illegal early/late C2S. Do not send play-world packages
    before the client is ready for them per stock order.
17. **Interest and no self-echo.** Entity/chunk/TE/stream updates go to peers
    that should observe them. Do not echo a player's own movement or redundant
    full state to themselves unless stock does. Serialize-once per tick where
    the interest path already does.
18. **Bounds and caps everywhere untrusted or hot.** C2S coords, slot indices,
    counts, string lengths, and fragment sizes are range-checked. Streaming
    queues (chunks, deco, entity spawn) stay under named caps so one peer
    cannot stall the 50 ms tick or OOM the process.
19. **Persist through the store.** Block/TE/player mutations that must survive
    restart go through `world/*` / save paths (e.g. ZCH3 `.zch`, player data), not
    only in-memory interest caches. A green join test is not proof of persist.
20. **Deterministic sim inputs.** Tick order for systems that touch the same
    data is stable. RNG for loot/AI/director uses explicit seeded state, not
    ad-hoc `std.crypto` or time-based noise on the sim path. Same seed + inputs
    → same outcomes in tests where we claim that.
21. **Stock hashes and type ids.** Unity/string hashes, AssignIds class ids, and
    item/block type ids follow stock formulas or loaded tables. Do not invent
    parallel id spaces that diverge from what the client resolves.
22. **Fail closed on encode.** If a body cannot be built correctly (missing
    catalog entry, buffer too small, unknown TE type), omit or send the stock
    empty/error form. Never truncate mid-field, pad with zeros to a guessed
    size, or send a partial blob that desyncs `BinaryReader`.
23. **Keep `make check` green.** No "fix later," no skipped assertions to land a
    feature. New wire/sim behavior gets a unit or `scenarios.zig` test when
    the path is non-trivial; join/spawn/chunk/inv changes need loadgen smoke
    when practical.
24. **Stdlib abstractions, not OS-specific guts. No raw syscalls in new or
    touched code.** Prefer the highest stable Zig 0.16 API that fits:
    `std.Io` / `Dir` / `File` / `Threaded`, `std.mem`, `std.fmt`, `std.Thread`
    (via `util/parallel`), etc. Zig does not use OOP abstract classes; **stdlib
    interfaces** (`std.Io` vtable) and thin helpers on top (`util/io_fs.zig`) are
    the idiomatic layer. Do **not** open-code `std.os.linux.*`, raw `std.posix`
    file loops, or `std.c` for ordinary FS. Ordinary FS is `util/io_fs` /
    `std.Io` only. LiteNet/UDP batch and admin/GSI TCP sockets remain **legacy**
    `std.os.linux` until a deliberate net migration. Shelling out remains
    forbidden when an in-process API exists (workspace Native APIs rule). Follow
    [Zig Zen](https://ziglang.org/documentation/master/#Zen) when choosing among
    correct options.

## Commands

```bash
zig build              # Debug binary → zig-out/bin/zdtd
zig build test         # unit + scenario tests (must stay green)
zig build run
make check             # version/toolchain pin + build + test + fuzz + lint
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
# LiteNet is ServerPort+2 (example: zdtd --port 27002 → loadgen --port 27004)

# Metrics: zdtd text/JSON snapshot (docs/APM.md), not 7dtd-apm sessions
```

Playability evidence for join/spawn/chunk/inv changes: loadgen smoke **and**
stock client (EAC off) when practical. Unit green alone is not enough.

## Layout

```text
src/main.zig           CLI, DebugAllocator, construct Game, run loop
src/protocol.zig       wire constants (challenge, tick rate; package ids live in wire/)
src/server/game.zig    join SM, tick orchestration, interest, send path
src/server/*           admin TCP, GSI, config, multi-system scenarios
src/ecs/*              SoA world, systems, inventory, quests, interest
src/world/*            chunks, TTS, prefabs, sleepers, containers, DTM, biomes
src/wire/*             package bodies (stock_*), binary LE, frames
src/litenet/*          LiteNet framing, peers, linux UDP
src/assets/*           blocks/items/recipes/loot/quests/entities XML tables
src/apm/*              counters, section timers, dumps (not 7dtd-apm)
src/util/parallel.zig  optional range split (AI, turrets, chunk save)
assets/fixtures/       offline XML for tests
tests/                 extra fixtures / harnesses when present
docs/                  STATUS, gaps, plan, APM, wire/map/system notes
worlds/                local save overlays (ZCH3 `.zch`, player data)
```

| Concern | Lives in | Does not live in |
|---|---|---|
| Stock package body layout | `wire/stock_*.zig`, `packages.zig` | `game.zig` open-coded writes |
| Block/world mutation | `world/*`, `ecs` | LiteNet / package id tables |
| Syscalls / sockets | `litenet/linux_udp.zig`, GSI/admin TCP | package builders, ECS systems |
| XML / config load | `assets/*`, `server/config.zig` | tick path |
| Metrics | `apm/*` via `Game.harness` | 7dtd-apm bridge |

- Import **facades** when they exist: `*/root.zig` per package (`util`, `apm`,
  `litenet`, `wire`, `assets`, `ecs`, `world`, `server`) and `wire/packages.zig`
  for stock body modules. Leaf files stay importable. Avoid cycles; world must
  not import wire (TE domain types live in world, wire re-exports as needed).
- `pub` only for intended API. Helpers stay file-private by default.

## Docs map

Full index: [`docs/INDEX.md`](docs/INDEX.md). **STATUS wins** if inventory docs lag.

| Doc | Role |
|---|---|
| [`docs/STATUS.md`](docs/STATUS.md) | What works now (gates + shipped surface) |
| [`TODO.md`](TODO.md) | Open backlog (shipped log below the fold) |
| [`docs/MISSING_FEATURES.md`](docs/MISSING_FEATURES.md) | Full gap inventory vs stock |
| [`docs/IMPLEMENTATION_PLAN.md`](docs/IMPLEMENTATION_PLAN.md) | Phased plan (M7+; post-playable stack) |
| [`docs/AUTHORITY.md`](docs/AUTHORITY.md) | Server-authoritative C2S gates + mode |
| [`docs/APM.md`](docs/APM.md) | Native metrics harness |
| [`docs/PACKAGES.md`](docs/PACKAGES.md) / [`docs/GAME_OPTIONS.md`](docs/GAME_OPTIONS.md) | Package catalog / serverconfig |
| [`docs/ECS.md`](docs/ECS.md) / [`docs/SYSTEMS.md`](docs/SYSTEMS.md) | Sim architecture |
| [`docs/SCALE_ARCHITECTURE.md`](docs/SCALE_ARCHITECTURE.md) / [`docs/PLANET_SCALE.md`](docs/PLANET_SCALE.md) | Scale (parked until M11) |
| [`../7dtd-research/docs/protocol.md`](../7dtd-research/docs/protocol.md) | Envelope, join, goldens |

Architecture and RE narratives stay under `../7dtd-research/docs`. Feature status and
playability live in this tree (`STATUS` / `TODO` / gaps). Update those when the
wire or play surface changes.

---

## Zig style

Zig **0.16**. Shaped by client-wire fidelity, 20 TPS, SoA sim, and loadgen /
stock-client evidence. Naming/memory habits follow usual Zig house style
([agave](https://github.com/maci0/agave/blob/main/AGENTS.md) is one reference);
the rest is dedi-rewrite specific.

### Naming

| Kind | Style | Example |
|---|---|---|
| Functions / methods | `camelCase` | `buildPlayerIdBody`, `setBlockWorld`, `sendJoinBundle` |
| Variables / fields / params | `snake_case` | `entity_id`, `world_dir`, `body_buf`, `view_radius` |
| Types | `PascalCase` | `Game`, `World`, `PackageName`, `StockSlot` |
| Files | `snake_case.zig` | `stock_quest.zig`, `linux_udp.zig` |
| Constants | `snake_case` module `const` | `max_streamed_chunks`, `pending_cap` |
| Stock type / package names | Match TFP strings | `NetPackagePlayerId`, `PackageName` cases |

**No magic numbers** on wire or tick paths. Package field sizes, AssignIds /
mapping captures, bit masks, buffer caps, and RE version pins are named module
`const` (often next to a one-line RE comment or path into `../7dtd-research/docs`).

### Wire and packages

- Bodies go into a **caller buffer** (`Game.body_buf`, stack `[N]u8` in tests):
  `buildXxxBody(buf, …) ![]u8`. Prefer that over allocating a slice per send.
- Use `wire/binary.zig` (`Reader` / writers) for .NET BinaryReader/Writer:
  little-endian ints, 7-bit string lengths. No second endian path.
- Resolve package ids through the negotiated map (`PackageIds` /
  `default_mappings` in fixtures).
- Document non-obvious field order next to the writes (RE / stock `Read` order).
- Incomplete packages that fail stock `Read` must not be sent "to look busy."
  Correct empty / omit beats a fake body. Server owns gaps; do not paper over
  in clients.

### Memory

- Root: `DebugAllocator` in `main`, pass `allocator` into `Game` and long-lived
  stores. No global allocator for sim/wire.
- Allocators are explicit: `std.mem.Allocator` or caller-owned buffers.
  `defer deinit` immediately after acquire; `errdefer` for error-only paths.
- **Hot path: no heap allocation.** Tick, per-packet C2S/S2C, interest/
  replicate, chunk stream encode, and ECS systems must not `alloc` / `create` /
  `dupe` / `allocPrint`, must not grow `ArrayList`/`HashMap`, and must not
  spin up arenas. Reuse `recv_buf` / `send_buf` / `body_buf`, fixed client
  slots, SoA columns, pools, and stack/`bufPrint` scratch. At cap: drop or
  omit (named const), do not realloc.
- Init/load/admin may allocate (maps, TTS cache, XML, prefabs, first-touch
  chunk **slot** fill into pre-reserved storage). Cache by stable keys; never
  re-parse XML every tick.
- `page_allocator` is not for tick or package work. Tests use
  `std.testing.allocator` (or `DebugAllocator`) so leaks fail CI.
- Review prompts: [`docs/PROMPTS/review-zig-idiomatic.md`](docs/PROMPTS/review-zig-idiomatic.md)
  (language/hot path), [`docs/PROMPTS/review-abstractions.md`](docs/PROMPTS/review-abstractions.md)
  (when to build or delete helpers/layers),
  [`docs/PROMPTS/review-simd.md`](docs/PROMPTS/review-simd.md) (SIMD on dense loops).

### Tick path (20 TPS / 50 ms)

Main sim + net loop is effectively single-threaded for game rules.

- **No heap allocation** (see Memory). No unbounded growth.
- No new threads per tick (`util/parallel` pool only).
- Syscalls stay on the existing poll / `recv` / `sendto` batch path (LiteNet +
  GSI). No open files or XML re-read mid-tick.
- Optional parallelism only via `util/parallel.zig`, never ad-hoc
  `std.Thread.spawn` in package builders or join SM.
- New cost on net/sim/interest/chunk stream: `apm` sections/counters. Judge
  regressions from **zdtd** dumps, not 7dtd-apm.

Init, map load, and admin commands may take longer; amortize into caches.

### Comptime and Zig 0.16

- `comptime` for closed sets (package enum maps, bit layouts, small parsers).
  `inline` only for tiny hot helpers, not large builders.
- Prefer `@memcpy` / `@memset`, `@bitCast` / `@intCast` / `@truncate`,
  `@min` / `@max` over open-coded bulk loops when clear.
- `ArrayList`: `.empty`, pass allocator into methods (`append(allocator, v)`).
- Prefer `@Int` / `@Enum` / `@Struct` / `@Union` over removed `@Type()`.
- `main` takes `std.process.Init.Minimal` (or full `Init`); thread allocator
  from there. No pre-0.16 compat shims.
- Build logic in `build.zig` / `build.zig.zon`. `Debug` for safety;
  `ReleaseFast` for soak. Thin Makefile is fine; do not hide the real build
  only in Make.

### Filesystem and I/O (Zig 0.16)

- **Default:** `std.Io.Threaded` (or the process Io) + `std.Io.Dir` / `File`.
  Examples: `Dir.cwd().writeFile(io, .{ .sub_path, .data })`,
  `Dir.cwd().openDir(io, path, .{ .iterate = true })`, `createDirPath`,
  `openFile` + read helpers.
- Shared helpers: `src/util/io_fs.zig` (mkdir/write/read/list via `std.Io` only).
- Config load + `--config-overrides` go through `assets/paths.zig` + `io_fs`,
  never raw open/getdents.
- **Forbidden in new code:** `std.os.linux.*` for ordinary files, ad-hoc
  `posix`/`std.c` file loops, `/tmp` for large caches (use project or `~/.cache`).
- **Layering:** app → `io_fs` (optional) → `std.Io` → (std internals). Do not
  skip to the bottom from game/assets/world code.
- **UDP/LiteNet:** keep the existing batched socket path until a deliberate
  migration; do not invent a second raw-syscall net stack. New net features
  prefer std abstractions where they fit.

### Zig Zen (tie-break)

When two approaches are correct, pick the one that matches
[Zig Zen](https://ziglang.org/documentation/master/#Zen): precise intent, edge
cases, readable code, one obvious way, fail at compile time when possible,
incremental migration off legacy I/O, **memory is a resource** (no hot-path
heap), dealloc always succeeds (`defer`). Full review rubric:
[`docs/PROMPTS/review-zig-idiomatic.md`](docs/PROMPTS/review-zig-idiomatic.md).

### Errors and safety

- Explicit error sets + `try` / `catch`. Empty `catch {}` only for true
  best-effort shutdown or a documented non-fatal RE fallback (comment why).
  Never `catch undefined`.
- `std.debug.assert` for internal invariants (slot bounds, buffer caps,
  streamed_n ranges).
- Malformed client packets: reject / drop / disconnect per join SM policy; do
  not crash the whole process on one bad peer when avoidable.

### Documentation in code

- File-level `//!`: purpose and non-goals.
- Public APIs: `///` with ownership (who frees / whose buffer) and non-obvious
  errors.
- Do **not** add narrating comments on obvious code. RE/layout comments on wire
  fields are welcome.

### Testing and evidence

- Unit `test` blocks at the **bottom** of the file that owns the logic.
- Multi-system join / inventory / chunk paths: `server/scenarios.zig` (extend
  it) rather than duplicating harnesses.
- Wire: golden layout tests (sizes, markers, known fixture mappings). Builders
  the stock client will `Read` need tests or an explicit join-path scenario.
- `zig build test` must stay green. Touching listen/join: loadgen smoke when
  practical.

### Anti-patterns

- Hard-coded package ids as "forever true" outside fixture maps
- Hand-copied block/item/recipe/entity/loot tables that stock ships as assets
  (load or comptime-generate from game files instead)
- Guessed package layouts or join order without RE / golden evidence
- Trusting C2S coords, inv blobs, or damage without validation
- Sending play packages before join SM allows them; accepting illegal phase C2S
- Self-echo of movement / full state the stock server would not send
- Unbounded chunk/entity/stream queues or unchecked slot/coord indices
- In-memory-only world edits that should hit ZCH3 `.zch` / player save
- Unseeded or hidden RNG on loot/AI/director tick paths
- Invented type-id or hash spaces parallel to stock catalogs
- Truncated or zero-padded wire bodies when encode fails
- Second encoder for the same stock package shape
- `catch {}` on encode/decode without intentional drop + comment
- Fake world/FX/journal content to silence client errors
- Game assemblies or bulk IL committed here
- Heap alloc / `dupe` / `allocPrint` / growing `ArrayList`/`HashMap` on tick or
  per-packet encode/interest/stream paths
- `page_allocator` on the tick path
- Syscalls or XML parse inside package body builders
- Raw `std.os.linux` / open-coded posix FS for ordinary files (use `std.Io` / `io_fs`)
- Names broader or opposite to the real control
- Manual cleanup in `catch` when `defer` / `errdefer` suffices
- Wiring 7dtd-apm, Harmony, or ModAPI into this process
- Client Harmony that invents S2C data zdtd should send
- Skipping or weakening tests to land a change
- Skipping STATUS/TODO updates when playability or wire surface changes

### Review checklist (Zig changes)

- [ ] Code sits in the correct layer (table above)
- [ ] Naming matches table; new wire/tick constants are named
- [ ] Allocators explicit; `defer` / `errdefer`
- [ ] Hot path: no heap alloc / no growing lists; caller buffers + named caps
- [ ] FS/I/O via `std.Io` / `io_fs` (no new raw linux/posix file syscalls)
- [ ] Package body uses `binary` + buffer builder; ids via map
- [ ] Layout matches RE or has a unit / scenario test
- [ ] No incomplete stock packages sent; missing preferred over fake
- [ ] Game asset data loaded or comptime-generated from install/fixtures, not hand-copied
- [ ] C2S validated (phase, bounds, ownership); server applies results, not blobs
- [ ] Interest correct; no bogus self-echo; stream caps named and enforced
- [ ] Persist path used when the mutation must survive restart
- [ ] Encode failure omits or uses stock empty form (no truncate/zero-pad guess)
- [ ] Errors propagated or deliberately ignored with comment
- [ ] Material net/sim cost has `apm` instrumentation when warranted
- [ ] `make check` / `zig build test` green; join/spawn/chunk/inv → loadgen when possible
- [ ] STATUS/TODO updated if feature surface or playability changed

## Stock-game research -> 7dtd-research

Anything that studies the **stock** dedicated server belongs in
[`../7dtd-research/`](../7dtd-research/), not here: reverse-engineering
narratives (`docs/`), the Mono.Cecil dump tooling (`tools/`), wire/protocol
analysis, and engine cost/loop RE. This repo owns the Zig dedicated reimplementation;
it does not host stock-game RE docs or dumpers. When RE is needed, add it
under `../7dtd-research/` and link back. How to RE:
[`../7dtd-research/docs/re-methodology.md`](../7dtd-research/docs/re-methodology.md).
