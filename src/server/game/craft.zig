//! Crafting and workstation helpers, extracted verbatim from game.zig:
//! tryCraft/tryCraftRecipe (InvTx craft op), getScrapableRecipe/tryScrap
//! (InvTx scrap op, RE GetScrapableRecipe IL=77), tickWorkstations (burn/craft +
//! heat map feed), tryRefuelGenerator (InvTx refuel), eatProps / itemIsArmor
//! (items.xml ItemActionEat + armor checks), resolveWorkstationOutput, and
//! handItemDamage (entity damage from the hand item).

const std = @import("std");
const ecs = @import("../../ecs/root.zig");
const components = @import("../../ecs/components.zig");
const assets_buffs = @import("../../assets/buffs.zig");
const game_mod = @import("../game.zig");
const packages = @import("../../wire/packages.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const assets_items = @import("../../assets/items.zig");
const assets_recipes = @import("../../assets/recipes.zig");
const assets_progression = @import("../../assets/progression.zig");
const assets_requirements = @import("../../assets/requirements.zig");
const assets_sandbox = @import("../../assets/sandbox.zig");
const invsys = @import("../../ecs/inventory.zig");
const systems = @import("../../ecs/systems.zig");
const replicate_te = @import("../replicate_te.zig");
const workstations_mod = @import("../../world/workstations.zig");
const game_social = @import("social.zig");

/// Vehicle tank cap and the InvTx refuel pickup reach are
/// rules.vehicle (fuel_cap / refuel_reach).
/// ECS armor-PDR hook: the equipped item's PhysicalDamageResist percent at
/// `quality` (1..6), evaluated from the items.xml quality curve (RE
/// PassiveEffect.ModValue IL=796; GetTotalPhysicalArmorRating sums passive
/// 41 on the wearer, combat-damage.md). 0 = the item carries no row, so the
/// offline pieces-rate floor in armorMitigation stands.
pub fn armorPdr(ctx: ?*anyopaque, item_id: u16, quality: u8) f32 {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    if (g.items.byId(item_id)) |d| {
        if (d.phys_resist_n > 0) {
            const qmax = g.items.max_quality_tier;
            const q: u8 = @max(1, @min(quality, qmax));
            return assets_buffs.curveValueAt(q, qmax, d.phys_resist_curve[0..d.phys_resist_n]);
        }
    }
    return 0;
}

/// ECS degradation hook: the held item's DegradationPerUse (per-use
/// durability wear; stock ItemValue.UseTimes). 0 = no row.
pub fn itemDegradation(ctx: ?*anyopaque, item_id: u16) f32 {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    if (g.items.byId(item_id)) |d| return d.degradation_per_use;
    return 0;
}

/// ECS penetration hook: the held item's TargetArmor fraction (negative
/// perc_add; GetTotalPhysicalArmorRating IL=47 applies passive 163 on the
/// attacking item to the wearer's passive-41 rating base). Perk-tag-gated
/// rows (perkJavelinMaster etc.) add their value only when the attacker owns
/// the tagged perk (level >= 1).
pub fn itemPenetration(ctx: ?*anyopaque, item_id: u16, attacker_peer: ?usize) f32 {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    if (g.items.byId(item_id)) |d| {
        var pen = d.target_armor;
        if (d.target_armor_tag.len > 0 and pen == 0) {
            if (attacker_peer) |slot| {
                if (g.skillLevelOf(slot, d.target_armor_tag) >= 1) pen = d.target_armor_tagged;
            }
        }
        return pen;
    }
    return 0;
}

/// ECS armor hook: stock/builtin name starts with "armor".
pub fn itemIsArmor(ctx: ?*anyopaque, item_id: u16) bool {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    if (g.items.byId(item_id)) |d| {
        if (std.mem.startsWith(u8, d.name, "armor")) return true;
        // XML catalog: the loaded name is the authority. Offline aliases
        // must not reclassify a catalog row after a game-dir load.
        if (g.items.source != .builtin or g.stock_catalogs_requested) return false;
    }
    if (g.items.source == .builtin and !g.stock_catalogs_requested) {
        if (invsys.builtinStockNameFallback(item_id)) |n| {
            if (std.mem.startsWith(u8, n, "armor")) return true;
        }
        return invsys.isArmorOffline(item_id);
    }
    return false;
}

/// Refuel generator at world pos if peer is in range. amount = items.xml FuelValue.
pub fn tryRefuelGenerator(self: *Game, c: *const Client, x: i32, y: i32, z: i32, amount: f32) bool {
    if (amount <= 0) return false;
    if (c.entity_id <= 0) return false;
    const ps = self.sim.slotOfNetId(c.entity_id) orelse return false;
    if (!self.sim.mask[ps].transform) return false;
    const t = self.sim.transform[ps];
    if (!self.withinEditReach(t.x, t.y, t.z, @floatFromInt(x), @floatFromInt(y), @floatFromInt(z))) return false;
    return self.sim.power.refuelAt(x, y, z, amount);
}

/// Refuel a vehicle the peer targets: the InvTx place coords point at the
/// body, so find the nearest vehicle within refuel_reach blocks and add the
/// item's FuelValue units, capped at the vehicle's tank. Returns false when
/// nothing is near or the tank is already full (the caller refunds the can).
pub fn tryRefuelVehicle(self: *Game, c: *const Client, x: i32, y: i32, z: i32, amount: f32) bool {
    if (amount <= 0) return false;
    if (c.entity_id <= 0) return false;
    const ps = self.sim.slotOfNetId(c.entity_id) orelse return false;
    if (!self.sim.mask[ps].transform) return false;
    const t = self.sim.transform[ps];
    if (!self.withinEditReach(t.x, t.y, t.z, @floatFromInt(x), @floatFromInt(y), @floatFromInt(z))) return false;
    var best: ?ecs.Slot = null;
    const reach = self.sim.rules.vehicle.refuel_reach;
    var best_d = reach * reach;
    for (ecs.groupSlice(&self.sim, .vehicle)) |vs| {
        if (!self.sim.mask[vs].transform) continue;
        const vx = self.sim.transform[vs].x - @as(f32, @floatFromInt(x));
        const vz = self.sim.transform[vs].z - @as(f32, @floatFromInt(z));
        const d2 = vx * vx + vz * vz;
        if (d2 < best_d) {
            best_d = d2;
            best = vs;
        }
    }
    const vs = best orelse return false;
    const v = &self.sim.vehicle[vs];
    // Tank cap: vehicles.xml fuelTank capacity when known (Game table);
    // else the `[rules.vehicle] fuel_cap` floor. A known kind with no
    // `fuelTank` block has no tank at all - stock's bicycle declares none -
    // so it refuses fuel instead of drinking the rules-floor 100; the floor
    // only stands in when the table itself is absent (no game-dir).
    var fuel_cap = self.sim.rules.vehicle.fuel_cap;
    if (self.vehicles.byKind(v.kind)) |vd| {
        if (vd.tank_capacity <= 0) return false;
        fuel_cap = vd.tank_capacity;
    }
    if (v.fuel >= fuel_cap) return false;
    v.fuel = @min(fuel_cap, v.fuel + amount);
    // Fuel is a vehicle payload; pos flags the vehicle for the periodic
    // position broadcast without forcing a motion relay.
    self.sim.markDirty(vs, .{ .pos = true });
    return true;
}

/// items.xml ItemActionEat props for InvTx use (ItemActionEat.consume).
pub fn eatProps(ctx: ?*anyopaque, item_id: u16) invsys.EatProps {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    return .{
        .is_eat = g.items.isEat(item_id),
        .food_amount = g.items.foodAmountFor(item_id),
        .food_health = g.items.foodHealthFor(item_id),
        .water_amount = g.items.waterAmountFor(item_id),
    };
}

/// `Recipe::GetName()`, i.e. the output ItemClass name (asm.il ~274245).
/// The name only feeds the client's `_craftCount_` XP scaling, so an unknown
/// type still crafts, just without a per-recipe counter.
fn resolveWorkstationOutput(ctx: ?*anyopaque, stock_type: i32) workstations_mod.ResolvedOutput {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    var out: workstations_mod.ResolvedOutput = .{ .item_id = g.items.ecsIdFromStockType(stock_type) };
    for (g.items.stock_types, 0..) |st, i| {
        if (st != stock_type or i >= g.items.stock_names.len) continue;
        out.stock_name = g.items.stock_names[i];
        return out;
    }
    if (out.item_id != 0) {
        if (assets_items.builtinStockName(out.item_id)) |sn| out.stock_name = sn;
    }
    return out;
}

/// Burn time per fuel item from items.xml FuelValue (RE items.md GetFuelValue;
/// 0 = not a fuel item, workstation falls back to the offline flat rate).
fn resolveWorkstationFuel(ctx: ?*anyopaque, item_id: u16) f32 {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    return g.items.fuelValueFor(item_id);
}

/// items.xml Weight for forge melt (units produced per scrap consumed).
fn resolveWorkstationWeight(ctx: ?*anyopaque, item_id: u16) u16 {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    return g.items.weightFor(item_id);
}

/// items.xml Stacknumber for a forged `unit_*` item: the ceiling on how much
/// material one forge slot holds.
fn resolveWorkstationUnitStack(ctx: ?*anyopaque, item_id: u16) u16 {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    return g.items.stackFor(item_id);
}

/// items.xml MeltTimePerUnit (seconds per weight unit; 0 → stock default 1).
fn resolveWorkstationMeltTime(ctx: ?*anyopaque, item_id: u16) f32 {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    return g.items.meltTimePerUnitFor(item_id);
}

/// blocks.xml InputMaterials comma list for a workstation block.
fn resolveWorkstationInputMaterials(ctx: ?*anyopaque, block_id: i32) []const u8 {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    if (block_id <= 0 or block_id > 65535) return "";
    return g.blocks.inputMaterials(@intCast(block_id));
}

/// unit_* item id for a material name ("iron" → unit_iron); 0 if unknown.
fn resolveWorkstationUnitItem(ctx: ?*anyopaque, material_name: []const u8) u16 {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    var buf: [64]u8 = undefined;
    if (material_name.len + 5 > buf.len) return 0;
    const name = std.fmt.bufPrint(&buf, "unit_{s}", .{material_name}) catch return 0;
    if (g.items.byName(name)) |d| return d.id;
    return 0;
}

/// Stock MadeOfMaterial → materials.xml forge_category (AcceptsMaterial).
fn resolveWorkstationForgeCategory(ctx: ?*anyopaque, item_id: u16) []const u8 {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    const mat = g.items.materialFor(item_id);
    if (mat.len == 0) return "";
    return g.maxdamage.forgeCategoryForMaterial(mat);
}

/// Stock HandleMaterialInput tools path: PassiveEffects 95 (CraftingSmeltTime).
/// Fold every occupied tool slot's perc_add curve into a multiplicative scale
/// (ItemValue.ModifyValue then duration *= perc). Empty tools → identity 1.
fn resolveWorkstationSmeltScale(ctx: ?*anyopaque, tools: []const components.InvSlot) f32 {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    var scale: f32 = 1.0;
    for (tools) |t| {
        if (t.item_id == 0 or t.count == 0) continue;
        scale *= g.items.craftingSmeltTimeScale(t.item_id, t.quality);
    }
    return scale;
}

/// Craft recipe by index into recipes.defs (InvTx craft op). Consumes ingredients, grants output.
/// Sandbox option 96 `CraftingProgression` (stock `XUiM_Recipes.CraftingProgression`).
/// The decoded server code wins; an option the code does not carry keeps its
/// stock default (Yes).
fn craftingProgressionOn(self: *const Game) bool {
    const o = assets_sandbox.optionByName("CraftingProgression") orelse return true;
    var groups: [assets_sandbox.max_groups]assets_sandbox.Group = undefined;
    const n = assets_sandbox.decode(self.sandbox_code, &groups);
    for (groups[0..n]) |g| {
        if (g.option_id == o.id) return assets_sandbox.valueB(o, g.index);
    }
    return o.default_i != 0;
}

/// Fold one class's `CraftingTier` rows at `lvl` over the running value.
fn foldCraftingTier(passives: []const assets_buffs.Passive, lvl: u8, ctx: assets_requirements.Ctx, v: *f32, counts: *assets_requirements.Counts) void {
    for (passives) |p| {
        if (!std.mem.eql(u8, p.name, "CraftingTier")) continue;
        if (!assets_buffs.tagsMatch(p.tags, ctx.tags)) continue;
        if (p.reqs.len > 0 and assets_requirements.evaluate(p.reqs, ctx, counts) != .pass) continue;
        const amount = if (p.value_cvar.len > 0)
            assets_requirements.cvarValue(ctx, p.value_cvar)
        else
            assets_buffs.curveAtAxis(p, @floatFromInt(lvl));
        switch (p.op) {
            .base_set, .set => v.* = amount,
            .base_add, .add => v.* += amount,
            .base_subtract, .subtract => v.* -= amount,
            .perc_add => v.* *= 1.0 + amount,
            .perc_subtract => v.* *= 1.0 - amount,
            else => {},
        }
    }
}

/// Stock `Recipe.GetCraftingTier(player)` (IL=22): flat 6 when
/// CraftingProgression is off, else `EffectManager.GetValue(CraftingTier = 91,
/// null, base 1, player, recipe, recipe.tags)` folded over the player's crafting
/// skill and perk rows whose tags intersect the recipe's tag set (which stock
/// builds as `tags + "," + recipe name`), evaluated at the class's purchased
/// level. The folded float truncates (`conv.i4`) and the item clamps to its own
/// max quality tier; zdtd clamps 1..ItemClass.MaxQualityTier.
pub fn craftingTierFor(self: *Game, peer_slot: usize, recipe: assets_recipes.RecipeDef) u8 {
    const qmax = self.items.max_quality_tier;
    if (!craftingProgressionOn(self)) return qmax;
    var v: f32 = 1;
    var counts: assets_requirements.Counts = .{};
    const ctx: assets_requirements.Ctx = .{ .tags = recipe.tags };
    for (self.progression_table.crafting_skills) |sk| {
        foldCraftingTier(sk.passives, self.skillLevelOf(peer_slot, sk.name), ctx, &v, &counts);
    }
    for (self.progression_table.perks) |pk| {
        foldCraftingTier(pk.passives, self.skillLevelOf(peer_slot, pk.name), ctx, &v, &counts);
    }
    const tier: f32 = @trunc(v);
    if (!(tier >= 1)) return 1;
    return @intFromFloat(@min(tier, @as(f32, @floatFromInt(qmax))));
}

/// Deposit a crafted output. A HasQuality item carries the crafting tier as its
/// quality (stock TileEntityWorkstation builds the output ItemValue with
/// RecipeQueueItem.Quality; the inventory craft has no queue item and uses
/// GetCraftingTier). A quality item never merges into a different tier, so it
/// takes a free slot; a stackable keeps the plain merge path.
fn depositCrafted(self: *Game, ps: ecs.Slot, item_id: u16, count: u16, quality: u8) bool {
    const has_quality = if (self.items.byId(item_id)) |d| d.has_quality else false;
    if (!has_quality) return self.sim.depositItem(ps, item_id, count);
    const inv = &self.sim.inventory[ps];
    const max_stack = self.items.stackFor(item_id);
    if (max_stack > 1) {
        for (inv.slots[0..components.inv_equip_start]) |*sl| {
            if (sl.item_id != item_id or sl.quality != quality or sl.count == 0) continue;
            if (@as(u32, sl.count) + count > max_stack) continue;
            sl.count += count;
            return true;
        }
    }
    var fi: usize = 0;
    while (fi < components.inv_equip_start and inv.slots[fi].count != 0) : (fi += 1) {}
    if (fi >= components.inv_equip_start) return false;
    inv.slots[fi] = .{ .item_id = item_id, .count = count, .quality = quality };
    return true;
}

pub fn tryCraft(self: *Game, peer_slot: usize, recipe_index: u16, times: u16) bool {
    if (recipe_index >= self.recipes.defs.len) return false;
    return tryCraftRecipe(self, peer_slot, self.recipes.defs[recipe_index], times);
}

/// The general inventory craft path only handles recipes with no
/// workstation/tool/material requirements - the stock player inventory
/// never offers those, and accepting them here would bypass the workstation
/// gate (craft_area/craft_tool) or mint items from nothing (zero-ingredient
/// material_based / wildcard_forge_category scrap stubs). GAP "Server craft
/// execution" / "Scrapping". The workstation craft path (inv.zig) enforces
/// craft_area against the station block.
pub fn generalCraftAllowed(recipe: assets_recipes.RecipeDef) bool {
    return recipe.craft_area.len == 0 and recipe.craft_tool.len == 0 and !recipe.material_based and !recipe.wildcard_forge_category;
}

fn tryCraftRecipe(self: *Game, peer_slot: usize, recipe: assets_recipes.RecipeDef, times: u16) bool {
    const ps = self.sim.playerByPeer(peer_slot) orelse return false;
    if (!self.sim.mask[ps].inventory) return false;
    if (!generalCraftAllowed(recipe)) return false;
    if (assets_progression.unlockRequirement(&self.progression_table, recipe.name)) |req| {
        if (self.skillLevelOf(peer_slot, req[0]) < req[1]) return false;
    }
    // Crafting tier (Recipe.GetCraftingTier): the ingredient modifier level
    // and the crafted item's quality tier.
    const craft_tier: u8 = craftingTierFor(self, peer_slot, recipe);
    var n: u16 = if (times == 0) 1 else @min(times, self.craft_max_times);
    // Wasm-first (AGENTS rule 29): crafting passes the on_craft_request
    // verdict (<0 deny, 0 keep, >0 caps the batch). The recipe name is the
    // stable key. Plugins gate which recipes a player may craft / how many.
    {
        const pid: i32 = if (self.sim.mask[ps].network_id) self.sim.network_id[ps].id else -1;
        const sv = self.plugins.craftRequest(pid, recipe.name, n);
        const v = if (sv != 0) sv else self.wasm_plugins.craftRequest(pid, recipe.name, n);
        if (v < 0) return false;
        if (v > 0) n = @intCast(@min(@as(u32, n), @as(u32, @intCast(v))));
    }
    // Aggregate by ECS id so duplicate ingredient lines (or aliases that
    // resolve to the same id) do not double-count inventory room.
    var need: [assets_recipes.max_ingredients]struct { id: u16, count: u32 } = undefined;
    var nn: usize = 0;
    var i: u8 = 0;
    while (i < recipe.ingredient_n) : (i += 1) {
        const ing = recipe.ingredients[i];
        // Recipe.CanCraft IL_0041: with UseIngredientModifier the count is
        // EffectManager.GetValue(CraftingIngredientCount = 198) at the crafting
        // tier, truncated; a non-positive result means the ingredient is not
        // required at all - IL_0083 skips the scan before the item is ever
        // resolved - while a positive one is floored to 1 by FastMax (IL_0097).
        const mod_count = assets_recipes.ingredientCount(recipe, ing.name, ing.count, craft_tier);
        if (mod_count == 0) continue;
        const id = self.ecsIdFromItemName(ing.name);
        if (id == 0) return false;
        const need_count = @max(1, mod_count);
        const add: u32 = @as(u32, need_count) * n;
        var merged = false;
        var k: usize = 0;
        while (k < nn) : (k += 1) {
            if (need[k].id == id) {
                need[k].count += add;
                merged = true;
                break;
            }
        }
        if (!merged) {
            if (nn >= need.len) return false;
            need[nn] = .{ .id = id, .count = add };
            nn += 1;
        }
    }
    var j: usize = 0;
    while (j < nn) : (j += 1) {
        if (need[j].count > std.math.maxInt(u16)) return false;
        if (self.sim.inventory[ps].countItem(need[j].id) < need[j].count) return false;
    }
    const out_id = self.ecsIdFromItemName(recipe.name);
    if (out_id == 0) return false;
    const out_u32: u32 = @as(u32, recipe.count) * n;
    if (out_u32 == 0 or out_u32 > std.math.maxInt(u16)) return false;
    const out_count: u16 = @intCast(out_u32);
    // Snapshot so any remove/add failure restores the exact pre-craft bag.
    const inventory_before = self.sim.inventory[ps];
    j = 0;
    while (j < nn) : (j += 1) {
        if (!self.sim.inventory[ps].removeItem(need[j].id, @intCast(need[j].count))) {
            self.sim.inventory[ps] = inventory_before;
            return false;
        }
    }
    const out_quality: u8 = if (self.items.byId(out_id)) |d|
        (if (d.has_quality) craft_tier else 1)
    else
        1;
    if (!depositCrafted(self, ps, out_id, out_count, out_quality)) {
        self.sim.inventory[ps] = inventory_before;
        return false;
    }
    const p: u16 = if (peer_slot > std.math.maxInt(u16)) std.math.maxInt(u16) else @intCast(peer_slot);
    const d: i16 = @intCast(@min(out_count, std.math.maxInt(i16)));
    self.sim.inv_ledger.record(p, out_id, d, .craft);
    // Quest craft progress when objective matches recipe name.
    systems.questOnCraft(&self.sim, peer_slot, recipe.name);
    // Craft-complete XP (EntityPlayerLocal.GiveExp(CraftCompleteData);
    // crafting-recipes.md section 2). Only the recipes that declare
    // craft_exp_gain grant anything: verified against the shipped V3.1.0
    // recipes.xml that every declared value is 0 and 622 of 639 recipes
    // declare nothing at all, so an undeclared recipe (-1 sentinel) stays at
    // no grant rather than a guessed derivation. The stock diminishing-return
    // divisor (per-recipe cumulative craft count) has no observable effect
    // while every known value is 0 and is not implemented until a non-zero
    // declared value exists to prove it against.
    if (recipe.craft_exp_gain > 0) {
        self.awardXp(peer_slot, @as(u64, @intCast(recipe.craft_exp_gain)) * n);
    }
    return true;
}

/// Stock CraftingManager.GetScrapableRecipe(itemValue, count) (RE crafting-recipes.md
/// IL=77): MadeOfMaterial must carry a ForgeCategory, item must not be NoScrapping,
/// then the first wildcard_forge_category recipe whose output material shares that
/// ForgeCategory (output type != input type) and whose output weight is
/// <= itemWeight * count wins. Null when no match.
pub fn getScrapableRecipe(
    self: *Game,
    item_id: u16,
    count: u16,
) ?assets_recipes.RecipeDef {
    if (item_id == 0 or count == 0) return null;
    const def = self.items.byId(item_id) orelse return null;
    if (def.no_scrapping) return null;
    const mat = def.material;
    if (mat.len == 0) return null;
    const forge_cat = self.maxdamage.forgeCategoryForMaterial(mat);
    if (forge_cat.len == 0) return null;
    const item_weight = def.weight;
    if (item_weight == 0) return null;
    const budget: u32 = @as(u32, item_weight) * @as(u32, count);

    for (self.recipes.defs) |recipe| {
        if (!recipe.wildcard_forge_category) continue;
        const out_id = self.ecsIdFromItemName(recipe.name);
        if (out_id == 0 or out_id == item_id) continue;
        const out_def = self.items.byId(out_id) orelse continue;
        const out_mat = out_def.material;
        if (out_mat.len == 0) continue;
        const out_cat = self.maxdamage.forgeCategoryForMaterial(out_mat);
        if (out_cat.len == 0 or !std.mem.eql(u8, out_cat, forge_cat)) continue;
        const out_count: u16 = if (recipe.count == 0) 1 else recipe.count;
        const out_weight: u32 = @as(u32, out_def.weight) * @as(u32, out_count);
        if (out_weight == 0 or out_weight > budget) continue;
        return recipe;
    }
    return null;
}

/// InvTx scrap op: bag slot `a`, qty = input count (min 1). Resolves scrap via
/// GetScrapableRecipe, consumes the slot's input, deposits `recipe.count` of
/// the scrap output (one craft of the selected stub; the RE weight gate only
/// selects which recipe is legal). Snapshot/restore mirrors tryCraftRecipe;
/// ledger cause reuses .craft (no scrap-specific cause yet).
pub fn tryScrap(self: *Game, peer_slot: usize, bag_slot: u16, qty: u16) bool {
    const ps = self.sim.playerByPeer(peer_slot) orelse return false;
    if (!self.sim.mask[ps].inventory) return false;
    if (bag_slot >= components.max_inv_slots) return false;
    const slot = self.sim.inventory[ps].slots[bag_slot];
    if (slot.item_id == 0 or slot.count == 0) return false;
    var n: u16 = if (qty == 0) 1 else qty;
    if (n > slot.count) n = slot.count;

    const recipe = getScrapableRecipe(self, slot.item_id, n) orelse return false;
    const out_id = self.ecsIdFromItemName(recipe.name);
    if (out_id == 0) return false;
    const out_count: u16 = if (recipe.count == 0) 1 else recipe.count;

    const inventory_before = self.sim.inventory[ps];
    if (self.sim.inventory[ps].takeFromSlot(bag_slot, n) == null) {
        self.sim.inventory[ps] = inventory_before;
        return false;
    }
    if (!self.sim.depositItem(ps, out_id, out_count)) {
        self.sim.inventory[ps] = inventory_before;
        return false;
    }
    const p: u16 = if (peer_slot > std.math.maxInt(u16)) std.math.maxInt(u16) else @intCast(peer_slot);
    const d: i16 = @intCast(@min(out_count, std.math.maxInt(i16)));
    self.sim.inv_ledger.record(p, out_id, d, .craft);
    systems.questOnCraft(&self.sim, peer_slot, recipe.name);
    return true;
}

pub fn handItemDamage(self: *Game, hand_item: []const u8) f32 {
    if (hand_item.len == 0) return 0;
    if (self.items.byName(hand_item)) |d| return d.entity_damage;
    return 0;
}

/// Hand-item DamageBlock (items.xml) for the per-class block chew; 0 when
/// the hand item has none (the caller falls back to the Rules floor).
/// Stock: meleeHandZombie01 8, meleeHandZombieFeral 24.
pub fn handItemBlockChew(self: *Game, hand_item: []const u8) f32 {
    if (hand_item.len == 0) return 0;
    if (self.items.byName(hand_item)) |d| return d.damage_block;
    return 0;
}

/// Hand-item melee reach (items.xml Range, fallback passive MaxRange) for
/// the per-class attack-range gate; 0 when the hand item has none (the
/// caller falls back to the Rules floor). Stock: zombie hand 1.6,
/// club/axe 2.4.
pub fn handItemRange(self: *Game, hand_item: []const u8) f32 {
    if (hand_item.len == 0) return 0;
    if (self.items.byName(hand_item)) |d| return d.melee_range;
    return 0;
}

/// One workstation step: burn/craft, then re-broadcast the stations it changed.
pub fn tickWorkstations(self: *Game, dt: f32) !void {
    // Material-input module is block-derived (not in ZWS1); refresh each tick
    // so a loaded forge melts without waiting for a client TE rewrite.
    for (self.workstations.items[0..], self.workstations.used[0..]) |*w, u| {
        if (!u) continue;
        if (w.block_id > 0 and w.block_id <= 65535) {
            w.has_material_input = self.blocks.hasMaterialInput(@intCast(w.block_id));
        }
    }
    self.workstations.tickAllResolved(dt, resolveWorkstationOutput, self, .{
        .max_crafts_per_tick = self.workstation_crafts_per_tick,
        .max_craft_backlog = self.workstation_craft_backlog,
        .fuel_resolve = &resolveWorkstationFuel,
        .fuel_ctx = self,
        .on_craft_done = &onStationCraftDone,
        .craft_done_ctx = self,
        // Forge melt: scrap → unit_* via Weight / MeltTimePerUnit / Material →
        // materials.xml forge_category / InputMaterials / unit_* resolvers.
        // Tools PassiveEffects 95 (CraftingSmeltTime) scale melt duration.
        .weight_resolve = &resolveWorkstationWeight,
        .unit_stack_resolve = &resolveWorkstationUnitStack,
        .melt_time_resolve = &resolveWorkstationMeltTime,
        .forge_category_resolve = &resolveWorkstationForgeCategory,
        .input_materials_resolve = &resolveWorkstationInputMaterials,
        .unit_item_resolve = &resolveWorkstationUnitItem,
        .smelt_scale_resolve = &resolveWorkstationSmeltScale,
        .melt_ctx = self,
    });
    // Heat map feed (AIDirectorChunkData): burning workstations with a
    // blocks.xml HeatMapStrength (forge 6, campfire 5, workbench 5, ...)
    // raise the region's activity like stock TileEntity.heatMapLastTime.
    for (self.workstations.items[0..], self.workstations.used[0..]) |*w, u| {
        if (!u or !w.is_burning) continue;
        const strength = self.blocks.heatStrength(@intCast(w.block_id));
        if (strength > 0) {
            self.sim.director.notifyActivity(@floatFromInt(w.x), @floatFromInt(w.z), strength, self.sim.rules.director.heat_event_ticks);
        }
    }
    try replicate_te.broadcastDirtyWorkstations(self);
}

/// Server-initiated positional sound (stock GameManager.
/// PlaySoundAtPositionServer IL=60): builds NetPackageSoundAtPosition
/// (write IL=25) with entityId -1 (no owning player -> broadcast to all)
/// and fans out to every peer in interest range.
pub fn playSoundAt(self: *Game, x: f32, y: f32, z: f32, clip: []const u8, mode: u8, distance: i32, volume: f32) void {
    var s: packages.SoundAtPosition = .{
        .pos = .{ x, y, z },
        .mode = mode,
        .distance = distance,
        .entity_id = -1,
        .volume_scale = volume,
    };
    // clip_len is a u8 and the cap is 256, so the cap itself does not fit:
    // reject at >= or the @intCast below traps. The only caller today passes a
    // short literal, but the emit path must not depend on that.
    if (clip.len >= packages.max_audio_clip_len) return;
    @memcpy(s.clip[0..clip.len], clip);
    s.clip_len = @intCast(clip.len);
    if (packages.buildSoundAtPosition(self.body_buf[0..512], s) catch null) |sb| {
        self.broadcastNear("NetPackageSoundAtPosition", sb, x, z, self.interest_range) catch {};
    }
}

/// Forge smelt-completion ding (RE TileEntityForge IL_02F9-031F:
/// produced-this-tick -> PlaySoundAtPositionServer(worldPos.ToVector3(),
/// "Forge/forge_item_complete", Logarithmic, 100, 1)). Only the smelter
/// dings in stock; workbench/campfire/etc. are silent.
fn onStationCraftDone(ctx: ?*anyopaque, x: i32, y: i32, z: i32, block_id: u16) void {
    const g: *Game = @ptrCast(@alignCast(ctx orelse return));
    const name = (g.blocks.byId(block_id) orelse return).name;
    if (!std.mem.eql(u8, name, "forge")) return;
    playSoundAt(
        g,
        @as(f32, @floatFromInt(x)) + 0.5,
        @as(f32, @floatFromInt(y)) + 0.5,
        @as(f32, @floatFromInt(z)) + 0.5,
        "Forge/forge_item_complete",
        0, // AudioRolloffMode.Logarithmic
        100,
        1.0,
    );
}

/// BlockRadiusEffect (dedicated-misc-systems.md; asm.il
/// EntityPlayerLocal.BlockRadiusEffectsTick IL=83 / BlockRadiusEffectsApply
/// IL=58): a burning workstation carrying blocks.xml ActiveRadiusEffects
/// (campfire/burning-barrel warmth -> buffCampfireAOE) grants its buff to
/// every player within radius, refreshing while they stay in range;
/// ecs.buff.add already handles "already active" as a refresh, so nothing
/// here needs an explicit already-has check. The S2C relay fires only on a
/// fresh grant (.added), not on a refresh, since a duration-only refresh
/// changes nothing the client needs to hear about again.
///
/// Always-on light sources with no fuel module (torch, candle, and a
/// radiated barrel's buffRadiation01) are not covered here: they carry no
/// workstation record to iterate, and this pass does not build the
/// placed-block index a non-workstation version would need. See
/// WORK_PLAN T38.
pub fn tickBlockRadiusEffects(self: *Game) void {
    for (self.workstations.items[0..], self.workstations.used[0..]) |*w, used| {
        if (!used or !w.is_burning) continue;
        const eff = self.blocks.radiusEffect(@intCast(w.block_id)) orelse continue;
        const def_id = self.buffs.indexOfName(eff.buff) orelse continue;
        const def = self.buffs.byId(def_id) orelse continue;
        const wx: f32 = @floatFromInt(w.x);
        const wy: f32 = @floatFromInt(w.y);
        const wz: f32 = @floatFromInt(w.z);
        for (&self.clients) |*cl| {
            if (!cl.joined) continue;
            const ps = self.sim.playerByPeer(cl.slot) orelse continue;
            const t = self.sim.transform[ps];
            const dx = t.x - wx;
            const dy = t.y - wy;
            const dz = t.z - wz;
            if (dx * dx + dy * dy + dz * dz > eff.radius_sq) continue;
            // buffsMut lazily sets mask[ps].buffs and zeroes the slot on
            // first touch (world.zig), so there is nothing to pre-check here;
            // gating on the mask first would skip every player who has never
            // had a buff before, which is every fresh join.
            const set = self.sim.buffsMut(ps);
            const res = ecs.buff.add(set, .{
                .def_id = def_id,
                .duration = def.duration,
                .stack_type = def.stack_type,
                .update_rate_ticks = def.update_rate_ticks,
                .remove_on_death = def.remove_on_death,
            }, ecs.buff.duration_from_class, -1, w.x, w.y, w.z);
            if (res == .added) {
                game_social.relayBuff(self, cl.entity_id, def.name, true, -1, null) catch {};
            }
        }
    }
}

/// Always-on BlockRadiusEffect sources with no fuel module (WORK_PLAN T38;
/// RE dedicated-misc-systems.md BlockRadiusEffect / EntityPlayerLocal.
/// BlockRadiusEffectsTick IL=83): wallTorchLight(+Player) / candleWallLight /
/// burningBarrel(+Player) / cntBarrelRadiatedSingle00 /
/// decoPumpkinJackOLantern grant their ActiveRadiusEffects buff
/// (buffCampfireAOE warmth, buffCandleAOE, buffRadiation01) to every player
/// within radius, refreshing while in range (ecs.buff.add refresh; the S2C
/// relay fires only on a fresh grant like the workstation pass). Stock runs
/// the radius scan per player tick; zdtd scans the player's local 7x7x7
/// block neighborhood for no-fuel radius blocks instead of a placed-block
/// index (the source set is seven blocks, radius <= 3; the barrelRadiated
/// radius is 2.5, so the box must be at least 3 wide to cover its band; the
/// fuel-module workstations stay on tickBlockRadiusEffects, so no double
/// application).
pub fn tickAlwaysOnRadiusEffects(self: *Game) void {
    for (&self.clients) |*cl| {
        if (!cl.joined) continue;
        const ps = self.sim.playerByPeer(cl.slot) orelse continue;
        if (!self.sim.mask[ps].transform) continue;
        const t = self.sim.transform[ps];
        const px: i32 = @floor(t.x);
        const py: i32 = @floor(t.y);
        const pz: i32 = @floor(t.z);
        var dx: i32 = -3;
        while (dx <= 3) : (dx += 1) {
            var dy: i32 = -3;
            while (dy <= 3) : (dy += 1) {
                var dz: i32 = -3;
                while (dz <= 3) : (dz += 1) {
                    const bx = px + dx;
                    const by = py + dy;
                    const bz = pz + dz;
                    const bid = self.world.blockWorld(bx, by, bz) catch continue;
                    if (bid == 0) continue;
                    if (self.blocks.hasFuelModule(bid)) continue; // workstation path owns these
                    const eff = self.blocks.radiusEffect(bid) orelse continue;
                    const wx: f32 = @floatFromInt(bx);
                    const wy: f32 = @floatFromInt(by);
                    const wz: f32 = @floatFromInt(bz);
                    const fdx = t.x - wx;
                    const fdy = t.y - wy;
                    const fdz = t.z - wz;
                    if (fdx * fdx + fdy * fdy + fdz * fdz > eff.radius_sq) continue;
                    const def_id = self.buffs.indexOfName(eff.buff) orelse continue;
                    const def = self.buffs.byId(def_id) orelse continue;
                    const set = self.sim.buffsMut(ps);
                    const res = ecs.buff.add(set, .{
                        .def_id = def_id,
                        .duration = def.duration,
                        .stack_type = def.stack_type,
                        .update_rate_ticks = def.update_rate_ticks,
                        .remove_on_death = def.remove_on_death,
                    }, ecs.buff.duration_from_class, -1, bx, by, bz);
                    if (res == .added) {
                        game_social.relayBuff(self, cl.entity_id, def.name, true, -1, null) catch {};
                    }
                }
            }
        }
    }
}

test "itemIsArmor does not use offline pins after catalogs requested" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.create(std.testing.allocator, world_dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    try std.testing.expect(itemIsArmor(g, 11));
    g.stock_catalogs_requested = true;
    g.items.source = .xml;
    try std.testing.expect(!itemIsArmor(g, 99));
}

test "general craft path rejects workstation/tool/material recipes" {
    // GAP "Server craft execution": the inventory craft path must not accept
    // forge/campfire-area recipes (they need a station), tool-bound recipes,
    // zero-ingredient material_based recipes, or wildcard forge scrap stubs
    // that would mint scrap from nothing.
    const base = assets_recipes.RecipeDef{};
    try std.testing.expect(generalCraftAllowed(base));
    try std.testing.expect(!generalCraftAllowed(.{ .craft_area = "forge" }));
    try std.testing.expect(!generalCraftAllowed(.{ .craft_tool = "toolForgeHammer" }));
    try std.testing.expect(!generalCraftAllowed(.{ .material_based = true }));
    try std.testing.expect(!generalCraftAllowed(.{ .wildcard_forge_category = true }));
}

test "getScrapableRecipe and tryScrap follow RE weight/category rules" {
    // Injected tables: input metal item (weight 5) scraps to unit_iron (weight 1)
    // when forge_category matches; no_scrapping and overweight output reject.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.create(std.testing.allocator, world_dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }

    const scrap_in_id: u16 = 100;
    const scrap_out_id: u16 = 101;
    const heavy_out_id: u16 = 102;
    const noscrap_id: u16 = 103;
    const item_defs = [_]assets_items.ItemDef{
        .{ .id = 0, .name = "none", .stack = 0 },
        .{ .id = scrap_in_id, .name = "scrapInput", .stack = 64, .weight = 5, .material = "Mmetal" },
        .{ .id = scrap_out_id, .name = "unit_iron", .stack = 60000, .weight = 1, .material = "Mmetal" },
        .{ .id = heavy_out_id, .name = "unitHeavy", .stack = 64, .weight = 20, .material = "Mmetal" },
        .{ .id = noscrap_id, .name = "noScrapItem", .stack = 64, .weight = 5, .material = "Mmetal", .no_scrapping = true },
    };
    // Drop Game.create catalogs before injecting fixtures (else their arenas leak).
    g.items.deinit();
    g.items = .{ .defs = &item_defs, .source = .xml };
    g.recipes.deinit();

    const recipe_iron = assets_recipes.RecipeDef{
        .name = "unit_iron",
        .count = 1,
        .wildcard_forge_category = true,
    };
    const recipe_heavy = assets_recipes.RecipeDef{
        .name = "unitHeavy",
        .count = 1,
        .wildcard_forge_category = true,
    };
    // First matching recipe wins; iron before heavy so overweight is never chosen when iron fits.
    const recipe_defs = [_]assets_recipes.RecipeDef{ recipe_iron, recipe_heavy };
    const heavy_only = [_]assets_recipes.RecipeDef{recipe_heavy};
    g.recipes = .{ .defs = &recipe_defs, .source = .xml };

    g.maxdamage.deinit();
    const arena_holder = try std.testing.allocator.create(std.heap.ArenaAllocator);
    arena_holder.* = .init(std.testing.allocator);
    g.maxdamage = .{ .arena_ptr = arena_holder };
    const a = arena_holder.allocator();
    try g.maxdamage.material_forge_category.put(a, try a.dupe(u8, "Mmetal"), try a.dupe(u8, "iron"));

    // Match: weight 5 >= output 1, same forge category, different type.
    try std.testing.expect(getScrapableRecipe(g, scrap_in_id, 1) != null);
    try std.testing.expectEqualStrings("unit_iron", getScrapableRecipe(g, scrap_in_id, 1).?.name);

    // NoScrapping rejects.
    try std.testing.expect(getScrapableRecipe(g, noscrap_id, 1) == null);

    // Overweight gate: only heavy recipe present, output weight 20 > item 5.
    g.recipes = .{ .defs = &heavy_only, .source = .xml };
    try std.testing.expect(getScrapableRecipe(g, scrap_in_id, 1) == null);
    // Enough count clears the weight gate (5*4=20).
    try std.testing.expect(getScrapableRecipe(g, scrap_in_id, 4) != null);
    g.recipes = .{ .defs = &recipe_defs, .source = .xml };

    const peer: usize = 0;
    _ = g.sim.spawnPlayer(0, 70, 0, peer);
    const ps = g.sim.playerByPeer(peer).?;
    g.sim.inventory[ps].slots[0] = .{ .item_id = scrap_in_id, .count = 2 };

    try std.testing.expect(tryScrap(g, peer, 0, 1));
    try std.testing.expectEqual(@as(u16, 1), g.sim.inventory[ps].slots[0].count);
    // Yield is recipe.count (weight gate only selects the recipe).
    try std.testing.expectEqual(@as(u32, 1), g.sim.inventory[ps].countItem(scrap_out_id));

    // no_scrapping item in bag rejects.
    g.sim.inventory[ps].slots[1] = .{ .item_id = noscrap_id, .count = 1 };
    try std.testing.expect(!tryScrap(g, peer, 1, 1));
    try std.testing.expectEqual(@as(u16, 1), g.sim.inventory[ps].slots[1].count);
}
