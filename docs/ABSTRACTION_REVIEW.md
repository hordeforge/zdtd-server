# Abstraction review (zdtd)

Scope: full tree under `src/` (util, wire, assets, world, server, ecs, litenet,
apm). Date: 2026-08-04 (baseline), 2026-08-06 (feature wave follow-up). Method:
`docs/prompts/abstractions-review.md` decision tree + scorecard. Complementary
to idiomatic Zig / `std.Io` migration.

## 2026-08-06 wave findings

Audited the 2026-08-06 feature wave (chunk raws memoization + water channel,
water sources, items/quests Extends, loot list tables, drop_prob, quest wire
kinds, ZPV3 save/restore, trader lock response, zdtd.toml [sim]) plus the
parallel-agent commits (8742721 storm persistence, 4ca2b3a/d4a2a77 stability
RE docs, 5ccd337 zig-idiomatic fixes). Review-only preferred; one P2 merge made
(quests.zig target extraction). Uncommitted `src/assets/maxdamage.zig`
(stability facts) left untouched per instruction.

| Name | Path | Verdict | Sev | Notes |
|---|---|---|---|---|
| `raws` plane memo (rawAt/raws_scratch) | `wire/stock_chunk.zig` | **keep** | - | Hot stream path; caller-owned fixed `[65536]u32` (`Game.chunk_raws`), no heap; callback fallback for tests is one encoder, one data source. Not a dual encoder |
| `writeWaterChannel` | `wire/stock_chunk.zig` | **keep** | - | Reads the memoized plane; same-value vs full-plane shape mirrors texture/density channels; band loop duplication across the three channels is wire-shape-specific, shared SIMD packs already extracted |
| `applyWaterSources` | `world/store.zig` | **keep** | - | Single water-fill path on the chunk materialize path; `world/water.zig Sources` is the domain type; no duplicate fill anywhere |
| `Sources.waterYNear` / `applyToChunkHeights` | `world/water.zig` | **keep** | - | Boundary helper, fail-closed (`?u8`) |
| `WeatherManager.encode/decode` | `world/weather.zig` | **keep** | - | Persistence format owned by the world layer, wire-free (no wire import); decode validates magic/bounds/biome/group against the seeding table and fails closed. Game only orchestrates save/restore |
| `items.zig` Stacknumber Extends resolve | `assets/items.zig` | **keep** | - | Two-pass own/ext maps, 24-hop cap, fail closed to stock 500; one authority |
| `resolveBody` (template) | `assets/quests.zig` | **keep** | - | Load-time concat, depth-capped, null → own body; recursive closure is the one obvious Zig shape |
| `parseQuestDefBody` | `assets/quests.zig` | **keep** | - | Named fn with explicit context; tests own the graph |
| `pickPrimaryKind` target extraction | `assets/quests.zig` | **merge** | P2 | Duplicated `objectiveTarget` rule (value/count/item_count). **Fixed:** now calls `objectiveTarget(body, oi, objectiveElementEnd(body, oi))` |
| `classifyObjective` vs `classifyPhaseKind` | `assets/quests.zig` | **keep split** | P2 | Different projections (primary meat kind vs per-phase advancing kind) onto different enums; string lists overlap but the mapping differs; a shared list constant adds indirection for little |
| `loot_list_by_name`/`by_id` + `lootListFor` | `assets/maxdamage.zig` | **keep** | - | Same by_name/by_id pattern as MaxDamage; `by_id` filled from the dump merge, name-table walk is a fail-closed fallback, not a second authority |
| `resolveLootList` / `resolveDecoFacts` | `assets/maxdamage.zig` | **keep** | - | Extends hop walk shared with distant/dim; uncommitted stability facts extend the same `DecoFacts` walk (left untouched) |
| Extends-walk pattern (3 resolvers) | items, maxdamage, quests | **keep** | P3 | Shared kernel is a ~6-line hop loop; a generic callback-based resolver would cost more than it saves. Extract only if a 4th resolver lands |
| `drop_prob` + LootDropProb clamp | `ecs/world.zig`, `assets/entities.zig` | **keep** | - | Plain data field; invariant clamped at load ([0,1], fail closed 1.0), sim roll is deterministic hash, no alloc |
| `ObjectiveWireKind` | `ecs/quest.zig` | **keep** | - | Wire shape kept in ecs deliberately; exhaustive `switch` at game.zig:7581 is the single wire mapping point (compiler-checked, one direction) |
| ZPV3 save/restore + `zPVRecordLen`/`zPV2DropName` | `server/game.zig` | **keep** | P2 | Record length + drop are pure fns; write side (savePlayers) and read side (tryRestorePlayer) still hand-walk fields. Extract a record reader pair on a 3rd reader site; not P0/P1 |
| `stockEntries` | `server/game.zig` | **keep** | - | 4 call sites (spawn ECD + snapshots + lock response), ECS→wire mapping with named cap, skips zero-count rows. Correct layer (server orchestration) |
| `buildLockResponseTrader` / `buildTraderDataStock` | `wire/packages.zig` | **keep** | - | Two envelopes, one `stock_entity.writeTraderDataBody` body writer: no dual trader-data encoder |
| `remove_quest` handlers (5664, 6379) | `server/game.zig` | **keep** | - | Two protocols (SharedQuest event vs NPCQuestList offer accept), different semantics, not duplicated logic |
| `zdtd.toml [sim]` | `server/zdtd_config.zig` | **keep** | - | One-key section following the exact applyKV/sanitize/merge pattern; consistent with stream/authority/feature/perf |
| Weather `encode/decode` rng state carry | `world/weather.zig` | **keep** | - | Restored manager replays the identical schedule (test proves it); fail-closed decode |

