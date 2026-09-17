# SIMD opportunity review, 2026-09-12

Prompt: `docs/prompts/simd-review.md`. Mode: **review only** (session override: read-only on
source; no fixes applied, no repo gates run).

- Working tree: zdtd (`zdtd-server`), HEAD `3d408904`, dirty from other parallel reviews only.
- Zig: 0.16.0 (`.zigversion`, `build.zig.zon` `minimum_zig_version`).
- Evidence method: `ripgrep` + `read` over the named hotspots, tracing each loop to its call
  site. Speed claims are call counts, not measurements (no gates allowed this session).

## 1. Existing `@Vector` inventory (audited: tails, scalar goldens)

| Location | Kernel | Tail / golden |
|---|---|---|
| `src/wire/stock_chunk.zig:143` | `fillDefaultRawsFromHeights`, 16 u32 lanes, y-major 256x16 grid | 256 % 16 == 0, no tail. Golden: `test "fillDefaultRawsFromHeights SIMD matches defaultBlockAt"` (:1255, random heights incl. 0/255). |
| `src/wire/stock_chunk.zig:224` | `layerIsUniformU8/U32/U64` (16/8/4 lanes) | scalar tail loop present. Tests :1238. |
| `src/wire/stock_chunk.zig:272` | `layerAnyNonAirU32`, `layerNeedsUpperU32` | scalar tail; test :1238. |
| `src/wire/stock_chunk.zig:302` | `packLowerU8` (8 u32 lanes) | scalar tail; test :1283. |
| `src/wire/stock_chunk.zig:318` | `packUpper24` 24-byte interleave via two `@shuffle` | scalar tail; golden incl. 1024 band and odd 13-cell tail (:1304). |
| `src/wire/stock_chunk.zig:358` | `packTexturePlane` (4 u64 lanes, u6 shift) | scalar tail; test :1283. |
| `src/wire/stock_chunk.zig:378` | `packDensityFromRaws` (8 u32 lanes, compare/select) | scalar tail; golden :1392 and a wire-level equality test :1352 (`dens_at` callback path vs SIMD path). |
| `src/wire/stock_chunk.zig:424` | `fillWaterMassFromRaws` | scalar tail; golden :1423. |
| `src/ecs/interest.zig:66` | `observerMask`, `@Vector(64,i32)` -> u64 bitmask | random cross-check vs `observerMaskRef` (:143) plus empty/zero/last-lane edges (:168), negative radius rejected. |
| `src/ecs/interest.zig:86` | `@bitCast` bool vector -> `ObserverMask` | lanes = `ln_server.max_peers` = 64 (`litenet/server.zig:9`), power of two, safe. |
| `src/world/worldgen.zig:103,120` | `trilerp` at `cell_w`=4 lanes, `tx_lanes` comptime | lane width pinned bit-exact vs `trilerp1` (:680). |
| `src/world/worldgen.zig:410` | `fillHeights` vector height scan | `fillHeightsScalar` reference; 4 lanes divides 16. |
| `src/world/worldgen.zig:426-528` | `generateChunkBlocks` solid store + height max | 4 lanes, contiguous X runs, no tail. |
| `src/world/worldgen.zig:576` | `fillWaterTable` 16 lanes x height band | `fillWaterTableScalar` reference; 256 % 16 == 0. |
| `src/world/dtm.zig:45` | `fillChunkHeights` 16 u16 lanes >> 8 | scalar fallback for edge chunks; golden :258. |

Verdict: the existing kernels are honest (scalar tail everywhere, scalar reference for every
non-trivial one, goldens for byte-identical output). Nothing found that is currently wrong.
The gaps are loops that never reach these kernels.

## 2. Candidate table

Severity: P1 hot+dense with a clean shape, P2 dense but medium heat or needs a layout tweak,
P3 cold / small N, Reject: not vectorizable without breaking determinism or semantics.

