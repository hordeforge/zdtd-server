//! Trader wire helpers extracted from game.zig.
//! stockEntries + sendTraderSnapshot + handleTrade + applyTraderDataCopyFrom.

const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const packages = @import("../../wire/packages.zig");
const wire_binary = @import("../../wire/binary.zig");
const ecs = @import("../../ecs/root.zig");
const systems = @import("../../ecs/systems.zig");
const replicate_te = @import("../replicate_te.zig");
const vending_mod = @import("../../world/vending.zig");

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
    _ = systems.trade(&self.sim, c.slot, t.trader_entity, t.item, t.qty, t.side, coin);
    if (c.peer) |p| {
        const ts = self.sim.slotOfNetId(t.trader_entity);
        try self.sendTraderSnapshot(p, ts);
    }
}

pub fn applyTraderDataCopyFrom(self: *Game, c: *Client, td: packages.TraderDataToServer) !void {
    var entries_buf: [ecs.components.max_stock]packages.stock_entity.TraderDataReadEntry = undefined;
    var tr: wire_binary.Reader = .{ .data = td.trader_data };
    const read = packages.stock_entity.readTraderDataBody(&tr, &entries_buf) catch return;
    if (td.is_entity) {
        const ts = self.sim.slotOfNetId(td.entity_id) orelse return;
        if (!self.sim.mask[ts].trader_stock) return;
        const st = &self.sim.trader_stock[ts];
        var i: usize = 0;
        while (i < read.n) : (i += 1) {
            const src = entries_buf[i];
            if (src.item.type_id == 0) {
                st.entries[i] = .{};
                continue;
            }
            const iname = self.items.nameByStockType(src.item.type_id) orelse continue;
            const eid = self.items.ecsIdByName(iname);
            if (eid == 0) continue;
            st.entries[i] = .{ .item = eid, .count = src.item.count, .markup = src.markup, .price = st.entries[i].price, .sell = st.entries[i].sell };
        }
        while (i < st.entries.len) : (i += 1) st.entries[i] = .{};
        if (read.money >= 0) st.wallet = read.money;
        if (c.peer) |p| try self.sendTraderSnapshot(p, ts);
        return;
    }
    const vm = self.vending.get(.{ .x = td.te_x, .y = td.te_y, .z = td.te_z }) orelse return;
    var i: usize = 0;
    while (i < read.n and i < vending_mod.max_vending_stock) : (i += 1) {
        const src = entries_buf[i];
        if (src.item.type_id == 0) {
            vm.stock[i] = .{};
            continue;
        }
        vm.stock[i] = .{ .type_id = src.item.type_id, .count = src.item.count, .markup = src.markup };
    }
    while (i < vending_mod.max_vending_stock) : (i += 1) vm.stock[i] = .{};
    if (read.money >= 0) vm.available_money = read.money;
    try replicate_te.sendVendingTe(self, c.peer.?, td.te_x, td.te_y, td.te_z);
}
