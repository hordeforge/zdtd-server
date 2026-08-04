# Chunk wire formats (zdtd)

**Production S→C** for the stock client is the network-mode encoder in
`src/wire/stock_chunk.zig` (`buildNetPackageChunkNew`), not the height-plane
helpers. Those helpers remain for unit tests and loadgen-style payloads.

Stock `Chunk.write` is ~601 IL (64 layers, channels, TE, …). Full bit-diff
goldens against a stock dedi capture are still open; the live path already uses
the stock envelope + block-layer layout the client `Read`s.

**API note:** in-memory `heightWorld` / `heightAt` return **u16** for headroom; stock wire and `.zch` still store **u8[256]** (clamp on write).

## Layout A: height plane (test / loadgen helper)

Used by `packages.buildChunkPayload` / `buildChunkBody` only (not the stock
client stream path).

```text
cx:i32 LE | cz:i32 LE | ydim:i32 (=256) | heights:u8[256]
size = 268
heights[lx + lz*16] = surface Y
```

## Layout D: stock NetPackageChunk envelope around Layout A

Test helper envelope (`buildChunkBodyStockEnvelope`). Production client stream
uses `stock_chunk` instead of a bare height-plane payload.

```text
overwrite:bool (=1)
cx:i16 | cy:i16 (=0) | cz:i16
dataLen:i32
payload: Layout A
size = 11 + 268 = 279
```

Package name: `NetPackageChunk`.

## ChunkRemove

Stock body: `chunkKey:i64` = `WorldChunkCache.MakeChunkKey(cx, cz)`  
`((cz & 0xFFFFFF) << 24) | (cx & 0xFFFFFF)`.

## Layout B / C (removed)

Former intermediate encoders **ZCHC** (column tops) and **ZCHL** (layered
skeleton) were deleted. Do not reintroduce parallel wire shapes; production is
`stock_chunk` on the net path and **ZCH3** on disk.

## Disk (world overlay)

Per-chunk `.zch` under `--world` (see [ADR 0011](adr/0011-custom-zch-world-overlay.md)):

```text
'Z''C''H''3' | cx:i32 | cz:i32 | flags[4]
heights:u8[256]
if flags[0]: blocks:u32[65536]          // full rawData
if flags[1]: textures:u64[65536]        // textureFull paint (optional)
if flags[2]: dens:u8[65536] + dens_set  // TTS density + bitset (optional)
```

Legacy: ZCH2 u16 type-only loads heights only (blocks regen). Pre-paint ZCH3
files (flags[1]/[2]=0) remain valid. In-memory paint is co-owned with the cell
(`setBlock` clears texture/density; `setBlockTexDens` re-applies).

## Stock network encoder (default S→C)

`src/wire/stock_chunk.zig` implements network-mode `Chunk.write` (bNetwork=true)
for height-column terrain:

- 64 block layers: full `BlockValue.rawData` (u32); lower8 same-value or 1024 array; upper24 (3072) whenever bits 8..31 set (type≥256 **or** rotation/meta)
- height/terrain maps; **topsoil broken bitfield all 0xFF** (avoid MicroSplat empty-splat path when Dummy); biomes + BiomeIntensity[256]
- density: stock CheckDensities rules (terrain dens &lt; 0 → −128; non-terrain ≥ 0 → +1); TTS density override when painted
- light same-value 0xFF + NeedsLightCalculation true; damage/water 0; texture bpv=6 from TTS paint only (terrain atlas ids &gt;255 stay on client Block.list, not channel)
- empty entity/TE/volume tails; network bool false + insideDevices 0 + culled false

`NetPackageChunk` first delivery uses **overwrite=false** so the client allocates
and `Chunk.read`s during package.read. Continuous stream uses the same builder.

Client mesh needs full neighbor rings (`RegenerateNextChunk`). Only **inner**
chunks (stream radius minus ~2) become displayed GOs. With stream r=4, max CGO
≈25; spawn overlay with `fixedSizeCC=false` needs viewDist²−10 (often 39+).
Join/stream defaults: **r 7..9** (`default_chunk_stream_radius_*` in `game.zig`;
CGO needs r≥6 at viewDist 7), hole-free, enough adds/tick.

## WorldInfo + terrain textures (not in chunk body)

Terrain floor materials on stock maps use **client MicroSplat** + local
`Data/Worlds/<level>/splat*.png`. That requires WorldInfo **`fixedSizeCC=false`**
so the client installs `ChunkProviderGenerateWorldFromRaw(bClientMode)` instead
of Dummy. See `../7dtd-research/docs/protocol-packages.md` §4.2 and
`chunk-providers.md` §4.5. Block ids alone cannot fix a grey floor when splats
never load.

## Evidence

- Surface AssignIds id 8 = terrBurntForestGround; burnt biome layers from biomes.xml.
- Client log with fixedSize=false: `GenWorldFromRaw splats took …ms`.
- Stream r=4 → CGO stuck 25/39 ("Starting game"); r≥6 required for viewDist 7.

## Path to full parity

1. Mixed-surface density + TTS dens: **HAVE**.  
2. Biome paint + biomes.xml column layers: **HAVE**.  
3. Prefab TTS rawData+tex+density: **HAVE** (filler skipped).  
4. fixedSizeCC=false + stream for CGO gate: **HAVE** (validate soak).  
5. Capture golden blobs from stock dedi for bit-diff.  
6. TE lists on chunk stream; name→id remap; `part_*` policy.
