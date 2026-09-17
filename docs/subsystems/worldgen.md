# Procedural world generation

This subsystem generates a world without stock map data. It owns terrain
synthesis from a pure function of `(seed, chunkX, chunkZ)`, the assignment of a
biome and of stock subbiomes, the surface material stack taken from
`biomes.xml`, and the water table that fills basins. Its boundary is the block
plane and the height plane it hands to the world store: it does not read stock
DTM or `prefabs.xml`, does not encode packages, and does not place POIs, roads
or settlements. `src/world/root.zig:3` fixes the import direction - the `world`
package may import `util` and `assets` and may use pure `ecs` component types,
and must not import `wire`, `server` or `litenet`. Consumers are therefore
`src/world/store.zig` inside the same package, plus the `server` chunk path
(`src/server/game/chunk_fill.zig`, `src/server/game/deco.zig`) which imports
`world`; nothing here is reachable from the wire layer.

Sources: [`src/world/worldgen.zig`](../../src/world/worldgen.zig), [`src/world/noise.zig`](../../src/world/noise.zig), [`src/world/subbiome_noise.zig`](../../src/world/subbiome_noise.zig), [`src/world/biomes.zig`](../../src/world/biomes.zig), [`src/world/prefabs.zig`](../../src/world/prefabs.zig), [`src/world/store.zig`](../../src/world/store.zig)

## Where generation sits in the pipeline

A world has one terrain source. The enum documents the four options and which
one generation corresponds to (src/world/store.zig:25):

```zig
pub const TerrainSource = enum {
    /// Constant sea_level columns (default empty world).
    flat,
    /// Stock DTM / prefabs / water from loadStockMap.
    baked,
    /// Copernicus DEM streamer (future seam; heights via heightmap when set).
    dem,
    /// Procedural noise from worldgen seed.
    proc,
};
```

`World.enableProc` selects `proc` and tears down the baked backends: the
heightmap, the prefab index, the water sources, the biomemap and the map
directory are all released, and the spawn point is re-derived from the
generated surface at `(256, 256)` because a proc world ships no spawnpoints
(src/world/store.zig:666). `--worldgen-seed` calls it during `Game` init
(src/server/game.zig:1171), and a seed may not be combined with `--map`
(src/main.zig:443) or with a non-stock wire profile (src/main.zig:955).

On the first touch of a chunk, `World.getOrCreate` loads the disk overlay
first; only on a miss does it branch on `terrain_source` and call
`Chunk.generateProc` for the stock geometry profile (src/world/store.zig:902).
The per-chunk generation runs synchronously inside `sendSpawnChunk`, wrapped in
the apm `chunk_gen` section, and is paced by `chunk_adds_per_stream_tick`
(src/server/game/chunk_fill.zig:40, src/server/game/types.zig:67). No worker
pool is involved: the async gen queue is the parked W2b milestone
(docs/GAP_ANALYSIS.md:657).

## Seeding and determinism

`WorldGen` holds the seed and the shaping parameters that the store overlays
from `[rules.worldgen]` (src/world/worldgen.zig:212):

```zig
pub const WorldGen = struct {
    seed: u64,
    noise: noise_mod.Noise,
    base_height: f32,
    height_amp: f32,
    min_surface: u8,
    max_surface: u8,
    squash: f32,
    noise_weight: f32,
    y_scale: f32,
    bedrock_h: i32,
    margin: f32,
    biome_n: u8 = 0,
    biome_table: ?*const biome_layers.Table = null,
    air_id: u16 = assignids.air,
    stone_id: u16 = assignids.terr_stone,
    dirt_id: u16 = assignids.terr_dirt,
    bedrock_id: u16 = assignids.terr_bedrock,
    forest_id: u16 = assignids.terr_forest_ground,
```

The noise state is a 256-entry permutation table plus the seed, and the table
is shuffled once from the seed by a splitmix64 stream, so no call order can
leak into a result (src/world/noise.zig:7):

```zig
pub const Noise = struct {
    perm: [256]u8,
    seed: u64,
```

`WorldGen.applyParams` copies the `[rules.worldgen]` group onto the generator
and recomputes `margin = squash + cell_h` (src/world/worldgen.zig:265). The
store applies it from the effective rules at `enableProc`
(src/world/store.zig:680), and the group is validated fail-closed before use:
`min_surface >= max_surface`, `noise_weight >= 1` and a non-positive `squash`
are rejected (src/main.zig:944, src/ecs/rules.zig:648). Seed precedence is CLI
`--worldgen-seed`, then `zdtd.toml [worldgen] seed`, then the preset pack value
(src/main.zig:908). The subbiome noise is seeded separately: a proc world uses
its own seed, a baked world uses `GetStableHashCode(worldName)`
(src/server/game.zig:1181).

