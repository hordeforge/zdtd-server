//! Apply parsed wire inventory / TE bodies into ECS and world stores.
//!
//! Parse stays in `wire/stock_*.zig` (BinaryReader layouts). Mutation of
//! `components.Inventory` and `containers.Container` lives here so package
//! builders never own sim writes.

const std = @import("std");
const binary = @import("../wire/binary.zig");
const stock_inv = @import("../wire/stock_inv.zig");
const stock_te = @import("../wire/stock_te.zig");
const components = @import("../ecs/components.zig");
const containers = @import("../world/containers.zig");

/// Apply NetPackageBag body into inventory bag (player_bag_only) or full slots.
pub fn applyBagPackage(
    body: []const u8,
    inv: *components.Inventory,
    reverse: ?stock_inv.ReverseResolver,
    ctx: ?*anyopaque,
    player_bag_only: bool,
) binary.ReadError!i32 {
    var r: binary.Reader = .{ .data = body };
    const entity_id = try r.readI32();
    const blob_len = try r.readU16();
    if (r.remaining() < blob_len) return error.EndOfStream;
    const blob = r.data[r.pos .. r.pos + blob_len];
    r.pos += blob_len;

    var br: binary.Reader = .{ .data = blob };
    const bag_ver = try br.readByte();
    const bag_n = try br.readU16();

    if (player_bag_only) {
        var i: usize = 0;
        while (i < bag_n) : (i += 1) {
            const s = try stock_inv.readItemStack(&br);
            if (i < components.inv_bag_count) {
                inv.slots[components.inv_bag_start + i] = stock_inv.toEcs(s, reverse, ctx);
            }
        }
        while (i < components.inv_bag_count) : (i += 1) {
            inv.slots[components.inv_bag_start + i] = .{};
        }
    } else {
        // Loot: clear all, fill from start
        inv.clear();
        var i: usize = 0;
        while (i < bag_n) : (i += 1) {
            const s = try stock_inv.readItemStack(&br);
            if (i < components.max_inv_slots) {
                inv.slots[i] = stock_inv.toEcs(s, reverse, ctx);
            }
        }
    }

    const has_locked = try br.readBool();
    if (has_locked) try stock_inv.skipPackedBoolArray(&br);
    if (bag_ver >= 1 and br.remaining() >= 1) {
        _ = try br.readBool(); // touched
        if (br.remaining() >= 1) {
            const has_prefs = try br.readBool();
            _ = has_prefs;
        }
    }
    return entity_id;
}

/// Apply a standalone Equipment.Write body into the ECS equipment range.
/// Returns the number of bytes consumed so a relay can trim to the stock body.
pub fn applyEquipmentBody(
    body: []const u8,
    inv: *components.Inventory,
    reverse: ?stock_inv.ReverseResolver,
    ctx: ?*anyopaque,
) binary.ReadError!usize {
    var r: binary.Reader = .{ .data = body };
    const version = try r.readByte();
    const eq_n: usize = if (version <= 2) 5 else if (version == 3) 8 else stock_inv.equipment_slots;
    var i: usize = 0;
    while (i < eq_n) : (i += 1) {
        // ReadOrNull: the ItemValue's own version byte doubles as the presence
        // marker, so an empty slot is one `0` byte.
        const s = try stock_inv.readItemValue(&r);
        if (i < components.inv_equip_count) {
            inv.slots[components.inv_equip_start + i] = stock_inv.toEcs(s, reverse, ctx);
        }
    }
    // The cosmetic + unlock tail only exists from version 2 on
    // (Equipment.il.txt:1711, `blt` past it when version < 2).
    if (version >= 2) {
        var ci: usize = 0;
        while (ci < eq_n) : (ci += 1) _ = try r.readI32();
        const unlocked = try r.readI32();
        var ui: i32 = 0;
        while (ui < unlocked) : (ui += 1) _ = try r.readI32();
    }
    return r.pos;
}

