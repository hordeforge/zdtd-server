# Procedural world generation (design)

**Product model: on-the-fly streaming gen**, not a static full-map bake.

Minecraft-style infinite (or huge) worlds: the server never materializes the
whole map up front. As players move, interest/stream requests chunks; each
missing chunk is **generated at request time** from `(seed, chunkX, chunkZ)`,
encoded with the existing stock `NetPackageChunk` path, then cached. Same seed
+ coords always yield the same blocks (regenerate after cache drop = identical).

Design for a stateless, high-throughput procedural voxel generator for zdtd:
realistic terrain, generated on demand per 16-wide chunk, as a pure function of
`(seed, position)` so it shards trivially and caches cheaply. Complements the
real-DEM streamer (`src/world/dem.zig`, Copernicus GLO-30); see the blend policy
below.

Status: **W0/W1/W2 landed** (`src/world/noise.zig`, `src/world/worldgen.zig`,
`TerrainSource.proc` in `store.zig`, `--worldgen-seed`). W2b+ still design.
Each section tags verified research vs reasoned inference (deep-research
2026-07-23, 24/25 claims confirmed by 3-vote adversarial verification).

## Design goals

- **On-the-fly, not prebaked.** No "generate world then host" step for the
  procedural mode. Generation is a **runtime terrain source** inside
  `World.getOrCreate` / the chunk stream pipeline. Optional offline bake tools
  may exist later for ops; they are not the play path.
- **Stateless pure function.** `block(seed, x, y, z)` depends only on inputs, no
  global RNG. Load-bearing: shardable (any region server regenerates any cell
  identically), cache-friendly, reproducible. Position-based hashing (wyhash /
  splitmix64 of `(seed,x,y,z)`) replaces any seeded-stream RNG.
- **Demand-driven per chunk.** Player move / interest → miss in RAM → miss on
  `.zch3` disk → **run worldgen for that chunk only** → fill store → stock wire
  send. Fits `world/store.zig` `getOrCreate` + existing stream caps
  (`max_streamed_chunks`, adds/tick). Prefetch a ring ahead of the player on
  workers so gen latency does not stall the 50 ms tick.
- **Cache is an optimization, not the source of truth.** Order: RAM chunk →
  disk overlay (player edits + first-touch gen) → pure regen from seed. Edits
  always win over regen (persist dig/build in `.zch3` / blockmeta).
- **Realistic.** Continents, oceans, mountains, biomes, caves, rivers that read
  as a plausible world, not noise mush.
- **20 TPS budget.** Never run unbounded gen on the main tick. Worker pool +
  named caps; apm section on gen wait / queue depth. Drop or delay stream adds
  rather than blow the tick (same discipline as chunk stream today).
- **Baked maps remain first-class.** Navezgane / Pregen / DEM modes stay. Proc
  mode is another `World` terrain backend, selected by CLI/config, not a fork
  of the net/sim stack.

## Runtime pipeline (streaming)

```text
  peer interest / stream ring
           |
           v
  store.getOrCreate(cx,cz)
           |
     +-----+------+
     | RAM hit?   | yes --> encode stock chunk --> send
     +-----+------+
           | no
           v
     load .zch3 / overlay?  yes --> materialize --> send
           | no
           v
     worldgen.generateChunk(seed, cx, cz)   // pure, may be async worker
           |
           v
     apply POI/WFC stamps that touch this chunk (deterministic neighbors)
           |
           v
     insert RAM + optional disk cache --> stock_chunk wire --> client
```

**Concurrency:** main tick only dequeues finished gen jobs and sends; workers
own noise/density/WFC. Cross-chunk features (POI radius, WFC boundary) must
still be pure functions of seed + coords so two workers never disagree.

**Unload:** far chunks may leave RAM; disk cache optional. Re-entry regenerates
or reloads; player mutations must have been persisted or they are lost (same
as baked worlds today).

