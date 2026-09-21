//! Buff-event drivers: requirement-gate ctx assembly (PlayerCtx),
//! triggered-row apply helpers, AddBuff gate, and every fire* event
//! (hit/kill/fall/jump/aim/crouch/respawn/reload/died/leave-game,
//! mob + class rows, item-use buffs, combat entry). *Game helpers called
//! from C2S handlers and step.zig; `game.zig` exposes forwarding methods.
//!
//! Split out of tick.zig (same functions, moved verbatim); the survival
//! VM fold and equip sync stay in tick.zig.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const packages = @import("../../wire/packages.zig");
const ecs = @import("../../ecs/root.zig");
const assets_buffs = @import("../../assets/buffs.zig");
const assets_unity_hash = @import("../../assets/unity_hash.zig");
const assets_progression = @import("../../assets/progression.zig");
const requirements = @import("../../assets/requirements.zig");
const sandbox = @import("../../assets/sandbox.zig");
const hooks = @import("hooks.zig");
const rng_util = @import("../../util/rng.zig");
const game_social = @import("social.zig");
const inventory = @import("../../ecs/inventory.zig");
const game_types = @import("types.zig");
const tick = @import("tick.zig");
// VM helpers owned by tick.zig (also used by the survival fold):
const activeBuffIds = tick.activeBuffIds;
const wornItemTags = tick.wornItemTags;
const armorGroups = tick.armorGroups;
const isHeadUnderwater = tick.isHeadUnderwater;
const heldItemTags = tick.heldItemTags;
const heldItemHasSecondary = tick.heldItemHasSecondary;
const holdingItemBroken = tick.holdingItemBroken;
const isSeated = tick.isSeated;
const fillItemMods = tick.fillItemMods;
// Shared consts owned by tick.zig:



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

/// Requirement-gate bridge: `PlayerItemCount` counts `item_name` over the
/// live inventory (`Inventory.GetItemCount + Bag.GetItemCount`, IL=67).
/// An unknown item name counts 0, like stock's null-ItemValue path.
const ItemCountLookup = struct {
    game: *Game,
    ps: ecs.Slot,

    fn count(ctx: *const anyopaque, item_name: []const u8) u32 {
        const self: *const ItemCountLookup = @ptrCast(@alignCast(ctx));
        if (!self.game.sim.mask[self.ps].inventory) return 0;
        const def = self.game.items.byName(item_name) orelse return 0;
        return self.game.sim.inventory[self.ps].countItem(def.id);
    }
};

/// The tag `Equipment::GetTotalPhysicalArmorRating` (IL=887) adds to its
/// passive-41 query; the attacking item's own tags ride the per-hit path.
pub const armor_query_tags = "coredamageresist";

/// The stock base max for Food/Water/Stamina (`EntityStats` seeds all three to
/// 100 and the VM folds its `*Max` deltas onto that base). Named so the
/// StatCompare gates' `Stat::Max` operand and the max recompute below cannot
/// drift apart.
const base_consumable_stat_max: f32 = 100;

/// Shared requirement-gate ctx assembly (ADR 0023 §2): the live player state
/// a `<requirement>` reads. One builder for the per-tick fold, the finish
/// trigger, and the damage-time fold, so a new gate input lands everywhere
/// at once instead of drifting across three copies (the attached_to_entity
/// drift of 2026-09-15). Scratch buffers live in the struct; `sink`/`names`
/// borrow from it, so the built Ctx is valid while the builder is alive.
pub const PlayerCtx = struct {
    buff_ids: [ecs.components.max_buffs_per_entity]u16 = undefined,
    buff_lookup: BuffNameLookup = .{ .table = undefined },
    buff_names: requirements.BuffNames = undefined,
    armor_group_buf: [ecs.components.inv_equip_count * 2]requirements.ArmorGroup = undefined,
    worn_tags_buf: [ecs.components.inv_equip_count][]const u8 = undefined,
    sink_impl: BuffSink = undefined,
    item_count_lookup: ItemCountLookup = .{ .game = undefined, .ps = 0 },

    pub fn init(self: *PlayerCtx, game: *Game, c: *Client, ps: ecs.Slot) void {
        self.buff_lookup = .{ .table = &game.buffs };
        self.buff_names = .{ .ctx = &self.buff_lookup, .resolve = BuffNameLookup.resolve };
        self.sink_impl = .{ .game = game, .entity_id = c.entity_id, .ps = ps };
        self.item_count_lookup = .{ .game = game, .ps = ps };
    }

    pub fn build(
        self: *PlayerCtx,
        game: *Game,
        c: *Client,
        ps: ecs.Slot,
        h: *const ecs.components.Health,
        sandbox_groups: []const sandbox.Group,
    ) requirements.Ctx {
        // Mirror submersion into `_underwater` (53 stock gates: torch
        // ignite, drowning buffs, swim penalties). Same head-block-water
        // check as the drowning leg; stock sets it client-side and never
        // networks `_` names, so the server projects it here and every ctx
        // consumer reads the same value.
        _ = c.cvars.apply("_underwater", .set, if (isHeadUnderwater(game, ps)) 1 else 0);
        return .{
            .levels = c.skill_levels[0..c.skill_level_n],
            .player_level = c.level,
            .alive = game.sim.alive[ps],
            .is_male = blk: {
                const class_hash = if (game.sim.mask[ps].class_id and game.sim.class_id[ps].hash != 0)
                    game.sim.class_id[ps].hash
                else
                    assets_unity_hash.class_player_male;
                break :blk class_hash != assets_unity_hash.class_player_female;
            },
            .is_corpse = h.corpse_seconds > 0,
            .is_sleeping = game.sim.mask[ps].sleeper and !game.sim.sleeper[ps].awake,
            // Dedicated server: never EntityPlayerLocal (RE IsLocalPlayer IL=23).
            .is_local_player = false,
            // Dedicated server: never EntityPlayerLocal.bFirstPersonView (RE IsFPV IL=34).
            .is_fpv = false,
            // Dedicated server: never EntityPlayerLocal.shelterPercent (RE IsSheltered IL=24).
            .is_sheltered = false,
            // Dedicated server: never EntityPlayerLocal tracking bounds (RE HasTrackedEntity IL=93).
            .has_tracked_entity = false,
            // Inventory + bag count by item name (RE PlayerItemCount IL=67).
            .item_count_ctx = &self.item_count_lookup,
            .item_count = ItemCountLookup.count,
            // Dedicated server: never Unity EModelSDCS (RE IsSDCS IL=27).
            .is_sdcs = false,
            // Dedicated server: never IsFriendOfLocalPlayer (RE IsAlly IL=36).
            .is_ally = false,
            // No Entity.IsInElevator tracked yet (RE IsOnLadder IL=19).
            .is_on_ladder = false,
            // Dedicated server: never Unity RootTransform/tempPrefab_* (RE HasAttachedPrefab IL=53).
            .has_attached_prefab = false,
            // Dedicated server: never Unity particle FX (RE HasParticle IL=23).
            .has_particle = false,
            // Stock IsLookingAtBlock IL=8 stub always returns true after base check.
            .is_looking_at_block = true,
            // Stock IsLookingAtEntity inherits IsLookingAtBlock stub → always true.
            .is_looking_at_entity = true,
            // AmountEnclosed not tracked yet (RE IsIndoors IL=25) → 0 → false.
            .is_indoors = false,
            // Seated in a vehicle (`Entity::AttachedToEntity`): scan the
            // vehicle seats for this entity id.
            .attached_to_entity = isSeated(&game.sim, c.entity_id),
            .biome_id = game.biomeIdAt(@trunc(game.sim.transform[ps].x), @trunc(game.sim.transform[ps].z)),
            .active_buffs = activeBuffIds(&game.sim.buffs[ps], &self.buff_ids),
            .buff_names = &self.buff_names,
            .held_tags = heldItemTags(game, ps),
            .holding_item_broken = holdingItemBroken(game, ps),
            .is_secondary_attack = heldItemHasSecondary(game, ps),
            .sandbox_groups = sandbox_groups,
            .game_stat_biome_progression = game.gameStatsValues().biome_progression,
            .armor_groups = armorGroups(game, ps, &self.armor_group_buf),
            .cvars = &c.cvars,
            // Per-event roll seed for `RandomRoll seed_type="Random"`
            // (stock seeds a fresh GameRandom from MinEventParams.Seed):
            // entity id mixed with the tick through a SplitMix64 finalizer,
            // deterministic per sim. A raw multiply-add walks sequential
            // seeds whose first xorshift outputs cluster near 97% (found
            // when the 5% PackMule roll never passed in 4000 ticks).
            .roll_seed = rng_util.XorShift32.initFromU64(@as(u64, @bitCast(@as(i64, c.entity_id))) *% 0x9E3779B9 +% game.tick_n).state,
            // Skill children for `PerksUnlocked` (progression table
            // parent_attr): the sum reads purchased perk levels by name.
            .skill_children_ctx = &game.progression_table,
            .skill_children_total = struct {
                fn f(holder: *const anyopaque, skill: []const u8, levels: []const requirements.NameLevel) u16 {
                    const t: *const assets_progression.Table = @ptrCast(@alignCast(holder));
                    var total: u16 = 0;
                    for (t.perks) |p| {
                        if (!std.mem.eql(u8, p.parent_attr, skill)) continue;
                        for (levels) |l| {
                            if (std.mem.eql(u8, l.name, p.name)) {
                                total += l.level;
                                break;
                            }
                        }
                    }
                    return total;
                }
            }.f,
            // The armour rating the previous tick's coredamageresist fold
            // produced (see requirements.Ctx.armor_rating).
            .armor_rating = game.sim.buff_phys_resist[ps],
            .live_buff = &self.sink_impl,
            .buff_active = BuffSink.has,
            .sink = .{ .ctx = &self.sink_impl, .add_buff = BuffSink.add, .remove_buff = BuffSink.remove },
            .worn_items = wornItemTags(game, ps, &self.worn_tags_buf),
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
            .is_night = game.sim.director.clock.isNight(),
            .is_day = !game.sim.director.clock.isNight(),
            .is_blood_moon = game.sim.director.clock.isBloodMoonNight(),
            .day_number = game.sim.director.clock.day,
            .time_of_day_ticks = @intFromFloat(@trunc(game.sim.director.clock.hours * 1000.0)),
            // The entity's class Tags (`entityclasses.xml`), read by
            // EntityTagCompare for the default self target.
            .entity_tags = entityClassTags(game, ps),
            // CurrentMovementTag (`EntityHasMovementTag`): the client's
            // reported movement state folded to idle/walking/running.
            .movement_tags = c.move_tag.name(),
        };
    }
};

