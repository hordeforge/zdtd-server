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

pub const PackageName = enum {
    NetPackagePackageIds,
    NetPackagePlayerLogin,
    NetPackagePlayerLoginAnswer,
    NetPackagePlayerId,
    NetPackagePlayerSpawnedInWorld,
    NetPackageRequestToSpawnPlayer,
    NetPackageEntityPosAndRot,
    NetPackageEntityRelPosAndRot,
    NetPackageEntityAliveFlags,
    NetPackageDamageEntity,
    NetPackageEntityRemove,
    NetPackageSetBlock,
    NetPackageChunk,
    NetPackageWorldTime,
    NetPackageSimpleChat,
    NetPackageEntityLookAt,
    // Extended systems (appended so join ids 0..15 stay stable for fixtures).
    NetPackageQuestObjectiveUpdate,
    NetPackageNPCQuestList,
    NetPackageTraderData,
    NetPackageEntitySpawn,
    NetPackageVehicleSpawn,
    NetPackageVehiclePositions,
    NetPackageVehicleDataSync,
    NetPackageTurretSpawn,
    NetPackageTurretSync,
    NetPackageWireActions,
    NetPackageWireToolActions,
    NetPackageWorldInfo,
    NetPackagePlayerInventory,
    NetPackageHoldingItem,
    NetPackageEntityStatChanged,
    NetPackageEntitySpawnResponse,
    NetPackageChunkRemove,
    NetPackageGameStats,
    NetPackageIdMapping,
    NetPackageEntityCollect,
    NetPackageInventoryTransactionRequest,
    NetPackageInventoryTransactionResponse,
    NetPackageInventoryDataRequest,
    NetPackageInventoryDataResponse,
    NetPackageItemDrop,
    NetPackageBag,
    NetPackageDropItemsContainer,
    NetPackageTileEntity,
};

/// Stable server map: index = pkgId (same idea as MockGameServer.DefaultMappings).
pub const default_mappings = [_][]const u8{
    "NetPackagePackageIds",
    "NetPackagePlayerLogin",
    "NetPackagePlayerLoginAnswer",
    "NetPackagePlayerId",
    "NetPackagePlayerSpawnedInWorld",
    "NetPackageRequestToSpawnPlayer",
    "NetPackageEntityPosAndRot",
    "NetPackageEntityRelPosAndRot",
    "NetPackageEntityAliveFlags",
    "NetPackageDamageEntity",
    "NetPackageEntityRemove",
    "NetPackageSetBlock",
    "NetPackageChunk",
    "NetPackageWorldTime",
    "NetPackageSimpleChat",
    "NetPackageEntityLookAt",
    "NetPackageQuestObjectiveUpdate",
    "NetPackageNPCQuestList",
    "NetPackageTraderData",
    "NetPackageEntitySpawn",
    "NetPackageVehicleSpawn",
    "NetPackageVehiclePositions",
    "NetPackageVehicleDataSync",
    "NetPackageTurretSpawn",
    "NetPackageTurretSync",
    "NetPackageWireActions",
    "NetPackageWireToolActions",
    "NetPackageWorldInfo",
    "NetPackagePlayerInventory",
    "NetPackageHoldingItem",
    "NetPackageEntityStatChanged",
    "NetPackageEntitySpawnResponse",
    "NetPackageChunkRemove",
    "NetPackageGameStats",
    "NetPackageIdMapping",
    "NetPackageEntityCollect",
    "NetPackageInventoryTransactionRequest",
    "NetPackageInventoryTransactionResponse",
    "NetPackageInventoryDataRequest",
    "NetPackageInventoryDataResponse",
    "NetPackageItemDrop",
    "NetPackageBag",
    "NetPackageDropItemsContainer",
    "NetPackageTileEntity",
    "NetPackagePlayerDisconnect",
    "NetPackagePlayerData",
    "NetPackageAuthConfirmation",
    "NetPackageAuthState",
    "NetPackageRequestToEnterGame",
    "NetPackageEncryptionRequest",
    "NetPackagePlayerStats",
    "NetPackageSetBlockResponse",
    "NetPackageCloseAllWindows",
    "NetPackageConfigFile",
    "NetPackageWorldInitInfo",
    "NetPackageWorldInitInfoRequest",
    "NetPackageClientInfo",
    "NetPackageAddRemoveBuff",
    "NetPackageAllyRequest",
    "NetPackageAllyResponse",
    "NetPackageAnimateBlock",
    "NetPackageAudio",
    "NetPackageAudioPlayInHead",
    "NetPackageBiomeIntensity",
    "NetPackageBlockLimitTracking",
    "NetPackageBlockTrigger",
    "NetPackageBloodmoonMusic",
    "NetPackageBossEvent",
    "NetPackageChat",
    "NetPackageChunkClusterInfo",
    "NetPackageChunkRemoveAll",
    "NetPackageConfirmSpawnEntity",
    "NetPackageConsoleCmdClient",
    "NetPackageConsoleCmdServer",
    "NetPackageDebug",
    "NetPackageDecoResetWorldChunk",
    "NetPackageDecoResetWorldRect",
    "NetPackageDecoUpdate",
    "NetPackageDeleteChunkData",
    "NetPackageDiscordIdMappings",
    "NetPackageDiscordLobbySecret",
    "NetPackageDynamicClientArrive",
    "NetPackageDynamicMesh",
    "NetPackageEAC",
    "NetPackageEditorAddVolumeFromClient",
    "NetPackageEditorPrefabInstance",
    "NetPackageEditorUpdateVolume",
    "NetPackageEmitSmell",
    "NetPackageEncryptionPublicKey",
    "NetPackageEncryptionSharedKey",
    "NetPackageEntityAddExpClient",
    "NetPackageEntityAddExpServer",
    "NetPackageEntityAddScoreClient",
    "NetPackageEntityAddScoreServer",
    "NetPackageEntityAddVelocity",
    "NetPackageEntityAnimationData",
    "NetPackageEntityAttach",
    "NetPackageEntityAwardKillServer",
    "NetPackageEntityMapMarkerRemove",
    "NetPackageEntityPhysics",
    "NetPackageEntityPrimeDetonator",
    "NetPackageEntityRagdoll",
    "NetPackageEntityRotation",
    "NetPackageEntitySetPartActive",
    "NetPackageEntitySetSkillLevelClient",
    "NetPackageEntitySetSkillLevelServer",
    "NetPackageEntitySpeeds",
    "NetPackageEntityStatsBuff",
    "NetPackageEntityStealth",
    "NetPackageEntityTeleport",
    "NetPackageEntityVelocity",
    "NetPackageEntityWaypointList",
    "NetPackageEventPrefab",
    "NetPackageExplosionClient",
    "NetPackageExplosionInitiate",
    "NetPackageGameEventRequest",
    "NetPackageGameEventResponse",
    "NetPackageGameMessage",
    "NetPackageHordeEvent",
    "NetPackageInventoryKeepOpen",
    "NetPackageItemActionEffects",
    "NetPackageItemReload",
    "NetPackageKeyExchangeComplete",
    "NetPackageLandClaimRepair",
    "NetPackageLobbyJoin",
    "NetPackageLobbyRegisterClient",
    "NetPackageLocalization",
    "NetPackageLockRequest",
    "NetPackageLockResponse",
    "NetPackageMapChunks",
    "NetPackageMapPosition",
    "NetPackageMinEventFire",
    "NetPackageModifyCVar",
    "NetPackageNavObject",
    "NetPackageNetMetrics",
    "NetPackageOwnedEntitySync",
    "NetPackagePOIMetadataRequest",
    "NetPackagePOIMetadataResponse",
    "NetPackagePOIWaypoint",
    "NetPackageParticleEffect",
    "NetPackagePartyActions",
    "NetPackagePartyData",
    "NetPackagePartyQuestChange",
    "NetPackagePersistentPlayerPositions",
    "NetPackagePersistentPlayerState",
    "NetPackagePickupBlock",
    "NetPackagePlayerDenied",
    "NetPackagePlayerEquipment",
    "NetPackagePlayerInventoryForAI",
    "NetPackagePlayerLaserSight",
    "NetPackagePlayerQuestPositions",
    "NetPackagePlayerSetBackpackPosition",
    "NetPackagePlayerTwitchStats",
    "NetPackagePlayerVendingMachine",
    "NetPackageQuestEntitySpawn",
    "NetPackageQuestEvent",
    "NetPackageQuestGotoPoint",
    "NetPackageQuestTreasurePoint",
    "NetPackageRangeCheckDamageEntity",
    "NetPackageRegionMetaData",
    "NetPackageRequestToSpawnEntity",
    "NetPackageSetAttackTarget",
    "NetPackageSetBlockTexture",
    "NetPackageSetProp",
    "NetPackageSharedPartyKill",
    "NetPackageSharedQuest",
    "NetPackageShowToolbeltMessage",
    "NetPackageSignDataRequest",
    "NetPackageSignDataResponse",
    "NetPackageSimpleRPC",
    "NetPackageSleeperPassiveChange",
    "NetPackageSleeperPose",
    "NetPackageSleeperWakeup",
    "NetPackageSoundAtPosition",
    "NetPackageTeleportPlayer",
    "NetPackageTwitchAccess",
    "NetPackageTwitchVoteScheduling",
    "NetPackageVehicleCount",
    "NetPackageWallVolume",
    "NetPackageWallVolumeRemove",
    "NetPackageWaterSet",
    "NetPackageWaterSimChunkUpdate",
    "NetPackageWaypoint",
    "NetPackageWeather",
    "NetPackageWorldAreas",
    "NetPackageWorldFolder",
    "NetPackageWorldSpawnPoints",
    "NetPackageDroneDataSync",
    "NetPackageDroneParticleEffect",
    "NetPackageLight",
    "NetPackageTreeFade",
};

const id_map = blk: {
    // A repeated name is a silent wire fault, not a typo: the index in
    // default_mappings *is* the negotiated package id, StaticStringMap keeps
    // only one of the two entries, and every id after the duplicate shifts by
    // one. The server would then advertise ids it never dispatches on. Reject
    // it where it costs nothing to notice. The pairwise scan is n^2 over 191
    // names, so it needs a branch budget; it runs once at compile time.
    @setEvalBranchQuota(default_mappings.len * default_mappings.len * 4);
    for (default_mappings, 0..) |a, i| {
        for (default_mappings[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a, b)) {
                @compileError("duplicate package name in default_mappings: " ++ a);
            }
        }
    }
    var kvs: [default_mappings.len]struct { []const u8, u16 } = undefined;
    for (default_mappings, 0..) |m, i| kvs[i] = .{ m, @intCast(i) };
    break :blk std.StaticStringMap(u16).initComptime(kvs);
};

pub fn idOf(name: []const u8) ?u16 {
    return id_map.get(name);
}

pub const VersionInfo = struct {
    release_type: u8 = 1,
    major: i32 = 3,
    /// Raw Minor for the 3.2.0 wire (changelog-3.2.0 §1: minor 10->20,
    /// §8: build 9->10; version.zig `stock_wire_gsi_version` = "V.3.20.10").
    /// The client derives the display form ("V 3.2.0") from these numbers and
    /// echoes it back in the login package, so the PackageIds numeric
    /// version must match the login gate (`stock_wire_comp`) exactly.
    minor: i32 = 20,
    build: i32 = 10,

    pub fn write(self: VersionInfo, w: *binary.Writer) !void {
        try w.writeByte(self.release_type);
        try w.writeI32(self.major);
        try w.writeI32(self.minor);
        try w.writeI32(self.build);
    }
};

/// NetPackagePackageIds (RE inventories/netpackage-bodies.md write IL=62,
/// protocol.md §4): `VersionInformation.Write` | mapping count i32 | count x
/// name string | `serverUseEAC` bool | `hasHostUserAndToken` bool, then the
/// host identity pair only when that bool is true. zdtd runs EAC-off with no
/// host token, so both bools are false and the pair is correctly absent.
/// Index = package id; the client must use these server-advertised ids.
pub fn buildPackageIdsBody(buf: []u8, ver: VersionInfo, mappings: []const []const u8) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try ver.write(&w);
    try w.writeI32(@intCast(mappings.len));
    for (mappings) |m| try w.writeString(m);
    try w.writeBool(false); // useEac
    try w.writeBool(false); // hasHost
    return w.written();
}

/// NetPackagePlayerLoginAnswer (RE inventories/netpackage-bodies.md, write
/// IL=46): `bAllowed` bool | `data` string | `platformLobbyId`
/// (PlatformLobbyId.Write) | host identity (ToStream + string) | server
/// identity (ToStream + string). zdtd writes the lobby and both identity pairs
/// as null: a headless EAC-off dedi has no platform lobby and no host token, so
/// a fabricated identity is exactly what rule 3 forbids. A null
/// PlatformUserIdentifier is one 0 byte, which is the stock null path.
pub fn buildLoginAnswerBody(buf: []u8, allowed: bool, data: []const u8) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeBool(allowed);
    try w.writeString(data);
    try w.writeByte(0); // lobby
    try w.writeByte(0); // platform null
    try w.writeString("");
    try w.writeByte(0);
    try w.writeString("");
    return w.written();
}

/// Stock `NetPackageLocalization` body (write IL=30): seqNr i32 | totalParts
/// i32 | dataLen i32 (-1 when null) | data bytes. `Compress()` is false for
/// this package (`get_Compress` IL=2), so the frame stays uncompressed even
/// though the payload itself is stock's raw-Deflate patch blob.
pub fn buildLocalizationBody(buf: []u8, seq: i32, total: i32, data: ?[]const u8) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(seq);
    try w.writeI32(total);
    if (data) |d| {
        try w.writeI32(@intCast(d.len));
        try w.writeBytes(d);
    } else {
        try w.writeI32(-1);
    }
    return w.written();
}

/// Stock NetPackageConfigFile body (RE IL=25, protocol-packages.md §...):
/// `name` (7-bit string), then dataLen i32 = -1 when data is null (client
/// loads its own file; LoadClientFile rows such as archetypes), else the
/// Deflate-compressed patched config bytes. Package-level `Compress`=true
/// (G7) is handled by the framer at the send site.
pub fn buildConfigFileBody(buf: []u8, name: []const u8, data: ?[]const u8) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeString(name);
    if (data) |d| {
        try w.writeI32(@intCast(d.len));
        try w.writeBytes(d);
    } else {
        try w.writeI32(-1);
    }
    return w.written();
}

test "buildConfigFileBody pins name + len + bytes and null form" {
    var buf: [512]u8 = undefined;
    const with_data = try buildConfigFileBody(&buf, "blocks", &[_]u8{ 1, 2, 3, 4 });
    // 7-bit name len 6 | "blocks" | i32 len 4 | 4 bytes
    try std.testing.expectEqualSlices(u8, &.{
        6, 'b', 'l', 'o', 'c', 'k', 's',
        4, 0,   0,   0,   1,   2,   3,
        4,
    }, with_data);
    const null_form = try buildConfigFileBody(&buf, "archetypes", null);
    try std.testing.expectEqualSlices(u8, &.{
        10,   'a',  'r',  'c',  'h', 'e', 't', 'y', 'p', 'e', 's',
        0xff, 0xff, 0xff, 0xff,
    }, null_form);
}

/// Stock NetPackagePlayerId body (derived V3.0.1, live against V3.1.0 b14):
/// id:i32 | team:i16 | PlayerDataFile.WriteNetwork | chunkViewDim:i32
/// Empty PDF matches a fresh PlayerDataFile() so stock ReadNetwork completes without EOF.
/// `sx,sy,sz` are world spawn coords written into ECD pos + lastSpawnPosition so the
/// local player is not created at (0,0,0) (which floods SkyManager/SignTexture NREs).
pub const PlayerIdOpts = struct {
    quests: []const stock_quest.StockQuestWrite = &.{},
    unlocked_recipes: []const []const u8 = &.{},
    toolbelt: []const stock_inv.StockSlot = &.{},
    bag: []const stock_inv.StockSlot = &.{},
    b_loaded: bool = true,
    game_stage_born_at: u64 = game_stage_born_unset,
    /// Character-sheet counters (`PlayerDataFile.playerKills/zombieKills/
    /// deaths/score`). Stock carries these in the save, so a join that writes
    /// 0 resets a returning player's sheet even though its own PlayerDataFile
    /// held the totals; the restored values ride here.
    player_kills: i32 = 0,
    zombie_kills: i32 = 0,
    deaths: i32 = 0,
    score: i32 = 0,
    /// The client's own character profile, as sent in
    /// `NetPackageRequestToSpawnPlayer` (stock stores it on the ECD:
    /// `GameManager::RequestToSpawnPlayer` `GameManager.il.txt:4614-4617`).
    /// Null keeps the offline default appearance.
    profile: ?stock_entity.PlayerProfile = null,
    /// The player's display name for the ECD (`ClientInfo.playerName` in
    /// stock). Bounded by the caller's own name buffer.
    player_name: []const u8 = "Player",
};

/// NetPackagePlayerId with default options (see buildPlayerIdBodyWithOpts for
/// the RE field order, write IL=21).
pub fn buildPlayerIdBody(buf: []u8, entity_id: i32, team: i16, chunk_view_dim: i32, sx: i32, sy: i32, sz: i32) ![]u8 {
    return buildPlayerIdBodyWithOpts(buf, entity_id, team, chunk_view_dim, sx, sy, sz, .{});
}

/// NetPackagePlayerId carrying the join inventory (see buildPlayerIdBodyWithOpts
/// for the RE field order, write IL=21).
pub fn buildPlayerIdBodyInv(
    buf: []u8,
    entity_id: i32,
    team: i16,
    chunk_view_dim: i32,
    sx: i32,
    sy: i32,
    sz: i32,
    quests: []const stock_quest.StockQuestWrite,
    unlocked_recipes: []const []const u8,
    toolbelt: []const stock_inv.StockSlot,
    bag: []const stock_inv.StockSlot,
) ![]u8 {
    return buildPlayerIdBodyWithOpts(buf, entity_id, team, chunk_view_dim, sx, sy, sz, .{
        .quests = quests,
        .unlocked_recipes = unlocked_recipes,
        .toolbelt = toolbelt,
        .bag = bag,
    });
}

/// EntityPlayer::Init seeds gameStageBornAtWorldTime to -1 (asm.il ~503740);
/// PlayerDataFile::CopyTo then clamps anything above the current world time
/// down to it (asm.il ~1975949), so the sentinel reads as zero days survived.
pub const game_stage_born_unset: u64 = std.math.maxInt(u64);

/// NetPackagePlayerId (RE inventories/netpackage-bodies.md, write IL=21):
/// `id` i32 | `teamNumber` i16 | `playerDataFile` (PlayerDataFile.WriteNetwork)
/// | `chunkViewDim` i32. The PDF body is written by
/// writeEmptyPlayerDataFileNetwork.
pub fn buildPlayerIdBodyWithOpts(
    buf: []u8,
    entity_id: i32,
    team: i16,
    chunk_view_dim: i32,
    sx: i32,
    sy: i32,
    sz: i32,
    opts: PlayerIdOpts,
) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeI16(team);
    try writeEmptyPlayerDataFileNetwork(&w, entity_id, sx, sy, sz, opts);
    try w.writeI32(chunk_view_dim);
    return w.written();
}

/// NetPackagePlayerId (RE write IL=21; field order in buildPlayerIdBodyWithOpts).
/// Like buildPlayerIdBodyInv; b_loaded=false for death-respawn re-bundle (avoids
/// GameManager.PlayerId CreateEntity+ToPlayer on an already-spawned local player).
/// `game_stage_born_at` is the server's survival-streak origin in world ticks,
/// so the client's own `gamestage` console command agrees with the server.
pub fn buildPlayerIdBodyInvLoaded(
    buf: []u8,
    entity_id: i32,
    team: i16,
    chunk_view_dim: i32,
    sx: i32,
    sy: i32,
    sz: i32,
    quests: []const stock_quest.StockQuestWrite,
    unlocked_recipes: []const []const u8,
    toolbelt: []const stock_inv.StockSlot,
    bag: []const stock_inv.StockSlot,
    b_loaded: bool,
    game_stage_born_at: u64,
) ![]u8 {
    return buildPlayerIdBodyWithOpts(buf, entity_id, team, chunk_view_dim, sx, sy, sz, .{
        .quests = quests,
        .unlocked_recipes = unlocked_recipes,
        .toolbelt = toolbelt,
        .bag = bag,
        .b_loaded = b_loaded,
        .game_stage_born_at = game_stage_born_at,
    });
}

/// Minimal empty PlayerDataFile.WriteNetwork (Write + PlayerMetaInfo.Write).
fn writeEmptyPlayerDataFileNetwork(
    w: *binary.Writer,
    entity_id: i32,
    sx: i32,
    sy: i32,
    sz: i32,
    opts: PlayerIdOpts,
) !void {
    const quests = opts.quests;
    const unlocked_recipes = opts.unlocked_recipes;
    const toolbelt = opts.toolbelt;
    const bag = opts.bag;
    const b_loaded = opts.b_loaded;
    const game_stage_born_at = opts.game_stage_born_at;
    const px: f32 = @floatFromInt(sx);
    const py: f32 = @floatFromInt(sy);
    const pz: f32 = @floatFromInt(sz);
    const profile = opts.profile;
    const player_name = opts.player_name;
    // --- EntityCreationData.write(bw, networkWrite=false) ---
    // V3.1.0 ECD FileVersion=36. Use the player class matching the client's own
    // profile so GameManager.PlayerId with bLoaded=true can CreateEntity +
    // ToPlayer (applies bag/toolbelt) and the client adopts its real
    // appearance; the offline default stays playerMale.
    const player_class: i32 = if (profile) |p|
        (if (p.is_male) stock_entity.class_player_male else stock_entity.class_player_female)
    else
        stock_entity.class_player_male;
    try w.writeByte(36); // FileVersion
    try w.writeI32(player_class);
    try w.writeI32(entity_id); // id (match PlayerId entity)
    try w.writeF32(std.math.floatMax(f32)); // lifetime
    try w.writeF32(px);
    try w.writeF32(py);
    try w.writeF32(pz); // pos
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(0); // rot
    try w.writeBool(true); // onGround
    // BodyDamage.Write: cBinaryVersion=4, damageType=0, Flags=0
    try w.writeI32(4);
    try w.writeI32(0);
    try w.writeU32(0);
    try w.writeBool(false); // no EntityStats
    try w.writeI16(0); // deathTime
    try w.writeBool(false); // no bag
    try w.writeI32(sx);
    try w.writeI32(sy);
    try w.writeI32(sz); // homePosition
    try w.writeI16(-1); // homeRange
    try w.writeByte(0); // spawnerSource
    // player branch: holdingItem, team, name, skin, profile
    try stock_inv.writeEmptyItemValue(w);
    try w.writeByte(0); // teamNumber
    try w.writeString(player_name);
    try w.writeString(""); // skinTexture
    try w.writeBool(true); // has PlayerProfile
    try stock_entity.writePlayerProfile(w, profile orelse .{
        .archetype = "BaseMale",
        .is_male = true,
        .race_name = "White",
        .variant_number = 1,
        .eye_color = "Blue01",
    });
    try w.writeU16(0); // entityData length
    try w.writeBool(false); // no traderData
    // networkWrite=false: skip sleeper/spawnBy/head/override fields
    try w.writeF32(0); // stressAmount (ECD v36 tail)

    // --- PlayerDataFile.Write remainder ---
    // inventory (toolbelt) ItemStack list: pad to stock PUBLIC_SLOTS (10)
    var tb_pad: [stock_inv.toolbelt_slots]stock_inv.StockSlot = [_]stock_inv.StockSlot{.{}} ** stock_inv.toolbelt_slots;
    {
        const n = @min(toolbelt.len, tb_pad.len);
        @memcpy(tb_pad[0..n], toolbelt[0..n]);
    }
    try stock_inv.writeItemStackList(w, tb_pad[0..]);
    try w.writeByte(0); // selectedInventorySlot
    // Bag: pad to stock CarryCapacity base (45). Mismatched counts resize the
    // client bag via Bag.ReadInto and leave every slot occupied (AddItem fails).
    var bag_pad: [stock_inv.bag_slots]stock_inv.StockSlot = [_]stock_inv.StockSlot{.{}} ** stock_inv.bag_slots;
    {
        const n = @min(bag.len, bag_pad.len);
        @memcpy(bag_pad[0..n], bag[0..n]);
    }
    try stock_inv.writeBag(w, bag_pad[0..], true);
    // dragAndDropItem as 1-element empty stack list
    try w.writeU16(1);
    try w.writeU16(0); // ItemStack.count == 0 (no ItemValue)
    try w.writeU16(0); // alreadyCraftedList
    try w.writeByte(0); // spawnPoints count (stock always writes 0 here)
    try w.writeI64(0); // selectedSpawnPointKey
    try w.writeBool(true); // stock hardcodes true
    try w.writeI16(0); // stock hardcodes 0
    // bLoaded=true → first join: ToPlayer applies toolbelt/bag. false on death
    // re-bundle so PlayerId does not re-CreateEntity the local player (NRE).
    try w.writeBool(b_loaded);
    // lastSpawnPosition: world spawn + heading
    try w.writeI32(sx);
    try w.writeI32(sy);
    try w.writeI32(sz);
    try w.writeF32(0);
    try w.writeI32(-1); // pdf id
    try w.writeI32(opts.player_kills);
    try w.writeI32(opts.zombie_kills);
    try w.writeI32(opts.deaths);
    try w.writeI32(opts.score);
    // Equipment.Write: version 4, 12 empty ItemValues, 12 cosmetic i32 zeros, unlocked 0
    try w.writeByte(4);
    var i: usize = 0;
    while (i < 12) : (i += 1) try w.writeByte(0); // null/empty ItemValue
    i = 0;
    while (i < 12) : (i += 1) try w.writeI32(0); // cosmetic slot ids
    try w.writeI32(0); // unlocked cosmetics count
    // unlockedRecipeList: u16 count + 7DTD strings (always_unlocked craft names)
    const unlock_n: u16 = @intCast(@min(unlocked_recipes.len, 512));
    try w.writeU16(unlock_n);
    var ui: usize = 0;
    while (ui < unlock_n) : (ui += 1) {
        try w.writeString(unlocked_recipes[ui]);
    }
    try w.writeU16(1); // stock hardcodes 1 before marker
    try w.writeI32(0);
    try w.writeI32(0);
    try w.writeI32(0); // markerPosition Vector3i
    try w.writeBool(false); // markerHidden
    try w.writeBool(false); // bCrouchedLocked
    // CraftingData.Write: version u16=2, recipe queue len byte=0
    try w.writeU16(2);
    try w.writeByte(0);
    try w.writeU16(0); // favoriteRecipeList
    try w.writeU32(0); // totalItemsCrafted
    try w.writeF32(0); // distanceWalked
    try w.writeF32(0); // longestLife
    try w.writeU64(game_stage_born_at); // gameStageBornAtWorldTime
    // WaypointCollection.Write: version 7, count 0
    try w.writeByte(7);
    try w.writeU16(0);
    // QuestJournal.Write: v5 (empty or stock quests with known client IDs)
    try stock_quest.writeQuestJournal(w, quests);
    try w.writeI32(0); // deathUpdateTime
    try w.writeF32(0); // currentLife
    try w.writeBool(false); // bDead
    try w.writeByte(88); // stock format marker
    try w.writeBool(false); // bModdedSaveGame
    // ChallengeJournal: v1 early-return path. Empty v2 Read() touches
    // GameManager.World while deserializing PlayerId (World still null) and NREs.
    try w.writeByte(1);
    // rentedVMPosition Vector3i
    try w.writeI32(0);
    try w.writeI32(0);
    try w.writeI32(0);
    try w.writeI32(0); // rentalEndDay
    // progressionData / buffData / stealthData: length 0 (empty streams).
    // buffData would carry an EntityBuffs blob (asm.il 1977295); nothing to put
    // there until buffs survive a session, and live buff sync rides
    // AddRemoveBuff / EntityStatsBuff instead.
    try w.writeI32(0);
    try w.writeI32(0);
    try w.writeI32(0);
    try w.writeU16(0); // favoriteCreativeStacks
    try w.writeU16(0); // favoriteShapes
    try w.writeU16(0); // ownedEntities
    try w.writeF32(0); // totalTimePlayed
    // PlayerMetaInfo.Write: no native, no name, level 0, distance 0
    try w.writeBool(false);
    try w.writeBool(false);
    try w.writeI32(0);
    try w.writeF32(0);
}