**Not this design:** stock dedicated RWG "create world" wizard that writes a
full `Data/Worlds/...` tree before listen. zdtd proc mode **listens first**,
generates as explored.

## 1. Noise foundation

- **Use OpenSimplex2-family gradient noise, not Perlin/value noise** (verified,
  3-0). Perlin and value noise are visibly square-biased: features align to
  45/90 degrees on the cubic lattice. OpenSimplex2F ("fast", Simplex-like) for
  general fields; OpenSimplex2S ("smooth") for ridged layers (`abs(x)` stacks).
  Sources: KdotJPG/OpenSimplex2, noiseposti.ng "The Perlin Problem".
- **Composition:** fBm (sum of octaves, freq x2 / amp x0.5), ridged multifractal
  (`1 - abs(noise)` per octave) for mountains, billow for hills.
- **Domain warping** for organic, non-griddy shapes (verified, 3-0): evaluate
  `f(p + h(p))` where `h` is an fBm-derived displacement, applied recursively:
  `fbm(p + 4.0*q)`, `q = fbm(p + ...)`, then again from the warped domain.
  Source: Inigo Quilez, iquilezles.org/articles/warp.
- **SIMD throughput** (verified, 3-0): FastNoise2 (AVX2) does ~261 M pts/s 3D
  Perlin, ~268 M 3D Simplex, ~5-7x FastNoise Lite (single-author benchmark,
  Intel 7820X; treat ratio as authoritative, absolute numbers hardware-specific).
  Source: github.com/Auburn/FastNoise2.
  - **Zig options:** (a) port OpenSimplex2 to Zig with `@Vector` SIMD (keeps the
    clean-room, no-C-dep property; preferred), or (b) FFI to FastNoise2. Start
    with a scalar Zig OpenSimplex2, add `@Vector` batching per chunk column once
    correct. Reasoned inference (no verified Zig-specific source).

## 2. Terrain as a 3D density field (not a heightmap)

Model terrain like Minecraft 1.18+ (Caves and Cliffs), which replaced the old
heightmap approach (verified, 3-0; sources: minecraft.wiki Noise_router /
World_generation / Noise_settings):

- `final_density(x,y,z) > 0` -> solid (default block); else air or fluid (aquifer
  decides). Terrain height emerges from adding a **clamped Y-gradient**
  (`y_clamped_gradient`: solid low, air high) to horizontally-varying 3D noise,
  so **overhangs and 3D shapes fall out naturally**.
- Compose `final_density` from a **noise router**: a tree of reusable
  density-function primitives (`noise`, `shifted_noise`, `spline`, `add/mul/
  min/max/clamp/abs/cube/square/lerp/range_choice/y_clamped_gradient`). In zdtd
  these are plain Zig functions over `(x,y,z)` returning `f32`, composed by data
  or code. (verified, 3-0; minecraft.wiki Density_function.)
- **Caching is mandatory** to afford a 3D field (verified, 3-0):
  - `cache_2d`: compute per horizontal `(x,z)` once (climate, continentalness).
  - `flat_cache`: per 4x4 column at `y=0`.
  - `interpolated`: sample the expensive 3D density on a **coarse cell grid** and
    trilinearly interpolate per block. Minecraft samples at cell size
    `4*size_horizontal` x `2*size_vertical` blocks (defaults 1/2) and interpolates
    (verified, 3-0). For a 16-wide chunk this is a handful of noise columns plus
    interpolation, not 4096 full evaluations.
- **Y range:** 16-aligned, like Minecraft's `min_y=-64, height=384` (both
  divisible by 16). zdtd's ~256 Y fits the same sectioned model (verified, 3-0).

### What W2 actually shipped

`src/world/worldgen.zig` implements this section for a single biome:

- `columnTarget(x, z)` is the `cache_2d`: the W1 2D shaping stack (continental
  fBm + ridged + domain-warped detail), clamped to
  `[min_surface + margin, max_surface - margin]` = `[48, 164]`.
