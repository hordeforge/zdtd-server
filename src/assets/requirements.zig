//! Stock `<requirement>` gates: one parser and one evaluator shape shared by
//! every XML file that carries them (progression effect_groups first; the
//! `<level_requirements>` blocks, buffs and gameevents reuse it).
//!
//! Semantics come from the EffectManager requirement family, not the game-event
//! one: `MinEffectGroup::ParseXml` (IL=103) reads the enclosing element's direct
//! `<requirement>` children into one `RequirementGroup`, and
//! `PassiveEffect::ParsePassiveEffect` (IL=423) reads the row's own; both are
//! checked by `RequirementGroup::IsValid` (AND, `EvalAnd` IL=66) before a row is
//! folded. `RequirementBase::compareValues` (IL=37) fixes the six comparison
//! spellings and their exact float relations.
//!
//! Fail closed (ADR 0023 §2): a kind, target or operand the evaluator cannot
//! resolve refuses the gate. Before this module existed every gated row folded
//! unconditionally, so a tool-, time- or chance-conditional effect applied
//! always; a gate that silently passed would keep that defect while looking
//! fixed. `Counts.unsupported` is how many gates were refused that way, so the
//! remaining vocabulary gap is measured rather than guessed at.

const std = @import("std");
const xml = @import("xml_util.zig");
const sandbox = @import("sandbox.zig");
const cvars = @import("cvars.zig");
const rng_util = @import("../util/rng.zig");

/// One `<requirement name="..."/>` gate. The name may carry a leading `!`,
/// which is stock's negation spelling (RequirementBase::invert).
pub const Requirement = struct {
    kind: Kind = .unsupported,
    /// `name` with the `!` stripped, verbatim from the file. Kept so a refused
    /// gate can be reported by name.
    name: []const u8 = "",
    negated: bool = false,
    op: Compare = .eq,
    value: f32 = 0,
    /// Scalar operand: `progression_name`, `cvar`, `stat`, `skill_name`, `key`.
    arg: []const u8 = "",
    /// Comma list operand: `buff`, `tags`.
    list: []const u8 = "",
    /// `value="@name"`: the operand is the entity's custom variable at
    /// evaluation time, not a literal (`RequirementBase::ParseXAttribute` keeps
    /// the string and `IsValid` reads it through the entity's CVars; a missing
    /// name is 0). `@:`-prefixed values are localization keys, never operands.
    value_cvar: []const u8 = "",
    /// `InBiome biome="N"`. -1 = absent.
    num: i32 = -1,
    /// `HitLocation body_parts="Head,..."` OR-mask of EnumBodyPartHit bits.
    body_parts: i32 = 0,
    target: Target = .self,
    /// `has_all_tags="true"` on a tag-list gate (HoldingItemHasTags/ItemHasTags):
    /// every listed tag must match instead of any one (IL=1C5).
    has_all: bool = false,
    /// `<requirement_group>` children: the group's own requirements and any
    /// nested groups, in document order (`RequirementGroup::groups`/`reqs`).
    /// Empty for a leaf requirement.
    children: []const Requirement = &.{},
    /// `RandomRoll min_max="a,b"` range ends. Bare numbers parse as both ends
    /// at the loot gate; here the attribute pair is stored verbatim.
    min_max: [2]f32 = .{ 0, 100 },
    /// `RandomRoll seed_type="Random|Player|Item"` (stock SeedType enum).
    /// Only `Random` evaluates (seeded from the ctx roll seed); the others
    /// refuse like any unmodelled input.
    seed_type: SeedType = .random,
};

/// `RandomRoll/SeedType`: Item = per-item seed, Player = per-entity seed,
/// Random = per-event seed (`MinEventParams.Seed`).
pub const SeedType = enum(u8) { random, player, item };

/// The vocabulary this evaluator resolves. Everything else maps to
/// `.unsupported` and refuses the gate.
pub const Kind = enum(u8) {
    unsupported,
    progression_level,
    player_level,
    /// `IsDayNumber` IL=32: compare `GameUtils.WorldTimeToDays(worldTime)`
    /// (= clock.day, 1-based) against operation/value. Null Ctx refuses.
    is_day_number,
    /// `TimeOfDay` IL=60: compare `world.worldTime % 24000` against
    /// `DayTimeToWorldTime(h, m, 0)` where XML `value` is hours*100+minutes
    /// (e.g. 1230). Null Ctx refuses (no clock).
    time_of_day,
    has_buff,
    is_alive,
    /// `IsMale` IL=19: target.IsMale. Fill from entity class_id vs
    /// class_player_male / class_player_female. Null Ctx refuses.
    is_male,
    /// `IsCorpse` IL=16: target.IsCorpse(). Fill from Health.corpse_seconds > 0
    /// (stock dwell timer set on death). Null Ctx refuses.
    is_corpse,
    /// `IsSleeping` IL=27: EntityEnemy with IsSleeping set (non-enemy fails).
    /// Fill from mask.sleeper && !sleeper.awake. Null Ctx refuses.
    is_sleeping,
    /// `IsLocalPlayer` IL=23: target is EntityPlayerLocal. Dedicated server
    /// never hosts EntityPlayerLocal — always false when Ctx is filled.
    /// Null Ctx refuses.
    is_local_player,
    /// `IsFPV` IL=34: EntityPlayerLocal.bFirstPersonView. Dedicated server
    /// never hosts EntityPlayerLocal — always false when Ctx is filled
    /// (IL returns invert when target is not local). Null Ctx refuses.
    is_fpv,
    /// `IsSheltered` IL=24: EntityPlayerLocal.shelterPercent > 0. Dedicated
    /// server never hosts EntityPlayerLocal — always false when Ctx is filled
    /// (IL returns false when target is not local). Null Ctx refuses.
    is_sheltered,
    /// `IsSDCS` IL=27: target.emodel is EModelSDCS. Dedicated server never
    /// hosts Unity EModel* — always false when Ctx is filled. Null Ctx refuses.
    is_sdcs,
    /// `IsAlly` IL=36: EntityPlayer && IsFriendOfLocalPlayer() && not
    /// EntityPlayerLocal. Dedicated server never hosts a local player — always
    /// false when Ctx is filled. Null Ctx refuses.
    is_ally,
    /// `IsOnLadder` IL=19: despite the name, tests `target.IsInElevator()`.
    /// No elevator flag tracked in sim — always false when Ctx is filled.
    /// Null Ctx refuses.
    is_on_ladder,
    /// `HasAttachedPrefab` IL=53: finds `tempPrefab_` + prefabName under
    /// Self.RootTransform (Unity). Dedicated server never hosts transforms —
    /// always false when Ctx is filled. Null Ctx refuses.
    has_attached_prefab,
    /// `HasParticle` IL=23: `params.Self.HasParticle(particleName)`. Dedicated
    /// server never hosts Unity particle FX — always false when Ctx is filled.
    /// Null Ctx refuses.
    has_particle,
    /// `IsLookingAtBlock` IL=8: after RequirementBase::IsValid, stock always
    /// returns true (raycast stub is empty). Fill true when Ctx is filled.
    /// Null Ctx refuses.
    is_looking_at_block,
    /// `IsLookingAtEntity` base=IsLookingAtBlock: inherits IsValid IL=8 stub
    /// that always returns true after RequirementBase::IsValid. Fill true when
    /// Ctx is filled. Null Ctx refuses.
    is_looking_at_entity,
    /// `IsIndoors` IL=25: `target.Stats.AmountEnclosed > 0`. Enclosure is not
    /// tracked yet — AmountEnclosed stays 0 → always false when Ctx is filled.
    /// Null Ctx refuses. (# ponytail: enclosure model later if indoors passives matter)
    is_indoors,
    is_attached_to_entity,
    in_biome,
    holding_item_has_tags,
    /// `HoldingItemBroken`: true when the held ItemValue's PercentUsesLeft
    /// is 0 (`UseTimes >= MaxUseTimes`). Empty hand / no durability fails
    /// closed (not broken). Null Ctx refuses (no inventory fold in scope).
    holding_item_broken,
    /// `ItemHasTags` IL=43: `params.ItemValue`'s ItemClass tags (HasAnyTags /
    /// HasAllTags). Empty ItemValue fails closed (IL returns false).
    item_has_tags,
    /// `RequirementItemTier` IL=36: `params.ItemValue.Quality` compared with
    /// the row's op/value. Null ItemValue fails closed (IL returns false).
    requirement_item_tier,
    /// `RequirementItemModTier` IL=84: find `mod_name` in ItemValue.Modifications
    /// (case-insensitive) and compare that mod's Quality. Null ItemValue / no
    /// matching mod fails closed (IL returns false).
    requirement_item_mod_tier,
    sandbox_option_bool,
    /// `GameStatBool` gamestat="…": reads a bool GameStat. Stock only ships
    /// `BiomeProgression` (GameStats[66]); unknown names refuse.
    game_stat_bool,
    armor_group_lowest_quality,
    armor_group_count,
    stat_compare_perc_current_to_max,
    /// `StatComparePercCurrentToModMax` IL=66: the stat's current value as a
    /// fraction of `Stat::ModifiedMax` (m_baseMax + m_maxModifier), i.e. the
    /// same denominator the passive VM recomputes as the effective max.
    stat_compare_perc_current_to_mod_max,
    /// `StatCompareModMax` IL=46: the stat's `Stat::ModifiedMax` VALUE.
    stat_compare_mod_max,
    /// `StatCompareMax` IL=46: the stat's `Stat::Max` = `m_baseMax` value.
    stat_compare_max,
    /// `StatComparePercModMaxToMax` IL=42: `Stat::ModifiedMaxPercent` =
    /// ModifiedMax / Max (how far the active modifiers have moved the max).
    stat_compare_perc_mod_max_to_max,
    /// `StatCompareCurrent` IL=52: the stat's current VALUE (not a fraction).
    stat_compare_current,
    /// `EntityTagCompare` IL=43: the target entity's `Tags` set
    /// (`Entity::HasAnyTags` / `HasAllTags`), any-of by default and all-of with
    /// `has_all_tags="true"`.
    entity_tag_compare,
    /// `IsNight` IL=19: `!World.IsDaytime()`, invert-aware.
    is_night,
    /// `IsDay` IL=19: World.IsDaytime() (= !isNight). Null Ctx refuses.
    is_day,
    /// `IsBloodMoon`: true when the world clock is on a blood-moon night
    /// (`WorldClock.isBloodMoonNight`). Null Ctx refuses (no clock).
    is_blood_moon,
    /// `EntityHasMovementTag` IL=47: the target's `CurrentMovementTag` set
    /// (`Test_AnySet` by default, `Test_AllSet` with `has_all_tags`),
    /// invert-aware. zdtd derives idle/walking/running from the client's
    /// reported movement state.
    entity_has_movement_tag,
    /// `IsEquipped` IL=97: true when the row's own item value sits in one of
    /// the target's equipment slots (the mod path scans each equipped item's
    /// Modifications array, which zdtd does not model, so a mod context refuses).
    is_equipped,
    /// `IsItemActive` IL=29: params.ItemValue.get_Activated() (Flags bit 0).
    /// Only the item fold fills it; buff/perk folds refuse. Null Ctx refuses.
    is_item_active,
    /// `IsHeldItem` IL=24: params.ItemValue == holdingItemStack.itemValue.
    /// On the item fold this is the inverse of `item_equipped` (held row
    /// true, equip row false). Null Ctx refuses (no item fold).
    is_held_item,
    /// `IsInstigator` IL=17: target == params.Instigator. Filled only on the
    /// damage fold (attacker Self == Instigator → true; victim Self != → false).
    /// Null Ctx refuses (no damage fold).
    is_instigator,
    /// `CVarCompare` IL=23: the entity's custom variable against `value`
    /// (a missing name reads 0).
    cvar_compare,
    /// `WornItems` IL=54: how many equipment slots hold an item carrying any
    /// of the row's `tags`.
    worn_items,
    /// `RandomRoll` IL=71: `FastLerp(min,max,RandomFloat)` compared against
    /// the value (or the entity's cvar when `value="@name"`). Only the
    /// `Random` seed evaluates, from the ctx roll seed; Player/Item refuse.
    random_roll,
    /// `PerksUnlocked` IL=68: the sum of purchased levels over the named
    /// skill's child perks, compared with the requirement op. A missing
    /// skill (or no children lookup) reads 0 levels, like stock's
    /// GetProgressionValue on an unknown name.
    perks_unlocked,
    /// `IsStatAtMax` IL=100: `Max - Value < 0.1` for the named stat
    /// (Health/Stamina/Water/Food switch). Stock rows use food/water only;
    /// `r.arg` carries `stat` (the generic parser maps it).
    is_stat_at_max,
    /// `InSafeZone` IL=25: `EntityPlayer.TwitchSafe`. zdtd has no Twitch
    /// integration, so the flag is never set and the gate reads false
    /// (stock without Twitch reads the same).
    in_safe_zone,
    /// `HitLocation` IL=27: `(bodyParts & params.DamageResponse.HitBodyPart) != 0`,
    /// invert-aware. Null HitBodyPart refuses (no damage fold in scope).
    hit_location,
    /// `<requirement_group op="and">` (the default when `op` is absent or
    /// unknown): every child must pass. An empty group passes
    /// (`RequirementGroup::EvalAnd` IL=66 returns true with no children).
    group_and,
    /// `<requirement_group op="or">`: one passing child is enough, and an empty
    /// group fails (`RequirementGroup::EvalOr` IL=70 returns false with no
    /// children).
    group_or,
};

/// `RequirementBase/OperationTypes` (OperationTypes.il.txt), case-insensitive
/// here because stock writes both `GTE` and `gt`.
pub const Compare = enum(u8) { eq, ne, lt, gt, le, ge };

/// `TargetedCompareRequirementBase/TargetTypes`: 0 self, 1 other, 2 instigator.
/// Only `self` resolves against the single-entity context zdtd has.
pub const Target = enum(u8) { self, other, instigator };

/// Per-requirement outcome. `unsupported` fails the gate like `fail`; the
/// caller counts it separately so the unported vocabulary stays visible.
pub const Verdict = enum(u8) { pass, fail, unsupported };

/// A progression value the `ProgressionLevel` gate can read. Structurally the
/// server player ledger's `SkillLevel`, which aliases it.
pub const NameLevel = struct {
    name: []const u8 = "",
    level: u8 = 0,
};

/// Buff name -> def id resolver. Kept as a callback so this module needs no
/// dependency on the buffs asset module (which imports it for `Passive.reqs`).
pub const BuffNames = struct {
    ctx: *const anyopaque,
    resolve: *const fn (ctx: *const anyopaque, name: []const u8) ?u16,
};

