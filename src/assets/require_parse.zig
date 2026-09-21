//! Requirement XML parse: kind/compare/target maps, the requirement
//! parser, and the group scanners.
//!
//! Split out of assets/requirements.zig (same code, moved verbatim);
//! re-exported so existing `requirements.*` call sites keep working.

const std = @import("std");
const xml = @import("xml_util.zig");
const Kind = @import("requirements.zig").Kind;
const Requirement = @import("requirements.zig").Requirement;
const Compare = @import("requirements.zig").Compare;
const Target = @import("requirements.zig").Target;

pub fn kindOf(name: []const u8) Kind {
    if (std.mem.eql(u8, name, "ProgressionLevel")) return .progression_level;
    if (std.mem.eql(u8, name, "PlayerLevel")) return .player_level;
    if (std.mem.eql(u8, name, "IsDayNumber")) return .is_day_number;
    if (std.mem.eql(u8, name, "TimeOfDay")) return .time_of_day;
    if (std.mem.eql(u8, name, "HasBuff")) return .has_buff;
    if (std.mem.eql(u8, name, "IsAlive")) return .is_alive;
    if (std.mem.eql(u8, name, "WasAlive")) return .was_alive;
    if (std.mem.eql(u8, name, "IsMale")) return .is_male;
    if (std.mem.eql(u8, name, "IsCorpse")) return .is_corpse;
    if (std.mem.eql(u8, name, "IsSleeping")) return .is_sleeping;
    if (std.mem.eql(u8, name, "TargetRange")) return .target_range;
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
    if (std.mem.eql(u8, name, "IsSecondaryAttack")) return .is_secondary_attack;
    if (std.mem.eql(u8, name, "InBiome")) return .in_biome;
    if (std.mem.eql(u8, name, "TriggerHasTags")) return .trigger_has_tags;
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
    if (std.mem.eql(u8, name, "IsDay")) return .is_day;
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
    if (std.mem.eql(u8, name, "PlayerItemCount")) return .player_item_count;
    if (std.mem.eql(u8, name, "HasTrackedEntity")) return .has_tracked_entity;
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
        xml.attr(hay, tag_start, "item_name") orelse
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
pub const require_eval = @import("require_eval.zig");
pub const compare = require_eval.compare;
pub const evaluate = require_eval.evaluate;
pub const all = require_eval.all;
pub const cvarValue = require_eval.cvarValue;
pub const parseMinMax = require_eval.parseMinMax;
pub const matchTagList = require_eval.matchTagList;
pub const tagListHas = require_eval.tagListHas;
pub const parseBodyParts = require_eval.parseBodyParts;
pub const levelOf = require_eval.levelOf;

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
