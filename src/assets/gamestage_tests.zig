//! Gamestage catalog tests: stages, spawns, counts.
//!
//! Split out of assets/gamestages.zig (same tests, moved verbatim).

const std = @import("std");
const gamestages = @import("gamestages.zig");
const parseCount = gamestages.parseCount;
const loadFromPath = gamestages.loadFromPath;
const loadFromSlice = gamestages.loadFromSlice;
const io_fs = @import("../util/io_fs.zig");
const Config = gamestages.Config;
const Group = gamestages.Group;
const SpawnGroup = gamestages.SpawnGroup;
const Spawner = gamestages.Spawner;
const Stage = gamestages.Stage;
const bornAtAfterDeath = gamestages.bornAtAfterDeath;
const cleanName = gamestages.cleanName;
const daysAlive = gamestages.daysAlive;
const lootStage = gamestages.lootStage;
const max_name_len = gamestages.max_name_len;
const partyLevel = gamestages.partyLevel;
const playerStage = gamestages.playerStage;
const ticks_per_day = gamestages.ticks_per_day;
const stock_paths = @import("../util/stock_paths.zig");
const stock_path = stock_paths.configFile("gamestages.xml");

test "cleanName covers the four stock shapes" {
    var buf: [max_name_len]u8 = undefined;
    try std.testing.expectEqualStrings("GroupGenericZombie", cleanName(&buf, "1GroupGenericZombie"));
    try std.testing.expectEqualStrings("GroupGenericZombie", cleanName(&buf, "S_-Group_Generic_Zombie"));
    try std.testing.expectEqualStrings("FooBar", cleanName(&buf, "S_Foo_Bar"));
    try std.testing.expectEqualStrings("zombieArlene", cleanName(&buf, "zombieArlene"));
    // Edge cases: empty, single digit, bare prefixes.
    try std.testing.expectEqualStrings("", cleanName(&buf, ""));
    try std.testing.expectEqualStrings("", cleanName(&buf, "7"));
    try std.testing.expectEqualStrings("", cleanName(&buf, "S_"));
    try std.testing.expectEqualStrings("", cleanName(&buf, "S_-"));
}

test "getStage picks the highest stage at or below n" {
    const spawns = [_]SpawnGroup{.{ .group = "g" }};
    const stages = [_]Stage{
        .{ .stage_num = 5, .spawns = &spawns },
        .{ .stage_num = 12, .spawns = &spawns },
        .{ .stage_num = 14, .spawns = &spawns },
        .{ .stage_num = 30, .spawns = &spawns },
    };
    const sp: Spawner = .{ .name = "S", .stages = &stages };
    // Below the first stage there is no stage at all (stock returns null).
    try std.testing.expect(sp.getStage(0) == null);
    try std.testing.expect(sp.getStage(4) == null);
    try std.testing.expectEqual(@as(i32, 5), sp.getStage(5).?.stage_num);
    try std.testing.expectEqual(@as(i32, 5), sp.getStage(11).?.stage_num);
    // The gamestages.xml header's worked example: GS 15 uses stage 14, GS 14 uses 12.
    try std.testing.expectEqual(@as(i32, 12), sp.getStage(13).?.stage_num);
    try std.testing.expectEqual(@as(i32, 14), sp.getStage(15).?.stage_num);
    try std.testing.expectEqual(@as(i32, 30), sp.getStage(std.math.maxInt(i32)).?.stage_num);
    const none: Spawner = .{ .name = "E" };
    try std.testing.expect(none.getStage(100) == null);
}

test "partyLevel matches the gamestages.xml worked example" {
    const cfg: Config = .{ .starting_weight = 1, .diminishing_returns = 0.5 };
    var stages = [_]i32{ 204, 30, 60, 91, 5, 1, 2, 80 };
    try std.testing.expectEqual(@as(i32, 279), partyLevel(cfg, &stages));
    // Single player is just their own stage; empty party is 0.
    var one = [_]i32{42};
    try std.testing.expectEqual(@as(i32, 42), partyLevel(cfg, &one));
    var nil = [_]i32{};
    try std.testing.expectEqual(@as(i32, 0), partyLevel(cfg, &nil));
    // Sorting is by value, not input order.
    var rev = [_]i32{ 1, 2, 5, 30, 60, 80, 91, 204 };
    try std.testing.expectEqual(@as(i32, 279), partyLevel(cfg, &rev));
}

