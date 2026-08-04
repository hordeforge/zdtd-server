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
    arena_ptr: ?*std.heap.ArenaAllocator = null,
    source: enum { builtin, xml } = .builtin,
    /// LootAbundance percent (serverconfig); scales rolled stack counts. 100 = 1×.
    abundance_pct: u16 = 100,

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

    /// Deterministic roll into `out`. Returns stack count.
    pub fn rollContainer(self: *const LootTable, name: []const u8, seed: u32, out: []Stack) usize {
        const cont = self.containerByName(name) orelse {
            // Unknown: try as group name.
            return self.rollGroup(name, seed, out, 0);
        };
        var n: usize = 0;
        var s = seed ^ 0x9e3779b9;
        var i: u8 = 0;
        while (i < cont.entry_n and n < out.len) : (i += 1) {
            const e = cont.entries[i];
            s = s *% 1103515245 +% 12345;
            // Always include first entry; others with prob.
            if (i > 0 and e.prob < 1.0) {
                const r = @as(f32, @floatFromInt(s % 1000)) / 1000.0;
                if (r > e.prob) continue;
            }
            if (e.is_group) {
                n += self.rollGroup(e.name, s, out[n..], 0);
            } else {
                const cmin = e.count_min;
                const cmax = if (e.count_max >= cmin) e.count_max else cmin;
                const cnt: u16 = if (cmax == cmin) cmin else cmin + @as(u16, @intCast(s % (cmax - cmin + 1)));
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

    fn rollGroup(self: *const LootTable, name: []const u8, seed: u32, out: []Stack, depth: u8) usize {
        if (depth > 6 or out.len == 0) return 0;
        const g = self.groupByName(name) orelse return 0;
        if (g.entry_n == 0) return 0;
        var s = seed;
        const picks: u8 = blk: {
            if (g.pick_max <= g.pick_min) break :blk g.pick_min;
            s = s *% 1103515245 +% 12345;
            break :blk g.pick_min + @as(u8, @intCast(s % (g.pick_max - g.pick_min + 1)));
        };
        var n: usize = 0;
        var p: u8 = 0;
        while (p < picks and n < out.len) : (p += 1) {
            s = s *% 1103515245 +% 12345;
            const idx: usize = s % g.entry_n;
            const e = g.entries[idx];
            if (e.is_group) {
                n += self.rollGroup(e.name, s, out[n..], depth + 1);
            } else {
                const cmin = e.count_min;
                const cmax = if (e.count_max >= cmin) e.count_max else cmin;
                const cnt: u16 = if (cmax == cmin) cmin else cmin + @as(u16, @intCast(s % (cmax - cmin + 1)));
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
    const nb = lt.rollContainer("woodenChest", 12345, &base);
    lt.abundance_pct = 200;
    var big: [max_roll_stacks]Stack = undefined;
    const ng = lt.rollContainer("woodenChest", 12345, &big);
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
    const ns = lt.rollContainer("woodenChest", 12345, &small);
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

fn parseItemOrGroup(tag_src: []const u8, tag_at: usize) ?LootEntry {
    const is_group = xml.attr(tag_src, tag_at, "group") != null;
    const name = if (is_group) xml.attr(tag_src, tag_at, "group") else xml.attr(tag_src, tag_at, "name");
    const n = name orelse return null;
    const cr = parseCountRange(xml.attr(tag_src, tag_at, "count") orelse "1");
    const prob = xml.parseF32(xml.attr(tag_src, tag_at, "prob") orelse "1") orelse 1;
    return .{
        .name = n,
        .is_group = is_group,
        .count_min = cr.min,
        .count_max = cr.max,
        .prob = prob,
    };
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !LootTable {
    const raw = try io_fs.readFileAll(allocator, path);
    defer allocator.free(raw);
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
            if (parseItemOrGroup(body, itag)) |ent| {
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
            if (parseItemOrGroup(body, itag)) |ent| {
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

    const gs = try arena.alloc(LootGroup, groups.items.len);
    @memcpy(gs, groups.items);
    const cs = try arena.alloc(LootContainer, containers.items.len);
    @memcpy(cs, containers.items);

    return .{
        .groups = gs,
        .containers = cs,
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
    const n = t.rollContainer("EntityLootContainerRegular", 42, &stacks);
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
        const n = t.rollContainer("woodenChest", 7, &stacks);
        try std.testing.expect(n >= 1);
    }
}
