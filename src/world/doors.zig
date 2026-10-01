//! Door tile-entity state: the `TEFeatureDoor` / `TEFeatureLockable` pair on a
//! composite door (doors, gates, hatches).
//!
//! Stock keeps the door's open flag and lock in its `TileEntityComposite`; the
//! open flag also lives in the block meta (which every client already syncs), so
//! this store exists for the part the meta does not carry: the lock blob that
//! makes another player's client show a locked door as locked.
//!
//! Non-goals: the auto-close timer, the drawbridge and honk-open halves of
//! `TEFeatureDoor`, and the door mesh/animation state (client-owned).
const std = @import("std");
const containers = @import("containers.zig");

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
};

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
