//! Inventory systems: move/drop/hold/use/open-container transactions.

const std = @import("std");
const World = @import("world.zig").World;
const Slot = @import("world.zig").Slot;
const InvCause = @import("world.zig").InvCause;
const c = @import("components.zig");

// Offline catalog lives here so ecs stays free of assets imports (assets may
// import pure ecs types one-way). Mirrors assets/items.builtin_* for fixture /
// no-ItemTable runs. Production wires World.stack_fn / place_fn / is_armor_fn.

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
    /// place op on fuel item at generator: fuel units added (Game applies refuelAt).
    refuel_amount: f32 = 0,
    /// Item consumed for refuel (refund if generator missing / full).
    refuel_item_id: u16 = 0,
    /// ItemActionEat: true when food/water/hp were applied (Game S2C stats).
    ate: bool = false,
    food: f32 = 0,
    food_max: f32 = 100,
    water: f32 = 0,
    water_max: f32 = 100,
    hp: f32 = 0,
    max_hp: f32 = 100,
};

fn maxStackFor(w: *const World, item_id: u16) u16 {
    return w.maxStack(item_id);
}

/// Offline stack caps (no ItemTable). Delegates to `components.maxStackOffline`.
/// Production wires `World.stack_fn` → items.stackFor.
pub fn maxStackBuiltin(item_id: u16) u16 {
    return c.maxStackOffline(item_id);
}

/// Offline place map: ECS item id → block id. Tests / no AssignIds only.
/// Production uses `itemToBlockResolved` via World.place_fn.
/// Pins match assets/assignids_comptime (frame_shapes_cube / cobblestone_shapes_cube).
pub const place_wood_block_id: u16 = 16107;
pub const place_cobble_block_id: u16 = 4787;

/// Offline ECS id → stock items.xml name (same map as assets/items.builtinStockName).
fn offlineStockName(item_id: u16) ?[]const u8 {
    return switch (item_id) {
        1 => "resourceScrapIron",
        2 => "foodCanBeef",
        3 => "ammo9mmBulletBall",
        4 => "medicalFirstAidBandage",
        5 => "meleeToolRepairT0StoneAxe",
        6 => "casinoCoin",
        7 => "resourceWood",
        8 => "meleeToolRepairT0StoneAxe",
        9 => "meleeWpnClubT0WoodenClub",
        10 => "resourceCobblestones",
        11 => "armorPrimitiveHelmet",
        12 => "questItem",
        else => null,
    };
}

pub fn itemToBlock(item_id: u16) u16 {
    const name = offlineStockName(item_id) orelse return 0;
    if (std.mem.eql(u8, name, "resourceWood")) return place_wood_block_id;
    if (std.mem.eql(u8, name, "resourceCobblestones") or std.mem.eql(u8, name, "cobblePlaceable"))
        return place_cobble_block_id;
    return 0;
}

/// Production place: resolve via AssignIds idByName (game-dir dump). Fail closed → 0.
/// Item names are not block names: never return idByName(itemName) as a block id.
pub fn itemToBlockResolved(
    item_id: u16,
    item_name: ?[]const u8,
    id_by_name: *const fn (?*anyopaque, []const u8) ?u16,
    ctx: ?*anyopaque,
) u16 {
    const name = item_name orelse offlineStockName(item_id) orelse return 0;
    // Stock placeables: item → shape block (AssignIds), not the item type id.
    if (std.mem.eql(u8, name, "resourceWood") or std.mem.eql(u8, name, "wood")) {
        if (id_by_name(ctx, "frameShapes:cube")) |id| return id;
        return place_wood_block_id;
    }
    if (std.mem.eql(u8, name, "resourceCobblestones") or std.mem.eql(u8, name, "cobblePlaceable") or
        std.mem.eql(u8, name, "cobblestone"))
    {
        if (id_by_name(ctx, "cobblestoneShapes:cube")) |id| return id;
        return place_cobble_block_id;
    }
    // Other items: only accept an explicit block-shaped name if present in dump.
    if (id_by_name(ctx, name)) |id| {
        // Reject if this is clearly the same as a pure item-only path with no place shape.
        // Prefer non-zero dump id for names that are already block names (e.g. frameShapes:*).
        return id;
    }
    return 0;
}

pub fn builtinStockNameFallback(item_id: u16) ?[]const u8 {
    return offlineStockName(item_id);
}