### Dual-path hunt (2026-08-06)

- FS: still a single `io_fs` story; no `linux_fs` module; residual raw posix only
  in litenet/tcp_listen thin layers.
- Encoders: one chunk encoder (`encodeNetworkChunk`); trader data has one body
  writer with two envelopes; no second stock package builder introduced.
- Id resolve: one runtime AssignIds authority; `loot_list_by_id` is derived from
  the same dump merge.
- ecs→assets / ecs→server / ecs→wire / world→wire / assets→wire imports: none
  (grep-verified; `ecs/root.zig` contract holds).

### Hot-path check (2026-08-06 additions)

- `rawAt` memo read: no heap, no I/O; fills `chunk_raws` once per chunk encode.
- `writeWaterChannel` / density / texture: stack arrays only, SIMD packs shared.
- `drop_prob` roll: integer math on the damage path, no alloc.
- `stockEntries`: fixed `[16]` caller buffer, no alloc.
- Weather encode/decode: off-tick (save/restore), alloc-free fixed buffer.

### Changes made this pass

1. `src/assets/quests.zig`: `pickPrimaryKind` now reuses `objectiveTarget`
   instead of re-implementing the value/count/item_count rule (P2 merge).

### Do not build (wave-specific)

- Generic Extends-chain resolver over the three existing walks (items/maxdamage/quests).
- A generic ChunkBlockChannel writer over light/damage/texture/water (shapes differ; SIMD packs already shared).
- An abstract weather backend / plugin-style storm hook; the single `Manager` state machine is the stock boundary.

## 2026-08-04 baseline

Scope: full tree under `src/` (util, wire, assets, world, server, ecs, litenet,
apm). Date: 2026-08-04. Method: `docs/prompts/abstractions-review.md` decision
tree + scorecard. Complementary to idiomatic Zig / `std.Io` migration.

## Inventory (abstractions in scope)

| Name | Path | Kind | Call sites (approx) | Layer |
|---|---|---|---|---|
| `io_fs` | `util/io_fs.zig` | thin util (`std.Io`) | 40+ | util |
| `parallel` | `util/parallel.zig` | thin util (worker pool) | 3 (AI, turrets, chunk save) | util |
| `binary` Reader/Writer | `wire/binary.zig` | thin util (.NET LE) | many | wire |
| `packages` facade | `wire/packages.zig` | layer facade + builders | many | wire |
| `stock_*` encoders | `wire/stock_*.zig` | domain builders | via packages / game | wire |
| `PackageIds` / name map | packages | boundary type | join + send | wire |
| `assets/root` | `assets/root.zig` | import facade | tests + imports | assets |
| `ecs/root` | `ecs/root.zig` | import facade | server | ecs |
| `apm/root` Harness | `apm/root.zig` | facade + metrics | game tick | apm |
| `maxdamage.idByName` | `assets/maxdamage.zig` | runtime id table | load + place + deco | assets |
| `assignids_comptime` pins | `assets/assignids_comptime.zig` | comptime pins + dump test | offline defaults / fixtures | assets |
| `IdByNameFn` hooks | blocks, biome_layers, storage_pairs | callback boundary | load paths | assets |
| `Game` orchestration | `server/game.zig` | domain (large) | main | server |
| LiteNet UDP | `litenet/udp_socket` | `std.Io.net` + thin posix | listen/tick | litenet |
| admin / GSI / webui TCP | `util/tcp_listen` | `IpAddress.listen` + poll/accept4 | optional ports | util/server |
| `util/clock` only | monotonic time | `posix.system.clock_gettime` (vDSO) | metrics/tick | util |

Deleted this pass: `util/owned_arena.zig` (zero production call sites; only
pulled into assets test root). `linux_fs` module: already absent (no file).

## Scorecard verdicts

