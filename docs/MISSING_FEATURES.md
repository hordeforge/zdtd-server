# Missing features (full gap inventory)

**Scope:** Goal A wire-compatible dedicated (stock client, EAC off), SoA ECS sim.  
**Not in scope:** mods, Harmony, 7dtd-apm, EAC-on clients, shipping TFP assets.  
**Baseline:** core loop playable (2026-07-23 STATUS); this file tracks residual
depth and scale, not join blockers.  
**Stock reference:** V3.1.0 RE under `../7dtd-research/docs/` (~194 NetPackage types).  
**Conflict rule:** [STATUS.md](STATUS.md) wins if a row here lags a shipped gate.

Each gap below is mapped to its now-available RE spec in [RE_GAP_CLOSURE.md](RE_GAP_CLOSURE.md).

This document is deliberately exhaustive. Status labels:

| Tag | Meaning |
|---|---|
| **HAVE** | Shipped enough to exercise with loadgen / unit tests / stock client |
| **PARTIAL** | Exists but not client-parity or incomplete sim (honest gaps below) |
| **MISSING** | Not implemented |
| **OUT** | Explicit non-goal |

---

## 0. Executive scorecard

**Living hub:** [STATUS.md](STATUS.md) · open backlog: [TODO.md](../TODO.md) · index: [INDEX.md](INDEX.md)  
**Tests:** **434** total (see STATUS for pass/fail) · stock join: green (0 NRE) · core play loop: **yes** (automated playtest pass=83 fail=0, soft residuals in STATUS) · full stock parity: **partial** (gaps below)

| Domain | Have | Partial | Missing (high) | Stock-client impact |
|---|---:|---:|---:|---|
| LiteNet + join | yes (password, rate limit, frag pump) | ordered hold, sequenced | Encryption* (optional) | joins clean |
| Package catalog | 190 names; 33/33 C2S | many S2C bodies shallow | editor/EAC/platform | play path covered |
| Terrain wire | stock Chunk.write + upper24 + DTM | dens residual, deco suppressed | full .ttc | POI textured; CGO green |
| Prefab TTS | types + density/TE/water/texture planes | part_* skip policy | name remap if tables diverge | houses from real TTS |
| Block world | columns + SetBlock + ZCH3 (.zch) + land claim | multi/meta depth | stability, falling | dig/build/persist |
| Inventory / TE / loot | PDF, TE, workstation sim, loot ECD bag, InvTx | lock contention depth | RecipeQueue C2S beyond TE | chest/craft/loot work |
| Entity sim | ECD spawn, entityclasses/groups, animals, EAI 2-task, grid A* | AI task depth | navmesh, more EAI tasks | fight/loot visible |
| Quests / traders | Quest.Write, multi-phase, TraderData v2, traderAlways | objective types, markup | dialog trees | journal + trade UI |
| Vehicles / power / turrets | attach, gravity clamp, place+WireActions, BFS | fuel/SoC, actuation | multi-seat stock bodies | place/wire/drive first cut |
| Content XML | blocks/items/entities/groups/recipes/loot/quests/traders | biomes.xml, vehicles.xml | gamestages, buffs | tables load |
| Persistence | ZCH3 `.zch`, players.zsv v2, containers.zct, blockmeta.zbm | vehicle/turret save | stock .ttc | restart keeps world+player |
| Admin / browser | admin TCP (kick/ban/give/tele/kill/…) + console | full telnet surface | Steam browser | ops usable |

**Honest bottom line:** core stock loop is playable under EAC-off (join, move,
dig/build, fight, death/respawn, loot, craft + workstation, trade, persist;
automated playtest pass=83 fail=0). Remaining work is **depth and scale**, not join.
Prefer missing over fakes. Best PARTIAL write-ups: §5.2.1 EAI, §6.1 quests,
electrical gaps, vehicle physics, blood-moon FX.

---

## 1. Network / LiteNet

| Item | Status | Notes |
|---|---|---|
| UDP bind / poll | HAVE | `litenet/linux_udp.zig` |
| ConnectRequest/Accept (game ordinals) | HAVE | property ids match game LiteNet |
| Reliable ordered channel | PARTIAL | window/retransmit + ACK-pumped multi-frag; ordered hold buffer deferred |
| Unreliable / sequenced channels | PARTIAL | unreliable send; sequenced first-cut channel 1 |
| MTU / fragmentation | HAVE | large chunks via sendReliable resume + pump_fn (14-37 KB POI) |
| C2S deflate envelope | HAVE | `frame.zig` inflates stock compressed batches (zlib/raw/gzip) |
| LiteNet Merged packets | HAVE | unpack `[prop][u16 len][subpacket]*` |
| Connect reject / full server | PARTIAL | peer slot limit; password reject `[0,0]` |
| Per-IP join rate limit | HAVE | ~500 ms/IP; loopback exempt |
| Disconnect / timeout cleanup | PARTIAL | alive flags; soft cleanup |
| NAT punch / Steam relay | OUT | later / never for open clone |
| EAC package path | OUT | residual RE only |

---

## 2. Join, auth, session

| Item | Status | Notes |
|---|---|---|
| Challenge `0xCA` + Guid16 echo | HAVE | |
| `NetPackagePackageIds` map | HAVE | **negotiated** 189-name list (full stock subset) |
| `NetPackagePlayerLogin` parse | PARTIAL | name/version fields; incomplete profile |
| `PlayerLoginAnswer` | HAVE | simple ok/fail string |
| `PlayerId` | PARTIAL | may not match stock body |
| `PlayerSpawnedInWorld` | PARTIAL | spawn coords; not full stock fields |
| `RequestToSpawnPlayer` | PARTIAL | ignores chunk view dim / profile v5 |
| Platform auth (EOS / Steam ticket) | MISSING | |
| Server password | HAVE | LiteNet Connect key (`ConnectionRequestCheck`); rejectInvalidPassword `[0,0]` |
| Encryption (`Encryption*`) | MISSING | optional platform RSA+AES residual (not ServerPassword; EAC-off OK) |
| Permission / admin flags | PARTIAL | admin TCP path; no in-game permission levels |
| Kick / ban / whitelist | PARTIAL | kick/ban/unban on admin TCP; no whitelist file |
| `ClientInfo` / version gate strictness | PARTIAL | soft version strings |
| Reconnect resume | PARTIAL | players.zsv v2 by name (pos/inv/journal); no platform id |
| Crossplay platform users | MISSING | |

