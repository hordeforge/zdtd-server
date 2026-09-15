//! items.xml loader + builtin sim ids with stock name/type resolution for client UI.

const std = @import("std");
const arena_util = @import("../util/arena.zig");
const xml = @import("xml_util.zig");
const buffs = @import("buffs.zig");
const requirements = @import("requirements.zig");
const io_fs = @import("../util/io_fs.zig");
const components = @import("../ecs/components.zig");

/// Storage cap on parsed item defs, a zdtd bound rather than a stock rule.
/// Measured against V3.2.0 `Data/Config` (2026-09-04): stock items.xml defines
/// **1413**, so this runs at 17% and has room to spare, unlike the block cap
/// next door.
pub const max_items: usize = 8192;

/// Per-item passive_effect row cap and the pool cap across the whole file.
/// Measured against V3.2.0 `Data/Config` (2026-09-12): 3255 `<passive_effect`
/// rows in items.xml, the busiest item carrying 8, so both run far below cap.
pub const max_passives_per_item: usize = 24;
pub const max_item_passives_total: usize = 8192;

/// Stock FastTags match between a passive's tag list and a drop row's tag
/// list: an untagged passive applies to every drop; a tagged passive needs
/// a shared tag with the drop (an untagged drop is only matched by
/// untagged passives).
fn tagsIntersect(row_tags: []const u8, drop_tags: []const u8) bool {
    if (row_tags.len == 0) return true;
    if (drop_tags.len == 0) return false;
    var it = std.mem.splitScalar(u8, row_tags, ',');
    while (it.next()) |rt| {
        const t = std.mem.trim(u8, rt, " \t");
        if (t.len == 0) continue;
        var it2 = std.mem.splitScalar(u8, drop_tags, ',');
        while (it2.next()) |dt| {
            if (std.mem.eql(u8, t, std.mem.trim(u8, dt, " \t"))) return true;
        }
    }
    return false;
}

/// Matches Block.ItemsStartHere (MAX_BLOCKS). Catalog constant; wire stock_inv
/// keeps the same pin for encode. Assets must not import wire for this alone.
pub const items_start_here: i32 = 65536;

/// First free item id after Blocks.ItemsStartHere (assignLeftOverItems pre-increments).
pub const stock_first_item_type: i32 = items_start_here + 1;

/// ItemClass.Stacknumber default when no property declares one (asm.il:749089).
pub const stock_default_stack: u16 = 0x1f4; // 500

/// Item id 0 = none/air: never a real item (item ids start at 1 after
/// ItemsStartHere). The empty-slot sentinel for offline pins and fail-closed
/// lookups that resolve to nothing.
pub const no_item_id: u16 = 0;

fn typeFromBuiltinId(item_id: u16) i32 {
    if (item_id == 0) return 0;
    return items_start_here + @as(i32, item_id);
}

/// items.xml HarvestCount passive (141) row on a held tool (RE GameUtils.
/// HarvestOnAttack IL=623 + items.xml ops): the harvest-yield modifier for
/// drop rows whose tag set intersects `tags` ("" = untagged, applies to
/// every drop). Ops fold over base 1 in row order: base_add -> base+value,
/// base_set -> base=value, perc_add -> base*(1+value); a quality curve
/// evaluates at the tool's quality (piecewise-linear, quality 1..6, RE
/// PassiveEffect.ModValue IL=796).
/// Per-item cap on parsed `<stat>` rows (stock items.xml peaks at 40 on one
/// item) and the pool cap across the file.
pub const max_gs_stats_per_item: usize = 64;
pub const max_gs_stats_total: usize = 4096;

/// Stock `ItemClass/GSStat` (`min`/`max` are the XML values divided by
/// `gs_stat_scale` and stored as i16, so the XML precision is 1/200).
pub const gs_stat_scale: f32 = 0.005;
/// Stock rejects a row whose |min| or |max| reaches this (GSStatsParseXml
/// IL_0134-0147) instead of letting the i16 cast overflow.
pub const gs_stat_limit: f32 = 163.835;

/// One `<stat name="..." value="quality,gameStage,chance,min,max"/>` row of an
/// item's `<stats>` block (stock `ItemClass::GSStatsParseXml` IL=181). The
/// effect stays a name: zdtd keys passive effects by name, and the wire's
/// numeric id is resolved where the stat is written.
pub const GsStat = struct {
    effect: []const u8 = "",
    quality: i16 = 0,
    game_stage: i16 = 0,
    chance: f32 = 0,
    min: i16 = 0,
    max: i16 = 0,
};

/// One rolled stat entry in the wire pair shape (`slot_a`/`slot_b`; stock's
/// `Stat` ctor makes `isBoosted = slot_b > 0`, and the writer emits
/// `slotA = isBoosted ? 0 : value`, `slotB = isBoosted ? value : 0`).
pub const RolledGsStat = struct {
    /// `PassiveEffects` ordinal (`assets/passive_effects.zig`).
    effect: u8 = 0,
    slot_a: i16 = 0,
    slot_b: i16 = 0,
};

/// `passive_effects`
const passive_effects = @import("passive_effects.zig");
const game_random = @import("../util/game_random.zig");

/// One `FindGSStat` (stock `ItemClass::FindGSStat` IL=90) over the rows of one
/// effect: the highest-stage row at or below `stage` whose `chance` gate
/// passes. Null is stock's "not found" sentinel (the returned `quality == -1`),
/// which the caller distinguishes from a real row by the quality it asks for.
/// The RNG draw happens only when the matched row's `chance < 1`.
fn findGsStat(
    stats: []const GsStat,
    effect: []const u8,
    quality: i32,
    stage_in: i32,
    r: *game_random.GameRandom,
) ?GsStat {
    var stage = stage_in;
    if (stage < 0) {
        // Trader path: the stage comes from the first row of that quality.
        for (stats) |s| {
            if (!std.mem.eql(u8, s.effect, effect)) continue;
            if (@as(i32, s.quality) == quality) {
                stage = s.game_stage;
                break;
            }
        }
    }
    var best: i32 = -1;
    var i: usize = stats.len;
    while (i > 0) {
        i -= 1;
        const s = stats[i];
        if (!std.mem.eql(u8, s.effect, effect)) continue;
        if (@as(i32, s.quality) != quality) continue;
        const cur: i32 = s.game_stage;
        if (cur > stage) continue;
        if (best < 0) {
            best = cur;
        } else if (cur < best) {
            return null; // stock breaks out of the loop to its sentinel
        }
        if (s.chance < 1) {
            const roll: f32 = @floatCast(r.nextDouble());
            if (!(s.chance > roll)) continue;
        }
        return s;
    }
    return null;
}

