//! NetPackageEntityAddExpClient body (ToClient XP grant; RE
//! ../7dtd-engine-research/il/netpackages-v3.1.0/NetPackageEntityAddExpClient_il.txt).
//!
//! `write` order after the package name: entityId i32, xp i32, xpType i16,
//! includeItem bool, then ItemValue only when includeItem. ProcessPackage
//! (IL=36) maps xpType == 0 to the "_xpFromKill" tag and anything else to
//! "_xpOther", so kill XP must use 0. zdtd never sends the optional ItemValue
//! (includeItem=false): the server grants plain XP, not item-tied XP.

const std = @import("std");
const binary = @import("binary.zig");
const stock_inv = @import("stock_inv.zig");

/// Stock XPTypes enum; the wire carries the i16 value. 0 = Kill (the client
/// tags it `_xpFromKill`), any other value = Other (`_xpOther`).
pub const xp_type_kill: i16 = 0;
pub const xp_type_other: i16 = 1;

pub const AddExpArgs = struct {
    entity_id: i32,
    xp: i32,
    xp_type: i16 = xp_type_other,
};

/// NetPackageEntityAddExpClient body: 4 + 4 + 2 + 1 = 11 bytes, no ItemValue.
pub fn buildAddExpClientBody(buf: []u8, args: AddExpArgs) ![]u8 {
    var w = binary.Writer{ .buf = buf };
    try w.writeI32(args.entity_id);
    try w.writeI32(args.xp);
    try w.writeI16(args.xp_type);
    try w.writeBool(false);
    return w.written();
}

test "add exp client body is the 11-byte stock shape" {
    var buf: [16]u8 = undefined;
    const body = try buildAddExpClientBody(&buf, .{ .entity_id = 42, .xp = 90, .xp_type = xp_type_kill });
    try std.testing.expectEqual(@as(usize, 11), body.len);
    var r = binary.Reader{ .data = body };
    try std.testing.expectEqual(@as(i32, 42), try r.readI32());
    try std.testing.expectEqual(@as(i32, 90), try r.readI32());
    try std.testing.expectEqual(@as(i16, 0), try r.readI16());
    try std.testing.expectEqual(false, try r.readBool());
}

/// NetPackagePlayerStats body: entityId i32 + EntityNetworkStats snapshot
/// (RE ../7dtd-engine-research/il/full-v3.1.0/_global/EntityAlive_EntityNetworkStats.il.txt
/// write IL=104; read order in 7dtd-engine-research/docs/progression.md).
///
/// The snapshot carries the whole progression picture to peers (party panel
/// level, tooltip name/kills). hasProgression=true with a minimal
/// Progression.Write blob (version 3, empty values) so the receiving side can
/// set Level/ExpToNextLevel; the blob is opaque bytes on the wire, so the
/// per-ProgressionValue list is not needed for the surface zdtd ships.
pub const PlayerStatsArgs = struct {
    entity_id: i32,
    entity_name: []const u8,
    level: u16,
    exp_to_next: i32,
    skill_points: u16 = 0,
    killed_zombies: i32 = 0,
    held_item: ?stock_inv.StockSlot = null,
};

/// Progression.Write v3 with an empty values list: version byte + Level u16 +
/// ExpToNextLevel i32 + SkillPoints u16 + count i32 + ExpDeficit i32.
pub fn writeMinimalProgression(w: *binary.Writer, level: u16, exp_to_next: i32, skill_points: u16) !void {
    try w.writeByte(3); // version
    try w.writeU16(level);
    try w.writeI32(exp_to_next);
    try w.writeU16(skill_points); // SkillPoints (ADR 0023 ledger balance)
    try w.writeI32(0); // progressionValueCount
    try w.writeI32(0); // ExpDeficit
}

