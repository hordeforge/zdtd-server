//! Tick orchestration - extracted from game.zig; helpers take *Game.
//! Bodies are verbatim copies from src/server/game.zig (stock asm.il comments kept).
//! game.zig is not edited in this extraction - it retains its own methods as
//! forwarding wrappers will be added by the main swarm step.

const std = @import("std");
const apm = @import("../../apm/root.zig");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const packages = @import("../../wire/packages.zig");
const world_store = @import("../../world/store.zig");
const ecs = @import("../../ecs/root.zig");
const assets_buffs = @import("../../assets/buffs.zig");
const assets_unity_hash = @import("../../assets/unity_hash.zig");
const assets_progression = @import("../../assets/progression.zig");
const requirements = @import("../../assets/requirements.zig");
const sandbox = @import("../../assets/sandbox.zig");
const clock = @import("../../util/clock.zig");
const persist = @import("../persist.zig");
const admin_cmds = @import("../admin_cmds.zig");
const admin_xml = @import("../admin_xml.zig");
const game_social = @import("social.zig");
const io_fs = @import("../../util/io_fs.zig");
const inventory = @import("../../ecs/inventory.zig");
const assets_items = @import("../../assets/items.zig");
const protocol = @import("../../protocol.zig");

/// Requirement-gate bridge: `HasBuff` resolves names through the loaded buffs
/// table (`EntityBuffs::HasBuff` is case-insensitive). Living here keeps
/// `assets/requirements.zig` free of a dependency on the buffs asset module,
/// which imports it for `Passive.reqs`.
const BuffNameLookup = struct {
    table: *const assets_buffs.Table,

    fn resolve(ctx: *const anyopaque, name: []const u8) ?u16 {
        const self: *const BuffNameLookup = @ptrCast(@alignCast(ctx));
        return self.table.indexOfName(name);
    }
};

/// The tag `Equipment::GetTotalPhysicalArmorRating` (IL=887) adds to its
/// passive-41 query; the attacking item's own tags ride the per-hit path.
const armor_query_tags = "coredamageresist";

/// The stock base max for Food/Water/Stamina (`EntityStats` seeds all three to
/// 100 and the VM folds its `*Max` deltas onto that base). Named so the
/// StatCompare gates' `Stat::Max` operand and the max recompute below cannot
/// drift apart.
const base_consumable_stat_max: f32 = 100;

/// The entity's own class `Tags` for `EntityTagCompare` (entityclasses.xml
/// `Tags` resolved through `extends`). The slot's class hash is the same one
/// the PlayerId wire carries; a slot without a class falls back to the player
/// class. Null = no catalog carries the class, which the gate refuses
/// (fail closed, counted) rather than silently treating the entity as
/// untagged.
fn entityClassTags(self: *Game, ps: ecs.Slot) ?[]const u8 {
    const hash = if (self.sim.class_id[ps].hash != 0)
        self.sim.class_id[ps].hash
    else
        assets_unity_hash.class_player_male;
    const def = self.entities.byHash(hash) orelse return null;
    return def.tags;
}

/// Add and remove the catalog buffs a triggered row asked for, relaying each
/// change to observers (the same contract as syncStageBuffs). Bounded by the
/// result's fixed arrays; an unknown name is skipped (fail closed).
fn applyTriggeredBuffs(self: *Game, entity_id: i32, ps: ecs.Slot, res: *const assets_buffs.TriggeredResult) void {
    for (res.remove_buffs[0..res.remove_n]) |name| {
        const def_id = self.buffs.indexOfName(name) orelse continue;
        const set = self.sim.buffsMut(ps);
        // Flag only: the buff tick reaps it next tick and the expiry drain
        // relays the removal once (relaying here too would send the stock
        // client a second NetPackageAddRemoveBuff for the same buff).
        _ = ecs.buff.remove(set, def_id);
    }
    for (res.add_buffs[0..res.add_n]) |name| {
        _ = addCatalogBuff(self, entity_id, ps, name);
    }
}

/// The live half of the triggered engine: applies a row's AddBuff/RemoveBuff as
/// the row passes and answers HasBuff against the current set, so a later row's
/// gate sees an earlier row's add (stock's ordering).
const BuffSink = struct {
    game: *Game,
    entity_id: i32,
    ps: ecs.Slot,

    fn add(ctx: *const anyopaque, name: []const u8) void {
        const s: *const BuffSink = @ptrCast(@alignCast(ctx));
        _ = addCatalogBuff(s.game, s.entity_id, s.ps, name);
    }

    fn remove(ctx: *const anyopaque, name: []const u8) void {
        const s: *const BuffSink = @ptrCast(@alignCast(ctx));
        const def_id = s.game.buffs.indexOfName(name) orelse return;
        _ = ecs.buff.remove(s.game.sim.buffsMut(s.ps), def_id);
    }

    fn has(ctx: *const anyopaque, name: []const u8) bool {
        const s: *const BuffSink = @ptrCast(@alignCast(ctx));
        const def_id = s.game.buffs.indexOfName(name) orelse return false;
        return s.game.sim.buffs[s.ps].find(def_id) != null;
    }
};

/// Add one catalog buff to the entity's set unless it is already active, and
/// relay the add. Returns whether it was added. Unknown names are skipped (fail
/// closed), like every other data-bound lookup.
/// Add a buff by catalog name to a player's sim slot and relay it (the loot
/// `buffs=` sink and the class-buff path share this).
pub fn addCatalogBuff(self: *Game, entity_id: i32, ps: ecs.Slot, name: []const u8) bool {
    const def_id = self.buffs.indexOfName(name) orelse return false;
    const def = self.buffs.byId(def_id) orelse return false;
    const set = self.sim.buffsMut(ps);
    if (set.find(def_id) != null) return false;
    _ = ecs.buff.add(set, .{
        .def_id = def_id,
        .duration = def.duration,
        .stack_type = def.stack_type,
        .update_rate_ticks = def.update_rate_ticks,
        .remove_on_death = def.remove_on_death,
    }, ecs.buff.duration_from_class, -1, 0, 0, 0);
    game_social.relayBuff(self, entity_id, def.name, true, -1, null) catch {};
    return true;
}

