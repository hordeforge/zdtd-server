# Chunk wire formats (zdtd)

Stock `Chunk.write` is ~601 IL (64 layers, channels, TE, …). Until capture-golden
stock bytes land, zdtd speaks two **documented intermediate** layouts.


**API note:** in-memory `heightWorld` / `heightAt` return **u16** for headroom; stock wire and `.zch` still store **u8[256]** (clamp on write).
## Layout A: height plane (inner payload)

```text
cx:i32 LE | cz:i32 LE | ydim:i32 (=256) | heights:u8[256]
size = 268
heights[lx + lz*16] = surface Y
```

## Layout D: stock NetPackageChunk envelope (default S→C)

Matches V3.0.1 `NetPackageChunk.write` when `bOverwriteExisting`:

```text
overwrite:bool (=1)
cx:i16 | cy:i16 (=0) | cz:i16
dataLen:i32
payload: Layout A (or future stock Chunk.write blob)
size = 11 + 268 = 279
```

Package name: `NetPackageChunk`. Bots may send/parse bare Layout A; server always sends D.

## ChunkRemove

Stock body: `chunkKey:i64` = `WorldChunkCache.MakeChunkKey(cx, cz)`  
`((cz & 0xFFFFFF) << 24) | (cx & 0xFFFFFF)`.

## Layout B: column tops (ZCHC)

```text
'Z''C''H''C' | cx:i32 | cz:i32 | ydim:i32 | heights:u8[256] | top_block:u16[256]
size = 4+12+256+512 = 784
```

`top_block` is the block id at surface height per column.

## Layout C: layered skeleton (ZCHL) stock-inspired

Approximates stock layer loop without full channel/TE parity:

```text
'Z''C''H''L' | cx:i32 | cy:i32(=0) | cz:i32 | ticks:u64
for layer in 0..63:
  present:u8
  if present:
    blocks:u16[1024]   // 16×16×4, index = x + z*16 + (y&3)*256
                       // y = layer*4 + (y&3)
heights:u8[256]
terrain:u16[256]       // surface y * 256 packing (stock-ish)
```

Empty air layers set `present=0` (common for sky). Encoder builds this from
`Chunk.blockAt` / heights. Decoder optional for custom clients.

## Disk

`.zch2` on disk: magic ZCH2 + heights + optional full 65536×u16 columns.
See `src/world/store.zig`.

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
Join/stream disk: **r 6..8**, hole-free, enough adds/tick.

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
