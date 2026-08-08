# State machine audit 2026-08-08

Audit of every stateful lifecycle in zdtd against the code and
`docs/STATE_MACHINES.md`. HEAD `3b06680` (branch main). Code is the authority;
where code and doc disagree the doc is fixed in this commit.

Method: read each machine's owning source (states, transitions, gates), compare
to the STATE_MACHINES.md section, flag mismatches and undocumented states. Doc
anchors cite file:line at HEAD.

## Summary table

| # | Machine | Code | Doc status | Notes |
|---|---|---|---|---|
| 1 | Join / client session | `server/c2s/join.zig`, `server/phase_gate.zig`, `server/game.zig` | matches, doc anchors stale | 3 diagram gaps (reconnect, death respawn, DynamicClientArrive fallback), WorldInfo is sent at Entering not Spawning |
| 2 | Quest lifecycle | `ecs/systems.zig` quest section, `ecs/quest.zig`, `ecs/components.zig` (`QuestProgress`), `ecs/poi_lock.zig` | matches, doc anchors stale | POI lock sub-machine and shared-quest latch undocumented |
| 3 | Weather storm SM | `world/weather.zig` | matches, 1 anchor stale | |
| 4 | Trader SM | `server/game/trader.zig`, `server/trade.zig`, `ecs/systems.zig` `traderRestock`, `ecs/components.zig` (`TraderStock`), `server/c2s/misc.zig` LockRequest | **undocumented** | whole machine missing from STATE_MACHINES.md; added |
| 5 | Sleeper volumes | `world/sleepers.zig`, `server/game/sleeper.zig`, `ecs/systems.zig` AiCtx | matches, 1 anchor stale | per-entity wake is proximity-only; AI diagram's "alert / damage" wake is wrong (fixed) |
| 6 | Blood moon | `ecs/aidirector.zig` (`WorldClock`, `Director`) | matches, 1 anchor stale | `bm_stage_frozen` latch and party spawn loop undocumented (added note) |
| 7 | Power grid | `ecs/electric.zig` (`PowerGrid`), `ecs/powerblocks.zig` (registry) | matches as summary | owner anchor points at the wrong file; switch latch / trigger delay-latch / timer undocumented (added note) |
| 8 | Vehicle multi-seat | `ecs/systems.zig` `vehicleAttach`/`vehicleDetach`, `ecs/components.zig` (`Vehicle`), `server/c2s/misc.zig` | **undocumented** | whole machine missing; added |
| 9 | Trader open/close C2S edge latches | `server/c2s/misc.zig` LockRequest, `server/trade.zig`, `server/c2s/quest.zig` TraderData | **undocumented** | folded into the new Trader section |

## 1. Join / client session SM

Actual state set (all flags on `Client`, `src/server/game/types.zig:274`):

| State | Code | Set by |
|---|---|---|
| Connecting | `!authed_challenge` | LiteNet Connect (`game.zig:2452` challenge send) |
| Challenged | `authed_challenge == true` | challenge echo match (`game.zig:2474-2488`, sends PackageIds) |
| Joined | `joined == true` | `c2s/join.zig` PlayerLogin accepted (~line 100) |
| Entering | phase `.joined` (no flag; `joined && !entered`) | RequestToEnterGame (`c2s/join.zig:123`) sends configs/WorldInfo/spawn points/areas/time/stats/deco |
| Spawning | pre-`entered` | RequestToSpawnPlayer (`c2s/join.zig:219`) or DynamicClientArrive fallback (`c2s/join.zig:187`) |
| Playing | `entered == true` | `sendJoinBundle` (`game.zig:3350`) |

Phase gate (`server/phase_gate.zig`): `phaseOf(joined, entered)` maps to
connecting / joined / playing; `allowed` drops any C2S name outside the
`pre_play_allow` list until playing (`game.zig:2600-2615`). The allowlist
matches the stock order the client walks (PlayerLogin, RequestToEnterGame,
AuthConfirmation, SignDataRequest, WorldInitInfoRequest, DynamicClientArrive,
RequestToSpawnPlayer, PlayerDisconnect).

