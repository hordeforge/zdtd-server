//! progression.xml: level curve + attribute/perk/book catalog (names, max
//! levels, costs) + the perk/attribute/book passive_effect rows (the surface
//! the passive-effects VM folds over its tracked stats) with the `<requirement>`
//! gates stock applies to each row. Requirement evaluation lives in
//! `requirements.zig`; effect application is progressive.

const std = @import("std");
const arena_util = @import("../util/arena.zig");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
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
        if (cost >= 2147483648.0) return std.math.maxInt(i32);
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
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
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
    return buffs.trackedDeltasAt(def.passives, level, ctx, counts);
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

/// End index (exclusive) of the element whose open tag starts at `open_at`,
/// including its close tag unless it is self-closing. Stock XML does not nest
/// same-name elements, so the first close tag ends it.
fn elementEnd(body: []const u8, open_at: usize) usize {
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
    const close = std.mem.findPos(u8, body, gt, close_tag) orelse return body.len;
    return close + close_tag.len;
}

/// The element's direct `<requirement>` children, in document order.
/// `RequirementBase::ParseRequirementGroup` (IL=148) reads
/// `Elements("requirement")`, i.e. direct children only: a requirement nested
/// in a triggered_effect or in a passive_effect is not a group gate.
fn scanRequirements(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    body: []const u8,
    open_at: usize,
    out: *std.ArrayList(requirements.Requirement),
) !void {
    const gt = std.mem.findPos(u8, body, open_at, ">") orelse return;
    if (gt > open_at and body[gt - 1] == '/') return;
    const end = elementEnd(body, open_at);
    var i = gt + 1;
    while (i < end) {
        const lt = std.mem.findPos(u8, body, i, "<") orelse break;
        if (lt >= end or std.mem.startsWith(u8, body[lt..], "</")) break;
        if (std.mem.startsWith(u8, body[lt..], "<requirement")) {
            try out.append(allocator, try requirements.parse(body, lt, arena));
        }
        i = elementEnd(body, lt);
    }
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
            try scanRequirements(allocator, arena, body, lt, &reqs);
        }
        const slice = try arena.alloc(requirements.Requirement, reqs.items.len);
        @memcpy(slice, reqs.items);
        try out.append(allocator, .{ .level = level, .reqs = slice });
        i = elementEnd(body, lt);
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
    const curve_levels_len = if (xml.attr(body, tag, "level")) |lv|
        buffs.parseCurveLevels(lv, &curve_levels)
    else
        0;
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
    try scanRequirements(allocator, arena, body, tag, req_pool);
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
    var i: usize = 0;
    while (i < g.len) {
        const lt = std.mem.findPos(u8, g, i, "<") orelse break;
        if (std.mem.startsWith(u8, g[lt..], "</")) break;
        if (std.mem.startsWith(u8, g[lt..], "<requirement")) {
            try group_reqs.append(allocator, try requirements.parse(g, lt, arena));
        }
        i = elementEnd(g, lt);
    }
    i = 0;
    while (i < g.len and pool.items.len < passive_limit) {
        const lt = std.mem.findPos(u8, g, i, "<") orelse break;
        if (std.mem.startsWith(u8, g[lt..], "</")) break;
        if (std.mem.startsWith(u8, g[lt..], "<passive_effect")) {
            try appendGatedPassive(allocator, arena, g, lt, group_reqs.items, pool, req_pool, req_ranges);
        }
        i = elementEnd(g, lt);
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
            i = close + 16;
            continue;
        }
        if (std.mem.startsWith(u8, body[lt..], "<passive_effect")) {
            try appendGatedPassive(allocator, arena, body, lt, &.{}, pool, req_pool, req_ranges);
        }
        i = elementEnd(body, lt);
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
        i = ai + 11;
    }

    try scanProgressionBlocks(allocator, arena, clean, "<perk ", "</perk>", false, perk_max_level, perk_base_cost, perk_cost_mult, &perks, &passives_list, &reqs_list, &req_ranges, &perk_ranges, max_perks);
    // `<book>` blocks share the perk shape (name, max_level, parent,
    // effect_group passives) and are progression values in their own right:
    // items.xml grants them with SetProgressionLevel level="-1". Without them
    // in the catalog a read almanac stores no level and folds no passive.
    try scanProgressionBlocks(allocator, arena, clean, "<book ", "</book>", true, perk_max_level, perk_base_cost, perk_cost_mult, &perks, &passives_list, &reqs_list, &req_ranges, &perk_ranges, max_perks);

    const passive_pool = try arena.alloc(buffs.Passive, passives_list.items.len);
    @memcpy(passive_pool, passives_list.items);
    const aslice = try arena.alloc(AttrDef, attrs.items.len);
    @memcpy(aslice, attrs.items);
    for (aslice, attr_ranges.items) |*a, rg| {
        a.passives = passive_pool[rg[0] .. rg[0] + rg[1]];
    }
    const pslice = try arena.alloc(PerkDef, perks.items.len);
    @memcpy(pslice, perks.items);
    for (pslice, perk_ranges.items) |*p, rg| {
        p.passives = passive_pool[rg[0] .. rg[0] + rg[1]];
    }
    // Every folded row has one range of gates in the pool (empty for ungated
    // rows); a mismatch means the walk and the append drifted apart.
    if (req_ranges.items.len != passive_pool.len) return error.MalformedProgression;
    const req_pool = try arena.alloc(requirements.Requirement, reqs_list.items.len);
    @memcpy(req_pool, reqs_list.items);
    for (passive_pool, req_ranges.items) |*p, rg| {
        p.reqs = req_pool[rg[0] .. rg[0] + rg[1]];
    }

    // Crafting skills + unlock_entry gates (99 rows in stock): the item
    // recipes unlock at the display_entry's mapped level per tier.
    var skills: std.ArrayList(CraftingSkill) = .empty;
    defer skills.deinit(allocator);
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
        const entries_slice = try arena.alloc(UnlockEntry, entries.items.len);
        @memcpy(entries_slice, entries.items);
        sk.entries = entries_slice;
        try skills.append(allocator, sk);
        si = close + 18;
    }
    const sk_slice = try arena.alloc(CraftingSkill, skills.items.len);
    @memcpy(sk_slice, skills.items);

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

