# Sleeper volumes and sleeper AI

The sleeper subsystem owns the prefab sleeper volume: the world-space box, the entity group it
spawns, whether it is still armed, and the wake path that turns its zombies from dormant to hunting.
`src/world/sleepers.zig` parses the volumes from the prefab XML and holds the runtime store,
`src/server/game/sleeper.zig` runs the player-entry scan and spawn, and the ECS carries the per
entity sleeper state and the wake request ring. The authored spawn points come from the prefab voxel
data, which [`src/world/tts.zig:71`](../../src/world/tts.zig) decodes. Per
[`src/world/root.zig:1-6`](../../src/world/root.zig) the world package may import util and assets
and must not import wire, server or litenet, so the store holds no net ids and the server layer
composes it with the sim and the wire.

Sources: [`src/world/sleepers.zig`](../../src/world/sleepers.zig),
[`src/world/tts.zig`](../../src/world/tts.zig),
[`src/server/game/sleeper.zig`](../../src/server/game/sleeper.zig),
[`src/server/game/step.zig`](../../src/server/game/step.zig),
[`src/server/game/tick.zig`](../../src/server/game/tick.zig),
[`src/ecs/components.zig`](../../src/ecs/components.zig),
[`src/server/game/init_world.zig`](../../src/server/game/init_world.zig)

## The volume store

The store is an arena-backed flat array capped at 8192 volumes, with at most one group per volume
(`src/world/sleepers.zig:11-12`, `src/world/sleepers.zig:585`). One volume is
(`src/world/sleepers.zig:28`):

```zig
pub const Volume = struct {
    /// World-space AABB (inclusive min, exclusive max) after prefab rotation.
    x0: i32 = 0,
    y0: i32 = 0,
    z0: i32 = 0,
    x1: i32 = 0,
    y1: i32 = 0,
    z1: i32 = 0,
```

Beyond the box, a volume carries its group classes, a `triggered` latch, a `respawn_time` in world
ticks, the alive count it last spawned, a group id and prefab origin for the cascade, a quest-cleared
flag and the authored spawn cells (`src/world/sleepers.zig:36-72`). The store itself is
(`src/world/sleepers.zig:74`):

```zig
pub const Store = struct {
    volumes: []Volume = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,
    /// Count triggered this session.
    trigger_count: u32 = 0,
```

The AABB test floors the queried position, so a volume is inclusive at its minimum corner and
exclusive at its maximum (`src/world/sleepers.zig:102-109`).

## Where the volumes come from

A volume's box comes from the prefab XML, not from the voxel data. `loadFromPrefabs` reads
`SleeperVolumeStart`, `SleeperVolumeSize`, `SleeperVolumeGroup` and `SleeperVolumeGroupId` from each
decoration's XML, rotating local corners into world space with the prefab rotation
(`src/world/sleepers.zig:453-459`, `src/world/sleepers.zig:549-570`):

```zig
pub fn loadFromPrefabs(
    allocator: std.mem.Allocator,
    prefabs_root: []const u8,
    decorations: []const PrefabRef,
    is_sleeper: ?IsSleeperFn,
    sleeper_ctx: ?*anyopaque,
) !Store {
```

The voxel data supplies the authored spawn points. `src/world/tts.zig` decodes the `.tts` block
planes into `TtsBlocks` (`src/world/tts.zig:71-94`) and `loadBlocks` reads one file
(`src/world/tts.zig:323`). For each prefab, `loadFromPrefabs` walks the block cells, resolves each
type id through the `.blocks.nim` local name map, and keeps the cells whose resolved block class is
`Sleeper`; the marker test is the caller's `IsSleeperFn`, with a name-prefix fallback only when no
class table is available (`src/world/sleepers.zig:519-532`, `src/world/sleepers.zig:373-377`). Cells
are filtered to each volume's local box and rotated to world space, so `vol.spawns` holds only points
inside that volume (`src/world/sleepers.zig:587-597`). Without a `.tts` and `.blocks.nim` pair the
list is empty and the spawn path falls back to a scatter inside the box
(`src/world/sleepers.zig:68-71`).

The group string is parsed by form: one token per volume means name only with a 5/5 count, three
tokens per volume means an explicit (name, min, max) triple, and anything else becomes the literal
name `???` with the same 5/5 default (`src/world/sleepers.zig:473-486`,
`src/world/sleepers.zig:571-585`). Volumes are built at world init from the loaded prefab
references, and the count is logged with how many groups resolved against the game stage table
(`src/server/game/init_world.zig:20-88`).

## Trigger and wake paths

There are three ways a volume fires. The first is player entry: every tenth tick the server gathers
joined-player positions and scans unlatched volumes for containment, in parallel when the world is
large enough (`src/server/game/sleeper.zig:16-50`, `src/server/game/sleeper.zig:53-87`):

```zig
pub fn tickSleeperVolumes(self: *Game) void {
```

