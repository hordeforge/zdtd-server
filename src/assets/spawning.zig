//! spawning.xml biome spawn rules → director / animal pop.

const std = @import("std");
const arena_util = @import("../util/arena.zig");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const paths = @import("paths.zig");

pub const max_rules: usize = 512;

pub const TimeOfDay = enum(u8) { any = 0, day = 1, night = 2 };

pub const SpawnKind = enum(u8) { zombie = 0, animal = 1, rare = 2 };

pub const Rule = struct {
    biome: []const u8 = "",
    entitygroup: []const u8 = "",
    maxcount: u8 = 1,
    time: TimeOfDay = .any,
    kind: SpawnKind = .zombie,
    /// Default sandbox column of respawndelay (game days), low bound.
    respawn_days: f32 = 1.0,
    /// Comma list of POI tags: the rule only fires where the area's POI tags
    /// contain any of these (stock POITags.Test_AnySet, spawning.md §2).
    tags: []const u8 = "",
    /// Comma list of POI tags that disable the rule where present
    /// (stock noPOITags.Test_AnySet).
    notags: []const u8 = "",
};

/// `<entityspawner name=…>` with its `EntityGroupName` property. Stock's
/// screamer system names these spawners in code (AIDirectorChunkEventComponent
/// ::SpawnScouts, asm.il ~415972) rather than reaching for a biome rule.
pub const Spawner = struct {
    name: []const u8 = "",
    entitygroup: []const u8 = "",
    /// TotalAlive property; low bound of a comma list. 0 = unset.
    total_alive: u8 = 0,
    /// TotalPerWave property; low bound of a comma list. 0 = unset.
    total_per_wave: u8 = 0,
};

pub const Table = struct {
    rules: []const Rule = &.{},
    spawners: []const Spawner = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,

    pub fn empty() Table {
        return .{};
    }

    pub fn deinit(self: *Table) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            self.rules = &.{};
            self.spawners = &.{};
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
        self.* = .{};
    }

    pub fn spawnerByName(self: *const Table, name: []const u8) ?Spawner {
        for (self.spawners) |s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }

    /// First matching rules for biome name (empty if none).
    pub fn rulesForBiome(self: *const Table, biome: []const u8, out: []Rule) usize {
        var n: usize = 0;
        for (self.rules) |r| {
            if (n >= out.len) break;
            if (std.mem.eql(u8, r.biome, biome)) {
                out[n] = r;
                n += 1;
            }
        }
        return n;
    }
};

fn parseTime(s: []const u8) TimeOfDay {
    if (std.mem.eql(u8, s, "Day")) return .day;
    if (std.mem.eql(u8, s, "Night")) return .night;
    return .any;
}

fn parseKind(s: ?[]const u8) SpawnKind {
    const t = s orelse return .zombie;
    if (std.mem.eql(u8, t, "animal")) return .animal;
    if (std.mem.eql(u8, t, "rare")) return .rare;
    return .zombie;
}