Doc status: **matches**, with fixes applied:

1. Owner anchors were stale: `game.zig:4816` (phase gate dispatch) is at
   `game.zig:2600`; `game.zig:7050` (sendJoinBundle) is at `game.zig:3338`.
2. "Spawning: PlayerId bundle (WorldInfo, id map, chunks)" is wrong: WorldInfo
   (plus configs, spawn points, areas, time, stats, deco) goes out at
   RequestToEnterGame (Entering); the PlayerId bundle is PlayerId + id map +
   quest nav + holding + vitals + Spawned + entity spawns + chunks + time +
   stats (`game.zig:3338-3518`) and must NOT re-send WorldInfo
   (`game.zig:3346` comment: second WorldInfo restarts createWorld).
3. Three code paths the diagram omits (added as notes): re-login while joined
   (`c2s/join.zig:32-45` re-sends LoginAnswer + SpawnedInWorld without
   re-entering), death respawn (Playing -> RequestToSpawnPlayer dead -> revive
   + Spawned(died) re-bundle, `c2s/join.zig:240-310`), and the
   DynamicClientArrive spawn fallback. `world_ready` (set at WorldInitInfoRequest)
   starts the chunk streamer before spawn (`c2s/join.zig:181-186`).

Code observations (not fixed, not state bugs):

- The gate shares `pre_play_allow` between `.connecting` and `.joined`, and the
  join handlers do not require `c.joined`: a peer that never sends PlayerLogin
  can still get a spawn bundle via RequestToEnterGame / RequestToSpawnPlayer /
  DynamicClientArrive (`c2s/join.zig:123-140, 219-303`). AGENTS rule 18 says the
  gate should match the SM state; today it is permissive rather than strict.
- A live, already-entered player that re-sends RequestToSpawnPlayer skips the
  revive guard but still gets the death re-bundle branch of sendJoinBundle
  (`first_join = !c.entered` is false), i.e. Spawned(died) + EntityTeleport to
  spawn (`game.zig:3494-3512`). Only reachable from a non-stock client (the
  stock client only sends the package on death), so it is a hardening gap, not
  a live bug.

## 2. Quest lifecycle SM

Actual state set (`ecs/components.zig:319` `QuestProgress`): `active`,
`completed`, `ready_turn_in`, `progress`, `phase` (1-based), `rally_activated`,
`poi` (rect), `is_shared`.

Transitions (`ecs/systems.zig`):

| From | To | Trigger | Code |
|---|---|---|---|
| NotStarted | InProgress | `questAccept` (code + POI rect, first actionable phase) | `systems.zig:314` |
| InProgress | InProgress | phase advance: `bumpPhase` on kill / goto / interact / fetch / craft / stay-within / rally / block_activate | `systems.zig:307`, `questTickGoto:561`, `questTickStayWithin:531`, `questOnTraderOpen:390`, `questObjectiveEvent:3728` |
| InProgress | ReadyTurnIn | highest phase reached, def `turn_in` | `finishPhaseGraph` `systems.zig:239`, `markProgress:217` |
| InProgress | Completed | highest phase reached, def auto-complete | `finishPhaseGraph` |
| ReadyTurnIn | Completed | trader open (turn-in; wallet coins in sim, items/exp via tick-end ring) | `questOnTraderOpen:390` + `game.zig:4832-4869` |
| Completed | [*] | journal entry + reward payout | `completeQuest:198` |

Scaffolding: `.auto` phases and `.rally` phases with no POI rect auto-skip
(`phaseIsScaffolding:251`, `skipAutoPhases:261`). Failure paths
(`Optional`, `ForcePhaseFinish`) are not modelled, as the doc claims.

POI lockout (`ecs/poi_lock.zig`) is a real sub-machine the doc never drew:

| State | Code | Transition |
|---|---|---|
| Free (no entry / expired) | `Table.check` null | |
| Locked (questers inside) | `Lock.locked == true` | `lock()` adds a quester (`poi_lock.zig:90`); unlock drops one (`:107`) |
| LockedOut (grace) | `locked == false`, `locked_out_until = world_time + 2000` | last quester leaves (`removeQuester`, `poi_lock.zig:56-64`) |
| Expired (removed) | entry dropped | `world_time > locked_out_until` (`check`, `:115`) |

