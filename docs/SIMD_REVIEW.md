# SIMD opportunity review (zdtd)

| | |
|---|---|
| Date | 2026-08-04 |
| Zig | 0.16 |
| Mode | Review + **P1 kernels shipped** in `stock_chunk.zig` |
| Prompt | [`PROMPTS/review-simd.md`](PROMPTS/review-simd.md) |

## Executive summary

| | Count |
|---|---|
| Shipped kernels | density uniform, block any/uniform/lower pack, texture planes (`@Vector`) |
| Deferred | worldgen noise batch (S04) until f32 seed policy locked |
| **P2** remaining | SoA distance, biomes/DTM |
| **Reject** | AI FSM, A*, wire strings, 7-bit binary, XML |

### Shipped (2026-08-04)

| ID | API | File |
|---|---|---|
| S01 | `layerIsUniformU8` in `writeDensityChannel` | `src/wire/stock_chunk.zig` |
| S02 | `layerAnyNonAirU32`, `layerIsUniformU32`, `layerNeedsUpperU32`, `packLowerU8` | same |
| S03 | `layerIsUniformU64`, `packTexturePlane` | same |
| S04 | deferred (fillHeights still scalar `heightAt`; comment + single index loop) | `worldgen.zig` |

Tests: `simd layerIsUniform and anyNonAir`, `simd packLower and packTexturePlane match scalar`, encode regression.

## Existing vector use

| Location | What | Verdict |
|---|---|---|
| `src/world/dem.zig:28-29` | `tile_offsets` / `tile_counts` init `@splat(0)` | Array init sugar, not a hot kernel |
| Rest of `src/` | none | Green field |

`@memcpy` / `@memset` already used appropriately in `store.zig`, `tts.zig`, `worldgen.zig` (keep; not replaced by manual SIMD).

---

## Candidate inventory

| ID | Location | What | N / shape | Hot? | Fit | Sev | Notes |
|---|---|---|---|---|---|---|---|
| S01 | `wire/stock_chunk.zig` `writeDensityChannel` ~336-368 | Per cell density u8, 64 layers × 1024 cells | 64×1024 u8 | **Y** stream | **high** | **P1** | Contiguous fill of `dens[1024]`; often uniform early-out already helps |
| S02 | `wire/stock_chunk.zig` `encodeNetworkChunk` block layer ~150-205 | any-air scan + lower/upper pack | 64×1024 u32 | **Y** stream | **high** | **P1** | `any` scan and uniform detect are pure maps; packing is byte extract |
| S03 | `wire/stock_chunk.zig` `writeTextureChannel` ~375-414 | textureFull u64 per cell → 6 planes | 64×1024 u64 | **Y** stream | med-high | **P1** | Plane extract is shift+truncate; good SIMD; watch LE |
| S04 | `world/worldgen.zig` `fillHeights` ~53-62 | 16×16 height from noise | 256 f32→u8 | proc stream | **high** | **P1** | Batch coords; **must** stay seed-bit-identical (see determinism) |
| S05 | `world/worldgen.zig` `generateChunkBlocks` ~71-87 | column stamp into blocks[] | 256×H u32 | proc | med | **P2** | Inner y loop short; outer 256 columns; `@memset` already |
| S06 | `world/noise.zig` `fbm2`/`ridged2` | octave sums | few octaves | via S04 | med | **P2** | Better to batch **cells** than SIMD inside one noise2 (branchy lattice) |
| S07 | `world/noise.zig` `noise2`/`contrib2` | simplex contrib | 1 sample | via S04 | low alone | **P2** | SIMD as 4-8 independent (x,y) samples, not inside grad |
| S08 | `ecs/systems.zig` `nearestPlayerSnap` ~52-70 | dx²+dz² min over players | P≪16 | tick AI | med | **P2** | Tiny P; SIMD only if many zombies × players matrix |
| S09 | `ecs/systems.zig` despawn / quest range loops | dist_sq vs radius | max_entities | tick | med | **P2** | SoA x/z columns; mask alive first (bitset) |
| S10 | `ecs/interest.zig` `observerMask` | entity cell vs all client cells | max_clients (64) | tick | med | **DONE** | `@Vector(64, i32)` compares reduced to one observer word; `observerMaskRef` is the scalar oracle |
| S11 | `ecs/systems.zig` AI full tick | FSM + A* | entities | tick | **low** | **Reject** | Divergent branches; use `parallel.forRanges` only |
| S12 | `ecs/path.zig` A* | graph search | expands | chase | **low** | **Reject** | Irregular; not SIMD |
| S13 | `wire/binary.zig` 7-bit strings | varint strings | var | net | **no** | **Reject** | |
| S14 | `assets/*` XML parse | text | init | **no** | **Reject** | |
| S15 | `world/store.zig` save/load | memcpy blocks | disk | init/save | low | **P3** | `@memcpy` enough |
| S16 | Dirty bit words | scan u64 bits | words | tick | med | **P3** | Bit-parallel `@ctz` loop; not classic SIMD |
| S17 | `world/biomes.zig` / DTM sample | grid sample | map load / query | sometimes | med | **P2** | If profiling shows cost |
| S18 | DEM height math | tile samples | stream | med | **P2** | After DEM hot in apm |
| S19 | Light channel fill | if uniform clears | chunk | stream | low | **P3** | Often `@memset` |