test "expForLevel matches stock GetExpForNextLevel golden values" {
    // Stock defaults from progression.xml parse (10000 / 1.05 / clamp 60):
    // cost(L) = float32(10000 * Mathf.Pow(1.05f, min(L+1, 60))), truncated,
    // Math.Min(.., 2.147484e9f) then conv.i4 saturates at int.MaxValue.
    // Golden values computed independently in float32 (numpy), same as the
    // stock Single arithmetic (Progression.il.txt 1083482).
    const c: LevelCurve = .{};
    try std.testing.expectEqual(@as(u64, 10500), c.expForLevel(0));
    try std.testing.expectEqual(@as(u64, 11024), c.expForLevel(1));
    try std.testing.expectEqual(@as(u64, 11576), c.expForLevel(2));
    try std.testing.expectEqual(@as(u64, 17103), c.expForLevel(10));
    try std.testing.expectEqual(@as(u64, 177896), c.expForLevel(58));
    try std.testing.expectEqual(@as(u64, 186791), c.expForLevel(59));
    // Exponent clamps at ClampExpCostAtLevel=60: 60 and beyond are identical.
    try std.testing.expectEqual(@as(u64, 186791), c.expForLevel(60));
    try std.testing.expectEqual(@as(u64, 186791), c.expForLevel(299));
    try std.testing.expectEqual(@as(u64, 186791), c.expForLevel(300));
    // A degenerate clamp (0 = no clamp) uses max_level: far levels hit the
    // 2.147484e9f ceiling like stock's Math.Min.
    const noclamp: LevelCurve = .{ .clamp_exp_cost_at_level = 0 };
    try std.testing.expectEqual(@as(u64, 2082136064), noclamp.expForLevel(250));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(i32)), noclamp.expForLevel(251));
}

