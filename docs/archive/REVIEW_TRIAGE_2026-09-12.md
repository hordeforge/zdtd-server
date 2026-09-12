# Review triage 2026-09-12

All nine `docs/prompts/*.md` review passes ran against HEAD `3d408904` and wrote
their snapshots under `docs/archive/` (commit `2d60fccb`). This file is the
consolidation: every finding, its verification result, and where it stands.

Dispositions:

- **FIXED** - applied in this pass, gate run after (see the commit that carries
  this file).
- **REJECTED** - verified and found not to be a defect (reason given). Reviews
  are static; a finding is not a fix instruction until the code around it is
  read.
- **QUEUED** - real, not applied here. Ordered by severity in the batch list at
  the end.

Snapshots: `HARDCODE_AUDIT_2026-09-12.md`, `NET_SEND_REVIEW_2026-09-12.md`,
`ECS_REVIEW_2026-09-12.md`, `ZIG_0_16_REVIEW_2026-09-12.md`,
`ZIG_REVIEW_2026-09-12.md`, `ZIG_PRACTICES_REVIEW_2026-09-12.md`,
`ABSTRACTION_REVIEW_2026-09-12.md`, `SIMD_REVIEW_2026-09-12.md`,
`../reviews/PLUGIN_COMPOSABILITY.md` (F7-F11).

## Fixed in this pass

| Review | Finding | Change |
|---|---|---|
| net-send P0 | `chunk_stream.zig` charged the tick pacing budget only on a delivered chunk, so a wedged peer walked the whole spawn ring / view square in one tick | budget charged per attempt; the pass stops on refusal (`drainSpawnArea`, `streamChunksForClient`) |
| net-send P1 | `NetPackageSignDataResponse` was absent from `isDroppablePackage`, so a full window aborted `sendSignDataBatches` before `isLastBatch=true` | added to the droppable set (middle batches may drop, the critical final batch still must deliver) |
| net-send P1 | `sendJoinBundle` at the spawn/respawn sites re-armed a full critical budget per package | both call sites arm the shared `critical_budget_deadline_ns` like the `RequestToEnterGame` bundle |
| hardcode A1 P1 | `weather.zig` pinned the `NetPackageWeather` body to 5 biomes and padded by duplicating state | count now `biome_layers.weather_n` (stock `biomeWeather.Count`); the 5-entry fallback survives only for a table with no biomes at all |
| ECS P1 | `tickSurvival` returned early when both decay rates were 0, skipping drowning/radiation/stamina and the whole buff lifecycle, including the `onSelfEnteredGame` class buffs | only the two food/water decay writes are gated |
| ECS P1 | `blockRawAt` returned 0 on a sparse-mirror miss (the mirror evicts), so a resend or TE replicate could report a bare block id for a rotated block | miss reads the resident chunk raw plane (`chunkAt`, never `getOrCreate`) |
| ECS P1 | `containers.getByGuid` scanned the ~500 B AoS | decodes the guid to `PosKey` (`posFromGuid`, tag-checked) and reuses `get`'s key-mirror scan |
| zig-0.16 P1 | `@intFromFloat` is a deprecated alias of `@trunc` in 0.16 | all 60 call sites in `src/` and `mods/` moved to `@trunc` (nested `@trunc(@ceil(x))` collapsed to `@ceil(x)`) |

Doc corrections that fall out of the hardcode audit (the code was right, the
docs were not): `XML_DATA_AUDIT.md` row 6 (the starter kit never moved to
`zdtd.toml`), the same file's loot "fabricated scrap iron" row (the roll fails
closed now), `PROVENANCE.md` ambient-seeds row and `DIVERGENCES.md` 6.2 (only
the hostiles are behind `starter_zombies`).

## Rejected after verification

