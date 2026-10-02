//! Per-(chunk, prop id) prop tuples: the state `NetPackageSetProp` writes.
//!
//! Stock `ChunkCluster.SetProp(ChunkPos, PropId, Position, Rotation, Scale,
//! BlockValue)` applies a nullable tuple to the chunk's prop slot; a null field
//! means "leave unchanged" (RE world-chunks.md 925-945). zdtd has no prefab-prop
//! baseline to merge into, so a change that names only some fields stores them
//! against zeroed defaults and `set_flags` records which were named.
//!
//! Fixed capacity and overwrite-by-key: no allocation on the packet path.
const std = @import("std");

/// Records are held inline in the world store, so the cap is a stack/size
/// budget, not a gameplay number: 256 tuples cover a session's placed props at
/// ~15 KB, where 4096 overflowed the stack in every test that holds a World.
pub const max_prop_records = 256;

pub const PropRecord = struct {
    chunk_key: u64,
    prop_id: i32,
    position: [3]f32 = .{ 0, 0, 0 },
    rotation: [4]f32 = .{ 0, 0, 0, 1 },
    scale: [3]f32 = .{ 1, 1, 1 },
    block_raw: u32 = 0,
    block_damage: u16 = 0,
    /// Wire flags byte of the change that last wrote this record (bit 1 PropId,
    /// 2 Position, 4 Rotation, 8 Scale, 16 BlockValue).
    set_flags: u8 = 0,
};

pub fn chunkKey(chunk_x: i32, chunk_y: i32) u64 {
    return (@as(u64, @as(u32, @bitCast(chunk_x))) << 32) | @as(u32, @bitCast(chunk_y));
}

pub const Store = struct {
    records: [max_prop_records]PropRecord = [_]PropRecord{.{ .chunk_key = 0, .prop_id = 0 }} ** max_prop_records,
    n: usize = 0,

    pub fn indexOf(self: *const Store, chunk_x: i32, chunk_y: i32, prop_id: i32) ?usize {
        const key = chunkKey(chunk_x, chunk_y);
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (self.records[i].chunk_key == key and self.records[i].prop_id == prop_id) return i;
        }
        return null;
    }

    /// Apply one change. Returns null when the store is full and this is a new
    /// prop: the caller drops that change rather than evicting live state.
    pub fn apply(
        self: *Store,
        chunk_x: i32,
        chunk_y: i32,
        prop_id: ?i32,
        position: ?[3]f32,
        rotation: ?[4]f32,
        scale: ?[3]f32,
        block_raw: ?u32,
        block_damage: ?u16,
    ) ?usize {
        const pid = prop_id orelse -1;
        const idx: usize = self.indexOf(chunk_x, chunk_y, pid) orelse blk: {
            if (self.n >= self.records.len) return null;
            const at = self.n;
            self.n += 1;
            self.records[at] = .{ .chunk_key = chunkKey(chunk_x, chunk_y), .prop_id = pid };
            break :blk at;
        };
        const rec = &self.records[idx];
        if (position) |v| rec.position = v;
        if (rotation) |v| rec.rotation = v;
        if (scale) |v| rec.scale = v;
        if (block_raw) |raw| {
            rec.block_raw = raw;
            rec.block_damage = block_damage orelse 0;
        }
        var flags: u8 = 0;
        if (prop_id != null) flags |= 1;
        if (position != null) flags |= 2;
        if (rotation != null) flags |= 4;
        if (scale != null) flags |= 8;
        if (block_raw != null) flags |= 16;
        rec.set_flags = flags;
        return idx;
    }
};

test "the prop store overwrites by chunk and prop id" {
    var s: Store = .{};
    _ = s.apply(3, -4, 7, .{ 1, 2, 3 }, null, null, null, null).?;
    try std.testing.expectEqual(@as(usize, 1), s.n);
    // A different prop in the same chunk is a new record.
    _ = s.apply(3, -4, 8, null, null, .{ 2, 2, 2 }, null, null).?;
    try std.testing.expectEqual(@as(usize, 2), s.n);
    // The same prop again merges into its record rather than appending.
    const i = s.apply(3, -4, 7, null, .{ 0, 0, 0, 1 }, null, 0xAB, 5).?;
    try std.testing.expectEqual(@as(usize, 2), s.n);
    const rec = s.records[i];
    try std.testing.expectEqual(@as(f32, 1), rec.position[0]); // unchanged
    try std.testing.expectEqual(@as(f32, 1), rec.rotation[3]);
    try std.testing.expectEqual(@as(u32, 0xAB), rec.block_raw);
    try std.testing.expectEqual(@as(u16, 5), rec.block_damage);
    // The flags record what the last change actually named: the prop id it
    // keyed on, its rotation and its block value.
    try std.testing.expectEqual(@as(u8, 1 | 4 | 16), rec.set_flags);
    // A chunk elsewhere does not collide with the same prop id.
    try std.testing.expect(s.indexOf(3, -5, 7) == null);
    try std.testing.expect(s.indexOf(3, -4, 7) != null);
}
