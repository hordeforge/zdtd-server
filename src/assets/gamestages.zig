//! gamestages.xml: per-spawner stage ladders plus the player/party stage math.
//!
//! Stock shape (asm.il GameStagesFromXml ~1379410):
//!   <gamestages>
//!     <config difficultyBonus=… startingWeight=… diminishingReturns=… …/>
//!     <group name="1GroupGenericZombie" spawner="SleeperGSList"/>
//!     <spawner name="BloodMoonHorde">
//!       <gamestage stage="1">
//!         <spawn group="ZombiesNight" num="300" maxAlive="8" duration="1" interval="60"/>
//!       </gamestage>
//!     </spawner>
//!   </gamestages>
//!
//! Group names are keyed by CleanName (asm.il GameStageGroup::CleanName ~1093513)
//! because both prefab sleeper volumes (SleeperVolume::Create ~1196629) and the
//! .tts reader (~1199950) clean before lookup.

const std = @import("std");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const paths = @import("paths.zig");

/// Stock world ticks per in-game day (asm.il get_gameStage IL_0012, 0x5dc0).
pub const ticks_per_day: u64 = 24000;

/// Longest name we clean in place. Stock's longest group name is well under this.
pub const max_name_len: usize = 128;

/// <config> knobs. Defaults are GameStageDefinition::.cctor (asm.il ~1093405),
/// not the XML: a config file may omit any attribute.
pub const Config = struct {
    days_alive_change_when_killed: i64 = 2,
    difficulty_bonus: f32 = 1,
    starting_weight: f32 = 1,
    diminishing_returns: f32 = 0.5,
    /// Blood-moon / wandering-horde loot drop bonus counters. Parsed and exposed
    /// but not yet consumed: zdtd has no per-horde kill counter to apply them to.
    loot_bonus_every: i32 = 0,
    loot_bonus_max_count: i32 = 0,
    loot_bonus_scale: f32 = 0,
    loot_wandering_bonus_every: i32 = 0,
    loot_wandering_bonus_scale: f32 = 0,
};

/// One `<spawn>` row. Defaults come from ParseSpawn (asm.il ~1379659..1379700):
/// num=1, maxAlive=1, interval=2, duration=0. The gamestages.xml header comment
/// claims interval=0 and duration=1; the IL is authoritative and disagrees.
pub const SpawnGroup = struct {
    /// entitygroups.xml group name.
    group: []const u8 = "",
    num: u16 = 1,
    max_alive: u16 = 1,
    interval: u16 = 2,
    duration: u16 = 0,
};

pub const Stage = struct {
    stage_num: i32 = 0,
    spawns: []const SpawnGroup = &.{},

    /// Stage::GetSpawnGroup(i) clamped; null when the stage carries no spawns.
    pub fn spawnGroup(self: *const Stage, idx: usize) ?SpawnGroup {
        if (self.spawns.len == 0) return null;
        return self.spawns[@min(idx, self.spawns.len - 1)];
    }
};

pub const Spawner = struct {
    name: []const u8 = "",
    /// Ascending by stage_num (GameStageDefinition::SortStages, asm.il ~1093160).
    stages: []const Stage = &.{},

    /// Highest stage whose number is <= `n`; null when `n` is below the first
    /// stage or the ladder is empty (asm.il GetStage ~1093187 + GetBoundIndex).
    pub fn getStage(self: *const Spawner, n: i32) ?*const Stage {
        if (self.stages.len == 0) return null;
        if (n < self.stages[0].stage_num) return null;
        var lo: usize = 0;
        var hi: usize = self.stages.len;
        while (lo + 1 < hi) {
            const mid = (lo + hi) / 2;
            if (self.stages[mid].stage_num <= n) lo = mid else hi = mid;
        }
        return &self.stages[lo];
    }
};

/// `<group name= spawner=>`: a POI-facing alias for a spawner ladder.
pub const Group = struct {
    /// CleanName(name); the key SleeperVolume looks up with.
    clean_name: []const u8 = "",
    full_name: []const u8 = "",
    spawner: []const u8 = "",
};

