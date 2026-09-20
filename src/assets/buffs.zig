//! buffs.xml: metadata + passive_effect rows. Full triggered_effect VM is later.

const std = @import("std");
const arena_util = @import("../util/arena.zig");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const paths = @import("paths.zig");
const requirements = @import("requirements.zig");
const cvars = @import("cvars.zig");
const sandbox = @import("sandbox.zig");
const components = @import("../ecs/components.zig");

/// Storage cap on parsed buff defs, a zdtd bound rather than a stock rule.
/// Measured against V3.2.0 `Data/Config` (2026-09-04): stock buffs.xml defines
/// **483**, so this runs at 24%.
pub const max_buffs: usize = 2048;
/// Measured against V3.2.0 `Data/Config` (2026-09-11): `buffShocked` carries the
/// most effect_group-scoped passive rows at 26, so this cap has headroom. It was
/// 16, which silently dropped 10 of that buff's rows.
pub const max_passives_per_buff: usize = 32;
pub const max_passives_total: usize = 8192;
pub const max_stat_mods_per_buff: usize = 8;
pub const max_stat_mods_total: usize = 2048;
pub const max_thresholds_per_buff: usize = 16;
pub const max_thresholds_total: usize = 512;
/// BuffClass::.ctor UpdateRateTicks default (asm.il 732691); update_rate is in
/// seconds and the client multiplies by 20 (asm.il 1371556).
pub const default_update_rate_ticks: i32 = 20;

/// passive_effect / triggered_effect `operation=`. The base_* and perc_* forms
/// come from passive_effect rows; the bare set/add/subtract/multiply forms come
/// from `action="ModifyStats"` and `ModifyCVar` triggered effects.
pub const Op = enum(u8) {
    base_set = 0,
    base_add = 1,
    perc_set = 2,
    perc_add = 3,
    base_subtract = 4,
    perc_subtract = 5,
    set = 6,
    add = 7,
    subtract = 8,
    multiply = 9,
    unknown = 255,
};

/// BuffEffectStackTypes (asm.il 738358), consumed by the stack switch in
/// EntityBuffs::AddBuff (asm.il 736259 IL_00e7). Lives with the component so
/// the rules in ecs/buff.zig need no dependency on the asset loader.
pub const StackType = components.StackType;

pub const max_curve_len: usize = 8;

pub const Passive = struct {
    name: []const u8 = "",
    op: Op = .unknown,
    /// First segment of a comma-separated curve value (level-1 value for
    /// perks; the flat value for single-segment rows). Kept for the legacy
    /// readers; `curveAt` is the level-aware accessor.
    value: f32 = 0,
    /// `value="@name"`: the row's value comes from the entity's custom
    /// variable (`MinEventActionModifyCVar`'s `cvarRef`; a missing name is 0),
    /// not from the curve. `@:`-prefixed values are localization keys and never
    /// reach here.
    value_cvar: []const u8 = "",
    tags: []const u8 = "",
    /// Per-level curve segments (stock `value="v1,v2,..."`: segment i applies
    /// at level i+1, clamped past the end). Filled for every parsed row.
    curve: [max_curve_len]f32 = .{0} ** max_curve_len,
    curve_len: u8 = 0,
    /// Explicit curve anchors from `level="1,5"` or `duration="0,20"`
    /// (progression.xml's dominant form is level pairs; 18 tracked buff rows use
    /// durations): value[i] sits at anchors[i], piecewise-linear between
    /// (curveValueAtLevels). 0 anchors = implicit.
    curve_levels: [max_curve_len]f32 = .{0} ** max_curve_len,
    curve_levels_len: u8 = 0,
    /// `<requirement>` gates: the enclosing `<effect_group>`'s direct children
    /// plus this row's own (MinEffectGroup::ParseXml IL=103 and
    /// PassiveEffect::ParsePassiveEffect IL=423 both call
    /// ParseRequirementGroup). Empty = ungated.
    reqs: []const requirements.Requirement = &.{},
};

/// One `<triggered_effect action="ModifyStats" .../>` row. Stock drives
/// starvation and dehydration damage this way rather than through a passive
/// effect, so the survival loop has to read these to get the real rate.
pub const StatMod = struct {
    /// `stat=` verbatim from the file, which is inconsistently cased in stock
    /// ("Food", "water"), so compare case-insensitively.
    stat: []const u8 = "",
    op: Op = .unknown,
    value: f32 = 0,
    /// `target="other"` on the row: the delta belongs to the event's other
    /// entity (Physician euthanizer set-to-kill), not self.
    target_other: bool = false,
    /// `delay=` seconds carried from the row; the caller defers (0 lands now).
    delay_s: f32 = 0,
};

/// Triggered rows per buff and in total (the onSelf* surface; only
/// ModifyStats/AddHealth/AddBuff/RemoveBuff/AddOrRemoveBuff/ModifyCVar/RemoveCVar
/// are evaluated - the other actions are recorded and skipped).
/// Measured against V3.2.0 `Data/Config` (2026-09-11): `buffStatusCheck02`
/// carries the most triggered rows at 126, then `buffFarmerSetBonus` 78 and
/// `buffStatusCheck01` 70; the file totals 3246. The old cap of 32 silently
/// dropped 94 of check02's rows, which is why the armor-set bonus rows never
/// parsed.
pub const max_triggered_per_buff: usize = 256;
pub const max_triggered_total: usize = 8192;

/// Stock onSelf* trigger names. `finish`/`stack` exist in the enum but have no
/// test: nothing in src evaluates one yet, so a row carrying either parses and
/// goes nowhere. Same fail-closed rule as every unhandled trigger; the row
/// stays in the table so a later engine change can consume it without
/// re-parsing.
pub const Trigger = enum(u8) {
    start,
    update,
    remove,
    entered_game,
    first_spawn,
    /// `onSelfProgressionUpdate`: fired when a progression value (perk,
    /// attribute, book) changes. progression.xml's `perkIntellectMastery` rows
    /// write `$perkBookwormChance` here, which the loot RandomRoll gates read.
    progression_update,
    /// `onPerkLevelChanged`: fired when a perk level is purchased (the 4
    /// `perkIntellectMastery` point-chance cvar rows).
    perk_level_changed,
    /// `onOtherAttackedSelf`: fired on the victim when another entity lands
    /// a hit (concussion/fatigue counters, PackMule display buff).
    other_attacked_self,
    /// `onSelfKilledOther`: fired on the killer's buffs and purchased
    /// perk/book rows when one of its hits kills (DeadEye/Berserker adds,
    /// stamina/health ModifyStats refunds).
    killed_other,
    /// `onSelfAttackedOther`: fired on the attacker when a hit lands
    /// (HitLocation-gated perk/buff rows: headshot/leg procs).
    self_attacked_other,
    /// `onSelfBuffFinish`: stock fires it when a buff's duration ends, after
    /// `onSelfBuffRemove` (87 buffs / 120 rows: stat restores, cvar clears,
    /// cooldown Adds, all currently inert).
    finish,
    /// `onSelfBuffStack`: stock fires it when AddBuff lands on an instance
    /// that is already active (42 buffs / 93 rows, mostly ModifyCVar chains
    /// like `buffHarvest`'s `$buffHarvestBonus`).
    stack,
    /// `onSelfLeaveGame`: fired on disconnect (storm/harvest/smell cleanup
    /// removes, debug-buff self-removes). Evaluated in the session-drop path
    /// before the entity is destroyed.
    leave_game,
    /// `onSelfDied`: fired on player death (infectionCounter set,
    /// aim/draw-buff removes). Evaluated in the hp-replicate death path
    /// before the game_on_death sequence runs.
    died,
    /// `onSelfPrimaryActionEnd`: fired when an eaten item's use ends; the
    /// consumable grants land here (beer/caffeine stamina buffs, drug
    /// water/DR buffs, goldenrod dysentery cure, medical buffProcessConsumables).
    /// Fired by the eat path, not the C2S damage/hit events.
    primary_action_end,
    /// `onSelfPrimaryActionRayHit`: fired when a ranged primary shot resolves
    /// a hit (DeepCuts/perception bleed-on-shot rows). The ranged hit path
    /// fires it; the C2S damage claim does not distinguish melee/ranged, so
    /// the held weapon's `ranged` tag selects it.
    primary_action_ray_hit,
    /// `onSelfDamagedOther`: fired when a landed hit applies its damage
    /// (Agility leg-cripple, Physician euthanizer on the stun baton). Fired
    /// alongside the attack event on the same C2S hit.
    self_damaged_other,
    /// `onOtherDamagedSelf`: fired on the victim when a landed hit applies
    /// damage from another entity (BarBrawling's rage on taking a fist hit).
    /// Fired alongside the victim's `other_attacked_self` path.
    other_damaged_self,
    /// `onCombatEntered`: fired on the out-of-combat -> in-combat transition
    /// (Enforcer Criminal Pursuit / Batter Up Stealing Bases stamina buffs).
    combat_entered,
    /// `onSelfFallImpact`: fired when the player lands after a fall (the
    /// buffStatusCheck01 leg-injury rows, gated on `_fallSpeed`). Driven by
    /// the falling-damage claim (dtype "falling"), which carries the impact.
    fall_impact,
    /// `onSelfDamagedBlock`: fired when the player damages a block (the check
    /// buff's church-bell spawn gate; TriggerHasTags reads the block's tags).
    block_damaged,
    other,
};

/// The bounded action set the engine evaluates.
pub const TriggeredAction = enum(u8) {
    modify_stats,
    add_buff,
    remove_buff,
    /// `MinEventActionAddOrRemoveBuff`: the row gates decide — pass adds,
    /// fail removes (weather/hazard toggles on `onSelfBuffUpdate`).
    add_or_remove_buff,
    /// `MinEventActionModifyCVar`: write one custom variable.
    modify_cvar,
    /// `MinEventActionRemoveCVar`: drop one.
    remove_cvar,
    /// `RemoveAllNegativeBuffs`: flag every active buff whose DamageType is
    /// set (near-death regen cure).
    remove_all_negative,
    /// `ResetProgression`: the respec consumable (Grandpa's Forgetting Elixir
    /// `reset_skills="true"`) refunds SkillPoints and clears perk/attribute
    /// levels to base. Recorded; the caller resets the player.
    reset_progression,
    /// `CallGameEvent`: run a gameevents.xml sequence by name
    /// (`MinEventActionCallGameEvent`; Dentist silver/gold grants).
    call_game_event,
    other,
};

/// One `<triggered_effect trigger=... action=...>` row with its nested
/// `<requirement>` children (stock reads them into the row's own
/// RequirementGroup, checked before the action runs).
pub const Triggered = struct {
    trigger: Trigger = .other,
    action: TriggeredAction = .other,
    /// ModifyStats target (case-insensitive compare like StatMod).
    stat: []const u8 = "",
    op: Op = .unknown,
    value: f32 = 0,
    /// AddBuff/RemoveBuff target.
    buff: []const u8 = "",
    /// `fireOneBuff="true"`: weighted single-pick over the comma `buff=` list
    /// (MinEventActionBuffModifierBase: GameRandom.RandomFloat walked against
    /// cumulative `buffWeights`; zombie-fist wound rows). Weights parsed into
    /// buff_weights; the caller picks one deterministically.
    fire_one_buff: bool = false,
    buff_weights: [16]f32 = .{0} ** 16,
    buff_weights_n: u8 = 0,
    /// `target="other"` on AddBuff/RemoveBuff rows: stock applies the buff
    /// to the event's other entity (victim-directed perk procs: shotgun
    /// stuns, cripples, bleeds) instead of self. `target="otherAOE"` rows
    /// apply to living entities within `range` of the other entity
    /// (SledgeSaga kill cripple); `target="selfAOE"` rows are recorded but
    /// not applied (admin RingOfFire only: no update-event range scan).
    target_other: bool = false,
    target_other_aoe: bool = false,
    /// `target="selfOtherPlayers"` on ModifyCVar/AddBuff rows: stock fans the
    /// row out to party/ally members (CharismaticNature level share + group
    /// buff). Parsed; the progression-update caller applies it.
    target_party: bool = false,
    /// `delay=` seconds on a row (stock `MinEventActionBase::Delay` runs the
    /// action through a coroutine; 21 kill-event stamina refunds carry 1.0).
    /// Parsed; the caller defers (0 = immediate).
    delay_s: f32 = 0,
    /// AoE range in metres (`range=`) and tag filter (`target_tags=`) for
    /// `target="otherAOE"` rows.
    aoe_range: f32 = 0,
    aoe_tags: []const u8 = "",
    /// CallGameEvent sequence name (`event=`); also reuses `buff` storage? No:
    /// a dedicated field keeps buff names and event names apart.
    game_event: []const u8 = "",
    /// ModifyCVar/RemoveCVar target (`cvar=`).
    cvar: []const u8 = "",
    /// ModifyCVar operation (`operation=`); `CVarOperation` defaults to set.
    cvar_op: cvars.Operation = .set,
    /// `value="@name"` on a ModifyCVar row: the operand is read from the
    /// entity's custom variable at apply time (`MinEventActionModifyCVar`'s
    /// `cvarRef`), not from `value`.
    value_cvar: []const u8 = "",
    /// Level-curved ModifyCVar `value="a,b,c"`: `Execute` indexes
    /// valueList[CalculatedLevel-1] when the event carries the row's
    /// ProgressionValue (spear-hunter metabolism curves). value_list_n = the
    /// parsed segment count; 0 = plain scalar.
    value_list: [16]f32 = .{0} ** 16,
    value_list_n: u8 = 0,
    /// The row's direct `<requirement>` children, evaluated by the shared
    /// evaluator (empty = ungated).
    reqs: []const requirements.Requirement = &.{},
};

/// One `<requirement name="StatComparePercCurrentToMax" .../>` gate. Stock
/// compares a **fraction of max**, not an absolute 0..100 value.
pub const StatThreshold = struct {
    /// The buff this requirement gates (the AddBuff target).
    buff: []const u8 = "",
    stat: []const u8 = "",
    /// Fraction of max, 0..1.
    value: f32 = 0,
};

pub const BuffDef = struct {
    name: []const u8 = "",
    /// BuffClass::InitialDurationMax in seconds; <= 0 never expires (asm.il 732754).
    duration: f32 = 0,
    stack_type: StackType = .ignore,
    update_rate_ticks: i32 = default_update_rate_ticks,
    /// BuffClass::RemoveOnDeath (asm.il 1371585), default true per .ctor.
    remove_on_death: bool = true,
    /// BuffClass::DamageType (`<damage_type value>` element, default none).
    /// `RemoveAllNegativeBuffs` clears buffs whose type is set.
    damage_type: []const u8 = "",
    /// The buff's `<tags value="..."/>` list (buffs.xml element, not an
    /// attribute). `game_on_death_injured` uses it to keep
    /// `deathpenalty_injured` buffs through death (16 stock buffs carry it).
    tags: []const u8 = "",
    passives: []const Passive = &.{},
    stat_mods: []const StatMod = &.{},
    thresholds: []const StatThreshold = &.{},
    /// The full onSelf* triggered surface (the passive-effects VM evaluates
    /// the bounded action set; the rest is recorded).
    triggered: []const Triggered = &.{},
};

/// Fallback catalog when buffs.xml is absent (headless tests, no game dir).
/// Verbatim subset of the stock file: name, stack_type, duration, update_rate,
/// remove_on_death only. Never invent buff names here, the client resolves them
/// against its own buffs.xml and drops anything it does not know.
pub const builtin_defs = [_]BuffDef{
    .{ .name = "buffInjuryBleeding", .duration = 0, .stack_type = .replace },
    .{ .name = "buffShocked", .duration = 4, .stack_type = .duration, .update_rate_ticks = 20 },
    .{ .name = "buffIsOnFire", .duration = 0, .stack_type = .ignore, .update_rate_ticks = 10 },
    .{ .name = "buffHarvest", .duration = 0, .stack_type = .effect, .remove_on_death = false },
    .{ .name = "buffStatusCheck01", .duration = 0, .stack_type = .ignore, .update_rate_ticks = 40, .remove_on_death = false },
};

pub fn builtin() Table {
    return .{ .defs = builtin_defs[0..] };
}

pub const Table = struct {
    defs: []const BuffDef = &.{},
    passive_pool: []const Passive = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,
    /// Lowercased name -> defs index, built once at load (XML tables only;
    /// small builtin/empty tables fall back to the linear scan below).
    name_index: std.StringHashMapUnmanaged(u16) = .{},

    pub fn empty() Table {
        return .{};
    }

    pub fn deinit(self: *Table) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            self.defs = &.{};
            self.passive_pool = &.{};
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
        self.* = .{};
    }

    /// Catalog index for a wire buff name. BuffManager::Buffs is a
    /// CaseInsensitiveStringDictionary (asm.il 733560), so lookup ignores case.
    pub fn indexOfName(self: *const Table, name: []const u8) ?u16 {
        if (self.name_index.count() != 0 and name.len <= 63) {
            var buf: [63]u8 = undefined;
            const lower = std.ascii.lowerString(buf[0..name.len], name);
            return self.name_index.get(lower);
        }
        for (self.defs, 0..) |d, i| {
            if (std.ascii.eqlIgnoreCase(d.name, name)) return @intCast(i);
        }
        return null;
    }

    pub fn byId(self: *const Table, id: u16) ?BuffDef {
        if (id >= self.defs.len) return null;
        return self.defs[id];
    }

    pub fn byName(self: *const Table, name: []const u8) ?BuffDef {
        const i = self.indexOfName(name) orelse return null;
        return self.defs[i];
    }

    /// Aggregate passive effect value for a buff (base_set overwrites, base_add sums).
    pub fn passiveValue(self: *const Table, buff_name: []const u8, effect: []const u8) ?f32 {
        const b = self.byName(buff_name) orelse return null;
        var acc: ?f32 = null;
        for (b.passives) |p| {
            if (!std.mem.eql(u8, p.name, effect)) continue;
            switch (p.op) {
                .base_set, .perc_set, .set => acc = p.value,
                .base_add, .perc_add, .add => acc = (acc orelse 0) + p.value,
                .base_subtract, .perc_subtract, .subtract => acc = (acc orelse 0) - p.value,
                .multiply => acc = (acc orelse 1) * p.value,
                .unknown => {},
            }
        }
        return acc;
    }
};

pub fn parseOp(s: []const u8) Op {
    if (std.mem.eql(u8, s, "base_set")) return .base_set;
    if (std.mem.eql(u8, s, "base_add")) return .base_add;
    if (std.mem.eql(u8, s, "perc_set")) return .perc_set;
    if (std.mem.eql(u8, s, "perc_add")) return .perc_add;
    if (std.mem.eql(u8, s, "base_subtract")) return .base_subtract;
    if (std.mem.eql(u8, s, "perc_subtract")) return .perc_subtract;
    if (std.mem.eql(u8, s, "set")) return .set;
    if (std.mem.eql(u8, s, "add")) return .add;
    if (std.mem.eql(u8, s, "subtract")) return .subtract;
    if (std.mem.eql(u8, s, "multiply")) return .multiply;
    return .unknown;
}

/// EnumUtils::Parse<BuffEffectStackTypes> with ignoreCase:true (asm.il 1371510).
/// An absent or unparsable value leaves the BuffClass::.ctor default (Ignore).
fn parseStackType(s: []const u8) StackType {
    if (std.ascii.eqlIgnoreCase(s, "duration")) return .duration;
    if (std.ascii.eqlIgnoreCase(s, "effect")) return .effect;
    if (std.ascii.eqlIgnoreCase(s, "replace")) return .replace;
    return .ignore;
}

/// update_rate seconds → UpdateRateTicks (asm.il 1371556: ParseFloat * 20, conv.i4).
fn parseUpdateRateTicks(s: []const u8) i32 {
    if (s.len == 0) return default_update_rate_ticks;
    const secs = std.fmt.parseFloat(f32, std.mem.trim(u8, s, " \t")) catch return default_update_rate_ticks;
    const ticks = secs * 20.0;
    if (!(ticks > 0)) return 0; // conv.i4 of a non-positive rate fires Update every tick
    if (ticks >= @as(f32, @floatFromInt(std.math.maxInt(i32)))) return std.math.maxInt(i32);
    return @trunc(ticks);
}

fn parseBoolAttr(s: []const u8, default: bool) bool {
    if (std.ascii.eqlIgnoreCase(s, "true")) return true;
    if (std.ascii.eqlIgnoreCase(s, "false")) return false;
    return default;
}

pub fn firstF32(s: []const u8) f32 {
    const comma = std.mem.findScalar(u8, s, ',') orelse s.len;
    return std.fmt.parseFloat(f32, std.mem.trim(u8, s[0..comma], " \t")) catch 0;
}

