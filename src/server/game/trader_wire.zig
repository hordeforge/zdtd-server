//! Trader wire helpers extracted from game.zig.
//! stockEntries + sendTraderSnapshot + handleTrade + applyTraderDataCopyFrom.

const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const packages = @import("../../wire/packages.zig");
const ecs = @import("../../ecs/root.zig");
const systems = @import("../../ecs/systems.zig");
const replicate_te = @import("../replicate_te.zig");

pub fn stockEntries(self: *Game, s: ecs.Slot, out: []packages.TraderStockEntry) usize {
    const stock = self.sim.trader_stock[s];
    var n: usize = 0;
    var e: usize = 0;
    while (e < stock.n and n < out.len) : (e += 1) {
        const ent = stock.entries[e];
        if (ent.count == 0) continue;
        const type_id: i32 = Game.resolveItemType(self, ent.item);
        out[n] = .{
            .item = .{ .type_id = type_id, .count = if (ent.count > 0) ent.count else 1, .quality = ent.quality },
            .markup = ent.markup,
        };
        n += 1;
    }
    return n;
}

pub fn handleTrade(self: *Game, c: *Client, body: []const u8) !void {
    const t = packages.parseTraderTrade(body) catch return;
    if (t.side == 1) {
        if (self.sim.slotOfNetId(t.trader_entity)) |ts| {
            const info_id = self.sim.trader_stock[ts].trader_info_id;
            if (info_id != 0) {
                if (self.traders.traderInfo(info_id)) |info| {
                    if (!info.allow_sell) return;
                }
            }
        }
    }
    const coin = self.coinItemId();
    const traded = systems.trade(&self.sim, c.slot, t.trader_entity, t.item, t.qty, t.side, coin);
    // Wasm-first (AGENTS rule 29): trader announcements react through a
    // plugin, not native code (kind 1 buy / 2 sell; stock side 0=buy 1=sell).
    if (traded) {
        const kind: i32 = if (t.side == 0) 1 else 2;
        self.plugins.traderEvent(c.entity_id, t.trader_entity, kind);
        self.wasm_plugins.traderEvent(c.entity_id, t.trader_entity, kind);
    }
    if (c.peer) |p| {
        const ts = self.sim.slotOfNetId(t.trader_entity);
        try self.sendTraderSnapshot(p, ts);
    }
}

pub fn applyTraderDataCopyFrom(self: *Game, c: *Client, td: packages.TraderDataToServer) !void {
    // TraderData ToServer is a client-side cache copy, not an authoritative
    // transaction. Applying its stock or money lets any joined peer mint
    // inventory and rewrite the shared trader economy. The typed trade path
    // above is the only path that may mutate an entity trader.
    if (td.is_entity) {
        const ts = self.sim.slotOfNetId(td.entity_id) orelse return;
        if (!self.sim.mask[ts].trader_stock) return;
        if (c.peer) |p| try self.sendTraderSnapshot(p, ts);
        return;
    }

    // Vending stock is likewise server-owned. Only acknowledge a nearby
    // owner's copy-back and re-send the stored TE; never apply its item list
    // or available-money field.
    const vm = self.vending.get(.{ .x = td.te_x, .y = td.te_y, .z = td.te_z }) orelse return;
    const mine = c.puid_primary.get() orelse c.puid_native.get() orelse return;
    if (!vm.owner.matches(mine)) return;
    const ps = self.sim.playerByPeer(c.slot) orelse return;
    const p = self.sim.transform[ps];
    if (!self.withinEditReach(p.x, p.y, p.z, @floatFromInt(td.te_x), @floatFromInt(td.te_y), @floatFromInt(td.te_z))) return;
    if (c.peer) |peer| try replicate_te.sendVendingTe(self, peer, td.te_x, td.te_y, td.te_z);
}
