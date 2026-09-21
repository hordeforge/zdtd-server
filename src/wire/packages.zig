//! Golden package body builders/parsers for join, motion, damage, spawn, TE.
//! Prefer this facade for all wire/stock_* body modules (and te_types); leaf
//! files stay importable. lint-architecture enforces stock_* re-exports here.
//!
//! Buffer contract: every `buildXxx*` takes a caller-owned `buf` and returns
//! the written slice (`![]u8`); no builder allocates. Callers size `buf` from
//! the named `*_size` / `max_*` constants and handle error.Overflow.

const std = @import("std");
const binary = @import("binary.zig");
const frame = @import("frame.zig");
const components = @import("../ecs/components.zig");
pub const platform_user = @import("platform_user.zig");
pub const stock_inv = @import("stock_inv.zig");
pub const stock_chunk = @import("stock_chunk.zig");
pub const stock_deco = @import("stock_deco.zig");
pub const stock_nameid = @import("stock_nameid.zig");
pub const stock_entity = @import("stock_entity.zig");
pub const stock_quest = @import("stock_quest.zig");
pub const stock_buff = @import("stock_buff.zig");
pub const stock_te = @import("stock_te.zig");
pub const stock_sign = @import("stock_sign.zig");
pub const stock_party = @import("stock_party.zig");
pub const stock_xp = @import("stock_xp.zig");
pub const te_types = @import("te_types.zig");

pub const stock_ids = @import("stock_ids.zig");
pub const PackageName = stock_ids.PackageName;
pub const default_mappings = stock_ids.default_mappings;
pub const idOf = stock_ids.idOf;
pub const VersionInfo = stock_ids.VersionInfo;
pub const buildPackageIdsBody = stock_ids.buildPackageIdsBody;

pub const stock_loginanswer = @import("stock_loginanswer.zig");
pub const buildLoginAnswerBody = stock_loginanswer.buildLoginAnswerBody;

pub const stock_localization = @import("stock_localization.zig");
pub const buildLocalizationBody = stock_localization.buildLocalizationBody;

pub const stock_configfile = @import("stock_configfile.zig");
pub const buildConfigFileBody = stock_configfile.buildConfigFileBody;

/// Stock NetPackagePlayerId body (derived V3.0.1, live against V3.1.0 b14):
/// id:i32 | team:i16 | PlayerDataFile.WriteNetwork | chunkViewDim:i32
/// Empty PDF matches a fresh PlayerDataFile() so stock ReadNetwork completes without EOF.
/// `sx,sy,sz` are world spawn coords written into ECD pos + lastSpawnPosition so the
/// local player is not created at (0,0,0) (which floods SkyManager/SignTexture NREs).
pub const stock_playerid = @import("stock_playerid.zig");
pub const PlayerIdOpts = stock_playerid.PlayerIdOpts;
pub const buildPlayerIdBody = stock_playerid.buildPlayerIdBody;
pub const buildPlayerIdBodyInv = stock_playerid.buildPlayerIdBodyInv;
pub const game_stage_born_unset = stock_playerid.game_stage_born_unset;
pub const buildPlayerIdBodyWithOpts = stock_playerid.buildPlayerIdBodyWithOpts;
pub const buildPlayerIdBodyInvLoaded = stock_playerid.buildPlayerIdBodyInvLoaded;
pub const RespawnType = stock_playerid.RespawnType;
pub const buildSpawnedBody = stock_playerid.buildSpawnedBody;
pub const parseSpawnedBody = stock_playerid.parseSpawnedBody;
const writeEmptyPlayerDataFileNetwork = stock_playerid.writeEmptyPlayerDataFileNetwork;

pub const stock_motion = @import("stock_motion.zig");
pub const buildPosAndRotBody = stock_motion.buildPosAndRotBody;
pub const buildEntityTeleportBody = stock_motion.buildEntityTeleportBody;
pub const buildEntitySpawnResponse = stock_motion.buildEntitySpawnResponse;
pub const TraderStockEntry = stock_trade.TraderStockEntry;
pub const buildTraderDataStock = stock_trade.buildTraderDataStock;
pub const parsePosAndRotBody = stock_motion.parsePosAndRotBody;
pub const buildRelPosBody = stock_motion.buildRelPosBody;
pub const cF_approaching_player: u16 = stock_motion.cF_approaching_player;
pub const cF_spawned: u16 = stock_motion.cF_spawned;
pub const cF_is_alert: u16 = stock_motion.cF_is_alert;
pub const cF_crouching: u16 = stock_motion.cF_crouching;
pub const buildAliveFlagsBody = stock_motion.buildAliveFlagsBody;
pub const parseAliveFlagsBody = stock_motion.parseAliveFlagsBody;
pub const buildEntitySpeedsBody = stock_motion.buildEntitySpeedsBody;
pub const parseEntitySpeedsBody = stock_motion.parseEntitySpeedsBody;
pub const parsePlayerDataEcdHead = stock_motion.parsePlayerDataEcdHead;
const readWorldF32 = stock_motion.readWorldF32;
const readWorldI32 = stock_motion.readWorldI32;

test "entity speeds body roundtrip" {
    var buf: [32]u8 = undefined;
    const body = try buildEntitySpeedsBody(&buf, 106, 2, 1.25, -0.5);
    const p = try parseEntitySpeedsBody(body);
    try std.testing.expectEqual(@as(i32, 106), p.entity_id);
    try std.testing.expectEqual(@as(u8, 2), p.movement_state);
    try std.testing.expectApproxEqAbs(@as(f32, 1.25), p.speed_forward, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), p.speed_strafe, 0.001);
}

test "player data ecd head from empty pdf write" {
    var buf: [4096]u8 = undefined;
    var w: binary.Writer = .{ .buf = &buf };
    try writeEmptyPlayerDataFileNetwork(&w, 106, -273, 61, 449, .{});
    const body = w.written();
    const h = try parsePlayerDataEcdHead(body);
    try std.testing.expectEqual(@as(i32, 106), h.entity_id);
    // The parser no longer returns the position (origin-relative, unusable
    // server-side), but the bytes must still sit where the ECD head puts them,
    // or the length validation above would be checking the wrong layout:
    // FileVersion u8 | entityClass i32 | id i32 | lifetime f32 | pos f32 x3.
    const pos_off = 1 + 4 + 4 + 4;
    const px: f32 = @bitCast(std.mem.readInt(u32, body[pos_off..][0..4], .little));
    const py: f32 = @bitCast(std.mem.readInt(u32, body[pos_off + 4 ..][0..4], .little));
    const pz: f32 = @bitCast(std.mem.readInt(u32, body[pos_off + 8 ..][0..4], .little));
    try std.testing.expectApproxEqAbs(@as(f32, -273), px, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 61), py, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 449), pz, 0.01);
}

test "player id body wraps the PDF with entityId, team and chunkViewDim" {
    // NetPackagePlayerId (RE write IL=21) is entityId i32 | team i16 |
    // PlayerDataFile.WriteNetwork | chunkViewDim i32. The join path builds it
    // (game.zig) and no wire test covered the frame around the PDF, only the
    // ECD head inside it, so the three outer fields and this body's own copy
    // of the ECD position run had nothing reading them back.
    var buf: [8192]u8 = undefined;
    const body = try buildPlayerIdBodyInvLoaded(
        &buf,
        106, // entity id
        7, // team: distinct from every neighbouring constant
        5, // chunkViewDim
        -273,
        61,
        449,
        &.{},
        &.{},
        &.{},
        &.{},
        true,
        game_stage_born_unset,
    );
    try std.testing.expectEqual(@as(i32, 106), std.mem.readInt(i32, body[0..4], .little));
    try std.testing.expectEqual(@as(i16, 7), std.mem.readInt(i16, body[4..6], .little));
    // chunkViewDim closes the body.
    try std.testing.expectEqual(@as(i32, 5), std.mem.readInt(i32, body[body.len - 4 ..][0..4], .little));

    // The PDF's ECD head starts at byte 6: FileVersion u8 | entityClass i32 |
    // id i32 | lifetime f32 | pos f32 x3.
    const ecd = 6;
    try std.testing.expectEqual(@as(u8, 36), body[ecd]);
    try std.testing.expectEqual(stock_entity.class_player_male, std.mem.readInt(i32, body[ecd + 1 ..][0..4], .little));
    try std.testing.expectEqual(@as(i32, 106), std.mem.readInt(i32, body[ecd + 5 ..][0..4], .little));
    const f32At = struct {
        fn get(b: []const u8, off: usize) f32 {
            return @bitCast(std.mem.readInt(u32, b[off..][0..4], .little));
        }
    }.get;
    try std.testing.expectEqual(std.math.floatMax(f32), f32At(body, ecd + 9)); // lifetime
    try std.testing.expectApproxEqAbs(@as(f32, -273), f32At(body, ecd + 13), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 61), f32At(body, ecd + 17), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 449), f32At(body, ecd + 21), 0.01);

    // Then rot f32 x3 | onGround bool | BodyDamage (cBinaryVersion 4, type 0,
    // flags 0) | hasStats bool | deathTime i16 | hasBag bool | homePosition
    // i32 x3 | homeRange i16 | spawnerSource u8. None of that was read back,
    // so the version 4 could swap with the zero beside it and homePosition's
    // three words could rotate.
    const after_rot = ecd + 25 + 12; // past pos, rot
    try std.testing.expectEqual(@as(u8, 1), body[after_rot]); // onGround
    const bd = after_rot + 1;
    try std.testing.expectEqual(@as(i32, 4), std.mem.readInt(i32, body[bd..][0..4], .little));
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, body[bd + 4 ..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, body[bd + 8 ..][0..4], .little));
    const home = bd + 12 + 1 + 2 + 1; // past hasStats, deathTime, hasBag
    try std.testing.expectEqual(@as(i32, -273), std.mem.readInt(i32, body[home..][0..4], .little));
    try std.testing.expectEqual(@as(i32, 61), std.mem.readInt(i32, body[home + 4 ..][0..4], .little));
    try std.testing.expectEqual(@as(i32, 449), std.mem.readInt(i32, body[home + 8 ..][0..4], .little));
    try std.testing.expectEqual(@as(i16, -1), std.mem.readInt(i16, body[home + 12 ..][0..2], .little));
}

test "player id PDF bag is CarryCapacity empties" {
    var buf: [8192]u8 = undefined;
    // Non-empty starter-like stacks in bag[0..3]; rest must pad empty.
    var bag: [4]stock_inv.StockSlot = .{
        .{ .type_id = stock_inv.items_start_here + 8, .count = 1 },
        .{ .type_id = stock_inv.items_start_here + 2, .count = 5 },
        .{ .type_id = stock_inv.items_start_here + 7, .count = 20 },
        .{ .type_id = stock_inv.items_start_here + 6, .count = 50 },
    };
    const body = try buildPlayerIdBodyInv(&buf, 171, 0, 4, -273, 61, 449, &.{}, &.{}, &.{}, bag[0..]);
    var r: binary.Reader = .{ .data = body };
    _ = try r.readI32(); // entity
    _ = try r.readI16(); // team
    // Skip ECD via stock_inv helper (player branch + v36 stress).
    _ = try stock_inv.skipEcdNetworkWriteFalse(&r);
    const tb_n = try r.readU16();
    try std.testing.expectEqual(@as(u16, @intCast(stock_inv.toolbelt_slots)), tb_n);
    var i: usize = 0;
    while (i < tb_n) : (i += 1) {
        const c = try r.readU16();
        try std.testing.expectEqual(@as(u16, 0), c);
    }
    _ = try r.readByte(); // selected
    try std.testing.expectEqual(@as(u8, 1), try r.readByte()); // bag ver
    const bag_n = try r.readU16();
    try std.testing.expectEqual(@as(u16, @intCast(stock_inv.bag_slots)), bag_n);
    var nonempty: usize = 0;
    i = 0;
    while (i < bag_n) : (i += 1) {
        const c = try r.readU16();
        if (c != 0) {
            nonempty += 1;
            // skip ItemValue v9 minimal
            try std.testing.expectEqual(@as(u8, 9), try r.readByte());
            _ = try r.readByte(); // flags
            _ = try r.readU16(); // type
            _ = try r.readF32();
            _ = try r.readU16();
            _ = try r.readU16();
            _ = try r.readByte(); // meta count
            _ = try r.readByte();
            _ = try r.readByte(); // mods
            _ = try r.readByte();
            _ = try r.readByte();
            _ = try r.readU16();
            _ = try r.readBool();
        }
    }
    try std.testing.expectEqual(@as(usize, 4), nonempty);
}

pub const stock_remove = @import("stock_remove.zig");
pub const RemoveEntityReason = stock_remove.RemoveEntityReason;
pub const buildRemoveBody = stock_remove.buildRemoveBody;
pub const buildRemoveBodyReason = stock_remove.buildRemoveBodyReason;

pub const stock_bloodmoon = @import("stock_bloodmoon.zig");
pub const buildBloodmoonMusicBody = stock_bloodmoon.buildBloodmoonMusicBody;

pub const stock_sleeper = @import("stock_sleeper.zig");
pub const buildSleeperWakeupBody = stock_sleeper.buildSleeperWakeupBody;
pub const buildSleeperPassiveChangeBody = stock_sleeper.buildSleeperPassiveChangeBody;

pub const stock_lookat = @import("stock_lookat.zig");
pub const buildEntityLookAtBody = stock_lookat.buildEntityLookAtBody;

/// Chunk + minimap-map wire bodies. Lives in stock_map.zig; re-exported
/// here so existing `packages.buildChunkBody` / `packages.MapChunkPiece`
/// call sites keep working.
pub const stock_map = @import("stock_map.zig");
pub const MapChunkPiece = stock_map.MapChunkPiece;
pub const buildMapChunksBody = stock_map.buildMapChunksBody;
pub const chunk_body_size: usize = stock_map.chunk_body_size;
pub const chunk_stock_envelope_overhead: usize = stock_map.chunk_stock_envelope_overhead;
pub const makeChunkKey = stock_map.makeChunkKey;
pub const extractChunkKeyX = stock_map.extractChunkKeyX;
pub const extractChunkKeyZ = stock_map.extractChunkKeyZ;
pub const buildChunkPayload = stock_map.buildChunkPayload;
pub const buildChunkBody = stock_map.buildChunkBody;
pub const ChunkParsed = stock_map.ChunkParsed;
pub const parseChunkBody = stock_map.parseChunkBody;

pub const stock_horde = @import("stock_horde.zig");
pub const HordeEvent = stock_horde.HordeEvent;
pub const buildHordeEventBody = stock_horde.buildHordeEventBody;

/// NetPackageDamageEntity (V3.2.0 packed-flags head + 30-field stock body).
/// Lives in stock_damage.zig; re-exported here so existing `packages.dmg_*`
/// and `packages.buildDamageBody` call sites keep working.
pub const stock_damage = @import("stock_damage.zig");
pub const dmg_can_hit_special: u32 = stock_damage.dmg_can_hit_special;
pub const dmg_cripple_legs: u32 = stock_damage.dmg_cripple_legs;
pub const dmg_critical: u32 = stock_damage.dmg_critical;
pub const dmg_dismember: u32 = stock_damage.dmg_dismember;
pub const dmg_fatal: u32 = stock_damage.dmg_fatal;
pub const dmg_from_buff: u32 = stock_damage.dmg_from_buff;
pub const dmg_ignore_consecutive: u32 = stock_damage.dmg_ignore_consecutive;
pub const dmg_ignore_party_share: u32 = stock_damage.dmg_ignore_party_share;
pub const dmg_pain_hit: u32 = stock_damage.dmg_pain_hit;
pub const dmg_turn_into_crawler: u32 = stock_damage.dmg_turn_into_crawler;
pub const dmg_trap_kill_xp: u32 = stock_damage.dmg_trap_kill_xp;
pub const buildDamageBody = stock_damage.buildDamageBody;
pub const parseDamageHead = stock_damage.parseDamageHead;

test "ConfirmSpawnEntity golden layout: i64 id + 16-byte request key (V3.2.0)" {
    const key = [16]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    var buf: [32]u8 = undefined;
    const body = try buildConfirmSpawnEntityBody(&buf, -5, &key);
    try std.testing.expectEqual(@as(usize, 24), body.len);
    try std.testing.expectEqual(@as(i64, -5), std.mem.readInt(i64, body[0..8], .little));
    try std.testing.expectEqualSlices(u8, &key, body[8..24]);
}

/// Stock `PrefabInstance.POIMetadata` record (read ctor IL=35, changelog-3.2.0
/// §3.2): the minimal per-POI metadata the client's DynamicPrefabDecorator
/// consumes for LOD/trader rendering.
pub const PoiMetadata = struct {
    x: i32,
    y: i32,
    z: i32,
    size_x: i32,
    size_y: i32,
    size_z: i32,
    rotation: u8,
    tier: u8,
    trader_area: bool,
    prefab_name: []const u8,
    tags: []const u8,
    quest_tags: []const u8,
};

/// Cap on POI metadata records per response (a stock map ships a few hundred
/// POIs; the frame stays well inside the compressed budget).
pub const max_poi_metadata: usize = 512;

/// NetPackagePOIMetadataResponse body: count:i32 + POIMetadata records
/// (compressed on the wire, channel 1).
pub fn buildPoiMetadataResponse(buf: []u8, records: []const PoiMetadata) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(@intCast(@min(records.len, max_poi_metadata)));
    const n = @min(records.len, max_poi_metadata);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const r = records[i];
        try w.writeI32(r.x);
        try w.writeI32(r.y);
        try w.writeI32(r.z);
        try w.writeI32(r.size_x);
        try w.writeI32(r.size_y);
        try w.writeI32(r.size_z);
        try w.writeByte(r.rotation);
        try w.writeByte(r.tier);
        try w.writeBool(r.trader_area);
        try w.writeString(r.prefab_name);
        try w.writeString(r.tags);
        try w.writeString(r.quest_tags);
    }
    return w.written();
}

