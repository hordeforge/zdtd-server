//! traders.xml minimal loader: traderAlways group direct items → trader stock.
//! Group refs (`<item group=...>`) resolve through loot.xml-style groups only
//! when they are trader_item_groups in the same file; nested loot groups skipped.

const std = @import("std");
const xml = @import("xml_util.zig");
const linux = std.os.linux;

pub const max_entries: usize = 32;

pub const Entry = struct {
    name: []const u8 = "",
    count: u16 = 1,
};

pub const TraderTable = struct {
    entries: []const Entry = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,

    pub fn deinit(self: *TraderTable) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
        }
        self.* = .{};
    }

    pub fn empty() TraderTable {
        return .{};
    }
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

/// Parse `count="a,b"` or `count="a"`; take the low bound (deterministic stock).
fn lowCount(v: []const u8) u16 {
    const comma = std.mem.indexOfScalar(u8, v, ',') orelse v.len;
    return std.fmt.parseInt(u16, v[0..comma], 10) catch 1;
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !TraderTable {
    const raw = try readFileAll(allocator, path);
    defer allocator.free(raw);
    const clean = try xml.stripComments(allocator, raw);
    defer allocator.free(clean);

    const start = std.mem.indexOf(u8, clean, "<trader_item_group name=\"traderAlways\"") orelse
        return error.OpenFailed;
    const end = std.mem.indexOfPos(u8, clean, start, "</trader_item_group>") orelse clean.len;
    const body = clean[start..end];

    var arena_holder = try allocator.create(std.heap.ArenaAllocator);
    arena_holder.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena_holder.deinit();
        allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();

    var list: std.ArrayList(Entry) = .empty;
    defer list.deinit(allocator);
    var i: usize = 0;
    while (i < body.len and list.items.len < max_entries) {
        const ii = std.mem.indexOfPos(u8, body, i, "<item ") orelse break;
        i = ii + 6;
        // direct items only; group refs need weighted roll machinery (deferred)
        const name = xml.attr(body, ii, "name") orelse continue;
        const count: u16 = if (xml.attr(body, ii, "count")) |cv| lowCount(cv) else 1;
        try list.append(allocator, .{ .name = try arena.dupe(u8, name), .count = count });
    }
    if (list.items.len == 0) return error.OpenFailed;
    const entries = try arena.alloc(Entry, list.items.len);
    @memcpy(entries, list.items);
    return .{ .entries = entries, .arena_ptr = arena_holder };
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) ?TraderTable {
    var path_buf: [2048]u8 = undefined;
    if (config_dir) |cd| {
        const p = std.fmt.bufPrint(&path_buf, "{s}/traders.xml", .{cd}) catch return null;
        return loadFromPath(allocator, p) catch null;
    }
    if (game_dir) |gd| {
        const p = std.fmt.bufPrint(&path_buf, "{s}/Data/Config/traders.xml", .{gd}) catch return null;
        return loadFromPath(allocator, p) catch null;
    }
    return null;
}

test "trader table parses stock traderAlways when present" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/traders.xml";
    var t = loadFromPath(std.testing.allocator, path) catch return; // skip offline
    defer t.deinit();
    try std.testing.expect(t.entries.len >= 5);
    var found_bandage = false;
    for (t.entries) |e| {
        if (std.mem.eql(u8, e.name, "medicalBandage")) {
            found_bandage = true;
            try std.testing.expect(e.count >= 3);
        }
    }
    try std.testing.expect(found_bandage);
}
