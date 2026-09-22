//! Tick orchestration - extracted from game.zig; helpers take *Game.
//! Bodies are verbatim copies from src/server/game.zig (stock asm.il comments kept).
//! game.zig is not edited in this extraction - it retains its own methods as
//! forwarding wrappers will be added by the main swarm step.

const std = @import("std");
const apm = @import("../../apm/root.zig");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ecs = @import("../../ecs/root.zig");
const assets_buffs = @import("../../assets/buffs.zig");
const assets_unity_hash = @import("../../assets/unity_hash.zig");
const assets_progression = @import("../../assets/progression.zig");
const requirements = @import("../../assets/requirements.zig");
const sandbox = @import("../../assets/sandbox.zig");
const hooks = @import("hooks.zig");
const clock = @import("../../util/clock.zig");
const inventory = @import("../../ecs/inventory.zig");
const game_types = @import("types.zig");
const assets_items = @import("../../assets/items.zig");

const buff_events = @import("buff_events.zig");
// Names owned by buff_events.zig that the survival VM below still uses.
pub const PlayerCtx = buff_events.PlayerCtx;
pub const addCatalogBuff = buff_events.addCatalogBuff;
pub const entityClassTags = buff_events.entityClassTags;
pub const drainPendingMods = buff_events.drainPendingMods;
pub const skillLevelsForEntity = buff_events.skillLevelsForEntity;
pub const armor_query_tags = buff_events.armor_query_tags;
pub const applyTriggeredBuffsAoe = buff_events.applyTriggeredBuffsAoe;
pub const applyTriggeredBuffs = buff_events.applyTriggeredBuffs;
const tick_equip = @import("tick_equip.zig");
// Names owned by tick_equip.zig that the survival VM below still uses.
pub const syncStageBuffs = tick_equip.syncStageBuffs;
pub const syncEquipMarkers = tick_equip.syncEquipMarkers;

/// One entry per worn equipment item: its `Tags` property (comma list), the
/// input `WornItems` (IL=54) counts. Empty tags are kept as an empty entry so
/// the slot count matches `Equipment::GetSlotCount` semantics, but no tag can
/// match it.
pub fn wornItemTags(self: *const Game, ps: ecs.Slot, out: *[ecs.components.inv_equip_count][]const u8) []const []const u8 {
    if (!self.sim.mask[ps].inventory) return out[0..0];
    const inv = &self.sim.inventory[ps];
    var n: usize = 0;
    var i: usize = ecs.components.inv_equip_start;
    const end = @min(i + ecs.components.inv_equip_count, inv.slots.len);
    while (i < end) : (i += 1) {
        const sl = inv.slots[i];
        if (sl.count == 0 or sl.item_id == 0) continue;
        const def = self.items.byId(sl.item_id) orelse continue;
        out[n] = def.tags;
        n += 1;
    }
    return out[0..n];
}

/// Worn armor groups and their lowest worn quality, into `out`; returns the
/// used prefix. `Equipment::ResetArmorGroups` (IL=51) walks the equipment slots,
/// keeps each `ItemClassArmor` item's `ArmorGroup` names and tracks the minimum
/// quality per group, so a group that is not worn is absent (the lookup then
/// reads 0). Bounded by the group count stock can reach (<= 12 worn items).
pub fn armorGroups(self: *const Game, ps: ecs.Slot, out: []requirements.ArmorGroup) []const requirements.ArmorGroup {
    if (!self.sim.mask[ps].inventory) return out[0..0];
    const inv = &self.sim.inventory[ps];
    var n: usize = 0;
    var i: usize = ecs.components.inv_equip_start;
    const end = @min(i + ecs.components.inv_equip_count, inv.slots.len);
    while (i < end) : (i += 1) {
        const s = inv.slots[i];
        if (s.count == 0 or s.item_id == 0) continue;
        const def = self.items.byId(s.item_id) orelse continue;
        if (def.armor_group.len == 0) continue;
        var it = std.mem.splitScalar(u8, def.armor_group, ',');
        while (it.next()) |seg| {
            const name = std.mem.trim(u8, seg, " \t");
            if (name.len == 0) continue;
            var hit = false;
            for (out[0..n]) |*g| {
                if (!std.mem.eql(u8, g.name, name)) continue;
                if (s.quality < g.quality) g.quality = s.quality;
                g.count +|= 1;
                hit = true;
                break;
            }
            if (hit) continue;
            if (n >= out.len) return out[0..n];
            out[n] = .{ .name = name, .quality = s.quality, .count = 1 };
            n += 1;
        }
    }
    return out[0..n];
}

/// Head block is water: the drowning depth gate, shared by the
/// `_underwater` cvar mirror (stock sets it client-side; never networked).
pub fn isHeadUnderwater(game: *Game, ps: ecs.Slot) bool {
    const water_id = game.world.terrain_ids.water;
    if (water_id == 0) return false;
    if (!game.sim.mask[ps].transform) return false;
    const t = game.sim.transform[ps];
    const id = game.world.blockWorld(
        @trunc(t.x),
        @as(i32, @trunc(t.y)) + 1,
        @trunc(t.z),
    ) catch 0;
    return id == water_id;
}

/// The held item's `Tags` property, or "" for an empty hand.
/// `HoldingItemHasTags::IsValid` (IL=37) reads
/// `Inventory.get_holdingItem().HasAnyTags/HasAllTags`, and an empty hand
/// matches no tag.
pub fn heldItemTags(self: *const Game, ps: ecs.Slot) []const u8 {
    if (!self.sim.mask[ps].inventory) return "";
    const inv = &self.sim.inventory[ps];
    if (inv.holding >= ecs.components.inv_toolbelt) return "";
    const s = inv.slots[inv.holding];
    if (s.count == 0 or s.item_id == 0) return "";
    const def = self.items.byId(s.item_id) orelse return "";
    return def.tags;
}

/// Held item declares a secondary action (`Action1`): the IsSecondaryAttack
/// IL=65 shape check (heavy attack on melee weapons), not the swing type.
pub fn heldItemHasSecondary(self: *const Game, ps: ecs.Slot) bool {
    if (!self.sim.mask[ps].inventory) return false;
    const inv = &self.sim.inventory[ps];
    if (inv.holding >= ecs.components.inv_toolbelt) return false;
    const s = inv.slots[inv.holding];
    if (s.count == 0 or s.item_id == 0) return false;
    const def = self.items.byId(s.item_id) orelse return false;
    return def.has_secondary;
}

/// Held ItemValue brokenness for `HoldingItemBroken`: PercentUsesLeft == 0
/// (`UseTimes >= MaxUseTimes`). Empty hand / unknown item / no durability → false.
pub fn holdingItemBroken(self: *const Game, ps: ecs.Slot) bool {
    if (!self.sim.mask[ps].inventory) return false;
    const inv = &self.sim.inventory[ps];
    if (inv.holding >= ecs.components.inv_toolbelt) return false;
    const s = inv.slots[inv.holding];
    if (s.count == 0 or s.item_id == 0) return false;
    const def = self.items.byId(s.item_id) orelse return false;
    const max_use = hooks.maxUseTimes(def, s.quality);
    if (max_use == 0) return false;
    return s.use_times >= @as(f32, @floatFromInt(max_use));
}

/// Whether the entity rides in any vehicle seat (`Entity::AttachedToEntity`
/// for `IsAttachedToEntity`; stock attaches on EntityVehicle). Linear scan
/// over live vehicles; seated players are rare and the fold runs per player.
pub fn isSeated(sim: *const ecs.World, entity_id: i32) bool {
    var it = sim.alive_bits.iterator(.{});
    while (it.next()) |idx| {
        const i: ecs.Slot = @intCast(idx);
        if (!sim.mask[i].vehicle) continue;
        for (sim.vehicle[i].seats[0..sim.vehicle[i].usableSeats()]) |rider| {
            if (rider == entity_id) return true;
        }
    }
    return false;
}

