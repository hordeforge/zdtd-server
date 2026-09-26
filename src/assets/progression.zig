//! progression.xml: level curve + attribute/perk/book catalog (names, max
//! levels, costs) + the perk/attribute/book passive_effect rows (the surface
//! the passive-effects VM folds over its tracked stats) with the `<requirement>`
//! gates stock applies to each row. Requirement evaluation lives in
//! `requirements.zig`; effect application is progressive.

const std = @import("std");
const arena_util = @import("../util/arena.zig");
const xml = @import("xml_util.zig");
const paths = @import("paths.zig");
const buffs = @import("buffs.zig");
const requirements = @import("requirements.zig");

// zdtd storage bounds, not stock rules; stock has no limit on either. Measured
// against V3.2.0 `Data/Config` (2026-09-04): progression.xml defines 8
// attributes and 57 perks, so both caps carry large headroom for modlets.
pub const max_attrs: usize = 16;
pub const max_perks: usize = 512;
pub const max_skills: usize = 64; // crafting skills (stock 23)
/// passive_effect rows per perk/attribute body (stock bodies stay well under).
pub const max_passives_per_def: usize = 32;
/// `triggered_effect` rows per perk/attribute body. Stock's heaviest body is
/// `perkIntellectMastery` with a handful of cvar rows; sized above it.
pub const max_triggered_per_def: usize = 12;

/// Level-curve defaults used before progression.xml loads (stock XML wins at
/// runtime; assets/progression.zig parses the shipped curve). These mirror the
/// stock geometric curve: 300 max level, 10k base XP, x1.05 multiplier, 1 skill
/// point per level, cost clamp at level 60.
pub const LevelCurve = struct {
    max_level: u16 = 300,
    exp_to_level: u32 = 10000,
    experience_multiplier: f32 = 1.05,
    skill_points_per_level: u16 = 1,
    clamp_exp_cost_at_level: u16 = 60,
    loaded: bool = false,

    /// XP required to go from `level` to level+1. Stock
    /// Progression.GetExpForNextLevel (7dtd-engine-research docs/progression.md XP
    /// curve, Progression.il.txt 1083482/1083513): conv.r4 BaseExpToLevel *
    /// Mathf.Pow(ExpMultiplier, Clamp(level+1, 0, ClampExpCostAtLevel)).
    /// Mathf.Pow computes in double and casts to float, so the multiply is
    /// float32; Math.Min(.., 2.147484e9f) then conv.i4 saturates at
    /// int.MaxValue. Players start at level 1, so level 1->2 is
    /// 10000 * 1.05f^2 = 11024 for the stock 10000/1.05/60 defaults.
    pub fn expForLevel(self: LevelCurve, level: u16) u64 {
        const clamp_l = if (self.clamp_exp_cost_at_level == 0) self.max_level else self.clamp_exp_cost_at_level;
        const exp: f32 = @floatFromInt(@min(@as(u32, level) + 1, @as(u32, clamp_l)));
        const powf: f32 = @floatCast(std.math.pow(
            f64,
            self.experience_multiplier,
            exp,
        ));
        const cost: f32 = @as(f32, @floatFromInt(self.exp_to_level)) * powf;
        if (!std.math.isFinite(cost)) return if (std.math.isNan(cost)) 0 else std.math.maxInt(i32);
        if (cost >= 2147483648.0) return std.math.maxInt(i32);
        if (cost <= 0) return 0;
        return @trunc(cost);
    }
};

/// One `<level_requirements level="N">` gate: the requirements to raise the
/// value to level N. `ProgressionClass::GetCalculatedMaxLevel` (IL=343) takes
/// the highest level whose gate passes, which is the level the stock skill UI
/// lets a player buy up to.
pub const LevelReq = struct {
    level: u8 = 0,
    reqs: []const requirements.Requirement = &.{},
};

pub const AttrDef = struct {
    name: []const u8 = "",
    min_level: u8 = 1,
    max_level: u8 = 10,
    base_cost: u16 = 1,
    cost_mult: f32 = 1.14,
    /// passive_effect rows in the attribute body (progression.xml). The VM
    /// folds the tracked subset (buffs.trackedDeltasFrom); attribute state is
    /// not applied yet (perk runtime open), parsed so the surface is data.
    passives: []const buffs.Passive = &.{},
    /// `triggered_effect` rows in the attribute body (progression.xml), each
    /// with its effect_group's gates. Parsed so the surface is data; the
    /// `onSelfProgressionUpdate` event fires them when the level changes.
    triggered: []const buffs.Triggered = &.{},
    /// `<level_requirements>` gates, one per block in file order (stock: every
    /// attribute's levels 1..10, each gated on PlayerLevel).
    level_reqs: []const LevelReq = &.{},
    /// `override_cost="1,2,2"` per-level cost table (ProgressionClass
    /// OverrideCost, IL=423). Empty = use CalculatedCostForLevel.
    override_cost: []const u16 = &.{},
};

