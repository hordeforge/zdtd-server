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

/// `AnimParamData.type` tags, from the stock enum
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

/// `Animator.StringToHash` (UnityEngine.AnimationModule internalcall): the
/// reflected CRC-32 of the parameter name - seed 0xFFFFFFFF, per byte
/// `h = (h >> 1 >> 7) ^ (0xEDB88320 & -(h & 1))`-style table step, return
/// `~h`. RE chain (entity-ai.md 2026-09-22): managed internalcall in
/// `UnityEngine.AnimationModule.dll`, native leaf at
/// `UnityPlayer.so +0xc26c90` seeded with -1 and complemented by its caller,
/// runtime table at `+0x1dedaf0` compared row-for-row against the standard
/// table, and a live stock-dedi capture returning
/// `StringToHash("Attack") = 0x406c280d`, exactly `zlib.crc32("Attack")`.
/// `AnimParamData.hash` carries these values; a wrong hash is a silent
/// client no-op, so this is an RE-pinned constant class (AGENTS rule 15:
/// Unity hashes from stock names).
pub fn animatorStringHash(comptime name: []const u8) i32 {
    var crc: u32 = 0xffff_ffff;
    for (name) |b| {
        crc ^= b;
        var k: u32 = 0;
        while (k < 8) : (k += 1) {
            crc = if (crc & 1 == 1) (crc >> 1) ^ 0xedb8_8320 else crc >> 1;
        }
    }
    return @bitCast(~crc);
}

/// The AvatarController.StaticInit constants an AI strike flush writes
/// (`AvatarZombieController::StartAnimationAttack`: `_setInt(Attack, variant)`,
/// `_setFloat(AttackBlend, ...)`, `_setTrigger(AttackTrigger)`).
pub const attack_param_hash: i32 = animatorStringHash("Attack");
pub const attack_blend_hash: i32 = animatorStringHash("AttackBlend");
pub const attack_trigger_hash: i32 = animatorStringHash("AttackTrigger");

/// One `AnimParamData` entry for the write side: the type selects which
/// value field is serialized, mirroring `parseAnimationData`.
pub const AnimParam = struct {
    hash: i32,
    kind: u8,
    int: i32 = 0,
    float: f32 = 0,
    boolean: bool = false,
};

/// Write side of the layout read by `parseAnimationData` (stock
/// `NetPackageEntityAnimationData::write` over the `NetPackageEntityTargeted`
/// base): `entityId` i32, count i32, then `hash` i32 + type u8 + typed value.
pub fn buildEntityAnimationDataBody(buf: []u8, entity_id: i32, params: []const AnimParam) error{Overflow}![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeI32(@intCast(params.len));
    for (params) |p| {
        try w.writeI32(p.hash);
        try w.writeByte(p.kind);
        switch (p.kind) {
            anim_param_bool, anim_param_trigger => try w.writeBool(p.boolean),
            anim_param_float, anim_param_data_float => try w.writeF32(p.float),
            anim_param_int => try w.writeI32(p.int),
            // Stock read throws on an unknown type; the builder only emits
            // the known kinds, so an unknown one is a local coding error.
            else => unreachable,
        }
    }
    return w.written();
}

test "animatorStringHash matches the live-pinned CRC-32 constants" {
    // Live stock-dedi capture (entity-ai.md 2026-09-22):
    // StringToHash("Attack") = 0x406c280d = zlib.crc32("Attack").
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x406c_280d))), attack_param_hash);
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x46fe_600d))), attack_blend_hash);
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x9828_122b))), attack_trigger_hash);
}

