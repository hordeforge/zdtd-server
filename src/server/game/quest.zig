//! Quest helpers — journal snapshots + trader offers + POI quest events.
//! Extracted from game.zig; helpers take *Game (called as game_quest.foo(g, …)).
//! Bodies are verbatim copies (stock asm.il comments kept).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const ecs = @import("../../ecs/root.zig");
const systems = @import("../../ecs/systems.zig");

const max_quest_position_data = game_mod.max_quest_position_data;

pub fn handleQuestEvent(self: *Game, peer: *ln_peer.Peer, c: *Client, body: []const u8) !void {
    const head = packages.stock_quest.parseQuestEventHead(body) catch return;
    // Trust boundary: a peer may only raise quest events for its own entity.
    if (head.entity_id != c.entity_id) return;
    switch (head.event) {
        .try_rally_marker => {
            const lockout = systems.questCheckPoiLockout(&self.sim, c.entity_id, head.px, head.pz);
            var reply = head;
            reply.extra_data = lockout.extra_data;
            // Reason → reply event, from the switch at asm.il 835696 IL_009d.
            reply.event = switch (lockout.reason) {
                .none => .rally_marker_activated,
                .player_inside => .rally_marker_player_locked,
                .bedroll => .rally_marker_bedroll_locked,
                .land_claim => .rally_marker_land_claim_locked,
                .quest_lock => .rally_marker_locked,
            };
            if (lockout.reason == .none) {
                // An unknown or already spent quest code gets no reply: the
                // marker must not report activated for a quest we cannot track.
                if (!systems.questOnRallyActivated(&self.sim, c.slot, head.quest_code)) return;
                systems.questPoiLock(&self.sim, c.entity_id, head.px, head.pz);
                // The quest now dedicates this POI: restore its baked blocks
                // (PrefabInstance.ResetBlocksAndRebuild on quest dedication).
                self.resetPoiBlocks(@intFromFloat(head.px), @intFromFloat(head.pz));
            }
            const out = try packages.stock_quest.buildQuestEvent(self.body_buf[0..64], reply);
            if (lockout.reason == .none) {
                // Activation is shared state (shared-quest party members see
                // the same marker); a refusal only concerns the requester.
                try self.broadcast("NetPackageQuestEvent", out);
            } else {
                try self.sendGame(peer, "NetPackageQuestEvent", out);
            }
        },
        .lock_poi => {
            systems.questPoiLock(&self.sim, c.entity_id, head.px, head.pz);
            // Lock acquisition = quest dedication: restore the POI blocks.
            self.resetPoiBlocks(@intFromFloat(head.px), @intFromFloat(head.pz));
        },
        .unlock_poi => systems.questPoiUnlock(&self.sim, c.entity_id, head.px, head.pz),
        else => return,
    }
}

