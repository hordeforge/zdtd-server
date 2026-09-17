//! recipes.xml loader: craft outputs + ingredients for server craft queue.

const std = @import("std");
const arena_util = @import("../util/arena.zig");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const components = @import("../ecs/components.zig");
const buffs = @import("buffs.zig");
const requirements = @import("requirements.zig");
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
    /// recipes.xml `craft_time` (seconds; stock `Recipe.craftingTime`). -1 =
    /// not declared: stock `Recipe::Init` (IL=79) resolves it to the sum of
    /// ingredient `CraftComponentTime * count`. 506 of 639 stock recipes omit
    /// it, and no stock item declares `CraftTimeValue`, so every stock
    /// derivation is 0.
    craft_time: f32 = -1,
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
    /// `tags` attribute plus the recipe name. Stock RecipesFromXml builds the
    /// tag set as `tags + "," + name` (IL_0180-0191), which is what lets a
    /// `CraftingTier`/`CraftingIngredientCount` row tagged with the output or
    /// ingredient item name match the recipe query.
    tags: []const u8 = "",
    /// `use_ingredient_modifier` (stock ParseBool default true): the recipe's
    /// CraftingIngredientCount rows fold into each ingredient's count.
    use_ingredient_modifier: bool = true,
    /// `<effect_group>` passive rows (CraftingIngredientCount,
    /// CraftingTier), arena-backed.
    passives: []const buffs.Passive = &.{},
};

/// `CraftingIngredientCount` (passive 198) rows on a recipe scale one
/// ingredient's required count at the crafting tier. Stock `Recipe::CanCraft`
/// (IL=128, `../7dtd-engine-research/il/full-v3.2.0/_global/Recipe.il.txt`)
/// IL_0041 calls `EffectManager.GetValue(198, null, xmlCount, player, recipe,
/// FastTags.Parse(ingredientName), ..., craftingTier, ...)` when
/// `UseIngredientModifier`, whose IL_03BC returns `base * perc` - the base ops
/// fold into one accumulator and the percent ops into another, multiplied
/// once, not op-by-op. The caller's `conv.i4` **truncates** toward zero. A
/// result `<= 0` makes the ingredient not required at all: IL_0083 skips the
/// scan entirely rather than clamping to 1, so a `count="0"` row with no
/// matching modifier is free while the same row plus a `base_add` at this tier
/// is charged. The query tags are the ingredient name; `perc_add` /
/// `perc_subtract` are fractions (+0.25 = +25%, the non-loot passive
/// convention) and `perc_set` replaces the accumulator rather than adding.
pub fn ingredientCount(
    recipe: RecipeDef,
    ing_name: []const u8,
    base: u16,
    crafting_tier: u8,
) u16 {
    if (!recipe.use_ingredient_modifier or recipe.passives.len == 0) return base;
    var base_v: f32 = @floatFromInt(base);
    var perc: f32 = 1.0;
    var counts: requirements.Counts = .{};
    const ctx: requirements.Ctx = .{ .tags = ing_name };
    for (recipe.passives) |p| {
        if (!std.mem.eql(u8, p.name, "CraftingIngredientCount")) continue;
        if (!buffs.tagsMatch(p.tags, ctx.tags)) continue;
        if (p.reqs.len > 0 and requirements.evaluate(p.reqs, ctx, &counts) != .pass) continue;
        const amount = if (p.value_cvar.len > 0)
            requirements.cvarValue(ctx, p.value_cvar)
        else
            buffs.curveAtAxis(p, @floatFromInt(@max(1, crafting_tier)));
        switch (p.op) {
            .base_set, .set => base_v = amount,
            .base_add, .add => base_v += amount,
            .base_subtract, .subtract => base_v -= amount,
            .perc_set => perc = amount,
            .perc_add => perc += amount,
            .perc_subtract => perc -= amount,
            else => {},
        }
    }
    const v = base_v * perc;
    // Stock skips a non-positive count instead of clamping it to 1: the
    // ingredient is not required. Positive counts are floored to 1 by the
    // caller (Recipe::CanCraft IL_0097 FastMax), after the sandbox
    // CraftingInput multiplier.
    if (!(v > 0)) return 0;
    return @intFromFloat(@min(@trunc(v), 65535.0));
}

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
    // effect_group rows: one shared pool in encounter order with a per-recipe
    // range, patched after the walk (same shape as the item_modifiers loader).
    var passives_list: std.ArrayList(buffs.Passive) = .empty;
    var reqs_list: std.ArrayList(requirements.Requirement) = .empty;
    var req_ranges: std.ArrayList(struct { usize, usize }) = .empty;
    var ranges: std.ArrayList(struct { usize, usize }) = .empty;
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
            // Absent or malformed lands on the -1 sentinel (stock's
            // RecipesFromXml leaves craftingTime at -1 when the attribute is
            // missing or fails TryParseFloat); `resolveCraftTime` derives it.
            .craft_time = xml.parseF32(xml.attr(clean, tag, "craft_time") orelse "-1") orelse -1,
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
        // Stock RecipesFromXml IL_0180-0191: tags = attr("tags") + "," + name.
        {
            const raw_tags = xml.attr(clean, tag, "tags") orelse "";
            def.tags = try std.fmt.allocPrint(arena, "{s},{s}", .{ raw_tags, name });
        }
        if (xml.attr(clean, tag, "use_ingredient_modifier")) |uim| {
            def.use_ingredient_modifier = !(std.mem.eql(u8, uim, "false") or std.mem.eql(u8, uim, "False"));
        }
        {
            const p0 = passives_list.items.len;
            _ = buffs.scanPassives(
                arena,
                arena,
                body,
                &passives_list,
                &reqs_list,
                &req_ranges,
                std.math.maxInt(usize),
            ) catch {};
            try ranges.append(arena, .{ p0, passives_list.items.len - p0 });
        }
        // Self-closing or open body tag both mark forge scrap stubs.
        if (std.mem.find(u8, body, "<wildcard_forge_category") != null) {
            def.wildcard_forge_category = true;
        } else if (gt > tag and clean[gt - 1] == '/') {
            // Self-closing recipe with no body: check the open tag itself.
            if (std.mem.find(u8, clean[tag .. gt + 1], "<wildcard_forge_category") != null) {
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
        } else {
            // The recipe is dropped, so drop its passive range too (the rows
            // stay in the shared pool, unreferenced).
            _ = ranges.pop();
        }
        i = next_i;
    }

    const defs = try arena.alloc(RecipeDef, list.items.len);
    @memcpy(defs, list.items);
    if (req_ranges.items.len != passives_list.items.len) return error.MalformedRecipes;
    const req_pool = try arena.alloc(requirements.Requirement, reqs_list.items.len);
    @memcpy(req_pool, reqs_list.items);
    const pool = try arena.alloc(buffs.Passive, passives_list.items.len);
    @memcpy(pool, passives_list.items);
    for (pool, req_ranges.items) |*pw, rg| {
        pw.reqs = req_pool[rg[0] .. rg[0] + rg[1]];
    }
    for (defs, ranges.items) |*d, rg| {
        d.passives = pool[rg[0] .. rg[0] + rg[1]];
    }
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

