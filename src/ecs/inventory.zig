//! Inventory systems: move/drop/hold/use/open-container transactions.

const std = @import("std");
const World = @import("world.zig").World;
const Slot = @import("world.zig").Slot;
const c = @import("components.zig");

pub const Op = enum(u8) {
    list = 0,
    move = 1,
    drop = 2,
    set_hold = 3,
    use = 4,
    open = 5, // open container entity
    close = 6,
    take = 7, // take from open container slot into bag
    put = 8, // put into open container
    place = 9, // place held placeable as block (needs world hook via Result)
    equip = 10, // move slot a → equip slot b (0..equip_count-1)
    /// Craft: a = recipe index (caller resolves), qty = output multiplier (min 1).
    craft = 11,
};

pub const Result = struct {
    ok: bool = false,
    dropped_entity: i32 = -1,
    /// place op: block to set in world (0 = none)
    place_block: u16 = 0,
    place_x: i32 = 0,
    place_y: i32 = 0,
    place_z: i32 = 0,
};

fn maxStackFor(item_id: u16) u16 {
    // Builtin catalog is the id source of truth (items.xml stacks apply to
    // XML-registered ids via ItemTable.stackFor at the Game layer).
    const items = @import("../assets/items.zig");
    for (items.builtin_defs) |d| {
        if (d.id == item_id) return if (d.stack == 0) 1 else d.stack;
    }
    return 60000;
}

/// Map inventory item → world block id (0 = not placeable).
pub fn itemToBlock(item_id: u16) u16 {
    return switch (item_id) {
        7 => 4, // wood item → wood block
        10 => 5, // cobble placeable
        else => 0,
    };
}

pub fn isArmor(item_id: u16) bool {
    return item_id == 11;
}

/// Armor in equip slots reduces incoming damage (0..0.5).
pub fn armorMitigation(w: *const World, peer: usize) f32 {
    const ps = w.playerByPeer(peer) orelse return 0;
    if (!w.mask[ps].inventory) return 0;
    var pieces: f32 = 0;
    var i: usize = c.inv_equip_start;
    while (i < c.max_inv_slots) : (i += 1) {
        if (w.inventory[ps].slots[i].count > 0 and isArmor(w.inventory[ps].slots[i].item_id)) {
            pieces += 1;
        }
    }
    return @min(0.5, pieces * 0.1);
}

pub fn give(w: *World, peer: usize, item_id: u16, count: u16) bool {
    const ps = w.playerByPeer(peer) orelse return false;
    if (!w.mask[ps].inventory) return false;
    const ok = w.inventory[ps].addItemStacked(item_id, count, maxStackFor(item_id));
    if (ok) markInv(w, ps);
    return ok;
}

pub fn setHolding(w: *World, peer: usize, slot: u16) bool {
    const ps = w.playerByPeer(peer) orelse return false;
    if (!w.mask[ps].inventory) return false;
    const ok = w.inventory[ps].setHolding(slot);
    if (ok) markInv(w, ps);
    return ok;
}

pub fn move(w: *World, peer: usize, from: u16, to: u16, qty: u16) bool {
    const ps = w.playerByPeer(peer) orelse return false;
    if (!w.mask[ps].inventory) return false;
    const item = w.inventory[ps].slots[from].item_id;
    const ok = w.inventory[ps].moveSlot(from, to, qty, maxStackFor(item));
    if (ok) markInv(w, ps);
    return ok;
}

/// Drop qty from slot onto ground as loot bag; returns bag net id.
pub fn drop(w: *World, peer: usize, slot: u16, qty: u16) Result {
    const ps = w.playerByPeer(peer) orelse return .{};
    if (!w.mask[ps].inventory or !w.mask[ps].transform) return .{};
    const taken = w.inventory[ps].takeFromSlot(slot, if (qty == 0) w.inventory[ps].slots[slot].count else qty) orelse return .{};
    const t = w.transform[ps];
    const bag = w.spawnLootBag(t.x + 0.5, t.y, t.z + 0.5, taken.item_id, taken.count) orelse {
        // refund
        _ = w.inventory[ps].addItemStacked(taken.item_id, taken.count, maxStackFor(taken.item_id));
        return .{};
    };
    // fix quality/meta on bag first slot
    if (w.slotOfNetId(bag)) |bi| {
        if (w.mask[bi].inventory) {
            w.inventory[bi].slots[0].quality = taken.quality;
            w.inventory[bi].slots[0].meta = taken.meta;
        }
    }
    markInv(w, ps);
    return .{ .ok = true, .dropped_entity = bag };
}