/// Passive-effects VM recomputes per player per tick: the untagged stats query
/// and the `coredamageresist` armor query, each over the buff and perk legs.
const vm_recomputes_per_player = 4;

/// Active buff def ids in `set`, into `out`; returns the used prefix. Bounded
/// by the fixed `BuffSet` slot count, so no allocation.
pub fn activeBuffIds(set: *const ecs.components.BuffSet, out: []u16) []const u16 {
    var n: usize = 0;
    for (&set.slots) |*s| {
        if (!s.active) continue;
        if (n >= out.len) break;
        out[n] = s.def_id;
        n += 1;
    }
    return out[0..n];
}

/// PlayerEntityStats survival loop (GAP 22; RE entity-stats.md §2):
/// Food/Water deplete with in-game time. Base drain is engine-driven
/// (`Rules.progression` - no XML row carries the rate, see buffs.Survival),
/// but the damage, regen and thresholds come from `buffs.xml` when `Game.buffs`
/// carries them: `buffs.survival()` resolves the stage thresholds, the
/// starvation HP loss and the stamina penalty. Runs after tickAll so the world
/// clock already advanced.
/// `Equipment.CalcDamage` (IL=83, combat-damage.md §2.1) non-physical leg:
/// stock queries `EffectManager.GetValue(43 ElementalDamageResist,
/// itemValue: null, entity: the victim, tags: damageTypeTag)`, so an armor row
/// tagged `heat,electrical` resists heat and electric but not cold, while the
/// untagged jitter rows resist every non-physical type. zdtd folds the same
/// rows the tick VM folds (equipped items, buffs, perks) on the damage event,
/// with the damage type as the ctx tag set. Returns the 0..1 fraction; the
/// caller scales `1 - fraction` like stock's
/// `FastMax(0, damage * (1 - value/100))`.
///
/// The ctx here is deliberately the event's own: it carries the live survival
/// state, class tags, clock and cvar/level ledger but not the tick fold's
/// equipment/sandbox snapshots, so a row gated on something only the tick fold
/// answers is refused (counted unsupported) rather than answered wrongly.
/// Every stock passive-43 row is requirement-free (only `tags`/`tier`), so the
/// fold is exact for stock data.
/// One item's tracked deltas: its own `<passive_effect>` rows plus each
/// installed mod's rows (`EffectManager.GetValue` layer 13: a modifier item's
/// effects apply alongside the item's own, at the mod's tier). Stock's
/// server-relevant modifier rows (armour resistances, max stats,
/// HealthChangeOT) are flat, so folding them on the item's quality axis is
/// exact; a tiered modifier row would need the mod's own quality, which the
/// wire ItemValue carries but zdtd does not store yet (recorded residual), so
/// those rows are approximated at the item's quality like the rest.
/// Attacker-side rows (`EntityDamage` and friends) are not consumed here: the
/// client's damage packet already carries the finished number.
fn itemTrackedDeltas(
    self: *Game,
    def: *const assets_items.ItemDef,
    mods: [4]u16,
    mod_qualities: [4]u8,
    quality: u8,
    ctx: requirements.Ctx,
    counts: *requirements.Counts,
) assets_buffs.TrackedDeltas {
    const axis = itemQualityAxis(self, quality);
    // ItemHasTags / RequirementItemTier / RequirementItemModTier read params.ItemValue.
    var item_ctx = ctx;
    item_ctx.item_tags = def.tags;
    item_ctx.item_quality = quality;
    var mod_buf: [4]requirements.NameLevel = undefined;
    item_ctx.item_mods = fillItemMods(self, mods, mod_qualities, &mod_buf);
    return assets_buffs.deltasPlus(
        assets_buffs.trackedDeltasAt(def.passives, axis, item_ctx, counts),
        modTrackedDeltas(self, mods, mod_qualities, quality, item_ctx, counts, null),
    );
}

/// Build the RequirementItemModTier ledger from installed mod ids + qualities.
pub fn fillItemMods(
    self: *const Game,
    mods: [4]u16,
    mod_qualities: [4]u8,
    buf: *[4]requirements.NameLevel,
) []const requirements.NameLevel {
    var n: usize = 0;
    for (mods, 0..) |mod_id, i| {
        if (mod_id == 0 or n >= buf.len) continue;
        const modef = self.items.byId(mod_id) orelse continue;
        const q = if (mod_qualities[i] == 0) @as(u8, 1) else mod_qualities[i];
        buf[n] = .{ .name = modef.name, .level = q };
        n += 1;
    }
    return buf[0..n];
}

/// The installed mods' rows alone (`EffectManager.GetValue` layer 13). The
/// mod-side PhysicalDamageResist is returned through `phys_out` when the caller
/// consumes it (the per-tick fold stores it for `armorMitigation`, since stock
/// `GetTotalPhysicalArmorRating` sums the worn items' effect layers); the
/// mod-side ElementalDamageResist is dropped because the tagged EDR query owns
/// it. A null `phys_out` keeps both in the returned deltas (the EDR caller).
fn modTrackedDeltas(
    self: *Game,
    mods: [4]u16,
    mod_qualities: [4]u8,
    quality: u8,
    ctx: requirements.Ctx,
    counts: *requirements.Counts,
    phys_out: ?*f32,
) assets_buffs.TrackedDeltas {
    const axis = itemQualityAxis(self, quality);
    var out: assets_buffs.TrackedDeltas = .{};
    for (mods, 0..) |mod_id, i| {
        if (mod_id == 0) continue;
        const modef = self.items.byId(mod_id) orelse continue;
        const md = self.item_mods.byName(modef.name) orelse continue;
        if (md.passives.len == 0) continue;
        // ItemHasTags / RequirementItemTier / RequirementItemModTier on mod
        // rows read the mod ItemValue (class tags + its own Quality).
        var mod_ctx = ctx;
        mod_ctx.item_tags = modef.tags;
        const mq = if (mod_qualities[i] == 0) @as(u8, 1) else mod_qualities[i];
        mod_ctx.item_quality = mq;
        const one = [_]requirements.NameLevel{.{ .name = modef.name, .level = mq }};
        mod_ctx.item_mods = &one;
        var m = assets_buffs.trackedDeltasAt(md.passives, axis, mod_ctx, counts);
        if (phys_out) |mp| {
            mp.* += m.phys_resist;
            m.phys_resist = 0;
            m.elem_resist = 0;
        }
        out = assets_buffs.deltasPlus(out, m);
    }
    return out;
}

fn itemQualityAxis(self: *const Game, quality: u8) assets_buffs.Axis {
    const qmax = self.items.max_quality_tier;
    return .{ .quality = .{ .level = @min(quality, qmax), .max = qmax } };
}

