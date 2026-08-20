# Status: stock-client join and play path

**Date pin:** 2026-08-08  
**Game line:** V 3.x Mono (connected client **V3.1.0 b14**; bundled AssignIds dump byte-matches this client's runtime block ids), EAC off  
**Validation:** `make check` passes (`zig build test`, fuzz, and
`lint-architecture: clean`); `game.zig` delegates to 42 shards in
`src/server/game/*.zig` aggregated through `src/server/root.zig`, and `c2s/*`
owns all C2S domains. `GAP_ANALYSIS.md` scores 329 features: 150 `WORKS`,
136 `PARTIAL`, 44 `MISSING` (see its scorecard for the per-area breakdown).
**Policy:** proper stock wire/sim only; missing preferred over fakes (see residual gaps)

This is the hub for "what works now" vs `GAP_ANALYSIS.md` (full inventory) and
`IMPLEMENTATION_PLAN.md` (phased plan). Doc index: [INDEX.md](INDEX.md).

## Wave 2026-08-20 (surface-parity reconciliation)

GAP_ANALYSIS reconciled against the code (STATUS wins on conflict): five
client-visible rows were stale and flipped to WORKS - stability/support
collapse, biomes.png + radiated biome damage, land-claim + bedroll spawn,
bedroll/last-logout persistence, and velocity packages. Net and ops area
16/27/9 -> 21/25/7; total 135/141/53 -> **140/138/51**. Two follow-up
slices: projectile/ranged combat verified WORKS (client-side projectiles),
then the AI senses row WORKS (smell + per-class cone), taking the total to
**142/138/49**. Next, MoveHelper physics/collision went MISSING -> PARTIAL
(collide-and-slide + step-up + stock gravity, RE entity-movement.md), total
**142/139/48**. Then the RWG water table (fluids/aquifers) and the water
flow dig-leveling both shipped, total **142/140/47**. Then crouch stealth
(hear muffle + sleeper detect) went MISSING -> PARTIAL, total
**142/141/46**. Then group AI (combat-noise alerts + sleeper wake) went
MISSING -> PARTIAL, total **142/142/45**. Then falling blocks (collapse
groups spawn EntityFallingBlock entities, fall + die on landing) went
MISSING -> PARTIAL, total **142/143/44**. Then the Demolition (zombieCop)
prime-and-explode shipped (RE entity-ai.md EntityZombieCop; entity + block
AoE), moving a bosses sub-item to WORKS inside the still-PARTIAL special
infected row. Reconciliation: the trader quest-list row (per-trader offers
via NetPackageNPCQuestList + accept marker) was stale PARTIAL - the window
is driven end to end, flipped to WORKS, total **143/142/44**. Then the
blood-moon schedule row went WORKS (stock CalcNextDay persisted on the
clock as ZCL2, seekable across restarts and day jumps), total
**144/141/44**. Reconciliation: GameStats.BloodMoonDay re-broadcasts on any day change (the step.zig per-tick diff already covered settime jumps), so the stat-58 row went WORKS, total **145/140/44**. Then the blood-moon warning-window row went WORKS (default red clock at hour 8 on the horde night; operator SandboxCode forwarded verbatim), total **146/139/44**. Then the BloodMoonRange jitter row went WORKS (persisted CalcNextDay schedule jitters non-negative 0..range; stat 58 reads the same jittered day), total **149/136/44**. Then BloodMoonEnemyCount semantics went WORKS (the party spawner enforces the stock min(30, count*members) per-party alive cap), total **150/135/44**. Then the provenance audit ledgered the recent behavioral constants and fixed dashboard/header drift. Then the dawn-end row went WORKS (horde marks clear at dawn; a wiped party kills its horde - KillPartyZombies, 2026-08-21), total **151/135/44**. Then the spawn-placement row went WORKS (seeded per-spawn bearing jitter breaks the repeating pattern; ring radii stay the A36 rules tunable), total **152/134/44**. Then the challenges-system row went WORKS (client-tracked per RE quests-challenges.md S5; server surface is the challengegroup_reward_* quests + GameEvent acks) and the NPC-dialog row was documented as non-client-visible on stock maps, total **153/133/44**. Then the quest wire-package and localization-title rows went WORKS (the journal body is stock-shaped per stock_quest.zig - QuestJournal.Write v5/Quest.Write v8; the server sends localization keys the client resolves locally), total **155/131/44**. The dashboard (docs/provenance.html) is synced.

**Client-visible parity queue (goal: 100% surface parity), ranked by client
impact:** (2026-08-20: projectile/ranged combat verified WORKS - RE
items.md:1097-1140: projectiles are client-side GameObjects, the server
surface is the DamageEntity C2S claim, which is complete; AI senses shipped
WORKS - per-class view cone (entityclasses MaxViewAngle, stock 180 default
halved), block-LOS sight, hearing through walls, and smell with a bleeding
extension, RE entity-ai.md CanEntityBeSeen + PlayerStealth; CanSeeStealth's
light-level leg stays RE-blocked, no server light channel)

1. MoveHelper physics / collision (PARTIAL - collide-and-slide + step-up + stock gravity shipped 2026-08-20; jump/dig/swim/elevator/push/door open)
2. RWG depth: climate/biomes, carved caves, POI/WFC placement (fluids/aquifers shipped 2026-08-20 - water table fills basins to the stock 62.88 surface)
3. Water flow / physics (PARTIAL - dig-leveling pours basins beside existing water 2026-08-20; placed water no cascade, no mass-flow/evap/drain)
4. Stealth / crouch (PARTIAL - crouch replicates (flags bit 512), hearing muffled 0.5x, sleeper detect 5; light-level leg RE-blocked 2026-08-20)
5. Group AI / pack behavior (PARTIAL - combat-noise alerts + sleeper wake 2026-08-20; no pack hunting/horde directives)
6. NPC dialog trees (MISSING - no stock-map NPC dialog surface beyond traders, whose quest/trade windows already work)
8. Challenges system (WORKS 2026-08-21 - client-tracked; server surface is the challengegroup_reward_* quests + GameEvent acks)
9. Falling blocks (PARTIAL - collapse groups spawn EntityFallingBlock entities that fall and die on landing 2026-08-20; item-drop-on-land + single-block branch open)
10. Bosses / special infected (PARTIAL - Demolition prime-and-explode shipped 2026-08-20; other special variants open)
11. World borders / difficulty tiers (RE-BLOCKED 2026-08-21 - difficulty damage table IL absent from the corpus; border is client-side)
12. Server-triggered sounds / music (RE-BLOCKED 2026-08-21 - NetPackageSoundAtPosition field types not pinned)
13. Quest reward choice / loot groups (RE-BLOCKED 2026-08-21 - the C2S chosen-reward field is not in the corpus; payout WORKS)
14. AIDirector / sleeper save blobs (MISSING)
15. Localization titles (MISSING)

AIDirector depth rows (2026-08-21): heat map/activity WORKS (NotifyActivity + CheckToSpawn scouts + cooldowns +
feral roll); wandering horde paths, feral sense, sleeper wake cascade and persistent director state are PARTIAL
with documented notes in GAP_ANALYSIS 5.3.

## Wave 2026-08-20 (config + provenance pass)

Hardcode audit closure (docs/archive/HARDCODE_AUDIT_2026-08-08.md): the
layered-policy ladder (stock data -> config -> wasm plugin -> core) pushed
further down, default-preserving except where stock alignment was intended.

- **Terrain-id pins -> live TerrainIds (A36-A38)**: TTS filler skip and the
  chunk heightmap fallback read `World.terrain_ids` (resolved via idByName),
  not comptime pins; `Chunk.terrain` points at the world's ids.
- **Config keys (B29-B37)**: guard kick/shed/weak-rate, te-scan caps,
  workstation craft caps and the apm dump period are zdtd.toml keys; movement
  envelope was already config. All defaults match the prior constants.
- **A34/A35 closed**: entityclasses `HealthMax` passive_effect + variable
  resolution was already live; the stock-file test now pins zombieBoe 200 /
  animalStag 100 / zombieBoeFeral 550 (V3.1.0 b14 ground truth), and the
  director class-resolve hook makes all 293 classes reachable per-class.
- **A41 stock alignment**: heat cooldowns 120/60 -> stock 240/180 s
  (`[rules.director]`, still operator-tunable); scout cadence roughly halves.
- **A40**: the invented builtin `zombieFeral` class row repointed to the real
  `zombieBoeFeral`.
- Standalone provenance dashboard (`docs/provenance.html`, opened from the
  repo, not served) reflects the scorecard and provenance state.

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
- **Features:** deco NameIdMapping + biome density + world-store mirror (with
  stock `GetRandomRotation` rolls in rawData bits 16..20, keyed to the placement
  cell so windows and the mirror agree), weather
  storm/bloodMoon state machine, quest rally objectives, workstation RecipeQueue,
  power trigger TE wire, A* pathfinding, gamestages, buffs depth, vehicle
  multi-seat, party PlatformUserId, stock telnet console surface.
- **Traders (T1):** the trader NPC now replicates with a real `npcTraderJen`
  class hash, and `TraderData` rides both stock S2C paths: spawn
  `EntityCreationData.hasTraderData` and the channel-1 LockResponse context.
  Each trader class resolves its own traders.xml `<trader_info>` id from
  npc.xml and fills its window with its own `<trader_items>` list (not the
  shared `traderAlways`); the lock-open path denies outside the trader's open
  hours (vending always open) and `allow_sell=false` blocks selling to it.
  Each trader owns a live money pool (wire shows it, debited on buy-from-
  player, credited on sell, regenerated by restock on the traders.xml
  `<trader_info>` `reset_interval` cadence: -1 never, 0 daily, N every N days).
  **Stock inventory roll (2026-08-08):** refs keep their count ranges, prob,
  unique_only and quality attrs and the fill runs the ported `TraderInfo`
  spawn (prob-weighted group picks, uniform count and quality rolls, seeded
  per world+trader+day), so windows vary per restock and quality rides the
  TraderData wire. Wire + scenario tested; live stock-client visual check
  pending.
- **Loot (T2):** containers roll their own `blocks.xml` LootList (gun safe
  `smallSafes`, chest `woodenChest`); zombie bags resolve the stock chain to
  `zPackReg` and drop only on `LootDropProb` (.04), so most kills drop nothing.
  Storage blocks with no resolvable LootList stay empty on both initial fill
  and the LootRespawnDays re-roll (fail closed, no invented `woodenChest`).
  Three new tests; 761 total.
- **Items (T3):** absent `Stacknumber` defaults to stock's 500 and inherits
  through `Extends` (two-pass resolve); the "bag slot waste" residual is closed.
  New stock-file test; 762 total.
- **Water (T4):** lakes and rivers now fill from `water_info.xml` sources at
  chunk generation, and the chunk water channel carries the full static mass.
  Prefab `.tts` water planes paint the resolved water block from the v>=17
  sparse water channel, so POI pools, flooded basements and water tanks render
  wet (the fluid sim remains open). Two new tests; 764 total.
- **Progression (T5):** `players.zsv` v3 persists level, XP, food/water and
  active buffs across restarts (server-side `awardXp` ledger; ZPV2 files still
  read; admin wipeplayer handles v3). Round-trip test x2; 765 total.
- **Quests (T6, parser + wire kinds):** `template=` inheritance resolves in a
  two-pass (67 derived quests parse non-empty), and per-objective Write shapes
  flow into the journal wire (TreasureChest/POIStayWithin kinds) so the join
  PDF no longer trips `ValidateSizeMarker`. The stock accept marker
  (`NPCQuestList RemoveQuest` with tier + index) is wired and the offer list
  excludes active quests. Goto-point quests without a static position
  (stock `RandomPOIGoto` / `ClosestPOIGoto`) bind the nearest real POI at
  accept; the NavObject marker, `PositionData` Location and the goto check all
  use the bound POI center, so markers point somewhere reachable instead of an
  invented spot. A stock `quests.xml` catalog skips the client-name prefix
  gate (server and client read the same file). Five new tests; 769 total.
- **Blood moon (T7):** the horde now runs stock `IsBloodMoonTime` - dusk on the
  blood-moon day through dawn of the next, crossing the midnight rollover - and
  `worldTimeBits` encodes `(day-1)*24000` so the client HUD day, BloodMoonDay
  and the red moon align. Dusk/dawn follow `CalcDuskDawnHours`. 772 total.
- **World integrity (T8, part):** land claims now disappear with their keystone
  (`removeClaimAt`) and offline claims expire past `LandClaimExpiryDays`;
  `markClaimsForEntity` tracks owner online state; block repair takes the lower
  wire damage as the new absolute (repair heals instead of weakening). The
  **stability plane shipped**: `src/world/stability.zig` ports the stock
  per-block byte plane (15 full / 1 cap / 0 falls) and a C2S SetBlock that cuts
  a support fells the dependency chain with client-visible collapse broadcasts.
  **Land claims persist** (`claims.zlc`): keystone claims survive a restart and
  re-map to the owner's new entity id on login, with the seen-day preserved for
  offline expiry. **Loot respawns**: `LootRespawnDays` (serverconfig, default 7)
  re-rolls a looted world container on its next open, and the touch day persists
  in `containers.zct`; player-placed storage never respawns. The client lpBlocks
  overlay remains open.
- **C2S (T10):** `NetPackagePlayerDisconnect` handled on the quit path (own
  entity only, immediate save + slot teardown). Parity coverage is now **0
  unhandled dir=1** (70 handled in game.zig). 775 total.
- **Review passes (prompts dir):** the abstraction and ecs-soa reviews ran and
  landed findings (`reviews/ABSTRACTION_REVIEW.md`, `reviews/ECS_REVIEW.md`); the
  ecs-soa follow-up fixes are in: RelPosAndRot raises the dirty bit so movers
  relay at the motion period instead of the heartbeat, the loot-bag Collect arm
  restores on partial deposit and records ledger causes, QuestEntitySpawn and
  TurretSpawn gained rate/quest gates, PosAndRot preserves the stored yaw, and
  turret kills roll `LootDropProb` like player kills. 788 total.
- **Docs:** [GAP_ANALYSIS.md](GAP_ANALYSIS.md) scores 329 features with anchors;
  [WORK_PLAN.md](WORK_PLAN.md) turns the top gaps into handoff-ready tasks.
- **Visual round (stock client, 2026-08-06):** the automated playtest
  (`7dtd-playtest`, Steam + Proton, EAC off) ran the demo suite against zdtd on
  Navezgane: 80-81 of 83 cases PASS across runs, including join, mesh, ground,
  walk/sprint/sneak/jump, dig/place, block damage, quest journal, weather,
  water plane, deco, craft, vehicles, power, blood-moon music, and the trader
  NPC visible to the client (`class=npcTraderJen`). Residual failures are
  demo-suite timing (the trader now owns the spawn-adjacent "nearest target"
  slot; the harness target pick was fixed to prefer zombies) and an
  item-drop EntityItem timing case. Fixing the harness's combat targeting is a
  suite change, not a server defect.

## Wave 2026-08-07 (reliable transport + quest rewards)

- **Reliable transport (litenet):** four gaps closed on the S2C/C2S path. The
  five motion packages ride `sendUnreliable` (stock `get_ReliableDelivery=false`),
  so 20 Hz position spam no longer competes with chunks and join-critical
  control traffic for the 64-slot window. WindowFull retries pace at 1 ms after
  16 fast attempts instead of a 0.5 s sleep, bounding a stuck peer's tick wedge
  to ~240 ms so the stale-peer sweep reclaims it (the repeated block-IdMapping
  drops under loadgen reconnect floods are gone). Inbound fragmented messages
  reassemble in two slots keyed by frag_id (a Bag plus a PlayerInventory during
  a loot transfer no longer clear each other). Inbound reliable payloads
  deliver in order: out-of-order seqs hold in a window-bounded buffer and drain
  on the gap, so WAN reordering cannot apply SetBlock / inventory transactions
  out of sequence.
- **Quests (rewards + actions):** `<reward>` entries parse kinds, item names and
  values into `RewardSpec`s, paid out at tick end (wallet coins on completion,
  items/exp through the ledger); `<action>` elements parse with phase/cvar/
  value/message properties and UnlockPOI fires on phase entry. Template-derived
  quests resolve `<variable>` overrides (last occurrence wins) so difficulty
  tier flows through `param1="difficulty"` and `tier2_fetch` reports 2.
- 803 unit tests (the exact count comes from running the cached binary).

**Gates at this pin:** `make check` exit 0 · 803 unit tests · live stock-client
gate **23/23** · playtest full suite green on a fresh world.

**Known open:** see [WORK_PLAN.md](WORK_PLAN.md). The largest are trader depth
(POI placement, restock; the NPC replicates with TraderData on both S2C paths,
per-trader stock/hours ship, and quest rewards/actions pay out, WORK_PLAN T1),
and player persistence depth.

## Wave 2026-08-07 (config-driven game modes, ADR 0021)

The full WORK_PLAN T11-T15 chain landed (ADR 0021 "config-driven game modes"),
plus five priority gaps from GAP_ANALYSIS / TODO. 950 unit tests.

- **T11 TOML binder** (`src/util/toml_bind.zig`): `zdtd.toml` and the mode
  packs now parse through one comptime-reflected binder - struct fields are
  `[section]`s (dotted `[rules.combat]` recurses), the field type drives value
  parsing, `?T` means unset, and unknown keys/sections abort startup. The
  per-key chains in `zdtd_config.zig` and `mode.zig` are deleted (net
  deletion), with aliases/ranges/enum-by-name declared on the struct. Fuzz
  target over `bind` added; the two existing config fuzz targets now exercise
  the binder through the real surfaces.
- **T12 `Rules` struct** (`src/ecs/rules.zig`): the sim rule constants moved
  out of file scope into `World.rules.<group>.<field>` - `combat`
  (attack_damage/range/cooldown), `ai` (LOD/sense/despawn ranges, chase/wander
  speed), `bloodmoon` (party distances, enemy cap, party count). Defaults pin
  the pre-move literals (a pin test fails loudly on drift); no behavioural
  change.
- **T13 mode packs are a full overlay**: `modes/<name>.toml` may set any
  `Rules` field via `[rules.*]` sections plus the stock keys it already
  accepted. Precedence stays operator-wins: `zdtd.toml` beats the pack for the
  same key. Example packs `modes/horde_lite.toml` and
  `modes/survival_crunch.toml` exercise the rules surface; GAME_OPTIONS.md
  carries the generated reference, and a coverage test pins every `Rules`
  field to the doc. Scenario `mode-rules` proves a pack's attack_damage lands
  in the sim (melee 100->16 with the 42 floor).
- **T14 precedence audit**: `attack_damage`, `chase_speed`, `wander_speed`
  are classified **floors** (entityclasses/items XML wins when non-zero; tests
  set a conflicting `Rules` value and assert the class value wins), everything
  else moved is **policy**. HARDCODE_AUDIT A32 documents the split.
- **T15 plugin event hooks**: `on_player_death`, `on_entity_killed`,
  `on_block_damage`, `on_quest_complete` with a deny/adjust return (<0 deny,
  0 keep, >0 percent). The kill verdict is routed from the sim via
  `World.kill_verdict_fn`; block damage and quest payout consult the hooks in
  game.zig. Static vtable grew the same four hooks. C fixtures
  `plugin_rules.c` / `plugin_trap.c` prove deny/double/trap-isolate end to end
  (scenario `wasm-t15`: death denied at 1 hp, block damage doubled, quest exp
  doubled, the trapping module disabled while the server keeps ticking).
  PLUGIN_DEV/PLUGIN_API/STATE_MACHINES updated.
- **GAP 19 ServerVersion**: the GSI `ServerVersion` is now the stock
  four-field `V.3.10.14` (`version.stock_wire_gsi_version`); the login
  package keeps the display form `V 3.1.0`. The client's
  `TryParseSerializedString` no longer sees a malformed string.
- **GAP 13 block rotation**: the SetBlock path writes the client's full
  `BlockValue.rawData` (rotation/meta upper bits) into the chunk plane via the
  new `setBlockRawWorld`, so player-placed doors/wedges and switch meta render
  rotated for a second client and survive relog (ZCH3 persists the u32 plane).
  Store test covers the plane + save/reload round trip.
- **StormFrequency knob**: `[sim] storm_frequency` (percent, default 100; 0
  disables storms) feeds both the weather scheduler divisor and the GameStats
- **Wave 2 (2026-08-09)**: console `storm` / `clearweather` / `stormoff`
  force and clear storms; workstation craft authority (per-craft count and
  duration come from recipes.xml, not the client blob; in-place queue
  validation); item drops commit via `NetPackageEntitySpawnResponse` (the
  thrower's client DecItems its bag); liteNet per-part WindowFull pump yield
  so join-critical ACKs land (blocks IdMapping now sends; loadgen join smoke
  8/8 full joins).
- **Wave 3 (2026-08-09)**: hit knockback + `NetPackageEntityVelocity`; turret
  kills credit the placing owner (quest/XP/score); vehicle refuel via gas-can
  InvTx; drowning + radiated biome damage (Rules knobs); explosion entity
  damage + thrower credit; `NetPackageWorldSpawnPoints` on death with the
  bedroll entry; respawn at the bedroll when placed.
  wire value, so client and server agree. No V3.1.0 serverconfig key exists
  (world state); documented in GAME_OPTIONS and zdtd.toml.example.
- **Storm survival gates (SandboxCode)**: the operator's `SandboxCode` /
  `SandboxPreset` parse from serverconfig and ride the GameStats blob
  (EnumGameStats 71/70), so a joining client decodes the server's sandbox
  gates (TemperatureSurvival, StormFreq, blood-moon settings) instead of its
  own defaults (RE sandbox-options §8). Wet/cold buffs stay client-computed by
  design: the stock dedicated server stubs felt temperature (weather-env §4),
  so server-side buffs would double-apply. GAP rows updated.
- **GSI sandbox advertising (GameInfoString 18/19)**: the TCP GameServerInfo
  text (and the PlayerLoginAnswer copy) carries `SandboxPreset`/`SandboxCode`
  when the operator set them, so the server browser can show what the server
  actually runs (RE network.md: SandboxPreset = 0x12, SandboxCode = 0x13).
  Unset keys are omitted - empty = client default, the same semantics as the
  GameStats(71) blob. `gsiSafe` sanitizes the values like every other GSI
  field. Three unit tests (keys emitted, unset omitted, injection sanitized).
- **Vending rent SM**: `NetPackagePlayerVendingMachine` (userId stream +
  Vector3i + removing, asm.il 833593) is handled server-authoritatively:
  identity-gated, rent pays `TraderInfo.RentCost` casinoCoin (inventory first,
  trade's rule), the term is `rent_time` in-game days, one machine per player,
  re-rent extends, expired rentals return to Unowned on the day roll, and
  `removing` clears ownership while the block identity and stock survive
  (`Vending.clear` no longer wipes pos). Scenario `vending-rent` covers the
  whole SM. Residual: password/allowed-users editing and the stock
  NetPackageTraderData ToServer buy body (GAP vending row).
- **Real-client trade CopyFrom**: the stock `NetPackageTraderData` ToServer
  body (isEntity | entityId/tePosition | hasTraderData | TraderData::Write,
  asm.il 843046) is now parsed and mirrored (stock TraderData.CopyFrom) onto
  the entity trader's sim stock and the vending store - count/markup/money
  from the client's post-trade copy, price/sell stay server-owned. The
  loadgen 9-byte trade body still works (length-distinguishable). Scenario
  `traderdata-copyfrom` covers both branches. This is the real-client buy
  path for both traders and vending machines.
- **Vending owner editing**: the vending TE composite C2S (mirror of
  TileEntityVendingMachine::write, payload version 3) is parsed and applied
  owner-gated - only the machine's owner may change lock/password/allowed
  users; ownership and the rental term stay server-applied (the rent SM owns
  them); the reach check matches the other TE paths. Scenario `vending-edit`
  covers owner apply + non-owner denial. The vending gap row is closed.
- **P4 evidence JSONL flush**: admin `evidence dump [path]` writes the
  authority-reject ring as JSONL to a file (default `<world>/evidence.jsonl`)
  via `Game.dumpEvidenceFile`; fails loudly on I/O error. Test covers the
  file round-trip. The P4 "evidence JSONL" TODO item is closed.
- **EAIRunawayFromEntity**: the `.runaway` task now covers both AITask-1
  (hurt) and AITask-2 (proximity) flee for passive animals: a 0.5 s fear scan
  over players/zombies/other animals within `fleeDistance` 20 sets
  `fear_target` (stock AITask-2 class filter maps to Kind), the gate accepts a
  fresh fear source, and the update flees the nearest feared entity. Two unit
  tests (flee within range, no flee beyond). GAP_ANALYSIS §5.2.1 updated;
  three EAI tasks remain blocked on their subsystems.
- **EAIApproachDistraction (decoy bait)**: dropped items carrying
  `DistractionTags` now attract zombies. items.xml parses the tags
  (`zombie`/`requires_contact`/`eat`; stock ships `resourceRockDecoy` with
  `zombie,requires_contact`) plus the `DistractionRadius`/`Lifetime`/
  `Strength`/`EatTicks` passive effects; the drop spawn seeds the sim loot-bag
  state, and a 20-tick `tickDistraction` broadcast (EntityItem.tickDistraction,
  asm.il EntityItem:1341) latches the nearest zombie within 25 m
  (`pendingDistraction`, closer wins, sleeping excluded, kind-gated on the
  `zombie` tag). The `.approach_distraction` task (MutexBits 3, priority 4 in
  the stock list) walks over and chews eat items (`distractionEatTicks--`);
  a non-eat decoy reached clears the latch and the zombie loses interest; a
  chewed-up item is removed with EntityRemove(Despawned). Simplifications
  documented in GAP_ANALYSIS §5.2.1 (no per-drop collision physics, no
  per-entity resistance). Four unit tests + the items.xml parse test; the
  stock-data decoy row is now live in V3.1.0 games.
- **Ally persistence**: `NetPackageAllyRequest` drives a real `AllyStore`
  table (`src/server/ally.zig`; ComputeTransition per asm.il 885142, both
  directions mirrored), and relationships persist to `{world_dir}/allies.zal`
  (magic ZAL1, zdtd-owned like claims.zlc) on the periodic + shutdown saves and
  restore at init; a missing file is a fresh server, a corrupt one fails the
  load loudly instead of silently clobbering. Unit test round-trips the file
  and the corrupt path.
- **Party state machine (P3)**: `NetPackagePartyActions` (entity-id keyed, no
  PUID - RE parties-factions.md §2) dispatches to a real `Party`/`PartyManager`
  (`src/ecs/party.zig`): AcceptInvite creates or joins (8-member cap, leader
  index 0), ChangeLead / LeaveParty / KickFromParty / Disconnected /
  JoinAutoParty (party id 1) / SetVoiceLobby mutate the authoritative group,
  and every mutation fans a stock-layout `NetPackagePartyData` snapshot
  (party id, leader index, voice lobby, member ids, changed entity, action,
  disband - parties-factions.md §3) out to party-relevant peers. A party of
  one auto-disbands (stock keeps no singleton party); disconnect removes the
  member. The old echo-to-sender is gone; a client-sent PartyData is rejected
  (ToClient, ownership). **Shared kill XP SHIPPED**: `Party.GetPartyXP`
  (`base * (1 - 0.1 * MemberCountInRange)`, range GameStats[54] = 100) splits
  the killer's award and every in-range mate gets the same split via
  `NetPackageSharedPartyKill` (scenario covers the 90/90 split and the solo
  full award). The killer's client also gets `NetPackageEntityAddExpClient`
  (xpType 0 = Kill, per the AddExpClient IL) so the XP icon and local
  progression gain fire; mates get the SharedPartyKill tooltip instead
  (stock split). **POI lockout exemption**: a party member inside a quest POI no
  longer blocks the rally (`World.party_same_fn` hook → `Game.parties`, stock
  CheckForPOILockouts). Wire layout + parse tests, a 7-case state-machine test,
  and two-peer scenarios cover accept → leave → disconnect → shared kill →
  POI lockout exemption. **Quest sharing SHIPPED**: a newly accepted quest
  fans a stock `NetPackageSharedQuest` share_quest body to the party and the
  journal slot is marked `is_shared`; a disconnect fans remove_quest events.
  Open: party gamestage/loot max and the per-objective shared-quest progress
  sync. **Per-objective delta relay SHIPPED**: `NetPackagePartyQuestChange`
  (sender | objectiveIndex | isComplete | questCode) is owner-gated and
  fanned to the other members so their shared-quest mirrors advance.
  **Per-player party loot stage SHIPPED**: `lootStageForPlayer`
  (Party.GetHighestLootStage) feeds death-bag/air-drop rolls.
- **Survival simulation (GAP 22)**: `Game.tickSurvival` depletes Food/Water
  with in-game time (rates from `[rules.progression]`, ADR 0021 tunables),
  drains HP while starving/dehydrated, regens when well-fed, clamps at zero,
  and syncs to the owner on a throttle via `NetPackageEntityStatChanged`.
  The stock passive-effect defaults (FoodChangeOT etc. through Stat.Tick) are
  not in the V3.1.0 IL corpus, so the rates are operator policy with stock-feel
  defaults (full Food ≈ 2 in-game days). **Stamina SHIPPED**: sprinting
  (MovementState 3, lapsed by a stale timer) drains, idle regens, synced as
  EntityStatChanged kind 1 on the same throttle. Unit test covers depletion,
  starvation damage, well-fed regen, clamp, sprint drain/regen and the S2C
  sync; the melee damage test now pins its own depletion off.
- **Vehicle/turret/power persistence (GAP)**: `entities.zen` (ZENT1) saves
  spawned vehicles (kind/pos/yaw/fuel/seats) and turrets (pos/range/damage/ammo)
  on the periodic + shutdown saves and restores them at init; turret power
  re-derives from the block grid, and power grid **nodes** rebuild from the
  chunk block grid on first chunk load (`scanChunkPower`, `power_scanned` per
  chunk) so a generator/consumer/battery layout survives restart. Restart keeps
  a parked minibike, a turret, and its power network. Open: wire edges (links
  between nodes stay runtime) and trader quest-offer state.
- **Prefab water plane (GAP)**: the v>=17 sparse water channel in `.tts`
  prefabs is decoded into a dense per-cell mass plane (`TtsBlocks.water`) and
  `tts.paintDecoration` paints the resolved runtime water block at every
  mass>0 cell, so POI pools, flooded basements and water towers render wet
  through the existing chunk water-mass channel (full static mass derived from
  the water block plane). Fail closed: `water_id` 0 skips water paint. Test
  builds a synthetic v19 prefab with one water cell and asserts decode + paint.
  Open: the flowing-water sim.
- **Procedural biome surface (W3 step 1)**: the proc generator samples a
  continuous low-frequency biome field (`WorldGen.biomeAt`, deterministic,
  region-contiguous - a biome is a landmass, not per-column static) and fills
  each column with its biome's `biomes.xml` surface stack when the loaded
  table resolves more than one biome; the single-biome default is unchanged.
  Two tests: field determinism/contiguity/range and multi-biome chunk fill.
  The chunk `biome_id` sent to the client now follows the same field for proc
  worlds, so the displayed biome matches the surface blocks; the resolved-list
  index is translated to the real sparse biomemap id (stock ids 1, 3, 5, 6, 7,
  8, 9, 13, …), so surface and display land on the right biome.- **Quest name gate closed**: `isStockClientQuestName` accepts every stock
  quest-name family (`treasure_` added; `quest_`/`tier`/`intro_`/`test_`/
  `challengegroup_reward_` already there), verified against stock quests.xml.
- **Chunk compression (GAP 20)**: `NetPackageChunk` is now deflated through
  the streaming `DeflateFramer` (same stock compressed-frame format as the
  `NameIdMapping`) before the reliable send, so the join stream carries a
  fraction of the raw block/texture payload; overflow falls back to the
  uncompressed frame. The same helper covers `NetPackageSignDataResponse`
  (both in the stock asm.il:808641 compress set). Test round-trips a 4 KiB
  payload through the inbound parser for both packages.
- **Starter quest re-grant fix**: `questAcceptStarter` scans every journal slot
  (active or completed) and refuses to re-grant a starter finished in an
  earlier session, so the completed record survives restart. Two quest
  scenarios that relied on the old re-grant behaviour moved to tmp dirs (a
  completed starter now persists in ZPV3).
- **Trader currency_item (traders.xml root)**: `Game.coinItemId` pays trade
  and vending rent in the root `currency_item` (stock: casinoCoin) instead of a
  hardcoded name, falling back to the stock name when unset. Parse test covers
  a custom currency and the empty fallback; `quality_mod` / `quest_tier_mod`
  root attributes are still ignored (GAP trader economy row).
- **Chat recipient routing (EChatType)**: `NetPackageChat` now parses and
  preserves the full stock body (chatType, sender, msg, msgSender, bbMode,
  recipientEntityIds - chat.md §1). Routing follows stock
  `ChatMessageServer` (chat.md §2): a non-empty recipient list sends only to
  those clients (Party/Friends/Whisper), otherwise broadcast; the channel
  rides the re-encode so a party message keeps its Party styling instead of
  being flattened to Global. Recipient lists over the 8 cap are rejected, not
  truncated. Two wire tests + a three-peer scenario (party chat reaches only
  the recipient, global reaches everyone but the sender).
- **GAP 12 fixed-size caps**: land claims 256→1024, containers 256→512
  (heap encode buffer - the old stack buffer truncated saves), workstations
  64→256, damaged blocks 64→256, bans 32→128, join-rate IPs 16→64. The join
  PlayerId journal was capped at 2 quests (sim holds 8); all quests now ride
  the PDF (scenario `journal-pdf` proves 5). Overflow tests: 300 claims /
  300 containers round-trip, 100 workstations, 100 damaged blocks. Residuals
  documented in GAP_ANALYSIS 12 (hp/raw sparse caches; persistent hp is the
  proper fix).
- **GAP 18 subbiome deco lists**: `decoSpeciesAt` resolves each cell through a
  port of stock `GetBiomeOrSubAt` (`src/world/subbiome_noise.zig`: .NET
  GameRandom, PerlinNoise Noise/FBM/Lattice, GetStableHashCode world-name
  seed) and samples that subbiome's own `<decorations>` set, parsed per
  `<subbiome>` in biome_layers. pine_forest's 8 subbiomes carry the real tree
  mass (.06-.08 vs .001-.007 top level), so a join window gets stock-like
  density instead of ~3 objects. Verified against stock biomes.xml + AssignIds
  dump. Residual: the stock `_perm` literal is not byte-reproduced (classic
  Ken Perlin table used); banding is stock-shaped, boundaries may drift
  (HARDCODE_AUDIT A33, extraction owned by 7dtd-research).

**Gates at this pin:** `make check` exit 0 · 950 unit tests · live stock-client
gate 23/23 · playtest full suite green on a fresh world.

**Known open:** see [WORK_PLAN.md](WORK_PLAN.md) (all T1-T15 tasks landed) and
GAP_ANALYSIS "What to build next" (survival stamina/core-temp residuals,
worldgen W2b-W7, three EAI tasks blocked on missing subsystems, party
gamestage/loot max, trader quality_mod). M11 CPU work stays parked until apm
shows need.

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
| POI reset | **PASS** | quest dedication (rally activation / POI lock) re-paints the POI's baked .tts blocks over player edits (ResetBlocksAndRebuild); quest-tag filter + lockout-expiry reset residual |
| Unit tests | **PASS** | 2026-08-05 wave: inventory place wood + craft scenarios green; snapshot/EAI/evidence/webui http added (run `zig build test` for exact count). |
| C2S hardening | **PASS** | join-phase gate; Bag ownership; damage cap+fatal-vs-NPC only; SetBlock/Explosion/TE reach 96; respawn heal only when dead |
| Interest fan-out | **PASS** | broadcastNear 160 blocks for SetBlock/Explosion/loot spawn; pw19 kill soak Items:3, no near-skip misfires |
| Player death → respawn | **PASS** | admin kill → EntityStatChanged hp=0; RequestToSpawnPlayer heal + PlayerSpawnedInWorld(died) + join bundle; playtest `player_respawn` PASS 2026-08-03 |
| Entity spawn-on-approach | **PASS** | per-client known_entities bitset; ECD spawn on first range entry (director hordes, sleeper wakes, roaming); pw27 soak green |
| Player persist v3 | **PASS** | players.zsv **ZPV3** (quality/meta + journal + level/XP/food/water/buffs; ZPV2 still read and upgraded on merge); join PDF carries restored toolbelt/bag; pw27 axe q1 persisted through restart+rejoin. Admin `wipeplayer <name>` erases offline records (and kicks online). Note: client inventory is client-authoritative (C2S PlayerData/PlayerInventory overwrite server sim), so only items the client actually holds persist; server-side `give` is a loot-bag drop for this reason |
| TE/block persist | **PASS** | containers.zct + blockmeta.zbm save/load on save tick + shutdown; unit roundtrip test; pw19 restart rejoin green (files present, join CGO:25, 0 WRN) |
| Player save merge | **PASS** | savePlayers keeps offline records (was TRUNC joined-only) |
| Trader XML stock | **PASS** | per-trader traders.xml `<trader_info>` lists via npc.xml class→id (traderAlways fallback) + items.xml EconomicValue prices (group pick rolls deferred) |
| Trader demand markup | **PASS** | per-entry Markup sbyte: buy spikes +100, sell eases -4 (saturating), restock resets; live markup rides the wire TraderData (client demand arrows + player-owned price factor 1+Markup×0.2) |
| Trader open/close | **PASS** | per-trader edge-latched close cycle (EntityTrader::OnUpdateLive shape): close force-unlocks the held trade channel and toggles `TraderOnOff` gate blocks (light meta; door lock via TE features residual); open latch reopens |
| Vending machines | **PASS** | TileEntityVendingMachine (type 7) emitted: blocks.xml Class/TraderID + Extends resolution, per-block TraderData store seeded from trader_info, TE pushed on chunk stream and LockRequest open (VendingMachineLockContext); rent/edit SM + C2S buy and disk persistence residual |
| Director class variety | **PASS** | zombie slots 1+8..11 from entitygroups weighted picks; rotation per spawn |
| Heat map / scouts | **PASS** | 5×5-chunk region heat from burning workstations (blocks.xml HeatMapStrength: forge 6, campfire 5...); 5 s check spawns scout parties at/above 25 with region+neighbor cooldowns (20% feral doubles); blood moons suppress new heat |
| Blood-moon parties | **PASS** | players within 80 m pool into one party (focus + per-party cap min(30, EnemyCount×members)); one shared wave per party; gamestage frozen at dusk; horde zombies > 150 m teleport back; horde marks + frozen stage cleared at dawn |
| Biome spawn groups | **PASS** | night/day/animal group per spawn-point biome via spawning.xml rules (biome map id → biomes.xml name → rule); wasteland at midnight gets `ZombiesWastelandNight`, not pine_forest's `ZombiesNight`; fallback on unknown biome |
| Zombie population bound | **PASS** | alive-cap 24 + far-despawn (>200 blocks, reason=Despawned); pw27 Ent stable 3-4 vs prior 7→34 creep |
| Corpse dwell | **PASS** | dead zombies/animals linger at hp 0 for TimeStayAfterDeath (30/300 s, entityclasses.xml) with AI stopped; the tick sweep removes expired bodies with EntityRemove; corpse harvest residual |
| Wandering hordes | **PASS** | HordeNextTime arms after day 1 at +12-24h (deterministic roll), player-gated; expiry spawns a 6-pack of horde zombies at ~92 m chasing the party; pack path-walk residual |
| ItemValue/Explosion wire | **PASS** | ReadData + ExplosionData positional per IL (no remaining() or scan heuristics); unit tests |
| Loot bag wire direction | **PASS** | NetPackageBag dir=ToServer(1); S2C sends removed; loot rides ECD `bag` field in EntitySpawn; pw15 kill 100/101/102 → Items:3, zero WRN/NRE in client log |
| Loadgen join + walk + dynamite | **PASS** | flat + Navezgane; 2-bot mixed 100% passRate, walks>0, ExplosionInitiate; pw21 2-bot wander 100% alongside live stock client (walks=495, zero client WRN) |
| EntityRemove reason byte | **PASS** | body=entityId:i32+reason:u8; pw14 admin `kill 100/101/102` no NCSimple underrun; Items:2 loot bags |
| Mob health replication | **PASS** | dirty-hp pass sends EntityStatChanged(health) for zombies/animals to observers (C2S damage, AI melee, admin kill, corpse hp=0); health bars drop and deaths show |
| Automated in-client playtest | **PASS (2026-08-06)** | V3.1.0 b14 pin. Live gate **23/23** on a fresh world each run (`FRESH=1`); the client renders and plays Navezgane. The earlier demo residuals are closed: the deco S2C NRE is resolved ([archive/DECO_NRE.md](archive/DECO_NRE.md)) and the join hang is fixed (GameState=Running plus chunks before the spawn). Still open: full MinEvents eat amount (chili +15). |
| Loadgen parity vs stock dedi | **PASS (2026-08-06)** | same `--join --count 2 --actions 20 --seed 4242` workload on the stock V3.1.0 dedicated (Navezgane) and on zdtd: both 2/2 bots joined rc=0, 0 deaths, no protocol errors; zdtd apm shows join_ok=26 join_fail=0, phase/decode/c2s rejects all 0 ([CLIENT_PLAYTEST.md](CLIENT_PLAYTEST.md)) |
| WebUI ops (WU0–WU2) | **PASS** | `--webui-port`+secret; `tcp_listen` + `std.http.Server`; dashboard + POST `/api/cmd`; CSRF; full apm snapshot; default off |
| Authority spine (P4.0) | **PASS (first cut)** | `phase_gate` matrix; movement envelope; reject counters in apm/webui; `ZdtdAuthorityMode`; inv ledger ring |
| Static plugins + Wasm runtime | **PASS (first cut)** | `src/plugin/` sample_hello; Res/Query/Cmd; stream soft warn; Wasm-only per ADR 0020: zwasm v2 runtime loads `[plugin] modules` from zdtd.toml, host imports `zdtd_log/tick/queue`, fuel+memory budget disables a looping module within one tick (WORK_PLAN T9, C fixture proven) |
| zdtd.toml | **PASS** | world/CWD → stream/authority/feature InitOptions; `zdtd.toml.example` |
| Gamemode pack | **PASS (first cut)** | `modes/default.toml` + `mode.zig`; `--mode` / `[mode] name` → InitOptions; `enable_sample_plugin` |
| C2S package coverage | **PASS 33/33** | parity tool: 0 unhandled dir=1 (72 handled across `c2s/*`; `NetPackagePlayerDisconnect` lands the quit immediately, WORK_PLAN T10); 190-pkg catalog docs/wire/PACKAGES.md |
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
| Player bodies to peers (`NetPackageEntitySpawn`, player class + name) | `server/game/join.zig` | join burst: joiner sees every in-view player; the joiner spawns to every client that sees it; `dropClientSlot` broadcasts `EntityRemove(Despawned)` so no ghost body |
| Progression snapshots (`NetPackagePlayerStats`, EntityNetworkStats) | `wire/stock_xp.zig`, `game/join.zig`, `game/player.zig` | peer tooltip/party level: sent at join per visible player + pushed to all peers on level-up; minimal Progression.Write v3 blob (Level/ExpToNextLevel) |
| Kill counter (`NetPackageEntityAddScoreClient`) | `wire/stock_xp.zig`, `c2s/misc.zig` | character-sheet zombie AND player kills: per-client ledgers incremented and pushed on every kill (PvP branch) |
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
| Workstation TE (type 12) | `stock_te.zig`, `world/workstations.zig` | ver 50 full body (fixed stock array lengths, recipe blobs, CraftCompleteData, lastInput); stock queue orientation, output-full stall and cycle carry; 2Hz burn/craft tick + dirty S2C re-broadcast and lock-grant push; see wire/WIRE_WORKSTATION.md |
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
console: see `ECS_SYSTEMS.md`.

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

## Wave 2026-08-09 (parity + extraction + docs hardening)

- **Refactor**: `game.zig` 5155 → **2464** (42 shards in `src/server/game/*.zig`
  via `src/server/root.zig`; `c2s/*` owns all C2S domains). Highlights:
  `init_assets`+`init_world` (asset load + world seed), `step` (20 Hz tick),
  `replicate_health`, `harness`, `wasm_host`, `constants`, `lifecycle`,
  `session_drop`, plus prior `loot|weather|vehicle|tick|world|player|quest|
  social|trader|stability|replicate|net|types|hooks|sleeper`.

## Wave 2026-08-08 (parity + extraction + docs overhaul)

- **Refactor**: `game/loot|weather|vehicle` shards (game.zig 5310 -> 5155);
  `c2s/*` owns all join + 4 C2S domains. Test-suite flakes root-caused and
  fixed (demo-pad re-seed on restored entities.zen + scenario world hygiene):
  `zig build test` 975/975 on consecutive runs.
- **Traders**: stock inventory roll (count ranges, prob, unique_only, quality
  from traders.xml, seeded per world+trader+day), 50-entry window
  (`TraderInfo.MaxItems`), lazy rebuild on open after ResetInterval,
  per-block CraftingAreaRecipes queue gate.
- **Loot**: containers sized from `lootcontainer size`; `count="all"` spawns
  every entry; `force_prob` independent gate; `loot_quality_template` rolls
  item quality by loot stage; group entry cap 192 (perkBooks).
- **Workstations**: non-burning stations (workbench/cement mixer/table saw)
  advance (fuel-module from blocks.xml Modules); state persists
  (`workstations.zws`, ZWS1).
- **World**: wildlife spawner split from the director gate
  (`[systems] animals`); entity HP loads from entityclasses.xml
  `passive_effect HealthMax` with `^` variable resolution; spawn pad uses
  the resolved terrain id; join SM gated by login (pre-login peers cannot
  reach enter/spawn); trader-interact quests advance on the LockRequest open.
- **Docs**: full review pass (wasm seams, state machines, hardcode
  externalization, docs audit), doc tree restructure (ZIG_CLONE.md,
  ECS_SYSTEMS.md, SCALE.md, docs/wire/), STATE_MACHINES.md +6 sections and
  GAMEPLAY.md with behavior flows, consistency + stale pass (GAP recount
  329). SonarQube Cloud workflow added; product renamed to Zeven Days to Die.

## Residual for full play (priority)

Open work only. See [TODO.md](../TODO.md) for the actionable list.

| Priority | Gap | Proper approach |
|---|---|---|
| P1 | Deco trees | Blocked on DecoManager.Read NRE RE; empty firstPackage only until object wire matches V3.1.0 |
| P2 | GameStats live sandbox sync | Full bPersistent blob on join (RE); HUD day from WorldTime; optional mid-session refresh |
| P1 | M11 multiplayer CPU | Serialize-once + named caps + pool shipped; chunk workers parked until apm need; 32-bot loadgen = operator validation |
| P2 | Quest / EAI / power depth | See GAP_ANALYSIS honest-gap sections (more EAI tasks) |
| P2 | Workstation recipe validation | Queue rides the TE body (no NetPackageRecipe*); the server still trusts the client's Recipe blob instead of checking recipes.xml |
| P2 | Workstation RecipeQueue C2S depth | Queue rides TE composite (no NetPackageRecipe*); InvTx craft works; deeper C2S optional |
| P3 | Party membership + ally persistence | Both SHIPPED: allies.zal round-trip; real `Party` state machine + `PartyData` snapshots (entity-id keyed, no PUID). Shared party scope SHIPPED: kill-XP split, shared quests, party loot stage + highest game stage feed the director |
| Parked | Full telnet / Steam browser | Admin TCP + WebUI cover research ops |
| Non-goal | Encryption* RSA+AES | Platform AntiCheat only; ServerPassword LiteNet key shipped; EAC-off scope |
| Parked | Planet-scale M2–M4 | DEM M1 proven; gateway/shards after M11 (SCALE.md) |
| Multi-ms | Worldgen W3–W7 | W0/W1/W2 shipped (3D density field); climate/caves/POI/WFC track open |

**HAVE (do not re-list as gaps):** AssignIds table (`assignids_v314.txt` 24808 rows +
maxdamage merge), stock Chunk.write + upper24, players.zsv **ZPV3** (ZPV2 still
read; progression tail + inv/journal), TE/blockmeta persist, claims.zlc,
clock.zcl, weather.zwt, workstation TE sim + workstations.zws persistence, trader TraderData v2, electrical
place+WireActions, sleeper volumes, quest multi-phase graphs, EAI task table
(9 tasks), land claim options.

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
| `src/server/game.zig` | Orchestration + Game struct (thin façade over `src/server/game/*`) |
| `src/server/game/*` | Per-domain game logic (join, tick, world, player, quest, social, trader, stability, replicate, net, loot, deco, weather, vehicle, sleeper, hooks, types) |
| `src/server/c2s/*` | All 5 C2S domains (join, move, inv, quest, misc) |
| `src/server/persist.zig` | zdtd-owned saves (players.zsv ZPV3, entities.zen, claims.zlc) |

---

## Related docs

Full map: [INDEX.md](INDEX.md).

| Doc | Role |
|---|---|
| [TODO.md](../TODO.md) | Open backlog (shipped log below the fold) |
| [GAP_ANALYSIS.md](GAP_ANALYSIS.md) | Gap inventory (honest PARTIAL sections); its scorecard feeds the standalone provenance dashboard ([provenance.html](provenance.html)) |
| [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) | M7-M16 phases (post-playable stack) |
| [PACKAGES.md](wire/PACKAGES.md) | 190-package catalog |
| [GAME_OPTIONS.md](GAME_OPTIONS.md) | serverconfig.xml → sim |
| [SCALE.md](SCALE.md) | Shard plan + substrate research (parked until M11) |
