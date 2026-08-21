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
    // Appended after the stock set; stock ids 0..15 stay stable for fixtures.
    NetPackageEntityFlags,
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
    "NetPackageEntityFlags",
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
    "NetPackagePOIAround",
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
    minor: i32 = 10,
    build: i32 = 14,

    pub fn write(self: VersionInfo, w: *binary.Writer) !void {
        try w.writeByte(self.release_type);
        try w.writeI32(self.major);
        try w.writeI32(self.minor);
        try w.writeI32(self.build);
    }
};

pub fn buildPackageIdsBody(buf: []u8, ver: VersionInfo, mappings: []const []const u8) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try ver.write(&w);
    try w.writeI32(@intCast(mappings.len));
    for (mappings) |m| try w.writeString(m);
    try w.writeBool(false); // useEac
    try w.writeBool(false); // hasHost
    return w.written();
}

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
};

pub fn buildPlayerIdBody(buf: []u8, entity_id: i32, team: i16, chunk_view_dim: i32, sx: i32, sy: i32, sz: i32) ![]u8 {
    return buildPlayerIdBodyWithOpts(buf, entity_id, team, chunk_view_dim, sx, sy, sz, .{});
}

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
    try writeEmptyPlayerDataFileNetwork(&w, entity_id, sx, sy, sz, opts.quests, opts.unlocked_recipes, opts.toolbelt, opts.bag, opts.b_loaded, opts.game_stage_born_at);
    try w.writeI32(chunk_view_dim);
    return w.written();
}

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
    quests: []const stock_quest.StockQuestWrite,
    unlocked_recipes: []const []const u8,
    toolbelt: []const stock_inv.StockSlot,
    bag: []const stock_inv.StockSlot,
    b_loaded: bool,
    game_stage_born_at: u64,
) !void {
    const px: f32 = @floatFromInt(sx);
    const py: f32 = @floatFromInt(sy);
    const pz: f32 = @floatFromInt(sz);
    // --- EntityCreationData.write(bw, networkWrite=false) ---
    // V3.1.0 ECD FileVersion=36. Use playerMale + profile so GameManager.PlayerId
    // with bLoaded=true can CreateEntity + ToPlayer (applies bag/toolbelt).
    try w.writeByte(36); // FileVersion
    try w.writeI32(stock_entity.class_player_male);
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
    try w.writeString("Player");
    try w.writeString(""); // skinTexture
    try w.writeBool(true); // has PlayerProfile
    try stock_entity.writePlayerProfile(w, .{
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
    try w.writeI32(0); // playerKills
    try w.writeI32(0); // zombieKills
    try w.writeI32(0); // deaths
    try w.writeI32(0); // score
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
    const body2 = try buildPlayerIdBody(&buf, 999, 3, 8, 0, 70, 0);
    try std.testing.expectEqual(@as(i32, 999), std.mem.readInt(i32, body2[0..4], .little));
    try std.testing.expectEqual(@as(i16, 3), std.mem.readInt(i16, body2[4..6], .little));
    try std.testing.expectEqual(@as(i32, 8), std.mem.readInt(i32, body2[body2.len - 4 ..][0..4], .little));
    try std.testing.expectEqual(body.len, body2.len);
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

pub fn parsePosAndRotBody(body: []const u8) !struct { entity_id: i32, x: f32, y: f32, z: f32, on_ground: bool } {
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
    return .{ .entity_id = entity_id, .x = x, .y = y, .z = z, .on_ground = on_ground };
}

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
pub const cF_approaching_player: u16 = 0x0002;
pub const cF_spawned: u16 = 0x0008;
pub const cF_is_alert: u16 = 0x0040;
/// Stock `IsCrouching` bit (protocol-packages.md 5.5.6): set by the client's
/// EntityFlags/AliveFlags package; the sim reads it for the stealth sense
/// gates (hear muffle + sleeper detect).
pub const cF_crouching: u16 = 0x0200;

pub fn buildAliveFlagsBody(buf: []u8, entity_id: i32, flags: u16) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeU16(flags);
    return w.written();
}

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

/// Head of PlayerDataFile.WriteNetwork / ECD.write(networkWrite=false) for SavePlayerData C2S.
/// Returns entity id + world position from the embedded EntityCreationData.
pub fn parsePlayerDataEcdHead(body: []const u8) !struct { entity_id: i32, x: f32, y: f32, z: f32 } {
    // FileVersion:u8 | entityClass:i32 | id:i32 | lifetime:f32 | pos:f32*3 | ...
    if (body.len < 1 + 4 + 4 + 4 + 12) return error.EndOfStream;
    var r: binary.Reader = .{ .data = body };
    const ver = try r.readByte();
    if (ver != 35 and ver != 36) return error.EndOfStream;
    _ = try r.readI32(); // entityClass
    const entity_id = try r.readI32();
    _ = try r.readF32(); // lifetime
    const x = try r.readF32();
    const y = try r.readF32();
    const z = try r.readF32();
    return .{ .entity_id = entity_id, .x = x, .y = y, .z = z };
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
    try writeEmptyPlayerDataFileNetwork(&w, 106, -273, 61, 449, &.{}, &.{}, &.{}, &.{}, true, game_stage_born_unset);
    const h = try parsePlayerDataEcdHead(w.written());
    try std.testing.expectEqual(@as(i32, 106), h.entity_id);
    try std.testing.expectApproxEqAbs(@as(f32, -273), h.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 61), h.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 449), h.z, 0.01);
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

/// Minimal DamageEntity body: enough for entityId + source + type + strength + fatal path fields zeros.
pub fn buildDamageBody(buf: []u8, entity_id: i32, source: u8, dtype: u8, strength: u16, fatal: bool, attacker: i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeByte(source);
    try w.writeByte(dtype);
    try w.writeU16(strength);
    try w.writeByte(0); // hitDirection
    try w.writeI16(0); // bodyPart
    try w.writeByte(0); // movement
    try w.writeBool(true); // pain
    try w.writeBool(fatal);
    try w.writeBool(false); // crit
    try w.writeI32(attacker);
    try w.writeF32(0);
    try w.writeF32(-1);
    try w.writeF32(0); // dirV
    try w.writeI32(0);
    try w.writeI32(0);
    try w.writeI32(0); // blockPos
    try w.writeString(""); // hitTransform
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(0); // uv
    try w.writeF32(1);
    try w.writeF32(0);
    try w.writeBool(true);
    try w.writeBool(false);
    try w.writeBool(false);
    try w.writeBool(false);
    try w.writeBool(false);
    try w.writeByte(0);
    try w.writeByte(0);
    try w.writeF32(0);
    try w.writeBool(false);
    try w.writeByte(0);
    try w.writeByte(0);
    try w.writeU16(0);
    try w.writeBool(false); // no item
    return w.written();
}

pub fn parseDamageHead(body: []const u8) !struct { entity_id: i32, source: u8, dtype: u8, strength: u16, fatal: bool } {
    if (body.len < 15) return error.EndOfStream;
    var r: binary.Reader = .{ .data = body };
    const entity_id = try r.readI32();
    const source = try r.readByte();
    const dtype = try r.readByte();
    const strength = try r.readU16();
    _ = try r.readByte();
    _ = try r.readI16();
    _ = try r.readByte();
    _ = try r.readBool();
    const fatal = try r.readBool();
    return .{ .entity_id = entity_id, .source = source, .dtype = dtype, .strength = strength, .fatal = fatal };
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

/// NetPackageRequestToSpawnPlayer: chunkViewDim:i16 | PlayerProfile | nearEntityId:i32
/// Profile is opaque; we only need view dim when present.
pub fn parseRequestToSpawnPlayer(body: []const u8) !struct { chunk_view_dim: i32, near_entity_id: i32 } {
    if (body.len < 2) return error.EndOfStream;
    var r: binary.Reader = .{ .data = body };
    const dim = try r.readI16();
    // Skip profile best-effort: if remaining has at least 4 bytes at end for nearEntityId
    var near: i32 = -1;
    if (body.len >= 6) {
        near = std.mem.readInt(i32, body[body.len - 4 ..][0..4], .little);
    }
    return .{ .chunk_view_dim = dim, .near_entity_id = near };
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

/// BlockValue.meta lives in rawData bits 22..25 (asm.il:140570 get_meta).
/// Powered blocks carry their visual state there: bit 0x1 = isPowered,
/// bit 0x2 = isOn (Block::ActivateBlock, asm.il:127088 / 137044).
pub const block_meta_powered: u8 = 1;
pub const block_meta_on: u8 = 2;

pub fn blockMeta(raw: u32) u8 {
    return @truncate((raw >> 22) & 15);
}

/// BlockValue::set_meta: clear bits 22..25 then splice the low nibble back in.
pub fn withBlockMeta(raw: u32, meta: u8) u32 {
    return (raw & 0xfc3fffff) | (@as(u32, meta & 15) << 22);
}

/// Build one-change stock SetBlock (null platform user; peers accept S2C without id check).
/// Id-only: rotation and meta bits are zero, so this is safe for fresh placement
/// and wrong for echoing a mutated block. Those callers want buildSetBlockBodyRaw.
pub fn buildSetBlockBody(buf: []u8, x: i32, y: i32, z: i32, block_id: u16) ![]u8 {
    return buildSetBlockBodyRaw(buf, x, y, z, @as(u32, block_id), 0, 0, 0);
}

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

/// Parse first stock BlockChangeInfo (or legacy simplified x/y/z/u16 for old fixtures).
pub fn parseSetBlockBody(body: []const u8) !struct { x: i32, y: i32, z: i32, block_id: u16 } {
    var one: [1]BlockChange = undefined;
    const n = try parseSetBlockChanges(body, one[0..]);
    if (n == 0 or !one[0].has_pos or !one[0].has_value) return error.EndOfStream;
    return .{ .x = one[0].x, .y = one[0].y, .z = one[0].z, .block_id = one[0].block_id };
}

/// Parse all BlockChangeInfo entries with world positions + block values.
pub fn parseSetBlockChanges(body: []const u8, out: []BlockChange) !usize {
    // Legacy intermediate: 14 bytes.
    if (body.len == 14) {
        if (out.len == 0) return 0;
        var r: binary.Reader = .{ .data = body };
        out[0] = .{
            .x = try r.readI32(),
            .y = try r.readI32(),
            .z = try r.readI32(),
            .block_id = try r.readU16(),
            .has_pos = true,
            .has_value = true,
        };
        return 1;
    }
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
        ch.block_id = @truncate(raw & 0xffff);
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

pub fn framed(buf: []u8, name: []const u8, body: []const u8) ![]u8 {
    const id = idOf(name) orelse return error.UnknownPackage;
    return frame.framePackage(buf, 0, id, body);
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

test "block meta accessors match BlockValue get_meta/set_meta" {
    try std.testing.expectEqual(@as(u8, 0), blockMeta(19200));
    try std.testing.expectEqual(@as(u32, 19200 | (2 << 22)), withBlockMeta(19200, 2));
    // Only bits 22..25 move; rotation and the type survive, and meta wraps to 4 bits.
    const rot: u32 = 19200 | (5 << 26) | (3 << 22);
    try std.testing.expectEqual(@as(u8, 3), blockMeta(rot));
    try std.testing.expectEqual(@as(u8, 15), blockMeta(withBlockMeta(rot, 0xff)));
    try std.testing.expectEqual(rot & ~@as(u32, 15 << 22), withBlockMeta(rot, 0));
}

test "NetPackageChunk package id is 12" {
    // Loadgen / stock maps use this id for terrain; join must deliver it.
    try std.testing.expectEqual(@as(u16, 12), idOf("NetPackageChunk").?);
    var heights: [256]u8 = .{70} ** 256;
    var body_buf: [512]u8 = undefined;
    const body = try buildChunkBody(&body_buf, -18, 28, &heights);
    try std.testing.expectEqual(@as(usize, chunk_stock_envelope_overhead + chunk_body_size), body.len);
    var frame_buf: [512]u8 = undefined;
    const fr = try framed(&frame_buf, "NetPackageChunk", body);
    // LiteNet channeled total must fit pending_bytes (1200).
    try std.testing.expect(fr.len + 4 < 1200);
}

test "pos body golden size" {
    var body_buf: [64]u8 = undefined;
    const body = try buildPosAndRotBody(&body_buf, 7, 1, 2, 3, 0, 90, 0, true);
    try std.testing.expectEqual(@as(usize, 30), body.len);
    const p = try parsePosAndRotBody(body);
    try std.testing.expectEqual(@as(i32, 7), p.entity_id);
    try std.testing.expect(p.on_ground);
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
    const body = try buildRelPosBody(&body_buf, 1, 1, 0, -1, 0, 128, 0, true, 2);
    try std.testing.expectEqual(@as(usize, 20), body.len);
    var frame_buf: [128]u8 = undefined;
    const fr = try framed(&frame_buf, "NetPackageEntityRelPosAndRot", body);
    // contentLen at offset 9 = 22
    const cl = std.mem.readInt(i32, fr[9..][0..4], .little);
    try std.testing.expectEqual(@as(i32, 22), cl);
}

test "package ids body" {
    var buf: [8192]u8 = undefined;
    const body = try buildPackageIdsBody(&buf, .{}, &default_mappings);
    var r: binary.Reader = .{ .data = body };
    try std.testing.expectEqual(@as(u8, 1), try r.readByte());
    try std.testing.expectEqual(@as(i32, 3), try r.readI32());
    try std.testing.expectEqual(@as(i32, 10), try r.readI32());
    try std.testing.expectEqual(@as(i32, 14), try r.readI32());
    try std.testing.expectEqual(@as(i32, @intCast(default_mappings.len)), try r.readI32());
}

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

test "world info body layout ends with hashCount0 and worldDataSize" {
    var buf: [256]u8 = undefined;
    const body = try buildWorldInfoBody(&buf, "Navezgane", 6144, 6144, 0, 0, 0, 0);
    // last 12 bytes: i32 0 + i64 0
    try std.testing.expect(body.len >= 12);
    const tail = body[body.len - 12 ..];
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, tail[0..4], .little));
    try std.testing.expectEqual(@as(i64, 0), std.mem.readInt(i64, tail[4..12], .little));
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

/// Legacy simplified hp pair (bots). Prefer buildEntityStatChangedBody for stock clients.
pub fn buildEntityStatBody(buf: []u8, entity_id: i32, hp: f32, max_hp: f32) ![]u8 {
    return buildEntityStatChangedBody(buf, entity_id, -1, .health, hp, max_hp, 0);
}

test "entity stat changed body size" {
    var buf: [32]u8 = undefined;
    const body = try buildEntityStatChangedBody(&buf, 106, -1, .health, 100, 100, 0);
    try std.testing.expectEqual(@as(usize, 4 + 4 + 1 + 4 + 4 + 4), body.len);
    try std.testing.expectEqual(@as(i32, 106), std.mem.readInt(i32, body[0..4], .little));
    try std.testing.expectEqual(@as(u8, 0), body[8]); // Health
}

/// Stock-compatible player inventory body (NetPackagePlayerInventory.write fields).
pub fn buildInventoryBodyStock(buf: []u8, inv: *const components.Inventory) ![]u8 {
    return stock_inv.buildFromEcs(buf, inv);
}

pub fn buildInventoryBodyStockResolved(
    buf: []u8,
    inv: *const components.Inventory,
    resolve: ?stock_inv.TypeResolver,
    ctx: ?*anyopaque,
) ![]u8 {
    return stock_inv.buildFromEcsResolved(buf, inv, resolve, ctx);
}

/// NetPackageIdMapping body: name string + i32 len + bytes.
pub fn buildIdMappingBody(buf: []u8, name: []const u8, data: []const u8) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeString(name);
    try w.writeI32(@intCast(data.len));
    try w.writeBytes(data);
    return w.written();
}

pub fn parseInventoryBodyNative(body: []const u8) !struct { holding: u16, open_container: i32, count: u16 } {
    var r: binary.Reader = .{ .data = body };
    return .{
        .holding = try r.readU16(),
        .open_container = try r.readI32(),
        .count = try r.readU16(),
    };
}

pub fn buildHoldingBodyResolved(
    buf: []u8,
    entity_id: i32,
    inv: *const components.Inventory,
    resolve: ?stock_inv.TypeResolver,
    ctx: ?*anyopaque,
) ![]u8 {
    return stock_inv.buildHoldingFromEcsResolved(buf, entity_id, inv, resolve, ctx);
}

/// Transaction request: op:u8 | a:u16 | b:u16 | qty:u16 | entity_id:i32
pub fn buildInvTxRequest(buf: []u8, op: u8, a: u16, b: u16, qty: u16, entity_id: i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeByte(op);
    try w.writeU16(a);
    try w.writeU16(b);
    try w.writeU16(qty);
    try w.writeI32(entity_id);
    return w.written();
}

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

/// Response: ok:u8 | dropped_entity:i32 | then optional inventory snap (caller appends).
pub fn buildInvTxResponseHead(buf: []u8, ok: bool, dropped_entity: i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeByte(@intFromBool(ok));
    try w.writeI32(dropped_entity);
    return w.written();
}

/// Legacy container data request: entity_id i32 (loadgen / older path).
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

/// Stock success response with item stacks (hash miss / full sync path).
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
    /// Slice of request body covering targetCount i32 + target identifying blobs (not context).
    targets_blob: []const u8,
    /// Remaining body after targets (context type string + optional payload).
    context_tail: []const u8,
};

fn skipLockTargetIdent(r: *binary.Reader) binary.ReadError!void {
    const present = try r.readByte();
    if (present == 0) return;
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
}

/// Parse LockRequest; on success returns head with slices into `body`.
pub fn parseLockRequest(body: []const u8) binary.ReadError!LockRequestHead {
    var r: binary.Reader = .{ .data = body };
    const locking = try r.readBool();
    const channel = try r.readU16();
    const count_pos = r.pos;
    const count = try r.readI32();
    if (count < 0 or count > 32) return error.EndOfStream;
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        try skipLockTargetIdent(&r);
    }
    const targets_end = r.pos;
    // remainder is context
    return .{
        .locking = locking,
        .channel = channel,
        .targets_blob = body[count_pos..targets_end],
        .context_tail = body[targets_end..],
    };
}

/// Build LockResponse that grants the lock by echoing request targets/context.
/// Layout: locking | success | error | isForceUnlocked | channel | targets | context
pub fn buildLockResponseGrant(buf: []u8, req: LockRequestHead) ![]u8 {
    return buildLockResponse(buf, req, true, "");
}

/// Deny lock (held by another peer / channel busy).
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

/// Grant a lock whose target is a trader entity. Stock serializes the
/// EntityTraderLockContext into the LockResponse (loot-economy.md): the type
/// name and Command are echoed from the request, then hasTraderData=true and
/// the server TraderData. NetPackageTraderData is ToServer-only, so this is
/// the packet that carries trader inventory to the opening client.
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
    try w.writeString(command);
    try w.writeBool(true); // hasTraderData
    try stock_entity.writeTraderDataBody(&w, td);
    return w.written();
}