/// Fold buff+perk+held/equip item StaminaChangeOT for one query tag set
/// (`PassiveEffect::hasMatchingTag` IL=53). Sprint uses `"running"`; walk uses
/// `"walking"`. Untagged idle regen stays on the plain fold.
fn taggedStaminaOt(
    self: *Game,
    ps: ecs.Slot,
    skill_levels: []const assets_progression.SkillLevel,
    base_ctx: requirements.Ctx,
    tag: []const u8,
    stamina_max: f32,
    req_counts: *requirements.Counts,
) f32 {
    var ctx = base_ctx;
    ctx.tags = tag;
    const vm = assets_buffs.effectTotals(&self.buffs, &self.sim.buffs[ps], ctx, req_counts);
    const pvm = assets_progression.perkTotals(&self.progression_table, skill_levels, ctx, req_counts);
    var ivm: assets_buffs.TrackedDeltas = .{};
    {
        var item_ctx = ctx;
        const held = self.sim.inventory[ps].heldItem();
        if (held.count > 0) {
            item_ctx.item_equipped = false;
            item_ctx.item_active = (held.flags & 1) != 0;
            if (self.items.byId(held.item_id)) |def| {
                item_ctx.item_tags = def.tags;
                item_ctx.item_quality = held.quality;
                var held_mod_buf: [4]requirements.NameLevel = undefined;
                item_ctx.item_mods = fillItemMods(self, held.mods, held.mod_qualities, &held_mod_buf);
                ivm = assets_buffs.deltasPlus(ivm, assets_buffs.trackedDeltasAt(def.passives, itemQualityAxis(self, held.quality), item_ctx, req_counts));
            }
        }
        item_ctx.item_equipped = true;
        var esi: usize = ecs.components.inv_equip_start;
        while (esi < ecs.components.max_inv_slots) : (esi += 1) {
            const slot = self.sim.inventory[ps].slots[esi];
            if (slot.count == 0) continue;
            const def = self.items.byId(slot.item_id) orelse continue;
            item_ctx.item_tags = def.tags;
            item_ctx.item_quality = slot.quality;
            var slot_mod_buf: [4]requirements.NameLevel = undefined;
            item_ctx.item_mods = fillItemMods(self, slot.mods, slot.mod_qualities, &slot_mod_buf);
            item_ctx.item_active = (slot.flags & 1) != 0;
            ivm = assets_buffs.deltasPlus(ivm, assets_buffs.trackedDeltasAt(def.passives, itemQualityAxis(self, slot.quality), item_ctx, req_counts));
        }
    }
    return (vm.stamina_ot + pvm.stamina_ot + ivm.stamina_ot) * stamina_max / 100.0;
}

/// Sandbox float option read off decoded groups, stock default when the code
/// does not carry it (`UpdateSandboxOptions` IL=21 copies these into
/// `Stat.LossSandboxModifier` per stat; Food=161 HungerMultiplier,
/// Water=162 ThirstMultiplier).
fn sandboxFloat(groups: []const sandbox.Group, name: []const u8) f32 {
    const o = sandbox.optionByName(name) orelse return 1.0;
    const set = sandbox.findSet(o.set_name) orelse return o.default_f;
    for (groups) |g| {
        if (g.option_id != o.id) continue;
        return sandbox.valueF(o, set, g.index);
    }
    return o.default_f;
}

pub fn elementalDamageResist(self: *Game, ps: ecs.Slot, damage_tag: []const u8) f32 {
    if (damage_tag.len == 0) return 0;
    if (!self.sim.mask[ps].inventory or !self.sim.mask[ps].health) return 0;
    const h = &self.sim.health[ps];
    const peer_slot = self.sim.player[ps].peer_slot;
    const c: ?*Client = if (peer_slot >= 0 and @as(usize, @intCast(peer_slot)) < self.clients.len)
        &self.clients[@intCast(peer_slot)]
    else
        null;
    var pctx: PlayerCtx = .{};
    var counts: requirements.Counts = .{};
    var total: f32 = 0;
    if (c) |cc| {
        pctx.init(self, cc, ps);
        var sandbox_buf: [sandbox.max_groups]sandbox.Group = undefined;
        const sandbox_groups = sandbox_buf[0..sandbox.decode(self.sandbox_code, &sandbox_buf)];
        var ctx = pctx.build(self, cc, ps, h, sandbox_groups);
        // The tagged EDR query owns this fold: rows match the damage type's
        // tag, not the caller's tag set.
        ctx.tags = damage_tag;
        var i: usize = ecs.components.inv_equip_start;
        while (i < ecs.components.max_inv_slots) : (i += 1) {
            const slot = self.sim.inventory[ps].slots[i];
            if (slot.count == 0) continue;
            const def = self.items.byId(slot.item_id) orelse continue;
            total += itemTrackedDeltas(self, &def, slot.mods, slot.mod_qualities, slot.quality, ctx, &counts).elem_resist;
        }
        total += assets_buffs.effectTotals(&self.buffs, &self.sim.buffs[ps], ctx, &counts).elem_resist;
        total += assets_progression.perkTotals(&self.progression_table, ctx.levels, ctx, &counts).elem_resist;
    }
    self.harness.counters.add(.requirement_gates, counts.resolved);
    self.harness.counters.add(.requirement_unsupported, counts.unsupported);
    // Stock FastMax(0, ...) floors at zero and the fraction can exceed 1 only
    // with modded rows; clamp so the caller's `1 - fraction` cannot go negative.
    return std.math.clamp(total / 100.0, 0, 1);
}

/// Foreign-gated GeneralDamageResist at damage time: the victim's perk rows
/// whose gates name the attacker (`target="other"`, e.g. Spectral Grace's
/// zombie/animal filter) evaluate here, where the attacker is known. The
/// per-tick fold refuses those rows (no other in scope), so a passing row
/// lands only on this hit. Returns the resist fraction (Grace = 1).
/// `other_tags` overrides the attacker-slot lookup (the accumulator passes
/// the slot; the hook resolves tags itself, so this form is for callers that
/// already hold the tag string).
pub fn foreignGatedResist(self: *Game, victim: ecs.Slot, attacker: ecs.Slot) f32 {
    return foreignGatedResistTags(self, victim, entityClassTags(self, attacker) orelse "");
}

/// Tag-string form of foreignGatedResist: an empty tag string matches nothing
/// (refuses the foreign rows, like a missing other).
pub fn foreignGatedResistTags(self: *Game, victim: ecs.Slot, other_tags: []const u8) f32 {
    if (!self.sim.mask[victim].health) return 0;
    const h = &self.sim.health[victim];
    const peer_slot = self.sim.player[victim].peer_slot;
    const c: ?*Client = if (peer_slot >= 0 and @as(usize, @intCast(peer_slot)) < self.clients.len)
        &self.clients[@intCast(peer_slot)]
    else
        null;
    var pctx: PlayerCtx = .{};
    // Offline victim (no client): the perk ledger is empty, so only the
    // buff leg could contribute; build the ctx without client state.
    var counts: requirements.Counts = .{};
    if (c) |cc| {
        pctx.init(self, cc, victim);
        var sandbox_buf: [sandbox.max_groups]sandbox.Group = undefined;
        const sandbox_groups = sandbox_buf[0..sandbox.decode(self.sandbox_code, &sandbox_buf)];
        var ctx = pctx.build(self, cc, victim, h, sandbox_groups);
        ctx.other_tags = if (other_tags.len > 0) other_tags else null;
        const total = assets_progression.perkTotals(&self.progression_table, ctx.levels, ctx, &counts).general_resist;
        self.harness.counters.add(.requirement_gates, counts.resolved);
        self.harness.counters.add(.requirement_unsupported, counts.unsupported);
        return std.math.clamp(total, 0, 1);
    }
    return 0;
}

