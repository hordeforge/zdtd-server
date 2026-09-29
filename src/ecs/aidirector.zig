//! Lightweight AIDirector as ECS resource (world clock, horde, blood moon).

const std = @import("std");
const rules_mod = @import("rules.zig");
pub const director_defaults: rules_mod.Director = .{};
const ecs_world = @import("world.zig");

/// Starter population batch per tick (initial_population_frac fill): 4
/// spawns per tick caps the fill at ~200 ms of sim work on a cold boot
/// instead of one tick spawning the whole population.
const initial_population_batch: u32 = 4;

/// In-game ticks per day (DayTimeToWorldTime: 24000 ticks, 1000 per hour).
pub const ticks_per_day: u64 = 24000;

/// Stock GameStats[11] TimeOfDayIncPerSec: world-time ticks advanced per real
/// second, `24000 / (DayNightLength * 60)` in **integer** arithmetic
/// (RE ../7dtd-engine-research/docs/admin/server-lifecycle.md:168; live
/// `getgamestat TimeOfDayIncPerSec` = 6 at the default 60 real-minute day).
/// The truncation is the point: a 60 minute day nominally runs 6.667 ticks/s
/// but stock advances 6, so it really takes 24000/6 = 4000 real seconds. A day
/// over 400 real minutes divides to 0 (frozen world time), which is what the
/// stock expression does; `WorldClock.tick` reproduces that rather than
/// inventing a floor.
pub fn timeOfDayIncPerSec(minutes_per_day: u16) u32 {
    const minutes: u32 = @max(minutes_per_day, 1);
    return @intCast(ticks_per_day / (@as(u64, minutes) * 60));
}

/// Sim world clock. Starts day 1, 07:00 (stock dedicated boot time, observed
/// live 2026-08-11: `gettime` on a fresh stock server reads "Day 1, 07:00").
/// DayNightLength (serverconfig, default 60 real minutes per day) sets the
/// rate through `timeOfDayIncPerSec`; the clock stores both so the sim rate and
/// the GameStats blob the client is told can never drift apart.
pub const WorldClock = struct {
    hours: f32 = 7.0,
    day: u32 = 1,
    /// GameStats[72] DayNightLength: configured real minutes per in-game day
    /// (config.zig clamps 10..1200). Reported verbatim on the wire.
    day_night_length: u16 = 60,
    /// GameStats[11] TimeOfDayIncPerSec: real world-time rate (ticks/s).
    time_of_day_inc_per_sec: u32 = 6,
    /// Daylight window [dawn, dusk]; night is outside it (stock `World.IsDark`
    /// IL=31: `hour < DawnHour || hour > DuskHour` - the dusk hour itself is
    /// still light, weather-environment.md boundary derivation).
    dawn: f32 = 4.0,
    dusk: f32 = 22.0,
    /// BloodMoonFrequency: blood moon every N days. NOTE (live-observed
    /// 2026-08-11): a stock 0 config does NOT disable - the sandbox option
    /// default (7) applies; zdtd's 0-disables here is a deliberate policy
    /// divergence (aidirector.md SetDay/CalcNextDay).
    bloodmoon_frequency: u32 = 7,
    /// BloodMoonRange: deterministic ±day jitter around each frequency multiple.
    bloodmoon_range: u8 = 0,
    /// Persisted blood-moon schedule (stock `CalcNextDay`, asm.il 412880):
    /// `next_bm = bm_day_last + frequency + RandomRange(0, range+1)` rolled at
    /// each cycle. `bm_cycle` is the schedule position and `bm_freq` /
    /// `bm_range` remember the settings the schedule was built for (a runtime
    /// change recomputes). 0 = uninitialized. Survives restart via clock.zcl
    /// so the client's red moon stays on the horde night across day jumps.
    bm_cycle: u32 = 0,
    bm_day_last: u32 = 0,
    next_bm: u32 = 0,
    bm_freq: u32 = 0,
    bm_range: u8 = 0,

    /// Real minutes per in-game day from serverconfig DayNightLength. Recomputes
    /// the stock TimeOfDayIncPerSec rate, so the world advances at the very rate
    /// the GameStats blob advertises.
    pub fn setDayNightLength(self: *WorldClock, minutes_per_day: u16) void {
        self.day_night_length = @max(minutes_per_day, 1);
        self.time_of_day_inc_per_sec = timeOfDayIncPerSec(self.day_night_length);
    }

    pub fn setDayLightLength(self: *WorldClock, daylight_hours: u8) void {
        // Stock GameUtils::CalcDuskDawnHours (IL=45, weather-environment.md
        // boundary derivation; asm.il 1926249): a DayLightLength
        // of 0 or 24 returns (dusk 22, dawn 4); otherwise dusk starts at 22,
        // clamps to DayLightLength when > 22, becomes 12 + DL/2 when < 18, and
        // dawn = clamp(dusk - DL, 0, 23).
        const dl = daylight_hours;
        if (dl == 0 or dl == 24) {
            self.dawn = 4.0;
            self.dusk = 22.0;
            return;
        }
        var dusk: f32 = 22.0;
        if (dl > 22) dusk = @floatFromInt(dl);
        if (dl < 18) dusk = 12.0 + @as(f32, @floatFromInt(dl)) / 2.0;
        const dawn = std.math.clamp(dusk - @as(f32, @floatFromInt(dl)), 0, 23);
        self.dusk = dusk;
        self.dawn = dawn;
    }

    pub fn tick(self: *WorldClock, dt: f32) void {
        // DIVERGENCE (docs/DIVERGENCES.md 6.1): stock dedicated pauses world
        // time with zero connected players (live-observed 2026-08-11,
        // server-lifecycle.md 5); zdtd advances unconditionally - a policy
        // simplification, not a stock behavior.
        self.hours += self.hoursFor(dt);
        while (self.hours >= 24.0) {
            self.hours -= 24.0;
            self.day +%= 1;
        }
    }

    /// In-game hours elapsed over `dt` real seconds at the stock world rate:
    /// `time_of_day_inc_per_sec` world ticks per real second, 1000 ticks per
    /// in-game hour. Zero when the rate is frozen (DayNightLength > 400).
    pub fn hoursFor(self: *const WorldClock, dt: f32) f32 {
        return dt * @as(f32, @floatFromInt(self.time_of_day_inc_per_sec)) / 1000.0;
    }

    pub fn isNight(self: *const WorldClock) bool {
        // Stock World.IsDark IL=31: dark iff hour < DawnHour || hour > DuskHour
        // (the dusk hour itself is still light). The `>` (not `>=`) matters at
        // exactly 22:00.
        return self.hours < self.dawn or self.hours > self.dusk;
    }

    /// Stock GameUtils::IsBloodMoonTime (IL=10 / asm.il 1926341,
    /// aidirector.md): the blood moon spans
    /// dusk on the scheduled day through dawn of the next day, crossing the
    /// midnight rollover. True when the current day is the scheduled day and it
    /// is at/after dusk (`hour >= duskHour`, the BM gate is INCLUSIVE of dusk,
    /// unlike IsDark's `>`), or the day after the scheduled day before dawn.
    pub fn isBloodMoonNight(self: *const WorldClock) bool {
        if (self.bloodmoon_frequency == 0) return false;
        if (self.hours >= self.dusk) return self.isBloodMoonDay(self.day);
        if (self.hours < self.dawn and self.day > 1) return self.isBloodMoonDay(self.day - 1);
        return false;
    }

    fn isBloodMoonDay(self: *const WorldClock, day: u32) bool {
        if (self.bloodmoon_frequency == 0) return false;
        self.ensureBmSchedule(day);
        // The dawn-crossing leg (isBloodMoonNight) tests the day before the
        // scheduled one too, so both the current and the previous target
        // count (they are never equal: next_bm > bm_day_last by construction).
        return day == self.next_bm or day == self.bm_day_last;
    }

    /// The persisted schedule position: advance `next_bm` past `today` using
    /// the stock CalcNextDay roll (bm_day_last + frequency + RandomRange(0,
    /// range+1)); the jitter is the deterministic hash of the cycle (same
    /// stream as the old live derivation, so existing worlds keep their
    /// cadence). A runtime frequency/range change rebuilds the schedule from
    /// cycle 1.
    fn ensureBmSchedule(self: *const WorldClock, today: u32) void {
        // Const-cast: the schedule is lazy state cached from the live clock.
        const wc: *WorldClock = @constCast(self);
        if (wc.next_bm == 0 or wc.bm_freq != self.bloodmoon_frequency or wc.bm_range != self.bloodmoon_range) {
            wc.bm_cycle = 0;
            wc.bm_day_last = 0;
            wc.bm_freq = self.bloodmoon_frequency;
            wc.bm_range = self.bloodmoon_range;
            wc.next_bm = wc.bmDayForCycle(1);
        }
        while (wc.next_bm < today and wc.next_bm != 0) {
            wc.bm_day_last = wc.next_bm;
            wc.bm_cycle += 1;
            wc.next_bm = wc.bmDayForCycle(wc.bm_cycle + 1);
        }
    }

    fn bmDayForCycle(self: *const WorldClock, cycle: u32) u32 {
        const span: u32 = @as(u32, self.bloodmoon_range) + 1;
        const jitter: u64 = (@as(u64, cycle) *% 2654435761) % span;
        return @as(u32, @intCast(@as(u64, cycle) * self.bloodmoon_frequency + jitter));
    }

    /// The scheduled blood-moon day for the client's stat 58 (GameStats
    /// BloodMoonDay): the horde day of the active cycle - the next persisted
    /// schedule day at/after `today` (stock CalcNextDay). NOT the plain
    /// frequency multiple: with BloodMoonRange jitter the horde can land on
    /// day c*freq+1, and the old multiple put the client's red moon on the
    /// wrong night (a non-horde multiple lit up, the actual horde night
    /// showed nothing). Cycle 1 is the first horde; cycle 0 is pre-game.
    pub fn bloodMoonDayFor(self: *const WorldClock, today: u32) i32 {
        if (self.bloodmoon_frequency == 0) return 0;
        self.ensureBmSchedule(today);
        return @intCast(self.next_bm);
    }

    /// Stock DayTimeToWorldTime: (day-1)*24000 + hours*1000 (+ minutes*1000/60).
    /// Day 1 spans [0, 24000); WorldTimeToDays(wt) = wt/24000 + 1. A day-0
    /// clock (test convention) encodes as 0 rather than underflowing.
    pub fn worldTimeBits(self: *const WorldClock) u64 {
        const d: u64 = if (self.day > 0) self.day - 1 else 0;
        const day_part: u64 = d * 24000;
        const hour_part: u64 = @trunc(self.hours * 1000.0);
        return day_part + hour_part;
    }
};

/// World time units per game hour (stock `DayTimeToWorldTime`, 24000/day).
pub const world_time_units_per_hour: u64 = 1000;

/// Resolved gamestages.xml `<spawn>` row: which entitygroup, and how many.
/// Carries the pacing fields stock's party spawner walks (`SetupGroup`:
/// `interval` seconds between spawns, `duration` seconds before the next
/// group row, 0 = no time gate; `num` total spawns before the row is done).
pub const StageGroup = struct {
    group: []const u8 = "",
    num: u16 = 1,
    max_alive: u16 = 1,
    interval: u16 = 2,
    duration: u16 = 0,
};

