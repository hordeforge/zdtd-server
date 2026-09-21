//! Remove bodies: entity-remove with reason byte and the layout test.
//!
//! Split out of the packages.zig facade (same builders, same test);
//! import via `packages.stock_remove` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");

/// Stock EnumRemoveEntityReason: Undef=0 Unloaded=1 Killed=2 Despawned=3 Captured=4.
pub const RemoveEntityReason = enum(u8) {
    undef = 0,
    unloaded = 1,
    killed = 2,
    despawned = 3,
    captured = 4,
};

/// NetPackageEntityRemove: entityId:i32 | reason:u8 (EnumRemoveEntityReason).
pub fn buildRemoveBody(buf: []u8, entity_id: i32) ![]u8 {
    return buildRemoveBodyReason(buf, entity_id, .killed);
}

/// NetPackageEntityRemove (RE protocol-packages.md, write IL=8): the
/// EntityTargeted base `entityId` i32, then `reason` u8
/// (EnumRemoveEntityReason). The body-inventory table lists only `reason`,
/// since it shows fields after the base.
pub fn buildRemoveBodyReason(buf: []u8, entity_id: i32, reason: RemoveEntityReason) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeByte(@intFromEnum(reason));
    return w.written();
}

test "EntityRemove body is entityId + reason byte" {
    var buf: [8]u8 = undefined;
    const body = try buildRemoveBody(&buf, 100);
    try std.testing.expectEqual(@as(usize, 5), body.len);
    try std.testing.expectEqual(@as(i32, 100), std.mem.readInt(i32, body[0..4], .little));
    try std.testing.expectEqual(@as(u8, 2), body[4]); // Killed
    const u = try buildRemoveBodyReason(&buf, 50, .unloaded);
    try std.testing.expectEqual(@as(u8, 1), u[4]);
}
