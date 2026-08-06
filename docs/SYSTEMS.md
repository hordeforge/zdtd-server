# Game systems beyond the join core

All of these run on the **SoA ECS** (`src/ecs/`).

## Zombie AI (`systems.systemZombieAi` + `ZombieAi` component)

| State | Behavior |
|---|---|
| idle / wander | pick nearby wander points |
| chase / alert | path toward nearest player within sense range |
| attack | melee damage on players when in range |

LOD scales (RE-inspired): full / mid / far throttle decision rate (`1.0` / `0.3` / `0.1`).

## AIDirector (`ecs/aidirector.zig` resource + `systemDirector`)

- **World clock**: hours 0–24, day index, blood moon every 7th night
- **Wandering horde**: night spawns near players
- **Blood moon waves**: denser spawns when `day % 7 == 0` at night
- **Day scouts**: rare daytime spawns
- Broadcasts `NetPackageWorldTime` each second of sim time

## Quests (`Journal`/`Wallet` + catalog + stock wire)

**Catalog** (shared resource) is either:

- **Builtin** (no stock config): kill×3, goto (50,70,50), visit trader
- **Stock XML**: load real `Data/Config/quests.xml` via `--game-dir` / `--map` /
  `--config-dir` / `--quests` (see [ASSETS.md](ASSETS.md)); tracks
  `objective_count` and per-reward Item/LootItem flags for Quest.Write

Per-player progress is **SoA**: `journal` + `wallet` on the player entity.
Join auto-accepts `catalog.starter_id`. Systems: `questAccept*`, `questOn*`.

**Stock wire** (`src/wire/stock_quest.zig`):

| Package | Role |
|---|---|
| PlayerId PDF `QuestJournal` v5 | Starter quest when name is client-known (`quest_*` / `tier*`); `Quest.Write` FileVersion 8 |
| RewardItem/LootItem | RewardIndex u8 **+** ItemStack (not index-only) |
| `NetPackageNPCQuestList` | FetchList + `QuestPacketEntry` offers (not zdtd-native journal body) |
| `NetPackageSharedQuest` | Share/remove; server accept-by-name + forward to target |
| `NetPackageQuestObjectiveUpdate` | Stock treasure/block layout; legacy op kept for fixtures |

## Traders (`trader_stock` component on trader entities)

- Spawns **Trader Jen** near map spawn as entity kind `trader`
- Stock lives on the entity (`TraderStock` column), not a side table
- **Stock** `NetPackageTraderData`: hasEntity + entityId + Vector3i + TraderData v2
  (primary ItemStack entries + markup + money)
- Opening trader advances fetch-trader / TurnIn quests (sim); offers via NPCQuestList

## Buffs (`BuffSet` component + `systemBuffs` + `ecs/buff.zig`)

- Catalog: `assets/buffs.zig` (typed `stack_type`, `duration`, `update_rate`
  seconds → `UpdateRateTicks`, `remove_on_death`), builtin subset without buffs.xml
- Runtime: fixed 8-slot `BuffSet` attached lazily per entity; the rules mirror
  stock `EntityBuffs`/`BuffClass`/`BuffValue` tick-for-tick (Invalid → Finished →
  Remove → Paused/dead → Started → DurationTick), 20 Hz counting **up**, and
  `DurationMax <= 0` never expires
- Stack rules (`BuffEffectStackTypes`): Ignore revives a pending removal,
  Duration extends by the remainder, Effect increments `stackEffectMultiplier`
  (saturating at 255), Replace restarts the timer. No `stack_type` means Ignore
- Wire (`src/wire/stock_buff.zig`): `NetPackageAddRemoveBuff` body and the
  `EntityBuffs` blob (version 3). Join sends every other player's full list as
  `NetPackageEntityStatsBuff` (remote-only on the client), since a late joiner
  missed the relays
- C2S is validated (own entity only, name must resolve) then relayed to the other
  peers; expiries fan out from the tick. Relays always send `duration = -1`:
  any value >= 0 calls `BuffClass::set_DurationMax` on the receiving client and
  retunes that buff class for every entity for the rest of its session
- Not shipped: the `triggered_effect` VM (the client runs it from its own
  buffs.xml), the blob's cvar section, immunity/damage-type gates, buff
  persistence across sessions, and therefore `PlayerDataFile.buffData` (still
  written as length 0)

## Chat / attach / collect

- Stock `NetPackageChat` (Global); SimpleChat upgraded to Chat
- `NetPackageEntityAttach` for vehicle enter/exit
- `NetPackageEntityCollect` entityId+playerId fan-out

## PackageIds

Join-stable prefix plus large stock name list in `packages.default_mappings`
(dynamic ids at runtime; never hard-code ids as permanent).

## Vehicles (`Vehicle` component + `systemVehicles`)

- Kinds: bicycle, minibike, motorcycle, 4x4, gyrocopter
- Enter / exit / drive (throttle + steer); fuel burn; driver transforms stick to vehicle
- Wire: `NetPackageVehicleSpawn`, `VehiclePositions`, `VehicleDataSync` (control body)

## Electricity (`ecs/electric.zig` PowerGrid resource)

- Nodes: generator, battery, relay, consumer
- Undirected wires; BFS power flood from generators
- Overload: consumers unpowered when load > generation
- Gates: `is_trigger` plates open on player step for their stock
  TriggerPowerDelay/Duration; `is_switch` blocks open while latched on
- Wire: `NetPackageWireActions` / `WireToolActions` (connect, toggle, add node)
- Wire: `NetPackageTileEntity` carries TileEntityPoweredTrigger ClientTriggerData
  (delay/duration/reset in, authoritative state out)
- Wire: grid state reaches clients as edge-triggered `NetPackageSetBlock` bodies
  rewriting BlockValue meta bit 0x1 (isPowered) and 0x2 (isOn)

## Turrets (`Turret` component + `systemTurrets`)

- Require **power** from the grid; auto-acquire zombies in range; fire + ammo
- Kills feed quest kill counters for joined players
- Wire: `NetPackageTurretSpawn`, `TurretSync`
- Default map: gen + turret wired near spawn

## Honesty

Real IL-grounded cores now landed for the previously-missing subsystems
(2026-07-23): EAI prioritized task graphs (ApproachAndAttackTarget + Wander,
greedy pathing kept), POI sleeper volumes from prefab `.tts`/`.nim` markers,
trader stock TraderData wire, blood-moon `BloodmoonMusic` builder (HordeEvent
builder shipped **unwired** because stock has zero senders), vehicle terrain
gravity/ground-clamp, electrical block placement + WireActions, and quest
multi-phase objective execution (real phase graph, not primary-kind collapse).
Each has documented remaining gaps (navmesh A*, gamestage biome/quest/POI-tier
inputs, generator
fuel sim, per-item markup, multi-objective phases, etc.). Prefer missing over
fake. Precise, current gap inventory: [MISSING_FEATURES.md](MISSING_FEATURES.md).
Hub: [STATUS.md](STATUS.md).
