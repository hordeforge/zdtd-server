//! Stock inventory apply: PlayerInventory body into ECS.
//!
//! Split out of wire/stock_inv.zig (same code, moved verbatim).

const std = @import("std");
const binary = @import("binary.zig");
const components = @import("../ecs/components.zig");
const stock_inv = @import("stock_inv.zig");
const readItemValue = stock_inv.readItemValue;
const StockSlot = stock_inv.StockSlot;
const items_start_here = stock_inv.items_start_here;
const ReverseResolver = stock_inv.ReverseResolver;
const toolbelt_slots = stock_inv.toolbelt_slots;
const readItemStackList = stock_inv.readItemStackList;
const toEcs = stock_inv.toEcs;
const readItemStack = stock_inv.readItemStack;
const skipPackedBoolArray = stock_inv.skipPackedBoolArray;
const skipPreferenceTracker = stock_inv.skipPreferenceTracker;

/// Parse stock NetPackagePlayerInventory body and apply present sections into ECS Inventory.
/// reverse maps absolute stock type → ecs item_id (0 = empty/unknown skipped as empty).
pub fn applyPlayerInventoryBody(
    body: []const u8,
    inv: *components.Inventory,
    reverse: ?ReverseResolver,
    ctx: ?*anyopaque,
) binary.ReadError!void {
    var r: binary.Reader = .{ .data = body };

    const has_tb = try r.readBool();
    if (has_tb) {
        var slots: [toolbelt_slots]StockSlot = [_]StockSlot{.{}} ** toolbelt_slots;
        const n = try readItemStackList(&r, slots[0..]);
        var i: usize = 0;
        while (i < toolbelt_slots) : (i += 1) {
            if (i < n) {
                inv.slots[i] = toEcs(slots[i], reverse, ctx);
            } else {
                inv.slots[i] = .{};
            }
        }
    }

    const has_bag = try r.readBool();
    if (has_bag) {
        // Bag.Write: version byte, u16 count, stacks, locked?, touched?, prefs?
        const bag_ver = try r.readByte();
        const bag_n = try r.readU16();
        var i: usize = 0;
        while (i < bag_n) : (i += 1) {
            const s = try readItemStack(&r);
            if (i < components.inv_bag_count) {
                inv.slots[components.inv_bag_start + i] = toEcs(s, reverse, ctx);
            }
        }
        // clear remaining bag slots if client sent shorter bag
        while (i < components.inv_bag_count) : (i += 1) {
            inv.slots[components.inv_bag_start + i] = .{};
        }
        const has_locked = try r.readBool();
        if (has_locked) {
            // PackedBoolArray: skip best-effort (length-prefixed bits). Read count if present.
            // Stock PackedBoolArray.Read: typically length then bytes. Skip remaining carefully:
            // For empty lock array Write is only false bool; when true, Read reconstructs.
            // Minimal: if stream has u16 length then that many bits packed.
            // Use versioned bag path: after locks, version>=1 has touched + prefs.
            _ = try skipPackedBoolArray(&r);
        }
        if (bag_ver >= 1) {
            _ = try r.readBool(); // touched
            const has_prefs = try r.readBool();
            if (has_prefs) {
                // PreferenceTracker.Write: playerId:i32 + optional toolbelt/equip/bag stacks.
                // Skip fully so equipment/drag sections after bag still parse.
                try skipPreferenceTracker(&r);
            }
        }
    }

    const has_eq = try r.readBool();
    if (has_eq) {
        const eq_n = try r.readU16();
        var i: usize = 0;
        while (i < eq_n) : (i += 1) {
            const present = try r.readBool();
            var s: StockSlot = .{};
            if (present) s = try readItemValue(&r);
            if (i < components.inv_equip_count) {
                inv.slots[components.inv_equip_start + i] = toEcs(s, reverse, ctx);
            }
        }
        // cosmetic i32 per eq slot + unlocked list
        var ci: usize = 0;
        while (ci < eq_n) : (ci += 1) _ = try r.readI32();
        const unlocked = try r.readI32();
        var ui: i32 = 0;
        while (ui < unlocked) : (ui += 1) _ = try r.readI32();
    }

    const has_drag = try r.readBool();
    if (has_drag) {
        // GameUtils.ReadItemStack: count + stacks; first is drag
        var drag_slots: [1]StockSlot = .{.{}};
        _ = try readItemStackList(&r, drag_slots[0..]);
        // ECS has no drag slot; ignore contents but parse for stream correctness.
    }
}
