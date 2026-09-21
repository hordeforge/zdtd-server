//! Claim + marker bodies: land-claim repair parse/build, map-object
//! type enum, and the map-marker + nav-object builders with the marker
//! test.
//!
//! Split out of the packages.zig facade (same code, same test);
//! import via `packages.stock_claim` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");

/// Read side of NetPackageLandClaimRepair (docs/wire/PACKAGES.md, extracted
/// read `ReadInt64;ReadInt64;ReadInt64;ReadBoolean;`): the block position
/// arrives as three i64, then `beginRepair` bool. Each coordinate is narrowed
/// to i32 and a value that does not fit is an error, since no world position
/// needs the wider type and a forged one would wrap into a valid-looking block.
pub fn parseLandClaimRepair(body: []const u8) !struct { x: i32, y: i32, z: i32, begin_repair: bool } {
    if (body.len < 25) return error.EndOfStream;
    var r: binary.Reader = .{ .data = body };
    const x = std.math.cast(i32, try r.readI64()) orelse return error.EndOfStream;
    const y = std.math.cast(i32, try r.readI64()) orelse return error.EndOfStream;
    const z = std.math.cast(i32, try r.readI64()) orelse return error.EndOfStream;
    const begin = try r.readBool();
    return .{ .x = x, .y = y, .z = z, .begin_repair = begin };
}

/// Write side of NetPackageLandClaimRepair (write IL=26): blockPosition as
/// three i64, then `beginRepair` bool. The server emits the end-repair form
/// (`Setup(blockPos, false)`) to the requester when the repair pass finishes
/// (TEFeatureAreaRepair repair coroutine IL_0337), clearing its IsRepairing.
pub fn buildLandClaimRepairBody(buf: []u8, x: i32, y: i32, z: i32, begin_repair: bool) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI64(x);
    try w.writeI64(y);
    try w.writeI64(z);
    try w.writeBool(begin_repair);
    return w.written();
}

/// `EnumMapObjectType` values used by the marker-removal package. The enum has
/// 18 entries (RE map-objects.md 90); only the ones zdtd removes are named here,
/// so an unused value cannot be cited as if it were verified.
pub const MapObjectType = enum(i32) {
    sleeping_bag = 1,
    supply_drop = 13,
    land_claim = 15,
};

/// `removeByType` selector: the entity id and the position are mutually
/// exclusive on the wire (RE protocol-packages.md 1735).
pub const map_marker_remove_by_entity: i32 = 0;
pub const map_marker_remove_by_position: i32 = 1;

/// NetPackageEntityMapMarkerRemove keyed by entity id (write IL=24, RE
/// protocol-packages.md 1735): `removeByType` i32 = 0 | `entityId` i32 |
/// `mapObjectType` i32. The client's `World.ObjectOnMapRemove` drops the marker.
pub fn buildMapMarkerRemoveByEntity(buf: []u8, entity_id: i32, object_type: MapObjectType) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(map_marker_remove_by_entity);
    try w.writeI32(entity_id);
    try w.writeI32(@intFromEnum(object_type));
    return w.written();
}

/// NetPackageEntityMapMarkerRemove keyed by position (same write IL=24, RE
/// protocol-packages.md 1735): `removeByType` i32 = 1 | `position` Vector3
/// (3 x f32) | `mapObjectType` i32. The two key forms are mutually exclusive.
/// Used where the marker belongs to something that is not an entity, which is
/// how stock removes a land-claim marker (`NetPackageEntityMapMarkerRemove(
/// EnumMapObjectType.LandClaim = 15, pos)`, RE server-lifecycle.md:292).
pub fn buildMapMarkerRemoveByPosition(buf: []u8, x: f32, y: f32, z: f32, object_type: MapObjectType) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(map_marker_remove_by_position);
    try w.writeF32(x);
    try w.writeF32(y);
    try w.writeF32(z);
    try w.writeI32(@intFromEnum(object_type));
    return w.written();
}

test "map marker remove body layout, both key forms" {
    // The two key forms are mutually exclusive on the wire: reading a
    // position-keyed body as an id-keyed one would take the first coordinate
    // word as an entity id and then run off the end.
    var buf: [32]u8 = undefined;
    const by_id = try buildMapMarkerRemoveByEntity(&buf, 106, .supply_drop);
    var r: binary.Reader = .{ .data = by_id };
    try std.testing.expectEqual(map_marker_remove_by_entity, try r.readI32());
    try std.testing.expectEqual(@as(i32, 106), try r.readI32());
    try std.testing.expectEqual(@as(i32, 13), try r.readI32());
    try std.testing.expectEqual(@as(usize, 0), r.remaining());

    var buf2: [32]u8 = undefined;
    const by_pos = try buildMapMarkerRemoveByPosition(&buf2, 10, 64, -20, .land_claim);
    var r2: binary.Reader = .{ .data = by_pos };
    try std.testing.expectEqual(map_marker_remove_by_position, try r2.readI32());
    try std.testing.expectEqual(@as(f32, 10), try r2.readF32());
    try std.testing.expectEqual(@as(f32, 64), try r2.readF32());
    try std.testing.expectEqual(@as(f32, -20), try r2.readF32());
    try std.testing.expectEqual(@as(i32, 15), try r2.readI32());
    try std.testing.expectEqual(@as(usize, 0), r2.remaining());
}
