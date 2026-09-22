//! C2S movement and entity-state handling: absolute/relative position, the
//! animation no-op, loot-bag collect, alive flags, motion speeds (sprint
//! state), hard teleports and velocity pings.
//!
//! Extracted from game.zig's handlePackage following the replicate_te
//! precedent. `handle` returns true when the package name belongs to this
//! domain; handlePackage falls through to the remaining arms otherwise.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const ecs = @import("../../ecs/root.zig");
const systems = @import("../../ecs/systems.zig");
const move_position = @import("move_position.zig");
const move_state = @import("move_state.zig");

fn sprintMagnitude(movement_state: u8, speed_forward: f32, speed_strafe: f32) f32 {
    if (movement_state != 3) return 0;
    return @max(@abs(speed_forward), @abs(speed_strafe));
}

/// True when `name` belongs to this domain and was handled.
pub fn handle(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (try move_position.handlePosition(self, c, peer, name, body)) return true;
    if (try move_state.handleState(self, c, peer, name, body)) return true;
    return false;
}

test "sprint magnitude covers backward and strafe movement" {
    try std.testing.expectEqual(@as(f32, 4), sprintMagnitude(3, -4, 0));
    try std.testing.expectEqual(@as(f32, 3), sprintMagnitude(3, 0, -3));
    try std.testing.expectEqual(@as(f32, 0), sprintMagnitude(2, 6, 6));
}
