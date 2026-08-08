# ECS and sim architecture review 2026-08-08 (zdtd)

| | |
|---|---|
| Date | 2026-08-08 |
| Audit start | `8638918` (branch main) |
| Audit end | `6a60f32` (main, ahead of origin; sibling agent committed concurrently) |
| Scope | `src/ecs/*` vs `src/world/*` vs `src/server/*` ownership: component mutation paths, Game-to-ecs edges, schedule + Rules overlay, tick-path allocation discipline, per-entity class stats fallback chain (A35), world-store vs ecs boundary |
| Mode | Audit first, small safe fixes only. 6 commits landed (see Fixes); every change is a read-layer or carry-layer consistency fix with a unit test, no API redesign |
| Companion docs | `docs/reviews/DEP_ARCH_REVIEW_2026-08-08.md` (import graph), `docs/reviews/ARCH_API_REVIEW_2026-08-08.md` (Game facade), `docs/adr/0021`, `docs/ECS_SYSTEMS.md` |

Branch caveat: main advanced during the audit. A sibling agent landed dead-code
removals (`a6c7fc5` trade, `f4cae2a` chunk_stream, `b78e8bd` Game method
duplicates, `1dd61aa` loader errors), a hardened `lint-architecture.sh`
(`344d917`), and two review docs. All findings below were re-verified against
the delivery-time tree. The three `zig fmt` failures in `make check`
(`game/join.zig`, `game/world.zig`, `game/hooks.zig`) pre-date this review
(verified against pristine HEAD bytes) and belong to the sibling's in-flight
shard work; none of the files this review touched fail fmt.

Method: (1) read `src/ecs/components.zig` (component inventory) and
`src/ecs/world.zig` (mutation funnel), (2) grepped every
`sim.<column>[` read/write in `src/server` and classified mutations against
the World funnel, (3) enumerated every `?*const fn` field in `src/ecs` to
inventory the Game-to-ecs hook surface, (4) read `schedule.zig` + `rules.zig`
and grepped all `rules.*` reads, (5) grepped `alloc|create|dupe|ArrayList|
page_allocator|arena` in `src/ecs` and on the server tick path, (6) traced the
per-entity class stat chain (`ClassId` -> `class_table` -> `Rules`) at every
speed/damage/sense read and every spawn site, (7) ran `zig build test`
(green) and `bash scripts/lint-architecture.sh` (clean) at start and delivery.

## Outcome

| Question | Result |
|---|---|
| Direct component mutation from server that breaks a World-owned invariant | 0 found; 3 raw-write sites (admin tp/tele, respawn, hp-stat clear) are deliberate but funnel-inconsistent; 2 fixed, 1 documented |
| Game-to-ecs edges | 15 ctx+fn hook pairs (5 Director + 10 World), all optional, all data-in/data-out. **The Director hooks are not the only edges** (see 2) |
| System disable surface | `w.rules.systems.*` toggles only, read in `schedule.run` + `Director.tick`; mode packs / zdtd.toml via `RulesOverlay` (ADR 0021) |
| Rules floor-vs-data precedence | consistent after fixes: chase/wander/attack/sense all read per-entity -> class_table -> Rules; is_enemy per-entity only (default true) |
| Heap allocation on the ecs tick path | 0. No alloc/create/dupe/ArrayList growth, no page_allocator, no arena in `systems.zig` / `schedule.zig` / tick-touched `world.zig` fns |
| world -> ecs edge | `world/containers.zig` + `world/workstations.zig` import `ecs/components.zig` for `InvSlot` only (pure POD, lint-allowed). ecs -> world: 0 imports |
| `make check` | still red on the 3 pre-existing sibling fmt failures only; this review's files pass `zig fmt --check`, lint, and `zig build test` |

## 1. Component ownership (src/ecs/components.zig)

Components are plain POD; mutation funnels live on `World` (spawn*/destroy/
reviveSlot/damageFrom/setPos/markDirty/sweepCorpses/depositItem) and in the
`systems.zig` phases. The table classifies every mutation site found in
`src/server` (scenarios/tests excluded).

