//! Door tile-entity state: the `TEFeatureDoor` / `TEFeatureLockable` pair on a
//! composite door (doors, gates, hatches).
//!
//! Stock keeps the door's open flag and lock in its `TileEntityComposite`; the
//! open flag also lives in the block meta (which every client already syncs), so
//! this store exists for the part the meta does not carry: the lock blob that
//! makes another player's client show a locked door as locked.
//!
//! The auto-close deadline rides the same record (the `AutoCloseTime` timer is
//! armed by `blocks_setblock` and run by `craft.tickDoorTimers`).
//!
//! Non-goals: the drawbridge and honk-open halves of `TEFeatureDoor`, and the
//! door mesh/animation state (client-owned).
const std = @import("std");
const containers = @import("containers.zig");
const io_fs = @import("../util/io_fs.zig");

/// Doors zdtd keeps lock state for.
pub const max_doors: usize = 256;

pub const Door = struct {
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
    block_id: u16 = 0,
    /// `TEFeatureLockable` body, replayed verbatim (same validation and cap as
    /// a container lock).
    lock_blob: [containers.max_lock_feature_bytes]u8 = [_]u8{0} ** containers.max_lock_feature_bytes,
    lock_len: u16 = 0,
    /// `autoCloseAtTickTime`: the tick the server closes this door at, 0 when
    /// no timer is armed (`SetOpen` stamps `ticks + AutoCloseTime * 20`).
    close_at: u64 = 0,
};

pub const Store = struct {
    items: [max_doors]Door = undefined,
    used: [max_doors]bool = .{false} ** max_doors,

    pub fn get(self: *Store, x: i32, y: i32, z: i32) ?*Door {
        for (self.items[0..], self.used[0..]) |*d, u| {
            if (u and d.x == x and d.y == y and d.z == z) return d;
        }
        return null;
    }

    pub fn getOrCreate(self: *Store, x: i32, y: i32, z: i32, block_id: u16) ?*Door {
        if (self.get(x, y, z)) |d| {
            d.block_id = block_id;
            return d;
        }
        for (self.items[0..], self.used[0..]) |*d, *u| {
            if (!u.*) {
                u.* = true;
                d.* = .{ .x = x, .y = y, .z = z, .block_id = block_id };
                return d;
            }
        }
        return null;
    }

    pub fn removeAt(self: *Store, x: i32, y: i32, z: i32) bool {
        for (self.items[0..], self.used[0..]) |*d, *u| {
            if (u.* and d.x == x and d.y == y and d.z == z) {
                u.* = false;
                d.* = .{};
                return true;
            }
        }
        return false;
    }

    pub fn count(self: *const Store) usize {
        var n: usize = 0;
        for (self.used) |u| {
            if (u) n += 1;
        }
        return n;
    }

    /// Persisted record: cell, block, lock length, the lock blob, the auto-close
    /// deadline. Fixed size so a truncated tail is a clean reject.
    const persisted_record_size: usize = 12 + 4 + 2 + containers.max_lock_feature_bytes + 8;

    /// Persist every stored door to {dir}/doors.zdr (ZDR1), sorted by cell so
    /// the bytes do not depend on slot order. Best-effort like the other saves.
    pub fn save(self: *const Store, dir: []const u8, allocator: std.mem.Allocator) !void {
        var path: [512]u8 = undefined;
        const p = try std.fmt.bufPrint(&path, "{s}/doors.zdr", .{dir});
        const buf = try allocator.alloc(u8, 4 + 2 + max_doors * persisted_record_size);
        defer allocator.free(buf);
        @memcpy(buf[0..4], "ZDR1");
        var o: usize = 6;
        var idxs: [max_doors]u16 = undefined;
        var n_idx: usize = 0;
        for (self.used, 0..) |u, i| {
            if (!u) continue;
            idxs[n_idx] = @intCast(i);
            n_idx += 1;
        }
        std.mem.sort(u16, idxs[0..n_idx], self, struct {
            fn less(store: *const Store, a: u16, b: u16) bool {
                const da = store.items[a];
                const db = store.items[b];
                if (da.x != db.x) return da.x < db.x;
                if (da.y != db.y) return da.y < db.y;
                return da.z < db.z;
            }
        }.less);
        var n_records: u16 = 0;
        for (idxs[0..n_idx]) |ii| {
            const d = &self.items[ii];
            if (o + persisted_record_size > buf.len) break;
            std.mem.writeInt(i32, buf[o..][0..4], d.x, .little);
            std.mem.writeInt(i32, buf[o + 4 ..][0..4], d.y, .little);
            std.mem.writeInt(i32, buf[o + 8 ..][0..4], d.z, .little);
            std.mem.writeInt(u32, buf[o + 12 ..][0..4], d.block_id, .little);
            std.mem.writeInt(u16, buf[o + 16 ..][0..2], d.lock_len, .little);
            @memcpy(buf[o + 18 ..][0..containers.max_lock_feature_bytes], &d.lock_blob);
            std.mem.writeInt(u64, buf[o + 18 + containers.max_lock_feature_bytes ..][0..8], d.close_at, .little);
            o += Store.persisted_record_size;
            n_records += 1;
        }
        std.mem.writeInt(u16, buf[4..6], n_records, .little);
        try io_fs.writeFile(p, buf[0..o]);
    }

    /// Decode a ZDR1 buffer. A bad magic, a short header or a record past the
    /// end is rejected whole.
    pub fn loadFromSlice(self: *Store, buf: []const u8) !void {
        if (buf.len < 6 or !std.mem.eql(u8, buf[0..4], "ZDR1")) return error.ReadFailed;
        const n_records = std.mem.readInt(u16, buf[4..6], .little);
        var o: usize = 6;
        var i: usize = 0;
        while (i < n_records) : (i += 1) {
            if (o + persisted_record_size > buf.len) return error.ReadFailed;
            const x = std.mem.readInt(i32, buf[o..][0..4], .little);
            const y = std.mem.readInt(i32, buf[o + 4 ..][0..4], .little);
            const z = std.mem.readInt(i32, buf[o + 8 ..][0..4], .little);
            const block_id: u16 = @intCast(std.mem.readInt(u32, buf[o + 12 ..][0..4], .little));
            const lock_len = std.mem.readInt(u16, buf[o + 16 ..][0..2], .little);
            if (lock_len > containers.max_lock_feature_bytes) return error.ReadFailed;
            const d = self.getOrCreate(x, y, z, block_id) orelse return error.ReadFailed;
            d.lock_len = lock_len;
            @memcpy(&d.lock_blob, buf[o + 18 ..][0..containers.max_lock_feature_bytes]);
            d.close_at = std.mem.readInt(u64, buf[o + 18 + containers.max_lock_feature_bytes ..][0..8], .little);
            o += Store.persisted_record_size;
        }
    }

    /// Load {dir}/doors.zdr. A missing file is a fresh world.
    pub fn load(self: *Store, dir: []const u8, allocator: std.mem.Allocator) !void {
        var path: [512]u8 = undefined;
        const p = try std.fmt.bufPrint(&path, "{s}/doors.zdr", .{dir});
        const buf = io_fs.readFileAll(allocator, p) catch |e| switch (e) {
            error.FileNotFound => return error.OpenFailed,
            else => return e,
        };
        defer allocator.free(buf);
        try self.loadFromSlice(buf);
    }
};