---

## 3. Package surface (~194 stock vs ~189 zdtd)

### 3.1 Implemented names (zdtd `default_mappings`)

Join/core: PackageIds, PlayerLogin, PlayerLoginAnswer, PlayerId, PlayerSpawnedInWorld, RequestToSpawnPlayer, EntityPosAndRot, EntityRelPosAndRot, EntityAliveFlags, DamageEntity, EntityRemove, SetBlock, Chunk, WorldTime, SimpleChat, EntityLookAt.

Extended (simplified bodies): QuestObjectiveUpdate, NPCQuestList, TraderData, EntitySpawn, VehicleSpawn, VehiclePositions, VehicleDataSync, TurretSpawn, TurretSync, WireActions, WireToolActions.

### 3.2 Missing packages by functional area

Bodies and handlers are **MISSING** unless noted PARTIAL (name known in RE only).

#### World / terrain / deco
| Package | Priority for stock client |
|---|---|
| `NetPackageChunk` **stock layout** | HAVE (`stock_chunk.zig` + upper24; DTM + TTS; CGO green) |
| `NetPackageChunkRemove` / `ChunkRemoveAll` | PARTIAL (ChunkRemove key streaming; no RemoveAll) |
| `NetPackageChunkClusterInfo` | P2 |
| `NetPackageWorldInfo` / game mode / seed | HAVE (fixedSizeCC closes overlay gate) |
| `NetPackageBiomeIntensity` | PARTIAL (interleaved in chunk path) |
| `NetPackageDecoUpdate` / deco reset | PARTIAL (empty firstPackage only; trees suppressed for AssignIds skew; generateAroundIds kept) |
| `NetPackageWater*` (if any in build) | P2 |
| `NetPackageDynamicMesh` | P3 / skip headless |

#### Entity lifecycle
| Package | Priority |
|---|---|
| `NetPackageEntitySpawn` stock body + class id | PARTIAL (`stock_entity.zig` ECD networkWrite; Unity Mono class hashes; **zombie/NPC, item-drop, falling-tree, player (male/female), and the junk-drone tail** all implemented + tested; **all six branches now implemented**: zombie/NPC, item-drop, fallingBlock, fallingBlocks, fallingTree, player, plus the junk-drone tail; missing payload for a branch returns an error rather than a short body). ECD `write` is header + `entityClass` switch + networkWrite tail, verified against IL, see `../7dtd-research/docs/protocol-packages.md` 5.1 |
| `NetPackageEntitySpawnResponse` | P1 (builder shipped; place/throw only: never on join: client ProcessPackage calls ItemValue.ItemClass on empty item → NRE) |
| `NetPackageEntityTeleport` | P1 |
| `NetPackageEntityVelocity` / `EntitySpeeds` / `EntityPhysics` | P1 |
| `NetPackageEntityRotation` | P2 |
| `NetPackageEntityAnimationData` | P2 |
| `NetPackageEntityRagdoll` | P2 |
| `NetPackageEntityAttach` / detach | P1 (vehicles, seats) |
| `NetPackageEntityStatChanged` / stats / buffs | PARTIAL (join sends Health/Stamina/Food/Water stock body; buffs deferred) |
| `NetPackageEntityStealth` | P2 |
| `NetPackageEntityCollect` | P1 (loot) |
| `NetPackageEntityWaypointList` / map markers | P2 |
| `NetPackageEntityAddExp*` / skills | P2 |
| `NetPackageEntityAwardKillServer` | P2 |

#### Combat / hazards
| Package | Priority |
|---|---|
| `NetPackageDamageEntity` full field semantics | PARTIAL (head parse/build) |
| `NetPackageExplosionInitiate` / `ExplosionClient` | PARTIAL (initiate dig + client FX; nested blob shallow) |
| `NetPackageAddRemoveBuff` / `EntityStatsBuff` | P1 |
| `NetPackageEmitSmell` | P3 |
| Blood / infection / wetness packages | P2 |

#### Inventory / items / crafting
| Package | Priority for stock client |
|---|---|
| Player inventory sync family | HAVE (PDF + C2S PlayerInventory; client-authoritative hold) |
| `NetPackageHoldingItem` | HAVE (S2C echo) |
| Drop / pickup / bag containers | HAVE (loot ECD bag; Bag C2S-only) |
| Craft / recipe / unlock | PARTIAL (InvTx + workstation TE + unlock list) |
| Toolbelt / bag / equipment slots | HAVE |
| Item quality / mods / durability | PARTIAL (quality/meta in players.zsv v2; mods shallow) |
| Loot container open/close | HAVE (LockRequest + TE stream) |

#### Blocks / building
| Package | Priority |
|---|---|
| `NetPackageSetBlock` multi-block / shape / rotation | PARTIAL (multi parse; rotation meta sparse) |
| Block damage / upgrade / paint | PARTIAL (HP accumulate; upgrade/paint open) |
| `NetPackageAnimateBlock` / `BlockTrigger` | PARTIAL (BlockTrigger C2S handled) |
| Stability / support collapse | MISSING |
| Land claim / bedroll / keystones | PARTIAL (LandClaim options; bedroll open) |
| Door / hatch / storage open state | PARTIAL (chest open pair; generic door shallow) |

#### AI director / events / sleepers
| Package | Priority |
|---|---|
| Horde / blood moon client FX (`BloodmoonMusic`, `HordeEvent`, `BossEvent`) | PARTIAL (BloodmoonMusic wired; HordeEvent builder unwired, stock has no sender) |
| Sleeper volume activate | PARTIAL (AABB wake + authored markers) |
| Game events (`GameEventRequest/Response`) | PARTIAL (ack path) |
| Party / ally (`AllyRequest/Response`) | PARTIAL (echo first cut) |