/// Unlock response (locking=false path on client ProcessPackage).
pub fn buildLockResponseUnlock(buf: []u8, success: bool) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeBool(false); // locking
    try w.writeBool(success);
    try w.writeString("");
    try w.writeBool(false); // isForceUnlocked
    // remaining fields read by client only on locking=true path for UnlockResponse
    // but write still emits channel/targets/context for stream completeness when locking=false
    // UnlockResponse only uses success/error/force: client stops early. Still write minimal tail.
    try w.writeU16(0);
    try w.writeI32(0); // no targets
    try w.writeString("");
    return w.written();
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
    is_spawn_enemies: bool = true,
    enemy_spawn_mode: bool = true,
    time_of_day_inc_per_sec: i32 = 20,
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
pub fn buildGameStatsBody(buf: []u8, players: u16, zombies: u16, day: u32, hours: f32) ![]u8 {
    _ = players;
    _ = zombies;
    _ = day;
    _ = hours;
    return buildGameStatsBodyValues(buf, .{});
}

/// Full persistent GameStats.Write matching the propertyList order (V3.1.0 b14).
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
    try w.writeBool(false); // IsCreativeMenuEnabled
    try w.writeBool(false); // IsTeleportEnabled
    try w.writeBool(false); // IsFlyingEnabled
    try w.writeBool(true); // IsPlayerDamageEnabled
    try w.writeBool(true); // IsPlayerCollisionEnabled
    try w.writeBool(v.is_spawn_enemies); // IsSpawnEnemies
    try w.writeI32(v.player_killing_mode); // PlayerKillingMode
    try w.writeI32(1); // ScorePlayerKillMultiplier
    try w.writeI32(1); // ScoreZombieKillMultiplier
    try w.writeI32(-5); // ScoreDiedMultiplier
    try w.writeI32(v.drop_on_death); // DropOnDeath
    try w.writeI32(0); // DropOnQuit
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
    try w.writeBool(true); // AirDropMarker
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
    try w.writeBool(true); // BiomeProgression
    try w.writeI32(v.storm_freq); // StormFreq
    try w.writeI32(0); // CameraRestrictionMode
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
    try w.writeI32(100); // GlobalLMModifier
    try w.writeI32(100); // BiomeLMModifier

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
    // Compatibility wrapper still builds.
    const emptyish = try buildGameStatsBody(buf[256..], 0, 0, 1, 8);
    try std.testing.expect(emptyish.len > 100);
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

