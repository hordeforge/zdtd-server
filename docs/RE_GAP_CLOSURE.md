# RE gap closure: research specs for zdtd's open items

**Purpose:** map each PARTIAL/MISSING item in [`MISSING_FEATURES.md`](MISSING_FEATURES.md)
to the reverse-engineering doc that now fully specifies it, so a gap can be closed
against a spec instead of guesswork. The stock RE corpus at `../7dtd-research/docs/`
was expanded to cover every dedicated codepath (2026-07 pass); this bridges it to
the clone.
**Rule (from AGENTS):** wire/sim facts come from RE; fix zdtd to match RE, never the
reverse. Implement missing behavior on the server, not via client workarounds.

Paths below are relative to this repo: `../7dtd-research/docs/<file>`.

---

## 1. Join, auth, encryption

| zdtd gap | Now specified in | What the spec gives |
|---|---|---|
| `NetPackagePlayerLogin` parse (incomplete profile) | `protocol.md` §5 (Login body) | full field order: playerName, platform+cross user/token streams, versionLong, compVersionLong, discordUserId:u64 |
| `RequestToSpawnPlayer` (ignores chunkViewDim / profile v5) | `protocol.md` §5 | chunkViewDim:i16 + PlayerProfile v5 (archetype/isMale/race/variant/hair.../eyeColor) + nearEntityId:i32 |
| `PlayerSpawnedInWorld` (not full stock fields) | `server-lifecycle.md` §3 + `protocol.md` §5 | join -> PlayerSpawnedInWorld(cInfo, respawnReason, pos, entityId) sequence |
| **Platform auth (EOS/Steam ticket) MISSING** | `platform-auth.md` §1-3 | identity model (`PlatformUserIdentifierAbs`, Steam u64+ticket, EOS ProductUserId+JWT); the 5-stage `IAuthorizer` chain (Native 400, Crossplat 490, EAC 600, EncAgreement 601, Finalizer 999); wire form `present:bool,version:byte,platform:string,id:string,token:string`; `EKickReason` values |
| **Encryption (`Encryption*`) MISSING** | `protocol-packages.md` §2 | the 4-package handshake: EncryptionRequest(empty) -> EncryptionPublicKey(paramsXml + len-prefixed Hash + SignedHash) -> EncryptionSharedKey(len-prefixed EncryptionKey + IntegrityKey) -> KeyExchangeComplete(bool); all `AllowedBeforeAuth`; cipher/KDF native |
| **Crossplay platform users MISSING** | `platform-auth.md` §1 | ClientInfo carries PlatformId + CrossplatformId; InternalId = EOS-preferred |
| Version gate strictness (soft) | `protocol.md` §3-4 (PackageIds, version blob) | Version(release:u8,major:i32,minor:i32,build:i32); id-map is server-advertised |

---

## 2. NetPackage bodies (channels + wire)

The full per-package census (channel/compress/direction/before-auth) is
`protocol-packages.md` §1; regenerate with `../7dtd-research/tools/NetProtocolCensus`.
Key facts zdtd should honor:

- **Channel 1 band** (bulk, several compressed): `NetPackageChunk`, `ChunkRemove`,
  `MapChunks`, `DynamicMesh`, `POIAround`, `WorldFolder` (`protocol-packages.md` §1.1).
- **8 compressed packages** set `get_Compress` themselves even on the bot path (§1.2).