test "player id body layout: header fields and non-empty pdf" {
    // PDF bag pads to CarryCapacity (45); keep headroom for quests/unlocks.
    var buf: [4096]u8 = undefined;
    const body = try buildPlayerIdBody(&buf, 171, 0, 4, -273, 61, 449);
    // Must be larger than the old 4-byte stub (id only).
    try std.testing.expect(body.len > 64);
    try std.testing.expectEqual(@as(i32, 171), std.mem.readInt(i32, body[0..4], .little));
    try std.testing.expectEqual(@as(i16, 0), std.mem.readInt(i16, body[4..6], .little));
    // ECD FileVersion byte immediately after team
    try std.testing.expectEqual(@as(u8, 36), body[6]);
    // chunkViewDim is the trailing i32
    const dim = std.mem.readInt(i32, body[body.len - 4 ..][0..4], .little);
    try std.testing.expectEqual(@as(i32, 4), dim);
    var r: binary.Reader = .{ .data = body };
    try std.testing.expectEqual(@as(i32, 171), try r.readI32());
    try std.testing.expectEqual(@as(i16, 0), try r.readI16());
    try std.testing.expectEqual(@as(u8, 36), try r.readByte()); // ECD FileVersion
    try std.testing.expectEqual(stock_entity.class_player_male, try r.readI32()); // entityClass
    try std.testing.expectEqual(@as(i32, 171), try r.readI32()); // ecd id
    _ = try r.readF32(); // lifetime
    try std.testing.expectEqual(@as(f32, -273), try r.readF32());
    try std.testing.expectEqual(@as(f32, 61), try r.readF32());
    try std.testing.expectEqual(@as(f32, 449), try r.readF32());

    // Anchor on the coordinate triple itself: -273 | 61 | 449 as i32 is a
    // distinct bit pattern from the same numbers written as f32 in the ECD
    // head above. Finding it proves the three words are adjacent and in order,
    // which is what a swap would break; the fields after it follow at a fixed
    // offset. This must run before body2 reuses `buf` underneath `body`.
    var want: [12]u8 = undefined;
    std.mem.writeInt(i32, want[0..4], -273, .little);
    std.mem.writeInt(i32, want[4..8], 61, .little);
    std.mem.writeInt(i32, want[8..12], 449, .little);
    // The triple appears twice: homePosition in the ECD, then
    // lastSpawnPosition in the PDF. Both are worth pinning, so take each.
    const home_at = std.mem.find(u8, body, &want) orelse return error.HomePosNotFound;
    const lsp = home_at + 12 +
        (std.mem.find(u8, body[home_at + 12 ..], &want) orelse return error.LastSpawnPosNotFound);
    try std.testing.expectEqual(@as(f32, 0), @as(f32, @bitCast(std.mem.readInt(u32, body[lsp + 12 ..][0..4], .little))));
    try std.testing.expectEqual(@as(i32, -1), std.mem.readInt(i32, body[lsp + 16 ..][0..4], .little)); // pdf id

    const body2 = try buildPlayerIdBody(&buf, 999, 3, 8, 0, 70, 0);
    try std.testing.expectEqual(@as(i32, 999), std.mem.readInt(i32, body2[0..4], .little));
    try std.testing.expectEqual(@as(i16, 3), std.mem.readInt(i16, body2[4..6], .little));
    try std.testing.expectEqual(@as(i32, 8), std.mem.readInt(i32, body2[body2.len - 4 ..][0..4], .little));
    try std.testing.expectEqual(body.len, body2.len);

    // lastSpawnPosition sits deep in the PDF, past a bag whose length depends
    // on CarryCapacity, so anchor on the bytes rather than count offsets:
    // `selectedSpawnPointKey` is the only i64 zero in the body and is followed
    // by a fixed run (bool true, i16 0, bool bLoaded) before the position.
    // Nothing read this triple back, and a swap would tell a joining client
    // its last spawn was somewhere it never stood.
}

test "player id PDF pins the drag-drop list, the score counters and the save marker" {
    // Wire-order audit 2026-09-11: three adjacent same-width pairs in the join
    // PDF survived every test in the suite. Swapping any of them changes what a
    // joining client reads - different kill/death counters, a zero-length
    // dragAndDropItem list, or a bDead of 88 - and the whole suite stayed
    // green, so nothing was pinning the PDF's field order at those offsets.
    var buf: [16384]u8 = undefined;
    const body = try buildPlayerIdBodyWithOpts(&buf, 171, 0, 4, -273, 61, 449, .{
        .player_kills = 11,
        .zombie_kills = 22,
        .deaths = 33,
        .score = 44,
    });

    // pdf id (-1) then the four counters, in stock PlayerDataFile.Write order.
    // Distinct values keep the run unique in the body.
    var counters: [20]u8 = undefined;
    std.mem.writeInt(i32, counters[0..4], -1, .little);
    std.mem.writeInt(i32, counters[4..8], 11, .little); // playerKills
    std.mem.writeInt(i32, counters[8..12], 22, .little); // zombieKills
    std.mem.writeInt(i32, counters[12..16], 33, .little); // deaths
    std.mem.writeInt(i32, counters[16..20], 44, .little); // score
    try std.testing.expect(std.mem.find(u8, body, &counters) != null);

    // dragAndDropItem is a one-element list whose single stack is empty, then
    // alreadyCraftedList, the spawnPoints count, selectedSpawnPointKey, the two
    // hardcoded fields and b_loaded. The long zero run followed by `01 00 01`
    // is what makes this window unique enough to search for.
    const drag_drop = [_]u8{
        1, 0, // dragAndDropItem list count 1
        0, 0, // its ItemStack.count 0 (no ItemValue)
        0, 0, // alreadyCraftedList
        0, // spawnPoints count
        0, 0, 0, 0, 0, 0, 0, 0, // selectedSpawnPointKey
        1, // stock hardcodes true
        0, 0, // stock hardcodes 0
        1, // b_loaded
    };
    try std.testing.expect(std.mem.find(u8, body, &drag_drop) != null);

    // deathUpdateTime(0) + currentLife(0) then bDead false and the 88 stock
    // format marker. The 88 byte is unique in the PDF, so this window pins the
    // pair directly.
    const dead_marker = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 88, 0, 1 };
    try std.testing.expect(std.mem.find(u8, body, &dead_marker) != null);
}

test "gameStageBornAtWorldTime rides the same offset as the -1 sentinel" {
    var a: [16384]u8 = undefined;
    var b: [16384]u8 = undefined;
    const dflt = try buildPlayerIdBodyInv(&a, 171, 0, 4, -273, 61, 449, &.{}, &.{}, &.{}, &.{});
    const born: u64 = 7 * 24000 + 12000;
    const set = try buildPlayerIdBodyInvLoaded(&b, 171, 0, 4, -273, 61, 449, &.{}, &.{}, &.{}, &.{}, true, born);
    // Only the eight bytes of the field change; the body must not resize.
    try std.testing.expectEqual(dflt.len, set.len);
    const off = std.mem.find(u8, dflt, &@as([8]u8, @bitCast(game_stage_born_unset))) orelse
        return error.SentinelNotFound;
    try std.testing.expectEqual(born, std.mem.readInt(u64, set[off..][0..8], .little));
    var i: usize = 0;
    while (i < dflt.len) : (i += 1) {
        if (i >= off and i < off + 8) continue;
        try std.testing.expectEqual(dflt[i], set[i]);
    }
}

/// Stock RespawnType (byte stored as i32 on wire).
pub const RespawnType = enum(i32) {
    new_game = 0,
    loaded_game = 1,
    died = 2,
    teleport = 3,
    enter_multiplayer = 4,
    join_multiplayer = 5,
    unknown = 6,
};

/// NetPackagePlayerSpawnedInWorld body: reason:i32 | pos Vector3i | entityId:i32.
/// Prefer `enter_multiplayer` / `join_multiplayer` for dedi joins (not NewGame).
pub fn buildSpawnedBody(buf: []u8, reason: i32, x: i32, y: i32, z: i32, entity_id: i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(reason);
    try w.writeI32(x);
    try w.writeI32(y);
    try w.writeI32(z);
    try w.writeI32(entity_id);
    return w.written();
}

/// Parse side of the same layout (read IL=14, GetLength 16): the client sends
/// this back after it finishes spawning locally, and stock's server
/// `ProcessPackage` (IL=47) validates the claimed entity against the sender
/// (`ValidEntityIdForSender`) before running `GameManager.PlayerSpawnedInWorld`
/// and rebroadcasting the confirm to every other peer on channel 192.
pub fn parseSpawnedBody(body: []const u8) !struct { reason: i32, x: i32, y: i32, z: i32, entity_id: i32 } {
    if (body.len < 20) return error.EndOfStream;
    var r: binary.Reader = .{ .data = body };
    return .{
        .reason = try r.readI32(),
        .x = try r.readI32(),
        .y = try r.readI32(),
        .z = try r.readI32(),
        .entity_id = try r.readI32(),
    };
}

test "spawned-in-world body is reason, position and entity id in that order" {
    // Five i32 in a row with nothing reading them back: the join path has four
    // call sites (game.zig, c2s/join.zig) and no wire test covered any of
    // them, so a swapped pair here would tell the client it spawned at a
    // coordinate built from the reason code.
    var buf: [32]u8 = undefined;
    const body = try buildSpawnedBody(
        &buf,
        @intFromEnum(RespawnType.enter_multiplayer),
        -273,
        61,
        449,
        106,
    );
    try std.testing.expectEqual(@as(usize, 20), body.len);
    try std.testing.expectEqual(@as(i32, 4), std.mem.readInt(i32, body[0..4], .little));
    try std.testing.expectEqual(@as(i32, -273), std.mem.readInt(i32, body[4..8], .little));
    try std.testing.expectEqual(@as(i32, 61), std.mem.readInt(i32, body[8..12], .little));
    try std.testing.expectEqual(@as(i32, 449), std.mem.readInt(i32, body[12..16], .little));
    try std.testing.expectEqual(@as(i32, 106), std.mem.readInt(i32, body[16..20], .little));
    // ...and the parser reads those same five positions back. The parse side
    // had no test at all: only `entity_id` was exercised (the spawn-confirm
    // scenario), so the mutant audit found reason/x/y/z interchangeable. Every
    // value here is distinct, which is what pins the order.
    const p = try parseSpawnedBody(body);
    try std.testing.expectEqual(@as(i32, 4), p.reason);
    try std.testing.expectEqual(@as(i32, -273), p.x);
    try std.testing.expectEqual(@as(i32, 61), p.y);
    try std.testing.expectEqual(@as(i32, 449), p.z);
    try std.testing.expectEqual(@as(i32, 106), p.entity_id);
}

/// NetPackageEntityPosAndRot (RE protocol-packages.md 5.5.1, write IL=76):
/// `entityId` i32 | pos.x,y,z f32 | `bUseQRotation` bool | rot.x,y,z f32 euler
/// degrees (the `false` branch) | `onGround` bool. The client applies it with 3
/// update steps.
pub fn buildPosAndRotBody(buf: []u8, entity_id: i32, x: f32, y: f32, z: f32, rx: f32, ry: f32, rz: f32, on_ground: bool) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeF32(x);
    try w.writeF32(y);
    try w.writeF32(z);
    try w.writeBool(false);
    try w.writeF32(rx);
    try w.writeF32(ry);
    try w.writeF32(rz);
    try w.writeBool(on_ground);
    return w.written();
}

/// NetPackageEntityTeleport shares PosAndRot wire (subclass of EntityPosAndRot).
pub fn buildEntityTeleportBody(buf: []u8, entity_id: i32, x: f32, y: f32, z: f32, rx: f32, ry: f32, rz: f32, on_ground: bool) ![]u8 {
    return buildPosAndRotBody(buf, entity_id, x, y, z, rx, ry, rz, on_ground);
}

/// NetPackageEntitySpawnResponse: success:bool | ItemValue. The client's
/// ProcessPackage dereferences ItemValue.ItemClass unconditionally, so the
/// item must be real: an empty sentinel NREs the stock client (the reason
/// this is only sent on place/throw, never on join). `item` null still
/// writes the empty sentinel for callers that only need the ack.
pub fn buildEntitySpawnResponse(buf: []u8, success: bool, item: ?stock_inv.StockSlot) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeBool(success);
    if (item) |it| {
        try stock_inv.writeItemValue(&w, it);
    } else {
        try stock_inv.writeEmptyItemValue(&w);
    }
    return w.written();
}

/// Stock TraderData with primary inventory entries (ItemStack + markup i8 + addedByPlayer).
pub const TraderStockEntry = stock_entity.TraderStockEntry;

/// Stock NetPackageTraderData.write (asm.il 839492-839540): the entity id and
/// tePosition are mutually exclusive. Write(bool = entityId != -1); when true it
/// writes ONLY the i32 entityId and branches past the position write. Our near-spawn
/// trader is an EntityTrader, so we always take the entity-id branch. Emitting a
/// tePosition here would desync the client's read and corrupt the TraderData body.
pub fn buildTraderDataStock(
    buf: []u8,
    entity_id: i32,
    trader_id: i32,
    available_money: i32,
    entries: []const TraderStockEntry,
) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeBool(true); // entityId != -1
    try w.writeI32(entity_id);
    try w.writeBool(true); // has TraderData
    try stock_entity.writeTraderDataBody(&w, .{
        .trader_id = trader_id,
        .available_money = available_money,
        .entries = entries,
    });
    return w.written();
}

/// Widest world coordinate a client may claim. Downstream sim code funnels
/// positions through `@floor(v)`, which traps on NaN/inf/huge in
/// safe builds, so non-finite coordinates are rejected at the wire boundary
/// rather than clamped somewhere deeper.
const world_coord_limit: f32 = 1 << 24;

fn readWorldF32(r: *binary.Reader) binary.ReadError!f32 {
    const v = try r.readF32();
    if (!std.math.isFinite(v) or @abs(v) > world_coord_limit) return error.Overflow;
    return v;
}

/// Finite float for rot/speed fields (no world-coord range).
fn readFiniteF32(r: *binary.Reader) binary.ReadError!f32 {
    const v = try r.readF32();
    if (!std.math.isFinite(v)) return error.Overflow;
    return v;
}

/// Integer counterpart of readWorldF32: same range, so a small per-axis
/// delta (block-dig radius etc.) added to it downstream cannot overflow i32.
const world_coord_limit_i32: i32 = 1 << 24;

fn readWorldI32(r: *binary.Reader) binary.ReadError!i32 {
    const v = try r.readI32();
    if (v > world_coord_limit_i32 or v < -world_coord_limit_i32) return error.Overflow;
    return v;
}

/// Read side of NetPackageEntityPosAndRot (RE protocol-packages.md 5.5.1, write
/// IL=76): `entityId` i32 | pos.x,y,z f32 | `bUseQRotation` bool | then either
/// euler f32 x3 or a quaternion f32 x4, mutually exclusive | `onGround` bool.
/// NetPackageEntityTeleport has no own write and rides this exact body (5.5.2),
/// so both C2S handlers share this parser.
///
/// Rotation is consumed but not returned: the server keeps the yaw it already
/// has for the entity, and a rotation from the wire is not a value it acts on.
/// Position goes through readWorldF32 so a coordinate outside the world bound
/// is an error here, not a teleport the sim has to undo.
/// `wire_len` is where the stock body ends, which is not `body.len`: the
/// `bUseQRotation` branch makes the length variable, and a peer may append
/// trailing bytes. A relay must forward `body[0..wire_len]`, never the raw
/// slice.
pub fn parsePosAndRotBody(body: []const u8) !struct { entity_id: i32, x: f32, y: f32, z: f32, on_ground: bool, wire_len: usize } {
    if (body.len < 30) return error.EndOfStream;
    var r: binary.Reader = .{ .data = body };
    const entity_id = try r.readI32();
    const x = try readWorldF32(&r);
    const y = try readWorldF32(&r);
    const z = try readWorldF32(&r);
    const use_q = try r.readBool();
    if (!use_q) {
        _ = try readFiniteF32(&r);
        _ = try readFiniteF32(&r);
        _ = try readFiniteF32(&r);
    } else {
        _ = try readFiniteF32(&r);
        _ = try readFiniteF32(&r);
        _ = try readFiniteF32(&r);
        _ = try readFiniteF32(&r);
    }
    const on_ground = try r.readBool();
    return .{ .entity_id = entity_id, .x = x, .y = y, .z = z, .on_ground = on_ground, .wire_len = r.pos };
}

/// NetPackageEntityRelPosAndRot (RE protocol-packages.md 5.5.4, write IL=30).
/// Extends the Rotation body (5.5.3), so the full wire order is: `entityId` i32
/// | `bUseQRotation` bool | rot.x,y,z i16 (EncodeRot, rot*256/360) | dPos.x,y,z
/// i16 (1/32 block) | `onGround` bool | `updateSteps` i16. The body-inventory
/// table lists only the five fields after the Rotation base.
pub fn buildRelPosBody(buf: []u8, entity_id: i32, dx: i16, dy: i16, dz: i16, rx: i16, ry: i16, rz: i16, on_ground: bool, steps: i16) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeBool(false);
    try w.writeI16(rx);
    try w.writeI16(ry);
    try w.writeI16(rz);
    try w.writeI16(dx);
    try w.writeI16(dy);
    try w.writeI16(dz);
    try w.writeBool(on_ground);
    try w.writeI16(steps);
    return w.written();
}

/// Stock NetPackageEntityAliveFlags bits actually set on the S2C path (V3).
/// Values are canonical in ecs/components.zig (single source of truth for the
/// bit numbers); these aliases keep the stock wire naming.
pub const cF_approaching_player: u16 = components.flag_approaching_player;
pub const cF_spawned: u16 = components.flag_spawned;
pub const cF_is_alert: u16 = components.flag_is_alert;
/// Stock `IsCrouching` bit (protocol-packages.md 5.5.6): set by the client's
/// EntityFlags/AliveFlags package; the sim reads it for the stealth sense
/// gates (hear muffle + sleeper detect).
pub const cF_crouching: u16 = components.flag_crouching;

/// NetPackageEntityAliveFlags (RE inventories/netpackage-bodies.md, write
/// IL=8): the EntityTargeted base entityId, then `flags` u16. Bit meanings in
/// protocol-packages.md 5.5.6.
pub fn buildAliveFlagsBody(buf: []u8, entity_id: i32, flags: u16) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeU16(flags);
    return w.written();
}

/// Read side of NetPackageEntityAliveFlags (RE protocol-packages.md 5.5.6,
/// write IL=8): `entityId` i32 | `flags` u16, the order buildAliveFlagsBody
/// writes. Unknown bits are kept rather than masked off: the bit meanings are
/// canonical in ecs/components.zig and the caller decides which it acts on, so
/// dropping a bit here would hide a client the RE table does not yet cover.
pub fn parseAliveFlagsBody(body: []const u8) !struct { entity_id: i32, flags: u16 } {
    var r: binary.Reader = .{ .data = body };
    return .{ .entity_id = try r.readI32(), .flags = try r.readU16() };
}

/// NetPackageEntitySpeeds: EntityTargeted entityId + movementState:u8 + speedForward/strafe:f32.
pub fn buildEntitySpeedsBody(buf: []u8, entity_id: i32, movement_state: u8, speed_forward: f32, speed_strafe: f32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeByte(movement_state);
    try w.writeF32(speed_forward);
    try w.writeF32(speed_strafe);
    return w.written();
}

/// Read side of NetPackageEntitySpeeds (RE protocol-packages.md residual table,
/// write IL=17, Process IL=37): `entityId` i32 | `movementState` u8 |
/// `speedForward` f32 | `speedStrafe` f32, the order buildEntitySpeedsBody
/// writes. Both speeds go through readFiniteF32, so a NaN or infinity from the
/// wire is an error instead of a value that poisons every later comparison.
pub fn parseEntitySpeedsBody(body: []const u8) !struct { entity_id: i32, movement_state: u8, speed_forward: f32, speed_strafe: f32 } {
    if (body.len < 13) return error.EndOfStream;
    var r: binary.Reader = .{ .data = body };
    return .{
        .entity_id = try r.readI32(),
        .movement_state = try r.readByte(),
        .speed_forward = try readFiniteF32(&r),
        .speed_strafe = try readFiniteF32(&r),
    };
}

