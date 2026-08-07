# ADR 0011: Custom ZCH world overlay (not stock region saves)

- **Status:** accepted
- **Date:** 2026-08-04
- **Updated:** 2026-08-07 (ZPV3 progression tail; document claims/clock/weather siblings)

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
5. **Sibling stores** stay separate under `--world`. Do not fold them into one
   mega-format until a migration plan exists. Magic bumps only on
   non-extensible layout change. Layouts (source of truth for implementers):

| File | Magic | Layout (LE) |
|---|---|---|
| `c_X_Z.zch` | **ZCH3** | See decision §2 (flagged channels) |
| `players.zsv` | **ZPV3** (writes; **ZPV2** still read) | Header `n:u32` then records: `name_len:u8 \| name \| x,y,z:f32 \| coins:u32 \| inv_n:u8 \| inv_n×(item:u16,count:u16,quality:u8,meta:u16) \| jn:u8 \| jn×(def_id:u16,quest_code:i32,flags:u8,progress:u16,phase:u8)` then **v3 progression tail**: `prog:u8` (0 = absent; 1 = present) \| when 1: `level:u16 \| xp:u64 \| food,food_max,water,water_max:f32×4 \| buff_n:u8 \| buff_n×(def_id:u16, stack:u8, flags:u8, dur_ticks:u32, upd_ticks:u16, upd_rate:i32, dur_max:f32, remove_on_death:u8)`. Merge-write keeps offline names and upgrades bare ZPV2 records by appending `prog=0`. Key = login name ([ADR 0017](0017-player-identity-login-name.md)). |
| `containers.zct` | **ZCT1** | `count:u16` then: `pos xyz:i32×3 \| block_id:i32 \| slot_count:u16 \| touched:u8 \| player:u8 \| slot_count×(item,count,quality,meta)` |
| `blockmeta.zbm` | **ZBM1** | `raw_n:u16 \| raw_n×(key:u64, raw:u32) \| hp_n:u16 \| hp_n×(key:u64, hp:u16)` |
| `claims.zlc` | **ZCLC** | `count:u16` then records: `x,y,z:i32 \| name_len:u8 \| name[32] \| owner_seen_day:u32`. Owner entity is not stored; re-mapped on login by name. |
| `clock.zcl` | **ZCL1** | `worldTime:u64` (stock-shaped: `(day-1)*24000 + hours*1000`). Missing file = fresh day 1. |
| `weather.zwt` | **ZWTH1** | Storm state machine encode (`world/weather.zig`); missing/corrupt = re-roll open groups. |

Slot `item_id` fields are ECS handles (see [ADR 0015](0015-ecs-item-id-vs-stock-type.md)).

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