test "POI metadata response: 512 dense records fit the response buffer" {
    // Regression (2026-08-29 Pregen soak): the handler built into a 64 KiB
    // slice, and 512 records with real prefab names/tags exceed it, so the
    // response silently never shipped on dense maps. The handler now uses a
    // 256 KiB slice; this pins that the worst-case record count fits.
    var records: [max_poi_metadata]PoiMetadata = undefined;
    for (&records, 0..) |*r, i| {
        r.* = .{
            .x = @intCast(i),
            .y = 0,
            .z = 0,
            .size_x = 10,
            .size_y = 8,
            .size_z = 10,
            .rotation = 0,
            .tier = 3,
            .trader_area = false,
            .prefab_name = "house_old_brick_02_police_station_red_wasteland_abandoned",
            .tags = "wasteland,house,red,day,residential,abandoned,police",
            .quest_tags = "town,residential,abandoned,police,crime,disturbance",
        };
    }
    var buf: [262144]u8 = undefined;
    const body = try buildPoiMetadataResponse(&buf, &records);
    try std.testing.expect(body.len > 65536); // the old slice could not hold it
    try std.testing.expect(body.len < buf.len);

    // Size alone says nothing about field order, and the record above cannot
    // say it either: y, z and rotation all sit at 0. Build one record with a
    // distinct value everywhere and read it back - the client keys map markers
    // and quest offers off these, so a rotated triple misplaces a POI.
    const one = [_]PoiMetadata{.{
        .x = 11,
        .y = 12,
        .z = 13,
        .size_x = 21,
        .size_y = 22,
        .size_z = 23,
        .rotation = 2,
        .tier = 5,
        .trader_area = true,
        .prefab_name = "p",
        .tags = "t",
        .quest_tags = "q",
    }};
    var one_buf: [512]u8 = undefined;
    const b = try buildPoiMetadataResponse(&one_buf, &one);
    try std.testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, b[0..4], .little)); // count
    try std.testing.expectEqual(@as(i32, 11), std.mem.readInt(i32, b[4..8], .little));
    try std.testing.expectEqual(@as(i32, 12), std.mem.readInt(i32, b[8..12], .little));
    try std.testing.expectEqual(@as(i32, 13), std.mem.readInt(i32, b[12..16], .little));
    try std.testing.expectEqual(@as(i32, 21), std.mem.readInt(i32, b[16..20], .little));
    try std.testing.expectEqual(@as(i32, 22), std.mem.readInt(i32, b[20..24], .little));
    try std.testing.expectEqual(@as(i32, 23), std.mem.readInt(i32, b[24..28], .little));
    try std.testing.expectEqual(@as(u8, 2), b[28]); // rotation
    try std.testing.expectEqual(@as(u8, 5), b[29]); // tier
    try std.testing.expectEqual(@as(u8, 1), b[30]); // traderArea
}

/// NetPackageConfirmSpawnEntity body (V3.2.0, changelog-3.2.0 §3.3):
/// createdEntityId:i64 (an Int32 field widened on write) + requestKey
/// Guid.ToByteArray bytes[16]. Sent only for client-requested entity spawns
/// (EntityCreationData.requestedBy/requestKey). zdtd drops generic spawn
/// requests (c2s/misc.zig RequestToSpawnEntity), so no live flow emits this;
/// the builder pins the shape for that path and for goldens.
pub fn buildConfirmSpawnEntityBody(buf: []u8, created_entity_id: i64, key: *const [16]u8) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI64(created_entity_id);
    try w.writeBytes(key);
    return w.written();
}

/// NetPackageRequestToSpawnPlayer (RE inventories/netpackage-bodies.md write
/// IL=17, protocol.md §5): `chunkViewDim` i16 | `playerProfile`
/// (PlayerProfile.Write) | `nearEntityId` i32.
///
/// Only `chunkViewDim` is read. The profile is the client's display copy and
/// the server owns the real one, so parsing it would buy nothing; `nearEntityId`
/// sits behind that variable-length blob and is unused server-side. It used to
/// be grabbed from the last four bytes without parsing the profile, which is a
/// guess rather than a read: on a short body those four bytes overlap
/// chunkViewDim itself. Reading a field we do not use, from an offset we did
/// not derive, is strictly worse than not reading it.
pub fn parseRequestToSpawnPlayer(body: []const u8) !struct { chunk_view_dim: i32 } {
    if (body.len < 2) return error.EndOfStream;
    var r: binary.Reader = .{ .data = body };
    return .{ .chunk_view_dim = try r.readI16() };
}

/// The client's `PlayerProfile` out of a `NetPackageRequestToSpawnPlayer` body
/// (stock read IL=14: `chunkViewDim:i16`, then `PlayerProfile::Read`). Separate
/// from parseRequestToSpawnPlayer so a body without the profile still yields
/// the dim, and a malformed profile leaves the caller on its default
/// appearance instead of dropping the spawn.
pub fn parseRequestToSpawnProfile(body: []const u8) !stock_entity.OwnedProfile {
    if (body.len < 2 + 4) return error.EndOfStream;
    var r: binary.Reader = .{ .data = body };
    _ = try r.readI16();
    return stock_entity.readOwnedProfile(&r);
}

test "RequestToSpawnPlayer reads only the leading chunkViewDim" {
    // A bare two-byte body is legal: everything after chunkViewDim is the
    // client's profile blob plus a field the server does not use.
    var two: [2]u8 = undefined;
    std.mem.writeInt(i16, &two, 4, .little);
    try std.testing.expectEqual(@as(i32, 4), (try parseRequestToSpawnPlayer(&two)).chunk_view_dim);

    // A trailing blob must not change what is read. The old code took the last
    // four bytes as nearEntityId, so a body this shape used to reinterpret its
    // own header bytes; asserting the dim is stable pins that it no longer
    // depends on the body's length.
    var long: [24]u8 = @splat(0xAB);
    std.mem.writeInt(i16, long[0..2], 4, .little);
    try std.testing.expectEqual(@as(i32, 4), (try parseRequestToSpawnPlayer(&long)).chunk_view_dim);

    // Shorter than the one field it does read is an error, not a zero.
    var one: [1]u8 = .{0};
    try std.testing.expectError(error.EndOfStream, parseRequestToSpawnPlayer(&one));
}

test "the client's profile round-trips out of RequestToSpawnPlayer" {
    // Body shape from NetPackageRequestToSpawnPlayer (read IL=14):
    // chunkViewDim:i16 | PlayerProfile (v5) | nearEntityId:i32.
    var buf: [256]u8 = undefined;
    var w: binary.Writer = .{ .buf = &buf };
    try w.writeI16(4);
    try stock_entity.writePlayerProfile(&w, .{
        .archetype = "BaseFemale",
        .is_male = false,
        .race_name = "Black",
        .variant_number = 3,
        .hair_name = "hairFemaleShort",
        .hair_color = "0,0,0",
        .mustache_name = "",
        .chops_name = "",
        .beard_name = "",
        .eye_color = "Green01",
    });
    try w.writeI32(-1);
    const body = w.written();

    const p = try parseRequestToSpawnProfile(body);
    try std.testing.expectEqualStrings("BaseFemale", p.view().archetype);
    try std.testing.expect(!p.view().is_male);
    try std.testing.expectEqualStrings("Black", p.view().race_name);
    try std.testing.expectEqual(@as(u8, 3), p.view().variant_number);
    try std.testing.expectEqualStrings("hairFemaleShort", p.view().hair_name);
    try std.testing.expectEqualStrings("Green01", p.view().eye_color);
    // The dim still parses from the same body.
    try std.testing.expectEqual(@as(i32, 4), (try parseRequestToSpawnPlayer(body)).chunk_view_dim);
    // A body without the profile blob yields the dim and no profile.
    var dim_only: [2]u8 = undefined;
    std.mem.writeInt(i16, &dim_only, 6, .little);
    try std.testing.expectError(error.EndOfStream, parseRequestToSpawnProfile(&dim_only));
    try std.testing.expectEqual(@as(i32, 6), (try parseRequestToSpawnPlayer(&dim_only)).chunk_view_dim);
}

test "a received profile drives the PDF player class and appearance" {
    var pbuf: [256]u8 = undefined;
    var pw: binary.Writer = .{ .buf = &pbuf };
    try pw.writeI16(4);
    try stock_entity.writePlayerProfile(&pw, .{
        .archetype = "BaseFemale",
        .is_male = false,
        .race_name = "Black",
        .variant_number = 3,
        .eye_color = "Green01",
    });
    try pw.writeI32(0);
    const prof = try parseRequestToSpawnProfile(pw.written());

    var buf: [4096]u8 = undefined;
    const body = try buildPlayerIdBodyWithOpts(&buf, 7, 0, 4, 1, 2, 3, .{
        .profile = prof.view(),
        .player_name = "Ann",
    });
    // id i32 + team i16, then the ECD FileVersion byte and the entityClass:
    // the female player class.
    try std.testing.expectEqual(@as(u8, 36), body[6]);
    try std.testing.expectEqual(@as(i32, stock_entity.class_player_female), std.mem.readInt(i32, body[7..11], .little));
    try std.testing.expect(std.mem.find(u8, body, "BaseFemale") != null);
    try std.testing.expect(std.mem.find(u8, body, "Green01") != null);
    try std.testing.expect(std.mem.find(u8, body, "Ann") != null);
    // Without a profile the body keeps the offline default (male class).
    const dflt = try buildPlayerIdBodyWithOpts(&buf, 7, 0, 4, 1, 2, 3, .{});
    try std.testing.expectEqual(@as(i32, stock_entity.class_player_male), std.mem.readInt(i32, dflt[7..11], .little));
    try std.testing.expect(std.mem.find(u8, dflt, "BaseMale") != null);
}

/// Stock NetPackageSetBlock body (derived V3.0.1, live against V3.1.0 b14):
/// PlatformUserIdentifierAbs (bool + optional platform/id) |
/// i16 changeCount | BlockChangeInfo* | i32 localPlayerThatChanged
///
/// Minimal BlockChangeInfo: BlockValueRef(pos) + entityId + flags + BlockValue.
/// BlockValue: u32 rawData (type in low 16 bits) + u16 damage.
/// BlockValueRef type 1 = world position Vector3i.
/// BlockChangeInfo::Write flag bits (asm.il:1100162). Only value/density/texture
/// carry payload bytes; damage/forceDensity/updateLight are pure booleans that
/// change how the receiver applies the change, so a reader that rejects them
/// drops perfectly ordinary stock edits. WorldBase::SetBlockRPC(bvRef, bv)
/// (asm.il:1248595) always sets bUpdateLight, so a plain block flip is 0x11.
const block_change_flag_value: u8 = stock_block.block_change_flag_value;
const block_change_flag_damage: u8 = stock_block.block_change_flag_damage;
const block_change_flag_density: u8 = stock_block.block_change_flag_density;
const block_change_flag_force_density: u8 = stock_block.block_change_flag_force_density;
const block_change_flag_update_light: u8 = stock_block.block_change_flag_update_light;
const block_change_flag_texture: u8 = stock_block.block_change_flag_texture;
const block_change_flags_known: u8 = stock_block.block_change_flags_known;
const block_type_mask: u32 = stock_block.block_type_mask;
pub const block_meta_powered: u8 = stock_block.block_meta_powered;
pub const block_meta_on: u8 = stock_block.block_meta_on;
pub const blockMeta = stock_block.blockMeta;
pub const withBlockMeta = stock_block.withBlockMeta;

pub const stock_block = @import("stock_block.zig");
pub const buildSetBlockBody = stock_block.buildSetBlockBody;
pub const buildSetBlockBodyDamage = stock_block.buildSetBlockBodyDamage;
pub const buildSetBlockBodyRaw = stock_block.buildSetBlockBodyRaw;
pub const BlockChange = stock_block.BlockChange;
pub const parseSetBlockBody = stock_block.parseSetBlockBody;
pub const parseSetBlockChanges = stock_block.parseSetBlockChanges;
pub const WaterSetChange = stock_block.WaterSetChange;
pub const parseWaterSet = stock_block.parseWaterSet;
pub const buildWaterSetBody = stock_block.buildWaterSetBody;
pub const AudioPlay = stock_block.AudioPlay;
pub const parseAudioPlay = stock_block.parseAudioPlay;
pub const buildAudioPlayBody = stock_block.buildAudioPlayBody;

/// `NetPackageQuestTreasurePoint/QuestPointActions`
/// (NetPackageQuestTreasurePoint_QuestPointActions.il.txt:3).
pub const quest_point_get_goto: u8 = 0;
pub const quest_point_get_treasure: u8 = 1;
pub const quest_point_update_treasure: u8 = 2;
pub const quest_point_update_blocks: u8 = 3;

/// `NetPackageQuestTreasurePoint` body. The layout branches on the leading
/// `ActionType` byte (read IL=54, NetPackageQuestTreasurePoint.il.txt:125):
/// action 2 carries only `questCode` i32 + `position` Vector3i; every other
/// action carries the full request/response form.
pub const QuestTreasurePoint = struct {
    action: u8 = 0,
    player_id: i32 = 0,
    distance: f32 = 0,
    offset: i32 = 0,
    treasure_radius: f32 = 0,
    blocks_per_reduction: i32 = 0,
    quest_code: i32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
    off_x: f32 = 0,
    off_y: f32 = 0,
    off_z: f32 = 0,
    use_nearby: bool = false,
};

/// Read side of the branch above (stock `NetPackageQuestTreasurePoint::read`
/// IL=54, NetPackageQuestTreasurePoint.il.txt:125): `ActionType` u8, then for
/// action 2 only `questCode` i32 + `position` Vector3i, else `playerId` i32,
/// `distance` f32, `offset` i32, `treasureRadius` f32, `blocksPerReduction`
/// i32, `questCode` i32, `position` Vector3i, `treasureOffset` Vector3 and
/// `useNearby` bool.
pub fn parseQuestTreasurePoint(body: []const u8) binary.ReadError!QuestTreasurePoint {
    var r: binary.Reader = .{ .data = body };
    var out: QuestTreasurePoint = .{ .action = try r.readByte() };
    if (out.action == quest_point_update_treasure) {
        out.quest_code = try r.readI32();
        out.x = try r.readI32();
        out.y = try r.readI32();
        out.z = try r.readI32();
        return out;
    }
    out.player_id = try r.readI32();
    out.distance = try r.readF32();
    out.offset = try r.readI32();
    out.treasure_radius = try r.readF32();
    out.blocks_per_reduction = try r.readI32();
    out.quest_code = try r.readI32();
    out.x = try r.readI32();
    out.y = try r.readI32();
    out.z = try r.readI32();
    out.off_x = try r.readF32();
    out.off_y = try r.readF32();
    out.off_z = try r.readF32();
    out.use_nearby = try r.readBool();
    return out;
}

/// The server's answer to a GetTreasurePoint request: stock re-Setups the
/// package with the resolved dig position and sends it back to the asking
/// player (`Setup` IL=26 at :36 pins ActionType 1 and zeroes distance/offset;
/// `write` IL=59 at :182 emits the same branch the reader expects).
pub fn buildQuestTreasurePointReply(
    buf: []u8,
    player_id: i32,
    quest_code: i32,
    blocks_per_reduction: i32,
    x: i32,
    y: i32,
    z: i32,
    off_x: f32,
    off_y: f32,
    off_z: f32,
) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeByte(quest_point_get_treasure);
    try w.writeI32(player_id);
    try w.writeF32(0); // distance: Setup zeroes it
    try w.writeI32(0); // offset: Setup zeroes it
    try w.writeF32(0); // treasureRadius: not re-set by Setup
    try w.writeI32(blocks_per_reduction);
    try w.writeI32(quest_code);
    try w.writeI32(x);
    try w.writeI32(y);
    try w.writeI32(z);
    try w.writeF32(off_x);
    try w.writeF32(off_y);
    try w.writeF32(off_z);
    try w.writeBool(false); // useNearby: not re-set by Setup
    return w.written();
}

