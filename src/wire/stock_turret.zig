//! Turret-sync body: entityId + target + isOn + None item value,
//! with the layout test.
//!
//! Split out of the packages.zig facade (same builder, same test);
//! import via `packages.stock_turret` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");

/// NetPackageTurretSync (read IL=20 / write IL=?): entityId i32,
/// targetEntityId i32, isOn bool, ItemValue (byte 0 = None; stock writes the
/// null-safe ItemValue for the turret's weapon). Broadcast by EntityTurret
/// when the target/on/weapon state changes (RE 2026-08-21); the client aims
/// the turret at the target and plays the fire state.
pub fn buildTurretSyncBody(buf: []u8, entity_id: i32, target_id: i32, is_on: bool) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeI32(target_id);
    try w.writeBool(is_on);
    try w.writeByte(0); // ItemValue.None (no weapon item in the zdtd sim)
    return w.written();
}

test "TurretSync body is entityId + target + isOn + None item value" {
    var buf: [32]u8 = undefined;
    const b = try buildTurretSyncBody(&buf, 300, 107, true);
    try std.testing.expectEqual(@as(usize, 4 + 4 + 1 + 1), b.len);
    try std.testing.expectEqual(@as(i32, 300), std.mem.readInt(i32, b[0..4], .little));
    try std.testing.expectEqual(@as(i32, 107), std.mem.readInt(i32, b[4..8], .little));
    try std.testing.expectEqual(@as(u8, 1), b[8]);
    try std.testing.expectEqual(@as(u8, 0), b[9]); // ItemValue.None
    const off = try buildTurretSyncBody(&buf, 301, -1, false);
    try std.testing.expectEqual(@as(u8, 0), off[8]);
}
