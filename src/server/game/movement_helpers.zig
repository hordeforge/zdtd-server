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
    // Server-derived vertical velocity (ADR 0037): delta over the server dt
    // from the last accepted move. Signed blocks/s (positive = rising);
    // feeds the sense v4 record (no sim-side player physics model).
    if (c.move_valid) {
        const tick_s: f32 = @as(f32, @floatFromInt(protocol.tick_ns)) / 1_000_000_000.0;
        const dt = movement.dtFromTicks(c.move_tick, self.tick_n, tick_s);
        c.vy_blocks_per_s = if (dt > 0) (y - c.move_y) / dt else 0;
    } else {
        c.vy_blocks_per_s = 0;
    }
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
    // Rule 20: range-check untrusted movement. NaN/Inf and any coordinate
    // beyond the ceiling are rejected (never clamped): the sim transform must
    // not hold a value that traps the tick-path @trunc casts (radius
    // scans, trigger activation), and clamping an attacker's coordinate would
    // still "teleport" them to the ceiling. The first packet after spawn
    // applies directly (move_valid=false), so this must run before that arm.
    if (!game_mod.coordInRange(x) or !game_mod.coordInRange(y) or !game_mod.coordInRange(z)) {
        self.harness.counters.inc(.bounds_rejects);
        return .{ .x = x, .y = y, .z = z, .applied = false };
    }
    if (!c.move_valid) {
        return .{ .x = x, .y = y, .z = z, .applied = true };
    }
    const tick_s: f32 = @as(f32, @floatFromInt(protocol.tick_ns)) / 1_000_000_000.0;
    const dt = movement.dtFromTicks(c.move_tick, self.tick_n, tick_s);
    const cap = self.max_horizontal_speed_mps;
    const clamp = movement.clampHorizontal(c.move_x, c.move_z, x, z, dt, cap);
    // Vertical cap: the horizontal clamp cannot see Y-only teleports (fly
    // hacking), so the Y delta is bounded the same way with its own cap.
    // Glide (ADR 0037): while the player's glide flag is armed the server
    // CLAMPS the vertical delta to the glide sink speed (blocks/s) instead of
    // rejecting it - the clamped position is broadcast back to the player and
    // observers, so the fall is slowed server-side (no client mod needed).
    // A teleport-scale jump is still rejected even gliding. Fail closed: flag
    // unset or expired -> stock envelope.
    var vcap = self.max_vertical_speed_mps;
    if (self.sim.slotOfNetId(entity_id)) |s| {
        if (self.sim.mask[s].player) {
            // Glide flag (parachute) first; else the global fall sink (e.g.
            // the moon_gravity mod's lunar terminal velocity); else stock.
            if (self.sim.player[s].glide_until_tick > self.sim.sim_tick) {
                vcap = self.sim.rules.glide.sink_vy_mps;
            } else if (self.sim.rules.glide.fall_sink_vy_mps > 0) {
                vcap = self.sim.rules.glide.fall_sink_vy_mps;
            }
        }
    }
    const vclamp = movement.clampVertical(c.move_y, y, dt, vcap);
    if (!clamp.clamped and !vclamp.clamped) {
        return .{ .x = x, .y = y, .z = z, .applied = true };
    }
    // The observed violation is evidence in every mode (the evidence ring is
    // the honest "seen it" record); the movement_rejects counter and its log
    // mean ENFORCED rejections, so observe (permissive - the guard never
    // denies there, AUTHORITY.md "observe records but never denies") must not
    // count: the dashboard would claim protection observe does not provide
    // (T19). Correct mode clamps + snaps below.
    self.noteEvidence(c, peer.local_id, entity_id, .movement, .strong, .none, cap, cap);
    if (self.authority_mode != .correct) {
        return .{ .x = x, .y = y, .z = z, .applied = true };
    }
    self.harness.counters.inc(.movement_rejects);
    const n = self.harness.counters.get(.movement_rejects);
    if (n == 1 or n % 100 == 0) {
        std.debug.print("zdtd: movement envelope reject n={d} local_id={d} entity={d}\n", .{ n, peer.local_id, entity_id });
    }
    if (packages.buildPosAndRotBody(self.body_buf[0..64], entity_id, clamp.x, vclamp.y, clamp.z, 0, 0, 0, true)) |sb| {
        self.sendGame(peer, "NetPackageEntityPosAndRot", sb) catch {};
    } else |_| {}
    return .{ .x = clamp.x, .y = vclamp.y, .z = clamp.z, .applied = true };
}
