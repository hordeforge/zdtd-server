//! Game-event bodies: the GameEventRequest ack (Approved, no tail)
//! and the ClientSequenceAction builder, with their tests.
//!
//! Split out of the packages.zig facade (same builders, same tests);
//! import via `packages.stock_gameevent` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");

/// NetPackageGameEventResponse ack for a GameEventRequest (challenge/quest
/// actions). Request wire: eventName str | entityID i32 | extraData str | tag
/// str | ... . Response wire (IL): eventName str | targetEntityID i32 |
/// extraData str | tag str | responseType u8 | entitySpawnedID i32 |
/// [type tail]. We reply Approved(1) with no tail so the client action
/// completes; the server has no challenge sim yet (EAC-off, client-tracked).
pub fn buildGameEventResponse(buf: []u8, request_body: []const u8) ![]u8 {
    var r: binary.Reader = .{ .data = request_body };
    var name_buf: [256]u8 = undefined;
    var extra_buf: [256]u8 = undefined;
    var tag_buf: [256]u8 = undefined;
    const event_name = try r.readString(&name_buf);
    const entity_id = r.readI32() catch 0;
    // extraData + tag echoed back so the client matches response to request.
    const extra = r.readString(&extra_buf) catch "";
    const tag = r.readString(&tag_buf) catch "";

    var w: binary.Writer = .{ .buf = buf };
    try w.writeString(event_name);
    try w.writeI32(entity_id); // targetEntityID
    try w.writeString(extra);
    try w.writeString(tag);
    try w.writeByte(1); // ResponseTypes.Approved
    try w.writeI32(0); // entitySpawnedID (no tail for Approved)
    return w.written();
}

/// Stock NetPackageGameEventResponse carrying a client action for the
/// receiver to perform (`ActionBaseClientAction.PerformTargetAction` sends
/// `ResponseTypes.ClientSequenceAction = 12` with the action key; the client
/// runs it via `HandleGameEventSequenceItemForClient(eventName, actionKey)`
/// against its own gameevents.xml copy). Body: eventName str |
/// targetEntityID i32 | extraData str | tag str | responseType u8 |
/// entitySpawnedID i32 (-1 stock) | actionKey str (read IL=89, write IL=144).
/// The key is stock's `BaseAction.actionKey`: `<sequenceName><index>` for a
/// root action (`SetActionKeyData` IL=23), `<parentKey>:<index>` when nested.
pub fn buildGameEventSequenceAction(
    buf: []u8,
    event_name: []const u8,
    target_entity_id: i32,
    action_key: []const u8,
) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeString(event_name);
    try w.writeI32(target_entity_id);
    try w.writeString("");
    try w.writeString("");
    try w.writeByte(12); // ResponseTypes.ClientSequenceAction
    try w.writeI32(-1); // entitySpawnedID (unused by the type-12 arm)
    try w.writeString(action_key);
    return w.written();
}

test "game event sequence action carries type 12 plus the action key" {
    var buf: [128]u8 = undefined;
    const body = try buildGameEventSequenceAction(&buf, "game_on_death_default", 107, "game_on_death_default0");
    var r: binary.Reader = .{ .data = body };
    var nb: [64]u8 = undefined;
    try std.testing.expectEqualStrings("game_on_death_default", try r.readString(&nb));
    try std.testing.expectEqual(@as(i32, 107), try r.readI32());
    var eb: [64]u8 = undefined;
    try std.testing.expectEqualStrings("", try r.readString(&eb));
    var tb: [64]u8 = undefined;
    try std.testing.expectEqualStrings("", try r.readString(&tb));
    try std.testing.expectEqual(@as(u8, 12), try r.readByte());
    try std.testing.expectEqual(@as(i32, -1), try r.readI32());
    var kb: [64]u8 = undefined;
    try std.testing.expectEqualStrings("game_on_death_default0", try r.readString(&kb));
    try std.testing.expectEqual(body.len, r.pos);
}

test "game event response echoes request name and approves" {
    var rb: [128]u8 = undefined;
    var rw: binary.Writer = .{ .buf = &rb };
    try rw.writeString("challenge_action");
    try rw.writeI32(107);
    try rw.writeString("extra");
    try rw.writeString("t1");
    try rw.writeBool(false);
    const req = rw.written();
    var buf: [128]u8 = undefined;
    const resp = try buildGameEventResponse(&buf, req);
    var pr: binary.Reader = .{ .data = resp };
    var nb: [64]u8 = undefined;
    try std.testing.expectEqualStrings("challenge_action", try pr.readString(&nb));
    try std.testing.expectEqual(@as(i32, 107), try pr.readI32());
    var eb: [64]u8 = undefined;
    try std.testing.expectEqualStrings("extra", try pr.readString(&eb));
    var tb: [64]u8 = undefined;
    try std.testing.expectEqualStrings("t1", try pr.readString(&tb));
    try std.testing.expectEqual(@as(u8, 1), try pr.readByte()); // Approved
}

test "game event response rejects a truncated name and defaults a truncated tail" {
    var full: [64]u8 = undefined;
    var fw: binary.Writer = .{ .buf = &full };
    try fw.writeString("ev");
    try fw.writeI32(1);
    try fw.writeString("x");
    try fw.writeString("y");
    const complete = fw.written();
    var out: [128]u8 = undefined;

    try std.testing.expectError(error.EndOfStream, buildGameEventResponse(&out, complete[0..0]));
    try std.testing.expectError(error.EndOfStream, buildGameEventResponse(&out, complete[0..2]));

    var len: usize = 3;
    while (len <= complete.len) : (len += 1) {
        const response = try buildGameEventResponse(&out, complete[0..len]);
        var r: binary.Reader = .{ .data = response };
        var name: [8]u8 = undefined;
        var extra: [8]u8 = undefined;
        var tag: [8]u8 = undefined;
        try std.testing.expectEqualStrings("ev", try r.readString(&name));
        _ = try r.readI32();
        _ = try r.readString(&extra);
        _ = try r.readString(&tag);
        try std.testing.expectEqual(@as(u8, 1), try r.readByte());
        try std.testing.expectEqual(@as(i32, 0), try r.readI32());
        try std.testing.expectEqual(@as(usize, 0), r.remaining());
    }
}
