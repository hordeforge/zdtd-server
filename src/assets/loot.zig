//! loot.xml loader: groups + containers, simple deterministic rolls.

const std = @import("std");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");

pub const max_groups: usize = 2048;
pub const max_containers: usize = 512;
pub const max_entries: usize = 32;
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
    /// How many entries to pick (min,max); 0 means "all entries once".
    pick_min: u8 = 1,
    pick_max: u8 = 1,
    entries: [max_entries]LootEntry = [_]LootEntry{.{}} ** max_entries,
    entry_n: u8 = 0,
};

pub const LootContainer = struct {
    name: []const u8 = "",
    size_x: u8 = 8,
    size_y: u8 = 6,
    entries: [max_entries]LootEntry = [_]LootEntry{.{}} ** max_entries,
    entry_n: u8 = 0,
};

pub const Stack = struct {
    item_name: []const u8 = "",
    count: u16 = 0,
};

pub const LootTable = struct {
    groups: []const LootGroup = &.{},
    containers: []const LootContainer = &.{},
    prob_templates: []const ProbTemplate = &.{},
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
    fn probGate(self: *const LootTable, e: LootEntry, loot_stage: i32, s: u32) bool {
        const p = self.entryProb(e, loot_stage);
        // A NaN prob (crafted/patched loot.xml) fails both comparisons below and
        // the NaN→int conversion in intFromFloat is undefined; fail closed to
        // match the C# unchecked cast (NaN rounds to 0, i.e. never picked).
        if (!std.math.isFinite(p)) return false;
        if (p >= 1.0) return true;
        if (p <= 0.0) return false;
        const thresh: u32 = @intFromFloat(@round(p * 1000.0));
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

    /// Deterministic roll into `out` at `loot_stage`. Returns stack count.
    /// Pass 1 for "no gamestage information"; the templates' first band starts
    /// at level 0 or 1, so stage 1 is the honest floor, not a magic value.
    pub fn rollContainer(self: *const LootTable, name: []const u8, loot_stage: i32, seed: u32, out: []Stack) usize {
        const cont = self.containerByName(name) orelse {
            // Unknown: try as group name.
            return self.rollGroup(name, loot_stage, seed, out, 0);
        };
        var n: usize = 0;
        var s = seed ^ 0x9e3779b9;
        var i: u8 = 0;
        while (i < cont.entry_n and n < out.len) : (i += 1) {
            const e = cont.entries[i];
            s = s *% 1103515245 +% 12345;
            // Always include the first entry unless it carries a loot stage
            // template: a template's prob is the stage gate itself, and stock
            // never emits an entry whose band prob is 0.
            if ((i > 0 or e.prob_template != 0) and !self.probGate(e, loot_stage, s)) continue;
            if (e.is_group) {
                n += self.rollGroup(e.name, loot_stage, s, out[n..], 0);
            } else {
                const cmin = e.count_min;
                const cmax = if (e.count_max >= cmin) e.count_max else cmin;
                // Full-domain ranges (0..65535) make the u16 span arithmetic
                // overflow; widen so the modulo never sees a wrapped zero.
                const span: u32 = @as(u32, cmax) - @as(u32, cmin) + 1;
                const cnt: u16 = if (cmax == cmin) cmin else cmin + @as(u16, @intCast(s % span));
                out[n] = .{ .item_name = e.name, .count = self.scaleCount(cnt) };
                n += 1;
            }
        }
        if (n == 0 and out.len > 0) {
            // Fallback scrap
            out[0] = .{ .item_name = "resourceScrapIron", .count = 5 };
            return 1;
        }
        return n;
    }

    fn rollGroup(self: *const LootTable, name: []const u8, loot_stage: i32, seed: u32, out: []Stack, depth: u8) usize {
        if (depth > 6 or out.len == 0) return 0;
        const g = self.groupByName(name) orelse return 0;
        if (g.entry_n == 0) return 0;
        var s = seed;
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
            const idx: usize = s % g.entry_n;
            const e = g.entries[idx];
            // A picked entry still has to clear its loot stage band, so a
            // low-stage player cannot pull a top-tier item out of a group.
            if (e.prob_template != 0 and !self.probGate(e, loot_stage, s)) continue;
            if (e.is_group) {
                n += self.rollGroup(e.name, loot_stage, s, out[n..], depth + 1);
            } else {
                const cmin = e.count_min;
                const cmax = if (e.count_max >= cmin) e.count_max else cmin;
                // Same span widening as rollContainer (count="0,65535").
                const span: u32 = @as(u32, cmax) - @as(u32, cmin) + 1;
                const cnt: u16 = if (cmax == cmin) cmin else cmin + @as(u16, @intCast(s % span));
                out[n] = .{ .item_name = e.name, .count = self.scaleCount(cnt) };
                n += 1;
            }
        }
        return n;
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
    if (std.mem.indexOfScalar(u8, s, ',')) |c| {
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
    };
}

/// `level="a,b"` on a `<loot>` band; a bare number covers exactly that level.
fn parseLevelRange(s: []const u8) struct { min: i32, max: i32 } {
    const comma = std.mem.indexOfScalar(u8, s, ',') orelse {
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

    var arena_holder = try allocator.create(std.heap.ArenaAllocator);
    arena_holder.* = std.heap.ArenaAllocator.init(allocator);
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
    if (std.mem.indexOf(u8, clean, "<loot_settings")) |ls| {
        if (xml.attr(clean, ls, "poi_tier_mod")) |v| poi_mod = try parseF32List(arena, v);
        if (xml.attr(clean, ls, "poi_tier_bonus")) |v| poi_bonus = try parseF32List(arena, v);
    }

    // lootprobtemplate: parsed first so item rows can resolve to an index.
    var templates: std.ArrayList(ProbTemplate) = .empty;
    defer templates.deinit(allocator);
    var bands: std.ArrayList(ProbBand) = .empty;
    defer bands.deinit(allocator);
    var ti: usize = 0;
    while (std.mem.indexOfPos(u8, clean, ti, "<lootprobtemplate")) |tag| {
        const gt = std.mem.indexOfPos(u8, clean, tag, ">") orelse break;
        const name = xml.attr(clean, tag, "name") orelse {
            ti = gt + 1;
            continue;
        };
        var body: []const u8 = "";
        ti = gt + 1;
        if (!(gt > tag and clean[gt - 1] == '/')) {
            const close = std.mem.indexOfPos(u8, clean, gt, "</lootprobtemplate>") orelse break;
            body = clean[gt + 1 .. close];
            ti = close + 19;
        }
        bands.clearRetainingCapacity();
        var bi: usize = 0;
        while (std.mem.indexOfPos(u8, body, bi, "<loot")) |ltag| {
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

    // lootgroup
    var i: usize = 0;
    while (i < clean.len and groups.items.len < max_groups) {
        const tag = std.mem.indexOfPos(u8, clean, i, "<lootgroup") orelse break;
        const name = xml.attr(clean, tag, "name") orelse {
            i = tag + 10;
            continue;
        };
        const gt = std.mem.indexOfPos(u8, clean, tag, ">") orelse break;
        var body: []const u8 = "";
        var next_i = gt + 1;
        if (!(gt > tag and clean[gt - 1] == '/')) {
            const close = std.mem.indexOfPos(u8, clean, gt, "</lootgroup>") orelse break;
            body = clean[gt + 1 .. close];
            next_i = close + 12;
        }
        var g: LootGroup = .{
            .name = try arena.dupe(u8, name),
        };
        if (xml.attr(clean, tag, "count")) |cv| {
            const cr = parseCountRange(cv);
            g.pick_min = @intCast(@min(cr.min, 255));
            g.pick_max = @intCast(@min(cr.max, 255));
        }
        var bi: usize = 0;
        while (bi < body.len and g.entry_n < max_entries) {
            const itag = std.mem.indexOfPos(u8, body, bi, "<item") orelse break;
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
        const tag = std.mem.indexOfPos(u8, clean, i, "<lootcontainer") orelse break;
        const name = xml.attr(clean, tag, "name") orelse {
            i = tag + 14;
            continue;
        };
        const gt = std.mem.indexOfPos(u8, clean, tag, ">") orelse break;
        var body: []const u8 = "";
        var next_i = gt + 1;
        if (!(gt > tag and clean[gt - 1] == '/')) {
            const close = std.mem.indexOfPos(u8, clean, gt, "</lootcontainer>") orelse break;
            body = clean[gt + 1 .. close];
            next_i = close + 16;
        }
        var c: LootContainer = .{
            .name = try arena.dupe(u8, name),
        };
        if (xml.attr(clean, tag, "size")) |sz| {
            if (std.mem.indexOfScalar(u8, sz, ',')) |comma| {
                c.size_x = @intCast(xml.parseU16(std.mem.trim(u8, sz[0..comma], " \t")) orelse 8);
                c.size_y = @intCast(xml.parseU16(std.mem.trim(u8, sz[comma + 1 ..], " \t")) orelse 6);
            }
        }
        var bi: usize = 0;
        while (bi < body.len and c.entry_n < max_entries) {
            const itag = std.mem.indexOfPos(u8, body, bi, "<item") orelse break;
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
    var t = loadFromPath(std.testing.allocator, path) catch return error.SkipZigTest;
    defer t.deinit();
    try std.testing.expect(t.groups.len > 50);
    try std.testing.expect(t.containers.len > 20);
    try std.testing.expect(t.containerByName("woodenChest") != null or t.containerByName("EntityLootContainerRegular") != null or t.groups.len > 0);
    var stacks: [max_roll_stacks]Stack = undefined;
    // EntityLootContainerRegular may be group-only; roll woodenChest or first container
    if (t.containerByName("woodenChest")) |_| {
        const n = t.rollContainer("woodenChest", 1, 7, &stacks);
        try std.testing.expect(n >= 1);
    }
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
    var t = loadFromPath(std.testing.allocator, path) catch return error.SkipZigTest;
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
