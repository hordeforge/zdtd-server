//! Horde-event body: event byte + pos + maxDist with the layout test.
//!
//! Split out of the packages.zig facade (same builder, same test);
//! import via `packages.stock_horde` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");

/// AIDirector/HordeEvent enum (Assembly-CSharp AIDirector/HordeEvent). Client
/// EntityPlayerLocal.HandleHordeEvent reacts to warn2 (spawn-warning audio) and
/// spawn (camera shake + spawn audio); none/warn1 are no-ops.
pub const HordeEvent = enum(u8) {
    none = 0,
    warn1 = 1,
    warn2 = 2,
    spawn = 3,
};

/// NetPackageHordeEvent (Assembly-CSharp NetPackageHordeEvent::write): after the base
/// NetPackage header the payload is Write((uint8)m_event), Write(m_pos.x/y/z f32),
/// Write(m_maxDist f32) = 17 bytes. ProcessPackage gates on distance: fires
/// HandleHordeEvent(m_event) only if (localPlayerPos - m_pos).sqrMagnitude <= m_maxDist^2,
/// so m_pos at origin with a large m_maxDist reaches every receiving client.
/// NOTE: stock server has NO sender for this package; the wire format and client handler
/// are real but the package is vestigial over the network through V3.1.0 b14. Emitting it is
/// non-stock behavior (see docs/GAP_ANALYSIS.md).
pub fn buildHordeEventBody(buf: []u8, event: HordeEvent, x: f32, y: f32, z: f32, max_dist: f32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeByte(@intFromEnum(event));
    try w.writeF32(x);
    try w.writeF32(y);
    try w.writeF32(z);
    try w.writeF32(max_dist);
    return w.written();
}

test "HordeEvent body is event byte + pos + maxDist (17 bytes)" {
    var buf: [24]u8 = undefined;
    const body = try buildHordeEventBody(&buf, .spawn, 1.5, -2.0, 3.25, 4096.0);
    try std.testing.expectEqual(@as(usize, 17), body.len);
    try std.testing.expectEqual(@as(u8, 3), body[0]);
    const fx: f32 = @bitCast(std.mem.readInt(u32, body[1..5], .little));
    const fy: f32 = @bitCast(std.mem.readInt(u32, body[5..9], .little));
    const fz: f32 = @bitCast(std.mem.readInt(u32, body[9..13], .little));
    const fd: f32 = @bitCast(std.mem.readInt(u32, body[13..17], .little));
    try std.testing.expectEqual(@as(f32, 1.5), fx);
    try std.testing.expectEqual(@as(f32, -2.0), fy);
    try std.testing.expectEqual(@as(f32, 3.25), fz);
    try std.testing.expectEqual(@as(f32, 4096.0), fd);
}