/// One entry per worn equipment item: its `Tags` property (comma list), the
/// input `WornItems` (IL=54) counts. Empty tags are kept as an empty entry so
/// the slot count matches `Equipment::GetSlotCount` semantics, but no tag can
/// match it.
fn wornItemTags(self: *const Game, ps: ecs.Slot, out: *[ecs.components.inv_equip_count][]const u8) []const []const u8 {
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
fn armorGroups(self: *const Game, ps: ecs.Slot, out: []requirements.ArmorGroup) []const requirements.ArmorGroup {
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

/// The held item's `Tags` property, or "" for an empty hand.
/// `HoldingItemHasTags::IsValid` (IL=37) reads
/// `Inventory.get_holdingItem().HasAnyTags/HasAllTags`, and an empty hand
/// matches no tag.
fn heldItemTags(self: *const Game, ps: ecs.Slot) []const u8 {
    if (!self.sim.mask[ps].inventory) return "";
    const inv = &self.sim.inventory[ps];
    if (inv.holding >= ecs.components.inv_toolbelt) return "";
    const s = inv.slots[inv.holding];
    if (s.count == 0 or s.item_id == 0) return "";
    const def = self.items.byId(s.item_id) orelse return "";
    return def.tags;
}

/// Passive-effects VM recomputes per player per tick: the untagged stats query
/// and the `coredamageresist` armor query, each over the buff and perk legs.
const vm_recomputes_per_player = 4;

/// Active buff def ids in `set`, into `out`; returns the used prefix. Bounded
/// by the fixed `BuffSet` slot count, so no allocation.
fn activeBuffIds(set: *const ecs.components.BuffSet, out: []u16) []const u16 {
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
    quality: u8,
    ctx: requirements.Ctx,
    counts: *requirements.Counts,
) assets_buffs.TrackedDeltas {
    const axis = itemQualityAxis(quality);
    return assets_buffs.deltasPlus(
        assets_buffs.trackedDeltasAt(def.passives, axis, ctx, counts),
        modTrackedDeltas(self, mods, quality, ctx, counts, null),
    );
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
    quality: u8,
    ctx: requirements.Ctx,
    counts: *requirements.Counts,
    phys_out: ?*f32,
) assets_buffs.TrackedDeltas {
    const axis = itemQualityAxis(quality);
    var out: assets_buffs.TrackedDeltas = .{};
    for (mods) |mod_id| {
        if (mod_id == 0) continue;
        const modef = self.items.byId(mod_id) orelse continue;
        const md = self.item_mods.byName(modef.name) orelse continue;
        if (md.passives.len == 0) continue;
        var m = assets_buffs.trackedDeltasAt(md.passives, axis, ctx, counts);
        if (phys_out) |mp| {
            mp.* += m.phys_resist;
            m.phys_resist = 0;
            m.elem_resist = 0;
        }
        out = assets_buffs.deltasPlus(out, m);
    }
    return out;
}

fn itemQualityAxis(quality: u8) assets_buffs.Axis {
    const qmax: u8 = ecs.components.max_quality_tiers;
    return .{ .quality = .{ .level = @min(quality, qmax), .max = qmax } };
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
    var buff_ids: [ecs.components.max_buffs_per_entity]u16 = undefined;
    const buff_lookup = BuffNameLookup{ .table = &self.buffs };
    const buff_names = requirements.BuffNames{ .ctx = &buff_lookup, .resolve = BuffNameLookup.resolve };
    const ctx = requirements.Ctx{
        .tags = damage_tag,
        .levels = if (c) |cc| cc.skill_levels[0..cc.skill_level_n] else &.{},
        .player_level = if (c) |cc| cc.level else 0,
        .alive = self.sim.alive[ps],
        .cvars = if (c) |cc| &cc.cvars else null,
        .active_buffs = activeBuffIds(&self.sim.buffs[ps], &buff_ids),
        .buff_names = &buff_names,
        .is_night = self.sim.director.clock.isNight(),
        .entity_tags = entityClassTags(self, ps),
        .hp_frac = if (h.max_hp > 0) h.hp / h.max_hp else 0,
        .hp_max = h.max_hp,
        .hp_base_max = h.base_max_hp,
        .stamina_frac = if (h.stamina_max > 0) h.stamina / h.stamina_max else 0,
        .stamina_max = h.stamina_max,
        .stamina_base_max = base_consumable_stat_max,
        .food_frac = if (h.food_max > 0) h.food / h.food_max else 0,
        .food_max = h.food_max,
        .food_base_max = base_consumable_stat_max,
        .water_frac = if (h.water_max > 0) h.water / h.water_max else 0,
        .water_max = h.water_max,
        .water_base_max = base_consumable_stat_max,
    };
    var counts: requirements.Counts = .{};
    var total: f32 = 0;
    var i: usize = ecs.components.inv_equip_start;
    while (i < ecs.components.max_inv_slots) : (i += 1) {
        const slot = self.sim.inventory[ps].slots[i];
        if (slot.count == 0) continue;
        const def = self.items.byId(slot.item_id) orelse continue;
        total += itemTrackedDeltas(self, &def, slot.mods, slot.quality, ctx, &counts).elem_resist;
    }
    total += assets_buffs.effectTotals(&self.buffs, &self.sim.buffs[ps], ctx, &counts).elem_resist;
    total += assets_progression.perkTotals(&self.progression_table, ctx.levels, ctx, &counts).elem_resist;
    self.harness.counters.add(.requirement_gates, counts.resolved);
    self.harness.counters.add(.requirement_unsupported, counts.unsupported);
    // Stock FastMax(0, ...) floors at zero and the fraction can exceed 1 only
    // with modded rows; clamp so the caller's `1 - fraction` cannot go negative.
    return std.math.clamp(total / 100.0, 0, 1);
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
    // Worn armor groups for the ArmorGroupLowestQuality gate; stock caps this
    // at one entry per worn item (12 equipment slots, one group name each).
    var armor_group_buf: [ecs.components.inv_equip_count * 2]requirements.ArmorGroup = undefined;
    // One Tags string per worn equipment item, for WornItems (IL=54).
    var worn_tags_buf: [ecs.components.inv_equip_count][]const u8 = undefined;
    // Active def ids snapshotted for the lifecycle sweep (a row may add buffs).
    var life_buf: [ecs.components.max_buffs_per_entity]u16 = undefined;
    var life_ids_n: usize = 0;
    for (&self.clients) |*c| {
        if (!c.joined) continue;
        const ps = self.sim.playerByPeer(c.slot) orelse continue;
        if (!self.sim.mask[ps].health or !self.sim.mask[ps].transform) continue;
        var h = &self.sim.health[ps];
        if (h.max_hp <= 0) continue;
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
        if (use_buff) {
            // Passive-effects VM (assets/buffs.zig): keep the matching
            // conditional stage buffs (buffStatusHungry/Thirsty01..03) in the
            // entity's BuffSet - the stage IS the starving/dehydrated state -
            // and drive the stamina penalty from the VM's StaminaChangeOT
            // total. Revertible: removing a stage buff recomputes the deltas
            // without it (additive deltas, recompute-from-set).
            //
            // Requirement-gate context (ADR 0023 §2): the live player state a
            // `<requirement>` reads. `attached_to_entity` stays false because
            // the sim tracks no vehicle/attachment state yet.
            var buff_ids: [ecs.components.max_buffs_per_entity]u16 = undefined;
            const buff_lookup = BuffNameLookup{ .table = &self.buffs };
            const buff_names = requirements.BuffNames{ .ctx = &buff_lookup, .resolve = BuffNameLookup.resolve };
            var sink_impl = BuffSink{ .game = self, .entity_id = c.entity_id, .ps = ps };
            const req_ctx = requirements.Ctx{
                .levels = c.skill_levels[0..c.skill_level_n],
                .player_level = c.level,
                .alive = self.sim.alive[ps],
                .biome_id = self.biomeIdAt(@trunc(self.sim.transform[ps].x), @trunc(self.sim.transform[ps].z)),
                .active_buffs = activeBuffIds(&self.sim.buffs[ps], &buff_ids),
                .buff_names = &buff_names,
                .held_tags = heldItemTags(self, ps),
                .sandbox_groups = sandbox_groups,
                .armor_groups = armorGroups(self, ps, &armor_group_buf),
                .cvars = &c.cvars,
                // The armour rating the previous tick's coredamageresist fold
                // produced (see requirements.Ctx.armor_rating).
                .armor_rating = self.sim.buff_phys_resist[ps],
                .live_buff = &sink_impl,
                .buff_active = BuffSink.has,
                .sink = .{ .ctx = &sink_impl, .add_buff = BuffSink.add, .remove_buff = BuffSink.remove },
                .worn_items = wornItemTags(self, ps, &worn_tags_buf),
                .hp_frac = if (h.max_hp > 0) h.hp / h.max_hp else 0,
                .hp_max = h.max_hp,
                // `Stat::Max` is the pre-modifier base (`base_max_hp`); the VM
                // recomputes the modified max one line below every tick.
                .hp_base_max = h.base_max_hp,
                .stamina_frac = if (h.stamina_max > 0) h.stamina / h.stamina_max else 0,
                .stamina_max = h.stamina_max,
                .stamina_base_max = base_consumable_stat_max,
                .food_frac = if (h.food_max > 0) h.food / h.food_max else 0,
                .food_max = h.food_max,
                .food_base_max = base_consumable_stat_max,
                .water_frac = if (h.water_max > 0) h.water / h.water_max else 0,
                .water_max = h.water_max,
                .water_base_max = base_consumable_stat_max,
                // The sim clock's own day/night split (`World.IsDaytime`).
                .is_night = self.sim.director.clock.isNight(),
                // The entity's class Tags (`entityclasses.xml`), read by
                // EntityTagCompare for the default self target.
                .entity_tags = entityClassTags(self, ps),
                // CurrentMovementTag (`EntityHasMovementTag`): the client's
                // reported movement state folded to idle/walking/running.
                .movement_tags = c.move_tag.name(),
            };
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
                    for (pdef.buffs) |bname| _ = addCatalogBuff(self, c.entity_id, ps, bname);
                }
                life_ids_n = activeBuffIds(&self.sim.buffs[ps], &life_buf).len;
                for (life_buf[0..life_ids_n]) |id| {
                    const slot = self.sim.buffs[ps].find(id) orelse continue;
                    if (slot.flags.entered_game_fired) continue;
                    slot.flags.entered_game_fired = true;
                    const eg = assets_buffs.evaluateTriggered(&self.buffs, id, .entered_game, req_ctx, &req_counts);
                    if (eg.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, eg.truncated);
                    applyTriggeredBuffs(self, c.entity_id, ps, &eg);
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
                    const st = assets_buffs.evaluateTriggered(&self.buffs, id, .start, req_ctx, &req_counts);
                    if (st.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, st.truncated);
                    continue;
                }
                if (slot.flags.remove) {
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
                const up = assets_buffs.evaluateTriggered(&self.buffs, id, .update, req_ctx, &req_counts);
                if (up.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, up.truncated);
            }
            // Survival stage state: the thresholds decide which stage stays; the
            // engine's own rows brought them in above, so this only reaps.
            syncStageBuffs(self, c.entity_id, ps, assets_buffs.survivalStages(sv, h));
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
            {
                var item_ctx = req_ctx;
                var mod_phys: f32 = 0;
                const held = self.sim.inventory[ps].heldItem();
                if (held.count > 0) {
                    item_ctx.item_equipped = false;
                    if (self.items.byId(held.item_id)) |def| {
                        ivm = assets_buffs.deltasPlus(ivm, assets_buffs.trackedDeltasAt(def.passives, itemQualityAxis(held.quality), item_ctx, &req_counts));
                        // The holding item's mod rows fold for their stats, but
                        // its physical resist is not armour: stock
                        // GetTotalPhysicalArmorRating walks the Equipment slots
                        // only, so a held weapon's plating mod does not mitigate
                        // incoming hits. `null` keeps the value out of the
                        // armour column and `ivm.phys_resist` is zeroed below.
                        ivm = assets_buffs.deltasPlus(ivm, modTrackedDeltas(self, held.mods, held.quality, item_ctx, &req_counts, null));
                    }
                }
                item_ctx.item_equipped = true;
                var esi: usize = ecs.components.inv_equip_start;
                while (esi < ecs.components.max_inv_slots) : (esi += 1) {
                    const slot = self.sim.inventory[ps].slots[esi];
                    if (slot.count == 0) continue;
                    const def = self.items.byId(slot.item_id) orelse continue;
                    ivm = assets_buffs.deltasPlus(ivm, assets_buffs.trackedDeltasAt(def.passives, itemQualityAxis(slot.quality), item_ctx, &req_counts));
                    ivm = assets_buffs.deltasPlus(ivm, modTrackedDeltas(self, slot.mods, slot.quality, item_ctx, &req_counts, &mod_phys));
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
            // Perk/buff/item max-stat deltas: unconditional recompute from the
            // bases every tick (revertible recompute-from-set - a zero delta
            // restores the spawn max; the values are stable so no churn).
            const mhp = vm.hp_max + pvm.hp_max + ivm.hp_max;
            h.max_hp = @max(1, h.base_max_hp + mhp);
            if (h.hp > h.max_hp) {
                h.hp = h.max_hp;
                self.sim.markDirty(ps, .{ .hp = true });
            }
            const mfood = vm.food_max + pvm.food_max + ivm.food_max;
            h.food_max = @max(1, 100 + mfood);
            const mwater = vm.water_max + pvm.water_max + ivm.water_max;
            h.water_max = @max(1, 100 + mwater);
            const mstam = vm.stamina_max + pvm.stamina_max + ivm.stamina_max;
            h.stamina_max = @max(1, 100 + mstam);
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
            // Perk/buff/item HealthChangeOT: stock applies the OT rate per second
            // (perkHealingFactor .011..16, well-rested regen), composing with
            // the starvation/regen branches above.
            const hp_ot = vm.hp_ot + pvm.hp_ot + ivm.hp_ot;
            if (hp_ot != 0) hp_delta += hp_ot * secs;
            // Stamina OT consumer (perk/buff/item StaminaChangeOT): the VM's
            // perc fraction of max per second joins the idle regen (stock
            // applies the buff's OT continuously; perkRuleOneCardio .1..3
            // adds a regen bonus, the stage-3 starvation buff drains while
            // idle too). The sprint branch keeps the stage-3 penalty.
            stamina_ot_bonus = (vm.stamina_ot + pvm.stamina_ot + ivm.stamina_ot) * h.stamina_max / 100.0;
            // Stamina penalty: stock `StaminaChangeOT perc_subtract .1` on
            // buffStatusHungry03 while its stage holds. The gate moved from
            // "food/water <= 0" to "stage-3 buff active" (the stock 2%
            // threshold); the arithmetic is unchanged.
            if (c.sprint_speed > 0 and vm.stamina_ot != 0 and (stages.hungry == 3 or stages.thirsty == 3)) {
                stamina_penalty = @abs(vm.stamina_ot) * h.stamina_max / 100.0 * secs;
            }
        } else {
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
                h.stamina = @max(0, h.stamina - stamina_penalty);
            } else {
                h.stamina = @max(0, h.stamina - prog.stamina_drain_per_second * dt);
            }
        } else {
            // Clamp both ways like the sprint branch: a draining
            // StaminaChangeOT buff (stage-3 starvation, modded data) must not
            // drive stamina negative while idle.
            h.stamina = @max(0, @min(h.stamina_max, h.stamina + (prog.stamina_regen_per_second + stamina_ot_bonus) * dt));
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
}

/// Keep the conditional survival stage buffs (buffStatusHungry/Thirsty01..03)
/// in the entity's BuffSet matching the resolved stages, relaying adds so the
/// stock client shows the same HUD state. Revertible: a stage change removes
/// the stale buff (flagged; the buff tick relays the removal) and the VM
/// recomputes its deltas without it. No-op when the stages already match.
fn syncStageBuffs(self: *Game, entity_id: i32, ps: ecs.Slot, keep: assets_buffs.SurvivalStages) void {
    _ = entity_id;
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

/// Current whole world-hour (day*24 + hour), for time-based scheduling.
/// Power consumer actuation (RE tile-entities-power.md PowerConsumer
/// HandlePowerUpdate → `Block.ActivateBlock(world, pos, bv, IsPowered, ...)`):
/// a powered door block opens while its circuit delivers power and closes when
/// the power drops (load shed, fuel out, switch off). Uses the same open/close
/// meta bit + SetBlock broadcast as the zombie door-open path (tickZombieBlockDamage);
/// the per-node `net_powered` flip (previously never written) drives the
/// one-shot so a settled circuit does not re-broadcast every tick. The
/// powered-state echo for other consumer kinds (lights, traps) stays recorded
/// in GAP 4693.
pub fn actuatePoweredDoors(self: *Game) void {
    const grid = &self.sim.power;
    var i: usize = 0;
    while (i < grid.node_n) : (i += 1) {
        const n = &grid.nodes[i];
        if (n.kind != .consumer) continue;
        if (n.powered == n.net_powered) continue;
        n.net_powered = n.powered;
        const id = self.blockIdAtWorld(n.x, n.y, n.z);
        const def = self.blocks.byId(id) orelse continue;
        if (!def.is_door) continue;
        // A 2-tall door spans two cells; the vertical partner gets the same
        // open bit (the consumer node may sit on either half).
        const door_dys = [_]i32{ 0, 1, -1 };
        for (door_dys) |dy| {
            const yy = n.y + dy;
            if (self.blockIdAtWorld(n.x, yy, n.z) != id) continue;
            const raw = self.world.rawWorld(n.x, yy, n.z) catch continue;
            const open = (packages.blockMeta(raw) & packages.block_meta_on) != 0;
            if (open == n.powered) continue;
            const new_raw = packages.withBlockMeta(raw, if (n.powered) packages.block_meta_on else 0);
            self.world.setBlockRawWorld(n.x, yy, n.z, new_raw) catch continue;
            if (packages.buildSetBlockBodyRaw(self.body_buf[0..96], n.x, yy, n.z, new_raw, 0, -1, -1)) |sb| {
                self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(n.x), @floatFromInt(n.z), self.interest_range) catch {};
            } else |_| {}
        }
    }
}

pub fn worldHour(self: *const Game) u64 {
    const clk = self.sim.director.clock;
    return @as(u64, clk.day) * 24 + @as(u64, @trunc(clk.hours));
}

/// Next scheduled airdrop as a world-hour. "interval" (default): every
/// `AirDropFrequency` game-hours from the last drop (the pre-config behavior).
/// "days" (`[sim] airdrop_schedule = "days"`): the stock-like day-count + TOD
/// schedule - `SandboxOptions.SetupAirDropTimeRanges` (IL=124) maps options
/// 52/54 to Min/MaxDayCount + Min/MaxTimeOfDay (default 3/3 days, 12:00), and
/// `calcNextAirdrop` (IL=39) picks `day + RandomRange(Min, Max+1) - 1` at that
/// TOD; zdtd replays that deterministically (same seed → same schedule) by
/// scheduling at day_min + k*(day_max - day_min + 1) days at the drop hour.
pub fn nextAirdropHour(self: *const Game, now: u64) u64 {
    if (self.airdrop_schedule == .days) {
        const span: u64 = @max(1, @as(u64, self.airdrop_day_max) -| self.airdrop_day_min + 1);
        const start: u64 = @as(u64, self.airdrop_day_min) * 24 + self.airdrop_drop_hour;
        if (now < start) return start;
        return start + ((now - start) / (span * 24) + 1) * (span * 24);
    }
    return now + self.air_drop_interval_hours;
}

/// AirDropFrequency: spawn a supply crate near a player every N game-hours.
/// DIVERGENCE (RE: aidirector.md airdrop schedule): stock schedules by
/// DAY-COUNT + fixed time-of-day - see nextAirdropHour above; `[sim]
/// airdrop_schedule = "days"` restores that. Also: stock AirDropFrequency=0
/// does NOT disable (the sandbox option default overrides the 0 pref; live
/// getgamestat reads 3); zdtd's 0 = off is a deliberate policy difference.
pub fn tickAirDrop(self: *Game) void {
    const enabled = if (self.airdrop_schedule == .days)
        self.airdrop_day_max > 0
    else
        self.air_drop_interval_hours > 0;
    if (!enabled) return;
    const now = self.worldHour();
    if (self.next_air_drop_hour == 0) {
        self.next_air_drop_hour = nextAirdropHour(self, now);
        return;
    }
    if (now < self.next_air_drop_hour) return;
    self.next_air_drop_hour = nextAirdropHour(self, now);
    // Drop above the first joined player.
    for (&self.clients) |*cl| {
        if (!cl.joined) continue;
        const ps = self.sim.playerByPeer(cl.slot) orelse continue;
        const t = self.sim.transform[ps];
        if (self.sim.spawnLootBag(t.x, t.y + 2, t.z, 1, 1)) |bag_nid| {
            // `[sim] airdrop_loot_list` (default stock "airDrop"; the old
            // "supplyCrate" name does not exist in stock loot.xml and rolled
            // empty crates - fixed here).
            self.fillLootBagFromTable(bag_nid, self.airdrop_loot_list, @intCast(bag_nid), self.lootStageForPlayer(cl.slot));
            self.broadcastLootSpawn(bag_nid) catch {};
            // AIDirectorAirDropComponent.RefreshCrates (map-objects.md section
            // 8): the one server-push nav marker case, everything else is
            // client-derived. nav_object_classes.xml "supply_drop" is the
            // shipped class name (map/compass/onscreen icon lookup; no display
            // name needed). entity_id ties the marker to the bag so a future
            // NetPackageEntityMapMarkerRemove on crate death has something to
            // reference; not implemented yet, so the marker outlives the loot.
            if (self.sim.slotOfNetId(bag_nid)) |bi| self.sim.loot_bag[bi].supply_crate = true;
            if (packages.buildNavObjectAdd(self.body_buf[8192..8704], "supply_drop", "", t.x, t.y + 2, t.z, @intCast(bag_nid))) |nb| {
                self.broadcast("NetPackageNavObject", nb) catch {};
            } else |_| {}
            std.debug.print("zdtd: air drop supply crate at ({d:.0},{d:.0}) hour={d}\n", .{ t.x, t.z, now });
        }
        return;
    }
}

/// BlockDamageAI / AIBM: attacking zombies chew through a solid block between
/// them and their target. Scaled by BlockDamageAI (BlockDamageAIBM on blood moon).
pub fn tickZombieBlockDamage(self: *Game) void {
    const mult: u32 = if (self.sim.director.bloodmoon_active) self.block_damage_ai_bm else self.block_damage_ai;
    if (mult == 0) return;
    // Per-class chew: the hand item's DamageBlock (zombie 8, feral 24) when
    // the class resolved one; the Rules floor otherwise.
    const base_bite: u32 = @trunc(@max(0, self.sim.rules.progression.block_bite_damage));
    // Cached zombie group: this pass only damages blocks, never spawns or
    // destroys entities, so the slice stays valid for the whole loop.
    for (ecs.groupSlice(&self.sim, .zombie)) |s| {
        const ai = self.sim.zombie_ai[s];
        if (ai.state != .attack and ai.state != .chase) continue;
        const tgt = self.sim.slotOfNetId(ai.target_id) orelse continue;
        const zt = self.sim.transform[s];
        const tt = self.sim.transform[tgt];
        var dx = tt.x - zt.x;
        var dz = tt.z - zt.z;
        const len = @sqrt(dx * dx + dz * dz);
        const block_range = @max(0.1, self.sim.rules.progression.block_damage_range);
        if (len < 0.1 or len > block_range) continue; // only when pressed against cover
        dx /= len;
        dz /= len;
        const bx: i32 = @floor(zt.x + dx);
        const bz: i32 = @floor(zt.z + dz);
        // The cell the zombie collides with sits at its body height: probe
        // the front column from feet to head and chew the first solid cell.
        // The old single head-height probe left zombies stuck against
        // 1-block-tall walls/fences (the head cell is air while the wall is
        // at feet level), so they never broke out.
        const feet_y: i32 = @floor(zt.y);
        const head_y: i32 = @floor(zt.y + 1);
        const by: i32 = blk: {
            var yi: i32 = feet_y;
            while (yi <= head_y) : (yi += 1) {
                if (self.world.isSolidWorld(bx, yi, bz) catch false) break :blk yi;
            }
            break :blk -1;
        };
        if (by < 0) continue;
        const id = self.blockIdAtWorld(bx, by, bz);
        if (id == 0) continue;
        // Zombies open unlocked doors on their path instead of chewing (RE
        // entity-ai.md CheckForDoorAndOpen: block with the door tag +
        // TEFeatureDoor, SetOpen when not open). Set the open meta bit and
        // broadcast; an already-open door is skipped (no re-broadcast). A
        // 2-tall door spans two cells, so the vertical partner gets the same
        // open bit (the probe may have landed on either half).
        if (self.blocks.byId(id)) |def| {
            if (def.is_door) {
                const door_dys = [_]i32{ 0, 1, -1 };
                for (door_dys) |dy| {
                    const yy = by + dy;
                    if (self.blockIdAtWorld(bx, yy, bz) != id) continue;
                    const raw = self.world.rawWorld(bx, yy, bz) catch continue;
                    if ((packages.blockMeta(raw) & packages.block_meta_on) != 0) continue;
                    const open_raw = packages.withBlockMeta(raw, packages.block_meta_on);
                    self.world.setBlockRawWorld(bx, yy, bz, open_raw) catch continue;
                    if (packages.buildSetBlockBodyRaw(self.body_buf[0..96], bx, yy, bz, open_raw, 0, -1, -1)) |sb| {
                        self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(bx), @floatFromInt(bz), self.interest_range) catch {};
                    } else |_| {}
                }
                continue;
            }
        }
        // Per-class chew: hand-item DamageBlock (zombie 8, feral 24) beats
        // the flat Rules floor when the class resolved one.
        const chew: u32 = if (self.sim.class_id[s].block_chew > 0)
            @trunc(self.sim.class_id[s].block_chew)
        else
            base_bite;
        const dmg: u16 = @intCast(@min(chew * mult / 100, 65535));
        const max_hp = self.maxDamageForBlock(id);
        const total = self.addBlockDamage(bx, by, bz, dmg) catch continue;
        if (total >= max_hp) {
            // Downgrade swap (stock Block.OnBlockDamaged): a block with a
            // DowngradeBlock turns into it instead of breaking.
            const down_raw = self.downgradeBreakRaw(bx, by, bz, id);
            if (down_raw != 0) {
                // The downgrade replaces the block, so the old one is gone
                // even though the cell stays occupied: its node, container
                // and vending entry go with it, same as a break.
                self.noteBlockRemoved(bx, by, bz, id);
                _ = self.world.setBlockRawWorld(bx, by, bz, down_raw) catch continue;
                // ...and the block it turned into claims what its own type
                // owns: a downgrade that lands a powered block needs a node.
                self.noteBlockAdded(bx, by, bz, world_store.typeId(down_raw));
                self.clearBlockHp(bx, by, bz);
                self.clearBlockRaw(bx, by, bz);
                if (packages.buildSetBlockBodyRaw(&self.body_buf, bx, by, bz, down_raw, 0, -1, -1)) |sb| {
                    self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(bx), @floatFromInt(bz), self.interest_range) catch {};
                } else |_| {}
            } else {
                // A removed bedroll clears the owner's respawn point.
                self.noteBlockRemoved(bx, by, bz, id);
                self.world.setBlockWorld(bx, by, bz, 0) catch continue;
                self.clearBlockHp(bx, by, bz);
                self.clearBlockRaw(bx, by, bz);
                if (packages.buildSetBlockBody(&self.body_buf, bx, by, bz, 0)) |sb| {
                    self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(bx), @floatFromInt(bz), self.interest_range) catch {};
                } else |_| {}
            }
        }
    }
}

/// Drop locks held longer than the lock stale window (tick path).
pub fn reapStaleLocks(self: *Game) void {
    const now = clock.monoNs();
    for (&self.lock_channel, 0..) |h, i| {
        if (h < 0) continue;
        const g = self.lock_granted_ns[i];
        if (g == 0) continue;
        if (now -% g >= self.lock_stale_ns) self.clearLockSlot(i);
    }
}

pub fn reapStalePeers(self: *Game) void {
    const now = clock.monoNs();
    const stale_ns: u64 = self.peer_stale_ms *| 1_000_000;
    // Stock MaxDurationInAuthState (10 s): the auth sweep runs off the
    // challenge issue time, not RX silence, so a peer that keeps the socket
    // warm with junk but never echoes is still reaped.
    const auth_ns: u64 = game_mod.default_auth_state_ms *| 1_000_000;
    for (&self.clients) |*c| {
        const p = c.peer orelse continue;
        if (!p.alive) {
            self.harness.counters.inc(.stale_peers_reaped);
            std.debug.print(
                "zdtd: peer reaped dead local_id={d} slot={d} entity={d}\n",
                .{ p.local_id, c.slot, c.entity_id },
            );
            // A hard disconnect (no NetPackagePlayerDisconnect) must not lose
            // the player's data until the next autosave: persist before the
            // slot is cleared (GAP "Save on disconnect / kick"). Pre-join
            // peers have no entity and nothing to save.
            if (c.entity_id > 0) self.savePlayers() catch |e| persist.logPersistErr(self, "save players on reap", e);
            self.clearLocksForPeer(c.slot);
            c.* = .{};
            self.refreshInfoPlayers();
            continue;
        }
        if (p.last_recv_ns == 0) continue;
        // Auth-state age (stock MaxDurationInAuthState): a peer that never
        // echoed the challenge is reaped past the age cap even when it keeps
        // receiving (RX silence alone never fires: last_recv_ns updates on
        // every datagram, including junk). Authenticated peers have
        // challenge_ns == 0 and skip this arm.
        if (c.challenge_ns != 0 and now -% c.challenge_ns > auth_ns) {
            self.harness.counters.inc(.stale_peers_reaped);
            std.debug.print(
                "zdtd: peer reaped in-auth local_id={d} slot={d} age_ms={d}\n",
                .{ p.local_id, c.slot, (now -% c.challenge_ns) / 1_000_000 },
            );
            p.alive = false;
            p.authenticated = false;
            for (&p.pending) |*slot| slot.used = false;
            p.local_window_start = p.local_seq;
            self.clearLocksForPeer(c.slot);
            c.* = .{};
            self.refreshInfoPlayers();
            continue;
        }
        if (now -% p.last_recv_ns > stale_ns) {
            self.harness.counters.inc(.stale_peers_reaped);
            std.debug.print(
                "zdtd: peer reaped stale local_id={d} slot={d} entity={d} idle_ms={d}\n",
                .{ p.local_id, c.slot, c.entity_id, (now -% p.last_recv_ns) / 1_000_000 },
            );
            p.alive = false;
            p.authenticated = false;
            for (&p.pending) |*slot| slot.used = false;
            p.local_window_start = p.local_seq;
            if (c.entity_id > 0) self.savePlayers() catch |e| persist.logPersistErr(self, "save players on reap", e);
            self.clearLocksForPeer(c.slot);
            c.* = .{};
            self.refreshInfoPlayers();
        }
    }
}

/// Drop armed policy kicks once the stock 0.5 s grace has elapsed.
/// Bounded by max_clients per tick.
pub fn reapPolicyKicks(self: *Game) void {
    for (&self.clients, 0..) |*cl, i| {
        if (cl.guard.kick_at_tick == 0) continue;
        if (self.tick_n < cl.guard.kick_at_tick) continue;
        if (cl.peer == null) {
            cl.guard.kick_at_tick = 0;
            continue;
        }
        self.dropClientSlot(i, "guard");
    }
}

pub fn clearDeadKnownEntities(self: *Game) void {
    // Most ticks free no slots; skip the reconcile entirely.
    if (!self.sim.any_freed_this_tick) return;
    // Word-wise AND per client against the sim's live set, instead of a
    // per-slot × per-client unset sweep (512×64 every tick).
    for (&self.clients) |*kc| kc.known_entities.setIntersection(self.sim.alive_bits);
    self.sim.any_freed_this_tick = false;
}

/// Drain MoveHelper dig damage requests (RE entity-ai.md DigUpdate): each
/// request damages the sim-marked block with the chew's bite damage; a broken
/// block ends the dig so the zombie walks on.
pub fn drainDigRequests(self: *Game) void {
    const mult: u32 = if (self.sim.director.bloodmoon_active) self.block_damage_ai_bm else self.block_damage_ai;
    if (mult == 0) return;
    // Per-class chew floor: hand-item DamageBlock beats the flat Rules value.
    const base_bite: u32 = @trunc(@max(0, self.sim.rules.progression.block_bite_damage));
    const n = @min(self.sim.dig_n, self.sim.dig_reqs.len);
    self.sim.dig_n = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const d = self.sim.dig_reqs[i];
        if (!self.sim.alive[d.slot]) continue;
        const solid = self.world.isSolidWorld(d.x, d.y, d.z) catch continue;
        if (!solid) {
            self.sim.zombie_ai[d.slot].digging = false;
            continue;
        }
        const id = self.blockIdAtWorld(d.x, d.y, d.z);
        if (id == 0) continue;
        const chew: u32 = if (self.sim.class_id[d.slot].block_chew > 0)
            @trunc(self.sim.class_id[d.slot].block_chew)
        else
            base_bite;
        const dmg: u16 = @intCast(@min(chew * mult / 100, 65535));
        const max_hp = self.maxDamageForBlock(id);
        const total = self.addBlockDamage(d.x, d.y, d.z, dmg) catch continue;
        if (total >= max_hp) {
            // Downgrade swap (stock Block.OnBlockDamaged): a block with a
            // DowngradeBlock turns into it instead of breaking.
            const down_raw = self.downgradeBreakRaw(d.x, d.y, d.z, id);
            if (down_raw != 0) {
                // Same as the damage-break downgrade above: the old block is
                // displaced, so its side state goes with it.
                self.noteBlockRemoved(d.x, d.y, d.z, id);
                _ = self.world.setBlockRawWorld(d.x, d.y, d.z, down_raw) catch continue;
                self.noteBlockAdded(d.x, d.y, d.z, world_store.typeId(down_raw));
                self.clearBlockHp(d.x, d.y, d.z);
                self.clearBlockRaw(d.x, d.y, d.z);
                self.sim.zombie_ai[d.slot].digging = false;
                if (packages.buildSetBlockBodyRaw(&self.body_buf, d.x, d.y, d.z, down_raw, 0, -1, -1)) |sb| {
                    self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(d.x), @floatFromInt(d.z), self.interest_range) catch {};
                } else |_| {}
            } else {
                // A removed bedroll clears the owner's respawn point.
                self.noteBlockRemoved(d.x, d.y, d.z, id);
                self.world.setBlockWorld(d.x, d.y, d.z, 0) catch continue;
                self.clearBlockHp(d.x, d.y, d.z);
                self.clearBlockRaw(d.x, d.y, d.z);
                self.sim.zombie_ai[d.slot].digging = false;
                if (packages.buildSetBlockBody(&self.body_buf, d.x, d.y, d.z, 0)) |sb| {
                    self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(d.x), @floatFromInt(d.z), self.interest_range) catch {};
                } else |_| {}
            }
        }
    }
}