pub fn tickSurvival(self: *Game, dt: f32) void { // APM (P4b): the per-player effects pass (passive-effects VM + triggered
    // engine + stat application) is bounded by the client table; the section
    // timer + survival_players/vm_recomputes counters keep it inside the
    // 50 ms budget as player counts scale.
    const sc = apm.profiler.scope(&self.harness.prof, .survival);
    defer sc.end();
    const prog = self.sim.rules.progression;
    const sv = assets_buffs.survival(&self.buffs);
    const use_buff = sv.ok();
    // Zero depletion rates disable ONLY the two food/water decay writes. This
    // used to return early, which also skipped drowning, radiation, the
    // stamina/well-fed folds and the whole buff lifecycle (including the
    // player class buffs fired by onSelfEnteredGame) whenever a preset turned
    // survival decay off, e.g. presets/builder.toml.
    const decay_on = prog.food_depletion_per_hour > 0 or prog.water_depletion_per_hour > 0;
    const game_hours = self.sim.director.clock.hoursFor(dt);
    const secs = dt;
    // Sandbox gates: decode the server's code once per tick rather than per
    // requirement (SandboxOptionBool reads it through SandboxOptionManager).
    var sandbox_buf: [sandbox.max_groups]sandbox.Group = undefined;
    const sandbox_groups = sandbox_buf[0..sandbox.decode(self.sandbox_code, &sandbox_buf)];
    // Active def ids snapshotted for the lifecycle sweep (a row may add buffs).
    var life_buf: [ecs.components.max_buffs_per_entity]u16 = undefined;
    var life_ids_n: usize = 0;
    // The pre-branch's already-remove-evaluated ids, so the post-update remove
    // pass does not fire onSelfBuffRemove twice for a buff flagged earlier.
    var pre_remove_buf: [ecs.components.max_buffs_per_entity]u16 = undefined;
    var pre_remove_n: usize = 0;
    for (&self.clients) |*c| {
        if (!c.joined) continue;
        const ps = self.sim.playerByPeer(c.slot) orelse continue;
        if (!self.sim.mask[ps].health or !self.sim.mask[ps].transform) continue;
        var h = &self.sim.health[ps];
        if (h.max_hp <= 0) continue;
        // Deferred ModifyStats refunds (`delay=` kill rows) land here.
        drainPendingMods(self, c.slot, ps);
        // Combat-engagement timer decays; stock re-fires onCombatEntered only
        // after the idle window (combat_ticks reaches 0), then the next
        // damage re-enters combat.
        if (c.combat_remaining_ticks > 0) {
            c.combat_remaining_ticks -= 1;
        }
        self.harness.counters.inc(.survival_players);
        // engine + the two stat folds + the two coredamageresist armor folds
        if (use_buff) self.harness.counters.add(.vm_recomputes, 1 + vm_recomputes_per_player);
        // Drowning: stock drains the client's local O2 bar first, then the
        // server is authoritative for the hp loss. The head block being water
        // is the depth gate (a submerged body at y <= water surface).
        if (prog.drowning_damage_per_second > 0) {
            const water_id = self.world.terrain_ids.water;
            if (water_id != 0 and self.world.blockWorld(
                @trunc(self.sim.transform[ps].x),
                @as(i32, @trunc(self.sim.transform[ps].y)) + 1,
                @trunc(self.sim.transform[ps].z),
            ) catch 0 == water_id) {
                c.drown_accum += secs;
                if (c.drown_accum >= 1.0) {
                    // Wasm-first (AGENTS rule 29): environmental damage passes
                    // the on_player_damage verdict with attacker -1, so a
                    // module scales/denies drowning like any other player hit.
                    // GeneralDamageResist (passive 40) covers every damage type.
                    // This leg models stock's Internal self-damage (a client
                    // drown report carries damageSource 1), and
                    // DamageSource::AffectedByArmor (IL=5) keeps the armour
                    // branch - passive 41 and passive 43 alike - for External
                    // hits only, so no EDR term here.
                    const raw = prog.drowning_damage_per_second * c.drown_accum *
                        (1.0 - inventory.generalDamageResist(&self.sim, ps));
                    const dmg = game_mod.playerDamageVerdictAmount(self, -1, c.entity_id, raw);
                    if (dmg > 0) _ = self.sim.damageFrom(c.entity_id, dmg, -1);
                    c.drown_accum = 0;
                }
            } else {
                c.drown_accum = 0;
            }
        }
        // Radiation: stock BiomeType.Radiated (biomes.xml <biomemap
        // name="radiated"/>) deals damage while the player stands in it.
        if (prog.radiation_damage_per_second > 0) {
            if (self.isRadiatedAt(@trunc(self.sim.transform[ps].x), @trunc(self.sim.transform[ps].z))) {
                c.radiation_accum += secs;
                if (c.radiation_accum >= 1.0) {
                    // Wasm-first (AGENTS rule 29): verdict with attacker -1,
                    // like drowning above: GDR only, since this is Internal
                    // self-damage and the armour branch is External-only
                    // (DamageSource::AffectedByArmor IL=5).
                    const raw = prog.radiation_damage_per_second * c.radiation_accum *
                        (1.0 - inventory.generalDamageResist(&self.sim, ps));
                    const dmg = game_mod.playerDamageVerdictAmount(self, -1, c.entity_id, raw);
                    if (dmg > 0) _ = self.sim.damageFrom(c.entity_id, dmg, -1);
                    c.radiation_accum = 0;
                }
            } else {
                c.radiation_accum = 0;
            }
        }
        const food_was = h.food;
        const water_was = h.water;
        const max_hp_was = h.max_hp;
        const food_max_was = h.food_max;
        const water_max_was = h.water_max;
        const stamina_max_was = h.stamina_max;
        if (decay_on) {
            h.food = @max(0, h.food - prog.food_depletion_per_hour * game_hours);
            h.water = @max(0, h.water - prog.water_depletion_per_hour * game_hours);
        }
        // Well-fed regen and starvation: when buffs.xml is present the
        // thresholds are fractions of max (StatComparePercCurrentToMax); otherwise
        // fall back to Rules. The Rules well_fed_threshold is an absolute that
        // is still parsed for offline worlds, but with stock data the regen gate
        // uses sv.hungry_frac[0] / thirsty_frac[0] (T16).
        var hp_delta: f32 = 0;
        var stamina_penalty: f32 = 0;
        var stamina_ot_bonus: f32 = 0;
        // Movement-tagged StaminaChangeOT (`running` sprint / `walking` walk).
        var stamina_ot_running: f32 = 0;
        if (use_buff) {
            // Passive-effects VM (assets/buffs.zig): keep the matching
            // conditional stage buffs (buffStatusHungry/Thirsty01..03) in the
            // entity's BuffSet - the stage IS the starving/dehydrated state -
            // and drive the stamina penalty from the VM's StaminaChangeOT
            // total. Revertible: removing a stage buff recomputes the deltas
            // without it (additive deltas, recompute-from-set).
            //
            // Requirement-gate context (ADR 0023 §2): the shared PlayerCtx
            // builder, so the tick fold reads the same gates as the
            // finish/damage paths.
            var pctx: PlayerCtx = .{};
            pctx.init(self, c, ps);
            var req_ctx = pctx.build(self, c, ps, h, sandbox_groups);
            var req_counts: requirements.Counts = .{};
            // Buff lifecycle events, driven from the active set rather than by
            // id (stock fires them from AddBuff / the entered-game path /
            // RemoveBuff):
            //   onSelfEnteredGame  once per instance, when the player enters
            //   onSelfBuffStart    once per instance, right after it is added
            //   onSelfBuffRemove   when the buff is flagged for removal
            // Bounded: a snapshot of the active def ids, so a row that adds a
            // buff cannot re-enter this loop.
            if (!c.entered_game_fired) {
                c.entered_game_fired = true;
                // entityclasses `Buffs=`: the class-level buff list stock
                // applies to every instance as it enters the game (the player
                // class carries buffStatusCheck01/02). Data-bound: the class
                // comes from the same Unity hash the PlayerId wire carries.
                if (self.entities.byHash(assets_unity_hash.class_player_male)) |pdef| {
                    for (pdef.buffs) |bname| _ = addCatalogBuff(self, c.entity_id, ps, bname, c.entity_id);
                    // Player-class entered-game rows (carryCapacity base,
                    // hazard timer max seeds, hazard cleanup removes): same
                    // engine and ctx as the buff rows below.
                    if (pdef.triggered.len != 0) {
                        const ceg = assets_buffs.evaluateRows(pdef.triggered, .entered_game, req_ctx, &req_counts);
                        if (ceg.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, ceg.truncated);
                        applyTriggeredBuffs(self, c.entity_id, ps, &ceg, c.entity_id);
                    }
                }
                life_ids_n = activeBuffIds(&self.sim.buffs[ps], &life_buf).len;
                for (life_buf[0..life_ids_n]) |id| {
                    const slot = self.sim.buffs[ps].find(id) orelse continue;
                    if (slot.flags.entered_game_fired) continue;
                    slot.flags.entered_game_fired = true;
                    const eg = assets_buffs.evaluateTriggered(&self.buffs, id, .entered_game, req_ctx, &req_counts);
                    if (eg.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, eg.truncated);
                    applyTriggeredBuffs(self, c.entity_id, ps, &eg, c.entity_id);
                }
            }
            // onSelfBuffStart / onSelfBuffRemove for every active buff, now that
            // the engine applies add/remove requests as the rows pass (so a
            // stage's start rows see the other stages and the highest wins).
            life_ids_n = activeBuffIds(&self.sim.buffs[ps], &life_buf).len;
            for (life_buf[0..life_ids_n]) |id| {
                const slot = self.sim.buffs[ps].find(id) orelse continue;
                if (!slot.flags.start_fired) {
                    slot.flags.start_fired = true;
                    // Physician heal buffs: ProgressionLevel target=instigator
                    // reads the healer's perk ledger (BuffInstance.instigator_id).
                    req_ctx.instigator_levels = skillLevelsForEntity(self, slot.instigator_id);
                    const st = assets_buffs.evaluateTriggered(&self.buffs, id, .start, req_ctx, &req_counts);
                    req_ctx.instigator_levels = null;
                    if (st.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, st.truncated);
                    // `otherAOE` start rows (SledgeSaga cripple morale) fan out
                    // around the holder at start time.
                    applyTriggeredBuffsAoe(self, ps, &st, c.entity_id);
                    // `CallGameEvent` start rows (Dentist silver/gold grants)
                    // run through the sequence runner like other callers.
                    // Food/Water/Stamina deltas ride that shared applier
                    // (single-apply); Health adds still fold into hp_delta.
                    applyTriggeredBuffs(self, c.entity_id, ps, &st, c.entity_id);
                    // AddHealth (ModifyStats Health add) on onSelfBuffStart.
                    hp_delta += assets_buffs.healthAddDelta(&st);
                    // Immediate Health subtracts (infection04 kill blow,
                    // falling-damage impactSpeed). Stage-3 hunger/thirst rows
                    // never appear on start, so no per-second exclusion needed.
                    hp_delta -= assets_buffs.healthSubtractOnce(&st);
                    continue;
                }
                if (slot.flags.remove) {
                    pre_remove_buf[pre_remove_n] = id;
                    pre_remove_n +|= 1;
                    const rm = assets_buffs.evaluateTriggered(&self.buffs, id, .remove, req_ctx, &req_counts);
                    if (rm.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, rm.truncated);
                }
            }
            // onSelfBuffUpdate for every active buff, due on the buff's own
            // update rate (`<update_rate>` is seconds * 20 ticks; buff.tick
            // resets update_ticks on the due tick). A row's AddBuff/RemoveBuff
            // lands through the sink as it passes.
            life_ids_n = activeBuffIds(&self.sim.buffs[ps], &life_buf).len;
            for (life_buf[0..life_ids_n]) |id| {
                const slot = self.sim.buffs[ps].find(id) orelse continue;
                if (slot.flags.remove or slot.flags.paused) continue;
                if (!slot.flags.started or slot.update_ticks != 0) continue;
                // Physician heal buffs: ProgressionLevel target=instigator on update too.
                req_ctx.instigator_levels = skillLevelsForEntity(self, slot.instigator_id);
                const up = assets_buffs.evaluateTriggered(&self.buffs, id, .update, req_ctx, &req_counts);
                req_ctx.instigator_levels = null;
                if (up.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, up.truncated);
                // AddHealth (ModifyStats Health add) on onSelfBuffUpdate; subtract
                // rows stay on the stage3 per-second path below.
                hp_delta += assets_buffs.healthAddDelta(&up);
                // Immediate Food/Water update deltas (spoilt-meal drain).
                const fw_up = assets_buffs.foodWaterDelta(&up);
                h.food = @max(0, h.food + fw_up.food);
                h.water = @max(0, h.water + fw_up.water);
                if (fw_up.food_set) |v| h.food = @max(0, @min(h.food_max, v));
                if (fw_up.water_set) |v| h.water = @max(0, @min(h.water_max, v));
                // Immediate Stamina update deltas (radiation pool -20).
                const st_up = assets_buffs.staminaDelta(&up);
                h.stamina = @min(h.stamina_max, @max(0, h.stamina + st_up.delta));
                if (st_up.set) |v| h.stamina = @max(0, @min(h.stamina_max, v));
            }
            // onSelfBuffRemove rows for buffs a RemoveBuff action flagged in
            // the update pass just above: the pre-branch fired for pre-existing
            // flags, so the newly flagged (not in pre_remove_buf) get their
            // cleanup here, before the next tickAll reaps the slot.
            life_ids_n = activeBuffIds(&self.sim.buffs[ps], &life_buf).len;
            for (life_buf[0..life_ids_n]) |id| {
                const slot = self.sim.buffs[ps].find(id) orelse continue;
                if (!slot.flags.remove) continue;
                var seen = false;
                for (pre_remove_buf[0..pre_remove_n]) |pid| {
                    if (pid == id) {
                        seen = true;
                        break;
                    }
                }
                if (seen) continue;
                const rm = assets_buffs.evaluateTriggered(&self.buffs, id, .remove, req_ctx, &req_counts);
                if (rm.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, rm.truncated);
            }
            // Survival stage state: the thresholds decide which stage stays; the
            // engine's own rows brought them in above, so this only reaps.
            syncStageBuffs(self, ps, assets_buffs.survivalStages(sv, h));
            // Equip edges: worn-slot diff fires equip_start/stop rows (armor
            // set markers, boot fall-damage cvars, miner healing cvars).
            syncEquipMarkers(self, c, ps, req_ctx);
            // Two queries, like stock: the max-stat/change-over-time consumers
            // call EffectManager.GetValue with no tags, and
            // Equipment::GetTotalPhysicalArmorRating (IL=887) queries passive 41
            // with `coredamageresist`. A tagged row only joins the query whose
            // tag set carries its tag (PassiveEffect::hasMatchingTag IL=53), so
            // the `running`/`walking` StaminaChangeOT rows no longer land in the
            // idle aggregate.
            const vm = assets_buffs.effectTotals(&self.buffs, &self.sim.buffs[ps], req_ctx, &req_counts);
            // Perk leg (level-scaled): purchased attribute/perk/book passives
            // fold through the same VM surface, revertible by
            // recompute-from-set and gated per row by its requirements.
            const pvm = assets_progression.perkTotals(&self.progression_table, c.skill_levels[0..c.skill_level_n], req_ctx, &req_counts);
            const armor_ctx = blk: {
                var ctx_armor = req_ctx;
                ctx_armor.tags = armor_query_tags;
                break :blk ctx_armor;
            };
            const vm_armor = assets_buffs.effectTotals(&self.buffs, &self.sim.buffs[ps], armor_ctx, &req_counts);
            const pvm_armor = assets_progression.perkTotals(&self.progression_table, c.skill_levels[0..c.skill_level_n], armor_ctx, &req_counts);
            self.harness.counters.add(.requirement_gates, req_counts.resolved);
            self.harness.counters.add(.requirement_unsupported, req_counts.unsupported);
            // Armor: buff + perk PhysicalDamageResist join the mitigation like
            // stock GetTotalPhysicalArmorRating sums passive 41 on the wearer.
            // The attacking item's tags are per-hit and stay with `item_mit`.
            self.sim.buff_phys_resist[ps] = vm_armor.phys_resist + pvm_armor.phys_resist;
            // Equipped and held item passives (stock `EffectManager.GetValue`
            // layers 7/8: `Inventory.ModifyValue` for the holding item, then the
            // equipment `ModifyValue` pass). Each item's rows evaluate at its own
            // quality tier, with `Ctx.item_equipped` answering `IsEquipped`
            // (true for an equipment slot, false for the hand - `Equipment::
            // GetItems` does not include the holding slot).
            var ivm: assets_buffs.TrackedDeltas = .{};
            // NoiseMultiplier (passive 88) product over buffs, perks and worn
            // items. Stock `PlayerStealth.CalcVolume`/`NotifyNoise` multiply
            // the volume by `GetValue(88)` (base 1.0); no installed-mod rows
            // carry it, so only item-def rows fold here.
            var noise_mult: f32 = assets_buffs.namedBuffFold(&self.buffs, &self.sim.buffs[ps], "NoiseMultiplier", 1.0, req_ctx, &req_counts);
            noise_mult = assets_progression.namedPerkFold(&self.progression_table, c.skill_levels[0..c.skill_level_n], "NoiseMultiplier", noise_mult, req_ctx, &req_counts);
            // LightMultiplier (passive 89) product over the same three legs;
            // item-def rows chain in the worn/held loops below.
            var light_mult: f32 = assets_buffs.namedBuffFold(&self.buffs, &self.sim.buffs[ps], "LightMultiplier", 1.0, req_ctx, &req_counts);
            light_mult = assets_progression.namedPerkFold(&self.progression_table, c.skill_levels[0..c.skill_level_n], "LightMultiplier", light_mult, req_ctx, &req_counts);
            // LootStage (passive 159) product over the same three legs;
            // item-def rows (rogue helmet, scavenger set) chain below.
            var loot_mult: f32 = assets_buffs.namedBuffFold(&self.buffs, &self.sim.buffs[ps], "LootStage", 1.0, req_ctx, &req_counts);
            loot_mult = assets_progression.namedPerkFold(&self.progression_table, c.skill_levels[0..c.skill_level_n], "LootStage", loot_mult, req_ctx, &req_counts);
            {
                var item_ctx = req_ctx;
                var mod_phys: f32 = 0;
                const held = self.sim.inventory[ps].heldItem();
                if (held.count > 0) {
                    item_ctx.item_equipped = false;
                    item_ctx.item_active = (held.flags & 1) != 0;
                    if (self.items.byId(held.item_id)) |def| {
                        // ItemHasTags / RequirementItemTier / RequirementItemModTier
                        // read params.ItemValue (tags, quality, Modifications).
                        item_ctx.item_tags = def.tags;
                        item_ctx.item_quality = held.quality;
                        var held_mod_buf: [4]requirements.NameLevel = undefined;
                        item_ctx.item_mods = fillItemMods(self, held.mods, held.mod_qualities, &held_mod_buf);
                        ivm = assets_buffs.deltasPlus(ivm, assets_buffs.trackedDeltasAt(def.passives, itemQualityAxis(self, held.quality), item_ctx, &req_counts));
                        noise_mult = assets_buffs.namedPassiveFold("NoiseMultiplier", def.passives, itemQualityAxis(self, held.quality), item_ctx, noise_mult, &req_counts);
                        light_mult = assets_buffs.namedPassiveFold("LightMultiplier", def.passives, itemQualityAxis(self, held.quality), item_ctx, light_mult, &req_counts);
                        loot_mult = assets_buffs.namedPassiveFold("LootStage", def.passives, itemQualityAxis(self, held.quality), item_ctx, loot_mult, &req_counts);
                        // The holding item's mod rows fold for their stats, but
                        // its physical resist is not armour: stock
                        // GetTotalPhysicalArmorRating walks the Equipment slots
                        // only, so a held weapon's plating mod does not mitigate
                        // incoming hits. `null` keeps the value out of the
                        // armour column and `ivm.phys_resist` is zeroed below.
                        ivm = assets_buffs.deltasPlus(ivm, modTrackedDeltas(self, held.mods, held.mod_qualities, held.quality, item_ctx, &req_counts, null));
                    }
                }
                item_ctx.item_equipped = true;
                var esi: usize = ecs.components.inv_equip_start;
                while (esi < ecs.components.max_inv_slots) : (esi += 1) {
                    const slot = self.sim.inventory[ps].slots[esi];
                    if (slot.count == 0) continue;
                    const def = self.items.byId(slot.item_id) orelse continue;
                    item_ctx.item_tags = def.tags;
                    item_ctx.item_quality = slot.quality;
                    var slot_mod_buf: [4]requirements.NameLevel = undefined;
                    item_ctx.item_mods = fillItemMods(self, slot.mods, slot.mod_qualities, &slot_mod_buf);
                    item_ctx.item_active = (slot.flags & 1) != 0;
                    ivm = assets_buffs.deltasPlus(ivm, assets_buffs.trackedDeltasAt(def.passives, itemQualityAxis(self, slot.quality), item_ctx, &req_counts));
                    ivm = assets_buffs.deltasPlus(ivm, modTrackedDeltas(self, slot.mods, slot.mod_qualities, slot.quality, item_ctx, &req_counts, &mod_phys));
                    noise_mult = assets_buffs.namedPassiveFold("NoiseMultiplier", def.passives, itemQualityAxis(self, slot.quality), item_ctx, noise_mult, &req_counts);
                    light_mult = assets_buffs.namedPassiveFold("LightMultiplier", def.passives, itemQualityAxis(self, slot.quality), item_ctx, light_mult, &req_counts);
                    loot_mult = assets_buffs.namedPassiveFold("LootStage", def.passives, itemQualityAxis(self, slot.quality), item_ctx, loot_mult, &req_counts);
                }
                // The item's own resist rows stay owned by the items.xml
                // quality-curve path (`armor_pdr_fn` -> armorMitigation) and the
                // tagged EDR query, so folding them here too would double-count;
                // the mod side is consumed (mod_phys below, EDR in the event
                // fold), which is why the mod helper strips those two fields.
                ivm.phys_resist = 0;
                ivm.elem_resist = 0;
                self.sim.item_mod_phys_resist[ps] = mod_phys;
            }
            // GeneralDamageResist (passive 40) is read UNTAGGED at the damage
            // choke (EntityAlive::DamageEntity reads it with an empty tag set),
            // so it comes off the plain fold and joins every player hit. Items
            // contribute through the same cache (`armorEnforcerOutfit` +0.05).
            self.sim.buff_general_resist[ps] = vm.general_resist + pvm.general_resist + ivm.general_resist;
            // NoiseMultiplier cache for the stealth legs. Rules stays the
            // offline floor: without a game-dir the fold is the neutral base
            // and the Rules value wins; with data the fold scales it.
            self.sim.stealth_noise_mult[ps] = self.sim.rules.ai.stealth_noise_passive * noise_mult;
            // LightMultiplier cache for the sight legs. Stock blends it into
            // lightLevel as (0.32 + 0.68 x passive89); the rogue/assassin rows
            // additionally gate on `_lightlevel`, the pre-blend light x100
            // mirrored in the stealth broadcast. Rules scales the fold like
            // the noise column, so the operator tunable keeps working.
            self.sim.stealth_light_mult[ps] = self.sim.rules.ai.stealth_light_passive * light_mult;
            // LootStage (passive 159) cache for GetLootStage. Stock
            // multiplies the floored total by GetValue(159); base 1.0, so no
            // rows means no change.
            self.sim.loot_stage_mult[ps] = loot_mult;
            // Perk/buff/item max-stat deltas: unconditional recompute from the
            // bases every tick (revertible recompute-from-set - a zero delta
            // restores the spawn max; the values are stable so no churn).
            const mhp = vm.hp_max + pvm.hp_max + ivm.hp_max;
            // Injury caps (`HealthMaxBlockage` abrasion/sprain/break rows):
            // the folded cvar value is subtracted from the max, never added.
            const hblock = vm.hp_block + pvm.hp_block + ivm.hp_block;
            h.max_hp = @max(1, h.base_max_hp + mhp - hblock);
            if (h.hp > h.max_hp) {
                h.hp = h.max_hp;
                self.sim.markDirty(ps, .{ .hp = true });
            }
            const mfood = vm.food_max + pvm.food_max + ivm.food_max;
            h.food_max = @max(1, 100 + mfood);
            const mwater = vm.water_max + pvm.water_max + ivm.water_max;
            h.water_max = @max(1, 100 + mwater);
            const mstam = vm.stamina_max + pvm.stamina_max + ivm.stamina_max;
            const sblock = vm.stamina_block + pvm.stamina_block + ivm.stamina_block;
            h.stamina_max = @max(1, 100 + mstam - sblock);
            const stages = assets_buffs.survivalStages(sv, h);
            const starving = stages.hungry == 3;
            const dehydrated = stages.thirsty == 3;
            if (starving or dehydrated) {
                // HP-loss leg: stock is a triggered `ModifyStats Health
                // subtract` on the active stage-3 buff's update (not a
                // passive); the VM resolves the rate off the active stage.
                const per_s = assets_buffs.stage3HpLossPerSecond(&self.buffs, stages);
                if (per_s > 0) {
                    // Wasm-first (AGENTS rule 29): verdict with attacker -1,
                    // like drowning/radiation above. GDR covers it too.
                    const raw = per_s * secs * (1.0 - inventory.generalDamageResist(&self.sim, ps));
                    hp_delta -= game_mod.playerDamageVerdictAmount(self, -1, c.entity_id, raw);
                }
            } else if (sv.hungry_frac[0] > 0 and sv.thirsty_frac[0] > 0) {
                if (h.food >= sv.hungry_frac[0] * h.food_max and h.water >= sv.thirsty_frac[0] * h.water_max) {
                    hp_delta += prog.well_fed_regen_per_hour * game_hours;
                }
            } else if (h.food >= prog.well_fed_threshold and h.water >= prog.well_fed_threshold) {
                hp_delta += prog.well_fed_regen_per_hour * game_hours;
            }
            // Perk/buff/item HealthChangeOT (`UpdatePlayerHealthOT` IL=179):
            // the positive leg only regens below full HP and scales by water
            // fraction (regen = OT x water% x dt); the negative leg rides
            // DamageEntity per contributing buff instead. Composes with the
            // starvation/regen branches above.
            const hp_ot = vm.hp_ot + pvm.hp_ot + ivm.hp_ot;
            if (hp_ot > 0 and h.hp < h.max_hp and h.water_max > 0) {
                hp_delta += hp_ot * (h.water / h.water_max) * secs;
            } else if (hp_ot < 0) {
                hp_delta += hp_ot * secs;
            }
            // Food/Water ChangeOT (`UpdatePlayerFoodOT`/`UpdatePlayerWaterOT`
            // IL=71): EffectManager.GetValue(115/123) * dt joins Stat.regenAmount
            // then Stat.Tick adds it. A negative regen is scaled by
            // `Stat.LossSandboxModifier` (`UpdateSandboxOptions` IL=21 sets
            // Food=161 HungerMultiplier, Water=162 ThirstMultiplier). Compose
            // with the Rules depletion floor above.
            const food_ot = vm.food_ot + pvm.food_ot + ivm.food_ot;
            if (food_ot != 0) {
                const scale = if (food_ot < 0) sandboxFloat(sandbox_groups, "HungerMultiplier") else 1.0;
                h.food = @min(h.food_max, @max(0, h.food + food_ot * scale * secs));
            }
            const water_ot = vm.water_ot + pvm.water_ot + ivm.water_ot;
            if (water_ot != 0) {
                const scale = if (water_ot < 0) sandboxFloat(sandbox_groups, "ThirstMultiplier") else 1.0;
                h.water = @min(h.water_max, @max(0, h.water + water_ot * scale * secs));
            }
            // Stamina OT consumer (perk/buff/item StaminaChangeOT): the VM's
            // perc fraction of max per second joins the idle regen (stock
            // applies the buff's OT continuously; perkRuleOneCardio .1..3
            // adds a regen bonus, the stage-3 starvation buff drains while
            // idle too). The sprint branch keeps the stage-3 penalty.
            stamina_ot_bonus = (vm.stamina_ot + pvm.stamina_ot + ivm.stamina_ot) * h.stamina_max / 100.0;
            // Sprint/walk legs query tagged StaminaChangeOT
            // (`PassiveEffect::hasMatchingTag` IL=53): tagged rows stay out of
            // the idle aggregate above and land here.
            if (c.sprint_speed > 0) {
                stamina_ot_running = taggedStaminaOt(self, ps, c.skill_levels[0..c.skill_level_n], req_ctx, "running", h.stamina_max, &req_counts);
            } else if (c.move_tag == .walking) {
                stamina_ot_running = taggedStaminaOt(self, ps, c.skill_levels[0..c.skill_level_n], req_ctx, "walking", h.stamina_max, &req_counts);
            }
            // Stamina penalty: stock `StaminaChangeOT perc_subtract .1` on
            // buffStatusHungry03 while its stage holds. The gate moved from
            // "food/water <= 0" to "stage-3 buff active" (the stock 2%
            // threshold); the arithmetic is unchanged.
            if (c.sprint_speed > 0 and vm.stamina_ot != 0 and (stages.hungry == 3 or stages.thirsty == 3)) {
                stamina_penalty = @abs(vm.stamina_ot) * h.stamina_max / 100.0 * secs;
            }
        } else {
            // Offline/no-buff path: both stealth columns are the Rules
            // floors, so the legs read the operator tunables, not stale folds.
            // LootStage resets to neutral (no Rules knob exists for it).
            self.sim.stealth_noise_mult[ps] = self.sim.rules.ai.stealth_noise_passive;
            self.sim.stealth_light_mult[ps] = self.sim.rules.ai.stealth_light_passive;
            self.sim.loot_stage_mult[ps] = 1.0;
            if (h.food <= 0 or h.water <= 0) {
                // Wasm-first (AGENTS rule 29): verdict with attacker -1, like
                // drowning/radiation above. GDR covers it too.
                const raw = prog.starvation_damage_per_hour * game_hours *
                    (1.0 - inventory.generalDamageResist(&self.sim, ps));
                hp_delta -= game_mod.playerDamageVerdictAmount(self, -1, c.entity_id, raw);
            } else if (h.food >= prog.well_fed_threshold and h.water >= prog.well_fed_threshold) {
                hp_delta += prog.well_fed_regen_per_hour * game_hours;
            }
        }
        if (hp_delta != 0 and h.hp > 0) {
            h.hp = @min(h.max_hp, @max(0, h.hp + hp_delta));
            self.sim.markDirty(ps, .{ .hp = true });
        }
        const survival_changed = h.food != food_was or h.water != water_was or hp_delta != 0 or
            h.max_hp != max_hp_was or h.food_max != food_max_was or h.water_max != water_max_was or
            h.stamina_max != stamina_max_was;
        if (c.sprint_stale_cd > 0) {
            c.sprint_stale_cd -= dt;
            if (c.sprint_stale_cd <= 0) {
                c.sprint_speed = 0;
                // The movement tag lapses with the same report: a client that
                // stopped sending speeds stops claiming to be moving, so a
                // walking/running gate does not stay open on stale input.
                c.move_tag = .idle;
            }
        }
        const stamina_was = h.stamina;
        if (c.sprint_speed > 0) {
            if (stamina_penalty > 0) {
                // Stage-3 OT replaces the Rules floor; running-tagged OT still
                // joins (cardio bonus / armor run penalty).
                h.stamina = @max(0, h.stamina - stamina_penalty + stamina_ot_running * dt);
            } else {
                // Rules drain floor minus running-tagged StaminaChangeOT (perc
                // of max per second). Positive cardio OT slows the drain;
                // negative armor run OT deepens it.
                h.stamina = @max(0, h.stamina - (prog.stamina_drain_per_second - stamina_ot_running) * dt);
            }
        } else {
            // Clamp both ways like the sprint branch: a draining
            // StaminaChangeOT buff (stage-3 starvation, modded data) must not
            // drive stamina negative while idle. Walking-tagged OT
            // (armorFarmerHelmet -.0281, armor CVars) joins the regen total.
            // `UpdatePlayerStaminaOT` IL=139: the positive leg only regens
            // below full stamina and scales by max(water%, 0.2); the Rules
            // floor is the no-row GetValue, so it gates the same way.
            const stam_ot_total = prog.stamina_regen_per_second + stamina_ot_bonus + stamina_ot_running;
            if (stam_ot_total > 0 and h.stamina < h.stamina_max and h.water_max > 0) {
                const wfrac = @max(0.2, h.water / h.water_max);
                h.stamina = @max(0, @min(h.stamina_max, h.stamina + stam_ot_total * wfrac * dt));
            } else if (stam_ot_total < 0) {
                h.stamina = @max(0, @min(h.stamina_max, h.stamina + stam_ot_total * dt));
            }
        }
        const stamina_changed = h.stamina != stamina_was;
        // Stat-changed observer (ADR 0034): one bounded call per changed
        // player per tick - plugins react/announce; the sim stays authority.
        if (survival_changed or stamina_changed) {
            self.statChangedObserver(c.entity_id, @trunc(h.hp), @trunc(h.food), @trunc(h.water), @trunc(h.stamina), c.level, @intCast(@min(c.xp, std.math.maxInt(i32))));
        }
        if (survival_changed or stamina_changed) {
            if (c.survival_sync_cd <= 0) {
                c.survival_sync_cd = prog.survival_sync_seconds;
                if (c.peer) |peer| {
                    if (survival_changed) {
                        self.sendSurvivalStats(peer, c.entity_id, h.hp, h.max_hp, h.food, h.food_max, h.water, h.water_max) catch |err| {
                            self.harness.counters.inc(.net_send_errors);
                            const n = self.harness.counters.get(.net_send_errors);
                            if (n == 1 or n % 100 == 0) {
                                var ts: [19]u8 = undefined;
                                std.debug.print("zdtd: {s} send survival stats failed local_id={d} entity={d} n={d}: {s}\n", .{ clock.wallStamp(&ts), peer.local_id, c.entity_id, n, @errorName(err) });
                            }
                        };
                    }
                    if (stamina_changed) {
                        self.sendStaminaStats(peer, c.entity_id, h.stamina, h.stamina_max) catch |err| {
                            self.harness.counters.inc(.net_send_errors);
                            const n = self.harness.counters.get(.net_send_errors);
                            if (n == 1 or n % 100 == 0) {
                                var ts: [19]u8 = undefined;
                                std.debug.print("zdtd: {s} send stamina stats failed local_id={d} entity={d} n={d}: {s}\n", .{ clock.wallStamp(&ts), peer.local_id, c.entity_id, n, @errorName(err) });
                            }
                        };
                    }
                }
            } else {
                c.survival_sync_cd -= dt;
            }
        }
    }
    tickMobRegen(self, dt);
}

