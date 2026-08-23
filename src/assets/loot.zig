//! loot.xml loader: groups + containers, simple deterministic rolls.

const std = @import("std");
const arena_util = @import("../util/arena.zig");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");

pub const max_groups: usize = 2048;
pub const max_containers: usize = 512;
/// Widest stock group (perkBooks has 133 entries); the cap must not truncate.
pub const max_entries: usize = 192;
pub const max_roll_stacks: usize = 8;

pub const LootEntry = struct {
    /// Item name or nested group name.
    name: []const u8 = "",
    is_group: bool = false,
    count_min: u16 = 1,
    count_max: u16 = 1,
    /// Probability weight (1.0 = always considered in equal pick).
    prob: f32 = 1,
    /// loot_prob_template index + 1 into LootTable.prob_templates; 0 = none.
    /// Resolved at load so the roll path never compares template names.
    prob_template: u16 = 0,
    /// force_prob="true": the entry rolls its prob independently instead of
    /// joining the group's pick pool (stock SpawnAllItemsFromList /
    /// SpawnLootItemsFromList forceProb branch, asm.il 698816).
    force_prob: bool = false,
};

/// One `<loot level="a,b" prob="p"/>` row of a `<lootprobtemplate>`.
pub const ProbBand = struct {
    min_level: i32 = 0,
    max_level: i32 = 0,
    prob: f32 = 0,
};

pub const ProbTemplate = struct {
    name: []const u8 = "",
    bands: []const ProbBand = &.{},
};

pub const LootGroup = struct {
    name: []const u8 = "",
    /// How many entries to pick (min,max).
    pick_min: u8 = 1,
    pick_max: u8 = 1,
    /// loot_quality_template name; empty = inherit the container's.
    quality_template: []const u8 = "",
    /// count="all": every entry spawns once (stock -1 sentinel →
    /// SpawnAllItemsFromList; regular prob is ignored, force_prob gates).
    pick_all: bool = false,
    entries: [max_entries]LootEntry = [_]LootEntry{.{}} ** max_entries,
    entry_n: u8 = 0,
};

pub const LootContainer = struct {
    name: []const u8 = "",
    size_x: u8 = 8,
    size_y: u8 = 6,
    /// loot_quality_template name (stock every container carries one).
    quality_template: []const u8 = "",
    /// destroy_on_close: 0 none, 1 "true" (destroy on unlock always), 2
    /// "empty" (destroy on unlock only when emptied). Stock
    /// TEFeatureStorage.ShouldDestroyOnClose (IL=19) + CheckDestroyTileEntity
    /// (IL=37, loot-economy.md 454-456).
    destroy_on_close: u8 = 0,
    entries: [max_entries]LootEntry = [_]LootEntry{.{}} ** max_entries,
    entry_n: u8 = 0,
};

pub const Stack = struct {
    item_name: []const u8 = "",
    count: u16 = 0,
    /// Rolled ItemValue quality (loot_quality_template by loot stage); 1 for
    /// stackables without a quality tier.
    quality: u8 = 1,
};

/// One quality-template level band: the loot stage window, the fallback
/// quality when no pick passes, and the prob-weighted quality picks.
pub const QualityPick = struct { quality: u8, prob: f32 };
pub const QualityBand = struct {
    min_level: i32 = 0,
    max_level: i32 = 999999,
    default_quality: u8 = 1,
    picks: []const QualityPick = &.{},
};
pub const QualityTemplate = struct {
    name: []const u8 = "",
    bands: []const QualityBand = &.{},
};

