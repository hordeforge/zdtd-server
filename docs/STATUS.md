# Status: stock-client join and play path

**Date pin:** 2026-08-08  
**Game line:** V 3.x Mono (connected client **V3.1.0 b14**; bundled AssignIds dump byte-matches this client's runtime block ids), EAC off  
**Validation:** `make check` passes (`zig build test`, fuzz, and
`lint-architecture: clean`); `game.zig` delegates to 42 shards in
`src/server/game/*.zig` aggregated through `src/server/root.zig`, and `c2s/*`
owns all C2S domains. `GAP_ANALYSIS.md` scores 333 features: 223 `WORKS`,
72 `PARTIAL`, 38 `MISSING` (see its scorecard for the per-area breakdown).
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
**144/141/44**. Reconciliation: GameStats.BloodMoonDay re-broadcasts on any day change (the step.zig per-tick diff already covered settime jumps), so the stat-58 row went WORKS, total **145/140/44**. Then the blood-moon warning-window row went WORKS (default red clock at hour 8 on the horde night; operator SandboxCode forwarded verbatim), total **146/139/44**. Then the BloodMoonRange jitter row went WORKS (persisted CalcNextDay schedule jitters non-negative 0..range; stat 58 reads the same jittered day), total **149/136/44**. Then BloodMoonEnemyCount semantics went WORKS (the party spawner enforces the stock min(30, count*members) per-party alive cap), total **150/135/44**. Then the provenance audit ledgered the recent behavioral constants and fixed dashboard/header drift. Then the dawn-end row went WORKS (horde marks clear at dawn; a wiped party kills its horde - KillPartyZombies, 2026-08-21), total **151/135/44**. Then the spawn-placement row went WORKS (seeded per-spawn bearing jitter breaks the repeating pattern; ring radii stay the A36 rules tunable), total **152/134/44**. Then the challenges-system row went WORKS (client-tracked per RE quests-challenges.md S5; server surface is the challengegroup_reward_* quests + GameEvent acks) and the NPC-dialog row was documented as non-client-visible on stock maps, total **153/133/44**. Then the quest wire-package and localization-title rows went WORKS (the journal body is stock-shaped per stock_quest.zig - QuestJournal.Write v5/Quest.Write v8; the server sends localization keys the client resolves locally), total **155/131/44**. Then the traders.xml inventory row went WORKS (group refs are parsed and rolled prob-weighted per stock SpawnLootItemsFromList), total **156/130/44**. Then the general craft path gained the workstation/tool/material gates (craft_tool + material_based parsed; zero-ingredient mints closed; craft execution row updated, stays PARTIAL for craft_time/unlock). Then the held-tool durability wiring landed (dig + landed hits wear ItemValue.UseTimes) and the Item durability row went WORKS - the players.zsv use_times persist is a save-format internal, out of scope - total **157/129/44**. Then the Item quality tier row went WORKS (quality rides wire/TE/zsv, loot-stage + trader rolls, stack-merge, durability wired; qualityinfo is the client-config flow), total **158/128/44**. The dashboard (docs/provenance.html) is synced. Then the
stock InvTx request parse shipped: `parseStockInvTx` decodes the full
`InventoryTransaction.Read` layout (Guid-keyed, hash-validated, SetAbsolute/
SetRelative/SetAll ops with WriteArray) and `c2s/inv.zig` detects stock
transactions behind the native 11-byte body with a `c2s_stock_invtx` counter;
counts unchanged (row still PARTIAL - op application and the stock response
remain open, and Guid-key resolution is RE-blocked: `InventoryTransaction.Read`
clears the transaction on an unknown key while `CreateInventoryServer` has no
callers in the RE corpus, so the registry population path is unpinned;
candidate capture: container-open sequence vs stock dedi). Then the XP curve
numeric-parity row went WORKS (expForLevel now mirrors stock
Progression.GetExpForNextLevel bit-for-bit: double-pow Mathf.Pow cast to float,
Clamp(level+1, 0, ClampExpCostAtLevel) exponent, 2.147484e9f min then conv.i4;
level 1->2 costs 11024 like stock, not 10000), total **159/127/44**. Then the
falling-blocks row gained the stock default path: collapse now spawns one
singular `fallingBlock` entity per cell whose `ShowModelOnFall` resolves true
(blocks.xml property, default true per Block.il.txt 1876-18A2), at the cell
center with the stock -0.1..0.1 Y offset + deterministic horizontal impulse;
full rawData rides the ECD and replicate branches on n==1. Then the crush
damage leg shipped (massKg from materials.xml Hardness/Mass with stock goldens
80/40; every-other-tick box-overlap damage, 3-hit cap, head + velocity gates,
armor reduction; the singular cell now tracks the transform exactly, fixing a
pre-existing floor-offset bug that landed blocks in 4 ticks), counts unchanged
(Fall-event drops, landing audio and the opt-in group mode stay open). The
dashboard (docs/provenance.html) is synced. Then the MoveHelper jump leg
shipped (a fully blocked, grounded AI fires an impulse sized to clear
jump_height - stock StartJump heightDiff ~1.3 - and sails at the arc apex
while rising, with the 1 s jumpDelay gate; fixed a moved-tracking bug the
tests exposed where the assignment preceded the comparison, so the body
jumped every tick; the step-up and wall tests stay green), counts unchanged
(dig/swim/elevator/push/door remain). The dashboard (docs/provenance.html) is
synced. Then placed water gained a bounded cascade (a bucket now falls down
its air column to the first solid and puddles into up to puddle_cap cells
that rest on solid, instead of sitting where placed; the old leveler only
poured dig edits beside lakes), counts unchanged (mass-flow, evap and drain
stay open). The dashboard (docs/provenance.html) is synced. Then the RWG row
gained terrain tiles: a low-frequency mountainness blend (stock
Plains/Hills/Mountains 4/4/2 amplitudes, world-generation.md 86) varies the
shaping stack so regions run flat, rolling or ridged, on top of the
already-shipped multi-biome surfaces (biome field + per-biome surface stacks +
procBiomeAt chunk biome ids), counts unchanged (the stock 6-axis climate
model, carved caves and POI/WFC placement stay open). The dashboard
(docs/provenance.html) is synced. Then the MoveHelper row gained
door-opening: a zombie pressed against a door on its path opens it (SetOpen
meta bit + broadcast, RE CheckForDoorAndOpen) instead of chewing, and the AI
solid probe now treats an open door as passable (door ids detected by the
stock door-naming set), counts unchanged (dig/swim/elevator/push remain). Then
the dig-through leg shipped (a blocked grounded AI whose obstacle is too tall
to hop digs the first solid cell in its move direction with the stock 18-tick
windup/attack cadence, damage drained by the Game like the chase chew; the
jump now probes at the body actual height so hops cannot clip tall walls),
counts unchanged (swim/elevator/push remain). Then the swim physics leg
shipped (a submerged AI body floats - gravity*0.025 with the 0.91 y-drag,
stock cSwimGravityPer/cSwimDragY - and moves at the swim speed fraction,
rules.ai swim_*), counts unchanged (elevator/push remain). Then the entity push leg shipped (an entity in the move destination stops the zombie and is shoved along the push direction - RE AttackPush - so crowds part instead of overlapping), counts unchanged (elevator remains). Then the MoveHelper row went WORKS (the elevator leg is a documented non-issue: stock has no elevator platform block - the doors are handled, the call-panel buttons are client UI), total **161/125/44**. Then the C2S trader-data row went WORKS (the stock ToServer body - isEntity + id/pos + TraderData - is parsed first and CopyFrom'd, so a stock client's post-trade push reaches the server; the legacy 9-byte trade body is only a fallback), total **162/124/44**. Then
the join-time deco row went WORKS (decorations now stream with newly entered
chunks - sendDecoForStreamedChunk generates + sends each new 128-block deco
chunk once per client with tracking; the client's DecoManager.Read ADDS
post-join updates, so the world is not bald beyond spawn), total
**160/126/44**. The dashboard (docs/provenance.html) is synced. Then the
sleeper wake cascade gained the noise-triggered volume wake: a combat noise
inside a volume's AABB (+0.9 pad, RE World.CheckSleeperVolumeNoise) now spawns
its whole group independent of the player, so a shot inside a POI summons its
sleepers before entry (counts unchanged - sleeper-pose respawn remains). The
dashboard (docs/provenance.html) is synced. Then the quest-POI selection
engine went WORKS (DynamicPrefabDecorator-equivalent selector: tier pool +
50 random attempts, sleeper-volume + Test_AllSet tag match, biome filters,
lockouts, squared center distance, trader 500/1500 bands; RandomPOIGoto/
Goto/ClosestPOIGoto objective meta drives it; trader offers pre-positioned
with the real QuestLocation/QuestSize/POIName instead of the fabricated
catalog spot; rally rects bound by the selector; RE pinned in 7dtd-research
quests-challenges.md), total **194/95/44**. Then quest journal persistence
went WORKS (players.zsv ZPV5: journal entries store the quest **name** (stock
Quest.Write identity) and the accepted POI rect; restore resolves by name so
a quests.xml edit cannot reshuffle a saved quest, and the rect comes back
verbatim instead of re-resolving to the nearest prefab; ZPV2/3/4 files still
read and upgrade in place), total **195/94/44**. Then ClearSleepers went real
(kills gate to the quest's bound POI - the victim position rides the kill
event, `PhaseSpec.poi_gated` from the ClearSleepers objective type - and
completing the phase suppresses the POI's sleeper volumes in the persistent
sleepers_cleared.zsc store, so a cleared POI does not re-arm on re-trigger or
restart; closes the NetPackageQuestEvent row's open item), total
**196/93/44**. Then the phase-graph row went WORKS: quests carry a flat
per-objective list (def.objectives) and a phase advances only when ALL its
non-optional objectives complete (stock refreshQuestCompletion, asm.il
983645-983904) — the shared tier1_clear phase 3 (ClearSleepers +
POIStayWithin) and always-active phase-0 objectives are enforced,
per-objective progress rides the journal wire and the ZPV6 save, and a
ForcePhaseFinish objective can fail a quest (0 stock uses, unit-tested); the
99-def sweep over the real quests.xml completes 99/99. Total **197/92/44**.
Then the quest-action row went WORKS: SpawnGSEnemy fires on phase entry
(gamestage-scaled enemies around the player, stock SpawnQuestEntity
placement 12-24 m; count range parsed from the action's `count` property);
SetCVar/ShowMessageWindow stay recorded-unfired as stock runs them on the
owning client, and GameEvent actions have no stock quest uses. Counts
unchanged (the action row was outside the scored set).
Then the treasure-dig ambush fired: `treasure_radius_break` (each buried-
supplies radius step) rolls the quest's TreasureRadiusReduction event chance
and spawns the nested SpawnGSEnemy ambush around the player, deterministic
per (world time, quest code); the event block is parsed from quests.xml
(stock: chance 0.25, 1-3 SleeperGSList on tier1_buried_supplies), so new
event types need no code, and the spawn reuses the phase-entry gamestage
hook. The row stays PARTIAL with a RE-blocked note (the event-type-0 server
path is only pinned as party-fan + distance-15 HandlePlayer, not the ambush
dispatch). Counts unchanged (the row was outside the scored set).
Then the Net/ops MISSING admin verbs went WORKS: `getoptions` (all known
serverconfig names with current values, GameStats-backed prefs preferred),
`exportcurrentconfigs` (`<world_dir>/exported_config.txt`),
`loglevel` (stock Log.Level 0..4 gating info/warn/err), `listthreads`/`lt`,
and `commandpermission`/`cp` (per-command required level, enforced at the
in-game console boundary; levels run 0 = highest like stock). The Steam-group
verbs stay a documented hard gap. Net and ops 47/4/5 -> **52/4/0**; total
**202/92/39**. Then the blood-moon music row went WORKS: eligibility is per
player (stock EntityPlayer.bloodMoonParty) - the horde music plays only while
the player's own party's horde is alive (per-client edge on the 20-tick pass,
per-player state in the join bundle); scenario bm-music proves a far-away
party stays silent. Blood moon 18/5/3 -> **19/4/3**; total **203/91/39**.
Then the loot-container discovery row went WORKS: the store is 4096 entries
with world-container eviction (full table reuses a non-player-placed
container, regenerated deterministically from the next chunk scan; player
chests never evicted), so Navezgane's thousands of loot containers all appear
and stay lootable. Items 14/12/7 -> **15/12/6**; total **204/91/38**.
Then the wander row went WORKS: wanderUpdate now routes the same A* chase
machinery (replan + waypoints, step_fn-gated), so a wanderer detours around
obstacles instead of sliding into them (stock EAIWander paths on the
navmesh); the row's frozen-Y/wall-clipping defects were already fixed by the
collision + gravity rewrite. Test proves the wall detour. Entities 21/23/4
-> **22/22/4**; total **205/90/38**. Then the world-time day row went WORKS
(re-audit): worldTimeBits is the stock DayTimeToWorldTime
((day-1)*24000 + hours*1000) with the day-1-as-zero pinning test; no
day-off-by-one remains in the clock path. World 24/18/6 -> **25/17/6**;
total **206/89/38**.
Then the loot probability row's headline gap closed: rollGroup picks are
prob-weighted like stock (stage-resolved prob as the relative weight;
zero-prob never picked; tested at ~90/10), on top of the existing
lootstage templates + gamestage-derived stage + force_prob gates. The row
stays PARTIAL for <requirement> filtering (85 stock uses) and per-entry
abundance_type (68).
Then the timid-animals row went WORKS: `approach_attack` is gated by the
class's inherited AITask-* list (`ai_attack` parsed from entityclasses.xml;
`ApproachAndAttackTarget` is the only attack task in V3.1.0 b14), so a stag
or rabbit near a player flees or wanders instead of sprinting at it and
meleeing, while wolves/bears/boars and zombies keep hunting - the boar
proves the discriminator is the task list, not IsEnemyEntity (it overrides
that to false for safe-zone spawning but keeps its attack task). The field
rides the per-entity class copy on every spawn path; unit test + systems
test. Entities 22/22/4 -> **23/21/4**; total **207/88/38**.
Then the restock-timer row went WORKS: the refill is stock's full reroll on
the channel-1 lock (`maybeRestockTrader` = HandleFullReset, lazy on the
trader open when reset_interval elapsed, re-rolling the window so sold-out
entries drop and fresh stock appears; the tick-side refill only keeps
drained stackables alive between opens), and trader stock now **persists**
across restart (traders.zst: entries by item name, wallet, reset cadence;
restored by trader name over the fresh XML fill, unknown item names fail
closed; scenario trader-persist round-trips a traded-against window).
Traders 15/5/3 -> **16/4/3**; total **208/87/38**.
Then the quest turn-in / trader-open row went WORKS: questOnTraderOpen fires
on the stock client's open path - the NetPackageLockRequest trade-window
open (channel 1, EntityTraderLockContext) triggers it in the lock handler,
so a stock client's trader visit advances trader_interact phases and turns
in ready quests with the reward (the TraderData branch stays a fallback).
Scenario trader-quest-open drives the wire end to end: the Goto->Interact->
TurnIn starter completes on the second lock-open with coins, a fetch quest
parked at ready_turn_in on a single open. Traders 16/4/3 -> **17/3/3**;
total **209/86/38**.
Then the trader-wallet row went WORKS on re-audit: the live money pool is
complete (buy credits it, sell debits it and refuses once out, restock
regenerates toward the spawn default, and the pool survives restart via
traders.zst); the two remaining notes resolved - TraderBuyLimit has zero
uses in the V3.1.0 b14 traders.xml, and the restock timer is wired (that
row went WORKS). Traders 17/3/3 -> **18/2/3**; total **210/85/38**.
Then the C2S handler-coverage row went WORKS on re-audit: ragdolls do relay
(owner ragdolls locally, the server re-broadcasts to the other tracked
players, stock SendPacketToTrackedPlayersAndTrackedEntity), and the 16
no-handler names are all non-stock-play scope (mod API, EAC waiver, creative
editor, Twitch, headless mesh, drone cosmetics) - nothing a stock client
sends in normal play is dropped unhandled. Net 52/4/0 -> **53/3/0**; total
**211/84/38**.
Then the S2C package-emission row went WORKS on re-audit: every never-sent
name is a documented non-goal under the parity rules (skill sync tracked by
the progression area; WallVolume not loaded; Light/TreeFade/AudioPlayInHead/
WaterSimChunkUpdate cosmetic; AuthState EAC-scope authorizer UX), and turret
animation is client-driven from the TurretSync aim/on state - no package a
stock client needs for stock play is left unsent. Net 53/3/0 -> **54/2/0**;
total **212/83/38**.
Then the in-game player console row went WORKS: NetPackageConsoleCmdServer
is answered with ConsoleCmdClient, players get the read-only allowlist
(deny otherwise), and an admin (permission list entry) routes
non-allowlisted verbs through the full admin surface with the reply
captured, gated by the per-command permission levels. Scenario
in-game-player-console drives the wire: help answers, a player's kick is
denied, an admin's kick routes and replies. Net 54/2/0 -> **55/1/0**; total
**213/82/38**.
Then the web-dashboard row was documented as **non-client-visible** under
the parity rules: the stock WebDashboard is an operator-side admin surface
the stock client never contacts (not a game wire path), so its residual
(WebDashboardEnabled/Port/Url ignored, no webtokens/webpermission/
createwebuser) does not block client-visible parity and it stays PARTIAL
with the note. Net/ops is now at client-visible parity: 55 WORKS / 1
non-client-visible PARTIAL / 0 MISSING.
Then the two animal rows went WORKS: systemDespawnFar walks both mob kind
groups (wildlife beyond 200 m is released like zombies instead of holding
slots forever; sleepers and alerted mobs stay), and the EntitySpeeds/
AliveFlags replicate block covers animals too, so the client animates a
wandering animal (movement state 1) instead of sliding it with state 0.
Entities 23/21/4 -> **25/19/4**; total **215/80/38**.
Then the EAI task-coverage and target-sensing rows went WORKS on re-audit:
the task table has 9 classes (ApproachDistraction + RunawayFromEntity landed
since the row was written - a thrown distraction is chased, a timid animal
flees a wolf), and the absent classes have zero AITask uses in the V3.1.0
b14 entityclasses.xml except Leap (mountain lion pounce, cosmetic). The
sense surface is stock-faithful: per-class SightRange, MaxViewAngle cone,
block LOS, stealth-scaled hearing and smell - the old flat-48m through-walls
claims are stale; the residual target-choice refinements are documented.
Entities 25/19/4 -> **27/17/4**; total **217/78/38**.
Then the entitygroups and sleeper-resolution rows went WORKS on re-audit:
the 512-group cap is gone (the table is a flat arena slice parsing the whole
file, so all ~1890 stock groups load including the gamestage-keyed horde
lists), and the GroupGenericZombie sleeper volumes resolve through
gamestages (sleeper.zig resolves the stage spawn group before the
byName/entitygroups chain) instead of falling through to zombieBoe.
Entities 27/17/4 -> **29/15/4**; total **219/76/38**.
Then the daytime wildlife spawner row went WORKS on re-audit: the class
lookup resolves the per-player-biome wildlife group and picks real classes
(rabbits/chickens/does/boars from WildGameForest with their own A35 stats)
instead of the stag-only slot-7 scan; the stag is now only the no-group
fallback. Entities 29/15/4 -> **30/14/4**; total **220/75/38**.
Then the items.xml Extends-inheritance row went WORKS on re-audit: the
V3.1.0 b14 stock items.xml has zero Extends children whose parent declares
DamageEntity, FuelValue or the eat cvars (full-file scan of the 1413
items), so the direct reads never miss stock data - the inherited-value gap
was data-absent (Stacknumber already resolves through Extends). Items
15/12/6 -> **16/11/6**; total **221/74/38**.
Then the DropOnDeath row went WORKS: death bags carry the victim's real
inventory range by mode (1 all, 2 toolbelt, 3 backpack) at preserved
offsets instead of a placeholder unit, on both kill paths (C2S damage and
the hp-replicate AI-kill detector, coordinated through has_backpack so a
death is never bagged twice); scenario + unit test. Items 16/11/6 ->
**17/10/6**; total **222/73/38**.
Then the storage TileEntity S2C row went WORKS: the container grid rides the
wire - the lock path captures the client-observed loot.xml size (validated),
the storage TE writer emits it instead of the 2xN synthesis, and ZCT2
persists it across restarts (ZCT1 still loads). The lootListName bool stays
false as a documented internal difference (loot is rolled at creation and
respawned by touched_day; the client UI does not render the list name).
Items 17/10/6 -> **18/9/6**; total **223/72/38**.
The dashboard
(docs/provenance.html) is synced.

**Client-visible parity queue (goal: 100% surface parity), ranked by client
impact:** (2026-08-20: projectile/ranged combat verified WORKS - RE
items.md:1097-1140: projectiles are client-side GameObjects, the server
surface is the DamageEntity C2S claim, which is complete; AI senses shipped
WORKS - per-class view cone (entityclasses MaxViewAngle, stock 180 default
halved), block-LOS sight, hearing through walls, and smell with a bleeding
extension, RE entity-ai.md CanEntityBeSeen + PlayerStealth; CanSeeStealth's
light-level leg stays RE-blocked, no server light channel)

1. MoveHelper physics / collision (WORKS 2026-08-21 - collide-and-slide + step-up + stock gravity + blocked-grounded jump + door-opening + dig-through + swim physics + entity push; the stock elevator has no platform block, documented; server-side only - a human client moves itself)
2. RWG depth: climate/biomes, carved caves, POI/WFC placement (fluids/aquifers 2026-08-20; multi-biome surfaces + terrain-tile relief blend 2026-08-21 - the stock 6-axis climate model and carved caves remain)
3. Water flow / physics (PARTIAL - dig-leveling pours basins beside existing water; placed water now cascades down its column and puddles, bounded 2026-08-21; no mass-flow engine, no evap/drain)
4. Stealth / crouch (PARTIAL - crouch replicates (flags bit 512), hearing muffled 0.5x, sleeper detect 5; light-level leg RE-blocked 2026-08-20)
5. Group AI / pack behavior (PARTIAL - combat-noise alerts + sleeper wake 2026-08-20; pack hunting/horde directives RE-BLOCKED - no group-attack IL in the corpus)
6. Falling blocks (PARTIAL - per-cell singular fallingBlock entities gated on blocks.xml ShowModelOnFall + crush damage via materials.xml Hardness/Mass 2026-08-21; Fall-event item drops, landing audio and the opt-in group mode open)
7. Bosses / special infected (PARTIAL - Demolition prime-and-explode shipped 2026-08-20; spider/crawler variant behaviors thin-RE - bCanClimbVertical pinned, the climb mechanics are not)
8. World borders / difficulty tiers (RE-BLOCKED 2026-08-21 - difficulty damage table IL absent from the corpus; border is client-side)
9. Server-triggered sounds / music (RE-BLOCKED 2026-08-21 - NetPackageSoundAtPosition field types not pinned)
10. Quest reward choice / loot groups (RE-BLOCKED 2026-08-21 - the C2S chosen-reward field is not in the corpus; payout WORKS)
11. AIDirector / sleeper save blobs (PARTIAL - non-client-visible save-format internal; clock/weather persist, full AIDirector blob out of scope)
12. NPC dialog trees (non-client-visible on stock maps - no stock map spawns a dialog-NPC; traders use the trading/quest windows, WORKS; GAP_ANALYSIS 4349)
13. Localization titles (WORKS 2026-08-21 - the server sends localization keys and the stock client resolves them from its own Localization.txt)

AIDirector depth rows (2026-08-21): heat map/activity WORKS (NotifyActivity + CheckToSpawn scouts + cooldowns +
feral roll); wandering horde paths, feral sense, sleeper-pose respawn and persistent director state are PARTIAL
with documented notes in GAP_ANALYSIS 5.3 (sleeper wake cascade itself: player-entry volume wake + noise-triggered volume wake, 2026-08-21).
Vehicle definitions XML reconciled WORKS 2026-08-21 (vehicles.xml loads per-kind Defs used by the spawn path). nav_objects.xml and blade/junk turret variants documented PARTIAL (markers/turrets ship with the stock wire; the data-driven per-objective nav_object and per-variant turret tables are refinements). 2026-08-21: the remaining ops/engineering MISSING rows (Steam listing, query protocol, Docker/systemd, hot reload, multi-world, path worker pool, spatial hash, interest budgets, entityId map, TE scan job, bench harnesses, capture regression, multi-version matrix, region-file save internals) are documented non-client-visible / out of scope. **TOP REMAINING WIRE ITEM: NetPackageInventoryTransactionRequest - the stock `InventoryTransaction.Read` parse (Guid-keyed, hash-validated, InventoryOperation ops incl. SetAll WriteArray, items.md 2060-2087) now lands in `parseStockInvTx` with detection on `c2s_stock_invtx`; the transactional-inventory mapping slice (op application, ledger hash check, stock-shaped response) is next and its Guid-resolution leg is RE-blocked (no CreateInventoryServer callers in the corpus; candidate capture: container-open sequence vs stock dedi), so the mapping needs new RE evidence before it can land.**

Wrench pickup shipped 2026-08-21: the C2S NetPackagePickupBlock body (pos |
rawData | playerId | platform identity) is parsed and run through the stock
server checks (own-entity claim, registered-identity match, world-block type
match, plus zdtd reach + land-claim bounds); on success the pickup package is
echoed to the requesting player (whose client adds the item via
OnBlockPickedUp and syncs it up, exactly like stock) and the block is replaced
with PickupSource/Air (V3.1.0 b14 ships no PickupSource property, so stock
leaves Air on every pickup; a modded blocks.xml is honoured). Net and ops
23/25/5 -> 24/25/5; total 162/124/44 -> **163/124/44** (331 features).

Paint shipped 2026-08-21: the C2S NetPackageSetBlockTexture body (pos |
face | idx | playerIdThatChanged | channel) is validated (own-entity claim,
reach + claim bounds, channel 0 only - Chunk.chnTextures is a 1-element
array) and the face byte stores the BlockTextureData catalog idx raw in the
per-block textureFull plane (Chunk.SetBlockFaceTexture IL=48), seeded from
the block's default texture so unpainted faces stay; ZCH3 persists the paint.
The dedi rebroadcast (playerIdThatChanged=-1) reaches every peer but the
painter. Net and ops 24/25/5 -> 25/25/5; total 163/124/44 -> **164/124/44**
(332 features).

Reload relay shipped 2026-08-21: the C2S NetPackageItemReload body (single
i32 entityId) is entity-gated and relayed to every peer but the sender
(GameManager.ItemReloadServer IL=32, flags 192), so other players see the
reload animation; ammo counts keep riding the inventory sync. Net and ops
25/25/5 -> 26/25/5; total 164/124/44 -> **165/124/44** (333 features).

Net-and-ops trivial cluster shipped 2026-08-21 (Net and ops 26/25/5 ->
29/22/5): the pre-auth challenge is now CSPRNG-derived (stock Guid.NewGuid,
asm.il 852999; the monotonic-counter version made the echo predictable), the
default peer-stale window is 10000 ms instead of 3000 (three missed pings on
stock's 1 s interval reaped real-internet peers on a 3 s hiccup), and the
Advertised ServerVersion row was stale - the GSI text already emits the strict
`V.3.10.14` SerializableString (commit 1dfc653). Total 165/124/44 ->
**168/121/44**.

Login version gate shipped 2026-08-21 (Net and ops 29/22/5 -> 30/21/5): the
full NetPackagePlayerLogin body was already parsed (identities wired to
puid_primary/puid_native); the VersionAuthorizer gate is now live - a client
whose compVersion differs from LongStringNoBuild (raw-Minor "V 3.10" for
V3.1.0 b14, asm.il VersionAuthorizer) is rejected with
EKickReason.VersionMismatch(4) instead of joining and desyncing silently.
The loadgen harness now sends the stock LongStringNoBuild form
(7dtd-loadgen b5c3069). Total 168/121/44 -> **169/120/44**.

Kick wire + connect rate limiting shipped 2026-08-21 (Net and ops 30/21/5 ->
32/19/5): every join-time reject now delivers NetPackagePlayerDenied with the
stock reason, timed after PackageIds like stock AuthorizationManager (banned ->
Banned(6), server full -> PlayerLimitExceeded(5) at login, build mismatch ->
VersionMismatch(4)); the rate limit moved into the LiteNet ConnectRequest path
(stock ConnectionRequestCheck, reject_rate_limit Disconnect before slot
allocation) with a 64-entry table that evicts the oldest entry instead of
expiring after N distinct IPs. Total 169/120/44 -> **171/118/44**.

S2C compression shipped 2026-08-21 (Net and ops 32/19/5 -> 33/18/5):
IdMapping + ConfigFile now deflate through the DeflateFramer (raw DEFLATE,
compressed envelope flag) alongside Chunk + SignDataResponse, matching every
emitted member of stock's get_Compress()=true set; the ~250 KiB mapping no
longer rides the reliable window uncompressed (one flat-world join was 6.4 MB
out). Total 171/118/44 -> **172/117/44**.

Envelope channel byte shipped 2026-08-21 (Net and ops 33/18/5 -> 34/17/5):
packages.framed and the deflate path pick the envelope channel by package name
(packages.channelFor), so Chunk/ChunkRemove (and DynamicMesh/MapChunks/POIAround
once emitted) ride channel 1 like stock's get_Channel override set, keeping
bulk world data off the control queue. Total 172/117/44 -> **173/116/44**.

Fragment retry + window starvation shipped 2026-08-21 (Net and ops 34/17/5 ->
36/15/5): the per-part WindowFull loop now pumps ACKs until the outer send
deadline, so a live peer's reliable window drains within one pass and the
outer layer never restarts the fragment stream with a fresh frag_id (the
Reliable-window-starvation residual). Combined with the IdMapping deflate
(slice 57), the join burst no longer saturates the 64-slot window; the loadgen
drop residual is a harness polling-loop artifact, not server behavior. Total
173/116/44 -> **175/114/44**.

MTU negotiation shipped 2026-08-21 (Net and ops 36/15/5 -> 37/14/5): the
MtuCheck probes now drive a per-peer negotiated MTU (client steps the stock
PossibleMtu list ascending; the server records the max probe and caps S2C
single datagrams + fragment parts at it), so a path MTU below the old fixed
1327 no longer drops every reliable datagram and kills the join. Outbound
Ping / RTT-adaptive retransmit stays a documented non-client-visible residual
(10 s RX-silence reap covers dead peers). Total 175/114/44 -> **176/113/44**.

Block rotation in streamed chunks flipped 2026-08-21 (Net and ops 37/14/5 ->
38/13/5): the row was stale - the SetBlock handler stores the full BlockValue
raw and the chunk encoder reads the raw plane, so doors/wedges/shapes stream
and relog in their real rotation (GAP 13 DONE 2026-08-07). Total 176/113/44
-> **177/112/44**.

SandboxCode decode shipped 2026-08-21 (Net and ops 38/13/5 -> 39/12/5): the
stock difficulty knobs moved out of serverconfig.xml into the single
SandboxCode string; zdtd now decodes it (version char + base-26 triples) and
applies XP multiplier, player/AI/blood-moon block damage, loot abundance,
blood-moon frequency/range/count, day/night lengths, loot respawn, air drops,
drop-on-death and zombie speed indices from the embedded stock value sets
(65 sets + 165 options, extracted from the SetupOptions IL census into
src/assets/sandbox{,_data}.zig). Unknown ids skipped, invalid indices fall
back to defaults, malformed version char leaves defaults - all exactly like
stock; the code still echoes verbatim in GameStats(71). A real stock
serverconfig.xml now tunes the sim. Total 177/112/44 -> **178/111/44**.

Sleeper wake wire shipped 2026-08-21 (S2C emission row, stays PARTIAL): POI
sleepers now spawn with the stock IsSleeperPassive flag (client renders them
lying down) and waking - player proximity, combat noise, or damage (stock
ProcessDamageResponseLocal wakes unconditionally) - broadcasts
NetPackageSleeperWakeup from a drained ECS ring so the client plays the wake
animation. RE pin in 7dtd-research protocol-packages.md: exact bodies, the
ConditionalTriggerSleeperWakeUp / SetSleeperActive senders, and the finding
that stock never emits NetPackageSleeperPose (the pose rides EntitySpawn
flags). SleeperPassiveChange stays unsent: zdtd's sim has no
active-but-not-waking sleeper state (documented divergence).

EntityLookAt + S2C row corrections shipped 2026-08-21 (S2C emission row,
stays PARTIAL): awake zombies with a target broadcast the stock look-at
package to tracking players (per-slot last-look state, SetLookPosition
0.0016 sqr-delta gate; RE pin in protocol-packages.md). Row corrections from
the dump: EntityAddExpClient was already emitted on kills; ShowToolbeltMessage
is not a pickup notification (sole stock sender is the Homerun minigame via
ShowTooltipMP unicast); NetPackageSleeperPose is stock-dead.

Save on disconnect/kick flipped 2026-08-21 (Net and ops 39/12/5 -> 40/11/5;
total 178/111/44 -> **179/110/44**): the stale/dead-peer reaps
(reapStalePeers both branches + the clientFor dead-peer sweep) now persist
the player before clearing the slot, so a hard disconnect is never lost to
the autosave interval. The bans row was recounted: identity bans already
persist (bans.zsv), expire by wall clock and gate the join; whitelist and
admin lists persist the same way. The IP hold table stays RAM-only by design
(it covers the connection being dropped), with the remaining real gaps
documented (serveradmin.xml not read, name-keyed bans, no reserved slots).

Block-meta and container persistence flipped 2026-08-21 (Net and ops 40/11/5
-> 42/9/5; total 179/110/44 -> **181/108/44**): block rotation/meta was
already safe (the chunk raw plane is the source of truth, GAP 13; the sparse
cache eviction is a cache miss), partial block damage is now 1024 entries
(was 64) with a counter + warn-once on eviction instead of silent loss, and
saveBlockMeta writes into a buffer sized for the full tables with asserts.
Containers: max_containers 512 with a loud insert warning and an
allocator-backed save buffer (no silent 257th-chest loss; the fixed caps are
documented engineering bounds).

Map atlas data landed 2026-08-21 (S2C emission row, stays PARTIAL): the
minimap color source is the block texture-atlas metadata (uvmapping XMLs),
which lives in the operator install's meshdescriptions_assets_all.bundle as
MeshDescription.MetaData TextAssets - not Data/Config XML. RE pinned the
UnityFS v8 bundle layout + the CalcChunkColors -> Block.GetMapColor ->
GetColorForSide -> uvMapping[id].color -> ToColor5 chain (7dtd-research
docs/texture-atlas.md), and the six ta_* XMLs are extracted into
src/assets/map_atlas.zig as a comptime RGB555 color table (231 entries).
The map wire landed 2026-08-21 (S2C emission row, stays PARTIAL): blocks.xml
Mesh/Texture/MapColor are parsed into BlockDef (the mesh names map to the six
atlases; default mesh 0 = opaque), NetPackageMapPosition C2S arms a per-client
17x17 chunk window, and tickMapChunks sends NetPackageMapChunks (channel 1,
compressed, batched) with per-chunk 256 RGB555 colors from the top visible
block - MapColor property, else the atlas color, else gray; water takes
BlockLiquidv2.Color. The in-game minimap now fills in, player markers
broadcast every 6 s (PersistentPlayerPositions, stock
playerPositionsCountdownTimer cadence) and trader compounds ship on join
(WorldAreas already sent) - the map trio is complete. Falling/jumping
zombies stream their vertical velocity (NetPackageEntityVelocity, delta-gated
in the replicate fan-out) so the client renders falls instead of glides; the
C2S handler row was recounted (76 of 98 stock-sent names handled). The player
list broadcasts every 5 s (NetPackageClientInfo: entityId, ping, admin flag -
ping 0, no RTT measurement yet). Death bags mark the map: the dropped
backpack marker broadcasts on drop (DropOnDeath) and clears on collect.
Turrets stream their aim/on state to viewers (NetPackageTurretSync,
change-gated in the replicate fan-out) so placed turrets turn toward targets.
The per-channel sequence row flipped to WORKS (2026-08-21): the old
`sendSequenced` latent channel hazard is gone - refactored away; zdtd emits
no sequenced-channel packages and the ACK/reliable window is channel-2 only
(Net and ops 42/9/5 -> 43/8/5; total **182/107/44**).

ChunkClusterInfo shipped 2026-08-21 (S2C emission row, stays PARTIAL): the
enter bundle now sends NetPackageChunkClusterInfo right after WorldInfo -
the client's chunkClusterInfoCo stores Position/bounds and only then lets
setSpawnPointListCo apply the spawn list (which the death screen and the
provider spawn points depend on; without the package that coroutine spun
until disconnect). Fixed DTM maps send bInfinite=false with the
ChunkProviderDisc bounds formula ((-195,-198)/(195,195) for Navezgane,
(-259,-262)/(259,259) for Pregen08k, truncating div); proc/flat send
bInfinite=true with (0,0)/(0,0) and pos (0,0,0), matching the WorldChunkCache
ctor defaults and primary-cluster Position. The b14 client's border-box
methods are no-op stubs and no client code subscribes to the fixed-size
finished-loading delegate, so the fixed-size branch cannot wedge it. RE pin:
7dtd-research protocol-packages.md 4.4. No scorecard change (the row's
PARTIAL reflects the remaining never-sent names, all non-client-visible
or RE-gated; Net and ops stays 43/8/5, total **182/107/44**).

Waypoint invite relay shipped 2026-08-21 (C2S handler row, stays PARTIAL):
NetPackageWaypoint C2S now parses the full Waypoint v7 body (pos/icon/
AuthoredText name/ownerId platform stream/type enum) and relays per
GameManager.WaypointInviteServer: Friends mode (0) fans to the inviter's
AllyStore allies, Everyone (1) to all players, skipping the inviter, with
the waypoint re-keyed (bTracked cleared, inviterEntityId set). Local
waypoints stay client-local as in stock - only invites traverse the server.
RE pin: 7dtd-research protocol-packages.md 5.7. C2S handled names 76 -> 77
of the 98 stock client sends; Net and ops stays 43/8/5, total **182/107/44**.

GameMessage relay shipped 2026-08-21 (C2S handler row, stays PARTIAL):
NetPackageGameMessage C2S (msgType u8 + mainEntityId + secondaryEntityId)
re-broadcasts verbatim to every client per GameManager.FinishGameMessageServer
(IL=69) - death announcements (EntityAlive.OnEntityDeath with
isGameMessageOnDeath), team changes (set_TeamNumber), leaves
(DisconnectClient LeftGame) and chat-form announcements now reach all
players, including the sender whose client displays on receipt. RE pin:
7dtd-research protocol-packages.md 5.8. C2S handled names 77 -> 78 of the 98
stock client sends; Net and ops stays 43/8/5, total **182/107/44**.

SoundAtPosition relay shipped 2026-08-21 (C2S handler row, stays PARTIAL):
NetPackageSoundAtPosition C2S (pos Vector3 + clip string + mode u8 +
distance + entityId + volumeScale) re-broadcasts verbatim to every client
except the owning player per GameManager.PlaySoundAtPositionServer (IL=60,
allButAttachedToEntityId = entityId); the owner already played the sound
locally and the distance field drives the receiving client's rolloff, not
the fan-out. RE pin: 7dtd-research protocol-packages.md 5.9. C2S handled
names 78 -> 79 of the 98 stock client sends; Net and ops stays 43/8/5,
total **182/107/44**.

EntityAwardKillServer handled 2026-08-21 (C2S handler row, stays PARTIAL):
the client's kill report (killerEntityId + killedEntityId, sent from
OnEntityDeath -> AwardKill when the local player scored the kill) is a
validated no-op: zdtd credits kill objectives and XP authoritatively at the
death path (questOnZombieKilled for melee/ranged/turret/trap kills), so
applying the client echo would double-credit. RE pin: 7dtd-research
protocol-packages.md 5.10 (documents the stock SharedKillClient -> client
report -> QuestEventManager.EntityKilled credit flow). C2S handled names
79 -> 80 of the 98 stock client sends; Net and ops stays 43/8/5, total
**182/107/44**.

Platform-id-keyed bans shipped 2026-08-21 (bans row, stays PARTIAL): the
ban key is now the platform user id like stock AdminBlacklist
(BannedUser.UserIdentifier). `ban add` on an online target stores its
primary platform identity + name, and the login gate checks the platform id
first (name as a fallback key for legacy bans.zsv rows and no-platform
sessions), so a rename cannot evade a ban. bans.zsv serializes as
`exp \t platform \t id \t name \t reason` with legacy 2/3-field rows read
back. Serveradmin.xml shipped 2026-08-21: a stock `serveradmin.xml` next to
serverconfig.xml (or in --config-dir / --game-dir) is parsed at startup
(admins/whitelist/blacklist sections; platform+userid attrs with the legacy
steamID fallback, permission_level, unbandate DateTime) and merged into the
same operator lists, so an existing stock permission file applies on top of
the zdtd list files. Whitelist enforcement shipped 2026-08-21: with a
non-empty whitelist the login gate now denies everyone except whitelisted
players (composite "platform:id" or login name) and admins (the stock
HasEntry bypass), matching BansAndWhitelistAuthorizer.Authorize (IL=71)
with EKickReason.NotOnWhitelist(7); RE pin in 7dtd-research
dedicated-misc-systems.md. Admin-list keying shipped 2026-08-21 (admin TCP
row recount): `admin add` / `whitelist add` on an online target now key the
entry by the "platform:id" composite like the ban path (a rename cannot
lose admin/whitelist standing), the ClientInfo admin flag checks both the
composite and the name, and the row's stale TelnetFailedLoginsBlocktime
claim was corrected - the per-source fail-limit block was already enforced
(admin.zig:204-205). Reserved/admin slots shipped 2026-08-21 (bans row):
the player cap is the stock tiered gate (PlayerSlotsAuthorizer.Authorize
IL=174) - ServerReservedSlots/ServerReservedSlotsPermission admit
privileged players through the reserved slots (occupied < max - reserved)
and ServerAdminSlots/ServerAdminSlotsPermission add admin headroom
(total < max + adminSlots); 0 disables each tier, so the default gate is
the plain cap. RE pin: 7dtd-research dedicated-misc-systems.md.
serveradmin.xml hot-reload shipped 2026-08-21 (bans row -> WORKS): the
tick polls the file's mtime every 5 s (stock InitFileWatcher ->
OnFileChanged) and re-applies the admins/whitelist/blacklist, replacing
only the XML-sourced entries so runtime .zsv edits survive. Every open
item on the bans row is now closed (serveradmin.xml read + hot-reloaded,
platform-id-keyed bans, whitelist enforcement, reserved/admin slots), so
the row flips to WORKS: Net and ops 43/8/5 -> **44/7/5**, total
182/107/44 -> **183/106/44**.

ParticleEffect + EntityStealth handled 2026-08-21 (C2S handler row, stays
PARTIAL): NetPackageParticleEffect re-broadcasts verbatim to every client
except the causing entity's owner (SpawnParticleEffectServer IL=41,
allButAttachedToEntityId), so client-triggered particles reach other
players; NetPackageEntityStealth is a validated no-op because zdtd computes
stealth server-side (crouch from movement frames, smell from buffs). RE
pins: 7dtd-research protocol-packages.md 5.11/5.12. C2S handled names 80
-> 82 of the 98 stock client sends; Net and ops stays 44/7/5, total
**183/106/44**.