/// Perk catalog row; max_level default 5 before progression.xml loads (stock
/// XML ships per-perk max levels via <perk max_level="...">). A `<book>` block
/// parses into the same row: same attributes, same `<effect_group>` children,
/// and a book is a progression value items.xml grants via
/// SetProgressionLevel(-1).
pub const PerkDef = struct {
    name: []const u8 = "",
    max_level: u8 = 5,
    /// Parent attribute/skill name if nested under one; empty if free. Stock
    /// uses it for UI grouping (it is a `<skill>` name, which is never
    /// levelled); the purchase gate is `level_reqs`, not this.
    parent_attr: []const u8 = "",
    /// True when the row came from a `<book>` block: a book is granted by
    /// reading its item, never bought with skill points.
    book: bool = false,
    /// Skill-point cost of the first level and the per-level multiplier. A
    /// row's own attributes win over the `<perks>` container's (stock container:
    /// 1 / 1; 7 stock perks replace both with `override_cost`).
    base_cost: u16 = 1,
    cost_mult: f32 = 1.0,
    /// passive_effect rows in the perk body (progression.xml). The VM folds
    /// the tracked subset (buffs.trackedDeltasFrom) gated by each row's
    /// requirements; perk state is not applied yet (perk runtime open), parsed
    /// so the effect surface is data.
    passives: []const buffs.Passive = &.{},
    /// `triggered_effect` rows in the perk body (progression.xml). Stock's
    /// `perkIntellectMastery` uses `onSelfProgressionUpdate` + ModifyCVar to
    /// maintain `$perkBookwormChance`; the loot RandomRoll gates read it.
    triggered: []const buffs.Triggered = &.{},
    /// `<level_requirements>` gates, one per block in file order (50 stock
    /// perks carry them, all gated on ProgressionLevel/PlayerLevel).
    level_reqs: []const LevelReq = &.{},
    /// `override_cost="1,2,2,2,3"` per-level cost table, replacing
    /// CalculatedCostForLevel (ProgressionClass OverrideCost, IL=423).
    override_cost: []const u16 = &.{},
};

/// One `<unlock_entry item="a,b" unlock_tier="N"/>` row: the named items'
/// recipes unlock when the parent crafting skill reaches `level` (the tier
/// resolved through its own display_entry's `unlock_level` comma list).
pub const UnlockEntry = struct {
    items: []const u8 = "",
    /// Required crafting-skill level (resolved from the display_entry tier).
    level: u8 = 0,
};

/// One `<crafting_skill name max_level parent>` block with its unlock_entry
/// gates.
pub const CraftingSkill = struct {
    name: []const u8 = "",
    max_level: u16 = 100,
    entries: []const UnlockEntry = &.{},
    /// `<effect_group>` passive rows on the skill. `CraftingTier` (passive 91)
    /// rows produce the crafted output's quality tier for the recipes whose tag
    /// set carries this skill's name (`Recipe.GetCraftingTier` IL=22: base 1,
    /// folded at the skill's purchased level, tag-filtered by the recipe's
    /// tags); `RecipeTagUnlocked` (73) rows are the unlock gate.
    passives: []const buffs.Passive = &.{},
};

pub const Table = struct {
    curve: LevelCurve = .{},
    attributes: []const AttrDef = &.{},
    perks: []const PerkDef = &.{},
    /// `<perks>` cost defaults the rows inherited (stock 1 / 1).
    perk_base_cost: u16 = 1,
    perk_cost_mult: f32 = 1.0,
    /// crafting_skill blocks with their unlock_entry gates (progression.xml).
    crafting_skills: []const CraftingSkill = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,

    pub fn empty() Table {
        return .{};
    }

    pub fn deinit(self: *Table) void {
        arena_util.destroyHolder(&self.arena_ptr);
        self.* = .{};
    }

    /// Stock `ProgressionClass::GetCalculatedMaxLevel` (IL=343) over a catalog
    /// row's `<level_requirements>`: the highest level whose gate passes (a
    /// block with no `<requirement>` children has a null RequirementGroup and
    /// passes, `canRun` IL=286). A row with no level gates answers its catalog
    /// `max_level`, which is the IL's non-attribute branch. Null for an unknown
    /// name.
    ///
    /// The shipped gates use only `ProgressionLevel` and `PlayerLevel` (301
    /// blocks: 250 + 51), so the context carries the ledger and the player
    /// level. Any other kind fails closed and holds the level at 0, which
    /// refuses the purchase rather than granting a level stock would gate.
    pub fn calculatedMaxLevel(
        self: *const Table,
        levels: []const SkillLevel,
        player_level: u16,
        name: []const u8,
    ) ?u8 {
        const ctx = requirements.Ctx{ .levels = levels, .player_level = player_level };
        var counts: requirements.Counts = .{};
        for (self.attributes) |a| {
            if (!std.mem.eql(u8, a.name, name)) continue;
            return highestPassingLevel(a.level_reqs, a.max_level, ctx, &counts);
        }
        for (self.perks) |pk| {
            if (!std.mem.eql(u8, pk.name, name)) continue;
            return highestPassingLevel(pk.level_reqs, pk.max_level, ctx, &counts);
        }
        return null;
    }
};

/// Curve-only load (fallback when the full table parse fails). Parses the file
/// once, lightly, and does not build or leak the attribute/perk arena.
pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !LevelCurve {
    const clean = try xml.readCleanFile(allocator, path);
    defer allocator.free(clean);
    return parseCurve(clean);
}

