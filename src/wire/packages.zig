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

pub const stock_gamestats = @import("stock_gamestats.zig");
pub const GameStatsValues = stock_gamestats.GameStatsValues;
pub const buildGameStatsBodyValues = stock_gamestats.buildGameStatsBodyValues;

pub const stock_weather = @import("stock_weather.zig");
pub const WeatherBiome = stock_weather.WeatherBiome;
pub const buildWeatherBody = stock_weather.buildWeatherBody;

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

pub const ExplosionInitiate = stock_explosion.ExplosionInitiate;
pub const parseExplosionInitiate = stock_explosion.parseExplosionInitiate;

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

pub const NpcQuestEventType = stock_quest.NpcQuestEventType;
pub const NpcQuestListHead = stock_quest.NpcQuestListHead;
pub const parseNpcQuestList = stock_quest.parseNpcQuestList;
pub const buildNpcQuestListFetch = stock_quest.buildNpcQuestListFetch;
pub const QuestObjectiveEventType = stock_quest.QuestObjectiveEventType;
pub const QuestObjectiveUpdate = stock_quest.QuestObjectiveUpdate;
pub const parseQuestObjectiveUpdate = stock_quest.parseQuestObjectiveUpdate;
pub const buildQuestObjectiveUpdate = stock_quest.buildQuestObjectiveUpdate;

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

pub const stock_tx_setall_cap: usize = stock_invtx.stock_tx_setall_cap;
pub const StockInvOp = stock_invtx.StockInvOp;
pub const stock_tx_op_cap: usize = stock_invtx.stock_tx_op_cap;
pub const stock_tx_entry_cap: usize = stock_invtx.stock_tx_entry_cap;
pub const StockInvEntry = stock_invtx.StockInvEntry;
pub const StockInvTx = stock_invtx.StockInvTx;
pub const parseStockInvTx = stock_invtx.parseStockInvTx;

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