Shared quests: `is_shared` latches on party share (`game/social.zig:266`
`shareQuestWithParty`); on owner disconnect the party receives remove_quest
events (`game.zig:3152-3170`). Rally marker: `rally_activated` latches per
quest (`systems.zig:516`).

Doc status: **matches**, fixes applied:

1. Owner anchors stale: `systems.zig:192` (completeQuest) is at 198;
   `systems.zig:340` (questOnTraderOpen) is at 390.
2. Added the POI lock sub-machine diagram + shared-quest note.

Code observation (not fixed): `src/ecs/quest_systems.zig` is a byte-identical
copy of the quest section of `systems.zig` (functions match one-for-one). It is
imported only as `_ = quest_systems` in `ecs/root.zig:36,89` and never called;
its file header claims "systems.zig re-exports these via pub const aliases",
which is false (the opposite: it is the duplicate). Drift hazard only; the
canonical code is `systems.zig`.

## 3. Weather storm SM

`world/weather.zig` `BiomeState.storm_state` (0 clear, 1 stormbuild, 2 storm)
per biome, driven by `storm_world_time` (`serverTimeUpdate`, `weather.zig:136`):
countdown -> stormbuild -> storm -> clear + reschedule with seeded rng gap.
`forceBloodMoon` (`weather.zig:125`) pushes every pending storm 5000 ticks past
the horde night and latches each biome to its `bloodMoon` group while
`blood_moon_forced`; the latch clears at dawn. Persistence `weather.zwt`
(`encode:302` / `decode`). Doc diagram matches the code exactly.

Doc status: **matches**; one anchor fixed (`BiomeState.storm_state` is at
`weather.zig:36`, not 29).

## 4. Trader SM (new section, was undocumented)

`ecs/components.zig:597` `TraderStock` is the state store:

| State | Code | Transition |
|---|---|---|
| Open | `is_closed == false` | `traderIsOpen` (`game/trader.zig:34`) true (open_time window, overnight wrap; vending / no-hours / unknown info always open) |
| Closed | `is_closed == true` | `tickTraderAreas` (`game/trader.zig:46`) on hours edge: force-unlock trade channel 0 + toggle TraderOnOff gate blocks (meta bit 0x2) |
| Stock fresh | `reset_interval` / `last_restock_day` | lazy restock on open (`maybeRestockTrader`, `game/trader.zig:204`) when interval elapsed; daily timer `systems.traderRestock` (`systems.zig:751`) refills counts toward `trader_restock_cap`, resets `markup`, regrows `wallet` to `wallet_default` |
| Wallet | `wallet` / `wallet_default` | credited by player buys, debited when buying from players (sell refused when empty), regrown at restock; `trader_wallet_dukes` fallback |

Restock cadence: `reset_interval < 0` never, `0` daily, `> 0` every N days
(`systems.zig:751-778`). Roll seed is deterministic: world seed x trader id x
day (`game/trader.zig:127` `traderRollSeed`). Player wallet debits on buys,
credits on sells; the trader `wallet` does the reverse (credited by player
buys, debited when buying from players, a sell refused once the pool is
empty) and regrows toward `wallet_default` at restock.

Doc status: **undocumented**; added as section 9 with the C2S edge latches.

## 5. Sleeper volumes

`world/sleepers.zig:38` `Volume.triggered`: Untouched -> Triggered (one-way)
when a player is inside the volume AABB; scan every `sleeper_tick_ticks` (10
ticks, ~0.5 s, `game.zig:4733`), parallel over volumes
(`server/game/sleeper.zig:52` `tickSleeperVolumes`). Trigger spawns group 0
(`vol.groups[0]`) at gamestage-resolved count, either authored `Class=Sleeper`
marker positions or a seeded scatter (`game/sleeper.zig:74-135`). Waking is one
way: `triggered` stays true, so no re-spawn spam.

