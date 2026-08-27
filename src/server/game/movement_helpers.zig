//! Movement envelope helpers extracted from game.zig.
//! Power-grid trigger activation and horizontal speed envelope.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const protocol = @import("../../protocol.zig");
const movement = @import("../movement.zig");
const packages = @import("../../wire/packages.zig");

pub fn noteAcceptedMove(self: *Game, c: *Client, x: f32, y: f32, z: f32) void {
    c.move_valid = true;
    c.move_x = x;
    c.move_y = y;
    c.move_z = z;
    c.move_tick = self.tick_n;
    tryActivateTriggerAtPlayer(self, x, y, z);
}

fn tryActivateTriggerAtPlayer(self: *Game, x: f32, y: f32, z: f32) void {
    const bx: i32 = @floor(x);
    const by: i32 = @floor(y);
    const bz: i32 = @floor(z);
    _ = self.sim.power.activateTriggerAt(bx, by - 1, bz);
    _ = self.sim.power.activateTriggerAt(bx, by, bz);
}

pub fn resetMoveEnvelopePeer(self: *Game, peer_slot: usize, x: f32, y: f32, z: f32) void {
    if (peer_slot >= game_mod.max_clients) return;
    const c = &self.clients[peer_slot];
    c.move_valid = false;
    c.move_x = x;
    c.move_y = y;
    c.move_z = z;
    c.move_tick = self.tick_n;
}

pub const ApplyResult = struct { x: f32, y: f32, z: f32, applied: bool };
pub fn applyMovementEnvelope(self: *Game, c: *Client, peer: *ln_peer.Peer, entity_id: i32, x: f32, y: f32, z: f32) ApplyResult {
    if (!c.move_valid) {
        return .{ .x = x, .y = y, .z = z, .applied = true };
    }
    const tick_s: f32 = @as(f32, @floatFromInt(protocol.tick_ns)) / 1_000_000_000.0;
    const dt = movement.dtFromTicks(c.move_tick, self.tick_n, tick_s);
    const cap = self.max_horizontal_speed_mps;
    const clamp = movement.clampHorizontal(c.move_x, c.move_z, x, z, dt, cap);
    // Vertical cap: the horizontal clamp cannot see Y-only teleports (fly
    // hacking), so the Y delta is bounded the same way with its own cap.
    const vclamp = movement.clampVertical(c.move_y, y, dt, self.max_vertical_speed_mps);
    if (!clamp.clamped and !vclamp.clamped) {
        return .{ .x = x, .y = y, .z = z, .applied = true };
    }
    self.harness.counters.inc(.movement_rejects);
    self.noteEvidence(c, peer.local_id, entity_id, .movement, .strong, .none, cap, cap);
    const n = self.harness.counters.get(.movement_rejects);
    if (n == 1 or n % 100 == 0) {
        std.debug.print("zdtd: movement envelope reject n={d} local_id={d} entity={d}\n", .{ n, peer.local_id, entity_id });
    }
    if (self.authority_mode != .correct) {
        return .{ .x = x, .y = y, .z = z, .applied = true };
    }
    if (packages.buildPosAndRotBody(self.body_buf[0..64], entity_id, clamp.x, vclamp.y, clamp.z, 0, 0, 0, true)) |sb| {
        self.sendGame(peer, "NetPackageEntityPosAndRot", sb) catch {};
    } else |_| {}
    return .{ .x = clamp.x, .y = vclamp.y, .z = clamp.z, .applied = true };
}
