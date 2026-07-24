# TODO: path to full stock play

Policy: **proper stock wire/sim only**. No invented terrain, FX, or journal
blobs. Prefer leaving a gap open over shipping a fake.

| Doc | Role |
|---|---|
| [docs/STATUS.md](docs/STATUS.md) | What works now (wins on conflict) |
| [docs/MISSING_FEATURES.md](docs/MISSING_FEATURES.md) | Gap inventory |
| [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) | M7–M16 phases |
| [docs/INDEX.md](docs/INDEX.md) | Full doc map |

**Gates (2026-07-23):** 189/189 unit · 11/11 automated stock-client playtest (0 NRE/WRN/underrun) · 33/33 C2S · core loop clean-playable. Open work is **depth + scale**, not join.

---

## Open now (read this first)

### Parity polish (client-visible)

- [ ] Deco trees: re-enable when AssignIds match target client (V3.0.1 b4 dump or negotiate); currently suppressed (NRE on mismatch)
- [ ] Weather biome array S2C (fixed per-biome layout)
- [ ] GameStats HUD day counter
- [ ] Quest objective-type coverage beyond kill/goto/fetch/trader (Craft, StayWithin, Rally markers, …); see MISSING §6.1
- [ ] EAI: more task types and/or grid A* (greedy path remains); see MISSING §5.2.1
- [ ] Power: generator fuel ramp, battery SoC, trigger/timer actuation
- [ ] Lock contention beyond first-cut holder deny
- [ ] Optional: workstation RecipeQueue C2S depth beyond InvTx + TE sim
- [ ] Optional: Encryption* RSA+AES (platform AntiCheat only; not required for ServerPassword)

### M11 multiplayer CPU (1.0 scale gate)

- [ ] Dirty bitsets + serialize-once interest (biggest win)
- [ ] Persistent thread pool (replace spawn/join per `forRanges`)
- [ ] O(1) NetId → slot map
- [ ] Chunk stream pipeline caps + workers as needed
- [ ] 32-bot then 128-bot loadgen + apm budgets (criterion 7)

### P4 authority spine (formalize existing gates)

- [ ] Policy/mode config + AUTHORITY.md short doc
- [ ] Protocol phase × package matrix counters
- [ ] Entity ownership Hard reject centralization
- [ ] Movement envelope / inv cause ledger / evidence JSONL (see P4 section below)

### Parked

- [ ] Planet-scale M2+ gateway/shards (DEM M1 proven; after M11) — [PLANET_SCALE.md](docs/PLANET_SCALE.md)
- [ ] SpacetimeDB: **rejected** (SCALE_ARCHITECTURE.md)
- [ ] Steam browser / full telnet parity / RWG (P3 ops)

### P3 ECS ergonomics / scale brainstorm

Unchecked idea lists remain in **P3** and **Scale / concurrency** sections below.
Do not adopt third-party ECS cores.

---

## Shipped log (collapsed history)

Core loop and parity landings. Do not re-open without new evidence.

