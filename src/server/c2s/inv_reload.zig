//! C2S inventory arms: item reload, player inventory snapshot.
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
const reverseItemType = game_mod.Game.reverseItemType;
const resolveItemType = game_mod.Game.resolveItemType;
const eatProps = game_mod.Game.eatProps;

/// curve[quality]) and tag gates (the mod's installable_tags intersects the
/// item's Tags, blocked_tags disjoint). Fail closed: unknown item, unknown
/// mod, empty installable gate, or count over budget → the slot's mods are
/// cleared (the client's next inventory sync corrects its view).
pub fn scrubIllegalMods(self: *Game, ps: ecs.Slot) void {
    const inv = &self.sim.inventory[ps];
    for (&inv.slots) |*sl| {
        if (sl.item_id == 0 or sl.mod_n == 0) continue;
        const item = self.items.byId(sl.item_id) orelse {
            sl.mod_n = 0;
            sl.mods = .{0} ** 4;
            continue;
        };
        if (sl.mod_n > self.items.modSlotsFor(sl.item_id, sl.quality)) {
            sl.mod_n = 0;
            sl.mods = .{0} ** 4;
            continue;
        }
        var ok = true;
        for (sl.mods[0..sl.mod_n]) |mid| {
            if (mid == 0) continue;
            const mod = self.items.byId(mid) orelse {
                ok = false;
                break;
            };
            if (!self.item_mods.isSuitable(mod.name, item.tags)) {
                ok = false;
                break;
            }
        }
        if (!ok) {
            sl.mod_n = 0;
            sl.mods = .{0} ** 4;
        }
    }
}

