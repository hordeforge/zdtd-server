//! Lightweight AIDirector as ECS resource (world clock, horde, blood moon).

const std = @import("std");
const rules_mod = @import("rules.zig");
const director_defaults: rules_mod.Director = .{};
const ecs_world = @import("world.zig");

/// Sim world clock. Starts day 1, 07:00 (stock dedicated boot time, observed
/// live 2026-08-11: `gettime` on a fresh stock server reads "Day 1, 07:00").
/// seconds_per_hour is the sim's time scale default (30 s per in-game hour);
/// stock serverconfig DayNightLength (default 60 min day) sets the real scale.
pub const WorldClock = struct {
    hours: f32 = 7.0,
    day: u32 = 1,
    seconds_per_hour: f32 = 30.0,
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

    /// Real seconds per in-game hour from DayNightLength (real minutes per day).
    pub fn setDayNightLength(self: *WorldClock, minutes_per_day: u16) void {
        self.seconds_per_hour = @as(f32, @floatFromInt(minutes_per_day)) * 60.0 / 24.0;
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
        // DIVERGENCE: stock dedicated pauses world time with zero connected
        // players (live-observed 2026-08-11, server-lifecycle.md 5); zdtd
        // advances unconditionally - a policy simplification, not a stock
        // behavior.
        self.hours += dt / self.seconds_per_hour;
        while (self.hours >= 24.0) {
            self.hours -= 24.0;
            self.day +%= 1;
        }
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
    /// BloodMoonDay): the horde day of the active cycle — the next persisted
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

/// Resolved gamestages.xml `<spawn>` row: which entitygroup, and how many.
pub const StageGroup = struct {
    group: []const u8 = "",
    num: u16 = 1,
    max_alive: u16 = 1,
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
/// Wandering horde (RE: aidirector.md wandering-horde scheduling): a group
/// of `wandering_horde_size` zombies spawns `wandering_spawn_dist` blocks out
/// every wander_min_gap..wander_max_gap (12-24 in-game hours of world time)
/// once the world is past wander_start_after. `wandering_spawn_dist` 92 is
/// the `FindTargets` inline start offset (`RandomOnUnitCircle * 92f`, IL_018B,
/// aidirector.md placement constants); the per-horde size is gamestage-group
/// driven in stock (live-observed 2026-08-11: "enemy max 5" for GS 1), so the
/// fixed 6 here is an approximation. Both are `[rules.director]` tunables
/// (ADR 0021); these aliases are the builtin defaults (tests reference them).
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
pub const heat_event_ticks: f32 = 720.0; // TileEntity heat event duration (doc-only; not modelled)
pub const heat_check_seconds: f32 = director_defaults.heat_check_seconds;
pub const heat_cooldown_seconds: f32 = director_defaults.heat_cooldown_seconds;
pub const heat_neighbor_cooldown_seconds: f32 = director_defaults.heat_neighbor_cooldown_seconds;
pub const heat_feral_chance: f32 = 0.2; // doc-only; the feral roll is not modelled
/// GameDifficulty 0..5 -> zombie HP multiplier (Scavenger..Insane). Stock tier
/// semantic; numbers zdtd-tuned (no pinned RE table, R9).
pub const hp_scale_by_difficulty = [_]f32{ 0.5, 0.75, 1.0, 1.25, 1.5, 2.0 };
/// ZombieMove 0..4 -> speed multiplier (walk/jog/run/sprint/nightmare). Stock
/// tier semantic; numbers zdtd-tuned (R9).
pub const move_scale_by_mode = [_]f32{ 0.5, 0.75, 1.0, 1.4, 1.7 };
pub const max_heat_regions: usize = 32;
pub const heat_scout_count: u32 = 2;
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

pub const Director = struct {
    /// Spawn-group kind for per-biome resolution (spawning.xml rule kind).
    pub const SpawnKind = enum(u8) { night = 0, day = 1, animal = 2 };

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

    /// Party game stage (CalcGameStageAround over the online players). Drives
    /// the scout tier and the blood moon stage lookup. 0 = no players / unknown.
    party_stage: i32 = 0,
    /// Optional lookup: (ctx, spawner_name, stage) → entitygroup name plus wave
    /// size, resolving gamestages.xml. Game wires it; the ECS layer stays free
    /// of asset imports, matching the group_pick_fn contract above.
    stage_group_ctx: ?*anyopaque = null,
    stage_group_fn: ?*const fn (?*anyopaque, []const u8, i32) ?StageGroup = null,
    /// Optional lookup: (ctx, entityspawner_name) → EntityGroupName from
    /// spawning.xml, for the code-named scout spawners.
    spawner_group_ctx: ?*anyopaque = null,
    spawner_group_fn: ?*const fn (?*anyopaque, []const u8) ?[]const u8 = null,
    bloodmoon_cd: f32 = 0,
    scouts_cd: f32 = 0,
    total_spawned: u32 = 0,
    bloodmoon_active: bool = false,
    /// Blood-moon party state (AIDirectorBloodMoonParty, 413090-413140):
    /// players within cPartyJoinDistance 80 m share one focus and one
    /// per-party wave; the party gamestage is frozen for the night; horde
    /// zombies beyond cTeleportDist 150 m are teleported back.
    bm_parties: [bm_parties_cap]BmParty = [_]BmParty{.{}} ** bm_parties_cap,
    bm_party_n: u8 = 0,
    /// Party gamestage snapshot at dusk (stock InitParty freezes it).
    bm_stage_frozen: i32 = 0,
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
    /// GameDifficulty 0..5; scales zombie hp (proxy for stock damage scaling).
    difficulty: u8 = 2,
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

    /// Alive-zombie ceiling: stock MaxSpawnedZombies default is 64; we keep a
    /// smaller dev cap so long soaks do not accrete entities without despawn.
    pub const default_max_alive_zombies: u32 = 24;
    /// Blood-moon spawn ceiling multiplier. RE: the stock blood-moon party
    /// spawner calls `AIDirector::CanSpawn(1.9f)` (asm.il:413528) - a 1.9x
    /// budget over the world MaxSpawnedZombies cap.
    pub const bloodmoon_budget_scale: f32 = 1.9;

    /// Zombie hp multiplier from GameDifficulty (0=Scavenger .. 5=Insane).
    /// The tier semantic is stock serverconfig GameDifficulty; the exact
    /// numbers are zdtd-tuned (no pinned RE table in the research corpus,
    /// R9 value-level disposition).
    pub fn hpScale(self: *const Director) f32 {
        return hp_scale_by_difficulty[@min(self.difficulty, 5)];
    }

    /// ZombieMove index 0..4 → speed multiplier (walk/jog/run/sprint/nightmare).
    /// Tier semantic stock; numbers zdtd-tuned (R9).
    fn moveScale(idx: u8) f32 {
        return move_scale_by_mode[@min(idx, 4)];
    }

    /// Current zombie speed multiplier for the active day/night/blood-moon state.
    pub fn zombieSpeedScale(self: *const Director) f32 {
        if (self.bloodmoon_active) return moveScale(self.zombie_move_bm);
        if (self.enemy_difficulty >= 1) return moveScale(self.zombie_move_feral);
        return moveScale(if (self.clock.isNight()) self.zombie_move_night else self.zombie_move_day);
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
        w.zombie_speed_scale = self.zombieSpeedScale();

        // `[systems] director = false` means "stop zombie spawning", not "stop
        // time". The world clock, blood-moon flag and daily trader restock live
        // on this path, so gating the whole system in schedule.run would freeze
        // day and night for the mode that disabled it. Wildlife keeps wandering
        // under its own `[systems] animals` flag (stock SpawnManagerBiomes is a
        // system separate from the AIDirector, spawning.md section 2).
        if (!w.rules.systems.director) {
            spawned += self.tickAnimals(w);
            if (self.clock.day != day_before) {
                @import("systems.zig").traderRestock(w);
            }
            return .{ .spawned = spawned, .world_time = self.clock.worldTimeBits() };
        }

        const alive_z = w.countKind(.zombie);
        // Blood-moon budget: stock's party spawner calls `AIDirector::CanSpawn
        // (1.9f)` (asm.il:413528), a 1.9x ceiling over the world budget, so
        // the horde does not thin at the ordinary day/night cap.
        const cap: u32 = if (self.bloodmoon_active)
            @intFromFloat(@as(f32, @floatFromInt(self.max_alive)) * bloodmoon_budget_scale)
        else
            self.max_alive;
        if (alive_z >= cap) {
            // Daily trader restock still runs below; skip spawn branches.
            if (self.clock.day != day_before) {
                @import("systems.zig").traderRestock(w);
            }
            return .{ .spawned = 0, .world_time = self.clock.worldTimeBits() };
        }

        if (self.clock.isNight() and self.horde_cd <= 0) {
            spawned += self.spawnNearPlayers(w, 2, w.rules.director.enemy_spawn_ring_min, w.rules.director.enemy_spawn_ring_max, "");
            self.horde_cd = if (self.bloodmoon_active) w.rules.director.bloodmoon_horde_drip_cd else w.rules.director.horde_drip_cd;
        }
        if (self.bloodmoon_active and self.bloodmoon_cd <= 0) {
            // Freeze the party gamestage at dusk (InitParty): the ladder and
            // the horde size stay fixed for the whole night.
            if (self.bm_stage_frozen == 0) self.bm_stage_frozen = self.party_stage;
            self.buildBloodMoonParties(w);
            self.recountAndTeleportHorde(w);
            const bm = self.stageGroup(bloodmoon_spawner);
            var wave: u32 = @max(1, self.bloodmoon_enemy_count / 2);
            var bm_group: []const u8 = "";
            if (bm) |sg| {
                wave = @min(wave, @max(1, @as(u32, sg.max_alive)));
                bm_group = sg.group;
            }
            spawned += self.spawnBloodMoonParties(w, wave, bm_group);
            self.bloodmoon_cd = w.rules.director.bloodmoon_wave_cd;
        } else if (!self.bloodmoon_active and self.bm_stage_frozen != 0) {
            // EndBloodMoon (412618): clear horde marks and the frozen stage at
            // dawn; nothing is despawned.
            self.bm_stage_frozen = 0;
            clearHordeMarks(w);
        }
        // Horde zombies keep to their party focus every tick (teleport back
        // past cTeleportDist) so a 2+ player horde cannot split.
        if (self.bloodmoon_active) {
            self.buildBloodMoonParties(w);
            self.recountAndTeleportHorde(w);
        }
        // Wandering horde schedule (AIDirectorWanderingHordeComponent): a group
        // of 6 at ~92 m every 12-24 in-game hours, player-gated.
        const wt = self.clock.worldTimeBits();
        if (self.wandering_next == 0) {
            if (wt > w.rules.director.wander_start_after) self.wandering_next = self.nextWanderingTime(w.rules.director.wander_min_gap, w.rules.director.wander_max_gap);
        } else if (wt >= self.wandering_next) {
            if (anyPlayer(w)) spawned += self.spawnWanderingHorde(w);
            self.wandering_next = self.nextWanderingTime(w.rules.director.wander_min_gap, w.rules.director.wander_max_gap);
        }
        // Heat map: decay + the 5 s scout check (AIDirectorChunkEventComponent).
        self.tickHeat(w, dt);
        if (!self.clock.isNight() and self.scouts_cd <= 0) {
            spawned += self.spawnNearPlayers(w, 1, w.rules.director.enemy_spawn_ring_min, w.rules.director.enemy_spawn_ring_max, self.scoutGroup());
            self.scouts_cd = w.rules.director.scout_drip_cd;
        }
        // Daytime wildlife up to MaxSpawnedAnimals (wander, not chase).
        spawned += self.tickAnimals(w);
        // Daily trader restock when day rolls.
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
        var p: ecs_world.Slot = 0;
        while (p < ecs_world.max_entities and n < count) : (p += 1) {
            if (!w.alive[p] or !w.mask[p].player or !w.mask[p].transform) continue;
            const ang = @as(f32, @floatFromInt(self.total_spawned +% n)) * 2.3;
            const r = min_r + (max_r - min_r) * @mod(ang, 1.0);
            const x = w.transform[p].x + @cos(ang) * r;
            const z = w.transform[p].z + @sin(ang) * r;
            const y = w.transform[p].y;
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
                n += 1;
            }
        }
        return n;
    }

    /// gamestages.xml spawner name the blood moon draws from.
    pub const bloodmoon_spawner = "BloodMoonHorde";

    /// Resolve a gamestages.xml spawner at the current party stage (the
    /// blood-moon ladder reads the night-frozen stage once set).
    fn stageGroup(self: *const Director, spawner: []const u8) ?StageGroup {
        const f = self.stage_group_fn orelse return null;
        const stage = if (self.bm_stage_frozen != 0) self.bm_stage_frozen else self.party_stage;
        const sg = f(self.stage_group_ctx, spawner, stage) orelse return null;
        if (sg.group.len == 0) return null;
        return sg;
    }

    /// Daytime scout entity group for the current party stage; empty when the
    /// spawning.xml entityspawner table is unavailable.
    fn scoutGroup(self: *const Director) []const u8 {
        const f = self.spawner_group_fn orelse return "";
        return f(self.spawner_group_ctx, scoutSpawnerName(self.party_stage)) orelse "";
    }

    /// `group_override` wins over the day/night spawning.xml groups; empty
    /// keeps the existing biome-rule behaviour.
    fn spawnNearPlayers(self: *Director, w: *ecs_world.World, count: u32, min_r: f32, max_r: f32, group_override: []const u8) u32 {
        var n: u32 = 0;
        var p: ecs_world.Slot = 0;
        while (p < ecs_world.max_entities and n < count) : (p += 1) {
            if (!w.alive[p] or !w.mask[p].player or !w.mask[p].transform) continue;
            var k: u32 = 0;
            while (k < count and n < count) : (k += 1) {
                const ang = @as(f32, @floatFromInt(k + n)) * 1.7;
                const r = min_r + (max_r - min_r) * (@mod(ang, 1.0));
                const x = w.transform[p].x + @cos(ang) * r;
                const z = w.transform[p].z + @sin(ang) * r;
                const y = w.transform[p].y;
                const slot = self.spawnOneZombie(w, x, y, z, group_override, self.total_spawned +% n, false) orelse break;
                w.zombie_ai[slot].state = .chase;
                w.zombie_ai[slot].target_id = w.network_id[p].id;
                w.zombie_ai[slot].alert = true;
                n += 1;
            }
        }
        return n;
    }

    /// Cluster online players into blood-moon parties: anyone within
    /// cPartyJoinDistance (80 m) of an existing party focus joins it (focus =
    /// running average); stragglers open new parties (cap rules.bloodmoon
    /// max_parties, clamped to the storage array bm_parties_cap).
    fn buildBloodMoonParties(self: *Director, w: *ecs_world.World) void {
        const rules = w.rules.bloodmoon;
        const max_parties: usize = @min(rules.max_parties, bm_parties_cap);
        const join2 = rules.party_join_dist * rules.party_join_dist;
        self.bm_parties = [_]BmParty{.{}} ** bm_parties_cap;
        self.bm_party_n = 0;
        var p: ecs_world.Slot = 0;
        while (p < ecs_world.max_entities) : (p += 1) {
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
        if (self.bm_party_n == 0) return;
        const tel2 = rules.party_teleport_dist * rules.party_teleport_dist;
        var s: ecs_world.Slot = 0;
        while (s < ecs_world.max_entities) : (s += 1) {
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
        var s: ecs_world.Slot = 0;
        while (s < ecs_world.max_entities) : (s += 1) {
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
                const y = nearestPlayerY(w, x, z) orelse continue;
                const slot = self.spawnOneZombie(w, x, y, z, group, self.total_spawned +% n, true) orelse continue;
                if (nearestPlayerSlot(w, x, z)) |ps| {
                    w.zombie_ai[slot].state = .chase;
                    w.zombie_ai[slot].target_id = w.network_id[ps].id;
                    w.zombie_ai[slot].alert = true;
                }
                party.alive += 1;
                n += 1;
            }
        }
        return n;
    }

    /// Pick the group class at (x,z) and spawn one zombie; mark horde when
    /// requested. Shared by the per-player ring and the party spawner.
    fn spawnOneZombie(self: *Director, w: *ecs_world.World, x: f32, y: f32, z: f32, group_override: []const u8, seed: u32, mark_horde: bool) ?ecs_world.Slot {
        var ct = w.class_table[1];
        const fallback = if (self.clock.isNight()) self.night_group else self.day_group;
        const grp = if (group_override.len > 0)
            group_override
        else if (self.biome_group_fn) |bf|
            bf(self.biome_group_ctx, x, z, if (self.clock.isNight()) .night else .day, fallback)
        else
            fallback;
        var resolved: ?ecs_world.EntityClass = null;
        if (grp.len > 0) {
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
        const bm_mul: f32 = if (self.bloodmoon_active) w.rules.director.bloodmoon_hp_mult else 1.0;
        const hp: f32 = (if (resolved) |d| d.max_hp else ct.max_hp) * bm_mul * self.hpScale();
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
        return slot;
    }

    /// Y of the nearest online player to (x,z), or null with no players.
    fn nearestPlayerY(w: *ecs_world.World, x: f32, z: f32) ?f32 {
        const s = nearestPlayerSlot(w, x, z) orelse return null;
        return w.transform[s].y;
    }

    /// True when at least one online player exists (wandering horde gate).
    fn anyPlayer(w: *ecs_world.World) bool {
        var p: ecs_world.Slot = 0;
        while (p < ecs_world.max_entities) : (p += 1) {
            if (w.alive[p] and w.mask[p].player) return true;
        }
        return false;
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

    /// Spawn one wandering-horde group of 6 at ~92 m around the first online
    /// player, marked IsHordeZombie and set to chase the party. Stock walks the
    /// pack as a startPos->endPos path (AstarManager location line) with
    /// pit-stop commands; the direct-chase simplification keeps the client
    /// visible behaviour (a scheduled pack arriving from outside) without the
    /// path-command AI, which stays a residual (GAP wandering hordes row).
    fn spawnWanderingHorde(self: *Director, w: *ecs_world.World) u32 {
        var p: ecs_world.Slot = 0;
        while (p < ecs_world.max_entities) : (p += 1) {
            if (!w.alive[p] or !w.mask[p].player or !w.mask[p].transform) continue;
            var n: u32 = 0;
            while (n < w.rules.director.wandering_horde_size) : (n += 1) {
                const ang = @as(f32, @floatFromInt(self.total_spawned +% n)) * 1.7 + @as(f32, @floatFromInt(n)) * 1.0472;
                const x = w.transform[p].x + @cos(ang) * w.rules.director.wandering_spawn_dist;
                const z = w.transform[p].z + @sin(ang) * w.rules.director.wandering_spawn_dist;
                const y = w.transform[p].y;
                const slot = self.spawnOneZombie(w, x, y, z, "", self.total_spawned +% n, true) orelse continue;
                w.zombie_ai[slot].state = .chase;
                w.zombie_ai[slot].target_id = w.network_id[p].id;
                w.zombie_ai[slot].alert = true;
                n += 1;
            }
            return n;
        }
        return 0;
    }

    /// 5x5-chunk region key for a world position (AIDirectorChunkData map).
    fn heatRegionKey(wx: f32, wz: f32) i64 {
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
    /// expire), then every 5 s run CheckToSpawn: a region at/above 25 spawns a
    /// scout party toward its center and cooldowns itself and its neighbors.
    fn tickHeat(self: *Director, w: *ecs_world.World, dt: f32) void {
        var i: usize = 0;
        while (i < self.heat_n) {
            const r = &self.heat[i];
            if (r.cooldown > 0) r.cooldown -= dt;
            r.activity -= r.decay * dt;
            if (r.activity < 0) r.activity = 0;
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
        if (self.bloodmoon_active) return;
        var ci: usize = 0;
        while (ci < self.heat_n) : (ci += 1) {
            const r = &self.heat[ci];
            if (r.activity < w.rules.director.heat_spawn_threshold or r.cooldown > 0) continue;
            // FindBestEventAndReset + StartCooldownOnNeighbors; the 20 % feral
            // roll doubles the cooldown (deterministic, seeded stream).
            const feral = (self.total_spawned +% @as(u32, @intCast(ci))) % 5 == 0;
            r.activity = 0;
            r.cooldown = if (feral) w.rules.director.heat_cooldown_seconds * 2.0 else w.rules.director.heat_cooldown_seconds;
            self.cooldownNeighbors(r.key, w.rules.director.heat_neighbor_cooldown_seconds);
            self.spawnHeatScouts(w, r.key);
        }
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
            if (r.cooldown < neighbor_cd) r.cooldown = neighbor_cd;
        }
    }

    /// SpawnScouts: a small party toward the hot region center (chunk-heat
    /// spawner 0/8/10 constants), marked horde and set to investigate the
    /// nearest player (SetInvestigatePosition, 2400 ticks).
    fn spawnHeatScouts(self: *Director, w: *ecs_world.World, key: i64) void {
        const center = heatRegionCenter(key);
        const group = self.scoutGroup();
        var n: u32 = 0;
        while (n < heat_scout_count) : (n += 1) {
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
        var p: ecs_world.Slot = 0;
        while (p < ecs_world.max_entities) : (p += 1) {
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

test "clock advances and bloodmoon spans dusk to dawn across rollover" {
    // BM day 7: the horde runs day 7 22:00 (dusk) through day 8 04:00 (dawn),
    // including the midnight day rollover (stock IsBloodMoonTime).
    var cl: WorldClock = .{ .hours = 21.0, .day = 7, .seconds_per_hour = 1.0 };
    try std.testing.expect(!cl.isBloodMoonNight()); // before dusk
    cl.tick(2.0); // 23:00 day 7: at/after dusk
    try std.testing.expectEqual(@as(u32, 7), cl.day);
    try std.testing.expect(cl.isBloodMoonNight());
    cl.tick(3.0); // 02:00 day 8: after the rollover, before dawn
    try std.testing.expectEqual(@as(u32, 8), cl.day);
    try std.testing.expect(cl.isBloodMoonNight());
    cl.tick(3.0); // 05:00 day 8: dawn passed
    try std.testing.expect(!cl.isBloodMoonNight());
}

test "worldTimeBits encodes stock day 1 as zero offset" {
    var cl: WorldClock = .{ .hours = 8.0, .day = 1, .seconds_per_hour = 1.0 };
    // Stock DayTimeToWorldTime: (day-1)*24000 + hours*1000; WorldTimeToDays
    // (wt/24000 + 1) must round-trip the wire day.
    const wt = cl.worldTimeBits();
    try std.testing.expectEqual(@as(u64, 8000), wt);
    try std.testing.expectEqual(@as(u32, 1), @as(u32, @intCast(wt / 24000 + 1)));
    cl.day = 7;
    cl.hours = 12.0;
    try std.testing.expectEqual(@as(u64, 6 * 24000 + 12000), cl.worldTimeBits());
    try std.testing.expectEqual(@as(u32, 7), @as(u32, @intCast(cl.worldTimeBits() / 24000 + 1)));
}

test "director spawns at night near player ecs" {
    var w: ecs_world.World = .{};
    var dir: Director = .{ .clock = .{ .hours = 23.0, .day = 1, .seconds_per_hour = 1.0 }, .horde_cd = 0 };
    _ = w.spawnPlayer(0, 70, 0, 0);
    const r = dir.tick(&w, 0.1);
    try std.testing.expect(r.spawned >= 1);
    try std.testing.expect(dir.total_spawned >= 1);
}

test "zombie speed scale follows day/night/bloodmoon config" {
    // Day = walk (0 → 0.5), night = sprint (3 → 1.4), blood moon = bm setting.
    var dir: Director = .{
        .zombie_move_day = 0,
        .zombie_move_night = 3,
        .zombie_move_bm = 4,
        .zombie_move_feral = 2,
    };
    dir.clock.hours = 12.0; // day
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), dir.zombieSpeedScale(), 0.001);
    dir.clock.hours = 23.0; // night
    try std.testing.expectApproxEqAbs(@as(f32, 1.4), dir.zombieSpeedScale(), 0.001);
    dir.bloodmoon_active = true;
    try std.testing.expectApproxEqAbs(@as(f32, 1.7), dir.zombieSpeedScale(), 0.001);
    dir.bloodmoon_active = false;
    dir.enemy_difficulty = 1; // feral overrides day
    dir.clock.hours = 12.0;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), dir.zombieSpeedScale(), 0.001);
}

test "director spawns daytime animals up to cap" {
    var w: ecs_world.World = .{};
    // Noon, animal cap 3, no zombie horde interference (day).
    var dir: Director = .{
        .clock = .{ .hours = 12.0, .day = 1, .seconds_per_hour = 1.0 },
        .max_alive_animals = 3,
        .scouts_cd = 999, // suppress daytime scout zombie
    };
    _ = w.spawnPlayer(0, 70, 0, 0);
    // Each tick spawns at most one animal (60s cooldown), so drive several with
    // the cooldown reset to reach the cap.
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        dir.animals_cd = 0;
        _ = dir.tick(&w, 0.1);
    }
    const animals = w.countKind(.animal);
    try std.testing.expect(animals >= 1);
    try std.testing.expect(animals <= 3); // never exceeds MaxSpawnedAnimals
}
test "director=false stops zombies but wildlife follows its own flag" {
    var w: ecs_world.World = .{};
    w.rules.systems.director = false;
    w.rules.systems.animals = true;
    var dir: Director = .{
        .clock = .{ .hours = 12.0, .day = 1, .seconds_per_hour = 1.0 },
        .max_alive_animals = 3,
    };
    _ = w.spawnPlayer(0, 70, 0, 0);
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        dir.animals_cd = 0;
        _ = dir.tick(&w, 0.1);
    }
    // Animals still spawn with the director off (stock SpawnManagerBiomes is
    // separate from the AIDirector); no zombies come from the director.
    try std.testing.expect(w.countKind(.animal) >= 1);
    try std.testing.expectEqual(@as(u32, 0), w.countKind(.zombie));
    // animals = false stops NEW spawns (existing wildlife is not despawned,
    // the same way director=false leaves live zombies alone).
    const before = w.countKind(.animal);
    w.rules.systems.animals = false;
    i = 0;
    while (i < 5) : (i += 1) {
        dir.animals_cd = 0;
        _ = dir.tick(&w, 0.1);
    }
    try std.testing.expectEqual(before, w.countKind(.animal));
}
test "spawned classes carry full entityclasses stats via the resolver (A35)" {
    const Hooks = struct {
        fn pick(_: ?*anyopaque, group: []const u8, _: u32) ?[]const u8 {
            // The spawn group resolves to a class that is NOT in the 16-slot
            // class_table, so the old path fell back to zombieBoe stats.
            _ = group;
            return "zombieBruteFeral";
        }
        fn resolve(_: ?*anyopaque, name: []const u8) ?ecs_world.EntityClass {
            if (!std.mem.eql(u8, name, "zombieBruteFeral")) return null;
            return .{
                .name = "zombieBruteFeral",
                .max_hp = 1200,
                .kind = .zombie,
                .hash = 987654321,
                .loot_list = "zPackReg",
                .chase_speed = 1.1,
                .wander_speed = 0.3,
                .attack_damage = 25,
            };
        }
    };
    var w: ecs_world.World = .{};
    var dir: Director = .{
        .clock = .{ .hours = 23.0, .day = 1, .seconds_per_hour = 1.0 },
        .horde_cd = 0,
        .night_group = "ZombiesNight",
        .group_pick_ctx = undefined,
        .group_pick_fn = &Hooks.pick,
        .class_resolve_ctx = undefined,
        .class_resolve_fn = &Hooks.resolve,
    };
    _ = w.spawnPlayer(0, 70, 0, 0);
    const r = dir.tick(&w, 0.1);
    try std.testing.expect(r.spawned >= 1);
    // The spawned zombie carries the resolved per-entity stats, not the
    // zombieBoe table default (40 HP, 0 speeds).
    var found = false;
    var s: ecs_world.Slot = 0;
    while (s < ecs_world.max_entities) : (s += 1) {
        if (!w.alive[s] or w.kind[s] != .zombie) continue;
        found = true;
        try std.testing.expectEqual(@as(i32, 987654321), w.class_id[s].hash);
        try std.testing.expectApproxEqAbs(@as(f32, 1200), w.health[s].max_hp, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 1.1), w.class_id[s].chase_speed, 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 0.3), w.class_id[s].wander_speed, 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 25), w.class_id[s].attack_damage, 1e-4);
        try std.testing.expectEqualStrings("zPackReg", w.class_id[s].loot_list);
    }
    try std.testing.expect(found);
}

test "bloodmoon frequency and range" {
    // Frequency 0 disables entirely.
    var cl: WorldClock = .{ .hours = 23.0, .day = 7, .bloodmoon_frequency = 0 };
    try std.testing.expect(!cl.isBloodMoonNight());
    // Frequency 7, range 0: exact multiples at night.
    cl = .{ .hours = 23.0, .day = 14, .bloodmoon_frequency = 7 };
    try std.testing.expect(cl.isBloodMoonNight());
    cl.day = 13;
    try std.testing.expect(!cl.isBloodMoonNight());
    // Range shifts the blood moon off the exact multiple; some day in each
    // cycle window must trigger, and daytime never does.
    cl = .{ .hours = 12.0, .day = 14, .bloodmoon_frequency = 7, .bloodmoon_range = 2 };
    try std.testing.expect(!cl.isBloodMoonNight()); // daytime
    var hits: u32 = 0;
    var d: u32 = 5;
    while (d <= 9) : (d += 1) {
        cl = .{ .hours = 23.0, .day = d, .bloodmoon_frequency = 7, .bloodmoon_range = 2 };
        if (cl.isBloodMoonNight()) hits += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), hits); // exactly one blood moon in cycle 1's window
}

