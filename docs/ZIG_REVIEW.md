# Zig idiomatic review (zdtd)

| | |
|---|---|
| Date | 2026-08-04 |
| Mode | Fix P0/P1 |
| Scope | `src/server`, `src/world`, `src/assets`, `src/util`, `src/ecs` (sample hot paths) |
| Prompt | `docs/prompts/zig-idiomatic-review.md` |

## Pass 2026-08-06 (follow-up)

| | |
|---|---|
| Date | 2026-08-06 |
| Mode | Review + fix P0/P1 |
| Scope | `src/plugin/wasm.zig` (Wasm runtime, new), `src/world/weather.zig` encode/decode (new), `src/server/game.zig` wasm wiring + saveWeather/restoreWeather, plus codebase re-scan of the search recipes |
| Result | No P0/P1 found in the new code; re-scan of the hot-path recipes found no new violations. Prior pass debt unchanged (see fix plan below) |

### New-code review (T9 wasm + storm persistence)

| Location | Issue | Verdict |
|---|---|---|
| `src/plugin/wasm.zig` `callHook`/`callPlayerJoin`/`WasmHost.onTick` | Tick path: no heap, no grow; disabled flag short-circuits before the call | Clean |
| `src/plugin/wasm.zig` `Plugin.load` | Init path: `errdefer` ladder (engine create/deinit, name dupe) disarms on success | Clean |
| `src/plugin/wasm.zig` `defineImports` | Host fns copy via `Caller.memory().sliceAt` (bounds-checked, no alloc) | Clean |
| `src/server/game.zig` `parsePluginCommand` | Tick path: `tokenizeScalar` + `parseFloat`/`parseInt`, 128-byte cap, no alloc | Clean |
| `src/world/weather.zig` `encode` | Fixed offsets + little-endian writes; caller buffer (1024 B), `BufferTooSmall` on overflow | Clean |
| `src/world/weather.zig` `decode` | Fail-closed: magic, length, bounds, biome id + group index vs table, finite params; manager untouched on reject | Clean |
| `src/server/game.zig` `saveWeather`/`restoreWeather` | Init/save paths only; `io_fs.readFileInto` into a stack buffer; oversize file truncates and decode rejects (fail closed) | Clean |
| `src/world/weather.zig` encode field offsets | Offset arithmetic (o+5/13/21/29) is a P3 footgun if `BiomeState` grows; the round-trip test covers every current field, so not worth churn now | P3, tracked |

### Re-scan results (2026-08-06)

| Recipe | Result |
|---|---|
| `allocator.alloc/create/dupe/realloc` on tick | None in game/ecs/wire tick path; chunk store allocs are load/first-touch (documented) |
| `page_allocator` | `src/world/store.zig:761,819` only, documented parallel-worker choice; not on the tick |
| `catch {}` / `catch unreachable` | `fuzz.zig` (test harness) + documented best-effort paths (parallel yield, tcp poll, litenet reject send) |
| `Thread.spawn` | Only `util/parallel.zig` (persistent pool) and `world/chunk_flush.zig` (single writer thread); documented |
| `std.os.linux.*` / raw posix FS | None outside the documented LiteNet/`tcp_listen`/clock layer |
| `inline fn` | Only tiny `apm/tracy.zig` wrappers (2-4 lines) |
| `anytype` public | `applyToInitOptions`/`sanitizeInitOptions` duck-type init merge, `xml_util.putDupeKey`, `powerblocks.build`; all documented |
| Pre-0.16 `ArrayList` style | None; all `.empty` + explicit allocator |
| `/tmp` for caches | None |

### Ordered fix plan (carried from the 2026-08-04 pass, still open)

1. Migrate admin telnet + GameServerInfo TCP to `std.Io` / `std.net` when next touched.
2. Comment or split remaining tick-path `catch {}` on broadcast (group helper with documented drop policy).
3. ~~Cap / pre-reserve `ecs.net_to_slot` HashMap at `ensureNetMap`~~ **Done**: `ensureTotalCapacity(max_entities)` (world.zig:213).
4. Optional: long-lived `std.Io.Threaded` on `Game` to avoid Threaded init per persist call (P2 perf).
5. P2 naming / god-file split of `game.zig` (out of scope).
6. `weather.zig` encode offsets: promote to named `const` if `BiomeState` gains a field (P3).

### Zen notes (2026-08-06)

- Memory is a resource: the wasm plugin queue rides the fixed 64-slot command buffer; the storm save rides a caller stack buffer.
- Fail closed: plugin fuel/trap disables one module; weather decode rejects mismatched files instead of desyncing the client.
- One obvious way: text SimCommand grammar and the `ZWTH1` layout are each documented in one place.

## Summary counts

| Sev | Found | Fixed this pass | Remaining |
|---|---|---|---|
| P0 | 1 | 1 | 0 |
| P1 | 18 | 16 | 2 (documented debt) |
| P2 | 12 | 0 | 12 |
| P3 | several | 0 | nits |

## P0 / P1 findings and fixes