test "playerStage matches the gamestages.xml worked examples" {
    const cfg: Config = .{ .difficulty_bonus = 1.2 };
    // Level 10, 4 days survived, difficultyBonus 1.2 → 16.8 → 16.
    try std.testing.expectEqual(@as(i32, 16), playerStage(cfg, .{ .level = 10, .days_alive = 4 }));
    // Level 10, 25 days, 2 deaths → daysAlive 21 capped to level 10 → 20*1.2 = 24.
    try std.testing.expectEqual(@as(i32, 24), playerStage(cfg, .{ .level = 10, .days_alive = 10 }));
    // Floor of 1 even at level 0 with a zero difficulty bonus.
    try std.testing.expectEqual(@as(i32, 1), playerStage(.{ .difficulty_bonus = 0 }, .{ .level = 0 }));
    // Max level does not overflow.
    const big = playerStage(cfg, .{ .level = std.math.maxInt(u16), .days_alive = std.math.maxInt(u16) });
    try std.testing.expect(big > 0);
}

test "daysAlive clamps to level and to zero" {
    try std.testing.expectEqual(@as(u16, 0), daysAlive(0, 0, 60));
    try std.testing.expectEqual(@as(u16, 4), daysAlive(4 * ticks_per_day + 1, 0, 60));
    // High cap is the player level.
    try std.testing.expectEqual(@as(u16, 10), daysAlive(25 * ticks_per_day, 0, 10));
    // bornAt in the future (clock rewound) reads as zero days, never wraps.
    try std.testing.expectEqual(@as(u16, 0), daysAlive(100, 5 * ticks_per_day, 60));
}

test "death pushes bornAt forward or snaps it to now" {
    const cfg: Config = .{ .days_alive_change_when_killed = 2 };
    // 10 days elapsed, 2-day penalty → bornAt advances by 2 days (8 days left).
    const born = bornAtAfterDeath(cfg, 10 * ticks_per_day, 0);
    try std.testing.expectEqual(@as(u64, 2 * ticks_per_day), born);
    try std.testing.expectEqual(@as(u16, 8), daysAlive(10 * ticks_per_day, born, 60));
    // Under the penalty window, bornAt snaps to now → zero days alive.
    const snapped = bornAtAfterDeath(cfg, ticks_per_day, 0);
    try std.testing.expectEqual(@as(u64, ticks_per_day), snapped);
    try std.testing.expectEqual(@as(u16, 0), daysAlive(ticks_per_day, snapped, 60));
    // Never underflows when bornAt is already ahead of the clock.
    try std.testing.expectEqual(@as(u64, 5), bornAtAfterDeath(cfg, 5, 9));
}

test "lootStage clamps biome_min/max" {
    // Unset clamps: level 5 → stage 5
    try std.testing.expectEqual(@as(i32, 5), lootStage(.{ .level = 5 }));
    // Min raises floor
    try std.testing.expectEqual(@as(i32, 10), lootStage(.{ .level = 5, .biome_min = 10 }));
    // Max caps ceiling
    try std.testing.expectEqual(@as(i32, 3), lootStage(.{ .level = 5, .biome_max = 3 }));
}

test "lootStage is level driven with clamps" {
    // No POI/biome/container terms: loot stage is just the level, min 1.
    try std.testing.expectEqual(@as(i32, 37), lootStage(.{ .level = 37 }));
    try std.testing.expectEqual(@as(i32, 1), lootStage(.{ .level = 0 }));
    // Container mod scales level; container bonus adds flat.
    try std.testing.expectEqual(@as(i32, 27), lootStage(.{ .level = 20, .container_mod = 0.2, .container_bonus = 3 }));
    // Biome min/max clamp before the global modifier.
    try std.testing.expectEqual(@as(i32, 30), lootStage(.{ .level = 5, .biome_min = 30 }));
    try std.testing.expectEqual(@as(i32, 12), lootStage(.{ .level = 90, .biome_max = 12 }));
    // Max level does not overflow.
    try std.testing.expect(lootStage(.{ .level = std.math.maxInt(u16) }) > 0);
}

test "parseCount handles thousands separators and junk" {
    try std.testing.expectEqual(@as(u16, 65535), parseCount("65,535", 1));
    try std.testing.expectEqual(@as(u16, 300), parseCount("300", 1));
    try std.testing.expectEqual(@as(u16, 65535), parseCount("999999", 1));
    try std.testing.expectEqual(@as(u16, 7), parseCount("nope", 7));
    try std.testing.expectEqual(@as(u16, 7), parseCount("", 7));
}