/// GameStageGroup::CleanName (asm.il ~1093513): one leading digit is dropped,
/// else an `S_` / `S_-` prefix is dropped and every `_` removed. Writes into
/// `buf` only on the underscore path; otherwise returns a slice of `name`.
pub fn cleanName(buf: *[max_name_len]u8, name: []const u8) []const u8 {
    if (name.len > 0 and std.ascii.isDigit(name[0])) return name[1..];
    if (!std.mem.startsWith(u8, name, "S_")) return name;
    const skip: usize = if (std.mem.startsWith(u8, name, "S_-")) 3 else 2;
    var n: usize = 0;
    for (name[skip..]) |c| {
        if (c == '_') continue;
        if (n >= buf.len) break;
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

/// EntityPlayer::get_gameStage (asm.il ~503972). `days_alive` must already be
/// clamped to [0, level] by the caller (daysAlive helper below).
/// Biome/quest terms are the caller's; zdtd passes zeros where the input tables
/// are not parsed yet (see docs/GAP_ANALYSIS.md).
pub const StageInputs = struct {
    level: u16 = 1,
    days_alive: u16 = 0,
    biome_mod: f32 = 0,
    biome_bonus: f32 = 0,
    quest_mod: f32 = 0,
    quest_bonus: f32 = 0,
    /// EntityPlayer::GlobalGameStageModifier, 1 unless a mod changes it.
    global_modifier: f32 = 1,
};

pub fn playerStage(cfg: Config, in: StageInputs) i32 {
    const level: f32 = @floatFromInt(in.level);
    const days: f32 = @floatFromInt(in.days_alive);
    const core = (level * (1 + in.biome_mod + in.quest_mod) + days) + in.biome_bonus + in.quest_bonus;
    const v = core * cfg.difficulty_bonus * in.global_modifier;
    if (!std.math.isFinite(v)) return 1;
    return @max(1, floorToI32(v));
}

/// (worldTime - bornAt) / 24000 clamped to [0, level] (asm.il get_gameStage
/// IL_0000..IL_0030). bornAt in the future yields 0, matching the u64 subtract
/// only because stock never lets bornAt exceed worldTime; we clamp explicitly.
pub fn daysAlive(world_time: u64, born_at_world_time: u64, level: u16) u16 {
    if (born_at_world_time >= world_time) return 0;
    const d = (world_time - born_at_world_time) / ticks_per_day;
    return @intCast(@min(d, @as(u64, level)));
}

/// EntityPlayer::SetAlive (asm.il ~503838): on respawn push bornAt forward by
/// daysAliveChangeWhenKilled days, or snap it to now when less than that has
/// elapsed (so daysAlive never wraps negative through the u64 subtract).
pub fn bornAtAfterDeath(cfg: Config, world_time: u64, born_at_world_time: u64) u64 {
    const penalty: u64 = @intCast(@max(0, cfg.days_alive_change_when_killed) * @as(i64, ticks_per_day));
    if (born_at_world_time > world_time) return world_time;
    if (world_time - born_at_world_time < penalty) return world_time;
    return born_at_world_time + penalty;
}

/// GameStageDefinition::CalcPartyLevel (asm.il ~1093305). Sorts `stages`
/// ascending in place, then walks top-down scaling by diminishingReturns.
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
    if (!std.math.isFinite(total)) return 0;
    return floorToI32(total);
}

/// EntityPlayer::GetLootStage (asm.il ~504215). Driven by player *level*, not
/// game stage, and with no days-alive term. POI-tier and biome terms are the
/// caller's; zdtd passes zeros where the input tables are not parsed yet.
pub const LootInputs = struct {
    level: u16 = 1,
    /// LootManager::POITierMod[DifficultyTier-1] * POITierLootStageModifier.
    poi_tier_mod: f32 = 0,
    poi_tier_bonus: f32 = 0,
    /// biomes.xml LootStageMod/Bonus * BiomeLootStageModifier.
    biome_mod: f32 = 0,
    biome_bonus: f32 = 0,
    /// LootContainer lootStageMod / lootStageBonus.
    container_mod: f32 = 0,
    container_bonus: f32 = 0,
    /// biomes.xml LootStageMin/Max; null = the stock -1 "unset" sentinel.
    biome_min: ?i32 = null,
    biome_max: ?i32 = null,
    global_modifier: f32 = 1,
};

pub fn lootStage(in: LootInputs) i32 {
    const level: f32 = @floatFromInt(in.level);
    const base = level * (1 + in.poi_tier_mod + in.biome_mod + in.container_mod) +
        (in.poi_tier_bonus + in.biome_bonus + in.container_bonus);
    if (!std.math.isFinite(base)) return 1;
    var stage = floorToI32(base);
    if (in.biome_min) |lo| stage = @max(stage, lo);
    if (in.biome_max) |hi| stage = @min(stage, hi);
    const scaled = @as(f32, @floatFromInt(stage)) * in.global_modifier;
    if (!std.math.isFinite(scaled)) return 1;
    return @max(1, floorToI32(scaled));
}

/// Saturating floor: f32 far outside i32 would be UB through @trunc.
fn floorToI32(v: f32) i32 {
    const f = @floor(v);
    if (f <= @as(f32, @floatFromInt(std.math.minInt(i32)))) return std.math.minInt(i32);
    if (f >= @as(f32, @floatFromInt(std.math.maxInt(i32)))) return std.math.maxInt(i32);
    return @trunc(f);
}

pub const Table = struct {
    config: Config = .{},
    spawners: []const Spawner = &.{},
    groups: []const Group = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,
    source: enum { empty, xml } = .empty,

    pub fn empty() Table {
        return .{};
    }

    pub fn deinit(self: *Table) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
        }
        self.* = .{};
    }

    pub fn spawnerByName(self: *const Table, name: []const u8) ?*const Spawner {
        for (self.spawners) |*s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }

    /// GameStageGroup::TryGet then `.spawner` (asm.il ~1093475). `name` is
    /// matched against cleaned group keys exactly as stock does, so callers
    /// pass the already-cleaned volume group name.
    pub fn groupSpawner(self: *const Table, name: []const u8) ?*const Spawner {
        for (self.groups) |g| {
            if (std.mem.eql(u8, g.clean_name, name)) return self.spawnerByName(g.spawner);
        }
        return null;
    }

    /// Convenience for the sleeper path: clean, then resolve group → spawner →
    /// stage → first spawn group name.
    pub fn sleeperEntityGroup(self: *const Table, volume_group: []const u8, stage_num: i32) ?SpawnGroup {
        var buf: [max_name_len]u8 = undefined;
        const sp = self.groupSpawner(cleanName(&buf, volume_group)) orelse return null;
        const st = sp.getStage(stage_num) orelse return null;
        return st.spawnGroup(0);
    }
};

