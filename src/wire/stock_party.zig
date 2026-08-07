//! NetPackagePartyActions (ToServer) + NetPackagePartyData (ToClient) bodies
//! (RE ../7dtd-research/docs/parties-factions.md §3).
//!
//! `NetPackagePartyActions.write` order: currentOperation u8, invitedByEntityID
//! i32, invitedEntityID i32, voiceLobbyId string (empty when null). The
//! `partyMembers` field is not serialized.
//!
//! `NetPackagePartyData.write` order: PartyID i32, LeaderIndex u8 (narrowed
//! from int), VoiceLobbyId string, memberCount i32, members i32[],
//! changedEntityID i32, partyAction u8, disbandParty bool.

const std = @import("std");
const binary = @import("binary.zig");

/// NetPackagePartyActions.PartyActions (parties-factions.md §2.2).
pub const PartyActions = enum(u8) {
    send_invite = 0,
    accept_invite = 1,
    change_lead = 2,
    leave_party = 3,
    kick_from_party = 4,
    disconnected = 5,
    join_auto_party = 6,
    set_voice_lobby = 7,
    _,
};

pub const ActionParsed = struct {
    action: u8,
    invited_by_entity: i32,
    invited_entity: i32,
    voice_lobby: []const u8,
};

/// Parse the NetPackagePartyActions body. `voice_buf` receives the string
/// (caller-owned stack scratch); on parse failure the caller drops the packet.
pub fn readActions(body: []const u8, voice_buf: []u8) binary.ReadError!ActionParsed {
    var r = binary.Reader{ .data = body };
    const action = try r.readByte();
    const invited_by = try r.readI32();
    const invited = try r.readI32();
    const voice = try r.readString(voice_buf);
    return .{
        .action = action,
        .invited_by_entity = invited_by,
        .invited_entity = invited,
        .voice_lobby = voice,
    };
}

/// Members snapshot for NetPackagePartyData.write.
pub const PartyDataArgs = struct {
    party_id: i32,
    leader_index: u8,
    voice_lobby: []const u8 = "",
    /// Member entity ids (≤ 8).
    members: []const i32,
    changed_entity: i32 = -1,
    party_action: u8 = 0,
    disband: bool = false,
};

/// Encode NetPackagePartyData.write (parties-factions.md §3). Bodies are small
/// (≤ 8 members x 4 + fixed header), so callers pass a stack buffer.
pub fn buildDataBody(buf: []u8, args: PartyDataArgs) ![]u8 {
    var w = binary.Writer{ .buf = buf };
    try w.writeI32(args.party_id);
    try w.writeByte(args.leader_index);
    try w.writeString(args.voice_lobby);
    if (args.members.len > 255) return error.TooManyMembers;
    try w.writeI32(@intCast(args.members.len));
    for (args.members) |m| try w.writeI32(m);
    try w.writeI32(args.changed_entity);
    try w.writeByte(args.party_action);
    try w.writeBool(args.disband);
    return w.written();
}

/// NetPackageSharedPartyKill (parties-factions.md §3): carries a shared kill
/// to party mates. Setup order: entityTypeID i32, xp i32, entityID i32
/// (killed), killerID i32.
pub const SharedKillArgs = struct {
    entity_type: i32,
    xp: i32,
    entity_id: i32,
    killer_id: i32,
};

pub fn buildSharedKillBody(buf: []u8, args: SharedKillArgs) ![]u8 {
    var w = binary.Writer{ .buf = buf };
    try w.writeI32(args.entity_type);
    try w.writeI32(args.xp);
    try w.writeI32(args.entity_id);
    try w.writeI32(args.killer_id);
    return w.written();
}

pub const SharedKillParsed = struct {
    entity_type: i32,
    xp: i32,
    entity_id: i32,
    killer_id: i32,
};

/// Parse the NetPackageSharedPartyKill body (server ProcessPackage resolves
/// entityID/killerID; caller validates against live entities).
pub fn readSharedKillBody(body: []const u8) binary.ReadError!SharedKillParsed {
    var r = binary.Reader{ .data = body };
    return .{
        .entity_type = try r.readI32(),
        .xp = try r.readI32(),
        .entity_id = try r.readI32(),
        .killer_id = try r.readI32(),
    };
}

test "shared kill body round-trips the four stock fields" {
    var buf: [32]u8 = undefined;
    const body = try buildSharedKillBody(&buf, .{ .entity_type = 3, .xp = 90, .entity_id = 42, .killer_id = 7 });
    try std.testing.expectEqual(@as(usize, 16), body.len);
    const p = try readSharedKillBody(body);
    try std.testing.expectEqual(@as(i32, 3), p.entity_type);
    try std.testing.expectEqual(@as(i32, 90), p.xp);
    try std.testing.expectEqual(@as(i32, 42), p.entity_id);
    try std.testing.expectEqual(@as(i32, 7), p.killer_id);
}

test "party data body layout matches NetPackagePartyData.write" {
    var buf: [128]u8 = undefined;
    const members = [_]i32{ 10, 20, 30 };
    const body = try buildDataBody(&buf, .{
        .party_id = 3,
        .leader_index = 1,
        .voice_lobby = "v1",
        .members = &members,
        .changed_entity = 30,
        .party_action = 2,
    });
    // PartyID 4 + LeaderIndex 1 + voice "v1" (1 + 2) + count 4 + 3x4 + changed
    // 4 + action 1 + disband 1 = 30.
    try std.testing.expectEqual(@as(usize, 30), body.len);
    var r = binary.Reader{ .data = body };
    try std.testing.expectEqual(@as(i32, 3), try r.readI32());
    try std.testing.expectEqual(@as(u8, 1), try r.readByte());
    var vbuf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("v1", try r.readString(&vbuf));
    try std.testing.expectEqual(@as(i32, 3), try r.readI32());
    try std.testing.expectEqual(@as(i32, 10), try r.readI32());
    try std.testing.expectEqual(@as(i32, 20), try r.readI32());
    try std.testing.expectEqual(@as(i32, 30), try r.readI32());
    try std.testing.expectEqual(@as(i32, 30), try r.readI32());
    try std.testing.expectEqual(@as(u8, 2), try r.readByte());
    try std.testing.expectEqual(@as(u8, 0), try r.readByte()); // disband false
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

test "party data disband flag round-trips" {
    var buf: [128]u8 = undefined;
    const body = try buildDataBody(&buf, .{ .party_id = 1, .leader_index = 0, .members = &.{}, .disband = true });
    var r = binary.Reader{ .data = body };
    _ = try r.readI32();
    _ = try r.readByte();
    var vbuf: [32]u8 = undefined;
    _ = try r.readString(&vbuf);
    _ = try r.readI32(); // count 0
    _ = try r.readI32();
    _ = try r.readByte();
    try std.testing.expect(try r.readByte() != 0);
}

test "party actions body parses the stock field order" {
    var wbuf: [64]u8 = undefined;
    var w = binary.Writer{ .buf = &wbuf };
    try w.writeByte(1); // accept_invite
    try w.writeI32(10); // invitedByEntityID
    try w.writeI32(20); // invitedEntityID
    try w.writeString(""); // voiceLobbyId
    var vbuf: [32]u8 = undefined;
    const a = try readActions(w.written(), &vbuf);
    try std.testing.expectEqual(@as(u8, 1), a.action);
    try std.testing.expectEqual(@as(i32, 10), a.invited_by_entity);
    try std.testing.expectEqual(@as(i32, 20), a.invited_entity);
    try std.testing.expectEqualStrings("", a.voice_lobby);
}