- `cellDensity` = `clamp((target - y) / squash, -1, 1) + 0.85 * clamp(fbm3, -1, 1)`
  with `squash = 28` and the noise stretched vertically (`y_scale = 2.0`,
  4 octaves at frequency 0.02). Both clamps are load-bearing: with weight < 1
  they make "solid well below target, air well above" a hard guarantee, and
  `margin = squash + cell_h = 36` is that guaranteed band's half-width.
- `interpolated`: cell size **4 x 8 x 4** blocks, so 5x5x33 = **825** fBm samples
  per chunk instead of 65536, trilinearly interpolated per block by one shared
  `trilerp`.
- The coarse grid is snapped in **world** coordinates (`@divFloor(wx, 4)`), and
  16 is a multiple of 4, so adjacent chunks share sample planes exactly. A chunk
  fill is bit-identical to the standalone `density(wx, wy, wz)` oracle, which
  makes "no seams across chunk borders" structural, not incidental, and testable.
- Heights are the topmost solid block, matching stock `Chunk::RecalcHeightAt`
  (asm.il:1104654), so overhangs are representable in the existing heightmap.
- Parameters were picked from measurement, not taste: at `squash = 12`,
  `y_scale = 0.5`, frequency 0.01 the field degenerates to a heightmap (0%
  overhang columns). The shipped values give **12.4%** of columns more than one
  solid run.
- Cost: **126 us/chunk** ReleaseFast, **1.7 ms/chunk** Debug (a naive per-block
  3D field is ~5.5 ms). At `chunk_adds_per_stream_tick = 8` that is ~1 ms/tick
  release, ~14 ms/tick Debug. Watch it via the apm `chunk_gen` section; the fix
  for Debug-with-many-clients is W2b (async workers), not a raised cap.

Not in W2 (honest gaps): biome climate (W3); carved caves (W4); POIs (W5).
Surface material is applied per column from its topmost solid block, so overhang
shelves and cave ceilings expose stone; run-aware surfacing belongs with W3.

Shipped W4 (2026-08-20): the water table. `fillWaterTable` fills every column
whose surface sits below the stock water level (RE `Block.cWaterLevel` 62.88,
surface cell 62) with water up to that cell, after the material pass. The
surface cell is a world-constant, so adjacent chunks agree by construction and
cannot seam. Not ported: per-lake `waterRect` sources and shore falloff, lava
lakes (section 4 keeps those as future work), water flow.

## 3. Biomes: multi-axis climate

Select biomes from a 6-axis climate model (verified, 3-0; minecraft.wiki
World_generation), the practical realization of a Whittaker temperature/
precipitation diagram extended with continentalness and erosion:

| Axis | Role |
|---|---|
| temperature | hot/cold band (also latitude when Earth-scale) |
| humidity (vegetation) | wet/dry |
| **continentalness** | ocean vs beach vs inland; higher = more inland, higher avg height |
| **erosion** | flatness; high erosion = flat, low = hilly/mountainous |
| weirdness (peaks-and-valleys) | ridge variants, biome variety |
| depth | Y relative to surface; enables 3D cave biomes |

- Biome lookup = **nearest-point search in the 6D climate hypercube** (each biome
  owns a hypercube of parameter ranges). Cross-checked vs Fabric
  `MultiNoiseUtil.NoiseHypercube`.
- **Splines** map continentalness / erosion / peaks-valleys to a terrain-shape
  offset fed into the density field (cubic splines; the "spline" density
  primitive). Continentalness drives continents-vs-oceans; erosion drives
  plains-vs-mountains.
- Note (refuted claim): the climate noises are **not** purely decorative; they
  can also feed terrain shape. Do not hard-separate biome noise from density
  noise.
- **Smooth blending:** interpolate block/material choice across the climate
  field rather than hard Voronoi edges (reasoned inference; redblobgames
  "terrain from noise" as practical reference, not a verified claim here).

## 4. Caves and 3D features