## The density field

Terrain is a field, not a heightmap: a column target supplies a clamped
Y-gradient, 3D fBm perturbs it, and the sign of the sum is solidity
(src/world/worldgen.zig:129):

```zig
fn cellDensity(self: *const WorldGen, target: f32, wx: f32, wy: f32, wz: f32) f32 {
    const grad = std.math.clamp((target - wy) / self.squash, -1, 1);
    const n3 = std.math.clamp(noise_mod.fbm3(&self.noise, wx, wy * self.y_scale, wz, density_p), -1, 1);
    return grad + self.noise_weight * n3;
}
```

Affordability comes from two caches: the 2D shaping stack is evaluated once per
coarse column, and the 3D field is sampled on a coarse corner grid and
trilinearly interpolated per block. The per-chunk grid is a plain struct on the
stack (src/world/worldgen.zig:138):

```zig
const Sampler = struct {
    cache2d: [samples_x * samples_x]f32,
    samples: [samples_x * samples_x * samples_y]f32,
    margin: f32,
```

The cell size is 4 x 8 x 4 blocks, which yields 5 x 5 x 33 = 825 fBm samples
per chunk (src/world/worldgen.zig:63-70):

```zig
pub const water_surface_cell: u8 = 62;
pub const cell_w: i32 = 4;
pub const cell_h: i32 = 8;
const samples_x: usize = @intCast(@divExact(chunk_size, cell_w) + 1); // 5
const samples_y: usize = @intCast(@divExact(y_dim, cell_h) + 1); // 33
```

The coarse grid is snapped in world coordinates (`@divFloor(wx, cell_w)`), and
`chunk_size % cell_w == 0` makes the sample planes of adjacent chunks coincide.
`generateChunkBlocks` writes every one of the 65536 cells of the plane and
derives the height plane from the topmost solid cell along the way
(src/world/worldgen.zig:483); `WorldGen.density` is the standalone
world-coordinate oracle, and the test "worldgen chunk fill matches world
density oracle (no chunk seams)" pins the bit-exact agreement that makes chunk
borders seamless by construction (src/world/worldgen.zig:699). Point queries
(`heightAt`) and `fillHeights` exist for reference and for the projected
geometry path, both scanning or interpolating the same field
(src/world/worldgen.zig:382, src/world/worldgen.zig:410).

`fillWaterTable` is the W4 water table: a column whose surface sits below
`water_surface_cell` takes water from one cell above its bed up to that cell,
and only air cells are overwritten (src/world/worldgen.zig:576). The constant
is one cell for the whole world, so adjacent chunks cannot seam. It is applied
at the end of `generateProc` (src/world/store.zig:397). Not ported: the stock
per-lake `waterRect` sources, shore falloff, lava lakes and water flow
(docs/WORLDGEN.md:220).

## Shaping, terrain tiles and biome assignment

`columnTarget` is the 2D shaping stack behind `cache_2d`: continental fBm, a
ridged layer and domain-warped detail, blended by a low-frequency
`mountainness` factor so regions run flat, rolling or ridged, and clamped to
`[min_surface + margin, max_surface - margin]` so interpolation cannot push a
derived height outside the asserted band (src/world/worldgen.zig:301,
src/world/worldgen.zig:338). The three amplitudes are shares of `height_amp`,
so the default `height_amp` of 24 reproduces the pre-rules amplitudes exactly
(src/world/worldgen.zig:47).

`biomeAt` is a single low-frequency fBm mapped onto the loaded biome count; it
returns index 0 while `biome_n <= 1`, which keeps the single-biome fill
(src/world/worldgen.zig:280). The store feeds it from the loaded stock table:
`syncWorldgenBiomes` copies `biome_n` from `biome_layers_table.biomeCount()`
and copies the live `terrain_ids` into the generator's id fields, and it
attaches the table whenever at least one biome resolved so that surface stacks
come from XML rather than the offline pin (src/world/store.zig:697). The
material pass then resolves a column's real biomemap id through
`biomeIdAt(...)` and fills the stack from `stackFor(...)`
(src/world/worldgen.zig:551). The chunk biome id sent on the wire comes from
the same field, so the client's displayed biome matches the blocks
(`World.procBiomeAt`, src/world/store.zig:718).

