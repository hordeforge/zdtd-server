# Zig idiomatic review snapshot (2026-09-12)

Prompt: `docs/prompts/zig-idiomatic-review.md`
Mode: **review only** (session override: read-only on `src/`, `build.zig`, `mods/`,
`plugins/`; no fixes applied; no repo-wide gates run).
Revision under review: `3d4089048b892c03e37a0db5f518196414f48ff0` (`3d408904`).
Toolchain: Zig 0.16.0 (`$HOME/.zvm/0.16.0/lib`).

Applicability gate: working tree is zdtd (`src/`, `docs/prompts/` present, 203
`src/**/*.zig` files). Passed.

## Scope

Sampled hot paths and language use, per prompt default:

- `src/server/game/*` (tick, step, net, chunk_stream, chunk_fill, replicate,
  send_extra, harness, join)
- `src/server/c2s/*`, `src/server/game.zig` (facade only)
- `src/ecs/*` (interest, world, systems, powerblocks, rules)
- `src/wire/*`, `src/litenet/*`, `src/world/store.zig`, `src/util/*`
- `src/apm/*`, `src/plugin/*` by general rules only

Not in scope (owned by sibling prompts): hardcoded game data
(`hardcoded-data-review.md`), helper existence (`abstractions-review.md`), ECS
state ownership / SoA layout (`ecs-soa-review.md`), vectorization
(`simd-review.md`), removed-API names (`zig-0.16-changelog-review.md`),
reliable-send classification (`net-send-review.md`).

Tests were **not** run (session override forbids `zig build` / `make check`).
All findings are static, each traced to call sites.

## Summary counts

| Severity | Count |
|---|---|
| P0 | 0 |
| P1 | 1 |
| P2 | 4 |
| P3 | 4 |

Headline: the hot path is in good shape. `src/ecs/interest.zig`,
`src/server/game/replicate.zig`, `src/server/game/send_extra.zig` and
`src/server/game/chunk_stream.zig` contain **no** heap allocation, no growing
list, and no `std.fmt.allocPrint`. `std.os.linux` appears only in
`src/util/sys_metrics.zig` (sanctioned) and `linux_fs.` has zero hits. The real
debt is I/O shaping (`std.Io.Threaded` built per call, including on the tick)
and an undocumented shared `body_buf` scratch layout.

## Findings

### P1

| # | Location | Evidence | Idiomatic fix | Sev |
|---|---|---|---|---|
| F1 | `src/server/game/step.zig:556` | The tick function builds `var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{}); defer threaded.deinit();` to print one APM JSON line, reached every `apm_report_period_ticks` (default 1200, `types.zig:56`). `Threaded.init` installs process-global handlers with `posix.sigaction(.IO/.PIPE, ...)` (`std/Io/Threaded.zig:1652-1660`); `deinit` restores them, calls `t.join()` and `t.* = undefined` (`Threaded.zig:1712-1722`). The UDP socket holds a live Threaded for the process lifetime (`src/litenet/udp_socket.zig:18`) and the parallel pool holds another (`src/util/parallel.zig:86`), so this per-report init clobbers their SIGIO disposition and the deinit blocks in join. | Construct one `std.Io.Threaded` (or bare `std.Io`) at `Game.create` and pass `self.io` down, exactly as the prompt's I/O example requires. `std.Io.File.stdout().writeStreamingAll(self.io, ...)`. | P1 |

### P2