Generate caves as separate 3D noise fields subtracted from `final_density`
(verified, 3-0; minecraft.wiki Cave/Aquifer):

- **Cheese caves:** large open pockets (white-noise regions become air).
- **Spaghetti caves:** long narrow winding tunnels from noise edges.
- **Noodle caves:** thinner, 1-5 blocks wide.
- **Aquifers:** one unified liquid system generates nearly all liquids (carvers,
  noise caves, rivers, oceans) from a separate 3D water-level noise field; lava
  lakes excepted. Implement as a per-position water table vs `final_density`.
- **Ore distribution:** additional 3D noise / per-cell deterministic placement by
  depth band (reasoned inference).

## 5. Rivers, oceans, coastlines, erosion

- **Oceans/coastlines:** continentalness < threshold = ocean; feather the coast
  via the continentalness spline (verified for continentalness role, 3-0).
- **Erosion for realism:** two options.
  - **Noise-approximate (Minecraft way):** the erosion axis + splines fake
    erosion with no simulation. Cheap, stateless, streams on demand. Default.
  - **Offline hydraulic/thermal erosion bake:** simulate droplets on a
    continental heightfield offline, store the eroded heightfield, sample it at
    runtime. More realistic valleys/ridges but breaks the pure `(seed,pos)`
    property and needs storage. Use only for a fixed hero region, not the
    streaming planet. (Erosion-sim tradeoff is **reasoned inference**, not a
    verified finding; sources nickmcd.me / jobtalle.com procedural hydrology are
    unverified here.)
- **Plate-tectonics-inspired continents:** low-frequency continentalness as
  continent plates (reasoned inference; redblobgames planet-generation).

## 6. Structure / feature placement (no global state)

Place POIs/features deterministically per cell, no global RNG (verified concept
for Poisson-disk, 3-0; devmag.org.za Poisson-disk, and a Bridson O(n) paper):

- Partition the world into cells; hash `(seed, cellX, cellZ)` to a jittered point
  (jittered grid) or a per-cell Poisson-disk candidate for blue-noise spacing.
- **Cross-chunk resolution:** when generating a chunk, also evaluate neighbor
  cells whose feature radius reaches into it, so a structure straddling a chunk
  boundary resolves identically from either side (each chunk is generated
  independently but sees the same deterministic neighbor candidates).
- This is exactly how zdtd's existing prefab stamping should feed: candidate POI
  -> `.tts` paint into the chunk (`world/tts.zig`).

### 6.1 Wave Function Collapse / tile layout (settlements, not terrain)

**Terrain** stays density-noise (sections 1-5). **WFC (and cousins) are for
discrete layout**: roads, district tiles, interior room graphs, prefab
neighborhoods. Do not run WFC per-block for continents; that is the wrong tool.

| Layer | Algorithm | Output |
|---|---|---|
| Continents / height / caves | OpenSimplex2 + density router (MC 1.18+) | solid/air/fluid per block |
| Biome surface / ore | climate axes + depth rules | block ids via AssignIds names |
| Settlement / trader strip / downtown | **WFC or model synthesis** on a tile grid | which prefab/tile occupies each cell |
| Single POI stamp | deterministic cell hash + `.tts` | blocks into chunk store |

**WFC sketch (zdtd-owned, clean-room):**

1. **Tiles** = stock RWG-style tiles and/or zdtd tile defs: edge tags
   (road_N/E/S/W, wall, open, water), footprint in chunks, prefab name list.
   Prefer reading stock `rwgmixer.xml` / tile prefab metadata when present;
   never invent block ids (AGENTS rule 15).
2. **Grid** = coarse cells (e.g. 1 cell = 1 RWG tile or N chunks). Seeded
   Shannon entropy collapse: pick lowest-entropy cell, pick weighted tile via
   `hash(seed, cell)`, propagate adjacency constraints.
3. **Determinism:** full collapse of a region must be a pure function of
   `(seed, region_origin, tile_set)`. Neighbor regions that overlap must agree
   on shared boundary cells (same cross-boundary rule as POI placement).