/// Everything a gate is evaluated against. Defaults describe a fresh, alive,
/// unattached player standing in no biome with no buffs: with no `buff_names`
/// resolver that still decides `HasBuff` (an empty active set is definitively
/// false) and refuses a non-empty one.
pub const Ctx = struct {
    levels: []const NameLevel = &.{},
    player_level: u16 = 1,
    /// `WorldClock.day` for `IsDayNumber` (1-based, same as WorldTimeToDays).
    /// Null = no clock fold (refuse).
    day_number: ?u32 = null,
    /// Within-day world-time ticks (`worldTime % 24000` = trunc(hours*1000))
    /// for `TimeOfDay`. Null = no clock fold (refuse).
    time_of_day_ticks: ?u32 = null,
    alive: bool = true,
    /// EntityPlayer.IsMale for `IsMale`. Null = no identity fold (refuse).
    is_male: ?bool = null,
    /// Health.corpse_seconds > 0 for `IsCorpse`. Null = no health fold (refuse).
    is_corpse: ?bool = null,
    /// mask.sleeper && !sleeper.awake for `IsSleeping`. Null = no sleeper fold (refuse).
    is_sleeping: ?bool = null,
    /// Always false on dedi (no EntityPlayerLocal). Null = no identity fold (refuse).
    is_local_player: ?bool = null,
    /// Always false on dedi (no EntityPlayerLocal / bFirstPersonView).
    /// Null = no identity fold (refuse).
    is_fpv: ?bool = null,
    /// Always false on dedi (no EntityPlayerLocal / shelterPercent).
    /// Null = no identity fold (refuse).
    is_sheltered: ?bool = null,
    /// Always false on dedi (no Unity EModelSDCS). Null = no identity fold (refuse).
    is_sdcs: ?bool = null,
    /// Always false on dedi (no local player / IsFriendOfLocalPlayer).
    /// Null = no identity fold (refuse).
    is_ally: ?bool = null,
    /// Always false until elevator state is tracked (RE IsOnLadder IL=19 =
    /// IsInElevator). Null = no identity fold (refuse).
    is_on_ladder: ?bool = null,
    /// Always false on dedi (no Unity RootTransform / tempPrefab_*).
    /// Null = no identity fold (refuse).
    has_attached_prefab: ?bool = null,
    /// Always false on dedi (no Unity particle FX). Null = no identity fold (refuse).
    has_particle: ?bool = null,
    /// Stock stub always true after base IsValid (RE IsLookingAtBlock IL=8).
    /// Null = no identity fold (refuse).
    is_looking_at_block: ?bool = null,
    /// Stock stub always true after base IsValid (inherits IsLookingAtBlock IL=8).
    /// Null = no identity fold (refuse).
    is_looking_at_entity: ?bool = null,
    /// Always false until AmountEnclosed is tracked (RE IsIndoors IL=25).
    /// Null = no identity fold (refuse).
    is_indoors: ?bool = null,
    attached_to_entity: bool = false,
    /// Biome id at the entity (biomes.xml `<biomemap id>`). Null = no biome in
    /// the params, which fails InBiome in BOTH polarities
    /// (InBiome::IsValid IL=30 returns false before it reads `invert`).
    biome_id: ?u8 = null,
    /// Active buff def ids on the entity.
    active_buffs: []const u16 = &.{},
    buff_names: ?*const BuffNames = null,
    /// The tag set the caller's `EffectManager.GetValue` query passes, as a
    /// comma list. `PassiveEffect::RequirementsMet` (IL=180) matches it against
    /// the row's `tags=` BEFORE the requirement group, and an empty query never
    /// matches a tagged row (hasMatchingTag IL=53). Empty = untagged query.
    tags: []const u8 = "",
    /// The held item's `Tags` property, comma list (HoldingItemHasTags IL=5
    /// reads `Inventory.get_holdingItem().HasAnyTags/HasAllTags`). Empty = an
    /// empty hand, which matches no tag.
    held_tags: []const u8 = "",
    /// Held ItemValue brokenness for `HoldingItemBroken` (PercentUsesLeft == 0).
    /// Null = no inventory fold in scope (refuse); false = empty hand / no
    /// durability / still has uses; true = UseTimes reached MaxUseTimes.
    holding_item_broken: ?bool = null,
    /// `params.ItemValue`'s ItemClass `Tags` for `ItemHasTags` (IL=43). Null =
    /// no ItemValue in scope (buff/perk fold), which refuses rather than
    /// matching the held hand; empty = empty ItemValue / unknown class (fail).
    item_tags: ?[]const u8 = null,
    /// `params.ItemValue.Quality` for `RequirementItemTier` (IL=36). Null = no
    /// ItemValue in scope (buff/perk fold), which refuses; 0 is a valid quality
    /// and still evaluates (IL compares the uint as float).
    item_quality: ?u8 = null,
    /// Installed mods for `RequirementItemModTier` (IL=84): each entry's
    /// `name` is the mod ItemClass name and `level` is its Quality. Null =
    /// no ItemValue in scope (buff/perk fold), which refuses; empty = ItemValue
    /// with no mods (fail closed, no match).
    item_mods: ?[]const NameLevel = null,
    /// `params.DamageResponse.HitBodyPart` for `HitLocation` (IL=27). Null =
    /// no damage fold in scope, which refuses; 0 = None still evaluates.
    hit_body_part: ?i16 = null,
    /// `target == params.Instigator` for `IsInstigator`. Null = no damage fold
    /// (refuse). True on the attacker fold, false on the victim fold.
    is_instigator: ?bool = null,
    /// Decoded sandbox code groups (`SandboxOptions.SandboxOptionManager`, see
    /// `assets/sandbox.zig`); `SandboxOptionBool` (IL=18) reads a bool option.
    sandbox_groups: []const sandbox.Group = &.{},
    /// GameStats[66] `BiomeProgression` for `GameStatBool`. Null = no GameStats
    /// fold in scope (refuse); true/false = the live wire value.
    game_stat_biome_progression: ?bool = null,
    /// Live stat fractions and maxes for the StatCompare gates (0..1 fractions;
    /// a non-positive max fails the gate like the IL).
    hp_frac: f32 = 0,
    /// `Stat::ModifiedMax` (m_baseMax + m_maxModifier) for Health.
    hp_max: f32 = 0,
    /// `Stat::Max` (m_baseMax) for Health, i.e. the max BEFORE the passive VM
    /// modifiers. 0 = the caller does not distinguish base from modified, in
    /// which case the `*ToMax` gates fall back to `hp_max` (the pre-VM
    /// approximation) instead of failing every row.
    hp_base_max: f32 = 0,
    stamina_frac: f32 = 0,
    stamina_max: f32 = 0,
    stamina_base_max: f32 = 0,
    food_frac: f32 = 0,
    food_max: f32 = 0,
    food_base_max: f32 = 0,
    water_frac: f32 = 0,
    water_max: f32 = 0,
    water_base_max: f32 = 0,
    /// `World.IsDaytime()` negated, for `IsNight` (IL=19). Null = the caller has
    /// no clock, which refuses the gate rather than guessing a phase.
    is_night: ?bool = null,
    /// `WorldClock.isNight() == false` for `IsDay`. Null = no clock (refuse).
    is_day: ?bool = null,
    /// `WorldClock.isBloodMoonNight()` for `IsBloodMoon`. Null = no clock
    /// (refuse); true/false = blood-moon night phase.
    is_blood_moon: ?bool = null,
    /// The row's item sits in an equipment slot, for `IsEquipped` (IL=97).
    /// Null = the fold has no item context (a buff or perk row), so the gate is
    /// refused; true/false = the item fold's own answer. An item in the hand is
    /// NOT equipped (Equipment::GetItems does not include the holding slot).
    item_equipped: ?bool = null,
    /// `ItemValue.Flags` bit 0 (Activated) for `IsItemActive`. Null = no item
    /// fold (refuse), same as `item_equipped`.
    item_active: ?bool = null,
    /// The entity's `CurrentMovementTag` set (`EntityAlive::OnUpdateLive` sets
    /// idle/walking/running from the move direction and `bMovementRunning`), as
    /// a comma list, for `EntityHasMovementTag` (IL=47). Null = the caller has
    /// no movement state, which refuses the gate rather than guessing a tag.
    movement_tags: ?[]const u8 = null,
    /// The entity's own `Tags` property (`entityclasses.xml <property
    /// name="Tags">`, inherited through `extends` like `EntityClass.CopyFrom`
    /// IL=171), as a comma list. `EntityTagCompare` with the default `self`
    /// target reads it; null = the caller has no class tag set, which refuses
    /// the gate rather than treating the entity as untagged.
    entity_tags: ?[]const u8 = null,
    /// The `other` entity's `Tags` for `target="other"` rows
    /// (`TargetedCompareRequirementBase` resolves `other`/`instigator` from
    /// `MinEventParams`; the damage path supplies the attacker's tags). Null
    /// = no other entity in scope, which refuses foreign-target rows rather
    /// than reading self.
    other_tags: ?[]const u8 = null,
    /// Healer/attacker progression ledger for `ProgressionLevel target="instigator"`
    /// (Physician heal buffs). Null = no instigator in scope → refuse (not self).
    instigator_levels: ?[]const NameLevel = null,
    /// The `other` entity's progression ledger for `ProgressionLevel target="other"`
    /// (e.g. perkBatterUpMetalChain on entity damage). Null = no other in scope → refuse.
    other_levels: ?[]const NameLevel = null,
    /// The `other` entity's alive bit for `IsAlive target="other"` (damage path).
    /// Null = no other in scope → refuse (not self).
    other_alive: ?bool = null,
    /// The `other` entity's live buff holder for `HasBuff target="other"` (damage path).
    /// Paired with `buff_active` (same BuffSink.has). Null = no other → refuse.
    other_live_buff: ?*const anyopaque = null,
    /// The `other` entity's corpse bit for `IsCorpse target="other"` (damage path).
    /// Null = no other in scope → refuse (not self).
    other_is_corpse: ?bool = null,
    /// The `other` entity's sleeper bit for `IsSleeping target="other"` (damage path).
    /// Null = no other in scope → refuse (not self).
    other_is_sleeping: ?bool = null,
    /// One entry per worn equipment item: the item's `Tags` property as a comma
    /// list (`WornItems` IL=54 walks `Equipment::GetSlotCount` and asks each
    /// item's `ItemClass::HasAnyTags`). Empty = nothing worn.
    worn_items: []const []const u8 = &.{},
    /// Live buff lookup (by name), preferred over the `active_buffs` snapshot.
    /// Stock applies `AddBuff`/`RemoveBuff` as the row passes, so a later row's
    /// `HasBuff` gate sees an earlier row's add; a snapshot cannot show that.
    /// `buff_names` still resolves the name when only the slice is available.
    live_buff: ?*const anyopaque = null,
    buff_active: ?*const fn (live: *const anyopaque, name: []const u8) bool = null,
    /// Applies a row's `AddBuff`/`RemoveBuff` the moment the row passes (same
    /// stock ordering). Null = record the request only, as before.
    sink: ?TriggeredSink = null,
    /// `Equipment::GetTotalPhysicalArmorRating`: the worn-armour rating the
    /// `coredamageresist` passive query produces, which `StatCompareCurrent`
    /// StatType 5 and `StatComparePercCurrentToModMax` read. zdtd folds the
    /// rating in the same tick's VM pass, so a gate sees the previous tick's
    /// value: one 50 ms tick stale, which is far closer than refusing the 8
    /// stock `stat="Armor"` rows that drive the armour status buffs.
    armor_rating: f32 = 0,
    /// The entity's custom variables (`assets/cvars.zig`). `CVarCompare`
    /// (IL=23) and passive rows whose `value="@name"` read them (a name that is
    /// not present reads 0, `EntityBuffs::GetCustomVar` IL=10), and the
    /// triggered engine's `ModifyCVar`/`RemoveCVar` rows write them in row
    /// order, so a later row's gate sees an earlier row's write. Null = the
    /// caller has no store (gates and values read 0, writes are dropped).
    cvars: ?*cvars.Set = null,
    /// Worn-armor groups and their lowest worn quality
    /// (`Equipment::ResetArmorGroups` IL=51 / `GetArmorGroupLowestQuality`),
    /// for `ArmorGroupLowestQuality` (IL=34). A group that is not worn is
    /// absent and reads as quality 0, exactly like the stock lookup.
    armor_groups: []const ArmorGroup = &.{},
    /// Per-event roll seed for `RandomRoll seed_type="Random"` (stock seeds a
    /// fresh GameRandom from `MinEventParams.Seed`). Null = the caller has no
    /// event seed, which refuses the gate (a wall-clock seed would
    /// desynchronize the sim and is never used).
    roll_seed: ?u32 = null,
    /// Skill children lookup for `PerksUnlocked`: given a skill name, the
    /// caller lists its child perk names (progression table `parent_attr`).
    /// Null = no tree available, which reads 0 levels (stock's unknown-name
    /// path) rather than refusing.
    skill_children_ctx: ?*const anyopaque = null,
    skill_children_total: ?*const fn (ctx: *const anyopaque, skill: []const u8, levels: []const NameLevel) u16 = null,
};

/// One worn armor group: how many items of it are worn and the lowest quality
/// among them (`Equipment::AddArmorGroup` IL=0 counts and minimises in one
/// pass).
pub const ArmorGroup = struct {
    name: []const u8 = "",
    quality: u8 = 0,
    count: u8 = 0,
};

/// A live sink for a row's AddBuff/RemoveBuff requests: `requirements.zig` may
/// not know about the buff catalog or the ECS, so the caller supplies the two
/// callbacks and the engine calls them as the row passes.
pub const TriggeredSink = struct {
    ctx: *const anyopaque,
    add_buff: *const fn (ctx: *const anyopaque, name: []const u8) void,
    remove_buff: *const fn (ctx: *const anyopaque, name: []const u8) void,
};

/// Gate accounting for one fold. Both counters are per requirement evaluated
/// on a row the caller would otherwise fold.
pub const Counts = struct {
    /// Requirements resolved to pass or fail.
    resolved: u32 = 0,
    /// Requirements refused because the kind, target or operand is not
    /// implemented. Every one of these fails its gate closed.
    unsupported: u32 = 0,
};

pub fn kindOf(name: []const u8) Kind {
    if (std.mem.eql(u8, name, "ProgressionLevel")) return .progression_level;
    if (std.mem.eql(u8, name, "PlayerLevel")) return .player_level;
    if (std.mem.eql(u8, name, "IsDayNumber")) return .is_day_number;
    if (std.mem.eql(u8, name, "TimeOfDay")) return .time_of_day;
    if (std.mem.eql(u8, name, "HasBuff")) return .has_buff;
    if (std.mem.eql(u8, name, "IsAlive")) return .is_alive;
    if (std.mem.eql(u8, name, "IsMale")) return .is_male;
    if (std.mem.eql(u8, name, "IsCorpse")) return .is_corpse;
    if (std.mem.eql(u8, name, "IsSleeping")) return .is_sleeping;
    if (std.mem.eql(u8, name, "IsLocalPlayer")) return .is_local_player;
    if (std.mem.eql(u8, name, "IsFPV")) return .is_fpv;
    if (std.mem.eql(u8, name, "IsSheltered")) return .is_sheltered;
    if (std.mem.eql(u8, name, "IsSDCS")) return .is_sdcs;
    if (std.mem.eql(u8, name, "IsAlly")) return .is_ally;
    if (std.mem.eql(u8, name, "IsOnLadder")) return .is_on_ladder;
    if (std.mem.eql(u8, name, "HasAttachedPrefab")) return .has_attached_prefab;
    if (std.mem.eql(u8, name, "HasParticle")) return .has_particle;
    if (std.mem.eql(u8, name, "IsLookingAtBlock")) return .is_looking_at_block;
    if (std.mem.eql(u8, name, "IsLookingAtEntity")) return .is_looking_at_entity;
    if (std.mem.eql(u8, name, "IsIndoors")) return .is_indoors;
    if (std.mem.eql(u8, name, "IsAttachedToEntity")) return .is_attached_to_entity;
    if (std.mem.eql(u8, name, "InBiome")) return .in_biome;
    if (std.mem.eql(u8, name, "HoldingItemHasTags")) return .holding_item_has_tags;
    if (std.mem.eql(u8, name, "HoldingItemBroken")) return .holding_item_broken;
    if (std.mem.eql(u8, name, "ItemHasTags")) return .item_has_tags;
    if (std.mem.eql(u8, name, "RequirementItemTier")) return .requirement_item_tier;
    if (std.mem.eql(u8, name, "RequirementItemModTier")) return .requirement_item_mod_tier;
    if (std.mem.eql(u8, name, "SandboxOptionBool")) return .sandbox_option_bool;
    if (std.mem.eql(u8, name, "GameStatBool")) return .game_stat_bool;
    if (std.mem.eql(u8, name, "ArmorGroupLowestQuality")) return .armor_group_lowest_quality;
    if (std.mem.eql(u8, name, "ArmorGroupCount")) return .armor_group_count;
    if (std.mem.eql(u8, name, "StatComparePercCurrentToMax")) return .stat_compare_perc_current_to_max;
    if (std.mem.eql(u8, name, "StatComparePercCurrentToModMax")) return .stat_compare_perc_current_to_mod_max;
    if (std.mem.eql(u8, name, "StatCompareModMax")) return .stat_compare_mod_max;
    if (std.mem.eql(u8, name, "StatCompareMax")) return .stat_compare_max;
    if (std.mem.eql(u8, name, "StatComparePercModMaxToMax")) return .stat_compare_perc_mod_max_to_max;
    if (std.mem.eql(u8, name, "StatCompareCurrent")) return .stat_compare_current;
    if (std.mem.eql(u8, name, "EntityTagCompare")) return .entity_tag_compare;
    if (std.mem.eql(u8, name, "IsNight")) return .is_night;
    if (std.mem.eql(u8, name, "IsBloodMoon")) return .is_blood_moon;
    if (std.mem.eql(u8, name, "IsEquipped")) return .is_equipped;
    if (std.mem.eql(u8, name, "IsItemActive")) return .is_item_active;
    if (std.mem.eql(u8, name, "IsHeldItem")) return .is_held_item;
    if (std.mem.eql(u8, name, "IsInstigator")) return .is_instigator;
    if (std.mem.eql(u8, name, "EntityHasMovementTag")) return .entity_has_movement_tag;
    if (std.mem.eql(u8, name, "CVarCompare")) return .cvar_compare;
    if (std.mem.eql(u8, name, "WornItems")) return .worn_items;
    if (std.mem.eql(u8, name, "RandomRoll")) return .random_roll;
    if (std.mem.eql(u8, name, "PerksUnlocked")) return .perks_unlocked;
    if (std.mem.eql(u8, name, "IsStatAtMax")) return .is_stat_at_max;
    if (std.mem.eql(u8, name, "InSafeZone")) return .in_safe_zone;
    if (std.mem.eql(u8, name, "HitLocation")) return .hit_location;
    return .unsupported;
}

pub fn parseCompare(s: []const u8) Compare {
    var buf: [32]u8 = undefined;
    if (s.len > buf.len) return .eq;
    const lower = std.ascii.lowerString(&buf, s);
    if (std.mem.eql(u8, lower, "gte") or std.mem.eql(u8, lower, "greaterorequal") or std.mem.eql(u8, lower, "greaterthanorequalto")) return .ge;
    if (std.mem.eql(u8, lower, "gt") or std.mem.eql(u8, lower, "greater") or std.mem.eql(u8, lower, "greaterthan")) return .gt;
    if (std.mem.eql(u8, lower, "lte") or std.mem.eql(u8, lower, "lessorequal") or std.mem.eql(u8, lower, "lessthanorequalto")) return .le;
    if (std.mem.eql(u8, lower, "lt") or std.mem.eql(u8, lower, "less") or std.mem.eql(u8, lower, "lessthan")) return .lt;
    if (std.mem.eql(u8, lower, "ne") or std.mem.eql(u8, lower, "neq") or std.mem.eql(u8, lower, "notequals")) return .ne;
    return .eq;
}

pub fn parseTarget(s: []const u8) Target {
    if (std.mem.eql(u8, s, "other")) return .other;
    if (std.mem.eql(u8, s, "instigator")) return .instigator;
    return .self;
}

/// Parse the `<requirement ...>` whose open tag begins at `tag_start` in `hay`.
/// `arena` owns the retained slices; the returned value is not valid after the
/// arena dies.
pub fn parse(hay: []const u8, tag_start: usize, arena: std.mem.Allocator) std.mem.Allocator.Error!Requirement {
    var r: Requirement = .{};
    const raw = xml.attr(hay, tag_start, "name") orelse return r;
    var n = raw;
    if (n.len > 0 and n[0] == '!') {
        r.negated = true;
        n = n[1..];
    }
    r.name = try arena.dupe(u8, n);
    r.kind = kindOf(n);
    if (xml.attr(hay, tag_start, "operation")) |o| r.op = parseCompare(o);
    if (xml.attr(hay, tag_start, "value")) |v| {
        if (v.len > 1 and v[0] == '@' and v[1] != ':') {
            r.value_cvar = try arena.dupe(u8, v[1..]);
        } else {
            r.value = std.fmt.parseFloat(f32, v) catch 0;
        }
    }
    if (xml.attr(hay, tag_start, "target")) |t| r.target = parseTarget(t);
    if (xml.attr(hay, tag_start, "biome")) |b| r.num = std.fmt.parseInt(i32, b, 10) catch -1;
    if (xml.attr(hay, tag_start, "has_all_tags")) |v| r.has_all = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "True");
    if (xml.attr(hay, tag_start, "min_max")) |m| r.min_max = parseMinMax(m);
    if (xml.attr(hay, tag_start, "seed_type")) |s| {
        if (std.mem.eql(u8, s, "Player")) r.seed_type = .player;
        if (std.mem.eql(u8, s, "Item")) r.seed_type = .item;
    }
    r.arg = try arena.dupe(u8, xml.attr(hay, tag_start, "progression_name") orelse
        xml.attr(hay, tag_start, "cvar") orelse
        xml.attr(hay, tag_start, "option") orelse
        xml.attr(hay, tag_start, "gamestat") orelse
        xml.attr(hay, tag_start, "group_name") orelse
        xml.attr(hay, tag_start, "stat") orelse
        xml.attr(hay, tag_start, "skill_name") orelse
        xml.attr(hay, tag_start, "key") orelse
        xml.attr(hay, tag_start, "mod_name") orelse "");
    r.list = try arena.dupe(u8, xml.attr(hay, tag_start, "buff") orelse
        xml.attr(hay, tag_start, "tags") orelse "");
    if (xml.attr(hay, tag_start, "body_parts")) |bp| r.body_parts = parseBodyParts(bp);
    return r;
}

/// `RequirementBase::compareValues` (IL=37). The <= / >= forms are the
/// negations of > / <, which is how stock spells them (`cgt.un`/`clt.un` then
/// `ceq 0`); keep that shape so a NaN operand behaves like stock rather than
/// like a second comparison operator.
pub fn compare(a: f32, op: Compare, b: f32) bool {
    return switch (op) {
        .eq => a == b,
        .ne => !(a == b),
        .lt => a < b,
        .gt => a > b,
        .le => !(a > b),
        .ge => !(a < b),
    };
}

