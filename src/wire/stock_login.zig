//! Player-login parse: NetPackagePlayerLogin field reader with the
//! stock-order, truncation and null-identity tests.
//!
//! Split out of the packages.zig facade (same parser, same tests);
//! import via `packages.stock_login` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");
const platform_user = @import("platform_user.zig");

/// Stock `NetPackagePlayerLogin::read` (asm.il 832140), field for field:
/// playerName string | native PlatformUserIdentifierAbs (inclCustomData=true) |
/// native auth token string | crossplatform PlatformUserIdentifierAbs
/// (inclCustomData=true) | crossplatform token string | version string |
/// compVersion string | u64 discordUserId.
///
/// The two tokens are the platform auth blobs (Steam ticket / EOS JWT, multi-KiB).
/// zdtd runs no authorizer chain, so they are walked past rather than copied.
pub const PlayerLogin = struct {
    name: []const u8,
    /// ClientInfo.PlatformId: the native platform account (asm.il 783892).
    native: platform_user.Stored = .{},
    /// ClientInfo.CrossplatformId: the EOS account, absent on native-only clients.
    crossplatform: platform_user.Stored = .{},
    discord_user_id: u64 = 0,
    /// `version` wire field (the client sends LongStringNoBuild for both).
    version_buf: [24]u8 = undefined,
    version_len: u8 = 0,
    /// `compVersion` wire field; VersionAuthorizer compares this against the
    /// server's LongStringNoBuild (ordinal-ignore-case) and kicks
    /// VersionMismatch on a difference.
    comp_buf: [24]u8 = undefined,
    comp_len: u8 = 0,

    pub fn version(self: *const PlayerLogin) []const u8 {
        return self.version_buf[0..self.version_len];
    }

    pub fn compVersion(self: *const PlayerLogin) []const u8 {
        return self.comp_buf[0..self.comp_len];
    }

    /// `ClientInfo::get_InternalId` (asm.il 783909): crossplatform when present,
    /// otherwise native. This is what stock keys PersistentPlayerData on
    /// (`GameManager::getPersistentPlayerID`, asm.il 1886263).
    pub fn internalId(self: *const PlayerLogin) platform_user.Stored {
        return if (self.crossplatform.present) self.crossplatform else self.native;
    }
};

/// Parse a full login body. `name_buf` receives the raw (unsanitized) name; the
/// caller still owns sanitizing it before it reaches any operator surface.
/// NetPackagePlayerLogin (RE inventories/netpackage-bodies.md, write IL=52):
/// `playerName` string | native identity (ToStream + auth-token string) |
/// crossplatform identity (ToStream + auth-token string) | `version` string |
/// `compVersion` string | `discordUserId` u64. The two auth tokens are skipped:
/// zdtd runs EAC-off and validates nothing platform-side, so reading them would
/// only be theatre.
pub fn parsePlayerLogin(body: []const u8, name_buf: []u8) binary.ReadError!PlayerLogin {
    var r: binary.Reader = .{ .data = body };
    // Stock writes playerName as an unbounded .NET string. Keep what fits and
    // consume the rest: failing here would abandon the whole body, and the
    // caller's version check and player-slot cap ride on a successful parse.
    // A split codepoint at the cut is dropped by sanitizePlayerName.
    var out: PlayerLogin = .{ .name = try r.readStringTruncating(name_buf) };
    var plat_buf: [platform_user.max_platform_len]u8 = undefined;
    var id_buf: [platform_user.max_id_len]u8 = undefined;

    try out.native.set(try platform_user.read(&r, &plat_buf, &id_buf));
    try r.skipString(); // native auth token
    try out.crossplatform.set(try platform_user.read(&r, &plat_buf, &id_buf));
    try r.skipString(); // crossplatform auth token
    const ver = try r.readString(&out.version_buf);
    out.version_len = @intCast(ver.len);
    const comp = try r.readString(&out.comp_buf);
    out.comp_len = @intCast(comp.len);
    out.discord_user_id = try r.readU64();
    return out;
}

/// Stock `NetPackageAllyRequest::read` (asm.il 886226): source
/// PlatformUserIdentifierAbs | target PlatformUserIdentifierAbs | bool addAlly.
/// Both identities are required: `AllyStore::ProcessAllyRequest` (asm.il 885024)
/// returns immediately when either is null, so a null one is a dead request.
pub const AllyRequest = struct {
    source: platform_user.Stored,
    target: platform_user.Stored,
    add_ally: bool,
};

