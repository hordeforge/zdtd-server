//! Named tick scratch on World. No file-static mutables for sim.
//! Cleared once per tick via World.beginTick / schedule.run.

const Slot = @import("entity.zig").Slot;
const NetId = @import("entity.zig").NetId;

/// Fixed interest / despawn id scratch (caller fills; schedule clears n).
pub const max_interest_ids: usize = 64;
pub const max_despawn_ids: usize = 8;
pub const max_kill_ids: usize = 16;

/// Per-tick scratch owned by World.systems schedule. No heap.
pub const TickLocals = struct {
    interest_ids: [max_interest_ids]NetId = .{0} ** max_interest_ids,
    interest_n: u8 = 0,
    despawn_ids: [max_despawn_ids]NetId = .{0} ** max_despawn_ids,
    despawn_n: u8 = 0,
    kill_ids: [max_kill_ids]NetId = .{0} ** max_kill_ids,
    kill_n: u8 = 0,
    loot_bag_ids: [max_kill_ids]NetId = .{0} ** max_kill_ids,
    loot_n: u8 = 0,
    /// Scratch player slots for AI/turret snapshots (filled by systems).
    player_slots: [64]Slot = .{0} ** 64,
    player_n: u8 = 0,

    pub fn clear(self: *TickLocals) void {
        self.interest_n = 0;
        self.despawn_n = 0;
        self.kill_n = 0;
        self.loot_n = 0;
        self.player_n = 0;
    }
};

const std = @import("std");

test "TickLocals clear zeros counts" {
    var t: TickLocals = .{};
    t.interest_n = 3;
    t.despawn_n = 1;
    t.kill_n = 2;
    t.loot_n = 1;
    t.player_n = 4;
    t.clear();
    try std.testing.expectEqual(@as(u8, 0), t.interest_n);
    try std.testing.expectEqual(@as(u8, 0), t.despawn_n);
    try std.testing.expectEqual(@as(u8, 0), t.kill_n);
    try std.testing.expectEqual(@as(u8, 0), t.loot_n);
    try std.testing.expectEqual(@as(u8, 0), t.player_n);
}
