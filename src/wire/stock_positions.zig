//! Positions bodies: the persistent player-positions broadcast with
//! the layout test.
//!
//! Split out of the packages.zig facade (same builder, same test);
//! import via `packages.stock_positions` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");
const platform_user = @import("platform_user.zig");

/// NetPackagePersistentPlayerPositions (write IL=38): count i32, then per
/// online player a PlatformUserIdentifierAbs.ToStream id + Vector3i position.
/// Broadcast every 6 s by GameManager.playerPositionsCountdownTimer; the
/// client's map shows the markers (protocol-packages.md; RE 2026-08-21).
pub const PlayerPositionEntry = struct {
    id: ?platform_user.Id,
    x: i32,
    y: i32,
    z: i32,
};

/// NetPackagePersistentPlayerPositions (RE inventories/netpackage-bodies.md,
/// write IL=38): `positions` count i32, then per entry the persistent player id
/// (PlatformUserIdentifier ToStream) and the position (StreamUtils Vector3i =
/// three i32).
pub fn buildPersistentPlayerPositionsBody(buf: []u8, entries: []const PlayerPositionEntry) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(@intCast(entries.len));
    for (entries) |e| {
        try platform_user.write(&w, e.id);
        try w.writeI32(e.x);
        try w.writeI32(e.y);
        try w.writeI32(e.z);
    }
    return w.written();
}

test "PersistentPlayerPositions body is count + id stream + Vector3i per entry" {
    var buf: [512]u8 = undefined;
    const entries = [_]PlayerPositionEntry{
        .{ .id = .{ .platform = "Steam", .id = "76561198000000000" }, .x = 100, .y = 60, .z = -200 },
        .{ .id = null, .x = 0, .y = 0, .z = 0 },
    };
    const b = try buildPersistentPlayerPositionsBody(&buf, &entries);
    try std.testing.expectEqual(@as(usize, 4 + (1 + 1 + 1 + 5 + 1 + 17 + 12) + (1 + 12)), b.len);
    try std.testing.expectEqual(@as(i32, 2), std.mem.readInt(i32, b[0..4], .little));
    // entry 0: present=1, version=1, "Steam", "76561198000000000", then Vector3i
    try std.testing.expectEqual(@as(u8, 1), b[4]);
    try std.testing.expectEqual(@as(u8, 1), b[5]);
    var scratch: [128]u8 = undefined;
    var r = binary.Reader{ .data = b[4..] };
    _ = try r.readByte();
    _ = try r.readByte();
    const pl = try r.readString(&scratch);
    try std.testing.expectEqualStrings("Steam", pl);
    const pid = try r.readString(&scratch);
    try std.testing.expectEqualStrings("76561198000000000", pid);
    try std.testing.expectEqual(@as(i32, 100), try r.readI32());
    try std.testing.expectEqual(@as(i32, 60), try r.readI32());
    try std.testing.expectEqual(@as(i32, -200), try r.readI32());
    // entry 1: null id = lone 0 byte.
    try std.testing.expectEqual(@as(u8, 0), try r.readByte());
    try std.testing.expectEqual(@as(i32, 0), try r.readI32());
}
