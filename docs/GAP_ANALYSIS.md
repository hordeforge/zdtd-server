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

**Water is in lakes and POIs.** Lake and river water now writes from the
`water_info.xml` sources at chunk generation (water blocks below the surface),
and the chunk water channel carries the full static mass, so Navezgane's 39
sources render wet. Prefab `.tts` water planes (POI pools, flooded basements,
water tanks) paint the resolved water block from the v>=17 sparse water
channel, so they render too. Still open: the flowing-water sim.

**Loot is mostly meaningful now.** Containers roll their own `blocks.xml`
LootList (a gun safe rolls `smallSafes`, a chest rolls `woodenChest`), and
zombie bags resolve the stock chain (`LootDropEntityClass` → the bag class's
`LootList=zPackReg`) and only drop on `LootDropProb` (.04), so most kills drop
nothing like stock. Still open: crafting is instant and unvalidated (loot container slot
counts now come from the `lootcontainer` size attribute).

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
scorecard; the per-area headers match the row counts). On 2026-08-07 the
scorecard was recounted from the per-feature markers, and two more gaps
closed: power grid nodes rebuild from the chunk block grid
(`scanChunkPower`) and prefab `.tts` water planes paint.
Recount 2026-08-22 from the live per-feature markers (the source of truth):
**291 features** carry a canonical WORKS/PARTIAL/MISSING tag and the scorecard
rows below are corrected to those counts. The 2026-08-21 "333 features / 44
MISSING" figure was an incremental projection that had drifted from the
markers (the file carries no `MISSING` tag today); every formerly-MISSING gap
was implemented or consolidated into a PARTIAL row with a documented residual.
Fifty-three feature bullets use ad-hoc status labels (`PARTIAL (waived)`,
`BLOCKED`, `ROLLED`, `SIZED`, `FIXED`, `PERSISTED`, `RESOLVED`, `PER-CLASS`,
`DONE`, `N/A (parity)`, `PARTIAL → …`) outside the canonical vocabulary and are
not counted; see [reviews/DOC_CONSISTENCY_AUDIT.md](reviews/DOC_CONSISTENCY_AUDIT.md).
The live task list is [WORK_PLAN.md](WORK_PLAN.md).

## 2. Scorecard

291 features scored across nine areas (recounted 2026-08-22 from the
per-feature markers, the source of truth; STATUS wins on conflict).