The second is combat noise, and it is player-independent: a shot inside a POI wakes its sleepers even
before anyone walks in. That scan runs before the sim consumes the noise ring
(`src/server/game/step.zig:142-145`, `src/server/game/sleeper.zig:202-212`). The third is movement
noise queued by the stealth system, scanned after the sim tick drained its own ring
(`src/server/game/step.zig:153-157`, `src/server/game/sleeper.zig:214-224`). Both noise scans use the
same test with a 0.9-block pad on every axis (`src/server/game/sleeper.zig:226-248`).

`triggerVolume` gates on re-arm, refuses a quest-cleared volume, optionally applies the stock global
zombie cap when `[sim] sleeper_cap_gate_enabled` is set, latches `triggered`, then cascades to every
volume of the same prefab placement sharing a nonzero group id. The cascade requires equal origin and
equal prefab name, so two placements of one prefab do not wake each other across the map, and the
latch terminates the recursion (`src/server/game/sleeper.zig:107-147`). Count and class come from the
game stage table when it resolves, otherwise from the group min/max sampled with a position-seeded
random; the per-volume stream is deterministic from the volume index
(`src/server/game/sleeper.zig:149-199`). Each zombie is created through `spawnSleeperDef`, which
stores the 1-based volume link used later for the re-arm recount
(`src/server/game/sleeper.zig:177-183`, `src/ecs/world.zig:1363`).

The wake itself is an ECS transition. The per-entity component is
(`src/ecs/components.zig:1037`):

```zig
pub const Sleeper = struct {
    awake: bool = false,
    volume_r: f32 = 16,
    home_x: f32 = 0,
    home_z: f32 = 0,
```

The AI and damage paths push a wake request into a bounded ring, 16 entries, so a POI full of
sleepers cannot stall the tick (`src/ecs/components.zig:1162-1172`, `src/ecs/world.zig:1015-1029`,
`src/ecs/systems.zig:1962-1965`).
Drain happens on the tick path (`src/server/game/tick.zig:1880`):

```zig
pub fn drainSleeperWakeups(self: *Game) void {
```

A stirred sleeper sends `NetPackageSleeperPassiveChange` and plays the groan; a fully woken one sends
`NetPackageSleeperWakeup` (`src/server/game/tick.zig:1891-1899`,
`src/wire/packages.zig:1311-1317`). Both are broadcasts rather than interest-gated, matching the
stock send with no target entity.

## Re-arm and the 2 Hz cadence

Volumes do not re-spawn while their group lives. `rearmIfExpired` is the gate
(`src/server/game/sleeper.zig:89-105`):

```zig
fn rearmIfExpired(self: *Game, vi: usize) bool {
```

A volume with no cleared `respawn_time` stays latched. A cleared one re-arms once world time passes
`respawn_time`, then sets the next re-arm window to now plus 1000 ticks; `maxInt(u64)` means never
(`src/server/game/sleeper.zig:94-105`). The clear itself is `tickSleeperRearm`: it recounts live
sleeper-spawned zombies per volume through the ECS link, and when a volume that spawned a group has
zero left, sets `respawn_time` to world time plus `LootRespawnDays * 24000` ticks, or never when the
setting is zero (`src/server/game/sleeper.zig:250-282`).

Volume work is 2 Hz side-work, not per-tick. `sleeper_tick_ticks` defaults to 10, which is once per
half second at 20 TPS, and the same modulo drives airdrops, zombie block damage, workstations and the
block radius effects (`src/server/game/types.zig:89`, `src/server/game/types.zig:362-365`,
`src/server/game/step.zig:249-264`). The workstation step receives the elapsed time for the whole
window rather than a single tick (`src/server/game/step.zig:255`).

## Persistence

Two side files keep a cleared or woken POI from re-popping on restart. `sleepers_cleared.zsc`
(ZSCL1) stores the rects whose sleepers a ClearSleepers quest suppressed, and `markClearedRect`
latches both the quest flag and the trigger latch on every overlapping volume
(`src/world/sleepers.zig:116-127`, `src/world/sleepers.zig:129-184`). `sleepers_triggered.zst`
(ZSTG1) stores the rects of volumes players already woke, with a v2 tail carrying the re-arm time;
the loader tolerates a pre-v2 file without the tail (`src/world/sleepers.zig:214-279`). Both are
loaded after the store is rebuilt from prefab XML at world init, so a quest-cleared POI stays clear
across a restart (`src/server/game/init_world.zig:84-88`).

## See also

- [`docs/subsystems/worldgen.md`](worldgen.md) - prefab placement, rotation and the TTS loader.
- [`docs/subsystems/ecs.md`](ecs.md) - the zombie kind group, the systems schedule and the AI hook.
- [`docs/subsystems/tick.md`](tick.md) - the ordered per-tick schedule and the 2 Hz side-work class.
- [`docs/subsystems/persistence.md`](persistence.md) - the save files and the world load order.
- [`docs/subsystems/quests.md`](quests.md) - the ClearSleepers quest and the cleared-rect suppression.
