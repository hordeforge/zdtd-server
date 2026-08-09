//! Deep-void rescue extracted from game.zig.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");

pub fn rescueDeepVoid(self: *Game, peer: *ln_peer.Peer, entity_id: i32, x: f32, y: f32, z: f32, do_teleport: bool) !?f32 {
    const gx: i32 = std.math.lossyCast(i32, @floor(x));
    const gz: i32 = std.math.lossyCast(i32, @floor(z));
    const h_u16: u16 = self.world.heightWorld(gx, gz) catch @intCast(@max(1, self.world.primarySpawn().y));
    const surface: f32 = @floatFromInt(h_u16);
    const min_y = surface + 0.9;
    if (!(y < -1.0)) return null;
    self.sim.setPos(entity_id, x, min_y, z, 0);
    if (do_teleport) {
        if (packages.buildEntityTeleportBody(&self.body_buf, entity_id, x, min_y, z, 0, 0, 0, true)) |tb| {
            try self.sendGame(peer, "NetPackageEntityTeleport", tb);
        } else |_| {}
    }
    return min_y;
}

pub fn withinEditReach(self: *const Game, px: f32, py: f32, pz: f32, bx: f32, by: f32, bz: f32) bool {
    const dx = px - bx;
    const dy = py - by;
    const dz = pz - bz;
    return dx * dx + dy * dy + dz * dz <= self.max_edit_range * self.max_edit_range;
}
