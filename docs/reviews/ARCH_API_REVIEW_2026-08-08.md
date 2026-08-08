# API boundaries and facade review 2026-08-08

Audit of logical API boundaries in zdtd: the `Game` struct facade
(`src/server/game.zig`, 5155 lines at HEAD), the `game/*` + `c2s/*`
delegation pattern, asset loaders, the wire facade, package root barrels, and
a best-practices scan. Audited at HEAD `8638918` (branch main); fixes in this
commit are dead-code removal and doc/signature alignment only (no behaviour
moved). A sibling agent was concurrently editing `ecs/*`, `game.zig`,
`sleeper.zig` and `admin_console.zig`; their in-flight changes were not
touched or committed.

## 1. Game struct facade (src/server/game.zig)

The struct holds 277 functions at audit time (187 `pub`). The facade pattern
is healthy: the file is a delegating shell plus the handful of real
orchestrators. Classification:

| Kind | Count | Notes |
|---|---|---|
| (a) one-line forwarders to `game/*` or `c2s/*` | 76 | net (sendGame, broadcast, pollNetOnce...), player (awardXp, gameStageOf...), world (setBlockRaw, getBlockHp...), tick, join, quest, social, trader, loot, replicate, weather, hooks, deco |
| (a) forwarders to other server modules | 41 | admin_console (34), persist (6), serverinfo_tcp |
| (b) real bodies | 160 | dominated by init (905L), step (347L), distantDeco (305L), sendJoinBundle (185L), streamChunksForClient (98L) |
| (c) `pub` used only inside the facade | ~14 | see 1.2 |

### 1.1 Method surface by domain (277 methods, line ranges at HEAD)

| Domain | Methods (count) | Representative names |
|---|---|---|
| Init / lifecycle | 5 | create, createWithMap, createWithOptions, initWithOptions (905L), deinit (57L) |
| Movement / authority | 6 | authorityCorrects, noteAcceptedMove, resetMoveEnvelopePeer, applyMovementEnvelope (55L), tryActivateTriggerAtPlayer |
| Item / inventory helpers | 10 | itemStackFor, clampInventoryStacks, itemIsArmor, tryRefuelGenerator, eatProps, sendSurvivalStats, sendStaminaStats |
| Deco | 7 | decoSpeciesAt, decoOffsetsFor (dead, removed), mirrorDeco (20L), sendDecoAroundSpawn, worldSeed, decoRadiusFor |
| World / claims / block meta | 31 | registerClaim, removeClaimAt, markClaimsForEntity, expireClaims, maxDamageForBlock, packBlockKey (dead, removed), getBlockHp, setBlockHp, addBlockDamage, clearBlockHp, setBlockRaw, blockRawAt, clearBlockRaw, saveClock/restoreClock/saveWeather/restoreWeather/saveBlockMeta/loadBlockMeta (real bodies) |
| Persist / admin / console | 42 | playersPath, savePlayers, wipePlayerRecordsByName, tryRestorePlayer, pollAdmin, adminReply, handleConsoleCmd, runBanCommand, saveAdminLists, gamePref, saveEntities, saveClaims, reclaimForName, dumpEvidenceFile |
| Net send / poll | 16 | bindPort, clientFor, isUnreliablePackage, sendGame, sendGameCritical, sendGameBudget (dead, removed), sendReliablePumped, pollNetAfterSend, pollNetOnce, sendFramedUnreliable, sendFramedDroppable, broadcast, broadcastNear, broadcastExcept, trySendCompressed, sendFramedReliable |
| C2S dispatch | 6 | onConnected (39L), onData (38L), dispatchGamePayload (70L), handlePackage (45L), buildLoginGsiText, handleTrade |
| Lock / quarantine / evidence | 17 | packLockPos, firstLockTargetPos, clearLockSlot, clearLocksForPeer, peerIpKey, joinRateLimited, isBanned, banIp, unbanIp, noteEvidence (57L), applyQuarantine (30L), armPolicyKick, quarantineDenies, noteBlockBreak, takeInvToken, takeBlockToken, takeDamageToken, acceptChatRate, placeAllowed |
| Spawn / join bundle | 17 | spawnYNearPlayer, spawnSurface (39L), sendJoinBundle (185L), sendGameStats, gameStatsValues, broadcastGameStats, isStockClientQuestName, countJoined, buildTraderQuestOffers |
| Items / crafting / workstations | 9 | resolveItemType, reverseItemType, resolveWorkstationOutput, buildInventorySnap, sendItemIdMapping, sendHoldingOnlyEx, sendHoldingEcho, isStorageBlockId, storagePairId, tryCraft, tryCraftRecipe (61L), tickWorkstations (15L), handItemDamage |
| Spawn classes / gamestage | 8 | resolveSpawnClass, pickEntityGroup, biomeGroupName (30L), pickStageGroup, pickSpawnerGroup |
| Loot / sleeper / chunk stream | 26 | ecsIdFromItemName, fillLootBagFromTable, sampleFlushCounters, gatherPlayerPositions, tickSleeperVolumes, resolveSleeperClass, broadcastLootSpawn, broadcastItemDropSpawn, sendSpawnChunk (85L), scanChunkPower (31L), ensurePrefabStorageInChunk (90L), fillContainerFromLoot (40L), maybeRespawnContainer (31L), sendContainersInChunk (21L), clientHasStreamed, clientAddStreamed, clientRemoveStreamed, sendSpawnArea (37L), streamChunksForClient (98L) |
| Replicate / buffs / party | 18 | replicatePlayerHealth (48L), clientObserves, handleAddRemoveBuff, sendBuffSync, playerBuffBlob, relayBuff, broadcastBuffExpiries, replicate, clearDeadKnownEntities, handlePartyActions, broadcastPartySnapshot, broadcastPartyRemoval, clientByEntityId, acceptQuestFor, shareQuestWithParty, handleAllyRequest |
| Tick / weather / vehicle | 16 | step (347L), buildWeatherBodyFromBiomes, sendWeather, broadcastWeather, seatRider, unseatRider, sendSeatedRiders, broadcastVehiclePositions, broadcastTurretSync |
| Run loop | 2 | run (32L), applyDamage, setBlock, attachJoinedClient, attachJoinedClientAs (58L), injectFramed, replicateNow |

