//! C2S inventory arms: transaction requests, data requests.
//!
//! Split out of c2s/inv.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const ecs = @import("../../ecs/root.zig");
const invsys = @import("../../ecs/inventory.zig");
const inv_apply = @import("../inv_apply.zig");
const reverseItemType = game_mod.Game.reverseItemType;
const resolveItemType = game_mod.Game.resolveItemType;
const scrubIllegalMods = @import("inv_reload.zig").scrubIllegalMods;
const game_locks = @import("../game/locks.zig");
const eatProps = game_mod.Game.eatProps;
const containers_mod = @import("../../world/containers.zig");

/// True when `name` is a transaction/data package and was handled.
pub fn handleTxn(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (std.mem.eql(u8, name, "NetPackageInventoryTransactionRequest")) {
        if (!self.takeInvToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        // A real stock client sends InventoryTransaction.Write (RE
        // protocol-packages.md 6.13). Try the stock layout first: the native
        // 11-byte parser only checks len >= 11, so a stock body would
        // otherwise be misread as a native request. Native bodies fail the
        // stock parse (the first i32 count misreads the op bytes).
        if (packages.parseStockInvTx(body) catch null) |stx| {
            // Apply the stock ops to the player's inventory (same
            // client-trust model as ADR 0007 PlayerInventory: the C2S
            // PlayerInventory push is already authoritative, so a stock
            // backpack/container transaction is no wider a surface) and ack
            // with the stock minimal response. The Guid registry population
            // path is unpinned RE, so the player's own transactions accept
            // without key validation; bounds + stack caps hold.
            self.harness.counters.inc(.c2s_stock_invtx);
            if (self.sim.playerByPeer(c.slot)) |ps| {
                if (self.sim.mask[ps].inventory) {
                    var ok = true;
                    // Stage into a copy and commit only on success. Stock
                    // applies the whole InventoryTransaction and then checks
                    // ValidateFinalHashes (InventoryManager
                    // TransactionRequestServer IL=46); a failure there force-
                    // unlocks and sends nothing, so a rejected transaction
                    // never leaves half its ops applied. The SetAbsolute /
                    // SetRelative arm used to write straight into the live
                    // inventory, so an op that failed after an earlier one had
                    // landed left those stacks applied, unclamped (the clamp
                    // sits in the success branch) and unreplicated.
                    var staged = self.sim.inventory[ps].slots;
                    for (stx.entries[0..stx.entry_n]) |*en| {
                        for (en.ops[0..en.op_n]) |op| {
                            switch (op.op) {
                                0, 1 => { // SetAbsolute / SetRelative:
                                    // the client's reported stack at the index
                                    // is authoritative
                                    if (op.index < 0 or op.index >= @as(i32, @intCast(ecs.components.max_inv_slots))) {
                                        ok = false;
                                        continue;
                                    }
                                    const slot = packages.stock_inv.toEcs(op.stack, reverseItemType, self);
                                    // T18 hardening: a NON-EMPTY client stack
                                    // that does not resolve to a server
                                    // catalog item is a reject, not a silent
                                    // clear - the ack must tell the client the
                                    // transaction failed (fail-closed, honest
                                    // success bit).
                                    if (op.stack.type_id != 0 and op.stack.count != 0 and slot.item_id == 0) {
                                        ok = false;
                                        self.harness.counters.inc(.c2s_rejects);
                                        continue;
                                    }
                                    staged[@intCast(op.index)] = slot;
                                },
                                2 => { // SetAll: replace the inventory array
                                    if (op.new_n > ecs.components.max_inv_slots) {
                                        ok = false;
                                        continue;
                                    }
                                    var slots: [ecs.components.max_inv_slots]ecs.components.InvSlot = @splat(.{});
                                    var si: u16 = 0;
                                    while (si < op.new_n) : (si += 1) {
                                        const slot = packages.stock_inv.toEcs(op.new_stacks[si], reverseItemType, self);
                                        // Same T18 reject: an unresolvable
                                        // non-empty stack fails the whole tx.
                                        if (op.new_stacks[si].type_id != 0 and op.new_stacks[si].count != 0 and slot.item_id == 0) {
                                            ok = false;
                                            self.harness.counters.inc(.c2s_rejects);
                                            break;
                                        }
                                        slots[si] = slot;
                                    }
                                    if (ok) staged = slots;
                                },
                                else => ok = false,
                            }
                        }
                    }
                    if (ok) {
                        self.sim.inventory[ps].slots = staged;
                        self.clampInventoryStacks(&self.sim.inventory[ps]);
                        // Stock minimal ack: success true + count 0 (full
                        // stacks ride only for non-primary players).
                        var ack: [5]u8 = .{ 1, 0, 0, 0, 0 };
                        try self.sendGame(peer, "NetPackageInventoryTransactionResponse", &ack);
                    } else {
                        // Stock TransactionRequestServer (IL=46, RE
                        // protocol-packages.md:1245): a failed apply logs and
                        // calls LockManager.ForceUnlockByPlayer. The client's
                        // window is showing a transaction the server refused,
                        // so leaving the lock held keeps that window open over
                        // a container whose contents no longer match, and pins
                        // the channel against everyone else.
                        self.harness.counters.inc(.c2s_rejects);
                        self.releaseOtherLocksForPeer(c.slot, game_locks.keep_no_channel);
                    }
                }
            }
            return true;
        }
        const tx = packages.parseInvTxRequest(body) catch return true;
        var r: invsys.Result = .{};
        var bag_pos: ?[3]i32 = null;
        // Captured before apply: a rejected place must refund what it consumed.
        const place_item_id: u16 = blk: {
            if (tx.op != @intFromEnum(invsys.Op.place) and tx.op != @intFromEnum(invsys.Op.use)) break :blk 0;
            if (tx.a >= ecs.components.max_inv_slots) break :blk 0;
            const ps = self.sim.playerByPeer(c.slot) orelse break :blk 0;
            if (!self.sim.mask[ps].inventory) break :blk 0;
            break :blk self.sim.inventory[ps].slots[tx.a].item_id;
        };
        const ledger_before = self.sim.inv_ledger.total;
        if (tx.op == @intFromEnum(invsys.Op.craft)) {
            r = .{ .ok = self.tryCraft(c.slot, tx.a, if (tx.qty == 0) 1 else tx.qty) };
        } else if (tx.op == @intFromEnum(invsys.Op.scrap)) {
            r = .{ .ok = self.tryScrap(c.slot, tx.a, if (tx.qty == 0) 1 else tx.qty) };
        } else if (tx.op > @intFromEnum(invsys.Op.equip)) {
            // Compact path: craft/scrap are handled above; any other op past
            // equip is unknown. Mapping unknowns to `.list` used to ack success
            // with no mutation (fail-open); stock InvTx rejects instead.
            r = .{ .ok = false };
            self.harness.counters.inc(.c2s_rejects);
        } else {
            const op: invsys.Op = @enumFromInt(tx.op);
            // Per-surface quarantine, the same gate the Bag and TileEntity
            // arms apply. This one packet reaches both surfaces: open / take /
            // put mutate a container's contents, and place writes a world
            // block. Ungated, a peer quarantined off either surface kept
            // working through the transaction route while its direct packets
            // were refused.
            switch (op) {
                .open, .take, .put => if (self.quarantineDenies(c, .container)) return true,
                .place => if (self.quarantineDenies(c, .block)) return true,
                else => {},
            }
            // Repair-by-combine first: dragging a damaged tool onto another
            // is MergeBest, not a move/swap. Falls through to the normal
            // path when the pair does not combine.
            if (op == .move and self.tryCombineTools(c.slot, tx.a, tx.b)) {
                var ack: [5]u8 = .{ 1, 0, 0, 0, 0 };
                try self.sendGame(peer, "NetPackageInventoryTransactionResponse", &ack);
                return true;
            }
            // The open bag's position, read while it still exists: a drain
            // that empties it destroys the entity, and the marker is keyed by
            // position.
            if (op == .take) {
                if (self.sim.playerByPeer(c.slot)) |tps| {
                    const cid = self.sim.inventory[tps].open_container;
                    if (cid > 0) {
                        if (self.sim.slotOfNetId(cid)) |bs| {
                            if (self.sim.mask[bs].transform) {
                                const bt = self.sim.transform[bs];
                                bag_pos = .{ @trunc(bt.x), @trunc(bt.y), @trunc(bt.z) };
                            }
                        }
                    }
                }
            }
            // ItemActionEat: resolve food/water/hp from items.xml via eatProps.
            r = invsys.applyTransactionEx(&self.sim, c.slot, op, tx.a, tx.b, tx.qty, tx.entity_id, eatProps, self);
        }
        // Draining a death bag slot-by-slot destroys it the same way
        // collecting the whole bag does, so the backpack marker must clear on
        // both, or the map keeps a marker on a bag that no longer exists.
        // The position has to be read before the drain: the entity is gone by
        // the time `emptied_bag` reports it.
        if (r.ok and r.emptied_bag > 0) {
            if (bag_pos) |bp| {
                if (c.removeBackpackAt(bp[0], bp[1], bp[2])) {
                    self.broadcastPlayerBackpack(c) catch {};
                }
            }
        }
        if (r.ok and r.place_block != 0) {
            // Land claim is authoritative on every apply path (ADR 0004); the
            // InvTx place route must not be a way around it. Refund the unit the
            // transaction already consumed (mirrors the refuel path).
            if (self.claimCovering(r.place_x, r.place_z)) |claim| {
                if (claim.owner_entity != c.entity_id) {
                    if (place_item_id != 0) _ = invsys.give(&self.sim, c.slot, place_item_id, 1);
                    r.ok = false;
                }
            }
        }
        if (r.ok and r.place_block != 0) {
            try self.world.setBlockWorld(r.place_x, r.place_y, r.place_z, r.place_block);
            // Drop any prior sparse raw at this cell so a re-place cannot
            // echo stale rotation/meta over the bare placed id (GAP 13).
            self.clearBlockRaw(r.place_x, r.place_y, r.place_z);
            // A placed bedroll becomes the player's respawn point (stock
            // bedroll blocks set EntityPlayer.spawnPoint on placement).
            if (self.isBedrollId(r.place_block)) {
                c.bed_x = r.place_x;
                c.bed_y = r.place_y;
                c.bed_z = r.place_z;
                c.has_bed = true;
            }
            const sb = try packages.buildSetBlockBody(&self.body_buf, r.place_x, r.place_y, r.place_z, r.place_block);
            try self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(r.place_x), @floatFromInt(r.place_z), self.interest_range);
            // Power nodes from placeable generators (same path as SetBlock).
            if (self.power_registry.lookup(r.place_block)) |pn| {
                if (self.sim.power.addNodeAt(pn.kind, r.place_x, r.place_y, r.place_z, pn.watts)) |nid| {
                    if (self.sim.power.indexOfId(nid)) |ni| pn.applyToNode(&self.sim.power.nodes[ni]);
                }
                self.sim.power.resolve();
            }
        } else if (r.ok and r.refuel_amount > 0) {
            // Gas can / FuelValue item used on a vehicle or at generator coords
            // (InvTx place). Vehicle first: the client targets the body.
            if (!self.tryRefuelVehicle(c, r.place_x, r.place_y, r.place_z, r.refuel_amount)) {
                if (!self.tryRefuelGenerator(c, r.place_x, r.place_y, r.place_z, r.refuel_amount)) {
                    // Refund the consumed fuel unit (inventory already took one).
                    if (r.refuel_item_id != 0) _ = invsys.give(&self.sim, c.slot, r.refuel_item_id, 1);
                    r.ok = false;
                }
            }
        }
        // Refunds via give() also append; count all ledger appends for this C2S.
        const ledger_delta = self.sim.inv_ledger.total -% ledger_before;
        if (ledger_delta != 0) self.harness.counters.add(.inv_ledger_events, ledger_delta);
        var head_buf: [16]u8 = undefined;
        const head = try packages.buildInvTxResponseHead(&head_buf, r.ok, r.dropped_entity);
        // Stock inventory (toolbelt 10 + bag 45 + equip) needs ~0.5–3 KiB.
        var snap: [4096]u8 = undefined;
        const inv_body = try self.buildInventorySnap(c, &snap);
        if (head.len + inv_body.len <= self.body_buf.len) {
            @memcpy(self.body_buf[0..head.len], head);
            @memcpy(self.body_buf[head.len..][0..inv_body.len], inv_body);
            try self.sendGame(peer, "NetPackageInventoryTransactionResponse", self.body_buf[0 .. head.len + inv_body.len]);
        }
        if (r.dropped_entity > 0) {
            try self.broadcastLootSpawn(r.dropped_entity);
        }
        // ItemActionEat.consume → EntityStatChanged food/water/health (stock path).
        if (r.ok and r.ate and c.entity_id > 0) {
            self.grantMagazineRead(c.slot, place_item_id);
            try self.sendSurvivalStats(peer, c.entity_id, r.hp, r.max_hp, r.food, r.food_max, r.water, r.water_max);
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageInventoryDataRequest")) {
        // Rate gate: each request serves up to 54 container slots; unthrottled
        // a spam loop turns a few bytes into a full response per packet.
        if (!self.takeInvToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        // Stock: KeyHashPair (Guid+hash) + managerToken Guid.
        // Serve TE container slots when Guid matches our deterministic pos-key.
        if (packages.parseInvDataRequestStock(body)) |req| {
            if (self.containers.getByGuid(&req.inventory_key)) |cont| {
                // Stock LootManager.LootContainerOpened: an untouched world
                // container rolls here with the opener's loot stage (the roll
                // no longer happens at chunk load), and a looted one re-rolls
                // once LootRespawnDays have elapsed.
                self.ensureContainerLoot(cont, c.slot);
                var slots: [containers_mod.max_container_slots]packages.stock_inv.StockSlot =
                    [_]packages.stock_inv.StockSlot{.{}} ** containers_mod.max_container_slots;
                var si: usize = 0;
                const n: usize = cont.slot_count;
                while (si < n) : (si += 1) {
                    const s = cont.slots[si];
                    if (s.count > 0 and s.item_id != 0) {
                        slots[si] = .{
                            .type_id = self.items.stockTypeFor(s.item_id),
                            .count = s.count,
                            .quality = s.quality,
                            .meta = s.meta,
                        };
                    }
                }
                const resp = try packages.buildInvDataResponseItems(
                    &self.body_buf,
                    req.inventory_key,
                    req.manager_token,
                    slots[0..n],
                );
                try self.sendGame(peer, "NetPackageInventoryDataResponse", resp);
            } else {
                const resp = try packages.buildInvDataResponseNotFound(
                    &self.body_buf,
                    req.inventory_key,
                    req.manager_token,
                );
                try self.sendGame(peer, "NetPackageInventoryDataResponse", resp);
            }
        } else |_| if (packages.parseInvDataRequest(body)) |eid| {
            if (self.sim.slotOfNetId(eid)) |si| {
                // Loot containers only: another player's slots are not a
                // lootable inventory, and echoing them leaks their bag.
                if (self.sim.mask[si].inventory and !self.sim.mask[si].player) {
                    const body_out = try packages.buildInventoryBodyStockResolved(
                        &self.body_buf,
                        &self.sim.inventory[si],
                        resolveItemType,
                        self,
                    );
                    try self.sendGame(peer, "NetPackageInventoryDataResponse", body_out);
                    _ = invsys.openContainer(&self.sim, c.slot, eid);
                }
            }
        } else |_| {}
        return true;
    }
    return false;
}
