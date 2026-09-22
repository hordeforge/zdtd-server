//! AI director tests: clock, spawning, blood moon, hordes, heat.
//!
//! Split out of ecs/aidirector.zig (same code, moved verbatim).

const std = @import("std");
const aidirector = @import("aidirector.zig");
const Director = aidirector.Director;
const WorldClock = aidirector.WorldClock;
const director_defaults = aidirector.director_defaults;
const world_time_units_per_hour = aidirector.world_time_units_per_hour;
const ecs_world = @import("world.zig");
const timeOfDayIncPerSec = aidirector.timeOfDayIncPerSec;
const StageGroup = aidirector.StageGroup;
const WaveRange = aidirector.WaveRange;
const RuleBudget = aidirector.RuleBudget;
const scoutSpawnerName = aidirector.scoutSpawnerName;
const heat_cooldown_seconds = aidirector.heat_cooldown_seconds;
const wander_min_gap = aidirector.wander_min_gap;
const wander_max_gap = aidirector.wander_max_gap;
const wandering_horde_size = aidirector.wandering_horde_size;
const wandering_spawn_dist = aidirector.wandering_spawn_dist;

test "clock rate is the stock truncated TimeOfDayIncPerSec" {
    // RE ../7dtd-engine-research/docs/admin/server-lifecycle.md:168:
    // GameStats[11] = 24000 / (DayNightLength * 60), integer division.
    try std.testing.expectEqual(@as(u32, 40), timeOfDayIncPerSec(10));
    try std.testing.expectEqual(@as(u32, 6), timeOfDayIncPerSec(60));
    try std.testing.expectEqual(@as(u32, 4), timeOfDayIncPerSec(90));
    try std.testing.expectEqual(@as(u32, 3), timeOfDayIncPerSec(120));
    try std.testing.expectEqual(@as(u32, 1), timeOfDayIncPerSec(400));
    // The stock expression truncates to 0 past 400 real minutes, which freezes
    // world time. Reproduce it rather than inventing a floor nobody measured.
    try std.testing.expectEqual(@as(u32, 0), timeOfDayIncPerSec(401));
    try std.testing.expectEqual(@as(u32, 0), timeOfDayIncPerSec(1200));

    var cl: WorldClock = .{};
    cl.setDayNightLength(60);
    try std.testing.expectEqual(@as(u16, 60), cl.day_night_length);
    try std.testing.expectEqual(@as(u32, 6), cl.time_of_day_inc_per_sec);
    // A stock 60 minute day really runs 24000/6 = 4000 s. Sixty seconds of
    // 20 TPS ticks advance 0.36 in-game hours; the old flat scale (6.667
    // ticks/s) advanced 0.4 and ran the client's day ahead of the server's.
    var i: usize = 0;
    while (i < 1200) : (i += 1) cl.tick(0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 7.36), cl.hours, 1e-3);

    // Frozen rate advances nothing.
    var frozen: WorldClock = .{};
    frozen.setDayNightLength(1200);
    frozen.tick(600.0);
    try std.testing.expectEqual(@as(f32, 7.0), frozen.hours);
}

test "clock advances and bloodmoon spans dusk to dawn across rollover" {
    // BM day 7: the horde runs day 7 22:00 (dusk) through day 8 04:00 (dawn),
    // including the midnight day rollover (stock IsBloodMoonTime).
    var cl: WorldClock = .{ .hours = 21.0, .day = 7, .time_of_day_inc_per_sec = 1000 };
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
    var cl: WorldClock = .{ .hours = 8.0, .day = 1, .time_of_day_inc_per_sec = 1000 };
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
    var dir: Director = .{ .clock = .{ .hours = 23.0, .day = 1, .time_of_day_inc_per_sec = 1000 }, .horde_cd = 0 };
    _ = w.spawnPlayer(0, 70, 0, 0);
    const r = dir.tick(&w, 0.1);
    try std.testing.expect(r.spawned >= 1);
    try std.testing.expect(dir.total_spawned >= 1);
}

test "starter population fills toward the cap once, batched" {
    // GAP "population is still thin": a fresh world stays near-empty until
    // the first night drip (the day drip is 1 scout per 120 s); the starter
    // fill (initial_population_frac of the alive cap) populates near players
    // once at boot, batched, and never re-fires after the target is reached.
    var w: ecs_world.World = .{};
    defer w.deinit();
    w.director.max_alive = 64;
    // Daytime: the night horde drip is gated out, so only the starter fill
    // can populate before dusk.
    w.director.clock = .{ .day = 1, .hours = 12.0 };
    _ = w.spawnPlayer(0, 70, 0, 0);

    // Step until the fill completes (batched at 4/tick -> ~4 ticks to the
    // 16 target), then verify it landed within the target and never re-fires.
    var ticks: u32 = 0;
    while (ticks < 200 and !w.director.initial_population_done) : (ticks += 1) _ = w.director.tick(&w, 0.05);
    try std.testing.expect(w.director.initial_population_done);
    try std.testing.expect(w.countKind(.zombie) > 0);
    // Never overshoots the target (0.25 x 64 = 16).
    const target: u32 = @trunc(64.0 * w.rules.director.initial_population_frac);
    try std.testing.expect(w.countKind(.zombie) <= target);
    // The fill does not re-fire: daytime has no horde drip, so the count
    // stays put once the target is reached.
    const after_fill = w.countKind(.zombie);
    for (0..120) |_| _ = w.director.tick(&w, 0.05);
    try std.testing.expectEqual(after_fill, w.countKind(.zombie));
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
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), dir.zombieSpeedScale(&director_defaults), 0.001);
    dir.clock.hours = 23.0; // night
    try std.testing.expectApproxEqAbs(@as(f32, 1.4), dir.zombieSpeedScale(&director_defaults), 0.001);
    dir.bloodmoon_active = true;
    try std.testing.expectApproxEqAbs(@as(f32, 1.7), dir.zombieSpeedScale(&director_defaults), 0.001);
    dir.bloodmoon_active = false;
    dir.enemy_difficulty = 1; // feral overrides day
    dir.clock.hours = 12.0;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), dir.zombieSpeedScale(&director_defaults), 0.001);
}

