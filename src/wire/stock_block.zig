//! Block + audio bodies: SetBlock variants, multi-change parse,
//! WaterSet, and the AudioPlay request shape with its roundtrip test.
//!
//! Split out of the packages.zig facade (same builders, same test);
//! import via `packages.stock_block` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");
const platform_user = @import("platform_user.zig");

/// BlockChangeInfo::Write flag bits (asm.il:1100162). Only value/density/texture
/// carry payload bytes; damage/forceDensity/updateLight are pure booleans that
/// change how the receiver applies the change, so a reader that rejects them
/// drops perfectly ordinary stock edits. WorldBase::SetBlockRPC(bvRef, bv)
/// (asm.il:1248595) always sets bUpdateLight, so a plain block flip is 0x11.
pub const block_change_flag_value: u8 = 1; // bChangeBlockValue
pub const block_change_flag_damage: u8 = 2; // bChangeDamage (damage rides in BlockValue)
pub const block_change_flag_density: u8 = 4; // bChangeDensity (sbyte)
pub const block_change_flag_force_density: u8 = 8; // bForceDensity (no payload)
pub const block_change_flag_update_light: u8 = 0x10; // bUpdateLight (no payload)
pub const block_change_flag_texture: u8 = 0x20; // bChangeTexture (TextureFullArray)
pub const block_change_flags_known: u8 =
    block_change_flag_value | block_change_flag_damage | block_change_flag_density |
    block_change_flag_force_density | block_change_flag_update_light | block_change_flag_texture;

/// BlockValue.type: low 16 of rawData (asm.il BlockValue.get_type).
pub const block_type_mask: u32 = 0xffff;

/// BlockValue.meta lives in rawData bits 22..25 (asm.il:140570 get_meta).
/// Powered blocks carry their visual state there: bit 0x1 = isPowered,
/// bit 0x2 = isOn (Block::ActivateBlock, asm.il:127088 / 137044).
pub const block_meta_powered: u8 = 1;
pub const block_meta_on: u8 = 2;

pub fn blockMeta(raw: u32) u8 {
    return @intCast((raw >> 22) & 15);
}

/// BlockValue::set_meta: clear bits 22..25 then splice the low nibble back in.
pub fn withBlockMeta(raw: u32, meta: u8) u32 {
    return (raw & 0xfc3fffff) | (@as(u32, meta & 15) << 22);
}


/// NetPackageSetBlock, one change (RE write IL=37; field order in
/// buildSetBlockBodyRaw). Null platform user; peers accept S2C without id check.
/// Id-only: rotation and meta bits are zero, so this is safe for fresh placement
/// and wrong for echoing a mutated block. Those callers want buildSetBlockBodyRaw.
pub fn buildSetBlockBody(buf: []u8, x: i32, y: i32, z: i32, block_id: u16) ![]u8 {
    return buildSetBlockBodyRaw(buf, x, y, z, @as(u32, block_id), 0, 0, 0);
}

/// NetPackageSetBlock carrying block damage (RE write IL=37; the damage u16 is
/// part of BlockValue.Write, see buildSetBlockBodyRaw).
pub fn buildSetBlockBodyDamage(
    buf: []u8,
    x: i32,
    y: i32,
    z: i32,
    block_id: u16,
    damage: u16,
    changed_by_entity: i32,
    local_player_that_changed: i32,
) ![]u8 {
    return buildSetBlockBodyRaw(buf, x, y, z, @as(u32, block_id), damage, changed_by_entity, local_player_that_changed);
}

