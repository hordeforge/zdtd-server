//! Block editing: SetBlock, BlockTrigger, Explosions.
//! Extracted from the old c2s/inv.zig tail (643-991) verbatim.

const std = @import("std");
const chunk_fill = @import("../game/chunk_fill.zig");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const platform_user = packages.platform_user;
const world_store = @import("../../world/store.zig");
const ecs = @import("../../ecs/root.zig");
const invsys = @import("../../ecs/inventory.zig");
const systems = @import("../../ecs/systems.zig");
const replicate_te = @import("../replicate_te.zig");

/// Cap on the C2S-claimed explosion radii (block + entity). RE: the largest
/// stock ExplosionData.EntityRadius is 6 (entities.xml `explosion` on
/// cop/feral: radius_blocks 5, radius_entities 6); a forged blob must not
/// carve the whole map or damage every loaded entity.
const max_claimed_explosion_radius: f32 = 6.0;

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
            // Downgrade swap raw (stock Block.OnBlockDamaged): carries the
            // downgrade target id with the old block's rotation/meta bits.
            var place_down_raw: u32 = 0;
            if (b.block_id == 0) {
                place_id = 0;
                out_dmg = 0;
                self.clearBlockHp(b.x, b.y, b.z);
                mutated = true;
                if (cur_id != 0) {
                    self.noteBlockBreak(c);
                    self.removeClaimAt(b.x, b.y, b.z);
                    // A removed bedroll clears the owner's respawn point
                    // (stock PersistentPlayerList.SpawnPointRemoved).
                    self.noteBlockRemoved(b.x, b.y, b.z, cur_id);
                    // Harvest drops + XP (RE items.md GameUtils.HarvestOnAttack):
                    // the server rolls the block's Harvest rows into the
                    // breaker's inventory (overflow -> ground bag) and grants
                    // material.Experience * rolled count. A block with no
                    // Harvest rows drops itself once (count 1); with rows the
                    // count is the roll total (0 when nothing rolled).
                    const harvested = chunk_fill.tryBlockHarvestDrop(self, c.slot, b.x, b.y, b.z, cur_id);
                    const hxp = self.harvestXpForBlock(cur_id);
                    if (hxp > 0) {
                        var count: u32 = 1;
                        if (self.blocks.byId(cur_id)) |bd| {
                            if (bd.harvest_drops.len > 0) count = harvested;
                        }
                        if (count > 0) self.awardXp(c.slot, hxp *| count);
                    }
                    // A broken container spills its pre-filled contents.
                    chunk_fill.tryContainerSpill(self, b.x, b.y, b.z);
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
                    // Stock Block.OnBlockDamaged downgrade swap: a block with
                    // a DowngradeBlock turns into it (rotation/meta preserved)
                    // instead of breaking - no harvest/XP/claim removal for
                    // the swap (the block did not break).
                    const down_raw = self.downgradeBreakRaw(b.x, b.y, b.z, base_cur);
                    if (down_raw != 0) {
                        place_id = @truncate(down_raw & 0xffff);
                        out_dmg = 0;
                        self.clearBlockHp(b.x, b.y, b.z);
                        self.clearBlockRaw(b.x, b.y, b.z);
                        place_down_raw = down_raw;
                    } else {
                        self.noteBlockBreak(c);
                        self.removeClaimAt(b.x, b.y, b.z);
                        // A removed bedroll clears the owner's respawn point.
                        self.noteBlockRemoved(b.x, b.y, b.z, base_cur);
                        // Harvest drops + XP (RE items.md GameUtils.HarvestOnAttack):
                        // same server-side roll as the direct-dig break above.
                        const harvested = chunk_fill.tryBlockHarvestDrop(self, c.slot, b.x, b.y, b.z, base_cur);
                        const hxp = self.harvestXpForBlock(base_cur);
                        if (hxp > 0) {
                            var count: u32 = 1;
                            if (self.blocks.byId(base_cur)) |bd| {
                                if (bd.harvest_drops.len > 0) count = harvested;
                            }
                            if (count > 0) self.awardXp(c.slot, hxp *| count);
                        }
                        // A broken container spills its pre-filled contents.
                        chunk_fill.tryContainerSpill(self, b.x, b.y, b.z);
                        place_id = 0;
                        out_dmg = 0;
                        self.clearBlockHp(b.x, b.y, b.z);
                    }
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
                    try self.setBlockHp(b.x, b.y, b.z, abs);
                }
                mutated = true;
                // Item durability (GAP "Item durability"): the held tool wears
                // with each dig (stock ItemValue.UseTimes; the client shows the
                // durability bar). Zero keeps a broken, repairable stack.
                if (self.sim.mask[editor].inventory) {
                    _ = invsys.degradeUse(&self.sim, c.slot, self.sim.inventory[editor].holding, 1.0);
                }
            } else {
                place_id = b.block_id;
                out_dmg = 0;
                if (cur_id != 0 and b.block_id != cur_id) {
                    // Stock hammer upgrade / wrench downgrade (Block.UpgradeBlock
                    // / DowngradeBlock, blocks.xml data): accept only the
                    // resolved upgrade OR downgrade target for the current
                    // block, never an arbitrary swap.
                    const cur_name = self.maxdamage.idName(cur_id) orelse continue;
                    const up_id: u16 = if (self.maxdamage.upgradeTarget(cur_name)) |u|
                        (self.maxdamage.idByName(u) orelse 0)
                    else
                        0;
                    const down_id: u16 = if (self.maxdamage.downgradeTarget(cur_name)) |d|
                        (self.maxdamage.idByName(d) orelse 0)
                    else
                        0;
                    if (up_id != b.block_id and down_id != b.block_id) continue;
                }
                self.clearBlockHp(b.x, b.y, b.z);
                mutated = true;
            }
            if (place_id != 0 and self.landClaimBlockId() == place_id) {
                // Stock LandClaimCount / LandClaimDeadZone gates: refuse to
                // register a claim past the owner's count or inside another
                // claim's dead zone (the client's own count check usually
                // stops the placement first).
                if (self.claimAllowed(editor_ent, b.x, b.y, b.z)) {
                    self.registerClaim(b.x, b.y, b.z, editor_ent);
                }
            }
            const place_raw: u32 = if (place_down_raw != 0)
                place_down_raw
            else if (b.raw != 0 and (b.raw & 0xffff) == place_id)
                b.raw
            else
                place_id;
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
            if (place_id != 0 and b.raw != 0 and place_down_raw == 0) {
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
                // Stage2Health: the echo damage caps at the stage-2 threshold
                // (doors show the binary cracked state; internal damage stays).
                const echo_dmg = self.wireBlockDamage(place_id, out_dmg);
                if (packages.buildSetBlockBodyRaw(self.body_buf[0..96], b.x, b.y, b.z, echo_raw, echo_dmg, editor_ent, editor_ent)) |sb| {
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
    if (std.mem.eql(u8, name, "NetPackagePickupBlock")) {
        // Wrench pickup. RE: GameManager.PickupBlockServer IL=77 (verify type
        // match, echo the pickup to the requesting player, replace the block
        // with PickupSource/Air via SetBlocksRPC); the item itself is added
        // client-side by PickupBlockClient -> Block.OnBlockPickedUp and rides
        // the player's normal inventory sync, exactly like stock (the dedi
        // never fabricates the item).
        if (!self.takeBlockToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        var plat_buf: [platform_user.max_platform_len]u8 = undefined;
        var id_buf: [platform_user.max_id_len]u8 = undefined;
        var sent_id: ?platform_user.Id = null;
        const pk = packages.parsePickupBlockBody(body, &plat_buf, &id_buf, &sent_id) catch return true;
        const ps = self.sim.playerByPeer(c.slot) orelse return true;
        const editor_ent = self.sim.network_id[ps].id;
        // ValidEntityIdForSender: the pickup must claim the sender's own
        // entity (asm.il NetPackage.ValidEntityIdForSender).
        if (pk.player_id != editor_ent) {
            self.harness.counters.inc(.ownership_rejects);
            return true;
        }
        // ValidUserIdForSender (asm.il NetPackage IL=29): exact match against
        // the sender's PlatformId or CrossplatformId; a null sent identity
        // passes only when the sender registered none (EAC-off / loadgen).
        if (sent_id) |sent| {
            if (!c.puid_primary.matches(sent) and !c.puid_native.matches(sent)) {
                self.harness.counters.inc(.ownership_rejects);
                return true;
            }
        } else {
            if (c.puid_primary.get() != null or c.puid_native.get() != null) {
                self.harness.counters.inc(.ownership_rejects);
                return true;
            }
        }
        // Type match: the world block must still be what the client snapped
        // (IL=77 IL_0031-0048; a mismatch silently drops, so a stale or
        // spoofed pickup never removes a different block).
        const cur_id = self.world.blockWorld(pk.x, pk.y, pk.z) catch return true;
        if (cur_id != @as(u16, @truncate(pk.raw))) return true;
        // zdtd trust bounds (stock checks CanPickup client-side; the server
        // still enforces reach and claims so a spoofed pickup cannot delete
        // distant or claimed blocks).
        const ep = self.sim.transform[ps];
        if (!self.withinEditReach(ep.x, ep.y, ep.z, @floatFromInt(pk.x), @floatFromInt(pk.y), @floatFromInt(pk.z))) {
            self.harness.counters.inc(.bounds_rejects);
            return true;
        }
        if (self.claimCovering(pk.x, pk.z)) |claim| {
            if (claim.owner_entity != editor_ent) {
                self.harness.counters.inc(.ownership_rejects);
                return true;
            }
        }
        // 1) Echo the pickup to the requesting player. Setup(pos, bv, playerId,
        //    null) writes a null identity, which the client's
        //    ValidUserIdForSender skips (it is not the server).
        const echo = packages.buildPickupBlockBody(self.body_buf[0..32], pk.x, pk.y, pk.z, pk.raw, pk.player_id) catch return true;
        try self.sendGame(peer, "NetPackagePickupBlock", echo);
        // 2) Replacement block: PickupSource name resolved via AssignIds, or
        //    Air. V3.1.0 b14 ships no PickupSource property, so stock leaves
        //    Air behind on every pickup; a modded blocks.xml is honoured.
        var repl_raw: u32 = 0;
        if (self.blocks.pickupSource(cur_id)) |src_name| {
            repl_raw = self.maxdamage.idByName(src_name) orelse 0;
        }
        // 3) Broadcast the replacement to observers (stock SetBlocksRPC
        //    carries a BlockChangeInfo; the SetBlock S2C body is the same
        //    shape the client Reads for every server block change).
        if (packages.buildSetBlockBodyRaw(self.body_buf[0..96], pk.x, pk.y, pk.z, repl_raw, 0, editor_ent, editor_ent)) |sb| {
            try self.broadcastNear("NetPackageSetBlock", sb, ep.x, ep.z, self.interest_range);
        } else |_| {}
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageSetBlockTexture")) {
        // Paint. RE: GameManager.SetBlockTextureServer IL=41 (apply the face
        // texture, rebroadcast to everyone but the sender with
        // playerIdThatChanged=-1 on a dedi); Chunk.SetBlockFaceTexture IL=48
        // stores the BlockTextureData catalog idx raw (`_texture & 255`) in
        // the face*8 bits of the per-block textureFull.
        if (!self.takeBlockToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        const st = packages.parseSetBlockTexture(body) catch return true;
        // chnTextures is a 1-element array (Chunk IL_01F8-01FE: `ldc.i4.1;
        // newarr`), so channel 0 is the only valid one; fail closed.
        if (st.channel != 0) {
            self.harness.counters.inc(.bounds_rejects);
            return true;
        }
        if (st.face > 5) {
            self.harness.counters.inc(.bounds_rejects);
            return true;
        }
        const ps = self.sim.playerByPeer(c.slot) orelse return true;
        const editor_ent = self.sim.network_id[ps].id;
        // ValidEntityIdForSender: the paint must claim the sender's own entity.
        if (st.player_id != editor_ent) {
            self.harness.counters.inc(.ownership_rejects);
            return true;
        }
        const ep = self.sim.transform[ps];
        if (!self.withinEditReach(ep.x, ep.y, ep.z, @floatFromInt(st.x), @floatFromInt(st.y), @floatFromInt(st.z))) {
            self.harness.counters.inc(.bounds_rejects);
            return true;
        }
        if (self.claimCovering(st.x, st.z)) |claim| {
            if (claim.owner_entity != editor_ent) {
                self.harness.counters.inc(.ownership_rejects);
                return true;
            }
        }
        const cur_id = self.world.blockWorld(st.x, st.y, st.z) catch return true;
        if (cur_id == 0) return true; // nothing to paint on
        // Base textureFull: stored paint, else the block's default (what the
        // client renders unpainted) so the other five faces do not go grey.
        const wt = world_store.World.worldToChunk(st.x, st.z);
        const ch = try self.world.getOrCreate(wt.pos);
        var base = ch.texAt(wt.lx, st.y, wt.lz);
        if (base == 0) base = self.block_textures.get(cur_id);
        const shift: u6 = @intCast(st.face * 8);
        const new_tex = (base & ~(@as(u64, 0xff) << shift)) | (@as(u64, st.idx) << shift);
        try self.world.setBlockTexDensWorld(st.x, st.y, st.z, self.blockRawAt(st.x, st.y, st.z), new_tex, null);
        // Rebroadcast to everyone but the painter (stock flags 192 excludes
        // the sender; the painter already applied the paint locally).
        const s2c: packages.SetBlockTexture = .{
            .x = st.x,
            .y = st.y,
            .z = st.z,
            .face = st.face,
            .idx = st.idx,
            .player_id = -1, // dedi (IL=41 IL_0018-0027)
            .channel = st.channel,
        };
        if (packages.buildSetBlockTextureBody(self.body_buf[0..32], s2c)) |sb| {
            try self.broadcastExcept("NetPackageSetBlockTexture", sb, c.slot);
        } else |_| {}
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
        const rad: i32 = @intFromFloat(@max(1, @min(ex.radius, max_claimed_explosion_radius)));
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
                    // Armor mitigation, less the blaster's held-item TargetArmor
                    // penetration (RE GetTotalPhysicalArmorRating IL=47).
                    const mit = invsys.armorMitigationVs(&self.sim, victim_slot, self.sim.playerByPeer(c.slot));
                    amount *= (1.0 - mit);
                }
                // Wasm-first (AGENTS rule 29): the on_player_damage verdict
                // applies to explosion damage too (attacker = the blaster), so
                // a module scales/denies PvP and self-damage from explosives
                // like any other hit. The native pvp_mode floor still wins.
                const atk = if (c.entity_id > 0) c.entity_id else -1;
                amount = game_mod.playerDamageVerdictAmount(self, atk, nid, amount);
                if (amount <= 0) continue;
            }
            const dmg = self.sim.damageFrom(nid, amount, if (c.entity_id > 0) c.entity_id else -1);
            if (dmg.killed and !self.sim.mask[es].player) {
                // Victim position for ClearSleepers POI gating (es is the
                // victim's sim slot).
                systems.questOnZombieKilled(&self.sim, c.slot, self.sim.transform[es].x, self.sim.transform[es].z);
                self.killXpAward(c.slot, self.xpGainFor(nid), dmg.kill_scale_pct);
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