#### Quests / traders / dialog (stock)
| Package | Priority |
|---|---|
| Full quest journal packages (not zdtd-native shapes) | PARTIAL (`stock_quest.zig` Quest.Write + NPCQuestList FetchList + SharedQuest; per-objective CurrentValue emitted from the phase graph; see §6.1 gaps) |
| Trader inventory stock format (stock TraderData) | PARTIAL (entity-id envelope + TraderData v2 primary entries now parse in the stock window; gaps below) |
| Dialog / NPC interaction | P1 |
| Quest POI marker / rally | P1 |

#### Vehicles / mounts
| Package | Priority |
|---|---|
| Stock vehicle packages (beyond simplified trio) | P1 |
| Fuel / storage / seats multi-occupant | P1 |
| Vehicle damage / parts | P2 |

#### Electricity / traps
| Package | Priority |
|---|---|
| Placeable stock electrical blocks (SetBlock → PowerGrid node) | HAVE |
| Stock `NetPackageWireActions` SetParent/RemoveParent → parent/child wiring | HAVE |
| Wired powered state (BFS flood from generators) | HAVE |
| `NetPackageWireToolActions` (visual handshake) | PARTIAL (peer rebroadcast only) |
| Powered door / light / trap blocks | PARTIAL (registered as consumers, no actuation) |
| Battery charge state | P2 |

**Landed (Electrical block placement parity):** when a player `SetBlock`s a
stock electrical block (`generatorbank`, `solarbank`, `batterybank`,
`electricwirerelay`, `autoTurret`, pressure plates, traps, …), a matching
`PowerGrid` node is registered at the block world position (`addNodeAt`,
idempotent) and dropped on removal (`removeAt`, compacts incident wires). Node
kind comes from the block `Class` in stock `blocks.xml`
(`src/ecs/powerblocks.zig`); watts are real block properties (`MaxPower` for
sources, `RequiredPower` for consumers, parsed in `maxdamage.loadFromBlocksXml`).
Real `NetPackageWireActions` bodies drive wiring: `SetParent` (op 0) connects
child→parent by world position, `RemoveParent` (op 1) drops the child's edges,
`SendWires` (op 2) is a visual no-op. Grounded in
`NetPackageWireActions::read`/`ProcessPackage` (asm.il:842779, 842922, 843021).

**Honest gaps (documented, not faked):**
- *Generator fuel*: `PowerGenerator` ramps output via
  `CurrentFuel`/`MaxFuel`/`OutputPerFuel`/`TickPowerGeneration` (asm.il:892750).
  zdtd treats a generator as constant `MaxPower` while `.on`. No fuel burn, no
  `ShouldAutoTurnOff`, no ramp.
- *Battery charge state*: `PowerItemTypes.BatteryBank` state-of-charge /
  charge-discharge is not modeled; `.battery` is a passive passthrough node.
- *Trigger/timer/toggle actuation*: PARTIAL. PressurePlate / TripWire /
  MotionSensor / Trigger are `is_trigger` gates: BFS powers the plate when
  wired, but does not flood past until `activateTriggerAt` (player step via
  `noteAcceptedMove`) sets `pulse_left` for `default_trigger_pulse_s`. Timer
  nodes still use `armTimer` periodic toggle. Gaps: Switch / ConsumerToggle
  interact C2S, stock TE ClientTriggerData wire, multi-parent directed edges.
- *RemoveParent precision*: stock removes exactly the child→parent edge
  (`PowerItem.RemoveSelfFromParent`, asm.il:843033). zdtd wires are undirected,
  so `removeParentAt` drops all edges incident to the node. Matches the common
  single-wire case; multi-parent topologies differ.
- *TileEntity wire-data persistence / SendWires visual path*
  (`CreateWireDataFromPowerItem`/`SendWireData`, asm.il:842993) is client visual;
  zdtd does not persist per-TE wire lists, only rebroadcasts the raw package.
- *AssignIds version skew*: the bundled `assignids_v314.txt` is V3.1.4 while the
  target client is V3.1.0(b14). If block ids differ, registry lookup silently
  no-ops (blocks place normally, just not power-registered). Supply a V3.0.1
  assignids dump for exact id parity. Registry also needs `blocks.xml` loaded.
- *Power accounting*: watts feed only the existing `resolve()` demand>gen
  consumer-drop heuristic. No per-branch `RequiredPower` summation up the parent
  tree, no `StackPower`/priority.

#### Chat / UI / config
| Package | Priority |
|---|---|
| `NetPackageChat` (vs SimpleChat) | P1 |
| `NetPackageGameMessage` / tips | P2 |
| `NetPackageConfigFile` / id mapping blocks-items | HAVE (LoadLocal list) |
| `NetPackageGameStats` | HAVE (full bPersistent blob; HUD day = WorldTime) |
| Console cmd client/server | P2 |
| XUi remote windows | P3 |

#### Auth / platform / misc
| Package | Priority |
|---|---|
| AuthState / AuthConfirmation | P1 |
| Discord / Twitch families | OUT / P3 |
| Editor / prefab editor packages | OUT |
| EAC | OUT |

**Gap size:** ~189/194 named (~97%). The named subset covers the full stock
client join + play path; remaining unnamed types are editor/EAC/platform.

---

## 4. World representation and maps