/// Head of PlayerDataFile.WriteNetwork / ECD.write(networkWrite=false) for the
/// SavePlayerData C2S body: `FileVersion` u8 | `entityClass` i32 | `id` i32 |
/// `lifetime` f32 | pos f32 x3 (RE EntityCreationData.write, protocol-packages
/// 5.1).
///
/// Returns the entity id only. The position used to come back too, and both
/// call sites discarded it with "pos unreliable (origin-relative); ignore" -
/// the client writes it relative to its own origin, so it is not a world
/// coordinate the server can use. Handing back three unchecked f32 that nobody
/// consumes is the same shape as the nearEntityId guess removed the same day:
/// a value the server cannot act on should not leave the parser. The pos bytes
/// are still consumed so the version/length validation this function exists for
/// stays exact.
pub fn parsePlayerDataEcdHead(body: []const u8) !struct { entity_id: i32 } {
    if (body.len < 1 + 4 + 4 + 4 + 12) return error.EndOfStream;
    var r: binary.Reader = .{ .data = body };
    const ver = try r.readByte();
    if (ver != 35 and ver != 36) return error.EndOfStream;
    _ = try r.readI32(); // entityClass
    const entity_id = try r.readI32();
    _ = try r.readF32(); // lifetime
    _ = try r.readF32(); // pos.x, origin-relative
    _ = try r.readF32(); // pos.y
    _ = try r.readF32(); // pos.z
    return .{ .entity_id = entity_id };
}

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
    // Skip ECD through entityData/trader (same as writeEmptyPlayerDataFileNetwork head).
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

/// Stock EnumRemoveEntityReason: Undef=0 Unloaded=1 Killed=2 Despawned=3 Captured=4.
pub const RemoveEntityReason = enum(u8) {
    undef = 0,
    unloaded = 1,
    killed = 2,
    despawned = 3,
    captured = 4,
};

/// NetPackageEntityRemove: entityId:i32 | reason:u8 (EnumRemoveEntityReason).
pub fn buildRemoveBody(buf: []u8, entity_id: i32) ![]u8 {
    return buildRemoveBodyReason(buf, entity_id, .killed);
}

/// NetPackageEntityRemove (RE protocol-packages.md, write IL=8): the
/// EntityTargeted base `entityId` i32, then `reason` u8
/// (EnumRemoveEntityReason). The body-inventory table lists only `reason`,
/// since it shows fields after the base.
pub fn buildRemoveBodyReason(buf: []u8, entity_id: i32, reason: RemoveEntityReason) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeByte(@intFromEnum(reason));
    return w.written();
}

test "EntityRemove body is entityId + reason byte" {
    var buf: [8]u8 = undefined;
    const body = try buildRemoveBody(&buf, 100);
    try std.testing.expectEqual(@as(usize, 5), body.len);
    try std.testing.expectEqual(@as(i32, 100), std.mem.readInt(i32, body[0..4], .little));
    try std.testing.expectEqual(@as(u8, 2), body[4]); // Killed
    const u = try buildRemoveBodyReason(&buf, 50, .unloaded);
    try std.testing.expectEqual(@as(u8, 1), u[4]);
}

/// NetPackageBloodmoonMusic (Assembly-CSharp NetPackageBloodmoonMusic::write): after the
/// base NetPackage header the payload is a single WriteBool(IsBloodMoonMusicEligible).
/// GetLength()=1, PackageDirection=ToClient. Sent per-player by DynamicMusic.Conductor.Update
/// in stock (per-player eligibility); our server broadcasts one global bool as an approximation.
pub fn buildBloodmoonMusicBody(buf: []u8, eligible: bool) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeBool(eligible);
    return w.written();
}

test "BloodmoonMusic body is a single eligibility bool" {
    var buf: [4]u8 = undefined;
    const on = try buildBloodmoonMusicBody(&buf, true);
    try std.testing.expectEqual(@as(usize, 1), on.len);
    try std.testing.expectEqual(@as(u8, 1), on[0]);
    const off = try buildBloodmoonMusicBody(&buf, false);
    try std.testing.expectEqual(@as(usize, 1), off.len);
    try std.testing.expectEqual(@as(u8, 0), off[0]);
}

/// NetPackageSleeperWakeup (Assembly-CSharp NetPackageSleeperWakeup::write,
/// IL=8): after the base header the payload is WriteInt32(m_targetId).
/// GetLength()=8, PackageDirection=ToClient. Sent broadcast (unreliable) by
/// EntityAlive.ConditionalTriggerSleeperWakeUp when a sleeper zombie wakes
/// (proximity, noise, damage; protocol-packages.md §6.19). The client plays
/// the wake animation via EntityAlive.ConditionalTriggerSleeperWakeUp.
pub fn buildSleeperWakeupBody(buf: []u8, entity_id: i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    return w.written();
}

/// NetPackageSleeperPassiveChange (Assembly-CSharp, base NetPackageEntityTargeted):
/// payload is WriteInt32(entityId) via the base write. GetLength()=8,
/// PackageDirection=ToClient. Sent broadcast (unreliable) by
/// EntityAlive.SetSleeperActive (IL=26) when a volume's sleeper stays passive
/// after trigger; the client clears IsSleeperPassive (Process IL=21).
/// Note: NetPackageSleeperPose (entityId + pose byte) is registered but never
/// emitted by any stock server path in the V3.1.0 b14 dump - the sleep pose
/// rides the EntitySpawn is_sleeper/is_sleeper_passive flags instead.
pub fn buildSleeperPassiveChangeBody(buf: []u8, entity_id: i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    return w.written();
}

test "SleeperWakeup body is the target entity id" {
    var buf: [8]u8 = undefined;
    const b = try buildSleeperWakeupBody(&buf, 107);
    try std.testing.expectEqual(@as(usize, 4), b.len);
    try std.testing.expectEqual(@as(i32, 107), std.mem.readInt(i32, b[0..4], .little));
}

test "SleeperPassiveChange body is the target entity id" {
    var buf: [8]u8 = undefined;
    const b = try buildSleeperPassiveChangeBody(&buf, -5);
    try std.testing.expectEqual(@as(usize, 4), b.len);
    try std.testing.expectEqual(@as(i32, -5), std.mem.readInt(i32, b[0..4], .little));
}

/// NetPackageEntityLookAt (Assembly-CSharp NetPackageEntityLookAt::write,
/// IL=22): base NetPackageEntityTargeted entityId, then the look-at world
/// position as three int-truncated i32 (Vector3 conv.i4). GetLength()=16,
/// PackageDirection=ToClient. Sent to tracking players by
/// EntityAlive.SetLookPosition when the look moves past the 0.0016
/// sqr-delta gate (protocol-packages.md §5.2.1). Cosmetic head-aim only.
pub fn buildEntityLookAtBody(buf: []u8, entity_id: i32, lx: f32, ly: f32, lz: f32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeI32(@trunc(lx));
    try w.writeI32(@trunc(ly));
    try w.writeI32(@trunc(lz));
    return w.written();
}

test "EntityLookAt body is entityId + int-truncated look position" {
    var buf: [32]u8 = undefined;
    const b = try buildEntityLookAtBody(&buf, 107, 10.9, 70.2, -3.7);
    try std.testing.expectEqual(@as(usize, 16), b.len);
    try std.testing.expectEqual(@as(i32, 107), std.mem.readInt(i32, b[0..4], .little));
    try std.testing.expectEqual(@as(i32, 10), std.mem.readInt(i32, b[4..8], .little));
    try std.testing.expectEqual(@as(i32, 70), std.mem.readInt(i32, b[8..12], .little));
    try std.testing.expectEqual(@as(i32, -3), std.mem.readInt(i32, b[12..16], .little));
}

/// One minimap chunk piece: the map-database key (RE IMapChunkDatabase
/// ToChunkDBKey: ((x & 0xFFFF) << 16) | (z & 0xFFFF)) + 256 RGB555 colors.
pub const MapChunkPiece = struct {
    key: i32,
    colors: [256]u16,
};

/// NetPackageMapChunks (Assembly-CSharp write IL=109): entityId i32, count
/// u16, then per piece (dbKey i32 + 256 u16 colors). Channel 1, Compress=true
/// (the caller sends via sendCompressed); protocol-packages.md §3.3.
pub fn buildMapChunksBody(buf: []u8, entity_id: i32, pieces: []const MapChunkPiece) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeU16(@intCast(pieces.len));
    for (pieces) |p| {
        try w.writeI32(p.key);
        for (p.colors) |c| try w.writeU16(c);
    }
    return w.written();
}

test "MapChunks body is entityId + count + key + 256 colors per piece" {
    var buf: [4096]u8 = undefined;
    var colors: [256]u16 = .{0} ** 256;
    colors[0] = 434;
    colors[255] = 16816;
    const pieces = [_]MapChunkPiece{.{ .key = 0x00010002, .colors = colors }};
    const b = try buildMapChunksBody(&buf, 107, &pieces);
    try std.testing.expectEqual(@as(usize, 4 + 2 + 4 + 512), b.len);
    try std.testing.expectEqual(@as(i32, 107), std.mem.readInt(i32, b[0..4], .little));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, b[4..6], .little));
    try std.testing.expectEqual(@as(i32, 0x00010002), std.mem.readInt(i32, b[6..10], .little));
    try std.testing.expectEqual(@as(u16, 434), std.mem.readInt(u16, b[10..12], .little));
    try std.testing.expectEqual(@as(u16, 16816), std.mem.readInt(u16, b[10 + 255 * 2 ..][0..2], .little));
}

/// AIDirector/HordeEvent enum (Assembly-CSharp AIDirector/HordeEvent). Client
/// EntityPlayerLocal.HandleHordeEvent reacts to warn2 (spawn-warning audio) and
/// spawn (camera shake + spawn audio); none/warn1 are no-ops.
pub const HordeEvent = enum(u8) {
    none = 0,
    warn1 = 1,
    warn2 = 2,
    spawn = 3,
};

/// NetPackageHordeEvent (Assembly-CSharp NetPackageHordeEvent::write): after the base
/// NetPackage header the payload is Write((uint8)m_event), Write(m_pos.x/y/z f32),
/// Write(m_maxDist f32) = 17 bytes. ProcessPackage gates on distance: fires
/// HandleHordeEvent(m_event) only if (localPlayerPos - m_pos).sqrMagnitude <= m_maxDist^2,
/// so m_pos at origin with a large m_maxDist reaches every receiving client.
/// NOTE: stock server has NO sender for this package; the wire format and client handler
/// are real but the package is vestigial over the network through V3.1.0 b14. Emitting it is
/// non-stock behavior (see docs/GAP_ANALYSIS.md).
pub fn buildHordeEventBody(buf: []u8, event: HordeEvent, x: f32, y: f32, z: f32, max_dist: f32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeByte(@intFromEnum(event));
    try w.writeF32(x);
    try w.writeF32(y);
    try w.writeF32(z);
    try w.writeF32(max_dist);
    return w.written();
}

test "HordeEvent body is event byte + pos + maxDist (17 bytes)" {
    var buf: [24]u8 = undefined;
    const body = try buildHordeEventBody(&buf, .spawn, 1.5, -2.0, 3.25, 4096.0);
    try std.testing.expectEqual(@as(usize, 17), body.len);
    try std.testing.expectEqual(@as(u8, 3), body[0]);
    const fx: f32 = @bitCast(std.mem.readInt(u32, body[1..5], .little));
    const fy: f32 = @bitCast(std.mem.readInt(u32, body[5..9], .little));
    const fz: f32 = @bitCast(std.mem.readInt(u32, body[9..13], .little));
    const fd: f32 = @bitCast(std.mem.readInt(u32, body[13..17], .little));
    try std.testing.expectEqual(@as(f32, 1.5), fx);
    try std.testing.expectEqual(@as(f32, -2.0), fy);
    try std.testing.expectEqual(@as(f32, 3.25), fz);
    try std.testing.expectEqual(@as(f32, 4096.0), fd);
}

/// NetPackageDamageEntity flags (V3.2.0 packed u32 bitfield; the 3.1.0 wire
/// wrote ten separate booleans, changelog-3.2.0 §3.1 / protocol.md §6.5).
pub const dmg_can_hit_special: u32 = 0x001;
pub const dmg_cripple_legs: u32 = 0x002;
pub const dmg_critical: u32 = 0x004;
pub const dmg_dismember: u32 = 0x008;
pub const dmg_fatal: u32 = 0x010;
pub const dmg_from_buff: u32 = 0x020;
pub const dmg_ignore_consecutive: u32 = 0x040;
pub const dmg_ignore_party_share: u32 = 0x080;
pub const dmg_pain_hit: u32 = 0x100;
pub const dmg_turn_into_crawler: u32 = 0x200;
pub const dmg_trap_kill_xp: u32 = 0x400;

/// NetPackageDamageEntity (RE inventories/netpackage-bodies.md, write IL=144).
/// All 30 fields in stock order: `entityId` i32 | `flags` u32 | `damageSrc` u8 |
/// `damageTyp` u8 | `strength` u16 | `hitDirection` u8 | `hitBodyPart` i16 |
/// `movementState` u8 | `attackerEntityId` i32 | dir f32 x3 | `blockPos`
/// (StreamUtils Vector3i) | `hitTransformName` string | hitTransformPosition
/// f32 x3 | uvHit f32 x2 | `KillXPScale` f32 | `damageMultiplier` f32 |
/// `random` f32 | `bonusDamageType` u8 | `StunType` u8 | `StunDuration` f32 |
/// `ArmorSlot` u8 | `ArmorSlotGroup` u8 | `ArmorDamage` u16 | `attackingItem`
/// bool, then the ItemValue only when that bool is true.
///
/// zdtd fills the head (entity, flags, source, type, strength, attacker) and
/// writes the descriptive tail as neutral values: hit transform, uv and armour
/// slots describe a client-side hit report we do not originate, and the false
/// `attackingItem` flag is the stock null path rather than a truncation.
pub fn buildDamageBody(buf: []u8, entity_id: i32, source: u8, dtype: u8, strength: u16, fatal: bool, attacker: i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    var flags: u32 = dmg_pain_hit;
    if (fatal) flags |= dmg_fatal;
    try w.writeU32(flags);
    try w.writeByte(source);
    try w.writeByte(dtype);
    try w.writeU16(strength);
    try w.writeByte(0); // hitDirection
    try w.writeI16(0); // bodyPart
    try w.writeByte(0); // movementState
    try w.writeI32(attacker);
    try w.writeF32(0);
    try w.writeF32(-1);
    try w.writeF32(0); // dirV
    try w.writeI32(0);
    try w.writeI32(0);
    try w.writeI32(0); // blockPos
    try w.writeString(""); // hitTransformName
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(0); // hitTransformPosition
    try w.writeF32(0);
    try w.writeF32(0); // uvHit
    try w.writeF32(1); // KillXPScale
    try w.writeF32(1); // damageMultiplier
    try w.writeF32(0); // random
    try w.writeByte(0); // bonusDamageType
    try w.writeByte(0); // StunType
    try w.writeF32(0); // StunDuration
    try w.writeByte(0); // ArmorSlot
    try w.writeByte(0); // ArmorSlotGroup
    try w.writeU16(0); // ArmorDamage
    try w.writeBool(false); // attackingItem present
    return w.written();
}

/// Read side of the V3.2.0 NetPackageDamageEntity head: `entityId` i32 |
/// packed flags u32 | `source` u8 | `damageType` u8 | `strength` u16 |
/// `hitDirection` u8 | `hitBodyPart` i16, matching the builder above (the ten
/// 3.1.0 booleans folded into one flag word in 3.2.0; docs/wire/PACKAGES.md).
/// The tail past the head is not decoded: the server recomputes damage from
/// its own weapon and armor state, so those fields are not values it acts on.
pub fn parseDamageHead(body: []const u8) !struct { entity_id: i32, source: u8, dtype: u8, strength: u16, fatal: bool, trap_kill_xp: bool, body_part: i16 } {
    if (body.len < 4 + 4 + 1 + 1 + 2 + 1 + 2 + 1) return error.EndOfStream;
    var r: binary.Reader = .{ .data = body };
    const entity_id = try r.readI32();
    const flags = try r.readU32();
    const source = try r.readByte();
    const dtype = try r.readByte();
    const strength = try r.readU16();
    _ = try r.readByte(); // hitDirection
    const body_part = try r.readI16(); // hitBodyPart (EnumBodyPartHit)
    _ = try r.readByte(); // movementState
    return .{
        .entity_id = entity_id,
        .source = source,
        .dtype = dtype,
        .strength = strength,
        .fatal = (flags & dmg_fatal) != 0,
        .trap_kill_xp = (flags & dmg_trap_kill_xp) != 0,
        .body_part = body_part,
    };
}

test "DamageEntity V3.2.0 golden layout: packed flags + KillXPScale at fixed offsets" {
    // The 3.1.0 ten-boolean wire was repacked (changelog-3.2.0 §3.1); the
    // stock client Reads this body on the C2S damage path, so the byte
    // layout is pinned here, not just the build/parse roundtrip (a
    // self-consistent build+parse break would still pass scenarios but
    // desync the real client's Read). Offsets derived from the builder's
    // write order: entityId 0, flags 4, source 8, dtype 9, strength 10,
    // hitDirection 12, bodyPart 13, movementState 15, attacker 16, ...,
    // KillXPScale 65, damageMultiplier 69.
    var buf: [128]u8 = undefined;
    const body = try buildDamageBody(&buf, 0x11223344, 1, 3, 100, true, 0x55667788);
    try std.testing.expectEqual(@as(usize, 88), body.len);
    try std.testing.expectEqual(@as(i32, 0x11223344), std.mem.readInt(i32, body[0..4], .little));
    // fatal=true -> pain_hit | fatal = 0x100 | 0x010.
    try std.testing.expectEqual(@as(u32, 0x110), std.mem.readInt(u32, body[4..8], .little));
    try std.testing.expectEqual(@as(u8, 1), body[8]); // source
    try std.testing.expectEqual(@as(u8, 3), body[9]); // dtype
    try std.testing.expectEqual(@as(u16, 100), std.mem.readInt(u16, body[10..12], .little));
    try std.testing.expectEqual(@as(i32, 0x55667788), std.mem.readInt(i32, body[16..20], .little));
    // The direction vector at 20 is (0, -1, 0): two zeros around a -1, so the
    // -1 is the only observable word and its position is what a swap moves.
    const f32At = struct {
        fn get(b: []const u8, off: usize) f32 {
            return @bitCast(std.mem.readInt(u32, b[off..][0..4], .little));
        }
    }.get;
    try std.testing.expectEqual(@as(f32, 0), f32At(body, 20));
    try std.testing.expectEqual(@as(f32, -1), f32At(body, 24)); // dirV y
    try std.testing.expectEqual(@as(f32, 0), f32At(body, 28));
    // KillXPScale (V3.2.0 addition) sits at 65; damageMultiplier at 69.
    const kxs: f32 = @bitCast(std.mem.readInt(u32, body[65..69], .little));
    try std.testing.expectEqual(@as(f32, 1.0), kxs);
    const dm: f32 = @bitCast(std.mem.readInt(u32, body[69..73], .little));
    try std.testing.expectEqual(@as(f32, 1.0), dm);
    const head = try parseDamageHead(body);
    try std.testing.expectEqual(@as(i32, 0x11223344), head.entity_id);
    try std.testing.expectEqual(@as(u16, 100), head.strength);
    try std.testing.expect(head.fatal);
    try std.testing.expect(!head.trap_kill_xp);
}

test "DamageEntity packed flags: fatal and trap_kill_xp bits parse independently" {
    var buf: [128]u8 = undefined;
    // trap_kill_xp only (0x400): fatal must be false, trap true. The head
    // needs the full 16 bytes (entityId+flags+source+dtype+strength+
    // hitDirection+bodyPart+movementState) before parseDamageHead accepts it.
    var w: binary.Writer = .{ .buf = &buf };
    try w.writeI32(7);
    try w.writeU32(dmg_trap_kill_xp);
    try w.writeByte(0); // source
    try w.writeByte(0); // dtype
    try w.writeU16(5); // strength
    try w.writeByte(0); // hitDirection
    try w.writeI16(0); // bodyPart
    try w.writeByte(0); // movementState
    const body = buf[0..w.written().len];
    const head = try parseDamageHead(body);
    try std.testing.expect(!head.fatal);
    try std.testing.expect(head.trap_kill_xp);
    try std.testing.expectEqual(@as(u16, 5), head.strength);
}

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

/// NetPackageChunk body (zdtd intermediate payload + optional stock envelope).
///
/// Inner payload (always):
///   cx:i32 LE | cz:i32 LE | ydim:i32 LE (=256) | heights:u8[256]
/// heights[lx + lz*16] = surface Y. Size = 268.
///
/// Stock envelope (layout D, default for S→C):
///   overwrite:bool(=true) | cx:i16 | cy:i16(=0) | cz:i16 | dataLen:i32 | payload
/// Stock clients still need a real Chunk.write blob inside payload; bots/loadgen
/// parse either envelope or bare payload via parseChunkBody.
pub const chunk_body_size: usize = 12 + 256;
/// Envelope overhead: 1 + 2+2+2 + 4 = 11.
pub const chunk_stock_envelope_overhead: usize = 11;

/// WorldChunkCache.MakeChunkKey(x, z): ((z & 0xFFFFFF) << 24) | (x & 0xFFFFFF)
pub const makeChunkKey = stock_deco.makeChunkKey;

pub fn extractChunkKeyX(key: i64) i32 {
    // extractX: sign-extend low 24 bits
    const u: i32 = @truncate(key);
    return (u << 8) >> 8;
}

pub fn extractChunkKeyZ(key: i64) i32 {
    // extractZ from stock IL: ((key >> 16) as i32) >> 8 → effectively high 24 of low 48
    const shifted: i32 = @truncate(key >> 16);
    return shifted >> 8;
}

/// zdtd height-map payload for tests and loadgen, **not a stock package body**:
/// cx i32 | cz i32 | ydim i32 | 256 height bytes. The stock chunk body is built
/// by stock_chunk.buildNetPackageChunkNew; see buildStockChunkEnvelope below.
pub fn buildChunkPayload(buf: []u8, cx: i32, cz: i32, heights: *const [256]u8) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(cx);
    try w.writeI32(cz);
    try w.writeI32(256); // ydim
    try w.writeBytes(heights);
    return w.written();
}

/// Test/loadgen helper: stock NetPackageChunk envelope (overwrite=true) around
/// a height-plane payload. Production client stream uses
/// `stock_chunk.buildNetPackageChunkNew`.
pub fn buildChunkBody(buf: []u8, cx: i32, cz: i32, heights: *const [256]u8) ![]u8 {
    if (buf.len < chunk_stock_envelope_overhead + chunk_body_size) return error.Overflow;
    var payload_buf: [chunk_body_size]u8 = undefined;
    const payload = try buildChunkPayload(&payload_buf, cx, cz, heights);
    var w: binary.Writer = .{ .buf = buf };
    try w.writeBool(true);
    try w.writeI16(@intCast(cx));
    try w.writeI16(0); // cy
    try w.writeI16(@intCast(cz));
    try w.writeI32(@intCast(payload.len));
    try w.writeBytes(payload);
    return w.written();
}

pub const ChunkParsed = struct {
    cx: i32,
    cz: i32,
    heights: []const u8,
};

/// Read side of buildChunkBody: the stock NetPackageChunk envelope
/// (`overwrite` bool | cx,cy,cz i16 | `len` i32 | payload) wrapped around
/// zdtd's height-plane payload, which is **not a stock chunk body**. The real
/// client stream is built by stock_chunk.buildNetPackageChunkNew and read by
/// the client, never by this function; this decodes what the tests and loadgen
/// write.
///
/// A body that does not start with a 0/1 discriminant is taken as a bare
/// payload, so both forms round-trip through one entry point.
pub fn parseChunkBody(body: []const u8) !ChunkParsed {
    // Stock envelope?
    if (body.len >= chunk_stock_envelope_overhead + chunk_body_size and (body[0] == 0 or body[0] == 1)) {
        var r: binary.Reader = .{ .data = body };
        const overwrite = try r.readBool();
        if (overwrite) {
            const cx = try r.readI16();
            _ = try r.readI16();
            const cz = try r.readI16();
            const data_len = try r.readI32();
            if (data_len < 0 or r.remaining() < @as(usize, @intCast(data_len))) return error.EndOfStream;
            const payload = body[r.pos .. r.pos + @as(usize, @intCast(data_len))];
            // Prefer coords from envelope when payload is height plane
            if (payload.len >= chunk_body_size) {
                const inner = try parseChunkPayload(payload);
                return .{ .cx = cx, .cz = cz, .heights = inner.heights };
            }
            return .{ .cx = cx, .cz = cz, .heights = payload };
        }
    }
    return parseChunkPayload(body);
}