pub const LootTable = struct {
    groups: []const LootGroup = &.{},
    containers: []const LootContainer = &.{},
    prob_templates: []const ProbTemplate = &.{},
    quality_templates: []const QualityTemplate = &.{},
    /// `<loot_settings poi_tier_mod= poi_tier_bonus=>`: LootManager::POITierMod /
    /// POITierBonus, indexed by Prefab.DifficultyTier-1 (asm.il GetLootStage
    /// ~504240). Empty until a caller knows the POI it is standing in.
    poi_tier_mod: []const f32 = &.{},
    poi_tier_bonus: []const f32 = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,
    source: enum { builtin, xml } = .builtin,
    /// LootAbundance percent (serverconfig); scales rolled stack counts. 100 = 1×.
    abundance_pct: u16 = 100,

    /// LootContainer::getProbability (asm.il ~699478): a loot_prob_template
    /// replaces the entry's own prob with the band covering `loot_stage`.
    /// A template with no covering band falls back to the entry prob, exactly
    /// as the IL falls through its band loop.
    pub fn entryProb(self: *const LootTable, e: LootEntry, loot_stage: i32) f32 {
        if (e.prob_template == 0) return e.prob;
        const idx = e.prob_template - 1;
        if (idx >= self.prob_templates.len) return e.prob;
        for (self.prob_templates[idx].bands) |b| {
            if (loot_stage >= b.min_level and loot_stage <= b.max_level) return b.prob;
        }
        return e.prob;
    }

    /// Fixed-point milli-prob gate so the roll stays integer-only (DST replay).
    /// `s` is the caller's already-advanced LCG state.
    /// Resolve the looted item quality from a loot_quality_template by loot
    /// stage (stock SpawnItem quality-template branch, asm.il 698080): the
    /// first band whose level window contains the stage, then the first pick
    /// whose prob the roll beats, else the band default.
    pub fn resolveQuality(self: *const LootTable, template_name: []const u8, loot_stage: i32, s: u32) u8 {
        if (template_name.len == 0) return 1;
        for (self.quality_templates) |qt| {
            if (!std.mem.eql(u8, qt.name, template_name)) continue;
            for (qt.bands) |band| {
                if (loot_stage < band.min_level or loot_stage > band.max_level) continue;
                const roll: u32 = (s >> 16) % 1000;
                for (band.picks) |p| {
                    if (p.prob <= 0) continue;
                    const thresh: u32 = @round(p.prob * 1000.0);
                    if (roll <= thresh) return p.quality;
                }
                return band.default_quality;
            }
            return 1;
        }
        return 1;
    }

    fn probGate(self: *const LootTable, e: LootEntry, loot_stage: i32, s: u32) bool {
        const p = self.entryProb(e, loot_stage);
        // A NaN prob (crafted/patched loot.xml) fails both comparisons below and
        // the NaN→int conversion in `@round` traps; fail closed to match the C#
        // unchecked cast (NaN rounds to 0, i.e. never picked).
        if (!std.math.isFinite(p)) return false;
        if (p >= 1.0) return true;
        if (p <= 0.0) return false;
        const thresh: u32 = @round(p * 1000.0);
        return (s % 1000) <= thresh;
    }

    /// Scale a rolled count by LootAbundance, keeping at least 1.
    fn scaleCount(self: *const LootTable, cnt: u16) u16 {
        if (self.abundance_pct == 100) return @max(cnt, 1);
        const scaled = (@as(u32, cnt) * self.abundance_pct) / 100;
        return @intCast(@max(scaled, 1));
    }

    pub fn deinit(self: *LootTable) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
        self.* = builtin();
    }

    pub fn builtin() LootTable {
        return .{
            .groups = &builtin_groups,
            .containers = &builtin_containers,
            .source = .builtin,
        };
    }

    pub fn groupByName(self: *const LootTable, name: []const u8) ?*const LootGroup {
        for (self.groups) |*g| {
            if (std.mem.eql(u8, g.name, name)) return g;
        }
        return null;
    }

    pub fn containerByName(self: *const LootTable, name: []const u8) ?*const LootContainer {
        for (self.containers) |*c| {
            if (std.mem.eql(u8, c.name, name)) return c;
        }
        return null;
    }

    /// Roll a LootItem reward from a group (quests.xml `<reward type="LootItem"
    /// id="groupX" value="N" ischosen="true" isfixed="..."/>`): `picks` entries
    /// prob-weighted (uniform when all weights equal), or the first `picks`
    /// entries when `is_fixed` (deterministic). Stage bands still gate each
    /// entry. Returns the stack count.
    pub fn rollGroupPicks(self: *const LootTable, name: []const u8, loot_stage: i32, seed: u32, picks: u8, is_fixed: bool, out: []Stack) usize {
        const g = self.groupByName(name) orelse return 0;
        if (g.entry_n == 0 or picks == 0 or out.len == 0) return 0;
        const qt = g.quality_template;
        var n: usize = 0;
        var s = seed;
        if (is_fixed) {
            var i: u8 = 0;
            while (i < g.entry_n and n < picks and n < out.len) : (i += 1) {
                const e = g.entries[i];
                if (e.is_group) {
                    n += self.rollGroup(e.name, loot_stage, s ^ @as(u32, i), out[n..], 1, qt);
                } else {
                    out[n] = .{
                        .item_name = e.name,
                        .count = self.scaleCount(if (e.count_min > 0) e.count_min else 1),
                        .quality = self.resolveQuality(qt, loot_stage, s ^ @as(u32, i)),
                    };
                    n += 1;
                }
            }
            return n;
        }
        // Prob-weighted picks (stock ischosen reward selection): each pick
        // sums the entry weights, rolls a weighted index and gates the band.
        var p: u8 = 0;
        while (p < picks and n < out.len) : (p += 1) {
            s = s *% 1103515245 +% 12345;
            var total: u32 = 0;
            var e: u8 = 0;
            while (e < g.entry_n) : (e += 1) {
                total +|= @max(@as(u32, @intFromFloat(g.entries[e].prob * 1000)), 1);
            }
            if (total == 0) break;
            const roll = s % total;
            var chosen: u8 = 0;
            var acc: u32 = 0;
            while (chosen < g.entry_n) : (chosen += 1) {
                acc +|= @max(@as(u32, @intFromFloat(g.entries[chosen].prob * 1000)), 1);
                if (roll < acc) break;
            }
            if (chosen >= g.entry_n) chosen = g.entry_n - 1;
            const picked = g.entries[chosen];
            if (picked.force_prob) {
                if (!self.probGate(picked, loot_stage, s)) {
                    continue;
                }
            } else if (picked.prob_template != 0 and !self.probGate(picked, loot_stage, s)) continue;
            if (picked.is_group) {
                n += self.rollGroup(picked.name, loot_stage, s, out[n..], 1, qt);
            } else {
                const cmin = picked.count_min;
                const cmax = if (picked.count_max >= cmin) picked.count_max else cmin;
                const span: u32 = @as(u32, cmax) - @as(u32, cmin) + 1;
                const cnt: u16 = if (cmax == cmin) cmin else cmin + @as(u16, @intCast(s % span));
                out[n] = .{
                    .item_name = picked.name,
                    .count = self.scaleCount(cnt),
                    .quality = self.resolveQuality(qt, loot_stage, s),
                };
                n += 1;
            }
        }
        return n;
    }

    /// Deterministic roll into `out` at `loot_stage`. Returns stack count.
    /// Pass 1 for "no gamestage information"; the templates' first band starts
    /// at level 0 or 1, so stage 1 is the honest floor, not a magic value.
    pub fn rollContainer(self: *const LootTable, name: []const u8, loot_stage: i32, seed: u32, out: []Stack) usize {
        const cont = self.containerByName(name) orelse {
            // Unknown: try as group name.
            return self.rollGroup(name, loot_stage, seed, out, 0, "");
        };
        var n: usize = 0;
        var s = seed ^ 0x9e3779b9;
        var i: u8 = 0;
        while (i < cont.entry_n and n < out.len) : (i += 1) {
            const e = cont.entries[i];
            s = s *% 1103515245 +% 12345;
            // Every entry rolls its own prob (stock LootContainer.roll): a
            // force_prob entry gates independently (stock forceProb branch)
            // and a plain entry gates on its prob the same way. The old
            // index-0-always exception is gone - it was data-benign (0 of the
            // 339 stock containers have a plain first entry with prob < 1)
            // but wrong for hypothetical data.
            const gate = !self.probGate(e, loot_stage, s);
            if (gate) continue;
            if (e.is_group) {
                n += self.rollGroup(e.name, loot_stage, s, out[n..], 0, cont.quality_template);
            } else {
                const cmin = e.count_min;
                const cmax = if (e.count_max >= cmin) e.count_max else cmin;
                // Full-domain ranges (0..65535) make the u16 span arithmetic
                // overflow; widen so the modulo never sees a wrapped zero.
                const span: u32 = @as(u32, cmax) - @as(u32, cmin) + 1;
                const cnt: u16 = if (cmax == cmin) cmin else cmin + @as(u16, @intCast(s % span));
                out[n] = .{
                    .item_name = e.name,
                    .count = self.scaleCount(cnt),
                    .quality = self.resolveQuality(cont.quality_template, loot_stage, s),
                };
                n += 1;
            }
        }
        // Fail closed (AGENTS rule 10): stock LootContainer.roll yields an
        // empty container when every entry fails its prob gate; never invent
        // items loot.xml does not define.
        return n;
    }

    fn rollGroup(self: *const LootTable, name: []const u8, loot_stage: i32, seed: u32, out: []Stack, depth: u8, inherit_template: []const u8) usize {
        if (depth > 6 or out.len == 0) return 0;
        const g = self.groupByName(name) orelse return 0;
        if (g.entry_n == 0) return 0;
        const qt = if (g.quality_template.len > 0) g.quality_template else inherit_template;
        var s = seed;
        // count="all" (stock -1): every entry spawns once; regular prob is
        // ignored, force_prob entries gate independently (SpawnAllItemsFromList,
        // asm.il 698452).
        if (g.pick_all) {
            var an: usize = 0;
            var ai: u8 = 0;
            while (ai < g.entry_n and an < out.len) : (ai += 1) {
                const e = g.entries[ai];
                s = s *% 1103515245 +% 12345;
                if (e.force_prob and !self.probGate(e, loot_stage, s)) continue;
                if (e.is_group) {
                    an += self.rollGroup(e.name, loot_stage, s, out[an..], depth + 1, qt);
                } else {
                    const cmin = e.count_min;
                    const cmax = if (e.count_max >= cmin) e.count_max else cmin;
                    const span: u32 = @as(u32, cmax) - @as(u32, cmin) + 1;
                    const cnt: u16 = if (cmax == cmin) cmin else cmin + @as(u16, @intCast(s % span));
                    out[an] = .{ .item_name = e.name, .count = self.scaleCount(cnt), .quality = self.resolveQuality(qt, loot_stage, s) };
                    an += 1;
                }
            }
            return an;
        }
        const picks: u8 = blk: {
            if (g.pick_max <= g.pick_min) break :blk g.pick_min;
            s = s *% 1103515245 +% 12345;
            // Same widening as the count spans: count="0,255" on a group would
            // overflow the u8 span (255-0+1 = 256).
            const span: u32 = @as(u32, g.pick_max) - @as(u32, g.pick_min) + 1;
            break :blk g.pick_min + @as(u8, @intCast(s % span));
        };
        var n: usize = 0;
        var p: u8 = 0;
        while (p < picks and n < out.len) : (p += 1) {
            s = s *% 1103515245 +% 12345;
            // Prob-weighted pick (stock LootContainer probability): each
            // entry's stage-resolved prob is its weight relative to the group
            // sum, so a 0.9 item drops ~9x as often as a 0.1 one. A zero-prob
            // plain entry gets weight 0 (never picked); force_prob entries
            // keep weight 1 and gate independently (their prob is a per-pick
            // chance, not a relative weight, stock force_prob semantics).
            var total: u32 = 0;
            var e: u8 = 0;
            while (e < g.entry_n) : (e += 1) {
                total +|= self.groupEntryWeight(g.entries[e], loot_stage);
            }
            if (total == 0) break;
            const roll = s % total;
            var chosen: u8 = 0;
            var acc: u32 = 0;
            while (chosen < g.entry_n) : (chosen += 1) {
                acc +|= self.groupEntryWeight(g.entries[chosen], loot_stage);
                if (roll < acc) break;
            }
            if (chosen >= g.entry_n) chosen = g.entry_n - 1;
            const picked_e = g.entries[chosen];
            // A picked entry still has to clear its loot stage band, so a
            // low-stage player cannot pull a top-tier item out of a group.
            // A force_prob entry rolls its prob independently.
            if (picked_e.force_prob) {
                if (!self.probGate(picked_e, loot_stage, s)) continue;
            } else if (picked_e.prob_template != 0 and !self.probGate(picked_e, loot_stage, s)) continue;
            if (picked_e.is_group) {
                n += self.rollGroup(picked_e.name, loot_stage, s, out[n..], depth + 1, qt);
            } else {
                const cmin = picked_e.count_min;
                const cmax = if (picked_e.count_max >= cmin) picked_e.count_max else cmin;
                // Same span widening as rollContainer (count="0,65535").
                const span: u32 = @as(u32, cmax) - @as(u32, cmin) + 1;
                const cnt: u16 = if (cmax == cmin) cmin else cmin + @as(u16, @intCast(s % span));
                out[n] = .{ .item_name = picked_e.name, .count = self.scaleCount(cnt), .quality = self.resolveQuality(qt, loot_stage, s) };
                n += 1;
            }
        }
        return n;
    }

    /// Prob weight of one group entry for a weighted pick: force_prob entries
    /// weigh 1 (their prob is a per-pick gate), plain/template entries weigh
    /// their stage-resolved prob (prob <= 0 = weight 0, unpickable).
    fn groupEntryWeight(self: *const LootTable, e: LootEntry, loot_stage: i32) u32 {
        if (e.force_prob) return 1;
        const ep = self.entryProb(e, loot_stage);
        if (!(ep > 0)) return 0;
        return @intFromFloat(@min(ep, 10.0) * 1000.0);
    }
};