test "director spawns daytime animals up to cap" {
    var w: ecs_world.World = .{};
    // Noon, animal cap 3, no zombie horde interference (day).
    var dir: Director = .{
        .clock = .{ .hours = 12.0, .day = 1, .time_of_day_inc_per_sec = 1000 },
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
        .clock = .{ .hours = 12.0, .day = 1, .time_of_day_inc_per_sec = 1000 },
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
test "animals and heat keep ticking when the zombie cap is full" {
    var w: ecs_world.World = .{};
    var dir: Director = .{
        .clock = .{ .hours = 12.0, .day = 1, .time_of_day_inc_per_sec = 1000 },
        .max_alive = 2,
        .max_alive_animals = 3,
        .scouts_cd = 999,
    };
    _ = w.spawnPlayer(0, 70, 0, 0);
    _ = w.spawnZombie(10, 70, 0, 40);
    _ = w.spawnZombie(12, 70, 0, 40);
    try std.testing.expectEqual(@as(u32, 2), w.countKind(.zombie));
    dir.notifyActivity(0, 0, 10, 720);
    const heat_before = dir.heat[0].activity;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        dir.animals_cd = 0;
        _ = dir.tick(&w, 0.1);
    }
    try std.testing.expect(dir.heat[0].activity < heat_before);
    try std.testing.expect(w.countKind(.animal) >= 1);
    try std.testing.expectEqual(@as(u32, 2), w.countKind(.zombie));
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
        .clock = .{ .hours = 23.0, .day = 1, .time_of_day_inc_per_sec = 1000 },
        .horde_cd = 0,
        // hpScale neutral tier (difficulty_hp_2 = 1.0): the assert below
        // checks the resolver's class stats unscaled, not the difficulty
        // hp ladder (which is covered by its own test).
        .difficulty = 2,
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

test "blood moon walks the stage spawn groups across the night" {
    // Stock party spawner (SetupGroup/Tick): row 0 spawns `num` zombies, then
    // the walk advances to row 1; a null row ends the walk (get_IsDone).
    const Hooks = struct {
        fn stageGroupAt(_: ?*anyopaque, spawner: []const u8, stage: i32, index: u32) ?StageGroup {
            if (!std.mem.eql(u8, spawner, Director.bloodmoon_spawner)) return null;
            if (stage != 61) return null;
            if (index == 0) return .{ .group = "ZombiesNight", .num = 2, .max_alive = 8, .interval = 1, .duration = 0 };
            if (index == 1) return .{ .group = "ZombiesNight", .num = 3, .max_alive = 8, .interval = 1, .duration = 0 };
            return null;
        }
        fn pick(_: ?*anyopaque, _: []const u8, _: u32) ?[]const u8 {
            return null; // class_table rotation fallback
        }
    };
    var w: ecs_world.World = .{};
    w.rules.director.initial_population_frac = 0;
    _ = w.spawnPlayer(0, 70, 0, 0);
    var dir: Director = .{
        .clock = .{ .hours = 23.0, .day = 7, .time_of_day_inc_per_sec = 1000 },
        .bloodmoon_enemy_count = 8,
        .bloodmoon_cd = 0,
        .horde_cd = 999,
        .party_stage = 61,
        // The Game pushes the weighted party level next to the high-water
        // mark; the freeze must take the weighted one (InitParty IL_0006).
        .party_stage_weighted = 61,
        .group_pick_fn = &Hooks.pick,
        .stage_group_at_ctx = undefined,
        .stage_group_at_fn = &Hooks.stageGroupAt,
    };
    // Dusk freeze starts the walk at row 0.
    _ = dir.tick(&w, 0.1);
    try std.testing.expectEqual(@as(i32, 61), dir.bm_stage_frozen);
    try std.testing.expectEqual(@as(u32, 0), dir.bm_group_index);
    // Drive waves until row 0 (num=2) is done: the walk must advance to row 1
    // and keep spawning its num=3.
    var ticks: u32 = 0;
    while (dir.bm_group_index == 0 and ticks < 40) : (ticks += 1) {
        dir.bloodmoon_cd = 0;
        _ = dir.tick(&w, 0.1);
    }
    try std.testing.expectEqual(@as(u32, 1), dir.bm_group_index);
    // The advancing tick already spawns row 1's first wave (stock advances
    // and spawns in the same spawner tick), so the counter is mid-row, not
    // zero; what matters is the walk keeps spawning row 1 to its num=3.
    try std.testing.expect(dir.bm_spawned_in_group >= 1);
    ticks = 0;
    while (dir.bm_spawned_in_group < 3 and ticks < 60) : (ticks += 1) {
        dir.bloodmoon_cd = 0;
        _ = dir.tick(&w, 0.1);
    }
    try std.testing.expectEqual(@as(u32, 3), dir.bm_spawned_in_group);
    // Past the last row the walk is done; the night stays populated via the
    // legacy first-row burst (no indexed lookup here means the walk ends).
    try std.testing.expect(dir.stageGroupAt(2) == null);
}

test "scout spawner tier follows the stock gamestage thresholds" { // SpawnScouts (asm.il ~415972): >=45 Scouts2, >=85 ScoutsFeral, >=125 radiated.
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
        .clock = .{ .hours = 12.0, .day = 1, .time_of_day_inc_per_sec = 1000 },
        .party_stage = 90,
        .spawner_group_fn = &Hooks.spawnerGroup,
        .group_pick_fn = &Hooks.pick,
    };
    const r = dir.tick(&w, 0.1);
    try std.testing.expect(r.spawned >= 1);
    try std.testing.expectEqualStrings("ScoutsFeral", Hooks.asked[0..Hooks.asked_len]);
}

test "daytime scout wave size comes from the spawner TotalPerWave" {
    // The count was a hardcoded 1 while spawning.xml sizes each tier
    // (Scouts1 1, Scouts2 2, ScoutsFeral/Radiated "1,2"). With a table wired
    // the tier's own value drives the wave; without one the caller's fallback
    // still applies.
    const Hooks = struct {
        fn spawnerGroup(_: ?*anyopaque, _: []const u8) ?[]const u8 {
            return "ZombieScoutsFeral";
        }
        fn pick(_: ?*anyopaque, group: []const u8, _: u32) ?[]const u8 {
            if (std.mem.eql(u8, group, "ZombieScoutsFeral")) return "zombieJoe";
            return null;
        }
        fn waveThree(_: ?*anyopaque, _: []const u8) WaveRange {
            return .{ .min = 3, .max = 3 };
        }
        fn waveUnset(_: ?*anyopaque, _: []const u8) WaveRange {
            return .{};
        }
        // The ScoutsFeral / ScoutsRadiated shape: TotalPerWave "1,2".
        fn waveOneToTwo(_: ?*anyopaque, _: []const u8) WaveRange {
            return .{ .min = 1, .max = 2 };
        }
    };
    var w: ecs_world.World = .{};
    _ = w.spawnPlayer(0, 70, 0, 0);
    var dir: Director = .{
        .clock = .{ .hours = 12.0, .day = 1, .time_of_day_inc_per_sec = 1000 },
        .party_stage = 90,
        .spawner_group_fn = &Hooks.spawnerGroup,
        .group_pick_fn = &Hooks.pick,
        .spawner_wave_fn = &Hooks.waveThree,
    };
    try std.testing.expectEqual(@as(u32, 3), dir.scoutWaveSize(1));

    // An absent property keeps the caller's fallback rather than spawning 0.
    dir.spawner_wave_fn = &Hooks.waveUnset;
    try std.testing.expectEqual(@as(u32, 1), dir.scoutWaveSize(1));

    // No table wired at all (offline tests) also keeps the fallback.
    dir.spawner_wave_fn = null;
    try std.testing.expectEqual(@as(u32, 2), dir.scoutWaveSize(2));

    // A "1,2" range rolls inside the range, never below min or above max, and
    // both ends are reachable across the spawn counter.
    dir.spawner_wave_fn = &Hooks.waveOneToTwo;
    var saw_one = false;
    var saw_two = false;
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        dir.total_spawned = i;
        const n = dir.scoutWaveSize(9);
        try std.testing.expect(n >= 1 and n <= 2);
        if (n == 1) saw_one = true;
        if (n == 2) saw_two = true;
    }
    try std.testing.expect(saw_one and saw_two);

    // Deterministic: the same counter yields the same roll.
    dir.total_spawned = 5;
    const first = dir.scoutWaveSize(9);
    dir.total_spawned = 5;
    try std.testing.expectEqual(first, dir.scoutWaveSize(9));
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
    w.rules.director.initial_population_frac = 0; // isolate the wave branch from the starter fill
    _ = w.spawnPlayer(0, 70, 0, 0);
    // Blood moon night with a generous BloodMoonEnemyCount; maxAlive=2 wins.
    var dir: Director = .{
        .clock = .{ .hours = 23.0, .day = 7, .time_of_day_inc_per_sec = 1000 },
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
    w.rules.director.initial_population_frac = 0; // isolate the wave count from the starter fill
    _ = w.spawnPlayer(0, 70, 0, 0);
    var dir: Director = .{
        .clock = .{ .hours = 23.0, .day = 7, .time_of_day_inc_per_sec = 1000 },
        .bloodmoon_enemy_count = 8,
        .horde_cd = 999,
    };
    const r = dir.tick(&w, 0.1);
    try std.testing.expect(dir.bloodmoon_active);
    try std.testing.expectEqual(@as(u32, 4), r.spawned); // BloodMoonEnemyCount / 2
}

test "horde bonus loot scales every Nth spawn and marks the row" {
    // Stock SpawnZombie (IL_00CD-0102): bonusLootSpawnCount++ per non-vulture
    // spawn, reset + lootDropProb *= LootBonusScale at bonusLootEvery; the
    // death path then reads the stored probability verbatim. Seeded at half
    // cadence by InitParty (IL_0072-0080).
    var w: ecs_world.World = .{};
    _ = w.spawnPlayer(0, 70, 0, 0);
    var dir: Director = .{};
    dir.setBloodMoonBonus(4, 25);
    try std.testing.expectEqual(@as(u32, 2), dir.bm_bonus_count); // seeded at every/2
    var bonus_n: u32 = 0;
    var i: u32 = 0;
    while (i < 2) : (i += 1) {
        const slot = dir.spawnOneZombieLoot(&w, 0, 70, 0, "", i, true, .bloodmoon) orelse return error.TestUnexpectedResult;
        if (w.class_id[slot].bonus_loot) {
            bonus_n += 1;
            try std.testing.expectEqual(@as(f32, 25.0), w.class_id[slot].drop_prob);
        }
    }
    try std.testing.expectEqual(@as(u32, 1), bonus_n); // 2nd spawn after the half seed
    try std.testing.expectEqual(@as(u32, 0), dir.bm_bonus_count); // reset on the award
    // Wandering kind runs its own counter (every 3rd x15, stock XML values).
    var wbonus: u32 = 0;
    i = 0;
    while (i < 3) : (i += 1) {
        const slot = dir.spawnOneZombieLoot(&w, 0, 70, 0, "", 100 + i, true, .wandering) orelse return error.TestUnexpectedResult;
        if (w.class_id[slot].bonus_loot) {
            wbonus += 1;
            try std.testing.expectEqual(@as(f32, 15.0), w.class_id[slot].drop_prob);
        }
    }
    try std.testing.expectEqual(@as(u32, 1), wbonus);
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
    // Pin the clock rate so one 50 ms tick advances a whole world tick past the
    // "due" schedule it forces below (the stock 6 ticks/s needs ~4 ticks).
    var d: Director = .{ .clock = .{ .time_of_day_inc_per_sec = 1000 } };
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
    try std.testing.expectEqual(@as(u32, wandering_horde_size), horde);
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
    var d: Director = .{ .clock = .{ .day = 2, .hours = 10.0, .time_of_day_inc_per_sec = 1000 } };
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
    try std.testing.expectEqual(@as(u32, 3), horde); // config size, not 6
    const hs = horde_slot orelse return error.TestUnexpectedResult;
    const dist = @sqrt(w.transform[hs].x * w.transform[hs].x + w.transform[hs].z * w.transform[hs].z);
    try std.testing.expect(dist > 30.0 and dist < 50.0); // config 40 m, not 92
}

test "the blood-moon freeze takes the weighted party level, not the high-water mark" {
    // AIDirectorBloodMoonParty::InitParty IL_0006 resolves the ladder from
    // partySpawner.CalcPartyLevel() over the party members, so a two-player
    // party at stage 40/80 freezes the weighted level (40 + 80*0.5 = 80 with
    // the stock DiminishingReturns of 0.5 ... the exact value comes from
    // GameStageDefinition::CalcPartyLevel), never the 80 max alone.
    var w: ecs_world.World = .{};
    defer w.deinit();
    w.rules.director.initial_population_frac = 0;
    _ = w.spawnPlayer(0, 70, 0, 0).?;
    var d: Director = .{
        .clock = .{ .hours = 23.0, .day = 7 },
        .horde_cd = 999,
        .party_stage = 80,
        .party_stage_weighted = 52,
    };
    _ = d.tick(&w, 0.1);
    try std.testing.expectEqual(@as(i32, 52), d.bm_stage_frozen);
    // With nothing pushed (offline tables, tests) the high-water mark stands.
    var d2: Director = .{
        .clock = .{ .hours = 23.0, .day = 7 },
        .horde_cd = 999,
        .party_stage = 80,
    };
    _ = d2.tick(&w, 0.1);
    try std.testing.expectEqual(@as(i32, 80), d2.bm_stage_frozen);
}

test "wandering horde takes its size and group from the WanderingHorde ladder" {
    // AIWanderingHordeSpawner::.ctor IL_0066 builds its party spawner with
    // mod = 50, and UpdateSpawn IL_006D spawns the resolved stage row's group
    // `num` times. The ladder index is the weighted party level wrapped at 50,
    // so a stage of 71 resolves row 21, and the pack is that row's size/group
    // rather than the rules fallback.
    const Hooks = struct {
        var asked_stage: i32 = -1;
        fn stageGroup(_: ?*anyopaque, spawner: []const u8, stage: i32) ?StageGroup {
            if (!std.mem.eql(u8, spawner, Director.wandering_spawner)) return null;
            asked_stage = stage;
            if (stage != 21) return null;
            return .{ .group = "wanderingHordeStageGS21", .num = 7, .max_alive = 30, .interval = 2, .duration = 9 };
        }
        fn around(_: ?*anyopaque, _: f32, _: f32, radius: f32) i32 {
            // The wired hook is asked with the stock CalcGameStageAround radius.
            if (radius != Director.gamestage_around_radius) return 0;
            return 71;
        }
        fn pick(_: ?*anyopaque, _: []const u8, _: u32) ?[]const u8 {
            return null; // class_table rotation fallback
        }
    };
    var w: ecs_world.World = .{};
    defer w.deinit();
    _ = w.spawnPlayer(0, 70, 0, 0).?;
    var d: Director = .{
        .clock = .{ .day = 3, .hours = 12.0, .time_of_day_inc_per_sec = 1000 },
        .stage_group_ctx = undefined,
        .stage_group_fn = &Hooks.stageGroup,
        .stage_around_ctx = undefined,
        .stage_around_fn = &Hooks.around,
        .group_pick_ctx = undefined,
        .group_pick_fn = &Hooks.pick,
    };
    d.wandering_next = d.clock.worldTimeBits() + 1; // due
    _ = d.tick(&w, 0.05);
    try std.testing.expectEqual(@as(i32, 21), Hooks.asked_stage); // 71 % 50
    var horde: u32 = 0;
    var s: ecs_world.Slot = 0;
    while (s < ecs_world.max_entities) : (s += 1) {
        if (w.alive[s] and w.zombie_ai[s].is_horde) horde += 1;
    }
    try std.testing.expectEqual(@as(u32, 7), horde); // the row's num, not the rule's 6

    // A stage that wraps to 0 (party stage 50, 100, ...) has no ladder row at
    // or below it, so the pack falls back to the rules size rather than
    // vanishing.
    var d2: Director = .{
        .clock = .{ .day = 3, .hours = 12.0 },
        .party_stage = 50,
        .stage_group_ctx = undefined,
        .stage_group_fn = &Hooks.stageGroup,
    };
    try std.testing.expectEqual(@as(i32, 0), @mod(d2.party_stage, Director.wandering_stage_mod));
    try std.testing.expect(d2.wanderingHordeRow(0, 0) == null);
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
    // Stock's cSpawnChance (20%) is a roll; pin it to 1 so this test is about
    // the spawn mechanics. The chance split has its own test below.
    w.rules.director.heat_spawn_chance = 1;
    // A forge (6 per event, 720-tick duration) feeds every tick: 30 ticks give
    // activity ~180, well past the 25 threshold.
    var t: u32 = 0;
    while (t < 30) : (t += 1) {
        d.notifyActivity(0, 0, 6, 720);
        _ = d.tick(&w, 0.05);
    }
    try std.testing.expect(d.heat_n >= 1);
    try std.testing.expect(d.heat[0].activity >= 25);
    // The 5 s CheckToSpawn fires: scouts spawn, the region resets and takes the
    // long cooldown (stock SetLongDelay 1320 s, not the 240 the reset stamped).
    var warm: u32 = 0;
    while (warm < 110) : (warm += 1) _ = d.tick(&w, 0.05);
    var scouts: u32 = 0;
    var s: ecs_world.Slot = 0;
    while (s < ecs_world.max_entities) : (s += 1) {
        if (!w.alive[s] or !w.zombie_ai[s].is_horde) continue;
        scouts += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), scouts); // rules.director.heat_scout_count default
    // Region was reset (activity 0) and is on the long cooldown. Region key of
    // (0,0): floor(0/80)=0 on both axes, packed = 0.
    var found = false;
    for (d.heat[0..d.heat_n]) |*r| {
        if (r.key == 0) {
            found = true;
            try std.testing.expect(r.activity == 0);
            // Long branch (a spawn happened), minus the ~5.5 s of ticks this
            // test runs past the check; the exact table is asserted in the
            // chance-split test below.
            try std.testing.expect(r.cooldown > w.rules.director.heat_cooldown_seconds);
            try std.testing.expect(r.cooldown <= w.rules.director.heat_long_cooldown_seconds);
        }
    }
    try std.testing.expect(found);
}

