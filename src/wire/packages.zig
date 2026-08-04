//! Golden package body builders/parsers for join, motion, damage, spawn, TE.
//! Prefer this facade for stock_* body modules; leaf files stay importable.

const std = @import("std");
const binary = @import("binary.zig");
const frame = @import("frame.zig");
pub const stock_inv = @import("stock_inv.zig");
pub const stock_chunk = @import("stock_chunk.zig");
pub const stock_deco = @import("stock_deco.zig");
pub const stock_entity = @import("stock_entity.zig");
pub const stock_quest = @import("stock_quest.zig");
pub const stock_te = @import("stock_te.zig");
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

/// Stock NetPackagePlayerId body (V3.0.1):
/// id:i32 | team:i16 | PlayerDataFile.WriteNetwork | chunkViewDim:i32
/// Empty PDF matches a fresh PlayerDataFile() so stock ReadNetwork completes without EOF.
/// `sx,sy,sz` are world spawn coords written into ECD pos + lastSpawnPosition so the
/// local player is not created at (0,0,0) (which floods SkyManager/SignTexture NREs).
pub fn buildPlayerIdBody(buf: []u8, entity_id: i32, team: i16, chunk_view_dim: i32, sx: i32, sy: i32, sz: i32) ![]u8 {
    return buildPlayerIdBodyWithQuests(buf, entity_id, team, chunk_view_dim, sx, sy, sz, &.{});
}

/// PlayerId with optional stock QuestJournal entries (must use client-known quest IDs).
pub fn buildPlayerIdBodyWithQuests(
    buf: []u8,
    entity_id: i32,
    team: i16,
    chunk_view_dim: i32,
    sx: i32,
    sy: i32,
    sz: i32,
    quests: []const stock_quest.StockQuestWrite,
) ![]u8 {
    return buildPlayerIdBodyFull(buf, entity_id, team, chunk_view_dim, sx, sy, sz, quests, &.{});
}

/// PlayerId + optional unlocked recipe names (always_unlocked craft list).
pub fn buildPlayerIdBodyFull(
    buf: []u8,
    entity_id: i32,
    team: i16,
    chunk_view_dim: i32,
    sx: i32,
    sy: i32,
    sz: i32,
    quests: []const stock_quest.StockQuestWrite,
    unlocked_recipes: []const []const u8,
) ![]u8 {
    return buildPlayerIdBodyInv(buf, entity_id, team, chunk_view_dim, sx, sy, sz, quests, unlocked_recipes, &.{}, &.{});
}

/// PlayerId carrying restored toolbelt/bag stacks (persisted players.zsv v2).
/// Empty slices = fresh join (client uses its local starter PDF).
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
    return buildPlayerIdBodyInvLoaded(buf, entity_id, team, chunk_view_dim, sx, sy, sz, quests, unlocked_recipes, toolbelt, bag, true);
}

/// Like buildPlayerIdBodyInv; b_loaded=false for death-respawn re-bundle (avoids
/// GameManager.PlayerId CreateEntity+ToPlayer on an already-spawned local player).
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
) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeI16(team);
    try writeEmptyPlayerDataFileNetwork(&w, entity_id, sx, sy, sz, quests, unlocked_recipes, toolbelt, bag, b_loaded);
    try w.writeI32(chunk_view_dim);
    return w.written();
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
    try w.writeU64(std.math.maxInt(u64)); // gameStageBornAtWorldTime = -1 as u64
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
    // progressionData / buffData / stealthData: length 0 (empty streams)
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

/// NetPackageEntitySpawnResponse: success:bool | ItemValue (empty byte 0 when no item).
pub fn buildEntitySpawnResponse(buf: []u8, success: bool) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeBool(success);
    try stock_inv.writeEmptyItemValue(&w);
    return w.written();
}

pub fn buildEntitySpawnResponseItem(buf: []u8, success: bool, item: stock_inv.StockSlot) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeBool(success);
    try stock_inv.writeItemValue(&w, item);
    return w.written();
}

