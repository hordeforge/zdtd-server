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
pub const quest_point_get_goto: u8 = stock_quest.quest_point_get_goto;
pub const quest_point_get_treasure: u8 = stock_quest.quest_point_get_treasure;
pub const quest_point_update_treasure: u8 = stock_quest.quest_point_update_treasure;

pub const quest_point_update_blocks: u8 = stock_quest.quest_point_update_blocks;
pub const QuestTreasurePoint = stock_quest.QuestTreasurePoint;
pub const parseQuestTreasurePoint = stock_quest.parseQuestTreasurePoint;
pub const buildQuestTreasurePointReply = stock_quest.buildQuestTreasurePointReply;

const readBlockChangeInfo = stock_block.readBlockChangeInfo;

pub const stock_frame = @import("stock_frame.zig");
pub const channelFor = stock_frame.channelFor;
pub const framed = stock_frame.framed;

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

pub const stock_anim = @import("stock_anim.zig");
pub const anim_param_bool: u8 = stock_anim.anim_param_bool;
pub const anim_param_trigger: u8 = stock_anim.anim_param_trigger;
pub const anim_param_float: u8 = stock_anim.anim_param_float;
pub const anim_param_int: u8 = stock_anim.anim_param_int;
pub const anim_param_data_float: u8 = stock_anim.anim_param_data_float;
pub const AnimationData = stock_anim.AnimationData;
pub const parseAnimationData = stock_anim.parseAnimationData;
pub const RagdollInvoke = stock_anim.RagdollInvoke;
pub const LaserSight = stock_anim.LaserSight;
pub const parseLaserSight = stock_anim.parseLaserSight;
pub const parseRagdollInvoke = stock_anim.parseRagdollInvoke;