/// Fill stock Quest.Write snapshots for active journal slots. pub so the
/// GAP 12 scenario can assert the full journal (not just the old 2) rides
/// the join PDF.
pub fn fillStockJournalWrites(
    self: *Game,
    peer_slot: usize,
    out: []packages.stock_quest.StockQuestWrite,
    reward_store: *[ecs.components.max_journal][ecs.quest.max_reward_flags]packages.stock_quest.RewardWire,
    obj_val_store: *[ecs.components.max_journal][ecs.quest.max_phases]u8,
    kind_store: *[ecs.components.max_journal][ecs.quest.max_phases]packages.stock_quest.ObjectiveWriteKind,
    pos_store: *[ecs.components.max_journal][max_quest_position_data]packages.stock_quest.PositionEntry,
) usize {
    const ps = self.sim.playerByPeer(peer_slot) orelse return 0;
    if (!self.sim.mask[ps].journal) return 0;
    var n: usize = 0;
    for (self.sim.journal[ps].slots) |s| {
        if (!s.active and !s.completed) continue;
        if (n >= out.len or n >= reward_store.len) break;
        const d = self.sim.catalog.byId(s.def_id) orelse continue;
        if (d.name.len == 0 or !self.isStockClientQuestName(d.name)) continue;
        const state: packages.stock_quest.QuestState = if (s.completed)
            .completed
        else if (s.ready_turn_in)
            .ready_turn_in
        else
            .in_progress;
        var prog: u8 = 0;
        if (s.progress > 0) prog = @intCast(@min(s.progress, 255));
        const rc: usize = @min(@as(usize, d.reward_count), ecs.quest.max_reward_flags);
        var ri: usize = 0;
        while (ri < rc) : (ri += 1) {
            var wire: packages.stock_quest.RewardWire = .{ .has_item_stack = false };
            const spec = if (ri < d.reward_n) d.rewards[ri] else ecs.quest.RewardSpec{};
            if (spec.kind == .item or spec.kind == .loot_item) {
                wire.has_item_stack = true;
                // The client resolves the ItemStack through its own items
                // catalog; resolve the stock name to the negotiated type id.
                // An unknown name keeps the stock Empty stack (fail closed).
                if (self.items.byStockName(spec.item_name)) |st| {
                    wire.item = .{
                        .type_id = st,
                        .count = @intCast(@min(spec.value, 65535)),
                        .quality = 1,
                    };
                }
            }
            reward_store[n][ri] = wire;
        }
        const phase: u8 = if (s.completed)
            255
        else if (s.phase > 0)
            s.phase
        else if (s.ready_turn_in)
            2
        else
            1;
        const qcode: i32 = if (s.quest_code != 0) s.quest_code else @intCast(d.id);
        // Per-objective CurrentValue from the phase graph: completed phases
        // report 255 (>= client required), the active phase reports clamped
        // progress, future phases 0. Legacy defs fall back to first_objective_value.
        var obj_vals: []const u8 = &.{};
        if (d.objective_phases.len > 0) {
            const req: u16 = if (s.phase > 0 and s.phase <= d.phases.len)
                d.phases[s.phase - 1].required
            else
                s.progress;
            var oi: usize = 0;
            const lim = @min(d.objective_phases.len, obj_val_store[n].len);
            while (oi < lim) : (oi += 1) {
                const op = d.objective_phases[oi];
                obj_val_store[n][oi] = if (s.completed or op < s.phase)
                    255
                else if (op == s.phase)
                    @intCast(@min(@min(s.progress, req), @as(u16, 255)))
                else
                    0;
            }
            obj_vals = obj_val_store[n][0..lim];
        }
        // PositionData: the Location marker plus, when the quest was placed
        // in a POI, the rect ObjectiveRallyPoint scans for its rally block.
        var pn: usize = 0;
        if (d.kind == .goto_point or d.kind == .kill_zombies or d.kind == .fetch_item) {
            // Goto target: the bound POI center (audit B26) or the def
            // marker when no POI data exists.
            const gx: f32 = if (d.kind == .goto_point and s.poi.valid()) s.poi.x + s.poi.size_x * 0.5 else d.tx;
            const gz: f32 = if (d.kind == .goto_point and s.poi.valid()) s.poi.z + s.poi.size_z * 0.5 else d.tz;
            pos_store[n][pn] = .{
                .kind = packages.stock_quest.position_data_location,
                .x = if (d.kind == .goto_point) gx else self.sim.transform[ps].x,
                .y = if (d.kind == .goto_point) d.ty else self.sim.transform[ps].y,
                .z = if (d.kind == .goto_point) gz else self.sim.transform[ps].z,
            };
            pn += 1;
        }
        if (s.poi.valid()) {
            pos_store[n][pn] = .{
                .kind = packages.stock_quest.position_data_poi_position,
                .x = s.poi.x,
                .y = s.poi.y,
                .z = s.poi.z,
            };
            pos_store[n][pn + 1] = .{
                .kind = packages.stock_quest.position_data_poi_size,
                .x = s.poi.size_x,
                .y = s.poi.size_y,
                .z = s.poi.size_z,
            };
            pn += 2;
        }
        // Per-objective Write subclass from the catalog (TreasureChest and
        // POIStayWithin use non-base shapes; everything else is Base).
        var kinds: []const packages.stock_quest.ObjectiveWriteKind = &.{};
        if (d.objective_kinds.len > 0) {
            const klim = @min(d.objective_kinds.len, kind_store.len);
            var ki: usize = 0;
            while (ki < klim) : (ki += 1) {
                kind_store[n][ki] = switch (d.objective_kinds[ki]) {
                    .base => .base,
                    .treasure_chest => .treasure_chest,
                    .empty => .empty,
                };
            }
            kinds = kind_store[n][0..klim];
        }
        out[n] = .{
            .id = d.name,
            .state = state,
            .quest_code = qcode,
            .current_phase = phase,
            .objective_count = d.objective_count,
            .first_objective_value = prog,
            .objective_values = obj_vals,
            .objective_kinds = kinds,
            .rewards = reward_store[n][0..rc],
            .position_data = pos_store[n][0..pn],
            .rally_marker_activated = s.rally_activated,
        };
        n += 1;
    }
    return n;
}