| Sev | Location | Loop shape, N per call | Hot? | Verdict |
|---|---|---|---|---|
| P1 | `src/wire/stock_chunk.zig:812` `writeDamageChannel` + `src/server/game/chunk_fill.zig:149` | 64 bands x 1024 cells = **65536** indirect `dmg_at` calls per chunk, each `Chunk.dmgAt` + `rawAt` + `wireBlockDamage` (2 hashmap probes, `maxdamage.zig:187`) | yes, chunk stream/join | **Accept**: callback is unconditional even when `ch.damages == null`, where all 65536 results are 0 and the existing `dmg_at == null` branch writes the same 3 bytes/band. |
| P1 | `src/wire/stock_chunk.zig:696` `writeDensityChannel` | 65536 indirect `dens_at` calls, 1 per cell, when the TTS density plane exists (it always does: `tts.zig:174`, stamped via `store.zig:930`) | yes | **Accept (SIMD)**: `packDensityFromRaws` (:378) sits unused because the fast path is gated on `dens_at == null`; the plane is dense and the band is contiguous. |
| P2 | `src/wire/stock_chunk.zig:734` `writeTextureChannel` | 65536 `texAt` calls (indirect + `blockType(rawAt)` + hashmap `block_textures.get`, `block_textures.zig:70`), SIMD only on the uniform check/pack | yes | **Accept (partial)**: pass the dense `ch.textures` plane (contiguous 1024 u64/band) so painted bands skip the callback; the zero-lane default path stays scalar. |
| P2 | `src/server/game/replicate.zig:200` and `:427` | per candidate entity/bot: 64-client scalar `cellsInRange` re-test while `in_range` (`:115`, `:388`) already holds the identical vector-computed mask | yes, every replicate pass | **Accept as structure fix** (not new SIMD): walk `known ∩ present ∩ ~in_range` bits. TODO.md:960 is this item. |
| P2 | `src/world/worldgen.zig:540-565` material pass (and twin `src/world/store.zig:366-378`) | per column of 256, inner loop y=0..h, ~20k compare/stores per chunk | chunk gen on tick | **Accept (row-band)**: vectorize over the 16-column X run with a per-row `@reduce(.Max, h_run)` upper bound; per-lane stack ids need a 16-scalar gather per row. |
| P2 | `src/world/worldgen.zig:145` `Sampler.init` / `noise.zig` `fbm3` | 25 column targets + 825 `cellDensity` = ~3800 simplex evals per chunk, ~5000 perm gathers each path | chunk gen on tick | **Conditional**: only with a batched-lane kernel and a bit-exact golden; see section 5. |
| P3 | `src/server/game/chunk_fill.zig:276` `te_scan` | 65536-cell u32 plane walk, memoized by previous id | chunk stream | Reject for SIMD: bandwidth bound, body is a hash probe per id change (`isStorageBlockId`); the existing last-id memo is the right fix. |
| P3 | `src/world/store.zig:282` `applyWaterSources`, `src/world/water.zig:57` `waterYNear` | 256 columns x linear scan of `water_info` points (AoS i32 triples) | chunk gen | Reject: N is map-dependent and small; AoS stride 12 blocks a portable vector load. A spatial bucket would be the fix, not SIMD. |
| P3 | `src/world/biomes.zig:285-313` PNG unfilter | per row, per byte, filter switch with a left-pixel dependency | load time | Reject: filters 1/3/4 are serially dependent; only filter 2 (up) is a row-wise add. Load, not tick. |
| P3 | `src/world/biomes.zig:34` `ColorTable.lookup` | linear scan over the color table per PNG pixel (up to 3072x3072) | load time | Reject (non-SIMD): a 24-bit direct map or hashmap removes ~10M scalar probes; not a vector problem. |
| P3 | `src/world/terrain_snapshot.zig:129` `fillCols` | 256 `heightAt` copies per chunk, <= 256 chunks/window | tick when `[perf] terrain_snapshot` on (default off) | Reject: pure contiguous u8 copy, `@memcpy` of the height plane would beat any vector loop and is a 1-line change if it ever shows in `terrain_snap`. |
| P3 | `src/wire/stock_chunk.zig:202` `dominantOf`, `:614` intensities fill, `src/world/biomes.zig:183` `chunkDominant` | 256-element u8 counts / 1536-byte interleave, once per chunk (dominant cached in `ch.biome_id`) | per chunk send | Reject: 256-element N and per-chunk, not per-client. |
| Reject | `src/ecs/systems.zig:235` `nearestPlayerSnap` | scan of player snaps, then branchy `canSensePlayer` (LOS raycast, stealth gates) | AI tick | Reject: N = joined players (<= 64, typically <= 8), and the per-iteration gate is the cost, not the distance math. |
| Reject | `src/wire/stock_deco.zig:303` `generateForDecoChunk` | 1000 RNG attempts, occupancy keep-out, per-species rolls | deco stream | Reject: sequential RNG stream; batching changes the placement stream and the wire bytes. |
| Reject | `src/server/game/sleeper.zig:38` `SleeperScanCtx.work` | volumes x players AABB test | tick (`sleeper_scan`) | Reject: already `parallel.forRanges`; N small; lanes would be players, not volumes. |
| Reject | `src/ecs/systems.zig:2979` falling blocks, `:3130` vehicles | per-entity gravity/integration with ground probes and store lookups | tick | Reject: N small (fell blocks/vehicles), branchy body. |
| Reject | `src/ecs/components.zig:19` `Transform` AoS (x,y,z,yaw stride 16) | per-entity physics in `systems.zig` | tick | Reject here: AoS kills contiguous lanes. SoA split is `ecs-soa-review.md` territory first. |