/// Use consumable in slot (food=2, medicine=4): remove 1, heal a bit.
pub fn use(w: *World, peer: usize, slot: u16) bool {
    const ps = w.playerByPeer(peer) orelse return false;
    if (!w.mask[ps].inventory or !w.mask[ps].health) return false;
    if (slot >= c.max_inv_slots) return false;
    const s = w.inventory[ps].slots[slot];
    if (s.count == 0) return false;
    const heal: f32 = switch (s.item_id) {
        2 => 10, // food
        4 => 25, // medicine
        else => return false,
    };
    _ = w.inventory[ps].takeFromSlot(slot, 1) orelse return false;
    w.health[ps].hp = @min(w.health[ps].max_hp, w.health[ps].hp + heal);
    if (w.mask[ps].dirty) w.dirty[ps].hp = true;
    markInv(w, ps);
    return true;
}

pub fn openContainer(w: *World, peer: usize, container_net: i32) bool {
    const ps = w.playerByPeer(peer) orelse return false;
    if (!w.mask[ps].inventory) return false;
    const cs = w.slotOfNetId(container_net) orelse return false;
    if (!w.mask[cs].loot_bag and !w.mask[cs].inventory) return false;
    if (w.mask[ps].transform and w.mask[cs].transform) {
        const dx = w.transform[ps].x - w.transform[cs].x;
        const dz = w.transform[ps].z - w.transform[cs].z;
        if (dx * dx + dz * dz > 64.0) return false;
    }
    w.inventory[ps].open_container = container_net;
    if (w.mask[cs].loot_bag) w.loot_bag[cs].open = true;
    markInv(w, ps);
    return true;
}

pub fn closeContainer(w: *World, peer: usize) void {
    const ps = w.playerByPeer(peer) orelse return;
    if (!w.mask[ps].inventory) return;
    const cid = w.inventory[ps].open_container;
    if (cid >= 0) {
        if (w.slotOfNetId(cid)) |cs| {
            if (w.mask[cs].loot_bag) w.loot_bag[cs].open = false;
        }
    }
    w.inventory[ps].open_container = -1;
}

/// Take from open container slot into player inventory.
pub fn takeFromContainer(w: *World, peer: usize, cont_slot: u16, qty: u16) bool {
    const ps = w.playerByPeer(peer) orelse return false;
    if (!w.mask[ps].inventory) return false;
    const cid = w.inventory[ps].open_container;
    if (cid < 0) return false;
    const cs = w.slotOfNetId(cid) orelse return false;
    if (!w.mask[cs].inventory) return false;
    const taken = w.inventory[cs].takeFromSlot(cont_slot, if (qty == 0) w.inventory[cs].slots[cont_slot].count else qty) orelse return false;
    if (!w.inventory[ps].addItemStacked(taken.item_id, taken.count, maxStackFor(taken.item_id))) {
        // refund container
        _ = w.inventory[cs].putInSlot(cont_slot, taken, maxStackFor(taken.item_id));
        return false;
    }
    // empty bag despawn
    var empty = true;
    for (w.inventory[cs].slots[0..c.inv_equip_start]) |s| {
        if (s.count > 0) {
            empty = false;
            break;
        }
    }
    if (empty and w.mask[cs].loot_bag) {
        w.inventory[ps].open_container = -1;
        w.destroy(cs);
    }
    markInv(w, ps);
    return true;
}

pub fn putIntoContainer(w: *World, peer: usize, player_slot: u16, qty: u16) bool {
    const ps = w.playerByPeer(peer) orelse return false;
    if (!w.mask[ps].inventory) return false;
    const cid = w.inventory[ps].open_container;
    if (cid < 0) return false;
    const cs = w.slotOfNetId(cid) orelse return false;
    if (!w.mask[cs].inventory) return false;
    const taken = w.inventory[ps].takeFromSlot(player_slot, if (qty == 0) w.inventory[ps].slots[player_slot].count else qty) orelse return false;
    if (!w.inventory[cs].addItemStacked(taken.item_id, taken.count, maxStackFor(taken.item_id))) {
        _ = w.inventory[ps].addItemStacked(taken.item_id, taken.count, maxStackFor(taken.item_id));
        return false;
    }
    markInv(w, ps);
    return true;
}

/// Equip armor from slot `from` into equip index `equip_i` (0..equip_count-1).
pub fn equip(w: *World, peer: usize, from: u16, equip_i: u16) bool {
    const ps = w.playerByPeer(peer) orelse return false;
    if (!w.mask[ps].inventory) return false;
    if (equip_i >= c.inv_equip_count) return false;
    if (from >= c.max_inv_slots) return false;
    const item = w.inventory[ps].slots[from];
    if (item.count == 0 or !isArmor(item.item_id)) return false;
    const to: u16 = @intCast(c.inv_equip_start + equip_i);
    return move(w, peer, from, to, 1);
}