/// Stock `ItemClass::AddGSStats` (IL=100): one entry per distinct effect at
/// `quality`/`stage`, drawing from `r` in stock's exact order - the base roll
/// (`FindGSStat(list, 0, 0, r)` then `RandomRange(min, max+1)`), then the
/// quality roll (`FindGSStat(list, quality, stage, r)`). The result is the
/// summed value split by `isBoosted = added > 0`, and an entry whose sum is 0
/// is dropped (stock's `RemoveUnusedStats`). An effect name the enum does not
/// know is skipped (the wire has no id for it).
pub fn rollGsStats(
    stats: []const GsStat,
    quality: u8,
    stage: i32,
    r: *game_random.GameRandom,
    out: []RolledGsStat,
) usize {
    var n: usize = 0;
    for (stats, 0..) |s, idx| {
        // First-occurrence order, and one entry per effect (stock's dictionary).
        var seen = false;
        for (stats[0..idx]) |prev| {
            if (std.mem.eql(u8, prev.effect, s.effect)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        var base: i32 = 0;
        if (findGsStat(stats, s.effect, 0, 0, r)) |g0| {
            if (g0.max >= g0.min) base = r.nextRange(g0.min, @as(i32, g0.max) + 1);
        }
        var added: i32 = 0;
        if (findGsStat(stats, s.effect, quality, stage, r)) |g1| {
            if (g1.quality > 0 and g1.max >= g1.min) {
                added = r.nextRange(g1.min, @as(i32, g1.max) + 1);
            }
        }
        if (base + added == 0) continue;
        const ordinal = passive_effects.idOfName(s.effect) orelse continue;
        if (n >= out.len) break;
        // Stock casts the sum to i16 with a wrapping `conv.i2`.
        const value: i16 = @truncate(base + added);
        out[n] = .{
            .effect = ordinal,
            .slot_a = if (added > 0) 0 else value,
            .slot_b = if (added > 0) value else 0,
        };
        n += 1;
    }
    return n;
}

pub const HarvestOp = enum(u8) { base_add, base_set, perc_add };

pub const HarvestCountRow = struct {
    op: HarvestOp = .base_add,
    /// Flat value, or curve anchors when curve_n > 0.
    value: f32 = 0,
    curve: [buffs.max_curve_len]f32 = .{0} ** buffs.max_curve_len,
    curve_n: u8 = 0,
    /// Comma list of gating tags ("" = applies to every drop row).
    tags: []const u8 = "",
};

pub const ItemDef = struct {
    /// zdtd internal id (small, used in ECS inventory).
    id: u16 = 0,
    name: []const u8 = "",
    stack: u16 = 50,
    /// Absolute stock ItemValue.type (ItemsStartHere + …). 0 = unknown.
    stock_type: i32 = 0,
    /// items.xml EconomicValue (0 = not tradeable).
    econ: f32 = 0,
    /// items.xml `TraderQualityMod="min,max"` (4 stock rows, toolCookingPot and
    /// toolCookingGrill variants): the quality price lerp this item uses
    /// instead of the trader's own `quality_mod` (stock
    /// `ItemClass.TraderQualityMinMod`/`MaxMod`, XUiM_Trader GetBuyPrice /
    /// GetSellPrice IL_0127-0168). 0 = not declared -> the trader's pair.
    trader_quality_min_mod: f32 = 0,
    trader_quality_max_mod: f32 = 0,
    /// items.xml EconomicSellScale (stock `ItemClass.EconomicSellScale`,
    /// IL default 1.0; the sell price base is EconomicValue * scale, RE
    /// loot-economy.md GetSellPrice). A39.
    econ_sell_scale: f32 = 1.0,
    /// items.xml EconomicBundleSize (RE loot-economy.md §5 GetBuyPrice/
    /// GetSellPrice: the price divides by the bundle). 89 stock items carry
    /// it (ammoGasCan 100, resourceWood 50, …); absent = 1.
    econ_bundle_size: u16 = 1,
    /// items.xml passive_effect DegradationMax (passive 8, stock
    /// `ItemClass.get_MaxUseTimesBase`, IL=25): the durability cap. Quality
    /// tiers "min,max" (tier 1..6 = quality 1..6) lerp between the pair; a
    /// single value is constant. 0 = no durability (PercentUsesLeft = 1).
    /// RE items.md §7 + ItemValue.get_PercentUsesLeft (IL=17).
    degradation_min: u32 = 0,
    degradation_max: u32 = 0,
    /// Stock `ItemClass.HasQuality` (IL=9): true when any `<effect_group>` is
    /// owner-tiered. `MinEffectGroup.OwnerTiered` defaults to true in the ctor
    /// and stock items.xml only ever writes `tiered="false"`, so an item has
    /// quality unless every one of its effect groups opts out. Gates the
    /// trader stock roll's quality substitution and `TraderMaxTier` clamp.
    has_quality: bool = false,
    /// items.xml Action0 DamageEntity (melee hand damage; 0 = none/unset).
    entity_damage: f32 = 0,
    /// items.xml DamageBlock property (hand-item block chew: zombie hand 8,
    /// feral 24; 0 = none/unset → the `[rules.progression] block_bite_damage`
    /// floor).
    damage_block: f32 = 0,
    /// items.xml LightValue (held-item light: torch .35, flashlight02 .55,
    /// weapon lights .45). Feeds the PlayerStealth selfLight term (Inventory.
    /// GetLightLevel IL=76: an AlwaysActive held item's LightValue, clamped
    /// 0..1). 0 = no held light.
    light_value: f32 = 0,
    /// items.xml melee reach: `Range` property (zombie hand 1.6) or the
    /// passive `MaxRange` (club/axe 2.4). 0 = none/unset → the
    /// `[rules.combat] attack_range_sq` floor.
    melee_range: f32 = 0,
    /// items.xml PhysicalDamageResist passive (41) quality curve: value[i]
    /// sits at quality 1 + 5i/(n-1), piecewise-linear (RE PassiveEffect.
    /// ModValue IL=796; GetTotalPhysicalArmorRating sums it on the wearer,
    /// combat-damage.md). 0 segments = the item carries no row.
    phys_resist_curve: [buffs.max_curve_len]f32 = .{0} ** buffs.max_curve_len,
    phys_resist_n: u8 = 0,
    /// ElementalDamageResist passive (43, `Equipment.CalcDamage` IL=83), same
    /// curve shape. This first-row curve is informational only: the live EDR
    /// path folds the item's tagged rows on the damage event
    /// (`Game.elementalDamageResist`), so a `tags="heat,electrical"` row
    /// resists those types and not cold. The untagged rows in this curve are
    /// the `-.2,.2` jitter, which applies to every non-physical type.
    elem_resist_curve: [buffs.max_curve_len]f32 = .{0} ** buffs.max_curve_len,
    elem_resist_n: u8 = 0,
    /// Every `<passive_effect>` row on the item, with its `effect_group` and
    /// row gates, parsed through the shared buffs scanner. The survival tick
    /// folds the tracked names over the equipped and held items (stock
    /// `EffectManager.GetValue` layers 7/8), so clothing max stats, armor
    /// resistances and boots' stamina rows apply. Empty = no rows (most items).
    passives: []const buffs.Passive = &.{},
    /// items.xml `Tags` property (comma list): the item's mod-attachment tag
    /// surface. A mod fits when its installable_tags intersects Tags and its
    /// blocked_tags is disjoint (RE items.md ItemClassModifier suitability).
    /// "" = untagged → no mods can attach (fail closed).
    tags: []const u8 = "",
    /// items.xml `ArmorGroup` property (stock ships one name per armor item,
    /// e.g. groupBiker). Equipment::ResetArmorGroups (IL=51) walks worn
    /// ItemClassArmor slots and records each item's group + quality, so this is
    /// the tag ArmorGroupLowestQuality matches. "" = not armor-grouped.
    armor_group: []const u8 = "",
    /// items.xml ModSlots passive (quality curve: value "1,1,1,2,2,3" sits at
    /// quality 1..6; RE items.md CalcModSlotCount IL=29 =
    /// FastMin(255, EffectManager.GetValue(ModSlots, item, Quality-1))). The
    /// max attached mods for a slot at a given quality. 0 segments = the item
    /// carries no row → no mods allowed (fail closed).
    mod_slots_curve: [buffs.max_curve_len]f32 = .{0} ** buffs.max_curve_len,
    mod_slots_n: u8 = 0,
    /// items.xml CraftingSmeltTime passive (PassiveEffects 95, perc_add quality
    /// curve). Forge tools (toolBellows) scale melt duration via
    /// ItemValue.ModifyValue in HandleMaterialInput. 0 segments = no row →
    /// identity (scale 1). Values are perc_add deltas (e.g. -.3 → 0.7×).
    crafting_smelt_time_curve: [buffs.max_curve_len]f32 = .{0} ** buffs.max_curve_len,
    crafting_smelt_time_n: u8 = 0,
    /// items.xml DegradationPerUse passive (base_set, stock
    /// ItemValue.UseTimes wear per use): the durability consumed by one use.
    /// 0 = no row -> the callers' 1.0 default (the pre-XML behavior).
    degradation_per_use: f32 = 0,
    /// items.xml StaminaLoss passive (base_set, first value): the per-attack
    /// stamina cost (RE ItemActionMelee IL: GetValue(StaminaLoss, item) x
    /// StaminaUsageMultiplier -> AddStamina(-cost)). The 2-value rows are the
    /// normal/power pair (first = normal); the negative quality-curve rows
    /// are recorded, not guessed.
    stamina_loss: f32 = 0,
    /// items.xml DismemberChance passive (144, first row value): the weapon's
    /// dismember contribution carried on DamageSource.DismemberChance (RE
    /// Explosion.AttackEntites IL_04F0 / ItemActionAttack.Hit IL_08E7).
    /// Stock feeds it into EntityAlive.GetDismemberChance: >= 100 skips the
    /// roll at flat 100, else chance = value * damagePer * the attacker's
    /// DismemberSelfChance passive (143). 0 = unset (no dismember from it).
    dismember_chance: f32 = 0,
    /// items.xml TargetArmor passive (163, perc_add, UNTAGGED rows only):
    /// armor penetration fraction applied to the target's mitigation
    /// (GetTotalPhysicalArmorRating IL=47: passive 163 on the attacking item
    /// modifies the wearer's passive-41 rating base).
    target_armor: f32 = 0,
    /// The first perk-tag-gated TargetArmor row (e.g. `-.3` tagged
    /// perkJavelinMaster): applies only when the attacker owns that perk.
    /// 0 / empty = no tagged row.
    target_armor_tagged: f32 = 0,
    target_armor_tag: []const u8 = "",
    /// items.xml HarvestCount passive (141) rows on the HELD item: the
    /// tool's harvest-yield modifier, tag-gated by the drop row's tag (RE
    /// GameUtils.HarvestOnAttack IL=623: count = trunc(rolled * GetValue(
    /// 141, tool, 1, holder, null, dropTag))). Empty = 1.0 (stock default).
    /// The equipped-armor rows (farmer/lumberjack/miner/scavenger) need the
    /// full EffectManager aggregation over worn items - the recorded
    /// passive-effects-VM non-goal; only the held-tool leg is wired here.
    harvest_rows: []const HarvestCountRow = &.{},
    /// items.xml `<stats>` rows: the gamestage-scaled stat rolls stock applies
    /// when the item value is created (`ItemClass::AddGSStats`). Own element
    /// only - stock parses the item's own `<stats>`, and no stock item inherits
    /// one (the two apparent inheritors sit in commented-out blocks).
    stats: []const GsStat = &.{},
    /// items.xml Action1 Class=PlaceAsBlock `Blockname` (b14: exactly two  -
    /// meleeToolTorch → wallTorchLightPlayer, candle → candleWallLightPlayer).
    /// Resolved to a block id via AssignIds at place time; empty = not
    /// placeable (fail closed - resourceWood etc. carry no Blockname and do
    /// not place in stock).
    place_block_name: []const u8 = "",
    /// items.xml FuelValue (generator/vehicle fuel units per item; 0 = not fuel).
    fuel_value: f32 = 0,
    /// items.xml `CraftTimeValue` property (stock `ItemClass.CraftComponentTime`,
    /// IL_061D): per-unit craft time this ingredient contributes to a recipe's
    /// derived `craftingTime` (`Recipe::Init` IL=79 sums `time * count`). 0 =
    /// not declared (no stock item declares it, so every stock derivation is
    /// 0).
    craft_component_time: f32 = 0,
    /// items.xml Weight (forge melt units added per input item; 0 = unset).
    weight: u16 = 0,
    /// items.xml MeltTimePerUnit (seconds per weight unit; 0 = stock default 1).
    melt_time_per_unit: f32 = 0,
    /// items.xml Material (MadeOfMaterial id, e.g. Mmetal). Empty = none.
    /// Forge melt resolves materials.xml forge_category through this.
    material: []const u8 = "",
    /// items.xml `SellableToTrader` (ItemClass ParseBool, default true,
    /// inherited through Extends): a trader refuses to buy the item, which is
    /// what greys the client's sell button and what the server enforces.
    sellable_to_trader: bool = true,
    /// items.xml NoScrapping: item cannot be scrap-salvaged
    /// (GetScrapableRecipe, RE crafting-recipes.md IL=77).
    no_scrapping: bool = false,
    /// ItemActionEat (Action0 Class=Eat) or name prefix food/drink.
    is_eat: bool = false,
    /// $foodAmountAdd from effect_group (PlayerEntityStats.Food gain).
    food_amount: f32 = 0,
    /// foodHealthAmount from effect_group (HP gain on eat).
    food_health: f32 = 0,
    /// $waterAmountAdd from effect_group (PlayerEntityStats.Water gain).
    water_amount: f32 = 0,
    /// items.xml `AddProgressionLevel` on eat (magazines: Unlocks a
    /// crafting_skill and adds `level`). Empty = not a magazine. Arena-owned.
    progression_name: []const u8 = "",
    /// Amount added per use (stock magazines ship 1). 0 = no grant.
    progression_add: u8 = 0,
    /// items.xml `SetProgressionLevel` with `level="-1"` (RE minevents.md
    /// IL=104: set ProgressionClass.MaxLevel). Stock almanacs/journals ship
    /// one or more perk names; arena-owned slice of interned names.
    progression_set_max: []const []const u8 = &.{},
    /// items.xml `GiveExp` on eat (stock magazines ship 50). 0 = no XP.
    eat_exp: u16 = 0,
    /// items.xml `DistractionTags` (EntityItem distraction; RE EntityItem::SetupDistraction
    /// + ItemClass::get_IsEatDistraction). Bits: 1 = eat, 2 = requires_contact, 4 = zombie.
    /// Stock ships only decoy (`zombie,requires_contact`).
    distraction_tags: u8 = 0,
    /// items.xml effect_group `DistractionRadius` (PassiveEffects.DistractionRadius,
    /// EntityItem::SetupDistraction). 0 = not a distraction.
    distraction_radius: f32 = 0,
    /// effect_group `DistractionLifetime` (tick broadcasts before the item stops
    /// attracting; stock decoy = 1).
    distraction_lifetime: i32 = 0,
    /// effect_group `DistractionStrength` (overcomes EntityAlive.distractionResistance).
    distraction_strength: f32 = 0,
    /// effect_group `DistractionEatTicks` (PassiveEffects 69): ticks an eating
    /// zombie chews the item before it dies. Stock decoy leaves it unset (0 =
    /// no eating; approach clears at close range).
    distraction_eat_ticks: i32 = 0,
};

/// EntityItem distraction parameters (RE EntityItem::SetupDistraction):
/// DistractionRadius(66), DistractionLifetime(67), DistractionStrength(68)
/// passive effects, plus the item's `DistractionTags`.
pub const Distraction = struct {
    /// Bit 1 = eat, 2 = requires_contact, 4 = zombie (stock decoy: 2|4).
    tags: u8 = 0,
    /// DistractionRadius in meters (squared on the sim side, like stock).
    radius: f32 = 0,
    /// DistractionLifetime in broadcast ticks (stock decoy = 1).
    lifetime: i32 = 0,
    /// DistractionStrength (vs EntityAlive.distractionResistance).
    strength: f32 = 0,
    /// DistractionEatTicks (PassiveEffects 69): ticks an eating zombie chews
    /// the item (0 = not eaten, approach clears at close range).
    eat_ticks: i32 = 0,
};

pub const ItemTable = struct {
    defs: []const ItemDef = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,
    source: enum { builtin, xml } = .builtin,
    /// All stock items from XML (name → absolute type), for IdMapping export.
    stock_names: []const []const u8 = &.{},
    stock_types: []const i32 = &.{},
    /// Resolved Stacknumber per stock_names row (Extends chain, default 500).
    stock_stacks: []const u16 = &.{},
    /// Per-item EconomicSellScale (stock ItemClass field, default 1.0; A39).
    stock_econ_scales: []const f32 = &.{},
    /// Sandbox `MaxStackSize` option (163 `StackSizeMultiplier`, default 1.0):
    /// stock's `ItemClass.MaxStackSizeModifier` static, which
    /// `ItemClass.get_MaxCount()` (IL=10) multiplies into the Stacknumber for
    /// stackable non-quality items and clamps at 30000. Set from the decoded
    /// server code at init; 1.0 keeps every raw Stacknumber.
    stack_size_modifier: f32 = 1,
    /// Stock `ItemClass.MaxQualityTier` static: the `<items>` root attribute
    /// `max_quality_tier` when present, else stock's own fallback
    /// (`ItemClassesFromXml.CreateItems` reads the root attribute into the
    /// static and assigns 6 when it is absent, `components.max_quality_tiers`).
    /// V3.2.0 ships no attribute. Bounds every quality axis: the passive folds
    /// (`itemQualityAxis`), armour PDR curves, the crafting tier clamp and
    /// `harvestMultiplier`'s quality curve.
    max_quality_tier: u8 = components.max_quality_tiers,

    pub fn deinit(self: *ItemTable) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
        self.* = builtin();
    }

    pub fn builtin() ItemTable {
        return .{ .defs = builtin_defs[0..], .source = .builtin };
    }

    pub fn byId(self: *const ItemTable, id: u16) ?ItemDef {
        // defs layout: builtins at [0..13) with id == index, XML items appended
        // with sequential ids from 100. Probe the computed slot; scan on miss.
        const guess: usize = if (id < builtin_defs.len)
            id
        else if (id >= 100)
            builtin_defs.len + @as(usize, id - 100)
        else
            self.defs.len;
        if (guess < self.defs.len and self.defs[guess].id == id) return self.defs[guess];
        for (self.defs) |d| if (d.id == id) return d;
        return null;
    }

    pub fn byName(self: *const ItemTable, name: []const u8) ?ItemDef {
        for (self.defs) |d| {
            if (std.mem.eql(u8, d.name, name)) return d;
        }
        // Offline only: stock items.xml name → builtin ECS row (casinoCoin → 6).
        // After items.xml load, missing names fail closed (wrong id is worse).
        if (self.source != .builtin) return null;
        var id: u16 = 1;
        while (id < 64) : (id += 1) {
            const sn = builtinStockName(id) orelse continue;
            if (!std.mem.eql(u8, sn, name)) continue;
            if (self.byId(id)) |d| return d;
        }
        return null;
    }

    /// Stock `ItemValue.CalcModSlotCount` (IL=29, items.md): the mod budget
    /// for an item at a quality tier = FastMin(255, EffectManager.GetValue(
    /// ModSlots, item, FastMax(0, Quality-1))) - the item's ModSlots quality
    /// curve value (tier 1..6 → curve[0..5]). 0 = no row → no mods (fail
    /// closed in the attachment scrub). Quality 0 (unset) treats as tier 1.
    pub fn modSlotsFor(self: *const ItemTable, item_id: u16, quality: u8) u8 {
        const d = self.byId(item_id) orelse return 0;
        if (d.mod_slots_n == 0) return 0;
        const q: usize = if (quality == 0) 1 else quality;
        const idx = @min(q, @as(usize, d.mod_slots_n)) - 1;
        const v = d.mod_slots_curve[idx];
        if (v <= 0) return 0;
        return @trunc(@min(v, 255.0));
    }

    /// Stock HandleMaterialInput tools path (PassiveEffects 95 CraftingSmeltTime):
    /// ItemValue.ModifyValue with perc_add → duration *= (1 + curve[quality]).
    /// No row → identity 1. Quality 0 treats as tier 1 (same as ModSlots).
    pub fn craftingSmeltTimeScale(self: *const ItemTable, item_id: u16, quality: u8) f32 {
        const d = self.byId(item_id) orelse return 1.0;
        if (d.crafting_smelt_time_n == 0) return 1.0;
        const q: usize = if (quality == 0) 1 else quality;
        const idx = @min(q, @as(usize, d.crafting_smelt_time_n)) - 1;
        return 1.0 + d.crafting_smelt_time_curve[idx];
    }

    /// Stock ItemValue.type → item name (reverse of stockTypeFor). Walks the
    /// defs; used off the hot path for trust-boundary checks (workstation queue
    /// validation). Builtin rows carry no stock type, so this only resolves
    /// after items.xml loads.
    pub fn nameByStockType(self: *const ItemTable, stock_type: i32) ?[]const u8 {
        for (self.defs) |d| {
            if (d.stock_type == stock_type and d.name.len > 0) return d.name;
        }
        return null;
    }

    /// ECS id for a stock or short name (0 unknown). Prefers defs after XML load.
    pub fn ecsIdByName(self: *const ItemTable, name: []const u8) u16 {
        if (self.byName(name)) |d| return d.id;
        return 0;
    }

    /// One extra item class to register (item_modifiers.xml row): the fields
    /// the modifier carries as an ItemClass (name, Stacknumber, EconomicValue,
    /// HasQuality).
    pub const ItemClassStub = struct {
        name: []const u8,
        econ: f32 = 0,
        stack: u16 = 1,
        has_quality: bool = false,
    };

    /// Register extra item classes that stock loads from a sibling catalog.
    /// `item_modifiers.xml` `<item_modifier>` rows are `ItemClassModifier`
    /// item classes in the same id space as `<item>` rows: stock runs
    /// `XmlLoadInfo` 9 (`items`) then 10 (`item_modifiers`) and
    /// `LateInitItems` -> `assignIdsLinear` -> `assignLeftOverItems` hands the
    /// leftover ids to the unassigned list in that order (RE items.md
    /// load-time id assignment). The wire carries installed mods as nested
    /// `ItemValue`s referring to those ids, so the ECS table and the join
    /// `IdMapping` have to know them; without this a looted gun's `mods=` roll
    /// (or a client-attached mod) resolves to nothing and fails closed.
    ///
    /// `classes` is item_modifiers.xml document order with each row's econ,
    /// stack and quality flag (the mod is an ItemClassModifier item class, so
    /// those item properties apply to it). No-op for the builtin fixture
    /// catalog, which has no arena and no stock id space. Ownership: the
    /// caller keeps `classes`; the table dupes the strings into its arena.
    pub fn addItemClasses(self: *ItemTable, classes: []const ItemClassStub) !void {
        const ap = self.arena_ptr orelse return;
        if (classes.len == 0) return;
        if (self.stock_names.len + classes.len > max_items) return error.TooManyItems;
        const arena = ap.allocator();
        var next_id: u16 = 1;
        for (self.defs) |d| next_id = @max(next_id, d.id +| 1);
        var next_stock: i32 = stock_first_item_type;
        for (self.stock_types) |st| next_stock = @max(next_stock, st + 1);
        const defs = try arena.alloc(ItemDef, self.defs.len + classes.len);
        @memcpy(defs[0..self.defs.len], self.defs);
        const sn = try arena.alloc([]const u8, self.stock_names.len + classes.len);
        @memcpy(sn[0..self.stock_names.len], self.stock_names);
        const st = try arena.alloc(i32, self.stock_names.len + classes.len);
        @memcpy(st[0..self.stock_types.len], self.stock_types);
        for (classes, 0..) |cl, i| {
            const name = try arena.dupe(u8, cl.name);
            defs[self.defs.len + i] = .{
                .id = next_id,
                .name = name,
                .stack = cl.stack,
                .stock_type = next_stock,
                .econ = cl.econ,
                .has_quality = cl.has_quality,
            };
            sn[self.stock_names.len + i] = name;
            st[self.stock_types.len + i] = next_stock;
            next_id +%= 1;
            next_stock += 1;
        }
        self.defs = defs;
        self.stock_names = sn;
        self.stock_types = st;
    }

    /// Held-tool HarvestCount multiplier for one drop row (RE GameUtils.
    /// HarvestOnAttack IL=623: count = trunc(rolled * GetValue(141, tool,
    /// 1, holder, null, dropTag))). Rows whose tag set intersects the drop
    /// row's tag set (or untagged) fold in order over base 1: base_add ->
    /// base+value, base_set -> base=value, perc_add -> base*(1+value); a
    /// quality curve evaluates at the tool's quality. 1.0 when nothing
    /// matches (the stock default; the equipped-armor aggregation is the
    /// recorded non-goal).
    pub fn harvestMultiplier(self: *const ItemTable, item_id: u16, quality: u8, drop_tags: []const u8) f32 {
        const d = self.byId(item_id) orelse return 1.0;
        if (d.harvest_rows.len == 0) return 1.0;
        var base: f32 = 1.0;
        for (d.harvest_rows) |r| {
            if (!tagsIntersect(r.tags, drop_tags)) continue;
            const v = if (r.curve_n > 0)
                buffs.curveValueAt(quality, self.max_quality_tier, r.curve[0..r.curve_n])
            else
                r.value;
            switch (r.op) {
                .base_add => base += v,
                .base_set => base = v,
                .perc_add => base *= 1.0 + v,
            }
        }
        return base;
    }

    pub fn byStockName(self: *const ItemTable, name: []const u8) ?i32 {
        for (self.stock_names, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return self.stock_types[i];
        }
        // defs may carry stock_type without full stock list (builtin)
        for (self.defs) |d| {
            if (std.mem.eql(u8, d.name, name) and d.stock_type != 0) return d.stock_type;
        }
        return null;
    }

    /// Sandbox `MaxStackSize` (option 163). Stock pushes the decoded value into
    /// the `ItemClass.MaxStackSizeModifier` static
    /// (SandboxOptionManager IL_0466-0470); 1.0 is the fast path.
    pub fn setStackSizeModifier(self: *ItemTable, v: f32) void {
        self.stack_size_modifier = if (v > 0) v else 1;
    }

    /// Max stack for an ECS item id: stock `ItemClass.get_MaxCount()` (IL=10).
    /// With the sandbox modifier at 1 (or an item that has quality, or one that
    /// cannot stack) the raw Stacknumber is returned; otherwise it is scaled and
    /// clamped at 30000. Quality items are weapons and tools whose stack of 1
    /// must not follow the option, which is why the check sits inside the
    /// non-default path in stock too.
    pub fn stackFor(self: *const ItemTable, item_id: u16) u16 {
        const d = self.byId(item_id) orelse return 1;
        if (!(d.stack > 0)) return 1;
        if (self.stack_size_modifier == 1) return d.stack;
        if (d.has_quality) return d.stack;
        if (!(d.stack > 1)) return d.stack;
        const scaled = fastRoundToInt(@as(f32, @floatFromInt(d.stack)) * self.stack_size_modifier);
        if (scaled <= 0) return 1;
        return @intCast(@min(scaled, max_scaled_stack));
    }

    /// Stock `ItemClass.HasQuality` (IL=9) for an items.xml name. The trader
    /// stock roll keys off names, so this is the name-side lookup. An unknown
    /// name has no quality (fail closed: a rolled quality on a stackable is
    /// worse than none).
    pub fn hasQualityByName(self: *const ItemTable, name: []const u8) bool {
        if (self.byName(name)) |d| return d.has_quality;
        return false;
    }

    /// FuelValue from items.xml (0 if unset / not a fuel item).
    pub fn fuelValueFor(self: *const ItemTable, item_id: u16) f32 {
        if (self.byId(item_id)) |d| {
            if (d.fuel_value > 0) return d.fuel_value;
        }
        return 0;
    }

    /// Weight from items.xml (forge melt units per input item; 0 if unset).
    pub fn weightFor(self: *const ItemTable, item_id: u16) u16 {
        if (self.byId(item_id)) |d| return d.weight;
        return 0;
    }

    /// MeltTimePerUnit from items.xml (seconds per weight unit; 0 → stock default 1).
    pub fn meltTimePerUnitFor(self: *const ItemTable, item_id: u16) f32 {
        if (self.byId(item_id)) |d| return d.melt_time_per_unit;
        return 0;
    }

    /// items.xml Material id (MadeOfMaterial); empty when unset.
    pub fn materialFor(self: *const ItemTable, item_id: u16) []const u8 {
        if (self.byId(item_id)) |d| return d.material;
        return "";
    }

    /// True if item is ItemActionEat consumable (or builtin food/medicine).
    /// True if absolute stock type maps to an eatable def (or food*/drink* name).
    pub fn isEatStockType(self: *const ItemTable, stock_type: i32) bool {
        if (stock_type == 0) return false;
        const eid = self.ecsIdFromStockType(stock_type);
        if (eid != 0 and self.isEat(eid)) return true;
        // Name from parallel stock arrays when reverse id is 0. XML catalogs
        // fail closed: a stock type with no ECS row is not eatable.
        if (self.source != .builtin) return false;
        for (self.stock_types, 0..) |st, i| {
            if (st != stock_type) continue;
            if (i >= self.stock_names.len) break;
            const n = self.stock_names[i];
            if (n.len >= 4 and (std.mem.startsWith(u8, n, "food") or std.mem.startsWith(u8, n, "drink")))
                return true;
            break;
        }
        return false;
    }

    pub fn isEat(self: *const ItemTable, item_id: u16) bool {
        if (self.byId(item_id)) |d| {
            if (d.is_eat) return true;
            if (d.progression_add > 0 and d.progression_name.len > 0) return true;
            if (d.progression_set_max.len > 0) return true;
            if (d.food_amount > 0 or d.water_amount > 0) return true;
            // Offline name heuristic for food*/drink* without parsed Action0.
            // After items.xml load, missing Action0 fails closed (wrong eat
            // is worse than missing).
            if (self.source == .builtin and d.name.len >= 4 and
                (std.mem.startsWith(u8, d.name, "food") or std.mem.startsWith(u8, d.name, "drink")))
                return true;
        }
        // Builtin offline ids (food / medicine). XML catalogs fail closed.
        return self.source == .builtin and (item_id == 2 or item_id == 4);
    }

    pub fn foodAmountFor(self: *const ItemTable, item_id: u16) f32 {
        if (self.byId(item_id)) |d| {
            if (d.food_amount > 0) return d.food_amount;
            if (self.source == .builtin and
                (d.is_eat or (d.name.len >= 4 and std.mem.startsWith(u8, d.name, "food")))) return 15;
        }
        if (self.source == .builtin and item_id == 2) return 15;
        return 0;
    }

    pub fn foodHealthFor(self: *const ItemTable, item_id: u16) f32 {
        if (self.byId(item_id)) |d| {
            if (d.food_health > 0) return d.food_health;
            if (self.source == .builtin) {
                if (item_id == 4 or std.mem.eql(u8, d.name, "medicine")) return 25;
                if (d.is_eat) return 7;
            }
        }
        if (self.source == .builtin and item_id == 2) return 7;
        if (self.source == .builtin and item_id == 4) return 25;
        return 0;
    }

    pub fn waterAmountFor(self: *const ItemTable, item_id: u16) f32 {
        if (self.byId(item_id)) |d| {
            if (d.water_amount > 0) return d.water_amount;
            if (self.source == .builtin and d.name.len >= 5 and std.mem.startsWith(u8, d.name, "drink")) return 20;
        }
        return 0;
    }

    /// EntityItem distraction parameters for a dropped item, or null when the
    /// item carries no DistractionTags (most items; only decoy in stock V3.1.0).
    pub fn distractionFor(self: *const ItemTable, item_id: u16) ?Distraction {
        const d = self.byId(item_id) orelse return null;
        if (d.distraction_tags == 0) return null;
        return .{
            .tags = d.distraction_tags,
            .radius = d.distraction_radius,
            .lifetime = d.distraction_lifetime,
            .strength = d.distraction_strength,
            .eat_ticks = d.distraction_eat_ticks,
        };
    }

    /// Resolve ECS item_id → absolute stock type for wire encode.
    pub fn stockTypeFor(self: *const ItemTable, item_id: u16) i32 {
        if (item_id == 0) return 0;
        if (self.byId(item_id)) |d| {
            if (d.stock_type != 0) return d.stock_type;
            // Offline alias: builtin short name → stock name. XML catalogs
            // already copy stock_type onto overlay rows; leftover aliases
            // would map the wrong item.
            if (self.source == .builtin) {
                if (builtinStockName(item_id)) |sn| {
                    if (self.byStockName(sn)) |t| return t;
                }
            }
            if (d.name.len > 0) {
                if (self.byStockName(d.name)) |t| return t;
            }
        } else if (self.source == .builtin) {
            if (builtinStockName(item_id)) |sn| {
                if (self.byStockName(sn)) |t| return t;
            }
        }
        // The relative-id pin exists only for the no-game-dir fixture catalog.
        // In XML mode an unresolved type would name the wrong stock item.
        if (self.source == .builtin) return typeFromBuiltinId(item_id);
        return 0;
    }

    /// Reverse: absolute stock type → ECS item_id (0 if unknown).
    pub fn ecsIdFromStockType(self: *const ItemTable, stock_type: i32) u16 {
        if (stock_type == 0) return 0;
        // Prefer exact stock_type on defs (builtins + xml-loaded).
        for (self.defs) |d| {
            if (d.stock_type == stock_type and d.id != 0) return d.id;
        }
        // Parallel stock_types/stock_names arrays (full XML order).
        for (self.stock_types, 0..) |st, i| {
            if (st != stock_type) continue;
            const name = if (i < self.stock_names.len) self.stock_names[i] else "";
            if (name.len > 0) {
                const eid = self.ecsIdByName(name);
                if (eid != 0) return eid;
                for (self.defs) |d| {
                    if (d.id != 0 and std.mem.eql(u8, d.name, name)) return d.id;
                }
            }
            break;
        }
        // Alias builtins via computed stockTypeFor (offline catalog only).
        if (self.source == .builtin) {
            var id: u16 = 1;
            while (id <= 12) : (id += 1) {
                if (self.stockTypeFor(id) == stock_type) return id;
            }
        }
        // Relative ids are an offline fixture convention, never XML truth.
        if (self.source == .builtin and stock_type > items_start_here) {
            const rel = stock_type - items_start_here;
            if (rel > 0 and rel < 100) return @intCast(rel);
        }
        return 0;
    }

    /// NameIdMapping payload (version 1 + count + id/name pairs).
    /// LE i32 + .NET 7-bit strings; open-coded so assets stays free of wire.
    pub fn writeNameIdMapping(self: *const ItemTable, buf: []u8) ![]u8 {
        var pos: usize = 0;
        try writeI32Le(buf, &pos, 1); // FILE_VERSION
        try writeI32Le(buf, &pos, @intCast(self.stock_names.len));
        for (self.stock_names, 0..) |name, i| {
            try writeI32Le(buf, &pos, self.stock_types[i]);
            try writeDotNetString(buf, &pos, name);
        }
        return buf[0..pos];
    }
};

fn writeI32Le(buf: []u8, pos: *usize, v: i32) error{Overflow}!void {
    if (pos.* + 4 > buf.len) return error.Overflow;
    std.mem.writeInt(i32, buf[pos.*..][0..4], v, .little);
    pos.* += 4;
}

fn writeDotNetString(buf: []u8, pos: *usize, s: []const u8) error{Overflow}!void {
    var len = s.len;
    while (true) {
        if (pos.* >= buf.len) return error.Overflow;
        // Low byte first; the | 0x80 below overwrites bit 7 with the
        // continuation flag, so the discarded high bits shift down on the next
        // iteration (same 7-bit length shape as the wire codec's writer).
        const b: u8 = @truncate(len);
        if (len < 0x80) {
            buf[pos.*] = b;
            pos.* += 1;
            break;
        }
        buf[pos.*] = b | 0x80;
        pos.* += 1;
        len >>= 7;
    }
    if (pos.* + s.len > buf.len) return error.Overflow;
    @memcpy(buf[pos.* .. pos.* + s.len], s);
    pos.* += s.len;
}

/// Action0/1 Class property equals `want` (ItemActionEat → Class="Eat").
fn itemActionClassIs(body: []const u8, want: []const u8) bool {
    // Prefer nested <property class="Action0"> ... Class=Eat
    var i: usize = 0;
    while (i < body.len) {
        const pi = std.mem.findPos(u8, body, i, "<property") orelse break;
        const cn = xml.attr(body, pi, "class") orelse {
            i = pi + 9;
            continue;
        };
        if (!(std.mem.startsWith(u8, cn, "Action"))) {
            i = pi + 9;
            continue;
        }
        // Find end of this property class block: next </property> after nested props.
        const rest = body[pi..];
        // Search Class value within next 400 bytes of this Action block.
        const window = if (rest.len > 500) rest[0..500] else rest;
        if (xml.propertyValue(window, "Class")) |cls| {
            if (std.mem.eql(u8, cls, want)) return true;
        }
        i = pi + 9;
    }
    return false;
}

/// First effect_group ModifyCVar add for cvar name (e.g. $foodAmountAdd).
fn firstCvarAdd(body: []const u8, cvar: []const u8) ?f32 {
    var i: usize = 0;
    while (i < body.len) {
        const ti = std.mem.findPos(u8, body, i, "triggered_effect") orelse break;
        const end = std.mem.findPos(u8, body, ti, "/>") orelse (std.mem.findPos(u8, body, ti, ">") orelse break);
        const win = body[ti .. end + 2];
        const cv = xml.attr(win, 0, "cvar") orelse {
            i = ti + 10;
            continue;
        };
        if (!std.mem.eql(u8, cv, cvar)) {
            i = ti + 10;
            continue;
        }
        const op = xml.attr(win, 0, "operation") orelse {
            i = ti + 10;
            continue;
        };
        if (!(std.mem.eql(u8, op, "add") or std.mem.eql(u8, op, "set"))) {
            i = ti + 10;
            continue;
        }
        if (xml.attr(win, 0, "value")) |v| {
            return xml.parseF32(v);
        }
        i = ti + 10;
    }
    return null;
}

/// First `AddProgressionLevel` triggered_effect: (progression_name, level).
/// Magazines ship `level="1"` (add 1, clamped to class max). Absolute
/// `SetProgressionLevel` rows are collected separately via
/// `collectProgressionSetMax`.
fn firstProgressionAdd(body: []const u8) ?struct { []const u8, u8 } {
    var i: usize = 0;
    while (i < body.len) {
        const ti = std.mem.findPos(u8, body, i, "triggered_effect") orelse break;
        const end = std.mem.findPos(u8, body, ti, "/>") orelse (std.mem.findPos(u8, body, ti, ">") orelse break);
        const win = body[ti .. end + 2];
        const action = xml.attr(win, 0, "action") orelse {
            i = ti + 10;
            continue;
        };
        if (!std.mem.eql(u8, action, "AddProgressionLevel")) {
            i = ti + 10;
            continue;
        }
        const pname = xml.attr(win, 0, "progression_name") orelse {
            i = ti + 10;
            continue;
        };
        const raw = xml.attr(win, 0, "level") orelse "1";
        const lvl = xml.parseI32Prefix(raw) orelse 1;
        if (lvl <= 0) {
            i = ti + 10;
            continue;
        }
        const add: u8 = if (lvl > 255) 255 else @intCast(lvl);
        return .{ pname, add };
    }
    return null;
}

/// Collect `SetProgressionLevel` names with `level="-1"` (RE minevents.md
/// IL=104: set ProgressionClass.MaxLevel). Stock ships only `-1`; other
/// levels are omitted rather than guessed. Arena owns the returned names.
fn collectProgressionSetMax(arena: std.mem.Allocator, body: []const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    // Names live in the items arena; only the list storage needs teardown on error.
    errdefer names.deinit(arena);
    var i: usize = 0;
    while (i < body.len) {
        const ti = std.mem.findPos(u8, body, i, "triggered_effect") orelse break;
        const end = std.mem.findPos(u8, body, ti, "/>") orelse (std.mem.findPos(u8, body, ti, ">") orelse break);
        const win = body[ti .. end + 2];
        const action = xml.attr(win, 0, "action") orelse {
            i = ti + 10;
            continue;
        };
        if (!std.mem.eql(u8, action, "SetProgressionLevel")) {
            i = ti + 10;
            continue;
        }
        const pname = xml.attr(win, 0, "progression_name") orelse {
            i = ti + 10;
            continue;
        };
        const raw = xml.attr(win, 0, "level") orelse {
            i = ti + 10;
            continue;
        };
        const lvl = xml.parseI32Prefix(raw) orelse {
            i = ti + 10;
            continue;
        };
        if (lvl != -1) {
            i = ti + 10;
            continue;
        }
        try names.append(arena, try arena.dupe(u8, pname));
        i = ti + 10;
    }
    if (names.items.len == 0) {
        names.deinit(arena);
        return &.{};
    }
    return try names.toOwnedSlice(arena);
}

/// First `GiveExp` triggered_effect exp amount. Magazines ship 50.
/// Cvar-backed GiveExp is not modelled (stock magazines use a literal).
fn firstGiveExp(body: []const u8) u16 {
    var i: usize = 0;
    while (i < body.len) {
        const ti = std.mem.findPos(u8, body, i, "triggered_effect") orelse break;
        const end = std.mem.findPos(u8, body, ti, "/>") orelse (std.mem.findPos(u8, body, ti, ">") orelse break);
        const win = body[ti .. end + 2];
        const action = xml.attr(win, 0, "action") orelse {
            i = ti + 10;
            continue;
        };
        if (!std.mem.eql(u8, action, "GiveExp")) {
            i = ti + 10;
            continue;
        }
        const raw = xml.attr(win, 0, "exp") orelse {
            i = ti + 10;
            continue;
        };
        const n = xml.parseI32Prefix(raw) orelse 0;
        if (n <= 0) {
            i = ti + 10;
            continue;
        }
        return if (n > 65535) 65535 else @intCast(n);
    }
    return 0;
}

/// Builtin ECS catalog (stable small ids for sim/save).
/// Stock's clamp on a sandbox-scaled stack (ItemClass.get_MaxCount IL_003F).
pub const max_scaled_stack: i32 = 30000;

/// `Utils::FastRoundToInt` (IL=1616): `(int)Math.Round((double)f)`, i.e. .NET's
/// default midpoint-to-even rounding - not away-from-zero. A 7.5 product is 8
/// and a 6.5 product is 6, which matters because the stock MaxStackSize
/// multipliers include .25/.5/.75/1.25/1.5/1.75/2.5.
fn fastRoundToInt(v: f32) i32 {
    const f = @floor(v);
    if (v - f == 0.5) {
        // Midpoint: the even neighbour wins.
        return @intFromFloat(if (@mod(f, 2.0) == 0) f else f + 1);
    }
    return @intFromFloat(@round(v));
}

pub const builtin_defs = [_]ItemDef{
    .{ .id = 0, .name = "none", .stack = 0 },
    .{ .id = 1, .name = "scrap", .stack = 60000, .stock_type = 0 },
    .{ .id = 2, .name = "food", .stack = 50, .is_eat = true, .food_amount = 15, .food_health = 7 },
    .{ .id = 3, .name = "ammo", .stack = 150 },
    .{ .id = 4, .name = "medicine", .stack = 10, .food_health = 25 },
    .{ .id = 5, .name = "tool", .stack = 1 },
    .{ .id = 6, .name = "dukeCoin", .stack = 60000 },
    .{ .id = 7, .name = "wood", .stack = 60000 },
    .{ .id = 8, .name = "stoneAxe", .stack = 1 },
    .{ .id = 9, .name = "meleeClub", .stack = 1 },
    .{ .id = 10, .name = "cobblePlaceable", .stack = 50 },
    .{ .id = 11, .name = "armorScrap", .stack = 1 },
    .{ .id = 12, .name = "questToken", .stack = 20 },
};

/// Map builtin ECS id → stock items.xml name (vanilla; names stable through V3.1.0 b14).
pub fn builtinStockName(item_id: u16) ?[]const u8 {
    return switch (item_id) {
        1 => "resourceScrapIron",
        2 => "foodCanBeef",
        3 => "ammo9mmBulletBall",
        4 => "medicalFirstAidBandage",
        5 => "meleeToolRepairT0StoneAxe",
        6 => "casinoCoin",
        7 => "resourceWood",
        8 => "meleeToolRepairT0StoneAxe",
        9 => "meleeWpnClubT0WoodenClub",
        10 => "resourceCobblestones",
        11 => "armorPrimitiveHelmet",
        12 => "questItem",
        else => null,
    };
}

/// Load items.xml: assign stock types like ItemClass.assignLeftOverItems
/// (first free id = ItemsStartHere+1, then sequential in document order).
/// Body of an item element's `<stats>` child, or null when it is absent or
/// self-closing (stock scans `_element.Elements("stats")`).
/// `<property value="true"/>`: stock's XML bool for an item property, null
/// when the text is neither spelling (the caller keeps the default).
fn boolProp(v: []const u8) ?bool {
    const t = std.mem.trim(u8, v, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(t, "true") or std.mem.eql(u8, t, "1")) return true;
    if (std.ascii.eqlIgnoreCase(t, "false") or std.mem.eql(u8, t, "0")) return false;
    return null;
}

fn itemStatsBody(body: []const u8) ?[]const u8 {
    const si = std.mem.findPos(u8, body, 0, "<stats") orelse return null;
    const gt = std.mem.findPos(u8, body, si, ">") orelse return null;
    if (gt == si or body[gt - 1] == '/') return null;
    const close = std.mem.findPos(u8, body, gt, "</stats>") orelse return null;
    return body[gt + 1 .. close];
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !ItemTable {
    const clean = try xml.readCleanFile(allocator, path);
    defer allocator.free(clean);

    const arena_holder = try arena_util.newArenaHolder(allocator);
    errdefer {
        arena_holder.deinit();
        allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();

    var stock_names: std.ArrayList([]const u8) = .empty;
    defer stock_names.deinit(allocator);
    var stock_types: std.ArrayList(i32) = .empty;
    defer stock_types.deinit(allocator);
    var stock_stacks: std.ArrayList(u16) = .empty;
    defer stock_stacks.deinit(allocator);
    // Stacknumber Extends resolution: own value (0 = none declared) and the
    // item's Extends target per stock_names row, resolved after the loop.
    var own_stacks: std.ArrayList(u16) = .empty;
    defer own_stacks.deinit(allocator);
    var ext_names: std.ArrayList([]const u8) = .empty;
    defer ext_names.deinit(allocator);
    var stock_econs: std.ArrayList(f32) = .empty;
    defer stock_econs.deinit(allocator);
    var stock_econ_declared: std.ArrayList(bool) = .empty;
    defer stock_econ_declared.deinit(allocator);
    var stock_bundles: std.ArrayList(u16) = .empty;
    defer stock_bundles.deinit(allocator);
    var stock_bundle_declared: std.ArrayList(bool) = .empty;
    defer stock_bundle_declared.deinit(allocator);
    var stock_econ_scales: std.ArrayList(f32) = .empty;
    defer stock_econ_scales.deinit(allocator);
    var stock_tq_min: std.ArrayList(f32) = .empty;
    defer stock_tq_min.deinit(allocator);
    var stock_tq_max: std.ArrayList(f32) = .empty;
    defer stock_tq_max.deinit(allocator);
    var stock_tq_declared: std.ArrayList(bool) = .empty;
    defer stock_tq_declared.deinit(allocator);
    var stock_edmgs: std.ArrayList(f32) = .empty;
    defer stock_edmgs.deinit(allocator);
    var stock_place_names: std.ArrayList([]const u8) = .empty;
    defer stock_place_names.deinit(allocator);
    var stock_dmg_blocks: std.ArrayList(f32) = .empty;
    defer stock_dmg_blocks.deinit(allocator);
    var stock_light_values: std.ArrayList(f32) = .empty;
    defer stock_light_values.deinit(allocator);
    var stock_melee_ranges: std.ArrayList(f32) = .empty;
    defer stock_melee_ranges.deinit(allocator);
    var stock_fuels: std.ArrayList(f32) = .empty;
    defer stock_fuels.deinit(allocator);
    var stock_craft_times: std.ArrayList(f32) = .empty;
    defer stock_craft_times.deinit(allocator);
    var stock_weights: std.ArrayList(u16) = .empty;
    defer stock_weights.deinit(allocator);
    var stock_weight_declared: std.ArrayList(bool) = .empty;
    defer stock_weight_declared.deinit(allocator);
    var stock_melt_times: std.ArrayList(f32) = .empty;
    defer stock_melt_times.deinit(allocator);
    var stock_melt_declared: std.ArrayList(bool) = .empty;
    defer stock_melt_declared.deinit(allocator);
    var stock_materials: std.ArrayList([]const u8) = .empty;
    defer stock_materials.deinit(allocator);
    var stock_material_declared: std.ArrayList(bool) = .empty;
    defer stock_material_declared.deinit(allocator);
    var stock_no_scrapping: std.ArrayList(bool) = .empty;
    defer stock_no_scrapping.deinit(allocator);
    var stock_sellable: std.ArrayList(bool) = .empty;
    defer stock_sellable.deinit(allocator);
    var stock_sellable_declared: std.ArrayList(bool) = .empty;
    defer stock_sellable_declared.deinit(allocator);
    var stock_is_eat: std.ArrayList(bool) = .empty;
    defer stock_is_eat.deinit(allocator);
    var stock_food_amt: std.ArrayList(f32) = .empty;
    defer stock_food_amt.deinit(allocator);
    var stock_food_hp: std.ArrayList(f32) = .empty;
    defer stock_food_hp.deinit(allocator);
    var stock_water_amt: std.ArrayList(f32) = .empty;
    defer stock_water_amt.deinit(allocator);
    var stock_prog_name: std.ArrayList([]const u8) = .empty;
    defer stock_prog_name.deinit(allocator);
    var stock_prog_add: std.ArrayList(u8) = .empty;
    defer stock_prog_add.deinit(allocator);
    var stock_prog_set_max: std.ArrayList([]const []const u8) = .empty;
    defer stock_prog_set_max.deinit(allocator);
    var stock_eat_exp: std.ArrayList(u16) = .empty;
    defer stock_eat_exp.deinit(allocator);
    var stock_dtags: std.ArrayList(u8) = .empty;
    defer stock_dtags.deinit(allocator);
    var stock_dradius: std.ArrayList(f32) = .empty;
    var stock_pdr_curves: std.ArrayList([buffs.max_curve_len]f32) = .empty;
    defer stock_pdr_curves.deinit(allocator);
    var stock_pdr_n: std.ArrayList(u8) = .empty;
    defer stock_pdr_n.deinit(allocator);
    var stock_edr_curves: std.ArrayList([buffs.max_curve_len]f32) = .empty;
    defer stock_edr_curves.deinit(allocator);
    var stock_edr_n: std.ArrayList(u8) = .empty;
    defer stock_edr_n.deinit(allocator);
    var stock_mslots_curves: std.ArrayList([buffs.max_curve_len]f32) = .empty;
    defer stock_mslots_curves.deinit(allocator);
    var stock_mslots_n: std.ArrayList(u8) = .empty;
    defer stock_mslots_n.deinit(allocator);
    var stock_smelt_curves: std.ArrayList([buffs.max_curve_len]f32) = .empty;
    defer stock_smelt_curves.deinit(allocator);
    var stock_smelt_n: std.ArrayList(u8) = .empty;
    defer stock_smelt_n.deinit(allocator);
    var stock_tags: std.ArrayList([]const u8) = .empty;
    defer stock_tags.deinit(allocator);
    var stock_armor_group: std.ArrayList([]const u8) = .empty;
    defer stock_armor_group.deinit(allocator);
    var stock_degrad_per_use: std.ArrayList(f32) = .empty;
    defer stock_degrad_per_use.deinit(allocator);
    var stock_stamina_loss: std.ArrayList(f32) = .empty;
    defer stock_stamina_loss.deinit(allocator);
    var stock_dismember_chance: std.ArrayList(f32) = .empty;
    defer stock_dismember_chance.deinit(allocator);
    var stock_target_armor: std.ArrayList(f32) = .empty;
    defer stock_target_armor.deinit(allocator);
    var stock_target_armor_tagged: std.ArrayList(f32) = .empty;
    defer stock_target_armor_tagged.deinit(allocator);
    var stock_target_armor_tag: std.ArrayList([]const u8) = .empty;
    defer stock_target_armor_tag.deinit(allocator);
    var stock_gs_stats: std.ArrayList([]const GsStat) = .empty;
    defer stock_gs_stats.deinit(allocator);
    var gs_stats_total: usize = 0;
    var stock_harvest_rows: std.ArrayList([]const HarvestCountRow) = .empty;
    defer stock_harvest_rows.deinit(allocator);
    defer stock_dradius.deinit(allocator);
    var stock_dlifetime: std.ArrayList(i32) = .empty;
    defer stock_dlifetime.deinit(allocator);
    var stock_dstrength: std.ArrayList(f32) = .empty;
    defer stock_dstrength.deinit(allocator);
    var stock_deat: std.ArrayList(i32) = .empty;
    defer stock_deat.deinit(allocator);
    var stock_degrad_min: std.ArrayList(u32) = .empty;
    defer stock_degrad_min.deinit(allocator);
    var stock_degrad_max: std.ArrayList(u32) = .empty;
    defer stock_degrad_max.deinit(allocator);
    var stock_has_quality: std.ArrayList(bool) = .empty;
    defer stock_has_quality.deinit(allocator);
    var stock_effect_group_declared: std.ArrayList(bool) = .empty;
    defer stock_effect_group_declared.deinit(allocator);
    // Full `<passive_effect>` surface per item (same rows and gates buffs
    // carry). The survival VM folds the tracked names over the equipped and
    // held items; the dedicated PDR/EDR curve fields above stay the source for
    // those two names (armorMitigation owns them).
    var stock_passive_ranges: std.ArrayList(struct { usize, usize }) = .empty;
    defer stock_passive_ranges.deinit(allocator);
    var passives_pool: std.ArrayList(buffs.Passive) = .empty;
    defer passives_pool.deinit(allocator);
    var passive_reqs_pool: std.ArrayList(requirements.Requirement) = .empty;
    defer passive_reqs_pool.deinit(allocator);
    var passive_req_ranges: std.ArrayList(struct { usize, usize }) = .empty;
    defer passive_req_ranges.deinit(allocator);

    var next_stock: i32 = stock_first_item_type;
    var i: usize = 0;
    while (i < clean.len and stock_names.items.len < max_items) {
        const ii = std.mem.findPos(u8, clean, i, "<item ") orelse break;
        const name = xml.attr(clean, ii, "name") orelse {
            i = ii + 6;
            continue;
        };
        var exists = false;
        for (stock_names.items) |n| {
            if (std.mem.eql(u8, n, name)) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            // Stacknumber + EconomicValue from this item's property block.
            const item_end = std.mem.findPos(u8, clean, ii + 6, "<item ") orelse clean.len;
            const stack_own = xml.propertyValue(clean[ii..item_end], "Stacknumber");
            var stack: u16 = stock_default_stack;
            if (stack_own) |v| {
                stack = xml.parseU16(v) orelse stock_default_stack;
            }
            try own_stacks.append(allocator, if (stack_own != null) stack else 0);
            const ext = xml.propertyValue(clean[ii..item_end], "Extends");
            try ext_names.append(allocator, if (ext) |e| try arena.dupe(u8, e) else "");
            // Single, not an integer: stock fields EconomicValue as `Single`
            // and parses it with ParseFloat (ItemClass IL_0666), so a modlet
            // can price an item above 65535 or with a fraction. Typing this
            // u16 turned either into 0, i.e. "not purchasable".
            var econ: f32 = 0;
            var econ_declared = false;
            if (xml.propertyValue(clean[ii..item_end], "EconomicValue")) |v| {
                econ = xml.parseF32(v) orelse 0;
                econ_declared = true;
            }
            try stock_econs.append(allocator, econ);
            try stock_econ_declared.append(allocator, econ_declared);
            // EconomicBundleSize (RE loot-economy.md §5): GetBuyPrice /
            // GetSellPrice divide the unit price by the bundle. 89 stock
            // items carry it (ammoGasCan 100, resourceWood 50, …); absent = 1.
            var bundle: u16 = 1;
            var bundle_declared = false;
            if (xml.propertyValue(clean[ii..item_end], "EconomicBundleSize")) |v| {
                bundle = xml.parseU16(v) orelse 1;
                bundle_declared = true;
            }
            try stock_bundles.append(allocator, bundle);
            try stock_bundle_declared.append(allocator, bundle_declared);
            // A39: EconomicSellScale (default 1.0 = stock ItemClass ctor IL).
            // TraderQualityMod: a "min,max" pair (or the two separate keys a
            // modlet may use). Either value present marks the row declared, so
            // an explicit 1 is honoured over the trader's pair.
            var tq_min: f32 = 0;
            var tq_max: f32 = 0;
            var tq_declared = false;
            if (xml.propertyValue(clean[ii..item_end], "TraderQualityMod")) |v| {
                var it = std.mem.splitScalar(u8, v, ',');
                if (it.next()) |lo| tq_min = xml.parseF32(std.mem.trim(u8, lo, " \t")) orelse 0;
                if (it.next()) |hi| tq_max = xml.parseF32(std.mem.trim(u8, hi, " \t")) orelse tq_min;
                if (tq_max == 0) tq_max = tq_min;
                tq_declared = true;
            }
            if (xml.propertyValue(clean[ii..item_end], "TraderQualityMinMod")) |v| {
                tq_min = xml.parseF32(v) orelse tq_min;
                tq_declared = true;
            }
            if (xml.propertyValue(clean[ii..item_end], "TraderQualityMaxMod")) |v| {
                tq_max = xml.parseF32(v) orelse tq_max;
                tq_declared = true;
            }
            try stock_tq_min.append(allocator, tq_min);
            try stock_tq_max.append(allocator, tq_max);
            try stock_tq_declared.append(allocator, tq_declared);
            var econ_scale: f32 = 1.0;
            if (xml.propertyValue(clean[ii..item_end], "EconomicSellScale")) |v| {
                econ_scale = xml.parseF32(v) orelse 1.0;
            }
            try stock_econ_scales.append(allocator, econ_scale);
            // Action0 DamageEntity (first hit; melee hands and weapons).
            var edmg: f32 = 0;
            if (xml.propertyValue(clean[ii..item_end], "DamageEntity")) |v| {
                edmg = xml.parseF32(v) orelse 0;
            }
            // Club/axe declare damage only as the EntityDamage passive effect
            // (operation=base_set; perk-tagged perc_add rows are ignored
            // without perks). Stock: club 12, stone axe 6.
            if (edmg == 0) {
                if (xml.passiveEffectValue(clean[ii..item_end], "EntityDamage")) |v| {
                    edmg = xml.parseF32(v) orelse 0;
                }
            }
            try stock_edmgs.append(allocator, edmg);
            // ItemActionPlaceAsBlock (Action1 Class=PlaceAsBlock): only items
            // with a Blockname place (stock b14 exactly two). Empty = not
            // placeable; resolved via AssignIds at place time.
            var place_name: []const u8 = "";
            if (itemActionClassIs(clean[ii..item_end], "PlaceAsBlock")) {
                if (xml.propertyValue(clean[ii..item_end], "Blockname")) |bn| place_name = try arena.dupe(u8, bn);
            }
            try stock_place_names.append(allocator, place_name);
            // DamageBlock property (hand items: zombie hand 8, feral 24).
            var dmg_block: f32 = 0;
            if (xml.propertyValue(clean[ii..item_end], "DamageBlock")) |v| {
                dmg_block = xml.parseF32(v) orelse 0;
            }
            try stock_dmg_blocks.append(allocator, dmg_block);
            // LightValue property (held-item light: torches, flashlights,
            // weapon lights). The stealth selfLight term (rule 15).
            var light_val: f32 = 0;
            if (xml.propertyValue(clean[ii..item_end], "LightValue")) |v| {
                light_val = std.math.clamp(xml.parseF32(v) orelse 0, 0, 1);
            }
            try stock_light_values.append(allocator, light_val);
            // Melee reach: `Range` property (zombie hand 1.6) or the passive
            // `MaxRange` (club/axe 2.4). Drives the AI attack-range gate.
            var mrange: f32 = 0;
            if (xml.propertyValue(clean[ii..item_end], "Range")) |v| {
                mrange = xml.parseF32(v) orelse 0;
            }
            if (mrange <= 0) {
                if (xml.passiveEffectValue(clean[ii..item_end], "MaxRange")) |v| {
                    mrange = xml.parseF32(v) orelse 0;
                }
            }
            try stock_melee_ranges.append(allocator, mrange);
            var fuel: f32 = 0;
            if (xml.propertyValue(clean[ii..item_end], "FuelValue")) |v| {
                fuel = xml.parseF32(v) orelse 0;
            }
            try stock_fuels.append(allocator, fuel);
            // Stock `ItemClass.CraftComponentTime` (IL_061D): the
            // `CraftTimeValue` property, parsed with TryParseFloat (a bad
            // value leaves the 0 default, like the FuelValue arm above).
            var cct: f32 = 0;
            if (xml.propertyValue(clean[ii..item_end], "CraftTimeValue")) |v| {
                cct = xml.parseF32(v) orelse 0;
            }
            try stock_craft_times.append(allocator, cct);
            var weight: u16 = 0;
            var weight_declared = false;
            if (xml.propertyValue(clean[ii..item_end], "Weight")) |v| {
                weight_declared = true;
                const w = xml.parseF32(v) orelse 0;
                if (w > 0 and w <= @as(f32, @floatFromInt(std.math.maxInt(u16)))) {
                    weight = @trunc(w);
                }
            }
            try stock_weights.append(allocator, weight);
            try stock_weight_declared.append(allocator, weight_declared);
            var melt_t: f32 = 0;
            var melt_declared = false;
            if (xml.propertyValue(clean[ii..item_end], "MeltTimePerUnit")) |v| {
                melt_declared = true;
                melt_t = xml.parseF32(v) orelse 0;
            }
            try stock_melt_times.append(allocator, melt_t);
            try stock_melt_declared.append(allocator, melt_declared);
            // items.xml Material → MadeOfMaterial; forge melt looks up
            // materials.xml forge_category through this id.
            var mat_name: []const u8 = "";
            var mat_declared = false;
            if (xml.propertyValue(clean[ii..item_end], "Material")) |mv| {
                mat_declared = true;
                mat_name = try arena.dupe(u8, mv);
            }
            try stock_materials.append(allocator, mat_name);
            try stock_material_declared.append(allocator, mat_declared);
            // items.xml NoScrapping: GetScrapableRecipe rejects these.
            var no_scrap = false;
            if (xml.propertyValue(clean[ii..item_end], "NoScrapping")) |v| {
                no_scrap = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "True");
            }
            try stock_no_scrapping.append(allocator, no_scrap);
            // items.xml SellableToTrader (ItemClass ParseBool; default true):
            // the trader refuses to buy these, so the sell path gates on it.
            var sellable = true;
            var sellable_declared = false;
            if (xml.propertyValue(clean[ii..item_end], "SellableToTrader")) |v| {
                sellable = boolProp(v) orelse true;
                sellable_declared = true;
            }
            try stock_sellable.append(allocator, sellable);
            try stock_sellable_declared.append(allocator, sellable_declared);
            // ItemActionEat: Action0 Class=Eat + effect_group cvars.
            const body = clean[ii..item_end];
            // Every `<passive_effect>` row on the item, through the buffs
            // scanner (rows and gates have one shape across both files).
            // Truncation is silent per item; the total is capped so a crafted
            // items.xml cannot exhaust the arena. The scanner takes the element
            // BODY (as buffs passes the `<buff>` body), so the enclosing
            // `<item>` tag is skipped here; a self-closing `<item/>` has none.
            {
                const p0 = passives_pool.items.len;
                const budget = @min(p0 + max_passives_per_item, max_item_passives_total);
                if (std.mem.findPos(u8, body, 0, ">")) |igt| {
                    const inner_start = igt + 1;
                    if (!(igt > 0 and body[igt - 1] == '/')) {
                        const inner_end = std.mem.findPos(u8, body, inner_start, "</item>") orelse body.len;
                        if (budget > p0 and inner_end > inner_start) {
                            _ = try buffs.scanPassives(allocator, arena, body[inner_start..inner_end], &passives_pool, &passive_reqs_pool, &passive_req_ranges, budget);
                        }
                    }
                }
                try stock_passive_ranges.append(allocator, .{ p0, passives_pool.items.len - p0 });
            }
            var is_eat = itemActionClassIs(body, "Eat");
            const food_amt: f32 = firstCvarAdd(body, "$foodAmountAdd") orelse 0;
            // HP on consume: food items carry `foodHealthAmount`; medical
            // items heal through the `medicalRegHealthAmount` cvar instead
            // (stock bandage 30/action, medkit 400). Both feed EatProps.hp.
            const food_hp: f32 = firstCvarAdd(body, "foodHealthAmount") orelse
                firstCvarAdd(body, "medicalRegHealthAmount") orelse 0;
            const water_amt: f32 = firstCvarAdd(body, "$waterAmountAdd") orelse 0;
            if (!is_eat and (food_amt > 0 or water_amt > 0)) is_eat = true;
            // No name heuristic here: stock's eatability is the presence of an
            // `ItemActionEat` (ItemClass.Action0/1), and a `food*`/`drink*`
            // prefix marked four real stock rows eatable - the
            // `foodCanShamSchematic` unlock, the `foodRawMeatBundle` open-bundle
            // action and the empty jars (`drinkJarEmpty` collects water,
            // `drinkJarGrey` has no action) - so moving one on the C2S
            // inventory path read as a meal and restored hunger/water.
            var prog_name: []const u8 = "";
            var prog_add: u8 = 0;
            if (firstProgressionAdd(body)) |pg| {
                prog_name = try arena.dupe(u8, pg[0]);
                prog_add = pg[1];
                is_eat = true;
            }
            const prog_set_max = try collectProgressionSetMax(arena, body);
            if (prog_set_max.len > 0) is_eat = true;
            try stock_is_eat.append(allocator, is_eat);
            try stock_food_amt.append(allocator, food_amt);
            try stock_food_hp.append(allocator, food_hp);
            try stock_water_amt.append(allocator, water_amt);
            try stock_prog_name.append(allocator, prog_name);
            try stock_prog_add.append(allocator, prog_add);
            try stock_prog_set_max.append(allocator, prog_set_max);
            try stock_eat_exp.append(allocator, firstGiveExp(body));
            // EntityItem distraction (stock decoy: `zombie,requires_contact`).
            var dtags: u8 = 0;
            if (xml.propertyValue(body, "DistractionTags")) |v| {
                var t = v;
                while (t.len > 0) {
                    const comma = std.mem.findScalar(u8, t, ',') orelse t.len;
                    const tag = t[0..comma];
                    if (std.mem.eql(u8, tag, "eat")) dtags |= 1;
                    if (std.mem.eql(u8, tag, "requires_contact")) dtags |= 2;
                    if (std.mem.eql(u8, tag, "zombie")) dtags |= 4;
                    t = if (comma < t.len) t[comma + 1 ..] else "";
                }
            }
            var dradius: f32 = 0;
            if (xml.passiveEffectValue(body, "DistractionRadius")) |v| {
                dradius = xml.parseF32(v) orelse 0;
            }
            var dlifetime: i32 = 0;
            if (xml.passiveEffectValue(body, "DistractionLifetime")) |v| {
                dlifetime = std.fmt.parseInt(i32, v, 10) catch 0;
            }
            var dstrength: f32 = 0;
            if (xml.passiveEffectValue(body, "DistractionStrength")) |v| {
                dstrength = xml.parseF32(v) orelse 0;
            }
            // Armor resist passives (41/42): quality curves. The curve
            // segments are the per-quality values scaled over Q1..Q6 (stock
            // PassiveEffect.ModValue interpolation, RE items.md).
            var pdr_curve: [buffs.max_curve_len]f32 = .{0} ** buffs.max_curve_len;
            var pdr_n: u8 = 0;
            const pdr_v = xml.passiveEffectValue(body, "PhysicalDamageResist");
            if (pdr_v) |v| {
                pdr_n = buffs.parseCurveValue(v, &pdr_curve);
            }
            var edr_curve: [buffs.max_curve_len]f32 = .{0} ** buffs.max_curve_len;
            var edr_n: u8 = 0;
            const edr_v = xml.passiveEffectValue(body, "ElementalDamageResist");
            if (edr_v) |v| {
                edr_n = buffs.parseCurveValue(v, &edr_curve);
            }
            try stock_pdr_curves.append(allocator, pdr_curve);
            try stock_pdr_n.append(allocator, pdr_n);
            try stock_edr_curves.append(allocator, edr_curve);
            try stock_edr_n.append(allocator, edr_n);
            // ModSlots passive (quality curve, RE items.md CalcModSlotCount):
            // the mod-capacity budget per quality tier; 0 = no row (fail
            // closed in the mod scrub).
            var mslots_curve: [buffs.max_curve_len]f32 = .{0} ** buffs.max_curve_len;
            var mslots_n: u8 = 0;
            const mslots_v = xml.passiveEffectValue(body, "ModSlots");
            if (mslots_v) |v| {
                mslots_n = buffs.parseCurveValue(v, &mslots_curve);
            }
            try stock_mslots_curves.append(allocator, mslots_curve);
            try stock_mslots_n.append(allocator, mslots_n);
            // CraftingSmeltTime (PassiveEffects 95, perc_add quality curve):
            // forge tools (toolBellows) scale melt duration. 0 = no row.
            var smelt_curve: [buffs.max_curve_len]f32 = .{0} ** buffs.max_curve_len;
            var smelt_n: u8 = 0;
            const smelt_v = xml.passiveEffectValue(body, "CraftingSmeltTime");
            if (smelt_v) |v| {
                smelt_n = buffs.parseCurveValue(v, &smelt_curve);
            }
            try stock_smelt_curves.append(allocator, smelt_curve);
            try stock_smelt_n.append(allocator, smelt_n);
            // Tags property: the mod-attachment tag surface (comma list).
            const tags = xml.propertyValue(body, "Tags") orelse "";
            try stock_tags.append(allocator, tags);
            try stock_armor_group.append(allocator, xml.propertyValue(body, "ArmorGroup") orelse "");
            // DegradationPerUse (base_set): the per-use durability wear.
            // The 3 perc_add rows are the modifier form - recorded.
            var degrad_per_use: f32 = 0;
            if (xml.passiveEffectValue(body, "DegradationPerUse")) |v| {
                if (xml.passiveOperation(body, "DegradationPerUse") == null or
                    std.mem.eql(u8, xml.passiveOperation(body, "DegradationPerUse").?, "base_set"))
                {
                    degrad_per_use = xml.parseF32(v) orelse 0;
                }
            }
            // TargetArmor (163, perc_add): armor penetration. Only UNTAGGED
            // rows apply without perk-tag evaluation (the perkJavelinMaster
            // rows are the recorded tag-gated leg).
            var target_armor: f32 = 0;
            var target_armor_tagged: f32 = 0;
            var target_armor_tag: []const u8 = "";
            // First row wins for each class: untagged applies always, the
            // tagged row applies only when the attacker owns the perk (the
            // tag is the perk name, e.g. perkJavelinMaster).
            if (xml.passiveEffectRow(body, "TargetArmor")) |row| {
                if (xml.attr(row, 0, "tags") == null) {
                    if (xml.attr(row, 0, "value")) |v| target_armor = xml.parseF32(v) orelse 0;
                } else {
                    if (xml.attr(row, 0, "value")) |v| target_armor_tagged = xml.parseF32(v) orelse 0;
                    if (xml.attr(row, 0, "tags")) |t| target_armor_tag = try arena.dupe(u8, t);
                }
            }
            try stock_degrad_per_use.append(allocator, degrad_per_use);
            var stamina_loss: f32 = 0;
            if (xml.passiveEffectRow(body, "StaminaLoss")) |row| {
                if (xml.attr(row, 0, "value")) |v| stamina_loss = xml.parseF32(v) orelse 0;
            }
            try stock_stamina_loss.append(allocator, stamina_loss);
            // DismemberChance (144): first row value, same first-match rule
            // as StaminaLoss above. Perk-tagged rows (e.g. perkMiner69r) are
            // the attacker's DismemberSelfChance side, not the weapon's, so
            // they do not belong here; only an untagged row counts.
            var dismember_chance: f32 = 0;
            var di: usize = 0;
            while (di < body.len) {
                const pi = std.mem.findPos(u8, body, di, "<passive_effect") orelse break;
                const pname = xml.attr(body, pi, "name") orelse {
                    di = pi + 15;
                    continue;
                };
                if (!std.mem.eql(u8, pname, "DismemberChance")) {
                    di = pi + 15;
                    continue;
                }
                if (xml.attr(body, pi, "tags") != null) {
                    di = pi + 15;
                    continue;
                }
                if (xml.attr(body, pi, "value")) |v| dismember_chance = xml.parseF32(v) orelse 0;
                break;
            }
            try stock_dismember_chance.append(allocator, dismember_chance);
            try stock_target_armor.append(allocator, target_armor);
            try stock_target_armor_tagged.append(allocator, target_armor_tagged);
            try stock_target_armor_tag.append(allocator, target_armor_tag);
            // HarvestCount (141): ALL rows on the item (tools carry one row
            // per gating tag; the club/spear family carries three).
            var harvest_rows: std.ArrayList(HarvestCountRow) = .empty;
            defer harvest_rows.deinit(allocator);
            var hp: usize = 0;
            while (hp < body.len) {
                const hi = std.mem.findPos(u8, body, hp, "<passive_effect") orelse break;
                const hname = xml.attr(body, hi, "name") orelse {
                    hp = hi + 15;
                    continue;
                };
                if (std.mem.eql(u8, hname, "HarvestCount")) {
                    const row: HarvestCountRow = .{
                        .op = if (std.mem.eql(u8, xml.attr(body, hi, "operation") orelse "", "base_set"))
                            .base_set
                        else if (std.mem.eql(u8, xml.attr(body, hi, "operation") orelse "", "perc_add"))
                            .perc_add
                        else
                            .base_add,
                        .tags = if (xml.attr(body, hi, "tags")) |t| try arena.dupe(u8, t) else "",
                    };
                    if (xml.attr(body, hi, "value")) |v| {
                        if (std.mem.findScalar(u8, v, ',')) |_| {
                            var curve: [buffs.max_curve_len]f32 = .{0} ** buffs.max_curve_len;
                            var curve_copy: [buffs.max_curve_len]f32 = .{0} ** buffs.max_curve_len;
                            const cn = buffs.parseCurveValue(v, &curve_copy);
                            @memcpy(curve[0..cn], curve_copy[0..cn]);
                            try harvest_rows.append(allocator, .{ .op = row.op, .curve = curve, .curve_n = @intCast(cn), .tags = row.tags });
                        } else {
                            try harvest_rows.append(allocator, .{ .op = row.op, .value = xml.parseF32(v) orelse 0, .tags = row.tags });
                        }
                    } else {
                        try harvest_rows.append(allocator, row);
                    }
                }
                hp = hi + 15;
            }
            if (harvest_rows.items.len > 0) {
                const slice = try arena.alloc(HarvestCountRow, harvest_rows.items.len);
                @memcpy(slice, harvest_rows.items);
                try stock_harvest_rows.append(allocator, slice);
            } else {
                try stock_harvest_rows.append(allocator, &.{});
            }
            // `<stats>`: the gamestage-scaled stat rows (stock
            // ItemClass::GSStatsParseXml IL=181). A row needs a name and at
            // least five comma fields; stock rejects a row whose |min| or |max|
            // reaches 163.835 rather than overflow the i16 cast, and so does
            // this parse.
            var gs_rows: std.ArrayList(GsStat) = .empty;
            defer gs_rows.deinit(allocator);
            if (itemStatsBody(body)) |sbody| {
                var sp: usize = 0;
                while (sp < sbody.len and gs_rows.items.len < max_gs_stats_per_item and
                    gs_stats_total < max_gs_stats_total)
                {
                    const sti = std.mem.findPos(u8, sbody, sp, "<stat ") orelse break;
                    const sname = xml.attr(sbody, sti, "name") orelse {
                        sp = sti + 6;
                        continue;
                    };
                    const sval = xml.attr(sbody, sti, "value") orelse {
                        sp = sti + 6;
                        continue;
                    };
                    sp = sti + 6;
                    if (sname.len == 0 or sval.len == 0) continue;
                    var parts: [5][]const u8 = undefined;
                    var pn: usize = 0;
                    var vit = std.mem.splitScalar(u8, sval, ',');
                    while (vit.next()) |raw| {
                        if (pn >= parts.len) break;
                        parts[pn] = std.mem.trim(u8, raw, " \t");
                        pn += 1;
                    }
                    if (pn < parts.len) continue;
                    const quality = std.fmt.parseInt(i16, parts[0], 10) catch continue;
                    const game_stage = std.fmt.parseInt(i16, parts[1], 10) catch continue;
                    const chance = xml.parseF32(parts[2]) orelse continue;
                    const vmin = xml.parseF32(parts[3]) orelse continue;
                    const vmax = xml.parseF32(parts[4]) orelse continue;
                    if (@abs(vmin) >= gs_stat_limit or @abs(vmax) >= gs_stat_limit) continue;
                    try gs_rows.append(allocator, .{
                        .effect = try arena.dupe(u8, sname),
                        .quality = quality,
                        .game_stage = game_stage,
                        .chance = chance,
                        // C# `(short)float` truncates toward zero.
                        .min = @intFromFloat(@trunc(vmin / gs_stat_scale)),
                        .max = @intFromFloat(@trunc(vmax / gs_stat_scale)),
                    });
                }
            }
            if (gs_rows.items.len > 0) {
                const slice = try arena.alloc(GsStat, gs_rows.items.len);
                @memcpy(slice, gs_rows.items);
                gs_stats_total += slice.len;
                try stock_gs_stats.append(allocator, slice);
            } else {
                try stock_gs_stats.append(allocator, &.{});
            }
            var deat: i32 = 0;
            if (xml.passiveEffectValue(body, "DistractionEatTicks")) |v| {
                deat = std.fmt.parseInt(i32, v, 10) catch 0;
            }
            // DegradationMax (passive 8): the durability cap, quality-tiered
            // "min,max" (tier 1..6 = quality 1..6) or a single constant.
            // Feeds MaxUseTimes -> ItemValue.PercentUsesLeft (worn items sell
            // for less, RE GetSellPrice / items.md §7).
            var dmin: u32 = 0;
            var dmax: u32 = 0;
            if (xml.passiveEffectValue(body, "DegradationMax")) |v| {
                if (std.mem.findScalar(u8, v, ',')) |comma| {
                    dmin = xml.parseU32(v[0..comma]) orelse 0;
                    dmax = xml.parseU32(v[comma + 1 ..]) orelse 0;
                } else {
                    dmax = xml.parseU32(v) orelse 0;
                    dmin = dmax;
                }
            }
            try stock_degrad_min.append(allocator, dmin);
            try stock_degrad_max.append(allocator, dmax);
            // ItemClass.HasQuality (IL=9): any owner-tiered effect_group. An
            // item declaring no effect_group of its own inherits its parent's
            // answer through the Extends pass below.
            try stock_has_quality.append(allocator, xml.hasTieredEffectGroup(body));
            try stock_effect_group_declared.append(allocator, xml.hasEffectGroup(body));
            try stock_dtags.append(allocator, dtags);
            try stock_dradius.append(allocator, dradius);
            try stock_dlifetime.append(allocator, dlifetime);
            try stock_dstrength.append(allocator, dstrength);
            try stock_deat.append(allocator, deat);
            try stock_stacks.append(allocator, stack);
            try stock_names.append(allocator, try arena.dupe(u8, name));
            try stock_types.append(allocator, next_stock);
            next_stock += 1;
        }
        i = ii + 6;
    }

    // Resolve Stacknumber, EconomicValue and EconomicBundleSize through the
    // Extends chain (stock items.xml declares ~1144 Extends properties; a
    // child can precede its parent in the file, so this is a second pass).
    // An item with no Stacknumber anywhere inherits the ItemClass default of
    // 500 (asm.il:749089). EconomicValue inherits like any property (286
    // stock items get their econ from a master, e.g. armorAssassinBoots ->
    // armorMediumMaster econ 1000; no stock item declares EconomicValue="0").
    {
        var own_stack_map: std.StringHashMapUnmanaged(u16) = .{};
        defer own_stack_map.deinit(allocator);
        var own_sellable_map: std.StringHashMapUnmanaged(bool) = .{};
        defer own_sellable_map.deinit(allocator);
        var own_tq_min_map: std.StringHashMapUnmanaged(f32) = .{};
        defer own_tq_min_map.deinit(allocator);
        var own_tq_max_map: std.StringHashMapUnmanaged(f32) = .{};
        defer own_tq_max_map.deinit(allocator);
        var own_econ_map: std.StringHashMapUnmanaged(f32) = .{};
        defer own_econ_map.deinit(allocator);
        var own_bundle_map: std.StringHashMapUnmanaged(u16) = .{};
        defer own_bundle_map.deinit(allocator);
        var own_weight_map: std.StringHashMapUnmanaged(u16) = .{};
        defer own_weight_map.deinit(allocator);
        var own_melt_map: std.StringHashMapUnmanaged(f32) = .{};
        defer own_melt_map.deinit(allocator);
        var own_material_map: std.StringHashMapUnmanaged([]const u8) = .{};
        defer own_material_map.deinit(allocator);
        // Hand-item Range / DamageBlock and the item Tags list inherit too
        // (meleeHandZombieFeral takes its parent's Action0 Range; the loot mod
        // roll and the attachment scrub read the inherited Tags).
        var own_range_map: std.StringHashMapUnmanaged(f32) = .{};
        defer own_range_map.deinit(allocator);
        var own_dmgblock_map: std.StringHashMapUnmanaged(f32) = .{};
        defer own_dmgblock_map.deinit(allocator);
        var own_tags_map: std.StringHashMapUnmanaged([]const u8) = .{};
        defer own_tags_map.deinit(allocator);
        var ext_map: std.StringHashMapUnmanaged([]const u8) = .{};
        defer ext_map.deinit(allocator);
        for (stock_names.items, 0..) |n, idx| {
            if (own_stacks.items[idx] != 0) try own_stack_map.put(allocator, n, own_stacks.items[idx]);
            if (stock_econ_declared.items[idx]) try own_econ_map.put(allocator, n, stock_econs.items[idx]);
            if (stock_tq_declared.items[idx]) {
                try own_tq_min_map.put(allocator, n, stock_tq_min.items[idx]);
                try own_tq_max_map.put(allocator, n, stock_tq_max.items[idx]);
            }
            if (stock_sellable_declared.items[idx]) try own_sellable_map.put(allocator, n, stock_sellable.items[idx]);
            if (stock_bundle_declared.items[idx]) try own_bundle_map.put(allocator, n, stock_bundles.items[idx]);
            if (stock_weight_declared.items[idx]) try own_weight_map.put(allocator, n, stock_weights.items[idx]);
            if (stock_melt_declared.items[idx]) try own_melt_map.put(allocator, n, stock_melt_times.items[idx]);
            if (stock_material_declared.items[idx]) try own_material_map.put(allocator, n, stock_materials.items[idx]);
            // 0 = "unset" for both props (consumers fail closed to the rules
            // floor), so a declared 0 needs no own-map entry.
            if (stock_melee_ranges.items[idx] != 0) try own_range_map.put(allocator, n, stock_melee_ranges.items[idx]);
            if (stock_dmg_blocks.items[idx] != 0) try own_dmgblock_map.put(allocator, n, stock_dmg_blocks.items[idx]);
            if (stock_tags.items[idx].len > 0) try own_tags_map.put(allocator, n, stock_tags.items[idx]);
            if (ext_names.items[idx].len > 0) try ext_map.put(allocator, n, ext_names.items[idx]);
        }
        const max_hops: usize = 24;
        for (stock_names.items, 0..) |n, idx| {
            var cur = n;
            var hops: usize = 0;
            while (hops < max_hops) : (hops += 1) {
                if (own_stack_map.get(cur)) |s| {
                    stock_stacks.items[idx] = s;
                    break;
                }
                cur = ext_map.get(cur) orelse break;
            }
        }
        for (stock_names.items, 0..) |n, idx| {
            var cur = n;
            var hops: usize = 0;
            while (hops < max_hops) : (hops += 1) {
                if (own_sellable_map.get(cur)) |b| {
                    stock_sellable.items[idx] = b;
                    break;
                }
                cur = ext_map.get(cur) orelse break;
            }
        }
        for (stock_names.items, 0..) |n, idx| {
            var cur = n;
            var hops: usize = 0;
            while (hops < max_hops) : (hops += 1) {
                if (own_tq_min_map.get(cur)) |lo| {
                    stock_tq_min.items[idx] = lo;
                    stock_tq_max.items[idx] = own_tq_max_map.get(cur) orelse lo;
                    break;
                }
                cur = ext_map.get(cur) orelse break;
            }
        }
        for (stock_names.items, 0..) |n, idx| {
            var cur = n;
            var hops: usize = 0;
            while (hops < max_hops) : (hops += 1) {
                if (own_econ_map.get(cur)) |e| {
                    stock_econs.items[idx] = e;
                    break;
                }
                cur = ext_map.get(cur) orelse break;
            }
        }
        for (stock_names.items, 0..) |n, idx| {
            var cur = n;
            var hops: usize = 0;
            while (hops < max_hops) : (hops += 1) {
                if (own_bundle_map.get(cur)) |b| {
                    stock_bundles.items[idx] = b;
                    break;
                }
                cur = ext_map.get(cur) orelse break;
            }
        }
        // Weight / MeltTimePerUnit inherit through Extends (unit_lead → unit_iron).
        for (stock_names.items, 0..) |n, idx| {
            var cur = n;
            var hops: usize = 0;
            while (hops < max_hops) : (hops += 1) {
                if (own_weight_map.get(cur)) |w| {
                    stock_weights.items[idx] = w;
                    break;
                }
                cur = ext_map.get(cur) orelse break;
            }
        }
        for (stock_names.items, 0..) |n, idx| {
            var cur = n;
            var hops: usize = 0;
            while (hops < max_hops) : (hops += 1) {
                if (own_melt_map.get(cur)) |m| {
                    stock_melt_times.items[idx] = m;
                    break;
                }
                cur = ext_map.get(cur) orelse break;
            }
        }
        // Hand-item Range / DamageBlock (Action0 props) inherit through the
        // chain: only 44 items declare Range, 24 DamageBlock.
        for (stock_names.items, 0..) |n, idx| {
            var cur = n;
            var hops: usize = 0;
            while (hops < max_hops) : (hops += 1) {
                if (own_range_map.get(cur)) |r| {
                    stock_melee_ranges.items[idx] = r;
                    break;
                }
                cur = ext_map.get(cur) orelse break;
            }
        }
        for (stock_names.items, 0..) |n, idx| {
            var cur = n;
            var hops: usize = 0;
            while (hops < max_hops) : (hops += 1) {
                if (own_dmgblock_map.get(cur)) |d| {
                    stock_dmg_blocks.items[idx] = d;
                    break;
                }
                cur = ext_map.get(cur) orelse break;
            }
        }
        // Tags inherit (286 live items declare none of their own: the
        // schematic masters, melee hands, food masters).
        for (stock_names.items, 0..) |n, idx| {
            if (stock_tags.items[idx].len > 0) continue;
            var cur = n;
            var hops: usize = 0;
            while (hops < max_hops) : (hops += 1) {
                if (own_tags_map.get(cur)) |t| {
                    stock_tags.items[idx] = t;
                    break;
                }
                cur = ext_map.get(cur) orelse break;
            }
        }
        // Material (MadeOfMaterial) inherits through Extends like Weight.
        for (stock_names.items, 0..) |n, idx| {
            var cur = n;
            var hops: usize = 0;
            while (hops < max_hops) : (hops += 1) {
                if (own_material_map.get(cur)) |m| {
                    stock_materials.items[idx] = m;
                    break;
                }
                cur = ext_map.get(cur) orelse break;
            }
        }
        // HasQuality inherits through Extends: Effects is a property like any
        // other, so a child declaring no effect_group of its own answers from
        // the first ancestor that declares one (gunHandgunT1Pistol ->
        // gunHandgunMaster).
        {
            var own_quality_map: std.StringHashMapUnmanaged(bool) = .{};
            defer own_quality_map.deinit(allocator);
            for (stock_names.items, 0..) |n, idx| {
                if (stock_effect_group_declared.items[idx])
                    try own_quality_map.put(allocator, n, stock_has_quality.items[idx]);
            }
            for (stock_names.items, 0..) |n, idx| {
                var cur = n;
                var hops: usize = 0;
                while (hops < max_hops) : (hops += 1) {
                    if (own_quality_map.get(cur)) |q| {
                        stock_has_quality.items[idx] = q;
                        break;
                    }
                    cur = ext_map.get(cur) orelse break;
                }
            }
        }
        // Armor resist curves inherit through the Extends chain like any
        // property (armorPrimitiveHelmet -> armorPrimitiveMaster carries the
        // PDR rows): the first ancestor with a row wins (stock property
        // inheritance; RE items.md Extends).
        {
            var own_pdr_map: std.StringHashMapUnmanaged([buffs.max_curve_len]f32) = .{};
            defer own_pdr_map.deinit(allocator);
            var own_pdrn_map: std.StringHashMapUnmanaged(u8) = .{};
            defer own_pdrn_map.deinit(allocator);
            var own_edr_map: std.StringHashMapUnmanaged([buffs.max_curve_len]f32) = .{};
            defer own_edr_map.deinit(allocator);
            var own_edrn_map: std.StringHashMapUnmanaged(u8) = .{};
            defer own_edrn_map.deinit(allocator);
            for (stock_names.items, 0..) |n, idx| {
                if (stock_pdr_n.items[idx] > 0) {
                    try own_pdr_map.put(allocator, n, stock_pdr_curves.items[idx]);
                    try own_pdrn_map.put(allocator, n, stock_pdr_n.items[idx]);
                }
                if (stock_edr_n.items[idx] > 0) {
                    try own_edr_map.put(allocator, n, stock_edr_curves.items[idx]);
                    try own_edrn_map.put(allocator, n, stock_edr_n.items[idx]);
                }
            }
            for (stock_names.items, 0..) |n, idx| {
                var cur = n;
                var hops: usize = 0;
                while (hops < max_hops) : (hops += 1) {
                    if (own_pdrn_map.get(cur)) |cn| {
                        stock_pdr_n.items[idx] = cn;
                        stock_pdr_curves.items[idx] = own_pdr_map.get(cur).?;
                        break;
                    }
                    cur = ext_map.get(cur) orelse break;
                }
                cur = n;
                hops = 0;
                while (hops < max_hops) : (hops += 1) {
                    if (own_edrn_map.get(cur)) |cn| {
                        stock_edr_n.items[idx] = cn;
                        stock_edr_curves.items[idx] = own_edr_map.get(cur).?;
                        break;
                    }
                    cur = ext_map.get(cur) orelse break;
                }
            }
            // ModSlots inherits through Extends like the resist curves: an
            // item that only overrides damage keeps its base's mod budget.
            {
                var own_mslots_map: std.StringHashMapUnmanaged([buffs.max_curve_len]f32) = .{};
                defer own_mslots_map.deinit(allocator);
                var own_mslotsn_map: std.StringHashMapUnmanaged(u8) = .{};
                defer own_mslotsn_map.deinit(allocator);
                for (stock_names.items, 0..) |n, idx| {
                    if (stock_mslots_n.items[idx] > 0) {
                        try own_mslots_map.put(allocator, n, stock_mslots_curves.items[idx]);
                        try own_mslotsn_map.put(allocator, n, stock_mslots_n.items[idx]);
                    }
                }
                for (stock_names.items, 0..) |n, idx| {
                    var cur = n;
                    var hops: usize = 0;
                    while (hops < max_hops) : (hops += 1) {
                        if (own_mslotsn_map.get(cur)) |cn| {
                            stock_mslots_n.items[idx] = cn;
                            stock_mslots_curves.items[idx] = own_mslots_map.get(cur).?;
                            break;
                        }
                        cur = ext_map.get(cur) orelse break;
                    }
                }
            }
            // CraftingSmeltTime inherits through Extends (same as ModSlots).
            {
                var own_smelt_map: std.StringHashMapUnmanaged([buffs.max_curve_len]f32) = .{};
                defer own_smelt_map.deinit(allocator);
                var own_smeltn_map: std.StringHashMapUnmanaged(u8) = .{};
                defer own_smeltn_map.deinit(allocator);
                for (stock_names.items, 0..) |n, idx| {
                    if (stock_smelt_n.items[idx] > 0) {
                        try own_smelt_map.put(allocator, n, stock_smelt_curves.items[idx]);
                        try own_smeltn_map.put(allocator, n, stock_smelt_n.items[idx]);
                    }
                }
                for (stock_names.items, 0..) |n, idx| {
                    var cur = n;
                    var hops: usize = 0;
                    while (hops < max_hops) : (hops += 1) {
                        if (own_smeltn_map.get(cur)) |cn| {
                            stock_smelt_n.items[idx] = cn;
                            stock_smelt_curves.items[idx] = own_smelt_map.get(cur).?;
                            break;
                        }
                        cur = ext_map.get(cur) orelse break;
                    }
                }
            }
        }
    }

    // Materialize the item passive pool into the arena and resolve the ranges
    // through `Extends` first: a child that declares no row inherits its
    // parent's list (stock property inheritance, same rule the resist curves
    // above follow). The pool order never changes, so the recorded ranges stay
    // valid against the arena copy.
    var item_passives: []const buffs.Passive = &.{};
    {
        var ext_map: std.StringHashMapUnmanaged([]const u8) = .{};
        defer ext_map.deinit(allocator);
        for (stock_names.items, 0..) |n, idx| {
            if (ext_names.items[idx].len > 0) try ext_map.put(allocator, n, ext_names.items[idx]);
        }
        var own_passive_map: std.StringHashMapUnmanaged(struct { usize, usize }) = .{};
        defer own_passive_map.deinit(allocator);
        for (stock_names.items, 0..) |n, idx| {
            if (stock_passive_ranges.items[idx][1] > 0)
                try own_passive_map.put(allocator, n, stock_passive_ranges.items[idx]);
        }
        for (stock_names.items, 0..) |n, idx| {
            if (stock_passive_ranges.items[idx][1] > 0) continue;
            var cur = n;
            var hops: usize = 0;
            while (hops < 24) : (hops += 1) {
                if (own_passive_map.get(cur)) |rg| {
                    stock_passive_ranges.items[idx] = rg;
                    break;
                }
                cur = ext_map.get(cur) orelse break;
            }
        }
        const pool = try arena.alloc(buffs.Passive, passives_pool.items.len);
        @memcpy(pool, passives_pool.items);
        // One gate range per passive row; a mismatch means the scan and the
        // append drifted apart (the same invariant buffs.zig checks).
        if (passive_req_ranges.items.len != pool.len) return error.MalformedItems;
        const req_pool = try arena.alloc(requirements.Requirement, passive_reqs_pool.items.len);
        @memcpy(req_pool, passive_reqs_pool.items);
        for (pool, passive_req_ranges.items) |*p, rg| {
            p.reqs = req_pool[rg[0] .. rg[0] + rg[1]];
        }
        item_passives = pool;
    }

    // Builtin defs: fill stock_type + stack/econ/dmg from items.xml via stock alias.
    var list: std.ArrayList(ItemDef) = .empty;
    defer list.deinit(allocator);
    for (builtin_defs) |d| {
        var def = d;
        def.name = try arena.dupe(u8, d.name);
        if (builtinStockName(d.id)) |sn| {
            for (stock_names.items, 0..) |n, idx| {
                if (!std.mem.eql(u8, n, sn)) continue;
                def.stock_type = stock_types.items[idx];
                def.stack = stock_stacks.items[idx];
                def.econ = stock_econs.items[idx];
                def.econ_bundle_size = stock_bundles.items[idx];
                def.econ_sell_scale = stock_econ_scales.items[idx];
                def.trader_quality_min_mod = stock_tq_min.items[idx];
                def.trader_quality_max_mod = stock_tq_max.items[idx];
                def.degradation_min = stock_degrad_min.items[idx];
                def.degradation_max = stock_degrad_max.items[idx];
                def.has_quality = stock_has_quality.items[idx];
                def.entity_damage = stock_edmgs.items[idx];
                def.place_block_name = stock_place_names.items[idx];
                def.damage_block = stock_dmg_blocks.items[idx];
                def.light_value = stock_light_values.items[idx];
                def.melee_range = stock_melee_ranges.items[idx];
                def.phys_resist_curve = stock_pdr_curves.items[idx];
                def.phys_resist_n = stock_pdr_n.items[idx];
                def.elem_resist_curve = stock_edr_curves.items[idx];
                def.elem_resist_n = stock_edr_n.items[idx];
                const prg0 = stock_passive_ranges.items[idx];
                def.passives = item_passives[prg0[0] .. prg0[0] + prg0[1]];
                def.tags = try arena.dupe(u8, stock_tags.items[idx]);
                def.armor_group = try arena.dupe(u8, stock_armor_group.items[idx]);
                def.mod_slots_curve = stock_mslots_curves.items[idx];
                def.mod_slots_n = stock_mslots_n.items[idx];
                def.crafting_smelt_time_curve = stock_smelt_curves.items[idx];
                def.crafting_smelt_time_n = stock_smelt_n.items[idx];
                def.degradation_per_use = stock_degrad_per_use.items[idx];
                def.stamina_loss = stock_stamina_loss.items[idx];
                def.dismember_chance = stock_dismember_chance.items[idx];
                def.target_armor = stock_target_armor.items[idx];
                def.target_armor_tagged = stock_target_armor_tagged.items[idx];
                def.target_armor_tag = stock_target_armor_tag.items[idx];
                def.harvest_rows = stock_harvest_rows.items[idx];
                def.stats = stock_gs_stats.items[idx];
                def.fuel_value = stock_fuels.items[idx];
                def.craft_component_time = stock_craft_times.items[idx];
                def.weight = stock_weights.items[idx];
                def.melt_time_per_unit = stock_melt_times.items[idx];
                def.material = stock_materials.items[idx];
                def.no_scrapping = stock_no_scrapping.items[idx];
                def.sellable_to_trader = stock_sellable.items[idx];
                def.is_eat = stock_is_eat.items[idx];
                def.food_amount = stock_food_amt.items[idx];
                def.food_health = stock_food_hp.items[idx];
                def.water_amount = stock_water_amt.items[idx];
                def.progression_name = stock_prog_name.items[idx];
                def.progression_add = stock_prog_add.items[idx];
                def.progression_set_max = stock_prog_set_max.items[idx];
                def.eat_exp = stock_eat_exp.items[idx];
                // Prefer stock name so byName("casinoCoin") works without alias walk.
                def.name = n;
                break;
            }
        }
        try list.append(allocator, def);
    }

    // Also register XML items as high sim ids (100+) for admin/give by stock name later.
    var next_sim: u16 = 100;
    for (stock_names.items, 0..) |n, idx| {
        var is_builtin = false;
        for (list.items) |d| {
            if (std.mem.eql(u8, d.name, n)) {
                is_builtin = true;
                break;
            }
        }
        if (is_builtin) continue;
        try list.append(allocator, .{
            .id = next_sim,
            .name = n,
            .stack = stock_stacks.items[idx],
            .stock_type = stock_types.items[idx],
            .econ = stock_econs.items[idx],
            .econ_bundle_size = stock_bundles.items[idx],
            .econ_sell_scale = stock_econ_scales.items[idx],
            .trader_quality_min_mod = stock_tq_min.items[idx],
            .trader_quality_max_mod = stock_tq_max.items[idx],
            .degradation_min = stock_degrad_min.items[idx],
            .degradation_max = stock_degrad_max.items[idx],
            .has_quality = stock_has_quality.items[idx],
            .entity_damage = stock_edmgs.items[idx],
            .place_block_name = stock_place_names.items[idx],
            .damage_block = stock_dmg_blocks.items[idx],
            .light_value = stock_light_values.items[idx],
            .melee_range = stock_melee_ranges.items[idx],
            .fuel_value = stock_fuels.items[idx],
            .craft_component_time = stock_craft_times.items[idx],
            .weight = stock_weights.items[idx],
            .melt_time_per_unit = stock_melt_times.items[idx],
            .material = stock_materials.items[idx],
            .no_scrapping = stock_no_scrapping.items[idx],
            .sellable_to_trader = stock_sellable.items[idx],
            // ItemActionEat props (was missing; stack-loss isEat relied on name heuristic only).
            .is_eat = stock_is_eat.items[idx],
            .food_amount = stock_food_amt.items[idx],
            .food_health = stock_food_hp.items[idx],
            .water_amount = stock_water_amt.items[idx],
            .progression_name = stock_prog_name.items[idx],
            .progression_add = stock_prog_add.items[idx],
            .progression_set_max = stock_prog_set_max.items[idx],
            .eat_exp = stock_eat_exp.items[idx],
            .distraction_tags = stock_dtags.items[idx],
            .distraction_radius = stock_dradius.items[idx],
            .phys_resist_curve = stock_pdr_curves.items[idx],
            .phys_resist_n = stock_pdr_n.items[idx],
            .elem_resist_curve = stock_edr_curves.items[idx],
            .elem_resist_n = stock_edr_n.items[idx],
            .passives = item_passives[stock_passive_ranges.items[idx][0] .. stock_passive_ranges.items[idx][0] + stock_passive_ranges.items[idx][1]],
            .tags = try arena.dupe(u8, stock_tags.items[idx]),
            .armor_group = try arena.dupe(u8, stock_armor_group.items[idx]),
            .mod_slots_curve = stock_mslots_curves.items[idx],
            .mod_slots_n = stock_mslots_n.items[idx],
            .crafting_smelt_time_curve = stock_smelt_curves.items[idx],
            .crafting_smelt_time_n = stock_smelt_n.items[idx],
            .degradation_per_use = stock_degrad_per_use.items[idx],
            .stamina_loss = stock_stamina_loss.items[idx],
            .dismember_chance = stock_dismember_chance.items[idx],
            .target_armor = stock_target_armor.items[idx],
            .target_armor_tagged = stock_target_armor_tagged.items[idx],
            .target_armor_tag = stock_target_armor_tag.items[idx],
            .harvest_rows = stock_harvest_rows.items[idx],
            .stats = stock_gs_stats.items[idx],
            .distraction_lifetime = stock_dlifetime.items[idx],
            .distraction_strength = stock_dstrength.items[idx],
            .distraction_eat_ticks = stock_deat.items[idx],
        });
        next_sim +%= 1;
        if (list.items.len >= max_items) break;
    }

    const defs = try arena.alloc(ItemDef, list.items.len);
    @memcpy(defs, list.items);
    const sn = try arena.alloc([]const u8, stock_names.items.len);
    @memcpy(sn, stock_names.items);
    const st = try arena.alloc(i32, stock_types.items.len);
    @memcpy(st, stock_types.items);
    const ss = try arena.alloc(u16, stock_stacks.items.len);
    @memcpy(ss, stock_stacks.items);
    const ssc = try arena.alloc(f32, stock_econ_scales.items.len);
    @memcpy(ssc, stock_econ_scales.items);

    return .{
        .defs = defs,
        .arena_ptr = arena_holder,
        .source = .xml,
        .stock_names = sn,
        .stock_types = st,
        .stock_stacks = ss,
        .stock_econ_scales = ssc,
        .max_quality_tier = rootMaxQualityTier(clean),
    };
}

/// `<items max_quality_tier="N">`: stock parses it into the static and falls
/// back to 6 when absent or unparsable. A value outside 1..255 keeps the
/// default rather than producing a degenerate quality axis.
fn rootMaxQualityTier(src: []const u8) u8 {
    const ri = std.mem.findPos(u8, src, 0, "<items") orelse return components.max_quality_tiers;
    const v = xml.attr(src, ri, "max_quality_tier") orelse return components.max_quality_tiers;
    const n = xml.parseU8(v) orelse return components.max_quality_tiers;
    // 0 would collapse every quality axis (stock assigns the parsed value
    // unchecked and divides by it); fail closed on the default instead.
    if (n == 0) return components.max_quality_tiers;
    return n;
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?ItemTable {
    const paths = @import("paths.zig");
    return paths.tryLoadConfig("items.xml", ItemTable, loadFromPath, allocator, game_dir, config_dir);
}

test "items inherit Action0 damage and Tags through Extends" {
    // Range / DamageBlock / Tags used to read the own body only: 1449 items
    // inherit MaxDamage-style props through Extends and 286 declare no Tags of
    // their own (schematicNoQualityMaster children), which made the loot mod
    // roll and the attachment scrub fail closed on them.
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/items.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    // meleeHandZombieFeral extends meleeHandZombie01 (Range 1.6).
    const feral = t.byName("meleeHandZombieFeral").?;
    const plain = t.byName("meleeHandZombie01").?;
    try std.testing.expect(plain.melee_range > 0);
    try std.testing.expectApproxEqAbs(plain.melee_range, feral.melee_range, 1e-4);
    // A schematic master child inherits the master's Tags.
    const schematic = t.byName("ammoArrowStoneSchematic");
    if (schematic) |d| try std.testing.expect(d.tags.len > 0);
    try std.testing.expect(t.byName("schematicNoQualityMaster").?.tags.len > 0);
}

test "builtin items" {
    const t = ItemTable.builtin();
    try std.testing.expectEqualStrings("dukeCoin", t.byId(6).?.name);
    try std.testing.expectEqualStrings("meleeToolRepairT0StoneAxe", builtinStockName(8).?);
}

// ecs/inventory keeps a leaf offline mirror (no assets import). Drift here breaks
// fixture place/stack/armor when stack_fn/place_fn are unset.
test "ecs offline inventory catalog mirrors builtins" {
    const inv = @import("../ecs/inventory.zig");
    for (builtin_defs) |d| {
        const want_stack: u16 = if (d.stack == 0) 1 else d.stack;
        try std.testing.expectEqual(want_stack, inv.maxStackBuiltin(d.id));
    }
    var id: u16 = 1;
    while (id <= 12) : (id += 1) {
        const a = builtinStockName(id);
        const b = inv.builtinStockNameFallback(id);
        if (a == null and b == null) continue;
        try std.testing.expect(a != null and b != null);
        try std.testing.expectEqualStrings(a.?, b.?);
    }
    try std.testing.expect(inv.isArmorOffline(11));
    try std.testing.expect(!inv.isArmorOffline(7));
}

test "sandbox MaxStackSize scales stackable items but never quality ones" {
    // Stock ItemClass.get_MaxCount (IL=10): with MaxStackSizeModifier != 1 the
    // Stacknumber is scaled and clamped at 30000, but only for items that
    // stack and carry no quality (a weapon's stack of 1 must not follow the
    // option). The option is 163 StackSizeMultiplier, set from the decoded
    // server code.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/items.xml", .{dir});
    try io_fs.writeFile(path,
        \\<items>
        \\  <item name="resourceWood">
        \\    <property name="Stacknumber" value="5" />
        \\  </item>
        \\  <item name="resourceScrapIron">
        \\    <property name="Stacknumber" value="1000" />
        \\  </item>
        \\  <item name="gunHandgunT1Pistol">
        \\    <property name="Stacknumber" value="1" />
        \\    <effect_group tiered="true" name="quality">
        \\      <passive_effect name="DamageModifier" operation="perc_add" value=".1" tier="1,6" />
        \\    </effect_group>
        \\  </item>
        \\  <item name="thrownRock">
        \\    <property name="Stacknumber" value="1" />
        \\  </item>
        \\</items>
    );
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const wood = t.byName("resourceWood").?.id;
    const iron = t.byName("resourceScrapIron").?.id;
    const pistol = t.byName("gunHandgunT1Pistol").?.id;
    const rock = t.byName("thrownRock").?.id;
    try std.testing.expect(t.byName("gunHandgunT1Pistol").?.has_quality);
    try std.testing.expect(!t.byName("resourceWood").?.has_quality);

    // Default: every raw Stacknumber stands.
    try std.testing.expectEqual(@as(u16, 5), t.stackFor(wood));
    try std.testing.expectEqual(@as(u16, 1000), t.stackFor(iron));

    // x2: stackables double, quality and non-stacking items are untouched.
    t.setStackSizeModifier(2.0);
    try std.testing.expectEqual(@as(u16, 10), t.stackFor(wood));
    try std.testing.expectEqual(@as(u16, 2000), t.stackFor(iron));
    try std.testing.expectEqual(@as(u16, 1), t.stackFor(pistol));
    try std.testing.expectEqual(@as(u16, 1), t.stackFor(rock));

    // x1.5 on a 5-count stack is a .NET midpoint: Math.Round(7.5) = 8.
    t.setStackSizeModifier(1.5);
    try std.testing.expectEqual(@as(u16, 8), t.stackFor(wood));
    // The clamp is stock's 30000, applied only on the scaled path.
    t.setStackSizeModifier(100.0);
    try std.testing.expectEqual(@as(u16, 30000), t.stackFor(iron));
    // A modifier the decoded code does not carry is not one: 0 falls back to 1.
    t.setStackSizeModifier(0);
    try std.testing.expectEqual(@as(u16, 1000), t.stackFor(iron));
}

test "stock type first item is ItemsStartHere+1" {
    try std.testing.expectEqual(@as(i32, 65537), stock_first_item_type);
}

test "XML item table fails closed instead of using builtin balance or ids" {
    const defs = [_]ItemDef{
        .{ .id = 100, .name = "foodUnspecified", .is_eat = true },
        .{ .id = 101, .name = "drinkUnspecified", .is_eat = true },
    };
    const t: ItemTable = .{ .defs = &defs, .source = .xml };

    try std.testing.expectEqual(@as(f32, 0), t.foodAmountFor(100));
    try std.testing.expectEqual(@as(f32, 0), t.foodHealthFor(100));
    try std.testing.expectEqual(@as(f32, 0), t.waterAmountFor(101));
    try std.testing.expectEqual(@as(i32, 0), t.stockTypeFor(99));
    try std.testing.expectEqual(@as(u16, 0), t.ecsIdFromStockType(items_start_here + 99));
    try std.testing.expect(t.byName("casinoCoin") == null);
    try std.testing.expectEqual(@as(u16, 0), t.ecsIdByName("resourceWood"));
    try std.testing.expect(!t.isEat(2));
    try std.testing.expect(!t.isEat(4));
    try std.testing.expectEqual(@as(i32, 0), t.stockTypeFor(6));

    const unparsed = [_]ItemDef{
        .{ .id = 102, .name = "foodUnparsed" },
        .{ .id = 103, .name = "drinkUnparsed" },
    };
    const xml_names: ItemTable = .{ .defs = &unparsed, .source = .xml };
    try std.testing.expect(!xml_names.isEat(102));
    try std.testing.expect(!xml_names.isEat(103));
    try std.testing.expectEqual(@as(f32, 0), xml_names.foodAmountFor(102));
    try std.testing.expectEqual(@as(f32, 0), xml_names.waterAmountFor(103));

    const builtin = ItemTable.builtin();
    try std.testing.expectEqual(@as(i32, items_start_here + 7), builtin.stockTypeFor(7));
    try std.testing.expectEqual(@as(f32, 15), builtin.foodAmountFor(2));
    try std.testing.expectEqual(@as(u16, 6), builtin.ecsIdByName("casinoCoin"));
    try std.testing.expect(builtin.isEat(2));
}

test "magazine AddProgressionLevel parses onto the eat item" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/items.xml", .{dir});
    try io_fs.writeFile(path,
        \\<items>
        \\  <item name="harvestingToolsSkillMagazine">
        \\    <property class="Action0">
        \\      <property name="Class" value="Eat"/>
        \\    </property>
        \\    <effect_group tiered="false">
        \\      <triggered_effect trigger="onSelfPrimaryActionEnd" action="AddProgressionLevel" progression_name="craftingHarvestingTools" level="1"/>
        \\      <triggered_effect trigger="onSelfPrimaryActionEnd" action="GiveExp" exp="50"/>
        \\    </effect_group>
        \\  </item>
        \\  <item name="foodCanBeef">
        \\    <property class="Action0">
        \\      <property name="Class" value="Eat"/>
        \\    </property>
        \\    <effect_group>
        \\      <triggered_effect trigger="onSelfPrimaryActionEnd" action="ModifyCVar" cvar="$foodAmountAdd" operation="add" value="15"/>
        \\    </effect_group>
        \\  </item>
        \\</items>
    );
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const mag = t.byName("harvestingToolsSkillMagazine").?;
    try std.testing.expect(mag.is_eat);
    try std.testing.expect(t.isEat(mag.id));
    try std.testing.expectEqualStrings("craftingHarvestingTools", mag.progression_name);
    try std.testing.expectEqual(@as(u8, 1), mag.progression_add);
    try std.testing.expectEqual(@as(u16, 50), mag.eat_exp);
    const food = t.byName("foodCanBeef").?;
    try std.testing.expectEqual(@as(u8, 0), food.progression_add);
    try std.testing.expectEqualStrings("", food.progression_name);
    try std.testing.expectEqual(@as(u16, 0), food.eat_exp);
    try std.testing.expectEqual(@as(usize, 0), food.progression_set_max.len);
}

test "almanac SetProgressionLevel level=-1 parses as set-to-max" {
    // RE minevents.md IL=104: level=-1 sets ProgressionClass.MaxLevel.
    // Stock ships only -1 (426 rows); non -1 is omitted.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/items.xml", .{dir});
    try io_fs.writeFile(path,
        \\<items>
        \\  <item name="bookFiremansAlmanacHeat">
        \\    <property class="Action0">
        \\      <property name="Class" value="Eat"/>
        \\    </property>
        \\    <effect_group tiered="false">
        \\      <triggered_effect trigger="onSelfPrimaryActionEnd" action="SetProgressionLevel" progression_name="perkFiremansAlmanacHeat" level="-1"/>
        \\      <triggered_effect trigger="onSelfPrimaryActionEnd" action="SetProgressionLevel" progression_name="perkFiremansAlmanacComplete" level="-1"/>
        \\      <triggered_effect trigger="onSelfPrimaryActionEnd" action="SetProgressionLevel" progression_name="perkIgnoredAbsolute" level="3"/>
        \\      <triggered_effect trigger="onSelfPrimaryActionEnd" action="GiveExp" exp="50"/>
        \\    </effect_group>
        \\  </item>
        \\</items>
    );
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const book = t.byName("bookFiremansAlmanacHeat").?;
    try std.testing.expect(book.is_eat);
    try std.testing.expect(t.isEat(book.id));
    try std.testing.expectEqual(@as(u8, 0), book.progression_add);
    try std.testing.expectEqualStrings("", book.progression_name);
    try std.testing.expectEqual(@as(usize, 2), book.progression_set_max.len);
    try std.testing.expectEqualStrings("perkFiremansAlmanacHeat", book.progression_set_max[0]);
    try std.testing.expectEqualStrings("perkFiremansAlmanacComplete", book.progression_set_max[1]);
    try std.testing.expectEqual(@as(u16, 50), book.eat_exp);
}

test "Tags + ModSlots parse and modSlotsFor gates the mod budget" {
    // RE items.md: the item's Tags surface (mod-attachment gates) + the
    // ModSlots quality curve (CalcModSlotCount IL=29 = GetValue(ModSlots,
    // item, Quality-1)); an item without ModSlots allows no mods (fail
    // closed in the attachment scrub).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/items.xml", .{dir});
    try io_fs.writeFile(path, "<items>\n" ++
        "  <item name=\"testGun\">\n" ++
        "    <property name=\"Tags\" value=\"T0,weapon,gun,barrelAttachments\"/>\n" ++
        "    <effect_group name=\"testGun\">\n" ++
        "      <passive_effect name=\"ModSlots\" operation=\"base_set\" value=\"1,1,1,2,2,3\" tier=\"1,2,3,4,5,6\"/>\n" ++
        "    </effect_group>\n" ++
        "  </item>\n" ++
        "  <item name=\"resourceWood\">\n" ++
        "    <property name=\"Stacknumber\" value=\"100\"/>\n" ++
        "  </item>\n" ++
        "</items>\n");
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const gun = t.byName("testGun") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("T0,weapon,gun,barrelAttachments", gun.tags);
    try std.testing.expectEqual(@as(u8, 6), gun.mod_slots_n);
    // Quality 1..3 → budget 1; quality 4..5 → 2; quality 6 → 3 (stock tier
    // curve). Quality 0 (unset) treats as tier 1.
    try std.testing.expectEqual(@as(u8, 1), t.modSlotsFor(gun.id, 1));
    try std.testing.expectEqual(@as(u8, 2), t.modSlotsFor(gun.id, 4));
    try std.testing.expectEqual(@as(u8, 3), t.modSlotsFor(gun.id, 6));
    try std.testing.expectEqual(@as(u8, 1), t.modSlotsFor(gun.id, 0));
    const wood = t.byName("resourceWood") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u8, 0), t.modSlotsFor(wood.id, 3)); // no ModSlots → 0
    try std.testing.expectEqual(@as(u8, 0), t.modSlotsFor(9999, 3)); // unknown item → 0
}