/// Stock `NetPackageAllyRequest::write` (asm.il 886258). zdtd never sends this
/// one (its direction is ToServer, asm.il 886198); it exists so scenarios can
/// drive the real C2S handler with real bytes.
pub fn buildAllyRequestBody(
    buf: []u8,
    source: platform_user.Id,
    target: platform_user.Id,
    add_ally: bool,
) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try platform_user.write(&w, source);
    try platform_user.write(&w, target);
    try w.writeBool(add_ally);
    return w.written();
}

/// Read side of NetPackageAllyRequest (RE inventories/netpackage-bodies.md,
/// write IL=18): `source` | `target` (both PlatformUserIdentifier ToStream) |
/// `addAlly` bool. docs/wire/PACKAGES.md shows only `ReadBoolean;` for this
/// package because the two identity reads go through a static FromStream that
/// the extractor does not follow; the note at the top of that file covers it.
pub fn parseAllyRequest(body: []const u8) binary.ReadError!AllyRequest {
    var r: binary.Reader = .{ .data = body };
    var plat_buf: [platform_user.max_platform_len]u8 = undefined;
    var id_buf: [platform_user.max_id_len]u8 = undefined;
    var out: AllyRequest = .{ .source = .{}, .target = .{}, .add_ally = false };
    try out.source.set(try platform_user.read(&r, &plat_buf, &id_buf));
    try out.target.set(try platform_user.read(&r, &plat_buf, &id_buf));
    out.add_ally = try r.readBool();
    return out;
}

/// Stock `NetPackageWaypoint` (write IL=17, read IL=17): a `Waypoint`
/// (Waypoint.Write IL=57; NetPackageWaypoint.read reads it with version 7,
/// so every version-gated field is present) followed by inviteMode:u8
/// (EnumWaypointInviteMode Friends=0 / Everyone=1) and inviterEntityId:i32.
/// Waypoint field order: pos Vector3i (3xi32), icon string ("" when null),
/// name AuthoredText (bool present, then string text + platform id when
/// present), bTracked bool, hiddenOnCompass bool, ownerId platform id,
/// lastKnownPositionEntityId i32, bIsAutoWaypoint bool, bUsingLocalizationId
/// bool, inviterEntityId i32, hiddenOnMap bool, lastKnownPositionEntityType
/// i32 (eLastKnownPositionEntityType None=0/Vehicle=1/Drone=2/Animal=3).
/// Server relay (GameManager.WaypointInviteServer IL=164) clones the waypoint,
/// clears bTracked, sets waypoint.inviterEntityId = inviter, and targets the
/// inviter's allies (mode Friends) or all players (mode Everyone), skipping
/// the inviter (7dtd-engine-research protocol-packages.md §5.x).
pub const WaypointInvite = struct {
    pos: [3]i32,
    /// Fixed-size copies of the client strings; parse never returns slices
    /// into the body or into stack scratch.
    icon: [max_waypoint_str]u8 = .{0} ** max_waypoint_str,
    icon_len: u8 = 0,
    name_present: bool = false,
    name_text: [max_waypoint_str]u8 = .{0} ** max_waypoint_str,
    name_text_len: u8 = 0,
    name_author: platform_user.Stored = .{},
    b_tracked: bool = false,
    hidden_on_compass: bool = false,
    owner_id: platform_user.Stored = .{},
    last_known_entity_id: i32 = 0,
    is_auto: bool = false,
    using_loc_id: bool = false,
    waypoint_inviter_entity: i32 = 0,
    hidden_on_map: bool = false,
    last_known_entity_type: i32 = 0,
    invite_mode: u8 = 0,
    inviter_entity_id: i32 = 0,

    pub fn iconSlice(self: *const WaypointInvite) []const u8 {
        return self.icon[0..self.icon_len];
    }

    pub fn nameTextSlice(self: *const WaypointInvite) []const u8 {
        return self.name_text[0..self.name_text_len];
    }
};

/// Waypoint names/icons are short user strings; anything longer fails closed
/// (malformed C2S is dropped, never truncated).
pub const max_waypoint_str: usize = 256;

fn copyWaypointStr(dst: *[max_waypoint_str]u8, src: []const u8) error{Overflow}!u8 {
    // The returned length is a u8 and the cap is 256, so the cap itself does
    // not fit: reject at >= (not >) or the @intCast below traps on a
    // client-controlled 256-byte string.
    if (src.len >= max_waypoint_str) return error.Overflow;
    @memcpy(dst[0..src.len], src);
    return @intCast(src.len);
}

