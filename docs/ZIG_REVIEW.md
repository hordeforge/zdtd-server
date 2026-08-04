# Zig idiomatic review (zdtd)

| | |
|---|---|
| Date | 2026-08-04 |
| Mode | Fix P0/P1 |
| Scope | `src/server`, `src/world`, `src/assets`, `src/util`, `src/ecs` (sample hot paths) |
| Prompt | `docs/PROMPTS/review-zig-idiomatic.md` |

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
