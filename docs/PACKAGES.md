# NetPackage catalog (stock V3.x, generated from parity_v3x.json)

Direction: ToServer=client→server (server MUST handle), ToClient=server→client
(server may send), Both=either. `handled` = a case in game.zig onData;
**Totals:** 190 stock catalog rows; 33 ToServer (all handled); handled cases 70; S2C emitted 46.  
**Join map:** `packages.default_mappings` has **189** names (runtime `package_maps=189`). Catalog and fixture map can drift slightly; regenerate via parity tooling rather than hand-editing.
`sent` = zdtd emits it S2C. Regenerate with ../7dtd-research/tools/parity + this script.

The `read wire (head)` column lists `BinaryReader` virtual calls only, so it
under-reports every package carrying a `PlatformUserIdentifierAbs`:
`PlatformUserIdentifierAbs::FromStream` is a static call and does not appear.
NetPackageAllyRequest shows `ReadBoolean;` but actually reads two identities and
then the bool (asm.il 886226). Same for NetPackageAllyResponse, NetPackageSetBlock
and NetPackagePlayerLogin. See `src/wire/platform_user.zig` for the real fields.

| Package | Dir | Handled(C2S) | Sent(S2C) | read wire (head) |
|---|---|---|---|---|
| NetPackageAddRemoveBuff | ? | handled |  | `ReadInt32;ReadString;ReadSingle;ReadBoolean;ReadInt32;SU.Rea` |
| NetPackageAllyRequest | ToServer | handled |  | `ReadBoolean;` |
| NetPackageAllyResponse | ToClient | handled |  | `ReadByte;ReadByte;ReadByte;` |
| NetPackageAnimateBlock | ToClient |  |  | `SU.ReadVector3i;ReadString;ReadInt32;ReadInt32;ReadBoolean;` |
| NetPackageAudio | ? | handled |  | `NetPackageEntityTargeted.read;ReadString;ReadBoolean;ReadSin` |
| NetPackageAudioPlayInHead | ToClient |  |  | `ReadString;ReadBoolean;` |
| NetPackageAuthConfirmation | ? | handled |  | `` |
| NetPackageAuthState | ToClient |  |  | `ReadString;` |
| NetPackageBag | ToServer | handled |  | `ReadInt32;ReadUInt16;get_BaseStream;SU.StreamCopy;` |
| NetPackageBiomeIntensity | ? |  |  | `BiomeIntensity.Read;` |
| NetPackageBlockLimitTracking | ? |  |  | `ReadInt32;ReadInt32;` |
| NetPackageBlockTrigger | ToServer | handled | sent | `SU.ReadVector3i;ReadUInt32;` |
| NetPackageBloodmoonMusic | ToClient |  | sent | `ReadBoolean;` |
| NetPackageBossEvent | ? | handled |  | `ReadInt32;ReadByte;ReadByte;ReadInt32;ReadString;ReadInt32;R` |
| NetPackageChat | ? | handled | sent | `ReadByte;ReadInt32;ReadString;ReadByte;ReadByte;ReadInt32;Re` |
| NetPackageChunk | ToClient |  | sent | `ReadBoolean;ReadInt16;ReadInt16;ReadInt16;ReadInt32;ReadByte` |
| NetPackageChunkClusterInfo | ToClient |  |  | `ReadString;ReadInt32;ReadInt32;ReadInt32;ReadInt32;ReadBoole` |
| NetPackageChunkRemove | ToClient |  | sent | `ReadInt64;` |
| NetPackageChunkRemoveAll | ToClient |  |  | `` |
| NetPackageClientInfo | ToClient |  |  | `ReadUInt16;ReadInt32;ReadInt16;ReadBoolean;` |
| NetPackageCloseAllWindows | ToClient | handled | sent | `ReadInt32;` |
| NetPackageConfigFile | ToClient |  | sent | `ReadString;ReadInt32;ReadBytes;` |
| NetPackageConsoleCmdClient | ToClient |  | sent | `ReadInt32;ReadString;ReadBoolean;` |
| NetPackageConsoleCmdServer | ToServer | handled |  | `ReadString;` |
| NetPackageDamageEntity | ? | handled |  | `ReadInt32;ReadByte;ReadByte;ReadUInt16;ReadByte;ReadInt16;Re` |
| NetPackageDebug | Both |  |  | `ReadInt16;ReadInt32;ReadInt32;ReadBytes;` |
| NetPackageDecoResetWorldChunk | ToClient |  | sent | `ReadInt32;get_BaseStream;SU.StreamCopy;` |
| NetPackageDecoResetWorldRect | ToClient |  |  | `ReadInt32;get_BaseStream;SU.StreamCopy;` |
| NetPackageDecoUpdate | ToClient |  | sent | `ReadBoolean;ReadInt32;get_BaseStream;SU.StreamCopy;` |
| NetPackageDeleteChunkData | ToClient |  |  | `ReadInt32;ReadInt64;` |
| NetPackageDirection | ? |  |  | `` |
| NetPackageDiscordIdMappings | ? | handled |  | `ReadBoolean;ReadInt32;ReadBoolean;ReadUInt64;ReadInt32;ReadI` |
| NetPackageDiscordLobbySecret | ToClient |  |  | `ReadByte;SU.ReadString;` |
| NetPackageDropItemsContainer | ToServer | handled |  | `ReadInt32;ReadString;SU.ReadVector3;` |
| NetPackageDynamicClientArrive | ToServer | handled |  | `ReadInt32;ReadInt32;ReadInt32;ReadInt32;` |
| NetPackageDynamicMesh | Both |  |  | `ReadInt32;ReadInt32;ReadInt32;ReadInt32;Read;` |
| NetPackageEAC | ? |  |  | `ReadInt32;ReadByte;` |
| NetPackageEditorAddVolumeFromClient | ToServer | handled |  | `ReadByte;ReadByte;SU.ReadVector3i;SU.ReadVector3i;ReadInt16;` |
| NetPackageEditorPrefabInstance | ToClient |  |  | `ReadByte;ReadInt32;SU.ReadVector3i;SU.ReadVector3i;ReadStrin` |
| NetPackageEditorUpdateVolume | ? |  |  | `ReadByte;ReadInt32;ReadInt32;ReadByte;PrefabVolumeAbs.Read;` |
| NetPackageEmitSmell | ? |  |  | `ReadInt32;ReadString;` |
| NetPackageEncryptionPublicKey | ? |  |  | `ReadString;ReadInt32;Read;ReadInt32;Read;` |
| NetPackageEncryptionRequest | ? |  |  | `` |
| NetPackageEncryptionSharedKey | ? |  |  | `ReadInt32;Read;ReadInt32;Read;` |
| NetPackageEntityAddExpClient | ToClient |  |  | `ReadInt32;ReadInt32;ReadInt16;ReadBoolean;` |
| NetPackageEntityAddExpServer | ToServer | handled |  | `` |
| NetPackageEntityAddScoreClient | ToClient |  |  | `ReadInt32;ReadInt16;ReadInt16;ReadInt16;ReadInt32;` |
| NetPackageEntityAddScoreServer | ToServer | handled |  | `` |
| NetPackageEntityAddVelocity | ToServer | handled |  | `ReadInt32;SU.ReadVector3;` |
| NetPackageEntityAliveFlags | ? | handled | sent | `NetPackageEntityTargeted.read;ReadUInt16;` |
| NetPackageEntityAnimationData | ? | handled |  | `NetPackageEntityTargeted.read;ReadInt32;` |
| NetPackageEntityAttach | ? | handled | sent | `ReadByte;ReadInt32;ReadInt32;ReadInt16;` |
| NetPackageEntityAwardKillServer | ToClient |  |  | `ReadInt32;ReadInt32;` |
| NetPackageEntityCollect | ? | handled | sent | `ReadInt32;ReadInt32;` |
| NetPackageEntityLookAt | ToClient |  |  | `NetPackageEntityTargeted.read;ReadInt32;ReadInt32;ReadInt32;` |
| NetPackageEntityMapMarkerRemove | ToClient |  |  | `ReadInt32;ReadInt32;SU.ReadVector3;ReadInt32;` |
| NetPackageEntityPhysics | ? |  |  | `ReadUInt16;ReadInt32;ReadSingle;ReadSingle;ReadSingle;ReadSi` |
| NetPackageEntityPosAndRot | ? | handled | sent | `NetPackageEntityTargeted.read;ReadSingle;ReadSingle;ReadSing` |
| NetPackageEntityPrimeDetonator | ToClient |  |  | `ReadInt32;` |
| NetPackageEntityRagdoll | ? |  |  | `ReadInt32;ReadByte;ReadSingle;ReadInt16;SU.ReadVector3;SU.Re` |
| NetPackageEntityRelPosAndRot | ? | handled |  | `NetPackageEntityRotation.read;ReadInt16;ReadInt16;ReadInt16;` |
| NetPackageEntityRemove | ToClient |  | sent | `NetPackageEntityTargeted.read;ReadByte;` |
| NetPackageEntityRotation | ? |  |  | `NetPackageEntityTargeted.read;ReadBoolean;ReadInt16;ReadInt1` |
| NetPackageEntitySetPartActive | ? |  |  | `ReadInt32;ReadBoolean;ReadString;` |
| NetPackageEntitySetSkillLevelClient | ToClient |  |  | `ReadInt32;ReadString;ReadInt32;` |
| NetPackageEntitySetSkillLevelServer | ToServer | handled |  | `` |
| NetPackageEntitySpawn | ToClient |  | sent (all ECD class branches) | `NetPackageEntityTargeted.read;EntityCreationData.read;` (ECD = header + entityClass switch + networkWrite tail; item-drop itemClass branch done) |
| NetPackageEntitySpawnResponse | ? |  |  | `ReadBoolean;ItemValue.Read;` |
| NetPackageEntitySpeeds | ? | handled | sent | `NetPackageEntityTargeted.read;ReadByte;ReadSingle;ReadSingle` |
| NetPackageEntityStatChanged | ? |  | sent | `NetPackageEntityTargeted.read;ReadInt32;ReadByte;ReadSingle;` |
| NetPackageEntityStatsBuff | ? | handled |  | `ReadInt32;ReadInt32;ReadBytes;` |
| NetPackageEntityStealth | Both |  |  | `ReadInt32;ReadUInt16;` |
| NetPackageEntityTeleport | ? | handled | sent | `` |
| NetPackageEntityVelocity | ToClient |  |  | `NetPackageEntityTargeted.read;ReadBoolean;ReadSingle;ReadSin` |
| NetPackageEntityWaypointList | ? |  |  | `ReadInt16;ReadInt32;ReadInt32;SU.ReadVector3;` |
| NetPackageEntry | ? |  |  | `` |
| NetPackageEventPrefab | ToClient |  |  | `ReadByte;` |
| NetPackageExplosionClient | ToClient |  | sent | `SU.ReadVector3;SU.ReadQuaterion;ReadInt16;ReadInt16;ReadInt1` |
| NetPackageExplosionInitiate | ToServer | handled |  | `SU.ReadVector3;SU.ReadVector3i;SU.ReadQuaterion;ReadUInt16;R` |
| NetPackageGameEventRequest | ToServer | handled |  | `ReadString;ReadInt32;ReadString;ReadString;ReadBoolean;ReadB` |
| NetPackageGameEventResponse | Both |  | sent | `ReadString;ReadInt32;ReadString;ReadString;ReadByte;ReadInt3` |
| NetPackageGameMessage | ? |  |  | `ReadByte;ReadInt32;ReadInt32;` |
| NetPackageGameStats | ToClient |  |  | `ReadInt16;get_BaseStream;SU.StreamCopy;` |
| NetPackageHoldingItem | ? | handled | sent | `ReadInt32;ItemStack.Read;ReadByte;` |
| NetPackageHordeEvent | ? |  |  | `ReadByte;ReadSingle;ReadSingle;ReadSingle;ReadSingle;` |
| NetPackageIdMapping | ToClient |  | sent | `ReadString;ReadInt32;ReadBytes;` |
| NetPackageInfo | ? |  |  | `` |
| NetPackageInventoryDataRequest | ToServer | handled |  | `KeyHashPair.Read;SU.ReadGuid;` |
| NetPackageInventoryDataResponse | ToClient |  | sent | `ReadBoolean;ReadString;SU.ReadGuid;SU.ReadGuid;` |
| NetPackageInventoryKeepOpen | ToServer | handled |  | `` |
| NetPackageInventoryTransactionRequest | ToServer | handled |  | `InventoryTransaction.Read;` |
| NetPackageInventoryTransactionResponse | ToClient |  | sent | `ReadBoolean;ReadInt32;SU.ReadGuid;ReadBoolean;` |
| NetPackageItemActionEffects | ? | handled | sent | `ReadInt32;ReadByte;ReadByte;ReadByte;ReadBoolean;SU.ReadVect` |
| NetPackageItemDrop | ToServer | handled |  | `ItemStack.Read;SU.ReadVector3;SU.ReadVector3;SU.ReadVector3;` |
| NetPackageItemReload | ? |  |  | `ReadInt32;` |
| NetPackageKeyExchangeComplete | ? |  |  | `ReadBoolean;` |
| NetPackageLandClaimRepair | ? | handled | sent | `ReadInt64;ReadInt64;ReadInt64;ReadBoolean;` |
| NetPackageLobbyJoin | ToClient |  |  | `PlatformLobbyId.Read;` |
| NetPackageLobbyRegisterClient | ToServer | handled |  | `PlatformLobbyId.Read;ReadBoolean;` |
| NetPackageLocalization | ToClient |  |  | `ReadInt32;ReadInt32;ReadInt32;ReadBytes;` |
| NetPackageLockRequest | ToServer | handled |  | `ReadBoolean;ReadUInt16;ReadInt32;ReadString;ILockContext.Rea` |
| NetPackageLockResponse | ToClient |  | sent | `ReadBoolean;ReadBoolean;ReadString;ReadBoolean;ReadUInt16;Re` |
| NetPackageMapChunks | ToClient |  |  | `ReadInt32;ReadUInt16;ReadInt32;ReadUInt16;` |
| NetPackageMapPosition | ToServer | handled |  | `ReadInt32;SU.ReadVector2i;` |
| NetPackageMeasure | ? |  |  | `` |
| NetPackageMetrics | ? |  |  | `` |
| NetPackageMinEventFire | ToClient |  |  | `ReadInt32;ReadInt32;ReadByte;ReadByte;ItemValue.Read;ReadUIn` |
| NetPackageModifyCVar | ? |  |  | `ReadInt32;ReadString;ReadSingle;ReadInt16;` |
| NetPackageNPCQuestList | ? | handled | sent | `ReadInt32;ReadInt32;ReadByte;ReadInt32;ReadInt32;QuestPacket` |
| NetPackageNavObject | ToClient |  | sent | `ReadString;ReadString;SU.ReadVector3;ReadBoolean;ReadBoolean` |
| NetPackageNetMetrics | ? |  |  | `ReadString;ReadString;ReadBoolean;ReadSingle;ReadBoolean;` |
| NetPackageOwnedEntitySync | ToClient |  |  | `ReadInt32;ReadInt32;ReadInt32;ReadByte;` |
| NetPackagePOIAround | ? |  |  | `ReadInt32;get_BaseStream;SU.StreamCopy;` |
| NetPackagePOIWaypoint | ToClient |  |  | `ReadByte;ReadInt32;ReadInt32;ReadBoolean;ReadInt32;` |
| NetPackagePackageIds | ToClient |  | sent | `VersionInformation.Read;ReadInt32;ReadString;ReadBoolean;Rea` |
| NetPackageParticleEffect | ? |  |  | `ParticleEffect.Read;ReadInt32;ReadBoolean;ReadBoolean;` |
| NetPackagePartyActions | ? | handled |  | `ReadByte;ReadInt32;ReadInt32;ReadString;` |
| NetPackagePartyData | ToClient | handled |  | `ReadInt32;ReadByte;ReadString;ReadInt32;ReadInt32;ReadInt32;` |
| NetPackagePartyQuestChange | ? |  |  | `ReadInt32;ReadByte;ReadBoolean;ReadInt32;` |
| NetPackagePersistentPlayerPositions | ToClient |  |  | `ReadInt32;SU.ReadVector3i;` |
| NetPackagePersistentPlayerState | ToClient |  | sent | `ReadByte;PersistentPlayerData.Read;` |
| NetPackagePickupBlock | ? |  |  | `SU.ReadVector3i;ReadUInt32;ReadInt32;` |
| NetPackagePlayerData | ToServer | handled |  | `` |
| NetPackagePlayerDenied | ToClient |  |  | `ReadInt32;ReadInt32;ReadInt64;ReadString;` |
| NetPackagePlayerDisconnect | ToServer |  |  | `` |
| NetPackagePlayerEquipment | ? | handled |  | `NetPackageEntityTargeted.read;Equipment.Read;` |
| NetPackagePlayerId | ToClient |  | sent | `ReadInt32;ReadInt16;ReadInt32;` |
| NetPackagePlayerInventory | ToServer | handled |  | `ReadBoolean;ReadBoolean;Bag.Read;ReadBoolean;ReadInt32;ReadI` |
| NetPackagePlayerInventoryForAI | ToServer | handled |  | `ReadInt32;` |
| NetPackagePlayerLaserSight | ? |  |  | `ReadInt32;ReadBoolean;SU.ReadVector3;` |
| NetPackagePlayerLogin | ToServer | handled |  | `ReadString;ReadString;ReadString;ReadString;ReadString;ReadU` |
| NetPackagePlayerLoginAnswer | ToClient |  | sent | `ReadBoolean;ReadString;PlatformLobbyId.Read;ReadString;ReadS` |
| NetPackagePlayerQuestPositions | ToServer | handled |  | `ReadInt32;ReadInt32;QuestPositionData.Read;` |
| NetPackagePlayerSetBackpackPosition | ToClient |  |  | `ReadInt32;ReadByte;SU.ReadVector3i;` |
| NetPackagePlayerSpawnedInWorld | Both |  | sent | `ReadInt32;SU.ReadVector3i;ReadInt32;` |
| NetPackagePlayerStats | ? | handled |  | `NetPackageEntityTargeted.read;EntityNetworkStats.read;` |
| NetPackagePlayerTwitchStats | ? |  |  | `NetPackageEntityTargeted.read;ReadBoolean;ReadBoolean;ReadBy` |
| NetPackagePlayerVendingMachine | ? |  |  | `ReadInt32;ReadInt32;ReadInt32;ReadBoolean;` |
| NetPackageQuestEntitySpawn | ToServer | handled |  | `ReadInt32;ReadString;ReadInt32;` |
| NetPackageQuestEvent | ? | handled | sent | `ReadInt32;SU.ReadVector3;ReadByte;ReadString;ReadInt32;ReadB` |
| NetPackageQuestGotoPoint | ? |  |  | `ReadInt32;ReadInt32;ReadByte;ReadString;ReadInt32;ReadInt32;` |
| NetPackageQuestObjectiveUpdate | ? | handled |  | `ReadInt32;ReadInt32;ReadByte;SU.ReadVector3i;` |
| NetPackageQuestTreasurePoint | ? |  |  | `ReadByte;ReadInt32;SU.ReadVector3i;ReadInt32;ReadSingle;Read` |
| NetPackageRangeCheckDamageEntity | ToClient |  |  | `ReadInt32;ReadByte;ReadByte;ReadSingle;ReadSingle;ReadSingle` |
| NetPackageRegionMetaData | ? |  |  | `ReadInt32;ReadInt32;ReadInt32;ReadInt32;ReadInt32;` |
| NetPackageRequestToEnterGame | ToServer | handled |  | `` |
| NetPackageRequestToSpawnEntity | ToServer | handled |  | `EntityCreationData.read;` |
| NetPackageRequestToSpawnPlayer | ToServer | handled |  | `ReadInt16;PlayerProfile.Read;ReadInt32;` |
| NetPackageSetAttackTarget | ? |  |  | `NetPackageEntityTargeted.read;ReadInt32;` |
| NetPackageSetBlock | ? | handled | sent | `ReadInt16;BlockChangeInfo.Read;ReadInt32;` |
| NetPackageSetBlockResponse | ? |  |  | `ReadUInt16;` |
| NetPackageSetBlockTexture | ? |  |  | `SU.ReadVector3i;ReadByte;ReadByte;ReadInt32;ReadByte;` |
| NetPackageSetProp | ? |  |  | `ReadInt16;PropChangeInfo.Read;ReadInt32;` |
| NetPackageSharedPartyKill | ? |  |  | `ReadInt32;ReadInt32;ReadInt32;ReadInt32;` |
| NetPackageSharedQuest | ? | handled | sent | `SharedQuestData.read;` |
| NetPackageShowToolbeltMessage | ToClient |  |  | `ReadString;ReadString;` |
| NetPackageSignDataRequest | ToServer | handled |  | `` |
| NetPackageSignDataResponse | ToClient |  | sent | `ReadBoolean;ReadInt32;ReadBytes;` |
| NetPackageSimpleChat | ? | handled |  | `ReadString;ReadInt32;ReadInt32;` |
| NetPackageSimpleRPC | ? |  |  | `ReadInt32;ReadByte;` |
| NetPackageSleeperPassiveChange | ToClient |  |  | `` |
| NetPackageSleeperPose | ? |  |  | `ReadInt32;ReadByte;` |
| NetPackageSleeperWakeup | ToClient |  |  | `ReadInt32;` |
| NetPackageSoundAtPosition | ? |  |  | `SU.ReadVector3;ReadString;ReadByte;ReadInt32;ReadInt32;` |
| NetPackageTeleportPlayer | ? |  |  | `ReadSingle;ReadSingle;ReadSingle;ReadBoolean;ReadSingle;Read` |
| NetPackageTileEntity | ? | handled | sent | V3.1.0: handle:u8, pos:Vector3i, teBlockId:i32, len:i32, payload |
| NetPackageTraderData | ToServer | handled | sent | `ReadBoolean;ReadInt32;SU.ReadVector3i;ReadBoolean;TraderData` |
| NetPackageTurretSpawn | ? | handled |  | `ReadInt32;SU.ReadVector3;SU.ReadVector3;ItemValue.Read;ReadI` |
| NetPackageTurretSync | ToClient |  |  | `ReadInt32;ReadInt32;ReadBoolean;ItemValue.Read;` |
| NetPackageTwitchAccess | ? |  |  | `ReadBoolean;` |
| NetPackageTwitchVoteScheduling | ? |  |  | `` |
| NetPackageVehicleCount | ? |  |  | `ReadInt32;ReadInt32;ReadInt32;` |
| NetPackageVehicleDataSync | ? | handled |  | `ReadInt32;ReadInt32;ReadUInt16;ReadUInt16;get_BaseStream;SU.` |
| NetPackageVehiclePositions | ? |  | sent | `ReadInt32;ReadInt32;SU.ReadVector3;` |
| NetPackageVehicleSpawn | ? | handled |  | `ReadInt32;SU.ReadVector3;SU.ReadVector3;ItemValue.Read;ReadI` |
| NetPackageWallVolume | ToClient |  |  | `ReadInt32;WallVolume.Read;` |
| NetPackageWallVolumeRemove | ToClient |  |  | `ReadInt32;` |
| NetPackageWaterSet | ? |  |  | `ReadInt32;ReadUInt16;WaterSetInfo.Read;` |
| NetPackageWaterSimChunkUpdate | ToClient |  |  | `ReadInt32;get_BaseStream;SU.StreamCopy;` |
| NetPackageWaypoint | ? |  |  | `Waypoint.Read;ReadByte;ReadInt32;` |
| NetPackageWeather | ToClient |  |  | `ReadByte;ReadByte;ReadByte;ReadSingle;` |
| NetPackageWireActions | ? | handled |  | `ReadByte;SU.ReadVector3i;ReadByte;SU.ReadVector3i;ReadInt32;` |
| NetPackageWireToolActions | ? | handled |  | `ReadByte;SU.ReadVector3i;ReadInt32;` |
| NetPackageWorldAreas | ToClient |  |  | `ReadByte;ReadInt16;TraderArea.Read;` |
| NetPackageWorldFolder | Both |  |  | `ReadInt32;ReadInt32;ReadInt32;ReadBytes;` |
| NetPackageWorldInfo | ToClient |  | sent | `ReadString;ReadString;ReadString;ReadString;ReadBoolean;Pers` |
| NetPackageWorldInitInfo | ToClient |  | sent | `ReadInt32;ReadInt32;ReadInt32;WallVolume.Read;` |
| NetPackageWorldInitInfoRequest | ToServer | handled |  | `` |
| NetPackageWorldSpawnPoints | ToClient |  | sent | `SpawnPointList.Read;` |
| NetPackageWorldTime | ToClient |  | sent | `ReadUInt64;` |
