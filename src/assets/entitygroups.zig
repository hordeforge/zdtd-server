//! entitygroups.xml: named weighted spawn lists (`<e n="…" p="…"/>`).

const std = @import("std");
const xml = @import("xml_util.zig");
const linux = std.os.linux;

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
    pub fn pick(self: *const GroupTable, group_name: []const u8, seed: u32) ?[]const u8 {
        const g = self.byName(group_name) orelse return null;
        if (g.entry_n == 0 or g.weight_sum <= 0) return null;
        const s = seed *% 1103515245 +% 12345;
        const r = @as(f32, @floatFromInt(s % 10000)) / 10000.0 * g.weight_sum;
        var acc: f32 = 0;
        var i: u8 = 0;
        while (i < g.entry_n) : (i += 1) {
            acc += g.entries[i].weight;
            if (r <= acc) return g.entries[i].name;
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

fn readFileAll(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var path_z: [2048]u8 = undefined;
    if (path.len >= path_z.len) return error.PathTooLong;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    const rc = linux.open(path_z[0..path.len :0].ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const end = linux.lseek(fd, 0, linux.SEEK.END);
    if (linux.errno(end) != .SUCCESS) return error.SeekFailed;
    const size: usize = @intCast(end);
    _ = linux.lseek(fd, 0, linux.SEEK.SET);
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    var off: usize = 0;
    while (off < size) {
        const n = linux.read(fd, buf[off..].ptr, size - off);
        if (linux.errno(n) != .SUCCESS) return error.ReadFailed;
        if (n == 0) break;
        off += @intCast(n);
    }
    return buf[0..off];
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !GroupTable {
    const raw = try readFileAll(allocator, path);
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
                w = xml.parseF32(ps) orelse 1;
            }
            g.entries[g.entry_n] = .{
                .name = try arena.dupe(u8, en),
                .weight = if (w > 0) w else 1,
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
    var path_buf: [2048]u8 = undefined;
    if (config_dir) |cd| {
        const p = try std.fmt.bufPrint(&path_buf, "{s}/entitygroups.xml", .{cd});
        return loadFromPath(allocator, p) catch null;
    }
    if (game_dir) |gd| {
        const p = try std.fmt.bufPrint(&path_buf, "{s}/Data/Config/entitygroups.xml", .{gd});
        return loadFromPath(allocator, p) catch null;
    }
    return null;
}

test "builtin group pick" {
    const t = GroupTable.builtin();
    const n = t.pick("ZombiesAll", 1);
    try std.testing.expect(n != null);
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
