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
    /// `InBiome biome="N"`. -1 = absent.
    num: i32 = -1,
    target: Target = .self,
    /// `has_all_tags="true"` on a tag-list gate (HoldingItemHasTags/ItemHasTags):
    /// every listed tag must match instead of any one (IL=1C5).
    has_all: bool = false,
};

/// The vocabulary this evaluator resolves. Everything else maps to
/// `.unsupported` and refuses the gate.
pub const Kind = enum(u8) {
    unsupported,
    progression_level,
    player_level,
    has_buff,
    is_alive,
    is_attached_to_entity,
    in_biome,
    holding_item_has_tags,
    sandbox_option_bool,
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
    alive: bool = true,
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
    /// Decoded sandbox code groups (`SandboxOptions.SandboxOptionManager`, see
    /// `assets/sandbox.zig`); `SandboxOptionBool` (IL=18) reads a bool option.
    sandbox_groups: []const sandbox.Group = &.{},
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
    if (std.mem.eql(u8, name, "HasBuff")) return .has_buff;
    if (std.mem.eql(u8, name, "IsAlive")) return .is_alive;
    if (std.mem.eql(u8, name, "IsAttachedToEntity")) return .is_attached_to_entity;
    if (std.mem.eql(u8, name, "InBiome")) return .in_biome;
    if (std.mem.eql(u8, name, "HoldingItemHasTags")) return .holding_item_has_tags;
    if (std.mem.eql(u8, name, "SandboxOptionBool")) return .sandbox_option_bool;
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
pub fn parse(hay: []const u8, tag_start: usize, arena: std.mem.Allocator) !Requirement {
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
    if (xml.attr(hay, tag_start, "value")) |v| r.value = std.fmt.parseFloat(f32, v) catch 0;
    if (xml.attr(hay, tag_start, "target")) |t| r.target = parseTarget(t);
    if (xml.attr(hay, tag_start, "biome")) |b| r.num = std.fmt.parseInt(i32, b, 10) catch -1;
    if (xml.attr(hay, tag_start, "has_all_tags")) |v| r.has_all = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "True");
    r.arg = try arena.dupe(u8, xml.attr(hay, tag_start, "progression_name") orelse
        xml.attr(hay, tag_start, "cvar") orelse
        xml.attr(hay, tag_start, "option") orelse
        xml.attr(hay, tag_start, "stat") orelse
        xml.attr(hay, tag_start, "skill_name") orelse
        xml.attr(hay, tag_start, "key") orelse "");
    r.list = try arena.dupe(u8, xml.attr(hay, tag_start, "buff") orelse
        xml.attr(hay, tag_start, "tags") orelse "");
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

/// Whether a comma tag list carries `tag` (case-sensitive, like FastTags).
fn tagListHas(list: []const u8, tag: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, std.mem.trim(u8, seg, " \t"), tag)) return true;
    }
    return false;
}

fn evalOne(r: Requirement, ctx: Ctx) Verdict {
    // TargetedCompareRequirementBase::IsValid (IL=51) resolves `other` and
    // `instigator` from MinEventParams; zdtd's context carries self only, so a
    // foreign target refuses the gate rather than silently reading self.
    if (r.target != .self) return .unsupported;
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
            const lvl = levelOf(ctx.levels, r.arg) orelse return .fail;
            return verdict(compare(@floatFromInt(lvl), r.op, r.value), r.negated);
        },
        .player_level => return verdict(compare(@floatFromInt(ctx.player_level), r.op, r.value), r.negated),
        .has_buff => return evalHasBuff(r, ctx),
        .is_alive => return verdict(ctx.alive, r.negated),
        .is_attached_to_entity => return verdict(ctx.attached_to_entity, r.negated),
        .holding_item_has_tags => return evalHoldingItemHasTags(r, ctx),
        .sandbox_option_bool => return evalSandboxOptionBool(r, ctx),
    }
}