/// An `<entityspawner>` TotalPerWave min/max pair (min 0 = property absent).
pub const WaveRange = struct {
    min: u32 = 0,
    max: u32 = 0,
};

/// AIDirectorChunkEventComponent::SpawnScouts (asm.il ~415972): the scout
/// `<entityspawner>` is picked purely by party game stage at 45 / 85 / 125.
pub fn scoutSpawnerName(party_stage: i32) []const u8 {
    if (party_stage < 45) return "Scouts1";
    if (party_stage < 85) return "Scouts2";
    if (party_stage < 125) return "ScoutsFeral";
    return "ScoutsRadiated";
}

/// Blood-moon party storage bound. The tuning constants (join/teleport/spawn
/// distances, party enemy cap, party count) live in rules.zig
/// `w.rules.bloodmoon` (ADR 0021): the per-tick reads go through the rule, and
/// `max_parties` is clamped to this array bound at use. The stock values are
/// AIDirectorBloodMoonParty constants (asm.il 413090-413140).
pub const bm_parties_cap: usize = 8;

/// AIDirectorWanderingHordeComponent (asm.il 419473-419490): a scheduled group
/// of ~6 zombies spawns ~92 m out and walks in as a pack. ChooseNextTime picks
/// worldTime + RandomRange(12000, 24000) ticks (12-24 in-game hours); the
/// schedule is player-gated (no players -> re-choose) and only starts after
/// day 1 (worldTime > 28000).
/// Wandering horde (RE: aidirector.md wandering-horde scheduling): the pack
/// spawns `wandering_spawn_dist` blocks out every
/// wander_min_gap..wander_max_gap (12-24 in-game hours of world time) once the
/// world is past wander_start_after, sized and grouped by the `WanderingHorde`
/// gamestages.xml ladder (that is the "gamestage-group driven" size observed
/// live on 2026-08-11: "enemy max 5" for GS 1). `wandering_spawn_dist` 92 is
/// the `FindTargets` inline start offset (`RandomOnUnitCircle * 92f`, IL_018B,
/// aidirector.md placement constants). `wandering_horde_size` is only the
/// fallback for when no ladder is wired (offline or builtin tables). Both are
/// `[rules.director]` tunables (ADR 0021); these aliases are the builtin
/// defaults (tests reference them).
pub const wandering_horde_size: u32 = director_defaults.wandering_horde_size;
pub const wandering_spawn_dist: f32 = director_defaults.wandering_spawn_dist;
pub const wander_min_gap: u64 = director_defaults.wander_min_gap;
pub const wander_max_gap: u64 = director_defaults.wander_max_gap;
pub const wander_start_after: u64 = director_defaults.wander_start_after;

/// AIDirectorChunkData heat map (asm.il 414504-415200): 5x5-chunk regions
/// accumulate activity from heat blocks (forges/campfires, blocks.xml
/// HeatMapStrength) and expire over the event duration; a region crossing 25
/// spawns a scout party (Scouts1/2/Feral/Radiated by gamestage) on the 5 s
/// check, then cooldowns the region and its neighbors. Blood moons suppress
/// new heat (NotifyActivity gate). The threshold / check / cooldown / scout
/// distance are `[rules.director]` tunables; the aliases are the defaults.
pub const heat_region_world: i32 = 16 * 5; // 5 chunks x 16 blocks
pub const heat_spawn_threshold: f32 = director_defaults.heat_spawn_threshold;
pub const heat_check_seconds: f32 = director_defaults.heat_check_seconds;
pub const heat_cooldown_seconds: f32 = director_defaults.heat_cooldown_seconds;
pub const heat_neighbor_cooldown_seconds: f32 = director_defaults.heat_neighbor_cooldown_seconds;
/// GameDifficulty / ZombieMove tier multipliers are `[rules.director]`
/// per-tier scalars (difficulty_hp_0..5, move_scale_0..4); the const arrays
/// moved there (numbers zdtd-tuned R9, operator policy).
pub const max_heat_regions: usize = 32;
/// Ambient spawn rule budget slots, keyed by the spawning.xml rule index.
/// Matches the parsed table bound (`assets/spawning.zig max_rules`): stock
/// has no cap, so a modlet patch adding rules past the old 64 no longer
/// silently loses its maxcount/respawn budget. 512 × 16 B = 8 KiB per
/// Director.
pub const rule_budget_cap: usize = 512;
pub const heat_scout_dist: f32 = director_defaults.heat_scout_dist; // chunk-heat spawner 0/8/10 constants

pub const HeatRegion = struct {
    key: i64 = 0,
    activity: f32 = 0,
    /// Per-second decay (sum of value/duration over the active events).
    decay: f32 = 0,
    cooldown: f32 = 0,
};

pub const BmParty = struct {
    focus_x: f32 = 0,
    focus_z: f32 = 0,
    members: u32 = 0,
    /// Horde zombies currently alive for this party (recounted each BM tick).
    alive: u32 = 0,
};

/// Per-rule ambient spawn budget (spawning.xml `maxcount` / `respawn_days`).
/// The Game resolves the rule under a spawn point; the Director enforces the
/// cap and the respawn delay (stock ChunkAreaBiomeSpawnData CountsAndTime per
/// spawn group: CanSpawn = count < maxCount, count decremented on death and
/// reset when the respawn delay elapses, spawning.md §3).
pub const RuleBudget = struct {
    /// Index into the spawning.xml rule table (0xffff = no rule / no budget).
    index: u16 = 0xffff,
    maxcount: u8 = 0,
    /// Respawn delay in game days (spawning.xml respawndelay).
    respawn_days: f32 = 1.0,
};

/// Per-rule runtime state (spawned-alive count + next respawn world time).
pub const RuleBudgetState = struct {
    count: u8 = 0,
    next_respawn_wt: u64 = 0,
};