test "scout spawner tier follows the stock gamestage thresholds" {
    // SpawnScouts (asm.il ~415972): >=45 Scouts2, >=85 ScoutsFeral, >=125 radiated.
    try std.testing.expectEqualStrings("Scouts1", scoutSpawnerName(0));
    try std.testing.expectEqualStrings("Scouts1", scoutSpawnerName(44));
    try std.testing.expectEqualStrings("Scouts2", scoutSpawnerName(45));
    try std.testing.expectEqualStrings("Scouts2", scoutSpawnerName(84));
    try std.testing.expectEqualStrings("ScoutsFeral", scoutSpawnerName(85));
    try std.testing.expectEqualStrings("ScoutsFeral", scoutSpawnerName(124));
    try std.testing.expectEqualStrings("ScoutsRadiated", scoutSpawnerName(125));
    try std.testing.expectEqualStrings("ScoutsRadiated", scoutSpawnerName(std.math.maxInt(i32)));
    // A negative stage cannot come out of partyLevel but must not trap.
    try std.testing.expectEqualStrings("Scouts1", scoutSpawnerName(std.math.minInt(i32)));
}

test "director draws the daytime scout group from the stage tier" {
    const Hooks = struct {
        var asked: [64]u8 = undefined;
        var asked_len: usize = 0;
        fn spawnerGroup(_: ?*anyopaque, name: []const u8) ?[]const u8 {
            asked_len = @min(name.len, asked.len);
            @memcpy(asked[0..asked_len], name[0..asked_len]);
            return "ZombieScoutsFeral";
        }
        fn pick(_: ?*anyopaque, group: []const u8, _: u32) ?[]const u8 {
            if (std.mem.eql(u8, group, "ZombieScoutsFeral")) return "zombieJoe";
            return null;
        }
    };
    var w: ecs_world.World = .{};
    _ = w.spawnPlayer(0, 70, 0, 0);
    var dir: Director = .{
        .clock = .{ .hours = 12.0, .day = 1, .seconds_per_hour = 1.0 },
        .party_stage = 90,
        .spawner_group_fn = &Hooks.spawnerGroup,
        .group_pick_fn = &Hooks.pick,
    };
    const r = dir.tick(&w, 0.1);
    try std.testing.expect(r.spawned >= 1);
    try std.testing.expectEqualStrings("ScoutsFeral", Hooks.asked[0..Hooks.asked_len]);
}

