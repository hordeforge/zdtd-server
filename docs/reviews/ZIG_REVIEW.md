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

### 2026-08-06 feature-wave review (chunk / quest / loot / ZPV3 / trader)

| | |
|---|---|
| Date | 2026-08-06 |
| Mode | Review + targeted fixes |
| Scope | `src/wire/stock_chunk.zig` (raw-plane memoization, water/density/texture channels, `rawAt`), `src/world/store.zig` `applyWaterSources`, `src/assets/items.zig` (Stacknumber Extends resolve), `src/assets/quests.zig` (template resolution, `parseQuestDefBody`, `sumCoinReward`), `src/ecs/quest.zig` (`ObjectiveWireKind`), `src/ecs/world.zig` (loot_drop_prob gate), `src/assets/maxdamage.zig` (`loot_list_by_name/by_id`, `resolveLootList`), `src/server/game.zig` (ZPV3 save/restore, NPCQuestList `remove_quest`, trader `LockResponse`), `src/assets/entities.zig` (`defaultTrader`, `LootDropProb`), `src/server/zdtd_config.zig` (`[sim] trader_wallet_dukes`) |

#### Verdicts

| Location | Issue | Verdict | Sev |
|---|---|---|---|
| `stock_chunk.zig` `encodeNetworkChunk` + memo | `raws_scratch` is a caller-owned `Game.chunk_raws` field; plane filled once, layers/density/water read it. No heap on the stream path; stack arrays only | Clean | - |
| `stock_chunk.zig` `writeWaterChannel` / `writeDensityChannel` / `writeTextureChannel` | SIMD uniform/pack helpers + scalar tails; stack `[1024]` buffers; named consts for layout | Clean | - |
| `stock_chunk.zig` `buildNetPackageChunkNew` | `buf.len < 16` pre-check plus a post-encode `total > buf.len` check that can never fire after a successful encode (writer already bounds-checks) | Redundant guard, harmless | P3 |
| `stock_chunk.zig` `density_nontarrain` | Typo in a `pub const` name | **Fixed**: renamed `density_nonterrain` (no in-tree usages) | P3 |
| `store.zig` `applyWaterSources` | Pure in-chunk fill, no alloc, bounds-checked `y < y_dim`; init/first-touch path | Clean | - |
| `items.zig` Extends resolve pass | Two-pass name maps + `max_hops` cap; init/load only, arena keys; child-before-parent handled | Clean | - |
| `quests.zig` template resolution + `parseQuestDefBody` + `sumCoinReward` | `resolveBody` depth-capped (8); deterministic FNV scatter for goto coords; `reward_coin` fails closed to 0; all init path with `errdefer` arena | Clean | - |
| `ecs/quest.zig` `ObjectiveWireKind` | Plain wire mirror enum with doc; exhaustive use in the quest builder | Clean | - |
| `ecs/world.zig` loot gate | Deterministic per-entity roll (net id hash), no RNG; bounded `% 1000` math | Clean | - |
| `entities.zig` `LootDropProb` parse | Unclamped; a modded negative value panics at the first kill (`@intFromFloat` to u64 in the damage path) | **Fixed**: clamp to `[0,1]`, out-of-range fails closed to 1.0 | P2 |
| `maxdamage.zig` `loot_list_by_name/by_id` + `resolveLootList` | Hop-capped Extends walk; id merge in the dump pass; `lootListFor` walks the name table only on by_id miss | Clean | - |
| `game.zig` `savePlayers` | Writes a `ZPV3` header while copying legacy `ZPV2` records verbatim (no prog tail); the next merge pass misparses the tail-less records under v3 semantics and corrupts the file | **Fixed**: append a `prog=0` tail when upgrading a v2 record | P1 |
| `game.zig` `tryRestorePlayer` | Non-matching `ZPV3` records are skipped without consuming the progression tail, misaligning the scan; restoring any player after another player's record fails or corrupts | **Fixed**: `rec_start` + `zpvRecordLen` skip on non-match; regression test added (`players zpv3 restore skips a preceding record's progression tail`) | P1 |
| `game.zig` NPCQuestList `remove_quest` + trader `LockResponse` | Index-capped offer scan; `body_buf`-built responses; trader context carries `trader_wallet_dukes` | Clean | - |
| `zdtd_config.zig` `[sim] trader_wallet_dukes` | Parses, merges, clamps negative to 0 with a log (tested) | Clean | - |

#### Test status (this scope)

- `zig build test` green on the main tree (784 tests, runner seed).
- The regression test fails against the pre-fix restore scan (verified by temporary revert: restore bails with `truncated inventory at record 1/2`).
- Note: `scenario inventory move drop place equip` (scenarios.zig:1041, armor mitigation `>= 0.09`) fails in direct binary runs at HEAD with and without this pass's changes (passes under the build-runner seed); pre-existing at HEAD, in the scenarios/plugin area owned by the parallel agent's pass.

### 2026-08-07 scope review (restock cadence / quest POI binding / tick cadences / loot fail-closed)

| | |
|---|---|
| Date | 2026-08-07 |
| Mode | Review only (no fixes applied) |
| Scope | Commits `f35ada0` (per-trader restock cadence), `7d48944` (A22 block-id coverage guard test), `df7cf5a` (A31 loot fail-closed), `fe546fb` (B26 quest POI binding), `8014945` + `ac7aca2` (B13 tick cadences) |
| Result | No P0/P1. Three P2 (all narrow). No hot-path allocations found |
| Line numbers | Committed HEAD (`git show HEAD:<path>`), not the working tree, which carries a parallel agent's in-flight edits in `game.zig` and `zdtd_config.zig` |

#### Verdicts

| Location | Issue | Idiomatic fix | Sev |
|---|---|---|---|
| `src/ecs/systems.zig:563-569` | `questTickGoto` applies the new POI-center target (`gx/gz`) to `fetch_trader` phase-1 quests as well as POI-goto kinds. `s.poi` binds at accept for **every** kind (`poiAt(d.tx, d.tz)`, pre-existing), so a fetch_trader def whose position sits inside a prefab now bumps phase-1 only near that POI's center, which can be far from the trader NPC the client's `go_to_trader` marker points at. `sendQuestNavObjects` (`use_def_pos`) and PositionData (`goto_point` only) scope POI-center use correctly; this branch does not. No test covers fetch_trader with a bound poi (the phase-graph tests never wire `poi_fn`) | Gate `gx/gz` on `d.kind == .goto_point` in the phase-1 branch and keep `d.tx/d.tz` for `fetch_trader`; add a test with `w.poi_fn` wired that accepts a fetch_trader quest and completes phase 1 at the trader position | P2 |
| `src/server/game.zig:10419-10421` | `tickWorkstations(0.5)` keeps the hardcoded 2 Hz dt while the gate cadence is now configurable: setting `sleeper_tick_ticks` away from 10 decouples burn rate from wall time (20 ticks × 0.5 s = 2x burn) | `dt = @as(f32, @floatFromInt(self.sleeper_tick_ticks)) * 0.05` (0.05 s per 20 TPS tick), keeping the default 10 → 0.5 unchanged | P2 |
| `src/assets/maxdamage.zig:757-800` | A22 guard test hand-rolls line splitting + `startsWith` while `xml_util` already provides `stripComments` / `nextElement` / `attr`. The `startsWith(line, "<block name=")` prefix is attribute-order dependent (a row with another attribute first is silently skipped, weakening the guard), and the `<!--` check handles full-line comments only; a comment line containing `<block name=...>` could false-fail. Uses `io_fs.readFileAll` correctly (house abstraction, `SkipZigTest` on missing install) | Reuse `xml_util.stripComments` + `nextElement(..., "<block ", "</block>")` + `attr(body, "name")`, skipping rows where `attr(body, "shapes")` is present; matches the loader's own parser ("one obvious way") | P2 |
| `src/ecs/systems.zig:731` | `day < stock.last_restock_day + @as(u32, @intCast(stock.reset_interval))`: u32 `+` wraps at absurd day values (Debug trap, ReleaseFast wraps silently). The `@intCast` itself is guarded by the `reset_interval > 0` check, so it is safe. Unreachable in practice (4.29e9 in-game days) | `if (day -| stock.last_restock_day < @as(u32, @intCast(stock.reset_interval))) continue;` is overflow-free and reads as "days since last restock" | P3 |
| `src/server/game.zig:1816-1847` | `nearestPoiAtWorld` is an O(n) scan over the whole prefab index (1559 instances in Navezgane) at every quest accept. Call sites verified: accept (`systems.zig:336`) and save-restore (`game.zig:2581`) only; `questTickGoto` and `sendQuestNavObjects` never call it, so it is off the per-tick/per-packet path. ~30-60 µs per accept, fine under the 50 ms budget. Degenerate edge: `World.nearestPoi` filters `r.valid()` after selection, so a zero-XZ nearest prefab would null the whole call instead of the next-best rect (theoretical: `boundsXZ` is always positive for real prefabs) | Acceptable as-is; a load-time grid bucket over POI centers is YAGNI until accept volume grows. Optional: skip degenerate rects inside the scan loop | P3 |
| `src/server/zdtd_config.zig:381-395` | The three new zero-checks (`sleeper_tick_ticks`, `turret_sync_ticks`, `save_interval_ticks`) mirror the existing `motion_replicate_period_ticks` pattern exactly (0 → 1 with a log): consistent. Two gaps: no test zeroes the new keys, and `sanitizeInitOptions` runs only in `main` (`main.zig:606`), so a direct `InitOptions{... = 0}` into `Game.createWithOptions` reaches `% 0` on the tick path (pre-existing exposure shared by all period fields) | Add a zero-case assert for the new keys; optionally clamp/assert in `Game.createWithOptions` | P3 |
| `src/server/game.zig:9404, 9432, 9493` | Fail-closed loot: `if (ll) |ll|` at the two fill sites vs `orelse return` in `maybeRespawnContainer`. Both keep `touched_day` untouched on the fail-closed path (it is set only inside `fillContainerFromLoot`), matching the scenario expectation | Consistent and correct as-is; `orelse return` is the cleaner of the two forms | - |
| `src/server/scenarios.zig:2767-2788` | Loot-respawn scenario branches at runtime on whether the fixture block resolves a LootList (`has_loot_list`), so the fail-closed branch only runs in the builtin/offline environment and the refill branch only with stock data | Optional: a dedicated fixture block with no LootList to force the fail-closed branch deterministically | P3 |
| `src/ecs/world.zig:391-399`, `src/ecs/components.zig:544-556` | `nearestPoi` hook mirrors `poiAt`; `///` docs state null semantics and field names match the `poi_ctx`/`poi_fn` pattern. `TraderStock.reset_interval`/`last_restock_day` carry interval semantics and ownership of the math in docs | Clean | - |
| `src/server/game.zig:8652-8657` | `fillTraderFromXml` copies `ti.reset_interval` inside the `|ti|` branch (null-safe) and stamps `last_restock_day` at fill so a fresh window keeps its stock; comment explains the window | Clean | - |
| `src/ecs/aidirector.zig:231, 267` | `traderRestock` runs on the day-roll guard inside `Director.tick` (not per tick), fixed-size entity scan, no alloc; the change only added the per-trader gate | Clean | - |

