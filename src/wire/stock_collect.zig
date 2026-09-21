//! Collect bodies: bag-then-collector build/parse with the roundtrip test.
//!
//! Split out of the packages.zig facade (same code, same test);
//! import via `packages.stock_collect` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");

/// Read side of NetPackageEntityCollect (RE inventories/netpackage-bodies.md,
/// write IL=12): `entityId` i32 | `playerId` i32, the order
/// buildEntityCollectBody writes.
///
/// Both fields come back because stock uses the second one: Process IL=51 runs
/// ValidEntityIdForSender(playerId) before collecting, so a parser that
/// returned only the bag id would leave the handler with nothing to check the
/// claim against.
pub fn parseCollectBody(body: []const u8) !struct { entity_id: i32, player_id: i32 } {
    if (body.len < 8) return error.EndOfStream;
    return .{
        .entity_id = std.mem.readInt(i32, body[0..4], .little),
        .player_id = std.mem.readInt(i32, body[4..8], .little),
    };
}

/// NetPackageEntityCollect (RE inventories/netpackage-bodies.md, write IL=12):
/// `entityId` i32 then `playerId` i32. The dedi rebroadcasts with flags 192
/// after ValidEntityIdForSender (protocol-packages.md, Process IL=51).
pub fn buildEntityCollectBody(buf: []u8, entity_id: i32, player_id: i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeI32(player_id);
    return w.written();
}

test "entity collect body is bag then collector, and the parser agrees" {
    // Two i32 whose order decides which entity is collected and which player
    // is credited. The C2S handler rejects a collect whose playerId is not the
    // sender (ValidEntityIdForSender, Process IL=51), so a swap here would
    // reject every honest collect and accept nothing else.
    var buf: [8]u8 = undefined;
    const body = try buildEntityCollectBody(&buf, 4242, 106);
    try std.testing.expectEqual(@as(usize, 8), body.len);
    try std.testing.expectEqual(@as(i32, 4242), std.mem.readInt(i32, body[0..4], .little));
    try std.testing.expectEqual(@as(i32, 106), std.mem.readInt(i32, body[4..8], .little));
    const p = try parseCollectBody(body);
    try std.testing.expectEqual(@as(i32, 4242), p.entity_id);
    try std.testing.expectEqual(@as(i32, 106), p.player_id);
}