test "quest treasure point body branches on the action byte" {
    // Action 2 is the short form: questCode + Vector3i and nothing else.
    var short_buf: [32]u8 = undefined;
    var sw: binary.Writer = .{ .buf = &short_buf };
    try sw.writeByte(quest_point_update_treasure);
    try sw.writeI32(77);
    try sw.writeI32(10);
    try sw.writeI32(70);
    try sw.writeI32(-4);
    const short = try parseQuestTreasurePoint(sw.written());
    try std.testing.expectEqual(@as(usize, 17), sw.written().len);
    try std.testing.expectEqual(@as(i32, 77), short.quest_code);
    try std.testing.expectEqual(@as(i32, -4), short.z);

    // The reply form round-trips through the long branch.
    // The reply: check the bytes at fixed offsets rather than round-tripping.
    // A round trip through zdtd's own writer and reader proves they agree with
    // each other, not with stock, and Setup pins distance/offset/treasureRadius
    // to zero - three consecutive fields (f32, i32, f32) that no round-trip
    // assertion can tell apart from each other or from a width swap.
    // Order per NetPackageQuestTreasurePoint::read (IL=54, :125): action u8 |
    // playerId i32 | distance f32 | offset i32 | treasureRadius f32 |
    // blocksPerReduction i32 | questCode i32 | position Vector3i |
    // treasureOffset Vector3 | useNearby bool.
    var buf: [64]u8 = undefined;
    const reply = try buildQuestTreasurePointReply(&buf, 107, 77, 3, 100, 60, -200, 0.5, 0.25, 1.5);
    try std.testing.expectEqual(@as(usize, 1 + 4 + 4 + 4 + 4 + 4 + 4 + 12 + 12 + 1), reply.len);
    try std.testing.expectEqual(quest_point_get_treasure, reply[0]);
    const i32At = struct {
        fn f(b: []const u8, off: usize) i32 {
            return std.mem.readInt(i32, b[off..][0..4], .little);
        }
    }.f;
    const f32At = struct {
        fn f(b: []const u8, off: usize) f32 {
            return @bitCast(std.mem.readInt(u32, b[off..][0..4], .little));
        }
    }.f;
    try std.testing.expectEqual(@as(i32, 107), i32At(reply, 1)); // playerId
    try std.testing.expectEqual(@as(f32, 0), f32At(reply, 5)); // distance
    try std.testing.expectEqual(@as(i32, 0), i32At(reply, 9)); // offset
    try std.testing.expectEqual(@as(f32, 0), f32At(reply, 13)); // treasureRadius
    try std.testing.expectEqual(@as(i32, 3), i32At(reply, 17)); // blocksPerReduction
    try std.testing.expectEqual(@as(i32, 77), i32At(reply, 21)); // questCode
    try std.testing.expectEqual(@as(i32, 100), i32At(reply, 25)); // position.x
    try std.testing.expectEqual(@as(i32, 60), i32At(reply, 29)); // position.y
    try std.testing.expectEqual(@as(i32, -200), i32At(reply, 33)); // position.z
    // Distinct offsets: equal ones could not catch a swap among the three.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), f32At(reply, 37), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), f32At(reply, 41), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), f32At(reply, 45), 0.001);
    try std.testing.expectEqual(@as(u8, 0), reply[49]); // useNearby

    // The parser agrees with those bytes.
    const got = try parseQuestTreasurePoint(reply);
    try std.testing.expectEqual(@as(i32, 107), got.player_id);
    try std.testing.expectEqual(@as(i32, 3), got.blocks_per_reduction);
    try std.testing.expectEqual(@as(i32, -200), got.z);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), got.off_y, 0.001);

    try std.testing.expectError(error.EndOfStream, parseQuestTreasurePoint(reply[0 .. reply.len - 1]));
}

const readBlockChangeInfo = stock_block.readBlockChangeInfo;

pub const stock_frame = @import("stock_frame.zig");
pub const channelFor = stock_frame.channelFor;
pub const framed = stock_frame.framed;

test "setblock stock body roundtrip" {
    var buf: [64]u8 = undefined;
    const body = try buildSetBlockBodyRaw(&buf, -10, 61, 400, 13, 0, 106, 106);
    try std.testing.expect(body.len > 20);
    try std.testing.expectEqual(@as(u8, 0), body[0]); // no user id
    const p = try parseSetBlockBody(body);
    try std.testing.expectEqual(@as(i32, -10), p.x);
    try std.testing.expectEqual(@as(i32, 61), p.y);
    try std.testing.expectEqual(@as(i32, 400), p.z);
    const dmg_body = try buildSetBlockBodyDamage(&buf, 1, 2, 3, 20304, 7, 100, 100);
    var one: [1]BlockChange = undefined;
    const n = try parseSetBlockChanges(dmg_body, one[0..]);
    try std.testing.expectEqual(@as(usize, 1), n);
    // The change position is the point of the package and nothing read it
    // back: the parser could have swapped two of the three coordinates and
    // every assertion here would still have passed.
    try std.testing.expectEqual(@as(i32, 1), one[0].x);
    try std.testing.expectEqual(@as(i32, 2), one[0].y);
    try std.testing.expectEqual(@as(i32, 3), one[0].z);
    try std.testing.expectEqual(@as(u16, 20304), one[0].block_id);
    try std.testing.expectEqual(@as(u16, 7), one[0].damage);
    try std.testing.expectEqual(@as(u16, 13), p.block_id);
}

test "setblock accepts payload-free stock flag bits and keeps rejecting unknown ones" {
    // BlockSwitch::updateState -> SetBlockRPC(bvRef, bv) emits value|updateLight.
    var buf: [64]u8 = undefined;
    var w: binary.Writer = .{ .buf = &buf };
    try w.writeBool(false);
    try w.writeI16(1);
    try w.writeByte(1); // BlockValueRef type = world position
    try w.writeI32(4);
    try w.writeI32(70);
    try w.writeI32(-9);
    try w.writeI32(106); // changedByEntityId
    try w.writeByte(0x11); // bChangeBlockValue | bUpdateLight
    try w.writeU32(withBlockMeta(19200, block_meta_on));
    try w.writeU16(0);
    try w.writeI32(106);
    const body = w.written();
    var one: [1]BlockChange = undefined;
    try std.testing.expectEqual(@as(usize, 1), try parseSetBlockChanges(body, one[0..]));
    try std.testing.expectEqual(@as(u16, 19200), one[0].block_id);
    try std.testing.expectEqual(block_meta_on, blockMeta(one[0].raw));
    // bChangeDamage and bForceDensity are payload-free too.
    buf[20] = block_change_flag_damage | block_change_flag_force_density | block_change_flag_value;
    try std.testing.expectEqual(@as(usize, 1), try parseSetBlockChanges(body, one[0..]));
    // Bits the stock writer never emits still fail closed: their payload (if any)
    // is unknown, so continuing would decode the rest of the batch desynced.
    buf[20] = 0x80;
    try std.testing.expectError(error.EndOfStream, parseSetBlockChanges(body, one[0..]));
    buf[20] = 0x40;
    try std.testing.expectError(error.EndOfStream, parseSetBlockChanges(body, one[0..]));
}

test "setblock raw body preserves the meta nibble" {
    var buf: [64]u8 = undefined;
    const raw = withBlockMeta(19200, block_meta_on | block_meta_powered);
    const body = try buildSetBlockBodyRaw(&buf, 1, 2, 3, raw, 11, 106, 106);
    var one: [1]BlockChange = undefined;
    try std.testing.expectEqual(@as(usize, 1), try parseSetBlockChanges(body, one[0..]));
    try std.testing.expectEqual(raw, one[0].raw);
    try std.testing.expectEqual(@as(u16, 19200), one[0].block_id);
    try std.testing.expectEqual(@as(u16, 11), one[0].damage);
    // The id-only form is the same encoder with an empty meta nibble.
    const plain = try buildSetBlockBodyDamage(&buf, 1, 2, 3, 19200, 11, 106, 106);
    try std.testing.expectEqual(@as(usize, 1), try parseSetBlockChanges(plain, one[0..]));
    try std.testing.expectEqual(@as(u8, 0), blockMeta(one[0].raw));
}

test "an empty change list from an identified client is not a block edit" {
    // A stock body is `identity | count i16 | changes`, and an identity plus a
    // zero count is 6 + platform.len + id.len bytes. Any pair summing to 8 -
    // "Steam" with a 3-character id, say - lands on exactly 14, which a
    // length-keyed legacy branch would decode as x/y/z/id read straight out of
    // the identity bytes: a block edit the client never asked for, at a
    // position taken from its account name.
    var buf: [64]u8 = undefined;
    var w: binary.Writer = .{ .buf = &buf };
    try platform_user.write(&w, .{ .platform = "Steam", .id = "abc" });
    try w.writeI16(0); // no changes
    const body = w.written();
    try std.testing.expectEqual(@as(usize, 14), body.len);

    var one: [1]BlockChange = undefined;
    try std.testing.expectEqual(@as(usize, 0), try parseSetBlockChanges(body, one[0..]));
}

test "block meta accessors match BlockValue get_meta/set_meta" {
    try std.testing.expectEqual(@as(u8, 0), blockMeta(19200));
    try std.testing.expectEqual(@as(u32, 19200 | (2 << 22)), withBlockMeta(19200, 2));
    // Only bits 22..25 move; rotation and the type survive, and meta wraps to 4 bits.
    const rot: u32 = 19200 | (5 << 26) | (3 << 22);
    try std.testing.expectEqual(@as(u8, 3), blockMeta(rot));
    try std.testing.expectEqual(@as(u8, 15), blockMeta(withBlockMeta(rot, 0xff)));
    try std.testing.expectEqual(rot & ~@as(u32, 15 << 22), withBlockMeta(rot, 0));
}

test "NetPackageChunk resolves to an id and frames at that id" {
    // The id itself is not a contract: ids are negotiated through
    // NetPackagePackageIds, so the client uses whatever index this table
    // advertises. What must hold is that the name resolves and that `framed`
    // stamps the same id `idOf` returns - a mismatch there would send terrain
    // under a header the client resolves to some other package.
    const chunk_id = idOf("NetPackageChunk") orelse return error.TestUnexpectedResult;
    var heights: [256]u8 = .{70} ** 256;
    var body_buf: [512]u8 = undefined;
    const body = try buildChunkBody(&body_buf, -18, 28, &heights);
    try std.testing.expectEqual(@as(usize, chunk_stock_envelope_overhead + chunk_body_size), body.len);
    var frame_buf: [512]u8 = undefined;
    const fr = try framed(&frame_buf, "NetPackageChunk", body);
    // framePackage: channel 1 | payloadSize i32 | compressed 1 | encrypted 1 |
    // count u16 | contentLen i32, then the package id.
    const pkg_id_off: usize = 1 + 4 + 1 + 1 + 2 + 4;
    try std.testing.expectEqual(chunk_id, std.mem.readInt(u16, fr[pkg_id_off..][0..2], .little));
    // LiteNet channeled total must fit pending_bytes (1200).
    try std.testing.expect(fr.len + 4 < 1200);
}

test "pos body golden size" {
    var body_buf: [64]u8 = undefined;
    // Distinct values in every slot: the body is entityId | pos x,y,z |
    // bUseQRotation | rot x,y,z | onGround, and a length check plus an id
    // check cannot see two of those floats trading places.
    const body = try buildPosAndRotBody(&body_buf, 7, 1, 2, 3, 11, 90, 13, true);
    try std.testing.expectEqual(@as(usize, 30), body.len);
    const p = try parsePosAndRotBody(body);
    try std.testing.expectEqual(@as(i32, 7), p.entity_id);
    try std.testing.expect(p.on_ground);

    const f32At = struct {
        fn get(b: []const u8, off: usize) f32 {
            return @bitCast(std.mem.readInt(u32, b[off..][0..4], .little));
        }
    }.get;
    try std.testing.expectEqual(@as(f32, 1), f32At(body, 4)); // pos x
    try std.testing.expectEqual(@as(f32, 2), f32At(body, 8));
    try std.testing.expectEqual(@as(f32, 3), f32At(body, 12));
    try std.testing.expectEqual(@as(u8, 0), body[16]); // bUseQRotation false
    try std.testing.expectEqual(@as(f32, 11), f32At(body, 17)); // rot x
    try std.testing.expectEqual(@as(f32, 90), f32At(body, 21));
    try std.testing.expectEqual(@as(f32, 13), f32At(body, 25));
    try std.testing.expectEqual(@as(u8, 1), body[29]); // onGround
}

test "pos body rejects non-finite and out-of-range coordinates" {
    var body_buf: [64]u8 = undefined;
    const nan = try buildPosAndRotBody(&body_buf, 7, std.math.nan(f32), 2, 3, 0, 0, 0, true);
    try std.testing.expectError(error.Overflow, parsePosAndRotBody(nan));
    const huge = try buildPosAndRotBody(&body_buf, 7, 1, 2, 1e30, 0, 0, 0, true);
    try std.testing.expectError(error.Overflow, parsePosAndRotBody(huge));
    const nan_rot = try buildPosAndRotBody(&body_buf, 7, 1, 2, 3, std.math.nan(f32), 0, 0, true);
    try std.testing.expectError(error.Overflow, parsePosAndRotBody(nan_rot));
}

test "entity speeds rejects non-finite" {
    var buf: [32]u8 = undefined;
    const body = try buildEntitySpeedsBody(&buf, 1, 0, std.math.nan(f32), 0);
    try std.testing.expectError(error.Overflow, parseEntitySpeedsBody(body));
    const inf = try buildEntitySpeedsBody(&buf, 1, 0, 1, std.math.inf(f32));
    try std.testing.expectError(error.Overflow, parseEntitySpeedsBody(inf));
}

test "rel body golden size" {
    var body_buf: [64]u8 = undefined;
    // Distinct values: the six i16 (rot x,y,z then dPos x,y,z) had zeros and
    // repeats among them, so most swaps in that run emitted identical bytes
    // and the size check could not have seen the rest.
    const body = try buildRelPosBody(&body_buf, 1, 21, 22, 23, 11, 12, 13, true, 2);
    try std.testing.expectEqual(@as(usize, 20), body.len);
    var frame_buf: [128]u8 = undefined;
    const fr = try framed(&frame_buf, "NetPackageEntityRelPosAndRot", body);
    // contentLen at offset 9 = 22
    const cl = std.mem.readInt(i32, fr[9..][0..4], .little);
    try std.testing.expectEqual(@as(i32, 22), cl);

    // entityId i32 | bUseQRotation bool | rot x,y,z i16 | dPos x,y,z i16 |
    // onGround bool | updateSteps i16 (RE protocol-packages.md 5.5.4).
    try std.testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, body[0..4], .little));
    try std.testing.expectEqual(@as(u8, 0), body[4]); // bUseQRotation
    try std.testing.expectEqual(@as(i16, 11), std.mem.readInt(i16, body[5..7], .little)); // rot x
    try std.testing.expectEqual(@as(i16, 12), std.mem.readInt(i16, body[7..9], .little));
    try std.testing.expectEqual(@as(i16, 13), std.mem.readInt(i16, body[9..11], .little));
    try std.testing.expectEqual(@as(i16, 21), std.mem.readInt(i16, body[11..13], .little)); // dPos x
    try std.testing.expectEqual(@as(i16, 22), std.mem.readInt(i16, body[13..15], .little));
    try std.testing.expectEqual(@as(i16, 23), std.mem.readInt(i16, body[15..17], .little));
    try std.testing.expectEqual(@as(u8, 1), body[17]); // onGround
    try std.testing.expectEqual(@as(i16, 2), std.mem.readInt(i16, body[18..20], .little)); // updateSteps
}

test "package ids body" {
    var buf: [8192]u8 = undefined;
    const body = try buildPackageIdsBody(&buf, .{}, &default_mappings);
    var r: binary.Reader = .{ .data = body };
    try std.testing.expectEqual(@as(u8, 1), try r.readByte());
    try std.testing.expectEqual(@as(i32, 3), try r.readI32());
    // 3.2.0 raw numbers (changelog-3.2.0 §1: minor 10->20, build 14->9;
    // §8: build 9->10). A client derives "V 3.2.0" from these and echoes it
    // in the login.
    try std.testing.expectEqual(@as(i32, 20), try r.readI32());
    try std.testing.expectEqual(@as(i32, 10), try r.readI32());
    try std.testing.expectEqual(@as(i32, @intCast(default_mappings.len)), try r.readI32());
}

pub const stock_world = @import("stock_world.zig");
pub const buildWorldTimeBody = stock_world.buildWorldTimeBody;
pub const buildSignDataResponseEmptyLast = stock_world.buildSignDataResponseEmptyLast;
pub const buildWorldInitInfoEmpty = stock_world.buildWorldInitInfoEmpty;
pub const buildWorldInfoBody = stock_world.buildWorldInfoBody;
pub const buildWorldFolderPartBody = stock_world.buildWorldFolderPartBody;
pub const buildEmptyWorldFolderTransfer = stock_world.buildEmptyWorldFolderTransfer;
pub const buildChunkClusterInfoBody = stock_world.buildChunkClusterInfoBody;

pub const stock_estats = @import("stock_estats.zig");
pub const EntityStatKind = stock_estats.EntityStatKind;
pub const buildEntityStatChangedBody = stock_estats.buildEntityStatChangedBody;
pub const buildAwardKillBody = stock_estats.buildAwardKillBody;
pub const buildSetAttackTargetBody = stock_estats.buildSetAttackTargetBody;
pub const buildEntityStealthBody = stock_estats.buildEntityStealthBody;
pub const buildEntityStealthCrouchBody = stock_estats.buildEntityStealthCrouchBody;

pub const stock_invtx = @import("stock_invtx.zig");
pub const buildInvTxRequest = stock_invtx.buildInvTxRequest;
pub const parseInvTxRequest = stock_invtx.parseInvTxRequest;
pub const buildInvTxResponseHead = stock_invtx.buildInvTxResponseHead;
pub const parseInvDataRequest = stock_invtx.parseInvDataRequest;
pub const InvDataRequestStock = stock_invtx.InvDataRequestStock;
pub const parseInvDataRequestStock = stock_invtx.parseInvDataRequestStock;
pub const buildInvDataResponseNotFound = stock_invtx.buildInvDataResponseNotFound;
pub const buildInvDataResponseItems = stock_invtx.buildInvDataResponseItems;
pub const buildIdMappingBody = stock_invtx.buildIdMappingBody;
pub const IdMappingEntry = stock_invtx.IdMappingEntry;
pub const buildNameIdMappingPayload = stock_invtx.buildNameIdMappingPayload;
pub const buildInventoryBodyStock = stock_inv.buildFromEcs;
pub const buildInventoryBodyStockResolved = stock_inv.buildFromEcsResolved;
pub const buildHoldingBodyResolved = stock_inv.buildHoldingFromEcsResolved;

pub const stock_lock = @import("stock_lock.zig");
pub const LockRequestHead = stock_lock.LockRequestHead;
pub const max_lock_targets_declared = stock_lock.max_lock_targets_declared;
pub const parseLockRequest = stock_lock.parseLockRequest;
pub const buildLockResponseGrant = stock_lock.buildLockResponseGrant;
pub const buildLockResponseDeny = stock_lock.buildLockResponseDeny;
pub const buildLockResponseForceUnlock = stock_lock.buildLockResponseForceUnlock;
pub const buildLockResponseTrader = stock_lock.buildLockResponseTrader;
pub const vending_lock_context = stock_lock.vending_lock_context;
pub const buildLockResponseUnlock = stock_lock.buildLockResponseUnlock;

