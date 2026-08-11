//! recipes.xml loader: craft outputs + ingredients for server craft queue.

const std = @import("std");
const arena_util = @import("../util/arena.zig");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const components = @import("../ecs/components.zig");

pub const max_recipes: usize = 1024;
pub const max_ingredients: usize = 8;

pub const Ingredient = struct {
    name: []const u8 = "",
    count: u16 = 1,
};

pub const RecipeDef = struct {
    name: []const u8 = "",
    count: u16 = 1,
    craft_time: f32 = 1,
    always_unlocked: bool = false,
    craft_area: []const u8 = "",
    /// recipes.xml craft_exp_gain: crafting XP granted on completion
    /// (EntityPlayerLocal.GiveExp(CraftCompleteData); crafting-recipes.md
    /// section 2). -1 = not declared. Verified against the shipped V3.1.0
    /// recipes.xml: only 17 of 639 recipes declare it, and every declared
    /// value is 0; the remaining 622 are left at -1 rather than a guessed
    /// derivation (the doc's ingredient-cost fallback is an editor-only export
    /// step, not something the dedicated server IL runs — items.xml ships zero
    /// CraftComponentExp rows to derive from even if it did).
    craft_exp_gain: i32 = -1,
    ingredients: [max_ingredients]Ingredient = [_]Ingredient{.{}} ** max_ingredients,
    ingredient_n: u8 = 0,
};

pub const RecipeTable = struct {
    defs: []const RecipeDef = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,
    source: enum { builtin, xml } = .builtin,

    pub fn deinit(self: *RecipeTable) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
        self.* = builtin();
    }

    pub fn builtin() RecipeTable {
        return .{ .defs = &builtin_defs, .source = .builtin };
    }

    pub fn byName(self: *const RecipeTable, name: []const u8) ?RecipeDef {
        for (self.defs) |d| {
            if (std.mem.eql(u8, d.name, name)) return d;
        }
        return null;
    }

    /// Names with always_unlocked (for PDF unlockedRecipeList).
    pub fn appendAlwaysUnlocked(self: *const RecipeTable, out: [][]const u8) usize {
        var n: usize = 0;
        for (self.defs) |d| {
            if (!d.always_unlocked) continue;
            if (n >= out.len) break;
            out[n] = d.name;
            n += 1;
        }
        // Starter craft demos: wooden club is learnable via perk in stock, not
        // always_unlocked. Seed it so InvTx/UI craft can run without progression
        // when the offline builtin catalog has no progression. When the stock
        // recipes.xml is loaded, extra names not in the catalog are omitted so
        // the wire list matches what the stock client knows.
        if (self.source == .builtin) {
            const extra = [_][]const u8{
                "meleeWpnClubT0WoodenClub",
                "resourceWood",
            };
            for (extra) |name| {
                if (n >= out.len) break;
                var dup = false;
                for (out[0..n]) |e| {
                    if (std.mem.eql(u8, e, name)) {
                        dup = true;
                        break;
                    }
                }
                if (dup) continue;
                if (self.byName(name)) |d| {
                    out[n] = d.name;
                } else {
                    out[n] = name;
                }
                n += 1;
            }
        }
        return n;
    }
};

