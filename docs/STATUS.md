# Status: stock-client join and play path

**Date pin:** 2026-08-04  
**Game line:** V 3.x Mono (connected client **V3.1.0 b14**; bundled AssignIds dump byte-matches this client's runtime block ids), EAC off  
**Unit tests:** `zig build test` → **199+** (binary direct; `--listen=-` may false-fail)  
**Policy:** proper stock wire/sim only; missing preferred over fakes (see residual gaps)

This is the hub for "what works now" vs `MISSING_FEATURES.md` (full inventory) and
`IMPLEMENTATION_PLAN.md` (phased plan). Doc index: [INDEX.md](INDEX.md).

**Conflict rule:** if STATUS and MISSING/IMPLEMENTATION_PLAN disagree on whether a
gate or feature shipped, **STATUS wins**. Refresh the inventory docs when closing
work; do not re-open a STATUS PASS from a stale MISSING row.

---

## Gates (evidence loop)

| Gate | State | Evidence |
|---|---|---|
| Stock client join (zdtd-connect auto) | **PASS** | 2026-08-04: `fixedSizeCC=false` + stream r≥6; spawn hb `cgo=68/39` (viewDist 7), terrainReady, xuiReady; overlay gate clear |
| NullReference on join | **PASS** | 0 NRE; ChunkCalc alive (no CalcDominantBiome OOB) |
| Client mesh (CGO) | **PASS** | CGO 68 ≥ 39; Chunks:192; stream r 6..8, 8 adds/tick, max_streamed=169 |
| Terrain floor textures (MicroSplat) | **PASS** | `fixedSizeCC=false` → FromRaw loads splat*.png (not Dummy); surface id 8=terrBurntForestGround; grey clay was null splat controls |
| POI/construction block textures | **PASS** | u32 rawData + upper24 when bits 8..31 set; TTS paint+density; non-terrain density ≥0; filler skipped on paint |
| serverconfig gameplay options | **PASS** | difficulty/bloodmoon/PvP/day-length/max-zombies parsed + applied (docs/GAME_OPTIONS.md) |
| Parity batch 2026-07-23 | **PASS (partial cores)** | POI sleeper volumes from prefab .tts/.nim, blood-moon BloodmoonMusic builder (HordeEvent builder unwired: stock has no sender), electrical block placement + WireActions, vehicle terrain gravity/ground-clamp, trader stock TraderData wire, quest multi-phase objective graphs, EAI prioritized task graphs, in-game console commands. All PARTIAL with documented gaps (MISSING_FEATURES.md); 239/239 tests |
| Quest PDF load | **PASS** | no `Failed loading` after RewardItem ItemStack wire |
| Unit tests | **PASS** | 239/239 (binary direct; `--listen=-` may false-fail) |
| C2S hardening | **PASS** | join-phase gate; Bag ownership; damage cap+fatal-vs-NPC only; SetBlock/Explosion/TE reach 96; respawn heal only when dead |
| Interest fan-out | **PASS** | broadcastNear 160 blocks for SetBlock/Explosion/loot spawn; pw19 kill soak Items:3, no near-skip misfires |
| Player death → respawn | **PASS** | admin kill → EntityStatChanged hp=0; RequestToSpawnPlayer heal + PlayerSpawnedInWorld(died) + join bundle; playtest `player_respawn` PASS 2026-08-03 |
| Entity spawn-on-approach | **PASS** | per-client known_entities bitset; ECD spawn on first range entry (director hordes, sleeper wakes, roaming); pw27 soak green |
| Player persist v2 | **PASS** | players.zsv v2 (quality/meta + journal); join PDF carries restored toolbelt/bag; pw27 axe q1 persisted through restart+rejoin. Note: client inventory is client-authoritative (C2S PlayerData/PlayerInventory overwrite server sim), so only items the client actually holds persist; server-side `give` is a loot-bag drop for this reason |
| TE/block persist | **PASS** | containers.zct + blockmeta.zbm save/load on save tick + shutdown; unit roundtrip test; pw19 restart rejoin green (files present, join CGO:25, 0 WRN) |
| Player save merge | **PASS** | savePlayers keeps offline records (was TRUNC joined-only) |
| Trader XML stock | **PASS** | traders.xml traderAlways direct items + items.xml EconomicValue prices (assets/traders.zig; group rolls deferred) |
| Director class variety | **PASS** | zombie slots 1+8..11 from entitygroups weighted picks; rotation per spawn |
| Zombie population bound | **PASS** | alive-cap 24 + far-despawn (>200 blocks, reason=Despawned); pw27 Ent stable 3-4 vs prior 7→34 creep |
| ItemValue/Explosion wire | **PASS** | ReadData + ExplosionData positional per IL (no remaining() or scan heuristics); unit tests |
| Loot bag wire direction | **PASS** | NetPackageBag dir=ToServer(1); S2C sends removed; loot rides ECD `bag` field in EntitySpawn; pw15 kill 100/101/102 → Items:3, zero WRN/NRE in client log |
| Loadgen join + walk + dynamite | **PASS** | flat + Navezgane; 2-bot mixed 100% passRate, walks>0, ExplosionInitiate; pw21 2-bot wander 100% alongside live stock client (walks=495, zero client WRN) |
| EntityRemove reason byte | **PASS** | body=entityId:i32+reason:u8; pw14 admin `kill 100/101/102` no NCSimple underrun; Items:2 loot bags |
| Automated in-client playtest | **PASS join + demo partial (2026-08-03)** | V3.1.0 pin + admin fixture parity. Latest `playtest-zdtd` → **pass=77 fail=6** (2026-08-04c; dig/place/loot/craft PASS). Residual: CGO 35/39, block dmg, food, trader buy, generator place. See [PLAYTEST_V310_20260803.md](PLAYTEST_V310_20260803.md). |
| C2S package coverage | **PASS 33/33** | every client→server package handled (parity tool: 0 unhandled dir=1); 190-pkg catalog docs/PACKAGES.md |
| Full playable stock dedi | **PASS (core loop); demo partial** | join → in-game (0 NRE) → move/build → fight → death → respawn → loot/craft/trade/persist **partial**. Automated demo residual: craft queue/trader buy client path, explosion close-in. Weather S2C from biomes.xml defaults; GameStats full persistent blob (HUD day from WorldTime). Cosmetic: deco trees (AssignIds). Not full-stock parity. |

Scratch one_shot logs (implementer): `STATUS-*.md` under session scratch; canonical
product notes stay in this file + linked docs.

---

## Architecture (unchanged boundaries)

```text
loadgen  → demand
apm      → measure (zdtd native `src/apm/`, not 7dtd-apm)
optimizer / server-guard / realworld → separate repos
zdtd     → Zig dedi, client wire only, no mods
```

---

## Shipped (HAVE / solid PARTIAL)

### Network / join

| Item | Location | Notes |
|---|---|---|
| Dual-port GSI TCP + LiteNet port+2 | `server/` | Stock connect |
| ServerPassword (LiteNet Connect key) | `litenet/server.zig`, `packet.zig` | GetString key vs password; reject `[0,0]` |
| Challenge 0xCA, PackageIds map | `wire/`, `litenet/` | Dynamic package names |
| C2S deflate + LiteNet Merged | `wire/frame.zig`, `litenet/` | Post-join C2S parse |
| PlayerLogin / LoginAnswer / enter / spawn | `server/game.zig` | EnterMultiplayer respawn type |
| PlayerId PDF (ECD + inv/equip/empty journal) | `wire/packages.zig`, `stock_inv.zig` | Spawn at real coords |
| ConfigFile LoadLocal list | `game.zig` | Stock xmlsToLoad names |
| WorldTime, deco first package | `stock_deco.zig` | DistantDecoTree via `idByName` (skip if dump miss) |

### World / terrain

| Item | Location | Notes |
|---|---|---|
| DTM height load (Navezgane etc.) | `world/dtm.zig` | center origin |
| Full columns biome layers + AssignIds terrain ids | `world/store.zig`, `assets/biome_layers.zig` | biomes.xml first `<layers>`; dirt=5 stone=1 bedrock=4 water=240 |
| `.zch3` chunk persist (u32 rawData) | `world/store.zig` | ZCH2 u16 dropped on load (regen from DTM+TTS) |
| Stock `NetPackageChunk` write path | `wire/stock_chunk.zig` | full rawData upper24; density repair rules; TTS dens; topsoil broken all-1s; light 0xFF |
| Spawn/stream ring for light+mesh | `server/game.zig` | join/stream r 6..8, 8 adds/tick, max_streamed=169; WorldInfo fixedSizeCC=**false** |
| biomes.png color→biomemap id | `world/biomes.zig` | stock biomemapcolor keys; id&lt;50; height fallback |
| Prefab footprints + water | `world/prefabs.zig`, `water.zig` | height flatten |
| **TTS paint (rawData+tex+density)** | `world/tts.zig`, `prefabs.zig` | skip terrainFiller; rotation bits kept |
| AssignIds pins + dump merge | `assets/assignids_comptime.zig`, `maxdamage.zig` | cwd + /proc/self/exe paths |
| Catalog loaders (XML) | `assets/*` | blocks ids=dump only; biomes colors; painting; spawning; buffs+passives; progression attrs/perks; vehicles; storage pairs; traders groups |
| Shared I/O | `util/linux_fs`, `assets/paths` | no copy-paste readFileAll / tryLoad |
| Seed chest AssignIds | `stock_deco.zig` | cntWoodenChestClosed from dump |
| Place item→block | `ecs/inventory` + Game.place_fn | name→AssignIds (wood→frameShapes:cube) |

### Inventory / containers / loot

| Item | Location | Notes |
|---|---|---|
| Stock PDF inventory apply | `stock_inv.zig` | toolbelt/bag/equip |
| HoldingItem, bag, drops | `stock_inv.zig`, `game.zig` | Bag/PlayerInventory C2S-only; S2C echo = HoldingItem |
| LockRequest grant + TE re-send | `packages.zig`, `game.zig` | always-grant (contention deferred) |
| Storage TE composite stream | `stock_te.zig` | place + chunk path |
| Workstation TE (type 12) | `stock_te.zig`, `world/workstations.zig` | ver 50 arrays + queue Recipe parse; 2Hz burn/craft tick, output materialized via items table, dirty S2C re-broadcast; see WIRE_WORKSTATION.md |
| InvData by Guid, transactional inv | `game.zig`, `containers.zig` | |
| Death/turret loot DroppedLootContainer ECD | `stock_entity.zig` | loot stacks embedded in ECD `bag` (Bag.Write) |

### Entities / combat

| Item | Location | Notes |
|---|---|---|
| Stock ECD EntitySpawn (zombie hashes) | `stock_entity.zig` | zombieBoe default class; join + interest |
| Stock ECD EntitySpawn (item-drop) | `stock_entity.zig` | `class_item` itemClass branch: belongsPlayerId/clientEntityId/itemStack + trailing sbyte; byte-offset round-trip test |
| Stock ECD EntitySpawn (player / falling-tree / junk-drone) | `stock_entity.zig` | player branch (holdingItem, teamNumber, entityName, skinTexture, PlayerProfile v5), fallingTree (Vector3i + Vector3), junk-drone tail (belongsPlayerId + orderState, outside the networkWrite guard); unimplemented classes error instead of emitting a short body; 9 tests |
| Client HUD Zom (EnemyCount) | n/a | **Always 0 on MP client**: stock `GameStateManager` sets EnemyCount only when `bServer`; ephemeral, not in `GameStats.Write` / `NetPackageGameStats`. Gate spawn health on **Ent** (World.Entities.Count), not Zom. |
| EntitySpeeds / AliveFlags fan-out | `packages.zig`, `game.zig` | |
| EntityTeleport (PosAndRot body) | `packages.zig` | |
| EntityAttach vehicle enter/exit | `packages.zig` | AttachServer/DetachServer |
| Damage + EntityRemove + loot | `game.zig`, `packages.zig` | EntityRemove = entityId:i32 + reason:u8 (EnumRemoveEntityReason; default Killed=2); admin `kill <id>` via `--admin-port` |
| LiteNet WindowFull | `game.zig` sendGame | tiered: streaming pkgs soft-drop ~8ms; critical join/state pkgs retry ~120ms (dropped SignDataResponse = "Starting Game" wedge); pw22 soak zero drops, join+loot green |
| ItemActionEffects rebroadcast | `game.zig` | multiplayer FX |
| AI director hordes / sleepers (sim) | `ecs/` | not full POI volumes |
| Zombie move speeds from XML | `assets/entities.zig`, `ecs/systems.zig` | MoveSpeedAggro/MoveSpeed via extends chain → class_table → AI; consts fallback |
| Zombie attack damage from XML | `assets/{entities,items}.zig` | HandItem → items.xml Action0 DamageEntity → class_table.attack_damage; const fallback |

### Quests / traders / chat

| Item | Location | Notes |
|---|---|---|
| Quest NavObject markers | `game.zig` sendQuestNavObjects | stock class names from nav_objects.xml |


| Item | Location | Notes |
|---|---|---|
| Stock quests.xml catalog | `assets/quests.zig` | objective/reward kinds |
| Quest.Write + journal v5 | `stock_quest.zig` | RewardItem = index + ItemStack |
| Starter in PlayerId PDF | `game.zig` | client-known `quest_*` / `tier*` names |
| NPCQuestList FetchList + QuestPacketEntry | `stock_quest.zig` | trader offers |
| SharedQuest forward/accept | `stock_quest.zig`, `game.zig` | |
| Stock TraderData (entity + TraderData v2) | `packages.zig` | primary entries + money |
| Stock NetPackageChat Global | `packages.zig` | SimpleChat upgraded |

### Content XML (2026-07-21)

| Item | Location | Notes |
|---|---|---|
| `entityclasses.xml` | `assets/entities.zig` | name → Unity hash, kind, HP, LootDropEntityClass; animals |
| `recipes.xml` | `assets/recipes.zig` | ingredients + always_unlocked → PlayerId unlock list |
| `loot.xml` | `assets/loot.zig` | groups/containers; death bag roll |
| Prefab sleeper volumes | `world/sleepers.zig` | Size/Start `#` segments + Group triples; wake on enter |
| `entitygroups.xml` | `assets/entitygroups.zig` | weighted `<e n p>`; director class_table |
| TTS density plane | `world/tts.zig` | sbyte[count] after block u32s |

### Other systems (simplified but wired)

Vehicles, power grid, turrets, signs (shells), setblock multi parse, admin TCP
stub: see `SYSTEMS.md`, `ECS.md`.

---

## Implementation rules (enforced)

1. Wire matches stock read/write (RE / IL), not “close enough”.
2. Sim state must match what the package claims.
3. Prefer **missing** over invented terrain, FX, or UI.
4. Tests use real stock ids/names when claiming stock behavior.
5. No AI attribution; no em dashes in shipped text.

Removed workarounds (do not reintroduce): POI stone shells, fake kill
ExplosionClient, guessed NavObject classes, `isStorageBlockId` for arbitrary
high ids, incomplete quest PDF blobs, reward wire that ignores ItemStack.

---

## Residual for full play (priority)

Open work only. See [TODO.md](../TODO.md) for the actionable list.

| Priority | Gap | Proper approach |
|---|---|---|
| P1 | Deco trees | Re-enabled when dump has treeOakSml01/treeDeadTree02 via idByName; empty firstPackage if miss |
| P2 | GameStats live sandbox sync | Full bPersistent blob on join (RE); HUD day from WorldTime; optional mid-session refresh |
| P2 | Weather storm SM | Defaults from biomes.xml on join+WorldTime throttle; storm/bloodMoon group SM not simulated |
| P1 | M11 multiplayer CPU | Serialize-once interest + named chunk caps shipped; pool shipped; 32-128 bot apm gate open |
| P2 | Quest / EAI / power depth | See MISSING honest-gap sections (objective types, A* path, generator fuel, trigger actuation) |
| P2 | Workstation RecipeQueue C2S depth | Queue rides TE composite (no NetPackageRecipe*); InvTx craft works; deeper C2S optional |
| P2 | PlatformUserIdentifierAbs party | Full ally/party user wire |
| P2 | Full telnet admin parity | Beyond admin TCP command set already shipped |
| P3 | Encryption* RSA+AES | Platform AntiCheat only; ServerPassword LiteNet key shipped; EAC-off scope |
| Parked | Planet-scale M2+ | DEM M1 proven; gateway/shards after in-process M11 (PLANET_SCALE.md) |

**HAVE (do not re-list as gaps):** AssignIds table (`assignids_v314.txt` 24808 rows +
maxdamage merge), stock Chunk.write + upper24, players.zsv v2, TE/blockmeta persist,
workstation TE sim, trader TraderData v2, electrical place+WireActions, sleeper
volumes, quest multi-phase graphs, EAI task table (2 tasks), land claim options.

---

## File map (stock wire modules)

| Module | Role |
|---|---|
| `src/wire/stock_chunk.zig` | Chunk network write |
| `src/wire/stock_deco.zig` | DecoUpdate + AssignIds constants |
| `src/wire/stock_entity.zig` | ECD spawn / loot classes |
| `src/wire/stock_inv.zig` | ItemValue/stack/bag/equip/PDF apply |
| `src/wire/stock_quest.zig` | Journal, NPCQuestList, SharedQuest |
| `src/wire/stock_te.zig` | TileEntity storage composite |
| `src/world/tts.zig` | Prefab TTS type paint |
| `src/world/prefabs.zig` | prefabs.xml + TTS cache + paint hook |
| `src/server/game.zig` | Package handlers + join bundle |

---

## Related docs

Full map: [INDEX.md](INDEX.md).

| Doc | Role |
|---|---|
| [TODO.md](../TODO.md) | Open backlog (shipped log below the fold) |
| [MISSING_FEATURES.md](MISSING_FEATURES.md) | Gap inventory (honest PARTIAL sections) |
| [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) | M7-M16 phases (post-playable stack) |
| [PACKAGES.md](PACKAGES.md) | 190-package catalog |
| [GAME_OPTIONS.md](GAME_OPTIONS.md) | serverconfig.xml → sim |
| [PLANET_SCALE.md](PLANET_SCALE.md) | Shard plan (parked until M11) |
| [SCALE_ARCHITECTURE.md](SCALE_ARCHITECTURE.md) | Substrate research (SpacetimeDB rejected) |
