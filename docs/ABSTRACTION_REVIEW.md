# Abstraction review (zdtd)

Scope: full tree under `src/` (util, wire, assets, world, server, ecs, litenet,
apm). Date: 2026-08-04. Method: `docs/PROMPTS/review-abstractions.md` decision
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
| LiteNet UDP | `litenet/*` | net stack (legacy syscalls) | listen/tick | litenet |
| admin / GSI TCP | `server/admin.zig`, `serverinfo_tcp.zig` | sockets (legacy) | optional ports | server |
| `apm/clock` | `apm/clock.zig` | monotonic clock (linux) | metrics | apm |

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
| LiteNet + admin TCP linux | intentional legacy sockets | **keep legacy** | P2 | Migrate only with deliberate net I/O work; not ordinary FS |
| `apm/clock` linux | timing | **keep** | P3 | Prefer `std.Io` clock when touching |

## Dual paths

| Dual | Status |
|---|---|
| `linux_fs` module vs `io_fs` | **Eliminated** (module was already gone; remaining raw `std.os.linux` FS callers migrated to `io_fs`) |
| App FS via `std.os.linux.open/read/write/mkdir/unlink` vs `io_fs` | **Eliminated** in world store/containers/dem/dtm/prefabs/water/tts/biomes/blocks_nim, assets assignids/maxdamage, server config/scenarios/game player+blockmeta+seed chest, main CLI |
| Socket stacks (LiteNet, admin TCP, GSI) still on `std.os.linux` | **Kept** (not ordinary FS; AGENTS legacy) |
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

- LiteNet / admin / GSI / apm clock still use `std.os.linux` (sockets/time).
- `packages.zig` / `game.zig` size (document only).
- Private per-file `fileExists` forwards (harmless).
- Comptime AssignIds pins vs runtime dump (documented dual-role, not dual path).