### 1.2 `pub` but only used internally (c)

All callers outside `src/server` are only: `create`, `createWithOptions`,
`deinit`, `run`, `step`, `applyDamage`, `bindPort`, `setBlock`, `infoPort`,
`fillWebuiSnap` (main.zig / fuzz.zig / store.zig). Everything else `pub` is
intra-package, which is fine for a facade, but these are `pub` with no caller
outside `game.zig` itself:

| Method | Line (HEAD) | Finding | Fix |
|---|---|---|---|
| `initWithOptions` | 599 (905L) | pub but only called by `createWithOptions` | could be private; keep pub for now (tests use it via create) |
| `sendFramedReliable` | 2892 (44L) | pub, only internal callers (2863, 2885) | make private |
| `clientFor` | 1945 | pub, only internal (2430, 2475, 5107) | make private |
| `clientObserves` | 4594 | pub, only internal (4583) | make private |
| `decoOffsetsFor`, `sendGameBudget`, `packBlockKey` | 1692, 1965, 2127 | **dead** (no callers anywhere) | removed in this commit |

`eatProps`, `packLockPos`, `firstLockTargetPos`, `stabilityAfterSetBlock`
are `pub` because `c2s/inv.zig` and `c2s/misc.zig` reach into the facade with
`const f = game_mod.Game.f;` aliases. That is the one facade smell in the C2S
layer: a c2s handler should import the owning shard (`game_world.packLockPos`)
or call through `self`. See 2.4.

## 2. game/* + c2s/* delegation

### 2.1 Pattern is consistent

Every `game/*` and `c2s/*` module takes `*Game` (or `*const Game`) first, is
called as `mod.fn(g, ...)`, and `game.zig` keeps a delegating method with the
same name. `c2s/*` handlers all expose one `handle(self, c, peer, name, body)
bool` and are chained from `Game.handlePackage` in a fixed order (join, move,
inv, quest, misc), phase-gated before dispatch.

### 2.2 Dead module-level duplicates (fixed in this commit)

Like the trade.zig copies removed at `8638918`, these module functions are
defined but never referenced as `mod.fn`; every caller uses the Game method.
All were removed:

| File | Dead fns (lines at HEAD) | Live twin |
|---|---|---|
| `server/trade.zig` | **whole file** (10 fns, 266L) | game.zig real bodies (handleTrade, applyTraderDataCopyFrom) + forwarders to game_trader / game_join |
| `server/chunk_stream.zig` | **whole file** (14 fns, 523L) | game.zig real bodies (newer copies) |
| `game/world.zig` | packLockPos (234), firstLockTargetPos (242), clearLockSlot (266), clearLocksForPeer (274) | game.zig methods (aliased by c2s/misc.zig) |
| `persist.zig` | reclaimForName (586), saveClock (605), restoreClock (617), saveWeather (645), restoreWeather (657), saveBlockMeta (680), loadBlockMeta (730) | game.zig methods (real bodies) |
| `game/join.zig` | sendHoldingEcho (562) | game.zig method (3709) |
| `game/deco.zig` | decoHeightAt (12) | join.zig private copy (38) |
| `game/hooks.zig` | itemIsArmor (144) | game.zig private fn (1642, wired at 750) |
| `game.zig` | decoOffsetsFor (1692), sendGameBudget (1965), packBlockKey (2127) pub forwarders | game_deco / game_net / game_world canonical fns |