/// Stock `Recipe::Init` (IL=79): a `craft_time` left at -1 resolves to the
/// sum of ingredient `CraftComponentTime * count`. `componentTime` resolves an
/// ingredient name to its per-unit time (0 when the item is unknown or
/// declares none); a declared time (>= 0, including an explicit 0) is kept.
/// Contextful callers wrap their table lookup in a closure-compatible fn.
pub fn resolveCraftTime(def: RecipeDef, componentTime: fn ([]const u8) f32) f32 {
    if (def.craft_time >= 0) return def.craft_time;
    var total: f32 = 0;
    var i: usize = 0;
    while (i < def.ingredient_n) : (i += 1) {
        total += componentTime(def.ingredients[i].name) * @as(f32, @floatFromInt(def.ingredients[i].count));
    }
    return total;
}

test "recipe tags, ingredient modifier and CraftingIngredientCount" {
    // Stock RecipesFromXml builds the recipe tag set as `tags + "," + name`
    // (IL_0180-0191), so a CraftingTier row tagged with the output item name
    // matches. Recipe.CanCraft folds CraftingIngredientCount (198) per
    // ingredient at the crafting tier when UseIngredientModifier (default
    // true; `use_ingredient_modifier="false"` opts out).
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/recipes.xml";
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
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/recipes.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expect(t.defs.len > 50);
    // forge clay recipe has ingredients
    const clay = t.byName("resourceClayLump");
    try std.testing.expect(clay != null);
}

test "craft_time defaults to the -1 sentinel and resolves like Recipe::Init" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/recipes.xml";
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
