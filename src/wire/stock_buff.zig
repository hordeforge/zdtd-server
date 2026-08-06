//! Stock buff wire (V3.1.0 b14): NetPackageAddRemoveBuff body and the
//! EntityBuffs blob carried by NetPackageEntityStatsBuff and PlayerDataFile.buffData.
//! Codec only, no server state. Field order comes from the client IL, never from
//! this encoder: encode and decode share the file, so a wrong order round-trips.

const std = @import("std");
const binary = @import("binary.zig");

/// EntityBuffs::Version (asm.il 738343). v3 is the only version we emit;
/// v2 wrote updateTicks as a byte and had no instigatorPos (asm.il 733631).
pub const entity_buffs_version: u8 = 3;

/// Longest buff name accepted off the wire. Stock names are catalog keys
/// (buffs.xml `name`), the longest in V3.1.0 is well under this.
pub const max_buff_name: usize = 64;

/// BuffValue/BuffFlags bit values (asm.il 733040). Same bit order as
/// ecs/components.BuffFlags, which is what callers @bitCast into `flags`.
pub const flag_started: u8 = 0x01;
pub const flag_finished: u8 = 0x02;
pub const flag_remove: u8 = 0x04;
pub const flag_update: u8 = 0x08;
pub const flag_invalid: u8 = 0x10;
pub const flag_paused: u8 = 0x20;

/// One BuffValue as it appears inside the EntityBuffs blob (asm.il 733588).
pub const BuffValueWire = struct {
    name: []const u8,
    /// BuffValue::.ctor starts this at 1 (asm.il 733486), not 0.
    stack_mult: u8 = 1,
    duration_ticks: u32 = 0,
    instigator_id: i32 = -1,
    flags: u8 = 0,
    update_ticks: u16 = 0,
    instigator_x: i32 = 0,
    instigator_y: i32 = 0,
    instigator_z: i32 = 0,
};

/// BuffValue::Write (asm.il 733588): string, u8, u32, i32, u8, u16, Vector3i.
pub fn writeBuffValue(w: *binary.Writer, v: BuffValueWire) !void {
    try w.writeString(v.name);
    try w.writeByte(v.stack_mult);
    try w.writeU32(v.duration_ticks);
    try w.writeI32(v.instigator_id);
    try w.writeByte(v.flags);
    try w.writeU16(v.update_ticks);
    try w.writeI32(v.instigator_x);
    try w.writeI32(v.instigator_y);
    try w.writeI32(v.instigator_z);
}

/// EntityBuffs::Write (asm.il 737940): u8 Version, u16 count, values,
/// u16 cvar count, (string, f32) pairs. We hold no cvars (the client runs the
/// triggered_effect graph locally), so the cvar section is always empty.
pub fn writeEntityBuffs(buf: []u8, values: []const BuffValueWire) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeByte(entity_buffs_version);
    try w.writeU16(@intCast(values.len));
    for (values) |v| try writeBuffValue(&w, v);
    try w.writeU16(0);
    return w.written();
}

/// NetPackageEntityStatsBuff body (asm.il 202222): i32 entityId, i32 len, bytes.
/// Unreliable in stock (get_ReliableDelivery false, asm.il 202144) and applied
/// only to remote entities (asm.il 202268), so it never drives the local player.
pub fn buildEntityStatsBuffBody(buf: []u8, entity_id: i32, blob: []const u8) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeI32(@intCast(blob.len));
    try w.writeBytes(blob);
    return w.written();
}

/// NetPackageAddRemoveBuff (asm.il 202415). Reliable (inherits NetPackage
/// get_ReliableDelivery) and the only S2C path that touches a client's own
/// buffs (ProcessPackage asm.il 202531 applies to any EntityAlive).
pub const AddRemoveBuff = struct {
    entity_id: i32,
    /// Slice into the caller's name buffer.
    name: []const u8,
    /// -1 means "use the client's own BuffClass duration". Any value >= 0 calls
    /// BuffClass::set_DurationMax (asm.il 736259 IL_00cf / IL_0246), which
    /// retunes the SHARED BuffClass for every entity on that client for the rest
    /// of the session. The server always sends -1.
    duration: f32,
    adding: bool,
    instigator_id: i32,
    instigator_x: i32,
    instigator_y: i32,
    instigator_z: i32,
};

/// write() at asm.il 202497: i32, string, f32, bool, i32, Vector3i.
pub fn buildAddRemoveBuffBody(buf: []u8, v: AddRemoveBuff) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(v.entity_id);
    try w.writeString(v.name);
    try w.writeF32(v.duration);
    try w.writeBool(v.adding);
    try w.writeI32(v.instigator_id);
    try w.writeI32(v.instigator_x);
    try w.writeI32(v.instigator_y);
    try w.writeI32(v.instigator_z);
    return w.written();
}