| Item | Status | Notes |
|---|---|---|
| Flat default world | HAVE | sea_level height plane |
| Stock DTM load (Navezgane/Pregen) | HAVE | u16 LE gameY×256, center origin |
| Spawnpoints.xml | HAVE | first spawn |
| prefabs.xml footprints | HAVE | AABB flatten + TTS interior paint |
| `.tts` full block paint | PARTIAL | types + density/damage/TE/water/texture planes; name remap if tables diverge |
| water_info.xml | PARTIAL | height hints only |
| biomes.png / radiation | PARTIAL | biomes.png color→biomemap; radiation MISSING |
| RWG / procedural gen | MISSING | baked maps only today; design WORLDGEN.md = **on-the-fly** per-chunk stream gen (MC density + WFC tiles; not static full bake; not stock RWG host) |
| Full block columns (16×256×16) | HAVE | dirt/stone/bedrock from height + TTS paint + ZCH3 `.zch` |
| Density / stability / shape / paint | PARTIAL | density channel; stability/falling MISSING |
| Stock layer model (`y>>2`) | PARTIAL | stock chunk encode path |
| Stock `NetPackageChunk` blob | HAVE | `stock_chunk.zig` + upper24; live CGO |
| `.ttc` region files | MISSING | custom ZCH3 `.zch` + blockmeta |
| RegionFileRaw headers / sectors | MISSING | RE partial |
| Chunk unload / streaming policy | PARTIAL | join r≤4 stream + resident cap 4096 LRU |
| Multi-block entities (doors) | PARTIAL | storage open pair; generic door meta shallow |
| Water flow / physics | MISSING | |
| Falling blocks | MISSING | |
| POI sleeper volumes from prefab | PARTIAL | AABBs + group/count + authored sleeper* markers. Gaps: gamestage, respawn, trigger cascade, quest/boss flags, pose |
| Land claim / bedroll spawn | PARTIAL | LandClaim options + keystone deny; bedroll ownership MISSING |
| World borders / difficulty tiers | MISSING | |

---

## 5. ECS simulation (entity systems)

### 5.1 Present components / systems

HAVE/PARTIAL: Transform, Health, NetworkId, Kind, Player, Journal, Wallet, ZombieAi, Vehicle, Turret, TraderStock, Flags; systems AI (LOD chase/melee), Director clock/hordes, vehicles stick, power BFS, turrets; parallel AI/turrets/save; max 512 entities.

### 5.2 Missing entity / AI features

| Item | Status |
|---|---|
| Entity class system (`entityclasses.xml`) | HAVE (`assets/entities.zig`) |
| Archetypes / gamestages / spawning.xml | MISSING |
| Animals / special infected / bosses | PARTIAL (animals spawner + cap; bosses MISSING) |
| EAI task graphs | PARTIAL (see 5.2.1) |
| Sleeper AI volumes | PARTIAL (prefab .tts/.nim markers) |
| Pathfinding (grid A* / navmesh) | PARTIAL (grid A* + BFS + greedy; no navmesh / vertical) |
| MoveHelper physics / collision | MISSING |
| Gravity / swimming / climbing | PARTIAL (void rescue teleport; vehicle gravity) |
| Line of sight / hearing / smell | MISSING |
| Stealth / crouch | MISSING |
| Group AI / pack behavior | MISSING |
| Despawn / cull by observer | PARTIAL (LOD + far-despawn >200 + alive-cap 24) |
| Entity pooling / soft cap policies | PARTIAL (MaxSpawnedZombies/Animals options) |
| Ragdoll / death loot bags | PARTIAL (loot ECD bag; no ragdoll) |
| XP / progression / skills | PARTIAL (awardXp ledger; skills MISSING) |
| Buffs / disease / food/water/temp | PARTIAL (join stats; buff packages shallow) |
| Inventory component | HAVE (toolbelt/bag/equip + InvTx) |
| Equipment / armor mitigation | PARTIAL (equip slots; mitigation shallow) |
| Projectile / ranged combat | MISSING |
| Block damage from zombies | PARTIAL (`tickZombieBlockDamage`) |
| Player respawn rules | HAVE (death → RequestToSpawnPlayer heal-when-dead) |
| Death / backpack | PARTIAL (DropOnDeath loot bag modes) |
| Party / allies | PARTIAL (echo first cut; PlatformUserId MISSING) |
| Spatial hash for queries | MISSING (broadcastNear radius only) |
| Dense free-list compaction | PARTIAL (scan free slots) |
| NetId → slot map (O(1)) | MISSING (linear scan) |
| Interest-aware tick budgets | MISSING |

#### 5.2.1 EAI task graphs (PARTIAL)

`AiCtx.work` (`src/ecs/systems.zig`) ports stock's prioritized task-selection
loop `EAITaskList::OnUpdateTasks` + `isBestTask` (asm.il:437713, :437874): an
ordered task table with `{priority, MutexBits, executeDelay, continuous}` per
task, "best task" selection by priority + mutex overlap, per-task re-eval
timer, and Start/Update/CanExecute/Continue hooks. The winning task is
projected onto the coarse `ZombieAi.state` enum so all downstream replication
stays unchanged. Two real tasks are registered:
ApproachAndAttackTarget (chase+melee, MutexBits=3, executeDelay=0.1,
non-continuous; asm.il:421798) and Wander (MutexBits=1, continuous;
asm.il:438104). Chase preempts wander on sensing a player; wander resumes when
the target is lost (mutex release), exactly reproducing stock's emergent order.

Honest gaps:

- **Grid A\* (no navmesh).** Approach replans via `path.aStarToward` on a
  coarse XZ grid when `World.solid_fn` is set (body-height solid from the block
  store); falls back to straight `stepToward` without a solid hook. Caps
  expansions (~96) and replan interval (~0.35 s) for the 20 TPS budget. No
  navmesh, no vertical climb/jump, no stock pathCounter/relocateTicks fidelity.
- **Four task types are real.** ApproachAndAttackTarget, ApproachSpot
  (`has_spot`/`spot_x`/`spot_z`, priority below chase, above wander; clears on
  arrive), Wander, and EAIBreakBlock (asm.il:425121): when chase A* finds no
  detour, `path_blocked` selects BreakBlock (mutex 0, holds `.chase` so
  `Game.tickZombieBlockDamage` chews cover). Still missing: EAIDestroyArea,
  EAIApproachDistraction (:423700, noiseSeekDist), EAITerritorial (:437973),
  and Look/Dodge/Leap/RangedAttack/RunAway. (There is no EAISeekSmell class in
  stock; do not add one.)
- **No data-driven per-class task graphs.** Stock builds the list from
  `entityclasses.xml` `AITask-N`/`AITarget-N` strings via
  `EAIManager::ParseTasks`/`CreateInstance` (asm.il:430620). No such XML is on
  hand, so priority/MutexBits/executeDelay/continuous are hardcoded in the
  comptime `zombie_tasks` table to mirror the stock zombie ordering.