/// True when `name` belongs to this domain and was handled.
/// True when `name` is a reload/inventory package and was handled.
pub fn handleReload(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (std.mem.eql(u8, name, "NetPackageItemReload")) {
        // Reload relay. RE GameManager.ItemReloadServer IL=32: the dedi plays
        // the reload locally, then rebroadcasts NetPackageItemReload (single
        // i32 entityId body) to every peer but the sender (flags 192), so the
        // other players see the reload animation; the sender already started
        // its own reload locally and needs no echo.
        if (!self.takeInvToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        if (body.len < 4) return true;
        const entity_id = std.mem.readInt(i32, body[0..4], .little);
        // Bounds rule 20: the id must name a real player entity, or a spoofed
        // reload would fan out to every connected peer for free. The body
        // describes the sender's own weapon, so a foreign id is a claim on
        // another player's animation, not a relay the server owes.
        if (entity_id == 0) {
            self.harness.counters.inc(.ownership_rejects);
            return true;
        }
        if (self.rejectIfNotSender(c, peer.local_id, entity_id, .none)) return true;
        if (self.sim.slotOfNetId(entity_id) == null) return true;
        try self.broadcastExcept("NetPackageItemReload", body, c.slot);
        // Stock check-buff row (buffStatusCheck01 onReloadStart): while the
        // held weapon carries `reloadPenalty` the reloader walks slowed
        // (buffReloadMovementPenalty, RunAndGun-gated Walk/RunSpeed rows).
        // Fired through the shared engine so the held-tag gate applies.
        if (self.sim.slotOfNetId(entity_id)) |ps| {
            self.fireReloadStart(ps);
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackagePlayerInventory")) {
        if (!self.takeInvToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        const ps = self.sim.playerByPeer(c.slot) orelse return true;
        if (!self.sim.mask[ps].inventory) return true;
        var before: [64]struct { id: u16, n: u32 } = undefined;
        var bn: usize = 0;
        var before_total: u32 = 0;
        for (self.sim.inventory[ps].slots) |sl| {
            if (sl.count == 0 or sl.item_id == 0) continue;
            if (!self.items.isEat(sl.item_id)) continue;
            before_total += sl.count;
            var found = false;
            for (before[0..bn]) |*e| {
                if (e.id == sl.item_id) {
                    e.n += sl.count;
                    found = true;
                    break;
                }
            }
            if (!found and bn < before.len) {
                before[bn] = .{ .id = sl.item_id, .n = sl.count };
                bn += 1;
            }
        }
        const baseline_total = if (before_total > 0) before_total else c.last_eatable_units;
        // Apply may partially mutate toolbelt then fail on bag/equip/prefs.
        // Keep stack-loss detect even on error (toolbelt is first on the wire).
        packages.stock_inv.applyPlayerInventoryBody(body, &self.sim.inventory[ps], reverseItemType, self) catch |err| {
            std.debug.print("zdtd: PlayerInventory apply err={s} body={d} peer={d}\n", .{ @errorName(err), body.len, c.slot });
        };
        self.clampInventoryStacks(&self.sim.inventory[ps]);
        scrubIllegalMods(self, ps);
        var after_total: u32 = 0;
        var first_eat_id: u16 = 0;
        for (self.sim.inventory[ps].slots) |sl| {
            if (sl.count == 0 or sl.item_id == 0) continue;
            if (!self.items.isEat(sl.item_id)) continue;
            after_total += sl.count;
            if (first_eat_id == 0) first_eat_id = sl.item_id;
        }
        // Body-side eatable count by stock type (reverse-independent).
        const body_eat = packages.stock_inv.countEatableInPlayerInventoryBody(
            body,
            reverseItemType,
            self,
            struct {
                fn isEatStock(ctx: ?*anyopaque, stock_type: i32) bool {
                    const g: *Game = @ptrCast(@alignCast(ctx.?));
                    return g.items.isEatStockType(stock_type);
                }
            }.isEatStock,
        );
        if (first_eat_id == 0 and body_eat.first_ecs != 0) first_eat_id = body_eat.first_ecs;

        if (self.sim.mask[ps].health and c.entity_id > 0) {
            var ate_any = false;
            var units_left: u32 = self.sim.rules.c2s.eat_units_per_push;
            // Path A: per-id loss within this package (ECS before → after).
            for (before[0..bn]) |e| {
                if (units_left == 0) break;
                var after_n: u32 = 0;
                for (self.sim.inventory[ps].slots) |sl| {
                    if (sl.item_id == e.id) after_n += sl.count;
                }
                if (after_n >= e.n) continue;
                const lost = @min(e.n - after_n, units_left);
                var u: u32 = 0;
                while (u < lost) : (u += 1) {
                    const props = eatProps(self, e.id);
                    const r = invsys.applyEatProps(&self.sim, ps, props);
                    if (!r.ate) break;
                    self.grantMagazineRead(c.slot, e.id);
                    self.fireItemUseBuffs(ps, e.id);
                    ate_any = true;
                    units_left -= 1;
                }
            }
            // Path B: ECS aggregate drop vs baseline (only with known eat id).
            if (!ate_any and baseline_total > after_total and units_left > 0) {
                const lost = @min(baseline_total - after_total, units_left);
                var eid: u16 = first_eat_id;
                if (eid == 0 and bn > 0) eid = before[0].id;
                if (eid == 0 and body_eat.first_ecs != 0) eid = body_eat.first_ecs;
                if (eid != 0 and self.items.isEat(eid)) {
                    var u: u32 = 0;
                    while (u < lost) : (u += 1) {
                        const props = eatProps(self, eid);
                        const r = invsys.applyEatProps(&self.sim, ps, props);
                        if (!r.ate) break;
                        self.grantMagazineRead(c.slot, eid);
                        self.fireItemUseBuffs(ps, eid);
                        ate_any = true;
                        units_left -= 1;
                    }
                }
            }
            // Path C: body stock-type count dropped vs last_eatable (primary live path).
            // Require a resolved eatable ecs id. Do not invent chili/beef/id=2 props
            // for unknown multi-unit losses (drop/trade false-eat under ADR 0007).
            if (!ate_any and c.last_eatable_units > body_eat.total and units_left > 0) {
                const lost = @min(c.last_eatable_units - body_eat.total, units_left);
                var eid: u16 = body_eat.first_ecs;
                if (eid == 0 and first_eat_id != 0) eid = first_eat_id;
                if (eid == 0 and bn > 0) eid = before[0].id;
                if (eid != 0 and self.items.isEat(eid)) {
                    var u: u32 = 0;
                    while (u < lost) : (u += 1) {
                        const props = eatProps(self, eid);
                        const r = invsys.applyEatProps(&self.sim, ps, props);
                        if (!r.ate) break;
                        self.grantMagazineRead(c.slot, eid);
                        self.fireItemUseBuffs(ps, eid);
                        ate_any = true;
                        units_left -= 1;
                    }
                } else if (lost > 0) {
                    std.debug.print("zdtd: PI eatable drop skipped (no eat eid) lost={d} last={d} body_eat={d} stock0={d}\n", .{
                        lost, c.last_eatable_units, body_eat.total, body_eat.first_stock,
                    });
                }
            }
            if (ate_any) {
                const h = self.sim.health[ps];
                std.debug.print("zdtd: ItemActionEat stack-loss food={d:.1} before={d} after={d} last={d} body_eat={d} stock0={d}\n", .{
                    h.food, before_total, after_total, c.last_eatable_units, body_eat.total, body_eat.first_stock,
                });
                try self.sendSurvivalStats(peer, c.entity_id, h.hp, h.max_hp, h.food, h.food_max, h.water, h.water_max);
            } else if (body_eat.total != c.last_eatable_units or before_total != after_total) {
                std.debug.print("zdtd: PI eatable before={d} after={d} last={d} body={d} body_eat={d} stock0={d}\n", .{
                    before_total, after_total, c.last_eatable_units, body.len, body_eat.total, body_eat.first_stock,
                });
            }
        }
        // Body-driven baseline so seed→eat works even when reverse leaves ECS empty.
        c.last_eatable_units = body_eat.total;
        return true;
    }
    return false;
}