### Recent (2026-07-23)
- [x] **Stock EAI prioritized task graphs**: replaced the ad-hoc `switch (ai.state)` in `AiCtx.work` (`src/ecs/systems.zig`) with a faithful port of `EAITaskList::OnUpdateTasks` + `isBestTask` (asm.il:437713, :437874). Each zombie runs an ordered comptime task table (`zombie_tasks`) of `{priority, MutexBits, executeDelay, continuous}` cells with Start/Update/CanExecute/Continue hooks; every tick the best task is (re)selected by priority + mutex overlap (`(a.mutex & b.mutex)==0` = compatible) and projected back onto the coarse `ZombieAi.state` so all downstream replication (EntitySpeeds/AliveFlags, block-damage, despawn) is unchanged. Two real tasks: ApproachAndAttackTarget (chase+melee, mutex 0b11, delay 0.1, non-continuous; asm.il:421798) and Wander (mutex 0b01, continuous; asm.il:438104). Chase preempts wander on sensing a player; wander resumes on target loss via the mutex-release path. Director-seeded aggro (`alert && target_id>=0`) survives as long as the target entity exists. New `TaskId` enum + one `active_task` byte on `ZombieAi` (reuses `decision_cd` as the re-eval timer). +3 tests (189 total). Gaps documented (MISSING_FEATURES 5.2.1): greedy path kept (no A\*), only 2 of stock's task types real, no data-driven per-class `AITask` XML, sensing collapsed to nearest-player, timing/chaseTimeMax approximated.
- [x] **Electrical block placement parity**: placing a stock electrical block (`generatorbank`, `solarbank`, `batterybank`, `electricwirerelay`, `autoTurret`, plates/traps, …) now registers a `PowerGrid` node at the block world position and removes it on break (`electric.addNodeAt`/`removeAt`, idempotent + wire-compacting). Node kind from block `Class` in stock `blocks.xml` (`src/ecs/powerblocks.zig`); watts are real block props (`MaxPower` sources, `RequiredPower` consumers, parsed in `maxdamage.loadFromBlocksXml`). Real `NetPackageWireActions` bodies drive wiring: SetParent (op 0) `connectByPos(child,parent[0])`, RemoveParent (op 1) `removeParentAt(child)`, SendWires (op 2) no-op; grounded in asm.il:842779/842922/843021. `NetPackageWireToolActions` = peer visual rebroadcast only. Legacy custom wire op kept for demo. Gaps (documented, not faked): generator fuel ramp, battery SoC, trigger/timer/toggle actuation, undirected RemoveParent, AssignIds V3.1.4↔V3.0.1 skew (silent no-op on mismatch). +5 tests (180 total).
- [x] **POI/construction blocks rendered as untextured grey clay** (whole houses smooth marching-cubes terrain material): chunk block-layer only wrote the low 8 bits of each id (`stock_chunk.zig` hardcoded `upper24=false`), so every id ≥ 256 truncated to `id & 0xFF` → a wrong (usually terrain) block. Fix: emit the 3072 B/cell interleaved `m_Upper24Bits` array (`id>>8,>>16,>>24`) whenever a layer has any id ≥ 256, matching decompiled `ChunkBlockLayer.Read`. Terrain ids (<256) unaffected, that is why floor looked fine but houses didn't. Live: CGO 0→25, house textures correct.
- [x] **Large POI chunks failed to send** (side effect of the above: upper24 grew chunks to 14–37 KB → many fragments overflowed the 64-slot reliable window → holed chunk disk → CGO 0). Fix: `Peer.sendReliable` now resumes the same fragment stream and pumps ACKs mid-message via a `pump_fn` callback (`Game.pumpAcks`) instead of restarting; `body_buf` 256→512 KB. Live: 0 failed chunk sends.
- [x] **serverconfig.xml gameplay options fully wired** (`config.zig` → `initWithOptions` + runtime systems, all clamped + tested, docs/GAME_OPTIONS.md). Config-only: GameDifficulty (zombie hp), BloodMoonFrequency/Range/EnemyCount, PlayerKillingMode (PvP gate), DayNightLength/DayLightLength (clock/night), MaxSpawnedZombies, ZombieMove/Night/Feral/BMMove + EnemyDifficulty → `World.zombie_speed_scale`, LootAbundance (roll count scale). New backing systems built so the rest apply too: **MaxSpawnedAnimals** (daytime animal spawner + cap), **XPMultiplier** (`Game.awardXp` server ledger on kill), **BlockDamagePlayer** (scales dig damage in SetBlock), **BlockDamageAI/AIBM** (`tickZombieBlockDamage`: zombies chew cover), **AirDropFrequency** (`tickAirDrop`: scheduled supply crate), **DropOnDeath** (loot bag on player death per mode), **LandClaim** (keystone placement → `land_claims`; non-owner SetBlock denied inside `LandClaimSize`; own-claim durability ×`LandClaimOnline/OfflineDurabilityModifier`). Also: serverconfig with a missing world folder falls back to flat instead of crashing (`main.dirExists`).
- [x] "Starting game..." wedge: WorldInfo fixedSizeCC=true (authored worlds are fixed-size CC; overlay gate CGO>=viewDist²-10 unless fixed-size → 0). pw24 fully in-game with HUD. Connect mod SpawnStateHeartbeat logs all overlay gates.
- [x] Admin persistent session + replies; restart_pair.sh harness script
- [x] Player death flow: sim keeps dead player entity (destroy() broke all later net-id lookups: give/kill "missed"); DamageEntity/deferred-damage skip EntityRemove for players; admin kill player → hp=0 EntityStatChanged so client death screen runs; RequestToSpawnPlayer heal-when-dead already handles respawn; pw25 live: kill → "Respawning: Died" → back in-game
- [x] Live-spawn replication: replicate() sends stock ECD EntitySpawn for dirty.spawn zombies/animals in range (director hordes + sleeper wakes were invisible: only PosAndRot went out)
- [x] Spawn-on-approach: per-client known_entities bitset (512 bits); replicate sends ECD spawn first time a zombie/animal enters range; bits cleared on slot death/recycle; join spawns marked known; pw27 soak green (kills → Items:3, no dup-spawn errors, admin replies "killed")
- [x] EntityRemove wire = entityId:i32 + reason:u8 (Killed=2); unit + pw14 admin kill no NCSimple underrun
- [x] Client HUD Zom always 0 on MP (EnemyCount server-only ephemeral); gate on Ent not Zom
- [x] sendGame WindowFull soft-drop (was crashing dedi post-join chunk flood)
- [x] admin `kill <entityId>` on `--admin-port`
- [x] NetPackageBag is ToServer-only (IL dir=1): removed all S2C Bag/PlayerInventory sends; loot contents now ride ECD `bag` field (Bag.Write) inside EntitySpawn; S2C inv echo = HoldingItem only
- [x] AGENTS review sweep 1: join-phase gate (unjoined peers only handshake pkgs); Bag ownership (no cross-player inv writes); DamageEntity strength cap 200 + fatal only vs NPC; SetBlock/Explosion/TileEntity reach checks (96 blocks); respawn heal only when dead; savePlayers debounced to save tick
- [x] AGENTS review sweep 2: deleted dead parallel encoders (simplified EntitySpawn, ZCHC/ZCHL chunk, ZTE1 TE, native inv/holding, legacy WorldInfo); comptime Unity hashes for entity classes (pinned by test); RE tools moved to ../7dtd-research/il/zdtd_re_tools; em dashes purged repo-wide; apm chunk_stream section + join_fail counter wired; dead apm sections pruned