fn parseChunkPayload(body: []const u8) !ChunkParsed {
    var r: binary.Reader = .{ .data = body };
    const cx = try r.readI32();
    const cz = try r.readI32();
    _ = try r.readI32();
    if (r.remaining() < 256) return error.EndOfStream;
    const heights = body[r.pos .. r.pos + 256];
    return .{ .cx = cx, .cz = cz, .heights = heights };
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
const block_change_flag_value: u8 = 1; // bChangeBlockValue
const block_change_flag_damage: u8 = 2; // bChangeDamage (damage rides in BlockValue)
const block_change_flag_density: u8 = 4; // bChangeDensity (sbyte)
const block_change_flag_force_density: u8 = 8; // bForceDensity (no payload)
const block_change_flag_update_light: u8 = 0x10; // bUpdateLight (no payload)
const block_change_flag_texture: u8 = 0x20; // bChangeTexture (TextureFullArray)
const block_change_flags_known: u8 =
    block_change_flag_value | block_change_flag_damage | block_change_flag_density |
    block_change_flag_force_density | block_change_flag_update_light | block_change_flag_texture;

/// BlockValue.type: low 16 of rawData (asm.il BlockValue.get_type).
const block_type_mask: u32 = 0xffff;

/// BlockValue.meta lives in rawData bits 22..25 (asm.il:140570 get_meta).
/// Powered blocks carry their visual state there: bit 0x1 = isPowered,
/// bit 0x2 = isOn (Block::ActivateBlock, asm.il:127088 / 137044).
pub const block_meta_powered: u8 = 1;
pub const block_meta_on: u8 = 2;

pub fn blockMeta(raw: u32) u8 {
    return @intCast((raw >> 22) & 15);
}

/// BlockValue::set_meta: clear bits 22..25 then splice the low nibble back in.
pub fn withBlockMeta(raw: u32, meta: u8) u32 {
    return (raw & 0xfc3fffff) | (@as(u32, meta & 15) << 22);
}

/// NetPackageSetBlock, one change (RE write IL=37; field order in
/// buildSetBlockBodyRaw). Null platform user; peers accept S2C without id check.
/// Id-only: rotation and meta bits are zero, so this is safe for fresh placement
/// and wrong for echoing a mutated block. Those callers want buildSetBlockBodyRaw.
pub fn buildSetBlockBody(buf: []u8, x: i32, y: i32, z: i32, block_id: u16) ![]u8 {
    return buildSetBlockBodyRaw(buf, x, y, z, @as(u32, block_id), 0, 0, 0);
}

/// NetPackageSetBlock carrying block damage (RE write IL=37; the damage u16 is
/// part of BlockValue.Write, see buildSetBlockBodyRaw).
pub fn buildSetBlockBodyDamage(
    buf: []u8,
    x: i32,
    y: i32,
    z: i32,
    block_id: u16,
    damage: u16,
    changed_by_entity: i32,
    local_player_that_changed: i32,
) ![]u8 {
    return buildSetBlockBodyRaw(buf, x, y, z, @as(u32, block_id), damage, changed_by_entity, local_player_that_changed);
}

/// Authoritative SetBlock carrying the whole BlockValue.rawData. Callers that
/// echo a mutated block must use this, not the id-only form: rotation and meta
/// live above the low 16 bits (asm.il:141018 BlockValue::Write), so rebuilding
/// rawData from the id alone snaps switches back off and doors back shut.
/// NetPackageSetBlock (RE protocol-packages.md 6.9 + write IL=37):
/// `persistentPlayerId` (ToStream; null = one 0 byte) | `blockChanges` count
/// i16 | count x BlockChangeInfo.Write | `localPlayerThatChanged` i32.
///
/// BlockChangeInfo.Write is BlockValueRef | `changedByEntityId` i32 | flags u8,
/// then the payloads the flags select. We set bChangeBlockValue only, so what
/// follows is BlockValue.Write = `rawData` u32 + `damage` u16 (Write IL=10).
/// The damage u16 belongs to BlockValue, not to the bChangeDamage flag: that
/// flag only tells the receiver to apply the damage that already rides here.
pub fn buildSetBlockBodyRaw(
    buf: []u8,
    x: i32,
    y: i32,
    z: i32,
    raw: u32,
    damage: u16,
    changed_by_entity: i32,
    local_player_that_changed: i32,
) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try platform_user.write(&w, null);
    try w.writeI16(1); // one BlockChangeInfo
    // BlockValueRef: type=1 (BlockPosition) + Vector3i
    try w.writeByte(1);
    try w.writeI32(x);
    try w.writeI32(y);
    try w.writeI32(z);
    try w.writeI32(changed_by_entity);
    try w.writeByte(block_change_flag_value);
    try w.writeU32(raw);
    try w.writeU16(damage);
    try w.writeI32(local_player_that_changed);
    return w.written();
}

pub const BlockChange = struct {
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
    block_id: u16 = 0,
    /// Full BlockValue.rawData (type low 16 + rotation/rotation bits).
    raw: u32 = 0,
    damage: u16 = 0,
    has_pos: bool = false,
    has_value: bool = false,
};

/// First change of a NetPackageSetBlock body, for the callers that only ever
/// act on one (RE blocks.md, BlockChangeInfo.Read IL=76). Full layout and the
/// legacy fixture form are in parseSetBlockChanges; this is a projection of it,
/// not a second decoder. A change without both a position and a value is an
/// error here because there is nothing to return.
pub fn parseSetBlockBody(body: []const u8) !struct { x: i32, y: i32, z: i32, block_id: u16 } {
    var one: [1]BlockChange = undefined;
    const n = try parseSetBlockChanges(body, one[0..]);
    if (n == 0 or !one[0].has_pos or !one[0].has_value) return error.EndOfStream;
    return .{ .x = one[0].x, .y = one[0].y, .z = one[0].z, .block_id = one[0].block_id };
}

/// Read side of NetPackageSetBlock (RE blocks.md, BlockChangeInfo.Write IL=89 /
/// Read IL=76): `persistentPlayerId` (PlatformUserIdentifier) | `count` i16 |
/// then per change a `BlockValueRef` (discriminant byte, 1 = Block followed by
/// Vector3i) | `changedByEntityId` i32 | flags byte | the flagged payloads in
/// flag order (BlockValue.Write = `rawData` u32 + `damage` u16, `sbyte`
/// density, TextureFullArray). bForceDensity and bUpdateLight are flags with no
/// payload.
///
/// An unknown flag bit is an error, not a skip: the bit selects a payload this
/// reader cannot size, so continuing would decode every later change in the
/// batch from a desynced offset as a bogus world edit. Changes lacking a
/// position or a value are dropped from the output rather than returned half
/// filled.
///
/// There is no length-keyed shortcut here. A 14-byte legacy branch used to sit
/// at the top, and 14 is a length a stock body reaches on its own: identity
/// plus a zero count is `6 + platform.len + id.len`, so any pair summing to 8
/// (`"Steam"` with a 3-character id) hit it, and an empty change list came back
/// as one change with x/y/z read out of the identity bytes. The caller's reach
/// check happened to reject those coordinates; that is not a defence a parser
/// should lean on.
pub fn parseSetBlockChanges(body: []const u8, out: []BlockChange) !usize {
    var r: binary.Reader = .{ .data = body };
    try platform_user.skip(&r);
    const n_i = try r.readI16();
    if (n_i <= 0) return 0;
    const n: usize = @intCast(n_i);
    var written: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ch = try readBlockChangeInfo(&r);
        if (ch.has_pos and ch.has_value and written < out.len) {
            out[written] = ch;
            written += 1;
        }
    }
    return written;
}

/// One `NetPackageWaterSet/WaterSetInfo`: `worldPos` Vector3i then a
/// `WaterValue` whose whole serialized form is a `UInt16 mass`
/// (WaterValue.il.txt:127, SerializedLength IL=2 returns 2).
pub const WaterSetChange = struct {
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
    mass: u16 = 0,
};

/// Stock `WaterValue.Full` mass (WaterValue.il.txt:141, `ldc.i4 19500`); the
/// `BlockValue` ctor maps an isWater block to exactly this. `Empty` is 0.
pub const water_mass_full: u16 = 19500;

/// `NetPackageWaterSet::read` (NetPackageWaterSet.il.txt:55): `senderEntityId`
/// i32 | `changes.Count` u16 | WaterSetInfo per entry. The client sends this
/// when a jar fill/empty or a water-cube tool edits water; stock's server
/// relays it to every other peer and then applies it, so the change is not
/// local to the acting client.
pub fn parseWaterSet(body: []const u8, out: []WaterSetChange) binary.ReadError!struct { sender: i32, n: usize } {
    var r: binary.Reader = .{ .data = body };
    const sender = try r.readI32();
    const count = try r.readU16();
    var written: usize = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const x = try r.readI32();
        const y = try r.readI32();
        const z = try r.readI32();
        const mass = try r.readU16();
        if (written < out.len) {
            out[written] = .{ .x = x, .y = y, .z = z, .mass = mass };
            written += 1;
        }
    }
    return .{ .sender = sender, .n = written };
}

/// Write side of the same body, for the server relay (stock
/// `NetPackageWaterSet::write` IL=36, NetPackageWaterSet.il.txt:86: base
/// write, `senderEntityId` i32, `changes.Count` as u16, then
/// `WaterSetInfo::Write` per entry, itself `StreamUtils::Write(Vector3i)` plus
/// `WaterValue::Write` u16, NetPackageWaterSet_WaterSetInfo.il.txt:16).
pub fn buildWaterSetBody(buf: []u8, sender: i32, changes: []const WaterSetChange) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(sender);
    if (changes.len > std.math.maxInt(u16)) return error.Overflow;
    try w.writeU16(@intCast(changes.len));
    for (changes) |c| {
        try w.writeI32(c.x);
        try w.writeI32(c.y);
        try w.writeI32(c.z);
        try w.writeU16(c.mass);
    }
    return w.written();
}

test "water set body round-trips the stock layout" {
    var buf: [64]u8 = undefined;
    // Every coordinate is distinct, so swapping any two of the three i32
    // writes (or the matching reads) fails here. Sharing y between entries
    // would let an x/y swap through.
    const changes = [_]WaterSetChange{
        .{ .x = 10, .y = 70, .z = -4, .mass = water_mass_full },
        .{ .x = 11, .y = 71, .z = -5, .mass = 0 },
    };
    const body = try buildWaterSetBody(&buf, 107, &changes);
    // i32 sender + u16 count + 2 x (3 x i32 + u16)
    try std.testing.expectEqual(@as(usize, 4 + 2 + 2 * 14), body.len);
    var out: [4]WaterSetChange = undefined;
    const got = try parseWaterSet(body, &out);
    try std.testing.expectEqual(@as(i32, 107), got.sender);
    try std.testing.expectEqual(@as(usize, 2), got.n);
    try std.testing.expectEqual(@as(i32, 10), out[0].x);
    try std.testing.expectEqual(@as(i32, 70), out[0].y);
    try std.testing.expectEqual(@as(i32, -4), out[0].z);
    try std.testing.expectEqual(water_mass_full, out[0].mass);
    try std.testing.expectEqual(@as(i32, 11), out[1].x);
    try std.testing.expectEqual(@as(i32, 71), out[1].y);
    try std.testing.expectEqual(@as(i32, -5), out[1].z);
    try std.testing.expectEqual(@as(u16, 0), out[1].mass);

    // A count larger than the body is a truncation error, not a short read.
    try std.testing.expectError(error.EndOfStream, parseWaterSet(body[0 .. body.len - 1], &out));
}

/// `Audio.NetPackageAudio` body: the `NetPackageEntityTargeted` base
/// (`entityId` i32, NetPackageEntityTargeted.il.txt:11) then `soundGroupName`
/// string, `play` bool, `position` as three bare f32, `playOnEntity` bool,
/// `occlusion` f32, `volumeScale` f32, `signalOnly` bool (read IL=49,
/// Audio/NetPackageAudio.il.txt:55).
pub const AudioPlay = struct {
    entity_id: i32 = 0,
    sound_group: []const u8 = "",
    play: bool = false,
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    play_on_entity: bool = false,
    occlusion: f32 = 0,
    volume_scale: f32 = 1,
    signal_only: bool = false,
};

/// Read side of the layout above (stock `Audio.NetPackageAudio::read` IL=49,
/// Audio/NetPackageAudio.il.txt:55, over the `NetPackageEntityTargeted::read`
/// base at NetPackageEntityTargeted.il.txt:11). `name_buf` receives the
/// sound-group name.
pub fn parseAudioPlay(body: []const u8, name_buf: []u8) binary.ReadError!AudioPlay {
    var r: binary.Reader = .{ .data = body };
    var out: AudioPlay = .{ .entity_id = try r.readI32() };
    out.sound_group = try r.readStringTruncating(name_buf);
    out.play = try r.readBool();
    out.x = try r.readF32();
    out.y = try r.readF32();
    out.z = try r.readF32();
    out.play_on_entity = try r.readBool();
    out.occlusion = try r.readF32();
    out.volume_scale = try r.readF32();
    out.signal_only = try r.readBool();
    return out;
}

/// Write side of the same body, for the server relay (stock
/// `Audio.NetPackageAudio::write` IL=53, Audio/NetPackageAudio.il.txt:106:
/// base write then the same field order the reader expects).
pub fn buildAudioPlayBody(buf: []u8, a: AudioPlay) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(a.entity_id);
    try w.writeString(a.sound_group);
    try w.writeBool(a.play);
    try w.writeF32(a.x);
    try w.writeF32(a.y);
    try w.writeF32(a.z);
    try w.writeBool(a.play_on_entity);
    try w.writeF32(a.occlusion);
    try w.writeF32(a.volume_scale);
    try w.writeBool(a.signal_only);
    return w.written();
}

test "audio play body round-trips the stock field order" {
    var buf: [128]u8 = undefined;
    const src: AudioPlay = .{
        .entity_id = 107,
        .sound_group = "open_door",
        .play = true,
        .x = 1.5,
        .y = 70,
        .z = -2.5,
        .play_on_entity = true,
        .occlusion = 0.25,
        .volume_scale = 0.75,
        .signal_only = false,
    };
    const body = try buildAudioPlayBody(&buf, src);
    var name_buf: [64]u8 = undefined;
    const got = try parseAudioPlay(body, &name_buf);
    try std.testing.expectEqual(@as(i32, 107), got.entity_id);
    try std.testing.expectEqualStrings("open_door", got.sound_group);
    try std.testing.expect(got.play);
    // Assert every f32, not just z: occlusion and volume_scale are adjacent
    // same-width fields, and x/y went unchecked, so a swap among them would
    // otherwise pass.
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), got.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 70), got.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -2.5), got.z, 0.001);
    try std.testing.expect(got.play_on_entity);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), got.occlusion, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), got.volume_scale, 0.001);
    try std.testing.expect(!got.signal_only);

    try std.testing.expectError(error.EndOfStream, parseAudioPlay(body[0 .. body.len - 1], &name_buf));
}

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

fn readBlockChangeInfo(r: *binary.Reader) binary.ReadError!BlockChange {
    var ch: BlockChange = .{};
    const ref_type = try r.readByte();
    if (ref_type == 1) {
        ch.x = try r.readI32();
        ch.y = try r.readI32();
        ch.z = try r.readI32();
        ch.has_pos = true;
    } else if (ref_type == 2) {
        // PropRef: two i32 + optional: rare; skip as opaque u64 if present fails soft
        return error.EndOfStream;
    } else if (ref_type != 0) {
        return error.EndOfStream;
    }
    _ = try r.readI32(); // changedByEntityId
    const flags = try r.readByte();
    // Unknown flag bits carry fields we do not consume; continuing would leave
    // the reader desynced and decode the rest of the batch as bogus edits.
    if ((flags & ~block_change_flags_known) != 0) return error.EndOfStream;
    if ((flags & block_change_flag_value) != 0) {
        const raw = try r.readU32();
        ch.raw = raw;
        ch.block_id = @intCast(raw & block_type_mask);
        ch.damage = try r.readU16();
        ch.has_value = true;
    }
    // density sbyte
    if ((flags & block_change_flag_density) != 0) _ = try r.readByte();
    // texture: TextureFullArray.Read(br, 1): typically one u64 when present.
    // Short stream must error, not silently succeed: later changes in the
    // batch would decode from a desynced offset as bogus world edits.
    if ((flags & block_change_flag_texture) != 0) _ = try r.readU64();
    return ch;
}

/// Stock `NetPackage.get_Channel` override set: bulk world data rides envelope
/// channel 1 so it does not sit in the same queue as control traffic.
/// `NetPackage::get_Channel` returns 0 (IL=2) and exactly four packages
/// override it to 1, each `get_Channel() IL=2` returning `ldc.i4.1`:
/// NetPackageChunk, NetPackageChunkRemove, NetPackageDynamicMesh,
/// NetPackageMapChunks and NetPackageWorldFolder (RE network.md "Second
/// envelope stream ... 5 packages";
/// `il/netpackages-v3.2.0/NetPackageWorldFolder_il.txt` IL_0000 = ldc.i4.1).
/// WorldFolder was missing here until 2026-09-06; zdtd never emits it, so
/// nothing was mis-sent, but the channel would have been wrong on the first
/// send.
///
/// `NetPackagePOIMetadataResponse` is deliberately absent. Its 3.1.0
/// predecessor `NetPackagePOIAround` did override to 1
/// (`il/full-v3.1.0/_global/NetPackagePOIAround.il.txt`), but the 3.2.0
/// replacement declares no `get_Channel` at all
/// (`il/full-v3.2.0/_global/NetPackagePOIMetadataResponse.il.txt`, base
/// NetPackage, no intermediate class), so it inherits channel 0. zdtd carried
/// the old channel across the package swap until 2026-09-04.
pub fn channelFor(name: []const u8) u8 {
    if (std.mem.eql(u8, name, "NetPackageChunk") or
        std.mem.eql(u8, name, "NetPackageChunkRemove") or
        std.mem.eql(u8, name, "NetPackageDynamicMesh") or
        std.mem.eql(u8, name, "NetPackageMapChunks") or
        std.mem.eql(u8, name, "NetPackageWorldFolder")) return 1;
    return 0;
}

pub fn framed(buf: []u8, name: []const u8, body: []const u8) ![]u8 {
    const id = idOf(name) orelse return error.UnknownPackage;
    return frame.framePackage(buf, channelFor(name), id, body);
}

test "only the five stock get_Channel overrides ride channel 1" {
    // Nothing tested this: dropping every override to 0 left the suite green.
    // The set is the packages whose `get_Channel() IL=2` returns ldc.i4.1;
    // `NetPackage::get_Channel` returns 0 for everything else.
    //
    // WorldFolder was missing here until 2026-09-06. The RE names five
    // (network.md "Second envelope stream ... 5 packages") and
    // `il/netpackages-v3.2.0/NetPackageWorldFolder_il.txt` IL_0000 is
    // `ldc.i4.1`; the test asserted "four" and so pinned the omission in
    // place. zdtd never emits WorldFolder, so nothing was mis-sent, but the
    // channel would have been wrong the moment it did.
    const on_one = [_][]const u8{
        "NetPackageChunk",
        "NetPackageChunkRemove",
        "NetPackageDynamicMesh",
        "NetPackageMapChunks",
        "NetPackageWorldFolder",
    };
    for (on_one) |n| try std.testing.expectEqual(@as(u8, 1), channelFor(n));

    // Every other advertised package inherits 0. Checking the whole table
    // rather than a sample is what catches a name added to the override set
    // without an IL override behind it - which is how POIMetadataResponse got
    // there, inherited from its removed 3.1.0 predecessor POIAround.
    for (default_mappings) |n| {
        var overridden = false;
        for (on_one) |o| {
            if (std.mem.eql(u8, n, o)) overridden = true;
        }
        if (overridden) continue;
        try std.testing.expectEqual(@as(u8, 0), channelFor(n));
    }
}

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

/// NetPackageWorldTime (RE inventories/netpackage-bodies.md, write IL=8): a
/// single `worldTime` u64, encoded as WorldClock.worldTimeBits (24000 per day,
/// 1000 per hour).
pub fn buildWorldTimeBody(buf: []u8, world_time: u64) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeU64(world_time);
    return w.written();
}

/// Empty last-batch NetPackageSignDataResponse: isLastBatch:bool + dataLen:i32(+bytes).
/// Client RequestWorldSignDataFromServer waits until isLastBatch clears downloadInProgress.
pub fn buildSignDataResponseEmptyLast(buf: []u8) ![]u8 {
    var wr: binary.Writer = .{ .buf = buf };
    try wr.writeBool(true); // isLastBatch
    try wr.writeI32(0); // data length
    return wr.written();
}

/// Empty NetPackageWorldInitInfo: eventPrefabCount:i32 + wallVolumeCount:i32.
/// Sets GameManager.worldInitInfoReceived so worldInfoCo can proceed to DoSpawn.
pub fn buildWorldInitInfoEmpty(buf: []u8) ![]u8 {
    var wr: binary.Writer = .{ .buf = buf };
    try wr.writeI32(0); // eventPrefabs
    try wr.writeI32(0); // wallVolumes
    return wr.written();
}

/// Stock NetPackageWorldInfo body (matches NetPackageWorldInfo.read/write IL):
/// gameMode, levelName, gameName, guid, hasPpList, [ppList], ticks:u64, fixedSizeCC,
/// firstTimeJoin, worldHashes raw (count:i32 + entries), worldDataSize:i64.
/// `name` is used for both levelName and gameName.
pub fn buildWorldInfoBody(buf: []u8, name: []const u8, w: i32, h: i32, sx: i32, sy: i32, sz: i32, seed: i32) ![]u8 {
    _ = w;
    _ = h;
    _ = sx;
    _ = sy;
    _ = sz;
    _ = seed;
    var wr: binary.Writer = .{ .buf = buf };
    try wr.writeString("GameModeSurvival"); // gameMode class name
    try wr.writeString(name); // levelName (e.g. Navezgane)
    try wr.writeString(name); // gameName
    try wr.writeString("00000000-0000-0000-0000-000000000001"); // guid
    try wr.writeBool(false); // no PersistentPlayerList blob
    try wr.writeU64(0); // ticks
    // fixedSizeCC MUST be false for stock maps (Navezgane): true installs
    // ChunkProviderDummy on the client (no splat maps). MicroSplat then samples
    // null _CustomControl0/1 and the whole terrain floor is grey clay.
    // false → GenerateWorldFromRaw(bClientMode) loads splat*.png from GameData.
    // Spawn overlay waits for CGO >= viewDist^2-10; keep stream ring large enough.
    // Design: docs/adr/0016-fixedsizecc-false-stream-cgo.md
    try wr.writeBool(false);
    // firstTimeJoin=false. GameManager.DoSpawn feeds this straight into
    // XUiC_SpawnSelectionWindow::Open(ui, bChooseSpawnPosition, bEnteringGame,
    // bFirstTimeSpawn) (V3.1.0 b14 IL: DoSpawn IL_0021, Open IL_0024). With
    // true the client parks on the spawn-selection window: the world renders
    // behind it, but the local player is never added to the world, so
    // EntityAlive.OnAddedToWorld never runs, IsSpawned stays false and the
    // client never sends EntityPosAndRot (server saw pos=(?,?,?) forever).
    try wr.writeBool(false); // firstTimeJoin
    // worldHashesData is raw MemoryStream of: count:i32 + (path:string, crc:u32)*count
    // PrepareWorldHashes writes count=0 when no RWG file CRC table.
    try wr.writeI32(0);
    try wr.writeI64(0); // worldDataSize
    return wr.written();
}

/// One `NetPackageWorldFolder` part (write IL=30): seqNr:i32, totalParts:i32,
/// dataLen:i32 (-1 when null), then data bytes. Channel 1. The client's
/// ProcessPackage appends each part to ReceiveStream and, on the last
/// (seqNr == totalParts - 1), runs uncompressWorld.
pub fn buildWorldFolderPartBody(buf: []u8, seq: i32, total: i32, data: []const u8) ![]u8 {
    var wr: binary.Writer = .{ .buf = buf };
    try wr.writeI32(seq);
    try wr.writeI32(total);
    try wr.writeI32(@intCast(data.len));
    try wr.writeBytes(data);
    return wr.written();
}

/// Empty world-folder transfer: one part carrying a zlib-deflated
/// `fileCount:i32 = 0` blob. RE: `NetPackageWorldFolder.write` IL=30,
/// `ProcessPackage` IL=93, `sendPacketsToClient` IL=84 and
/// `uncompressWorld` coroutine IL=321
/// (`../7dtd-engine-research/docs/network/protocol-packages.md` "World-folder").
/// Stock's prepareWorldFolderData streams real world files; zdtd's
/// flat/default worlds have nothing to ship (WorldInfo already advertised
/// hashCount=0), but worldInfoCo still calls RequestWorld when no local world
/// matches, and that coroutine waits on WorldReceivedAndUncompressed. An
/// empty last-part clears the wait the same way a zero-file zip would
/// (uncompressWorld: count=0 loop, write completed marker, set the flag).
pub fn buildEmptyWorldFolderTransfer(buf: []u8) ![]u8 {
    const flate = std.compress.flate;
    var plain: [4]u8 = undefined;
    std.mem.writeInt(i32, &plain, 0, .little);
    var window: [flate.max_window_len]u8 = undefined;
    var out_scratch: [64]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&out_scratch);
    // Stock DeflateOutputStream (prepareWorldFolderData) is zlib-wrapped;
    // the client DeflateInputStream expects the same container.
    var comp = flate.Compress.init(&sink, &window, .zlib, .default) catch return error.Overflow;
    comp.writer.writeAll(&plain) catch return error.Overflow;
    comp.finish() catch return error.Overflow;
    return buildWorldFolderPartBody(buf, 0, 1, out_scratch[0..sink.end]);
}

