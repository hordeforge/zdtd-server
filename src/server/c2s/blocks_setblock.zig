//! C2S block arm: SetBlock validate, mutate, replicate.
//!
//! Split out of c2s/blocks.zig (same code, moved verbatim).

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
const replicate_te = @import("../game/replicate_te.zig");
const plugin_compose = @import("../game/plugin_compose.zig");
const log = @import("../../util/log.zig");

/// Bound on the `PassThroughDamage` downgrade-chain walk. Stock recurses the
/// whole damage handler with no cap; a modded chain cannot spin the tick here.
pub const max_passthrough_depth: usize = 8;

/// True when `name` is a setblock package and was handled.
pub fn handleSetBlock(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
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
            if (self.rejectIfBeyondEditRange(
                c,
                peer.local_id,
                editor_ent,
                .block,
                ep.x,
                ep.y,
                ep.z,
                @floatFromInt(b.x),
                @floatFromInt(b.y),
                @floatFromInt(b.z),
            )) {
                const rejects = self.harness.counters.get(.bounds_rejects);
                log.warnEvery(rejects, "SetBlock out of reach n={d} ({d},{d},{d}) player=({d:.0},{d:.0},{d:.0})\n", .{ rejects, b.x, b.y, b.z, ep.x, ep.y, ep.z });
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
                        if (count > 0) self.awardXpTagged(c.slot, hxp *| count, "Harvesting");
                    }
                }
            } else if (b.damage > 0 or (cur_id != 0 and b.block_id == cur_id and b.damage != cur_dmg)) {
                const wire_abs = b.damage;
                const base_cur = if (cur_id != 0) cur_id else b.block_id;
                var abs: u16 = cur_dmg;
                if (wire_abs > cur_dmg) {
                    if (self.block_damage_player != 100) {
                        const delta: u32 = @as(u32, wire_abs - cur_dmg) * self.block_damage_player / 100;
                        abs = @intCast(@min(@as(u32, cur_dmg) + delta, std.math.maxInt(u16)));
                    } else {
                        abs = wire_abs;
                    }
                } else if (wire_abs < cur_dmg) {
                    abs = wire_abs;
                }
                // materials.xml CanDestroy=false (Mbedrock): the stock client
                // never sends damage for it (`ItemActionAttack::Hit`
                // IL_028A-029D zeroes the scalar), so a request that does is a
                // forged edit. Drop this block's entry and keep the rest of the
                // batch.
                if (!self.maxdamage.canDestroyFor(base_cur)) continue;
                // `onSelfDamagedBlock` only when damage rose (not repair /
                // no-op sync); tags feed TriggerHasTags (church-bell gate).
                if (abs > cur_dmg) {
                    if (self.sim.playerByPeer(c.slot)) |bps| self.fireBlockDamaged(bps, base_cur);
                }
                var max_hp = self.maxDamageForBlock(base_cur);
                if (self.claimCovering(b.x, b.z)) |claim| {
                    if (claim.owner_entity == editor_ent) {
                        const dur = if (claim.owner_online) self.land_claim_online_dur else self.land_claim_offline_dur;
                        if (dur > 0) max_hp = @intCast(@min(@as(u32, max_hp) * dur, std.math.maxInt(u16)));
                    }
                }
                if (abs >= max_hp) {
                    // Stock Block.OnBlockDamaged downgrade swap: a block with
                    // a DowngradeBlock turns into it (rotation/meta preserved)
                    // instead of breaking - no harvest/XP/claim removal for
                    // the swap (the block did not break).
                    const down_raw = self.downgradeBreakRaw(b.x, b.y, b.z, base_cur);
                    if (down_raw != 0) {
                        place_id = world_store.typeId(down_raw);
                        out_dmg = 0;
                        // The block did not break (no harvest, no claim
                        // removal), but it was replaced, so a container or
                        // vending entry keyed to the old one must not survive
                        // under its downgrade. The power node is handled by
                        // the place_id != cur_id swap check further down.
                        self.containers.remove(.{ .x = b.x, .y = b.y, .z = b.z });
                        self.sign_texts.remove(.{ .x = b.x, .y = b.y, .z = b.z });
                        self.vending.removeAt(.{ .x = b.x, .y = b.y, .z = b.z });
                        self.light_te.removeAt(.{ .x = b.x, .y = b.y, .z = b.z });
                        self.workstations.removeAt(b.x, b.y, b.z);
                        self.clearBlockHp(b.x, b.y, b.z);
                        self.clearBlockRaw(b.x, b.y, b.z);
                        place_down_raw = down_raw;
                        // Stock Block.OnBlockDamaged IL_0384-03AE: with
                        // PassThroughDamage the leftover damage
                        // (claimed - max_hp) hits the replacement block at the
                        // same cell, recursively down the downgrade chain
                        // (102 stock rows: doors, gates, hatches, the vehicle
                        // and wood/steel masters). The walk is bounded;
                        // stock's own recursion is not. Only the swap chain is
                        // walked here: stock re-runs the whole damage handler,
                        // so its intermediate stages also roll harvest drops
                        // and XP, which this arm does not.
                        if (self.blocks.passThrough(base_cur)) {
                            var left: u32 = abs - max_hp;
                            var cur_down: u32 = down_raw;
                            var depth: usize = 0;
                            while (cur_down != 0 and left > 0 and depth < max_passthrough_depth) : (depth += 1) {
                                const nid = world_store.typeId(cur_down);
                                const nmax: u32 = self.maxDamageForBlock(nid);
                                if (nmax == 0 or !self.blocks.passThrough(nid)) break;
                                if (left < nmax) {
                                    self.setBlockHp(b.x, b.y, b.z, @intCast(@min(left, std.math.maxInt(u16)))) catch break;
                                    break;
                                }
                                left -= nmax;
                                const next = self.downgradeBreakRaw(b.x, b.y, b.z, nid);
                                if (next == 0) {
                                    // The chain ends: the last stage is gone.
                                    place_id = 0;
                                    place_down_raw = 0;
                                    out_dmg = 0;
                                    break;
                                }
                                self.clearBlockHp(b.x, b.y, b.z);
                                self.clearBlockRaw(b.x, b.y, b.z);
                                place_id = world_store.typeId(next);
                                place_down_raw = next;
                                cur_down = next;
                            }
                        }
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
                            if (count > 0) self.awardXpTagged(c.slot, hxp *| count, "Harvesting");
                        }
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
                        const v = plugin_compose.blockDamage(self, b.x, b.y, b.z, @intCast(delta));
                        if (v < 0) {
                            abs = cur_dmg;
                        } else if (v > 0) {
                            // u64 product: a large verdict times the delta must
                            // not overflow u32 (Debug trap / ReleaseFast wrap);
                            // the result is clamped to the u16 damage ceiling.
                            const add: u32 = @intCast(@min(@as(u64, delta) * @as(u64, @intCast(v)) / 100, 65535));
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
            if (place_id != cur_id) {
                // Replacing one block with another displaces the old one just
                // as removing it would, then the new one claims what its own
                // type owns. Only clearing on place_id == 0 caught removals
                // and missed every swap.
                if (self.sim.power.removeAt(b.x, b.y, b.z)) self.sim.power.resolve();
                self.vending.removeAt(.{ .x = b.x, .y = b.y, .z = b.z });
            }
            self.noteBlockAdded(b.x, b.y, b.z, place_id);
            // Sparse block_raw is a write-through mirror of the chunk plane
            // (GAP 13). Any place that does not store a fresh client raw must
            // drop a prior hit so blockRawAt cannot echo stale rotation/meta
            // for a bare-id or downgrade write.
            if (place_id != 0 and b.raw != 0 and place_down_raw == 0) {
                self.setBlockRaw(b.x, b.y, b.z, b.raw);
            } else {
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
                self.sign_texts.remove(.{ .x = b.x, .y = b.y, .z = b.z });
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
    return false;
}
