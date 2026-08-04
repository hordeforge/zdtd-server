//! entitygroups.xml: named weighted spawn lists (`<e n="…" p="…"/>`).

const std = @import("std");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");

pub const max_groups: usize = 512;
pub const max_entries: usize = 64;

pub const Entry = struct {
    name: []const u8 = "",
    /// Relative weight (default 1). Stock `p` attribute.
    weight: f32 = 1,
};

pub const Group = struct {
    name: []const u8 = "",
    entries: [max_entries]Entry = [_]Entry{.{}} ** max_entries,
    entry_n: u8 = 0,
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
        if (g.entry_n == 0 or g.weight_sum <= 0) return null;
        const s = seed *% 1103515245 +% 12345;
        // milli-weight: round(weight * 1000). Integer walk; r in [0, sum).
        var sum_mw: u64 = 0;
        var i: u8 = 0;
        while (i < g.entry_n) : (i += 1) {
            const w = g.entries[i].weight;
            if (w <= 0) continue;
            sum_mw += @as(u64, @intFromFloat(@round(w * 1000.0)));
        }
        if (sum_mw == 0) return null;
        // Match prior scale: (s % 10000) / 10000 * sum, via integer multiply.
        const r_mw: u64 = (@as(u64, s % 10000) * sum_mw) / 10000;
        var acc_mw: u64 = 0;
        i = 0;
        while (i < g.entry_n) : (i += 1) {
            const w = g.entries[i].weight;
            if (w <= 0) continue;
            acc_mw += @as(u64, @intFromFloat(@round(w * 1000.0)));
            if (r_mw < acc_mw) return g.entries[i].name;
        }
        return g.entries[g.entry_n - 1].name;
    }
};

const builtin_groups = [_]Group{
    blk: {
        var g: Group = .{ .name = "ZombiesAll", .entry_n = 2, .weight_sum = 2 };
        g.entries[0] = .{ .name = "zombieBoe", .weight = 1 };
        g.entries[1] = .{ .name = "zombieJoe", .weight = 1 };
        break :blk g;
    },
    blk: {
        var g: Group = .{ .name = "ZombiesNight", .entry_n = 2, .weight_sum = 1.25 };
        g.entries[0] = .{ .name = "zombieBoe", .weight = 1 };
        g.entries[1] = .{ .name = "zombieSpider", .weight = 0.25 };
        break :blk g;
    },
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

    var i: usize = 0;
    while (i < clean.len and list.items.len < max_groups) {
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
        var bi: usize = 0;
        while (bi < body.len and g.entry_n < max_entries) {
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
            g.entries[g.entry_n] = .{
                .name = try arena.dupe(u8, en),
                .weight = w,
            };
            g.weight_sum += g.entries[g.entry_n].weight;
            g.entry_n += 1;
            bi = et + 3;
        }
        if (g.entry_n > 0) try list.append(allocator, g);
        i = next_i;
    }

    const gs = try arena.alloc(Group, list.items.len);
    @memcpy(gs, list.items);
    return .{
        .groups = gs,
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