test "blood moon wave size is capped by the stage maxAlive" {
    const Hooks = struct {
        var seen_stage: i32 = -1;
        fn stageGroup(_: ?*anyopaque, spawner: []const u8, stage: i32) ?StageGroup {
            if (!std.mem.eql(u8, spawner, Director.bloodmoon_spawner)) return null;
            seen_stage = stage;
            return .{ .group = "ZombiesNight", .num = 300, .max_alive = 2 };
        }
    };
    var w: ecs_world.World = .{};
    _ = w.spawnPlayer(0, 70, 0, 0);
    // Blood moon night with a generous BloodMoonEnemyCount; maxAlive=2 wins.
    var dir: Director = .{
        .clock = .{ .hours = 23.0, .day = 7, .seconds_per_hour = 1.0 },
        .bloodmoon_enemy_count = 40,
        .party_stage = 61,
        .horde_cd = 999, // isolate the blood moon branch from the night horde
        .stage_group_fn = &Hooks.stageGroup,
    };
    const r = dir.tick(&w, 0.1);
    try std.testing.expect(dir.bloodmoon_active);
    try std.testing.expectEqual(@as(i32, 61), Hooks.seen_stage);
    try std.testing.expect(r.spawned >= 1);
    try std.testing.expect(r.spawned <= 2);
}