- **Single-task executing set.** `executingTasks` is collapsed to one
  `active_task` TaskId. Exact for the current table (BreakBlock mutex 0 can
  switch with Approach via table order; movement tasks still exclusive), but a
  continuous non-conflicting task (e.g. EAILook) would need a task bitset.
- **Sensing collapsed.** The stock `targetTasks` list
  (EAISetNearestEntityAsTarget / corpse / SetAsTargetIfHurt sorter,
  asm.il:430171) is folded into the existing single-nearest-player sense
  (`nearestPlayerSnap`, `sense_dist_sq`). No multi-candidate sorting, corpse
  targeting, feralSense range scaling, or group/ally awareness.
- **Timing approximated.** The stock fixed 0.05s/20Hz tick and
  `executeWaitTime` accumulation are replaced by zdtd's variable
  `dt*active_scale` LOD throttle on `decision_cd`; `executeDelayScale` is fixed
  at the 0.85 base without the GameRandom jitter. Aggro persistence uses the
  coarse `alert` flag plus a "target entity still exists" check, not a
  `chaseTimeMax`/`homeTimeout` countdown.

### 5.3 AIDirector depth

| Item | Status |
|---|---|
| World clock + blood moon day%7 | PARTIAL |
| Night horde near players | PARTIAL (simple spawn) |
| Scout daytime | PARTIAL |
| Gamestage scaling | MISSING |
| Heat map / activity | MISSING |
| Wandering horde paths | MISSING |
| Feral sense / blood moon music sync | MISSING |
| Sleeper wake cascade | MISSING |
| Persistent director state save | MISSING |

---

## 6. Quests, traders, dialog

| Item | Status |
|---|---|
| Builtin 3 quests | HAVE (real phase graphs) |
| Load stock `quests.xml` catalog | PARTIAL (~defs mapped; many templates shallow) |
| Multi-phase objectives | PARTIAL (real ordered phase graph; see gaps below) |
| ClearSleepers volume clear | PARTIAL (kill counter drives the kill phase; no volume/spawn sim) |
| Fetch container / treasure | PARTIAL (fetch phase counter; no container/treasure sim) |
| RandomPOIGoto / rally markers | PARTIAL (Goto phase by location; RallyPoint auto-skipped, no marker) |
| TurnIn at correct trader NPC | PARTIAL (any trader open) |
| Stock quest wire packages | MISSING (zdtd-native journal body) |
| Localization.csv titles | MISSING |
| Reward choice / loot groups | MISSING |
| Trader tiers / quest_list offers | PARTIAL (lists parsed, not driven UI) |
| `traders.xml` inventory | PARTIAL (`traderAlways` direct items populate the stock TraderData window; group rolls skipped) |
| Duke tokens / currency stock | PARTIAL (coins wallet) |
| NPC dialog trees | MISSING |
| Challenges system | MISSING |

### 6.1 Multi-phase objective execution (honest gaps)

Quests now carry a faithful ordered phase graph (`QuestDef.phases`,
`highest_phase`, `objective_phases`), built from the objective `phase` attribute
or nested `<property name="phase">`. `QuestProgress` advances phase-by-phase
mirroring stock `Quest.refreshQuestCompletion` / `Quest.AdvancePhase`
(asm.il 983645-983904 / 982816): a phase completes when its tracked count
objective reaches the required value, then the sim advances; at the highest phase
a `TurnIn` quest becomes ready-turn-in (completed on trader interact) and an
`AutoComplete` quest completes. Legacy phase-less defs keep the single-kind path.
Remaining gaps:

- **One advancing objective per phase.** Stock `refreshQuestCompletion` requires
  ALL non-optional current-phase objectives complete. We track a single progress
  counter per phase (the highest-scored non-auto objective, e.g. `tier1_clear`
  phase 3 collapses ClearSleepers + POIStayWithin to ClearSleepers).
- **Phase-0 always-active objectives.** Stock counts `Phase==0` in every phase's
  check; missing-phase objectives are approximated as phase 1, not active across
  all phases.
- **Scaffolding phases auto-complete.** RallyPoint, POIStayWithin, UnlockPOI
  action, and empty intermediate phases map to `PhaseKind.auto` and complete on
  entry with no rally-marker network flow, StayWithin volume check, or POI unlock
  / FX (no assets).
- **Objective-type coverage.** Executed: ClearSleepers/EntityKill/AnimalKill
  (kill), Goto family (goto/trader), Fetch family + TreasureChest (fetch),
  InteractWithNPC/ReturnToNPC (trader-interact). Mapped to `auto` or ignored:
  Craft, Assemble, BlockPlace/Pickup/Activate/Upgrade, Repair, Scrap, Buff, Wear,
  Time, SkillsPurchased, GameEvent, TwitchVote, ExchangeItemFrom, OpenWindow.
- **Completed-phase wire value.** Completed objectives are sent as
  `CurrentValue=255` (>= typical client required). Objectives whose stock required
  Value exceeds 255 (large-radius / time) would display complete prematurely.
- **No fail / optional tracking.** `ForcePhaseFinish` → quest Failed and Optional
  `OptionalComplete` are not modeled; quests never auto-fail on phase timeout.

### Trader UI parity (stock `NetPackageTraderData`) honest gaps

The wire envelope now matches stock (`NetPackageTraderData.write`, asm.il
839492-839540): entity-trader packages emit `bool(true) + i32 entityId + bool
hasTraderData` and the entity id XORs the tePosition (no stray Vector3i), so the
already-correct full `TraderData` v2 body (`buildTraderDataStock`) parses and the
real `traderAlways` stock plus base econ prices show in the client window. Still
not stock:

- **Per-item markup / price drift**: stock adjusts `Entry.Markup` at runtime
  (Increase +100 on buy, Decrease -4 on sell, asm.il 856828-856866) from demand.
  zdtd always sends `Markup=0`, so prices are static base econ values with no
  supply/demand drift.
- **TierItemGroups**: stock `TraderData.TierItemGroups` (`List<ItemStack[]>`,
  written u8 count + WriteItemStack per group, asm.il 857562-857587) unlocks
  deeper stock as trader tier rises. zdtd always writes 0 groups: only the flat
  `traderAlways` PrimaryInventory shows, no tier-gated restock depth.