test "loot abundance scales counts, keeps at least one" {
    var lt = LootTable.builtin();
    var base: [max_roll_stacks]Stack = undefined;
    const nb = lt.rollContainer("woodenChest", 1, 12345, &base);
    lt.abundance_pct = 200;
    var big: [max_roll_stacks]Stack = undefined;
    const ng = lt.rollContainer("woodenChest", 1, 12345, &big);
    try std.testing.expectEqual(nb, ng);
    // Every non-fallback stack doubles (same seed → same base counts).
    var i: usize = 0;
    while (i < nb) : (i += 1) {
        try std.testing.expectEqualStrings(base[i].item_name, big[i].item_name);
        try std.testing.expectEqual(base[i].count * 2, big[i].count);
    }
    // A tiny abundance still yields at least 1 per stack.
    lt.abundance_pct = 1;
    var small: [max_roll_stacks]Stack = undefined;
    const ns = lt.rollContainer("woodenChest", 1, 12345, &small);
    i = 0;
    while (i < ns) : (i += 1) try std.testing.expect(small[i].count >= 1);
}

const builtin_groups = [_]LootGroup{
    blk: {
        var g: LootGroup = .{
            .name = "groupScrapCommon",
            .pick_min = 1,
            .pick_max = 1,
            .entry_n = 2,
        };
        g.entries[0] = .{ .name = "resourceScrapIron", .count_min = 3, .count_max = 8 };
        g.entries[1] = .{ .name = "resourceScrapLead", .count_min = 2, .count_max = 6 };
        break :blk g;
    },
};