/// Apply parsed TE loot items into a container store entry.
pub fn applyParsedToContainer(
    parsed: *const stock_te.ParsedTe,
    cont: *containers.Container,
    reverse: ?stock_inv.ReverseResolver,
    ctx: ?*anyopaque,
) void {
    const n = if (parsed.size_x > 0 and parsed.size_y > 0)
        @min(@as(usize, parsed.size_x) * @as(usize, parsed.size_y), containers.max_container_slots)
    else
        @min(parsed.item_count, containers.max_container_slots);
    // Geometry only grows: a client-declared smaller grid must not make the
    // container's tail slots unaddressable (and drop them from the save).
    cont.slot_count = @intCast(@max(@as(usize, cont.slot_count), n));
    cont.block_id = parsed.block_id;
    cont.clear();
    var i: usize = 0;
    while (i < parsed.item_count and i < cont.slot_count) : (i += 1) {
        const s = parsed.items[i];
        if (s.type_id == 0 or s.count == 0) continue;
        const item_id: u16 = if (reverse) |rv| rv(ctx, s.type_id) else blk: {
            if (s.type_id > stock_inv.items_start_here) {
                const rel = s.type_id - stock_inv.items_start_here;
                if (rel > 0 and rel < 100) break :blk @as(u16, @intCast(rel));
            }
            break :blk 0;
        };
        if (item_id == 0) continue;
        cont.setSlot(i, .{
            .item_id = item_id,
            .count = s.count,
            .quality = @min(s.quality, 255),
            .meta = s.meta,
        });
    }
}

fn testRevItemId(_: ?*anyopaque, st: i32) u16 {
    if (st >= stock_inv.items_start_here) {
        const rel = st - stock_inv.items_start_here;
        if (rel > 0 and rel < 100) return @intCast(rel);
    }
    return 0;
}

test "bag package roundtrip player bag slots" {
    var buf: [8192]u8 = undefined;
    var inv: components.Inventory = .{};
    inv.slots[10] = .{ .item_id = 7, .count = 15, .quality = 1 };
    inv.slots[11] = .{ .item_id = 3, .count = 30, .quality = 1 };
    const body = try stock_inv.buildBagPackage(&buf, 42, &inv, null, null, true);
    var inv2: components.Inventory = .{};
    const eid = try applyBagPackage(body, &inv2, testRevItemId, null, true);
    try std.testing.expectEqual(@as(i32, 42), eid);
    try std.testing.expectEqual(@as(u16, 7), inv2.slots[10].item_id);
    try std.testing.expectEqual(@as(u16, 15), inv2.slots[10].count);
    try std.testing.expectEqual(@as(u16, 3), inv2.slots[11].item_id);

    // Bag.Write closes with three bools: no LockedSlots, touched, no
    // PreferenceTracker. Only the slots were read back, so a swap among those
    // three went unnoticed - and the outer two are both false, which is why
    // the middle one has to be true here to be observable at all. Layout:
    // entityId i32 | blobLen u16 | version u8 | count u16 | N x ItemStack.
    const tail = body[body.len - 3 ..];
    try std.testing.expectEqual(@as(u8, 0), tail[0]); // LockedSlots absent
    try std.testing.expectEqual(@as(u8, 1), tail[1]); // touched
    try std.testing.expectEqual(@as(u8, 0), tail[2]); // PreferenceTracker absent
}

test "applyEquipmentBody parses the standalone equipment body" {
    // Equipment::Write (Equipment.il.txt:1594): version 4 | 12 x
    // ItemValue::Write, where a null slot is the bare `0` byte its own version
    // field would carry | 12 x cosmetic i32 | i32 unlocked | unlocked x i32.
    var buf: [1024]u8 = undefined;
    var w = binary.Writer{ .buf = &buf };
    try w.writeByte(4); // Equipment version -> 12 slots
    for (0..12) |i| {
        if (i == 2) {
            // Absolute stock type (items_start_here + relative); fallbackEcsId
            // maps it back to the relative ECS id.
            try stock_inv.writeItemValue(&w, .{ .type_id = stock_inv.items_start_here + 5, .count = 1 });
        } else {
            try w.writeByte(0); // null ItemValue
        }
    }
    for (0..12) |_| try w.writeI32(0); // cosmetics
    try w.writeI32(0); // unlocked count
    var inv: components.Inventory = .{};
    const used = try applyEquipmentBody(w.written(), &inv, null, null);
    try std.testing.expectEqual(@as(u16, 5), inv.slots[components.inv_equip_start + 2].item_id);
    try std.testing.expectEqual(@as(u16, 0), inv.slots[components.inv_equip_start + 0].item_id);
    try std.testing.expectEqual(@as(u16, 0), inv.slots[components.inv_equip_start + 11].item_id);
    // The whole body is consumed, so a relay can trim to it.
    try std.testing.expectEqual(w.written().len, used);

    // Trailing bytes do not extend the parsed length.
    var padded: [1024]u8 = undefined;
    const n = w.written().len;
    @memcpy(padded[0..n], w.written());
    @memset(padded[n..][0..6], 0xcc);
    var inv2: components.Inventory = .{};
    try std.testing.expectEqual(n, try applyEquipmentBody(padded[0 .. n + 6], &inv2, null, null));
}
