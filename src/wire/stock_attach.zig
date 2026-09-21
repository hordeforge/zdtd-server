//! Attach bodies: EntityAttach build/parse plus the detach predicate.
//!
//! Split out of the packages.zig facade (same code, moved verbatim);
//! the layout tests stay in the facade where the suite already
//! exercises them through these names.
//! import via `packages.stock_attach` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");

pub const AttachType = enum(u8) {
    attach_server = 0,
    attach_client = 1,
    detach_server = 2,
    detach_client = 3,
};

/// "Any free seat" on the wire. The stock client mounts with -1 and detaches
/// with vehicleId = -1 / slot = -1 (asm.il:541872, asm.il:406816).
pub const slot_any: i16 = -1;

/// NetPackageEntityAttach (RE inventories/netpackage-bodies.md, write IL=21):
/// `attachType` u8 | `riderId` i32 | `vehicleId` i32 | `slot` i16. Slot is an
/// int32 in memory but conv.i2 on the wire (asm.il:844620).
pub fn buildEntityAttach(buf: []u8, attach_type: AttachType, rider_id: i32, vehicle_id: i32, slot: i16) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeByte(@intFromEnum(attach_type));
    try w.writeI32(rider_id);
    try w.writeI32(vehicle_id);
    try w.writeI16(slot);
    return w.written();
}

/// Read side of NetPackageEntityAttach (RE inventories/netpackage-bodies.md,
/// write IL=21): `attachType` u8 | `riderId` i32 | `vehicleId` i32 | `slot`
/// i16, the order buildEntityAttach writes. An `attachType` outside the four
/// stock values is rejected rather than clamped: stock switches on it, so a
/// fifth value has no defined meaning and guessing one would attach or detach
/// on a byte the client never meant as either.
pub fn parseEntityAttach(body: []const u8) !struct { attach_type: AttachType, rider_id: i32, vehicle_id: i32, slot: i16 } {
    if (body.len < 11) return error.EndOfStream;
    const at_raw = body[0];
    const at = std.enums.fromInt(AttachType, at_raw) orelse return error.InvalidEvent;
    return .{
        .attach_type = at,
        .rider_id = std.mem.readInt(i32, body[1..5], .little),
        .vehicle_id = std.mem.readInt(i32, body[5..9], .little),
        .slot = std.mem.readInt(i16, body[9..11], .little),
    };
}

pub fn attachTypeIsDetach(t: AttachType) bool {
    return t == .detach_server or t == .detach_client;
}