const builtin_containers = [_]LootContainer{
    blk: {
        var c: LootContainer = .{
            .name = "EntityLootContainerRegular",
            .size_x = 6,
            .size_y = 2,
            .entry_n = 2,
        };
        c.entries[0] = .{ .name = "groupScrapCommon", .is_group = true };
        c.entries[1] = .{ .name = "foodCanBeef", .count_min = 1, .count_max = 2, .prob = 0.35 };
        break :blk c;
    },
    blk: {
        var c: LootContainer = .{
            .name = "woodenChest",
            .size_x = 6,
            .size_y = 2,
            .entry_n = 2,
        };
        c.entries[0] = .{ .name = "groupScrapCommon", .is_group = true };
        c.entries[1] = .{ .name = "resourceWood", .count_min = 5, .count_max = 15 };
        break :blk c;
    },
};

fn parseCountRange(s: []const u8) struct { min: u16, max: u16 } {
    if (std.mem.findScalar(u8, s, ',')) |c| {
        const a = xml.parseU16(std.mem.trim(u8, s[0..c], " \t")) orelse 1;
        const b = xml.parseU16(std.mem.trim(u8, s[c + 1 ..], " \t")) orelse a;
        return .{ .min = a, .max = b };
    }
    const v = xml.parseU16(std.mem.trim(u8, s, " \t")) orelse 1;
    return .{ .min = v, .max = v };
}

fn parseItemOrGroup(tag_src: []const u8, tag_at: usize, templates: []const ProbTemplate) ?LootEntry {
    const is_group = xml.attr(tag_src, tag_at, "group") != null;
    const name = if (is_group) xml.attr(tag_src, tag_at, "group") else xml.attr(tag_src, tag_at, "name");
    const n = name orelse return null;
    const cr = parseCountRange(xml.attr(tag_src, tag_at, "count") orelse "1");
    const prob = xml.parseF32(xml.attr(tag_src, tag_at, "prob") orelse "1") orelse 1;
    const fp = xml.attr(tag_src, tag_at, "force_prob") orelse "";
    var tpl: u16 = 0;
    if (xml.attr(tag_src, tag_at, "loot_prob_template")) |tn| {
        for (templates, 0..) |t, ti| {
            if (std.mem.eql(u8, t.name, tn)) {
                tpl = @intCast(ti + 1);
                break;
            }
        }
    }
    return .{
        .name = n,
        .is_group = is_group,
        .count_min = cr.min,
        .count_max = cr.max,
        .prob = prob,
        .prob_template = tpl,
        .force_prob = std.mem.eql(u8, fp, "true") or std.mem.eql(u8, fp, "True"),
    };
}

/// `level="a,b"` on a `<loot>` band; a bare number covers exactly that level.
fn parseLevelRange(s: []const u8) struct { min: i32, max: i32 } {
    const comma = std.mem.findScalar(u8, s, ',') orelse {
        const v = std.fmt.parseInt(i32, std.mem.trim(u8, s, " \t"), 10) catch 0;
        return .{ .min = v, .max = v };
    };
    const a = std.fmt.parseInt(i32, std.mem.trim(u8, s[0..comma], " \t"), 10) catch 0;
    const b = std.fmt.parseInt(i32, std.mem.trim(u8, s[comma + 1 ..], " \t"), 10) catch a;
    return .{ .min = a, .max = @max(a, b) };
}

