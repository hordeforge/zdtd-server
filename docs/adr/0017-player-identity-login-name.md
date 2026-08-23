# ADR 0017: Player persist identity is login name (not platform id)

- **Status:** accepted
- **Date:** 2026-08-05
- **Updated:** 2026-08-07 (ZPV3 progression magic landed; identity key unchanged)
- **Related:** [0011](0011-custom-zch-world-overlay.md), [INVENTORY.md](../wire/INVENTORY.md), [GAME_OPTIONS.md](../GAME_OPTIONS.md)

## Context

Reconnect and wipe need a stable key for `players.zsv`. Stock clients expose a
login display name early in join; platform/EOS ids are optional,
version-sensitive, and not fully wired on the EAC-off research path.

File magic: writers emit **ZPV3** (ZPV2 body + progression tail). Readers still
accept **ZPV2** and upgrade on merge-write. See [ADR 0011](0011-custom-zch-world-overlay.md)
for the byte layout. The magic bump was for progression (level/XP/food/water/buffs),
not for identity; the primary key did not change.

## Decision

1. **Primary key = login name** (UTF-8, length-capped on wire/save). Merge-write and `wipeplayer <name>` match on this string, for both ZPV2 and ZPV3 records.
2. **No platform id column** in ZPV2 or ZPV3 until a RE-backed, version-stable id is required for multi-name or rename cases.
3. **Case and collision policy:** exact byte match of the name stored at first join; operators resolve collisions with wipe/rename offline. Do not invent a second soft-id space in sim.

## Consequences

- Rename on the client creates a new persist row (old row remains until wipe).
- Two players cannot safely share one login name on one world file.
- Adding platform id later is a **further magic bump** (or flagged extension) migration, not a
  silent field insert and not a reuse of a magic already spent on another field
  (the bumps after ZPV3 went to bedroll, journal identity, durability, hp,
  born-time and seed; the current writer is ZPV10).

## Alternatives considered

| Option | Notes |
|---|---|
| Platform / EOS id only | Incomplete on EAC-off research path; RE residual |
| Composite name+platform | Better later; needs migration + join path evidence |
| Entity net id as persist key | Not stable across restart |