/// Read side of NetPackageWaypoint (RE protocol-packages.md 5.7, write/read
/// IL=17, Waypoint version 7 with every version gate open): `pos` Vector3i |
/// `icon` string | `name` AuthoredText (present bool, then text + identity) |
/// `bTracked` | `hiddenOnCompass` | `ownerId` identity |
/// `lastKnownPositionEntityId` i32 | `bIsAutoWaypoint` | `bUsingLocalizationId`
/// | `inviterEntityId` i32 | `hiddenOnMap` | `lastKnownPositionEntityType` i32,
/// then `inviteMode` u8 and a second `inviterEntityId` i32 outside the Waypoint.
///
/// Both client-controlled strings go through copyWaypointStr, which rejects a
/// length that would not fit its u8 counter.
pub fn parseWaypointInvite(body: []const u8) (binary.ReadError || error{Overflow})!WaypointInvite {
    var r: binary.Reader = .{ .data = body };
    var out: WaypointInvite = .{ .pos = .{ 0, 0, 0 } };
    out.pos = .{ try r.readI32(), try r.readI32(), try r.readI32() };
    var str_buf: [max_waypoint_str]u8 = undefined;
    out.icon_len = try copyWaypointStr(&out.icon, try r.readString(&str_buf));
    out.name_present = try r.readBool();
    if (out.name_present) {
        out.name_text_len = try copyWaypointStr(&out.name_text, try r.readString(&str_buf));
        var plat_buf: [platform_user.max_platform_len]u8 = undefined;
        var id_buf: [platform_user.max_id_len]u8 = undefined;
        try out.name_author.set(try platform_user.read(&r, &plat_buf, &id_buf));
    }
    out.b_tracked = try r.readBool();
    out.hidden_on_compass = try r.readBool();
    var plat_buf: [platform_user.max_platform_len]u8 = undefined;
    var id_buf: [platform_user.max_id_len]u8 = undefined;
    try out.owner_id.set(try platform_user.read(&r, &plat_buf, &id_buf));
    out.last_known_entity_id = try r.readI32();
    out.is_auto = try r.readBool();
    out.using_loc_id = try r.readBool();
    out.waypoint_inviter_entity = try r.readI32();
    out.hidden_on_map = try r.readBool();
    out.last_known_entity_type = try r.readI32();
    out.invite_mode = try r.readByte();
    out.inviter_entity_id = try r.readI32();
    return out;
}

/// Rebuild the relay body. Matches the server adjustments in
/// NetPackageWaypointInvite (RE: WaypointInviteServer Setup). bTracked=false,
/// waypoint.inviterEntityId = inviter, package inviterEntityId = inviter.
pub fn buildWaypointInviteBody(buf: []u8, wp: *const WaypointInvite, inviter: i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(wp.pos[0]);
    try w.writeI32(wp.pos[1]);
    try w.writeI32(wp.pos[2]);
    try w.writeString(wp.iconSlice());
    try w.writeBool(wp.name_present);
    if (wp.name_present) {
        try w.writeString(wp.nameTextSlice());
        try platform_user.write(&w, wp.name_author.get());
    }
    try w.writeBool(false); // bTracked: server clears before relay (IL_002E)
    try w.writeBool(wp.hidden_on_compass);
    try platform_user.write(&w, wp.owner_id.get());
    try w.writeI32(wp.last_known_entity_id);
    try w.writeBool(wp.is_auto);
    try w.writeBool(wp.using_loc_id);
    try w.writeI32(inviter);
    try w.writeBool(wp.hidden_on_map);
    try w.writeI32(wp.last_known_entity_type);
    try w.writeByte(wp.invite_mode);
    try w.writeI32(inviter);
    return w.written();
}

pub const WaypointEntry = struct {
    entity_id: i32,
    x: f32,
    y: f32,
    z: f32,
};

/// Stock `NetPackageEntityWaypointList` (write IL=39): listType i16
/// (`eWayPointListType` Vehicle=0 / Drone=1) then a count-prefixed list of
/// (entityId i32, position Vector3 as 3xf32). The server ships the owner's
/// vehicles to a remote player
/// (`VehicleManager.UpdateVehicleWaypointsForPlayer` IL=69, channel 192) so
/// their map shows where they parked.
pub fn buildEntityWaypointListBody(buf: []u8, list_type: i16, entries: []const WaypointEntry) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI16(list_type);
    try w.writeI32(@intCast(entries.len));
    for (entries) |e| {
        try w.writeI32(e.entity_id);
        try w.writeF32(e.x);
        try w.writeF32(e.y);
        try w.writeF32(e.z);
    }
    return w.written();
}