QuestGotoPoint/QuestTreasurePoint handled 2026-08-21 (C2S handler row,
stays PARTIAL): the goto-marker report and the treasure-dig report are
validated no-ops - goto objectives complete by proximity (questTickGoto,
radius^2 per tick) and fetch/treasure phases advance from the client's
QuestObjectiveUpdate treasure_complete event, so both client echoes are
redundant. RE pin: 7dtd-research protocol-packages.md 5.13. C2S handled
names 82 -> 84 of the 98 stock client sends; Net and ops stays 44/7/5,
total **183/106/44**.

EntityPhysics handled + C2S tail categorized 2026-08-21 (C2S handler row,
stays PARTIAL): the physics-master report (pos/rot/velocity + flags) is a
validated no-op because movement, falling-block and vehicle sims are
server-authoritative (broadcast PosAndRot / VehiclePositions /
EntityVelocity). The remaining 17 unhandled names are categorized by scope
(protocol-packages.md 5.14): mod API surface, EAC/encryption waivers,
creative/editor, Twitch integration, headless mesh, and deferred
cosmetic/depth (DroneDataSync/DroneParticleEffect junk-drone state).
EntityRagdoll relay shipped 2026-08-21: the owner-client's ragdoll impulse
(entityId + flag-gated duration/bodyPart/vectors + mode/state) relays
verbatim to the other clients - the owner already ragdolled locally
(SendPacketToTrackedPlayersAndTrackedEntity). RE pin:
7dtd-research protocol-packages.md 5.15. C2S handled names 85
-> 86 of the 98 stock client sends; Net and ops stays 44/7/5, total
**183/106/44**.