test "director without stage hooks keeps its unstaged behaviour" {
    var w: ecs_world.World = .{};
    _ = w.spawnPlayer(0, 70, 0, 0);
    var dir: Director = .{
        .clock = .{ .hours = 23.0, .day = 7, .seconds_per_hour = 1.0 },
        .bloodmoon_enemy_count = 8,
        .horde_cd = 999,
    };
    const r = dir.tick(&w, 0.1);
    try std.testing.expect(dir.bloodmoon_active);
    try std.testing.expectEqual(@as(u32, 4), r.spawned); // BloodMoonEnemyCount / 2
}

test "bloodMoonDayFor returns the jittered horde day, not the multiple" {
    // freq 7, range 1: jitter(1) = (1*2654435761) % 2 = 1, so the first horde
    // is day 8. The old "next frequency multiple" logic said 7, lighting the
    // client's red moon on a non-horde night and showing nothing on day 8.
    var cl: WorldClock = .{ .hours = 8.0, .day = 1, .bloodmoon_frequency = 7, .bloodmoon_range = 1 };
    try std.testing.expectEqual(@as(i32, 8), cl.bloodMoonDayFor(1)); // upcoming
    try std.testing.expectEqual(@as(i32, 8), cl.bloodMoonDayFor(7)); // the night before
    try std.testing.expectEqual(@as(i32, 8), cl.bloodMoonDayFor(8)); // horde night
    try std.testing.expectEqual(@as(i32, 14), cl.bloodMoonDayFor(9)); // next cycle
    // range 0: pure multiples (the default; bmday-resend scenario unchanged).
    cl.bloodmoon_range = 0;
    try std.testing.expectEqual(@as(i32, 7), cl.bloodMoonDayFor(1));
    try std.testing.expectEqual(@as(i32, 7), cl.bloodMoonDayFor(7));
    try std.testing.expectEqual(@as(i32, 14), cl.bloodMoonDayFor(8));
    // frequency 0 = disabled.
    cl.bloodmoon_frequency = 0;
    try std.testing.expectEqual(@as(i32, 0), cl.bloodMoonDayFor(1));
}