/// Place one placeable from held/toolbelt slot at (x,y,z) world coords.
pub fn placeBlock(w: *World, peer: usize, slot: u16, x: i32, y: i32, z: i32) Result {
    const ps = w.playerByPeer(peer) orelse return .{};
    if (!w.mask[ps].inventory) return .{};
    if (slot >= c.max_inv_slots) return .{};
    const item = w.inventory[ps].slots[slot];
    if (item.count == 0) return .{};
    const block = itemToBlock(item.item_id);
    if (block == 0) return .{};
    _ = w.inventory[ps].takeFromSlot(slot, 1) orelse return .{};
    markInv(w, ps);
    return .{ .ok = true, .place_block = block, .place_x = x, .place_y = y, .place_z = z };
}

/// Apply inventory op. `entity_id` used for open; for place, a=slot and entity_id packs x|y in low/high?  
/// Place uses a=slot, b=y, qty unused, entity_id = (x & 0xffff) | (z << 16) signed mid.
pub fn applyTransaction(w: *World, peer: usize, op: Op, a: u16, b: u16, qty: u16, entity_id: i32) Result {
    return switch (op) {
        .list => .{ .ok = true },
        .move => .{ .ok = move(w, peer, a, b, qty) },
        .drop => drop(w, peer, a, qty),
        .set_hold => .{ .ok = setHolding(w, peer, a) },
        .use => .{ .ok = use(w, peer, a) },
        .open => .{ .ok = openContainer(w, peer, entity_id) },
        .close => blk: {
            closeContainer(w, peer);
            break :blk .{ .ok = true };
        },
        .take => .{ .ok = takeFromContainer(w, peer, a, qty) },
        .put => .{ .ok = putIntoContainer(w, peer, a, qty) },
        .equip => .{ .ok = equip(w, peer, a, b) },
        .place => blk: {
            // entity_id = x, b = y as u16 signed via bitcast, qty = z low 16 bits signed extend
            const x: i32 = entity_id;
            const y: i32 = @as(i16, @bitCast(b));
            const z: i32 = @as(i16, @bitCast(qty));
            break :blk placeBlock(w, peer, a, x, y, z);
        },
        // Craft resolved in Game (needs recipes + item name map).
        .craft => .{ .ok = false },
    };
}

fn markInv(w: *World, ps: Slot) void {
    if (w.mask[ps].dirty) w.dirty[ps].inv = true;
}

test "move and drop and use" {
    const WorldT = @import("world.zig").World;
    var w: WorldT = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    _ = w.spawnPlayer(0, 70, 0, 0);
    try std.testing.expect(give(&w, 0, 2, 3)); // food
    const ps = w.playerByPeer(0).?;
    var food_slot: u16 = 0;
    for (w.inventory[ps].slots, 0..) |s, i| {
        if (s.item_id == 2) {
            food_slot = @intCast(i);
            break;
        }
    }
    w.health[ps].hp = 50;
    try std.testing.expect(use(&w, 0, food_slot));
    try std.testing.expect(w.health[ps].hp >= 59.9);
    try std.testing.expect(setHolding(&w, 0, 0));
    const r = drop(&w, 0, 0, 1);
    try std.testing.expect(r.ok);
    try std.testing.expect(r.dropped_entity > 0);
    try std.testing.expect(openContainer(&w, 0, r.dropped_entity));
    try std.testing.expect(takeFromContainer(&w, 0, 0, 0));
}

test "craft op reserved" {
    try std.testing.expectEqual(@as(u8, 11), @intFromEnum(Op.craft));
}

test "equip armor and place wood" {
    const WorldT = @import("world.zig").World;
    var w: WorldT = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    _ = w.spawnPlayer(0, 70, 0, 0);
    try std.testing.expect(give(&w, 0, 11, 1)); // armor
    try std.testing.expect(give(&w, 0, 7, 5)); // wood
    const ps = w.playerByPeer(0).?;
    var armor_slot: u16 = 0;
    for (w.inventory[ps].slots, 0..) |s, i| {
        if (s.item_id == 11) {
            armor_slot = @intCast(i);
            break;
        }
    }
    try std.testing.expect(equip(&w, 0, armor_slot, 0));
    try std.testing.expect(armorMitigation(&w, 0) >= 0.09);
    var wood_slot: u16 = 0;
    for (w.inventory[ps].slots, 0..) |s, i| {
        if (s.item_id == 7) {
            wood_slot = @intCast(i);
            break;
        }
    }
    const pr = placeBlock(&w, 0, wood_slot, 1, 70, 1);
    try std.testing.expect(pr.ok);
    try std.testing.expectEqual(@as(u16, 4), pr.place_block);
}