/// Parse a comma-separated ModifyCVar value curve (spear-hunter metabolism
/// rows) into a fixed array; level i reads value[i] (1-based).
fn parseValueList(s: []const u8) struct { list: [16]f32, n: u8 } {
    var out = [_]f32{0} ** 16;
    var n: u8 = 0;
    if (s.len == 0) return .{ .list = out, .n = 0 };
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |seg| {
        const t = std.mem.trim(u8, seg, " \t");
        if (t.len == 0) continue;
        if (n >= out.len) break;
        out[n] = std.fmt.parseFloat(f32, t) catch 0;
        n += 1;
    }
    return .{ .list = out, .n = n };
}

/// Parse a comma-separated `weights=` list into a fixed array (fireOneBuff).
fn parseWeights(s: []const u8) [16]f32 {
    var out = [_]f32{0} ** 16;
    if (s.len == 0) return out;
    var it = std.mem.splitScalar(u8, s, ',');
    var i: usize = 0;
    while (it.next()) |seg| {
        if (i >= out.len) break;
        out[i] = std.fmt.parseFloat(f32, std.mem.trim(u8, seg, " \t")) catch 0;
        i += 1;
    }
    return out;
}

/// Count of parsed weights (0 for empty).
fn weightsCount(s: []const u8) u8 {
    if (s.len == 0) return 0;
    var n: u8 = 0;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |seg| {
        if (std.mem.trim(u8, seg, " \t").len == 0) continue;
        if (n >= 16) break;
        n += 1;
    }
    return n;
}

/// Fill `out` with the comma-separated curve segments of a passive `value`
/// (stock: segment i applies at level i+1). Returns the segment count (0 for
/// an empty value). `out[0]` is always the flat/level-1 value.
pub fn parseCurveValue(s: []const u8, out: *[max_curve_len]f32) u8 {
    var n: u8 = 0;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |seg| {
        const seg_t = std.mem.trim(u8, seg, " \t");
        if (seg_t.len == 0) continue;
        if (n >= max_curve_len) break;
        out[n] = std.fmt.parseFloat(f32, seg_t) catch 0;
        n += 1;
    }
    return n;
}

/// Stock curve evaluation (RE PassiveEffect::ModValue, IL=796): the curve
/// Levels are scaled so value[0] sits at level 1 and value[n-1] at
/// `max_level`, and the effect interpolates linearly between neighbours
/// (Mathf.Lerp on the level fraction); a level outside every segment applies
/// nothing (0). The item effect level is the raw ItemValue.Quality
/// (EffectManager.GetValue IL_0393), so 6-value armor curves are per-quality
/// values and 2-value curves interpolate Q1..Q6 (e.g. 8..12.3).
pub fn curveValueAt(level: u8, max_level: u8, curve: []const f32) f32 {
    if (curve.len == 0 or level == 0 or max_level < 2) return 0;
    if (curve.len == 1) return curve[0];
    const l: f32 = @floatFromInt(level);
    const hi: f32 = @floatFromInt(max_level);
    const n = curve.len;
    for (1..n) |i| {
        const l0: f32 = 1.0 + (hi - 1.0) * @as(f32, @floatFromInt(i - 1)) / @as(f32, @floatFromInt(n - 1));
        const l1: f32 = 1.0 + (hi - 1.0) * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n - 1));
        if (l >= l0 and l <= l1) {
            const t: f32 = if (l1 > l0) (l - l0) / (l1 - l0) else 0;
            return curve[i - 1] + (curve[i] - curve[i - 1]) * t;
        }
    }
    return 0;
}

/// The axis a passive curve is evaluated on. Stock calls
/// `PassiveEffect.ModifyValue(ea, level, ...)` with the **purchased level** for
/// perk/attribute passives and with `BuffValue.DurationInSeconds` for buff
/// passives (`BuffClass::ModifyValue` IL=105), and the `level=`/`duration=`
/// attributes both fill the same `Levels` array.
pub const Axis = union(enum) {
    /// A purchased progression level (1-based; 0 = not purchased).
    level: u8,
    /// A buff's elapsed duration in seconds.
    duration: f32,
    /// An equipped/held item's quality tier. Unlike `level`, quality 0 is a
    /// real value (an item with no quality tier), so it does not short-circuit:
    /// stock seeds `PassiveEffect.ModValue` with `ItemValue.Quality` and spreads
    /// the value curve across the item's tier axis (`tier=`/quality 1..max),
    /// which is `curveValueAt` rather than the level-anchor interpolator.
    quality: Quality,
};

/// The item-quality axis: the tier value plus the tier count cap the items.xml
/// curve spreads over (stock item quality 1..6, `components.max_quality_tiers`).
pub const Quality = struct { level: u8, max: u8 };

/// Anchor-pair curve evaluation (stock `PassiveEffect.ModValue` over the
/// `level=`/`duration=` anchors): piecewise-linear between (levels[i],
/// values[i]); an axis outside every segment applies nothing (0), matching
/// ModValue's fall-through. Stock pairs the arrays **by shape** rather than by
/// padding them to equal length (`PassiveEffect::ModValue` IL_0016 `bne.un`
/// IL_01D4), so the two unequal shapes are evaluated explicitly:
/// `levels.len >= 2` with a single value holds `values[0]` flat across
/// `levels[0]..levels[1]` (IL_0348), and a single level with two values rolls
/// between them (IL_01D4, stock `RandomRange` / mean when the cached seed is 0,
/// for which the deterministic mean is the sim-safe projection). Every other
/// mismatch applies nothing (IL_057C).
pub fn curveValueAtLevels(axis: f32, levels: []const f32, values: []const f32) f32 {
    if (levels.len == 0 or values.len == 0) return 0;
    if (values.len != levels.len) {
        if (levels.len >= 2 and values.len == 1) {
            return if (axis >= levels[0] and axis <= levels[1]) values[0] else 0;
        }
        if (levels.len == 1 and values.len == 2) {
            return if (@floor(axis) == @floor(levels[0])) (values[0] + values[1]) * 0.5 else 0;
        }
        return 0;
    }
    // Single anchor: stock (PassiveEffect::ModValue IL=161) applies values[0]
    // only when FloorToInt(axis) == FloorToInt(levels[0]); it does not
    // interpolate or extrapolate. This is the shape of every `<book>` passive
    // row and 148 progression rows.
    if (levels.len == 1) {
        return if (@floor(axis) == @floor(levels[0])) values[0] else 0;
    }
    // Highest matching bracket wins (stock scans i = n-1 down to 1, IL_0155).
    var i: usize = levels.len;
    while (i > 1) : (i -= 1) {
        const j = i - 1;
        const l0 = levels[j - 1];
        const l1 = levels[j];
        if (axis >= l0 and axis <= l1) {
            const t: f32 = if (l1 > l0) (axis - l0) / (l1 - l0) else 0;
            return values[j - 1] + (values[j] - values[j - 1]) * t;
        }
    }
    return 0;
}

/// Value of a passive on `axis`. With explicit anchors the value interpolates
/// between the pairs; without them stock's `_levels == null` branch applies a
/// single value flat, averages a two-value row, and applies nothing for more
/// (ModValue IL=3C4).
pub fn curveAtAxis(p: Passive, axis: f32) f32 {
    if (p.curve_levels_len > 0) {
        // The value array keeps its own length: a `level="1,5" value="-1"` row
        // has two anchors and one value, which stock holds flat rather than
        // ramping to 0.
        return curveValueAtLevels(axis, p.curve_levels[0..p.curve_levels_len], p.curve[0..p.curve_len]);
    }
    if (p.curve_len == 0) return p.value;
    if (p.curve_len == 1) return p.curve[0];
    if (p.curve_len == 2) return (p.curve[0] + p.curve[1]) * 0.5;
    return 0;
}

/// Value of a passive at a purchased `level` (1-based). Level 0 (unpurchased)
/// is 0.
pub fn curveAt(p: Passive, level: u8) f32 {
    if (level == 0) return 0;
    return curveAtAxis(p, @floatFromInt(level));
}

/// Parse the explicit `level="a,b,..."` anchors (parallel to the value curve).
pub fn parseCurveLevels(s: []const u8, out: *[max_curve_len]f32) u8 {
    var n: u8 = 0;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |seg| {
        const seg_t = std.mem.trim(u8, seg, " \t");
        if (seg_t.len == 0) continue;
        if (n >= max_curve_len) break;
        out[n] = std.fmt.parseFloat(f32, seg_t) catch 0;
        n += 1;
    }
    return n;
}

/// Stock's anchor attribute chain (`PassiveEffect::ParsePassiveEffect`): the
/// first non-empty of `level=` (IL_01D3), `tier=` (IL_026C) or `duration=`
/// (IL_0304) fills the same Levels array, because each branch jumps past the
/// ones after it (`br IL_0394`). `tier=` is the items.xml quality axis (633
/// stock rows) and `duration=` the buff elapsed-time axis.
pub fn parseAnchors(body: []const u8, tag: usize, out: *[max_curve_len]f32) u8 {
    for ([_][]const u8{ "level", "tier", "duration" }) |attr_name| {
        const s = xml.attr(body, tag, attr_name) orelse continue;
        const n = parseCurveLevels(s, out);
        if (n > 0) return n;
    }
    return 0;
}

/// Append one `<passive_effect>` row with the gates stock applies to it: the
/// enclosing `<effect_group>`'s direct `<requirement>` children plus the row's
/// own nested ones (`MinEffectGroup::ParseXml` IL=103 and
/// `PassiveEffect::ParsePassiveEffect` IL=423 each build one RequirementGroup,
/// and `PassiveEffect::RequirementsMet` IL=180 checks them before the tag gate
/// and the value fold).
fn appendGatedPassive(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    body: []const u8,
    tag: usize,
    group_reqs: []const requirements.Requirement,
    passives: *std.ArrayList(Passive),
    req_pool: *std.ArrayList(requirements.Requirement),
    req_ranges: *std.ArrayList(struct { usize, usize }),
) !void {
    if (xml.attr(body, tag, "name") == null) return;
    const r0 = req_pool.items.len;
    for (group_reqs) |r| try req_pool.append(allocator, r);
    try requirements.scanRequirements(allocator, arena, body, tag, req_pool);
    try req_ranges.append(allocator, .{ r0, req_pool.items.len - r0 });
    const en = xml.attr(body, tag, "name").?;
    const op_s = xml.attr(body, tag, "operation") orelse "base_add";
    const val_s = xml.attr(body, tag, "value") orelse "0";
    // `value="@name"` is a cvar reference (not a curve); `@:` is localization.
    const val_cvar = if (val_s.len > 1 and val_s[0] == '@' and val_s[1] != ':') val_s[1..] else "";
    const tags = xml.attr(body, tag, "tags") orelse "";
    var curve: [max_curve_len]f32 = .{0} ** max_curve_len;
    const curve_len = if (val_cvar.len > 0) 0 else parseCurveValue(val_s, &curve);
    var curve_levels: [max_curve_len]f32 = .{0} ** max_curve_len;
    const curve_levels_len = parseAnchors(body, tag, &curve_levels);
    try passives.append(allocator, .{
        .name = try arena.dupe(u8, en),
        .op = parseOp(op_s),
        .value = curve[0],
        .value_cvar = if (val_cvar.len > 0) try arena.dupe(u8, val_cvar) else "",
        .tags = try arena.dupe(u8, tags),
        .curve = curve,
        .curve_len = curve_len,
        .curve_levels = curve_levels,
        .curve_levels_len = curve_levels_len,
    });
}

/// One `<effect_group>` body: its direct `<requirement>` children gate every
/// passive in it (`MinEffectGroup::ParseXml` IL=103 builds one RequirementGroup
/// for the element, not a running per-row list), and a row may add its own.
fn scanEffectGroup(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    g: []const u8,
    passives: *std.ArrayList(Passive),
    req_pool: *std.ArrayList(requirements.Requirement),
    req_ranges: *std.ArrayList(struct { usize, usize }),
    budget: usize,
) !void {
    var group_reqs: std.ArrayList(requirements.Requirement) = .empty;
    defer group_reqs.deinit(allocator);
    try requirements.scanChildren(allocator, arena, g, 0, g.len, &group_reqs);
    var pj: usize = 0;
    while (pj < g.len and passives.items.len < budget) {
        const pl = std.mem.findPos(u8, g, pj, "<") orelse break;
        if (std.mem.startsWith(u8, g[pl..], "</")) break;
        if (std.mem.startsWith(u8, g[pl..], "<passive_effect")) {
            try appendGatedPassive(allocator, arena, g, pl, group_reqs.items, passives, req_pool, req_ranges);
        }
        pj = requirements.elementEnd(g, pl);
    }
}

/// The `<triggered_effect>` rows in `body[start..end)` (one buff body at the
/// top level, or one `<effect_group>` body). Each row's gate list is the
/// region's gates first, then the row's own direct children, so a group gate
/// applies to every row inside it. `budget` is the absolute pool index the
/// per-buff cap ends at; `seen` accumulates the rows taken this buff.
pub fn scanTriggeredRows(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    body: []const u8,
    start: usize,
    end: usize,
    group_reqs: []const requirements.Requirement,
    triggered: *std.ArrayList(Triggered),
    reqs_list: *std.ArrayList(requirements.Requirement),
    trig_req_ranges: *std.ArrayList(struct { usize, usize }),
    budget: usize,
    seen: *usize,
) !void {
    var j = start;
    while (j < end and triggered.items.len < budget) {
        const ri = std.mem.findPos(u8, body[0..end], j, "<triggered_effect ") orelse break;
        if (ri >= end) break;
        const trig_s = xml.attr(body, ri, "trigger") orelse {
            j = ri + 18;
            continue;
        };
        const act_s = xml.attr(body, ri, "action") orelse {
            j = ri + 18;
            continue;
        };
        const row_end = requirements.elementEnd(body, ri);
        if (row_end == 0 or row_end > end) break;
        // AddHealth → ModifyStats Health add (MinEventActionAddHealth →
        // EntityAlive.AddHealth). `show_splatter` is client-only. `health="@cvar"`
        // is refused (stock has none); literal health= only.
        const is_add_health = std.mem.eql(u8, act_s, "AddHealth");
        const health_s = if (is_add_health) xml.attr(body, ri, "health") orelse "0" else "";
        const health_cvar = is_add_health and health_s.len > 1 and health_s[0] == '@';
        const act = if (is_add_health) .modify_stats else parseTriggeredAction(act_s);
        const val_s = xml.attr(body, ri, "value") orelse "0";
        // ModifyCVar takes its operand from a cvar when `value` starts with `@`
        // (MinEventActionModifyCVar::ParseXmlAttribute IL_0172 sets cvarRef and
        // strips the sigil); `@:` is a localization key and never a cvar. The
        // randomint(...)/randomfloat(...) forms are not implemented: a row that
        // would roll is refused rather than applied as 0. ModifyStats reads
        // `value="@x"` the same way at execute time (IL_0008: cvarRef →
        // GetCustomVar into value; falling-damage subtracts @.impactSpeed).
        const val_cvar = if ((act == .modify_cvar or act == .modify_stats) and val_s.len > 1 and val_s[0] == '@' and val_s[1] != ':') val_s[1..] else "";
        const roll = act == .modify_cvar and (std.mem.startsWith(u8, val_s, "randomint(") or
            std.mem.startsWith(u8, val_s, "randomfloat("));
        const target_s = xml.attr(body, ri, "target") orelse "";
        const weights_s = xml.attr(body, ri, "weights") orelse "";
        const tr: Triggered = .{
            .trigger = parseTrigger(trig_s),
            .action = if (roll or health_cvar) .other else act,
            .buff = try arena.dupe(u8, xml.attr(body, ri, "buff") orelse ""),
            .fire_one_buff = std.mem.eql(u8, xml.attr(body, ri, "fireOneBuff") orelse "", "true"),
            .buff_weights = parseWeights(weights_s),
            .buff_weights_n = weightsCount(weights_s),
            .game_event = try arena.dupe(u8, xml.attr(body, ri, "event") orelse ""),
            .target_other = std.mem.eql(u8, target_s, "other"),
            .target_other_aoe = std.mem.eql(u8, target_s, "otherAOE"),
            .target_party = std.mem.eql(u8, target_s, "selfOtherPlayers"),
            .aoe_range = firstF32(xml.attr(body, ri, "range") orelse "0"),
            .aoe_tags = try arena.dupe(u8, xml.attr(body, ri, "target_tags") orelse ""),
            .stat = try arena.dupe(u8, if (is_add_health) "Health" else xml.attr(body, ri, "stat") orelse ""),
            .cvar = try arena.dupe(u8, xml.attr(body, ri, "cvar") orelse ""),
            .cvar_op = cvars.Operation.parse(xml.attr(body, ri, "operation") orelse "set") orelse .set,
            .value_cvar = if (val_cvar.len > 0) try arena.dupe(u8, val_cvar) else "",
            .op = if (is_add_health) .add else parseOp(xml.attr(body, ri, "operation") orelse "add"),
            .value = if (is_add_health) firstF32(health_s) else firstF32(val_s),
            .value_list = blk: {
                const vl = parseValueList(val_s);
                break :blk vl.list;
            },
            .value_list_n = blk: {
                const vl = parseValueList(val_s);
                break :blk vl.n;
            },
            .delay_s = firstF32(xml.attr(body, ri, "delay") orelse "0"),
        };
        const rq0 = reqs_list.items.len;
        for (group_reqs) |g| try reqs_list.append(allocator, g);
        // The row's own `<requirement>` children, through the shared evaluator
        // (RequirementBase::ParseRequirementGroup IL=148 reads direct children).
        try requirements.scanRequirements(allocator, arena, body, ri, reqs_list);
        try trig_req_ranges.append(allocator, .{ rq0, reqs_list.items.len - rq0 });
        try triggered.append(allocator, tr);
        seen.* += 1;
        j = row_end;
    }
}

