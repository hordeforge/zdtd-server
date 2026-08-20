//! Block editing: SetBlock, BlockTrigger, Explosions.
//! Extracted from the old c2s/inv.zig tail (643-991) verbatim.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const world_store = @import("../../world/store.zig");
const ecs = @import("../../ecs/root.zig");
const invsys = @import("../../ecs/inventory.zig");
const systems = @import("../../ecs/systems.zig");
const replicate_te = @import("../replicate_te.zig");

pub fn handle(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (std.mem.eql(u8, name, "NetPackageBlockTrigger")) {
        // Same rate gate as SetBlock: unthrottled would let a spam loop fan
        // this broadcast out to every nearby peer for free (bandwidth DoS).
        if (!self.takeBlockToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        const ps = self.sim.playerByPeer(c.slot) orelse return true;
        try self.broadcastNear("NetPackageBlockTrigger", body, self.sim.transform[ps].x, self.sim.transform[ps].z, self.interest_range);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageSetBlock")) {
        if (self.quarantineDenies(c, .block)) return true;
        if (!self.takeBlockToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        var changes: [32]packages.BlockChange = undefined;
        const n = packages.parseSetBlockChanges(body, changes[0..]) catch {
            std.debug.print("zdtd: SetBlock parse fail body={d}\n", .{body.len});
            return true;
        };
        if (n == 0) return true;
        const editor = self.sim.playerByPeer(c.slot) orelse return true;
        const editor_ent = self.sim.network_id[editor].id;
        {
            const tr0 = self.sim.transform[editor];
            _ = try self.rescueDeepVoid(peer, editor_ent, tr0.x, tr0.y, tr0.z, true);
        }
        const ep = self.sim.transform[editor];
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const b = changes[i];
            if (!self.withinEditReach(ep.x, ep.y, ep.z, @floatFromInt(b.x), @floatFromInt(b.y), @floatFromInt(b.z))) {
                self.harness.counters.inc(.bounds_rejects);
                self.noteEvidence(c, peer.local_id, editor_ent, .bounds, .strong, .block, 0, self.max_edit_range);
                const rejects = self.harness.counters.get(.bounds_rejects);
                if (rejects == 1 or rejects % 100 == 0) {
                    std.debug.print("zdtd: SetBlock out of reach n={d} ({d},{d},{d}) player=({d:.0},{d:.0},{d:.0})\n", .{ rejects, b.x, b.y, b.z, ep.x, ep.y, ep.z });
                }
                continue;
            }
            if (self.claimCovering(b.x, b.z)) |claim| {
                if (claim.owner_entity != editor_ent) continue;
            }
            const cur_id = self.world.blockWorld(b.x, b.y, b.z) catch 0;
            const cur_dmg = self.getBlockHp(b.x, b.y, b.z);
            const cur_raw = self.blockRawAt(b.x, b.y, b.z);
            if (cur_id != 0 and b.block_id == cur_id and b.damage == cur_dmg and b.raw != 0 and b.raw != cur_raw) {
                self.setBlockRaw(b.x, b.y, b.z, b.raw);
                try self.world.setBlockRawWorld(b.x, b.y, b.z, b.raw);
                const on = (packages.blockMeta(b.raw) & packages.block_meta_on) != 0;
                if (self.sim.power.setSwitchAt(b.x, b.y, b.z, on)) {
                    self.sim.power.resolve();
                }
                if (packages.buildSetBlockBodyRaw(self.body_buf[0..96], b.x, b.y, b.z, b.raw, cur_dmg, editor_ent, editor_ent)) |sb| {
                    try self.broadcastNear("NetPackageSetBlock", sb, ep.x, ep.z, self.interest_range);
                } else |_| {}
                continue;
            }
            var place_id: u16 = b.block_id;
            var out_dmg: u16 = 0;
            var mutated = false;
            if (b.block_id == 0) {
                place_id = 0;
                out_dmg = 0;
                self.clearBlockHp(b.x, b.y, b.z);
                mutated = true;
                if (cur_id != 0) {
                    self.noteBlockBreak(c);
                    self.removeClaimAt(b.x, b.y, b.z);
                }
            } else if (b.damage > 0 or (cur_id != 0 and b.block_id == cur_id and b.damage != cur_dmg)) {
                const wire_abs = b.damage;
                const base_cur = if (cur_id != 0) cur_id else b.block_id;
                var abs: u16 = cur_dmg;
                if (wire_abs > cur_dmg) {
                    if (self.block_damage_player != 100) {
                        const delta: u32 = @as(u32, wire_abs - cur_dmg) * self.block_damage_player / 100;
                        abs = @intCast(@min(@as(u32, cur_dmg) + delta, 65535));
                    } else {
                        abs = wire_abs;
                    }
                } else if (wire_abs < cur_dmg) {
                    abs = wire_abs;
                }
                var max_hp = self.maxDamageForBlock(base_cur);
                if (self.claimCovering(b.x, b.z)) |claim| {
                    if (claim.owner_entity == editor_ent) {
                        const dur = if (claim.owner_online) self.land_claim_online_dur else self.land_claim_offline_dur;
                        if (dur > 0) max_hp = @intCast(@min(@as(u32, max_hp) * dur, 65535));
                    }
                }
                if (abs >= max_hp) {
                    self.noteBlockBreak(c);
                    self.removeClaimAt(b.x, b.y, b.z);
                    place_id = 0;
                    out_dmg = 0;
                    self.clearBlockHp(b.x, b.y, b.z);
                } else {
                    // Wasm-first (AGENTS rule 29): player dig is a block-damage
                    // path, so the claimed delta passes the on_block_damage
                    // verdict like every other path (addBlockDamage). Plugins
                    // may deny (no progress) or scale the delta.
                    if (abs > cur_dmg) {
                        const delta = abs - cur_dmg;
                        const sv = self.plugins.blockDamage(b.x, b.y, b.z, @intCast(delta));
                        const v = if (sv != 0) sv else self.wasm_plugins.blockDamage(b.x, b.y, b.z, @intCast(delta));
                        if (v < 0) {
                            abs = cur_dmg;
                        } else if (v > 0) {
                            const add = @as(u32, delta) * @as(u32, @intCast(v)) / 100;
                            abs = @intCast(@min(@as(u32, cur_dmg) + add, 65535));
                        }
                    }
                    place_id = if (cur_id != 0) cur_id else b.block_id;
                    out_dmg = abs;
                    self.setBlockHp(b.x, b.y, b.z, abs);
                }
                mutated = true;
            } else {
                place_id = b.block_id;
                out_dmg = 0;
                if (cur_id != 0 and b.block_id != cur_id) {
                    const cur_name = self.maxdamage.idName(cur_id) orelse continue;
                    const target_name = self.maxdamage.upgradeTarget(cur_name) orelse continue;
                    const target_id = self.maxdamage.idByName(target_name) orelse continue;
                    if (target_id != b.block_id) continue;
                }
                self.clearBlockHp(b.x, b.y, b.z);
                mutated = true;
            }
            if (place_id != 0 and self.landClaimBlockId() == place_id) {
                self.registerClaim(b.x, b.y, b.z, editor_ent);
            }
            const place_raw: u32 = if (b.raw != 0 and (b.raw & 0xffff) == place_id) b.raw else place_id;
            try self.world.setBlockRawWorld(b.x, b.y, b.z, place_raw);
            if (place_id != 0 and self.blocks.isVending(place_id)) {
                _ = self.vending.getOrCreate(.{ .x = b.x, .y = b.y, .z = b.z }, place_id, self.blocks.traderId(place_id));
            } else if (place_id == 0) {
                self.vending.removeAt(.{ .x = b.x, .y = b.y, .z = b.z });
            }
            if (place_id != 0) {
                if (self.power_registry.lookup(place_id)) |pn| {
                    if (self.sim.power.addNodeAt(pn.kind, b.x, b.y, b.z, pn.watts)) |nid| {
                        if (self.sim.power.indexOfId(nid)) |ni| pn.applyToNode(&self.sim.power.nodes[ni]);
                    }
                    self.sim.power.resolve();
                }
            } else if (self.sim.power.removeAt(b.x, b.y, b.z)) {
                self.sim.power.resolve();
            }
            if (place_id != 0 and b.raw != 0) {
                self.setBlockRaw(b.x, b.y, b.z, b.raw);
            } else if (place_id == 0) {
                self.clearBlockRaw(b.x, b.y, b.z);
            }
            if (cur_id != place_id) {
                _ = game_mod.stabilityAfterSetBlock(self, b.x, b.y, b.z, cur_id, place_id);
            }
            if (self.isStorageBlockId(place_id)) {
                if (self.containers.get(.{ .x = b.x, .y = b.y, .z = b.z })) |cont| {
                    cont.block_id = place_id;
                    try replicate_te.broadcastStorageTe(self, cont);
                } else if (self.containers.getOrCreate(.{ .x = b.x, .y = b.y, .z = b.z }, 8, @intCast(place_id))) |cont| {
                    try replicate_te.broadcastStorageTe(self, cont);
                }
            } else if (self.storagePairId(place_id) == null) {
                self.containers.remove(.{ .x = b.x, .y = b.y, .z = b.z });
            }
            if (mutated) {
                const stored_raw = self.blockRawAt(b.x, b.y, b.z);
                const echo_raw: u32 = if (place_id != 0 and (stored_raw & 0xffff) == place_id) stored_raw else @as(u32, place_id);
                if (packages.buildSetBlockBodyRaw(self.body_buf[0..96], b.x, b.y, b.z, echo_raw, out_dmg, editor_ent, editor_ent)) |sb| {
                    try self.broadcastNear("NetPackageSetBlock", sb, ep.x, ep.z, self.interest_range);
                } else |_| {}
            }
        }
        if (packages.idOf("NetPackageSetBlockResponse") != null) {
            var rb: [4]u8 = undefined;
            std.mem.writeInt(u16, rb[0..2], 0, .little);
            try self.sendGame(peer, "NetPackageSetBlockResponse", rb[0..2]);
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageExplosionInitiate")) {
        const ex = packages.parseExplosionInitiate(body) catch return true;
        if (self.quarantineDenies(c, .block)) return true;
        if (ex.entity_id > 0 and c.entity_id > 0 and ex.entity_id != c.entity_id) {
            self.harness.counters.inc(.ownership_rejects);
            self.noteEvidence(c, peer.local_id, ex.entity_id, .ownership, .strong, .block, @floatFromInt(ex.entity_id), @floatFromInt(c.entity_id));
            return true;
        }
        if (!self.takeBlockToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        const rad: i32 = @trunc(@max(1, @min(ex.radius, 6)));
        const cx = if (ex.bx != 0 or ex.by != 0 or ex.bz != 0) ex.bx else @as(i32, @floor(ex.wx));
        const cy = if (ex.bx != 0 or ex.by != 0 or ex.bz != 0) ex.by else @as(i32, @floor(ex.wy));
        const cz = if (ex.bx != 0 or ex.by != 0 or ex.bz != 0) ex.bz else @as(i32, @floor(ex.wz));
        if (self.sim.playerByPeer(c.slot)) |bi| {
            if (!self.sim.alive[bi] or self.sim.health[bi].hp <= 0) {
                self.harness.counters.inc(.bounds_rejects);
                return true;
            }
            const bp = self.sim.transform[bi];
            // Reach-check the actual dig center (bx/by/bz overrides wx/wy/wz
            // above), not the possibly-unrelated thrown/explosion position:
            // otherwise a client can claim to be next to the blast but dig
            // anywhere on the map via the block-position override.
            const dx = @as(f32, @floatFromInt(cx)) - bp.x;
            const dy = @as(f32, @floatFromInt(cy)) - bp.y;
            const dz = @as(f32, @floatFromInt(cz)) - bp.z;
            const ex_d2 = dx * dx + dy * dy + dz * dz;
            if (ex_d2 > self.max_edit_range * self.max_edit_range) {
                self.harness.counters.inc(.bounds_rejects);
                self.noteEvidence(c, peer.local_id, ex.entity_id, .bounds, .strong, .block, @sqrt(ex_d2), self.max_edit_range);
                return true;
            }
        } else return true;
        var dy: i32 = -rad;
        while (dy <= rad) : (dy += 1) {
            var dz: i32 = -rad;
            while (dz <= rad) : (dz += 1) {
                var dx: i32 = -rad;
                while (dx <= rad) : (dx += 1) {
                    if (dx * dx + dy * dy + dz * dz > rad * rad) continue;
                    const wx = cx + dx;
                    const wy = cy + dy;
                    const wz = cz + dz;
                    if (wy <= 0) continue;
                    const cur = self.world.blockWorld(wx, wy, wz) catch continue;
                    if (cur == 0 or cur == world_store.block_bedrock) continue;
                    self.world.setBlockWorld(wx, wy, wz, 0) catch continue;
                    const sb = packages.buildSetBlockBody(self.body_buf[0..64], wx, wy, wz, 0) catch continue;
                    self.broadcastNear("NetPackageSetBlock", sb, ex.wx, ex.wz, self.interest_range) catch {};
                }
            }
        }
        // ExplosionData is supplied by the client. Keep its effect inside the
        // same bounded authority envelope as direct C2S damage; otherwise a
        // forged blob can use a 65535 m radius and damage every loaded entity.
        const e_rad: f32 = @max(1, @min(ex.entity_radius, 6));
        const claimed_damage: f32 = if (ex.entity_damage > 0) ex.entity_damage else @as(f32, @floatFromInt(ex.block_damage));
        const e_dmg: f32 = @min(claimed_damage, @as(f32, @floatFromInt(self.max_claimed_damage)));
        var es: ecs.Slot = 0;
        while (es < ecs.max_entities) : (es += 1) {
            if (!self.sim.alive[es] or !self.sim.mask[es].transform or !self.sim.mask[es].health) continue;
            const nid = self.sim.network_id[es].id;
            if (nid <= 0) continue;
            const t = self.sim.transform[es];
            const edx = t.x - ex.wx;
            const edy = t.y - ex.wy;
            const edz = t.z - ex.wz;
            const ed2 = edx * edx + edy * edy + edz * edz;
            if (ed2 > e_rad * e_rad) continue;
            if (self.sim.kind[es] == .trader) continue;
            // A kill inside this loop spawns the corpse's loot bag (hp 1) into
            // the first free slot, which may sit above `es`. Damaging it would
            // destroy the bag on the spawning tick and bill a second kill.
            if (self.sim.kind[es] == .loot_bag) continue;
            const fall = 1.0 - @sqrt(ed2) / e_rad;
            if (fall <= 0) continue;
            var amount = e_dmg * fall;
            if (self.sim.mask[es].player and self.sim.player[es].peer_slot >= 0) {
                const victim_slot: usize = @intCast(self.sim.player[es].peer_slot);
                if (self.pvp_mode == 0 and victim_slot != c.slot) continue;
                if (victim_slot != c.slot) {
                    const mit = invsys.armorMitigation(&self.sim, victim_slot);
                    amount *= (1.0 - mit);
                }
            }
            const dmg = self.sim.damageFrom(nid, amount, if (c.entity_id > 0) c.entity_id else -1);
            if (dmg.killed and !self.sim.mask[es].player) {
                systems.questOnZombieKilled(&self.sim, c.slot);
                self.killXpAward(c.slot, self.xpGainFor(nid));
                if (c.zombie_kills < std.math.maxInt(u16)) c.zombie_kills += 1;
                if (c.peer) |kpeer| {
                    if (packages.stock_xp.buildAddScoreBody(self.body_buf[64..80], .{ .entity_id = c.entity_id, .zombie_kills = c.zombie_kills })) |ab| {
                        self.sendGame(kpeer, "NetPackageEntityAddScoreClient", ab) catch {
                            self.harness.counters.inc(.net_send_errors);
                        };
                    } else |_| {}
                }
            }
        }
        const client_body = try packages.buildExplosionClient(self.body_buf[96..288], ex.wx, ex.wy, ex.wz, 0, ex.block_damage, @intCast(@max(1, rad)), ex.block_damage, if (c.entity_id > 0) c.entity_id else ex.entity_id);
        try self.broadcastNear("NetPackageExplosionClient", client_body, ex.wx, ex.wz, self.interest_range);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageItemActionEffects")) {
        if (!self.takeInvToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        try self.broadcastExcept("NetPackageItemActionEffects", body, c.slot);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageCloseAllWindows")) {
        if (!self.takeInvToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        try self.broadcastExcept("NetPackageCloseAllWindows", body, c.slot);
        return true;
    }
    return false;
}