fn parseF32Attr(src: []const u8, at: usize, name: []const u8, dflt: f32) f32 {
    const s = xml.attr(src, at, name) orelse return dflt;
    return xml.parseF32(std.mem.trim(u8, s, " \t")) orelse dflt;
}

/// Stock writes `num="65,535"` with a thousands separator; strip it before
/// parsing and saturate rather than reject (ParseAttribute would leave the
/// default, but the intent of 65,535 is plainly "as many as the u16 holds").
fn parseCount(s: []const u8, dflt: u16) u16 {
    var digits: [16]u8 = undefined;
    var n: usize = 0;
    for (std.mem.trim(u8, s, " \t")) |c| {
        if (c == ',' or c == '_') continue;
        if (!std.ascii.isDigit(c)) return dflt;
        if (n >= digits.len) return std.math.maxInt(u16);
        digits[n] = c;
        n += 1;
    }
    if (n == 0) return dflt;
    const v = std.fmt.parseInt(u32, digits[0..n], 10) catch return std.math.maxInt(u16);
    return @intCast(@min(v, std.math.maxInt(u16)));
}

fn parseCountAttr(src: []const u8, at: usize, name: []const u8, dflt: u16) u16 {
    const s = xml.attr(src, at, name) orelse return dflt;
    return parseCount(s, dflt);
}

fn stageAsc(_: void, a: Stage, b: Stage) bool {
    return a.stage_num < b.stage_num;
}