/// One element body's `<passive_effect>` rows, each with its effect_group's
/// gates. Every stock buff keeps its passives in `<effect_group>` blocks
/// (881/881) and none nests a group, so the walk is one level deep; a hand-built
/// or modded buff may put a row at the top level, which then carries only its
/// own gates. Items.xml carries the same rows on an `<item>`, so the scanner is
/// shared: `budget` is the absolute pool index the caller's row cap ends at
/// (buffs: `max_passives_per_buff`; items: `max_passives_per_item`).
pub fn scanPassives(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    body: []const u8,
    passives: *std.ArrayList(Passive),
    req_pool: *std.ArrayList(requirements.Requirement),
    req_ranges: *std.ArrayList(struct { usize, usize }),
    budget: usize,
) !bool {
    var i: usize = 0;
    while (i < body.len and passives.items.len < budget) {
        const lt = std.mem.findPos(u8, body, i, "<") orelse break;
        if (std.mem.startsWith(u8, body[lt..], "</")) break;
        if (std.mem.startsWith(u8, body[lt..], "<effect_group")) {
            const ggt = std.mem.findPos(u8, body, lt, ">") orelse break;
            if (ggt > lt and body[ggt - 1] == '/') {
                i = ggt + 1;
                continue;
            }
            const gclose = std.mem.findPos(u8, body, ggt, "</effect_group>") orelse break;
            try scanEffectGroup(allocator, arena, body[ggt + 1 .. gclose], passives, req_pool, req_ranges, budget);
            i = gclose + "</effect_group>".len;
            continue;
        }
        if (std.mem.startsWith(u8, body[lt..], "<passive_effect")) {
            try appendGatedPassive(allocator, arena, body, lt, &.{}, passives, req_pool, req_ranges);
        }
        i = requirements.elementEnd(body, lt);
    }
    // Reaching the budget means the row count is at the cap; report so a
    // truncated stock or modded buff is visible instead of silent.
    return passives.items.len >= budget;
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !Table {
    const clean = try xml.readCleanFile(allocator, path);
    defer allocator.free(clean);

    const arena_holder = try arena_util.newArenaHolder(allocator);
    errdefer {
        arena_holder.deinit();
        allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();

    var ranges: std.ArrayList(struct { usize, usize }) = .empty; // passive start,len per def
    defer ranges.deinit(allocator);
    var passives_list: std.ArrayList(Passive) = .empty;
    defer passives_list.deinit(allocator);
    var metas: std.ArrayList(BuffDef) = .empty; // every field but passives
    defer metas.deinit(allocator);
    var mods_list: std.ArrayList(StatMod) = .empty;
    defer mods_list.deinit(allocator);
    var mod_ranges: std.ArrayList(struct { usize, usize }) = .empty;
    defer mod_ranges.deinit(allocator);
    var thresholds_list: std.ArrayList(StatThreshold) = .empty;
    defer thresholds_list.deinit(allocator);
    var thr_ranges: std.ArrayList(struct { usize, usize }) = .empty;
    defer thr_ranges.deinit(allocator);
    var triggered_list: std.ArrayList(Triggered) = .empty;
    defer triggered_list.deinit(allocator);
    var trig_ranges: std.ArrayList(struct { usize, usize }) = .empty;
    defer trig_ranges.deinit(allocator);
    var reqs_list: std.ArrayList(requirements.Requirement) = .empty;
    defer reqs_list.deinit(allocator);
    var req_ranges: std.ArrayList(struct { usize, usize }) = .empty; // gate start,len per passive
    defer req_ranges.deinit(allocator);
    // Triggered rows pool their gate ranges separately from the passive pool,
    // but share the requirement pool.
    var trig_req_ranges: std.ArrayList(struct { usize, usize }) = .empty; // gate start,len per triggered row
    defer trig_req_ranges.deinit(allocator);

    // Buffs whose row count reached a cap (the parse drops the excess). Printed
    // once after the walk so a truncated file is visible.
    var truncated_passives: usize = 0;
    var truncated_triggered: usize = 0;

    var i: usize = 0;
    while (i < clean.len and metas.items.len < max_buffs) {
        const bi = std.mem.findPos(u8, clean, i, "<buff ") orelse break;
        const name = xml.attr(clean, bi, "name") orelse {
            i = bi + 6;
            continue;
        };
        const gt = std.mem.findPos(u8, clean, bi, ">") orelse break;
        var body_end = gt + 1;
        if (!(gt > bi and clean[gt - 1] == '/')) {
            const close = std.mem.findPos(u8, clean, gt, "</buff>") orelse break;
            body_end = close;
        }
        const body = clean[gt + 1 .. body_end];
        var meta: BuffDef = .{ .name = try arena.dupe(u8, name) };
        if (xml.attr(clean, bi, "duration")) |d| {
            meta.duration = std.fmt.parseFloat(f32, d) catch 0;
        } else if (std.mem.find(u8, body, "<duration")) |di| {
            if (xml.attr(body, di, "value")) |v| meta.duration = std.fmt.parseFloat(f32, v) catch 0;
        }
        if (std.mem.find(u8, body, "<stack_type")) |si| {
            if (xml.attr(body, si, "value")) |v| meta.stack_type = parseStackType(v);
        }
        if (std.mem.find(u8, body, "<update_rate")) |ui| {
            if (xml.attr(body, ui, "value")) |v| meta.update_rate_ticks = parseUpdateRateTicks(v);
        }
        if (xml.attr(clean, bi, "remove_on_death")) |v| meta.remove_on_death = parseBoolAttr(v, true);
        if (std.mem.find(u8, body, "<tags")) |ti| {
            if (xml.attr(body, ti, "value")) |v| meta.tags = try arena.dupe(u8, v);
        }
        if (std.mem.find(u8, body, "<damage_type")) |di| {
            if (xml.attr(body, di, "value")) |v| meta.damage_type = try arena.dupe(u8, v);
        }
        const m0 = mods_list.items.len;
        var mj: usize = 0;
        var mn: usize = 0;
        while (mj < body.len and mn < max_stat_mods_per_buff and mods_list.items.len < max_stat_mods_total) {
            const ti = std.mem.findPos(u8, body, mj, "action=\"ModifyStats\"") orelse break;
            mj = ti + 20;
            // Attributes sit on the same tag, so scan from the tag open.
            const tag = std.mem.findScalarLast(u8, body[0..ti], '<') orelse continue;
            const st = xml.attr(body, tag, "stat") orelse continue;
            const op_s = xml.attr(body, tag, "operation") orelse "add";
            const val_s = xml.attr(body, tag, "value") orelse "0";
            try mods_list.append(allocator, .{
                .stat = try arena.dupe(u8, st),
                .op = parseOp(op_s),
                .value = firstF32(val_s),
            });
            mn += 1;
        }

        const t0 = thresholds_list.items.len;
        var tj: usize = 0;
        var tn: usize = 0;
        while (tj < body.len and tn < max_thresholds_per_buff and thresholds_list.items.len < max_thresholds_total) {
            const ri = std.mem.findPos(u8, body, tj, "StatComparePercCurrentToMax") orelse break;
            tj = ri + 27;
            const tag = std.mem.findScalarLast(u8, body[0..ri], '<') orelse continue;
            const st = xml.attr(body, tag, "stat") orelse continue;
            const val_s = xml.attr(body, tag, "value") orelse continue;
            // The gated buff is the AddBuff on the enclosing triggered_effect,
            // which opens before this requirement.
            const te = std.mem.findLast(u8, body[0..ri], "<triggered_effect") orelse continue;
            const gated = xml.attr(body, te, "buff") orelse "";
            try thresholds_list.append(allocator, .{
                .buff = try arena.dupe(u8, gated),
                .stat = try arena.dupe(u8, st),
                .value = firstF32(val_s),
            });
            tn += 1;
        }

        // Full onSelf* surface: trigger/action/stat/buff, gated by the row's own
        // `<requirement>` children AND the enclosing `<effect_group>`'s direct
        // gates (`MinEffectGroup::ParseXml` IL=103 builds one RequirementGroup
        // for the element), so the walk is two levels like the passive scan.
        const tr0 = triggered_list.items.len;
        const tr_budget = @min(tr0 + max_triggered_per_buff, max_triggered_total);
        var trn: usize = 0;
        var trj: usize = 0;
        while (trj < body.len and triggered_list.items.len < tr_budget) {
            const lt = std.mem.findPos(u8, body, trj, "<") orelse break;
            if (std.mem.startsWith(u8, body[lt..], "</")) break;
            if (std.mem.startsWith(u8, body[lt..], "<effect_group")) {
                const ggt = std.mem.findPos(u8, body, lt, ">") orelse break;
                if (ggt > lt and body[ggt - 1] == '/') {
                    trj = ggt + 1;
                    continue;
                }
                const gclose = std.mem.findPos(u8, body, ggt, "</effect_group>") orelse break;
                var group_reqs: std.ArrayList(requirements.Requirement) = .empty;
                defer group_reqs.deinit(allocator);
                try requirements.scanChildren(allocator, arena, body, ggt + 1, gclose, &group_reqs);
                try scanTriggeredRows(allocator, arena, body, ggt + 1, gclose, group_reqs.items, &triggered_list, &reqs_list, &trig_req_ranges, tr_budget, &trn);
                trj = gclose + "</effect_group>".len;
                continue;
            }
            if (std.mem.startsWith(u8, body[lt..], "<triggered_effect")) {
                try scanTriggeredRows(allocator, arena, body, lt, requirements.elementEnd(body, lt), &.{}, &triggered_list, &reqs_list, &trig_req_ranges, tr_budget, &trn);
            }
            trj = requirements.elementEnd(body, lt);
        }
        if (triggered_list.items.len >= tr_budget and tr_budget < max_triggered_total) truncated_triggered += 1;
        try trig_ranges.append(allocator, .{ tr0, triggered_list.items.len - tr0 });

        const p0 = passives_list.items.len;
        const passive_budget = @min(passives_list.items.len + max_passives_per_buff, max_passives_total);
        if (try scanPassives(allocator, arena, body, &passives_list, &reqs_list, &req_ranges, passive_budget)) truncated_passives += 1;
        try metas.append(allocator, meta);
        try ranges.append(allocator, .{ p0, passives_list.items.len - p0 });
        try mod_ranges.append(allocator, .{ m0, mods_list.items.len - m0 });
        try thr_ranges.append(allocator, .{ t0, thresholds_list.items.len - t0 });
        // `body_end` is already past the row (the `>` of a self-closing buff, or
        // the `<` of `</buff>`); the old `+ 1` resumed one char late, which
        // dropped every second self-closing `<buff/>` in a run.
        i = body_end;
    }

    const pool = try arena.alloc(Passive, passives_list.items.len);
    @memcpy(pool, passives_list.items);
    // Every passive row has one gate range (empty for ungated rows); a mismatch
    // means the group walk and the append drifted apart.
    if (req_ranges.items.len != pool.len) return error.MalformedBuffs;
    const req_pool = try arena.alloc(requirements.Requirement, reqs_list.items.len);
    @memcpy(req_pool, reqs_list.items);
    for (pool, req_ranges.items) |*p, rg| {
        p.reqs = req_pool[rg[0] .. rg[0] + rg[1]];
    }
    const mod_pool = try arena.alloc(StatMod, mods_list.items.len);
    @memcpy(mod_pool, mods_list.items);
    const thr_pool = try arena.alloc(StatThreshold, thresholds_list.items.len);
    @memcpy(thr_pool, thresholds_list.items);
    const trig_pool = try arena.alloc(Triggered, triggered_list.items.len);
    @memcpy(trig_pool, triggered_list.items);
    if (trig_req_ranges.items.len != trig_pool.len) return error.MalformedBuffs;
    for (trig_pool, trig_req_ranges.items) |*tr, rg| {
        tr.reqs = req_pool[rg[0] .. rg[0] + rg[1]];
    }
    const defs = try arena.alloc(BuffDef, metas.items.len);
    for (metas.items, ranges.items, 0..) |meta, rg, di| {
        defs[di] = meta;
        defs[di].passives = pool[rg[0] .. rg[0] + rg[1]];
        const mr = mod_ranges.items[di];
        defs[di].stat_mods = mod_pool[mr[0] .. mr[0] + mr[1]];
        const tr = thr_ranges.items[di];
        defs[di].thresholds = thr_pool[tr[0] .. tr[0] + tr[1]];
        const tg = trig_ranges.items[di];
        defs[di].triggered = trig_pool[tg[0] .. tg[0] + tg[1]];
    }
    if (truncated_passives > 0 or truncated_triggered > 0) {
        std.debug.print(
            "zdtd: buffs.xml hit a row cap (passives {d} buffs, triggered {d} buffs); rows past the cap were dropped (max_passives_per_buff={d}, max_triggered_per_buff={d})\n",
            .{ truncated_passives, truncated_triggered, max_passives_per_buff, max_triggered_per_buff },
        );
    }
    var name_index: std.StringHashMapUnmanaged(u16) = .{};
    try name_index.ensureTotalCapacity(arena, @intCast(defs.len));
    for (defs, 0..) |d, di| {
        const lower = try arena.alloc(u8, d.name.len);
        _ = std.ascii.lowerString(lower, d.name);
        const gop = name_index.getOrPutAssumeCapacity(lower);
        if (!gop.found_existing) gop.value_ptr.* = @intCast(di);
    }

    return .{ .defs = defs, .passive_pool = pool, .arena_ptr = arena_holder, .name_index = name_index };
}

/// Survival numbers stock ships as data, resolved out of the loaded table so
/// the sim does not have to know buff names or walk effect rows every tick.
///
/// What is here is what buffs.xml actually carries. The **base** food and water
/// depletion is deliberately absent: stock decays those engine-side through
/// `Stat.Tick` (activity scaled), and no XML row states the rate, so that one
/// stays a documented policy tunable in `Rules.progression` rather than being
/// invented here and presented as stock (AGENTS: prefer missing over fake).
pub const Survival = struct {
    /// Fraction of max Food at or below which each hunger stage applies
    /// (stock buffStatusCheck01: .5, .25, .02). 0 = not found.
    hungry_frac: [3]f32 = .{ 0, 0, 0 },
    /// Same for Water (buffStatusThirsty01/02/03).
    thirsty_frac: [3]f32 = .{ 0, 0, 0 },
    /// HP lost per **real** second at the final hunger stage. Stock applies
    /// `ModifyStats Health subtract .25` once per buff update, so this is that
    /// value divided by the buff's update rate.
    starve_hp_per_s: f32 = 0,
    /// Same for the final thirst stage (Dehydration).
    dehydrate_hp_per_s: f32 = 0,
    /// Fraction of max stamina subtracted while starving
    /// (buffStatusHungry03 `StaminaChangeOT perc_subtract`).
    starve_stamina_perc: f32 = 0,

    /// True when the table carried enough to drive the sim. False keeps the
    /// caller on its Rules floor rather than on a half-resolved mix.
    pub fn ok(self: Survival) bool {
        return self.hungry_frac[0] > 0 and self.thirsty_frac[0] > 0 and self.starve_hp_per_s > 0;
    }
};

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    return true;
}

/// Health lost per real second by `buff_name`'s ModifyStats Health row.
fn healthLossPerSecond(t: *const Table, buff_name: []const u8) f32 {
    const d = t.byName(buff_name) orelse return 0;
    const rate_ticks: f32 = @floatFromInt(@max(1, d.update_rate_ticks));
    const secs = rate_ticks / 20.0; // update_rate is stored in 20 TPS ticks
    for (d.stat_mods) |m| {
        if (!eqIgnoreCase(m.stat, "Health")) continue;
        if (m.op != .base_subtract and m.op != .subtract) continue;
        if (m.value <= 0 or secs <= 0) continue;
        return m.value / secs;
    }
    return 0;
}

/// Resolve the survival numbers stock ships. Missing rows stay 0 so the caller
/// can tell "not in this file" from "stock says zero".
pub fn survival(t: *const Table) Survival {
    var out: Survival = .{};
    const check = t.byName("buffStatusCheck01");
    if (check) |c| {
        for (c.thresholds) |th| {
            const stage: usize = if (std.mem.endsWith(u8, th.buff, "01"))
                0
            else if (std.mem.endsWith(u8, th.buff, "02"))
                1
            else if (std.mem.endsWith(u8, th.buff, "03"))
                2
            else
                continue;
            if (eqIgnoreCase(th.stat, "Food") and std.mem.find(u8, th.buff, "Hungry") != null) {
                out.hungry_frac[stage] = th.value;
            } else if (eqIgnoreCase(th.stat, "Water") and std.mem.find(u8, th.buff, "Thirsty") != null) {
                out.thirsty_frac[stage] = th.value;
            }
        }
    }
    out.starve_hp_per_s = healthLossPerSecond(t, "buffStatusHungry03");
    out.dehydrate_hp_per_s = healthLossPerSecond(t, "buffStatusThirsty03");
    if (t.byName("buffStatusHungry03")) |h3| {
        for (h3.passives) |ps| {
            if (std.mem.eql(u8, ps.name, "StaminaChangeOT") and ps.op == .perc_subtract) {
                out.starve_stamina_perc = ps.value;
                break;
            }
        }
    }
    return out;
}

/// --- Revertible passive-effects VM (bounded EffectManager surface) ---
///
/// Stock evaluates every active buff's passive_effect rows against the entity
/// on each buff update (EffectManager.GetValue); this VM folds the rows of a
/// tracked surface into one additive delta set per buff and sums the active
/// set. Removing a buff reverses its contribution exactly - the total is a
/// pure recomputation over the active set (the paper's revertible-effects
/// discipline, no stale inverse records). The pass is bounded:
/// `max_buffs_per_entity` active slots, no allocation, no table writes.
/// The tracked surface is the stats the sim owns: health/food/water/stamina
/// (values and change-over-time) and the damage-resist percents. Rows outside
/// it are counted but not simulated (recorded, not guessed).
pub const TrackedDeltas = struct {
    hp_max: f32 = 0,
    hp_ot: f32 = 0,
    food_max: f32 = 0,
    food_ot: f32 = 0,
    water_max: f32 = 0,
    water_ot: f32 = 0,
    stamina_max: f32 = 0,
    stamina_ot: f32 = 0,
    /// Injury max caps (`HealthMaxBlockage`/`StaminaMaxBlockage`, the
    /// abrasion/sprain/break rows whose `@$counter` cvar value the fold
    /// resolves): subtracted from the max at the consumer, never added.
    hp_block: f32 = 0,
    stamina_block: f32 = 0,
    /// PhysicalDamageResist percent (stock passive 41, GetTotalPhysicalArmorRating).
    phys_resist: f32 = 0,
    general_resist: f32 = 0,
    elem_resist: f32 = 0,

    pub fn any(self: TrackedDeltas) bool {
        return self.hp_max != 0 or self.hp_ot != 0 or self.food_max != 0 or
            self.food_ot != 0 or self.water_max != 0 or self.water_ot != 0 or
            self.stamina_max != 0 or self.stamina_ot != 0 or
            self.hp_block != 0 or self.stamina_block != 0 or
            self.phys_resist != 0 or self.general_resist != 0 or self.elem_resist != 0;
    }
};

const TrackedField = enum(u8) {
    hp_max,
    hp_ot,
    food_max,
    food_ot,
    water_max,
    water_ot,
    stamina_max,
    stamina_ot,
    hp_block,
    stamina_block,
    phys_resist,
    general_resist,
    elem_resist,
};

const tracked_names = [_]struct { name: []const u8, field: TrackedField }{
    .{ .name = "HealthChangeOT", .field = .hp_ot },
    .{ .name = "FoodChangeOT", .field = .food_ot },
    .{ .name = "WaterChangeOT", .field = .water_ot },
    .{ .name = "StaminaChangeOT", .field = .stamina_ot },
    .{ .name = "HealthMax", .field = .hp_max },
    .{ .name = "FoodMax", .field = .food_max },
    .{ .name = "WaterMax", .field = .water_max },
    .{ .name = "StaminaMax", .field = .stamina_max },
    .{ .name = "HealthMaxBlockage", .field = .hp_block },
    .{ .name = "StaminaMaxBlockage", .field = .stamina_block },
    .{ .name = "PhysicalDamageResist", .field = .phys_resist },
    .{ .name = "GeneralDamageResist", .field = .general_resist },
    .{ .name = "ElementalDamageResist", .field = .elem_resist },
};

fn addTo(out: *TrackedDeltas, field: TrackedField, v: f32) void {
    switch (field) {
        inline else => |f| @field(out, @tagName(f)) += v,
    }
}

/// Sanity ceiling for a tracked delta (f32). Stock stat values and passive
/// deltas are < 1e4; the ceiling keeps a pathological modded curve value
/// (1e38, inf, or nan from a passive/effect attribute) from reaching the
/// tick's @trunc casts on the max stats, while leaving every real
/// curve 10000x of headroom. NaN folds to 0 (fail closed); the sign is
/// kept for finite values.
pub const tracked_delta_max: f32 = 1_000_000;

fn clampDelta(v: f32) f32 {
    if (std.math.isNan(v)) return 0;
    return std.math.clamp(v, -tracked_delta_max, tracked_delta_max);
}

fn addDeltas(a: *TrackedDeltas, b: TrackedDeltas) void {
    inline for (@typeInfo(TrackedDeltas).@"struct".fields) |f| {
        @field(a, f.name) = clampDelta(@field(a, f.name) + @field(b, f.name));
    }
}

/// Fold a passive_effect list over the tracked surface.
/// `base_add`/`base_subtract` are flat deltas; `perc_*` keep the raw XML
/// fraction (the survival loop applies `fraction x base / 100` per second -
/// the pre-VM arithmetic, unchanged). `base_set` and any other op over a
/// tracked name are omitted: without the per-entity base value the delta is
/// not defined (recorded, not guessed).
///
/// Each tracked row is gated first (ADR 0023 §2): its `<requirement>` list is
/// evaluated against `ctx` and a row whose gates do not pass is not folded.
/// `counts` accumulates the gate accounting for the caller's APM counters; the
/// fold itself stays a pure recompute over the gated set, so removing a level
/// still reverses its contribution exactly.
pub fn trackedDeltasAt(
    passives: []const Passive,
    axis: Axis,
    ctx: requirements.Ctx,
    counts: *requirements.Counts,
) TrackedDeltas {
    const a: f32 = switch (axis) {
        .level => |l| if (l == 0) return .{} else @floatFromInt(l),
        .duration => |d| d,
        // The quality axis never short-circuits (see Axis.quality); the value is
        // resolved per row through curveValueAt below.
        .quality => 0,
    };
    var out: TrackedDeltas = .{};
    for (passives) |p| {
        const field = blk: {
            for (tracked_names) |t| {
                if (std.mem.eql(u8, t.name, p.name)) break :blk t.field;
            }
            break :blk null;
        } orelse continue;
        // PassiveEffect::RequirementsMet (IL=180) matches the row's tags before
        // it checks the requirement group, so a tag-scoped row stays out of a
        // query whose tag set does not carry it.
        if (!tagsMatch(p.tags, ctx.tags)) continue;
        if (p.reqs.len > 0 and requirements.evaluate(p.reqs, ctx, counts) != .pass) continue;
        // A `value="@name"` row reads the entity's cvar instead of the curve
        // (the cvar's own value already carries any scaling).
        const v = if (p.value_cvar.len > 0)
            requirements.cvarValue(ctx, p.value_cvar)
        else switch (axis) {
            // Item rows carry the same `value=` curve, but the axis is the
            // quality tier (see itemQualityValue).
            .quality => |q| itemQualityValue(p, q),
            else => curveAtAxis(p, a),
        };
        switch (p.op) {
            .base_add => addTo(&out, field, v),
            .base_subtract => addTo(&out, field, -v),
            .perc_add => addTo(&out, field, v),
            .perc_subtract => addTo(&out, field, -v),
            else => continue,
        }
    }
    return out;
}

/// Fold the `LootProb` rows (passive 79) of `passives` onto a loot entry's base
/// probability. Rows apply in file order with the GetValue op semantics
/// (`base_set` replaces, `base_add`/`base_subtract` add, `perc_add`/
/// `perc_subtract` scale by `1 +/- v/100`), and only rows whose `tags` intersect
/// `ctx.tags` participate (`PassiveEffect::RequirementsMet` filters on the query
/// tag set before the requirement group) - that query set is the loot entry's
/// own `tags=` attribute, which is what the 431 tagged stock entries are for.
/// Stock's 128 LootProb rows hang off perks like `perkDeadEye`
/// (`perc_add 2..10 tags="rifleSkill,ammo762mm"`).
pub fn lootProbFold(passives: []const Passive, axis: Axis, ctx: requirements.Ctx, base: f32, counts: *requirements.Counts) f32 {
    const a: f32 = switch (axis) {
        .level => |l| if (l == 0) return base else @floatFromInt(l),
        .duration => |d| d,
        .quality => 0,
    };
    var v = base;
    for (passives) |p| {
        if (!std.mem.eql(u8, p.name, "LootProb")) continue;
        if (!tagsMatch(p.tags, ctx.tags)) continue;
        if (p.reqs.len > 0 and requirements.evaluate(p.reqs, ctx, counts) != .pass) continue;
        const amount = if (p.value_cvar.len > 0)
            requirements.cvarValue(ctx, p.value_cvar)
        else switch (axis) {
            .quality => |q| itemQualityValue(p, q),
            else => curveAtAxis(p, a),
        };
        switch (p.op) {
            .base_set, .set => v = amount,
            .base_add, .add => v += amount,
            .base_subtract, .subtract => v -= amount,
            .perc_add => v *= 1.0 + amount / 100.0,
            .perc_subtract => v *= 1.0 - amount / 100.0,
            else => {},
        }
        if (!(v >= 0)) v = 0;
    }
    return v;
}

/// Fold the `PlayerExpGain` rows (passive 87) onto a base XP award.
/// Same GetValue op / tag / req filtering as `lootProbFold`, but `perc_add`/
/// `perc_subtract` use stock's fraction form (`1 +/- v`) — PlayerExpGain rows
/// ship as fractions (Harvesting `-.1..-.4`, Kill `.05`, medical `1`/`2`/`5`),
/// not the LootProb percent scale.
pub fn playerExpGainFold(passives: []const Passive, axis: Axis, ctx: requirements.Ctx, base: f32, counts: *requirements.Counts) f32 {
    const a: f32 = switch (axis) {
        .level => |l| if (l == 0) return base else @floatFromInt(l),
        .duration => |d| d,
        .quality => 0,
    };
    var v = base;
    for (passives) |p| {
        if (!std.mem.eql(u8, p.name, "PlayerExpGain")) continue;
        if (!tagsMatch(p.tags, ctx.tags)) continue;
        if (p.reqs.len > 0 and requirements.evaluate(p.reqs, ctx, counts) != .pass) continue;
        const amount = if (p.value_cvar.len > 0)
            requirements.cvarValue(ctx, p.value_cvar)
        else switch (axis) {
            .quality => |q| itemQualityValue(p, q),
            else => curveAtAxis(p, a),
        };
        switch (p.op) {
            .base_set, .set => v = amount,
            .base_add, .add => v += amount,
            .base_subtract, .subtract => v -= amount,
            .perc_add => v *= 1.0 + amount,
            .perc_subtract => v *= 1.0 - amount,
            else => {},
        }
        if (!(v >= 0)) v = 0;
    }
    return v;
}

/// Fold a named GetValue passive onto `base` with fraction `perc_add`
/// (`1+/-v`). Used for `GlobalGameStageModifier` / `GlobalLootStageModifier`
/// (EntityPlayer getters start at 1.0). Same tag/req filtering as the
/// LootProb / PlayerExpGain folds.
pub fn namedPassiveFold(name: []const u8, passives: []const Passive, axis: Axis, ctx: requirements.Ctx, base: f32, counts: *requirements.Counts) f32 {
    const a: f32 = switch (axis) {
        .level => |l| if (l == 0) return base else @floatFromInt(l),
        .duration => |d| d,
        .quality => 0,
    };
    var v = base;
    for (passives) |p| {
        if (!std.mem.eql(u8, p.name, name)) continue;
        if (!tagsMatch(p.tags, ctx.tags)) continue;
        if (p.reqs.len > 0 and requirements.evaluate(p.reqs, ctx, counts) != .pass) continue;
        const amount = if (p.value_cvar.len > 0)
            requirements.cvarValue(ctx, p.value_cvar)
        else switch (axis) {
            .quality => |q| itemQualityValue(p, q),
            else => curveAtAxis(p, a),
        };
        switch (p.op) {
            .base_set, .set => v = amount,
            .base_add, .add => v += amount,
            .base_subtract, .subtract => v -= amount,
            .perc_add => v *= 1.0 + amount,
            .perc_subtract => v *= 1.0 - amount,
            else => {},
        }
        if (!(v >= 0)) v = 0;
    }
    return v;
}

/// Value of a passive row at an item's quality tier. Stock seeds
/// `PassiveEffect.ModValue` with `ItemValue.Quality` and evaluates the row the
/// same way it evaluates any other axis: a row with `tier=`/`level=` anchors
/// (the 633 items.xml `tier=` rows, e.g. `PhysicalDamageResist "8,12.3"
/// tier="1,6"`) interpolates over them, and a row without anchors takes
/// ModValue's `_levels == null` branch - one value flat, two values rolled
/// (the mean here, since the sim is deterministic), more applies nothing
/// (IL_03C4). The old fall-through spread an anchor-less value list over the
/// quality range, inventing a Q1..Q6 ramp for the two-value
/// `-.2,.2` resist rolls stock randomizes per item.
fn itemQualityValue(p: Passive, q: Quality) f32 {
    if (p.curve_levels_len > 0) return curveAtAxis(p, @floatFromInt(q.level));
    // No anchors: the shape rule ignores the axis, so the quality is moot.
    return curveAtAxis(p, 0);
}

/// `PassiveEffect::hasMatchingTag` (IL=53) with the stock defaults (`MatchAnyTags`
/// is true from the ctor, `InvertTagCheck` false; the shipped files set neither
/// `match_all_tags` nor `invert_tag_check`). The query is the caller's GetValue
/// tag list, so a row matches when any of its tags is in it, an untagged row
/// always matches, and a tagged row never matches an empty query.
pub fn tagsMatch(row_tags: []const u8, query: []const u8) bool {
    if (row_tags.len == 0) return true;
    if (query.len == 0) return false;
    var it = std.mem.splitScalar(u8, row_tags, ',');
    while (it.next()) |seg| {
        const tag = std.mem.trim(u8, seg, " \t");
        if (tag.len == 0) continue;
        var qit = std.mem.splitScalar(u8, query, ',');
        while (qit.next()) |qseg| {
            if (std.mem.eql(u8, std.mem.trim(u8, qseg, " \t"), tag)) return true;
        }
    }
    return false;
}

test "lootProbFold applies tagged LootProb rows in order" {
    // perkDeadEye shape: perc_add 2..10 over levels 1..5 with the entry's tag
    // in the query. Untagged queries and unmatched tags leave the base alone.
    const rows = [_]Passive{
        .{ .name = "LootProb", .op = .perc_add, .tags = "rifleSkill", .curve = .{ 2, 4, 6, 8, 10, 0, 0, 0 }, .curve_len = 5, .curve_levels = .{ 1, 2, 3, 4, 5, 0, 0, 0 }, .curve_levels_len = 5 },
        .{ .name = "LootProb", .op = .base_set, .value = 1, .tags = "" },
    };
    var counts: requirements.Counts = .{};
    const hit: requirements.Ctx = .{ .tags = "rifleSkill" };
    // base 0.5 -> perc_add 10% at level 5 -> 0.55, then the untagged base_set 1
    // (an untagged row matches any query) replaces it with 1.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), lootProbFold(&rows, .{ .level = 5 }, hit, 0.5, &counts), 1e-4);
    // Without the tag only the untagged row applies.
    const miss: requirements.Ctx = .{ .tags = "shotgunSkill" };
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), lootProbFold(&rows, .{ .level = 5 }, miss, 0.5, &counts), 1e-4);
    // Level 0 (not purchased) short-circuits before any row.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), lootProbFold(&rows, .{ .level = 0 }, hit, 0.5, &counts), 1e-4);
    // A perc-only list scales the base: 0.5 * 1.02 = 0.51 at level 1.
    const perc_only = [_]Passive{rows[0]};
    try std.testing.expectApproxEqAbs(@as(f32, 0.51), lootProbFold(&perc_only, .{ .level = 1 }, hit, 0.5, &counts), 1e-4);
}

