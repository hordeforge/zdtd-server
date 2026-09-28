//! Tick equip sync: stage buffs, equip markers, mod rows.
//!
//! Split out of server/game/tick.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ecs = @import("../../ecs/root.zig");
const assets_buffs = @import("../../assets/buffs.zig");
const requirements = @import("../../assets/requirements.zig");
const game_types = @import("types.zig");
const buff_events = @import("buff_events.zig");
const addCatalogBuff = buff_events.addCatalogBuff;
const tick = @import("tick.zig");
const fillItemMods = tick.fillItemMods;

pub fn syncStageBuffs(self: *Game, ps: ecs.Slot, keep: assets_buffs.SurvivalStages) void {
    const set = self.sim.buffsMut(ps);
    var remove_ids: [assets_buffs.max_triggered_removes]u16 = undefined;
    var n_rem: usize = 0;
    for (&set.slots) |*slot| {
        if (!slot.active) continue;
        const def = self.buffs.byId(slot.def_id) orelse continue;
        const stage = assets_buffs.stageOfBuffName(def.name) orelse continue;
        if (!std.mem.startsWith(u8, def.name, "buffStatusHungry") and
            !std.mem.startsWith(u8, def.name, "buffStatusThirsty")) continue;
        // Only the threshold-selected stage stays; anything lower or higher is a
        // stale stage.
        const keep_stage = if (std.mem.startsWith(u8, def.name, "buffStatusThirsty")) keep.thirsty else keep.hungry;
        if (stage == keep_stage) continue;
        if (n_rem < remove_ids.len) {
            remove_ids[n_rem] = slot.def_id;
            n_rem += 1;
        }
    }
    for (remove_ids[0..n_rem]) |id| {
        _ = ecs.buff.remove(set, id);
    }
}

/// Equip-marker reconcile: an equipped item's `onSelfEquipStart` rows grant
/// marker buffs (buffRogueBoots et al, which the fall-damage path gates on)
/// and seed per-item cvars (boot fall-damage reductions, miner healing).
/// Stock fires these on the equip edge; the server diffs the worn slots
/// against `c.equip_seen` per tick and fires the old item's `onSelfEquipStop`
/// rows plus the new item's `onSelfEquipStart` rows through the shared
/// engine (gated, relayed, cvars written). Bounded by the equip slot count;
/// no allocation.
pub fn syncEquipMarkers(self: *Game, c: *Client, ps: ecs.Slot, base_ctx: requirements.Ctx) void {
    if (!self.sim.mask[ps].inventory) return;
    const inv = &self.sim.inventory[ps];
    var req_counts: requirements.Counts = .{};
    // No live sink: buff adds apply once through applyEquipStart/Stop below.
    // (base_ctx carries the survival pass sink, which would double-apply and
    // wrongly fire stack rows on the second add.)
    var nosink_ctx = base_ctx;
    nosink_ctx.sink = null;
    nosink_ctx.other_sink = null;
    var esi: usize = ecs.components.inv_equip_start;
    while (esi < ecs.components.max_inv_slots) : (esi += 1) {
        syncEquipSlot(self, c, ps, &inv.slots[esi], &c.equip_seen[esi - ecs.components.inv_equip_start], true, &nosink_ctx, &req_counts);
    }
    // The held weapon's own + installed mods' equip rows (cripple/burn proc
    // cvars seed here; the damage rows read them at hit time).
    if (inv.holding < ecs.components.inv_toolbelt) {
        syncEquipSlot(self, c, ps, &inv.slots[inv.holding], &c.held_seen, false, &nosink_ctx, &req_counts);
    } else if (c.held_seen.id != 0) {
        c.held_seen = .{};
    }
    self.harness.counters.add(.requirement_gates, req_counts.resolved);
    self.harness.counters.add(.requirement_unsupported, req_counts.unsupported);
}

/// One slot's equip edge: old item stop rows, new item start rows (or update
/// rows on quality change), plus installed mods' rows. `equipped` answers
/// IsEquipped (false for the held slot: Equipment::GetItems excludes it).
pub fn syncEquipSlot(
    self: *Game,
    c: *Client,
    ps: ecs.Slot,
    slot: *const ecs.components.InvSlot,
    seen: *game_types.EquipSeen,
    equipped: bool,
    nosink_ctx: *requirements.Ctx,
    req_counts: *requirements.Counts,
) void {
    const cur_id: u16 = if (slot.count == 0) 0 else slot.item_id;
    const prev_id: u16 = seen.id;
    const prev_mods = seen.mods;
    if (cur_id == prev_id and (cur_id == 0 or slot.quality == seen.quality)) return;
    seen.* = .{ .id = cur_id, .quality = slot.quality, .mods = slot.mods };
    if (prev_id != 0 and cur_id != prev_id) {
        if (self.items.byId(prev_id)) |old_def| {
            if (old_def.triggered.len != 0) {
                var sctx = nosink_ctx.*;
                sctx.item_equipped = equipped;
                const res = assets_buffs.evaluateRows(old_def.triggered, .equip_stop, sctx, req_counts);
                if (res.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, res.truncated);
                applyEquipStop(self, ps, &res);
            }
        }
        // Removed piece's installed mods stop rows (RemoveCVar cleanup
        // like $crippleChance); mod ids snapshot before the overwrite.
        fireSeenModRows(self, c, ps, &prev_mods, .equip_stop, req_counts);
    }
    if (cur_id != 0) {
        // Installed mods' own equip rows fire even when the host item has
        // no rows of its own (clubs carry no triggered rows; their mods do).
        if (cur_id != prev_id) fireModEquipRows(self, c, ps, slot, .equip_start, req_counts);
        if (self.items.byId(cur_id)) |new_def| {
            if (new_def.triggered.len != 0) {
                var sctx = nosink_ctx.*;
                sctx.item_equipped = equipped;
                sctx.item_active = (slot.flags & 1) != 0;
                sctx.item_tags = new_def.tags;
                sctx.item_quality = slot.quality;
                sctx.item_meta_charge = slot.meta_charge;
                // Item-parent curves index valueList by quality tier
                // (minevents.md Execute IL=154).
                sctx.item_level = slot.quality;
                var mod_buf: [4]requirements.NameLevel = undefined;
                sctx.item_mods = fillItemMods(self, slot.mods, slot.mod_qualities, &mod_buf);
                if (cur_id != prev_id) {
                    const res = assets_buffs.evaluateRows(new_def.triggered, .equip_start, sctx, req_counts);
                    if (res.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, res.truncated);
                    applyEquipStart(self, c, ps, &res);
                } else {
                    // Same piece, new quality: tier-curved cvars refresh.
                    const res = assets_buffs.evaluateRows(new_def.triggered, .equip_update, sctx, req_counts);
                    if (res.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, res.truncated);
                }
            }
        }
    }
}

