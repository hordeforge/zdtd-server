//! Trader helpers extracted verbatim from game.zig.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const packages = @import("../../wire/packages.zig");
const world_store = @import("../../world/store.zig");
const assets_traders = @import("../../assets/traders.zig");
const ecs = @import("../../ecs/root.zig");
const rng_util = @import("../../util/rng.zig");

pub fn coinItemId(self: *const Game) u16 {
    const name = if (self.traders.currency_item.len > 0) self.traders.currency_item else "casinoCoin";
    return self.items.ecsIdByName(name);
}

pub fn traderMoney(self: *const Game, s: ecs.Slot) i32 {
    if (self.sim.mask[s].trader_stock) {
        const m = self.sim.trader_stock[s];
        if (m.wallet_default != 0) return m.wallet;
    }
    return self.trader_wallet_dukes;
}

fn traderMinutes(v: []const u8) ?u32 {
    const colon = std.mem.indexOfScalar(u8, v, ':') orelse return null;
    if (colon == 0 or colon + 1 >= v.len) return null;
    const h = std.fmt.parseInt(u32, v[0..colon], 10) catch return null;
    const m = std.fmt.parseInt(u32, v[colon + 1 ..], 10) catch return null;
    if (h > 23 or m > 59) return null;
    return h * 60 + m;
}

pub fn traderIsOpen(self: *const Game, ts: ecs.Slot) bool {
    const info_id = self.sim.trader_stock[ts].trader_info_id;
    if (info_id == 0) return true;
    const info = self.traders.traderInfo(info_id) orelse return true;
    if (info.is_vending or info.open_time.len == 0) return true;
    const open = traderMinutes(info.open_time) orelse return true;
    const close = traderMinutes(info.close_time) orelse return true;
    const now = (@as(u32, @intCast(self.sim.director.clock.worldTimeBits() % 24000)) * 3) / 50;
    if (close > open) return now >= open and now < close;
    return now >= open or now < close;
}

pub fn tickTraderAreas(self: *Game) void {
    var s: ecs.Slot = 0;
    while (s < ecs.max_entities) : (s += 1) {
        if (!self.sim.alive[s] or !self.sim.mask[s].trader or !self.sim.mask[s].trader_stock) continue;
        const st = &self.sim.trader_stock[s];
        const closed = !traderIsOpen(self, s);
        if (closed == st.is_closed) continue;
        st.is_closed = closed;
        if (closed) {
            const ch: usize = 0;
            if (self.lock_channel[ch] >= 0) {
                const holder: usize = @intCast(self.lock_channel[ch]);
                self.clearLockSlot(ch);
                if (holder < self.clients.len and self.clients[holder].joined) {
                    if (self.clients[holder].peer) |p| {
                        const resp = packages.buildLockResponseUnlock(&self.body_buf, true) catch continue;
                        self.sendGame(p, "NetPackageLockResponse", resp) catch continue;
                    }
                }
            }
        }
        toggleTraderGates(self, s, closed);
    }
}

pub fn toggleTraderGates(self: *Game, s: ecs.Slot, closed: bool) void {
    const tr = self.sim.transform[s];
    const pf = if (self.world.prefabs) |*p| p else return;
    for (pf.items) |*d| {
        if (world_store.prefabs.isPart(d.name)) continue;
        const qd = pf.questData(d.name) orelse continue;
        if (!qd.is_trader_area) continue;
        if (tr.x < @as(f32, @floatFromInt(d.x - 8)) or tr.x > @as(f32, @floatFromInt(d.x + d.size_x + 8))) continue;
        if (tr.z < @as(f32, @floatFromInt(d.z - 8)) or tr.z > @as(f32, @floatFromInt(d.z + d.size_z + 8))) continue;
        toggleGatesInArea(self, d, closed);
        return;
    }
}

pub fn toggleGatesInArea(self: *Game, d: *const world_store.prefabs.Decoration, closed: bool) void {
    const x0 = d.x;
    const x1 = d.x + d.size_x;
    const z0 = d.z;
    const z1 = d.z + d.size_z;
    var bx: i32 = x0;
    while (bx < x1) : (bx += 1) {
        var bz: i32 = z0;
        while (bz < z1) : (bz += 1) {
            const surf = self.world.heightWorld(bx, bz) catch continue;
            const y_lo: i32 = @max(@as(i32, 0), @as(i32, surf) - 4);
            const y_hi: i32 = @min(@as(i32, 255), @as(i32, surf) + 14);
            var y: i32 = y_lo;
            while (y <= y_hi) : (y += 1) {
                const id = self.world.blockWorld(bx, y, bz) catch 0;
                if (id == 0) continue;
                if (!self.blocks.isTraderOnOff(id)) continue;
                const raw = self.blockRawAt(bx, y, bz);
                const meta = packages.blockMeta(raw);
                const new_meta: u8 = if (closed) meta & ~@as(u8, 0x2) else meta | 0x2;
                if (new_meta == meta) continue;
                self.setBlockRaw(bx, y, bz, packages.withBlockMeta(raw, new_meta));
                if (packages.buildSetBlockBodyRaw(
                    self.body_buf[0..96],
                    bx,
                    y,
                    bz,
                    packages.withBlockMeta(raw, new_meta),
                    0,
                    -1,
                    -1,
                )) |sb| {
                    self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(bx), @floatFromInt(bz), self.interest_range) catch {};
                } else |_| {}
            }
        }
    }
}