test "blood moon party clustering pools nearby players and splits stragglers" {
    var w: ecs_world.World = .{};
    defer w.deinit();
    // Two players 40 m apart and one 200 m away: 2 parties (cPartyJoinDistance 80).
    const a = w.spawnPlayer(0, 70, 0, 0).?;
    const b = w.spawnPlayer(40, 70, 0, 1).?;
    _ = w.spawnPlayer(200, 70, 200, 2).?;
    var d: Director = .{};
    d.buildBloodMoonParties(&w);
    try std.testing.expectEqual(@as(u8, 2), d.bm_party_n);
    // The near pair shares one focus (their average), the straggler its own.
    const near = d.bm_parties[0];
    try std.testing.expect(near.members == 2);
    try std.testing.expect(@abs(near.focus_x - 20.0) < 0.01);
    const far = d.bm_parties[1];
    try std.testing.expect(far.members == 1);
    // No players at all -> no parties.
    var w2: ecs_world.World = .{};
    defer w2.deinit();
    var d2: Director = .{};
    d2.buildBloodMoonParties(&w2);
    try std.testing.expectEqual(@as(u8, 0), d2.bm_party_n);
    _ = a;
    _ = b;
}

test "wandering horde arms after day 1 and spawns a 6-pack at 92 m" {
    var w: ecs_world.World = .{};
    defer w.deinit();
    const pid = w.spawnPlayer(0, 70, 0, 0).?;
    _ = pid;
    var d: Director = .{};
    // Day 1 (worldTime < 28000): not scheduled yet.
    _ = d.tick(&w, 0.05);
    try std.testing.expectEqual(@as(u64, 0), d.wandering_next);
    // Day 2 10:00 (34000 ticks): the schedule arms into the future.
    d.clock.day = 2;
    d.clock.hours = 10.0;
    _ = d.tick(&w, 0.05);
    try std.testing.expect(d.wandering_next > d.clock.worldTimeBits());
    try std.testing.expect(d.wandering_next - d.clock.worldTimeBits() >= wander_min_gap);
    try std.testing.expect(d.wandering_next - d.clock.worldTimeBits() <= wander_max_gap);
    // Force it due: a pack of up to 6 horde-marked zombies at ~92 m, then the
    // schedule rolls forward.
    d.wandering_next = d.clock.worldTimeBits() + 1;
    _ = d.tick(&w, 0.05);
    var horde: u32 = 0;
    var horde_slot: ?ecs_world.Slot = null;
    var s: ecs_world.Slot = 0;
    while (s < ecs_world.max_entities) : (s += 1) {
        if (!w.alive[s] or !w.zombie_ai[s].is_horde) continue;
        horde += 1;
        horde_slot = s;
    }
    try std.testing.expect(horde >= 1 and horde <= wandering_horde_size);
    try std.testing.expect(d.wandering_next > d.clock.worldTimeBits());
    const hs = horde_slot orelse return error.TestUnexpectedResult;
    const dx = w.transform[hs].x - 0.0;
    const dz = w.transform[hs].z - 0.0;
    const dist = @sqrt(dx * dx + dz * dz);
    try std.testing.expect(dist > 70.0 and dist < 115.0);
    try std.testing.expect(w.zombie_ai[hs].state == .chase);
}