| # | Location | Evidence | Idiomatic fix | Sev |
|---|---|---|---|---|
| F2 | `src/server/game/net.zig:462` | `clientFor` (per-packet entry, called from `net_handlers.zig:14` and `:46`) builds and tears down a Threaded on the first packet of a peer that has no client slot, using `page_allocator`, only to call `threaded.io().random(&c.challenge)`. Comment at `:459-461` claims "accept path, not the tick"; UDP has no accept, this is the first-datagram path. Same sigaction replace/restore and join as F1. | Same shared `self.io`; `c.challenge` is per-connection so `self.io.random(&c.challenge)` is correct and allocation-free. | P2 |
| F3 | `src/util/io_fs.zig:62` | `ioThreaded()` returns a fresh `std.Io.Threaded` by value; 12 helper entry points each init/deinit one per call (`io_fs.zig:67,80,102,133,162,171,179,191,202,212,225,237`). Reached from the tick save path (`step.zig:513-518` -> `containers/workstations/allies.save`) and from chunk materialization (`store.zig` uses `io_fs` 26x, `prefabs.zig` 23x). This is the root cause of F1/F2. Intent is documented at `io_fs.zig:57-61` ("paired init/deinit so this can nest inside a bound socket Threaded"), which is exactly the pattern the prompt's example forbids. | One process-lifetime `std.Io.Threaded` behind a `std.once`/mutex (Threaded is designed to be shared), and `io_fs` callers take its `std.Io`. Removes 12 init/deinit pairs and the handler churn. | P2 |
| F4 | `src/server/game.zig:2213, 2606, 2698, 2745, 2757, 2773, 2782`; `src/server/game/tick.zig:838, 906`; `src/server/game/chunk_fill.zig:786`; `src/server/game/replicate_te.zig:211, 355, 435`; `src/server/game/replicate_health.zig:61, 76, 88`; `src/server/game/social.zig:378, 410`; `src/server/game/chunk_stream.zig:293, 301`; `src/server/game/world.zig:549`; `src/server/game/vehicle.zig:22, 38, 62, 95, 117`; `src/server/game/stability.zig:64`; `src/server/game/step.zig:318`; `src/server/admin_console.zig:323, 1799, 1655`; `src/server/replicate_te.zig:78, 108` | Callers hand-build sub-ranges of the single 512 KiB `body_buf` (`game.zig:402`) with bare literals: `[0..96]`, `[0..64]`, `[0..11]`, `[0..16]`, `[16..32]`, `[96..200]`, `[200..456]`, `[256..384]`, `[384..16384]`, `[1024..1040]`, `[8192..8704]`, `[9216..9728]`, `[9728..]`. Nothing names or asserts the partition, and nothing stops a later edit from placing a second live body inside a region a first body still occupies (`[1024..1040]` is inside the `[384..16384]` PlayerId region). I found no proven live overlap: every send copies into `send_buf` synchronously (`net.zig:108`), so bodies die at `sendGame` return. This is a latent footgun plus a magic-number violation on the wire/tick path. | Promote the offsets to named module consts (`body_region_setblock`, `body_region_pid`, ...), and add `comptime` range-disjointness asserts. Behaviour unchanged. | P2 |
| F5 | `src/world/store.zig:851` (`self.allocator.create(Chunk)`), `:1502/:1516/:1527/:1532/:1544` (per-plane `alloc`), `:1411` (`encodeChunk(c, std.heap.page_allocator)`) via `evictOneChunk` (`:830-836`) and `saveAll` (`:1613`) | Chunk materialization and chunk encode allocate on the chunk-stream / tick path. It is bounded: `max_resident_chunks = 4096` (`:805`), cap checked at `:841`, LRU victim destroyed at `:835`, and eviction save is async by default (`:1412`). The prompt classifies first-touch fill into reserved slot storage as allowed, but this implementation reserves nothing per chunk: `create(Chunk)` plus per-plane `alloc` is the allocation. | Either document the gray area explicitly on `getOrCreate` (cap + eviction + async encode is the whole argument) or move chunk slots to a pre-reserved pool. Cheapest: add a `///` note naming the cap and the `apm` counter that exposes the eviction rate. | P2 |

### P3

