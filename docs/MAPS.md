# Stock maps (Navezgane / Pregen)

zdtd can load **baked heightmaps** from the dedicated/game install:

```text
Data/Worlds/<Name>/
  map_info.xml      HeightMapSize="W,H"
  dtm.raw           W*H × u16 LE, value = surfaceY * 256
  dtm_processed.raw preferred when present (same layout)
  spawnpoints.xml   position="x,y,z" (first used as default spawn)
```

## Coordinate mapping

Measured against Navezgane spawnpoints (V3.0.1):

```text
DTM index:  dx = worldX + W/2,  dz = worldZ + H/2
surface Y:  raw_u16 >> 8   (i.e. gameY * 256 packing)
```

Example: Navezgane `6144×6144`, spawn `(-273,61,449)` → DTM `(2799,3521)` height `60`.

## CLI

```bash
GAME=.../7 Days to Die Dedicated Server
zdtd --port 27002 --game-dir "$GAME" --world-name Navezgane --world worlds/nav_save
# equivalent:
zdtd --port 27002 --map "$GAME/Data/Worlds/Navezgane" --world worlds/nav_save
```

| Flag | Role |
|---|---|
| `--map` | Read-only stock terrain + prefabs + water + spawns |
| `--game-dir` + `--world-name` | Resolve `$game/Data/Worlds/$name` |
| `--world` | Writable zdtd overlay (`.zch` files: ZCH3 heights + full u32 block data) |

Supported folders on a typical install: `Navezgane`, `Pregen06k01`, `Pregen06k02`,
`Pregen08k01`, `Pregen08k02` (size from each `map_info.xml`).

## Prefabs + water (loaded with `--map`)

| File | Behavior |
|---|---|
| `prefabs.xml` | All decorations; sizes from `Data/Prefabs/{POIs,Parts,RWGTiles}/name.tts` header |
| Footprint stamp | Flatten/pad heights under each AABB (POIs +1 block pad; `part_*` ground only) |
| **TTS block paint** | `src/world/tts.zig`: stock v≥5 raw `u32` plane; type = low 16 bits; skip multi-block children; rot 0–3; stamped on chunk create for full POIs (`part_*` skipped for cost) |
| `water_info.xml` | Point sources; near cells pull surface toward water Y |

Navezgane smoke: **1559** prefabs, **39** water sources. Pregen08k01: **5302** prefabs.

Code: `prefabs.Index` lazy-caches loaded TTS by name; paint writes **into the
generating chunk only** (no recursive world set during paint).

## Limits (honest)

- **Vertical world cap = 256 (client side).** Stock clients cap Y at 256 (64
  layers x 4); it is also `ChunkAreaDim` for the 16x16 XZ maps, so it cannot be
  raised blindly. zdtd can serve tall columns (`world/dem.zig` `elevToBlockY`),
  but real elevations above ~255 (Mont Blanc 4365 m) are clamped by stock
  clients. Lifting the cap needs an opt-in client-side YDim-expand mod that
  patches only the true vertical/layer sites. MVP exists in the RealEarth
  sister project (`../7days-realworld`, `tools/engine_patcher`, Mono.Cecil +
  Harmony). Opt-in scaling extension, not part of the stock-client-wire core.
  See `docs/SCALE_ARCHITECTURE.md`.
- TTS: types + **texture channel** (per-block `textureFull` paint decoded from
  the sparse v>=10 channel and wired into the chunk `chnTextures` so paint-driven
  shape blocks render their material, not grey). Density from type + TTS; terrain
  floor MicroSplat needs client splat load (`fixedSizeCC=false`, see WIRE_CHUNK).
- No TTS name→AssignIds remap if prefab ids drift from runtime blocks.xml.
- TTS TE lists spawn loot-type containers (Loot/SecureLoot/Composite); non-loot TEs and TTS-driven sleeper volumes not yet spawned (sleeper volumes come from prefab XML).
- Biome paint from `biomes.png`: per-chunk dominant biome (HAVE); per-cell biome paint still one value per chunk.
- Terrain outside prefabs: dirt/stone/bedrock columns from surface height.
- Chunk wire: stock `Chunk.write` path from heights + painted types when present.