pub fn parseChunkRemoveBody(body: []const u8) !struct { cx: i32, cz: i32 } {
    if (body.len < 8) return error.EndOfStream;
    const key = std.mem.readInt(i64, body[0..8], .little);
    return .{ .cx = extractChunkKeyX(key), .cz = extractChunkKeyZ(key) };
}

/// Collect loot: entity_id i32 (bag). Optional playerId i32 on stock wire.
pub fn parseCollectBody(body: []const u8) !i32 {
    if (body.len < 4) return error.EndOfStream;
    return std.mem.readInt(i32, body[0..4], .little);
}

pub fn buildEntityCollectBody(buf: []u8, entity_id: i32, player_id: i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeI32(player_id);
    return w.written();
}

/// GameUtils/EKickReason (asm.il:1913681-1913720). Only the values zdtd emits:
/// an operator `kick` and a server-side guard-policy decision. zdtd has no EAC
/// integration, so the Eac* reasons are never sent.
pub const KickReason = enum(i32) {
    manual_kick = 0x0A,
    mod_decision = 0x10,
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

pub fn buildEntityAttach(buf: []u8, attach_type: AttachType, rider_id: i32, vehicle_id: i32, slot: i16) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeByte(@intFromEnum(attach_type));
    try w.writeI32(rider_id);
    try w.writeI32(vehicle_id);
    try w.writeI16(slot);
    return w.written();
}