fn verdict(v: bool, negated: bool) Verdict {
    const pass = if (negated) !v else v;
    return if (pass) .pass else .fail;
}

fn levelOf(levels: []const NameLevel, name: []const u8) ?u8 {
    for (levels) |l| {
        if (std.mem.eql(u8, l.name, name)) return l.level;
    }
    return null;
}

fn evalHasBuff(r: Requirement, ctx: Ctx) Verdict {
    // The live lookup wins when the caller can see the set changing during the
    // scan (stock's ordering); the slice is the fallback for gate-only callers.
    if (ctx.buff_active) |live| {
        const holder = ctx.live_buff orelse return .unsupported;
        var it = std.mem.splitScalar(u8, r.list, ',');
        while (it.next()) |seg| {
            const name = std.mem.trim(u8, seg, " \t");
            if (name.len == 0) continue;
            if (live(holder, name)) return verdict(true, r.negated);
        }
        return verdict(false, r.negated);
    }
    // An empty active set decides the gate without a name catalog.
    if (ctx.active_buffs.len == 0) return verdict(false, r.negated);
    const names = ctx.buff_names orelse return .unsupported;
    var it = std.mem.splitScalar(u8, r.list, ',');
    while (it.next()) |seg| {
        const name = std.mem.trim(u8, seg, " \t");
        if (name.len == 0) continue;
        // HasBuff::ParseXAttribute lowercases the list; EntityBuffs::HasBuff
        // looks the name up case-insensitively. A name the catalog does not
        // carry is simply not active.
        const id = names.resolve(names.ctx, name) orelse continue;
        for (ctx.active_buffs) |a| {
            if (a == id) return verdict(true, r.negated);
        }
    }
    return verdict(false, r.negated);
}

/// `HoldingItemHasTags::IsValid` (IL=37): the held item's tag set is matched
/// any-of by default and all-of with `has_all_tags="true"`. An empty hand
/// carries no tags, so any-of is false and all-of is vacuously true only for an
/// empty tag list (a malformed row).
fn evalHoldingItemHasTags(r: Requirement, ctx: Ctx) Verdict {
    var matched = r.has_all; // any-of starts false, all-of starts true
    const held = ctx.held_tags;
    var seen = false;
    var it = std.mem.splitScalar(u8, r.list, ',');
    while (it.next()) |seg| {
        const tag = std.mem.trim(u8, seg, " \t");
        if (tag.len == 0) continue;
        seen = true;
        const hit = held.len > 0 and tagListHas(held, tag);
        if (r.has_all) {
            if (!hit) {
                matched = false;
                break;
            }
        } else if (hit) {
            matched = true;
            break;
        }
    }
    if (!seen) matched = r.has_all; // empty list: any-of false, all-of true
    return verdict(matched, r.negated);
}

/// `ItemHasTags::IsValid` (IL=43): same any-of/all-of match as HoldingItemHasTags,
/// but against `params.ItemValue`'s ItemClass tags. Null `item_tags` = no
/// ItemValue in scope (buff/perk fold) → refuse; empty = empty ItemValue → fail.
fn evalItemHasTags(r: Requirement, ctx: Ctx) Verdict {
    const tags = ctx.item_tags orelse return .unsupported;
    var matched = r.has_all;
    var seen = false;
    var it = std.mem.splitScalar(u8, r.list, ',');
    while (it.next()) |seg| {
        const tag = std.mem.trim(u8, seg, " \t");
        if (tag.len == 0) continue;
        seen = true;
        const hit = tags.len > 0 and tagListHas(tags, tag);
        if (r.has_all) {
            if (!hit) {
                matched = false;
                break;
            }
        } else if (hit) {
            matched = true;
            break;
        }
    }
    if (!seen) matched = r.has_all;
    return verdict(matched, r.negated);
}

/// `RequirementItemTier::IsValid` (IL=36): compares `params.ItemValue.Quality`
/// with the row's op/value. Null ItemValue refuses (no item fold in scope);
/// a present quality of 0 still evaluates (IL compares the uint as float).
fn evalRequirementItemTier(r: Requirement, ctx: Ctx) Verdict {
    const q = ctx.item_quality orelse return .unsupported;
    return verdict(compare(@floatFromInt(q), r.op, operand(ctx, r)), r.negated);
}

/// `RequirementItemModTier::IsValid` (IL=84): scan Modifications for
/// `mod_name` (case-insensitive), then compareValues(Quality, op, value).
fn evalRequirementItemModTier(r: Requirement, ctx: Ctx) Verdict {
    const mods = ctx.item_mods orelse return .unsupported;
    if (r.arg.len == 0) return .unsupported;
    var q: ?u8 = null;
    for (mods) |m| {
        if (m.name.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(m.name, r.arg)) {
            q = m.level;
            break;
        }
    }
    const quality = q orelse return verdict(false, r.negated);
    return verdict(compare(@floatFromInt(quality), r.op, operand(ctx, r)), r.negated);
}

/// `HitLocation::IsValid` (IL=27): `(bodyParts & HitBodyPart) != 0`, inverted
/// by `invert`. Null HitBodyPart refuses (no damage fold in scope).
fn evalHitLocation(r: Requirement, ctx: Ctx) Verdict {
    const hit = ctx.hit_body_part orelse return .unsupported;
    const matched = (r.body_parts & @as(i32, hit)) != 0;
    return verdict(matched, r.negated);
}

/// Stock `EnumBodyPartHit` flag bits (components.zig comment + Extensions
/// masks). Unknown names contribute 0 so a typo fails closed rather than
/// matching everything.
fn parseBodyParts(s: []const u8) i32 {
    var mask: i32 = 0;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |seg| {
        const n = std.mem.trim(u8, seg, " \t");
        if (n.len == 0) continue;
        mask |= bodyPartBit(n);
    }
    return mask;
}

fn bodyPartBit(name: []const u8) i32 {
    // Exact stock spellings from EnumBodyPartHit / progression.xml.
    if (std.mem.eql(u8, name, "Torso")) return 1;
    if (std.mem.eql(u8, name, "Head")) return 2;
    if (std.mem.eql(u8, name, "LeftUpperArm")) return 4;
    if (std.mem.eql(u8, name, "RightUpperArm")) return 8;
    if (std.mem.eql(u8, name, "LeftUpperLeg")) return 16;
    if (std.mem.eql(u8, name, "RightUpperLeg")) return 32;
    if (std.mem.eql(u8, name, "LeftLowerArm")) return 64;
    if (std.mem.eql(u8, name, "RightLowerArm")) return 128;
    if (std.mem.eql(u8, name, "LeftLowerLeg")) return 256;
    if (std.mem.eql(u8, name, "RightLowerLeg")) return 512;
    if (std.mem.eql(u8, name, "Special") or std.mem.eql(u8, name, "secondary")) return 1024;
    // Stock shorthand in progression.xml (`xxleg,secondary`); treat as Legs.
    if (std.mem.eql(u8, name, "xxleg")) return 816;
    if (std.mem.eql(u8, name, "UpperArms")) return 12;
    if (std.mem.eql(u8, name, "LowerArms")) return 192;
    if (std.mem.eql(u8, name, "Arms")) return 204;
    if (std.mem.eql(u8, name, "UpperLegs")) return 48;
    if (std.mem.eql(u8, name, "LowerLegs")) return 768;
    if (std.mem.eql(u8, name, "Legs")) return 816;
    return 0;
}

/// `SandboxOptionBool::IsValid` (IL=18): `SandboxOptionManager.GetBool` of the
/// named option, which is the decoded sandbox code's index or the option
/// default when the code does not carry it (the stock override list is empty:
/// `sandbox_overrides.xml` ships no active entry). A name outside the option
/// table or a non-bool option refuses the gate.
fn evalSandboxOptionBool(r: Requirement, ctx: Ctx) Verdict {
    const o = sandbox.optionByName(r.arg) orelse return .unsupported;
    if (o.kind != .boolean) return .unsupported;
    var value = o.default_i != 0;
    for (ctx.sandbox_groups) |g| {
        if (g.option_id != o.id) continue;
        value = sandbox.valueB(o, g.index);
        break;
    }
    return verdict(value, r.negated);
}

/// `GameStatBool::IsValid`: bool GameStat by `gamestat=` name. Stock only
/// ships BiomeProgression (GameStats[66]); unknown names refuse.
fn evalGameStatBool(r: Requirement, ctx: Ctx) Verdict {
    if (!std.mem.eql(u8, r.arg, "BiomeProgression")) return .unsupported;
    const v = ctx.game_stat_biome_progression orelse return .unsupported;
    return verdict(v, r.negated);
}

/// `ArmorGroupLowestQuality::IsValid` (IL=34): compares
/// `Equipment.GetArmorGroupLowestQuality(group)` (the lowest quality among the
/// worn items of that group, 0 when the group is not worn) against `value`.
fn evalArmorGroupLowestQuality(r: Requirement, ctx: Ctx) Verdict {
    var quality: f32 = 0;
    for (ctx.armor_groups) |g| {
        if (!std.mem.eql(u8, g.name, r.arg)) continue;
        quality = @floatFromInt(g.quality);
        break;
    }
    return verdict(compare(quality, r.op, operand(ctx, r)), r.negated);
}

/// `ArmorGroupCount::IsValid` (via `Equipment.GetArmorGroupCount`): the number
/// of worn items in the group, 0 when the group is not worn.
fn evalArmorGroupCount(r: Requirement, ctx: Ctx) Verdict {
    var count: f32 = 0;
    for (ctx.armor_groups) |g| {
        if (!std.mem.eql(u8, g.name, r.arg)) continue;
        count = @floatFromInt(g.count);
        break;
    }
    return verdict(compare(count, r.op, operand(ctx, r)), r.negated);
}

/// One tracked stat as the StatCompare family reads it: the current value, its
/// fraction of `Stat::ModifiedMax`, the modified max and the base max
/// (`Stat::Max`). Built from the ctx's `*_frac` / `*_max` / `*_base_max`
/// triple, so every member of the family reads one consistent sample.
const Sample = struct {
    cur: f32 = 0,
    frac: f32 = 0,
    /// `Stat::ModifiedMax` (m_baseMax + m_maxModifier).
    mod_max: f32 = 0,
    /// `Stat::Max` = `m_baseMax`. 0 = the caller did not supply it.
    base_max: f32 = 0,
};

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    return true;
}

/// The sample for a named stat; null for a name the ctx does not track (the
/// caller counts that as unsupported).
fn sample(name: []const u8, ctx: Ctx) ?Sample {
    const frac, const mod_max, const base_max = if (eqIgnoreCase(name, "Health"))
        .{ ctx.hp_frac, ctx.hp_max, ctx.hp_base_max }
    else if (eqIgnoreCase(name, "Stamina"))
        .{ ctx.stamina_frac, ctx.stamina_max, ctx.stamina_base_max }
    else if (eqIgnoreCase(name, "Food"))
        .{ ctx.food_frac, ctx.food_max, ctx.food_base_max }
    else if (eqIgnoreCase(name, "Water"))
        .{ ctx.water_frac, ctx.water_max, ctx.water_base_max }
    else
        return null;
    // `Stat::get_Value` IL=13 clamps to [0, ModifiedMax].
    const cur = @max(0, @min(frac * mod_max, mod_max));
    return .{ .cur = cur, .frac = frac, .mod_max = mod_max, .base_max = base_max };
}

/// `StatComparePercCurrentToMax::Compare` (IL=120): the named stat's value as a
/// fraction of `Stat::Max` (the BASE max), compared against `value`; a stat
/// whose max is not positive fails the gate in both polarities (the IL returns
/// false before reading `invert`). Health, Stamina, Food and Water are the
/// StatTypes the shipped rows use. A caller that carries no base max keeps the
/// pre-VM approximation (the modified max) so a row is not turned off.
fn evalStatComparePercCurrentToMax(r: Requirement, ctx: Ctx) Verdict {
    const s = sample(r.arg, ctx) orelse return .unsupported;
    const denom = if (s.base_max > 0) s.base_max else s.mod_max;
    if (!(denom > 0)) return .fail;
    return verdict(compare(s.cur / denom, r.op, operand(ctx, r)), r.negated);
}

/// `StatComparePercCurrentToModMax::Compare` (IL=66): the stat's value as a
/// fraction of `Stat::ModifiedMax`; a non-positive modified max fails in both
/// polarities (the IL checks `bgt.un` before reading `invert`).
fn evalStatComparePercCurrentToModMax(r: Requirement, ctx: Ctx) Verdict {
    const s = sample(r.arg, ctx) orelse return .unsupported;
    if (!(s.mod_max > 0)) return .fail;
    return verdict(compare(s.frac, r.op, operand(ctx, r)), r.negated);
}

/// `StatCompareModMax::Compare` (IL=46): the stat's `Stat::ModifiedMax` VALUE
/// against the operand.
fn evalStatCompareModMax(r: Requirement, ctx: Ctx) Verdict {
    const s = sample(r.arg, ctx) orelse return .unsupported;
    return verdict(compare(s.mod_max, r.op, operand(ctx, r)), r.negated);
}

/// `StatCompareMax::Compare` (IL=46): the stat's `Stat::Max` (base) VALUE. A
/// caller that does not carry the base max refuses the gate rather than
/// comparing a fabricated 0.
fn evalStatCompareMax(r: Requirement, ctx: Ctx) Verdict {
    const s = sample(r.arg, ctx) orelse return .unsupported;
    if (!(s.base_max > 0)) return .unsupported;
    return verdict(compare(s.base_max, r.op, operand(ctx, r)), r.negated);
}

/// `StatComparePercModMaxToMax::Compare` (IL=42): `Stat::ModifiedMaxPercent`
/// (ModifiedMax / Max) against the operand.
fn evalStatComparePercModMaxToMax(r: Requirement, ctx: Ctx) Verdict {
    const s = sample(r.arg, ctx) orelse return .unsupported;
    if (!(s.base_max > 0)) return .unsupported;
    return verdict(compare(s.mod_max / s.base_max, r.op, operand(ctx, r)), r.negated);
}

/// `StatCompareCurrent::Compare` IL=52: the named stat's CURRENT value against
/// the row's operand (Health, Stamina, Water and Food are StatTypes 1..4; the
/// `Armor` branch reads `Equipment::GetTotalPhysicalArmorRating`).
fn evalStatCompareCurrent(r: Requirement, ctx: Ctx) Verdict {
    if (eqIgnoreCase(r.arg, "Armor")) {
        return verdict(compare(ctx.armor_rating, r.op, operand(ctx, r)), r.negated);
    }
    const s = sample(r.arg, ctx) orelse return .unsupported;
    return verdict(compare(s.cur, r.op, operand(ctx, r)), r.negated);
}

/// `IsNight::IsValid` (IL=19): `!World.IsDaytime()`, invert-aware. A caller
/// with no clock refuses the gate instead of guessing the phase.
fn evalIsNight(r: Requirement, ctx: Ctx) Verdict {
    const night = ctx.is_night orelse return .unsupported;
    return verdict(night, r.negated);
}

/// `IsDay::IsValid` IL=19: World.IsDaytime() (= !isNight).
fn evalIsDay(r: Requirement, ctx: Ctx) Verdict {
    const day = ctx.is_day orelse return .unsupported;
    return verdict(day, r.negated);
}

/// `IsMale::IsValid` IL=19: target.IsMale, invert-aware.
fn evalIsMale(r: Requirement, ctx: Ctx) Verdict {
    const male = ctx.is_male orelse return .unsupported;
    return verdict(male, r.negated);
}

/// `IsCorpse::IsValid` IL=16: target.IsCorpse() (= corpse dwell active).
fn evalIsCorpse(r: Requirement, ctx: Ctx) Verdict {
    const corpse = ctx.is_corpse orelse return .unsupported;
    return verdict(corpse, r.negated);
}

/// `IsSleeping::IsValid` IL=27: EntityEnemy sleeper not yet awake.
fn evalIsSleeping(r: Requirement, ctx: Ctx) Verdict {
    const sleeping = ctx.is_sleeping orelse return .unsupported;
    return verdict(sleeping, r.negated);
}

/// `IsLocalPlayer::IsValid` IL=23: EntityPlayerLocal only exists client-side.
fn evalIsLocalPlayer(r: Requirement, ctx: Ctx) Verdict {
    const local = ctx.is_local_player orelse return .unsupported;
    return verdict(local, r.negated);
}

/// `IsFPV::IsValid` IL=34: EntityPlayerLocal.bFirstPersonView; non-local → false.
fn evalIsFpv(r: Requirement, ctx: Ctx) Verdict {
    const fpv = ctx.is_fpv orelse return .unsupported;
    return verdict(fpv, r.negated);
}

/// `IsSheltered::IsValid` IL=24: EntityPlayerLocal.shelterPercent > 0; non-local → false.
fn evalIsSheltered(r: Requirement, ctx: Ctx) Verdict {
    const sheltered = ctx.is_sheltered orelse return .unsupported;
    return verdict(sheltered, r.negated);
}

/// `IsSDCS::IsValid` IL=27: emodel is EModelSDCS; no Unity model on dedi → false.
fn evalIsSdcs(r: Requirement, ctx: Ctx) Verdict {
    const sdcs = ctx.is_sdcs orelse return .unsupported;
    return verdict(sdcs, r.negated);
}

/// `IsAlly::IsValid` IL=36: IsFriendOfLocalPlayer; no local player on dedi → false.
fn evalIsAlly(r: Requirement, ctx: Ctx) Verdict {
    const ally = ctx.is_ally orelse return .unsupported;
    return verdict(ally, r.negated);
}

/// `IsOnLadder::IsValid` IL=19: IsInElevator(); no elevator flag in sim → false.
fn evalIsOnLadder(r: Requirement, ctx: Ctx) Verdict {
    const on_ladder = ctx.is_on_ladder orelse return .unsupported;
    return verdict(on_ladder, r.negated);
}

/// `HasAttachedPrefab::IsValid` IL=53: Unity RootTransform child; no transforms on dedi → false.
fn evalHasAttachedPrefab(r: Requirement, ctx: Ctx) Verdict {
    const attached = ctx.has_attached_prefab orelse return .unsupported;
    return verdict(attached, r.negated);
}

/// `HasParticle::IsValid` IL=23: Self.HasParticle; no particle FX on dedi → false.
fn evalHasParticle(r: Requirement, ctx: Ctx) Verdict {
    const particle = ctx.has_particle orelse return .unsupported;
    return verdict(particle, r.negated);
}

/// `IsLookingAtBlock::IsValid` IL=8: stock stub returns true after base check.
fn evalIsLookingAtBlock(r: Requirement, ctx: Ctx) Verdict {
    const looking = ctx.is_looking_at_block orelse return .unsupported;
    return verdict(looking, r.negated);
}

/// `IsLookingAtEntity::IsValid`: inherits IsLookingAtBlock stub → true after base check.
fn evalIsLookingAtEntity(r: Requirement, ctx: Ctx) Verdict {
    const looking = ctx.is_looking_at_entity orelse return .unsupported;
    return verdict(looking, r.negated);
}

