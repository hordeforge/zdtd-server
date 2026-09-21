//! Explosion body: the client explosion broadcast with the layout test.
//!
//! Split out of the packages.zig facade (same builder, same test);
//! import via `packages.stock_explosion` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");

/// NetPackageExplosionClient (RE protocol-packages.md 6.15 + write IL=60):
/// `center` Vector3 | `rotation` Quaternion | `expType` i16 | `blastPower` u16 |
/// `blastRadius` u16 | `blockDamage` u16 | `entityId` i32 | `changeCount` u16,
/// then changeCount x BlockChangeInfo. zdtd emits the FX with an empty change
/// list: block results already ride the authoritative SetBlock path, so
/// repeating them here would apply them twice on the client.
pub fn buildExplosionClient(
    buf: []u8,
    cx: f32,
    cy: f32,
    cz: f32,
    exp_type: i16,
    blast_power: u16,
    blast_radius: u16,
    block_damage: u16,
    entity_id: i32,
) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeF32(cx);
    try w.writeF32(cy);
    try w.writeF32(cz);
    // Quaternion identity (x,y,z,w)
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(1);
    try w.writeI16(exp_type);
    try w.writeU16(blast_power);
    try w.writeU16(blast_radius);
    try w.writeU16(block_damage);
    try w.writeI32(entity_id);
    try w.writeU16(0); // explosionChanges count
    return w.written();
}

test "explosion client body layout" {
    // No test covered this builder. It is pos Vector3 | identity quaternion |
    // type i16 | blastPower u16 | blastRadius u16 | blockDamage u16 |
    // entityId i32 | changes count u16, and the three u16 in a row are the
    // part a swap moves without changing the length.
    var buf: [64]u8 = undefined;
    const body = try buildExplosionClient(&buf, 11, 12, 13, 3, 21, 22, 23, 106);
    try std.testing.expectEqual(@as(usize, 12 + 16 + 2 + 6 + 4 + 2), body.len);
    const f32At = struct {
        fn get(b: []const u8, off: usize) f32 {
            return @bitCast(std.mem.readInt(u32, b[off..][0..4], .little));
        }
    }.get;
    try std.testing.expectEqual(@as(f32, 11), f32At(body, 0));
    try std.testing.expectEqual(@as(f32, 12), f32At(body, 4));
    try std.testing.expectEqual(@as(f32, 13), f32At(body, 8));
    // Identity quaternion: three zeros then w = 1.
    try std.testing.expectEqual(@as(f32, 0), f32At(body, 12));
    try std.testing.expectEqual(@as(f32, 1), f32At(body, 24));
    try std.testing.expectEqual(@as(i16, 3), std.mem.readInt(i16, body[28..30], .little));
    try std.testing.expectEqual(@as(u16, 21), std.mem.readInt(u16, body[30..32], .little)); // blastPower
    try std.testing.expectEqual(@as(u16, 22), std.mem.readInt(u16, body[32..34], .little)); // blastRadius
    try std.testing.expectEqual(@as(u16, 23), std.mem.readInt(u16, body[34..36], .little)); // blockDamage
    try std.testing.expectEqual(@as(i32, 106), std.mem.readInt(i32, body[36..40], .little));
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, body[40..42], .little));
}
