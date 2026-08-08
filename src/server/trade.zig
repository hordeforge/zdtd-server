//! Trader surface: the C2S trade handler, the TraderData snapshot to peers, and
//! the trader sim (open hours, gates, XML stock fill, money/coins).
//!
//! Extracted from game.zig following the replicate_te precedent: these take
//! `*Game` as the first parameter and are called as `trade.handleTrade(g, …)`.
//! game.zig keeps one-line delegating methods so existing callers are unchanged.

const std = @import("std");
const game_mod = @import("game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../litenet/peer.zig");
const packages = @import("../wire/packages.zig");
const wire_binary = @import("../wire/binary.zig");
const ecs = @import("../ecs/root.zig");
const world_store = @import("../world/store.zig");
const vending_mod = @import("../world/vending.zig");
const assets_traders = @import("../assets/traders.zig");
const assets_npc = @import("../assets/npc.zig");
const resolveItemType = game_mod.Game.resolveItemType;
const systems = @import("../ecs/systems.zig");
const replicate_te = @import("replicate_te.zig");
const game_trader = @import("game/trader.zig");
const io_fs = @import("../util/io_fs.zig");

pub fn stockEntries(self: *Game, s: ecs.Slot, out: []packages.TraderStockEntry) usize {
    const stock = self.sim.trader_stock[s];
    var n: usize = 0;
    var e: usize = 0;
    while (e < stock.n and n < out.len) : (e += 1) {
        const ent = stock.entries[e];
        if (ent.count == 0) continue;
        const type_id: i32 = resolveItemType(@ptrCast(self), ent.item);
        out[n] = .{
            .item = .{
                .type_id = type_id,
                .count = if (ent.count > 0) ent.count else 1,
                .quality = 1,
            },
            // Entry.Markup demand delta: +100 after a buy, -4 after a sell
            // (asm.il 856828-856866), reset on restock. The client shows the
            // demand arrows and, for player-owned/rentable machines, prices
            // from 1 + Markup*0.2 (loot-economy.md section 5).
            .markup = ent.markup,
        };
        n += 1;
    }
    return n;
}

pub fn sendTraderSnapshot(self: *Game, peer: *ln_peer.Peer, prefer_slot: ?ecs.Slot) !void {
    var ti: ?ecs.Slot = prefer_slot;
    if (ti == null) {
        var i: ecs.Slot = 0;
        while (i < ecs.max_entities) : (i += 1) {
            if (self.sim.alive[i] and self.sim.mask[i].trader and self.sim.mask[i].trader_stock) {
                ti = i;
                break;
            }
        }
    }
    const s = ti orelse return;
    if (!self.sim.mask[s].trader_stock) return;
    const eid = self.sim.network_id[s].id;
    // Stock TraderData with primary inventory from SoA stock table.
    var entries: [ecs.components.max_stock]packages.TraderStockEntry = undefined;
    const n = self.stockEntries(s, &entries);
    const body = try packages.buildTraderDataStock(
        self.body_buf[0..4096],
        eid,
        eid, // trader id (stock TraderID is a traders.xml index; entity id is a safe placeholder)
        self.traderMoney(s),
        entries[0..n],
    );
    try self.sendGame(peer, "NetPackageTraderData", body);
}

pub fn handleTrade(self: *Game, c: *Client, body: []const u8) !void {
    const t = packages.parseTraderTrade(body) catch return;
    // allow_sell=false traders (vending machines, player-owned booths) never
    // buy from the player; stock disables the Sell tab entirely.
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

/// Stock NetPackageTraderData::ProcessPackage (asm.il 843218): mirror the
/// client's post-trade TraderData onto the server's trader / vending stock
/// (TraderData.CopyFrom). The client computes prices and moves inventory
/// locally; the server accepts the resulting stock deltas and rebroadcasts
/// the now-authoritative copy to observers. Price/sell stay server-owned
/// (the wire TraderData carries no price; the client derives it from econ x
/// markup).
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
            st.entries[i] = .{
                .item = eid,
                .count = src.item.count,
                .markup = src.markup,
                .price = st.entries[i].price,
                .sell = st.entries[i].sell,
            };
        }
        // Drop the entries the client did not send back.
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
        // The vending store is wire-oriented (type_id is the stock type).
        vm.stock[i] = .{ .type_id = src.item.type_id, .count = src.item.count, .markup = src.markup };
    }
    while (i < vending_mod.max_vending_stock) : (i += 1) vm.stock[i] = .{};
    if (read.money >= 0) vm.available_money = read.money;
    try replicate_te.sendVendingTe(self, c.peer.?, td.te_x, td.te_y, td.te_z);
}

