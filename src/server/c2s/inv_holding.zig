//! C2S inventory arms: holding item, item drop, bag access.
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

/// True when `name` is a holding/drop/bag package and was handled.
pub fn handleHolding(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (std.mem.eql(u8, name, "NetPackageHoldingItem")) {
        // Rate gate: unthrottled, a spam loop would fan the held-item echo
        // out to every nearby peer for free (same rationale as SetBlock).
        if (!self.takeInvToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        const h = packages.stock_inv.readHoldingItem(body) catch return true;
        if (h.entity_id != 0 and self.rejectIfNotSender(c, peer.local_id, h.entity_id, .none)) return true;
        const ps = self.sim.playerByPeer(c.slot) orelse return true;
        if (!self.sim.mask[ps].inventory) return true;
        if (h.holding_index < ecs.components.inv_toolbelt) {
            _ = self.sim.inventory[ps].setHolding(h.holding_index);
        }
        // Rebroadcast to other peers (stock server behavior).
        const hb = try packages.buildHoldingBodyResolved(
            &self.body_buf,
            c.entity_id,
            &self.sim.inventory[ps],
            resolveItemType,
            self,
        );
        try self.broadcastExcept("NetPackageHoldingItem", hb, c.slot);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageItemDrop")) {
        // Rate gate: each accepted drop spawns an item entity + broadcast to
        // observers; without the token a spam loop amplifies C2S bandwidth.
        if (!self.takeInvToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        const d = packages.stock_inv.readItemDrop(body) catch return true;
        const item_id = reverseItemType(self, d.stack.type_id);
        if (item_id == 0 or d.stack.count == 0) return true;
        // Prefer drop from matching player stack; else spawn at drop pos.
        var dropped: i32 = -1;
        const ps = self.sim.playerByPeer(c.slot) orelse return true;
        if (self.sim.mask[ps].inventory) {
            var slot_i: u16 = 0;
            while (slot_i < ecs.components.max_inv_slots) : (slot_i += 1) {
                const s = self.sim.inventory[ps].slots[slot_i];
                if (s.item_id == item_id and s.count > 0) {
                    const qty = @min(s.count, d.stack.count);
                    const r = invsys.applyTransaction(&self.sim, c.slot, .drop, slot_i, 0, qty, -1);
                    dropped = r.dropped_entity;
                    break;
                }
            }
        }
        // The server inventory is authoritative. A claimed stack that was
        // not actually present must not materialize a new item entity.
        if (dropped > 0) {
            // Stock ItemDropServer → EntityItem (class "item"), not death bag.
            try self.broadcastItemDropSpawn(dropped, d.stack, c.entity_id, d.client_instance_id);
            // EntitySpawnResponse(success, item): the thrower's client DecItems
            // its own inventory on receipt, committing the drop. Without it the
            // stack stays in the client bag until the next inventory sync.
            if (packages.buildEntitySpawnResponse(self.body_buf[16..48], true, d.stack)) |rb| {
                try self.sendGame(peer, "NetPackageEntitySpawnResponse", rb);
            } else |_| {}
            try self.sendHoldingEcho(peer, c);
            // Rebaseline eatable units so Path C does not treat drop as eat.
            if (self.sim.mask[ps].inventory) {
                var eat_n: u32 = 0;
                for (self.sim.inventory[ps].slots) |sl| {
                    if (sl.count == 0 or sl.item_id == 0) continue;
                    if (self.items.isEat(sl.item_id)) eat_n += sl.count;
                }
                c.last_eatable_units = eat_n;
            }
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageBag")) {
        // Same container quarantine the TileEntity arm applies. Both write
        // client-supplied item contents into a non-player entity (this one
        // reaches loot bags and vehicle baskets), so a peer quarantined off
        // the container surface could keep rewriting bags through here while
        // its TE writes were denied.
        if (self.quarantineDenies(c, .container)) return true;
        // Rate gate: a bag write mutates inventory and echoes to every other
        // peer; unthrottled it is the same broadcast-amplification hole as
        // the SetBlock relay.
        if (!self.takeInvToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        const entity_id = packages.stock_inv.peekBagEntityId(body) catch return true;
        if (entity_id == c.entity_id or entity_id == 0) {
            const ps = self.sim.playerByPeer(c.slot) orelse return true;
            if (!self.sim.mask[ps].inventory) return true;
            _ = inv_apply.applyBagPackage(body, &self.sim.inventory[ps], reverseItemType, self, true) catch return true;
            self.clampInventoryStacks(&self.sim.inventory[ps]);
        } else if (self.sim.slotOfNetId(entity_id)) |si| {
            // Ownership: never let a peer write another player's inventory.
            if (self.sim.mask[si].player) {
                self.harness.counters.inc(.ownership_rejects);
                return true;
            }
            // Reach: same as Collect/TE. Without this, any peer can rewrite
            // distant loot-bag (or other non-player inv) contents by id.
            const ps = self.sim.playerByPeer(c.slot) orelse return true;
            const pp = self.sim.transform[ps];
            const bp = self.sim.transform[si];
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
            if (self.sim.mask[si].inventory) {
                _ = inv_apply.applyBagPackage(body, &self.sim.inventory[si], reverseItemType, self, false) catch return true;
                self.clampInventoryStacks(&self.sim.inventory[si]);
            } else if (self.sim.mask[si].vehicle) {
                // Vehicle basket (RE NetPackageBag write IL=19 / read IL=16,
                // research dedicated-misc-systems.md vehicle storage pin v2):
                // the basket is Entity.bag, synced as a Bag.Write blob. Apply
                // to the vehicle's fixed basket array (item ids validated by
                // the reverse resolver) and echo the raw body to the other
                // clients, since the stock S2C broadcast sender is unpinned.
                var wire_slots: [ecs.components.max_basket_slots]packages.stock_inv.StockSlot = undefined;
                const parsed = packages.stock_inv.parseBagBody(body, wire_slots[0..]) catch {
                    self.harness.counters.inc(.c2s_malformed);
                    return true;
                };
                const v = &self.sim.vehicle[si];
                var bi: usize = 0;
                while (bi < ecs.components.max_basket_slots) : (bi += 1) {
                    v.basket[bi] = if (bi < parsed.n)
                        packages.stock_inv.toEcs(wire_slots[bi], reverseItemType, self)
                    else
                        .{};
                }
                v.basket_n = @intCast(parsed.n);
                // Same stack clamp the player-inventory branch above applies,
                // and the container / workstation TE bodies below. The basket
                // is a client-writable InvSlot group like the rest, so an
                // over-cap count here was the one way to write a stack past
                // its items.xml Stacknumber and have it persist.
                self.clampStackSlots(v.basket[0..v.basket_n]);
                try self.broadcastExcept("NetPackageBag", body, c.slot);
            }
        } else return true;
        try self.sendHoldingEcho(peer, c);
        return true;
    }
    return false;
}
