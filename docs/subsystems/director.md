# AI director and spawning

This subsystem owns the world clock, the horde schedule and every zombie and animal spawn the sim performs: the blood-moon ladder, the per-spawner gamestage ladders, the weighted entity-group rolls, the chunk heat map, the wandering horde, and the prefab sleeper volumes that wake when a player enters them. `ecs/aidirector.zig` is the runtime: it holds a `Director` resource with the clock and the spawn state, and it reaches the asset tables only through optional function hooks, so the ECS layer never imports `assets` (`src/ecs/aidirector.zig:367`). The tables are parsed in `assets/gamestages.zig` (per-spawner ladders and the player, party and loot stage math), `assets/entitygroups.zig` (the weighted `<e n= p=>` lists) and `assets/spawning.zig` (the biome rules, entity spawners and per-rule budgets); the server wires all three into the director at init. The sleeper volumes live in `world/sleepers.zig` for parsing and `server/game/sleeper.zig` for the scan and spawn. The per-tick position is fixed by the sim schedule, where the director phase runs after buffs and before stealth and AI (`src/ecs/schedule.zig:12`). Import direction is enforced: `ecs` may import `util` only (`src/ecs/root.zig:3`), `assets` may import `util` and pure `ecs` types (`src/assets/root.zig:3`), and `server` may import every package (`src/server/root.zig:3`). The director's own doc comment calls it a lightweight resource for the clock, horde and blood moon (`src/ecs/aidirector.zig:1`), and the hook indirection is what keeps that true.

Sources: [`src/ecs/aidirector.zig`](../../src/ecs/aidirector.zig), [`src/ecs/schedule.zig`](../../src/ecs/schedule.zig), [`src/ecs/rules.zig`](../../src/ecs/rules.zig), [`src/ecs/systems.zig`](../../src/ecs/systems.zig), [`src/assets/gamestages.zig`](../../src/assets/gamestages.zig), [`src/assets/entitygroups.zig`](../../src/assets/entitygroups.zig), [`src/assets/spawning.zig`](../../src/assets/spawning.zig), [`src/world/sleepers.zig`](../../src/world/sleepers.zig), [`src/server/game/sleeper.zig`](../../src/server/game/sleeper.zig), [`src/server/game.zig`](../../src/server/game.zig), [`src/server/game/init_assets.zig`](../../src/server/game/init_assets.zig).

## The clock and the blood-moon ladder

The world clock carries the in-game hour and day, the configured day length, the derived world-time rate, the daylight window and the persisted blood-moon schedule as one value (`src/ecs/aidirector.zig:35`):

```zig
pub const WorldClock = struct {
    hours: f32 = 7.0,
    day: u32 = 1,
    /// GameStats[72] DayNightLength: configured real minutes per in-game day
    /// (config.zig clamps 10..1200). Reported verbatim on the wire.
    day_night_length: u16 = 60,
    /// GameStats[11] TimeOfDayIncPerSec: real world-time rate (ticks/s).
    time_of_day_inc_per_sec: u32 = 6,
```

A day is 24000 world ticks, the rate is stock's integer `24000 / (DayNightLength * 60)`, and the truncation is deliberate: a 60-minute day nominally runs 6.667 ticks per second but stock advances 6, so the real day takes 4000 seconds (`src/ecs/aidirector.zig:14`, `:22`). `setDayNightLength` recomputes that rate whenever the setting changes, so the sim advancement and the stat blob the client is told cannot drift apart (`src/ecs/aidirector.zig:70`). Night is the complement of the daylight window with a strict compare at dusk, because the dusk hour itself is still light (`src/ecs/aidirector.zig:114`). The clock advances one tick's worth of hours and rolls the day over on the 24-hour boundary, and it advances even with no players connected, which the code marks as a deliberate policy divergence from stock's pause (`src/ecs/aidirector.zig:95`).

The blood-moon test spans dusk to the following dawn, so it crosses the midnight rollover (`src/ecs/aidirector.zig:121`):

```zig
    pub fn isBloodMoonNight(self: *const WorldClock) bool {
        if (self.bloodmoon_frequency == 0) return false;
        if (self.hours >= self.dusk) return self.isBloodMoonDay(self.day);
        if (self.hours < self.dawn and self.day > 1) return self.isBloodMoonDay(self.day - 1);
        return false;
    }
```

The schedule itself is a lazy persisted ladder: `next_bm` advances past today with stock's `CalcNextDay` roll, frequency plus a deterministic jitter derived from the cycle number, and a runtime change to frequency or range rebuilds it from cycle 1 (`src/ecs/aidirector.zig:143`). The jitter is a hash of the cycle rather than a random draw so the same seed and inputs give the same horde nights, and existing worlds keep their cadence (`src/ecs/aidirector.zig:166`). `bloodMoonDayFor` reports the active cycle's horde day for the client's stat, which the comment records is not the plain frequency multiple once range jitter is on (`src/ecs/aidirector.zig:172`). Day 1 starts at 07:00, the boot time observed from a fresh stock server (`src/ecs/aidirector.zig:27`).