/// Stock NetPackageChunkClusterInfo body (NetPackageChunkClusterInfo.write
/// IL=36): name:string, cMinPos:2xi32, cMaxPos:2xi32, bInfinite:bool,
/// pos:Vector3 (3xf32). Server fills from `Setup(ChunkCluster)`: name =
/// GamePrefs.GameWorld, cMin/cMax = WorldChunkCache.ChunkMinPos/MaxPos,
/// bInfinite = !IsFixedSize, pos = ChunkCluster.Position. The client
/// (GameManager.ChunkClusterInfo -> chunkClusterInfoCo, V3.1.0 b14) stores
/// pos/min/max on its ChunkCache, and only when bInfinite=false sets
/// IsFixedSize and calls the (no-op in b14) border-box methods; `name` is
/// never read client-side. Fixed maps send the ChunkProviderDisc bounds
/// formula; infinite worlds keep the WorldChunkCache ctor defaults (0,0).
pub fn buildChunkClusterInfoBody(buf: []u8, name: []const u8, cmin: [2]i32, cmax: [2]i32, b_infinite: bool, pos: [3]f32) ![]u8 {
    var wr: binary.Writer = .{ .buf = buf };
    try wr.writeString(name);
    try wr.writeI32(cmin[0]);
    try wr.writeI32(cmin[1]);
    try wr.writeI32(cmax[0]);
    try wr.writeI32(cmax[1]);
    try wr.writeBool(b_infinite);
    try wr.writeF32(pos[0]);
    try wr.writeF32(pos[1]);
    try wr.writeF32(pos[2]);
    return wr.written();
}

test "chunk cluster info body layout" {
    var buf: [64]u8 = undefined;
    const body = try buildChunkClusterInfoBody(&buf, "Navezgane", .{ -195, -198 }, .{ 195, 195 }, false, .{ 0, 0, 0 });
    var rd: binary.Reader = .{ .data = body };
    var name_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Navezgane", try rd.readString(&name_buf));
    try std.testing.expectEqual(@as(i32, -195), try rd.readI32());
    try std.testing.expectEqual(@as(i32, -198), try rd.readI32());
    try std.testing.expectEqual(@as(i32, 195), try rd.readI32());
    try std.testing.expectEqual(@as(i32, 195), try rd.readI32());
    try std.testing.expectEqual(false, try rd.readBool());
    try std.testing.expectEqual(@as(f32, 0), try rd.readF32());
    try std.testing.expectEqual(@as(f32, 0), try rd.readF32());
    try std.testing.expectEqual(@as(f32, 0), try rd.readF32());
    try std.testing.expectEqual(@as(usize, body.len), rd.pos);
}

test "world info body layout ends with hashCount0 and worldDataSize" {
    var buf: [256]u8 = undefined;
    const body = try buildWorldInfoBody(&buf, "Navezgane", 6144, 6144, 0, 0, 0, 0);
    // last 12 bytes: i32 0 + i64 0
    try std.testing.expect(body.len >= 12);
    const tail = body[body.len - 12 ..];
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, tail[0..4], .little));
    try std.testing.expectEqual(@as(i64, 0), std.mem.readInt(i64, tail[4..12], .little));
}

test "empty world folder transfer is one last part with zlib payload" {
    var buf: [128]u8 = undefined;
    const body = try buildEmptyWorldFolderTransfer(&buf);
    var rd: binary.Reader = .{ .data = body };
    try std.testing.expectEqual(@as(i32, 0), try rd.readI32()); // seqNr
    try std.testing.expectEqual(@as(i32, 1), try rd.readI32()); // totalParts (last = seq 0)
    const len = try rd.readI32();
    try std.testing.expect(len > 0);
    try std.testing.expectEqual(@as(usize, @intCast(len)), body.len - rd.pos);
    // zlib header: CMF=0x78
    try std.testing.expectEqual(@as(u8, 0x78), body[rd.pos]);
    try std.testing.expectEqual(@as(u8, 1), channelFor("NetPackageWorldFolder"));
}

test "sign data empty last batch is bool true + len0" {
    var buf: [16]u8 = undefined;
    const body = try buildSignDataResponseEmptyLast(&buf);
    try std.testing.expectEqual(@as(usize, 5), body.len);
    try std.testing.expectEqual(@as(u8, 1), body[0]);
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, body[1..5], .little));
}

test "world init info empty is two zero counts" {
    var buf: [16]u8 = undefined;
    const body = try buildWorldInitInfoEmpty(&buf);
    try std.testing.expectEqual(@as(usize, 8), body.len);
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, body[0..4], .little));
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, body[4..8], .little));
}

/// Stock NetPackageEntityStatChanged/EnumStat (nested enum).
pub const EntityStatKind = enum(u8) {
    health = 0,
    stamina = 1,
    sickness = 2,
    gassiness = 3,
    speed_modifier = 4,
    wellness = 5,
    core_temp_old = 6,
    food = 7,
    water = 8,
};

/// Stock body after channel pkgId (NetPackageEntityTargeted + StatChanged fields):
/// entityId:i32 | instigatorId:i32 | enumStat:u8 | value:f32 | max:f32 | maxModifier:f32
pub fn buildEntityStatChangedBody(
    buf: []u8,
    entity_id: i32,
    instigator_id: i32,
    kind: EntityStatKind,
    value: f32,
    max: f32,
    max_modifier: f32,
) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeI32(instigator_id);
    try w.writeByte(@intFromEnum(kind));
    try w.writeF32(value);
    try w.writeF32(max);
    try w.writeF32(max_modifier);
    return w.written();
}

/// Stock NetPackageEntityAwardKillServer body (read IL=9): EntityId:i32 (the
/// killer) | KilledEntityId:i32. Sent by `GameManager.AwardKill` (IL=27) to a
/// remote killer so its client fires the local EntityKill event that kill
/// challenges subscribe to.
pub fn buildAwardKillBody(buf: []u8, killer_id: i32, killed_id: i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(killer_id);
    try w.writeI32(killed_id);
    return w.written();
}

/// Stock NetPackageSetAttackTarget body (read IL=8, GetLength 8):
/// entityId:i32 (the NetPackageEntityTargeted base) | targetId:i32. The
/// client feeds it to `EntityAlive::SetAttackTargetClient`, which backs
/// `GetAttackTargetLocal` for remote entities (drone beam targeting and the
/// DynamicMusic threat level read it). `target_id` is -1 for "no target",
/// which is what stock sends when the attack-target window expires
/// (EntityAlive::OnUpdateLive) as well as on an explicit clear.
pub fn buildSetAttackTargetBody(buf: []u8, entity_id: i32, target_id: i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeI32(target_id);
    return w.written();
}

/// Stock NetPackageEntityStealth body (write IL=12): id:i32 | data:u16.
///
/// The three `Setup` overloads pack `data` three mutually exclusive ways, and
/// none of them combines the crouch flag with the light/noise payload:
///   - `Setup(player, isCrouching)` sets data to exactly 0 or 1 (IL=13, :9).
///   - `Setup(local, smellRadius, eating, sheltered)` is the smell form,
///     tagged with bit 1 and routed server-side (IL=36, :24).
///   - `Setup(player, lightLevel, noiseVolume, isAlert)` packs
///     `(byte)lightLevel | ((noise & 127) << 8)`, plus bit 15 for alert
///     (IL=26, :62). This is the one PlayerStealth.TickServer broadcasts.
/// The client branch reads `light = (byte)data`, so the light level owns the
/// whole low byte (ProcessPackage IL_009F-00A5). ORing a crouch bit into the
/// light form would land inside that byte and report light+1.
pub fn buildEntityStealthBody(
    buf: []u8,
    entity_id: i32,
    light_level: u8,
    noise_volume: u8,
    is_alert: bool,
) ![]u8 {
    var data: u16 = @as(u16, light_level) | (@as(u16, noise_volume & 127) << 8);
    if (is_alert) data |= 32768;
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeU16(data);
    return w.written();
}

/// The crouch-only `Setup(player, isCrouching)` form (IL=13): data is the bare
/// flag, never combined with the light/noise payload.
pub fn buildEntityStealthCrouchBody(buf: []u8, entity_id: i32, is_crouching: bool) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeU16(if (is_crouching) 1 else 0);
    return w.written();
}

test "entity stealth body packs the stock data bits" {
    var buf: [16]u8 = undefined;
    const body = try buildEntityStealthBody(&buf, 107, 5, 90, true);
    try std.testing.expectEqual(@as(usize, 6), body.len);
    try std.testing.expectEqual(@as(i32, 107), std.mem.readInt(i32, body[0..4], .little));
    const data = std.mem.readInt(u16, body[4..6], .little);
    try std.testing.expectEqual(@as(u16, 5), data & 0xff); // light
    try std.testing.expectEqual(@as(u16, 90), (data >> 8) & 127); // noise
    try std.testing.expect(data & 32768 != 0); // alert
}

test "stealth light owns the whole low byte" {
    // The client reads light as (byte)data, so an odd light value must not be
    // confusable with the crouch form: light 5 stays 5, never 4 or 5|crouch.
    var buf: [16]u8 = undefined;
    for ([_]u8{ 0, 1, 2, 3, 5, 127, 254, 255 }) |light| {
        const body = try buildEntityStealthBody(&buf, 107, light, 0, false);
        const data = std.mem.readInt(u16, body[4..6], .little);
        try std.testing.expectEqual(@as(u16, light), data & 0xff);
    }
}

test "crouch stealth body is the bare flag form" {
    var buf: [16]u8 = undefined;
    const on = try buildEntityStealthCrouchBody(&buf, 107, true);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, on[4..6], .little));
    var buf2: [16]u8 = undefined;
    const off = try buildEntityStealthCrouchBody(&buf2, 107, false);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, off[4..6], .little));
}

test "entity stat changed body size" {
    var buf: [32]u8 = undefined;
    // value and max were both 100 and maxModifier 0, so the three trailing
    // floats were two duplicates and a zero: a swap among them emitted the
    // same bytes. Distinct values make the run observable.
    const body = try buildEntityStatChangedBody(&buf, 106, -1, .health, 75, 100, 25);
    try std.testing.expectEqual(@as(usize, 4 + 4 + 1 + 4 + 4 + 4), body.len);
    try std.testing.expectEqual(@as(i32, 106), std.mem.readInt(i32, body[0..4], .little));
    try std.testing.expectEqual(@as(i32, -1), std.mem.readInt(i32, body[4..8], .little)); // instigator
    try std.testing.expectEqual(@as(u8, 0), body[8]); // Health
    const f32At = struct {
        fn get(b: []const u8, off: usize) f32 {
            return @bitCast(std.mem.readInt(u32, b[off..][0..4], .little));
        }
    }.get;
    try std.testing.expectEqual(@as(f32, 75), f32At(body, 9)); // value
    try std.testing.expectEqual(@as(f32, 100), f32At(body, 13)); // max
    try std.testing.expectEqual(@as(f32, 25), f32At(body, 17)); // maxModifier
}

test "inventory transaction request body is the compact zdtd order" {
    // buildInvTxRequest had no test at all. It is not the stock layout (that
    // is parseStockInvTx), but it rides the stock package name for loadgen and
    // the scenarios, so its field order still has to hold: op u8 | a u16 |
    // b u16 | qty u16 | entityId i32.
    var buf: [16]u8 = undefined;
    const body = try buildInvTxRequest(&buf, 2, 11, 22, 33, 106);
    try std.testing.expectEqual(@as(usize, 11), body.len);
    try std.testing.expectEqual(@as(u8, 2), body[0]);
    try std.testing.expectEqual(@as(u16, 11), std.mem.readInt(u16, body[1..3], .little));
    try std.testing.expectEqual(@as(u16, 22), std.mem.readInt(u16, body[3..5], .little));
    try std.testing.expectEqual(@as(u16, 33), std.mem.readInt(u16, body[5..7], .little));
    try std.testing.expectEqual(@as(i32, 106), std.mem.readInt(i32, body[7..11], .little));
    // The parser must agree field for field, not just on the length.
    const p = try parseInvTxRequest(body);
    try std.testing.expectEqual(@as(u8, 2), p.op);
    try std.testing.expectEqual(@as(u16, 11), p.a);
    try std.testing.expectEqual(@as(u16, 22), p.b);
    try std.testing.expectEqual(@as(u16, 33), p.qty);
    try std.testing.expectEqual(@as(i32, 106), p.entity_id);
}

/// Stock-compatible player inventory body (NetPackagePlayerInventory.write fields).
pub fn buildInventoryBodyStock(buf: []u8, inv: *const components.Inventory) ![]u8 {
    return stock_inv.buildFromEcs(buf, inv);
}

/// NetPackagePlayerInventory (RE protocol-packages.md 5.4, write IL=107):
/// `toolbelt` present bool (+ ItemStack[] if set) | `bag` present bool
/// (+ Bag.Write) | `equipment` present bool (+ Equipment: ItemValue array, one
/// cosmetic i32 per slot, then the unlockedCosmetics count) | `dragAndDropItem`
/// present bool (+ ItemStack). The body-inventory table shows the cosmetics
/// list as a top-level field; the narrative places it inside the equipment
/// block, which is where stock_inv.writeEquipment puts it.
pub fn buildInventoryBodyStockResolved(
    buf: []u8,
    inv: *const components.Inventory,
    resolve: ?stock_inv.TypeResolver,
    ctx: ?*anyopaque,
) ![]u8 {
    return stock_inv.buildFromEcsResolved(buf, inv, resolve, ctx);
}

/// NetPackageIdMapping body: name string + i32 len + bytes, matching
/// `NetPackageIdMapping::write` (IL=18: `Write(String)`, `Write(Int32)`,
/// `Write(Byte[])`) and its read (IL=13: `ReadString`, `ReadInt32`,
/// `ReadBytes`).
pub fn buildIdMappingBody(buf: []u8, name: []const u8, data: []const u8) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeString(name);
    try w.writeI32(@intCast(data.len));
    try w.writeBytes(data);
    return w.written();
}

/// One `(stock type id, name)` row of a NameIdMapping payload, in
/// `NameIdMapping::SaveToWriter` order (IL=72: per entry `Write(Int32)` the id
/// then `Write(String)` the name).
pub const IdMappingEntry = struct { id: i32, name: []const u8 };

/// NameIdMapping payload: version i32 (1) | count i32 | per entry id i32 +
/// name string. The count is written after the rows because stock backfills it
/// the same way (`SaveToWriter` seeks back to the reserved slot, IL=72).
/// Returns the payload for `buildIdMappingBody` to wrap.
pub fn buildNameIdMappingPayload(buf: []u8, entries: []const IdMappingEntry) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(1); // version
    const count_pos = w.pos;
    try w.writeI32(0);
    var n: i32 = 0;
    for (entries) |e| {
        try w.writeI32(e.id);
        try w.writeString(e.name);
        n += 1;
    }
    std.mem.writeInt(i32, buf[count_pos..][0..4], n, .little);
    return w.written();
}

/// NetPackageHoldingItem (RE inventories/netpackage-bodies.md, write IL=16):
/// `entityId` i32 | `holdingItemStack` (ItemStack.Write) | `holdingItemIndex`
/// u8. Body written by stock_inv.writeHoldingItem.
pub fn buildHoldingBodyResolved(
    buf: []u8,
    entity_id: i32,
    inv: *const components.Inventory,
    resolve: ?stock_inv.TypeResolver,
    ctx: ?*anyopaque,
) ![]u8 {
    return stock_inv.buildHoldingFromEcsResolved(buf, entity_id, inv, resolve, ctx);
}

/// zdtd's own compact transaction request: op:u8 | a:u16 | b:u16 | qty:u16 |
/// entity_id:i32. **Not the stock body.** Stock writes
/// `InventoryTransaction.Write` (RE inventories/netpackage-bodies.md, Write
/// IL=75): a nested op list (count | count | Key Vector3i | InitialHash i32 |
/// FinalHash i32 | Ops count | InventoryOperation.Write each). The C2S handler
/// tries the stock layout first and only falls back to this one
/// (`c2s/inv.zig`, parseStockInvTx), so a real client is served the stock
/// shape; this compact form exists for scenarios driving the same handler
/// without building a full stock transaction. It is never sent to a client.
pub fn buildInvTxRequest(buf: []u8, op: u8, a: u16, b: u16, qty: u16, entity_id: i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeByte(op);
    try w.writeU16(a);
    try w.writeU16(b);
    try w.writeU16(qty);
    try w.writeI32(entity_id);
    return w.written();
}

/// Read side of buildInvTxRequest and likewise **not the stock body**: op u8 |
/// a u16 | b u16 | qty u16 | entityId i32. The stock layout is
/// InventoryTransaction.Write (RE inventories/netpackage-bodies.md, Write
/// IL=75), decoded by parseStockInvTx. The C2S handler tries the stock form
/// first and only falls back here (c2s/inv.zig), so a real client never
/// reaches this parser; it exists for the zdtd tools and fixtures that write
/// the compact form.
pub fn parseInvTxRequest(body: []const u8) !struct { op: u8, a: u16, b: u16, qty: u16, entity_id: i32 } {
    if (body.len < 11) return error.EndOfStream;
    var r: binary.Reader = .{ .data = body };
    return .{
        .op = try r.readByte(),
        .a = try r.readU16(),
        .b = try r.readU16(),
        .qty = try r.readU16(),
        .entity_id = try r.readI32(),
    };
}

/// zdtd's compact transaction response head, the counterpart to
/// buildInvTxRequest and likewise **not the stock body**: ok u8 |
/// dropped_entity i32, then an optional inventory snapshot the caller appends.
/// Stock's NetPackageInventoryTransactionResponse (RE write IL=66) is
/// inventories bool | i32 | success bool | keys count | Vector3i | bool.
pub fn buildInvTxResponseHead(buf: []u8, ok: bool, dropped_entity: i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeByte(@intFromBool(ok));
    try w.writeI32(dropped_entity);
    return w.written();
}

/// Legacy container data request: entity_id i32. **Not the stock body**, which
/// is `KeyHashPair` + `managerToken` Guid (RE inventories/netpackage-bodies.md
/// NetPackageInventoryDataRequest, write IL=12) and is decoded by
/// parseInvDataRequestStock. The C2S handler tries the stock form first
/// (c2s/inv.zig), so this serves loadgen and the older zdtd path only.
pub fn parseInvDataRequest(body: []const u8) !i32 {
    if (body.len < 4) return error.EndOfStream;
    return std.mem.readInt(i32, body[0..4], .little);
}

/// Stock NetPackageInventoryDataRequest: Guid inventoryKey | i32 hash | Guid managerToken.
pub const InvDataRequestStock = struct {
    inventory_key: [16]u8,
    hash: i32,
    manager_token: [16]u8,
};

/// Read side of the stock NetPackageInventoryDataRequest (RE
/// inventories/netpackage-bodies.md, write IL=12): `keyHash`
/// (KeyHashPair.Write, itself Guid `Key` + i32 `Hash`, Write IL=9) |
/// `managerToken` Guid. Both Guids are carried opaquely: the server matches the
/// key and echoes the token back on the response, so their internal layout is
/// never interpreted here.
pub fn parseInvDataRequestStock(body: []const u8) !InvDataRequestStock {
    // 16 + 4 + 16 = 36
    if (body.len < 36) return error.EndOfStream;
    var key: [16]u8 = undefined;
    var tok: [16]u8 = undefined;
    @memcpy(&key, body[0..16]);
    const hash = std.mem.readInt(i32, body[16..20], .little);
    @memcpy(&tok, body[20..36]);
    return .{ .inventory_key = key, .hash = hash, .manager_token = tok };
}

/// Stock NetPackageInventoryDataResponse for unknown key:
/// success=false | error string | inventoryKey | ItemStack[] null (i16 -1) | managerToken
pub fn buildInvDataResponseNotFound(buf: []u8, inventory_key: [16]u8, manager_token: [16]u8) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeBool(false);
    try w.writeString("inventory not found");
    try w.writeBytes(&inventory_key);
    // ItemStack.WriteArray(null) → i16 -1
    try w.writeI16(-1);
    try w.writeBytes(&manager_token);
    return w.written();
}

/// NetPackageInventoryDataResponse (RE protocol-packages.md, write IL=24 /
/// Process IL=30): `success` bool | `errorMsg` string | `inventoryKey` Guid |
/// `ItemStack[]` (i16 count + ItemStack.Write each) | `managerToken` Guid.
/// The body-inventory table omits the stack array; the narrative row and the
/// client's UpdateInventory(items, managerToken) both have it, so the array
/// sits between key and token. This is the hash-miss / full-sync path; the
/// hash-hit path writes count -1 for a null list (Request Process IL=92 step 3).
pub fn buildInvDataResponseItems(
    buf: []u8,
    inventory_key: [16]u8,
    manager_token: [16]u8,
    slots: []const stock_inv.StockSlot,
) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeBool(true);
    try w.writeString(""); // empty error
    try w.writeBytes(&inventory_key);
    // ItemStack.WriteArray: i16 count + ItemStack.Write * n
    const n: i16 = @intCast(@min(slots.len, 32767));
    try w.writeI16(n);
    var i: usize = 0;
    while (i < @as(usize, @intCast(n))) : (i += 1) {
        try stock_inv.writeItemStack(&w, slots[i]);
    }
    try w.writeBytes(&manager_token);
    return w.written();
}

/// Stock NetPackageLockRequest body (after package id):
/// locking:bool | channel:u16 | targetCount:i32 | targets… | contextType:string | context?
pub const LockRequestHead = struct {
    locking: bool,
    channel: u16,
    /// Declared target span length. Stock's `LockRequestServer` gate 2
    /// (IL=239) refuses more than `max_lock_targets_declared`, but the deny
    /// response echoes the request's targets, so the parser walks the span and
    /// the C2S handler owns the rule.
    target_count: i32,
    /// True when any target entry is null (`WriteIdentifyingInfo` writes a
    /// `false` presence byte and nothing else). Stock's gate 2 rejects a span
    /// containing a null target with the same deny as an over-long span.
    has_null_target: bool,
    /// Slice of request body covering targetCount i32 + target identifying blobs (not context).
    targets_blob: []const u8,
    /// Remaining body after targets (context type string + optional payload).
    context_tail: []const u8,
};

/// Walk one target's identifying info, returning false for a null target (the
/// presence byte was 0).
fn skipLockTargetIdent(r: *binary.Reader) binary.ReadError!bool {
    const present = try r.readByte();
    if (present == 0) return false;
    const ty = try r.readByte();
    switch (ty) {
        0 => { // TileEntity → Vector3i
            _ = try r.readI32();
            _ = try r.readI32();
            _ = try r.readI32();
        },
        1 => { // TEFeatureAbs → Vector3i + feature name
            _ = try r.readI32();
            _ = try r.readI32();
            _ = try r.readI32();
            try r.skipString();
        },
        2 => { // Entity → entityId
            _ = try r.readI32();
        },
        3 => { // TransactionalInventory → Guid
            if (r.remaining() < 16) return error.EndOfStream;
            r.pos += 16;
        },
        else => return error.EndOfStream,
    }
    return true;
}

/// Stock's hard cap on a lock request's target span. `LockRequestServer` gate 2
/// (IL=239, RE dedicated-leftovers.md:136) refuses a span longer than 5. The
/// refusal still produces a reply: the failure sets `errorMsg` and falls
/// through to the `NetPackageLockResponse` send with `success = false`
/// (IL_0263), so the C2S handler owns this rule and must answer with a deny.
/// The constant previously held 32 with a comment claiming the limit was
/// undocumented, which accepted requests stock rejects.
pub const max_lock_targets_declared: i32 = 5;

/// Parse-time work bound on the declared target count, deliberately above the
/// stock rule above: the parser has to walk the span even for a request the
/// server will refuse, because the deny response echoes the request's targets.
/// A count past this bound is malformed rather than merely over-limit.
const max_lock_targets_parseable: i32 = 64;