/// `IsIndoors::IsValid` IL=25: AmountEnclosed > 0; untracked → 0 → false.
fn evalIsIndoors(r: Requirement, ctx: Ctx) Verdict {
    const indoors = ctx.is_indoors orelse return .unsupported;
    return verdict(indoors, r.negated);
}

/// `IsBloodMoon::IsValid`: world clock is on a blood-moon night.
fn evalIsBloodMoon(r: Requirement, ctx: Ctx) Verdict {
    const bm = ctx.is_blood_moon orelse return .unsupported;
    return verdict(bm, r.negated);
}

/// `IsDayNumber::IsValid` IL=32: compare WorldTimeToDays (= clock.day) vs value.
fn evalIsDayNumber(r: Requirement, ctx: Ctx) Verdict {
    const day = ctx.day_number orelse return .unsupported;
    return verdict(compare(@floatFromInt(day), r.op, operand(ctx, r)), r.negated);
}

/// `TimeOfDay::IsValid` IL=60: compare worldTime%24000 vs DayTimeToWorldTime(HHMM).
/// XML value is hours*100+minutes; stock converts via DayTimeToWorldTime(h,m,0)
/// (= h*1000 + m*1000/60) then compareValues against the within-day tick.
fn evalTimeOfDay(r: Requirement, ctx: Ctx) Verdict {
    const ticks = ctx.time_of_day_ticks orelse return .unsupported;
    const hhmm = operand(ctx, r);
    const hours: f32 = @trunc(hhmm / 100.0);
    const minutes: f32 = hhmm - hours * 100.0;
    // DayTimeToWorldTime(h, m, 0): 1000 ticks/hour, 1000/60 per minute.
    const time_value: f32 = hours * 1000.0 + minutes * (1000.0 / 60.0);
    return verdict(compare(@floatFromInt(ticks), r.op, time_value), r.negated);
}

/// `HoldingItemBroken::IsValid`: held ItemValue PercentUsesLeft == 0
/// (`UseTimes >= MaxUseTimes`). Null Ctx refuses; empty hand / no durability
/// is not broken (IL returns false).
fn evalHoldingItemBroken(r: Requirement, ctx: Ctx) Verdict {
    const broken = ctx.holding_item_broken orelse return .unsupported;
    return verdict(broken, r.negated);
}

/// `IsEquipped::IsValid` IL=97: the row's item value is in an equipment slot.
/// The caller supplies that answer for the fold it is running (equipment true,
/// holding false, mods unsupported); a caller with no item context refuses.
fn evalIsEquipped(r: Requirement, ctx: Ctx) Verdict {
    const equipped = ctx.item_equipped orelse return .unsupported;
    return verdict(equipped, r.negated);
}

/// `IsItemActive::IsValid` IL=29: params.ItemValue.get_Activated() (Flags & 1).
fn evalIsItemActive(r: Requirement, ctx: Ctx) Verdict {
    const active = ctx.item_active orelse return .unsupported;
    return verdict(active, r.negated);
}

/// `IsHeldItem::IsValid` IL=24: params.ItemValue == holding stack.
/// Item fold fills `item_equipped`; held ⇒ false ⇒ held-item true.
fn evalIsHeldItem(r: Requirement, ctx: Ctx) Verdict {
    const equipped = ctx.item_equipped orelse return .unsupported;
    return verdict(!equipped, r.negated);
}

/// `IsInstigator::IsValid` IL=17: target == params.Instigator.
fn evalIsInstigator(r: Requirement, ctx: Ctx) Verdict {
    const instigator = ctx.is_instigator orelse return .unsupported;
    return verdict(instigator, r.negated);
}

/// `EntityHasMovementTag::IsValid` IL=47: the target's `CurrentMovementTag` set
/// against the row's tags, any-of via `Test_AnySet` and all-of via
/// `Test_AllSet` with `has_all_tags="true"`, inverted by `invert`. A caller
/// with no movement state refuses rather than guessing a tag.
fn evalEntityHasMovementTag(r: Requirement, ctx: Ctx) Verdict {
    const tags = ctx.movement_tags orelse return .unsupported;
    var matched = r.has_all; // any-of starts false, all-of starts true
    var seen = false;
    var it = std.mem.splitScalar(u8, r.list, ',');
    while (it.next()) |seg| {
        const tag = std.mem.trim(u8, seg, " \t");
        if (tag.len == 0) continue;
        seen = true;
        const hit = tags.len > 0 and tagListHas(tags, tag);
        if (r.has_all) {
            if (!hit) {
                matched = false;
                break;
            }
        } else if (hit) {
            matched = true;
            break;
        }
    }
    if (!seen) matched = r.has_all; // empty list: any-of false, all-of true
    return verdict(matched, r.negated);
}

/// `EntityTagCompare::IsValid` IL=43: `target.HasAnyTags` (any-of) or
/// `HasAllTags` with `has_all_tags="true"`, invert-aware. The evaluator runs
/// for the default `self` target only; a foreign target is refused before the
/// dispatch (the tick ctx carries one entity).
fn evalEntityTagCompare(r: Requirement, ctx: Ctx) Verdict {
    const entity_tags = ctx.entity_tags orelse return .unsupported;
    var matched = r.has_all; // any-of starts false, all-of starts true
    var seen = false;
    var it = std.mem.splitScalar(u8, r.list, ',');
    while (it.next()) |seg| {
        const tag = std.mem.trim(u8, seg, " \t");
        if (tag.len == 0) continue;
        seen = true;
        const hit = entity_tags.len > 0 and tagListHas(entity_tags, tag);
        if (r.has_all) {
            if (!hit) {
                matched = false;
                break;
            }
        } else if (hit) {
            matched = true;
            break;
        }
    }
    if (!seen) matched = r.has_all; // empty list: any-of false, all-of true
    return verdict(matched, r.negated);
}

/// `WornItems::IsValid` IL=54: `compareValues(count, op, value)` where `count`
/// is the number of equipment slots whose item carries ANY of the row's tags
/// (`ItemClass::HasAnyTags`), negated by `invert`.
fn evalWornItems(r: Requirement, ctx: Ctx) Verdict {
    var count: f32 = 0;
    for (ctx.worn_items) |item_tags| {
        var it = std.mem.splitScalar(u8, r.list, ',');
        while (it.next()) |t| {
            if (t.len == 0) continue;
            if (tagListHas(item_tags, t)) {
                count += 1;
                break;
            }
        }
    }
    return verdict(compare(count, r.op, operand(ctx, r)), r.negated);
}

/// `RandomRoll::IsValid` (IL=71): `FastLerp(min,max,RandomFloat)` compared
/// against the value (or the entity's cvar when `value="@name"`). Only the
/// `Random` seed evaluates, drawn from `ctx.roll_seed` (the per-event seed;
/// stock seeds a fresh GameRandom from `MinEventParams.Seed`). Player/Item
/// seeds refuse (no per-entity/per-item stream here), and a null roll seed
/// refuses rather than rolling on wall-clock4287 noise.
fn evalRandomRoll(r: Requirement, ctx: Ctx) Verdict {
    if (r.seed_type != .random) return .unsupported;
    const seed = ctx.roll_seed orelse return .unsupported;
    var rng = rng_util.XorShift32.init(seed);
    const f = @as(f32, @floatFromInt(rng.next() >> 8)) / 16777216.0;
    const rolled = r.min_max[0] + (r.min_max[1] - r.min_max[0]) * f;
    return verdict(compare(rolled, r.op, operand(ctx, r)), r.negated);
}

/// `PerksUnlocked::IsValid` (IL=68): the sum of purchased levels over the
/// named skill's child perks. The children come from the caller's lookup
/// (progression table `parent_attr`); without one the sum is 0. `r.arg`
/// carries `skill_name` (the generic attr parser maps it there).
fn evalPerksUnlocked(r: Requirement, ctx: Ctx) Verdict {
    var total: u16 = 0;
    if (ctx.skill_children_total) |f| {
        if (ctx.skill_children_ctx) |holder| {
            total = f(holder, r.arg, ctx.levels);
        }
    }
    return verdict(compare(@floatFromInt(total), r.op, operand(ctx, r)), r.negated);
}

/// `IsStatAtMax::IsValid` (IL=100): `Max - Value < 0.1` for the named stat.
/// The four stock stats map onto the ctx fractions/maxes (food/water/HP/
fn evalIsStatAtMax(r: Requirement, ctx: Ctx) Verdict {
    // Stat::Max / Stat::Value as (max, value); unknown stat refuses.
    var max: f32 = 0;
    var val: f32 = 0;
    if (std.mem.eql(u8, r.arg, "food")) {
        max = ctx.food_max;
        val = ctx.food_frac * ctx.food_max;
    } else if (std.mem.eql(u8, r.arg, "water")) {
        max = ctx.water_max;
        val = ctx.water_frac * ctx.water_max;
    } else if (std.mem.eql(u8, r.arg, "health")) {
        max = ctx.hp_max;
        val = ctx.hp_frac * ctx.hp_max;
    } else if (std.mem.eql(u8, r.arg, "stamina")) {
        max = ctx.stamina_max;
        val = ctx.stamina_frac * ctx.stamina_max;
    } else return .unsupported;
    return verdict(max - val < 0.1, r.negated);
}

/// `InSafeZone::IsValid` (IL=25): `EntityPlayer.TwitchSafe`. zdtd has no
/// Twitch integration, so the flag is never set and the gate reads false
/// (stock without Twitch reads the same). Invert-aware like the IL.
fn evalInSafeZone(r: Requirement) Verdict {
    return verdict(false, r.negated);
}

/// `CVarCompare::IsValid` IL=23: `compareValues(GetCustomVar(name), op, value)`
/// negated by `invert`.
fn evalCvarCompare(r: Requirement, ctx: Ctx) Verdict {
    return verdict(compare(cvarValue(ctx, r.arg), r.op, operand(ctx, r)), r.negated);
}

/// The right-hand operand of a comparison: the literal `value`, or the entity's
/// custom variable when the row wrote `value="@name"` (255 stock rows do).
/// `min_max="a,b"` pair; a bare number is both ends.
fn parseMinMax(s: []const u8) [2]f32 {
    const comma = std.mem.findScalar(u8, s, ',') orelse {
        const v = std.fmt.parseFloat(f32, std.mem.trim(u8, s, " \t")) catch 0;
        return .{ v, v };
    };
    return .{
        std.fmt.parseFloat(f32, std.mem.trim(u8, s[0..comma], " \t")) catch 0,
        std.fmt.parseFloat(f32, std.mem.trim(u8, s[comma + 1 ..], " \t")) catch 100,
    };
}

fn operand(ctx: Ctx, r: Requirement) f32 {
    if (r.value_cvar.len > 0) return cvarValue(ctx, r.value_cvar);
    return r.value;
}

/// `EntityBuffs::GetCustomVar` IL=10: a missing name is 0.
pub fn cvarValue(ctx: Ctx, name: []const u8) f32 {
    const store = ctx.cvars orelse return 0;
    return store.get(name);
}

/// Whether a comma tag list carries `tag` (case-sensitive, like FastTags).
fn tagListHas(list: []const u8, tag: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, std.mem.trim(u8, seg, " \t"), tag)) return true;
    }
    return false;
}

/// A leaf gate, counted once per evaluated requirement. A group node counts its
/// own children instead: counting the group's aggregate verdict too would
/// double-count every gate inside it.
fn evalOne(r: Requirement, ctx: Ctx, counts: *Counts) Verdict {
    if (r.kind == .group_and or r.kind == .group_or) return evalLeaf(r, ctx, counts);
    const v = evalLeaf(r, ctx, counts);
    switch (v) {
        .pass, .fail => counts.resolved += 1,
        .unsupported => counts.unsupported += 1,
    }
    return v;
}

fn evalLeaf(r: Requirement, ctx: Ctx, counts: *Counts) Verdict {
    // TargetedCompareRequirementBase::IsValid (IL=51) resolves `other` and
    // `instigator` from MinEventParams. Foreign kinds that have a supplier:
    //   EntityTagCompare + other_tags (damage path)
    //   ProgressionLevel + instigator_levels (Physician heal buffs)
    //   ProgressionLevel + other_levels (BatterUpMetalChain / entity damage)
    //   IsAlive + other_alive (damage path)
    //   HasBuff + other_live_buff (damage path; BuffSink.has)
    //   IsCorpse + other_is_corpse / IsSleeping + other_is_sleeping (damage path)
    // Everything else refuses rather than reading self.
    if (r.target != .self and r.kind != .entity_tag_compare and r.kind != .progression_level and r.kind != .is_alive and r.kind != .has_buff and r.kind != .is_corpse and r.kind != .is_sleeping)
        return .unsupported;
    var use_ctx = ctx;
    if (r.target == .other) {
        if (r.kind == .entity_tag_compare) {
            const ot = ctx.other_tags orelse return .unsupported;
            use_ctx.entity_tags = ot;
        } else if (r.kind == .progression_level) {
            const ol = ctx.other_levels orelse return .unsupported;
            use_ctx.levels = ol;
        } else if (r.kind == .is_alive) {
            const oa = ctx.other_alive orelse return .unsupported;
            use_ctx.alive = oa;
        } else if (r.kind == .has_buff) {
            const olb = ctx.other_live_buff orelse return .unsupported;
            use_ctx.live_buff = olb;
            // buff_active stays (BuffSink.has); live_buff holder is the other entity.
        } else if (r.kind == .is_corpse) {
            const oc = ctx.other_is_corpse orelse return .unsupported;
            use_ctx.is_corpse = oc;
        } else if (r.kind == .is_sleeping) {
            const os = ctx.other_is_sleeping orelse return .unsupported;
            use_ctx.is_sleeping = os;
        } else return .unsupported;
    } else if (r.target == .instigator) {
        if (r.kind != .progression_level) return .unsupported;
        const il = ctx.instigator_levels orelse return .unsupported;
        use_ctx.levels = il;
    }
    switch (r.kind) {
        .unsupported => return .unsupported,
        .in_biome => {
            // A null params biome returns false before `invert` is read.
            const id = ctx.biome_id orelse return .fail;
            return verdict(@as(i32, id) == r.num, r.negated);
        },
        .progression_level => {
            // ProgressionLevel::IsValid returns false when the target has no
            // such progression value, before `invert` is read.
            const lvl = levelOf(use_ctx.levels, r.arg) orelse return .fail;
            return verdict(compare(@floatFromInt(lvl), r.op, operand(use_ctx, r)), r.negated);
        },
        .player_level => return verdict(compare(@floatFromInt(ctx.player_level), r.op, operand(ctx, r)), r.negated),
        .is_day_number => return evalIsDayNumber(r, ctx),
        .time_of_day => return evalTimeOfDay(r, ctx),
        .has_buff => return evalHasBuff(r, use_ctx),
        .is_alive => return verdict(use_ctx.alive, r.negated),
        .is_male => return evalIsMale(r, ctx),
        .is_corpse => return evalIsCorpse(r, use_ctx),
        .is_sleeping => return evalIsSleeping(r, use_ctx),
        .is_local_player => return evalIsLocalPlayer(r, ctx),
        .is_fpv => return evalIsFpv(r, ctx),
        .is_sheltered => return evalIsSheltered(r, ctx),
        .is_sdcs => return evalIsSdcs(r, ctx),
        .is_ally => return evalIsAlly(r, ctx),
        .is_on_ladder => return evalIsOnLadder(r, ctx),
        .has_attached_prefab => return evalHasAttachedPrefab(r, ctx),
        .has_particle => return evalHasParticle(r, ctx),
        .is_looking_at_block => return evalIsLookingAtBlock(r, ctx),
        .is_looking_at_entity => return evalIsLookingAtEntity(r, ctx),
        .is_indoors => return evalIsIndoors(r, ctx),
        .is_attached_to_entity => return verdict(ctx.attached_to_entity, r.negated),
        .holding_item_has_tags => return evalHoldingItemHasTags(r, ctx),
        .holding_item_broken => return evalHoldingItemBroken(r, ctx),
        .item_has_tags => return evalItemHasTags(r, ctx),
        .requirement_item_tier => return evalRequirementItemTier(r, ctx),
        .requirement_item_mod_tier => return evalRequirementItemModTier(r, ctx),
        .hit_location => return evalHitLocation(r, ctx),
        .sandbox_option_bool => return evalSandboxOptionBool(r, ctx),
        .game_stat_bool => return evalGameStatBool(r, ctx),
        .armor_group_lowest_quality => return evalArmorGroupLowestQuality(r, ctx),
        .armor_group_count => return evalArmorGroupCount(r, ctx),
        .stat_compare_perc_current_to_max => return evalStatComparePercCurrentToMax(r, ctx),
        .stat_compare_perc_current_to_mod_max => return evalStatComparePercCurrentToModMax(r, ctx),
        .stat_compare_mod_max => return evalStatCompareModMax(r, ctx),
        .stat_compare_max => return evalStatCompareMax(r, ctx),
        .stat_compare_perc_mod_max_to_max => return evalStatComparePercModMaxToMax(r, ctx),
        .stat_compare_current => return evalStatCompareCurrent(r, ctx),
        .entity_tag_compare => return evalEntityTagCompare(r, use_ctx),
        .is_night => return evalIsNight(r, ctx),
        .is_day => return evalIsDay(r, ctx),
        .is_blood_moon => return evalIsBloodMoon(r, ctx),
        .is_equipped => return evalIsEquipped(r, ctx),
        .is_item_active => return evalIsItemActive(r, ctx),
        .is_held_item => return evalIsHeldItem(r, ctx),
        .is_instigator => return evalIsInstigator(r, ctx),
        .entity_has_movement_tag => return evalEntityHasMovementTag(r, ctx),
        .cvar_compare => return evalCvarCompare(r, ctx),
        .worn_items => return evalWornItems(r, ctx),
        .random_roll => return evalRandomRoll(r, ctx),
        .perks_unlocked => return evalPerksUnlocked(r, ctx),
        .is_stat_at_max => return evalIsStatAtMax(r, ctx),
        .in_safe_zone => return evalInSafeZone(r),
        .group_and => return evalList(r.children, false, ctx, counts),
        .group_or => return evalList(r.children, true, ctx, counts),
    }
}

/// AND over one row's gates (`RequirementGroup::EvalAnd`, the stock default).
/// Short-circuits on the first fail; an unsupported gate blocks the row and is
/// counted, so a gate the evaluator cannot resolve never passes.
pub fn evaluate(reqs: []const Requirement, ctx: Ctx, counts: *Counts) Verdict {
    return evalList(reqs, false, ctx, counts);
}