/// The entity's own class `Tags` for `EntityTagCompare` (entityclasses.xml
/// `Tags` resolved through `extends`). The slot's class hash is the same one
/// the PlayerId wire carries; a slot without a class falls back to the player
/// class. Null = no catalog carries the class, which the gate refuses
/// (fail closed, counted) rather than silently treating the entity as
/// untagged.
pub fn entityClassTags(self: *Game, ps: ecs.Slot) ?[]const u8 {
    const hash = if (self.sim.class_id[ps].hash != 0)
        self.sim.class_id[ps].hash
    else
        assets_unity_hash.class_player_male;
    const def = self.entities.byHash(hash) orelse return null;
    return def.tags;
}

/// Project a victim slot's `_notAlerted` for foreign CVarCompare gates
/// (NightStalker stealth damage needs an unalerted victim): true when the
/// slot is a living non-player without the AI alert flag. Players and
/// unknown slots leave the projection null (store read instead).
fn projectVictimAlert(self: *Game, ctx: *requirements.Ctx, victim: ecs.Slot) void {
    if (self.sim.mask[victim].player) return;
    if (!self.sim.alive[victim]) {
        ctx.other_not_alerted = false;
        return;
    }
    const alerted = self.sim.mask[victim].zombie_ai and self.sim.zombie_ai[victim].alert;
    ctx.other_not_alerted = !alerted;
}

/// Add and remove the catalog buffs a triggered row asked for, relaying each
/// change to observers (the same contract as syncStageBuffs). Bounded by the
/// result's fixed arrays; an unknown name is skipped (fail closed).
pub fn applyTriggeredBuffs(self: *Game, entity_id: i32, ps: ecs.Slot, res: *const assets_buffs.TriggeredResult, instigator_id: i32) void {
    applyTriggeredBuffsFull(self, entity_id, ps, res, instigator_id, true);
}

fn applyTriggeredBuffsFull(self: *Game, entity_id: i32, ps: ecs.Slot, res: *const assets_buffs.TriggeredResult, instigator_id: i32, apply_stats: bool) void {
    applyTriggeredBuffsOther(self, null, res, instigator_id);
    // `CallGameEvent` rows run the named sequence through the gameevents
    // runner (Dentist silver/gold grants ride ClientSequenceAction).
    const peer_slot = if (self.sim.mask[ps].player) self.sim.player[ps].peer_slot else -1;
    for (res.game_events[0..res.game_event_n]) |seq_name| {
        if (peer_slot >= 0 and @as(usize, @intCast(peer_slot)) < self.clients.len) {
            _ = self.runGameEventSequence(@intCast(peer_slot), seq_name);
        }
    }
    // `RemoveAllNegativeBuffs` (near-death regen cure): flag every active
    // buff whose DamageType is set (IL=50 checks `!= None`).
    if (res.remove_all_negative) {
        var ids: [ecs.components.max_buffs_per_entity]u16 = undefined;
        const n = activeBuffIds(&self.sim.buffs[ps], &ids).len;
        for (ids[0..n]) |id| {
            const def = self.buffs.byId(id) orelse continue;
            if (def.damage_type.len == 0) continue;
            _ = ecs.buff.remove(&self.sim.buffs[ps], id);
        }
    }
    // Stock splits `buff=` on commas into buffNames (buff modifier base
    // IL=50/76); a recorded multi-name entry fans out here (the live sink
    // already splits through applyCommaBuffs).
    for (res.remove_buffs[0..res.remove_n]) |names| {
        var it = std.mem.splitScalar(u8, names, ',');
        while (it.next()) |seg| {
            const name = std.mem.trim(u8, seg, " \t");
            if (name.len == 0) continue;
            const def_id = self.buffs.indexOfName(name) orelse continue;
            const set = self.sim.buffsMut(ps);
            // Flag only: the buff tick reaps it next tick and the expiry drain
            // relays the removal once (relaying here too would send the stock
            // client a second NetPackageAddRemoveBuff for the same buff).
            _ = ecs.buff.remove(set, def_id);
        }
    }
    for (res.add_buffs[0..res.add_n]) |names| {
        var it = std.mem.splitScalar(u8, names, ',');
        while (it.next()) |seg| {
            const name = std.mem.trim(u8, seg, " \t");
            if (name.len == 0) continue;
            _ = addCatalogBuff(self, entity_id, ps, name, instigator_id);
        }
    }
    // Immediate stat deltas on the holder's own bars (finish-event restores:
    // spawn-heal +30000 Health/Stamina). Health adds flow through hp_delta
    // semantics inline here; Food/Water/Stamina apply directly. Hit/kill
    // callers pass apply_stats=false: applyKillMods owns their stat job.
    if (!apply_stats) return;
    if (self.sim.mask[ps].health) {
        const h = &self.sim.health[ps];
        const hp_add = assets_buffs.healthAddDelta(res);
        if (hp_add != 0 and h.hp > 0) h.hp = @min(h.max_hp, h.hp + hp_add);
        const fw = assets_buffs.foodWaterDelta(res);
        h.food = @max(0, h.food + fw.food);
        h.water = @max(0, h.water + fw.water);
        if (fw.food_set) |v| h.food = @max(0, @min(h.food_max, v));
        if (fw.water_set) |v| h.water = @max(0, @min(h.water_max, v));
        const stdelta = assets_buffs.staminaDelta(res);
        h.stamina = @min(h.stamina_max, @max(0, h.stamina + stdelta.delta));
        if (stdelta.set) |v| h.stamina = @max(0, @min(h.stamina_max, v));
        self.sim.markDirty(ps, .{ .hp = true });
    }
}

/// Victim-directed half of a triggered result (`target="other"` rows): apply
/// the adds/removes to the event's other slot. Zombies carry buff sets too,
/// so a cripple/bleed/stun proc lands on them; players get the relay.
/// Null victim = no other in scope (non-damage callers): the other_sink
/// already applied live, so the recorded lists are dropped.
fn applyTriggeredBuffsOther(self: *Game, victim: ?ecs.Slot, res: *const assets_buffs.TriggeredResult, instigator_id: i32) void {
    const vs = victim orelse return;
    for (res.remove_other_buffs[0..res.remove_other_n]) |names| {
        var it = std.mem.splitScalar(u8, names, ',');
        while (it.next()) |seg| {
            const name = std.mem.trim(u8, seg, " \t");
            if (name.len == 0) continue;
            const def_id = self.buffs.indexOfName(name) orelse continue;
            if (!self.sim.mask[vs].buffs) continue;
            _ = ecs.buff.remove(self.sim.buffsMut(vs), def_id);
        }
    }
    const vid = if (self.sim.mask[vs].network_id) self.sim.network_id[vs].id else -1;
    for (res.add_other_buffs[0..res.add_other_n], 0..) |names, i| {
        // fireOneBuff: weighted single pick over the comma list (stock draws
        // Entity.rand random float and walks cumulative buffWeights).
        if (res.add_other_fireone[i] and res.add_other_weights_n[i] > 0) {
            if (pickWeightedBuff(self, vs, names, res.add_other_weights[i][0..res.add_other_weights_n[i]])) |name| {
                _ = addCatalogBuff(self, vid, vs, name, instigator_id);
            }
            continue;
        }
        var it = std.mem.splitScalar(u8, names, ',');
        while (it.next()) |seg| {
            const name = std.mem.trim(u8, seg, " \t");
            if (name.len == 0) continue;
            _ = addCatalogBuff(self, vid, vs, name, instigator_id);
        }
    }
    // Victim-directed ModifyStats rows (Physician euthanizer set-to-kill):
    // Health/Stamina set/subtract/add on the victim's bars when it has them.
    if (self.sim.mask[vs].health) {
        const vh = &self.sim.health[vs];
        for (res.mods[0..res.mod_n]) |m| {
            if (!m.target_other) continue;
            if (std.ascii.eqlIgnoreCase(m.stat, "Health")) {
                if (m.op == .add) {
                    if (vh.hp > 0) vh.hp = @min(vh.max_hp, vh.hp + m.value);
                } else if (m.op == .subtract) {
                    vh.hp = @max(0, vh.hp - m.value);
                } else {
                    vh.hp = @max(0, @min(vh.max_hp, m.value));
                }
            } else if (std.ascii.eqlIgnoreCase(m.stat, "Stamina")) {
                if (m.op == .add) {
                    vh.stamina = @min(vh.stamina_max, @max(0, vh.stamina + m.value));
                } else if (m.op == .subtract) {
                    vh.stamina = @max(0, vh.stamina - m.value);
                } else {
                    vh.stamina = @max(0, @min(vh.stamina_max, m.value));
                }
            }
        }
        self.sim.markDirty(vs, .{ .hp = true });
    }
}

/// Weighted single pick over a fireOneBuff comma list; deterministic off the
/// target's net id (stock `Entity.rand`). Returns null only if every weight is
/// zero (nothing selected, matching the cumulative-walk fallthrough).
fn pickWeightedBuff(self: *Game, ps: ecs.Slot, names: []const u8, weights: []const f32) ?[]const u8 {
    var list_buf: [16][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, names, ',');
    while (it.next()) |seg| {
        const name = std.mem.trim(u8, seg, " \t");
        if (name.len == 0) continue;
        if (n >= list_buf.len or n >= weights.len) break;
        list_buf[n] = name;
        n += 1;
    }
    if (n == 0) return null;
    var total: f32 = 0;
    for (weights[0..n]) |w| total += w;
    if (total <= 0) return null;
    const seed = if (self.sim.mask[ps].network_id) self.sim.network_id[ps].id else @as(i32, @intCast(ps));
    var rng = rng_util.XorShift32.initFromNetId(seed);
    const roll = rng.nextFloat() * total;
    var acc: f32 = 0;
    for (weights[0..n], 0..) |w, i| {
        acc += w;
        if (roll < acc) return list_buf[i];
    }
    return list_buf[n - 1];
}

