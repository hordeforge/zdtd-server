//! Minimal blocks.xml / builtin block id table.

const std = @import("std");
const xml = @import("xml_util.zig");
const linux = std.os.linux;

pub const max_blocks: usize = 4096;

pub const BlockDef = struct {
    id: u16 = 0,
    name: []const u8 = "",
    solid: bool = true,
};

pub const BlockTable = struct {
    defs: []const BlockDef = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,
    source: enum { builtin, xml } = .builtin,

    pub fn deinit(self: *BlockTable) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
        self.* = builtin();
    }

    pub fn builtin() BlockTable {
        return .{ .defs = builtin_defs[0..], .source = .builtin };
    }

    pub fn byId(self: *const BlockTable, id: u16) ?BlockDef {
        for (self.defs) |d| if (d.id == id) return d;
        return null;
    }

    pub fn byName(self: *const BlockTable, name: []const u8) ?BlockDef {
        for (self.defs) |d| {
            if (std.mem.eql(u8, d.name, name)) return d;
        }
        return null;
    }

    pub fn isSolid(self: *const BlockTable, id: u16) bool {
        if (id == 0) return false;
        if (self.byId(id)) |d| return d.solid;
        return true;
    }
};

pub const builtin_defs = [_]BlockDef{
    .{ .id = 0, .name = "air", .solid = false },
    .{ .id = 1, .name = "dirt", .solid = true },
    .{ .id = 2, .name = "stone", .solid = true },
    .{ .id = 3, .name = "bedrock", .solid = true },
    .{ .id = 4, .name = "wood", .solid = true },
    .{ .id = 5, .name = "cobblestone", .solid = true },
    .{ .id = 6, .name = "water", .solid = false },
    .{ .id = 7, .name = "sand", .solid = true },
    .{ .id = 8, .name = "iron", .solid = true },
    .{ .id = 9, .name = "glass", .solid = true },
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

/// Best-effort blocks.xml: assign sequential ids starting at 10 for unknown names.
pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !BlockTable {
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

    var list: std.ArrayList(BlockDef) = .empty;
    defer list.deinit(allocator);
    for (builtin_defs) |d| {
        try list.append(allocator, .{
            .id = d.id,
            .name = try arena.dupe(u8, d.name),
            .solid = d.solid,
        });
    }

    var next_id: u16 = 10;
    var i: usize = 0;
    while (i < clean.len and list.items.len < max_blocks) {
        const bi = std.mem.indexOfPos(u8, clean, i, "<block ") orelse break;
        const name = xml.attr(clean, bi, "name") orelse {
            i = bi + 7;
            continue;
        };
        // skip if already have
        var exists = false;
        for (list.items) |d| {
            if (std.mem.eql(u8, d.name, name)) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            // Non-solid: exact "air"/"water" and water-family names only.
            // (Substring matched false positives like "airConditioner".)
            const solid = !(std.mem.eql(u8, name, "air") or
                std.mem.eql(u8, name, "water") or
                std.mem.startsWith(u8, name, "water") or
                std.mem.startsWith(u8, name, "terrWater"));
            try list.append(allocator, .{
                .id = next_id,
                .name = try arena.dupe(u8, name),
                .solid = solid,
            });
            next_id +%= 1;
        }
        i = bi + 7;
    }

    const defs = try arena.alloc(BlockDef, list.items.len);
    @memcpy(defs, list.items);
    return .{ .defs = defs, .arena_ptr = arena_holder, .source = .xml };
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?BlockTable {
    var path_buf: [2048]u8 = undefined;
    if (config_dir) |cd| {
        const p = try std.fmt.bufPrint(&path_buf, "{s}/blocks.xml", .{cd});
        return loadFromPath(allocator, p) catch null;
    }
    if (game_dir) |gd| {
        const p = try std.fmt.bufPrint(&path_buf, "{s}/Data/Config/blocks.xml", .{gd});
        return loadFromPath(allocator, p) catch null;
    }
    return null;
}

test "builtin block table" {
    const t = BlockTable.builtin();
    try std.testing.expect(t.isSolid(1));
    try std.testing.expect(!t.isSolid(0));
    try std.testing.expectEqualStrings("stone", t.byId(2).?.name);
}