fn parseCurve(clean: []const u8) LevelCurve {
    var c: LevelCurve = .{};
    const li = std.mem.find(u8, clean, "<level ") orelse return c;
    if (xml.attr(clean, li, "max_level")) |v| c.max_level = std.fmt.parseInt(u16, v, 10) catch c.max_level;
    if (xml.attr(clean, li, "exp_to_level")) |v| c.exp_to_level = std.fmt.parseInt(u32, v, 10) catch c.exp_to_level;
    if (xml.attr(clean, li, "experience_multiplier")) |v| c.experience_multiplier = std.fmt.parseFloat(f32, v) catch c.experience_multiplier;
    if (xml.attr(clean, li, "skill_points_per_level")) |v| c.skill_points_per_level = std.fmt.parseInt(u16, v, 10) catch c.skill_points_per_level;
    if (xml.attr(clean, li, "clamp_exp_cost_at_level")) |v| c.clamp_exp_cost_at_level = std.fmt.parseInt(u16, v, 10) catch c.clamp_exp_cost_at_level;
    c.loaded = true;
    return c;
}

/// One purchased progression value (attribute/perk/book) on a player. Shared
/// with the server Client ledger (server/game/types.zig) so the VM can fold the
/// player's perk levels directly, and with the requirement evaluator, whose
/// `ProgressionLevel` gate reads exactly this shape.
pub const SkillLevel = requirements.NameLevel;

/// Level-scaled tracked deltas for one purchased progression value: folds its
/// passive rows at `level` (curve segment i applies at level i+1), gated by the
/// row requirements. Revertible by recompute-from-set like the buff VM
/// (removing the level drops its deltas exactly).
pub fn trackedDeltasAtLevel(
    def: anytype,
    level: u8,
    ctx: requirements.Ctx,
    counts: *requirements.Counts,
) buffs.TrackedDeltas {
    return buffs.trackedDeltasAt(def.passives, .{ .level = level }, ctx, counts);
}

/// A row's highest passing `<level_requirements>` level, or `catalog_max` when
/// the row carries no gates (see `Table.calculatedMaxLevel`).
fn highestPassingLevel(
    level_reqs: []const LevelReq,
    catalog_max: u8,
    ctx: requirements.Ctx,
    counts: *requirements.Counts,
) u8 {
    if (level_reqs.len == 0) return catalog_max;
    var best: u8 = 0;
    for (level_reqs) |lr| {
        if (lr.reqs.len > 0 and requirements.evaluate(lr.reqs, ctx, counts) != .pass) continue;
        if (lr.level > best) best = lr.level;
    }
    return best;
}

/// Combined tracked deltas over a player's purchased progression levels
/// (attributes + perks + books). No allocation; the fold is bounded by the
/// skill-level ledger cap. `ctx` carries the live player state the row gates
/// read; `counts` accumulates the gate accounting for the caller's counters.
pub fn perkTotals(
    pt: *const Table,
    skill_levels: []const SkillLevel,
    ctx: requirements.Ctx,
    counts: *requirements.Counts,
) buffs.TrackedDeltas {
    var out: buffs.TrackedDeltas = .{};
    for (skill_levels) |sl| {
        if (sl.level == 0) continue;
        var found = false;
        for (pt.attributes) |a| {
            if (std.mem.eql(u8, a.name, sl.name)) {
                out = buffs.deltasPlus(out, trackedDeltasAtLevel(&a, sl.level, ctx, counts));
                found = true;
                break;
            }
        }
        if (found) continue;
        for (pt.perks) |pk| {
            if (std.mem.eql(u8, pk.name, sl.name)) {
                out = buffs.deltasPlus(out, trackedDeltasAtLevel(&pk, sl.level, ctx, counts));
                break;
            }
        }
    }
    return out;
}

/// Named-passive fold over a player's purchased progression levels, chained
/// over `base` (mirrors `perkTotals` but for multiplicative passives outside
/// the additive tracked surface, e.g. NoiseMultiplier passive 88).
pub fn namedPerkFold(
    pt: *const Table,
    skill_levels: []const SkillLevel,
    name: []const u8,
    base: f32,
    ctx: requirements.Ctx,
    counts: *requirements.Counts,
) f32 {
    var out = base;
    for (skill_levels) |sl| {
        if (sl.level == 0) continue;
        var found = false;
        for (pt.attributes) |a| {
            if (std.mem.eql(u8, a.name, sl.name)) {
                out = buffs.namedPassiveFold(name, a.passives, .{ .level = sl.level }, ctx, out, counts);
                found = true;
                break;
            }
        }
        if (found) continue;
        for (pt.perks) |pk| {
            if (std.mem.eql(u8, pk.name, sl.name)) {
                out = buffs.namedPassiveFold(name, pk.passives, .{ .level = sl.level }, ctx, out, counts);
                break;
            }
        }
    }
    return out;
}

/// One body's direct `<level_requirements level="N">` children.
/// `ProgressionFromXml` (IL=660) gives each block an `N` and a RequirementGroup
/// built from its own direct `<requirement>` children (null when the block has
/// no child elements), and `ProgressionClass::GetCalculatedMaxLevel` (IL=343)
/// keeps the highest level whose group passes.
fn scanLevelReqs(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    body: []const u8,
    out: *std.ArrayList(LevelReq),
) !void {
    var i: usize = 0;
    while (i < body.len) {
        const lt = std.mem.findPos(u8, body, i, "<level_requirements") orelse break;
        var level: u8 = 0;
        if (xml.attr(body, lt, "level")) |v| level = std.fmt.parseInt(u8, v, 10) catch 0;
        const gt = std.mem.findPos(u8, body, lt, ">") orelse break;
        var reqs: std.ArrayList(requirements.Requirement) = .empty;
        defer reqs.deinit(allocator);
        if (!(gt > lt and body[gt - 1] == '/')) {
            try requirements.scanRequirements(allocator, arena, body, lt, &reqs);
        }
        const slice = try arena.alloc(requirements.Requirement, reqs.items.len);
        @memcpy(slice, reqs.items);
        try out.append(allocator, .{ .level = level, .reqs = slice });
        i = requirements.elementEnd(body, lt);
    }
}

