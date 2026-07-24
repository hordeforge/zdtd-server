# Procedural world generation (design)

Design for a stateless, high-throughput procedural voxel generator for zdtd:
realistic terrain, generated on demand per 16-wide chunk, as a pure function of
`(seed, position)` so it shards trivially and caches cheaply. Complements the
real-DEM streamer (`src/world/dem.zig`, Copernicus GLO-30); see the blend policy
below.

Status: design only. No generator code yet. This doc is the plan; each section
tags what is a verified research finding vs reasoned inference (deep-research
2026-07-23, 24/25 claims confirmed by 3-vote adversarial verification).

## Design goals

- **Stateless pure function.** `block(seed, x, y, z)` depends only on inputs, no
  global RNG. This is the load-bearing property: it makes generation shardable
  (any region server regenerates any cell identically), cache-friendly, and
  reproducible. Position-based hashing (wyhash / splitmix64 of `(seed,x,y,z)`)
  replaces any seeded-stream RNG.
- **On demand, per chunk.** Fits the existing `world/store.zig` `getOrCreate`:
  generate a chunk's block columns when first touched, feed the stock chunk wire
  (`wire/stock_chunk.zig`), unchanged.
- **Realistic.** Continents, oceans, mountains, biomes, caves, rivers, that read
  as a plausible world, not noise mush.
- **20 TPS budget.** Generation must not stall the tick; runs off-tick / on a
  worker pool (like `parallel.forRanges`), results cached to `.zch2`.

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

## 7. Performance and architecture

- **Pure `(seed,pos)` => chunk-parallel + shardable** (verified LOD/statelessness,
  3-0; Distant Horizons, binary-greedy-meshing). Generate chunks on a worker
  pool; cache RAM -> `.zch2` disk -> (planet scale) object store. Any shard
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
    pub fn columnBlocks(self, cx, cz, out: *[16*256*16]u16) void { ... }
    fn finalDensity(self, x, y, z) f32 { ... }   // coarse-cell + interpolate
    fn climate(self, x, z) Climate { ... }        // cache_2d per column
    fn biomeAt(self, c: Climate, depth) Biome { ... } // 6D nearest hypercube
};
```

- Wire into `world/store.zig` `getOrCreate` as a terrain source alongside DEM and
  flat: `heights`/`blocks` filled from `worldgen.columnBlocks` when the world is
  in procedural mode. Block-id selection per biome + depth (topsoil/dirt/stone/
  biome surface). Stock chunk wire (`stock_chunk.zig`) unchanged; the texture
  channel (already wired) carries paint for painted blocks.
- Parallelize generation with the existing worker pattern; cache to `.zch2`.

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

- **W1** Zig OpenSimplex2 + fBm/ridged + domain warp; unit tests (determinism,
  no-global-state, artifact spot-checks).
- **W2** 3D density field + coarse-cell interpolation + `y_clamped_gradient`;
  single-biome terrain into `store.zig`, stock chunk wire.
- **W3** 6-axis climate + continentalness/erosion/PV splines; biome surface
  blocks; nearest-hypercube biome lookup.
- **W4** caves (cheese/spaghetti/noodle) + aquifers.
- **W5** deterministic feature/POI placement (per-cell hash), cross-boundary
  resolution, `.tts` stamp.
- **W6** DEM blend policy + boundary feathering; procedural detail on DEM base.
- **W7** far-terrain LOD sampling for planet-scale streaming (ties to
  `docs/PLANET_SCALE.md`).

## Sources

Primary: FastNoise2, OpenSimplex2, iquilezles.org/warp, binary-greedy-meshing,
Distant Horizons, No Man's Sky GDC 2017, US Patent 11,810,252. Secondary
(community wiki, tracks the engine JSON schema, cross-checked vs Fabric):
minecraft.wiki Density_function / Noise_router / Noise_settings / World_generation
/ Cave-Aquifer. Blog/reference: noiseposti.ng, redblobgames, devmag Poisson-disk.
Full verification log: deep-research run 2026-07-23 (24/25 claims 3-0 confirmed).