test "inventory data request stock layout and not-found response" {
    var key: [16]u8 = .{1} ** 16;
    var tok: [16]u8 = .{2} ** 16;
    var req_buf: [36]u8 = undefined;
    @memcpy(req_buf[0..16], &key);
    std.mem.writeInt(i32, req_buf[16..20], 42, .little);
    @memcpy(req_buf[20..36], &tok);
    const req = try parseInvDataRequestStock(&req_buf);
    try std.testing.expectEqual(@as(i32, 42), req.hash);
    try std.testing.expectEqualSlices(u8, &key, &req.inventory_key);

    var resp_buf: [128]u8 = undefined;
    const resp = try buildInvDataResponseNotFound(&resp_buf, key, tok);
    try std.testing.expectEqual(@as(u8, 0), resp[0]); // success false
    // error string 7bit-len then UTF8; then key; then i16 -1
    try std.testing.expect(resp.len > 20);

    const items = [_]stock_inv.StockSlot{
        .{ .type_id = stock_inv.items_start_here + 7, .count = 3, .quality = 1 },
        .{},
    };
    const ok = try buildInvDataResponseItems(&resp_buf, key, tok, items[0..]);
    try std.testing.expectEqual(@as(u8, 1), ok[0]);
    try std.testing.expect(ok.len > resp.len);
}

/// Live overrides for persistent GameStats.Write fields (stock defaults otherwise).
/// RE: EnumGameStats + initPropertyDecl bPersistent filter (sandbox-options §6.1).
/// There is **no** current-day field in the net blob; HUD day comes from
/// NetPackageWorldTime (`worldTime / 24000`). BloodMoonDay is the scheduled BM day.
pub const GameStatsValues = struct {
    game_difficulty: i32 = 2,
    blood_moon_enemy_count: i32 = 8,
    enemy_difficulty: i32 = 0,
    day_light_length: i32 = 18,
    day_night_length: i32 = 60,
    blood_moon_day: i32 = 0,
    blood_moon_warning: i32 = 1, // stock live value: warn one day ahead
    block_damage_player: i32 = 100,
    block_damage_ai: i32 = 100,
    block_damage_ai_bm: i32 = 100,
    xp_multiplier: i32 = 100,
    player_killing_mode: i32 = 3,
    drop_on_death: i32 = 1,
    land_claim_size: i32 = 41,
    land_claim_online_dur: i32 = 32,
    land_claim_offline_dur: i32 = 32,
    air_drop_frequency: i32 = 0,
    party_shared_kill_range: i32 = 100,
    show_friend_player_on_map: bool = true,
    /// GameStats[18]/[20] IsCreativeMenuEnabled / IsFlyingEnabled: stock seeds
    /// both from GamePrefs 58 `BuildCreate`
    /// (server-lifecycle.md GameStats table), so a server running with cheat
    /// mode on hands the client its creative menu and flight.
    build_create: bool = false,
    /// GameStats[53] AirDropMarker (sandbox option, default on).
    air_drop_marker: bool = true,
    /// GameStats[34] DropOnQuit (sandbox option `DropOnQuit`, distinct from
    /// DropOnDeath).
    drop_on_quit: i32 = 0,
    /// GameStats[66] BiomeProgression (sandbox option, default on).
    biome_progression: bool = true,
    /// GameStats[68] CameraRestrictionMode (serverconfig).
    camera_restriction_mode: i32 = 0,
    /// GameStats[29] ScorePlayerKillMultiplier: `GameModeSurvival::Init`
    /// IL_0035-0038 sets it to 0 (a player kill scores nothing), while
    /// [28] ScoreZombieKillMultiplier is 1 and [30] ScoreDiedMultiplier -5
    /// (IL_003D-0049). Mode semantics, not a tunable.
    score_player_kill_multiplier: i32 = 0,
    is_spawn_enemies: bool = true,
    enemy_spawn_mode: bool = true,
    /// GameStats[11] TimeOfDayIncPerSec = 24000 / (DayNightLength * 60) in
    /// integer arithmetic: 6 at the stock 60 real-minute day (live `getgamestat`
    /// 2026-08-12). Callers pass the WorldClock's own rate.
    time_of_day_inc_per_sec: i32 = 6,
    death_penalty: i32 = 1,
    quest_progression_daily_limit: i32 = 4,
    /// Percent, stock GamePrefs.StormFreq default 100 (asm.il 1908835). Also the
    /// source of World::StormFrequency (the 1.0 multiplier the storm scheduler divides by).
    storm_freq: i32 = 100,
    loot_abundance: i32 = 100,
    loot_respawn_days: i32 = 7,
    bedroll_expiry_time: i32 = 45,
    land_claim_count: i32 = 5,
    land_claim_dead_zone: i32 = 30,
    land_claim_expiry_time: i32 = 3,
    land_claim_decay_mode: i32 = 0,
    land_claim_offline_delay: i32 = 0,
    jar_refund: i32 = 60,
    sandbox_preset: []const u8 = "",
    sandbox_code: []const u8 = "",
};

/// Stock NetPackageGameStats body: i16 payload_len + GameStats.Write blob.
/// Write emits only bPersistent PropertyDecls in engine propertyList order with
/// no name/id prefix (RE sandbox-options §6.1, GameStats.il Write IL=60).
/// Empty payload (len=0) remains valid. Full blob uses stock defaults + overrides.
///
/// **propertyList order is not EnumGameStats order.** `initPropertyDecl`
/// (IL=702, `il/full-v3.2.0/_global/GameStats.il.txt`) fills 78 slots with
/// literal enum ids that are out of order in several places: slot 4/5 carry
/// FragLimit (enum 6/7) and slot 6/7 carry DayLimit (enum 4/5), slot 14 carries
/// IsSpawnNearOtherPlayer (enum 25) ahead of TimeOfDayIncPerSec (enum 11), and
/// nine slots are non-persistent and skipped entirely (EnemyCount and
/// AnimalCount among them). Since the blob carries no field names, the writes
/// below follow slot order; the enum index table in
/// inventories/gamestats-gameprefs.md documents the enum, not this order, and
/// reordering these lines to match it would shift every later field.
pub fn buildGameStatsBodyValues(buf: []u8, v: GameStatsValues) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    // Reserve i16 length; fill after payload.
    try w.writeI16(0);
    const payload_start = w.pos;

    // propertyList order, bPersistent only (78 decls, 9 skipped). Types: 0=i32 2=string 3=bool.
    // EnumGameState.Running. Not cosmetic: PlayerMoveController.Update runs
    // updateRespawn() only while GameStats[GameState] == 1, else it calls
    // stopMoving() and returns. Sending 0 (Loading) freezes the client's
    // respawn machine in WaitingForSpawnWindowToClose, so the loading screen
    // is never closed even though the world, player and colliders are live.
    try w.writeI32(1); // GameState
    try w.writeI32(0); // GameModeId
    try w.writeBool(false); // TimeLimitActive
    try w.writeI32(0); // TimeLimitThisRound
    try w.writeBool(false); // FragLimitActive
    try w.writeI32(0); // FragLimitThisRound
    try w.writeBool(false); // DayLimitActive
    try w.writeI32(0); // DayLimitThisRound
    try w.writeString(""); // ShowWindow
    try w.writeString(""); // LoadScene
    try w.writeI32(0); // CurrentRoundIx
    try w.writeBool(false); // ShowAllPlayersOnMap
    try w.writeBool(v.show_friend_player_on_map); // ShowFriendPlayerOnMap
    try w.writeBool(false); // ShowSpawnWindow
    try w.writeBool(false); // IsSpawnNearOtherPlayer
    try w.writeI32(v.time_of_day_inc_per_sec); // TimeOfDayIncPerSec
    try w.writeBool(v.build_create); // IsCreativeMenuEnabled (GamePrefs 58)
    try w.writeBool(false); // IsTeleportEnabled
    try w.writeBool(v.build_create); // IsFlyingEnabled (GamePrefs 58)
    try w.writeBool(true); // IsPlayerDamageEnabled
    try w.writeBool(true); // IsPlayerCollisionEnabled
    try w.writeBool(v.is_spawn_enemies); // IsSpawnEnemies
    try w.writeI32(v.player_killing_mode); // PlayerKillingMode
    try w.writeI32(v.score_player_kill_multiplier); // ScorePlayerKillMultiplier
    try w.writeI32(1); // ScoreZombieKillMultiplier
    try w.writeI32(-5); // ScoreDiedMultiplier
    try w.writeI32(v.drop_on_death); // DropOnDeath
    try w.writeI32(v.drop_on_quit); // DropOnQuit (sandbox)
    try w.writeI32(v.game_difficulty); // GameDifficulty
    try w.writeI32(v.blood_moon_enemy_count); // BloodMoonEnemyCount
    try w.writeBool(v.enemy_spawn_mode); // EnemySpawnMode
    try w.writeI32(v.enemy_difficulty); // EnemyDifficulty
    try w.writeI32(v.day_light_length); // DayLightLength
    try w.writeI32(v.land_claim_count); // LandClaimCount
    try w.writeI32(v.land_claim_size); // LandClaimSize
    try w.writeI32(v.land_claim_dead_zone); // LandClaimDeadZone
    try w.writeI32(v.land_claim_expiry_time); // LandClaimExpiryTime
    try w.writeI32(v.land_claim_decay_mode); // LandClaimDecayMode
    try w.writeI32(v.land_claim_online_dur); // LandClaimOnlineDurabilityModifier
    try w.writeI32(v.land_claim_offline_dur); // LandClaimOfflineDurabilityModifier
    try w.writeI32(v.land_claim_offline_delay); // LandClaimOfflineDelay
    try w.writeI32(v.bedroll_expiry_time); // BedrollExpiryTime
    try w.writeI32(v.air_drop_frequency); // AirDropFrequency
    try w.writeBool(v.air_drop_marker); // AirDropMarker (sandbox)
    try w.writeI32(v.party_shared_kill_range); // PartySharedKillRange
    try w.writeBool(false); // AutoParty
    try w.writeI32(0); // OptionsPOICulling
    try w.writeI32(v.blood_moon_day); // BloodMoonDay (scheduled, not HUD day)
    try w.writeI32(v.block_damage_player); // BlockDamagePlayer
    try w.writeI32(v.xp_multiplier); // XPMultiplier
    try w.writeI32(v.blood_moon_warning); // BloodMoonWarning
    try w.writeBool(true); // TwitchBloodMoonAllowed
    try w.writeI32(v.death_penalty); // DeathPenalty
    try w.writeI32(v.quest_progression_daily_limit); // QuestProgressionDailyLimit
    try w.writeBool(v.biome_progression); // BiomeProgression (sandbox)
    try w.writeI32(v.storm_freq); // StormFreq
    try w.writeI32(v.camera_restriction_mode); // CameraRestrictionMode
    try w.writeI32(v.jar_refund); // JarRefund
    try w.writeString(v.sandbox_preset); // SandboxPreset
    try w.writeString(v.sandbox_code); // SandboxCode
    try w.writeI32(v.day_night_length); // DayNightLength
    try w.writeI32(v.block_damage_ai); // BlockDamageAI
    try w.writeI32(v.block_damage_ai_bm); // BlockDamageAIBM
    try w.writeI32(v.loot_abundance); // LootAbundance
    try w.writeI32(v.loot_respawn_days); // LootRespawnDays
    try w.writeI32(100); // GlobalGSModifier
    try w.writeI32(100); // BiomeGSModifier
    try w.writeI32(100); // GlobalLSModifier
    try w.writeI32(100); // BiomeLSModifier

    const payload_len: i32 = @intCast(w.pos - payload_start);
    if (payload_len > std.math.maxInt(i16)) return error.Overflow;
    std.mem.writeInt(i16, buf[0..2], @intCast(payload_len), .little);
    return w.written();
}