Per-entity awake state: `Sleeper.awake` (`ecs/components.zig:639`) with
`volume_r = 20` around the home cell; `systems.zig:987-1005` forces
`ai.state = .sleep` while no player is within `volume_r`, then latches
`awake = true` and goes `.chase` when one enters. Sleepers are exempt from
distraction targeting (`systems.zig:1691`) and far-despawn (`systems.zig:2109`).

Doc status: **matches** (section 8). Two fixes:

1. Owner anchor: `triggered` is at `sleepers.zig:38`, not 36.
2. Section 3 (AI) said "Sleep --> Chase: alert / damage"; the code only wakes
   on player proximity to home. Damage sets `revenge_target`
   (`world.zig:749` `damageFrom`) but the sleeper gate at `systems.zig:988`
   re-forces `.sleep` and skips the AI task pass while no player is near, so a
   damaged sleeper outside its volume radius stays asleep. Fixed the diagram to
   "player within volume radius".

## 6. Blood moon window

`aidirector.zig:61` `isBloodMoonNight`: dusk on the scheduled day through dawn
of the next day (crosses midnight rollover); `bloodmoon_frequency` 0 disables;
`bloodmoon_range` jitter is deterministic per cycle (`isBloodMoonDay:68`,
`bloodMoonDayFor:98`). `Director.tick` (`aidirector.zig:290`) sets
`bloodmoon_active` every tick; GameStats `blood_moon_day` re-broadcast on the
day roll (`game.zig:4715-4726`). Doc diagram matches.

Undocumented details (added as a note): `bm_stage_frozen` latches the party
gamestage at dusk and clears at dawn with horde marks (`aidirector.zig:330-347`,
`clearHordeMarks:557`); parties cluster players within 80 m
(`buildBloodMoonParties:493`), horde zombies teleport back to their party focus
past 150 m (`recountAndTeleportHorde:526`), waves spawn every 6 s per party
(`spawnBloodMoonParties:569`).

Doc status: **matches**; one anchor fixed (`isBloodMoonNight` at
`aidirector.zig:61`, not 62).

## 7. Power grid

`ecs/electric.zig` `PowerGrid` / `PowerNode` is the machine; `ecs/powerblocks.zig`
owns the blocks.xml `Registry` + `Resolved` props (kind, watts, fuel, trigger/
switch classes). Node effective states: `powered` (BFS reachability from an on
generator with fuel, solar gated by daylight, `resolveDay:498`), `on` (switch
latch), and for triggers `pulse_left` / `latched` / `delay_left` (the open gate).
`nodeIsOn` (`electric.zig:99`) maps node state to block meta bit 0x2: switch ->
latch, trigger -> pulse/latch, everything else -> powered.

Undocumented details (added as a note):

- Switch latch: `setSwitchAt` (`electric.zig:235`) flips `on`; an off switch is
  still powered (client sees meta bit 0x1) but passes nothing.
- Trigger gate: `activateTriggerAt` (`electric.zig:176`) requires a powered
  trigger; `delay_left` holds the gate shut until the delay elapses (`tick:246`
  step 5), `pulse_left` opens it for the duration, duration 0 (Triggered) falls
  back to a 0.5 s contact pulse, duration -1 (Always) latches until
  `resetTriggerAt` (`electric.zig:221`).
- Timer relay: `armTimer` (`electric.zig:164`) toggles a wired consumer on
  period.
- Generator fuel burns to empty -> auto off (`tick:246` step 1); battery
  charges on surplus / discharges on shortfall (step 3); overload drops
  highest-id consumers (load shed in `resolveDay`).

Doc status: **matches** as a summary; the owner anchor pointed at
`powerblocks.zig` for `PowerGrid`/`resolve`/`tick`, which live in
`electric.zig` (fixed).

## 8. Vehicle multi-seat (new section, was undocumented)

`ecs/components.zig:209-258` `Vehicle`: `seats[max_seats=6]` per seat holds a
rider net id or -1 (free); `driver_seat = 0`.