## 3. Chunk-wire finding detail (the one with a real constant factor)

`sendSpawnChunk` (`chunk_fill.zig:121`) passes `dmg_at = DmgCtx.at` unconditionally (`:149`)
and `dens_at` only when `ch.densities != null` (`:147`). `writeDamageChannel` therefore runs
the per-cell callback path for every chunk, including the ones with no damage plane at all.
For those, the `dmg_at == null` branch at `stock_chunk.zig:813` emits exactly the same bytes
(presence 1 + u16 0 per band). Measured call count: 64 bands x 1024 = 65536 callbacks per
chunk encode; a join streams 17x17 chunks (`chunk_fill.zig:250` comment), so ~19M callbacks
per peer join for a channel that is empty.

`dens_at` is the opposite case: the TTS density plane is always parsed for supported stock
TTS versions (`tts.zig:174-178`), so `setBlockTexDens` allocates `densities`/`dens_set` for
almost every POI chunk (`store.zig:323-337`), which *forces* the scalar density path and
disables the SIMD packet that exists for the same data.

Both are on the `chunk_gen` / `save_encode` apm sections (`apm/profiler.zig:25-27`), i.e. the
sections the docs already name as join-burst costs (`docs/APM.md:122`). I could not run apm
this session (read-only, no gates), so the per-cell cost is stated as call counts, not ns.

## 4. Top 5 recommended wins (edit sketches)

1. **Gate `dmg_at` on the plane (P1, no SIMD needed)**
   `src/server/game/chunk_fill.zig:149`, ~2 lines.
   `// Only when the plane exists: an absent plane makes every cell 0, and the
   // channel then takes writeDamageChannel's same-value branch (byte-identical).`
   `.dmg_at = if (ch.damages == null) null else DmgCtx.at,`
   Golden: encode one chunk with/without damage plane and compare the two payloads
   (`packages.stock_chunk` test, extend the :1352 style).