test "playerExpGainFold uses fraction perc_add not percent" {
    // Stock MotherLode / miner shape: Harvesting perc_add -.1..-.4 (penalty) or
    // Kill/medical fraction bonuses. Unlike LootProb, perc_add is `1+v`.
    const rows = [_]Passive{
        .{ .name = "PlayerExpGain", .op = .perc_add, .tags = "Harvesting", .curve = .{ -0.1, -0.2, -0.3, -0.4, 0, 0, 0, 0 }, .curve_len = 4, .curve_levels = .{ 1, 2, 3, 4, 0, 0, 0, 0 }, .curve_levels_len = 4 },
        .{ .name = "PlayerExpGain", .op = .perc_add, .tags = "Kill", .value = 0.05 },
    };
    var counts: requirements.Counts = .{};
    const harvest: requirements.Ctx = .{ .tags = "Harvesting" };
    // base 100 -> perc_add -0.4 at level 4 -> 60
    try std.testing.expectApproxEqAbs(@as(f32, 60.0), playerExpGainFold(&rows, .{ .level = 4 }, harvest, 100.0, &counts), 1e-4);
    // Kill tag only hits the Kill row: 100 * 1.05 = 105
    const kill: requirements.Ctx = .{ .tags = "Kill" };
    try std.testing.expectApproxEqAbs(@as(f32, 105.0), playerExpGainFold(&rows, .{ .level = 1 }, kill, 100.0, &counts), 1e-4);
    // Empty tags: tagged rows do not match
    const empty: requirements.Ctx = .{ .tags = "" };
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), playerExpGainFold(&rows, .{ .level = 4 }, empty, 100.0, &counts), 1e-4);
    // Level 0 short-circuit
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), playerExpGainFold(&rows, .{ .level = 0 }, harvest, 100.0, &counts), 1e-4);
}

test "namedPassiveFold scales GlobalGameStageModifier from base 1" {
    const rows = [_]Passive{
        .{ .name = "GlobalGameStageModifier", .op = .perc_add, .value = 0.5 },
        .{ .name = "GlobalLootStageModifier", .op = .perc_add, .value = 0.25 },
    };
    var counts: requirements.Counts = .{};
    const ctx: requirements.Ctx = .{};
    // 1 * 1.5 = 1.5
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), namedPassiveFold("GlobalGameStageModifier", &rows, .{ .level = 1 }, ctx, 1.0, &counts), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.25), namedPassiveFold("GlobalLootStageModifier", &rows, .{ .level = 1 }, ctx, 1.0, &counts), 1e-4);
    // wrong name leaves base alone
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), namedPassiveFold("BiomeGameStageModifier", &rows, .{ .level = 1 }, ctx, 1.0, &counts), 1e-4);
}

/// The level-1 (flat) variant, used by perk/attribute callers and tests.
pub fn trackedDeltasFrom(passives: []const Passive, ctx: requirements.Ctx, counts: *requirements.Counts) TrackedDeltas {
    return trackedDeltasAt(passives, .{ .level = 1 }, ctx, counts);
}

/// Fold one buff's passive_effect rows over the tracked surface at its elapsed
/// `duration_seconds` (stock's ModValue argument for a buff).
pub fn trackedDeltas(def: *const BuffDef, duration_seconds: f32, ctx: requirements.Ctx, counts: *requirements.Counts) TrackedDeltas {
    return trackedDeltasAt(def.passives, .{ .duration = duration_seconds }, ctx, counts);
}

/// Sum two delta sets (perk leg + buff leg, level-scaled).
pub fn deltasPlus(a: TrackedDeltas, b: TrackedDeltas) TrackedDeltas {
    var out = a;
    addDeltas(&out, b);
    return out;
}

/// Sum of the tracked deltas over an entity's active buffs (revertible by
/// recomputation: removing a buff drops its contribution exactly).
pub fn effectTotals(t: *const Table, set: *const components.BuffSet, ctx: requirements.Ctx, counts: *requirements.Counts) TrackedDeltas {
    var out: TrackedDeltas = .{};
    for (&set.slots) |*slot| {
        if (!slot.active) continue;
        if (t.byId(slot.def_id)) |def| {
            addDeltas(&out, trackedDeltas(&def, slot.durationSeconds(), ctx, counts));
        }
    }
    return out;
}

/// Named-passive fold over an entity's active buffs (same duration axis as
/// `effectTotals`, chained over `base`). For multiplicative passives like
/// NoiseMultiplier (passive 88) that live outside the additive tracked
/// surface: `PlayerStealth.CalcVolume`/`NotifyNoise` multiply the volume by
/// `GetValue(88)`.
pub fn namedBuffFold(t: *const Table, set: *const components.BuffSet, name: []const u8, base: f32, ctx: requirements.Ctx, counts: *requirements.Counts) f32 {
    var out = base;
    for (&set.slots) |*slot| {
        if (!slot.active) continue;
        if (t.byId(slot.def_id)) |def| {
            out = namedPassiveFold(name, def.passives, .{ .duration = slot.durationSeconds() }, ctx, out, counts);
        }
    }
    return out;
}

/// Active survival-stage state: which buffStatusHungry/Thirsty stage is in
/// effect, from buffStatusCheck01's StatComparePercCurrentToMax thresholds
/// (fractions of max). 0 = none; 1/2/3 = the buffStatus*0{1,2,3} stage.
pub const SurvivalStages = struct {
    hungry: u8 = 0,
    thirsty: u8 = 0,
};

fn stageFor(frac: f32, s0: f32, s1: f32, s2: f32) u8 {
    if (s2 > 0 and frac <= s2) return 3;
    if (s1 > 0 and frac <= s1) return 2;
    if (s0 > 0 and frac <= s0) return 1;
    return 0;
}

/// Stock drives starvation/dehydration from conditional buffs, not a fixed
/// rule: buffStatusCheck01 applies the matching stage buff on its 2 s update.
/// Stage 3 (<= 2% of max) is the damaging stage the survival loop reacts to.
pub fn survivalStages(sv: Survival, h: *const components.Health) SurvivalStages {
    const f = if (h.food_max > 0) h.food / h.food_max else 0;
    const w = if (h.water_max > 0) h.water / h.water_max else 0;
    return .{
        .hungry = stageFor(f, sv.hungry_frac[0], sv.hungry_frac[1], sv.hungry_frac[2]),
        .thirsty = stageFor(w, sv.thirsty_frac[0], sv.thirsty_frac[1], sv.thirsty_frac[2]),
    };
}

/// Name of the conditional survival buff for a stage, or null for stage 0.
pub fn stageBuffName(stage: u8, thirsty: bool) ?[]const u8 {
    if (stage < 1 or stage > 3) return null;
    return switch (stage) {
        1 => if (thirsty) "buffStatusThirsty01" else "buffStatusHungry01",
        2 => if (thirsty) "buffStatusThirsty02" else "buffStatusHungry02",
        else => if (thirsty) "buffStatusThirsty03" else "buffStatusHungry03",
    };
}

fn parseTrigger(s: []const u8) Trigger {
    if (std.mem.eql(u8, s, "onSelfBuffStart")) return .start;
    if (std.mem.eql(u8, s, "onSelfBuffUpdate")) return .update;
    if (std.mem.eql(u8, s, "onSelfBuffRemove")) return .remove;
    if (std.mem.eql(u8, s, "onSelfEnteredGame")) return .entered_game;
    if (std.mem.eql(u8, s, "onSelfFirstSpawn")) return .first_spawn;
    if (std.mem.eql(u8, s, "onSelfProgressionUpdate")) return .progression_update;
    if (std.mem.eql(u8, s, "onPerkLevelChanged")) return .perk_level_changed;
    if (std.mem.eql(u8, s, "onOtherAttackedSelf")) return .other_attacked_self;
    if (std.mem.eql(u8, s, "onSelfKilledOther")) return .killed_other;
    if (std.mem.eql(u8, s, "onSelfAttackedOther")) return .self_attacked_other;
    if (std.mem.eql(u8, s, "onSelfBuffFinish")) return .finish;
    if (std.mem.eql(u8, s, "onSelfBuffStack")) return .stack;
    if (std.mem.eql(u8, s, "onSelfLeaveGame")) return .leave_game;
    if (std.mem.eql(u8, s, "onSelfDied")) return .died;
    if (std.mem.eql(u8, s, "onSelfPrimaryActionEnd")) return .primary_action_end;
    if (std.mem.eql(u8, s, "onSelfPrimaryActionRayHit")) return .primary_action_ray_hit;
    if (std.mem.eql(u8, s, "onSelfDamagedOther")) return .self_damaged_other;
    if (std.mem.eql(u8, s, "onOtherDamagedSelf")) return .other_damaged_self;
    if (std.mem.eql(u8, s, "onCombatEntered")) return .combat_entered;
    if (std.mem.eql(u8, s, "onSelfFallImpact")) return .fall_impact;
    if (std.mem.eql(u8, s, "onSelfDamagedBlock")) return .block_damaged;
    return .other;
}

fn parseTriggeredAction(s: []const u8) TriggeredAction {
    if (std.mem.eql(u8, s, "ModifyStats")) return .modify_stats;
    if (std.mem.eql(u8, s, "AddBuff")) return .add_buff;
    if (std.mem.eql(u8, s, "RemoveBuff")) return .remove_buff;
    if (std.mem.eql(u8, s, "AddOrRemoveBuff")) return .add_or_remove_buff;
    if (std.mem.eql(u8, s, "ModifyCVar")) return .modify_cvar;
    if (std.mem.eql(u8, s, "RemoveCVar")) return .remove_cvar;
    if (std.mem.eql(u8, s, "CallGameEvent")) return .call_game_event;
    if (std.mem.eql(u8, s, "RemoveAllNegativeBuffs")) return .remove_all_negative;
    if (std.mem.eql(u8, s, "ResetProgression")) return .reset_progression;
    return .other; // RefreshPerks is a no-op here: the passive fold reads skill_levels live.
}

/// Largest number of one action's rows any single stock buff fires for one
/// event (buffs.xml): AddBuff 16 and RemoveBuff 16 (buffStatusCheck02's
/// onSelfBuffUpdate armor-set rows), ModifyStats 1. Sized above the stock
/// maximum for modlet headroom; past a cap the request is dropped and counted
/// in `truncated` (never silently applied as a shorter list).
pub const max_triggered_adds = 24;
pub const max_triggered_removes = 24;
pub const max_triggered_mods = 8;