pub fn buildPlayerStatsBody(buf: []u8, args: PlayerStatsArgs) ![]u8 {
    var w = binary.Writer{ .buf = buf };
    try w.writeI32(args.entity_id);
    // EntityNetworkStats fields, stock write order (IL=104).
    try w.writeI32(args.killed_zombies); // killed
    if (args.held_item) |hi| {
        try stock_inv.writeItemStack(&w, hi);
    } else {
        try w.writeU16(0); // empty ItemStack (count 0)
    }
    try w.writeByte(0); // holdingItemIndex
    try w.writeI32(0); // deathHealth
    try w.writeByte(0); // teamNumber
    try w.writeI32(0); // attachedToEntityId
    try w.writeString(args.entity_name);
    try w.writeBool(true); // isPlayer
    try w.writeI32(args.killed_zombies); // killedZombies
    try w.writeI32(0); // killedPlayers
    try w.writeI32(args.exp_to_next); // experience (stock Setup: ExpToNextLevel)
    try w.writeI32(args.level);
    try w.writeU32(0); // totalItemsCrafted
    try w.writeF32(0); // distanceWalked
    try w.writeF32(0); // longestLife
    try w.writeF32(0); // currentLife
    try w.writeF32(0); // totalTimePlayed
    try w.writeI32(0); // vehiclePose
    try w.writeBool(false); // isSpectator
    try w.writeBool(true); // hasProgression
    const len_off = w.pos;
    try w.writeI16(0); // progressionsData length, patched after the blob
    try writeMinimalProgression(&w, args.level, args.exp_to_next, args.skill_points);
    const blob_len: i16 = @intCast(w.pos - len_off - 2);
    std.mem.writeInt(i16, buf[len_off..][0..2], blob_len, .little);
    return w.written();
}

test "player stats body is the stock EntityNetworkStats shape" {
    var buf: [128]u8 = undefined;
    const body = try buildPlayerStatsBody(&buf, .{
        .entity_id = 42,
        .skill_points = 7,
        .entity_name = "Bot",
        .level = 3,
        .exp_to_next = 1000,
        .killed_zombies = 5,
    });
    var r = binary.Reader{ .data = body };
    try std.testing.expectEqual(@as(i32, 42), try r.readI32()); // entityId
    try std.testing.expectEqual(@as(i32, 5), try r.readI32()); // killed
    try std.testing.expectEqual(@as(u16, 0), try r.readU16()); // empty ItemStack
    try std.testing.expectEqual(@as(u8, 0), try r.readByte()); // holdingItemIndex
    try std.testing.expectEqual(@as(i32, 0), try r.readI32()); // deathHealth
    try std.testing.expectEqual(@as(u8, 0), try r.readByte()); // teamNumber
    try std.testing.expectEqual(@as(i32, 0), try r.readI32()); // attachedToEntityId
    try std.testing.expectEqualStrings("Bot", try r.readString(&buf)); // entityName
    try std.testing.expectEqual(true, try r.readBool()); // isPlayer
    try std.testing.expectEqual(@as(i32, 5), try r.readI32()); // killedZombies
    try std.testing.expectEqual(@as(i32, 0), try r.readI32()); // killedPlayers
    try std.testing.expectEqual(@as(i32, 1000), try r.readI32()); // experience = ExpToNextLevel
    try std.testing.expectEqual(@as(i32, 3), try r.readI32()); // level
    try std.testing.expectEqual(@as(u32, 0), try r.readU32()); // totalItemsCrafted
    _ = try r.readF32(); // distanceWalked
    _ = try r.readF32(); // longestLife
    _ = try r.readF32(); // currentLife
    _ = try r.readF32(); // totalTimePlayed
    try std.testing.expectEqual(@as(i32, 0), try r.readI32()); // vehiclePose
    try std.testing.expectEqual(false, try r.readBool()); // isSpectator
    try std.testing.expectEqual(true, try r.readBool()); // hasProgression
    const blob_len = try r.readI16();
    try std.testing.expectEqual(@as(i16, 17), blob_len);
    try std.testing.expectEqual(@as(u8, 3), try r.readByte()); // Progression version
    try std.testing.expectEqual(@as(u16, 3), try r.readU16()); // Level
    try std.testing.expectEqual(@as(i32, 1000), try r.readI32()); // ExpToNextLevel
    try std.testing.expectEqual(@as(u16, 7), try r.readU16()); // SkillPoints
    try std.testing.expectEqual(@as(i32, 0), try r.readI32()); // count
    try std.testing.expectEqual(@as(i32, 0), try r.readI32()); // ExpDeficit
    try std.testing.expect(r.remaining() == 0);
}