/// Authoritative SetBlock carrying the whole BlockValue.rawData. Callers that
/// echo a mutated block must use this, not the id-only form: rotation and meta
/// live above the low 16 bits (asm.il:141018 BlockValue::Write), so rebuilding
/// rawData from the id alone snaps switches back off and doors back shut.
/// NetPackageSetBlock (RE protocol-packages.md 6.9 + write IL=37):
/// `persistentPlayerId` (ToStream; null = one 0 byte) | `blockChanges` count
/// i16 | count x BlockChangeInfo.Write | `localPlayerThatChanged` i32.
///
/// BlockChangeInfo.Write is BlockValueRef | `changedByEntityId` i32 | flags u8,
/// then the payloads the flags select. We set bChangeBlockValue only, so what
/// follows is BlockValue.Write = `rawData` u32 + `damage` u16 (Write IL=10).
/// The damage u16 belongs to BlockValue, not to the bChangeDamage flag: that
/// flag only tells the receiver to apply the damage that already rides here.
pub fn buildSetBlockBodyRaw(
    buf: []u8,
    x: i32,
    y: i32,
    z: i32,
    raw: u32,
    damage: u16,
    changed_by_entity: i32,
    local_player_that_changed: i32,
) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try platform_user.write(&w, null);
    try w.writeI16(1); // one BlockChangeInfo
    // BlockValueRef: type=1 (BlockPosition) + Vector3i
    try w.writeByte(1);
    try w.writeI32(x);
    try w.writeI32(y);
    try w.writeI32(z);
    try w.writeI32(changed_by_entity);
    try w.writeByte(block_change_flag_value);
    try w.writeU32(raw);
    try w.writeU16(damage);
    try w.writeI32(local_player_that_changed);
    return w.written();
}

pub const BlockChange = struct {
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
    block_id: u16 = 0,
    /// Full BlockValue.rawData (type low 16 + rotation/rotation bits).
    raw: u32 = 0,
    damage: u16 = 0,
    has_pos: bool = false,
    has_value: bool = false,
};

/// First change of a NetPackageSetBlock body, for the callers that only ever
/// act on one (RE blocks.md, BlockChangeInfo.Read IL=76). Full layout and the
/// legacy fixture form are in parseSetBlockChanges; this is a projection of it,
/// not a second decoder. A change without both a position and a value is an
/// error here because there is nothing to return.
pub fn parseSetBlockBody(body: []const u8) !struct { x: i32, y: i32, z: i32, block_id: u16 } {
    var one: [1]BlockChange = undefined;
    const n = try parseSetBlockChanges(body, one[0..]);
    if (n == 0 or !one[0].has_pos or !one[0].has_value) return error.EndOfStream;
    return .{ .x = one[0].x, .y = one[0].y, .z = one[0].z, .block_id = one[0].block_id };
}

/// Read side of NetPackageSetBlock (RE blocks.md, BlockChangeInfo.Write IL=89 /
/// Read IL=76): `persistentPlayerId` (PlatformUserIdentifier) | `count` i16 |
/// then per change a `BlockValueRef` (discriminant byte, 1 = Block followed by
/// Vector3i) | `changedByEntityId` i32 | flags byte | the flagged payloads in
/// flag order (BlockValue.Write = `rawData` u32 + `damage` u16, `sbyte`
/// density, TextureFullArray). bForceDensity and bUpdateLight are flags with no
/// payload.
///
/// An unknown flag bit is an error, not a skip: the bit selects a payload this
/// reader cannot size, so continuing would decode every later change in the
/// batch from a desynced offset as a bogus world edit. Changes lacking a
/// position or a value are dropped from the output rather than returned half
/// filled.
///
/// There is no length-keyed shortcut here. A 14-byte legacy branch used to sit
/// at the top, and 14 is a length a stock body reaches on its own: identity
/// plus a zero count is `6 + platform.len + id.len`, so any pair summing to 8
/// (`"Steam"` with a 3-character id) hit it, and an empty change list came back
/// as one change with x/y/z read out of the identity bytes. The caller's reach
/// check happened to reject those coordinates; that is not a defence a parser
/// should lean on.
pub fn parseSetBlockChanges(body: []const u8, out: []BlockChange) !usize {
    var r: binary.Reader = .{ .data = body };
    try platform_user.skip(&r);
    const n_i = try r.readI16();
    if (n_i <= 0) return 0;
    const n: usize = @intCast(n_i);
    var written: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ch = try readBlockChangeInfo(&r);
        if (ch.has_pos and ch.has_value and written < out.len) {
            out[written] = ch;
            written += 1;
        }
    }
    return written;
}

/// One `NetPackageWaterSet/WaterSetInfo`: `worldPos` Vector3i then a
/// `WaterValue` whose whole serialized form is a `UInt16 mass`
/// (WaterValue.il.txt:127, SerializedLength IL=2 returns 2).
pub const WaterSetChange = struct {
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
    mass: u16 = 0,
};

/// Stock `WaterValue.Full` mass (WaterValue.il.txt:141, `ldc.i4 19500`); the
/// `BlockValue` ctor maps an isWater block to exactly this. `Empty` is 0.
pub const water_mass_full: u16 = 19500;