GSI browser fields shipped 2026-08-22 (GameServerInfo row -> WORKS):
ServerDescription / ServerWebsiteURL / Region / Language / PlayGroup (from
ServerMatchmakingGroup) ride the GSI text when set in serverconfig.xml
(empty omits the key, client default; `;`/CR/LF stripped from operator
values). Every config-sourceable GameInfoString key is now emitted; the six
remaining members are platform/identity fields zdtd does not own
(documentable non-goals). Net and ops 44/7/5 -> **45/6/5**, total
183/106/44 -> **184/105/44**.

Power wire-edge persistence shipped 2026-08-22 (persistence row -> WORKS):
entities.zen gains a kind-3 record writing each live power edge
by endpoint positions (node ids are per-session), and the loader queues
them as pending wires that reconnectPending drains as scanChunkPower
rebuilds both endpoint nodes. A generator/consumer wiring survives
restart. Trader/NPC quest offers carry no separate state to save: the
offer list derives from npc.xml quest_list plus the player's active
journal at request time (buildTraderQuestOffers, tier filter + accept
marker), reconstructing identically after a restart - a documented design
difference with no client-visible impact. Net and ops 45/6/5 ->
**46/5/5**, total 184/105/44 -> **185/104/44**.

S2C emission recount 2026-08-22 (row, stays PARTIAL): 57 package names
now appear in server send calls across game + c2s (the join bundle, the
chunk/deco/weather stream, stat/vitals pushes, the map trio, the social
relays, response packages and auth denies); the never-sent list is
unchanged at the seven documented non-goals (progression sync, cosmetic
FX, EAC-scope auth). Net and ops stays 46/5/5, total **185/104/44**.

