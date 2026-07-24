# Chunk wire formats (zdtd)

Stock `Chunk.write` is ~601 IL (64 layers, channels, TE, …). Until capture-golden
stock bytes land, zdtd speaks two **documented intermediate** layouts.

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

- 64 block layers: same-value lower8 when uniform, plus a per-cell upper24 array (`id>>8,>>16,>>24`) whenever any id >= 256 so construction/POI ids are not truncated to their low byte
- height/terrain maps, topsoil bitfield, biomes, interleaved BiomeIntensity[256] (6 B each)
- density: mixed-surface layers (solid bands same-value; surface layer per-cell)
- light/damage/water channels same-value (light fill 0, client LightChunk fills); texture channel per-block textureFull (bpv=6, low 6 bytes) from TTS paint, same-value only for uniform bands
- empty entity/TE/volume tails; network bool false + insideDevices 0 + culled false

`NetPackageChunk` first delivery uses **overwrite=false** so the client allocates
and `Chunk.read`s during package.read. Continuous stream uses the same builder.

Client network path forces `NeedsLightCalculation=true` after read; mesh needs
full 8-neighbor rings + light clear (`RegenerateNextChunk`). Server join/stream
must keep a hole-free disk (pw10: join r≤4, stream r≤4) or CGO stays 0.

Intermediate height-plane (layout A/D) remains for loadgen helpers that call
`buildChunkBody` directly; join path uses stock encoder.

## Evidence (pw10)

- Server sent 81 unique stock chunks around spawn (-273,449 → cx~-18..-17 cz~28).
- Client: `Chunks:90 CGO:25` stable, FPS~275, no NRE on mesh path.

## Path to full parity

1. Mixed-surface density layers: **HAVE** (`stock_chunk.zig`).  
2. Stock biome paint from biomes.png: **HAVE** (`world/biomes.zig` color→biomemap id).  
3. Prefab `.tts` **type** paint: **HAVE** (`src/world/tts.zig` on chunk create).  
   Remaining: **density** channel from TTS (texture done), TE lists on chunk stream, name→id remap, `part_*` policy.  
4. Capture golden blobs from stock dedi for bit-diff.  
5. Grow stream with client viewDim (Allowed ChunkViewDistance 7) without flooding LiteNet.