/// Minimal offline craft set (wood frame-ish).
pub const builtin_defs = [_]RecipeDef{
    blk: {
        var d: RecipeDef = .{
            .name = "resourceWood",
            .count = 1,
            .craft_time = 1,
            .always_unlocked = true,
            .ingredient_n = 1,
        };
        d.ingredients[0] = .{ .name = "resourceWood", .count = 1 };
        break :blk d;
    },
    blk: {
        var d: RecipeDef = .{
            .name = "resourceCobblestones",
            .count = 1,
            .craft_time = 1,
            .always_unlocked = true,
            .ingredient_n = 1,
        };
        d.ingredients[0] = .{ .name = "resourceRockSmall", .count = 1 };
        break :blk d;
    },
};

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !RecipeTable {
    const clean = try xml.readCleanFile(allocator, path);
    defer allocator.free(clean);

    const arena_holder = try arena_util.newArenaHolder(allocator);
    errdefer {
        arena_holder.deinit();
        allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();

    var list: std.ArrayList(RecipeDef) = .empty;
    defer list.deinit(allocator);

    var i: usize = 0;
    while (i < clean.len and list.items.len < max_recipes) {
        const tag = std.mem.findPos(u8, clean, i, "<recipe") orelse break;
        const name = xml.attr(clean, tag, "name") orelse {
            i = tag + 7;
            continue;
        };
        // Skip wildcard forge scrap stubs without ingredients when body empty.
        const gt = std.mem.findPos(u8, clean, tag, ">") orelse break;
        var body: []const u8 = "";
        var next_i = gt + 1;
        if (gt > tag and clean[gt - 1] == '/') {
            // self-closing
        } else {
            const close = std.mem.findPos(u8, clean, gt, "</recipe>") orelse break;
            body = clean[gt + 1 .. close];
            next_i = close + 9;
        }

        var def: RecipeDef = .{
            .name = try arena.dupe(u8, name),
            .count = xml.parseU16(xml.attr(clean, tag, "count") orelse "1") orelse 1,
            .craft_time = xml.parseF32(xml.attr(clean, tag, "craft_time") orelse "1") orelse 1,
            .always_unlocked = false,
            .craft_area = "",
        };
        if (xml.attr(clean, tag, "always_unlocked")) |au| {
            def.always_unlocked = std.mem.eql(u8, au, "true") or std.mem.eql(u8, au, "True");
        }
        if (xml.attr(clean, tag, "craft_area")) |ca| {
            def.craft_area = try arena.dupe(u8, ca);
        }
        if (xml.attr(clean, tag, "craft_exp_gain")) |ceg| {
            def.craft_exp_gain = xml.parseI32Prefix(ceg) orelse -1;
        }

        var ii: usize = 0;
        while (ii < body.len and def.ingredient_n < max_ingredients) {
            const itag = std.mem.findPos(u8, body, ii, "<ingredient") orelse break;
            const iname = xml.attr(body, itag, "name") orelse {
                ii = itag + 11;
                continue;
            };
            const icount = xml.parseU16(xml.attr(body, itag, "count") orelse "1") orelse 1;
            def.ingredients[def.ingredient_n] = .{
                .name = try arena.dupe(u8, iname),
                .count = icount,
            };
            def.ingredient_n += 1;
            ii = itag + 11;
        }

        // Keep recipes with ingredients; also keep always_unlocked zero-ingredient (scrap stubs).
        if (def.ingredient_n > 0 or def.always_unlocked) {
            try list.append(allocator, def);
        }
        i = next_i;
    }

    const defs = try arena.alloc(RecipeDef, list.items.len);
    @memcpy(defs, list.items);
    return .{
        .defs = defs,
        .arena_ptr = arena_holder,
        .source = .xml,
    };
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?RecipeTable {
    const paths = @import("paths.zig");
    return paths.tryLoadConfig("recipes.xml", RecipeTable, loadFromPath, allocator, game_dir, config_dir);
}

test "builtin recipes" {
    const t = RecipeTable.builtin();
    try std.testing.expect(t.byName("resourceWood") != null);
    var names: [32][]const u8 = undefined;
    const n = t.appendAlwaysUnlocked(&names);
    try std.testing.expect(n >= 1);
}

test "load stock recipes when present" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/recipes.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expect(t.defs.len > 50);
    // forge clay recipe has ingredients
    const clay = t.byName("resourceClayLump");
    try std.testing.expect(clay != null);
}

test "craft_exp_gain parses the declared 0 and defaults undeclared to -1" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/recipes.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    // resourceCoalBundle declares craft_exp_gain="0" in the shipped file, and
    // (unlike resourceClayLump, which has two same-named <recipe> elements,
    // one via workbench and one via forge) its name is unambiguous.
    const coal = t.byName("resourceCoalBundle") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i32, 0), coal.craft_exp_gain);
    // Most recipes (622 of 639 in the shipped file) declare nothing; the
    // fail-closed default must stay -1, not a guessed derivation.
    var undeclared_found = false;
    for (t.defs) |d| {
        if (d.craft_exp_gain == -1) {
            undeclared_found = true;
            break;
        }
    }
    try std.testing.expect(undeclared_found);
}
