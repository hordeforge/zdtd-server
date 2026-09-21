//! Package id subsystem: PackageName enum, the stable
//! default_mappings table, idOf lookup, VersionInfo, and the
//! PackageIds body builder.
//!
//! Split out of the packages.zig facade (same code, moved verbatim);
//! re-exported so existing `packages.idOf` / `packages.PackageName`
//! call sites keep working.

const std = @import("std");
const binary = @import("binary.zig");

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