pub fn parseEntityAttach(body: []const u8) !struct { attach_type: AttachType, rider_id: i32, vehicle_id: i32, slot: i16 } {
    if (body.len < 11) return error.EndOfStream;
    const at_raw = body[0];
    if (at_raw > 3) return error.InvalidEvent;
    return .{
        .attach_type = @enumFromInt(at_raw),
        .rider_id = std.mem.readInt(i32, body[1..5], .little),
        .vehicle_id = std.mem.readInt(i32, body[5..9], .little),
        .slot = std.mem.readInt(i16, body[9..11], .little),
    };
}

pub fn attachTypeIsDetach(t: AttachType) bool {
    return t == .detach_server or t == .detach_client;
}

pub const SpawnPointXYZ = struct {
    x: i32,
    y: i32,
    z: i32,
    /// Degrees yaw (SpawnPosition.heading). 0 if unknown.
    heading: f32 = 0,
    team: i32 = 0,
    /// -1 = all game modes (stock default for world spawns).
    active_in_game_mode: i32 = -1,
};

/// NetPackageWorldSpawnPoints body = SpawnPointList.Write:
///   u8 CurrentSaveVersion(=2) + i32 count + SpawnPoint.Write * n
/// SpawnPoint.Write = SpawnPosition.Write + i32 team + i32 activeInGameMode
/// SpawnPosition.Write = u16 0 + f32 x,y,z + f32 heading
/// Per-point payload = 26 bytes (stock GetLength lies with count*20).
pub fn buildWorldSpawnPoints(buf: []u8, points: []const SpawnPointXYZ) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeByte(2); // SpawnPointList.CurrentSaveVersion
    try w.writeI32(@intCast(points.len));
    for (points) |p| {
        try w.writeU16(0); // SpawnPosition always writes a discarded u16
        try w.writeF32(@floatFromInt(p.x));
        try w.writeF32(@floatFromInt(p.y));
        try w.writeF32(@floatFromInt(p.z));
        try w.writeF32(p.heading);
        try w.writeI32(p.team);
        try w.writeI32(p.active_in_game_mode);
    }
    return w.written();
}

