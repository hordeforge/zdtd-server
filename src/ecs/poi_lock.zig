//! Quest POI lockout table: the server half of QuestEventManager's
//! PrefabInstance.lockInstance (QuestLockInstance, asm.il 1001892-1002045).
//! A locked POI belongs to the questers that activated it; when the last one
//! leaves, the POI stays locked out until `world_time + unlock_grace`.

const std = @import("std");
const c = @import("components.zig");

/// QuestEventManager.POILockoutReasonTypes (asm.il 993966-993970).
pub const LockReason = enum(u8) {
    none = 0,
    player_inside = 1,
    bedroll = 2,
    land_claim = 3,
    quest_lock = 4,
};

/// QuestLockInstance.SetUnlocked: LockedOutUntil = worldTime + 0x7d0 (asm.il 1002020).
pub const unlock_grace: u64 = 2000;

/// Fixed capacity: the table is grown from client packets, so it must not be
/// an unbounded allocation a peer can drive.
pub const max_locks: usize = 64;
/// Questers tracked per POI (stock keeps an unbounded list; a shared quest
/// party is small and extra questers only make the lock outlive them).
pub const max_questers: usize = 8;

pub const Lock = struct {
    rect: c.PoiRect = .{},
    questers: [max_questers]i32 = [_]i32{0} ** max_questers,
    quester_n: u8 = 0,
    /// QuestLockInstance.IsLocked.
    locked: bool = false,
    /// QuestLockInstance.LockedOutUntil (0 while questers are inside).
    locked_out_until: u64 = 0,

    fn hasQuester(self: *const Lock, entity_id: i32) bool {
        for (self.questers[0..self.quester_n]) |q| {
            if (q == entity_id) return true;
        }
        return false;
    }

    fn addQuester(self: *Lock, entity_id: i32) void {
        if (self.hasQuester(entity_id)) return;
        if (self.quester_n >= max_questers) return;
        self.questers[self.quester_n] = entity_id;
        self.quester_n += 1;
    }

    fn removeQuester(self: *Lock, entity_id: i32, world_time: u64) void {
        var i: usize = 0;
        while (i < self.quester_n) : (i += 1) {
            if (self.questers[i] != entity_id) continue;
            self.questers[i] = self.questers[self.quester_n - 1];
            self.quester_n -= 1;
            break;
        }
        // QuestLockInstance.RemoveQuester: last quester out starts the grace.
        if (self.quester_n == 0 and self.locked) {
            self.locked = false;
            self.locked_out_until = world_time +| unlock_grace;
        }
    }

    /// QuestLockInstance.CheckQuestLock (asm.il 1002026): true = removable.
    fn expired(self: *const Lock, world_time: u64) bool {
        return !self.locked and world_time > self.locked_out_until;
    }
};

pub const Table = struct {
    entries: [max_locks]Lock = [_]Lock{.{}} ** max_locks,
    n: usize = 0,

    fn indexAt(self: *Table, x: f32, z: f32) ?usize {
        for (self.entries[0..self.n], 0..) |*e, i| {
            if (e.rect.containsXZ(x, z)) return i;
        }
        return null;
    }

    fn remove(self: *Table, i: usize) void {
        self.entries[i] = self.entries[self.n - 1];
        self.n -= 1;
    }

    /// Lock `rect` for `entity_id`. An existing live lock only gains a quester;
    /// an expired one is replaced. False = table full (lock refused, not faked).
    pub fn lock(self: *Table, rect: c.PoiRect, entity_id: i32, world_time: u64) bool {
        if (!rect.valid()) return false;
        if (self.indexAt(rect.x, rect.z)) |i| {
            if (!self.entries[i].expired(world_time)) {
                self.entries[i].addQuester(entity_id);
                return true;
            }
            self.remove(i);
        }
        if (self.n >= max_locks) {
            // Table full for a *different* rect: reclaim the first expired
            // entry rather than refusing new locks forever once every slot
            // has been touched once (nothing else ever sweeps this table).
            var reclaimed = false;
            var i: usize = 0;
            while (i < self.n) : (i += 1) {
                if (self.entries[i].expired(world_time)) {
                    self.remove(i);
                    reclaimed = true;
                    break;
                }
            }
            if (!reclaimed) return false;
        }
        self.entries[self.n] = .{ .rect = rect, .locked = true };
        self.entries[self.n].addQuester(entity_id);
        self.n += 1;
        return true;
    }

    /// QuestEventManager.QuestUnlockPOI (asm.il 998930): drop one quester.
    pub fn unlock(self: *Table, x: f32, z: f32, entity_id: i32, world_time: u64) void {
        const i = self.indexAt(x, z) orelse return;
        self.entries[i].removeQuester(entity_id, world_time);
    }

    /// Lock state at (x,z) as CheckForPOILockouts sees it (asm.il 998957-999010):
    /// an expired instance is dropped first, a surviving one reports QuestLock
    /// with LockedOutUntil as extraData. Returns null when the POI is free.
    pub fn check(self: *Table, x: f32, z: f32, world_time: u64) ?u64 {
        const i = self.indexAt(x, z) orelse return null;
        if (self.entries[i].expired(world_time)) {
            self.remove(i);
            return null;
        }
        return self.entries[i].locked_out_until;
    }
};