4. **Failure:** if contradiction, backtrack limited depth or regenerate cell
   with next hash salt; never leave illegal adjacency on the wire.
5. **Stamp:** resolved tile -> prefab `.tts` / parts via existing TTS path.
6. **Alternatives when WFC is heavy:** Wang tiles / edge-matched random walk
   (faster, less expressive); stock-like hub-and-spoke road graph + Poisson POI
   (W5) as MVP before full WFC.

**Non-goals for WFC:** replacing biomes.xml colors, faking Navezgane, or
shipping a second block id space. Stock RWG C# pipeline is **not** a host
target; this is a Zig reimplementation of the *idea* (seeded infinite map +
prefab stamps), not a DLL callout.

**References (layout, not terrain):** Maxim Gumin WFC; Paul Merrell model
synthesis; Oskar Stalberg (Townscaper) tile grammars; stock 7DTD RWG tile/hub
docs in research when cited. Treat adjacency rule extraction from stock XML as
an RE task under `../7dtd-engine-research`, implementation under `src/world/`.

## 7. Performance and architecture

- **Pure `(seed,pos)` => chunk-parallel + shardable** (verified LOD/statelessness,
  3-0; Distant Horizons, binary-greedy-meshing). Generate chunks on a worker
  pool; cache RAM -> ZCH3 `.zch` disk -> (planet scale) object store. Any shard
  regenerates any cell identically, no cross-shard coordination.
- **Coarse-cell density + interpolation** (section 2) is the main throughput
  lever.
- **Meshing / LOD are client-side** (zdtd is the server; the stock client meshes
  from the chunk wire). Relevant only for future far-terrain streaming: binary
  greedy meshing (~50-200us per 64^3 chunk, do not transplant the absolute number
  to 16-wide chunks; verified 3-0) and Distant-Horizons-style LOD by sampling the
  same density field on a coarse grid (verified 3-0).
- **Reference pipelines:** No Man's Sky (GDC 2017) layered-noise + polygonization;
  Minecraft 1.18+ density functions. Both confirm the layered-noise -> density ->
  surface pipeline.

## 8. Mapping onto zdtd

New module `src/world/worldgen.zig`:

```
pub const WorldGen = struct {
    seed: u64,
    // density-function tree (climate + continentalness/erosion splines + caves)
    pub fn heightAt(self, wx, wz) u16 { ... }
    pub fn fillHeights(self, cx, cz, out: *[256]u8) void { ... }
    pub fn generateChunkBlocks(self, cx, cz, blocks: []u32) void { ... }
    fn finalDensity(self, x, y, z) f32 { ... }   // coarse-cell + interpolate
    fn climate(self, x, z) Climate { ... }        // cache_2d per column
    fn biomeAt(self, c: Climate, depth) Biome { ... } // 6D nearest hypercube
};
```

- Wire into `world/store.zig` `getOrCreate` as a terrain source alongside DEM and
  flat: on cache miss in procedural mode, call `worldgen` for that chunk only
  (sync stub first; then async job + stream wait). `heights` filled via
  `wg.fillHeights`; blocks via `ensureBlocksWithStack(biome_layers.defaultStack())`
  in `store.zig`. Block ids via biomes.xml names + AssignIds. Stock
  chunk wire (`stock_chunk.zig`) unchanged.
- Stream path (`game.zig` chunk interest) unchanged at the package layer: it
  already demand-loads via `getOrCreate`. Proc mode only changes what miss
  means (gen vs heightmap/TTS).
- Parallelize with existing worker pattern; cache RAM then `.zch3`. Never
  require a full-map prepass before `zdtd` accepts joins.

## 9. Procedural vs real-DEM (blend policy)

zdtd has both a real-DEM heightfield (`dem.zig`, GLO-30, proven live to Mont
Blanc 4365m) and this procedural generator. Policy (this is the research's
**biggest open question** with **no verified source**; treat as reasoned
inference, seed for a follow-up):