test "GameStats body is i16 len + full persistent blob" {
    var buf: [512]u8 = undefined;
    const body = try buildGameStatsBodyValues(&buf, .{
        .game_difficulty = 3,
        .blood_moon_day = 14,
        .day_night_length = 90,
    });
    try std.testing.expect(body.len >= 4);
    const plen = std.mem.readInt(i16, body[0..2], .little);
    try std.testing.expectEqual(@as(usize, @intCast(plen)), body.len - 2);
    // Empty string defaults + 69 typed fields: payload is non-trivial (not empty blob).
    try std.testing.expect(plen > 100);
    const defaults = try buildGameStatsBodyValues(buf[256..], .{});
    try std.testing.expect(defaults.len > 100);

    // The blob carries no field names, so position is the only thing that
    // identifies a value. A length assertion alone cannot see a reordering,
    // which is exactly the defect this layout is prone to: pin the head
    // against the propertyList slot order in initPropertyDecl (IL=702).
    var r: binary.Reader = .{ .data = body[2..] };
    try std.testing.expectEqual(@as(i32, 1), try r.readI32()); // 0: GameState Running
    try std.testing.expectEqual(@as(i32, 0), try r.readI32()); // 1: GameModeId
    try std.testing.expectEqual(false, try r.readBool()); // 2: TimeLimitActive
    try std.testing.expectEqual(@as(i32, 0), try r.readI32()); // 3: TimeLimitThisRound
    // Slots 4..7 are Frag before Day (enum 6,7,4,5), not enum order.
    try std.testing.expectEqual(false, try r.readBool()); // 4: FragLimitActive
    try std.testing.expectEqual(@as(i32, 0), try r.readI32()); // 5: FragLimitThisRound
    try std.testing.expectEqual(false, try r.readBool()); // 6: DayLimitActive
    try std.testing.expectEqual(@as(i32, 0), try r.readI32()); // 7: DayLimitThisRound
    var s_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("", try r.readString(&s_buf)); // 8: ShowWindow
    try std.testing.expectEqualStrings("", try r.readString(&s_buf)); // 9: LoadScene
    try std.testing.expectEqual(@as(i32, 0), try r.readI32()); // 10: CurrentRoundIx

    // Slots 0..10 are all constant zeros and empty strings, so swapping two
    // same-typed neighbours there produces identical bytes and proves nothing.
    // Slots 11..15 are where the caller's values land, and they are the only
    // part of the head a reordering can actually be caught in: give each a
    // distinct value and read them back in slot order. Slot 14 is
    // IsSpawnNearOtherPlayer (enum 25), ahead of TimeOfDayIncPerSec (enum 11).
    var distinct: [512]u8 = undefined;
    const d = try buildGameStatsBodyValues(&distinct, .{
        .show_friend_player_on_map = true,
        .time_of_day_inc_per_sec = 37,
        // These three default to the same values as the hardcoded constants
        // written beside them: is_spawn_enemies is true next to a literal
        // true, and player_killing_mode / drop_on_death sit among the literal
        // 1 score multipliers. That made the whole slot run unobservable, so
        // pick values differing from both neighbours.
        .is_spawn_enemies = false,
        .player_killing_mode = 2,
        .drop_on_death = 3,
        // Same collision a few slots on: DropOnQuit is a literal 0 while
        // enemy_difficulty defaults to 0, and the difficulty / blood-moon /
        // daylight values have to differ from each other as well.
        .game_difficulty = 4,
        .blood_moon_enemy_count = 9,
        .enemy_difficulty = 5,
        .day_light_length = 19,
        .land_claim_count = 6,
        // The remaining caller-supplied collisions, found by walking the whole
        // write list against the fixture rather than one audit run at a time:
        // the two land-claim durability modifiers both default to 32, the
        // block-damage / XP / loot values all default to 100, and blood_moon_day
        // defaults to 0 next to the literal-0 OptionsPOICulling.
        .land_claim_online_dur = 31,
        .land_claim_offline_dur = 33,
        .blood_moon_day = 21,
        .block_damage_player = 101,
        .xp_multiplier = 102,
        .block_damage_ai = 103,
        .block_damage_ai_bm = 104,
        .loot_abundance = 105,
    });
    var dr: binary.Reader = .{ .data = d[2..] };
    dr.pos = r.pos; // same head width, already asserted field by field above
    try std.testing.expectEqual(false, try dr.readBool()); // 11: ShowAllPlayersOnMap
    try std.testing.expectEqual(true, try dr.readBool()); // 12: ShowFriendPlayerOnMap
    try std.testing.expectEqual(false, try dr.readBool()); // 13: ShowSpawnWindow
    try std.testing.expectEqual(false, try dr.readBool()); // 14: IsSpawnNearOtherPlayer
    try std.testing.expectEqual(@as(i32, 37), try dr.readI32()); // 15: TimeOfDayIncPerSec

    // Slots 16..20 are five hardcoded bools: three false then two true. A swap
    // inside either group is invisible by construction, but one across the
    // boundary turns player damage or collision off for every client, so read
    // all five and let the boundary carry the check.
    try std.testing.expectEqual(false, try dr.readBool()); // 16: IsCreativeMenuEnabled
    try std.testing.expectEqual(false, try dr.readBool()); // 17: IsTeleportEnabled
    try std.testing.expectEqual(false, try dr.readBool()); // 18: IsFlyingEnabled
    try std.testing.expectEqual(true, try dr.readBool()); // 19: IsPlayerDamageEnabled
    try std.testing.expectEqual(true, try dr.readBool()); // 20: IsPlayerCollisionEnabled
    // Slots 21..26 mix caller values with hardcoded score multipliers, which
    // is where the defaults collided: with is_spawn_enemies false and the two
    // i32 distinct from the literal 1 / -5 beside them, each position is now
    // observable.
    try std.testing.expectEqual(false, try dr.readBool()); // 21: IsSpawnEnemies
    try std.testing.expectEqual(@as(i32, 2), try dr.readI32()); // 22: PlayerKillingMode
    // 23 is 0 and 24 is 1: `GameModeSurvival::Init` IL_0035-0040 sets the
    // player-kill multiplier to nothing and the zombie one to 1, so the pair
    // is no longer two identical constants.
    try std.testing.expectEqual(@as(i32, 0), try dr.readI32()); // 23: ScorePlayerKillMultiplier
    try std.testing.expectEqual(@as(i32, 1), try dr.readI32()); // 24: ScoreZombieKillMultiplier
    try std.testing.expectEqual(@as(i32, -5), try dr.readI32()); // 25: ScoreDiedMultiplier
    try std.testing.expectEqual(@as(i32, 3), try dr.readI32()); // 26: DropOnDeath
    try std.testing.expectEqual(@as(i32, 0), try dr.readI32()); // 27: DropOnQuit
    try std.testing.expectEqual(@as(i32, 4), try dr.readI32()); // 28: GameDifficulty
    try std.testing.expectEqual(@as(i32, 9), try dr.readI32()); // 29: BloodMoonEnemyCount
    try std.testing.expectEqual(true, try dr.readBool()); // 30: EnemySpawnMode
    try std.testing.expectEqual(@as(i32, 5), try dr.readI32()); // 31: EnemyDifficulty
    try std.testing.expectEqual(@as(i32, 19), try dr.readI32()); // 32: DayLightLength
    try std.testing.expectEqual(@as(i32, 6), try dr.readI32()); // 33: LandClaimCount

    // The rest of the blob, to the end. Reading only the head left 35 slots
    // whose position nothing checked, and the blob is the one body where a
    // single misplaced field shifts every value after it.
    try std.testing.expectEqual(@as(i32, 41), try dr.readI32()); // 34: LandClaimSize
    try std.testing.expectEqual(@as(i32, 30), try dr.readI32()); // 35: LandClaimDeadZone
    try std.testing.expectEqual(@as(i32, 3), try dr.readI32()); // 36: LandClaimExpiryTime
    try std.testing.expectEqual(@as(i32, 0), try dr.readI32()); // 37: LandClaimDecayMode
    try std.testing.expectEqual(@as(i32, 31), try dr.readI32()); // 38: LandClaimOnlineDur
    try std.testing.expectEqual(@as(i32, 33), try dr.readI32()); // 39: LandClaimOfflineDur
    try std.testing.expectEqual(@as(i32, 0), try dr.readI32()); // 40: LandClaimOfflineDelay
    try std.testing.expectEqual(@as(i32, 45), try dr.readI32()); // 41: BedrollExpiryTime
    try std.testing.expectEqual(@as(i32, 0), try dr.readI32()); // 42: AirDropFrequency
    try std.testing.expectEqual(true, try dr.readBool()); // 43: AirDropMarker
    try std.testing.expectEqual(@as(i32, 100), try dr.readI32()); // 44: PartySharedKillRange
    try std.testing.expectEqual(false, try dr.readBool()); // 45: AutoParty
    try std.testing.expectEqual(@as(i32, 0), try dr.readI32()); // 46: OptionsPOICulling
    try std.testing.expectEqual(@as(i32, 21), try dr.readI32()); // 47: BloodMoonDay
    try std.testing.expectEqual(@as(i32, 101), try dr.readI32()); // 48: BlockDamagePlayer
    try std.testing.expectEqual(@as(i32, 102), try dr.readI32()); // 49: XPMultiplier
    try std.testing.expectEqual(@as(i32, 1), try dr.readI32()); // 50: BloodMoonWarning
    try std.testing.expectEqual(true, try dr.readBool()); // 51: TwitchBloodMoonAllowed
    try std.testing.expectEqual(@as(i32, 1), try dr.readI32()); // 52: DeathPenalty
    try std.testing.expectEqual(@as(i32, 4), try dr.readI32()); // 53: QuestProgressionDailyLimit
    try std.testing.expectEqual(true, try dr.readBool()); // 54: BiomeProgression
    try std.testing.expectEqual(@as(i32, 100), try dr.readI32()); // 55: StormFreq
    try std.testing.expectEqual(@as(i32, 0), try dr.readI32()); // 56: CameraRestrictionMode
    try std.testing.expectEqual(@as(i32, 60), try dr.readI32()); // 57: JarRefund
    var gs_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("", try dr.readString(&gs_buf)); // 58: SandboxPreset
    try std.testing.expectEqualStrings("", try dr.readString(&gs_buf)); // 59: SandboxCode
    try std.testing.expectEqual(@as(i32, 60), try dr.readI32()); // 60: DayNightLength
    try std.testing.expectEqual(@as(i32, 103), try dr.readI32()); // 61: BlockDamageAI
    try std.testing.expectEqual(@as(i32, 104), try dr.readI32()); // 62: BlockDamageAIBM
    try std.testing.expectEqual(@as(i32, 105), try dr.readI32()); // 63: LootAbundance
    try std.testing.expectEqual(@as(i32, 7), try dr.readI32()); // 64: LootRespawnDays
    try std.testing.expectEqual(@as(i32, 100), try dr.readI32()); // 65: GlobalGSModifier
    try std.testing.expectEqual(@as(i32, 100), try dr.readI32()); // 66: BiomeGSModifier
    try std.testing.expectEqual(@as(i32, 100), try dr.readI32()); // 67: GlobalLSModifier
    try std.testing.expectEqual(@as(i32, 100), try dr.readI32()); // 68: BiomeLSModifier
    // Nothing left: the blob ends exactly here.
    try std.testing.expectEqual(@as(usize, 0), dr.remaining());

    // Pairs that remain indistinguishable because both sides are the same
    // constant, not because the fixture is weak: the empty strings at 8/9 and
    // 58/59, the false runs at 13/14 and 16..18, the true pair at 19/20, and
    // the four 100s at 65..68. No caller input can separate those;
    // initPropertyDecl holds the order, and the swap-mutation audit reports
    // them as survivors by construction.
}

test "lock response for a trader carries the context and trader data" {
    // buildLockResponseTrader had no test. It differs from a plain grant by
    // forcing success true and appending the context type name, the command
    // and a TraderData block, so the leading locking/success pair is where a
    // swap would pass unnoticed.
    var req_buf: [64]u8 = undefined;
    var w: binary.Writer = .{ .buf = &req_buf };
    try w.writeBool(true); // locking
    try w.writeU16(3); // channel
    try w.writeI32(0); // no targets
    try w.writeString("EntityTraderLockContext");
    try w.writeString("trade");
    const head = try parseLockRequest(w.written());

    var resp_buf: [512]u8 = undefined;
    const resp = try buildLockResponseTrader(&resp_buf, head, .{
        .trader_id = 42,
        .available_money = 1000,
        .entries = &.{},
    });
    var r: binary.Reader = .{ .data = resp };
    var s_buf: [64]u8 = undefined;
    try std.testing.expectEqual(true, try r.readBool()); // locking echoed
    try std.testing.expectEqual(true, try r.readBool()); // success forced
    try std.testing.expectEqualStrings("", try r.readString(&s_buf)); // errorMsg
    try std.testing.expectEqual(false, try r.readBool()); // isForceUnlocked
    try std.testing.expectEqual(@as(u16, 3), try r.readU16()); // channel echoed
    try std.testing.expectEqual(@as(i32, 0), try r.readI32()); // targets count
    try std.testing.expectEqualStrings("EntityTraderLockContext", try r.readString(&s_buf));
    try std.testing.expectEqualStrings("trade", try r.readString(&s_buf));
    try std.testing.expectEqual(true, try r.readBool()); // hasTraderData

    // With locking=true both leading bools are true, so a swap between the
    // echoed locking and the forced success emits identical bytes. Repeat with
    // locking=false: the pair is then observable, and success must still be
    // forced true regardless.
    var req2_buf: [64]u8 = undefined;
    var w2: binary.Writer = .{ .buf = &req2_buf };
    try w2.writeBool(false); // locking
    try w2.writeU16(3);
    try w2.writeI32(0);
    try w2.writeString("EntityTraderLockContext");
    try w2.writeString("trade");
    const head2 = try parseLockRequest(w2.written());
    var resp2_buf: [512]u8 = undefined;
    const resp2 = try buildLockResponseTrader(&resp2_buf, head2, .{
        .trader_id = 42,
        .available_money = 1000,
        .entries = &.{},
    });
    try std.testing.expectEqual(@as(u8, 0), resp2[0]); // locking echoed false
    try std.testing.expectEqual(@as(u8, 1), resp2[1]); // success still forced

    // Same builder, vending context: VendingMachineLockContext::Read takes the
    // TraderData straight after the type name, with no Command and no
    // hasTraderData bool (TileEntityVendingMachine_VendingMachineLockContext
    // .il.txt:19). Emitting the entity shape here handed the client two extra
    // bytes it reads as the first half of TraderID.
    var vreq_buf: [64]u8 = undefined;
    var vw: binary.Writer = .{ .buf = &vreq_buf };
    try vw.writeBool(true);
    try vw.writeU16(3);
    try vw.writeI32(0);
    try vw.writeString(vending_lock_context);
    const vhead = try parseLockRequest(vw.written());
    var vresp_buf: [512]u8 = undefined;
    const vresp = try buildLockResponseTrader(&vresp_buf, vhead, .{
        .trader_id = 42,
        .available_money = 1000,
        .entries = &.{},
    });
    var vr: binary.Reader = .{ .data = vresp };
    _ = try vr.readBool(); // locking
    _ = try vr.readBool(); // success
    _ = try vr.readString(&s_buf); // errorMsg
    _ = try vr.readBool(); // isForceUnlocked
    _ = try vr.readU16(); // channel
    _ = try vr.readI32(); // targets count
    try std.testing.expectEqualStrings(vending_lock_context, try vr.readString(&s_buf));
    // TraderData begins immediately: its TraderID, not a command length byte.
    try std.testing.expectEqual(@as(i32, 42), try vr.readI32());
    // The two contexts must not produce the same tail length for equal data.
    try std.testing.expect(vresp.len < resp.len);
}

/// One biome weather snapshot (WeatherPackage on wire).
pub const WeatherBiome = struct {
    biome_id: u8 = 3,
    group_index: u8 = 0,
    /// Number of weather groups this biome has in the biomes.xml we serve. The
    /// client indexes weatherGroups with groupIndex unchecked, so this bounds it.
    group_count: u8 = 1,
    remaining_seconds: u8 = 0,
    /// temp, precip, cloud, wind, fog. Raw biomes.xml scale (temp F, rest 0..100);
    /// the client divides by 100 (BiomeWeather::FogPercent, asm.il ~2048596).
    params: [5]f32 = .{ 70, 0, 20, 10, 5 },
};

/// Stock NetPackageWeather: no count prefix; client sizes from its biomeWeather.Count.
/// Emit one entry per biomemap biome we care about (same count both sides ideally).
/// RE: weather-environment.md §3: biomeId u8, groupIndex u8, remainingSeconds u8, 5xf32.
///
/// groupIndex is clamped here because BiomeDefinition::SetWeatherGroup (asm.il
/// ~1250261) does an unchecked weatherGroups[_index]: an out-of-range index is an
/// unhandled exception inside ClientProcessPackages on an unmodified client.
/// Index 0 always exists for a biome that has weather at all.
pub fn buildWeatherBody(buf: []u8, biomes: []const WeatherBiome) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    for (biomes) |b| {
        try w.writeByte(b.biome_id);
        try w.writeByte(if (b.group_index < b.group_count) b.group_index else 0);
        try w.writeByte(b.remaining_seconds);
        for (b.params) |p| try w.writeF32(p);
    }
    return w.written();
}

test "weather body five biomes is 115" {
    var buf: [256]u8 = undefined;
    var biomes: [5]WeatherBiome = [_]WeatherBiome{.{}} ** 5;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        biomes[i].biome_id = @intCast(i + 1);
        biomes[i].group_index = @intCast(i);
        biomes[i].group_count = 11;
        biomes[i].remaining_seconds = @intCast(10 + i);
        biomes[i].params = .{ 70 + @as(f32, @floatFromInt(i)), 0.1, 0.2, 0.3, 0.4 };
    }
    const body = try buildWeatherBody(&buf, biomes[0..]);
    // 5 × (3 bytes + 5×f32) = 5 × 23 = 115
    try std.testing.expectEqual(@as(usize, 115), body.len);
    // Entry 0 layout: biomeId, groupIndex, remainingSeconds, then params[0] f32
    try std.testing.expectEqual(@as(u8, 1), body[0]);
    try std.testing.expectEqual(@as(u8, 0), body[1]);
    try std.testing.expectEqual(@as(u8, 10), body[2]);
    const temp0: f32 = @bitCast(std.mem.readInt(u32, body[3..7], .little));
    try std.testing.expectEqual(@as(f32, 70), temp0);
    // Entry 4 starts at 4*23 = 92
    try std.testing.expectEqual(@as(u8, 5), body[92]);
    try std.testing.expectEqual(@as(u8, 4), body[93]);
    try std.testing.expectEqual(@as(u8, 14), body[94]);
    const temp4: f32 = @bitCast(std.mem.readInt(u32, body[95..99], .little));
    try std.testing.expectEqual(@as(f32, 74), temp4);
}

test "weather body clamps out of range group index" {
    var buf: [128]u8 = undefined;
    const biomes = [_]WeatherBiome{
        .{ .biome_id = 3, .group_index = 5, .group_count = 11 },
        .{ .biome_id = 5, .group_index = 5, .group_count = 4 },
        .{ .biome_id = 8, .group_index = 0, .group_count = 0 },
    };
    const body = try buildWeatherBody(&buf, biomes[0..]);
    try std.testing.expectEqual(@as(usize, 69), body.len);
    try std.testing.expectEqual(@as(u8, 5), body[1]);
    // Index past the biome's group list would throw inside SetWeatherGroup.
    try std.testing.expectEqual(@as(u8, 0), body[24]);
    try std.testing.expectEqual(@as(u8, 0), body[47]);
}

pub const stock_chunkremove = @import("stock_chunkremove.zig");
pub const buildChunkRemoveBody = stock_chunkremove.buildChunkRemoveBody;
pub const parseChunkRemoveBody = stock_chunkremove.parseChunkRemoveBody;

pub const stock_collect = @import("stock_collect.zig");
pub const parseCollectBody = stock_collect.parseCollectBody;
pub const buildEntityCollectBody = stock_collect.buildEntityCollectBody;

pub const stock_denied = @import("stock_denied.zig");
pub const KickReason = stock_denied.KickReason;
pub const buildPlayerDeniedBody = stock_denied.buildPlayerDeniedBody;

test "PlayerDenied body matches stock field order and excludes the package id" {
    var buf: [64]u8 = undefined;
    const body = try buildPlayerDeniedBody(&buf, .mod_decision, 0, 0, "abc");
    // i32 + i32 + i64 + (1-byte 7-bit length + 3 bytes) = 20 bytes, which is
    // also stock GetLength() (asm.il:827105-827110) for a 3-char reason.
    try std.testing.expectEqual(@as(usize, 20), body.len);
    var r: binary.Reader = .{ .data = body };
    try std.testing.expectEqual(@as(i32, 0x10), try r.readI32());
    try std.testing.expectEqual(@as(i32, 0), try r.readI32());
    try std.testing.expectEqual(@as(i64, 0), try r.readI64());
    try std.testing.expectEqual(@as(u32, 3), try binary.read7BitEncodedInt(&r));
    try std.testing.expectEqualStrings("abc", body[body.len - 3 ..]);

    // framed() appends the body verbatim after the u16 package id that the base
    // NetPackage::write emits; the body must not carry a second copy of it.
    var framed_buf: [64]u8 = undefined;
    const f = try framed(&framed_buf, "NetPackagePlayerDenied", body);
    try std.testing.expect(std.mem.endsWith(u8, f, body));
    // frame header is 13 bytes (frame.framePackage), then u16 id, then body.
    try std.testing.expectEqual(@as(usize, 13 + 2) + body.len, f.len);

    const manual = try buildPlayerDeniedBody(&buf, .manual_kick, 0, 0, "");
    try std.testing.expectEqual(@as(i32, 0x0A), std.mem.readInt(i32, manual[0..4], .little));
    try std.testing.expectEqual(@as(usize, 17), manual.len);
}

/// Stock NetPackageChat: chatType u8 | sender i32 | msg string | msgSender u8 | bbMode u8 | recipCount i32 | ids...
pub const stock_gameevent = @import("stock_gameevent.zig");
pub const buildGameEventResponse = stock_gameevent.buildGameEventResponse;
pub const buildGameEventSequenceAction = stock_gameevent.buildGameEventSequenceAction;

pub const stock_console = @import("stock_console.zig");
pub const parseConsoleCmd = stock_console.parseConsoleCmd;
pub const buildConsoleCmdClient = stock_console.buildConsoleCmdClient;

pub const stock_chat = @import("stock_chat.zig");
pub const StockChat = stock_chat.StockChat;
pub const buildStockChat = stock_chat.buildStockChat;
pub const parseStockChat = stock_chat.parseStockChat;
pub const SoundAtPosition = stock_chat.SoundAtPosition;
pub const max_audio_clip_len: usize = stock_chat.max_audio_clip_len;
pub const parseSoundAtPosition = stock_chat.parseSoundAtPosition;
pub const buildSoundAtPosition = stock_chat.buildSoundAtPosition;
pub const ParticleEffectInvoke = stock_chat.ParticleEffectInvoke;
pub const parseParticleEffectInvoke = stock_chat.parseParticleEffectInvoke;