| # | Location | Evidence | Idiomatic fix | Sev |
|---|---|---|---|---|
| F6 | `src/server/webui.zig:1396` | `var s_buf: [8]u8 = undefined;` then `std.fmt.bufPrint(&s_buf, "{d}", .{remaining_s}) catch unreachable` for a `u32` (max 10 digits). The sibling that formats the *same* value for Retry-After uses `catch "30"` (`webui.zig:590`), so one value has two recovery policies. `lockoutRemainingS` (`:317-326`) currently caps at 30 s, so this is latent, not live. | Widen to `[10]u8` and use one policy: `catch "30"` like `:590`, or `assert(remaining_s <= 9999)`. Also removes the only `catch unreachable` on an unbounded type in webui. | P3 |
| F7 | `src/server/game/tick.zig:839, 897, 907, 974, 1005, 1014, 1161, 1171, 1197, 1202, 1255, 1296, 1360`; `src/server/game/chunk_fill.zig:553, 593, 620, 749, 786, 837, 848` | Empty `catch {}` on `broadcast` / `broadcastNear` / `broadcastLootSpawn` on the tick and chunk-fill paths, with no comment. AGENTS: "Empty `catch {}` only for true best-effort shutdown or documented non-fatal RE fallback (comment why)". Traced: `broadcastNearImpl` already counts encode failures (`net.zig:249`) and window drops (`:277`), so the failure is not invisible in `apm`; only the intent is undocumented. | Add a one-line comment at each site or, better, route through one helper that counts and comments once. No behaviour change. | P3 |
| F8 | `src/assets/buffs.zig:1425, 1483, 1572, 1628`; `src/server/game/tests.zig:1546, 1547, 1597, 1598` | Tests write into the repo: `io_fs.mkdirPath("worlds")` plus `worlds/zdtd_buffs_*.xml` (removed by `defer deleteFile`, but the `worlds/` directory is left), and `.zdtd_cfg_cache/dst_*` dirs. AGENTS rule: "Tests never write into repo. Use `std.testing.tmpDir`... `.zdtd_test_*` is gitignored as backstop, not licence". Both paths are gitignored (`worlds/`, `.zdtd_cfg_cache/`), so the cost is an unclean tree plus a stale directory, not a committed artifact. | Port the four buffs tests and the two dst tests to `std.testing.tmpDir`, passing the path in. | P3 |
| F9 | `src/apm/profiler.zig:40` | `Section` ends with a `_,` catch-all arm. Every `switch` over `Section` therefore cannot be exhaustiveness-checked, which is the compile-time guarantee the prompt's section 5 asks for. `sections_len` (`:42`) is still correct because a non-exhaustive `_` is not in `@typeInfo(...).@"enum".fields`. | Drop the `_` arm (the enum has 15 named members and one switch site set) so a new section forces every consumer to be updated. | P3 |

## Comptime, inline, and anytype

**Good (no change):**

- `src/ecs/interest.zig:54` `ObserverMask` returns `@Int(.unsigned, lanes)`; the
  observer mask is a single `@Vector` word (`:80-100`) with a per-lane
  semantics comment. Correct 0.16 reification, no `@Type`.
- `src/litenet/peer.zig:25-31` caps computed at comptime with a
  `std.debug.assert(packet.max_sequence % pending_cap == 0)` in a `comptime`
  block (`:23-25`); the `catch unreachable` on `divCeil` is genuinely
  comptime-known and commented.
- `src/util/toml_bind.zig:148, 164, 225, 245` walks `std.meta.fields` and
  `@typeInfo(E).@"enum".fields` to auto-bind config, which is ADR 0021 exactly.
- `src/ecs/world.zig:116` and `src/ecs/query.zig` use `comptime opts: anytype`
  as a documented options struct, the `std` shape rather than `anytype` soup.

**Bad or risky:**

- No `inline fn` abuse: the only three are 2 to 6 line `apm/tracy.zig` helpers
  (`:43, 51, 56`). Nothing large is inlined.
- `src/server/game/init_assets.zig:47` reaches
  `@typeInfo(@TypeOf(result)).error_union.payload` without a tag check. It is a
  compile error if wrong, so it fails at compile time as intended; listing it
  only so a future non-error-union call is understood to be a hard build break.
- `@Type(` has zero hits. `std.meta.Int` has zero hits.

**Missing:**

- No `comptime` size assertion guards the `body_buf` scratch partition (F4).
  A `comptime` block asserting the regions are disjoint is the cheap fix that
  makes the layout self-checking.

## Hot-path memory (prompt section 3a)

Verified clean, by search plus call-site trace:

| Path | Result |
|---|---|
| `src/ecs/interest.zig` | no `alloc`/`ArrayList`/`dupe` hits |
| `src/server/game/replicate.zig` | no `alloc`/`ArrayList`/`HashMap`/`dupe` hits |
| `src/server/game/send_extra.zig` | no hits; deflates into `Game.send_buf` (`Frame` path) |
| `src/server/game/chunk_stream.zig` | no hits; caps named, drop-oldest at cap (`:86-92`) |
| `src/ecs/world.zig` `net_to_slot` map | pre-reserved at init (`:678 ensureTotalCapacity(max_entities)`), so per-entity `put` (`:1034`) cannot grow; OOM path degrades to linear lookup with a printed warning, commented |
| `src/wire/*` | builders take caller buffers; sizes are named consts with RE cites |
| `src/litenet/peer.zig` | fixed caps, comptime assert; `extra_q_len`, `pending_cap`, `assemble_cap` named |