/// NetPackageLockRequest (RE write IL=74; the response in buildLockResponseGrant
/// echoes these fields): `locking` bool | `channel` u16 | target count i32 |
/// targets | `context` string. On success returns a head with slices into `body`.
pub fn parseLockRequest(body: []const u8) binary.ReadError!LockRequestHead {
    var r: binary.Reader = .{ .data = body };
    const locking = try r.readBool();
    const channel = try r.readU16();
    const count_pos = r.pos;
    const count = try r.readI32();
    if (count < 0 or count > max_lock_targets_parseable) return error.EndOfStream;
    var has_null_target = false;
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        if (!try skipLockTargetIdent(&r)) has_null_target = true;
    }
    const targets_end = r.pos;
    // remainder is context
    return .{
        .locking = locking,
        .channel = channel,
        .target_count = count,
        .has_null_target = has_null_target,
        .targets_blob = body[count_pos..targets_end],
        .context_tail = body[targets_end..],
    };
}

/// NetPackageLockResponse granting the lock (RE inventories/netpackage-bodies.md,
/// write IL=74): `locking` bool | `success` bool | `errorMsg` string |
/// `isForceUnlocked` bool | `channel` u16 | `targets` | `context` string. The
/// targets and context are echoed verbatim from the request, which is what
/// keeps the client's pending lock correlated.
pub fn buildLockResponseGrant(buf: []u8, req: LockRequestHead) ![]u8 {
    return buildLockResponse(buf, req, true, "");
}

/// NetPackageLockResponse denying the lock, held by another peer or a busy
/// channel (RE write IL=74; field order in buildLockResponseGrant).
pub fn buildLockResponseDeny(buf: []u8, req: LockRequestHead, err_msg: []const u8) ![]u8 {
    return buildLockResponse(buf, req, false, err_msg);
}

fn buildLockResponse(buf: []u8, req: LockRequestHead, success: bool, err_msg: []const u8) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeBool(req.locking);
    try w.writeBool(success);
    try w.writeString(err_msg);
    try w.writeBool(false); // isForceUnlocked
    try w.writeU16(req.channel);
    try w.writeBytes(req.targets_blob);
    if (req.context_tail.len > 0) {
        try w.writeBytes(req.context_tail);
    } else {
        try w.writeString("");
    }
    return w.written();
}

/// NetPackageLockResponse forcing a held lock open (RE write IL=74; field order
/// in `buildLockResponseGrant`). `locking = false` selects the client's
/// `LockManager.UnlockResponse(success, errorMsg, isForceUnlocked)` branch
/// (ProcessPackage IL=27), which reads neither the targets nor the context - so
/// this needs only the channel, and the server does not have to have kept the
/// original request's target blob. Stock sends the same thing from
/// `ForceUnlockByPlayer` (IL=11) on disconnect cleanup and after a failed
/// inventory transaction.
pub fn buildLockResponseForceUnlock(buf: []u8, channel: u16) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeBool(false); // locking = false -> UnlockResponse branch
    try w.writeBool(true); // success
    try w.writeString("");
    try w.writeBool(true); // isForceUnlocked
    try w.writeU16(channel);
    try w.writeI32(0); // no targets: the unlock branch never reads them
    try w.writeString("");
    return w.written();
}

test "force-unlock lock response selects the unlock branch" {
    // The two directions are different client calls (ProcessPackage IL=27), so
    // `locking` is what routes it; a grant-shaped body with success=true would
    // re-open the window instead of closing it.
    var buf: [64]u8 = undefined;
    const body = try buildLockResponseForceUnlock(&buf, 3);
    var r: binary.Reader = .{ .data = body };
    try std.testing.expectEqual(false, try r.readBool()); // locking
    try std.testing.expectEqual(true, try r.readBool()); // success
    var s: [8]u8 = undefined;
    try std.testing.expectEqualStrings("", try r.readString(&s));
    try std.testing.expectEqual(true, try r.readBool()); // isForceUnlocked
    try std.testing.expectEqual(@as(u16, 3), try r.readU16());
    try std.testing.expectEqual(@as(i32, 0), try r.readI32()); // target count
    try std.testing.expectEqualStrings("", try r.readString(&s));
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

/// Grant a lock whose target is a trader. Stock serializes the target's lock
/// context into the LockResponse, and the two trader-ish contexts do **not**
/// share a layout:
///   - `EntityTraderLockContext::Read` (EntityTrader_EntityTraderLockContext
///     .il.txt:38): `Command` string, `hasTraderData` bool, then TraderData
///     only when that bool is set.
///   - `VendingMachineLockContext::Read` (TileEntityVendingMachine_Vending
///     MachineLockContext.il.txt:19): TraderData **directly**, with no command
///     and no bool.
/// Emitting the entity shape for a vending machine hands the client two extra
/// bytes (the empty command's length and the bool) which it reads as the first
/// half of `TraderID`, desyncing the rest of the body.
/// NetPackageTraderData is ToServer-only, so this is the packet that carries
/// trader inventory to the opening client.
pub fn buildLockResponseTrader(buf: []u8, req: LockRequestHead, td: stock_entity.TraderDataInfo) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    // Type name + Command from the request context tail (empty-safe fallbacks).
    // Separate buffers: the second readString must not clobber the first.
    var type_buf: [64]u8 = undefined;
    var cmd_buf: [64]u8 = undefined;
    var r: binary.Reader = .{ .data = req.context_tail };
    const type_name = if (req.context_tail.len > 0)
        r.readString(&type_buf) catch "EntityTraderLockContext"
    else
        "EntityTraderLockContext";
    const command = if (r.pos < req.context_tail.len)
        (r.readString(&cmd_buf) catch "")
    else
        "";
    try w.writeBool(req.locking);
    try w.writeBool(true); // success
    try w.writeString(""); // error
    try w.writeBool(false); // isForceUnlocked
    try w.writeU16(req.channel);
    try w.writeBytes(req.targets_blob);
    try w.writeString(type_name);
    // VendingMachineLockContext has neither field; only the entity context
    // carries Command + hasTraderData ahead of the TraderData.
    if (!std.mem.eql(u8, type_name, vending_lock_context)) {
        try w.writeString(command);
        try w.writeBool(true); // hasTraderData
    }
    try stock_entity.writeTraderDataBody(&w, td);
    return w.written();
}

/// Stock type name for the vending-machine lock context, the discriminator the
/// client uses to pick which context `Read` runs.
pub const vending_lock_context = "VendingMachineLockContext";

/// Unlock response (locking=false path on client ProcessPackage).
/// NetPackageLockResponse for an unlock (RE write IL=74; field order in
/// buildLockResponseGrant). locking=false with an empty target list.
pub fn buildLockResponseUnlock(buf: []u8, success: bool) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeBool(false); // locking
    try w.writeBool(success);
    try w.writeString("");
    try w.writeBool(false); // isForceUnlocked
    // The tail is written even though an unlock carries nothing in it:
    // omitting it would desync the reader's BinaryReader rather than save
    // bytes. The RE body table lists nine fields, but the last two (target
    // `FullName`, `ILockContext.Write`) sit behind the same two null guards as
    // LockRequest (protocol-packages.md residual table): the per-target info
    // is written only for a non-null target list, and the context payload only
    // for a non-null context. An empty list and an empty context type name are
    // therefore the complete stock encoding of "nothing locked".
    try w.writeU16(0); // channel
    try w.writeI32(0); // targets: empty list
    try w.writeString(""); // context type name (empty = null context)
    return w.written();
}

test "lock request span cap is the handler's rule, not the parser's" {
    // Stock LockRequestServer gate 2 (IL=239) refuses a span longer than 5 and
    // still replies with a deny that echoes the request's targets (IL_0263), so
    // the parser must walk an over-limit span far enough for the C2S handler to
    // answer it. Rejecting at parse time silently dropped the request, which
    // left the client's pending lock unresolved.
    const buildTargets = struct {
        fn call(w: *binary.Writer, n: i32) !void {
            try w.writeBool(true);
            try w.writeU16(0);
            try w.writeI32(n);
            var i: i32 = 0;
            while (i < n) : (i += 1) {
                try w.writeByte(1); // present
                try w.writeByte(1); // TEFeatureAbs
                try w.writeI32(i);
                try w.writeI32(70);
                try w.writeI32(2);
                try w.writeString("Storage");
            }
            try w.writeString("");
        }
    }.call;

    // The literal 5 is the point of the test: deriving the bounds from the
    // constant would pass for any value it happens to hold, which is exactly
    // what let the old 32 sit here unnoticed.
    try std.testing.expectEqual(@as(i32, 5), max_lock_targets_declared);

    var over_buf: [1024]u8 = undefined;
    var over_w: binary.Writer = .{ .buf = &over_buf };
    try buildTargets(&over_w, 6);
    const over = try parseLockRequest(over_w.written());
    try std.testing.expectEqual(@as(i32, 6), over.target_count);
    try std.testing.expect(!over.has_null_target);
    // The whole span is walked, so the deny response can echo it. The blob
    // starts after locking (1) + channel (2).
    try std.testing.expectEqual(over_w.written().len, 3 + over.targets_blob.len + over.context_tail.len);

    // A null target is gate 2's other reject; the parser reports it rather than
    // pretending the span was well formed.
    var null_buf: [64]u8 = undefined;
    var null_w: binary.Writer = .{ .buf = &null_buf };
    try null_w.writeBool(true);
    try null_w.writeU16(0);
    try null_w.writeI32(1);
    try null_w.writeByte(0); // present = 0 -> null target
    try null_w.writeString("");
    const nul = try parseLockRequest(null_w.written());
    try std.testing.expect(nul.has_null_target);

    // Past the parse bound the body is malformed, not merely over-limit.
    var huge_buf: [2048]u8 = undefined;
    var huge_w: binary.Writer = .{ .buf = &huge_buf };
    try buildTargets(&huge_w, max_lock_targets_parseable + 1);
    try std.testing.expectError(error.EndOfStream, parseLockRequest(huge_w.written()));
}

test "lock request grant response layout" {
    // locking=true, channel=0, 1 TEFeatureAbs target at (1,70,2) name=Storage, empty context
    var req: [64]u8 = undefined;
    var w: binary.Writer = .{ .buf = &req };
    try w.writeBool(true);
    try w.writeU16(0);
    try w.writeI32(1);
    try w.writeByte(1); // present
    try w.writeByte(1); // TEFeatureAbs
    try w.writeI32(1);
    try w.writeI32(70);
    try w.writeI32(2);
    try w.writeString("Storage");
    try w.writeString(""); // no context type
    const head = try parseLockRequest(w.written());
    try std.testing.expect(head.locking);
    try std.testing.expectEqual(@as(u16, 0), head.channel);

    var resp_buf: [128]u8 = undefined;
    const resp = try buildLockResponseGrant(&resp_buf, head);
    try std.testing.expectEqual(@as(u8, 1), resp[0]); // locking
    try std.testing.expectEqual(@as(u8, 1), resp[1]); // success

    // Only those two bytes were checked. The rest is locking | success |
    // errorMsg | isForceUnlocked | channel | targets | context, and the deny
    // path had no test at all - it differs from grant only in the success bit
    // and the message, which is exactly the pair a swap would hide.
    var r: binary.Reader = .{ .data = resp };
    var s_buf: [64]u8 = undefined;
    try std.testing.expectEqual(true, try r.readBool()); // locking
    try std.testing.expectEqual(true, try r.readBool()); // success
    try std.testing.expectEqualStrings("", try r.readString(&s_buf)); // errorMsg
    try std.testing.expectEqual(false, try r.readBool()); // isForceUnlocked
    try std.testing.expectEqual(@as(u16, 0), try r.readU16()); // channel
    // targets_blob is echoed verbatim: count 1 then the one target entry.
    try std.testing.expectEqual(@as(i32, 1), try r.readI32());

    var deny_buf: [128]u8 = undefined;
    const deny = try buildLockResponseDeny(&deny_buf, head, "busy");
    var dr: binary.Reader = .{ .data = deny };
    try std.testing.expectEqual(true, try dr.readBool()); // locking echoed
    try std.testing.expectEqual(false, try dr.readBool()); // success cleared
    try std.testing.expectEqualStrings("busy", try dr.readString(&s_buf));
    try std.testing.expectEqual(false, try dr.readBool()); // isForceUnlocked
    try std.testing.expectEqual(@as(u16, 0), try dr.readU16()); // channel
}

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

/// Stock NetPackageChunkRemove: chunkKey i64 (WorldChunkCache.MakeChunkKey).
pub fn buildChunkRemoveBody(buf: []u8, cx: i32, cz: i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI64(makeChunkKey(cx, cz));
    return w.written();
}

/// Read side of NetPackageChunkRemove: one `chunkKey` i64, the key
/// buildChunkRemoveBody writes. The coordinates come back out through the same
/// WorldChunkCache.MakeChunkKey packing, so any i64 decodes to some chunk and
/// the range check belongs at the caller, not here.
pub fn parseChunkRemoveBody(body: []const u8) !struct { cx: i32, cz: i32 } {
    if (body.len < 8) return error.EndOfStream;
    const key = std.mem.readInt(i64, body[0..8], .little);
    return .{ .cx = extractChunkKeyX(key), .cz = extractChunkKeyZ(key) };
}

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

/// GameUtils/EKickReason (asm.il:1913681-1913720). Only the values zdtd emits:
/// an operator `kick` and a server-side guard-policy decision. zdtd has no EAC
/// integration, so the Eac* reasons are never sent.
pub const KickReason = enum(i32) {
    /// EKickReason.ManualKick (10), RE `protocol-packages.md` "EKickReason";
    /// stock also uses it for a platform-blocked enter.
    manual_kick = 0x0A,
    /// 16. **Name and client-facing string unverified.** The RE records 35
    /// values and names ten of them; 16 is in range but is not one of the
    /// named ones, and no retained dump carries the full enum, so what a
    /// stock client renders for it is unknown. Only the guard-policy kick
    /// (`game/guard.zig`) sends it, and that call fills the custom reason
    /// string, which is what an operator actually reads. Re-derive the label
    /// from a fresh enum dump before relying on it.
    mod_decision = 0x10,
    /// EKickReason.VersionMismatch (asm.il GameUtils_EKickReason): the
    /// client's compatibilityVersion differs from LongStringNoBuild.
    version_mismatch = 4,
    /// EKickReason.PlayerLimitExceeded: the server is full (AuthorizationManager).
    player_limit_exceeded = 5,
    /// EKickReason.Banned: the source identity/IP is banned.
    banned = 6,
    /// EKickReason.NotOnWhitelist: the identity is not on the (enabled)
    /// whitelist and is not an admin (BansAndWhitelistAuthorizer, IL=71).
    not_on_whitelist = 7,
};

/// Stock NetPackagePlayerDenied body (asm.il:827055-827090):
///   i32 reason | i32 apiResponseEnum | i64 banUntil (DateTime.ToBinary) |
///   string customReason (BinaryWriter 7-bit length prefix).
/// The u16 package id belongs to the base `NetPackage::write`
/// (asm.il:800444-800456), which `frame.framePackage` already emits, so it must
/// NOT be repeated here. `banUntil = 0` is stock's default `initobj DateTime`
/// (asm.il:1918620-1918630), i.e. a kick with no ban.
pub fn buildPlayerDeniedBody(
    buf: []u8,
    reason: KickReason,
    api_response: i32,
    ban_until_binary: i64,
    custom_reason: []const u8,
) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(@intFromEnum(reason));
    try w.writeI32(api_response);
    try w.writeI64(ban_until_binary);
    try w.writeString(custom_reason);
    return w.written();
}

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

/// NetPackageConsoleCmdServer body = one .NET string (the command). Returns it
/// in `buf` (caller-owned). Empty on malformed.
pub fn parseConsoleCmd(body: []const u8, buf: []u8) []const u8 {
    var r: binary.Reader = .{ .data = body };
    return r.readString(buf) catch "";
}

/// NetPackageConsoleCmdClient body = i32 lineCount + lineCount .NET strings +
/// bool bExecute. Server sends command output back to the console.
pub fn buildConsoleCmdClient(buf: []u8, lines: []const []const u8, b_execute: bool) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(@intCast(lines.len));
    for (lines) |ln| try w.writeString(ln);
    try w.writeBool(b_execute);
    return w.written();
}

/// NetPackageChat body (RE chat.md §1): chatType u8 (EChatType: 0 Global,
/// 1 Friends, 2 Party, 3 Whisper, 4 Discord), senderEntityId i32, msg string,
/// msgSender u8, bbMode u8, recipientEntityIds (i32 count + ids). The
/// recipient list is the routing key: ChatMessageServer sends only to those
/// clients when non-empty, else broadcasts (chat.md §2).
pub const StockChat = struct {
    chat_type: u8,
    sender: i32,
    msg: []const u8,
    msg_sender: u8 = 0,
    bb_mode: u8 = 0,
    /// Party/friends/whisper recipients (≤ 8, the party cap).
    recipients: [8]i32 = .{-1} ** 8,
    recipient_count: u8 = 0,
};

/// NetPackageChat (RE inventories/netpackage-bodies.md, write IL=63):
/// `chatType` u8 | `senderEntityId` i32 | `msg` string | `msgSender` u8
/// (EMessageSender) | `bbMode` u8 (BbCodeSupportMode) | `recipientEntityIds`
/// count i32 | count x i32. An empty recipient list means every peer.
pub fn buildStockChat(buf: []u8, chat_type: u8, sender_entity_id: i32, msg: []const u8, recipients: []const i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeByte(chat_type);
    try w.writeI32(sender_entity_id);
    try w.writeString(msg);
    try w.writeByte(0); // EMessageSender
    try w.writeByte(0); // BbCodeSupportMode
    try w.writeI32(@intCast(recipients.len));
    for (recipients) |rid| try w.writeI32(rid);
    return w.written();
}

/// NetPackageChat, read side (RE write IL=63; same field order as
/// buildStockChat): `chatType` u8 | `senderEntityId` i32 | `msg` string |
/// `msgSender` u8 | `bbMode` u8 | recipient count i32 | count x i32.
pub fn parseStockChat(body: []const u8) !StockChat {
    if (body.len < 6) return error.EndOfStream;
    var r: binary.Reader = .{ .data = body };
    const chat_type = try r.readByte();
    const sender = try r.readI32();
    // Zero-copy message slice into `body` (no caller buffer). Overlong length
    // prefix maps Overflow → InvalidString to match string reader contract.
    const len_u = binary.read7BitEncodedInt(&r) catch |err| switch (err) {
        error.Overflow => return error.InvalidString,
        else => |e| return e,
    };
    const len: usize = len_u;
    if (r.pos + len > body.len) return error.EndOfStream;
    const msg = body[r.pos .. r.pos + len];
    r.pos += len;
    var out = StockChat{ .chat_type = chat_type, .sender = sender, .msg = msg };
    out.msg_sender = try r.readByte();
    out.bb_mode = try r.readByte();
    const count = try r.readI32();
    if (count > 0) {
        if (count > out.recipients.len) return error.Overflow; // forged list
        var i: usize = 0;
        while (i < @as(usize, @intCast(count))) : (i += 1) {
            out.recipients[i] = try r.readI32();
        }
        out.recipient_count = @intCast(count);
    }
    return out;
}

/// Stock `NetPackageSoundAtPosition` (write IL=25, read IL=21): pos Vector3
/// (3xf32) | audioClipName string | mode u8 (UnityEngine.AudioRolloffMode
/// Logarithmic=0/Linear=1/Custom=2) | distance i32 | entityId i32. The
/// dedicated-server relay (GameManager PlaySoundAtPositionServer IL=60)
/// re-broadcasts Setup(...) with allButAttachedToEntityId = entityId, so
/// every client except the owning player hears the sound (the owner already
/// played it locally); the `distance` field drives the receiving client's
/// rolloff, not the fan-out. Note: `volumeScale` is a Setup-only field that
/// stock never puts on the wire (write stops after entityId, read stops
/// after entityId; the client-side receiver gets the field default 0) - it
/// is kept on the struct for API symmetry but must not be encoded/decoded.
pub const SoundAtPosition = struct {
    pos: [3]f32,
    clip: [max_audio_clip_len]u8 = .{0} ** max_audio_clip_len,
    clip_len: u8 = 0,
    mode: u8 = 0,
    distance: i32 = 0,
    entity_id: i32 = 0,
    volume_scale: f32 = 0,
    /// End of the stock body. The clip string makes the length variable, so a
    /// relay must forward `body[0..wire_len]` rather than the raw slice.
    wire_len: usize = 0,

    pub fn clipSlice(self: *const SoundAtPosition) []const u8 {
        return self.clip[0..self.clip_len];
    }
};

/// Audio clip names are short asset paths; anything longer fails closed.
pub const max_audio_clip_len: usize = 256;

/// Read side of NetPackageSoundAtPosition (RE write IL=25): pos Vector3 | clip
/// string | `mode` u8 | `distance` i32 | `entityId` i32, the order
/// buildSoundAtPosition writes and where stock's write also stops.
///
/// `volume_scale` therefore never comes off the wire; it stays at its default
/// and only the local relay path sets it. The clip string is the one
/// client-controlled length in the body, so it is capped rather than trusted.
pub fn parseSoundAtPosition(body: []const u8) (binary.ReadError || error{Overflow})!SoundAtPosition {
    if (body.len < 22) return error.EndOfStream; // 12 pos + 1 clip-len + 1 mode + 4 + 4
    var r: binary.Reader = .{ .data = body };
    var out: SoundAtPosition = .{
        .pos = .{ try r.readF32(), try r.readF32(), try r.readF32() },
    };
    var clip_buf: [max_audio_clip_len]u8 = undefined;
    const clip = try r.readString(&clip_buf);
    // clip_len is a u8, so the cap itself does not fit: readString accepts a
    // length equal to the buffer, and >= (not >) is what keeps the cast below
    // in range. A joined client controls this length.
    if (clip.len >= max_audio_clip_len) return error.Overflow;
    @memcpy(out.clip[0..clip.len], clip);
    out.clip_len = @intCast(clip.len);
    out.mode = try r.readByte();
    out.distance = try r.readI32();
    out.entity_id = try r.readI32();
    out.wire_len = r.pos;
    return out;
}

/// Encode the stock body (write IL=25): pos Vector3 | clip string | mode u8 |
/// distance i32 | entityId i32. Server-initiated sounds carry entityId -1
/// (the dedicated relay's allButAttachedToEntityId). volumeScale is never
/// encoded: stock's write stops after entityId (see SoundAtPosition note).
pub fn buildSoundAtPosition(buf: []u8, s: SoundAtPosition) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeF32(s.pos[0]);
    try w.writeF32(s.pos[1]);
    try w.writeF32(s.pos[2]);
    try w.writeString(s.clipSlice());
    try w.writeByte(s.mode);
    try w.writeI32(s.distance);
    try w.writeI32(s.entity_id);
    return w.written();
}

test "sound at position parses the stock 5-field body" {
    // write IL=25 / read IL=21: pos 3xf32 | clip string | mode u8 | distance
    // i32 | entityId i32. volumeScale is Setup-only and never on the wire.
    var body: [128]u8 = undefined;
    var w: binary.Writer = .{ .buf = &body };
    // pos[1] is 64.75, not 0: with a zero there a swap with either neighbour
    // emitted bytes the assertions could not tell apart.
    try w.writeF32(100.5);
    try w.writeF32(64.75);
    try w.writeF32(-50.25);
    try w.writeString("Sounds/explosions/boom");
    try w.writeByte(1); // Linear
    try w.writeI32(30);
    try w.writeI32(42);
    const s = try parseSoundAtPosition(w.written());
    try std.testing.expectApproxEqAbs(@as(f32, 100.5), s.pos[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -50.25), s.pos[2], 0.001);
    try std.testing.expectEqualStrings("Sounds/explosions/boom", s.clipSlice());
    try std.testing.expectEqual(@as(u8, 1), s.mode);
    try std.testing.expectEqual(@as(i32, 30), s.distance);
    try std.testing.expectEqual(@as(i32, 42), s.entity_id);
    try std.testing.expectEqual(@as(f32, 0), s.volume_scale); // Setup-only default

    // A trailing volumeScale byte is not part of the wire: the parser stops
    // after entityId and the builder emits exactly 5 fields (a stock client
    // reader would desync on a 6-field body).
    // Separate buffer: `body` is the parsed input and `s` slices into it, so
    // building into it would overwrite the very values being written.
    var out_buf: [128]u8 = undefined;
    const built = try buildSoundAtPosition(&out_buf, s);
    // Values, not just the field count: this block only checked that the body
    // ends after five fields, so a reordering inside the builder would hide
    // behind a parser that moved with it. pos[1] also had to stop being 0.
    const f32At = struct {
        fn get(b: []const u8, off: usize) f32 {
            return @bitCast(std.mem.readInt(u32, b[off..][0..4], .little));
        }
    }.get;
    try std.testing.expectEqual(@as(f32, 100.5), f32At(built, 0));
    try std.testing.expectEqual(@as(f32, 64.75), f32At(built, 4));
    try std.testing.expectEqual(@as(f32, -50.25), f32At(built, 8));
    var br: binary.Reader = .{ .data = built };
    _ = try br.readF32();
    _ = try br.readF32();
    _ = try br.readF32();
    var nb: [64]u8 = undefined;
    _ = try br.readString(&nb);
    _ = try br.readByte();
    _ = try br.readI32();
    _ = try br.readI32();
    try std.testing.expectError(error.EndOfStream, br.readF32()); // no 6th field
}