test "waypoint invite parses and rebuilds round-trip" {
    var src: [512]u8 = undefined;
    var w: binary.Writer = .{ .buf = &src };
    try w.writeI32(123);
    try w.writeI32(64);
    try w.writeI32(-9);
    try w.writeString("ui_game_symbol_map");
    try w.writeBool(true);
    try w.writeString("my marker");
    try platform_user.write(&w, .{ .platform = "Steam", .id = "76561198000000000" });
    try w.writeBool(true); // bTracked
    // hiddenOnCompass true, and isAuto / usingLocId differ: all three were
    // false, which matched the literal false the builder writes beside them
    // and made those swaps emit identical bytes.
    try w.writeBool(true); // hiddenOnCompass
    try platform_user.write(&w, .{ .platform = "Steam", .id = "76561198000000001" });
    try w.writeI32(-1);
    try w.writeBool(true); // isAuto
    try w.writeBool(false); // usingLocId
    try w.writeI32(7); // waypoint inviterEntityId
    try w.writeBool(true); // hiddenOnMap
    try w.writeI32(2); // lastKnownPositionEntityType Drone
    try w.writeByte(0); // inviteMode Friends
    try w.writeI32(7); // inviterEntityId
    const body = w.written();

    const wp = try parseWaypointInvite(body);
    try std.testing.expectEqual([3]i32{ 123, 64, -9 }, wp.pos);
    try std.testing.expectEqualStrings("ui_game_symbol_map", wp.iconSlice());
    try std.testing.expect(wp.name_present);
    try std.testing.expectEqualStrings("my marker", wp.nameTextSlice());
    const author = wp.name_author.get().?;
    try std.testing.expectEqualStrings("Steam", author.platform);
    try std.testing.expectEqualStrings("76561198000000000", author.id);
    try std.testing.expect(wp.b_tracked);
    try std.testing.expect(wp.hidden_on_compass);
    // isAuto and usingLocId were both unread and both false, matching the
    // literal false the builder writes nearby; distinct values plus these two
    // assertions make that run observable.
    try std.testing.expect(wp.is_auto);
    try std.testing.expect(!wp.using_loc_id);
    try std.testing.expectEqual(@as(i32, 2), wp.last_known_entity_type);
    try std.testing.expectEqual(@as(u8, 0), wp.invite_mode);
    try std.testing.expectEqual(@as(i32, 7), wp.inviter_entity_id);

    // Relay rebuild: bTracked forced false, inviter re-keyed.
    var out: [512]u8 = undefined;
    const rebuilt = try buildWaypointInviteBody(&out, &wp, 42);
    var rd: binary.Reader = .{ .data = rebuilt };
    try std.testing.expectEqual(@as(i32, 123), try rd.readI32());
    try std.testing.expectEqual(@as(i32, 64), try rd.readI32());
    try std.testing.expectEqual(@as(i32, -9), try rd.readI32());
    var sbuf: [max_waypoint_str]u8 = undefined;
    try std.testing.expectEqualStrings("ui_game_symbol_map", try rd.readString(&sbuf));
    try std.testing.expect(try rd.readBool()); // name present
    try std.testing.expectEqualStrings("my marker", try rd.readString(&sbuf));
    var rp: [platform_user.max_platform_len]u8 = undefined;
    var ri: [platform_user.max_id_len]u8 = undefined;
    const ra: platform_user.Id = (try platform_user.read(&rd, &rp, &ri)).?;
    try std.testing.expectEqualStrings("76561198000000000", ra.id);
    try std.testing.expect(!try rd.readBool()); // bTracked cleared on relay
    try std.testing.expect(try rd.readBool()); // hiddenOnCompass echoed
    try std.testing.expect((try platform_user.read(&rd, &rp, &ri)) != null);
    try std.testing.expectEqual(@as(i32, -1), try rd.readI32());
    try std.testing.expect(try rd.readBool()); // isAuto echoed
    try std.testing.expect(!try rd.readBool()); // usingLocId echoed
    try std.testing.expectEqual(@as(i32, 42), try rd.readI32());
    try std.testing.expect(try rd.readBool());
    try std.testing.expectEqual(@as(i32, 2), try rd.readI32());
    try std.testing.expectEqual(@as(u8, 0), try rd.readByte());
    try std.testing.expectEqual(@as(i32, 42), try rd.readI32());
}