Review backlog sweep 3 (2026-07-22, all landed + pw19 live green Items:3):
- [x] ContainerStore persist (`containers.zct`) + block_hp/block_raw persist (`blockmeta.zbm`); save tick + deinit
- [x] seedChestBlockId resolves via AssignIds dump `idByName` first; pin fallback
- [x] readItemValueData: deterministic per ItemValue.ReadData IL (mods/cosmetics always at v9 top level; nested = modifier path; version-gated tail); no remaining() guessing
- [x] parseExplosionInitiate: positional ExplosionData.Read (i16 radius*0.05, f32 BlockDamage) per IL; scan heuristic deleted
- [x] broadcastNear interest filter (160 blocks) for SetBlock/ExplosionClient/loot EntitySpawn; unknown player = deliver (join in progress)
- [x] items.xml Stacknumber parsed; ItemTable.stackFor; inventory maxStackFor from builtin catalog
- [x] Turret/AI kill loot refilled from loot.xml before spawn broadcast
- [x] store.zig writeAll/readAll (short IO = error); resident chunk cap 4096 + evict-save
- [x] blocks.zig solidity exact-match air/water (was substring); WindowFull retry ≤~8ms; sendHoldingEcho rename; loadPlayers noop deleted
- [x] wander RNG per-entity xorshift32 (was constant hash drift)

- [x] players.zsv v2: quality/meta per slot + journal quests persisted; restore into slot order + journal; join PDF now carries restored toolbelt/bag stacks (buildPlayerIdBodyInv); pw27 E2E: give→save→restart→rejoin→`inv 0` shows persisted slots
- [x] admin `inv <slot>` probe; admin `give` now drops a loot bag at the player (server inv writes were clobbered by client C2S PlayerInventory pushes; pickup is client-authoritative)

Scale track (docs/SCALE_ARCHITECTURE.md, research-verified 2026-07-22):
- [x] M1 DEM streamer proven live (GLO-30 COG; world/dem.zig)
- [ ] M2 gateway split (parked; after M11)
- [ ] M3 two static shards + handoff (parked)
- [ ] M4 thread-per-core N shards (parked)
- SpacetimeDB: **rejected** (SCALE_ARCHITECTURE.md)

### More shipped detail (2026-07-22..23)

- [x] biomes/blocks id-space review; player save v2; traderAlways + EconomicValue
- [x] Zombie speeds/damage from XML; director class rotation; pop cap + far-despawn
- [x] Workstation TE wire + Recipe parse + 2Hz sim + output materialize
- [x] WindowFull tiering; admin TCP expansion; sleeper authored markers
- [x] Rejoin y-clamp; PPD join name; void rescue; PosAndRot authority
- [x] Playtest driver 11/11; C2S 33/33; PACKAGES.md; BloodmoonMusic (HordeEvent unwired)
- [x] Deco suppress (AssignIds skew); core loop clean-playable pw38
- [x] TTS planes; ServerPassword; AssignIds dump; chunk upper24; land claim options

Open scale/parity items: see **Open now** at top.

---

## P0 (blocks real play) — CLOSED

All items below shipped. Kept as historical checklist.

- [x] **TTS density + damage channels**  
  Load sbyte density + u8 damage planes after block types in `.tts`. Texture/TE
  lists still open. File: `src/world/tts.zig`.

- [x] **TTS name→id remap**  
  Stock V3.x `.tts` types already AssignIds-range (max ~24k on sample POI).  
  Remap only if client/server id tables diverge; `.blocks.nim` exists for that.

- [x] **Prefab `part_*` paint policy**  
  Skip all `part_*` TTS paint (driveways/road clutter). Heights still flatten.
  Full POIs only. Documented in `prefabs.applyTtsPaintToChunk`.

- [x] **Sleeper volumes**  
  Parse prefab sleeper metadata; wake on player enter (not free-roam sleepers only).  
  `src/world/sleepers.zig` + Game.tickSleeperVolumes (near-spawn POI budget).

- [x] **Prefab loot TEs (first cut)**  
  On chunk stream, scan TTS-painted known storage AssignIds; create TE + roll
  `woodenChest` loot. Full prefab TE list from TTS tail still open.

- [x] **Craft / recipes (first cut)**  
  Load `recipes.xml`; PlayerId unlockedRecipeList = always_unlocked names.  
  InvTx op=craft consumes ingredients + grants output. Stock craft queue UI
  packages still shallow. `src/assets/recipes.zig` + `Game.tryCraft`.

- [x] **ExplosionInitiate C2S (first cut)**  
  Parse head; sphere dig + ExplosionClient broadcast. Nested blob radii shallow.

