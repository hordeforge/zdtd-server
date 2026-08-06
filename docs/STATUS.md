# Status: stock-client join and play path

**Date pin:** 2026-08-06  
**Game line:** V 3.x Mono (connected client **V3.1.0 b14**; bundled AssignIds dump byte-matches this client's runtime block ids), EAC off  
**Unit tests:** `zig build test` → **758** total (prefer `zig build test`; running the cached test binary with Zig's `--listen=-` IPC by hand can hang, and the build-runner run can end in a benign trailing `failed command` while still exiting 0; the count comes from running the cached binary directly). Recount after large ECS/webui waves.
**Policy:** proper stock wire/sim only; missing preferred over fakes (see residual gaps)

This is the hub for "what works now" vs `GAP_ANALYSIS.md` (full inventory) and
`IMPLEMENTATION_PLAN.md` (phased plan). Doc index: [INDEX.md](INDEX.md).

## Wave 2026-08-06

Landed on main, each gated on `zig build` + `make check` and, where it is
observable, on the live stock client:

- **Join path closed on the real client.** Three defects, in order of discovery:
  a soft-dropped chunk was still recorded as streamed so it was never resent,
  leaving a hole in the mesh halo (no collision mesh, free-fall, origin thrash);
  GameStats reported `GameState=0` (Loading) while the client runs
  `updateRespawn` only at `1` (Running); and chunks streamed only from the spawn
  bundle, losing a race against `OnAddedToWorld` setting `bSpawned`. The client
  now renders Navezgane and plays: HUD, compass, hotbar, block damage, pickups.
- **POI fidelity.** Prefab footprints turned counter-clockwise where stock turns
  clockwise, swapping rotations 1 and 3 for 709 of Navezgane's 1559 decorations;
  per-block facing needed `CalcRotation(rot, 4 - r)` to match. Prefab ids are now
  remapped through `<name>.blocks.nim` (21.4% of painted cells were the wrong
  block over a 120-POI sample), pre-v18 `BlockValue` layouts are converted, and
  `YOffset` is applied so caves, mines and bunkers sit below the surface.
- **Combat and replication.** Player HP changes reach the client, mobs that leave
  a client's interest box are unloaded instead of standing frozen forever, and
  the replicate pass gained alive/dirty bitsets with per-entity observer masks.
- **Features:** deco NameIdMapping + biome density + world-store mirror, weather
  storm/bloodMoon state machine, quest rally objectives, workstation RecipeQueue,
  power trigger TE wire, A* pathfinding, gamestages, buffs depth, vehicle
  multi-seat, party PlatformUserId, stock telnet console surface.
- **Traders (T1):** the trader NPC now replicates with a real `npcTraderJen`
  class hash, and `TraderData` rides both stock S2C paths: spawn
  `EntityCreationData.hasTraderData` and the channel-1 LockResponse context.
  Wire + scenario tested (759 total); live stock-client visual check pending.
- **Loot (T2):** containers roll their own `blocks.xml` LootList (gun safe
  `smallSafes`, chest `woodenChest`); zombie bags resolve the stock chain to
  `zPackReg` and drop only on `LootDropProb` (.04), so most kills drop nothing.
  Three new tests; 761 total.
- **Items (T3):** absent `Stacknumber` defaults to stock's 500 and inherits
  through `Extends` (two-pass resolve); the "bag slot waste" residual is closed.
  New stock-file test; 762 total.
- **Water (T4):** lakes and rivers now fill from `water_info.xml` sources at
  chunk generation, and the chunk water channel carries the full static mass
  (POI water planes and the fluid sim remain open). Two new tests; 764 total.
- **Progression (T5):** `players.zsv` v3 persists level, XP, food/water and
  active buffs across restarts (server-side `awardXp` ledger; ZPV2 files still
  read; admin wipeplayer handles v3). Round-trip test x2; 765 total.
- **Docs:** [GAP_ANALYSIS.md](GAP_ANALYSIS.md) scores 345 features with anchors;
  [WORK_PLAN.md](WORK_PLAN.md) turns the top gaps into handoff-ready tasks.

**Gates at this pin:** `make check` exit 0 · 758 unit tests · live stock-client
gate **23/23** · playtest full suite green on a fresh world.

**Known open:** see [WORK_PLAN.md](WORK_PLAN.md). The largest are trader depth
(POI placement, restock, per-trader lists, quest offering; the NPC now
replicates with TraderData on both S2C paths, WORK_PLAN T1), quest accept and
template inheritance, water, and player persistence.

**Conflict rule:** if STATUS and GAP_ANALYSIS / IMPLEMENTATION_PLAN disagree on
whether a gate or feature shipped, **STATUS wins**. Refresh the inventory docs
when closing work; do not re-open a STATUS PASS from a stale GAP_ANALYSIS row.

---

## Gates (evidence loop)

| Gate | State | Evidence |
|---|---|---|
| Stock client join (zdtd-connect auto) | **PASS** | 2026-08-04: `fixedSizeCC=false` + stream r≥6; spawn hb `cgo=68/39` (viewDist 7), terrainReady, xuiReady; overlay gate clear |
| NullReference on join | **PASS** | 0 NRE; ChunkCalc alive (no CalcDominantBiome OOB) |
| Client mesh (CGO) | **PASS** | CGO 68 ≥ 39; Chunks:192; defaults stream r 7..9 (CGO needs r≥6 at viewDist 7), 8 adds/tick, max_streamed=169 |
| Terrain floor textures (MicroSplat) | **PASS** | `fixedSizeCC=false` → FromRaw loads splat*.png (not Dummy); surface id 8=terrBurntForestGround; grey clay was null splat controls |
| POI/construction block textures | **PASS** | u32 rawData + upper24 when bits 8..31 set; TTS paint+density; non-terrain density ≥0; filler skipped on paint |
| serverconfig gameplay options | **PASS** | difficulty/bloodmoon/PvP/day-length/max-zombies parsed + applied (docs/GAME_OPTIONS.md) |
| Parity batch 2026-07-23 | **PASS (partial cores)** | POI sleeper volumes from prefab .tts/.nim, blood-moon BloodmoonMusic builder (HordeEvent builder unwired: stock has no sender), electrical block placement + WireActions, vehicle terrain gravity/ground-clamp, trader stock TraderData wire, quest multi-phase objective graphs, EAI prioritized task graphs, in-game console commands. All PARTIAL with documented gaps (GAP_ANALYSIS.md) |
| Quest PDF load | **PASS** | no `Failed loading` after RewardItem ItemStack wire |
| Unit tests | **PASS** | 2026-08-05 wave: inventory place wood + craft scenarios green; snapshot/EAI/evidence/webui http added (run `zig build test` for exact count). |
| C2S hardening | **PASS** | join-phase gate; Bag ownership; damage cap+fatal-vs-NPC only; SetBlock/Explosion/TE reach 96; respawn heal only when dead |
| Interest fan-out | **PASS** | broadcastNear 160 blocks for SetBlock/Explosion/loot spawn; pw19 kill soak Items:3, no near-skip misfires |
| Player death → respawn | **PASS** | admin kill → EntityStatChanged hp=0; RequestToSpawnPlayer heal + PlayerSpawnedInWorld(died) + join bundle; playtest `player_respawn` PASS 2026-08-03 |
| Entity spawn-on-approach | **PASS** | per-client known_entities bitset; ECD spawn on first range entry (director hordes, sleeper wakes, roaming); pw27 soak green |
| Player persist v2 | **PASS** | players.zsv v2 (quality/meta + journal); join PDF carries restored toolbelt/bag; pw27 axe q1 persisted through restart+rejoin. Admin `wipeplayer <name>` erases offline records (and kicks online). Note: client inventory is client-authoritative (C2S PlayerData/PlayerInventory overwrite server sim), so only items the client actually holds persist; server-side `give` is a loot-bag drop for this reason |
| TE/block persist | **PASS** | containers.zct + blockmeta.zbm save/load on save tick + shutdown; unit roundtrip test; pw19 restart rejoin green (files present, join CGO:25, 0 WRN) |
| Player save merge | **PASS** | savePlayers keeps offline records (was TRUNC joined-only) |
| Trader XML stock | **PASS** | traders.xml traderAlways direct items + items.xml EconomicValue prices (assets/traders.zig; group rolls deferred) |
| Director class variety | **PASS** | zombie slots 1+8..11 from entitygroups weighted picks; rotation per spawn |
| Zombie population bound | **PASS** | alive-cap 24 + far-despawn (>200 blocks, reason=Despawned); pw27 Ent stable 3-4 vs prior 7→34 creep |
| ItemValue/Explosion wire | **PASS** | ReadData + ExplosionData positional per IL (no remaining() or scan heuristics); unit tests |
| Loot bag wire direction | **PASS** | NetPackageBag dir=ToServer(1); S2C sends removed; loot rides ECD `bag` field in EntitySpawn; pw15 kill 100/101/102 → Items:3, zero WRN/NRE in client log |
| Loadgen join + walk + dynamite | **PASS** | flat + Navezgane; 2-bot mixed 100% passRate, walks>0, ExplosionInitiate; pw21 2-bot wander 100% alongside live stock client (walks=495, zero client WRN) |
| EntityRemove reason byte | **PASS** | body=entityId:i32+reason:u8; pw14 admin `kill 100/101/102` no NCSimple underrun; Items:2 loot bags |
| Automated in-client playtest | **PASS (2026-08-06)** | V3.1.0 b14 pin. Live gate **23/23** on a fresh world each run (`FRESH=1`); the client renders and plays Navezgane. The earlier demo residuals are closed: the deco S2C NRE is resolved ([archive/DECO_NRE.md](archive/DECO_NRE.md)) and the join hang is fixed (GameState=Running plus chunks before the spawn). Still open: full MinEvents eat amount (chili +15). |
| WebUI ops (WU0–WU2) | **PASS** | `--webui-port`+secret; `tcp_listen` + `std.http.Server`; dashboard + POST `/api/cmd`; CSRF; full apm snapshot; default off |
| Authority spine (P4.0) | **PASS (first cut)** | `phase_gate` matrix; movement envelope; reject counters in apm/webui; `ZdtdAuthorityMode`; inv ledger ring |
| Static plugins + P3 ECS | **PASS (first cut)** | `src/plugin/` sample_hello; Res/Query/Cmd; stream soft warn; plugins are Wasm-only per ADR 0020, no runtime wired (WORK_PLAN T9) |
| zdtd.toml | **PASS** | world/CWD → stream/authority/feature InitOptions; `zdtd.toml.example` |
| Gamemode pack | **PASS (first cut)** | `modes/default.toml` + `mode.zig`; `--mode` / `[mode] name` → InitOptions; `enable_sample_plugin` |
| C2S package coverage | **PASS 32/33** | parity tool: 1 unhandled dir=1 (`NetPackagePlayerDisconnect`, covered by the LiteNet transport-disconnect path, game.zig:3437; explicit handler = WORK_PLAN T10); 190-pkg catalog docs/PACKAGES.md |
| Full playable stock dedi | **PASS (core loop); demo partial** | join → in-game (0 NRE) → move/build → fight → death → respawn → loot/craft/trade/persist **partial**. Automated demo residual: craft queue/trader buy client path, explosion close-in. Weather S2C driven by the biomes.xml storm/bloodMoon group state machine; GameStats full persistent blob (HUD day from WorldTime). Cosmetic: deco trees blocked on DecoManager.Read NRE. Not full-stock parity. |

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
| ZCH3 chunk persist (`.zch` files, u32 rawData) | `world/store.zig` | ZCH2 u16 blocks are dropped on load (regen from DTM+TTS); heights remain |
| Stock `NetPackageChunk` write path | `wire/stock_chunk.zig` | full rawData upper24; density repair rules; TTS dens; topsoil broken all-1s; light 0xFF |
| Spawn/stream ring for light+mesh | `server/game.zig` | defaults r 7..9 (`default_chunk_stream_radius_*`), 8 adds/tick, max_streamed=169; WorldInfo fixedSizeCC=**false** |
| biomes.png color→biomemap id | `world/biomes.zig` | stock biomemapcolor keys; id&lt;50; height fallback |
| Prefab footprints + water | `world/prefabs.zig`, `water.zig` | height flatten |
| **TTS paint (rawData+tex+density)** | `world/tts.zig`, `prefabs.zig` | ids remapped by name via `.blocks.nim`; pre-18 `BlockValueV3` converted; skip terrainFiller; rotation bits kept |
| AssignIds pins + dump merge | `assets/assignids_comptime.zig`, `maxdamage.zig` | cwd + /proc/self/exe paths |
| Catalog loaders (XML) | `assets/*` | blocks ids=dump only; biomes colors; painting; spawning; buffs (stack/duration/update_rate) + passives; progression attrs/perks; vehicles; storage pairs; traders groups |
| Shared I/O | `util/io_fs.zig`, `assets/paths.zig` | std.Io-backed filesystem helpers and config-path resolution |
| Seed chest AssignIds | `stock_deco.zig` | cntWoodenChestClosed from dump |
| Place item→block | `ecs/inventory` + Game.place_fn | name→AssignIds (wood→frameShapes:cube) |

### Inventory / containers / loot

| Item | Location | Notes |
|---|---|---|
| Stock PDF inventory apply | `stock_inv.zig` | toolbelt/bag/equip |
| HoldingItem, bag, drops | `stock_inv.zig`, `game.zig` | Bag/PlayerInventory C2S-only; S2C echo = HoldingItem |
| LockRequest grant + TE re-send | `packages.zig`, `game.zig` | always-grant (contention deferred) |
| Storage TE composite stream | `stock_te.zig` | place + chunk path |
| Workstation TE (type 12) | `stock_te.zig`, `world/workstations.zig` | ver 50 full body (fixed stock array lengths, recipe blobs, CraftCompleteData, lastInput); stock queue orientation, output-full stall and cycle carry; 2Hz burn/craft tick + dirty S2C re-broadcast and lock-grant push; see WIRE_WORKSTATION.md |
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
| EAI BreakBlock task | `ecs/systems.zig` | path_blocked → BreakBlock; block chew via tickZombieBlockDamage |

### Quests / traders / chat

| Item | Location | Notes |
|---|---|---|
| Quest NavObject markers | `game.zig` sendQuestNavObjects | stock class names from nav_objects.xml |
| Stock quests.xml catalog | `assets/quests.zig` | objective/reward kinds |
| Quest.Write + journal v5 | `stock_quest.zig` | RewardItem = index + ItemStack |
| Starter in PlayerId PDF | `game.zig` | client-known `quest_*` / `tier*` names |
| NPCQuestList FetchList + QuestPacketEntry | `stock_quest.zig` | trader offers |
| SharedQuest forward/accept | `stock_quest.zig`, `game.zig` | |
| Stock TraderData (entity + TraderData v2) | `packages.zig` | primary entries + money |
| Stock NetPackageChat Global | `packages.zig` | SimpleChat upgraded |
| Buff set + stack/duration ticks | `ecs/buff.zig`, `ecs/components.zig` | stock EntityBuffs tick order at 20 Hz |
| AddRemoveBuff + EntityBuffs blob | `wire/stock_buff.zig`, `game.zig` | C2S validated, relay/expiry always duration -1 |

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
console: see `SYSTEMS.md`, `ECS.md`.

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
| P1 | Deco trees | Blocked on DecoManager.Read NRE RE; empty firstPackage only until object wire matches V3.1.0 |
| P2 | GameStats live sandbox sync | Full bPersistent blob on join (RE); HUD day from WorldTime; optional mid-session refresh |
| P2 | Weather storm SM | Shipped (`world/weather.zig`): stormbuild → storm → reschedule per biome, random group rolls, blood-moon override. Not persisted across restart |
| P1 | M11 multiplayer CPU | Serialize-once + named caps + pool shipped; chunk workers parked until apm need; 32-bot loadgen = operator validation |
| P2 | Quest / EAI / power depth | See GAP_ANALYSIS honest-gap sections (more EAI tasks) |
| P2 | Workstation recipe validation | Queue rides the TE body (no NetPackageRecipe*); the server still trusts the client's Recipe blob instead of checking recipes.xml |
| P2 | PlatformUserIdentifierAbs party | Full ally/party user wire |
| P2 | Quest / EAI / power depth | See GAP_ANALYSIS honest-gap sections (more EAI tasks; workstation RecipeQueue C2S optional) |
| P2 | Workstation RecipeQueue C2S depth | Queue rides TE composite (no NetPackageRecipe*); InvTx craft works; deeper C2S optional |
| P3 | Party membership + ally persistence | PUID flows login → PersistentPlayerState → AllyStore; party packages carry no PUID (entity-id keyed) so party needs Party state, not identity |
| Parked | Full telnet / Steam browser | Admin TCP + WebUI cover research ops |
| Non-goal | Encryption* RSA+AES | Platform AntiCheat only; ServerPassword LiteNet key shipped; EAC-off scope |
| Parked | Planet-scale M2–M4 | DEM M1 proven; gateway/shards after M11 (PLANET_SCALE.md) |
| Parked | Wasm plugin runtime | ADR 0020: Wasm-only, no runtime wired yet; static host stays as test scaffolding (WORK_PLAN T9) |
| Multi-ms | Worldgen W3–W7 | W0/W1/W2 shipped (3D density field); climate/caves/POI/WFC track open |

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
| [GAP_ANALYSIS.md](GAP_ANALYSIS.md) | Gap inventory (honest PARTIAL sections) |
| [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) | M7-M16 phases (post-playable stack) |
| [PACKAGES.md](PACKAGES.md) | 190-package catalog |
| [GAME_OPTIONS.md](GAME_OPTIONS.md) | serverconfig.xml → sim |
| [PLANET_SCALE.md](PLANET_SCALE.md) | Shard plan (parked until M11) |
| [SCALE_ARCHITECTURE.md](SCALE_ARCHITECTURE.md) | Substrate research (SpacetimeDB rejected) |
