//! Recipe catalog tests: outputs, tags, counts.
//!
//! Split out of assets/recipes.zig (same tests, moved verbatim).

const std = @import("std");
const recipes_mod = @import("recipes.zig");
const RecipeTable = recipes_mod.RecipeTable;
const xml = @import("xml_util.zig");
const stock_paths = @import("../util/stock_paths.zig");
const io_fs = @import("../util/io_fs.zig");
const RecipeDef = recipes_mod.RecipeDef;
const ingredientCount = recipes_mod.ingredientCount;
const loadFromPath = recipes_mod.loadFromPath;
const resolveCraftTime = recipes_mod.resolveCraftTime;

test "recipe tags, ingredient modifier and CraftingIngredientCount" {
    // Stock RecipesFromXml builds the recipe tag set as `tags + "," + name`
    // (IL_0180-0191), so a CraftingTier row tagged with the output item name
    // matches. Recipe.CanCraft folds CraftingIngredientCount (198) per
    // ingredient at the crafting tier when UseIngredientModifier (default
    // true; `use_ingredient_modifier="false"` opts out).
    const path = stock_paths.configFile("recipes.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expect(t.defs.len > 500);

    const hammer = t.byName("meleeToolRepairT1ClawHammer").?;
    // The declared tags plus the recipe name: the name is what lets the
    // craftingRepairTools skill's CraftingTier row (tagged with the item name)
    // match this recipe's query.
    try std.testing.expect(std.mem.find(u8, hammer.tags, "craftingHarvestingTools") != null);
    try std.testing.expect(std.mem.find(u8, hammer.tags, "meleeToolRepairT1ClawHammer") != null);
    try std.testing.expect(hammer.use_ingredient_modifier);

    // armorPrimitiveHelmet: base_add level 2..6 value 5..30 on fibers/wood
    // (base 5) and level 4..6 on cloth (base 0) and level 5..6 on duct tape.
    const helmet = t.byName("armorPrimitiveHelmet").?;
    try std.testing.expectEqual(@as(u16, 5), ingredientCount(helmet, "resourceYuccaFibers", 5, 1));
    try std.testing.expectEqual(@as(u16, 10), ingredientCount(helmet, "resourceYuccaFibers", 5, 2));
    try std.testing.expectEqual(@as(u16, 35), ingredientCount(helmet, "resourceYuccaFibers", 5, 6));
    // A base of 0 with no row matching this tier is not required at all:
    // the scan is skipped (Recipe::CanCraft IL_0083), not clamped to 1.
    try std.testing.expectEqual(@as(u16, 0), ingredientCount(helmet, "resourceCloth", 0, 1));
    // At tier 4 the cloth row's base_add 5 lands on the 0 base, so stock
    // charges 5 - the skip happens on the *modified* count.
    try std.testing.expectEqual(@as(u16, 5), ingredientCount(helmet, "resourceCloth", 0, 4));
    // An ingredient the rows do not name keeps its base count.
    try std.testing.expectEqual(@as(u16, 5), ingredientCount(helmet, "resourceDuctTape", 5, 4));

    // perc_add rows are fractions and the caller truncates: ammoDartIron
    // unit_iron base 3 at tier 1 (value .25) becomes trunc(3 * 1.25) = 3.
    const dart = t.byName("ammoDartIron").?;
    try std.testing.expect(dart.use_ingredient_modifier);
    try std.testing.expectEqual(@as(u16, 3), ingredientCount(dart, "unit_iron", 3, 1));
    try std.testing.expectEqual(@as(u16, 3), ingredientCount(dart, "unit_clay", 3, 1));

    // use_ingredient_modifier="false" opts the recipe out entirely (the
    // forge-emptying rows). Some of those names also have an earlier wildcard
    // stub that keeps the attribute default, so scan the catalog.
    var opted_out = false;
    for (t.defs) |d| {
        if (d.use_ingredient_modifier) continue;
        opted_out = true;
        try std.testing.expectEqual(@as(u16, 7), ingredientCount(d, "unit_iron", 7, 6));
    }
    try std.testing.expect(opted_out);
}

test "builtin recipes" {
    const t = RecipeTable.builtin();
    try std.testing.expect(t.byName("resourceWood") != null);
    var names: [32][]const u8 = undefined;
    const n = t.appendAlwaysUnlocked(&names);
    try std.testing.expect(n >= 1);
}

test "load stock recipes when present" {
    const path = stock_paths.configFile("recipes.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expect(t.defs.len > 50);
    // forge clay recipe has ingredients
    const clay = t.byName("resourceClayLump");
    try std.testing.expect(clay != null);
}

test "craft_time defaults to the -1 sentinel and resolves like Recipe::Init" {
    const path = stock_paths.configFile("recipes.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    // Declared times are kept verbatim (the forge resourceClayLump row
    // declares craft_time="1"; the salvage stub of the same name omits it).
    var clay: ?RecipeDef = null;
    for (t.defs) |d| {
        if (std.mem.eql(u8, d.name, "resourceClayLump") and d.craft_time == 1) {
            clay = d;
            break;
        }
    }
    const c = clay orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f32, 1), resolveCraftTime(c, struct {
        fn f(_: []const u8) f32 {
            return 0;
        }
    }.f));
    // 506 of 639 stock recipes omit the attribute: the sentinel stays -1.
    var omitted: ?RecipeDef = null;
    for (t.defs) |d| {
        if (d.craft_time == -1) {
            omitted = d;
            break;
        }
    }
    const o = omitted orelse return error.TestUnexpectedResult;
    // No stock item declares CraftTimeValue, so every stock derivation is 0
    // (stock's own `Recipe::Init` sum over the same data).
    try std.testing.expectEqual(@as(f32, 0), resolveCraftTime(o, struct {
        fn f(_: []const u8) f32 {
            return 0;
        }
    }.f));
    // The sum shape: time * count per ingredient.
    const S = struct {
        fn f(name: []const u8) f32 {
            if (std.mem.eql(u8, name, "a")) return 2.5;
            if (std.mem.eql(u8, name, "b")) return 1.0;
            return 0;
        }
    };
    var synth: RecipeDef = .{ .name = "s", .craft_time = -1, .ingredient_n = 2 };
    synth.ingredients[0] = .{ .name = "a", .count = 2 };
    synth.ingredients[1] = .{ .name = "b", .count = 3 };
    try std.testing.expectEqual(@as(f32, 8.0), resolveCraftTime(synth, S.f));
}

test "craft_exp_gain parses the declared 0 and defaults undeclared to -1" {
    const path = stock_paths.configFile("recipes.xml");
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
