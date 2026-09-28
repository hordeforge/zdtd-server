//! Requirement gate evaluator: verdict over one row gate list, the
//! per-kind eval fns, and `evaluate`/`all` entry points.
//!
//! Split out of requirements.zig (same code, moved verbatim);
//! re-exported through the requirements facade so existing
//! `requirements.evaluate` call sites keep working.

const std = @import("std");
const requirements = @import("requirements.zig");
const sandbox = @import("sandbox.zig");
const rng_util = @import("../util/rng.zig");
// Shapes owned by requirements.zig:
const Requirement = requirements.Requirement;
const Compare = requirements.Compare;
const Verdict = requirements.Verdict;
const Ctx = requirements.Ctx;
const Counts = requirements.Counts;
const NameLevel = requirements.NameLevel;

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

pub fn levelOf(levels: []const NameLevel, name: []const u8) ?u8 {
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
    return verdict(matchTagList(ctx.held_tags, r.list, r.has_all), r.negated);
}

/// `ItemHasTags::IsValid` (IL=43): same any-of/all-of match as HoldingItemHasTags,
/// but against `params.ItemValue`'s ItemClass tags. Null `item_tags` = no
/// ItemValue in scope (buff/perk fold) → refuse; empty = empty ItemValue → fail.
/// `TriggerHasTags` IL=33: the event's own tag set (params.Tags) overlaps the
/// row's list. The block-damage path supplies the damaged block's tags.
fn evalTriggerHasTags(r: Requirement, ctx: Ctx) Verdict {
    const tags = ctx.trigger_tags orelse return .unsupported;
    return verdict(matchTagList(tags, r.list, r.has_all), r.negated);
}

fn evalItemHasTags(r: Requirement, ctx: Ctx) Verdict {
    const tags = ctx.item_tags orelse return .unsupported;
    return verdict(matchTagList(tags, r.list, r.has_all), r.negated);
}

/// `RequirementItemTier::IsValid` (IL=36): compares `params.ItemValue.Quality`
/// with the row's op/value. Null ItemValue refuses (no item fold in scope);
/// a present quality of 0 still evaluates (IL compares the uint as float).
/// `CompareItemMetaFloat` (IL=57): the held item's `charge` metadata against
/// the row's value. The key is `charge` in every stock row, so the ctx carries
/// that one value; a row naming another key is not stock-shaped and refuses.
fn evalCompareItemMetaFloat(r: Requirement, ctx: Ctx) Verdict {
    if (r.arg.len > 0) return .unsupported;
    const charge = ctx.item_meta_charge orelse return .unsupported;
    return verdict(compare(charge, r.op, operand(ctx, r)), r.negated);
}

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
pub fn parseBodyParts(s: []const u8) i32 {
    var mask: i32 = 0;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |seg| {
        const n = std.mem.trim(u8, seg, " \t");
        if (n.len == 0) continue;
        mask |= bodyPartBit(n);
    }
    return mask;
}

