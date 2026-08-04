//! spawning.xml biome spawn rules → director / animal pop.

const std = @import("std");
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
};

pub const Table = struct {
    rules: []const Rule = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,

    pub fn empty() Table {
        return .{};
    }

    pub fn deinit(self: *Table) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            self.rules = &.{};
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
        self.* = .{};
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
    const comma = std.mem.indexOfScalar(u8, s, ',') orelse s.len;
    return std.fmt.parseFloat(f32, s[0..comma]) catch 1.0;
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !Table {
    const raw = try io_fs.readFileAll(allocator, path);
    defer allocator.free(raw);
    const clean = try xml.stripComments(allocator, raw);
    defer allocator.free(clean);

    var arena_holder = try allocator.create(std.heap.ArenaAllocator);
    arena_holder.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena_holder.deinit();
        allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();

    var list: std.ArrayList(Rule) = .empty;
    defer list.deinit(allocator);

    var i: usize = 0;
    while (i < clean.len and list.items.len < max_rules) {
        const bi = std.mem.indexOfPos(u8, clean, i, "<biome ") orelse break;
        const bname = xml.attr(clean, bi, "name") orelse {
            i = bi + 7;
            continue;
        };
        const gt = std.mem.indexOfPos(u8, clean, bi, ">") orelse break;
        const close = std.mem.indexOfPos(u8, clean, gt, "</biome>") orelse break;
        const body = clean[gt + 1 .. close];
        const bn = try arena.dupe(u8, bname);

        var j: usize = 0;
        while (j < body.len and list.items.len < max_rules) {
            const si = std.mem.indexOfPos(u8, body, j, "<spawn ") orelse break;
            const eg = xml.attr(body, si, "entitygroup") orelse {
                j = si + 7;
                continue;
            };
            const mc_s = xml.attr(body, si, "maxcount") orelse "1";
            const time_s = xml.attr(body, si, "time") orelse "Any";
            const type_s = xml.attr(body, si, "type");
            const rd_s = xml.attr(body, si, "respawndelay") orelse "1";
            const mc = std.fmt.parseInt(u8, mc_s, 10) catch 1;
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

    const rules = try arena.alloc(Rule, list.items.len);
    @memcpy(rules, list.items);
    return .{ .rules = rules, .arena_ptr = arena_holder };
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?Table {
    return paths.tryLoadConfig("spawning.xml", Table, loadFromPath, allocator, game_dir, config_dir);
}

test "load spawning.xml when present" {
    const p = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/spawning.xml";
    var t = loadFromPath(std.testing.allocator, p) catch return error.SkipZigTest;
    defer t.deinit();
    try std.testing.expect(t.rules.len > 5);
    var buf: [32]Rule = undefined;
    const n = t.rulesForBiome("burnt_forest", &buf);
    try std.testing.expect(n >= 1);
    try std.testing.expect(buf[0].entitygroup.len > 0);
}