In-game console admin route shipped 2026-08-22 (row, stays PARTIAL): a
player with a permission-list entry now routes non-allowlisted console
verbs through the full admin command surface (runAdminLine, same path as
TCP/webui) with the reply captured into the ConsoleCmdClient response;
players without an entry still get "permission denied". Net and ops stays
46/5/5, total **185/104/44**.

Per-peer memory trimmed 2026-08-22 (row, stays PARTIAL): the Merged-mailbox
byte budget is now the true worst case (64 slots x max_single_user = ~83
KiB instead of 512 KiB), cutting the per-peer reservation from ~2.2 MiB to
~1.8 MiB (~139 MiB to ~114 MiB at 64 peers). A shared traffic-sized
reassembly pool would cut the rest. Admin TCP row -> WORKS 2026-08-22:
every server-relevant stock verb is implemented; client-only verbs (dm,
debugmenu, gfx, screenshot) are deliberately absent because they manipulate
the local client's rendering - a documented design note, not a parity gap.
Net and ops 46/5/5 -> **47/4/5**, total 185/104/44 -> **186/103/44**.

Quest NavObject markers shipped 2026-08-22 (quest row -> WORKS): the join
marker class now comes from the ACTIVE phase's `nav_object` property
(quests.xml objective property, arena-owned on the PhaseSpec; values
quest/rally/sleeper_volume/treasure/restore_power/fetch_container/
go_to_trader/return_to_trader) with the legacy kind fallback, and the
position is the placed POI center or the objective target - the old
primary-spawn fallback put kill/fetch markers on the wrong side of the
map. RE pin: 7dtd-research map-objects.md. Quests 20/11/1 -> 21/10/1,
total 186/103/44 -> **187/102/44**.