---

## Top recommended wins

### 1. S01 Density channel fill (P1)

**Where:** `writeDensityChannel` builds `dens: [1024]u8` then uniform check.

**Sketch:**

- Scalar `densityAt` stays source of truth (TTS override + `densityForBlock`).
- Optional: after filling dens (or while filling), uniform check via `@Vector(16, u8)` compare to `dens[0]` with early exit on mismatch (already short-circuits somewhat).
- Stronger win if `blockAt` is dense u32 SoA: vector load types, compare air/terrain masks, `select` density_air vs density_terrain (override path still scalar).

**Test:** random chunk blocks → SIMD dens bytes == scalar dens bytes for all 64 layers.

**Risk:** low if golden is byte-identical. TTS `dens_at` hook forces scalar fallback when non-null.

### 2. S02 Block layer any + pack (P1)

**Where:** nested lx/lz/ly loops for `any` and lower/upper arrays.

**Sketch:**

- **any-air:** OR-reduce `blockType(raw) != 0` over 1024 cells (vector cmp + `@reduce(.Or, …)`).
- **uniform:** same as density.
- **pack lower:** `@truncate` vector of u32 → u8 (when no upper bits).
- Upper24 interleaved layout may stay scalar (strided stores).

**Test:** fixture chunks (flat air, flat stone, mixed POI ids with rotation bits) payload equality.

### 3. S03 Texture planes (P1)

**Where:** `vals[1024]u64` then 6 planes of 1024 bytes.

**Sketch:** for each plane j, vector shift/truncate stores; 1024/16 = 64 iters.

**Test:** painting defaults vs mixed textureFull.

### 4. S04 Worldgen heights (P1, proc only)

**Where:** `fillHeights` 256 independent `heightAt` calls.

**Sketch:** process 4–8 columns per batch only if each `heightAt` is pure and order of f32 sums **inside** one sample stays scalar (current octave loop order). Do **not** change reduction order of fbm octaves.

**Test:** existing `worldgen determinism same seed and chunk` must pass; add SIMD vs scalar `fillHeights` equality for seeds `{1,7,12345}` and chunks `{(0,0),(3,-2)}`.

**Risk:** medium (f32). Prefer batching **integer** post-process only if noise stays scalar first.

---

## Rejects (explicit)

| Item | Why |
|---|---|
| Full zombie AI / attack SM | Divergent control flow |
| A* pathing | Graph, irregular expand |
| LiteNet / package framing | Protocol, branches |
| 7-bit string binary | Variable length |
| XML / config load | Init, text |
| Replacing `@memcpy` of whole chunk buffers | Already optimal enough |
| SIMD "framework" or runtime CPU dispatcher v1 | YAGNI; start portable `@Vector(8/16)` |

---

## Determinism policy (worldgen)

STATUS/TODO claim seed-stable proc gen. For any SIMD touching noise:

1. Golden: scalar `heightAt` / `fillHeights` reference.
2. SIMD path must `expectEqualSlices` on heights for fixed seeds.
3. Prefer SIMD only on **independent cells**; keep per-cell f32 graph identical to scalar (same octave count and sum order).
4. If platform FMA differs, freeze scalar noise and only SIMD integer packing elsewhere (S01-S03 safer).

---

## Implementation order (when unparked)

1. S01 density uniform + fill goldens (integer, stream-hot).
2. S02 any-air / lower pack goldens.
3. S03 texture planes if apm shows texture channel cost.
4. S04 height batch only with strict seed tests; else skip until proc is default play path.
5. S09/S10 SoA dist if 128-bot loadgen shows AI/interest in apm.

Do **not** start with noise internals (S06/S07) before S01-S03.

---

## Interaction with other reviews

| Review | Link |
|---|---|
| Hot-path no-alloc | SIMD temps stack-only; no dens heap |
| Abstractions | One helper e.g. `densityLayerFill` in `stock_chunk.zig` or `util/simd_density.zig` only if 2+ call sites |
| parallel.forRanges | Chunk encode stays single-threaded per chunk today; SIMD **inside** encode; multi-chunk parallel is separate M11 workers item |
| apm | Add/keep section around `encodeNetworkChunk` if implementing |

---

## Suggested apm / validation

Before implementing, capture one soak with chunk stream heavy (join + fly):

- time in chunk body build vs interest vs AI
- If density/block loops are not visible, demote S01-S03 to P2

After implementing: `make check` + loadgen join smoke + one proc `--worldgen-seed` explore if S04 lands.

---

## Success checklist (this pass)

- [x] Candidates with path-level anchors and severity
- [x] Top wins sketched with golden plan
- [x] Rejects listed
- [x] No hot-path alloc recommendations
- [x] No code change (review only)
- [x] No em dashes / AI attribution