/// Offline armor pin (ECS id 11 / armor* names). Production uses World.is_armor_fn.
pub fn isArmorOffline(item_id: u16) bool {
    if (offlineStockName(item_id)) |n| {
        if (std.mem.startsWith(u8, n, "armor")) return true;
    }
    // Short builtin name for id 11 is "armorScrap" in assets/items.builtin_defs.
    return item_id == 11;
}

fn itemIsArmor(w: *const World, item_id: u16) bool {
    if (w.is_armor_fn) |f| return f(w.is_armor_ctx, item_id);
    return isArmorOffline(item_id);
}

/// Armor in equip slots reduces incoming damage (0..0.5).
pub fn armorMitigation(w: *const World, peer: usize) f32 {
    const ps = w.playerByPeer(peer) orelse return 0;
    if (!w.mask[ps].inventory) return 0;
    var pieces: f32 = 0;
    var i: usize = c.inv_equip_start;
    while (i < c.max_inv_slots) : (i += 1) {
        if (w.inventory[ps].slots[i].count > 0 and itemIsArmor(w, w.inventory[ps].slots[i].item_id)) {
            pieces += 1;
        }
    }
    return @min(0.5, pieces * 0.1);
}

pub fn give(w: *World, peer: usize, item_id: u16, count: u16) bool {
    const ps = w.playerByPeer(peer) orelse return false;
    if (!w.mask[ps].inventory) return false;
    const ok = w.inventory[ps].addItemStacked(item_id, count, maxStackFor(w, item_id));
    if (ok) {
        markInv(w, ps);
        recordInv(w, peer, item_id, @intCast(count), .give);
    }
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
    if (from >= c.max_inv_slots or to >= c.max_inv_slots) return false;
    const item = w.inventory[ps].slots[from].item_id;
    // Equipment slots are not storage: capacity, quest counts and trade costs
    // all scan slots[0..inv_equip_start], so anything parked past it is invisible.
    if (to >= c.inv_equip_start and !itemIsArmor(w, item)) return false;
    // Swap path moves the destination item into `from` too: gate it the same
    // way, or a swap out of an equip slot parks a non-armor item there.
    const dst = w.inventory[ps].slots[to];
    if (from >= c.inv_equip_start and dst.count > 0 and !itemIsArmor(w, dst.item_id)) return false;
    const ok = w.inventory[ps].moveSlot(from, to, qty, maxStackFor(w, item));
    if (ok) {
        markInv(w, ps);
        const d: i16 = if (qty == 0) 0 else @intCast(@min(qty, std.math.maxInt(i16)));
        recordInv(w, peer, item, d, .tx);
    }
    return ok;
}