This is not the climate model the design describes. `docs/WORLDGEN.md:227`
specifies a 6-axis temperature/moisture/continentalness/erosion/weirdness/depth
model with nearest-hypercube lookup; the shipped `biomeAt(fx, fz)` takes no
climate and has no hypercube. No `finalDensity` or `climate` symbol exists in
`src/world/worldgen.zig`; the signature sketch in `docs/WORLDGEN.md:365` is
design, not this code.

## Subbiome noise: decoration only

`subbiome_noise.zig` is a clean-room port of stock `PerlinNoise` plus
`WorldBiomeProviderFromImage::GetSubBiomeIdxAt`, used by deco sampling, not by
terrain (src/world/subbiome_noise.zig:1). A subbiome is a noise window plus its
own distant-decoration set (src/world/subbiome_noise.zig:207):

```zig
pub const SubBiome = struct {
    noise_freq: f32 = 0,
    noise_min: f32 = 0,
    noise_max: f32 = 0,
    noise_ox: f32 = 0,
    noise_oz: f32 = 0,
};
```

`subBiomeIdx` evaluates the two-octave fBm at the offset cell, normalises it to
`[0,1)` and returns the first subbiome whose `[min, max)` window contains the
value, or -1 for the biome's own list (src/world/subbiome_noise.zig:220).
`Game.decoSpeciesAt` calls it per cell on a proc world after resolving the
biome from the W3 field (src/server/game/deco.zig:61). Fidelity is bounded:
stock embeds a fixed 256-byte permutation literal, while this port uses the
classic Ken Perlin table, so the subbiome banding is stock-shaped but not
byte-identical to the stock boundaries (src/world/subbiome_noise.zig:19). The
biomemap loader in `biomes.zig` - `ColorTable` keyed on `biomes.xml`
`biomemapcolor` rows and the `BiomeMap` PNG reader - serves the baked path; a
proc world carries no biomemap (src/world/biomes.zig:17,
src/world/biomes.zig:219).

## Wiring: callers, tick, wire, persistence

| Step | Site |
|---|---|
| Source selection | `World.enableProc` (src/world/store.zig:666), called from `Game` init (src/server/game.zig:1171) |
| Chunk miss | `World.getOrCreate` proc branch (src/world/store.zig:902) |
| Fill | `Chunk.generateProc` then `fillWaterTable` (src/world/store.zig:387) |
| Tick entry | `sendSpawnChunk`, apm section `chunk_gen` (src/server/game/chunk_fill.zig:40) |
| Pacing | `chunk_adds_per_stream_tick`, default 8 (src/server/game/types.zig:67) |
| Wire | stock `buildNetPackageChunkNew` body, biome id per chunk and per column (src/server/game/chunk_fill.zig:130, src/server/game/chunk_fill.zig:112) |
| Persist | ZCH3 `.zch` per chunk; clean proc chunks are skipped (src/world/store.zig:1468) |

The wire is the same builder the baked path uses, so a proc chunk reaches the
client through the existing stock chunk package; nothing in this subsystem
adds a second encoder. A green zdtd encode/decode round trip proves
self-consistency between this generator and the zdtd encoder, not stock RWG
compatibility. Persistence follows from determinism: an untouched proc chunk
regenerates from the seed, so only dirty chunks are written, and an infinite
world's save directory grows with the player's edits (src/world/store.zig:1460).

## What is missing

Roads, POIs, settlements and tile layout have no code in this subsystem and no
caller anywhere in `src/`. `enableProc` explicitly clears the prefab index
(src/world/store.zig:673), so no `.tts` paint is applied to a proc chunk, and
no source file references WFC, tile or road placement. The design places these
at W5/W5b (docs/WORLDGEN.md:439); as of this reading they are design only.

The remaining parked stages, per the design milestones and the gap row: the
async gen queue and prefetch ring (W2b), carved caves and aquifers (W4),
lava lakes and water flow (W4), run-aware surfacing so overhang undersides do
not expose stone (W3), the real-DEM blend policy (W6) and far-terrain LOD
(W7). The stock RWG C# pipeline is not a host target, and `rwgmixer.xml` is
listed as `-`, so the stock tile weights are not driven by that file
(docs/GAP_ANALYSIS.md:6381, docs/GAP_ANALYSIS.md:4546).

## See also

- [`docs/WORLDGEN.md`](../WORLDGEN.md) - the design, milestones and the verified-versus-inferred log
- [`docs/MAPS.md`](../MAPS.md) - the baked DTM/prefab path this subsystem replaces
- [`docs/GAP_ANALYSIS.md`](../GAP_ANALYSIS.md) - the "RWG / procedural gen" row and the proc non-goal
- Sibling pages: [map.md](map.md), [world-store.md](world-store.md).