/// NetPackageEntityAddScoreClient body: entityId i32, zombieKills i16,
/// playerKills i16, otherTeamNumber i16, conditions i32 (RE
/// ../7dtd-engine-research/il/netpackages-v3.1.0/NetPackageEntityAddScoreClient_il.txt
/// write IL=27; the struct fields are Int32 narrowed to i16 on the wire).
/// Stock sends it on every kill so the client's character sheet shows the
/// running zombie/player kill counters.
pub const AddScoreArgs = struct {
    entity_id: i32,
    zombie_kills: u16,
    player_kills: u16 = 0,
    other_team_number: u16 = 0,
    conditions: i32 = 0,
};

pub fn buildAddScoreBody(buf: []u8, args: AddScoreArgs) ![]u8 {
    var w = binary.Writer{ .buf = buf };
    try w.writeI32(args.entity_id);
    try w.writeI16(@intCast(args.zombie_kills));
    try w.writeI16(@intCast(args.player_kills));
    try w.writeI16(@intCast(args.other_team_number));
    try w.writeI32(args.conditions);
    return w.written();
}

test "add score body is the 14-byte stock shape" {
    var buf: [16]u8 = undefined;
    const body = try buildAddScoreBody(&buf, .{ .entity_id = 42, .zombie_kills = 7 });
    try std.testing.expectEqual(@as(usize, 14), body.len);
    var r = binary.Reader{ .data = body };
    try std.testing.expectEqual(@as(i32, 42), try r.readI32());
    try std.testing.expectEqual(@as(i16, 7), try r.readI16());
    try std.testing.expectEqual(@as(i16, 0), try r.readI16());
    try std.testing.expectEqual(@as(i16, 0), try r.readI16());
    try std.testing.expectEqual(@as(i32, 0), try r.readI32());
}

/// NetPackageEntityVelocity body: entityId i32 | bAdd bool | motion Vector3
/// (3 x f32). RE ../7dtd-engine-research/il/netpackages-v3.1.0/NetPackageEntityVelocity_il.txt
/// write IL=23 (NetPackageEntityTargeted base + bAdd + motion). bAdd=true
/// means AddMotion: the client adds the vector to the entity's current motion
/// (hit shove / knockback).
pub const VelocityArgs = struct {
    entity_id: i32,
    b_add: bool = true,
    dx: f32 = 0,
    dy: f32 = 0,
    dz: f32 = 0,
};

pub fn buildEntityVelocityBody(buf: []u8, args: VelocityArgs) ![]u8 {
    var w = binary.Writer{ .buf = buf };
    try w.writeI32(args.entity_id);
    try w.writeBool(args.b_add);
    try w.writeF32(args.dx);
    try w.writeF32(args.dy);
    try w.writeF32(args.dz);
    return w.written();
}

test "entity velocity body is the 17-byte stock shape" {
    var buf: [32]u8 = undefined;
    const body = try buildEntityVelocityBody(&buf, .{ .entity_id = 42, .dx = 1, .dy = 0, .dz = -1 });
    try std.testing.expectEqual(@as(usize, 17), body.len);
    var r = binary.Reader{ .data = body };
    try std.testing.expectEqual(@as(i32, 42), try r.readI32());
    try std.testing.expectEqual(true, try r.readBool());
    try std.testing.expectEqual(@as(f32, 1), try r.readF32());
    try std.testing.expectEqual(@as(f32, 0), try r.readF32());
    try std.testing.expectEqual(@as(f32, -1), try r.readF32());
}

/// NetPackageEntitySetSkillLevelClient body: entityId i32 | skill string |
/// level i32 (RE netpackage-bodies.md). Sent on a successful purchase.
pub fn buildEntitySetSkillLevelBody(buf: []u8, entity_id: i32, skill: []const u8, level: i32) ![]u8 {
    var w = binary.Writer{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeString(skill);
    try w.writeI32(level);
    return w.written();
}