test "world spawn points stock wire" {
    var buf: [128]u8 = undefined;
    const body = try buildWorldSpawnPoints(&buf, &[_]SpawnPointXYZ{
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
/// (../7dtd-research il dump, docs/loot-economy.md:435).
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
            .size_x = 60,
            .size_y = 28,
            .size_z = 60,
            .pad_x = -2,
            .pad_y = 0,
            .pad_z = -2,
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
    try std.testing.expectEqual(@as(i32, 10), std.mem.readInt(i32, body[3..7], .little));
    try std.testing.expectEqual(@as(i16, 60), std.mem.readInt(i16, body[15..17], .little));
    try std.testing.expectEqual(@as(i8, -2), @as(i8, @bitCast(body[21]))); // pad_x
    try std.testing.expectEqual(@as(u8, 2), body[24]); // teleport count
    try std.testing.expectEqual(@as(i8, 7), @as(i8, @bitCast(body[25]))); // vol0 start_x
    try std.testing.expectEqual(@as(u8, 52), body[28]); // vol0 size_x
}

pub fn parseLandClaimRepair(body: []const u8) !struct { x: i32, y: i32, z: i32, begin_repair: bool } {
    if (body.len < 25) return error.EndOfStream;
    var r: binary.Reader = .{ .data = body };
    const x = std.math.cast(i32, try r.readI64()) orelse return error.EndOfStream;
    const y = std.math.cast(i32, try r.readI64()) orelse return error.EndOfStream;
    const z = std.math.cast(i32, try r.readI64()) orelse return error.EndOfStream;
    const begin = try r.readBool();
    return .{ .x = x, .y = y, .z = z, .begin_repair = begin };
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

/// Minimal ExplosionClient: center xyz + identity quat + expType i16 + power/radius/blockDmg u16 + entityId + changes u16=0.
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
    /// ExplosionData.entityRadius * 0.05 (default 3).
    entity_radius: f32 = 3,
    /// ExplosionData.entityDamage (default 0 -> falls back to block_damage).
    entity_damage: f32 = 0,
};

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
        if (br.readI16()) |er| {
            if (er > 0) out.entity_radius = @as(f32, @floatFromInt(er)) * 0.05;
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

/// zdtd-native quest accept/progress (not stock client wire).
/// def_id u16, op u8 (0=list,1=accept,2=abandon). Kept for unit/loadgen fixtures.
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

/// Parse stock C2S NPCQuestList head (npc, player, eventType + optional tier).
pub fn parseNpcQuestList(body: []const u8) !NpcQuestListHead {
    if (body.len < 9) return error.EndOfStream;
    const npc = std.mem.readInt(i32, body[0..4], .little);
    const player = std.mem.readInt(i32, body[4..8], .little);
    const et_raw = body[8];
    const et: NpcQuestEventType = if (et_raw <= 4)
        @enumFromInt(et_raw)
    else
        return error.InvalidEvent;
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

/// S2C FetchList with QuestPacketEntry offers (stock trader UI).
/// Empty offers: pass `entries` as `&.{}` (npc | player | eventType=0 | tier | count=0).
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

pub fn parseQuestObjectiveUpdate(body: []const u8) !QuestObjectiveUpdate {
    if (body.len < 9) return error.EndOfStream;
    const et_raw = body[8];
    const et: QuestObjectiveEventType = if (et_raw <= 2)
        @enumFromInt(et_raw)
    else
        return error.InvalidEvent;
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

    for ([_]AttachType{ .attach_server, .attach_client, .detach_server, .detach_client }) |t| {
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
    try std.testing.expectEqual(QuestObjectiveEventType.block_activated, u.event_type);
    try std.testing.expectEqual(@as(i32, 10), u.block_x);
}

/// Trader buy/sell: trader_entity i32, item u16, qty u16, side u8 (0=buy,1=sell).
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

pub fn parseVendingMachineAccess(body: []const u8, plat_buf: []u8, id_buf: []u8) !VendingMachineAccess {
    var r: binary.Reader = .{ .data = body };
    const user = (try platform_user.read(&r, plat_buf, id_buf)) orelse return error.EndOfStream;
    const x = try r.readI32();
    const y = try r.readI32();
    const z = try r.readI32();
    const removing = try r.readBool();
    return .{ .user = user, .x = x, .y = y, .z = z, .removing = removing };
}

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

/// Stock NetPackagePickupBlock (RE netpackage-bodies.md "NetPackagePickupBlock",
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

/// Stock NetPackageSetBlockTexture (RE netpackage-bodies.md "NetPackageSetBlockTexture",
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

/// Vehicle control: entity_id i32, op u8 (0=enter,1=exit,2=drive), throttle f32, steer f32
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

pub fn buildVehicleControlBody(buf: []u8, entity_id: i32, op: u8, throttle: f32, steer: f32) ![]u8 {
    if (buf.len < 13) return error.Overflow;
    std.mem.writeInt(i32, buf[0..4], entity_id, .little);
    buf[4] = op;
    std.mem.writeInt(u32, buf[5..9], @as(u32, @bitCast(throttle)), .little);
    std.mem.writeInt(u32, buf[9..13], @as(u32, @bitCast(steer)), .little);
    return buf[0..13];
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
    // bare payload still parses
    const bare = try buildChunkPayload(buf[0..chunk_body_size], 3, 4, &heights);
    const p2 = try parseChunkBody(bare);
    try std.testing.expectEqual(@as(i32, 3), p2.cx);
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

    /// `ClientInfo::get_InternalId` (asm.il 783909): crossplatform when present,
    /// otherwise native. This is what stock keys PersistentPlayerData on
    /// (`GameManager::getPersistentPlayerID`, asm.il 1886263).
    pub fn internalId(self: *const PlayerLogin) platform_user.Stored {
        return if (self.crossplatform.present) self.crossplatform else self.native;
    }
};

/// Parse a full login body. `name_buf` receives the raw (unsanitized) name; the
/// caller still owns sanitizing it before it reaches any operator surface.
pub fn parsePlayerLogin(body: []const u8, name_buf: []u8) binary.ReadError!PlayerLogin {
    var r: binary.Reader = .{ .data = body };
    var out: PlayerLogin = .{ .name = try r.readString(name_buf) };
    var plat_buf: [platform_user.max_platform_len]u8 = undefined;
    var id_buf: [platform_user.max_id_len]u8 = undefined;

    try out.native.set(try platform_user.read(&r, &plat_buf, &id_buf));
    try r.skipString(); // native auth token
    try out.crossplatform.set(try platform_user.read(&r, &plat_buf, &id_buf));
    try r.skipString(); // crossplatform auth token
    try r.skipString(); // version
    try r.skipString(); // compVersion
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
    try w.writeString("maci");
    try platform_user.write(&w, .{ .platform = "Steam", .id = "76561198000000001" });
    try w.writeString("native-ticket");
    try platform_user.write(&w, .{ .platform = "EOS", .id = "0123456789abcdef" });
    try w.writeString("eos-jwt");
    try w.writeString("V 3.1.0 (b14)");
    try w.writeString("V 3.1.0");
    try w.writeU64(42);

    var name_buf: [32]u8 = undefined;
    const login = try parsePlayerLogin(w.written(), &name_buf);
    try std.testing.expectEqualStrings("maci", login.name);
    try std.testing.expectEqualStrings("Steam", login.native.get().?.platform);
    try std.testing.expectEqualStrings("76561198000000001", login.native.get().?.id);
    try std.testing.expectEqualStrings("EOS", login.crossplatform.get().?.platform);
    try std.testing.expectEqual(@as(u64, 42), login.discord_user_id);
    // InternalId prefers the crossplatform account.
    try std.testing.expectEqualStrings("EOS", login.internalId().get().?.platform);
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
    try w.writeString("V 3.1.0 (b14)");
    try w.writeString("V 3.1.0 (b14)");
    try w.writeU64(0);

    var name_buf: [32]u8 = undefined;
    const login = try parsePlayerLogin(w.written(), &name_buf);
    try std.testing.expectEqualStrings("Bot", login.name);
    try std.testing.expect(login.native.get() == null);
    try std.testing.expect(login.crossplatform.get() == null);
    try std.testing.expect(login.internalId().get() == null);
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

/// Parse a stock InventoryTransaction.Write body. Returns error.EndOfStream on
/// truncation and error.InvalidArgument when the layout is not stock-shaped
/// (callers fall back to the native body).
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
    try std.testing.expectEqual(@as(i32, 7), p.x);
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
    try std.testing.expectEqual(@as(i32, 5), t.x);
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
    // Truncated at every boundary is EndOfStream.
    var cut: usize = 0;
    while (cut < 19) : (cut += 1) {
        try std.testing.expectError(error.EndOfStream, parseSetBlockTexture(built[0..cut]));
    }
}