test "load progression.xml when present" {
    const p = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/progression.xml";
    if (!io_fs.fileExists(p)) return error.SkipZigTest;
    var t = try loadTableFromPath(std.testing.allocator, p);
    defer t.deinit();
    try std.testing.expect(t.curve.loaded);
    try std.testing.expectEqual(@as(u16, 300), t.curve.max_level);
    try std.testing.expectEqual(@as(u32, 10000), t.curve.exp_to_level);
    try std.testing.expect(t.attributes.len >= 4);
    try std.testing.expect(t.perks.len > 10);
    try std.testing.expect(t.curve.expForLevel(1) >= t.curve.exp_to_level);
}

test "perk parent and per-attribute overrides parse from stock progression.xml" {
    // (a) each <perk> carries its own `parent` (a skill/attribute name); the
    // old walk-back resolved every perk to the file's last <attribute>.
    // (b) attBooks/attCrafting/attGeneralPerks carry their own
    // min_level/max_level/base_skill_point_cost overrides.
    const p = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/progression.xml";
    if (!io_fs.fileExists(p)) return error.SkipZigTest;
    var t = try loadTableFromPath(std.testing.allocator, p);
    defer t.deinit();

    // A combat perk: parent resolves to its skill, not the last attribute.
    var found_dead_eye = false;
    for (t.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkDeadEye")) {
            try std.testing.expectEqualStrings("skillPerceptionCombat", pk.parent_attr);
            found_dead_eye = true;
        }
    }
    try std.testing.expect(found_dead_eye);
    // The rest of the ladder resolves to their skills, not the last
    // attribute in the file.
    var skill_parents: usize = 0;
    for (t.perks) |pk| {
        if (std.mem.startsWith(u8, pk.parent_attr, "skill")) skill_parents += 1;
    }
    try std.testing.expect(skill_parents > 20);

    // Attribute overrides: attBooks is 0/0/0, the default rows stay 1/10/1.
    var att_books = false;
    var att_perception = false;
    for (t.attributes) |a| {
        if (std.mem.eql(u8, a.name, "attBooks")) {
            try std.testing.expectEqual(@as(u8, 0), a.min_level);
            try std.testing.expectEqual(@as(u8, 0), a.max_level);
            try std.testing.expectEqual(@as(u16, 0), a.base_cost);
            att_books = true;
        }
        if (std.mem.eql(u8, a.name, "attPerception")) {
            try std.testing.expectEqual(@as(u8, 1), a.min_level);
            try std.testing.expectEqual(@as(u16, 1), a.base_cost);
            att_perception = true;
        }
    }
    try std.testing.expect(att_books);
    try std.testing.expect(att_perception);
}

test "crafting skill unlock_entry gates parse and resolve tiers" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/progression.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadTableFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expect(t.crafting_skills.len >= 20);
    // The stone axe unlocks at craftingHarvestingTools tier 1 -> level 1
    // (display_entry unlock_levels "1,2,4,6,8,10").
    const req = unlockRequirement(&t, "meleeToolRepairT0StoneAxe").?;
    try std.testing.expectEqualStrings("craftingHarvestingTools", req[0]);
    try std.testing.expectEqual(@as(u8, 1), req[1]);
    // Ungated items (always_unlocked) have no requirement.
    try std.testing.expect(unlockRequirement(&t, "resourceWood") == null);
}