- [x] **LockManager contention (first cut)**  
  Per-channel holder peer; deny when held; unlock ownership.

- [x] **Entityclasses + animals (first cut)**  
  `entityclasses.xml` → name/hash/HP/kind/LootDropEntityClass; animals spawn;  
  ECD uses class hash. `src/assets/entities.zig`.

- [x] **Entitygroups (first cut)**  
  `entitygroups.xml` weighted pick; director uses class_table default walker.
  `src/assets/entitygroups.zig`.

- [x] **Loot tables (first cut)**  
  `loot.xml` groups/containers; death bag fill from LootDropEntityClass.  
  Prefab TE loot still open. `src/assets/loot.zig`.

- [x] **Quest journal phase/location (first cut)**  
  PlayerId journal writes current_phase + location for active quests.  
  Full objective subclass graphs / NavObject still open.

- [x] **Quest objective phase/location (expanded)**  
  Phase + location in journal; subclass/NavObject graphs still open.

- [x] **Quest NavObject (first cut)**  
  Join sends stock `quest` / `go_to_trader` / `return_to_trader` NavObject markers.  
  Full objective subclass graphs still incomplete.

- [x] **Quest multi-phase (first cut)**  
  phase field; trader open advances Goto→Interact; journal current_phase.  
  Full subclass CurrentValue wires (ClearSleepers/Rally/etc.) still open.

- [x] **Quest objective values (expanded)**  
  Journal writes per-objective CurrentValue; active phase gets progress byte.  
  Subclass-specific extra fields (RallyPoint/ClearSleepers graphs) still open.

- [x] **Quest objective subclass extras (IL-verified)**  
  BaseObjective = version+value; TreasureChest = 2×i32; POIStayWithin empty.  
  Other types inherit base (Assembly-CSharp monodis).

- [x] **Quest multi-phase objective execution (real phase graph)**  
  `QuestDef.phases`/`highest_phase`/`objective_phases` built from objective
  `phase` attr or nested `<property name="phase">`; `QuestProgress` advances
  phase-by-phase per `Quest.refreshQuestCompletion`/`AdvancePhase` (goto → kill →
  fetch → trader-interact), TurnIn at highest phase; leading `.auto` scaffolding
  auto-skips; per-objective CurrentValue emitted (completed=255). Legacy
  phase-less defs keep single-kind path. Gaps in MISSING_FEATURES §6.1:
  one advancing objective per phase, RallyPoint/StayWithin/UnlockPOI auto, no
  fail/optional tracking, unmapped types (Craft/Repair/Buff/…).

---

## P1 (play quality)

- [x] **Block damage (first cut)**  
  Sparse HP accumulate on SetBlock damage; break at 500. Upgrade/paint still open.

- [x] **Doors / open state (storage pair)**  
  Chest closed↔open AssignIds keep same TE contents. Generic door meta still open.

- [x] **World spawn points S2C (stock wire)**  
  `NetPackageWorldSpawnPoints` ver=2 + u16 pad/point (26 B/pt).  
  pw6/pw7 `result=joined` Found own player 107.  
  Bedroll / land-claim ownership still open.

- [x] **Vehicle stock packages (first cut)**  
  Spawn/positions/control + attach + fuel burn/stall. Multi-seat/storage still open.

- [x] **Vehicle physics: terrain-follow + collision (first cut)**  
  Server gravity accumulator (`cGravity` -9.81) + terrain-top clamp in
  `systemVehicles` via optional `World.ground_fn` hook (block store backed).
  Clamped y rides the existing VehiclePositions wire. Gaps: suspension/engine,
  gyrocopter thrust, entity/block-side collision, slope tilt (documented).

- [x] **Trader economics (first cut)**  
  Daily restock; price/sell tables. Dukes item id still casinoCoin alias.

- [x] **Trader UI parity (stock TraderData wire)**  
  Fixed `NetPackageTraderData` envelope: entity id XORs tePosition (dropped the
  stray Vector3i that desynced the client read), so the full stock TraderData v2
  body now parses and real `traderAlways` stock shows. Removed unused
  `buildTraderDataEntityOnly` foot-gun. Markup sent as 0 (honest neutral: no
  per-item demand source). Gaps in docs/MISSING_FEATURES.md: markup drift,
  TierItemGroups, trader wallet economy, restock depth, group refs.

- [x] **SharedQuest quest_code**  
  Monotonic `next_quest_code` on accept; remove matches code (def_id fallback).

---

## P2 (ops / multiplayer polish)

- [x] Party / ally echo (first cut) - full PlatformUserIdentifierAbs deferred
- [x] Kick/ban/list on admin TCP (first cut); ServerPassword = LiteNet connect key
- [x] Admin TCP: kick/ban/unban/list/give/tele/say/save (not full telnet parity)
- [x] LiteNet: reliable+frag HAVE; unreliable sendUnreliable; sequenced still MISSING
- [x] Per-IP join rate limit (~500ms; loopback exempt)
- [x] Reconnect by player name (players.zsv pos/inv/coins) - platform id still open
- [x] Biome id from biomes.png color→biomemap id (stock keys); height-band fallback  
  Spawn (-273,449) → burnt_forest id 9. pw7 ChunkCalc no OOB.