/// `NetPackageWaterSet::read` (NetPackageWaterSet.il.txt:55): `senderEntityId`
/// i32 | `changes.Count` u16 | WaterSetInfo per entry. The client sends this
/// when a jar fill/empty or a water-cube tool edits water; stock's server
/// relays it to every other peer and then applies it, so the change is not
/// local to the acting client.
pub fn parseWaterSet(body: []const u8, out: []WaterSetChange) binary.ReadError!struct { sender: i32, n: usize } {
    var r: binary.Reader = .{ .data = body };
    const sender = try r.readI32();
    const count = try r.readU16();
    var written: usize = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const x = try r.readI32();
        const y = try r.readI32();
        const z = try r.readI32();
        const mass = try r.readU16();
        if (written < out.len) {
            out[written] = .{ .x = x, .y = y, .z = z, .mass = mass };
            written += 1;
        }
    }
    return .{ .sender = sender, .n = written };
}

/// Write side of the same body, for the server relay (stock
/// `NetPackageWaterSet::write` IL=36, NetPackageWaterSet.il.txt:86: base
/// write, `senderEntityId` i32, `changes.Count` as u16, then
/// `WaterSetInfo::Write` per entry, itself `StreamUtils::Write(Vector3i)` plus
/// `WaterValue::Write` u16, NetPackageWaterSet_WaterSetInfo.il.txt:16).
pub fn buildWaterSetBody(buf: []u8, sender: i32, changes: []const WaterSetChange) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(sender);
    if (changes.len > std.math.maxInt(u16)) return error.Overflow;
    try w.writeU16(@intCast(changes.len));
    for (changes) |c| {
        try w.writeI32(c.x);
        try w.writeI32(c.y);
        try w.writeI32(c.z);
        try w.writeU16(c.mass);
    }
    return w.written();
}

test "water set body round-trips the stock layout" {
    var buf: [64]u8 = undefined;
    // Every coordinate is distinct, so swapping any two of the three i32
    // writes (or the matching reads) fails here. Sharing y between entries
    // would let an x/y swap through.
    const changes = [_]WaterSetChange{
        .{ .x = 10, .y = 70, .z = -4, .mass = water_mass_full },
        .{ .x = 11, .y = 71, .z = -5, .mass = 0 },
    };
    const body = try buildWaterSetBody(&buf, 107, &changes);
    // i32 sender + u16 count + 2 x (3 x i32 + u16)
    try std.testing.expectEqual(@as(usize, 4 + 2 + 2 * 14), body.len);
    var out: [4]WaterSetChange = undefined;
    const got = try parseWaterSet(body, &out);
    try std.testing.expectEqual(@as(i32, 107), got.sender);
    try std.testing.expectEqual(@as(usize, 2), got.n);
    try std.testing.expectEqual(@as(i32, 10), out[0].x);
    try std.testing.expectEqual(@as(i32, 70), out[0].y);
    try std.testing.expectEqual(@as(i32, -4), out[0].z);
    try std.testing.expectEqual(water_mass_full, out[0].mass);
    try std.testing.expectEqual(@as(i32, 11), out[1].x);
    try std.testing.expectEqual(@as(i32, 71), out[1].y);
    try std.testing.expectEqual(@as(i32, -5), out[1].z);
    try std.testing.expectEqual(@as(u16, 0), out[1].mass);

    // A count larger than the body is a truncation error, not a short read.
    try std.testing.expectError(error.EndOfStream, parseWaterSet(body[0 .. body.len - 1], &out));
}

/// `Audio.NetPackageAudio` body: the `NetPackageEntityTargeted` base
/// (`entityId` i32, NetPackageEntityTargeted.il.txt:11) then `soundGroupName`
/// string, `play` bool, `position` as three bare f32, `playOnEntity` bool,
/// `occlusion` f32, `volumeScale` f32, `signalOnly` bool (read IL=49,
/// Audio/NetPackageAudio.il.txt:55).
pub const AudioPlay = struct {
    entity_id: i32 = 0,
    sound_group: []const u8 = "",
    play: bool = false,
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    play_on_entity: bool = false,
    occlusion: f32 = 0,
    volume_scale: f32 = 1,
    signal_only: bool = false,
};

