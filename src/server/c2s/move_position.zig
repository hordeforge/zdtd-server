//! C2S movement arms: absolute/relative position, collect, alive flags.
//!
//! Split out of c2s/move.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const ecs = @import("../../ecs/root.zig");
const systems = @import("../../ecs/systems.zig");

/// True when `name` is a position package and was handled.
pub fn handlePosition(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
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
        // T22 suppression: the rescue is a server correction for a mesh
        // desync, never a cheat - reset the envelope so the interim client
        // packets (still falling before it processes the EntityTeleport) are
        // not counted as movement rejects against a legit player.
        if (try self.rescueDeepVoid(peer, p.entity_id, env.x, env.y, env.z, true)) |ny| {
            self.resetMoveEnvelopePeer(c.slot, env.x, ny, env.z);
            systems.questTickGoto(&self.sim, c.slot, env.x, env.z);
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
        systems.questTickGoto(&self.sim, c.slot, env.x, env.z);
        systems.questTickStayWithin(&self.sim, c.slot, env.x, env.z);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageEntityCollect")) {
        const col = packages.parseCollectBody(body) catch return true;
        const bag = col.entity_id;
        // ValidEntityIdForSender(playerId): stock discards a collect whose
        // claimed collector is not the sender (NetPackageEntityCollect
        // ProcessPackage IL=51), so one client cannot collect a bag in another
        // player's name.
        if (col.player_id != c.entity_id) {
            self.harness.counters.inc(.ownership_rejects);
            return true;
        }
        // Transfer contents into server inv, then destroy. Wire order matches
        // stock: Collect (client OnCollect) then EntityRemove(Despawned).
        if (self.sim.slotOfNetId(bag)) |bs| {
            const is_loot = self.sim.kind[bs] == .loot_bag or self.sim.mask[bs].loot_bag;
            if (is_loot) {
                if (self.sim.playerByPeer(c.slot)) |ps| {
                    const pp = self.sim.transform[ps];
                    const bp = self.sim.transform[bs];
                    if (self.rejectIfBeyondEditRange(
                        c,
                        peer.local_id,
                        c.entity_id,
                        .container,
                        pp.x,
                        pp.y,
                        pp.z,
                        bp.x,
                        bp.y,
                        bp.z,
                    )) return true;
                    // Full deposit only: a partial one restores the player
                    // inventory and keeps the bag alive (ecs.inventory
                    // collectBagFull, the one transfer rule shared with
                    // systems.collectLootNear).
                    if (!ecs.inventory.collectBagFull(&self.sim, c.slot, bs)) return true;
                }
                const bx = self.sim.transform[bs].x;
                const by = self.sim.transform[bs].y;
                const bz = self.sim.transform[bs].z;
                // An air-drop crate carries server-pushed markers, so the
                // server has to take them back: nothing on the client derives
                // them from the entity going away. Stock b10 removes both the
                // MapObject (EntitySupplyCrate.OnEntityDeath IL=30) and the
                // NavObject (OnEntityUnload -> RemoveSupplyCrate IL=54). Read
                // before destroy: the slot's components are gone afterwards.
                const was_crate = self.sim.mask[bs].loot_bag and self.sim.loot_bag[bs].supply_crate;
                if (self.sim.alive[bs]) self.sim.destroy(bs);
                if (was_crate) self.broadcastSupplyCrateMarkerRemove(bag);
                if (packages.buildEntityCollectBody(self.body_buf[0..16], bag, c.entity_id)) |cb| {
                    try self.broadcast("NetPackageEntityCollect", cb);
                } else |_| {}
                if (packages.buildRemoveBodyReason(&self.body_buf, bag, .despawned)) |rm| {
                    try self.broadcast("NetPackageEntityRemove", rm);
                } else |_| {}
                // Collected the player's own death bag: clear the backpack
                // marker and tell every client (RE EntityBackpack).
                if (self.clients[c.slot].removeBackpackAt(
                    @trunc(bx),
                    @trunc(by),
                    @trunc(bz),
                )) {
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
        // The Rotation base this package extends is variable width: byte 4 is
        // bUseQRotation, and it selects 3 x i16 euler (6 bytes) or a 4 x f32
        // quaternion (16 bytes) before dPos begins (RE protocol-packages.md
        // 5.5.3 / 5.5.4). Reading dPos at a fixed offset 11 decodes quaternion
        // bytes as a movement delta whenever a client sets the flag.
        const use_q = body[4] != 0;
        const dpos_off: usize = if (use_q) 21 else 11;
        if (body.len < dpos_off + 6 + 1 + 2) {
            self.harness.counters.inc(.decode_rejects);
            return true;
        }
        const dx = std.mem.readInt(i16, body[dpos_off..][0..2], .little);
        const dy = std.mem.readInt(i16, body[dpos_off + 2 ..][0..2], .little);
        const dz = std.mem.readInt(i16, body[dpos_off + 4 ..][0..2], .little);
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
    return false;
}
