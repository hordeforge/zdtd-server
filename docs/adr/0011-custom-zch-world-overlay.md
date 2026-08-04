# ADR 0011: Custom ZCH world overlay (not stock region saves)

- **Status:** accepted
- **Date:** 2026-08-04

## Context

Stock 7DTD persists world state in Unity-era region/prefab formats tied to the
Mono dedi. zdtd is a clean-room server: it must not load or write stock region
binaries as a runtime dependency, but dig/build and TTS paint must survive
process restart under `--world`.

In-memory chunks already hold heights, full `BlockValue.rawData` (u32), optional
`textureFull` (u64), and optional TTS density bitset. Early ZCH2 stored only
u16 type ids (lossy for rotation/meta). ZCH3 fixed rawData; paint/density were
still runtime-only, so digs over painted POI cells could leave orphan texture
after restart (TTS re-stamp then block overlay without paint channels).

## Decision

1. **Authoritative overlay** lives under the operator `--world` dir as per-chunk
   `.zch` files (magic **ZCH3**), not stock region files.
2. **ZCH3 layout:** `ZCH3 | pos.x/z:i32 | flags | heights:u8[256] | optional
   channels`. Flags: `[12]=blocks u32`, `[13]=textures u64`, `[14]=densities +
   dens_set bitset`. Missing flags = channel absent (backward compatible with
   pre-paint ZCH3 and heights-only files).
3. **Load order:** regenerate from map source (DTM/TTS/proc) first, then
   **overlay** disk channels so player edits win. ZCH2 u16 block payloads are
   ignored (heights only; blocks regen) so rotation/meta is never half-loaded.
4. **Cell invariant:** plain `setBlock` / `setBlockRaw` clears paint/density on
   that cell; paint writers re-apply via `setBlockTexDens`. Dirty chunks that
   have allocated texture/density planes persist those planes so cleared digs
   remain clear after restart.
5. **Sibling stores** stay separate: `players.zsv` (ZPV2), `containers.zct`
   (ZCT1), `blockmeta.zbm` (ZBM1). Do not fold them into one mega-format until a
   migration plan exists.

## Consequences

- Operators get portable, inspectable overlays independent of stock saves.
- Paint fidelity after dig/build + restart matches sim, not only first join.
- File size grows when paint/density planes are allocated (POI / edited chunks).
- Format is irreversible for consumers that only understand heights; bump magic
  (ZCH4+) only if layout is non-extensible via flags.

## Alternatives considered

| Option | Notes |
|---|---|
| Stock region read/write | Couples to Unity/Mono save stack; clean-room violation |
| Full stock Chunk.Serialize blob on disk | Larger RE surface; harder to evolve; overkill for overlay |
| Heights-only + blockmeta for every edit | Does not cover full columns or paint channels |
| Always re-TTS after load, never persist paint | Digs over POIs keep orphan textures after restart |