/// AND over one row's gates (`RequirementGroup::EvalAnd`, the stock default;
/// `op="or"` does not appear in the shipped files). Short-circuits on the first
/// fail; an unsupported gate blocks the row and is counted.
pub fn evaluate(reqs: []const Requirement, ctx: Ctx, counts: *Counts) Verdict {
    var unsupported = false;
    for (reqs) |r| {
        switch (evalOne(r, ctx)) {
            .pass => counts.resolved += 1,
            .fail => {
                counts.resolved += 1;
                return .fail;
            },
            .unsupported => {
                counts.unsupported += 1;
                unsupported = true;
            },
        }
    }
    return if (unsupported) .unsupported else .pass;
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
    const close = std.mem.findPos(u8, body, gt, close_tag) orelse return body.len;
    return close + close_tag.len;
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
) !void {
    const gt = std.mem.findPos(u8, body, open_at, ">") orelse return;
    if (gt > open_at and body[gt - 1] == '/') return;
    const end = elementEnd(body, open_at);
    var i = gt + 1;
    while (i < end) {
        const lt = std.mem.findPos(u8, body, i, "<") orelse break;
        if (lt >= end or std.mem.startsWith(u8, body[lt..], "</")) break;
        if (std.mem.startsWith(u8, body[lt..], "<requirement")) {
            try out.append(allocator, try parse(body, lt, arena));
        }
        i = elementEnd(body, lt);
    }
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

test "SandboxOptionBool reads the decoded option or its default" {
    const newbie = sandbox.optionByName("NewbieCoat").?;
    const req_on = Requirement{ .kind = .sandbox_option_bool, .arg = "NewbieCoat" };
    const req_off = Requirement{ .kind = .sandbox_option_bool, .arg = "NewbieCoat", .negated = true };
    // Not in the code: the option default (YesNo default 0 = No).
    try testing.expect(!all(&.{req_on}, .{}));
    try testing.expect(all(&.{req_off}, .{}));
    // Code index 1 = Yes.
    const on = [_]sandbox.Group{.{ .option_id = newbie.id, .index = 1 }};
    try testing.expect(all(&.{req_on}, .{ .sandbox_groups = &on }));
    try testing.expect(!all(&.{req_off}, .{ .sandbox_groups = &on }));
    // Code index 0 = No even though the option is carried.
    const off = [_]sandbox.Group{.{ .option_id = newbie.id, .index = 0 }};
    try testing.expect(!all(&.{req_on}, .{ .sandbox_groups = &off }));
    // An unknown option name refuses rather than guessing.
    var counts: Counts = .{};
    const unknown = Requirement{ .kind = .sandbox_option_bool, .arg = "NotAnOption" };
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{unknown}, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
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
    const random = Requirement{ .kind = .unsupported, .name = "RandomRoll" };
    var counts: Counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{random}, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
    // A gate that passes does not mask a later unsupported one.
    const alive = Requirement{ .kind = .is_alive };
    counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{ alive, random }, .{}, &counts));
    try testing.expectEqual(@as(u32, 1), counts.resolved);
    try testing.expectEqual(@as(u32, 1), counts.unsupported);
    // A failing gate short-circuits before the unsupported one.
    counts = .{};
    try testing.expectEqual(Verdict.fail, evaluate(&.{ alive, random }, .{ .alive = false }, &counts));
    try testing.expectEqual(@as(u32, 1), counts.resolved);
    try testing.expectEqual(@as(u32, 0), counts.unsupported);
    // `target="other"` is not resolvable in a self-only context.
    const foreign = Requirement{ .kind = .is_alive, .target = .other };
    counts = .{};
    try testing.expectEqual(Verdict.unsupported, evaluate(&.{foreign}, .{}, &counts));
}

test "all() is the AND over an empty and a multi-gate list" {
    try testing.expect(all(&.{}, .{}));
    const alive = Requirement{ .kind = .is_alive };
    const attached = Requirement{ .kind = .is_attached_to_entity };
    try testing.expect(all(&.{ alive, attached }, .{ .attached_to_entity = true }));
    try testing.expect(!all(&.{ alive, attached }, .{ .attached_to_entity = false }));
}