| State | Code | Transition |
|---|---|---|
| Seat free | `seats[s] < 0` | |
| Seat occupied | `seats[s] = rider` | `vehicleAttach` (`systems.zig:1890`): fresh mount requires proximity (`mount_range_sq`) and vacates any other vehicle; an occupied seat is refused (no eviction, unlike stock); re-requesting the held seat is a no-op |
| Seat change | old seat freed, new taken | `vehicleAttach` with `requested >= 0` and `requested != held`; leaving the driver seat stops the hull |
| Riding -> on foot | seat freed | `vehicleDetach` (`systems.zig:1934`): resolves the hull from occupancy (the wire detach carries vehicleId = -1); driver exit -> `vehicleStop` (`:1944` zeroes speed/throttle/steer) |

C2S: `NetPackageEntityAttach` accepts only `rider_id == own entity`
(`c2s/misc.zig:520-537`); `NetPackageVehicleSpawn` ops 0/1 seat/unseat and op 2
control, which only the seat-0 driver may send (`c2s/misc.zig:504-519`).
`VehicleDataSync` relays only when the sender is the driver (`c2s/misc.zig:493`).

Doc status: **undocumented**; added as section 10.

## 9. Trader open/close C2S edge latches

The lock-channel table (`game.zig:485` `lock_channel[16]` plus granted-ns /
holder-entity / pos-key) is the trader window latch:

- LockRequest grant (entity trader target) gates on `traderIsOpen` (deny
  "closed"), lazy-restocks (`maybeRestockTrader`), and answers with TraderData
  in the LockResponse context (`c2s/misc.zig:411-430`). Vending machines are
  always open (channel 1; `c2s/misc.zig:431-446`).
- Stale lock auto-release after `lock_stale_ns` (120 s, `c2s/misc.zig:341-344`).
- Close edge: `tickTraderAreas` force-unlocks trade channel 0 and sends a
  forced LockResponse unlock to the holder (`game/trader.zig:56-65`).
- Trade body: 9-byte NetPackageTraderData -> `handleTrade` (buy/sell against
  stock + wallet, `server/trade.zig:78`); CopyFrom bodies (hasTraderData=true)
  mirror the client's post-trade stock deltas and money back
  (`server/trade.zig:107`); the 4-byte open marker (entity id only) is the
  fall-through that fires `questOnTraderOpen` + snapshot + quest list
  (`c2s/quest.zig:203-241`).

Doc status: **undocumented**; folded into the new Trader section.

## Non-goal machines (doc sections 2, 11-14)

Spot-checked for anchor drift only (not re-audited): section 2 tick pipeline
matches `ecs/schedule.zig` phase order; section 13 peer anchor
(`litenet/peer.zig:129`) is current; section 14 claims match
`game/world.zig:26/65/89`. `docs/ZIG_CLONE.md` 4.4 is the loadgen client-side
join sequence, consistent with the server machine here (no change).

## Doc fixes applied (this commit)

1. STATE_MACHINES.md join: anchors 4816/7050 -> 2600/3338; Spawning
   parenthetical corrected (WorldInfo is Entering); reconnect, death-respawn
   and DynamicClientArrive fallback paths noted.
2. Quest: anchors 192/340 -> 198/390; added POI lock sub-machine + shared-quest
   note.
3. Weather: storm_state anchor 29 -> 36.
4. AI: Sleep wake transition corrected to player proximity (was "alert /
   damage").
5. Blood moon: anchor 62 -> 61; frozen-stage/party note.
6. Power: owner corrected to `electric.zig`; switch/trigger/timer details
   noted.
7. Sleepers: anchor 36 -> 38.
8. Added new sections 9 (Trader SM + C2S edge latches) and 10 (Vehicle
   multi-seat) with diagrams; table and numbering updated.

## Code observations (not fixed)

1. `quest_systems.zig` is a dead byte-identical duplicate of the `systems.zig`
   quest section (see section 2).
2. Join gate is permissive pre-login (see section 1).
3. Live-player RequestToSpawnPlayer re-bundle (see section 1).
4. `questOnTraderOpen` firing depends on the implicit 4-byte NetPackageTraderData
   open marker shape (see section 9); if a stock-client build changes the open
   body, trader_interact / turn-in quests silently stop advancing. The coupling
   is implicit and untested end-to-end with a real client.