/// Build trader FetchList offers from a quest_list id (stock quest names
/// only). A quest already active in the player's journal is not re-offered:
/// stock removes it from the NPCQuestList on accept (the accept marker).
/// The quest list a trader offers resolves from npc.xml (quest_list per
/// trader_info id; the entity class picked the id at spawn). When npc.xml
/// is absent (fixtures) the stock class-hash map below is the fallback so
/// a modded trader still gets offers.
pub fn traderQuestList(self: *const Game, npc_entity_id: i32) []const u8 {
    const hash = if (self.sim.slotOfNetId(npc_entity_id)) |ts|
        self.sim.class_id[ts].hash
    else
        0;
    if (self.sim.slotOfNetId(npc_entity_id)) |ts| {
        const info_id = self.sim.trader_stock[ts].trader_info_id;
        if (info_id != 0) {
            if (self.npc.questListForTrader(info_id)) |ql| return ql;
        }
    }
    if (hash == packages.stock_entity.class_npc_trader_rekt) return "trader_rekt_quests";
    if (hash == packages.stock_entity.class_npc_trader_bob) return "trader_bob_quests";
    if (hash == packages.stock_entity.class_npc_trader_hugh) return "trader_hugh_quests";
    if (hash == packages.stock_entity.class_npc_trader_joel) return "trader_joel_quests";
    return "trader_jen_quests";
}

pub fn buildTraderQuestOffers(
    self: *Game,
    list_id: []const u8,
    peer_slot: usize,
    trader_x: f32,
    trader_y: f32,
    trader_z: f32,
    tier: u8,
    out: []packages.stock_quest.QuestPacketEntry,
) usize {
    const list = self.sim.catalog.listById(list_id) orelse return 0;
    const ps = self.sim.playerByPeer(peer_slot) orelse return 0;
    var n: usize = 0;
    for (list.entries) |qid| {
        if (n >= out.len) break;
        const d = self.sim.catalog.byId(qid) orelse continue;
        if (d.name.len == 0 or !self.isStockClientQuestName(d.name)) continue;
        // Stock filters the trader's quest list by DifficultyTier == the
        // requested tierLevel (asm.il 827746-827975). tier 0 = no filter.
        if (tier != 0 and d.difficulty_tier != tier) continue;
        if (self.sim.mask[ps].journal and self.sim.journal[ps].hasActive(qid)) continue;
        out[n] = .{
            .quest_id = d.name,
            .loc_x = d.tx,
            .loc_y = d.ty,
            .loc_z = d.tz,
            .poi_name = d.name,
            .trader_x = trader_x,
            .trader_y = trader_y,
            .trader_z = trader_z,
        };
        n += 1;
    }
    return n;
}