/// Apply an equip-start result: marker buffs land (gated adds relay), cvar
/// writes already landed through the ctx store during evaluation.
pub fn applyEquipStart(self: *Game, c: *Client, ps: ecs.Slot, res: *const assets_buffs.TriggeredResult) void {
    for (res.add_buffs[0..res.add_n]) |names| {
        var it = std.mem.splitScalar(u8, names, ',');
        while (it.next()) |seg| {
            const name = std.mem.trim(u8, seg, " \t");
            if (name.len == 0) continue;
            _ = addCatalogBuff(self, c.entity_id, ps, name, c.entity_id);
        }
    }
}

/// Apply an equip-stop result: flagged removals reap through the buff tick
/// (relayed once there), RemoveCVar lists already cleared during evaluation.
pub fn applyEquipStop(self: *Game, ps: ecs.Slot, res: *const assets_buffs.TriggeredResult) void {
    const set = self.sim.buffsMut(ps);
    for (res.remove_buffs[0..res.remove_n]) |names| {
        var it = std.mem.splitScalar(u8, names, ',');
        while (it.next()) |seg| {
            const name = std.mem.trim(u8, seg, " \t");
            if (name.len == 0) continue;
            const def_id = self.buffs.indexOfName(name) orelse continue;
            _ = ecs.buff.remove(set, def_id);
        }
    }
}

/// Fire one installed mod's equip rows with the host item's ctx (mod quality
/// in item_mods answers RequirementItemModTier; the mod's own tier gates
/// read it too). Start rows apply buffs/cvars; stop rows clean up.
pub fn fireOneModRows(
    self: *Game,
    c: *Client,
    ps: ecs.Slot,
    mod_id: u16,
    sctx: requirements.Ctx,
    event: assets_buffs.Trigger,
    req_counts: *requirements.Counts,
) void {
    const mdef = self.items.byId(mod_id) orelse return;
    const mrows = self.item_mods.byName(mdef.name) orelse return;
    if (mrows.triggered.len == 0) return;
    const res = assets_buffs.evaluateRows(mrows.triggered, event, sctx, req_counts);
    if (res.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, res.truncated);
    if (event == .equip_start) {
        applyEquipStart(self, c, ps, &res);
    } else {
        applyEquipStop(self, ps, &res);
    }
}

/// Fire installed mods' equip-start rows for a newly worn piece.
pub fn fireModEquipRows(
    self: *Game,
    c: *Client,
    ps: ecs.Slot,
    slot: *const ecs.components.InvSlot,
    event: assets_buffs.Trigger,
    req_counts: *requirements.Counts,
) void {
    const def = self.items.byId(slot.item_id) orelse return;
    var sctx = requirements.Ctx{
        .levels = c.skill_levels[0..c.skill_level_n],
        .player_level = c.level,
        .item_equipped = true,
        .item_tags = def.tags,
        .item_quality = slot.quality,
        .item_level = slot.quality,
        .item_meta_charge = slot.meta_charge,
        .cvars = &c.cvars,
    };
    var mod_buf: [4]requirements.NameLevel = undefined;
    sctx.item_mods = fillItemMods(self, slot.mods, slot.mod_qualities, &mod_buf);
    for (slot.mods) |mod_id| {
        if (mod_id == 0) continue;
        fireOneModRows(self, c, ps, mod_id, sctx, event, req_counts);
    }
}

/// Fire stored mod ids' stop rows for a removed piece (mod ids ride
/// equip_seen because the live slot is already overwritten).
pub fn fireSeenModRows(
    self: *Game,
    c: *Client,
    ps: ecs.Slot,
    mods: *const [4]u16,
    event: assets_buffs.Trigger,
    req_counts: *requirements.Counts,
) void {
    const sctx = requirements.Ctx{
        .levels = c.skill_levels[0..c.skill_level_n],
        .player_level = c.level,
        .item_equipped = true,
        .cvars = &c.cvars,
    };
    for (mods.*) |mod_id| {
        if (mod_id == 0) continue;
        fireOneModRows(self, c, ps, mod_id, sctx, event, req_counts);
    }
}
