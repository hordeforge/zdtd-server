//! Velocity body: EntityVelocity build with the stock [-8, 8] clamp
//! and the layout test.
//!
//! Split out of the packages.zig facade (same builder, same test);
//! import via `packages.stock_velocity` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");

/// NetPackageEntityVelocity (write IL=23): entityId i32, bAdd bool, motion
/// f32 x3, clamped to [-8, 8] per axis at Setup (protocol-packages.md §5.5.5).
/// The one builder for this package: the replication path
/// (NetEntityDistributionEntry) sends live motion and the C2S hit-shove path
/// sends knockback, both through here so every peer sees the stock clamp.
pub fn buildEntityVelocityBody(buf: []u8, entity_id: i32, b_add: bool, vx: f32, vy: f32, vz: f32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeBool(b_add);
    try w.writeF32(std.math.clamp(vx, -8.0, 8.0));
    try w.writeF32(std.math.clamp(vy, -8.0, 8.0));
    try w.writeF32(std.math.clamp(vz, -8.0, 8.0));
    return w.written();
}

test "EntityVelocity body is entityId + bAdd + clamped motion" {
    var buf: [32]u8 = undefined;
    const b = try buildEntityVelocityBody(&buf, 107, false, 0, -5.5, 99.0);
    try std.testing.expectEqual(@as(usize, 4 + 1 + 12), b.len);
    try std.testing.expectEqual(@as(i32, 107), std.mem.readInt(i32, b[0..4], .little));
    try std.testing.expectEqual(@as(u8, 0), b[4]); // bAdd false
    try std.testing.expectEqual(@as(f32, 0.0), @as(f32, @bitCast(std.mem.readInt(u32, b[5..9], .little))));
    try std.testing.expectEqual(@as(f32, -5.5), @as(f32, @bitCast(std.mem.readInt(u32, b[9..13], .little))));
    try std.testing.expectEqual(@as(f32, 8.0), @as(f32, @bitCast(std.mem.readInt(u32, b[13..17], .little)))); // clamped
    const add = try buildEntityVelocityBody(&buf, 1, true, 1, 0, 0);
    try std.testing.expectEqual(@as(u8, 1), add[4]);
}