test "perk/attribute passive_effect rows parse (the 649-row surface)" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/progression.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadTableFromPath(std.testing.allocator, path);
    defer t.deinit();
    // Stock perk bodies carry passive rows (e.g. GeneralDamageResist on
    // toughness perks, BlockDamage on SexRex); the parse must not truncate.
    var total: usize = 0;
    var tracked_hits: usize = 0;
    var counts: requirements.Counts = .{};
    for (t.perks) |p| {
        total += p.passives.len;
        const d = buffs.trackedDeltasFrom(p.passives, .{}, &counts);
        if (d.general_resist != 0 or d.phys_resist != 0 or d.hp_max != 0 or d.stamina_ot != 0) tracked_hits += 1;
    }
    for (t.attributes) |a| total += a.passives.len;
    try std.testing.expect(total > 100); // the 649 rows are mostly in effect_groups; perk+attr bodies hold hundreds
    // A known tracked row: perkSexRex BlockDamage is untracked, but the
    // toughness-tree GeneralDamageResist rows land in the VM's resist delta.
    try std.testing.expect(tracked_hits > 0);
    // Level-scaled fold against the real XML: perkHealingFactor carries
    // HealthChangeOT .011,.022,.05,.1,.16 (per-second regen), so level 5
    // folds 0.16 hp/s and level 0 folds nothing.
    var heal: ?PerkDef = null;
    for (t.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkHealingFactor")) {
            heal = pk;
            break;
        }
    }
    if (heal) |h| {
        try std.testing.expect(h.passives.len > 0);
        // The row is gated `!HasBuff buffStatusHungry03,buffStatusThirsty03`;
        // with the buff catalog absent but no buffs active the gate is decided
        // (empty set) so the regen folds.
        try std.testing.expect(h.passives[0].reqs.len > 0);
        const d5 = buffs.trackedDeltasAt(h.passives, 5, .{}, &counts);
        try std.testing.expectApproxEqAbs(@as(f32, 0.16), d5.hp_ot, 0.0001);
        const d0 = buffs.trackedDeltasAt(h.passives, 0, .{}, &counts);
        try std.testing.expect(!d0.any());
        // Starving for water: the row must not fold at all.
        const starving_ids = [_]u16{3};
        const names = requirements.BuffNames{ .ctx = undefined, .resolve = struct {
            fn f(_: *const anyopaque, name: []const u8) ?u16 {
                return if (std.ascii.eqlIgnoreCase(name, "buffStatusThirsty03")) 3 else null;
            }
        }.f };
        const starving = buffs.trackedDeltasAt(h.passives, 5, .{
            .active_buffs = &starving_ids,
            .buff_names = &names,
        }, &counts);
        try std.testing.expectEqual(@as(f32, 0), starving.hp_ot);
    }
    // Explicit level= anchors: perkFortitudeMastery HealthMax is level="4,5"
    // value="50,100" - the fold applies nothing below level 4 (the old
    // implicit scaling would have given level 1 -> 50).
    var fort: ?PerkDef = null;
    for (t.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkFortitudeMastery")) {
            fort = pk;
            break;
        }
    }
    if (fort) |f2| {
        const d1 = buffs.trackedDeltasAt(f2.passives, 1, .{}, &counts);
        try std.testing.expectEqual(@as(f32, 0), d1.hp_max);
        const d5 = buffs.trackedDeltasAt(f2.passives, 5, .{}, &counts);
        try std.testing.expectApproxEqAbs(@as(f32, 100), d5.hp_max, 0.0001);
    }
    // `<book>` blocks parse into the same catalog: the Fireman's Almanac
    // Complete passives are InBiome-gated AND tags="running", so they fold only
    // for a running query in that biome (an untagged query never matches a
    // tagged row).
    var book: ?PerkDef = null;
    for (t.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkFiremansAlmanacComplete")) {
            book = pk;
            break;
        }
    }
    try std.testing.expect(book != null);
    const b = book.?;
    try std.testing.expectEqual(@as(u8, 1), b.max_level);
    try std.testing.expect(b.passives.len > 0);
    var in_biome = false;
    for (b.passives) |p| {
        if (std.mem.eql(u8, p.name, "StaminaChangeOT") and p.reqs.len > 0) in_biome = true;
    }
    try std.testing.expect(in_biome);
    try std.testing.expectEqual(@as(f32, 0), buffs.trackedDeltasAt(b.passives, 1, .{ .biome_id = 1, .tags = "running" }, &counts).stamina_ot);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), buffs.trackedDeltasAt(b.passives, 1, .{ .biome_id = 8, .tags = "running" }, &counts).stamina_ot, 0.0001);
    // The same biome with an untagged query folds nothing: the row is tagged.
    try std.testing.expectEqual(@as(f32, 0), buffs.trackedDeltasAt(b.passives, 1, .{ .biome_id = 8 }, &counts).stamina_ot);
}

