//! Animation + relay bodies: ragdoll invoke, animation data, laser
//! sight, and the variable-length relay framing, with their tests.
//!
//! Split out of the packages.zig facade (same code, same tests);
//! import via `packages.stock_anim` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");
const buildSoundAtPosition = @import("stock_chat.zig").buildSoundAtPosition;
const max_audio_clip_len: usize = @import("stock_chat.zig").max_audio_clip_len;
const parseSoundAtPosition = @import("stock_chat.zig").parseSoundAtPosition;

/// Stock `NetPackageEntityRagdoll` (write IL=59): entityId i32, flags u8,
/// then conditionally (flags&1) duration f32, bodyPart i16, forceVec 3xf32,
/// forceWorldPos 3xf32, hipPos 3xf32, (flags&2) mode u8, (flags&4) state u8.
/// The sender is the entity's owner (EntityBuffs / EModelBase.DoRagdoll
/// force the local ragdoll); the server applies it and re-broadcasts via
/// NetEntityDistribution.SendPacketToTrackedPlayersAndTrackedEntity, so a
/// verbatim relay to the other clients matches the intent (the owner already
/// ragdolled locally).
/// `AnimParamData/ValueTypes` (AnimParamData_ValueTypes.il.txt:3). The value
/// width follows the type: Bool and Trigger read a bool, Float and DataFloat a
/// f32, Int an i32 (`CreateFromBinary` switch, AnimParamData.il.txt:62).
pub const anim_param_bool: u8 = 0;
pub const anim_param_trigger: u8 = 1;
pub const anim_param_float: u8 = 2;
pub const anim_param_int: u8 = 3;
pub const anim_param_data_float: u8 = 4;

/// `NetPackageEntityAnimationData::read` (IL=22,
/// NetPackageEntityAnimationData.il.txt:58): the `NetPackageEntityTargeted`
/// base `entityId` i32, a count i32, then that many `AnimParamData` entries of
/// `hash` i32 + `type` u8 + a type-sized value. An unknown type throws in
/// stock ("Invalid Value Type:", :82), so it is a parse error here too.
///
/// Only the id and the consumed length are returned: the parameters are an
/// opaque client animation list the server does not act on, but the length is
/// what lets the relay trim instead of forwarding appended bytes.
pub const AnimationData = struct {
    entity_id: i32 = 0,
    param_count: i32 = 0,
    wire_len: usize = 0,
};

/// Read side of the layout above (stock
/// `NetPackageEntityAnimationData::read` IL=22,
/// NetPackageEntityAnimationData.il.txt:58, over the
/// `NetPackageEntityTargeted::read` base and `AnimParamData::CreateFromBinary`
/// at AnimParamData.il.txt:54).
pub fn parseAnimationData(body: []const u8) binary.ReadError!AnimationData {
    var r: binary.Reader = .{ .data = body };
    var out: AnimationData = .{ .entity_id = try r.readI32() };
    out.param_count = try r.readI32();
    if (out.param_count < 0) return error.EndOfStream;
    var i: i32 = 0;
    while (i < out.param_count) : (i += 1) {
        _ = try r.readI32(); // parameter name hash
        switch (try r.readByte()) {
            anim_param_bool, anim_param_trigger => _ = try r.readBool(),
            anim_param_float, anim_param_data_float => _ = try r.readF32(),
            anim_param_int => _ = try r.readI32(),
            else => return error.EndOfStream, // stock throws on an unknown type
        }
    }
    out.wire_len = r.pos;
    return out;
}