test "DistractionTags + Distraction* effects parse (stock decoy shape)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/items.xml", .{dir});
    try io_fs.writeFile(path, "<items>\n" ++
        "  <item name=\"resourceRockDecoy\">\n" ++
        "    <property name=\"ThrowableDecoy\" value=\"true\"/>\n" ++
        "    <property name=\"DistractionTags\" value=\"zombie,requires_contact\"/>\n" ++
        "    <effect_group name=\"decoy\" tiered=\"false\">\n" ++
        "      <passive_effect name=\"DistractionRadius\" operation=\"base_set\" value=\"25\"/>\n" ++
        "      <passive_effect name=\"DistractionLifetime\" operation=\"base_set\" value=\"1\"/>\n" ++
        "      <passive_effect name=\"DistractionStrength\" operation=\"base_set\" value=\"100\"/>\n" ++
        "    </effect_group>\n" ++
        "  </item>\n" ++
        "  <item name=\"foodBait\">\n" ++
        "    <property name=\"DistractionTags\" value=\"zombie,eat\"/>\n" ++
        "    <effect_group name=\"decoy\">\n" ++
        "      <passive_effect name=\"DistractionRadius\" operation=\"base_set\" value=\"10\"/>\n" ++
        "      <passive_effect name=\"DistractionLifetime\" operation=\"base_set\" value=\"5\"/>\n" ++
        "      <passive_effect name=\"DistractionStrength\" operation=\"base_set\" value=\"50\"/>\n" ++
        "      <passive_effect name=\"DistractionEatTicks\" operation=\"base_set\" value=\"12\"/>\n" ++
        "    </effect_group>\n" ++
        "  </item>\n" ++
        "  <item name=\"resourceWood\">\n" ++
        "    <property name=\"Stacknumber\" value=\"100\"/>\n" ++
        "  </item>\n" ++
        "</items>\n");
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const decoy = t.byName("resourceRockDecoy").?;
    const d = t.distractionFor(decoy.id).?;
    try std.testing.expectEqual(@as(u8, 2 | 4), d.tags); // requires_contact + zombie
    try std.testing.expectEqual(@as(f32, 25), d.radius);
    try std.testing.expectEqual(@as(i32, 1), d.lifetime);
    try std.testing.expectEqual(@as(f32, 100), d.strength);
    try std.testing.expectEqual(@as(i32, 0), d.eat_ticks); // decoy is not eaten
    // Eat distraction parses the DistractionEatTicks passive effect.
    const bait = t.byName("foodBait").?;
    const b = t.distractionFor(bait.id).?;
    try std.testing.expectEqual(@as(u8, 1 | 4), b.tags);
    try std.testing.expectEqual(@as(f32, 10), b.radius);
    try std.testing.expectEqual(@as(i32, 12), b.eat_ticks);
    // Plain items are not distractions.
    const wood = t.byName("resourceWood").?;
    try std.testing.expect(t.distractionFor(wood.id) == null);
}

