//! buffs.xml: metadata + passive_effect rows. Full triggered_effect VM is later.

const std = @import("std");
const arena_util = @import("../util/arena.zig");
const xml = @import("xml_util.zig");
const paths = @import("paths.zig");
const requirements = @import("requirements.zig");
const cvars = @import("cvars.zig");
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

pub const triggered_mod = @import("triggered.zig");
pub const max_triggered_per_buff: usize = triggered_mod.max_triggered_per_buff;
pub const max_triggered_total: usize = triggered_mod.max_triggered_total;
pub const Trigger = triggered_mod.Trigger;
pub const TriggeredAction = triggered_mod.TriggeredAction;
pub const Triggered = triggered_mod.Triggered;
pub const max_triggered_adds = triggered_mod.max_triggered_adds;
pub const max_triggered_removes = triggered_mod.max_triggered_removes;
pub const max_triggered_mods = triggered_mod.max_triggered_mods;
pub const TriggeredResult = triggered_mod.TriggeredResult;
pub const evaluateTriggered = triggered_mod.evaluateTriggered;
pub const evaluateRows = triggered_mod.evaluateRows;
pub const parseTrigger = triggered_mod.parseTrigger;
pub const parseTriggeredAction = triggered_mod.parseTriggeredAction;

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
    name_index: std.StringHashMapUnmanaged(u16) = .empty,

    pub fn empty() Table {
        return .{};
    }

    pub fn deinit(self: *Table) void {
        self.defs = &.{};
        self.passive_pool = &.{};
        arena_util.destroyHolder(&self.arena_ptr);

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
pub fn parseStackType(s: []const u8) StackType {
    if (std.ascii.eqlIgnoreCase(s, "duration")) return .duration;
    if (std.ascii.eqlIgnoreCase(s, "effect")) return .effect;
    if (std.ascii.eqlIgnoreCase(s, "replace")) return .replace;
    return .ignore;
}

/// update_rate seconds → UpdateRateTicks (asm.il 1371556: ParseFloat * 20, conv.i4).
pub fn parseUpdateRateTicks(s: []const u8) i32 {
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

pub const buff_curve = @import("buff_curve.zig");
pub const firstF32 = buff_curve.firstF32;
pub const parseCurveValue = buff_curve.parseCurveValue;
pub const curveValueAt = buff_curve.curveValueAt;
pub const curveValueAtLevels = buff_curve.curveValueAtLevels;
pub const curveAtAxis = buff_curve.curveAtAxis;
pub const curveAt = buff_curve.curveAt;
pub const parseCurveLevels = buff_curve.parseCurveLevels;
pub const parseAnchors = buff_curve.parseAnchors;
pub const Axis = buff_curve.Axis;
pub const Quality = buff_curve.Quality;
const parseWeights = buff_curve.parseWeights;
const weightsCount = buff_curve.weightsCount;
const parseValueList = buff_curve.parseValueList;

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
            // `GiveExp` carries its amount in `exp=`, not `value=`.
            .value = if (is_add_health) firstF32(health_s) else if (act == .give_exp) firstF32(xml.attr(body, ri, "exp") orelse "0") else firstF32(val_s),
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
    var name_index: std.StringHashMapUnmanaged(u16) = .empty;
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

/// Health lost per real second by `buff_name`'s ModifyStats Health row.
fn healthLossPerSecond(t: *const Table, buff_name: []const u8) f32 {
    const d = t.byName(buff_name) orelse return 0;
    const rate_ticks: f32 = @floatFromInt(@max(1, d.update_rate_ticks));
    const secs = rate_ticks / 20.0; // update_rate is stored in 20 TPS ticks
    for (d.stat_mods) |m| {
        if (!std.ascii.eqlIgnoreCase(m.stat, "Health")) continue;
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
            if (std.ascii.eqlIgnoreCase(th.stat, "Food") and std.mem.find(u8, th.buff, "Hungry") != null) {
                out.hungry_frac[stage] = th.value;
            } else if (std.ascii.eqlIgnoreCase(th.stat, "Water") and std.mem.find(u8, th.buff, "Thirsty") != null) {
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
/// `perc_subtract` use stock's fraction form (`1 +/- v`), PlayerExpGain rows
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
            // Passive tags are matched case-insensitively (stock FastTags):
            // the query carries the incoming buff's own name
            // (BuffResistance vs `buffInjuryStunned01`-style tags).
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, qseg, " \t"), tag)) return true;
        }
    }
    return false;
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

/// Health lost per real second by a buff's `ModifyStats Health subtract`
/// triggered row (stock applies it once per update_rate; this is value / the
/// update interval in seconds, the same conversion healthLossPerSecond used).
pub fn hpLossPerSecond(def: *const BuffDef) f32 {
    const rate_ticks: f32 = @floatFromInt(@max(1, def.update_rate_ticks));
    const secs = rate_ticks / 20.0;
    for (def.stat_mods) |m| {
        if (!std.ascii.eqlIgnoreCase(m.stat, "Health")) continue;
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
        if (!std.ascii.eqlIgnoreCase(m.stat, "Health")) continue;
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
        if (!std.ascii.eqlIgnoreCase(m.stat, "Health")) continue;
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
        if (!std.ascii.eqlIgnoreCase(m.stat, "Health")) continue;
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
        if (std.ascii.eqlIgnoreCase(m.stat, "Food")) {
            if (m.op == .subtract) out.food -= m.value else if (m.op == .add) out.food += m.value else if (m.op == .set) out.food_set = m.value;
        } else if (std.ascii.eqlIgnoreCase(m.stat, "Water")) {
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
        if (!std.ascii.eqlIgnoreCase(m.stat, "Stamina")) continue;
        if (m.op == .subtract) out.delta -= m.value else if (m.op == .add) out.delta += m.value else if (m.op == .set) out.set = m.value;
    }
    return out;
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?Table {
    return paths.tryLoadConfig("buffs.xml", Table, loadFromPath, allocator, game_dir, config_dir);
}