/// Drain sleeper wake requests (RE EntityAlive.ConditionalTriggerSleeperWakeUp:
/// broadcasts NetPackageSleeperWakeup, unreliable, to every client when a
/// sleeper zombie wakes - proximity, noise or damage; protocol-packages.md
/// §6.19). Consume-owns-drain like the dig ring. Broadcast, not interest
/// gated: stock ConnectionManager.SendPackage with toEntityId=-1 reaches all
/// clients, and a distant POI waking matters for a client's minimap/audio.
pub fn drainSleeperWakeups(self: *Game) void {
    const n = @min(self.sim.sleeper_wake_n, self.sim.sleeper_wake_reqs.len);
    self.sim.sleeper_wake_n = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const s: u16 = self.sim.sleeper_wake_reqs[i].slot;
        if (!self.sim.alive[s] or !self.sim.mask[s].network_id) continue;
        const nid = self.sim.network_id[s].id;
        // RE EntityAlive.SetSleeperActive (IL=26): a stirred sleeper sends
        // NetPackageSleeperPassiveChange (the client clears IsSleeperPassive
        // and plays the groan); a woken one gets NetPackageSleeperWakeup.
        if (self.sim.sleeper_wake_reqs[i].groan) {
            if (packages.buildSleeperPassiveChangeBody(&self.body_buf, nid)) |body| {
                self.broadcast("NetPackageSleeperPassiveChange", body) catch {};
            } else |_| {}
            continue;
        }
        if (packages.buildSleeperWakeupBody(&self.body_buf, nid)) |body| {
            self.broadcast("NetPackageSleeperWakeup", body) catch {};
        } else |_| {}
    }
}