## Gamestage math

The player stage is stock `EntityPlayer::get_gameStage` reduced to the terms zdtd parses: level, days alive, the biome and quest modifiers, and the global modifier from mods (`src/assets/gamestages.zig:121`):

```zig
pub fn playerStage(cfg: Config, in: StageInputs) i32 {
    const level: f32 = @floatFromInt(in.level);
    const days: f32 = @floatFromInt(in.days_alive);
    const core = (level * (1 + in.biome_mod + in.quest_mod) + days) + in.biome_bonus + in.quest_bonus;
    const v = core * cfg.difficulty_bonus * in.global_modifier;
    if (!std.math.isFinite(v)) return 1;
    return @max(1, floorToI32(v));
}
```

Days alive is the elapsed world time divided by a day, clamped to the player's level, and death pushes the birth stamp forward by the configured penalty or snaps it to now so the unsigned subtraction can never wrap (`src/assets/gamestages.zig:144`, `:153`). The party stage is `CalcPartyLevel`, which sorts the members' stages ascending and walks them top-down scaling each by the diminishing-returns factor starting from the config weight (`src/assets/gamestages.zig:162`):

```zig
pub fn partyLevel(cfg: Config, stages: []i32) i32 {
    if (stages.len == 0) return 0;
    std.mem.sort(i32, stages, {}, std.sort.asc(i32));
    var total: f32 = 0;
    var weight: f32 = cfg.starting_weight;
    var i: usize = stages.len;
    while (i > 0) {
        i -= 1;
        total += @as(f32, @floatFromInt(stages[i])) * weight;
        weight *= cfg.diminishing_returns;
    }
```

The config defaults come from the stock game-stage constructor rather than from the XML, because a config file may omit any attribute (`src/assets/gamestages.zig:30`). A spawner's ladder is ascending by stage number and `getStage` returns the highest stage at or below the requested number, or null below the first stage, matching the stock binary search (`src/assets/gamestages.zig:79`). A stage's spawn rows are selected by index by `spawnGroup`, which clamps into range (`src/assets/gamestages.zig:65`); the director's nightly walk instead uses the unclamped indexed lookup so it can detect the end of the rows. Group names are keyed by `CleanName`, which drops one leading digit or an `S_` / `S_-` prefix and removes underscores, because both the prefab sleeper volumes and the `.tts` reader clean before lookup (`src/assets/gamestages.zig:100`). Blood-moon and wandering-horde loot cadences also come from the config block, and the server pushes the nightly cadence into the director with the stage freeze (`src/assets/gamestages.zig:41`, `src/server/game.zig:3657`). Loot stage is its own function, driven by player level rather than game stage and with no days-alive term (`src/assets/gamestages.zig:177`). The input comments state plainly that zdtd passes zeros where the biome and quest tables are not parsed yet (`src/assets/gamestages.zig:118`).

## Entity-group rolls

An entity group is a named list of entity class names with relative weights, held as one flat arena slice rather than a per-group fixed array, because the stock file has 1875 groups and a group-count cap would silently drop the horde groups at the tail (`src/assets/entitygroups.zig:19`). A pick is deterministic in the seed and integer-based, so it does not depend on floating-point accumulation order across machines (`src/assets/entitygroups.zig:54`):

```zig
    pub fn pick(self: *const GroupTable, group_name: []const u8, seed: u32) ?[]const u8 {
        const g = self.byName(group_name) orelse return null;
        if (g.entries.len == 0 or g.weight_sum <= 0) return null;
        const s = seed *% 1103515245 +% 12345;
        // milli-weight: round(weight * 1000). Integer walk; r in [0, sum).
        var sum_mw: u64 = 0;
        for (g.entries) |e| {
            if (e.weight <= 0) continue;
            sum_mw += @as(u64, @round(e.weight * 1000.0));
        }
```

Weights are folded into milli-units and the roll walks the list accumulating, so a zero or negative weight is skipped rather than biasing the distribution, and an oversized modded weight cannot trap the cast because the ceiling is named and explicit (`src/assets/entitygroups.zig:15`, `:70`). The director never calls this directly: `group_pick_fn` is an optional hook on the `Director` that the server wires to the table, and the ECS layer stays free of asset imports (`src/ecs/aidirector.zig:332`). The same pattern covers the per-type tables: the biome spawn-group resolver, the entity-class resolver that lets a picked class which was never preloaded still spawn with its own stats, the ground-permission check that mirrors `CanMobsSpawnAtPos`, the stage lookups, and the per-spawner wave range (`src/ecs/aidirector.zig:335`, `:344`, `:346`, `:370`). Each hook has a documented null behavior, which is the offline and no-game-dir path.

## The per-tick order

