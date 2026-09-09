//! recipes.xml loader: craft outputs + ingredients for server craft queue.

const std = @import("std");
const arena_util = @import("../util/arena.zig");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const components = @import("../ecs/components.zig");
const util_log = @import("../util/log.zig");

/// Storage cap on parsed recipes, a zdtd bound rather than a stock rule: stock
/// has no limit. Measured against V3.2.0 `Data/Config` (2026-09-04): stock
/// recipes.xml defines **630**, so this leaves room for roughly 390 modlet
/// additions. The parse loop stops at the cap, so overflow drops the tail; it
/// logs once when that happens rather than silently shipping a short catalog,
/// because a missing recipe looks like a game bug, not a config limit.
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
    /// step, not something the dedicated server IL runs - items.xml ships zero
    /// CraftComponentExp rows to derive from even if it did).
    craft_exp_gain: i32 = -1,
    /// recipes.xml craft_tool: the tool name a recipe requires (53 stock
    /// recipes). Empty = any. The general inventory craft path rejects
    /// tool-bound recipes (they need the workstation/tool context).
    craft_tool: []const u8 = "",
    /// recipes.xml material_based="true": the recipe uses the material
    /// system (34 stock); the general craft path rejects them (materials are
    /// not a stock inventory ingredient, so crafting from nothing would mint
    /// items - GAP "Server craft execution").
    material_based: bool = false,
    /// recipes.xml `<wildcard_forge_category/>`: forge scrap stub
    /// (GetScrapableRecipe, RE crafting-recipes.md IL=77). Not a general
    /// craft recipe; crafting it with no ingredients would mint scrap.
    wildcard_forge_category: bool = false,
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

    /// Join PDF unlockedRecipeList: always_unlocked plus recipes whose
    /// unlock_entry the player currently meets. `skill_level(name)` is the
    /// player's purchased/magazine crafting-skill level. Offline catalogs
    /// with no progression table still seed demo names via appendAlwaysUnlocked.
    pub fn appendUnlockedFor(
        self: *const RecipeTable,
        out: [][]const u8,
        table: *const @import("progression.zig").Table,
        skill_level: *const fn ([]const u8) u8,
    ) usize {
        var n = self.appendAlwaysUnlocked(out);
        if (table.crafting_skills.len == 0) return n;
        for (self.defs) |d| {
            if (n >= out.len) break;
            if (d.always_unlocked) continue;
            const req = @import("progression.zig").unlockRequirement(table, d.name) orelse continue;
            if (skill_level(req[0]) < req[1]) continue;
            var dup = false;
            for (out[0..n]) |e| {
                if (std.mem.eql(u8, e, d.name)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            out[n] = d.name;
            n += 1;
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
        if (list.items.len + 1 == max_recipes) {
            // One line at the boundary: a truncated catalog otherwise presents
            // as recipes that mysteriously do not exist.
            util_log.err(
                "zdtd: recipes.xml hit the {d}-recipe cap; later recipes are dropped\n",
                .{max_recipes},
            );
        }
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
        if (xml.attr(clean, tag, "craft_tool")) |ct| {
            def.craft_tool = try arena.dupe(u8, ct);
        }
        if (xml.attr(clean, tag, "material_based")) |mb| {
            def.material_based = std.mem.eql(u8, mb, "true") or std.mem.eql(u8, mb, "True");
        }
        if (xml.attr(clean, tag, "craft_exp_gain")) |ceg| {
            def.craft_exp_gain = xml.parseI32Prefix(ceg) orelse -1;
        }
        // Self-closing or open body tag both mark forge scrap stubs.
        if (std.mem.indexOf(u8, body, "<wildcard_forge_category") != null) {
            def.wildcard_forge_category = true;
        } else if (gt > tag and clean[gt - 1] == '/') {
            // Self-closing recipe with no body: check the open tag itself.
            if (std.mem.indexOf(u8, clean[tag .. gt + 1], "<wildcard_forge_category") != null) {
                def.wildcard_forge_category = true;
            }
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

        // Keep recipes with ingredients; also keep always_unlocked / scrap stubs.
        if (def.ingredient_n > 0 or def.always_unlocked or def.wildcard_forge_category) {
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

test "appendUnlockedFor includes gated recipes only when the skill meets the tier" {
    const recipes = [_]RecipeDef{
        .{ .name = "resourceWood", .always_unlocked = true },
        .{ .name = "meleeToolRepairT0StoneAxe", .always_unlocked = false },
        .{ .name = "meleeToolPickT1IronPickaxe", .always_unlocked = false },
    };
    const table: RecipeTable = .{ .defs = &recipes, .source = .xml };
    const skills = [_]@import("progression.zig").CraftingSkill{
        .{
            .name = "craftingHarvestingTools",
            .max_level = 100,
            .entries = &.{
                .{ .items = "meleeToolRepairT0StoneAxe", .level = 1 },
                .{ .items = "meleeToolPickT1IronPickaxe", .level = 11 },
            },
        },
    };
    const prog: @import("progression.zig").Table = .{ .crafting_skills = &skills };
    const Harvest = struct {
        var harvest: u8 = 0;
        fn level(name: []const u8) u8 {
            if (std.mem.eql(u8, name, "craftingHarvestingTools")) return harvest;
            return 0;
        }
    };
    var names: [8][]const u8 = undefined;
    Harvest.harvest = 0;
    const n0 = table.appendUnlockedFor(&names, &prog, Harvest.level);
    try std.testing.expectEqual(@as(usize, 1), n0);
    try std.testing.expectEqualStrings("resourceWood", names[0]);
    Harvest.harvest = 1;
    const n1 = table.appendUnlockedFor(&names, &prog, Harvest.level);
    try std.testing.expectEqual(@as(usize, 2), n1);
    Harvest.harvest = 11;
    const n2 = table.appendUnlockedFor(&names, &prog, Harvest.level);
    try std.testing.expectEqual(@as(usize, 3), n2);
}