test "perkTotals folds purchased perk levels level-scaled and reverts" {
    const attrs = [_]AttrDef{.{ .name = "attFortitude", .max_level = 10 }};
    const perks = [_]PerkDef{
        .{
            .name = "perkHealingFactor",
            .max_level = 5,
            .parent_attr = "attFortitude",
            .passives = &.{.{ .name = "HealthChangeOT", .op = .base_add, .curve = .{ 0.011, 0.022, 0.05, 0.1, 0.16, 0, 0, 0 }, .curve_len = 5 }},
        },
        .{
            .name = "perkPackMule",
            .max_level = 5,
            .passives = &.{.{ .name = "GeneralDamageResist", .op = .base_add, .value = 1 }},
        },
    };
    const pt = Table{ .attributes = attrs[0..], .perks = perks[0..] };
    var counts: requirements.Counts = .{};
    // No purchases: no deltas.
    var levels = [_]SkillLevel{.{}} ** 4;
    try std.testing.expect(!perkTotals(&pt, &levels, .{}, &counts).any());
    // Healing Factor level 1: small regen; level 5: the full curve value.
    levels[0] = .{ .name = "perkHealingFactor", .level = 1 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.011), perkTotals(&pt, &levels, .{}, &counts).hp_ot, 0.0001);
    levels[0].level = 5;
    levels[1] = .{ .name = "perkPackMule", .level = 3 };
    const t5 = perkTotals(&pt, &levels, .{}, &counts);
    try std.testing.expectApproxEqAbs(@as(f32, 0.16), t5.hp_ot, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), t5.general_resist, 0.0001);
    // Revertible: dropping the level drops its deltas exactly.
    levels[1].level = 0;
    const back = perkTotals(&pt, &levels, .{}, &counts);
    try std.testing.expectApproxEqAbs(@as(f32, 0), back.general_resist, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.16), back.hp_ot, 0.0001);
    // Unknown names are ignored (fail closed).
    levels[0].name = "notAPerk";
    try std.testing.expect(!perkTotals(&pt, &levels, .{}, &counts).any());
    // The ProgressionLevel gate reads the same ledger the fold walks: a row
    // gated on its own progression name folds only once that level is held.
    const gated = [_]PerkDef{.{
        .name = "perkFortitudeMastery",
        .max_level = 5,
        .passives = &.{.{
            .name = "HealthMax",
            .op = .base_add,
            .curve = .{ 0, 0, 0, 50, 100, 0, 0, 0 },
            .curve_len = 5,
            .reqs = &.{.{
                .kind = .progression_level,
                .op = .ge,
                .value = 1,
                .arg = "perkFortitudeMastery",
            }},
        }},
    }};
    const gt = Table{ .perks = gated[0..] };
    const held = [_]SkillLevel{.{ .name = "perkFortitudeMastery", .level = 5 }};
    const gate_ctx = requirements.Ctx{ .levels = &held };
    try std.testing.expectApproxEqAbs(@as(f32, 100), perkTotals(&gt, &held, gate_ctx, &counts).hp_max, 0.0001);
    // The gate blocks when the ctx ledger does not corroborate the folded
    // level (stock resolves the gate against the target's Progression, not
    // against the level the caller happens to fold at).
    try std.testing.expectEqual(@as(f32, 0), perkTotals(&gt, &held, .{
        .levels = &.{.{ .name = "other", .level = 1 }},
    }, &counts).hp_max);
}