#### Hot-path memory

None found. Verified call sites: `questTickGoto` runs per accepted move packet but reads the pre-bound `s.poi` (float math only, no `nearestPoi`, no alloc); `sendQuestNavObjects` is join/death-rebundle only and encodes into `body_buf`; `nearestPoiAtWorld` is accept-time and save-restore only; `lootListFor` is a read-only HashMap get on the by-id fast path (pre-existing cost on the chunk-stream container fill in `sendContainersInChunk`); `traderRestock` runs on day roll only.

#### Comptime / inline / anytype / I/O

- No new comptime, `inline`, or `anytype` surface in the reviewed commits.
- The A22 test reads via `io_fs.readFileAll`; no new raw FS or syscalls anywhere in scope. Test-only hardcodes (Steam path, `no_id` names) match the sibling `loadFromBlocksXml` tests' pattern (`SkipZigTest` on missing install).

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

## Pass 2026-08-08 (re-audit)

Re-ran the naming/import/0.16 scans on the parity-wave tree: clean. No
world → wire imports, no snake_case `pub fn`, no hungarian prefixes, no
misleading `*_enabled` flags, `@intFromFloat` uses are legitimate float→int
conversions, no `std.math.min/max` where builtins fit. game.zig continued
shrinking (5310 → 5115 at the wave head; loot/weather/vehicle shards).