test "heat map: cSpawnChance picks the short or long cooldown table" {
    // Stock CheckToSpawn (IL=46, aidirector.md verified literals): the reset
    // stamps 240 s, then a 20% roll either spawns (SetLongDelay 1320 s plus
    // StartCooldownOnNeighbors(true) = 720 s on the eight neighbours) or not
    // (the region keeps 240 and the neighbours get 180). zdtd spawned on every
    // crossing and modelled the long delay as a feral 2x cooldown, so scout
    // parties came about five times too often and the region re-armed after
    // 240 s instead of 22 minutes.
    var w0: ecs_world.World = .{};
    defer w0.deinit();
    _ = w0.spawnPlayer(0, 70, 0, 0).?;
    // District (1,0) is one 80-block region east of district (0,0).
    const neighbour_key = Director.heatRegionKey(80, 0);

    // Roll fails: no scouts, region 240, neighbour 180.
    var d0: Director = .{ .heat_check_cd = 0 };
    w0.rules.director.heat_spawn_chance = 0;
    d0.notifyActivity(0, 0, 30, 720);
    d0.notifyActivity(80, 0, 30, 720);
    _ = d0.tick(&w0, 0.05);
    var zombies: u32 = 0;
    var s: ecs_world.Slot = 0;
    while (s < ecs_world.max_entities) : (s += 1) {
        if (w0.alive[s] and w0.zombie_ai[s].is_horde) zombies += 1;
    }
    try std.testing.expectEqual(@as(u32, 0), zombies);
    try std.testing.expectEqual(@as(f32, 240), cooldownOf(&d0, 0));
    try std.testing.expectEqual(@as(f32, 180), cooldownOf(&d0, neighbour_key));

    // Roll lands: the same crossing spawns and takes the long table.
    var w1: ecs_world.World = .{};
    defer w1.deinit();
    _ = w1.spawnPlayer(0, 70, 0, 0).?;
    var d1: Director = .{ .heat_check_cd = 0 };
    w1.rules.director.heat_spawn_chance = 1;
    d1.notifyActivity(0, 0, 30, 720);
    d1.notifyActivity(80, 0, 30, 720);
    _ = d1.tick(&w1, 0.05);
    zombies = 0;
    s = 0;
    while (s < ecs_world.max_entities) : (s += 1) {
        if (w1.alive[s] and w1.zombie_ai[s].is_horde) zombies += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), zombies);
    try std.testing.expectEqual(@as(f32, 1320), cooldownOf(&d1, 0));
    // The neighbour's own check is skipped because the long cooldown is already
    // stamped, so it holds exactly the neighbour-long value.
    try std.testing.expectEqual(@as(f32, 720), cooldownOf(&d1, neighbour_key));
}