test "animation data parses the typed parameter list" {
    var buf: [64]u8 = undefined;
    var w: binary.Writer = .{ .buf = &buf };
    try w.writeI32(107);
    try w.writeI32(3);
    try w.writeI32(0x1111);
    try w.writeByte(anim_param_bool);
    try w.writeBool(true);
    try w.writeI32(0x2222);
    try w.writeByte(anim_param_float);
    try w.writeF32(1.5);
    try w.writeI32(0x3333);
    try w.writeByte(anim_param_int);
    try w.writeI32(-9);
    const got = try parseAnimationData(w.written());
    try std.testing.expectEqual(@as(i32, 107), got.entity_id);
    try std.testing.expectEqual(@as(i32, 3), got.param_count);
    // 4 id + 4 count + bool(4+1+1) + float(4+1+4) + int(4+1+4) = 32
    try std.testing.expectEqual(@as(usize, 32), got.wire_len);
    try std.testing.expectEqual(w.written().len, got.wire_len);

    // Trailing bytes do not extend the parsed length.
    var padded: [96]u8 = undefined;
    const n = w.written().len;
    @memcpy(padded[0..n], w.written());
    @memset(padded[n..][0..5], 0x5a);
    try std.testing.expectEqual(n, (try parseAnimationData(padded[0 .. n + 5])).wire_len);

    // An unknown value type is a parse error, as it is in stock.
    var bad: [16]u8 = undefined;
    var bw: binary.Writer = .{ .buf = &bad };
    try bw.writeI32(107);
    try bw.writeI32(1);
    try bw.writeI32(0x4444);
    try bw.writeByte(9);
    try std.testing.expectError(error.EndOfStream, parseAnimationData(bw.written()));
}

pub const RagdollInvoke = struct {
    entity_id: i32,
    flags: u8,
    /// End of the stock body. The flag-gated tails make the length variable,
    /// so a relay must forward `body[0..wire_len]` and not the raw slice.
    wire_len: usize = 0,
};

/// NetPackagePlayerLaserSight (read IL=16): entityId i32 | laserSightActive
/// bool | laserSightPosition Vector3 **only when active** (the read branches
/// on the flag at IL_001E, so an inactive body is 5 bytes, not 17). Stock's
/// ProcessPackage (IL=70) re-sends the body from the server to every client
/// except the sender's own entity, so a player sees a mate's laser dot.
pub const LaserSight = struct {
    entity_id: i32,
    active: bool,
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    /// End of the stock body; the length is variable, so a relay must trim to
    /// it rather than forward the raw slice.
    wire_len: usize = 0,
};

/// Read side of NetPackagePlayerLaserSight (read IL=16), laid out on
/// `LaserSight` above. Server-side the body is relayed, so nothing past the
/// ownership check reads the position fields.
pub fn parseLaserSight(body: []const u8) binary.ReadError!LaserSight {
    var r: binary.Reader = .{ .data = body };
    var out: LaserSight = .{
        .entity_id = try r.readI32(),
        .active = try r.readBool(),
    };
    if (out.active) {
        out.x = try r.readF32();
        out.y = try r.readF32();
        out.z = try r.readF32();
    }
    out.wire_len = r.pos;
    return out;
}

/// Read side of NetPackageEntityRagdoll, whose layout and conditional tails are
/// documented on RagdollInvoke above (RE protocol-packages.md, write IL=59).
/// Only `entityId` and `flags` are returned; the flagged tails are consumed so
/// a truncated body still errors, but the server relays the bytes verbatim
/// rather than acting on the force vectors.
pub fn parseRagdollInvoke(body: []const u8) binary.ReadError!RagdollInvoke {
    var r: binary.Reader = .{ .data = body };
    const entity_id = try r.readI32();
    const flags = try r.readByte();
    if ((flags & 1) != 0) {
        _ = try r.readF32(); // duration
        _ = try r.readI16(); // bodyPart
        var i: usize = 0;
        while (i < 3) : (i += 1) _ = try r.readF32();
        i = 0;
        while (i < 3) : (i += 1) _ = try r.readF32();
        i = 0;
        while (i < 3) : (i += 1) _ = try r.readF32();
    }
    if ((flags & 2) != 0) _ = try r.readByte(); // mode
    if ((flags & 4) != 0) _ = try r.readByte(); // state
    return .{ .entity_id = entity_id, .flags = flags, .wire_len = r.pos };
}

