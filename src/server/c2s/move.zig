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

fn sprintMagnitude(movement_state: u8, speed_forward: f32, speed_strafe: f32) f32 {
    if (movement_state != 3) return 0;
    return @max(@abs(speed_forward), @abs(speed_strafe));
}

/// True when `name` belongs to this domain and was handled.
pub fn handle(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (std.mem.eql(u8, name, "NetPackageEntityPosAndRot")) {
        const p = packages.parsePosAndRotBody(body) catch {
            self.harness.counters.inc(.decode_rejects);
            return true;
        };
        if (p.entity_id != c.entity_id) {
            self.harness.counters.inc(.ownership_rejects);
            return true;
        }
        const env = self.applyMovementEnvelope(c, peer, p.entity_id, p.x, p.y, p.z);
        if (!env.applied) return true;
        // Void rescue only (surface-2 snap desynced mesh; see rescueDeepVoid).
        if (try self.rescueDeepVoid(peer, p.entity_id, env.x, env.y, env.z, true)) |ny| {
            self.noteAcceptedMove(c, env.x, ny, env.z);
            systems.questTickGoto(&self.sim, c.slot, env.x, ny, env.z);
            systems.questTickStayWithin(&self.sim, c.slot, env.x, env.z);
            return true;
        }
        // Keep the stored facing: the absolute package's rotation is not
        // parsed into the column, so passing 0 would fabricate a north
        // facing on every move (RelPos preserves it). setPos marks dirty.
        var yaw: f32 = 0;
        if (self.sim.slotOfNetId(p.entity_id)) |si| yaw = self.sim.transform[si].yaw;
        self.sim.setPos(p.entity_id, env.x, env.y, env.z, yaw);
        self.noteAcceptedMove(c, env.x, env.y, env.z);
        systems.questTickGoto(&self.sim, c.slot, env.x, env.y, env.z);
        systems.questTickStayWithin(&self.sim, c.slot, env.x, env.z);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageEntityCollect")) {
        const bag = packages.parseCollectBody(body) catch return true;
        // Transfer contents into server inv, then destroy. Wire order matches
        // stock: Collect (client OnCollect) then EntityRemove(Despawned).
        if (self.sim.slotOfNetId(bag)) |bs| {
            const is_loot = self.sim.kind[bs] == .loot_bag or self.sim.mask[bs].loot_bag;
            if (is_loot) {
                if (self.sim.playerByPeer(c.slot)) |ps| {
                    const pp = self.sim.transform[ps];
                    const bp = self.sim.transform[bs];
                    if (!self.withinEditReach(pp.x, pp.y, pp.z, bp.x, bp.y, bp.z)) {
                        self.harness.counters.inc(.bounds_rejects);
                        return true;
                    }
                    // Full deposit only: a partial one restores the player
                    // inventory and keeps the bag alive (ecs.inventory
                    // collectBagFull, the one transfer rule shared with
                    // systems.collectLootNear).
                    if (!ecs.inventory.collectBagFull(&self.sim, c.slot, bs)) return true;
                }
                const bx = self.sim.transform[bs].x;
                const by = self.sim.transform[bs].y;
                const bz = self.sim.transform[bs].z;
                if (self.sim.alive[bs]) self.sim.destroy(bs);
                if (packages.buildEntityCollectBody(self.body_buf[0..16], bag, c.entity_id)) |cb| {
                    try self.broadcast("NetPackageEntityCollect", cb);
                } else |_| {}
                if (packages.buildRemoveBodyReason(&self.body_buf, bag, .despawned)) |rm| {
                    try self.broadcast("NetPackageEntityRemove", rm);
                } else |_| {}
                // Collected the player's own death bag: clear the backpack
                // marker and tell every client (RE EntityBackpack).
                if (self.clients[c.slot].has_backpack and
                    self.clients[c.slot].backpack_x == @as(i32, @trunc(bx)) and
                    self.clients[c.slot].backpack_y == @as(i32, @trunc(by)) and
                    self.clients[c.slot].backpack_z == @as(i32, @trunc(bz)))
                {
                    self.clients[c.slot].has_backpack = false;
                    try self.broadcastPlayerBackpack(&self.clients[c.slot]);
                }
            }
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageEntityRelPosAndRot")) {
        if (body.len < 20 or c.entity_id <= 0) {
            if (body.len < 20) self.harness.counters.inc(.decode_rejects);
            return true;
        }
        const eid = std.mem.readInt(i32, body[0..4], .little);
        if (eid != c.entity_id) {
            self.harness.counters.inc(.ownership_rejects);
            return true;
        }
        const dx = std.mem.readInt(i16, body[11..13], .little);
        const dy = std.mem.readInt(i16, body[13..15], .little);
        const dz = std.mem.readInt(i16, body[15..17], .little);
        if (self.sim.slotOfNetId(eid)) |idx| {
            // RelPos delta scale (RE protocol-packages.md 5.5.4): dPos is the
            // client's movement delta encoded in 1/32-block i16 units.
            const scale: f32 = 0.03125;
            const nx = self.sim.transform[idx].x + @as(f32, @floatFromInt(dx)) * scale;
            const ny = self.sim.transform[idx].y + @as(f32, @floatFromInt(dy)) * scale;
            const nz = self.sim.transform[idx].z + @as(f32, @floatFromInt(dz)) * scale;
            if (!std.math.isFinite(nx) or !std.math.isFinite(ny) or !std.math.isFinite(nz)) {
                self.harness.counters.inc(.decode_rejects);
                return true;
            }
            const env = self.applyMovementEnvelope(c, peer, eid, nx, ny, nz);
            if (!env.applied) return true;
            const yaw = self.sim.transform[idx].yaw;
            self.sim.setPos(eid, env.x, env.y, env.z, yaw);
            // RelPos can walk Y into void without absolute PosAndRot; re-snap.
            if (try self.rescueDeepVoid(peer, eid, env.x, env.y, env.z, true)) |ry| {
                self.noteAcceptedMove(c, env.x, ry, env.z);
            } else {
                self.noteAcceptedMove(c, env.x, env.y, env.z);
            }
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageEntityAliveFlags")) {
        const f = packages.parseAliveFlagsBody(body) catch {
            self.harness.counters.inc(.decode_rejects);
            return true;
        };
        if (f.entity_id != c.entity_id) {
            self.harness.counters.inc(.ownership_rejects);
            return true;
        }
        if (self.sim.slotOfNetId(f.entity_id)) |idx| {
            // Store the client-reported word verbatim (stock relay mirror).
            // Server-side decisions never read these stored bits: crouch is
            // derived from the package directly below, and the S2C flags word
            // for AI entities is built from sim state in replicate.zig.
            self.sim.flags[idx].bits = f.flags;
            // Stealth (RE entity-ai.md PlayerStealth): the client reports its
            // crouch in this flags word (bit 512); the AI sense gates muffle
            // hearing and shrink sleeper detect for crouched players.
            if (self.sim.mask[idx].player) {
                self.sim.player[idx].crouching = (f.flags & packages.cF_crouching) != 0;
            }
        }
        // Fan-out to other peers (stock tracked-players path).
        try self.broadcastExcept("NetPackageEntityAliveFlags", body, c.slot);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageEntitySpeeds")) {
        const s = packages.parseEntitySpeedsBody(body) catch {
            self.harness.counters.inc(.decode_rejects);
            return true;
        };
        if (s.entity_id != c.entity_id) {
            self.harness.counters.inc(.ownership_rejects);
            return true;
        }
        // Sprint state for the stamina drain (MovementState 3 = sprint/aggro,
        // entity-ai.md SetMovementState); lapses on a stale timer.
        c.sprint_speed = sprintMagnitude(s.movement_state, s.speed_forward, s.speed_strafe);
        c.sprint_stale_cd = self.sim.rules.progression.sprint_stale_seconds;
        try self.broadcastExcept("NetPackageEntitySpeeds", body, c.slot);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageEntityTeleport")) {
        const p = packages.parsePosAndRotBody(body) catch {
            self.harness.counters.inc(.decode_rejects);
            return true;
        };
        if (p.entity_id != c.entity_id) {
            self.harness.counters.inc(.ownership_rejects);
            return true;
        }
        // Same speed envelope as PosAndRot: without it a client teleports
        // anywhere and noteAcceptedMove rebaselines the gate to that spot.
        const env = self.applyMovementEnvelope(c, peer, p.entity_id, p.x, p.y, p.z);
        if (!env.applied) return true;
        if (try self.rescueDeepVoid(peer, p.entity_id, env.x, env.y, env.z, false)) |ny| {
            // Snapped; do not fan-out void coords.
            self.noteAcceptedMove(c, env.x, ny, env.z);
            return true;
        }
        var yaw: f32 = 0;
        if (self.sim.slotOfNetId(p.entity_id)) |si| yaw = self.sim.transform[si].yaw;
        self.sim.setPos(p.entity_id, env.x, env.y, env.z, yaw);
        self.noteAcceptedMove(c, env.x, env.y, env.z);
        // Clamped: the owner already got a correction; peers pick the true
        // position up on the next motion pass rather than the raw claim. The
        // gate checks all three axes: a Y-only clamp (fly attempt) must not
        // relay the raw teleport Y to peers either.
        if (env.x == p.x and env.y == p.y and env.z == p.z) {
            try self.broadcastExcept("NetPackageEntityTeleport", body, c.slot);
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageEntityAddVelocity")) {
        if (body.len >= 4) {
            const eid = std.mem.readInt(i32, body[0..4], .little);
            if (eid != c.entity_id) return true;
            if (self.sim.slotOfNetId(eid)) |si| {
                self.sim.markDirty(si, .{ .pos = true });
            }
        }
        return true;
    }
    return false;
}

test "sprint magnitude covers backward and strafe movement" {
    try std.testing.expectEqual(@as(f32, 4), sprintMagnitude(3, -4, 0));
    try std.testing.expectEqual(@as(f32, 3), sprintMagnitude(3, 0, -3));
    try std.testing.expectEqual(@as(f32, 0), sprintMagnitude(2, 6, 6));
}