/// Cooldown of the heat region with `key`, or -1 when absent (test helper).
fn cooldownOf(d: *const Director, key: i64) f32 {
    for (d.heat[0..d.heat_n]) |r| {
        if (r.key == key) return r.cooldown;
    }
    return -1;
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
    var cl: WorldClock = .{ .hours = 12.0, .day = 1, .time_of_day_inc_per_sec = 1000 };
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

test "blood moon row duration converts to world time units" {
    // AIDirectorGameStagePartySpawner::SetupGroup IL_0044-0062:
    // nextStageTime = world.worldTime + duration * 1000 (1000 units per game
    // hour, 24000 per day). The old *20 armed every row deadline 50x early.
    const Ctx = struct {
        fn at(_: ?*anyopaque, spawner: []const u8, stage: i32, index: u32) ?StageGroup {
            if (!std.mem.eql(u8, spawner, Director.bloodmoon_spawner)) return null;
            if (stage != 61) return null;
            if (index == 0) return .{ .group = "ZombiesNight", .num = 1, .max_alive = 8, .interval = 5, .duration = 1 };
            if (index == 1) return .{ .group = "ZombiesNight", .num = 1, .max_alive = 8, .interval = 5, .duration = 0 };
            return null;
        }
    };
    var w: ecs_world.World = .{};
    defer w.deinit();
    var d: Director = .{ .clock = .{ .day = 7, .hours = 23.0 } };
    d.bm_stage_frozen = 61;
    d.stage_group_at_fn = &Ctx.at;
    d.setupBmGroup(&w);
    try std.testing.expectEqual(d.clock.worldTimeBits() + world_time_units_per_hour, d.bm_group_deadline);
    // duration 0 leaves the row ungated (stock writes 0).
    d.bm_group_index = 1;
    d.setupBmGroup(&w);
    try std.testing.expectEqual(@as(u64, 0), d.bm_group_deadline);
}

test "blood moon kills the horde when the party is wiped" {
    // Stock KillPartyZombies (party Tick, aidirector.md): when the horde's
    // party empties (all players dead), the horde zombies die instead of
    // roaming until dawn.
    var w: ecs_world.World = .{};
    defer w.deinit();
    var d: Director = .{ .clock = .{ .day = 7, .hours = 23.0 }, .bloodmoon_enemy_count = 8, .horde_cd = 999 };
    _ = w.spawnPlayer(0, 70, 0, 0);
    for (0..80) |_| _ = d.tick(&w, 0.05);
    var horde_n: u32 = 0;
    for (0..ecs_world.max_entities) |s| {
        if (w.alive[s] and w.zombie_ai[s].is_horde) horde_n += 1;
    }
    try std.testing.expect(horde_n >= 1);
    // Wipe the party: the horde must be destroyed on the next tick.
    for (0..ecs_world.max_entities) |s| {
        if (w.alive[s] and w.mask[s].player) w.destroy(@intCast(s));
    }
    for (0..5) |_| _ = d.tick(&w, 0.05);
    var horde_left: u32 = 0;
    for (0..ecs_world.max_entities) |s| {
        if (w.alive[s] and w.zombie_ai[s].is_horde) horde_left += 1;
    }
    try std.testing.expectEqual(@as(u32, 0), horde_left);
}

test "night spawns ground-snap through the world ground hook" {
    // Spawn placement: the drip used the player's centre Y (~1.7 m up), so
    // zombies materialised embedded in hillsides or floating on slopes. With
    // the ground hook set, the spawn Y is the surface at (x,z).
    var w: ecs_world.World = .{};
    defer w.deinit();
    w.ground_ctx = null;
    w.ground_fn = struct {
        fn f(_: ?*anyopaque, _: i32, _: i32) f32 {
            return 50.0;
        }
    }.f;
    _ = w.spawnPlayer(0, 70, 0, 0);
    var dir: Director = .{
        .clock = .{ .hours = 23.0, .day = 7, .time_of_day_inc_per_sec = 1000 },
        .bloodmoon_enemy_count = 8,
        .horde_cd = 0,
    };
    // A night non-blood-moon day: the drip spawns from spawnNearPlayers.
    dir.clock.day = 3;
    dir.bloodmoon_active = false;
    const r = dir.tick(&w, 0.1);
    try std.testing.expect(r.spawned > 0);
    var saw_ground = false;
    var s: ecs_world.Slot = 0;
    while (s < ecs_world.max_entities) : (s += 1) {
        if (!w.alive[s] or !w.mask[s].transform or w.kind[s] != .zombie) continue;
        if (w.transform[s].y == 50.0) saw_ground = true;
    }
    try std.testing.expect(saw_ground);
}

test "blood-moon HP floor applies only to unresolved fallback classes" {
    // Stock has no flat blood-moon HP multiplier: the gamestage ladder class
    // carries its own stats (GAP "Blood-moon zombie strength"). The rules
    // floor (bloodmoon_hp_mult, default 1.5) applies only when no class
    // resolved (offline/builtin fallback through the class_table rotation).
    var w: ecs_world.World = .{};
    var dir: Director = .{ .bloodmoon_active = true, .difficulty = 2 }; // hpScale 1.0
    var ci: usize = 0;
    while (ci < w.class_table.len) : (ci += 1) {
        const ct = w.class_table[ci];
        if (ct.kind == .zombie and ct.hash != 0 and ct.max_hp > 0) break;
    }
    const cls = w.class_table[ci];
    const Pick = struct {
        fn pick(ctx: ?*anyopaque, _: []const u8, _: u32) ?[]const u8 {
            const c: *const ecs_world.EntityClass = @ptrCast(@alignCast(ctx.?));
            return c.name;
        }
    };
    dir.group_pick_ctx = @ptrCast(@constCast(&cls));
    dir.group_pick_fn = &Pick.pick;
    // Resolved from the group: the class's own HP, no 1.5x.
    const slot = dir.spawnOneZombie(&w, 0, 70, 0, "HordeGS1", 42, true) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f32, cls.max_hp), w.health[slot].hp);

    // Unresolved (no group): the class_table rotation keeps the 1.5x floor.
    const seed: u32 = 7;
    const rotation = [_]usize{ 1, 8, 9, 10, 11 };
    const fct = w.class_table[rotation[seed % rotation.len]];
    const f2 = dir.spawnOneZombie(&w, 0, 70, 5, "", seed, false) orelse return error.TestUnexpectedResult;
    if (fct.hash != 0 and fct.kind == .zombie) {
        try std.testing.expectApproxEqAbs(@as(f32, fct.max_hp * 1.5), w.health[f2].hp, 0.01);
    }
}