pub fn loadFromSlice(allocator: std.mem.Allocator, raw: []const u8) !Table {
    const clean = try xml.stripComments(allocator, raw);
    defer allocator.free(clean);

    var arena_holder = try allocator.create(std.heap.ArenaAllocator);
    arena_holder.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena_holder.deinit();
        allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();

    var cfg: Config = .{};
    if (std.mem.find(u8, clean, "<config")) |ci| {
        cfg.days_alive_change_when_killed = @trunc(@max(0, @min(365, parseF32Attr(clean, ci, "daysAliveChangeWhenKilled", 2))));
        cfg.difficulty_bonus = parseF32Attr(clean, ci, "difficultyBonus", 1);
        cfg.starting_weight = parseF32Attr(clean, ci, "startingWeight", 1);
        cfg.diminishing_returns = parseF32Attr(clean, ci, "diminishingReturns", 0.5);
        cfg.loot_bonus_every = parseCountAttr(clean, ci, "lootBonusEvery", 0);
        cfg.loot_bonus_max_count = parseCountAttr(clean, ci, "lootBonusMaxCount", 0);
        cfg.loot_bonus_scale = parseF32Attr(clean, ci, "lootBonusScale", 0);
        cfg.loot_wandering_bonus_every = parseCountAttr(clean, ci, "lootWanderingBonusEvery", 0);
        cfg.loot_wandering_bonus_scale = parseF32Attr(clean, ci, "lootWanderingBonusScale", 0);
    }

    var groups: std.ArrayList(Group) = .empty;
    defer groups.deinit(allocator);
    var i: usize = 0;
    while (std.mem.findPos(u8, clean, i, "<group")) |tag| {
        i = tag + 6;
        const name = xml.attr(clean, tag, "name") orelse continue;
        const spawner = xml.attr(clean, tag, "spawner") orelse continue;
        if (name.len == 0 or name.len > max_name_len) continue;
        var buf: [max_name_len]u8 = undefined;
        try groups.append(allocator, .{
            .clean_name = try arena.dupe(u8, cleanName(&buf, name)),
            .full_name = try arena.dupe(u8, name),
            .spawner = try arena.dupe(u8, spawner),
        });
    }

    var spawners: std.ArrayList(Spawner) = .empty;
    defer spawners.deinit(allocator);
    var stage_buf: std.ArrayList(Stage) = .empty;
    defer stage_buf.deinit(allocator);
    var spawn_buf: std.ArrayList(SpawnGroup) = .empty;
    defer spawn_buf.deinit(allocator);

    i = 0;
    while (std.mem.findPos(u8, clean, i, "<spawner")) |tag| {
        const gt = std.mem.findPos(u8, clean, tag, ">") orelse break;
        const name = xml.attr(clean, tag, "name") orelse {
            i = gt + 1;
            continue;
        };
        var body: []const u8 = "";
        i = gt + 1;
        if (!(gt > tag and clean[gt - 1] == '/')) {
            const close = std.mem.findPos(u8, clean, gt, "</spawner>") orelse break;
            body = clean[gt + 1 .. close];
            i = close + 10;
        }
        if (name.len == 0) continue;

        stage_buf.clearRetainingCapacity();
        var bi: usize = 0;
        while (std.mem.findPos(u8, body, bi, "<gamestage")) |st_tag| {
            const st_gt = std.mem.findPos(u8, body, st_tag, ">") orelse break;
            const num_s = xml.attr(body, st_tag, "stage");
            var st_body: []const u8 = "";
            bi = st_gt + 1;
            if (!(st_gt > st_tag and body[st_gt - 1] == '/')) {
                const st_close = std.mem.findPos(u8, body, st_gt, "</gamestage>") orelse break;
                st_body = body[st_gt + 1 .. st_close];
                bi = st_close + 12;
            }
            // ParseStage throws on a missing/unparsable stage number; zdtd skips
            // the row so one bad entry cannot void a whole ladder.
            const num = std.fmt.parseInt(i32, std.mem.trim(u8, num_s orelse continue, " \t"), 10) catch continue;

            spawn_buf.clearRetainingCapacity();
            var si: usize = 0;
            while (std.mem.findPos(u8, st_body, si, "<spawn")) |sp_tag| {
                si = sp_tag + 6;
                const grp = xml.attr(st_body, sp_tag, "group") orelse continue;
                if (grp.len == 0) continue;
                try spawn_buf.append(allocator, .{
                    .group = try arena.dupe(u8, grp),
                    .num = parseCountAttr(st_body, sp_tag, "num", 1),
                    .max_alive = parseCountAttr(st_body, sp_tag, "maxAlive", 1),
                    .interval = parseCountAttr(st_body, sp_tag, "interval", 2),
                    .duration = parseCountAttr(st_body, sp_tag, "duration", 0),
                });
            }
            // AddStage only keeps stages that carry at least one spawn (asm.il
            // ParseStage IL_007f..IL_008f).
            if (spawn_buf.items.len == 0) continue;
            try stage_buf.append(allocator, .{
                .stage_num = num,
                .spawns = try arena.dupe(SpawnGroup, spawn_buf.items),
            });
        }
        if (stage_buf.items.len == 0) continue;
        const stages = try arena.dupe(Stage, stage_buf.items);
        std.mem.sort(Stage, stages, {}, stageAsc);
        try spawners.append(allocator, .{
            .name = try arena.dupe(u8, name),
            .stages = stages,
        });
    }

    return .{
        .config = cfg,
        .spawners = try arena.dupe(Spawner, spawners.items),
        .groups = try arena.dupe(Group, groups.items),
        .arena_ptr = arena_holder,
        .source = .xml,
    };
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !Table {
    const raw = try io_fs.readFileAll(allocator, path);
    defer allocator.free(raw);
    return loadFromSlice(allocator, raw);
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?Table {
    return paths.tryLoadConfig("gamestages.xml", Table, loadFromPath, allocator, game_dir, config_dir);
}

const stock_path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/gamestages.xml";

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
    var t = loadFromPath(std.testing.allocator, stock_path) catch return error.SkipZigTest;
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