test "entity animation data builds the typed strike list" {
    var buf: [64]u8 = undefined;
    const params = [_]AnimParam{
        .{ .hash = attack_param_hash, .kind = anim_param_int, .int = 0 },
        .{ .hash = attack_blend_hash, .kind = anim_param_float, .float = 0.5 },
        .{ .hash = attack_trigger_hash, .kind = anim_param_trigger, .boolean = true },
    };
    const body = try buildEntityAnimationDataBody(&buf, 107, &params);
    // Two i32 header words plus 4+1+4 (int), 4+1+4 (float), 4+1+1 (trigger).
    try std.testing.expectEqual(@as(usize, 32), body.len);
    const back = try parseAnimationData(body);
    try std.testing.expectEqual(@as(i32, 107), back.entity_id);
    try std.testing.expectEqual(@as(i32, 3), back.param_count);
    try std.testing.expectEqual(body.len, back.wire_len);
    try std.testing.expectEqual(attack_param_hash, std.mem.readInt(i32, body[8..12], .little));
    try std.testing.expectEqual(@as(u8, anim_param_int), body[12]);
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

/// Stock `NetPackageEntityRagdoll` (write IL=59): entityId i32, flags u8,
/// then conditionally (flags&1) duration f32, bodyPart i16, forceVec 3xf32,
/// forceWorldPos 3xf32, hipPos 3xf32, (flags&2) mode u8, (flags&4) state u8.
/// The sender is the entity's owner (EntityBuffs / EModelBase.DoRagdoll
/// force the local ragdoll); the server applies it and re-broadcasts via
/// NetEntityDistribution.SendPacketToTrackedPlayersAndTrackedEntity, so a
/// verbatim relay to the other clients matches the intent (the owner already
/// ragdolled locally).
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

/// One decoded NetPackageItemActionEffects body. The two Vector3 are optional
/// on the wire (a presence bool covers both); `wire_len` is the consumed
/// length so a relay forwards exactly what stock writes.
pub const ItemActionEffects = struct {
    entity_id: i32 = 0,
    slot_idx: u8 = 0,
    action_idx: u8 = 0,
    firing_state: u8 = 0,
    user_data: i32 = 0,
    wire_len: usize = 0,
};

/// NetPackageItemActionEffects::read (IL=39,
/// il/netpackages-v3.2.0/NetPackageItemActionEffects_il.txt:33): entityId i32
/// | slotIdx u8 | actionIdx u8 | firingState u8 | a bool that, when set, is
/// followed by startPos and direction as Vector3 (write IL=52 sets it only
/// when either vector is non-zero, so a false here means both are zero).
pub fn parseItemActionEffects(body: []const u8) binary.ReadError!ItemActionEffects {
    var r: binary.Reader = .{ .data = body };
    const eid = try r.readI32();
    const slot = try r.readByte();
    const action = try r.readByte();
    const firing = try r.readByte();
    if (try r.readBool()) {
        var i: usize = 0;
        while (i < 6) : (i += 1) _ = try r.readF32();
    }
    const user_data = try r.readI32();
    return .{
        .entity_id = eid,
        .slot_idx = slot,
        .action_idx = action,
        .firing_state = firing,
        .user_data = user_data,
        .wire_len = r.pos,
    };
}

/// One decoded NetPackageWireToolActions body. `operation` is the stock
/// `WireActions` enum byte; `entity_id` is the player the client claims is
/// holding the wire tool, which the server checks against the sender.
pub const WireToolActions = struct {
    operation: u8 = 0,
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
    entity_id: i32 = 0,
};

/// NetPackageWireToolActions::read (IL=13,
/// il/netpackages-v3.2.0/NetPackageWireToolActions_il.txt:17):
/// currentOperation u8 | tileEntityPosition Vector3i | entityID i32.
/// GetLength() IL=2 returns 12, but the read is 17 bytes; the length hint is
/// the pool size class, not the body size, so trust the read.
pub fn parseWireToolActions(body: []const u8) binary.ReadError!WireToolActions {
    var r: binary.Reader = .{ .data = body };
    const op = try r.readByte();
    const x = try r.readI32();
    const y = try r.readI32();
    const z = try r.readI32();
    const eid = try r.readI32();
    return .{ .operation = op, .x = x, .y = y, .z = z, .entity_id = eid };
}

/// Stock NetPackageWireActions SetParent body (asm.il:842779): op=0,
/// tileEntityPosition=child, childCount=1, wireChildren[0]=parent, wiringEntityID.
pub fn buildWireSetParentBody(buf: []u8, cx: i32, cy: i32, cz: i32, px: i32, py: i32, pz: i32, entity_id: i32) ![]u8 {
    if (buf.len < 30) return error.Overflow;
    buf[0] = 0;
    std.mem.writeInt(i32, buf[1..5], cx, .little);
    std.mem.writeInt(i32, buf[5..9], cy, .little);
    std.mem.writeInt(i32, buf[9..13], cz, .little);
    buf[13] = 1;
    std.mem.writeInt(i32, buf[14..18], px, .little);
    std.mem.writeInt(i32, buf[18..22], py, .little);
    std.mem.writeInt(i32, buf[22..26], pz, .little);
    std.mem.writeInt(i32, buf[26..30], entity_id, .little);
    return buf[0..30];
}