/// AND/OR over a node's children. `or` returns pass as soon as one child
/// passes, and only reports unsupported when nothing passed and some child was
/// unsupported (an unresolved gate must not turn an OR into a pass). An empty
/// group is `and` = pass, `or` = fail, like IL=66/IL=70.
fn evalList(reqs: []const Requirement, or_mode: bool, ctx: Ctx, counts: *Counts) Verdict {
    var unsupported = false;
    for (reqs) |r| {
        switch (evalOne(r, ctx, counts)) {
            .pass => if (or_mode) return .pass,
            .fail => if (!or_mode) return .fail,
            .unsupported => unsupported = true,
        }
    }
    if (unsupported) return .unsupported;
    // No child passed: an OR fails (also when it is empty, IL=70), an AND
    // passes (also when it is empty, IL=66).
    return if (or_mode) .fail else .pass;
}

/// Whether every gate passes, discarding the accounting.
pub fn all(reqs: []const Requirement, ctx: Ctx) bool {
    var counts: Counts = .{};
    return evaluate(reqs, ctx, &counts) == .pass;
}

/// End index (exclusive) of the element whose open tag starts at `open_at`,
/// including its close tag unless it is self-closing. Stock XML does not nest
/// same-name elements, so the first close tag ends it.
pub fn elementEnd(body: []const u8, open_at: usize) usize {
    const gt = std.mem.findPos(u8, body, open_at, ">") orelse return body.len;
    if (gt > open_at and body[gt - 1] == '/') return gt + 1;
    var name_end = open_at + 1;
    while (name_end < gt and !std.ascii.isWhitespace(body[name_end]) and
        body[name_end] != '/' and body[name_end] != '>') name_end += 1;
    const name = body[open_at + 1 .. name_end];
    if (name.len == 0 or name.len + 3 > 64) return gt + 1;
    var close_buf: [64]u8 = undefined;
    close_buf[0] = '<';
    close_buf[1] = '/';
    @memcpy(close_buf[2..][0..name.len], name);
    close_buf[2 + name.len] = '>';
    const close_tag = close_buf[0 .. name.len + 3];
    var open_buf: [64]u8 = undefined;
    open_buf[0] = '<';
    @memcpy(open_buf[1..][0..name.len], name);
    const open_tag = open_buf[0 .. name.len + 1];
    // Depth-aware: an element of the same name may nest inside itself
    // (`<requirement_group op="or">` does), and matching the first close tag
    // would end the outer element early and re-scan its children.
    var scan = gt;
    var depth: usize = 1;
    while (depth > 0) {
        const close = std.mem.findPos(u8, body, scan, close_tag) orelse return body.len;
        if (std.mem.findPos(u8, body, scan, open_tag)) |open| {
            if (open < close) {
                const after = open + open_tag.len;
                const delim = after < body.len and
                    (body[after] == '>' or body[after] == '/' or std.ascii.isWhitespace(body[after]));
                const inner_gt = std.mem.findPos(u8, body, open, ">") orelse return body.len;
                const empty = inner_gt > open and body[inner_gt - 1] == '/';
                if (delim and !empty) depth += 1;
                scan = if (inner_gt > open) inner_gt + 1 else after;
                continue;
            }
        }
        depth -= 1;
        scan = close + close_tag.len;
    }
    return scan;
}

/// The element's direct `<requirement>` children, in document order.
/// `RequirementBase::ParseRequirementGroup` (IL=148) reads
/// `Elements("requirement")`, i.e. direct children only: a requirement nested
/// in a triggered_effect or in a passive_effect is not a group gate.
pub fn scanRequirements(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    body: []const u8,
    open_at: usize,
    out: *std.ArrayList(Requirement),
) std.mem.Allocator.Error!void {
    const gt = std.mem.findPos(u8, body, open_at, ">") orelse return;
    if (gt > open_at and body[gt - 1] == '/') return;
    try scanChildren(allocator, arena, body, gt + 1, elementEnd(body, open_at), out);
}

/// The direct `<requirement>` / `<requirement_group>` children in `body[start..end)`,
/// in document order. `MinEffectGroup::ParseXml` (IL=103) builds one
/// RequirementGroup from an element's direct children, so an `<effect_group>`
/// body is scanned with this range form.
pub fn scanChildren(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    body: []const u8,
    start: usize,
    end: usize,
    out: *std.ArrayList(Requirement),
) std.mem.Allocator.Error!void {
    var i = start;
    while (i < end) {
        const lt = std.mem.findPos(u8, body[0..end], i, "<") orelse break;
        if (lt >= end or std.mem.startsWith(u8, body[lt..], "</")) break;
        if (std.mem.startsWith(u8, body[lt..], "<requirement_group")) {
            try out.append(allocator, try parseGroup(allocator, arena, body, lt));
        } else if (std.mem.startsWith(u8, body[lt..], "<requirement")) {
            try out.append(allocator, try parse(body, lt, arena));
        }
        i = elementEnd(body, lt);
    }
}

/// One `<requirement_group op="and|or">` with its direct children (gates and
/// nested groups). `RequirementGroup/Op` IL=?? is `{ And = 0, Or = 1 }`, and
/// `RequirementGroup::IsValid` IL=25 falls back to AND for any other value.
/// The group itself is a node in the flat AND list its parent evaluates.
pub fn parseGroup(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    hay: []const u8,
    tag_start: usize,
) std.mem.Allocator.Error!Requirement {
    const op = xml.attr(hay, tag_start, "op") orelse "and";
    var r: Requirement = .{
        .kind = if (std.ascii.eqlIgnoreCase(op, "or")) .group_or else .group_and,
        .name = if (std.ascii.eqlIgnoreCase(op, "or")) "requirement_group:or" else "requirement_group:and",
    };
    var kids: std.ArrayList(Requirement) = .empty;
    defer kids.deinit(allocator);
    try scanRequirements(allocator, arena, hay, tag_start, &kids);
    r.children = try arena.dupe(Requirement, kids.items);
    return r;
}

const testing = std.testing;

test "parse reads the negation, comparison, target and operands" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "<effect_group>" ++
        "<requirement name=\"!HasBuff\" buff=\"buffStatusHungry03,buffStatusThirsty03\"/>" ++
        "<requirement name=\"ProgressionLevel\" progression_name=\"perkFortitudeMastery\" operation=\"GTE\" value=\"1\"/>" ++
        "<requirement name=\"InBiome\" biome=\"8\"/>" ++
        "<requirement name=\"PlayerLevel\" operation=\"NotEquals\" value=\"3\" target=\"other\"/>" ++
        "</effect_group>";
    const b = std.mem.find(u8, src, "<requirement name=\"!HasBuff\"").?;
    const r = try parse(src, b, a);
    try testing.expectEqual(Kind.has_buff, r.kind);
    try testing.expect(r.negated);
    try testing.expectEqualStrings("HasBuff", r.name);
    try testing.expectEqualStrings("buffStatusHungry03,buffStatusThirsty03", r.list);
    const p = std.mem.find(u8, src, "<requirement name=\"ProgressionLevel\"").?;
    const rp = try parse(src, p, a);
    try testing.expectEqual(Kind.progression_level, rp.kind);
    try testing.expectEqual(Compare.ge, rp.op);
    try testing.expectEqualStrings("perkFortitudeMastery", rp.arg);
    try testing.expectEqual(@as(f32, 1), rp.value);
    const i = std.mem.find(u8, src, "<requirement name=\"InBiome\"").?;
    try testing.expectEqual(@as(i32, 8), (try parse(src, i, a)).num);
    const t = std.mem.find(u8, src, "<requirement name=\"PlayerLevel\"").?;
    const rt = try parse(src, t, a);
    try testing.expectEqual(Compare.ne, rt.op);
    try testing.expectEqual(Target.other, rt.target);
    // `option=` and `has_all_tags=` land on the fields the new kinds read.
    const sandbox_src = "<effect_group><requirement name=\"SandboxOptionBool\" option=\"NewbieCoat\"/>" ++
        "<requirement name=\"HoldingItemHasTags\" tags=\"a,b\" has_all_tags=\"true\"/></effect_group>";
    const sb = std.mem.find(u8, sandbox_src, "<requirement name=\"SandboxOptionBool\"").?;
    const rsb = try parse(sandbox_src, sb, a);
    try testing.expectEqual(Kind.sandbox_option_bool, rsb.kind);
    try testing.expectEqualStrings("NewbieCoat", rsb.arg);
    const hh = std.mem.find(u8, sandbox_src, "<requirement name=\"HoldingItemHasTags\"").?;
    const rhh = try parse(sandbox_src, hh, a);
    try testing.expectEqual(Kind.holding_item_has_tags, rhh.kind);
    try testing.expectEqualStrings("a,b", rhh.list);
    try testing.expect(rhh.has_all);
}

test "HoldingItemHasTags matches the held item's tags" {
    const any = Requirement{ .kind = .holding_item_has_tags, .list = "perkDeadEye,perkBrawler" };
    const all_tags = Requirement{ .kind = .holding_item_has_tags, .list = "perkDeadEye,gun", .has_all = true };
    const neg = Requirement{ .kind = .holding_item_has_tags, .negated = true, .list = "perkDeadEye" };
    // An empty hand carries no tags: any-of false, all-of false, negation true.
    try testing.expect(!all(&.{any}, .{}));
    try testing.expect(!all(&.{all_tags}, .{}));
    try testing.expect(all(&.{neg}, .{}));
    const ctx = Ctx{ .held_tags = "T0,perkDeadEye,gun" };
    try testing.expect(all(&.{any}, ctx));
    try testing.expect(all(&.{all_tags}, ctx));
    try testing.expect(!all(&.{neg}, ctx));
    // all-of fails when one listed tag is missing.
    try testing.expect(!all(&.{.{ .kind = .holding_item_has_tags, .list = "perkDeadEye,axe", .has_all = true }}, ctx));
    // A tag is a whole segment, not a substring.
    try testing.expect(!all(&.{.{ .kind = .holding_item_has_tags, .list = "perkDead" }}, ctx));
    try testing.expect(all(&.{.{ .kind = .holding_item_has_tags, .list = " gun , T0 " }}, ctx));
}

test "ItemHasTags matches params.ItemValue class tags" {
    const any = Requirement{ .kind = .item_has_tags, .list = "perkGunslinger,melee" };
    const all_tags = Requirement{ .kind = .item_has_tags, .list = "perkGunslinger,gun", .has_all = true };
    const neg = Requirement{ .kind = .item_has_tags, .negated = true, .list = "perkGunslinger" };
    // No ItemValue in scope (buff/perk fold): refuse closed.
    try testing.expect(!all(&.{any}, .{}));
    try testing.expect(!all(&.{all_tags}, .{}));
    try testing.expect(!all(&.{neg}, .{}));
    // Empty ItemValue / unknown class: fail (IL returns false before invert).
    const empty = Ctx{ .item_tags = "" };
    try testing.expect(!all(&.{any}, empty));
    try testing.expect(!all(&.{all_tags}, empty));
    try testing.expect(all(&.{neg}, empty));
    const ctx = Ctx{ .item_tags = "T0,perkGunslinger,gun" };
    try testing.expect(all(&.{any}, ctx));
    try testing.expect(all(&.{all_tags}, ctx));
    try testing.expect(!all(&.{neg}, ctx));
    try testing.expect(!all(&.{.{ .kind = .item_has_tags, .list = "perkGunslinger,axe", .has_all = true }}, ctx));
    try testing.expect(!all(&.{.{ .kind = .item_has_tags, .list = "perkGun" }}, ctx));
}

test "RequirementItemTier compares params.ItemValue.Quality" {
    const eq = Requirement{ .kind = .requirement_item_tier, .op = .eq, .value = 3 };
    const gte = Requirement{ .kind = .requirement_item_tier, .op = .ge, .value = 2 };
    const neg = Requirement{ .kind = .requirement_item_tier, .negated = true, .op = .eq, .value = 3 };
    // No ItemValue in scope (buff/perk fold): refuse closed.
    try testing.expect(!all(&.{eq}, .{}));
    const q0 = Ctx{ .item_quality = 0 };
    try testing.expect(!all(&.{eq}, q0));
    try testing.expect(all(&.{neg}, q0));
    const q3 = Ctx{ .item_quality = 3 };
    try testing.expect(all(&.{eq}, q3));
    try testing.expect(all(&.{gte}, q3));
    try testing.expect(!all(&.{neg}, q3));
}

test "RequirementItemModTier compares matching mod Quality" {
    const eq = Requirement{ .kind = .requirement_item_mod_tier, .op = .eq, .value = 2, .arg = "modGunCrippleEm" };
    const ge = Requirement{ .kind = .requirement_item_mod_tier, .op = .ge, .value = 2, .arg = "modGunCrippleEm" };
    const miss = Requirement{ .kind = .requirement_item_mod_tier, .op = .eq, .value = 1, .arg = "modMissing" };
    // No ItemValue in scope: refuse closed.
    try testing.expect(!all(&.{eq}, .{}));
    const mods = [_]NameLevel{
        .{ .name = "modOther", .level = 6 },
        .{ .name = "modGunCrippleEm", .level = 2 },
    };
    const ctx = Ctx{ .item_mods = &mods };
    try testing.expect(all(&.{eq}, ctx));
    try testing.expect(all(&.{ge}, ctx));
    try testing.expect(!all(&.{miss}, ctx));
    // Case-insensitive name match (stock EqualsCaseInsensitive).
    const ci = Requirement{ .kind = .requirement_item_mod_tier, .op = .eq, .value = 2, .arg = "MODGUNCRIPPLEEM" };
    try testing.expect(all(&.{ci}, ctx));
}

test "HitLocation matches DamageResponse.HitBodyPart" {
    const head = Requirement{ .kind = .hit_location, .body_parts = 2 };
    const legs = Requirement{ .kind = .hit_location, .body_parts = 16 | 32 | 256 | 512 };
    const neg = Requirement{ .kind = .hit_location, .negated = true, .body_parts = 2 };
    try testing.expect(!all(&.{head}, .{})); // no damage fold
    const h = Ctx{ .hit_body_part = 2 };
    try testing.expect(all(&.{head}, h));
    try testing.expect(!all(&.{legs}, h));
    try testing.expect(!all(&.{neg}, h));
    const l = Ctx{ .hit_body_part = 16 };
    try testing.expect(all(&.{legs}, l));
    try testing.expect(!all(&.{head}, l));
    try testing.expectEqual(@as(i32, 2), parseBodyParts("Head"));
    try testing.expectEqual(@as(i32, 816), parseBodyParts("LeftUpperLeg,RightUpperLeg,LeftLowerLeg,RightLowerLeg"));
    try testing.expectEqual(@as(i32, 816), parseBodyParts("xxleg"));
    try testing.expectEqual(@as(i32, 1024), parseBodyParts("secondary"));
}

test "ArmorGroupLowestQuality reads the worn group's lowest quality" {
    const req = Requirement{ .kind = .armor_group_lowest_quality, .arg = "groupBiker", .op = .eq, .value = 3 };
    const groups = [_]ArmorGroup{
        .{ .name = "groupBiker", .quality = 3 },
        .{ .name = "groupWinter", .quality = 6 },
    };
    const ctx = Ctx{ .armor_groups = &groups };
    try testing.expect(all(&.{req}, ctx));
    // A group that is not worn reads 0, exactly like
    // Equipment.GetArmorGroupLowestQuality's missing-key branch.
    const missing = Requirement{ .kind = .armor_group_lowest_quality, .arg = "groupNomad", .op = .eq, .value = 3 };
    try testing.expect(!all(&.{missing}, ctx));
    const zero = Requirement{ .kind = .armor_group_lowest_quality, .arg = "groupNomad", .op = .eq, .value = 0 };
    try testing.expect(all(&.{zero}, ctx));
    // Ordering works through the shared comparison table.
    const gte5 = Requirement{ .kind = .armor_group_lowest_quality, .arg = "groupWinter", .op = .ge, .value = 5 };
    try testing.expect(all(&.{gte5}, ctx));
    const gte6 = Requirement{ .kind = .armor_group_lowest_quality, .arg = "groupWinter", .op = .ge, .value = 6 };
    try testing.expect(all(&.{gte6}, ctx));
    const gte7 = Requirement{ .kind = .armor_group_lowest_quality, .arg = "groupWinter", .op = .ge, .value = 7 };
    try testing.expect(!all(&.{gte7}, ctx));
}

test "StatCompareCurrent reads the stat's absolute value" {
    // StatCompareCurrent IL=52 compares the current value, unlike
    // StatComparePercCurrentToMax which compares a fraction of max.
    const ctx = Ctx{ .hp_frac = 0.5, .hp_max = 200, .water_frac = 1, .water_max = 100 };
    const hp_lte_100 = Requirement{ .kind = .stat_compare_current, .name = "StatCompareCurrent", .arg = "Health", .op = .le, .value = 100 };
    const hp_lte_99 = Requirement{ .kind = .stat_compare_current, .name = "StatCompareCurrent", .arg = "Health", .op = .le, .value = 99 };
    try testing.expect(all(&.{hp_lte_100}, ctx));
    try testing.expect(!all(&.{hp_lte_99}, ctx));
    // Names are case-insensitive like the other stat gates.
    const water = Requirement{ .kind = .stat_compare_current, .name = "StatCompareCurrent", .arg = "water", .op = .ge, .value = 100 };
    try testing.expect(all(&.{water}, ctx));
    // An @cvar operand is resolved (round 29).
    var vars: cvars.Set = .{};
    _ = vars.apply("$thirst", .set, 100);
    try testing.expect(all(&.{water}, .{ .water_frac = 1, .water_max = 100, .cvars = &vars }));
    // The Armor branch reads the worn-armour rating (IL=52 StatType 5,
    // Equipment::GetTotalPhysicalArmorRating), which the VM fold produces.
    var counts: Counts = .{};
    const armor_low = Requirement{ .kind = .stat_compare_current, .name = "StatCompareCurrent", .arg = "Armor", .op = .le, .value = 0.25 };
    try testing.expect(all(&.{armor_low}, .{ .armor_rating = 0 }));
    try testing.expect(!all(&.{armor_low}, .{ .armor_rating = 0.5 }));
    // A stat the ctx cannot read is still refused rather than guessed.
    const stamina_none = Requirement{ .kind = .stat_compare_current, .name = "StatCompareCurrent", .arg = "Speed", .op = .le, .value = 1 };
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{stamina_none}, ctx, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
}

