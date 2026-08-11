//! Prefab `.blocks.nim` local-id → block name table (Prefab name mapping).
//! Catalog/asset parse (not world store). Use when TTS types are local indices
//! rather than AssignIds. Import `assets/blocks_nim.zig` only (not world).

const std = @import("std");
const arena_util = @import("../util/arena.zig");
const io_fs = @import("../util/io_fs.zig");

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
    const data = try io_fs.readFileAll(allocator, path);
    defer allocator.free(data);
    if (data.len < 8) return error.ShortNim;
    const version = std.mem.readInt(u32, data[0..4], .little);
    _ = version;
    const count = std.mem.readInt(u32, data[4..8], .little);
    if (count > max_entries) return error.TooMany;

    const arena_holder = try arena_util.newArenaHolder(allocator);
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
    // max_id sizes the allocation below; an untrusted file must not drive it
    // unbounded (a crafted id of 0xFFFFFFFF would demand a 64 GiB table).
    // Stock local ids are u16-range block ids, which can exceed max_entries.
    if (max_id > std.math.maxInt(u16)) return error.BadLocalId;

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
    if (!io_fs.fileExists(p)) return error.SkipZigTest;

    var m = try loadFromPath(std.testing.allocator, p);
    defer m.deinit();
    try std.testing.expect(m.names.len > 10);
    try std.testing.expectEqualStrings("air", m.nameOf(0).?);
}
