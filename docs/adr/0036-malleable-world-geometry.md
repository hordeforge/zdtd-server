# ADR 0036: Malleable world geometry — elevation projection + wire profiles

- **Status:** accepted
- **Date:** 2026-08-28
- **Related:** ADR 0011 (ZCH save formats), ADR 0021 (rules as data),
  ADR 0020 (Wasm plugins; wire encode stays native)

## Context

A stock 7DTD client only reads a 256-tall chunk format (`ChunkBlockYDim=256`,
64 layers of 4, byte heightmaps, `x + z*16 + y*256` plane indexing — all
byte-pinned by our golden tests and the research `terrain-height.md` dump).
"Changing max height" is therefore not a modlet knob: even RealEarth, the mod
that famously adds real height, ships an **engine patch** (YDim 256→16384,
an IL literal their own docs call "not a config tweak"), and its stock-safe
compress path is explicitly non-product. We serve a stock client, so the
256 format stays the default contract, period.

But "the format is pinned" was being over-applied: the server's **world model**
had 256 baked in as code (`y_dim` consts in `store.zig` and `worldgen.zig`,
u8 heights planes, hardcoded block-plane stride everywhere), so even a
RealEarth-style *paired* server+client mod (operator accepts a client mod) had
no seam to slot into, and a world that wanted a different elevation model
(compressed mountains, one-to-one sea-level mapping, custom ceiling) had no
data surface at all.

## Decision

Two layers, both data-driven, wire encode staying native (ADR 0020):

1. **Elevation projection (`[rules.geometry]`, ADR 0021 auto-bound).** Terrain
   sources produce absolute game-Y elevation; the column is
   `clamp(height_offset + height_scale * elev_m, 0, ceiling)` with
   `sea_level` shaping the flat fill and the baked-DTM fallback. Stock
   defaults are the identity (scale 1, offset 0, ceiling = profile max) and
   are a no-op fast path — vanilla worlds render byte-identical.
2. **Wire profiles (`[wire] profile` in zdtd.toml).** A `WireProfile` in
   `protocol.zig` carries the column height (one source of truth; layers,
   plane cell count and `c_max_height` derive from it — the plane index
   stride stays the fixed `ChunkAreaDim` 256). The chunk store (`Chunk.y_dim`,
   profile-sized planes), the chunk wire builder (layer band count + column
   height bounds), and the save format (ZCH4 tag carrying `y_dim`) all follow
   it. `stock` is the default and only complete dialect; non-stock profiles
   are named (currently `tall-512`, synthetic, for seam proof) and require a
   paired client mod. Unknown names and structurally invalid profiles fail
   closed at startup; proc worldgen + non-stock is refused (proc generation
   remains 256-tall).

RealEarth's own "keep true meters in tiles, compress only when writing" maps
onto this: an elevation source (future `.rte`/DEM tiles, the `dem`
`TerrainSource` slot) supplies real meters, the projection compresses into the
active column, and the column height is the dialect's choice. Byte heightmaps
stay byte (lossy) exactly like RealEarth's residual `GetTerrainHeight`; the
block layers carry tall truth.

## Consequences

**Easy now:** a world/modpack can ship compressed or sea-level-mapped terrain
via `[rules.geometry]` with a stock client; the wire/save/storage seam for a
taller column exists, is config-declared, and is proven by a `tall-512`
scenario (128-layer wire bodies, ZCH4 save round-trip, production chunk_fill
stream) — no stock bytes changed (golden tests guard).

**Harder / costs:** a dense non-stock chunk can exceed the fixed 512 KiB
`body_buf` (stock worst case ~262 KiB); today that fails loudly (encode
Overflow) rather than corrupting — a profile-sized send buffer is follow-on
work. `tall-512` is a synthetic dialect: no real client can read it, so it is
test-only; implementing an actual RealEarth-compatible dialect needs RE of
their patched formats in the research repo plus a patched client in the test
env (out of scope here). Proc terrain is not yet projection-driven (its
elevation model is the generator's own params) — documented, not silent.

**Boundary:** geometry choice is data (rules/manifest/config); wire encode,
interest and persistence stay native (ADR 0020). This does not open a plugin
boundary for world geometry — plugins gate *behavior*, not format.