test "a waypoint icon at the cap fails closed instead of trapping the cast" {
    // Same shape as the sound clip: the stored length is a u8 while
    // max_waypoint_str is 256, so a client-sent 256-byte icon reached
    // @intCast(256) -> u8. It must be rejected, not panic.
    var src: [1024]u8 = undefined;
    var w: binary.Writer = .{ .buf = &src };
    try w.writeI32(1);
    try w.writeI32(2);
    try w.writeI32(3);
    const long = [_]u8{'i'} ** max_waypoint_str;
    try w.writeString(&long);
    try w.writeBool(false); // no name
    try std.testing.expectError(error.Overflow, parseWaypointInvite(w.written()));
}

/// Stock `NetPackagePartyQuestChange::read` (asm.il): senderEntityID i32 |
/// objectiveIndex u8 | isComplete bool | questCode i32. Server fans it to the
/// other party members; the client's HandlePlayer applies the shared-quest
/// objective delta (parties-factions.md §2.3).
pub const PartyQuestChange = struct {
    sender_entity: i32,
    objective_index: u8,
    is_complete: bool,
    quest_code: i32,
};

/// Read side of NetPackagePartyQuestChange (RE
/// inventories/netpackage-bodies.md, write IL=20): `senderEntityID` i32 |
/// `objectiveIndex` u8 | `isComplete` bool | `questCode` i32.
pub fn parsePartyQuestChange(body: []const u8) binary.ReadError!PartyQuestChange {
    var r: binary.Reader = .{ .data = body };
    return .{
        .sender_entity = try r.readI32(),
        .objective_index = try r.readByte(),
        .is_complete = try r.readBool(),
        .quest_code = try r.readI32(),
    };
}

/// Stock `NetPackageAllyResponse::read` (asm.il 886390): source | target |
/// u8 newStatus | u8 allyEventSource | u8 allyEventTarget. Its direction is
/// ToClient (asm.il 886358), so the server only ever writes this one.
pub fn buildAllyResponseBody(
    buf: []u8,
    source: platform_user.Id,
    target: platform_user.Id,
    new_status: u8,
    event_source: u8,
    event_target: u8,
) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try platform_user.write(&w, source);
    try platform_user.write(&w, target);
    try w.writeByte(new_status);
    try w.writeByte(event_source);
    try w.writeByte(event_target);
    return w.written();
}

test "player login body parses stock field order" {
    var body: [256]u8 = undefined;
    var w: binary.Writer = .{ .buf = &body };
    try w.writeString("Alice");
    try platform_user.write(&w, .{ .platform = "Steam", .id = "76561198000000001" });
    try w.writeString("native-ticket");
    try platform_user.write(&w, .{ .platform = "EOS", .id = "0123456789abcdef" });
    try w.writeString("eos-jwt");
    try w.writeString("V 3.10");
    try w.writeString("V 3.10");
    try w.writeU64(42);

    var name_buf: [32]u8 = undefined;
    const login = try parsePlayerLogin(w.written(), &name_buf);
    try std.testing.expectEqualStrings("Alice", login.name);
    try std.testing.expectEqualStrings("Steam", login.native.get().?.platform);
    try std.testing.expectEqualStrings("76561198000000001", login.native.get().?.id);
    try std.testing.expectEqualStrings("EOS", login.crossplatform.get().?.platform);
    try std.testing.expectEqual(@as(u64, 42), login.discord_user_id);
    // LongStringNoBuild form (client sends it as both version and compVersion).
    try std.testing.expectEqualStrings("V 3.10", login.version());
    try std.testing.expectEqualStrings("V 3.10", login.compVersion());
    // InternalId prefers the crossplatform account.
    try std.testing.expectEqualStrings("EOS", login.internalId().get().?.platform);
}

test "player login with a name longer than the buffer still parses" {
    // Stock writes playerName unbounded. An over-long name used to fail the
    // whole parse, and the caller runs its version check and player-slot cap
    // only on the success branch, so such a client joined ungated.
    var body: [256]u8 = undefined;
    var w: binary.Writer = .{ .buf = &body };
    const long_name = "0123456789012345678901234567890123456789ABCDEF";
    try w.writeString(long_name);
    try platform_user.write(&w, .{ .platform = "EOS", .id = "0123456789abcdef" });
    try w.writeString("native-ticket");
    try platform_user.write(&w, .{ .platform = "EOS", .id = "0123456789abcdef" });
    try w.writeString("eos-jwt");
    try w.writeString("V 3.2.0");
    try w.writeString("V 3.2.0");
    try w.writeU64(7);

    var name_buf: [32]u8 = undefined;
    const login = try parsePlayerLogin(w.written(), &name_buf);
    try std.testing.expectEqualStrings(long_name[0..32], login.name);
    // The fields behind the name still land, so the version gate can run.
    try std.testing.expectEqualStrings("V 3.2.0", login.compVersion());
    try std.testing.expectEqual(@as(u64, 7), login.discord_user_id);
}