| Location | Issue | Fix | Sev |
|---|---|---|---|
| `src/server/game.zig` land_claims | `ArrayList.append` on place path (may grow heap) | Fixed array `max_land_claims` + drop at cap | P0 |
| `src/world/store.zig` | Raw `linux.open/read/write/mkdir` for `.zch` | Already on `io_fs` (verified) | P1 |
| `src/world/containers.zig` | Raw linux save/load | Already on `io_fs` (verified) | P1 |
| `src/server/game.zig` savePlayers / tryRestorePlayer | Raw linux FD I/O | Buffer + `io_fs.readFileInto` / `writeFile` | P1 |
| `src/server/game.zig` saveBlockMeta / loadBlockMeta | Raw linux FD I/O | Buffer + `io_fs` | P1 |
| `src/server/game.zig` seedChestBlockId | Raw linux open/read | `io_fs.readFileInto` | P1 |
| `src/world/prefabs.zig` | linux TTS size + test mkdir/write | `io_fs` | P1 |
| `src/world/dtm.zig` | linux fileExists | `io_fs.fileExistsSimple` | P1 |
| `src/world/water.zig` | linux mkdir/write helpers | Removed (tests use io_fs path) | P1 |
| `src/world/biomes.zig` `tts` `blocks_nim` tests | linux open skip | `io_fs.fileExistsSimple` | P1 |
| `src/world/dem.zig` tile cache + test | linux open/read/write | `io_fs` | P1 |
| `src/assets/assignids_comptime.zig` | linux read dump | `io_fs.readFileAll` | P1 |
| `src/assets/maxdamage.zig` readlink | `linux.readlink` | `io_fs.readLinkAbsoluteSimple` | P1 |
| `src/server/config.zig` tests | linux mkdir/open/write | `io_fs.mkdirPathSimple` / `writeFileSimple` | P1 |
| `src/server/scenarios.zig` | linux unlink/mkdir | Already on `io_fs` (verified) | P1 |
| `src/util/io_fs.zig` | Incomplete helper surface | Added readInto, delete, readLink, dirExists, Simple variants | P1 |
| `src/ecs/world.zig` registerNet | bare `catch {}` | Comment: map OOM, SoA fallback | P1 |
| `src/server/game.zig` pollNetOnce | bare catch on peer handlers | Comment: one bad peer must not stop poll | P1 |
| Tick broadcast/save `catch {}` | Many best-effort drops | Comments on init/shutdown; rest intentional drop | P1→debt |
| LiteNet / admin TCP / clock | `std.Io.net` / `tcp_listen` / thin posix clock | **Done** (see STD_ABSTRACTIONS) | - |

## Hot-path memory

| Check | Result |
|---|---|
| `page_allocator` on tick | None in game/ecs/wire tick path. `io_fs.*Simple` and `parallel` use page_allocator for short-lived `Threaded` only (init/load/admin). |
| Interest / stream encode alloc | No new heap on encode; `body_buf` / fixed scratch used. |
| Growing lists on tick | **Fixed:** `land_claims` no longer `ArrayList`. Prefab sleeper `ArrayList` remains **init-only** (Game.create). |
| Chunk first-touch alloc | Init/load gray area: `ensureBlocks` still allocates column storage into reserved chunk slots (documented OK). |

## Comptime / inline / anytype

| Kind | Notes |
|---|---|
| Good | Package name maps, AssignIds pins, small `inline for` on wire field packs |
| No P1 inline abuse found | Large builders are not `inline` |
| anytype | Limited to table duck-types (e.g. TE body resolve); no public soup |

## I/O debt (legacy vs fixed)

| Area | Status |
|---|---|
| `util/io_fs.zig` | Canonical one-shot FS |
| `world/*` asset/map load | Migrated off raw linux |
| `assets/*` | Migrated (assignids, maxdamage readlink) |
| `server/game.zig` player/blockmeta persist | Migrated |
| `litenet/udp_socket` | **Done** via `std.Io.net` |
| `server/admin.zig`, GSI, webui | **Done** via `util/tcp_listen` |
| `util/clock` / apm timing | `posix.system.clock_gettime` (vDSO; intentional) |
| `game.zig` test peer attach | LiteNet peer tests use net address types |
| `linux_fs` module | **Absent** (removed / never present) |

## Ordered fix plan (remaining)

1. Migrate admin telnet + GameServerInfo TCP to `std.Io` / `std.net` when next touched.
2. Comment or split remaining tick-path `catch {}` on broadcast (group helper with documented drop policy).
3. Cap / pre-reserve `ecs.net_to_slot` HashMap at `ensureNetMap` with `ensureTotalCapacity(max_entities)`.
4. Optional: long-lived `std.Io.Threaded` on `Game` to avoid Threaded init per persist call (P2 perf).
5. P2 naming / god-file split of `game.zig` (out of scope).

## Zen notes

- One FS way: `io_fs` / `std.Io` (rule 24).
- Memory is a resource: land claims fixed cap, no tick ArrayList grow.
- Incremental: LiteNet left alone; world/assets/server persist moved aggressively.

## Test status

See chat summary after `make check`.
