//! Look-at body: entityId + int-truncated look position with the
//! layout test.
//!
//! Split out of the packages.zig facade (same builder, same test);
//! import via `packages.stock_lookat` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");

/// NetPackageEntityLookAt (Assembly-CSharp NetPackageEntityLookAt::write,
/// IL=22): base NetPackageEntityTargeted entityId, then the look-at world
/// position as three int-truncated i32 (Vector3 conv.i4). GetLength()=16,
/// PackageDirection=ToClient. Sent to tracking players by
/// EntityAlive.SetLookPosition when the look moves past the 0.0016
/// sqr-delta gate (protocol-packages.md §5.2.1). Cosmetic head-aim only.
pub fn buildEntityLookAtBody(buf: []u8, entity_id: i32, lx: f32, ly: f32, lz: f32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeI32(@trunc(lx));
    try w.writeI32(@trunc(ly));
    try w.writeI32(@trunc(lz));
    return w.written();
}

test "EntityLookAt body is entityId + int-truncated look position" {
    var buf: [32]u8 = undefined;
    const b = try buildEntityLookAtBody(&buf, 107, 10.9, 70.2, -3.7);
    try std.testing.expectEqual(@as(usize, 16), b.len);
    try std.testing.expectEqual(@as(i32, 107), std.mem.readInt(i32, b[0..4], .little));
    try std.testing.expectEqual(@as(i32, 10), std.mem.readInt(i32, b[4..8], .little));
    try std.testing.expectEqual(@as(i32, 70), std.mem.readInt(i32, b[8..12], .little));
    try std.testing.expectEqual(@as(i32, -3), std.mem.readInt(i32, b[12..16], .little));
}