pub const stock_attach = @import("stock_attach.zig");
pub const AttachType = stock_attach.AttachType;
pub const slot_any: i16 = stock_attach.slot_any;
pub const buildEntityAttach = stock_attach.buildEntityAttach;
pub const parseEntityAttach = stock_attach.parseEntityAttach;
pub const attachTypeIsDetach = stock_attach.attachTypeIsDetach;

pub const SpawnPointEntry = stock_entity.SpawnPointEntry;

/// NetPackageWorldSpawnPoints body = SpawnPointList.Write (one stock shape).
/// Per-point payload = 26 bytes (stock GetLength lies with count*20).
pub const buildWorldSpawnPoints = stock_entity.buildWorldSpawnPointsBody;

test "world spawn points stock wire" {
    var buf: [128]u8 = undefined;
    const body = try buildWorldSpawnPoints(&buf, &[_]stock_entity.SpawnPointEntry{
        .{ .x = -273, .y = 61, .z = 449, .heading = 51 },
        .{ .x = 0, .y = 70, .z = 0 },
    });
    // 1 + 4 + 2*26
    try std.testing.expectEqual(@as(usize, 57), body.len);
    try std.testing.expectEqual(@as(u8, 2), body[0]);
    try std.testing.expectEqual(@as(i32, 2), std.mem.readInt(i32, body[1..5], .little));
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, body[5..7], .little));
    try std.testing.expectEqual(@as(f32, -273), @as(f32, @bitCast(std.mem.readInt(u32, body[7..11], .little))));
    try std.testing.expectEqual(@as(f32, 61), @as(f32, @bitCast(std.mem.readInt(u32, body[11..15], .little))));
    try std.testing.expectEqual(@as(f32, 449), @as(f32, @bitCast(std.mem.readInt(u32, body[15..19], .little))));
    try std.testing.expectEqual(@as(f32, 51), @as(f32, @bitCast(std.mem.readInt(u32, body[19..23], .little))));
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, body[23..27], .little));
    try std.testing.expectEqual(@as(i32, -1), std.mem.readInt(i32, body[27..31], .little));
}

test "world spawn points: 32 entries exceed the old 512-byte join buffer" {
    // Regression (2026-08-29 Pregen soak): sendWorldSpawnPoints built into a
    // 512-byte slice, but 32 entries need 837 bytes (26/entry + 5 header), so
    // maps with >= 20 spawn points overflowed on every enter. The join
    // handler now uses a 1024-byte slice; pin that the full cap fits.
    var pts: [32]stock_entity.SpawnPointEntry = undefined;
    for (&pts, 0..) |*p, i| p.* = .{ .x = @floatFromInt(i), .y = 60, .z = @floatFromInt(i) };
    var buf: [1024]u8 = undefined;
    const body = try buildWorldSpawnPoints(&buf, &pts);
    try std.testing.expect(body.len > 512); // the old slice could not hold it
    try std.testing.expect(body.len < buf.len);
}

pub const stock_areas = @import("stock_areas.zig");
pub const TraderTeleport = stock_areas.TraderTeleport;
pub const TraderAreaEntry = stock_areas.TraderAreaEntry;
pub const buildWorldAreasBody = stock_areas.buildWorldAreasBody;

pub const stock_velocity = @import("stock_velocity.zig");
pub const buildEntityVelocityBody = stock_velocity.buildEntityVelocityBody;

pub const stock_clientinfo = @import("stock_clientinfo.zig");
pub const ClientInfoEntry = stock_clientinfo.ClientInfoEntry;
pub const buildClientInfoBody = stock_clientinfo.buildClientInfoBody;
pub const buildPlayerSetBackpackPositionBody = stock_clientinfo.buildPlayerSetBackpackPositionBody;

pub const stock_turret = @import("stock_turret.zig");
pub const buildTurretSyncBody = stock_turret.buildTurretSyncBody;

pub const stock_positions = @import("stock_positions.zig");
pub const PlayerPositionEntry = stock_positions.PlayerPositionEntry;
pub const buildPersistentPlayerPositionsBody = stock_positions.buildPersistentPlayerPositionsBody;

pub const stock_claim = @import("stock_claim.zig");
pub const parseLandClaimRepair = stock_claim.parseLandClaimRepair;
pub const buildLandClaimRepairBody = stock_claim.buildLandClaimRepairBody;
pub const MapObjectType = stock_claim.MapObjectType;
pub const map_marker_remove_by_entity: i32 = stock_claim.map_marker_remove_by_entity;
pub const map_marker_remove_by_position: i32 = stock_claim.map_marker_remove_by_position;
pub const buildMapMarkerRemoveByEntity = stock_claim.buildMapMarkerRemoveByEntity;
pub const buildMapMarkerRemoveByPosition = stock_claim.buildMapMarkerRemoveByPosition;

pub const stock_nav = @import("stock_nav.zig");
pub const buildNavObjectAdd = stock_nav.buildNavObjectAdd;
pub const buildNavObjectRemove = stock_nav.buildNavObjectRemove;

pub const stock_explosion = @import("stock_explosion.zig");
pub const buildExplosionClient = stock_explosion.buildExplosionClient;

/// C2S ExplosionInitiate head (protocol-frames §12).
/// worldPos 3xf32 | blockPos 3xi32 | quat 4xf32 | blobLen u16 | blob | entityId i32 | delay f32 …
pub const ExplosionInitiate = struct {
    wx: f32 = 0,
    wy: f32 = 0,
    wz: f32 = 0,
    bx: i32 = 0,
    by: i32 = 0,
    bz: i32 = 0,
    entity_id: i32 = -1,
    delay_s: f32 = 0,
    /// Best-effort radius from nested blob (default 3).
    radius: f32 = 3,
    block_damage: u16 = 50,
    /// ExplosionData.EntityRadius, a raw i16 in blocks (default 3).
    entity_radius: f32 = 3,
    /// ExplosionData.entityDamage (default 0 -> falls back to block_damage).
    entity_damage: f32 = 0,
};

/// Read side of NetPackageExplosionInitiate (RE protocol-packages.md,
/// inventories/netpackage-bodies.md write IL=55): `worldPos` Vector3 |
/// `blockPos` Vector3i | `rotation` Quaternion | `explosionBlobLen` u16 + blob
/// | `entityId` i32 | `delay` f32 | `bRemoveBlockAtExplPosition` bool | item
/// present bool + ItemValue.
///
/// The two trailing fields are not read. `bRemoveBlockAtExplPosition` clears
/// the center block in stock (GameManager.ExplosionServer IL=50), which
/// c2s/blocks.zig does anyway, and the optional ItemValue feeds passives
/// 19/20/21 (block damage, entity damage, radius) that zdtd does not apply to
/// a client-supplied blast. Both sit at the end of the body, so skipping them
/// cannot desync the reader.
pub fn parseExplosionInitiate(body: []const u8) !ExplosionInitiate {
    var r: binary.Reader = .{ .data = body };
    var out: ExplosionInitiate = .{};
    out.wx = try readWorldF32(&r);
    out.wy = try readWorldF32(&r);
    out.wz = try readWorldF32(&r);
    out.bx = try readWorldI32(&r);
    out.by = try readWorldI32(&r);
    out.bz = try readWorldI32(&r);
    // quat 4xf32
    _ = try r.readF32();
    _ = try r.readF32();
    _ = try r.readF32();
    _ = try r.readF32();
    const blob_len = try r.readU16();
    if (blob_len > 0) {
        if (r.remaining() < blob_len) return error.EndOfStream;
        const blob = r.data[r.pos .. r.pos + blob_len];
        r.pos += blob_len;
        // ExplosionData.Read (IL): particleIndex i16 | duration i16*0.1 |
        // blockRadius i16*0.05 | entityRadius i16 | blastPower i16 |
        // blockDamage f32 | entityDamage f32 | blockTags string |
        // ignoreHeatMap bool | damageType i16 | DamageMultiplier(i16 n + pairs) |
        // buffCount u8 + strings. We consume through blockDamage; rest unused.
        var br: binary.Reader = .{ .data = blob };
        _ = br.readI16() catch 0; // particleIndex
        _ = br.readI16() catch 0; // duration deci-seconds
        const radius_raw = br.readI16() catch 0;
        if (radius_raw > 0) out.radius = @as(f32, @floatFromInt(radius_raw)) * 0.05;
        // EntityRadius is a raw i16 in blocks: the RE table notes a scale
        // factor on Duration (x10) and BlockRadius (x20) and leaves this row
        // blank (protocol-packages.md ExplosionData, Read IL=82). Dividing it
        // by 20 as well turned the stock value 6 into 0.3, which the caller
        // then clamped up to its 1 m floor, so a stock explosion barely
        // reached any entity while its block damage worked normally.
        if (br.readI16()) |er| {
            if (er > 0) out.entity_radius = @floatFromInt(er);
        } else |_| {}
        _ = br.readI16() catch 0; // blastPower
        if (br.readF32()) |bd| {
            if (bd > 0 and bd <= 65535) out.block_damage = @trunc(bd);
        } else |_| {}
        if (br.readF32()) |ed| {
            if (ed > 0 and ed <= 65535) out.entity_damage = ed;
        } else |_| {}
    }
    if (r.remaining() >= 4) out.entity_id = try r.readI32();
    if (r.remaining() >= 4) out.delay_s = try r.readF32();
    return out;
}

test "explosion initiate parse head" {
    var buf: [128]u8 = undefined;
    var w: binary.Writer = .{ .buf = &buf };
    try w.writeF32(1);
    try w.writeF32(70);
    try w.writeF32(2);
    try w.writeI32(1);
    try w.writeI32(70);
    try w.writeI32(2);
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(1);
    try w.writeU16(0);
    try w.writeI32(106);
    try w.writeF32(0.5);
    const p = try parseExplosionInitiate(w.written());
    try std.testing.expectApproxEqAbs(@as(f32, 1), p.wx, 0.01);
    try std.testing.expectEqual(@as(i32, 70), p.by);
    try std.testing.expectEqual(@as(i32, 106), p.entity_id);
}

test "explosion initiate parses ExplosionData blob positionally" {
    var buf: [160]u8 = undefined;
    var w: binary.Writer = .{ .buf = &buf };
    try w.writeF32(1);
    try w.writeF32(70);
    try w.writeF32(2);
    try w.writeI32(1);
    try w.writeI32(70);
    try w.writeI32(2);
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(1);
    // ExplosionData blob: particle 3, duration 10, blockRadius raw 80 (=4.0),
    // entityRadius 4, blastPower 100, blockDamage 250.0, entityDamage 60.0
    var blob_buf: [64]u8 = undefined;
    var bw: binary.Writer = .{ .buf = &blob_buf };
    try bw.writeI16(3);
    try bw.writeI16(10);
    try bw.writeI16(80);
    try bw.writeI16(4);
    try bw.writeI16(100);
    try bw.writeF32(250.0);
    try bw.writeF32(60.0);
    const blob = bw.written();
    try w.writeU16(@intCast(blob.len));
    try w.writeBytes(blob);
    try w.writeI32(107);
    try w.writeF32(0);
    const p = try parseExplosionInitiate(w.written());
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), p.radius, 0.01);
    try std.testing.expectEqual(@as(u16, 250), p.block_damage);
    try std.testing.expectEqual(@as(i32, 107), p.entity_id);
}

/// zdtd-native quest accept/progress, **not a stock client wire body**:
/// def_id u16, op u8 (0=list, 1=accept, 2=abandon). Kept for unit and loadgen
/// fixtures. The stock quest C2S shapes are NetPackageNPCQuestList
/// (parseNpcQuestList) and NetPackageQuestObjectiveUpdate, both tried before
/// this one in c2s/quest.zig.
pub fn parseQuestOp(body: []const u8) !struct { def_id: u16, op: u8 } {
    if (body.len < 3) return error.EndOfStream;
    return .{
        .def_id = std.mem.readInt(u16, body[0..2], .little),
        .op = body[2],
    };
}

// --- Stock NetPackageNPCQuestList (V3.x) ---
// eventType: 0 FetchList, 1 RemoveQuest, 2 ResetQuests, 3 AddUsedPOI, 4 ClearUsedPOI

pub const NpcQuestEventType = enum(u8) {
    fetch_list = 0,
    remove_quest = 1,
    reset_quests = 2,
    add_used_poi = 3,
    clear_used_poi = 4,
};

pub const NpcQuestListHead = struct {
    npc_entity_id: i32,
    player_entity_id: i32,
    event_type: NpcQuestEventType,
    tier_level: i32 = 0,
    remove_index: u8 = 0,
};

/// Read side of NetPackageNPCQuestList (RE protocol-packages.md, Process
/// IL=180): `npcEntityID` i32 | `playerEntityID` i32 | `eventType` u8, then a
/// type-dependent tail. Only the head and `tierLevel` are decoded here; the
/// FetchList entry list, POI vectors and the RemoveQuest index beyond
/// `remove_index` are tails the server never needs to read back, since it is
/// the side that produces them.
///
/// An `eventType` outside the five stock values is rejected: stock switches on
/// it, so a sixth selects no tail and nothing sensible to answer.
pub fn parseNpcQuestList(body: []const u8) !NpcQuestListHead {
    if (body.len < 9) return error.EndOfStream;
    const npc = std.mem.readInt(i32, body[0..4], .little);
    const player = std.mem.readInt(i32, body[4..8], .little);
    const et_raw = body[8];
    const et = std.enums.fromInt(NpcQuestEventType, et_raw) orelse return error.InvalidEvent;
    var head: NpcQuestListHead = .{
        .npc_entity_id = npc,
        .player_entity_id = player,
        .event_type = et,
    };
    if (et == .fetch_list or et == .remove_quest or et == .add_used_poi or et == .clear_used_poi) {
        if (body.len < 13) return error.EndOfStream;
        head.tier_level = std.mem.readInt(i32, body[9..13], .little);
        if (et == .remove_quest) {
            if (body.len < 14) return error.EndOfStream;
            head.remove_index = body[13];
        }
    }
    return head;
}

/// NetPackageNPCQuestList, S2C FetchList with QuestPacketEntry offers (stock
/// trader UI): npc i32 | player i32 | eventType u8 | tier i32 | entry count i32
/// | count x QuestPacketEntry. Empty offers: pass `entries` as `&.{}`.
pub const buildNpcQuestListFetch = stock_quest.buildNpcQuestListFetch;

// --- Stock NetPackageQuestObjectiveUpdate (V3.x) ---
// senderEntityID i32 | questCode i32 | eventType u8 | blockPos Vector3i

pub const QuestObjectiveEventType = enum(u8) {
    treasure_radius_break = 0,
    treasure_complete = 1,
    block_activated = 2,
};

pub const QuestObjectiveUpdate = struct {
    sender_entity_id: i32,
    quest_code: i32,
    event_type: QuestObjectiveEventType,
    block_x: i32 = 0,
    block_y: i32 = 0,
    block_z: i32 = 0,
};

/// Read side of NetPackageQuestObjectiveUpdate (RE
/// inventories/netpackage-bodies.md, write IL=21): `senderEntityID` i32 |
/// `questCode` i32 | `eventType` u8 | `blockPos` (StreamUtils Vector3i), the
/// order buildQuestObjectiveUpdate writes.
///
/// The trailing block position is optional here while stock always writes it:
/// a 9-byte body leaves the position zero rather than erroring, which is what
/// keeps the zdtd-native {def_id u16, op u8} fixtures in c2s/quest.zig
/// parseable. An `eventType` outside the three stock values is rejected, since
/// stock switches on it and a fourth has no objective to advance.
pub fn parseQuestObjectiveUpdate(body: []const u8) !QuestObjectiveUpdate {
    if (body.len < 9) return error.EndOfStream;
    const et_raw = body[8];
    const et = std.enums.fromInt(QuestObjectiveEventType, et_raw) orelse return error.InvalidEvent;
    var out: QuestObjectiveUpdate = .{
        .sender_entity_id = std.mem.readInt(i32, body[0..4], .little),
        .quest_code = std.mem.readInt(i32, body[4..8], .little),
        .event_type = et,
    };
    if (body.len >= 21) {
        out.block_x = std.mem.readInt(i32, body[9..13], .little);
        out.block_y = std.mem.readInt(i32, body[13..17], .little);
        out.block_z = std.mem.readInt(i32, body[17..21], .little);
    }
    return out;
}

/// NetPackageQuestObjectiveUpdate (RE inventories/netpackage-bodies.md, write
/// IL=21): `senderEntityID` i32 | `questCode` i32 | `eventType` u8 |
/// `blockPos` (StreamUtils Vector3i = three i32).
pub fn buildQuestObjectiveUpdate(buf: []u8, u: QuestObjectiveUpdate) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(u.sender_entity_id);
    try w.writeI32(u.quest_code);
    try w.writeByte(@intFromEnum(u.event_type));
    try w.writeI32(u.block_x);
    try w.writeI32(u.block_y);
    try w.writeI32(u.block_z);
    return w.written();
}

test "entity attach layout" {
    var buf: [32]u8 = undefined;
    const body = try buildEntityAttach(&buf, .attach_server, 106, 50, 0);
    try std.testing.expectEqual(@as(usize, 11), body.len);
    const a = try parseEntityAttach(body);
    try std.testing.expectEqual(AttachType.attach_server, a.attach_type);
    try std.testing.expectEqual(@as(i32, 106), a.rider_id);
    try std.testing.expectEqual(@as(i32, 50), a.vehicle_id);
    try std.testing.expectEqual(@as(i16, 0), a.slot);
}