test "HarvestCount held-tool rows parse and fold over base 1" {
    // RE GameUtils.HarvestOnAttack IL=623: count = trunc(rolled *
    // GetValue(141, tool, 1, holder, null, dropTag)). Ops: base_add ->
    // base+value, base_set -> base=value, perc_add -> base*(1+value);
    // a curve evaluates at the tool quality. Tag-gated by the drop row.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/items.xml", .{dir});
    try io_fs.writeFile(path,
        \\<items>
        \\  <item name="meleeToolPickT3Auger">
        \\    <effect_group name="Auger">
        \\      <passive_effect name="HarvestCount" operation="perc_add" value=".2"/>
        \\    </effect_group>
        \\  </item>
        \\  <item name="meleeWpnClubT0WoodenClub">
        \\    <effect_group name="Club">
        \\      <passive_effect name="HarvestCount" operation="base_add" value="-.75" tags="allHarvest"/>
        \\      <passive_effect name="HarvestCount" operation="base_add" value="-.75" tags="allToolsHarvest"/>
        \\      <passive_effect name="HarvestCount" operation="base_add" value="-.75" tags="oreWoodHarvest"/>
        \\    </effect_group>
        \\  </item>
        \\  <item name="meleeToolAxeT2SteelAxe">
        \\    <effect_group name="Axe">
        \\      <passive_effect name="HarvestCount" operation="base_set" value=".7" tags="butcherHarvest"/>
        \\    </effect_group>
        \\  </item>
        \\  <item name="armorMinerHelmet">
        \\    <effect_group name="Helmet">
        \\      <passive_effect name="HarvestCount" operation="perc_add" value=".05,.1,.15,.20,.25,.30" tier="1,2,3,4,5,6" tags="oreWoodHarvest"/>
        \\    </effect_group>
        \\  </item>
        \\</items>
    );
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();

    // Untagged perc_add applies to every drop: 1 + .2 = 1.2.
    const auger = t.byName("meleeToolPickT3Auger").?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.2), t.harvestMultiplier(auger.id, 1, "oreWoodHarvest"), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.2), t.harvestMultiplier(auger.id, 1, ""), 1e-4);
    // Club: base_add -.75 over base 1 -> 0.25 for a matching tag; no match
    // (butcherHarvest) -> 1.0 (no row applies).
    const club = t.byName("meleeWpnClubT0WoodenClub").?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), t.harvestMultiplier(club.id, 1, "oreWoodHarvest"), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), t.harvestMultiplier(club.id, 1, "allHarvest,lumberjackHarvest"), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), t.harvestMultiplier(club.id, 1, "butcherHarvest"), 1e-4);
    // Axe: base_set .7 replaces the base for butcherHarvest only.
    const axe = t.byName("meleeToolAxeT2SteelAxe").?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), t.harvestMultiplier(axe.id, 1, "butcherHarvest"), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), t.harvestMultiplier(axe.id, 1, "oreWoodHarvest"), 1e-4);
    // Curve: quality 3 -> 1 + .15 = 1.15 (piecewise at quality 1..6).
    const helmet = t.byName("armorMinerHelmet").?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.05), t.harvestMultiplier(helmet.id, 1, "oreWoodHarvest"), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.15), t.harvestMultiplier(helmet.id, 3, "oreWoodHarvest"), 1e-4);
    // Unknown item / no rows -> 1.0.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), t.harvestMultiplier(9999, 1, "oreWoodHarvest"), 1e-4);
}