test "a clip name at the cap fails closed instead of trapping the cast" {
    // clip_len is u8 while max_audio_clip_len is 256, and readString accepts a
    // length equal to the buffer, so a clip of exactly 256 bytes reached
    // @intCast(256) -> u8 and panicked. Any joined client can send this
    // package, so the cast has to be unreachable, not merely unlikely.
    var body: [512]u8 = undefined;
    var w: binary.Writer = .{ .buf = &body };
    try w.writeF32(1);
    try w.writeF32(2);
    try w.writeF32(3);
    const long = [_]u8{'a'} ** max_audio_clip_len;
    try w.writeString(&long);
    try w.writeByte(1);
    try w.writeI32(30);
    try w.writeI32(42);
    try std.testing.expectError(error.Overflow, parseSoundAtPosition(w.written()));

    // One byte under the cap still parses, so the rejection is about the cap
    // itself and not a broken length path.
    var body2: [512]u8 = undefined;
    var w2: binary.Writer = .{ .buf = &body2 };
    try w2.writeF32(1);
    try w2.writeF32(2);
    try w2.writeF32(3);
    try w2.writeString(long[0 .. max_audio_clip_len - 1]);
    try w2.writeByte(1);
    try w2.writeI32(30);
    try w2.writeI32(42);
    const ok = try parseSoundAtPosition(w2.written());
    try std.testing.expectEqual(@as(usize, max_audio_clip_len - 1), ok.clipSlice().len);
}

/// Stock `NetPackageParticleEffect` (write IL=20): a `ParticleEffect`
/// (ParticleEffect.Write IL=47: ParticleId i32, pos Vector3 3xf32, rot
/// Quaternion 4xf32, color Color32 4 bytes, soundName string,
/// additionalHitSoundName string, volumeScale f32) followed by
/// entityThatCausedIt i32, forceCreation bool, worldSpawn bool. The
/// dedicated-server relay (GameManager.SpawnParticleEffectServer IL=41)
/// re-broadcasts Setup(...) with allButAttachedToEntityId =
/// entityThatCausedIt, so every client except the causing entity's owner
/// sees the effect (the owner already spawned it locally).
pub const ParticleEffectInvoke = struct {
    entity_caused: i32,
    force_creation: bool,
    world_spawn: bool,
    /// End of the stock body. The two sound-name strings make the length
    /// variable, so a relay must forward `body[0..wire_len]`.
    wire_len: usize = 0,
};

/// NetPackageParticleEffect (write IL=20, NetPackageParticleEffect.il.txt:43):
/// `pe` (ParticleEffect::Write) | `entityThatCausedIt` i32 | `forceCreation`
/// bool | `worldSpawn` bool.
///
/// `ParticleEffect::Write` (ParticleEffect.il.txt:397-435) ends with
/// `parentEntityId` i32 and `attachment` u8 after volumeScale. Those five
/// bytes are part of the effect, not the package tail: reading the package's
/// own i32 too early took `parentEntityId` as `entityThatCausedIt` and then
/// derived both bools from the attachment byte and the real causing id.
pub fn parseParticleEffectInvoke(body: []const u8) (binary.ReadError || error{Overflow})!ParticleEffectInvoke {
    var r: binary.Reader = .{ .data = body };
    _ = try r.readI32(); // ParticleId
    var i: usize = 0;
    while (i < 3) : (i += 1) _ = try r.readF32(); // pos
    i = 0;
    while (i < 4) : (i += 1) _ = try r.readF32(); // rot (Quaternion)
    i = 0;
    while (i < 4) : (i += 1) _ = try r.readByte(); // color (Color32)
    var scratch: [128]u8 = undefined;
    _ = try r.readString(&scratch); // soundName
    _ = try r.readString(&scratch); // additionalHitSoundName
    _ = try r.readF32(); // volumeScale
    _ = try r.readI32(); // ParticleEffect.parentEntityId
    _ = try r.readByte(); // ParticleEffect.attachment
    var out: ParticleEffectInvoke = .{
        .entity_caused = try r.readI32(),
        .force_creation = try r.readBool(),
        .world_spawn = try r.readBool(),
    };
    out.wire_len = r.pos;
    return out;
}

test "particle effect invoke parses the stock body" {
    var body: [256]u8 = undefined;
    var w: binary.Writer = .{ .buf = &body };
    try w.writeI32(7); // ParticleId
    try w.writeF32(1);
    try w.writeF32(2);
    try w.writeF32(3);
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(1);
    try w.writeByte(255);
    try w.writeByte(0);
    try w.writeByte(0);
    try w.writeByte(255);
    try w.writeString("Sounds/blood");
    try w.writeString("");
    try w.writeF32(1); // volumeScale
    // ParticleEffect::Write ends here, with two fields the package tail sits
    // behind. Distinct values so reading them as the tail cannot pass.
    try w.writeI32(999); // ParticleEffect.parentEntityId
    try w.writeByte(3); // ParticleEffect.attachment
    try w.writeI32(42); // entityThatCausedIt
    try w.writeBool(true); // forceCreation
    try w.writeBool(false); // worldSpawn
    const pe = try parseParticleEffectInvoke(w.written());
    try std.testing.expectEqual(@as(i32, 42), pe.entity_caused);
    try std.testing.expect(pe.force_creation);
    try std.testing.expect(!pe.world_spawn);
}

test "stock chat round-trips channel, sender, message and recipients" {
    var buf: [128]u8 = undefined;
    const recips = [_]i32{ 20, 30 };
    const body = try buildStockChat(&buf, 2, 10, "hello party", &recips); // EChatType.Party
    const ch = try parseStockChat(body);
    try std.testing.expectEqual(@as(u8, 2), ch.chat_type);
    try std.testing.expectEqual(@as(i32, 10), ch.sender);
    try std.testing.expectEqualStrings("hello party", ch.msg);
    try std.testing.expectEqual(@as(u8, 2), ch.recipient_count);
    try std.testing.expectEqual(@as(i32, 20), ch.recipients[0]);
    try std.testing.expectEqual(@as(i32, 30), ch.recipients[1]);
}

test "stock chat global has no recipients and rejects a forged oversized list" {
    var buf: [128]u8 = undefined;
    const body = try buildStockChat(&buf, 0, 10, "global", &.{});
    const ch = try parseStockChat(body);
    try std.testing.expectEqual(@as(u8, 0), ch.chat_type);
    try std.testing.expectEqual(@as(u8, 0), ch.recipient_count);
    // 9 recipients > the 8 cap is rejected, not truncated.
    var w = binary.Writer{ .buf = &buf };
    try w.writeByte(0);
    try w.writeI32(10);
    try w.writeString("x");
    try w.writeByte(0);
    try w.writeByte(0);
    try w.writeI32(9);
    var i: usize = 0;
    while (i < 9) : (i += 1) try w.writeI32(@intCast(100 + i));
    try std.testing.expectError(error.Overflow, parseStockChat(w.written()));
}

/// NetPackageEntityAttach: attachType u8 | riderId i32 | vehicleId i32 | slot i16
pub const AttachType = enum(u8) {
    attach_server = 0,
    attach_client = 1,
    detach_server = 2,
    detach_client = 3,
};

/// "Any free seat" on the wire. The stock client mounts with -1 and detaches
/// with vehicleId = -1 / slot = -1 (asm.il:541872, asm.il:406816).
pub const slot_any: i16 = -1;

/// NetPackageEntityAttach (RE inventories/netpackage-bodies.md, write IL=21):
/// `attachType` u8 | `riderId` i32 | `vehicleId` i32 | `slot` i16. Slot is an
/// int32 in memory but conv.i2 on the wire (asm.il:844620).
pub fn buildEntityAttach(buf: []u8, attach_type: AttachType, rider_id: i32, vehicle_id: i32, slot: i16) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeByte(@intFromEnum(attach_type));
    try w.writeI32(rider_id);
    try w.writeI32(vehicle_id);
    try w.writeI16(slot);
    return w.written();
}

/// Read side of NetPackageEntityAttach (RE inventories/netpackage-bodies.md,
/// write IL=21): `attachType` u8 | `riderId` i32 | `vehicleId` i32 | `slot`
/// i16, the order buildEntityAttach writes. An `attachType` outside the four
/// stock values is rejected rather than clamped: stock switches on it, so a
/// fifth value has no defined meaning and guessing one would attach or detach
/// on a byte the client never meant as either.
pub fn parseEntityAttach(body: []const u8) !struct { attach_type: AttachType, rider_id: i32, vehicle_id: i32, slot: i16 } {
    if (body.len < 11) return error.EndOfStream;
    const at_raw = body[0];
    const at = std.enums.fromInt(AttachType, at_raw) orelse return error.InvalidEvent;
    return .{
        .attach_type = at,
        .rider_id = std.mem.readInt(i32, body[1..5], .little),
        .vehicle_id = std.mem.readInt(i32, body[5..9], .little),
        .slot = std.mem.readInt(i16, body[9..11], .little),
    };
}

pub fn attachTypeIsDetach(t: AttachType) bool {
    return t == .detach_server or t == .detach_client;
}

pub const SpawnPointEntry = stock_entity.SpawnPointEntry;

/// NetPackageWorldSpawnPoints body = SpawnPointList.Write (one stock shape).
/// Per-point payload = 26 bytes (stock GetLength lies with count*20).
pub fn buildWorldSpawnPoints(buf: []u8, points: []const stock_entity.SpawnPointEntry) ![]u8 {
    return stock_entity.buildWorldSpawnPointsBody(buf, points);
}

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

/// One trader compound for NetPackageWorldAreas: position/size/protect
/// padding plus the prefab's teleport volumes (local cells).
pub const TraderTeleport = struct {
    start_x: i8 = 0,
    start_y: i8 = 0,
    start_z: i8 = 0,
    size_x: u8 = 0,
    size_y: u8 = 0,
    size_z: u8 = 0,
};

pub const TraderAreaEntry = struct {
    pos_x: i32 = 0,
    pos_y: i32 = 0,
    pos_z: i32 = 0,
    size_x: i16 = 0,
    size_y: i16 = 0,
    size_z: i16 = 0,
    /// GetProtectPadding: (TraderAreaProtect - 2) in x/z, y unchanged.
    pad_x: i8 = 0,
    pad_y: i8 = 0,
    pad_z: i8 = 0,
    teleports: []const TraderTeleport = &.{},
};

/// NetPackageWorldAreas body: byte cVersion=1, i16 count, TraderArea.Write
/// each (Position i32x3, PrefabSize i16x3, GetProtectPadding s8x3, teleport
/// volumes u8 count + startPos s8x3 / size u8x3). Layout from
/// NetPackageWorldAreas::write IL=31 and TraderArea::Write IL=111
/// (../7dtd-engine-research il dump, docs/loot-economy.md:435).
pub fn buildWorldAreasBody(buf: []u8, areas: []const TraderAreaEntry) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeByte(1); // cVersion
    try w.writeI16(@intCast(areas.len));
    for (areas) |a| {
        try w.writeI32(a.pos_x);
        try w.writeI32(a.pos_y);
        try w.writeI32(a.pos_z);
        try w.writeI16(a.size_x);
        try w.writeI16(a.size_y);
        try w.writeI16(a.size_z);
        try w.writeByte(@bitCast(a.pad_x));
        try w.writeByte(@bitCast(a.pad_y));
        try w.writeByte(@bitCast(a.pad_z));
        try w.writeByte(@intCast(a.teleports.len));
        for (a.teleports) |t| {
            try w.writeByte(@bitCast(t.start_x));
            try w.writeByte(@bitCast(t.start_y));
            try w.writeByte(@bitCast(t.start_z));
            try w.writeByte(t.size_x);
            try w.writeByte(t.size_y);
            try w.writeByte(t.size_z);
        }
    }
    return w.written();
}

test "world areas stock wire" {
    var buf: [256]u8 = undefined;
    const body = try buildWorldAreasBody(&buf, &[_]TraderAreaEntry{
        .{
            .pos_x = 10,
            .pos_y = 61,
            .pos_z = 20,
            // size_x and size_z were both 60, which made that swap emit
            // identical bytes; the audit reported it as a survivor.
            .size_x = 60,
            .size_y = 28,
            .size_z = 62,
            // pad_x and pad_z were both -2, which made that swap emit
            // identical bytes.
            .pad_x = -2,
            .pad_y = 0,
            .pad_z = -3,
            .teleports = &.{
                .{ .start_x = 7, .start_y = 1, .start_z = 2, .size_x = 52, .size_y = 12, .size_z = 5 },
                .{ .start_x = 2, .start_y = 1, .start_z = 7, .size_x = 57, .size_y = 28, .size_z = 41 },
            },
        },
    });
    // 1 + 2 + (12 + 6 + 3 + 1 + 2*6)
    try std.testing.expectEqual(@as(usize, 1 + 2 + 34), body.len);
    try std.testing.expectEqual(@as(u8, 1), body[0]); // cVersion
    try std.testing.expectEqual(@as(i16, 1), std.mem.readInt(i16, body[1..3], .little));
    // Whole position and size triples: only pos_x and size_x were read, so
    // pos_y/pos_z and size_y/size_z could swap unnoticed.
    try std.testing.expectEqual(@as(i32, 10), std.mem.readInt(i32, body[3..7], .little));
    try std.testing.expectEqual(@as(i32, 61), std.mem.readInt(i32, body[7..11], .little));
    try std.testing.expectEqual(@as(i32, 20), std.mem.readInt(i32, body[11..15], .little));
    try std.testing.expectEqual(@as(i16, 60), std.mem.readInt(i16, body[15..17], .little));
    try std.testing.expectEqual(@as(i16, 28), std.mem.readInt(i16, body[17..19], .little));
    try std.testing.expectEqual(@as(i16, 62), std.mem.readInt(i16, body[19..21], .little));
    // The padding triple and both teleport triples, not just their first
    // component: pad_y/pad_z, start_y/start_z and size_y/size_z each had
    // nothing reading them back and could swap unnoticed.
    try std.testing.expectEqual(@as(i8, -2), @as(i8, @bitCast(body[21]))); // pad_x
    try std.testing.expectEqual(@as(i8, 0), @as(i8, @bitCast(body[22]))); // pad_y
    try std.testing.expectEqual(@as(i8, -3), @as(i8, @bitCast(body[23]))); // pad_z
    try std.testing.expectEqual(@as(u8, 2), body[24]); // teleport count
    try std.testing.expectEqual(@as(i8, 7), @as(i8, @bitCast(body[25]))); // vol0 start_x
    try std.testing.expectEqual(@as(i8, 1), @as(i8, @bitCast(body[26]))); // vol0 start_y
    try std.testing.expectEqual(@as(i8, 2), @as(i8, @bitCast(body[27]))); // vol0 start_z
    try std.testing.expectEqual(@as(u8, 52), body[28]); // vol0 size_x
    try std.testing.expectEqual(@as(u8, 12), body[29]); // vol0 size_y
    try std.testing.expectEqual(@as(u8, 5), body[30]); // vol0 size_z
    // Second volume follows immediately, six bytes on.
    try std.testing.expectEqual(@as(i8, 2), @as(i8, @bitCast(body[31]))); // vol1 start_x
    try std.testing.expectEqual(@as(i8, 1), @as(i8, @bitCast(body[32])));
    try std.testing.expectEqual(@as(i8, 7), @as(i8, @bitCast(body[33])));
    try std.testing.expectEqual(@as(u8, 57), body[34]); // vol1 size_x
    try std.testing.expectEqual(@as(u8, 28), body[35]);
    try std.testing.expectEqual(@as(u8, 41), body[36]);
}

/// NetPackageEntityVelocity (write IL=23): entityId i32, bAdd bool, motion
/// f32 x3, clamped to [-8, 8] per axis at Setup (protocol-packages.md §5.5.5).
/// The one builder for this package: the replication path
/// (NetEntityDistributionEntry) sends live motion and the C2S hit-shove path
/// sends knockback, both through here so every peer sees the stock clamp.
pub fn buildEntityVelocityBody(buf: []u8, entity_id: i32, b_add: bool, vx: f32, vy: f32, vz: f32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeBool(b_add);
    try w.writeF32(std.math.clamp(vx, -8.0, 8.0));
    try w.writeF32(std.math.clamp(vy, -8.0, 8.0));
    try w.writeF32(std.math.clamp(vz, -8.0, 8.0));
    return w.written();
}

test "EntityVelocity body is entityId + bAdd + clamped motion" {
    var buf: [32]u8 = undefined;
    const b = try buildEntityVelocityBody(&buf, 107, false, 0, -5.5, 99.0);
    try std.testing.expectEqual(@as(usize, 4 + 1 + 12), b.len);
    try std.testing.expectEqual(@as(i32, 107), std.mem.readInt(i32, b[0..4], .little));
    try std.testing.expectEqual(@as(u8, 0), b[4]); // bAdd false
    try std.testing.expectEqual(@as(f32, 0.0), @as(f32, @bitCast(std.mem.readInt(u32, b[5..9], .little))));
    try std.testing.expectEqual(@as(f32, -5.5), @as(f32, @bitCast(std.mem.readInt(u32, b[9..13], .little))));
    try std.testing.expectEqual(@as(f32, 8.0), @as(f32, @bitCast(std.mem.readInt(u32, b[13..17], .little)))); // clamped
    const add = try buildEntityVelocityBody(&buf, 1, true, 1, 0, 0);
    try std.testing.expectEqual(@as(u8, 1), add[4]);
}

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

/// NetPackageTurretSync (read IL=20 / write IL=?): entityId i32,
/// targetEntityId i32, isOn bool, ItemValue (byte 0 = None; stock writes the
/// null-safe ItemValue for the turret's weapon). Broadcast by EntityTurret
/// when the target/on/weapon state changes (RE 2026-08-21); the client aims
/// the turret at the target and plays the fire state.
pub fn buildTurretSyncBody(buf: []u8, entity_id: i32, target_id: i32, is_on: bool) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeI32(target_id);
    try w.writeBool(is_on);
    try w.writeByte(0); // ItemValue.None (no weapon item in the zdtd sim)
    return w.written();
}

test "TurretSync body is entityId + target + isOn + None item value" {
    var buf: [32]u8 = undefined;
    const b = try buildTurretSyncBody(&buf, 300, 107, true);
    try std.testing.expectEqual(@as(usize, 4 + 4 + 1 + 1), b.len);
    try std.testing.expectEqual(@as(i32, 300), std.mem.readInt(i32, b[0..4], .little));
    try std.testing.expectEqual(@as(i32, 107), std.mem.readInt(i32, b[4..8], .little));
    try std.testing.expectEqual(@as(u8, 1), b[8]);
    try std.testing.expectEqual(@as(u8, 0), b[9]); // ItemValue.None
    const off = try buildTurretSyncBody(&buf, 301, -1, false);
    try std.testing.expectEqual(@as(u8, 0), off[8]);
}

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

/// Read side of NetPackageLandClaimRepair (docs/wire/PACKAGES.md, extracted
/// read `ReadInt64;ReadInt64;ReadInt64;ReadBoolean;`): the block position
/// arrives as three i64, then `beginRepair` bool. Each coordinate is narrowed
/// to i32 and a value that does not fit is an error, since no world position
/// needs the wider type and a forged one would wrap into a valid-looking block.
pub fn parseLandClaimRepair(body: []const u8) !struct { x: i32, y: i32, z: i32, begin_repair: bool } {
    if (body.len < 25) return error.EndOfStream;
    var r: binary.Reader = .{ .data = body };
    const x = std.math.cast(i32, try r.readI64()) orelse return error.EndOfStream;
    const y = std.math.cast(i32, try r.readI64()) orelse return error.EndOfStream;
    const z = std.math.cast(i32, try r.readI64()) orelse return error.EndOfStream;
    const begin = try r.readBool();
    return .{ .x = x, .y = y, .z = z, .begin_repair = begin };
}

/// Write side of NetPackageLandClaimRepair (write IL=26): blockPosition as
/// three i64, then `beginRepair` bool. The server emits the end-repair form
/// (`Setup(blockPos, false)`) to the requester when the repair pass finishes
/// (TEFeatureAreaRepair repair coroutine IL_0337), clearing its IsRepairing.
pub fn buildLandClaimRepairBody(buf: []u8, x: i32, y: i32, z: i32, begin_repair: bool) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI64(x);
    try w.writeI64(y);
    try w.writeI64(z);
    try w.writeBool(begin_repair);
    return w.written();
}

/// `EnumMapObjectType` values used by the marker-removal package. The enum has
/// 18 entries (RE map-objects.md 90); only the ones zdtd removes are named here,
/// so an unused value cannot be cited as if it were verified.
pub const MapObjectType = enum(i32) {
    sleeping_bag = 1,
    supply_drop = 13,
    land_claim = 15,
};

/// `removeByType` selector: the entity id and the position are mutually
/// exclusive on the wire (RE protocol-packages.md 1735).
pub const map_marker_remove_by_entity: i32 = 0;
pub const map_marker_remove_by_position: i32 = 1;

/// NetPackageEntityMapMarkerRemove keyed by entity id (write IL=24, RE
/// protocol-packages.md 1735): `removeByType` i32 = 0 | `entityId` i32 |
/// `mapObjectType` i32. The client's `World.ObjectOnMapRemove` drops the marker.
pub fn buildMapMarkerRemoveByEntity(buf: []u8, entity_id: i32, object_type: MapObjectType) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(map_marker_remove_by_entity);
    try w.writeI32(entity_id);
    try w.writeI32(@intFromEnum(object_type));
    return w.written();
}

/// NetPackageEntityMapMarkerRemove keyed by position (same write IL=24, RE
/// protocol-packages.md 1735): `removeByType` i32 = 1 | `position` Vector3
/// (3 x f32) | `mapObjectType` i32. The two key forms are mutually exclusive.
/// Used where the marker belongs to something that is not an entity, which is
/// how stock removes a land-claim marker (`NetPackageEntityMapMarkerRemove(
/// EnumMapObjectType.LandClaim = 15, pos)`, RE server-lifecycle.md:292).
pub fn buildMapMarkerRemoveByPosition(buf: []u8, x: f32, y: f32, z: f32, object_type: MapObjectType) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(map_marker_remove_by_position);
    try w.writeF32(x);
    try w.writeF32(y);
    try w.writeF32(z);
    try w.writeI32(@intFromEnum(object_type));
    return w.written();
}

test "map marker remove body layout, both key forms" {
    // The two key forms are mutually exclusive on the wire: reading a
    // position-keyed body as an id-keyed one would take the first coordinate
    // word as an entity id and then run off the end.
    var buf: [32]u8 = undefined;
    const by_id = try buildMapMarkerRemoveByEntity(&buf, 106, .supply_drop);
    var r: binary.Reader = .{ .data = by_id };
    try std.testing.expectEqual(map_marker_remove_by_entity, try r.readI32());
    try std.testing.expectEqual(@as(i32, 106), try r.readI32());
    try std.testing.expectEqual(@as(i32, 13), try r.readI32());
    try std.testing.expectEqual(@as(usize, 0), r.remaining());

    var buf2: [32]u8 = undefined;
    const by_pos = try buildMapMarkerRemoveByPosition(&buf2, 10, 64, -20, .land_claim);
    var r2: binary.Reader = .{ .data = by_pos };
    try std.testing.expectEqual(map_marker_remove_by_position, try r2.readI32());
    try std.testing.expectEqual(@as(f32, 10), try r2.readF32());
    try std.testing.expectEqual(@as(f32, 64), try r2.readF32());
    try std.testing.expectEqual(@as(f32, -20), try r2.readF32());
    try std.testing.expectEqual(@as(i32, 15), try r2.readI32());
    try std.testing.expectEqual(@as(usize, 0), r2.remaining());
}