fn lowF32List(s: []const u8) f32 {
    const comma = std.mem.findScalar(u8, s, ',') orelse s.len;
    return std.fmt.parseFloat(f32, s[0..comma]) catch 1.0;
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !Table {
    const raw = try io_fs.readFileAll(allocator, path);
    defer allocator.free(raw);
    return loadFromSlice(allocator, raw);
}

pub fn loadFromSlice(allocator: std.mem.Allocator, raw: []const u8) !Table {
    const clean = try xml.stripComments(allocator, raw);
    defer allocator.free(clean);

    const arena_holder = try arena_util.newArenaHolder(allocator);
    errdefer {
        arena_holder.deinit();
        allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();

    var list: std.ArrayList(Rule) = .empty;
    defer list.deinit(allocator);

    var i: usize = 0;
    while (i < clean.len and list.items.len < max_rules) {
        const bi = std.mem.findPos(u8, clean, i, "<biome ") orelse break;
        const bname = xml.attr(clean, bi, "name") orelse {
            i = bi + 7;
            continue;
        };
        const gt = std.mem.findPos(u8, clean, bi, ">") orelse break;
        const close = std.mem.findPos(u8, clean, gt, "</biome>") orelse break;
        const body = clean[gt + 1 .. close];
        const bn = try arena.dupe(u8, bname);

        var j: usize = 0;
        while (j < body.len and list.items.len < max_rules) {
            const si = std.mem.findPos(u8, body, j, "<spawn ") orelse break;
            const eg = xml.attr(body, si, "entitygroup") orelse {
                j = si + 7;
                continue;
            };
            const mc_s = xml.attr(body, si, "maxcount") orelse "1";
            const time_s = xml.attr(body, si, "time") orelse "Any";
            const type_s = xml.attr(body, si, "type");
            const rd_s = xml.attr(body, si, "respawndelay") orelse "1";
            const mc = std.fmt.parseInt(u8, mc_s, 10) catch 1;
            // POI-tag gating (spawning.md §2): tags = required (any-set),
            // notags = forbidden (none-set), both comma lists.
            const tags_s = xml.attr(body, si, "tags") orelse "";
            const notags_s = xml.attr(body, si, "notags") orelse "";
            try list.append(allocator, .{
                .biome = bn,
                .entitygroup = try arena.dupe(u8, eg),
                .maxcount = mc,
                .time = parseTime(time_s),
                .kind = parseKind(type_s),
                .respawn_days = lowF32List(rd_s),
            });
            j = si + 7;
        }
        i = close + 8;
    }

    var spawners: std.ArrayList(Spawner) = .empty;
    defer spawners.deinit(allocator);
    i = 0;
    while (std.mem.findPos(u8, clean, i, "<entityspawner")) |tag| {
        const gt = std.mem.findPos(u8, clean, tag, ">") orelse break;
        const name = xml.attr(clean, tag, "name") orelse {
            i = gt + 1;
            continue;
        };
        var body: []const u8 = "";
        i = gt + 1;
        if (!(gt > tag and clean[gt - 1] == '/')) {
            const close = std.mem.findPos(u8, clean, gt, "</entityspawner>") orelse break;
            body = clean[gt + 1 .. close];
            i = close + 16;
        }
        // Stock allows one <day> block per day number; zdtd takes the first
        // EntityGroupName it finds (the `*` fallback in every stock spawner).
        const eg = xml.propertyValue(body, "EntityGroupName") orelse continue;
        if (eg.len == 0) continue;
        try spawners.append(allocator, .{
            .name = try arena.dupe(u8, name),
            .entitygroup = try arena.dupe(u8, eg),
            .total_alive = lowU8List(xml.propertyValue(body, "TotalAlive")),
            .total_per_wave = lowU8List(xml.propertyValue(body, "TotalPerWave")),
        });
    }

    return .{
        .rules = try arena.dupe(Rule, list.items),
        .spawners = try arena.dupe(Spawner, spawners.items),
        .arena_ptr = arena_holder,
    };
}

/// Low bound of a `"1,2"` style property list; 0 when absent or unparsable.
fn lowU8List(s: ?[]const u8) u8 {
    const v = s orelse return 0;
    const comma = std.mem.findScalar(u8, v, ',') orelse v.len;
    return std.fmt.parseInt(u8, std.mem.trim(u8, v[0..comma], " \t"), 10) catch 0;
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?Table {
    return paths.tryLoadConfig("spawning.xml", Table, loadFromPath, allocator, game_dir, config_dir);
}

test "load spawning.xml when present" {
    const p = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/spawning.xml";
    if (!io_fs.fileExists(p)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, p);
    defer t.deinit();
    try std.testing.expect(t.rules.len > 5);
    var buf: [32]Rule = undefined;
    const n = t.rulesForBiome("burnt_forest", &buf);
    try std.testing.expect(n >= 1);
    try std.testing.expect(buf[0].entitygroup.len > 0);
}

test "stock entityspawners feed the gamestage scout thresholds" {
    const p = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/spawning.xml";
    if (!io_fs.fileExists(p)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, p);
    defer t.deinit();
    // SpawnScouts (asm.il ~415972) names these four by gamestage band.
    try std.testing.expectEqualStrings("ZombieScouts", t.spawnerByName("Scouts1").?.entitygroup);
    try std.testing.expectEqualStrings("ZombieScouts", t.spawnerByName("Scouts2").?.entitygroup);
    try std.testing.expectEqualStrings("ZombieScoutsFeral", t.spawnerByName("ScoutsFeral").?.entitygroup);
    try std.testing.expectEqualStrings("ZombieScoutsRadiated", t.spawnerByName("ScoutsRadiated").?.entitygroup);
    // TotalAlive / TotalPerWave take the low bound of a comma list.
    try std.testing.expectEqual(@as(u8, 1), t.spawnerByName("Scouts1").?.total_alive);
    try std.testing.expectEqual(@as(u8, 2), t.spawnerByName("Scouts2").?.total_per_wave);
    try std.testing.expectEqual(@as(u8, 1), t.spawnerByName("ScoutsFeral").?.total_per_wave);
    try std.testing.expect(t.spawnerByName("NoSuchSpawner") == null);
}

test "entityspawner parse tolerates malformed rows" {
    const src =
        \\<spawning>
        \\  <entityspawner name="ok"><day value="*"><property name="EntityGroupName" value="G"/></day></entityspawner>
        \\  <entityspawner name="noGroup"><day value="*"><property name="TotalAlive" value="4"/></day></entityspawner>
        \\  <entityspawner><day value="*"><property name="EntityGroupName" value="H"/></day></entityspawner>
        \\  <entityspawner name="selfClosed"/>
        \\</spawning>
    ;
    var t = try loadFromSlice(std.testing.allocator, src);
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 1), t.spawners.len);
    try std.testing.expectEqualStrings("G", t.spawnerByName("ok").?.entitygroup);
    try std.testing.expectEqual(@as(u8, 0), t.spawnerByName("ok").?.total_alive);
}

test "spawning.xml rule tags/notags parse" {
    const p = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/spawning.xml";
    if (!io_fs.fileExists(p)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, p);
    defer t.deinit();
    // Stock pine_forest dz02 carries tags="commercial,industrial" notags="downtown".
    var saw_tags = false;
    var saw_notags = false;
    for (t.rules) |r| {
        if (std.mem.eql(u8, r.biome, "pine_forest") and std.mem.eql(u8, r.entitygroup, "ZombiesAll")) {
            if (r.tags.len > 0) saw_tags = true;
            if (r.notags.len > 0) saw_notags = true;
        }
    }
    try std.testing.expect(saw_tags);
    try std.testing.expect(saw_notags);
}