| Component | Mutated by | Verdict |
|---|---|---|
| Transform | World.setPos (C2S move, systems movement/vehicles), admin tp/tele raw write, respawn raw write, persist load | 2 raw writes bypass setPos; both immediately send NetPackageEntityTeleport + reset the move envelope, so the missing markDirty is moot. Improvement 1 |
| Health | World.damageFrom, systems (deferred damage, buffs), tickSurvival (server), respawn raw write, persist load, ecs applyEatProps | Survival/regen intentionally lives in the server tick (GAP 22, buffs.xml wiring pending T16); respawn is the documented "sanctioned un-kill" (reviveSlot). Improvement 2 |
| ZombieAi | systems.zig only (task table, movement, revenge, distractions), World.damageFrom (revenge latch), World.spawn* (init) | clean |
| Vehicle | systems.systemVehicles, persist load (fuel/yaw), World.spawnVehicleEx | clean |
| Turret | systems.systemTurrets, persist load (range/damage/ammo), World.spawnTurret | clean |
| Journal | systems.quest_systems, game.zig shared-quest pass, persist load, c2s/quest | server reads + phase edits; no World method exists; consistent |
| Wallet | trade.zig / game/trader.zig (buy/sell), c2s/quest vending rent, systems quest reward, persist load | 4 write sites, same "server owns the economy" rule; scattered but consistent. Improvement 4 |
| Inventory | Inventory component methods + World.depositItem, c2s apply paths, systems.loot, persist load, rollback snapshots (`inventory_before`) | component methods own stack invariants; markDirty raised by callers. clean |
| ClassId | World.spawn*Def (carry), Director/Game spawn resolution, hooks (POI trader hash/loot), systems (is_enemy reads only) | all writes now go through the def spawns (A35 fixes) or hooks |
| TraderStock | game/trader.zig + trade.zig + systems.traderRestock | trade domain is server-side by design; restock math in systems. Improvements 4 |
| LootBag | World.spawnLootBag, game/loot.zig distraction config | post-spawn config has no World method; consistent |
| Sleeper | World.spawnSleeper*, systems (awake state via sleeper scan on server) | clean |
| Flags | c2s/move NetPackageEntityAliveFlags raw write | client-driven echo fanned to peers verbatim; the package IS the wire (stock tracked-players); no dirty needed. By design |
| Dirty | World.markDirty (raise), replicate post-pass clearAfterReplicate + syncDirtyBit, replicatePlayerHealth hp clear | the hp clear was a second clear-without-sync site; fixed (Fixes 6) |

No server handler writes `alive[]`, `mask[]`, `network_id[]`, `kind_groups`,
`peer_to_player`, or `dirty_bits[]` directly. The only sanctioned un-kill
(`reviveSlot`) and the spawn/destroy paths stay on World.

## 2. Sim vs server boundary: Game-to-ecs edges

The audit prompt asked to confirm the four Director hooks are the only
Game-to-ecs edges. They are not: the ecs layer carries 15 optional ctx+fn
pairs, all wired once at `Game` init, all pure data-in/data-out (no Game
callback reaches back into ecs state).

| Hook | Lives on | Wired at | Purpose |
|---|---|---|---|
| `biome_group_fn` | Director | game.zig:1141 | per-spawn-point biome spawn group (spawning.xml) |
| `group_pick_fn` | Director | game.zig:1143 | entitygroup pick (entitygroups.xml) |
| `class_resolve_fn` | Director | game.zig:1148 | full entityclasses row for out-of-table classes (A35) |
| `stage_group_fn` | Director | game.zig:1150 | gamestages.xml spawner lookup |
| `spawner_group_fn` | Director | game.zig:1152 | scout spawner name -> EntityGroupName |
| `ground_fn` | World | game.zig:739 | terrain height for vehicle physics |
| `step_fn` | World | game.zig:742 | one-cell move probe for AI pathing |
| `place_fn` | World | game.zig:744 | item_id -> placeable block id (AssignIds) |
| `fuel_value_fn` | World | game.zig:746 | items.xml FuelValue |
| `stack_fn` | World | game.zig:748 | items.xml Stacknumber |
| `is_armor_fn` | World | game.zig:750 | armor prefix test |
| `poi_fn` | World | game.zig:753 | POI footprint at world XZ (prefabs) |
| `nearest_poi_fn` | World | game.zig:755 | nearest quest-eligible POI |
| `party_same_fn` | World | game.zig:758 | party membership for POI lockout |
| `kill_verdict_fn` | World | game.zig:1157 | wasm plugin kill verdict (T15) |

Data-only Game-to-ecs writes (no fn pointers): `sim.rules` at init,
`sim.class_table` via `setClassDef`, `sim.director.*` config at init + admin
commands, `sim.director.party_stage` every tick (game.zig:4721),
`sim.zombie_speed_scale`, `sim.trader_restock_cap/refill`. `Game` also drains
`sim.completed_quests_ring` at tick end. `src/ecs` imports nothing from
`src/server` or `src/world`; the hooks are the entire seam, and each hook is
null in offline/test worlds (documented fallback per hook).

`src/ecs/sim_view.zig` (narrow inv/transform mut surface) is exported from
`ecs/root.zig` and referenced by `docs/PLUGIN_API.md` as the plugin capability,
but no plugin or handler currently uses it (wasm host uses hooks + the command
buffer). Dead-but-documented surface; Improvement 5.

## 3. Schedule + Rules overlay