- [x] Pathfinding BFS (first cut) - `path.bfsToward`; greedy fallback

---

## Explicit non-goals (do not put here)

- Mod host / Harmony / EfficientServer
- 7dtd-apm Mono bridge
- EAC-on
- Shipping TFP assets or redistributing game DLLs
- Adopting knoedel (or any Bevy-style archetype ECS) as the sim core
- Loading `7dtd-server-guard` (or any Harmony anti-cheat DLL) into zdtd
  (reimplement authority in-process; see P4)

---

## P3 - ECS ergonomics to steal (ideas only; keep our SoA core)

**Do not adopt** any third-party ECS as sim storage. Keep dense SoA + explicit
`tickAll` + `util/parallel` + stock net ids. Steal *patterns* that cut bugs or
scale cost without archetype graphs or auto system reordering.

### Survey (Zig ECS landscape, 2026)

| Project | Stars / notes | Storage | Steal? | Skip / why |
|---|---|---|---|---|
| [prime31/zig-ecs](https://github.com/prime31/zig-ecs) | ~423; Entt port | sparse sets; View / Group / OwningGroup | View vs Group cache idea; `each` struct packing | Full Registry; OwningGroup reorder churn fights fixed slots + net ids |
| [Games-by-Mason/mr_ecs](https://codeberg.org/Games-by-Mason/mr_ecs) (was ZCS) | active; Zig master; SoA chunks | archetype chunks; **no alloc after init** | **CmdBuf** + Exec; gen-counted handles; chunk/forEachAsync; capacity warnings; Tracy zones on cmds | Archetype core; parent/child Node tree (not our model) |
| [Avokadoen/ecez](https://codeberg.org/avokado/ecez) | comptime API; was GitHub | storage + systems | **Storage.Subset** (limited mut surface); ezby-style snapshot bytes; **ztracy** markers | Implicit multi-thread dispatch reorders work; EventArgument unsynced |
| [Lommix/knoedel](https://github.com/Lommix/knoedel) | ~44; Bevy-like; Zig 0.16 | archetype + schedules | Res/ResMut; Local; Commands; Chain order; Jobs arg | Auto lock-free schedule by access sets; plugin/hot-reload host |
| [zig-gamedev/zflecs](https://github.com/zig-gamedev/zflecs) | bindings to Flecs C | Flecs tables/queries | **Pipeline phases**; observers (on-add hooks); prefab/template pattern; REST/monitor *ideas* only | C runtime + full Flecs in process; query language overkill |
| [freakmangd/zentig_ecs](https://github.com/freakmangd/zentig_ecs) | Bevy-ish; early | stages + WorldBuilder | **named stages** + `cleanForNextFrame` arena; include/module layout | Not battle-tested; full builder infection |
| [linuxy/coyote-ecs](https://github.com/linuxy/coyote-ecs) | simple; old Zig | component store | little | Stale Zig; unique-comp-per-attach model |
| [hexops/mach-ecs](https://github.com/hexops-graveyard/mach-ecs) | graveyard / experimental | dynamic tooling focus | tooling/trace *philosophy* | Unstable; not a dependency |
| SpexGuy/Zig-ECS, zplanck, others | small / old | various | skip | Abandoned or toy |

**Closest fit for ideas:** mr_ecs (command buffers, fixed capacity, chunk parallel)
and ecez (subset mutability, tracy, binary snapshot). **Closest to avoid as core:**
knoedel/Flecs/zentig full stacks.

### Steal checklist (implement in-tree)

From **knoedel / Bevy shape** (already listed, kept):

- [ ] **Typed resources** - `Res`/`ResMut` helpers over `World` fields  
- [ ] **System locals** - named tick/join scratch; no hidden statics  
- [ ] **Query helpers** - SoA mask `forEach` / comptime With-Without; no archetypes  
- [ ] **Explicit schedules** - ordered phases only; parallel *inside* phase  
- [ ] **Jobs helper** - batch onto persistent pool + wait-group  

From **mr_ecs** (high value for dedi):

- [ ] **Tick command buffer** - reserve/spawn/despawn/add-mask/damage as deferred
  ops; `Exec` at phase boundaries so parallel AI never mutates structure  
- [ ] **Generation-counted handles** (if/when slot reuse bites) - net id stays
  stable for wire; internal slot gen prevents stale AI/target pointers  
- [ ] **Fixed capacities + soft warnings** - entity/stream/cmd caps; warn past ~80%
  (apm counter), fail closed at hard cap  
- [ ] **Chunk-style parallel for** - iterate contiguous SoA ranges / interest cells
  with optional `std.Io` or pool; same as extending `forRanges`  
- [ ] **Cmd profiling zones** - name deferred batches in apm/tracy-style sections  

From **ecez**:

- [ ] **Storage subset / capability** - handlers get `SimView` that can only touch
  allowed columns (inv vs AI vs world); documents authority boundaries in types  
- [ ] **Optional Tracy/ztracy markers** behind build flag; map onto `src/apm/`
  sections first, Tracy second  
- [ ] **Sim snapshot bytes (ezby-like)** - deterministic dump of SoA + resources for
  regression tests / replay; not a second save format for `.zch2`  

From **zig-ecs (Entt)**:

- [ ] **View vs cached Group** - default open mask scan (View); optional maintained
  dense list of alive zombies/players/turrets updated on spawn/despawn (Group)
  to skip full-capacity scans as `max_entities` grows  
- [ ] **`each` packed args** - `fn(struct { ai: *ZombieAi, t: *Transform })` sugar
  over parallel columns (comptime zip); no runtime query object  

From **Flecs / zflecs** (ideas only, no C dep):

- [ ] **Named pipeline phases** - already `tickAll`; document as pipeline; add
  pre_replicate / post_net hooks without a scheduler crate  
- [ ] **Observers / hooks** - on-spawn / on-death callbacks registered in one place
  (loot ECD, quest kill, interest untrack) instead of scatter in game.zig  
- [ ] **Prefab/template spawn** - “zombie from entityclasses row” as a fill-from-
  catalog helper (we load XML; avoid Flecs prefab graphs)  
- [ ] **Remote monitor** - optional admin/apm HTTP or existing admin TCP metrics;
  do not embed Flecs explorer  

From **zentig**:

- [ ] **Frame arena reset** - `cleanForNextFrame` equivalent: clear tick command
  buf, path scratch, encode scratch in one place at end of `step()`  
- [ ] **Module include layout** - keep systems split by file; single `tickAll`
  order list (not a WorldBuilder DSL)  

### Still skip (reaffirm)

- Archetype graph as entity storage  
- Auto parallel by access-set inference  
- Plugin/hot-reload host, dylib systems  
- Flecs/C or any ECS as git dependency on the hot path  
- Parent/child scene graphs for net entities (stock wire is flat net ids)

---

## Scale / concurrency brainstorm (path, not a rewrite)

Target: 20 TPS (50 ms), stock wire fidelity, seed-stable sim, serialize-once
interest. Net and join SM stay single-owner. Parallelism is for *bulk work with
disjoint writes*, not "everything lock-free."

### Principles

1. **One authority thread for rules that touch shared truth** (join SM, C2S
   apply, lock table, player inv ownership, world time). Workers never accept
   untrusted C2S directly.
2. **Parallelize by data partition**, not by racing systems: entity slot ranges,
   chunk keys, interest cells, outbound peer queues.
3. **Serialize-once**: encode dirty entity/chunk/TE bytes once per tick; fan out
   with memcpy/refcount to interested peers (M11 plan).
4. **Determinism first**: fixed phase order; seeded RNG; parallel reduce only
   via commutative ops (damage FP sums) or post-sort apply.
5. **Caps everywhere**: entity cap, stream queues, pending chunks, deco, path
   jobs. One peer must not blow the 50 ms budget.
6. **Measure with `src/apm/`**: section latency for net poll, tickAll phases,
   interest gather, chunk encode, send. Scale claims need dumps, not vibes.

### Near-term (unblocks real multiplayer CPU)

- [ ] **Persistent thread pool**  
  Replace spawn/join-per-`forRanges` with a long-lived pool (`util/parallel` or
  sibling). Same range API; lower tail latency on AI/turrets/save.

- [ ] **Dirty-bit interest + serialize-once**  
  Spatial hash / cell interest; gather dirty transforms once; queue shared
  bytes per observer. Goal: replicate cost ~ O(dirty × interest), not O(players²).

- [ ] **Chunk stream pipeline**  
  Decode/paint/encode stages with bounded queues: load/TTS on workers, main
  thread only commits store + enqueues S2C. Named caps on pending per peer.

- [ ] **Sharded world store**  
  Per-chunk or per-region mutex / ticket; block edits only on owned shard.
  Parallel pathfind read snapshots or epoch; writers stay tick-ordered for the
  same chunk.

- [ ] **Outbound net fan-out**  
  Build frames on tick thread (or encode workers into peer-local buffers);
  `sendto` batching; optional per-peer send worker only if apm shows send bound
  (careful: ordering and LiteNet state stay consistent).

### Mid-term (density / maps)

- [ ] **Entity capacity policy**  
  Raise `max_entities` with pooling; despawn far sleepers; director budget by
  cell. Dense SoA scan stays OK if masks are tight and dead slots sparse.

- [ ] **AI LOD already present** - push further: far agents throttle, sleep in
  unloaded cells, path requests as jobs with per-tick solve budget.

- [ ] **Path / sleeper / TE loot as job batches**  
  Jobs helper + pool; results applied serially in phase order.

- [ ] **Parallel chunk save** (have first cut) - extend to async flush without
  blocking tick; double-buffer dirty set.

- [ ] **Read-mostly snapshots**  
  For interest and AI: copy player positions (already) and optionally a
  compact spatial index once per tick; workers read snapshot only.

### Far-term / only with evidence

- [ ] **Multi-world or region shards** (separate processes or large regions)
  only if single-process 128–256 peers still fail budgets after serialize-once.
  Cross-shard entity migrate is a product decision, not a default.
- [ ] **Lock-free queues** at net edges (C2S parsed packets in, S2C frames out)
  if contention shows; keep sim apply single-threaded.
- [ ] **SIMD** on hot SoA columns (distance checks, mask scans) after profiles
  say so; micro-opts second to interest/encode structure.
- [ ] **io_uring / recvmmsg batching** on Linux UDP path when packet rate binds.

### Anti-patterns (scale)

- Global "ECS auto-parallel" that reorders systems by access sets  
- Shared mutable world from many threads without partitions  
- Encoding the same entity N times for N peers  
- Unbounded chunk/entity spawn queues "to catch up"  
- Thread per peer or thread per package  
- Measuring only host CPU without zdtd apm section splits  
- Chasing lock-free purity on the authoritative apply path  

### Suggested order of attack

```text
1. apm sections on tick + replicate + chunk stream (baseline)
2. persistent pool (cheap win on current parallel systems)
3. dirty bits + serialize-once interest (biggest multiplayer win)
4. chunk stream workers + caps
5. sharded store / path jobs as maps and entity counts grow
6. only then consider process sharding
```

Detail and status for interest/pool also live in
[docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) M11 and
[docs/ECS.md](docs/ECS.md). Update those when an item ships.

---

## P4 - Native authority / anti-exploit (server-guard ideas in-process)

**Source:** sibling [`7dtd-server-guard`](../7dtd-server-guard/) docs
(`THREAT_MODEL`, `ARCHITECTURE`, `SIGNALS`, `POLICY`). That project is a
Harmony mod for **stock** dedi. **zdtd does not load it.** We implement the
same *authority outcomes* inside the Zig apply path (AGENTS rule 15: server
owns state; C2S is a request).

### How it maps

| server-guard layer | zdtd home |
|---|---|
| HookRegistry / Harmony seams | C2S dispatch in `server/game.zig` (already the only apply path) |
| ObservationAdapter | Decode once into typed request structs; no raw blob apply |
| PlayerSessionRegistry | Peer slot + entity id + join SM phase + platform/name epoch |
| ContextSnapshot | Ping/RTT when known, tick debt (`apm`), vehicle seat, death/spawn flags |
| Movement / Combat / Inv / World ledgers | Small per-peer or per-entity structs next to sim; not a second world |
| ProtocolState | Existing join SM + package allowlists per phase |
| InvariantEngine | Hard rejects at apply (return / drop / correct) |
| BehaviorEngine | Optional later; Weak signals only `record` |
| EvidenceStore | Append-only JSONL under world/log dir; redaction defaults |
| ResponseCoordinator | Modes: observe / correct / (later) kick; no auto permanent ban |
| Metrics | `src/apm/` counters: rejects, drops, ledger hits, queue depth |

### Policy (adopt, keep small)

Mirror guard `POLICY.md` vocabulary, operator-facing:

- Default **Observe**: counters + optional evidence file; gameplay unchanged.  
- **Correct**: reject/clamp **Hard** invariants only (impossible transitions).  
- **Enforce** (opt-in, late): quarantine capability bits or kick after gates;
  never automatic permanent ban; never VAC.  
- Severity: Hard → may correct; Strong → needs repeat/independent; Weak → record
  only (aim/ESP-style: mostly N/A without client rotation fidelity).  
- Suppress soft scoring on join/spawn, teleport, death, stall, explosion impulse.  
- Attribute induced findings to initiator, not victim (container races, knockback).

### Already have (partial; tighten, do not reimplement blind)

- [x] Join SM phase gating (challenge → ids → login → enter → spawn → play)  
- [x] Per-IP join rate limit (~500 ms; loopback exempt)  
- [x] Ban list + kick on admin TCP (first cut)  
- [x] ServerPassword LiteNet Connect key (not Encryption*)  
- [x] Lock channel holder deny  
- [x] InvTx / craft consume server-side; TE lock path  
- [x] Some bounds on package body handling  

Gaps vs guard signal catalog are the checklist below.

### Architecture sketch (zdtd-native)

```text
UDP recv → LiteNet → deframe/decode
  → phase allowlist (ProtocolState)
  → typed C2S request (no blind blob)
  → Context (peer, entity ownership, vehicle, tick health)
  → Hard invariants (reject/clamp)     // Correct mode
  → sim apply (ecs / world store)      // authoritative result
  → optional ledger append + evidence  // Observe always capable
  → interest replicate result state
```

Layout proposal (when started):

```text
src/guard/           // or src/authority/
  root.zig
  policy.zig         // mode ladder, action enum
  protocol.zig       // phase × package allow + token buckets
  movement.zig       // last pos, budget envelope
  combat.zig         // cadence, reach, held-item checks
  inventory.zig      // double-entry causes (or fold into ecs/inventory)
  world_action.zig   // block reach, claim, explosion consume
  evidence.zig       // JSONL writer, redaction, hash chain optional
  metrics.zig        // thin wrappers over apm counters
```

Keep hot path allocation-free: fixed per-peer ledgers, ring of findings, drop
soft observations under load (apm `guard_drop_*`). No network IO on tick thread
for evidence (buffer → flush in admin/tick tail or dedicated writer later).

### Implementation checklist

**P4.0 - Spine (do first)**

- [ ] **Policy + mode config** - `observe` default; per-family correct flags;
  document in `docs/` (short AUTHORITY.md) pointing at server-guard POLICY  
- [ ] **Protocol allow matrix** - package name/id × join phase; illegal → drop +
  counter; reconnect/resume paths named  
- [ ] **Entity ownership** - C2S entity id must belong to connection (or
  documented delegated set: driven vehicle, owned turret); else Hard reject  
- [ ] **Decode validation** - NaN/Inf, coord range, stack size, string/enum
  lengths; fail request safely (already partially true; centralize)  
- [ ] **Cost-class token buckets** - per-peer budgets for join, inv sync, chat,
  setblock, damage, chunk req; `throttle` under pressure; never counts as “cheat
  score”  
- [ ] **apm counters** - `c2s_reject_*`, `c2s_throttle`, `guard_observe_drop`  

**P4.1 - Hard invariants (Correct mode)**

- [ ] **Movement envelope** - accepted pos + max speed/accel over server dt +
  latency slack; debt/credit cap; reset on teleport/spawn/vehicle enter;
  excess → clamp to last good + Strong record (Correct: rubber-band)  
- [ ] **Block / TE reach** - interaction distance + loaded chunk; claim/lock
  already partial; locked TE without grant → reject  
- [ ] **Inventory conservation** - every delta needs a cause (loot, craft,
  trade, drop, pickup, quest, admin, death bag); unexplained positive → reject
  or strip + Strong evidence  
- [ ] **Stack / quality bounds** - from items.xml tables; Hard  
- [ ] **Craft** - ingredients/time/recipe already first-cut; close workstation
  queue if/when C2S exists; else treat opaque TE sync carefully (no blind trust)  
- [ ] **Damage** - attacker alive; held item/ammo when we have it; target exists;
  reach vs hit volume; rate vs item action; reject impossible HP/damage fields;
  do not claim aimbot Hard  
- [ ] **Explosion** - inventory consume / authority for initiate; radius caps  
- [ ] **Privileged ops** - admin TCP / give / tele only from admin path; game
  C2S cannot self-grant  

**P4.2 - Ledgers and evidence**

- [ ] **Per-peer movement ledger** - samples, last correction, grace windows  
- [ ] **Combat ledger** - last swing/shot times, reload, target ids  
- [ ] **Inv ledger** - cause-tagged deltas (fold into invtx path)  
- [ ] **Evidence JSONL** - schema version, time, peer/entity pseudonym, detector
  id, severity, observed vs bound, action; no raw packets, no secrets, no IP by
  default (hash/pseudonym); optional hash chain later  
- [ ] **Admin visibility** - `guardstats` / apm dump section; kick message carries
  rule id + evidence id when Enforce exists  

**P4.3 - Soft / availability (Observe, then throttle)**

- [ ] Flood / churn signals (reconnect rate, malformed decode rate)  
- [ ] Weak farming/efficiency signals: record only, never kick  
- [ ] Global load shed: drop soft observes and defer non-essential streams  

**P4.4 - Enforce (only after dry-run)**

- [ ] Quarantine flags: no damage dealt / no container / no setblock (separate
  bits)  
- [ ] Kick after policy gates (2 independent Strong or repeated Hard + opt-in)  
- [ ] Dry-run mode: log “would kick” until operator enables  
- [ ] Scenario tests: malicious C2S fixtures in `scenarios.zig` (speed, dupe
  inv, wrong entity id, phase violation)  

### What not to port from server-guard

- Harmony / ModEvents / build-pinned IL tokens  
- Client memory or EAC integration  
- Automatic aimbot/ESP bans from rotation time series (stock wire too coarse;
  Weak/review only if we ever sample rot)  
- Dashboard/webhook auth surface (use existing admin TCP + files)  
- AGPL DLL in-process; reimplement ideas under zdtd license/tree  
- Treating loadgen bots as cheaters without test bypass / loopback exempt  

### Suggested order

```text
1. Protocol phase matrix + ownership + decode bounds + apm rejects
2. Token buckets (availability)
3. Movement clamp + block reach (visible Correct wins)
4. Inv cause ledger on existing InvTx/craft/loot paths
5. Damage reach/cadence Hard checks
6. Evidence JSONL + scenarios
7. Dry-run Enforce → opt-in quarantine/kick
```

Playability and wire fidelity stay P0; guard work must not invent package
shapes or weaken stock `Read`. Prefer missing detection over false Correct.

---

## Verification checklist (each P0)

1. Unit test for wire layout (golden bytes or round-trip fields).  
2. Stock client join still 0 NRE / no NCSimple EOF.  
3. Feature-specific log or capture proof (no silent fakes).  
4. Update [docs/STATUS.md](docs/STATUS.md) and this file when a box is closed.
