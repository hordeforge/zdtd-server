//! entitygroups.xml: named weighted spawn lists (`<e n="…" p="…"/>`).

const std = @import("std");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");

pub const Entry = struct {
    name: []const u8 = "",
    /// Relative weight (default 1). Stock `p` attribute.
    weight: f32 = 1,
};

/// Entries are a flat arena slice, not a fixed array: stock entitygroups.xml has
/// 1875 groups, so a per-group fixed array would cost megabytes and any cap on
/// the group count silently drops the tail (the gamestage horde groups live
/// there, e.g. feralHordeStageGS2 at index 1177).
pub const Group = struct {
    name: []const u8 = "",
    entries: []const Entry = &.{},
    weight_sum: f32 = 0,
};

pub const GroupTable = struct {
    groups: []const Group = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,
    source: enum { builtin, xml } = .builtin,

    pub fn deinit(self: *GroupTable) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
        self.* = builtin();
    }

    pub fn builtin() GroupTable {
        return .{ .groups = &builtin_groups, .source = .builtin };
    }

    pub fn byName(self: *const GroupTable, name: []const u8) ?Group {
        for (self.groups) |g| {
            if (std.mem.eql(u8, g.name, name)) return g;
        }
        return null;
    }

    /// Deterministic pick by seed; returns entity class name or null.
    /// Weights are compared in fixed-point milli-units so the pick path does
    /// not depend on f32 accumulation order (DST / cross-machine replay).
    pub fn pick(self: *const GroupTable, group_name: []const u8, seed: u32) ?[]const u8 {
        const g = self.byName(group_name) orelse return null;
        if (g.entries.len == 0 or g.weight_sum <= 0) return null;
        const s = seed *% 1103515245 +% 12345;
        // milli-weight: round(weight * 1000). Integer walk; r in [0, sum).
        var sum_mw: u64 = 0;
        for (g.entries) |e| {
            if (e.weight <= 0) continue;
            sum_mw += @as(u64, @intFromFloat(@round(e.weight * 1000.0)));
        }
        if (sum_mw == 0) return null;
        // Match prior scale: (s % 10000) / 10000 * sum, via integer multiply.
        const r_mw: u64 = (@as(u64, s % 10000) * sum_mw) / 10000;
        var acc_mw: u64 = 0;
        for (g.entries) |e| {
            if (e.weight <= 0) continue;
            acc_mw += @as(u64, @intFromFloat(@round(e.weight * 1000.0)));
            if (r_mw < acc_mw) return e.name;
        }
        return g.entries[g.entries.len - 1].name;
    }
};

const builtin_all = [_]Entry{
    .{ .name = "zombieBoe", .weight = 1 },
    .{ .name = "zombieJoe", .weight = 1 },
};
const builtin_night = [_]Entry{
    .{ .name = "zombieBoe", .weight = 1 },
    .{ .name = "zombieSpider", .weight = 0.25 },
};
const builtin_groups = [_]Group{
    .{ .name = "ZombiesAll", .entries = &builtin_all, .weight_sum = 2 },
    .{ .name = "ZombiesNight", .entries = &builtin_night, .weight_sum = 1.25 },
};

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !GroupTable {
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

    var list: std.ArrayList(Group) = .empty;
    defer list.deinit(allocator);
    var entry_buf: std.ArrayList(Entry) = .empty;
    defer entry_buf.deinit(allocator);

    var i: usize = 0;
    while (i < clean.len) {
        const tag = std.mem.indexOfPos(u8, clean, i, "<entitygroup") orelse break;
        const name = xml.attr(clean, tag, "name") orelse {
            i = tag + 12;
            continue;
        };
        const gt = std.mem.indexOfPos(u8, clean, tag, ">") orelse break;
        var body: []const u8 = "";
        var next_i = gt + 1;
        if (!(gt > tag and clean[gt - 1] == '/')) {
            const close = std.mem.indexOfPos(u8, clean, gt, "</entitygroup>") orelse break;
            body = clean[gt + 1 .. close];
            next_i = close + 14;
        }
        var g: Group = .{
            .name = try arena.dupe(u8, name),
        };
        entry_buf.clearRetainingCapacity();
        var bi: usize = 0;
        while (bi < body.len) {
            const et = std.mem.indexOfPos(u8, body, bi, "<e ") orelse break;
            const en = xml.attr(body, et, "n") orelse {
                bi = et + 3;
                continue;
            };
            var w: f32 = 1;
            if (xml.attr(body, et, "p")) |ps| {
                // Explicit p="0" disables the entry; do not coerce it to 1.
                w = @max(0, xml.parseF32(ps) orelse 1);
            }
            try entry_buf.append(allocator, .{
                .name = try arena.dupe(u8, en),
                .weight = w,
            });
            g.weight_sum += w;
            bi = et + 3;
        }
        if (entry_buf.items.len > 0) {
            g.entries = try arena.dupe(Entry, entry_buf.items);
            try list.append(allocator, g);
        }
        i = next_i;
    }

    return .{
        .groups = try arena.dupe(Group, list.items),
        .arena_ptr = arena_holder,
        .source = .xml,
    };
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?GroupTable {
    const paths = @import("paths.zig");
    return paths.tryLoadConfig("entitygroups.xml", GroupTable, loadFromPath, allocator, game_dir, config_dir);
}

test "builtin group pick" {
    const t = GroupTable.builtin();
    const n = t.pick("ZombiesAll", 1);
    try std.testing.expect(n != null);
}

test "group pick same seed is stable" {
    const t = GroupTable.builtin();
    const a = t.pick("ZombiesAll", 42).?;
    const b = t.pick("ZombiesAll", 42).?;
    try std.testing.expectEqualStrings(a, b);
    // Different seeds should not all collapse to one class on a 2-entry group.
    var saw_diff = false;
    var seed: u32 = 1;
    while (seed < 64) : (seed += 1) {
        if (!std.mem.eql(u8, t.pick("ZombiesAll", seed).?, a)) {
            saw_diff = true;
            break;
        }
    }
    try std.testing.expect(saw_diff);
}

test "load stock entitygroups when present" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/entitygroups.xml";
    var t = loadFromPath(std.testing.allocator, path) catch return error.SkipZigTest;
    defer t.deinit();
    try std.testing.expect(t.groups.len > 10);
    try std.testing.expect(t.byName("ZombiesAll") != null);
    const pick = t.pick("ZombiesAll", 99);
    try std.testing.expect(pick != null);
}

test "stock entitygroups keeps the whole file, tail groups included" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/entitygroups.xml";
    var t = loadFromPath(std.testing.allocator, path) catch return error.SkipZigTest;
    defer t.deinit();
    // Stock ships 1875 groups; any cap below that silently drops the tail, and
    // the gamestage horde groups live in the tail.
    try std.testing.expect(t.groups.len >= 1800);
    try std.testing.expect(t.byName("feralHordeStageGS2") != null);
    try std.testing.expect(t.byName("sleeperHordeStageGS5") != null);
    try std.testing.expect(t.pick("feralHordeStageGS2", 7) != null);
    // No group may come back empty: pick() would return null for it.
    for (t.groups) |g| try std.testing.expect(g.entries.len > 0);
}
