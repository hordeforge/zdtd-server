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

    /// XP required to go from `level` to level+1. Stock
    /// Progression.GetExpForNextLevel (7dtd-research docs/progression.md XP
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
            // Per-attribute overrides win over the <attributes> defaults
            // (stock: attBooks/attCrafting/attGeneralPerks carry their own
            // min_level/max_level/base_skill_point_cost).
            .min_level = if (xml.attr(clean, ai, "min_level")) |v| std.fmt.parseInt(u8, v, 10) catch def_min else def_min,
            .max_level = if (xml.attr(clean, ai, "max_level")) |v| std.fmt.parseInt(u8, v, 10) catch def_max else def_max,
            .base_cost = if (xml.attr(clean, ai, "base_skill_point_cost")) |v| std.fmt.parseInt(u16, v, 10) catch def_cost else def_cost,
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
        // parent: the perk row's own `parent` attribute (a skill/attribute
        // name in stock, e.g. parent="skillPerceptionCombat"). The old
        // walk-back grabbed the last <attribute> in the file, so every perk
        // resolved to the same wrong attribute.
        var parent: []const u8 = "";
        if (xml.attr(clean, pi, "parent")) |pn| parent = try arena.dupe(u8, pn);
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