/// The engine's outcome for one buff event: the ModifyStats deltas and the
/// AddBuff/RemoveBuff requests. Bounded arrays; the caller owns the BuffSet
/// and the wire relay. `truncated` counts requests dropped past a cap so a
/// caller can surface the bound instead of losing them silently.
pub const TriggeredResult = struct {
    mods: [max_triggered_mods]StatMod = [_]StatMod{.{}} ** max_triggered_mods,
    mod_n: u8 = 0,
    add_buffs: [max_triggered_adds][]const u8 = .{""} ** max_triggered_adds,
    remove_buffs: [max_triggered_removes][]const u8 = .{""} ** max_triggered_removes,
    add_n: u8 = 0,
    remove_n: u8 = 0,
    truncated: u8 = 0,
    /// Victim-directed adds (`target="other"`): parallel to add_buffs, same
    /// order. The caller applies these to the event's other entity.
    add_other_buffs: [max_triggered_adds][]const u8 = .{""} ** max_triggered_adds,
    add_other_n: u8 = 0,
    /// fireOneBuff flags + weights per other add: the entry's comma list is a
    /// weighted single pick, not all.
    add_other_fireone: [max_triggered_adds]bool = .{false} ** max_triggered_adds,
    add_other_weights: [max_triggered_adds][16]f32 = .{.{0} ** 16} ** max_triggered_adds,
    add_other_weights_n: [max_triggered_adds]u8 = .{0} ** max_triggered_adds,
    /// Victim-directed removes, parallel to remove_buffs.
    remove_other_buffs: [max_triggered_removes][]const u8 = .{""} ** max_triggered_removes,
    remove_other_n: u8 = 0,
    /// AoE adds (`target="otherAOE"`): buff name + row range/tags per entry.
    /// The caller scans living entities around the event's other entity.
    add_aoe_buffs: [max_triggered_adds][]const u8 = .{""} ** max_triggered_adds,
    add_aoe_range: [max_triggered_adds]f32 = .{0} ** max_triggered_adds,
    add_aoe_tags: [max_triggered_adds][]const u8 = .{""} ** max_triggered_adds,
    add_aoe_n: u8 = 0,
    /// Party adds (`target="selfOtherPlayers"` AddBuff): buff names fanned out
    /// to party/ally members by the caller.
    add_party_buffs: [max_triggered_adds][]const u8 = .{""} ** max_triggered_adds,
    add_party_n: u8 = 0,
    /// Party cvar writes (`target="selfOtherPlayers"` ModifyCVar): cvar + op
    /// + resolved value per entry, applied to each member's store.
    party_cvars: [max_triggered_adds][]const u8 = .{""} ** max_triggered_adds,
    party_cvar_ops: [max_triggered_adds]cvars.Operation = .{.set} ** max_triggered_adds,
    party_cvar_vals: [max_triggered_adds]f32 = .{0} ** max_triggered_adds,
    party_cvar_n: u8 = 0,
    /// Game-event calls (`CallGameEvent`): sequence names the caller runs
    /// through the gameevents runner.
    game_events: [max_triggered_adds][]const u8 = .{""} ** max_triggered_adds,
    game_event_n: u8 = 0,
    /// Cure-all (`RemoveAllNegativeBuffs`): the caller flags every active
    /// buff whose DamageType is set.
    remove_all_negative: bool = false,
    /// Respec (`ResetProgression`): the caller refunds SkillPoints and clears
    /// perk/attribute levels to base.
    reset_progression: bool = false,
};

/// The triggered-effect engine: evaluate one buff's `onSelf*` rows for
/// `event`, gated by the row's own `<requirement>` children through the shared
/// evaluator (fail closed: a gate it cannot resolve refuses the row and is
/// counted). Unknown triggers/actions are skipped. Bounded: the result arrays
/// cap the outcome; no allocation.
pub fn evaluateTriggered(t: *const Table, def_id: u16, event: Trigger, ctx: requirements.Ctx, counts: *requirements.Counts) TriggeredResult {
    const def = t.byId(def_id) orelse return .{};
    return evaluateRows(def.triggered, event, ctx, counts);
}

/// Evaluate one row list for `event`. Shared by the buff engine (a buff's own
/// rows) and the progression engine (progression.xml's `perkIntellectMastery`
/// `onSelfProgressionUpdate` rows write `$perkBookwormChance`), so the row
/// semantics - gate, document-order cvar writes - live in one place.
pub fn evaluateRows(rows: []const Triggered, event: Trigger, ctx: requirements.Ctx, counts: *requirements.Counts) TriggeredResult {
    var out: TriggeredResult = .{};
    for (rows) |tr| {
        if (tr.trigger != event) continue;
        // `AddOrRemoveBuff` toggles on the gates: pass adds, fail removes.
        // Every other action runs only on pass.
        if (tr.action == .add_or_remove_buff) {
            if (tr.buff.len == 0) continue;
            const pass = tr.reqs.len == 0 or requirements.evaluate(tr.reqs, ctx, counts) == .pass;
            if (pass) {
                if (out.add_n >= out.add_buffs.len) {
                    out.truncated +|= 1;
                    continue;
                }
                out.add_buffs[out.add_n] = tr.buff;
                out.add_n += 1;
                if (ctx.sink) |sk| sk.add_buff(sk.ctx, tr.buff);
            } else {
                if (out.remove_n >= out.remove_buffs.len) {
                    out.truncated +|= 1;
                    continue;
                }
                out.remove_buffs[out.remove_n] = tr.buff;
                out.remove_n += 1;
                if (ctx.sink) |sk| sk.remove_buff(sk.ctx, tr.buff);
            }
            continue;
        }
        if (tr.reqs.len > 0 and requirements.evaluate(tr.reqs, ctx, counts) != .pass) continue;
        switch (tr.action) {
            .modify_stats => {
                if (tr.op == .unknown) continue;
                if (out.mod_n >= out.mods.len) {
                    out.truncated +|= 1;
                    continue;
                }
                // `value="@cvar"` resolves at execute time against the
                // holder's store (falling-damage @.impactSpeed); missing
                // reads 0 like GetCustomVar.
                const v = if (tr.value_cvar.len > 0) requirements.cvarValue(ctx, tr.value_cvar) else tr.value;
                out.mods[out.mod_n] = .{ .stat = tr.stat, .op = tr.op, .value = v, .target_other = tr.target_other, .delay_s = tr.delay_s };
                out.mod_n += 1;
            },
            .add_buff => {
                if (tr.buff.len == 0) continue;
                if (tr.target_party) {
                    // Party adds skip every sink: the caller fans them out to
                    // party/ally members (CharismaticNature group buff).
                    if (out.add_party_n >= out.add_party_buffs.len) {
                        out.truncated +|= 1;
                        continue;
                    }
                    out.add_party_buffs[out.add_party_n] = tr.buff;
                    out.add_party_n += 1;
                    continue;
                }
                if (tr.target_other_aoe) {
                    // AoE adds skip every sink: the caller fans them out over
                    // living entities in range (no victims on update events).
                    if (out.add_aoe_n >= out.add_aoe_buffs.len) {
                        out.truncated +|= 1;
                        continue;
                    }
                    out.add_aoe_buffs[out.add_aoe_n] = tr.buff;
                    out.add_aoe_range[out.add_aoe_n] = tr.aoe_range;
                    out.add_aoe_tags[out.add_aoe_n] = tr.aoe_tags;
                    out.add_aoe_n += 1;
                    continue;
                }
                if (tr.target_other) {
                    if (out.add_other_n >= out.add_other_buffs.len) {
                        out.truncated +|= 1;
                        continue;
                    }
                    out.add_other_buffs[out.add_other_n] = tr.buff;
                    out.add_other_fireone[out.add_other_n] = tr.fire_one_buff;
                    out.add_other_weights[out.add_other_n] = tr.buff_weights;
                    out.add_other_weights_n[out.add_other_n] = tr.buff_weights_n;
                    out.add_other_n += 1;
                    // Victim-directed adds skip the self sink: the caller
                    // applies them to the event's other entity. A fireOneBuff
                    // row skips the live sink too (the weighted single pick
                    // happens in the applier; the sink would apply all).
                    if (ctx.other_sink) |sk| {
                        if (!tr.fire_one_buff) sk.add_buff(sk.ctx, tr.buff);
                    }
                    continue;
                }
                if (out.add_n >= out.add_buffs.len) {
                    out.truncated +|= 1;
                    continue;
                }
                out.add_buffs[out.add_n] = tr.buff;
                out.add_n += 1;
                // Stock applies the add as the row passes, so a later row's
                // HasBuff gate (through the live lookup) sees it.
                if (ctx.sink) |sk| sk.add_buff(sk.ctx, tr.buff);
            },
            .remove_buff => {
                if (tr.buff.len == 0) continue;
                if (tr.target_other) {
                    if (out.remove_other_n >= out.remove_other_buffs.len) {
                        out.truncated +|= 1;
                        continue;
                    }
                    out.remove_other_buffs[out.remove_other_n] = tr.buff;
                    out.remove_other_n += 1;
                    if (ctx.other_sink) |sk| sk.remove_buff(sk.ctx, tr.buff);
                    continue;
                }
                if (out.remove_n >= out.remove_buffs.len) {
                    out.truncated +|= 1;
                    continue;
                }
                out.remove_buffs[out.remove_n] = tr.buff;
                out.remove_n += 1;
                if (ctx.sink) |sk| sk.remove_buff(sk.ctx, tr.buff);
            },
            .modify_cvar => {
                // Applied as the row is scanned, in document order, so a later
                // row's gate sees this write (check02's `.ArmorLightTotal` is
                // `set @.ArmorLightLevel` then `multiply @.ArmorLightWorn`).
                // `target="other"` writes go to the victim's store when the
                // event supplies one (player client stores, or the lazy
                // per-entity column for zombies/others).
                if (tr.target_other) {
                    if (ctx.other_cvars) |ostore| {
                        if (tr.cvar.len == 0) continue;
                        const v = if (tr.value_cvar.len > 0) ostore.get(tr.value_cvar) else tr.value;
                        _ = ostore.apply(tr.cvar, tr.cvar_op, v);
                    }
                    continue;
                }
                if (tr.target_party) {
                    // Party cvar writes record for the caller's fan-out; the
                    // self write still lands through the normal path below
                    // when a store exists (stock writes self too).
                    if (out.party_cvar_n < out.party_cvars.len and tr.cvar.len > 0) {
                        const self_store = ctx.cvars;
                        const v = if (tr.value_cvar.len > 0 and self_store != null) self_store.?.get(tr.value_cvar) else tr.value;
                        out.party_cvars[out.party_cvar_n] = tr.cvar;
                        out.party_cvar_ops[out.party_cvar_n] = tr.cvar_op;
                        out.party_cvar_vals[out.party_cvar_n] = v;
                        out.party_cvar_n += 1;
                    } else if (out.party_cvar_n >= out.party_cvars.len) {
                        out.truncated +|= 1;
                    }
                }
                const store = ctx.cvars orelse continue;
                if (tr.cvar.len == 0) continue;
                // A level-curved `value="a,b,c"` indexes valueList[level-1]
                // when the event carries the row's ProgressionValue (stock
                // Execute IL: CalculatedLevel); the progression-update caller
                // supplies the changing perk's level.
                const v = if (tr.value_list_n > 0 and tr.value_cvar.len == 0)
                    tr.value_list[@min(tr.value_list_n, @max(1, ctx.progression_level orelse 1)) - 1]
                else if (tr.value_cvar.len > 0) store.get(tr.value_cvar) else tr.value;
                _ = store.apply(tr.cvar, tr.cvar_op, v);
            },
            .remove_cvar => {
                // Stock splits `cvar=` on commas into cvarNames (ParseXml IL=23);
                // every listed name is removed.
                if (tr.target_other) {
                    if (ctx.other_cvars) |ostore| {
                        if (tr.cvar.len == 0) continue;
                        var it = std.mem.splitScalar(u8, tr.cvar, ',');
                        while (it.next()) |seg| {
                            const name = std.mem.trim(u8, seg, " \t");
                            if (name.len == 0) continue;
                            _ = ostore.remove(name);
                        }
                    }
                    continue;
                }
                const store = ctx.cvars orelse continue;
                if (tr.cvar.len == 0) continue;
                var it = std.mem.splitScalar(u8, tr.cvar, ',');
                while (it.next()) |seg| {
                    const name = std.mem.trim(u8, seg, " \t");
                    if (name.len == 0) continue;
                    _ = store.remove(name);
                }
            },
            .call_game_event => {
                if (tr.game_event.len == 0) continue;
                if (out.game_event_n >= out.game_events.len) {
                    out.truncated +|= 1;
                    continue;
                }
                out.game_events[out.game_event_n] = tr.game_event;
                out.game_event_n += 1;
            },
            .remove_all_negative => {
                // Flagged in the result; the caller resolves DamageType
                // against its buff table (the engine has no table here).
                if (out.remove_all_negative) continue;
                out.remove_all_negative = true;
            },
            .reset_progression => {
                if (out.reset_progression) continue;
                out.reset_progression = true;
            },
            .add_or_remove_buff => unreachable, // handled above (toggle, not gate)
            .other => continue,
        }
    }
    return out;
}

/// Survival stage (1..3) of a conditional buff name, or null.
pub fn stageOfBuffName(name: []const u8) ?u8 {
    if (std.mem.endsWith(u8, name, "01")) return 1;
    if (std.mem.endsWith(u8, name, "02")) return 2;
    if (std.mem.endsWith(u8, name, "03")) return 3;
    return null;
}

/// SurvivalStages from the engine's wanted stage-buff names (hungry/thirsty
/// stage, 0 = none).
pub fn stagesFromWanted(wanted: []const []const u8) SurvivalStages {
    var out: SurvivalStages = .{};
    for (wanted) |name| {
        const stage = stageOfBuffName(name) orelse continue;
        if (std.mem.startsWith(u8, name, "buffStatusHungry")) out.hungry = stage;
        if (std.mem.startsWith(u8, name, "buffStatusThirsty")) out.thirsty = stage;
    }
    return out;
}

/// The buffStatusCheck01 def id (the survival stage selector's update rows),
/// or null when the table has no such buff.
pub fn survivalCheckId(t: *const Table) ?u16 {
    return t.indexOfName("buffStatusCheck01");
}

/// The armor-status buff the entity classes carry beside buffStatusCheck01
/// (entityclasses.xml `Buffs=`): its `onSelfBuffUpdate` rows grant and revoke
/// the armor-set bonuses (`ArmorGroupCount` gates, `ArmorGroupLowestQuality`
/// tiers). Selection key only; every value stays in buffs.xml.
pub fn armorCheckId(t: *const Table) ?u16 {
    return t.indexOfName("buffStatusCheck02");
}

/// Health lost per real second by a buff's `ModifyStats Health subtract`
/// triggered row (stock applies it once per update_rate; this is value / the
/// update interval in seconds, the same conversion healthLossPerSecond used).
pub fn hpLossPerSecond(def: *const BuffDef) f32 {
    const rate_ticks: f32 = @floatFromInt(@max(1, def.update_rate_ticks));
    const secs = rate_ticks / 20.0;
    for (def.stat_mods) |m| {
        if (!eqIgnoreCase(m.stat, "Health")) continue;
        if (m.op != .base_subtract and m.op != .subtract) continue;
        if (m.value <= 0 or secs <= 0) continue;
        return m.value / secs;
    }
    return 0;
}

/// Combined HP-loss rate (per real second) for the active stage-3 survival
/// buffs, evaluated through the triggered engine: each stage-3 buff's
/// `onSelfBuffUpdate` ModifyStats Health rows (requirement-gated) convert to
/// a per-second rate over the buff's update interval. Stock names stay in
/// the loader (xml-audit); the survival loop passes its resolved stages.
pub fn stage3HpLossPerSecond(t: *const Table, stages: SurvivalStages) f32 {
    var per_s: f32 = 0;
    if (stages.hungry == 3) {
        if (t.byName("buffStatusHungry03")) |d| {
            var tc: requirements.Counts = .{};
            const r = evaluateTriggered(t, t.indexOfName("buffStatusHungry03").?, .update, .{}, &tc);
            per_s = @max(per_s, triggeredHealthPerSecond(&d, &r));
        }
    }
    if (stages.thirsty == 3) {
        if (t.byName("buffStatusThirsty03")) |d| {
            var tc2: requirements.Counts = .{};
            const r = evaluateTriggered(t, t.indexOfName("buffStatusThirsty03").?, .update, .{}, &tc2);
            per_s = @max(per_s, triggeredHealthPerSecond(&d, &r));
        }
    }
    return per_s;
}

/// Sum of a triggered result's ModifyStats Health subtract rows, converted to
/// a per-second rate over the buff's update interval (value / (rate/20)).
fn triggeredHealthPerSecond(def: *const BuffDef, r: *const TriggeredResult) f32 {
    const rate_ticks: f32 = @floatFromInt(@max(1, def.update_rate_ticks));
    const secs = rate_ticks / 20.0;
    var per_s: f32 = 0;
    for (r.mods[0..r.mod_n]) |m| {
        if (!eqIgnoreCase(m.stat, "Health")) continue;
        if (m.op != .base_subtract and m.op != .subtract) continue;
        if (m.value <= 0 or secs <= 0) continue;
        per_s += m.value / secs;
    }
    return per_s;
}

/// Sum of ModifyStats Health `add` rows (AddHealth alias). Applied once per
/// firing event; subtract rows stay on the stage3 per-second path.
pub fn healthAddDelta(r: *const TriggeredResult) f32 {
    var d: f32 = 0;
    for (r.mods[0..r.mod_n]) |m| {
        // Victim-directed rows belong to the other applier, never self.
        if (m.target_other) continue;
        if (!eqIgnoreCase(m.stat, "Health")) continue;
        if (m.op != .add) continue;
        d += m.value;
    }
    return d;
}

/// Immediate Health `subtract` rows, applied once per firing event
/// (infection04 kill blow 99999999, falling-damage @.impactSpeed). Stage-3
/// hunger/thirst rows stay on the per-second path: callers pass the buff's
/// update interval and those rows are excluded here by name match.
pub fn healthSubtractOnce(r: *const TriggeredResult) f32 {
    var d: f32 = 0;
    for (r.mods[0..r.mod_n]) |m| {
        if (m.target_other) continue;
        if (!eqIgnoreCase(m.stat, "Health")) continue;
        if (m.op != .subtract) continue;
        d += m.value;
    }
    return d;
}

/// Immediate Food/Water deltas from ModifyStats rows: `subtract` applies once
/// (puking drains 50 water at start), `add` sums, `set` takes the last.
/// Victim-directed rows excluded (other applier owns them).
pub const FoodWaterDelta = struct { food: f32 = 0, water: f32 = 0, food_set: ?f32 = null, water_set: ?f32 = null };

pub fn foodWaterDelta(r: *const TriggeredResult) FoodWaterDelta {
    var out: FoodWaterDelta = .{};
    for (r.mods[0..r.mod_n]) |m| {
        if (m.target_other) continue;
        if (eqIgnoreCase(m.stat, "Food")) {
            if (m.op == .subtract) out.food -= m.value else if (m.op == .add) out.food += m.value else if (m.op == .set) out.food_set = m.value;
        } else if (eqIgnoreCase(m.stat, "Water")) {
            if (m.op == .subtract) out.water -= m.value else if (m.op == .add) out.water += m.value else if (m.op == .set) out.water_set = m.value;
        }
    }
    return out;
}

/// Immediate Stamina deltas from ModifyStats rows: `subtract` applies once
/// per firing event (radiation pool drains 20 per update), `add` sums, `set`
/// takes the last. Victim-directed rows excluded (other applier owns them).
pub const StaminaDelta = struct { delta: f32 = 0, set: ?f32 = null };