/// Fan an `otherAOE` add list out over living entities within `range` of the
/// buff holder (SledgeSaga cripple morale). Stock centers the range cube on
/// Self (`Entity::position` at IL_0146), not on the victim; the row's
/// requirement gates run per candidate with that candidate as Other. Tag
/// filter matches the candidate's class tags; empty matches everything. The
/// holder itself is skipped (self got its own rows).
pub fn applyTriggeredBuffsAoe(self: *Game, holder: ecs.Slot, res: *const assets_buffs.TriggeredResult, instigator_id: i32) void {
    if (res.add_aoe_n == 0) return;
    if (!self.sim.mask[holder].transform) return;
    const vp = self.sim.transform[holder];
    var s: ecs.Slot = 0;
    while (s < ecs.world.max_entities) : (s += 1) {
        if (s == holder) continue;
        // Candidates are live damageable entities: players always qualify;
        // zombies/animals qualify even without a buff set yet (addCatalogBuff
        // attaches it). Anything else (turrets, bags) is skipped.
        if (!self.sim.alive[s] or !self.sim.mask[s].transform) continue;
        if (!self.sim.mask[s].player and (!self.sim.mask[s].kind or (self.sim.kind[s] != .zombie and self.sim.kind[s] != .animal))) continue;
        const p = self.sim.transform[s];
        const dx = p.x - vp.x;
        const dz = p.z - vp.z;
        const d = @sqrt(dx * dx + dz * dz);
        for (res.add_aoe_buffs[0..res.add_aoe_n], res.add_aoe_range[0..res.add_aoe_n], res.add_aoe_tags[0..res.add_aoe_n]) |names, range, tags| {
            if (d > range) continue;
            if (tags.len > 0) {
                const ct = entityClassTags(self, s) orelse continue;
                if (!tagListHas(tags, ct)) continue;
            }
            const eid = if (self.sim.mask[s].network_id) self.sim.network_id[s].id else -1;
            var it = std.mem.splitScalar(u8, names, ',');
            while (it.next()) |seg| {
                const name = std.mem.trim(u8, seg, " \t");
                if (name.len == 0) continue;
                _ = addCatalogBuff(self, eid, s, name, instigator_id);
            }
        }
    }
}

/// True when any comma-separated tag in `filter` appears in the entity's
/// comma-separated class `tags` (case-insensitive, trimmed).
fn tagListHas(filter: []const u8, tags: []const u8) bool {
    var fi = std.mem.splitScalar(u8, filter, ',');
    while (fi.next()) |f| {
        const want = std.mem.trim(u8, f, " \t");
        if (want.len == 0) continue;
        var ti = std.mem.splitScalar(u8, tags, ',');
        while (ti.next()) |t| {
            if (std.ascii.eqlIgnoreCase(want, std.mem.trim(u8, t, " \t"))) return true;
        }
    }
    return false;
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
        applyCommaBuffs(s.game, s.entity_id, s.ps, name);
    }

    fn remove(ctx: *const anyopaque, name: []const u8) void {
        const s: *const BuffSink = @ptrCast(@alignCast(ctx));
        var it = std.mem.splitScalar(u8, name, ',');
        while (it.next()) |seg| {
            const n = std.mem.trim(u8, seg, " \t");
            if (n.len == 0) continue;
            const def_id = s.game.buffs.indexOfName(n) orelse continue;
            _ = ecs.buff.remove(s.game.sim.buffsMut(s.ps), def_id);
        }
    }

    fn has(ctx: *const anyopaque, name: []const u8) bool {
        const s: *const BuffSink = @ptrCast(@alignCast(ctx));
        const def_id = s.game.buffs.indexOfName(name) orelse return false;
        return s.game.sim.buffs[s.ps].find(def_id) != null;
    }

    /// Victim-directed sink half: the same add/remove against the event's
    /// other slot (the BuffSink already points at the victim).
    fn addOther(ctx: *const anyopaque, name: []const u8) void {
        const s: *const BuffSink = @ptrCast(@alignCast(ctx));
        if (!s.game.sim.mask[s.ps].buffs) return;
        applyCommaBuffs(s.game, s.entity_id, s.ps, name);
    }

    fn removeOther(ctx: *const anyopaque, name: []const u8) void {
        remove(ctx, name);
    }
};

/// Apply a (possibly comma-separated) AddBuff `buff=` list: stock splits on
/// comma (MinEventActionBuffModifierBase ParseXmlAttribute IL splits char
/// 44); each name resolves alone so a renamed modlet buff fails closed
/// without dropping its siblings.
pub fn applyCommaBuffs(game: *Game, entity_id: i32, ps: ecs.Slot, name: []const u8) void {
    var it = std.mem.splitScalar(u8, name, ',');
    while (it.next()) |seg| {
        const n = std.mem.trim(u8, seg, " \t");
        if (n.len == 0) continue;
        _ = addCatalogBuff(game, entity_id, ps, n, entity_id);
    }
}

/// Add one catalog buff to the entity's set unless it is already active, and
/// relay the add. Returns whether it was added. Unknown names are skipped (fail
/// closed), like every other data-bound lookup.
/// Add a buff by catalog name to a player's sim slot and relay it (the loot
/// `buffs=` sink and the class-buff path share this).
/// Skill ledger for a living player entity (Physician `target=instigator`).
/// Null when the entity is not a joined client.
pub fn skillLevelsForEntity(self: *Game, entity_id: i32) ?[]const requirements.NameLevel {
    if (entity_id < 0) return null;
    for (&self.clients) |*c| {
        if (!c.joined or c.entity_id != entity_id) continue;
        return c.skill_levels[0..c.skill_level_n];
    }
    return null;
}

/// Skill ledger for a sim slot (ProgressionLevel target=other on damage).
fn skillLevelsForSlot(self: *Game, ps: ecs.Slot) ?[]const requirements.NameLevel {
    if (!self.sim.mask[ps].network_id) return null;
    return skillLevelsForEntity(self, self.sim.network_id[ps].id);
}

/// BuffResistance (passive 197) for one entity against an incoming buff's
/// NameTag: stock `EntityBuffs::HasImmunity` reads GetValue(197) over the
/// incoming tag, clamped 0..1 (PainTolerance vs stuns). Buff + perk legs.
fn buffResist(self: *Game, ps: ecs.Slot, name_tag: []const u8) f32 {
    const peer_slot = self.sim.player[ps].peer_slot;
    if (peer_slot < 0 or @as(usize, @intCast(peer_slot)) >= self.clients.len) return 0;
    const c = &self.clients[@intCast(peer_slot)];
    var counts: requirements.Counts = .{};
    const ctx: requirements.Ctx = .{
        .levels = c.skill_levels[0..c.skill_level_n],
        .player_level = c.level,
        .tags = name_tag,
    };
    var v = assets_buffs.namedBuffFold(&self.buffs, &self.sim.buffs[ps], "BuffResistance", 0.0, ctx, &counts);
    v = assets_progression.namedPerkFold(&self.progression_table, c.skill_levels[0..c.skill_level_n], "BuffResistance", v, ctx, &counts);
    self.harness.counters.add(.requirement_gates, counts.resolved);
    self.harness.counters.add(.requirement_unsupported, counts.unsupported);
    return std.math.clamp(v, 0, 1);
}

pub fn addCatalogBuff(self: *Game, entity_id: i32, ps: ecs.Slot, name: []const u8, instigator_id: i32) bool {
    const def_id = self.buffs.indexOfName(name) orelse return false;
    const def = self.buffs.byId(def_id) orelse return false;
    // BuffResistance gate: refuse the add when the resist draw wins.
    // Deterministic draw off entity id + buff id (same hash-roll policy as
    // the dismember/loot legs); a zero resist never refuses. The query tag
    // is the buff's own name (NameTag = lowercased buff name at parse).
    const resist = buffResist(self, ps, def.name);
    if (resist > 0) {
        var h: u64 = @bitCast(@as(i64, entity_id));
        h = h *% 1103515245 +% def_id +% 12345;
        h = (h >> 16) ^ h;
        if (@as(f32, @floatFromInt(h % 100000)) / 100000.0 < resist) return false;
    }
    const set = self.sim.buffsMut(ps);
    // Stock fires `onSelfBuffStack` when AddBuff lands on an instance that
    // is already active (42 buffs / 93 rows, mostly ModifyCVar chains like
    // harvest bonus). The stack rows evaluate with the live ctx so their
    // cvar writes land.
    if (set.find(def_id) != null) {
        self.fireBuffStack(ps, def_id);
        return false;
    }
    // Physician heal buffs: ProgressionLevel target=instigator reads the
    // healer's ledger via BuffInstance.instigator_id (default -1 = none).
    _ = ecs.buff.add(set, .{
        .def_id = def_id,
        .duration = def.duration,
        .stack_type = def.stack_type,
        .update_rate_ticks = def.update_rate_ticks,
        .remove_on_death = def.remove_on_death,
    }, ecs.buff.duration_from_class, instigator_id, 0, 0, 0);
    game_social.relayBuff(self, entity_id, def.name, true, instigator_id, null) catch {};
    // Mobs run no survival pass, so their start rows fire here (players
    // cover start rows there; firing here too would double-apply).
    if (!self.sim.mask[ps].player) {
        fireMobBuffStart(self, ps, def_id);
    }
    return true;
}

/// Fire a buff's `onSelfBuffStack` rows when AddBuff lands on an active
/// instance. Shares the PlayerCtx builder; cvar rows apply through the ctx
/// store, AddBuff/RemoveBuff through the sink.
pub fn fireBuffStack(self: *Game, ps: ecs.Slot, def_id: u16) void {
    fireBuffEvent(self, ps, def_id, .stack, null);
}

/// Fire a mob buff's `onSelfBuffStart` rows at add time (burning duration
/// seed, wound-table side effects). Players run start rows through the
/// survival pass; mobs have no such driver, so adds evaluate them here.
/// Uses the victim's own cvar store; granted buffs apply silently (mob
/// buffs have no S2C buff-list sync).
pub fn fireMobBuffStart(self: *Game, vs: ecs.Slot, def_id: u16) void {
    self.fireMobBuffEvent(vs, def_id, .start);
}