test "ambient rule budget caps the drip and releases on destroy" {
    // The per-rule budget (spawning.xml maxcount/respawndelay) gates the
    // ambient drip: a rule with maxcount 2 admits two spawns, blocks the
    // third until one dies (releaseRule) and re-arms after respawn_days.
    var w: ecs_world.World = .{};
    defer w.deinit();
    // The budget lives on the World's own director so World.destroy's release
    // finds it (the game drives w.director.tick the same way).
    w.director.clock = .{ .day = 1, .hours = 23.0 };
    w.director.max_alive = 64;
    // A fixed rule resolver: index 3, maxcount 2, respawn 1 day.
    const Ctx = struct {
        fn f(_: ?*anyopaque, _: f32, _: f32, kind: Director.SpawnKind) RuleBudget {
            if (kind != .night) return .{};
            return .{ .index = 3, .maxcount = 2, .respawn_days = 1.0 };
        }
    };
    var ctx = Ctx{};
    w.director.rule_budget_ctx = &ctx;
    w.director.rule_budget_fn = &Ctx.f;
    _ = w.spawnPlayer(0, 70, 0, 0);

    // First drip tick: 2 spawns admitted (maxcount 2).
    var ticks: u32 = 0;
    while (ticks < 40 and w.countKind(.zombie) < 2) : (ticks += 1) _ = w.director.tick(&w, 0.05);
    try std.testing.expectEqual(@as(u32, 2), w.countKind(.zombie));
    try std.testing.expectEqual(@as(u8, 2), w.director.rule_budgets[3].count);

    // The delay is armed: further drip ticks cannot add to the rule.
    const before = w.countKind(.zombie);
    for (0..60) |_| _ = w.director.tick(&w, 0.05);
    try std.testing.expectEqual(before, w.countKind(.zombie));

    // Kill attrition: destroy one zombie -> the rule count drops and a new
    // spawn is admitted (the delay was armed, so the fresh cycle starts).
    var found: ?ecs_world.Slot = null;
    var si: ecs_world.Slot = 0;
    while (si < ecs_world.max_entities) : (si += 1) {
        if (w.alive[si] and w.mask[si].zombie_ai and !w.mask[si].player) {
            found = si;
            break;
        }
    }
    try std.testing.expect(found != null);
    w.destroy(found.?);
    try std.testing.expectEqual(@as(u8, 1), w.director.rule_budgets[3].count);
    // The drip re-runs when horde_cd (45 s) elapses (900 ticks at 0.05); the
    // budget admits the slot freed by the kill within the same cycle.
    for (0..950) |_| _ = w.director.tick(&w, 0.05);
    try std.testing.expect(w.countKind(.zombie) >= 2);
}