`schedule.run` (src/ecs/schedule.zig) is the only tick driver: `beginTick ->
buffs -> director -> ai -> vehicles -> turrets -> despawn -> commands`, with
`animals` running inside `Director.tick` (stock SpawnManagerBiomes is a system
separate from the AIDirector; `rules.zig` documents this). The order is pinned
by a test and is not configurable.

- **Toggles**: `w.rules.systems.{buffs,director,animals,ai,vehicles,turrets,despawn,commands}`.
  Read only in `schedule.run` (6) and `Director.tick` (`director`, `animals`).
  Mode packs (`modes/builder.toml`) and zdtd.toml apply `[rules.*]` overlays
  via `RulesOverlay`/`mergeOverlay` (ADR 0021 decision 3). No other disable
  path exists. `director = false` keeps the world clock, blood-moon flag and
  daily trader restock and only stops zombie spawning (test-pinned).
- **Floor-vs-data (ADR 0021 decision 5)**: every `rules.*` read was checked.
  `combat.attack_damage`, `ai.sense_dist_sq`, `ai.chase_speed`,
  `ai.wander_speed` are documented floors; the per-entity / class_table layers
  win first (see 5). All other `rules.*` values (path timing, bloodmoon party
  tuning, progression, despawn range, mount range) are policy with no
  per-entity stock equivalent, and `rules.zig` says so next to each field.
  Server-side `rules.*` reads (`game/tick.zig` survival + block bite,
  `c2s/move.zig` sprint staleness) are all policy values. Consistent.

## 4. Hot-path discipline

Grepped every allocator/arena/`ArrayList`/`HashMap`/`dupe`/`create` hit in
`src/ecs` and on the server tick path.

- `src/ecs/systems.zig`, `schedule.zig`, `world.zig` tick fns
  (`beginTick`, `spawnBase`, `destroy`, `damageFrom`, `setPos`, `sweepCorpses`,
  `markDirty`, `syncDirtyBit`, `drainCommands`), `aidirector.zig`,
  `buff.zig`, `quest_systems.zig`, `electric.zig`, `path.zig`, `interest.zig`,
  `command.zig`, `observers.zig`, `group.zig`, `locals.zig`, `inv_ledger.zig`:
  **zero** heap allocation. `net_to_slot` is pre-sized at init
  (`ensureNetMap`); `registerNet` on failure degrades to the SoA scan (never
  reallocs). Stack-only scratch: `dmg_fp [512]u32` (2 KB) per AI tick, `[64]`
  player snaps, fixed `TickResult` rings.
- No `page_allocator` and no arena on any tick path. All `page_allocator` uses
  are process/`std.Io.Threaded` init (main, litenet, tcp_listen, parallel,
  webui, game.zig:4969), fs helpers, load paths, and the async
  `world/chunk_flush.zig` writer thread + store save workers (documented as
  off-tick in their headers). Arenas are load-time only (quest catalog,
  serverconfig, mode packs).
- Parallelism is the pre-created `util/parallel` / `jobs` pool only; no
  per-tick thread spawn.

## 5. Per-entity class stats fallback chain (A35, commits da14212 / 5a5a953)

Chain: `ClassId` per-entity fields -> `class_table[class_id[s].id]` row ->
`Rules` floor. Verified at every read and every spawn:

| Stat | Read site | Chain at audit start | Now |
|---|---|---|---|
| wander_speed | systems.zig:1030, 1045 | per-entity -> table -> Rules | ok (unchanged) |
| chase_speed | systems.zig:1043-1046 | per-entity -> table -> Rules | ok (unchanged) |
| attack_damage | systems.zig:1483 | **table -> Rules only, skipped per-entity** | **fixed** (Fixes 1) |
| is_enemy | systems.zig:1308 | per-entity (default true, no floor) | ok (unchanged) |
| sight_range | systems.zig:1120 senseDistSq | table -> Rules only; no per-entity field | **fixed** (Fixes 5) |

Spawn sites that must carry the per-entity layer (a class outside the fixed
16-slot table behaves as itself only if the stats ride on the entity):

| Spawn site | Before | After |
|---|---|---|
| Director zombie (`spawnZombieDef`) | ok (A35) | unchanged |
| Director animal (`spawnAnimalsNearPlayers`) | manual post-spawn copy | `spawnAnimalDef` (Fixes 2) |
| Director class_table rotation pick | `spawnZombieClass` dropped stats | `spawnZombieDef` with the row (Fixes 4) |
| Prefab sleeper volumes | `spawnSleeperClass` dropped stats | `spawnSleeperDef` (Fixes 2) |
| Fresh-world starter zombies/animal | `spawnZombieClass`/`spawnAnimal` dropped stats | def variants (Fixes 3) |
| Admin `spawnentity` (both paths) | dropped stats | def variants (Fixes 2, 4) |
| Quest summons (`NetPackageQuestEntitySpawn`) | dropped stats | `spawnZombieDef` (Fixes 4) |
| POI trader (hooks.zig) | hash/loot only | ok (traders have no speeds/damage) |