test "load stock items.xml when present" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days To Die/Data/Config/items.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expect(t.stock_names.len > 100);
    try std.testing.expectEqual(@as(i32, 65537), t.byStockName("meleeToolRepairT0StoneAxe").?);
    try std.testing.expectEqual(t.byStockName("meleeToolRepairT0StoneAxe").?, t.stockTypeFor(8));
    try std.testing.expect(t.stockTypeFor(7) > stock_first_item_type); // wood
    // DegradationMax (passive 8): the builtin stone axe quality tier is
    // "250,500" (Q1 -> 250, Q6 -> 500; stock items.xml). Feeds the sell
    // price's PercentUsesLeft term (worn items sell for less).
    if (t.byId(8)) |axe| {
        try std.testing.expectEqual(@as(u32, 250), axe.degradation_min);
        try std.testing.expectEqual(@as(u32, 500), axe.degradation_max);
        // A tool carries owner-tiered effect groups, so the trader roll gives
        // it a quality (ItemClass.HasQuality).
        try std.testing.expect(axe.has_quality);
    }
    // Stackable resources carry no effect_group at all: no quality.
    try std.testing.expect(!t.hasQualityByName("resourceWood"));
    // Non-durable items (no DegradationMax) price full: pul term is 1.
    if (t.byName("resourceWood")) |wood| {
        try std.testing.expectEqual(@as(u32, 0), wood.degradation_max);
    }
    // Stock gas can: FuelValue from items.xml (ammoGasCan).
    if (t.byName("ammoGasCan")) |gas| {
        try std.testing.expect(gas.fuel_value > 0);
        try std.testing.expectEqual(gas.fuel_value, t.fuelValueFor(gas.id));
    }
    // Forge melt inputs: Weight + MeltTimePerUnit from items.xml.
    if (t.byName("unit_iron")) |iron| {
        try std.testing.expectEqual(@as(u16, 1), iron.weight);
        try std.testing.expectApproxEqAbs(@as(f32, 0.25), iron.melt_time_per_unit, 1e-4);
        try std.testing.expectEqual(iron.weight, t.weightFor(iron.id));
        try std.testing.expectApproxEqAbs(iron.melt_time_per_unit, t.meltTimePerUnitFor(iron.id), 1e-4);
    }
    // unit_lead Extends unit_iron: Weight + MeltTimePerUnit inherit.
    if (t.byName("unit_lead")) |lead| {
        try std.testing.expectEqual(@as(u16, 1), lead.weight);
        try std.testing.expectApproxEqAbs(@as(f32, 0.25), lead.melt_time_per_unit, 1e-4);
    }
    if (t.byName("resourceScrapBrass")) |brass| {
        try std.testing.expectEqual(@as(u16, 1), brass.weight);
        try std.testing.expectApproxEqAbs(@as(f32, 0.4), brass.melt_time_per_unit, 1e-4);
    }
    // Action1 PlaceAsBlock Blockname: b14 exactly two items place, and the
    // rest (resourceWood etc.) are not placeable.
    if (t.byName("meleeToolTorch")) |torch| {
        try std.testing.expectEqualStrings("wallTorchLightPlayer", torch.place_block_name);
    }
    if (t.byName("candle")) |cnd| {
        try std.testing.expectEqualStrings("candleWallLightPlayer", cnd.place_block_name);
    }
    if (t.byName("resourceWood")) |wood| {
        try std.testing.expectEqualStrings("", wood.place_block_name);
    }
    // EconomicValue resolves through the Extends chain (286 stock items get
    // their econ from a master) and EconomicBundleSize divides the price.
    if (t.byName("armorAssassinBoots")) |boots| {
        try std.testing.expectEqual(@as(f32, 1000), boots.econ);
    }
    if (t.byName("ammoGasCan")) |gas| {
        try std.testing.expectEqual(@as(u16, 100), gas.econ_bundle_size);
    }
    if (t.byName("resourceWood")) |wood| {
        try std.testing.expectEqual(@as(u16, 50), wood.econ_bundle_size);
    }
    // Held-item lights (Inventory.GetLightLevel IL=76): torches and
    // flashlights carry items.xml LightValue for the stealth selfLight term.
    if (t.byName("meleeToolTorch")) |torch| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.35), torch.light_value, 0.001);
    }
    if (t.byName("meleeToolFlashlight02")) |fl| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.55), fl.light_value, 0.001);
    }
    if (t.byName("gunHandgunT0PipePistol")) |gun| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.45), gun.light_value, 0.001);
    }
    // Melee damage: club/axe declare it as the EntityDamage passive effect
    // (base_set) - property-less items must not resolve to 0.
    if (t.byName("meleeWpnClubT0WoodenClub")) |club| {
        try std.testing.expectEqual(@as(f32, 12), club.entity_damage);
    }
    if (t.byName("meleeToolRepairT0StoneAxe")) |axe| {
        try std.testing.expectEqual(@as(f32, 6), axe.entity_damage);
    }
    // Per-class block chew: DamageBlock property on the zombie hand items.
    if (t.byName("meleeHandZombie01")) |hand| {
        try std.testing.expectEqual(@as(f32, 8), hand.damage_block);
    }
    if (t.byName("meleeHandZombieFeral")) |feral| {
        try std.testing.expectEqual(@as(f32, 24), feral.damage_block);
    }
    // Melee reach: zombie hand Range property 1.6; club falls back to the
    // passive MaxRange 2.4.
    if (t.byName("meleeHandZombie01")) |hand| {
        try std.testing.expectEqual(@as(f32, 1.6), hand.melee_range);
    }
    if (t.byName("meleeWpnClubT0WoodenClub")) |club| {
        try std.testing.expectEqual(@as(f32, 2.4), club.melee_range);
    }
    // Medical heal: bandage heals via the medicalRegHealthAmount cvar.
    if (t.byName("medicalFirstAidBandage")) |band| {
        try std.testing.expect(band.food_health > 0);
    }
    var buf: [512 * 1024]u8 = undefined;
    const map = try t.writeNameIdMapping(&buf);
    try std.testing.expect(map.len > 16);
    try std.testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, map[0..4], .little));
}