/// Read side of the layout above (stock `Audio.NetPackageAudio::read` IL=49,
/// Audio/NetPackageAudio.il.txt:55, over the `NetPackageEntityTargeted::read`
/// base at NetPackageEntityTargeted.il.txt:11). `name_buf` receives the
/// sound-group name.
pub fn parseAudioPlay(body: []const u8, name_buf: []u8) binary.ReadError!AudioPlay {
    var r: binary.Reader = .{ .data = body };
    var out: AudioPlay = .{ .entity_id = try r.readI32() };
    out.sound_group = try r.readStringTruncating(name_buf);
    out.play = try r.readBool();
    out.x = try r.readF32();
    out.y = try r.readF32();
    out.z = try r.readF32();
    out.play_on_entity = try r.readBool();
    out.occlusion = try r.readF32();
    out.volume_scale = try r.readF32();
    out.signal_only = try r.readBool();
    return out;
}

/// Write side of the same body, for the server relay (stock
/// `Audio.NetPackageAudio::write` IL=53, Audio/NetPackageAudio.il.txt:106:
/// base write then the same field order the reader expects).
pub fn buildAudioPlayBody(buf: []u8, a: AudioPlay) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(a.entity_id);
    try w.writeString(a.sound_group);
    try w.writeBool(a.play);
    try w.writeF32(a.x);
    try w.writeF32(a.y);
    try w.writeF32(a.z);
    try w.writeBool(a.play_on_entity);
    try w.writeF32(a.occlusion);
    try w.writeF32(a.volume_scale);
    try w.writeBool(a.signal_only);
    return w.written();
}

test "audio play body round-trips the stock field order" {
    var buf: [128]u8 = undefined;
    const src: AudioPlay = .{
        .entity_id = 107,
        .sound_group = "open_door",
        .play = true,
        .x = 1.5,
        .y = 70,
        .z = -2.5,
        .play_on_entity = true,
        .occlusion = 0.25,
        .volume_scale = 0.75,
        .signal_only = false,
    };
    const body = try buildAudioPlayBody(&buf, src);
    var name_buf: [64]u8 = undefined;
    const got = try parseAudioPlay(body, &name_buf);
    try std.testing.expectEqual(@as(i32, 107), got.entity_id);
    try std.testing.expectEqualStrings("open_door", got.sound_group);
    try std.testing.expect(got.play);
    // Assert every f32, not just z: occlusion and volume_scale are adjacent
    // same-width fields, and x/y went unchecked, so a swap among them would
    // otherwise pass.
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), got.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 70), got.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -2.5), got.z, 0.001);
    try std.testing.expect(got.play_on_entity);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), got.occlusion, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), got.volume_scale, 0.001);
    try std.testing.expect(!got.signal_only);

    try std.testing.expectError(error.EndOfStream, parseAudioPlay(body[0 .. body.len - 1], &name_buf));
}

fn readBlockChangeInfo(r: *binary.Reader) binary.ReadError!BlockChange {
    var ch: BlockChange = .{};
    const ref_type = try r.readByte();
    if (ref_type == 1) {
        ch.x = try r.readI32();
        ch.y = try r.readI32();
        ch.z = try r.readI32();
        ch.has_pos = true;
    } else if (ref_type == 2) {
        // PropRef: two i32 + optional: rare; skip as opaque u64 if present fails soft
        return error.EndOfStream;
    } else if (ref_type != 0) {
        return error.EndOfStream;
    }
    _ = try r.readI32(); // changedByEntityId
    const flags = try r.readByte();
    // Unknown flag bits carry fields we do not consume; continuing would leave
    // the reader desynced and decode the rest of the batch as bogus edits.
    if ((flags & ~block_change_flags_known) != 0) return error.EndOfStream;
    if ((flags & block_change_flag_value) != 0) {
        const raw = try r.readU32();
        ch.raw = raw;
        ch.block_id = @intCast(raw & block_type_mask);
        ch.damage = try r.readU16();
        ch.has_value = true;
    }
    // density sbyte
    if ((flags & block_change_flag_density) != 0) _ = try r.readByte();
    // texture: TextureFullArray.Read(br, 1): typically one u64 when present.
    // Short stream must error, not silently succeed: later changes in the
    // batch would decode from a desynced offset as bogus world edits.
    if ((flags & block_change_flag_texture) != 0) _ = try r.readU64();
    return ch;
}