/// Clone an ArrayList's items into an arena slice (the catalog owns its data).
fn arenaSlice(arena: std.mem.Allocator, comptime T: type, list: []const T) ![]const T {
    const out = try arena.alloc(T, list.len);
    @memcpy(out, list);
    return out;
}

/// `<row override_cost="1,2,2,3"/>`: ProgressionClass.OverrideCost, a per-level
/// cost table that replaces CalculatedCostForLevel (IL=423). Empty when the row
/// has no override.
fn parseOverrideCost(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    body: []const u8,
    tag: usize,
) ![]const u16 {
    const s = xml.attr(body, tag, "override_cost") orelse return &.{};
    var buf: std.ArrayList(u16) = .empty;
    defer buf.deinit(allocator);
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |seg| {
        const t = std.mem.trim(u8, seg, " \t");
        if (t.len == 0) continue;
        try buf.append(allocator, std.fmt.parseInt(u16, t, 10) catch 0);
    }
    return arenaSlice(arena, u16, buf.items);
}

/// Append the `<passive_effect>` whose open tag starts at `tag`, retaining the
/// curve rows. Only called for a tag whose `name` exists.
fn appendPassive(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    body: []const u8,
    tag: usize,
    pool: *std.ArrayList(buffs.Passive),
) !void {
    const en = xml.attr(body, tag, "name") orelse return;
    const op_s = xml.attr(body, tag, "operation") orelse "base_add";
    const val_s = xml.attr(body, tag, "value") orelse "0";
    var curve: [buffs.max_curve_len]f32 = .{0} ** buffs.max_curve_len;
    const curve_len = buffs.parseCurveValue(val_s, &curve);
    var curve_levels: [buffs.max_curve_len]f32 = .{0} ** buffs.max_curve_len;
    const curve_levels_len = buffs.parseAnchors(body, tag, &curve_levels);
    try pool.append(allocator, .{
        .name = try arena.dupe(u8, en),
        .op = buffs.parseOp(op_s),
        .value = curve[0],
        .tags = try arena.dupe(u8, xml.attr(body, tag, "tags") orelse ""),
        .curve = curve,
        .curve_len = curve_len,
        .curve_levels = curve_levels,
        .curve_levels_len = curve_levels_len,
    });
}

/// Append one gated passive row: the caller's accumulated group gates followed
/// by the row's own nested ones, recorded as one contiguous range.
fn appendGatedPassive(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    body: []const u8,
    tag: usize,
    group_reqs: []const requirements.Requirement,
    pool: *std.ArrayList(buffs.Passive),
    req_pool: *std.ArrayList(requirements.Requirement),
    req_ranges: *std.ArrayList([2]usize),
) !void {
    if (xml.attr(body, tag, "name") == null) return;
    const r0 = req_pool.items.len;
    for (group_reqs) |r| try req_pool.append(allocator, r);
    try requirements.scanRequirements(allocator, arena, body, tag, req_pool);
    try req_ranges.append(allocator, .{ r0, req_pool.items.len - r0 });
    try appendPassive(allocator, arena, body, tag, pool);
}

/// One `<effect_group>` body: the group's direct `<requirement>` children apply
/// to every passive in it (MinEffectGroup::ParseXml IL=103 builds one
/// RequirementGroup for the element, not a running per-row list), and each row
/// may add its own. `passive_limit` is the absolute pool index the caller's
/// `max_passives_per_def` budget ends at.
fn scanEffectGroup(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    g: []const u8,
    pool: *std.ArrayList(buffs.Passive),
    req_pool: *std.ArrayList(requirements.Requirement),
    req_ranges: *std.ArrayList([2]usize),
    passive_limit: usize,
) !void {
    var group_reqs: std.ArrayList(requirements.Requirement) = .empty;
    defer group_reqs.deinit(allocator);
    try requirements.scanChildren(allocator, arena, g, 0, g.len, &group_reqs);
    var i: usize = 0;
    while (i < g.len and pool.items.len < passive_limit) {
        const lt = std.mem.findPos(u8, g, i, "<") orelse break;
        if (std.mem.startsWith(u8, g[lt..], "</")) break;
        if (std.mem.startsWith(u8, g[lt..], "<passive_effect")) {
            try appendGatedPassive(allocator, arena, g, lt, group_reqs.items, pool, req_pool, req_ranges);
        }
        i = requirements.elementEnd(g, lt);
    }
}