Hot-path exceptions are F1, F2, F5 (all above) plus F3's reachability from the
tick save path. No `page_allocator`, `allocPrint`, or growing list was found in
per-packet encode/decode, interest fan-out, or chunk stream select.

`apm` coverage matches AGENTS rule 6: `.tick_total`, `.net_poll`,
`.sim_entities`, `.replicate`, `.chunk_stream`, `.chunk_gen`, `.save_io`,
`.save_encode`, `.save_flush_wait`, `.terrain_snap`, `.sleeper_scan`,
`.te_scan`, `.survival`, `.join`, `.join_drain` are all live
(`step.zig:33,45,93,96,506,509`; `replicate.zig:21`; `chunk_stream.zig:248`).

## I/O and syscall debt

| Class | Sites | Verdict |
|---|---|---|
| `std.os.linux.*` | `src/util/sys_metrics.zig:48-49` (`sysinfo`) | **legacy OK**: AGENTS rule 26 names `util/sys_metrics.zig` as a sanctioned OS-specific site |
| `std.posix.setsockopt` | `src/litenet/udp_socket.zig:44-64` | **legacy OK**: AGENTS rule 26 names `litenet/udp_socket.zig`; the `V6ONLY` probe deliberately uses `posix.system.setsockopt` + `posix.errno` to avoid `unreachable` on `EINVAL` (documented `:55-58`) |
| `std.posix.rusage` | `src/util/sys_metrics.zig:60-62` | **legacy OK** (same sanctioned file) |
| `std.posix.system` clock | `src/util/clock.zig:6` | **legacy OK**, documented vDSO rationale |
| raw FS (`std.posix.open/read/write/close`, `std.c.*`) | none | clean |
| `linux_fs.` | none | migration guard held |
| per-call `std.Io.Threaded` | `io_fs.zig:62` + 12 entry points; `step.zig:556`; `net.zig:462`; `main.zig:117`; `assets/modlets.zig:74`; `assets/signs.zig:153`; `udp_socket.zig:18`; `tcp_listen.zig:23`; `parallel.zig:86` | **fix-now for `step.zig:556` and `net.zig:462`** (F1, F2); **migrate when touching for `io_fs.zig`** (F3). The socket/listener/pool ones are correct: one instance, held for the process lifetime |
| stdout only | `main.zig:117` (`writeStdout`) | **legacy OK**: one-shot CLI path, not the tick |

No second FS path, no second UDP stack, no `std.c` file loop.

## Structure, naming, errors (secondary sweep)

- All 203 `src/**/*.zig` files begin with a `//!` module doc. No gap.
- `src/server/game.zig` is 3918 lines; it is the documented delegating facade
  (`sendGame`, `broadcast`, `clientFor`, `create`/`deinit` are real bodies, most
  else forwards). One facade exception: `game.zig:2570-2790` open-codes the
  join-bundle send sequence with raw `body_buf` slices (F4). That is
  orchestration, not a package field write, so it does not violate the layer
  table; the buffers are the issue.
- No duplicated encoder for one stock package shape was found:
  `buildSetBlockBody` vs `buildSetBlockBodyRaw` encode different stock shapes,
  and every other `buildXxxBody` name maps 1:1 to a package.
- No `@panic("todo")` on a production path. `unreachable` in production code:
  `webui.zig:1396` (F6), `join.zig:767` (fmt into a fixed buffer, same pattern,
  currently safe), `peer.zig:25` (comptime, justified), `packages.zig:4508`
  (comment explains the cast is provably unreachable). `admin_console.zig`'s 15
  empty catches are admin-only one-shot paths, lower risk than F7.
- Sim determinism: zero `std.crypto.random` / `std.time` on loot or AI. The
  only `Io.random` use is the per-connection challenge CSPRNG (`net.zig:464`),
  which is correct. All `std.Random.DefaultPrng` uses are test-local with fixed
  seeds. No finding.