/// Comma list of floats into an arena slice (`poi_tier_mod="0.05,0.1,…"`).
fn parseF32List(arena: std.mem.Allocator, s: []const u8) ![]const f32 {
    var n: usize = 0;
    var count_it = std.mem.splitScalar(u8, s, ',');
    while (count_it.next()) |_| n += 1;
    const out = try arena.alloc(f32, n);
    var i: usize = 0;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |part| : (i += 1) {
        out[i] = xml.parseF32(std.mem.trim(u8, part, " \t")) orelse 0;
    }
    return out;
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !LootTable {
    const raw = try io_fs.readFileAll(allocator, path);
    defer allocator.free(raw);
    return loadFromSlice(allocator, raw);
}

pub fn loadFromSlice(allocator: std.mem.Allocator, raw: []const u8) !LootTable {
    const clean = try xml.stripComments(allocator, raw);
    defer allocator.free(clean);

    const arena_holder = try arena_util.newArenaHolder(allocator);
    errdefer {
        arena_holder.deinit();
        allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();

    var groups: std.ArrayList(LootGroup) = .empty;
    defer groups.deinit(allocator);
    var containers: std.ArrayList(LootContainer) = .empty;
    defer containers.deinit(allocator);

    // <loot_settings poi_tier_mod="…" poi_tier_bonus="…"/>
    var poi_mod: []const f32 = &.{};
    var poi_bonus: []const f32 = &.{};
    if (std.mem.find(u8, clean, "<loot_settings")) |ls| {
        if (xml.attr(clean, ls, "poi_tier_mod")) |v| poi_mod = try parseF32List(arena, v);
        if (xml.attr(clean, ls, "poi_tier_bonus")) |v| poi_bonus = try parseF32List(arena, v);
    }

    // lootprobtemplate: parsed first so item rows can resolve to an index.
    var templates: std.ArrayList(ProbTemplate) = .empty;
    defer templates.deinit(allocator);
    var bands: std.ArrayList(ProbBand) = .empty;
    defer bands.deinit(allocator);
    var ti: usize = 0;
    while (std.mem.findPos(u8, clean, ti, "<lootprobtemplate")) |tag| {
        const gt = std.mem.findPos(u8, clean, tag, ">") orelse break;
        const name = xml.attr(clean, tag, "name") orelse {
            ti = gt + 1;
            continue;
        };
        var body: []const u8 = "";
        ti = gt + 1;
        if (!(gt > tag and clean[gt - 1] == '/')) {
            const close = std.mem.findPos(u8, clean, gt, "</lootprobtemplate>") orelse break;
            body = clean[gt + 1 .. close];
            ti = close + 19;
        }
        bands.clearRetainingCapacity();
        var bi: usize = 0;
        while (std.mem.findPos(u8, body, bi, "<loot")) |ltag| {
            bi = ltag + 5;
            const lvl = xml.attr(body, ltag, "level") orelse continue;
            const lr = parseLevelRange(lvl);
            try bands.append(allocator, .{
                .min_level = lr.min,
                .max_level = lr.max,
                .prob = xml.parseF32(std.mem.trim(u8, xml.attr(body, ltag, "prob") orelse "0", " \t")) orelse 0,
            });
        }
        if (bands.items.len == 0) continue;
        try templates.append(allocator, .{
            .name = try arena.dupe(u8, name),
            .bands = try arena.dupe(ProbBand, bands.items),
        });
    }
    const tpl = try arena.dupe(ProbTemplate, templates.items);

    // lootqualitytemplate: level bands with prob-weighted quality picks.
    var q_templates: std.ArrayList(QualityTemplate) = .empty;
    defer q_templates.deinit(allocator);
    var qti: usize = 0;
    while (std.mem.findPos(u8, clean, qti, "<lootqualitytemplate")) |qt_tag| {
        const qt_name = xml.attr(clean, qt_tag, "name") orelse {
            qti = qt_tag + 21;
            continue;
        };
        const qt_gt = std.mem.findPos(u8, clean, qt_tag, ">") orelse break;
        var qt_body: []const u8 = "";
        qti = qt_gt + 1;
        if (!(qt_gt > qt_tag and clean[qt_gt - 1] == '/')) {
            const qt_close = std.mem.findPos(u8, clean, qt_gt, "</lootqualitytemplate>") orelse break;
            qt_body = clean[qt_gt + 1 .. qt_close];
            qti = qt_close + 22;
        }
        var q_bands: std.ArrayList(QualityBand) = .empty;
        defer q_bands.deinit(allocator);
        var bi: usize = 0;
        while (std.mem.findPos(u8, qt_body, bi, "<qualitytemplate")) |b_tag| {
            bi = b_tag + 16;
            const lvl = xml.attr(qt_body, b_tag, "level") orelse continue;
            const lr = parseLevelRange(lvl);
            const dflt = xml.parseU16(std.mem.trim(u8, xml.attr(qt_body, b_tag, "default_quality") orelse "1", " \t")) orelse 1;
            const b_gt = std.mem.findPos(u8, qt_body, b_tag, ">") orelse break;
            var b_body: []const u8 = "";
            if (!(b_gt > b_tag and qt_body[b_gt - 1] == '/')) {
                const b_close = std.mem.findPos(u8, qt_body, b_gt, "</qualitytemplate>") orelse break;
                b_body = qt_body[b_gt + 1 .. b_close];
            }
            var picks: std.ArrayList(QualityPick) = .empty;
            defer picks.deinit(allocator);
            var pi: usize = 0;
            while (std.mem.findPos(u8, b_body, pi, "<loot ")) |p_tag| {
                pi = p_tag + 6;
                const q = xml.parseU16(std.mem.trim(u8, xml.attr(b_body, p_tag, "quality") orelse "1", " \t")) orelse 1;
                const p = xml.parseF32(std.mem.trim(u8, xml.attr(b_body, p_tag, "prob") orelse "0", " \t")) orelse 0;
                try picks.append(allocator, .{ .quality = @intCast(@min(q, 255)), .prob = p });
            }
            try q_bands.append(allocator, .{
                .min_level = lr.min,
                .max_level = lr.max,
                .default_quality = @intCast(@min(dflt, 255)),
                .picks = try arena.dupe(QualityPick, picks.items),
            });
        }
        if (q_bands.items.len == 0) continue;
        try q_templates.append(allocator, .{
            .name = try arena.dupe(u8, qt_name),
            .bands = try arena.dupe(QualityBand, q_bands.items),
        });
    }
    const q_tpl = try arena.dupe(QualityTemplate, q_templates.items);

    // lootgroup
    var i: usize = 0;
    while (i < clean.len and groups.items.len < max_groups) {
        const tag = std.mem.findPos(u8, clean, i, "<lootgroup") orelse break;
        const name = xml.attr(clean, tag, "name") orelse {
            i = tag + 10;
            continue;
        };
        const gt = std.mem.findPos(u8, clean, tag, ">") orelse break;
        var body: []const u8 = "";
        var next_i = gt + 1;
        if (!(gt > tag and clean[gt - 1] == '/')) {
            const close = std.mem.findPos(u8, clean, gt, "</lootgroup>") orelse break;
            body = clean[gt + 1 .. close];
            next_i = close + 12;
        }
        var g: LootGroup = .{
            .name = try arena.dupe(u8, name),
        };
        if (xml.attr(clean, tag, "loot_quality_template")) |lqt| {
            g.quality_template = try arena.dupe(u8, lqt);
        }
        if (xml.attr(clean, tag, "count")) |cv| {
            if (std.mem.eql(u8, cv, "all")) {
                g.pick_all = true;
            } else {
                const cr = parseCountRange(cv);
                g.pick_min = @intCast(@min(cr.min, 255));
                g.pick_max = @intCast(@min(cr.max, 255));
            }
        }
        var bi: usize = 0;
        while (bi < body.len and g.entry_n < max_entries) {
            const itag = std.mem.findPos(u8, body, bi, "<item") orelse break;
            if (parseItemOrGroup(body, itag, tpl)) |ent| {
                var e = ent;
                e.name = try arena.dupe(u8, ent.name);
                g.entries[g.entry_n] = e;
                g.entry_n += 1;
            }
            bi = itag + 5;
        }
        try groups.append(allocator, g);
        i = next_i;
    }

    // lootcontainer
    i = 0;
    while (i < clean.len and containers.items.len < max_containers) {
        const tag = std.mem.findPos(u8, clean, i, "<lootcontainer") orelse break;
        const name = xml.attr(clean, tag, "name") orelse {
            i = tag + 14;
            continue;
        };
        const gt = std.mem.findPos(u8, clean, tag, ">") orelse break;
        var body: []const u8 = "";
        var next_i = gt + 1;
        if (!(gt > tag and clean[gt - 1] == '/')) {
            const close = std.mem.findPos(u8, clean, gt, "</lootcontainer>") orelse break;
            body = clean[gt + 1 .. close];
            next_i = close + 16;
        }
        var c: LootContainer = .{
            .name = try arena.dupe(u8, name),
        };
        if (xml.attr(clean, tag, "loot_quality_template")) |lqt| {
            c.quality_template = try arena.dupe(u8, lqt);
        }
        if (xml.attr(clean, tag, "size")) |sz| {
            if (std.mem.findScalar(u8, sz, ',')) |comma| {
                c.size_x = @intCast(xml.parseU16(std.mem.trim(u8, sz[0..comma], " \t")) orelse 8);
                c.size_y = @intCast(xml.parseU16(std.mem.trim(u8, sz[comma + 1 ..], " \t")) orelse 6);
            }
        }
        // destroy_on_close: "true" (1) / "empty" (2) / absent (0). Values
        // feed TEFeatureStorage.ShouldDestroyOnClose (loot-economy.md).
        if (xml.attr(clean, tag, "destroy_on_close")) |doc| {
            if (std.mem.eql(u8, doc, "true")) {
                c.destroy_on_close = 1;
            } else if (std.mem.eql(u8, doc, "empty")) {
                c.destroy_on_close = 2;
            }
        }
        var bi: usize = 0;
        while (bi < body.len and c.entry_n < max_entries) {
            const itag = std.mem.findPos(u8, body, bi, "<item") orelse break;
            if (parseItemOrGroup(body, itag, tpl)) |ent| {
                var e = ent;
                e.name = try arena.dupe(u8, ent.name);
                c.entries[c.entry_n] = e;
                c.entry_n += 1;
            }
            bi = itag + 5;
        }
        try containers.append(allocator, c);
        i = next_i;
    }

    return .{
        .groups = try arena.dupe(LootGroup, groups.items),
        .containers = try arena.dupe(LootContainer, containers.items),
        .prob_templates = tpl,
        .quality_templates = q_tpl,
        .poi_tier_mod = poi_mod,
        .poi_tier_bonus = poi_bonus,
        .arena_ptr = arena_holder,
        .source = .xml,
    };
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?LootTable {
    const paths = @import("paths.zig");
    return paths.tryLoadConfig("loot.xml", LootTable, loadFromPath, allocator, game_dir, config_dir);
}

test "builtin loot roll" {
    const t = LootTable.builtin();
    var stacks: [max_roll_stacks]Stack = undefined;
    const n = t.rollContainer("EntityLootContainerRegular", 1, 42, &stacks);
    try std.testing.expect(n >= 1);
    try std.testing.expect(stacks[0].count >= 1);
}

test "load stock loot when present" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/loot.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expect(t.groups.len > 50);
    try std.testing.expect(t.containers.len > 20);
    try std.testing.expect(t.containerByName("woodenChest") != null);
    var stacks: [max_roll_stacks]Stack = undefined;
    // Fail-closed rolls mean a single seed can legitimately come up empty
    // (stock prob gates); some seed in a spread must still yield loot.
    var total: usize = 0;
    var seed: u32 = 0;
    while (seed < 32) : (seed += 1) {
        total += t.rollContainer("woodenChest", 7, seed, &stacks);
    }
    try std.testing.expect(total >= 1);
}

test "loot prob templates gate entries by loot stage" {
    const src =
        \\<lootcontainers>
        \\<loot_settings poi_tier_mod="0.05,0.1,0.15" poi_tier_bonus="3,6,9"/>
        \\<lootprobtemplates>
        \\  <lootprobtemplate name="veryLowDelayed">
        \\    <loot level="0,14" prob="0"/>
        \\    <loot level="15,999999" prob=".05"/>
        \\  </lootprobtemplate>
        \\  <lootprobtemplate name="guaranteed">
        \\    <loot level="1,999999" prob="1"/>
        \\  </lootprobtemplate>
        \\</lootprobtemplates>
        \\<lootgroup name="g">
        \\  <item name="always" loot_prob_template="guaranteed"/>
        \\  <item name="plain"/>
        \\</lootgroup>
        \\<lootcontainer name="c" size="6,2">
        \\  <item name="gated" loot_prob_template="veryLowDelayed"/>
        \\  <item name="plain"/>
        \\</lootcontainer>
        \\</lootcontainers>
    ;
    var t = try loadFromSlice(std.testing.allocator, src);
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 2), t.prob_templates.len);
    try std.testing.expectEqual(@as(usize, 3), t.poi_tier_mod.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.15), t.poi_tier_mod[2], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 3), t.poi_tier_bonus[0], 0.0001);

    const cont = t.containerByName("c").?;
    const gated = cont.entries[0];
    const plain = cont.entries[1];
    // veryLowDelayed: zero below stage 15, .05 at and above it.
    try std.testing.expectApproxEqAbs(@as(f32, 0), t.entryProb(gated, 0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), t.entryProb(gated, 14), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), t.entryProb(gated, 15), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), t.entryProb(gated, 999999), 0.0001);
    // Above the last band nothing matches, so the entry's own prob applies.
    try std.testing.expectApproxEqAbs(@as(f32, 1), t.entryProb(gated, 1_000_000), 0.0001);
    // An entry with no template is stage-blind (unchanged behaviour).
    try std.testing.expectApproxEqAbs(@as(f32, 1), t.entryProb(plain, 0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), t.entryProb(plain, 5000), 0.0001);

    // The zero band must suppress the item across every seed, and the .05 band
    // must let it through at least once.
    var stacks: [max_roll_stacks]Stack = undefined;
    var seen_low: usize = 0;
    var seen_high: usize = 0;
    var seed: u32 = 0;
    while (seed < 400) : (seed += 1) {
        var n = t.rollContainer("c", 0, seed, &stacks);
        for (stacks[0..n]) |st| {
            if (std.mem.eql(u8, st.item_name, "gated")) seen_low += 1;
        }
        n = t.rollContainer("c", 40, seed, &stacks);
        for (stacks[0..n]) |st| {
            if (std.mem.eql(u8, st.item_name, "gated")) seen_high += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), seen_low);
    try std.testing.expect(seen_high >= 1);
}