test "effect_group and row requirements attach to the right passives" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/progression.xml", .{dir});
    try io_fs.writeFile(path,
        \\<progression>
        \\  <level max_level="10" exp_to_level="100" experience_multiplier="1.1" skill_points_per_level="1" clamp_exp_cost_at_level="5"/>
        \\  <attributes min_level="1" max_level="10" base_skill_point_cost="1" cost_multiplier_per_level="1"/>
        \\  <perks min_level="0" max_level="7" base_skill_point_cost="2" cost_multiplier_per_level="1.5">
        \\    <perk name="perkGated" max_level="5" parent="skillTest" override_cost="1,2">
        \\      <level_requirements level="1"><requirement name="ProgressionLevel" progression_name="attStrength" operation="GTE" value="1"/></level_requirements>
        \\      <level_requirements level="3"><requirement name="ProgressionLevel" progression_name="attStrength" operation="GTE" value="5"/></level_requirements>
        \\      <effect_group>
        \\        <requirement name="InBiome" biome="8"/>
        \\        <passive_effect name="StaminaMax" operation="base_add" level="1" value="25"/>
        \\        <passive_effect name="HealthMax" operation="base_add" level="1" value="50">
        \\          <requirement name="!HasBuff" buff="buffBleeding"/>
        \\        </passive_effect>
        \\        <triggered_effect trigger="onSelfPrimaryActionEnd" action="ModifyStats" stat="Health" operation="add" value="1">
        \\          <requirement name="PlayerLevel" operation="GTE" value="1"/>
        \\        </triggered_effect>
        \\        <passive_effect name="FoodMax" operation="base_add" level="1" value="10"/>
        \\      </effect_group>
        \\      <effect_group>
        \\        <passive_effect name="WaterMax" operation="base_add" level="1" value="5"/>
        \\      </effect_group>
        \\    </perk>
        \\    <perk name="perkInherits" parent="skillTest"/>
        \\    <book name="perkBookTest" max_level="1" parent="skillTest">
        \\      <effect_group>
        \\        <requirement name="ProgressionLevel" progression_name="perkGated" operation="GTE" value="1"/>
        \\        <passive_effect name="HealthChangeOT" operation="base_add" level="1" value="0.5"/>
        \\      </effect_group>
        \\    </book>
        \\  </perks>
        \\</progression>
    );
    var t = try loadTableFromPath(std.testing.allocator, path);
    defer t.deinit();
    var perk: ?PerkDef = null;
    var book: ?PerkDef = null;
    for (t.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkGated")) perk = pk;
        if (std.mem.eql(u8, pk.name, "perkBookTest")) book = pk;
    }
    try std.testing.expect(perk != null and book != null);
    const p = perk.?;
    // Four passives over the two groups. The triggered_effect's requirement is
    // not a group gate and its row is not a passive.
    try std.testing.expectEqual(@as(usize, 4), p.passives.len);
    // StaminaMax: the group gate only.
    try std.testing.expectEqual(@as(usize, 1), p.passives[0].reqs.len);
    try std.testing.expectEqual(requirements.Kind.in_biome, p.passives[0].reqs[0].kind);
    // HealthMax: the group gate plus its own nested requirement.
    try std.testing.expectEqual(@as(usize, 2), p.passives[1].reqs.len);
    try std.testing.expectEqual(requirements.Kind.has_buff, p.passives[1].reqs[1].kind);
    try std.testing.expect(p.passives[1].reqs[1].negated);
    // FoodMax still takes the group gate.
    try std.testing.expectEqual(@as(usize, 1), p.passives[2].reqs.len);
    // WaterMax is in the second group, which has no requirement.
    try std.testing.expectEqual(@as(usize, 0), p.passives[3].reqs.len);
    // The two `<level_requirements>` blocks parse onto the row, in file order,
    // with their own nested requirements.
    try std.testing.expectEqual(@as(usize, 2), p.level_reqs.len);
    try std.testing.expectEqual(@as(u8, 1), p.level_reqs[0].level);
    try std.testing.expectEqual(@as(u8, 3), p.level_reqs[1].level);
    try std.testing.expectEqual(@as(usize, 1), p.level_reqs[1].reqs.len);
    try std.testing.expectEqual(requirements.Kind.progression_level, p.level_reqs[1].reqs[0].kind);
    try std.testing.expectEqualStrings("attStrength", p.level_reqs[1].reqs[0].arg);
    try std.testing.expectEqual(@as(f32, 5), p.level_reqs[1].reqs[0].value);
    // No gates pass with an empty ledger, so nothing is purchasable; a
    // strength of 5 unlocks level 3.
    var ledger = [_]SkillLevel{.{ .name = "attStrength", .level = 4 }};
    try std.testing.expectEqual(@as(u8, 1), t.calculatedMaxLevel(&ledger, 1, "perkGated").?);
    ledger[0].level = 5;
    try std.testing.expectEqual(@as(u8, 3), t.calculatedMaxLevel(&ledger, 1, "perkGated").?);
    try std.testing.expectEqual(@as(u8, 0), t.calculatedMaxLevel(&.{}, 1, "perkGated").?);
    // The book has no level gates: its catalog max (1) is the answer, and the
    // row is flagged as a book so the purchase path can refuse it.
    try std.testing.expectEqual(@as(usize, 0), book.?.level_reqs.len);
    try std.testing.expect(book.?.book);
    try std.testing.expectEqual(@as(u8, 1), t.calculatedMaxLevel(&.{}, 1, "perkBookTest").?);
    try std.testing.expect(t.calculatedMaxLevel(&.{}, 1, "notACatalogRow") == null);
    // The row's own cost attributes and override table parse, and a row with
    // neither inherits the <perks> container's defaults (max_level 7 here).
    try std.testing.expectEqualSlices(u16, &.{ 1, 2 }, p.override_cost);
    try std.testing.expectEqual(@as(u16, 2), p.base_cost);
    try std.testing.expectEqual(@as(f32, 1.5), p.cost_mult);
    const inh = for (t.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkInherits")) break pk;
    } else return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u8, 7), inh.max_level);
    try std.testing.expectEqual(@as(usize, 0), inh.override_cost.len);
    try std.testing.expectEqual(@as(u16, 2), t.perk_base_cost);
    try std.testing.expectEqual(@as(f32, 1.5), t.perk_cost_mult);
    var counts: requirements.Counts = .{};
    const in8 = buffs.trackedDeltasAt(p.passives, 1, .{ .biome_id = 8 }, &counts);
    try std.testing.expectApproxEqAbs(@as(f32, 25), in8.stamina_max, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 50), in8.hp_max, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 10), in8.food_max, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 5), in8.water_max, 0.0001);
    // Wrong biome: the gated rows drop, the ungated second group stays. The
    // single `level="1"` anchor applies at level 1 (not interpolated).
    const in1 = buffs.trackedDeltasAt(p.passives, 1, .{ .biome_id = 1 }, &counts);
    try std.testing.expectEqual(@as(f32, 0), in1.stamina_max);
    try std.testing.expectEqual(@as(f32, 0), in1.hp_max);
    try std.testing.expectEqual(@as(f32, 0), in1.food_max);
    try std.testing.expectApproxEqAbs(@as(f32, 5), in1.water_max, 0.0001);
    // The book row is gated on the perk's level, so it needs the ledger entry.
    const b = book.?;
    try std.testing.expectEqual(@as(usize, 1), b.passives.len);
    try std.testing.expectEqual(requirements.Kind.progression_level, b.passives[0].reqs[0].kind);
    const book_ledger = [_]requirements.NameLevel{.{ .name = "perkGated", .level = 1 }};
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), buffs.trackedDeltasAt(b.passives, 1, .{ .levels = &book_ledger }, &counts).hp_ot, 0.0001);
    try std.testing.expectEqual(@as(f32, 0), buffs.trackedDeltasAt(b.passives, 1, .{}, &counts).hp_ot);
}