2. **SIMD density with TTS overrides (P1)**
   `src/wire/stock_chunk.zig:696`, ~45 lines incl. two `EncodeOpts` fields (`:104` area) and
   `chunk_fill.zig` wiring (`:147`).
   Sketch: add `dens_plane: ?*const [65536]u8` and `dens_set: ?*const [8192]u8`. Per band
   `base = band * 1024` (bit-aligned): `packDensityFromRaws(plane[base..][0..1024], &dens)`,
   then for `c` in steps of 8: build `@Vector(8, bool)` from `dens_set` bits `base+c..` and
   `dens[c..][0..8].* = @select(u8, mask, dens_plane[base+c..][0..8].*, dens[c..][0..8].*)`.
   Scalar equivalent to keep as golden: the current `densityAt` callback loop (`:708-719`).
   Determinism: byte compare, not tolerance.

3. **Dense texture plane for painted bands (P2)**
   `src/wire/stock_chunk.zig:734`, ~40 lines. Add `textures: ?*const [65536]u64`; per band
   `@memcpy(vals[0..1024], tex_plane[base..][0..1024])`, then for cells still 0 apply
   `texAt` (defaults from blocks.xml) as today. Scalar golden: current `vals` loop.

4. **Reuse the observer mask for range-remove (P2, structure not SIMD)**
   `src/server/game/replicate.zig:196-212` and `:422-435`, ~15 lines. Build one `present`
   mask (joined/entered/obs_ok/peer) next to `active` (`:83-93`), then iterate
   `m = known_mask & present & ~in_range` and send the remove per set bit. Keeps
   `cellsInRange` semantics because `observerMask` is already that predicate (proved by
   `interest.zig:143`).

5. **Row-band material pass (P2)**
   `src/world/worldgen.zig:540-565` (and the same shape at `src/world/store.zig:366-378`),
   ~40 lines. Per 16-column row: load `h_run` (16 u8 lanes), `ymax = @reduce(.Max, h_run)`,
   loop y=0..ymax: gather 16 `col_ids[lane][y]` into a `@Vector(16,u16)`, load the block run,
   `@select` on `blocks != air`, store. Golden: byte-compare the 65536-cell plane vs the
   current column loop (the existing `generateChunkBlocks` tests :651-678 cover the shape).

## 5. Noise: why it is not in the top 5 yet

`noise.zig` is scalar (`noise2`/`noise3`/`fbm2`/`fbm3`/`ridged2`), and `Sampler.init`
(`worldgen.zig:145`) is the dominant `chunk_gen` cost by call count (~3800 simplex evals per
chunk; ~1.1M per 289-chunk join). A `@Vector(8, f32)` batch is *possible* for the ALU half
(skew, floor, `t`, dot) but every corner needs 3 `perm[]` gathers per lane
(`noise.zig:81`), which portable Zig `@Vector` cannot gather, so the batched form is scalar
`inline for` lanes around vector math: a real but unmeasured win, with a real risk of
disturbing the frozen f32 order. `docs/WORLDGEN.md:147` prefers a `@Vector` port of
OpenSimplex2; that plan is compatible with this finding.

Recommendation: measure `chunk_gen` first (the prompt's "measure or bound cost"), then batch
8 lanes in `Sampler.init`'s y-loop only if the section says noise dominates. Any implementation
needs a per-lane bit-exact golden against scalar `fbm3` (no ulp tolerance: `worldgen.zig:699`
pins "chunk fill matches world density oracle" and STATUS claims seed determinism).

## 6. Not verified / out of scope

- No apm run, no `make check`, no loadgen: all heat statements are call counts plus the
  documented section attribution in `docs/APM.md`.
- `water_info.xml` point count for Navezgane was not read, so the `waterYNear` scan width is
  bounded only by "small"; that P3 could move up if the file is large.
- `max_peers` is 64 today; `observerMask` assumes a power-of-two lane count and a
  `@bitCast(bool vector)` word, so a future non-power-of-two peer cap needs a revisit
  (assert would be cheap).
- Nothing under `plugins/`, `mods/`, `.wasm` or `build.zig` was reviewed: SIMD there is out of
  scope for this pass.