/// read() at asm.il 202464. `name_buf` receives the buff name; the returned
/// slice borrows it. Untrusted input: every field is bounds-checked and the
/// name length is capped by the caller's buffer.
pub fn parseAddRemoveBuff(body: []const u8, name_buf: []u8) !AddRemoveBuff {
    var r: binary.Reader = .{ .data = body };
    const entity_id = try r.readI32();
    const name = try r.readString(name_buf);
    const duration = try r.readF32();
    const adding = try r.readBool();
    const instigator_id = try r.readI32();
    return .{
        .entity_id = entity_id,
        .name = name,
        .duration = duration,
        .adding = adding,
        .instigator_id = instigator_id,
        .instigator_x = try r.readI32(),
        .instigator_y = try r.readI32(),
        .instigator_z = try r.readI32(),
    };
}

test "AddRemoveBuff body matches the stock write field order" {
    var buf: [64]u8 = undefined;
    const body = try buildAddRemoveBuffBody(&buf, .{
        .entity_id = 171,
        .name = "buffShocked",
        .duration = -1,
        .adding = true,
        .instigator_id = 200,
        .instigator_x = 1,
        .instigator_y = -2,
        .instigator_z = 3,
    });
    // Hand-built from asm.il 202497, not from the encoder above.
    const expect = [_]u8{
        0xAB, 0x00, 0x00, 0x00, // entityId 171
        11, 'b', 'u', 'f', 'f', 'S', 'h', 'o', 'c', 'k', 'e', 'd', // 7-bit len + name
        0x00, 0x00, 0x80, 0xBF, // duration -1.0f
        0x01, // adding
        0xC8, 0x00, 0x00, 0x00, // instigatorId 200
        0x01, 0x00, 0x00, 0x00, // instigatorPos.x
        0xFE, 0xFF, 0xFF, 0xFF, // instigatorPos.y
        0x03, 0x00, 0x00, 0x00, // instigatorPos.z
    };
    try std.testing.expectEqualSlices(u8, &expect, body);

    var nbuf: [max_buff_name]u8 = undefined;
    const back = try parseAddRemoveBuff(body, &nbuf);
    try std.testing.expectEqual(@as(i32, 171), back.entity_id);
    try std.testing.expectEqualStrings("buffShocked", back.name);
    try std.testing.expectEqual(@as(f32, -1), back.duration);
    try std.testing.expect(back.adding);
    try std.testing.expectEqual(@as(i32, 200), back.instigator_id);
    try std.testing.expectEqual(@as(i32, -2), back.instigator_y);
}

test "EntityBuffs blob matches the stock write field order" {
    var buf: [128]u8 = undefined;
    const blob = try writeEntityBuffs(&buf, &.{.{
        .name = "buffIsOnFire",
        .stack_mult = 2,
        .duration_ticks = 0x0102,
        .instigator_id = -1,
        .flags = flag_started,
        .update_ticks = 7,
        .instigator_x = 0,
        .instigator_y = 64,
        .instigator_z = 0,
    }});
    // Hand-built from asm.il 737940 (header) + 733588 (value).
    const expect = [_]u8{
        3, // EntityBuffs::Version
        0x01, 0x00, // ActiveBuffs.Count
        12,   'b',
        'u',  'f',
        'f',  'I',
        's',  'O',
        'n',  'F',
        'i',  'r',
        'e',
        0x02, // stackEffectMultiplier
        0x02, 0x01, 0x00, 0x00, // durationTicks
        0xFF, 0xFF, 0xFF, 0xFF, // instigatorId
        0x01, // buffFlags (Started)
        0x07, 0x00, // updateTicks
        0x00, 0x00, 0x00, 0x00, // instigatorPos.x
        0x40, 0x00, 0x00, 0x00, // instigatorPos.y
        0x00, 0x00, 0x00, 0x00, // instigatorPos.z
        0x00, 0x00, // cvar count
    };
    try std.testing.expectEqualSlices(u8, &expect, blob);
}

test "empty EntityBuffs blob is version + two zero counts" {
    var buf: [16]u8 = undefined;
    const blob = try writeEntityBuffs(&buf, &.{});
    try std.testing.expectEqualSlices(u8, &[_]u8{ 3, 0, 0, 0, 0 }, blob);

    var body_buf: [32]u8 = undefined;
    const body = try buildEntityStatsBuffBody(&body_buf, 171, blob);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0xAB, 0x00, 0x00, 0x00, // entityId
        0x05, 0x00, 0x00, 0x00, // blob length
        3,    0,    0,    0,
        0,
    }, body);
}

test "parseAddRemoveBuff rejects truncated and oversized input" {
    var nbuf: [max_buff_name]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, parseAddRemoveBuff(&.{}, &nbuf));
    // Full body minus one byte of the trailing Vector3i.
    var buf: [64]u8 = undefined;
    const body = try buildAddRemoveBuffBody(&buf, .{
        .entity_id = 1,
        .name = "buffIsOnFire",
        .duration = -1,
        .adding = false,
        .instigator_id = -1,
        .instigator_x = 0,
        .instigator_y = 0,
        .instigator_z = 0,
    });
    try std.testing.expectError(error.EndOfStream, parseAddRemoveBuff(body[0 .. body.len - 1], &nbuf));
    // A name longer than the caller's buffer must not overflow it.
    var tiny: [4]u8 = undefined;
    try std.testing.expectError(error.Overflow, parseAddRemoveBuff(body, &tiny));
}
