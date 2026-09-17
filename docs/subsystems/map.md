# Map data: DTM, prefabs, TTS, biomes, navigation

This subsystem reads the stock map that an operator install ships: the baked DTM height plane and spawn points, the Copernicus GLO-30 DEM codec, the `prefabs.xml` index with its `.tts` voxel data, `<name>.blocks.nim` id maps and `<name>.xml` quest/trader metadata, sleeper volumes, `biomes.xml` colors and `biomes.png`, `water_info.xml` point sources, the coarse navigation grid, and the pure sky day/night curves. It owns parsing and the in-memory shape those files become, plus the sim-facing query helpers over them; it does not own chunk storage, save overlays, wire encoding, or world generation (the `flat`/`proc` paths live in `worldgen.zig`). The package `//!` comment fixes the boundary: world may import `util` and `assets` and may use pure ECS component types, but must not import `wire`, `server`, or `litenet` (`src/world/root.zig:1`); `assets/blocks_nim.zig` is explicitly imported from assets, not from world (`src/world/root.zig:6`). Consumers today are `src/server/game/*` (`init_assets`, `init_world`, `chunk_fill`, `deco`, `sleeper`, `trader`, `step`, `wasm_host`), `main.zig`, and the fuzz entry points (`src/fuzz.zig:32`).

Sources: [`src/world/dtm.zig`](../../src/world/dtm.zig), [`src/world/dem.zig`](../../src/world/dem.zig), [`src/world/prefabs.zig`](../../src/world/prefabs.zig), [`src/world/tts.zig`](../../src/world/tts.zig), [`src/world/sleepers.zig`](../../src/world/sleepers.zig), [`src/world/biomes.zig`](../../src/world/biomes.zig), [`src/world/subbiome_noise.zig`](../../src/world/subbiome_noise.zig), [`src/world/water.zig`](../../src/world/water.zig), [`src/world/nav.zig`](../../src/world/nav.zig), [`src/world/sky.zig`](../../src/world/sky.zig), [`src/assets/blocks_nim.zig`](../../src/assets/blocks_nim.zig).

## Load entry point and coordinate mapping

One loader fills the whole map: `World.loadStockMapEx` reads the DTM, the spawn points, `biomes.png`, the prefab index (deriving `<Data>/Prefabs` from a `.../Worlds/<name>` map path when no explicit prefab root is passed), and `water_info.xml`, then sets `terrain_source = .baked` and drops any worldgen state (`src/world/store.zig:745`, `src/world/store.zig:787`). The loaded pieces are plain optional fields on `World` (`src/world/store.zig:540`). Chunk materialization calls back into them in a fixed order: DTM heights, biome layer stack, prefab flatten and TTS paint, then water carve (`src/world/store.zig:923`, `src/world/store.zig:935`, `src/world/store.zig:1007`).

The heightmap record (`src/world/dtm.zig:13`, methods elided):

```zig
pub const Heightmap = struct {
    width: i32,
    height: i32,
    /// Owned buffer of u16 samples (width*height), row-major Z then X (index = dz*width + dx).
    samples: []u16,
    allocator: std.mem.Allocator,
    half_w: i32,
    half_h: i32,
```

World XZ maps to samples by `dx = wx + half_w`, `dz = wz + half_h`, with the origin at map center, and the u16 sample is shifted down by 8 to a block Y (`src/world/dtm.zig:29`). `fillChunkHeights` writes a 16x16 plane with a 16-wide vector path when the chunk is interior and a scalar fallback at edges (`src/world/dtm.zig:39`, `src/world/dtm.zig:59`). Grid size comes from `map_info.xml` `HeightMapSize="W,H"` (`src/world/dtm.zig:86`); the loader prefers `dtm_processed.raw` over `dtm.raw` when both exist (`src/world/dtm.zig:159`). `spawnpoints.xml` `position="x,y,z"` entries land in a fixed caller array, and the first one is the primary spawn (`src/world/dtm.zig:116`, `src/world/store.zig:817`).

The DEM leg is a separate codec with no streaming layer: Copernicus GLO-30 COG header parse (`src/world/dem.zig:37`), DEFLATE tile decode plus TIFF floating-point predictor 3 (`src/world/dem.zig:84`, `src/world/dem.zig:103`), and `elevToBlockY = 60 + elev_m/12` clamped to `[1, 250]`, where the clamp rather than the 12 m scale is what keeps extreme elevations in range (`src/world/dem.zig:156`). The S3 range-fetch layer is parked, per the file header (`src/world/dem.zig:3`). This is not the baked-map path described in [MAPS.md](../MAPS.md); it is the elevation model behind the geometry projection seam.