test "poi lock blocks until the last quester leaves and the grace expires" {
    var t: Table = .{};
    const rect: c.PoiRect = .{ .x = 100, .z = 200, .size_x = 40, .size_y = 20, .size_z = 30 };
    try std.testing.expect(t.check(110, 210, 0) == null);
    try std.testing.expect(t.lock(rect, 171, 0));
    try std.testing.expectEqual(@as(?u64, 0), t.check(110, 210, 0));
    // A second quester keeps the lock alive after the first one unlocks.
    try std.testing.expect(t.lock(rect, 172, 0));
    t.unlock(110, 210, 171, 100);
    try std.testing.expectEqual(@as(?u64, 0), t.check(110, 210, 100));
    t.unlock(110, 210, 172, 100);
    // Grace window still reports locked, extraData = LockedOutUntil.
    try std.testing.expectEqual(@as(?u64, 100 + unlock_grace), t.check(110, 210, 500));
    try std.testing.expect(t.check(110, 210, 100 + unlock_grace + 1) == null);
    try std.testing.expectEqual(@as(usize, 0), t.n);
}

test "poi lock is bounded to its rect and to max_locks" {
    var t: Table = .{};
    const rect: c.PoiRect = .{ .x = 0, .z = 0, .size_x = 10, .size_y = 10, .size_z = 10 };
    try std.testing.expect(t.lock(rect, 1, 0));
    // Max edge is exclusive, min edge inclusive (stock Rect.Contains).
    try std.testing.expect(t.check(0, 0, 0) != null);
    try std.testing.expect(t.check(9.99, 9.99, 0) != null);
    try std.testing.expect(t.check(10, 5, 0) == null);
    try std.testing.expect(t.check(-1, 5, 0) == null);
    // A zero-size rect is not a POI and must never take a slot.
    try std.testing.expect(!t.lock(.{}, 2, 0));
    try std.testing.expectEqual(@as(usize, 1), t.n);
    var i: usize = 1;
    while (i < max_locks) : (i += 1) {
        const r: c.PoiRect = .{ .x = @floatFromInt(i * 100), .z = 0, .size_x = 10, .size_y = 10, .size_z = 10 };
        try std.testing.expect(t.lock(r, @intCast(i), 0));
    }
    const overflow: c.PoiRect = .{ .x = 1_000_000, .z = 0, .size_x = 10, .size_y = 10, .size_z = 10 };
    try std.testing.expect(!t.lock(overflow, 999, 0));
    try std.testing.expectEqual(max_locks, t.n);
}

test "unlocking an unknown poi is a no-op" {
    var t: Table = .{};
    t.unlock(5, 5, 171, 0);
    try std.testing.expectEqual(@as(usize, 0), t.n);
    // Re-locking after expiry replaces the dead entry instead of stacking.
    const rect: c.PoiRect = .{ .x = 0, .z = 0, .size_x = 8, .size_y = 8, .size_z = 8 };
    try std.testing.expect(t.lock(rect, 1, 0));
    t.unlock(1, 1, 1, 0);
    try std.testing.expect(t.lock(rect, 2, unlock_grace + 1));
    try std.testing.expectEqual(@as(usize, 1), t.n);
    try std.testing.expectEqual(@as(u8, 1), t.entries[0].quester_n);
}