test "ZDR1 round-trips a door lock" {
    var a: Store = .{};
    const d = a.getOrCreate(3, 70, 4, 901).?;
    d.lock_blob[0] = 7;
    d.lock_len = 6;
    d.close_at = 4242;
    const buf = try std.testing.allocator.alloc(u8, 4 + 2 + max_doors * Store.persisted_record_size);
    defer std.testing.allocator.free(buf);
    @memcpy(buf[0..4], "ZDR1");
    var o: usize = 6;
    std.mem.writeInt(i32, buf[o..][0..4], 3, .little);
    std.mem.writeInt(i32, buf[o + 4 ..][0..4], 70, .little);
    std.mem.writeInt(i32, buf[o + 8 ..][0..4], 4, .little);
    std.mem.writeInt(u32, buf[o + 12 ..][0..4], 901, .little);
    std.mem.writeInt(u16, buf[o + 16 ..][0..2], 6, .little);
    @memset(buf[o + 18 .. o + 18 + containers.max_lock_feature_bytes], 0);
    buf[o + 18] = 7;
    std.mem.writeInt(u64, buf[o + 18 + containers.max_lock_feature_bytes ..][0..8], 4242, .little);
    o += Store.persisted_record_size;
    std.mem.writeInt(u16, buf[4..6], 1, .little);

    var b: Store = .{};
    try b.loadFromSlice(buf[0..o]);
    const rb = b.get(3, 70, 4).?;
    try std.testing.expectEqual(@as(u16, 901), rb.block_id);
    try std.testing.expectEqual(@as(u16, 6), rb.lock_len);
    try std.testing.expectEqual(@as(u8, 7), rb.lock_blob[0]);
    try std.testing.expectEqual(@as(u64, 4242), rb.close_at);

    var bad = buf[0..o];
    bad[0] = 'X';
    try std.testing.expectError(error.ReadFailed, b.loadFromSlice(bad));
    try std.testing.expectError(error.ReadFailed, b.loadFromSlice(buf[0 .. o - 1]));
}

test "door store keeps a lock blob per cell" {
    var s: Store = .{};
    const d = s.getOrCreate(1, 70, 2, 900).?;
    d.lock_blob[0] = 1;
    d.lock_len = 6;
    try std.testing.expectEqual(@as(u16, 900), s.get(1, 70, 2).?.block_id);
    try std.testing.expectEqual(@as(u16, 6), s.get(1, 70, 2).?.lock_len);
    try std.testing.expectEqual(@as(usize, 1), s.count());
    try std.testing.expect(s.removeAt(1, 70, 2));
    try std.testing.expectEqual(@as(usize, 0), s.count());
}