/// EntityAlive look-at sync (RE protocol-packages.md §5.2.1): broadcasts
/// NetPackageEntityLookAt to tracking players when an awake zombie's look
/// target moves past the stock 0.0016 sqr-delta gate (EntityAlive
/// SetLookPosition, SendPacketToTrackedPlayers). Target = the AI's attack
/// target position, else the investigate spot. Cosmetic head-aim only; no
/// sim authority. The per-slot last-sent state skips re-sends between
/// meaningful target changes.
pub fn tickEntityLookAt(self: *Game) void {
    for (self.sim.kind_groups.slice(.zombie)) |s| {
        if (!self.sim.alive[s] or !self.sim.mask[s].network_id or !self.sim.mask[s].zombie_ai) continue;
        if (!self.sim.mask[s].transform) continue;
        const ai = self.sim.zombie_ai[s];
        if (!ai.alert and !ai.has_spot) continue;
        if (self.sim.mask[s].sleeper and !self.sim.sleeper[s].awake) continue;
        var lx: f32 = 0;
        var ly: f32 = 0;
        var lz: f32 = 0;
        var have = false;
        if (ai.target_id >= 0) {
            if (self.sim.slotOfNetId(ai.target_id)) |t| {
                if (self.sim.alive[t] and self.sim.mask[t].transform) {
                    lx = self.sim.transform[t].x;
                    ly = self.sim.transform[t].y;
                    lz = self.sim.transform[t].z;
                    have = true;
                }
            }
        }
        if (!have and ai.has_spot) {
            lx = ai.spot_x;
            ly = self.sim.transform[s].y;
            lz = ai.spot_z;
            have = true;
        }
        if (!have) continue;
        const st = &self.entity_look_sent[s];
        // Slot recycled onto a new entity: the previous occupant's last-sent
        // target must not gate this one's first look (spawnBase bumped gen).
        if (st.gen != self.sim.network_id[s].gen) st.* = .{ .gen = self.sim.network_id[s].gen };
        const dx = lx - st.x;
        const dy = ly - st.y;
        const dz = lz - st.z;
        if (st.sent and dx * dx + dy * dy + dz * dz < 0.0016) continue;
        st.x = lx;
        st.y = ly;
        st.z = lz;
        st.sent = true;
        if (packages.buildEntityLookAtBody(&self.body_buf, self.sim.network_id[s].id, lx, ly, lz)) |body| {
            self.broadcastNear("NetPackageEntityLookAt", body, self.sim.transform[s].x, self.sim.transform[s].z, self.interest_range) catch {};
        } else |_| {}
    }
}