test "player login with both identities null still yields the name" {
    // Shape zdtd's own loadgen bot sends: name, null PUID, empty token, ...
    var body: [128]u8 = undefined;
    var w: binary.Writer = .{ .buf = &body };
    try w.writeString("Bot");
    try platform_user.write(&w, null);
    try w.writeString("");
    try platform_user.write(&w, null);
    try w.writeString("");
    try w.writeString("V 3.10");
    try w.writeString("V 3.10");
    try w.writeU64(0);

    var name_buf: [32]u8 = undefined;
    const login = try parsePlayerLogin(w.written(), &name_buf);
    try std.testing.expectEqualStrings("Bot", login.name);
    try std.testing.expect(login.native.get() == null);
    try std.testing.expect(login.crossplatform.get() == null);
    try std.testing.expect(login.internalId().get() == null);
    try std.testing.expectEqualStrings("V 3.10", login.compVersion());
}

test "player login truncated at any boundary is rejected" {
    var body: [128]u8 = undefined;
    var w: binary.Writer = .{ .buf = &body };
    try w.writeString("Bot");
    try platform_user.write(&w, .{ .platform = "Steam", .id = "76561198000000001" });
    try w.writeString("");
    try platform_user.write(&w, null);
    try w.writeString("");
    try w.writeString("V");
    try w.writeString("V");
    try w.writeU64(0);
    const full = w.written();

    var name_buf: [32]u8 = undefined;
    var cut: usize = 0;
    while (cut < full.len) : (cut += 1) {
        try std.testing.expectError(error.EndOfStream, parsePlayerLogin(full[0..cut], &name_buf));
    }
    _ = try parsePlayerLogin(full, &name_buf);
}

test "ally request round-trips both identities" {
    var body: [128]u8 = undefined;
    var w: binary.Writer = .{ .buf = &body };
    try platform_user.write(&w, .{ .platform = "Steam", .id = "1001" });
    try platform_user.write(&w, .{ .platform = "EOS", .id = "beef" });
    try w.writeBool(true);

    const req = try parseAllyRequest(w.written());
    try std.testing.expect(req.source.matches(.{ .platform = "Steam", .id = "1001" }));
    try std.testing.expect(req.target.matches(.{ .platform = "EOS", .id = "beef" }));
    try std.testing.expect(req.add_ally);
}
test "ally request with a null identity parses but is not actionable" {
    var body: [64]u8 = undefined;
    var w: binary.Writer = .{ .buf = &body };
    try platform_user.write(&w, null);
    try platform_user.write(&w, .{ .platform = "EOS", .id = "beef" });
    try w.writeBool(false);
    const full = w.written();

    const req = try parseAllyRequest(full);
    try std.testing.expect(req.source.get() == null);
    try std.testing.expect(req.target.get() != null);
    try std.testing.expect(!req.add_ally);
    // Missing the trailing addAlly bool is a short body, not a default.
    try std.testing.expectError(error.EndOfStream, parseAllyRequest(full[0 .. full.len - 1]));
}
test "ally response body layout" {
    var buf: [128]u8 = undefined;
    const out = try buildAllyResponseBody(
        &buf,
        .{ .platform = "Steam", .id = "1001" },
        .{ .platform = "Steam", .id = "1002" },
        1,
        3,
        6,
    );
    var r: binary.Reader = .{ .data = out };
    var plat: [platform_user.max_platform_len]u8 = undefined;
    var id: [platform_user.max_id_len]u8 = undefined;
    try std.testing.expectEqualStrings("1001", (try platform_user.read(&r, &plat, &id)).?.id);
    try std.testing.expectEqualStrings("1002", (try platform_user.read(&r, &plat, &id)).?.id);
    try std.testing.expectEqual(@as(u8, 1), try r.readByte());
    try std.testing.expectEqual(@as(u8, 3), try r.readByte());
    try std.testing.expectEqual(@as(u8, 6), try r.readByte());
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}