/// Write the P4 evidence ring as JSONL to `path` (admin `evidence dump`).
/// Returns the number of events written; fails loudly on I/O error so the
/// operator never mistakes a failed flush for a successful one.
pub fn coinItemId(self: *const Game) u16 {
    const name = if (self.traders.currency_item.len > 0) self.traders.currency_item else "casinoCoin";
    return self.items.ecsIdByName(name);
}

/// Live trader AvailableMoney for the wire: stock debits it when buying
/// from the player and credits it when selling to them. Uninitialized
/// traders (wallet_default 0) fall back to the config default.
pub fn traderMoney(self: *const Game, s: ecs.Slot) i32 {
    if (self.sim.mask[s].trader_stock) {
        const m = self.sim.trader_stock[s];
        if (m.wallet_default != 0) return m.wallet;
    }
    return self.trader_wallet_dukes;
}

/// Parse a stock "H:MM" hour string to minutes after midnight; null if malformed.
pub fn traderMinutes(v: []const u8) ?u32 {
    const colon = std.mem.indexOfScalar(u8, v, ':') orelse return null;
    if (colon == 0 or colon + 1 >= v.len) return null;
    const h = std.fmt.parseInt(u32, v[0..colon], 10) catch return null;
    const m = std.fmt.parseInt(u32, v[colon + 1 ..], 10) catch return null;
    if (h > 23 or m > 59) return null;
    return h * 60 + m;
}

/// trader_info open hours gate: vending machines and traders without
/// open_time are always open; unknown info ids (fixtures) never gate.
pub fn traderIsOpen(self: *const Game, ts: ecs.Slot) bool {
    const info_id = self.sim.trader_stock[ts].trader_info_id;
    if (info_id == 0) return true;
    const info = self.traders.traderInfo(info_id) orelse return true;
    if (info.is_vending or info.open_time.len == 0) return true;
    const open = traderMinutes(info.open_time) orelse return true;
    const close = traderMinutes(info.close_time) orelse return true;
    // 24000 ticks/day, 1000 ticks/hour → minute of day = ticks*3/50.
    const now = (@as(u32, @intCast(self.sim.director.clock.worldTimeBits() % 24000)) * 3) / 50;
    if (close > open) return now >= open and now < close;
    return now >= open or now < close; // overnight window
}

