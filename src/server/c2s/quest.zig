//! C2S quest/social/trade domain: shared quests, party and ally actions,
//! buff add/remove, quest events and objective updates, the NPC quest list,
//! trader data and vending-machine edits.
//!
//! Extracted from game.zig's handlePackage following the replicate_te
//! precedent. `handle` returns true when the package name belongs to this
//! domain; handlePackage falls through to the remaining arms otherwise.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const ecs = @import("../../ecs/root.zig");
const systems = @import("../../ecs/systems.zig");
const c2s_text = @import("../c2s_text.zig");
const replicate_te = @import("../replicate_te.zig");
const vending_mod = @import("../../world/vending.zig");

/// True when `name` belongs to this domain and was handled.
pub fn handle(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (std.mem.eql(u8, name, "NetPackageLandClaimRepair")) {
        // Same rate gate as SetBlock: unthrottled would let a spam loop fan
        // this broadcast out to every connected peer for free (bandwidth DoS).
        if (!self.takeBlockToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        _ = packages.parseLandClaimRepair(body) catch return true;
        try self.broadcast("NetPackageLandClaimRepair", body);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageSharedQuest")) {
        const head = packages.stock_quest.parseSharedQuestHead(body) catch return true;
        // Stock GameManager.QuestShareServer: if sharedWith is local, handle; else
        // forward package to sharedWithEntityID. We forward the body unchanged and
        // update server journal only when quest_id maps to a known catalog def.
        if (head.event == .share_quest) {
            if (head.quest_id_len > 0) {
                if (self.sim.catalog.byName(head.questId())) |d| {
                    _ = systems.questAccept(&self.sim, c.slot, d.id);
                }
            }
            const with = if (head.shared_with_entity_id > 0) head.shared_with_entity_id else c.entity_id;
            if (with == c.entity_id) {
                try self.sendGame(peer, "NetPackageSharedQuest", body);
            } else {
                // Forward to target peer if present; otherwise broadcast (party).
                var sent = false;
                for (&self.clients) |*cl| {
                    if (!cl.joined or cl.entity_id != with) continue;
                    if (cl.peer) |tp| {
                        try self.sendGame(tp, "NetPackageSharedQuest", body);
                        sent = true;
                    }
                    break;
                }
                if (!sent) try self.broadcast("NetPackageSharedQuest", body);
            }
        } else if (head.event == .remove_quest) {
            // Prefer stock Quest.QuestCode; fall back to catalog def_id for old clients.
            if (head.quest_code != 0) {
                if (systems.questFindByCode(&self.sim, c.slot, head.quest_code)) |s| {
                    s.active = false;
                    s.completed = false;
                } else if (head.quest_code > 0 and head.quest_code <= 65535) {
                    if (systems.questFindActive(&self.sim, c.slot, @intCast(head.quest_code))) |s| {
                        s.active = false;
                        s.completed = false;
                    }
                }
            }
            try self.sendGame(peer, "NetPackageSharedQuest", body);
        } else {
            try self.broadcast("NetPackageSharedQuest", body);
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackagePartyQuestChange")) {
        const q = packages.parsePartyQuestChange(body) catch {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        };
        if (q.sender_entity != c.entity_id) {
            self.harness.counters.inc(.ownership_rejects);
            return true;
        }
        const p = self.parties.partyByMember(c.entity_id) orelse return true;
        for (p.members[0..p.n]) |m| {
            if (m == c.entity_id) continue;
            if (self.clientByEntityId(m)) |member| {
                if (member.peer) |mp| {
                    self.sendGame(mp, "NetPackagePartyQuestChange", body) catch |err| {
                        self.harness.counters.inc(.net_send_errors);
                        std.debug.print("zdtd: send PartyQuestChange failed: {s}\n", .{@errorName(err)});
                    };
                }
            }
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackagePartyActions")) {
        try self.handlePartyActions(c, body);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackagePartyData")) {
        self.harness.counters.inc(.ownership_rejects);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageAllyRequest")) {
        try self.handleAllyRequest(c, body);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageAllyResponse")) {
        self.harness.counters.inc(.ownership_rejects);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageWaypoint")) {
        // Stock NetPackageWaypoint.ProcessPackage (IL=29): ValidEntityIdForSender
        // gate, then GameManager.WaypointInviteServer (IL=164) relays to the
        // inviter's allies (EnumWaypointInviteMode Friends=0, AllyStore.IsAlly
        // on primary ids) or to all players (Everyone=1), skipping the
        // inviter, with the waypoint cloned, bTracked cleared and
        // inviterEntityId re-keyed to the inviter (Setup).
        const wp = packages.parseWaypointInvite(body) catch {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        };
        if (wp.inviter_entity_id != c.entity_id) {
            self.harness.counters.inc(.ownership_rejects);
            return true;
        }
        const inviter_id = c.puid_primary.get() orelse return true;
        for (&self.clients) |*cl| {
            if (!cl.joined or cl.entity_id == c.entity_id) continue;
            if (cl.peer == null) continue;
            if (wp.invite_mode == 0) {
                const target_id = cl.puid_primary.get() orelse continue;
                if (!self.allies.isAlly(inviter_id, target_id)) continue;
            }
            const relay = packages.buildWaypointInviteBody(self.body_buf[0..512], &wp, c.entity_id) catch continue;
            self.sendGame(cl.peer.?, "NetPackageWaypoint", relay) catch |err| {
                self.harness.counters.inc(.net_send_errors);
                std.debug.print("zdtd: send Waypoint failed: {s}\n", .{@errorName(err)});
            };
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageAddRemoveBuff")) {
        try self.handleAddRemoveBuff(c, body);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageQuestEvent")) {
        try self.handleQuestEvent(peer, c, body);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageQuestObjectiveUpdate")) {
        // Stock wire: treasure/block objective events mirror the client's
        // own quest progress into the server journal (so it persists and
        // can coordinate). block_activated advances the block_activate
        // phase; treasure_complete advances the fetch phase (the client dug
        // the chest / finished the fetch), so a treasure/fetch quest reaches
        // turn-in through its real event instead of the old kill-loot hack.
        // treasure_radius_break is mid-dig progress — recorded, not applied.
        // Also accept legacy zdtd-native {def_id u16, op u8} for unit fixtures.
        if (packages.parseQuestObjectiveUpdate(body)) |u| {
            switch (u.event_type) {
                .block_activated => _ = systems.questObjectiveEvent(&self.sim, c.slot, u.quest_code, .block_activate),
                .treasure_complete => _ = systems.questObjectiveEvent(&self.sim, c.slot, u.quest_code, .fetch_item),
                .treasure_radius_break => {},
            }
        } else |_| {
            if (packages.parseQuestOp(body)) |op| {
                if (op.op == 1) _ = self.acceptQuestFor(c, op.def_id);
            } else |_| {}
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageNPCQuestList")) {
        // Stock trader quest-list exchange: FetchList with QuestPacketEntry offers.
        const head = packages.parseNpcQuestList(body) catch packages.NpcQuestListHead{
            .npc_entity_id = 0,
            .player_entity_id = c.entity_id,
            .event_type = .fetch_list,
        };
        var tx: f32 = 0;
        var ty: f32 = 70;
        var tz: f32 = 0;
        if (self.sim.slotOfNetId(head.npc_entity_id)) |ni| {
            if (self.sim.mask[ni].transform) {
                tx = self.sim.transform[ni].x;
                ty = self.sim.transform[ni].y;
                tz = self.sim.transform[ni].z;
            }
        }
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
                    if (d.difficulty_tier != head.tier_level) continue;
                    const ps = self.sim.playerByPeer(c.slot) orelse break;
                    if (self.sim.mask[ps].journal and self.sim.journal[ps].hasActive(qid)) continue;
                    if (idx == head.remove_index) {
                        _ = self.acceptQuestFor(c, qid);
                        break;
                    }
                    idx += 1;
                }
            }
            var offers: [8]packages.stock_quest.QuestPacketEntry = undefined;
            const on = self.buildTraderQuestOffers(self.traderQuestList(head.npc_entity_id), c.slot, tx, ty, tz, @intCast(@max(head.tier_level, 0)), &offers);
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
            const on = self.buildTraderQuestOffers(self.traderQuestList(head.npc_entity_id), c.slot, tx, ty, tz, @intCast(@max(head.tier_level, 0)), &offers);
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
        if (body.len >= 9 and (body[8] == 0 or body[8] == 1)) {
            try self.handleTrade(c, body);
            return true;
        }
        systems.questOnTraderOpen(&self.sim, c.slot);
        // Stock trader quest offers (npc from open body when present).
        const npc_id: i32 = if (body.len >= 4) std.mem.readInt(i32, body[0..4], .little) else 0;
        // Server-side catalog accept for loadgen/sim; stock UI uses NPCQuestList.
        if (self.sim.catalog.listById(self.traderQuestList(npc_id))) |list| {
            for (list.entries) |qid| {
                if (self.acceptQuestFor(c, qid)) break;
            }
        }
        try self.sendTraderSnapshot(peer, null);
        var offers: [8]packages.stock_quest.QuestPacketEntry = undefined;
        var tx: f32 = 0;
        var ty: f32 = 70;
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
        const info = self.traders.traderInfo(@intCast(vm.trader_id)) orelse return true;
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
            const from_inv: u32 = @min(have, cost);
            if (from_inv > 0) {
                if (!self.sim.inventory[ps].removeItem(coins, @intCast(from_inv))) return true;
                self.sim.markDirty(ps, .{ .inv = true });
            }
        }
        self.sim.wallet[ps].coins -= cost;
        vm.owner.set(acc.user) catch return true;
        // Stock term: RentTimeInDays (trader_info rent_time, default 30).
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