/// Fire a mob buff's rows for any event (remove/finish on expiry) with the
/// victim's own store. Granted buffs apply silently through addCatalogBuff
/// (which itself fires their start rows); removals flag for the buff-tick
/// reap.
pub fn fireMobBuffEvent(self: *Game, vs: ecs.Slot, def_id: u16, event: assets_buffs.Trigger) void {
    var req_counts: requirements.Counts = .{};
    var ctx = requirements.Ctx{ .alive = self.sim.alive[vs] };
    ctx.cvars = self.sim.cvarsMut(vs);
    const res = assets_buffs.evaluateTriggered(&self.buffs, def_id, event, ctx, &req_counts);
    if (res.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, res.truncated);
    const vid = if (self.sim.mask[vs].network_id) self.sim.network_id[vs].id else -1;
    const set = self.sim.buffsMut(vs);
    for (res.remove_buffs[0..res.remove_n]) |names| {
        var it = std.mem.splitScalar(u8, names, ',');
        while (it.next()) |seg| {
            const name = std.mem.trim(u8, seg, " \t");
            if (name.len == 0) continue;
            const rid = self.buffs.indexOfName(name) orelse continue;
            _ = ecs.buff.remove(set, rid);
        }
    }
    for (res.add_buffs[0..res.add_n]) |names| {
        var it = std.mem.splitScalar(u8, names, ',');
        while (it.next()) |seg| {
            const name = std.mem.trim(u8, seg, " \t");
            if (name.len == 0) continue;
            _ = addCatalogBuff(self, vid, vs, name, vid);
        }
    }
    self.harness.counters.add(.requirement_gates, req_counts.resolved);
    self.harness.counters.add(.requirement_unsupported, req_counts.unsupported);
}
/// for a non-player victim. The class resolves by the slot's class hash;
/// zombie cvars attach lazily like buffs. Buff adds relay to trackers.
pub fn fireClassRows(self: *Game, vs: ecs.Slot, event: assets_buffs.Trigger) void {
    const hash = self.sim.class_id[vs].hash;
    if (hash == 0) return;
    const def = self.entities.byHash(hash) orelse return;
    if (def.triggered.len == 0) return;
    var req_counts: requirements.Counts = .{};
    var ctx = requirements.Ctx{
        .entity_tags = def.tags,
        .alive = self.sim.alive[vs],
    };
    if (self.sim.mask[vs].health) {
        const vh = &self.sim.health[vs];
        if (vh.max_hp > 0) {
            ctx.hp_frac = @max(0, @min(vh.hp / vh.max_hp, 1));
            ctx.hp_max = vh.max_hp;
        }
    }
    ctx.other_cvars = self.sim.cvarsMut(vs);
    // Cvar rows write the victim's own store directly (no client merge).
    ctx.cvars = self.sim.cvarsMut(vs);
    const res = assets_buffs.evaluateRows(def.triggered, event, ctx, &req_counts);
    if (res.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, res.truncated);
    const vid = if (self.sim.mask[vs].network_id) self.sim.network_id[vs].id else -1;
    for (res.add_buffs[0..res.add_n]) |names| {
        var it = std.mem.splitScalar(u8, names, ',');
        while (it.next()) |seg| {
            const name = std.mem.trim(u8, seg, " \t");
            if (name.len == 0) continue;
            _ = addCatalogBuff(self, vid, vs, name, vid);
        }
    }
    self.harness.counters.add(.requirement_gates, req_counts.resolved);
    self.harness.counters.add(.requirement_unsupported, req_counts.unsupported);
}

/// Fire a victim buff's `onOtherAttackedSelf` rows when another entity lands
/// a hit (concussion/fatigue counters, PackMule display buff). The attacker's
/// tags ride `other_tags` so victim rows can filter on them.
pub fn fireAttackedSelf(self: *Game, ps: ecs.Slot, attacker: ecs.Slot, body_part: i16) void {
    const peer_slot = self.sim.player[ps].peer_slot;
    if (peer_slot < 0 or @as(usize, @intCast(peer_slot)) >= self.clients.len) return;
    const c = &self.clients[@intCast(peer_slot)];
    self.noteCombat(@intCast(peer_slot));
    const h = &self.sim.health[ps];
    var pctx: PlayerCtx = .{};
    pctx.init(self, c, ps);
    var sandbox_buf: [sandbox.max_groups]sandbox.Group = undefined;
    const sandbox_groups = sandbox_buf[0..sandbox.decode(self.sandbox_code, &sandbox_buf)];
    var req_counts: requirements.Counts = .{};
    var ctx = pctx.build(self, c, ps, h, sandbox_groups);
    ctx.other_tags = entityClassTags(self, attacker);
    // ProgressionLevel target=other reads the attacker's perk ledger.
    ctx.other_levels = skillLevelsForSlot(self, attacker);
    // IsAlive target=other reads the attacker's alive bit.
    ctx.other_alive = self.sim.alive[attacker];
    // HasBuff target=other reads the attacker's live buff set.
    var other_sink: BuffSink = .{
        .game = self,
        .entity_id = if (self.sim.mask[attacker].network_id) self.sim.network_id[attacker].id else -1,
        .ps = attacker,
    };
    ctx.other_live_buff = &other_sink;
    // `target="other"` rows apply to the attacker as the row passes
    // (symmetric with the attacker event; today's victim rows are all
    // self-directed, so this only prevents the next miss).
    var other_impl: BuffSink = .{
        .game = self,
        .entity_id = if (self.sim.mask[attacker].network_id) self.sim.network_id[attacker].id else -1,
        .ps = attacker,
    };
    ctx.other_sink = .{ .ctx = &other_impl, .add_buff = BuffSink.addOther, .remove_buff = BuffSink.removeOther };
    // IsCorpse / IsSleeping target=other (corpseRemoval / NightStalker).
    ctx.other_is_corpse = if (self.sim.mask[attacker].health) self.sim.health[attacker].corpse_seconds > 0 else false;
    ctx.other_is_sleeping = self.sim.mask[attacker].sleeper and !self.sim.sleeper[attacker].awake;
    // HitLocation (IL=27) reads params.DamageResponse.HitBodyPart.
    ctx.hit_body_part = body_part;
    // IsInstigator IL=17: Self is the victim, Instigator is the attacker → false.
    ctx.is_instigator = false;
    var buff_ids: [ecs.components.max_buffs_per_entity]u16 = undefined;
    const n = activeBuffIds(&self.sim.buffs[ps], &buff_ids).len;
    for (buff_ids[0..n]) |id| {
        const res = assets_buffs.evaluateTriggered(&self.buffs, id, .other_attacked_self, ctx, &req_counts);
        if (res.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, res.truncated);
        applyTriggeredBuffs(self, c.entity_id, ps, &res, c.entity_id);
        applyTriggeredBuffsOther(self, attacker, &res, c.entity_id);
    }
    // Progression victim rows (PackMule display buff): the victim's own
    // purchased perks fire on being hit, same gates as the buff leg.
    for (c.skill_levels[0..c.skill_level_n]) |sl| {
        const rows = progressionTriggeredRows(self, sl.name);
        if (rows.len == 0) continue;
        const res = assets_buffs.evaluateRows(rows, .other_attacked_self, ctx, &req_counts);
        if (res.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, res.truncated);
        applyTriggeredBuffs(self, c.entity_id, ps, &res, c.entity_id);
        applyTriggeredBuffsOther(self, attacker, &res, c.entity_id);
    }
    // The damage-apply event on the victim (`onOtherDamagedSelf`): BarBrawling
    // 6's rage grants on taking a fist hit, gated ItemHasTags + perk level.
    for (c.skill_levels[0..c.skill_level_n]) |sl| {
        const rows = progressionTriggeredRows(self, sl.name);
        if (rows.len == 0) continue;
        const res = assets_buffs.evaluateRows(rows, .other_damaged_self, ctx, &req_counts);
        if (res.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, res.truncated);
        applyTriggeredBuffs(self, c.entity_id, ps, &res, c.entity_id);
        applyTriggeredBuffsOther(self, attacker, &res, c.entity_id);
    }
    // Zombie-attacker hand rows: the attacker's class `hand_item` (e.g.
    // meleeHandZombie01) carries `onSelfAttackedOther` procs that land on the
    // player victim (infectionCounter add, melee-wound buffs). Here `other`
    // is the player, so remap the foreign fills onto the victim and apply the
    // target=other results to the player.
    if (self.sim.mask[attacker].class_id or self.sim.kind[attacker] == .zombie or self.sim.kind[attacker] == .animal) {
        if (attackerHandTriggers(self, attacker)) |rows| {
            var ic = ctx;
            ic.other_tags = entityClassTags(self, ps);
            ic.other_alive = self.sim.alive[ps];
            var victim_sink: BuffSink = .{
                .game = self,
                .entity_id = if (self.sim.mask[ps].network_id) self.sim.network_id[ps].id else -1,
                .ps = ps,
            };
            ic.other_live_buff = &victim_sink;
            var victim_impl: BuffSink = .{
                .game = self,
                .entity_id = if (self.sim.mask[ps].network_id) self.sim.network_id[ps].id else -1,
                .ps = ps,
            };
            ic.other_sink = .{ .ctx = &victim_impl, .add_buff = BuffSink.addOther, .remove_buff = BuffSink.removeOther };
            ic.other_cvars = &c.cvars;
            const hres = assets_buffs.evaluateRows(rows, .self_attacked_other, ic, &req_counts);
            if (hres.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, hres.truncated);
            applyTriggeredBuffsOther(self, ps, &hres, attackerId(self, attacker));
        }
    }
    self.harness.counters.add(.requirement_gates, req_counts.resolved);
    self.harness.counters.add(.requirement_unsupported, req_counts.unsupported);
}

/// The attacker class's `hand_item` triggered rows for the victim event
/// (zombie fists carry onSelfAttackedOther infection/wound procs). Null when
/// the slot has no class or its hand item has no rows.
fn attackerHandTriggers(self: *Game, attacker: ecs.Slot) ?[]const assets_buffs.Triggered {
    const hash = if (self.sim.mask[attacker].class_id and self.sim.class_id[attacker].hash != 0)
        self.sim.class_id[attacker].hash
    else
        packages.stock_entity.class_zombie_default;
    const cdef = self.entities.byHash(hash) orelse return null;
    if (cdef.hand_item.len == 0) return null;
    const idef = self.items.byName(cdef.hand_item) orelse return null;
    if (idef.triggered.len == 0) return null;
    return idef.triggered;
}

/// Net id for a victim-directed add's instigator (the attacker).
fn attackerId(self: *Game, attacker: ecs.Slot) i32 {
    return if (self.sim.mask[attacker].network_id) self.sim.network_id[attacker].id else -1;
}