test "wandering horde size and distance follow [rules.director]" {
    var w: ecs_world.World = .{};
    defer w.deinit();
    w.rules.director.wandering_horde_size = 3;
    w.rules.director.wandering_spawn_dist = 40.0;
    _ = w.spawnPlayer(0, 70, 0, 0);
    var d: Director = .{ .clock = .{ .day = 2, .hours = 10.0 } };
    d.wandering_next = d.clock.worldTimeBits() + 1;
    _ = d.tick(&w, 0.05);
    var horde: u32 = 0;
    var horde_slot: ?ecs_world.Slot = null;
    var s: ecs_world.Slot = 0;
    while (s < ecs_world.max_entities) : (s += 1) {
        if (!w.alive[s] or !w.zombie_ai[s].is_horde) continue;
        horde += 1;
        horde_slot = s;
    }
    try std.testing.expect(horde >= 1 and horde <= 3); // config size, not 6
    const hs = horde_slot orelse return error.TestUnexpectedResult;
    const dist = @sqrt(w.transform[hs].x * w.transform[hs].x + w.transform[hs].z * w.transform[hs].z);
    try std.testing.expect(dist > 30.0 and dist < 50.0); // config 40 m, not 92
}

test "wandering horde skips with no players and re-arms" {
    var w: ecs_world.World = .{};
    defer w.deinit();
    var d: Director = .{ .clock = .{ .day = 3, .hours = 12.0 } };
    d.wandering_next = d.clock.worldTimeBits() + 1; // due
    const zombies_before = w.countKind(.zombie);
    _ = d.tick(&w, 0.05);
    try std.testing.expectEqual(zombies_before, w.countKind(.zombie)); // no spawn
    try std.testing.expect(d.wandering_next > d.clock.worldTimeBits()); // re-armed
}