Note: `persist.zig` is the *documented* home of the save/load fns (world.zig
header says so), but the live copies are the game.zig methods; the persist.zig
copies had already drifted (loadBlockMeta 31L vs game.zig 33L). The follow-up
should re-point the Game methods at persist.zig and delete the game.zig
bodies, or delete the persist.zig file entirely if not wanted there (2.5).

### 2.3 Root barrel and lint

`src/server/root.zig` aggregates every file in `src/server` including the
`game/*` and `c2s/*` subfolders, and `scripts/lint-architecture.sh` fails when
a file is missing from the barrel (fixed-string match on basename, one level
of subfolders). The barrel `test {}` block references every module so unit
tests aggregate. Verified green for all packages (util, apm, litenet, wire,
ecs, world, assets, plugin, server). After the file removals the barrel was
updated in the same commit.

### 2.4 C2S alias reach-in

`c2s/inv.zig` (`eatProps`, `stabilityAfterSetBlock`) and `c2s/misc.zig`
(`packLockPos`, `firstLockTargetPos`) alias Game methods/`game.zig` module fns
instead of importing the owning shard. Works, but it pins those helpers to the
facade; the shard (game_world) owns identical copies. Fix shape: delete the
game.zig methods, import `game_world` in the c2s files. Low priority (4 call
sites), flagged for the extraction pass.

### 2.5 Duplicated save/load direction

`world.zig` header says save/load "intentionally left in persist.zig and not
duplicated here", but the live save/load bodies are in game.zig and persist.zig
holds stale copies (now removed). Decide the canonical home:
- Option A: game.zig forwards to persist.zig (matches documented intent; move
  the 7 bodies back out of game.zig).
- Option B: keep bodies in game.zig, delete persist.zig save/load and the
  header claims.
Recommendation: A, as part of a persist extraction shard, but it is code
movement and was out of scope here.

## 3. Assets loaders (src/assets/*)

The convention is consistent across 20 of 22 loaders:
`tryLoad(allocator, game_dir, config_dir[, extra...]) !?T` (file missing →
`null`, parse error → error) and `loadFromPath(allocator, path) !T`. Findings:

| Finding | Location | Severity | Fix shape |
|---|---|---|---|
| `tryLoad` returns `?T` (no error union), swallows errors with `catch null` | `npc.zig:16`, `traders.zig:16` | medium | **fixed**: `!?T` + `try` at the 2 game.zig call sites (fail closed on corrupt XML) |
| `tryLoad` without `config_dir` | `signs.zig` (signs come from prefabs root) | low | intentional; note in doc |
| extra params (`id_by_name`, `is_distant_deco` callbacks) | `biome_layers.zig`, `blocks.zig`, `block_textures.zig` | low | intentional (id resolve at load); consistent within file |
| extra params (`map_dir`, `quests_path`) | `quests.zig` | low | intentional (quests live in the map dir) |
| `loadFromBlocksXml` instead of `loadFromPath` | `maxdamage.zig:505` | low | name is descriptive (parses blocks.xml + merges materials); keep |
| `tryLoad`/`tryLoadTable` pair | `progression.zig` | low | two different table shapes (LevelCurve vs Table); fine |
| `tryLoadConfig(comptime...)` centralizes path resolution + XML patch overrides | `paths.zig` | good | single choke point; all loaders go through it |

## 4. Wire facade (src/wire/packages.zig, 3532 lines)

Healthy: zero allocator use in any builder (verified across `src/wire/*`; the
only `alloc` calls are in `stock_nameid.zig` tests), caller-owned `buf` +
returned written slice, `parseXxx(body) !T` mirror naming, ids resolved via the
negotiated map, `lint-architecture.sh` enforces every `stock_*.zig` re-export.

| Finding | Location | Severity | Fix shape |
|---|---|---|---|
| `buildXxxBody` naming not universal: `buildEntitySpawnResponse`, `buildGameEventResponse`, `buildEntityAttach`, `buildStockChat`, `buildInvTxRequest`, `buildInvTxResponseHead`, `buildInvDataResponseNotFound`, `buildLockResponse*` (4), `buildConsoleCmdClient`, `buildWorldSpawnPoints`, `buildChunkPayload` | packages.zig | low | rename to `...Body` for consistency; touches many call sites so left as follow-up |
| Buffer contract implicit (documented in AGENTS.md, not the file) | packages.zig header | low | **fixed**: added a 3-line contract note |
| `buildChunkPayload` vs `buildChunkBody` both exist | 1081/1093 | low | documented (payload vs full stock envelope, test/loadgen helper); keep |
| error sets: most `![]u8` (inferred), 4 parsers explicit `binary.ReadError!T` | packages.zig | low | consistent enough; explicit where Reader errors dominate |