test "StatCompare max family separates Stat::Max from Stat::ModifiedMax" {
    // Stat IL: get_Max() = m_baseMax, get_ModifiedMax() = m_baseMax +
    // m_maxModifier, get_ModifiedMaxPercent() = ModifiedMax / Max. The ctx
    // carries both (`hp_base_max` = the pre-VM base, `hp_max` = the value the
    // passive VM recomputes). 100 base + 100 modifier at half health:
    const ctx = Ctx{ .hp_frac = 0.5, .hp_max = 200, .hp_base_max = 100 };
    const perc_max = Requirement{ .kind = .stat_compare_perc_current_to_max, .name = "StatComparePercCurrentToMax", .arg = "Health", .op = .eq, .value = 1 };
    try testing.expect(all(&.{perc_max}, ctx));
    const perc_max_lt = Requirement{ .kind = .stat_compare_perc_current_to_max, .name = "StatComparePercCurrentToMax", .arg = "Health", .op = .lt, .value = 1 };
    try testing.expect(!all(&.{perc_max_lt}, ctx));
    const perc_mod = Requirement{ .kind = .stat_compare_perc_current_to_mod_max, .name = "StatComparePercCurrentToModMax", .arg = "Health", .op = .eq, .value = 0.5 };
    try testing.expect(all(&.{perc_mod}, ctx));
    const mod_max = Requirement{ .kind = .stat_compare_mod_max, .name = "StatCompareModMax", .arg = "Health", .op = .eq, .value = 200 };
    try testing.expect(all(&.{mod_max}, ctx));
    const base_max = Requirement{ .kind = .stat_compare_max, .name = "StatCompareMax", .arg = "Health", .op = .eq, .value = 100 };
    try testing.expect(all(&.{base_max}, ctx));
    // ModifiedMaxPercent = 200/100 = 2 (the buffs.xml health-stage ladder gates
    // on `StatComparePercModMaxToMax Health LT 0.9`).
    const max_percent = Requirement{ .kind = .stat_compare_perc_mod_max_to_max, .name = "StatComparePercModMaxToMax", .arg = "Health", .op = .eq, .value = 2 };
    try testing.expect(all(&.{max_percent}, ctx));
    const max_percent_lt = Requirement{ .kind = .stat_compare_perc_mod_max_to_max, .name = "StatComparePercModMaxToMax", .arg = "Health", .op = .lt, .value = 0.9 };
    try testing.expect(!all(&.{max_percent_lt}, ctx));
    // The IL's zero guard: a non-positive denominator fails both polarities
    // (PercCurrentToMax/PercCurrentToModMax return false before `invert`).
    const zero = Ctx{ .hp_frac = 0.5, .hp_max = 0, .hp_base_max = 0 };
    const perc_max_neg = Requirement{ .kind = .stat_compare_perc_current_to_max, .name = "StatComparePercCurrentToMax", .arg = "Health", .op = .eq, .value = 1, .negated = true };
    const perc_mod_neg = Requirement{ .kind = .stat_compare_perc_current_to_mod_max, .name = "StatComparePercCurrentToModMax", .arg = "Health", .op = .eq, .value = 0.5, .negated = true };
    try testing.expect(!all(&.{perc_max_neg}, zero));
    try testing.expect(!all(&.{perc_mod_neg}, zero));
    // A caller with no base max keeps the pre-VM approximation (the modified
    // max) instead of turning the row off; a stat the ctx cannot read is
    // refused, and StatCompareMax refuses rather than comparing a fabricated 0.
    const perc_max_half = Requirement{ .kind = .stat_compare_perc_current_to_max, .name = "StatComparePercCurrentToMax", .arg = "Health", .op = .eq, .value = 0.5 };
    try testing.expect(all(&.{perc_max_half}, .{ .hp_frac = 0.5, .hp_max = 200 }));
    var counts: Counts = .{};
    const other = Requirement{ .kind = .stat_compare_perc_current_to_mod_max, .name = "StatComparePercCurrentToModMax", .arg = "Speed", .op = .lt, .value = 1 };
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{other}, ctx, &counts));
    const no_base = Requirement{ .kind = .stat_compare_max, .name = "StatCompareMax", .arg = "Health", .op = .eq, .value = 100 };
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{no_base}, .{ .hp_max = 200 }, &counts));
    try testing.expectEqual(@as(u32, 2), counts.unsupported);
}

test "EntityTagCompare matches the entity's own class Tags" {
    // EntityTagCompare IL=43: target.HasAnyTags (any-of) / HasAllTags with
    // has_all_tags, invert-aware. The default target is self (targetType 0),
    // and the ctx's `entity_tags` is the entityclasses.xml `Tags` set.
    const ctx = Ctx{ .entity_tags = "entity,player,human" };
    const player = Requirement{ .kind = .entity_tag_compare, .name = "EntityTagCompare", .list = "player" };
    try testing.expect(all(&.{player}, ctx));
    const zombie = Requirement{ .kind = .entity_tag_compare, .name = "EntityTagCompare", .list = "zombie" };
    try testing.expect(!all(&.{zombie}, ctx));
    // The invert spelling stock uses for the non-player half of a pair
    // (buffBurningFlamingArrow ships both variants).
    const not_zombie = Requirement{ .kind = .entity_tag_compare, .name = "EntityTagCompare", .list = "zombie", .negated = true };
    try testing.expect(all(&.{not_zombie}, ctx));
    // Any-of is the default, `has_all_tags` demands every tag.
    const any = Requirement{ .kind = .entity_tag_compare, .name = "EntityTagCompare", .list = "zombie,human" };
    try testing.expect(all(&.{any}, ctx));
    const every = Requirement{ .kind = .entity_tag_compare, .name = "EntityTagCompare", .list = "entity,human", .has_all = true };
    try testing.expect(all(&.{every}, ctx));
    const all_miss = Requirement{ .kind = .entity_tag_compare, .name = "EntityTagCompare", .list = "entity,zombie", .has_all = true };
    try testing.expect(!all(&.{all_miss}, ctx));
    // A ctx with no class tag set refuses (fail closed, counted) instead of
    // reading the entity as untagged; a foreign target is refused before the
    // dispatch because the tick ctx carries one entity.
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{player}, .{}, &counts));
    var foreign = player;
    foreign.target = .other;
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{foreign}, .{ .entity_tags = "entity" }, &counts));
    try testing.expectEqual(@as(u32, 2), counts.unsupported);
}

test "IsEquipped answers from the item fold's own context" {
    // IsEquipped IL=97: true when the row's ItemValue is in an equipment slot.
    // Only the item fold knows that, so a buff/perk fold (null) refuses.
    const eq = Requirement{ .kind = .is_equipped, .name = "IsEquipped" };
    try testing.expect(all(&.{eq}, .{ .item_equipped = true }));
    try testing.expect(!all(&.{eq}, .{ .item_equipped = false }));
    const negated = Requirement{ .kind = .is_equipped, .name = "IsEquipped", .negated = true };
    try testing.expect(all(&.{negated}, .{ .item_equipped = false }));
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{eq}, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
}

test "IsItemActive answers from the item fold and refuses without one" {
    // IsItemActive IL=29: Flags bit 0 (Activated) on params.ItemValue.
    // Only the item fold knows that, so a buff/perk fold (null) refuses.
    const active = Requirement{ .kind = .is_item_active, .name = "IsItemActive" };
    try testing.expect(all(&.{active}, .{ .item_active = true }));
    try testing.expect(!all(&.{active}, .{ .item_active = false }));
    const inverted = Requirement{ .kind = .is_item_active, .name = "IsItemActive", .negated = true };
    try testing.expect(all(&.{inverted}, .{ .item_active = false }));
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{active}, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
}

test "IsHeldItem is the inverse of item_equipped on the item fold" {
    // IsHeldItem IL=24: params.ItemValue == holdingItemStack.itemValue.
    // Item fold: held row item_equipped=false → held; equip row true → not held.
    const held = Requirement{ .kind = .is_held_item, .name = "IsHeldItem" };
    try testing.expect(all(&.{held}, .{ .item_equipped = false }));
    try testing.expect(!all(&.{held}, .{ .item_equipped = true }));
    const inverted = Requirement{ .kind = .is_held_item, .name = "IsHeldItem", .negated = true };
    try testing.expect(all(&.{inverted}, .{ .item_equipped = true }));
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{held}, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
}

test "IsInstigator answers from the damage fold and refuses without one" {
    // IsInstigator IL=17: target == params.Instigator.
    // Attacker fold → true; victim fold → false; no damage fold → refuse.
    const inst = Requirement{ .kind = .is_instigator, .name = "IsInstigator" };
    try testing.expect(all(&.{inst}, .{ .is_instigator = true }));
    try testing.expect(!all(&.{inst}, .{ .is_instigator = false }));
    const inverted = Requirement{ .kind = .is_instigator, .name = "IsInstigator", .negated = true };
    try testing.expect(all(&.{inverted}, .{ .is_instigator = false }));
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{inst}, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
}

test "EntityHasMovementTag matches the live movement tag set" {
    // EntityHasMovementTag IL=47: Test_AnySet by default, Test_AllSet with
    // has_all_tags, invert-aware. perkHardTarget's row is the shipped
    // `tags="walking,running"` one.
    const ctx = Ctx{ .movement_tags = "running" };
    const walking_or_running = Requirement{ .kind = .entity_has_movement_tag, .name = "EntityHasMovementTag", .list = "walking,running" };
    try testing.expect(all(&.{walking_or_running}, ctx));
    const idle = Requirement{ .kind = .entity_has_movement_tag, .name = "EntityHasMovementTag", .list = "idle" };
    try testing.expect(!all(&.{idle}, ctx));
    // The `!` spelling stock uses on the idle half of a pair.
    const not_idle = Requirement{ .kind = .entity_has_movement_tag, .name = "EntityHasMovementTag", .list = "idle", .negated = true };
    try testing.expect(all(&.{not_idle}, Ctx{ .movement_tags = "walking" }));
    // All-of demands every listed tag; a single-tag set cannot satisfy it.
    const every = Requirement{ .kind = .entity_has_movement_tag, .name = "EntityHasMovementTag", .list = "walking,running", .has_all = true };
    try testing.expect(!all(&.{every}, ctx));
    // A caller with no movement state refuses instead of guessing a tag.
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{walking_or_running}, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
}

test "IsNight reads the clock and refuses without one" {
    // IsNight IL=19: !World.IsDaytime(), invert-aware.
    const night = Requirement{ .kind = .is_night, .name = "IsNight" };
    try testing.expect(all(&.{night}, .{ .is_night = true }));
    try testing.expect(!all(&.{night}, .{ .is_night = false }));
    const inverted = Requirement{ .kind = .is_night, .name = "IsNight", .negated = true };
    try testing.expect(all(&.{inverted}, .{ .is_night = false }));
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{night}, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
}

test "IsDay reads the clock and refuses without one" {
    const day = Requirement{ .kind = .is_day, .name = "IsDay" };
    try testing.expect(all(&.{day}, .{ .is_day = true }));
    try testing.expect(!all(&.{day}, .{ .is_day = false }));
    const inverted = Requirement{ .kind = .is_day, .name = "IsDay", .negated = true };
    try testing.expect(all(&.{inverted}, .{ .is_day = false }));
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{day}, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
}

test "IsMale reads gender and refuses without identity" {
    const male = Requirement{ .kind = .is_male, .name = "IsMale" };
    try testing.expect(all(&.{male}, .{ .is_male = true }));
    try testing.expect(!all(&.{male}, .{ .is_male = false }));
    const inverted = Requirement{ .kind = .is_male, .name = "IsMale", .negated = true };
    try testing.expect(all(&.{inverted}, .{ .is_male = false }));
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{male}, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
}

test "IsCorpse reads corpse dwell and refuses without health" {
    const corpse = Requirement{ .kind = .is_corpse, .name = "IsCorpse" };
    try testing.expect(all(&.{corpse}, .{ .is_corpse = true }));
    try testing.expect(!all(&.{corpse}, .{ .is_corpse = false }));
    const inverted = Requirement{ .kind = .is_corpse, .name = "IsCorpse", .negated = true };
    try testing.expect(all(&.{inverted}, .{ .is_corpse = false }));
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{corpse}, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
}

test "IsSleeping reads sleeper state and refuses without fold" {
    const sleeping = Requirement{ .kind = .is_sleeping, .name = "IsSleeping" };
    try testing.expect(all(&.{sleeping}, .{ .is_sleeping = true }));
    try testing.expect(!all(&.{sleeping}, .{ .is_sleeping = false }));
    const inverted = Requirement{ .kind = .is_sleeping, .name = "IsSleeping", .negated = true };
    try testing.expect(all(&.{inverted}, .{ .is_sleeping = false }));
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{sleeping}, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
}

test "IsLocalPlayer is false on dedi and refuses without fold" {
    const local = Requirement{ .kind = .is_local_player, .name = "IsLocalPlayer" };
    try testing.expect(!all(&.{local}, .{ .is_local_player = false }));
    try testing.expect(all(&.{local}, .{ .is_local_player = true }));
    const inverted = Requirement{ .kind = .is_local_player, .name = "IsLocalPlayer", .negated = true };
    try testing.expect(all(&.{inverted}, .{ .is_local_player = false }));
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{local}, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
}

test "IsFPV is false on dedi and refuses without fold" {
    const fpv = Requirement{ .kind = .is_fpv, .name = "IsFPV" };
    try testing.expect(!all(&.{fpv}, .{ .is_fpv = false }));
    try testing.expect(all(&.{fpv}, .{ .is_fpv = true }));
    const inverted = Requirement{ .kind = .is_fpv, .name = "IsFPV", .negated = true };
    try testing.expect(all(&.{inverted}, .{ .is_fpv = false }));
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{fpv}, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
}

test "IsSheltered is false on dedi and refuses without fold" {
    const sheltered = Requirement{ .kind = .is_sheltered, .name = "IsSheltered" };
    try testing.expect(!all(&.{sheltered}, .{ .is_sheltered = false }));
    try testing.expect(all(&.{sheltered}, .{ .is_sheltered = true }));
    const inverted = Requirement{ .kind = .is_sheltered, .name = "IsSheltered", .negated = true };
    try testing.expect(all(&.{inverted}, .{ .is_sheltered = false }));
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{sheltered}, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
}

test "IsSDCS is false on dedi and refuses without fold" {
    const sdcs = Requirement{ .kind = .is_sdcs, .name = "IsSDCS" };
    try testing.expect(!all(&.{sdcs}, .{ .is_sdcs = false }));
    try testing.expect(all(&.{sdcs}, .{ .is_sdcs = true }));
    const inverted = Requirement{ .kind = .is_sdcs, .name = "IsSDCS", .negated = true };
    try testing.expect(all(&.{inverted}, .{ .is_sdcs = false }));
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{sdcs}, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
}

test "IsAlly is false on dedi and refuses without fold" {
    const ally = Requirement{ .kind = .is_ally, .name = "IsAlly" };
    try testing.expect(!all(&.{ally}, .{ .is_ally = false }));
    try testing.expect(all(&.{ally}, .{ .is_ally = true }));
    const inverted = Requirement{ .kind = .is_ally, .name = "IsAlly", .negated = true };
    try testing.expect(all(&.{inverted}, .{ .is_ally = false }));
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{ally}, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
}

test "IsOnLadder is false without elevator state and refuses without fold" {
    const ladder = Requirement{ .kind = .is_on_ladder, .name = "IsOnLadder" };
    try testing.expect(!all(&.{ladder}, .{ .is_on_ladder = false }));
    try testing.expect(all(&.{ladder}, .{ .is_on_ladder = true }));
    const inverted = Requirement{ .kind = .is_on_ladder, .name = "IsOnLadder", .negated = true };
    try testing.expect(all(&.{inverted}, .{ .is_on_ladder = false }));
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{ladder}, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
}

test "HasAttachedPrefab is false on dedi and refuses without fold" {
    const prefab = Requirement{ .kind = .has_attached_prefab, .name = "HasAttachedPrefab" };
    try testing.expect(!all(&.{prefab}, .{ .has_attached_prefab = false }));
    try testing.expect(all(&.{prefab}, .{ .has_attached_prefab = true }));
    const inverted = Requirement{ .kind = .has_attached_prefab, .name = "HasAttachedPrefab", .negated = true };
    try testing.expect(all(&.{inverted}, .{ .has_attached_prefab = false }));
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{prefab}, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
}

test "HasParticle is false on dedi and refuses without fold" {
    const particle = Requirement{ .kind = .has_particle, .name = "HasParticle" };
    try testing.expect(!all(&.{particle}, .{ .has_particle = false }));
    try testing.expect(all(&.{particle}, .{ .has_particle = true }));
    const inverted = Requirement{ .kind = .has_particle, .name = "HasParticle", .negated = true };
    try testing.expect(all(&.{inverted}, .{ .has_particle = false }));
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{particle}, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
}

test "IsLookingAtBlock is true per stock stub and refuses without fold" {
    const looking = Requirement{ .kind = .is_looking_at_block, .name = "IsLookingAtBlock" };
    try testing.expect(all(&.{looking}, .{ .is_looking_at_block = true }));
    try testing.expect(!all(&.{looking}, .{ .is_looking_at_block = false }));
    const inverted = Requirement{ .kind = .is_looking_at_block, .name = "IsLookingAtBlock", .negated = true };
    try testing.expect(!all(&.{inverted}, .{ .is_looking_at_block = true }));
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{looking}, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
}

test "IsLookingAtEntity is true per stock stub and refuses without fold" {
    const looking = Requirement{ .kind = .is_looking_at_entity, .name = "IsLookingAtEntity" };
    try testing.expect(all(&.{looking}, .{ .is_looking_at_entity = true }));
    try testing.expect(!all(&.{looking}, .{ .is_looking_at_entity = false }));
    const inverted = Requirement{ .kind = .is_looking_at_entity, .name = "IsLookingAtEntity", .negated = true };
    try testing.expect(!all(&.{inverted}, .{ .is_looking_at_entity = true }));
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{looking}, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
}

test "IsIndoors is false without enclosure and refuses without fold" {
    const indoors = Requirement{ .kind = .is_indoors, .name = "IsIndoors" };
    try testing.expect(!all(&.{indoors}, .{ .is_indoors = false }));
    try testing.expect(all(&.{indoors}, .{ .is_indoors = true }));
    const inverted = Requirement{ .kind = .is_indoors, .name = "IsIndoors", .negated = true };
    try testing.expect(all(&.{inverted}, .{ .is_indoors = false }));
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{indoors}, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
}

test "IsBloodMoon reads the blood-moon clock and refuses without one" {
    const bm = Requirement{ .kind = .is_blood_moon, .name = "IsBloodMoon" };
    try testing.expect(all(&.{bm}, .{ .is_blood_moon = true }));
    try testing.expect(!all(&.{bm}, .{ .is_blood_moon = false }));
    const inverted = Requirement{ .kind = .is_blood_moon, .name = "IsBloodMoon", .negated = true };
    try testing.expect(all(&.{inverted}, .{ .is_blood_moon = false }));
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{bm}, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
}

test "HoldingItemBroken reads held durability and refuses without inventory" {
    // HoldingItemBroken: PercentUsesLeft == 0 (UseTimes >= MaxUseTimes).
    const brk = Requirement{ .kind = .holding_item_broken, .name = "HoldingItemBroken" };
    try testing.expect(all(&.{brk}, .{ .holding_item_broken = true }));
    try testing.expect(!all(&.{brk}, .{ .holding_item_broken = false }));
    const inverted = Requirement{ .kind = .holding_item_broken, .name = "HoldingItemBroken", .negated = true };
    try testing.expect(all(&.{inverted}, .{ .holding_item_broken = false }));
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{brk}, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
}