/// NetPackageNavObject add/remove map marker (quest/trader style).
/// Wire: class | name | pos | isAdd | useOverrideColor | color u32 | usingLoc bool | entityId
pub fn buildNavObjectAdd(
    buf: []u8,
    nav_class: []const u8,
    name: []const u8,
    x: f32,
    y: f32,
    z: f32,
    entity_id: i32,
) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeString(nav_class);
    try w.writeString(name);
    try w.writeF32(x);
    try w.writeF32(y);
    try w.writeF32(z);
    try w.writeBool(true); // isAdd
    try w.writeBool(false); // useOverrideColor
    try w.writeU32(0xffffffff); // Color32 white as packed ARGB-ish
    try w.writeBool(false); // usingLocalizationId
    try w.writeI32(entity_id);
    return w.written();
}

/// NetPackageNavObject remove form (Setup(Int32 _entityId) IL=20): every
/// field is still written, with an empty class/name and a zero position, and
/// isAdd = false. The client's ProcessPackage (IL=77, isAdd false branch) then
/// calls NavObjectManager.UnRegisterNavObjectByEntityID(entityId). Stock sends
/// this from AIDirectorAirDropComponent.RemoveSupplyCrate (IL=54), reached by
/// EntitySupplyCrate.OnEntityUnload (IL=17) when the unload reason is Killed;
/// EntitySupplyCrate.OnEntityDeath (IL=30) sends the parallel
/// NetPackageEntityMapMarkerRemove(SupplyDrop, entityId).
pub fn buildNavObjectRemove(buf: []u8, entity_id: i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeString(""); // navObjectClass
    try w.writeString(""); // name
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(0); // position
    try w.writeBool(false); // isAdd
    try w.writeBool(false); // useOverrideColor
    try w.writeU32(0); // overrideColor, ignored by the remove branch
    try w.writeBool(false); // usingLocalizationId
    try w.writeI32(entity_id);
    return w.written();
}

test "nav object add body layout" {
    // No test covered this builder. Two strings, then a Vector3 whose three
    // words nothing read back, then a run of flags around a packed colour.
    var buf: [128]u8 = undefined;
    const body = try buildNavObjectAdd(&buf, "quest", "Trader Jen", 11, 12, 13, 106);
    var r: binary.Reader = .{ .data = body };
    var s_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("quest", try r.readString(&s_buf));
    try std.testing.expectEqualStrings("Trader Jen", try r.readString(&s_buf));
    try std.testing.expectEqual(@as(f32, 11), try r.readF32());
    try std.testing.expectEqual(@as(f32, 12), try r.readF32());
    try std.testing.expectEqual(@as(f32, 13), try r.readF32());
    try std.testing.expectEqual(true, try r.readBool()); // isAdd
    try std.testing.expectEqual(false, try r.readBool()); // useOverrideColor
    try std.testing.expectEqual(@as(u32, 0xffffffff), try r.readU32()); // colour
    try std.testing.expectEqual(false, try r.readBool()); // usingLocalizationId
    try std.testing.expectEqual(@as(i32, 106), try r.readI32());
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

test "nav object remove body is the same shape with isAdd clear" {
    // The stock remove form still writes every field; only the client branch
    // reads entityId. A body that omitted the leading strings/position would
    // desync the client's BinaryReader.
    var buf: [128]u8 = undefined;
    const body = try buildNavObjectRemove(&buf, 106);
    var r: binary.Reader = .{ .data = body };
    var s_buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("", try r.readString(&s_buf));
    try std.testing.expectEqualStrings("", try r.readString(&s_buf));
    try std.testing.expectEqual(@as(f32, 0), try r.readF32());
    try std.testing.expectEqual(@as(f32, 0), try r.readF32());
    try std.testing.expectEqual(@as(f32, 0), try r.readF32());
    try std.testing.expectEqual(false, try r.readBool()); // isAdd
    try std.testing.expectEqual(false, try r.readBool()); // useOverrideColor
    _ = try r.readU32(); // colour, ignored by the remove branch
    try std.testing.expectEqual(false, try r.readBool()); // usingLocalizationId
    try std.testing.expectEqual(@as(i32, 106), try r.readI32());
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

/// NetPackageExplosionClient (RE protocol-packages.md 6.15 + write IL=60):
/// `center` Vector3 | `rotation` Quaternion | `expType` i16 | `blastPower` u16 |
/// `blastRadius` u16 | `blockDamage` u16 | `entityId` i32 | `changeCount` u16,
/// then changeCount x BlockChangeInfo. zdtd emits the FX with an empty change
/// list: block results already ride the authoritative SetBlock path, so
/// repeating them here would apply them twice on the client.
pub fn buildExplosionClient(
    buf: []u8,
    cx: f32,
    cy: f32,
    cz: f32,
    exp_type: i16,
    blast_power: u16,
    blast_radius: u16,
    block_damage: u16,
    entity_id: i32,
) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeF32(cx);
    try w.writeF32(cy);
    try w.writeF32(cz);
    // Quaternion identity (x,y,z,w)
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(1);
    try w.writeI16(exp_type);
    try w.writeU16(blast_power);
    try w.writeU16(blast_radius);
    try w.writeU16(block_damage);
    try w.writeI32(entity_id);
    try w.writeU16(0); // explosionChanges count
    return w.written();
}

test "explosion client body layout" {
    // No test covered this builder. It is pos Vector3 | identity quaternion |
    // type i16 | blastPower u16 | blastRadius u16 | blockDamage u16 |
    // entityId i32 | changes count u16, and the three u16 in a row are the
    // part a swap moves without changing the length.
    var buf: [64]u8 = undefined;
    const body = try buildExplosionClient(&buf, 11, 12, 13, 3, 21, 22, 23, 106);
    try std.testing.expectEqual(@as(usize, 12 + 16 + 2 + 6 + 4 + 2), body.len);
    const f32At = struct {
        fn get(b: []const u8, off: usize) f32 {
            return @bitCast(std.mem.readInt(u32, b[off..][0..4], .little));
        }
    }.get;
    try std.testing.expectEqual(@as(f32, 11), f32At(body, 0));
    try std.testing.expectEqual(@as(f32, 12), f32At(body, 4));
    try std.testing.expectEqual(@as(f32, 13), f32At(body, 8));
    // Identity quaternion: three zeros then w = 1.
    try std.testing.expectEqual(@as(f32, 0), f32At(body, 12));
    try std.testing.expectEqual(@as(f32, 1), f32At(body, 24));
    try std.testing.expectEqual(@as(i16, 3), std.mem.readInt(i16, body[28..30], .little));
    try std.testing.expectEqual(@as(u16, 21), std.mem.readInt(u16, body[30..32], .little)); // blastPower
    try std.testing.expectEqual(@as(u16, 22), std.mem.readInt(u16, body[32..34], .little)); // blastRadius
    try std.testing.expectEqual(@as(u16, 23), std.mem.readInt(u16, body[34..36], .little)); // blockDamage
    try std.testing.expectEqual(@as(i32, 106), std.mem.readInt(i32, body[36..40], .little));
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, body[40..42], .little));
}

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
pub fn buildNpcQuestListFetch(
    buf: []u8,
    npc_entity_id: i32,
    player_entity_id: i32,
    tier_level: i32,
    entries: []const stock_quest.QuestPacketEntry,
) ![]u8 {
    return stock_quest.buildNpcQuestListFetch(buf, npc_entity_id, player_entity_id, tier_level, entries);
}

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

/// Trader buy/sell, **not a stock package body**: trader_entity i32 | item u16
/// | qty u16 | side u8 (0=buy, 1=sell), exactly 9 bytes. Stock has no
/// NetPackageTraderTrade; a real client's trade shows up as its post-trade
/// TraderData copy (parseTraderDataToServer). This body rides under the
/// NetPackageTraderData name for loadgen and the sim, and c2s/quest.zig picks
/// the arm on an exact length of 9 so a stock body cannot land here.
pub fn parseTraderTrade(body: []const u8) !struct { trader_entity: i32, item: u16, qty: u16, side: u8 } {
    if (body.len < 9) return error.EndOfStream;
    return .{
        .trader_entity = std.mem.readInt(i32, body[0..4], .little),
        .item = std.mem.readInt(u16, body[4..6], .little),
        .qty = std.mem.readInt(u16, body[6..8], .little),
        .side = body[8],
    };
}

/// Stock NetPackagePlayerVendingMachine.read (asm.il 833593-833690): a
/// PlatformUserIdentifierAbs stream (FromStream(reader, false, false)), the
/// Vector3i position, and the removing flag. The client sends it when it rents
/// (removing=false) or clears (removing=true) a vending machine.
pub const VendingMachineAccess = struct {
    user: platform_user.Id,
    x: i32,
    y: i32,
    z: i32,
    removing: bool,
};

/// Read side of NetPackagePlayerVendingMachine (RE protocol-packages.md
/// residual table, write IL=28): `userId` (PlatformUserIdentifier) | x,y,z i32
/// | `removing` bool. An empty identity is an error rather than a null user:
/// the whole package exists to add or remove that user from a machine's
/// allowed list, so there is nothing to apply without one.
pub fn parseVendingMachineAccess(body: []const u8, plat_buf: []u8, id_buf: []u8) !VendingMachineAccess {
    var r: binary.Reader = .{ .data = body };
    const user = (try platform_user.read(&r, plat_buf, id_buf)) orelse return error.EndOfStream;
    const x = try r.readI32();
    const y = try r.readI32();
    const z = try r.readI32();
    const removing = try r.readBool();
    return .{ .user = user, .x = x, .y = y, .z = z, .removing = removing };
}

/// zdtd's own trade request body, **not a stock package**: traderEntity i32 |
/// item u16 | qty u16 | side u8. Stock has no single "trade" package; a buy or
/// sell rides the inventory transaction path. This feeds Game.handleTrade
/// directly and is never framed with a stock package name, so it cannot reach
/// or come from a client.
pub fn buildTraderTradeBody(buf: []u8, trader_entity: i32, item: u16, qty: u16, side: u8) ![]u8 {
    if (buf.len < 9) return error.Overflow;
    std.mem.writeInt(i32, buf[0..4], trader_entity, .little);
    std.mem.writeInt(u16, buf[4..6], item, .little);
    std.mem.writeInt(u16, buf[6..8], qty, .little);
    buf[8] = side;
    return buf[0..9];
}

/// Stock NetPackageTraderData ToServer header (asm.il 843046): the first byte
/// is isEntity; then entityId (i32) or the TE position Vector3i (3 x i32);
/// then hasTraderData; the TraderData::Write body follows when true. The real
/// client sends its post-trade cache copy back here (loot-economy.md §5). The
/// server parses it for framing but does not treat its stock or money as
/// authoritative.
pub const TraderDataToServer = struct {
    is_entity: bool,
    entity_id: i32 = -1,
    te_x: i32 = 0,
    te_y: i32 = 0,
    te_z: i32 = 0,
    has_trader_data: bool = false,
    /// TraderData::Write body (when has_trader_data).
    trader_data: []const u8 = &.{},
};

/// Read side of the stock NetPackageTraderData ToServer header documented
/// above (asm.il 843046; RE protocol-packages.md, Process IL=50). The
/// discriminant picks the length: an entity target is 1 + 4 + 1 bytes, a tile
/// entity 1 + 12 + 1, and the TraderData::Write body follows only when
/// `hasTraderData` is set. That body is returned as an unparsed slice; the
/// caller decides what of it, if anything, it trusts.
pub fn parseTraderDataToServer(body: []const u8) !TraderDataToServer {
    if (body.len < 6) return error.EndOfStream;
    const is_entity = body[0] != 0;
    var t: TraderDataToServer = .{ .is_entity = is_entity };
    if (is_entity) {
        if (body.len < 6) return error.EndOfStream;
        t.entity_id = std.mem.readInt(i32, body[1..5], .little);
        t.has_trader_data = body[5] != 0;
        t.trader_data = if (t.has_trader_data) body[6..] else &.{};
    } else {
        if (body.len < 14) return error.EndOfStream;
        t.te_x = std.mem.readInt(i32, body[1..5], .little);
        t.te_y = std.mem.readInt(i32, body[5..9], .little);
        t.te_z = std.mem.readInt(i32, body[9..13], .little);
        t.has_trader_data = body[13] != 0;
        t.trader_data = if (t.has_trader_data) body[14..] else &.{};
    }
    return t;
}

/// Stock NetPackagePickupBlock (RE inventories/netpackage-bodies.md "NetPackagePickupBlock",
/// read asm.il 20: StreamUtils.ReadVector3i | ReadUInt32 rawData | ReadInt32
/// playerId | PlatformUserIdentifierAbs.FromStream(errorOnEmpty=false,
/// inclCustomData=false)). The S2C echo of a pickup carries the same layout
/// with a null identity (Setup(pos, bv, playerId, null), ToStream(null) is a
/// lone 0 byte).
pub const PickupBlock = struct {
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
    /// Full BlockValue.rawData the client snapped; type = low 16 bits
    /// (BlockValue.get_type, asm.il BlockValue.rawData layout).
    raw: u32 = 0,
    player_id: i32 = 0,
};

/// Read side of NetPackagePickupBlock (RE inventories/netpackage-bodies.md,
/// read asm.il 20 / write IL=22): `blockPos` (StreamUtils Vector3i) | `rawData`
/// u32 | `playerId` i32 | `persistentPlayerId` (PlatformUserIdentifier, null =
/// one 0 byte). Same order buildPickupBlockBody writes.
///
/// The platform identity is handed back through `sent` rather than dropped
/// because the C2S handler needs it: stock runs both ValidEntityIdForSender on
/// `playerId` and ValidUserIdForSender on the identity, and a parser that
/// consumed the identity silently would leave the second check with nothing to
/// compare (c2s/blocks.zig).
pub fn parsePickupBlockBody(body: []const u8, plat_buf: []u8, id_buf: []u8, sent: *?platform_user.Id) !PickupBlock {
    if (body.len < 16) return error.EndOfStream;
    var r: binary.Reader = .{ .data = body };
    const p: PickupBlock = .{
        .x = try r.readI32(),
        .y = try r.readI32(),
        .z = try r.readI32(),
        .raw = try r.readU32(),
        .player_id = try r.readI32(),
    };
    sent.* = try platform_user.read(&r, plat_buf, id_buf);
    return p;
}

/// NetPackagePickupBlock (RE inventories/netpackage-bodies.md, write IL=22):
/// `blockPos` (StreamUtils Vector3i) | `rawData` u32 | `playerId` i32 |
/// `persistentPlayerId` (PlatformUserIdentifier ToStream; null = one 0 byte,
/// which is what a dedi with no platform identity writes).
pub fn buildPickupBlockBody(buf: []u8, x: i32, y: i32, z: i32, raw: u32, player_id: i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(x);
    try w.writeI32(y);
    try w.writeI32(z);
    try w.writeU32(raw);
    try w.writeI32(player_id);
    try platform_user.write(&w, null);
    return w.written();
}

/// Stock NetPackageItemReload (RE inventories/netpackage-bodies.md "NetPackageItemReload"):
/// a single i32 entityId. Same layout both directions; the dedi relays it to
/// every peer but the sender (GameManager.ItemReloadServer IL=32, flags 192).
pub fn parseItemReload(body: []const u8) !i32 {
    if (body.len < 4) return error.EndOfStream;
    return std.mem.readInt(i32, body[0..4], .little);
}

/// Stock NetPackageSetBlockTexture (RE inventories/netpackage-bodies.md "NetPackageSetBlockTexture",
/// read asm.il 24: StreamUtils.ReadVector3i | u8 face | u8 idx | i32
/// playerIdThatChanged | u8 channel). The dedi rebroadcast sets
/// playerIdThatChanged=-1 (GameManager.SetBlockTextureServer IL=41
/// IL_0018-0027); the face byte stores the BlockTextureData catalog idx raw
/// (Chunk.SetBlockFaceTexture IL=48 masks `_texture & 255` into face*8 bits).
/// chnTextures is a 1-element array (Chunk IL_01F8-01FE: `ldc.i4.1;
/// newarr`), so channel 0 is the only valid one.
pub const SetBlockTexture = struct {
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
    face: u8 = 0,
    idx: u8 = 0,
    player_id: i32 = 0,
    channel: u8 = 0,
};

/// Read side of NetPackageSetBlockTexture (RE
/// inventories/netpackage-bodies.md, write IL=24): `blockPos` (StreamUtils
/// Vector3i) | `blockFace` u8 | `idx` u8 | `playerIdThatChanged` i32 |
/// `channel` u8, which is the 19-byte minimum checked here.
pub fn parseSetBlockTexture(body: []const u8) !SetBlockTexture {
    if (body.len < 19) return error.EndOfStream;
    var r: binary.Reader = .{ .data = body };
    return .{
        .x = try r.readI32(),
        .y = try r.readI32(),
        .z = try r.readI32(),
        .face = try r.readByte(),
        .idx = try r.readByte(),
        .player_id = try r.readI32(),
        .channel = try r.readByte(),
    };
}

/// NetPackageSetBlockTexture (RE inventories/netpackage-bodies.md, write
/// IL=24): `blockPos` (StreamUtils Vector3i = three i32) | `blockFace` u8 |
/// `idx` u8 | `playerIdThatChanged` i32 | `channel` u8.
pub fn buildSetBlockTextureBody(buf: []u8, t: SetBlockTexture) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(t.x);
    try w.writeI32(t.y);
    try w.writeI32(t.z);
    try w.writeByte(t.face);
    try w.writeByte(t.idx);
    try w.writeI32(t.player_id);
    try w.writeByte(t.channel);
    return w.written();
}

/// Stock NetPackageVehicleDataSync header (asm.il:844254, read at asm.il:844340):
/// senderId i32 | vehicleId i32 | syncFlags u16 | dataLen u16 | data[dataLen].
/// The payload is an opaque EntityVehicle::ReadSyncData blob that zdtd relays
/// rather than decodes, so only the framing is validated here.
pub const VehicleDataSync = struct {
    sender_id: i32,
    vehicle_id: i32,
    sync_flags: u16,
    data: []const u8,
};

/// NetPackageVehicleDataSync (RE inventories/netpackage-bodies.md, write
/// IL=27): `senderId` i32 | `vehicleId` i32 | `syncFlags` u16 | `entityData`
/// length u16 + bytes.
pub fn parseVehicleDataSync(body: []const u8) !VehicleDataSync {
    if (body.len < 12) return error.EndOfStream;
    const data_len = std.mem.readInt(u16, body[10..12], .little);
    if (12 + @as(usize, data_len) > body.len) return error.EndOfStream;
    return .{
        .sender_id = std.mem.readInt(i32, body[0..4], .little),
        .vehicle_id = std.mem.readInt(i32, body[4..8], .little),
        .sync_flags = std.mem.readInt(u16, body[8..10], .little),
        .data = body[12 .. 12 + @as(usize, data_len)],
    };
}

/// Native zdtd vehicle control (not a stock layout). Fixed 13 bytes so it can
/// never be confused with a stock body carrying the same package name.
pub const vehicle_control_len: usize = 13;

/// Vehicle control, **not a stock layout**: entity_id i32 | op u8 (0=enter,
/// 1=exit, 2=drive) | throttle f32 | steer f32, exactly `vehicle_control_len`
/// bytes. Stock has no C2S package of this shape; its vehicle placement rides
/// NetPackageVehicleSpawn (entityType i32 | pos | rot | ItemValue |
/// entityThatPlaced i32, RE inventories/netpackage-bodies.md). The dispatch in
/// c2s/misc.zig gates on the exact 13-byte length, so a stock body cannot be
/// decoded here; it falls through unhandled, since zdtd does not implement
/// client-requested vehicle spawning (docs/DIVERGENCES.md).
pub fn parseVehicleControl(body: []const u8) !struct { entity_id: i32, op: u8, throttle: f32, steer: f32 } {
    if (body.len < 5) return error.EndOfStream;
    const eid = std.mem.readInt(i32, body[0..4], .little);
    const op = body[4];
    var throttle: f32 = 0;
    var steer: f32 = 0;
    if (body.len >= 13) {
        throttle = @bitCast(std.mem.readInt(u32, body[5..9], .little));
        steer = @bitCast(std.mem.readInt(u32, body[9..13], .little));
        if (!std.math.isFinite(throttle) or !std.math.isFinite(steer)) return error.Overflow;
    }
    return .{ .entity_id = eid, .op = op, .throttle = throttle, .steer = steer };
}

/// zdtd's own vehicle control body, **not a stock layout**: entityId i32 | op u8
/// | throttle f32 | steer f32, fixed at vehicle_control_len bytes. Stock's
/// NetPackageVehicleSpawn (RE write IL=24) is entityType i32 | pos Vector3 |
/// rot Vector3 | ItemValue | entityThatPlaced i32, which is a different shape
/// and a different purpose. The C2S handler distinguishes them by the exact
/// 13-byte length, so a real stock body can never be read as this one.
pub fn buildVehicleControlBody(buf: []u8, entity_id: i32, op: u8, throttle: f32, steer: f32) ![]u8 {
    if (buf.len < 13) return error.Overflow;
    std.mem.writeInt(i32, buf[0..4], entity_id, .little);
    buf[4] = op;
    std.mem.writeInt(u32, buf[5..9], @as(u32, @bitCast(throttle)), .little);
    std.mem.writeInt(u32, buf[9..13], @as(u32, @bitCast(steer)), .little);
    return buf[0..13];
}

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

test "console cmd parse + client reply roundtrip" {
    // Server-side: parse the command the client typed.
    var body: [64]u8 = undefined;
    var w: binary.Writer = .{ .buf = &body };
    try w.writeString("teleportplayer 10 70 20");
    const cmd_body = w.written();
    var cbuf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("teleportplayer 10 70 20", parseConsoleCmd(cmd_body, &cbuf));

    // Client reply: i32 count + strings + bool, readable by the stock client.
    var rbuf: [256]u8 = undefined;
    const lines = [_][]const u8{ "line one", "line two" };
    const reply = try buildConsoleCmdClient(&rbuf, &lines, false);
    var r: binary.Reader = .{ .data = reply };
    try std.testing.expectEqual(@as(i32, 2), try r.readI32());
    var lb: [64]u8 = undefined;
    try std.testing.expectEqualStrings("line one", try r.readString(&lb));
    try std.testing.expectEqualStrings("line two", try r.readString(&lb));
    try std.testing.expectEqual(false, try r.readBool());
}

test "console cmd parse handles empty/malformed" {
    var cbuf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("", parseConsoleCmd(&.{}, &cbuf));
    // Truncated payload (claimed length longer than remaining bytes).
    try std.testing.expectEqualStrings("", parseConsoleCmd(&[_]u8{ 5, 'h', 'i' }, &cbuf));
    // Overlong 7-bit length prefix (same rejection as binary.Reader).
    try std.testing.expectEqualStrings("", parseConsoleCmd(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 }, &cbuf));
    // Valid short command still parses after the empty/malformed cases.
    var ok_body: [16]u8 = undefined;
    var w: binary.Writer = .{ .buf = &ok_body };
    try w.writeString("help");
    try std.testing.expectEqualStrings("help", parseConsoleCmd(w.written(), &cbuf));
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

test "parsePickupBlockBody reads the stock wrench-pickup layout" {
    // 3x i32 pos | u32 rawData | i32 playerId | null platform identity (1 byte).
    var buf: [64]u8 = undefined;
    var w: binary.Writer = .{ .buf = &buf };
    try w.writeI32(10);
    try w.writeI32(64);
    try w.writeI32(-3);
    try w.writeU32(0x0004_0023); // type 0x23, meta nibble in bits 22..25
    try w.writeI32(501);
    try platform_user.write(&w, .{ .platform = "Steam", .id = "76561198000000001" });
    const body = w.written();
    var plat: [platform_user.max_platform_len]u8 = undefined;
    var id: [platform_user.max_id_len]u8 = undefined;
    var sent: ?platform_user.Id = null;
    const p = try parsePickupBlockBody(body, &plat, &id, &sent);
    try std.testing.expect(sent != null);
    try std.testing.expectEqual(@as(i32, 10), p.x);
    try std.testing.expectEqual(@as(i32, 64), p.y);
    try std.testing.expectEqual(@as(i32, -3), p.z);
    try std.testing.expectEqual(@as(u32, 0x0004_0023), p.raw);
    try std.testing.expectEqual(@as(i32, 501), p.player_id);
    // Truncated before the identity is EndOfStream, never a partial read.
    var cut: usize = 0;
    while (cut < 16) : (cut += 1) {
        var pb: [platform_user.max_platform_len]u8 = undefined;
        var ib: [platform_user.max_id_len]u8 = undefined;
        var sent3: ?platform_user.Id = null;
        try std.testing.expectError(error.EndOfStream, parsePickupBlockBody(body[0..cut], &pb, &ib, &sent3));
    }
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