/// Scan a perk/attribute/book body for `<passive_effect>` rows with the gates
/// stock applies to them. Rows inside an `<effect_group>` take that group's
/// direct requirements; a row outside any group takes only its own.
fn scanPassives(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    body: []const u8,
    pool: *std.ArrayList(buffs.Passive),
    req_pool: *std.ArrayList(requirements.Requirement),
    req_ranges: *std.ArrayList([2]usize),
) !void {
    const p0 = pool.items.len;
    var i: usize = 0;
    while (i < body.len and pool.items.len - p0 < max_passives_per_def) {
        const lt = std.mem.findPos(u8, body, i, "<") orelse break;
        if (std.mem.startsWith(u8, body[lt..], "</")) break;
        if (std.mem.startsWith(u8, body[lt..], "<effect_group")) {
            const gt = std.mem.findPos(u8, body, lt, ">") orelse break;
            if (gt > lt and body[gt - 1] == '/') {
                i = gt + 1;
                continue;
            }
            const close = std.mem.findPos(u8, body, gt, "</effect_group>") orelse break;
            try scanEffectGroup(allocator, arena, body[gt + 1 .. close], pool, req_pool, req_ranges, p0 + max_passives_per_def);
            i = close + "</effect_group>".len;
            continue;
        }
        if (std.mem.startsWith(u8, body[lt..], "<passive_effect")) {
            try appendGatedPassive(allocator, arena, body, lt, &.{}, pool, req_pool, req_ranges);
        }
        i = requirements.elementEnd(body, lt);
    }
}

/// Scan a perk/attribute/book body for `<triggered_effect>` rows. Same walk as
/// the passive scan: rows inside an `<effect_group>` take that group's direct
/// requirements, a top-level row only its own. The rows land in one shared pool
/// with per-def ranges, like the passives.
fn scanTriggered(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    body: []const u8,
    triggered: *std.ArrayList(buffs.Triggered),
    reqs: *std.ArrayList(requirements.Requirement),
    trig_req_ranges: *std.ArrayList(struct { usize, usize }),
) !void {
    var i: usize = 0;
    while (i < body.len and triggered.items.len < triggered.items.len + max_triggered_per_def) {
        const lt = std.mem.findPos(u8, body, i, "<") orelse break;
        if (std.mem.startsWith(u8, body[lt..], "</")) break;
        if (std.mem.startsWith(u8, body[lt..], "<effect_group")) {
            const gt = std.mem.findPos(u8, body, lt, ">") orelse break;
            if (gt > lt and body[gt - 1] == '/') {
                i = gt + 1;
                continue;
            }
            const close = std.mem.findPos(u8, body, gt, "</effect_group>") orelse break;
            const inner = body[gt + 1 .. close];
            var group_reqs: std.ArrayList(requirements.Requirement) = .empty;
            defer group_reqs.deinit(allocator);
            try requirements.scanChildren(allocator, arena, inner, 0, inner.len, &group_reqs);
            var seen: usize = triggered.items.len;
            try buffs.scanTriggeredRows(
                allocator,
                arena,
                inner,
                0,
                inner.len,
                group_reqs.items,
                triggered,
                reqs,
                trig_req_ranges,
                triggered.items.len + max_triggered_per_def,
                &seen,
            );
            i = close + "</effect_group>".len;
            continue;
        }
        if (std.mem.startsWith(u8, body[lt..], "<triggered_effect")) {
            const end = requirements.elementEnd(body, lt);
            var seen: usize = triggered.items.len;
            try buffs.scanTriggeredRows(
                allocator,
                arena,
                body,
                lt,
                end,
                &.{},
                triggered,
                reqs,
                trig_req_ranges,
                triggered.items.len + max_triggered_per_def,
                &seen,
            );
        }
        i = requirements.elementEnd(body, lt);
    }
}

/// One `<perk>`/`<book>` element body: catalog row plus its passive rows. Both
/// element names carry the same attributes (name, max_level, parent) and the
/// same `<effect_group>`/`<level_requirements>` children.
fn scanProgressionBlocks(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    clean: []const u8,
    comptime open_tag: []const u8,
    comptime close_tag: []const u8,
    book: bool,
    def_max_level: u8,
    def_base_cost: u16,
    def_cost_mult: f32,
    list: *std.ArrayList(PerkDef),
    passives: *std.ArrayList(buffs.Passive),
    reqs: *std.ArrayList(requirements.Requirement),
    req_ranges: *std.ArrayList([2]usize),
    ranges: *std.ArrayList([2]usize),
    triggered: *std.ArrayList(buffs.Triggered),
    trig_req_ranges: *std.ArrayList(struct { usize, usize }),
    trig_ranges: *std.ArrayList([2]usize),
    limit: usize,
) !void {
    var i: usize = 0;
    while (i < clean.len and list.items.len < limit) {
        const pi = std.mem.findPos(u8, clean, i, open_tag) orelse break;
        const name = xml.attr(clean, pi, "name") orelse {
            i = pi + open_tag.len;
            continue;
        };
        var max_l: u8 = def_max_level;
        if (xml.attr(clean, pi, "max_level")) |v| max_l = std.fmt.parseInt(u8, v, 10) catch def_max_level;
        // Cost: a row's own attributes win over the <perks> container's.
        const row_base = if (xml.attr(clean, pi, "base_skill_point_cost")) |v|
            std.fmt.parseInt(u16, v, 10) catch def_base_cost
        else
            def_base_cost;
        const row_mult = if (xml.attr(clean, pi, "cost_multiplier_per_level")) |v|
            std.fmt.parseFloat(f32, v) catch def_cost_mult
        else
            def_cost_mult;
        // parent: the row's own `parent` attribute (a skill/attribute name in
        // stock, e.g. parent="skillPerceptionCombat"). The old walk-back grabbed
        // the last <attribute> in the file, so every perk resolved to the same
        // wrong attribute.
        var parent: []const u8 = "";
        if (xml.attr(clean, pi, "parent")) |pn| parent = try arena.dupe(u8, pn);
        const gt = std.mem.findPos(u8, clean, pi, ">") orelse break;
        const close = if (gt > pi and clean[gt - 1] == '/')
            gt + 1
        else
            std.mem.findPos(u8, clean, gt, close_tag) orelse break;
        const body = clean[gt + 1 .. close];
        var lvl_buf: std.ArrayList(LevelReq) = .empty;
        defer lvl_buf.deinit(allocator);
        try scanLevelReqs(allocator, arena, body, &lvl_buf);
        const r0 = passives.items.len;
        try scanPassives(allocator, arena, body, passives, reqs, req_ranges);
        const t0 = triggered.items.len;
        try scanTriggered(allocator, arena, body, triggered, reqs, trig_req_ranges);
        try list.append(allocator, .{
            .name = try arena.dupe(u8, name),
            .max_level = max_l,
            .parent_attr = parent,
            .book = book,
            .base_cost = row_base,
            .cost_mult = row_mult,
            .level_reqs = try arenaSlice(arena, LevelReq, lvl_buf.items),
            .override_cost = try parseOverrideCost(allocator, arena, clean, pi),
        });
        try ranges.append(allocator, .{ r0, passives.items.len - r0 });
        try trig_ranges.append(allocator, .{ t0, triggered.items.len - t0 });
        i = pi + open_tag.len;
    }
}