| zdtd gap | Now specified in | What to build |
|---|---|---|
| `NetPackageEntitySpawn` stock body + class id (**complete**) | `protocol-packages.md` §5.1 | `EntityCreationData.write` is 3 sections. **Header (all entities):** readFileVersion:byte, entityClass:i32, id:i32, lifetime:f32, pos/rot 3xf32, onGround, BodyDamage.Write, stats(bool+EntityStats), deathTime:i16, bag(bool+Bag), homePos 3xi32, homeRange:i16, spawnerSource:byte. **entityClass switch:** itemClass -> belongsPlayerId:i32, clientEntityId:i32, itemStack.Write, sbyte(0); fallingBlock/fallingBlocks -> BlockValue arrays + positions + TextureFullArray; fallingTree -> blockPos(3xi32) + fallTreeDir(3xf32); playerMale/Female -> holdingItem, teamNumber:u8, entityName/skinTexture:string, playerProfile(bool + PlayerProfile v5); **zombie/NPC/animal -> nothing.** **Tail (all):** entityData(u16+bytes), traderData(bool+Write), if networkWrite: sleeperPose:u8, isSleeper:bool, spawnById:i32, spawnByName:string, spawnByAllowShare:bool, headState:u8, overrideSize/HeadSize:f32, isDancing:bool, **(only if isSleeper) isSleeperPassive:bool**; then **outside the networkWrite guard**, (if junkDrone) belongsPlayerId:i32 + orderState:i32. **zdtd:** zombie, item-drop, fallingTree, player, and the junkDrone tail implemented + tested in `src/wire/stock_entity.zig`; class names taken from the `EntityClass.Init` ldstr literals; fallingBlocks writes ONE count shared by all three arrays (rawData / Vector3i / TextureFullArray-as-i64); a missing branch payload errors instead of emitting a short body. |
| `NetPackageDamageEntity` full fields (PARTIAL) | `protocol.md` §6.5 + `combat-damage.md` | full write order (entityId,damageSource:u8,damageType:u8,strength:u16,...,attacker,dirV 3xf32,blockPos 3xi32,hitTransform...,armor slots,stun,...); `EnumDamageTypes` 16=Suffocation |
| stats/buffs body (buffs deferred) | `entity-stats.md`, `buffs.md`, `protocol-packages.md` | EntityBuffs add/remove net (name,duration,instigator); survival stat sync |
| `NetPackageChunkRemove` (RemoveAll open) | `protocol-packages.md` §3.2 | chunkKey:i64 (WorldChunkCache packed x,z); channel 1, ToClient |
| `NetPackageSetBlock` rotation meta sparse | `blocks.md` (BlockValue bitfield) | `BlockValue.rawData` u32: type 0-15, rotation 16-20, meta3 bit21, meta 22-25, meta2 26-29, ischild 30, hasdecal 31; +damage as u16 (6 bytes on wire, not 4) |
| `NetPackageTileEntity` | `experimental-delta.md` §2 / protocol-packages §6.12 | **V3.1.0 stock:** handle:u8, teWorldPos:Vector3i, teBlockId:i32, len:i32, payload. Implemented in `src/wire/stock_te.zig` |
| Chat body | `chat.md` §1 | chatType:u8(EChatType 0Global/1Friends/2Party/3Whisper/4Discord), senderEntityId:i32, msg:string, msgSender:u8, bbMode:u8, recipientEntityIds:i32 count+i32[] |
| `NetPackageWorldInfo` join descriptor (**audit-corrected**) | `protocol-packages.md` §4.2 | gameMode/levelName/gameName/guid:string, ppList(bool+PersistentPlayerList.Write), ticks:u64, fixedSizeCC:bool, firstTimeJoin:bool, **worldHashes: i32 COUNT + count x { filename:string, hash:u32 }** (NOT a byte-length blob), worldDataSize:i64 |
| `ItemValue` packing (**audit-corrected**) | `items.md` §2 | each Stats entry is **`byte` PassiveEffects type + `i16` value(0 if boosted) + `i16` boosted(0 if not)** (3 fields, not 2); CosmeticMods count/rows skipped for `ItemClassModifier` (same guard as Mods) |
| `NetPackageDynamicMesh` (if pursued) | `dynamic-mesh.md` §5 | channel 1, compressed, Both; X/Z/UpdateTime/len/bytes (2 MiB cap); per-client one-outstanding via empty-package acks; `NetPackageDynamicClientArrive` reconciles UpdateTime deltas. **Region persistence (`.group`) is deflate-compressed via `DynamicMeshRegionDataStorage.SaveRegion`, NOT the dead `WriteRegion` version-160 format** (`dynamic-mesh.md` §4) |

---

## 3. Server systems (sim parity)

| zdtd gap | Now specified in | What to build |
|---|---|---|
| Craft / recipe / unlock (PARTIAL) | `crafting-recipes.md` | Recipe.CanCraft (ingredients+unlocked+tier); RecipeQueueItem craft-time; consume->produce(ModifyValue by tier)->XP; unlock via progression |
| Item quality / mods / durability (mods shallow) | `items.md` + `inventories/item-actions.md` | ItemValue packing (marker, flags byte, type/UseTimes/Quality/Meta, typed meta, stats, nested Modifications+CosmeticMods); durability = UseTimes vs MaxUseTimes |
| Block damage / upgrade / paint (upgrade open) | `blocks.md` | `OnBlockDamaged` -> `DestroyedResult` {None0,Keep1,Downgrade2,Remove3}; negative damage = repair-to-upgrade |
| Spawning (biome/horde) if pursued | `spawning.md` | 5 spawn sources funnel through World.SpawnEntityInWorld; AIDirector.CanSpawn gate (EnemyCount<MaxSpawnedZombies); observer-gated NetPackageEntitySpawn on interest entry |
| Buffs sim | `buffs.md` | EntityBuffs.Tick counts BuffValue.DurationInTicks; expire -> EntityStats recalc; death/tag removal; netSync add/remove |
| Progression / XP | `progression.md` | AddLevelExp -> recursive level-up -> skill points -> SpendSkillPoints(CanPurchase) -> RefreshPerks |
| Power (electricity) | `tile-entities-power.md` | PowerManager root forest in power.dat, ~6.25 Hz tick, greedy depth-first full-requirement-or-off |
| Parties / factions | `parties-factions.md` | party (session, max 8, shared XP `startingXP*(1-0.1*inRange)`); faction standing matrix in factions.dat; ally handshake |
| Quests | `quests-challenges.md` | template/instance; NotStarted->InProgress->ReadyForTurnIn->Completed; objective mini-machines; rewards per ReceiveStages |

---

## 4. Staying current

The RE is pinned to stable V3.0.1. After a game update, run
`../7dtd-research/tools/parity/drift-check.sh` (or the `drift-watch.sh` daemon): it
reports changed packages / types / enums so this table and the affected zdtd bodies
can be revised. The experimental branch already differs (see
`../7dtd-research/docs/experimental-delta.md`: `NetPackageTileEntity` widened,
held-entity feature), so version-gate the wire where noted.

---

## Related

| Doc | Role |
|---|---|
| [MISSING_FEATURES.md](MISSING_FEATURES.md) | The gap inventory this closes against |
| [PACKAGES.md](PACKAGES.md) | zdtd's package implementation status |
| `../7dtd-research/docs/INDEX.md` | Full stock RE hub |
| `../7dtd-research/docs/protocol-packages.md` | Per-package wire bodies + census |
