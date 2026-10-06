//! Stock drone companion wire bodies (S2C).
//!
//! `NetPackageDroneDataSync` (`write` IL=27) and
//! `NetPackageDroneParticleEffect` (`write` IL=12), grounded in
//! `../../7dtd-engine-research/docs/inventories/netpackage-bodies.md`. Both
//! are server-to-client: the server owns the drone's state and fans it out.
//!
//! Non-goals: the drone state machine (src/ecs/drone_state.zig) and the
//! steering layer (raycast-pathing.md 6b).

const std = @import("std");
const binary = @import("binary.zig");

/// `NetPackageDroneDataSync.write` (IL=27): `senderId:i32, vehicleId:i32,
/// syncFlags:u16, entityData:u16 count` then that many bytes of
/// `VehicleDataSync` payload (the drone's entity data blob).
pub fn buildDroneDataSyncBody(buf: []u8, sender_id: i32, vehicle_id: i32, sync_flags: u16, entity_data: []const u8) ![]u8 {
    var w = binary.Writer{ .buf = buf };
    try w.writeI32(sender_id);
    try w.writeI32(vehicle_id);
    try w.writeU16(sync_flags);
    try w.writeU16(@intCast(entity_data.len));
    try w.writeBytes(entity_data);
    return w.written();
}

/// `NetPackageDroneParticleEffect.write` (IL=12): `pe:ParticleEffect.Write`
/// then `entityThatCausedIt:i32`. `pe` is the particle-effect frame the
/// client renders; the server passes it through as the encoded body.
pub fn buildDroneParticleEffectBody(buf: []u8, particle_effect: []const u8, entity_that_caused_it: i32) ![]u8 {
    var w = binary.Writer{ .buf = buf };
    try w.writeBytes(particle_effect);
    try w.writeI32(entity_that_caused_it);
    return w.written();
}

test "drone data sync body matches NetPackageDroneDataSync.write" {
    var buf: [64]u8 = undefined;
    const body = try buildDroneDataSyncBody(&buf, 7, 11, 3, &[_]u8{ 0xAA, 0xBB, 0xCC });
    // senderId:i32, vehicleId:i32, syncFlags:u16, count:u16, then the payload.
    try std.testing.expectEqual(@as(usize, 4 + 4 + 2 + 2 + 3), body.len);
    try std.testing.expectEqual(@as(i32, 7), std.mem.readInt(i32, body[0..4], .little));
    try std.testing.expectEqual(@as(i32, 11), std.mem.readInt(i32, body[4..8], .little));
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, body[8..10], .little));
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, body[10..12], .little));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB, 0xCC }, body[12..15]);
}

test "drone particle effect body matches NetPackageDroneParticleEffect.write" {
    var buf: [64]u8 = undefined;
    const body = try buildDroneParticleEffectBody(&buf, &[_]u8{ 1, 2, 3, 4 }, 42);
    try std.testing.expectEqual(@as(usize, 4 + 4), body.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, body[0..4]);
    try std.testing.expectEqual(@as(i32, 42), std.mem.readInt(i32, body[4..8], .little));
}