pub fn loadTableFromPath(allocator: std.mem.Allocator, path: []const u8) !Table {
    const clean = try xml.readCleanFile(allocator, path);
    defer allocator.free(clean);

    const arena_holder = try arena_util.newArenaHolder(allocator);
    errdefer {
        arena_holder.deinit();
        allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();

    const curve = parseCurve(clean);

    var attrs: std.ArrayList(AttrDef) = .empty;
    defer attrs.deinit(allocator);
    var perks: std.ArrayList(PerkDef) = .empty;
    defer perks.deinit(allocator);
    var passives_list: std.ArrayList(buffs.Passive) = .empty;
    defer passives_list.deinit(allocator);
    var reqs_list: std.ArrayList(requirements.Requirement) = .empty;
    defer reqs_list.deinit(allocator);
    var req_ranges: std.ArrayList([2]usize) = .empty;
    defer req_ranges.deinit(allocator);
    var perk_ranges: std.ArrayList([2]usize) = .empty;
    defer perk_ranges.deinit(allocator);
    var triggered_list: std.ArrayList(buffs.Triggered) = .empty;
    defer triggered_list.deinit(allocator);
    var trig_req_ranges: std.ArrayList(struct { usize, usize }) = .empty;
    defer trig_req_ranges.deinit(allocator);
    var attr_trig_ranges: std.ArrayList([2]usize) = .empty;
    defer attr_trig_ranges.deinit(allocator);
    var perk_trig_ranges: std.ArrayList([2]usize) = .empty;
    defer perk_trig_ranges.deinit(allocator);

    // Default attribute costs from <attributes ...>
    var def_min: u8 = 1;
    var def_max: u8 = 10;
    var def_cost: u16 = 1;
    var def_mult: f32 = 1.14;
    if (std.mem.find(u8, clean, "<attributes ")) |ai| {
        if (xml.attr(clean, ai, "min_level")) |v| def_min = std.fmt.parseInt(u8, v, 10) catch def_min;
        if (xml.attr(clean, ai, "max_level")) |v| def_max = std.fmt.parseInt(u8, v, 10) catch def_max;
        if (xml.attr(clean, ai, "base_skill_point_cost")) |v| def_cost = std.fmt.parseInt(u16, v, 10) catch def_cost;
        if (xml.attr(clean, ai, "cost_multiplier_per_level")) |v| def_mult = std.fmt.parseFloat(f32, v) catch def_mult;
    }

    // Perk defaults from <perks ...> (stock max 5 / cost 1 / mult 1; the row's
    // own attributes win). perkLuckyLooter is the stock row that takes its
    // max_level from here rather than writing one.
    var perk_max_level: u8 = 5;
    var perk_base_cost: u16 = 1;
    var perk_cost_mult: f32 = 1.0;
    if (std.mem.find(u8, clean, "<perks ")) |pi| {
        if (xml.attr(clean, pi, "max_level")) |v| perk_max_level = std.fmt.parseInt(u8, v, 10) catch perk_max_level;
        if (xml.attr(clean, pi, "base_skill_point_cost")) |v| perk_base_cost = std.fmt.parseInt(u16, v, 10) catch perk_base_cost;
        if (xml.attr(clean, pi, "cost_multiplier_per_level")) |v| perk_cost_mult = std.fmt.parseFloat(f32, v) catch perk_cost_mult;
    }

    var attr_ranges: std.ArrayList([2]usize) = .empty;
    defer attr_ranges.deinit(allocator);
    var i: usize = 0;
    while (i < clean.len and attrs.items.len < max_attrs) {
        const ai = std.mem.findPos(u8, clean, i, "<attribute ") orelse break;
        const aname = xml.attr(clean, ai, "name") orelse {
            i = ai + 11;
            continue;
        };
        const agt = std.mem.findPos(u8, clean, ai, ">") orelse break;
        // attBooks/attCrafting are self-closing (`/>`): no body to scan.
        const aclose = if (agt > ai and clean[agt - 1] == '/')
            agt + 1
        else
            std.mem.findPos(u8, clean, agt, "</attribute>") orelse break;
        const abody = clean[agt + 1 .. aclose];
        var alvl_buf: std.ArrayList(LevelReq) = .empty;
        defer alvl_buf.deinit(allocator);
        try scanLevelReqs(allocator, arena, abody, &alvl_buf);
        try attrs.append(allocator, .{
            .name = try arena.dupe(u8, aname),
            // Per-attribute overrides win over the <attributes> defaults
            // (stock: attBooks/attCrafting/attGeneralPerks carry their own
            // min_level/max_level/base_skill_point_cost).
            .min_level = if (xml.attr(clean, ai, "min_level")) |v| std.fmt.parseInt(u8, v, 10) catch def_min else def_min,
            .max_level = if (xml.attr(clean, ai, "max_level")) |v| std.fmt.parseInt(u8, v, 10) catch def_max else def_max,
            .base_cost = if (xml.attr(clean, ai, "base_skill_point_cost")) |v| std.fmt.parseInt(u16, v, 10) catch def_cost else def_cost,
            .cost_mult = def_mult,
            .level_reqs = try arenaSlice(arena, LevelReq, alvl_buf.items),
            .override_cost = try parseOverrideCost(allocator, arena, clean, ai),
        });
        const ar0 = passives_list.items.len;
        try scanPassives(allocator, arena, abody, &passives_list, &reqs_list, &req_ranges);
        try attr_ranges.append(allocator, .{ ar0, passives_list.items.len - ar0 });
        const at0 = triggered_list.items.len;
        try scanTriggered(allocator, arena, abody, &triggered_list, &reqs_list, &trig_req_ranges);
        try attr_trig_ranges.append(allocator, .{ at0, triggered_list.items.len - at0 });
        i = ai + 11;
    }

    try scanProgressionBlocks(allocator, arena, clean, "<perk ", "</perk>", false, perk_max_level, perk_base_cost, perk_cost_mult, &perks, &passives_list, &reqs_list, &req_ranges, &perk_ranges, &triggered_list, &trig_req_ranges, &perk_trig_ranges, max_perks);
    // `<book>` blocks share the perk shape (name, max_level, parent,
    // effect_group passives) and are progression values in their own right:
    // items.xml grants them with SetProgressionLevel level="-1". Without them
    // in the catalog a read almanac stores no level and folds no passive.
    try scanProgressionBlocks(allocator, arena, clean, "<book ", "</book>", true, perk_max_level, perk_base_cost, perk_cost_mult, &perks, &passives_list, &reqs_list, &req_ranges, &perk_ranges, &triggered_list, &trig_req_ranges, &perk_trig_ranges, max_perks);

    const passive_pool = try arena.alloc(buffs.Passive, passives_list.items.len);
    @memcpy(passive_pool, passives_list.items);
    const trig_pool = try arena.alloc(buffs.Triggered, triggered_list.items.len);
    @memcpy(trig_pool, triggered_list.items);
    const aslice = try arena.alloc(AttrDef, attrs.items.len);
    @memcpy(aslice, attrs.items);
    for (aslice, attr_ranges.items) |*a, rg| {
        a.passives = passive_pool[rg[0] .. rg[0] + rg[1]];
    }
    for (aslice, attr_trig_ranges.items) |*a, rg| {
        a.triggered = trig_pool[rg[0] .. rg[0] + rg[1]];
    }
    const pslice = try arena.alloc(PerkDef, perks.items.len);
    @memcpy(pslice, perks.items);
    for (pslice, perk_ranges.items) |*p, rg| {
        p.passives = passive_pool[rg[0] .. rg[0] + rg[1]];
    }
    for (pslice, perk_trig_ranges.items) |*p, rg| {
        p.triggered = trig_pool[rg[0] .. rg[0] + rg[1]];
    }
    // Every folded row has one range of gates in the pool (empty for ungated
    // rows); a mismatch means the walk and the append drifted apart.
    if (req_ranges.items.len != passive_pool.len) return error.MalformedProgression;
    if (trig_req_ranges.items.len != trig_pool.len) return error.MalformedProgression;
    const req_pool = try arena.alloc(requirements.Requirement, reqs_list.items.len);
    @memcpy(req_pool, reqs_list.items);
    for (passive_pool, req_ranges.items) |*p, rg| {
        p.reqs = req_pool[rg[0] .. rg[0] + rg[1]];
    }
    for (trig_pool, trig_req_ranges.items) |*t, rg| {
        t.reqs = req_pool[rg[0] .. rg[0] + rg[1]];
    }

    // Crafting skills + unlock_entry gates (99 rows in stock): the item
    // recipes unlock at the display_entry's mapped level per tier.
    var skills: std.ArrayList(CraftingSkill) = .empty;
    defer skills.deinit(allocator);
    var skill_passives: std.ArrayList(buffs.Passive) = .empty;
    defer skill_passives.deinit(allocator);
    var skill_reqs: std.ArrayList(requirements.Requirement) = .empty;
    defer skill_reqs.deinit(allocator);
    var skill_req_ranges: std.ArrayList([2]usize) = .empty;
    defer skill_req_ranges.deinit(allocator);
    var skill_ranges: std.ArrayList([2]usize) = .empty;
    defer skill_ranges.deinit(allocator);
    var si: usize = 0;
    while (si < clean.len and skills.items.len < max_skills) {
        const ski = std.mem.findPos(u8, clean, si, "<crafting_skill ") orelse break;
        const sk_name = xml.attr(clean, ski, "name") orelse {
            si = ski + 17;
            continue;
        };
        const gt = std.mem.findPos(u8, clean, ski, ">") orelse break;
        const close = std.mem.findPos(u8, clean, gt, "</crafting_skill>") orelse break;
        const body = clean[gt + 1 .. close];
        var sk: CraftingSkill = .{
            .name = try arena.dupe(u8, sk_name),
        };
        if (xml.attr(clean, ski, "max_level")) |ml| sk.max_level = std.fmt.parseInt(u16, ml, 10) catch sk.max_level;
        var entries: std.ArrayList(UnlockEntry) = .empty;
        defer entries.deinit(allocator);
        var ei: usize = 0;
        while (ei < body.len) {
            const di = std.mem.findPos(u8, body, ei, "<display_entry ") orelse break;
            const dgt = std.mem.findPos(u8, body, di, ">") orelse break;
            // Each display_entry owns its tier->level list; its unlock_entries
            // resolve against it (a later display_entry's list does not leak).
            var tier_levels: [8]u8 = .{0} ** 8;
            if (xml.attr(body, di, "unlock_level")) |ul| {
                var t: usize = 0;
                var it = std.mem.splitScalar(u8, ul, ',');
                while (it.next()) |seg| {
                    if (t >= tier_levels.len) break;
                    const v = std.mem.trim(u8, seg, " \t");
                    if (v.len > 0) tier_levels[t] = std.fmt.parseInt(u8, v, 10) catch 0;
                    t += 1;
                }
            }
            var uj = dgt + 1;
            while (uj < body.len) {
                const uni = std.mem.findPos(u8, body, uj, "<unlock_entry ") orelse break;
                const ugt = std.mem.findPos(u8, body, uni, ">") orelse break;
                if (std.mem.find(u8, body[dgt..uni], "</display_entry>") != null) break;
                const item_s = xml.attr(body, uni, "item") orelse "";
                var tier: u8 = 0;
                if (xml.attr(body, uni, "unlock_tier")) |tv| tier = std.fmt.parseInt(u8, tv, 10) catch 0;
                const lvl: u8 = if (tier > 0 and tier <= tier_levels.len) tier_levels[tier - 1] else 0;
                try entries.append(allocator, .{
                    .items = try arena.dupe(u8, item_s),
                    .level = lvl,
                });
                uj = ugt + 1;
            }
            ei = dgt + 1;
        }
        const sp0 = skill_passives.items.len;
        try scanPassives(allocator, arena, body, &skill_passives, &skill_reqs, &skill_req_ranges);
        try skill_ranges.append(allocator, .{ sp0, skill_passives.items.len - sp0 });
        const entries_slice = try arena.alloc(UnlockEntry, entries.items.len);
        @memcpy(entries_slice, entries.items);
        sk.entries = entries_slice;
        try skills.append(allocator, sk);
        si = close + 18;
    }
    const sk_slice = try arena.alloc(CraftingSkill, skills.items.len);
    @memcpy(sk_slice, skills.items);
    if (skill_req_ranges.items.len != skill_passives.items.len) return error.MalformedProgression;
    const sk_req_pool = try arena.alloc(requirements.Requirement, skill_reqs.items.len);
    @memcpy(sk_req_pool, skill_reqs.items);
    const sk_pool = try arena.alloc(buffs.Passive, skill_passives.items.len);
    @memcpy(sk_pool, skill_passives.items);
    for (sk_pool, skill_req_ranges.items) |*pw, rg| {
        pw.reqs = sk_req_pool[rg[0] .. rg[0] + rg[1]];
    }
    for (sk_slice, skill_ranges.items) |*sk, rg| {
        sk.passives = sk_pool[rg[0] .. rg[0] + rg[1]];
    }

    return .{
        .curve = curve,
        .attributes = aslice,
        .perks = pslice,
        .perk_base_cost = perk_base_cost,
        .perk_cost_mult = perk_cost_mult,
        .crafting_skills = sk_slice,
        .arena_ptr = arena_holder,
    };
}

/// Unlock requirement for an item: (crafting skill name, required level), or
/// null when no unlock_entry gates it (always_unlocked). Magazines raise the
/// skill via AddProgressionLevel; the join PDF and tryCraft honour the gate.
pub fn unlockRequirement(self: *const Table, item_name: []const u8) ?struct { []const u8, u8 } {
    for (self.crafting_skills) |sk| {
        for (sk.entries) |e| {
            var it = std.mem.splitScalar(u8, e.items, ',');
            while (it.next()) |n| {
                const t = std.mem.trim(u8, n, " \t");
                if (!std.mem.eql(u8, t, item_name)) continue;
                return .{ sk.name, e.level };
            }
        }
    }
    return null;
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?LevelCurve {
    return paths.tryLoadConfig("progression.xml", LevelCurve, loadFromPath, allocator, game_dir, config_dir);
}

pub fn tryLoadTable(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?Table {
    return paths.tryLoadConfig("progression.xml", Table, loadTableFromPath, allocator, game_dir, config_dir);
}