test "stock items.xml Stacknumber default and Extends resolution" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/items.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const stackOf = struct {
        fn f(tab: *const ItemTable, name: []const u8) u16 {
            for (tab.stock_names, 0..) |n, i| {
                if (std.mem.eql(u8, n, name)) return tab.stock_stacks[i];
            }
            return 0;
        }
    }.f;
    // Leaf with no Stacknumber and no Extends: ItemClass default 500.
    try std.testing.expectEqual(@as(u16, 500), stackOf(&t, "meleeToolRepairT0StoneAxe"));
    // One Extends hop: ammoArrowExploding -> ammoArrowIron (75).
    try std.testing.expectEqual(@as(u16, 75), stackOf(&t, "ammoArrowExploding"));
    // Two hops: meleeHandZombieFeral -> meleeHandZombie01 -> meleeHandMaster (1).
    try std.testing.expectEqual(@as(u16, 1), stackOf(&t, "meleeHandZombieFeral"));
    // The builtin stone axe (id 8) inherits the resolved stack via its stock alias.
    try std.testing.expectEqual(@as(u16, 500), t.byId(8).?.stack);
    // A39: EconomicSellScale from items.xml (stock ItemClass.EconomicSellScale,
    // IL ctor default 1.0; toolCookingGrill marks down to .5).
    const scaleOf = struct {
        fn f(tab: *const ItemTable, name: []const u8) f32 {
            for (tab.stock_names, 0..) |n, i| {
                if (std.mem.eql(u8, n, name)) return tab.stock_econ_scales[i];
            }
            return 0;
        }
    }.f;
    try std.testing.expectEqual(@as(f32, 1.0), scaleOf(&t, "meleeToolRepairT0StoneAxe"));
    try std.testing.expectEqual(@as(f32, 0.5), scaleOf(&t, "toolCookingGrill"));
    try std.testing.expectEqual(@as(f32, 1.0), t.byId(8).?.econ_sell_scale);
}