| Review | Finding | Why it is not a defect |
|---|---|---|
| net-send P1 | `game.zig` `sendBlockIdMapping` logs and returns on frame-init/write/deflate failure instead of propagating | that is the documented contract in the function's own header: "All or nothing. A partial blob is worse than none... any validation failure, an empty dump, or a compressed size that does not fit all skip the package entirely and leave today's LoadLocal behaviour in place." `LoadFromArray` swallows a partial blob and `assignLeftOverBlocks` silently renumbers unnamed blocks, so returning the error (which aborts the join) is strictly worse than the current fail-closed skip |
| best-practices P1 | `game.zig` has 226 one-line forwarders | it is the documented delegating facade; deleting them touches every call site of a 3.9 k-line file for no behavioural gain. Kept deliberately; the note "stop adding no-policy forwarders" is recorded below |

## Fixed in the second pass (round 22)

| Review | Finding | Change |
|---|---|---|
| hardcode B1 P2 | the starter kit was hardcoded in `World.spawnPlayer`; docs claimed it was already config | `[sim] spawn_starter_kit` (`name` / `name:count` rows) parsed once at `Game.create` after the catalog loads, resolved through items.xml, unknown names omitted, counts clamped to Stacknumber, unset keeps the default |
| hardcode B2 P2 | `starter_zombies = false` did not give a stock-lazy world: trader/minibike/chest/power seeded unconditionally | `[sim] demo_seed` gates the rest; both false is stock-lazy (DIVERGENCES 6.2, PROVENANCE ambient-seeds row) |
| SIMD P1 | `dmg_at` passed unconditionally, so 65536 indirect damage callbacks ran per chunk with no damage plane | gated like `dens_at`; the null branch writes identical bytes |
| plugin F7 P1 | point claims bound by plan slot, not loaded slot | `loadResolved` maps plan slot to loaded slot and refuses a claim whose module never loaded; regression test with a skipped first module |
| net-send P2 | `map.zig` marked pieces sent before the send | marked only on a real send |
| net-send P2 | `budget_ns == null` disabled the only fragment-retry deadline | parameter is a plain `u64`; no caller passed null |

## Fixed in the third pass (round 23)

| Review | Finding | Change |
|---|---|---|
| hardcode A2 P3 | `world/workstations.zig` applied the invented 10 s burn when a wired FuelValue resolver answered 0 | a wired resolver answering 0 stops the burn and leaves the item; the fallback is offline-only |
| hardcode B3 P3 | `pos_heartbeat_period_ticks` was not operator-tunable | `[stream] pos_heartbeat_period_ticks` (default 5, clamp >= 1) threaded through `interest.needsPosSend` |
| plugin F8 P2 | `reload` did not enforce `_zdtd_requires` for manifest-backed modules, so HMR accepted a module a restart refuses | reload sets the same flag as `loadResolved`; the in-repo test fixtures now declare `_zdtd_requires` |
| plugin F9 P2 | `reconcileClaims` zeroed claims/deny before `bindManifest`, so a failed re-read lifted both | manifest read first, state changed only on success; failure logs and keeps the previous claims and mask |
| plugin F10 P3 | `deny = "spawn"` did not stop `bot spawn` (and `despawn` vs `bot remove`) | bot sub-verbs fold into the tested mask; other sub-verbs stay behind `bot` |

Residual from F9: a manifest-backed reload still succeeds when its manifest
is invalid (the module itself loaded); the state change is refused but the
reload is not. Refusing the reload would mean tearing down a freshly loaded
module after the fact; the strict form stays queued with F11.

## Queued (ordered)

Correctness / behaviour, next pass:

1. **plugin F11 (P3)** - a manifest-backed reload keeps the old `config_bytes`
   and never re-reads `config.toml`, so an edited config is not seen on HMR.
2. **net-send P2** - the unreliable guards use `max_single_user` while
   `sendUnreliable` enforces `min(max_single_user, peer_mtu-4)`.
3. **ECS P1** - `wire/stock_inv.zig` / `wire/stock_te.zig` mutate ECS state;
   move the apply functions next to their target types (~130 lines).
4. **ECS P2** - `game/trader.zig` copies the whole `TraderStock` by value in
   the replicate loop; take a pointer.
5. **ECS P2** - `replicate_health.zig` and `tickTraderAreas` scan full
   `max_entities` instead of `dirty_bits` / the trader kind group.