`Director.tick` runs the clock first, then the countdowns, then one gate that decides whether this tick may spawn at all (`src/ecs/aidirector.zig:542`):

```zig
    pub fn tick(self: *Director, w: *ecs_world.World, dt: f32) struct { spawned: u32, world_time: u64 } {
        const day_before = self.clock.day;
        self.clock.tick(dt);
        var spawned: u32 = 0;

        if (self.horde_cd > 0) self.horde_cd -= dt;
        if (self.bloodmoon_cd > 0) self.bloodmoon_cd -= dt;
        if (self.scouts_cd > 0) self.scouts_cd -= dt;
        if (self.animals_cd > 0) self.animals_cd -= dt;

        self.bloodmoon_active = self.clock.isBloodMoonNight();
```

The spawn flag combines the systems toggle with the alive-zombie cap, and the blood-moon cap is the world cap multiplied by the stock 1.9 ceiling so the horde does not thin at the ordinary limit (`src/ecs/aidirector.zig:566`, `:570`). The cap is a spawn gate and not an early return: heat decay, blood-moon teleports, the end-of-night cleanup, animals and the daily trader restock all still run when the world is full (`src/ecs/aidirector.zig:562`). The starter population fills once toward a configured fraction of the cap in batches of four per tick, so a cold boot cannot spawn the whole population in one tick (`src/ecs/aidirector.zig:579`, `:587`). Then, in order: the night horde drip on its cooldown (`:598`); the blood moon block, which freezes the party stage at dusk, seeds the bonus-loot counter, forms the parties, recounts and teleports stragglers, advances the nightly spawn-group walk or falls back to the legacy first-row burst, and resets the horde marks at dawn (`:602`, `:666`); the wandering-horde schedule, which is gated on a player being online and stays due while the cap is full instead of being dropped (`:685`); the heat map decay and scout roll (`:694`); the daytime scout drip (`:696`); then animals, and a trader restock when the day counter changed (`:703`, `:704`). The blood-moon party state is the stock party model: players within the join distance share one focus and one frozen stage for the night, and horde zombies past the teleport distance are pulled back each tick (`src/ecs/aidirector.zig:405`).

The schedule calls this system unconditionally, because the director owns the world clock and the daily restock and applies its own toggle to spawning only; disabling the whole phase would freeze day and night (`src/ecs/schedule.zig:94`). The systems toggle it reads is documented next to the field: `director = false` stops zombie spawning but keeps the clock, the blood-moon flag and the trader restock (`src/ecs/rules.zig:27`). Wildlife is a separate toggle, `animals`, mirroring stock where the biome spawn manager is a system separate from the AIDirector, so a no-zombie mode can keep wandering wildlife (`src/ecs/rules.zig:30`). The `animals` slot exists in the schedule's named order only so the field count matches; the wildlife pass itself runs inside the director tick and a second call would double-spawn (`src/ecs/schedule.zig:71`). The tuning constants for the gaps, rings, cooldowns and caps are all fields of the `Director` rules group, so a mode pack moves them without touching the sim (`src/ecs/rules.zig:670`).

## Sleeper spawn

Sleepers are not director spawns: they belong to prefab volumes parsed from the world's placement data, and the server runs one scan per tick over the volumes a player may have entered (`src/server/game/sleeper.zig:53`). The scan is a range-parallel pass over the volumes, marking each one that contains a joined player and then triggering it on the main thread, so the spawn work itself stays serial and deterministic (`src/server/game/sleeper.zig:64`, `:82`). A volume that was cleared re-arms only after its respawn time, and one suppressed by a completed ClearSleepers quest never re-arms at all (`src/server/game/sleeper.zig:89`, `:115`). A volume with a nonzero group id wakes every sibling volume of the same prefab placement sharing that id, which is the stock `TouchGroup` cascade; origin and prefab name equality keep duplicate placements of one prefab from waking each other across the map, and the triggered latch terminates the recursion (`src/server/game/sleeper.zig:131`). The global `CanSpawn(2.1)` gate is behind an off-by-default flag, and the code marks spawning regardless of the global cap as the documented zdtd divergence (`src/server/game/sleeper.zig:117`, `:126`). The volume store caps at 8192 volumes and four groups per volume, and it persists its cleared and triggered state separately from the chunk store (`src/world/sleepers.zig:11`). A sleeper z is a normal sim entity once awake, so AI, wake conditions and the sleeper component are the same paths the rest of the AI uses (`src/ecs/systems.zig:1913`).

## See also

- [`ecs.md`](ecs.md): the world, entity table and components the spawned zombies become.
- [`tick.md`](tick.md): the full phase order and where the director sits in it.
- [`assets.md`](assets.md): how the three XML tables reach the loaders and their caps.
- [`map.md`](map.md): prefab placement and the POI data the sleeper volumes come from.
- [`movement.md`](movement.md): the AI path and movement the spawned entities use.
