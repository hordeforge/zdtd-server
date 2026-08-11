//! progression.xml: level curve + attribute/perk catalog (names, max levels, costs).
//! Full perk requirement graphs / effect application is progressive; catalog is loaded.

const std = @import("std");
const arena_util = @import("../util/arena.zig");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const paths = @import("paths.zig");

pub const max_attrs: usize = 16;
pub const max_perks: usize = 512;

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

    /// XP required to go from `level` to level+1 (stock geometric curve).
    pub fn expForLevel(self: LevelCurve, level: u16) u64 {
        if (level == 0) return self.exp_to_level;
        const clamp_l = if (self.clamp_exp_cost_at_level == 0) self.max_level else self.clamp_exp_cost_at_level;
        const L: f64 = @floatFromInt(@min(level, clamp_l));
        const base: f64 = @floatFromInt(self.exp_to_level);
        const mult: f64 = self.experience_multiplier;
        const cost = base * std.math.pow(f64, mult, L - 1.0);
        if (cost > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return std.math.maxInt(u32);
        return @trunc(cost);
    }
};

pub const AttrDef = struct {
    name: []const u8 = "",
    min_level: u8 = 1,
    max_level: u8 = 10,
    base_cost: u16 = 1,
    cost_mult: f32 = 1.14,
};

/// Perk catalog row; max_level default 5 before progression.xml loads (stock
/// XML ships per-perk max levels via <perk max_level="...">).
pub const PerkDef = struct {
    name: []const u8 = "",
    max_level: u8 = 5,
    /// Parent attribute name if nested under one; empty if free.
    parent_attr: []const u8 = "",
};

pub const Table = struct {
    curve: LevelCurve = .{},
    attributes: []const AttrDef = &.{},
    perks: []const PerkDef = &.{},
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

    var i: usize = 0;
    while (i < clean.len and attrs.items.len < max_attrs) {
        const ai = std.mem.findPos(u8, clean, i, "<attribute ") orelse break;
        const aname = xml.attr(clean, ai, "name") orelse {
            i = ai + 11;
            continue;
        };
        try attrs.append(allocator, .{
            .name = try arena.dupe(u8, aname),
            .min_level = def_min,
            .max_level = def_max,
            .base_cost = def_cost,
            .cost_mult = def_mult,
        });
        i = ai + 11;
    }

    i = 0;
    while (i < clean.len and perks.items.len < max_perks) {
        const pi = std.mem.findPos(u8, clean, i, "<perk ") orelse break;
        const pname = xml.attr(clean, pi, "name") orelse {
            i = pi + 6;
            continue;
        };
        var max_l: u8 = 5;
        if (xml.attr(clean, pi, "max_level")) |v| {
            max_l = std.fmt.parseInt(u8, v, 10) catch 5;
        }
        // parent: walk back for nearest <attribute name=
        var parent: []const u8 = "";
        if (std.mem.findLast(u8, clean[0..pi], "<attribute ")) |ab| {
            if (xml.attr(clean, ab, "name")) |pn| parent = try arena.dupe(u8, pn);
        }
        try perks.append(allocator, .{
            .name = try arena.dupe(u8, pname),
            .max_level = max_l,
            .parent_attr = parent,
        });
        i = pi + 6;
    }

    const aslice = try arena.alloc(AttrDef, attrs.items.len);
    @memcpy(aslice, attrs.items);
    const pslice = try arena.alloc(PerkDef, perks.items.len);
    @memcpy(pslice, perks.items);

    return .{
        .curve = curve,
        .attributes = aslice,
        .perks = pslice,
        .arena_ptr = arena_holder,
    };
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?LevelCurve {
    return paths.tryLoadConfig("progression.xml", LevelCurve, loadFromPath, allocator, game_dir, config_dir);
}

pub fn tryLoadTable(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?Table {
    return paths.tryLoadConfig("progression.xml", Table, loadTableFromPath, allocator, game_dir, config_dir);
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