test "laser sight position is conditional on the active flag" {
    // An inactive body is 5 bytes: stock's read branches on the flag, so
    // demanding the Vector3 rejected every laser-off packet as malformed and
    // the off transition never reached the other clients.
    var off_buf: [8]u8 = undefined;
    var ow: binary.Writer = .{ .buf = &off_buf };
    try ow.writeI32(107);
    try ow.writeBool(false);
    const off = try parseLaserSight(ow.written());
    try std.testing.expectEqual(@as(i32, 107), off.entity_id);
    try std.testing.expect(!off.active);
    try std.testing.expectEqual(@as(usize, 5), off.wire_len);

    var on_buf: [32]u8 = undefined;
    var w: binary.Writer = .{ .buf = &on_buf };
    try w.writeI32(107);
    try w.writeBool(true);
    try w.writeF32(1.5);
    try w.writeF32(2.5);
    try w.writeF32(3.5);
    const on = try parseLaserSight(w.written());
    try std.testing.expect(on.active);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), on.y, 0.001);
    try std.testing.expectEqual(@as(usize, 17), on.wire_len);

    // A truncated active body is still an error, not a short read.
    try std.testing.expectError(error.EndOfStream, parseLaserSight(on_buf[0..9]));
}

test "ragdoll invoke parses the stock body" {
    var body: [128]u8 = undefined;
    var w: binary.Writer = .{ .buf = &body };
    try w.writeI32(77); // entityId
    try w.writeByte(0x07); // flags: duration+mode+state
    try w.writeF32(1.5); // duration
    try w.writeI16(2); // bodyPart
    try w.writeF32(1);
    try w.writeF32(2);
    try w.writeF32(3);
    try w.writeF32(4);
    try w.writeF32(5);
    try w.writeF32(6);
    try w.writeF32(7);
    try w.writeF32(8);
    try w.writeF32(9);
    try w.writeByte(1); // mode
    try w.writeByte(0); // state
    const r = try parseRagdollInvoke(w.written());
    try std.testing.expectEqual(@as(i32, 77), r.entity_id);
    try std.testing.expectEqual(@as(u8, 0x07), r.flags);
    // wire_len is where the stock body ends, so a relay can trim whatever a
    // peer appended instead of fanning it out.
    try std.testing.expectEqual(w.written().len, r.wire_len);

    // A flags=0 body stops right after the flags byte, and trailing bytes do
    // not extend it.
    var short: [32]u8 = undefined;
    var sw: binary.Writer = .{ .buf = &short };
    try sw.writeI32(77);
    try sw.writeByte(0);
    try sw.writeBytes(&[_]u8{ 0xde, 0xad, 0xbe, 0xef });
    const r2 = try parseRagdollInvoke(sw.written());
    try std.testing.expectEqual(@as(usize, 5), r2.wire_len);
    try std.testing.expect(r2.wire_len < sw.written().len);
}

test "variable-length relay bodies report where the stock body ends" {
    // SoundAtPosition and ParticleEffect both carry client-sized strings, so
    // body.len is not the stock length: a raw relay forwards appended bytes.
    var buf: [128]u8 = undefined;
    const snd = try buildSoundAtPosition(&buf, .{
        .pos = .{ 1, 2, 3 },
        .clip = blk: {
            var c: [max_audio_clip_len]u8 = .{0} ** max_audio_clip_len;
            @memcpy(c[0..4], "boom");
            break :blk c;
        },
        .clip_len = 4,
        .mode = 1,
        .distance = 30,
        .entity_id = 107,
    });
    const exact = try parseSoundAtPosition(snd);
    try std.testing.expectEqual(snd.len, exact.wire_len);

    var padded: [160]u8 = undefined;
    @memcpy(padded[0..snd.len], snd);
    @memset(padded[snd.len..][0..8], 0xaa);
    const trailing = try parseSoundAtPosition(padded[0 .. snd.len + 8]);
    try std.testing.expectEqual(snd.len, trailing.wire_len);
    try std.testing.expectEqual(@as(i32, 107), trailing.entity_id);
}