test "all-gated roll yields an empty container, not fabricated items" {
    const src =
        \\<lootcontainers>
        \\<lootprobtemplates>
        \\  <lootprobtemplate name="never">
        \\    <loot level="0,999999" prob="0"/>
        \\  </lootprobtemplate>
        \\</lootprobtemplates>
        \\<lootcontainer name="emptyOk" size="6,2">
        \\  <item name="gatedA" loot_prob_template="never"/>
        \\  <item name="gatedB" prob="0"/>
        \\</lootcontainer>
        \\</lootcontainers>
    ;
    var t = try loadFromSlice(std.testing.allocator, src);
    defer t.deinit();
    var stacks: [max_roll_stacks]Stack = undefined;
    var seed: u32 = 0;
    while (seed < 50) : (seed += 1) {
        const n = t.rollContainer("emptyOk", 30, seed, &stacks);
        try std.testing.expectEqual(@as(usize, 0), n);
    }
}

test "loot quality template rolls quality by loot stage" {
    const src =
        \\<lootcontainers>
        \\<lootqualitytemplate name="qualTest">
        \\  <qualitytemplate level="0,9" default_quality="1">
        \\    <loot quality="1" prob="0.5"/>
        \\    <loot quality="2" prob="1"/>
        \\  </qualitytemplate>
        \\  <qualitytemplate level="10,999999" default_quality="6">
        \\    <loot quality="4" prob="0.1"/>
        \\    <loot quality="6" prob="1"/>
        \\  </qualitytemplate>
        \\</lootqualitytemplate>
        \\<lootgroup name="g">
        \\  <item name="weaponA"/>
        \\</lootgroup>
        \\<lootcontainer name="c" size="6,2" loot_quality_template="qualTest">
        \\  <item name="weaponA"/>
        \\</lootcontainer>
        \\</lootcontainers>
    ;
    var t = try loadFromSlice(std.testing.allocator, src);
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 1), t.quality_templates.len);
    try std.testing.expectEqualStrings("qualTest", t.containerByName("c").?.quality_template);
    // Stage 1: band 0-9, picks 1 (p.5) then 2 (p1) - quality in {1,2}.
    var stacks: [16]Stack = undefined;
    var saw_hi = false;
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        const n = t.rollContainer("c", 1, 9000 + i, &stacks);
        for (stacks[0..n]) |s| {
            try std.testing.expect(s.quality == 1 or s.quality == 2);
            if (s.quality == 2) saw_hi = true;
        }
    }
    try std.testing.expect(saw_hi);
    // Stage 15: band 10+, picks 4 (p.1) then 6 (p1) - quality in {4,6}.
    var saw_6 = false;
    i = 0;
    while (i < 200) : (i += 1) {
        const n = t.rollContainer("c", 15, 7000 + i, &stacks);
        for (stacks[0..n]) |s| {
            try std.testing.expect(s.quality == 4 or s.quality == 6);
            if (s.quality == 6) saw_6 = true;
        }
    }
    try std.testing.expect(saw_6);
    std.debug.print("PASS loot quality: template rolls quality by loot stage\n", .{});
}