6. **ECS P2** - the `Dirty.spawn/.inv/.remove` bits are set but never read or
   cleared, so `dirty_bits` never releases the slot; delete them.
7. **SIMD P1** - `stock_chunk.zig` density channel is scalar whenever a TTS
   density plane exists (POI chunks), bypassing the existing
   `packDensityFromRaws` SIMD path.
8. **abstractions P1** - the native `PluginHost` vtable defaults on
   (`enable_sample_plugin`), composes before Wasm on 28 hooks, and is a
   shipped preset knob, while ADR 0020 decision 2 calls it test scaffolding.
   Needs a maintainer call: default it off in product configs, or amend the
   ADR.

Structure / idiom (no behaviour change):

9. **idiomatic P1 + abstractions P2 + best-practices agree** - one shared
    `std.Io.Threaded` on `Game` instead of a fresh init/deinit in `step.zig`
    (per APM period), `net.zig clientFor` (per first datagram) and all 12
    `util/io_fs.zig` helpers. The 0.16 `Threaded.init` installs process-global
    SIGIO/SIGPIPE handlers, so the current shape clobbers the live instances in
    `udp_socket.zig` / `parallel.zig` and `join()`s on the tick thread.
10. **best-practices P2** - `plugin/manifest.zig` uses `std.meta.tags` and a
    parallel `QueueVerb.names` table where `@typeInfo(T).@"enum".fields` +
    `@tagName` is the 0.16 shape used elsewhere.
11. **best-practices P2** - `protocol.zig` methods `y_pow` / `c_max_height` /
    `plane_cells` are snake_case among camelCase siblings.
12. **abstractions P2** - add `arena.destroyHolder` and replace the 28
    open-coded child/deinit/destroy blocks (`util/arena.zig` already has
    `newArenaHolder`); merge the duplicated edit-reach predicate
    (`game/rescue.zig` vs `game/guard.zig`).
13. **idiomatic P3** - rename the `_,` catch-all out of `apm/profiler.zig`
    `Section` so switches over it are exhaustiveness-checked; widen
    `webui.zig:1396`'s `[8]u8` and give it one overflow policy.
14. **simd P1/P2** - density/texture channel SIMD planes, replicate range
    mask reuse, worldgen row-band material pass (measure first; all have scalar
    goldens to compare against).
15. **zig-0.16 P2/P3** - `std.mem.indexOf` -> `std.mem.find` (10 sites),
    `sys_metrics.zig` residual-table note.
16. **best-practices / abstractions P3** - move `server/replicate_te.zig` under
    `server/game/`, delete the four no-policy `packages.zig` forwarders and the
    `unityStringHash` alias, inline `game/bans.zig`.

## Evidence notes

- The first batch landed with `zig build` clean and `make check` green (lint,
  provenance 203/203 and 65 ledgered constants, XML audit, tests, fuzz).
- The second batch (round 22) landed the same way: `zig build test` direct run
  `1801 passed; 3 skipped; 0 failed` and `make check` green. New tests: the
  starter-kit config (configured, unknown name omitted, count clamped,
  default), `demo_seed = false` removing every demo kind while the default
  world still has them, and the F7 claim mapping with a skipped first module.
  The weather-body test asserts the table count instead of a pinned 115.
- The third batch (round 23): `zig build test` direct run `1802 passed;
  3 skipped; 0 failed` and `make check` green. The scheduled gaps called for
  `[stream] pos_heartbeat_period_ticks` and a `needsPosSend` period argument,
  the two plugin tests that reload a hand-built module had to gain a real
  `_zdtd_requires` export (the F8 rule now holds on HMR too), and the verb
  policy test asserts `deny="spawn"` stops `bot spawn` without spawning.
- The Navezgane mixed-mode loadgen smoke on this tree (2 bots) passed every
  join; it also printed one `tick overrun n=700 late_us=44591 (budget=50000us)`,
  which is worth watching as the independent measurement for the net-send P0
  (the fix bounds the pathological case, it does not claim the common-case
  tick cost fell).
- No review fix was applied without reading the surrounding code; the two
  rejected findings above are the reason that matters.
