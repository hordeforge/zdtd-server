//! C2S block arm: explosion initiate (validate, detonate, replicate).
//!
//! Split out of c2s/blocks.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const ecs = @import("../../ecs/root.zig");
const invsys = @import("../../ecs/inventory.zig");
const protocol = @import("../../protocol.zig");
const systems = @import("../../ecs/systems.zig");
const game_world = @import("../game/world.zig");
const chunk_fill = @import("../game/chunk_fill.zig");

/// Cap on the C2S-claimed explosion radii (block + entity). RE: the largest
/// stock ExplosionData.EntityRadius is 6 (entities.xml `explosion` on
/// cop/feral: radius_blocks 5, radius_entities 6); a forged blob must not
/// carve the whole map or damage every loaded entity.
pub const max_claimed_explosion_radius: f32 = 6.0;

/// True when `name` is an explosion package and was handled.
pub fn handleExplosion(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
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
        const rad: i32 = @trunc(@max(1, @min(ex.radius, max_claimed_explosion_radius)));
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
            if (self.rejectIfBeyondEditRange(
                c,
                peer.local_id,
                ex.entity_id,
                .block,
                bp.x,
                bp.y,
                bp.z,
                @floatFromInt(cx),
                @floatFromInt(cy),
                @floatFromInt(cz),
            )) return true;
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
                    // Live AssignIds id (World.terrain_ids), not the offline
                    // module pin: a dumpless merge or modded terrBedrock must
                    // still skip the correct cell (HARDCODE A36 residual).
                    if (cur == 0 or cur == self.world.terrain_ids.bedrock) continue;
                    // Stock Explosion::AttackBlocks, not "delete everything in
                    // the sphere": the claimed ExplosionData.BlockDamage is the
                    // power, the block's material decides whether it breaks
                    // (hardness and explosionresistance), and a block can come
                    // out merely damaged. Every block the blast destroyed is
                    // re-read below because a downgrade swap also changes the
                    // cell.
                    const blast_falloff = game_world.blastFalloff(
                        wx,
                        wy,
                        wz,
                        ex.wx,
                        ex.wy,
                        ex.wz,
                        @floatFromInt(rad),
                    );
                    const blast_attacker: i32 = if (c.entity_id > 0) c.entity_id else -1;
                    if (!self.blastBlock(wx, wy, wz, cur, @floatFromInt(ex.block_damage), blast_falloff, 1.0, blast_attacker)) continue;
                    const after = self.world.blockWorld(wx, wy, wz) catch continue;
                    if (after != 0) continue; // damaged or downgraded, not destroyed
                    // Destroy-event drops (RE Block.DropItemsOnEvent IL=246 +
                    // GameManager.ExplodeGroupFrameUpdate IL=145): the
                    // destroyed block's `<drop event="Destroy">` rows roll at
                    // the blast with the stock explosion overallProb 0.5;
                    // stacks bag at the block, stick rows re-place debris.
                    _ = chunk_fill.rollBlockDropEvent(self, 0, wx, wy, wz, cur, .destroy, 0.5);
                }
            }
        }
        // ExplosionData is supplied by the client. Keep its effect inside the
        // same bounded authority envelope as direct C2S damage; otherwise a
        // forged blob can use a 65535 m radius and damage every loaded entity.
        const e_rad: f32 = @max(1, @min(ex.entity_radius, max_claimed_explosion_radius));
        const claimed_damage: f32 = if (ex.entity_damage > 0) ex.entity_damage else @as(f32, @floatFromInt(ex.block_damage));
        const e_dmg: f32 = @min(claimed_damage, @as(f32, @floatFromInt(self.max_claimed_damage)));
        // alive_bits: pay for live entities, not the empty slot table.
        var alive_it = self.sim.alive_bits.iterator(.{});
        while (alive_it.next()) |idx| {
            const es: ecs.Slot = @intCast(idx);
            if (!self.sim.mask[es].transform or !self.sim.mask[es].health) continue;
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
                // GeneralDamageResist (passive 40) covers every damage type, so
                // it joins the blast before the physical armor leg (stock
                // EntityAlive::DamageEntity order).
                amount *= 1.0 - invsys.generalDamageResist(&self.sim, es);
                const victim_slot: usize = @intCast(self.sim.player[es].peer_slot);
                if (self.pvp_mode == 0 and victim_slot != c.slot) continue;
                // Explosion.AttackEntites builds the DamageSource External
                // (IL_0499), so DamageSource::AffectedByArmor (IL=5) holds for
                // every victim including the blaster, and the blast's stock
                // Heat type (ExplosionData default 6) takes passive 43
                // ElementalDamageResist rather than the physical armor rating
                // (Equipment.CalcDamage IL=83).
                amount *= (1.0 - self.elementalDamageResist(es, protocol.damageTypeName(6)));
                // Wasm-first (AGENTS rule 29): the on_player_damage verdict
                // applies to explosion damage too (attacker = the blaster), so
                // a module scales/denies PvP and self-damage from explosives
                // like any other hit. The native pvp_mode floor still wins.
                const atk = if (c.entity_id > 0) c.entity_id else -1;
                amount = game_mod.playerDamageVerdictAmount(self, atk, nid, amount);
                if (amount <= 0) continue;
            }
            const dmg = self.sim.damageFrom(nid, amount, if (c.entity_id > 0) c.entity_id else -1);
            // Same S2C hit fan-out as the direct-damage path (ProcessDamageResponse
            // IL=86): the blast victim's trackers see the applied hit. Source
            // External (Explosion.AttackEntites IL_0499) and the stock
            // ExplosionData.DamageType default Heat (ExplosionData cctor
            // ldc.i4.6; the initiate body carries no damage type).
            {
                // The applied hit, not the claim: the server's post-resist
                // value, which for a non-player victim now includes its class
                // PhysicalDamageResist leg (stock ProcessDamageResponse).
                const applied: u16 = @intCast(@min(@as(u32, @trunc(@max(0, dmg.applied))), 65535));
                const atk = if (c.entity_id > 0) c.entity_id else -1;
                if (packages.buildDamageBody(self.body_buf[288..544], nid, 0, 6, applied, dmg.killed, atk)) |db| {
                    self.broadcastNear("NetPackageDamageEntity", db, t.x, t.z, self.interest_range) catch {};
                } else |_| {}
            }
            if (dmg.killed and !self.sim.mask[es].player) {
                // Victim position for ClearSleepers POI gating (es is the
                // victim's sim slot).
                systems.questOnZombieKilled(&self.sim, c.slot, self.sim.transform[es].x, self.sim.transform[es].z);
                self.killXpAward(c.slot, self.xpGainFor(nid), dmg.kill_scale_pct, false, nid);
                // Stock GameManager.AwardKill: tell the killer's client so its
                // local EntityKill event fires (kill challenges hang off it).
                self.awardKillNotify(c.slot, nid);
                if (c.zombie_kills < std.math.maxInt(u16)) c.zombie_kills += 1;
                if (c.peer) |kpeer| {
                    // Both counters ride one body (RE protocol-packages.md 27);
                    // filling only zombie_kills would send a stale 0 for the
                    // other and contradict what this client was already told.
                    if (packages.stock_xp.buildAddScoreBody(self.body_buf[64..80], .{
                        .entity_id = c.entity_id,
                        .zombie_kills = c.zombie_kills,
                        .player_kills = c.player_kills,
                    })) |ab| {
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
    return false;
}
