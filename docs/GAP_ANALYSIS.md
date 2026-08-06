# Gap analysis: what a player can and cannot do on Navezgane

**Date pin:** 2026-08-06
**Game line:** stock client **V3.1.0 b14**, EAC off, Navezgane, direct IP.
**IL reference:** `/home/maci/.cache/zdtd-scratch/asm.il` (2026-08-05 dump). Line
numbers in this document refer to **that** dump. Older ranges quoted in
[GAP_ANALYSIS.md](GAP_ANALYSIS.md) drift by roughly 3500 lines in the
NetPackage region; re-check before trusting a cited line from an older doc.
**Stock XML reference:** `.../7 Days to Die Dedicated Server/Data/`.

**Method.** Nine parallel audits read the zdtd implementation first, then grounded
every claim about stock behaviour in the IL (method plus line) or in the stock
XML (file plus element). Live evidence is quoted where it exists. "The unit tests
pass" was **not** accepted as evidence for any wire claim, because zdtd encodes
and decodes with the same code.

**Conflict rule.** [STATUS.md](STATUS.md) remains the living hub for shipped
gates. Where a row here contradicts
[IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md),
this document is newer and cites its evidence inline; where it contradicts a
STATUS **PASS**, the disagreement is called out explicitly in the relevant
section and in [Not verified](#not-verified).

Status labels, used exactly as defined:

| Tag | Meaning |
|---|---|
| **WORKS** | Implemented and evidenced (test, live playtest log, or a cited code path) |
| **PARTIAL** | Implemented but incomplete or simplified; the exact shortfall is named |
| **MISSING** | Not implemented at all |

---

**Where things live:** this is the gap document. Sections 4 to 12 score each
feature against the code with anchors; Appendix A carries the long-form area
narratives, the priority bands and the deep dives, merged here from the former
MISSING_FEATURES.md. [WORK_PLAN.md](WORK_PLAN.md) owns the tasks and
[STATUS.md](STATUS.md) owns whether a gate shipped, which wins on that question.

## 1. Honest summary

### What a player can do today

Join a zdtd server over direct IP with an unmodified V3.1.0 client and reach
Playing with zero NullReferenceExceptions (live gate 23/23 on a fresh world).
Walk real Navezgane terrain built from the shipped DTM heightmap and the shipped
biome layer stacks. Enter POIs stamped from the real `.tts` prefab files, with
the block, texture and density planes reaching the client cell for cell. Dig,
place blocks, and have that survive a restart. Take client-reported damage, eat
food, die and respawn. Fight zombies that spawn near the player, chase with grid
A* around walls, chew through cover, die and drop a loot bag. Wake POI sleepers
by entering their volume. Open a chest and take items out of it. Queue a craft on
a workstation and have the server tick it. Watch the day/night clock, weather
storms driven by the real `biomes.xml` state machine, and a blood moon fire on
schedule with the correct music cue. Operators get an admin TCP console, a web
dashboard, autosave, and APM metrics.

Zombies can hurt you and you can die: server-side melee reaches the client as
EntityStatChanged, so combat has stakes (2026-08-06). Buffs apply, tick, stack
and expire on the server and reach the client. Mobs that wander out of interest
are unloaded instead of standing frozen in your world forever.

### What a player cannot do

**Nobody can find the server.** There is no Steam or EOS registration and no LAN
discovery, so a typed IP is the only route in, and the one thing that is
advertised is malformed: `ServerVersion "V 3.1.0"` fails the client's
`TryParseSerializedString`, which wants `"V.3.10.14"`.

**Traders are half there.** The trader NPC now replicates to the client with a
real `npcTraderJen` class hash, and `TraderData` rides both stock S2C paths:
`EntityCreationData.hasTraderData` on spawn and the channel-1 LockResponse
context on open (wire-tested; stock-client visual check pending). Still open:
placing traders in the five Navezgane POIs (only the demo
`spawnTrader("Trader Jen", ...)` exists), restock rolls, per-trader item lists,
and quest offering, so the full economy loop is not reachable yet.

**POIs are built right, but not finished.** Ids, rotation and height were all
wrong and are fixed (2026-08-06): ids remap through the prefab's `.blocks.nim`
including pre-v18 BlockValue layouts, prefabs turn clockwise like stock with the
matching per-block facing, and `YOffset` places caves, mines and bunkers below
the surface. Still open: `part_*` decorations are not painted, sleeper triggers
are partial, and per-block facing uses one remap table where stock resolves it
virtually per BlockShape.

**Water is in lakes but not POIs.** Lake and river water now writes from the
`water_info.xml` sources at chunk generation (water blocks below the surface),
and the chunk water channel carries the full static mass, so Navezgane's 39
sources render wet. Still dry: prefab `.tts` water planes (POI pools, flooded
basements, water tanks) and the flowing-water sim.

**Loot is mostly meaningful now.** Containers roll their own `blocks.xml`
LootList (a gun safe rolls `smallSafes`, a chest rolls `woodenChest`), and
zombie bags resolve the stock chain (`LootDropEntityClass` → the bag class's
`LootList=zPackReg`) and only drop on `LootDropProb` (.04), so most kills drop
nothing like stock. Still open: container slot counts ignore the `lootcontainer`
size attribute (everything is 8 slots), and crafting is instant and
unvalidated.

**What you are is mostly saved now.** Level, XP, survival stats (food/water)
and active buffs survive a restart via `players.zsv` v3 (the server-side ledger
`awardXp` feeds it; login-name keyed per ADR 0017). Still open: the client's
`NetPackagePlayerStats` blob is dropped (other players never see your level),
perk/skill-point spending is client-owned with no server model, and there is no
server-to-client XP/level push.

**The world is bald, dry and stepped.** The join deco burst produced 3 objects for
an entire 13x13-chunk window. Terrain is hard voxel stairs because the DTM's
sub-block byte is discarded. Nothing ever collapses.

**No progression system exists.** 57 perks, 16 skills and 23 crafting skills load
as names only, 649 `passive_effect` rows are never parsed, and gamestage does not
exist, so day 1 and day 70 spawn identical enemies at identical counts.

---

## 1a. What has landed since this analysis

This document was written at head `60153a0` on 2026-08-06. The following ranked
items shipped afterwards and are marked DONE in section 3: 1 (damage
replication), 3 (blocks.nim id remap), 4 (rotation direction and YOffset), 6
(EntityRemove on unload) and 17 (gamestages). Also landed: buffs depth, vehicle
multi-seat, party PlatformUserId, the stock telnet console surface and the M11
replication CPU work.

The per-area tables and the scorecard **have** been rescored against the code at
head `2768e30` (2026-08-06): rows verified as landed carry a `(2026-08-06)` tag
next to their state. Totals moved from 74/160/111 to 100/150/95 (current
scorecard; the per-area headers match the row counts).
The live task list is [WORK_PLAN.md](WORK_PLAN.md).

## 2. Scorecard

345 features catalogued across nine areas. Rescored 2026-08-06 at head `2768e30`.

| Area | WORKS | PARTIAL | MISSING | Total | Bottom line |
|---|---:|---:|---:|---:|---|
| [Quests](#4-quests) | 15 | 17 | 4 | 36 | Template-derived defs non-empty; stock accept marker wired; `<variable>` open |
| [Traders](#5-traders) | 6 | 9 | 11 | 26 | Trader NPC replicates with TraderData on spawn and lock-open; POI placement, restock and per-trader lists open |
| [Blood moon](#6-blood-moon) | 4 | 15 | 8 | 27 | Horde runs dusk to dawn on the right night; BloodMoonDay re-send + FX polish open |
| [POIs and prefabs](#7-pois-and-prefabs) | 11 | 14 | 7 | 32 | Ids, rotation and height now correct; part_* decorations and sleeper triggers remain |
| [Entities and AI](#8-entities-and-ai) | 15 | 21 | 13 | 49 | Real fights with real stakes and real A*; population is still thin |
| [Items, crafting, loot](#9-items-crafting-and-loot) | 10 | 15 | 10 | 35 | Containers roll their own tables; items stack like stock; crafting instant and unvalidated |
| [Player progression](#10-player-progression) | 8 | 11 | 18 | 37 | Damage and buffs land; nothing survives a restart |
| [World systems](#11-world-systems) | 20 | 19 | 12 | 51 | Walk, dig, build, persist; lakes wet, claims expire, repair heals, supports collapse |
| [Net and ops](#12-net-and-ops) | 12 | 29 | 11 | 52 | Join works, telnet is stock-shaped; invisible to browsers, thin persistence |
| **Total** | **101** | **150** | **94** | **345** | Core loop playable with stakes; content fidelity and persistence are the gap |

---

## 2a. Explicit non-goals

Do not plan these as product features of zdtd:

1. Loading `Mods/`, Harmony, ModAPI, EfficientServer, RealEarth as runtime.  
2. Integrating **7dtd-apm** Mono bridge / bpftrace into the Zig process.  
3. EAC-signed multiplayer.  
4. Shipping TFP DLLs, prefab binaries, or bulk decompiled C#.  
5. Bit-identical blood-moon festivities / full Unity FX parity.  
6. Twitch integration, editor packages, dynamic mesh as required path.

---

## 3. What to build next

Ranked across all areas by player impact, highest first. Each entry names the
area and the concrete work.

1. **DONE 2026-08-06.** Player progression / entities: replicate AI-inflicted damage.
   `applyDeferredDamage` subtracts from `health[].hp` and never sets or emits
   anything; `Dirty.hp` is written in one place and read in none. Emit
   `NetPackageEntityStatChanged` for player HP from the tick replicate pass, the
   way stock's `EntityStats::SendStatChangePacket` does (asm.il:199650). Until
   this lands, combat has no stakes and a "dead" player is a ghost who cannot
   fight back (`src/ecs/systems.zig:1280-1291`, `:1433-1447`,
   `src/server/game.zig:5527`).

2. **DONE 2026-08-06.** Traders: replicate the trader entity, then deliver
   `TraderData`. Unfiltered `.trader` from both spawn paths
   (`src/server/game.zig:7178`, `:8829`), gave `class_table[3]` the real
   `npcTraderJen` hash (builtin and XML), and wired `TraderData` onto
   `EntityCreationData.hasTraderData` and the channel-1 `LockResponse` context
   (`src/wire/stock_entity.zig` `writeTraderDataBody`,
   `src/wire/packages.zig` `buildLockResponseTrader`). Proven by a wire test and
   the trader scenario (`server/scenarios.zig`); live stock-client visual check
   still open. POI placement, restock rolls and quest offering remain.

3. **DONE 2026-08-06.** POIs: remap prefab block ids through `<name>.blocks.nim` (also converts pre-v18 BlockValue layouts).
   `applyTtsPaintToChunk` stamps the raw `.tts` type id and assumes it is in the
   runtime `AssignIds` range; it is not. 203350 of 952260 painted cells (21.4%)
   over a 120-POI sample are the wrong block, live-confirmed on the client
   (`src/world/prefabs.zig:222`, stock does it at `Prefab::loadIdMapping`,
   asm.il:928850).

4. **DONE 2026-08-06.** POIs: rotation direction and `YOffset`.
   zdtd rotates +90*r where stock rotates -90*r, so rotations 1 and 3 are swapped
   for 709 of 1559 decorations (`src/world/tts.zig:310` vs
   `Prefab::offsetToCoordRotated` asm.il:915424). Separately, `paintDecoration`
   never reads the prefab `YOffset`, so 679 of 1487 POIs sit too high and every
   cave, mine, quarry and bunker is stamped at the surface
   (`src/world/prefabs.zig:222`, stock at asm.il:902414).

5. **DONE 2026-08-06.** Loot: make containers and bags roll the right table.
   (a) `maxdamage` now carries each block's `blocks.xml` `LootList` (resolved
   through `Extends`) and the container fill uses it, so a gun safe rolls
   `smallSafes` instead of `woodenChest` (`src/assets/maxdamage.zig`
   `lootListFor`, `src/server/game.zig` fill sites). (b) The death-bag chain is
   resolved at load: `LootDropEntityClass` names a bag entity class whose own
   `LootList` is the loot.xml container (`zombieBoe` → `EntityLootContainerRegular`
   → `zPackReg`; comma-weighted form takes the first candidate). (c)
   `LootDropProb` (.04 regular zombie) is parsed and gates the bag, so most
   kills drop nothing like stock. Tests: per-block `lootListFor` against the
   stock blocks.xml, the zPackReg chain assertion, and a drop-prob gate test;
   761 tests green. Still open: container slot counts (size attribute) and
   crafting validation.

6. **DONE 2026-08-06.** Entities / net: `EntityRemove(Unloaded)` when a mob leaves interest.
   `DONE`. The replicate pass now mirrors spawn-on-approach: a mob outside a
   client's interest box gets `NetPackageEntityRemove(entityId, Unloaded)` sent to
   that one client and its `known_entities` bit dropped, the way stock's
   `NetEntityDistributionEntry::updatePlayerEntity` does (asm.il:801228-801276)
   (`src/server/game.zig:8871-8891`).

7. **DONE 2026-08-06.** Items: default `Stacknumber` to 500 and resolve
   `Extends`. Absent `Stacknumber` now defaults to stock's 0x1f4 = 500
   (asm.il:749089) and inherits through the `Extends` chain (two-pass resolve,
   children-before-parents safe, up to 24 hops). Test asserts a leaf (500), a
   one-hop (`ammoArrowExploding` 75) and a two-hop (`meleeHandZombieFeral` 1)
   case against the stock file. The "bag slot waste" playtest residual is
   closed. DamageEntity/FuelValue/eat cvars still read direct-only.

8. **DONE 2026-08-06.** World: put water in the world. Lake/river water now
   writes from the `water_info.xml` sources at chunk generation
   (`Chunk.applyWaterSources`: water blocks from the lake bed up to the source
   surface), and the chunk water channel carries the full static mass (19500)
   per water cell instead of uniform zero
   (`src/wire/stock_chunk.zig` `writeWaterChannel`, `water_block_id`).
   Navezgane's 39 sources render wet; a Navezgane loadgen smoke passes. Still
   open: prefab `.tts` water planes (POI pools) and the flowing-water sim.

9. **DONE (server side) 2026-08-06.** Progression / net: save what a player
   is. `players.zsv` v3 extends each record with a progression tail: level,
   XP (the server-side `awardXp` ledger), food/water survival stats and the
   active buffs (full BuffInstance state), restored on rejoin and handled by
   the admin wipeplayer rewrite. Old ZPV2 files still read. Round-trip test
   runs two full save/restart cycles. Honest gaps kept open: the client's
   `NetPackagePlayerStats` blob is still dropped, perk/skill-point spending is
   client-owned with no server model (the ledger saves level+XP which define
   the budget), and identity stays login-name keyed per ADR 0017 rather than
   platform user id.

10. **DONE 2026-08-06 (persistence 2026-08-07).** World: make land claims real.
    `removeClaimAt` drops the claim when the keystone breaks and `expireClaims`
    releases offline claims past `LandClaimExpiryDays` (0 disables);
    `markClaimsForEntity` tracks owner online state so the offline durability
    modifier is live. **Claims persist across restart** (`claims.zlc`): the
    owner's login name keys the restore, re-mapped to the new entity id on
    login; the preserved seen-day keeps offline expiry honest. Test covers
    keystone break, offline expiry, online-never-expires and the restart +
    re-map round trip. Still open: the client lpBlocks overlay
    (`src/server/game.zig` removeClaimAt/expireClaims,
    `src/wire/stock_inv.zig:846`).

11. **DONE 2026-08-06.** Blood moon / world: fix the night window and the day
    encoding. `isBloodMoonNight` mirrors stock `IsBloodMoonTime`: dusk on
    `bmDay` through dawn on `bmDay+1`, crossing the midnight rollover.
    `worldTimeBits` emits `(day-1)*24000` (stock `DayTimeToWorldTime`), so the
    client HUD day and `GameStats.BloodMoonDay` align and the red moon lands on
    the horde night. `setDayLightLength` implements `CalcDuskDawnHours`
    (0/24 → (22,4); dusk 22 / DL / 12+DL/2; dawn = clamp(dusk-DL,0,23)).
    CalcNextDay jitter is non-negative like stock. Unit tests over the window
    and the wire day; 772 tests green. BloodMoonDay re-send on the day roll is
    now shipped: `bloodMoonDayFor` is one authority for the scheduled day, and
    step() re-broadcasts NetPackageGameStats to entered peers when it changes,
    so a client that sat past its first horde gets the next red-moon day instead
    of a stale HUD value (scenario `bmday-resend`).

12. **Everywhere: raise or remove the fixed-size caps.**
    64 damaged blocks world-wide, 128 block rotations world-wide (both FIFO with
    O(n) eviction), 256 containers, 256 land claims, 64 workstations, 512 of 1892
    entitygroups, 16 join-rate-limit IPs, 32 in-RAM bans, ~1200 of 1487 sleeper
    POIs, 2 of 8 journal slots reaching the client. Each silently corrupts or
    drops once exceeded (`src/server/game.zig:461-467`,
    `src/world/containers.zig:9`, `src/world/workstations.zig:11`,
    `src/assets/entitygroups.zig:7`).

13. **World: store block rotation in the chunk plane.**
    `setBlockWorld` truncates to the bare u16 id, so rotation and meta live only
    in the 128-entry sparse cache the chunk encoder never consults. Every
    player-placed door, wedge and shape re-renders unrotated for a second client
    or after a relog (`src/world/store.zig:260-262`, `:653-658`).

14. **DONE 2026-08-06.** World: fix block repair. Stock repair calls
    `Block::DamageBlock` with a negated amount and sends the new **lower**
    absolute damage (asm.il:657520, :96545). zdtd now treats a lower wire value
    as the new absolute damage instead of a delta to add, so repairing 500 to
    300 sets 300 and a full repair (damage 0) clears the damage
    (`src/server/game.zig:6024`).

15. **DONE 2026-08-06 (parser + wire kinds).** Quests: implement `template=`
    inheritance and the per-objective Write shapes. `template=` now resolves
    in a two-pass (effective body = template chain + own), so the 67
    template-derived quests parse non-empty; `objective_kinds` flows from the
    catalog into `StockQuestWrite` (TreasureChest 8 bytes, POIStayWithin/
    StayWithin zero-byte, else Base), so a base tier1 zero-byte objective no
    longer trips `ValidateSizeMarker` on the join PDF. Remaining: the
    `<variable>` display-param substitution and the NPCQuestList accept-marker
    wiring (accept currently rides SharedQuest; the trader-offer list still
    re-offers accepted quests).

16. **DONE 2026-08-06.** Quests: honour the real accept path. Stock signals
    acceptance with `NPCQuestList` `eventType=RemoveQuest(1)` carrying
    `tierLevel` and `removeIndex` (asm.il:827849). The handler now accepts the
    matching offer into the journal and re-sends the list without it;
    `buildTraderQuestOffers` excludes active quests. The blind first-entry
    auto-accept on `TraderData` open stays for the loadgen/sim path but skips
    already-active quests.

17. **DONE 2026-08-06.** Entities / blood moon / progression: parse `gamestages.xml`.
    It is only a filename in `xml_patch.zig:99`. Without it `GroupGenericZombie`
    (4781 uses in prefab XML) falls through to `zombieBoe`, the `BloodMoonHorde`
    spawner's wave structure does not exist, and the world never escalates. The
    whole surface needed is visible at asm.il:955240 and :416434.

18. **World: sample subbiome deco lists.** zdtd samples only the biome's
    top-level `<decorations>` list (prob .001-.007 in pine_forest) where stock's
    `decorateChunkRandom` resolves each cell through `GetBiomeOrSubAt` and samples
    that subbiome's `m_DistantDecoBlocks` (.06-.08). Live result: 3 objects for a
    whole join window (`src/assets/biome_layers.zig:415`, asm.il:1266039).

19. **Net: fix `ServerVersion` and register with a master server.**
    `src/version.zig:12` advertises `"V 3.1.0"`; the correct
    `VersionInformation.SerializableString` is `"V.3.10.14"` (asm.il:2009306),
    and the client logs a parse warning today. Then add Steam or EOS
    registration, since direct IP is currently the only route in.

20. **Net: stop wasting the transport budget.**
    Everything goes reliable-ordered, uncompressed, one package per envelope, on
    one channel. Stock marks five motion packages unreliable (asm.il:816202 and
    four siblings), compresses eight (asm.il:808641 and siblings), and puts bulk
    world data on channel 1 (asm.il:808632). One join costs 6.4 MB out and drops
    the block `IdMapping` to `WindowFull` (live: `reliable_window_drops=1`).

21. **Progression: build a buff runtime.** 482 buff defs load and none can be
    applied, ticked, expired, relayed or persisted: no buff component, no buff
    system, no `AddRemoveBuff` relay (stock relays it at asm.il:202530).
    Injuries, infection, food effects, weather and set bonuses are client-local
    fiction (`src/ecs/components.zig:538-560`, `src/server/game.zig:4785`).

22. **Progression: simulate survival.** Nothing decrements food or water,
    stamina is a hardcoded `100/100` sent once at join, and there is no regen,
    wellness or core temperature. Also fix the eat hack that drops food to 50% of
    max when it is at or above 85% before adding
    (`src/ecs/inventory.zig:256-261`, `src/server/game.zig:6529`).

23. **Entities: add wandering hordes and the screamer heat map.**
    Both sibling AIDirector components are absent (asm.il:409345). Every constant
    needed is a single literal block at asm.il:416218. Without them, base
    activity has zero consequence and the only threat between blood moons is a
    2-zombie drip every 45 s.

24. ~~**World: add the stability plane and falling blocks.**~~
    **Shipped** (`src/world/stability.zig`, commits 6daf9ca + 02a373a): the
    per-block byte plane (15 full / 1 non-support cap / 0 falls), reset +
    distribute on first touch, and the incremental removal/placement paths
    from `StabilityCalculator`/`ChannelCalculator` (RE: `../7dtd-research/docs/stability.md`).
    A C2S SetBlock that removes a support block fells the dependency chain and
    broadcasts the collapse; placing re-spreads from supported neighbours.
    Support/ignore membership resolves from the block tables, not hardcoded.

25. **Net: count and log unhandled C2S packages, then close the list.**
    35 packages the stock client genuinely sends fall off the end of
    `handlePackage` with no counter and no log, including `SetBlockTexture`,
    `PickupBlock`, `ItemReload`, `Waypoint`, `PlayerVendingMachine`,
    `QuestGotoPoint` and `PlayerDisconnect`. Players see tools that do nothing
    and an operator cannot notice (`src/server/game.zig:3771-5480`).

---

## 4. Quests

**Headline.** zdtd loads the real `Data/Config/quests.xml` (99 defs, 6
quest_lists) and hands the client a wire-correct starter quest, but 53 of the
client-known quest defs come out empty because `template=` inheritance is not
implemented, no trader-accepted quest is ever recorded server-side, and any
journal write for a `tier1_*` quest will make the stock client mark it Failed
because the per-objective Write shapes are wrong.

**15 WORKS · 17 PARTIAL · 4 MISSING**

- **Locate and read stock quests.xml** `WORKS`
  `tryLoad` tries `quests_path`, override merge, `config_dir`,
  `game_dir/Data/Config`, then `map_dir/../Config`; parse or IO failure is logged
  rather than silently treated as absent. Verified live: a probe binary loaded the
  dedicated-server file and produced `defs=99 lists=6
  starter=quest_whiteRiverCitizen1 max_tier=6 quests_per_tier=10`.
  *Anchors:* `src/assets/quests.zig:514`, `:535`, `:560`,
  `src/server/game.zig:672`, `:988`

- **`<quests>` root attributes (starter_quest, max_quest_tier, quests_per_tier)** `WORKS`
  All three parsed off the `<quests>` element, matching `QuestsFromXml`. Probe
  output matched the stock file exactly.
  *Anchors:* `src/assets/quests.zig:396`, `asm.il:1390259-1390294`

- **XML comment stripping before parse** `WORKS`
  `stripComments` runs first, so commented-out `<quest id="tier1_defense"/>`
  entries inside `quest_list` bodies are not picked up.
  *Anchors:* `src/assets/quests.zig:382`, `:579`

- **Objective `phase` resolution (attribute and nested `<property>`)** `WORKS`
  `objectivePhase` reads the attribute then falls back to the nested property,
  exactly as stock does across `ParseObjective` and
  `BaseObjective::ParseProperties`. Matters because only 10 of 119 objectives in
  the real file use the attribute.
  *Anchors:* `src/assets/quests.zig:112`, `asm.il:1391145-1391172`,
  `asm.il:959336-959374`

- **Quest template inheritance (`template=` plus `<variable>`)** `WORKS`
  `parseCatalog` now resolves `template=` in a two-pass: the effective body is
  the template chain's content (outermost first) followed by the quest's own
  body, so objectives/rewards accumulate in stock order and the 67
  template-derived quests (all tier2..tier6, `treasure_*`,
  `challengegroup_reward_*`) parse non-empty. `<variable>` display-param
  substitution (name/subtitle/description keys) is still not resolved.
  *Anchors:* `src/assets/quests.zig` parseCatalog pre-scan + resolveBody,
  `Data/Config/quests.xml`

- **Objective type to executable phase kind mapping** `PARTIAL`
  Executes RallyPoint, ClearSleepers, EntityKill, AnimalKill, FetchKeep,
  FetchFromContainer, FetchFromTreasure, TreasureChest, InteractWithNPC,
  ReturnToNPC, RandomGotoNPC, Craft, CraftItem, Recipe, StayWithin,
  StayWithinArea, Goto, RandomPOIGoto, ClosestPOIGoto, RandomGoto. Unmapped:
  `POIStayWithin` (13 uses, the real spelling that the exact-match on
  `StayWithin` misses) and `POIBlockActivate` (2 uses), plus the whole rest of the
  `BaseObjective` family. Measured mitigation: 0 of 77 phases in the 26 real
  graphs are `.auto`, because `POIStayWithin` always shares a phase with a
  higher-scoring objective.
  *Anchors:* `src/assets/quests.zig:70`, `:86`, `:131`,
  `asm.il:1391050-1391068`, `asm.il:959583-983229`

- **Requirement elements and quest_criteria / offer_criteria** `MISSING`
  Not parsed at all. Zero player impact today: the shipped `quests.xml` contains
  0 of each. A modded file using them would silently lose its gating.
  *Anchors:* `asm.il:1390960-1391040`, `asm.il:1390474-1390510`

- **Quest `<action>` elements** `PARTIAL`
  `parseQuestDef` now parses every `<action>` (types, phase, and the cvar /
  value / message / event / gamestage_list properties). **UnlockPOI fires
  server-side on phase entry**: the phase-gated action releases the quest's POI
  lock (stock `QuestActionUnlockPOI`, asm.il 1390421-1390429), so the phase-4
  action on turn-in quests no longer leaves the POI reserved forever. The
  starter's `SetCVar StarterQuest=1` and `ShowMessageWindow` are parsed but run
  on the owning player's client in stock, so zdtd records them and fires
  nothing; `SpawnGSEnemy` (gamestage-scaled spawn) and `GameEvent` need the
  spawn/event subsystems and stay recorded-unfired.
  *Anchors:* `src/assets/quests.zig:280`, `src/server/game.zig:6320`,
  `asm.il:1390421-1390429`

- **Objective `value` / `count` / `item_count` to required count** `PARTIAL`
  Two divergences. (1) `ParseObjective` reads only id, value, optional and phase;
  zdtd honours a `count=` attribute stock ignores. (2) For the Goto family stock
  parses `Value` as a float **distance in metres** into `ObjectiveGoto::distance`,
  not a count; zdtd turns `quest_whiteRiverCitizen1`'s `value="5"` into
  `PhaseSpec{trader_interact, required=5}`. Masked only because `bumpPhase` is
  called with `n=spec.required` at the call sites.
  *Anchors:* `src/assets/quests.zig:123`, `src/ecs/systems.zig:345`, `:516`,
  `asm.il:1391090-1391107`, `asm.il:966955-966966`

- **Phase graph construction** `PARTIAL`
  `buildPhaseGraph` mirrors `QuestClass.HighestPhase` and picks the
  highest-scoring non-auto objective per phase. Verified: `tier1_clear` gives
  `highest_phase=4, phases=[goto_point:1, rally:1, kill_zombies:5,
  trader_interact:1]`. Stock's `refreshQuestCompletion` requires **all**
  non-optional objectives of a phase; zdtd tracks exactly one, so the
  `POIStayWithin` constraint and the second half of a shared phase are ignored.
  `Optional` and `ForcePhaseFinish` are unread, so quests can never fail.
  *Anchors:* `src/assets/quests.zig:205`, `src/ecs/systems.zig:234`, `:258`,
  `asm.il:987390-987648`, `asm.il:986500-986686`, `asm.il:959396-959410`

- **completiontype TurnIn vs AutoComplete** `WORKS`
  Parsed and honoured; TurnIn parks in `ready_turn_in` at the highest phase and
  completes on trader open. All 31 occurrences in the stock file are TurnIn.
  *Anchors:* `src/assets/quests.zig:296`, `src/ecs/systems.zig:222`, `:349`,
  `asm.il:990502-990503`

- **difficulty_tier** `WORKS`
  The stock property carries `param1="difficulty"`: the tier comes from the
  quest's `<variable name="difficulty">` override (27 occurrences), falling
  back to the property value. zdtd now resolves variables (last occurrence
  wins, so the derived quest overrides the template) and reads the tier through
  the param. Verified against the stock file: `tier2_fetch` reports 2 while
  `tier1_fetch` reports 1. The tier still only scales the default kill count;
  trader tier gating and the `NPCQuestList` `tierLevel` filter remain open.
  *Anchors:* `src/assets/quests.zig:294`, `:227`, `:303`

- **Rewards: counting and per-reward wire shape flags** `PARTIAL`
  The count and shape are right (LootItem 498, Item 132, Exp 85, Quest 6,
  ShowMessageWindow 4, SkillPoints 1, Skill 1; only Item/LootItem carry an
  ItemStack). `reward_coin` is the sum of the actual `casinoCoin` Item rewards
  (no invented formula). 2026-08-06: the journal now writes **real ItemStacks**
  (stock item name resolved through the negotiated items table; unknown names
  keep the stock Empty stack) and turning in pays the rewards out: the wallet
  coins in the sim, Item/LootItem stacks into the player inventory and Exp into
  the xp ledger via a tick-end drain of the completed-quest ring (scenario
  `quest-rewards`). Still open: LootItem group weights, ischosen/isfixed
  selection and RewardQuest chaining.
  *Anchors:* `src/assets/quests.zig:364`, `:307`, `src/server/game.zig:6350`,
  `:6356`

- **`<quest_list>` parsing** `WORKS`
  All 6 stock lists parsed with entries resolved to catalog ids (test_quests 7,
  trader_rekt/jen/bob/hugh 25 each, trader_joel 24).
  *Anchors:* `src/assets/quests.zig:439`, `:275`, `:413`

- **Quest.Write body layout (FileVersion 8)** `WORKS`
  `writeStockQuest` reproduces `Quest::Write` field for field, including the u16
  size markers with `FinalizeSizeMarker` semantics.
  *Anchors:* `src/wire/stock_quest.zig:144`, `asm.il:988824-989038`

- **QuestJournal.Write v5 header and footer** `WORKS`
  version 5, TraderPOIs=0, TradersByFaction=0, u16 quest count, per-quest u16
  size marker, TraderData=0. STATUS records the Quest PDF load as PASS after the
  RewardItem fix and the current client log has no `Failed loading` line.
  *Anchors:* `src/wire/stock_quest.zig:219`, `src/wire/packages.zig:516`,
  `docs/STATUS.md:28`, `asm.il:1005150-1005266`

- **Per-objective Write shape** `WORKS`
  `game.zig` now populates `StockQuestWrite.objective_kinds` from the catalog:
  each objective's type maps to BaseObjective (FileVersion + CurrentValue),
  ObjectiveTreasureChest (8 bytes) or the zero-byte POIStayWithin/StayWithin
  shape, so a base tier1 template's zero-byte objective no longer trips the
  client's `ValidateSizeMarker` on the join PDF. ObjectiveTime (u16) stays
  unmapped (rare; falls back to Base).
  *Anchors:* `src/assets/quests.zig` buildPhaseGraph kinds, `src/ecs/quest.zig`
  `ObjectiveWireKind`, `src/server/game.zig` fillStockJournalWrites,
  `src/wire/stock_quest.zig:76`, `:162`

- **objective_count on the wire for template-derived quests** `WORKS`
  `objective_count = countTags(body, "<objective")` counts the **merged**
  body: the T6 template merge (`resolveBody`) concatenates the template body
  before the quest's own, so a derived quest's count is at least the
  template's full objective list (the count the client's inherited
  `QuestClass` carries). Verified against the stock file: 67 template-derived
  quests, and `challengegroup_reward_advanced_survival` carries the full
  homesteading objective set (test asserts the derived count >= the
  template's, so the join-PDF ValidateSizeMarker cannot trip on a count of 1).
  **2026-08-07:** the pre-scan that feeds the template maps skipped
  self-closing `<quest id="X"/>` list placeholders, which previously
  overwrote the real quest body with an empty slice and silently lost all
  template content (objectives, rewards, difficulty_tier).
  *Anchors:* `src/assets/quests.zig:380`, `:394`, `:555` (resolveBody),
  `src/server/game.zig:7440`

- **Per-objective CurrentValue from the phase graph** `PARTIAL`
  Emits 255 for completed phases, clamped progress for the active phase, 0 for
  future. Reasonable for count objectives, meaningless for boolean-ish ones (Goto,
  InteractWithNPC) and for TreasureChest/StayWithin whose Read does not consume a
  CurrentValue at all.
  *Anchors:* `src/server/game.zig:6371`, `:6381`

- **Quest.PositionData** `PARTIAL`
  Location, POIPosition and POISize are written and the POI rect is resolved from
  `prefabs.xml` at accept time. Missing: `PositionDataTypes.QuestGiver` (0) is
  never written, and the Location for goto_point quests is the FNV-hash-of-id
  coordinate in a +/-100 box around the world origin, not a real POI. The compass
  and map marker point at an arbitrary spot near (0,0).
  *Anchors:* `src/server/game.zig:6390`, `src/assets/quests.zig:313`,
  `src/wire/stock_quest.zig:12`, `:614`

- **NetPackageNPCQuestList FetchList + QuestPacketEntry wire** `WORKS`
  Byte-for-byte the stock `QuestPacketEntry::read/write` order; `parseNpcQuestList`
  matches the stock read switch including the per-event tails.
  *Anchors:* `src/wire/stock_quest.zig:112`, `src/wire/packages.zig:2674`,
  `asm.il:827300-827326`, `asm.il:827512-827630`

- **Trader quest offers** `PARTIAL`
  The offer list now follows the trader's class: the 5 trader class hashes
  (npcTraderJen/Bob/Hugh/Joel/Rekt, RE-computed) map to their parsed
  `trader_*_quests` lists, with jen as the fail-closed default, so each trader
  offers its own list once POI placement spawns the other classes (scenario
  `trader-lists` proves a rekt-class trader offers `trader_rekt_quests`).
  Remaining: the 8-offer cap, the `quest_`/`tier` name filter dropping
  `intro_buried_supplies`, fabricated QuestLocation tx/ty/tz and POIName, and
  `tierLevel` echoed but not filtering.
  *Anchors:* `src/server/game.zig:6435`, `:5345`, `:5383`, `:6276`

- **Trader quest ACCEPT** `WORKS`
  Stock signals acceptance with `NPCQuestList eventType=RemoveQuest(1)` carrying
  `tierLevel` plus `removeIndex`. The handler now accepts the matching offer
  (tier-filtered, non-active, `removeIndex`'th) into the journal and re-sends
  the list without it; `buildTraderQuestOffers` excludes active quests, so the
  client stops offering an accepted quest. The scenario drives FetchList then
  RemoveQuest and asserts the journal entry plus the one-shorter list.
  *Anchors:* `src/server/game.zig` NPCQuestList remove_quest branch,
  `buildTraderQuestOffers`, `asm.il:827849-827902`

- **NetPackageQuestEvent parse/build and rally handshake** `PARTIAL`
  The head and per-event tails are parsed with bounds checks; TryRallyMarker is
  answered with the full stock reason switch; LockPOI/UnlockPOI drive
  `ecs/poi_lock.zig`; a peer may only raise events for its own entity. Dropped by
  the `else => return` arm: ClearSleeper (9), SetupFetch (12), SetupRestorePower
  (13), FinishManagedQuest (14), ResetTraderQuests (16). A fetch quest never gets
  its satchel and a clear quest never gets sleeper-cleared notifications, so
  neither can complete even though the rally marker arms correctly.
  *Anchors:* `src/wire/stock_quest.zig:438`, `:463`, `:478`,
  `src/server/game.zig:6288`, `:6322`, `asm.il:835620-836087`, `asm.il:999755`

- **POI lockout check (server half)** `PARTIAL`
  Reports QuestLock and PlayerInside. Bedroll and LandClaim reasons never fire
  because the server tracks neither, and stock's party-member exemption is not
  modelled so a party mate inside the POI blocks the reset. Unit tested.
  *Anchors:* `src/ecs/systems.zig:426`, `:2538`, `asm.il:998990-999125`

- **NetPackageSharedQuest** `WORKS`
  All four heads parsed with truncation rejected (round-trip and truncation
  tests); accepted into the server journal; removal matched by QuestCode first
  with a def_id fallback; body forwarded to the named peer or broadcast.
  *Anchors:* `src/wire/stock_quest.zig:328`, `src/server/game.zig:4686`,
  `src/wire/stock_quest.zig:559`

- **NetPackageQuestObjectiveUpdate handling** `MISSING`
  The stock body is parsed and then discarded (`_ = u;`). Only the legacy
  zdtd-native `{def_id u16, op u8}` fallback does anything, and only for
  `op==1`. Block-objective and treasure events have no effect.
  *Anchors:* `src/server/game.zig:5314`, `src/wire/packages.zig:2742`

- **S2C quest progress updates during a session** `BLOCKED (2026-08-07)`
  The stock journal is written only inside `NetPackagePlayerId`, i.e. at first
  join. Nothing re-sends a journal or emits a QuestObjectiveUpdate when the
  server-side phase advances. Every server-side advance is invisible until the
  next login.
  *Blocked on:* the exact mid-session sync mechanism. The RE docs establish
  that the client owns the quest object and the server mirrors coordination
  events over `NetPackageQuestEvent`, but the precise package/mechanism stock
  uses to push objective CurrentValue progress to the owning client is not yet
  extracted (the `QuestEventManager` hook mirroring path). Needs a
  `7dtd-research` dump of the quest objective sync path before implementing;
  guessing would invent wire behavior.
  *Anchors:* `src/server/game.zig:6088`, `:6121`, `:6185`,
  `../7dtd-research/docs/quests-challenges.md` §5 (client owns the quest)

- **Server-side journal: accept, phase advance, turn-in, coins** `WORKS`
  `questAccept` allocates a slot, assigns a monotonic quest_code, resolves a POI
  rect and skips leading scaffolding phases; the phase walk saturates correctly;
  TurnIn parks and completes on trader open, paying into the wallet with
  saturating add. Six unit tests.
  *Anchors:* `src/ecs/systems.zig:277`, `:270`, `:187`, `:2386`, `:2564`

- **Rally-point objective execution** `PARTIAL`
  `questOnRallyActivated` marks `RallyMarkerActivated` once and advances a rally
  phase, degrading to scaffolding when the instance has no POI rect so the quest
  cannot deadlock. The rect comes from `poiAt(def.tx, def.tz)` and those are the
  fabricated coordinates, so which POI a quest lands in is arbitrary rather than
  the biome/tier-filtered choice stock makes.
  *Anchors:* `src/ecs/systems.zig:458`, `:234`, `:298`, `src/assets/quests.zig:313`

- **Kill / fetch / goto / stay-within / craft progress hooks** `PARTIAL`
  All five are wired. Two divergences: every zombie kill also calls
  `questOnFetchItem(1)`, so a fetch quest completes by killing zombies; and
  `questTickGoto` uses a hardcoded 4 m radius instead of the objective's parsed
  distance, with stay-within using `max(8, required)` and `required` doubling as
  a radius. ClearSleepers is an N-kills-anywhere counter rather than "clear this
  POI's sleeper volume".
  *Anchors:* `src/server/game.zig:4961`, `:2886`, `src/ecs/systems.zig:503`,
  `:473`, `:388`, `src/assets/quests.zig:227`

- **Starter quest granted at join** `PARTIAL`
  `hasActive` only matches slots that are active and not completed, and
  `findFree`'s second pass reuses non-active slots, so a starter quest completed
  in an earlier session is granted again on the next login and the completed
  record can be overwritten. `max_journal` is 8 slots but
  `fillStockJournalWrites` is called with a 2-entry buffer, so at most the first
  two journal slots ever reach the client.
  *Anchors:* `src/server/game.zig:6779`, `src/ecs/systems.zig:314`,
  `src/ecs/components.zig:284`, `:274`, `src/server/game.zig:6780`

- **Quest journal persistence (players.zsv v2)** `PARTIAL`
  Stores def_id, quest_code, a flags byte, progress and phase, and re-resolves
  the POI rect on load. The identity stored is the parse-order catalog `def_id`;
  any edit to `quests.xml`, a `--config-overrides` patch or a game update
  reshuffles it and every saved quest silently becomes a different quest. The POI
  rect is not persisted, so a restored quest can land in a different prefab.
  *Anchors:* `src/server/game.zig:1845`, `:1947`, `:1991`,
  `src/assets/quests.zig:405`

- **Quest NavObject markers** `PARTIAL`
  Emits `nav_objects.xml` class names at join for active quests with
  client-known names. The class is derived from the legacy QuestKind, not from the
  current phase's `nav_object` property, and the position is either the fabricated
  def coordinate or the world primary spawn.
  *Anchors:* `src/server/game.zig:6245`, `:6257`, `asm.il:959379-959389`

- **Client-known-name gate before writing a quest to the wire** `PARTIAL`
  `isStockClientQuestName` accepts only `quest_` or `tier` prefixes, which keeps
  unresolvable ids out of the PDF but also silently drops legitimate stock quests:
  `intro_buried_supplies`, `treasure_*`, `challengegroup_reward_*`, `test_*`. A
  membership check against the parsed catalog would be exact.
  *Anchors:* `src/server/game.zig:6276`, `:6341`, `:6448`

- **Fuzz coverage of the quest surface** `WORKS`
  `parseCatalog` is fuzzed over arbitrary bytes; `parseNpcQuestList`,
  `parseQuestObjectiveUpdate`, `parseQuestOp` and the SharedQuest and QuestEvent
  corpora are all fuzz targets.
  *Anchors:* `src/fuzz.zig:802`, `:185`, `:327`

---

## 5. Traders

**Headline.** A player on a stock V3.1.0 client can now see and reach a trader:
the `.trader` kind replicates with a real `npcTraderJen` class hash and
`TraderData` arrives on both stock S2C paths, `EntityCreationData.hasTraderData`
at spawn and the channel-1 `LockResponse` context on open (wire-tested
2026-08-06; stock-client visual check pending). What is still missing is the
economy around the NPC: no trader is placed in the five Navezgane POIs, no
restock roll exists, per-trader item lists (Jen/Bob/Hugh/Joel/Rekt) are not
parsed, and quest offering is unwired.

**6 WORKS · 9 PARTIAL · 11 MISSING**

- **Trader placement in POIs** `MISSING`
  `src/world/` has zero trader references. The only trader in the world is one
  hardcoded `spawnTrader("Trader Jen", spawn.x+12, spawn.y, spawn.z+8)` at world
  init. Navezgane ships five trader POIs; a player who walks to a compound finds
  an empty building.
  *Anchors:* `src/server/game.zig:1137`, `Data/Worlds/Navezgane/prefabs.xml`
  (trader_jen/bob/hugh/joel/rekt)

- **Trader entity replicated to the stock client** `WORKS`
  Both ECD emitters (`sendStockEntitySpawns`, the replicate spawn-on-approach
  pass) now include `.trader`, and `class_table[3]` carries the real
  `npcTraderJen` Unity hash (from entityclasses at load, with an offline builtin
  fallback), so the client renders an EntityTrader instead of falling back to
  the zombie class. Proven by the wire test and the trader scenario, which
  asserts the join spawn body carries the trader class and data.
  *Anchors:* `src/server/game.zig:7178-7230`, `:8829-8910`,
  `src/assets/entities.zig` `defaultTrader`, `src/assets/unity_hash.zig`
  `class_npc_trader_jen`

- **TraderData carried in EntityCreationData** `WORKS`
  Stock `EntityCreationData.write` emits `bool hasTraderData` then
  `TraderData::Write` after the entityData blob, and the read side copies
  `traderData.Clone()` onto the spawned `EntityTrader`. `buildEntitySpawnStock`
  now takes a `trader_data` option and emits that block; the trader scenario
  parses the join spawn body and asserts the flag plus the trader id.
  *Anchors:* `src/wire/stock_entity.zig:250-257`, `writeTraderDataBody`,
  `asm.il:472732-472745`, `asm.il:472307-472325`, `asm.il:471328-471340`

- **TraderData on the real trader-open path (LockRequest channel 1)** `WORKS`
  Stock opens the window in two steps: activate gives `LockRequestLocal(channel 0)`
  with an `EntityTraderLockContext`; picking "trade" gives `UnlockRequestLocal`
  then `LockRequestLocal(channel 1)`, where `EntityTrader::OnLockedServer` runs
  `TraderManager::TraderInventoryRequested` (the restock roll) and stuffs
  `TraderData.Clone()` into the lock context for `NetPackageLockResponse`. zdtd's
  lock handler now detects a trader entity target and answers with
  `buildLockResponseTrader`: the request's type name and Command echoed, then
  `hasTraderData=true` and the server stock (restock roll still deferred, so the
  window shows the static stock). The trader scenario drives the request and
  asserts the response context.
  *Anchors:* `src/wire/packages.zig` `buildLockResponseTrader`,
  `src/server/game.zig` lock handler trader branch,
  `asm.il:531397-531465`, `asm.il:533826-533834`, `asm.il:533455-533474`,
  `asm.il:530836-530893`

- **NetPackageTraderData S2C snapshot** `MISSING`
  The body encoding is right but the **direction** is wrong:
  `get_PackageDirection` returns 1 = ToServer and `ProcessPackage` early-returns
  unless `IsServer`. The client calls `ProcessPackages` with ToServer as the
  disallowed direction, so an inbound one is logged as
  `[NET] Received package {0} which is only allowed to be sent to the server` and
  dropped before read. Cosmetic now that the real S2C paths (spawn ECD and
  LockResponse) carry the stock: `sendTraderSnapshot` is a refresh hint only.
  *Anchors:* `src/server/game.zig:5482-5527`, `src/wire/packages.zig:643-668`,
  `asm.il:843057-843064`, `asm.il:843277-843285`, `asm.il:787291-787305`,
  `asm.il:787103-787107`, `asm.il:803963-803970`

- **TraderData v2 body encoding** `WORKS`
  `buildTraderDataStock` matches `TraderData::Read` / `ReadInventoryData` v2
  exactly, and the envelope matches `NetPackageTraderData::write`. Correct bytes
  on a package the client will not accept.
  *Anchors:* `src/wire/packages.zig:643-668`, `asm.il:861034-861057`,
  `asm.il:861060-861230`, `asm.il:860491-860628`, `asm.il:843213-843265`

- **C2S NetPackageTraderData handling** `PARTIAL`
  Stock clients push TraderData via `TraderData::SetModified`. zdtd routes on a
  heuristic `body.len >= 9 and body[8] in {0,1}` into `parseTraderTrade`, a
  zdtd-private 9-byte format that does not exist in stock. In a real stock body
  byte 8 is the third byte of `TraderData.TraderID`, which for ids 1..10 is 0, so
  a stock push is always misread as a "buy" op and then bounces off `slotOfNetId`.
  The quest/open branch is therefore unreachable from a stock client.
  *Anchors:* `src/server/game.zig:5357-5362`, `src/wire/packages.zig:2853-2862`,
  `asm.il:860724-860742`

- **traders.xml trader_item_group parsing with nested group refs** `WORKS`
  `loadFromPath` scans every `<trader_item_group>` and `expandGroup` resolves
  child refs recursively with a depth limit and a visited set. The docs are stale
  here: `GAP_ANALYSIS.md:535` and `:612` say group refs are skipped; they are
  expanded, with a test against the real stock file.
  *Anchors:* `src/assets/traders.zig:114-177`, `:54-82`, `:183-201`,
  `Data/Config/traders.xml:1179-1194`

- **traders.xml `<trader_info>` elements** `MISSING`
  Only the literal `"<trader_item_group "` is looked for. Nothing reads id,
  reset_interval, open_time, close_time, override_buy_markup,
  override_sell_markup, allow_sell, is_vending, player_owned,
  rentable/rent_cost/rent_time, or the per-trader `<trader_items>` blocks. Every
  trader would carry the same generic `traderAlways` list; Jen's clothing, Bob's
  vehicles, Rekt's food, and the player-owned and vending variants do not exist.
  *Anchors:* `src/assets/traders.zig:131-148`, `Data/Config/traders.xml:1240-1280`,
  `:1469`, `:1472`, `:1488`

- **traders.xml root economy attributes** `MISSING`
  `buy_markup="3"`, `sell_markdown="0.2"`, `quality_mod="1,2"` and
  `quest_tier_mod` are all ignored. `casinoCoin` is hardcoded by name in
  `game.zig` rather than read from `currency_item`.
  *Anchors:* `src/assets/traders.zig:114-177`, `src/server/game.zig:5530`,
  `Data/Config/traders.xml:3`

- **Inventory roll (count ranges, prob, unique_only, quality, RNG)** `PARTIAL`
  `lowCount` always takes the low bound, so counts are deterministic minima
  (medicalBandage 3,5 gives 3; ammoGasCan 5000,10000 gives 5000). count, prob,
  unique_only and quality on a **group ref** are dropped entirely. There is no
  `GameRandom` roll, so every world and every restock produces the identical list.
  *Anchors:* `src/assets/traders.zig:85-88`, `:96-106`, `asm.il:861363+`

- **Inventory depth and ordering** `PARTIAL`
  `TraderStock` holds 12 entries, `expandGroup` writes into 64, and
  `sendTraderSnapshot` caps at 16, so only the first 12 resolvable names survive.
  `expandGroupRec` emits all direct items before descending, so XML order is not
  preserved. Stock `traderAlways` plus a trader_info's two `<trader_items>` blocks
  is well over a hundred stacks.
  *Anchors:* `src/ecs/components.zig:199`, `src/assets/traders.zig:10`, `:71-81`,
  `src/server/game.zig:5498`, `:6762`

- **Buy/sell pricing from items.xml EconomicValue** `PARTIAL`
  `price = econ/10`, `sell = econ/50`. Stock multiplies EconomicValue by the
  `BuyCostMultiplier` passive, then `TraderInfo.BuyMarkup` (3), then a quality lerp
  and `PercentUsesLeft`, plus `(1 + Entry.Markup*0.2)`. zdtd is roughly 30x low on
  buy and 10x low on sell. Because the client computes the displayed price itself
  in `XUiM_Trader`, a working window would show one number and the server would
  charge another.
  *Anchors:* `src/server/game.zig:6757-6777`, `src/assets/items.zig:429-432`,
  `asm.il:1830470-1830700`, `Data/Config/traders.xml:3`

- **Trade execution** `PARTIAL`
  `systems.trade` is coherent bookkeeping with rollback and overflow guards, but
  only over zdtd's private 9-byte body and only exercised by zdtd's own scenario
  harness. Two behavioural gaps regardless of wire: you can only sell an item the
  trader already stocks, and the trader's money is never debited when you sell.
  *Anchors:* `src/ecs/systems.zig:623-689`, `:636-640`,
  `src/server/scenarios.zig:614-633`

- **Trader wallet / AvailableMoney** `PARTIAL`
  A fixed `trader_wallet_dukes = 5000` is written into every TraderData and never
  spent, regenerated per reset interval, or made per-trader. Selling is
  effectively unlimited; stock also enforces `TraderInfo.TraderBuyLimit`.
  *Anchors:* `src/server/game.zig:133-136`, `:5522`, `asm.il:861697`

- **Haggling / barter perks** `MISSING`
  No occurrence of "barter" anywhere in `src/`. `progression.xml` defines
  BarteringBuying/BarteringSelling (perkBetterBarter, 5%..25%) and TraderStage
  (perkDaringAdventurer, +10..+50); none are loaded or applied.
  *Anchors:* `src/` (no match), `Data/Config/progression.xml:3064-3065`, `:3084`

- **Trader tiers / TierItemGroups / traderstage_templates** `MISSING`
  `buildTraderDataStock` always writes a 0 tier-group count.
  `TraderInfo.TierItemGroups`, `TraderMaxTier`, `TraderItemAbundance` and the
  `traderstage_templates` gating are unimplemented, so stock never deepens or
  improves as the player progresses.
  *Anchors:* `src/wire/packages.zig:665`, `Data/Config/traders.xml:24-60`,
  `asm.il:863725-863767`

- **Per-entry Markup (demand model)** `MISSING`
  Written as a constant 0 with an honest comment. Stock mutates `Entry.Markup` via
  IncreaseMarkup/DecreaseMarkup and the price factor is `(1 + Markup*0.2)`.
  *Anchors:* `src/server/game.zig:5507-5513`, `asm.il:860548-860586`,
  `asm.il:1830586-1830600`

- **Restock timer** `PARTIAL`
  `traderRestock` adds +10 to every existing entry each in-game day, capped at 50.
  Stock does a full reroll on the channel-1 lock when
  `worldTime - lastInventoryUpdate >= ResetIntervalInTicks` (3 days for humans, 1
  for vending) via `HandleFullReset` plus `SpawnTierGroup`. zdtd never introduces
  new items, never drops sold-out ones, and never respects the cadence. Trader
  stock is not persisted either.
  *Anchors:* `src/ecs/systems.zig:693-706`, `src/ecs/aidirector.zig:154`, `:181`,
  `src/server/game.zig:1751`, `asm.il:863657-863767`, `asm.il:863770-863910`,
  `Data/Config/traders.xml:1240`

- **Open hours and the closed-door behaviour** `MISSING`
  Nothing reads or models open_time/close_time. Stock's `TraderInfo::get_IsOpen`
  compares `worldTime % 24000` against the open/close hours;
  `EntityTrader::OnUpdateLive` plays a warning then flips `TraderArea.SetClosed`,
  raising the bars and force-unlocking anyone in the window; `OnEntityActivated`
  refuses to open when closed and shows a "next time" tooltip.
  *Anchors:* `src/` (no reference), `asm.il:862122-862230`,
  `asm.il:531811-531898`, `asm.il:531397-531420`, `asm.il:861688-861690`

- **TraderArea replication (NetPackageWorldAreas)** `MISSING`
  The package name is in the id table but there is no builder and no send site.
  Without it the client has no protect bounds, no teleport volumes and no
  IsClosed state: no safe zone, no zombie exclusion, no auto-teleport at closing.
  *Anchors:* `src/wire/packages.zig:251`, `asm.il:847341-847513`,
  `asm.il:1207080+`

- **Vending machines** `MISSING`
  `te_types.trader = 2` is a named constant only; no vending TE is ever emitted
  and the storage/workstation handlers explicitly exclude it. `blocks.xml` carries
  TraderID 4/10 for vending blocks and `traderAlways` even sells
  `cntVendingMachine`.
  *Anchors:* `src/wire/te_types.zig:7`, `src/server/game.zig:7423`,
  `Data/Config/blocks.xml:51206`, `Data/Config/traders.xml:1472`

- **Quest offering via NetPackageNPCQuestList** `PARTIAL`
  The reply is legal (base direction Both) and the bodies are right, but the
  client's `ProcessPackage` resolves the npc id with `GetEntity(id) as
  EntityTrader` before doing anything, and zdtd has no trader entity on the
  client, so the offers are silently discarded. The list id is hardcoded to
  `trader_jen_quests` at all three call sites; `npc.xml` is only forwarded as a
  ConfigFile, never parsed.
  *Anchors:* `src/server/game.zig:6434-6462`, `:5345`, `:5364`, `:5383`,
  `src/assets/xml_patch.zig:101`, `asm.il:827745-827765`, `asm.il:804011-804018`,
  `Data/Config/npc.xml:19-31`

- **Quest turn-in / phase advance on trader open** `PARTIAL`
  `questOnTraderOpen` is correct and wired into the `NetPackageTraderData` branch,
  but that branch is only reached when `body[8]` is not 0 or 1, which a stock
  push never satisfies. Works in zdtd's own scenario harness only.
  *Anchors:* `src/ecs/systems.zig:335-350`, `src/server/game.zig:5362`,
  `src/server/scenarios.zig:594-599`

- **Trader dialog window, greeting, voice, radial commands** `MISSING`
  `EntityTrader` exposes "talk"/"trade"/"remove" and opens
  `XUiC_DialogWindowGroup` on the channel-0 lock, driven by `dialogs.xml`. zdtd
  has no dialog handling; `dialogs.xml` is only forwarded as a ConfigFile.
  *Anchors:* `asm.il:530944-530960`, `asm.il:533816-533826`,
  `src/assets/xml_patch.zig:100`

- **Currency item and wallet/inventory reconciliation** `WORKS`
  `casinoCoin` is resolved by name through the items catalog and `trade()` fails
  closed when the id is 0; the wallet is reconciled against inventory coin stacks
  before spending and coins are removed from the bag first, so the sync cannot
  re-mint spent money. The name is hardcoded rather than read from
  `currency_item`, which is a fidelity nit.
  *Anchors:* `src/server/game.zig:5530`, `src/ecs/systems.zig:625-645`

---

## 6. Blood moon

**Headline.** A blood moon does fire on the server every Nth day and the client
hears the blood-moon music and sees the biome forced to its `bloodMoon` weather
group, but the horde is a flat 4-zombie-every-6s trickle from the ordinary night
spawn group with no gamestage escalation, it ends at midnight instead of dawn,
and the red moon and red HUD warning clock the client draws from
`GameStats.BloodMoonDay` land on the wrong night because zdtd's WorldTime day
encoding is one day high.

**4 WORKS · 15 PARTIAL · 8 MISSING**

- **Blood-moon day schedule from BloodMoonFrequency** `PARTIAL`
  `isBloodMoonNight` tests `day % bloodmoon_frequency == 0`; 0 disables. Stock
  uses no modulus: `CalcNextDay` computes
  `nextBM = bmDayLast + Frequency + RandomRange(0, Range+1)` and persists it.
  With Range=0 the two agree, so the default 7-day cadence matches; what is
  missing is that the schedule is derived from the live day counter every tick, so
  it is neither persisted nor seekable.
  *Anchors:* `src/ecs/aidirector.zig:41`, `:44`, `src/server/config.zig:225`,
  `asm.il:412880`, `asm.il:412986`

- **BloodMoonRange jitter** `PARTIAL`
  zdtd jitters +/-range around each frequency multiple. Stock only ever adds
  0..range, so a stock blood moon is never early. Worse, the
  `GameStats.BloodMoonDay` zdtd sends ignores `bloodmoon_range` entirely, so with
  Range>0 the server-simulated horde night and the client-rendered blood moon are
  on different days by construction.
  *Anchors:* `src/ecs/aidirector.zig:57`, `src/server/game.zig:6216`,
  `asm.il:412894`, `src/server/config.zig:231`

- **Blood-moon night window (dusk to dawn)** `WORKS`
  `isBloodMoonNight` now mirrors stock `IsBloodMoonTime` (asm.il:1926341):
  active on `day==bmDay` when `hour>=dusk`, and on `day==bmDay+1` when
  `hour<dawn` — so the horde runs dusk on the blood-moon day through dawn of
  the next, crossing the midnight rollover. The midnight stop and the phantom
  pre-dawn window are gone.
  *Anchors:* `src/ecs/aidirector.zig` `isBloodMoonNight`, `asm.il:1926341`,
  `asm.il:412859`

- **Dusk/dawn hours from DayLightLength** `WORKS`
  `setDayLightLength` implements stock `CalcDuskDawnHours` (asm.il:1926249):
  DayLightLength 0/24 → (dusk 22, dawn 4); dusk starts at 22, clamps to DL when
  DL > 22, becomes 12 + DL/2 when DL < 18; dawn = clamp(dusk - DL, 0, 23). At
  the default 18 it still gives (4,22); non-default values now match the
  client's locally computed sky window.
  *Anchors:* `src/ecs/aidirector.zig` `setDayLightLength`, `asm.il:1926249`

- **WorldTime day number on the wire** `WORKS`
  `worldTimeBits` now emits `(day-1) * 24000 + hours*1000` (stock
  `DayTimeToWorldTime`, asm.il:1926175), so `WorldTimeToDays` (wt/24000 + 1)
  round-trips the wire day. The client HUD day and `GameStats.BloodMoonDay`
  align with the server day, so the red moon lands on the horde night.
  *Anchors:* `src/ecs/aidirector.zig` `worldTimeBits`,
  `src/server/admin.zig` `dayTimeToWorldTime`, `asm.il:1925943`,
  `asm.il:1926175`

- **GameStats.BloodMoonDay sent to the client** `PARTIAL`
  Computed and written at the BloodMoonDay slot of the full persistent blob, but
  only sent at join and on the respawn re-bundle; never re-sent when the day
  rolls, and not resent by `settime`. A client that stays connected past its first
  blood moon keeps a BloodMoonDay in the past forever.
  *Anchors:* `src/server/game.zig:6214`, `:6216`, `:6206`, `:3869`,
  `src/wire/packages.zig:1998`, `src/server/game.zig:2292`

- **Client blood-moon sky FX** `PARTIAL`
  Entirely client-side: `SkyManager::OnGameStatsChanged` latches bloodmoonDay from
  stat 58 and dusk/dawn from stat 42, and `IsBloodMoonVisible` recomputes the
  window as `(dusk-4, dawn+2)`. zdtd sends both stats so the mechanism is wired,
  but the day off-by-one puts the red moon on the wrong night.
  *Anchors:* `asm.il:2041922`, `asm.il:2042093`, `src/wire/packages.zig:1998`,
  `:1983`

- **Blood-moon warning window (red HUD clock)** `PARTIAL`
  Stock has no warning packet: `XUiC_CompassWindow` colours the clock FF0000 when
  `GameStats[BloodMoonDay]` equals the client's current day and
  `World::BloodMoonWarningHour <= hour` (default 8). Three problems: the day
  off-by-one puts it on the wrong day; zdtd sends an empty SandboxCode so the
  client never applies the server's BloodMoonWarning choice; and `BloodMoonWarning`
  is parsed nowhere in zdtd. Stat 61 is read only by `GameSenseManager`
  (SteelSeries LEDs), never by the HUD.
  *Anchors:* `asm.il:1574299`, `asm.il:1248240`, `asm.il:2502629`,
  `asm.il:1913041`, `src/wire/packages.zig:1892`, `:2001`

- **NetPackageBloodmoonMusic** `PARTIAL`
  Builder is IL-correct and broadcast on the rising and falling edge every 20
  ticks. Two gaps: it is a single global bool where stock computes it per player
  from `EntityPlayer.bloodMoonParty`; and because it is edge-triggered only, a
  client that joins **during** a blood moon never receives it and hears normal
  night music all night.
  *Anchors:* `src/wire/packages.zig:896`, `src/server/game.zig:8114`, `:8119`,
  `asm.il:807834`, `asm.il:2593714`, `asm.il:807889`

- **NetPackageHordeEvent** `MISSING`
  Builder and enum exist and are byte-correct but nothing calls
  `buildHordeEventBody`. This is deliberate and correct for parity: there is no
  `GetPackage<NetPackageHordeEvent>()` anywhere in the stock assembly, so stock
  never emits it either. No player impact relative to stock. The repo doc cites a
  stale line range.
  *Anchors:* `src/wire/packages.zig:930`, `asm.il:822185`, `asm.il:518546`,
  `docs/GAP_ANALYSIS.md:889`

- **Blood-moon weather override** `WORKS`
  `Manager.tick` pushes every biome's next storm at least 5000 ticks past now and
  forces each biome to its own `bloodMoon` weather group index once per
  transition, releasing on the falling edge. This is a real S2C
  `NetPackageWeather` change, so a stock client does observe it.
  *Anchors:* `src/world/weather.zig:106`, `:125`, `src/server/game.zig:8106`,
  `src/assets/biome_layers.zig:757`, `Data/Config/biomes.xml:190`

- **Horde spawn composition** `PARTIAL`
  Blood-moon spawns reuse `Director.spawnNearPlayers`, which picks from the
  biome's ordinary night entitygroup (`ZombiesNight` for pine_forest) or a fixed
  5-slot class rotation. Stock draws from the `BloodMoonHorde` spawner in
  `gamestages.xml`, whose stages reference `feralHordeStageGS1..GS4086`. Every
  blood moon is the same handful of basic zombies regardless of level or day.
  *Anchors:* `src/ecs/aidirector.zig:233`, `:247`, `src/server/game.zig:892`,
  `:6682`, `Data/Config/gamestages.xml:4428`, `Data/Config/entitygroups.xml:15809`

- **Escalation by gamestage** `MISSING`
  zdtd has no gamestage concept: `gamestages.xml` is only a patchable filename,
  and `game.zig:7044` says outright "no gamestage scaling: gsScale=1". The blood
  moon is a constant burst of `max(1, BloodMoonEnemyCount/2)` every 6 s all night.
  Stock walks a per-party `GameStageDefinition` stage through 6-7 spawn groups
  with num/maxAlive/duration/interval, ending in a station-keeping wave. No ramp,
  no lull, no final wave.
  *Anchors:* `src/ecs/aidirector.zig:163`, `:164`, `src/assets/xml_patch.zig:99`,
  `src/server/game.zig:7044`, `asm.il:416494`, `asm.il:416532`,
  `Data/Config/gamestages.xml:4430`

- **BloodMoonEnemyCount semantics** `PARTIAL`
  Parsed (clamped 0..60) and used as `wave = max(1, count/2)` per 6 s burst. Stock
  meaning is different: it is the per-player multiplier for the party's alive cap,
  `enemyActiveMax = min(30, count * partyMemberCount)`. zdtd has no per-player
  alive cap at all.
  *Anchors:* `src/server/config.zig:226`, `src/ecs/aidirector.zig:96`, `:164`,
  `src/server/game.zig:6224`, `asm.il:413818`, `asm.il:412041`

- **Alive-zombie budget during a blood moon** `PARTIAL`
  `Director.tick` hard-returns at `MaxSpawnedZombies`, the same cap day and night.
  Stock's blood-moon party spawner calls `AIDirector::CanSpawn(1.9f)`, a 1.9x
  budget, which is what the stock serverconfig comment refers to. The horde caps
  out at the ordinary world budget and thins as soon as anything else is alive.
  *Anchors:* `src/ecs/aidirector.zig:151`, `:104`, `src/server/config.zig:46`,
  `asm.il:413528`

- **Spawn placement and spawn direction rotation** `PARTIAL`
  Deterministic angle at 12-22 m from each player. Stock spawns at
  `cSpawnDistance = 40` with +/-45 degrees of jitter, a hard 30 m minimum, 0..10
  extra random distance, and rotates `spawnBaseDir` by 120 degrees per group.
  Zombies materialize inside visual range in front of the player and always from
  the same bearing pattern.
  *Anchors:* `src/ecs/aidirector.zig:165`, `:240`, `asm.il:413135`,
  `asm.il:414107`, `asm.il:413541`

- **Blood-moon party grouping (multiplayer)** `MISSING`
  No party concept: every player independently gets `wave` zombies per burst.
  Stock groups players within `cPartyJoinDistance = 80`, computes one shared
  gamestage frozen for the night, spawns against the party focus, and teleports a
  drifting party zombie back past `cTeleportDist = 150`. With 2+ players zdtd
  doubles the spawn rate where stock would pool it.
  *Anchors:* `src/ecs/aidirector.zig:233`, `asm.il:413090`, `asm.il:412744`,
  `asm.il:414221`

- **Blood-moon zombie strength** `PARTIAL`
  Real and observable: hp x1.5 on top of the GameDifficulty scale, `ZombieBMMove`
  speed band while active, and `BlockDamageAIBM` replacing `BlockDamageAI`. All
  three are zdtd approximations; stock has no flat 1.5x hp, difficulty comes from
  the gamestage groups picking feral and radiated classes with their own stats.
  *Anchors:* `src/ecs/aidirector.zig:266`, `:132`, `src/server/game.zig:3097`,
  `src/server/config.zig:51`, `:57`

- **Blood-moon end and despawn at dawn** `PARTIAL`
  Nothing happens beyond the flag flipping: music false edge plus weather release.
  Survivors are left in the world and only disappear via `systemDespawnFar`. Stock
  `EndBloodMoon` also does not despawn, but it clears IsHordeZombie,
  bIsChunkObserver and IsBloodMoon on every EntityEnemy so they stop pinning
  chunks, and the party `Tick` calls `KillPartyZombies` when the party empties.
  With zdtd's window ending at midnight, leftover horde zombies chase you until
  dawn anyway.
  *Anchors:* `src/ecs/systems.zig:1707`, `:1722`, `src/server/game.zig:8116`,
  `asm.il:412618`, `asm.il:413662`

- **Blood-moon bonus loot bags** `MISSING`
  Stock bumps `Entity.lootDropProb` by `LootBonusScale` on every
  `bonusLootEvery`-th horde zombie. zdtd's blood-moon zombies use the ordinary
  loot path, so the reward half of the night is missing.
  *Anchors:* `asm.il:413875`, `asm.il:414005`, `src/ecs/aidirector.zig:269`

- **Blood-moon corpse decay / chunk pinning** `MISSING`
  Stock sets `bIsChunkObserver` on every horde zombie and divides
  `timeStayAfterDeath` by 3. zdtd models neither. Note the client-side 3x gib
  cleanup keys on `EntityAlive.IsBloodMoon`, which is not on the wire in stock
  either, so a stock dedi client is in the same boat.
  *Anchors:* `asm.il:412595`, `asm.il:413978`, `asm.il:59416`

- **Blood-moon schedule persistence across restart** `MISSING`
  `WorldClock.day` is never loaded from or written to any save: it starts at 1 on
  every start. Stock persists bmDay/bmDayLast/bmDayNextOverride via the
  component's Read/Write alongside worldTime. Restart resets the calendar to day 1
  08:00, so a save is never more than 7 days from its first horde.
  *Anchors:* `src/ecs/aidirector.zig:8`, `src/server/game.zig:579`,
  `asm.il:412351`, `asm.il:412406`

- **Console/admin visibility of the blood moon** `PARTIAL`
  `gettime` prints "bloodmoon in N days" and the webui status page shows
  ACTIVE/idle plus the frequency. Both use the plain modulus and so ignore
  BloodMoonRange, and the day they print is the server day, one lower than the
  player's HUD. There is no way to force a blood moon; stock's only trigger for
  `SetForToday` is the gameevents `ActionSetHordeNight` sequence action (there is
  no `bloodmoon` console command in V3.1.0 either).
  *Anchors:* `src/server/game.zig:2219`, `:2435`, `src/server/webui.zig:1357`,
  `asm.il:412317`, `asm.il:2573467`

- **settime command arity** `PARTIAL`
  zdtd treats a lone numeric argument as a **day**, so the stock-syntax
  `settime 22000` (raw world time, 1000 = one hour) sets the server to day 22000.
  The playtest harness sends exactly that on the `settime_bloodmoon` barrier,
  which is why the `combat/blood_moon_music` case only ever verifies that the
  client clock reached night. `settime day` / `settime night` also differ.
  *Anchors:* `src/server/game.zig:2273`, `:2284`, `asm.il:251877`,
  `7dtd-playtest/scripts/playtest_run.py:1399`

- **Where the blood-moon options come from** `PARTIAL`
  zdtd reads BloodMoonFrequency/Range/EnemyCount as serverconfig properties.
  Stock V3.1.0's shipped serverconfig no longer defines them at all: only
  `TwitchBloodMoonAllowed` and `SandboxCode`, with
  `UpdateInGameValuesWithSandboxOptions` pulling SandboxOptions 48/49/51 into the
  component statics. zdtd writes empty SandboxPreset/SandboxCode, so the client
  falls back to its own local GamePrefs.
  *Anchors:* `src/server/config.zig:104`, `src/wire/packages.zig:2009`,
  `asm.il:2501788`, `serverconfig.xml:103`,
  `output_log_client_zdtd_connect.txt:3672-3675`

- **Wandering horde / screamer heat** `MISSING`
  Stock creates `AIDirectorWanderingHordeComponent` and
  `AIDirectorChunkEventComponent` alongside the blood-moon component. zdtd's
  director has only a fixed daytime "scout" of 1 zombie every 120 s and a
  2-per-45s night trickle, with no heat map, no screamer and no wandering horde
  schedule.
  *Anchors:* `src/ecs/aidirector.zig:159`, `:168`, `asm.il:409351`,
  `Data/Config/gamestages.xml:1582`, `:3458`

- **Blood-moon death bookkeeping (IsBloodMoonDead)** `MISSING`
  `StartBloodMoon` clears `EntityPlayer.IsBloodMoonDead` on every tracked player.
  zdtd has no such flag, so nothing downstream can key on "died during a blood
  moon".
  *Anchors:* `asm.il:412541`, `src/ecs/aidirector.zig:148`

---

## 7. POIs and prefabs

**Headline.** Navezgane's POIs are present, stamped from the real stock `.tts`
files and reach a stock client, but they are built from the wrong block ids
(~21% of cells), placed at the wrong height (46% of POIs ignore YOffset) and
rotated the wrong way round for rotation 1/3 (46% of decorations), so a player
can walk into every POI but none of them is the building TFP authored.

**11 WORKS · 14 PARTIAL · 7 MISSING**

- **prefabs.xml decoration parse** `WORKS`
  Reads all 1559 `<decoration>` elements with rotation mod 4 and
  `y_is_groundlevel`, matching `DynamicPrefabDecorator.Load`'s attribute set. An
  independent parse of the same file yields 1559 decorations and the rotation
  histogram 473/363/377/346.
  *Anchors:* `src/world/prefabs.zig:201`, `:237`, `:245`, `asm.il:902273-902400`

- **Prefab .tts binary decode (v19)** `WORKS`
  Header, block plane, density, damage, sparse texture, sparse water and TE list.
  Independently re-implemented in Python with identical results on
  abandoned_house_01/07, store_gun_01 and house_old_ranch_13. Child cells
  (0x40000000) cleared; `offsetToCoord` matches stock.
  *Anchors:* `src/world/tts.zig:88`, `:67`, `asm.il:920310-920625`,
  `asm.il:915380-915421`

- **Prefab block id remap through `<name>.blocks.nim`** `WORKS` (2026-08-06)
  `applyTtsPaintToChunk` stamps the raw `.tts` type id and the comment assumes
  "TTS type ids are AssignIds-range on stock installs". That is false: every
  Navezgane POI ships a `.blocks.nim` (120/120 sampled) whose ids have drifted
  from the current install's AssignIds. Measured over a random 120-POI sample:
  203350 of 952260 painted cells (21.4%) carry an id whose current-install block
  is different; per POI 2.5% to 49.5%. Live client evidence at world (-241,471):
  y63 id 2505 is `brickShapes:cube` in the nim but renders as
  `woodShapes:signLetter_period`; y69 id 1342 authored `cubeBaseboard` renders
  `cubeHalfLocalNorthFaceInside`. zdtd also pushes its own blocks NameIdMapping,
  so the client cannot correct it.
  *Anchors:* `src/world/prefabs.zig:222`, `src/world/tts.zig:373`,
  `src/server/game.zig:6207`, `asm.il:928850-928971`

- **POI footprint / AABB placement** `WORKS`
  `boundsXZ` keeps position as the min corner and swaps size_x/size_z for
  rotations 1 and 3, identical to stock for all four rotations.
  *Anchors:* `src/world/prefabs.zig:66`, `asm.il:921616-921637`,
  `asm.il:944180-944243`

- **Prefab rotation: block coordinate mapping** `WORKS` (2026-08-06)
  Rotations 1 and 3 are swapped: zdtd rotates +90*r where stock rotates -90*r.
  Stock forward map: r=1 gives `(sz-1-z, x)`; r=3 gives `(z, sx-1-x)`. zdtd has
  those two swapped. `Prefab::RotatePointOnY` confirms the sign directly
  (`AngleAxis(-90, up)` on the `_bLeft` path). Independent data proof: for the 130
  Navezgane decorations declaring `POIMarkerType=RoadExit`, the stock map puts the
  marker within 4 blocks of a road pixel in `splat3_processed.png` for 129/130
  (rot1 24/24, rot3 23/23); zdtd's map only 94/130, and only 6/24 and 6/23 for rot
  1 and 3. 709 of 1559 decorations use rotation 1 or 3, so front doors, garages
  and driveways of ~46% of POIs face away from their road.
  *Anchors:* `src/world/tts.zig:310`, `asm.il:915424-915618`,
  `asm.il:915620-915698`, `asm.il:921639-921684`, `asm.il:931080-931180`

- **Prefab rotation: per-block facing** `PARTIAL` (step count fixed 2026-08-06)
  The 24-orientation permutation table is correct (re-derived from
  `BlockShapeNew::rotationsToQuats` with the world-space pre-multiply
  `ConvertRotationFree` performs). What is wrong is the **step count**: stock
  applies `CalcRotation(rot, 4-r)` because `RotateY` replaces `_rotCount` with
  `4-_rotCount` when `_bLeft`. Since `rotateLocalXZ` is inverted the same way the
  POI stays internally coherent, but for r=1 and r=3 the whole building is 180
  degrees off stock. Also unmodelled: the remap is virtual per BlockShape in stock
  (`BlockShape` base does `(rotation+rotCount)&15`; `BlockShapeCube` does a
  band-local cycle) while zdtd applies the `BlockShapeNew` table to every block.
  *Anchors:* `src/world/tts.zig:293`, `:309`, `asm.il:181926-181957`,
  `asm.il:181959-182018`, `asm.il:173648-173702`, `asm.il:166904-166921`,
  `asm.il:171283-171414`

- **Prefab YOffset** `WORKS` (2026-08-06)
  `paintDecoration` uses `origin_y = d.y` and never reads the prefab .xml
  `YOffset`; stock applies it in `DynamicPrefabDecorator.Load` right after
  `GetPrefabRotated`. 679 of the 1487 full-POI decorations (46%) have a nonzero
  YOffset. Houses are typically -1 or -2, so their ground floor sits a block above
  the pad. The extremes are structural: canyon_mine -55, house_old_ranch_13 -44,
  cave_07 -33, cave_03 -32, bunker_00 -30, quarry_02 -30, ten caves at -25. Every
  cave, mine, quarry and bunker is stamped as a surface box with no entrance.
  *Anchors:* `src/world/tts.zig:373`, `src/world/prefabs.zig:222`,
  `asm.il:902414-902420`, `asm.il:917079-917081`, `asm.il:914052`

- **Terrain flatten under a POI footprint** `PARTIAL`
  Forces the height plane to `deco.y+1` for every cell of every full-POI AABB. The
  stock world does not need it: `dtm_processed.raw` already contains the pad, at
  `deco.y-1` for 1272 of 1487 POIs and already perfectly flat for 1101. The call
  runs after `ensureBlocksWithStack`, so the terrain blocks are fine; only the
  heights plane is 2 blocks high, which makes teleports, respawns and
  heightWorld-based placement inside a POI land 2 blocks above the floor.
  *Anchors:* `src/world/prefabs.zig:79`, `src/world/store.zig:589`

- **Painting part_* decorations** `MISSING`
  `applyTtsPaintToChunk` returns early for any `part_` name and `sleepers.zig`
  skips them too. Navezgane has 72: driveways, town signs for
  Gravestowne/Diersville/Perishton, and the Perishton pedestrian bridge.
  *Anchors:* `src/world/prefabs.zig:232`, `src/world/sleepers.zig:217`

- **Multi-block / child blocks** `MISSING`
  `parseBlocks` zeroes every cell with the child bit 0x40000000 and nothing
  regenerates them. Stock calls `AddAllChildBlocks` at the end of `RotateY` and
  after load. Large POI props exist only as their parent cell, partly
  walk-through and partly invisible.
  *Anchors:* `src/world/tts.zig:106`, `asm.il:918950-919033`, `asm.il:921630`

- **Prefab authored block damage plane** `PARTIAL`
  Decoded into `TtsBlocks.damage` but nothing consumes it; the chunk encoder
  writes the damage channel as all-zero. POIs that should arrive pre-damaged
  arrive pristine, losing both the ruined look and the intended weak spots.
  *Anchors:* `src/world/tts.zig:136`, `:358`, `src/wire/stock_chunk.zig:383`

- **Prefab water plane** `MISSING`
  The v>=17 sparse water channel is only skipped over to find the TE list. POI
  pools, flooded basements and water tanks are dry.
  *Anchors:* `src/world/tts.zig:172`

- **Prefab texture/paint plane** `WORKS`
  The sparse texture bitstream is decoded into a dense per-cell u64 and carried
  through `setBlockTexDens` onto the wire, so paint-driven shape blocks keep their
  face material instead of rendering grey.
  *Anchors:* `src/world/tts.zig:148`, `src/world/store.zig:597`

- **Prefab tile-entity list to world positions** `PARTIAL`
  TEs are rotated with the same inverted `rotateLocalXZ`, so they land where the
  inverted paint put their block: consistent with the stamped building but 180
  degrees off stock for rot 1/3. Only the local position and type byte are used;
  the payload (authored contents, lock state, sign text, light colour) is dropped,
  so POI safes and lockers arrive empty and unlocked and POI signs blank.
  *Anchors:* `src/world/prefabs.zig:243`, `:261`, `src/world/tts.zig:22`, `:228`

- **TileEntityType constants** `PARTIAL`
  `src/wire/te_types.zig` does not match the stock enum. Stock: Collector=3,
  LandClaim=4, Loot=5, Trader=6, SecureLoot=0x0A, Workstation=0x0C, Sign=0x0D,
  Powered=0x0F, Light=0x12, Trigger=0x13, Sleeper=0x14, SecureLootSigned=0x16,
  Composite=0x19. zdtd has loot=1, trader=2, composite=5, secure_loot=6,
  powered=10, sign=0x16, light=0x19; only none=0 and workstation=12 are right. The
  `.tts` TE list really does use the stock enum (real prefabs contain only 18, 20
  and 25), so the prefab TE filter accepts real Composite TEs only by accident
  (zdtd's `light` = 0x19 equals stock Composite) and would misclassify a real
  Loot, Trader or SecureLoot TE.
  *Anchors:* `src/wire/te_types.zig:5`, `:19`, `src/server/game.zig:7423`,
  `asm.il:1311761-1311788`

- **Loot container discovery in a POI chunk** `PARTIAL`
  Scans 65536 cells for ids `maxdamage` marks as storage, caps at 32 per chunk.
  Two problems compound: the ids in the chunk are the un-remapped prefab ids, so
  real cabinets and safes are often not recognised while unrelated cells sometimes
  are; and the global store is a fixed 256 entries with no eviction, so
  `getOrCreate` returns null once 256 containers exist server-wide. Navezgane has
  thousands.
  *Anchors:* `src/server/game.zig:7380`, `:6657`, `src/world/containers.zig:9`,
  `:82`

- **Loot content per container** `WORKS`
  `fillContainerFromLoot` now takes the block's `blocks.xml` LootList via
  `maxdamage.lootListFor` (resolved through `Extends`), so a gun safe rolls
  `smallSafes`, a chest `woodenChest`, and a medicine cabinet its own table.
  `blocks.xml` declares ~172 distinct LootList values across 449 blocks and
  `loot.xml` defines 340 lootcontainers; the mapping now exists end to end.
  *Anchors:* `src/server/game.zig` fill sites, `src/assets/maxdamage.zig`
  `lootListFor`, `Data/Config/blocks.xml`, `Data/Config/loot.xml`

- **Loot container size** `PARTIAL`
  Every container is created with `slot_count 8`. Stock takes it from the
  `lootcontainer` size attribute: woodenChest 6,2 = 12; playerGunSafe 8,10 = 80.
  *Anchors:* `src/server/game.zig:7404`, `:7428`, `src/world/containers.zig:31`

- **Loot respawn (LootRespawnDays / LootTimer)** `MISSING`
  No respawn timer and no expiry on the touched flag. The client reports
  `GamePref.LootRespawnDays = 7` and zdtd never acts on it, so a looted container
  stays empty forever and there is no reason to revisit a POI.
  *Anchors:* `src/world/containers.zig:31`, `src/server/game.zig:7445`

- **POI reset / rebuild** `MISSING`
  Nothing resets a POI's blocks; a repo-wide search for ResetBlocks / poi_reset
  finds no implementation. Stock resets on fetch/clear quest accept or lockout
  expiry. A POI destroyed or cleared once stays that way permanently, so
  repeatable quests on the same POI can never restore it.
  *Anchors:* `src/ecs/poi_lock.zig:1`, `asm.il:945360-945387`

- **Quest POI lockout table** `WORKS`
  Lock/unlock/expire with the 2000-tick grace, quester list, rect containment and
  table bound, grounded in `QuestEventManager`/`QuestLockInstance` and covered by
  three unit tests.
  *Anchors:* `src/ecs/poi_lock.zig:19`, `:90`, `:115`, `asm.il:1001892-1002045`

- **POI rect lookup for quests** `PARTIAL`
  Returns the prefab AABB (correct and rotation-independent) but iterates all 1559
  decorations linearly per query and does not exclude `part_*`, so a driveway or a
  city sign can be returned as the POI a quest is anchored to.
  *Anchors:* `src/server/game.zig:1455`, `src/world/prefabs.zig:66`

- **Sleeper volume parse** `WORKS`
  Parses the '#'-separated volume list and both `SleeperVolumeGroup` forms with
  the `Vector3i.one` fallback for a missing Size segment. Verified against the real
  `abandoned_house_01.xml` in a unit test.
  *Anchors:* `src/world/sleepers.zig:246`, `:320`, `asm.il:2498294`

- **Sleeper volume world placement** `PARTIAL`
  Corners are rotated with the same inverted `rotateLocalXZ`, so for rot 1/3 the
  volumes sit in the mirrored half of the building relative to stock. They stay
  consistent with the stamped POI, so a player still triggers them in the
  corresponding room, but they are not the rooms TFP marked.
  *Anchors:* `src/world/sleepers.zig:154`, `:336`

- **Authored sleeper spawn points** `PARTIAL`
  Scans the `.tts` type plane, resolves each id through the prefab's
  `.blocks.nim` and accepts names starting `"sleeper"`. Stock's test is
  `Block.IsSleeperBlock`, set by `BlockSleeper`'s ctor; resolving `Class=Sleeper`
  through Extends gives 34 blocks, 16 of them named `infestedSleeper*`, which the
  case-sensitive prefix misses. Across the shipped `.blocks.nim` files, 886 of
  1105 POIs contain `sleeper*` markers and 338 contain `infestedSleeper*`, so
  about a third of POIs lose part of their authored spawn set.
  *Anchors:* `src/world/sleepers.zig:306`, `:314`, `asm.il:133430-133460`,
  `asm.il:923100-923213`

- **Sleeper volume coverage across the map** `PARTIAL`
  The volume store is built from at most ~1200 prefab refs (pass 1 unbounded
  within 512 m of spawn, pass 2 breaks at 1200) out of 1487 full POIs. A few
  hundred POIs, all far from spawn, contain no sleepers at all.
  *Anchors:* `src/server/game.zig:1003`, `:1039`, `src/world/sleepers.zig:9`

- **Sleeper wake / trigger** `PARTIAL`
  Pure player-inside-AABB test, one-shot (`volume.triggered` latches forever).
  Missing: the `SleeperVolumeTriggeredBy` cascade, sight/sound/light triggers,
  priority volumes, boss/loot/quest-exclude flags, spawn pose (the marker block
  name encodes Sit/Back/SideLeft/Stomach/Idle and is discarded), gamestage-scaled
  counts, spawnMode, respawnMap/respawnTime. The count is `min + (vi % span)`, not
  a roll.
  *Anchors:* `src/server/game.zig:6995`, `:7030`, `src/world/sleepers.zig:26`

- **Prefab TE scan as a container source** `PARTIAL`
  Runs after the block scan, capped at 48 per chunk, and only lets through TE
  types passing the wrong-numbered filter. Against real prefab data only Composite
  (25) TEs produce containers, matched via zdtd's misnamed `light` constant; Light
  and Sleeper are correctly ignored but for the wrong reason. Containers created
  this way now fill from the block's LootList, but the TE-type filter itself is
  still off.
  *Anchors:* `src/server/game.zig:7413`, `:7439`, `src/wire/te_types.zig:19`

- **POI block data path into chunks** `WORKS`
  Verified end to end on a live stock client. The client log shows chunk (-17,28)
  meshed and displayed and `poi hb centre(-241,471) ... columnsAboveGround=13/49`;
  its per-y ids are exactly the `.tts` cells of abandoned_house_07 at zdtd's
  rotated local column, so the paint reaches the client cell for cell. Applies to
  the heightmap terrain source only.
  *Anchors:* `src/world/store.zig:589`, `src/world/prefabs.zig:222`, `:404`,
  `output_log_client_zdtd_connect.txt:20533`

- **Trader areas / teleport volumes from prefabs.xml** `MISSING`
  Nothing reads TraderArea, TraderAreaProtect or TeleportVolumeList. Trader
  compounds are ordinary POIs with no protected area and no teleport volumes.
  *Anchors:* `src/assets/traders.zig:1`, `asm.il:902420-902440`,
  `asm.il:903590-903616`

- **Prefab entity list** `MISSING`
  The `.tts` entity block only exists for file versions 4..11 and V3 prefabs are
  v19, so nothing is lost from the file itself, but zdtd also has no equivalent of
  `CopyEntitiesIntoWorld`. Not player-visible on stock Navezgane data.
  *Anchors:* `src/world/tts.zig:9`, `asm.il:925420-925478`

- **Prefab terrainFiller / terrainFillerAdaptive handling** `PARTIAL`
  Both filler types are skipped so existing terrain shows through, which is the
  right first-order behaviour, but stock resolves them through
  `InitTerrainFillers` and `CopyIntoLocal`, so adaptive fillers that should take
  the surrounding terrain material leave gaps at POI edges instead.
  *Anchors:* `src/world/tts.zig:351`, `asm.il:915200-915221`

---

## 8. Entities and AI

**Headline.** A player joining zdtd today sees real zombies spawn, chase around
walls with A*, chew cover, die and drop loot, and POI sleepers wake on entry (all
six of those are PASS in the 83-case real-client playtest), but the population
behind them is a thin approximation: one hardcoded pair of entity groups for the
whole map, five zombie classes, one animal species (a stag that hunts you), no
gamestage, no wandering hordes, and no screamers.

**15 WORKS · 21 PARTIAL · 13 MISSING**

- **AIDirector world clock, day/night, blood-moon night detection** `WORKS`
  `WorldClock.tick` advances from DayNightLength; `isNight` uses dawn 04:00 plus
  DayLightLength; `isBloodMoonNight` honours frequency and range with deterministic
  jitter and probes neighbouring cycles so a jittered day is not missed.
  *Anchors:* `src/ecs/aidirector.zig:6-68`, `:41-61`,
  `src/server/game.zig:8101-8110`

- **Blood-moon music trigger** `WORKS`
  Single global bool broadcast on the `bloodmoon_active` edge. Live playtest case
  `combat/blood_moon_music` PASS. Stock sends it per-player; the global broadcast
  is the documented simplification.
  *Anchors:* `src/server/game.zig:8116-8121`, `src/wire/packages.zig:892-896`,
  `junit-1784959913.xml`

- **Zombie speed bands** `WORKS`
  Recomputed every tick from day/night/feral/blood-moon state; index 0..4 maps to
  0.5/0.75/1.0/1.4/1.7. Parsed from serverconfig.
  *Anchors:* `src/ecs/aidirector.zig:120-136`, `:149`, `src/server/config.zig:234`

- **MaxSpawnedZombies / MaxSpawnedAnimals caps** `WORKS`
  Both reach the director and gate spawning. Global cap only; stock also enforces
  a per-`ChunkAreaBiomeSpawnData` maxcount, which zdtd does not.
  *Anchors:* `src/server/game.zig:581-582`, `src/ecs/aidirector.zig:150-157`,
  `:173-178`

- **GameDifficulty HP scaling** `PARTIAL`
  `hpScale()` multiplies spawn HP by 0.5..2.0 and blood moon adds 1.5x. Stock
  scales incoming and outgoing **damage** via `GameStageDefinition::DifficultyBonus`
  and buffs, not max HP, so numbers differ even though the felt difficulty moves
  the right way.
  *Anchors:* `src/ecs/aidirector.zig:109-118`, `:266-267`, `asm.il:220834`

- **spawning.xml parsing** `PARTIAL`
  Parses biome name, entitygroup, maxcount, time, type and respawndelay. Never
  parses the stock `tags` / `notags` POI-type attributes. `maxcount` and
  `respawn_days` are stored on `Rule` and read by nothing in the whole tree. Live:
  `spawning rules=57`.
  *Anchors:* `src/assets/spawning.zig:14-22`, `:104-127`,
  `Data/Config/spawning.xml:22-33`

- **Biome-aware spawn group selection at runtime** `MISSING`
  The director's night/day/animal group names are resolved **once** at world load
  by scanning a hardcoded biome-name list and taking the first match. The live log
  proves the result: `director groups night=ZombiesNight day=ZombiesAll
  animal=WildGameForest`, i.e. pine_forest's rules. A player standing in the
  wasteland at midnight gets forest walkers. Stock resolves per
  `ChunkAreaBiomeSpawnData` from the actual biome under the chunk.
  *Anchors:* `src/server/game.zig:871-900`, `server-orch.log`, `asm.il:1093888`

- **POI-tag spawn filtering** `MISSING`
  Stock ORs every `PrefabInstance.Prefab.Tags` over the chunk area into a
  `FastTags<TagGroup/Poi>` and tests each group's `POITags` / `noPOITags` before
  enabling it. zdtd parses neither attribute, so downtown never produces the
  denser downtown groups and open forest gets the same table as a city block.
  *Anchors:* `asm.il:1094100-1094300`, `src/assets/spawning.zig:104-127`

- **Chunk-area spawn ledger** `MISSING`
  Stock keeps per-group counts, DecMaxCount/IncCount, a 32-group enabled bitmask,
  a respawn clock and `OnEntityUnloaded` to give the slot back. zdtd has one global
  alive counter and fixed cooldowns (45 s night horde, 120 s scout, 60 s animals),
  so density does not track where the player has already cleared.
  *Anchors:* `asm.il:1093735-1093863`, `asm.il:1094380-1094470`,
  `src/ecs/aidirector.zig:159-178`

- **entitygroups.xml weighted group table** `PARTIAL`
  Parses `<entitygroup>` / `<e n= p=>` and picks deterministically in integer
  milli-weights, but `max_groups` is 512 and stock ships 1892. The live server logs
  `entitygroups n=512`: 1380 groups are silently dropped at the parse cap.
  Everything past name #512 (`sleeperHordeStageGS623`) is gone, which is most of
  the gamestage-keyed horde/sleeper/scout lists.
  *Anchors:* `src/assets/entitygroups.zig:7`, `:112`, `server-orch.log`

- **Entity class variety actually reachable at spawn** `PARTIAL`
  `class_table` is 16 fixed slots; the loader fills exactly 5 zombie slots plus one
  animal. `spawnNearPlayers` picks a class name from the group then scans
  `class_table` for a name match, and any pick outside those 5 names silently falls
  back to `zombieBoe`. 293 entityclasses load; at most 6 can ever spawn.
  *Anchors:* `src/ecs/world.zig:171-180`, `src/server/game.zig:794-813`,
  `src/ecs/aidirector.zig:246-265`

- **Per-class movement speed and attack damage on spawned zombies** `PARTIAL`
  `spawnZombieClass` overrides only `class_id.hash` and `loot_list`;
  `class_id.id` stays 1. The AI reads speed and attack damage from
  `class_table[class_id.id]`, so a spawned zombieSpider or zombieFeral walks and
  hits exactly like zombieBoe. Only `max_hp` differs.
  *Anchors:* `src/ecs/world.zig:467-474`, `src/ecs/systems.zig:951-954`, `:1285`

- **Gamestage** `PARTIAL` (2026-08-06)
  `gamestages.xml` is not parsed anywhere (only in the xml_patch name table).
  Stock resolves SleeperVolumeGroup, horde and quest spawn names through
  `GameStageDefinition::GetGameStage(name)` to `GetStage(PartyGameStage)` to
  `SpawnGroup.groupName` to `EntityGroups::GetRandomFromGroup`. zdtd short-circuits
  to a fixed class and says so in a comment. Day 1 and day 70 spawn identical
  enemies at identical counts.
  *Anchors:* `src/assets/xml_patch.zig:99`, `src/server/game.zig:7044`,
  `asm.il:955240-955270`, `asm.il:416434`

- **POI sleeper volumes: parse, trigger, spawn at authored markers** `PARTIAL`
  3124 volumes load from stock Navezgane prefabs; volumes are AABB-tested in
  parallel then spawned serially at authored marker cells. `combat/sleeper_wake`
  PASS on the real client. Gaps: only `vol.groups[0]` is used, `triggered` is
  one-shot and never persists or re-arms, no `TriggeredByIndices` cascade, no
  sleeper pose, no `is_sleeper_passive`, no gamestage count scaling.
  *Anchors:* `src/server/game.zig:6995-7074`, `src/world/sleepers.zig:246-380`,
  `asm.il:197877`, `server-orch.log`

- **Sleeper group name to entity class resolution** `PARTIAL`
  `resolveSleeperClass` tries entityclasses byName, then entitygroups.pick, then
  `defaultZombie()`. The dominant stock value is `GroupGenericZombie` (4781
  occurrences across Data/Prefabs/POIs), which is **not** an entitygroup: it is a
  `gamestages.xml` `<group name="1GroupGenericZombie" spawner="SleeperGSList"/>`
  indirection. With gamestages unparsed, every such volume falls through to
  zombieBoe. Only volumes naming a class directly (~1000 occurrences) get the right
  model.
  *Anchors:* `src/server/game.zig:7076-7086`, `Data/Config/gamestages.xml:153`,
  `Data/Prefabs/POIs/*.xml`

- **Sleeper wake condition** `PARTIAL`
  Two independent mechanisms: an AABB test to spawn the group, then a per-entity
  20 m circle to flip `.sleep` to `.chase`. Stock uses SleeperNoiseToSense /
  NoiseToWake / SightToWakeMin-Max light thresholds and MaxViewAngle, so crouching,
  darkness and silence do nothing: walking within 20 m always wakes everything.
  *Anchors:* `src/ecs/systems.zig:903-921`, `src/ecs/world.zig:523-531`,
  `Data/Config/entityclasses.xml:697-702`

- **EAITaskList priority + MutexBits selection loop** `WORKS`
  Faithful port of `OnUpdateTasks` (stop-if-not-best, then priority-ascending
  CanExecute scan, then Update), with `isBestTask` reproducing
  `areTasksCompatible` and Reset hooks seeding lookTime at the two stock sites.
  `executeDelayScale` pinned at the 0.85 base.
  *Anchors:* `src/ecs/systems.zig:732-750`, `:797-806`, `:956-1007`,
  `asm.il:437713`, `asm.il:437874`

- **EAI task coverage: 8 of 15 stock task classes** `PARTIAL`
  Implemented: BreakBlock, DestroyArea, RunawayWhenHurt, ApproachAndAttackTarget,
  Territorial, ApproachSpot, Look, Wander. Absent: ApproachDistraction (which is in
  zombieTemplateMale's stock list), Leap, RunawayFromEntity, Dodge,
  RangedAttackTarget, MeleeAttackTarget, ItemTask, the three Drone tasks, PathTest.
  No spitters, no leaping, no chasing a thrown distraction, no animal fleeing a
  wolf.
  *Anchors:* `src/ecs/systems.zig:732-750`,
  `Data/Config/entityclasses.xml:562-571`, `asm.il` EAI* class list

- **Per-class AITask/AITarget lists from entityclasses.xml** `MISSING`
  `assets/entities.zig` parses MaxHealth, Tags, UserSpawnType,
  LootDropEntityClass, MoveSpeed, MoveSpeedAggro and HandItem, and nothing else.
  The AITask / AITarget property strings are never read; the task table is one
  comptime array shared by every entity. Also unparsed: AIFeralSense,
  AINoiseSeekDist, AIPathCostScale, SightRange, MaxViewAngle, MaxTurnSpeed,
  TimeStayAfterDeath.
  *Anchors:* `src/assets/entities.zig:230-272`, `src/ecs/systems.zig:731-750`,
  `asm.il:430620`

- **Timid animals run the zombie task table** `PARTIAL`
  `spawnAnimal` sets `mask.zombie_ai` and the AI loop has no kind gate;
  `canExecute` dispatches `.approach_attack` to `approachCanExecute`, which only
  tests "a player is within 48 m". Only `.runaway` is kind-gated. Stock
  `animalTemplateTimid` is RunawayWhenHurt, RunawayFromEntity, Look, Wander with no
  attack task at all. An unprovoked stag sprints at you and melees.
  *Anchors:* `src/ecs/world.zig:509-521`, `src/ecs/systems.zig:815-818`,
  `:1019-1031`, `:1140-1144`, `Data/Config/entityclasses.xml:4754-4757`

- **Target sensing** `PARTIAL`
  Only `EAISetAsTargetIfHurt` is modelled, as a revenge-target override on top of
  `nearestPlayerSnap` with a 20 s window. Missing: SetNearestEntityAsTarget with
  its per-class hear/see distances, BlockingTargetTask, SetNearestCorpseAsTarget,
  BlockIf. Sense is a flat 48 m XZ radius with no line of sight, no MaxViewAngle
  and no light/stealth multipliers; stock zombieTemplateMale SightRange is 30 m
  with LOS and a 180 degree cone, so zdtd zombies notice you 60% further away and
  through walls.
  *Anchors:* `src/ecs/systems.zig:78-140`, `:18`,
  `Data/Config/entityclasses.xml:678-679`, `asm.il:430171`

- **Grid A* pathfinding** `WORKS`
  4-neighbour A* with Manhattan heuristic, binary min-heap open set, lazy stale
  rejection, deterministic equal-f ties, node and expansion caps, greedy fallback
  when unreachable, and a reconstruct that never emits a step the predicate
  refused (proved by a 200-seed sweep plus a fuzz target). Waypoints buffered 8
  deep.
  *Anchors:* `src/ecs/path.zig:239-335`, `:454-497`,
  `src/ecs/components.zig:81-128`

- **A* move predicate against real terrain** `WORKS`
  `pathStepAt` resolves through `world.standableWorld` (step-up, drop, headroom)
  with a lock-free terrain snapshot fast path, returning the destination feet Y
  rather than a bool, which is what makes POI floors under roofs distinguishable.
  *Anchors:* `src/server/game.zig:1319-1330`, `src/ecs/systems.zig:1298-1313`,
  `:1372-1387`

- **A* tick budget / replan throttle** `WORKS`
  0.35 s replan interval plus a slot-strided per-tick admission derived once on
  the main thread so the answer is worker-independent. Over-budget bodies keep
  walking the stored buffer. Counters surface on TickResult.
  *Anchors:* `src/ecs/world.zig:360-366`, `src/ecs/systems.zig:1345-1371`,
  `src/ecs/schedule.zig:30-35`

- **Pathfinding fidelity vs stock navmesh** `PARTIAL`
  Nodes are keyed on (x,z) only, so a column reachable at two heights collapses to
  whichever the search reached first. 4-neighbour only, 96 expansions and 256 nodes
  per solve, max 32-step path, Manhattan cost with no `AIPathCostScale`. No path
  smoothing, no door opening, no jump/vault/ladder. Zombies take blocky
  right-angle routes and give up past ~24 blocks of detour.
  *Anchors:* `src/ecs/path.zig:1-8`, `src/ecs/systems.zig:28-37`,
  `Data/Config/entityclasses.xml:559`

- **Wander does not path and freezes Y** `PARTIAL`
  `wanderUpdate` calls `stepToward`, which only writes transform.x/z/yaw: it never
  touches `.y` and never consults the step predicate. A wandering zombie on a
  hillside keeps its spawn height and walks straight through walls.
  *Anchors:* `src/ecs/systems.zig:1416-1426`, `:142-151`, `:1372-1382`

- **BreakBlock / DestroyArea block chewing** `WORKS`
  When a replan cannot reach the goal, `path_blocked` latches and the mutex-0 tasks
  hold the chase projection; block damage at 2 Hz applies base 10 scaled by
  BlockDamageAI/AIBM, respects MaxDamage, and broadcasts on break. Replan clears
  the latch when a detour opens.
  *Anchors:* `src/ecs/systems.zig:1072-1128`, `src/server/game.zig:3096-3134`,
  `src/ecs/systems.zig:1337-1339`

- **Daytime wildlife spawner** `PARTIAL`
  One animal per 60 s during daylight up to the cap. The class lookup scans
  `class_table` for `kind==.animal` and only slot 7 is ever an animal, filled with
  `defaultAnimal() = animalStag`. Every animal in the world is a stag regardless of
  the WildGameForest pick. No rabbits, chickens, does, boars.
  *Anchors:* `src/ecs/aidirector.zig:188-231`, `src/server/game.zig:763-773`,
  `src/assets/entities.zig:74-80`

- **Enemy animals (wolf, bear, dire wolf, mountain lion, snake, coyote)** `MISSING`
  `spawning.xml` carries EnemyAnimalsForest / DesertNight / Snow rules and the
  parser records them, but the director only ever consumes the **first**
  animal-kind rule it finds and can only instantiate slot 7. No hostile wildlife
  exists in a zdtd world.
  *Anchors:* `src/server/game.zig:882`, `src/ecs/aidirector.zig:188-209`,
  `Data/Config/spawning.xml:31-33`

- **Vultures / flying entities** `MISSING`
  No flying entity kind, no vertical AI, no `EntityFlying` equivalent.
  *Anchors:* `src/ecs/components.zig:5-13`

- **Animals never despawn** `PARTIAL`
  `systemDespawnFar` copies only the `.zombie` kind group, so animals accumulate to
  MaxSpawnedAnimals (default 50) and stay alive forever, holding entity slots and
  `known_entities` bits. Zombies do despawn beyond 200 m.
  *Anchors:* `src/ecs/systems.zig:1707-1740`, `:1716`

- **Animal replication carries no movement state** `PARTIAL`
  `replicate()` sends EntitySpawn and PosAndRot for `.animal`, but the
  EntitySpeeds / EntityAliveFlags block is gated on `kind == .zombie`, so the
  client animates animals with movementState 0 while their transform slides.
  *Anchors:* `src/server/game.zig:8826`, `:8927-8952`

- **Night horde** `PARTIAL`
  Every 45 s of night, 2 zombies spawn 18-28 m from each player already flagged
  `.chase` with the player as target. Not a stock wandering horde and not a biome
  spawn: a direct aggro drip. Blood-moon nights shorten the cooldown to 8 s.
  *Anchors:* `src/ecs/aidirector.zig:159-162`, `:233-282`

- **Blood-moon waves** `PARTIAL`
  `max(1, BloodMoonEnemyCount/2)` zombies 12-22 m from each player every 6 s at
  1.5x HP. No party spawner, no per-party gsScaling, no maxAlive per group, no wave
  structure or lull. The only real limit is MaxSpawnedZombies.
  *Anchors:* `src/ecs/aidirector.zig:163-167`, `:96-97`, `asm.il:416385-416960`

- **Wandering hordes** `MISSING`
  No equivalent of `AIDirectorWanderingHordeComponent` / `AIWanderingHordeSpawner`:
  no scheduled group of 6 spawning at 92 m and walking a path across the map, no
  HordeNextTime scheduling, no horde path.
  *Anchors:* `asm.il:419473-419490`, `asm.il:416218`,
  `src/ecs/aidirector.zig:159-162`

- **Screamers and the activity heat map** `MISSING`
  No `AIDirectorChunkData` heat accumulation, no noise-to-heat feed, no scout spawn
  on threshold, no scream-summons-more loop. The daytime "scout" is a single
  ordinary zombie every 120 s. Forges, generators and gunfire have zero
  consequence.
  *Anchors:* `src/ecs/aidirector.zig:168-171`, `asm.il:414504-415200`,
  `asm.il:416218`

- **NetPackageHordeEvent** `MISSING`
  `buildHordeEventBody` with the None/Warn1/Warn2/Spawn enum exists and is unit
  tested, but there are zero send sites, so `HandleHordeEvent` never fires on the
  client and there is no approaching-horde warning.
  *Anchors:* `src/wire/packages.zig:912-942`, `src/server/game.zig` (no call site)

- **AIDirector / sleeper state persistence across restart** `MISSING`
  `saveAll` persists chunks, containers, block meta and players. No entity,
  director or sleeper-trigger state is written, so a restart resets director
  cooldowns, drops every live mob, and re-arms every already-cleared sleeper
  volume.
  *Anchors:* `src/server/game.zig:8131-8147`, `:1751`

- **Entity spawn replication (EntityCreationData v36)** `WORKS`
  Correct zombie/animal empty middle branch, sleeper flag and stressAmount tail.
  Sent on join (capped at 16) and on approach per observer via `known_entities`.
  `combat/zombie_or_npc_nearby` and `combat/zombie_target_has_health` PASS.
  *Anchors:* `src/wire/stock_entity.zig:161-273`, `src/server/game.zig:6466-6505`,
  `:7841-7869`

- **Motion replication (PosAndRot / EntitySpeeds / EntityAliveFlags)** `WORKS`
  Serialize-once fan-out on a 2-tick motion period with a 5-tick heartbeat and
  cell-based interest. Zombies get EntitySpeeds matching
  `NetPackageEntitySpeeds::write` and AliveFlags driven by AiState.
  `combat/alive_flags_self` PASS.
  *Anchors:* `src/server/game.zig:7885-7939`, `src/ecs/interest.zig:11-45`,
  `asm.il:818303-818382`

- **Entity removal on death / despawn** `WORKS`
  Broadcast on player kill, turret kill, admin kill and far-despawn, and the killer
  gets quest credit, XP and a DroppedLootContainer. `combat/zombie_death_loot` and
  `economy/zombie_removed_after_kill` PASS.
  *Anchors:* `src/server/game.zig:4936-4970`, `:8076-8098`,
  `src/wire/packages.zig:861-876`

- **EntityRemove(Unloaded) when a mob leaves interest range** `WORKS`
  The replicate pass runs an unload sweep next to spawn-on-approach: any mob a
  client knows but whose cell is outside that client's `view_radius` box gets
  `NetPackageEntityRemove(entityId, Unloaded)` on the reliable channel, and the
  `known_entities` bit clears only once the send succeeded, so a failed send
  retries instead of leaving a ghost. Stock does the same per player in
  `NetEntityDistributionEntry::updatePlayerEntity`. An observer whose own entity
  slot cannot be resolved is skipped rather than treated as sitting in cell (0,0),
  which would evict its whole known set.
  *Anchors:* `src/server/game.zig:8871-8891`, `src/wire/packages.zig:861-880`,
  `asm.il:801228-801276`, `asm.il:1227761`

- **Corpse dwell time (TimeStayAfterDeath)** `MISSING`
  zdtd broadcasts EntityRemove the instant HP hits 0. Stock
  `EntityAlive::OnDeathUpdate` counts up to TimeStayAfterDeath (30 for
  zombieTemplateMale, 300 for animals) before unloading, with DeadBodyHitPoints
  governing corpse destruction. Bodies pop out of existence mid animation and
  cannot be harvested.
  *Anchors:* `asm.il:450657-450759`, `Data/Config/entityclasses.xml:692-693`,
  `src/server/game.zig:4945-4947`

- **Zombie health replication to clients** `MISSING`
  EntityStatChanged is only sent for player vitals. Zombie HP lives server-side and
  the client's local copy stays at the class default until EntityRemove arrives.
  Acceptable for the current damage model but there is no server-to-client health
  correction.
  *Anchors:* `src/server/game.zig:6507-6543`, `:4936-4947`

- **Animation / ragdoll / look-at replication for AI** `MISSING`
  EntityAnimationData is accepted from clients and dropped; EntityRagdoll,
  EntityLookAt, EntityStealth and EntityRotation are never sent for server-driven
  mobs. Head aim is explicitly out of scope.
  *Anchors:* `src/server/game.zig:4036-4038`, `src/ecs/systems.zig:1247-1263`

- **Spawn placement validity** `PARTIAL`
  x,z come from a handful of deterministic bearings and y straight from the
  player's transform. No ground snap, no standable check, no "nothing already
  inside a 4 x 2.5 x 4 box" test (stock does exactly that via
  `World.GetEntitiesInBounds`), and no out-of-view constraint. Zombies materialise
  embedded in hillsides or floating, always on the same few bearings.
  *Anchors:* `src/ecs/aidirector.zig:240-245`, `:214-218`,
  `asm.il:1094396-1094440`

- **Quest-driven enemy spawn** `PARTIAL`
  The handler reads and discards the groupName and spawns up to 8 copies of
  `defaultZombie()` on a 6 m ring. Stock resolves the group through the gamestage
  spawner. Quest ambushes are always generic walkers at the wrong count.
  *Anchors:* `src/server/game.zig:4836-4851`, `asm.il:955240-955275`

- **Admin / console entity spawn and kill** `WORKS`
  `spawnentity` resolves a class name through `entities.byName` and chooses
  spawnAnimal vs spawnZombieClass by kind; admin kill applies lethal damage,
  broadcasts, credits quests and spawns the bag; `killall` sweeps zombies.
  *Anchors:* `src/server/game.zig:2342-2345`, `:2853-2895`, `:2636-2657`

- **Parallel AI execution and LOD** `WORKS`
  `systemZombieAi` runs over disjoint slot ranges above 64 live entities, damage is
  accumulated as atomic fixed-point and applied serially, and `lodScale` throttles
  `decision_cd` by distance with a documented ultra-far branch that skips task
  selection entirely.
  *Anchors:* `src/ecs/systems.zig:1428-1449`, `:929-945`, `:42-46`

---

## 9. Items, crafting and loot

**Headline.** A player can open zdtd chests and see items, and a workstation TE
round-trips, but loot content is wrong at the source, crafting is instant and
unvalidated, and durability, mods and repair do not exist.

**10 WORKS · 15 PARTIAL · 10 MISSING**

- **items.xml load: names plus stock ItemValue.type assignment** `WORKS`
  1413 unique `<item name=>` parsed in document order, first type =
  ItemsStartHere+1 = 65537, exported via NameIdMapping. Test asserts
  `meleeToolRepairT0StoneAxe == 65537` against the real file.
  *Anchors:* `src/assets/items.zig:371-534`, `:11-14`, `:239-248`

- **items.xml Stacknumber to server max stack** `WORKS`
  Absent `Stacknumber` defaults to stock's 0x1f4 = 500 (asm.il:749089) and
  resolves through the Extends chain (two-pass, children-before-parents safe,
  up to 24 hops). The "bag slot waste" playtest residual is closed: most
  classes now stack like stock.
  *Anchors:* `src/assets/items.zig:424-430` + resolve pass, `:112-117`,
  `asm.il:749074-749091`

- **items.xml Extends inheritance** `PARTIAL`
  `loadFromPath` resolves `Stacknumber` through Extends; DamageEntity,
  FuelValue and the eat cvars are still read direct-only, so inherited values
  for those properties are lost (melee damage and fuel for templated items).
  1144 of 1413 stock items use Extends.
  *Anchors:* `src/assets/items.zig:408-463`, `Data/Config/items.xml`

- **EconomicValue, DamageEntity, FuelValue, ItemActionEat cvars** `WORKS`
  Parsed per item and surfaced through ItemDef: econ drives trader price,
  entity_damage drives melee, fuel_value drives generator refuel, food/water/health
  cvars drive the eat path.
  *Anchors:* `src/assets/items.zig:428-456`, `:119-183`,
  `src/server/game.zig:1353-1401`

- **ItemValue v9 wire encode/decode** `WORKS`
  Encoder and decoder both follow the stock v9 ReadData shape including the
  ItemsStartHere flag bit, typed metadata skip, stats block and the v>8 texture
  bool plus i64.
  *Anchors:* `src/wire/stock_inv.zig:73-100`, `:497-571`

- **Item modifiers (mods) and cosmetics** `MISSING`
  Encode always writes `Modifications.Length = 0` and `CosmeticMods.Length = 0`;
  decode reads the nested mod ItemValues and throws them away. Anything the server
  authors is unmodded, and `item_modifiers.xml` is never parsed.
  *Anchors:* `src/wire/stock_inv.zig:93-95`, `:535-548`,
  `src/ecs/components.zig:296-301`

- **Item durability (ItemValue.UseTimes)** `MISSING`
  `StockSlot.use_times` exists on the wire but the ECS `InvSlot` has only quality
  and meta; nothing ever decrements or persists UseTimes. Tools never wear out and
  durability is dropped on save/restore.
  *Anchors:* `src/wire/stock_inv.zig:48`, `src/ecs/components.zig:299-300`,
  `src/server/game.zig:1910-1913`

- **Item quality tier** `PARTIAL`
  quality rides the wire, the TE and players.zsv, and stack merges refuse to blend
  different qualities. But nothing ever produces a quality other than 1: loot fill
  hardcodes it and `qualityinfo.xml` is only forwarded as a client config name.
  *Anchors:* `src/server/game.zig:7453`, `src/ecs/components.zig:363-395`,
  `:444-466`, `src/server/game.zig:5669`

- **Repair (item repair queue / RepairItem)** `MISSING`
  `RecipeQueueItem` carries a RepairItem ItemValue plus u16 in stock; zdtd always
  writes `hasRepair = false` and discards it on read. There is no item-repair path
  anywhere in `src/`. Stock computes repair craftingTime from
  `ItemClass.RepairTime` and pushes it through the same crafting queue.
  *Anchors:* `src/wire/stock_te.zig:389`, `:532-536`,
  `src/server/game.zig:4679-4683`, `asm.il:1413451-1413530`

- **Block upgrade path (hammer upgrade)** `MISSING`
  `blocks.xml` UpgradeBlock is never read; `maxdamage.zig` reads only MaxDamage,
  LootList presence and CompositeTileEntity. Hitting a wood frame with a hammer
  changes nothing server-side.
  *Anchors:* `src/assets/maxdamage.zig:393-394`, `src/server/game.zig:6670-6680`

- **recipes.xml load** `PARTIAL`
  630 recipes with up to 5 ingredients parse fine. Missing: tags (631 uses),
  craft_tool (53), material_based (34), use_ingredient_modifier (6),
  learn_exp_gain, craft_exp_gain (17). `craft_area` is parsed into RecipeDef and
  has zero consumers, so a workbench-only recipe can be crafted anywhere. Default
  craft_time is 1.0 where stock leaves `Recipe::craftingTime = -1` (a sentinel) for
  the 506 recipes with no attribute.
  *Anchors:* `src/assets/recipes.zig:151-186`, `:21`, `:161-163`,
  `asm.il:1392695-1392710`

- **Server craft execution** `PARTIAL`
  `tryCraftRecipe` aggregates ingredients, snapshots the bag, consumes, deposits
  and rolls back on failure. But it is instantaneous (craft_time never applied),
  ignores craft_area and craft_tool, and does not check the recipe is unlocked. The
  33 zero-ingredient material_based scrap recipes survive the loader, so crafting
  through this path mints items from nothing.
  *Anchors:* `src/server/game.zig:6688-6752`, `src/assets/recipes.zig:181-184`

- **NetPackageInventoryTransactionRequest / Response wire format** `PARTIAL`
  zdtd reuses the stock package **name** with a homegrown 11-byte body
  (`op u8 | a u16 | b u16 | qty u16 | entity i32`), documented as a deliberate
  deviation. Stock `read()` is `InventoryTransaction::Read`: i32 opCount then per
  inventory Guid key, i32 InitialHash, i32 FinalHash, i32 opCount, and
  `InventoryOperation.Write` per op. Stock Response is bool, i32 count, then
  (Guid, bool, ItemStack[])*. A genuine stock transaction packet would be misparsed
  as `op = low byte of the i32 count` (typically 1 = move) with Guid bytes as slot
  indices, and zdtd's response is not decodable by the stock client. Crafting via
  op 11 is unreachable from a legitimate client but trivially forgeable.
  *Anchors:* `src/wire/packages.zig:1639-1668`, `src/server/game.zig:4459-4534`,
  `docs/INVENTORY.md:74-75`, `asm.il:823033-823059`, `asm.il:614000-614087`,
  `asm.il:612874-612917`

- **Unlocked recipe list on join** `PARTIAL`
  Only `always_unlocked` recipes (41 in stock) plus two hard-seeded demo names are
  sent, capped at 64. There is no progression or magazine-driven unlock: a player
  never learns a new recipe from the server across sessions.
  *Anchors:* `src/assets/recipes.zig:53-86`, `src/server/game.zig:6089-6091`,
  `src/wire/packages.zig:491`

- **Workstation TE (type 12) C2S parse and S2C echo** `WORKS`
  Full stock body: fuel/input/tools/output arrays at the client's declared lengths,
  RecipeQueueItem v2 with verbatim Recipe blob passthrough, CraftCompleteData v1
  list, isBurning/burnTimeLeft, melt array, isPlayerPlaced, lastTickTime delta and
  trailing lastInput. The parser rejects a payload it cannot drain exactly; the
  echo re-emits the client's array lengths so its grids are not resized. Scenario
  test drives C2S, tick, S2C, acknowledge.
  *Anchors:* `src/wire/stock_te.zig:411-453`, `:566+`,
  `src/server/game.zig:4364-4412`, `src/server/scenarios.zig:1449-1570`

- **Workstation craft tick** `WORKS`
  Mirrors stock `HandleRecipeQueue` orientation (active entry is the last slot),
  stalls instead of dropping when the output array is full, carries the time
  overrun through `cycleRecipeQueue`, and keeps a bounded craft-complete list
  drained by client acknowledgement. Ticks at 2 Hz.
  *Anchors:* `src/world/workstations.zig:220-337`, `src/server/game.zig:6824-6864`,
  `:8056-8060`

- **Workstation fuel burn rate** `PARTIAL`
  `handleFuel` consumes one fuel item per 10.0 s flat. Stock
  `TileEntityWorkstation::GetFuelTime` returns `ItemClass::GetFuelValue`, i.e. the
  items.xml FuelValue: `resourceCoal` = 100, most wood and oil shale 1-5. zdtd
  already parses FuelValue into ItemDef and simply does not use it here, so coal
  burns 10x too short and wood 10x too long.
  *Anchors:* `src/world/workstations.zig:196-215`, `src/assets/items.zig:119-125`,
  `asm.il:1332283-1332301`, `asm.il:1331999`

- **Workstation input consumption and forge melt simulation** `MISSING`
  `handleRecipeQueue` never touches the input array and never advances the melt
  timers; melt values and lastInput ride through as opaque client bytes. The forge
  does not smelt on the server.
  *Anchors:* `src/world/workstations.zig:220-253`, `:158-164`,
  `docs/WIRE_WORKSTATION.md:171-173`

- **Workstation recipe validation against recipes.xml** `MISSING`
  The queued Recipe's output type, count, craft time and exp gain are taken from
  the client blob verbatim; nothing cross-checks recipes.xml. A modified client can
  queue any output at any rate.
  *Anchors:* `src/wire/stock_te.zig:509-523`, `src/world/workstations.zig:257-269`,
  `docs/WIRE_WORKSTATION.md:167-169`

- **Non-fuel workstations (workbench, chemistry station)** `PARTIAL`
  `handleRecipeQueue` returns immediately when `is_burning` is false, and
  `isModuleUsed` is not on the wire, so a workbench never advances a craft
  server-side.
  *Anchors:* `src/world/workstations.zig:221-222`,
  `docs/WIRE_WORKSTATION.md:170-171`

- **Workstation persistence and capacity** `MISSING`
  `WorkstationStore` has no save/load (unlike ContainerStore) and caps at 64
  stations world-wide with a linear position scan. A forge's fuel, input, output
  and queue are gone on restart, and the 65th placed workstation is silently
  dropped.
  *Anchors:* `src/world/workstations.zig:11`, `:369-400`,
  `src/world/containers.zig:129-235`

- **loot.xml parse** `PARTIAL`
  1010 groups and 339 containers parse. Not parsed: loot_prob_template (1528
  uses), force_prob (181), abundance_type, loot_quality_template (403), the
  loot_settings poi_tier_mod/bonus block, and requirement children. `count="all"`
  (360 uses) falls through parseU16 and becomes pick 1. `LootGroup.entries` caps at
  32, silently truncating 6 stock groups (perkBooks has 133 entries).
  `LootContainer.size_x/size_y` are parsed and never used.
  *Anchors:* `src/assets/loot.zig:243-352`, `:9`, `:281-285`, `:33-34`,
  `src/server/game.zig:7405`, `Data/Config/loot.xml:9656`

- **Loot roll probability model** `PARTIAL`
  `rollContainer` applies a milli-prob gate only to container-level entries at
  index > 0. `rollGroup` picks a uniform random index with no prob weighting at
  all, so within a group every item is equally likely. No lootstage, no gamestage,
  no biome/quest requirement filtering, no per-entry abundance_type.
  *Anchors:* `src/assets/loot.zig:92-125`, `:127-154`

- **LootAbundance server setting** `WORKS`
  Clamped 1..1000, scales every rolled stack count with a floor of 1; unit test
  asserts the 2x and 1% cases.
  *Anchors:* `src/server/config.zig:53`, `:237`, `src/server/game.zig:788`,
  `src/assets/loot.zig:52-57`, `:157-177`

- **Per-block loot list selection** `WORKS`
  `maxdamage` records each block's LootList value (resolved through the Extends
  chain, children-before-parents safe) and the container fill selects by block
  id, so a gun safe, a medicine cabinet, a cash register and a bird nest each
  yield their own table.
  *Anchors:* `src/assets/maxdamage.zig` `loot_list_by_name` / `lootListFor`,
  `Data/Config/blocks.xml`

- **Zombie / animal death loot bag contents** `WORKS`
  `entities.zig` resolves the stock chain at load: `LootDropEntityClass` names
  the bag **entity class** (`EntityLootContainerRegular`), whose own
  `LootList="zPackReg"` is the loot.xml container; comma-weighted forms take the
  first candidate. `LootDropProb` (.04 regular zombie) is parsed and gates the
  bag in `World.damage`, so most kills drop nothing and the rest roll real
  zPack tables instead of 5 scrap iron.
  *Anchors:* `src/assets/entities.zig` load, `src/ecs/world.zig` damage gate,
  `src/ecs/components.zig` `ClassId.drop_prob`,
  `Data/Config/entityclasses.xml:689`, `Data/Config/loot.xml:9928`
  *Anchors:* `src/assets/entities.zig:245-247`, `src/server/game.zig:6906-6924`,
  `src/assets/loot.zig:119-123`, `Data/Config/entityclasses.xml`,
  `Data/Config/loot.xml:9927`

- **Loot bag drop probability (LootDropProb)** `MISSING`
  `World.damage` unconditionally spawns a bag for every zombie and animal kill.
  Stock LootDropProb is .04 for a regular zombie (up to 1 for specials) and is
  never parsed. The field carpets in bags; the codebase already notes "loot floods
  the field" in the clear_ai path.
  *Anchors:* `src/ecs/world.zig:683-693`, `src/server/game.zig:2635-2662`,
  `Data/Config/entityclasses.xml`

- **Player death loot bag (DropOnDeath)** `PARTIAL`
  Modes 1..3 spawn a bag but `spawnLootBag(t.x, t.y, t.z, 1, 1)` puts a single unit
  of item 1 in it: the dead player's inventory is never transferred, and modes 2
  (toolbelt only) and 3 (backpack only) are not distinguished from mode 1.
  *Anchors:* `src/server/game.zig:4949-4959`, `src/ecs/world.zig:595-604`

- **Storage TileEntity S2C** `PARTIAL`
  Composite TE with one Storage feature is built and pushed on chunk stream and
  lock grant, matching `TEFeatureStorage.Write` field order. Two divergences: the
  lootListName bool is always written false, and the container grid is synthesized
  as 2xN (or 9x6 above 18 slots) from slot_count rather than from the loot.xml
  container size, so a stock 6x2 wooden chest renders as a 2x4 grid.
  *Anchors:* `src/wire/stock_te.zig:140-189`, `src/server/game.zig:7405`,
  `asm.il:156979`

- **Storage TileEntity C2S apply and broadcast** `WORKS`
  Parse, range check against the acting player, apply, broadcast. Slot quality and
  meta survive the round trip; containers persist to `containers.zct` sorted by
  world position.
  *Anchors:* `src/server/game.zig:4335-4360`, `src/wire/stock_te.zig:204-343`,
  `src/world/containers.zig:129-235`

- **NetPackageInventoryDataRequest / Response** `PARTIAL`
  Requests keyed by the deterministic pos Guid are answered with the container's
  ItemStacks. This is the front half of stock's
  `RequestInventoryFromServer` to `ReadInventory` to `TransactionRequestLocal`
  loop; the back half uses zdtd's incompatible transaction format, so a mutation
  made through this path cannot be applied.
  *Anchors:* `src/server/game.zig:4536-4587`, `src/world/containers.zig:48-58`,
  `asm.il:613064-613088`, `asm.il:613124-613223`

- **Loot respawn and destroy_on_close** `MISSING`
  `Container.touched` is stored and put on the wire, but nothing clears it on a
  timer and nothing acts on the loot.xml `destroy_on_close` attribute.
  LootRespawnDays is only echoed in the GamePrefs blob; looted containers stay
  empty forever.
  *Anchors:* `src/world/containers.zig:31-43`, `src/wire/packages.zig:1914`,
  `:2015`, `Data/Config/loot.xml`

- **Container capacity limits** `PARTIAL`
  256 containers world-wide with a linear scan per lookup, 54 slots each; the
  prefab TE scan stops after 32 block hits plus 48 TE-list hits per chunk. A dense
  POI silently exceeds these.
  *Anchors:* `src/world/containers.zig:7-11`, `src/server/game.zig:7409-7410`,
  `:7421`

- **Player inventory persistence of item state** `PARTIAL`
  players.zsv v2 stores item_id, count, quality and meta per slot into a 32-entry
  read buffer, while the ECS inventory is 47 slots against the stock wire layout of
  10 + 45 + 12. UseTimes, mods, cosmetics and seed are not stored at all. Slots
  beyond bag index 32 and equipment index 5 are dropped on the C2S apply.
  *Anchors:* `src/server/game.zig:1910-1913`, `:2094-2103`,
  `src/ecs/components.zig:200-220`, `src/wire/stock_inv.zig:627-681`

- **Scrapping (material_based recipes / CraftCompleteData.scrapped)** `MISSING`
  `Recipe.isScrap` is read and discarded; `CraftCompleteData.scrapped` is only ever
  echoed back. There is no server-side scrap-to-material logic, and the 34
  material_based recipes are treated as ordinary zero-ingredient recipes.
  *Anchors:* `src/wire/stock_te.zig:514`, `:559`,
  `src/world/workstations.zig:110-132`

---

## 10. Player progression

**Headline.** A player can join, eat, take client-reported damage, die by
admin/self-report and respawn. Level, XP, survival stats and active buffs now
survive a restart (players.zsv v3, server-side ledger). Still missing: no perk
runtime (client-owned spending, no server model), the client's
`NetPackagePlayerStats` blob is dropped so other players never see your level,
and server-to-client XP/level pushes do not exist.

**8 WORKS · 11 PARTIAL · 18 MISSING**

- **progression.xml `<level>` curve parse** `WORKS`
  Parsed on boot and logged. Live: `progression max_level=300 exp_to_level=10000
  attrs=8 perks=57`, matching `progression.xml:8`.
  *Anchors:* `src/assets/progression.zig:92-106`, `:123-130`,
  `src/server/game.zig:834-845`, `server-orch.log:14`

- **Server-side XP ledger and level-up loop** `PARTIAL`
  `awardXp` levels correctly against its own curve, but it is a write-only
  counter: the value lives on the per-peer `Client` struct (never on the ECS
  entity), is never sent to the client, never saved, and is zeroed by
  `clients[slot] = .{}` on any disconnect. The only award site is a zombie/animal
  kill via C2S DamageEntity, 100 XP flat.
  *Anchors:* `src/server/game.zig:3043-3062`, `:4960-4965`, `:290-293`

- **XP curve numeric parity with stock** `PARTIAL`
  zdtd's `expForLevel(L) = exp_to_level * mult^(min(L,clamp)-1)`. Stock's
  `GetExpForNextLevel()` is `BaseExpToLevel * ExpMultiplier^(Level+1)`. The
  exponent is off by 2, so every zdtd level costs a factor of 1.05^2 = 1.1025 less
  XP than stock (10000 vs 11025 for level 1 to 2). zdtd clamps at u32 max, stock at
  2.14748365e9.
  *Anchors:* `src/assets/progression.zig:21-30`, `asm.il:1083482`,
  `asm.il:1083513`, `asm.il:1088481`

- **XPMultiplier server option** `WORKS`
  Parsed, applied to awards, reported in the GameStats blob. Client log confirms
  `GameStat.XPMultiplier = 100` arrived.
  *Anchors:* `src/server/config.zig:238`, `src/server/game.zig:3048`, `:6232`,
  `output_log_client_zdtd_connect.txt:5236`

- **XP from non-kill sources** `MISSING`
  `awardXp` has exactly one call site. Turret kills grant quest credit but no XP.
  `quests.xml` carries `<reward type="Exp" value="500"/>` rows the quest catalog
  does not model. Mining, looting or finishing a quest earns nothing server-side.
  *Anchors:* `src/server/game.zig:4964`, `:8068-8074`, `src/ecs/quest.zig:56`,
  `Data/Config/quests.xml:103`

- **Skill points granted per level** `MISSING`
  `LevelCurve.skill_points_per_level` is parsed and stored but has no reader
  anywhere in `src/`. There is no skill-point balance on any struct or component,
  so a level-up produces nothing spendable.
  *Anchors:* `src/assets/progression.zig:16`, `:102`

- **Client to server XP sync (EntityAddExpServer, EntityAddScoreServer)** `MISSING`
  Both are matched and returned with a comment saying "No server-side skill sim
  yet". The stock server applies them to the remote player's Progression. zdtd
  discards the XP, so the server's ledger and the client's HUD level diverge
  permanently.
  *Anchors:* `src/server/game.zig:4794-4799`, `asm.il:813959`

- **Client to server progression blob (NetPackagePlayerStats)** `MISSING`
  Dropped with a one-line "accept, no sim" branch. The body is
  `EntityNetworkStats`, carrying experience, level, killedZombies, killedPlayers,
  totalItemsCrafted, currentLife/longestLife/totalTimePlayed and a hasProgression
  plus i16-length progressionsData blob. Stock calls `ToEntity` to write
  Level/ExpToNextLevel onto the server entity, then relays to the other clients.
  zdtd throws away exactly the data it would need to persist progression, and other
  players never see your level or stats.
  *Anchors:* `src/server/game.zig:4785-4788`, `asm.il:833182`, `asm.il:441294`,
  `asm.il:441670`

- **Server to client XP/level push (EntityAddExpClient, EntitySetSkillLevelClient)** `MISSING`
  Both names exist in the package table but are never built or sent, and there is
  no builder for either body. The server has no way to grant XP or force a skill
  level for an admin command or a quest reward.
  *Anchors:* `src/wire/packages.zig:158-159`, `:172-173`, `asm.il:813609`,
  `asm.il:813815`

- **progression.xml attribute and perk catalog load** `PARTIAL`
  Names and counts load (8 attributes, 57 live perks), but the catalog is thin and
  partly wrong. (a) `perk.parent_attr` is derived by walking back to the nearest
  `<attribute ` before the perk; every perk in stock sits after `</attributes>`,
  so all 57 resolve to `attCrafting` instead of their real `parent="skill*"`. (b)
  Per-attribute min_level/max_level/base_skill_point_cost overrides are ignored.
  (c) `<skill>` (16 rows), `<crafting_skill>` (23 rows), override_cost,
  level_requirements, effect_group, unlock_entry, display_entry, book and
  book_group are not parsed at all. (d) Nothing in `src/` reads perks or
  attributes: `perkByName` and `attrByName` have zero callers outside their own
  file, and the only consumer of the Table is a debug print of the counts.
  *Anchors:* `src/assets/progression.zig:166-188`, `:137-164`, `:68-80`,
  `src/server/game.zig:839-844`, `Data/Config/progression.xml:189`, `:193-214`,
  `:240`, `:875`, `:879`

- **Perk purchase / spend skill points** `MISSING`
  `EntitySetSkillLevelServer` is acked and discarded; `GameEventRequest` (the other
  route the client uses) is blanket-approved with `ResponseTypes.Approved` and no
  state change. There is no server-side per-player perk level table. A player can
  move the sliders, the server neither validates nor remembers it, and a relog
  wipes it.
  *Anchors:* `src/server/game.zig:4794-4799`, `:4815-4820`,
  `src/wire/packages.zig:2216-2235`

- **Perk / attribute passive effects applied to gameplay** `MISSING`
  `progression.xml` has 649 `<passive_effect>` rows under attributes and perks;
  none are parsed and none applied. The only mitigation the sim has is a flat 10%
  per equipped armour piece capped at 50%, unrelated to progression.
  *Anchors:* `src/ecs/inventory.zig:146-157`, `Data/Config/progression.xml`

- **Crafting skills / magazines / recipe unlock by progression** `MISSING`
  `progression.xml` has 99 `<unlock_entry>` rows gating recipes behind
  crafting_skill levels; zdtd parses none. The join PDF ships only
  `always_unlocked` names plus two hardcoded seeds added because the wooden club is
  perk-gated in stock. A player can never learn a new recipe by playing.
  *Anchors:* `src/assets/recipes.zig:52-88`, `src/server/game.zig:6090-6091`,
  `Data/Config/progression.xml:245`

- **Gamestage (level plus days survived driving spawn difficulty)** `MISSING`
  No gamestage anywhere. The spawn path explicitly comments "no gamestage scaling:
  zdtd has no gamestage, gsScale=1", and `gamestages.xml` is in the not-loaded
  list. Zombie difficulty never responds to player level.
  *Anchors:* `src/server/game.zig:7044`, `docs/GAP_ANALYSIS.md`

- **buffs.xml catalog and passive_effect parse** `PARTIAL`
  482 buff defs load (483 raw `<buff `, 482 after comment stripping, matching the
  live log). The parse is shallow: only the first value of a comma list is kept,
  `level="2,10"` ranges are ignored, `value="@$PlayerLevelBonus"` expression refs
  parse to 0, at most 16 passive_effects per buff are kept, and all 3373
  `<triggered_effect>` rows plus requirements and effect_groups are dropped.
  *Anchors:* `src/assets/buffs.zig:85-174`, `:80-83`, `:9`, `server-orch.log:13`,
  `Data/Config/buffs.xml`

- **Buff runtime: apply, tick, expire, stack** `WORKS` (2026-08-06)
  A buff component, per-entity buff list and a `systemBuffs` pass now run in the
  ECS with stack rules and 20 Hz timers, and buff changes reach the client over
  the stock wire. Open: the triggered_effect VM, cvar sync, immunity and
  damage-type gates, and persistence across sessions (see WORK_PLAN T5).
  *Anchors:* `src/ecs/components.zig:538-560`, `src/assets/buffs.zig:57-69`,
  `output_log_client_zdtd_connect.txt:21110`, `:27206`

- **NetPackageAddRemoveBuff relay and emission** `WORKS` (2026-08-06)
  Validated then relayed, following stock's server branch: a peer may only drive
  its own player entity and only with a buff name the catalog resolves. The
  server can now push a buff onto a player and other clients see it.
  *Anchors:* `src/server/game.zig:4785-4788`, `asm.il:202415`,
  `asm.il:202530-202566`

- **NetPackageEntityStatsBuff** `WORKS` (2026-08-06)
  Built and sent: the full buff list of every other joined player rides
  `buildEntityStatsBuffBody` on join.
  *Anchors:* `src/server/game.zig:4790-4793`

- **Health component and client-claimed damage into the sim** `PARTIAL`
  C2S DamageEntity is validated (actor alive, target alive, both in interest range,
  strength capped, fatal honoured only against NPCs, PvP gate, armour mitigation)
  and applied. This is the only route by which a player's HP moves on the server
  other than eating.
  *Anchors:* `src/server/game.zig:4881-4936`, `src/ecs/world.zig:665-710`,
  `src/ecs/components.zig:22-30`

- **Zombie melee damage replicated to the victim** `WORKS` (2026-08-06)
  Was the biggest hole: `applyDeferredDamage` subtracted HP and emitted nothing,
  `Dirty.hp` was written in one place and read in none, and the four
  EntityStatChanged send sites were all event driven, so a zombie could beat a
  player to zero HP without the client ever hearing about it. The tick replicate
  pass now drains the hp dirty bit into stock EntityStatChanged(Health), the way
  `EntityStats::SendStatChangePacket` does, so combat has stakes and a dead
  player is dead rather than a ghost.
  *Anchors:* `src/ecs/systems.zig`, `src/server/game.zig`, `asm.il:199650`

- **Food / water application on eat** `PARTIAL`
  Works end to end and is the one live-verified vitals path (playtest
  `PASS economy/eat_food_consume ... food0=50.0 food=55.1`), driven by items.xml
  `$foodAmountAdd` / foodHealthAmount / `$waterAmountAdd`. Two caveats: a
  deliberate demo hack drops food to 50% of max before adding whenever food is at
  or above 85% of max, so eating on a nearly full stomach **lowers** your food bar
  (100 to 50 to 65 for a chili); and stock routes the whole thing through the
  `buffProcessConsumables` buff with requirement gates that do not exist here.
  *Anchors:* `src/ecs/inventory.zig:250-280`, `:256-261`,
  `src/assets/items.zig:444-456`, `src/server/game.zig:4530-4533`,
  `Data/Config/items.xml:20015-20029`, `Data/Config/buffs.xml:8477`

- **Food / water decay over time** `MISSING`
  Nothing decrements `health[].food` or `health[].water` anywhere. The only writes
  are 100/100 at spawn, the eat path, and the respawn reset. Hunger and thirst are
  not a threat and food has no purpose beyond the tiny heal.
  *Anchors:* `src/ecs/world.zig:553-556`, `src/ecs/inventory.zig:256-265`,
  `src/server/game.zig:3962`

- **Stamina simulation** `MISSING`
  The server sends a hardcoded `.{ .stamina, 100, 100 }` in the join vitals bundle
  and never again. There is no stamina field on Health. Sprinting, swinging and
  jumping cost nothing server-side; the drain a player sees is purely client-local
  (playtest `PASS core/stamina_drains_sprint`).
  *Anchors:* `src/server/game.zig:6529`, `src/ecs/components.zig:22-30`

- **Health regeneration / wellness / core temperature** `MISSING`
  No regen tick, no wellness, no core temp. `EntityStatKind` has
  sickness/gassiness/speed_modifier/wellness/core_temp_old wired in the wire enum
  but none are ever sent. `weathersurvival.xml` is not loaded.
  *Anchors:* `src/wire/packages.zig:1549-1560`, `src/server/game.zig:6527-6532`

- **Death detection and the dead-player entity** `WORKS`
  A kill through C2S DamageEntity is detected, and the player entity is
  deliberately kept alive at hp 0 rather than destroyed (destroying it desyncs the
  client and breaks later net-id lookups). A second hit on a corpse cannot re-fire
  the kill side effects. Live: `PASS finale/player_death_screen dead=True hp=0`.
  *Anchors:* `src/server/game.zig:4937-4959`, `src/ecs/world.zig:677-705`,
  `src/server/game.zig:2865-2877`

- **Respawn: heal, teleport, PlayerSpawnedInWorld(died), re-bundle** `PARTIAL`
  The sequence fires and the client recovers (`PASS finale/player_respawn`), and
  the heal is correctly gated on actually being dead so a live player cannot spam
  RequestToSpawnPlayer for a free heal. But the respawn position is always the
  world primary spawn, and the playtest saw `hp=50` client-side against the
  server's 100 with `spawned=False`, so the two sides do not agree on the
  post-respawn state.
  *Anchors:* `src/server/game.zig:3942-4009`, `:3956-3988`, `:6022-6056`

- **Respawn zeroes food and water** `PARTIAL`
  Bug. The respawn heal does `self.sim.health[si] = .{ .hp = 100, .max_hp = 100 }`,
  which resets the whole struct, and Health's defaults are `food = 0` and
  `water = 0` (only food_max/water_max default to 100). `sendJoinBundle` then takes
  the death re-bundle branch and `sendPlayerVitals` reads those zeros out of the
  sim and sends Food 0/100 and Water 0/100, which
  `NetPackageEntityStatChanged::ProcessPackage` applies to the local player. Only
  bites on death-respawn, not first join or relog, because `spawnPlayer` does set
  100/100.
  *Anchors:* `src/server/game.zig:3962`, `src/ecs/components.zig:22-30`,
  `src/server/game.zig:6508-6544`, `:6185-6203`, `src/ecs/world.zig:553-556`,
  `asm.il:201999`

- **Bedroll / spawn point selection on respawn** `MISSING`
  `sendWorldSpawnPoints` ships the map's spawnpoints, but every respawn calls
  `spawnSurface(primarySpawn().x, primarySpawn().z)` and ignores the client's
  `selectedSpawnPointKey` entirely (the join PDF hardcodes spawnPoints count 0).
  There is no bedroll block handler. Die anywhere and you walk back from the same
  fixed point every time.
  *Anchors:* `src/server/game.zig:5540-5558`, `:3952`, `:3777`,
  `src/wire/packages.zig:467-468`

- **DropOnDeath backpack** `PARTIAL`
  Broken in both directions. zdtd spawns a bag containing one unit of ECS item 1
  ("scrap") at the death position, ignoring the player's actual inventory.
  Meanwhile stock's real backpack is client-driven:
  `EntityPlayerLocal::dropItemOnDeath` does removeItemsOnDeath plus
  degradeItemsOnDeath plus `dropBackpack(true)`, and `dropBackpack` ends in
  `RequestToSpawnEntityServer(ECD)` which becomes `NetPackageRequestToSpawnEntity`.
  zdtd refuses that package outright as "not authoritative enough". So the client
  empties its own bag on death and then sends SavePlayerData, which zdtd applies to
  the sim inventory: the gear is destroyed and no recoverable backpack ever exists.
  What the player sees at the death site is a single scrap.
  *Anchors:* `src/server/game.zig:4948-4958`, `:4859-4866`, `:4737-4783`,
  `src/assets/items.zig:336`, `asm.il:523092`, `asm.il:523893`, `asm.il:524453`

- **DeathPenalty server option** `PARTIAL`
  The GameStats blob carries death_penalty but it is hardcoded to the struct
  default 1 (XPOnly) and is not in `sendGameStats`'s override list, not in
  `config.zig`'s property table, and not in `serverconfig.example.xml`. Live client
  log confirms `GameStat.DeathPenalty = XPOnly` arriving. The behaviour itself is
  entirely client-side in stock (`EntityPlayer::HandleClientDeath` switches on the
  stat and fires the `game_on_death_*` sequences), so it works by accident at
  XPOnly, but an operator cannot change it and zdtd enforces nothing.
  *Anchors:* `src/wire/packages.zig:1908`, `:2003`,
  `src/server/game.zig:6222-6239`, `src/server/config.zig:110-130`,
  `asm.il:507993`, `asm.il:1904133`, `Data/Config/gameevents.xml:57-110`

- **XP deficit death penalty on the server** `MISSING`
  No deficit is tracked. Stock's `AddXPDeficit` adds
  `GetExpForNextLevel() * ExpDeficitPerDeathPercentage` (default 0.1) clamped to
  `GetExpForNextLevel() * ExpDeficitMaxPercentage` (default 0.5), applied on
  `OnRespawnFromDeath`. Moot in practice since zdtd's own ledger is invisible and
  unpersisted, but the server has no notion of it.
  *Anchors:* `src/server/game.zig:3043-3062`, `asm.il:1084044`, `asm.il:1084146`,
  `asm.il:733886`

- **Death / kill counters** `MISSING`
  The join PDF writes literal zeros for playerKills, zombieKills, deaths and score,
  and PlayerMetaInfo level 0 / distance 0 / totalTimePlayed 0. The C2S
  SavePlayerData parser reads past all four and discards them. Every session the
  client's stats page starts from zero.
  *Anchors:* `src/wire/packages.zig:479-483`, `:537-542`,
  `src/wire/stock_inv.zig:413-417`

- **players.zsv persistence: name, position, coins, inventory, journal** `WORKS`
  ZPV2 merge-write that carries offline records over, refuses to clobber on a
  corrupt read, patches the header count from what was actually written, and
  re-resolves quest POI rects on load. Saved on the periodic tick when dirty, on
  `saveworld`, and on shutdown. Covered by the persist restart scenario.
  *Anchors:* `src/server/game.zig:1910-2033`, `:2050-2164`, `:9176-9179`,
  `src/server/scenarios.zig:293-336`

- **Progression persistence across restart or relog** `MISSING`
  The players.zsv v2 record is name, xyz, coins, inventory, journal. There is no
  XP, level, skill-point or perk field, and `Client.xp` / `Client.level` are zeroed
  on disconnect. The join PDF writes progressionData length 0 and PlayerMetaInfo
  level 0, and the C2S PlayerData parser stops at the Equipment block so the
  client's own progressionsData is never even read. A player who levels to 20 and
  reconnects is level 1 with 0 XP and no perks, every time.
  *Anchors:* `src/server/game.zig:1910-1913`, `:1916-2033`,
  `src/wire/packages.zig:530-533`, `:538-542`, `src/wire/stock_inv.zig:369-428`,
  `src/server/game.zig:337-338`

- **Buff persistence across restart** `MISSING`
  The join PDF writes buffData length 0 alongside progressionData and stealthData.
  There is nothing to persist since no buff state exists.
  *Anchors:* `src/wire/packages.zig:530-533`, `asm.il:1975508`, `asm.il:1977923`

- **Vitals persistence (health, food, water)** `MISSING`
  Not in the players.zsv record, and the join PDF writes `hasEntityStats = false`
  so no PlayerEntityStats block is sent. The reader can skip an incoming block but
  never applies it. Every relog resets you to 100/100/100 via `spawnPlayer`.
  *Anchors:* `src/wire/packages.zig:420`, `src/wire/stock_inv.zig:278-295`,
  `src/ecs/world.zig:553-556`, `src/server/game.zig:1916-2033`

- **progression.zig curve-only loader** `PARTIAL`
  `loadFromPath` calls `loadTableFromPath`, discards the result with `_ = t`
  without ever calling deinit, then re-parses the file with `loadCurveOnly`. The
  table's ArenaAllocator plus its heap-allocated holder leaks on every call.
  Reachable only via the `tryLoad` fallback, which in practice runs only when the
  file is missing, so it is close to dead code, but it is a real leak and a double
  parse.
  *Anchors:* `src/assets/progression.zig:84-90`, `src/server/game.zig:846-850`

---

## 11. World systems

**Headline.** A player can walk, dig, build and persist on real Navezgane terrain
with POIs, day/night and weather; lakes fill from water_info sources, claims
expire, repair heals and supports collapse, but the world is visually bald (3
deco objects per join), terrain is stepped rather than smooth, and block-rotation
persistence and the HUD day counter each have specific, noticeable gaps.

**20 WORKS · 19 PARTIAL · 12 MISSING**

- **Chunk store (16x256x16, u32 rawData plane, lazy channels, ZCH3 disk)** `WORKS`
  Full 65536-cell u32 plane per chunk with lazy texture and density side planes;
  ZCH3 with per-channel presence flags and full bounds validation before mutating
  a resident chunk.
  *Anchors:* `src/world/store.zig:78-342`, `:703-728`, `:736-780`, `:817-904`

- **Stock DTM heightmap load** `WORKS`
  6144x6144 u16 samples, world XZ centred at map centre, per-chunk 16x16 height
  fill, consistent with the shipped file size.
  *Anchors:* `src/world/dtm.zig:12-49`, `Data/Worlds/Navezgane/dtm.raw`,
  `map_info.xml`

- **DTM sub-block precision** `PARTIAL`
  `heightAtWorld` does `samples[idx] >> 8`, discarding the 1/256-block fractional
  height, and the chunk density channel then emits only binary extremes (terrain
  -128, air 127). Hard voxel stairs on every slope where stock renders a smooth
  marching-cubes surface. Only TTS-painted POI cells carry real density.
  *Anchors:* `src/world/dtm.zig:33`, `src/wire/stock_chunk.zig:28-33`, `:430-435`

- **Biome-driven terrain columns** `WORKS`
  `getOrCreate` fills the column from the dominant biome's layer stack before POI
  paint and disk reload; stacks come from the same biomes.xml the server serves, so
  block ids match the client catalog.
  *Anchors:* `src/world/store.zig:582-589`,
  `src/assets/biome_layers.zig:174-230`, `src/server/game.zig:944-963`

- **Procedural worldgen** `PARTIAL`
  Deterministic per-(seed,cx,cz) density field, world-snapped coarse grid so chunk
  borders cannot seam, test pins chunk fill against the density oracle. Missing per
  its own header: fluids and aquifers (a dip below sea level is a dry pit), single
  biome only, caves implicit not carved, per-column surfacing so overhang shelves
  expose stone.
  *Anchors:* `src/world/worldgen.zig:1-27`, `src/world/store.zig:235-241`,
  `:985-1015`

- **Chunk streaming to the stock client** `PARTIAL`
  Hole-free centred square, add/remove deltas, paced 8 adds per 5-tick period. Hard
  compile cap `max_streamed_chunks_cap = 169` (a 13x13 square, ~104 blocks) while
  the client is told `AllowedViewDistance = 12` (25x25 chunks). Beyond ~104 blocks
  the player sees no server terrain at all.
  *Anchors:* `src/server/game.zig:7548-7639`, `:233-239`, `:7284-7345`

- **Resident chunk cap and deterministic eviction** `WORKS`
  4096 resident chunks, min-key victim (not HashMap walk order) so DST replay is
  stable, save-before-free so nothing is discarded unsaved.
  *Anchors:* `src/world/store.zig:524-547`

- **Async chunk flush** `WORKS`
  Opt-in background writer with a per-key wait guard mirroring stock
  `RegionFileManager::IsChunkSavedAndDormant`; falls back to inline write rather
  than dropping; force-serial under DST so fault injection still surfaces errors.
  *Anchors:* `src/world/chunk_flush.zig:1-80`, `src/world/store.zig:789-822`

- **Per-chunk biome** `PARTIAL`
  One biome byte written into all 256 biome cells plus a fixed BiomeIntensity per
  column. Biome transitions snap to 16-block chunk boundaries instead of following
  biomes.png per cell, and there is no blending.
  *Anchors:* `src/wire/stock_chunk.zig:345-362`, `src/server/game.zig:7297-7308`

- **Topsoil bitfield / splat maps** `PARTIAL`
  `m_bTopSoilBroken` is written all-0xFF (every column marked broken) so the client
  uses Block side textures instead of sampling MicroSplat. Terrain reads as uniform
  blocks.xml colours; splat1-4.png are never used. Deliberate workaround per the
  code comment.
  *Anchors:* `src/wire/stock_chunk.zig:337-343`,
  `Data/Worlds/Navezgane/splat1.png`

- **Chunk light seeding** `PARTIAL`
  Light channel is a uniform 0xFF with NeedsLightCalculation=true, so the first
  mesh is uniformly bright until the client's own light pass runs. No server-side
  light model exists.
  *Anchors:* `src/wire/stock_chunk.zig:380-391`

- **Stability channel omitted from the chunk wire** `WORKS`
  Matches stock `bNetwork=true`, which skips the stability channel; the client
  rebuilds the plane itself via `LightChunk` to `CalcStability` to
  `DistributeStability`.
  *Anchors:* `src/wire/stock_chunk.zig:329`, `asm.il:1127022`, `asm.il:1127044`

- **POI / prefab placement from prefabs.xml plus .tts** `PARTIAL`
  Full POIs flatten heights and paint their block/texture/density planes, and TEs
  are enumerated for storage. Every prefab whose name starts `part_` is skipped
  outright, so roads, driveways and every part-based decoration are absent. (Full
  detail in [section 7](#7-pois-and-prefabs).)
  *Anchors:* `src/world/prefabs.zig:79-114`, `:222-242`, `:232`,
  `src/world/tts.zig:1-200`

- **Player-placed block rotation / meta in the chunk plane** `PARTIAL`
  `setBlockWorld` writes only the bare u16 id into `Chunk.blocks`, so rotation and
  meta live only in a 128-entry FIFO sparse cache the chunk encoder never consults.
  Place 129 rotated blocks, or walk out of stream range and back, and wedges, doors
  and shapes re-render unrotated on the chunk resend.
  *Anchors:* `src/world/store.zig:260-262`, `src/server/game.zig:465`,
  `:3305-3336`, `:7310-7314`

- **Block damage in the chunk wire** `MISSING`
  The damage channel is written as uniform same-value 0. A partially chewed base
  wall re-renders pristine on every chunk resend, even for blocks the server still
  tracks.
  *Anchors:* `src/wire/stock_chunk.zig:384`

- **Join-time deco burst (NetPackageDecoUpdate) plus world mirror** `PARTIAL`
  One `firstPackage=true` burst at RequestToEnterGame, 4096 objects per package,
  mirrored into the block store so collision and harvest agree. It is the only
  window (the client drains and nulls `DecoManager.loadedDecos` at the end of
  OnWorldLoaded), so anything outside the join radius stays bald for the whole
  session however far the player walks.
  *Anchors:* `src/server/game.zig:1534-1627`, `:1637-1645`,
  `src/wire/stock_deco.zig:98-141`, `src/world/deco_mirror.zig:1-22`

- **Deco density (biomes.xml probabilities)** `PARTIAL`
  zdtd samples only the biome's top-level `<decorations>` list and never evaluates
  subbiome noise. Stock's `decorateChunkRandom` resolves each cell through
  `GetBiomeOrSubAt` and samples that subbiome's `m_DistantDecoBlocks`. For
  pine_forest the top-level rows are prob .001-.007 while the subbiome lists carry
  treeJuniper4m .06, treeDeadTree01 .07, treeDeadPineLeaf .08. Live result:
  `DecoUpdate objs=3 pkgs=1 r=6 mirrored=3` for an entire 13x13-chunk join window.
  *Anchors:* `src/assets/biome_layers.zig:2`, `:415-435`,
  `src/wire/stock_deco.zig:292-357`, `asm.il:1266039`, `asm.il:1303341`,
  `Data/Config/biomes.xml:489-507`, `:261-267`, `server-orch.log:41`

- **Deco rotation** `PARTIAL`
  Every DecoObject is emitted with rotation 0; stock rolls
  `BiomeBlockDecoration::GetRandomRotation`. All trees and rocks face the same way.
  Deliberate: a rotated multiblock changes the child-cell offsets the world mirror
  writes.
  *Anchors:* `src/wire/stock_deco.zig:287-291`, `:347-353`

- **Deco ore-noise gate (CheckOreNoiseAt)** `MISSING`
  Not implemented; documented as deliberate because every `checkresource` row in
  stock biomes.xml is a `type="prefab"` row zdtd does not send anyway.
  *Anchors:* `src/wire/stock_deco.zig:287-289`

- **type="prefab" decorations** `MISSING`
  Only `type="block"` rows become DecoObjects. Surface rock formations
  (rock_form01/02) and the surface ore veins (deco_iron_vein, deco_coal_vein) that
  feed early mining never appear anywhere.
  *Anchors:* `src/wire/stock_deco.zig:154-159`, `Data/Config/biomes.xml:283`,
  `:310`, `:494-495`

- **Deco multiblock mirroring** `WORKS`
  Offsets derived from blocks.xml MultiBlockDim exactly as `Block::Init` builds
  them; child rawData packs ischild plus parent offsets into meta/meta2/
  rotationAndMeta3 matching the stock setters; oversized multiblocks are skipped
  rather than half-written.
  *Anchors:* `src/world/deco_mirror.zig:39-111`, `asm.il:92240-92325`,
  `asm.il:140882-140960`, `asm.il:1126815-1127012`

- **Weather state machine (clear / stormbuild / storm, per biome)** `WORKS`
  Branch-for-branch port of `BiomeWeather::ServerTimeUpdate`: 5-tick
  re-evaluation gate, 60/DayNightLength scaling, storm delay divided by
  StormFrequency, duration jitter, remaining_seconds divided by TimeOfDayIncPerSec,
  weighted group pick and per-ProbType range roll. Six unit tests including a full
  storm cycle and an i64-max case.
  *Anchors:* `src/world/weather.zig:104-284`, `asm.il:2048930`, `asm.il:2049128`,
  `asm.il:1250209`, `asm.il:1249300`

- **Blood-moon weather override** `WORKS`
  Pushes every scheduled storm at least 5000 ticks past the horde night and forces
  each biome to its bloodMoon group once per transition, releasing on exit,
  matching `CalcGlobalWeatherType`.
  *Anchors:* `src/world/weather.zig:122-142`, `asm.il:2051850`

- **NetPackageWeather broadcast** `WORKS`
  23-byte records (biomeId, groupIndex, remainingSeconds, 5x f32), no count prefix,
  groupIndex clamped to the biome's group count so `SetWeatherGroup` cannot index
  out of range. Sent on re-join and every 20 ticks, deferred under load shedding.
  *Anchors:* `src/wire/packages.zig:2057-2075`, `src/server/game.zig:8192-8253`,
  `:8113`

- **Weather biome padding when biomes.xml yields fewer than 5 weather biomes** `PARTIAL`
  When n < 5 the last real state is duplicated into fabricated biome_ids 1..5. The
  client keys strictly by biomeId, so a partial or modded biomes.xml would push one
  biome's groupIndex into another whose group list may be shorter, while
  `buildWeatherBody` clamps against the source biome's group_count. Dead for stock
  data, live for mods.
  *Anchors:* `src/server/game.zig:8211-8235`, `src/wire/packages.zig:2065-2075`,
  `asm.il:2054217-2054277`

- **StormFrequency configurability** `PARTIAL`
  `storm_frequency` is taken from the compile-time GameStatsValues default. No
  serverconfig or zdtd.toml knob exists, so an operator cannot turn storms up, down
  or off.
  *Anchors:* `src/server/game.zig:950-956`, `src/wire/packages.zig:1910-1912`

- **Weather gameplay effects** `MISSING`
  Weather is wire-cosmetic only. Nothing on the server reads the five params: no
  core temperature, no wet or cold buffs, no stamina/food/water modifiers. The
  client loads weathersurvival locally but the server never drives it.
  *Anchors:* `src/world/weather.zig:9-11`, `src/server/game.zig:5670`

- **Day/night clock and NetPackageWorldTime broadcast** `WORKS`
  WorldClock advances hours from real dt scaled by DayNightLength, dawn fixed at
  04:00 and dusk = 4 + DayLightLength, broadcast as a u64 every 20 ticks and sent
  once at enter. Blood-moon nights, zombie speed bands and POI lockouts all read
  the same clock.
  *Anchors:* `src/ecs/aidirector.zig:6-68`, `src/server/game.zig:8101-8103`,
  `:6204-6205`

- **World time day number** `PARTIAL`
  `worldTimeBits` returns `day*24000 + hours*1000` with day starting at 1, but
  stock encodes `(day-1)*24000` and decodes `worldTime/24000 + 1`. The client HUD
  shows one day more than the server believes: server day 1 08:00 renders as
  "Day 2 08:00", and the day-7 blood moon lands on the client's displayed day 8.
  *Anchors:* `src/ecs/aidirector.zig:63-67`, `asm.il:1926175-1926208`,
  `asm.il:1925943-1925956`

- **World clock persistence across restart** `MISSING`
  Nothing saves or restores `WorldClock.day` / `hours`. Every restart resets the
  world to day 1, 08:00, wiping the blood-moon schedule and any day-gated quest or
  loot-respawn progress. The periodic persist path saves only chunks, containers,
  block meta and players.
  *Anchors:* `src/server/game.zig:8131-8147`, `:1691-1703`,
  `src/ecs/aidirector.zig:7-8`

- **Blood-moon schedule plus NetPackageBloodmoonMusic** `WORKS`
  Deterministic jitter around each frequency multiple with neighbouring cycles
  tested so a jittered day across the boundary still fires; music package
  edge-triggered on the transition. (Divergences from stock in
  [section 6](#6-blood-moon).)
  *Anchors:* `src/ecs/aidirector.zig:41-61`, `src/server/game.zig:8114-8121`

- **Water blocks in the world** `MISSING`
  No water block is ever written. `water_info.xml` is parsed only to **raise**
  terrain heights up to the water Y within a 12-block radius, so Navezgane's 39
  lake and pond sources render as flat dry dirt plains. The `.tts` water plane is
  parsed only to skip past it. `terrain_ids.water` exists but nothing ever assigns
  it.
  *Anchors:* `src/world/water.zig:34-57`, `src/world/store.zig:624-626`,
  `src/world/tts.zig:170-197`, `Data/Worlds/Navezgane/water_info.xml`

- **Chunk water channel on the wire** `MISSING`
  The bpv=2 water channel is written as uniform same-value 0 for every chunk, so
  the client's WaterSimulationApplyChanges thread has nothing to render or
  simulate. No swimming, no drinking from a lake, no water blocking movement.
  *Anchors:* `src/wire/stock_chunk.zig:388`

- **Water simulation / flow packages** `MISSING`
  `NetPackageWaterSet` and `NetPackageWaterSimChunkUpdate` are in the package-id
  table so ids stay aligned, but there is no builder, no parser and no handler.
  Placing or removing a water source does nothing.
  *Anchors:* `src/wire/packages.zig:247-248`

- **Block stability plane / structural support** `WORKS` `(2026-08-06)`
  `src/world/stability.zig` ports the stock model: per-block byte plane (15 full
  support, 1 cap for non-support, 0 is the only value that falls), reset +
  distribute on first touch, and incremental removal/placement recompute.
  `Game.stabilityAfterSetBlock` runs it on every C2S SetBlock: a removed support
  block fells the recursed dependency chain and the caller removes + broadcasts
  the fallen blocks; a placed block takes support from its neighbours and
  re-spreads. Support/ignore membership comes from the maxdamage block tables.
  Known gaps: a placed block that would fall instantly still stands until a
  support change under it (stock seeds 15 everywhere too, so this matches stock);
  no `EntityFallingBlock` visual entity (the client collapses locally).
  *Anchors:* `src/world/stability.zig`, `../7dtd-research/docs/stability.md`

- **Structural collapse / falling blocks** `BLOCKED (2026-08-07)`
  The stability plane and collapse removal are shipped (the server removes
  every now-unsupported block and broadcasts the change; the client renders its
  own falling blocks because it runs the identical plane locally). The
  server-side `fallingBlock` ENTITY spawn (stock `World::AddFallingBlock` +
  `LetBlocksFall` outside the IsServer guard) is deferred: spawning server
  entities for positions the client already collapses locally risks visible
  duplicate falling blocks, and the dedup behavior between server-replicated
  and client-local falling entities is not yet pinned down from RE.
  *Blocked on:* `EntityFallingBlock(s)` spawn/landing dedup RE before the
  entity spawn can ship; the removal-side parity is done.
  *Anchors:* `asm.il:1095889-1095893`, `asm.il:1239718`, `asm.il:1239773`,
  `asm.il:1240000`, `asm.il:1881963`, `src/wire/stock_entity.zig:121`

- **Player block damage (C2S SetBlock, BlockDamagePlayer, break)** `PARTIAL`
  Reach-gated, land-claim-gated, throttled, scaled by BlockDamagePlayer, broken
  when absolute damage reaches blocks.xml MaxDamage, with an authoritative S2C
  echo. But the damage store is a 64-entry global FIFO array with a linear scan:
  the 65th distinct damaged block in the whole world silently evicts the oldest,
  resetting that block to full HP mid-fight.
  *Anchors:* `src/server/game.zig:5057-5241`, `:461-463`, `:3268-3283`,
  `:3235-3245`

- **Block repair (ItemActionRepair)** `WORKS`
  Stock repair calls `Block::DamageBlock` with a **negated** repair amount and
  SetBlockRPCs the resulting **lower** absolute damage, so C2S SetBlock carries
  damage < current. zdtd now takes the wire value as the new absolute damage
  when it is lower (never adds a lower value as a delta), so repairing 500 to
  300 sets 300 and a full repair (0) clears the damage; the block's hp then
  rises toward max on the next damage write.
  *Anchors:* `src/server/game.zig:6024` repair branch, `asm.il:657520-657583`,
  `asm.il:96545-96562`, `asm.il:96797-96812`

- **Block upgrade (frame to reinforced)** `PARTIAL`
  Works only incidentally: stock turns an over-repaired block into
  `Block.UpgradeBlock` client-side and sends a SetBlock with the new id and damage
  0, which zdtd's handler falls through to as a plain fresh place. The server has
  no UpgradeBlock table, does no material or tool validation, never consumes
  upgrade items and grants no XP. A modified client can upgrade anything to
  anything for free.
  *Anchors:* `src/server/game.zig:5173-5179`, `asm.il:96718-96762`,
  `asm.il:657572`

- **Block downgrade on destroy (Stage2Health)** `MISSING`
  When HP runs out zdtd always sets air. Stock's DamageBlock has a Stage2Health
  path that downgrades a block to a damaged stage instead of destroying it, so
  concrete to damaged concrete to destroyed never happens here.
  *Anchors:* `src/server/game.zig:5162-5166`, `asm.il:96828-96833`

- **Zombie block damage** `PARTIAL`
  Zombies in chase/attack within 3 blocks chew the cell in front at head height, 10
  damage per 2 Hz bite scaled by BlockDamageAI (AIBM on blood moon), broadcast on
  break. Simplified: a single ray-less cell probe rather than real AI block-target
  selection, and it shares the same 64-slot damage cap.
  *Anchors:* `src/server/game.zig:3094-3134`

- **Block max HP from blocks.xml MaxDamage** `WORKS`
  Resolved per block id from the parsed table with Extends resolution; fails closed
  to 100 when the catalog is loaded but the id is unknown, and only falls back to
  id-band guesses when no catalog was loaded at all.
  *Anchors:* `src/server/game.zig:3235-3245`, `src/assets/maxdamage.zig`

- **Explosion block damage** `PARTIAL`
  Applies a uniform sphere dig (radius clamped 1..6) that deletes every non-bedrock
  block inside it regardless of material or MaxDamage, then broadcasts
  ExplosionClient. No falloff, no per-block resistance, no partial damage, no
  per-item block-damage multiplier.
  *Anchors:* `src/server/game.zig:5243-5310`

- **Land claim keystone registration, edit deny, durability modifier** `WORKS`
  Placing a keystoneBlock registers a claim; `claimCovering` does a Chebyshev test
  against LandClaimSize/2 and blocks edits by anyone but the owner; the owner's
  blocks get max_hp multiplied by the online/offline durability modifier. Cap of
  256 claims, new claims silently dropped past that (documented limit).
  *Anchors:* `src/server/game.zig` registerClaim/claimCovering,
  `:5995-6005`

- **Land claim removal when the keystone is destroyed** `WORKS`
  `removeClaimAt` drops the claim when the keystone breaks (SetBlock damage >= max
  hp or block id 0) and `expireClaims` releases offline claims past
  `LandClaimExpiryDays` on the day roll; expiry 0 disables it. Test covers
  keystone break, non-keystone break, offline expiry and online-never-expires.
  *Anchors:* `src/server/game.zig` removeClaimAt/expireClaims, test at `:10017`

- **Land claim persistence** `MISSING`
  Claims live in a fixed in-memory array and are never written to disk. A restart
  drops every claim while the keystone blocks themselves persist in the chunk save,
  so protection silently disappears and cannot be re-established without
  re-placing the block.
  *Anchors:* `src/server/game.zig:415-417`, `:1691-1703`

- **Land claim replication to the client (lpBlocks)** `MISSING`
  The player-data blob writes `lpBlocks count = 0`, so the client never learns
  about any claim. No claim boundary on the map, no protected-area overlay, no
  client-side feedback: an edit inside someone else's claim just silently fails.
  *Anchors:* `src/wire/stock_inv.zig:846`, `:885`

- **Land claim rules: Count, DeadZone, ExpiryTime, DecayMode, OfflineDelay** `PARTIAL`
  ExpiryTime is enforced (`expireClaims` on the day roll, offline only); the other
  four (claim Count, DeadZone, DecayMode, OfflineDelay) are written into the
  GameStats blob so the client displays them, but are not enforced.
  *Anchors:* `src/wire/packages.zig:1916-1920`, `:1984-1991`,
  `src/server/game.zig` expireClaims

- **Land claim owner_online tracking** `WORKS`
  `markClaimsForEntity` sets `owner_online` false on disconnect and true on join,
  refreshing `owner_seen_day` (the expiry base); the offline durability modifier
  is therefore live.
  *Anchors:* `src/server/game.zig` markClaimsForEntity

- **Chunk / block persistence across restart** `WORKS`
  ZCH3 chunk saves carry the full u32 block plane plus texture and density
  channels; the ZBM1 sidecar carries sparse rotation raw plus accumulated damage
  with sorted keys for deterministic bytes. Round-trip covered by a
  dig/place/reload test.
  *Anchors:* `src/world/store.zig:736-780`, `:1017-1040`,
  `src/server/game.zig:3350-3412`

- **Terrain footing snapshot for A*** `WORKS`
  Conservative read-mostly per-column surface descriptor rebuilt on the main thread
  each tick, built with `getPtr` (never `getOrCreate`) so a hit equals what the
  locked hook would return; misses fall through to the locked path and are counted.
  *Anchors:* `src/world/terrain_snapshot.zig:1-60`

---

## 12. Net and ops

**Headline.** A player can join and play today over direct IP with a correct
189-name package map and a working reliable/fragmented LiteNet channel, but the
server is invisible to every server browser, drops the block id mapping on every
single join, silently ignores 35 packages the stock client actually sends, and
persists so little that a restart visibly damages a built base.

**12 WORKS · 29 PARTIAL · 11 MISSING**

- **PackageIds name table (189 stock names, exact set)** `WORKS`
  `default_mappings` holds exactly the 189 concrete `NetPackage` subclasses of
  V3.1.0 b14. Verified by extracting every class transitively extending NetPackage
  from asm.il (191) and removing the two abstract ones
  (`NetPackageEntityTargeted`, `DynamicMeshServerData`), since
  `FindTypesImplementingBase` defaults `_allowAbstract=false`. Set difference is
  empty in both directions, including nested types registered by short name.
  *Anchors:* `src/wire/packages.zig:68-256`, `asm.il:805117-805140`,
  `asm.il:805088-805100`, `asm.il:2133289-2133345`

- **PackageIds id 0 reserved for NetPackagePackageIds** `WORKS`
  Stock `SetupBaseMapping` always maps packageIdsType to id 0 and
  `IdMappingsReceived` skips it; zdtd puts it at index 0.
  *Anchors:* `src/wire/packages.zig:69`, `asm.il:805194-805212`,
  `asm.il:805272-805340`

- **NetPackagePackageIds body encoding** `WORKS`
  Stock read order is VersionInformation.Read, i32 count, count strings, bool
  serverUseEAC, bool hasHostUserAndToken, then host id plus token. zdtd writes
  exactly that with hasHost=false, and its VersionInfo (1,3,10,14) matches the
  Constants literals.
  *Anchors:* `src/wire/packages.zig:270-292`, `asm.il:828487-828545`,
  `asm.il:1865686-1865690`

- **Unknown-name safety in the PackageIds map** `WORKS`
  Any name not in `knownPackageTypes` makes the client log
  `[NET] Unknown package type ..., can not proceed connecting to server`,
  Disconnect, and show EKickReason 18 = UnknownNetPackage. Because zdtd's table is
  an exact match this can never fire, but the table must never be hand-edited with
  a typo.
  *Anchors:* `asm.il:805288-805310`, `asm.il:1921872`

- **C2S handler coverage** `PARTIAL`
  70 package names have a handler in `Game.handlePackage`. Scanning asm.il for
  `GetPackage<X>` immediately preceding `SendToServer` yields 98 names the stock
  client actually sends; 35 have no handler: Debug, DroneDataSync,
  DroneParticleEffect, DynamicMesh, EAC, EditorUpdateVolume, EncryptionPublicKey,
  EntityAwardKillServer, EntityPhysics, EntityRagdoll, EntityStatChanged,
  EntityStealth, GameEventResponse, GameMessage, ItemReload, KeyExchangeComplete,
  ModifyCVar, ParticleEffect, PartyQuestChange, PickupBlock, PlayerDisconnect,
  PlayerLaserSight, PlayerTwitchStats, PlayerVendingMachine, QuestGotoPoint,
  QuestTreasurePoint, SetBlockTexture, SetProp, SharedPartyKill, SimpleRPC,
  SoundAtPosition, TwitchAccess, TwitchVoteScheduling, Waypoint, WorldFolder.
  Player-visible: paint never sticks, wrench-pickup does nothing, reload never syncs
  ammo, map waypoints are local only, vending machines are inert, buried-supplies
  and goto quest markers never register, ragdolls/particles/positional sound are not
  relayed, and a clean Quit-to-menu is not noticed.
  *Anchors:* `src/server/game.zig:3771-5480`, `asm.il:791490-791510`,
  `asm.il:793038-793060`

- **Unhandled C2S packages are dropped with no trace** `PARTIAL`
  `handlePackage` is a linear if/eql chain that falls off the end for any name it
  does not know. No counter, no rate-limited log, no evidence event. Contrast the
  `id >= 189` case, which does log "unmapped package".
  *Anchors:* `src/server/game.zig:3771-3790`, `:5478-5480`

- **S2C package emission coverage** `PARTIAL`
  35 names are emitted. ToClient names never sent at all include MapChunks,
  PersistentPlayerPositions, WorldAreas, SleeperWakeup/SleeperPose/
  SleeperPassiveChange, TurretSync, EntityLookAt, EntityVelocity,
  EntityAddExpClient, EntitySetSkillLevelClient, ShowToolbeltMessage,
  ChunkClusterInfo, WallVolume, Light, TreeFade, AudioPlayInHead,
  WaterSimChunkUpdate, PlayerSetBackpackPosition, ClientInfo, AuthState. The
  in-game map never fills in or shows party members, sleeper volumes (3124 loaded)
  never wake or pose on the client, turrets do not animate, and pickup/toolbelt
  notifications never appear.
  *Anchors:* `src/server/game.zig:2976-3040`, `:7686-7760`,
  `src/wire/packages.zig:1320`

- **Game envelope channel byte** `PARTIAL`
  `frame.framePackage` always writes channel 0. Stock overrides `get_Channel` to 1
  for NetPackageChunk, ChunkRemove, DynamicMesh, MapChunks and POIAround, i.e. bulk
  world data rides a second envelope stream so it does not sit in the same queue as
  control traffic.
  *Anchors:* `src/wire/frame.zig:201-217`, `asm.il:808632-808638`,
  `asm.il:826004`, `asm.il:833771`

- **S2C compression** `PARTIAL`
  Only the block NameIdMapping is deflated. Stock overrides `get_Compress()=true`
  for eight packages: Chunk, ConfigFile, DynamicClientArrive, DynamicMesh,
  IdMapping, MapChunks, POIAround, SignDataResponse. zdtd sends Chunk, ConfigFile
  and SignDataResponse uncompressed, which is why one join costs 6.4 MB out
  (`net_bytes_out=6388795` for a single 60 s gate run) and why the reliable window
  saturates.
  *Anchors:* `src/wire/frame.zig:146-198`, `src/server/game.zig:5598-5628`,
  `:7347`, `asm.il:808641-808647`, `asm.il:809975`, `asm.il:822370`,
  `asm.il:826004`, `asm.il:833771`, `asm.il:841321`

- **Package batching per envelope** `MISSING`
  `framePackage` hardcodes count=1, so every game package becomes its own LiteNet
  reliable message. Stock `NetConnectionAbs` accumulates a package stream and sends
  one envelope with `_packageCount>1`. With one package per datagram, the 64-slot
  window holds 64 packages instead of 64 batches.
  *Anchors:* `src/wire/frame.zig:207-212`, `asm.il:788600-788684`

- **C2S envelope decompression** `WORKS`
  Honours the per-envelope compressed flag, sniffs gzip/zlib/raw, caps expansion at
  64x and 512 KiB, and fails closed on reentrant parse so `Package.body` slices are
  never clobbered. Fuzzed.
  *Anchors:* `src/wire/frame.zig:44-125`, `src/fuzz.zig:106-140`

- **Encrypted envelopes / key exchange** `MISSING`
  `parseChannelPayload` returns 0 when the encrypted byte is non-zero, and none of
  EncryptionRequest / EncryptionPublicKey / EncryptionSharedKey /
  KeyExchangeComplete is handled or sent. Correct for EAC-off since encryption is
  server-initiated by `AntiCheatEncryptionAuthServer.TryStartKeyExchange`, but it
  hard-caps zdtd at EAC-off hosting forever.
  *Anchors:* `src/wire/frame.zig:115`, `asm.il:781868-781905`

- **LiteNet ConnectRequest / ConnectAccept, protocol id 13** `WORKS`
  `parseConnectRequest` validates protocol id, address size (16/28) and truncation;
  `writeConnectAccept` emits the 15-byte stock layout. Proven live: the stock
  client connects and reaches Playing (gate 23/23).
  *Anchors:* `src/litenet/packet.zig:76-95`, `:141-152`,
  `~/.cache/zdtd-playtest/report-1785987487.json`

- **ServerPassword as LiteNet connect key** `WORKS`
  `connectKeyMatches` reads the NetDataWriter string from the request data and
  compares constant-time; mismatch replies with Disconnect plus
  EAdditionalDisconnectCause 0. Applied on every ConnectRequest including
  retransmits.
  *Anchors:* `src/litenet/packet.zig:120-140`, `src/litenet/server.zig:48-64`

- **Pre-auth challenge handshake** `PARTIAL`
  Shape is right: 17 bytes `[0xCA][16]`, matching
  `LiteNetLibAuthWrapperServer.ChallengePackageSize = 0x11`. But zdtd derives the
  16 bytes from a monotonic counter and a fixed multiplier, so the challenge is
  fully predictable, where stock uses `Guid.NewGuid()`. It is echoed back over the
  same connection so this is not an authentication break, but it removes any value
  the echo has as a spoofed-source check.
  *Anchors:* `src/server/game.zig:2941-2946`, `src/protocol.zig:11-12`,
  `asm.il:852999`, `asm.il:853010-853025`

- **Auth-state timeout (half-open connection reaping)** `MISSING`
  Stock arms `MaxDurationInAuthState = 10 s` and sweeps every
  `ConnectionStateCheckInterval = 10 s`, dropping any peer still Authenticating.
  zdtd only reaps on receive silence (`peer_stale_ms`, default 3000). A peer that
  completes ConnectRequest, never echoes the challenge, and keeps answering Pings
  holds a Client slot indefinitely. With max_players 8 that is an 8-packet
  slot-exhaustion DoS.
  *Anchors:* `src/server/game.zig:4081-4113`, `src/litenet/peer.zig:412-414`,
  `src/server/zdtd_config.zig:429`, `asm.il:853692-853711`

- **Connect rate limiting** `PARTIAL`
  500 ms/IP matches stock `ConnectionRateLimitMilliseconds = 0x1F4`, but zdtd
  applies it in `Game.onConnected`, **after** `Server.poll` has allocated a peer
  slot and sent ConnectAccept, whereas stock rejects inside
  `ConnectionRequestCheck`. The table is a fixed 16 entries that is append-only and
  never aged: after 16 distinct IPs have connected, every further IP is
  unthrottled. `packet.reject_rate_limit` and `packet.reject_pending_connection` are
  defined and never used.
  *Anchors:* `src/server/game.zig:3553-3572`, `:3628-3634`,
  `src/litenet/server.zig:47-77`, `src/litenet/packet.zig:70-72`,
  `asm.il:852995`

- **NetPackagePlayerLogin body parsing** `PARTIAL`
  zdtd reads only the leading playerName string. Stock's read order is playerName,
  platformUser (`PlatformUserIdentifierAbs.FromStream`), platformToken,
  crossplatformUser, crossplatformToken, version, compVersion, discordUserId. So
  zdtd has no platform identity, no auth token, and no client-version check: there
  is no EKickReason.VersionMismatch path, and a client of a different build joins
  and desyncs silently. The identity gap cascades into save keying, bans and admin
  permissions.
  *Anchors:* `src/server/game.zig:3893-3906`, `asm.il:832130-832182`,
  `asm.il:832185-832275`, `asm.il:31206-31248`

- **EAC enforcement** `MISSING`
  By design. NetPackageEAC and NetPackageAuthState are never sent or handled, GSI
  advertises `EACEnabled:False`, and no encryption is initiated. Live client log
  confirms "Not started with EAC, anticheat disabled". Players must run the EAC-off
  client and the server can never be advertised as protected.
  *Anchors:* `src/server/serverinfo_tcp.zig:23`, `src/server/game.zig:3765`,
  `output_log_client_zdtd_connect.txt:61-62`

- **Kick wire (NetPackagePlayerDenied)** `PARTIAL`
  `buildPlayerDeniedBody` encodes the stock body and the guard policy uses it with
  a delayed drop. But the three join-time rejects (no free slot, banned IP,
  rate-limited) just set `peer.alive=false` and clear the slot with no PlayerDenied
  and no LiteNet Disconnect, so the client hangs until its own timeout with no
  reason string. Stock has PlayerLimitExceeded(5) and Banned(6) for exactly these.
  *Anchors:* `src/wire/packages.zig:2149-2175`, `src/server/game.zig:3608-3634`,
  `:5858-5870`, `asm.il:1921854-1921883`

- **Bans and whitelist** `PARTIAL`
  `ban_ip` is 32 IPv4 host-order keys held in RAM only. No persistence across
  restart, no expiry or ban-until, no serveradmin.xml, no ban by platform
  identifier, no whitelist, no reserved or admin slots. IPv6 peers are folded to an
  FNV hash so a ban is per-address, not per-prefix.
  *Anchors:* `src/server/game.zig:458-459`, `:3574-3600`, `:3530-3550`,
  `serverconfig.xml` (AdminFileName / ServerReservedSlots / ServerAdminSlots)

- **Admin permission levels** `MISSING`
  There is no permission model. The in-game console has a fixed read-only allowlist
  (help, gettime, listplayers, listents, say, version, dm, cm, settempunit,
  debugmenu); everything mutating is reachable only from the loopback TCP console.
  A real server admin cannot use giveself, settime, teleportplayer or kick from
  in-game at all. Stock has `ConsoleCmdAbstract.DefaultPermissionLevel` and
  `cDefaultUserPermissionLevel = 1000` with admins.xml.
  *Anchors:* `src/server/c2s_text.zig:38-45`, `src/server/game.zig:2199-2205`,
  `asm.il:204246-204254`, `asm.il:1865701`

- **IPv6 hosting** `MISSING`
  The UDP socket binds only `IpAddress.ip4.unspecified(port)`. An IPv6-only client
  cannot reach the server. Stock LiteNetLib is constructed with the dual-stack flag
  set.
  *Anchors:* `src/litenet/udp_socket.zig:21-27`, `asm.il:852304-852310`

- **Reliable-ordered channel and ack bitmap** `WORKS` `(2026-08-07)`
  window_size 64, max_sequence 32768, ack payload 9 bytes, channel byte 2 (LiteNet
  channelNumber 0 plus DeliveryMethod.ReliableOrdered=2, confirmed by
  `NetworkServerLiteNetLib::SendData`). Inbound delivery is now ordered: a
  non-fragmented payload for a seq ahead of the expected next is held in a
  window-bounded hold buffer (falling back to on-first-sight when the hold is
  full), and the in-order packet delivers then drains every now-contiguous
  held payload through the extra mailbox, so WAN reordering no longer applies
  SetBlock / inventory transactions out of order. Fragmented messages deliver
  on completion as before (their payload lives in the reassembly buffer).
  *Anchors:* `src/litenet/packet.zig:24-25`, `:236-249`,
  `src/litenet/peer.zig:436-469`, `:551-565`, `asm.il:854255-854262`

- **Per-package delivery method (unreliable motion)** `WORKS` `(2026-08-07)`
  Stock overrides `get_ReliableDelivery` to false for exactly five packages:
  EntityPosAndRot, EntityRelPosAndRot, EntityRotation, EntitySpeeds,
  EntityStatsBuff, and `NetConnectionAbs` passes that flag to SendData, which
  selects DeliveryMethod.Unreliable(4). `sendGame` and `broadcastExcept` now
  route those five names through `Peer.sendUnreliable` (single-datagram fire
  and forget; oversized frames fall back to the reliable path), and the
  replicate fan-out sends the PosAndRot/Speeds frames via
  `sendFramedUnreliable`. 20 Hz motion no longer occupies or retransmits
  inside the 64-slot reliable window shared with chunks and join-critical
  control traffic. Residual: `sendSequenced` still has no callers; the C2S
  RelPos path is not relayed (peers learn positions from the sim replicate).
  *Anchors:* `src/server/game.zig:2976-3040`, `src/litenet/peer.zig:197-215`,
  `asm.il:816202-816208`, `asm.il:793041-793050`

- **Outbound fragmentation** `PARTIAL`
  Fragments at 1317 user bytes per part, up to 512 parts, stable frag_id across
  per-part WindowFull retries. The defect is the outer retry:
  `sendFramedReliable` / `sendGame` catch WindowFull and re-enter `sendReliable`,
  which restarts the message at part 0 with a fresh frag_id, discarding all
  in-flight parts and burning window slots again.
  *Anchors:* `src/litenet/peer.zig:217-263`, `src/server/game.zig:6285-6308`,
  `:3526-3550`

- **Inbound fragment reassembly** `WORKS` `(2026-08-07)`
  Peer now holds two assembly slots keyed by frag_id (stock keeps a dictionary;
  the realistic interleave is exactly two: a Bag plus a PlayerInventory during a
  loot transfer). A second fragmented message no longer clears the first; a
  third concurrent message drops with an `asm_drops` counter. Regression test
  interleaves two messages and reassembles both whole.
  *Anchors:* `src/litenet/peer.zig:149-157`, `:320-331`

- **Reliable-window starvation on join (block IdMapping dropped)** `PARTIAL`
  Live evidence, not theory: the server log shows
  `reliable window drop pkg=NetPackageIdMapping (framed)` followed by
  `blocks IdMapping send failed: WindowFull`, and the APM line reports
  `reliable_window_drops=1`. The ~250 KiB deflated mapping is ~200 fragments
  through a 64-slot window shared with uncompressed chunk and ConfigFile traffic.
  The client falls back to its own `Block::AssignIds` ordering, which happens to
  match today only because zdtd loads the same blocks.xml.
  **Mitigated 2026-08-06:** the retry loops (`sendGame`, `sendFramedReliable`,
  `sendFramedDroppable`) slept 0.5 s every 4th WindowFull attempt, wedging the
  single-threaded tick for up to ~2 min per stuck peer and starving
  `reapStalePeers` (3 s). They now pump ACK-free for the first 16 attempts and
  then pace at 1 ms every 4th (LiteNetLib clients batch ACKs on ~15 ms Update
  cycles, so the pacing lets a live peer's ACKs drain the window), keeping the
  ~960-attempt budget bounded to ~240 ms of tick time per stuck peer; a dead
  peer is reclaimed by the stale-peer sweep instead of holding the tick.
  Residual: the loadgen client (PollEvents-only networking loop) still drops
  the mapping on every flat-world join and falls back to local AssignIds
  (matching for same-install); the outer retry still restarts the fragment
  stream.
  *Anchors:* `server-orch.log:39-40`, `:48`, `src/server/game.zig:6207-6283`,
  `:6285-6308`

- **LiteNet Merged packet handling** `WORKS`
  Merged (property 12) is unwrapped into an extra mailbox with nesting refused at
  depth 1, overlap-safe copy and a 64-slot queue; `drainControl` refuses to consume
  a datagram it cannot queue precisely because `handlePacket` already ACKed it.
  Fuzzed.
  *Anchors:* `src/litenet/peer.zig:418-435`, `:369-410`,
  `src/litenet/server.zig:104-124`, `src/litenet/peer.zig:658`

- **Ping/Pong and MTU negotiation** `PARTIAL`
  zdtd answers Ping with an 11-byte Pong and echoes MtuCheck as MtuOk, but never
  initiates either. `max_packet_size` is hardcoded at 1327 with no discovery, so on
  a path with MTU below ~1355 every reliable datagram is dropped and the join dies;
  and with no outbound Ping there is no RTT estimate, so retransmit is a fixed
  80 ms regardless of link.
  *Anchors:* `src/litenet/peer.zig:482-508`, `src/litenet/packet.zig:15`,
  `src/litenet/peer.zig:26`

- **Per-channel sequence spaces** `PARTIAL`
  `sendSequenced` writes channel byte 1 but reuses the same local_seq, window and
  pending array as channel 2, and `flushAcks` unconditionally stamps channel byte
  2. A real LiteNet channel has its own sequence and window. Currently harmless
  only because `sendSequenced` has no callers.
  *Anchors:* `src/litenet/peer.zig:208-215`, `:559`

- **LiteNet Broadcast property (LAN discovery)** `MISSING`
  Property 11 (broadcast) and 16 (nat_message) fall into the `else => return null`
  arm. The server never answers a LAN discovery probe.
  *Anchors:* `src/litenet/peer.zig:509-511`

- **Peer timeout / stale reaping** `PARTIAL`
  Works, but the default `peer_stale_ms` is 3000 ms measured from the last received
  datagram of any kind. That is three missed pings on stock's 1 s ping interval,
  which is aggressive for real internet; a 3 s hiccup reaps the client slot and
  forces a full reconnect.
  *Anchors:* `src/server/game.zig:4081-4113`, `src/server/zdtd_config.zig:429`

- **Admin TCP console** `PARTIAL` (2026-08-06)
  The stock telnet protocol now ships: TelnetEnabled / TelnetPort /
  TelnetPassword / TelnetFailedLoginLimit are parsed, the greeting and password
  prompts match stock, the bind is loopback without a password and INADDR_ANY
  with one, and the reply text for listplayers, listplayerids, listents, help,
  getgamepref, chunkcache and mem matches the stock literals. admin, whitelist
  and ban lists persist. Open: client-only verbs are deliberately absent,
  TelnetFailedLoginsBlocktime is parsed but not enforced as a per-source block,
  and permission entries are keyed by login name because zdtd has no stock user
  id to key them by.
  *Anchors:* `src/server/admin.zig:21-27`, `:204-300`,
  `src/server/game.zig:2452-2470`, `:2001-2018`, `asm.il:204226-204320`

- **In-game player console (NetPackageConsoleCmdServer)** `PARTIAL`
  Handled and answered with ConsoleCmdClient, with a verb-only audit line and a
  read-only allowlist that correctly rejects settime/giveself/spawnentity/killall/
  kick/ban. The mutating branches inside `handleConsoleCmd` are therefore dead code
  for every client, since no permission level can unlock them.
  *Anchors:* `src/server/game.zig:2186-2260`, `src/server/c2s_text.zig:38-57`

- **Web dashboard** `PARTIAL`
  zdtd ships its own web UI with a required shared secret (min 8 chars,
  charset-validated), HMAC session token for cookie and CSRF, and a lockout after
  repeated bad tokens, loopback by default. It is not the stock WebDashboard:
  WebDashboardEnabled / WebDashboardPort / WebDashboardUrl are ignored and there is
  no webtokens / webpermission / createwebuser surface.
  *Anchors:* `src/server/webui.zig:1-40`, `:134-220`, `serverconfig.xml`

- **GameServerInfo TCP provider (direct connect)** `WORKS`
  Serves the stock 5-ASCII-digit plus CRLF length frame with a `Key:Value;CRLF`
  body on ServerPort, sanitizing CR/LF/; out of operator-supplied names and
  clamping player counts. The client's Connect then dials UDP at Port+2, confirmed
  in IL. Live: the client added 127.0.0.1 to history and joined.
  *Anchors:* `src/server/serverinfo_tcp.zig:43-135`, `asm.il:852360-852368`,
  `output_log_client_zdtd_connect.txt:3531`

- **Advertised ServerVersion string** `PARTIAL`
  Concrete wrong value with live evidence. zdtd advertises `ServerVersion
  "V 3.1.0"`. Stock sets `GameInfoString.ServerVersion` (key 9) to
  `VersionInformation.SerializableString` =
  `String.Format("{0}.{1}.{2}.{3}", ReleaseType, Major, Minor, Build)` =
  `"V.3.10.14"` for V3.1.0 b14. The client parses it with
  `TryParseSerializedString`, which requires exactly four dot-separated fields, so
  it fails and logs `Server browser: Could not parse version from received data
  (from entry: 127.0.0.1): V 3.1.0`. Not fatal because GameServerInfo's ctor seeds
  Major=-1 and `IsCompatibleVersion` short-circuits to true for a negative Major,
  but the browser row shows no version. zdtd's on-wire VersionInfo in
  NetPackagePackageIds already uses the correct tuple, so only the GSI text is
  wrong.
  *Anchors:* `src/version.zig:12`, `src/server/serverinfo_tcp.zig:56`,
  `output_log_client_zdtd_connect.txt:3531`, `asm.il:795818-795822`,
  `asm.il:2009306-2009320`, `asm.il:2009539-2009570`, `asm.il:793930-793950`

- **GameServerInfo key coverage** `PARTIAL`
  17 keys emitted. The `GameInfoString` enum has 20 values; zdtd omits
  ServerDescription(3), ServerWebsiteURL(4), SteamID(8), Platform(10),
  ServerLoginConfirmationText(11), Region(12), Language(13), UniqueId(14),
  CombinedPrimaryId(15), CombinedNativeId(16), PlayGroup(17), SandboxPreset(18) and
  SandboxCode(19). SandboxCode is where V3.1.0 keeps the difficulty/loot/XP preset,
  so the browser cannot show what the server is actually running.
  *Anchors:* `src/server/serverinfo_tcp.zig:49-68`, `asm.il:796457-796476`

- **Steam / EOS master-server registration** `MISSING`
  Nothing in `src/` registers with Steam matchmaking or EOS lobbies. The only
  advertisement is the direct TCP GSI provider, which the client reads once it
  already knows the address. `ServerVisibility` in serverconfig.xml is ignored. A
  player cannot find the server in the in-game browser.
  *Anchors:* `src/server/serverinfo_tcp.zig`, `serverconfig.xml:16`

- **serverconfig.xml property coverage** `PARTIAL`
  31 property names are applied and unknown ones are ignored with an edit-distance
  typo hint. But of stock V3.1.0's 69 properties only 11 overlap (GameName,
  GameWorld, ServerPort, ServerPassword, ServerMaxPlayerCount, PlayerKillingMode,
  MaxSpawnedZombies, MaxSpawnedAnimals, LandClaimSize,
  LandClaim{Online,Offline}DurabilityModifier). The other 20 names zdtd reads
  (GameDifficulty, BloodMoonFrequency, DayNightLength, XPMultiplier, LootAbundance,
  BlockDamage*, DropOnDeath, AirDropFrequency, Zombie*Move, ViewRadius, AdminPort)
  do not exist in stock V3.1.0 serverconfig.xml at all: stock moved them into the
  single SandboxCode string, which zdtd ignores entirely. Dropping a real stock
  serverconfig.xml onto zdtd yields default gameplay tuning with no warning.
  *Anchors:* `src/server/config.zig:94-127`, `:200-260`, `serverconfig.xml:103`,
  `asm.il:796475-796476`

- **Chunk save format** `PARTIAL`
  Works for zdtd, but is a private format and not interchangeable with stock. One
  file per chunk, `<world>/c_X_Z.zch`, magic ZCH3. There is no reader or writer for
  stock `Region/*.7rg`, so a stock save cannot be imported and a zdtd world cannot
  be opened by the stock server or singleplayer. Validation rejects torn records
  and is fuzzed.
  *Anchors:* `src/world/store.zig:694-695`, `:702-727`, `:736-780`

- **Player save (players.zsv)** `PARTIAL`
  ZPV2 records keyed by **login name** (not platform id, so two players with the
  same name share a save and a rename loses it). Each record holds position, coins,
  up to ~60 inventory slots and journal quests. Absent: health, stamina, food,
  water, temperature, buffs, XP and level, skills and perks, equipment/armour,
  toolbelt-vs-backpack layout, bedroll and spawn point, map exploration, waypoints,
  kill/death stats, gamestage. Offline records are correctly carried over on
  merge-write and a corrupt file aborts the save instead of clobbering.
  *Anchors:* `src/server/game.zig:1744-1864`, `:1885-1960`, `:2600+`

- **Container / loot persistence** `PARTIAL`
  `containers.zct` (ZCT1) persists position, block id, slot count, touched and
  player-storage flags plus item slots, sorted by world position for deterministic
  bytes. Hard cap `max_containers = 256` world-wide, and `save()` silently `break`s
  once the fixed buffer is full. A single large POI has more lootable containers
  than that; the 257th chest silently loses its contents.
  *Anchors:* `src/world/containers.zig:9-11`, `:129-181`

- **Block rotation and damage persistence** `PARTIAL`
  Two global fixed arrays: `block_raw` is 128 entries and `block_hp` is 64, both
  world-wide, and `setBlockRaw` evicts the oldest with an O(n) shift when full.
  `saveBlockMeta` writes into a 4096-byte stack buffer and `break`s when it fills.
  The 129th rotated block a player ever places makes the first one's rotation
  revert to 0 while the server is still running, with no log. Partial block damage
  survives for only the last 64 damaged blocks.
  *Anchors:* `src/server/game.zig:461-467`, `:3305-3325`, `:3350-3402`

- **Block rotation in streamed chunks** `PARTIAL`
  The SetBlock handler calls `world.setBlockWorld(x,y,z,place_id)`, which stores the
  u16 id, so the upper 16 rotation/meta bits never reach the chunk. `blockRawAt` is
  consulted only for the SetBlock echo, the power registry and the damage path,
  never by the chunk encoder. A second client streaming that chunk, or the same
  client after a relog, sees every player-placed door, wedge and shape in default
  rotation.
  *Anchors:* `src/world/store.zig:260-262`, `:653-658`,
  `src/server/game.zig:5183`, `:5194-5197`, `:5213-5219`

- **Land claim persistence** `MISSING`
  `land_claims` is a 256-entry in-memory array; `deinit` sets `land_claims_n = 0`
  and nothing ever writes it to disk or reads it back. After any restart every
  keystone stops protecting its area, even though the keystone block is still in
  the world.
  *Anchors:* `src/server/game.zig:416-417`, `:1704`, `:3145-3172`

- **Vehicle, turret, power and quest-NPC persistence** `MISSING`
  No save/load path exists for spawned vehicles, turrets, the power grid graph or
  trader/NPC quest offer state. Park a minibike or wire a generator bank, restart,
  and it is gone.
  *Anchors:* `src/server/game.zig:1686-1706`, `:8130-8146`

- **Autosave and shutdown save** `WORKS`
  Every 100 ticks (5 s at 20 Hz) the tick flushes world chunks, containers and
  block meta, plus players when dirty. `deinit` repeats all four and drains the
  async chunk flusher. Admin `save` and `saveworld` report failure honestly instead
  of claiming success.
  *Anchors:* `src/server/game.zig:8130-8147`, `:1686-1706`, `:2551-2571`,
  `:2809-2827`

- **Save on disconnect / kick** `MISSING`
  `dropClientSlot` and `reapStalePeers` both do `clients[slot] = .{}` with no
  `savePlayers` first, and `NetPackagePlayerDisconnect` (the one stock ToServer
  package with no handler) is ignored, so a clean quit is not even noticed. Up to
  one autosave interval (5 s) of movement, loot and quest progress is discarded on
  every disconnect and on every admin kick.
  *Anchors:* `src/server/game.zig:6586-6591`, `:4081-4113`,
  `src/server/phase_gate.zig:32`

- **Per-peer memory footprint** `PARTIAL`
  Each Peer statically embeds `asm_parts[512][1317]` (674 KiB), two 512 KiB buffers
  and `pending[64]` of 1327-byte slots, i.e. roughly 1.8 MiB per peer, times
  `max_peers = 64` gives about 115 MiB of Server struct resident regardless of how
  many players are online. Plus Game's own send_buf 256 KiB, body_buf 512 KiB,
  recv_buf 64 KiB and payload_hold 64 KiB.
  *Anchors:* `src/litenet/peer.zig:154-167`, `src/litenet/server.zig:8-13`,
  `src/server/game.zig:366-377`

- **Fuzzing of the network trust boundary** `WORKS`
  `parseConnectRequest`, `parseChannelPayload` (including the compressed path), the
  package decoders, the binary reader, admin command parsing, GSI text and Peer
  state are all under `std.testing.Smith` fuzzers. Real coverage of the untrusted
  input surface, though it says nothing about wire correctness.
  *Anchors:* `src/fuzz.zig:49-140`, `:169-330`, `:431-458`, `:825+`,
  `src/litenet/peer.zig:658`

---

## Not verified

Read this section before treating any row above as settled. Silence is not a
pass. Everything below is a limit on the evidence, not a defect list.

### No live client observation exists for these claims

- **Zombie melee never reaching the client.** Derived from two unambiguous code
  facts (`Dirty.hp` has no consumer; the tick replicate pass sends no stat) plus
  the stock IL that does send it. No playtest has a zombie kill a player: the
  `finale/player_death` case used an admin kill.
- **Respawn zeroing food and water on the client HUD.** The server-side zeroing
  and the send are certain; that the client applies `Stat.Value` to the local
  player is IL-derived (`asm.il:201999`). No screenshot or post-death client log.
- **The empty trader window.** No live stock client was stood up to confirm it.
  The claim rests on the IL direction gate plus the two missing delivery paths,
  three independent code paths pointing the same way.
- **The `tier1_*` "Failed loading objectives" prediction.** IL-derived from
  `Quest::Read`'s `ValidateSizeMarker` path; never observed on a client.
- **The death backpack never appearing.** Grounded in zdtd refusing
  `NetPackageRequestToSpawnEntity` and in `dropBackpack` ending at
  `RequestToSpawnEntityServer`. Not observed in-client.
- **On-screen consequences of the all-broken topsoil bitfield, the uniform light
  seed, the binary density and the missing water channel.** Inferred from the
  encoder plus the stock read path, not observed.
- **Whether the client's local `StabilityCalculator` produces a visible collapse
  against a zdtd server.** The mechanism is IL-grounded; the in-game outcome is
  not.
- **The block repair defect.** Code and IL grounded, not reproduced live.
- **Whether a stock MP client still renders distant-POI imposters from its own
  local `prefabs.xml`,** which would make the rotation error visible as an
  imposter-vs-blocks mismatch. The playtest ran with
  `DynamicMeshUseImposters=False`.
- **Sleeper spawning, container opening and loot contents.** Code and IL grounded
  only; no live observation of the resulting items.
- **The "animals attack the player" and "frozen ghost" findings.** Derived from
  code paths (no kind gate in `canExecute`; `known_entities` only cleared on
  death), not from an observed session. Both paths are unambiguous.
- **Food and water never decaying.** A negative grep result over every write to
  `health[].food` / `health[].water`. Confident, but a negative grep is weaker
  than a positive trace.

### No blood moon has ever been reached in a playtest

No run in `~/.cache/zdtd-playtest` has actually reached a blood moon. The
`combat/blood_moon_music` case only asserts that the client clock reached night;
the host telnet sends `settime 22000`, which zdtd parses as **day** 22000. The
client log contains only the pre-connect GameStat dump
(`GameStat.BloodMoonDay = 0`) and the DynamicMusic Bloodmoon section preload, so
the BloodMoonDay value the client actually received, the red moon, the red clock
and the blood-moon music firing were all unobservable. Every claim about
client-visible blood-moon behaviour is IL-derived.

### Session-specific evidence gaps

- **Items, crafting and loot:** the client log for that session contains no chest
  open, no craft, no workstation and no TileEntity or exception lines at all, so
  nothing in that area has live stock-client evidence from it. The only live
  datapoints are `docs/archive/PLAYTEST_V310_20260803.md:53` (craft queue does not
  consume) and `:71` (bag slot waste), which line up with the stack-default and
  instant-craft findings. `docs/WIRE_WORKSTATION.md:174` itself states there has
  been no live-client workstation playtest, so the workstation **WORKS** rows rest
  on IL grounding plus the scenario test.
- **Entities and AI:** the client log path referenced by the audit task does not
  exist; the surviving `output_log_client__<date>.txt` files contain only
  GamePref/GameStat dumps with no entity-spawn traces. The client-side evidence
  for that area is entirely the 83-case junit playtest results.
- **Traders:** the client log for the zdtd connect is 155 lines and contains zero
  occurrences of "trader" or the direction-rejection warning, so it neither
  confirms nor refutes the drop empirically. It does confirm no trader window was
  ever opened in that session.
- **World systems:** the server was not run and no client was attached during that
  audit; all wire claims are encoder-plus-IL.
- **Net and ops:** LiteNetLib is a separate assembly and is **not** in `asm.il`
  (only `.assembly extern LiteNetLib`), so the PacketProperty ordinals,
  window_size 64, max_sequence 32768, ack payload size, MTU 1327 and the fragment
  header layout rest on prior research plus the fact that a stock client completes
  the handshake and streams chunks. Only channelNumber 0 and DeliveryMethod 2 or 4
  were confirmed from the game-side IL. Counts of handled and sent package names
  come from regex over `game.zig`, so a name reached through an indirect helper
  could be undercounted.
- **Quests:** no playtest evidence of a quest being accepted, tracked or completed
  on the stock client. It was also not verified whether the stock client
  independently auto-accepts the starter quest on top of the one zdtd sends.
- **POIs:** the DTM smooth-slope half of the sub-block-precision finding rests on
  `dtm.raw` storing `gameY*256` plus `MarchingCubes::DensityTerrain` existing, not
  on reading the stock generator code.

### Documentation that this analysis contradicts

Refresh these when the underlying work lands; the contradictions are recorded so
nobody re-opens a closed row from a stale one.

| Doc row | This analysis says |
|---|---|
| `GAP_ANALYSIS.md:588-605` and `STATUS.md:143`: trader window shows real `traderAlways` stock | Not supported by the IL. `NetPackageTraderData` is ToServer-only and dropped by the client (asm.il:843057, :787291); no trader entity exists client-side either |
| `GAP_ANALYSIS.md:535` and `:612`: traders.xml group refs are skipped | They are expanded recursively with a test against the real stock file (`src/assets/traders.zig:54-82`) |
| `GAP_ANALYSIS.md:339`: "Player respawn rules | HAVE" | PARTIAL: fixed spawn point, zeroed food and water, no bedroll |
| `GAP_ANALYSIS.md:340`: "Death / backpack | PARTIAL (DropOnDeath loot bag modes)" | Understates it: the bag content is a hardcoded single scrap and the real stock backpack request is refused |
| `STATUS.md:32`: "Player death to respawn | PASS" | The gate passed on an admin kill, which does not exercise the AI-damage path that is actually broken |
| `GAP_ANALYSIS.md:889`: NetPackageHordeEvent line range 818538-818735 | Stale for the 2026-08-05 dump; the class is at asm.il:822185-822359 |
| `src/ecs/quest.zig:68` comment: `Quest::AdvancePhase` at 982816 | Stale; that line is inside `ObjectiveTreasureChest` in this dump. AdvancePhase now ends at 986686, `refreshQuestCompletion` is 987390-987648, `Quest::Write` is 988813-989038 |
| `src/wire/stock_quest.zig` `ObjectiveWriteKind` comment implying two non-default shapes | There are four: BaseObjective, POIStayWithin (empty), StayWithin (also empty, unnamed in the repo), TreasureChest, plus ObjectiveTime's single u16 |

### Method caveats that apply everywhere

- Every wire claim is grounded in IL or in a live stock-client observation.
  zdtd's own round-trip unit tests were never accepted as wire evidence.
- All `asm.il` line numbers are for the **2026-08-05** dump. Line-number drift
  against older repo comments is real and, in the NetPackage region, about 3500
  lines.
- No zdtd source was modified by any auditor; `git status --porcelain` was clean
  after each audit. Probes were built in scratchpad copies and deleted.

---

## Appendix A. Area narratives and deep dives

Merged from the former GAP_ANALYSIS.md on 2026-08-06. This is the long-form
background: why an area looks the way it does, what stock does that zdtd does
not, and the deep dives. Per-feature state lives in sections 4 to 12 above and
wins on any disagreement; these narratives carry reasoning, not scoring.

Status tags used below: **HAVE** shipped enough to exercise, **PARTIAL** exists
but not at client parity, **MISSING** not implemented, **OUT** explicit non-goal.

### 1. Network / LiteNet

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

### 2. Join, auth, session

| Item | Status | Notes |
|---|---|---|
| Challenge `0xCA` + Guid16 echo | HAVE | |
| `NetPackagePackageIds` map | HAVE | **negotiated** 189-name list (full stock subset) |
| `NetPackagePlayerLogin` parse | PARTIAL | full field walk (asm.il 832140): name + both `PlatformUserIdentifierAbs`; auth tokens skipped (no authorizer chain) |
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
| Reconnect resume | PARTIAL | players.zsv v2 keyed **by login name**, not by identity: a client can claim another player's save by picking their name. Stock keys the PDF on `PrimaryId.CombinedString` (asm.il 1884842). Re-keying needs a save migration; tracked in §10 |
| Crossplay platform users | PARTIAL | both identities decoded and stored per client; `InternalId` = crossplatform else native (asm.il 783909); no platform verification (EAC off) | |

---

### 3. Package surface (~194 stock vs ~189 zdtd)

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
| `NetPackageDecoUpdate` / deco reset | PARTIAL (join-time burst around spawn. Species and density are biome-driven: biomes.xml `<decorations>` filtered by resolved `IsDistantDecoration`, sampled with stock's `decorateChunkRandom` shape (128x128 deco chunks, 1000 attempts, `prob * 0.125f * 16f`). Placed deco is mirrored into the block store (`[feature] deco_mirror`) with stock's `ischild`/parent packing for multiblocks. Client still has ONE deco window: `loadedDecos` is nulled at the end of `OnWorldLoaded`, so nothing outside the join view square is ever decorated. Residuals: deterministic PRNG instead of `GameRandom`, no `CheckOreNoiseAt`, rotation always 0, subbiome noise not evaluated. `DecoResetWorldChunk` on view unload removed (not stock). See [DECO_NRE.md](archive/DECO_NRE.md)) |
| `NetPackageIdMapping` "blocks" | HAVE (full AssignIds dump sent before the config files, in the stock slot; envelope raw-deflated like `NetConnectionAbs::Compress`. All-or-nothing with `[feature] block_id_mapping` kill switch. Needs one live V3.1.x client run to confirm) |
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
| `NetPackageEntityStatChanged` / stats / buffs | PARTIAL (join sends Health/Stamina/Food/Water stock body; player Health also replicates from the tick pass whenever `dirty.hp` is set, so AI melee, C2S damage and death reach the client the way `EntityStats::TickWait` polls `Stat.Changed` (asm.il:199393); NPC stats and buffs deferred) |
| `NetPackageEntityStatChanged` / stats / buffs | PARTIAL (join sends Health/Stamina/Food/Water stock body; buff set is server-owned via AddRemoveBuff) |
| `NetPackageEntityAttach` / detach | HAVE (server resolves slot, replies AttachClient/DetachClient) |
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
| `NetPackageAddRemoveBuff` / `EntityStatsBuff` | PARTIAL (AddRemoveBuff C2S validated + S2C relay/expiry; EntityStatsBuff full-list sync on join; PDF `buffData` still empty, no cvar section) |
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
| Quest POI marker / rally | PARTIAL (`NetPackageQuestEvent` rally-marker + Lock/UnlockPOI handled; POIPosition/POISize on Quest.Write; rally engages only for quests placed in a prefab) |

#### Vehicles / mounts
| Package | Priority |
|---|---|
| Stock vehicle packages (beyond simplified trio) | P1 |
| Seats multi-occupant | HAVE (base seats from vehicles.xml; no seat-mod budget) |
| Fuel / storage as items | P1 |
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
  `noteAcceptedMove`) opens it. The gate now honours the trigger's stock
  `TriggerPowerDelay` / `TriggerPowerDuration` (`triggerDelaySeconds` /
  `triggerDurationSeconds`, asm.il:900414 and 900579): Always latches until a
  reset, a numeric duration holds for its seconds, and Triggered still falls
  back to `default_trigger_pulse_s` because zdtd has no "contact released"
  event. Class=Switch / ConsumerToggle register as `is_switch` gates driven by
  BlockValue meta bit 0x2, which arrives on the SetBlock path
  (`BlockSwitch::updateState` -> `SetBlockRPC`, asm.il:136663), not as a TE
  payload. Grid state goes back out as zdtd's `Block::ActivateBlock` equivalent:
  an edge-triggered `NetPackageSetBlock` rewriting meta bit 0x1 (isPowered) and
  0x2 (isOn) per node (asm.il:127088 / 137044 / 1323820). The
  TileEntityPoweredTrigger ClientTriggerData payload is encoded and decoded in
  `wire/stock_te.zig` (both directions, asm.il:1325813 / 1326015).
  Gaps: `PowerTimerRelay` StartTime/EndTime hour semantics (Property1/Property2
  are carried but a TimerRelay still runs on the old `armTimer` period), Motion
  sensor ownerID and TargetTypes filtering (TargetType is parsed and echoed, not
  enforced), multi-parent directed edges, and the S2C TE leg only lands where
  the client already holds a TileEntity: zdtd streams chunks with tile-entity
  count 0 (`stock_chunk.zig`), and `NetPackageTileEntity::ProcessPackage`
  (asm.il:842860) drops an update for a position with no TileEntity. That leg is
  unverified against a live client; the SetBlock/meta legs are the ones that
  render today.
- *RemoveParent precision*: stock removes exactly the child→parent edge
  (`PowerItem.RemoveSelfFromParent`, asm.il:843033). zdtd wires are undirected,
  so `removeParentAt` drops all edges incident to the node. Matches the common
  single-wire case; multi-parent topologies differ.
- *TileEntity wire-data persistence / SendWires visual path*
  (`CreateWireDataFromPowerItem`/`SendWireData`, asm.il:842993) is client visual;
  zdtd does not persist per-TE wire lists, only rebroadcasts the raw package.
- *AssignIds version skew*: the bundled `assignids_v314.txt` is V3.1.4 while the
  target client is V3.1.0(b14). If block ids differ, registry lookup silently
  no-ops (blocks place normally, just not power-registered). Supply a V3.1.0 b14
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

### 4. World representation and maps

| Item | Status | Notes |
|---|---|---|
| Flat default world | HAVE | sea_level height plane |
| Stock DTM load (Navezgane/Pregen) | HAVE | u16 LE gameY×256, center origin |
| Spawnpoints.xml | HAVE | first spawn |
| prefabs.xml footprints | HAVE | AABB flatten + TTS interior paint; prefab `.xml` `YOffset` applied to the stamp origin (caves/mines/bunkers land below grade) |
| `.tts` full block paint | PARTIAL | types + density/damage/TE/water/texture planes; name remap if tables diverge |
| prefabs.xml footprints | HAVE | AABB flatten + TTS interior paint |
| `.tts` full block paint | PARTIAL | types + density/damage/TE/water/texture planes; prefab-local ids remapped by name via `<name>.blocks.nim` (`Prefab::loadIdMapping`), pre-18 files converted from `BlockValueV3` |
| water_info.xml | PARTIAL | height hints only |
| biomes.png / radiation | PARTIAL | biomes.png color→biomemap; radiation MISSING |
| RWG / procedural gen | PARTIAL | W0–W2: on-the-fly per-chunk 3D density gen (`y_clamped_gradient` + coarse-cell interp, real overhangs, single biome) via `--worldgen-seed`. MISSING: fluids/aquifers (dips are dry pits), 6-axis climate/biomes, carved caves, POI/WFC placement, async gen workers. Not stock RWG host |
| Full block columns (16×256×16) | HAVE | dirt/stone/bedrock from height + TTS paint + ZCH3 `.zch` |
| Density / stability / shape / paint | PARTIAL | density channel; stability plane WORKS (support/falling per `stability.zig`) |
| Stock layer model (`y>>2`) | PARTIAL | stock chunk encode path |
| Stock `NetPackageChunk` blob | HAVE | `stock_chunk.zig` + upper24; live CGO |
| `.ttc` region files | MISSING | custom ZCH3 `.zch` + blockmeta |
| RegionFileRaw headers / sectors | MISSING | RE partial |
| Chunk unload / streaming policy | PARTIAL | join r≤4 stream + resident cap 4096 LRU |
| Multi-block entities (doors) | PARTIAL | storage open pair; generic door meta shallow |
| Water flow / physics | MISSING | |
| Falling blocks | MISSING | |
| POI sleeper volumes from prefab | PARTIAL | AABBs + group/count + authored sleeper* markers + gamestage group→spawner→stage→entitygroup chain. Gaps: respawn, trigger cascade, quest/boss flags, pose, per-volume stage adjust |
| Land claim / bedroll spawn | PARTIAL | LandClaim options + keystone deny; bedroll ownership MISSING |
| World borders / difficulty tiers | MISSING | |

---

### 5. ECS simulation (entity systems)

### 5.1 Present components / systems

HAVE/PARTIAL: Transform, Health, NetworkId, Kind, Player, Journal, Wallet, ZombieAi, Vehicle, Turret, TraderStock, Flags; systems AI (LOD chase/melee), Director clock/hordes, vehicles stick, power BFS, turrets; parallel AI/turrets/save; max 512 entities.

### 5.2 Missing entity / AI features

| Item | Status |
|---|---|
| Entity class system (`entityclasses.xml`) | HAVE (`assets/entities.zig`) |
| Archetypes / gamestages / spawning.xml | PARTIAL (`assets/gamestages.zig` + spawning.xml `<biome>`/`<entityspawner>`; archetypes MISSING) |
| Animals / special infected / bosses | PARTIAL (animals spawner + cap; bosses MISSING) |
| EAI task graphs | PARTIAL (see 5.2.1) |
| Sleeper AI volumes | PARTIAL (prefab .tts/.nim markers) |
| Pathfinding (grid A* / navmesh) | PARTIAL (grid A* + BFS + greedy over a body-aware step predicate: step-up 1, drop 3, 2-cell headroom; 8-cell waypoint buffer + per-tick replan budget; no navmesh, no jump/climb) |
| MoveHelper physics / collision | MISSING |
| Gravity / swimming / climbing | PARTIAL (void rescue teleport; vehicle gravity) |
| Line of sight / hearing / smell | MISSING |
| Stealth / crouch | MISSING |
| Group AI / pack behavior | MISSING |
| Despawn / cull by observer | PARTIAL (LOD + far-despawn >200 + alive-cap 24; leaving a client's interest box now sends that client `EntityRemove(Unloaded)` and drops the `known_entities` bit, matching `NetEntityDistributionEntry::updatePlayerEntity`) |
| Entity pooling / soft cap policies | PARTIAL (MaxSpawnedZombies/Animals options) |
| Ragdoll / death loot bags | PARTIAL (loot ECD bag; no ragdoll) |
| XP / progression / skills | PARTIAL (awardXp ledger; skills MISSING) |
| Buffs / disease / food/water/temp | PARTIAL (buff set + stack/duration ticks + wire; disease/temp effects MISSING) |
| Inventory component | HAVE (toolbelt/bag/equip + InvTx) |
| Equipment / armor mitigation | PARTIAL (equip slots; mitigation shallow) |
| Projectile / ranged combat | MISSING |
| Block damage from zombies | PARTIAL (`tickZombieBlockDamage`) |
| Player respawn rules | HAVE (death → RequestToSpawnPlayer heal-when-dead) |
| Death / backpack | PARTIAL (DropOnDeath loot bag modes) |
| Party (membership) | MISSING (PartyActions/PartyData echoed to sender; no Party state) |
| Allies | PARTIAL (identity-keyed AllyStore + AllyResponse; not persisted) |
| Spatial hash for queries | MISSING (broadcastNear radius only) |
| Dense free-list compaction | PARTIAL (scan free slots; cached per-Kind alive groups, `src/ecs/group.zig`) |
| Whole-world per-tick scans | PARTIAL (kind groups cover players/zombies/vehicles; replicate walks `World.alive_bits`/`dirty_bits` and the dirty clear is O(changed); the interest *query* is still a per-entity observer mask, no cell hash) |
| NetId → slot map (O(1)) | HAVE (`World.net_to_slot`; documented linear fallback only when the map is degraded) |
| Interest-aware tick budgets | MISSING |

#### 5.2.1 EAI task graphs (PARTIAL)

IL line numbers in this section are `asm.il` (V3.1.0 b14) unless a citation says
otherwise. Older EAI citations in this file and in `src/ecs/` were taken from
`asm_v301.il`, whose numbering is offset by roughly +680 for these classes
(EAIBreakBlock is asm_v301.il:425121 but asm.il:425801); check which dump you
are reading before quoting a line.

`AiCtx.work` (`src/ecs/systems.zig`) ports stock's prioritized task-selection
loop `EAITaskList::OnUpdateTasks` + `isBestTask` (asm.il:437713, :437874): an
ordered task table with `{priority, MutexBits, executeDelay, continuous}` per
task, "best task" selection by priority + mutex overlap, per-task re-eval
timer, and Start/Update/CanExecute/Continue hooks. The winning task is
projected onto the coarse `ZombieAi.state` enum so all downstream replication
stays unchanged.

Eight real tasks are registered in the comptime `zombie_tasks` table, in the
stock AITask order: BreakBlock, DestroyArea, RunawayWhenHurt (MutexBits=1 from
its .ctor, EAIBase defaults for executeDelay/continuous; asm.il:435616, flee
distance 20 from `EAIRunAway::.ctor`, asm.il:434801),
ApproachAndAttackTarget (chase+melee, MutexBits=3, executeDelay=0.1,
non-continuous; asm.il:421798), Territorial, ApproachSpot, Look (MutexBits=1,
executeDelay 0.5 from the EAIBase::Init default, continuous; asm.il:429858),
and Wander (MutexBits=1, continuous; asm.il:438104). Chase preempts wander on
sensing a player; wander resumes when the target is lost (mutex release),
exactly reproducing stock's emergent order. RunawayWhenHurt is gated on
`kind == .animal`, standing in for the fact that only the passive-animal
classes carry it in `entityclasses.xml` while zdtd runs animals on the zombie
table.

The head of the stock AITarget list is modeled too. `EAISetAsTargetIfHurt`
(asm.il:435831; CanExecute ends :436139, Start ends :436169) promotes the
attacker to the attack target for the 400-tick window `Start` passes to
`SetAttackTarget` (asm.il:436155). `NetPackageDamageEntity::read` carries
`attackerEntityId` (asm.il:810693), so `World.damageFrom` records it as the
revenge target and `applyRevengeTarget` overrides the nearest-player pick while
it is fresh, keeping CanExecute's "attacker is a different entity type" gate. It
is applied as a target-selection override rather than a second task table,
because zdtd collapses the whole AITarget list into `nearestPlayerSnap`. The
`class=` filter is not modeled: zdtd damage attribution only ever names a player
or a turret.

`Reset()` and a `Continue() != CanExecute()` split are both modeled, because
Look needs them: `EAITaskList::OnUpdateTasks` calls `action.Reset()` on the same
path that clears `isExecuting` (asm.il:437713, IL_006F), and only two Reset
overrides in the whole assembly seed `EAIManager.lookTime` -
`EAIWander::Reset` (RandomRange(0.5, 5), asm.il:438383) and
`EAIApproachSpot::Reset` (5 + rand\*3, asm.il:424395). Wander's own
`Continue()` (asm.il:438318) is a real override that stops on the 30 s cap and
on "path finished"; before Look landed, zdtd reused CanExecute for both, so
wander never terminated on arrival. The resulting loop is stock's: wander until
the destination is reached (or preempted by a chase), then stand still and slew
body yaw (`Entity::SeekYaw`, asm.il:399475) toward a fresh +/-60 deg pick every
0.7 s (asm.il:429984-430001) for the owed 0.5-5 s (5-8 s after an investigate
spot), then wander again. Only body yaw is involved, which zdtd already
replicates via `NetPackageEntityPosAndRot`.

Honest gaps:

- **Grid A\* (no navmesh).** Approach replans via `path.aStarToward` on a
  coarse XZ grid when `World.step_fn` is set. The predicate is a *move* test,
  not a solid-cell test: `store.Chunk.standableY` returns the feet Y the body
  would occupy in the destination column, so step-up (1), drop (3) and
  2-cell headroom are all part of the search, and the followed path carries its
  Y (entities now walk terrain instead of floating at spawn height). Without a
  hook the grid is open and flat and movement falls back to straight
  `stepToward`. One solve fills an 8-cell waypoint buffer that is followed
  across ticks, so a chase costs roughly one search per 8 m rather than one per
  metre; replans happen when the buffer empties, the goal leaves its cell, or a
  blocked path is due for a retry (~0.35 s). A per-tick node budget
  (`World.path_replans_per_tick` = 16 solves x `path_max_expand` = 96
  expansions) admits replans by a stride derived from last tick's demand;
  admission is a pure function of slot and tick number, never a shared atomic,
  because the AI phase runs on parallel ranges and a countdown would make chase
  paths depend on worker scheduling. Refused ticks keep walking the buffer and
  are counted as `path_replans_denied`. Nodes are still keyed on XZ only, so a
  column reachable at two heights resolves to whichever the search found first.
  No navmesh, no jump/climb, no stock pathCounter/relocateTicks fidelity.
- **Five EAI tasks stay unimplemented, each on a hard missing dependency.**
  **BLOCKED (2026-08-07):** each needs a subsystem or data source that does
  not exist yet (client animator state, vertical movement / MoveHelper
  physics, item actions + projectiles, per-class task graphs, dropped-item
  entities with item-class flags). Not inventable without those subsystems;
  the dependencies below are the evidence.
  - *EAIDodge* (asm.il:426512): CanExecute reads the target's
    `avatarController.IsAnimationToDodge()` and Start calls
    `StartAnimationDodge` - client animator state the server does not have.
    Independently dead data: no entity in stock `entityclasses.xml` or
    `npc.xml` declares a Dodge AITask.
  - *EAILeap* (asm.il:429498, MutexBits 3, executeDelay 1+rand): needs
    `jumpMaxDistance`, `moveHelper.BlockedFlags`, `navigator.getPath()`,
    `BodyDamage::IsAnyLegMissing`, a capsule `Physics.Raycast` (mask
    0x40810000) and `moveHelper.StartJump`. zdtd has no vertical movement
    integration (see "MoveHelper physics / collision" above). Users:
    zombieSpider, animalMountainLion.
  - *EAIRangedAttackTarget* (asm.il:433404, MutexBits 0b1011, cooldown 3,
    attackDuration 20, minRange 4, maxRange 25): sequences anim states then
    calls `UseHoldingItem`/`IsHoldingItemInUse`; the projectile comes from the
    held `ItemActionRanged`. zdtd has neither item actions nor projectiles.
    Users: zombieRancher/PlagueSpitter, zombieChuck, mutated/vulture classes.
  - *EAIRunawayFromEntity* (asm.il:435190, base EAIRunAway asm.il:434778):
    needs a fear-source scan over nearby entity classes (`EAIRunAway::FindFleePos`
    plus the class filter), which zdtd's single nearest-player sense cannot
    express. Its sibling *EAIRunawayWhenHurt* (asm.il:435616) is implemented:
    see the revenge-target note below.
  - *EAIApproachDistraction* (asm.il:423700): needs `EntityAlive.distraction`
    to be a dropped `EntityItem` whose `ItemClass.IsEatDistraction` is true,
    plus `AINoiseSeekDist` (8 for zombieTemplateMale). zdtd has no dropped-item
    entity carrying item-class flags.

  (There is no EAISeekSmell class in stock; do not add one.)
- **Look is body-yaw only.** `EAILook::Continue`'s `lookAtTicks` / 40-tick
  `SetLookPosition` branch (asm.il:430022-430072) aims the head/eye rig; zdtd
  replicates body yaw only, so only the `turnTicks`/SeekYaw branch is ported.
  Look's `IsAlert` double-drain of waitTicks and its `bodyDamage.CurrentStun`
  bail (asm.il:429937-429978) are also dropped: Approach always preempts Look
  before it could be alert, and there is no stun model.
- **SeekYaw is per-tick, not the stock two-phase slew.** Stock stores
  `yawSeekAngle`/`yawSeekAngleEnd`/`yawSeekTimeMax` and interpolates inside
  `Entity`'s own update; `seekYawStep` applies the same speed law (quadratic
  slowdown inside 35 deg, 20 deg/s floor) directly per tick. Same endpoint and
  same rate law, different integration. `MaxTurnSpeed` is pinned to the
  zombieTemplateMale value 250 deg/s because `World.EntityClass` carries no
  per-class turn speed; stock values span 100-420 across classes.
- **No data-driven per-class task graphs.** Stock builds the list from
  `entityclasses.xml` `AITask-N`/`AITarget-N` strings via
  `EAIManager::ParseTasks`/`CreateInstance` (asm.il:430620), and
  `EAITaskList::AddTask` (asm.il:430495) uses the 1-based list index as the
  priority. The stock dedicated-server config ships that XML
  (`Data/Config/entityclasses.xml`); zombieTemplateMale's list is
  `BreakBlock | DestroyArea | Territorial | ApproachDistraction |
  ApproachAndAttackTarget | ApproachSpot | Look | Wander`, i.e. priorities
  1..8 in that order. Parsing it per class is unimplemented for scope reasons,
  not for lack of data: priority/MutexBits/executeDelay/continuous are
  hardcoded in the comptime `zombie_tasks` table. That table compresses
  priorities to {1,1,1,2,2,2,2} (same pairwise `isBestTask` relations for the
  implemented subset), orders Territorial *after* Approach, and adds a "no
  sensed player" clause to `territorialCanExecute` that stock's
  `EAITerritorial::CanExecute` (asm.il:437973, home distance only) does not
  have - in stock, Territorial (priority 3) genuinely preempts a chase.
- **Single-task executing set.** `executingTasks` is collapsed to one
  `active_task` TaskId. Exact for the current table (BreakBlock mutex 0 can
  switch with Approach via table order; movement tasks including Look are all
  mutex 0b01 and therefore exclusive anyway), but a continuous
  non-conflicting task would need a task bitset.
- **Ultra-far LOD bypasses selection.** Beyond `full_ai_dist_sq * 4` the work
  loop forces `active_task = .wander` without consulting CanExecute, so distant
  zombies never look around and a pending `look_time` sits unconsumed until
  they come back in range.
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
| Gamestage scaling | PARTIAL (player/party stage, scout tier, blood-moon stage, sleeper groups, loot prob bands; see 5.x gamestage gaps) |
| Heat map / activity | MISSING |
| Wandering horde paths | MISSING |
| Feral sense / blood moon music sync | MISSING |
| Sleeper wake cascade | MISSING |
| Persistent director state save | MISSING |

---

### 6. Quests, traders, dialog

| Item | Status |
|---|---|
| Builtin 3 quests | HAVE (real phase graphs) |
| Load stock `quests.xml` catalog | PARTIAL (~defs mapped; many templates shallow) |
| Multi-phase objectives | PARTIAL (real ordered phase graph; see gaps below) |
| ClearSleepers volume clear | PARTIAL (kill counter drives the kill phase; no volume/spawn sim) |
| Fetch container / treasure | PARTIAL (fetch phase counter; no container/treasure sim) |
| RandomPOIGoto / rally markers | PARTIAL (Goto phase by location; RallyPoint executes via `NetPackageQuestEvent` when the quest lands in a prefab, otherwise still scaffolding) |
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
- **Scaffolding phases auto-complete.** POIStayWithin and empty intermediate
  phases map to `PhaseKind.auto` and complete on entry. RallyPoint is now
  `PhaseKind.rally` and waits for the client's `TryRallyMarker`, but only when
  the quest instance carries a POI rect: the server resolves one from
  prefabs.xml at accept time, and a quest that lands outside every prefab keeps
  the old auto-skip so it cannot stall (the client only emits the event when it
  finds a `Rally` indexed block inside the quest's POI rect,
  `QuestJournal.HasQuestAtRallyPosition` asm.il 1006297).
- **UnlockPOI is an action, not an objective.** Stock resolves `<action>` via
  the `QuestAction` prefix (asm.il 1390609), so `QuestActionUnlockPOI`
  (asm.il 956062) never was a phase. Its server half is the POI lockout table:
  the `UnlockPOI` quest event releases the lock. `<action>` elements are still
  not parsed from quests.xml, so nothing triggers an unlock but the client.
- **POI lockout reasons are partial.** `questCheckPoiLockout` reports
  `QuestLock` (live lock in `ecs/poi_lock.zig`) and `PlayerInside` (another
  player standing in the prefab rect). `Bedroll` and `LandClaim` need home /
  claim tracking the server does not have, so they never fire. Party members
  are not exempt from `PlayerInside` because zdtd tracks no parties.
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

### 7. Vehicles, electricity, turrets, blocks as systems

| Item | Status |
|---|---|
| Vehicle kinds + enter/drive | PARTIAL (arcade physics) |
| Stock vehicle definitions XML | MISSING |
| Multi-seat | HAVE (seat0..N from vehicles.xml, driver is seat 0) |
| Storage / fuel items | PARTIAL fuel float only |
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

### 8. Inventory, items, crafting, loot

| Item | Status |
|---|---|
| Item id table from `items.xml` | HAVE (`assets/items.zig`) |
| Block id table | HAVE (AssignIds dump + `maxdamage`) |
| Recipes / crafting queue | PARTIAL (`assets/recipes.zig` + workstation) |
| Loot containers / `loot.xml` | HAVE (`assets/loot.zig`) |
| Quality / mods / durability | PARTIAL (quality/meta persist; mods shallow) |
| Stacking / bag size | PARTIAL (items.xml Stacknumber) |
| Workstation / forge / chemistry | PARTIAL (TE type 12 full body + stock queue/craft-complete semantics; see WIRE_WORKSTATION) |
| Schematic unlocks | PARTIAL (always_unlocked recipe list on join) |
| Trader buy against real item defs | PARTIAL (traderAlways + EconomicValue; group rolls deferred) |

**Largest remaining “feels like a game” gaps:** AI path A*, quest objective
type coverage, power fuel/actuation, deco/AssignIds pin, M11 serialize-once.

---

### 9. Content / assets pipeline

| Asset | Status |
|---|---|
| quests.xml | PARTIAL loader |
| map_info + dtm + spawns | HAVE |
| prefabs.xml + tts sizes + prefab YOffset | PARTIAL |
| water_info.xml | PARTIAL |
| blocks.xml | HAVE (`maxdamage` MaxPower/RequiredPower, ids) |
| items.xml / item_modifiers | HAVE (`assets/items.zig`; modifiers partial) |
| entityclasses / entitygroups | HAVE (`assets/entities.zig`, `entitygroups.zig`) |
| biomes.xml / biomes.png | HAVE (colors + layers + biomes.png) |
| traders.xml | HAVE (groups + expand) |
| vehicles.xml | PARTIAL (load + spawn HP/speed) |
| gamestages / spawning | HAVE (`assets/gamestages.zig`; spawning.xml `<biome>` + `<entityspawner>`) |
| buffs / progression | PARTIAL (catalog + passives + XP curve; no full VM) |
| buffs / progression | PARTIAL (typed catalog + stack/duration/update_rate + passives + XP curve; no triggered_effect VM) |
| recipes / loot | HAVE (`assets/recipes.zig`, `loot.zig`) |
| Localization.csv | MISSING |
| materials / physicsbodies | PARTIAL (materials MaxDamage via maxdamage) |
| sounds / music (server triggers) | MISSING |
| nav_objects.xml | MISSING |
| worldglobal / weathersurvival | MISSING |
| shapes / painting | PARTIAL (painting.xml atlas; shapes via AssignIds/TTS) |

Pattern for new loaders: `src/assets/<name>.zig` + fixture + `Game.init` resolve (see ASSETS.md).

---

### 10. Persistence and player data

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
| Player save key | PARTIAL (login name; stock uses `PrimaryId.CombinedString`, asm.il 1884842) |
| Ally relationships | MISSING (in-memory only; stock persists them in PersistentPlayerList) |

---

### 11. Replication, interest, performance

| Item | Status |
|---|---|
| Broadcast all transforms | PARTIAL (except owner for PosAndRot; broadcastNear 160) |
| Spatial interest (chunk/grid) | PARTIAL (radius filter; no cell hash) |
| Serialize-once shared buffers | HAVE (`Game.replicate` is entity-outer: encode + frame once, memcpy fan-out per interested peer; docs/adr/0008) |
| Dirty flags (POS/ROT/FLAGS/HP) | HAVE (`World.dirty_bits` mirrors `dirty[]` through `markDirty`; off-heartbeat replicate visits dirty ∪ mobs only. Mob motion stays heartbeat-only by design: marking `stepToward` dirty would take mob PosAndRot from tick%10 to tick%2) |
| RelPos vs PosAndRot bands | PARTIAL (client RelPos applied; server mostly PosAndRot) |
| Velocity packages | MISSING |
| Per-client byte budget | PARTIAL (WindowFull tiered soft-drop) |
| entityId → connection map O(1) | MISSING (`clientFor` still scans 64 client slots per datagram; measured as noise next to the per-entity work) |
| NetId → slot hashmap | HAVE (`World.net_to_slot`; linear fallback only when the map is degraded) |
| Parallel AI / turrets / save | HAVE |
| Persistent thread pool | HAVE (`util/parallel.zig` persistent pool) |
| Async region I/O | PARTIAL (`world/chunk_flush.zig` behind `[perf] async_chunk_flush`, default off: one joined writer thread, per-key FIFO, `waitKey` gate on read/evict. Encode stays on the tick thread; still one file per chunk, no stock-style region file) |
| Read-mostly terrain snapshot for A* | PARTIAL (`world/terrain_snapshot.zig` behind `[perf] terrain_snapshot`, default off; one surface Y per column, answering only the surface footing case. Walls and building interiors are out of the body's step/drop band and fall back to the locked hook, as does anything outside the 256-chunk / radius-2 window) |
| Path worker pool | MISSING (A* already runs inside the parallel AI batch. A *deferred* solve phase is still not built, but the per-tick node budget it was waiting on now exists: `World.pathBudgetAdmits` spreads replans by a slot/tick stride and refused bodies follow their stored waypoint buffer, so a delayed replan no longer means a straight-line chase. `path_replans` / `path_replans_denied` counters ship as the evidence. docs/SCALE_ARCHITECTURE.md) |
| TE loot / prefab-storage scan as a job batch | MISSING (`te_scan` section + `te_scan_cells` counter ship as evidence; the `found >= 32` early return makes an exactly-equivalent parallel scan fiddly) |
| Metrics apm harness | HAVE (`src/apm/`) |
| Tracy zones over apm sections | PARTIAL (`-Dtracy` + operator-supplied `-Dtracy-src`; 12 `Section` zones + per-tick frame mark only. No plots/locks/alloc/GPU zones, nothing inside ecs job workers, and CI never builds the on path. `docs/APM.md`) |
| 128-bot scale bench harness | MISSING (loadgen mixed 2-bot green; 128 open) |

---

### 12. Admin, ops, hosting

| Item | Status |
|---|---|
| CLI port/world/map/game-dir | HAVE |
| serverconfig.xml stock | HAVE (`config.zig`; GAME_OPTIONS.md) |
| Telnet / web admin | PARTIAL (stock greeting + login + bind rule; see §12.1) |
| Console commands (kick, ban, admin, …) | PARTIAL (stock verbs and output shapes below; client-side verbs MISSING) |
| Steam server browser listing | MISSING |
| Query protocol | MISSING |
| Logs / log rotation | PARTIAL (stdio) |
| Graceful shutdown save | HAVE (save tick + deinit persist) |
| Docker / systemd unit | MISSING |
| Config hot reload | MISSING |
| Guard policy (weak signals / quarantine / dry-run kick) | HAVE (`server/guard_policy.zig`; see gaps below) |

### 12.1 Telnet console parity (P3, PARTIAL)

Grounded in the decompiled V3.1.0 b14 client IL (`asm.il`).

**HAVE**

- Login: `TelnetEnabled` / `TelnetPort` / `TelnetPassword` /
  `TelnetFailedLoginLimit` / `TelnetFailedLoginsBlocktime` parsed from
  serverconfig (EnumGamePrefs 0x44/0x45/0x59/0xA5/0xA6, asm.il:1903853-1903951).
  `TelnetPort` wins over the zdtd `AdminPort` alias when telnet is enabled.
- Greeting block and login prompts verbatim from `TelnetConnection::LoginMessage`
  and `::authenticate` (asm.il ~269683-270300): `*** Connected with 7DTD server.`,
  the version/IP/port/players/mode/world/name/difficulty block,
  `Please enter password:`, `Password incorrect, please enter password:`,
  `Too many failed login attempts!`, `Logon successful.`
- Bind rule from `TelnetConsole::.ctor` (asm.il ~270735): loopback with no
  password, INADDR_ANY only when one is set. Password compare is constant-time
  and the password line is never echoed or logged.
- Stock output shapes: `*** ERROR: unknown command '<cmd>'`, the `help` index
  (`*** Generic Console Help ***` / `*** List of Commands ***` / `<cmds> => <desc>`),
  `listplayers` full field order, `listplayerids`, `listents`, `Total of N in the game`,
  `GamePref.{0} = {1}`, `Chunks:` / `Chunk Memory:`, the `mem` line separators,
  and the `Wrong number of arguments, expected …, found N.` arity errors.
- Stock argument grammar: `kick <target> [reason]`, `kickall [reason]`,
  `ban add|remove|list <target> <duration> <unit> [reason]` with the full stock
  unit table, `admin add|remove|list`, `whitelist add|remove|list`,
  `settime day|night|<worldtime>|<day> <hour> <minute>` (world time from
  `GameUtils::DayTimeToWorldTime`, asm.il:1926175).
- Admin / whitelist / ban lists persist beside `players.zsv`
  (`admins.zsv`, `whitelist.zsv`, `bans.zsv`). Bans carry an absolute expiry, so a
  restart neither resurrects an expired ban nor drops a live one; a corrupt line
  is skipped and reported, never applied.

**MISSING on purpose (client-side verbs, no meaning on a dedicated server)**

`gfx`, `cam`, `spectator`, `debugmenu`, `showalbedo`, `shownormals`,
`enablerendering`, `debugshot`, `audio`, `lights`, `water`, `weathersurvival`,
`teleport`/`tp` in its stock form (stock `tp` moves the *local* player and replies
"Command can only be used on clients", asm.il 259294).

**MISSING (server-side, not yet done)**

`admin addgroup` / `removegroup` and `whitelist addgroup` / `removegroup` (zdtd has
no Steam group concept), `commandpermission`/`cp`, `loglevel`, `listthreads`/`lt`,
`getoptions`, `exportcurrentconfigs`, `help <command>` detail pages,
`setgamepref` as a real write (zdtd applies serverconfig at startup only, so it
replies that the pref is read-only rather than reporting a change that did not
happen).

**Deliberate divergences**

- `tp` stays a zdtd alias of `tele` (teleport another player by slot / entity id).
  Flipping it to stock's client-only meaning would break zdtd's own WEBUI docs and
  playtest tooling for no operator gain. Stock's server-side name is `teleportplayer`.
- zdtd-only verbs keep their names and are marked "zdtd:" in the `help` index:
  `give`, `inv`, `unban`, `guardstats`, `guardclear`, `evidence`, `apm`,
  `wipeplayer`, `status`. Stock has no `give` (it has `giveself`/`givexp`).
- Ban and permission entries are keyed by login name, not a platform user id:
  zdtd has no stock user id to store, and inventing one would be a fabricated
  identity in an operator-visible list.

### Guard policy honest gaps (P4)

Landed: severity ladder with a structural "weak signals never kick" property,
per-peer tick-windowed gates (2 distinct Strong or N Hard), per-surface
quarantine bits enforced at 5 C2S sites, an IL-grounded `NetPackagePlayerDenied`
kick with a stock 0.5 s delayed drop, a load-shed valve, and zdtd.toml
`[authority] guard_*` switches. Full contract in
[AUTHORITY.md](AUTHORITY.md#guard-policy-p4).

| Gap | Why it stays a gap |
|---|---|
| Efficiency detectors (aimbot / ESP / rotation time series) | Stock wire is too coarse and zdtd does not sample rotation. Only the block-destroy-rate weak signal exists, and it is record-only. |
| Quarantine persistence across reconnect | Bits live on the client slot, which is reset to `.{}` on disconnect. Persisting them needs a `players.zsv` schema change. Reconnect churn is a `.flood` signal; the kick gate is the answer, not faked persistence. |
| Ban ladder / ban duration / appeal path | `NetPackagePlayerDenied.banUntil` is always 0 and the IP ban list stays operator-only. `EacViolation`/`EacBan` are never emitted (no EAC integration; explicit non-goal). |
| Forensic evidence trail | The ring is global, 64 entries, and ring writes are deduplicated per (detector, surface) per window. `evidence` is a sample; the counts that drove a decision live in the per-peer state and the apm counters. |
| Load shed under the virtual clock | Only the real-time `run()` overrun branch arms it, so `--ticks` / scenario runs never exercise it end to end. Only its predicate is unit-tested. It is a coarse availability valve, not a scheduler. |
| Kick message delivery | Best-effort. zdtd has no stock `ConnectionManager` teardown (ModEvents, AuthorizationManager, save-on-disconnect). A lost reliable send leaves the client to time out with no reason string. |
| Weak-signal thresholds | `weak_break_rate_per_window = 900` is a heuristic; nothing in the IL defines a legitimate harvest rate. Tuning knob, not detection ground truth. |
| serverconfig.xml properties for the policy | Deliberately absent. The switches are Bucket B (zdtd.toml `[authority]`) so there is one obvious way to set them. |
| webui mirror of the policy line | Not extended in this pass; only admin `guardstats` shows the rungs and per-slot bits. |

---

### 13. Validation and client compatibility

| Item | Status |
|---|---|
| Unit / scenario tests | HAVE (**434** total; see STATUS for pass/fail pin) |
| Loadgen join bots | PARTIAL (join + walk + actions; stock chunk stream when `wire_chunks`) |
| Stock client join + stand | **PASS** (live gate **23/23** on a fresh world; see STATUS) |
| Golden wire size checks | PARTIAL (some packages) |
| Capture regression suite vs stock | MISSING |
| Multi-version client matrix | MISSING |

---

### 15. Priority bands (post-playable)

**P0 join/play gate: CLOSED** (STATUS 2026-07-23). Do not re-open from stale rows.

### P1: Depth the client still notices

Each row is current as of the 2026-08-06 wave. Where a row says SHIPPED the work
is on main and gated; what follows "Open:" is the honest remainder.

1. **Deco** SHIPPED: `blocks` NameIdMapping, biome-driven density and the
   world-store mirror. Open: a live-client playtest (the client log must show
   "Received mapping data for: blocks", then "Block IDs with mapping" and a sane
   block-id total), and the one-shot join burst is still the only deco window.
2. **Weather storm / bloodMoon group state machine** SHIPPED
   (`src/world/weather.zig`). Storm state is persisted (`weather.zwt`, ZWTH1)
   and restored across restart; stock `WeatherManager::Save`/`Load` was not
   mirrored (own format, same fields). Open: `ForceWeather` / `SetStorm` admin
   commands.
3. **Path A\*** SHIPPED: grid A* over a body-aware step predicate (step-up, drop
   and headroom), 8-cell waypoint buffer, deterministic per-tick node budget. EAI
   gained RunawayWhenHurt and the SetAsTargetIfHurt revenge target. Open: navmesh,
   jump and climb, data-driven per-class task graphs (5.2.1).
4. **Quest objective coverage** PARTIAL: Craft, StayWithin and Rally execute.
   Open: POIStayWithin and the unmodelled types still auto-complete, quests.xml
   `<action>` elements are unparsed, 53 client-known defs parse empty because
   template inheritance is not resolved, and the accept path is missing
   (see GAP_ANALYSIS section 4).
5. **Power trigger TE wire** SHIPPED: Switch meta gate on SetBlock, delay and
   duration from ClientTriggerData, edge-triggered meta broadcast of grid state.
   Open: TimerRelay hour semantics, Motion TargetTypes filtering, and a
   live-client playtest of the S2C TE leg (needs tile entities in the chunk
   stream).
6. **Workstation RecipeQueue** SHIPPED: the C2S/S2C body is complete (fixed stock
   array lengths, trailing `lastInput`, `CraftCompleteData`, recipe blobs) and the
   craft tick follows `HandleRecipeQueue` / `cycleRecipeQueue`. Open: the server
   trusts the client's `Recipe` blob for output type, count and time instead of
   validating against recipes.xml; non-burning stations (workbench) do not advance
   server side because the Module gate is not on the wire; no live-client playtest
   of the forge UI.

### P2: Multiplayer CPU (M11)

SHIPPED: dirty bitsets, serialize-once interest, per-entity observer masks,
persistent thread pool, O(1) NetId map. Open: spatial cell hash for the interest
query (M11.1) and the 32-128 bot apm gate (M11.5). See IMPLEMENTATION_PLAN M11.

### P3: Ops and polish

SHIPPED this wave: full stock telnet console surface, party PlatformUserId,
gamestages (inputs below), buffs depth, vehicle multi-seat.
Open: Steam server browser registration, the buffs remainder (triggered_effect
VM, cvar sync, immunity and damage-type gates, buff persistence across sessions),
Encryption* (optional).

#### Gamestage: what is in and what is still missing

In (`src/assets/gamestages.zig`, grounded in asm.il V3.1.0 b14):
- `<config>`, `<group>`, `<spawner>/<gamestage>/<spawn>` parsing with the IL's
  spawn defaults `num=1 maxAlive=1 interval=2 duration=0` (`GamesStagesFromXml::
  ParseSpawn` ~1379611). The gamestages.xml header comment states different
  defaults and is wrong.
- `EntityPlayer::get_gameStage` (~503972), `GetLootStage` (~504215),
  `CalcPartyLevel` (~1093305), `CalcGameStageAround` (~1093351),
  `GetStage`/`GetBoundIndex` (~1093187), `GameStageGroup::CleanName` (~1093513),
  `SetAlive` days-alive penalty (~503838).
- Consumers: sleeper volume groups, blood-moon spawner stage (group + maxAlive),
  daytime scout tier at 45/85/125 (`SpawnScouts` ~415972), loot.xml
  `loot_prob_template` bands, and the `gamestage [slot]` admin command
  (same fields as `ConsoleCmdGameStage::Execute` ~220775).
- `gameStageBornAtWorldTime` now rides the PlayerId PDF instead of the -1
  sentinel, so the client's own `gamestage` readout agrees with the server.

Still missing (inputs zdtd does not parse; all are fed as zero/absent, never faked):
- biomes.xml `GameStageMod` / `GameStageBonus` / `LootStageMod` /
  `LootStageBonus` / `LootStageMin` / `LootStageMax`.
- quests.xml `GameStageMod` / `GameStageBonus` (active-quest terms).
- Prefab `DifficultyTier`, so loot.xml `loot_settings poi_tier_mod` /
  `poi_tier_bonus` load but are never applied.
- loot.xml `<lootqualitytemplates>`: item quality by loot stage. zdtd's loot
  `Stack` carries no quality, so this needs a container/wire change first.
- EffectManager passive modifiers on both stages (`GlobalGameStageModifier`,
  `BiomeGameStageModifier`, `GlobalLootStageModifier`, … all pinned at 1).
- Blood-moon and wandering-horde loot drop bonus counters (`LootBonusEvery`,
  `LootBonusMaxCount`, `LootBonusScale`, `LootWanderingBonusEvery`,
  `LootWanderingBonusScale`): parsed into `Config`, not consumed.
- Cross-session persistence of days survived: `game_stage_born_world_time` is
  per-session Client state, so the streak restarts on reconnect.
- Party grouping ignores stock's same-`PrefabInstance` requirement (zdtd has no
  per-player POI tracking); distance alone decides.

### P4: Planet scale (parked)
Gateway + shards after M11 numbers (PLANET_SCALE.md). DEM M1 proven.

---

### POI sleeper volumes: what lands, what stays a gap

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
- Group name resolves stock-first: `GameStageGroup::CleanName` → gamestages.xml
  group → spawner → `GetStage(volume stage)` → first `<spawn>` group →
  `EntityGroups::GetRandomFromGroup`; then the class table, then the entitygroup
  table, else the default walker. The volume stage is
  `Max(0, CalcGameStageAround(players within 100))`. On a stock Navezgane boot
  all 3124 sleeper volumes resolve through the gamestage chain; before it they
  all fell through to the default walker, because stock POIs name gamestage
  groups (`GroupGenericZombie`, `S_-Group_Generic_Zombie`) that entitygroups.xml
  does not contain.

Honest gaps (no data path in zdtd, not faked):
- Per-volume gamestage adjust byte (zdtd's .tts/.nim reader does not carry it),
  and `maxAlive` is a per-burst cap rather than a live per-player population cap.
- Sleeper respawn (`respawnMap`/`respawnTime`/`cRespawnNever`); one-shot `triggered`.
- Trigger types (`ETriggerType`) and volume-to-volume wake cascade
  (`SleeperVolumeTriggeredBy`); zdtd wakes purely on player-inside-AABB.
- Quest / boss / loot volume flags (`SleeperIsBossVolume`/`SleeperIsLootVolume`/
  `isQuestExclude`/`isPriority`/`SleeperVolumeGroupId`).
- Sleeper pose / rotation / look / `spawnMode` (Normal/Bandit/Infested) and
  `MinScript` (`SVS<i>`): only the marker position + entity class are wired.
- `spawnCountMin/Max < 0 -> 5,6` runtime reset: malformed-data only, not modeled.

### Blood-moon festivities client FX packages

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
  "Armageddon" finds no `NetPackage`; the name is absent from stock through V3.1.0 b14. Not
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

### Vehicle physics (terrain-follow + collision)

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

### Platform identity, party and allies

`PlatformUserIdentifierAbs` is the only real player identity on the wire. One
codec owns it (`src/wire/platform_user.zig`); nothing else may hand-roll the
four fields.

LANDED (real, IL-grounded):
- **PUID codec.** `FromStream` (asm.il 30604): bool present, and a false bool is
  the whole value. Otherwise u8 UserIdentifierVersion (read then popped), string
  platform, string id, then `ReadCustomData`. `ToStream` (asm.il 31206) writes a
  lone 0 for null, else `1, 1, platform, id`. `WriteCustomData` /
  `ReadCustomData` (asm.il 30544 / 30553) are empty base bodies with no override
  anywhere in the assembly, so `inclCustomData` costs zero bytes.
- **Login.** `NetPackagePlayerLogin::read` (asm.il 832140) is walked in full:
  name, native PUID, native token, crossplatform PUID, crossplatform token,
  version, compVersion, u64 discordUserId. Both identities are stored per client;
  the two tokens are skipped because zdtd runs no authorizer chain.
- **PersistentPlayerState.** PrimaryId is `ClientInfo.InternalId` (crossplatform
  else native, asm.il 783909, matching `getPersistentPlayerID` asm.il 1886263)
  and NativeId is `ClientInfo.PlatformId`, per `CreatePlayerData` (asm.il 890568,
  called at asm.il 1885235). A client that sent no identity still gets a stable
  synthetic id so the entityId → name mapping (GMSG join line, party UI names)
  cannot regress.
- **Allies.** `NetPackageAllyRequest` (asm.il 886226) is decoded, the sender is
  required to speak for its own identity, and `AllyStore::ComputeTransition`
  (asm.il 885142) / `GetStatus` / `SetStatus` (asm.il 885392 / 885424) drive a
  real relationship table (`src/server/ally.zig`). The result goes out as
  `NetPackageAllyResponse` (asm.il 886390). A client-sent AllyResponse is dropped:
  its direction is ToClient (asm.il 886358).

HONEST GAPS:
- **Party membership.** `NetPackagePartyActions` (asm.il 829049) and
  `NetPackagePartyData` (asm.il 829470) carry **no** PlatformUserId; both are
  purely entity-id keyed. zdtd holds no `Party` state, so both are echoed to the
  sender and no S2C `PartyData` is ever constructed. What is missing is a
  Party/PartyManager equivalent (AcceptInvite / ChangeLead / LeaveParty /
  KickFromParty / JoinAutoParty), not identity. This is also why party members
  are not exempt from the POI `PlayerInside` lockout (`src/ecs/systems.zig`).
- **Ally persistence.** Relationships live in the server process only; stock
  saves them in `PersistentPlayerList`. They reset on restart.
- **Player save key.** Persistence is still keyed on the login name, so a client
  can claim another player's save by picking their name. Stock loads the PDF from
  `PrimaryId.CombinedString` (asm.il 1884842). Re-keying needs a save migration
  with a name-keyed fallback for existing players.
- **Platform verification.** Neither auth token is decoded or checked, so an
  identity is a claim, not a proof (EAC-off scope; see §2).
- **Reported read calls.** `docs/PACKAGES.md` under-reports these packages
  because `PlatformUserIdentifierAbs::FromStream` is a static call, not a
  `BinaryReader` virtual: the AllyRequest row shows only `ReadBoolean;`.
### Vehicle seats (multi-occupant)

`components.Vehicle.seats` is a fixed `[6]i32` of rider net ids; seat 0 is the
driver (`EntityVehicle::AttachEntityToSelf` sets `hasDriver` only for slot 0,
asm.il:542176) and 1..n-1 are passengers. Seat allocation in
`systems.vehicleAttach` mirrors `Entity::AttachEntityToSelf` (asm.il:406554): a
negative request takes the lowest free seat, re-requesting the held seat is a
no-op, an out-of-range request fails. `seat_count` comes from the contiguous
`seatN` classes in vehicles.xml (`Vehicle::SetSeats`, asm.il:1344168), giving
Bicycle/Minibike/Motorcycle 1, Gyrocopter 2, Truck4x4 4.

On the wire the server is authoritative, as stock is: a client sends
`AttachType` 0 with slot -1 (`EntityVehicle::EnterVehicle`, asm.il:541872) or
type 2 with `vehicleId = -1, slot = -1` (`Entity::SendDetach`, asm.il:406816),
and the server answers everyone with type 1 carrying the RESOLVED seat or type 3
(asm.il:844722). The client parents the rider to the seat transform itself
(`EntityVehicle::GetAttachedToInfo`, asm.il:542503), so the seat index is the
only thing the server has to get right for a passenger to render in place.

HONEST GAPS:
- **No `VehicleSeats` mod budget.** `Vehicle::SetSeats` allows extra seats when
  `EffectManager.GetValue(PassiveEffects::VehicleSeats, ...)` (asm.il:733849) is
  non-zero. zdtd has no vehicle mod slots, so the budget is fixed at 0 and only
  base seats count: a Truck4x4 is 4 seats, never 6.
- **Occupancy is not persisted.** A restart leaves every seat empty.
- **Explicit requests for an occupied seat are refused, not honoured.** Stock
  overwrites the array entry (asm.il:406554 IL_005d), which would unseat another
  player on a client's say-so. The stock client never sends a positive slot.
- **`NetPackageVehicleDataSync` payload stays opaque.** The framing is parsed
  and validated (asm.il:844254) and the body is relayed to other peers, but the
  `EntityVehicle::ReadSyncData` blob is not decoded.

### V3.1.0 wire note (2026-08-02)

`NetPackageTileEntity` now writes `teBlockId:i32` after world pos and uses **i32**
payload length (was u16). Stock RE: `../7dtd-research/docs/protocol-packages.md` §6.12
and the research topic docs.

**Implemented** in `src/wire/stock_te.zig` (`writeOuterTeHeader` /
`readOuterTeHeader`) for storage + workstation builders/parsers. Tests: 306/306.