pub const Director = struct {
    /// Spawn-group kind for per-biome resolution (spawning.xml rule kind).
    pub const SpawnKind = enum(u8) { night = 0, day = 1, animal = 2 };

    /// Ambient spawn rule budgets, keyed by the spawning.xml rule index. The
    /// array is fixed-size; indices beyond it are treated as unbudgeted.
    rule_budgets: [rule_budget_cap]RuleBudgetState = [_]RuleBudgetState{.{}} ** rule_budget_cap,
    /// Optional per-spawn-point rule resolver: (ctx, x, z, kind) -> budget.
    /// Game wires the spawning.xml table; null = unbudgeted ambient spawns.
    rule_budget_ctx: ?*anyopaque = null,
    rule_budget_fn: ?*const fn (?*anyopaque, f32, f32, SpawnKind) RuleBudget = null,

    clock: WorldClock = .{},
    horde_cd: f32 = 0,
    /// Entity group names from spawning.xml (empty → class_table rotation).
    night_group: []const u8 = "",
    day_group: []const u8 = "",
    animal_group: []const u8 = "",
    /// Optional pick: (ctx, group_name, seed) → class name; Game wires entitygroups.
    group_pick_ctx: ?*anyopaque = null,
    group_pick_fn: ?*const fn (?*anyopaque, []const u8, u32) ?[]const u8 = null,
    /// Per-player biome spawn-group resolver: (ctx, x, z, kind, fallback) →
    /// the group NAME for the biome under the spawn point (night/day/animal),
    /// or the fallback when the biome/rule is unknown. Game wires spawning.xml.
    biome_group_ctx: ?*anyopaque = null,
    biome_group_fn: ?*const fn (?*anyopaque, f32, f32, SpawnKind, []const u8) []const u8 = null,
    /// Optional resolve: (ctx, class_name) → the full entityclasses stats, so
    /// a picked class that was not preloaded into the fixed class_table still
    /// spawns with its own HP/speeds/damage/hash/loot (A35). Game wires the
    /// entities table; null keeps the old class_table-only resolution.
    class_resolve_ctx: ?*anyopaque = null,
    class_resolve_fn: ?*const fn (?*anyopaque, []const u8) ?ecs_world.EntityClass = null,
    /// Ground permission for a mob spawn: (ctx, x, y, z) -> true when the block
    /// at that cell may carry a spawn. Stock `Chunk::CanMobsSpawnAtPos`
    /// (IL_0043/IL_004E) requires the block under the spawn cell to be
    /// `CanMobsSpawnOn` AND movement-solid. Game wires the blocks table; null
    /// keeps every position allowed (the pre-parse behaviour and the offline
    /// world, where no blocks.xml table exists).
    mob_spawn_ok_ctx: ?*anyopaque = null,
    mob_spawn_ok_fn: ?*const fn (?*anyopaque, i32, i32, i32) bool = null,

    /// Party game stage (CalcGameStageAround over the online players). Drives
    /// the scout tier and the blood moon stage lookup. 0 = no players / unknown.
    party_stage: i32 = 0,
    /// Sandbox 43 `MaxEnemyTier` (the value behind `EntityFactory.MaxEntityTier`,
    /// cctor default 5 = Elite). A spawn whose class sits above this is replaced
    /// by the first class at or below it on its `PreviousTier` ladder; a class
    /// with no configured ladder is refused, exactly like stock's
    /// `GetEntityClassWithinMaxTier` (IL=30) returning null.
    max_enemy_tier: u8 = 5,
    /// Weighted party level (`GameStageDefinition::CalcPartyLevel` over the
    /// party members), pushed by the Game each tick. The blood moon freezes
    /// this rather than `party_stage`, because stock's
    /// `AIDirectorBloodMoonParty::InitParty` IL_0006 resolves the ladder from
    /// `partySpawner.CalcPartyLevel()`; a two-player party at stage 40/80
    /// therefore rolls its waves at the weighted level, not the 80 high-water
    /// mark. 0 = not pushed, fall back to `party_stage`.
    party_stage_weighted: i32 = 0,
    /// Optional lookup: (ctx, spawner_name, stage) → entitygroup name plus wave
    /// size, resolving gamestages.xml. Game wires it; the ECS layer stays free
    /// of asset imports, matching the group_pick_fn contract above. First-row
    /// only (legacy burst path); the nightly walk uses `stage_group_at_fn`.
    stage_group_ctx: ?*anyopaque = null,
    stage_group_fn: ?*const fn (?*anyopaque, []const u8, i32) ?StageGroup = null,
    /// Optional lookup: (ctx, spawner_name, stage, index) → the stage's row at
    /// `index`, null past the end (stock `Stage.GetSpawnGroup`, which returns
    /// null out of range). Feeds the nightly group walk.
    stage_group_at_ctx: ?*anyopaque = null,
    stage_group_at_fn: ?*const fn (?*anyopaque, []const u8, i32, u32) ?StageGroup = null,
    /// Optional lookup: (ctx, wx, wz, radius) → the weighted party game stage
    /// of the players around that point, stock
    /// `GameStageDefinition::CalcGameStageAround`. The wandering-horde ladder
    /// scales its spawner's own member players rather than the whole server, so
    /// a wired hook beats the tick's `party_stage` (which is the group high
    /// water mark). Null keeps `party_stage`.
    stage_around_ctx: ?*anyopaque = null,
    stage_around_fn: ?*const fn (?*anyopaque, f32, f32, f32) i32 = null,

    /// Optional lookup: (ctx, entityspawner_name) → EntityGroupName from
    /// spawning.xml, for the code-named scout spawners.
    spawner_group_ctx: ?*anyopaque = null,
    spawner_group_fn: ?*const fn (?*anyopaque, []const u8) ?[]const u8 = null,
    /// Optional lookup: (ctx, entityspawner_name) → that spawner's
    /// `TotalPerWave` min/max from spawning.xml (min 0 = unset). Stock sizes a
    /// scout wave per tier (Scouts1 1, Scouts2 2, ScoutsFeral and
    /// ScoutsRadiated "1,2") and rolls in the range, so without it every tier
    /// spawns the same count.
    spawner_wave_ctx: ?*anyopaque = null,
    spawner_wave_fn: ?*const fn (?*anyopaque, []const u8) WaveRange = null,
    bloodmoon_cd: f32 = 0,
    scouts_cd: f32 = 0,
    total_spawned: u32 = 0,
    /// Threshold crossings evaluated by the chunk-heat spawner. Only the
    /// deterministic `cSpawnChance` roll reads it; never persisted (heat
    /// regions are rebuilt from live activity, not save state).
    heat_checks: u32 = 0,
    bloodmoon_active: bool = false,
    /// Blood-moon party state (AIDirectorBloodMoonParty, 413090-413140):
    /// players within cPartyJoinDistance 80 m share one focus and one
    /// per-party wave; the party gamestage is frozen for the night; horde
    /// zombies beyond cTeleportDist 150 m are teleported back.
    bm_parties: [bm_parties_cap]BmParty = [_]BmParty{.{}} ** bm_parties_cap,
    bm_party_n: u8 = 0,
    /// Party gamestage snapshot at dusk (stock InitParty freezes it).
    bm_stage_frozen: i32 = 0,
    /// Nightly spawn-group walk (`AIDirectorGameStagePartySpawner`: `groupIndex`
    /// into the frozen stage's rows, `SetupGroup` per row). `bm_group_index`
    /// is the current row, `bm_spawned_in_group` counts spawns against its
    /// `num` (`canSpawn = spawnCount < numToSpawn`), `bm_group_deadline` is
    /// the world-time tick when a `duration` row expires (0 = no time gate),
    /// and `bm_spawn_at` paces spawns within the row by its `interval`
    /// seconds. Reset at each dusk freeze; the walk ends when the rows run
    /// out (stock `get_IsDone = groupIndex > 0 && spawnGroup == null`), and
    /// the wave loop falls back to the legacy first-row burst.
    bm_group_index: u32 = 0,
    bm_spawned_in_group: u32 = 0,
    bm_group_deadline: u64 = 0,
    bm_spawn_at: f32 = 0,
    /// Blood-moon bonus-loot spawn counter
    /// (`AIDirectorBloodMoonParty.bonusLootSpawnCount`): incremented per
    /// non-vulture horde spawn; when it reaches `bonus_loot_every` it resets
    /// and that zombie's `lootDropProb` scales by `loot_bonus_scale`
    /// (SpawnZombie IL_00CD-0102). Seeded at `bonus_loot_every / 2` when the
    /// night's parties form (InitParty IL_0072-0080). The per-night
    /// `bonus_loot_every` itself is `max(stageSpawnMax / LootBonusMaxCount,
    /// LootBonusEvery)` (SetPartyLevel IL_007C); zdtd resolves it from the
    /// frozen party stage the same way through the gamestage table.
    bm_bonus_count: u32 = 0,
    bm_bonus_every: u32 = 0,
    bm_bonus_scale: f32 = 1.0,
    /// Wandering-horde bonus-loot spawn counter
    /// (`AIWanderingHordeSpawner.bonusLootSpawnCount`): same shape against
    /// `wander_bonus_every` x `wander_bonus_scale`
    /// (AIWanderingHordeSpawner IL_00F8-011C). Both refresh from the
    /// gamestages.xml config block each tick (the Game syncs them; the ECS
    /// layer stays free of asset imports).
    wander_bonus_count: u32 = 0,
    wander_bonus_every: u32 = 3,
    wander_bonus_scale: f32 = 15.0,
    /// World time (ticks) of the next wandering horde (0 = not scheduled yet).
    /// ChooseNextTime: now + RandomRange(12000, 24000); player-gated.
    wandering_next: u64 = 0,
    /// Heat map regions (AIDirectorChunkData), dense array capped.
    heat: [max_heat_regions]HeatRegion = [_]HeatRegion{.{}} ** max_heat_regions,
    heat_n: u8 = 0,
    heat_check_cd: f32 = 0,
    /// Alive-zombie ceiling (MaxSpawnedZombies). Defaults to the dev cap; the
    /// operator's serverconfig raises it. See default_max_alive_zombies.
    max_alive: u32 = default_max_alive_zombies,
    /// GameDifficulty 0..5 (1 = Adventurer, the stock default game); scales
    /// zombie hp (proxy for stock damage scaling) and picks the
    /// `[rules.difficulty] incoming_damage_N` ladder (comptime XML presets).
    difficulty: u8 = 1,
    /// SandboxCode option 17 IncomingDamage flat override (0 = unset): a
    /// custom operator code wins over the per-difficulty ladder, exactly
    /// like stock's single IncomingDamageModifier static
    /// (UpdateInGameValuesWithSandboxOptions).
    sandbox_incoming: f32 = 0,
    /// ZombieMove / ZombieMoveNight / ZombieFeralMove / ZombieBMMove indices 0..4.
    zombie_move_day: u8 = 0,
    zombie_move_night: u8 = 3,
    zombie_move_feral: u8 = 3,
    zombie_move_bm: u8 = 3,
    /// EnemyDifficulty: 0 = normal, 1 = feral (use feral speed at all times).
    enemy_difficulty: u8 = 0,
    /// BloodMoonEnemyCount: zombies per blood-moon wave (per spawn burst).
    bloodmoon_enemy_count: u8 = 8,
    /// BloodMoonRange: deterministic ±day jitter around the frequency multiple.
    bloodmoon_range: u8 = 0,
    /// MaxSpawnedAnimals: daytime wildlife cap (0 disables animal spawning).
    max_alive_animals: u32 = 0,
    animals_cd: f32 = 0,
    /// Starter population fill has run (one-time per world; stock fills loaded
    /// regions toward their maxcounts as they load - see tick()).
    initial_population_done: bool = false,

    /// Alive-zombie ceiling: stock MaxSpawnedZombies default is 64; we keep a
    /// smaller dev cap so long soaks do not accrete entities without despawn.
    pub const default_max_alive_zombies: u32 = 24;

    /// Zombie hp multiplier from GameDifficulty (0=Scavenger .. 5=Insane).
    /// The tier semantic is stock serverconfig GameDifficulty; the exact
    /// numbers are `[rules.director] difficulty_hp_0..5` (zdtd-tuned R9).
    pub fn hpScale(self: *const Director, r: *const rules_mod.Director) f32 {
        return switch (@min(self.difficulty, 5)) {
            0 => r.difficulty_hp_0,
            1 => r.difficulty_hp_1,
            2 => r.difficulty_hp_2,
            3 => r.difficulty_hp_3,
            4 => r.difficulty_hp_4,
            else => r.difficulty_hp_5,
        };
    }

    /// Damage multiplier for a GameDifficulty-matched attack pair, mirroring
    /// stock `ItemActionAttack.difficultyModifier` (RE, combat-damage.md):
    /// same-control pairs (PvP, AI-vs-AI) are unchanged; a server attacker
    /// vs a client entity scales by `[rules.difficulty] incoming_damage_0..5`,
    /// a client attacker vs a server entity by `entity_incoming_damage_0..5`
    /// (carried as config for operator policy; stock applies it client-side
    /// and the server trusts the claimed strength, so no server re-scale).
    pub fn damageScale(
        self: *const Director,
        attacker_client: bool,
        target_client: bool,
        r: *const rules_mod.Difficulty,
    ) f32 {
        if (attacker_client == target_client) return 1.0;
        if (attacker_client) return r.entityIncomingFor(self.difficulty);
        // AI attacker vs a client entity: a SandboxCode IncomingDamage
        // override wins; otherwise the per-difficulty ladder.
        if (self.sandbox_incoming > 0) return self.sandbox_incoming;
        return r.incomingFor(self.difficulty);
    }

    /// ZombieMove index 0..4 → speed multiplier (walk/jog/run/sprint/nightmare).
    /// Values from `[rules.director] move_scale_0..4` (zdtd-tuned R9).
    fn moveScale(idx: u8, r: *const rules_mod.Director) f32 {
        return switch (@min(idx, 4)) {
            0 => r.move_scale_0,
            1 => r.move_scale_1,
            2 => r.move_scale_2,
            3 => r.move_scale_3,
            else => r.move_scale_4,
        };
    }

    /// Current zombie speed multiplier for the active day/night/blood-moon state.
    pub fn zombieSpeedScale(self: *const Director, r: *const rules_mod.Director) f32 {
        if (self.bloodmoon_active) return moveScale(self.zombie_move_bm, r);
        if (self.enemy_difficulty >= 1) return moveScale(self.zombie_move_feral, r);
        return moveScale(if (self.clock.isNight()) self.zombie_move_night else self.zombie_move_day, r);
    }

    pub fn tick(self: *Director, w: *ecs_world.World, dt: f32) struct { spawned: u32, world_time: u64 } {
        const day_before = self.clock.day;
        self.clock.tick(dt);
        var spawned: u32 = 0;

        if (self.horde_cd > 0) self.horde_cd -= dt;
        if (self.bloodmoon_cd > 0) self.bloodmoon_cd -= dt;
        if (self.scouts_cd > 0) self.scouts_cd -= dt;
        if (self.animals_cd > 0) self.animals_cd -= dt;

        self.bloodmoon_active = self.clock.isBloodMoonNight();
        w.zombie_speed_scale = self.zombieSpeedScale(&w.rules.director);

        // `[systems] director = false` means "stop zombie spawning", not "stop
        // time". The world clock, blood-moon flag and daily trader restock live
        // on this path, so gating the whole system in schedule.run would freeze
        // day and night for the mode that disabled it. Wildlife keeps wandering
        // under its own `[systems] animals` flag (stock SpawnManagerBiomes is a
        // system separate from the AIDirector, spawning.md section 2).
        //
        // The alive-zombie cap is a spawn gate, not a return: heat decay,
        // blood-moon party teleports, EndBloodMoon, animals, and trader
        // restock still run. Returning here used to freeze all of those for
        // as long as the cap was full.
        const alive_z = w.countKind(.zombie);
        // Blood-moon budget: stock's party spawner calls `AIDirector::CanSpawn
        // (1.9f)` (asm.il:413528), a 1.9x ceiling over the world budget, so
        // the horde does not thin at the ordinary day/night cap.
        const cap: u32 = if (self.bloodmoon_active)
            // Clamp in f64: [rules.bloodmoon] budget_scale has no declared
            // range, so a large operator value must not trap the u32 cast
            // (f32 cannot hold u32 max exactly; f64 can).
            @trunc(@min(@as(f64, @floatFromInt(self.max_alive)) * @as(f64, w.rules.bloodmoon.budget_scale), 4294967295.0))
        else
            self.max_alive;
        const spawn_z = w.rules.systems.director and alive_z < cap;

        // Starter population (GAP "population is still thin"): stock fills
        // loaded regions toward their spawning.xml maxcounts as they load, so
        // a player never sees an empty world; the zdtd drip alone (2 per 45 s
        // at night, 1 per 120 s by day) leaves a fresh world near-empty until
        // the first night. Fill once toward `initial_population_frac x cap`,
        // batched so one tick cannot spawn the whole population. The
        // spawning.xml per-rule budget gate still applies per spawn
        // (spawnNearPlayers -> budgetFor/budgetAllows).
        if (spawn_z and !self.initial_population_done) {
            const target: u32 = @trunc(@as(f32, @floatFromInt(cap)) * w.rules.director.initial_population_frac);
            const gap: u32 = if (alive_z < target) target - alive_z else 0;
            if (gap == 0) {
                self.initial_population_done = true;
            } else {
                spawned += self.spawnNearPlayers(w, @min(gap, initial_population_batch), w.rules.director.enemy_spawn_ring_min, w.rules.director.enemy_spawn_ring_max, "");
            }
        }

        if (w.rules.systems.director) {
            // Stock suspends ordinary biome enemy spawning during a blood moon:
            // the enemy request is demoted to animals-only and the horde party
            // owns the budget (spawning.md:126-128, 1274-1278). The drip is
            // zdtd's stand-in for that biome loop, so it stops for the night
            // too; animals keep their own cadence below.
            if (spawn_z and !self.bloodmoon_active and self.clock.isNight() and self.horde_cd <= 0) {
                spawned += self.spawnNearPlayers(w, 2, w.rules.director.enemy_spawn_ring_min, w.rules.director.enemy_spawn_ring_max, "");
                self.horde_cd = w.rules.director.horde_drip_cd;
            }
            if (self.bloodmoon_active and self.bloodmoon_cd <= 0) {
                // Freeze the party gamestage at dusk (InitParty): the ladder and
                // the horde size stay fixed for the whole night. The Game pushes
                // the matching bonus-loot cadence in through pushBloodMoonBonus
                // (the stage sum lives in the asset table, not in this layer);
                // until it does, the stock XML defaults below stand in.
                if (self.bm_stage_frozen == 0) {
                    self.bm_stage_frozen = if (self.party_stage_weighted > 0)
                        self.party_stage_weighted
                    else
                        self.party_stage;
                    // Seed the bonus counter once per night, the way stock
                    // InitParty does. Keep whatever cadence the Game already
                    // pushed from the ladder; only fall back to the stock XML
                    // defaults when nothing has set one yet.
                    if (self.bm_bonus_every == 0) {
                        self.setBloodMoonBonus(12, 25);
                    } else {
                        self.bm_bonus_count = self.bm_bonus_every / 2;
                    }
                    // Start the nightly group walk at row 0 (stock SetPartyLevel
                    // resets groupIndex/spawnCount, then SetupGroup).
                    self.bm_group_index = 0;
                    self.setupBmGroup(w);
                }
                self.buildBloodMoonParties(w);
                self.recountAndTeleportHorde(w);
                if (spawn_z) {
                    const now = self.clock.worldTimeBits();
                    // Row pacing (spawner Tick): a `duration` row expires into
                    // the next row; the row's `interval` gates the wave burst.
                    // Stock ticks this per party spawner; one shared walk is
                    // the same count (one spawner per night per party, and
                    // zdtd runs one wave loop across parties).
                    if (self.stageGroupAt(self.bm_group_index) != null) {
                        if (self.bm_group_deadline != 0 and now >= self.bm_group_deadline) {
                            self.bm_group_index += 1;
                            self.setupBmGroup(w);
                        }
                    }
                    if (self.stageGroupAt(self.bm_group_index)) |row| {
                        // Row done (`spawnCount >= numToSpawn`) advances, like
                        // canSpawn going false into the next SetupGroup.
                        if (self.bm_spawned_in_group >= row.num) {
                            self.bm_group_index += 1;
                            self.setupBmGroup(w);
                        }
                    }
                    if (self.stageGroupAt(self.bm_group_index)) |walk| {
                        spawned += self.spawnBloodMoonWalk(w, walk);
                    } else {
                        // Walk exhausted (or no indexed lookup wired): the
                        // legacy first-row burst keeps the night populated.
                        const bm = self.stageGroup(bloodmoon_spawner);
                        var wave: u32 = @max(1, @as(u32, @trunc(@min(@as(f64, @floatFromInt(self.bloodmoon_enemy_count)) * @as(f64, w.rules.bloodmoon.wave_frac), 4294967295.0))));
                        var bm_group: []const u8 = "";
                        if (bm) |sg| {
                            wave = @min(wave, @max(1, @as(u32, sg.max_alive)));
                            bm_group = sg.group;
                        }
                        spawned += self.spawnBloodMoonParties(w, wave, bm_group);
                    }
                    self.bloodmoon_cd = w.rules.director.bloodmoon_wave_cd;
                }
            } else if (!self.bloodmoon_active and self.bm_stage_frozen != 0) {
                // EndBloodMoon (412618): clear horde marks and the frozen stage at
                // dawn; nothing is despawned.
                self.bm_stage_frozen = 0;
                self.bm_group_index = 0;
                self.bm_spawned_in_group = 0;
                self.bm_group_deadline = 0;
                clearHordeMarks(w);
            }
            // Horde zombies keep to their party focus every tick (teleport back
            // past cTeleportDist) so a 2+ player horde cannot split.
            if (self.bloodmoon_active) {
                self.buildBloodMoonParties(w);
                self.recountAndTeleportHorde(w);
            }
            // Wandering horde schedule (AIDirectorWanderingHordeComponent): a group
            // of 6 at ~92 m every 12-24 in-game hours, player-gated. Stay due
            // when the zombie cap is full so the wave fires as soon as there
            // is budget instead of being dropped.
            const wt = self.clock.worldTimeBits();
            if (self.wandering_next == 0) {
                if (wt > w.rules.director.wander_start_after) self.wandering_next = self.nextWanderingTime(w.rules.director.wander_min_gap, w.rules.director.wander_max_gap);
            } else if (wt >= self.wandering_next) {
                // Stock `get_OtherHordesAreActive` is `SkyManager.IsBloodMoonVisible()
                // || ChunkEventComponent.HasAnySpawns()`, and a due wave whose
                // other-horde test passes pushes `nextTime` instead of spawning
                // (aidirector.md:711-712, 723-727). A wandering pack must not
                // land on top of the horde night; it stays due and fires once
                // the night ends.
                if (spawn_z and !self.bloodmoon_active) {
                    if (anyPlayer(w)) spawned += self.spawnWanderingHorde(w);
                    self.wandering_next = self.nextWanderingTime(w.rules.director.wander_min_gap, w.rules.director.wander_max_gap);
                }
            }
            // Heat map: decay always; the 5 s scout spawn is cap-gated.
            self.tickHeat(w, dt, spawn_z);
            if (spawn_z and !self.clock.isNight() and self.scouts_cd <= 0) {
                // Wave size is the tier's own TotalPerWave, not a flat 1.
                spawned += self.spawnNearPlayers(w, self.scoutWaveSize(1), w.rules.director.enemy_spawn_ring_min, w.rules.director.enemy_spawn_ring_max, self.scoutGroup());
                self.scouts_cd = w.rules.director.scout_drip_cd;
            }
        }

        spawned += self.tickAnimals(w);
        if (self.clock.day != day_before) {
            @import("systems.zig").traderRestock(w);
        }

        self.total_spawned +%= spawned;
        return .{ .spawned = spawned, .world_time = self.clock.worldTimeBits() };
    }

    /// Daytime wildlife up to MaxSpawnedAnimals (wander, not chase). Runs under
    /// `[systems] animals` independent of `director`, mirroring stock where
    /// SpawnManagerBiomes (animals) is separate from the AIDirector (zombies).
    fn tickAnimals(self: *Director, w: *ecs_world.World) u32 {
        var n: u32 = 0;
        if (!w.rules.systems.animals) return 0;
        // Stock spawns wildlife day (WildGameForest) and night (WildGameForest
        // Night + EnemyAnimals: snake, boar, coyote, wolf, bear), all under
        // MaxSpawnedAnimals, so the day-only gate is dropped.
        if (self.max_alive_animals <= 0 or self.animals_cd > 0) return 0;
        if (w.countKind(.animal) < self.max_alive_animals) {
            n += self.spawnAnimalsNearPlayers(w, 1, w.rules.director.animal_spawn_ring_min, w.rules.director.animal_spawn_ring_max);
        }
        self.animals_cd = w.rules.director.animal_drip_cd;
        return n;
    }

    fn spawnAnimalsNearPlayers(self: *Director, w: *ecs_world.World, count: u32, min_r: f32, max_r: f32) u32 {
        var n: u32 = 0;
        for (w.kind_groups.slice(.player)) |p| {
            if (n >= count) break;
            if (!w.alive[p] or !w.mask[p].player or !w.mask[p].transform) continue;
            const ang = @as(f32, @floatFromInt(self.total_spawned +% n)) * 2.3;
            const r = min_r + (max_r - min_r) * @mod(ang, 1.0);
            const x = w.transform[p].x + @cos(ang) * r;
            const z = w.transform[p].z + @sin(ang) * r;
            // Per-rule budget gate for the animal rules (maxcount/respawndelay).
            const budget = self.budgetFor(w, x, z, .animal);
            if (budget.index != 0xffff and !self.budgetAllows(budget, w)) continue;
            const y = w.groundY(x, z) orelse w.transform[p].y;
            // Wildlife group per player biome (fallback = the single group).
            var animal_ct: ?ecs_world.EntityClass = null;
            var agroup = self.animal_group;
            if (self.biome_group_fn) |bf| agroup = bf(self.biome_group_ctx, x, z, .animal, self.animal_group);
            if (agroup.len > 0) {
                if (self.group_pick_fn) |pick| {
                    if (pick(self.group_pick_ctx, agroup, self.total_spawned)) |cname| {
                        for (w.class_table) |ct| {
                            if (ct.kind == .animal and std.mem.eql(u8, ct.name, cname)) {
                                animal_ct = ct;
                                break;
                            }
                        }
                        // Full entityclasses stats when the animal class was not
                        // preloaded into the fixed table (same A35 path as
                        // zombies: bear 2500 HP instead of the 30 floor).
                        if (animal_ct == null) {
                            if (self.class_resolve_fn) |f| animal_ct = f(self.class_resolve_ctx, cname);
                        }
                    }
                }
            }
            if (animal_ct == null) {
                for (w.class_table) |ct| {
                    if (ct.kind == .animal and ct.hash != 0) {
                        animal_ct = ct;
                        break;
                    }
                }
            }
            const hp: f32 = if (animal_ct) |ct| ct.max_hp else 30;
            // spawnAnimalDef carries the resolved per-class speeds/damage onto
            // the entity (A35), same contract as spawnZombieDef.
            const id = if (animal_ct) |ct|
                w.spawnAnimalDef(x, y, z, ct)
            else
                w.spawnAnimal(x, y, z, hp, 0, "");
            const nid = id orelse break;
            if (w.slotOfNetId(nid)) |slot| {
                w.zombie_ai[slot].state = .wander; // wildlife roams, does not hunt
                if (budget.index != 0xffff) {
                    w.zombie_ai[slot].spawn_rule = budget.index;
                    self.budgetConsume(budget, w);
                }
                n += 1;
            }
        }
        return n;
    }

    /// gamestages.xml spawner name the blood moon draws from.
    pub const bloodmoon_spawner = "BloodMoonHorde";

    /// gamestages.xml spawner name the wandering horde draws from
    /// (`AIWanderingHordeSpawner::.ctor` IL_0056/IL_0066; the Bandits spawn
    /// type uses "WanderingBandits" instead, which zdtd does not schedule).
    pub const wandering_spawner = "WanderingHorde";

    /// `AIWanderingHordeSpawner::.ctor` IL_0066 passes this as
    /// `ResetPartyLevel(mod)`: the wandering ladder wraps at 50 because the
    /// XML's 50 rows stop there (its own comment). Only this ladder wraps -
    /// the blood moon and ScoutGSList spawners pass 0.
    pub const wandering_stage_mod = 50;

    /// Radius for `GameStageDefinition::CalcGameStageAround` (IL=38):
    /// `World::GetPlayersAround(pos, 100f)`, i.e. the weighted party level of
    /// the players near the spawner.
    pub const gamestage_around_radius: f32 = 100.0;

    /// Resolve a gamestages.xml spawner at the current party stage (the
    /// blood-moon ladder reads the night-frozen stage once set).
    fn stageGroup(self: *const Director, spawner: []const u8) ?StageGroup {
        const f = self.stage_group_fn orelse return null;
        const stage = if (self.bm_stage_frozen != 0) self.bm_stage_frozen else self.party_stage;
        const sg = f(self.stage_group_ctx, spawner, stage) orelse return null;
        if (sg.group.len == 0) return null;
        return sg;
    }

    /// Resolve one row of the frozen stage by index (stock
    /// `Stage.GetSpawnGroup`, null past the end). Null group also ends the
    /// walk, matching `get_IsDone = groupIndex > 0 && spawnGroup == null`.
    pub fn stageGroupAt(self: *const Director, index: u32) ?StageGroup {
        const f = self.stage_group_at_fn orelse return null;
        const sg = f(self.stage_group_at_ctx, bloodmoon_spawner, self.bm_stage_frozen, index) orelse return null;
        if (sg.group.len == 0) return null;
        return sg;
    }

    /// Advance the nightly group walk to the next row (stock `SetupGroup`:
    /// row = stage row at `groupIndex`; `interval` paces spawns, `duration`
    /// arms the row deadline in world-time units, `num` sizes the row). A null
    /// row ends the walk for the night.
    pub fn setupBmGroup(self: *Director, w: *ecs_world.World) void {
        _ = w;
        if (self.stageGroupAt(self.bm_group_index)) |sg| {
            self.bm_spawned_in_group = 0;
            self.bm_spawn_at = 0;
            // Stock AIDirectorGameStagePartySpawner::SetupGroup IL_0044-0062:
            // nextStageTime = world.worldTime + duration * 1000. World time is
            // 1000 units per game hour (DayTimeToWorldTime), not 20 Hz ticks;
            // the old *20 armed every row deadline 50x too early.
            self.bm_group_deadline = if (sg.duration > 0)
                self.clock.worldTimeBits() + @as(u64, sg.duration) * world_time_units_per_hour
            else
                0;
        } else {
            // Past the last row: mark done. The wave loop treats this as
            // "walk exhausted" and falls back to the legacy first-row burst.
            self.bm_group_index = std.math.maxInt(u32);
        }
    }

    /// Blood-moon bonus cadence for the frozen stage
    /// (`AIDirectorGameStagePartySpawner.SetPartyLevel` IL_0065-007C):
    /// `bonusLootEvery = max(stageSpawnMax / LootBonusMaxCount, LootBonusEvery)`
    /// where `stageSpawnMax` sums every spawn-group `num` in the stage
    /// (CalcStageSpawnMax IL=30). The spawn-count walk needs the full stage,
    /// which the `stage_group_fn` projection (first row only) does not carry,
    /// so the Game pushes the resolved cadence + scale in with the nightly
    /// stage freeze; the fallback below keeps offline/builtin tables on the
    /// stock XML defaults. Seeding `bm_bonus_count` at half the cadence is
    /// stock `InitParty` (IL_0072-0080).
    pub fn setBloodMoonBonus(self: *Director, every: u32, scale: f32) void {
        self.setBloodMoonBonusParams(every, scale);
        self.bm_bonus_count = self.bm_bonus_every / 2;
    }

    /// Update the cadence and scale without touching the progress counter.
    /// The Game re-pushes the resolved gamestage values every tick of an
    /// active blood moon so a ladder loaded mid-night takes effect, and that
    /// caller must not re-seed: `bm_bonus_count` advances once per horde
    /// spawn, so a 20 Hz reset to `every / 2` held it below `every` and the
    /// bonus drop never fired for any cadence above 2.
    pub fn setBloodMoonBonusParams(self: *Director, every: u32, scale: f32) void {
        self.bm_bonus_every = @max(1, every);
        self.bm_bonus_scale = if (scale > 0) scale else 1.0;
    }

    /// Daytime scout entity group for the current party stage; empty when the
    /// spawning.xml entityspawner table is unavailable.
    fn scoutGroup(self: *const Director) []const u8 {
        return self.scoutGroupFor(self.party_stage);
    }

    /// Scout entity group for a gamestage: stock `SpawnScouts` picks the tier
    /// from `CalcGameStageAround` at the hot spot, not from a server-wide
    /// high-water mark (aidirector.md:394-397), so the heat path anchors here.
    fn scoutGroupAt(self: *const Director, wx: f32, wz: f32) []const u8 {
        return self.scoutGroupFor(self.stageAround(wx, wz));
    }

    fn scoutGroupFor(self: *const Director, stage: i32) []const u8 {
        const f = self.spawner_group_fn orelse return "";
        return f(self.spawner_group_ctx, scoutSpawnerName(stage)) orelse "";
    }

    /// The tier's `TotalPerWave` from spawning.xml, falling back to `dflt`
    /// when no table is wired (offline tests) or the property is absent.
    pub fn scoutWaveSize(self: *const Director, dflt: u32) u32 {
        return self.scoutWaveSizeFor(self.party_stage, dflt);
    }

    /// Wave size for the position-anchored heat path.
    pub fn scoutWaveSizeAt(self: *const Director, wx: f32, wz: f32, dflt: u32) u32 {
        return self.scoutWaveSizeFor(self.stageAround(wx, wz), dflt);
    }

    pub fn scoutWaveSizeFor(self: *const Director, stage: i32, dflt: u32) u32 {
        const f = self.spawner_wave_fn orelse return dflt;
        const r = f(self.spawner_wave_ctx, scoutSpawnerName(stage));
        if (r.min == 0) return dflt;
        const hi = @max(r.min, r.max);
        if (hi == r.min) return r.min;
        // Stock rolls RandomRange(min, max + 1) per wave
        // (EntitySpawner.il.txt:565-573). Seeded off the spawn counter so the
        // sequence stays deterministic for a given run.
        const span: u64 = hi - r.min + 1;
        const roll: u64 = (@as(u64, self.total_spawned) *% 2654435761) % span;
        return r.min + @as(u32, @intCast(roll));
    }

    /// `group_override` wins over the day/night spawning.xml groups; empty
    /// keeps the existing biome-rule behaviour. When a per-rule budget is
    /// wired, each spawn point resolves its spawning.xml rule and the spawn
    /// is gated on `count < maxcount` and the respawn delay (spawning.md §3);
    /// the spawned zombie carries the rule index so `releaseRule` on destroy
    /// decrements the alive count (kill attrition).
    fn spawnNearPlayers(self: *Director, w: *ecs_world.World, count: u32, min_r: f32, max_r: f32, group_override: []const u8) u32 {
        var n: u32 = 0;
        for (w.kind_groups.slice(.player)) |p| {
            if (n >= count) break;
            if (!w.alive[p] or !w.mask[p].player or !w.mask[p].transform) continue;
            var k: u32 = 0;
            while (k < count and n < count) : (k += 1) {
                // Stock AIDirector ring placement (asm.il:413135): the base
                // bearing spreads the batch, and a per-spawn jitter (seeded
                // from the spawn counter) keeps the pattern from repeating
                // identically every tick - zombies stop materialising from
                // the same bearings each wave.
                const base = @as(f32, @floatFromInt(k + n)) * 1.7;
                const jit = @as(f32, @floatFromInt(spawnJitter(self.total_spawned +% n))) / 10000.0 * 2.0 * std.math.pi;
                const ang = base + jit;
                const r = min_r + (max_r - min_r) * (@mod(ang, 1.0));
                const x = w.transform[p].x + @cos(ang) * r;
                const z = w.transform[p].z + @sin(ang) * r;
                // Per-rule budget gate (spawning.xml maxcount/respawndelay).
                const budget = self.budgetFor(w, x, z, if (self.clock.isNight()) .night else .day);
                if (budget.index != 0xffff and !self.budgetAllows(budget, w)) continue;
                // Ground snap (RE spawn placement): the player's transform Y is
                // its centre, ~1.7 m above the surface, so spawning at that Y
                // embeds zombies in hillsides or leaves them floating on
                // slopes; the world ground hook gives the surface at (x,z).
                const y = w.groundY(x, z) orelse w.transform[p].y;
                const slot = self.spawnOneZombie(w, x, y, z, group_override, self.total_spawned +% n, false) orelse break;
                w.zombie_ai[slot].state = .chase;
                w.zombie_ai[slot].target_id = w.network_id[p].id;
                w.zombie_ai[slot].alert = true;
                if (budget.index != 0xffff) {
                    w.zombie_ai[slot].spawn_rule = budget.index;
                    self.budgetConsume(budget, w);
                }
                n += 1;
            }
        }
        return n;
    }

    /// Resolve the spawning.xml rule budget at a world position (fallback:
    /// unbudgeted when no resolver is wired or the biome/rule is unknown).
    fn budgetFor(self: *const Director, w: *const ecs_world.World, x: f32, z: f32, kind: SpawnKind) RuleBudget {
        _ = w;
        if (self.rule_budget_fn) |f| return f(self.rule_budget_ctx, x, z, kind);
        return .{};
    }

    /// True when the rule's alive count is under maxcount, after rolling the
    /// budget when the respawn delay has elapsed (stock ResetRespawn sets
    /// maxCount when the delay elapses; CanSpawn = count < maxCount,
    /// spawning.md §3). The reset happens on the check, so a fresh batch in
    /// the same world-time window is not gated by the delay it just armed.
    pub fn budgetAllows(self: *Director, budget: RuleBudget, w: *const ecs_world.World) bool {
        const i: usize = budget.index;
        if (i >= rule_budget_cap) return true;
        if (budget.maxcount == 0) return true; // 0 = unbounded (stock maxcount 0)
        const st = &self.rule_budgets[i];
        const wt = w.director.clock.worldTimeBits();
        if (wt >= st.next_respawn_wt) {
            st.count = 0;
            st.next_respawn_wt = std.math.maxInt(u64); // re-arm on consume
        }
        return st.count < budget.maxcount;
    }

    /// Charge one spawn against the rule budget: increment the alive count
    /// and arm the next cycle's respawn delay on the first spawn of a cycle
    /// (stock ResetRespawn arms the delay when the budget resets).
    pub fn budgetConsume(self: *Director, budget: RuleBudget, w: *const ecs_world.World) void {
        const i: usize = budget.index;
        if (i >= rule_budget_cap or budget.maxcount == 0) return;
        const st = &self.rule_budgets[i];
        st.count +|= 1;
        if (st.count == 1 and st.next_respawn_wt == std.math.maxInt(u64)) {
            // Stock scales days to world ticks (BiomeSpawningFromXml IL_0191:
            // ParseFloat * 24000) and arms delayWorldTime = now + delay *
            // RandomRange(0.9, 1.1) (ResetRespawn IL_0146-0159). The delay is
            // fractional days (dz02 day respawns in 0.3 d), so no whole-day
            // floor: a floor would stretch a 7-hour respawn to a full day.
            // Deterministic midpoint (1.0x) instead of the 0.9-1.1 roll: the
            // budget has no per-rule RNG stream.
            const ticks: u64 = @trunc(@max(0, budget.respawn_days) * @as(f32, ticks_per_day));
            st.next_respawn_wt = w.director.clock.worldTimeBits() + ticks;
        }
    }

    /// Decrement a rule's alive count when one of its spawns dies/despawns
    /// (World.destroy calls this; stock kill attrition on the area budget).
    pub fn releaseRule(self: *Director, rule: u16) void {
        if (rule >= rule_budget_cap) return;
        const st = &self.rule_budgets[rule];
        if (st.count > 0) st.count -= 1;
    }

    /// Stock's blood-moon vulture swap roll (`SpawnZombie` IL_0049: the
    /// controller's `RandomFloat() < 0.5`). Deterministic here, drawn from the
    /// same per-spawn mix as the placement jitter, so a replay of the same
    /// spawn counter makes the same choice.
    pub fn bloodMoonVultureSwap(seed: u32) bool {
        return spawnJitter(seed) < 5000;
    }

    /// Deterministic per-spawn jitter seed (0..9999) from the spawn counter,
    /// so consecutive waves place zombies on varied bearings without a global
    /// RNG (RE spawn placement, asm.il:413135).
    fn spawnJitter(seed: u32) u32 {
        const x = (seed +% 0x9E3779B9) *% 0x85EBCA6B;
        return (x ^ (x >> 16)) % 10000;
    }

    /// Cluster online players into blood-moon parties: anyone within
    /// cPartyJoinDistance (80 m) of an existing party focus joins it (focus =
    /// running average); stragglers open new parties (cap rules.bloodmoon
    /// max_parties, clamped to the storage array bm_parties_cap).
    pub fn buildBloodMoonParties(self: *Director, w: *ecs_world.World) void {
        const rules = w.rules.bloodmoon;
        const max_parties: usize = @min(rules.max_parties, bm_parties_cap);
        const join2 = rules.party_join_dist * rules.party_join_dist;
        self.bm_parties = [_]BmParty{.{}} ** bm_parties_cap;
        self.bm_party_n = 0;
        for (w.kind_groups.slice(.player)) |p| {
            if (!w.alive[p] or !w.mask[p].player or !w.mask[p].transform) continue;
            const x = w.transform[p].x;
            const z = w.transform[p].z;
            var joined = false;
            for (self.bm_parties[0..self.bm_party_n]) |*party| {
                const dx = party.focus_x - x;
                const dz = party.focus_z - z;
                if (dx * dx + dz * dz > join2) continue;
                const m: f32 = @floatFromInt(party.members);
                party.focus_x = (party.focus_x * m + x) / (m + 1.0);
                party.focus_z = (party.focus_z * m + z) / (m + 1.0);
                party.members += 1;
                joined = true;
                break;
            }
            if (joined or self.bm_party_n >= max_parties) continue;
            const np = &self.bm_parties[self.bm_party_n];
            np.* = .{ .focus_x = x, .focus_z = z, .members = 1 };
            self.bm_party_n += 1;
        }
    }

    /// One pass over horde zombies per blood-moon tick: recount each party's
    /// alive set (stock OnEntityUnloaded accounting) and teleport a drifter
    /// back to its party focus once it passes cTeleportDist (150 m).
    fn recountAndTeleportHorde(self: *Director, w: *ecs_world.World) void {
        const rules = w.rules.bloodmoon;
        for (self.bm_parties[0..self.bm_party_n]) |*party| party.alive = 0;
        if (self.bm_party_n == 0) {
            // All parties wiped: stock KillPartyZombies (party Tick, aidirector.md)
            // kills the horde when its party empties, so a dead party does not
            // leave horde zombies roaming until dawn. Snapshot: destroy()
            // shifts the live kind group.
            var buf: [ecs_world.max_entities]ecs_world.Slot = undefined;
            const src = w.kind_groups.slice(.zombie);
            const n = src.len;
            @memcpy(buf[0..n], src);
            for (buf[0..n]) |s| {
                if (w.alive[s] and w.zombie_ai[s].is_horde) w.destroy(s);
            }
            return;
        }
        const tel2 = rules.party_teleport_dist * rules.party_teleport_dist;
        for (w.kind_groups.slice(.zombie)) |s| {
            if (!w.alive[s] or !w.zombie_ai[s].is_horde) continue;
            const x = w.transform[s].x;
            const z = w.transform[s].z;
            var best_d2: f32 = std.math.floatMax(f32);
            var best_i: usize = 0;
            for (self.bm_parties[0..self.bm_party_n], 0..) |*party, i| {
                const dx = party.focus_x - x;
                const dz = party.focus_z - z;
                const d2 = dx * dx + dz * dz;
                if (d2 < best_d2) {
                    best_d2 = d2;
                    best_i = i;
                }
            }
            self.bm_parties[best_i].alive += 1;
            if (best_d2 <= tel2) continue;
            const focus = &self.bm_parties[best_i];
            const ang = @as(f32, @floatFromInt(s)) * 2.399963; // ~120 degree steps
            const nx = focus.focus_x + @cos(ang) * rules.party_spawn_dist;
            const nz = focus.focus_z + @sin(ang) * rules.party_spawn_dist;
            w.setPos(w.network_id[s].id, nx, w.transform[s].y, nz, 0);
        }
    }

    /// EndBloodMoon: clear IsHordeZombie on every living zombie (412618).
    fn clearHordeMarks(w: *ecs_world.World) void {
        for (w.kind_groups.slice(.zombie)) |s| {
            if (w.alive[s]) w.zombie_ai[s].is_horde = false;
        }
    }

    /// Spawn one wave per party around its focus (cSpawnDistance 40 + up to
    /// 10 jitter), marked horde, capped per party at
    /// min(cPartyEnemyMax 30, BloodMoonEnemyCount x members). One shared wave
    /// per party instead of one per player: 2 players in range get one horde.
    fn spawnBloodMoonParties(self: *Director, w: *ecs_world.World, wave: u32, group: []const u8) u32 {
        const rules = w.rules.bloodmoon;
        var n: u32 = 0;
        for (self.bm_parties[0..self.bm_party_n]) |*party| {
            const cap = @min(rules.party_enemy_max, @as(u32, self.bloodmoon_enemy_count) * party.members);
            var k: u32 = 0;
            while (k < wave and party.alive < cap and n < wave * self.bm_party_n) : (k += 1) {
                const ang = @as(f32, @floatFromInt(self.total_spawned +% n)) * 2.399963;
                const r = rules.party_spawn_dist + @mod(ang, 1.0) * 10.0;
                const x = party.focus_x + @cos(ang) * r;
                const z = party.focus_z + @sin(ang) * r;
                const y = w.groundY(x, z) orelse (nearestPlayerY(w, x, z) orelse continue);
                // Stock's forced radiated vulture: when the targeted player is
                // attached to an entity (a vehicle), a 50% roll replaces the
                // group pick with `animalZombieVultureRadiated`, and that spawn
                // does not feed the bonus-loot counter (SpawnZombie
                // IL_0031-0061). The roll is a deterministic mix of the spawn
                // counter, like the placement jitter.
                const seed = self.total_spawned +% n;
                var class_override: ?[]const u8 = null;
                var loot_kind: LootKind = .bloodmoon;
                if (nearestPlayerSlot(w, x, z)) |ps| {
                    if (w.ridesVehicle(w.network_id[ps].id) and bloodMoonVultureSwap(seed)) {
                        class_override = "animalZombieVultureRadiated";
                        loot_kind = .none;
                    }
                }
                const slot = self.spawnOneZombieClass(w, x, y, z, group, seed, true, loot_kind, class_override) orelse continue;
                if (nearestPlayerSlot(w, x, z)) |ps| {
                    w.zombie_ai[slot].state = .chase;
                    w.zombie_ai[slot].target_id = w.network_id[ps].id;
                    w.zombie_ai[slot].alert = true;
                }
                party.alive += 1;
                n += 1;
            }
        }
        self.bm_spawned_in_group +|= n;
        return n;
    }

    /// Spawn one walk-row wave per party (stock spawner Tick pacing): the
    /// current row's `interval` gates bursts (`bm_spawn_at` accumulates the
    /// wave cooldown), `num` caps the row (`bm_spawned_in_group`), and the
    /// row's `maxAlive` caps the burst like the legacy path. Counts into the
    /// row total so the driver advances when the row is done.
    fn spawnBloodMoonWalk(self: *Director, w: *ecs_world.World, row: StageGroup) u32 {
        self.bm_spawn_at -= w.rules.director.bloodmoon_wave_cd;
        const interval_s: f32 = @floatFromInt(@max(1, row.interval));
        if (self.bm_spawn_at > 0 and interval_s > 0) {
            // Not due yet: hold the burst until the row interval elapses.
            self.bm_spawn_at += w.rules.director.bloodmoon_wave_cd;
            return 0;
        }
        self.bm_spawn_at = interval_s;
        const remaining: u32 = row.num -| self.bm_spawned_in_group;
        if (remaining == 0) return 0;
        var wave: u32 = @max(1, @as(u32, @trunc(@min(@as(f64, @floatFromInt(self.bloodmoon_enemy_count)) * @as(f64, w.rules.bloodmoon.wave_frac), 4294967295.0))));
        wave = @min(wave, @max(1, @as(u32, row.max_alive)));
        wave = @min(wave, remaining);
        return self.spawnBloodMoonParties(w, wave, row.group);
    }

    /// Pick the group class at (x,z) and spawn one zombie; mark horde when
    /// requested. Shared by the per-player ring and the party spawner.
    /// `loot_kind` selects the bonus-loot counter the spawn feeds: blood-moon
    /// waves count toward `bonusLootEvery` x `LootBonusScale`, wandering packs
    /// toward `LootWanderingBonusEvery` x `LootWanderingBonusScale`, and
    /// everything else (drips, scouts, ambient) carries no bonus. Stock keeps
    /// one counter per spawner object; zdtd keeps one per kind on the
    /// director, which is the same count (one spawner of each kind per night).
    const LootKind = enum { none, bloodmoon, wandering };
    pub fn spawnOneZombie(self: *Director, w: *ecs_world.World, x: f32, y: f32, z: f32, group_override: []const u8, seed: u32, mark_horde: bool) ?ecs_world.Slot {
        return self.spawnOneZombieLoot(w, x, y, z, group_override, seed, mark_horde, .none);
    }
    pub fn spawnOneZombieLoot(self: *Director, w: *ecs_world.World, x: f32, y: f32, z: f32, group_override: []const u8, seed: u32, mark_horde: bool, loot_kind: LootKind) ?ecs_world.Slot {
        return self.spawnOneZombieClass(w, x, y, z, group_override, seed, mark_horde, loot_kind, null);
    }

    /// Same spawn with a forced class: stock's blood-moon spawner replaces the
    /// group pick with `animalZombieVultureRadiated` when its targeted player
    /// rides an entity, and that spawn skips the bonus-loot counter
    /// (AIDirectorBloodMoonParty::SpawnZombie IL_0031-0061). `class_override`
    /// is that class name; it resolves through the same class table/XML path
    /// the group picker uses.
    /// `EntityFactory::GetEntityClassWithinMaxTier` (IL=30): a class at or
    /// below `max_enemy_tier` passes through; otherwise walk its
    /// `PreviousTier` names (comma list, one class or a random pick) until one
    /// fits. Null means the ladder could not satisfy the cap, and the caller
    /// must skip the spawn.
    fn clampEntityTier(self: *const Director, w: *const ecs_world.World, ct: ecs_world.EntityClass) ?ecs_world.EntityClass {
        if (ct.entity_tier <= self.max_enemy_tier) return ct;
        if (ct.previous_tier.len == 0) return null;
        // One or more names; stock picks the first entry when there is one and
        // a random entry otherwise. The pick is seeded off the spawn counter so
        // a given run stays reproducible.
        var count: u32 = 0;
        var it = std.mem.splitScalar(u8, ct.previous_tier, ',');
        while (it.next()) |raw| {
            if (std.mem.trim(u8, raw, " \t").len > 0) count += 1;
        }
        if (count == 0) return null;
        const pick_i: u32 = if (count == 1) 0 else @intCast((@as(u64, self.total_spawned) *% 2654435761) % count);
        var seen: u32 = 0;
        var it2 = std.mem.splitScalar(u8, ct.previous_tier, ',');
        while (it2.next()) |raw| {
            const name = std.mem.trim(u8, raw, " \t");
            if (name.len == 0) continue;
            if (seen != pick_i) {
                seen += 1;
                continue;
            }
            for (w.class_table) |row| {
                if (std.mem.eql(u8, row.name, name)) return self.clampEntityTier(w, row);
            }
            if (self.class_resolve_fn) |f| {
                if (f(self.class_resolve_ctx, name)) |row| return self.clampEntityTier(w, row);
            }
            return null;
        }
        return null;
    }

    pub fn spawnOneZombieClass(self: *Director, w: *ecs_world.World, x: f32, y: f32, z: f32, group_override: []const u8, seed: u32, mark_horde: bool, loot_kind: LootKind, class_override: ?[]const u8) ?ecs_world.Slot {
        // Stock `Chunk::CanMobsSpawnAtPos` ground gate: the cell under the
        // spawn must carry CanMobsSpawnOn and be movement-solid, so a
        // player-built floor (which declares neither) does not host spawns.
        // The caller's y is the stand cell (groundY = surface + 1), so the
        // ground block sits one below it.
        if (self.mob_spawn_ok_fn) |ok| {
            const gx: i32 = @floor(x);
            const gy: i32 = @as(i32, @floor(y)) - 1;
            const gz: i32 = @floor(z);
            if (!ok(self.mob_spawn_ok_ctx, gx, gy, gz)) return null;
        }
        var ct = w.class_table[1];
        const fallback = if (self.clock.isNight()) self.night_group else self.day_group;
        const grp = if (group_override.len > 0)
            group_override
        else if (self.biome_group_fn) |bf|
            bf(self.biome_group_ctx, x, z, if (self.clock.isNight()) .night else .day, fallback)
        else
            fallback;
        var resolved: ?ecs_world.EntityClass = null;
        if (class_override) |cname| {
            for (w.class_table) |slot_ct| {
                if (std.mem.eql(u8, slot_ct.name, cname)) {
                    ct = slot_ct;
                    resolved = ct;
                    break;
                }
            }
            if (resolved == null) {
                if (self.class_resolve_fn) |f| resolved = f(self.class_resolve_ctx, cname);
            }
        } else if (grp.len > 0) {
            if (self.group_pick_fn) |pick| {
                if (pick(self.group_pick_ctx, grp, seed)) |cname| {
                    for (w.class_table) |slot_ct| {
                        if (slot_ct.kind == .zombie and std.mem.eql(u8, slot_ct.name, cname)) {
                            ct = slot_ct;
                            resolved = ct;
                            break;
                        }
                    }
                    // Class not in the fixed table: resolve the full stats from
                    // entityclasses.xml so its HP/speeds/damage reach the sim.
                    if (resolved == null) {
                        if (self.class_resolve_fn) |f| resolved = f(self.class_resolve_ctx, cname);
                    }
                }
            }
        } else {
            const zombie_slots = [_]usize{ 1, 8, 9, 10, 11 };
            const csel = zombie_slots[seed % zombie_slots.len];
            if (w.class_table[csel].hash != 0 and w.class_table[csel].kind == .zombie) {
                ct = w.class_table[csel];
            }
        }
        // `EntityFactory.MaxEntityTier` (sandbox 43): a class above the cap is
        // replaced by its `PreviousTier` ladder, and a class whose ladder
        // cannot satisfy the cap is not spawned at all (stock returns null and
        // logs). Applied to both the group pick and the forced blood-moon
        // override, which is what `LoadAssets` does on every create.
        if (resolved) |row| {
            resolved = self.clampEntityTier(w, row) orelse return null;
            ct = resolved.?;
        } else if (ct.hash != 0) {
            ct = self.clampEntityTier(w, ct) orelse return null;
        }
        // Stock has no flat blood-moon HP multiplier: blood-moon difficulty
        // comes from the gamestage ladder picking feral/radiated classes with
        // their own stats (GAP "Blood-moon zombie strength"). The rules floor
        // stays only for the unresolved class_table fallback (offline/builtin
        // data, where no ladder class exists to carry the difficulty).
        const bm_mul: f32 = if (self.bloodmoon_active and resolved == null) w.rules.director.bloodmoon_hp_mult else 1.0;
        const hp: f32 = (if (resolved) |d| d.max_hp else ct.max_hp) * bm_mul * self.hpScale(&w.rules.director);
        const id = if (resolved) |d|
            w.spawnZombieDef(x, y, z, hp, d)
        else if (ct.hash != 0)
            // Class_table rotation pick: carry the row so its speeds/damage
            // reach the AI even when class_id[s].id stays the kind default.
            w.spawnZombieDef(x, y, z, hp, ct)
        else
            w.spawnZombie(x, y, z, hp);
        const nid = id orelse return null;
        const slot = w.slotOfNetId(nid) orelse return null;
        if (mark_horde) w.zombie_ai[slot].is_horde = true;
        // Bonus loot (SpawnZombie IL_00CD-0102, AIWanderingHordeSpawner
        // IL_00F8-011C): count the spawn, and every Nth one carries the
        // scaled drop probability on its class row. Stock skips the count for
        // the forced radiated vulture (the 50% AttachedToEntity roll returns
        // before the counter); zdtd has no vulture force path, so every spawn
        // through these two kinds counts.
        switch (loot_kind) {
            .none => {},
            .bloodmoon => {
                const every = if (self.bm_bonus_every > 0) self.bm_bonus_every else 12;
                const scale = if (self.bm_bonus_scale > 0) self.bm_bonus_scale else 25;
                self.bm_bonus_count += 1;
                if (self.bm_bonus_count >= every) {
                    self.bm_bonus_count = 0;
                    w.class_id[slot].drop_prob *= scale;
                    w.class_id[slot].bonus_loot = true;
                }
            },
            .wandering => {
                const every = if (self.wander_bonus_every > 0) self.wander_bonus_every else 3;
                const scale = if (self.wander_bonus_scale > 0) self.wander_bonus_scale else 15;
                self.wander_bonus_count += 1;
                if (self.wander_bonus_count >= every) {
                    self.wander_bonus_count = 0;
                    w.class_id[slot].drop_prob *= scale;
                    w.class_id[slot].bonus_loot = true;
                }
            },
        }
        return slot;
    }

    /// Y of the nearest online player to (x,z), or null with no players.
    fn nearestPlayerY(w: *ecs_world.World, x: f32, z: f32) ?f32 {
        const s = nearestPlayerSlot(w, x, z) orelse return null;
        return w.transform[s].y;
    }

    /// True when at least one online player exists (wandering horde gate).
    fn anyPlayer(w: *ecs_world.World) bool {
        return w.countKind(.player) > 0;
    }

    /// ChooseNextTime: now + RandomRange(12000, 24000). The roll is a
    /// deterministic mix of the day and the spawn counter (seeded sim, stable
    /// replays), standing in for the director GameRandom.
    fn nextWanderingTime(self: *const Director, min_gap: u64, max_gap: u64) u64 {
        const wt = self.clock.worldTimeBits();
        const span = max_gap - min_gap + 1;
        const day = wt / 24_000;
        const off = ((day *% 2654435761) +% (self.total_spawned *% 97)) % span;
        return wt + min_gap + off;
    }

    /// Spawn one wandering-horde pack at ~92 m around the first online player,
    /// marked IsHordeZombie and set to chase the party. Stock walks the pack as
    /// a startPos->endPos path (AstarManager location line) with pit-stop
    /// commands; the direct-chase simplification keeps the client visible
    /// behaviour (a scheduled pack arriving from outside) without the
    /// path-command AI, which stays a residual (GAP wandering hordes row).
    ///
    /// The pack's size and entity group come from the `WanderingHorde` ladder
    /// in gamestages.xml, not from a rule: `AIWanderingHordeSpawner::.ctor`
    /// IL_0066 builds its `AIDirectorGameStagePartySpawner` with `mod = 50`
    /// (the ladder's own "These will wrap around at 50" comment) and
    /// `UpdateSpawn` IL_006D spawns the resolved stage row's `group` `num`
    /// times. Without a ladder (offline or builtin tables, or a wrapped stage
    /// below the first row) it falls back to the rules-sized biome-group pack.
    fn spawnWanderingHorde(self: *Director, w: *ecs_world.World) u32 {
        for (w.kind_groups.slice(.player)) |p| {
            if (!w.alive[p] or !w.mask[p].player or !w.mask[p].transform) continue;
            const row = self.wanderingHordeRow(w.transform[p].x, w.transform[p].z);
            const count: u32 = if (row) |r| @max(1, @as(u32, r.num)) else w.rules.director.wandering_horde_size;
            const group: []const u8 = if (row) |r| r.group else "";
            var n: u32 = 0;
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const ang = @as(f32, @floatFromInt(self.total_spawned +% n)) * 1.7 + @as(f32, @floatFromInt(i)) * 1.0472;
                const x = w.transform[p].x + @cos(ang) * w.rules.director.wandering_spawn_dist;
                const z = w.transform[p].z + @sin(ang) * w.rules.director.wandering_spawn_dist;
                const y = w.groundY(x, z) orelse w.transform[p].y;
                const slot = self.spawnOneZombieLoot(w, x, y, z, group, self.total_spawned +% n, true, .wandering) orelse continue;
                w.zombie_ai[slot].state = .chase;
                w.zombie_ai[slot].target_id = w.network_id[p].id;
                w.zombie_ai[slot].alert = true;
                n += 1;
            }
            return n;
        }
        return 0;
    }

    /// The `WanderingHorde` stage row for a pack around (wx,wz).
    /// `AIDirectorGameStagePartySpawner::ResetPartyLevel` IL_0000-0015 keeps
    /// the weighted party level inside the ladder (`if (mod != 0) level %=
    /// mod`, `mod = 50` for this spawner), and the level itself is
    /// `CalcPartyLevel` over the spawner's member players. A stage the ladder
    /// has no row at or below (0, or a wrap to 0) yields null.
    pub fn wanderingHordeRow(self: *const Director, wx: f32, wz: f32) ?StageGroup {
        const f = self.stage_group_fn orelse return null;
        const stage = @mod(self.stageAround(wx, wz), wandering_stage_mod);
        if (stage <= 0) return null;
        const sg = f(self.stage_group_ctx, wandering_spawner, stage) orelse return null;
        if (sg.group.len == 0) return null;
        return sg;
    }

    /// `GameStageDefinition::CalcGameStageAround` over the wired radius when
    /// the Game supplies one, else the tick's party stage.
    fn stageAround(self: *const Director, wx: f32, wz: f32) i32 {
        if (self.stage_around_fn) |f| return f(self.stage_around_ctx, wx, wz, gamestage_around_radius);
        return self.party_stage;
    }

    /// 5x5-chunk region key for a world position (AIDirectorChunkData map).
    pub fn heatRegionKey(wx: f32, wz: f32) i64 {
        const rx: i64 = @divFloor(@as(i64, @floor(wx)), heat_region_world);
        const rz: i64 = @divFloor(@as(i64, @floor(wz)), heat_region_world);
        return (rx << 32) | (rz & 0xFFFFFFFF);
    }

    fn heatRegionCenter(key: i64) struct { x: f32, z: f32 } {
        const rx: i64 = key >> 32;
        const rz: i64 = @as(i32, @bitCast(@as(u32, @truncate(@as(u64, @bitCast(key))))));
        return .{
            .x = @floatFromInt(rx * heat_region_world + heat_region_world / 2),
            .z = @floatFromInt(rz * heat_region_world + heat_region_world / 2),
        };
    }

    /// AIDirector::NotifyActivity (asm.il 414504-415200): a heat event adds
    /// `value` to the region for `duration` ticks (linear decay). Gated off
    /// during blood moons; fail-closed at the region cap.
    pub fn notifyActivity(self: *Director, wx: f32, wz: f32, value: f32, duration_ticks: f32) void {
        if (value <= 0 or self.bloodmoon_active) return;
        const key = heatRegionKey(wx, wz);
        const per_sec = value / (duration_ticks / 20.0);
        for (self.heat[0..self.heat_n]) |*r| {
            if (r.key == key) {
                r.activity += value;
                r.decay += per_sec;
                return;
            }
        }
        if (self.heat_n >= max_heat_regions) return;
        const r = &self.heat[self.heat_n];
        r.* = .{ .key = key, .activity = value, .decay = per_sec };
        self.heat_n += 1;
    }

    /// AIDirectorChunkEventComponent::Tick: decay region activity (events
    /// expire), then every 5 s run CheckToSpawn: a region at/above 25 resets,
    /// and the `heat_spawn_chance` roll decides whether it spawns a scout party
    /// toward its center and takes the long cooldown table, or only cools.
    fn tickHeat(self: *Director, w: *ecs_world.World, dt: f32, spawn_z: bool) void {
        var i: usize = 0;
        while (i < self.heat_n) {
            const r = &self.heat[i];
            if (r.cooldown > 0) r.cooldown -= dt;
            r.activity -= r.decay * dt;
            r.activity = @max(r.activity, 0);
            // A spent region stays while on cooldown (it must keep blocking new
            // heat in the same area); once cooled and empty it is dropped.
            if (r.activity <= 0.01 and r.cooldown <= 0) {
                self.heat[i] = self.heat[self.heat_n - 1];
                self.heat_n -= 1;
                continue;
            }
            i += 1;
        }
        self.heat_check_cd -= dt;
        if (self.heat_check_cd > 0) return;
        self.heat_check_cd = w.rules.director.heat_check_seconds;
        // Hold the heat event when the zombie cap is full so CheckToSpawn
        // retries once there is budget, instead of burning activity for a
        // scout that cannot spawn.
        if (self.bloodmoon_active or !spawn_z) return;
        var ci: usize = 0;
        while (ci < self.heat_n) : (ci += 1) {
            const r = &self.heat[ci];
            if (r.activity < w.rules.director.heat_spawn_threshold or r.cooldown > 0) continue;
            // CheckToSpawn (IL=46): FindBestEventAndReset picks the max-Value
            // event and stamps the short cooldown (240 s), then the
            // cSpawnChance roll (20%) decides whether this crossing spawns
            // scouts. On a spawn, SetLongDelay hard-sets 1320 s and
            // StartCooldownOnNeighbors(true) gives the eight neighbours 720 s;
            // otherwise the region keeps the 240 and the neighbours get 180.
            // The feral/radiated scout *type* is not a roll here: it comes from
            // the gamestage bracket (scoutGroup -> Scouts1/2/Feral/Radiated).
            const spawns = self.heatSpawnRolls(w.rules.director.heat_spawn_chance);
            r.activity = 0;
            r.cooldown = w.rules.director.heat_cooldown_seconds;
            if (spawns) {
                r.cooldown = w.rules.director.heat_long_cooldown_seconds;
                self.cooldownNeighbors(r.key, w.rules.director.heat_neighbor_long_cooldown_seconds);
                self.spawnHeatScouts(w, r.key);
            } else {
                self.cooldownNeighbors(r.key, w.rules.director.heat_neighbor_cooldown_seconds);
            }
        }
    }

    /// One `CheckToSpawn` spawn roll against `chance` (stock `cSpawnChance`,
    /// a GameRandom roll). zdtd derives it from a counter that advances once per
    /// threshold crossing, so a replay with the same inputs makes the same
    /// choices without a shared global RNG (sim rule 22).
    fn heatSpawnRolls(self: *Director, chance: f32) bool {
        const ordinal = self.heat_checks;
        self.heat_checks +%= 1;
        if (!std.math.isFinite(chance) or chance <= 0) return false;
        if (chance >= 1) return true;
        const h = (ordinal +% 0x9E3779B9) *% 0x85EBCA6B;
        const roll = (h ^ (h >> 16)) % 1000;
        return roll < @as(u32, @trunc(chance * 1000.0));
    }

    /// StartCooldownOnNeighbors: the eight surrounding regions get the shorter
    /// neighbor cooldown (or keep a longer existing one).
    fn cooldownNeighbors(self: *Director, key: i64, neighbor_cd: f32) void {
        const rx: i64 = key >> 32;
        const rz: i64 = @as(i32, @bitCast(@as(u32, @truncate(@as(u64, @bitCast(key))))));
        for (self.heat[0..self.heat_n]) |*r| {
            const nrx: i64 = r.key >> 32;
            const nrz: i64 = @as(i32, @bitCast(@as(u32, @truncate(@as(u64, @bitCast(r.key))))));
            const dx = nrx - rx;
            const dz = nrz - rz;
            if (dx == 0 and dz == 0) continue;
            if (@abs(dx) > 1 or @abs(dz) > 1) continue;
            r.cooldown = @max(r.cooldown, neighbor_cd);
        }
    }

    /// SpawnScouts: a small party toward the hot region center (chunk-heat
    /// spawner 0/8/10 constants), marked horde and set to investigate the
    /// nearest player (SetInvestigatePosition, 2400 ticks).
    fn spawnHeatScouts(self: *Director, w: *ecs_world.World, key: i64) void {
        const center = heatRegionCenter(key);
        // Anchor the tier at the hot spot: stock `SpawnScouts` finds the
        // closest player within 120 m of it and takes `CalcGameStageAround`
        // (aidirector.md:394-397), so a solo level-1 player does not draw
        // `ScoutsRadiated` because someone else on the map is level 125.
        const group = self.scoutGroupAt(center.x, center.z);
        var n: u32 = 0;
        var i: u32 = 0;
        // Stock sizes the heat wave from the tier's TotalPerWave; the rule is
        // the fallback when no spawning.xml table is wired.
        const wave = self.scoutWaveSizeAt(center.x, center.z, w.rules.director.heat_scout_count);
        while (i < wave) : (i += 1) {
            const ang = @as(f32, @floatFromInt(self.total_spawned +% n)) * 2.399963;
            const x = center.x + @cos(ang) * w.rules.director.heat_scout_dist;
            const z = center.z + @sin(ang) * w.rules.director.heat_scout_dist;
            const y = nearestPlayerY(w, x, z) orelse break;
            const slot = self.spawnOneZombie(w, x, y, z, group, self.total_spawned +% n, true) orelse continue;
            if (nearestPlayerSlot(w, x, z)) |ps| {
                w.zombie_ai[slot].state = .chase;
                w.zombie_ai[slot].target_id = w.network_id[ps].id;
                w.zombie_ai[slot].alert = true;
            }
            n += 1;
        }
    }

    fn nearestPlayerSlot(w: *ecs_world.World, x: f32, z: f32) ?ecs_world.Slot {
        var best: ?ecs_world.Slot = null;
        var best_d2: f32 = std.math.floatMax(f32);
        for (w.kind_groups.slice(.player)) |p| {
            if (!w.alive[p] or !w.mask[p].player or !w.mask[p].transform) continue;
            const dx = w.transform[p].x - x;
            const dz = w.transform[p].z - z;
            const d2 = dx * dx + dz * dz;
            if (d2 < best_d2) {
                best_d2 = d2;
                best = p;
            }
        }
        return best;
    }
};