test "a def stops at max_passives_per_def rows" {
    // The bound is a zdtd storage cap, not a stock rule; it must hold across
    // the effect_group walk (a group-at-a-time scan must not lose the per-row
    // check the flat scan had) or a pathological modded body grows the pool.
    const a = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "<progression><attributes min_level=\"1\" max_level=\"10\"/><perks><perk name=\"perkMany\" max_level=\"5\"><effect_group><requirement name=\"InBiome\" biome=\"8\"/>");
    var i: usize = 0;
    while (i < max_passives_per_def + 8) : (i += 1) {
        try buf.appendSlice(a, "<passive_effect name=\"StaminaMax\" operation=\"base_add\" level=\"1\" value=\"1\"/>");
    }
    try buf.appendSlice(a, "</effect_group></perk></perks></progression>");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/progression.xml", .{dir});
    try io_fs.writeFile(path, buf.items);
    var t = try loadTableFromPath(a, path);
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 1), t.perks.len);
    try std.testing.expectEqual(max_passives_per_def, t.perks[0].passives.len);
    var counts: requirements.Counts = .{};
    const d = buffs.trackedDeltasAt(t.perks[0].passives, 1, .{ .biome_id = 8 }, &counts);
    try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(max_passives_per_def)), d.stamina_max, 0.0001);
}

