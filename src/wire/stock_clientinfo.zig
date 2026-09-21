//! Client-info bodies: the player-list broadcast and the backpack
//! position marker, with their layout tests.
//!
//! Split out of the packages.zig facade (same code, same tests);
//! import via `packages.stock_clientinfo` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");

/// NetPackageClientInfo (write IL=41): count u16, then per online player
/// (entityId i32, pingTime i16 via conv.i2, admin bool). Broadcast every 5 s
/// by ConnectionManager.updateClientInfo (RE 2026-08-21); drives the player
/// list UI + admin crowns.
pub const ClientInfoEntry = struct {
    entity_id: i32,
    /// Ping in ms (zdtd has no RTT measurement yet; 0 = unmeasured).
    ping_ms: i16,
    admin: bool,
};

/// NetPackageClientInfo (RE inventories/netpackage-bodies.md, write IL=41):
/// `playerIds` count u16, then per entry entityId i32 | ping i16 | isAdmin bool.
pub fn buildClientInfoBody(buf: []u8, entries: []const ClientInfoEntry) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeU16(@intCast(entries.len));
    for (entries) |e| {
        try w.writeI32(e.entity_id);
        try w.writeI16(e.ping_ms);
        try w.writeBool(e.admin);
    }
    return w.written();
}

test "ClientInfo body is count + entityId + ping + admin per entry" {
    var buf: [256]u8 = undefined;
    const entries = [_]ClientInfoEntry{
        .{ .entity_id = 100, .ping_ms = 24, .admin = true },
        .{ .entity_id = 101, .ping_ms = 0, .admin = false },
    };
    const b = try buildClientInfoBody(&buf, &entries);
    try std.testing.expectEqual(@as(usize, 2 + 2 * 7), b.len);
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, b[0..2], .little));
    try std.testing.expectEqual(@as(i32, 100), std.mem.readInt(i32, b[2..6], .little));
    try std.testing.expectEqual(@as(i16, 24), std.mem.readInt(i16, b[6..8], .little));
    try std.testing.expectEqual(@as(u8, 1), b[8]); // admin
    try std.testing.expectEqual(@as(i32, 101), std.mem.readInt(i32, b[9..13], .little));
    try std.testing.expectEqual(@as(u8, 0), b[15]); // admin false
}

/// NetPackagePlayerSetBackpackPosition (write IL=? / read IL=29): playerId
/// i32, count u8, then Vector3i positions (3 x i32). Broadcast when a
/// player's dropped-backpack markers change (EntityBackpack /
/// PersistentPlayerData; RE 2026-08-21) - the client shows the markers.
pub fn buildPlayerSetBackpackPositionBody(buf: []u8, player_id: i32, positions: []const [3]i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(player_id);
    try w.writeByte(@intCast(positions.len));
    for (positions) |p| {
        try w.writeI32(p[0]);
        try w.writeI32(p[1]);
        try w.writeI32(p[2]);
    }
    return w.written();
}

test "PlayerSetBackpackPosition body is playerId + count + Vector3i list" {
    var buf: [64]u8 = undefined;
    const empty = try buildPlayerSetBackpackPositionBody(&buf, 100, &.{});
    try std.testing.expectEqual(@as(usize, 5), empty.len);
    try std.testing.expectEqual(@as(i32, 100), std.mem.readInt(i32, empty[0..4], .little));
    try std.testing.expectEqual(@as(u8, 0), empty[4]);
    const one = try buildPlayerSetBackpackPositionBody(&buf, 101, &.{.{ 10, 60, -20 }});
    try std.testing.expectEqual(@as(usize, 5 + 12), one.len);
    try std.testing.expectEqual(@as(u8, 1), one[4]);
    try std.testing.expectEqual(@as(i32, 10), std.mem.readInt(i32, one[5..9], .little));
    try std.testing.expectEqual(@as(i32, -20), std.mem.readInt(i32, one[13..17], .little));
}