| Name | Score notes | Verdict | Sev | Action |
|---|---|---|---|---|
| Dual FS (`linux_fs` + `io_fs`) | dual path | **merge** | P1 | Done: single `io_fs` / `std.Io`; raw FS removed from app/world/assets/config/game persist |
| `io_fs` | 3+ sites, std gap sugar, removes dual | **keep** | - | Extended: mkdir/write/read/list/exists/dir/delete/readLink/readInto |
| `readFileExact` alias | 0 policy, pure forward | **delete** | P2 | Removed; call `readFileAll` |
| `owned_arena` | 0 real call sites | **delete** | P1 | Deleted file |
| Local `mkdirP` copies | 5+ files open-coding linux.mkdir | **merge** | P1 | Call `io_fs.mkdirPath` / `mkdirPathSimple` |
| Local `fileExists` 1-liners | same-file private, 3+ sites | **keep thin** | P3 | Private forward to `io_fs.fileExistsSimple` OK |
| `buildChunkBodyBare` | 1 test site, pure forward | **delete** | P2 | Tests use `buildChunkPayload` |
| `buildInventoryBody` / `buildHoldingBody` aliases | 0 external callers | **delete** | P2 | Prefer `*Stock` / `*Resolved` names |
| `buildHoldingBodyResolved` vs `*StockResolved` | dual name same body | **merge** | P1 | Single `buildHoldingBodyResolved` |
| Chunk encode paths | height-plane `buildChunkBody*` vs `stock_chunk.encodeNetworkChunk` | **keep both** | P2 | Different stock shapes: bots/tests vs production stream (`stock_chunk.buildNetPackageChunkNew`). Not dual encoders for one package |
| Id resolve | runtime `maxdamage.idByName` + comptime pins | **keep split** | P2 | Documented: open set = dump table; pins = offline/fixture only. Not a second AssignIds space |
| `packages.zig` size (~2.7k) | facade + many builders | **document** | P2 | God facade: do not split until a leaf file already owns tests; logic stays in `stock_*` |
| `game.zig` size (~5.5k) | orchestration god | **document** | P2 | Wrong-layer open-code wire is already mostly in packages; further split is product work, not this pass |
| `parallel` | 3 sites, no alloc on hot path | **keep** | - | - |
| Plugin / System vtable | none | **do not build** | - | - |
| LiteNet + admin/GSI TCP | migrated to `std.Io.net` / `tcp_listen` | **keep** | - | See [STD_ABSTRACTIONS.md](STD_ABSTRACTIONS.md); residual thin posix only |
| clock hot path | `posix.system.clock_gettime` | **keep** | - | Io.Threaded per call too heavy on packet path |

## Dual paths

| Dual | Status |
|---|---|
| `linux_fs` module vs `io_fs` | **Eliminated** (module was already gone; remaining raw `std.os.linux` FS callers migrated to `io_fs`) |
| App FS via `std.os.linux.open/read/write/mkdir/unlink` vs `io_fs` | **Eliminated** in world store/containers/dem/dtm/prefabs/water/tts/biomes/blocks_nim, assets assignids/maxdamage, server config/scenarios/game player+blockmeta+seed chest, main CLI |
| Socket stacks (LiteNet, admin TCP, GSI) | **Migrated** to `std.Io.net` / `tcp_listen` (thin posix residual) |
| Chunk height-plane builders vs stock network chunk | **Not dual**: different wire shapes; production uses `stock_chunk` |
| Holding/inventory alias forwards | **Eliminated** dead aliases |
| Id: AssignIds dump vs comptime pins | **Documented one authority**: runtime dump for play; pins for offline fixtures only |

## Abstractions to add

None scored ≥ 6 that are missing. Third-call-site policies already live in
`io_fs`, `binary`, `parallel`.

## Do not build

- Generic `Repository(T)` / DI / mod plugin host
- Second FS stack or expanding a `linux_fs` module
- Second stock chunk encoder "for bots" that diverges from RE
- `OwnedArena` until ≥3 loaders share create/ensure without copy-paste pressure
  (current loaders use inline `ArenaAllocator` create; extract only on third
  identical lifecycle if it reduces bugs)
- Abstract base `System` trait object bus

## Hot-path check

| Helper | Tick? | Heap? | Hidden I/O? |
|---|---|---|---|
| `io_fs.*` | no (init/load/persist/admin) | yes (Threaded + file) | yes, intentional off-tick |
| `parallel.forRanges` | yes (AI/turret/save) | no per-item | no |
| `packages.build*` | yes (encode into `body_buf`) | no | no |
| `stock_chunk.encode*` | yes (stream) | no | no |

## Layer placement

Matches AGENTS table. FS helpers stay in `util/io_fs`. Wire bodies stay in
`wire/*`. World persist now goes through `io_fs` without crossing into LiteNet.

## Code changes this pass

1. Extended `util/io_fs.zig` (simple variants, delete, dirExists, readLinkAbsolute, readFileInto).
2. Migrated remaining ordinary FS off `std.os.linux` into `io_fs`.
3. Deleted `util/owned_arena.zig` and dead package alias forwards.
4. Removed duplicate assets test import of `io_fs`.

## Residual (not P0/P1)

- Thin posix residuals on net/clock: REUSEADDR, poll+accept4, clock_gettime (see STD_ABSTRACTIONS).
- `packages.zig` / `game.zig` size (document only).
- Private per-file `fileExists` forwards (harmless).
- Comptime AssignIds pins vs runtime dump (documented dual-role, not dual path; ECS item handles: ADR 0015).

