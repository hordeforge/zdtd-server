//! `NetPackageSetProp` + `PropChangeInfo` (RE:
//! `../7dtd-engine-research/docs/inventories/netpackage-bodies.md` 1692,
//! `PropChangeInfo.il` `Write` IL_0000-0136, `StreamUtils.il` 498/516).
//!
//! Prop edits are the sibling of the block path: `GameManager.ChangeProps`
//! applies each change to the chunk's prop slot and `SetPropsOnClients` fans the
//! same package out on channel 192, excluding the changer. This file is the wire
//! contract only - the per-chunk prop store, the relay and the chunk-stream leg
//! land separately.
const std = @import("std");
const binary = @import("binary.zig");
const platform_user = @import("platform_user.zig");

/// One `PropChangeInfo`: a chunk coordinate plus the nullable tuple the server
/// applies. Absent fields are not written and are not part of the flags byte.
pub const PropChange = struct {
    chunk_x: i32 = 0,
    chunk_y: i32 = 0,
    prop_id: ?i32 = null,
    position: ?[3]f32 = null,
    rotation: ?[4]f32 = null,
    scale: ?[3]f32 = null,
    /// `BlockValue.rawData` (u32) then `BlockValue.damage` (u16), written only
    /// when the nullable BlockValue is present.
    block_raw: ?u32 = null,
    block_damage: ?u16 = null,
};

/// Flags byte bit per nullable field, in write order (IL_002D-007F).
pub const flag_prop_id: u8 = 1;
pub const flag_position: u8 = 2;
pub const flag_rotation: u8 = 4;
pub const flag_scale: u8 = 8;
pub const flag_block_value: u8 = 16;

fn changeFlags(c: PropChange) u8 {
    var f: u8 = 0;
    if (c.prop_id != null) f |= flag_prop_id;
    if (c.position != null) f |= flag_position;
    if (c.rotation != null) f |= flag_rotation;
    if (c.scale != null) f |= flag_scale;
    if (c.block_raw != null) f |= flag_block_value;
    return f;
}

fn writeVec3(w: *binary.Writer, v: [3]f32) !void {
    for (v) |f| try w.writeF32(f);
}

pub fn writePropChange(w: *binary.Writer, c: PropChange) !void {
    try w.writeI32(c.chunk_x);
    try w.writeI32(c.chunk_y);
    try w.writeByte(changeFlags(c));
    if (c.prop_id) |v| try w.writeI32(v);
    if (c.position) |v| try writeVec3(w, v);
    if (c.rotation) |v| for (v) |f| try w.writeF32(f);
    if (c.scale) |v| try writeVec3(w, v);
    if (c.block_raw) |raw| {
        try w.writeU32(raw);
        try w.writeU16(c.block_damage orelse 0);
    }
}

pub fn readPropChange(r: *binary.Reader) binary.ReadError!PropChange {
    var c: PropChange = .{
        .chunk_x = try r.readI32(),
        .chunk_y = try r.readI32(),
    };
    const flags = try r.readByte();
    // Unknown bits mean a shape this reader does not know: refuse rather than
    // desync the stream (rule 24).
    if (flags & ~(flag_prop_id | flag_position | flag_rotation | flag_scale | flag_block_value) != 0) {
        return error.InvalidString;
    }
    if (flags & flag_prop_id != 0) c.prop_id = try r.readI32();
    if (flags & flag_position != 0) c.position = .{ try r.readF32(), try r.readF32(), try r.readF32() };
    if (flags & flag_rotation != 0) c.rotation = .{ try r.readF32(), try r.readF32(), try r.readF32(), try r.readF32() };
    if (flags & flag_scale != 0) c.scale = .{ try r.readF32(), try r.readF32(), try r.readF32() };
    if (flags & flag_block_value != 0) {
        c.block_raw = try r.readU32();
        c.block_damage = try r.readU16();
    }
    return c;
}

/// `NetPackageSetProp` body: persistentPlayerId (`ToStream`), i16 change count,
/// the changes, then `m_localPlayerThatChanged` i32 (netpackage-bodies.md 1692).
pub fn buildSetPropBody(buf: []u8, puid: ?platform_user.Id, changes: []const PropChange, local_player: i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try platform_user.write(&w, puid);
    try w.writeI16(@intCast(changes.len));
    for (changes) |c| try writePropChange(&w, c);
    try w.writeI32(local_player);
    return w.written();
}

