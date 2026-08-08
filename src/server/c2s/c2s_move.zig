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
    if (std.mem.eql(u8, name, "NetPackageEntityAnimationData")) {
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
                    const dx = bp.x - pp.x;
                    const dy = bp.y - pp.y;
                    const dz = bp.z - pp.z;
                    if (dx * dx + dy * dy + dz * dz > self.max_edit_range * self.max_edit_range) {
                        self.harness.counters.inc(.bounds_rejects);
                        return true;
                    }
                    if (self.sim.mask[ps].inventory and self.sim.mask[bs].inventory) {
                        // Same transfer rule as systems.collectLootNear: only a
                        // full deposit destroys the bag; a partial one restores
                        // the player inventory and keeps the bag alive so the
                        // rest is not silently deleted.
                        const inventory_before = self.sim.inventory[ps];
                        var transferred = true;
                        for (self.sim.inventory[bs].slots) |slot| {
                            if (slot.count == 0 or slot.item_id == 0) continue;
                            if (!self.sim.depositItem(ps, slot.item_id, slot.count)) {
                                transferred = false;
                                break;
                            }
                        }
                        if (!transferred) {
                            self.sim.inventory[ps] = inventory_before;
                            return true;
                        }
                        for (self.sim.inventory[bs].slots) |slot| {
                            if (slot.count == 0 or slot.item_id == 0) continue;
                            const d: i16 = @intCast(@min(slot.count, std.math.maxInt(i16)));
                            const p: u16 = if (c.slot > std.math.maxInt(u16)) std.math.maxInt(u16) else @intCast(c.slot);
                            self.sim.inv_ledger.record(p, slot.item_id, d, .loot);
                        }
                        self.sim.markDirty(ps, .{ .inv = true });
                    }
                }
                if (self.sim.alive[bs]) self.sim.destroy(bs);
                if (packages.buildEntityCollectBody(self.body_buf[0..16], bag, c.entity_id)) |cb| {
                    try self.broadcast("NetPackageEntityCollect", cb);
                } else |_| {}
                if (packages.buildRemoveBodyReason(&self.body_buf, bag, .despawned)) |rm| {
                    try self.broadcast("NetPackageEntityRemove", rm);
                } else |_| {}
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
        if (self.sim.slotOfNetId(f.entity_id)) |idx| self.sim.flags[idx].bits = f.flags;
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
        c.sprint_speed = if (s.movement_state == 3) s.speed_forward else 0;
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
        // position up on the next motion pass rather than the raw claim.
        if (env.x == p.x and env.z == p.z) {
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