/// EntityTrader::OnUpdateLive open/close cycle (asm.il 531757-531898):
/// when `!TraderInfo.IsOpen` differs from the area's closed latch, apply
/// `TraderArea::SetClosed` — on closing, force-unlock the trade channel
/// (LockManager::ForceUnlockLockTarget, channel 0) so an open window closes,
/// then toggle the area's TraderOnOff gate blocks.
pub fn tickTraderAreas(self: *Game) void {
    var s: ecs.Slot = 0;
    while (s < ecs.max_entities) : (s += 1) {
        if (!self.sim.alive[s] or !self.sim.mask[s].trader or !self.sim.mask[s].trader_stock) continue;
        const st = &self.sim.trader_stock[s];
        const closed = !self.traderIsOpen(s);
        if (closed == st.is_closed) continue;
        st.is_closed = closed;
        if (closed) {
            // ForceUnlockLockTarget: only the trade channel (0) is a trader
            // lock; kick its holder with a forced unlock so the window shuts.
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
        self.toggleTraderGates(s, closed);
    }
}

/// TraderArea::SetClosed gate walk: toggle IndexName="TraderOnOff" blocks in
/// the trader's POI area. Stock closes doors/locks via their composite door
/// TE features (zdtd has no door TE yet: residual) and flips BlockLight meta
/// bit 0x2 (close clears, open sets); loudspeakers only play a sound. Each
/// raw change is broadcast as the authoritative NetPackageSetBlock.
pub fn toggleTraderGates(self: *Game, s: ecs.Slot, closed: bool) void {
    const tr = self.sim.transform[s];
    const pf = if (self.world.prefabs) |*p| p else return;
    for (pf.items) |*d| {
        if (world_store.prefabs.isPart(d.name)) continue;
        const qd = pf.questData(d.name) orelse continue;
        if (!qd.is_trader_area) continue;
        // The trader entity sits inside its area footprint.
        if (tr.x < @as(f32, @floatFromInt(d.x - 8)) or tr.x > @as(f32, @floatFromInt(d.x + d.size_x + 8))) continue;
        if (tr.z < @as(f32, @floatFromInt(d.z - 8)) or tr.z > @as(f32, @floatFromInt(d.z + d.size_z + 8))) continue;
        self.toggleGatesInArea(d, closed);
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
                // Doors and loudspeakers are handled via TE features or are
                // sound-only; only light gates carry the meta on/off bit.
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

/// Replace builtin trader stock with the trader's own traders.xml list when
/// resolvable to ECS items: per-trader `<trader_items>` from the trader_info
/// matching the entity's class (npc.xml trader_id), else traderAlways.
/// Price from items.xml EconomicValue when known.
pub fn fillTraderFromXml(self: *Game, trader_net_id: i32) void {
    const tt = self.traders;
    const s = self.sim.slotOfNetId(trader_net_id) orelse return;
    if (!self.sim.mask[s].trader_stock) return;
    var n: usize = 0;
    var rolled: [assets_traders.max_expand]assets_traders.RolledItem = undefined;
    const rn = game_trader.rollStockRefs(self, trader_net_id, &rolled);
    if (rn == 0) return;
    const info_id = self.sim.trader_stock[s].trader_info_id;
    // Stock GetBuyPrice/GetSellPrice (loot-economy.md): buy = econ x
    // BuyMarkup (per-trader OverrideBuyMarkup wins), sell = econ x
    // SellMarkdown (OverrideSellMarkdown wins). The previous econ/10 and
    // econ/50 constants priced ~30x and ~10x low versus the client display.
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
        if (econ == 0) continue; // fail closed: no EconomicValue means not tradeable (RE GetBuyPrice)
        self.sim.trader_stock[s].entries[n] = .{
            .item = iid,
            .count = r.count,
            .quality = r.quality,
            .price = @intCast(@min(@as(u64, @intFromFloat(@as(f64, econ) * buy_markup)), 65535)),
            .sell = @max(1, @as(u16, @intCast(@min(@as(u64, @intFromFloat(@as(f64, econ) * sell_markup)), 65535)))),
        };
        n += 1;
    }
    if (n > 0) self.sim.trader_stock[s].n = @intCast(n);
}

test "trader POIs spawn their NPC classes on a stock map" {
    const game_dir = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
    const map = game_dir ++ "/Data/Worlds/Navezgane";
    if (!io_fs.dirExistsSimple(map)) return error.SkipZigTest;
    io_fs.mkdirPathSimple(".zdtd_cfg_cache");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{
        .map_dir = map,
        .game_dir = game_dir,
    });
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    // Pad trader plus the five trader POIs (Jen/Bob/Hugh/Joel/Rekt), each
    // carrying its own class hash and trader_info stock.
    var n: usize = 0;
    var saw_bob = false;
    var si: ecs.Slot = 0;
    while (si < ecs.max_entities) : (si += 1) {
        if (!g.sim.alive[si] or !g.sim.mask[si].trader) continue;
        n += 1;
        if (g.sim.class_id[si].hash == packages.stock_entity.class_npc_trader_bob) saw_bob = true;
    }
    try std.testing.expect(n >= 6);
    try std.testing.expect(saw_bob);
}

test "POI reset restores baked blocks over player edits" {
    const game_dir = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
    const map = game_dir ++ "/Data/Worlds/Navezgane";
    if (!io_fs.dirExistsSimple(map)) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{
        .map_dir = map,
        .game_dir = game_dir,
    });
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    const pf = if (g.world.prefabs) |*p| p else return error.TestUnexpectedResult;
    // First trader POI with a baked block table.
    var di: ?usize = null;
    for (pf.items, 0..) |d, i| {
        if (world_store.prefabs.isPart(d.name)) continue;
        const qd = pf.questData(d.name) orelse continue;
        if (!qd.is_trader_area) continue;
        if (pf.getTtsBlocks(d.name) == null) continue;
        di = i;
        break;
    }
    const idx = di orelse return error.TestUnexpectedResult;
    const d = pf.items[idx];
    // A non-air block near the stamp surface to edit and restore.
    var target: ?[3]i32 = null;
    outer: for (0..@as(usize, @intCast(d.size_x))) |lx| {
        for (0..@as(usize, @intCast(d.size_z))) |lz| {
            const by = d.stampY() + 1;
            const y_hi = @min(by + 10, 255);
            var y: i32 = by;
            while (y <= y_hi) : (y += 1) {
                const bid = g.world.blockWorld(d.x + @as(i32, @intCast(lx)), y, d.z + @as(i32, @intCast(lz))) catch 0;
                if (bid == 0) continue;
                target = .{ d.x + @as(i32, @intCast(lx)), y, d.z + @as(i32, @intCast(lz)) };
                break :outer;
            }
        }
    }
    const t = target orelse return error.TestUnexpectedResult;
    const orig = (try g.world.blockWorld(t[0], t[1], t[2]));
    // Player edit wipes the block; the quest dedication resets it.
    try g.setBlock(t[0], t[1], t[2], 0);
    try std.testing.expectEqual(@as(u16, 0), try g.world.blockWorld(t[0], t[1], t[2]));
    g.resetPoiBlocks(t[0], t[2]);
    try std.testing.expectEqual(orig, try g.world.blockWorld(t[0], t[1], t[2]));
}