/// Stock TraderData with primary inventory entries (ItemStack + markup i8 + addedByPlayer).
pub const TraderStockEntry = struct {
    item: stock_inv.StockSlot,
    markup: i8 = 0,
};

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
    // TraderData.Write
    try w.writeI32(trader_id);
    try w.writeU64(0); // lastInventoryUpdate
    try w.writeByte(2); // FileVersion
    // WriteInventoryData: primary count + entries, tier groups 0, money
    try w.writeI32(@intCast(entries.len));
    for (entries) |e| {
        try stock_inv.writeItemStack(&w, e.item);
        try w.writeByte(@bitCast(e.markup)); // i8 as byte
        try w.writeBool(false); // AddedByPlayer
    }
    try w.writeByte(0); // TierItemGroups count
    try w.writeI32(available_money);
    return w.written();
}

pub fn parsePosAndRotBody(body: []const u8) !struct { entity_id: i32, x: f32, y: f32, z: f32, on_ground: bool } {
    if (body.len < 30) return error.EndOfStream;
    var r: binary.Reader = .{ .data = body };
    const entity_id = try r.readI32();
    const x = try r.readF32();
    const y = try r.readF32();
    const z = try r.readF32();
    const use_q = try r.readBool();
    if (!use_q) {
        _ = try r.readF32();
        _ = try r.readF32();
        _ = try r.readF32();
    } else {
        _ = try r.readF32();
        _ = try r.readF32();
        _ = try r.readF32();
        _ = try r.readF32();
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

/// Stock NetPackageEntityAliveFlags bit constants (V3).
pub const cF_approaching_enemy: u16 = 0x0001;
pub const cF_approaching_player: u16 = 0x0002;
pub const cF_aiming_gun: u16 = 0x0004;
pub const cF_spawned: u16 = 0x0008;
pub const cF_jumping: u16 = 0x0010;
pub const cF_is_breaking_blocks: u16 = 0x0020;
pub const cF_is_alert: u16 = 0x0040;
pub const cF_is_flashlight_on: u16 = 0x0080;
pub const cF_is_god_mode: u16 = 0x0100;
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
        .speed_forward = try r.readF32(),
        .speed_strafe = try r.readF32(),
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
    try writeEmptyPlayerDataFileNetwork(&w, 106, -273, 61, 449, &.{}, &.{}, &.{}, &.{}, true);
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
/// are real but the package is vestigial over the network in V3.0.1. Emitting it is
/// non-stock behavior (see docs/MISSING_FEATURES.md).
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

/// Default S→C: stock package envelope around intermediate height-plane payload.
pub fn buildChunkBody(buf: []u8, cx: i32, cz: i32, heights: *const [256]u8) ![]u8 {
    return buildChunkBodyStockEnvelope(buf, cx, cz, heights, true);
}

pub fn buildChunkBodyStockEnvelope(buf: []u8, cx: i32, cz: i32, heights: *const [256]u8, overwrite: bool) ![]u8 {
    if (buf.len < chunk_stock_envelope_overhead + chunk_body_size) return error.Overflow;
    var payload_buf: [chunk_body_size]u8 = undefined;
    const payload = try buildChunkPayload(&payload_buf, cx, cz, heights);
    var w: binary.Writer = .{ .buf = buf };
    try w.writeBool(overwrite);
    if (overwrite) {
        try w.writeI16(@intCast(cx));
        try w.writeI16(0); // cy
        try w.writeI16(@intCast(cz));
        try w.writeI32(@intCast(payload.len));
        try w.writeBytes(payload);
    }
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

/// Stock NetPackageSetBlock body (V3.0.1):
/// PlatformUserIdentifierAbs (bool + optional platform/id) |
/// i16 changeCount | BlockChangeInfo* | i32 localPlayerThatChanged
///
/// Minimal BlockChangeInfo: BlockValueRef(pos) + entityId + flags + BlockValue.
/// BlockValue: u32 rawData (type in low 16 bits) + u16 damage.
/// BlockValueRef type 1 = world position Vector3i.
const block_change_flag_value: u8 = 1; // bChangeBlockValue

/// Build one-change stock SetBlock (null platform user; peers accept S2C without id check).
pub fn buildSetBlockBody(buf: []u8, x: i32, y: i32, z: i32, block_id: u16) ![]u8 {
    return buildSetBlockBodyFull(buf, x, y, z, block_id, 0, 0);
}

pub fn buildSetBlockBodyFull(
    buf: []u8,
    x: i32,
    y: i32,
    z: i32,
    block_id: u16,
    changed_by_entity: i32,
    local_player_that_changed: i32,
) ![]u8 {
    return buildSetBlockBodyDamage(buf, x, y, z, block_id, 0, changed_by_entity, local_player_that_changed);
}

/// Authoritative SetBlock with absolute BlockValue.damage (stock DamageBlock path).
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
    var w: binary.Writer = .{ .buf = buf };
    try w.writeBool(false); // no PlatformUserIdentifierAbs
    try w.writeI16(1); // one BlockChangeInfo
    // BlockValueRef: type=1 (BlockPosition) + Vector3i
    try w.writeByte(1);
    try w.writeI32(x);
    try w.writeI32(y);
    try w.writeI32(z);
    try w.writeI32(changed_by_entity);
    try w.writeByte(block_change_flag_value);
    // BlockValue: type in low 16 of rawData, then absolute damage u16
    try w.writeU32(@as(u32, block_id));
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
    const has_user = try r.readBool();
    if (has_user) {
        _ = try r.readByte();
        try r.skipString();
        try r.skipString();
    }
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
    if ((flags & block_change_flag_value) != 0) {
        const raw = try r.readU32();
        ch.raw = raw;
        ch.block_id = @truncate(raw & 0xffff);
        ch.damage = try r.readU16();
        ch.has_value = true;
    }
    // density sbyte
    if ((flags & 4) != 0) _ = try r.readByte();
    // texture: TextureFullArray.Read(br, 1): typically one u64 when present.
    // Short stream must error, not silently succeed: later changes in the
    // batch would decode from a desynced offset as bogus world edits.
    if ((flags & 0x20) != 0) _ = try r.readU64();
    return ch;
}

pub fn framed(buf: []u8, name: []const u8, body: []const u8) ![]u8 {
    const id = idOf(name) orelse return error.UnknownPackage;
    return frame.framePackage(buf, 0, id, body);
}

test "setblock stock body roundtrip" {
    var buf: [64]u8 = undefined;
    const body = try buildSetBlockBodyFull(&buf, -10, 61, 400, 13, 106, 106);
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
    try wr.writeBool(false);
    try wr.writeBool(true); // firstTimeJoin
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
pub fn buildInventoryBodyStock(buf: []u8, inv: *const @import("../ecs/components.zig").Inventory) ![]u8 {
    return stock_inv.buildFromEcs(buf, inv);
}

pub fn buildInventoryBodyStockResolved(
    buf: []u8,
    inv: *const @import("../ecs/components.zig").Inventory,
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
    inv: *const @import("../ecs/components.zig").Inventory,
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
    try w.writeByte(if (ok) 1 else 0);
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
    blood_moon_warning: i32 = 8,
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
    storm_freq: i32 = 0,
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

/// Full persistent GameStats.Write matching V3.0.1 propertyList order.
pub fn buildGameStatsBodyValues(buf: []u8, v: GameStatsValues) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    // Reserve i16 length; fill after payload.
    try w.writeI16(0);
    const payload_start = w.pos;

    // propertyList order, bPersistent only (78 decls, 9 skipped). Types: 0=i32 2=string 3=bool.
    try w.writeI32(0); // GameState
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
    remaining_seconds: u8 = 0,
    /// temp, precip, cloud, wind, fog
    params: [5]f32 = .{ 70, 0, 0.2, 0.1, 0.05 },
};

/// Stock NetPackageWeather: no count prefix; client sizes from its biomeWeather.Count.
/// Emit one entry per biomemap biome we care about (same count both sides ideally).
/// RE: weather-environment.md §3 — biomeId u8, groupIndex u8, remainingSeconds u8, 5×f32.
pub fn buildWeatherBody(buf: []u8, biomes: []const WeatherBiome) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    for (biomes) |b| {
        try w.writeByte(b.biome_id);
        try w.writeByte(b.group_index);
        try w.writeByte(b.remaining_seconds);
        for (b.params) |p| try w.writeF32(p);
    }
    return w.written();
}

test "weather body five biomes is 115" {
    var buf: [256]u8 = undefined;
    var biomes: [5]WeatherBiome = [_]WeatherBiome{.{}} ** 5;
    var i: usize = 0;
    while (i < 5) : (i += 1) biomes[i].biome_id = @intCast(i + 1);
    const body = try buildWeatherBody(&buf, biomes[0..]);
    try std.testing.expectEqual(@as(usize, 115), body.len);
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

/// SimpleChat (legacy two strings). Prefer buildStockChat for stock clients.
pub fn buildChatBody(buf: []u8, from: []const u8, msg: []const u8) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeString(from);
    try w.writeString(msg);
    return w.written();
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

test "game event response never crashes on truncated request" {
    // Client-controlled body: must not panic on any prefix length.
    var full: [64]u8 = undefined;
    var fw: binary.Writer = .{ .buf = &full };
    try fw.writeString("ev");
    try fw.writeI32(1);
    try fw.writeString("x");
    try fw.writeString("y");
    const complete = fw.written();
    var out: [128]u8 = undefined;
    var len: usize = 0;
    while (len <= complete.len) : (len += 1) {
        // Either builds a valid response or errors cleanly; never UB.
        _ = buildGameEventResponse(&out, complete[0..len]) catch {};
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

pub fn buildStockChat(buf: []u8, sender_entity_id: i32, msg: []const u8) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeByte(0); // EChatType.Global
    try w.writeI32(sender_entity_id);
    try w.writeString(msg);
    try w.writeByte(0); // EMessageSender
    try w.writeByte(0); // BbCodeSupportMode
    try w.writeI32(0); // no recipient filter (broadcast)
    return w.written();
}

pub fn parseStockChat(body: []const u8) !struct { chat_type: u8, sender: i32, msg: []const u8 } {
    if (body.len < 6) return error.EndOfStream;
    var r: binary.Reader = .{ .data = body };
    const chat_type = try r.readByte();
    const sender = try r.readI32();
    var len: usize = 0;
    var shift: u6 = 0;
    while (true) {
        const b = try r.readByte();
        len |= @as(usize, b & 0x7F) << shift;
        if ((b & 0x80) == 0) break;
        shift += 7;
        if (shift > 28) return error.InvalidString;
    }
    if (r.pos + len > body.len) return error.EndOfStream;
    const msg = body[r.pos .. r.pos + len];
    return .{ .chat_type = chat_type, .sender = sender, .msg = msg };
}

/// NetPackageEntityAttach: attachType u8 | riderId i32 | vehicleId i32 | slot i16
pub const AttachType = enum(u8) {
    attach_server = 0,
    attach_client = 1,
    detach_server = 2,
    detach_client = 3,
};

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

/// NetPackageCloseAllWindows: playerId i32
pub fn buildCloseAllWindows(buf: []u8, player_id: i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(player_id);
    return w.written();
}

/// NetPackageGameMessage: msgType u8 | mainEntityId i32 | secondaryEntityId i32
pub fn buildGameMessage(buf: []u8, msg_type: u8, main_entity_id: i32, secondary_entity_id: i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeByte(msg_type);
    try w.writeI32(main_entity_id);
    try w.writeI32(secondary_entity_id);
    return w.written();
}

/// NetPackageLandClaimRepair: x/y/z as i64 + beginRepair bool
pub fn buildLandClaimRepair(buf: []u8, x: i32, y: i32, z: i32, begin_repair: bool) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI64(@intCast(x));
    try w.writeI64(@intCast(y));
    try w.writeI64(@intCast(z));
    try w.writeBool(begin_repair);
    return w.written();
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

pub fn buildNavObjectRemove(buf: []u8, nav_class: []const u8, entity_id: i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeString(nav_class);
    try w.writeString("");
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeBool(false); // isAdd = remove
    try w.writeBool(false);
    try w.writeU32(0);
    try w.writeBool(false);
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
};

pub fn parseExplosionInitiate(body: []const u8) !ExplosionInitiate {
    var r: binary.Reader = .{ .data = body };
    var out: ExplosionInitiate = .{};
    out.wx = try r.readF32();
    out.wy = try r.readF32();
    out.wz = try r.readF32();
    out.bx = try r.readI32();
    out.by = try r.readI32();
    out.bz = try r.readI32();
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
        _ = br.readI16() catch 0; // entityRadius
        _ = br.readI16() catch 0; // blastPower
        if (br.readF32()) |bd| {
            if (bd > 0 and bd <= 65535) out.block_damage = @intFromFloat(bd);
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

pub fn buildQuestOpBody(buf: []u8, def_id: u16, op: u8) ![]u8 {
    if (buf.len < 3) return error.Overflow;
    std.mem.writeInt(u16, buf[0..2], def_id, .little);
    buf[2] = op;
    return buf[0..3];
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

/// S2C empty FetchList: npc | player | eventType=0 | tier | entryCount=0
pub fn buildNpcQuestListEmptyFetch(buf: []u8, npc_entity_id: i32, player_entity_id: i32, tier_level: i32) ![]u8 {
    return stock_quest.buildNpcQuestListFetch(buf, npc_entity_id, player_entity_id, tier_level, &.{});
}

/// S2C FetchList with QuestPacketEntry offers (stock trader UI).
pub fn buildNpcQuestListFetch(
    buf: []u8,
    npc_entity_id: i32,
    player_entity_id: i32,
    tier_level: i32,
    entries: []const stock_quest.QuestPacketEntry,
) ![]u8 {
    return stock_quest.buildNpcQuestListFetch(buf, npc_entity_id, player_entity_id, tier_level, entries);
}

/// S2C ResetQuests: npc | player | eventType=2 (no extra fields)
pub fn buildNpcQuestListReset(buf: []u8, npc_entity_id: i32, player_entity_id: i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(npc_entity_id);
    try w.writeI32(player_entity_id);
    try w.writeByte(@intFromEnum(NpcQuestEventType.reset_quests));
    return w.written();
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
}

test "entity spawn response and teleport layout" {
    var buf: [64]u8 = undefined;
    const sr = try buildEntitySpawnResponse(&buf, true);
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

test "stock npc quest list empty fetch layout" {
    var buf: [32]u8 = undefined;
    const body = try buildNpcQuestListEmptyFetch(&buf, 50, 106, 0);
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

pub fn buildTraderTradeBody(buf: []u8, trader_entity: i32, item: u16, qty: u16, side: u8) ![]u8 {
    if (buf.len < 9) return error.Overflow;
    std.mem.writeInt(i32, buf[0..4], trader_entity, .little);
    std.mem.writeInt(u16, buf[4..6], item, .little);
    std.mem.writeInt(u16, buf[6..8], qty, .little);
    buf[8] = side;
    return buf[0..9];
}

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

/// Wire tool: op u8, then payload (see electric.PowerGrid.applyWireAction)
pub fn buildWireConnectBody(buf: []u8, a: u16, b: u16) ![]u8 {
    if (buf.len < 5) return error.Overflow;
    buf[0] = 1;
    std.mem.writeInt(u16, buf[1..3], a, .little);
    std.mem.writeInt(u16, buf[3..5], b, .little);
    return buf[0..5];
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