/// Attacker-side hit trigger: fires the attacker's `onSelfAttackedOther`
/// buff + progression rows with `params.DamageResponse.HitBodyPart` so
/// HitLocation gates (headshot/leg procs) evaluate. Victim tags ride
/// `other_tags`. ponytail: items.xml AttackedOther rows stay unparsed until
/// the item triggered surface lands; progression + buff catalogs cover the
/// stock HitLocation gates that matter for perk behaviour.
pub fn fireAttackedOther(self: *Game, ps: ecs.Slot, victim: ecs.Slot, body_part: i16) void {
    const peer_slot = self.sim.player[ps].peer_slot;
    if (peer_slot < 0 or @as(usize, @intCast(peer_slot)) >= self.clients.len) return;
    const c = &self.clients[@intCast(peer_slot)];
    self.noteCombat(@intCast(peer_slot));
    const h = &self.sim.health[ps];
    var pctx: PlayerCtx = .{};
    pctx.init(self, c, ps);
    var sandbox_buf: [sandbox.max_groups]sandbox.Group = undefined;
    const sandbox_groups = sandbox_buf[0..sandbox.decode(self.sandbox_code, &sandbox_buf)];
    var req_counts: requirements.Counts = .{};
    var ctx = pctx.build(self, c, ps, h, sandbox_groups);
    ctx.other_tags = entityClassTags(self, victim);
    projectVictimAlert(self, &ctx, victim);
    // `ItemHasTags` reads the attacker's held-item tags (params.ItemValue):
    // the Boomstick stun rows require a Boomstick-tagged gun in hand.
    if (self.sim.mask[ps].inventory) {
        const held = self.sim.inventory[ps].heldItem();
        if (held.count > 0) {
            if (self.items.byId(held.item_id)) |def| ctx.item_tags = def.tags;
        }
    }
    // ProgressionLevel target=other reads the victim's perk ledger.
    ctx.other_levels = skillLevelsForSlot(self, victim);
    // IsAlive target=other reads the victim's alive bit.
    ctx.other_alive = self.sim.alive[victim];
    // HasBuff target=other reads the victim's live buff set.
    var other_sink: BuffSink = .{
        .game = self,
        .entity_id = if (self.sim.mask[victim].network_id) self.sim.network_id[victim].id else -1,
        .ps = victim,
    };
    ctx.other_live_buff = &other_sink;
    // `target="other"` AddBuff/RemoveBuff rows apply to the victim as the
    // row passes (shotgun stuns, cripples, bleeds).
    var other_impl: BuffSink = .{
        .game = self,
        .entity_id = if (self.sim.mask[victim].network_id) self.sim.network_id[victim].id else -1,
        .ps = victim,
    };
    ctx.other_sink = .{ .ctx = &other_impl, .add_buff = BuffSink.addOther, .remove_buff = BuffSink.removeOther };
    // `target="other"` ModifyCVar/RemoveCVar rows write the victim's store:
    // players use their client store, zombies/others a lazy per-entity column
    // (bleed/sprain escalation counters, exactly stock EntityBuffs cvars).
    if (self.sim.mask[victim].player) {
        const vpeer = self.sim.player[victim].peer_slot;
        if (vpeer >= 0 and @as(usize, @intCast(vpeer)) < self.clients.len) {
            ctx.other_cvars = &self.clients[@intCast(vpeer)].cvars;
        }
    } else {
        ctx.other_cvars = self.sim.cvarsMut(victim);
    }
    // IsCorpse / IsSleeping target=other (corpseRemoval / NightStalker).
    ctx.other_is_corpse = if (self.sim.mask[victim].health) self.sim.health[victim].corpse_seconds > 0 else false;
    ctx.other_is_sleeping = self.sim.mask[victim].sleeper and !self.sim.sleeper[victim].awake;
    // TargetRange target=other (PistolPete/LimbShot ≤3 m): self-to-victim
    // distance when both transforms exist.
    if (self.sim.mask[ps].transform and self.sim.mask[victim].transform) {
        const a = self.sim.transform[ps];
        const b = self.sim.transform[victim];
        const dx = a.x - b.x;
        const dz = a.z - b.z;
        ctx.other_distance = @sqrt(dx * dx + dz * dz);
    }
    // StatCompare target=other (PulverizingFinishers ≤30%, PartyStarter
    // full-HP): the victim's Health fraction/max when it has health.
    if (self.sim.mask[victim].health) {
        const vh = &self.sim.health[victim];
        if (vh.max_hp > 0) {
            ctx.other_hp_frac = @max(0, @min(vh.hp / vh.max_hp, 1));
            ctx.other_hp_max = vh.max_hp;
        }
    }
    ctx.hit_body_part = body_part;
    // IsInstigator IL=17: Self is the attacker == Instigator → true.
    ctx.is_instigator = true;
    fireHitRows(self, c, ps, victim, &ctx, &req_counts, .self_attacked_other);
    // The landed hit also fires the damage-apply event: Agility leg-cripple,
    // Physician euthanizer (stun-baton instant kill) ride onSelfDamagedOther,
    // gated on the same ctx (the damage was applied by this hit).
    fireHitRows(self, c, ps, victim, &ctx, &req_counts, .self_damaged_other);
    self.harness.counters.add(.requirement_gates, req_counts.resolved);
    self.harness.counters.add(.requirement_unsupported, req_counts.unsupported);
}

/// The three hit-row passes (buff set, purchased perks, held item) at one
/// trigger; both the melee (`onSelfAttackedOther`) and ranged
/// (`onSelfPrimaryActionRayHit`) hit paths share it.
fn fireHitRows(
    self: *Game,
    c: *Client,
    ps: ecs.Slot,
    victim: ecs.Slot,
    ctx: *const requirements.Ctx,
    req_counts: *requirements.Counts,
    trigger: assets_buffs.Trigger,
) void {
    var counts = req_counts.*;
    var buff_ids: [ecs.components.max_buffs_per_entity]u16 = undefined;
    const n = activeBuffIds(&self.sim.buffs[ps], &buff_ids).len;
    for (buff_ids[0..n]) |id| {
        const res = assets_buffs.evaluateTriggered(&self.buffs, id, trigger, ctx.*, &counts);
        if (res.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, res.truncated);
        applyKillMods(self, ps, &res);
        applyTriggeredBuffsFull(self, c.entity_id, ps, &res, c.entity_id, false);
        applyTriggeredBuffsOther(self, victim, &res, c.entity_id);
    }
    for (c.skill_levels[0..c.skill_level_n]) |sl| {
        const rows = progressionTriggeredRows(self, sl.name);
        if (rows.len == 0) continue;
        const res = assets_buffs.evaluateRows(rows, trigger, ctx.*, &counts);
        if (res.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, res.truncated);
        applyKillMods(self, ps, &res);
        applyTriggeredBuffsFull(self, c.entity_id, ps, &res, c.entity_id, false);
        applyTriggeredBuffsOther(self, victim, &res, c.entity_id);
    }
    if (self.sim.mask[ps].inventory) {
        const held = self.sim.inventory[ps].heldItem();
        if (held.count > 0) {
            if (self.items.byId(held.item_id)) |def| {
                const ires = assets_buffs.evaluateRows(def.triggered, trigger, ctx.*, &counts);

                if (ires.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, ires.truncated);
                applyKillMods(self, ps, &ires);
                applyTriggeredBuffsFull(self, c.entity_id, ps, &ires, c.entity_id, false);
                applyTriggeredBuffsOther(self, victim, &ires, c.entity_id);
                // Installed mods' damage rows (cripple/burn/bleed procs):
                // same ctx, mod quality answering RequirementItemModTier.
                var mod_buf: [4]requirements.NameLevel = undefined;
                for (held.mods) |mod_id| {
                    if (mod_id == 0) continue;
                    const mdef = self.items.byId(mod_id) orelse continue;
                    const mrows = self.item_mods.byName(mdef.name) orelse continue;
                    if (mrows.triggered.len == 0) continue;
                    var mctx = ctx.*;
                    mctx.item_mods = fillItemMods(self, held.mods, held.mod_qualities, &mod_buf);
                    const mres = assets_buffs.evaluateRows(mrows.triggered, trigger, mctx, &counts);
                    if (mres.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, mres.truncated);
                    applyKillMods(self, ps, &mres);
                    applyTriggeredBuffsFull(self, c.entity_id, ps, &mres, c.entity_id, false);
                    applyTriggeredBuffsOther(self, victim, &mres, c.entity_id);
                }
            }
        }
    }
    req_counts.* = counts;
}

/// Ranged hit trigger: `onSelfPrimaryActionRayHit`. The C2S damage claim does
/// not carry melee-vs-ranged, so the held weapon's `ranged` tag selects this
/// path (guns/bows/crossbows); the DeepCuts/perception bleed rows land on the
/// victim like the melee procs. Shares the hit-row passes.
pub fn fireRayHit(self: *Game, ps: ecs.Slot, victim: ecs.Slot, body_part: i16) void {
    const peer_slot = self.sim.player[ps].peer_slot;
    if (peer_slot < 0 or @as(usize, @intCast(peer_slot)) >= self.clients.len) return;
    const c = &self.clients[@intCast(peer_slot)];
    self.noteCombat(@intCast(peer_slot));
    const h = &self.sim.health[ps];
    var pctx: PlayerCtx = .{};
    pctx.init(self, c, ps);
    var sandbox_buf: [sandbox.max_groups]sandbox.Group = undefined;
    const sandbox_groups = sandbox_buf[0..sandbox.decode(self.sandbox_code, &sandbox_buf)];
    var req_counts: requirements.Counts = .{};
    var ctx = pctx.build(self, c, ps, h, sandbox_groups);
    ctx.other_tags = entityClassTags(self, victim);
    projectVictimAlert(self, &ctx, victim);
    if (self.sim.mask[ps].inventory) {
        const held = self.sim.inventory[ps].heldItem();
        if (held.count > 0) {
            if (self.items.byId(held.item_id)) |def| ctx.item_tags = def.tags;
        }
    }
    ctx.other_levels = skillLevelsForSlot(self, victim);
    ctx.other_alive = self.sim.alive[victim];
    var other_sink: BuffSink = .{
        .game = self,
        .entity_id = if (self.sim.mask[victim].network_id) self.sim.network_id[victim].id else -1,
        .ps = victim,
    };
    ctx.other_live_buff = &other_sink;
    var other_impl: BuffSink = .{
        .game = self,
        .entity_id = if (self.sim.mask[victim].network_id) self.sim.network_id[victim].id else -1,
        .ps = victim,
    };
    ctx.other_sink = .{ .ctx = &other_impl, .add_buff = BuffSink.addOther, .remove_buff = BuffSink.removeOther };
    if (self.sim.mask[victim].player) {
        const vpeer = self.sim.player[victim].peer_slot;
        if (vpeer >= 0 and @as(usize, @intCast(vpeer)) < self.clients.len) {
            ctx.other_cvars = &self.clients[@intCast(vpeer)].cvars;
        }
    } else {
        ctx.other_cvars = self.sim.cvarsMut(victim);
    }
    ctx.other_is_corpse = if (self.sim.mask[victim].health) self.sim.health[victim].corpse_seconds > 0 else false;
    ctx.other_is_sleeping = self.sim.mask[victim].sleeper and !self.sim.sleeper[victim].awake;
    if (self.sim.mask[ps].transform and self.sim.mask[victim].transform) {
        const a = self.sim.transform[ps];
        const b = self.sim.transform[victim];
        const dx = a.x - b.x;
        const dz = a.z - b.z;
        ctx.other_distance = @sqrt(dx * dx + dz * dz);
    }
    if (self.sim.mask[victim].health) {
        const vh = &self.sim.health[victim];
        if (vh.max_hp > 0) {
            ctx.other_hp_frac = @max(0, @min(vh.hp / vh.max_hp, 1));
            ctx.other_hp_max = vh.max_hp;
        }
    }
    ctx.hit_body_part = body_part;
    ctx.is_instigator = true;
    fireHitRows(self, c, ps, victim, &ctx, &req_counts, .primary_action_ray_hit);
    fireHitRows(self, c, ps, victim, &ctx, &req_counts, .self_damaged_other);
    self.harness.counters.add(.requirement_gates, req_counts.resolved);
    self.harness.counters.add(.requirement_unsupported, req_counts.unsupported);
}