test "biome spawn groups resolve per-biome spawning.xml rules on a stock map" {
    const game_dir = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
    const map = game_dir ++ "/Data/Worlds/Navezgane";
    if (!io_fs.dirExistsSimple(map)) return error.SkipZigTest;
    io_fs.mkdirPathSimple(".zdtd_cfg_cache");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{
        .map_dir = map,
        .game_dir = game_dir,
    });
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    const bm = g.world.biomes orelse return error.TestUnexpectedResult;
    try std.testing.expect(g.world.biome_layers_table.loaded);
    // Scan the map for one wasteland cell (biomemap id 8) and one pine_forest
    // cell (id 3) instead of pinning fragile world coords.
    var wasteland: ?[2]i32 = null;
    var pine: ?[2]i32 = null;
    var wx: i32 = -1600;
    while (wx <= 1600 and (wasteland == null or pine == null)) : (wx += 32) {
        var wz: i32 = -1600;
        while (wz <= 1600) : (wz += 32) {
            const bid = bm.atWorld(wx, wz) orelse continue;
            if (bid == 8 and wasteland == null) wasteland = .{ wx, wz };
            if (bid == 3 and pine == null) pine = .{ wx, wz };
        }
    }
    const w = wasteland orelse return error.TestUnexpectedResult;
    const p = pine orelse return error.TestUnexpectedResult;
    const fx = @as(f32, @floatFromInt(w[0]));
    const fz = @as(f32, @floatFromInt(w[1]));
    // The fn takes a callback-style ctx first (director binding uses the
    // same shape): pass the game as ctx; null would panic on the deref.
    const w_night = Game.biomeGroupName(g, fx, fz, .night, "fallback");
    const w_day = Game.biomeGroupName(g, fx, fz, .day, "fallback");
    const p_night = Game.biomeGroupName(g, @floatFromInt(p[0]), @floatFromInt(p[1]), .night, "fallback");
    try std.testing.expectEqualStrings("ZombiesWastelandNight", w_night);
    try std.testing.expectEqualStrings("ZombiesWasteland", w_day);
    try std.testing.expectEqualStrings("ZombiesNight", p_night);
    // Unknown biome ids / missing biome map fall back instead of guessing.
    try std.testing.expectEqualStrings("fallback", Game.biomeGroupName(g, 99999, 99999, .night, "fallback"));
}