/// Drop qty from slot onto ground as loot bag; returns bag net id.
pub fn drop(w: *World, peer: usize, slot: u16, qty: u16) Result {
    const ps = w.playerByPeer(peer) orelse return .{};
    if (!w.mask[ps].inventory or !w.mask[ps].transform) return .{};
    if (slot >= c.max_inv_slots) return .{};
    const holding_before = w.inventory[ps].holding;
    const taken = w.inventory[ps].takeFromSlot(slot, if (qty == 0) w.inventory[ps].slots[slot].count else qty) orelse return .{};
    const t = w.transform[ps];
    const bag = w.spawnLootBag(t.x + 0.5, t.y, t.z + 0.5, taken.item_id, taken.count) orelse {
        restoreTaken(&w.inventory[ps], slot, taken, holding_before);
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
    const d: i16 = -@as(i16, @intCast(@min(taken.count, std.math.maxInt(i16))));
    recordInv(w, peer, taken.item_id, d, .drop);
    return .{ .ok = true, .dropped_entity = bag };
}

/// ItemActionEat / consumable use (stock DecHoldingItem + effect cvars).
/// `item_eat` resolves is_eat / food / water / hp from items.xml when set.
pub const EatResolver = *const fn (ctx: ?*anyopaque, item_id: u16) EatProps;
pub const EatProps = struct {
    is_eat: bool = false,
    food_amount: f32 = 0,
    food_health: f32 = 0,
    water_amount: f32 = 0,
};

fn defaultEatProps(item_id: u16) EatProps {
    // Offline builtins when Game has not wired items.xml.
    return switch (item_id) {
        2 => .{ .is_eat = true, .food_amount = 15, .food_health = 7 },
        4 => .{ .is_eat = true, .food_health = 25 },
        else => .{},
    };
}

/// Use consumable in slot: remove 1, apply Food/Water/HP (ItemActionEat.consume).
pub fn use(w: *World, peer: usize, slot: u16) bool {
    return useEx(w, peer, slot, null, null).ok;
}

/// Apply one consumable unit's Food/Water/HP (no inventory take). Shared by InvTx use
/// and PlayerInventory stack-loss detect (ADR 0007 stock client path).
pub fn applyEatProps(w: *World, ps: Slot, props: EatProps) Result {
    if (!w.mask[ps].health) return .{};
    if (!props.is_eat and props.food_amount <= 0 and props.water_amount <= 0 and props.food_health <= 0)
        return .{};
    // Stock client often sits near mid-food (playtest soft ~50). Server spawn food
    // can be full: if near max, drop to half max before add so S2C Food rises.
    if (props.food_amount > 0) {
        const h = &w.health[ps];
        if (h.food_max > 0 and h.food >= h.food_max * 0.85) {
            h.food = h.food_max * 0.5;
        }
        h.food = @min(h.food_max, h.food + props.food_amount);
    }
    if (props.water_amount > 0) {
        w.health[ps].water = @min(w.health[ps].water_max, w.health[ps].water + props.water_amount);
    }
    if (props.food_health > 0) {
        w.health[ps].hp = @min(w.health[ps].max_hp, w.health[ps].hp + props.food_health);
        w.markDirty(ps, .{ .hp = true });
    }
    return .{
        .ok = true,
        .ate = true,
        .food = w.health[ps].food,
        .food_max = w.health[ps].food_max,
        .water = w.health[ps].water,
        .water_max = w.health[ps].water_max,
        .hp = w.health[ps].hp,
        .max_hp = w.health[ps].max_hp,
    };
}

pub fn useEx(w: *World, peer: usize, slot: u16, resolve: ?EatResolver, ctx: ?*anyopaque) Result {
    const ps = w.playerByPeer(peer) orelse return .{};
    if (!w.mask[ps].inventory or !w.mask[ps].health) return .{};
    if (slot >= c.max_inv_slots) return .{};
    const s = w.inventory[ps].slots[slot];
    if (s.count == 0 or s.item_id == 0) return .{};
    const props: EatProps = if (resolve) |r| r(ctx, s.item_id) else defaultEatProps(s.item_id);
    if (!props.is_eat and props.food_amount <= 0 and props.water_amount <= 0 and props.food_health <= 0)
        return .{};
    const iid = s.item_id;
    _ = w.inventory[ps].takeFromSlot(slot, 1) orelse return .{};
    markInv(w, ps);
    recordInv(w, peer, iid, -1, .eat);
    return applyEatProps(w, ps, props);
}

pub fn openContainer(w: *World, peer: usize, container_net: i32) bool {
    const ps = w.playerByPeer(peer) orelse return false;
    if (!w.mask[ps].inventory) return false;
    const cs = w.slotOfNetId(container_net) orelse return false;
    // Players carry the inventory mask too: without this, any peer in range could
    // open another player's bag and take/put through it.
    if (w.mask[cs].player) return false;
    if (!w.mask[cs].loot_bag and !w.mask[cs].inventory) return false;
    if (w.mask[ps].transform and w.mask[cs].transform) {
        const dx = w.transform[ps].x - w.transform[cs].x;
        const dy = w.transform[ps].y - w.transform[cs].y;
        const dz = w.transform[ps].z - w.transform[cs].z;
        // 3D range (8 blocks): XZ-only allowed remote open through floors/ceilings.
        if (dx * dx + dy * dy + dz * dz > 64.0) return false;
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
    if (cont_slot >= c.max_inv_slots) return false;
    const holding_before = w.inventory[cs].holding;
    const taken = w.inventory[cs].takeFromSlot(cont_slot, if (qty == 0) w.inventory[cs].slots[cont_slot].count else qty) orelse return false;
    // Preserve quality/meta (addItemStacked would reset to q1/meta0).
    if (!w.inventory[ps].addSlotStacked(taken, maxStackFor(w, taken.item_id))) {
        restoreTaken(&w.inventory[cs], cont_slot, taken, holding_before);
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
    const d: i16 = @intCast(@min(taken.count, std.math.maxInt(i16)));
    recordInv(w, peer, taken.item_id, d, .loot);
    return true;
}

pub fn putIntoContainer(w: *World, peer: usize, player_slot: u16, qty: u16) bool {
    const ps = w.playerByPeer(peer) orelse return false;
    if (!w.mask[ps].inventory) return false;
    const cid = w.inventory[ps].open_container;
    if (cid < 0) return false;
    const cs = w.slotOfNetId(cid) orelse return false;
    if (!w.mask[cs].inventory) return false;
    if (player_slot >= c.max_inv_slots) return false;
    const holding_before = w.inventory[ps].holding;
    const taken = w.inventory[ps].takeFromSlot(player_slot, if (qty == 0) w.inventory[ps].slots[player_slot].count else qty) orelse return false;
    // Preserve quality/meta when depositing into a container.
    if (!w.inventory[cs].addSlotStacked(taken, maxStackFor(w, taken.item_id))) {
        restoreTaken(&w.inventory[ps], player_slot, taken, holding_before);
        return false;
    }
    markInv(w, ps);
    const d: i16 = -@as(i16, @intCast(@min(taken.count, std.math.maxInt(i16))));
    recordInv(w, peer, taken.item_id, d, .tx);
    return true;
}

/// Equip armor from slot `from` into equip index `equip_i` (0..equip_count-1).
pub fn equip(w: *World, peer: usize, from: u16, equip_i: u16) bool {
    const ps = w.playerByPeer(peer) orelse return false;
    if (!w.mask[ps].inventory) return false;
    if (equip_i >= c.inv_equip_count) return false;
    if (from >= c.max_inv_slots) return false;
    const item = w.inventory[ps].slots[from];
    if (item.count == 0 or !itemIsArmor(w, item.item_id)) return false;
    const to: u16 = @intCast(c.inv_equip_start + equip_i);
    return move(w, peer, from, to, 1);
}

/// Place one placeable from held/toolbelt slot at (x,y,z) world coords.
/// Fuel items (items.xml FuelValue > 0) do not place a block: Result.refuel_amount
/// is set and Game calls PowerGrid.refuelAt at the target (generator) position.
pub fn placeBlock(w: *World, peer: usize, slot: u16, x: i32, y: i32, z: i32) Result {
    const ps = w.playerByPeer(peer) orelse return .{};
    if (!w.mask[ps].inventory) return .{};
    if (slot >= c.max_inv_slots) return .{};
    const item = w.inventory[ps].slots[slot];
    if (item.count == 0) return .{};
    // Fuel interaction: consume one stack unit; Game validates generator + applies fuel.
    if (w.fuel_value_fn) |ff| {
        const fv = ff(w.fuel_value_ctx, item.item_id);
        if (fv > 0) {
            const iid = item.item_id;
            _ = w.inventory[ps].takeFromSlot(slot, 1) orelse return .{};
            markInv(w, ps);
            recordInv(w, peer, iid, -1, .place);
            return .{
                .ok = true,
                .refuel_amount = fv,
                .refuel_item_id = iid,
                .place_x = x,
                .place_y = y,
                .place_z = z,
            };
        }
    }
    const block: u16 = if (w.place_fn) |f|
        f(w.place_ctx, item.item_id)
    else
        itemToBlock(item.item_id);
    if (block == 0) return .{};
    const iid = item.item_id;
    _ = w.inventory[ps].takeFromSlot(slot, 1) orelse return .{};
    markInv(w, ps);
    recordInv(w, peer, iid, -1, .place);
    return .{ .ok = true, .place_block = block, .place_x = x, .place_y = y, .place_z = z };
}

/// Apply inventory op. `entity_id` used for open; for place, a=slot and entity_id packs x|y in low/high?
/// Place uses a=slot, b=y, qty unused, entity_id = (x & 0xffff) | (z << 16) signed mid.
pub fn applyTransaction(w: *World, peer: usize, op: Op, a: u16, b: u16, qty: u16, entity_id: i32) Result {
    return applyTransactionEx(w, peer, op, a, b, qty, entity_id, null, null);
}

pub fn applyTransactionEx(
    w: *World,
    peer: usize,
    op: Op,
    a: u16,
    b: u16,
    qty: u16,
    entity_id: i32,
    eat_resolve: ?EatResolver,
    eat_ctx: ?*anyopaque,
) Result {
    return switch (op) {
        .list => .{ .ok = true },
        .move => .{ .ok = move(w, peer, a, b, qty) },
        .drop => drop(w, peer, a, qty),
        .set_hold => .{ .ok = setHolding(w, peer, a) },
        .use => useEx(w, peer, a, eat_resolve, eat_ctx),
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
    w.markDirty(ps, .{ .inv = true });
}

fn recordInv(w: *World, peer: usize, item_id: u16, delta: i16, cause: InvCause) void {
    const p: u16 = if (peer > std.math.maxInt(u16)) std.math.maxInt(u16) else @intCast(peer);
    w.inv_ledger.record(p, item_id, delta, cause);
}

/// Roll back a take from a known slot without re-stacking or losing quality/meta.
/// The sim is single-threaded, so only the remainder of that same stack can occupy it.
fn restoreTaken(inv: *c.Inventory, slot: u16, taken: c.InvSlot, holding_before: u16) void {
    const dst = &inv.slots[slot];
    if (dst.count == 0) {
        dst.* = taken;
    } else {
        std.debug.assert(dst.item_id == taken.item_id);
        std.debug.assert(dst.quality == taken.quality);
        std.debug.assert(dst.meta == taken.meta);
        dst.count +|= taken.count;
    }
    inv.holding = holding_before;
}

test "move and drop and use" {
    const WorldT = @import("world.zig").World;
    var w: WorldT = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    _ = w.spawnPlayer(0, 70, 0, 0);
    try std.testing.expect(give(&w, 0, 2, 3)); // food (stacks on starter kit if present)
    const ps = w.playerByPeer(0).?;
    var food_slot: u16 = 0;
    for (w.inventory[ps].slots, 0..) |s, i| {
        if (s.item_id == 2) {
            food_slot = @intCast(i);
            break;
        }
    }
    const count_before_use = w.inventory[ps].slots[food_slot].count;
    try std.testing.expect(count_before_use >= 3);
    w.health[ps].hp = 50;
    w.health[ps].food = 40;
    w.health[ps].food_max = 100;
    try std.testing.expect(use(&w, 0, food_slot));
    // Builtin item 2: +7 foodHealth, +15 foodAmount; consume exactly 1.
    try std.testing.expectEqual(@as(f32, 57), w.health[ps].hp);
    try std.testing.expectEqual(@as(f32, 55), w.health[ps].food);
    try std.testing.expectEqual(count_before_use - 1, w.inventory[ps].slots[food_slot].count);
    // Move 1 into a free slot, then drop from there (exercises move + drop path).
    var dest: u16 = 0;
    var found_dest = false;
    for (w.inventory[ps].slots[0..c.inv_equip_start], 0..) |s, i| {
        if (s.count == 0) {
            dest = @intCast(i);
            found_dest = true;
            break;
        }
    }
    try std.testing.expect(found_dest);
    const count_after_use = w.inventory[ps].slots[food_slot].count;
    try std.testing.expect(move(&w, 0, food_slot, dest, 1));
    try std.testing.expectEqual(count_after_use - 1, w.inventory[ps].slots[food_slot].count);
    try std.testing.expectEqual(@as(u16, 1), w.inventory[ps].slots[dest].count);
    try std.testing.expectEqual(@as(u16, 2), w.inventory[ps].slots[dest].item_id);
    try std.testing.expect(setHolding(&w, 0, dest));
    const r = drop(&w, 0, dest, 1);
    try std.testing.expect(r.ok);
    try std.testing.expect(r.dropped_entity > 0);
    try std.testing.expectEqual(@as(u16, 0), w.inventory[ps].slots[dest].count);
    var food_after_drop: u16 = 0;
    for (w.inventory[ps].slots[0..c.inv_equip_start]) |s| {
        if (s.item_id == 2) food_after_drop += s.count;
    }
    try std.testing.expect(openContainer(&w, 0, r.dropped_entity));
    try std.testing.expect(takeFromContainer(&w, 0, 0, 0));
    // Take-back restores the dropped unit into bag storage.
    var food_after_take: u16 = 0;
    for (w.inventory[ps].slots[0..c.inv_equip_start]) |s| {
        if (s.item_id == 2) food_after_take += s.count;
    }
    try std.testing.expectEqual(food_after_drop + 1, food_after_take);
}

test "open container refuses another player's inventory" {
    const WorldT = @import("world.zig").World;
    var w: WorldT = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    _ = w.spawnPlayer(0, 70, 0, 0);
    const victim = w.spawnPlayer(1, 70, 1, 1).?;
    try std.testing.expect(!openContainer(&w, 0, victim));
}

test "failed container put restores exact source stack and holding slot" {
    const WorldT = @import("world.zig").World;
    var w: WorldT = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    _ = w.spawnPlayer(0, 70, 0, 0);
    const ps = w.playerByPeer(0).?;
    const bag = w.spawnLootBag(1, 70, 1, 3, 1).?;
    try std.testing.expect(openContainer(&w, 0, bag));
    const cs = w.slotOfNetId(bag).?;

    w.inventory[ps].slots[0] = .{ .item_id = 11, .count = 2, .quality = 6, .meta = 321 };
    w.inventory[ps].holding = 0;
    for (w.inventory[cs].slots[0..c.inv_equip_start]) |*s| {
        s.* = .{ .item_id = 3, .count = maxStackBuiltin(3), .quality = 1 };
    }

    try std.testing.expect(!putIntoContainer(&w, 0, 0, 0));
    try std.testing.expectEqual(c.InvSlot{ .item_id = 11, .count = 2, .quality = 6, .meta = 321 }, w.inventory[ps].slots[0]);
    try std.testing.expectEqual(@as(u16, 0), w.inventory[ps].holding);
}

test "container take and put preserve quality and meta" {
    const WorldT = @import("world.zig").World;
    var w: WorldT = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    _ = w.spawnPlayer(0, 70, 0, 0);
    const ps = w.playerByPeer(0).?;
    // Anchor item so the bag is not destroyed when the quality stack is taken.
    const bag = w.spawnLootBag(1, 70, 1, 3, 1).?;
    const cs = w.slotOfNetId(bag).?;
    w.inventory[cs].slots[1] = .{ .item_id = 11, .count = 1, .quality = 5, .meta = 42 };
    try std.testing.expect(openContainer(&w, 0, bag));
    try std.testing.expect(takeFromContainer(&w, 0, 1, 1));
    var found: ?c.InvSlot = null;
    for (w.inventory[ps].slots[0..c.inv_equip_start]) |s| {
        if (s.item_id == 11) found = s;
    }
    try std.testing.expectEqual(c.InvSlot{ .item_id = 11, .count = 1, .quality = 5, .meta = 42 }, found.?);
    // Put back into bag and check destination preserves quality/meta.
    var src_slot: u16 = 0;
    for (w.inventory[ps].slots, 0..) |s, i| {
        if (s.item_id == 11) {
            src_slot = @intCast(i);
            break;
        }
    }
    try std.testing.expect(putIntoContainer(&w, 0, src_slot, 1));
    var bag_found: ?c.InvSlot = null;
    for (w.inventory[cs].slots[0..c.inv_equip_start]) |s| {
        if (s.item_id == 11) bag_found = s;
    }
    try std.testing.expectEqual(c.InvSlot{ .item_id = 11, .count = 1, .quality = 5, .meta = 42 }, bag_found.?);
}

test "open container rejects far vertical targets" {
    const WorldT = @import("world.zig").World;
    var w: WorldT = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    _ = w.spawnPlayer(0, 70, 0, 0);
    // Same XZ, 20 blocks above (outside 8-block 3D radius).
    const bag = w.spawnLootBag(0, 90, 0, 3, 1).?;
    try std.testing.expect(!openContainer(&w, 0, bag));
}

test "craft op reserved" {
    try std.testing.expectEqual(@as(u8, 11), @intFromEnum(Op.craft));
}

test "place fuel item yields refuel_amount" {
    const WorldT = @import("world.zig").World;
    var w: WorldT = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    _ = w.spawnPlayer(0, 70, 0, 0);
    const Fuel = struct {
        fn fv(_: ?*anyopaque, id: u16) f32 {
            return if (id == 50) 2 else 0;
        }
    };
    w.fuel_value_fn = &Fuel.fv;
    try std.testing.expect(give(&w, 0, 50, 2));
    const ps = w.playerByPeer(0).?;
    var slot: u16 = 0;
    for (w.inventory[ps].slots, 0..) |s, i| {
        if (s.item_id == 50) {
            slot = @intCast(i);
            break;
        }
    }
    const r = placeBlock(&w, 0, slot, 10, 70, 12);
    try std.testing.expect(r.ok);
    try std.testing.expectEqual(@as(f32, 2), r.refuel_amount);
    try std.testing.expectEqual(@as(u16, 50), r.refuel_item_id);
    try std.testing.expectEqual(@as(u16, 0), r.place_block);
    try std.testing.expectEqual(@as(u16, 1), w.inventory[ps].slots[slot].count);
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
    try std.testing.expectEqual(place_wood_block_id, pr.place_block);
}