test "the new gate kinds parse from the stock attribute spellings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        "<effect_group>" ++
        "<requirement name=\"EntityTagCompare\" tags=\"player\" has_all_tags=\"true\"/>" ++
        "<requirement name=\"!IsNight\"/>" ++
        "<requirement name=\"StatComparePercCurrentToModMax\" stat=\"health\" operation=\"LTE\" value=\"0.5\"/>" ++
        "</effect_group>";
    var at: usize = 0;
    var seen: usize = 0;
    while (std.mem.findPos(u8, src, at, "<requirement")) |tag| {
        at = tag + 12;
        const r = try parse(src, tag, arena.allocator());
        switch (seen) {
            0 => {
                try testing.expectEqual(Kind.entity_tag_compare, r.kind);
                try testing.expectEqualStrings("player", r.list);
                try testing.expect(r.has_all);
            },
            1 => {
                try testing.expectEqual(Kind.is_night, r.kind);
                try testing.expect(r.negated);
            },
            else => {
                try testing.expectEqual(Kind.stat_compare_perc_current_to_mod_max, r.kind);
                try testing.expectEqual(Compare.le, r.op);
                try testing.expectEqual(@as(f32, 0.5), r.value);
                try testing.expectEqualStrings("health", r.arg);
            },
        }
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 3), seen);
}

test "a value=\"@cvar\" operand is read live, not parsed as 0" { // buffLevelUpTracking gates its `add $LastPlayerLevel 1` row on
    // `PlayerLevel GT value="@$LastPlayerLevel"`. Parsing that operand as 0 made
    // the guard always pass, so the counter climbed on every 0.1 s update.
    var vars: cvars.Set = .{};
    const src = "<effect_group><requirement name=\"PlayerLevel\" operation=\"GT\" value=\"@$LastPlayerLevel\"/></effect_group>";
    const tag = std.mem.find(u8, src, "<requirement").?;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try parse(src, tag, arena.allocator());
    try testing.expectEqualStrings("$LastPlayerLevel", r.value_cvar);
    try testing.expectEqual(@as(f32, 0), r.value);
    const ctx0 = Ctx{ .player_level = 1, .cvars = &vars };
    // Level 1 vs an unset counter (0): passes.
    try testing.expect(all(&.{r}, ctx0));
    _ = vars.apply("$LastPlayerLevel", .set, 1);
    // Level 1 vs the counter at 1: the guard closes.
    try testing.expect(!all(&.{r}, ctx0));
    const ctx5 = Ctx{ .player_level = 5, .cvars = &vars };
    try testing.expect(all(&.{r}, ctx5));
    // The other comparison kinds take the same operand path.
    const worn = Requirement{ .kind = .worn_items, .name = "WornItems", .list = "lightArmor", .op = .eq, .value_cvar = ".wornTarget" };
    var wornvars: cvars.Set = .{};
    _ = wornvars.apply(".wornTarget", .set, 0);
    try testing.expect(all(&.{worn}, .{ .cvars = &wornvars }));
    _ = wornvars.apply(".wornTarget", .set, 2);
    const two = Ctx{ .cvars = &wornvars, .worn_items = &.{ "a,lightArmor", "b,lightArmor" } };
    try testing.expect(all(&.{worn}, two));
    _ = wornvars.apply(".wornTarget", .set, 3);
    try testing.expect(!all(&.{worn}, two));
}

test "WornItems counts the slots whose item carries any of the row's tags" {
    // WornItems IL=54: Equipment::GetSlotCount walk, each item's
    // ItemClass::HasAnyTags(equipmentTags), compared with the shared table.
    const worn = [_][]const u8{
        "head,armor,armorHead,lightArmor,lightArmorDeg",
        "upperbody,chest,armor,armorChest,lightArmor,lightArmorDeg",
        "lowerbody,feet,armor,armorFeet,heavyArmor",
        "hands,armor",
    };
    const ctx = Ctx{ .worn_items = &worn };
    // Any-of on the row's tags, not all-of.
    const light4 = Requirement{ .kind = .worn_items, .name = "WornItems", .list = "lightArmor", .op = .eq, .value = 4 };
    try testing.expect(!all(&.{light4}, ctx));
    const light2 = Requirement{ .kind = .worn_items, .name = "WornItems", .list = "lightArmor", .op = .eq, .value = 2 };
    try testing.expect(all(&.{light2}, ctx));
    // A two-tag list counts a slot once even when it carries both.
    const light_or_heavy = Requirement{ .kind = .worn_items, .name = "WornItems", .list = "lightArmor,heavyArmor", .op = .eq, .value = 3 };
    try testing.expect(all(&.{light_or_heavy}, ctx));
    // Ordering and negation go through the same comparison table.
    const gte3 = Requirement{ .kind = .worn_items, .name = "WornItems", .list = "armor", .op = .ge, .value = 3 };
    try testing.expect(all(&.{gte3}, ctx));
    const not_light = Requirement{ .kind = .worn_items, .name = "WornItems", .list = "lightArmor", .op = .gt, .value = 0, .negated = true };
    try testing.expect(!all(&.{not_light}, ctx));
    // Nothing worn: the count is 0.
    const none = Requirement{ .kind = .worn_items, .name = "WornItems", .list = "lightArmor", .op = .eq, .value = 0 };
    try testing.expect(all(&.{none}, .{}));
}

test "CVarCompare reads the entity's custom variables, missing as 0" {
    var vars: cvars.Set = .{};
    _ = vars.apply(".ArmorLightWorn", .set, 4);
    _ = vars.apply("$bleedAmount", .set, -0.5);
    const ctx = Ctx{ .cvars = &vars };
    const four = Requirement{ .kind = .cvar_compare, .name = "CVarCompare", .arg = ".ArmorLightWorn", .op = .eq, .value = 4 };
    try testing.expect(all(&.{four}, ctx));
    // Names are case-insensitive and the operand can be negative.
    const bleeding = Requirement{ .kind = .cvar_compare, .name = "CVarCompare", .arg = "$BLEEDAMOUNT", .op = .lt, .value = 0 };
    try testing.expect(all(&.{bleeding}, ctx));
    // A missing name reads 0 (GetCustomVar IL=10).
    const missing_zero = Requirement{ .kind = .cvar_compare, .name = "CVarCompare", .arg = ".nope", .op = .eq, .value = 0 };
    try testing.expect(all(&.{missing_zero}, ctx));
    const missing_four = Requirement{ .kind = .cvar_compare, .name = "CVarCompare", .arg = ".nope", .op = .eq, .value = 4 };
    try testing.expect(!all(&.{missing_four}, ctx));
    // `!CVarCompare` inverts the comparison.
    const negated = Requirement{ .kind = .cvar_compare, .name = "CVarCompare", .arg = ".nope", .op = .eq, .value = 0, .negated = true };
    try testing.expect(!all(&.{negated}, ctx));
    try testing.expectApproxEqAbs(@as(f32, 4), cvarValue(ctx, ".ArmorLightWorn"), 0.0001);
}

test "ArmorGroupCount counts the worn pieces of the group, 0 when unworn" {
    const groups = [_]ArmorGroup{
        .{ .name = "groupBiker", .quality = 3, .count = 4 },
        .{ .name = "groupNomad", .quality = 5, .count = 2 },
    };
    const ctx = Ctx{ .armor_groups = &groups };
    // The armor-set rows are `Equals 4` (grant) and `LTE 3` (revoke).
    try testing.expect(all(&.{.{ .kind = .armor_group_count, .arg = "groupBiker", .op = .eq, .value = 4 }}, ctx));
    try testing.expect(!all(&.{.{ .kind = .armor_group_count, .arg = "groupNomad", .op = .eq, .value = 4 }}, ctx));
    try testing.expect(all(&.{.{ .kind = .armor_group_count, .arg = "groupNomad", .op = .le, .value = 3 }}, ctx));
    // An unworn group is 0, exactly like Equipment.GetArmorGroupCount.
    try testing.expect(all(&.{.{ .kind = .armor_group_count, .arg = "groupRogue", .op = .eq, .value = 0 }}, ctx));
    try testing.expect(!all(&.{.{ .kind = .armor_group_count, .arg = "groupRogue", .op = .eq, .value = 4 }}, ctx));
}

test "StatComparePercCurrentToMax reads the stat fraction against its max" {
    const water_lt_2 = Requirement{ .kind = .stat_compare_perc_current_to_max, .arg = "Water", .op = .le, .value = 0.02 };
    const ctx = Ctx{ .water_frac = 0.01, .water_max = 100 };
    try testing.expect(all(&.{water_lt_2}, ctx));
    const hydrated = Ctx{ .water_frac = 0.5, .water_max = 100 };
    try testing.expect(!all(&.{water_lt_2}, hydrated));
    // The stat name is case-insensitive (stock compares the enum's name).
    const health = Requirement{ .kind = .stat_compare_perc_current_to_max, .arg = "health", .op = .ge, .value = 0.5 };
    try testing.expect(all(&.{health}, .{ .hp_frac = 0.75, .hp_max = 100 }));
    // A max that is not positive fails in both polarities: the IL returns
    // false before it reads the negated flag, so the positive gate fails even
    // though its comparison holds, and a negated gate fails even though its
    // polarity would hold.
    const dry = Ctx{ .water_frac = 0.01, .water_max = 0 };
    try testing.expect(!all(&.{water_lt_2}, dry));
    const dry_negated = Requirement{ .kind = .stat_compare_perc_current_to_max, .arg = "Water", .op = .ge, .value = 0.5, .negated = true };
    try testing.expect(!all(&.{dry_negated}, dry));
    // A stat the shipped rows never use is an unsupported kind, not a guess.
    var counts: Counts = .{};
    const other = Requirement{ .kind = .stat_compare_perc_current_to_max, .arg = "Speed", .op = .le, .value = 0.5 };
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{other}, ctx, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
}

test "SandboxOptionBool reads the decoded option or its default" {
    const newbie = sandbox.optionByName("NewbieCoat").?;
    const req_on = Requirement{ .kind = .sandbox_option_bool, .arg = "NewbieCoat" };
    const req_off = Requirement{ .kind = .sandbox_option_bool, .arg = "NewbieCoat", .negated = true };
    // Not in the code: the option's census default (NewbieCoat is Yes).
    try testing.expect(all(&.{req_on}, .{}));
    try testing.expect(!all(&.{req_off}, .{}));
    // Code index 1 = Yes.
    const on = [_]sandbox.Group{.{ .option_id = newbie.id, .index = 1 }};
    try testing.expect(all(&.{req_on}, .{ .sandbox_groups = &on }));
    try testing.expect(!all(&.{req_off}, .{ .sandbox_groups = &on }));
    // Code index 0 = No even though the option default is Yes.
    const off = [_]sandbox.Group{.{ .option_id = newbie.id, .index = 0 }};
    try testing.expect(!all(&.{req_on}, .{ .sandbox_groups = &off }));
    try testing.expect(all(&.{req_off}, .{ .sandbox_groups = &off }));
    // An unknown option name refuses rather than guessing.
    var counts: Counts = .{};
    const unknown = Requirement{ .kind = .sandbox_option_bool, .arg = "NotAnOption" };
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{unknown}, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
}

test "GameStatBool reads BiomeProgression and refuses unknown or missing" {
    const req = Requirement{ .kind = .game_stat_bool, .name = "GameStatBool", .arg = "BiomeProgression" };
    try testing.expect(all(&.{req}, .{ .game_stat_biome_progression = true }));
    try testing.expect(!all(&.{req}, .{ .game_stat_biome_progression = false }));
    const inverted = Requirement{ .kind = .game_stat_bool, .name = "GameStatBool", .arg = "BiomeProgression", .negated = true };
    try testing.expect(all(&.{inverted}, .{ .game_stat_biome_progression = false }));
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{req}, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
    const unk = Requirement{ .kind = .game_stat_bool, .name = "GameStatBool", .arg = "NoSuchStat" };
    counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{unk}, .{ .game_stat_biome_progression = true }, &counts));
}

test "IsDayNumber compares WorldClock.day and refuses without clock" {
    const req = Requirement{ .kind = .is_day_number, .name = "IsDayNumber", .op = .ge, .value = 2 };
    try testing.expect(all(&.{req}, .{ .day_number = 2 }));
    try testing.expect(all(&.{req}, .{ .day_number = 5 }));
    try testing.expect(!all(&.{req}, .{ .day_number = 1 }));
    const eq = Requirement{ .kind = .is_day_number, .name = "IsDayNumber", .op = .eq, .value = 3 };
    try testing.expect(all(&.{eq}, .{ .day_number = 3 }));
    try testing.expect(!all(&.{eq}, .{ .day_number = 2 }));
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{req}, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
}

test "TimeOfDay compares within-day ticks against HHMM and refuses without clock" {
    // 1230 -> DayTimeToWorldTime(12,30,0) = 12000 + 500 = 12500
    const req = Requirement{ .kind = .time_of_day, .name = "TimeOfDay", .op = .ge, .value = 1230 };
    try testing.expect(all(&.{req}, .{ .time_of_day_ticks = 12500 }));
    try testing.expect(all(&.{req}, .{ .time_of_day_ticks = 13000 }));
    try testing.expect(!all(&.{req}, .{ .time_of_day_ticks = 12000 }));
    // 700 -> 7*1000 = 7000 (stock dawn-ish)
    const dawn = Requirement{ .kind = .time_of_day, .name = "TimeOfDay", .op = .eq, .value = 700 };
    try testing.expect(all(&.{dawn}, .{ .time_of_day_ticks = 7000 }));
    try testing.expect(!all(&.{dawn}, .{ .time_of_day_ticks = 7001 }));
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{req}, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
}

test "requirement_group evaluates with the stock AND/OR semantics" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "<effect_group>" ++
        "<requirement_group op=\"or\">" ++
        "<requirement name=\"InBiome\" biome=\"8\"/>" ++
        "<requirement name=\"PlayerLevel\" operation=\"GTE\" value=\"5\"/>" ++
        "<requirement_group op=\"and\">" ++
        "<requirement name=\"InBiome\" biome=\"2\"/>" ++
        "<requirement name=\"IsAlive\"/>" ++
        "</requirement_group>" ++
        "</requirement_group>" ++
        "</effect_group>";
    const g0 = std.mem.find(u8, src, "<effect_group").?;
    var out: std.ArrayList(Requirement) = .empty;
    defer out.deinit(testing.allocator);
    try scanRequirements(testing.allocator, a, src, g0, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    const g = out.items[0];
    try testing.expectEqual(Kind.group_or, g.kind);
    try testing.expectEqual(@as(usize, 3), g.children.len);
    try testing.expectEqual(Kind.group_and, g.children[2].kind);
    try testing.expectEqual(@as(usize, 2), g.children[2].children.len);
    // One passing child is enough for the OR.
    try testing.expect(all(&.{g}, .{ .player_level = 5 }));
    try testing.expect(all(&.{g}, .{ .biome_id = 8 }));
    // The nested AND needs both of its children.
    try testing.expect(!all(&.{g}, .{ .player_level = 4, .biome_id = 2, .alive = false }));
    try testing.expect(all(&.{g}, .{ .player_level = 4, .biome_id = 2, .alive = true }));
    // A gate the evaluator cannot resolve must not turn the OR into a pass.
    var counts: Counts = .{};
    const unresolved = Requirement{ .kind = .group_or, .name = "requirement_group:or", .children = &.{
        .{ .kind = .unsupported, .name = "Nope" },
    } };
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{unresolved}, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
    // An empty group is AND = pass, OR = fail (RequirementGroup IL=66/IL=70).
    const empty_and = Requirement{ .kind = .group_and, .name = "requirement_group:and", .children = &.{} };
    const empty_or = Requirement{ .kind = .group_or, .name = "requirement_group:or", .children = &.{} };
    try testing.expect(all(&.{empty_and}, .{}));
    try testing.expect(!all(&.{empty_or}, .{}));
    // A group with no `op` attribute is AND (RequirementGroup::IsValid IL=25
    // falls back to EvalAnd for every value but Or).
    const src_and = "<effect_group><requirement_group>" ++
        "<requirement name=\"InBiome\" biome=\"2\"/>" ++
        "<requirement name=\"PlayerLevel\" operation=\"GTE\" value=\"5\"/>" ++
        "</requirement_group></effect_group>";
    var out2: std.ArrayList(Requirement) = .empty;
    defer out2.deinit(testing.allocator);
    try scanRequirements(testing.allocator, a, src_and, 0, &out2);
    try testing.expectEqual(Kind.group_and, out2.items[0].kind);
    try testing.expect(!all(out2.items, .{ .biome_id = 2, .player_level = 4 }));
    try testing.expect(all(out2.items, .{ .biome_id = 2, .player_level = 5 }));
}

test "compare matches the six stock operation spellings" {
    // RequirementBase/OperationTypes is 18 names over 6 relations.
    try testing.expectEqual(Compare.eq, parseCompare("Equals"));
    try testing.expectEqual(Compare.eq, parseCompare("EQ"));
    try testing.expectEqual(Compare.eq, parseCompare("E"));
    try testing.expectEqual(Compare.ne, parseCompare("NotEquals"));
    try testing.expectEqual(Compare.ne, parseCompare("NE"));
    try testing.expectEqual(Compare.lt, parseCompare("LT"));
    try testing.expectEqual(Compare.lt, parseCompare("LessThan"));
    try testing.expectEqual(Compare.gt, parseCompare("gt"));
    try testing.expectEqual(Compare.gt, parseCompare("GreaterThan"));
    try testing.expectEqual(Compare.le, parseCompare("LTE"));
    try testing.expectEqual(Compare.le, parseCompare("LessThanOrEqualTo"));
    try testing.expectEqual(Compare.ge, parseCompare("GTE"));
    try testing.expectEqual(Compare.ge, parseCompare("GreaterOrEqual"));
    try testing.expect(compare(2, .ge, 2));
    try testing.expect(compare(2, .le, 2));
    try testing.expect(!compare(2, .gt, 2));
}

test "HasBuff reads the active set and its negations" {
    const Ids = struct {
        fn resolve(_: *const anyopaque, name: []const u8) ?u16 {
            if (std.mem.eql(u8, name, "buffShocked")) return 7;
            if (std.mem.eql(u8, name, "buffBleeding")) return 9;
            return null;
        }
    };
    const names = BuffNames{ .ctx = undefined, .resolve = Ids.resolve };
    const has = Requirement{ .kind = .has_buff, .list = "buffShocked" };
    const not_has = Requirement{ .kind = .has_buff, .negated = true, .list = "buffShocked,buffBleeding" };
    // No buffs at all: HasBuff is false and !HasBuff true without any catalog.
    const empty = Ctx{};
    try testing.expect(!all(&.{has}, empty));
    try testing.expect(all(&.{not_has}, empty));
    // One active buff, resolved through the catalog.
    const active = [_]u16{7};
    var ctx = Ctx{ .active_buffs = &active, .buff_names = &names };
    try testing.expect(all(&.{has}, ctx));
    try testing.expect(!all(&.{not_has}, ctx));
    // A non-empty set with no resolver cannot be decided: both polarities
    // refuse rather than guess.
    var counts: Counts = .{};
    ctx.buff_names = null;
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{has}, ctx, &counts));
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{not_has}, ctx, &counts));
    try testing.expectEqual(@as(u32, 0), counts.resolved);
    try testing.expectEqual(@as(u32, 2), counts.unsupported);
    // A name the catalog does not carry is not active: `HasBuff` on it is
    // false, and its negation true, even with another buff active.
    const active_other = [_]u16{9};
    const ctx2 = Ctx{ .active_buffs = &active_other, .buff_names = &names };
    const has_unknown = Requirement{ .kind = .has_buff, .list = "buffUnknown" };
    const not_unknown = Requirement{ .kind = .has_buff, .negated = true, .list = "buffUnknown" };
    try testing.expect(!all(&.{has_unknown}, ctx2));
    try testing.expect(all(&.{not_unknown}, ctx2));
    // buffBleeding (9) is active, so the list containing it matches.
    const has_bleeding = Requirement{ .kind = .has_buff, .list = "buffShocked,buffBleeding" };
    try testing.expect(all(&.{has_bleeding}, ctx2));
    try testing.expect(!all(&.{not_has}, ctx2));
}

