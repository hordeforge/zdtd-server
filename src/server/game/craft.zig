//! Crafting and workstation helpers, extracted verbatim from game.zig:
//! tryCraft/tryCraftRecipe (InvTx craft op), tickWorkstations (burn/craft +
//! heat map feed), tryRefuelGenerator (InvTx refuel), eatProps / itemIsArmor
//! (items.xml ItemActionEat + armor checks), resolveWorkstationOutput, and
//! handItemDamage (entity damage from the hand item).

const std = @import("std");
const ecs = @import("../../ecs/root.zig");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const assets_items = @import("../../assets/items.zig");
const assets_recipes = @import("../../assets/recipes.zig");
const invsys = @import("../../ecs/inventory.zig");
const systems = @import("../../ecs/systems.zig");
const replicate_te = @import("../replicate_te.zig");
const workstations_mod = @import("../../world/workstations.zig");
const game_social = @import("social.zig");

/// Vehicle tank cap and the InvTx refuel pickup reach are
/// rules.vehicle (fuel_cap / refuel_reach).

/// ECS armor hook: stock/builtin name starts with "armor".
pub fn itemIsArmor(ctx: ?*anyopaque, item_id: u16) bool {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    if (g.items.byId(item_id)) |d| {
        if (std.mem.startsWith(u8, d.name, "armor")) return true;
    }
    if (invsys.builtinStockNameFallback(item_id)) |n| {
        if (std.mem.startsWith(u8, n, "armor")) return true;
    }
    return invsys.isArmorOffline(item_id);
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
    const fuel_cap = self.sim.rules.vehicle.fuel_cap;
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

/// Craft recipe by index into recipes.defs (InvTx craft op). Consumes ingredients, grants output.
pub fn tryCraft(self: *Game, peer_slot: usize, recipe_index: u16, times: u16) bool {
    if (recipe_index >= self.recipes.defs.len) return false;
    return tryCraftRecipe(self, peer_slot, self.recipes.defs[recipe_index], times);
}

/// The general inventory craft path only handles recipes with no
/// workstation/tool/material requirements - the stock player inventory
/// never offers those, and accepting them here would bypass the workstation
/// gate (craft_area/craft_tool) or mint items from nothing (zero-ingredient
/// material_based recipes). GAP "Server craft execution". The workstation
/// craft path (inv.zig) enforces craft_area against the station block.
pub fn generalCraftAllowed(recipe: assets_recipes.RecipeDef) bool {
    return recipe.craft_area.len == 0 and recipe.craft_tool.len == 0 and !recipe.material_based;
}

fn tryCraftRecipe(self: *Game, peer_slot: usize, recipe: assets_recipes.RecipeDef, times: u16) bool {
    const ps = self.sim.playerByPeer(peer_slot) orelse return false;
    if (!self.sim.mask[ps].inventory) return false;
    if (!generalCraftAllowed(recipe)) return false;
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
        const id = self.ecsIdFromItemName(ing.name);
        if (id == 0) return false;
        const add: u32 = @as(u32, ing.count) * n;
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
    if (!self.sim.depositItem(ps, out_id, out_count)) {
        self.sim.inventory[ps] = inventory_before;
        return false;
    }
    self.sim.markDirty(ps, .{ .inv = true });
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

pub fn handItemDamage(self: *Game, hand_item: []const u8) f32 {
    if (hand_item.len == 0) return 0;
    if (self.items.byName(hand_item)) |d| return d.entity_damage;
    return 0;
}

/// One workstation step: burn/craft, then re-broadcast the stations it changed.
pub fn tickWorkstations(self: *Game, dt: f32) !void {
    self.workstations.tickAllResolved(dt, resolveWorkstationOutput, self, .{
        .max_crafts_per_tick = self.workstation_crafts_per_tick,
        .max_craft_backlog = self.workstation_craft_backlog,
        .fuel_resolve = &resolveWorkstationFuel,
        .fuel_ctx = self,
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

test "general craft path rejects workstation/tool/material recipes" {
    // GAP "Server craft execution": the inventory craft path must not accept
    // forge/campfire-area recipes (they need a station), tool-bound recipes,
    // or zero-ingredient material_based recipes that would mint items.
    const base = assets_recipes.RecipeDef{};
    try std.testing.expect(generalCraftAllowed(base));
    try std.testing.expect(!generalCraftAllowed(.{ .craft_area = "forge" }));
    try std.testing.expect(!generalCraftAllowed(.{ .craft_tool = "toolForgeHammer" }));
    try std.testing.expect(!generalCraftAllowed(.{ .material_based = true }));
}