test "count=all groups spawn every entry; force_prob gates independently" {
    const src =
        \\<lootcontainers>
        \\<lootgroup name="allGroup" count="all">
        \\  <item name="a" prob="0"/>
        \\  <item name="b" prob="0.0001"/>
        \\  <item name="c" prob="1"/>
        \\  <item name="gated" prob="1" force_prob="true"/>
        \\</lootgroup>
        \\<lootgroup name="pickGroup" count="1">
        \\  <item name="x" force_prob="true" prob="0"/>
        \\  <item name="y" force_prob="true" prob="1"/>
        \\  <item name="z"/>
        \\</lootgroup>
        \\</lootcontainers>
    ;
    var t = try loadFromSlice(std.testing.allocator, src);
    defer t.deinit();
    const ag = t.groupByName("allGroup").?;
    try std.testing.expect(ag.pick_all);
    try std.testing.expectEqual(@as(u8, 4), ag.entry_n);
    // count="all": every entry spawns once regardless of prob; the force_prob
    // entry gates on its own prob (1 here so it stays).
    var stacks: [16]Stack = undefined;
    const n = t.rollGroup("allGroup", 1, 7, &stacks, 0, "");
    try std.testing.expectEqual(@as(usize, 4), n);
    var saw_all = true;
    for ([_][]const u8{ "a", "b", "c", "gated" }) |want| {
        var seen = false;
        for (stacks[0..n]) |s| {
            if (std.mem.eql(u8, s.item_name, want)) seen = true;
        }
        if (!seen) saw_all = false;
    }
    try std.testing.expect(saw_all);
    // force_prob prob=0 is never picked from the pick pool.
    var s2: [16]Stack = undefined;
    var i: u32 = 0;
    var saw_x = false;
    while (i < 200) : (i += 1) {
        const n2 = t.rollGroup("pickGroup", 1, 1000 + i, &s2, 0, "");
        for (s2[0..n2]) |s| {
            if (std.mem.eql(u8, s.item_name, "x")) saw_x = true;
        }
    }
    try std.testing.expect(!saw_x);
    std.debug.print("PASS loot: count=all spawns every entry, force_prob gates\n", .{});
}