test "rule budgets cover the full parsed table, not just the first 64" {
    // A modlet patch can add spawning.xml rules up to the parsed bound
    // (512); an index past the old 64-slot array must be budgeted, not
    // silently treated as unbudgeted. Index 511 with maxcount 1 admits one
    // consume and denies the second until release.
    var w: ecs_world.World = .{};
    defer w.deinit();
    const b: RuleBudget = .{ .index = 511, .maxcount = 1, .respawn_days = 1.0 };
    try std.testing.expect(w.director.budgetAllows(b, &w));
    w.director.budgetConsume(b, &w);
    try std.testing.expectEqual(@as(u8, 1), w.director.rule_budgets[511].count);
    try std.testing.expect(!w.director.budgetAllows(b, &w));
    w.director.releaseRule(511);
    try std.testing.expect(w.director.budgetAllows(b, &w));
}

test "difficulty damage scale uses the comptime XML ladder" {
    // The six difficulty presets decode from the embedded sandbox_presets
    // XML (assets/sandbox_presets.zig) into `[rules.difficulty]
    // incoming_damage_0..5`; `damageScale` mirrors stock
    // ItemActionAttack.difficultyModifier (IL=44): only mixed
    // server/client matchups scale.
    var w: ecs_world.World = .{};
    defer w.deinit();
    const d = &w.director;
    const r = &w.rules.difficulty;
    d.difficulty = 4; // True Survivalist
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), d.damageScale(false, true, r), 1e-4); // AI -> player x2.0
    d.difficulty = 0; // Scavenger
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), d.damageScale(false, true, r), 1e-4);
    d.difficulty = 2; // Nomad (empty code = defaults)
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), d.damageScale(false, true, r), 1e-4);
    d.difficulty = 5; // Insane
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), d.damageScale(false, true, r), 1e-4);
    // EntityIncomingDamage never appears in a difficulty code: 1.0 on every
    // tier, so the player -> zombie leg is unchanged.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), d.damageScale(true, false, r), 1e-4);
    // PvP and AI-vs-AI pairs never scale (stock difficultyModifier).
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), d.damageScale(true, true, r), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), d.damageScale(false, false, r), 1e-4);
    // A SandboxCode IncomingDamage override (custom code) wins over the
    // ladder regardless of the difficulty index (stock single static).
    d.sandbox_incoming = 1.7;
    d.difficulty = 0; // Scavenger ladder would be 0.5
    try std.testing.expectApproxEqAbs(@as(f32, 1.7), d.damageScale(false, true, r), 1e-4);
    d.sandbox_incoming = 0; // unset -> ladder back
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), d.damageScale(false, true, r), 1e-4);
}