pub fn staminaDelta(r: *const TriggeredResult) StaminaDelta {
    var out: StaminaDelta = .{};
    for (r.mods[0..r.mod_n]) |m| {
        if (m.target_other) continue;
        if (!eqIgnoreCase(m.stat, "Stamina")) continue;
        if (m.op == .subtract) out.delta -= m.value else if (m.op == .add) out.delta += m.value else if (m.op == .set) out.set = m.value;
    }
    return out;
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?Table {
    return paths.tryLoadConfig("buffs.xml", Table, loadFromPath, allocator, game_dir, config_dir);
}

test "the quality axis evaluates item rows at the item's tier" {
    var counts: requirements.Counts = .{};
    // A single-segment row is level-independent (ModValue's `_levels == null`,
    // `_values.Length == 1` branch): it applies at any quality, including the 0
    // of an item with no quality tier (a plain shirt's flat row).
    var flat: Passive = .{ .name = "GeneralDamageResist", .op = .base_add, .curve_len = 1 };
    flat.curve[0] = 0.05;
    flat.value = 0.05;
    for ([_]u8{ 0, 1, 6 }) |q| {
        const d = trackedDeltasAt(&.{flat}, .{ .quality = .{ .level = q, .max = 6 } }, .{}, &counts);
        try std.testing.expectApproxEqAbs(@as(f32, 0.05), d.general_resist, 0.0001);
    }
    // Six values anchored by tier="1,2,3,4,5,6" (armorAthleticOutfit
    // HealthMax "2,4,6,8,10,20" at items.xml:14305): Q1 = 2, Q6 = 20.
    var curve: Passive = .{ .name = "HealthMax", .op = .base_add, .curve_len = 6, .curve_levels_len = 6 };
    curve.curve = .{ 2, 4, 6, 8, 10, 20, 0, 0 };
    curve.curve_levels = .{ 1, 2, 3, 4, 5, 6, 0, 0 };
    try std.testing.expectApproxEqAbs(@as(f32, 20), trackedDeltasAt(&.{curve}, .{ .quality = .{ .level = 6, .max = 6 } }, .{}, &counts).hp_max, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2), trackedDeltasAt(&.{curve}, .{ .quality = .{ .level = 1, .max = 6 } }, .{}, &counts).hp_max, 0.001);
    // A no-quality item sits below the first anchor: nothing applies (stock
    // returns from ModValue without touching the value).
    try std.testing.expectEqual(@as(f32, 0), trackedDeltasAt(&.{curve}, .{ .quality = .{ .level = 0, .max = 6 } }, .{}, &counts).hp_max);
    // Two values anchored by tier="1,6" (the armor resist row
    // PhysicalDamageResist "8,12.3" at items.xml:13620): Q1 = 8, Q6 = 12.3.
    var pair: Passive = .{ .name = "PhysicalDamageResist", .op = .base_add, .curve_len = 2, .curve_levels_len = 2 };
    pair.curve = .{ 8, 12.3, 0, 0, 0, 0, 0, 0 };
    pair.curve_levels = .{ 1, 6, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectApproxEqAbs(@as(f32, 8), trackedDeltasAt(&.{pair}, .{ .quality = .{ .level = 1, .max = 6 } }, .{}, &counts).phys_resist, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 12.3), trackedDeltasAt(&.{pair}, .{ .quality = .{ .level = 6, .max = 6 } }, .{}, &counts).phys_resist, 0.001);
    // An anchor-less two-value row is stock's per-item roll
    // (PassiveEffect::ModValue IL_0427); the deterministic sim projects the
    // mean, so the old quality spread must not come back.
    var roll: Passive = .{ .name = "PhysicalDamageResist", .op = .base_add, .curve_len = 2 };
    roll.curve = .{ -0.2, 0.2, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectApproxEqAbs(@as(f32, 0), trackedDeltasAt(&.{roll}, .{ .quality = .{ .level = 1, .max = 6 } }, .{}, &counts).phys_resist, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), trackedDeltasAt(&.{roll}, .{ .quality = .{ .level = 6, .max = 6 } }, .{}, &counts).phys_resist, 0.001);
    // Anchors come from `level=`, else `tier=`, else `duration=` in that order
    // (PassiveEffect::ParsePassiveEffect IL_01D3 / IL_026C / IL_0304), each
    // branch jumping past the attributes after it.
    const tier_row = "<passive_effect name=\"PhysicalDamageResist\" operation=\"base_add\" value=\"8,12.3\" tier=\"1,6\"/>";
    var tl: [max_curve_len]f32 = .{0} ** max_curve_len;
    try std.testing.expectEqual(@as(u8, 2), parseAnchors(tier_row, 0, &tl));
    try std.testing.expectApproxEqAbs(@as(f32, 1), tl[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 6), tl[1], 0.001);
    const all_three = "<passive_effect name=\"x\" value=\"1\" level=\"1,5\" tier=\"2,6\" duration=\"0,20\"/>";
    var al: [max_curve_len]f32 = .{0} ** max_curve_len;
    try std.testing.expectEqual(@as(u8, 2), parseAnchors(all_three, 0, &al));
    try std.testing.expectApproxEqAbs(@as(f32, 1), al[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 5), al[1], 0.001); // level=, not tier=/duration=
    const duration_row = "<passive_effect name=\"x\" value=\"1,5\" duration=\"0,3,60\"/>";
    var dl: [max_curve_len]f32 = .{0} ** max_curve_len;
    try std.testing.expectEqual(@as(u8, 3), parseAnchors(duration_row, 0, &dl));
    try std.testing.expectApproxEqAbs(@as(f32, 60), dl[2], 0.001);
}

test "stack_type parse is case-insensitive and falls back to ignore" {
    try std.testing.expectEqual(StackType.duration, parseStackType("Duration"));
    try std.testing.expectEqual(StackType.effect, parseStackType("EFFECT"));
    try std.testing.expectEqual(StackType.replace, parseStackType("replace"));
    // Absent or garbage keeps BuffClass::.ctor's Ignore default (asm.il 732691).
    try std.testing.expectEqual(StackType.ignore, parseStackType(""));
    try std.testing.expectEqual(StackType.ignore, parseStackType("stacked"));
}

test "update_rate seconds convert to stock UpdateRateTicks" {
    try std.testing.expectEqual(@as(i32, 20), parseUpdateRateTicks("1"));
    try std.testing.expectEqual(@as(i32, 10), parseUpdateRateTicks(".5"));
    try std.testing.expectEqual(@as(i32, 44), parseUpdateRateTicks("2.217")); // truncating conv.i4
    // Absent / unparsable keeps the 20-tick default.
    try std.testing.expectEqual(default_update_rate_ticks, parseUpdateRateTicks(""));
    try std.testing.expectEqual(default_update_rate_ticks, parseUpdateRateTicks("fast"));
    // Zero and negative rates cannot count down; stock stores them as-is (fires every tick).
    try std.testing.expectEqual(@as(i32, 0), parseUpdateRateTicks("0"));
    try std.testing.expectEqual(@as(i32, 0), parseUpdateRateTicks("-3"));
}

test "builtin catalog resolves by name case-insensitively" {
    var t = builtin();
    defer t.deinit();
    const id = t.indexOfName("BUFFSHOCKED").?;
    const d = t.byId(id).?;
    try std.testing.expectEqualStrings("buffShocked", d.name);
    try std.testing.expectEqual(StackType.duration, d.stack_type);
    try std.testing.expectEqual(@as(f32, 4), d.duration);
    try std.testing.expect(d.remove_on_death);
    try std.testing.expect(t.indexOfName("buffNotInCatalog") == null);
    try std.testing.expect(t.byId(@intCast(builtin_defs.len)) == null);
    // buffHarvest survives death (stock hidden console buff).
    try std.testing.expect(!t.byName("buffHarvest").?.remove_on_death);
}

test "parsed buff fields: stack, duration, update rate, remove_on_death" {
    const xml_src =
        \\<buffs>
        \\<buff name="buffShocked">
        \\<stack_type value="duration"/>
        \\<duration value="4"/>
        \\<update_rate value="1"/>
        \\</buff>
        \\<buff name="buffHarvest" hidden="true" remove_on_death="false">
        \\<stack_type value="effect"/>
        \\<duration value="0"/>
        \\<passive_effect name="HarvestCount" operation="perc_add" value="0.5"/>
        \\</buff>
        \\<buff name="buffNoStack"/>
        \\</buffs>
    ;
    const path = "worlds/zdtd_buffs_parse.xml";
    io_fs.mkdirPath("worlds");
    try io_fs.writeFile(path, xml_src);
    defer io_fs.deleteFile(path);

    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 3), t.defs.len);

    const shocked = t.byName("buffShocked").?;
    try std.testing.expectEqual(StackType.duration, shocked.stack_type);
    try std.testing.expectEqual(@as(f32, 4), shocked.duration);
    try std.testing.expectEqual(@as(i32, 20), shocked.update_rate_ticks);
    try std.testing.expect(shocked.remove_on_death);

    const harvest = t.byName("buffHarvest").?;
    try std.testing.expectEqual(StackType.effect, harvest.stack_type);
    try std.testing.expect(!harvest.remove_on_death);
    try std.testing.expectEqual(@as(usize, 1), harvest.passives.len);
    try std.testing.expectEqual(@as(f32, 0.5), t.passiveValue("buffHarvest", "HarvestCount").?);

    // No stack_type element at all: Ignore, not Replace (73 stock buffs rely on this).
    const nostack = t.byName("buffNoStack").?;
    try std.testing.expectEqual(StackType.ignore, nostack.stack_type);
    try std.testing.expectEqual(default_update_rate_ticks, nostack.update_rate_ticks);
}

/// Test-local name resolver for `requirements.BuffNames` (the same shape the
/// server's per-tick lookup uses).
const TestNames = struct {
    table: *const Table,
    fn resolve(ctx: *const anyopaque, name: []const u8) ?u16 {
        const self: *const TestNames = @ptrCast(@alignCast(ctx));
        return self.table.indexOfName(name);
    }
};

test "an AddBuff row is visible to a later row's HasBuff gate" {
    // Stock applies AddBuff as the row passes, so the stage rows' chains work
    // (each stage's onSelfBuffStart removes the others, and the highest stage
    // added wins). The engine records the request either way; with a sink and a
    // live lookup the later gate sees it in the same pass.
    const xml_src =
        \\<buffs>
        \\<buff name="check">
        \\<effect_group>
        \\<triggered_effect trigger="onSelfBuffUpdate" action="AddBuff" buff="first"/>
        \\<triggered_effect trigger="onSelfBuffUpdate" action="AddBuff" buff="second">
        \\<requirement name="HasBuff" buff="first"/>
        \\</triggered_effect>
        \\<triggered_effect trigger="onSelfBuffUpdate" action="AddBuff" buff="third">
        \\<requirement name="!HasBuff" buff="first"/>
        \\</triggered_effect>
        \\</effect_group>
        \\</buff>
        \\<buff name="first"/><buff name="second"/><buff name="third"/>
        \\</buffs>
    ;
    const path = "worlds/zdtd_buffs_live.xml";
    io_fs.mkdirPath("worlds");
    try io_fs.writeFile(path, xml_src);
    defer io_fs.deleteFile(path);
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const cid = t.indexOfName("check").?;
    var counts: requirements.Counts = .{};
    // Record only: the snapshot cannot show the add, so "second" is not
    // requested and "third" is.
    const plain = evaluateTriggered(&t, cid, .update, .{}, &counts);
    try std.testing.expectEqual(@as(u8, 2), plain.add_n);
    try std.testing.expectEqualStrings("first", plain.add_buffs[0]);
    try std.testing.expectEqualStrings("third", plain.add_buffs[1]);
    // Live: a sink applies "first" and the lookups see it.
    var active: [4]u16 = undefined;
    var active_n: usize = 0;
    const Live = struct {
        table: *const Table,
        ids: []u16,
        n: *usize,
        fn add(ctx: *const anyopaque, name: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(@constCast(ctx)));
            const id = self.table.indexOfName(name) orelse return;
            self.ids[self.n.*] = id;
            self.n.* += 1;
        }
        fn remove(ctx: *const anyopaque, name: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(@constCast(ctx)));
            const id = self.table.indexOfName(name) orelse return;
            var i: usize = 0;
            while (i < self.n.*) : (i += 1) {
                if (self.ids[i] != id) continue;
                var j = i;
                while (j + 1 < self.n.*) : (j += 1) self.ids[j] = self.ids[j + 1];
                self.n.* -= 1;
                return;
            }
        }
        fn has(ctx: *const anyopaque, name: []const u8) bool {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            const id = self.table.indexOfName(name) orelse return false;
            for (self.ids[0..self.n.*]) |a| if (a == id) return true;
            return false;
        }
    };
    var live = Live{ .table = &t, .ids = &active, .n = &active_n };
    const live_ctx = requirements.Ctx{
        .live_buff = &live,
        .buff_active = Live.has,
        .sink = .{ .ctx = &live, .add_buff = Live.add, .remove_buff = Live.remove },
    };
    const applied = evaluateTriggered(&t, cid, .update, live_ctx, &counts);
    // Row 2 now passes (`first` landed during the scan) and row 3 is refused by
    // `!HasBuff first`, which is the stock ordering the stage chain needs.
    try std.testing.expectEqual(@as(u8, 2), applied.add_n);
    try std.testing.expectEqualStrings("first", applied.add_buffs[0]);
    try std.testing.expectEqualStrings("second", applied.add_buffs[1]);
    // The sink ran in row order, so exactly those two are active.
    try std.testing.expectEqual(@as(usize, 2), active_n);
    try std.testing.expectEqual(t.indexOfName("first").?, active[0]);
    try std.testing.expectEqual(t.indexOfName("second").?, active[1]);
    try std.testing.expect(Live.has(&live, "first"));
    try std.testing.expect(Live.has(&live, "second"));
    try std.testing.expect(!Live.has(&live, "third"));
}

test "ModifyCVar applies in row order and a later row's gate sees it" {
    // Stock applies a ModifyCVar action as the row's requirements pass, so a
    // later row in the same pass reads the value an earlier row wrote
    // (check02's `.ArmorLightTotal` is `set @.ArmorLightLevel` then
    // `multiply @.ArmorLightWorn`, and the rows after it gate on the result).
    const xml_src =
        \\<buffs>
        \\<buff name="check">
        \\<effect_group>
        \\<triggered_effect trigger="onSelfBuffUpdate" action="ModifyCVar" cvar=".total" operation="set" value="4"/>
        \\<triggered_effect trigger="onSelfBuffUpdate" action="ModifyCVar" cvar=".total" operation="multiply" value="@.level"/>
        \\<triggered_effect trigger="onSelfBuffUpdate" action="ModifyCVar" cvar=".count" operation="add" value="1"/>
        \\<triggered_effect trigger="onSelfBuffUpdate" action="RemoveCVar" cvar=".gone"/>
        \\<triggered_effect trigger="onSelfBuffUpdate" action="ModifyCVar" cvar=".rolled" operation="set" value="randomint(1,5)"/>
        \\<triggered_effect trigger="onSelfBuffUpdate" action="AddBuff" buff="gated">
        \\<requirement name="CVarCompare" cvar=".total" operation="Equals" value="12"/>
        \\</triggered_effect>
        \\</effect_group>
        \\</buff>
        \\<buff name="gated"/>
        \\</buffs>
    ;
    const path = "worlds/zdtd_buffs_cvar.xml";
    io_fs.mkdirPath("worlds");
    try io_fs.writeFile(path, xml_src);
    defer io_fs.deleteFile(path);
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const cid = t.indexOfName("check").?;
    var store: cvars.Set = .{};
    _ = store.apply(".level", .set, 3);
    _ = store.apply(".gone", .set, 9);
    _ = store.apply(".rolled", .set, 7);
    var counts: requirements.Counts = .{};
    const r = evaluateTriggered(&t, cid, .update, .{ .cvars = &store }, &counts);
    // 4 * 3, with the multiply reading the value the set row just wrote.
    try std.testing.expectApproxEqAbs(@as(f32, 12), store.get(".total"), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), store.get(".count"), 0.0001);
    try std.testing.expectEqual(@as(f32, 0), store.get(".gone"));
    // The gated AddBuff row saw .total == 12 within the same pass.
    try std.testing.expectEqual(@as(u8, 1), r.add_n);
    try std.testing.expectEqualStrings("gated", r.add_buffs[0]);
    // A `randomint(...)` operand is not implemented: the row is refused, so the
    // sentinel survives instead of the row writing its unparsed 0.
    try std.testing.expectApproxEqAbs(@as(f32, 7), store.get(".rolled"), 0.0001);
    // Without a store the rows are gates-only and nothing is written.
    const no_store = evaluateTriggered(&t, cid, .update, .{}, &counts);
    try std.testing.expectEqual(@as(u8, 0), no_store.add_n);
}

test "an effect_group gate applies to its triggered rows and its passives" {
    // Before this the parser read only bare `<requirement>` children: a
    // `<requirement_group op="or">` was skipped whole (turning the gate OFF), a
    // nested group ended its parent early (elementEnd matched the first close
    // tag), and a triggered row took no effect_group gate at all, so the row
    // fired with every branch false.
    const xml_src =
        \\<buffs>
        \\<buff name="check">
        \\<effect_group>
        \\<requirement_group op="or">
        \\<requirement name="HasBuff" buff="buffA"/>
        \\<requirement_group op="and">
        \\<requirement name="HasBuff" buff="buffB"/>
        \\<requirement name="IsAlive"/>
        \\</requirement_group>
        \\</requirement_group>
        \\<requirement name="HasBuff" buff="buffC"/>
        \\<triggered_effect trigger="onSelfBuffUpdate" action="AddBuff" buff="target"/>
        \\</effect_group>
        \\<effect_group>
        \\<requirement name="HasBuff" buff="buffD"/>
        \\<passive_effect name="StaminaChangeOT" operation="base_add" value="0.5"/>
        \\</effect_group>
        \\</buff>
        \\<buff name="buffA"/><buff name="buffB"/><buff name="buffC"/><buff name="buffD"/><buff name="target"/>
        \\</buffs>
    ;
    const path = "worlds/zdtd_buffs_group.xml";
    io_fs.mkdirPath("worlds");
    try io_fs.writeFile(path, xml_src);
    defer io_fs.deleteFile(path);
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    // Every consecutive self-closing `<buff/>` loads (the walk used to resume
    // one char late and drop every second one).
    try std.testing.expectEqual(@as(usize, 6), t.defs.len);
    const cid = t.indexOfName("check").?;
    const a_id = t.indexOfName("buffA").?;
    const b_id = t.indexOfName("buffB").?;
    const c_id = t.indexOfName("buffC").?;
    const d_id = t.indexOfName("buffD").?;
    const names = requirements.BuffNames{ .ctx = &TestNames{ .table = &t }, .resolve = TestNames.resolve };
    var counts: requirements.Counts = .{};
    // The effect_group gate is (A or (B and alive)) AND C.
    const none = evaluateTriggered(&t, cid, .update, .{}, &counts);
    try std.testing.expectEqual(@as(u8, 0), none.add_n);
    const with_a = evaluateTriggered(&t, cid, .update, .{ .active_buffs = &.{a_id}, .buff_names = &names }, &counts);
    try std.testing.expectEqual(@as(u8, 0), with_a.add_n);
    const with_c = evaluateTriggered(&t, cid, .update, .{ .active_buffs = &.{c_id}, .buff_names = &names }, &counts);
    try std.testing.expectEqual(@as(u8, 0), with_c.add_n);
    const with_ac = evaluateTriggered(&t, cid, .update, .{ .active_buffs = &.{ a_id, c_id }, .buff_names = &names }, &counts);
    try std.testing.expectEqual(@as(u8, 1), with_ac.add_n);
    try std.testing.expectEqualStrings("target", with_ac.add_buffs[0]);
    const with_bc = evaluateTriggered(&t, cid, .update, .{ .active_buffs = &.{ b_id, c_id }, .buff_names = &names }, &counts);
    try std.testing.expectEqual(@as(u8, 1), with_bc.add_n);
    // The nested AND still needs IsAlive.
    const with_bc_dead = evaluateTriggered(&t, cid, .update, .{ .active_buffs = &.{ b_id, c_id }, .buff_names = &names, .alive = false }, &counts);
    try std.testing.expectEqual(@as(u8, 0), with_bc_dead.add_n);
    // The passive in the second group folds only under that group's gate.
    var set: components.BuffSet = .{};
    set.slots[0] = .{ .active = true, .def_id = cid };
    try std.testing.expectApproxEqAbs(@as(f32, 0), effectTotals(&t, &set, .{}, &counts).stamina_ot, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), effectTotals(&t, &set, .{
        .active_buffs = &.{d_id},
        .buff_names = &names,
    }, &counts).stamina_ot, 0.0001);
}

test "load buffs.xml when present" {
    const p = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/buffs.xml";
    if (!io_fs.fileExists(p)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, p);
    defer t.deinit();
    try std.testing.expect(t.defs.len > 10);
    try std.testing.expect(t.passive_pool.len > 0);
}

test "survival numbers resolve from the shipped buffs.xml" {
    const gd = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
    var t = (tryLoad(std.testing.allocator, gd, null) catch null) orelse return error.SkipZigTest;
    defer t.deinit();
    const sv = survival(&t);
    try std.testing.expect(sv.ok());
    // buffStatusCheck01 gates: Food <= .5 / .25 / .02 of max.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), sv.hungry_frac[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), sv.hungry_frac[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.02), sv.hungry_frac[2], 0.001);
    try std.testing.expect(sv.thirsty_frac[0] > 0);
    // buffStatusHungry03: ModifyStats Health subtract .25 per update.
    try std.testing.expect(sv.starve_hp_per_s > 0);
    try std.testing.expect(sv.dehydrate_hp_per_s > 0);
    // The VM folds the real rows: Hungry03's StaminaChangeOT perc_subtract
    // lands in the tracked deltas and its stage-3 Health loss rate reads off
    // the def.
    const h3 = t.byName("buffStatusHungry03").?;
    var counts: requirements.Counts = .{};
    const d3 = trackedDeltas(&h3, 1, .{}, &counts);
    try std.testing.expectApproxEqAbs(@as(f32, -0.1), d3.stamina_ot, 0.001);
    try std.testing.expectApproxEqAbs(sv.starve_hp_per_s, hpLossPerSecond(&h3), 0.0001);
    // A starved player resolves to stage 3 for both bars.
    var hh: components.Health = .{ .food_max = 100, .water_max = 100, .food = 1, .water = 1 };
    const st = survivalStages(sv, &hh);
    try std.testing.expectEqual(@as(u8, 3), st.hungry);
    try std.testing.expectEqual(@as(u8, 3), st.thirsty);
    // The triggered engine selects the same stage from check01's update rows
    // (the raw result also carries check01's other update AddBuff rows, so
    // assert the survival-relevant selection via stagesFromWanted).
    const cid = survivalCheckId(&t).?;
    var tc3: requirements.Counts = .{};
    const well = evaluateTriggered(&t, cid, .update, .{ .food_frac = 0.6, .water_frac = 0.6, .food_max = 100, .water_max = 100 }, &tc3);
    const well_st = stagesFromWanted(well.add_buffs[0..well.add_n]);
    try std.testing.expectEqual(@as(u8, 0), well_st.hungry);
    try std.testing.expectEqual(@as(u8, 0), well_st.thirsty);
    const mid = evaluateTriggered(&t, cid, .update, .{ .food_frac = 0.4, .water_frac = 0.01, .food_max = 100, .water_max = 100 }, &tc3);
    const mid_st = stagesFromWanted(mid.add_buffs[0..mid.add_n]);
    try std.testing.expectEqual(@as(u8, 1), mid_st.hungry);
    try std.testing.expectEqual(@as(u8, 3), mid_st.thirsty);
}