test "entity attach carries the stock mount and dismount shapes" {
    var buf: [32]u8 = undefined;
    // Mount request: EntityVehicle::EnterVehicle sends slot -1 (asm.il:541872).
    const mount = try parseEntityAttach(try buildEntityAttach(&buf, .attach_server, 171, 63, slot_any));
    try std.testing.expectEqual(slot_any, mount.slot);
    // Dismount request: Entity::SendDetach sends vehicleId -1 and slot -1
    // (asm.il:406816), so the server must resolve the hull itself.
    const detach = try parseEntityAttach(try buildEntityAttach(&buf, .detach_server, 171, -1, slot_any));
    try std.testing.expectEqual(@as(i32, -1), detach.vehicle_id);
    try std.testing.expectEqual(slot_any, detach.slot);
    try std.testing.expect(attachTypeIsDetach(detach.attach_type));
    // Slot is int32 in memory but int16 on the wire (conv.i2, asm.il:844620).
    const wide = try parseEntityAttach(try buildEntityAttach(&buf, .attach_client, 1, 2, 32767));
    try std.testing.expectEqual(@as(i16, 32767), wide.slot);

    // Derived from the enum, not a hand-listed set: a new variant must be
    // covered here automatically rather than slipping through untested.
    for (std.enums.values(AttachType)) |t| {
        const rt = try parseEntityAttach(try buildEntityAttach(&buf, t, -2147483648, 2147483647, -32768));
        try std.testing.expectEqual(t, rt.attach_type);
        try std.testing.expectEqual(@as(i32, -2147483648), rt.rider_id);
        try std.testing.expectEqual(@as(i32, 2147483647), rt.vehicle_id);
        try std.testing.expectEqual(@as(i16, -32768), rt.slot);
    }
    // AttachType only has 0..3 (asm.il:844620); anything else is not a package.
    var bogus = [_]u8{4} ++ [_]u8{0} ** 10;
    try std.testing.expectError(error.InvalidEvent, parseEntityAttach(&bogus));
    try std.testing.expectError(error.EndOfStream, parseEntityAttach(bogus[0..10]));
}

test "vehicle data sync header framing" {
    // senderId | vehicleId | syncFlags | dataLen | data
    var body: [16]u8 = .{ 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 4, 0, 9, 8, 7, 6 };
    const s = try parseVehicleDataSync(&body);
    try std.testing.expectEqual(@as(i32, 1), s.sender_id);
    try std.testing.expectEqual(@as(i32, 2), s.vehicle_id);
    try std.testing.expectEqual(@as(u16, 3), s.sync_flags);
    try std.testing.expectEqualSlices(u8, &.{ 9, 8, 7, 6 }, s.data);
    // A truncated payload must never hand out bytes past the body.
    try std.testing.expectError(error.EndOfStream, parseVehicleDataSync(body[0..15]));
    try std.testing.expectError(error.EndOfStream, parseVehicleDataSync(body[0..11]));
    // Empty payload is legal framing.
    const empty = try parseVehicleDataSync(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(usize, 0), empty.data.len);
}

test "entity spawn response and teleport layout" {
    var buf: [64]u8 = undefined;
    const sr = try buildEntitySpawnResponse(&buf, true, null);
    try std.testing.expectEqual(@as(usize, 2), sr.len); // success + empty ItemValue
    try std.testing.expectEqual(@as(u8, 1), sr[0]);
    try std.testing.expectEqual(@as(u8, 0), sr[1]);
    const tp = try buildEntityTeleportBody(&buf, 106, 1, 70, 2, 0, 90, 0, true);
    const p = try parsePosAndRotBody(tp);
    try std.testing.expectEqual(@as(i32, 106), p.entity_id);
    try std.testing.expectApproxEqAbs(@as(f32, 1), p.x, 0.01);
}

test "stock trader data snapshot layout" {
    var buf: [512]u8 = undefined;
    const items = [_]TraderStockEntry{
        .{ .item = .{ .type_id = stock_inv.items_start_here + 2, .count = 5, .quality = 1 }, .markup = 0 },
    };
    const body = try buildTraderDataStock(&buf, 50, 50, 1000, items[0..]);
    // Envelope: entity-id branch only, no tePosition (asm.il 839492-839540).
    var r: binary.Reader = .{ .data = body };
    try std.testing.expectEqual(true, try r.readBool()); // entityId != -1
    try std.testing.expectEqual(@as(i32, 50), try r.readI32()); // entityId
    try std.testing.expectEqual(true, try r.readBool()); // hasTraderData
    // TraderData.Write (asm.il 857508-857528)
    try std.testing.expectEqual(@as(i32, 50), try r.readI32()); // TraderID
    try std.testing.expectEqual(@as(u64, 0), try r.readU64()); // lastInventoryUpdate
    try std.testing.expectEqual(@as(u8, 2), try r.readByte()); // FileVersion
    // WriteInventoryData (asm.il 857530-857594)
    try std.testing.expectEqual(@as(i32, 1), try r.readI32()); // PrimaryInventory count
    // Entry.Write (asm.il 856889-856907): ItemStack + i8 markup + bool addedByPlayer.
    const slot = try stock_inv.readItemStack(&r);
    try std.testing.expectEqual(@as(u16, 5), slot.count);
    try std.testing.expectEqual(@as(i8, 0), @as(i8, @bitCast(try r.readByte()))); // Markup
    try std.testing.expectEqual(false, try r.readBool()); // AddedByPlayer
    try std.testing.expectEqual(@as(u8, 0), try r.readByte()); // TierItemGroups count
    try std.testing.expectEqual(@as(i32, 1000), try r.readI32()); // AvailableMoney
    try std.testing.expectEqual(body.len, r.pos);
}

test "trader data snapshot holds the stock 50-entry window (MaxItems)" {
    var buf: [4096]u8 = undefined;
    var items: [components.max_stock]TraderStockEntry = undefined;
    for (&items, 0..) |*it, i| {
        it.* = .{ .item = .{ .type_id = stock_inv.items_start_here + 2, .count = 5, .quality = 1 } };
        _ = i;
    }
    const body = try buildTraderDataStock(&buf, 50, 50, 1000, items[0..]);
    var r: binary.Reader = .{ .data = body };
    try std.testing.expectEqual(true, try r.readBool());
    _ = try r.readI32();
    try std.testing.expectEqual(true, try r.readBool());
    _ = try r.readI32();
    _ = try r.readU64();
    _ = try r.readByte();
    try std.testing.expectEqual(@as(i32, components.max_stock), try r.readI32());
    var i: usize = 0;
    while (i < components.max_stock) : (i += 1) {
        const slot = try stock_inv.readItemStack(&r);
        try std.testing.expectEqual(@as(u16, 5), slot.count);
        _ = try r.readByte();
        try std.testing.expectEqual(false, try r.readBool());
    }
    try std.testing.expectEqual(@as(u8, 0), try r.readByte());
    try std.testing.expectEqual(@as(i32, 1000), try r.readI32());
    try std.testing.expectEqual(body.len, r.pos);
}

test "stock npc quest list empty fetch layout" {
    var buf: [32]u8 = undefined;
    const body = try buildNpcQuestListFetch(&buf, 50, 106, 0, &.{});
    try std.testing.expectEqual(@as(usize, 17), body.len);
    const head = try parseNpcQuestList(body);
    try std.testing.expectEqual(@as(i32, 50), head.npc_entity_id);
    try std.testing.expectEqual(@as(i32, 106), head.player_entity_id);
    try std.testing.expectEqual(NpcQuestEventType.fetch_list, head.event_type);
    try std.testing.expectEqual(@as(i32, 0), head.tier_level);
    // entry count follows tier
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, body[13..17], .little));
}

test "stock quest objective update layout" {
    var buf: [32]u8 = undefined;
    const body = try buildQuestObjectiveUpdate(&buf, .{
        .sender_entity_id = 106,
        .quest_code = 1,
        .event_type = .block_activated,
        .block_x = 10,
        .block_y = 70,
        .block_z = 20,
    });
    try std.testing.expectEqual(@as(usize, 21), body.len);
    const u = try parseQuestObjectiveUpdate(body);
    try std.testing.expectEqual(@as(i32, 106), u.sender_entity_id);
    try std.testing.expectEqual(@as(i32, 1), u.quest_code);
    try std.testing.expectEqual(QuestObjectiveEventType.block_activated, u.event_type);
    // Whole block position: y and z were unread, so a swap would advance the
    // objective against a different block than the one the client activated.
    try std.testing.expectEqual(@as(i32, 10), u.block_x);
    try std.testing.expectEqual(@as(i32, 70), u.block_y);
    try std.testing.expectEqual(@as(i32, 20), u.block_z);
}

test "every declared npc quest and objective event variant parses" {
    // Both parsers derive their bound from the enum via std.enums.fromInt, so
    // a new variant stays legal on the wire instead of becoming InvalidEvent.
    for (std.enums.values(NpcQuestEventType)) |ev| {
        // 14 bytes covers the longest tail (remove_quest adds remove_index).
        var body: [14]u8 = @splat(0);
        std.mem.writeInt(i32, body[0..4], 50, .little);
        std.mem.writeInt(i32, body[4..8], 106, .little);
        body[8] = @intFromEnum(ev);
        const head = try parseNpcQuestList(&body);
        try std.testing.expectEqual(ev, head.event_type);
    }
    for (std.enums.values(QuestObjectiveEventType)) |ev| {
        var body: [21]u8 = @splat(0);
        std.mem.writeInt(i32, body[0..4], 106, .little);
        std.mem.writeInt(i32, body[4..8], 1, .little);
        body[8] = @intFromEnum(ev);
        const u = try parseQuestObjectiveUpdate(&body);
        try std.testing.expectEqual(ev, u.event_type);
    }
}

pub const stock_trade = @import("stock_trade.zig");
pub const parseTraderTrade = stock_trade.parseTraderTrade;
pub const VendingMachineAccess = stock_trade.VendingMachineAccess;
pub const parseVendingMachineAccess = stock_trade.parseVendingMachineAccess;
pub const buildTraderTradeBody = stock_trade.buildTraderTradeBody;
pub const TraderDataToServer = stock_trade.TraderDataToServer;
pub const parseTraderDataToServer = stock_trade.parseTraderDataToServer;
pub const PickupBlock = stock_trade.PickupBlock;
pub const parsePickupBlockBody = stock_trade.parsePickupBlockBody;
pub const buildPickupBlockBody = stock_trade.buildPickupBlockBody;
pub const parseItemReload = stock_trade.parseItemReload;
pub const SetBlockTexture = stock_trade.SetBlockTexture;
pub const parseSetBlockTexture = stock_trade.parseSetBlockTexture;
pub const buildSetBlockTextureBody = stock_trade.buildSetBlockTextureBody;

pub const stock_vehicle = @import("stock_vehicle.zig");
pub const VehicleDataSync = stock_vehicle.VehicleDataSync;
pub const parseVehicleDataSync = stock_vehicle.parseVehicleDataSync;
pub const vehicle_control_len: usize = stock_vehicle.vehicle_control_len;
pub const parseVehicleControl = stock_vehicle.parseVehicleControl;
pub const buildVehicleControlBody = stock_vehicle.buildVehicleControlBody;

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

test "chunk body layout size and fields" {
    var heights: [256]u8 = .{64} ** 256;
    heights[5 + 5 * 16] = 70;
    var buf: [300]u8 = undefined;
    const body = try buildChunkBody(&buf, 1, -2, &heights);
    try std.testing.expectEqual(chunk_stock_envelope_overhead + chunk_body_size, body.len);
    try std.testing.expectEqual(@as(u8, 1), body[0]); // overwrite
    const p = try parseChunkBody(body);
    try std.testing.expectEqual(@as(i32, 1), p.cx);
    try std.testing.expectEqual(@as(i32, -2), p.cz);
    try std.testing.expectEqual(@as(u8, 70), p.heights[5 + 5 * 16]);
    // The envelope's three i16 are cx, cy, cz. The parser reads cx and cz by
    // offset, so it would agree with the writer even if both moved together;
    // read the raw words instead. Layout: overwrite bool | cx | cy | cz | len.
    try std.testing.expectEqual(@as(i16, 1), std.mem.readInt(i16, body[1..3], .little));
    try std.testing.expectEqual(@as(i16, 0), std.mem.readInt(i16, body[3..5], .little)); // cy
    try std.testing.expectEqual(@as(i16, -2), std.mem.readInt(i16, body[5..7], .little));
    try std.testing.expectEqual(@as(i32, chunk_body_size), std.mem.readInt(i32, body[7..11], .little));

    // bare payload still parses
    const bare = try buildChunkPayload(buf[0..chunk_body_size], 3, 4, &heights);
    const p2 = try parseChunkBody(bare);
    try std.testing.expectEqual(@as(i32, 3), p2.cx);
    try std.testing.expectEqual(@as(i32, 4), p2.cz);
    // Payload head is cx | cz | ydim as i32, ydim distinct from both coords.
    try std.testing.expectEqual(@as(i32, 3), std.mem.readInt(i32, bare[0..4], .little));
    try std.testing.expectEqual(@as(i32, 4), std.mem.readInt(i32, bare[4..8], .little));
    try std.testing.expectEqual(@as(i32, 256), std.mem.readInt(i32, bare[8..12], .little));
}

test "chunk key roundtrip" {
    const key = makeChunkKey(-18, 28);
    try std.testing.expectEqual(@as(i32, -18), extractChunkKeyX(key));
    try std.testing.expectEqual(@as(i32, 28), extractChunkKeyZ(key));
    var buf: [16]u8 = undefined;
    const body = try buildChunkRemoveBody(&buf, -18, 28);
    const p = try parseChunkRemoveBody(body);
    try std.testing.expectEqual(@as(i32, -18), p.cx);
    try std.testing.expectEqual(@as(i32, 28), p.cz);
}

// --- Identity-bearing packages (PlatformUserIdentifierAbs) ---

pub const stock_login = @import("stock_login.zig");
pub const PlayerLogin = stock_login.PlayerLogin;
pub const parsePlayerLogin = stock_login.parsePlayerLogin;
pub const AllyRequest = stock_login.AllyRequest;
pub const buildAllyRequestBody = stock_login.buildAllyRequestBody;
pub const parseAllyRequest = stock_login.parseAllyRequest;
pub const WaypointInvite = stock_login.WaypointInvite;
pub const max_waypoint_str: usize = stock_login.max_waypoint_str;
pub const parseWaypointInvite = stock_login.parseWaypointInvite;
pub const buildWaypointInviteBody = stock_login.buildWaypointInviteBody;
pub const WaypointEntry = stock_login.WaypointEntry;
pub const buildEntityWaypointListBody = stock_login.buildEntityWaypointListBody;
pub const PartyQuestChange = stock_login.PartyQuestChange;
pub const parsePartyQuestChange = stock_login.parsePartyQuestChange;
pub const buildAllyResponseBody = stock_login.buildAllyResponseBody;

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

// --- Stock NetPackageInventoryTransactionRequest parse (RE protocol-packages.md
// 6.13, items.md 2060-2087, InventoryOperation.Write IL) ---
//
// Body: i32 count, then per inventory: Guid key (16 bytes, .NET little-endian)
// + i32 initialHash + i32 finalHash + i32 opCount + opCount x
// InventoryOperation.Write. Each op: i16 operation (0 SetAbsolute, 1
// SetRelative, 2 SetAll); SetAbsolute/SetRelative write ItemStack.Write + i32
// index; SetAll writes ItemStack.WriteArray. The stock client sends this for
// container/backpack transactions; zdtd's native 11-byte body is tried first.

/// SetAll stack cap per op: stock backpack size is 36; 128 bounds hostile input.
pub const stock_tx_setall_cap: usize = 128;

pub const StockInvOp = struct {
    op: u8,
    stack: stock_inv.StockSlot = .{},
    index: i32 = 0,
    /// SetAll (op 2): NewStacks array; empty when op != 2 or null array.
    new_stacks: [stock_tx_setall_cap]stock_inv.StockSlot = undefined,
    new_n: u16 = 0,
};

/// Ops per inventory (a stock backpack move is 1-2; cap bounds hostile input).
pub const stock_tx_op_cap: usize = 8;
pub const stock_tx_entry_cap: usize = 4;

pub const StockInvEntry = struct {
    guid: [16]u8,
    initial_hash: i32,
    final_hash: i32,
    ops: [stock_tx_op_cap]StockInvOp = undefined,
    op_n: u8 = 0,
};

pub const StockInvTx = struct {
    entries: [stock_tx_entry_cap]StockInvEntry = undefined,
    entry_n: u8 = 0,
};

/// Read side of the stock NetPackageInventoryTransactionRequest body, one
/// InventoryTransaction.Write (RE inventories/netpackage-bodies.md, Write
/// IL=75): a nested op list of count | count | `Key` Vector3i | `InitialHash`
/// i32 | `FinalHash` i32 | ops count | InventoryOperation.Write each.
///
/// Returns error.EndOfStream on truncation and error.InvalidArgument when the
/// layout is not stock-shaped, which is how c2s/inv.zig knows to fall back to
/// the compact zdtd body (parseInvTxRequest).
pub fn parseStockInvTx(body: []const u8) !StockInvTx {
    var r: binary.Reader = .{ .data = body };
    var out: StockInvTx = .{};
    const count = try r.readI32();
    if (count < 0 or count > stock_tx_entry_cap) return error.InvalidArgument;
    var i: usize = 0;
    while (i < @as(usize, @intCast(count))) : (i += 1) {
        const e = &out.entries[i];
        for (&e.guid) |*b| b.* = try r.readByte();
        e.initial_hash = try r.readI32();
        e.final_hash = try r.readI32();
        const op_count = try r.readI32();
        if (op_count < 0 or op_count > stock_tx_op_cap) return error.InvalidArgument;
        var k: usize = 0;
        while (k < @as(usize, @intCast(op_count))) : (k += 1) {
            const op_raw = try r.readI16();
            if (op_raw < 0 or op_raw > 2) return error.InvalidArgument;
            const op: u8 = @intCast(op_raw);
            const oe = &e.ops[k];
            oe.op = op;
            if (op == 2) {
                // SetAll: ItemStack.WriteArray (i16 count; -1 = null array).
                const n = try r.readI16();
                if (n == -1) {
                    oe.new_n = 0; // null NewStacks
                    continue;
                }
                if (n < 0 or n > stock_tx_setall_cap) return error.InvalidArgument;
                var j: i16 = 0;
                while (j < n) : (j += 1) {
                    oe.new_stacks[@intCast(j)] = try stock_inv.readItemStack(&r);
                }
                oe.new_n = @intCast(n);
            } else {
                oe.stack = try stock_inv.readItemStack(&r);
                oe.index = try r.readI32();
            }
        }
        e.op_n = @intCast(op_count);
        out.entry_n = @intCast(count);
    }
    return out;
}