test "stock groups parse past the old 32-entry cap (perkBooks)" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/loot.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    // perkBooks has 133 entries; the cap must not truncate stock groups.
    if (t.groupByName("perkBooks")) |g| {
        try std.testing.expect(g.entry_n >= 100);
        try std.testing.expect(g.entry_n <= max_entries);
    }
}

test "loot rolls stay deterministic for a given stage and seed" {
    const t = LootTable.builtin();
    var a: [max_roll_stacks]Stack = undefined;
    var b: [max_roll_stacks]Stack = undefined;
    const na = t.rollContainer("woodenChest", 37, 99, &a);
    const nb = t.rollContainer("woodenChest", 37, 99, &b);
    try std.testing.expectEqual(na, nb);
    for (a[0..na], b[0..nb]) |x, y| {
        try std.testing.expectEqualStrings(x.item_name, y.item_name);
        try std.testing.expectEqual(x.count, y.count);
    }
    // Stage 0 and the i32 extremes must not trap.
    _ = t.rollContainer("woodenChest", 0, 1, &a);
    _ = t.rollContainer("woodenChest", std.math.minInt(i32), 1, &a);
    _ = t.rollContainer("woodenChest", std.math.maxInt(i32), 1, &a);
}

test "stock loot prob templates load and band the real items" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/loot.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expect(t.prob_templates.len > 10);
    // loot_settings ships five POI tiers.
    try std.testing.expectEqual(@as(usize, 5), t.poi_tier_mod.len);
    try std.testing.expectEqual(@as(usize, 5), t.poi_tier_bonus.len);
    // At least one item row must reference a template, else the resolve step
    // silently did nothing.
    var referenced: usize = 0;
    for (t.groups) |g| {
        var i: u8 = 0;
        while (i < g.entry_n) : (i += 1) {
            if (g.entries[i].prob_template != 0) referenced += 1;
        }
    }
    try std.testing.expect(referenced > 100);
    // ProbT0's documented mid band: level 20,21 → prob 1.
    for (t.prob_templates) |p| {
        if (!std.mem.eql(u8, p.name, "ProbT0")) continue;
        var hit = false;
        for (p.bands) |b| {
            if (b.min_level == 20 and b.max_level == 21) {
                try std.testing.expectApproxEqAbs(@as(f32, 1), b.prob, 0.0001);
                hit = true;
            }
        }
        try std.testing.expect(hit);
    }
}

test "reward group rolls fixed first picks or prob-weighted choices" {
    const xml_text =
        \\<loot>
        \\  <lootgroup name="groupQuestWeapons">
        \\    <item name="gunPistolT2" count="1" prob="1"/>
        \\    <item name="gunRifleT2" count="1" prob="1"/>
        \\    <item name="meleeClubT2" count="1" prob="1"/>
        \\  </lootgroup>
        \\</loot>
    ;
    var lt = try loadFromSlice(std.testing.allocator, xml_text);
    defer lt.deinit();
    var stacks: [8]Stack = undefined;
    // isfixed: the first two entries, deterministic.
    const nf = lt.rollGroupPicks("groupQuestWeapons", 1, 42, 2, true, &stacks);
    try std.testing.expectEqual(@as(usize, 2), nf);
    try std.testing.expectEqualStrings("gunPistolT2", stacks[0].item_name);
    try std.testing.expectEqualStrings("gunRifleT2", stacks[1].item_name);
    // Weighted picks: each pick resolves to one of the three.
    const nw = lt.rollGroupPicks("groupQuestWeapons", 1, 42, 3, false, &stacks);
    try std.testing.expectEqual(@as(usize, 3), nw);
    var i: usize = 0;
    while (i < nw) : (i += 1) {
        try std.testing.expect(std.mem.eql(u8, stacks[i].item_name, "gunPistolT2") or
            std.mem.eql(u8, stacks[i].item_name, "gunRifleT2") or
            std.mem.eql(u8, stacks[i].item_name, "meleeClubT2"));
    }
    // Unknown group returns nothing (fail closed).
    try std.testing.expectEqual(@as(usize, 0), lt.rollGroupPicks("noSuchGroup", 1, 1, 1, false, &stacks));
}

test "container group rolls are prob-weighted, not uniform" {
    // Stock LootContainer probability: an entry's prob weights it relative
    // to the group sum, so a 0.9 item drops ~9x as often as a 0.1 one and a
    // 0-prob item never drops. The old rollGroup picked a uniform index.
    const xml_text =
        \\<loot>
        \\  <lootgroup name="gWeighted">
        \\    <item name="commonItem" count="1" prob="0.9"/>
        \\    <item name="rareItem" count="1" prob="0.1"/>
        \\    <item name="neverItem" count="1" prob="0"/>
        \\  </lootgroup>
        \\  <lootcontainer name="cWeighted" count="1" loot_quality_template="qualityNoTier">
        \\    <item group="gWeighted"/>
        \\  </lootcontainer>
        \\</loot>
    ;
    var lt = try loadFromSlice(std.testing.allocator, xml_text);
    defer lt.deinit();
    var stacks: [8]Stack = undefined;
    var common: usize = 0;
    var rare: usize = 0;
    var never: usize = 0;
    var s: u32 = 1;
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        s = s *% 1103515245 +% 12345;
        const n = lt.rollContainer("cWeighted", 1, s, &stacks);
        try std.testing.expectEqual(@as(usize, 1), n);
        if (std.mem.eql(u8, stacks[0].item_name, "commonItem")) {
            common += 1;
        } else if (std.mem.eql(u8, stacks[0].item_name, "rareItem")) {
            rare += 1;
        } else {
            never += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), never);
    // ~90/10 split with a wide tolerance band (no flaky seed edge).
    try std.testing.expect(common > rare * 4);
    try std.testing.expect(common + rare == 4000);
}
