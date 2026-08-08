//! Loot / item-table helpers — extracted verbatim from game.zig.
//! ecsIdFromItemName, loot bags, and loot-spawn broadcasts.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const packages = @import("../../wire/packages.zig");
const ecs = @import("../../ecs/root.zig");
const assets_loot = @import("../../assets/loot.zig");

pub fn ecsIdFromItemName(self: *Game, name: []const u8) u16 {
    const id = self.items.ecsIdByName(name);
    if (id != 0) return id;
    if (self.items.byStockName(name)) |st| {
        const sid = self.items.ecsIdFromStockType(st);
        if (sid != 0) return sid;
    }
    if (self.items.source == .builtin) {
        if (std.mem.eql(u8, name, "resourceScrapIron") or std.mem.eql(u8, name, "resourceScrapLead")) return 1;
        if (std.mem.eql(u8, name, "foodCanBeef")) return 2;
        if (std.mem.eql(u8, name, "resourceWood")) return 7;
        if (std.mem.eql(u8, name, "casinoCoin")) return 6;
    }
    return 0;
}

pub fn fillLootBagFromTable(self: *Game, bag_net_id: i32, loot_list: []const u8, seed: u32, loot_stage: i32) void {
    const list_name = if (loot_list.len > 0) loot_list else "EntityLootContainerRegular";
    var stacks: [assets_loot.max_roll_stacks]assets_loot.Stack = undefined;
    const n = self.loot.rollContainer(list_name, loot_stage, seed, &stacks);
    if (n == 0) return;
    const slot = self.sim.slotOfNetId(bag_net_id) orelse return;
    if (!self.sim.mask[slot].inventory) return;
    self.sim.inventory[slot].clear();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const eid = ecsIdFromItemName(self, stacks[i].item_name);
        if (eid == 0) continue;
        _ = self.sim.depositItem(slot, eid, stacks[i].count);
    }
    if (self.sim.inventory[slot].countItem(1) == 0 and self.sim.inventory[slot].slots[0].count == 0) {
        _ = self.sim.depositItem(slot, 1, 5);
    }
}

pub fn broadcastLootSpawn(self: *Game, net_id: i32) !void {
    const bi = self.sim.slotOfNetId(net_id) orelse return;
    var bag_slots: [ecs.components.max_inv_slots]packages.stock_inv.StockSlot = undefined;
    var bag_n: usize = 0;
    if (self.sim.mask[bi].inventory) {
        for (self.sim.inventory[bi].slots) |s| {
            if (s.count > 0 and s.item_id != 0) {
                bag_slots[bag_n] = packages.stock_inv.slotFromEcs(s, Game.resolveItemType, self);
                bag_n += 1;
            }
        }
    }
    const spb = try packages.stock_entity.buildEntitySpawnStock(&self.body_buf, .{
        .entity_id = net_id,
        .entity_class = packages.stock_entity.class_dropped_loot_container,
        .x = self.sim.transform[bi].x,
        .y = self.sim.transform[bi].y,
        .z = self.sim.transform[bi].z,
        .yaw = self.sim.transform[bi].yaw,
        .on_ground = true,
        .bag = if (bag_n > 0) bag_slots[0..bag_n] else null,
    });
    try self.broadcastNear("NetPackageEntitySpawn", spb, self.sim.transform[bi].x, self.sim.transform[bi].z, self.interest_range);
}

pub fn broadcastItemDropSpawn(self: *Game, net_id: i32, stack: packages.stock_inv.StockSlot, belongs_player_id: i32, client_entity_id: i32) !void {
    const bi = self.sim.slotOfNetId(net_id) orelse return;
    if (self.sim.mask[bi].inventory) {
        const dropped_item = self.sim.inventory[bi].slots[0].item_id;
        if (self.items.distractionFor(dropped_item)) |d| {
            self.sim.loot_bag[bi].distraction_tags = d.tags;
            self.sim.loot_bag[bi].distraction_radius_sq = d.radius * d.radius;
            self.sim.loot_bag[bi].distraction_lifetime = d.lifetime;
            self.sim.loot_bag[bi].distraction_strength = d.strength;
            self.sim.loot_bag[bi].distraction_eat_ticks = d.eat_ticks;
        }
    }
    const slot = if (stack.type_id != 0) stack else blk: {
        if (self.sim.mask[bi].inventory) {
            for (self.sim.inventory[bi].slots) |s| {
                if (s.count > 0 and s.item_id != 0) break :blk packages.stock_inv.slotFromEcs(s, Game.resolveItemType, self);
            }
        }
        break :blk stack;
    };
    if (slot.type_id == 0 or slot.count == 0) {
        try broadcastLootSpawn(self, net_id);
        return;
    }
    const spb = try packages.stock_entity.buildEntitySpawnStock(&self.body_buf, .{
        .entity_id = net_id,
        .entity_class = packages.stock_entity.class_item,
        .x = self.sim.transform[bi].x,
        .y = self.sim.transform[bi].y,
        .z = self.sim.transform[bi].z,
        .yaw = self.sim.transform[bi].yaw,
        .on_ground = true,
        .item_drop = slot,
        .belongs_player_id = belongs_player_id,
        .client_entity_id = client_entity_id,
    });
    try self.broadcastNear("NetPackageEntitySpawn", spb, self.sim.transform[bi].x, self.sim.transform[bi].z, self.interest_range);
}