- **Trader wallet / economy**: `AvailableMoney` is a fixed placeholder pool
  (`trader_wallet_dukes = 5000`) that does not regenerate per stock-day, is not
  persisted, and is not spent on player sells (`trade()` credits the player
  wallet directly).
- **Restock depth**: `systems.traderRestock` grows every entry +10/day toward a
  flat cap of 50, ignoring stock per-item count ranges (`count="a,b"`) and
  marketTier/tender rules.
- **Group refs in `traders.xml`** (`<item group=...>`) are skipped by
  `assets/traders.zig` (only direct `<item name=...>` under `traderAlways`),
  so stock is a subset of stock's rolled-group inventory.

---

## 7. Vehicles, electricity, turrets, blocks as systems

| Item | Status |
|---|---|
| Vehicle kinds + enter/drive | PARTIAL (arcade physics) |
| Stock vehicle definitions XML | MISSING |
| Multi-seat / storage / fuel items | PARTIAL fuel float only |
| Vehicle collision / terrain stick | PARTIAL (server gravity + terrain-top clamp; no entity/block-side collision) |
| Placeable vehicle as entity spawn stock | PARTIAL |
| Power grid BFS | HAVE (flood from generators, demand>gen drop) |
| Placeable electrical blocks in world | HAVE (SetBlock → PowerGrid node, real watts) |
| Stock `NetPackageWireActions` SetParent/RemoveParent | HAVE |
| Wire tool stock UX packages | PARTIAL (WireToolActions = peer visual rebroadcast) |
| Battery charge / solar | PARTIAL (solar = generator node; no battery SoC) |
| Turret placeable block + power | PARTIAL (entity + node) |
| Ammo items / reload | PARTIAL (ammo counter) |
| Blade / junk turret variants | MISSING |

---

## 8. Inventory, items, crafting, loot

| Item | Status |
|---|---|
| Item id table from `items.xml` | HAVE (`assets/items.zig`) |
| Block id table | HAVE (AssignIds dump + `maxdamage`) |
| Recipes / crafting queue | PARTIAL (`assets/recipes.zig` + workstation) |
| Loot containers / `loot.xml` | HAVE (`assets/loot.zig`) |
| Quality / mods / durability | PARTIAL (quality/meta persist; mods shallow) |
| Stacking / bag size | PARTIAL (items.xml Stacknumber) |
| Workstation / forge / chemistry | PARTIAL (TE type 12 + 2Hz burn/craft; see WIRE_WORKSTATION) |
| Schematic unlocks | PARTIAL (always_unlocked recipe list on join) |
| Trader buy against real item defs | PARTIAL (traderAlways + EconomicValue; group rolls deferred) |

**Largest remaining “feels like a game” gaps:** AI path A*, quest objective
type coverage, power fuel/actuation, deco/AssignIds pin, M11 serialize-once.

---

## 9. Content / assets pipeline

| Asset | Status |
|---|---|
| quests.xml | PARTIAL loader |
| map_info + dtm + spawns | HAVE |
| prefabs.xml + tts sizes | PARTIAL |
| water_info.xml | PARTIAL |
| blocks.xml | HAVE (`maxdamage` MaxPower/RequiredPower, ids) |
| items.xml / item_modifiers | HAVE (`assets/items.zig`; modifiers partial) |
| entityclasses / entitygroups | HAVE (`assets/entities.zig`, `entitygroups.zig`) |
| biomes.xml / biomes.png | HAVE (colors + layers + biomes.png) |
| traders.xml | HAVE (groups + expand) |
| vehicles.xml | PARTIAL (load + spawn HP/speed) |
| gamestages / spawning | PARTIAL (spawning.xml → director groups; gamestages no) |
| buffs / progression | PARTIAL (catalog + passives + XP curve; no full VM) |
| recipes / loot | HAVE (`assets/recipes.zig`, `loot.zig`) |
| Localization.csv | MISSING |
| materials / physicsbodies | PARTIAL (materials MaxDamage via maxdamage) |
| sounds / music (server triggers) | MISSING |
| nav_objects.xml | MISSING |
| worldglobal / weathersurvival | MISSING |
| shapes / painting | PARTIAL (painting.xml atlas; shapes via AssignIds/TTS) |

Pattern for new loaders: `src/assets/<name>.zig` + fixture + `Game.init` resolve (see ASSETS.md).

---

## 10. Persistence and player data

| Item | Status |
|---|---|
| `.zch` height overlay | HAVE |
| Full chunk block save | HAVE (ZCH3 `.zch` u32 columns) |
| Stock region `.ttc` | MISSING |
| Player profile / inventory save | HAVE (players.zsv v2 quality/meta + journal) |
| Bedroll / last logout pos | PARTIAL (logout pos; bedroll ownership MISSING) |
| Map ownership / claims | PARTIAL (LandClaim keystone + deny) |
| AIDirector / sleeper save blobs | MISSING |
| Quest journal save | HAVE (players.zsv v2) |
| Vehicle / turret persistence | MISSING |
| Atomic save / backup rotation | PARTIAL (temp+rename on chunks; no backup rotation) |
| Multi-world / instance | MISSING |

---

## 11. Replication, interest, performance

| Item | Status |
|---|---|
| Broadcast all transforms | PARTIAL (except owner for PosAndRot; broadcastNear 160) |
| Spatial interest (chunk/grid) | PARTIAL (radius filter; no cell hash) |
| Serialize-once shared buffers | MISSING (M11 open) |
| Dirty flags (POS/ROT/FLAGS/HP) | PARTIAL (spawn dirty + known_entities; full bitset open) |
| RelPos vs PosAndRot bands | PARTIAL (client RelPos applied; server mostly PosAndRot) |
| Velocity packages | MISSING |
| Per-client byte budget | PARTIAL (WindowFull tiered soft-drop) |
| entityId → connection map O(1) | MISSING |
| NetId → slot hashmap | MISSING (linear scan) |
| Parallel AI / turrets / save | HAVE |
| Persistent thread pool | MISSING (spawn/join per forRanges) |
| Async region I/O | MISSING |
| Path worker pool | MISSING |
| Metrics apm harness | HAVE (`src/apm/`) |
| 128-bot scale bench harness | MISSING (loadgen mixed 2-bot green; 128 open) |