- `Thread.spawn` outside the sanctioned pool exists only in tests
  (`ecs/systems.zig:4430, 4454` inside `test` blocks; `ecs/world.zig:2417`
  inside a `test "AtomicBits concurrent..."`). Production threads are
  `util/parallel.zig:92` (persistent pool) and `world/chunk_flush.zig:98`
  (single writer). No finding.

## Ordered fix plan (small PRs)

1. **PR 1 (F1, F2): one `io` for the process.** Add `io_threaded: std.Io.Threaded`
   plus a `io: std.Io` accessor set in `Game.create` (`game.zig:683`) and torn
   down in `Game.deinit` (`game.zig:1363`). Replace `step.zig:556-558` and
   `net.zig:462-463`. Expected 10 to 14 lines, no wire change. Removes the only
   tick-path `Threaded` construction.
2. **PR 2 (F3): make `io_fs` use that instance.** Turn
   `ioThreaded()` (`io_fs.zig:62`) into a shared process-lifetime singleton and
   drop the 12 paired `defer deinit()` blocks. Expected 30 to 40 lines in one
   file. Cross-check the "nest inside a bound socket Threaded" comment: with a
   single shared instance nothing nests, so the comment goes too.
3. **PR 3 (F4): name the `body_buf` regions.** Add module consts for the
   offsets and a `comptime` disjointness assert, then replace the ~25 literal
   slices. Expected 40 to 60 lines, mechanical, no behaviour change. Do it
   before the next builder that needs scratch.
4. **PR 4 (F6, F9): stop suppressing exhaustiveness.** Widen `webui.zig:1396` to
   `[10]u8` with `catch "30"` (matches `:590`), and drop `_,` from
   `apm/profiler.zig:40`. Expected 4 to 8 lines; `zig build` will surface any
   switch that the catch-all was hiding.
5. **PR 5 (F5, F7, F8): document, do not rewrite.** One `///` note on
   `store.getOrCreate` stating the 4096 cap, eviction, and async encode
   (F5); one comment per broadcast drop site or one shared helper (F7); move
   the six repo-writing tests to `std.testing.tmpDir` (F8). Expected 25 to
   40 lines, mostly comments plus test plumbing.

F4 and F1 are the two that will bite again: F1 because a second long-lived
`Threaded` keeps the clobber window open, F4 because the next scratch buffer
will be placed by eye.

## Search evidence run

```text
rg -n 'allocator\.(alloc|create|dupe|realloc)|page_allocator|allocPrint|\.dupe\(' \
  src/server/game src/server/c2s src/ecs src/wire src/litenet src/world/store.zig
rg -n 'ArrayList|HashMap|SegmentedList' src/server/game src/server/c2s src/ecs src/wire
rg -n 'Threaded\.init' src --type zig
rg -n 'Thread\.spawn' src --type zig
rg -n 'std\.os\.linux\.|std\.posix\.(open|read|write|close)|std\.c\.(open|read)' src
rg -n 'linux_fs\.' src        # empty
rg -n 'inline fn' src          # 3 hits, all tracy helpers
rg -n '@Type\(|@typeInfo|std\.meta\.' src
rg -n 'catch \{\s*\}|catch unreachable' src
rg -n 'body_buf\[[0-9]+\.\.[0-9]+\]|body_buf\[0\.\.[0-9]+\]' src
rg -n 'crypto\.random|std\.Random|DefaultPrng' src
```

## Not verified

- `zig build` / `make check` / `zig build test` were not run (session override).
  F6 and F9 are the two findings whose fix could surface compile errors, and
  neither was compile-checked.
- The `Threaded.init` SIGIO clobber in F1/F3 is read from the Zig 0.16.0 std
  source, not reproduced against a running server. On a host where
  `have_sig_io` is false the handler part degrades, but the `t.join()` in
  `deinit` and the `page_allocator` bookkeeping remain.
- F5's worst case is asserted from `max_resident_chunks = 4096` and the
  "~256 KiB per block-allocated chunk" comment (`store.zig:803-805`); I did not
  measure resident RSS, so the 1 GiB figure is the repo's, not mine.
- F4 has no proven live overlap. I traced every `body_buf` slice listed to its
  send site and each send copies into `send_buf` before returning, so the
  hazard is latent, not current. A `comptime` disjointness check is the way to
  keep it latent.
- Interest / replicate fan-out was read for allocation only, not audited for
  observer-mask correctness (that is `ecs-soa-review.md`).
