//! Stock inventory apply: PlayerInventory body into ECS (V3.3.0 b18).
//!
//! The b10 inline containers (`bool + ItemStack[]` / `Bag.Read` / `ItemValue[]`)
//! are replaced by three `bool present + blob` sections (protocol-packages.md
//! §1.5.4). Each blob is `StreamUtils.WriteBlob` framed (`i32 len | bytes`) and
//! wraps a versioned container record whose body is an `ItemStackGrid`; the
//! drag item stays a bare `ItemStack`. Applied present sections land in the ECS
//! Inventory; an absent section leaves the server's current state (the client
//! only pushes the containers it owns).

const std = @import("std");
const binary = @import("binary.zig");
const components = @import("../ecs/components.zig");
const stock_inv = @import("stock_inv.zig");
const StockSlot = stock_inv.StockSlot;
const ReverseResolver = stock_inv.ReverseResolver;
const toolbelt_slots = stock_inv.toolbelt_slots;
const toEcs = stock_inv.toEcs;
const readItemStack = stock_inv.readItemStack;
const readBlob = stock_inv.readBlob;
const readItemStackGrid = stock_inv.readItemStackGrid;

/// Parse a stock NetPackagePlayerInventory body (b18 blob form) and apply
/// present sections into the ECS Inventory. `reverse` maps absolute stock type
/// to ecs item_id (0 = empty/unknown, skipped as empty).
pub fn applyPlayerInventoryBody(
    body: []const u8,
    inv: *components.Inventory,
    reverse: ?ReverseResolver,
    ctx: ?*anyopaque,
) binary.ReadError!void {
    var r: binary.Reader = .{ .data = body };
    var scratch: [16384]u8 = undefined;

    // inventoryData: bool + blob(Inventory.Write = ver 1 | grid | selectedSlot)
    const has_inv = try r.readBool();
    if (has_inv) {
        const n = try readBlob(&r, scratch[0..]);
        if (n > 0) {
            var br: binary.Reader = .{ .data = scratch[0..n] };
            const ver = try br.readByte();
            if (ver == 1) {
                var slots: [toolbelt_slots]StockSlot = @splat(.{});
                _ = try readItemStackGrid(&br, slots[0..]);
                for (slots, 0..) |s, i| inv.slots[i] = toEcs(s, reverse, ctx);
            }
            // version mismatch: fail closed, leaving the section untouched.
        }
    }

    // bagData: bool + blob(Bag.Write = ver 2 | grid)
    const has_bag = try r.readBool();
    if (has_bag) {
        const n = try readBlob(&r, scratch[0..]);
        if (n > 0) {
            var br: binary.Reader = .{ .data = scratch[0..n] };
            const ver = try br.readByte();
            if (ver == 2) {
                var slots: [components.inv_bag_count]StockSlot = @splat(.{});
                _ = try readItemStackGrid(&br, slots[0..]);
                for (slots, 0..) |s, i| {
                    if (i < components.inv_bag_count) {
                        inv.slots[components.inv_bag_start + i] = toEcs(s, reverse, ctx);
                    }
                }
            }
        }
    }

    // equipmentData: bool + blob(Equipment.Write = ver 6 | grid | cosmetics |
    // unlocked list)
    const has_eq = try r.readBool();
    if (has_eq) {
        const n = try readBlob(&r, scratch[0..]);
        if (n > 0) {
            var br: binary.Reader = .{ .data = scratch[0..n] };
            const ver = try br.readByte();
            if (ver == 6) {
                var slots: [components.inv_equip_count]StockSlot = @splat(.{});
                _ = try readItemStackGrid(&br, slots[0..]);
                for (slots, 0..) |s, i| {
                    if (i < components.inv_equip_count) {
                        inv.slots[components.inv_equip_start + i] = toEcs(s, reverse, ctx);
                    }
                }
                // cosmetics: one i32 per grid slot, then unlocked count + ids.
                const eq_n = @min(slots.len, components.inv_equip_count);
                var ci: usize = 0;
                while (ci < eq_n) : (ci += 1) _ = try br.readI32();
                const unlocked = try br.readI32();
                var ui: i32 = 0;
                while (ui < unlocked) : (ui += 1) _ = try br.readI32();
            }
        }
    }

    // dragAndDropItem: bool + one bare ItemStack (no ECS drag slot; consumed
    // so the reader stays aligned if a future field follows).
    const has_drag = try r.readBool();
    if (has_drag) _ = try readItemStack(&r);
}
