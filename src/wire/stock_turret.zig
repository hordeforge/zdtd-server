//! Turret-sync body: entityId + target + isOn + the turret's item value,
//! with the layout test. A deployed turret's magazine rides that item value's
//! Meta (`EntityTurret.get_AmmoCount`), so the sync is what tells the client
//! how many rounds the turret has left; `None` is the no-item case.
//!
//! Split out of the packages.zig facade (same builder, same test);
//! import via `packages.stock_turret` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");
const stock_inv = @import("stock_inv.zig");

/// NetPackageTurretSync (read IL=20 / write IL=?): entityId i32,
/// targetEntityId i32, isOn bool, ItemValue (byte 0 = None; stock writes the
/// null-safe ItemValue for the turret's weapon). Broadcast by EntityTurret
/// when the target/on/weapon state changes (RE 2026-08-21); the client aims
/// the turret at the target and plays the fire state.
pub fn buildTurretSyncBody(buf: []u8, entity_id: i32, target_id: i32, is_on: bool, item: ?stock_inv.StockSlot) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeI32(target_id);
    try w.writeBool(is_on);
    if (item) |iv| {
        try stock_inv.writeItemValue(&w, iv);
    } else {
        try w.writeByte(0); // ItemValue.None (no deployed item)
    }
    return w.written();
}

test "TurretSync body is entityId + target + isOn + None item value" {
    var buf: [32]u8 = undefined;
    const b = try buildTurretSyncBody(&buf, 300, 107, true, null);
    try std.testing.expectEqual(@as(usize, 4 + 4 + 1 + 1), b.len);
    try std.testing.expectEqual(@as(i32, 300), std.mem.readInt(i32, b[0..4], .little));
    try std.testing.expectEqual(@as(i32, 107), std.mem.readInt(i32, b[4..8], .little));
    try std.testing.expectEqual(@as(u8, 1), b[8]);
    try std.testing.expectEqual(@as(u8, 0), b[9]); // ItemValue.None
    const off = try buildTurretSyncBody(&buf, 301, -1, false, null);
    try std.testing.expectEqual(@as(u8, 0), off[8]);

    // A deployed item rides the sync with `ammo` as its Meta, which is where
    // the client's turret UI reads the magazine from.
    const with_item = try buildTurretSyncBody(&buf, 302, 55, true, .{
        .type_id = 1000,
        .count = 1,
        .quality = 2,
        .meta = 12,
    });
    try std.testing.expect(with_item.len > 10);
    try std.testing.expectEqual(@as(i32, 302), std.mem.readInt(i32, with_item[0..4], .little));
    var r: binary.Reader = .{ .data = with_item, .pos = 9 };
    const iv = try stock_inv.readItemValue(&r);
    try std.testing.expectEqual(@as(i32, 1000), iv.type_id);
    try std.testing.expectEqual(@as(u16, 12), iv.meta);
    try std.testing.expectEqual(@as(u16, 2), iv.quality);
}