/// Mob health over time: zombies/animals with active buffs fold their
/// HealthChangeOT rows (radiated regen, burning DoTs) with the victim's own
/// cvar store answering `@name` values. Stock ticks these in Stat.Tick on
/// every EntityAlive; the player legs live above, this covers the rest.
/// Positive heals clamp to max; negative ride raw like the player OT leg.
/// Changed HP marks dirty so the replicate pass emits EntityStatChanged.
fn tickMobRegen(self: *Game, dt: f32) void {
    var req_counts: requirements.Counts = .{};
    var it = self.sim.alive_bits.iterator(.{});
    while (it.next()) |idx| {
        const i: ecs.Slot = @intCast(idx);
        if (self.sim.mask[i].player) continue;
        const kind = self.sim.kind[i];
        if (kind != .zombie and kind != .animal) continue;
        if (!self.sim.mask[i].buffs or !self.sim.mask[i].health) continue;
        const h = &self.sim.health[i];
        if (h.hp <= 0 or h.max_hp <= 0) continue;
        var ctx = requirements.Ctx{
            .alive = true,
            .hp_frac = @max(0, @min(h.hp / h.max_hp, 1)),
            .hp_max = h.max_hp,
        };
        ctx.cvars = self.sim.cvarsMut(i);
        // Mob buff update rows (radiated regen removes itself at >=80% HP):
        // players run these on each buff's update rate; mobs evaluate them
        // inline since no other mob system drives the update event. Removes
        // flag for the buff-tick reap; cvar writes land directly.
        var ids: [ecs.components.max_buffs_per_entity]u16 = undefined;
        var nn: usize = 0;
        for (&self.sim.buffs[i].slots) |*s| {
            if (!s.active or nn >= ids.len) continue;
            ids[nn] = s.def_id;
            nn += 1;
        }
        for (ids[0..nn]) |id| {
            const res = assets_buffs.evaluateTriggered(&self.buffs, id, .update, ctx, &req_counts);
            if (res.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, res.truncated);
            for (res.remove_buffs[0..res.remove_n]) |names| {
                var it2 = std.mem.splitScalar(u8, names, ',');
                while (it2.next()) |seg| {
                    const name = std.mem.trim(u8, seg, " \t");
                    if (name.len == 0) continue;
                    const rid = self.buffs.indexOfName(name) orelse continue;
                    _ = ecs.buff.remove(self.sim.buffsMut(i), rid);
                }
            }
        }
        const totals = assets_buffs.effectTotals(&self.buffs, &self.sim.buffs[i], ctx, &req_counts);
        if (totals.hp_ot == 0) continue;
        h.hp = @min(h.max_hp, @max(0, h.hp + totals.hp_ot * dt));
        self.sim.markDirty(i, .{ .hp = true });
    }
    self.harness.counters.add(.requirement_gates, req_counts.resolved);
    self.harness.counters.add(.requirement_unsupported, req_counts.unsupported);
}