/// NetPackageSetAttackTarget S2C. Stock fans this out from every server-side
/// attack-target change: `EntityAlive::SetAttackTarget` (IL=70) sends
/// `Setup(entityId, target ? target.entityId : -1)`, and the expiry path in
/// `OnUpdateLive` (IL=363) sends `Setup(entityId, -1)` when attackTargetTime
/// runs out. The client stores it as `attackTargetClient`, which is what
/// `GetAttackTargetLocal` returns for a remote entity (the drone beam and the
/// DynamicMusic threat level read it).
///
/// zdtd picks targets in the sim (`ai.target_id`) and never published them, so
/// remote clients saw every zombie as untargeted. This is the edge detector:
/// stock's per-change sends become a per-tick diff against the last published
/// value, which is the same traffic without mirroring stock's call sites.
pub fn tickAttackTarget(self: *Game) void {
    for (self.sim.kind_groups.slice(.zombie)) |s| {
        if (!self.sim.alive[s] or !self.sim.mask[s].network_id or !self.sim.mask[s].zombie_ai) continue;
        if (!self.sim.mask[s].transform) continue;
        // A sleeping sleeper has no live target to advertise, and waking is
        // its own package (drainSleeperWakeups).
        if (self.sim.mask[s].sleeper and !self.sim.sleeper[s].awake) continue;
        const st = &self.attack_target_sent[s];
        // Slot recycled onto a new entity: the previous occupant's last-sent
        // target must not gate this one's first send (spawnBase bumped gen).
        if (st.gen != self.sim.network_id[s].gen) st.* = .{ .gen = self.sim.network_id[s].gen };
        // Stock's wire value: -1 when there is no target, and equally when the
        // target is gone, since a dead entity is not a target any more.
        var want: i32 = -1;
        const tid = self.sim.zombie_ai[s].target_id;
        if (tid >= 0) {
            if (self.sim.slotOfNetId(tid)) |t| {
                if (self.sim.alive[t]) want = tid;
            }
        }
        if (st.sent and st.id == want) continue;
        st.id = want;
        st.sent = true;
        if (packages.buildSetAttackTargetBody(&self.body_buf, self.sim.network_id[s].id, want)) |body| {
            self.broadcastNear("NetPackageSetAttackTarget", body, self.sim.transform[s].x, self.sim.transform[s].z, self.interest_range) catch {};
        } else |_| {}
    }
}