/// Held weapon is ranged (`ranged` tag), for the C2S damage-path branch.
pub fn heldWeaponIsRanged(self: *const Game, ps: ecs.Slot) bool {
    if (!self.sim.mask[ps].inventory) return false;
    const inv = &self.sim.inventory[ps];
    if (inv.holding >= ecs.components.inv_toolbelt) return false;
    const s = inv.slots[inv.holding];
    if (s.count == 0 or s.item_id == 0) return false;
    const def = self.items.byId(s.item_id) orelse return false;
    return tagListHas("ranged", def.tags);
}

/// Killer-side kill trigger: fires the killer's `onSelfKilledOther` buff +
/// progression rows when one of its hits kills (DeadEye/Berserker adds, the
/// stamina/health ModifyStats refunds). Victim tags ride `other_tags` so rows
/// can filter on them; `delay=` rows (21 kill stamina refunds at 1.0 s)
/// defer onto the client's pending queue.
/// The eaten item's `onSelfPrimaryActionEnd` rows: consumable grants (beer /
/// coffee / drug buffs, goldenrod dysentery cure, medical heal) land on the
/// eater after a successful consume. The food/water/HP ModifyCVar pool rows
/// are skipped — the eat path applies EatProps directly, so firing the pool
/// writes here would double-restore. AddBuff/RemoveBuff/CallGameEvent apply.
pub fn fireItemUseBuffs(self: *Game, ps: ecs.Slot, item_id: u16) void {
    const peer_slot = self.sim.player[ps].peer_slot;
    if (peer_slot < 0 or @as(usize, @intCast(peer_slot)) >= self.clients.len) return;
    const c = &self.clients[@intCast(peer_slot)];
    if (item_id == 0) return;
    const def = self.items.byId(item_id) orelse return;
    if (def.triggered.len == 0) return;
    const h = &self.sim.health[ps];
    var pctx: PlayerCtx = .{};
    pctx.init(self, c, ps);
    var sandbox_buf: [sandbox.max_groups]sandbox.Group = undefined;
    const sandbox_groups = sandbox_buf[0..sandbox.decode(self.sandbox_code, &sandbox_buf)];
    var req_counts: requirements.Counts = .{};
    var ctx = pctx.build(self, c, ps, h, sandbox_groups);
    // The item rows write both the consumable buff's own duration cvars
    // (`$buffBeerDuration` etc., which the buff's update rows drain to expire
    // it) and the food/water/HP pools (`$foodAmountAdd`, foodHealthAmount,
    // medicalRegHealthAmount) that buffProcessConsumables drains over time.
    // The eat path owns the pool effect through instant EatProps, so evaluate
    // against a scratch copy and merge only the non-pool writes back — the
    // duration cvars land and the pools stay absent, so a beer wears off and
    // food does not double-restore.
    var scratch = c.cvars;
    ctx.cvars = &scratch;
    const res = assets_buffs.evaluateRows(def.triggered, .primary_action_end, ctx, &req_counts);
    if (res.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, res.truncated);
    for (scratch.entries[0..scratch.n]) |entry| {
        if (isConsumePoolCvar(entry.name)) continue;
        _ = c.cvars.apply(entry.name, .set, entry.value);
    }
    applyTriggeredBuffsFull(self, c.entity_id, ps, &res, c.entity_id, false);
    // Gated `GiveExp` rows sum here (bandage 10 + Physician tier bonus);
    // this replaces the flat first-GiveExp award, which ignored the gates.
    if (res.give_exp > 0) self.awardXp(@intCast(peer_slot), res.give_exp);
    // Grandpa's Forgetting Elixir: `ResetProgression` resets skills and
    // refunds points server-side (the client's respec UI reads the result).
    if (res.reset_progression) self.resetProgression(@intCast(peer_slot));
    self.harness.counters.add(.requirement_gates, req_counts.resolved);
    self.harness.counters.add(.requirement_unsupported, req_counts.unsupported);
}

/// The food/water/HP pool cvars the eat path replaces with instant EatProps;
/// their writes are withheld from the merge so buffProcessConsumables cannot
/// double-drain a seeded pool.
fn isConsumePoolCvar(name: []const u8) bool {
    return std.mem.eql(u8, name, "$foodAmountAdd") or
        std.mem.eql(u8, name, "$waterAmountAdd") or
        std.mem.eql(u8, name, "foodHealthAmount") or
        std.mem.eql(u8, name, "medicalRegHealthAmount") or
        std.mem.eql(u8, name, "medRegHealthIncSpeed");
}

/// Combat timer + the out-of-combat -> in-combat transition: refresh the
/// idle window on every dealt/received damage; on the 0 -> active edge fire
/// the combat_entered progression rows (Enforcer Criminal Pursuit etc.).
pub fn noteCombat(self: *Game, slot: usize) void {
    if (slot >= self.clients.len) return;
    const c = &self.clients[slot];
    const was_out = c.combat_remaining_ticks == 0;
    c.combat_remaining_ticks = 100; // stock IsInCombat window ~5 s at 20 TPS
    if (!was_out) return;
    const ps = self.sim.playerByPeer(slot) orelse return;
    if (!self.sim.mask[ps].health or !self.sim.mask[ps].transform) return;
    const h = &self.sim.health[ps];
    var pctx: PlayerCtx = .{};
    pctx.init(self, c, ps);
    var sandbox_buf: [sandbox.max_groups]sandbox.Group = undefined;
    const sandbox_groups = sandbox_buf[0..sandbox.decode(self.sandbox_code, &sandbox_buf)];
    var req_counts: requirements.Counts = .{};
    var ctx = pctx.build(self, c, ps, h, sandbox_groups);
    // The ItemHasTags gates (Enforcer magnum, Club PummelPete) read the held
    // weapon's tags at combat entry, like the hit paths.
    if (self.sim.mask[ps].inventory) {
        const held = self.sim.inventory[ps].heldItem();
        if (held.count > 0) {
            if (self.items.byId(held.item_id)) |def| ctx.item_tags = def.tags;
        }
    }
    for (c.skill_levels[0..c.skill_level_n]) |sl| {
        const rows = progressionTriggeredRows(self, sl.name);
        if (rows.len == 0) continue;
        const res = assets_buffs.evaluateRows(rows, .combat_entered, ctx, &req_counts);
        if (res.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, res.truncated);
        applyTriggeredBuffs(self, c.entity_id, ps, &res, c.entity_id);
    }
    self.harness.counters.add(.requirement_gates, req_counts.resolved);
    self.harness.counters.add(.requirement_unsupported, req_counts.unsupported);
}

/// The jump buff rows (`onSelfJump`): the leg buffs' activity escalation
/// (buffLegGetsWorse, $legHurtCounter) fires when the client's move helper
/// starts a jump (AliveFlags 0x0010 edge; stock EntityAlive.set_Jumping
/// IL=46). Same shape as fireFallImpact: active buffs only, shared engine,
/// stat deltas applied inline.
pub fn fireJump(self: *Game, ps: ecs.Slot) void {
    const peer_slot = self.sim.player[ps].peer_slot;
    if (peer_slot < 0 or @as(usize, @intCast(peer_slot)) >= self.clients.len) return;
    const c = &self.clients[@intCast(peer_slot)];
    const h = &self.sim.health[ps];
    var pctx: PlayerCtx = .{};
    pctx.init(self, c, ps);
    var sandbox_buf: [sandbox.max_groups]sandbox.Group = undefined;
    const sandbox_groups = sandbox_buf[0..sandbox.decode(self.sandbox_code, &sandbox_buf)];
    var req_counts: requirements.Counts = .{};
    const ctx = pctx.build(self, c, ps, h, sandbox_groups);
    var buff_ids: [ecs.components.max_buffs_per_entity]u16 = undefined;
    const n = activeBuffIds(&self.sim.buffs[ps], &buff_ids).len;
    for (buff_ids[0..n]) |id| {
        const res = assets_buffs.evaluateTriggered(&self.buffs, id, .jump, ctx, &req_counts);
        if (res.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, res.truncated);
        applyTriggeredBuffs(self, c.entity_id, ps, &res, c.entity_id);
    }
    self.harness.counters.add(.requirement_gates, req_counts.resolved);
    self.harness.counters.add(.requirement_unsupported, req_counts.unsupported);
}

/// The aim/crouch flag edges (`onSelfAimingGunStart/Stop`, `onSelfCrouch`,
/// `onSelfStand`, `onSelfCrouchRun/Walk`): the client reports aim (0x0004)
/// and crouch (0x0200) in the AliveFlags word. Setting aim adds
/// buffHoldBreathAiming01 (gated `holdBreathAiming` held tag) and clearing
/// removes it; crouch set/clear adds/removes buffCrouching, whose start and
/// update rows apply the screen effect and whose own update row re-removes
/// it when `_crouching` reads 0. Same shape as fireJump.
pub fn fireAimEdge(self: *Game, ps: ecs.Slot, aiming: bool) void {
    fireFlagBuffEdge(self, ps, if (aiming) .aim_start else .aim_stop);
}

/// The crouch flag edge also drives the `_crouching` mirror write (a set
/// edge writes 1, a clear edge writes 0) before firing, so the buff's own
/// `_crouching`-gated update row resolves against the live value.
pub fn fireCrouchEdge(self: *Game, ps: ecs.Slot, crouching: bool) void {
    const peer_slot = self.sim.player[ps].peer_slot;
    if (peer_slot < 0 or @as(usize, @intCast(peer_slot)) >= self.clients.len) return;
    const c = &self.clients[@intCast(peer_slot)];
    _ = c.cvars.apply("_crouching", .set, if (crouching) 1 else 0);
    fireFlagBuffEdge(self, ps, if (crouching) .crouch else .stand);
}