---

## 12. Admin, ops, hosting

| Item | Status |
|---|---|
| CLI port/world/map/game-dir | HAVE |
| serverconfig.xml stock | HAVE (`config.zig`; GAME_OPTIONS.md) |
| Telnet / web admin | PARTIAL (admin TCP session, not stock telnet) |
| Console commands (give, tele, …) | PARTIAL (in-game ConsoleCmd + admin TCP: kick/ban/give/tele/say/kill/inv/spawn/time/…) |
| Steam server browser listing | MISSING |
| Query protocol | MISSING |
| Logs / log rotation | PARTIAL (stdio) |
| Graceful shutdown save | HAVE (save tick + deinit persist) |
| Docker / systemd unit | MISSING |
| Config hot reload | MISSING |

---

## 13. Validation and client compatibility

| Item | Status |
|---|---|
| Unit / scenario tests | HAVE (**434** total; see STATUS for pass/fail pin) |
| Loadgen join bots | PARTIAL (join + walk + actions; stock chunk stream when `wire_chunks`) |
| Stock client join + stand | **PASS** (playtest-zdtd **pass=83 fail=0** pin; see STATUS) |
| Golden wire size checks | PARTIAL (some packages) |
| Capture regression suite vs stock | MISSING |
| Multi-version client matrix | MISSING |

---

## 14. Explicit non-goals (OUT)

Do not plan these as product features of zdtd:

1. Loading `Mods/`, Harmony, ModAPI, EfficientServer, RealEarth as runtime.  
2. Integrating **7dtd-apm** Mono bridge / bpftrace into the Zig process.  
3. EAC-signed multiplayer.  
4. Shipping TFP DLLs, prefab binaries, or bulk decompiled C#.  
5. Bit-identical blood-moon festivities / full Unity FX parity.  
6. Twitch integration, editor packages, dynamic mesh as required path.

---

## 15. Priority bands (post-playable)

**P0 join/play gate: CLOSED** (STATUS 2026-07-23). Do not re-open from stale rows.

### P1: Depth the client still notices
1. Deco/AssignIds pin (V3.0.1 dump or negotiate) so trees can return.  
2. Weather storm/bloodMoon group SM (defaults from biomes.xml on join+WorldTime throttle shipped).  
3. Path A* (or better than greedy) + more EAI task types.  
4. Quest objective-type coverage (Craft/StayWithin wired; Rally/UnlockPOI still auto).  
5. Power: full trigger TE wire (first-cut shipped: gate pulse + player step; Switch/TE ClientTriggerData still open).  
6. Workstation RecipeQueue C2S depth (lock contention shipped).

### P2: Multiplayer CPU (M11)
Dirty bitsets, serialize-once interest, persistent thread pool, O(1) NetId map,
32-128 bot apm gate. See IMPLEMENTATION_PLAN M11 + TODO near-term scale.

### P3: Ops and polish
Full telnet surface, Steam browser, party PlatformUserId, gamestages, buffs
depth, vehicle multi-seat, Encryption* (optional).

### P4: Planet scale (parked)
Gateway + shards after M11 numbers (PLANET_SCALE.md). DEM M1 proven.

---

## POI sleeper volumes: what lands, what stays a gap

Implemented (`src/world/sleepers.zig`, `Game.tickSleeperVolumes`):
- Volume AABBs, group name, and spawn min/max from the real prefab `.xml`
  (`SleeperVolumeStart` / `SleeperVolumeSize` / `SleeperVolumeGroup`), matching
  `PrefabVolumes.PrefabSleeperVolumeList::ReadFromProperties` (asm.il ~2498294):
  `#`-separated `Vector3i` list per volume; group is a comma-split flat token
  list read as name-only (count defaults 5,5) or `name,min,max` triples.
- **Authored spawn points**: positions of `Class=Sleeper` marker blocks read from
  the prefab voxel data (`.tts` types via `.blocks.nim` name map, block name
  prefix `sleeper*`), grounded in the stock block-scan
  (`Block.IsSleeperBlock -> SleeperVolume::AddSpawnPoint`, asm.il ~919380). Wake
  spawns one zombie per marker (capped to the requested count). When no `.tts` or
  no marker blocks are present, falls back to a deterministic AABB scatter.
- Group name resolves through the class table then the entitygroup table
  (`EntityGroups::GetRandomFromGroup`), else the default walker.

Honest gaps (no data path in zdtd, not faked):
- Gamestage / difficulty scaling of counts and entity variants (`gsScale=1` here).
- Sleeper respawn (`respawnMap`/`respawnTime`/`cRespawnNever`); one-shot `triggered`.
- Trigger types (`ETriggerType`) and volume-to-volume wake cascade
  (`SleeperVolumeTriggeredBy`); zdtd wakes purely on player-inside-AABB.
- Quest / boss / loot volume flags (`SleeperIsBossVolume`/`SleeperIsLootVolume`/
  `isQuestExclude`/`isPriority`/`SleeperVolumeGroupId`).
- Sleeper pose / rotation / look / `spawnMode` (Normal/Bandit/Infested) and
  `MinScript` (`SVS<i>`): only the marker position + entity class are wired.
- `spawnCountMin/Max < 0 -> 5,6` runtime reset: malformed-data only, not modeled.

## Blood-moon festivities client FX packages

Ground-truth audit of every FX package name associated with the blood-moon edge
in stock V3.1.0(b14) (decompiled Assembly-CSharp.dll). Wire formats cited to the
IL class/method they came from.

### Landed (real, IL-grounded)

- **`NetPackageBloodmoonMusic`** (`buildBloodmoonMusicBody`, packages.zig).
  Payload after the base header is a single `WriteBool(IsBloodMoonMusicEligible)`
  (1 byte), `PackageDirection=ToClient`, per `NetPackageBloodmoonMusic::write`.
  Wired on the blood-moon rising/falling edge in game.zig `step()` (every 20
  ticks, gated on `director.bloodmoon_active` vs `bloodmoon_sent`).