pub fn bodyPartBit(name: []const u8) i32 {
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

/// The sample for a named stat; null for a name the ctx does not track (the
/// caller counts that as unsupported).
fn sample(name: []const u8, ctx: Ctx) ?Sample {
    const frac, const mod_max, const base_max = if (std.ascii.eqlIgnoreCase(name, "Health"))
        .{ ctx.hp_frac, ctx.hp_max, ctx.hp_base_max }
    else if (std.ascii.eqlIgnoreCase(name, "Stamina"))
        .{ ctx.stamina_frac, ctx.stamina_max, ctx.stamina_base_max }
    else if (std.ascii.eqlIgnoreCase(name, "Food"))
        .{ ctx.food_frac, ctx.food_max, ctx.food_base_max }
    else if (std.ascii.eqlIgnoreCase(name, "Water"))
        .{ ctx.water_frac, ctx.water_max, ctx.water_base_max }
    else
        return null;
    // `Stat::get_Value` IL=13 clamps to [0, ModifiedMax].
    const cur = @max(0, @min(frac * mod_max, mod_max));
    return .{ .cur = cur, .frac = frac, .mod_max = mod_max, .base_max = base_max };
}

/// Remap target=other stat reads onto the victim's supplied Health: only
/// Health rows ship with a foreign target (PulverizingFinishers,
/// PartyStarter), and only Health has an other_* supplier. Anything else
/// refuses rather than reading self.
fn statOtherCtx(r: Requirement, ctx: Ctx) Ctx {
    if (r.target != .other) return ctx;
    if (!std.ascii.eqlIgnoreCase(r.arg, "Health")) return Ctx{
        .hp_frac = 0,
        .hp_max = 0,
        .hp_base_max = 0,
    };
    var out = ctx;
    const frac = ctx.other_hp_frac orelse return Ctx{};
    const max = ctx.other_hp_max orelse return Ctx{};
    out.hp_frac = frac;
    out.hp_max = max;
    out.hp_base_max = max;
    return out;
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
    if (std.ascii.eqlIgnoreCase(r.arg, "Armor")) {
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

/// `TargetRange::IsValid` IL=59: `Entity::GetDistance(self, other)` vs the
/// row value (both orders compare the same; invert negates the result).
/// target=other reads the damage path's other_distance; self target has no
/// distance supplier (stock also needs Self+Other) and refuses.
fn evalTargetRange(r: Requirement, ctx: Ctx) Verdict {
    const d = ctx.other_distance orelse return .unsupported;
    return verdict(compare(d, r.op, operand(ctx, r)), r.negated);
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

/// `HasTrackedEntity::IsValid` IL=93: target must be EntityPlayerLocal and a
/// tagged entity must sit in the tracker's bounds. No local player on dedi.
fn evalHasTrackedEntity(r: Requirement, ctx: Ctx) Verdict {
    const tracked = ctx.has_tracked_entity orelse return .unsupported;
    return verdict(tracked, r.negated);
}

/// `PlayerItemCount::IsValid` IL=67: inventory + bag count of `item_name`
/// vs the row op/value. Null lookup refuses (no inventory in scope).
fn evalPlayerItemCount(r: Requirement, ctx: Ctx) Verdict {
    const lookup = ctx.item_count orelse return .unsupported;
    const holder = ctx.item_count_ctx orelse return .unsupported;
    return verdict(compare(@floatFromInt(lookup(holder, r.arg)), r.op, operand(ctx, r)), r.negated);
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
    return verdict(matchTagList(tags, r.list, r.has_all), r.negated);
}

/// `EntityTagCompare::IsValid` IL=43: `target.HasAnyTags` (any-of) or
/// `HasAllTags` with `has_all_tags="true"`, invert-aware. The evaluator runs
/// for the default `self` target only; a foreign target is refused before the
/// dispatch (the tick ctx carries one entity).
fn evalEntityTagCompare(r: Requirement, ctx: Ctx) Verdict {
    const entity_tags = ctx.entity_tags orelse return .unsupported;
    return verdict(matchTagList(entity_tags, r.list, r.has_all), r.negated);
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
/// negated by `invert`. target=other reads the supplied other_cvars store
/// (party-share fan-out); without one the gate refuses.
fn evalCvarCompare(r: Requirement, ctx: Ctx) Verdict {
    if (r.target == .other and ctx.other_cvars == null and ctx.other_not_alerted == null) return .unsupported;
    // `_notAlerted` projection for zombie victims: evaluated before the
    // store so the gate resolves without a seeded cvar.
    if (r.target == .other and std.mem.eql(u8, r.arg, "_notAlerted")) {
        if (ctx.other_not_alerted) |na| return verdict(compare(if (na) 1 else 0, r.op, operand(ctx, r)), r.negated);
    }
    return verdict(compare(cvarValue(ctx, r.arg), r.op, operand(ctx, r)), r.negated);
}

/// Swap the cvar store to the other's for foreign CVarCompare reads: the
/// caller (party-share fan-out) sets other_cvars per member. Self reads and
/// `@` operands keep the holder's own store.
fn cvarOtherCtx(r: Requirement, ctx: Ctx) Ctx {
    if (r.target != .other) return ctx;
    var out = ctx;
    out.cvars = ctx.other_cvars;
    return out;
}

/// The right-hand operand of a comparison: the literal `value`, or the entity's
/// custom variable when the row wrote `value="@name"` (255 stock rows do).
/// `min_max="a,b"` pair; a bare number is both ends.
pub fn parseMinMax(s: []const u8) [2]f32 {
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
pub fn tagListHas(list: []const u8, tag: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, std.mem.trim(u8, seg, " \t"), tag)) return true;
    }
    return false;
}

/// Any-of / all-of match of `needle_list` (comma tags) against `haystack`.
/// Empty needle list: any-of false, all-of true (stock empty-list rule).
pub fn matchTagList(haystack: []const u8, needle_list: []const u8, has_all: bool) bool {
    var matched = has_all;
    var seen = false;
    var it = std.mem.splitScalar(u8, needle_list, ',');
    while (it.next()) |seg| {
        const tag = std.mem.trim(u8, seg, " \t");
        if (tag.len == 0) continue;
        seen = true;
        const hit = haystack.len > 0 and tagListHas(haystack, tag);
        if (has_all) {
            if (!hit) {
                matched = false;
                break;
            }
        } else if (hit) {
            matched = true;
            break;
        }
    }
    if (!seen) matched = has_all;
    return matched;
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
    //   TargetRange + other_distance (damage path)
    //   WasAlive + other_alive (damage path; victim alive on a hit)
    //   StatComparePercCurrentToMax + other_hp_* (damage path; remapped in
    //   statOtherCtx, so the gate list lets it through)
    //   CVarCompare + other_cvars (party-share fan-out supplies the member's
    //   store; the evaluator refuses without one)
    // Everything else refuses rather than reading self.
    if (r.target != .self and r.kind != .entity_tag_compare and r.kind != .progression_level and r.kind != .is_alive and r.kind != .has_buff and r.kind != .is_corpse and r.kind != .is_sleeping and r.kind != .target_range and r.kind != .was_alive and r.kind != .stat_compare_perc_current_to_max and r.kind != .cvar_compare)
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
        } else if (r.kind == .was_alive) {
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
        } else if (r.kind == .stat_compare_perc_current_to_max) {
            // Victim health needs no use_ctx remap: statOtherCtx remaps at
            // the dispatch site onto the other_hp_* supplier.
        } else if (r.kind == .cvar_compare) {
            // Member cvars need no use_ctx remap: cvarOtherCtx swaps the store
            // at the dispatch site (and refuses without a supplier).
        } else if (r.kind == .target_range) {
            // Distance needs no remap: the evaluator reads other_distance
            // straight from ctx (both orders compare the same).
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
        .was_alive => return verdict(use_ctx.alive, r.negated),
        .is_male => return evalIsMale(r, ctx),
        .is_corpse => return evalIsCorpse(r, use_ctx),
        .is_sleeping => return evalIsSleeping(r, use_ctx),
        .target_range => return evalTargetRange(r, ctx),
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
        .is_secondary_attack => return verdict(ctx.is_secondary_attack, r.negated),
        .is_attached_to_entity => return verdict(ctx.attached_to_entity, r.negated),
        .holding_item_has_tags => return evalHoldingItemHasTags(r, ctx),
        .trigger_has_tags => return evalTriggerHasTags(r, ctx),
        .holding_item_broken => return evalHoldingItemBroken(r, ctx),
        .item_has_tags => return evalItemHasTags(r, ctx),
        .requirement_item_tier => return evalRequirementItemTier(r, ctx),
        .compare_item_meta_float => return evalCompareItemMetaFloat(r, ctx),
        .requirement_item_mod_tier => return evalRequirementItemModTier(r, ctx),
        .hit_location => return evalHitLocation(r, ctx),
        .sandbox_option_bool => return evalSandboxOptionBool(r, ctx),
        .game_stat_bool => return evalGameStatBool(r, ctx),
        .armor_group_lowest_quality => return evalArmorGroupLowestQuality(r, ctx),
        .armor_group_count => return evalArmorGroupCount(r, ctx),
        .stat_compare_perc_current_to_max => return evalStatComparePercCurrentToMax(r, statOtherCtx(r, ctx)),
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
        .cvar_compare => return evalCvarCompare(r, cvarOtherCtx(r, ctx)),
        .worn_items => return evalWornItems(r, ctx),
        .random_roll => return evalRandomRoll(r, ctx),
        .perks_unlocked => return evalPerksUnlocked(r, ctx),
        .is_stat_at_max => return evalIsStatAtMax(r, ctx),
        .in_safe_zone => return evalInSafeZone(r),
        .player_item_count => return evalPlayerItemCount(r, ctx),
        .has_tracked_entity => return evalHasTrackedEntity(r, ctx),
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