test "per-slot look cache resets when the slot is recycled" {
    const gpa = std.testing.allocator;
    var g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_lookcache", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    const aid = g.sim.spawnZombie(5, 70, 5, 40).?;
    const s = g.sim.slotOfNetId(aid).?;
    // allocSlot picks the lowest free slot, so every slot below s is occupied
    // by init entities and stays occupied: after the destroy below, s is the
    // lowest free slot again and the next spawn reuses it.
    g.sim.zombie_ai[s].alert = true;
    g.sim.zombie_ai[s].has_spot = true;
    g.sim.zombie_ai[s].spot_x = 10;
    g.sim.zombie_ai[s].spot_z = 20;
    g.tickEntityLookAt();
    try std.testing.expect(g.entity_look_sent[s].sent);
    const old_gen = g.sim.network_id[s].gen;
    try std.testing.expectEqual(old_gen, g.entity_look_sent[s].gen);

    // Recycle the slot onto a new zombie whose first look target equals the
    // previous occupant's last-sent one. The stale entry must not gate the
    // new entity's look: the gen mismatch resets the cache, so the pass
    // re-sends and re-pins to the new generation.
    g.sim.destroy(s);
    g.sim.beginTick();
    const bid = g.sim.spawnZombie(5, 70, 5, 40).?;
    const s2 = g.sim.slotOfNetId(bid).?;
    try std.testing.expectEqual(s, s2);
    g.sim.zombie_ai[s2].alert = true;
    g.sim.zombie_ai[s2].has_spot = true;
    g.sim.zombie_ai[s2].spot_x = 10;
    g.sim.zombie_ai[s2].spot_z = 20;
    g.tickEntityLookAt();
    try std.testing.expectEqual(old_gen + 1, g.entity_look_sent[s2].gen);
    try std.testing.expect(g.entity_look_sent[s2].sent);
}
