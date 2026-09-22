//! C2S quest arms: NPC quest list, trader data, vending machines.
//!
//! Split out of c2s/quest.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const ecs = @import("../../ecs/root.zig");
const systems = @import("../../ecs/systems.zig");
const replicate_te = @import("../game/replicate_te.zig");
const vending_mod = @import("../../world/vending.zig");
const quest_giver_fallback_y = @import("quest_party.zig").quest_giver_fallback_y;

/// True when `name` is a trader/vending package and was handled.
pub fn handleTrade(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (std.mem.eql(u8, name, "NetPackageNPCQuestList")) {
        // Stock trader quest-list exchange: FetchList with QuestPacketEntry offers.
        const head = packages.parseNpcQuestList(body) catch packages.NpcQuestListHead{
            .npc_entity_id = 0,
            .player_entity_id = c.entity_id,
            .event_type = .fetch_list,
        };
        var tx: f32 = 0;
        var ty: f32 = quest_giver_fallback_y;
        var tz: f32 = 0;
        if (self.sim.slotOfNetId(head.npc_entity_id)) |ni| {
            if (self.sim.mask[ni].transform) {
                tx = self.sim.transform[ni].x;
                ty = self.sim.transform[ni].y;
                tz = self.sim.transform[ni].z;
                // Same reach gate as the trade, the TraderData echo and the
                // window open ([sim] trader_use_range): the remove_quest arm
                // below accepts an offer into the journal, so an ungated list
                // exchange hands out quests from every trader on the map.
                // An id that names nothing keeps the fallback marker position
                // and grants nothing, so only a resolved NPC is checked.
                if (!self.inTradeReach(c, tx, ty, tz)) {
                    self.harness.counters.inc(.bounds_rejects);
                    return true;
                }
            }
        }
        // max_quest_tier (quests.xml root): stock clamps the offered tier
        // window to the declared maximum (accept + offer paths below).
        const req_tier: u8 = blk: {
            const mt = self.sim.catalog.max_tier;
            // Clamp: tier_level is a raw wire i32 and a hostile value above
            // 255 would trap the u8 cast; any tier above the stock max is
            // nonsense, so the max_tier comparison below picks mt anyway.
            const tl: u8 = @intCast(@min(@max(head.tier_level, 0), 255));
            if (mt > 0 and tl > mt) break :blk mt;
            break :blk tl;
        };
        if (head.event_type == .remove_quest) {
            // Stock accept marker (asm.il 827746-827975): the client took
            // the removeIndex'th offer, filtered by DifficultyTier and
            // non-active quests. Accept it into the journal and re-send the
            // list without it, so the client stops offering it.
            if (self.sim.catalog.listById(self.traderQuestList(head.npc_entity_id))) |list| {
                var idx: u32 = 0;
                for (list.entries) |qid| {
                    const d = self.sim.catalog.byId(qid) orelse continue;
                    if (d.name.len == 0 or !self.isStockClientQuestName(d.name)) continue;
                    if (d.difficulty_tier != req_tier) continue;
                    const ps = self.sim.playerByPeer(c.slot) orelse break;
                    if (self.sim.mask[ps].journal and self.sim.journal[ps].hasActive(qid)) continue;
                    if (idx == head.remove_index) {
                        _ = self.acceptQuestFor(c, qid);
                        // Quest giver for PositionDataTypes.QuestGiver (0):
                        // the trader that offered the quest, so the client's
                        // return-to-giver marker points at the real NPC.
                        if (self.sim.playerByPeer(c.slot)) |pslot| {
                            if (self.sim.mask[pslot].journal) {
                                if (self.sim.journal[pslot].findActive(qid)) |qs| {
                                    qs.giver_x = tx;
                                    qs.giver_y = ty;
                                    qs.giver_z = tz;
                                }
                            }
                        }
                        break;
                    }
                    idx += 1;
                }
            }
            var offers: [8]packages.stock_quest.QuestPacketEntry = undefined;
            const on = self.buildTraderQuestOffers(self.traderQuestList(head.npc_entity_id), c.slot, tx, ty, tz, @intCast(@max(req_tier, 0)), &offers);
            const body_out = try packages.buildNpcQuestListFetch(
                self.body_buf[0..2048],
                head.npc_entity_id,
                if (head.player_entity_id != 0) head.player_entity_id else c.entity_id,
                head.tier_level,
                offers[0..on],
            );
            try self.sendGame(peer, "NetPackageNPCQuestList", body_out);
            return true;
        }
        if (head.event_type == .fetch_list or head.event_type == .reset_quests) {
            var offers: [8]packages.stock_quest.QuestPacketEntry = undefined;
            const on = self.buildTraderQuestOffers(self.traderQuestList(head.npc_entity_id), c.slot, tx, ty, tz, @intCast(@max(req_tier, 0)), &offers);
            const body_out = try packages.buildNpcQuestListFetch(
                self.body_buf[0..2048],
                head.npc_entity_id,
                if (head.player_entity_id != 0) head.player_entity_id else c.entity_id,
                head.tier_level,
                offers[0..on],
            );
            try self.sendGame(peer, "NetPackageNPCQuestList", body_out);
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageTraderData")) {
        // Stock ToServer body (asm.il 843046): isEntity | entityId /
        // tePosition | hasTraderData | TraderData::Write. A real client's
        // post-trade copy is length-distinguishable from the loadgen/sim
        // 9-byte trade body (which is exactly 9 bytes).
        if (body.len > 9 and body[0] <= 1) {
            if (packages.parseTraderDataToServer(body) catch null) |td| {
                if (td.has_trader_data) {
                    try self.applyTraderDataCopyFrom(c, td);
                    return true;
                }
            }
        }
        // Exactly 9, not >= 9: a stock ToServer body with isEntity=false and
        // hasTraderData=false is 14 bytes, and its body[8] is the high byte of
        // te_y, which is 0 for any real world coordinate. With >= 9 that body
        // fell through to the trade arm and was decoded as a trade whose qty
        // came from two te_y bytes.
        if (body.len == 9 and (body[8] == 0 or body[8] == 1)) {
            try self.handleTrade(c, body);
            return true;
        }
        // Same reach gate as the trade and the TraderData echo. Opening the
        // window advances trader_interact phases, turns in a ready quest and
        // pays its rewards, so without this a player could farm every quest
        // turn-in on the map by naming targets from spawn. The header decides
        // what the leading bytes mean: an entity id when isEntity, otherwise
        // the tile-entity position (a vending machine). The zdtd short open
        // body carries neither, so it has no position to check.
        if (packages.parseTraderDataToServer(body) catch null) |open| {
            if (open.is_entity) {
                const ni = self.sim.slotOfNetId(open.entity_id) orelse return true;
                if (!self.sim.mask[ni].transform) return true;
                const np = self.sim.transform[ni];
                if (!self.inTradeReach(c, np.x, np.y, np.z)) {
                    self.harness.counters.inc(.bounds_rejects);
                    return true;
                }
            } else if (!self.inTradeReach(
                c,
                @floatFromInt(open.te_x),
                @floatFromInt(open.te_y),
                @floatFromInt(open.te_z),
            )) {
                self.harness.counters.inc(.bounds_rejects);
                return true;
            }
        }
        // Stock trader quest offers (npc from open body when present).
        const npc_id: i32 = if (body.len >= 4) std.mem.readInt(i32, body[0..4], .little) else 0;
        systems.questOnTraderOpen(&self.sim, c.slot);
        // Server-side catalog accept for loadgen/sim; stock UI uses NPCQuestList.
        if (self.sim.catalog.listById(self.traderQuestList(npc_id))) |list| {
            for (list.entries) |qid| {
                if (self.acceptQuestFor(c, qid)) break;
            }
        }
        try self.sendTraderSnapshot(peer, null);
        var offers: [8]packages.stock_quest.QuestPacketEntry = undefined;
        var tx: f32 = 0;
        var ty: f32 = quest_giver_fallback_y;
        var tz: f32 = 0;
        if (self.sim.slotOfNetId(npc_id)) |ni| {
            if (self.sim.mask[ni].transform) {
                tx = self.sim.transform[ni].x;
                ty = self.sim.transform[ni].y;
                tz = self.sim.transform[ni].z;
            }
        }
        const on = self.buildTraderQuestOffers(self.traderQuestList(npc_id), c.slot, tx, ty, tz, 0, &offers);
        const qbody = try packages.buildNpcQuestListFetch(
            self.body_buf[512..2560],
            npc_id,
            c.entity_id,
            0,
            offers[0..on],
        );
        try self.sendGame(peer, "NetPackageNPCQuestList", qbody);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackagePlayerVendingMachine")) {
        // Vending rent / clear (loot-economy.md §6, asm.il 833593):
        // removing=false rents (or extends) the machine for the sender;
        // removing=true clears ownership. Server-authoritative: only the
        // sender's own identity may act, rent costs TraderInfo.RentCost
        // currency, and the rental term is 30 in-game days.
        var plat_buf: [packages.platform_user.max_platform_len]u8 = undefined;
        var id_buf: [packages.platform_user.max_id_len]u8 = undefined;
        const acc = packages.parseVendingMachineAccess(body, &plat_buf, &id_buf) catch return true;
        const mine = c.puid_primary.get() orelse c.puid_native.get() orelse return true;
        if (!acc.user.eql(mine)) return true;
        const key: vending_mod.PosKey = .{ .x = acc.x, .y = acc.y, .z = acc.z };
        const vm = self.vending.get(key) orelse return true;
        const day = self.sim.director.clock.day;
        // Expired rentals clear first (currentDay > rental_end_day).
        if (vm.rental_end_day > 0 and day > vm.rental_end_day) vm.clear();
        if (acc.removing) {
            // Stock TryRemoveVendingMachinePosition acts on the sender's
            // own per-player list: only the owner may clear the machine.
            if (!vm.owner.matches(acc.user)) return true;
            vm.clear();
            try replicate_te.sendVendingTe(self, peer, acc.x, acc.y, acc.z);
            return true;
        }
        const info = self.traders.traderInfo(vm.trader_id) orelse return true;
        if (!info.rentable) return true;
        if (vm.rental_end_day > 0 and !vm.owner.matches(acc.user)) return true; // other owner (CanRent 1)
        const coins = self.coinItemId();
        if (coins == 0) return true;
        const ps = self.sim.playerByPeer(c.slot) orelse return true;
        if (!self.sim.mask[ps].wallet) return true;
        // One machine per player (CanRent 2, checkAlreadyRentingVM).
        if (vm.rental_end_day == 0) {
            for (self.vending.items[0..], self.vending.used[0..]) |*other, u| {
                if (!u) continue;
                if (&other.* == vm) continue;
                if (other.rental_end_day > 0 and other.owner.matches(acc.user)) return true;
            }
        }
        // Sync wallet from inventory coins (same rule as trade).
        if (self.sim.mask[ps].inventory) {
            const inv_coins = self.sim.inventory[ps].countItem(coins);
            if (inv_coins > self.sim.wallet[ps].coins) self.sim.wallet[ps].coins = inv_coins;
        }
        const cost: u32 = @intCast(@max(0, info.rent_cost));
        if (self.sim.wallet[ps].coins < cost) return true; // insufficient currency (CanRent 3)
        if (self.sim.mask[ps].inventory) {
            const have = self.sim.inventory[ps].countItem(coins);
            // removeItem takes a u16 count; a wallet synced from many coin
            // stacks can hold more than 65535, so drain in u16 chunks rather
            // than truncating the cast.
            const from_inv: u32 = @min(have, cost);
            if (from_inv > 0) {
                var left: u32 = from_inv;
                while (left > 0) {
                    const chunk: u16 = @intCast(@min(left, @as(u32, std.math.maxInt(u16))));
                    if (!self.sim.inventory[ps].removeItem(coins, chunk)) return true;
                    left -= chunk;
                }
            }
        }
        self.sim.wallet[ps].coins -= cost;
        vm.owner.set(acc.user) catch return true;
        // Stock term: RentTimeInDays (trader_info rent_time; Table default 30).
        // Explicit 0 / negative still floors to 30 (stock ctor default).
        const term: i32 = if (info.rent_time > 0) info.rent_time else 30;
        const day_i: i32 = @intCast(day);
        vm.rental_end_day = if (vm.rental_end_day > 0) vm.rental_end_day + term else day_i + term;
        vm.rentable = info.rentable;
        // The owning player sees its machine's stock; re-send the TE.
        try replicate_te.sendVendingTe(self, peer, acc.x, acc.y, acc.z);
        return true;
    }
    return false;
}