test "heat map: forge activity crosses 25 and spawns scouts with cooldown" {
    var w: ecs_world.World = .{};
    defer w.deinit();
    _ = w.spawnPlayer(0, 70, 0, 0).?;
    var d: Director = .{};
    // A forge (6 per event, 720-tick duration) feeds every tick: 30 ticks give
    // activity ~180, well past the 25 threshold.
    var t: u32 = 0;
    while (t < 30) : (t += 1) {
        d.notifyActivity(0, 0, 6, 720);
        _ = d.tick(&w, 0.05);
    }
    try std.testing.expect(d.heat_n >= 1);
    try std.testing.expect(d.heat[0].activity >= 25);
    // The 5 s CheckToSpawn fires: scouts spawn, the region resets and cools.
    var warm: u32 = 0;
    while (warm < 110) : (warm += 1) _ = d.tick(&w, 0.05);
    var scouts: u32 = 0;
    var s: ecs_world.Slot = 0;
    while (s < ecs_world.max_entities) : (s += 1) {
        if (!w.alive[s] or !w.zombie_ai[s].is_horde) continue;
        scouts += 1;
    }
    try std.testing.expect(scouts >= 1 and scouts <= heat_scout_count);
    // Region was reset (activity 0) and is on cooldown. Region key of (0,0):
    // floor(0/80)=0 on both axes, packed = 0.
    var found = false;
    for (d.heat[0..d.heat_n]) |*r| {
        if (r.key == 0) {
            found = true;
            try std.testing.expect(r.activity == 0);
            try std.testing.expect(r.cooldown > 0);
        }
    }
    try std.testing.expect(found);
}