fn fireFlagBuffEdge(self: *Game, ps: ecs.Slot, event: assets_buffs.Trigger) void {
    const peer_slot = self.sim.player[ps].peer_slot;
    if (peer_slot < 0 or @as(usize, @intCast(peer_slot)) >= self.clients.len) return;
    const c = &self.clients[@intCast(peer_slot)];
    const h = &self.sim.health[ps];
    var pctx: PlayerCtx = .{};
    pctx.init(self, c, ps);
    var sandbox_buf: [sandbox.max_groups]sandbox.Group = undefined;
    const sandbox_groups = sandbox_buf[0..sandbox.decode(self.sandbox_code, &sandbox_buf)];
    var req_counts: requirements.Counts = .{};
    var ctx = pctx.build(self, c, ps, h, sandbox_groups);
    // The aiming/crouch rows gate on the held item (`holdBreathAiming`
    // tags on buffHoldBreathAiming01): ride the held tags like the hit
    // events so the gate resolves.
    if (self.sim.mask[ps].inventory) {
        const held = self.sim.inventory[ps].heldItem();
        if (held.count > 0) {
            if (self.items.byId(held.item_id)) |def| ctx.item_tags = def.tags;
        }
    }
    var buff_ids: [ecs.components.max_buffs_per_entity]u16 = undefined;
    const n = activeBuffIds(&self.sim.buffs[ps], &buff_ids).len;
    for (buff_ids[0..n]) |id| {
        const res = assets_buffs.evaluateTriggered(&self.buffs, id, event, ctx, &req_counts);
        if (res.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, res.truncated);
        applyTriggeredBuffs(self, c.entity_id, ps, &res, c.entity_id);
    }
    self.harness.counters.add(.requirement_gates, req_counts.resolved);
    self.harness.counters.add(.requirement_unsupported, req_counts.unsupported);
}

/// The respawn buff rows (`onSelfRespawn`): stock fires it after the player
/// respawns. The only stock row is buffNearDeathProtection's self-remove;
/// fired in the respawn funnel after the check buffs are re-added so the
/// row resolves against the live set. Same shape as fireFallImpact.
pub fn fireRespawn(self: *Game, ps: ecs.Slot) void {
    const peer_slot = self.sim.player[ps].peer_slot;
    if (peer_slot < 0 or @as(usize, @intCast(peer_slot)) >= self.clients.len) return;
    const c = &self.clients[@intCast(peer_slot)];
    const h = &self.sim.health[ps];
    var pctx: PlayerCtx = .{};
    pctx.init(self, c, ps);
    var sandbox_buf: [sandbox.max_groups]sandbox.Group = undefined;
    const sandbox_groups = sandbox_buf[0..sandbox.decode(self.sandbox_code, &sandbox_buf)];
    var req_counts: requirements.Counts = .{};
    const ctx = pctx.build(self, c, ps, h, sandbox_groups);
    var buff_ids: [ecs.components.max_buffs_per_entity]u16 = undefined;
    const n = activeBuffIds(&self.sim.buffs[ps], &buff_ids).len;
    for (buff_ids[0..n]) |id| {
        const res = assets_buffs.evaluateTriggered(&self.buffs, id, .respawn, ctx, &req_counts);
        if (res.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, res.truncated);
        applyTriggeredBuffs(self, c.entity_id, ps, &res, c.entity_id);
    }
    self.harness.counters.add(.requirement_gates, req_counts.resolved);
    self.harness.counters.add(.requirement_unsupported, req_counts.unsupported);
}

/// The landing buff rows after a fall (`onSelfFallImpact`): the check buff's
/// leg-injury escalation (buffPlayerFallingDamage, $legHurtCounter,
/// buffLegGetsWorse) gates on `_fallSpeed`; the falling-damage claim's amount
/// approximates the impact speed that stock records on landing.
pub fn fireFallImpact(self: *Game, ps: ecs.Slot, impact_speed: f32) void {
    const peer_slot = self.sim.player[ps].peer_slot;
    if (peer_slot < 0 or @as(usize, @intCast(peer_slot)) >= self.clients.len) return;
    const c = &self.clients[@intCast(peer_slot)];
    _ = c.cvars.apply("_fallSpeed", .set, impact_speed);
    const h = &self.sim.health[ps];
    var pctx: PlayerCtx = .{};
    pctx.init(self, c, ps);
    var sandbox_buf: [sandbox.max_groups]sandbox.Group = undefined;
    const sandbox_groups = sandbox_buf[0..sandbox.decode(self.sandbox_code, &sandbox_buf)];
    var req_counts: requirements.Counts = .{};
    const ctx = pctx.build(self, c, ps, h, sandbox_groups);
    var buff_ids: [ecs.components.max_buffs_per_entity]u16 = undefined;
    const n = activeBuffIds(&self.sim.buffs[ps], &buff_ids).len;
    for (buff_ids[0..n]) |id| {
        const res = assets_buffs.evaluateTriggered(&self.buffs, id, .fall_impact, ctx, &req_counts);
        if (res.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, res.truncated);
        applyTriggeredBuffs(self, c.entity_id, ps, &res, c.entity_id);
    }
    self.harness.counters.add(.requirement_gates, req_counts.resolved);
    self.harness.counters.add(.requirement_unsupported, req_counts.unsupported);
}

/// The reload-start event: fire active buffs' `onReloadStart` rows (the
/// check buff grants buffReloadMovementPenalty while the held weapon
/// carries `reloadPenalty`). Held tags ride the ctx like the hit events.
pub fn fireReloadStart(self: *Game, ps: ecs.Slot) void {
    const peer_slot = self.sim.player[ps].peer_slot;
    if (peer_slot < 0 or @as(usize, @intCast(peer_slot)) >= self.clients.len) return;
    const c = &self.clients[@intCast(peer_slot)];
    const h = &self.sim.health[ps];
    var pctx: PlayerCtx = .{};
    pctx.init(self, c, ps);
    var sandbox_buf: [sandbox.max_groups]sandbox.Group = undefined;
    const sandbox_groups = sandbox_buf[0..sandbox.decode(self.sandbox_code, &sandbox_buf)];
    var req_counts: requirements.Counts = .{};
    var ctx = pctx.build(self, c, ps, h, sandbox_groups);
    ctx.held_tags = heldItemTags(self, ps);
    var buff_ids: [ecs.components.max_buffs_per_entity]u16 = undefined;
    const n = activeBuffIds(&self.sim.buffs[ps], &buff_ids).len;
    for (buff_ids[0..n]) |id| {
        const res = assets_buffs.evaluateTriggered(&self.buffs, id, .reload_start, ctx, &req_counts);
        if (res.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, res.truncated);
        applyTriggeredBuffs(self, c.entity_id, ps, &res, c.entity_id);
    }
    self.harness.counters.add(.requirement_gates, req_counts.resolved);
    self.harness.counters.add(.requirement_unsupported, req_counts.unsupported);
}
pub fn fireBlockDamaged(self: *Game, ps: ecs.Slot, block_id: u16) void {
    const peer_slot = self.sim.player[ps].peer_slot;
    if (peer_slot < 0 or @as(usize, @intCast(peer_slot)) >= self.clients.len) return;
    const c = &self.clients[@intCast(peer_slot)];
    const block_tags = if (self.blocks.byId(block_id)) |bd| bd.tags else "";
    const h = &self.sim.health[ps];
    var pctx: PlayerCtx = .{};
    pctx.init(self, c, ps);
    var sandbox_buf: [sandbox.max_groups]sandbox.Group = undefined;
    const sandbox_groups = sandbox_buf[0..sandbox.decode(self.sandbox_code, &sandbox_buf)];
    var req_counts: requirements.Counts = .{};
    var ctx = pctx.build(self, c, ps, h, sandbox_groups);
    ctx.trigger_tags = block_tags;
    var buff_ids: [ecs.components.max_buffs_per_entity]u16 = undefined;
    const n = activeBuffIds(&self.sim.buffs[ps], &buff_ids).len;
    for (buff_ids[0..n]) |id| {
        const res = assets_buffs.evaluateTriggered(&self.buffs, id, .block_damaged, ctx, &req_counts);
        if (res.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, res.truncated);
        applyTriggeredBuffs(self, c.entity_id, ps, &res, c.entity_id);
    }
    self.harness.counters.add(.requirement_gates, req_counts.resolved);
    self.harness.counters.add(.requirement_unsupported, req_counts.unsupported);
}

pub fn fireKilledOther(self: *Game, ps: ecs.Slot, victim: ecs.Slot) void {
    const peer_slot = self.sim.player[ps].peer_slot;
    if (peer_slot < 0 or @as(usize, @intCast(peer_slot)) >= self.clients.len) return;
    const c = &self.clients[@intCast(peer_slot)];
    const h = &self.sim.health[ps];
    var pctx: PlayerCtx = .{};
    pctx.init(self, c, ps);
    var sandbox_buf: [sandbox.max_groups]sandbox.Group = undefined;
    const sandbox_groups = sandbox_buf[0..sandbox.decode(self.sandbox_code, &sandbox_buf)];
    var req_counts: requirements.Counts = .{};
    var ctx = pctx.build(self, c, ps, h, sandbox_groups);
    ctx.other_tags = entityClassTags(self, victim);
    projectVictimAlert(self, &ctx, victim);
    // Foreign fills mirror the hit event (no stock kill row needs them yet;
    // symmetry so the next row lands instead of refusing): victim perk
    // ledger, alive bit, live buff set, corpse/sleeper bits, Health
    // fraction/max, and player-victim cvar store.
    ctx.other_levels = skillLevelsForSlot(self, victim);
    ctx.other_alive = self.sim.alive[victim];
    var kill_other_sink: BuffSink = .{
        .game = self,
        .entity_id = if (self.sim.mask[victim].network_id) self.sim.network_id[victim].id else -1,
        .ps = victim,
    };
    ctx.other_live_buff = &kill_other_sink;
    ctx.other_is_corpse = if (self.sim.mask[victim].health) self.sim.health[victim].corpse_seconds > 0 else false;
    ctx.other_is_sleeping = self.sim.mask[victim].sleeper and !self.sim.sleeper[victim].awake;
    if (self.sim.mask[victim].health) {
        const vh = &self.sim.health[victim];
        if (vh.max_hp > 0) {
            ctx.other_hp_frac = @max(0, @min(vh.hp / vh.max_hp, 1));
            ctx.other_hp_max = vh.max_hp;
        }
    }
    if (self.sim.mask[victim].player) {
        const vpeer = self.sim.player[victim].peer_slot;
        if (vpeer >= 0 and @as(usize, @intCast(vpeer)) < self.clients.len) {
            ctx.other_cvars = &self.clients[@intCast(vpeer)].cvars;
        }
    } else {
        ctx.other_cvars = self.sim.cvarsMut(victim);
    }
    // `ItemHasTags` reads the killer's held-item tags (params.ItemValue):
    // the SiphoningStrikes heal requires a melee weapon in hand.
    if (self.sim.mask[ps].inventory) {
        const held = self.sim.inventory[ps].heldItem();
        if (held.count > 0) {
            if (self.items.byId(held.item_id)) |def| ctx.item_tags = def.tags;
        }
    }
    var buff_ids: [ecs.components.max_buffs_per_entity]u16 = undefined;
    const n = activeBuffIds(&self.sim.buffs[ps], &buff_ids).len;
    for (buff_ids[0..n]) |id| {
        const res = assets_buffs.evaluateTriggered(&self.buffs, id, .killed_other, ctx, &req_counts);
        if (res.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, res.truncated);
        applyKillMods(self, ps, &res);
        applyTriggeredBuffsFull(self, c.entity_id, ps, &res, c.entity_id, false);
        applyTriggeredBuffsOther(self, victim, &res, c.entity_id);
        applyTriggeredBuffsAoe(self, ps, &res, c.entity_id);
    }
    for (c.skill_levels[0..c.skill_level_n]) |sl| {
        const rows = progressionTriggeredRows(self, sl.name);
        if (rows.len == 0) continue;
        const res = assets_buffs.evaluateRows(rows, .killed_other, ctx, &req_counts);
        if (res.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, res.truncated);
        applyKillMods(self, ps, &res);
        applyTriggeredBuffsFull(self, c.entity_id, ps, &res, c.entity_id, false);
        applyTriggeredBuffsOther(self, victim, &res, c.entity_id);
        applyTriggeredBuffsAoe(self, ps, &res, c.entity_id);
    }
    self.harness.counters.add(.requirement_gates, req_counts.resolved);
    self.harness.counters.add(.requirement_unsupported, req_counts.unsupported);
}