/// Deterministic roll seed for a trader's inventory: (world seed, trader
/// entity, day). Same world + trader + day → same stock; restock on a later
/// day rolls fresh (sim rule: deterministic inputs).
pub fn traderRollSeed(self: *const Game, trader_net_id: i32) u64 {
    const day = self.sim.director.clock.day;
    var buf: [16]u8 = undefined;
    std.mem.writeInt(u64, buf[0..8], self.worldSeed(), .little);
    std.mem.writeInt(u64, buf[8..16], @as(u64, @bitCast(@as(i64, trader_net_id))) ^ (@as(u64, day) *% 0x9E3779B97F4A7C15), .little);
    return std.hash.Wyhash.hash(0, &buf);
}

/// Resolve the refs a trader fills from (its own `<trader_items>` when the
/// trader_info has them, else the traderAlways fallback) and roll them into
/// out[] with the seeded rng (stock TraderInfo::Spawn port in traders.zig).
/// Also copies the per-trader RestockInterval onto the sim stock.
pub fn rollStockRefs(self: *Game, trader_net_id: i32, out: []assets_traders.RolledItem) usize {
    const tt = self.traders;
    var refs: []const assets_traders.ItemRef = &.{};
    if (self.sim.slotOfNetId(trader_net_id)) |s| {
        if (self.sim.mask[s].trader_stock) {
            const info_id = self.sim.trader_stock[s].trader_info_id;
            if (info_id != 0) {
                if (tt.traderInfo(info_id)) |ti| {
                    if (ti.refs.len > 0) refs = ti.refs;
                    // Per-trader RestockInterval drives systems.traderRestock
                    // (-1 = never, 0 = daily, N = every N days).
                    self.sim.trader_stock[s].reset_interval = ti.reset_interval;
                    self.sim.trader_stock[s].last_restock_day = self.sim.director.clock.day;
                }
            }
        }
    }
    if (refs.len == 0) refs = tt.trader_always_refs;
    if (refs.len == 0) return 0;
    var rng = rng_util.XorShift32.initFromU64(traderRollSeed(self, trader_net_id));
    return tt.rollAllRefs(refs, &rng, out);
}

pub fn fillTraderFromXml(self: *Game, trader_net_id: i32) void {
    const tt = self.traders;
    const s = self.sim.slotOfNetId(trader_net_id) orelse return;
    if (!self.sim.mask[s].trader_stock) return;
    var n: usize = 0;
    var rolled: [assets_traders.max_expand]assets_traders.RolledItem = undefined;
    const rn = rollStockRefs(self, trader_net_id, &rolled);
    if (rn == 0) return;
    const info_id = self.sim.trader_stock[s].trader_info_id;
    var buy_markup: f32 = 1.0;
    var sell_markup: f32 = 0.02;
    if (info_id != 0) {
        if (tt.traderInfo(info_id)) |ti| {
            if (ti.override_buy_markup > 0) buy_markup = ti.override_buy_markup;
            if (ti.override_sell_markup > 0) sell_markup = ti.override_sell_markup;
        }
    }
    if (buy_markup == 1.0 and tt.buy_markup > 0) buy_markup = tt.buy_markup;
    if (sell_markup == 0.02 and tt.sell_markdown > 0) sell_markup = tt.sell_markdown;
    for (rolled[0..rn]) |r| {
        if (n >= ecs.components.max_stock) break;
        const iid = self.ecsIdFromItemName(r.name);
        if (iid == 0) continue;
        const econ: u16 = if (self.items.byId(iid)) |d| d.econ else 0;
        self.sim.trader_stock[s].entries[n] = .{
            .item = iid,
            .count = r.count,
            .quality = r.quality,
            .price = if (econ > 0) @intCast(@min(@as(u64, @intFromFloat(@as(f64, econ) * buy_markup)), 65535)) else 5,
            .sell = if (econ > 0) @max(1, @as(u16, @intCast(@min(@as(u64, @intFromFloat(@as(f64, econ) * sell_markup)), 65535)))) else 1,
        };
        n += 1;
    }
    if (n > 0) self.sim.trader_stock[s].n = @intCast(n);
}


/// Stock TraderManager.TraderInventoryRequested / HandleFullReset
/// (loot-economy.md §3): restock is lazy, triggered by the trader open, not a
/// background timer. When the trader_info ResetInterval has elapsed since the
/// last fill, rebuild the window with fresh rolls (fillTraderFromXml re-runs
/// the seeded roll, which also advances last_restock_day) and regenerate the
/// money pool toward its spawn default.
pub fn maybeRestockTrader(self: *Game, ts: ecs.Slot) void {
    if (!self.sim.mask[ts].trader_stock) return;
    const stock = &self.sim.trader_stock[ts];
    if (stock.reset_interval < 0) return; // never restocks
    const day = self.sim.director.clock.day;
    if (stock.reset_interval > 0) {
        if (day -| stock.last_restock_day < @as(u32, @intCast(stock.reset_interval))) return;
    }
    self.fillTraderFromXml(self.sim.network_id[ts].id);
    if (self.sim.trader_stock[ts].wallet < self.sim.trader_stock[ts].wallet_default) {
        self.sim.trader_stock[ts].wallet = self.sim.trader_stock[ts].wallet_default;
    }
}
