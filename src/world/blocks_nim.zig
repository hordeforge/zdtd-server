//! Prefab `.blocks.nim` local-id → block name table (Prefab name mapping).
//! Use when TTS types are local indices rather than AssignIds.

const std = @import("std");
const linux = std.os.linux;

pub const max_entries: usize = 4096;

pub const Map = struct {
    /// local_id → name (owned in arena)
    names: []const []const u8 = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,

    pub fn deinit(self: *Map) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
        self.* = .{};
    }

    pub fn nameOf(self: *const Map, local_id: u16) ?[]const u8 {
        if (local_id >= self.names.len) return null;
        const n = self.names[local_id];
        return if (n.len > 0) n else null;
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

fn read7BitLen(data: []const u8, pos: *usize) !usize {
    var length: usize = 0;
    var shift: u6 = 0;
    while (true) {
        if (pos.* >= data.len) return error.EndOfStream;
        const b = data[pos.*];
        pos.* += 1;
        length |= @as(usize, b & 0x7f) << shift;
        if (b < 0x80) break;
        shift += 7;
        if (shift > 28) return error.BadLen;
    }
    return length;
}

/// Layout (observed stock): version:u32 | count:u32 | (local_id:u32 | 7bit-string name)*count
pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !Map {
    const data = try readFileAll(allocator, path);
    defer allocator.free(data);
    if (data.len < 8) return error.ShortNim;
    const version = std.mem.readInt(u32, data[0..4], .little);
    _ = version;
    const count = std.mem.readInt(u32, data[4..8], .little);
    if (count > max_entries) return error.TooMany;

    var arena_holder = try allocator.create(std.heap.ArenaAllocator);
    arena_holder.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena_holder.deinit();
        allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();

    // Find max local id
    var max_id: usize = 0;
    var pos: usize = 8;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (pos + 4 > data.len) return error.ShortNim;
        const id = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;
        const ln = try read7BitLen(data, &pos);
        if (pos + ln > data.len) return error.ShortNim;
        pos += ln;
        if (id > max_id) max_id = id;
    }

    const names = try arena.alloc([]const u8, max_id + 1);
    @memset(names, "");

    pos = 8;
    i = 0;
    while (i < count) : (i += 1) {
        const id = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;
        const ln = try read7BitLen(data, &pos);
        const name = try arena.dupe(u8, data[pos .. pos + ln]);
        pos += ln;
        if (id <= max_id) names[id] = name;
    }

    return .{
        .names = names,
        .arena_ptr = arena_holder,
    };
}

test "load abandoned_house blocks.nim if present" {
    const p = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Prefabs/POIs/abandoned_house_01.blocks.nim";
    var path_z: [512]u8 = undefined;
    if (p.len >= path_z.len) return error.SkipZigTest;
    @memcpy(path_z[0..p.len], p);
    path_z[p.len] = 0;
    const rc = linux.open(path_z[0..p.len :0].ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.SkipZigTest;
    _ = linux.close(@intCast(rc));

    var m = try loadFromPath(std.testing.allocator, p);
    defer m.deinit();
    try std.testing.expect(m.names.len > 10);
    try std.testing.expectEqualStrings("air", m.nameOf(0).?);
}