test "item passive rows parse with their gates and inherit through Extends" {
    const gd = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
    if (!io_fs.dirExists(gd ++ "/Data/Config")) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, gd ++ "/Data/Config/items.xml");
    defer t.deinit();
    const rowOf = struct {
        fn f(d: ItemDef, name: []const u8) ?buffs.Passive {
            for (d.passives) |p| {
                if (std.mem.eql(u8, p.name, name)) return p;
            }
            return null;
        }
    }.f;
    // armorAthleticOutfit carries HealthMax "2,4,6,8,10,20" (a 6-segment tier
    // curve); the survival VM folds it at the item's quality.
    const outfit = t.byName("armorAthleticOutfit") orelse return error.SkipZigTest;
    const hm = rowOf(outfit, "HealthMax") orelse return error.SkipZigTest;
    try std.testing.expectEqual(@as(u8, 6), hm.curve_len);
    try std.testing.expectApproxEqAbs(@as(f32, 20), hm.curve[5], 0.001);
    // armorRangerBoots inherits StaminaMax from its master class (the same
    // Extends chain the resist curves use).
    const boots = t.byName("armorRangerBoots") orelse return error.SkipZigTest;
    const sm = rowOf(boots, "StaminaMax") orelse return error.SkipZigTest;
    try std.testing.expect(sm.curve_len > 0);
    // armorEnforcerOutfit's flat GeneralDamageResist row (passive 40), the one
    // item row the round-2 damage choke consumes.
    const enforcer = t.byName("armorEnforcerOutfit") orelse return error.SkipZigTest;
    const gdr = rowOf(enforcer, "GeneralDamageResist") orelse return error.SkipZigTest;
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), gdr.value, 0.0001);
    // The admin items gate their rows on IsEquipped (6 stock rows), which the
    // item fold answers with Ctx.item_equipped.
    const shirt = t.byName("toughGuyShirtAdmin") orelse return error.SkipZigTest;
    var gated = false;
    for (shirt.passives) |p| {
        for (p.reqs) |r| {
            if (r.kind == .is_equipped) gated = true;
        }
    }
    try std.testing.expect(gated);
}