test "per-trader stock and hours come from trader_info + npc.xml" {
    const traders_path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/traders.xml";
    const npc_path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/npc.xml";
    const tt = assets_traders.loadFromPath(std.testing.allocator, traders_path) catch return error.SkipZigTest;
    const nt = assets_npc.loadFromPath(std.testing.allocator, npc_path) catch return error.SkipZigTest;

    io_fs.mkdirPathSimple(".zdtd_cfg_cache");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{});
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    // No config dirs here, so create left the tables empty: own the stock files.
    g.traders.deinit();
    g.traders = tt;
    g.npc.deinit();
    g.npc = nt;

    try std.testing.expectEqual(@as(u16, 6), g.npc.traderIdForClass("npcTraderBob"));
    try std.testing.expectEqual(@as(u16, 2), g.npc.traderIdForClass("Trader Jen"));
    try std.testing.expectEqualStrings("trader_rekt_quests", g.npc.questListForTrader(8).?);

    // Pad trader gets Jen's trader_info (2) and her own list, not traderAlways.
    var jen: ?i32 = null;
    var si: ecs.Slot = 0;
    while (si < ecs.max_entities) : (si += 1) {
        if (g.sim.alive[si] and g.sim.mask[si].trader) {
            g.sim.trader_stock[si].trader_info_id = 2;
            jen = g.sim.network_id[si].id;
            break;
        }
    }
    const jen_id = jen orelse return error.TestUnexpectedResult;
    g.fillTraderFromXml(jen_id);
    const jslot = g.sim.slotOfNetId(jen_id).?;
    // Offline game has the ~12-item builtin table, so at least one of Jen's
    // refs must resolve; the exact count depends on items.xml coverage.
    try std.testing.expect(g.sim.trader_stock[jslot].n >= 1);

    // Joel's trader_info (1) fills a different list: some (item, count)
    // pair among the first entries differs from Jen's.
    const joel_id = g.sim.spawnTrader("npcTraderJoel", 100, 70, 100, 1, 5000).?;
    g.fillTraderFromXml(joel_id);
    const kslot = g.sim.slotOfNetId(joel_id).?;
    const a = &g.sim.trader_stock[jslot];
    const b = &g.sim.trader_stock[kslot];
    try std.testing.expect(a.n >= 1 and b.n >= 1);
    var differs = false;
    const m = @min(a.n, b.n);
    for (a.entries[0..m], b.entries[0..m]) |x, y| {
        if (x.item != y.item or x.count != y.count) differs = true;
    }
    try std.testing.expect(differs);

    // Hours gate: Jen (4:05–21:50) is open at noon, closed at 03:00; a
    // vending trader_info (4) and unknown ids (fixtures) never gate.
    g.sim.director.clock.hours = 12.0;
    try std.testing.expect(g.traderIsOpen(jslot));
    g.sim.director.clock.hours = 3.0;
    try std.testing.expect(!g.traderIsOpen(jslot));
    const vend_id = g.sim.spawnTrader("vending", 110, 70, 110, 4, 5000).?;
    const vslot = g.sim.slotOfNetId(vend_id).?;
    try std.testing.expect(g.traderIsOpen(vslot));
    const unk_id = g.sim.spawnTrader("Trader", 120, 70, 120, 0, 5000).?;
    const uslot = g.sim.slotOfNetId(unk_id).?;
    try std.testing.expect(g.traderIsOpen(uslot));
}