test "ProgressionLevel resolves against the purchased ledger and fails closed" {
    const levels = [_]NameLevel{.{ .name = "perkFortitudeMastery", .level = 3 }};
    const ctx = Ctx{ .levels = &levels };
    const ge1 = Requirement{ .kind = .progression_level, .op = .ge, .value = 1, .arg = "perkFortitudeMastery" };
    const ge5 = Requirement{ .kind = .progression_level, .op = .ge, .value = 5, .arg = "perkFortitudeMastery" };
    try testing.expect(all(&.{ge1}, ctx));
    try testing.expect(!all(&.{ge5}, ctx));
    // An unknown progression_name is a resolved false, exactly like stock's
    // null ProgressionValue, in both polarities.
    const unknown = Requirement{ .kind = .progression_level, .op = .ge, .value = 1, .arg = "notAPerk" };
    const unknown_neg = Requirement{ .kind = .progression_level, .negated = true, .op = .ge, .value = 1, .arg = "notAPerk" };
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.fail, evaluate(&.{unknown}, ctx, &counts));
    try testing.expectEqual(Verdict.fail, evaluate(&.{unknown_neg}, ctx, &counts));
    try testing.expectEqual(@as(u32, 0), counts.unsupported);
}

test "ProgressionLevel target=instigator reads instigator_levels" {
    // Stock Physician heal buffs gate `$legTreatedCritHealingBase` on the
    // healer's perkPhysician via target="instigator". Without a supplier the
    // gate refuses; with instigator_levels it resolves against that ledger.
    const self_lv = [_]NameLevel{.{ .name = "perkPhysician", .level = 0 }};
    const heal_lv = [_]NameLevel{.{ .name = "perkPhysician", .level = 2 }};
    const gate = Requirement{
        .kind = .progression_level,
        .op = .eq,
        .value = 2,
        .arg = "perkPhysician",
        .target = .instigator,
    };
    var counts: Counts = .{};
    // No supplier → unsupported (not self).
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{gate}, .{ .levels = &self_lv }, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
    // Healer has perkPhysician 2 → pass.
    counts = .{};
    try testing.expectEqual(Verdict.pass, evaluate(&.{gate}, .{
        .levels = &self_lv,
        .instigator_levels = &heal_lv,
    }, &counts));
    try testing.expectEqual(@as(u32, 1), counts.resolved);
    // Healer missing the perk → fail closed.
    counts = .{};
    try testing.expectEqual(Verdict.fail, evaluate(&.{gate}, .{
        .levels = &self_lv,
        .instigator_levels = &[_]NameLevel{},
    }, &counts));
}

test "ProgressionLevel target=other reads other_levels" {
    // Stock entityclasses.xml gates EntityDamage on perkBatterUpMetalChain via
    // target="other". Without a supplier the gate refuses; with other_levels it
    // resolves against that ledger (not self).
    const self_lv = [_]NameLevel{.{ .name = "perkBatterUpMetalChain", .level = 0 }};
    const other_lv = [_]NameLevel{.{ .name = "perkBatterUpMetalChain", .level = 1 }};
    const gate = Requirement{
        .kind = .progression_level,
        .op = .eq,
        .value = 1,
        .arg = "perkBatterUpMetalChain",
        .target = .other,
    };
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{gate}, .{ .levels = &self_lv }, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
    counts = .{};
    try testing.expectEqual(Verdict.pass, evaluate(&.{gate}, .{
        .levels = &self_lv,
        .other_levels = &other_lv,
    }, &counts));
    try testing.expectEqual(@as(u32, 1), counts.resolved);
    counts = .{};
    try testing.expectEqual(Verdict.fail, evaluate(&.{gate}, .{
        .levels = &self_lv,
        .other_levels = &[_]NameLevel{},
    }, &counts));
}

test "IsAlive target=other reads other_alive" {
    // Stock damage rows gate on the other entity's alive bit via target="other".
    // Without a supplier the gate refuses; with other_alive it resolves that bit.
    const gate = Requirement{ .kind = .is_alive, .target = .other };
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{gate}, .{ .alive = true }, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
    counts = .{};
    try testing.expectEqual(Verdict.pass, evaluate(&.{gate}, .{ .alive = false, .other_alive = true }, &counts));
    try testing.expectEqual(@as(u32, 1), counts.resolved);
    counts = .{};
    try testing.expectEqual(Verdict.fail, evaluate(&.{gate}, .{ .alive = true, .other_alive = false }, &counts));
}

test "HasBuff target=other reads other_live_buff" {
    // Stock fire-proc rows gate AddBuff on HasBuff target="other". Without a
    // supplier the gate refuses; with other_live_buff + buff_active it resolves.
    const gate = Requirement{ .kind = .has_buff, .list = "buffBurningElement", .target = .other };
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{gate}, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);

    const Holder = struct {
        has_it: bool,
        fn has(ctx: *const anyopaque, name: []const u8) bool {
            const h: *const @This() = @ptrCast(@alignCast(ctx));
            _ = name;
            return h.has_it;
        }
    };
    var yes: Holder = .{ .has_it = true };
    var no: Holder = .{ .has_it = false };
    counts = .{};
    try testing.expectEqual(Verdict.pass, evaluate(&.{gate}, .{
        .buff_active = Holder.has,
        .other_live_buff = &yes,
    }, &counts));
    try testing.expectEqual(@as(u32, 1), counts.resolved);
    counts = .{};
    try testing.expectEqual(Verdict.fail, evaluate(&.{gate}, .{
        .buff_active = Holder.has,
        .other_live_buff = &no,
    }, &counts));
}

test "IsCorpse target=other reads other_is_corpse" {
    // Stock corpseRemoval effect_group gates on IsCorpse target="other".
    const gate = Requirement{ .kind = .is_corpse, .target = .other };
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{gate}, .{ .is_corpse = true }, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
    counts = .{};
    try testing.expectEqual(Verdict.pass, evaluate(&.{gate}, .{ .is_corpse = false, .other_is_corpse = true }, &counts));
    try testing.expectEqual(@as(u32, 1), counts.resolved);
    counts = .{};
    try testing.expectEqual(Verdict.fail, evaluate(&.{gate}, .{ .is_corpse = true, .other_is_corpse = false }, &counts));
}

test "IsSleeping target=other reads other_is_sleeping" {
    // Stock NightStalker SlumberParty gates on IsSleeping target="other".
    const gate = Requirement{ .kind = .is_sleeping, .target = .other };
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{gate}, .{ .is_sleeping = true }, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
    counts = .{};
    try testing.expectEqual(Verdict.pass, evaluate(&.{gate}, .{ .is_sleeping = false, .other_is_sleeping = true }, &counts));
    try testing.expectEqual(@as(u32, 1), counts.resolved);
    counts = .{};
    try testing.expectEqual(Verdict.fail, evaluate(&.{gate}, .{ .is_sleeping = true, .other_is_sleeping = false }, &counts));
}

test "InBiome needs a biome in the params for either polarity" {
    const in8 = Requirement{ .kind = .in_biome, .num = 8 };
    const not8 = Requirement{ .kind = .in_biome, .negated = true, .num = 8 };
    try testing.expect(all(&.{in8}, .{ .biome_id = 8 }));
    try testing.expect(!all(&.{in8}, .{ .biome_id = 9 }));
    try testing.expect(all(&.{not8}, .{ .biome_id = 9 }));
    // Null biome: stock returns false before reading invert, so the negated
    // form refuses too.
    try testing.expect(!all(&.{in8}, .{}));
    try testing.expect(!all(&.{not8}, .{}));
}

test "an unsupported kind or foreign target fails the gate and is counted" {
    const bogus = Requirement{ .kind = .unsupported, .name = "BogusGate" };
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{bogus}, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
    // A gate that passes does not mask a later unsupported one.
    const alive = Requirement{ .kind = .is_alive };
    counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{ alive, bogus }, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.resolved);
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
    // A failing gate short-circuits before the unsupported one.
    counts = .{};
    try testing.expectEqual(Verdict.fail, evaluate(&.{ alive, bogus }, .{ .alive = false }, &counts));
    try testing.expectEqual(@as(u32, 1), counts.resolved);
    try testing.expectEqual(@as(u32, 0), counts.unsupported);
    // `target="other"` is not resolvable in a self-only context.
    const foreign = Requirement{ .kind = .is_alive, .target = .other };
    counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{foreign}, .{}, &counts));
}

test "RandomRoll evaluates the Random seed against the value" {
    // Stock `RandomRoll::IsValid` (IL=71): FastLerp(min,max,RandomFloat)
    // compared with the requirement op; seed_type Random draws from the ctx
    // roll seed, Player/Item and a missing seed refuse.
    const roll = Requirement{ .kind = .random_roll, .op = .le, .value = 70, .min_max = .{ 0, 100 } };
    var counts: Counts = .{};
    // Deterministic: the same seed rolls the same verdict.
    const v1 = evaluate(&.{roll}, .{ .roll_seed = 1234 }, &counts);
    counts = .{};
    const v2 = evaluate(&.{roll}, .{ .roll_seed = 1234 }, &counts);
    try std.testing.expectEqual(v1, v2);
    try std.testing.expectEqual(@as(u32, 1), counts.resolved);
    // No seed refuses (a wall-clock seed would desync the sim).
    counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{roll}, .{}, &counts));
    // Player/Item seeds refuse (no per-entity/per-item stream here).
    counts = .{};
    const proll = Requirement{ .kind = .random_roll, .op = .le, .value = 70, .min_max = .{ 0, 100 }, .seed_type = .player };
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{proll}, .{ .roll_seed = 1234 }, &counts));
    // The stock shape parses from XML: seed_type + min_max + value/cvar.
    var arena_holder: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_holder.deinit();
    const arena = arena_holder.allocator();
    const src = "<effect_group><requirement name=\"RandomRoll\" seed_type=\"Random\" min_max=\"0,100\" operation=\"LTE\" value=\"70\"/></effect_group>";
    const b = std.mem.find(u8, src, "<requirement name=\"RandomRoll\"").?;
    const parsed = try parse(src, b, arena);
    try std.testing.expectEqual(Kind.random_roll, parsed.kind);
    try std.testing.expectEqual(SeedType.random, parsed.seed_type);
    try std.testing.expectEqual(@as(f32, 0), parsed.min_max[0]);
    try std.testing.expectEqual(@as(f32, 100), parsed.min_max[1]);
    try std.testing.expectEqual(@as(f32, 70), parsed.value);
}

test "PerksUnlocked sums the skill's child perk levels" {
    // Stock `PerksUnlocked::IsValid` (IL=68): the sum of purchased levels
    // over the named skill's children (book groups: 7 perks at max 1).
    var arena_holder: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_holder.deinit();
    const arena = arena_holder.allocator();
    const src = "<effect_group><requirement name=\"PerksUnlocked\" skill_name=\"skillFiremansAlmanac\" operation=\"GTE\" value=\"7\"/></effect_group>";
    const b = std.mem.find(u8, src, "<requirement name=\"PerksUnlocked\"").?;
    const parsed = try parse(src, b, arena);
    try std.testing.expectEqual(Kind.perks_unlocked, parsed.kind);
    try std.testing.expectEqualStrings("skillFiremansAlmanac", parsed.arg);
    // Children lookup over a synthetic tree: 7 perks at level 1 each.
    const Kids = struct {
        names: []const []const u8,
        fn total(holder: *const anyopaque, skill: []const u8, levels: []const NameLevel) u16 {
            const self: *@This() = @ptrCast(@alignCast(@constCast(holder)));
            _ = skill;
            var t: u16 = 0;
            for (self.names) |n| t += levelOf(levels, n) orelse 0;
            return t;
        }
    };
    var kids = Kids{ .names = &.{ "p1", "p2", "p3", "p4", "p5", "p6", "p7" } };
    const levels = [_]NameLevel{
        .{ .name = "p1", .level = 1 }, .{ .name = "p2", .level = 1 },
        .{ .name = "p3", .level = 1 }, .{ .name = "p4", .level = 1 },
        .{ .name = "p5", .level = 1 }, .{ .name = "p6", .level = 1 },
        .{ .name = "p7", .level = 1 },
    };
    const ctx = Ctx{ .levels = &levels, .skill_children_ctx = &kids, .skill_children_total = Kids.total };
    var counts: Counts = .{};
    try std.testing.expectEqual(Verdict.pass, evaluate(&.{parsed}, ctx, &counts));
    // 6 of 7: the GTE 7 gate fails.
    const levels6 = [_]NameLevel{
        .{ .name = "p1", .level = 1 }, .{ .name = "p2", .level = 1 },
        .{ .name = "p3", .level = 1 }, .{ .name = "p4", .level = 1 },
        .{ .name = "p5", .level = 1 }, .{ .name = "p6", .level = 1 },
    };
    counts = .{};
    try std.testing.expectEqual(Verdict.fail, evaluate(&.{parsed}, .{ .levels = &levels6, .skill_children_ctx = &kids, .skill_children_total = Kids.total }, &counts));
    // No lookup reads 0 (stock's unknown-name path), so GTE 7 fails, LT passes.
    counts = .{};
    try std.testing.expectEqual(Verdict.fail, evaluate(&.{parsed}, .{ .levels = &levels }, &counts));
}

test "IsStatAtMax reads Max minus Value under 0.1" {
    // Stock `IsStatAtMax::IsValid` (IL=100): `Max - Value < 0.1`. Stock rows
    // use food/water only; an unknown stat refuses.
    const full = Requirement{ .kind = .is_stat_at_max, .arg = "food" };
    const not_full = Requirement{ .kind = .is_stat_at_max, .negated = true, .arg = "food" };
    var counts: Counts = .{};
    try std.testing.expectEqual(Verdict.pass, evaluate(&.{full}, .{ .food_max = 100, .food_frac = 1 }, &counts));
    try std.testing.expectEqual(Verdict.fail, evaluate(&.{full}, .{ .food_max = 100, .food_frac = 0.5 }, &counts));
    try std.testing.expectEqual(Verdict.pass, evaluate(&.{not_full}, .{ .food_max = 100, .food_frac = 0.5 }, &counts));
    // Within 0.1 reads full (the heal-item gate must not fire at 99.95).
    counts = .{};
    try std.testing.expectEqual(Verdict.pass, evaluate(&.{full}, .{ .food_max = 100, .food_frac = 0.9995 }, &counts));
    // Water maps the same way; unknown stats refuse.
    const water = Requirement{ .kind = .is_stat_at_max, .arg = "water" };
    counts = .{};
    try std.testing.expectEqual(Verdict.pass, evaluate(&.{water}, .{ .water_max = 100, .water_frac = 1 }, &counts));
    counts = .{};
    const bogus = Requirement{ .kind = .is_stat_at_max, .arg = "mana" };
    try std.testing.expectEqual(Verdict.unsupported, evaluate(&.{bogus}, .{}, &counts));
    // The stock shape parses (stat rides the generic arg).
    var arena_holder: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_holder.deinit();
    const arena = arena_holder.allocator();
    const src = "<effect_group><requirement name=\"IsStatAtMax\" stat=\"food\"/></effect_group>";
    const b = std.mem.find(u8, src, "<requirement name=\"IsStatAtMax\"").?;
    const parsed = try parse(src, b, arena);
    try std.testing.expectEqual(Kind.is_stat_at_max, parsed.kind);
    try std.testing.expectEqualStrings("food", parsed.arg);
}

test "InSafeZone reads false without a Twitch integration" {
    // Stock `InSafeZone::IsValid` (IL=25) reads `EntityPlayer.TwitchSafe`;
    // zdtd has no Twitch integration, so the flag is never set. Both
    // stock rows are Twitch buffs (twitch_buffNoHealingManager,
    // twitch_voteNoSafe).
    const safe = Requirement{ .kind = .in_safe_zone };
    const not_safe = Requirement{ .kind = .in_safe_zone, .negated = true };
    var counts: Counts = .{};
    try std.testing.expectEqual(Verdict.fail, evaluate(&.{safe}, .{}, &counts));
    try std.testing.expectEqual(Verdict.pass, evaluate(&.{not_safe}, .{}, &counts));
    try std.testing.expectEqual(@as(u32, 2), counts.resolved);
}

test "EntityTagCompare target=other reads the other tags" {
    // `TargetedCompareRequirementBase` resolves `other` from MinEventParams;
    // the ctx carries it as `other_tags`. Without it the row refuses (never
    // reads self); with it the stock any-of/negation shape applies.
    const other = Requirement{ .kind = .entity_tag_compare, .target = .other, .list = "zombie,animal" };
    const not_other = Requirement{ .kind = .entity_tag_compare, .target = .other, .negated = true, .list = "trader" };
    var counts: Counts = .{};
    try std.testing.expectEqual(Verdict.unsupported, evaluate(&.{other}, .{ .entity_tags = "player" }, &counts));
    counts = .{};
    try std.testing.expectEqual(Verdict.pass, evaluate(&.{other}, .{ .entity_tags = "player", .other_tags = "zombie" }, &counts));
    try std.testing.expectEqual(Verdict.pass, evaluate(&.{not_other}, .{ .entity_tags = "player", .other_tags = "zombie" }, &counts));
    try std.testing.expectEqual(@as(u32, 2), counts.resolved);
    // A non-tag foreign kind still refuses (its input is the other's state).
    counts = .{};
    const alive_other = Requirement{ .kind = .is_alive, .target = .other };
    try std.testing.expectEqual(Verdict.unsupported, evaluate(&.{alive_other}, .{ .other_tags = "zombie" }, &counts));
}

test "all() is the AND over an empty and a multi-gate list" {
    try testing.expect(all(&.{}, .{}));
    const alive = Requirement{ .kind = .is_alive };
    const attached = Requirement{ .kind = .is_attached_to_entity };
    try testing.expect(all(&.{ alive, attached }, .{ .attached_to_entity = true }));
    try testing.expect(!all(&.{ alive, attached }, .{ .attached_to_entity = false }));
}