`spawnZombieClass`/`spawnAnimal` remain as the low-level hash/loot forwarders
(used by the def variants and tests only). The chain is now consistent at
every read and every production spawn site.

## 6. World store vs ecs

| Concern | Owned by | Notes |
|---|---|---|
| Chunks, blocks, block HP, TTS, prefabs, sleeper volumes, containers/vending/workstation TE, weather, biome/deco | `src/world/*` | chunk stream + TE replicate in server read world, never write ecs entity state |
| Entities (transform/health/AI/inventory/quests), systems, resources, power grid | `src/ecs/*` | `World` (ecs) is the entity store; `Game` owns it as `sim` |
| Terrain queries into the sim | none in ecs; the `ground_fn`/`step_fn` hooks | ecs never imports world; server wires world lookups in as ctx+fn |
| world -> ecs imports | `containers.zig`, `workstations.zig` import `ecs/components.zig` for `InvSlot` | pure POD shape, allowed by `lint-architecture.sh` (world forbids server/wire/litenet/apm only) |

No boundary confusion found: no world function reaches into ecs entity state
and no ecs system reaches into the block store directly. The one shared type
(`InvSlot`) is a POD that both sides already treat as a value.

## Fixes (this review, 6 commits)

1. `84d2887` `systems.zig` attack read: per-entity `attack_damage` wins before
   the class_table row and the Rules floor (A35), + test.
2. `f7c9547` `spawnSleeperDef` / `spawnAnimalDef` on World, `Game.entityClassOf`
   mapping extracted, sleeper volumes + admin `spawnentity` + director animals
   route through them, + world test.
3. `9d983da` fresh-world starter zombies/animals spawn as their resolved class.
4. `bd0564e` quest summons (`c2s/misc`) and admin spawn-by-name carry the
   resolved class.
5. `687305b` `ClassId.sight_range` carried by the def spawns; `senseDistSq`
   reads per-entity -> class_table -> Rules, + test.
6. `6a60f32` `replicatePlayerHealth` calls `syncDirtyBit` after lowering
   `dirty[i].hp`, restoring the documented dirty_bits invariant.

Each fix is a read-layer or carry-layer consistency change with a unit test;
`zig build test` green at every step, `lint-architecture.sh` clean at delivery.

## Ordered improvement list

1. **`World.teleportTo(slot, x, y, z, yaw)`** (small): replace the two raw
   `sim.transform[ps] = ...` writes in `admin_console.zig` (tp, tele). The
   immediate NetPackageEntityTeleport makes today's behaviour correct, but the
   funnel keeps markDirty/rot handling in one place and removes the only
   transform writes outside `setPos`/systems/persist/respawn.
2. **`World.respawnPlayer(slot, x, y, z)`** (small-medium): absorb the
   c2s/join.zig respawn block (reviveSlot + health reset + blood-moon flag +
   transform + markDirty), which is currently a carefully commented raw-write
   block. One method would own the "sanctioned un-kill" and its dirty bits.
3. **Drop or wire `SimView`** (tiny): it is the documented plugin capability
   (docs/PLUGIN_API.md) but nothing imports it; either route the wasm plugin
   host's inv/transform ops through it or remove it to avoid a second mutation
   surface next to `World`/hooks.
4. **Centralize wallet writes** (small): `coins` is mutated from trade, vending
   rent, quest reward and persist load; a `World.walletCoins(slot)` accessor or
   a small ecs wallet helper would make the four sites auditable in one place.
5. **Per-entity `sight_range` on the class_table row** (optional): `class_table`
   rows are still the fallback for sight; if a mode preloads rows with
   SightRange, the entity inherits it (already correct). The remaining
   asymmetry is that `spawnZombieFromClassId` (tests only) does not carry the
   row stats; production paths are all covered.
6. **Trader-stock writes** (later): the trade domain is deliberately
   server-side, but `trader_stock` is mutated from three server files; moving
   the open/close + buy/sell math into ecs (like `traderRestock`) would let a
   mode or plugin gate it without touching Game.
7. **Watch the sibling's fmt debt**: `game/join.zig`, `game/world.zig`,
   `game/hooks.zig` fail `zig fmt --check` at HEAD (pre-existing). They are the
   sibling's in-flight shard files; once that work lands, `make check` should
   go green and a follow-up fmt pass should include them.

## Evidence

- `zig build test` (Debug): green at audit start and at delivery (and after
  each fix commit).
- `bash scripts/lint-architecture.sh`: clean at delivery (incl. `344d917`
  hardened rules).
- `zig fmt --check` on every file touched by this review: clean.
- `git status`: clean at delivery; sibling's concurrent commits stacked under
  this review's commits (no stash/reset/pop used).