## Pass 2026-08-20 (hot-path perf review, post config/plugin wave)

Reviewed the recently touched hot paths (plugin sense/verdict dispatch,
bot config reads, quest policy reads, `[rules.director]` reads, wasm sense
trailer building) against the 20 TPS / 50 ms budget + no-hot-path-heap
rule:

- **Allocations:** none on the tick path. Plugin load (Engine + name
  dupe) is init-only; `wasmSense` uses the existing 2048-byte stack
  scratch; the bot-info/damage-event trailer and `BotManager`/quest/
  director config reads are caller buffers and struct-field reads. No
  `ArrayList`/`alloc`/`create` in `step.zig`, `wasm_host.zig`, `bot.zig`,
  `plugin/wasm.zig` tick paths (grep-verified).
- **apm coverage:** tick_total, net_poll, sim_entities, chunk_stream,
  terrain_snap, save_io/save_encode all instrumented; the plugin on_tick
  dispatch sits inside the instrumented tick.
- **Measured** (loadgen 4 clients + `bot count 2` + bot + killfeed
  plugins, warm flat world, 30 actions): tick_total p50 393 µs, mean
  16.6 ms, p99/max spikes from the join-burst chunk stream (throttled)
  and idle poll-wait (net_poll max == tick_total max is the poll blocking,
  not work); sim_entities p50 196 µs. Budget 50 ms holds with >100x
  margin at steady state; no refactor warranted by the measured data.