/// Apply a hit/kill trigger's immediate ModifyStats rows to the holder's own
/// bars. Only Health/Stamina `add` rows apply here; `subtract` rows stay on
/// their own paths (stage-3 drain) and `delay=` rows defer onto the pending
/// queue. Shared by the kill event (SiphoningStrikes heals) and the attacked
/// event (MachineGunner stamina, AdrenalineHealing health), whose mods were
/// previously evaluated but never applied.
fn applyKillMods(self: *Game, ps: ecs.Slot, res: *const assets_buffs.TriggeredResult) void {
    const peer_slot = self.sim.player[ps].peer_slot;
    const h = &self.sim.health[ps];
    for (res.mods[0..res.mod_n]) |m| {
        // Victim-directed rows belong to the other applier (euthanizer
        // set-to-kill); self rows here are Health/Stamina `add` only.
        if (m.target_other) continue;
        if (m.op != .add) continue;
        const is_health = std.ascii.eqlIgnoreCase(m.stat, "Health");
        const is_stamina = std.ascii.eqlIgnoreCase(m.stat, "Stamina");
        if (!is_health and !is_stamina) continue;
        // `delay=` rows (kill-event stamina at 1.0 s) defer onto the
        // client's pending queue, drained on the survival tick.
        if (m.delay_s > 0 and peer_slot >= 0 and @as(usize, @intCast(peer_slot)) < self.clients.len) {
            deferMod(self, @intCast(peer_slot), m.stat, m.value, m.delay_s);
            continue;
        }
        if (is_health) {
            if (h.hp > 0) h.hp = @min(h.max_hp, h.hp + m.value);
        } else {
            h.stamina = @min(h.stamina_max, @max(0, h.stamina + m.value));
        }
    }
    self.sim.markDirty(ps, .{ .hp = true });
}

/// Queue a delayed ModifyStats refund onto the client's pending slots
/// (stock coroutine; 20 ticks per second). A full row drops (bounded).
fn deferMod(self: *Game, slot: usize, stat: []const u8, value: f32, delay_s: f32) void {
    const c = &self.clients[slot];
    const due = self.tick_n + @as(u64, @intFromFloat(@max(1, delay_s * 20)));
    for (&c.pending_mods) |*p| {
        if (p.due_tick != 0) continue;
        const n = @min(stat.len, p.stat.len);
        @memcpy(p.stat[0..n], stat[0..n]);
        p.stat_len = @intCast(n);
        p.op_add = true;
        p.value = value;
        p.due_tick = due;
        return;
    }
    self.harness.counters.add(.triggered_rows_dropped, 1);
}

/// Drain due deferred mods onto the holder's bars (survival tick).
pub fn drainPendingMods(self: *Game, slot: usize, ps: ecs.Slot) void {
    const c = &self.clients[slot];
    const h = &self.sim.health[ps];
    var dirty = false;
    for (&c.pending_mods) |*p| {
        if (p.due_tick == 0 or self.tick_n < p.due_tick) continue;
        p.due_tick = 0;
        const stat = p.stat[0..p.stat_len];
        if (std.ascii.eqlIgnoreCase(stat, "Health")) {
            if (h.hp > 0) h.hp = @min(h.max_hp, h.hp + p.value);
        } else if (std.ascii.eqlIgnoreCase(stat, "Stamina")) {
            h.stamina = @min(h.stamina_max, @max(0, h.stamina + p.value));
        } else continue;
        dirty = true;
    }
    if (dirty) self.sim.markDirty(ps, .{ .hp = true });
}

/// A progression value's `triggered_effect` rows (attributes + perks).
fn progressionTriggeredRows(self: *const Game, name: []const u8) []const assets_buffs.Triggered {
    for (self.progression_table.attributes) |a| {
        if (std.mem.eql(u8, a.name, name)) return a.triggered;
    }
    for (self.progression_table.perks) |perk| {
        if (std.mem.eql(u8, perk.name, name)) return perk.triggered;
    }
    return &.{};
}

pub fn fireBuffEvent(self: *Game, ps: ecs.Slot, def_id: u16, event: assets_buffs.Trigger, other: ?ecs.Slot) void {
    const peer_slot = self.sim.player[ps].peer_slot;
    if (peer_slot < 0 or @as(usize, @intCast(peer_slot)) >= self.clients.len) return;
    const c = &self.clients[@intCast(peer_slot)];
    const h = &self.sim.health[ps];
    var pctx: PlayerCtx = .{};
    pctx.init(self, c, ps);
    var sandbox_buf: [sandbox.max_groups]sandbox.Group = undefined;
    const sandbox_groups = sandbox_buf[0..sandbox.decode(self.sandbox_code, &sandbox_buf)];
    var req_counts: requirements.Counts = .{};
    var ctx = pctx.build(self, c, ps, h, sandbox_groups);
    if (other) |o| ctx.other_tags = entityClassTags(self, o);
    const res = assets_buffs.evaluateTriggered(&self.buffs, def_id, event, ctx, &req_counts);
    self.harness.counters.add(.requirement_gates, req_counts.resolved);
    self.harness.counters.add(.requirement_unsupported, req_counts.unsupported);
    if (res.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, res.truncated);
    applyTriggeredBuffs(self, c.entity_id, ps, &res, c.entity_id);
}

/// Fire a buff's `onSelfBuffFinish` rows at expiry (stock: after
/// onSelfBuffRemove). Shares the PlayerCtx builder with the survival fold;
/// cvar rows apply through the ctx store, AddBuff/RemoveBuff through the
/// sink.
pub fn fireBuffFinish(self: *Game, ps: ecs.Slot, def_id: u16) void {
    fireBuffEvent(self, ps, def_id, .finish, null);
}

/// Fire every active buff's `onSelfLeaveGame` rows on disconnect (storm /
/// harvest / smell cleanup removes, debug-buff self-removes). Runs before
/// the session-drop path destroys the entity; removals flag for the reap
/// that never comes, so they read as flagged, matching the remove path.
pub fn fireLeaveGame(self: *Game, ps: ecs.Slot) void {
    const peer_slot = self.sim.player[ps].peer_slot;
    if (peer_slot < 0 or @as(usize, @intCast(peer_slot)) >= self.clients.len) return;
    const c = &self.clients[@intCast(peer_slot)];
    const h = &self.sim.health[ps];
    var pctx: PlayerCtx = .{};
    pctx.init(self, c, ps);
    var sandbox_buf: [sandbox.max_groups]sandbox.Group = undefined;
    const sandbox_groups = sandbox_buf[0..sandbox.decode(self.sandbox_code, &sandbox_buf)];
    var req_counts: requirements.Counts = .{};
    const ctx = pctx.build(self, c, ps, h, sandbox_groups);
    var buff_ids: [ecs.components.max_buffs_per_entity]u16 = undefined;
    const n = activeBuffIds(&self.sim.buffs[ps], &buff_ids).len;
    for (buff_ids[0..n]) |id| {
        const res = assets_buffs.evaluateTriggered(&self.buffs, id, .leave_game, ctx, &req_counts);
        if (res.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, res.truncated);
        applyTriggeredBuffs(self, c.entity_id, ps, &res, c.entity_id);
    }
    self.harness.counters.add(.requirement_gates, req_counts.resolved);
    self.harness.counters.add(.requirement_unsupported, req_counts.unsupported);
}

/// Fire every active buff's `onSelfDied` rows on player death
/// (infectionCounter set, aim/draw-buff removes). Runs in the hp-replicate
/// death path before the game_on_death sequence; removals flag for the
/// respawn reap like the kill-remove path.
pub fn fireDied(self: *Game, ps: ecs.Slot) void {
    const peer_slot = self.sim.player[ps].peer_slot;
    if (peer_slot < 0 or @as(usize, @intCast(peer_slot)) >= self.clients.len) return;
    const c = &self.clients[@intCast(peer_slot)];
    const h = &self.sim.health[ps];
    var pctx: PlayerCtx = .{};
    pctx.init(self, c, ps);
    var sandbox_buf: [sandbox.max_groups]sandbox.Group = undefined;
    const sandbox_groups = sandbox_buf[0..sandbox.decode(self.sandbox_code, &sandbox_buf)];
    var req_counts: requirements.Counts = .{};
    const ctx = pctx.build(self, c, ps, h, sandbox_groups);
    var buff_ids: [ecs.components.max_buffs_per_entity]u16 = undefined;
    const n = activeBuffIds(&self.sim.buffs[ps], &buff_ids).len;
    for (buff_ids[0..n]) |id| {
        const res = assets_buffs.evaluateTriggered(&self.buffs, id, .died, ctx, &req_counts);
        if (res.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, res.truncated);
        applyTriggeredBuffs(self, c.entity_id, ps, &res, c.entity_id);
    }
    // Player-class died rows (hazard timer reset/clear on playerMale):
    // same engine, same ctx; cvar writes land through the player store.
    const hash = if (self.sim.mask[ps].class_id and self.sim.class_id[ps].hash != 0)
        self.sim.class_id[ps].hash
    else
        assets_unity_hash.class_player_male;
    if (self.entities.byHash(hash)) |cdef| {
        if (cdef.triggered.len != 0) {
            const res = assets_buffs.evaluateRows(cdef.triggered, .died, ctx, &req_counts);
            if (res.truncated > 0) self.harness.counters.add(.triggered_rows_dropped, res.truncated);
            applyTriggeredBuffs(self, c.entity_id, ps, &res, c.entity_id);
        }
    }
    self.harness.counters.add(.requirement_gates, req_counts.resolved);
    self.harness.counters.add(.requirement_unsupported, req_counts.unsupported);
}