Quest objective party mirror shipped 2026-08-22 (S2C progress row ->
WORKS): the mid-session S2C path is NetPackageQuestObjectiveUpdate's party
fan-out (ProcessPackage IL=180) - the client reports its own objective
events, the server applies them to the authoritative journal AND re-applies
them to each party member's journal + re-sends the package to each member's
client, so a shared quest advances live for the whole party
(treasure_complete -> fetch phase, block_activated -> block_activate
phase). RE pin: 7dtd-research protocol-packages.md. Quests 21/10/1 ->
22/9/1, total 187/102/44 -> **188/101/44**.

Per-objective CurrentValue row -> WORKS 2026-08-22: the journal writer
emits 255 / clamped-active / 0-future per objective from the phase graph;
boolean-ish objectives (Goto, InteractWithNPC) and
TreasureChest/StayWithin do not consume the value client-side - exactly
like stock, whose Reads ignore it for those types - so the wire carries
the stock layout with stock semantics. Quests 22/9/1 -> 23/8/1, total
188/101/44 -> **189/100/44**.

Quest.PositionData row -> WORKS 2026-08-22: QuestGiver (0) is now written -
the giver position is captured at trader accept (the offering NPC's
position, for the client's return-to-giver marker; unset for starter
quests) alongside the existing Location / POIPosition / POISize entries.
Quests 23/8/1 -> 24/7/1, total 189/100/44 -> **190/99/44**.

Rewards row -> WORKS 2026-08-22: LootItem rewards whose id is a loot group
(groupQuestWeapons etc.) roll `value` prob-weighted picks (ischosen) or the
first `value` entries (isfixed) and grant each stack; RewardQuest entries
chain - the turn-in grants the named quest to the journal. RE pin:
7dtd-research quests-challenges.md. Quests 24/7/1 -> 25/6/1, total
190/99/44 -> **191/98/44**.

POI lockout row -> WORKS 2026-08-22: the home reasons now fire - a Game
context hook reports the requesting player's respawn bed and land claims
(land_claim_size radius around the keystone), and questCheckPoiLockout maps
them to LockReason.bedroll / .land_claim, alongside the existing
QuestLock, PlayerInside and the stock party-member exemption. Quests
25/6/1 -> 26/5/1, total 191/98/44 -> **192/97/44**.

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
- **Docs:** [GAP_ANALYSIS.md](GAP_ANALYSIS.md) scores 330 features with anchors;
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