test "an empty table resolves to not-ok rather than to zeros that look real" {
    var t = builtin();
    defer t.deinit();
    const sv = survival(&t);
    try std.testing.expect(!sv.ok());
}

test "trackedDeltas folds the tracked surface, omits base_set and untracked names" {
    const def = BuffDef{
        .name = "testBuff",
        .passives = &.{
            .{ .name = "HealthChangeOT", .op = .base_add, .value = 2 },
            .{ .name = "StaminaChangeOT", .op = .perc_subtract, .value = 0.1 },
            .{ .name = "PhysicalDamageResist", .op = .base_add, .value = 8 },
            .{ .name = "GeneralDamageResist", .op = .base_subtract, .value = 3 },
            .{ .name = "HealthMax", .op = .base_set, .value = 150 }, // no base -> omitted
            .{ .name = "HarvestCount", .op = .base_add, .value = 3 }, // untracked
            .{ .name = "HealthMaxBlockage", .op = .base_add, .value = 12 },
            .{ .name = "StaminaMaxBlockage", .op = .base_add, .value = 7 },
        },
    };
    var counts: requirements.Counts = .{};
    const d = trackedDeltas(&def, 1, .{}, &counts);
    try std.testing.expectEqual(@as(f32, 2), d.hp_ot);
    try std.testing.expectEqual(@as(f32, -0.1), d.stamina_ot);
    try std.testing.expectEqual(@as(f32, 8), d.phys_resist);
    try std.testing.expectEqual(@as(f32, -3), d.general_resist);
    try std.testing.expectEqual(@as(f32, 0), d.hp_max); // base_set omitted
    try std.testing.expectEqual(@as(f32, 12), d.hp_block);
    try std.testing.expectEqual(@as(f32, 7), d.stamina_block);
    try std.testing.expect(d.any());
}

test "effectTotals sums active buffs and reverts exactly on removal" {
    const def = BuffDef{
        .name = "testBuff",
        .passives = &.{
            .{ .name = "HealthChangeOT", .op = .base_add, .value = 2 },
            .{ .name = "StaminaMax", .op = .base_add, .value = 10 },
        },
    };
    const defs = [_]BuffDef{def};
    const t = Table{ .defs = defs[0..] };
    var set: components.BuffSet = .{};
    set.slots[0] = .{ .active = true, .def_id = 0 };
    var counts: requirements.Counts = .{};
    const one = effectTotals(&t, &set, .{}, &counts);
    try std.testing.expectEqual(@as(f32, 2), one.hp_ot);
    try std.testing.expectEqual(@as(f32, 10), one.stamina_max);
    // A second active slot of the same def doubles the sum (additive deltas).
    set.slots[1] = .{ .active = true, .def_id = 0 };
    const two = effectTotals(&t, &set, .{}, &counts);
    try std.testing.expectEqual(@as(f32, 4), two.hp_ot);
    try std.testing.expectEqual(@as(f32, 20), two.stamina_max);
    // Removal recomputes without it: reverts exactly (revertible effects).
    set.slots[1].active = false;
    const back = effectTotals(&t, &set, .{}, &counts);
    try std.testing.expectEqual(@as(f32, 2), back.hp_ot);
    try std.testing.expectEqual(@as(f32, 10), back.stamina_max);
    set.slots[0].active = false;
    try std.testing.expect(!effectTotals(&t, &set, .{}, &counts).any());
}

test "addDeltas clamps pathological curve values to the sanity ceiling" {
    // A modded passive value of 1e38 (or inf/nan) must not reach the tick's
    // @trunc casts; the fold saturates instead.
    const def = BuffDef{
        .name = "hugeBuff",
        .passives = &.{
            .{ .name = "HealthMax", .op = .base_add, .value = 1e38 },
            .{ .name = "HealthChangeOT", .op = .base_add, .value = std.math.inf(f32) },
        },
    };
    const defs = [_]BuffDef{def};
    const t = Table{ .defs = defs[0..] };
    var set: components.BuffSet = .{};
    set.slots[0] = .{ .active = true, .def_id = 0 };
    var counts: requirements.Counts = .{};
    const totals = effectTotals(&t, &set, .{}, &counts);
    try std.testing.expectEqual(tracked_delta_max, totals.hp_max);
    try std.testing.expectEqual(tracked_delta_max, totals.hp_ot);
    // NaN folds to 0 (fail closed), and a second huge buff still saturates.
    const def2 = BuffDef{
        .name = "nanBuff",
        .passives = &.{.{ .name = "StaminaMax", .op = .base_add, .value = std.math.nan(f32) }},
    };
    const defs2 = [_]BuffDef{ def, def2 };
    const t2 = Table{ .defs = defs2[0..] };
    set.slots[1] = .{ .active = true, .def_id = 1 };
    const t2totals = effectTotals(&t2, &set, .{}, &counts);
    try std.testing.expectEqual(@as(f32, 0), t2totals.stamina_max);
    try std.testing.expectEqual(tracked_delta_max, t2totals.hp_max);
}

test "survivalStages selects the stock stage thresholds (0.5 / 0.25 / 0.02)" {
    const sv = Survival{
        .hungry_frac = .{ 0.5, 0.25, 0.02 },
        .thirsty_frac = .{ 0.5, 0.25, 0.02 },
    };
    const expect = struct {
        fn stages(sv_in: Survival, food: f32, water: f32, want_h: u8, want_w: u8) !void {
            var hh: components.Health = .{ .food_max = 100, .water_max = 100, .food = food, .water = water };
            const s = survivalStages(sv_in, &hh);
            try std.testing.expectEqual(@as(u8, want_h), s.hungry);
            try std.testing.expectEqual(@as(u8, want_w), s.thirsty);
        }
    };
    try expect.stages(sv, 60, 60, 0, 0);
    try expect.stages(sv, 50, 50, 1, 1); // <= 0.5
    try expect.stages(sv, 25, 25, 2, 2); // <= 0.25
    try expect.stages(sv, 2, 2, 3, 3); // <= 0.02
    try expect.stages(sv, 1, 99, 3, 0);
}

test "hpLossPerSecond converts the ModifyStats Health row to a per-second rate" {
    const def = BuffDef{
        .name = "buffStatusHungry03",
        .update_rate_ticks = 44, // stock update_rate 2.2 s
        .stat_mods = &.{.{ .stat = "Health", .op = .base_subtract, .value = 0.25 }},
    };
    const per_s = hpLossPerSecond(&def);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25 / 2.2), per_s, 0.0001);
}

test "stageBuffName maps stages to the stock conditional buff names" {
    try std.testing.expectEqualStrings("buffStatusHungry01", stageBuffName(1, false).?);
    try std.testing.expectEqualStrings("buffStatusHungry02", stageBuffName(2, false).?);
    try std.testing.expectEqualStrings("buffStatusHungry03", stageBuffName(3, false).?);
    try std.testing.expectEqualStrings("buffStatusThirsty01", stageBuffName(1, true).?);
    try std.testing.expectEqualStrings("buffStatusThirsty03", stageBuffName(3, true).?);
    try std.testing.expect(stageBuffName(0, false) == null);
}

test "parseCurveValue fills per-level segments; curveAt clamps and levels" {
    var c: [max_curve_len]f32 = .{0} ** max_curve_len;
    const n = parseCurveValue(".011,.022,.05,.1,.16", &c);
    try std.testing.expectEqual(@as(u8, 5), n);
    try std.testing.expectApproxEqAbs(@as(f32, 0.011), c[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.16), c[4], 0.0001);
    const p = Passive{ .curve = c, .curve_len = n };
    // No `level=`/`duration=`: stock's ModValue applies one value flat, averages
    // two, and applies nothing for more, so this anchor-less 5-value row folds
    // nothing at any level.
    try std.testing.expectEqual(@as(f32, 0), curveAt(p, 1));
    try std.testing.expectEqual(@as(f32, 0), curveAt(p, 5));
    const anchored = Passive{
        .curve = c,
        .curve_len = n,
        .curve_levels = .{ 1, 2, 3, 4, 5, 0, 0, 0 },
        .curve_levels_len = 5,
    };
    try std.testing.expectApproxEqAbs(@as(f32, 0.011), curveAt(anchored, 1), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), curveAt(anchored, 4), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.16), curveAt(anchored, 5), 0.0001);
    try std.testing.expectEqual(@as(f32, 0), curveAt(anchored, 9)); // past the last anchor
    try std.testing.expectEqual(@as(f32, 0), curveAt(anchored, 0)); // unpurchased
    // A two-value anchor-less row applies the average (ModValue IL=3C4).
    const two = Passive{ .curve = .{ 2, 4, 0, 0, 0, 0, 0, 0 }, .curve_len = 2 };
    try std.testing.expectApproxEqAbs(@as(f32, 3), curveAt(two, 1), 0.0001);
    // Single-segment rows repeat the flat value.
    var c1: [max_curve_len]f32 = .{0} ** max_curve_len;
    _ = parseCurveValue("1.5", &c1);
    const p1 = Passive{ .curve = c1, .curve_len = 1 };
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), curveAt(p1, 3), 0.0001);
}

test "trackedDeltasAt scales a perk curve to its level" {
    const passives = [_]Passive{
        .{ .name = "HealthChangeOT", .op = .base_add, .curve = .{ 0.011, 0.022, 0.05, 0.1, 0.16, 0, 0, 0 }, .curve_len = 5, .curve_levels = .{ 1, 2, 3, 4, 5, 0, 0, 0 }, .curve_levels_len = 5 },
        .{ .name = "GeneralDamageResist", .op = .base_add, .curve = .{ 0.05, 0.25, 0, 0, 0, 0, 0, 0 }, .curve_len = 2, .curve_levels = .{ 1, 5, 0, 0, 0, 0, 0, 0 }, .curve_levels_len = 2 },
    };
    var counts: requirements.Counts = .{};
    const l1 = trackedDeltasAt(&passives, .{ .level = 1 }, .{}, &counts);
    try std.testing.expectApproxEqAbs(@as(f32, 0.011), l1.hp_ot, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), l1.general_resist, 0.0001);
    const l5 = trackedDeltasAt(&passives, .{ .level = 5 }, .{}, &counts);
    try std.testing.expectApproxEqAbs(@as(f32, 0.16), l5.hp_ot, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), l5.general_resist, 0.0001); // clamp
    const l0 = trackedDeltasAt(&passives, .{ .level = 0 }, .{}, &counts);
    try std.testing.expect(!l0.any());
}

test "a buff passive folds only under its effect_group requirement" {
    // buffCoffee carries StaminaChangeOT perc_add 0.2 gated
    // `!HasBuff buffHealWaterMax` and 0.1 gated `HasBuff buffHealWaterMax`.
    // Both folded before the buff parser honoured effect_group requirements, so
    // a coffee drinker got 0.3 instead of one of the two rows.
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/buffs.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const coffee = t.indexOfName("buffCoffee").?;
    var set: components.BuffSet = .{};
    set.slots[0] = .{ .active = true, .def_id = coffee };
    const names = requirements.BuffNames{ .ctx = undefined, .resolve = struct {
        fn f(_: *const anyopaque, name: []const u8) ?u16 {
            return if (std.ascii.eqlIgnoreCase(name, "buffHealWaterMax")) 7 else null;
        }
    }.f };
    var counts: requirements.Counts = .{};
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), effectTotals(&t, &set, .{}, &counts).stamina_ot, 0.0001);
    const active_ids = [_]u16{7};
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), effectTotals(&t, &set, .{
        .active_buffs = &active_ids,
        .buff_names = &names,
    }, &counts).stamina_ot, 0.0001);
}

test "SandboxOptionBool gates a passive on the decoded sandbox option" {
    // PlayerLevelBonusApplied is a stock YesNo option whose census default is
    // Yes (SandboxOptionManager IL, option 11), and it gates buffStatusCheck01's
    // four max-stat rows. The decoded code supplies the value when it carries
    // the option; index 0 is an explicit No.
    const passives = [_]Passive{.{
        .name = "HealthMax",
        .op = .base_add,
        .value = 50,
        .reqs = &.{.{
            .kind = .sandbox_option_bool,
            .name = "SandboxOptionBool",
            .arg = "PlayerLevelBonusApplied",
        }},
    }};
    var counts: requirements.Counts = .{};
    // No code: the stock default (Yes) lets the row apply.
    try std.testing.expectApproxEqAbs(@as(f32, 50), trackedDeltasAt(&passives, .{ .level = 1 }, .{}, &counts).hp_max, 0.0001);
    try std.testing.expectEqual(@as(u32, 1), counts.resolved);
    try std.testing.expectEqual(@as(u32, 0), counts.unsupported);
    // Code index 1 = Yes, index 0 = No (even though the default is Yes).
    const on = [_]sandbox.Group{.{ .option_id = sandbox.optionByName("PlayerLevelBonusApplied").?.id, .index = 1 }};
    try std.testing.expectApproxEqAbs(@as(f32, 50), trackedDeltasAt(&passives, .{ .level = 1 }, .{ .sandbox_groups = &on }, &counts).hp_max, 0.0001);
    const off = [_]sandbox.Group{.{ .option_id = sandbox.optionByName("PlayerLevelBonusApplied").?.id, .index = 0 }};
    try std.testing.expectEqual(@as(f32, 0), trackedDeltasAt(&passives, .{ .level = 1 }, .{ .sandbox_groups = &off }, &counts).hp_max);
}

test "the stock SandboxOptionBool gates resolve instead of refusing" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/buffs.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const check = t.byName("buffStatusCheck01").?;
    var counts: requirements.Counts = .{};
    // Four max-stat rows, each gated SandboxOptionBool PlayerLevelBonusApplied.
    // They fold 0 either way (the value is a CVar reference), so the counter is
    // what proves the gate resolved rather than failed closed.
    _ = trackedDeltasAt(check.passives, .{ .level = 1 }, .{}, &counts);
    try std.testing.expectEqual(@as(u32, 4), counts.resolved);
    try std.testing.expectEqual(@as(u32, 0), counts.unsupported);
}

test "duration-anchored buff rows ramp with the elapsed seconds" {
    // buffInternalBleeding carries HealthChangeOT base_subtract
    // duration="0,3,60" value="1,5,200": the bleed ramps from 1 to 5 hp/s over
    // the first 3 s and on to 200 hp/s by 60 s (ModValue interpolates between
    // the anchors), so the folded delta is negative. The parser used to read
    // only `level=`, so the row fell into the anchor-less branch and folded a
    // constant, and the fold had no duration axis at all.
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/buffs.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const b = t.byName("buffInternalBleeding").?;
    var counts: requirements.Counts = .{};
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), trackedDeltasAt(b.passives, .{ .duration = 0 }, .{}, &counts).hp_ot, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -5.0), trackedDeltasAt(b.passives, .{ .duration = 3 }, .{}, &counts).hp_ot, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -97.368), trackedDeltasAt(b.passives, .{ .duration = 30 }, .{}, &counts).hp_ot, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -200.0), trackedDeltasAt(b.passives, .{ .duration = 60 }, .{}, &counts).hp_ot, 0.01);
    // The duration anchors really parsed (not the implicit average).
    var found = false;
    for (b.passives) |p| {
        if (!std.mem.eql(u8, p.name, "HealthChangeOT") or p.curve_levels_len == 0) continue;
        found = true;
        try std.testing.expectApproxEqAbs(@as(f32, 3), p.curve_levels[1], 0.001);
        try std.testing.expectApproxEqAbs(@as(f32, 60), p.curve_levels[2], 0.001);
    }
    try std.testing.expect(found);
    // The buff fold feeds the elapsed ticks in: 600 ticks = 30 s, 40 ticks = 2 s.
    const bleeding = t.indexOfName("buffInternalBleeding").?;
    var set: components.BuffSet = .{};
    set.slots[0] = .{ .active = true, .def_id = bleeding, .duration_ticks = 600 };
    var counts2: requirements.Counts = .{};
    try std.testing.expectApproxEqAbs(@as(f32, -97.368), effectTotals(&t, &set, .{}, &counts2).hp_ot, 0.05);
    set.slots[0].duration_ticks = 40;
    try std.testing.expectApproxEqAbs(@as(f32, -3.667), effectTotals(&t, &set, .{}, &counts2).hp_ot, 0.01);
}

test "HoldingItemHasTags gates the hold-breath stamina rows" {
    // buffHoldBreathAiming01 has two untagged StaminaChangeOT rows whose curves
    // are anchored on `duration=` (`0,1 -> -.9,-1.6` and `1,9999 -> -1.6`), so
    // they are evaluated at the buff's elapsed seconds and only one applies at a
    // time, plus four rows gated `HoldingItemHasTags tags="perkDeadEye"` with
    // `ProgressionLevel Equals 3/4/5/1`. All four used to join the untagged sum
    // (+0.75) and before the duration axis both duration rows folded together.
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/buffs.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const p = t.byName("buffHoldBreathAiming01").?;
    var counts: requirements.Counts = .{};
    // t = 0 s: only the first duration segment is live.
    try std.testing.expectApproxEqAbs(@as(f32, -0.9), trackedDeltasAt(p.passives, .{ .duration = 0 }, .{}, &counts).stamina_ot, 0.0001);
    // t = 2 s: the second segment only, and the perk rows stay out of an empty hand.
    try std.testing.expectApproxEqAbs(@as(f32, -1.6), trackedDeltasAt(p.passives, .{ .duration = 2 }, .{}, &counts).stamina_ot, 0.0001);
    // perkDeadEye 5 in hand: the Equals-5 row joins (+0.3).
    const lv5 = [_]requirements.NameLevel{.{ .name = "perkDeadEye", .level = 5 }};
    try std.testing.expectApproxEqAbs(@as(f32, -1.3), trackedDeltasAt(p.passives, .{ .duration = 2 }, .{
        .held_tags = "T0,perkDeadEye",
        .levels = &lv5,
    }, &counts).stamina_ot, 0.0001);
    // perkDeadEye 3: the Equals-3 row joins (+0.1).
    const lv3 = [_]requirements.NameLevel{.{ .name = "perkDeadEye", .level = 3 }};
    try std.testing.expectApproxEqAbs(@as(f32, -1.5), trackedDeltasAt(p.passives, .{ .duration = 2 }, .{
        .held_tags = "T0,perkDeadEye",
        .levels = &lv3,
    }, &counts).stamina_ot, 0.0001);
    // A weapon without the perk tag still gets nothing.
    try std.testing.expectApproxEqAbs(@as(f32, -1.6), trackedDeltasAt(p.passives, .{ .duration = 2 }, .{
        .held_tags = "T0,axe",
        .levels = &lv5,
    }, &counts).stamina_ot, 0.0001);
}

test "an unworn armor group refuses every biker tier" {
    // buffBikerSetBonus's six PhysicalDamageResist rows are gated
    // `ArmorGroupLowestQuality group_name="groupBiker" Equals 1..6`. With no
    // armor worn the group reads quality 0 (the stock lookup's missing-key
    // branch), so every tier refuses. All six used to fold unconditionally, so
    // a bare player read 1+2+3+4+5+6 = 21.
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/buffs.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const biker = t.indexOfName("buffBikerSetBonus").?;
    var set: components.BuffSet = .{};
    set.slots[0] = .{ .active = true, .def_id = biker };
    var counts: requirements.Counts = .{};
    const totals = effectTotals(&t, &set, .{}, &counts);
    try std.testing.expectEqual(@as(f32, 0), totals.phys_resist);
    try std.testing.expectEqual(@as(u32, 6), counts.resolved);
    try std.testing.expectEqual(@as(u32, 0), counts.unsupported);
}

test "the stock coredamageresist armor rows fold only under the armor query" {
    // Equipment::GetTotalPhysicalArmorRating (IL=887) queries passive 41 with
    // the `coredamageresist` tag. The `god` buff carries both an untagged 200
    // point PhysicalDamageResist row and a `coredamageresist`-tagged one, so the
    // untagged query sees 200 and the armor query sees both (400); the tick's
    // armor leg must use the armor query.
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/buffs.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const god = t.indexOfName("god").?;
    var set: components.BuffSet = .{};
    set.slots[0] = .{ .active = true, .def_id = god };
    var counts: requirements.Counts = .{};
    try std.testing.expectApproxEqAbs(@as(f32, 200), effectTotals(&t, &set, .{}, &counts).phys_resist, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 400), effectTotals(&t, &set, .{ .tags = "coredamageresist" }, &counts).phys_resist, 0.001);
}