test "loadFromSlice honours IL spawn defaults, not the header comment" {
    const src =
        \\<gamestages>
        \\  <config difficultyBonus="1.2" diminishingReturns="0.25"/>
        \\  <group name="1GroupGenericZombie" spawner="SleeperGSList"/>
        \\  <spawner name="SleeperGSList">
        \\    <gamestage stage="7"><spawn group="ZombiesAll"/></gamestage>
        \\    <gamestage stage="1"><spawn group="ZombiesNight" num="300" maxAlive="8" duration="1" interval="60"/></gamestage>
        \\    <gamestage stage="3"/>
        \\  </spawner>
        \\</gamestages>
    ;
    var t = try loadFromSlice(std.testing.allocator, src);
    defer t.deinit();
    try std.testing.expectApproxEqAbs(@as(f32, 1.2), t.config.difficulty_bonus, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), t.config.diminishing_returns, 0.0001);
    try std.testing.expectEqual(@as(i64, 2), t.config.days_alive_change_when_killed);
    // Stage 3 carried no <spawn>, so AddStage drops it; the rest sort ascending.
    const sp = t.spawnerByName("SleeperGSList").?;
    try std.testing.expectEqual(@as(usize, 2), sp.stages.len);
    try std.testing.expectEqual(@as(i32, 1), sp.stages[0].stage_num);
    try std.testing.expectEqual(@as(i32, 7), sp.stages[1].stage_num);
    // Omitted attributes take the IL defaults num=1 maxAlive=1 interval=2 duration=0.
    const bare = sp.getStage(9).?.spawnGroup(0).?;
    try std.testing.expectEqualStrings("ZombiesAll", bare.group);
    try std.testing.expectEqual(@as(u16, 1), bare.num);
    try std.testing.expectEqual(@as(u16, 1), bare.max_alive);
    try std.testing.expectEqual(@as(u16, 2), bare.interval);
    try std.testing.expectEqual(@as(u16, 0), bare.duration);
    const full = sp.getStage(1).?.spawnGroup(0).?;
    try std.testing.expectEqual(@as(u16, 300), full.num);
    try std.testing.expectEqual(@as(u16, 8), full.max_alive);
    try std.testing.expectEqual(@as(u16, 60), full.interval);
    try std.testing.expectEqual(@as(u16, 1), full.duration);
    // Group resolution goes through CleanName on both sides.
    try std.testing.expect(t.groupSpawner("GroupGenericZombie") != null);
    try std.testing.expect(t.groupSpawner("1GroupGenericZombie") == null);
    try std.testing.expectEqualStrings("ZombiesNight", t.sleeperEntityGroup("S_-Group_Generic_Zombie", 1).?.group);
    try std.testing.expect(t.sleeperEntityGroup("GroupGenericZombie", 0) == null);
}

test "loadFromSlice survives malformed input" {
    var a = try loadFromSlice(std.testing.allocator, "");
    a.deinit();
    var b = try loadFromSlice(std.testing.allocator, "<gamestages><spawner name=\"x\"><gamestage stage=\"zz\">");
    defer b.deinit();
    try std.testing.expectEqual(@as(usize, 0), b.spawners.len);
    var c = try loadFromSlice(std.testing.allocator, "<group name=\"a\"/><spawn group=\"\"/>");
    defer c.deinit();
    try std.testing.expectEqual(@as(usize, 0), c.groups.len); // no spawner attribute
}

test "load stock gamestages when present" {
    if (!io_fs.fileExists(stock_path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, stock_path);
    defer t.deinit();
    try std.testing.expect(t.spawners.len > 100);
    try std.testing.expect(t.groups.len > 100);
    try std.testing.expectApproxEqAbs(@as(f32, 1.2), t.config.difficulty_bonus, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), t.config.diminishing_returns, 0.0001);
    try std.testing.expectEqual(@as(i64, 2), t.config.days_alive_change_when_killed);
    try std.testing.expectEqual(@as(i32, 12), t.config.loot_bonus_every);
    // The four spawners the director and the sleeper path need.
    try std.testing.expect(t.spawnerByName("BloodMoonHorde") != null);
    try std.testing.expect(t.spawnerByName("SleeperGSList") != null);
    // Every stage ladder is sorted and non-empty.
    for (t.spawners) |s| {
        try std.testing.expect(s.stages.len > 0);
        var prev: i32 = std.math.minInt(i32);
        for (s.stages) |st| {
            try std.testing.expect(st.stage_num >= prev);
            try std.testing.expect(st.spawns.len > 0);
            prev = st.stage_num;
        }
    }
    // The overwhelmingly common stock POI sleeper group must resolve end to end.
    const sg = t.sleeperEntityGroup("GroupGenericZombie", 1).?;
    try std.testing.expect(sg.group.len > 0);
    try std.testing.expectEqualStrings(sg.group, t.sleeperEntityGroup("S_-Group_Generic_Zombie", 1).?.group);
    // Blood moon stage 1 is the header's documented example.
    const bm = t.spawnerByName("BloodMoonHorde").?.getStage(1).?;
    try std.testing.expect(bm.spawns.len >= 1);
    try std.testing.expect(bm.spawns[0].max_alive >= 1);
}