/// NetPackageClientInfo broadcast (RE ConnectionManager.updateClientInfo:
/// 5 s cadence): the per-player list (entityId, ping, admin flag) that drives
/// the player list UI and admin crowns. Ping is 0 (zdtd has no RTT
/// measurement; documented residual), admin = the name is in the permission
/// list.
/// Stock serveradmin.xml hot-reload (AdminTools.InitFileWatcher ->
/// OnFileChanged -> Load, IL=33/5): poll the file's mtime every 5 s and
/// re-apply the XML on change. The .zsv list files stay the runtime-persisted
/// form, so an operator editing serveradmin.xml while the server runs sees
/// the change without a restart (bans, whitelist and admin levels).
pub fn tickServerAdminReload(self: *Game) void {
    if (self.serveradmin_reload_timer > 0) {
        self.serveradmin_reload_timer -= 1;
        return;
    }
    self.serveradmin_reload_timer = 100; // 5 s at 20 TPS
    const path = self.serveradmin_path orelse return;
    const mtime = io_fs.fileMtimeNanos(path) orelse return;
    if (mtime == self.serveradmin_mtime) return;
    self.serveradmin_mtime = mtime;
    // Replace the XML-sourced portion (entries removed from the file must
    // disappear); runtime (.zsv) entries are untouched.
    self.admin_list.clearXml();
    self.whitelist.clearXml();
    self.ban_list.clearXml();
    admin_xml.load(self.allocator, path, &self.admin_list, &self.whitelist, &self.ban_list) catch |err| {
        var ts: [19]u8 = undefined;
        std.debug.print("zdtd: {s} warning: serveradmin.xml reload failed: {s}\n", .{ clock.wallStamp(&ts), @errorName(err) });
        return;
    };
    std.debug.print("zdtd: serveradmin.xml reloaded (mtime {d})\n", .{mtime});
}