test "parseStockInvTx reads the stock InventoryTransaction layout" {
    // Golden bytes per RE (items.md 2060-2087, InventoryOperation Write IL):
    // count 1; one inventory: 16-byte Guid, initialHash, finalHash, opCount 1,
    // then one SetAbsolute op (i16 0, ItemStack.Write, i32 index).
    var buf: [256]u8 = undefined;
    var w: binary.Writer = .{ .buf = &buf };
    try w.writeI32(1); // inventoryCount
    // Guid: 16 bytes (0x00..0x0F).
    for (0..16) |i| try w.writeByte(@intCast(i));
    try w.writeI32(111); // initialHash
    try w.writeI32(222); // finalHash
    try w.writeI32(1); // opCount
    try w.writeI16(0); // SetAbsolute
    try stock_inv.writeItemStack(&w, .{ .type_id = 800, .count = 1, .quality = 1 });
    try w.writeI32(3); // index slot 3
    const tx = try parseStockInvTx(w.written());
    try std.testing.expectEqual(@as(u8, 1), tx.entry_n);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }, &tx.entries[0].guid);
    try std.testing.expectEqual(@as(i32, 111), tx.entries[0].initial_hash);
    try std.testing.expectEqual(@as(i32, 222), tx.entries[0].final_hash);
    try std.testing.expectEqual(@as(u8, 1), tx.entries[0].op_n);
    try std.testing.expectEqual(@as(u8, 0), tx.entries[0].ops[0].op);
    try std.testing.expectEqual(@as(i32, 3), tx.entries[0].ops[0].index);
    try std.testing.expectEqual(@as(u16, 1), tx.entries[0].ops[0].stack.count);
    try std.testing.expectEqual(@as(i32, 800), tx.entries[0].ops[0].stack.type_id);

    // SetAll op: i16 2 + ItemStack.WriteArray (i16 count, -1 = null).
    var buf2: [256]u8 = undefined;
    var w2: binary.Writer = .{ .buf = &buf2 };
    try w2.writeI32(1);
    for (0..16) |i| try w2.writeByte(@intCast(i));
    try w2.writeI32(1);
    try w2.writeI32(2);
    try w2.writeI32(1); // opCount
    try w2.writeI16(2); // SetAll
    try w2.writeI16(2); // array count
    try stock_inv.writeItemStack(&w2, .{ .type_id = 800, .count = 5, .quality = 1 });
    try stock_inv.writeItemStack(&w2, .{ .type_id = 801, .count = 2, .quality = 1 });
    const tx2 = try parseStockInvTx(w2.written());
    try std.testing.expectEqual(@as(u8, 1), tx2.entries[0].op_n);
    try std.testing.expectEqual(@as(u8, 2), tx2.entries[0].ops[0].op);
    try std.testing.expectEqual(@as(u16, 2), tx2.entries[0].ops[0].new_n);
    try std.testing.expectEqual(@as(i32, 800), tx2.entries[0].ops[0].new_stacks[0].type_id);
    try std.testing.expectEqual(@as(i32, 801), tx2.entries[0].ops[0].new_stacks[1].type_id);

    // Null WriteArray: i16 -1 decodes to an empty stack list.
    var buf3: [256]u8 = undefined;
    var w3: binary.Writer = .{ .buf = &buf3 };
    try w3.writeI32(1);
    for (0..16) |i| try w3.writeByte(@intCast(i));
    try w3.writeI32(1);
    try w3.writeI32(2);
    try w3.writeI32(1);
    try w3.writeI16(2);
    try w3.writeI16(-1);
    const tx3 = try parseStockInvTx(w3.written());
    try std.testing.expectEqual(@as(u8, 2), tx3.entries[0].ops[0].op);
    try std.testing.expectEqual(@as(u16, 0), tx3.entries[0].ops[0].new_n);

    // A native 11-byte body must NOT parse as a stock transaction.
    var native: [11]u8 = .{ 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0 };
    try std.testing.expectError(error.EndOfStream, parseStockInvTx(&native));
}

test "parseTraderDataToServer reads the stock ToServer body" {
    // RE protocol-packages.md 6.23: isEntity bool | entityId i32 (or
    // tePosition 3xi32) | hasTraderData bool | TraderData.Write.
    var buf: [64]u8 = undefined;
    var w: binary.Writer = .{ .buf = &buf };
    try w.writeBool(true); // isEntity
    try w.writeI32(1001); // entityId
    try w.writeBool(true); // hasTraderData
    try w.writeI32(3); // TraderData.TraderID
    try w.writeU64(7); // lastInventoryUpdate
    try w.writeByte(0); // trailing u8
    const td = try parseTraderDataToServer(w.written());
    try std.testing.expect(td.is_entity);
    try std.testing.expectEqual(@as(i32, 1001), td.entity_id);
    try std.testing.expect(td.has_trader_data);
    try std.testing.expectEqual(@as(i32, 3), std.mem.readInt(i32, td.trader_data[0..4], .little));
    // Vending machine branch: isEntity false + tePosition.
    var buf2: [64]u8 = undefined;
    var w2: binary.Writer = .{ .buf = &buf2 };
    try w2.writeBool(false);
    try w2.writeI32(10);
    try w2.writeI32(70);
    try w2.writeI32(20);
    try w2.writeBool(false); // no trader data
    const td2 = try parseTraderDataToServer(w2.written());
    try std.testing.expect(!td2.is_entity);
    try std.testing.expectEqual(@as(i32, 10), td2.te_x);
    try std.testing.expect(!td2.has_trader_data);
}

test "buildPickupBlockBody echoes the S2C pickup with a null identity" {
    var buf: [64]u8 = undefined;
    const out = try buildPickupBlockBody(&buf, 7, 8, 9, 0x1234, 42);
    // Body is 3x4 + 4 + 4 + 1 null-identity byte.
    try std.testing.expectEqual(@as(usize, 21), out.len);
    var plat: [platform_user.max_platform_len]u8 = undefined;
    var id: [platform_user.max_id_len]u8 = undefined;
    var sent2: ?platform_user.Id = null;
    const p = try parsePickupBlockBody(out, &plat, &id, &sent2);
    try std.testing.expect(sent2 == null);
    // Whole position: y and z had nothing reading them back, so a swap in the
    // triple would pick up a different block than the client asked for.
    try std.testing.expectEqual(@as(i32, 7), p.x);
    try std.testing.expectEqual(@as(i32, 8), p.y);
    try std.testing.expectEqual(@as(i32, 9), p.z);
    try std.testing.expectEqual(@as(u32, 0x1234), p.raw);
    try std.testing.expectEqual(@as(i32, 42), p.player_id);
}

test "parseSetBlockTexture reads the stock paint body" {
    var buf: [32]u8 = undefined;
    var w: binary.Writer = .{ .buf = &buf };
    try w.writeI32(5);
    try w.writeI32(60);
    try w.writeI32(-8);
    try w.writeByte(3); // face
    try w.writeByte(17); // catalog idx
    try w.writeI32(-1); // dedi rebroadcast playerIdThatChanged
    try w.writeByte(0); // channel
    const t = try parseSetBlockTexture(w.written());
    // Whole position: only x was read back, so y and z could swap unnoticed
    // and paint would land on a different block.
    try std.testing.expectEqual(@as(i32, 5), t.x);
    try std.testing.expectEqual(@as(i32, 60), t.y);
    try std.testing.expectEqual(@as(i32, -8), t.z);
    try std.testing.expectEqual(@as(u8, 3), t.face);
    try std.testing.expectEqual(@as(u8, 17), t.idx);
    try std.testing.expectEqual(@as(i32, -1), t.player_id);
    try std.testing.expectEqual(@as(u8, 0), t.channel);
    // Round-trip: build is the same 19-byte layout.
    var out: [32]u8 = undefined;
    const built = try buildSetBlockTextureBody(&out, t);
    try std.testing.expectEqual(@as(usize, 19), built.len);
    const t2 = try parseSetBlockTexture(built);
    try std.testing.expectEqual(@as(i32, -8), t2.z);
    try std.testing.expectEqual(@as(u8, 17), t2.idx);
    // Raw bytes, not only the round-trip: build and parse can move a field
    // together and still agree with each other, which is what the swap audit
    // reported here after the parse-side assertions were added.
    try std.testing.expectEqual(@as(i32, 5), std.mem.readInt(i32, built[0..4], .little));
    try std.testing.expectEqual(@as(i32, 60), std.mem.readInt(i32, built[4..8], .little));
    try std.testing.expectEqual(@as(i32, -8), std.mem.readInt(i32, built[8..12], .little));
    try std.testing.expectEqual(@as(u8, 3), built[12]); // face
    try std.testing.expectEqual(@as(u8, 17), built[13]); // idx
    try std.testing.expectEqual(@as(i32, -1), std.mem.readInt(i32, built[14..18], .little));
    try std.testing.expectEqual(@as(u8, 0), built[18]); // channel
    // Truncated at every boundary is EndOfStream.
    var cut: usize = 0;
    while (cut < 19) : (cut += 1) {
        try std.testing.expectError(error.EndOfStream, parseSetBlockTexture(built[0..cut]));
    }
}

test "parseItemReload reads the single entityId" {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(i32, buf[0..4], 12345, .little);
    try std.testing.expectEqual(@as(i32, 12345), try parseItemReload(buf[0..4]));
    // Negative ids are legal wire values (the sender's own entity id is
    // always positive; a negative one fails the entity-exists gate).
    std.mem.writeInt(i32, buf[0..4], -1, .little);
    try std.testing.expectEqual(@as(i32, -1), try parseItemReload(buf[0..4]));
    try std.testing.expectError(error.EndOfStream, parseItemReload(buf[0..3]));
    try std.testing.expectError(error.EndOfStream, parseItemReload(&.{}));
}

/// Stock `NetPackageEntityRagdoll` (write IL=59): entityId i32, flags u8,
/// then conditionally (flags&1) duration f32, bodyPart i16, forceVec 3xf32,
/// forceWorldPos 3xf32, hipPos 3xf32, (flags&2) mode u8, (flags&4) state u8.
/// The sender is the entity's owner (EntityBuffs / EModelBase.DoRagdoll
/// force the local ragdoll); the server applies it and re-broadcasts via
/// NetEntityDistribution.SendPacketToTrackedPlayersAndTrackedEntity, so a
/// verbatim relay to the other clients matches the intent (the owner already
/// ragdolled locally).
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

test "id mapping body is name, then length, then bytes" {
    // The join path builds this for the item NameIdMapping and nothing read it
    // back: swapping the name string with the i32 length left the whole suite
    // green while the body no longer matched `NetPackageIdMapping::read`
    // (IL=13: ReadString, ReadInt32, ReadBytes).
    var buf: [64]u8 = undefined;
    const body = try buildIdMappingBody(&buf, "items", &.{ 7, 8, 9 });

    var r: binary.Reader = .{ .data = body };
    var name_buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("items", try r.readString(&name_buf));
    try std.testing.expectEqual(@as(i32, 3), try r.readI32());
    try std.testing.expectEqualSlices(u8, &.{ 7, 8, 9 }, body[r.pos..]);
}

test "name id mapping payload is version, count, then id before name" {
    // The join path built this inline in game/join.zig, where neither the
    // mutant tool nor the coverage counts reach: swapping the id with the name
    // left the whole suite green while the payload stopped matching
    // `NameIdMapping::SaveToWriter` (IL=72: per entry Write(Int32) the id then
    // Write(String) the name).
    var buf: [128]u8 = undefined;
    const payload = try buildNameIdMappingPayload(&buf, &.{
        .{ .id = 65543, .name = "meleeToolStoneAxe" },
        .{ .id = 65545, .name = "gunHandgunT1Pistol" },
    });

    var r: binary.Reader = .{ .data = payload };
    try std.testing.expectEqual(@as(i32, 1), try r.readI32()); // version
    try std.testing.expectEqual(@as(i32, 2), try r.readI32()); // backfilled count
    var name_buf: [32]u8 = undefined;
    try std.testing.expectEqual(@as(i32, 65543), try r.readI32());
    try std.testing.expectEqualStrings("meleeToolStoneAxe", try r.readString(&name_buf));
    try std.testing.expectEqual(@as(i32, 65545), try r.readI32());
    try std.testing.expectEqualStrings("gunHandgunT1Pistol", try r.readString(&name_buf));
    try std.testing.expectEqual(@as(usize, 0), r.remaining());

    // An empty map still carries a well-formed header.
    const none = try buildNameIdMappingPayload(&buf, &.{});
    try std.testing.expectEqual(@as(usize, 8), none.len);
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, none[4..8], .little));
}

test "explosion blob decodes radii at their stock scales" {
    // ExplosionData (RE protocol-packages.md, Read IL=82): Duration is stored
    // x10 and BlockRadius x20, EntityRadius and BlastPower are raw. The stock
    // cop/feral explosion is radius_blocks 5, radius_entities 6, so a blob
    // carrying 100 and 6 must decode to 5.0 and 6.0 blocks.
    var body: [128]u8 = undefined;
    var w: binary.Writer = .{ .buf = &body };
    try w.writeF32(10); // worldPos
    try w.writeF32(70);
    try w.writeF32(10);
    try w.writeI32(10); // blockPos
    try w.writeI32(70);
    try w.writeI32(10);
    try w.writeF32(0); // rotation quaternion
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(1);

    var blob: [64]u8 = undefined;
    var bw: binary.Writer = .{ .buf = &blob };
    try bw.writeI16(3); // particleIndex
    try bw.writeI16(25); // duration, x10 -> 2.5 s
    try bw.writeI16(100); // blockRadius, x20 -> 5 blocks
    try bw.writeI16(6); // entityRadius, raw -> 6 blocks
    try bw.writeI16(1); // blastPower
    try bw.writeF32(120); // blockDamage
    try bw.writeF32(45); // entityDamage
    const blob_bytes = bw.written();

    try w.writeU16(@intCast(blob_bytes.len));
    try w.writeBytes(blob_bytes);
    try w.writeI32(42); // entityId
    try w.writeF32(0); // delay

    const ex = try parseExplosionInitiate(w.written());
    try std.testing.expectEqual(@as(i32, 42), ex.entity_id);
    try std.testing.expectApproxEqAbs(@as(f32, 5), ex.radius, 0.001);
    // The bug this pins: entity_radius was divided by 20 as well, so the stock
    // value 6 arrived as 0.3 and the caller's 1 m floor swallowed it.
    try std.testing.expectApproxEqAbs(@as(f32, 6), ex.entity_radius, 0.001);
    try std.testing.expectEqual(@as(u16, 120), ex.block_damage);
    try std.testing.expectApproxEqAbs(@as(f32, 45), ex.entity_damage, 0.001);
}

test "GameStats carries the config-driven creative, marker and camera values" {
    // GameStats[18]/[20] come from GamePrefs 58 BuildCreate, [53] from the
    // sandbox AirDropMarker, [34] from DropOnQuit, [66] from BiomeProgression
    // and [68] from serverconfig CameraRestrictionMode. They used to be
    // constants in the writer, so an operator could not turn creative mode,
    // flight, the air-drop marker or the camera restriction on.
    var on_buf: [512]u8 = undefined;
    const on = try buildGameStatsBodyValues(&on_buf, .{
        .build_create = true,
        .air_drop_marker = false,
        .drop_on_quit = 2,
        .biome_progression = false,
        .camera_restriction_mode = 1,
    });
    var off_buf: [512]u8 = undefined;
    const off = try buildGameStatsBodyValues(&off_buf, .{});
    // Same field set, so only the values differ: the writer's field order is
    // the propertyList contract.
    try std.testing.expectEqual(off.len, on.len);
    try std.testing.expect(!std.mem.eql(u8, on, off));
    // ScorePlayerKillMultiplier is 0 in both (GameModeSurvival::Init IL_0035).
    const defaults = GameStatsValues{};
    try std.testing.expectEqual(@as(i32, 0), defaults.score_player_kill_multiplier);
    try std.testing.expectEqual(@as(i32, 0), defaults.drop_on_quit);
    try std.testing.expect(!defaults.build_create);
    try std.testing.expect(defaults.air_drop_marker);
    try std.testing.expect(defaults.biome_progression);
}

test "localization body carries seq, total and the deflate blob" {
    // NetPackageLocalization::write IL=0030: seqNr i32, totalParts i32,
    // data length (i32, -1 for null) then the bytes.
    var buf: [64]u8 = undefined;
    const body = try buildLocalizationBody(&buf, 0, 1, &[_]u8{ 0x03, 0x00 });
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0, 0, 0, 0, // seqNr
        1, 0, 0, 0, // totalParts
        2,    0,    0, 0, // data length
        0x03, 0x00,
    }, body);
    const nul = try buildLocalizationBody(&buf, 2, 3, null);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        2, 0, 0, 0, 3, 0, 0, 0, 0xff, 0xff, 0xff, 0xff,
    }, nul);
}