pub const ParsedSetProp = struct {
    persistent_player: ?platform_user.Id,
    changes: []PropChange,
    local_player_that_changed: i32,
};

/// Caller owns `changes_buf`; the returned slice points into it.
///
/// RE: `NetPackageSetProp.Read` / `PropChangeInfo.Read` (`../7dtd-engine-research/docs/network/protocol-packages.md` "Prop/land edits", §5.5) - `m_persistentPlayerId`, the counted `m_propChanges` rows, then `m_localPlayerThatChanged`.
pub fn parseSetPropBody(
    body: []const u8,
    plat_buf: []u8,
    id_buf: []u8,
    changes_buf: []PropChange,
) !ParsedSetProp {
    var r: binary.Reader = .{ .data = body };
    const puid = try platform_user.read(&r, plat_buf, id_buf);
    const n = try r.readI16();
    if (n < 0 or @as(usize, @intCast(n)) > changes_buf.len) return error.InvalidString;
    var i: usize = 0;
    while (i < @as(usize, @intCast(n))) : (i += 1) {
        changes_buf[i] = try readPropChange(&r);
    }
    const local = try r.readI32();
    return .{ .persistent_player = puid, .changes = changes_buf[0..i], .local_player_that_changed = local };
}

test "NetPackageSetProp body round-trips both change shapes" {
    const puid: platform_user.Id = .{ .platform = "Steam", .id = "76561198000000000" };
    const changes = [_]PropChange{
        .{ .chunk_x = 3, .chunk_y = -4, .prop_id = 42, .position = .{ 1.5, 2.5, 3.5 }, .rotation = .{ 0, 0, 0, 1 }, .scale = .{ 1, 1, 1 }, .block_raw = 0xDEADBEEF, .block_damage = 7 },
        .{ .chunk_x = 0, .chunk_y = 0 },
        .{ .chunk_x = 9, .chunk_y = 9, .block_raw = 5, .block_damage = 0 },
    };
    var buf: [512]u8 = undefined;
    const body = try buildSetPropBody(&buf, puid, &changes, -1);

    var plat: [32]u8 = undefined;
    var idbuf: [64]u8 = undefined;
    var out: [8]PropChange = undefined;
    const parsed = try parseSetPropBody(body, &plat, &idbuf, &out);
    try std.testing.expectEqual(@as(usize, 3), parsed.changes.len);
    try std.testing.expectEqual(@as(i32, -1), parsed.local_player_that_changed);
    try std.testing.expect(parsed.persistent_player != null);
    try std.testing.expectEqualStrings("Steam", parsed.persistent_player.?.platform);
    try std.testing.expectEqualStrings("76561198000000000", parsed.persistent_player.?.id);
    const full = parsed.changes[0];
    try std.testing.expectEqual(@as(i32, 3), full.chunk_x);
    try std.testing.expectEqual(@as(i32, -4), full.chunk_y);
    try std.testing.expectEqual(@as(i32, 42), full.prop_id.?);
    try std.testing.expectEqual(@as(f32, 3.5), full.position.?[2]);
    try std.testing.expectEqual(@as(f32, 1), full.rotation.?[3]);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), full.block_raw.?);
    try std.testing.expectEqual(@as(u16, 7), full.block_damage.?);
    // A coordinate-only change carries no flags and no values.
    try std.testing.expectEqual(@as(?i32, null), parsed.changes[1].prop_id);
    try std.testing.expectEqual(@as(?[3]f32, null), parsed.changes[1].position);
    try std.testing.expectEqual(@as(?[3]f32, null), parsed.changes[2].scale);
    // A BlockValue without an explicit damage reads back as 0, not absent.
    try std.testing.expectEqual(@as(?u16, 0), parsed.changes[2].block_damage);

    // The flags byte distinguishes the two shapes: the full change carries all
    // five bits, the coordinate-only change none.
    try std.testing.expectEqual(@as(u8, 31), changeFlags(changes[0]));
    try std.testing.expectEqual(@as(u8, 0), changeFlags(changes[1]));
}
