//! Trader wire helpers extracted from game.zig.
//! stockEntries + sendTraderSnapshot + handleTrade + applyTraderDataCopyFrom.

const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const packages = @import("../../wire/packages.zig");
const ecs = @import("../../ecs/root.zig");
const systems = @import("../../ecs/systems.zig");
const replicate_te = @import("../replicate_te.zig");
const wire_binary = @import("../../wire/binary.zig");
const vending_mod = @import("../../world/vending.zig");

/// Trader/vending trade reach (blocks). The client can only open the trade
/// window by activating the NPC or machine in use range, so an echo from
/// beyond this distance is dropped. Stock trusts the echo blindly
/// (TraderData.CopyFrom on the raw key, loot-economy.md 5); this gate closes
/// the "rewrite any trader from anywhere" vector without affecting a
/// legitimate trade. Reach is `[sim] trader_use_range` (Game.trade_use_range).

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
    // NetPackageTraderData ToServer carries the client's post-trade TraderData
    // copy (loot-economy.md 5: stock's ProcessPackage does TraderData.CopyFrom
    // onto the live EntityTrader or TileEntityVendingMachine; the wire carries
    // no price, so count/markup/money come from the echo while price/sell stay
    // server-owned). Apply it stock-faithfully, gated on trade reach and with
    // item-type resolution + quality bounds so a remote peer cannot rewrite
    // the shared economy. Entries are matched by item type (the client may
    // drop a depleted entry or append a sold one), not by index.
    var entries_buf: [ecs.components.max_stock]packages.stock_entity.TraderDataReadEntry = undefined;
    var tr: wire_binary.Reader = .{ .data = td.trader_data };
    const read = packages.stock_entity.readTraderDataBody(&tr, &entries_buf) catch return;

    if (td.is_entity) {
        const ts = self.sim.slotOfNetId(td.entity_id) orelse return;
        if (!self.sim.mask[ts].trader_stock) return;
        const epos = self.sim.transform[ts];
        if (!inTradeReach(self, c, epos.x, epos.y, epos.z)) return;
        const st = &self.sim.trader_stock[ts];
        // Atomic: validate and map before mutating. Any bad entry aborts without
        // partial trader state. `target` holds the server entry index for each
        // echo entry (-1 = no server match / no mutation yet).
        var target: [ecs.components.max_stock]i16 = [_]i16{-1} ** ecs.components.max_stock;
        var used: [ecs.components.max_stock]bool = [_]bool{false} ** ecs.components.max_stock;
        var i: usize = 0;
        while (i < read.n) : (i += 1) {
            const src = entries_buf[i];
            if (src.item.type_id == 0) continue;
            if (src.item.quality < 1 or src.item.quality > 6) return;
            const iname = self.items.nameByStockType(src.item.type_id) orelse return;
            const eid = self.items.ecsIdByName(iname);
            if (eid == 0) return;
            var si: usize = 0;
            while (si < st.entries.len) : (si += 1) {
                if (!used[si] and st.entries[si].item == eid) {
                    used[si] = true;
                    target[i] = @intCast(si);
                    break;
                }
            }
        }
        // All validated: apply.
        i = 0;
        while (i < read.n) : (i += 1) {
            const ti = target[i];
            if (ti < 0) continue;
            const src = entries_buf[i];
            const si: usize = @intCast(ti);
            st.entries[si].count = src.item.count;
            st.entries[si].quality = @intCast(src.item.quality);
            st.entries[si].markup = src.markup;
        }
        // Entries the echo no longer carries were bought out (stock removes a
        // depleted PrimaryInventory row); clear them.
        i = 0;
        while (i < st.entries.len) : (i += 1) {
            if (!used[i]) st.entries[i] = .{};
        }
        if (read.money >= 0) st.wallet = read.money;
        if (c.peer) |p| try self.sendTraderSnapshot(p, ts);
        return;
    }

    const vm = self.vending.get(.{ .x = td.te_x, .y = td.te_y, .z = td.te_z }) orelse return;
    if (!inTradeReach(self, c, @floatFromInt(td.te_x), @floatFromInt(td.te_y), @floatFromInt(td.te_z))) return;
    // Atomic: validate whole batch, plan mutations, then apply. Record desired
    // per-echo mutation as target slot + counts/quality so no partial vending
    // state leaks on a bad tail entry.
    const Pending = struct { slot: i16 = -1, type_id: i32 = 0, count: i32 = 0, quality: u8 = 1, markup: i8 = 0, is_append: bool = false };
    var pending: [vending_mod.max_vending_stock + ecs.components.max_stock]Pending = [_]Pending{.{}} ** (vending_mod.max_vending_stock + ecs.components.max_stock);
    var pending_n: usize = 0;
    var used_plan: [vending_mod.max_vending_stock]bool = [_]bool{false} ** vending_mod.max_vending_stock;
    // First pass: validate and reserve slots without mutating vm.stock.
    var pi: usize = 0;
    while (pi < read.n) : (pi += 1) {
        const src = entries_buf[pi];
        if (src.item.type_id == 0) continue;
        if (src.item.quality < 1 or src.item.quality > 6) return;
        if (self.items.nameByStockType(src.item.type_id) == null) return;
        var si: usize = 0;
        while (si < vm.stock.len) : (si += 1) {
            if (!used_plan[si] and vm.stock[si].type_id == src.item.type_id) break;
        }
        if (si < vm.stock.len) {
            used_plan[si] = true;
            pending[pending_n] = .{ .slot = @intCast(si), .type_id = src.item.type_id, .count = @intCast(src.item.count), .quality = @intCast(src.item.quality), .markup = src.markup };
            pending_n += 1;
        } else {
            var free: usize = 0;
            while (free < vm.stock.len and (vm.stock[free].type_id != 0 or used_plan[free])) : (free += 1) {}
            if (free < vm.stock.len) {
                used_plan[free] = true;
                pending[pending_n] = .{ .slot = @intCast(free), .type_id = src.item.type_id, .count = @intCast(src.item.count), .quality = @intCast(src.item.quality), .markup = src.markup, .is_append = true };
                pending_n += 1;
            }
        }
    }
    var used: [vending_mod.max_vending_stock]bool = [_]bool{false} ** vending_mod.max_vending_stock;
    var pj: usize = 0;
    while (pj < pending_n) : (pj += 1) {
        const p2 = pending[pj];
        const si: usize = @intCast(p2.slot);
        used[si] = true;
        vm.stock[si] = .{ .type_id = p2.type_id, .count = p2.count, .quality = p2.quality, .markup = p2.markup };
    }
    var i: usize = 0;
    while (i < vm.stock.len) : (i += 1) {
        if (!used[i]) vm.stock[i] = .{};
    }
    // stock_n gates persistence and the wire entry loop: recount it to the
    // last non-empty row (holes are fine; the wire skips type_id == 0).
    var last: usize = 0;
    i = 0;
    while (i < vm.stock.len) : (i += 1) {
        if (vm.stock[i].type_id != 0) last = i + 1;
    }
    vm.stock_n = @intCast(last);
    if (read.money >= 0) vm.available_money = read.money;
    // NotifyListeners: every client whose view covers the machine gets the
    // fresh TE, not just the acting peer (stock TileEntityVendingMachine).
    try replicate_te.broadcastVendingTe(self, td.te_x, td.te_y, td.te_z);
}

/// Squared-distance reach gate for trade echoes: the sender's player must be
/// within trade_use_range of the target (see trade_use_range above).
fn inTradeReach(self: *const Game, c: *const Client, bx: f32, by: f32, bz: f32) bool {
    const ps = self.sim.playerByPeer(c.slot) orelse return false;
    const p = self.sim.transform[ps];
    const dx = p.x - bx;
    const dy = p.y - by;
    const dz = p.z - bz;
    return dx * dx + dy * dy + dz * dz <= self.trade_use_range * self.trade_use_range;
}