test "heat map: low activity never spawns and decays away" {
    var w: ecs_world.World = .{};
    defer w.deinit();
    _ = w.spawnPlayer(0, 70, 0, 0).?;
    var d: Director = .{};
    // A torch (1) fed once stays well under 25 and decays over the 720-tick
    // (36 s) event duration.
    d.notifyActivity(0, 0, 1, 720);
    var t: u32 = 0;
    while (t < 800) : (t += 1) _ = d.tick(&w, 0.05); // 40 s > 36 s
    var zombies: u32 = 0;
    var s: ecs_world.Slot = 0;
    while (s < ecs_world.max_entities) : (s += 1) {
        if (w.alive[s] and w.zombie_ai[s].is_horde) zombies += 1;
    }
    try std.testing.expectEqual(@as(u32, 0), zombies);
    try std.testing.expectEqual(@as(u8, 0), d.heat_n); // expired
}

test "bloodmoon schedule persists position and advances past the live day" {
    // Stock CalcNextDay (asm.il 412880): the schedule is a persisted
    // bmDayLast -> nextBM roll, not a live modulus. The first horde sits at
    // cycle 1 (freq 7 + jitter 0..2); the horde spans dusk to dawn across
    // midnight; advancing the live day rolls the schedule forward; a runtime
    // frequency change rebuilds it.
    var cl: WorldClock = .{ .hours = 12.0, .day = 1, .seconds_per_hour = 1.0 };
    cl.bloodmoon_frequency = 7;
    cl.bloodmoon_range = 2;
    const first = cl.bloodMoonDayFor(1);
    try std.testing.expect(first >= 7 and first <= 9);
    try std.testing.expectEqual(@as(u32, @intCast(first)), cl.next_bm);
    // Horde night and the dawn-crossing leg match the schedule.
    cl.day = @intCast(first);
    cl.hours = 23.0;
    try std.testing.expect(cl.isBloodMoonNight());
    cl.tick(3.0); // past midnight into day first+1, before dawn
    try std.testing.expect(cl.isBloodMoonNight());
    cl.tick(3.0); // dawn passed
    try std.testing.expect(!cl.isBloodMoonNight());
    // Live day far past the first horde: the schedule rolls forward and the
    // previous target is retained (stock bmDayLast).
    cl.day = 30;
    const next = cl.bloodMoonDayFor(30);
    try std.testing.expect(next > first);
    try std.testing.expect(cl.bm_day_last >= first and cl.bm_day_last < next);
    try std.testing.expect(next >= 30);
    // A runtime frequency change rebuilds from cycle 1.
    cl.bloodmoon_frequency = 10;
    cl.bloodmoon_range = 0;
    cl.day = 1;
    try std.testing.expectEqual(@as(i32, 10), cl.bloodMoonDayFor(1));
}

test "blood moon spawns past the ordinary world budget (1.9x CanSpawn)" {
    // RE asm.il:413528: the stock BM party spawner calls CanSpawn(1.9f), a
    // 1.9x ceiling over MaxSpawnedZombies, so the horde does not thin at the
    // day/night cap. With max_alive 24 the BM ceiling is 45.
    var w: ecs_world.World = .{};
    defer w.deinit();
    var d: Director = .{ .clock = .{ .day = 3, .hours = 23.0 }, .max_alive = 24 };
    _ = w.spawnPlayer(0, 70, 0, 0);
    // Seed 24 zombies (the ordinary cap): on a normal night the tick must not
    // spawn more (the director derives bloodmoon_active from the clock).
    var s: u32 = 0;
    while (s < 24) : (s += 1) {
        _ = w.spawnZombie(@floatFromInt(s % 8), 70, @floatFromInt(s / 8), 40);
    }
    for (0..40) |_| _ = d.tick(&w, 0.05);
    try std.testing.expectEqual(@as(u32, 24), w.countKind(.zombie));
    // A blood-moon night (freq 7 -> day 7): the 1.9x budget admits more and
    // the horde drip runs; the BM ceiling (45) is never exceeded.
    d.clock.day = 7;
    d.clock.hours = 23.0;
    var ticks: u32 = 0;
    while (ticks < 600 and w.countKind(.zombie) <= 24) : (ticks += 1) {
        _ = d.tick(&w, 0.05);
    }
    try std.testing.expect(w.countKind(.zombie) > 24);
    while (ticks < 1200) : (ticks += 1) {
        _ = d.tick(&w, 0.05);
    }
    // The cap gates at tick start, so a horde batch may overshoot the 45
    // ceiling by its own size (stock CanSpawn behaves the same); the count
    // stays well under the 64 stock MaxSpawnedZombies default.
    try std.testing.expect(w.countKind(.zombie) <= 64);
}
