# ADR 0011: Custom ZCH world overlay (not stock region saves)

- **Status:** accepted
- **Date:** 2026-08-04
- **Updated:** 2026-08-07 (ZPV3 progression tail; document claims/clock/weather siblings); 2026-08-23 (store table synced to the shipped writers: ZPV10/ZCT2/ZBM2/ZCL2; byte layouts now canonical in the owning src files)

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
   non-extensible layout change. Writers only move forward; readers accept the
   listed older magics and upgrade on merge-write. The byte-exact,
   version-aware layouts live in the save/load doc comments of the owning src
   file (`src/server/persist.zig`, `src/world/*.zig`): that code is the
   source of truth for implementers, not this table (the table duplicated it
   once and drifted). Current writers:

| File | Magic (writes) | Still read | Owner |
|---|---|---|---|
| `c_X_Z.zch` | **ZCH3** | pre-paint ZCH3 (flags decide channels) | decision §2; `src/world/store.zig` |
| `players.zsv` | **ZPV10** | **ZPV2**–**ZPV9** | `src/server/persist.zig` (`savePlayers`). Grew from the ZPV3 base (name, pos, coins, inventory, journal, progression tail) by version bumps: bedroll (v4+), journal name + POI rect (v5+), slot `use_times` (v7+), tail hp (v8+), born world time (v9+), slot seed (v10). Merge-write keeps offline names and upgrades old records. Key = login name ([ADR 0017](0017-player-identity-login-name.md)). |
| `containers.zct` | **ZCT2** | **ZCT1** | `src/world/containers.zig` (ZCT2 adds touched_day + grid size_x/size_y) |
| `blockmeta.zbm` | **ZBM2** | **ZBM1** | `src/server/game/blockmeta.zig` (ZBM2 adds the damage plane) |
| `claims.zlc` | **ZCLC** | - | `src/server/persist.zig`: `x,y,z:i32 \| name_len:u8 \| name[32] \| owner_seen_day:u32`. Owner entity is not stored; re-mapped on login by name. |
| `clock.zcl` | **ZCL2** | **ZCL1** | `src/server/game/clock_persist.zig` (ZCL2 adds the persisted blood-moon schedule). Missing file = fresh day 1. |
| `weather.zwt` | **ZWTH1** | - | Storm state machine encode (`src/world/weather.zig`); missing/corrupt = re-roll open groups. |

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