test "armor resist curves parse from stock items.xml (PDR quality curves)" {
    const gd = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
    var t = try loadFromPath(std.testing.allocator, gd ++ "/Data/Config/items.xml");
    defer t.deinit();
    // armorPrimitiveHelmet carries PhysicalDamageResist "8,12.3" (Q1..Q6).
    var found: usize = 0;
    for (t.defs) |d| {
        if (std.mem.eql(u8, d.name, "armorPrimitiveHelmet")) {
            try std.testing.expectEqual(@as(u8, 2), d.phys_resist_n);
            try std.testing.expectApproxEqAbs(@as(f32, 8), d.phys_resist_curve[0], 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 12.3), d.phys_resist_curve[1], 0.001);
            try std.testing.expectEqual(@as(u8, 2), d.elem_resist_n);
            found += 1;
        }
        if (d.phys_resist_n > 0) found += 1;
    }
    // Measured against stock V3.2.0 items.xml (2026-09-04): 1413 items, of
    // which 67 carry a PhysicalDamageResist passive; the parse finds 73 rows
    // because a def can hold more than one. The old bound was 50 with a note
    // that max_items might truncate the tail - it cannot: the table runs at
    // 17% of the cap, so nothing is lost and the bound can be tight enough to
    // catch a regression instead of tolerating one.
    try std.testing.expect(found >= 70);
    // DegradationPerUse (base_set) on tools; TargetArmor (perc_add) only on
    // untagged rows (ammo9mmBulletAP, the armor-piercing round).
    var stone_axe = false;
    var ap_ammo = false;
    var javelin = false;
    for (t.defs) |d| {
        if (std.mem.eql(u8, d.name, "meleeToolRepairT0StoneAxe")) {
            try std.testing.expectApproxEqAbs(@as(f32, 1), d.degradation_per_use, 0.001);
            stone_axe = true;
        }
        if (std.mem.eql(u8, d.name, "ammo9mmBulletAP")) {
            try std.testing.expectApproxEqAbs(@as(f32, -0.5), d.target_armor, 0.001);
            ap_ammo = true;
        }
        // perk-tag-gated TargetArmor: the javelin carries `-.3` tagged
        // perkJavelinMaster (applies only when the attacker owns the perk).
        if (std.mem.startsWith(u8, d.name, "meleeWpnSpear") and d.target_armor_tagged != 0) {
            try std.testing.expectEqualStrings("perkJavelinMaster", d.target_armor_tag);
            javelin = true;
        }
    }
    try std.testing.expect(stone_axe);
    try std.testing.expect(ap_ammo);
    try std.testing.expect(javelin);
}

test "StaminaLoss parses as the per-attack cost" {
    const gd = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
    var t = try loadFromPath(std.testing.allocator, gd ++ "/Data/Config/items.xml");
    defer t.deinit();
    var found = false;
    for (t.defs) |d| {
        if (std.mem.eql(u8, d.name, "meleeToolRepairT0StoneAxe")) {
            try std.testing.expectApproxEqAbs(@as(f32, 8), d.stamina_loss, 0.001);
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "HasQuality follows owner-tiered effect groups and inherits through Extends" {
    // ItemClass.HasQuality (IL=9) = Effects != null && IsOwnerTiered(). Effects
    // is a property, so a child with no effect_group of its own answers from
    // the first ancestor that declares one.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/items.xml", .{dir});
    try io_fs.writeFile(path, "<items>\n" ++
        "  <item name=\"gunMaster\">\n" ++
        "    <effect_group name=\"gunMaster\">\n" ++
        "      <passive_effect name=\"ModSlots\" operation=\"base_set\" value=\"1,1,1,2,2,3\" tier=\"1,2,3,4,5,6\"/>\n" ++
        "    </effect_group>\n" ++
        "  </item>\n" ++
        "  <item name=\"gunChild\">\n" ++
        "    <property name=\"Extends\" value=\"gunMaster\"/>\n" ++
        "  </item>\n" ++
        "  <item name=\"perkBook\">\n" ++
        "    <effect_group name=\"perkBook\" tiered=\"false\">\n" ++
        "      <passive_effect name=\"ModSlots\" operation=\"base_set\" value=\"1\"/>\n" ++
        "    </effect_group>\n" ++
        "  </item>\n" ++
        "  <item name=\"perkBookChild\">\n" ++
        "    <property name=\"Extends\" value=\"perkBook\"/>\n" ++
        "  </item>\n" ++
        "  <item name=\"resourceWood\">\n" ++
        "    <property name=\"Stacknumber\" value=\"100\"/>\n" ++
        "  </item>\n" ++
        "</items>\n");
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expect(t.byName("gunMaster").?.has_quality);
    try std.testing.expect(t.byName("gunChild").?.has_quality);
    try std.testing.expect(!t.byName("perkBook").?.has_quality);
    try std.testing.expect(!t.byName("perkBookChild").?.has_quality);
    // No effect_group anywhere in the chain: null Effects, no quality.
    try std.testing.expect(!t.byName("resourceWood").?.has_quality);
    // Name lookup mirrors the field (the trader roll's resolver); an unknown
    // name fails closed.
    try std.testing.expect(t.hasQualityByName("gunChild"));
    try std.testing.expect(!t.hasQualityByName("noSuchItem"));
}

test "items root max_quality_tier bounds the quality axes" {
    // Stock `ItemClassesFromXml.CreateItems` parses the `<items>` root
    // attribute into the static `ItemClass.MaxQualityTier` and assigns 6 when
    // it is absent. V3.2.0 ships no attribute; a modlet that sets it (XPath
    // `/items/@max_quality_tier`) has to move the quality axis with it, or the
    // server clamps a tier the client accepts.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/items.xml", .{dir});
    try io_fs.writeFile(path,
        \\<items max_quality_tier="10">
        \\  <item name="gunMaster">
        \\    <property name="Stacknumber" value="1"/>
        \\    <effect_group name="gunMaster" tiered="true">
        \\      <passive_effect name="ModSlots" operation="base_set" value="1"/>
        \\    </effect_group>
        \\  </item>
        \\</items>
    );
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expectEqual(@as(u8, 10), t.max_quality_tier);
    // The harvest curve spreads over the table's tier count, not the default.
    const no_rows = t.harvestMultiplier(t.byName("gunMaster").?.id, 7, "wood");
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), no_rows, 0.001);

    // Absent attribute: stock's 6. A degenerate value keeps it too.
    try io_fs.writeFile(path, "<items max_quality_tier=\"0\">\n</items>\n");
    var t2 = try loadFromPath(std.testing.allocator, path);
    defer t2.deinit();
    try std.testing.expectEqual(@as(u8, 6), t2.max_quality_tier);
}

test "EconomicValue keeps stock's float range and fraction" {
    // Stock fields EconomicValue as `Single` and parses it with ParseFloat
    // (ItemClass IL_0666). Typing it u16 turned a modlet's 1000000-duke relic
    // (or a 2.5 value) into 0, which the trader then prices at the
    // "econ == 0" fallback of buy 5 / sell 1, i.e. not tradeable as authored.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/items.xml", .{dir});
    try io_fs.writeFile(path,
        \\<items>
        \\  <item name="relic">
        \\    <property name="EconomicValue" value="1000000"/>
        \\  </item>
        \\  <item name="fraction">
        \\    <property name="EconomicValue" value="2.5"/>
        \\  </item>
        \\  <item name="plain"/>
        \\</items>
    );
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expectEqual(@as(f32, 1000000), t.byName("relic").?.econ);
    try std.testing.expectEqual(@as(f32, 2.5), t.byName("fraction").?.econ);
    // No EconomicValue anywhere: 0, the trader's untradeable marker.
    try std.testing.expectEqual(@as(f32, 0), t.byName("plain").?.econ);
}

test "items.xml stats rows parse with stock's field grammar and guards" {
    // Stock ItemClass::GSStatsParseXml IL=181: each `<stat>` needs a name and a
    // value with at least five comma fields (quality, gameStage, chance, min,
    // max); |min| or |max| at 163.835 or above is rejected rather than
    // overflowing the i16 cast, and the stored value is the XML number divided
    // by 0.005.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/items_stats.xml", .{dir});
    try io_fs.writeFile(path,
        \\<items>
        \\  <item name="gunMaster">
        \\    <stats>
        \\      <stat name="EntityDamage" value="0,0,1,0,.1"/>
        \\      <stat name="DegradationMax" value="0,60,.5,-.1,.2"/>
        \\    </stats>
        \\  </item>
        \\  <item name="badRows">
        \\    <stats>
        \\      <stat name="EntityDamage" value="0,0,1,0"/>
        \\      <stat name="" value="0,0,1,0,.1"/>
        \\      <stat name="Range" value="0,0,1,0,200"/>
        \\      <stat name="BlockDamage" value="0,0,1,notanumber,.1"/>
        \\    </stats>
        \\  </item>
        \\  <item name="emptyStats"><stats></stats></item>
        \\</items>
    );
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const gm = t.byName("gunMaster").?;
    try std.testing.expectEqual(@as(usize, 2), gm.stats.len);
    try std.testing.expectEqualStrings("EntityDamage", gm.stats[0].effect);
    try std.testing.expectEqual(@as(i16, 0), gm.stats[0].quality);
    try std.testing.expectEqual(@as(i16, 0), gm.stats[0].game_stage);
    try std.testing.expectEqual(@as(f32, 1), gm.stats[0].chance);
    try std.testing.expectEqual(@as(i16, 0), gm.stats[0].min);
    try std.testing.expectEqual(@as(i16, 20), gm.stats[0].max); // .1 / .005
    try std.testing.expectEqualStrings("DegradationMax", gm.stats[1].effect);
    try std.testing.expectEqual(@as(i16, 60), gm.stats[1].game_stage);
    try std.testing.expectEqual(@as(f32, 0.5), gm.stats[1].chance);
    try std.testing.expectEqual(@as(i16, -20), gm.stats[1].min); // -.1 / .005
    try std.testing.expectEqual(@as(i16, 40), gm.stats[1].max); // .2 / .005
    // Every malformed row is dropped; the well-formed ones stay.
    try std.testing.expectEqual(@as(usize, 0), t.byName("badRows").?.stats.len);
    try std.testing.expectEqual(@as(usize, 0), t.byName("emptyStats").?.stats.len);
}

test "stock items.xml stats rows load" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/items.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    // A tool carries the Base_Random_Roll rows; EntityDamage is
    // "0,0,1,0,.1" (chance 1, min 0, max 20 after the /0.005 scale).
    const axe = t.byName("meleeToolAxeT1IronFireaxe") orelse return error.TestUnexpectedResult;
    try std.testing.expect(axe.stats.len >= 4);
    // Two EntityDamage rows: the quality-0 base roll (chance 1, max .1) and the
    // quality-1 boosted roll (chance .3, min .1, max .5).
    var base: ?GsStat = null;
    var boosted: ?GsStat = null;
    for (axe.stats) |r| {
        if (!std.mem.eql(u8, r.effect, "EntityDamage")) continue;
        if (r.quality == 0) base = r;
        if (r.quality == 1) boosted = r;
    }
    try std.testing.expectEqual(@as(i16, 20), base.?.max);
    try std.testing.expectEqual(@as(f32, 1), base.?.chance);
    try std.testing.expectEqual(@as(i16, 20), boosted.?.min);
    try std.testing.expectEqual(@as(i16, 100), boosted.?.max);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), boosted.?.chance, 0.0001);
    // An item with no <stats> block stays empty (fail closed, no invented rows).
    try std.testing.expectEqual(@as(usize, 0), t.byName("resourceWood").?.stats.len);
}

test "SellableToTrader parses and inherits through Extends" {
    // Stock `ItemClass` reads SellableToTrader with ParseBool (default true)
    // and the property dictionary is copied through Extends, so a child of an
    // unsellable master is unsellable too. 48 stock items declare it.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/items_sell.xml", .{dir});
    try io_fs.writeFile(path,
        \\<items>
        \\  <item name="questItemMaster">
        \\    <property name="SellableToTrader" value="false"/>
        \\  </item>
        \\  <item name="questItemChild">
        \\    <property name="Extends" value="questItemMaster"/>
        \\  </item>
        \\  <item name="plainItem"/>
        \\  <item name="declaredTrue">
        \\    <property name="SellableToTrader" value="true"/>
        \\  </item>
        \\</items>
    );
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expect(!t.byName("questItemMaster").?.sellable_to_trader);
    try std.testing.expect(!t.byName("questItemChild").?.sellable_to_trader);
    // Absent keeps stock's true default.
    try std.testing.expect(t.byName("plainItem").?.sellable_to_trader);
    try std.testing.expect(t.byName("declaredTrue").?.sellable_to_trader);
}

test "stock items.xml SellableToTrader rows load" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/items.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    // meleeWpnBladeT0BoneKnife carries value="false" (items.xml:40) and the
    // quest masters inherit it.
    try std.testing.expect(!t.byName("meleeWpnBladeT0BoneKnife").?.sellable_to_trader);
    // The default is true for the bulk of the catalog.
    try std.testing.expect(t.byName("gunHandgunT0PipePistol").?.sellable_to_trader);
}

test "TraderQualityMod parses and inherits through Extends" {
    // Stock ItemClass reads the quality price pair
    // (TraderQualityMinMod/MaxMod, written as the comma pair TraderQualityMod
    // in items.xml; 4 stock rows, all "1,20") and XUiM_Trader's GetBuyPrice /
    // GetSellPrice lerp it over (Quality-1)/5, falling back to the trader's
    // pair when the item declares none.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/items_tqm.xml", .{dir});
    try io_fs.writeFile(path,
        \\<items>
        \\  <item name="cookMaster">
        \\    <property name="TraderQualityMod" value="1,20"/>
        \\  </item>
        \\  <item name="cookChild">
        \\    <property name="Extends" value="cookMaster"/>
        \\  </item>
        \\  <item name="splitKeys">
        \\    <property name="TraderQualityMinMod" value="2"/>
        \\    <property name="TraderQualityMaxMod" value="7"/>
        \\  </item>
        \\  <item name="plain"/>
        \\</items>
    );
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expectEqual(@as(f32, 1), t.byName("cookMaster").?.trader_quality_min_mod);
    try std.testing.expectEqual(@as(f32, 20), t.byName("cookMaster").?.trader_quality_max_mod);
    // Extends carries both halves.
    try std.testing.expectEqual(@as(f32, 1), t.byName("cookChild").?.trader_quality_min_mod);
    try std.testing.expectEqual(@as(f32, 20), t.byName("cookChild").?.trader_quality_max_mod);
    // The two separate keys work too, and an absent pair stays 0 (the
    // trader's own pair applies).
    try std.testing.expectEqual(@as(f32, 2), t.byName("splitKeys").?.trader_quality_min_mod);
    try std.testing.expectEqual(@as(f32, 7), t.byName("splitKeys").?.trader_quality_max_mod);
    try std.testing.expectEqual(@as(f32, 0), t.byName("plain").?.trader_quality_min_mod);
    try std.testing.expectEqual(@as(f32, 0), t.byName("plain").?.trader_quality_max_mod);
}

test "stock items.xml TraderQualityMod rows load" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/items.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const pot = t.byName("toolCookingPot") orelse return error.SkipZigTest;
    try std.testing.expectEqual(@as(f32, 1), pot.trader_quality_min_mod);
    try std.testing.expectEqual(@as(f32, 20), pot.trader_quality_max_mod);
    // A normal tool declares no pair: the trader's own quality mod applies.
    try std.testing.expectEqual(@as(f32, 0), t.byName("meleeToolAxeT1IronFireaxe").?.trader_quality_min_mod);
}

test "the gamestage stat roll follows stock's draw order" {
    // The stock axe rows (items.xml meleeToolAxeT1IronFireaxe): a quality-0
    // base row (chance 1, min 0, max .1) and a quality-1 boosted row
    // (chance .3, min .1, max .5); the stored i16s are the XML value / 0.005,
    // so the ranges are 0..20 and 20..100.
    const rows = [_]GsStat{
        .{ .effect = "EntityDamage", .quality = 0, .game_stage = 0, .chance = 1, .min = 0, .max = 20 },
        .{ .effect = "EntityDamage", .quality = 1, .game_stage = 0, .chance = 0.3, .min = 20, .max = 100 },
        .{ .effect = "DegradationMax", .quality = 0, .game_stage = 0, .chance = 1, .min = 0, .max = 0 },
    };
    var out: [6]RolledGsStat = undefined;

    // Deterministic: the same seed draws the same entries, and the base roll
    // stays inside the base row's range.
    var r1 = game_random.GameRandom.init(1234);
    const n1 = rollGsStats(&rows, 1, 0, &r1, &out);
    try std.testing.expect(n1 >= 1);
    // EntityDamage is the first effect and `None`=0, `EntityDamage`=1.
    try std.testing.expectEqual(@as(u8, 1), out[0].effect);
    const value1: i32 = @as(i32, out[0].slot_a) + @as(i32, out[0].slot_b);
    try std.testing.expect(value1 >= 0 and value1 <= 120);
    var r2 = game_random.GameRandom.init(1234);
    var out2: [6]RolledGsStat = undefined;
    const n2 = rollGsStats(&rows, 1, 0, &r2, &out2);
    try std.testing.expectEqual(n1, n2);
    try std.testing.expectEqualSlices(RolledGsStat, out[0..n1], out2[0..n2]);

    // The zero-sum row contributes nothing: an all-zero base row and no
    // quality row emit no entry (stock's RemoveUnusedStats).
    const zero_rows = [_]GsStat{
        .{ .effect = "BlockDamage", .quality = 0, .game_stage = 0, .chance = 1, .min = 0, .max = 0 },
    };
    var r3 = game_random.GameRandom.init(7);
    var out3: [6]RolledGsStat = undefined;
    try std.testing.expectEqual(@as(usize, 0), rollGsStats(&zero_rows, 1, 0, &r3, &out3));

    // A row whose chance gate fails leaves the base roll alone and the added
    // roll out: chance 0 never passes, so the entry is the base only.
    const gated = [_]GsStat{
        .{ .effect = "EntityDamage", .quality = 0, .game_stage = 0, .chance = 1, .min = 5, .max = 5 },
        .{ .effect = "EntityDamage", .quality = 3, .game_stage = 0, .chance = 0, .min = 50, .max = 60 },
    };
    var r4 = game_random.GameRandom.init(99);
    var out4: [6]RolledGsStat = undefined;
    const n4 = rollGsStats(&gated, 3, 0, &r4, &out4);
    try std.testing.expectEqual(@as(usize, 1), n4);
    // Base 5..5 (RandomRange(5, 6) = 5), no added value, so the value is a
    // non-boosted slot_a.
    try std.testing.expectEqual(@as(i16, 5), out4[0].slot_a);
    try std.testing.expectEqual(@as(i16, 0), out4[0].slot_b);

    // A stage below the row's gameStage skips it (the quality-1 row declares
    // stage 20: at stage 0 the added roll finds nothing).
    const staged = [_]GsStat{
        .{ .effect = "EntityDamage", .quality = 1, .game_stage = 20, .chance = 1, .min = 40, .max = 40 },
    };
    var r5 = game_random.GameRandom.init(3);
    var out5: [6]RolledGsStat = undefined;
    try std.testing.expectEqual(@as(usize, 0), rollGsStats(&staged, 1, 0, &r5, &out5));
    var r6 = game_random.GameRandom.init(3);
    var out6: [6]RolledGsStat = undefined;
    try std.testing.expectEqual(@as(usize, 0), rollGsStats(&staged, 1, 0, &r6, &out6));
    var r7 = game_random.GameRandom.init(3);
    var out7: [6]RolledGsStat = undefined;
    const n7 = rollGsStats(&staged, 0, 0, &r7, &out7);
    try std.testing.expectEqual(@as(usize, 0), n7);
}