test "a spawn whose ground forbids mobs is refused" {
    // Stock `Chunk::CanMobsSpawnAtPos` IL_0043/IL_004E: the block under the
    // spawn cell must be CanMobsSpawnOn and movement-solid, so a player-built
    // floor hosts no spawns. The director asks through a hook; with no hook
    // every position stays allowed (offline/builtin world), which the second
    // half pins.
    var w: ecs_world.World = .{};
    defer w.deinit();
    _ = w.spawnPlayer(0, 70, 0, 0).?;
    var d: Director = .{ .clock = .{ .time_of_day_inc_per_sec = 1000 } };
    const Gate = struct {
        var allow = false;
        var seen_y: i32 = 0;
        fn ok(_: ?*anyopaque, _: i32, y: i32, _: i32) bool {
            seen_y = y;
            return allow;
        }
    };
    d.mob_spawn_ok_ctx = null;
    d.mob_spawn_ok_fn = &Gate.ok;

    Gate.allow = false;
    try std.testing.expect(d.spawnOneZombieLoot(&w, 10.0, 70.0, 10.0, "", 7, false, .none) == null);
    // The gate sees the GROUND cell: the caller's y is the stand cell.
    try std.testing.expectEqual(@as(i32, 69), Gate.seen_y);

    Gate.allow = true;
    try std.testing.expect(d.spawnOneZombieLoot(&w, 10.0, 70.0, 10.0, "", 7, false, .none) != null);

    // No hook: the same position spawns (pre-parse behaviour).
    var d2: Director = .{ .clock = .{ .time_of_day_inc_per_sec = 1000 } };
    try std.testing.expect(d2.spawnOneZombieLoot(&w, 12.0, 70.0, 12.0, "", 9, false, .none) != null);
}
