//! Vehicle bodies: DataSync header parse and the native 13-byte control
//! parse/build.
//!
//! Split out of the packages.zig facade (same code, moved verbatim);
//! import via `packages.stock_vehicle` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");
const stock_inv = @import("stock_inv.zig");

/// Stock NetPackageVehicleDataSync header (asm.il:844254, read at asm.il:844340):
/// senderId i32 | vehicleId i32 | syncFlags u16 | dataLen u16 | data[dataLen].
/// The payload is an opaque EntityVehicle::ReadSyncData blob that zdtd relays
/// rather than decodes, so only the framing is validated here.
pub const VehicleDataSync = struct {
    sender_id: i32,
    vehicle_id: i32,
    sync_flags: u16,
    data: []const u8,
};

/// NetPackageVehicleDataSync (RE inventories/netpackage-bodies.md, write
/// IL=27): `senderId` i32 | `vehicleId` i32 | `syncFlags` u16 | `entityData`
/// length u16 + bytes.
pub fn parseVehicleDataSync(body: []const u8) !VehicleDataSync {
    if (body.len < 12) return error.EndOfStream;
    const data_len = std.mem.readInt(u16, body[10..12], .little);
    if (12 + @as(usize, data_len) > body.len) return error.EndOfStream;
    return .{
        .sender_id = std.mem.readInt(i32, body[0..4], .little),
        .vehicle_id = std.mem.readInt(i32, body[4..8], .little),
        .sync_flags = std.mem.readInt(u16, body[8..10], .little),
        .data = body[12 .. 12 + @as(usize, data_len)],
    };
}

/// One C2S NetPackageVehicleSpawn body (stock write IL=24): `entityType` i32 |
/// `pos` Vector3 | `rot` Vector3 | ItemValue | `entityThatPlaced` i32. The
/// client's `ItemActionSpawnVehicle.ExecuteAction` sends it when a placeable
/// vehicle item is used; stock's ProcessPackage spawns the entity with the
/// placer as owner when `VehicleManager.CanAddMoreVehicles()` holds, and drops
/// the item back otherwise.
pub const VehicleSpawnRequest = struct {
    entity_type: i32,
    x: f32,
    y: f32,
    z: f32,
    rx: f32,
    ry: f32,
    rz: f32,
    item: stock_inv.StockSlot,
    entity_that_placed: i32,
};

/// Smallest stock body: entityType 4 | pos 12 | rot 12 | ItemValue (>= 4) |
/// placer 4.
pub const vehicle_spawn_min_len: usize = 36;

/// NetPackageVehicleSpawn (stock write IL=24): `entityType` i32 | `pos`
/// Vector3 | `rot` Vector3 | ItemValue | `entityThatPlaced` i32.
pub fn parseVehicleSpawn(body: []const u8) !VehicleSpawnRequest {
    if (body.len < vehicle_spawn_min_len) return error.EndOfStream;
    var r: binary.Reader = .{ .data = body };
    const entity_type = try r.readI32();
    const x = try r.readF32();
    const y = try r.readF32();
    const z = try r.readF32();
    const rx = try r.readF32();
    const ry = try r.readF32();
    const rz = try r.readF32();
    const item = try stock_inv.readItemValue(&r);
    const placer = try r.readI32();
    return .{
        .entity_type = entity_type,
        .x = x,
        .y = y,
        .z = z,
        .rx = rx,
        .ry = ry,
        .rz = rz,
        .item = item,
        .entity_that_placed = placer,
    };
}

/// Native zdtd vehicle control (not a stock layout). Fixed 13 bytes so it can
/// never be confused with a stock body carrying the same package name.
pub const vehicle_control_len: usize = 13;

/// Vehicle control, **not a stock layout**: entity_id i32 | op u8 (0=enter,
/// 1=exit, 2=drive) | throttle f32 | steer f32, exactly `vehicle_control_len`
/// bytes. Stock has no C2S package of this shape; its vehicle placement rides
/// NetPackageVehicleSpawn (entityType i32 | pos | rot | ItemValue |
/// entityThatPlaced i32, RE inventories/netpackage-bodies.md). The dispatch in
/// c2s/misc.zig gates on the exact 13-byte length, so a stock body cannot be
/// decoded here; it falls through unhandled, since zdtd does not implement
/// client-requested vehicle spawning (docs/DIVERGENCES.md).
pub fn parseVehicleControl(body: []const u8) !struct { entity_id: i32, op: u8, throttle: f32, steer: f32 } {
    if (body.len < 5) return error.EndOfStream;
    const eid = std.mem.readInt(i32, body[0..4], .little);
    const op = body[4];
    var throttle: f32 = 0;
    var steer: f32 = 0;
    if (body.len >= 13) {
        throttle = @bitCast(std.mem.readInt(u32, body[5..9], .little));
        steer = @bitCast(std.mem.readInt(u32, body[9..13], .little));
        if (!std.math.isFinite(throttle) or !std.math.isFinite(steer)) return error.Overflow;
    }
    return .{ .entity_id = eid, .op = op, .throttle = throttle, .steer = steer };
}

/// zdtd's own vehicle control body, **not a stock layout**: entityId i32 | op u8
/// | throttle f32 | steer f32, fixed at vehicle_control_len bytes. Stock's
/// NetPackageVehicleSpawn (RE write IL=24) is entityType i32 | pos Vector3 |
/// rot Vector3 | ItemValue | entityThatPlaced i32, which is a different shape
/// and a different purpose. The C2S handler distinguishes them by the exact
/// 13-byte length, so a real stock body can never be read as this one.
pub fn buildVehicleControlBody(buf: []u8, entity_id: i32, op: u8, throttle: f32, steer: f32) ![]u8 {
    if (buf.len < 13) return error.Overflow;
    std.mem.writeInt(i32, buf[0..4], entity_id, .little);
    buf[4] = op;
    std.mem.writeInt(u32, buf[5..9], @as(u32, @bitCast(throttle)), .little);
    std.mem.writeInt(u32, buf[9..13], @as(u32, @bitCast(steer)), .little);
    return buf[0..13];
}

test "vehicle data sync header framing" {
    // senderId | vehicleId | syncFlags | dataLen | data
    var body: [16]u8 = .{ 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 4, 0, 9, 8, 7, 6 };
    const s = try parseVehicleDataSync(&body);
    try std.testing.expectEqual(@as(i32, 1), s.sender_id);
    try std.testing.expectEqual(@as(i32, 2), s.vehicle_id);
    try std.testing.expectEqual(@as(u16, 3), s.sync_flags);
    try std.testing.expectEqualSlices(u8, &.{ 9, 8, 7, 6 }, s.data);
    // A truncated payload must never hand out bytes past the body.
    try std.testing.expectError(error.EndOfStream, parseVehicleDataSync(body[0..15]));
    try std.testing.expectError(error.EndOfStream, parseVehicleDataSync(body[0..11]));
    // Empty payload is legal framing.
    const empty = try parseVehicleDataSync(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(usize, 0), empty.data.len);
}