pub fn tickClientInfo(self: *Game) void {
    if (self.client_info_timer > 0) {
        self.client_info_timer -= 1;
        return;
    }
    self.client_info_timer = 100; // 5 s at 20 TPS (stock timer value)
    var entries: [game_mod.max_clients]packages.ClientInfoEntry = undefined;
    var n: usize = 0;
    for (&self.clients) |*c| {
        if (!c.joined or c.entity_id <= 0) continue;
        if (n >= entries.len) break;
        // Admin flag: platform-id composite (serveradmin.xml / admin add on
        // an online session) or the login name (name-keyed entries).
        var is_admin = c.name_len != 0 and self.admin_list.find(c.name[0..c.name_len]) != null;
        if (!is_admin) {
            if (c.puid_primary.get()) |pid| {
                var key_buf: [admin_cmds.max_id]u8 = undefined;
                const key = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ pid.platform, pid.id }) catch "";
                if (key.len != 0) is_admin = self.admin_list.find(key) != null;
            }
        }
        entries[n] = .{ .entity_id = c.entity_id, .ping_ms = 0, .admin = is_admin };
        n += 1;
    }
    if (n == 0) return;
    if (packages.buildClientInfoBody(&self.body_buf, entries[0..n])) |body| {
        self.broadcast("NetPackageClientInfo", body) catch {};
    } else |_| {}
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