- **`NetPackageHordeEvent`** (`buildHordeEventBody` + `HordeEvent` enum,
  packages.zig). Payload is `Write((uint8)m_event)` then `m_pos.x/y/z` and
  `m_maxDist` as f32 = 17 bytes, per `NetPackageHordeEvent::write` (fields
  `m_event: AIDirector/HordeEvent`, `m_pos: Vector3`, `m_maxDist: float32`).
  Enum `AIDirector/HordeEvent`: `None=0 Warn1=1 Warn2=2 Spawn=3`. Client
  `EntityPlayerLocal.HandleHordeEvent` plays `Enemies/Horde/horde_spawn_warning`
  on Warn2 and `Enemies/Horde/horde_spawn` + camera shake on Spawn (stock audio
  banks, no custom assets). `ProcessPackage` fires only if
  `(localPos - m_pos).sqrMagnitude <= m_maxDist^2`.

### Honest gaps

- **`NetPackageHordeEvent` has no stock server sender (vestigial).** All 26 IL
  occurrences are inside the class body (818538-818735); there is no
  `GetPackage<NetPackageHordeEvent>()` anywhere in the assembly. The builder and
  client handler are real, but stock never emits the package. Auto-broadcasting
  it on the blood-moon edge would be **non-stock server behavior**, so it is
  deliberately NOT wired into game.zig. The builder is shipped for parity/opt-in
  use; wiring it is left as a documented, clearly-labeled hook, not stock parity.
- **`NetPackageHordeArmageddon` does not exist.** Grep of the IL for
  "Armageddon" finds no `NetPackage`; the name is absent from stock V3.0.1. Not
  implemented.
- **Feral sense is not an FX package.** It is `EAIManager.feralSense: float32`
  plus the `EnumGamePrefs.ZombieFeralSense` gamepref, applied at world/entity
  init, not sent on the blood-moon edge. Nothing to build.
- **`NetPackageBossEvent` is not blood-moon-driven.** It is the
  `GameEventManager` boss-group system (senders at IL 582104-584753, all inside
  `GameEventManager`), keyed on `BossEventTypes`. Out of scope; hooking it to the
  blood-moon edge would fabricate boss groups with no backing sim. Not wired.
- **`NetPackageBloodmoonMusic` per-player eligibility is not modeled (PARTIAL).**
  Stock `DynamicMusic.Conductor.Update` computes per-player eligibility from
  `EntityPlayer.bloodMoonParty` via `PlayerEligibleForBloodmoonCache` and targets
  each player individually. zdtd broadcasts one global bool. Pre-existing
  approximation, not a regression.

## Vehicle physics (terrain-follow + collision)

zdtd's server-authoritative vehicle sim (`src/ecs/systems.zig systemVehicles`)
is a zdtd extension: stock does NOT simulate vehicles server-side. Stock
`EntityVehicle` is Unity client-side (VPEngine, WheelColliders, Rigidbody);
`NetPackageVehiclePositions::ProcessPackage` (asm.il:841203-841225) only feeds
positions into the local player WaypointCollection, so the server relays
positions and never simulates. The clamped `transform.y` propagates unchanged
through the existing `broadcastVehiclePositions` (`src/server/game.zig`), no wire
change.

LANDED (feasible core):
- Vertical physics in `systemVehicles`: gravity accumulator
  `Vehicle.vy += cGravity * dt` with `cGravity = -9.81`
  (`EntityVehicle::cGravity`, asm.il:536018), plus a terrain-top clamp that
  prevents both sinking below and floating above the ground sample.
- Ground height via an optional ECS hook (`World.ground_fn`, `World.groundY`)
  that Game backs with the block store (`heightAtWorld` -> `Chunk.heightAt + 1`).
  Unset (headless / unit tests) means no terrain data, so physics is skipped
  and no fake flat floor is invented.

HONEST GAPS (Unity client-side in stock, no server representation / no assets):
- **Suspension / wheel / engine physics.** Stock drives a Unity VPEngine with
  rpm/rpmMax/rpmDrag, per-wheel motor/brake torque, Force/Motor triggers and
  WheelColliders (asm.il:535043 field block). The core keeps the arcade
  speed/steer integral in `vehicleControl` plus scalar gravity. Not reproduced.
- **Gyrocopter thrust / flight.** Stock lifts via input-up motor force
  (`EntityVehicle` Force/Trigger InputUp). The core ground-clamps the gyrocopter
  like every other kind, so it cannot ascend yet.
- **Entity-entity / block-side collision.** Stock uses Unity colliders and
  `EntityVehicle::FindCollisionEntity` via GetComponent/GetComponentInParent
  (asm.il:543188). The core does terrain-top collision only (no vehicle-vehicle,
  vehicle-zombie, or block-side collision).
- **Slope alignment (pitch/roll).** `Transform` carries only yaw
  (`src/ecs/components.zig`); the body stays axis-flat and does not tilt to
  terrain normals. The clamp follows height per (x,z) sample only.
- **Water buoyancy / fluid handling.** The height query treats the terrain top
  as the only surface.

## Related

| Doc | Role |
|---|---|
| [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) | Phased work to close gaps |
| [ECS.md](ECS.md) | Current sim architecture |
| [MAPS.md](MAPS.md) | Map load limits |
| [ASSETS.md](ASSETS.md) | Config load pattern |
| [SYSTEMS.md](SYSTEMS.md) | What systems exist today |
| [zig-clone.md](zig-clone.md) | M0-M6 architecture |
| [../../7dtd-research/docs/inventories/netpackages.md](../../7dtd-research/docs/inventories/netpackages.md) | Full package census |
| [../../7dtd-research/docs/protocol.md](../../7dtd-research/docs/protocol.md) | Wire facts |

## V3.1.0 wire note (2026-08-02)

`NetPackageTileEntity` now writes `teBlockId:i32` after world pos and uses **i32**
payload length (was u16). Stock RE: `../7dtd-research/docs/protocol-packages.md` §6.12
and `experimental-delta.md`.

**Implemented** in `src/wire/stock_te.zig` (`writeOuterTeHeader` /
`readOuterTeHeader`) for storage + workstation builders/parsers. Tests: 306/306.