## Prefab index, footprints and YOffset

`prefabs.xml` is parsed once into `Index`: names are interned into one owned buffer, and sizes are probed from each prefab's `.tts` header (`magic "tts\0"`, version `u32`, then `sx/sy/sz` as `u16`) under `POIs`, `Parts`, or `RWGTiles` (`src/world/prefabs.zig:711`, `src/world/prefabs.zig:811`). A prefab whose `.tts` is missing gets `4x2x4` when it is a `part_*` and `16x8x16` otherwise (`src/world/prefabs.zig:887`). The per-decoration record (`src/world/prefabs.zig:155`, methods elided):

```zig
pub const Decoration = struct {
    name: []const u8,
    x: i32,
    y: i32,
    z: i32,
    rot: u8 = 0,
    y_is_ground: bool = true,
    size_x: i32 = 8,
    size_y: i32 = 4,
    size_z: i32 = 8,
    /// `YOffset` from the prefab .xml. Only meaningful once the prefab files
    /// have been probed (parseXml with a prefabs data dir), 0 otherwise.
    y_offset: i32 = 0,
```

Two vertical rules matter more than the field list. `stampY()` adds `y_offset` only when `y_is_ground` is set, so a cave that pins an absolute Y keeps it (`src/world/prefabs.zig:174`); `YOffset` is read by exact property-name match because the same file carries `DistantPOIYOffset`, and every parse failure returns 0 like `DynamicProperties::GetInt` (`src/world/prefabs.zig:828`). The terrain pad is a different value: `applyToChunkHeights` flattens to the declared ground minus one block for a full POI (the level stock's `dtm_processed.raw` already carries) and to plain ground for parts, and raises rather than lowers when `y_is_ground` is false (`src/world/prefabs.zig:288`). Footprint bounds swap X and Z for rotations 1 and 3 (`src/world/prefabs.zig:229`), and `part_*` names are never quest POIs (`src/world/prefabs.zig:60`).

Per-decorating metadata is lazily cached in `questData` from the prefab's own `.xml`: `QuestTags`, `DifficultyTier`, `AllowDecorations`, the `Tags` property as `poi_tags`, a `has_sleepers` flag set when `SleeperVolumeSize` exists, the trader NPC cell from the `IndexedBlockOffsets class="Trader"` entry, `ThemeTags`, and the trader-area protect padding and teleport volumes (`src/world/prefabs.zig:547`, `src/world/prefabs.zig:587`). The `QuestData` fields (`src/world/prefabs.zig:18`, remainder elided):

```zig
pub const QuestData = struct {
    /// Stock QuestTags value ("clear, fetch, infested"), "" when absent.
    tags: []const u8 = "",
    /// Stock `Tags` property (the PoiTags list, e.g. "wilderness",
    /// "commercial,industrial"): the FastTags<Poi> set the biome spawner
    /// tests against spawning.xml rule tags/notags (spawning.md §2).
    poi_tags: []const u8 = "",
    /// Stock DifficultyTier (1..6), 0 when absent.
    tier: u8 = 0,
```

`poiTagsAt` feeds the biome spawner a POI's tags for a world position (`src/world/prefabs.zig:271`), `collectDecoSuppressors` feeds the decoration sampler the footprints that suppress world deco (`src/world/prefabs.zig:253`), and `foreachTeInChunk` hands the chunk scan the prefab's tile-entity list with rotated world coordinates (`src/world/prefabs.zig:670`). Trader gates read `is_trader_area` and walk the AABB (`src/server/game/trader.zig:73`).

## TTS voxel data and block id remapping

`.tts` is read into a dense per-cell shape; the file stores a flat `u32` plane and separate sparse channels (`src/world/tts.zig:1`). The record (`src/world/tts.zig:71`, `deinit` elided):

```zig
pub const TtsBlocks = struct {
    sx: i32,
    sy: i32,
    sz: i32,
    /// Full BlockValue.rawData (type 0..15 + rotation/meta); air = 0. Child cells cleared.
    types: []u32,
    /// Density channel (stock sbyte as u8 bit pattern), length types.len or empty.
    density: []u8 = &.{},
    /// Damage plane (u16 LE per cell) when present.
    damage: []u16 = &.{},
    /// Per-cell textureFull (paint); low 48 bits meaningful. 0 = unpainted.
    /// Length types.len when the sparse texture channel was decoded, else empty.
    textures: []u64 = &.{},
    /// Per-cell water mass (sparse WaterValue u16, v>=17). 0 = dry. Length
    /// types.len when the channel was decoded, else empty. Cells with mass > 0
    /// are authored water (POI pools, flooded basements, water towers).
    water: []u16 = &.{},
    /// Per-cell blockplaceholders index + 1 (0 = the cell is a normal block).
    /// Filled by the prefab id remap from the placeholder table, consumed by
    /// the paint path, which resolves the target at the cell's world position.
    placeholders: []u16 = &.{},
    /// Prefab TE list (local coords). Payloads owned by same allocator.
    tile_entities: []TeEntry = &.{},
    allocator: std.mem.Allocator,
```

`parseBlocks` rejects versions below 5, converts pre-18 `BlockValueV3` layouts through `convertOldRawData` before anything reads the type, and clears child cells (`src/world/tts.zig:136`, `src/world/tts.zig:50`). Density is assumed immediately after the block plane, damage is gated on version > 8, and the texture (v>=10) and water (v>=17) channels decode a bitstream plus one value per set bit into dense arrays (`src/world/tts.zig:180`, `src/world/tts.zig:187`, `src/world/tts.zig:199`, `src/world/tts.zig:223`). Tile entities are read after the block data for version > 12 (`src/world/tts.zig:259`).

Type ids in the file are prefab-local indices, so `Index.remapToRuntimeIds` resolves each through the prefab's `<name>.blocks.nim` into the runtime AssignIds space, replaces only the low 16 bits so rotation and meta survive, and leaves a cell air when the name is unknown to this install (`src/world/prefabs.zig:378`, `src/world/prefabs.zig:443`). The install must supply the resolver: `init_assets.zig` installs it from the merged AssignIds table before the first chunk is generated (`src/server/game/init_assets.zig:229`), and `setIdLookup` drops cached prefabs so nothing stays in local ids (`src/world/prefabs.zig:361`). `getTtsBlocks` caches one heap allocation per name so a held pointer survives later cache puts (`src/world/prefabs.zig:519`).

Painting has three behaviors worth knowing before changing it: blockplaceholders resolve per cell at the world position through `PlaceholderCtx` (`src/world/tts.zig:406`, `src/world/tts.zig:457`); `terrainFiller`/`terrainFillerAdaptive` cells take the surrounding terrain from a callback rather than being stamped (`src/world/tts.zig:474`); and the stamped block rotation is `rotateRawY(raw, 4 - rot)` because stock's left-turn path replaces the rotation count (`src/world/tts.zig:498`). The world-side callback writes straight into the generating chunk and never re-enters the chunk store (`src/world/store.zig:944`). Note the doc drift: [MAPS.md](../MAPS.md) line 87 still states there is no TTS name to AssignIds remap, while the code has done that remap by name since the `.blocks.nim` path landed.

## Sleeper volumes

Sleeper volumes are parsed from each placed prefab's XML, not from the world store, and the resulting `Store` is the sim's whole sleeper model. The volume record (`src/world/sleepers.zig:28`, methods and later fields elided):

```zig
pub const Volume = struct {
    /// World-space AABB (inclusive min, exclusive max) after prefab rotation.
    x0: i32 = 0,
    y0: i32 = 0,
    z0: i32 = 0,
    x1: i32 = 0,
    y1: i32 = 0,
    z1: i32 = 0,
    groups: [max_group_classes]VolumeGroup = [_]VolumeGroup{.{}} ** max_group_classes,
    group_n: u8 = 0,
```

The remaining state is the wake/persistence model: `triggered`, `respawn_time` in world ticks, `spawned_alive`, `group_id`, the placement `origin_x/y/z` that keeps two placements of one prefab from cascading into each other, `quest_cleared`, and authored `spawns` (`src/world/sleepers.zig:45`, `src/world/sleepers.zig:51`, `src/world/sleepers.zig:58`, `src/world/sleepers.zig:65`, `src/world/sleepers.zig:71`). `loadFromPrefabs` caches each prefab XML, decides the group form from the token count (name-only gets `5,5`; triples parse `min/max`; anything else becomes class `"???"` with `5,5`), and collects authored spawn points from `Class=Sleeper` marker blocks in the `.tts`, resolved through `.blocks.nim` with a name-prefix fallback only when no classifier is supplied (`src/world/sleepers.zig:380`, `src/world/sleepers.zig:485`, `src/world/sleepers.zig:519`, `src/world/sleepers.zig:572`). `max_volumes` is 8192 (`src/world/sleepers.zig:11`).

Wiring: `initWorld` builds a `PrefabRef` list in two passes (near the primary spawn first, then the rest of the map), calls `loadFromPrefabs` with `Game.isSleeperName`, then replays persisted suppressions (`src/server/game/init_world.zig:23`, `src/server/game/init_world.zig:66`, `src/server/game/init_world.zig:85`). Per tick, `tickSleeperVolumes` gathers player positions and scans untriggered volumes, in parallel when the job batches are on, then calls `triggerVolume` for each hit (`src/server/game/sleeper.zig:53`, `src/server/game/sleeper.zig:74`). A triggered volume cascades by `group_id` plus origin and prefab-name equality, and re-arms only through `rearmIfExpired` (`src/server/game/sleeper.zig:109`, `src/server/game/sleeper.zig:94`). `has_sleepers` on the prefab quest data is the stock `AnyUsedEntry` gate for quest POI selection (`src/world/prefabs.zig:587`).

Persistence is two files in the world dir: `sleepers_cleared.zsc` (magic `ZSCL1`, 24-byte rects) for quest-cleared POIs and `sleepers_triggered.zst` (magic `ZSTG1`, 24-byte rects plus an optional `u64` re-arm tail) for volumes players already woke (`src/world/sleepers.zig:132`, `src/world/sleepers.zig:218`). Both loaders are best-effort and re-mark volumes by rect overlap after the store is rebuilt, because the store itself is regenerated from the prefab XMLs each boot (`src/world/sleepers.zig:160`, `src/world/sleepers.zig:251`).

## Biomes and subbiome noise

`biomes.xml` supplies both the biome id rows and the PNG color keys. `loadColorTable` builds a name to id map from `<biomap id name>` rows and pairs each `<biome biomemapcolor>` hex color with the id its own name resolves to, so callers key on stock names rather than literals (`src/world/biomes.zig:119`). `tryLoadColorTable` resolves the file through the config path resolution and returns null on absence (`src/world/biomes.zig:204`); `init_assets.zig` loads it and, if a map dir is already open, reloads `biomes.png` with those colors so the PNG's RGB keys map to ids instead of the offline fallback table (`src/server/game/init_assets.zig:729`, `src/world/biomes.zig:66`).

The biomemap record (`src/world/biomes.zig:219`):

```zig
pub const BiomeMap = struct {
    width: i32 = 0,
    height: i32 = 0,
    /// biomemap ids (not PNG color channels), row-major.
    r: []u8 = &.{},
    allocator: std.mem.Allocator = undefined,
    half_w: i32 = 0,
    half_h: i32 = 0,
    /// Blocks per biomes.png pixel (world size / png size); Navezgane ships 3072px for a 6144 world.
    scale: i32 = 1,
```

`parsePng` is a minimal decoder: 8-bit RGB or RGBA, non-interlaced, filters 0 through 4, zlib IDAT inflate, and a 16384 edge cap that also guards the raw-size math (`src/world/biomes.zig:290`, `src/world/biomes.zig:288`). `atWorld` flips Z because PNG row 0 is north and divides by `scale` (`src/world/biomes.zig:236`); `chunkDominant` counts only ids below 50, matching stock's `int[50]` (`src/world/biomes.zig:247`). `World` sets `scale` from the DTM width over the PNG width after load (`src/world/store.zig:780`). Consumers use the dominant id for the chunk wire header and `atWorld` for the per-cell channel (`src/server/game/chunk_fill.zig:57`, `src/server/game/chunk_fill.zig:177`).

Subbiome resolution is a clean-room port of `PerlinNoise` plus `GetSubBiomeIdxAt`, seeded from `GetStableHashCode(worldName)` (`src/world/subbiome_noise.zig:1`, `src/server/game.zig:1181`). The window record (`src/world/subbiome_noise.zig:207`):

```zig
pub const SubBiome = struct {
    noise_freq: f32 = 0,
    noise_min: f32 = 0,
    noise_max: f32 = 0,
    noise_ox: f32 = 0,
    noise_oz: f32 = 0,
};
```

`subBiomeIdx` returns the first subbiome whose `[min, max)` window contains `FBM(x+ox, z+oz, freq) * 0.5 + 0.5`, recomputing the noise only when frequency or offset changes, as stock caches it; `-1` means the biome's own decoration list applies (`src/world/subbiome_noise.zig:220`). Stated fidelity gap: the stock embedded permutation literal is not extracted, so zdtd uses the classic Ken Perlin table and the banding is stock-shaped but not byte-identical to stock boundaries (`src/world/subbiome_noise.zig:19`). The deco sampler consumes this per cell (`src/server/game/deco.zig:61`).

The splat map is not read here. No module in this repo opens `splat3_processed.png`; the file appears only in an RE comment justifying the rotation direction (`src/world/tts.zig:337`), while [MAPS.md](../MAPS.md) line 19 describes wired chunks as using MicroSplat splats. What the wire carries per cell is the TTS density/damage/texture planes and the chunk topsoil bitfield (`src/server/game/chunk_fill.zig:145`), so splat fidelity beyond that is a gap, not an implemented path.

## Water, navigation and sky queries

Water is two things: stock point sources used as water-table hints, and the bounded leveling queue the edit path feeds. `Sources.applyToChunkHeights` lowers a cell to the water surface only when the cell is at most 2 blocks above it, so pools read flat without draining deeper terrain; the carve radius is the named constant `pool_carve_radius = 12` (`src/world/water.zig:75`, `src/world/water.zig:72`). Parsing accepts `<Water pos="x, y, z"/>` with spaces after commas, and a missing file is normal while any other I/O error is logged so it cannot masquerade as "no water" (`src/world/water.zig:103`, `src/world/water.zig:141`). The `Leveler` is a fixed 256-entry ring on `World`; a full queue drops the new edit rather than growing (`src/world/water.zig:20`, `src/world/water.zig:18`). It is wired at chunk generation (`src/world/store.zig:1007`).

Navigation is a coarse grid, not a Recast mesh: 4-block cells, a 64x64 cell search region, 32 waypoints, and a maximum step of `max_step_up + 1` (`src/world/nav.zig:19`, `src/world/nav.zig:22`, `src/world/nav.zig:25`). Walkability fails closed on an unloaded chunk (`src/world/nav.zig:33`):

```zig
pub fn cellSurfaceY(w: *const World, wx: i32, wz: i32) ?i32 {
    const bx = wx * cell_size + cell_size / 2;
    const bz = wz * cell_size + cell_size / 2;
    const t = World.worldToChunk(bx, bz);
    const ch = w.chunks.get(t.pos.hash()) orelse return null;
    return ch.standableY(t.lx, t.lz, w.yDim() - body_height, max_step_up, w.yDim());
}
```

`findPath` is BFS over 4-neighbours with fixed stack arrays, so the query path allocates nothing (`src/world/nav.zig:45`, `src/world/nav.zig:59`). The grid is exposed to Wasm plugins as the `path` host verb, which converts world coordinates to cells and formats the waypoint list (`src/server/game/wasm_host.zig:498`, `src/server/game/wasm_host.zig:514`). The decisions stay in the guest, per ADR 0026; this module only answers.

Sky is pure functions of world time for the clone-side light model: `day_ticks = 24000`, `ticks_per_hour = 1000`, `timeOfDay`, `sunMoonTarget`, `dayPercent`, and `ambientLuma` (`src/world/sky.zig:19`, `src/world/sky.zig:23`, `src/world/sky.zig:52`). The moon fold uses the stock 7-phase tables (`src/world/sky.zig:123`):

```zig
pub const moon_phases = [_]f32{ 0.05, 0.35, 0.55, 0.70, 1.40, 1.63, 1.82 };
pub const moon_brights = [_]f32{ 1.0, 0.65, 0.45, 0.25, 0.40, 0.60, 0.90 };
```

The tick path computes one ambient value per tick and folds it into the sim's `ambient_light` for the stealth light byte (`src/server/game/step.zig:131`, `src/server/game/step.zig:140`). Everything position-dependent in stock's `GetLightLevel` stays zero and is recorded as later slices; the file header says so (`src/world/sky.zig:8`).

## See also

- [MAPS.md](../MAPS.md) - operator-facing map loading, CLI flags and the honest limits table.
- [WORLDGEN.md](../WORLDGEN.md) - the flat and procedural terrain path this page's `.baked` path replaces at load.
- [ASSETS.md](../ASSETS.md) - where `biomes.xml`, `blocks.xml` and AssignIds id spaces come from.
- [SCALE.md](../SCALE.md) - the DEM/elevation and vertical-cap work the 256-tall wire profile forces.
- [AUTHORITY.md](../AUTHORITY.md) - which of these query results the server owns when a client asks.
- Sibling pages: [worldgen.md](worldgen.md), [world-store.md](world-store.md),
  [assets.md](assets.md), [chunk-stream.md](chunk-stream.md).
