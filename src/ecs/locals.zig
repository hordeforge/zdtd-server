//! Named tick scratch on World. No file-static mutables for sim.
//! Cleared once per tick via World.beginTick / schedule.run.
//! The id-slot arrays that used to live here moved into the per-tick
//! `TickResult` (schedule.zig) / turret result (systems.zig); only the
//! counters survive until a caller needs them.

/// Per-tick scratch owned by World.systems schedule. No heap.
pub const TickLocals = struct {
    interest_n: u8 = 0,
    despawn_n: u8 = 0,
    kill_n: u8 = 0,
    loot_n: u8 = 0,
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