- **Base heightfield from DEM where real coverage exists** (continents, real
  mountains): DEM gives the macro landform for free at ~30m posts.
- **Procedural supplies sub-30m detail** the DEM cannot: surface roughness,
  overhangs, caves, ore, biome surface, features. Add procedural detail noise on
  top of the DEM base height.
- **Out-of-coverage / fictional regions: fully procedural** (continentalness +
  erosion + splines).
- **Boundary blending:** feather the DEM base into procedural continentalness so
  coverage edges are seamless (analogous to seamless-heightfield stitching, US
  Patent 11,810,252, primary source but a patent, not a game technique). Blend
  weight = distance-to-coverage-edge.
- Y=256 client cap still applies to tall DEM terrain; see `docs/MAPS.md` and the
  RealEarth opt-in YDim mod.

## 10. Honest gaps (verified-vs-inferred)

Per the missing-over-fake principle, the following are **reasoned inference, not
verified findings** (deep-research could not confirm a source): the exact
stateless hashing scheme (wyhash vs splitmix64 vs seeding SIMD noise directly),
GPU-side generation tradeoffs, hydraulic/thermal erosion bake-vs-noise, plate
tectonics, Voronoi biome-blend specifics, structure-placement method choice, and
crucially the **real-DEM/procedural fusion** method. Prototype and measure these;
do not present them as settled.

## Milestones

Parked behind join/play fidelity and M11 CPU unless explicitly unparked.
Baked Navezgane / Pregen remain available; **proc mode is live stream gen**.

- **W0** Terrain-source enum on `World` (`flat` | `baked` | `dem` | `proc`);
  `getOrCreate` miss → proc generate one chunk; join with empty disk works;
  stream ring exercises gen under loadgen (no full prebake).
- **W1** Zig OpenSimplex2 + fBm/ridged + domain warp; unit tests (determinism,
  no-global-state, artifact spot-checks).
- **W2** 3D density field + coarse-cell interpolation + `y_clamped_gradient`;
  single-biome terrain into `store.zig` on the fly; stock chunk wire.
- **W2b** Async gen queue + prefetch ring + apm (`worldgen_queue`, wait ns);
  main tick never blocks on multi-chunk gen.
- **W3** 6-axis climate + continentalness/erosion/PV splines; biome surface
  blocks from biomes.xml names via AssignIds; nearest-hypercube biome lookup.
- **W4** caves (cheese/spaghetti/noodle) + aquifers.
- **W5** deterministic feature/POI placement (per-cell hash), cross-boundary
  resolution, `.tts` stamp at first touch (MVP settlements without WFC).
- **W5b** tile WFC / edge-matched layout for trader strips and districts; stamp
  stock prefabs on demand when the settlement cell is first needed; optional
  `rwgmixer`-driven weights when RE allows.
- **W6** DEM blend policy + boundary feathering; procedural detail on DEM base
  (still streamed per chunk).
- **W7** far-terrain LOD sampling for planet-scale streaming (ties to
  `docs/SCALE.md`).

**CLI / world mode:** `--worldgen-seed <u64>` (implies proc terrain source;
see `src/main.zig`) or serverconfig keys in GAME_OPTIONS; flat and baked map
modes stay. World dir holds **overlays + cache only**, not a mandatory full
export.

## Sources

Primary: FastNoise2, OpenSimplex2, iquilezles.org/warp, binary-greedy-meshing,
Distant Horizons, No Man's Sky GDC 2017, US Patent 11,810,252. Secondary
(community wiki, tracks the engine JSON schema, cross-checked vs Fabric):
minecraft.wiki Density_function / Noise_router / Noise_settings / World_generation
/ Cave-Aquifer. Blog/reference: noiseposti.ng, redblobgames, devmag Poisson-disk.
Full verification log: deep-research run 2026-07-23 (24/25 claims 3-0 confirmed).