test "stock level_requirements parse and gate the calculated max level" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/progression.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadTableFromPath(std.testing.allocator, path);
    defer t.deinit();

    // attPerception carries ten level blocks, each gated on PlayerLevel >= 1,
    // so every attribute level is reachable from player level 1.
    var att: ?AttrDef = null;
    for (t.attributes) |a| {
        if (std.mem.eql(u8, a.name, "attPerception")) att = a;
    }
    try std.testing.expect(att != null);
    try std.testing.expectEqual(@as(usize, 10), att.?.level_reqs.len);
    try std.testing.expectEqual(@as(u8, 10), t.calculatedMaxLevel(&.{}, 1, "attPerception").?);
    try std.testing.expectEqual(@as(u8, 0), t.calculatedMaxLevel(&.{}, 0, "attPerception").?);

    // A perk ladder: perkPummelPete wants attStrength 1/3/5/7/10 for levels
    // 1..5, so the highest passing block is the purchasable level.
    const pummel = for (t.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkPummelPete")) break pk;
    } else return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 5), pummel.level_reqs.len);
    var lv = [_]SkillLevel{.{ .name = "attStrength", .level = 6 }};
    try std.testing.expectEqual(@as(u8, 3), t.calculatedMaxLevel(&lv, 1, "perkPummelPete").?);
    lv[0].level = 2;
    try std.testing.expectEqual(@as(u8, 1), t.calculatedMaxLevel(&lv, 1, "perkPummelPete").?);
    lv[0].level = 10;
    try std.testing.expectEqual(@as(u8, 5), t.calculatedMaxLevel(&lv, 1, "perkPummelPete").?);

    // Every book row is flagged and carries no level gates (books are
    // item-granted), and the whole level-gate vocabulary is ProgressionLevel
    // plus PlayerLevel, which is what the evaluator implements.
    var books: usize = 0;
    var prog: usize = 0;
    var player: usize = 0;
    for (t.perks) |pk| {
        if (pk.book) {
            books += 1;
            try std.testing.expectEqual(@as(usize, 0), pk.level_reqs.len);
        }
        for (pk.level_reqs) |lr| {
            for (lr.reqs) |r| {
                switch (r.kind) {
                    .progression_level => prog += 1,
                    .player_level => player += 1,
                    else => return error.UnexpectedRequirementKind,
                }
            }
        }
    }
    for (t.attributes) |a| {
        for (a.level_reqs) |lr| {
            for (lr.reqs) |r| {
                switch (r.kind) {
                    .progression_level => prog += 1,
                    .player_level => player += 1,
                    else => return error.UnexpectedRequirementKind,
                }
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 152), books);
    try std.testing.expectEqual(@as(usize, 250), prog);
    try std.testing.expectEqual(@as(usize, 51), player);

    // Seven stock perks replace the cost curve with a per-level table, and
    // perkLuckyLooter takes its max_level from the <perks> container.
    const lucky = for (t.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkLuckyLooter")) break pk;
    } else return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u8, 5), lucky.max_level);
    try std.testing.expectEqualSlices(u16, &.{ 1, 2, 2, 2, 3 }, lucky.override_cost);
    try std.testing.expectEqual(@as(u16, 1), t.perk_base_cost);
    try std.testing.expectEqual(@as(f32, 1.0), t.perk_cost_mult);
    var overrides: usize = 0;
    for (t.perks) |pk| {
        if (pk.override_cost.len > 0) overrides += 1;
    }
    try std.testing.expectEqual(@as(usize, 7), overrides);
}