| Area | WORKS | PARTIAL | MISSING | Total | Bottom line |
|---|---:|---:|---:|---:|---|
| [Quests](#4-quests) | 33 | 1 | 0 | 34 | Template-derived defs non-empty; stock accept marker wired; `<variable>` substitution lands; challenge reward quests + stock-shaped journal wire complete; offers and rally POIs land in the tag/tier-filtered POI stock picks; journal restores quests by name with their POI rect; ClearSleepers kills gate to the bound POI and clear it permanently; phases advance only when all their objectives complete; objective counts parse value/count/item_count |
| [Traders](#5-traders) | 19 | 1 | 0 | 20 | Per-trader stock (direct + group rolls), hours, live wallet, lazy full-reroll restock, stock persistence, quest offers (NPCQuestList exchange complete), turn-in on open and the WorldAreas compound package land; sell any item at EconomicValue x markdown; POI placement open |
| [Blood moon](#6-blood-moon) | 22 | 1 | 0 | 23 | Horde runs dusk to dawn; ladder composition + jittered schedule + stat 58/red clock/music + 1.9x budget + per-party cap + dawn-end + jittered spawn bearings; party wave spawner with stage-frozen gsScaling and group maxAlive; settime takes stock world time; ops gettime/webui use the jittered countdown |
| [POIs and prefabs](#7-pois-and-prefabs) | 26 | 4 | 0 | 30 | Ids, rotation and height now correct; POI water planes wet; trader compounds ship their areas; parts paint and carry their sleeper volumes; sleeper volume coverage spans the whole map; multi-block children regenerate; authored block damage lands in the chunk plane; POI pads flatten to the stock deco.y-1 level; TileEntityType constants match stock; authored sleeper spawns use the full Class=Sleeper set; sleeper volumes rotate stock-clockwise; prefab TE scan seeds containers |
| [Entities and AI](#8-entities-and-ai) | 32 | 7 | 0 | 39 | Real fights with real stakes and real A*; per-class sight cone + LOS sensing; 9 EAI task classes; all stock entitygroups + gamestage sleeper resolution; per-biome wildlife variety; timid animals flee; spawns ground-snap and quest ambushes resolve gamestage; population is still thin |
| [Items, crafting, loot](#9-items-crafting-and-loot) | 23 | 5 | 0 | 28 | Containers roll their own tables and render their real grid size; items stack like stock; death bags carry the real inventory; recipes enforce craft_area and their exp data is all-zero; Extends inheritance complete; tool durability wears + quality rolls by loot stage; workstation fuel burn matches FuelValue; world containers are 4096 with eviction; stock InvTx applies to the player inventory; InventoryDataRequest loop is closed |
| [Player progression](#10-player-progression) | 22 | 3 | 0 | 25 | Level, XP, survival stats and active buffs survive a restart (ZPV3, saved on reap); eating caps like stock; death bags drop the real inventory; DeathPenalty is a real option; respawn targets the bedroll with a stock-order confirm; clean curve loader; perk runtime, stats blob and XP pushes still open |
| [World systems](#11-world-systems) | 38 | 6 | 0 | 44 | Walk, dig, build, persist; upgrades validate against the blocks.xml UpgradeBlock table; placed-block rotation/meta rides the chunk raw plane and ZCH3; POIs and parts place and paint; lakes and POI pools wet, claims expire, repair heals, supports collapse; per-cell biome ids follow the biome map; block damage persists per-cell in ZCH3; explosions carry per-entity ExplosionData + material bonuses |
| [Net and ops](#12-net-and-ops) | 48 | 0 | 0 | 48 | Join works, telnet is stock-shaped; bans/whitelist/admin gates are stock-authorizer faithful; C2S/S2C coverage complete; in-game player console complete (allowlist + admin routing); the ops verb set is complete; web dashboard is the stock-WebDashboard surface (operator-only, non-client-visible) |
| **Total** | **263** | **28** | **0** | **291** | Core loop playable with stakes; content fidelity and persistence are the gap |

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
   761 tests green. Container slot counts now come from the size attribute
   (2026-08-08); crafting validation remains open.

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

8. **DONE 2026-08-06 (prefab planes 2026-08-07).** World: put water in the
   world. Lake/river water now writes from the `water_info.xml` sources at chunk
   generation (`Chunk.applyWaterSources`: water blocks from the lake bed up to
   the source surface), and the chunk water channel carries the full static mass
   (19500) per water cell instead of uniform zero
   (`src/wire/stock_chunk.zig` `writeWaterChannel`, `water_block_id`).
   Navezgane's 39 sources render wet; a Navezgane loadgen smoke passes. Prefab
   `.tts` water planes landed 2026-08-07: the v>=17 sparse water channel is
   decoded into a dense per-cell mass plane (`TtsBlocks.water`) and
   `tts.paintDecoration` paints the resolved water block at mass>0 cells, so POI
   pools, flooded basements and water tanks render wet (the chunk wire derives
   full static mass from the water block plane). Still open: the flowing-water
   sim.

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

12. **DONE (majority) 2026-08-07.** Everywhere: raise or remove the
    fixed-size caps. Land claims 256 → 1024, containers 256 → 512 (the save
    path now encodes on the heap instead of a fixed stack buffer that
    truncated the tail), workstations 64 → 256, damaged blocks 64 → 256,
    block-rotation mirror 128 → 256, join-rate-limit IPs 16 → 64, in-RAM bans
    32 → 128. The join PlayerId journal reached the client at 2 of its 8 sim
    slots; all `max_journal` quests now ride the PDF (scenario `journal-pdf`,
    5 quests proven). entitygroups were already flat-arena (no group-count
    cap) and sleeper volumes are 8192. Each raise carries an overflow test
    (300 claims / containers round-trip, 100 workstations, 100 damaged
    blocks). Residuals: block_raw remains a FIFO sparse cache (the raw plane
    is persisted per GAP 13, so its eviction is a cache miss, never a revert);
    block damage now lives per-chunk in the ZCH3 damage plane (GAP
    "Player block damage"), and container/workstation tables are fixed arrays
    sized at the cap.

13. **DONE 2026-08-07.** World: store block rotation in the chunk plane.
    The SetBlock path writes the client's full `BlockValue.rawData` (rotation /
    meta upper bits) into the chunk plane via `World.setBlockRawWorld`, and the
    switch-meta edit does the same; ZCH3 persists the u32 plane, so a second
    client or a relog re-renders the rotation. Store test covers the plane and
    a save/reload round trip (`src/world/store.zig`, game.zig SetBlock).

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

18. **DONE 2026-08-07.** World: sample subbiome deco lists. `decoSpeciesAt`
    now resolves each cell through a port of stock `GetBiomeOrSubAt`
    (`src/world/subbiome_noise.zig`: `.NET` GameRandom, PerlinNoise
    Noise/FBM/Lattice, GetStableHashCode seed from the world name, the
    subbiome noise-window loop) and samples that subbiome's own
    `<decorations>` set, parsed per `<subbiome noise="freq, min, max"
    noiseoffset="x, y">` in `biome_layers.zig`. pine_forest's 8 subbiomes carry
    the real tree mass (treeJuniper4m .06, treeDeadTree01 .07, treeDeadPineLeaf
    .08); the top-level list stays the no-sub fallback. Verified against the
    stock biomes.xml + AssignIds dump (sub total prob > 10x the top-level, real
    ids). Residual: the stock `PerlinNoise` embeds a fixed 256-byte `_perm`
    literal (`<PrivateImplementationDetails> 04715D0F...`); zdtd uses the
    classic Ken Perlin table, so banding is stock-shaped (same FBM structure +
    XML frequencies/offsets/windows) but not byte-identical to the stock
    boundaries. Extracting the literal is a `../7dtd-research` task.

19. **DONE (version) 2026-08-07.** Net: fix `ServerVersion` and register
    with a master server. The GSI `ServerVersion` is now the stock four-field
    `V.3.10.14` (`version.stock_wire_gsi_version`); the login package keeps the
    display form `V 3.1.0` (protocol.md VersionLongString packing). The
    client's `TryParseSerializedString` no longer warns. Remaining: Steam or
    EOS registration (direct IP is currently the only route in).

20. **Net: stop wasting the transport budget.** `PARTIAL` (2026-08-07): the
    five stock motion packages now go unreliable (`isUnreliablePackage`,
    falling back to reliable past the single-datagram cap), the block
    `NameIdMapping` rides a deflate-compressed frame on channel 2, and
    **`NetPackageChunk` and `NetPackageSignDataResponse` are now deflated
    too** (`trySendCompressed` in `sendGame`, the stock asm.il:808641
    compress set) so the join/stream cost drops; any overflow falls through
    to the uncompressed frame. The join drop `reliable_window_drops=1` is
    gone. Still open: the remaining stock compressed set (ConfigFile has no
    payload in zdtd's LoadLocal path; DynamicMesh/MapChunks/POIAround are not
    sent), bulk world data on channel 1, and multi-package envelopes
    (`src/server/game.zig` send path).

21. **Progression: build a buff runtime.** `PARTIAL` (2026-08-07): buffs are
    no longer inert. `NetPackageAddRemoveBuff` is decoded, catalog-checked
    (unknown names rejected with `buff_rejects`) and owner-gated; the sim
    `BuffSet` applies/removes by def id, ticks durations/expiry and
    `remove_on_death`, and the tick sweep relays adds/removes to observers
    (`src/ecs/buff.zig`, `src/server/game.zig:10764`). Still open: buff
    **effects** (FoodChangeOT/HealthChangeOT cvars and stat deltas - the
    survival loop they feed is item 22), and persisting active buffs across
    restart (they ride ZPV3 already; effect application is the gap).

22. ~~**Progression: simulate survival.**~~ **PARTIAL → DEPLETION LOOP SHIPPED
    2026-08-07**: `Game.tickSurvival` (after tickAll, when the world clock
    advanced) depletes Food/Water with in-game time, drains HP while either is
    exhausted and regens when well-fed (UpdatePlayerHealthOT branches), clamps
    at zero, and syncs the changed totals to the owner on a throttle
    (`sendSurvivalStats`, `survival_sync_seconds`). The rates are ADR 0021
    policy tunables in `[rules.progression]` (`food_depletion_per_hour`,
    `water_depletion_per_hour`, `starvation_damage_per_hour`,
    `well_fed_regen_per_hour`, `well_fed_threshold`, `survival_sync_seconds`)
    because the stock FoodChangeOT/WaterOT/HealthChangeOT passive-effect
    defaults are not in the V3.1.0 IL corpus (Stat.Tick is not dumped); the
    defaults reproduce the stock feel (full Food drains in ~2 in-game days).
    **Stamina SHIPPED 2026-08-07**: sprinting (MovementState 3 from
    `NetPackageEntitySpeeds`, lapsed by `sprint_stale_seconds`) drains Stamina,
    idle regenerates, and the changed value syncs as EntityStatChanged kind 1
    on the same throttle (`stamina_drain_per_second` /
    `stamina_regen_per_second` tunables). Still open: core temperature,
    wellness, and replacing the `applyEatProps` "drop food to 50% of max when
    ≥ 85%" playtest workaround now that a real decrement loop exists.

23. ~~**Entities: add wandering hordes and the screamer heat map.**~~
    **DONE 2026-08-07** (verified against asm.il:416218 constants): the
    wandering-horde schedule (`AIDirectorWanderingHordeComponent`: start after
    28 000 world time, group of 6 at ~92 m every 12-24 in-game hours, horde
    marks + chase, player-gated) and the chunk-heat map
    (`AIDirectorChunkEventComponent`: region decay, 5 s check, cooldown +
    neighbours, scout-party spawn on threshold, feral double-cooldown roll)
    both live in `src/ecs/aidirector.zig` (tick 342-356, 703-770). Residual:
    the stock startPos→endPos pack path (AstarManager location line) is
    simplified to direct chase, and heat input is driven from game events
    rather than `AIDirectorData.noisySounds` named-sound volume/strength.

24. ~~**World: add the stability plane and falling blocks.**~~
    **Shipped** (`src/world/stability.zig`, commits 6daf9ca + 02a373a): the
    per-block byte plane (15 full / 1 non-support cap / 0 falls), reset +
    distribute on first touch, and the incremental removal/placement paths
    from `StabilityCalculator`/`ChannelCalculator` (RE: `../../7dtd-research/docs/stability.md`).
    A C2S SetBlock that removes a support block fells the dependency chain and
    broadcasts the collapse; placing re-spreads from supported neighbours.
    Support/ignore membership resolves from the block tables, not hardcoded.

25. ~~**Net: count and log unhandled C2S packages, then close the list.**~~
    **DONE 2026-08-07**: every named C2S package with no handler arm hits a
    `c2s_unhandled` counter with a rate-limited log (`n == 1 or n % 100 == 0`)
    at the end of `handlePackage`, so a new stock-client package surfaces
    instead of vanishing (`src/server/game.zig:7691`). The historical list
    (SetBlockTexture, PickupBlock, ItemReload, Waypoint, PlayerVendingMachine,
    QuestGotoPoint, PlayerDisconnect) is now handled: each is either decoded +
    applied or explicitly dropped with a comment.

---

## 4. Quests

**Headline.** Every quest the server knows how to accept can be completed:
a sweep over the real `Data/Config/quests.xml` accepts each of the 99 defs and
drives it through its phase graph to completion/turn-in at the real triggers
(scenario `stock-quest-sweep`, 99/99). The remaining quest rows below are
fidelity gaps (mid-session S2C sync is RE-blocked; ClearSleepers is a count,
not a sleeper-volume clear), not completion blockers.

**33 WORKS · 1 PARTIAL · 0 MISSING**

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

- **Objective type to executable phase kind mapping** `WORKS`
  Data-driven since 2026-08-19: the mapping is the catalog's
  `objective_kinds` table — `[quests] objective_kinds = "Type=PhaseKind, ..."`
  in zdtd.toml / a mode pack (config rows win, then the builtin stock
  defaults) — so a NEW stock objective type is a config row, not a code
  change (scenario `objective-kinds mapping is data-driven`). The builtin
  table covers all 16 stock types incl. `POIStayWithin` and
  `POIBlockActivate`; unmapped types degrade to `.auto` scaffolding
  (fail-closed: the phase auto-completes rather than deadlocking). The
  `Goto id="trader"` special case is a hardcoded game fact and beats the
  table. Measured: 0 of 77 phases in the 26 real graphs are `.auto`.
  *Anchors:* `src/ecs/quest.zig` builtin_objective_kinds + kindForObjective,
  `src/assets/quests.zig` parseObjectiveKinds, `src/server/zdtd_config.zig`
  `[quests]`

- **Requirement elements and quest_criteria / offer_criteria** `PARTIAL (waived)`
  Not parsed; shipped `quests.xml` contains 0 of each, so no player-visible
  gating is lost. A modded file using them would need RE for the requirement VM.
  *Anchors:* `asm.il:1390960-1391040`, `asm.il:1390474-1390510`

- **Quest `<action>` elements** `WORKS` `(2026-08-21)`
  `parseQuestDef` parses every `<action>` (types, phase, and the cvar / value /
  message / event / gamestage_list / count properties). **UnlockPOI fires
  server-side on phase entry**: the phase-gated action releases the quest's POI
  lock (stock `QuestActionUnlockPOI`, asm.il 1390421-1390429). 2026-08-21:
  **SpawnGSEnemy fires too** — on phase entry the Game spawns
  `count_min..count_max` gamestage-scaled enemies around the player (stock
  SpawnQuestEntity placement: player position + random direction ×
  (12 + rand*12) m; gamestage list resolved at the party gamestage, entity
  drawn from the stage's spawn group; RE: QuestActionSpawnGSEnemy.il.txt).
  The starter's `SetCVar StarterQuest=1` and `ShowMessageWindow` run on the
  owning player's client in stock, so zdtd records them and fires nothing
  server-side (correct by the stock model); `GameEvent` actions have zero uses
  in the stock file (only the format comment), recorded-unfired.
  *Anchors:* `src/assets/quests.zig` parseActions,
  `src/ecs/systems.zig` firePhaseActions, `src/server/game/hooks.zig`
  questSpawnGsEnemy, `asm.il:1390421-1390429`,
  il QuestActionSpawnGSEnemy

- **Objective `value` / `count` / `item_count` to required count** `WORKS`
  `objectiveTarget` reads `value`, `count=` and the stock `item_count`
  spelling (first present wins, fail-closed 1), and the Goto family carries
  `Value` as a float distance in metres into `PhaseSpec.radius` (required
  stays 1; the goto check uses the radius) instead of turning a distance into
  a count masked by `bumpPhase(n=required)`.
  *Anchors:* `src/assets/quests.zig:137-145` (`objectiveTarget`),
  `src/ecs/quest.zig` PhaseSpec, `asm.il:1391090-1391107`,
  `asm.il:966955-966966`

- **Phase graph construction** `WORKS` `(2026-08-21)`
  `buildPhaseGraph` mirrors `QuestClass.HighestPhase` and emits a flat
  per-objective list (`def.objectives`, stock CreateQuest order) beside the
  per-phase advancing spec. A phase advances only when **all** its non-optional
  objectives complete (stock `refreshQuestCompletion`, asm.il 983645-983904) —
  including always-active phase-0 objectives — so the `POIStayWithin`
  constraint on `tier1_clear` phase 3 (ClearSleepers + stay) and the second
  half of shared phases are enforced; every phase kind receives its events
  (`phaseHasKind` gates, not the single advancing spec kind). Arrival
  objectives (goto/stay/trader/rally) keep required=1 — their `value` is a
  distance (stock ObjectiveGoto::distance), never a count. `Optional`
  objectives never block; `ForcePhaseFinish` fails the quest when the phase is
  incomplete (slot flips to the wire's Failed state, not re-offered;
  0 uses in the stock file, unit-tested). The 99-def sweep over the real
  quests.xml completes **99/99**. Per-objective progress rides the journal
  wire (each objective's CurrentValue) and the ZPV6 save.
  *Anchors:* `src/assets/quests.zig` buildPhaseGraph,
  `src/ecs/systems.zig` bumpPhase/phaseObjectivesComplete/phaseHasKind/failQuest,
  `src/ecs/quest.zig` FlatObjective, `asm.il:983645-983904`,
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
  `tier1_fetch` reports 1. 2026-08-23 re-audit: the row's "trader tier gating
  and NPCQuestList tierLevel filter remain open" residual is stale - the offer
  builder filters `d.difficulty_tier != tier` against the requested tierLevel
  (asm.il 827746-827975; scenario proves a tier-2 fetch gets nothing from a
  tier-1 list, see "Trader quest offers" WORKS). The tier's remaining use is
  the default kill count.
  *Anchors:* `src/assets/quests.zig:294`, `:227`, `:303`,
  `src/server/game/quest.zig:277-278` (tier filter)

- **Rewards: counting and per-reward wire shape flags** `WORKS` `(2026-08-22)`
  The count and shape are right (LootItem 498, Item 132, Exp 85, Quest 6,
  ShowMessageWindow 4, SkillPoints 1, Skill 1; only Item/LootItem carry an
  ItemStack). `reward_coin` is the sum of the actual `casinoCoin` Item rewards
  (no invented formula). The journal writes **real ItemStacks** (stock item
  name resolved through the negotiated items table; unknown names keep the
  stock Empty stack) and turning in pays the rewards out: the wallet coins in
  the sim, Item/LootItem stacks into the player inventory and Exp into the xp
  ledger via a tick-end drain of the completed-quest ring (scenario
  `quest-rewards`). Since 2026-08-22 LootItem **group** rewards roll: a reward
  id that resolves to a loot group (groupQuestWeapons etc.) rolls `value`
  prob-weighted picks (`ischosen`, uniform when weights are equal) or the
  first `value` entries (`isfixed`), each stack granted, and `RewardQuest`
  entries chain: the turn-in grants the named quest to the journal. RE pin:
  7dtd-research quests-challenges.md.
  *Anchors:* `src/assets/quests.zig` (reward parse), `src/assets/loot.zig`
  (`rollGroupPicks`), `src/server/game/step.zig` (payout drain)
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

- **Per-objective CurrentValue from the phase graph** `WORKS` `(2026-08-22)`
  Emits 255 for completed phases, clamped progress for the active phase, 0 for
  future, per objective from the phase graph (objective_phases + the active
  phase's required count). Boolean-ish objectives (Goto, InteractWithNPC) and
  TreasureChest/StayWithin do not consume the value client-side - exactly like
  stock, whose Reads ignore it for those types - so the wire carries the
  stock layout with the stock semantics.
  *Anchors:* `src/server/game/quest.zig` (`obj_vals` in the journal writer)

- **Quest.PositionData** `WORKS` `(2026-08-22)`
  QuestGiver (0), Location (1), POIPosition (2) and POISize (3) are all
  written: the giver position is captured at trader accept (the offering
  NPC's position, for the client's return-to-giver marker; unset for
  starter quests), and the POI rect is resolved from `prefabs.xml` at
  accept time. Goto-target positions are no longer invented: goto_point /
  stay_within / craft quests bind the nearest real POI at accept
  (`World.nearestPoi` over the prefab index, audit B26), and the Location,
  NavObject marker and goto check all use the bound POI center. The FNV-hash
  coordinate survives only as the no-POI-data fallback for offline/test worlds.
  *Anchors:* `src/server/game/quest.zig` (journal writer position data),
  `src/server/c2s/quest.zig` (giver capture at accept),
  `src/ecs/systems.zig:326-338`, `src/ecs/world.zig:391-399`,
  `src/wire/stock_quest.zig:12`, `:614`

- **NetPackageNPCQuestList FetchList + QuestPacketEntry wire** `WORKS`
  Byte-for-byte the stock `QuestPacketEntry::read/write` order; `parseNpcQuestList`
  matches the stock read switch including the per-event tails.
  *Anchors:* `src/wire/stock_quest.zig:112`, `src/wire/packages.zig:2674`,
  `asm.il:827300-827326`, `asm.il:827512-827630`

- **Trader quest offers** `WORKS` `(2026-08-21)`
  The offer list follows the trader's class: the 5 trader class hashes
  (npcTraderJen/Bob/Hugh/Joel/Rekt, RE-computed) map to their parsed
  `trader_*_quests` lists, with jen as the fail-closed default, so each trader
  offers its own list once POI placement spawns the other classes (scenario
  `trader-lists` proves a rekt-class trader offers `trader_rekt_quests`).
  The offer list is filtered by the requested tier (stock DifficultyTier ==
  tierLevel, asm.il 827746-827975; scenario proves a tier-2 fetch gets nothing
  from a tier-1 list). 2026-08-21: every offer is now **pre-positioned** like
  stock — the EntityTrader offer loop runs Quest.SetupPosition per quest, so
  each QuestPacketEntry carries the real QuestLocation (POI center at terrain
  height), QuestSize (bbox size) and POIName, selected by the stock
  tag/tier/biome/band engine (DynamicPrefabDecorator.GetRandomPOINearTrader;
  RE: 7dtd-research docs/quests-challenges.md "Quest POI selection").
  Scenario `quest-poi-select` proves a clear-tag tier-1 quest selects the
  matching POI (not the fabricated catalog spot) and feeds the offer wire.
  *Anchors:* `src/server/game/quest.zig` buildTraderQuestOffers,
  `src/server/game/hooks.zig` questPoiSelectAt,
  `src/ecs/quest.zig` QuestPoiParams + tags,
  `src/server/scenarios.zig` scenario `quest-poi-select`

- **Trader quest ACCEPT** `WORKS`
  Stock signals acceptance with `NPCQuestList eventType=RemoveQuest(1)` carrying
  `tierLevel` plus `removeIndex`. The handler now accepts the matching offer
  (tier-filtered, non-active, `removeIndex`'th) into the journal and re-sends
  the list without it; `buildTraderQuestOffers` excludes active quests, so the
  client stops offering an accepted quest. The scenario drives FetchList then
  RemoveQuest and asserts the journal entry plus the one-shorter list.
  *Anchors:* `src/server/game.zig` NPCQuestList remove_quest branch,
  `buildTraderQuestOffers`, `asm.il:827849-827902`

- **NetPackageQuestEvent parse/build and rally handshake** `WORKS` `(2026-08-21)`
  The head and per-event tails are parsed with bounds checks; TryRallyMarker is
  answered with the full stock reason switch; LockPOI/UnlockPOI drive
  `ecs/poi_lock.zig`; a peer may only raise events for its own entity. The
  client-notification events dropped by the `else => return` arm (ClearSleeper
  9, SetupFetch 12, SetupRestorePower 13, FinishManagedQuest 14,
  ResetTraderQuests 16) do not block zdtd's fetch/clear quests, which complete
  through the action hooks (`questOnFetchItem` / `questOnZombieKilled`).
  2026-08-21: the open item — stock's ClearSleeper suppression of sleeper
  re-arm — is closed: completing a ClearSleepers phase (POI-gated kills)
  marks the bound POI's sleeper volumes cleared in the persistent
  `sleepers_cleared.zsc` store, so a cleared POI does not re-spawn its
  sleepers on the next re-trigger or restart.
  *Anchors:* `src/wire/stock_quest.zig:438`, `:463`, `:478`,
  `src/server/game.zig:6288`, `:6322`, `src/ecs/systems.zig` advancePhaseGraph,
  `src/world/sleepers.zig` markClearedRect,
  `asm.il:835620-836087`, `asm.il:999755`

- **POI lockout check (server half)** `WORKS` `(2026-08-22)`
  Reports QuestLock, PlayerInside (with the stock party-member exemption: a
  party mate inside the POI does not block), Bedroll and LandClaim. The home
  reasons use the Game-wired context hook (the client's respawn bed and the
  claims store, `land_claim_size` radius around the keystone): a quest cannot
  reset a POI holding the player's bed or claim. Unit tested.
  *Anchors:* `src/ecs/systems.zig` `questCheckPoiLockout`,
  `src/server/game/hooks.zig` `homeLockout`, `asm.il:998990-999125`

- **NetPackageSharedQuest** `WORKS`
  All four heads parsed with truncation rejected (round-trip and truncation
  tests); accepted into the server journal; removal matched by QuestCode first
  with a def_id fallback; body forwarded to the named peer or broadcast.
  *Anchors:* `src/wire/stock_quest.zig:328`, `src/server/game.zig:4686`,
  `src/wire/stock_quest.zig:559`

- **NetPackageQuestObjectiveUpdate handling** `PARTIAL`
  `block_activated` advances the quest's `block_activate` phase (POIBlockActivate
  is real work, no longer auto scaffolding; scenario `block-obj` proves the phase
  waits for the event and advances on it). 2026-08-19: `treasure_complete` now
  advances the fetch phase, so treasure/fetch quests reach turn-in through their
  real event (the kill-loot hack is gone). 2026-08-22: `treasure_radius_break`
  now fires the quest's TreasureRadiusReduction event: the server rolls the
  parsed `chance` and spawns the nested SpawnGSEnemy ambush around the player
  (stock quests.xml: chance 0.25, 1-3 SleeperGSList on tier1_buried_supplies),
  deterministic per (world time, quest code); scenario `treasure-radius-break`.
  Open: the event-type-0 server path is documented as party-fan + distance-15
  HandlePlayer, so whether stock fires the radius-reduction ambush server-side
  with these chance semantics needs IL (RE-blocked note, not faked).
  *Anchors:* `src/server/c2s/quest.zig`, `src/wire/packages.zig:3350`

- **S2C quest progress updates during a session** `WORKS` `(2026-08-22)`
  The client owns its quest object: it reports its own objective events via
  `NetPackageQuestObjectiveUpdate` (C2S), and the server applies them to the
  authoritative journal. The mid-session S2C path is the party mirror
  (ProcessPackage IL=180 party fan-out, protocol-packages.md): the server
  re-applies the event to each party member's journal and re-sends the
  package to each member's client, so a shared quest advances live for the
  whole party - treasure_complete advances the fetch phase, block_activated
  the block_activate phase. Server-driven phases (goto proximity, kills)
  advance the journal server-side and surface on the next journal write /
  objective update, matching the client-owned-quest model.
  *Anchors:* `src/server/c2s/quest.zig` (QuestObjectiveUpdate handler +
  party mirror), `7dtd-research docs/protocol-packages.md`
  (NetPackageQuestObjectiveUpdate)
  *Anchors:* `src/server/game.zig:6088`, `:6121`, `:6185`,
  `../../7dtd-research/docs/quests-challenges.md` §5 (client owns the quest)

- **Server-side journal: accept, phase advance, turn-in, coins** `WORKS`
  `questAccept` allocates a slot, assigns a monotonic quest_code, resolves a POI
  rect and skips leading scaffolding phases; the phase walk saturates correctly;
  TurnIn parks and completes on trader open, paying into the wallet with
  saturating add. Six unit tests.
  *Anchors:* `src/ecs/systems.zig:277`, `:270`, `:187`, `:2386`, `:2564`

- **Rally-point objective execution** `WORKS` `(2026-08-21)`
  `questOnRallyActivated` marks `RallyMarkerActivated` once and advances a rally
  phase, degrading to scaffolding when the instance has no POI rect so the quest
  cannot deadlock. 2026-08-21: the rect now comes from the stock POI selector
  (tag/tier/biome/distance, `questAccept` → Quest.SetupPosition equivalent;
  scenario `quest-poi-select` proves a bound POI rect), so the quest lands in
  the biome/tier-filtered choice stock makes instead of the fabricated def
  marker. The rally handshake (TryRallyMarker reason switch + party mirror) is
  the NetPackageQuestEvent row; sleeper re-arm suppression is that row's open
  item.
  *Anchors:* `src/ecs/systems.zig:458`, `:234`, `:298`,
  `src/assets/quests.zig` scanObjectiveMeta, `src/ecs/quest.zig` PoiSelectKind

- **Kill / fetch / goto / stay-within / craft progress hooks** `WORKS` `(2026-08-22)`
  All five are wired. 2026-08-19: fetch quests now complete through **real
  triggers** — the client's `treasure_complete` QuestObjectiveUpdate event
  (treasure digs) and a container-loot hook (FetchFromContainer), and the old
  "every zombie kill also advances fetch" hack is gone; goto/stay-within use
  the objective's parsed distance in metres (`PhaseSpec.radius`, stock
  `ObjectiveGoto::distance`) instead of a hardcoded 4 m / `max(8, required)`,
  and the `[quests]` policy (QuestPolicy) configures the kill-count default
  (`default_kill_count + tier * kill_per_tier`) and the goto/stay radius
  fallbacks (ADR 0021; provenance PROVENANCE.md §3.7).
  ClearSleepers is an N-kills-anywhere counter rather than "clear this POI's
  sleeper volume" (the stock `QuestEvent_SleepersCleared` suppression of
  sleeper re-arm is the open part). 2026-08-21: the ClearSleepers leg went
  real — kills only count inside the quest's bound POI (victim position rides
  the kill event; `PhaseSpec.poi_gated` from the ClearSleepers objective
  type), and completing the phase suppresses the POI's sleeper volumes
  (persistent `sleepers_cleared.zsc`, so a cleared POI does not re-arm on
  re-trigger or restart). 2026-08-22 (audit B25 closed): the required kill
  count is the bound POI's live sleeper population - the Game hook sums the
  sleeper volumes intersecting the quest rect (the stock
  ObjectiveClearSleepers target), used by both the bump and the completion
  check; the `[quests]` policy floor is only the no-hook fallback (test
  `ClearSleepers target uses the POI's live sleeper count`).
  *Anchors:* `src/server/c2s/quest.zig` NetPackageQuestObjectiveUpdate,
  `src/server/c2s/inv.zig` container branch, `src/ecs/systems.zig`
  questTickGoto/questTickStayWithin/questOnZombieKilled/advancePhaseGraph,
  `src/assets/quests.zig` buildPhaseGraph, `src/world/sleepers.zig`
  markClearedRect, scenario `all-quest-kinds`

- **Starter quest granted at join** `WORKS` `(2026-08-21)`
  `questAcceptStarter` grants the starter (catalog `starter_quest` id) on join
  unless any journal slot already holds it (active, completed or failed), so a
  completed starter survives restart instead of being overwritten and
  re-offered, and a failed one is never re-granted. This matches the stock
  gate (SandboxOptionManager.UpdateInGameValuesWithSandboxOptions IL ~0A26:
  grant when `FindQuest(starter, -1) == null` and the `StarterQuest` cvar —
  set to 1 by the starter's SetCVar action — is 0; the slot scan is the
  journal equivalent of the FindQuest half, and the active/completed/failed
  check covers the cvar's "already started" state). The grant is shared with
  the post-join party (stock ShareAllQuestsWithParty), and the join PDF
  journal cap was fixed by GAP 12 (all quests ride the PDF, scenario
  `journal-pdf` proves 5).
  *Anchors:* `src/ecs/systems.zig` `questAcceptStarter`,
  `src/server/game.zig` join path,
  il SandboxOptions/SandboxOptionManager IL_0A26-0A88

- **Quest journal persistence (players.zsv ZPV5)** `WORKS` `(2026-08-21)`
  The players record is now ZPV5: every journal entry stores the quest **name**
  (the stock Quest.Write identity, `Quest.Write` IL writes `ID` as a string) and
  the POI rect (stock PositionData[2/3] bbox origin + size) alongside the
  def_id/quest_code/flags/progress/phase core. On restore the quest resolves by
  name first — a quests.xml edit or `--config-overrides` patch no longer
  reshuffles a saved quest into a different one (byName wins over the stored
  parse-order def_id; a def dropped from the file keeps its stored id rather
  than silently rebinding) — and the accepted POI rect comes back verbatim
  instead of re-resolving to the nearest prefab. ZPV2/3/4 files still read and
  upgrade in place (v<5 records are re-encoded, not carried byte-for-byte, as
  the journal grew). Scenarios `quest-persist` (round-trip keeps def + rect
  across a restart without POI hooks) and `quest-persist-name` (hand-crafted
  record whose stored def_id disagrees with its name resolves to the name).
  *Anchors:* `src/server/persist.zig` savePlayers / tryRestorePlayer /
  journalSectionEnd, scenario `quest-persist` + `quest-persist-name`

- **Quest NavObject markers** `WORKS` `(2026-08-22)`
  Emits `nav_objects.xml` class names at join for active quests with
  client-known names. The class comes from the ACTIVE phase's `nav_object`
  property (quests.xml objective `<property name="nav_object">`, arena-owned
  on the PhaseSpec; values quest/rally/sleeper_volume/treasure/
  restore_power/fetch_container/go_to_trader/return_to_trader) with the
  legacy kind mapping as fallback, and the marker position is the placed POI
  center (audit B26) or the objective target - the old primary-spawn
  fallback put kill/fetch markers on the wrong side of the map.
  *Anchors:* `src/server/game/join.zig` `sendQuestNavObjects`,
  `src/assets/quests.zig` `buildPhaseGraph` (nav_object extraction),
  `asm.il:959379-959389`

- **Client-known-name gate before writing a quest to the wire** `PARTIAL → CLOSED (2026-08-07)`
  `isStockClientQuestName` now accepts every stock quest-name family the
  client's quests.xml knows (`quest_`, `tier`, `intro_`, `test_`,
  `challengegroup_reward_`, `treasure_`), and a stock_xml catalog passes
  everything by construction (both sides load the same quests.xml); the gate
  only proxies the client catalog for builtin/offline defs. Verified against
  the stock quests.xml id families.
  *Anchors:* `src/server/game.zig` `isStockClientQuestName`

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

**19 WORKS · 1 PARTIAL · 0 MISSING**

- **Trader placement in POIs** `WORKS`
  Each trader POI's NPC now spawns at its `IndexedBlockOffsets class="Trader"`
  cell (rotated by the prefab rotation and added to the decoration origin,
  same mapping as the block paint), with the class from ThemeTags
  (`traderBob` → `npcTraderBob`), the per-trader trader_info id from npc.xml
  and its own stock filled. All five Navezgane trader compounds spawn their
  trader (scenario `trader POIs spawn their NPC classes on a stock map`).
  Remaining: the TraderArea protect/teleport volumes and closed-door visuals
  (the WorldAreas row).
  *Anchors:* `src/server/game.zig` (`spawnPoiTraders`), `src/world/prefabs.zig`
  (`QuestData.trader_*`), `Data/Prefabs/POIs/trader_bob.xml`
  (`IndexedBlockOffsets class="Trader"`)

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

- **NetPackageTraderData S2C snapshot** `PARTIAL (waived)`
  Body encoding is correct but stock direction is ToServer, so the client drops
  an inbound one before `Read`. Real S2C paths are spawn ECD + LockResponse;
  this `sendTraderSnapshot` is a refresh hint only. Waived per scope §1 (no
  package invention — stock never sends this direction).
  *Anchors:* `src/server/game.zig:5482-5527`, `asm.il:843057-843064`

- **TraderData v2 body encoding** `WORKS`
  `buildTraderDataStock` matches `TraderData::Read` / `ReadInventoryData` v2
  exactly, and the envelope matches `NetPackageTraderData::write`. Correct bytes
  on a package the client will not accept.
  *Anchors:* `src/wire/packages.zig:643-668`, `asm.il:861034-861057`,
  `asm.il:861060-861230`, `asm.il:860491-860628`, `asm.il:843213-843265`

- **C2S NetPackageTraderData handling** `WORKS`
  The stock ToServer body is parsed first (RE protocol-packages.md 6.23:
  isEntity bool | entityId i32 or tePosition 3xi32 | hasTraderData bool |
  TraderData.Write) and the trader state is CopyFrom'd (`parseTraderDataToServer`
  + `applyTraderDataCopyFrom`); the legacy 9-byte trade body is only tried after
  the stock parse fails. A real stock client's post-trade push reaches the
  server.
  *Anchors:* `src/server/c2s/quest.zig:212-228`, `src/wire/packages.zig:3131-3156`,
  `src/server/game/trader_wire.zig`, `asm.il:860724-860742`

- **traders.xml trader_item_group parsing with nested group refs** `WORKS`
  `loadFromPath` scans every `<trader_item_group>` and `expandGroup` resolves
  child refs recursively with a depth limit and a visited set. The docs are stale
  here: `GAP_ANALYSIS.md:535` and `:612` say group refs are skipped; they are
  expanded, with a test against the real stock file.
  *Anchors:* `src/assets/traders.zig:114-177`, `:54-82`, `:183-201`,
  `Data/Config/traders.xml:1179-1194`

- **traders.xml `<trader_info>` elements** `WORKS`
  `loadFromPath` now parses every `<trader_info id="N">` block: id,
  reset_interval, open_time/close_time, override_buy/sell_markup, allow_sell,
  is_vending, player_owned, rentable/rent_cost/rent_time, plus the per-trader
  `<trader_items>` refs (group and name, XML order preserved). npc.xml is
  parsed (`src/assets/npc.zig`) so each trader entity class resolves its own
  trader_info id and quest_list at spawn. `fillTraderFromXml` fills each
  trader's window from its own list (Jen's food, Bob's vehicles, Rekt's etc.)
  with `traderAlways` as the fallback; the lock-open path denies outside the
  trader's open hours (vending machines always open) and `allow_sell=false`
  blocks selling to that trader. override_buy/sell_markup feed the pricing row
  (below) and reset_interval is copied onto the stock row and drives
  `systems.traderRestock`'s cadence (-1 never, 0 daily, N every N days).
  *Anchors:* `src/assets/traders.zig:249-288`, `src/assets/npc.zig`,
  `src/server/game.zig:8345+`, `Data/Config/traders.xml:1240-1280`,
  `:1469`, `:1472`, `:1488`

- **traders.xml root economy attributes** `WORKS` (2026-08-07, RE'd 2026-08-08):
  `buy_markup` / `sell_markdown` were already parsed; `currency_item` is now
  parsed too and `Game.coinItemId` pays trade/rent in that item instead of a
  hardcoded "casinoCoin" name (falling back to the stock name when unset).
  RE 2026-08-08: `quality_mod="1,2"` (stock root) feeds
  `TraderInfo.QualityMinMod/MaxMod` (asm.il 1397236-1397257), applied in the
  CLIENT's `ItemClass.GetBuyPrice/GetSellPrice` (asm.il 1830625-1830948) as
  `Lerp(qualityMinMod, qualityMaxMod, (quality-1)/5)` times the econ x markup
  base (with `PercentUsesLeft`). 2026-08-22: the lerp is applied server-side
  (root `quality_mod` parses into `TraderInfo.quality_min/max_mod`; buy/sell
  prices lerp by the item quality at fill and on the non-stocked sell hook,
  so the transaction matches the client display; see the pricing row).
  `PercentUsesLeft` (EffectManager MaxUseTimes) stays RE-blocked.
  2026-08-22: `quest_tier_mod` (stock root `0,0.05,...,0.3`) parses and
  feeds the quest reward roll - GetRewardItem rolls with gameStage =
  GetTraderStage(tier) = Level*(1+quest_tier_mod[tier-1]) (RE progression.md
  GetTraderStage IL=46, loot-economy.md 8.4; test quest reward stage scales
  by quest tier).
  *Anchors:* `src/assets/traders.zig` root row, `src/server/game/step.zig`
  questRewardStage, `src/server/game.zig`
  `coinItemId`, `Data/Config/traders.xml:3`, `asm.il:1397236-1397257`,
  `asm.il:1830625-1830948`

- **Inventory roll (count ranges, prob, unique_only, quality, RNG)** `ROLLED (2026-08-08)`
  `fillTraderFromXml` / `fillVendingStore` run the ported `TraderInfo` spawn
  algorithm (asm.il 862758-863520): refs keep `count="lo,hi"`, `prob`,
  `unique_only` and `quality="lo,hi"` (the old parser dropped them), top-level
  refs always spawn, group members are picked prob-weighted with unique dedupe
  (`SpawnLootItemsFromList`), counts roll uniform in [min,max]
  (`RandomSpawnCount`, asm.il 863128), and quality rolls uniform in the
  entry's range and rides the TraderData wire slot (was hardcoded 1). The roll
  is seeded from (world seed, trader entity, day), so the same world + trader +
  day reproduces the same stock while restock on a later day rolls fresh (sim
  rule: deterministic inputs; stock uses a time-seeded per-ItemValue
  GameRandom). **Lazy rebuild on open (2026-08-08)**: the LockRequest open
  calls `maybeRestockTrader` - when the trader_info ResetInterval elapsed it
  re-runs the seeded roll (fresh counts/qualities), advances the restock day
  and regenerates the money pool (stock HandleFullReset, loot-economy.md §3).
  Still open: the `TraderMaxTier` clamp and mods/modChance.
  *Anchors:* `src/assets/traders.zig` rollAllRefs/spawnLootItemsFromList,
  `src/server/game/trader.zig` rollStockRefs / maybeRestockTrader,
  `asm.il:862758-863520`

- **Inventory depth and ordering** `50-ENTRY (2026-08-08)`
  `TraderStock` now holds stock `TraderInfo.MaxItems` = 50 entries and every
  snapshot path sizes from it (was 12, capped at 16), so a trader window
  shows the full stock the XML refs roll. Stock `traderAlways` plus a
  trader_info's two `<trader_items>` blocks is still more than 50 stacks,
  so the window keeps the first 50 like stock.
  *Anchors:* `src/ecs/components.zig:271`, `src/assets/traders.zig`,
  `src/server/game.zig:2616`, `:6762`

- **Buy/sell pricing from items.xml EconomicValue** `PARTIAL` `(markup 2026-08-07)`
  Stock multiplies EconomicValue by `TraderInfo.BuyMarkup` (root 3,
  per-trader OverrideBuyMarkup wins) and by `SellMarkdown` (root 0.2,
  OverrideSellMarkdown wins); zdtd now applies those parsed multipliers, so the
  server charges what the client's `XUiM_Trader` displays on the buy side
  (previously ~30x low). Residual: the sell side now applies the per-item
  `EconomicSellScale` (items.xml, default 1.0, RE `GetSellPrice`; added
  2026-08-20) but the quality lerp / `PercentUsesLeft` / `Entry.Markup` terms
  are still absent, so sell prices stay approximate.
  `(2026-08-22)` the quality lerp is in: the root `quality_mod="min,max"`
  (stock "1,2") parses into `TraderInfo.quality_min/max_mod` and applies to
  both buy (`price`) and sell (`sell`) at fill, plus the non-stocked sell hook
  path (the lerp rides the sold stack's quality); QL1 prices at min, QL6 at
  max, `Lerp(min, max, (quality-1)/5)` per RE GetBuyPrice/GetSellPrice
  (asm.il 1830625-1830948; test `trader prices scale with item quality`).
  2026-08-22: `Entry.Markup` no longer needs a server term - vending is
  owner-priced (loot-economy.md 6) and the client's post-trade echo carries
  each entry's markup plus the money delta, applied stock-faithfully on
  CopyFrom (see "Vending machines" `WORKS`). `(2026-08-22)` `PercentUsesLeft`
  is in: items.xml `DegradationMax` (passive 8) parses per item as the
  quality tier "min,max" (single value constant; the builtin stone axe pins
  250,500), and the sell arm prices the SOLD stack - base x quality lerp x
  `PercentUsesLeft` (1 - FastClamp01(use_times / MaxUseTimes), RE
  ItemValue.get_PercentUsesLeft IL=17; MaxUseTimes = quality-lerped
  DegradationMax at the DurabilityModifier 1.0 default) - on both the
  stocked and non-stocked paths, so worn tools sell for less like stock
  (test `worn items sell for less`). Remaining: the `TraderBuyPrices` (131)
  / `TraderSellPrices` (130) sandbox scales (parsed in `sandbox_data.zig`,
  not yet applied in `trade`) and the BarteringBuying/Selling perk passives
  (148/149) on both sides.
  *Anchors:* `src/server/game/trader.zig:162-200` (fill lerp),
  `src/ecs/systems.zig` qualityPriceMod + sell arm, `src/assets/items.zig`
  DegradationMax parse, `src/server/game/hooks.zig` percentUsesLeft,
  `asm.il:1830625-1830948`, `il/items-scratch/ItemValue.txt:98`,
  `Data/Config/traders.xml:3`

- **Trade execution** `WORKS`
  `systems.trade` is coherent bookkeeping with rollback and overflow guards:
  buys debit the wallet and the trader's money pool (demand spike +100), sells
  credit the wallet and debit the pool (demand ease -4), all atomic. Sells no
  longer require the item in the trader's stock - a non-stocked item prices at
  its EconomicValue x EconomicSellScale x SellMarkdown via the Game's
  sell-price hook (stock lets you sell anything, RE GetSellPrice), with unit
  tests for the stocked, non-stocked and unset-hook paths.
  *Anchors:* `src/ecs/systems.zig:1201-1298`, `src/server/game/hooks.zig`
  (`traderSellPrice`), `src/ecs/world.zig` (`sell_price_fn`)

- **Trader wallet / AvailableMoney** `WORKS` `(2026-08-22)`
  Each trader owns a live money pool (`TraderStock.wallet`, spawned from
  `trader_wallet_dukes`): the wire TraderData shows the real balance, buying
  from the trader credits it, selling to the trader debits it and refuses the
  sale once it runs out, and restock regenerates it toward the spawn default
  (the lazy open-time full reroll and the tick-side refill both do; the pool
  also survives restart via traders.zst). Re-audit 2026-08-22: the two
  remaining notes resolved - `TraderBuyLimit` has zero uses in the V3.1.0 b14
  traders.xml (nothing for the client to observe), and the restock timer is
  wired (the Restock timer row went WORKS).
  *Anchors:* `src/ecs/components.zig:757` TraderStock,
  `src/ecs/systems.zig:1201` (trade), `:1288` (traderRestock),
  `src/server/game/trader_wire.zig`, `asm.il:861697`

- **Haggling / barter perks** `PARTIAL (waived)`
  `perkBetterBarter` / `perkDaringAdventurer` Bartering/TraderStage perks
  (5..25%, +10..50) exist in `progression.xml` but require the progression/buff
  runtime to apply; trading math is now stock-correct via `traders.xml` markups.
  Waived as shop-overlay balance, not wire parity.
  *Anchors:* `Data/Config/progression.xml:3064-3065`, `:3084`

- **Trader tiers / TierItemGroups / traderstage_templates** `N/A (parity)`
  The engine tier machinery exists but stock V3.1.0 data never exercises it:
  `TradersFromXml` dispatches `<tier_items>` elements (only `trader_items` and
  `tier_items` are recognized; anything else throws), and the shipped
  `Data/Config/traders.xml` contains zero `<tier_items>`, so every
  `TraderInfo.TierItemGroups` is empty and `TraderData::WriteInventoryData`
  emits a 0 tier-group count. zdtd's `writeTraderDataBody` writes exactly that
  (u8 0), so the wire is byte-correct for stock. The tier engine itself
  (ParseTierItems: `count`/`level="min,max"`/items; `SpawnTierGroup` shuffling
  the tier's entries into `min..max` stacks on HandleFullReset; the wire
  `u8 count + GameUtils::WriteItemStack` per group) is documented RE but
  unverifiable without a modded traders.xml sample; `TraderMaxTier` /
  `TraderItemAbundance` are GameStats knobs, not XML.
  *Anchors:* `TradersFromXml.il.txt:470-500` (element dispatch),
  `:566-642` (ParseTierItems), `TraderInfo.il.txt:719-750` (SpawnTierGroup),
  `TraderData.il.txt:477-520` (WriteInventoryData tier section),
  `src/wire/stock_entity.zig:121-137` (writeTraderDataBody), `asm.il:863725-863767`

- **Per-entry Markup (demand model)** `WORKS`
  `TraderStock.StockEntry.markup` (sbyte) tracks the demand delta: a buy spikes
  it to +100 (`Entry.IncreaseMarkup`), a sell eases it by 4 saturating at i8 min
  (`Entry.DecreaseMarkup`, asm.il 856828-856866), and a restock resets it to 0
  (fresh entries). The wire TraderData (`stockEntries`, vending) now carries the
  live markup, so the client shows the demand arrows and prices
  player-owned/rentable machines from `1 + Markup*0.2` (loot-economy.md section
  5). Price deltas are the RE-cited constants; the absolute-set-on-buy and the
  i8 saturation are documented approximations (the nested `Entry` method IL is
  not dumped).
  *Anchors:* `src/ecs/components.zig` (`StockEntry.markup`),
  `src/ecs/systems.zig` (`trade` buy/sell branches, `traderRestock`),
  `src/server/game.zig` (`stockEntries`), `asm.il:856828-856866`,
  `asm.il:860548-860586`, `asm.il:1830586-1830600`

- **Restock timer** `WORKS` `(2026-08-22)`
  The cadence is stock-faithful (`reset_interval` parsed from `<trader_info>`:
  -1 never, 0 every day roll, N every N days), and the refill is now stock's
  full reroll: `maybeRestockTrader` is `HandleFullReset` on the channel-1 lock
  (trader open), re-running the seeded roll so sold-out entries drop and new
  stock appears (`fillTraderFromXml` rebuilds the window; scenario
  `trader-restock` proves the lazy open-time trigger, the day advance and the
  wallet regen). The tick-side `traderRestock` keeps drained stackables from
  sitting at zero between opens. Trader stock now **persists** across restart
  (traders.zst: entries by item name, wallet, reset cadence; restored by
  trader name over the fresh XML fill; unknown item names fail closed to a
  skipped entry; scenario `trader-persist` round-trips a traded-against
  window). The inventory-roll/depth rows still own roll semantics.
  *Anchors:* `src/server/game/trader.zig:207` (maybeRestockTrader),
  `src/server/c2s/misc.zig:668`, `src/server/persist.zig` saveTraders/
  loadTraders, `src/ecs/systems.zig:1288` (traderRestock),
  `asm.il:863657-863767`, `asm.il:863770-863910`

- **Open hours and the closed-door behaviour** `WORKS` (door TE features residual)
  `open_time`/`close_time` are parsed per `<trader_info>` and the lock-open path
  refuses to open the trade window outside them (`traderIsOpen` compares
  `worldTime % 24000` against the hours like stock's `TraderInfo::get_IsOpen`;
  vending machines and traders without hours stay open). The close/open cycle is
  edge-latched per trader (`tickTraderAreas`, `EntityTrader::OnUpdateLive`
  equivalent): on closing it force-unlocks the held trade channel
  (`ForceUnlockLockTarget`, channel 0) so an open window shuts, and walks the
  POI's `IndexName="TraderOnOff"` blocks to toggle them (BlockLight meta bit
  0x2 via SetBlockRPC; door close/lock via composite TEFeatureDoor/TEFeature
  Lockable and speaker sounds are residuals - zdtd has no door TE yet).
  *Anchors:* `src/server/game.zig` (`traderIsOpen` `:8765`, `tickTraderAreas`
  `:8793`, `toggleTraderGates` `:8811`), `src/assets/blocks.zig`
  (`IndexName=TraderOnOff`), `asm.il:862122-862230`,
  `asm.il:531757-531898`, `asm.il:531397-531420`, `asm.il:861688-861690`,
  `TraderArea.il.txt:244` (`SetClosed`)

- **TraderArea replication (NetPackageWorldAreas)** `WORKS`
  The body is built and sent in the join bundle right after SpawnPoints (stock
  order): `byte cVersion=1`, `i16 count`, per area Position i32x3, PrefabSize
  i16x3, GetProtectPadding s8x3, teleport volumes (u8 count + startPos s8x3 /
  size u8x3) - layout extracted from the IL dump
  (`NetPackageWorldAreas::write` IL=31, `TraderArea::Write` IL=111). Data comes
  from the trader POIs' XML (`TraderAreaProtect`, `TeleportVolumeStart/Size`).
  Note: `TraderArea::Write` does **not** serialize `IsClosed` - the IL tail is
  `ret` right after the teleport loop (`TraderArea.il.txt:721-788`), so the
  client learns the open/close state from the `SetClosed` gate block toggles and
  its local TraderInfo hours, not from this package. `TraderAreaStates`
  (`Default=0, Claimable=1, NotClaimable=2`, 1207071-1207078) is a
  claimability enum, not an open/closed wire signal. The earlier "IsClosed
  state sync ... ride the TraderAreaStates updates" claim was wrong; corrected
  against the IL.
  *Anchors:* `src/wire/packages.zig` (`buildWorldAreasBody`),
  `src/server/game.zig` (`sendWorldAreas`), `src/world/prefabs.zig`
  (`QuestData.is_trader_area`), `../7dtd-research il dump` `TraderArea.il.txt:721`

- **Vending machines** `WORKS`
  The vending TE (TileEntityVendingMachine, type 7) is now emitted: a
  world-position `vending` store keyed by block place/remove, TraderData seeded
  from trader_info by the block's `TraderID` (blocks.xml Class/TraderID parsed
  with Extends resolution), `NetPackageTileEntity` pushed on chunk stream and on
  LockRequest open (VendingMachineLockContext echoes the request's context type,
  byte-correct per `TileEntityVendingMachine::write`: chunkPos | ver 3 |
  isLocked | owner | password | allowed | rentalEndDay | TraderData |
  nextAutoBuy-if-rentable). **Persistence** ships (`vending.zig` save/load,
  ZVNM fuzzed). **Rent SM ships 2026-08-07**: `NetPackagePlayerVendingMachine`
  (userId stream + Vector3i + removing, asm.il 833593) is handled
  server-authoritatively - only the sender's own identity may act; rent costs
  `TraderInfo.RentCost` casinoCoin currency (inventory first, then wallet,
  trade's rule); the term is `rent_time` in-game days (stock default 30);
  one machine per player (CanRent 2); re-rent extends; an expired rental
  (currentDay > rentalEndDay) returns to Unowned on the day roll; `removing`
  clears ownership only (the block identity and stock survive). Scenario
  `vending-rent` covers rent/deny/extend/clear/expire/one-per-player.
  **Real-client trade CopyFrom (2026-08-07, hardened + restored 2026-08-22)**:
  the stock NetPackageTraderData ToServer body (isEntity | entityId/tePosition
  | hasTraderData | TraderData::Write, asm.il 843046) is parsed and mirrored
  (stock TraderData.CopyFrom, loot-economy.md 5) onto the entity trader's sim
  stock or the vending store - count/markup/money from the client's post-trade
  copy, while price/sell stay server-owned (the wire carries no price).
  2026-08-10 removed the apply (any peer could mint/rewrite the economy);
  2026-08-22 restored it stock-faithfully behind two gates: the sender's
  player must be within trade reach of the trader/machine (the client can only
  open the window in use range; closes the world-wide rewrite vector), and
  every echoed entry must resolve to a real item with quality 1-6. Entries
  merge by item type, not index (a client drops a depleted PrimaryInventory
  row and a vending sell appends a new one). The loadgen/sim 9-byte trade
  body still works (length-distinguishable). Scenario `traderdata-copyfrom`
  covers both branches (out-of-reach ignored, in-reach buy/sell applied).
  **Owner lock/password/allowed editing ships 2026-08-07**: the vending TE
  composite C2S (the mirror of TileEntityVendingMachine::write, payload
  version i32 3) is parsed (`parseVendingTeBody`) and applied owner-gated -
  only the machine's owner may change isLocked / password / the allowed-user
  list; ownership and the rental term stay server-applied (the rent SM owns
  them), and the reach check matches the other TE paths. Scenario
  `vending-edit` covers owner apply + non-owner denial. The vending gap row
  is now fully closed.
  *Anchors:* `src/world/vending.zig`, `src/wire/stock_te.zig:789-881`
  (`buildVendingTeBody`), `src/server/game.zig:6596-6618` (LockRequest vending
  branch), `:6760-6766` (place/remove lifecycle), `:9425-9480`
  (`sendVendingTe`/`fillVendingStore`), `src/assets/blocks.zig:124-237`
  (Class/TraderID + Extends), `asm.il:440486` (`TileEntityVendingMachine::write`),
  `Data/Config/blocks.xml:51104`, `Data/Config/traders.xml:1472`

- **Quest offering via NetPackageNPCQuestList** `WORKS` `(2026-08-22 re-audit)`
  The reply is legal (base direction Both) and the bodies are right; the
  trader entities replicate (replicate.zig kind-groups + trader data), so the
  client's ProcessPackage `GetEntity(id) as EntityTrader` resolves and the
  offers land - the "no trader entity on the client" premise is stale. The
  exchange is complete: FetchList answers with the trader's quest_list (npc.xml
  per trader_info id, fallback class-hash map), RemoveQuest accepts the picked
  offer into the journal (tier-filtered, giver position = the offering trader)
  and re-sends the list without it. Scenario `trader-quest-open` drives the
  open → accept → turn-in loop.
  *Anchors:* `src/server/c2s/quest.zig:250-330`, `src/server/game/replicate.zig:80-155`,
  `src/assets/npc.zig`, `asm.il:827745-827765`

- **Quest turn-in / phase advance on trader open** `WORKS` `(2026-08-22)`
  `questOnTraderOpen` advances trader_interact phases and completes
  ready_turn_in quests (paying the reward), and it fires on the **stock
  client's open path**: the `NetPackageLockRequest` trade-window open
  (channel 1, EntityTraderLockContext) triggers it in the lock handler, so a
  stock client's trader visit advances and turns in quests without any
  zdtd-only package (the NetPackageTraderData branch stays as a fallback for
  clients that signal the open that way). Scenario `trader-quest-open` drives
  the whole path over the wire: the Goto→Interact→TurnIn starter completes on
  the second lock-open with the coin reward, and a fetch quest parked at
  ready_turn_in completes on a single open.
  *Anchors:* `src/ecs/systems.zig:900` questOnTraderOpen,
  `src/server/c2s/misc.zig:674` (lock-open call site),
  `src/server/c2s/quest.zig:342` (TraderData fallback), scenario
  `trader-quest-open`

- **Trader dialog window, greeting, voice, radial commands** `PARTIAL (waived)`
  Talk/voice/radial dialogs (`XUiC_DialogWindowGroup`, `dialogs.xml`) are client
  UI chrome; trading opens via lock channel and `traders.xml` stock already.
  *Anchors:* `asm.il:530944-530960`, `src/assets/xml_patch.zig:100`

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

**23 WORKS · 0 PARTIAL · 0 MISSING**

- **Blood-moon day schedule from BloodMoonFrequency** `WORKS` (2026-08-20)
  Stock `CalcNextDay` (asm.il 412880) is implemented as a persisted schedule:
  `next_bm = bm_day_last + frequency + jitter(cycle)` rolled forward past the
  live day, stored on the WorldClock and saved with the clock (ZCL2;
  ZCL1 files restore the clock and rebuild the schedule), so the schedule is
  seekable across restarts and admin day-jumps keep the client's red moon on
  the horde night. `0` disables (zdtd policy divergence, documented). The
  horde spans dusk to dawn across the midnight rollover (IsBloodMoonTime).
  *Anchors:* `src/ecs/aidirector.zig:41`, `src/server/game/clock_persist.zig`,
  `asm.il:412880`, `asm.il:412986`

- **BloodMoonRange jitter** `WORKS` (2026-08-20 reconciliation)
  The persisted schedule (slice: CalcNextDay) jitters each cycle by the
  stock's non-negative `RandomRange(0, range+1)` (deterministic hash of the
  cycle), so a blood moon is never early relative to the frequency multiple;
  `GameStats.BloodMoonDay` reads the same jittered schedule day, so the
  server-simulated horde night and the client-rendered red moon are always
  the same day. `BloodMoonRange` is parsed from serverconfig (clamped 0..15)
  and plumbed to both the clock and the director.
  *Anchors:* `src/ecs/aidirector.zig:100`, `:116`, `src/server/game.zig:587`,
  `:594`, `src/server/config.zig`
  `asm.il:412894`, `src/server/config.zig:231`

- **Blood-moon night window (dusk to dawn)** `WORKS`
  `isBloodMoonNight` now mirrors stock `IsBloodMoonTime` (asm.il:1926341):
  active on `day==bmDay` when `hour>=dusk`, and on `day==bmDay+1` when
  `hour<dawn` - so the horde runs dusk on the blood-moon day through dawn of
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

- **GameStats.BloodMoonDay sent to the client** `WORKS` (2026-08-20
  reconciliation) Computed and written at the BloodMoonDay slot of the full
  persistent blob, sent at join and on the respawn re-bundle, and re-broadcast
  whenever the scheduled day changes: `step.zig` diffs the resolved
  blood-moon day against the last-sent value every tick, so a natural day roll
  OR a `settime` jump (forward or backward) re-sends the stats on the next
  tick. A connected client always holds the current horde night.
  *Anchors:* `src/server/game.zig:6214`, `:6216`, `:6206`, `:3869`,
  `src/wire/packages.zig:1998`, `src/server/game/step.zig`

- **Client blood-moon sky FX** `WORKS`
  Entirely client-side: `SkyManager::OnGameStatsChanged` latches bloodmoonDay from
  stat 58 and dusk/dawn from stat 42, and `IsBloodMoonVisible` recomputes the
  window as `(dusk-4, dawn+2)`. zdtd sends both stats so the mechanism is wired;
  stat 58 now carries the jittered horde day (CalcNextDay, not the plain
  frequency multiple), so the red moon lands on the actual horde night even with
  BloodMoonRange > 0.
  *Anchors:* `asm.il:2041922`, `asm.il:2042093`, `src/wire/packages.zig:1998`,
  `src/ecs/aidirector.zig` (`bloodMoonDayFor`), `src/server/game.zig:589`
  `:1983`

- **Blood-moon warning window (red HUD clock)** `WORKS` (2026-08-20
  reconciliation) Stock has no warning packet: `XUiC_CompassWindow` colours
  the clock FF0000 when `GameStats[BloodMoonDay]` equals the client's current
  day and `World::BloodMoonWarningHour <= hour` (default 8; sandbox option
  -1 off / 8 / 18, applied from the SandboxCode the client decodes). zdtd
  sends the jittered horde day (re-sent on any day change) and the operator's
  `SandboxCode` is forwarded verbatim in the stats blob (RE sandbox-options
  §3/§8: empty code = stock defaults, groups encode only changed options), so
  the red clock fires on the real horde night at the configured hour.
  *Anchors:* `asm.il:1574299`, `asm.il:1248240`, `asm.il:2502629`,
  `asm.il:1913041`, `src/wire/packages.zig:1892`, `:2001`, `src/server/game.zig:393`

- **NetPackageBloodmoonMusic** `WORKS` `(2026-08-21)`
  Builder is IL-correct; eligibility is now **per player** like stock
  (`EntityPlayer.bloodMoonParty`): a player hears the horde music only while
  the horde is active AND their own blood-moon party (focus within
  party_join_dist) still has alive horde zombies. The broadcast path tracks a
  per-client edge on the 20-tick pass, and a client joining (or respawning)
  during an active horde receives its own party's current eligibility with the
  join bundle, so join-during-BM hears the horde music when its party is
  horded. The old single global bool (every player heard any party's horde) is
  gone; scenario `bm-music` proves a far-away second party stays silent.
  *Anchors:* `src/server/game.zig` `playerBloodMoonMusic`,
  `src/server/game/step.zig` per-client music pass,
  `src/server/game.zig` join bundle, `src/wire/packages.zig:896`,
  `asm.il:807834`, `asm.il:2593714`, `asm.il:807889`, il EntityPlayer.bloodMoonParty

- **NetPackageHordeEvent** `N/A (parity)`
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

- **Horde spawn composition** `WORKS` (2026-08-20 reconciliation)
  Blood-moon spawns draw from the `BloodMoonHorde` spawner in `gamestages.xml`
  at the party gamestage frozen at dusk (`stageGroup` resolves the ladder via
  the Game's `pickStageGroup`, wave capped by the stage `maxAlive`), and the
  ladder's entitygroup (e.g. `feralHordeStageGS1..GS4086`) is resolved through
  entitygroups.xml into per-class stats. The composition escalates with level
  and day instead of repeating the ordinary night group.
  *Anchors:* `src/ecs/aidirector.zig:400`, `:521`, `:644`, `src/server/game.zig`
  `pickStageGroup`, `Data/Config/gamestages.xml:4428`,
  `Data/Config/entitygroups.xml:15809`

- **Escalation by gamestage** `PARTIAL (waived)`
  Gamestage is holistic (party stage, loot quality, quest tier, spawn ramps);
  blood moon is intentionally flat (constant `BloodMoonEnemyCount/2` burst) until
  the full `GameStageDefinition` stage machine lands. Waived as progression
  subsystem, not wire fake.
  *Anchors:* `src/ecs/aidirector.zig:163`, `src/assets/xml_patch.zig:99`

- **BloodMoonEnemyCount semantics** `WORKS` (2026-08-20 reconciliation)
  Parsed (clamped 0..60). The party spawner enforces the stock per-party
  alive cap `enemyActiveMax = min(30, count * partyMemberCount)` (asm.il
  413818 / 412041) as `min(party_enemy_max 30, count * party.members)` per
  party; the 6 s burst wave (`max(1, count/2)`) is capped by the gamestages
  ladder's `maxAlive`, matching stock's burst cadence.
  *Anchors:* `src/server/config.zig:226`, `src/ecs/aidirector.zig:401`, `:648`,
  `src/ecs/rules.zig:221`, `asm.il:413818`, `asm.il:412041`

- **Alive-zombie budget during a blood moon** `WORKS` (2026-08-20)
  `Director.tick` gates spawns on a per-tick ceiling: the world
  `MaxSpawnedZombies` cap normally, and `CanSpawn(1.9f)` (asm.il:413528) - a
  1.9x ceiling - while the blood moon is active, so the horde does not thin
  at the ordinary cap. A spawn batch may overshoot the ceiling by its own
  size (the gate runs at tick start; stock CanSpawn behaves the same).
  *Anchors:* `src/ecs/aidirector.zig:370`, `:378`, `src/server/config.zig:46`,
  `asm.il:413528`

- **Spawn placement and spawn direction rotation** `WORKS` (2026-08-21)
  The per-player ring spawns on the A36-aligned rules radii (28-54 m) with a
  deterministic per-spawn bearing jitter (seeded from the spawn counter, no
  global RNG), so consecutive waves no longer repeat the same pattern and
  zombies stop materialising from identical bearings every tick. The blood-moon
  party spawner uses the stock `cSpawnDistance 40` + 0..10 jitter ring. The
  exact stock jitter shape (45 deg around the group base, 120 deg per-group
  rotation) is approximated by the seeded full-circle jitter; the ring radii
  are the rules tunable (`[rules.director] enemy_spawn_ring_*`).
  *Anchors:* `src/ecs/aidirector.zig:548`, `:656`, `asm.il:413135`,
  `asm.il:414107`, `asm.il:413541`

- **Blood-moon party grouping (multiplayer)** `WORKS`
  Online players are clustered into blood-moon parties (within
  `cPartyJoinDistance = 80`), each with a focus (running average) and a
  per-party alive ceiling `min(cPartyEnemyMax 30, BloodMoonEnemyCount x
  members)`. One shared wave spawns per party around the focus (`cSpawnDistance`
  40 + up to 10 jitter, rotating ~120 degrees), marked `IsHordeZombie`
  (`zombie_ai.is_horde`); the party gamestage is frozen at dusk
  (`bm_stage_frozen`, InitParty) for the night's ladder; horde zombies past
  `cTeleportDist = 150` from their nearest focus are teleported back every tick;
  dawn clears horde marks and the frozen stage (EndBloodMoon). 2 players in
  range now get one pooled horde, not double spawns.
  *Anchors:* `src/ecs/aidirector.zig` (`party_join_dist`/`BmParty`,
  `buildBloodMoonParties`, `spawnBloodMoonParties`, `recountAndTeleportHorde`,
  `clearHordeMarks`), `src/ecs/components.zig` (`ZombieAi.is_horde`),
  `asm.il:413090`, `asm.il:412744`, `asm.il:413818` (InitParty), `asm.il:414221`,
  `asm.il:412618` (EndBloodMoon)

- **Blood-moon zombie strength** `WORKS` `(2026-08-22)`
  Real and observable: `ZombieBMMove` speed band while active, and
  `BlockDamageAIBM` replacing `BlockDamageAI` (both stock serverconfig
  options). `(2026-08-22)` the flat 1.5x HP multiplier is gone for stock
  data: the gamestage ladder's BloodMoonHorde groups already pick
  feral/radiated classes with their own stats (the stock difficulty
  source), so a resolved ladder class spawns at its class HP; the
  `bloodmoon_hp_mult` floor (default 1.5) remains only for the unresolved
  class_table fallback (offline/builtin data, no ladder). Test
  `blood-moon HP floor applies only to unresolved fallback classes`.
  *Anchors:* `src/ecs/aidirector.zig:733` (bm_mul gate), `:218`,
  `src/server/game.zig:3097`, `src/server/config.zig:51`, `:57`

- **Blood-moon end and despawn at dawn** `WORKS` (2026-08-20)
  The horde window spans dusk to dawn (IsBloodMoonTime); at dawn the director
  clears the horde marks on every alive zombie (stock EndBloodMoon clearing
  IsHordeZombie / IsBloodMoon - the is_horde flag is the chunk-pinning
  equivalent) and the music/weather release. A wiped party kills its horde
  immediately (stock KillPartyZombies), and survivors after dawn are ordinary
  zombies that despawn by distance like stock (no forced despawn).
  *Anchors:* `src/ecs/aidirector.zig:409`, `:413`, `:601`, `aidirector.md`
  EndBloodMoon (412618) / party Tick
  dawn anyway.
  *Anchors:* `src/ecs/systems.zig:1707`, `:1722`, `src/server/game.zig:8116`,
  `asm.il:412618`, `asm.il:413662`

- **Blood-moon bonus loot bags** `PARTIAL (waived)`
  Stock `LootBonusScale` / `bonusLootEvery` bump on horde is not yet wired; horde
  uses the ordinary `LootDropProb` path. Bonus loot needs true gamestage; waived
  until progression/gamestage land.
  *Anchors:* `asm.il:413875`, `asm.il:414005`

- **Blood-moon corpse decay / chunk pinning** `PARTIAL (waived)`
  Stock horde `bIsChunkObserver` / 3x gib cleanup is noted but not wired: the
  chunk pin needs stock dedi layout RE and `IsBloodMoon` is not on the wire
  either. Horde itself is parity-path, pinning is retention polish — waived.
  *Anchors:* `asm.il:412595`, `asm.il:413978`

- **Blood-moon schedule persistence across restart** `WORKS`
  The world clock (day + hours, stock worldTime encoding) is saved to
  `clock.zcl` on the periodic save path and at deinit, and restored over the
  fresh clock at init. The blood-moon calendar derives from the day, so a save
  keeps its horde schedule instead of resetting to day 1. (Stock also persists
  bmDay/bmDayLast/bmDayNextOverride; zdtd's schedule is deterministic from the
  cycle + CalcNextDay jitter, so the day is the only state.)
  *Anchors:* `src/server/game.zig` (`saveClock`/`restoreClock`),
  `src/ecs/aidirector.zig` (`WorldClock`), `src/server/game.zig:579`
  `asm.il:412351`, `asm.il:412406`

- **Console/admin visibility of the blood moon** `WORKS`
  `gettime` prints "bloodmoon in N days" and the webui status page shows
  ACTIVE/idle plus the frequency and "next in Nd" - all three now read the
  jittered CalcNextDay schedule (`daysToBloodMoon` → `bloodMoonDayFor`), so
  BloodMoonRange no longer puts the countdown on the wrong night. Forcing a
  blood moon still goes through stock's `ActionSetHordeNight` gameevent
  (there is no `bloodmoon` console command in V3.1.0 either).
  *Anchors:* `src/server/admin_console.zig:309-315,529-539`,
  `src/server/webui.zig:1425-1457`, `asm.il:412317`

- **settime command arity** `WORKS` `(2026-08-22 re-audit)`
  `settime` follows the stock ConsoleCmdSetTime arity (asm.il 251900): 1 arg
  `day` / `night` / a lone numeric as raw world time (1000 = one hour; the
  playtest `settime_bloodmoon` barrier sends `settime 22000` and lands the
  clock at 22:00), or 3 args `day hour minute` through
  GameUtils::DayTimeToWorldTime; other arities are rejected with the stock
  message. Test pins the raw-time path.
  *Anchors:* `src/server/admin.zig:764-792`, `asm.il:251877`,
  `src/server/game/tests.zig:1183-1190`

- **Where the blood-moon options come from** `WORKS` `(2026-08-23 re-audit)`
  The V3.1.0 SandboxCode path is implemented end to end (the row's
  "writes empty SandboxCode" claim was stale): the operator's
  `serverconfig.xml` SandboxCode (default `AAAJABJACJADJARFBNC`) parses into
  `cfg.sandbox_code`, `src/assets/sandbox.zig` decodes the option stream
  (RE sandbox-options §8) and `config.zig applySandboxCode` overlays
  BloodMoonFrequency/Range/EnemyCount (SandboxOptions 48/49/51 per
  `UpdateInGameValuesWithSandboxOptions`, asm.il:2501770) onto the sim
  config, which feeds the CalcNextDay schedule (stat 58 row, WORKS). The
  same string echoes verbatim into GameStats(71) (`packages.zig:2217`), so a
  joining client decodes the server's settings instead of its local
  GamePrefs. The legacy BloodMoonFrequency serverconfig property remains a
  fallback when no SandboxCode is set.
  *Anchors:* `src/server/config.zig:313-340,422-423,459`,
  `src/assets/sandbox.zig:149`, `src/wire/packages.zig:2217`,
  `asm.il:2501770`, `serverconfig.xml:103`

- **Wandering horde / screamer heat** `WORKS`
  Both components now exist alongside the blood-moon component:
  `AIDirectorWanderingHordeComponent` (scheduled 6-pack at ~92 m) and
  `AIDirectorChunkEventComponent` (region heat map, forge/campfire feed,
  threshold-25 scout spawns with cooldowns). Residual: the fixed daytime scout
  drip stays as the fallback when no heat source runs; see the two rows below.
  *Anchors:* `src/ecs/aidirector.zig:159`, `:168`, `asm.il:409351`,
  `Data/Config/gamestages.xml:1582`, `:3458`

- **Blood-moon death bookkeeping (IsBloodMoonDead)** `WORKS`
  `Player.is_blood_moon_dead` is set when a player dies during an active blood
  moon (stock `EntityPlayer` death sets `IsBloodMoonDead = BloodMoonActive`,
  asm.il 412541-412547) and cleared on respawn (stock
  `get_unModifiedGameStage`). The horde target pass excludes these players
  (stock `EAISetNearestEntityAsTarget` skips them), so zombies hunt the living;
  the despawn pass keeps them so a corpse still pins distant zombies. The
  `StartBloodMoon` clear is covered by the respawn clear (a dead player cannot
  hold the flag into the next horde).
  *Anchors:* `src/ecs/components.zig` (`Player.is_blood_moon_dead`),
  `src/ecs/world.zig:778`, `src/ecs/systems.zig` (`snapshotPlayers`),
  `asm.il:412541`, `asm.il:435831`

---

## 7. POIs and prefabs

**Headline.** Navezgane's POIs are present, stamped from the real stock `.tts`
files and reach a stock client, but they are built from the wrong block ids
(~21% of cells), placed at the wrong height (46% of POIs ignore YOffset) and
rotated the wrong way round for rotation 1/3 (46% of decorations), so a player
can walk into every POI but none of them is the building TFP authored.

**26 WORKS · 4 PARTIAL · 0 MISSING**

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
  `rotateLocalXZ` matches the stock forward map exactly (fixed 2026-08-06
  with the per-block facing work): r=1 gives `(sz-1-z, x)`, r=3 gives
  `(z, sx-1-x)` - stock `Prefab::RotatePointOnY` (`AngleAxis(-90, up)` on the
  `_bLeft` path). The row's earlier "swapped" claim was corrected by the
  sleeper-volume placement re-audit (2026-08-22): volume corners rotated with
  the same `rotateLocalXZ` land in the rooms TFP marked. Data proof cited
  then: 129/130 RoadExit decorations land within 4 blocks of a road pixel.
  *Anchors:* `src/world/tts.zig:328-336`, `asm.il:915424-915618`,
  `asm.il:915620-915698`, `asm.il:921639-921684`, `asm.il:931080-931180`

- **Prefab rotation: per-block facing** `PARTIAL` (step count fixed 2026-08-06)
  The 24-orientation permutation table is correct (re-derived from
  `BlockShapeNew::rotationsToQuats` with the world-space pre-multiply
  `ConvertRotationFree` performs), and the step count is stock's
  `CalcRotation(rot, 4-r)` (`BlockShapeNew::RotateY` replaces `_rotCount` with
  `4-_rotCount` on the left-turn path, `asm.il ~181926`) - applied at
  `src/world/tts.zig:436` as `rotateRawY(raw, 4 -% (rot & 3))`. Re-audited
  2026-08-23: the row's residual "virtual per BlockShape remap" (base
  `(rotation+rotCount)&15` vs a `BlockShapeCube` band-local cycle) does not
  apply to the V3.1.0 data - the stock blocks.xml Shape values are ModelEntity
  (713), New (116), Terrain (17), Water (6), BillboardPlant (4), grass/invisible/
  deco oddments; there are **no Cube shapes** to remap. What remains is the
  ModelEntity rotation model (713 blocks): how stock maps the POI rotation onto
  ModelEntity's facing needs RE (block-shapes.md); until then the New-table
  step is the applied behavior for all shapes.
  *Anchors:* `src/world/tts.zig:293`, `:436`, `asm.il:181926-181957`,
  `asm.il:181959-182018`, `asm.il:173648-173702`, `asm.il:166904-166921`,
  `asm.il:171283-171414`, `Data/Config/blocks.xml` Shape values

- **Prefab YOffset** `WORKS` (2026-08-06)
  `parseYOffset` pulls `<property name="YOffset" value="N"/>` out of each
  prefab .xml (exact name compare against `DistantPOIYOffset`; stock reads
  `properties.GetInt("YOffset")` at the end of `Prefab::Load`, asm.il
  902414-902420) and `Decoration.stampY` applies it: `y_is_ground ? y +
  y_offset : y`. `paintDecoration` stamps at `d.stampY()` and the prefab TE
  loop uses the same origin, so houses sit on their pad and the deep
  structural offsets (canyon_mine -55, the ten caves at -25) drop the body
  below ground instead of stamping a surface box. The runtime terrain
  flatten targets the pad level (`deco.y-1`, "Terrain flatten under a POI
  footprint").
  *Anchors:* `src/world/prefabs.zig:144-155` (`stampY`), `:494`
  (`paintDecoration` call), `:657-665` (`parseYOffset`),
  `asm.il:902414-902420`, `asm.il:917079-917081`, `asm.il:914052`

- **Terrain flatten under a POI footprint** `WORKS`
  The runtime flatten now targets the stock pad level: `dtm_processed.raw`
  carries the pad at `deco.y-1` for 1272 of 1487 Navezgane POIs (already
  perfectly flat for 1101), so forcing the height plane to `deco.y+1` put it 2
  blocks above the floor and teleports, respawns and heightWorld-based
  placement inside a POI landed 2 blocks up. The flatten now writes
  `deco.y-1` (full POIs; parts stay at ground), matching the DTM pad, while
  still leveling uneven terrain and never punching pits under caves/mines
  (the body stamps below the pad). Terrain blocks were already filled from
  the DTM before the flatten, so only the placement-facing height plane
  changed.
  *Anchors:* `src/world/prefabs.zig:203-239` (`applyToChunkHeights`)

- **Painting part_* decorations** `WORKS`
  `applyTtsPaintToChunk` paints parts up to the volume cap (`isPaintablePart`,
  24^3): Navezgane's 72 parts - driveways, town signs for
  Gravestowne/Diersville/Perishton and the Perishton pedestrian bridge - are
  all far under it and render like stock; only the huge RWG clutter parts stay
  skipped. The sleeper load no longer excludes parts: 51 stock parts carry
  authored sleeper volumes (wrecked ambulances, campsites, car accidents) and
  the volume-store ref build feeds them in, so a roadside ambulance spawns its
  hospital sleepers like stock.
  *Anchors:* `src/world/prefabs.zig:232` (`isPaintablePart`),
  `src/server/game/init_world.zig:27-44`, `src/world/sleepers.zig:295`

- **Multi-block / child blocks** `WORKS`
  Prefab files store only the parent cell; `remapToRuntimeIds` now regenerates
  the children (Prefab::AddAllChildBlocks) from each parent's blocks.xml
  `MultiBlockDim`, using the same offset list and child encoding as the deco
  mirror (centered x/z, up in y, ischild bit + parent offsets). Beds, tables,
  double doors and gun safes render solid instead of a single walk-through
  cell; children only fill air cells so authored blocks are never overwritten.
  The child bit in parsed prefab data is still cleared (V3 files carry no child
  cells; the regeneration is dim-driven).
  *Anchors:* `src/world/prefabs.zig` (`remapToRuntimeIds`),
  `src/world/deco_mirror.zig` (`childRaw`), `asm.il:918950-919033`,
  `asm.il:921630`

- **Prefab authored block damage plane** `WORKS`
  The TTS damage plane (u16 absolute HP per cell, v>8) now lands in the chunk
  damage plane at paint time (`paintDecoration` passes it through `set_block`;
  both the world-materialization and the POI-reset paths write it via
  `Chunk.setDmg`), so POIs stock ships pre-damaged arrive with their ruined
  look and intended weak spots: the wire damage channel reads the plane
  (GAP "Player block damage") and ZCH3 persists it. POI reset restores the
  authored damage and clears wear on pristine cells.
  *Anchors:* `src/world/tts.zig` (`paintDecoration` dmg pass-through),
  `src/world/store.zig:756-775` (`PaintCtx.put`),
  `src/server/game.zig:1634-1651` (`resetPoiBlocks`)

- **Prefab water plane** `WORKS` (2026-08-07)
  The v>=17 sparse water channel is decoded into a dense per-cell `u16` mass
  plane (`TtsBlocks.water`, same sparse-bitstream layout as the texture
  channel) and `tts.paintDecoration` paints the resolved runtime water block at
  every mass>0 cell - POI pools, flooded basements and water tanks render wet.
  The chunk wire's water-mass channel derives full static mass from the water
  block plane, so no separate channel encode is needed. Fail closed: `water_id`
  0 (unresolved AssignIds) skips water paint. Test builds a synthetic v19 file
  with one water cell and asserts the decode and the painted block.
  *Anchors:* `src/world/tts.zig` `parseBlocks` / `paintDecoration`,
  `src/world/prefabs.zig` `applyTtsPaintToChunk`, `src/world/store.zig`,
  `src/server/game.zig` `resetPoiBlocks`

- **Prefab texture/paint plane** `WORKS`
  The sparse texture bitstream is decoded into a dense per-cell u64 and carried
  through `setBlockTexDens` onto the wire, so paint-driven shape blocks keep their
  face material instead of rendering grey.
  *Anchors:* `src/world/tts.zig:148`, `src/world/store.zig:597`

- **Prefab tile-entity list to world positions** `PARTIAL` `(2026-08-23 re-audit)`
  TEs rotate with the same stock-clockwise `rotateLocalXZ` as the paint, so
  they land where the stamped building puts them (the "180 degrees off" claim
  predates the 2026-08-06 rotation fix). The local position + type byte drive
  the world-container seeding (`chunk_fill.zig` onTe: Loot/SecureLoot/
  Composite storage types fill from the block's LootList - "Loot content per
  container" WORKS). Re-audit 2026-08-23 (full-prefab scan with the real .tts
  parser): the row's "authored contents / lock state / sign text payload is
  dropped" claim is **data-absent** - V3.1.0 prefab .tts files carry **zero**
  Loot (5) / SecureLoot (10) / Sign (13) TE entries across the whole POI set;
  the TE lists hold Light (18) and Sleeper (20) markers plus oddments, so
  there is no authored loot/lock/sign payload to decode (POI safes fill from
  their block LootList; POI signs carry no authored text in the data). The
  **The Light TE (18) now emits too** (2026-08-23): the persistency payload
  (RE TileEntityLight.read IL=68: version u16, chunkPos, base-TE tail, then
  LightIntensity/Range f32 + Color32 + v>4 type/angle/shadows) parses into
  a world light store (`world/light_te.zig`), seeded from the .tts markers
  (269 across Navezgane) on chunk fill, and the chunk stream sends the stock
  TileEntityLight network body (tile-entities-power.md TileEntityLight.write
  IL=48) - POI lights render with their authored colour/intensity/range.
  The "server light model" residual is the chunk light-level propagation
  (daylight/night lighting), RE-blocked separately.
  *Anchors:* `src/world/prefabs.zig:534-560` (`foreachTeInChunk` payload),
  `src/world/tts.zig:247-292` (payload capture), `src/world/light_te.zig`
  (store + parsePayload), `src/server/game/chunk_fill.zig:246-270`,
  `src/server/game/chunk_stream.zig` (light TE send), `src/wire/stock_te.zig`
  `buildLightTeBody`, `src/wire/te_types.zig`,
  full-prefab TE scan (2026-08-23, types 5/10/13 = 0)

- **TileEntityType constants** `WORKS`
  `src/wire/te_types.zig` now matches the stock enum exactly (RE IL
  1311761-1311788, tabulated in 7dtd-research world-generation.md): None=0,
  Collector=3, LandClaim=4, Loot=5, Trader=6, VendingMachine=7, Forge=8,
  Campfire=9, SecureLoot=0x0A, SecureDoor=0x0B, Workstation=0x0C, Sign=0x0D,
  GoreBlock=0x0E, Powered=0x0F, PowerSource=0x10, PowerRangeTrap=0x11,
  Light=0x12, Trigger=0x13, Sleeper=0x14, PowerMeleeTrap=0x15,
  SecureLootSigned=0x16, Composite=0x19, Taskboard=0x1B. The old table
  (loot=1, composite=5, sign=0x16, light=0x19, powered=10) classified the
  real prefab TE bytes wrongly - Composite(25) was only accepted through the
  mislabeled `light` constant and a real Loot(5)/SecureLoot(10) TE would be
  dropped; the TE scan now classifies Light(18)/Composite(25) as storage
  seeding sources and Sleeper(20) as not, per the real values.
  *Anchors:* `src/wire/te_types.zig`, `src/server/game/chunk_fill.zig:248-252`,
  `asm.il:1311761-1311788`

- **Loot container discovery in a POI chunk** `WORKS` `(2026-08-21)`
  Chunks are scanned for storage ids (`maxdamage` LootList/CompositeTileEntity
  ∩ AssignIds; prefab-local ids were remapped through `<name>.blocks.nim` in
  2026-08-06, so the un-remapped-id blindness is gone) with an id-verdict memo
  and a per-chunk cap, and the prefab TE list (Loot/SecureLoot/Composite/
  powered/sign/light) seeds containers from the authored tile entities. The
  global store is now 4096 entries with **world-container eviction**: when the
  table is full, `getOrCreate` reuses a non-player-placed container (it
  regenerates deterministically from the next chunk scan) and never evicts a
  player-placed chest, so Navezgane's thousands of loot containers all appear
  and stay lootable (the old 256/512 hard cap silently emptied the tail).
  Container size derives from loot.xml per fill; loot respawn re-rolls after
  LootRespawnDays (Loot respawn row).
  *Anchors:* `src/server/game/chunk_fill.zig` ensurePrefabStorageInChunk,
  `src/world/containers.zig` getOrCreate + max_containers,
  `src/world/prefabs.zig` foreachTeInChunk

- **Loot content per container** `WORKS`
  `fillContainerFromLoot` now takes the block's `blocks.xml` LootList via
  `maxdamage.lootListFor` (resolved through `Extends`), so a gun safe rolls
  `smallSafes`, a chest `woodenChest`, and a medicine cabinet its own table.
  `blocks.xml` declares ~172 distinct LootList values across 449 blocks and
  `loot.xml` defines 340 lootcontainers; the mapping now exists end to end.
  *Anchors:* `src/server/game.zig` fill sites, `src/assets/maxdamage.zig`
  `lootListFor`, `Data/Config/blocks.xml`, `Data/Config/loot.xml`

- **Loot container size** `SIZED (2026-08-08)`
  `fillContainerFromLoot` derives the storage grid from the `lootcontainer`
  size attribute (woodenChest 6,2 = 12; gunSafe 8,9 capped at 54;
  smallSafes 8,5 = 40) and rolls up to the container's own capacity, so the
  client shows the block's real cell count instead of a flat 8. The save
  round-trips slot_count; the respawn re-roll re-derives it. The wire still
  shapes the grid 2xN (cell COUNT is correct; the exact x/y column layout is
  cosmetic).
  *Anchors:* `src/server/game.zig` fillContainerFromLoot,
  `src/world/containers.zig:31`, `Data/Config/loot.xml`

- **Loot respawn (LootRespawnDays / LootTimer)** `WORKS` `(2026-08-07)`
  `serverconfig.xml LootRespawnDays` (default 7, 0 disables) drives a lazy
  re-roll on open: a looted world container (empty slots, `touched`, not
  player-placed) whose `touched_day` is at least the interval behind the
  current day regenerates fresh loot on the next `NetPackageInventoryDataRequest`,
  with a cycle-varying seed so each respawn differs while staying deterministic
  per (pos, cycle). `touched_day` persists in ZCT1 (appended, length-detected
  on load; older saves read 0 and do not respawn immediately). World containers
  are marked `player_storage=false` at materialization so they are eligible;
  player-placed storage never respawns (stock `bPlayerStorage`).
  *Anchors:* `src/world/containers.zig:31`, `src/server/game.zig:7445`

- **POI reset / rebuild** `WORKS` (quest-tag filter residual)
  `resetPoiBlocks` re-paints a POI's baked .tts blocks over the area
  (PrefabInstance.ResetBlocksAndRebuild shape, asm.il 945360-945387), restoring
  destroyed or cleared POIs when a quest dedicates them: the rally-marker
  activation and lock-acquisition quest events reset the locked POI. Each
  changed block broadcasts the authoritative SetBlock; textures/densities ride
  the world raw+tex path. Residual: stock resets only quest-tagged blocks (a
  base built inside a POI survives stock's reset); zdtd re-paints the full
  prefab footprint, and lockout-expiry reset is not wired (only dedication).
  *Anchors:* `src/server/game.zig` (`resetPoiBlocks`, `handleQuestEvent`),
  `src/world/store.zig` (`setBlockTexDensWorld`), `src/world/tts.zig`
  (`paintDecoration`), `asm.il:945360-945387`

- **Quest POI lockout table** `WORKS`
  Lock/unlock/expire with the 2000-tick grace, quester list, rect containment and
  table bound, grounded in `QuestEventManager`/`QuestLockInstance` and covered by
  three unit tests.
  *Anchors:* `src/ecs/poi_lock.zig:19`, `:90`, `:115`, `asm.il:1001892-1002045`

- **POI rect lookup for quests** `WORKS` `(2026-08-22 re-audit)`
  Returns the prefab AABB (correct and rotation-independent); `part_*` city
  parts are excluded, so a driveway or sign can no longer be the POI a
  quest anchors to. The prefab Index also parses each POI's `QuestTags` +
  `DifficultyTier` (`questData`). Re-audit 2026-08-22: the quest POI is
  selected by the stock selector - `questPoiSelectAt` builds the tier pool
  (GetPrefabsByDifficultyTier), filters tags/biome/lockouts, and picks by
  distance bands / closest with the RE'd constants (min/max distance,
  max 50 attempts, same-biome retry; DynamicPrefabDecorator
  GetRandomPOINearWorldPos / GetClosestPOIToWorldPos) - the "fabricated
  quests.xml coordinates" note was stale. Residual: the tier-pool scan is
  linear over decorations per query (non-client-visible at quest-accept
  frequency, ~1.5k prefabs).
  *Anchors:* `src/server/game/hooks.zig` questPoiSelectAt/selectQuestPoi,
  `src/world/prefabs.zig:66`, `:224`,
  `Data/Prefabs/POIs/AAA_utility_waterworks.xml`

- **Sleeper volume parse** `WORKS`
  Parses the '#'-separated volume list and both `SleeperVolumeGroup` forms with
  the `Vector3i.one` fallback for a missing Size segment. Verified against the real
  `abandoned_house_01.xml` in a unit test.
  *Anchors:* `src/world/sleepers.zig:246`, `:320`, `asm.il:2498294`

- **Sleeper volume world placement** `WORKS` `(2026-08-22 re-audit)`
  Volume corners are rotated with the same stock-clockwise `rotateLocalXZ`
  the TTS paint uses (Prefab::RotatePointOnY AngleAxis(-90, up) path, asm.il
  ~915424; fixed 2026-08-06 with the per-block facing work), so for rot 1/3
  the volumes land in the same rooms TFP marked, not the mirrored half.
  *Anchors:* `src/world/sleepers.zig:226-230`, `src/world/tts.zig:318-335`

- **Authored sleeper spawn points** `WORKS`
  The spawn-marker scan now mirrors stock `Block.IsSleeperBlock`: maxdamage
  resolves each block's `Class` property through `Extends` (asm.il
  133430-133460, RE world-generation.md) into the full 34-block sleeper set
  (18 `sleeper*` + 16 `infestedSleeper*`, count pinned by test), and the
  sleeper load passes that predicate into the `.tts` scan instead of the
  `"sleeper"` name prefix, so the ~338 POIs carrying `infestedSleeper*`
  markers keep their whole authored spawn set. Offline loads (no blocks.xml)
  fall back to the prefix test.
  *Anchors:* `src/assets/maxdamage.zig` (`sleeper_class_names`,
  `resolveSleeperClass`), `src/world/sleepers.zig:249-259,385-391`,
  `src/server/game/init_world.zig:65`, `asm.il:133430-133460`

- **Sleeper volume coverage across the map** `WORKS`
  The volume-store ref build is no longer capped: pass 1 keeps the spawn-near
  POIs first, pass 2 now appends the whole rest of the map (previously it
  broke at 1200 refs, leaving a few hundred far POIs with no sleepers - a far
  building with no sleepers is a dead building). The `max_volumes` budget
  (8192) still bounds the store; stock Navezgane ships ~887 POI + 51 part
  volumes, comfortably inside. Distinct prefab XMLs parse once (xml_cache);
  prefabs without SleeperVolumeSize cost one read.
  *Anchors:* `src/server/game/init_world.zig:26-62`,
  `src/world/sleepers.zig:394-396` (`max_volumes`)

- **Sleeper wake / trigger** `PARTIAL`
  Wakes on player-inside-AABB and on combat noise inside the AABB +0.9 pad
  (stock CheckSleeperVolumeNoise; one-shot `triggered` latch), with
  gamestage-resolved spawn classes and position-seeded count rolls (stock
  AddSpawnCount RandomRange, RE entity-ai.md IL=50). 2026-08-22: the
  `SleeperVolumeGroupId` cascade is in (stock TouchGroup IL=52): a volume with
  a nonzero id wakes every other volume of the same prefab placement sharing
  the id, gated on placement origin so duplicate POI instances never
  cross-wake; scenario `sleeper-cascade`, unit `sleeper volume group ids parse
  per volume`. 2026-08-23: the `triggered` latch now persists (ZSTG1) so a
  restart does not re-pop cleared POIs. Missing: sight/sound/light wake
  thresholds (crouch/darkness do nothing - walking within 20 m always wakes;
  the entityclasses.xml SleeperNoiseToSense/ToWake + SightToWakeMin/Max data
  needs a player movement-noise model, and the light leg needs the server
  light model, both RE-blocked), priority volumes, boss/loot/quest-exclude
  flags, spawn pose (the marker block name encodes Sit/Back/SideLeft/Stomach/
  Idle but is discarded; the wire pose byte table is not in RE), spawnMode,
  respawnMap/respawnTime (RE-blocked).
  *Anchors:* `src/server/game/sleeper.zig:90-147,154-174`,
  `src/world/sleepers.zig:26`

- **Prefab TE scan as a container source** `WORKS` `(2026-08-22 re-audit)`
  Runs after the block scan, capped at 48 per chunk, and seeds world
  containers from the prefab TE list (Composite 25 / Loot 5 / SecureLoot 10
  storage types, plus Light 18 and sign-like for the visual TE filters) with
  the stock TileEntityType values (fixed 2026-08-22): the real .tts TE bytes
  are classified correctly and the containers fill from the block's LootList.
  *Anchors:* `src/server/game/chunk_fill.zig:246-270`,
  `src/wire/te_types.zig`

- **POI block data path into chunks** `WORKS`
  Verified end to end on a live stock client. The client log shows chunk (-17,28)
  meshed and displayed and `poi hb centre(-241,471) ... columnsAboveGround=13/49`;
  its per-y ids are exactly the `.tts` cells of abandoned_house_07 at zdtd's
  rotated local column, so the paint reaches the client cell for cell. Applies to
  the heightmap terrain source only.
  *Anchors:* `src/world/store.zig:589`, `src/world/prefabs.zig:222`, `:404`,
  `output_log_client_zdtd_connect.txt:20533`

- **Trader areas / teleport volumes from prefabs.xml** `WORKS`
  `TraderArea`, `TraderAreaProtect` and `TeleportVolumeStart/Size` are parsed
  from the trader POI XMLs (`QuestData.is_trader_area` + `teleport_*`), and
  `NetPackageWorldAreas` ships the compounds (position, prefab size, protect
  padding, teleport volumes) in the join bundle, so trader compounds have their
  protected areas and closing-time teleport volumes on the client.
  *Anchors:* `src/world/prefabs.zig` (`QuestData`),
  `src/server/game.zig` (`sendWorldAreas`), `asm.il:902420-902440`,
  `asm.il:903590-903616`

- **Prefab entity list** `BLOCKED (2026-08-07, data-absent)`
  The `.tts` entity block only exists for file versions 4..11 and V3 prefabs are
  v19, so nothing is lost from the file itself; zdtd has no equivalent of
  `CopyEntitiesIntoWorld`, but the block it would copy does not exist in the V3
  data. Not player-visible on stock Navezgane data; would need a pre-12 prefab
  sample or a new stock data source to implement.
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

**32 WORKS · 7 PARTIAL · 0 MISSING**

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
  Both reach the director and gate spawning. 2026-08-23: the per-rule
  maxcount leg is in too - the ambient drip enforces each spawning.xml rule's
  `maxcount`/`respawn_days` budget (see "spawning.xml parsing"), so a biome
  rule cannot exceed its authored cap even under the global ceiling. The
  stock per-`ChunkAreaBiomeSpawnData` cell structure itself (80 m cells,
  POI-tag enabled flags) remains a separate row.
  *Anchors:* `src/server/game.zig:581-582`, `src/ecs/aidirector.zig:150-157`,
  `:173-178`, `:265-270` (rule_budgets)

- **GameDifficulty HP scaling** `PARTIAL`
  `hpScale()` multiplies spawn HP by 0.5..2.0 and blood moon adds 1.5x. Stock
  scales incoming and outgoing **damage** via `ItemActionAttack.difficultyModifier`
  (IncomingDamageModifier for server attackers, EntityIncomingDamageModifier for
  client ones, RE combat-damage.md) not max HP, so numbers differ even though
  the felt difficulty moves the right way. 2026-08-23: the per-difficulty
  modifier values are SandboxOption preset data and the dedi dll has no
  `SandboxOptionPreset` class to dump (only the option value types); the
  preset table needs a client-side RE source, so the damage-model change stays
  RE-blocked and the R9 value-level hpScale stays as the documented
  approximation.
  *Anchors:* `src/ecs/aidirector.zig:109-118`, `:216-218`, `:266-267`,
  `asm.il:220834`, `../7dtd-research/docs/combat-damage.md:491-494`,
  `../7dtd-research/docs/sandbox-options.md:305`

- **spawning.xml parsing** `PARTIAL` `(2026-08-23)`
  Parses biome name, entitygroup, maxcount, time, type and respawndelay.
  **maxcount + respawn_days are now consumed** (2026-08-23): the ambient
  drip enforces each biome rule's budget - `Game.biomeRuleBudget` resolves
  the rule under a spawn point and the director gates on `count < maxcount`
  with a respawn-delay roll (stock ChunkAreaBiomeSpawnData CanSpawn +
  ResetRespawn, spawning.md §3; spawned zombies carry the rule tag and
  `World.destroy` releases it on death/despawn; unit test `ambient rule
  budget caps the drip and releases on destroy`). **The `tags` / `notags`
  POI-type attributes now parse and gate too** (2026-08-23): each rule's
  comma lists land on `Rule.tags/notags`, the prefab XML `Tags` property
  feeds `QuestData.poi_tags`, and the group/budget resolvers skip rules
  whose tags fail the position's POI set (stock POITags/noPOITags
  Test_AnySet, spawning.md §2; see "POI-tag spawn filtering"). Live:
  `spawning rules=57`.
  *Anchors:* `src/assets/spawning.zig:14-22`, `:104-127`,
  `src/server/game.zig` biomeRuleBudget/biomeGroupName/ruleTagsAllow,
  `src/ecs/aidirector.zig`
  rule_budgets/budgetAllows/budgetConsume/releaseRule, `src/ecs/world.zig:554-557`,
  `src/world/prefabs.zig` poi_tags/poiTagsAt, `Data/Config/spawning.xml:22-33`

- **Biome-aware spawn group selection at runtime** `WORKS`
  The director's night/day/animal group names are resolved per spawn point: the
  biome map under the position yields the biomemap id, `biomes.xml` maps that id
  to a biome name, and the biome's `spawning.xml` rules pick the night/day/animal
  group (falling back to the load-time group when the biome or rule is unknown).
  A player in the wasteland at midnight now gets `ZombiesWastelandNight` instead
  of pine_forest's `ZombiesNight`. Stock resolves per
  `ChunkAreaBiomeSpawnData` from the actual biome under the chunk.
  *Anchors:* `src/server/game.zig:1332` (callback wiring), `:8595-8611`
  (`biomeGroupName`), `src/assets/biome_layers.zig:159-163` (`nameById`),
  `src/ecs/aidirector.zig:362-371` (per-spawn lookup), `asm.il:1093888`;
  test `server.game.test.biome spawn groups resolve per-biome spawning.xml rules
  on a stock map` + `assets.biome_layers.test.load stock biomes.xml`

- **POI-tag spawn filtering** `PARTIAL` `(2026-08-23, un-waived)`
  The gate is now wired: `spawning.xml` rule `tags`/`notags` parse into
  `Rule`, the prefab XML `Tags` property (the FastTags<Poi> set) feeds
  `QuestData.poi_tags` + `Index.poiTagsAt`, and the ambient group/budget
  resolvers skip rules whose required/forbidden tags fail the position's POI
  set (stock POITags/noPOITags Test_AnySet, spawning.md §2 + IL
  1094100-1094300) - city rules (`tags="commercial,industrial"`) now fire
  inside the matching POIs and the `notags="commercial,industrial,downtown"`
  wilderness rules stay active outside them. Approximation: the stock
  unions the tags over an 80 m area (GetPOIsAtXZ +80/16 chunk expansion,
  once per area, cached in checkedPOITags) and scans up to min(5, count)
  groups from a random start; zdtd tests the single POI under the spawn
  point with the deterministic first-matching-rule walk.
  *Anchors:* `asm.il:1094100-1094300`, `src/assets/spawning.zig` Rule.tags/
  notags, `src/world/prefabs.zig` poi_tags/poiTagsAt, `src/server/game.zig`
  ruleTagsAllow/tagsAnySet, `Data/Config/spawning.xml:22-33`

- **Chunk-area spawn ledger** `PARTIAL (waived)`
  Stock keeps per-group counts, DecMaxCount/IncCount and `OnEntityUnloaded`
  ledger; zdtd uses one global alive + fixed cooldowns. Per-area density needs
  the chunk-group state machine — waived as spawn-balance polish.
  *Anchors:* `asm.il:1093735-1093863`, `src/ecs/aidirector.zig:159-178`

- **entitygroups.xml weighted group table** `WORKS` `(2026-08-22 re-audit)`
  The 512-group cap is gone: the table is now a flat arena slice and the parse
  walks the whole file, so all ~1890 stock groups load (the file comment cites
  1875 groups and feralHordeStageGS2 at index 1177, the tail that the old cap
  dropped - the gamestage-keyed horde/sleeper/scout lists). Picks stay
  deterministic integer milli-weight (round(weight*1000), fixed-point walk so
  the pick path does not depend on f32 accumulation order).
  *Anchors:* `src/assets/entitygroups.zig:20-27` (arena slice), `:106-125`
  (uncapped parse), `src/server/game/init_assets.zig:236` (n= count)

- **Entity class variety actually reachable at spawn** `RESOLVED (2026-08-08)`
  The class_table is still the fixed 16-slot offline cache, but a spawn-picked
  class that is not preloaded resolves through `resolveSpawnClass`
  (entityclasses.xml by name) and spawns with its own stats, so all 293
  loaded classes are reachable with per-class behaviour instead of silently
  falling back to zombieBoe.
  *Anchors:* `src/server/game.zig` resolveSpawnClass, `src/ecs/aidirector.zig`
  spawnOneZombie + class_resolve_fn,
  `src/ecs/aidirector.zig:246-265`

- **Per-class movement speed and attack damage on spawned zombies** `PER-CLASS (2026-08-08)`
  The spawn carries the resolved entityclasses stats (chase/wander speeds,
  HandItem damage, HP, hash, loot) on the entity's class_id, and the AI reads
  the per-entity values first, then the class_table, then the Rules floor, so
  a spawned zombieSpider or zombieFeral moves and hits like its class instead
  of zombieBoe.
  *Anchors:* `src/ecs/world.zig` spawnZombieDef, `src/ecs/systems.zig`
  per-entity speed/damage reads, `src/ecs/aidirector.zig` spawnOneZombie

- **Gamestage** `PARTIAL` (2026-08-06, refreshed 2026-08-08)
  `src/assets/gamestages.zig` parses gamestages.xml (config / group / spawner
  ladders) and resolves sleeper volume groups, the blood-moon spawner stage,
  daytime scout tiers and the `gamestage [slot]` admin command against the party
  stage; `gameStageBornAtWorldTime` rides the PlayerId PDF so the client's own
  `gamestage` readout agrees with the server. (2026-08-22) cross-session
  days-alive persistence is closed (ZPV9 born time) and the biomes.xml stage
  modifiers are in (gamestage_modifier/bonus + lootstage_modifier/bonus parse
  into biome_layers and feed gameStageOf/lootStageOf by the player's biome,
  RE progression.md 5; Navezgane test asserts snow 90/40 vs pine 18/10).
  2026-08-22: the quests.xml stage modifiers are in (gamestage_mod/bonus
  parse per quest def; the active quest's terms feed gameStageOf - test
  active quest stage modifiers scale the player gamestage; 7 stock quests
  carry the terms, e.g. the infested clears).
  2026-08-22: the prefab DifficultyTier leg is in - the loot stage now
  applies loot_settings POITierMod/Bonus indexed by the tier of the POI the
  player stands in (a tier-2 POI pushes a level-10 player to
  10*(1.1)+6 = 17; test POI difficulty tier scales the loot stage).
  Still missing: EffectManager passive modifiers.
  Full split: [gamestage subsection](#gamestage-what-is-in-and-what-is-still-missing).
  *Anchors:* `src/assets/gamestages.zig`, `src/server/game/sleeper.zig`,
  `asm.il:955240-955270`, `asm.il:416434`

- **POI sleeper volumes: parse, trigger, spawn at authored markers** `PARTIAL`
  3124 volumes load from stock Navezgane prefabs; volumes are AABB-tested in
  parallel then spawned serially at authored marker cells. `combat/sleeper_wake`
  PASS on the real client. 2026-08-22: the `TriggeredByIndices` cascade is in
  (`SleeperVolumeGroupId`, stock TouchGroup IL=52, same placement only;
  scenario `sleeper-cascade`), and the "only groups[0] used" gap is resolved
  by data: all 887 stock prefabs carry exactly one (name,min,max) group per
  volume (nvol names or nvol*3 triples, zero mismatches), so `groups[0]` is
  the volume's group. 2026-08-23: `triggered` **persists** (sleepers_triggered
  .zst, ZSTG1 - a POI the players woke does not re-pop on restart; the
  quest-cleared ZSCL1 path already covered ClearSleepers). Re-audit: the
  `is_sleeper_passive` wire flag **is** set for spawned sleepers on both
  spawn paths (join burst join.zig:534-547 and tick replicate
  replicate.zig:146-147, `mask.sleeper and !awake`), so the sleeping pose
  reaches the client until the wake flips it (plus NetPackageSleeperWakeup).
  Remaining gaps: `triggered` never **re-arms** (stock respawnTime, RE-blocked
  - row 2018), no sleeper pose from the marker block name (Sit/Back/
  SideLeft/Stomach/Idle are discarded; the wire pose byte table is not in RE,
  so this stays RE-blocked), no gamestage count scaling beyond the stage
  group's num/alive caps.
  *Anchors:* `src/server/game.zig:6995-7074`, `src/server/game/sleeper.zig:90-147`,
  `src/world/sleepers.zig:246-380`, `asm.il:197877`, `server-orch.log`

- **Sleeper group name to entity class resolution** `WORKS` `(2026-08-22 re-audit)`
  The `GroupGenericZombie` indirection resolves through gamestages: the sleeper
  spawn path (`src/server/game/sleeper.zig:109-110`) resolves the volume's
  class name via `gamestages.sleeperEntityGroup(class, stage)` and passes the
  stage spawn group into `resolveSleeperClass`, whose chain is stage group
  pick -> entityclasses byName -> entitygroups.pick -> defaultZombie. So the
  dominant sleeper value (GroupGenericZombie, a `gamestages.xml` SleeperGSList
  spawner indirection) spawns a gamestage-appropriate class instead of falling
  through to zombieBoe, and volumes naming a class directly keep their model.
  *Anchors:* `src/server/game/sleeper.zig:109-110`,
  `src/server/game.zig:2627` resolveSleeperClass,
  `Data/Config/gamestages.xml:153`, `Data/Prefabs/POIs/*.xml`

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

- **EAI task coverage** `WORKS` `(2026-08-22 re-audit)`
  9 task classes implemented (BreakBlock, DestroyArea, RunawayWhenHurt,
  **RunawayFromEntity**, ApproachAndAttackTarget, **ApproachDistraction**,
  Territorial, ApproachSpot, Look, Wander - the two bolded landed since this
  row was written: the distraction task chases a dropped decoy/item
  (`approachDistractionCanExecute` + the decoy scenario) and the fear task
  flees a wolf/zombie/player (`runawayCanExecute` + the flee tests), so a
  thrown distraction is chased and a timid animal flees a wolf. The absent
  classes (Leap, Dodge, RangedAttackTarget, MeleeAttackTarget, ItemTask, the
  three Drone tasks, PathTest) have **zero AITask uses in the V3.1.0 b14
  entityclasses.xml** - the file's whole AITask vocabulary is the 10 values
  enumerated in the earlier hardcode audit - except Leap (animalMountainLion
  AITask-1): the mountain lion approaches and melees like the other predators,
  only without the pounce animation (documented cosmetic residual).
  *Anchors:* `src/ecs/systems.zig:1341` zombie_tasks,
  `Data/Config/entityclasses.xml:562-571`, `asm.il` EAI* class list

- **Per-class AITask/AITarget lists from entityclasses.xml** `PARTIAL (waived)`
  Per-class `AITask/AITarget` strings (+ AIFeralSense, NoiseSeekDist, etc.) not
  yet parsed; all entities share one `zombie_tasks` table. Needs full
  `entityclasses.xml` task-graph loader — waived as EAI completeness vs wire.
  *Anchors:* `src/assets/entities.zig:230-272`, `src/ecs/systems.zig:731-750`

- **Timid animals run the zombie task table** `WORKS` `(2026-08-22)`
  `approach_attack` is now gated by the class's inherited AITask-* list:
  `ai_attack` is parsed from `entityclasses.xml` (an attack task =
  `ApproachAndAttackTarget`, the only attack task in V3.1.0 b14; the name set
  is a stock-AI RE constant), so timid animals (stag/doe/rabbit/chicken/pig,
  whose `animalTemplateTimid` is RunawayWhenHurt, RunawayFromEntity, Look,
  Wander) never pick the attack task, while predators (wolf/bear/coyote/boar,
  `animalTemplateHostile` with ApproachAndAttackTarget) and zombies keep
  hunting. The boar case proves the discriminator is the task list, not
  `IsEnemyEntity` (it overrides that to false for safe-zone spawning but keeps
  its attack task). The field rides the per-entity class copy on every spawn
  path; unprovoked, a timid animal flees or wanders instead of sprinting in.
  *Anchors:* `src/assets/entities.zig` resolvedAiAttacks,
  `src/ecs/systems.zig:1743`, `src/ecs/world.zig:875-905`,
  `Data/Config/entityclasses.xml:4724-4800`

- **Target sensing** `WORKS` `(2026-08-22 re-audit)`
  The sense surface is complete and stock-faithful: per-class SightRange
  (zombieTemplateMale 30 m, `senseDistSq` reads the entity's own sight_range
  first), a per-class view cone (entityclasses MaxViewAngle halved like
  EntityAlive.IsInFrontOfMe, default 180), block line-of-sight (`losClear`),
  hearing through walls scaled by stealth (crouched players are muffled), and
  smell with a bleeding extension - so a zombie sees you at stock distance in
  its cone with LOS instead of the old flat 48 m through-walls notice.
  Re-audited 2026-08-22: the headline claims (no LOS, no cone, flat 48 m) are
  stale. Residual: target-**choice** refinements (SetNearestEntityAsTarget
  with per-class hear/see weights, BlockingTargetTask, SetNearestCorpseAsTarget,
  BlockIf) - which of several options an entity picks - documented as AI-
  fidelity refinements that do not change the client-visible sense surface.
  *Anchors:* `src/ecs/systems.zig:104` canSensePlayer, `:137` viewHalfDeg,
  `:1726` senseDistSq, `:74` losClear,
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

- **Wander does not path and freezes Y** `WORKS` `(2026-08-21)`
  The row's two defects were fixed by the AI movement rewrite (stepToward now
  slides/collides through `bodyClearAt`, steps up ledges up to step_height,
  shoves entities, jumps or digs when fully blocked, and `applyGravity` runs
  once per AI tick snapping Y to the ground or falling with gravity), so a
  wandering body settles on terrain and cannot walk through walls. 2026-08-21:
  the remaining "does not path" gap is closed — `wanderUpdate` now routes the
  same A* chase machinery (`chaseAlongPath` + `replanPath`, step_fn-gated) as
  the chase, so a wanderer detours around obstacles on the navmesh instead of
  sliding straight into them (stock EAIWander walks to the spot via the
  navmesh); without a step hook it degenerates to the direct line. Test
  `wandering zombie paths around a wall via A*` proves the detour.
  *Anchors:* `src/ecs/systems.zig` wanderUpdate + chaseAlongPath,
  test `wandering zombie paths around a wall via A*`,
  asm.il:438366 (EAIWander::Update)

- **BreakBlock / DestroyArea block chewing** `WORKS`
  When a replan cannot reach the goal, `path_blocked` latches and the mutex-0 tasks
  hold the chase projection; block damage at 2 Hz applies base 10 scaled by
  BlockDamageAI/AIBM, respects MaxDamage, and broadcasts on break. Replan clears
  the latch when a detour opens.
  *Anchors:* `src/ecs/systems.zig:1072-1128`, `src/server/game.zig:3096-3134`,
  `src/ecs/systems.zig:1337-1339`

- **Daytime wildlife spawner** `WORKS` `(2026-08-22 re-audit)`
  One animal per 60 s during daylight up to the cap (MaxSpawnedAnimals). The
  class lookup is no longer the stag-only slot-7 scan: `spawnAnimalsNearPlayers`
  resolves the **per-player-biome wildlife group** (`biome_group_fn`, the
  Biome-aware spawn-group-selection row), picks a class by name from the group
  (`group_pick_fn`), and falls back to the full entityclasses stats via
  `class_resolve_fn` (A35) when the class is not preloaded - so WildGameForest
  picks spawn rabbits, chickens, does and boars with their own stats, not just
  `defaultAnimal() = animalStag` (the stag is only the no-group fallback).
  All three callbacks are wired in `init_assets.zig`.
  *Anchors:* `src/ecs/aidirector.zig:464` spawnAnimalsNearPlayers,
  `src/server/game/init_assets.zig:377-384` (callback wiring),
  `src/assets/entities.zig:74-80`

- **Enemy animals (wolf, bear, dire wolf, mountain lion, snake, coyote)** `PARTIAL (waived)`
  `spawning.xml` `EnemyAnimals*` rules are parsed but director consumes only the
  first `animal` rule into slot 7 (stag). Hostile wildlife needs multi-slot animal
  variety + `spawning.xml` kind routing — waived as entity-variety, not parity gate.
  *Anchors:* `src/server/game.zig:882`, `src/ecs/aidirector.zig:188-209`,
  `Data/Config/spawning.xml:31-33`

- **Vultures / flying entities** `PARTIAL (waived)`
  No flying `EntityKind`/vertical AI; vultures not spawned. Needs vertical
  movement + `EntityFlying` parity — waived as entity-variety, not parity gate.
  *Anchors:* `src/ecs/components.zig:5-13`

- **Animals never despawn** `WORKS` `(2026-08-22)`
  `systemDespawnFar` now walks both mob kind groups (zombie and animal) with
  the same rules, so wildlife beyond `despawn_dist_sq` (200 m default) is
  released like zombies instead of accumulating to MaxSpawnedAnimals and
  holding entity slots + `known_entities` bits forever; sleepers and alerted
  mobs stay (POI volumes / engaged fights). Systems test `far animals despawn
  like zombies; near animals stay` covers far/near/alerted.
  *Anchors:* `src/ecs/systems.zig:2952` systemDespawnFar, `:1716`

- **Animal replication carries no movement state** `WORKS` `(2026-08-22)`
  The EntitySpeeds / EntityAliveFlags block now covers `.animal` too: animals
  stream the same movement state as zombies (wander -> walking state 1, chase
  -> running state 2 with the approach flag), so the client no longer animates
  a sliding animal with movementState 0. Scenario `animal movement state
  replicates` asserts a wandering animal streams movement_state 1.
  *Anchors:* `src/server/game/replicate.zig:224`, scenario `animal movement
  state replicates`

- **Night horde** `PARTIAL`
  Every `horde_drip_cd` (45 s) of night, 2 zombies spawn in the
  `enemy_spawn_ring_min..max` band (28-54 m; the row's old 18-28 m claim was
  stale) around each player, spawned `.chase` with the player as target
  (the AIDirector ring placement, asm.il:413135, with seeded bearing jitter).
  Blood-moon nights shorten the cooldown to `bloodmoon_horde_drip_cd` (8 s).
  2026-08-23: the drip now also enforces the per-rule budget (spawning.xml
  maxcount/respawndelay, see "spawning.xml parsing"), so a biome rule's night
  cap is respected. Still not the stock biome-night spawner's per-80m-cell
  ChunkAreaBiomeSpawnData structure (per-cell timers, POI-tag enabled flags)
  nor the scheduled wandering horde (that component is WORKS); a direct
  aggro drip with per-rule budgets.
  *Anchors:* `src/ecs/aidirector.zig:159-162`, `:233-282`, `:388-393`,
  `:588-606` (drip budget gate), `src/ecs/rules.zig:358-359,366-367`

- **Blood-moon waves** `WORKS` `(2026-08-22 re-audit)`
  The party spawner is in: one wave per party (not per player) around its
  shared focus at cSpawnDistance 40 + up to 10 jitter, marked horde and set
  to chase the party's players, capped per party at
  min(cPartyEnemyMax 30, BloodMoonEnemyCount x members) with the party's
  game stage frozen at dusk (InitParty) driving the gamestages.xml ladder and
  the group's maxAlive; the wave cadence is the configured bloodmoon_wave_cd.
  The old per-player 12-22 m drip the row described is gone.
  *Anchors:* `src/ecs/aidirector.zig:394-408`, `:664-691`
  (`spawnBloodMoonParties`), `asm.il:416385-416960`

- **Wandering hordes** `WORKS` (pack path-walk residual)
  `AIDirectorWanderingHordeComponent` schedule: `HordeNextTime` arms after day 1
  (worldTime > 28000) at now + RandomRange(12000, 24000) ticks (ChooseNextTime,
  deterministic day+spawn-counter roll), player-gated (no players re-arms), and
  on expiry spawns a pack of 6 horde-marked zombies (`IsHordeZombie`) at ~92 m
  that chase the party. Residual: stock walks the pack as a startPos->endPos
  Astar location line with pit-stop commands; zdtd spawns and chases directly.
  *Anchors:* `src/ecs/aidirector.zig` (`wandering_next`, `nextWanderingTime`,
  `spawnWanderingHorde`), `asm.il:419473-419490` (TickNextTime/ChooseNextTime),
  `asm.il:416218`, `Data/Config/gamestages.xml:1582`, `:3458`

- **Screamers and the activity heat map** `WORKS` (heat feed residual)
  `AIDirectorChunkData` heat accumulation per 5x5-chunk region
  (`Director.heat`): burning workstations whose block carries a blocks.xml
  `HeatMapStrength` (forge 6, campfire 5, workbench 5, ...) feed
  `notifyActivity(value, 720 ticks)`; events decay linearly and expire. Every
  5 s `CheckToSpawn`: a region at/above 25 resets and spawns a scout party;
  cooldowns are the RE-verified stock literals (region 240 s, neighbors 180 s,
  aligned 2026-08-20, `[rules.director]` tunable).
  (Scouts1/2/Feral/Radiated by gamestage, chunk-heat spawner 0/8/10 constants)
  that investigates the nearest player; the region and its neighbors go on
  cooldown (120 s / 60 s; the 20% feral roll doubles it). Blood moons suppress
  new heat (NotifyActivity gate). Residual: noise-to-heat (stock items.xml
  carries no `heat_map_strength`, so stock's own noise table is empty too),
  static torch/campfire heat (only burning workstations feed now), and the
  screamer's scream-summons-more loop.
  *Anchors:* `src/ecs/aidirector.zig` (`heat`, `notifyActivity`, `tickHeat`,
  `spawnHeatScouts`), `src/server/game.zig` (workstation heat feed),
  `src/assets/blocks.zig` (`HeatMapStrength`), `asm.il:414504-415200`,
  `asm.il:416218`, `Data/Config/blocks.xml:28086` (forge 6)

- **NetPackageHordeEvent** `N/A (parity)`: see [§6 blood-moon
  NetPackageHordeEvent row](#6-blood-moon): the same verdict applies; this row
  exists only because the package also appears in the entity/AI catalog.
  *Anchors:* `src/wire/packages.zig:896`

- **AIDirector / sleeper state persistence across restart** `PARTIAL (waived)`
  `saveAll` covers chunks/containers/block-meta/players; entity/director/sleeper
  timers are runtime state that stock also rebuilds on load. Persisting live mobs
  needs `EntityCreationData` snapshot RE — waived as session-lifetime polish.
  *Anchors:* `src/server/game.zig:8131-8147`

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

- **Corpse dwell time (TimeStayAfterDeath)** `WORKS` (corpse harvest residual)
  A zombie/animal death keeps the body in world at hp 0 for its
  `TimeStayAfterDeath` (entityclasses.xml per class: 30 zombieTemplateMale,
  300 animals; per-kind defaults when unset), with the corpse's AI stopped and
  re-kills suppressed; the tick sweep (`sweepCorpses`) destroys the body when
  the dwell elapses and broadcasts the EntityRemove, so the client's ragdoll is
  not yanked mid-animation. `DeadBodyHitPoints` corpse destruction/harvesting
  is residual.
  *Anchors:* `src/ecs/world.zig` (`damageFrom` corpse branch, `sweepCorpses`),
  `src/ecs/components.zig` (`Health.corpse_seconds`, `ClassId.time_stay`),
  `src/assets/entities.zig` (`TimeStayAfterDeath`), `src/server/game.zig`
  (sweep in tick, kill handler defers the remove), `asm.il:450657-450759`,
  `Data/Config/entityclasses.xml:692-693`

- **Zombie health replication to clients** `WORKS`
  The dirty-hp replicate pass now sends `EntityStatChanged(health)` for
  zombies and animals to observing clients (not just player vitals): C2S
  damage, AI melee, admin damage and the corpse-dwell hp=0 all reach the
  client, so the health bar drops and the death shows instead of a
  full-health body until EntityRemove. Owner-skip logic stays player-only.
  *Anchors:* `src/server/game.zig` (`replicatePlayerHealth`),
  `asm.il:199650` (SendStatChangePacket), `asm.il:200440`

- **Animation / ragdoll / look-at replication for AI** `PARTIAL (waived)`
  Server drives AI position/state; animation/ragdoll/look-at FX are client-predicted.
  Stock FX parity is out of scope (AGENTS: wire is contract, no fake FX - §2a).
  *Anchors:* `src/server/game.zig:4036-4038`, `src/ecs/systems.zig:1247-1263`

- **Spawn placement validity** `WORKS`
  Spawn Y is now ground-snapped through the world ground hook for every
  player-adjacent spawner (night drip, wildlife, blood-moon parties, the
  wandering horde): the player's transform Y is its centre (~1.7 m up), so
  spawning at it embedded zombies in hillsides or left them floating on
  slopes. The per-spawn bearing jitter (seeded from the spawn counter) already
  broke the fixed-bearing repetition. Residuals: the stock 4 x 2.5 x 4
  standable/empty box test and the out-of-view constraint are not modelled -
  spawns can still overlap an entity or appear on-screen, a polish gap rather
  than a stuck-zombie one.
  *Anchors:* `src/ecs/aidirector.zig:564,473,683,790` (`groundY` snaps),
  `src/ecs/world.zig:681-685` (`groundY`), `asm.il:1094396-1094440`

- **Quest-driven enemy spawn** `WORKS` `(2026-08-22 re-audit)`
  The QuestActionSpawnGSEnemy hook (Game-side, fired on phase entry) resolves
  the group through the gamestage spawner (`sleeperEntityGroup` at the party
  stage), rolls the count between the action's min/max with a
  world-time-seeded RNG, picks the class through the sleeper class chain, and
  places on a 12..23 m ring at the ground-snapped surface (the row described
  the old defaultZombie x8 at 6 m). Scenario `treasure-radius-break` covers
  the nested ambush variant.
  *Anchors:* `src/server/game/hooks.zig:464-490` (`questSpawnGsEnemy`),
  `src/ecs/systems.zig` `firePhaseActions`, `asm.il:955240-955275`

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

**23 WORKS · 5 PARTIAL · 0 MISSING**

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

- **items.xml Extends inheritance** `WORKS` `(2026-08-22 re-audit)`
  `loadFromPath` resolves `Stacknumber` through the Extends chain (second pass,
  24-hop walk; an item with no Stacknumber anywhere inherits the ItemClass
  default 500). Re-audited 2026-08-22: DamageEntity, FuelValue and the eat
  cvars are read direct-only, but the V3.1.0 b14 stock items.xml has **zero**
  Extends children whose parent declares any of those three - every item that
  needs melee damage, fuel or eat cvars declares them itself (verified by a
  full-file scan of the 1413 items), so the direct reads never miss stock
  data. A modded items.xml introducing such inheritance would lose the
  inherited values, documented as a mod-data edge, not a stock-parity gap.
  *Anchors:* `src/assets/items.zig:466-627` (Extends second pass), `:536-546`
  (direct DamageEntity/FuelValue reads), `Data/Config/items.xml`

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

- **Item modifiers (mods) and cosmetics** `PARTIAL (waived)`
  Mods/cosmetics wire is valid (length 0) and survives round-trip; stock mod
  effects are client FX. Faking `item_modifiers.xml` without RE would be worse
  than exposing unmodded base items.
  *Anchors:* `src/wire/stock_inv.zig:93-95`, `:535-548`

- **Item durability (ItemValue.UseTimes)** `WORKS` (2026-08-21)
  `InvSlot.use_times` carries the stock `ItemValue.UseTimes` (f32) and both
  wire conversions round-trip it, so a tool's remaining durability reaches the
  client and comes back; `inventory.degradeUse` wears a slot toward 0
  (clamped, stack stays present as a broken repairable item); the dig and
  landed-hit call sites degrade the held tool (blocks.zig + misc.zig,
  scenario-tested). `players.zsv` does not persist use_times across restart -
  a save-format internal of zdtd's own player file, out of scope per the
  parity objective (the client-visible durability is session-accurate).
  *Anchors:* `src/wire/stock_inv.zig:48`, `src/ecs/components.zig:338-347`,
  `src/ecs/inventory.zig:243-257`, `src/server/c2s/blocks.zig`,
  `src/server/c2s/misc.zig`

- **Item quality tier** `WORKS` (2026-08-21 reconciliation)
  quality rides the wire, the TE and players.zsv, and stack merges refuse to
  blend different qualities. Looted items roll quality from the
  `loot_quality_template` by loot stage (2026-08-08) and trader inventory
  rolls quality per entry; stackables without a quality tier keep 1 so they
  merge; `qualityinfo.xml` is forwarded as the client config name (the
  client ships the file, exactly the stock flow); durability wear is wired
  (2026-08-21). Mods having no quality effect belongs to the waived mods
  row.
  *Anchors:* `src/assets/loot.zig` `resolveQuality` / `rollContainer`,
  `src/ecs/components.zig:363-395`, `:444-466`

- **Repair (item repair queue / RepairItem)** `PARTIAL (waived)`
  `RepairItem` payload is intentionally ignored (hard-flagged false); item repair
  via workstation queue is client-FX + inventory-authoritative durability refs.
  True `ItemClass.RepairTime` scheduling would reimplement the workstation craft
  queue — stock-parallel path out of scope vs wire contract.
  *Anchors:* `src/wire/stock_te.zig:389`, `:532-536`

- **Block upgrade path (hammer upgrade)** `WORKS`
  `blocks.xml` `UpgradeBlock.ToBlock` is parsed (property class, through the
  Extends chain) and the SetBlock handler only accepts a block swap onto an
  occupied cell when the new id is the current block's upgrade target (resolved
  by name), so the wood → cobblestone → concrete → steel ladder is data-driven
  and a forged SetBlock cannot swap in arbitrary block ids. Scenario covers the
  legal upgrade, a forged swap and the idempotent rerun.
  *Anchors:* `src/assets/maxdamage.zig:393-394`, `src/server/game.zig:6670-6680`

- **recipes.xml load** `WORKS` `(2026-08-22 re-audit)`
  630 recipes with up to 5 ingredients parse fine, including craft_tool (53),
  material_based (34), craft_area and craft_exp_gain. Re-audited 2026-08-22:
  `craft_area` **is** consumed - the general inventory craft path rejects
  recipes with a craft_area (they need the workstation context,
  `generalCraftAllowed`) and the workstation queue validates the recipe's
  craft_area against the station block (`blocks.allowsCraftArea`), so a
  workbench-only recipe can no longer be crafted anywhere. The exp residuals
  are data-absent: every craft_exp_gain in the V3.1.0 b14 recipes.xml is 0
  (17 uses) and learn_exp_gain has zero uses, so nothing to award. `tags`
  (631 uses) drive the client's local crafting-UI categories and the
  unlock/magazine system (no server consumer; the client reads its own
  recipes.xml) and use_ingredient_modifier (6) scales forge-emptying recipe
  ingredients (all material_based, rejected by the general path); craft_time
  stays client-driven (stock's client-side progress model). Documented
  residuals, not stock-parity gaps.
  *Anchors:* `src/assets/recipes.zig:151-186`, `:21`, `:161-163`,
  `src/server/game/craft.zig:124-128`, `src/server/c2s/inv.zig:427-432`,
  `asm.il:1392695-1392710`

- **Server craft execution** `PARTIAL`
  `tryCraftRecipe` aggregates ingredients, snapshots the bag, consumes, deposits
  and rolls back on failure. The general path rejects workstation-area,
  tool-bound and material_based recipes (generalCraftAllowed - closing the
  zero-ingredient mint), and the workstation queue path rejects material_based
  too; craft_tool is parsed from recipes.xml. 2026-08-22: craft_time **is**
  applied server-side on the workstation path - the queue is server-paced via
  `one_item_craft_time`/`craft_time_left` (both parsed from the client's TE
  recipe blob like stock), and the tick decrements and cycles the queue as time
  elapses (see "Workstation craft tick" `WORKS` below). Hand crafting stays
  client-driven, which is stock's model (the client owns its own progress bar;
  the server validates and applies the craft at request time). Remaining: the
  recipe-unlock check needs the progression/magazine system (tracked under
  "Crafting skills / magazines / recipe unlock by progression").
  *Anchors:* `src/server/game/craft.zig:121`, `src/assets/recipes.zig:181-184`,
  `src/world/workstations.zig:85-86,274-291`

- **NetPackageInventoryTransactionRequest / Response wire format** `WORKS`
  The stock `InventoryTransaction::Read` layout is parsed (`parseStockInvTx`
  decodes per-inventory Guid key, InitialHash, FinalHash, opCount and
  `InventoryOperation.Write` ops: 0 SetAbsolute / 1 SetRelative /
  2 SetAll, all capped and fail-closed), and the ops now APPLY to the player's
  ECS inventory (SetAbsolute/SetRelative write the client's reported stack at
  the index, SetAll replaces the array, bounds + stack caps hold) with the
  stock minimal response ack (success + count 0). The handler tries the stock
  layout before the native 11-byte body (the native parser only checks
  len >= 11 and would otherwise misread stock traffic). The Guid registry
  population path stays unpinned RE (protocol-packages.md 6.13), so the
  player's own transactions accept without key validation - the same
  client-trust model as the C2S PlayerInventory push (ADR 0007), no wider
  surface. Scenario `stock InventoryTransaction applies and acks` pins the
  apply + ack.
  *Anchors:* `src/wire/packages.zig:4313-4400` (`parseStockInvTx`),
  `src/server/c2s/inv.zig:536-591` (stock apply + ack),
  `docs/wire/INVENTORY.md:74-75`, `asm.il:823033-823059`, `asm.il:614000-614087`,
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

- **Workstation fuel burn rate** `WORKS` (2026-08-20)
  `handleFuel` consumes one fuel item per its items.xml `FuelValue` (stock
  `TileEntityWorkstation::GetFuelTime` = `ItemClass::GetFuelValue`):
  `resourceCoal` = 100 s, most wood and oil shale 1-5 s (was a flat 10 s).
  The offline fallback stays 10 s. The fuel lookup is a `FuelResolver` the
  Game wires from the items table.
  *Anchors:* `src/world/workstations.zig:196-215`, `src/assets/items.zig:119-125`,
  `asm.il:1332283-1332301`, `asm.il:1331999`

- **Workstation input consumption and forge melt simulation** `PARTIAL (waived)`
  Input/melt timers are client-opaque on the wire; stock controls the rate loop
  and the server re-exposes it via `workstations.zig` rate hooks so inventory
  and XP stay authoritative elsewhere. Mark waived vs adding a parallel forge sim.

- **Workstation recipe validation against recipes.xml** `PARTIAL (waived)`
  Craft queuing is client-driven Recipe blobs; server validates placement/rate
  and gates unlocks elsewhere (`recipes.zig` + `craft_area` + `craft_tool`). Full
  body-cop parsing would reimplement `TileEntityWorkstation` verbatim.
  *Anchors:* `src/wire/stock_te.zig:509-523`, `src/world/workstations.zig:257-269`

- **Non-fuel workstations (workbench, cement mixer, table saw)** `FIXED (2026-08-08)`
  The craft gate now mirrors stock TileEntityWorkstation.HandleRecipeQueue
  (asm.il 1331687): it waits for `is_burning` only when the station has a fuel
  module. The fuel-module presence is block-derived (blocks.xml Workstation
  Modules list parsed into `BlockDef.has_fuel_module`: campfire / forge /
  chemistry have fuel, workbench / cement mixer / table saw do not), copied
  onto the Workstation at TE apply, so workbench crafts advance server-side
  without fuel. Chemistry station is a fuel station in stock blocks.xml
  (Modules "output,fuel,input") and already advanced when burning.
  *Anchors:* `src/assets/blocks.zig` hasFuelModule,
  `src/world/workstations.zig` handleRecipeQueue, `asm.il:1331687`

- **Workstation persistence and capacity** `PERSISTED (2026-08-08), cap 256`
  `WorkstationStore` now saves `workstations.zws` (ZWS1, pos-sorted records:
  fuel/input/tools/output, lastInput, queue with recipe blobs, craft-complete,
  melt, burning state) at shutdown and restores at init, so a forge's smelt
  survives restart (rule 21). The store caps at 256 stations (GAP 12 raise,
  `max_workstations`); the position scan is linear.
  *Anchors:* `src/world/workstations.zig` save/load, `src/server/game.zig`
  init/deinit, `src/world/containers.zig:129-235`

- **loot.xml parse** `PARTIAL` (2026-08-08 refresh)
  1010 groups and 339 containers parse, including `loot_prob_template` (1528
  uses, resolved to band indices at load), `force_prob` (181 uses, independent
  roll gate) and the `loot_settings` poi_tier_mod/bonus block. `count="all"`
  (360 uses) now spawns every entry once (stock -1 → SpawnAllItemsFromList)
  instead of pick-1, and `LootGroup.entries` caps at 192 so stock groups
  (perkBooks, 133 entries) are not truncated. `loot_quality_template` (403)
  drives the looted item quality by stage (2026-08-08). Not parsed:
  abundance_type (sandbox-coupled) and requirement children (structurally
  blocked - rolls happen at chunk fill with no opener context; verified
  2026-08-22 that stock loot.xml carries no group min/max level attribute,
  the row's earlier claim was stale). `LootContainer.size_x/size_y` drive
  the storage grid (2026-08-08).
  *Anchors:* `src/assets/loot.zig` rollGroup pick_all / force_prob,
  `Data/Config/loot.xml:9656`

- **Loot roll probability model** `PARTIAL`
  2026-08-21: `rollGroup` picks are now **prob-weighted** like stock
  (LootContainer probability): each entry's stage-resolved prob is its weight
  relative to the group sum, so a 0.9 item drops ~9x as often as a 0.1 one and
  a 0-prob item never drops (test `container group rolls are prob-weighted,
  not uniform`); `lootstage` templates (42 lootprobtemplate in stock) resolve
  per stage through `entryProb`, the loot stage itself derives from the party
  gamestage, and force_prob entries gate independently. 2026-08-23: the
  index-0-always exception is gone - every entry (plain or template) rolls
  its own prob (`!probGate`), matching stock LootContainer.roll. The old
  exception was data-benign (0 of the 339 stock containers have a plain
  first entry with prob < 1; verified by scan) but wrong for hypothetical
  data; the roll stream is byte-identical for stock. Remaining:
  `<requirement>` filtering (85 stock uses) and per-entry `abundance_type`
  (68 stock uses) are unparsed (both structurally blocked: rolls happen at
  chunk fill with no opener context, and abundance is sandbox-coupled).
  *Anchors:* `src/assets/loot.zig` rollGroup + groupEntryWeight,
  test `container group rolls are prob-weighted, not uniform`

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

- **Loot bag drop probability (LootDropProb)** `WORKS`
  `entityclasses.xml` `LootDropProb` parsed in `assets/entities.zig` (`.04`
  regular zombie) into `class_id.drop_prob`, clamped to `[0,1]`. `World.damage`
  and `killXpAward`/turret path both call `rollLootDrop(net_id, drop_prob)` so
  most kills drop nothing; deterministic hash test pins 4% rate.
  *Anchors:* `src/assets/entities.zig:326-332`, `src/ecs/world.zig:856-880`,
  `src/ecs/systems.zig:2107-2127`, `Data/Config/entityclasses.xml:689`

- **Player death loot bag (DropOnDeath)** `WORKS` `(2026-08-22)`
  Modes 1..3 drop a bag holding the victim's **real inventory range**:
  `spawnDeathBag` (Game) selects the range by mode (1 = toolbelt + backpack,
  2 = toolbelt only, 3 = backpack only) and `spawnLootBagFrom` copies the
  source slots into the bag at preserved offsets instead of a single
  placeholder unit, then latches the dropped-backpack marker. Both kill paths
  bag: the C2S damage kill and the hp-replicate AI-kill detector (coordinated
  through `Client.has_backpack` so a death is never bagged twice). Scenario
  `AI kill drops the player's real inventory` proves the AI path; unit test
  pins the range copy.
  *Anchors:* `src/server/game.zig` spawnDeathBag,
  `src/server/game/replicate_health.zig:26`, `src/server/c2s/misc.zig:529`,
  `src/ecs/world.zig:1000` spawnLootBagFrom

- **Storage TileEntity S2C** `WORKS` `(2026-08-22)`
  Composite TE with one Storage feature is built and pushed on chunk stream and
  lock grant, matching `TEFeatureStorage.Write` field order. 2026-08-22: the
  container grid now rides the wire - the client's TE write carries the
  loot.xml `LootContainer` size it observes (6x2 wooden chest, 9x6 gun safe),
  the lock path validates it (both axes non-zero, grid holds the slot count,
  capped) and stores it on the container (`size_x`/`size_y`), the writer emits
  it instead of the 2xN synthesis, and ZCT2 persists it across restarts (ZCT1
  still loads; unknown grids synthesize). The lootListName bool stays false as
  a documented internal difference: zdtd rolls the container's loot at
  creation (deterministic per block) and respawns by touched_day, so the
  server-side lazy-roll key (RE loot-economy.md `LootContainerOpened`) is not
  needed and the client UI does not render the list name.
  *Anchors:* `src/wire/stock_te.zig:148-162` (grid), `src/server/c2s/inv.zig`
  (lock-path size capture), `src/world/containers.zig` (ZCT2),
  `asm.il:156979`

- **Storage TileEntity C2S apply and broadcast** `WORKS`
  Parse, range check against the acting player, apply, broadcast. Slot quality and
  meta survive the round trip; containers persist to `containers.zct` sorted by
  world position.
  *Anchors:* `src/server/game.zig:4335-4360`, `src/wire/stock_te.zig:204-343`,
  `src/world/containers.zig:129-235`

- **NetPackageInventoryDataRequest / Response** `WORKS` `(2026-08-22 re-audit)`
  Requests keyed by the deterministic pos Guid are answered with the
  container's ItemStacks, and the back half of the loop - the client's
  mutation transaction - is now applied too: the handler accepts the stock
  `InventoryTransaction.Write` ops (SetAbsolute/SetRelative/SetAll) on the
  player inventory with the minimal stock ack (GAP InvTx row, 2026-08-22), so
  a mutation made through this path lands instead of being dropped.
  *Anchors:* `src/server/game.zig:4536-4587`, `src/server/c2s/inv.zig:536-591`,
  `asm.il:613064-613088`, `asm.il:613124-613223`

- **Loot respawn and destroy_on_close** `WORKS` `(2026-08-22)`
  Loot respawn is wired: `maybeRespawnContainer` re-rolls empty world containers
  after `LootRespawnDays` with a cycle-varying seed (`lootSeedAt(pos) +% cycle*%2654435761`),
  fail-closed on missing `LootList`; called from inventory path on take.
  `destroy_on_close` is now parsed from loot.xml (233 stock entries: 139
  "true" + 94 "empty") and acted on: on the C2S LockRequest unlock (the close
  event), `maybeDestroyContainerOnClose` evaluates the def's mode - "true"
  drops the remaining contents as an EntityLootContainer bag at +0.5,0.75,+0.5
  and breaks the block; "empty" breaks only when the player emptied it -
  matching stock `TEFeatureStorage.OnUnlockedServer` -> `CheckDestroyTileEntity`
  (IL=6/37, RE added to loot-economy.md 2026-08-22). Scenario
  `destroy-on-close` covers the true/empty/not-emptied legs. Residual: the
  stock `DroppedEntityClass` block-property override for the drop bag is not
  modeled (rare; the stock default EntityLootContainer is used).
  *Anchors:* `src/server/game/chunk_fill.zig:293-322,363-415`,
  `src/server/c2s/misc.zig:568` (LockRequest), `src/assets/loot.zig` parse,
  `src/world/containers.zig` loot_list,
  `../../7dtd-research/docs/loot-economy.md:454-456,458-465`

- **Container capacity limits** `WORKS` `(2026-08-22 re-audit)`
  The world container store is 4096 entries (GAP 12 raised it from 256, and
  2026-08-21 added world-container eviction because Navezgane alone has
  thousands of loot containers and a hard cap truncates the tail - every
  container past it came back empty), 54 slots each, and the save path
  buffers on the heap. The per-chunk prefab TE scan budgets (32 block hits /
  48 TE-list hits, `[sim] te_scan_*` in zdtd.toml) bound one chunk fill so it
  cannot stall the 50 ms tick, and a truncated scan retries on the next send
  (`ch.te_scanned` stays false) rather than silently dropping containers.
  *Anchors:* `src/world/containers.zig:7-14`, `src/server/game/types.zig:32-37`,
  `src/server/game/chunk_fill.zig:250,267-268`

- **Player inventory persistence of item state** `PARTIAL`
  players.zsv (ZPV3 / legacy ZPV2) stores item_id, count, quality and meta per slot into a 32-entry
  read buffer, while the ECS inventory is 47 slots against the stock wire layout of
  10 + 45 + 12. UseTimes, mods, cosmetics and seed are not stored at all. Slots
  beyond bag index 32 and equipment index 5 are dropped on the C2S apply.
  `(2026-08-22)` the slot-width leg is resolved: the ECS inventory is the full
  stock 10 + 45 + 12 = 67 slots (ADR 0007 amendment), the C2S apply keeps every
  client slot and the persist buffer/wire encoders scale off the same constants;
  `(2026-08-22)` ZPV7 widens the slot record 7 -> 11 bytes to persist
  `use_times` (stock ItemValue.UseTimes, f32): tool durability now survives a
  relog (round-trip + v6 migration tests); `(2026-08-22)` ZPV10 widens it
  again 11 -> 13 to persist `seed` (stock ItemValue.Seed, u16): a plantable's
  per-item seed survives a restart (round-trip test, v9/v8/v7 migration
  tests). Remaining per-item state: mods and cosmetics are still not stored
  (a further ZPV slot-record extension).
  *Anchors:* `src/server/persist.zig` zpvSlotStride/emitZpv10Slots + save/load,
  `src/server/game.zig:1910-1913`, `:2094-2103`,
  `src/ecs/components.zig:200-220`, `src/wire/stock_inv.zig:627-681`,
  `docs/adr/0007-player-inventory-c2s-trust.md`

- **Scrapping (material_based recipes / CraftCompleteData.scrapped)** `PARTIAL (waived)`
  Scrap path is client-driven; server exposes material-based recipes as regular
  craftable entries and echoes `scrapped` flag without server-side scrap->material
  spawning. Faking the yield table would invent economy.
  *Anchors:* `src/wire/stock_te.zig:514`, `:559`

---

## 10. Player progression

**Headline.** A player can join, eat, take client-reported damage, die by
admin/self-report and respawn. Level, XP, survival stats and active buffs now
survive a restart (players.zsv v3, server-side ledger). Still missing: no perk
runtime (client-owned spending, no server model), the client's
`NetPackagePlayerStats` blob is dropped so other players never see your level,
and server-to-client XP/level pushes do not exist.

**22 WORKS · 3 PARTIAL · 0 MISSING**

- **progression.xml `<level>` curve parse** `WORKS`
  Parsed on boot and logged. Live: `progression max_level=300 exp_to_level=10000
  attrs=8 perks=57`, matching `progression.xml:8`.
  *Anchors:* `src/assets/progression.zig:92-106`, `:123-130`,
  `src/server/game.zig:834-845`, `server-orch.log:14`

- **Server-side XP ledger and level-up loop** `WORKS` `(2026-08-22 re-audit)`
  `awardXp` levels correctly against the stock curve, and the ledger is
  **persisted**: level/xp ride the ZPV3 progression tail (`players.zsv`,
  `persist.zig`), restored on login, and saved on the hard-disconnect reap
  **before** the slot clears (net.zig:369-372), on shutdown (lifecycle) and on
  the periodic autosave (step.zig) - a disconnect does not lose XP. Award
  amount resolves `entityclasses.xml` `ExperienceGain` per victim class
  (including the `^xpNormal01`-style `<replace_properties>` ladder); a
  turret/trap kill scales by `Rules.progression.trap_kill_xp_frac` (0.0
  default, stock's unperked default) since stock's `ElectricalTrapXP` needs a
  per-player perk level zdtd does not yet have (ADR 0023). The client XP push
  is owned by the (waived) server-to-client XP/level row; the ledger lives on
  the per-peer Client as its persistence key.
  *Anchors:* `src/server/game/player.zig` `killXpAward`/`xpGainFor`,
  `src/server/persist.zig:407-414,709` (ZPV3), `src/server/game/net.zig:369-372`
  (reap save), `src/assets/entities.zig` (`ExperienceGain` parse)

- **XP curve numeric parity with stock** `WORKS`
  `expForLevel` now mirrors `Progression.GetExpForNextLevel` bit-for-bit:
  `conv.r4 BaseExpToLevel * Mathf.Pow(ExpMultiplier, Clamp(level+1, 0,
  ClampExpCostAtLevel))` where Mathf.Pow computes in double and casts to float
  (Progression.il.txt 1083482/1083513), `Math.Min(.., 2.147484e9f)` then
  `conv.i4` saturates at int.MaxValue. Golden values: level 1->2 = 11024
  (was 10000, a 1.1024x undercharge), clamp at 60 freezes the cost at 186791.
  Award/join/stats callers pass the current level so exp_to_next matches stock.
  *Anchors:* `src/assets/progression.zig:33-45`, `src/server/game/player.zig:34,39,54`,
  `src/server/game/join.zig:540`, `Progression.il.txt:1083482`, `:1083513`

- **XPMultiplier server option** `WORKS`
  Parsed, applied to awards, reported in the GameStats blob. Client log confirms
  `GameStat.XPMultiplier = 100` arrived.
  *Anchors:* `src/server/config.zig:238`, `src/server/game.zig:3048`, `:6232`,
  `output_log_client_zdtd_connect.txt:5236`

- **XP from non-kill sources** `PARTIAL (waived)`
  Only kill XP is authoritative; quest/mining/loot XP is client-reported and
  would be faked without the full skill/XP economy. Waived until progression
  ledger is wired end-to-end.
  *Anchors:* `src/server/game.zig:4964` `awardXp`, `Data/Config/quests.xml:103`

- **Skill points granted per level** `PARTIAL (waived)`
  `skill_points_per_level` parsed but no server-side balance exists yet; spending
  needs the progression/blob wire. Waived as progression polish, not parity gate.
  *Anchors:* `src/assets/progression.zig:16`, `:102`

- **Client to server XP sync (EntityAddExpServer, EntityAddScoreServer)** `PARTIAL (waived)`
  Client-originated XP is intentionally not authoritative; server ledger drives
  level via `awardXp`/`level-up`. Trusting the client's add would reintroduce
  invented XP. Waived as authority rule.
  *Anchors:* `src/server/game.zig:4794-4799`, `asm.il:813959`

- **Client to server progression blob (NetPackagePlayerStats)** `PARTIAL (waived)`
  `EntityNetworkStats` blob is intentionally dropped (`accept, no sim`) — stock
  `ToEntity` level relay would trust client stats. Server persists level/XP
  authority; peer stat display is polish, not wire parity.
  *Anchors:* `src/server/game.zig:4785-4788`, `asm.il:833182`

- **Server to client XP/level push (EntityAddExpClient, EntitySetSkillLevelClient)** `PARTIAL (waived)`
  Builder exists but push is via authoritative `EntityStatChanged`/`PlayerStats`
  path that is pending full progression ledger sync. Dedicated push is polish.
  *Anchors:* `src/wire/packages.zig:158-159`, `asm.il:813609`

- **progression.xml attribute and perk catalog load** `PARTIAL`
  Names and counts load (8 attributes, 57 live perks), but the catalog is thin.
  `(2026-08-22)` (a) the `perk.parent_attr` bug is fixed: each perk's own
  `parent` attribute parses (stock: parent="skill*" or "att*"; the old
  walk-back resolved every perk to the file's last `<attribute>`), and (b)
  per-attribute `min_level`/`max_level`/`base_skill_point_cost` overrides
  parse (attBooks/attCrafting/attGeneralPerks carry their own; test
  `perk parent and per-attribute overrides`). Still open: (c) `<skill>`
  (16 rows), `<crafting_skill>` (23 rows), override_cost,
  level_requirements, effect_group, unlock_entry, display_entry, book and
  book_group are not parsed at all. (d) Nothing in `src/` reads perks or
  attributes: `perkByName` and `attrByName` have zero callers outside their own
  file, and the only consumer of the Table is a debug print of the counts.
  *Anchors:* `src/assets/progression.zig:126-187`, `:163-167`, `:38-44`,
  `src/server/game.zig:839-844`, `Data/Config/progression.xml:189`, `:193-214`,
  `:240`, `:875`, `:879`

- **Perk purchase / spend skill points** `PARTIAL (waived)`
  Skill level changes are intentionally not authoritative (no server-side perk
  table yet); the client owns spend and the server persists level/XP. Full
  perk table + `GameEventRequest` wiring is a progression follow-on.
  *Anchors:* `src/server/game.zig:4794-4799`, `src/wire/packages.zig:2216-2235`

- **Perk / attribute passive effects applied to gameplay** `PARTIAL (waived)`
  649 `passive_effect` rows not yet wired; armour mitigation is the only live sim
  effect. Needs full `effect_group` VM — waived until progression runtime exists.
  *Anchors:* `src/ecs/inventory.zig:146-157`, `Data/Config/progression.xml`

- **Crafting skills / magazines / recipe unlock by progression** `PARTIAL (waived)`
  99 `unlock_entry` rows gating recipes behind crafting_skill not yet parsed;
  join PDF ships `always_unlocked` + wood-club seeds. Needs progression ledger to
  do without faking unlocks.
  *Anchors:* `src/assets/recipes.zig:52-88`, `Data/Config/progression.xml:245`

- **Gamestage (level plus days survived driving spawn difficulty)** `PARTIAL (waived)`
  Spawn uses `gsScale=1` (no scaling); `gamestages.xml` is now parsed in `§8`
  Gamestage PARTIAL and wiring full stage to every spawn needs the progression
  ledger. Waived until progression-driven difficulty lands.
  *Anchors:* `src/server/game.zig:7044`, `src/assets/gamestages.zig`

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

- **Health component and client-claimed damage into the sim** `WORKS` `(2026-08-22 re-audit)`
  C2S DamageEntity is validated (actor alive, target alive, both in interest range,
  strength capped, fatal honoured only against NPCs, PvP gate, armour mitigation)
  and applied. This is the only route by which a player's HP moves on the server
  other than eating. 2026-08-22 re-audit: the handler is complete and matches the
  row's claims - the C2S path (c2s/misc.zig NetPackageDamageEntity) adds plugin
  damage verdicts (on_player_damage), held-tool durability wear, combat noise and
  knockback-velocity fan-out on top of the validated apply; the row carried no
  documented residual and the stale `PARTIAL` marker is corrected.
  *Anchors:* `src/server/c2s/misc.zig:381-520`, `src/ecs/world.zig:665-710`,
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

- **Food / water application on eat** `WORKS` `(2026-08-22)`
  Works end to end and is the one live-verified vitals path (playtest
  `PASS economy/eat_food_consume ... food0=50.0 food=55.1`), driven by items.xml
  `$foodAmountAdd` / foodHealthAmount / `$waterAmountAdd`. 2026-08-22: the
  demo hack is gone - eating adds and caps at max (stock
  buffProcessConsumables), so a nearly-full stomach no longer drops the food
  bar to half before adding (the old 85% drain lowered 100 food to 65).
  Eating at full simply caps; unit test pins the no-drain cap. Stock routes
  the consumable through a buff with requirement gates; the net effect (food/
  water/HP add, capped) is what zdtd applies - documented internal
  difference.
  *Anchors:* `src/ecs/inventory.zig:285-306` applyEatProps,
  `src/assets/items.zig:444-456`, `Data/Config/items.xml:20015-20029`,
  `Data/Config/buffs.xml:8477`

- **Food / water decay over time** `WORKS`
  `tickSurvival` depletes food/water per game hour (`Rules.progression`
  `food_depletion_per_hour`/`water_depletion_per_hour` divided by
  `clock.seconds_per_hour`), synced to owner on `survival_sync_seconds`
  throttle. Starving/dehydrated players take `buffs.survival()` threshold-gated
  HP damage; well-fed ones regen. Verified: `game/tests` one-hour starve plaus
  + well-fed regen + starve HP loss.
  *Anchors:* `src/server/game/tick.zig:23-121`, `src/assets/buffs.zig:363-421`

- **Stamina simulation** `WORKS`
  `tickSurvival` drains `stamina_drain_per_second` while `sprint_stale_cd` is
  active and applies the `buffs.survival()` `StaminaChangeOT perc_subtract`
  penalty when starving; otherwise regens at `stamina_regen_per_second` toward
  max, with S2C `EntityStatChanged(stamina)` on change. Join vitals ship real
  `health.stamina` values, not hardcoded 100.
  *Anchors:* `src/server/game/tick.zig:125-150`, `src/server/game/join.zig:569-585`

- **Health regeneration / wellness / core temperature** `PARTIAL`
  Well-fed regen via `buffs.survival()` fraction-of-max gate is live; starvation
  damage is live. 2026-08-23 re-audit (RE entity-stats.md 3 + weather-
  environment.md 4): the **core-temperature server surface is present** - the
  server ships the per-biome temperature (slot 0) in `NetPackageWeather`
  (weather.zig buildWeatherBodyFromBiomes, from the live biome weather
  state machine) and the stock dedicated build deliberately **stubs the
  felt-temperature getters**: the client computes felt temp and applies the
  cold/hot buffs from its own weathersurvival.xml MinEvents, gated on the
  server's WeatherSurvivalEnabled. The stock weathersurvival.xml carries no
  tuning (only `TemperatureHeight height="0" addDegrees="0"`), so a server
  parse adds nothing. Remaining: **wellness** (the max-health-over-time
  system - eating quality food/drink raises wellness toward a cap, feeding
  `PlayerEntityStats.MaxHealth`; no consumer today).
  *Anchors:* `src/server/game/tick.zig:78-107`, `src/server/game/weather.zig:23-69`,
  `src/wire/packages.zig:2251-2295`, `../7dtd-research/docs/entity-stats.md:141-166`,
  `../7dtd-research/docs/weather-environment.md:257-300`,
  `Data/Config/weathersurvival.xml`

- **Death detection and the dead-player entity** `WORKS`
  A kill through C2S DamageEntity is detected, and the player entity is
  deliberately kept alive at hp 0 rather than destroyed (destroying it desyncs the
  client and breaks later net-id lookups). A second hit on a corpse cannot re-fire
  the kill side effects. Live: `PASS finale/player_death_screen dead=True hp=0`.
  *Anchors:* `src/server/game.zig:4937-4959`, `src/ecs/world.zig:677-705`,
  `src/server/game.zig:2865-2877`

- **Respawn: heal, teleport, PlayerSpawnedInWorld(died), re-bundle** `WORKS`
  The sequence fires and the client recovers (`PASS finale/player_respawn`),
  the heal is gated on actually being dead (a live player cannot spam
  RequestToSpawnPlayer for a free heal), the respawn target is the player's
  bedroll when placed else the world spawn (scenario `bedroll respawn`
  pins the death-screen list and the target), and the wire order is
  respawn-confirm first, then the teleport to the respawn point and the
  EntityStatChanged 100/100 (the redundant world-spawn teleport that flashed
  the client to spawn before the bed was removed 2026-08-22; the stat now
  follows the spawn confirm so it cannot be discarded in the death state).
  *Anchors:* `src/server/c2s/join.zig:323-381`,
  scenario `bedroll respawn`, `finale/player_respawn`

- **Respawn zeroes food and water** `WORKS`
  `respawnPlayer` now mutates hp/max_hp only, preserving food/water/stamina and
  seeding maxima when zero; respawn no longer starves the player to 0/100.
  *Anchors:* `src/ecs/world.zig:respawnPlayer`, `src/ecs/components.zig:22-37`

- **Bedroll / spawn point selection on respawn** `PARTIAL (waived)`
  Bedroll selection and `selectedSpawnPointKey` handling need a persistent bedroll
  registry and player-choice wire (`NetPackageRequestToSpawnPlayer`). Current
  respawn keeps players in the world (no ghost) and preserves food/water; bed
  placement choice is waived as respawn-choice subsystem.
  *Anchors:* `src/server/game.zig:5540-5558`, `src/wire/packages.zig:467-468`

- **DropOnDeath backpack** `WORKS` `(2026-08-22 re-audit)`
  The server spawns the death bag itself on the lethal event - both the C2S
  DamageEntity death path and the hp-replicate AI-kill detector call
  `spawnDeathBag`, which drops the victim's real inventory range (DropOnDeath
  1 all / 2 toolbelt / 3 backpack) at the death position and broadcasts the
  bag + the backpack map marker (`Client.has_backpack` coordinates the two
  paths so a death is never bagged twice; scenario `AI kill drops the
  player's real inventory as a death bag` pins the content). The client's
  `NetPackageRequestToSpawnEntity` ECD is still refused (the server bag makes
  it redundant and it proves no ownership), so the "single scrap" placeholder
  bag the row described is gone.
  *Anchors:* `src/server/game.zig:2677-2701` (`spawnDeathBag`),
  `src/server/c2s/misc.zig:513-536`, `src/server/game/replicate_health.zig:30`,
  scenario `AI kill drops the player's real inventory as a death bag`

- **DeathPenalty server option** `WORKS`
  `DeathPenalty` (0 nothing / 1 XPOnly / 2 Backpack / 3 Delete) is now a
  first-class serverconfig property: parsed + sandbox-wired (`SandboxOptions`
  option 26), passed into the Game, emitted in the GameStats blob
  (`gameStatsValues.death_penalty`), settable at runtime via `setoptions`,
  ranged in the mode packs and documented in `serverconfig.example.xml`.
  The behaviour itself is client-side in stock (`EntityPlayer::HandleClientDeath`
  switches on the stat and fires the `game_on_death_*` sequences), so an
  operator can now change the client's death flow and the server advertises
  the effective value.
  *Anchors:* `src/server/config.zig` (`death_penalty`),
  `src/server/game.zig:2148` (`gameStatsValues`),
  `src/server/admin_console.zig:748,905`, `src/server/mode.zig`,
  `src/assets/sandbox_data.zig:126`, `serverconfig.example.xml`

- **XP deficit death penalty on the server** `PARTIAL (waived)`
  `AddXPDeficit` (`ExpDeficitPerDeathPercentage`/`MaxPercentage` on
  `OnRespawnFromDeath`) not tracked; death/rebalance is otherwise client-ledger
  bound and has no player-visible blocker without the full progression runtime.
  *Anchors:* `asm.il:1084044`, `asm.il:1084146`

- **Death / kill counters** `PARTIAL (waived)`
  PDF/counters write literal zeros; stats UI is waived polish vs auth paths.
  Real counters would need persistent progression ledger wiring first.
  *Anchors:* `src/wire/packages.zig:479-483`, `:537-542`,
  `src/wire/stock_inv.zig:413-417`

- **players.zsv persistence: name, position, coins, inventory, journal** `WORKS`
  **ZPV3** merge-write (ZPV2 still read and upgraded with `prog=0`) that carries
  offline records over, refuses to clobber on a corrupt read, patches the header
  count from what was actually written, and re-resolves quest POI rects on load.
  Saved on the periodic tick when dirty, on `saveworld`, and on shutdown. Covered
  by the persist restart scenario. Layout: [ADR 0011](adr/0011-custom-zch-world-overlay.md).
  *Anchors:* `src/server/game.zig` (`savePlayers` / restore path),
  `src/server/scenarios.zig` (persist restart)

- **Progression persistence across restart or relog** `WORKS` (server ledger;
  PDF/wire residuals open)
  ZPV3 progression tail stores `Client.level` / `Client.xp` (the server-side
  `awardXp` ledger) and restores them on rejoin. Perk/skill-point spending remains
  client-owned with no server model; join PDF `progressionData` length and
  PlayerMetaInfo level may still under-report to the UI relative to the ledger.
  C2S PlayerData still does not ingest the client's progressionsData blob.
  *Anchors:* `src/server/game.zig` (ZPV3 tail write/read), STATUS T5,
  [ADR 0011](adr/0011-custom-zch-world-overlay.md)

- **Buff persistence across restart** `WORKS` (sim store; join PDF residual)
  Active buffs ride the ZPV3 progression tail (`buff_n` × BuffInstance fields) and
  are restored into ECS on rejoin. Residual: join PDF may still write buffData
  length 0 so the client UI can miss restored buffs until a later S2C path.
  *Anchors:* `src/server/game.zig` (ZPV3 buff tail), `src/ecs` buff slots

- **Vitals persistence (health, food, water)** `WORKS` `(2026-08-22 re-audit)`
  Food/water (and maxes) are in the ZPV3 progression tail and restored into
  `sim.health`. `(2026-08-22)` ZPV8 adds the player's current `hp` to the
  tail: the post-spawn restore pass applies it, so a relog keeps the player's
  wounds instead of granting a free full heal (v2-7 files migrate with a -1
  sentinel that keeps the spawn path's full health; round-trip + migration
  tests). Re-audit 2026-08-22: the join `hasEntityStats` residual is
  non-visible - the join EntitySpawn writes `hasEntityStats=false`, but the
  survival loop's first tick pushes HP/food/water/max and stamina via
  `NetPackageEntityStatChanged` immediately after spawn (`survival_sync_cd`
  starts at 0), so the client's HUD reads the same stats with no waiting.
  *Anchors:* `src/server/persist.zig` ZPV8/9 tail, `src/server/c2s/join.zig:203,230`
  (restore before/after spawn), `src/server/game/tick.zig:131` (first-tick sync),
  `src/server/game/join.zig` sendSurvivalStats / sendStaminaStats

- **progression.zig curve-only loader** `WORKS` `(2026-08-22 re-audit)`
  `loadFromPath` is a clean single parse (`readCleanFile` + `parseCurve`, no
  arena); `tryLoad` routes through it and `tryLoadTable` is the separate
  table loader. The old double-parse-with-leak (`loadTableFromPath` result
  discarded via `_ = t` without deinit) is gone.
  *Anchors:* `src/assets/progression.zig:87-90` (`loadFromPath`), `:191-197`
  (`tryLoad` / `tryLoadTable`)

---

## 11. World systems

**Headline.** A player can walk, dig, build and persist on real Navezgane terrain
with POIs, day/night and weather; lakes fill from water_info sources, claims
expire, repair heals and supports collapse, but the world is visually bald (3
deco objects per join), terrain is stepped rather than smooth, and block-rotation
persistence and the HUD day counter each have specific, noticeable gaps.

**38 WORKS · 6 PARTIAL · 0 MISSING**

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

- **DTM sub-block precision** `PARTIAL → RE-CORRECTED (2026-08-23)`
  The row's premise was stale: stock's surface density is **binary** too -
  `fillDensityInBlock` (IL=16, dumped 2026-08-23) sets `IsTerrain() ?
  DensityTerrain : DensityAir` and `GenerateTerrain` stamps the surface cell
  with it. The wire heightmaps are byte[256] and the density channel is
  binary, so the 1/256 DTM height fraction is not wire-representable and no
  stock server encodes it. The client's smooth rolling surface comes from
  the meshers interpolating the byte heightmap across columns
  (`MeshGenerator.CreateMesh` 5-column heights array, IL=1083;
  `MeshGeneratorMC2.build` terrainHeightsCache + topSoilCache, IL=1662;
  research: chunk-providers.md "Surface density is binary"). zdtd emits the
  same binary density + byte heightmaps, so the wire is stock-faithful;
  `heightAtWorld` keeping the fraction would have no wire consumer.
  Remaining: live-client confirmation that the cross-column smoothing reads
  zdtd's heightmap identically to stock's (playtest ground case); the
  sub-block fraction stays used only where stock uses it (none on the
  server surface).
  *Anchors:* `src/world/dtm.zig:33`, `src/wire/stock_chunk.zig:28-33`,
  `:430-435`, `7dtd-research docs/chunk-providers.md` + `il/terrain-v3.1.0/
  TerrainGeneratorWithBiomeResource_fillDensityInBlock_*_il.txt`

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

- **Chunk streaming to the stock client** `WORKS` `(2026-08-22)`
  Hole-free centred square, add/remove deltas, paced 8 adds per 5-tick period.
  `(2026-08-22)` the stream budget covers the full stock view: the compile cap
  is now 625 (a 25x25 square, radius 12 - the stock client's view-distance-12
  request) instead of 169, which truncated the default view-7 stream to a
  13x13 hole-free disk (~104 blocks) with no server terrain beyond. The
  default view-7 now streams its full 225 chunks, `chunk_stream_radius_max`
  defaults to 12, and the in-view bitset grew to 640 bits so the O(1)
  membership probe stays on the fast path at the full square.
  *Anchors:* `src/server/zdtd_config.zig` max_streamed_chunks_cap,
  `src/server/game/chunk_stream.zig` (bitset + radius), `src/server/game/types.zig`

- **Resident chunk cap and deterministic eviction** `WORKS`
  4096 resident chunks, min-key victim (not HashMap walk order) so DST replay is
  stable, save-before-free so nothing is discarded unsaved.
  *Anchors:* `src/world/store.zig:524-547`

- **Async chunk flush** `WORKS`
  Opt-in background writer with a per-key wait guard mirroring stock
  `RegionFileManager::IsChunkSavedAndDormant`; falls back to inline write rather
  than dropping; force-serial under DST so fault injection still surfaces errors.
  *Anchors:* `src/world/chunk_flush.zig:1-80`, `src/world/store.zig:789-822`

- **Per-chunk biome** `WORKS`
  Each of the 256 biome cells carries the biome-map value at its world XZ
  (biomes.png for stock maps, the proc field for RWG), so transitions follow
  the map per 1-block cell instead of snapping to the chunk dominant; the
  per-column BiomeIntensity reports that cell's id at full strength, and
  DominantBiome / AreaMasterDominantBiome are the modal cell (stock
  CalcDominantBiome semantics: count, first maximum). Client-side microsplat
  blending is a renderer concern, not server wire; no per-cell blend weights
  exist in the stock chunk body.
  *Anchors:* `src/wire/stock_chunk.zig:77-78,521-555`,
  `src/server/game/chunk_fill.zig:91-110,132-133`

- **Topsoil bitfield / splat maps** `PARTIAL` `(2026-08-22)`
  The stock `m_bTopSoilBroken` bitfield now rides the wire for real: the
  chunk keeps the 32-byte state (fresh = all-clear, so the client
  splat-renders the top terrain block like stock; `setTopSoilBroken` marks
  a column disturbed on a dig/upgrade/explosion at or above the column
  surface, with the 1-wide border-neighbor pass, RE `Chunk.SetTopSoilBroken`
  IL=36 / blocks.md position path), the wire writes the chunk's actual
  bytes instead of the old all-0xFF workaround (which made every column
  render block textures), and ZCH3 persists the bitfield as a trailing 32
  bytes (older saves load all-clear; bits re-set on the next dig). The
  `topsoil_all_broken` rules key (default false) restores the legacy look
  for worlds without splat maps (the flat demo world). Client-visible:
  Navezgane terrain now splat-blends like a stock server until a column is
  dug. Not yet verified on a live client render; the playtest ground case
  gates it.
  *Anchors:* `src/world/store.zig` Chunk.topsoil/setTopSoilBroken +
  markTopSoilBroken + ZCH3 tail, `src/wire/stock_chunk.zig` topsoil write,
  `src/ecs/rules.zig` WorldGroup.topsoil_all_broken,
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

- **POI / prefab placement from prefabs.xml plus .tts** `WORKS` `(2026-08-22 re-audit)`
  Full POIs flatten heights and paint their block/texture/density planes, and TEs
  are enumerated for storage. Re-audited 2026-08-22: `part_` prefabs are **not**
  skipped - they are placed (height flatten to ground, no pad) and painted under
  the `part_paint_volume_cap` (24^3; `isPaintablePart`), and Navezgane's 72 parts
  (driveways, town signs, the pedestrian bridge) all fit under it, so roads and
  driveways are present on stock maps. The huge RWG clutter parts skip painting
  as a documented perf choice (RWG-owned, section 3).
  *Anchors:* `src/world/prefabs.zig:49-66` (isPart / isPaintablePart), `:216-235`
  (part flatten), `:487` (paint gate), `src/world/tts.zig:1-200`

- **Player-placed block rotation / meta in the chunk plane** `WORKS` `(2026-08-22 re-audit)`
  The placement paths write the full 32-bit BlockValue (`setBlockRawWorld`,
  type low 16 + rotation/meta upper bits) into the chunk's raw plane
  (`src/world/store.zig:779-783`, GAP 13 fix); the chunk wire encoder's
  rawData provider reads that plane (`src/wire/stock_chunk.zig:44`), and ZCH3
  persists the u32 plane so a second client or a relog re-renders the
  rotation. Test `rotation raw lives in the chunk plane and survives
  save/reload` (store.zig:1570) pins the round trip. The bare-u16
  `setBlockWorld` remains for air/terrain edits where rotation does not
  apply.
  *Anchors:* `src/world/store.zig:779-783` setBlockRawWorld,
  `src/server/c2s/blocks.zig:68,160` (placement), `src/wire/stock_chunk.zig:44`,
  test `rotation raw lives in the chunk plane and survives save/reload`

- **Block damage in the chunk wire** `WORKS`
  `writeDamageChannel` encodes the per-cell u16 damage via the `dmg_at` hook
  (`getBlockHp` sparse store, 256-entry FIFO); chunkFill threads it through
  `DmgCtx` (world coords). Null hook falls back to all-zero.
  *Anchors:* `src/wire/stock_chunk.zig:writeDamageChannel`, `src/server/game/chunk_fill.zig:DmgCtx`

- **Join-time deco burst (NetPackageDecoUpdate) plus world mirror** `WORKS`
  One `firstPackage=true` burst at RequestToEnterGame, 4096 objects per package,
  mirrored into the block store so collision and harvest agree. Decorations now
  also stream with newly entered chunks: `sendDecoForStreamedChunk` generates +
  sends each new 128-block deco chunk once per client (tracked in
  `Client.deco_sent`), mirroring as it goes - the client's `DecoManager.Read`
  ADDS post-join firstPackage=false updates to `loadedDecos` (DecoManager.il.txt
  Read IL=29; the old "client discards post-join deco" assumption was not RE'd
  and is wrong), so the world is decorated beyond the join radius.
  *Anchors:* `src/server/game/join.zig:140-275`, `src/server/game/chunk_stream.zig:198-210`,
  `src/wire/stock_deco.zig:98-141`, `src/world/deco_mirror.zig:1-22`

- **Deco density (biomes.xml probabilities)** `WORKS` (superseded 2026-08-08,
  see work-log entry #18)
  Was: zdtd sampled only the biome's top-level `<decorations>` list and never
  evaluated subbiome noise, so pine_forest's dense subbiome rows
  (treeJuniper4m .06, treeDeadTree01 .07, treeDeadPineLeaf .08) never fired and
  a 13x13-chunk join window produced only 3 deco objects. `decoSpeciesAt` now
  resolves each cell's subbiome through `subbiome_noise.zig` (a clean-room port
  of stock's `GetBiomeOrSubAt`, ported PerlinNoise/GameRandom) and samples that
  subbiome's own list, matching stock's `decorateChunkRandom`.
  *Anchors:* `src/world/subbiome_noise.zig`, `src/server/game/deco.zig:19`,
  `src/server/game/join.zig:55`, `Data/Config/biomes.xml:489-507`

- **Deco rotation** `WORKS`
  Every DecoObject carries a `BiomeBlockDecoration::GetRandomRotation` roll
  (0..3, 90 degree steps) in rawData bits 16..20, keyed to the placement cell so
  every clipping window and the world mirror agree on the rawData. Trees and
  rocks no longer all face north; the mirror reads the same rotation bits, so a
  rotated multiblock keeps its child-cell offsets consistent.
  *Anchors:* `src/wire/stock_deco.zig:352-372`, `:32-37`

- **Deco ore-noise gate (CheckOreNoiseAt)** `PARTIAL (waived)`
  Not implemented; deliberate because every `checkresource` row in stock biomes.xml
  is a `type="prefab"` row zdtd does not send (prefab decorator, not DecoUpdate).
  *Anchors:* `src/wire/stock_deco.zig:287-289`

- **type="prefab" decorations** `WORKS` `(2026-08-07)`
  Biomes.xml `type="prefab"` rows (rock_form01/02, deco_iron_vein,
  deco_coal_vein) are not part of the distant-deco species: stock
  `BiomeDefinition::AddDecoBlock` builds `m_DistantDecoBlocks` from
  `IsDistantDecoration` blocks only (treeMaster/treeCactus01, world-chunks.md
  §Distant deco), and the prefab rows feed the dynamic prefab decorator, not the
  DecoUpdate burst. Skipping them matches stock, so the claim that they "never
  appear anywhere" is about the not-yet-implemented dynamic prefab decorator
  (prefabs.xml `<decoration>` placement), tracked separately.
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

- **Weather biome padding when biomes.xml yields fewer than 5 weather biomes** `WORKS` `(2026-08-22 re-audit)`
  When n < 5 the last real state is duplicated into fabricated biome_ids 1..5. The
  client keys strictly by biomeId, so a partial or modded biomes.xml would push one
  biome's groupIndex into another whose group list may be shorter, while
  `buildWeatherBody` clamps against the source biome's group_count. Dead for stock
  data (stock biomes.xml supplies exactly 5 weather biomes), live for modded
  biomes.xml only - out of stock-scope parity; the clamp keeps fabricated ids from
  overrunning the source group list.
  *Anchors:* `src/server/game.zig:8211-8235`, `src/wire/packages.zig:2065-2075`,
  `asm.il:2054217-2054277`

- **StormFrequency configurability** `DONE 2026-08-07`
  `[sim] storm_frequency` (zdtd.toml, percent, default 100; 0 disables storms)
  feeds both the weather scheduler divisor and the GameStats wire value, so the
  client's storm scheduler and the server agree.
  *Anchors:* `src/world/weather.zig:52-53`, `src/server/game.zig` `gameStatsValues`,
  `docs/GAME_OPTIONS.md` `[sim]`

- **Weather gameplay effects (gates)** `DONE 2026-08-07`; **buffs: client-owned by design**
  The operator's `SandboxCode`/`SandboxPreset` now parse from serverconfig and
  ride the GameStats blob (EnumGameStats 71/70), so a joining client decodes the
  server's sandbox gates - TemperatureSurvival, StormFreq, blood-moon settings -
  instead of its own defaults (RE sandbox-options.md §8: the client decodes
  GameStats.GetString(71) in AfterPlayerRespawn). Per weather-environment.md §4,
  the stock *dedicated* server stubs the felt-temperature helpers and does NOT
  compute wet/cold buffs: the local client computes felt temperature from the
  shipped per-biome params + weathersurvival.xml MinEvents. Server-side buff
  application would double-apply and is intentionally not implemented. GSI
  advertising SHIPPED 2026-08-07: the TCP GameServerInfo text (and the
  PlayerLoginAnswer copy) carries `SandboxPreset`/`SandboxCode`
  (GameInfoString 18/19) when the operator set them; unset keys are omitted
  (empty = client default, same as GameStats).
  *Anchors:* `src/server/config.zig` SandboxCode/SandboxPreset,
  `src/server/serverinfo_tcp.zig` `buildInfoText`, `src/server/game.zig` `gameStatsValues`,
  `src/wire/packages.zig:2039-2040`,
  `../../7dtd-research/docs/weather-environment.md` §4, `sandbox-options.md` §8

- **Day/night clock and NetPackageWorldTime broadcast** `WORKS`
  WorldClock advances hours from real dt scaled by DayNightLength, dawn fixed at
  04:00 and dusk = 4 + DayLightLength, broadcast as a u64 every 20 ticks and sent
  once at enter. Blood-moon nights, zombie speed bands and POI lockouts all read
  the same clock.
  *Anchors:* `src/ecs/aidirector.zig:6-68`, `src/server/game.zig:8101-8103`,
  `:6204-6205`

- **World time day number** `WORKS` `(2026-08-21 re-audit)`
  `worldTimeBits` is the stock `DayTimeToWorldTime` exactly:
  `(day-1)*24000 + hours*1000`, with `WorldTimeToDays(wt) = wt/24000 + 1`
  (day 1 spans [0, 24000); a day-0 test clock encodes as 0 without
  underflow). The client HUD and the day-7 blood moon both decode the same
  wire day; the pinning test asserts day 1 08:00 = 8000 and day 7 12:00 =
  6*24000 + 12000 round-trips to day 7. No residual day-off-by-one encoding
  remains anywhere in the clock path.
  *Anchors:* `src/ecs/aidirector.zig` `worldTimeBits` +
  test `worldTimeBits encodes stock day 1 as zero offset`,
  `asm.il:1926175-1926208`, `asm.il:1925943-1925956`

- **World clock persistence across restart** `WORKS`
  `clock.zcl` (magic ZCL1, stock-shaped `worldTime` u64) is saved on the periodic
  save path and at deinit, and restored over the fresh clock at init. The
  blood-moon calendar derives from the day, so a save keeps its horde schedule.
  (Duplicate of the blood-moon schedule persistence entry above; kept here so the
  §world-time residual list does not re-open a shipped store.)
  *Anchors:* `src/server/game.zig` (`saveClock`/`restoreClock`),
  `src/ecs/aidirector.zig` (`WorldClock.worldTimeBits`)

- **Blood-moon schedule plus NetPackageBloodmoonMusic** `WORKS`
  Deterministic jitter around each frequency multiple with neighbouring cycles
  tested so a jittered day across the boundary still fires; music package
  edge-triggered on the transition. (Divergences from stock in
  [section 6](#6-blood-moon).)
  *Anchors:* `src/ecs/aidirector.zig:41-61`, `src/server/game.zig:8114-8121`

- **Water blocks in the world** `WORKS`
  `water_info.xml` sources fill water blocks from lake bed up to source surface
  (`Chunk.applyWaterSources`), prefab `.tts` water plane paints water blocks, and
  `terrain_ids.water` resolved from AssignIds drives both. Verified by loadgen on
  Navezgane.
  *Anchors:* `src/world/store.zig:183-198`, `src/world/water.zig:63-110`,
  `src/world/tts.zig:170-210`

- **Chunk water channel on the wire** `WORKS`
  `writeWaterChannel` encodes per-cell WaterValue mass (19500) for water cells
  via same-value / byte-planes, carried in every chunk; client renders wet.
  *Anchors:* `src/wire/stock_chunk.zig:630-680`, `:768-801`

- **Water simulation / flow packages** `PARTIAL (waived)`
  Static water blocks + channel mass are live; dynamic flow sim via
  `NetPackageWaterSet` / `NetPackageWaterSimChunkUpdate` remains stock-only.
  Placing/removing a water source does not trigger flow.
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
  *Anchors:* `src/world/stability.zig`, `../../7dtd-research/docs/stability.md`

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

- **Player block damage (C2S SetBlock, BlockDamagePlayer, break)** `WORKS`
  Reach-gated, land-claim-gated, throttled, scaled by BlockDamagePlayer, broken
  when absolute damage reaches blocks.xml MaxDamage, with an authoritative S2C
  echo. Damage is stored per-cell in the chunk damage plane (`Chunk.damages`,
  u16 absolute HP) and persisted by ZCH3, so the old global FIFO cap (64, then
  1024) is gone: any number of distinct damaged blocks keeps its absolute value
  mid-fight, survives chunk eviction and restarts, and the chunk wire damage
  channel reads the plane directly (no store scan per cell).
  *Anchors:* `src/server/c2s/blocks.zig:63-135`, `src/server/game/world.zig`
  (`setBlockHp`/`getBlockHp`/`clearBlockHp`), `src/world/store.zig`
  (`Chunk.damages`, `setDmg`/`dmgAt`), `src/server/game/chunk_fill.zig`
  (`DmgCtx`)

- **Block repair (ItemActionRepair)** `WORKS`
  Stock repair calls `Block::DamageBlock` with a **negated** repair amount and
  SetBlockRPCs the resulting **lower** absolute damage, so C2S SetBlock carries
  damage < current. zdtd now takes the wire value as the new absolute damage
  when it is lower (never adds a lower value as a delta), so repairing 500 to
  300 sets 300 and a full repair (0) clears the damage; the block's hp then
  rises toward max on the next damage write.
  *Anchors:* `src/server/game.zig:6024` repair branch, `asm.il:657520-657583`,
  `asm.il:96545-96562`, `asm.il:96797-96812`

- **Block upgrade (frame to reinforced)** `WORKS` `(2026-08-22 re-audit)`
  The server now has the UpgradeBlock table: `maxdamage.zig` parses blocks.xml
  `UpgradeBlock.ToBlock` (Extends-resolved, stock chains like woodFrame ->
  wood -> cobblestone -> concrete -> steel) and the C2S SetBlock path
  validates the claimed upgrade - when the client sends a new block id, it
  must equal the current block's table target (`maxdamage.upgradeTarget`),
  else the edit is rejected (`continue`), so a modified client cannot upgrade
  anything to anything. Resource consumption and repair/upgrade XP are
  client-side stock mechanics (the client deducts materials during its own
  upgrade flow and our dig/repair path already grants mining XP), documented
  as such.
  *Anchors:* `src/server/c2s/blocks.zig:148-153` (target validation),
  `src/assets/maxdamage.zig:75-76,208-210` (UpgradeBlock table),
  `asm.il:96718-96762`, `asm.il:657572`

- **Block downgrade on destroy (Stage2Health)** `PARTIAL (waived)`
  Stock `DamageBlock` can downgrade via `Stage2Health`; zdtd always clears to air.
  Visible on the small set of multi-stage blocks only. Wire is correct (chunk +
  SetBlock echo) and full block-state downgrade needs `blocks.xml` `DowngradeBlock`
  wiring across the whole pipeline — waived as stage-fidelity, not parity blocker.
  *Anchors:* `src/server/game.zig:5162-5166`, `asm.il:96828-96833`

- **Zombie block damage** `PARTIAL`
  Zombies in chase/attack within 3 blocks chew the solid cell in the front
  column (feet to head, first solid), 10 damage per 2 Hz bite scaled by
  BlockDamageAI (AIBM on blood moon), broadcast on break. 2026-08-22: the
  probe scans the body height instead of head-only, so zombies chew
  1-block-tall walls instead of getting stuck forever, and a 2-tall door
  opens on both halves (scenarios zombie-lowwall + zombie-door). Simplified:
  a single ray-less cell probe rather than real AI block-target selection
  (the damage store now shares the exact per-chunk plane as player damage,
  so no cap or eviction remains).
  *Anchors:* `src/server/game/tick.zig:215-290`, `:355-376`

- **Block max HP from blocks.xml MaxDamage** `WORKS`
  Resolved per block id from the parsed table with Extends resolution; fails closed
  to 100 when the catalog is loaded but the id is unknown, and only falls back to
  id-band guesses when no catalog was loaded at all.
  *Anchors:* `src/server/game.zig:3235-3245`, `src/assets/maxdamage.zig`

- **Explosion block damage** `WORKS`
  Demolition blasts carry per-entity ExplosionData from entityclasses.xml
  (`<property class="Explosion">`, Extends-resolved: the stock cop ships
  RadiusBlocks 5 / RadiusEntities 6 / BlockDamage 500 / EntityDamage 150,
  feral/radiated/infernal tiers override the damages), with the Rules values
  as the floor; blocks in the sphere take linear distance falloff damage
  through the addBlockDamage choke point, scaled by the class's DamageBonus
  material multipliers (materials.xml damage_category; stock cop: earth → 0,
  so terrain survives the blast), break at blocks.xml MaxDamage, and partial
  damage persists in the chunk damage plane (GAP "Player block damage").
  The falloff formula itself is not tabulated in the RE corpus (approximation:
  linear 1 - d/radius).
  *Anchors:* `src/assets/entities.zig` (`ExplosionDef`, `resolveExplosion`),
  `src/assets/maxdamage.zig` (`material_category`, `categoryForBlock`),
  `src/server/game/world.zig` (`drainExplosions`),
  `src/ecs/world.zig` (`EntityClass.explosion_*`)

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

- **Land claim persistence** `WORKS`
  `claims.zlc` (ZCL1) persists the claim array across restart; `loadClaims` on
  boot and `saveClaims` on tick/deinit/peer-drop/claim-mutate restore it, and a
  scenario asserts round-trip across a fresh `World` with the same dir. Owner
  id re-maps on login via name.
  *Anchors:* `src/server/persist.zig:517-580`, `src/server/game/world.zig:5`,
  `src/server/scenarios.zig:4253-4285`

- **Land claim replication to the client (lpBlocks)** `PARTIAL (waived)`
  Server enforces claims on the C2S `SetBlock` path (`claimCovering` + owner check
  before apply); the PPD lpBlocks overlay is still empty (needs `PersistentPlayerData`
  `LPBlocks` `List<Vector3i>` RE decode + `World::GetLandClaimOwner` wiring). Leaving
  MISSING would invent the `List<Vector3i>` wire shape without the RE dump for
  `PersistentPlayerData::Write` count-vs-list layout, so waived per stop rule.
  *Anchors:* `src/server/c2s/blocks.zig:claimCovering`, `src/wire/stock_inv.zig:846-885`,
  `../7dtd-research/il/realearth-surfaces-v3.1.0/PersistentPlayerData_Write_BinaryWriter_il.txt:IL_008E-00D7`

- **Land claim rules: Count, DeadZone, ExpiryTime, DecayMode, OfflineDelay** `PARTIAL`
  ExpiryTime is enforced (`expireClaims` on the day roll, offline only); the other
  four (claim Count, DeadZone, DecayMode, OfflineDelay) are written into the
  GameStats blob so the client displays them. `(2026-08-22)` all four parse from
  serverconfig with stock defaults (Count 3, DeadZone 60, OfflineDelay 3,
  DecayMode 0) and feed the blob; Count and DeadZone are now enforced at
  registration (`claimAllowed`: refuse claims past the owner's count or inside
  another claim's dead zone; test `land claim count and dead-zone gates`).
  Residual: the DecayMode/OfflineDelay keystone-damage rate is not documented
  in 7dtd-research (RE-blocked), so offline decay beyond expiry is not modeled.
  *Anchors:* `src/wire/packages.zig:1916-1920`, `:1984-1991`,
  `src/server/game/world.zig` claimAllowed + expireClaims,
  `src/server/c2s/blocks.zig:157` (placement gate), `src/server/config.zig`

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
single join, silently ignores 32 packages the stock client actually sends, and
persists so little that a restart visibly damages a built base.

**48 WORKS · 0 PARTIAL · 0 MISSING**

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

- **C2S handler coverage** `WORKS` `(2026-08-22 re-audit)`
  86 package names have a handler in `Game.handlePackage` (PlayerDisconnect,
  SharedPartyKill, PartyQuestChange, PlayerVendingMachine, GameEventResponse,
  EntityStatChanged, Waypoint, GameMessage, SoundAtPosition,
  EntityAwardKillServer, ParticleEffect, EntityStealth, QuestGotoPoint,
  QuestTreasurePoint, EntityPhysics and EntityRagdoll have handlers
  since the last count; the Waypoint
  relay parses the full Waypoint v7 body and fans the invite to the
  inviter's allies or all players per
  GameManager.WaypointInviteServer, the GameMessage relay re-broadcasts
  the 9-byte announcement body to every client per
  FinishGameMessageServer - death/team/leave/chat announcements now reach
  other players, the SoundAtPosition relay re-broadcasts positional
  audio to every client except the owning player per
  PlaySoundAtPositionServer, the EntityAwardKillServer kill report is
  a validated no-op because zdtd credits kill objectives and XP
  authoritatively at the death path - applying the client echo would
  double-credit, the ParticleEffect relay re-broadcasts client-triggered
  particles to every client except the causing entity's owner per
  SpawnParticleEffectServer, the EntityStealth stealth report is a
  validated no-op because zdtd computes stealth server-side (crouch from
  movement frames, smell from buffs), the QuestGotoPoint /
  QuestTreasurePoint reports are validated no-ops because goto objectives
  complete by proximity (questTickGoto) and fetch/treasure phases advance
  from the QuestObjectiveUpdate treasure_complete event, the
  EntityPhysics physics-master report is a validated no-op because
  movement/falling-block/vehicle sims are server-authoritative, and the
  EntityRagdoll impulse relays to the other clients - the owner already
  ragdolled locally (SendPacketToTrackedPlayersAndTrackedEntity)).
  Scanning asm.il for `GetPackage<X>` immediately preceding `SendToServer`
  yields 98 names the stock client actually sends; 16 have no handler,
  categorized by scope (protocol-packages.md 5.14): mod API surface
  (ModifyCVar, SetProp, SimpleRPC, Debug), EAC/encryption waivers (EAC,
  EncryptionPublicKey, KeyExchangeComplete), creative/editor
  (EditorUpdateVolume, WorldFolder), Twitch integration (PlayerTwitchStats,
  TwitchAccess, TwitchVoteScheduling, PlayerLaserSight), headless mesh
  (DynamicMesh), deferred cosmetic/depth (DroneDataSync,
  DroneParticleEffect junk-drone state).
  Re-audited 2026-08-22: ragdolls **do** relay - the owner's client forces
  its local ragdoll and the server re-broadcasts the verbatim body to the
  entity's other tracked players (stock SendPacketToTrackedPlayersAndTracked
  Entity; `src/server/c2s/misc.zig` NetPackageEntityRagdoll), and the 16
  no-handler names above are all non-stock-play scope (mod API, EAC waiver,
  creative editor, Twitch, headless mesh, drone cosmetic state), so nothing
  a stock client sends in normal play is dropped unhandled. (Goto/treasure
  quest markers register through the server's objective wire; the client's
  reach/dig reports are redundant with the server's proximity completion and
  QuestObjectiveUpdate events. Local map waypoints stay client-local as in
  stock; only the party waypoint invite traverses the server, and it now
  relays. The vending C2S buy residual is tracked by the Vending machines
  row.)
  *Anchors:* `src/server/game.zig:3771-5480`, `src/server/c2s/quest.zig`
  (NetPackageWaypoint), `src/server/c2s/misc.zig:205` (EntityRagdoll relay),
  `asm.il:791490-791510`,
  `asm.il:793038-793060`

- **Wrench pickup (NetPackagePickupBlock handling)** `WORKS` `(2026-08-21)`
  The C2S body (3x i32 pos | u32 rawData | i32 playerId | platform identity,
  RE netpackage-bodies.md) is parsed and run through the stock server checks
  (asm.il GameManager.PickupBlockServer IL=77): the claimed entity must be the
  sender's own, the platform identity must match the registered primary/native
  id (null passes only when the sender registered none, NetPackage IL=29), the
  world block type must still match what the client snapped, and zdtd adds
  reach + land-claim bounds on top. On success the pickup package is echoed to
  the requesting player (whose client runs PickupBlockClient -> OnBlockPickedUp
  and adds the item through its normal inventory sync, exactly like stock; the
  dedi never fabricates the item) and the block is replaced with
  PickupSource/Air (V3.1.0 b14 ships no PickupSource property, XML.txt:908
  declares it, so stock leaves Air on every pickup; a modded blocks.xml is
  honoured via `BlockTable.pickupSource`).
  *Anchors:* `src/server/c2s/blocks.zig` NetPackagePickupBlock branch,
  `src/wire/packages.zig` parse/buildPickupBlockBody,
  `src/assets/blocks.zig` `pickup_source`

- **Paint (NetPackageSetBlockTexture handling)** `WORKS` `(2026-08-21)`
  The C2S body (3x i32 pos | u8 face | u8 idx | i32 playerIdThatChanged | u8
  channel, RE netpackage-bodies.md) is parsed and validated (own-entity claim,
  reach + land-claim bounds; channel 0 only - `Chunk.chnTextures` is a
  1-element array, Chunk IL_01F8-01FE - and face 0..5). The face byte stores
  the BlockTextureData catalog idx raw (Chunk.SetBlockFaceTexture IL=48 masks
  `_texture & 255` into face*8 bits), read-modify-write into the per-block
  textureFull plane (`Chunk.texAt` + `setBlockTexDensWorld`, persisted by
  ZCH3), seeding unpainted faces from the block's default texture so the other
  five faces do not grey out. The dedi rebroadcast
  (GameManager.SetBlockTextureServer IL=41) carries playerIdThatChanged=-1 and
  reaches every peer but the painter, who already applied the paint locally.
  *Anchors:* `src/server/c2s/blocks.zig` NetPackageSetBlockTexture branch,
  `src/wire/packages.zig` parse/buildSetBlockTexture,
  `src/world/store.zig` `textures` plane + `setBlockTexDensWorld`

- **Reload relay (NetPackageItemReload handling)** `WORKS` `(2026-08-21)`
  The C2S body (single i32 entityId, RE netpackage-bodies.md) is validated
  against a real player entity and relayed to every peer but the sender
  (GameManager.ItemReloadServer IL=32, flags 192), so the other players see
  the reload animation; the sender already started its own reload locally and
  needs no echo. Ammo-count changes continue to ride the normal inventory
  sync. The relay is throttled and entity-gated so a spoofed id cannot fan
  out to every connected peer.
  *Anchors:* `src/server/c2s/inv.zig` NetPackageItemReload branch,
  `src/wire/packages.zig` `parseItemReload`

- **Unhandled C2S packages are dropped with no trace** `WORKS` `(2026-08-07)`
  `handlePackage` is a linear if/eql chain; the fall-through now increments
  `c2s_unhandled` and rate-limit logs the first and every 100th occurrence with
  the peer local id, so a new stock client package surfaces instead of
  vanishing (no evidence event yet).
  *Anchors:* `src/server/game.zig:3771-3790`, `:5478-5480`

- **S2C package emission coverage** `WORKS` `(2026-08-22 re-audit)`
  57 package names appear in server send calls (sendGame/broadcast/
  sendGameCritical/trySendCompressed across `game.zig` + `game/*.zig` +
  `c2s/*.zig`; recount 2026-08-22 - the join bundle, chunk/deco/weather
  stream, stat/vitals pushes, the map trio, the social relays (Waypoint,
  GameMessage, SoundAtPosition, ParticleEffect, EntityRagdoll), the
  response packages (SetBlockResponse, InventoryDataResponse, etc.) and
  the auth denies). The in-game minimap now fills in: the client's
  NetPackageMapPosition C2S arms a 17x17 chunk window (RE
  MapChunkDatabase.GetMapChunkPackagesToSend), and the server sends
  NetPackageMapChunks (channel 1, compressed, batched) with per-chunk 256
  RGB555 colors computed from the top visible block (MapColor property, else
  the texture-atlas color, else gray; water = BlockLiquidv2.Color) - the
  atlas colors come from the meshdescriptions bundle (texture-atlas.md).
  The map trio is complete: player markers broadcast every 6 s
  (NetPackagePersistentPlayerPositions, 2026-08-21) and trader areas ship on
  join (NetPackageWorldAreas). Falling/jumping zombies stream their vertical
  velocity (NetPackageEntityVelocity, 2026-08-21, delta-gated in the
  replicate fan-out). The player list broadcasts every 5 s
  (NetPackageClientInfo, 2026-08-21). Death bags mark the map: the dropped
  backpack marker broadcasts on drop and clears on collect
  (NetPackagePlayerSetBackpackPosition, 2026-08-21). Turrets stream their
  aim/on state to viewers (NetPackageTurretSync, 2026-08-21, change-gated in
  the replicate fan-out). Join ships the primary cluster descriptor
  (NetPackageChunkClusterInfo, 2026-08-21, right after WorldInfo per the
  client's chunkClusterLoaded gate; ChunkProviderDisc bounds for fixed DTM
  maps, infinite (0,0)/(0,0) for proc/flat). ToClient names never sent at all
  include EntitySetSkillLevelClient, WallVolume, Light, TreeFade,
  AudioPlayInHead, WaterSimChunkUpdate, AuthState.
  Corrected (2026-08-21): EntityAddExpClient IS emitted on kills (killXpAward,
  stock_xp builder); ShowToolbeltMessage is not a pickup notification - its
  sole stock sender is the Homerun minigame (ShowTooltipMP unicast,
  protocol-packages.md); NetPackageSleeperPose is stock-dead (the sleep pose
  rides EntitySpawn flags); the sleeper trio wake path is wired (SleeperWakeup
  on proximity/noise/damage wake, passive spawn flags). Turrets do not
  animate.
  Never-sent non-goals (2026-08-21, all cited from the V3.1.0 b14 dump):
  EntitySetSkillLevelClient (perk/skill progression sync - zdtd has no skill
  system; the progression area tracks it), WallVolume (prefab wallvolume
  data + World.AddWallVolume broadcast - zdtd does not load wallvolume
  definitions, so there is nothing to send and the sim does not repel with
  them), Light (LightManager/NetPackageLight Setup(entityId, level) - dynamic
  light-flicker rendering, cosmetic), TreeFade (EntityFallingTree fade FX,
  cosmetic), AudioPlayInHead (one-shot client SFX; stock senders are
  EntityNPC.PlayVoiceSetEntry trader/NPC voice lines and
  EntityDrone.BroadcastPlayVO, cosmetic audio), WaterSimChunkUpdate
  (fine-grained water-flow voxel deltas for the client's cosmetic water sim;
  server-authoritative water still streams as blocks), AuthState
  (AuthorizationManager StateLocalizationKey - the "Login: ..." progress
  text in XUiC_ProgressWindow; EAC-scope authorizer UX, no gameplay effect
  with the stock client's default progress text).
  Re-audited 2026-08-22: every never-sent name above is a documented non-goal
  under the parity rules - skill-level sync is tracked by the Player
  progression area, WallVolume is not loaded (no wallvolume defs, nothing to
  send), Light/TreeFade/AudioPlayInHead/WaterSimChunkUpdate are cosmetic FX
  or a cosmetic water sim (server-authoritative water still streams as
  blocks), and AuthState is EAC-scope authorizer UX. Turret animation is
  client-driven from the TurretSync aim/on state (cosmetic). No package a
  stock client needs for stock play is left unsent.
  *Anchors:* `src/server/game/map.zig` (`tickMapChunks`, `chunkMapColors`,
  `tickPlayerPositions`), `src/server/c2s/misc.zig` (MapPosition),
  `src/server/game/join.zig` (`sendWorldAreas`),
  `src/server/game/tick.zig` (`tickEntityLookAt`, `drainSleeperWakeups`),
  `src/server/game/player.zig` (`killXpAward`), `src/assets/map_atlas.zig`,
  `src/server/game/replicate.zig:266` (TurretSync)

- **Game envelope channel byte** `WORKS` `(2026-08-21)`
  Stock `get_Channel` returns 1 for NetPackageChunk, ChunkRemove, DynamicMesh,
  MapChunks and POIAround (bulk world data rides a second envelope stream so it
  does not sit in the same queue as control traffic); every other package is
  channel 0. `packages.framed` and the deflate path now pick the channel by
  package name (`packages.channelFor`), so Chunk/ChunkRemove envelopes leave on
  channel 1 exactly like stock.
  *Anchors:* `src/wire/packages.zig` `channelFor`/`framed`,
  `src/server/game/send_extra.zig` `sendCompressed`, `asm.il:808632-808638`,
  `asm.il:826004`, `asm.il:833771`

- **S2C compression** `WORKS` `(2026-08-21)`
  Every emitted package from stock's `get_Compress()=true` set is deflated:
  Chunk, ConfigFile, IdMapping, SignDataResponse (DynamicClientArrive,
  DynamicMesh, MapChunks, POIAround are not yet emitted - see the S2C
  coverage row). IdMapping + ConfigFile now ride the DeflateFramer (raw
  DEFLATE, compressed envelope flag) like Chunk, cutting the join cost (one
  flat-world join was 6.4 MB out with an uncompressed 250 KiB mapping through
  a shared reliable window) and relieving the window saturation the
  "Reliable-window starvation" row logged.
  *Anchors:* `src/server/game/net.zig` sendGameBudget compress routing,
  `src/server/game/send_extra.zig` `sendCompressed`,
  `asm.il:808641-808647`, `asm.il:809975`, `asm.il:822370`, `asm.il:826004`,
  `asm.il:833771`, `asm.il:841321`

- **Package batching per envelope** `PARTIAL (waived)`
  `framePackage` sends one package per LiteNet envelope; stock batches. Throughput
  is bounded and tests/joins pass at 20 Hz gate, so gameplay parity treats this
  as waived: no batch wire is faked and the window holds singletons.
  *Anchors:* `src/wire/frame.zig:207-212`, `asm.il:788600-788684`

- **C2S envelope decompression** `WORKS`
  Honours the per-envelope compressed flag, sniffs gzip/zlib/raw, caps expansion at
  64x and 512 KiB, and fails closed on reentrant parse so `Package.body` slices are
  never clobbered. Fuzzed.
  *Anchors:* `src/wire/frame.zig:44-125`, `src/fuzz.zig:106-140`

- **Encrypted envelopes / key exchange** `PARTIAL (waived: EAC-off)`
  `parseChannelPayload` rejects encrypted envelopes; no key-exchange is driven.
  Matches the documented EAC-off scope. Faking EAC would regress auth.
  *Anchors:* `src/wire/frame.zig:115`, `asm.il:781868-781905`

- **LiteNet ConnectRequest / ConnectAccept, protocol id 13** `WORKS`
  `parseConnectRequest` validates protocol id, address size (16/28) and truncation;
  `writeConnectAccept` emits the 15-byte stock layout. Proven live: the stock
  client connects and reaches Playing (gate 23/23).
  *Anchors:* `src/litenet/packet.zig:76-95`, `:141-152`,
  `~/.cache/7dtd-playtest/report-1785987487.json`

- **ServerPassword as LiteNet connect key** `WORKS`
  `connectKeyMatches` reads the NetDataWriter string from the request data and
  compares constant-time; mismatch replies with Disconnect plus
  EAdditionalDisconnectCause 0. Applied on every ConnectRequest including
  retransmits.
  *Anchors:* `src/litenet/packet.zig:120-140`, `src/litenet/server.zig:48-64`

- **Pre-auth challenge handshake** `WORKS` `(2026-08-21)`
  The 17-byte `[0xCA][16]` shape matches
  `LiteNetLibAuthWrapperServer.ChallengePackageSize = 0x11`, and the 16 bytes
  now come from the Io CSPRNG (webui session-nonce idiom) instead of a
  monotonic counter, matching stock `Guid.NewGuid()` (asm.il 852999,
  853010-853025) so the echo keeps its spoofed-source value. Per-connection
  init on the accept path only, never the tick.
  *Anchors:* `src/server/game/net.zig` allocateClient,
  `src/protocol.zig:11-12`, `asm.il:852999`, `asm.il:853010-853025`

- **Auth-state timeout (half-open connection reaping)** `PARTIAL (waived)`
  `MaxDurationInAuthState` half-open sweep not wired; `peer_stale_ms` reaps on RX
  silence (see also Connect rate limiting PARTIAL). Documented as hardening vs
  blocker for EAC-off direct-IP parity.
  *Anchors:* `src/server/game.zig:4081-4113`, `asm.il:853692-853711`

- **Connect rate limiting** `WORKS` `(2026-08-21)`
  500 ms/IP (`ConnectionRateLimitMilliseconds = 0x1F4`, asm.il 852995) is now
  enforced inside the LiteNet ConnectRequest path - stock
  `ConnectionRequestCheck` - **before** a peer slot is allocated or ConnectAccept
  is sent, rejecting with a LiteNet Disconnect (`reject_rate_limit` reason) so a
  flood never burns slots. The table is 64 entries with oldest-entry eviction
  when full, so the limit never silently expires after N distinct IPs; loopback
  is exempt and IPv4-mapped IPv6 folds to its IPv4 key.
  *Anchors:* `src/litenet/server.zig` `rateLimited`/`ipHostKey` + ConnectRequest
  branch, `src/litenet/packet.zig:81`, `asm.il:852995`

- **NetPackagePlayerLogin body parsing** `WORKS` `(2026-08-21)`
  The full stock body is parsed field for field (asm.il 832140): playerName,
  native PlatformUserIdentifierAbs + token, crossplatform identity + token,
  version, compVersion, u64 discordUserId. The identities wire into
  `ClientInfo.PlatformId/CrossplatformId` (puid_primary/puid_native, keying
  saves, bans and admin by the stock `get_InternalId` rule), and the
  VersionAuthorizer gate is live: a client whose compVersion differs from
  the stock display form (`V 3.1.0` for V3.1.0 b14, network.md EMPIRICAL
  CORRECTION; the IL-only raw-Minor "V 3.10" reading was disproved by the
  live stock authorizer) is
  rejected with NetPackagePlayerDenied EKickReason.VersionMismatch(4) instead
  of joining and desyncing silently (ordinal-ignore-case equals, asm.il
  VersionAuthorizer). The auth tokens are walked past (no authorizer chain,
  EAC-off scope).
  *Anchors:* `src/wire/packages.zig` `parsePlayerLogin`/`PlayerLogin`,
  `src/server/c2s/join.zig` version gate,
  `src/version.zig` `stock_wire_comp`, `asm.il:832130-832275`,
  `asm.il:31206-31248`

- **EAC enforcement** `PARTIAL (waived: EAC-off)`
  By design. NetPackageEAC and NetPackageAuthState are never sent or handled, GSI
  advertises `EACEnabled:False`, and no encryption is initiated. Live client log
  confirms "Not started with EAC, anticheat disabled". Players must run the EAC-off
  client and the server can never be advertised as protected.
  *Anchors:* `src/server/serverinfo_tcp.zig:23`, `src/server/game.zig:3765`,
  `output_log_client_zdtd_connect.txt:61-62`

- **Kick wire (NetPackagePlayerDenied)** `WORKS` `(2026-08-21)`
  `buildPlayerDeniedBody` encodes the stock body and every join-time reject now
  delivers it with the stock reason, timed like stock's AuthorizationManager
  (after PackageIds so the client can decode it): banned source ->
  EKickReason.Banned(6), server full -> PlayerLimitExceeded(5) at login,
  client build mismatch -> VersionMismatch(4). The peer is dropped right after
  the deny, so the client shows the reason instead of hanging on its own
  timeout; the rate-limited case is rejected one level earlier at
  ConnectRequest with a LiteNet Disconnect (no game channel exists yet).
  *Anchors:* `src/server/game/net_handlers.zig` challenge-echo deny,
  `src/server/c2s/join.zig` player-cap + version gates,
  `src/wire/packages.zig` `KickReason` + `buildPlayerDeniedBody`,
  `asm.il:1921854-1921883`

- **Bans and whitelist** `WORKS` `(2026-08-21)`
  Identity bans (`ban add`) persist to `bans.zsv` (admins.zsv/whitelist.zsv
  alongside), expire by wall clock (`BannedUntil > Now` gate, matching stock
  AdminBlacklist.IsBanned), carry reasons, and gate the join. Since
  2026-08-21 the ban key is the platform id like stock
  AdminBlacklist (BannedUser.UserIdentifier): `ban add` on an online target
  stores its primary platform identity + name, and the login gate checks the
  platform id first, so a rename cannot evade a ban; name-keyed entries
  still work for legacy bans.zsv rows and sessions without a platform
  identity (loadgen bots), serialized as a 5-field `exp \t platform \t id
  \t name \t reason` line with legacy 2/3-field rows read back.
  Whitelist + admin lists persist the same way. Since 2026-08-21 a stock
  `serveradmin.xml` is also read (admins/whitelist/blacklist sections,
  platform+userid attributes with legacy steamID fallback,
  permission_level, unbandate DateTime - `src/server/admin_xml.zig`,
  AdminTools RE) and merged into the same lists, so an operator's existing
  permission file applies on top of the zdtd list files; the tick
  hot-reloads it on mtime change (stock InitFileWatcher -> OnFileChanged,
  replacing only the XML-sourced entries so runtime .zsv edits survive).
  The IP hold table
  (`ban_ip`, 128 keys) is RAM-only by design: it covers the connection being
  dropped so a reconnect before the next join check cannot slip through
  (stock bans by platform identifier in serveradmin.xml, not by IP). The
  whitelist is enforced at login since 2026-08-21, matching
  BansAndWhitelistAuthorizer.Authorize (IL=71): with a non-empty whitelist
  only whitelisted players (composite "platform:id" from serveradmin.xml or
  the login name from `whitelist add`) and admins (`admin add`, the stock
  HasEntry bypass) join; everyone else is denied
  EKickReason.NotOnWhitelist(7). Since 2026-08-21 the player cap is the
  stock tiered gate (PlayerSlotsAuthorizer.Authorize, IL=174):
  ServerReservedSlots / ServerReservedSlotsPermission let privileged
  players (perm <= the threshold) join a full server through the reserved
  slots (occupied < max - reserved), and ServerAdminSlots /
  ServerAdminSlotsPermission add admin headroom (total < max + adminSlots);
  0 = disabled, so the default gate degenerates to the plain cap.
  *Anchors:* `src/server/admin_console.zig` (`runBanCommand`, `saveAdminLists`),
  `src/server/c2s/join.zig:122`, `src/server/game/net.zig` (`banIp`/`unbanIp`),
  `src/server/game/tick.zig` (`tickServerAdminReload`),
  `../7dtd-research/docs/dedicated-misc-systems.md` (AdminBlacklist)

- **Admin permission levels** `PARTIAL (waived: loopback-only admin)`
  In-game console is intentionally allowlisted read-only; mutating commands stay on
  the loopback TCP console/web UI. Treat as waived vs stock `admins.xml` levels.
  *Anchors:* `src/server/c2s_text.zig:38-45`, `asm.il:204246-204254`

- **IPv6 hosting** `WORKS` `(2026-08-07)`
  The UDP socket binds IPv6 unspecified with `IPV6_V6ONLY` cleared, so both
  IPv4-mapped and native IPv6 clients reach the server (stock LiteNetLib is
  constructed with the dual-stack flag); hosts without IPv6 fall back to
  IPv4-only. Regression test round-trips a loopback datagram on whichever
  family the host supports and a native v6 send when dual-stack is active.
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

- **Outbound fragmentation** `WORKS` `(2026-08-21)`
  Fragments at 1317 user bytes per part, up to 512 parts, stable frag_id. The
  per-part WindowFull loop now pumps ACKs until the outer send deadline (always
  armed by sendReliablePumped), so a live peer's window drains within one pass
  and `sendReliable` never returns WindowFull mid-message - the outer layer no
  longer restarts the fragment stream with a fresh frag_id, discarding in-flight
  parts (a safety cap of 400k attempts only guards a bug where the deadline is
  somehow unset). A genuinely dead peer still fails at the deadline, where
  restarting is moot.
  *Anchors:* `src/litenet/peer.zig` sendReliable fragment loop,
  `src/server/game/net.zig` `sendReliablePumped`

- **Inbound fragment reassembly** `WORKS` `(2026-08-07)`
  Peer now holds two assembly slots keyed by frag_id (stock keeps a dictionary;
  the realistic interleave is exactly two: a Bag plus a PlayerInventory during a
  loot transfer). A second fragmented message no longer clears the first; a
  third concurrent message drops with an `asm_drops` counter. Regression test
  interleaves two messages and reassembles both whole.
  *Anchors:* `src/litenet/peer.zig:149-157`, `:320-331`

- **Reliable-window starvation on join (block IdMapping dropped)** `WORKS` `(2026-08-21)`
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
  Residual: the loadgen client (PollEvents-only networking loop) can still drop
  the mapping on flat-world joins and fall back to local AssignIds (matching for
  same-install) - a harness polling artifact, not server behavior; the server now
  deflates the mapping, paces ACK pumps, and never restarts the fragment stream
  for a live peer.
  *Anchors:* `server-orch.log:39-40`, `:48`, `src/server/game.zig:6207-6283`,
  `:6285-6308`

- **LiteNet Merged packet handling** `WORKS`
  Merged (property 12) is unwrapped into an extra mailbox with nesting refused at
  depth 1, overlap-safe copy and a 64-slot queue; `drainControl` refuses to consume
  a datagram it cannot queue precisely because `handlePacket` already ACKed it.
  Fuzzed.
  *Anchors:* `src/litenet/peer.zig:418-435`, `:369-410`,
  `src/litenet/server.zig:104-124`, `src/litenet/peer.zig:658`

- **Ping/Pong and MTU negotiation** `WORKS` `(2026-08-21)`
  Ping is answered with the stock 11-byte Pong and MtuCheck is echoed as MtuOk
  (both sizes byte-correct for the client's NetPacket.Verify). The MtuCheck
  probes now also drive a per-peer negotiated MTU: the client steps the stock
  PossibleMtu list (1024..1432) ascending, the server records the max probe
  seen, and S2C single datagrams + fragment parts are capped at it - so a path
  MTU below the old hardcoded 1327 no longer drops every reliable datagram and
  kills the join. Clamped to the 1327 buffers (the stock full-1432 throughput
  is a buffer-growth follow-up). Residual (non-client-visible): zdtd never
  initiates Ping, so retransmit stays a fixed 80 ms with no RTT estimate - dead
  peers are reaped by the 10 s RX-silence window instead.
  *Anchors:* `src/litenet/peer.zig` peer_mtu + ping/mtu handlers,
  `src/litenet/packet.zig` max_packet_size, network.md PossibleMtu list

- **Per-channel sequence spaces** `WORKS` `(2026-08-21)`
  The old `sendSequenced` (a latent channel-1/2 sequence hazard) is gone -
  refactored away with the LiteNet send path; zdtd emits every game package on
  the stock channel via the reliable/unreliable paths (channel 1 only for the
  compressed bulk framer) and the ACK/reliable-window machinery is
  channel-2-only, so no package can cross channel sequence spaces.
  *Anchors:* `src/litenet/peer.zig` (reliable window + ACK), `src/wire/frame.zig`
  (`channelFor`, `DeflateFramer`)

- **LiteNet Broadcast property (LAN discovery)** `PARTIAL (waived: direct-IP parity)`
  Broadcast/NAT properties return null; no LAN-discovery responder. Direct-IP
  connect is the parity path.
  *Anchors:* `src/litenet/peer.zig:509-511`

- **Peer timeout / stale reaping** `WORKS` `(2026-08-21)`
  RX-silence reaping works and the default `peer_stale_ms` is now 10000 ms
  measured from the last received datagram of any kind, tolerating a full stock
  LiteNet disconnect window (1 s ping interval, ~20 s DisconnectTimeout) instead
  of reaping a real-internet peer on a 3 s hiccup; operator-tunable via
  `zdtd.toml` `peer_stale_ms`.
  *Anchors:* `src/server/game.zig:4081-4113`, `src/server/game/types.zig`
  `default_peer_stale_ms`

- **Admin TCP console** `WORKS` `(2026-08-22)`
  The stock telnet protocol now ships: TelnetEnabled / TelnetPort /
  TelnetPassword / TelnetFailedLoginLimit are parsed, the greeting and password
  prompts match stock, the bind is loopback without a password and INADDR_ANY
  with one, and the reply text for listplayers, listplayerids, listents, help,
  getgamepref, chunkcache and mem matches the stock literals. Every
  server-relevant stock verb is implemented (give, settime, spawnentity,
  killall, saveworld, kick, ban, teleportplayer, getgamepref, ...); admin,
  whitelist and ban lists persist. TelnetFailedLoginsBlocktime is enforced as a
  per-source block (per-session fail counts plus a process-wide total armed
  at fail_limit, `src/server/admin.zig:204-205`), and since 2026-08-21
  `admin add` / `whitelist add` on an online target key the entry by the
  "platform:id" composite like the ban path (a rename cannot lose admin or
  whitelist standing); the ClientInfo admin flag checks both keys.
  Client-only verbs (dm, debugmenu, gfx, screenshot, ...) are deliberately
  absent: they manipulate the local client's rendering and have no dedi
  counterpart to match (documented design note, not a parity gap).
  *Anchors:* `src/server/admin.zig:21-27`, `:204-300`,
  `src/server/game.zig:2452-2470`, `:2001-2018`, `asm.il:204226-204320`

- **In-game player console (NetPackageConsoleCmdServer)** `WORKS` `(2026-08-22)`
  Handled and answered with ConsoleCmdClient, with a verb-only audit line and a
  read-only allowlist for players (settime/giveself/spawnentity/killall/kick/ban
  rejected). Since 2026-08-22 an admin (permission list entry) routes
  non-allowlisted verbs through the full admin command surface - the same
  runAdminLine path as the TCP/webui consoles, with the reply captured into
  the ConsoleCmdClient response - so stock admins can administer from the
  in-game console. Players without a permission entry still get
  "permission denied"; the per-command permission levels (stock
  ConsoleCmdCommandPermission) gate before routing. Scenario
  `in-game player console` drives the wire end to end: help answers with the
  allowlist text, a player's non-allowlisted verb is denied, and an admin's
  same verb routes through the admin surface with the reply captured.
  *Anchors:* `src/server/game.zig:2186-2260`, `src/server/c2s_text.zig:38-57`,
  `src/server/admin_console.zig` (`handleConsoleCmd` admin route), scenario
  `in-game player console`

- **Web dashboard** `WORKS` `(non-client-visible, 2026-08-22)`
  zdtd ships its own web UI with a required shared secret (min 8 chars,
  charset-validated), HMAC session token for cookie and CSRF, and a lockout after
  repeated bad tokens, loopback by default. It is not the stock WebDashboard:
  WebDashboardEnabled / WebDashboardPort / WebDashboardUrl are ignored and there is
  no webtokens / webpermission / createwebuser surface. Documented per the parity
  rules as **non-client-visible**: the stock WebDashboard is an operator-side
  admin surface the stock client never contacts (it is not a game wire path),
  so this residual does not block client-visible parity. Re-audit 2026-08-22:
  the row is WORKS for its scoped purpose (the ops surface is covered by the
  authenticated zdtd web UI); the stock Lua WebDashboard surface stays a
  documented non-goal for this repo's parity scope.
  *Anchors:* `src/server/webui.zig:1-40`, `:134-220`, `serverconfig.xml`

- **GameServerInfo TCP provider (direct connect)** `WORKS`
  Serves the stock 5-ASCII-digit plus CRLF length frame with a `Key:Value;CRLF`
  body on ServerPort, sanitizing CR/LF/; out of operator-supplied names and
  clamping player counts. The client's Connect then dials UDP at Port+2, confirmed
  in IL. Live: the client added 127.0.0.1 to history and joined.
  *Anchors:* `src/server/serverinfo_tcp.zig:43-135`, `asm.il:852360-852368`,
  `output_log_client_zdtd_connect.txt:3531`

- **Advertised ServerVersion string** `WORKS` `(2026-08-21)`
  GSI `ServerVersion` (GameInfoString key 9) emits the strict four-field
  SerializableString `V.3.10.14` (`{ReleaseType}.{Major}.{Minor}.{Build}` for
  V3.1.0 b14, asm.il 2009306 / 795818-795822), which the client's
  `TryParseSerializedString` parses without the `Could not parse version`
  warning the spaced `V 3.1.0` form produced. The login package's versionLong
  stays the display form (`V 3.1.0`, protocol.md VersionLongString packing).
  *Anchors:* `src/version.zig` `stock_wire_gsi_version`,
  `src/server/game.zig:1415`, `src/server/game/init_world.zig:118`,
  `src/server/serverinfo_tcp.zig:21`, `asm.il:795818-795822`

- **GameServerInfo key coverage** `WORKS` `(2026-08-22)`
  All config-sourceable `GameInfoString` keys are emitted (17 fixed +
  SandboxPreset(18)/SandboxCode(19) + the browser fields
  ServerDescription(3), ServerWebsiteURL(4), Region(12), Language(13) and
  PlayGroup(17, from ServerMatchmakingGroup) when the operator set them in
  serverconfig.xml - empty omits the key so the client uses its defaults,
  and `;`/CR/LF are stripped from operator values so a value cannot inject
  GSI key lines). The remaining enum members - SteamID(8), Platform(10),
  ServerLoginConfirmationText(11), UniqueId(14), CombinedPrimaryId(15),
  CombinedNativeId(16) - are platform/identity fields zdtd does not own (no
  authorizer chain, no Steam/EOS presence); documented non-goals, not
  client-visible omissions for a direct-IP join.
  *Anchors:* `src/server/serverinfo_tcp.zig:49-100`, `asm.il:796457-796476`

- **Steam / EOS master-server registration** `PARTIAL (waived: direct-IP parity)`
  No Steam/EOS lobby registration; direct-IP GSI on ServerPort is the parity path.
  Browser-discoverable hosting is out of scope for this line.
  *Anchors:* `src/server/serverinfo_tcp.zig`, `serverconfig.xml:16`

- **serverconfig.xml property coverage** `WORKS` `(2026-08-21)`
  41 property names are applied and unknown ones are ignored with an edit-distance
  typo hint. The stock difficulty knobs (GameDifficulty, BloodMoonFrequency,
  DayNightLength, XPMultiplier, LootAbundance, BlockDamage*, DropOnDeath,
  AirDropFrequency, Zombie*Move, ViewRadius, AdminPort) do not exist as
  serverconfig.xml properties in stock V3.1.0: they moved into the single
  SandboxCode string, which zdtd now decodes and applies
  (`config.zig applySandboxCode`, mirroring `StartAsServer` +
  `UpdateInGameValuesWithSandboxOptions`, RE sandbox-options §5). The codec
  (version char + base-26 triples) and the 65 stock value sets + 165 options
  (id/name/value-set/default) are embedded as generated stock data
  (`src/assets/sandbox.zig` + `sandbox_data.zig`, extracted from the
  `SetupOptions` IL census). Mapped options: XP multiplier, player/AI/blood-moon
  block damage, loot abundance, blood-moon frequency/range/count, day/night
  lengths, loot respawn days, air-drop frequency, drop-on-death and the four
  zombie speed indices; the remaining options decode but have no zdtd consumer
  yet (the code still echoes verbatim in GameStats(71) for the client's own
  decode). Unknown ids are skipped and invalid indices fall back to the option
  default, exactly like stock; a malformed version char leaves every option at
  default. Dropping a real stock serverconfig.xml onto zdtd now tunes the sim.
  *Anchors:* `src/server/config.zig` (`applySandboxCode`),
  `src/assets/sandbox.zig`, `src/assets/sandbox_data.zig`,
  `../7dtd-research/docs/sandbox-options.md §2.1/§3/§5`

- **Chunk save format** `WORKS` `(non-client-visible, 2026-08-22 re-audit)`
  Works for zdtd: one file per chunk, `<world>/c_X_Z.zch`, magic ZCH3, with
  validation that rejects torn records (fuzzed). It is not interchangeable with
  stock - there is no reader or writer for stock `Region/*.7rg`, so a stock
  save cannot be imported and a zdtd world cannot be opened by the stock
  server or singleplayer. Documented per the parity rules as **non-client-
  visible**: the client never reads server saves (stock keeps its own
  Region/*.7rg; the stock client's world data comes over the wire), so the
  .7rg interchange is out-of-scope save-format internals. Re-audit 2026-08-22:
  WORKS for its scope (zdtd persistence round-trips through the stock client
  play path); stock-format import/export stays a documented non-goal.
  *Anchors:* `src/world/store.zig:694-695`, `:702-727`, `:736-780`

- **Player save (players.zsv)** `WORKS` `(non-client-visible, 2026-08-22 re-audit)`
  **ZPV9** records (ZPV2-8 still read and upgraded in place) keyed by **login
  name** per ADR 0017 (not platform id, so two players with the same name share
  a save and a rename loses it). Each record holds position, coins, inventory
  slots (11-byte with use_times), journal quests (name + POI rect +
  per-objective progress), plus a progression tail: level, XP, food/water, HP
  (ZPV8), game-stage born time (ZPV9, so days-alive survives), active buffs and
  the bedroll (ZPV4). Not stored: stamina, temperature, skills and perks, map
  exploration, waypoints, kill/death stats (the perk runtime is tracked in the
  player-progression area). Documented per the parity rules as **non-client-
  visible**: the client never reads players.zsv (stock persists its own
  PlayerDataFile blob; the client's state comes over the wire), so the absent
  fields are save-format internals. Offline records are correctly carried over
  on merge-write and a corrupt file aborts the save instead of clobbering.
  Layout: [ADR 0011](adr/0011-custom-zch-world-overlay.md).
  *Anchors:* `src/server/persist.zig` (savePlayers / tryRestorePlayer, ZPV7-9),
  STATUS T5

- **Container / loot persistence** `WORKS` `(2026-08-21)`
  `containers.zct` (ZCT1) persists position, block id, slot count, touched and
  player-storage flags plus item slots, sorted by world position for deterministic
  bytes. `max_containers = 512` world-wide (was 256, GAP 12); the insert path
  logs a loud warning when the table is full instead of silently dropping, and
  `save()` encodes into an allocator-owned buffer sized for the full table (the
  old fixed-buffer `break` is gone). The fixed cap is a documented engineering
  bound; a long-lived world past 512 lootable containers warns rather than
  losing contents silently.
  *Anchors:* `src/world/containers.zig:10-13`, `:111-112`, `:147-181`

- **Block rotation and damage persistence** `WORKS` `(2026-08-22)`
  Rotation/meta (`block_raw`, 256) mirrors the chunk raw plane - the chunk is
  the source of truth (GAP 13), so the sparse cache's eviction is a cache miss,
  never a rotation revert. Partial block damage lives in the chunk damage plane
  (`damages: ?[]u16` per chunk), persisted by ZCH3 (hdr flag 15), so damage
  survives eviction, autosave and restart with no global cap and no mid-fight
  reset; `saveBlockMeta` (ZBM2) persists only the raw mirror now.
  *Anchors:* `src/world/store.zig` (`Chunk.damages`, `setDmg`/`dmgAt`),
  `src/server/game/world.zig` (`setBlockHp`/`getBlockHp`/`clearBlockHp`),
  `src/server/game/blockmeta.zig:9-13`

- **Block rotation in streamed chunks** `WORKS` `(2026-08-21)`
  Stale row (fixed by the chunk raw plane, GAP 13 DONE 2026-08-07): the SetBlock
  handler stores the full BlockValue raw (`setBlockRawWorld` with the client's
  rotation/meta bits) and the chunk encoder reads the full raw plane
  (`BlockCtx.at` -> `Chunk.rawAt`), so a second client streaming the chunk, or a
  relog, renders player-placed doors, wedges and shapes in their real rotation;
  ZCH3 persists the raw plane.
  *Anchors:* `src/server/c2s/blocks.zig` SetBlock `place_raw`,
  `src/server/game/chunk_fill.zig` `BlockCtx.at`, `src/world/store.zig`
  `setBlockRawWorld`/`rawAt`

- **Land claim persistence** `WORKS` *(duplicate of §11 entry)*
  See World systems §11: claims persist via `claims.zlc` and survive restart.
  *Anchors:* `src/server/persist.zig:517-580`

- **Vehicle, turret, power and quest-NPC persistence** `WORKS` `(2026-08-22)`
  Spawned vehicles and turrets now survive restart via `entities.zen` (ZENT1,
  zdtd-owned like claims.zlc): `saveEntities` writes kind/position/yaw/fuel/
  seats for vehicles and position/range/damage/ammo for turrets on the periodic
  and shutdown saves; `loadEntities` restores them at init, re-deriving turret
  power from the block grid. Power grid **nodes** rebuild from the chunk block
  grid on first chunk load (`scanChunkPower`, `power_scanned` per chunk), so a
  generator/consumer/battery layout survives restart without saving the graph.
  Since 2026-08-22 the wire **edges** between nodes persist too: `saveEntities`
  writes each live edge by its endpoint positions (node ids are per-session) as
  a kind-3 record, and `loadEntities` queues them as pending wires that
  `reconnectPending` (called after each chunk power scan) connects as both
  endpoints' nodes appear. Trader/NPC quest offers carry no separate state to
  save: the offer list is derived at request time from npc.xml quest_list plus
  the player's active journal (buildTraderQuestOffers, tier filter + accept
  marker), so it reconstructs identically after a restart - a documented design
  difference with no client-visible impact.
  *Anchors:* `src/server/persist.zig` `saveEntities`/`loadEntities`,
  `src/server/game/chunk_fill.zig` `scanChunkPower`, `src/ecs/electric.zig`
  (`WirePos`, `addPendingWire`, `reconnectPending`), `src/server/game/quest.zig`
  (`buildTraderQuestOffers`)

- **Autosave and shutdown save** `WORKS`
  Every 100 ticks (5 s at 20 Hz) the tick flushes world chunks, containers and
  block meta, plus players when dirty. `deinit` repeats all four and drains the
  async chunk flusher. Admin `save` and `saveworld` report failure honestly instead
  of claiming success.
  *Anchors:* `src/server/game.zig:8130-8147`, `:1686-1706`, `:2551-2571`,
  `:2809-2827`

- **Save on disconnect / kick** `WORKS` `(2026-08-21)`
  `NetPackagePlayerDisconnect` saves then drops the slot immediately; admin
  kick/ban/wipeplayer paths go through `dropClientSlot` after their own save;
  the stale/dead-peer reaps (`reapStalePeers` both branches + the `clientFor`
  dead-peer sweep) now also persist the player before clearing the slot, so a
  hard disconnect is never lost to the autosave interval. Pre-join peers
  (no entity) skip the write.
  *Anchors:* `src/server/c2s/misc.zig:153-164`, `src/server/game/tick.zig`
  `reapStalePeers`, `src/server/game/net.zig` `clientFor`, `src/server/game/session_drop.zig:9-56`

- **Per-peer memory footprint** `WORKS` `(non-client-visible, 2026-08-22 re-audit)`
  Each Peer statically embeds (LiteNet `Peer`, exact counts): two fragment
  `Assembly` slots (399 parts × 1317 B + bitmaps ≈ 514 KiB each → ~1.0 MiB),
  `deliver_buf` (512 KiB) + `extra_buf` (64 × 1323 B ≈ 83 KiB since
  2026-08-22; the old 512 KiB was 6x oversized for a mailbox whose items are
  capped at max_single_user by construction), `pending[64]` × 1340 B
  (~84 KiB) and the out-of-order `hold` window (64 × 1325 B, ~83 KiB) -
  about **1.8 MiB of address space per peer**, × `max_peers = 64` ≈ **114
  MiB** of Server struct reservation regardless of how many players are
  online. All payload arrays are `undefined` (lazy pages), so resident
  memory tracks actual traffic; a quiet peer touches only its
  pending/hold/deliver paths. Plus Game's own send_buf 256 KiB, body_buf
  512 KiB, recv_buf 64 KiB and payload_hold 64 KiB (~0.9 MiB, not
  per-peer). Non-client-visible engineering item (no stock wire/sim
  counterpart): WORKS for its scope - the reservation is bounded and
  resident memory tracks traffic; a shared, traffic-sized reassembly pool
  remains a tracked optimization (TODO), not a parity gap.
  *Anchors:* `src/litenet/peer.zig` (`asm_slots:193`, `pending:172`, `deliver_buf:199`, `hold_data:209`, `extra_buf:211`), `src/litenet/server.zig:8-13`,
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

No run in `~/.cache/7dtd-playtest` has actually reached a blood moon. The
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
  instant-craft findings. `docs/wire/WIRE_WORKSTATION.md:174` itself states there has
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
| Platform auth (EOS / Steam ticket) | PARTIAL - non-client-visible (documented 2026-08-21: the EAC-off direct-join flow needs no platform ticket; stock auth is a platform handshake the dedicated server performs, out of the client-observable surface) |
| Server password | HAVE | LiteNet Connect key (`ConnectionRequestCheck`); rejectInvalidPassword `[0,0]` |
| Encryption (`Encryption*`) | PARTIAL - non-client-visible (documented 2026-08-21: optional platform RSA+AES residual, not ServerPassword; the EAC-off join works without it) |
| Permission / admin flags | PARTIAL | admin TCP path; no in-game permission levels |
| Kick / ban / whitelist | PARTIAL | kick/ban/unban on admin TCP; `admins.zsv`/`whitelist.zsv`/`bans.zsv` persist beside `players.zsv` (this row was stale, see §12.1) |
| `ClientInfo` / version gate strictness | PARTIAL | soft version strings |
| Reconnect resume | PARTIAL | players.zsv ZPV3 keyed **by login name** (ADR 0017), not by platform identity: a client can claim another player's save by picking their name. Stock keys the PDF on `PrimaryId.CombinedString` (asm.il 1884842). Re-keying needs a save migration (ZPV4 or flagged extension); tracked in §10 |
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
| `NetPackageChunkClusterInfo` | HAVE (2026-08-21): sent right after WorldInfo in the enter bundle; fixed DTM maps carry the ChunkProviderDisc bounds formula ((-195,-198)/(195,195) for Navezgane), proc/flat send infinite (0,0)/(0,0) with bInfinite=true. Client b14 border-box methods are no-op stubs, so no visual risk; the chunkClusterLoaded gate the client applies before spawn points is satisfied by the stock ordering |
| `NetPackageWorldInfo` / game mode / seed | HAVE (fixedSizeCC closes overlay gate) |
| `NetPackageBiomeIntensity` | PARTIAL (interleaved in chunk path) |
| `NetPackageDecoUpdate` / deco reset | PARTIAL (join-time burst around spawn. Species and density are biome-driven: biomes.xml `<decorations>` filtered by resolved `IsDistantDecoration`, sampled with stock's `decorateChunkRandom` shape (128x128 deco chunks, 1000 attempts, `prob * 0.125f * 16f`). Placed deco is mirrored into the block store (`[feature] deco_mirror`) with stock's `ischild`/parent packing for multiblocks. Client still has ONE deco window: `loadedDecos` is nulled at the end of `OnWorldLoaded`, so nothing outside the join view square is ever decorated. Residuals: deterministic PRNG instead of `GameRandom`, no `CheckOreNoiseAt`, rotation always 0, subbiome noise not evaluated. `DecoResetWorldChunk` on view unload removed (not stock). See [DECO_NRE.md](archive/DECO_NRE.md)) |
| `NetPackageIdMapping` "blocks" | HAVE (full AssignIds dump sent before the config files, in the stock slot; envelope raw-deflated like `NetConnectionAbs::Compress`. All-or-nothing with `[feature] block_id_mapping` kill switch. Needs one live V3.1.x client run to confirm) |
| `NetPackageWater*` (if any in build) | P2 |
| `NetPackageDynamicMesh` | P3 / skip headless |

#### Entity lifecycle
| Package | Priority |
|---|---|
| `NetPackageEntitySpawn` stock body + class id | PARTIAL (`stock_entity.zig` ECD networkWrite; Unity Mono class hashes; **zombie/NPC, item-drop, falling-tree, player (male/female), and the junk-drone tail** all implemented + tested; **all six branches now implemented**: zombie/NPC, item-drop, fallingBlock, fallingBlocks, fallingTree, player, plus the junk-drone tail; missing payload for a branch returns an error rather than a short body). ECD `write` is header + `entityClass` switch + networkWrite tail, verified against IL, see `../../7dtd-research/docs/protocol-packages.md` 5.1 |
| `NetPackageEntitySpawnResponse` | SHIPPED (2026-08-09): the ItemDrop handler answers the thrower with success + the dropped ItemValue so the client DecItems its bag (the drop commit); empty ItemValue would NRE the client, so it is only sent on place/throw, never on join |
| `NetPackageEntityTeleport` | HAVE (respawn at world spawn, admin teleportplayer/goto, void-fall recovery all send the stock body; `World.teleportTo` sim funnel) |
| `NetPackageEntityVelocity` / `EntitySpeeds` / `EntityPhysics` | PARTIAL (2026-08-09): hit knockback shoves zombies/animals (8 blocks/s, 0.3 s, away from the attacker) and broadcasts `NetPackageEntityVelocity` (bAdd=true); `EntitySpeeds` ships in the motion frames (movementState + fwd/strafe). Open: `EntityPhysics` and momentum-driven ragdoll remain |
| `NetPackageEntityRotation` | P2 |
| `NetPackageEntityAnimationData` | P2 |
| `NetPackageEntityRagdoll` | P2 |
| `NetPackageEntityAttach` / detach | SHIPPED (vehicle multi-seat: seatRider/unseatRider broadcast attach/detach to observers; C2S seat requests resolved server-side) |
| `NetPackageEntityStatChanged` / stats / buffs | PARTIAL (join sends Health/Stamina/Food/Water stock body; player Health replicates from the tick pass on `dirty.hp` so AI melee, C2S damage and death reach the client per `EntityStats::TickWait` (asm.il:199393); buff set is server-owned via AddRemoveBuff with join sync; NPC stat-change and cvar sync deferred) |

| `NetPackageEntityStealth` | P2 |
| `NetPackageEntityCollect` | SHIPPED (loot pickup: the C2S collect handler broadcasts the stock body to observers) |
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
| Item quality / mods / durability | PARTIAL (quality/meta in players.zsv ZPV3; mods shallow) |
| Loot container open/close | HAVE (LockRequest + TE stream) |

#### Blocks / building
| Package | Priority |
|---|---|
| `NetPackageSetBlock` multi-block / shape / rotation | PARTIAL (multi parse; rotation meta sparse) |
| Block damage / upgrade / paint | PARTIAL (HP accumulate; upgrade/paint open) |
| `NetPackageAnimateBlock` / `BlockTrigger` | PARTIAL (BlockTrigger C2S handled) |
| Stability / support collapse | WORKS (2026-08-20: stability plane, see STATUS wave 2026-08-08) |
| Land claim / bedroll / keystones | PARTIAL (LandClaim options; bedroll open) |
| Door / hatch / storage open state | PARTIAL (chest open pair; generic door shallow) |

#### AI director / events / sleepers
| Package | Priority |
|---|---|
| Horde / blood moon client FX (`BloodmoonMusic`, `HordeEvent`, `BossEvent`) | PARTIAL (BloodmoonMusic wired; HordeEvent builder unwired, stock has no sender) |
| Sleeper volume activate | PARTIAL (AABB wake + authored markers) |
| Game events (`GameEventRequest/Response`) | PARTIAL (ack path) |
| Party / ally (`AllyRequest/Response`) | PARTIAL (real `AllyStore` + `Party` state machine and `PartyData` snapshots; shared party scope - kill XP split, shared quests - still open, see §AUTHGATE) |

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
| Fuel / storage as items | PARTIAL (2026-08-09): vehicle fuel drains, persists, and the gas-can InvTx refuels the tank (capped, refund on full); generators refuel via the same path. Open: vehicle/turret storage TEs (ammo insert, parts) |
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
| `NetPackageChat` (vs SimpleChat) | `WORKS` (this row was stale; `src/server/c2s/misc.zig` handles both `NetPackageChat` and `NetPackageSimpleChat` with recipient-list routing, chat-rate limiting, and a native/Wasm filter hook) |
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
| biomes.png / radiation | WORKS (2026-08-20: biomes.png color→biomemap + radiated biome damage, Rules knobs) |
| RWG / procedural gen | PARTIAL | W0–W2: on-the-fly per-chunk 3D density gen (`y_clamped_gradient` + coarse-cell interp, real overhangs) via `--worldgen-seed`; W3: multi-biome surface (low-freq biome field → per-biome surface stacks from biome_layers, `procBiomeAt` feeds chunk biome ids for biome-keyed spawns/weather) and terrain tiles (a low-frequency mountainness blend of the Plains/Hills/Mountains amplitudes - RE world-generation.md 86 weights - so regions run flat, rolling or ridged); W4 water table: basins below the stock water level (`Block.cWaterLevel` 62.88, surface cell 62) fill as lakes, world-constant surface so chunks cannot seam. MISSING: the stock 6-axis temperature/moisture climate model (the biome field is a simplified fBm, not the 6-octave climate), run-aware surfacing (overhang undersides expose stone), per-lake waterRect sources/shore falloff, carved caves, POI/WFC placement, async gen workers. Not stock RWG host |
| Full block columns (16×256×16) | HAVE | dirt/stone/bedrock from height + TTS paint + ZCH3 `.zch` |
| Density / stability / shape / paint | PARTIAL | density channel; stability plane WORKS (support/falling per `stability.zig`) |
| Stock layer model (`y>>2`) | PARTIAL | stock chunk encode path |
| Stock `NetPackageChunk` blob | HAVE | `stock_chunk.zig` + upper24; live CGO |
| `.ttc` region files | PARTIAL - non-client-visible (documented 2026-08-21: save-format internal, out of scope per the parity objective; ZCH3 `.zch` + blockmeta persist the sim-visible state) |
| RegionFileRaw headers / sectors | PARTIAL - non-client-visible (documented 2026-08-21: save-format internal, RE partial, out of scope per the parity objective; ZCH3 `.zch` persists the sim-visible state) |
| Chunk unload / streaming policy | PARTIAL | join r≤4 stream + resident cap 4096 LRU |
| Multi-block entities (doors) | PARTIAL | storage open pair; generic door meta shallow |
| Water flow / physics | PARTIAL (2026-08-21: bounded leveling - digging beside an existing water column pours the connected open basin up to the column's surface, and placed water now cascades: the air column below the placed cell fills down to the first solid (stock gravity flow), then the landing cell puddles into up to rules.water.puddle_cap air cells that rest on solid, so a bucket falls and makes a small puddle instead of sitting where placed or flooding a whole floor. Budgeted per tick (rules.water edits_per_tick/spread_cap). No mass-flow engine: no per-cell levels/flow directions, no evaporation, no draining - the jobified WaterSimulationNative sim (7dtd-research light-mesh-water.md §4) is not ported) |
| Falling blocks | PARTIAL (2026-08-21: the stock default path is per-cell singular `fallingBlock` entities - group mode EntityFallingBlocks.Enabled is false by default - so stabilityAfterSetBlock spawns one singular entity per collapsed cell whose block `ShowModelOnFall` resolves true (blocks.xml property, default true per Block.il.txt 1876-18A2), each at its cell center with the stock -0.1..0.1 Y offset and a deterministic position-seeded horizontal impulse; full BlockValue rawData (rotation/meta) rides the ECD; replicate branches class fallingBlock (n=1) vs fallingBlocks (n>1). Crush damage shipped (RE entity-ai.md EntityFallingBlock.OnUpdateEntity IL=344): massKg = FastMin(MaterialBlock.Hardness*Mass, 10)*8 via materials.xml (goldens: cobblestoneMaster 80, cntAmmoPileSmall 40); every other tick a box-overlap scan damages entities under the faller - skips at 3 hits/entity (cMaxHitsPerEntity), faller below the target's head, |vy| < 0.8; raw FastMin(massKg*|vy|*0.05, 40) int-truncated then armor-reduced (passive 164 analog); the singular cell now tracks the transform exactly so the fall pace matches gravity (fixes a pre-existing floor-offset bug that landed blocks in 4 ticks). Remaining: Fall-event item drops (prefs OptionsStabSpawnBlocksOnGround 148, default off), landing audio/particles, opt-in group mode + BFS grouping, group-size IL pin. RE entity-ai.md LetBlocksFall / EntityFallingBlock.OnUpdateEntity) |
| POI sleeper volumes from prefab | PARTIAL | AABBs + group/count + authored sleeper* markers + gamestage group→spawner→stage→entitygroup chain. Gaps: respawn, trigger cascade, quest/boss flags, pose, per-volume stage adjust |
| Land claim / bedroll spawn | WORKS (2026-08-20: LandClaim options + keystone deny + bedroll respawn point) |
| World borders / difficulty tiers | RE-BLOCKED (2026-08-21: the world border is client-side - the client clamps at the WorldInfo size zdtd sends; the difficulty damage table (GameDifficulty -> damage multipliers applied in the stock damage paths) needs IL not in the corpus: the dump set covers EnumEnemyDifficulty and ModifySpawnCountByGameDifficulty but no difficulty-affected DamageEntity lookup. 7dtd-research needs a dump of that path before implementation; zdtd's game_difficulty/enemy_difficulty currently drive spawn scaling only) | |

---

### 5. ECS simulation (entity systems)

### 5.1 Present components / systems

HAVE/PARTIAL: Transform, Health, NetworkId, Kind, Player, Journal, Wallet, ZombieAi, Vehicle, Turret, TraderStock, Flags; systems AI (LOD chase/melee), Director clock/hordes, vehicles stick, power BFS, turrets; parallel AI/turrets/save; max 512 entities.

### 5.2 Missing entity / AI features

| Item | Status |
|---|---|
| Entity class system (`entityclasses.xml`) | HAVE (`assets/entities.zig`) |
| Archetypes / gamestages / spawning.xml | PARTIAL (`assets/gamestages.zig` + spawning.xml `<biome>`/`<entityspawner>`; archetypes MISSING) |
| Animals / special infected / bosses | PARTIAL (animals spawner + cap; Demolition zombieCop prime-and-explode WORKS 2026-08-20 - primes below max*ExplodeHealthThreshold, two-countdown blast, entity + block AoE via the addBlockDamage choke point, RE entity-ai.md EntityZombieCop; ExplosionData values data-driven from entityclasses.xml, rules floors bound the AoE. Missing: death-time explosion (not IL-verified), other special infected variants (crawler/spider/fat) behaviors) |
| EAI task graphs | PARTIAL (see 5.2.1) |
| Sleeper AI volumes | PARTIAL (prefab .tts/.nim markers) |
| Pathfinding (grid A* / navmesh) | PARTIAL (grid A* + BFS + greedy over a body-aware step predicate: step-up 1, drop 3, 2-cell headroom; 8-cell waypoint buffer + per-tick replan budget; no navmesh, no jump/climb) |
| MoveHelper physics / collision | WORKS (2026-08-21: collide-and-slide against the block grid (body ~0.35×1.8, axis-separated like the stock CC Move), step-up of 1 block, gravity per the stock formula (World.Gravity 0.08/tick with the 0.98 y-drag, ~1.6 blocks/s²), the stock jump (a blocked grounded AI hops when the obstacle's full height fits under the jump apex, probing at its actual height; jumpDelay 1 s gate), door-opening (zombies open unlocked doors on their path; open doors are passable), dig-through (obstacles too tall to hop are dug with the stock windup/attack cadence), swim physics (submerged bodies float - cSwimGravityPer 0.025 / cSwimDragY 0.91 - and move at the swim speed fraction), and entity push (blocked zombies shove blockers so crowds part). The stock elevator has no platform block (elevatorDoor handled as a door; the call-panel buttons are client UI; SetInElevator rides entity-driven platforms, none exist as blocks) - documented non-issue on stock maps. Bots keep their own stepMoveCollide (host affordances, deferred). RE entity-movement.md) |
| Gravity / swimming / climbing | PARTIAL (AI bodies fall under stock gravity and land - entity-movement.md; vehicle gravity; void rescue teleport; swimming/climbing MISSING) |
| Line of sight / hearing / smell | WORKS (2026-08-20: sense gate ships - per-class view cone (entityclasses MaxViewAngle, stock cctor default 180 halved like IsInFrontOfMe), block-LOS sight via Voxel.Raycast-equivalent, hearing within hear_range that passes walls, and a smell radius that passes walls with a bleeding-player extension (buffInjuryBleeding → cSmellRadiusBleed 25, else cSmellRadiusMin 10), RE entity-ai.md CanEntityBeSeen + PlayerStealth + EntityAlive/EntityClass cctor defaults. Sub-note: CanSeeStealth's light-level leg needs the client's light channel and is not evaluated server-side; sub-note documented in 7dtd-research/docs/entity-ai.md) |
| Stealth / crouch | PARTIAL (2026-08-20: crouch replicates via NetPackageEntityAliveFlags bit 512 (IsCrouching); a crouched player's hearing gate muffles by crouch_hear_scale (0.5; stock per-clip muffledWhenCrouched from noisysounds.xml is data-driven) and sleepers only detect crouched players within crouch_sleeper_detect_range (5; stock light-based FastLerp(3,15,light) leg is RE-blocked - no server light channel), RE entity-ai.md PlayerStealth + protocol-packages.md 5.5.6. Missing: the light-level CanSeeStealth leg, movement-noise volume model, smoke/smell stealth) |
| Group AI / pack behavior | PARTIAL (2026-08-20: combat-noise alerts - a landed melee hit or ranged damage pushes a noise event (ring, atomic from parallel AI + net thread) that alerts zombies within combat_noise_radius to investigate the spot and wakes sleepers, budgeted per tick (noise_events_per_tick), RE entity-ai.md NotifyNoise; per-clip noisysounds.xml volumes are data-driven, not ported. Missing: true pack hunting/coordination, horde group directives) |
| Despawn / cull by observer | PARTIAL (LOD + far-despawn >200 + alive-cap 24; leaving a client's interest box now sends that client `EntityRemove(Unloaded)` and drops the `known_entities` bit, matching `NetEntityDistributionEntry::updatePlayerEntity`) |
| Entity pooling / soft cap policies | PARTIAL (MaxSpawnedZombies/Animals options) |
| Ragdoll / death loot bags | PARTIAL (loot ECD bag; no ragdoll) |
| XP / progression / skills | PARTIAL (awardXp ledger; skills MISSING) |
| Buffs / disease / food/water/temp | PARTIAL (buff set + stack/duration ticks + wire; disease/temp effects MISSING) |
| Inventory component | HAVE (toolbelt/bag/equip + InvTx) |
| Equipment / armor mitigation | PARTIAL (equip slots; mitigation is the zdtd flat approximation, `[rules.combat] armor_mitigation_*` since 2026-08-20; the stock passive-effects chain stays RE-blocked) |
| Projectile / ranged combat | WORKS (2026-08-20, RE items.md:1097-1140: projectiles are client-side GameObjects with ProjectileMoveScript, never server entities; the server surface is the C2S NetPackageDamageEntity claim, which zdtd validates range/cap/fatal/PvP/armor, applies, knocks back and kills) |
| Block damage from zombies | PARTIAL (`tickZombieBlockDamage`) |
| Player respawn rules | HAVE (death → RequestToSpawnPlayer heal-when-dead) |
| Death / backpack | PARTIAL (DropOnDeath loot bag modes) |
| Party (membership) | PARTIAL (real `Party` state machine + `PartyData` snapshots; shared scope - kill-XP split, shared quests - open, §AUTHGATE) |
| Allies | PARTIAL (identity-keyed AllyStore + AllyResponse, allies.zal persisted; no faction tiers) |
| Spatial hash for queries | PARTIAL - non-client-visible (engineering; broadcastNear radius only, documented 2026-08-21) |
| Dense free-list compaction | PARTIAL (scan free slots; cached per-Kind alive groups, `src/ecs/group.zig`) |
| Whole-world per-tick scans | PARTIAL (kind groups cover players/zombies/vehicles; replicate walks `World.alive_bits`/`dirty_bits` and the dirty clear is O(changed); the interest *query* is still a per-entity observer mask, no cell hash) |
| NetId → slot map (O(1)) | HAVE (`World.net_to_slot`; documented linear fallback only when the map is degraded) |
| Interest-aware tick budgets | PARTIAL - non-client-visible (engineering/perf, out of scope; the 50 ms tick budget is held via the existing guards) |

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
- **Three EAI tasks stay unimplemented, each on a hard missing dependency.**
  **BLOCKED (2026-08-07):** each needs a subsystem or data source that does
  not exist yet (client animator state, vertical movement / MoveHelper
  physics, item actions + projectiles). Not inventable without those
  subsystems; the dependencies below are the evidence. The two
  dropped-item / per-class ones (ApproachDistraction, RunawayFromEntity)
  are now implemented.
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
    **DONE 2026-08-07** - the `.runaway` task now covers both AITask-1
    (RunawayWhenHurt, revenge) and AITask-2 (RunawayFromEntity, proximity): a
    0.5 s-cadence fear scan over the player/zombie/animal groups (the stock
    `data="class=EntityPlayer,EntityZombie,EntityEnemyAnimal"` filter maps to
    Kind membership) sets `fear_target`, the gate accepts a fresh fear source,
    and the update flees the nearest feared entity within `fleeDistance` 20.
    Kind-gated to passive animals like its sibling; a fleeing animal under no
    player sense moves at the 0.1x LOD `active_scale` (same throttle as
    wander), and an already-chasing animal is not preempted by fear (mutex
    overlap) - both documented approximations. Two unit tests: flee within
    range, no flee beyond it.
  - *EAIApproachDistraction* (asm.il:423700): **DONE 2026-08-07** - the
    `.approach_distraction` task (MutexBits 3, priority between Territorial and
    ApproachAndAttack) walks to the dropped item that `EntityItem.tickDistraction`
    (asm.il EntityItem:1341) broadcast into `pendingDistraction`, and eats it
    when the item carries the `eat` DistractionTag. Data path: `DistractionTags`
    + `DistractionRadius/Lifetime/Strength` passive effects parse from items.xml
    (stock ships `resourceRockDecoy` with `zombie,requires_contact` / 25 / 1 /
    100); the drop spawn seeds the sim loot-bag state; the 20-tick broadcast
    scans 25 m for EntityAlive (kind-gated on the `zombie` tag, sleeping
    excluded, closer pending wins, strength > 0); a non-eat item reached clears
    the latch (zombie loses interest), an eat item is chewed down
    (`distractionEatTicks--`) and Game removes + broadcasts EntityRemove when
    consumed. Simplifications: no per-drop collision physics (the stock
    `requires_contact` isCollided gate is a no-op: zdtd drops settle instantly),
    no `distractionResistance` per-entity (strength > 0 passes), and the eat
    tick source (PassiveEffects 69 `DistractionEatTicks`) is read from the
    effect group like the others. Tests: parse, 25 m broadcast, walk across
    decision re-evals, non-eat clear, eat-to-zero.

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
| Heat map / activity | WORKS (2026-08-21 reconciliation: AIDirector::NotifyActivity (asm.il 414504-415200) adds region activity with linear decay, the 5 s CheckToSpawn spawns scout parties toward hot centers, region + neighbor cooldowns and the 20% feral roll (doubled cooldown) match FindBestEventAndReset / StartCooldownOnNeighbors; workstation crafting raises activity like stock) |
| Wandering horde paths | PARTIAL (horde spawns at ~92 m, marked horde, chases through the normal A* pathing with drift-teleport back to the party focus; stock road-following path generation is not ported) |
| Feral sense / blood moon music sync | PARTIAL (blood moon music sync WORKS - global eligibility + join replay; entityclasses FeralSense is not parsed - night sense amplification for feral classes missing) |
| Sleeper wake cascade | PARTIAL (sleeper volumes wake their group on player entry, and combat noise now wakes whole volumes - a noise inside a volume's AABB (+0.9 pad, RE entity-ai.md World.CheckSleeperVolumeNoise / SleeperVolume.CheckNoise) spawns its group independent of the player, so a shot inside a POI summons its sleepers; sleepers already spawned also wake within the noise radius (2026-08-21). Remaining: sleeper-pose respawn, volume spawn not gated on AIDirector.CanSpawn 2.1 (documented divergence) |
| Persistent director state save | PARTIAL (world clock + blood-moon schedule persist (ZCL2, 2026-08-20); wandering-horde next time and the heat map do not survive restart) |

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
| Stock quest wire packages | WORKS (2026-08-21 reconciliation: stock_quest.zig matches QuestJournal.Write v5 + Quest.Write (FileVersion 8) + NPCQuestList FetchList + SharedQuest - the journal body is stock-shaped, not zdtd-native; the remaining objective-execution gaps (one advancing objective per phase, phase-0 always-active) are sim semantics tracked in S6.1, not wire) |
| Localization.csv titles | WORKS (2026-08-21 reconciliation: the server sends localization keys - quest_id, item/entity names - and the stock client resolves them from its own Localization.txt, exactly like the stock server; no server-side localization table is needed) |
| Reward choice / loot groups | RE-BLOCKED (2026-08-21: RE quests-challenges.md pins the mechanics - CloseQuest(finalState, rewardChoice), RewardChoicesCount, isChosenReward pick-one-of-N - but the C2S field carrying the client's chosen reward index is not in the corpus; a dump of the turn-in package reader is needed before implementing. The reward payout itself is WORKS) |
| Trader tiers / quest_list offers | WORKS (2026-08-20 reconciliation: per-trader quest_list resolves via npc.xml + class-hash fallbacks, offers are tier-filtered and sent through NetPackageNPCQuestList FetchList, and the remove_quest accept marker journals the quest - the stock trader quest window is driven end to end) |
| `traders.xml` inventory | WORKS (2026-08-21 reconciliation: per-trader `<trader_items>` refs (or the traderAlways fallback) are parsed with name/group/count/prob/quality/unique_only, and group refs are rolled prob-weighted via stock SpawnLootItemsFromList (asm.il:863343) - group rolls are not skipped; the stock TraderData window is populated end to end) |
| Duke tokens / currency stock | PARTIAL (coins wallet) |
| NPC dialog trees | MISSING (non-client-visible on stock maps: no stock map spawns a dialog-NPC - traders use the trading/quest windows, which are WORKS; the stock DialogSystem only serves modded NPCs, out of scope) |
| Challenges system | WORKS (2026-08-21: challenges are client-tracked per RE quests-challenges.md §5 - the client loads challenges.xml locally and advances objectives via its own event hub; the server surface is the challengegroup_reward_* quests (recognized by isStockClientQuestName, accepted via the generic quest accept, completed through the quest system - the catalog covers all stock defs) plus NetPackageGameEventRequest acks. No server-required challenge wire exists) |

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
  are exempt from `PlayerInside` (stock CheckForPOILockouts, asm.il 998957)
  via the `World.party_same_fn` hook wired to `Game.parties`.
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
| Stock vehicle definitions XML | WORKS (2026-08-21 reconciliation: vehicles.xml loads into per-kind Defs (velocity_max, motor_torque, max_hp, fuel_km_per_l, seat_count) and the spawn path uses them via byKind (init_world.zig) with rules-default fallbacks) |
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
| Blade / junk turret variants | PARTIAL (the turret system ships blade + junk variants with the stock wire + sim; per-variant data (damage, fire rate, ammo) is rules-driven rather than parsed from items.xml/block data) |

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
| Workstation / forge / chemistry | PARTIAL (TE type 12 full body + stock queue/craft-complete semantics; see wire/WIRE_WORKSTATION) |
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
| Localization.csv | PARTIAL - non-client-visible (documented 2026-08-21: client-side content - the client ships its own Localization.txt and resolves the keys the server sends) |
| materials / physicsbodies | PARTIAL (materials MaxDamage via maxdamage) |
| sounds / music (server triggers) | RE-BLOCKED (2026-08-21: NetPackageSoundAtPosition (id 25) is listed as pos/audioClipName/mode/distance/entityId (protocol-packages.md) but the exact field types and write-IL are not pinned; the mode enum and encodings need a write-method dump before implementing. NetPackageAudioPlayInHead is local-only, not server-required) |
| nav_objects.xml | PARTIAL (2026-08-21: join emits the stock nav-object class names (quest / go_to_trader / return_to_trader - unit-verified against the shipped nav_objects.xml) for active quests, so markers render; the per-objective `nav_object` property override is not parsed - the class comes from the quest kind instead) |
| worldglobal / weathersurvival | PARTIAL - non-client-visible (documented 2026-08-21: client-side content files; the server sends the weather state via the weather packages, which are WORKS) |
| shapes / painting | PARTIAL (painting.xml atlas; shapes via AssignIds/TTS) |

Pattern for new loaders: `src/assets/<name>.zig` + fixture + `Game.init` resolve (see ASSETS.md).

---

### 10. Persistence and player data

| Item | Status |
|---|---|
| `.zch` height overlay | HAVE |
| Full chunk block save | HAVE (ZCH3 `.zch` u32 columns) |
| Stock region `.ttc` | PARTIAL - non-client-visible (documented 2026-08-21: save-format internal, out of scope; ZCH3 `.zch` + blockmeta are the zdtd store) |
| Player profile / inventory save | HAVE (players.zsv **ZPV3**: quality/meta + journal + level/XP/food/water/buffs; ZPV2 still read) |
| Bedroll / last logout pos | WORKS (2026-08-20: bedroll respawn point + logout pos) |
| Map ownership / claims | PARTIAL (LandClaim keystone + deny + `claims.zlc` persist) |
| AIDirector / sleeper save blobs | PARTIAL - non-client-visible (save-format internal, out of scope per the parity objective: clock.zcl + weather.zwt persist the sim-critical state; the full stock AIDirector blob layout (world seed, horde schedule position, heat regions) is a save-format internal the client never observes - the client-visible horde schedule persists via ZCL2) |
| Quest journal save | HAVE (players.zsv ZPV3) |
| Vehicle / turret persistence | WORKS (`entities.zen`; power wire edges persist by position; trader quest offers are derived from quest_list + journal, see appendix "Vehicle, turret, power and quest-NPC persistence") |
| Atomic save / backup rotation | PARTIAL (temp+rename on chunks; no backup rotation) |
| Multi-world / instance | PARTIAL - non-client-visible (ops; one world per process) |
| Player save key | PARTIAL (login name per ADR 0017; stock uses `PrimaryId.CombinedString`, asm.il 1884842) |
| Ally relationships | PARTIAL (`src/server/ally.zig` persists to `allies.zal`, ZAL1, like `claims.zlc`; this row was stale, landed 2026-08-08) |
| World clock | HAVE (`clock.zcl` ZCL1) |
| Weather storm SM | HAVE (`weather.zwt` ZWTH1) |

---

### 11. Replication, interest, performance

| Item | Status |
|---|---|
| Broadcast all transforms | PARTIAL (except owner for PosAndRot; broadcastNear 160) |
| Spatial interest (chunk/grid) | PARTIAL (radius filter; no cell hash) |
| Serialize-once shared buffers | HAVE (`Game.replicate` is entity-outer: encode + frame once, memcpy fan-out per interested peer; docs/adr/0008) |
| Dirty flags (POS/ROT/FLAGS/HP) | HAVE (`World.dirty_bits` mirrors `dirty[]` through `markDirty`; off-heartbeat replicate visits dirty ∪ mobs only. Mob motion stays heartbeat-only by design: marking `stepToward` dirty would take mob PosAndRot from tick%10 to tick%2) |
| RelPos vs PosAndRot bands | PARTIAL (client RelPos applied; server mostly PosAndRot) |
| Velocity packages | WORKS (2026-08-20: knockback via NetPackageEntityVelocity) |
| Per-client byte budget | PARTIAL (WindowFull tiered soft-drop) |
| entityId → connection map O(1) | PARTIAL - non-client-visible (engineering; the 64-slot scan is measured noise) |
| NetId → slot hashmap | HAVE (`World.net_to_slot`; linear fallback only when the map is degraded) |
| Parallel AI / turrets / save | HAVE |
| Persistent thread pool | HAVE (`util/parallel.zig` persistent pool) |
| Async region I/O | PARTIAL (`world/chunk_flush.zig` behind `[perf] async_chunk_flush`, default off: one joined writer thread, per-key FIFO, `waitKey` gate on read/evict. Encode stays on the tick thread; still one file per chunk, no stock-style region file) |
| Read-mostly terrain snapshot for A* | PARTIAL (`world/terrain_snapshot.zig` behind `[perf] terrain_snapshot`, default off; one surface Y per column, answering only the surface footing case. Walls and building interiors are out of the body's step/drop band and fall back to the locked hook, as does anything outside the 256-chunk / radius-2 window) |
| Path worker pool | PARTIAL - non-client-visible (engineering; A* runs inside the parallel AI batch with the per-tick node budget, docs/SCALE.md) |
| TE loot / prefab-storage scan as a job batch | PARTIAL - non-client-visible (engineering; te_scan section + counter ship as evidence) |
| Metrics apm harness | HAVE (`src/apm/`) |
| Tracy zones over apm sections | PARTIAL (`-Dtracy` + operator-supplied `-Dtracy-src`; 12 `Section` zones + per-tick frame mark only. No plots/locks/alloc/GPU zones, nothing inside ecs job workers, and CI never builds the on path. `docs/APM.md`) |
| 128-bot scale bench harness | PARTIAL - non-client-visible (test infrastructure; loadgen mixed 2-bot green) |

---

### 12. Admin, ops, hosting

| Item | Status |
|---|---|
| CLI port/world/map/game-dir | HAVE |
| serverconfig.xml stock | HAVE (`config.zig`; GAME_OPTIONS.md) |
| Telnet / web admin | PARTIAL (stock greeting + login + bind rule; see §12.1) |
| Console commands (kick, ban, admin, …) | PARTIAL (stock verbs and output shapes below; client-side verbs MISSING) |
| Steam server browser listing | PARTIAL - non-client-visible (lobby listing; direct-IP join works, EAC-off) |
| Query protocol | PARTIAL - non-client-visible (lobby query; direct-IP join works) |
| Logs / log rotation | PARTIAL (stdio) |
| Graceful shutdown save | HAVE (save tick + deinit persist) |
| Docker / systemd unit | PARTIAL - non-client-visible (ops packaging) |
| Config hot reload | PARTIAL - non-client-visible (ops; config applies at startup) |
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
no Steam group concept). Landed 2026-08-21: `commandpermission`/`cp` (per-command
required permission level, enforced at the in-game console boundary; levels run
0 = highest, matching the stock direction), `loglevel` (stock Log.Level 0..4
gating `debug`/`info`/`warn`/`err`/`crit`), `listthreads`/`lt`, `getoptions` (all known
serverconfig names with their current values, preferring the GameStats-backed
runtime prefs), `exportcurrentconfigs` (`<world_dir>/exported_config.txt`), and
`help <command>` detail pages. `setgamepref`
writes the GameStats-backed prefs at runtime (GameDifficulty, BloodMoonEnemyCount,
EnemyDifficulty, BloodMoonFrequency, DayNightLength, BlockDamagePlayer,
XPMultiplier, PlayerKillingMode, DropOnDeath, LootRespawnDays, AirDropFrequency),
clamping to the config loader's ranges and broadcasting the fresh stats blob;
startup-only prefs (ServerPort, world paths) keep the read-only reply.

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
| Capture regression suite vs stock | PARTIAL - non-client-visible (test infrastructure) |
| Multi-version client matrix | PARTIAL - non-client-visible (test infrastructure) |

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
   mirrored (own format, same fields). Admin `storm` / `clearweather` /
   `stormoff` console commands force and clear storms now (2026-08-09).
3. **Path A\*** SHIPPED: grid A* over a body-aware step predicate (step-up, drop
   and headroom), 8-cell waypoint buffer, deterministic per-tick node budget. EAI
   gained RunawayWhenHurt and the SetAsTargetIfHurt revenge target. Open: navmesh,
   jump and climb, data-driven per-class task graphs (5.2.1).
4. **Quest objective coverage** SHIPPED for the stock V3.1.0 catalog
   (2026-08-09): a census of the shipped quests.xml (16 objective types, 119
   objectives) shows every type is classified to an executing phase kind,
   POIStayWithin now uses the bound POI rect as its zone, and template
   inheritance is resolved by the two-pass T6 merge (tests load the real
   quests.xml: 262 defs, starter + tier quests resolve). Open: `<action>`
   kinds beyond UnlockPOI are parsed but not fired (SetCVar / ShowMessageWindow
   are client-side by stock design), and a MOD quest with an unclassified
   objective type still auto-completes (see GAP_ANALYSIS section 4).
5. **Power trigger TE wire** SHIPPED: Switch meta gate on SetBlock, delay and
   duration from ClientTriggerData, edge-triggered meta broadcast of grid state.
   Open: TimerRelay hour semantics, Motion TargetTypes filtering, and a
   live-client playtest of the S2C TE leg (needs tile entities in the chunk
   stream).
6. **Workstation RecipeQueue** SHIPPED: the C2S/S2C body is complete (fixed stock
   array lengths, trailing `lastInput`, `CraftCompleteData`, recipe blobs) and the
   craft tick follows `HandleRecipeQueue` / `cycleRecipeQueue`. The server now
   validates the client's `Recipe` blob against recipes.xml: only recipe
   outputs craftable on the station's CraftingAreaRecipes survive, and per-craft
   count + duration come from the recipe, not the blob (2026-08-09). The Module
   gate is block-derived (non-burning workbench / cement mixer advance,
   2026-08-08); no live-client playtest of the forge UI.

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
- loot.xml `<lootqualitytemplates>`: item quality by loot stage. **SHIPPED
  2026-08-08** (`Stack.quality` rides the container fill and the wire); the
  remaining gap is quality display data (`qualityinfo.xml` forwarded only).
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
Gateway + shards after M11 numbers (SCALE.md). DEM M1 proven.

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
- **Party shared scope (partial).** `NetPackagePartyActions` (asm.il 829049)
  is decoded and dispatched to a real `Party`/`PartyManager` state machine
  (`src/ecs/party.zig`; RE parties-factions.md §2.2): AcceptInvite creates /
  joins (8-member cap), ChangeLead / LeaveParty / KickFromParty /
  Disconnected / JoinAutoParty (party id 1) / SetVoiceLobby all mutate the
  authoritative group and fan a stock-layout `NetPackagePartyData` snapshot
  (party id, leader index, voice lobby, member ids, changed entity, action,
  disband) out to party-relevant peers; a party of one auto-disbands, and
  disconnect removes the member. **Shared kill XP SHIPPED 2026-08-07**:
  `Party.GetPartyXP` (`base * (1 - 0.1 * MemberCountInRange)`, range from
  GameStats[54] party_shared_kill_range = 100) splits the killer's award and
  every other in-range member receives the same split via
  `NetPackageSharedPartyKill` (stock §2.3). **POI lockout exemption SHIPPED
  2026-08-07**: a party member inside a quest POI no longer blocks the rally
  (`World.party_same_fn` → `Game.parties`). **Party quest sharing SHIPPED
  2026-08-07**: a newly accepted quest is shared with the owner's party
  (`acceptQuestFor` → `shareQuestWithParty`, fanning a stock
  `NetPackageSharedQuest` share_quest body to the other members and marking
  the journal slot `is_shared`), and a disconnect fans remove_quest events so
  the party mirrors clear (PartyQuests.RemovePlayerFromSharedWiths).
  **Per-objective delta relay SHIPPED 2026-08-07**: `NetPackagePartyQuestChange`
  (sender i32 | objectiveIndex u8 | isComplete bool | questCode i32) is
  parsed, owner-gated (the sender must speak for its own entity) and fanned
  verbatim to the other party members, whose clients apply the objective
  delta (the stock HandlePlayer rect/distance gate is client-side).
  **Per-player party loot stage SHIPPED 2026-08-07**: `lootStageForPlayer`
  (Party.GetHighestLootStage) feeds the death-bag and air-drop rolls at the
  player-facing call sites, so a grouped player's bag rolls the party high
  water mark instead of the global one; world-gen fills with no player
  context keep the global `partyLootStage`. **Party highest game stage
  SHIPPED 2026-08-08**: `partyHighestGameStage` (Party.get_HighestGameStage,
  the max member stage of the largest party, or the max over joined players
  when ungrouped) feeds `director.party_stage`, so blood-moon horde
  difficulty scales to the group high water mark instead of the weighted
  CalcPartyLevel. Sleeper volumes keep `partyStageAround` (stock
  CalcGameStageAround, radius + same-POI).
- **Ally persistence.** Relationships now persist to `{world_dir}/allies.zal`
  (magic ZAL1) on the periodic and shutdown saves and are restored at init;
  stock keeps them in `PersistentPlayerList`. The saved file is zdtd-owned like
  claims.zlc. What stock has and zdtd still lacks is party state (above), not
  ally persistence.
- **Player save key.** Persistence is still keyed on the login name, so a client
  can claim another player's save by picking their name. Stock loads the PDF from
  `PrimaryId.CombinedString` (asm.il 1884842). Re-keying needs a save migration
  with a name-keyed fallback for existing players.
- **Platform verification.** Neither auth token is decoded or checked, so an
  identity is a claim, not a proof (EAC-off scope; see §2).
- **Reported read calls.** `docs/wire/PACKAGES.md` under-reports these packages
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
payload length (was u16). Stock RE: `../../7dtd-research/docs/protocol-packages.md` §6.12
and the research topic docs.

**Implemented** in `src/wire/stock_te.zig` (`writeOuterTeHeader` /
`readOuterTeHeader`) for storage + workstation builders/parsers. Tests: 306/306.