test "tagsMatch follows PassiveEffect::hasMatchingTag with the stock defaults" {
    // ctor: MatchAnyTags = true, InvertTagCheck = false; no shipped row sets
    // match_all_tags or invert_tag_check.
    try std.testing.expect(tagsMatch("", ""));
    try std.testing.expect(tagsMatch("", "running")); // untagged row matches anything
    try std.testing.expect(!tagsMatch("running", "")); // tagged row never matches untagged
    try std.testing.expect(tagsMatch("running", "running"));
    try std.testing.expect(tagsMatch("running", "walking,running")); // any-set
    try std.testing.expect(tagsMatch("running,swimmingRun", "swimmingRun"));
    try std.testing.expect(!tagsMatch("running", "walking"));
    try std.testing.expect(tagsMatch("coredamageresist", "coredamageresist"));
    // Whitespace and empty segments are tolerated on both sides.
    try std.testing.expect(tagsMatch(" running , secondary ", "secondary"));
    try std.testing.expect(tagsMatch("running", " running ,"));
}

test "a tagged passive folds only for a query that carries its tag" {
    const passives = [_]Passive{
        .{ .name = "StaminaChangeOT", .op = .perc_add, .value = 0.3, .tags = "running" },
        .{ .name = "StaminaMax", .op = .base_add, .value = 25 },
        .{ .name = "PhysicalDamageResist", .op = .base_add, .value = 200, .tags = "coredamageresist" },
    };
    var counts: requirements.Counts = .{};
    const untagged = trackedDeltasAt(&passives, .{ .level = 1 }, .{}, &counts);
    try std.testing.expectEqual(@as(f32, 0), untagged.stamina_ot);
    try std.testing.expectApproxEqAbs(@as(f32, 25), untagged.stamina_max, 0.0001);
    try std.testing.expectEqual(@as(f32, 0), untagged.phys_resist);
    const running = trackedDeltasAt(&passives, .{ .level = 1 }, .{ .tags = "running" }, &counts);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), running.stamina_ot, 0.0001);
    // The untagged row matches every query, including the tagged ones.
    try std.testing.expectApproxEqAbs(@as(f32, 25), running.stamina_max, 0.0001);
    const armor = trackedDeltasAt(&passives, .{ .level = 1 }, .{ .tags = "coredamageresist" }, &counts);
    try std.testing.expectApproxEqAbs(@as(f32, 200), armor.phys_resist, 0.0001);
    try std.testing.expectEqual(@as(f32, 0), armor.stamina_ot);
}

test "a requirement-gated row is folded only when its gates pass" {
    // The stock shape that matters: perkHealingFactor's HealthChangeOT row is
    // gated `!HasBuff buffStatusHungry03,buffStatusThirsty03`, so a starving
    // player must not get the regen.
    const reqs = [_]requirements.Requirement{.{
        .kind = .has_buff,
        .negated = true,
        .name = "HasBuff",
        .list = "buffStatusHungry03,buffStatusThirsty03",
    }};
    const passives = [_]Passive{
        .{ .name = "HealthChangeOT", .op = .base_add, .curve = .{ 0.011, 0.022, 0.05, 0.1, 0.16, 0, 0, 0 }, .curve_len = 5, .curve_levels = .{ 1, 2, 3, 4, 5, 0, 0, 0 }, .curve_levels_len = 5, .reqs = &reqs },
        .{ .name = "StaminaMax", .op = .base_add, .curve = .{ 25, 50, 0, 0, 0, 0, 0, 0 }, .curve_len = 2, .curve_levels = .{ 4, 5, 0, 0, 0, 0, 0, 0 }, .curve_levels_len = 2 },
    };
    var counts: requirements.Counts = .{};
    // No active buffs: the gate passes and the row folds.
    const fed = trackedDeltasAt(&passives, .{ .level = 5 }, .{}, &counts);
    try std.testing.expectApproxEqAbs(@as(f32, 0.16), fed.hp_ot, 0.0001);
    try std.testing.expectEqual(@as(u32, 1), counts.resolved);
    // Starving: the negated HasBuff gate fails, so only the ungated row folds.
    const starving_ids = [_]u16{3};
    const names = requirements.BuffNames{ .ctx = undefined, .resolve = struct {
        fn f(_: *const anyopaque, name: []const u8) ?u16 {
            if (std.ascii.eqlIgnoreCase(name, "buffStatusThirsty03")) return 3;
            if (std.ascii.eqlIgnoreCase(name, "buffStatusHungry03")) return 4;
            return null;
        }
    }.f };
    counts = .{};
    const starving = trackedDeltasAt(&passives, .{ .level = 5 }, .{
        .active_buffs = &starving_ids,
        .buff_names = &names,
    }, &counts);
    try std.testing.expectEqual(@as(f32, 0), starving.hp_ot);
    try std.testing.expectApproxEqAbs(@as(f32, 50), starving.stamina_max, 0.0001);
    try std.testing.expectEqual(@as(u32, 1), counts.resolved);
    // A gate the evaluator cannot resolve refuses the row and is counted.
    const unsupported = [_]requirements.Requirement{.{ .kind = .unsupported, .name = "RandomRoll" }};
    const gated = [_]Passive{.{ .name = "StaminaMax", .op = .base_add, .value = 50, .reqs = &unsupported }};
    counts = .{};
    try std.testing.expect(!trackedDeltasAt(&gated, .{ .level = 5 }, .{}, &counts).any());
    try std.testing.expectEqual(@as(u32, 1), counts.unsupported);
}

test "curveValueAt interpolates the stock quality curve (Q1..Q6)" {
    // RE PassiveEffect.ModValue (IL=796): levels scaled so value[0] = Q1 and
    // value[n-1] = Q6, piecewise-linear. armorPrimitiveHelmet "8,12.3".
    const two = [_]f32{ 8, 12.3 };
    try std.testing.expectApproxEqAbs(@as(f32, 8), curveValueAt(1, 6, &two), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 12.3), curveValueAt(6, 6, &two), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 9.72), curveValueAt(3, 6, &two), 0.001); // 8 + 4.3*(2/5)
    // A 6-value curve = per-quality values (armorPreacherOutfit .02..15).
    const six = [_]f32{ 0.02, 0.04, 0.06, 0.08, 0.1, 0.15 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.02), curveValueAt(1, 6, &six), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), curveValueAt(5, 6, &six), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.15), curveValueAt(6, 6, &six), 0.0001);
    // Single value is constant; level 0 / empty curve apply nothing.
    const one = [_]f32{5};
    try std.testing.expectApproxEqAbs(@as(f32, 5), curveValueAt(4, 6, &one), 0.001);
    try std.testing.expectEqual(@as(f32, 0), curveValueAt(0, 6, &two));
    try std.testing.expectEqual(@as(f32, 0), curveValueAt(3, 6, &.{}));
}

test "a triggered action past the bounded result is counted, not silently dropped" {
    // Stock's widest row set is buffStatusCheck02's 16 onSelfBuffUpdate AddBuff
    // rows; the bound is above that on purpose, and anything past it must show
    // up in `truncated` rather than disappear.
    try std.testing.expect(max_triggered_adds >= 16);
    try std.testing.expect(max_triggered_removes >= 16);
    const over = max_triggered_adds + 3;
    const rows = comptime blk: {
        var r: [over]Triggered = undefined;
        for (&r, 0..) |*e, i| e.* = .{
            .trigger = .update,
            .action = .add_buff,
            .buff = if (i % 2 == 0) "setBonusA" else "setBonusB",
        };
        break :blk r;
    };
    const defs = [_]BuffDef{.{ .name = "check02", .triggered = &rows }};
    const t = Table{ .defs = defs[0..] };
    var counts: requirements.Counts = .{};
    const r = evaluateTriggered(&t, 0, .update, .{}, &counts);
    try std.testing.expectEqual(max_triggered_adds, r.add_n);
    try std.testing.expectEqual(@as(u8, 3), r.truncated);
    try std.testing.expectEqualStrings("setBonusA", r.add_buffs[0]);
    try std.testing.expectEqualStrings("setBonusB", r.add_buffs[max_triggered_adds - 1]);
}

test "evaluateTriggered gates, filters events, and caps the bounded actions" {
    // The stage rows are gated StatComparePercCurrentToMax on Food, now through
    // the shared requirement evaluator.
    const food_lt_50 = [_]requirements.Requirement{.{
        .kind = .stat_compare_perc_current_to_max,
        .name = "StatComparePercCurrentToMax",
        .arg = "Food",
        .op = .lt,
        .value = 0.5,
    }};
    const food_lt_2 = [_]requirements.Requirement{.{
        .kind = .stat_compare_perc_current_to_max,
        .name = "StatComparePercCurrentToMax",
        .arg = "Food",
        .op = .lt,
        .value = 0.02,
    }};
    const defs = [_]BuffDef{
        .{
            .name = "check01",
            .triggered = &.{
                .{ .trigger = .update, .action = .add_buff, .buff = "hungry01", .reqs = &food_lt_50 },
                .{ .trigger = .update, .action = .add_buff, .buff = "hungry03", .reqs = &food_lt_2 },
                .{ .trigger = .start, .action = .remove_buff, .buff = "sibling" },
                .{ .trigger = .update, .action = .other }, // recorded action: skipped
            },
        },
        .{
            .name = "buffStatusHungry03",
            .update_rate_ticks = 44,
            .triggered = &.{
                .{ .trigger = .update, .action = .modify_stats, .stat = "Health", .op = .subtract, .value = 0.25 },
            },
        },
    };
    const t = Table{ .defs = defs[0..] };
    var counts: requirements.Counts = .{};
    // Food 40%: hungry01 passes, hungry03 (2%) fails; event filter skips start.
    const r1 = evaluateTriggered(&t, 0, .update, .{ .food_frac = 0.4, .food_max = 100 }, &counts);
    try std.testing.expectEqual(@as(u8, 1), r1.add_n);
    try std.testing.expectEqualStrings("hungry01", r1.add_buffs[0]);
    try std.testing.expectEqual(@as(u8, 0), r1.remove_n);
    // Food 1%: both rows pass (bounded result keeps both).
    const r2 = evaluateTriggered(&t, 0, .update, .{ .food_frac = 0.01, .food_max = 100 }, &counts);
    try std.testing.expectEqual(@as(u8, 2), r2.add_n);
    // The start event fires the sibling removal only.
    const r3 = evaluateTriggered(&t, 0, .start, .{}, &counts);
    try std.testing.expectEqual(@as(u8, 0), r3.add_n);
    try std.testing.expectEqual(@as(u8, 1), r3.remove_n);
    try std.testing.expectEqualStrings("sibling", r3.remove_buffs[0]);
    // ModifyStats on the stage-3 buff's update.
    const r4 = evaluateTriggered(&t, 1, .update, .{}, &counts);
    try std.testing.expectEqual(@as(u8, 1), r4.mod_n);
    try std.testing.expectEqualStrings("Health", r4.mods[0].stat);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), r4.mods[0].value, 0.0001);
    // stage3HpLossPerSecond converts through the engine: 0.25 / 2.2s.
    const sv = SurvivalStages{ .hungry = 3, .thirsty = 0 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.25 / 2.2), stage3HpLossPerSecond(&t, sv), 0.0001);
}

test "AddHealth parses as ModifyStats Health add" {
    // MinEventActionAddHealth → EntityAlive.AddHealth; show_splatter is client-only.
    const xml_src =
        \\<buffs>
        \\<buff name="burn">
        \\<effect_group>
        \\<triggered_effect trigger="onSelfBuffUpdate" action="AddHealth" health="-2"/>
        \\<triggered_effect trigger="onSelfBuffStart" action="AddHealth" health="5"/>
        \\</effect_group>
        \\</buff>
        \\</buffs>
    ;
    const path = "worlds/zdtd_buffs_addhealth.xml";
    io_fs.mkdirPath("worlds");
    try io_fs.writeFile(path, xml_src);
    defer io_fs.deleteFile(path);
    var table = try loadFromPath(std.testing.allocator, path);
    defer table.deinit();
    const id = table.indexOfName("burn").?;
    var counts: requirements.Counts = .{};
    const up = evaluateTriggered(&table, id, .update, .{}, &counts);
    try std.testing.expectEqual(@as(u8, 1), up.mod_n);
    try std.testing.expectEqualStrings("Health", up.mods[0].stat);
    try std.testing.expect(up.mods[0].op == .add);
    try std.testing.expectApproxEqAbs(@as(f32, -2), up.mods[0].value, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -2), healthAddDelta(&up), 0.0001);
    const st = evaluateTriggered(&table, id, .start, .{}, &counts);
    try std.testing.expectEqual(@as(u8, 1), st.mod_n);
    try std.testing.expectApproxEqAbs(@as(f32, 5), st.mods[0].value, 0.0001);
}

test "stagesFromWanted derives the stage set from engine names" {
    const wanted = [_][]const u8{ "buffStatusHungry02", "buffStatusThirsty03" };
    const st = stagesFromWanted(&wanted);
    try std.testing.expectEqual(@as(u8, 2), st.hungry);
    try std.testing.expectEqual(@as(u8, 3), st.thirsty);
    try std.testing.expectEqual(@as(u8, 1), stageOfBuffName("buffStatusHungry01").?);
    try std.testing.expect(stageOfBuffName("buffShocked") == null);
}

test "explicit level= curve pairs evaluate piecewise-linearly" {
    // progression.xml's dominant form: level="1,5" value="2,10".
    var lv: [max_curve_len]f32 = .{0} ** max_curve_len;
    const n = parseCurveLevels("1,5", &lv);
    try std.testing.expectEqual(@as(u8, 2), n);
    try std.testing.expectApproxEqAbs(@as(f32, 1), lv[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 5), lv[1], 0.001);
    const vals = [_]f32{ 2, 10 };
    const ls = lv[0..n];
    try std.testing.expectApproxEqAbs(@as(f32, 2), curveValueAtLevels(1, ls, &vals), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 10), curveValueAtLevels(5, ls, &vals), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 6), curveValueAtLevels(3, ls, &vals), 0.001); // interpolated
    try std.testing.expectEqual(@as(f32, 0), curveValueAtLevels(0, ls, &vals));
    try std.testing.expectEqual(@as(f32, 0), curveValueAtLevels(6, ls, &vals)); // out of range
    // curveAt honors the anchors: a 4,5-anchored row applies nothing below 4.
    const p = Passive{ .curve = .{ 50, 100, 0, 0, 0, 0, 0, 0 }, .curve_len = 2, .curve_levels = .{ 4, 5, 0, 0, 0, 0, 0, 0 }, .curve_levels_len = 2 };
    try std.testing.expectEqual(@as(f32, 0), curveAt(p, 1));
    try std.testing.expectApproxEqAbs(@as(f32, 50), curveAt(p, 4), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 100), curveAt(p, 5), 0.001);
    // A single anchor applies at its own level only (PassiveEffect::ModValue
    // IL=161 compares FloorToInt(level) to FloorToInt(levels[0]), it does not
    // extrapolate). Every `<book>` row and 148 progression rows use this form,
    // so a single anchor folding 0 made read almanacs and level-1 perks no-ops.
    const one_anchor = Passive{
        .curve = .{ 0.2, 0, 0, 0, 0, 0, 0, 0 },
        .curve_len = 1,
        .curve_levels = .{ 1, 0, 0, 0, 0, 0, 0, 0 },
        .curve_levels_len = 1,
    };
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), curveAt(one_anchor, 1), 0.001);
    try std.testing.expectEqual(@as(f32, 0), curveAt(one_anchor, 2));
    try std.testing.expectEqual(@as(f32, 0), curveAt(one_anchor, 0));

    // Two anchors with a single value hold it flat across the bracket
    // (PassiveEffect::ModValue IL_0348): 305 stock rows are this shape, e.g.
    // LootProb level="2,3" value="8" and CraftingIngredientCount level="1,5"
    // value="-1". Padding the value slice to the anchor count ramped it to 0
    // instead, so perkMasterChef 3 folded LootProb 0 and resourceGlue's bone
    // cost faded out by tier 5.
    const flat = Passive{
        .curve = .{ 8, 0, 0, 0, 0, 0, 0, 0 },
        .curve_len = 1,
        .curve_levels = .{ 2, 3, 0, 0, 0, 0, 0, 0 },
        .curve_levels_len = 2,
    };
    try std.testing.expectEqual(@as(f32, 0), curveAt(flat, 1));
    try std.testing.expectApproxEqAbs(@as(f32, 8), curveAt(flat, 2), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 8), curveAt(flat, 3), 0.001);
    try std.testing.expectEqual(@as(f32, 0), curveAt(flat, 4));

    // The mirror shape - one anchor, two values - is stock's per-item roll
    // (IL_01D4 RandomRange, mean when the cached seed is 0); with the mean the
    // primitive-armor resist rows give the same value at every quality instead
    // of a Q1..Q6 ramp. No stock row uses it today, but the shapes pair.
    const roll = Passive{
        .curve = .{ -0.2, 0.2, 0, 0, 0, 0, 0, 0 },
        .curve_len = 2,
        .curve_levels = .{ 1, 0, 0, 0, 0, 0, 0, 0 },
        .curve_levels_len = 1,
    };
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), curveAt(roll, 1), 0.001);
    try std.testing.expectEqual(@as(f32, 0), curveAt(roll, 2));
}

test "AddOrRemoveBuff toggles on its gates" {
    // Stock `MinEventActionAddOrRemoveBuff` (Execute IL=11): the row gates
    // decide — pass adds, fail removes. Weather/hazard toggles ride
    // `onSelfBuffUpdate` with a CVar threshold gate.
    const rows = [_]Triggered{
        .{ .trigger = .update, .action = .add_or_remove_buff, .buff = "buffHot", .reqs = &.{} },
    };
    var counts: requirements.Counts = .{};
    // No gates: pass = add.
    const added = evaluateRows(&rows, .update, .{}, &counts);
    try std.testing.expectEqual(@as(u8, 1), added.add_n);
    try std.testing.expectEqual(@as(u8, 0), added.remove_n);
    try std.testing.expectEqualStrings("buffHot", added.add_buffs[0]);
    // A failing gate removes instead: force-fail with an unsatisfiable
    // cvar threshold (missing cvar reads 0, never >= 100).
    const gated = [_]Triggered{
        .{ .trigger = .update, .action = .add_or_remove_buff, .buff = "buffHot", .reqs = &.{
            .{ .kind = .cvar_compare, .arg = "noSuchCvarZZZ", .op = .ge, .value = 100 },
        } },
    };
    counts = .{};
    const removed = evaluateRows(&gated, .update, .{}, &counts);
    try std.testing.expectEqual(@as(u8, 0), removed.add_n);
    try std.testing.expectEqual(@as(u8, 1), removed.remove_n);
    try std.testing.expectEqualStrings("buffHot", removed.remove_buffs[0]);
}

test "ModifyStats target=other flags the victim mod" {
    // Stock buffPhysicianEuthanizer's start row sets Health on target=other
    // (instant-kill); the flag routes it to the victim applier, not self.
    const rows = [_]Triggered{
        .{ .trigger = .start, .action = .modify_stats, .stat = "Health", .op = .set, .value = -25000, .target_other = true, .reqs = &.{} },
        .{ .trigger = .start, .action = .modify_stats, .stat = "Health", .op = .add, .value = 2, .reqs = &.{} },
    };
    var counts: requirements.Counts = .{};
    const res = evaluateRows(&rows, .start, .{}, &counts);
    try std.testing.expectEqual(@as(u8, 2), res.mod_n);
    try std.testing.expect(res.mods[0].target_other);
    try std.testing.expect(!res.mods[1].target_other);
    // Self-only folds skip victim rows (SiphoningStrikes path unaffected).
    try std.testing.expectApproxEqAbs(@as(f32, 2), healthAddDelta(&res), 0.0001);
}

test "damage_type element parses onto the def" {
    // `<damage_type value>` drives RemoveAllNegativeBuffs matching.
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/buffs.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expectEqualStrings("Bashing", t.byName("buffInjuryAbrasion").?.damage_type);
    try std.testing.expectEqualStrings("bloodloss", t.byName("buffInjuryBleeding").?.damage_type);
    try std.testing.expectEqualStrings("stun", t.byName("buffHarvest").?.damage_type);
}

test "cure-all row evaluates on regen start" {
    // The regen cure row is gated PlayerLevel LT 6; level 1 passes and the
    // result flags remove_all_negative.
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/buffs.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const id = t.indexOfName("buffNearDeathRegen").?;
    var counts: requirements.Counts = .{};
    const res = evaluateTriggered(&t, id, .start, .{ .player_level = 1 }, &counts);
    try std.testing.expect(res.remove_all_negative);
}