## 5. util / apm / litenet facades

All three barrels aggregate every leaf and the lint covers them; leaves do not
import their own package root (no cycles). Notable: `util/root.zig`,
`apm/root.zig`, `litenet/root.zig`, `wire/root.zig`, `ecs/root.zig`,
`world/root.zig`, `assets/root.zig`, `plugin/root.zig` all pass the
"files not mentioned in root.zig: []" check. `wire` leaves are imported via
`packages.zig` (28 refs) with `binary`/`frame` directly importable (documented
exception).

## 6. Best-practices scan

| Finding | Location | Severity | Fix shape |
|---|---|---|---|
| `@ptrCast(@alignCast(ctx.?))` callback-context cast is the dominant pattern (10x in hooks.zig, 5x in deco.zig, stock_deco tests) | game/*, wire | low | standard for `?*anyopaque` callbacks; no change |
| Numeric `@truncate` in SIMD chunk pack/unpack is intentional narrowing | stock_chunk.zig (25x) | low | justified; no change |
| `ctx orelse return 0` vs `ctx.?` inconsistency in callback casts | deco.zig vs hooks.zig | low | stylistic; unify to `ctx orelse return default` |
| 5 nested `fn lookup(ctx, name) ?u16` idByName callbacks (TerrCtx/NimCtx/IdCtx x3) with near-identical bodies | game.zig 877-1176 | low | could share one callback factory; not worth the generic indirection |
| `less` sort comparators duplicated (block_raw vs block_hp) | game.zig 2255/2275 | low | identical shapes; a generic `lessByKey` helper could share, low value |
| `bitOf` / `bitOfPeerSlot` module-level helpers exported for shards | game.zig 107/113 | ok | live (replicate.zig uses both) |
| Misleading-name candidates | none found | - | names checked against AGENTS naming rule; `chunk_stream_radius_*` etc. are accurate |

## 7. Ordered next extractions (2-3 shards, each < 200 lines of body)

Do these only after the sibling's in-flight ecs/game.zig work lands. Each is
pure move + forwarder (game.zig keeps delegating methods), same shape as the
existing shards.

1. **`game/chunk_stream.zig` (revive) — chunk send/stream, ~285 body lines**
   `streamChunksForClient` (98), `sendSpawnChunk` (85), `sendSpawnArea` (37),
   `sendContainersInChunk` (21), `clientHasStreamed` (8), `clientAddStreamed`
   (20), `clientRemoveStreamed` (11). Slightly over 200 because the bodies are
   what they are; alternatively split `sendSpawnChunk`+`sendSpawnArea` into
   `game/chunk_send.zig` first.
2. **`game/chunk_fill.zig` — stream-side chunk prep/fill, ~280 body lines**
   `ensurePrefabStorageInChunk` (90), `scanChunkPower` (31),
   `fillContainerFromLoot` (40), `maybeRespawnContainer` (31), `lootSeedAt`
   (10), plus the `def`/`onTe`/`at`/`tex`/`dens` chunk-TE helpers (~75).
3. **`game/craft.zig` — crafting + workstations, ~140 body lines (under 200)**
   `tryCraftRecipe` (61), `tryCraft` (5), `tickWorkstations` (15),
   `resolveWorkstationOutput` (14), `handItemDamage` (7), `tryRefuelGenerator`
   (14), `eatProps` (10), `itemIsArmor` (12).
   Then, after those: join bundle (`sendJoinBundle` 185 alone fits the limit;
   `attachJoinedClientAs` 58, `sendBlockIdMapping` 60 follow), and the
   persist save/load re-point (2.5).

## 8. Fixes applied in this review (all trivially safe)

| Commit | Change |
|---|---|
| a6c7fc5 + b8509fe | delete dead `server/trade.zig` (10 fns), drop barrel entry |
| f4cae2a + 6d4e029 | delete dead `server/chunk_stream.zig` (14 fns), drop barrel entry + unused c2s/inv import, fix join.zig header claim |
| b78e8bd | remove 14 dead module-level duplicates (world/persist/join/deco/hooks/game.zig) |
| 1dd61aa | npc/traders `tryLoad` → `!?T`, propagate errors at call sites |
| this commit | packages.zig buffer-contract doc note + this review |

`zig build` and `zig build test` green after each change (test run includes the
sibling's uncommitted ecs edits).
