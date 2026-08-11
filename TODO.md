# TODO: path to full stock play

Policy: **proper stock wire/sim only**. No invented terrain, FX, or journal
blobs. Prefer leaving a gap open over shipping a fake.

| Doc | Role |
|---|---|
| [docs/STATUS.md](docs/STATUS.md) | What works now (hub; wins on conflict) |
| [docs/GAP_ANALYSIS.md](docs/GAP_ANALYSIS.md) | Gap inventory · 329 features · **53 MISSING** |
| [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) | Phased milestones |
| [docs/WORK_PLAN.md](docs/WORK_PLAN.md) | Handoff-ready tasks |
| [docs/INDEX.md](docs/INDEX.md) | Full doc map |

**Gates (2026-08-09):** `make check` exit 0 · **991/991** tests · `lint-architecture: clean` · `game.zig` 2537 (≤2500 via 42 shards) · live stock-client gate **23/23**. GAP **53 MISSING**. Evidence: [docs/STATUS.md](docs/STATUS.md) + `handoff.md`.

### Freeze (core playable)

Core join/CGO/demo **83/83**, strict eat (stackDrop + Food ≥+5), hard power-TE fixture, V3.1.0 pin: **freeze** unless TFP patch, full MinEvents eat (+15 chili S2C), or animator human soak reopens work.

### Shipped this wave (2026-08-06)

Do not re-open these as gaps; see [docs/STATUS.md](docs/STATUS.md) for detail.

- [x] **Join path closed on the real client**: dropped chunks are no longer
      recorded as streamed, `GameState=Running` is reported, and chunks stream
      before the spawn. The client renders and plays Navezgane.
- [x] **POI fidelity**: clockwise prefab rotation with `CalcRotation(rot, 4-r)`
      facing, `<name>.blocks.nim` id remap plus pre-v18 BlockValue conversion,
      and `YOffset` applied to the stamp origin.
- [x] **Combat and replication**: player HP reaches the client,
      `EntityRemove(Unloaded)` on leaving interest, alive/dirty bitsets with
      per-entity observer masks.
- [x] **Features**: deco NameIdMapping + biome density + world-store mirror,
      weather state machine, quest rally objectives, workstation RecipeQueue,
      power trigger TE wire, A* pathing, gamestages, buffs depth, vehicle
      multi-seat, party PlatformUserId, stock telnet console surface.
- [x] **Traders (T1)**: `.trader` replicates with a real `npcTraderJen` hash;
      `EntityCreationData.hasTraderData` and the LockResponse trader context
      carry server stock on both stock S2C paths (wire + scenario tested;
      visual check pending).
- [x] **Loot (T2)**: containers roll their own `blocks.xml` LootList (Extends
      resolved); zombie bags resolve the stock chain to `zPackReg` and drop only
      on `LootDropProb` (.04).
- [x] **Items (T3)**: `Stacknumber` defaults to 500 and inherits through
      `Extends` (leaf, one-hop and two-hop cases tested against the stock file).
- [x] **Water (T4)**: lakes/rivers fill from `water_info.xml` sources at chunk
      generation; the chunk water channel carries the full static mass.
- [x] **Progression (T5)**: `players.zsv` v3 persists level/XP/food/water/buffs
      across restarts (server-side ledger; ZPV2 still read; wipeplayer v3-aware).
- [x] **Quests (T6)**: `template=` inheritance, per-objective Write kinds, and
      the stock accept marker (`NPCQuestList RemoveQuest`; offers exclude active
      quests). `<variable>` display-param substitution remains open.
- [x] **Blood moon (T7)**: horde runs dusk-to-dawn across the rollover
      (IsBloodMoonTime); WorldTime day encoding `(day-1)*24000`; CalcDuskDawnHours
      and non-negative CalcNextDay jitter.
- [x] **World integrity (T8 part)**: land claims removed with the keystone and
      expire offline (`LandClaimExpiryDays`), owner online tracked, block repair
      takes the lower wire damage as new absolute. **Stability shipped**: the
      per-block byte plane and falling-block trigger live in
      `src/world/stability.zig`; a SetBlock that cuts a support fells the chain.
      Remaining: `EntityFallingBlock` visual entities and per-chunk persistence
      of the plane (stock does not persist it either).
- [x] **C2S (T10)**: `NetPackagePlayerDisconnect` handled on the quit path (own
      entity only, immediate save + slot teardown); parity 0 unhandled dir=1.
- [x] **Plugins (T9)**: zwasm v2 Wasm runtime (`src/plugin/wasm.zig`). `[plugin]
      modules` in zdtd.toml loads `.wasm` once at init; host imports
      `zdtd_log`/`zdtd_tick`/`zdtd_queue`; fuel + memory budget disables a
      looping module within one tick; queued `SimCommand`s land in the sim.
      C-built fixtures prove a non-Zig module end to end (hello queues spawns
      that the sim applies; looper cut off by `OutOfFuel`).
- [x] **Storm persistence**: `weather.zwt` (ZWTH1) saves the per-biome storm
      machine (group index, storm state, schedule fields, rng state); restored
      right after the fresh seed at init, saved on the periodic save path, admin
      save and deinit. Fail-closed decode keeps the fresh roll on corrupt input.
- [x] **Docs**: [GAP_ANALYSIS.md](docs/GAP_ANALYSIS.md) and
      [WORK_PLAN.md](docs/WORK_PLAN.md); review prompts moved to `docs/prompts/`
      with `*-review.md` names so the review-loop tool discovers them.

### Next up

The ranked, handoff-ready list lives in [docs/WORK_PLAN.md](docs/WORK_PLAN.md).
Wave 1 is T1 traders (unblocks most of traders and quests), then T2 loot tables
and T3 item stack sizes in parallel. Harness tasks W1-W3 are cheap and
independent; do W3 first if `make check` flakiness is costing time.

### Shipped this wave (2026-08-04..05)

Infrastructure and authority surface already in tree (do not re-open as gaps):

- [x] **Review follow-ups**: STATUS/TODO hygiene; eat near-max soft so Food S2C rises; double PlayerSpawned on join; `evidence` ring + admin dump; flood counters; [DECO_NRE.md](docs/archive/DECO_NRE.md)
- [x] **WebUI HTTP** WU0–WU2 (`server/webui.zig`): dashboard, `/api/apm.json`, POST `/api/cmd`, CSRF, cookie login
- [x] **`util/tcp_listen`**: std.Io.net listen for admin / GSI / webui (no raw linux accept loops in callers)
- [x] **`phase_gate.zig`**: per-package connecting|joined|playing matrix + `phase_rejects`
- [x] **`movement.zig`**: soft 20 m/s envelope + `movement_rejects` (observe counts; Correct clamp path)
- [x] **Static plugin host** + `sample_hello` (`src/plugin/`; ADR 0005; no dynlib/Wasm)
- [x] **P3 ECS ergonomics**: `ecs/res.zig`, `ecs/query.zig`, `ecs/command.zig` (cap 64 + soft warn)
- [x] **Stream soft warn** ~80% of `max_streamed_chunks` / entity / cmd buffer (`warn_ratio`)
- [x] **Hardcode A05** `World.terrain_ids` via idByName; **A10–A12 / B13** class AI floors, vehicle held drive, named tick periods
- [x] **zdtd.toml** + gamemode pack (`modes/default.toml`); reject counters in apm + webui

---

## Open now (read this first)

### Perk and attribute progression (ADR 0023)

`progression.xml`'s catalog loads (attributes, perks, costs) but nothing
tracks a player's level in any of them: no per-player state, no requirement
evaluator, no passive-effect resolver. Found because A34 (turret kill XP)
needed the last of those three and could only get a flat floor instead.
Decision: [ADR 0023](docs/adr/0023-perk-attribute-system.md). Plan:
[docs/WORK_PLAN.md](docs/WORK_PLAN.md) T24-T27, strictly ordered.

- [ ] T24: persist per-player attribute and perk levels plus a skill-point
      balance through the existing player save (ZPV3). Everything below needs
      this first.
- [ ] T25: a `ProgressionLevel`/`PlayerLevel` requirement evaluator for
      `<level_requirements>` (measured against the shipped file: no other
      requirement type appears there); any other requirement type in a block
      fails the level-up closed rather than approving it by ignoring what it
      can't check.
- [ ] T26: `resolveEffect`'s progression and buffs layers (see
      [ADR 0024](docs/adr/0024-passive-effect-stack-layers.md): stock computes
      this class of number from an item/equipment/progression/buffs layer
      stack, not a perk-only read), so A34's `ElectricalTrapXP` floor upgrades
      to the real per-player value and the next perk-gated number is a call
      site, not a new `Rules` field.
- [ ] T27: C2S perk/attribute spend, landed only after the S2C push
      (`buildPlayerStatsBody`) can echo the result correctly.
- [ ] T28: armor mitigation (`PhysicalDamageResist`/`ElementalDamageResist`,
      A35) fills T26's item/equipment layer stubs instead of a parallel
      resolver; independent of T24-T27, no per-player state needed.

### GameEvent engine, challenges, and other research-vs-plan gaps

A broader sweep of `../7dtd-research/docs/` (63 docs; the perk and anti-cheat
programs above only came from a first triage) against `GAP_ANALYSIS.md` and
this file. Decision for the largest item: [ADR 0025](docs/adr/0025-gameevent-scoped-interpreter.md)
(a scoped dispatch engine, not stock's full ~132-verb set, per the same
reasoning as ADR 0023's requirement evaluator). Plan:
[docs/WORK_PLAN.md](docs/WORK_PLAN.md) T32-T37.

- [ ] T32: the GameEvent dispatch engine. Currently a pure echo
      (`NetPackageGameEventRequest` → `buildGameEventResponse(body)`, sent back
      unchanged); no sequence/phase/action machinery exists anywhere. Blocks
      T33, blood-moon boss triggers, and quest `<action type=GameEvent>`
      elements.
- [ ] T33: the challenge system (needs T32). Scored MISSING with no
      elaboration section; zero implementation, `ChallengeJournal` is a
      permanent empty stub.
- [x] T34: crafting XP, re-scoped after checking the shipped `recipes.xml`
      (17 of 639 recipes declare `craft_exp_gain`, all declare it `0`) and
      landed against what's confirmed rather than the originally assumed
      formula.
- [x] T35: air-drop crates now push a `supply_drop` NavObject marker
      alongside the loot-bag spawn.
- [ ] T36: `BlockTrigger` C2S is relayed to nearby peers with zero server
      validation; any peer can claim any trigger fired and the server never
      checks the prefab's actual wiring.
- [x] T37: bedroll ownership persists (`players.zsv` bumped ZPV3 -> ZPV4,
      version-gated field, old files upgrade in place on next save).
- [~] T38: `ActiveRadiusEffects` (A36, fresh find from a genuine third-pass
      sweep, not previously tracked anywhere). Campfire/torch/candle warmth
      and a radiated barrel's proximity debuff were entirely unimplemented.
      Landed for workstation-backed blocks (campfire, burning barrel) via the
      existing buff-grant and workstation-iteration primitives. Open residual:
      always-on light sources with no fuel module (torch, candle, the
      radiated barrel) have no placed-block index to scan yet.

Also corrected: T30 (drone AI) was grounded on the wrong research doc and
undercounted the state machine at 6 states instead of the real 9 (missing
`NoClip` and `Teleport`, the stuck-recovery states); fixed in WORK_PLAN.
Four stale `GAP_ANALYSIS.md` rows found and fixed this pass (chat, ally
persistence, whitelist, deco density all incorrectly read MISSING/PARTIAL
against already-shipped code). `getsandboxoptions`/`gso` console verb is
also unimplemented and uninventoried (sandbox-options.md §8.1); low value,
not worth a task, noted here so it isn't lost.

### Anti-cheat (authority first, then detection)

EAC is off and clients are unmodified, so every defence is server side and
ownership beats detection. Decision:
[ADR 0022](docs/adr/0022-anti-cheat-architecture.md). Plan:
[docs/WORK_PLAN.md](docs/WORK_PLAN.md) T18-T23. Catalog, threat model and policy
vocabulary reused from the design-only sibling `../7dtd-server-guard/docs/`.
Anti-goal: shipping a kick. Ownership and readable evidence solve most of it.

- [ ] T18: own the player inventory. ADR 0007's client-trusting C2S apply is the
      largest cheat surface in the server (duplication, spawn-anything) and no
      detector closes it honestly. Worth more than every task below.
- [ ] T19: make `observe` mode honest. It counts movement rejects but still
      applies the client position, so the name promises protection the code does
      not provide.
- [ ] T20: classify every detector by input authority and role; assert the
      ceiling (`hard` requires every decision input server-derived) by test.
- [ ] T21: guest detector feed (`on_evidence` Wasm hook), read-only events out,
      `evidence.Event` in, severity capped by the host, never a gate.
- [ ] T22: attribution (a finding another player induces never accrues against
      the victim) and suppression (stalls, spawn, teleport, death, chunk
      starvation, packet loss), so the anti-cheat cannot be used to grief.
- [ ] T23: make the dry run produce a reviewable diff, so no enforcement rung is
      ever enabled without a measured false-positive rate.

### Custom game modes (config-driven behaviour)

**SHIPPED 2026-08-07** (ADR 0021, WORK_PLAN T11-T15). The TOML binder
(`src/util/toml_bind.zig`) replaced the two hand-written key chains; sim rules
live in `World.rules` (`src/ecs/rules.zig`, defaults pinned); mode packs set
any `Rules` field via `[rules.*]` plus the stock keys; precedence stays
operator-wins (`zdtd.toml` beats the pack); floors are classified in
HARDCODE_AUDIT A32; the Wasm host gained the four event hooks with a
deny/adjust return. See [docs/STATUS.md](docs/STATUS.md) wave 2026-08-07.

### Playtest suite (real client)

- [x] Phase A: `7dtd-playtest` mod + orchestrator; connect join-only; dig/place wait-confirm ([docs/CLIENT_PLAYTEST.md](docs/CLIENT_PLAYTEST.md))
- [x] Scenario catalog v0.2: demo/benchmark/full suites (~30 live, ~50 deferred SKIP); `SCENARIOS.md`
- [x] Demo green on **stock dedi** Navezgane: pass=24 fail=0 skip=7 (`make -C 7dtd-playtest playtest-demo`)
- [x] Playtest v0.3: telnet fixtures, day clock, look pitch, zombie nearby, JUnit, fresh-save; demo **pass=30 fail=0 skip=15**
- [x] Phase B partial: kill/spawn/death/respawn pass on zdtd demo (2026-08-03); residual dig/block-dmg/loot-pickup/craft/trader
- [x] Phase C: persist multi-phase rejoin in orchestrator (`7dtd-playtest` suite `persist`: setup → saveworld → restart → rejoin)
- [x] Optional: run demo against zdtd (`make -C 7dtd-playtest playtest-zdtd`) 2026-08-04q: **83 pass / 0 fail** stackDrop + Food +5.1; power TE hard; version pin V3.1.0


### Residual playtest fails (demo, 2026-08-04d) - product depth

Latest: `server/logs/playtest_zdtd_demo_20260804h.log` · report [docs/archive/PLAYTEST_V310_20260803.md](docs/archive/PLAYTEST_V310_20260803.md).
Score: **pass=83 fail=0** (20260804q). CGO PASS. Strict eat stackDrop + Food ≥+5 (04q 50.0→55.1; full +15 open). generator_fuel = Power TE present (not fuel SoC).

| Case | Symptom | Likely owner |
|---|---|---|
| `power/*` place suite | intermittent type=0 when client floats | **mitigated 2026-08-04:** void rescue surface-8; SetBlock reach clamps vertical dy to ±12 so mesh float does not fail horizontal place |
| `combat/zombie_target_has_health` | intermittent no EntityAlive | **mitigated 2026-08-04:** admin spawnentity surface Y + clear known_entities so ECD re-sends |

Closed fixtures: dig/place/block_dmg/explosion (04h); **eat_food_consume** strict (04q: stackDrop + Food ≥+5, no force-dec) + **ranged_shot**; **generator_fuel** Power TE hard. Peak **83/83** (20260804q).

**Server ItemActionEat (2026-08-04q):** InvTx use + PI stack-loss (Paths A/B/C; Path C needs resolved eat eid; ItemDrop rebaselines last_eatable). PreferenceTracker skip; high-id `is_eat`. Unit: food 40→55. Live playtest: food0=50.0 food=55.1 (+5.1; full chili +15 S2C not proven in orch log). Join: no WorldInitInfo after enter.

Closed this campaign: dig/place, loot pickup, craft, CGO, weather underrun, kill/respawn, V3.1.0 pin.

Shipped: SetBlock damage S2C, materials MaxDamage, ItemDrop class_item + Collect Despawned, ECD v36+stress, PDF **bLoaded=true** + playerMale profile (ToPlayer applies bag), starter coins, orch zdtd fresh-save.

### Residual non-demo (still open)

- [x] ~~Weather/storm SM state not persisted: on restart each biome resets to its
      default weather group instead of resuming the storm cycle~~ **Shipped
      2026-08-06**: `world/weather.zig` encode/decode (`weather.zwt`, ZWTH1)
      saves per-biome group index, storm state and schedule fields; restored
      right after the fresh seed in `initWithOptions`, saved on the periodic
      save path, admin save and deinit. Fail-closed decode (table-matched,
      bounds-checked) so a corrupt file keeps the fresh roll.
- [x] ~~GameStats.BloodMoonDay not re-sent on day roll: a client connected past
      its first blood moon keeps a stale value~~ **Shipped 2026-08-06**:
      `bloodMoonDayFor` is the single scheduled-day authority and step()
      re-broadcasts NetPackageGameStats to entered peers when it changes, so
      the red-moon HUD day refreshes after the first horde (scenario
      `bmday-resend`).

### Parity polish (client-visible)

- [x] Deco trees: **live-validated** 2026-08-05 (V3.0.1 b4 client): join burst `DecoUpdate objs=1488 pkgs=1`, client logs `[DECO] read 1488`, **0 exceptions**, world load completes (Chunks 226, CGO 90/39). DecoManager.Read NRE resolved; see [docs/DECO_NRE.md](docs/archive/DECO_NRE.md). Residual: one-shot join window (client nulls `loadedDecos` after world load) and no client id negotiation (A22)
- [x] Weather biome array S2C from `biomes.xml` default weather groups (join + WorldTime throttle); no hardcoded param table
- [x] **Survival loop (GAP 22)** SHIPPED 2026-08-07: `Game.tickSurvival`
  depletes Food/Water with in-game time, drains HP while starving/dehydrated,
  regens when well-fed, and syncs via `NetPackageEntityStatChanged`; rates are
  `[rules.progression]` tunables (stock passive-effect defaults not in the
  V3.1.0 IL corpus). **Stamina SHIPPED** (sprint drain via MovementState 3,
  idle regen, EntityStatChanged kind 1 sync). Open: core temperature,
  wellness.
- [x] **Storm gameplay effects (gates)** SHIPPED 2026-08-07: storm SM + `[sim] storm_frequency` (feeds the weather scheduler AND the GameStats wire), and the operator's `SandboxCode`/`SandboxPreset` now parse from serverconfig and ride the GameStats blob (EnumGameStats 71/70), so a joining client decodes the server's sandbox gates (TemperatureSurvival, StormFreq, blood-moon settings) instead of its own defaults. Per RE (weather-environment.md §4) the stock *dedicated* server stubs felt-temperature helpers and does NOT compute wet/cold buffs - the local client computes felt temperature from the shipped per-biome params + weathersurvival.xml MinEvents - so server-side buff application would double-apply and is intentionally NOT implemented. **GSI advertising SHIPPED 2026-08-07**: the TCP GameServerInfo text (and the PlayerLoginAnswer copy) now carries `SandboxPreset`/`SandboxCode` (GameInfoString 18/19) when the operator set them; unset keys are omitted (empty = client default, same as GameStats).
- [x] Vending machines: TileEntityVendingMachine (type 7) wire emitted - blocks.xml Class/TraderID with Extends resolution, per-block TraderData store seeded from trader_info, TE pushed on chunk stream + LockRequest open (`VendingMachineLockContext`). Disk persistence ships (ZVNM). **Rent SM ships 2026-08-07** (server-authoritative rent/clear/extend/expire via `NetPackagePlayerVendingMachine`; scenario `vending-rent`). **Real-client trade CopyFrom ships 2026-08-07**: the stock NetPackageTraderData ToServer body is parsed and mirrored onto trader/vending stock (scenario `traderdata-copyfrom`). **Owner lock/password/allowed editing ships 2026-08-07** (vending TE composite C2S, owner-gated; scenario `vending-edit`). The vending row is closed.
- [x] GameStats: full bPersistent propertyList blob (RE initPropertyDecl order); HUD day from WorldTime (no day field in GameStats net blob); BloodMoonDay = scheduled BM
- [x] Quest Craft + StayWithin phase kinds (quests.xml classify + `questOnCraft` / `questTickStayWithin`); Rally/UnlockPOI still `.auto`
- [x] EAI: grid A* chase path (`path.aStarToward` + solid hook); more task types still open (MISSING §5.2.1)
- [x] EAI BreakBlock task (path_blocked → hold chase for block damage)
- [x] EAI ApproachSpot task (`has_spot` / spot_x,z; below chase, above wander)
- [x] EAI DestroyArea + Territorial (home leash 32 m; destroy_area reuses break_block chew)
- [x] EAI Look task + `Reset()` hook + `Continue()`/`CanExecute()` split (wander→look→wander cycle, `Entity::SeekYaw` body yaw)
- [ ] EAI residual: Dodge (client animator only, and unreferenced by stock XML), Leap (jump physics + BodyDamage limbs + raycast), RangedAttack (item actions + projectiles); see MISSING §5.2.1. **RunAway\* SHIPPED 2026-08-07** (AITask-1 hurt + AITask-2 proximity flee) and **ApproachDistraction SHIPPED 2026-08-07** (dropped-item distraction: `DistractionTags`/`DistractionRadius`/`Lifetime`/`Strength`/`EatTicks` from items.xml - stock ships decoy `zombie,requires_contact` - the 20-tick tickDistraction broadcast latches nearby zombies, the task walks over and chews eat items; see GAP §5.2.1).
- [x] Power: fuel/SoC/timer tick; MaxFuel/OutputPerFuel/Charge from blocks.xml via maxdamage → powerblocks.Resolved → PowerNode (no default_gen_fuel consts)
- [x] Lock contention: TE pos-key cross-channel deny + 120s stale auto-release + clear on unlock/disconnect
- [x] Power solar day gate (`PowerNode.solar` + `resolveDay`/`tick(..., daylight)` from WorldClock)
- [x] Power: gas-can / FuelValue item refuel via InvTx place → `electric.refuelAt` (items.xml FuelValue; stock name ammoGasCan)
- [x] Power: full trigger TE wire (pressure plate / tripwire gate + `activateTriggerAt` on player step; pulse opens BFS)
- [x] Workstation RecipeQueue C2S: TileEntity type 12 parse applies queue + burn; tick crafts + dirty rebroadcast
- [x] Hardcode audit: run `docs/prompts/hardcoded-data-review.md` → [`docs/reviews/HARDCODE_AUDIT.md`](docs/reviews/HARDCODE_AUDIT.md) (Bucket A stock XML vs Bucket B zdtd config; 2026-08-04)

### M11 multiplayer CPU (1.0 scale gate)

- [x] Dirty bitsets + serialize-once interest (`World.alive_bits`/`dirty_bits` behind the `markDirty` funnel; entity-outer encode once, framed fan-out over one `interest.observerMask` word per entity; dirty clear is O(changed); apm `replicate_candidates`/`replicate_fanouts`/`replicate_encodes_skipped`)
- [x] Persistent thread pool (`util/parallel.zig` Io mutex/cond workers; no spawn/join per `forRanges`)
- [x] O(1) NetId → slot map (`World.net_to_slot`; already shipped)
- [x] Chunk stream named caps (`max_streamed_chunks`, `chunk_stream_radius_{min,max}`, `chunk_adds_per_stream_tick`, `chunk_stream_period_ticks`)
- [ ] Chunk stream workers (async load/encode): **parked until apm shows need** (named caps + main-thread stream enough for demo)
- [ ] 32-bot then 128-bot loadgen + apm budgets (criterion 7): **keep open; operator validation** (not a code checkbox alone)

### P4 authority spine (formalize existing gates)

- [x] Policy/mode config + AUTHORITY.md short doc (`ZdtdAuthorityMode`, docs/AUTHORITY.md)
- [x] Phase / ownership / bounds reject counters (`phase_rejects`, `ownership_rejects`, `bounds_rejects` in apm + webui)
- [x] Per-package phase matrix (`src/server/phase_gate.zig`; connecting|joined|playing; aggregate `phase_rejects`)
- [x] Movement envelope first cut (`src/server/movement.zig`; soft 20 m/s clamp + `movement_rejects`; observe counts only)
- [x] Inv cause ledger first cut (`ecs/inv_ledger.zig` ring + apm `inv_ledger_events`); **evidence JSONL flush ships 2026-08-07** (admin `evidence dump [path]`, `Game.dumpEvidenceFile`)
- [x] Guard policy P4 (`src/server/guard_policy.zig`): weak signals, load shed, quarantine bits, dry-run kick

### Parked / rejected (not near-term research-clone work)

- [ ] **PARKED** Planet-scale M2–M4 gateway/shards: after M11 only; DEM M1 proven - [SCALE.md](docs/SCALE.md)
- [ ] **REJECTED** SpacetimeDB substrate (SCALE.md); not a zdtd dependency
- [ ] **PARKED** Steam browser / full telnet parity (P3 ops); admin TCP + WebUI cover research ops
- [ ] **NON-GOAL** Encryption* RSA+AES: platform AntiCheat only; EAC-off research scope; ServerPassword LiteNet key shipped
- [ ] **PARKED** Wasm guest mods (ADR 0010 phase 2): after static plugins prove hooks; sandboxed fuel/memory caps; no stock Mods/ promise
- [ ] **DROPPED** Dynlib native plugins: ADR 0020 makes plugins Wasm-only, so there is no native ABI to version

### Extension roadmap (ADR 0010; after playability)

Design: [adr/0010-data-config-zig-plugins.md](docs/adr/0010-data-config-zig-plugins.md), [PLUGIN_API.md](docs/PLUGIN_API.md).

- [x] Hardcode A05: `World.terrain_ids` resolved via idByName at init (pins remain offline defaults)
- [x] `zdtd.toml` loader (`src/server/zdtd_config.zig`) stream/authority/feature + `zdtd.toml.example` + GAME_OPTIONS
- [x] Hardcode A10–A12 / B13 (class AI floors, vehicle held drive, named tick periods)
- [x] Hardcode A08: deco trees ship in the join `DecoUpdate` burst; ids via `Game.decoTreeIds` (`idByName`, fail closed to empty firstPackage), `[feature] deco_trees` kill switch, per-chunk deco path deleted (client nulls `loadedDecos` after `OnWorldLoaded`). A22 residual open: no `blocks` NameIdMapping, so id skew on a modded/other-version client is undetectable. Not stock density/biome species; server does not mirror the client deco writeback; needs a live-client playtest. See [DECO_NRE.md](docs/archive/DECO_NRE.md)
- [x] Native static plugin host skeleton (ADR 0005) + `sample_hello` (`src/plugin/`; no dynlib/Wasm)
- [x] Gamemode = config pack + static plugin flag (`modes/default.toml` + `mode.zig`; `--mode` / `[mode] name`; sample_plugin only)
- Wasm / dynlib: see **Parked / rejected** above (not open near-term checkboxes).

### Procedural worldgen (**on-the-fly stream**, not static bake)

Design hub: [docs/WORLDGEN.md](docs/WORLDGEN.md). **Not** stock RWG C# host and
**not** "generate whole map then run." Minecraft-style: listen → players move →
`getOrCreate` miss → gen that chunk from seed → stock wire → cache. Density
terrain + optional WFC tiles for settlements. Baked Navezgane/Pregen stay
alternate backends.

**W0/W1/W2 shipped.** W2b–W7 remain open as a **multi-milestone** track (not one
PR); unpark the rest after core demo depth + M11 unless prioritized.

- [x] **W0** `World` terrain source `proc`; empty world dir join; demand gen in `getOrCreate` + existing stream ring (proof: explore forever without prebake)
- [x] **W1** OpenSimplex2 + fBm/ridged + domain warp in Zig; determinism tests
- [x] **W2** 3D density + coarse-cell interp + `y_clamped_gradient` filling chunks **at stream time**; stock chunk wire unchanged (5×5×33 coarse grid, cell 4×8×4, world-snapped so chunk borders cannot seam; overhangs measured 12.4% of columns; 126 µs/chunk ReleaseFast, 1.7 ms Debug; apm `chunk_gen`). Fluids/biomes/caves/POI stay W3–W5
- [ ] **W2b** Async gen workers + prefetch ring + apm; tick never blocks on bulk gen (multi-milestone)
- [ ] **W3** 6-axis climate + biome surface blocks via biomes.xml / AssignIds names (multi-milestone). **Surface blocks SHIPPED 2026-08-07**: the procedural generator now samples a continuous low-frequency biome field (`WorldGen.biomeAt`, deterministic, region-contiguous) and fills each column with its biome's `biomes.xml` surface stack (`stackFor`) when more than one biome resolved; single-biome fallback unchanged. Still open: the 6-axis climate and biome-driven detail/vegetation density.
- [ ] **W4** Caves (cheese/spaghetti/noodle) + aquifers (multi-milestone)
- [ ] **W5** Deterministic POI placement (cell hash, cross-chunk), `.tts` stamp on first touch (multi-milestone)
- [ ] **W5b** WFC / edge-matched **tile** layout for districts/roads (not per-block terrain); collapse when settlement cell demanded; see WORLDGEN §6.1 (multi-milestone)
- [ ] **W6** DEM + procedural blend (detail on GLO-30 base; feather edges; still per-chunk stream) (multi-milestone)
- [ ] **W7** Far-terrain LOD sampling (ties [SCALE.md](docs/SCALE.md); after M11 planet track) (multi-milestone)
- [x] Operator: `--worldgen-seed U64` (implies proc); world dir = overlay+cache only; GAME_OPTIONS still open
- [x] Persist: player edits win over regen (ZCH3 load before regen; heights-only re-load after gen; blockmeta/containers)
- [ ] Stock RWG XML RE (rwgmixer/tiles) in `../7dtd-research` only; zdtd tables, no DLL

### P3 ECS ergonomics / scale brainstorm

Unchecked idea lists remain in **P3** and **Scale / concurrency** sections below.
Do not adopt third-party ECS cores.

---

## Shipped log (collapsed history)

Core loop and parity landings. Do not re-open without new evidence.

### Recent (2026-08-07)
- [x] **Prefab water plane (GAP)**: the `.tts` v>=17 sparse water channel is
      decoded into a dense per-cell mass plane (`TtsBlocks.water`) and
      `tts.paintDecoration` paints the resolved runtime water block at every
      mass>0 cell, so POI pools, flooded basements and water towers render wet
      through the existing chunk water-mass channel (full static mass derived
      from the water block plane). `applyTtsPaintToChunk` / `resetPoiBlocks`
      take the resolved `terrain_ids.water`; `water_id` 0 fails closed. Test:
      synthetic v19 prefab with one water cell → decode + paint (+1 test, 950
      total). Open: flowing-water sim.
- [x] **Power graph rebuild (GAP "Vehicle, turret, power ... persistence")**:
      power grid **nodes** rebuild from the chunk block grid on first chunk
      load (`scanChunkPower`, per-chunk `power_scanned`), so a
      generator/consumer/battery layout survives restart without saving the
      graph; `entities.zen` already saved vehicles/turrets. Open: wire edges
      (runtime only) and trader quest-offer state.

### Shipped (2026-08-08, refactor + flake root cause)
- [x] **game.zig shards**: loot (67f2a88), weather (6db0ed9), vehicle (82b9e24)
      extracted verbatim with thin forwarders; `game.zig` 5310 → 5099.
- [x] **Trader inventory roll** (c1c3d39): traders.xml refs keep count
      ranges, prob, unique_only and quality; the fill runs the ported
      `TraderInfo` spawn (prob-weighted group picks, uniform count + quality
      rolls, seeded per world+trader+day) and quality rides the TraderData
      wire. GAP "Inventory roll" closed; restock full-rebuild, TraderMaxTier
      and mods stay open.
- [x] **Party highest game stage** (01fa28d): `partyHighestGameStage` (max
      member stage of the largest party, or max over joined when ungrouped)
      feeds `director.party_stage`; blood-moon horde difficulty scales to the
      group high water mark instead of the weighted CalcPartyLevel. Sleeper
      volumes keep radius-based CalcGameStageAround.
- [x] **Loot container size** (a578230): world containers size from the
      `lootcontainer` size attr (woodenChest 6x2=12, smallSafes 8x5=40, gun
      safe capped at 54) and roll up to their capacity; the client shows the
      block's real cell count instead of a flat 8.
- [x] **Non-burning workstation queues** (586d59b): the craft gate mirrors
      stock (asm.il 1331687) - only fuel-module stations wait for isBurning;
      workbench / cement mixer / table saw advance. Fuel-module presence is
      block-derived (blocks.xml Workstation Modules).
- [x] **Workstation persistence** (44a4056): workstations.zws (ZWS1)
      round-trips fuel/input/output, the smelting queue (recipe blobs),
      craft-complete and melt across restart, so a forge's progress is not
      lost on reboot (rule 21).
- [x] **Trader window 50 entries** (fe30501): TraderStock.max_stock 12 → 50
      (stock TraderInfo.MaxItems); snapshot buffers and the TraderData wire
      carry the full window.
- [x] **Per-entity class stats** (da14212): every entityclasses.xml class a
      spawn group picks resolves by name and spawns with its own HP/speeds/
      damage/hash/loot (A35), instead of the ~12 preloaded classes only;
      animals too (bear 2500 HP). AI reads per-entity stats first.
- [x] **Loot count=all / force_prob / entry cap** (8e6daa9): count="all"
      groups spawn every entry (was pick-1), force_prob entries gate
      independently (stock asm.il 698452/698816), group entries cap 32 → 192
      so perkBooks (133) is not truncated.
- [x] **Loot quality templates** (cbb3bdf): parse <lootqualitytemplate> level
      bands and roll looted item quality by loot stage (asm.il 698080);
      containers carry quality on the wire instead of a flat 1 (quality items
      only; stackables keep 1 so they merge).
- [x] **Lazy trader restock on open** (253787f, c75d580): the LockRequest open
      rebuilds the window with fresh rolls when the trader_info ResetInterval
      elapsed (stock HandleFullReset, lazy not timed), advancing the restock
      day and regenerating the money pool.
- [x] **Test-suite flake root cause fixed**: the "4 pre-existing flakes" (console
      listents reply, blood-moon re-send, multi-seat join) all traced to
      scenario worlds and `.zdtd_cfg_cache` dirs retaining a previous run's
      `entities.zen` while every boot re-seeded the demo minibike + turret on
      top of the restored ones. Vehicle/turret records grew +2 per suite run
      (hundreds in local dirs) until entity slots (512) or the 8 KiB console
      reply sink ran out. Fix: `had_saved_entities` gates the persistable demo
      seeds (a real restart bug: duplicates on every boot), and
      `freshScenarioDir` wipes each scenario world before its test
      (`io_fs.removeDirTreeSimple`). `zig build test` → **975/975** on consecutive
      consecutive runs; counts provably stable across runs.

### Recent (2026-08-04)
- [x] **EAI Look + Reset/Continue split**: ported `EAILook` (asm.il:429858) as the seventh `zombie_tasks` cell, in the stock zombie AITask position between ApproachSpot and Wander (`entityclasses.xml` zombieTemplateMale, `EAITaskList::AddTask` priority == 1-based index, asm.il:430495). Look is not cosmetic: it is Wander's partner. Implementing it forced two missing stock mechanisms - a per-task `Reset()` hook (`EAITaskList::OnUpdateTasks` IL_006F, asm.il:437713) and a `Continue()` distinct from `CanExecute()` (`EAIBase::Continue` defaults to CanExecute, asm.il:424569). `EAIWander::Reset` seeds `lookTime = RandomRange(0.5, 5)` (asm.il:438383) and `EAIApproachSpot::Reset` seeds `5 + rand*3` (asm.il:424395); those are the only two Reset sites in the assembly that write `lookTime`. `EAIWander::Continue` (asm.il:438318) stops on the 30 s cap and on path-finished, which zdtd previously never did (wander ran forever). `EAIWander::CanExecute` is data-blocked while `lookTime > 0` (asm.il:438181). Look's Start latches the owed seconds and stops the mover (asm.il:429903); its Update slews body yaw via a port of `Entity::SeekYaw`'s speed law (asm.il:399475: quadratic slowdown inside 35 deg, 20 deg/s floor, MaxTurnSpeed 250 from entityclasses.xml) toward a fresh +/-60 deg pick every 0.7 s (asm.il:429984-430001). New: `c.TaskId.look`, five `ZombieAi` fields (`look_time`/`look_wait`/`look_turn_cd`/`look_yaw`/`wander_time`), `seekYawStep`, `canContinue`, `resetTask`, `rngFrac` (reuses the existing per-entity xorshift, as stock reuses one GameRandom per entity). +4 tests (453 total). Gaps documented (MISSING §5.2.1): head/eye `SetLookPosition` aim, alert double-drain, stun bail, per-class MaxTurnSpeed, per-tick vs two-phase slew, ultra-far LOD bypass, and the five residual tasks (Dodge/Leap/RangedAttack/RunAway*/ApproachDistraction) with the hard dependency each is blocked on. Also corrected §5.2.1's false claim that `entityclasses.xml` is "not on hand" - it ships with the dedicated server; per-class parsing is a scope gap, not a data gap.
- [x] **ECS/SoA review prompt** `docs/prompts/ecs-soa-review.md`; phase_gate + movement envelope; plugin host + query/command
- [x] **EAI BreakBlock**; eat soften near-max; wood→frameShapes place; deco empty firstPackage (no Read NRE)
- [x] **WebUI WU2**: POST `/api/cmd` + console UI + CSRF; expanded Snapshot (entity census, all apm counters, p99/max, policy knobs)
- [x] **zdtd.toml**: minimal TOML loader + example; stream/authority/feature → InitOptions; sanitize radii
- [x] **A05 terrain ids**: `World.terrain_ids` + `resolveTerrainIds` after AssignIds merge
- [x] **P4 reject counters**: phase/ownership/bounds apm + webui Errors panel
- [x] **Playtest flake mitigations**: void rescue threshold surface-8; `withinEditReach` vertical clamp; admin/console spawnentity at DTM surface + force ECD via known_entities unset
- [x] **ADR 0010** data/config/Zig + Wasm guest roadmap; WebUI WU0 skeleton
- [x] **WebUI WU1**: tick snapshot + status/players/apm partials + `/api/apm.json` + cookie login
- [x] **P4.0 authority spine**: `ZdtdAuthorityMode` observe|correct (default correct) in config → Game; `docs/AUTHORITY.md` formalizes join phase, C2S bounds, ownership, interest no self-echo
- [x] **EAI grid A\***: `path.aStarToward` (Manhattan, capped expand) + `World.solid_fn` body-height probe from block store; chase replans ~0.35s; unit tests around wall; greedy fallback
- [x] **M11.2 serialize-once interest**: entity-outer encode/frame once, fan-out framed PosAndRot (+ zombie Speeds/AliveFlags); dirty clear via `interest.clearAfterReplicate`; named chunk stream caps
- [x] **W0/W1 worldgen foundation**: `TerrainSource` + `world/noise.zig` (OpenSimplex2-family + fBm/ridged/warp) + `world/worldgen.zig`; `getOrCreate` proc path; `--worldgen-seed`
- [x] **Weather from biomes.xml**: `biome_layers.Table` parses default weather group ranges → wire params; join + WorldTime throttle send `NetPackageWeather`; deleted hardcoded `defaultWeatherBiomes`
- [x] **Quest Craft/StayWithin**: `QuestKind`/`PhaseKind` + systems hooks; quests.xml classifiers; nav markers exhaust kinds
- [x] Craft InvTx path + `questOnCraft` after successful recipe; stay tick on player move
- [x] Agent prompt `docs/prompts/hardcoded-data-review.md` expanded (Bucket A/B, stock Config gap list, builtins, absolute paths, ids/enums)
- [x] **Config XML overrides**: `--config-overrides DIR` (repeatable, filename order); xpath set/remove/append subset; `paths`+`xml_patch`+`io_fs` (`std.Io`, no raw syscalls); AGENTS rule 26
- [x] **Power from blocks.xml**: MaxFuel/OutputPerFuel/OutputPerCharge/OutputPerStack parsed in maxdamage; powerblocks.Resolved.applyToNode; place path applies props; electric tick fuel/SoC/timers; removed default_gen_fuel/battery_cap consts
- [x] WORLDGEN on-the-fly stream design + TODO W0-W7
- [x] Lock pos-key + stale timeout; solar day gate; persistent parallel pool (Io mutex/cond)

### Recent (2026-07-23)
- [x] **Stock EAI prioritized task graphs**: replaced the ad-hoc `switch (ai.state)` in `AiCtx.work` (`src/ecs/systems.zig`) with a faithful port of `EAITaskList::OnUpdateTasks` + `isBestTask` (asm.il:437713, :437874). Each zombie runs an ordered comptime task table (`zombie_tasks`) of `{priority, MutexBits, executeDelay, continuous}` cells with Start/Update/CanExecute/Continue hooks; every tick the best task is (re)selected by priority + mutex overlap (`(a.mutex & b.mutex)==0` = compatible) and projected back onto the coarse `ZombieAi.state` so all downstream replication (EntitySpeeds/AliveFlags, block-damage, despawn) is unchanged. Two real tasks: ApproachAndAttackTarget (chase+melee, mutex 0b11, delay 0.1, non-continuous; asm.il:421798) and Wander (mutex 0b01, continuous; asm.il:438104). Chase preempts wander on sensing a player; wander resumes on target loss via the mutex-release path. Director-seeded aggro (`alert && target_id>=0`) survives as long as the target entity exists. New `TaskId` enum + one `active_task` byte on `ZombieAi` (reuses `decision_cd` as the re-eval timer). +3 tests (189 total). Gaps documented (GAP_ANALYSIS 5.2.1): greedy path kept (no A\*), only 2 of stock's task types real, no data-driven per-class `AITask` XML, sensing collapsed to nearest-player, timing/chaseTimeMax approximated.
- [x] **Electrical block placement parity**: placing a stock electrical block (`generatorbank`, `solarbank`, `batterybank`, `electricwirerelay`, `autoTurret`, plates/traps, …) now registers a `PowerGrid` node at the block world position and removes it on break (`electric.addNodeAt`/`removeAt`, idempotent + wire-compacting). Node kind from block `Class` in stock `blocks.xml` (`src/ecs/powerblocks.zig`); watts are real block props (`MaxPower` sources, `RequiredPower` consumers, parsed in `maxdamage.loadFromBlocksXml`). Real `NetPackageWireActions` bodies drive wiring: SetParent (op 0) `connectByPos(child,parent[0])`, RemoveParent (op 1) `removeParentAt(child)`, SendWires (op 2) no-op; grounded in asm.il:842779/842922/843021. `NetPackageWireToolActions` = peer visual rebroadcast only. Legacy custom wire op kept for demo. Gaps (documented, not faked): generator fuel ramp, battery SoC, trigger/timer/toggle actuation, undirected RemoveParent, AssignIds V3.1.4↔V3.0.1 skew (silent no-op on mismatch). +5 tests (180 total).
- [x] **POI/construction blocks rendered as untextured grey clay** (whole houses smooth marching-cubes terrain material): chunk block-layer only wrote the low 8 bits of each id (`stock_chunk.zig` hardcoded `upper24=false`), so every id ≥ 256 truncated to `id & 0xFF` → a wrong (usually terrain) block. Fix: emit the 3072 B/cell interleaved `m_Upper24Bits` array (`id>>8,>>16,>>24`) whenever a layer has any id ≥ 256, matching decompiled `ChunkBlockLayer.Read`. Terrain ids (<256) unaffected, that is why floor looked fine but houses didn't. Live: CGO 0→25, house textures correct.
- [x] **Large POI chunks failed to send** (side effect of the above: upper24 grew chunks to 14-37 KB → many fragments overflowed the 64-slot reliable window → holed chunk disk → CGO 0). Fix: `Peer.sendReliable` now resumes the same fragment stream and pumps ACKs mid-message via a `pump_fn` callback (`Game.pumpAcks`) instead of restarting; `body_buf` 256→512 KB. Live: 0 failed chunk sends.
- [x] **serverconfig.xml gameplay options fully wired** (`config.zig` → `initWithOptions` + runtime systems, all clamped + tested, docs/GAME_OPTIONS.md). Config-only: GameDifficulty (zombie hp), BloodMoonFrequency/Range/EnemyCount, PlayerKillingMode (PvP gate), DayNightLength/DayLightLength (clock/night), MaxSpawnedZombies, ZombieMove/Night/Feral/BMMove + EnemyDifficulty → `World.zombie_speed_scale`, LootAbundance (roll count scale). New backing systems built so the rest apply too: **MaxSpawnedAnimals** (daytime animal spawner + cap), **XPMultiplier** (`Game.awardXp` server ledger on kill), **BlockDamagePlayer** (scales dig damage in SetBlock), **BlockDamageAI/AIBM** (`tickZombieBlockDamage`: zombies chew cover), **AirDropFrequency** (`tickAirDrop`: scheduled supply crate), **DropOnDeath** (loot bag on player death per mode), **LandClaim** (keystone placement → `land_claims`; non-owner SetBlock denied inside `LandClaimSize`; own-claim durability ×`LandClaimOnline/OfflineDurabilityModifier`). Also: serverconfig with a missing world folder falls back to flat instead of aborting startup (`io_fs.dirExistsSimple`).
- [x] "Starting game..." / grey floor tradeoff (2026-08-04): `fixedSizeCC=true` closes overlay (CGO thr=0) but installs ChunkProviderDummy → no splat load → grey MicroSplat floor. **Correct:** `fixedSizeCC=false` + stream r≥6 (meshable core clears viewDist²−10; r=4 max CGO≈25). Docs: STATUS, docs/wire/WIRE_CHUNK, research protocol-packages §4.2 + chunk-providers §4.5.
- [x] Terrain AssignIds + biomes.xml layers; TTS full rawData/density; density repair rules; skip terrainFiller paint; LiteNet frag window for large textured chunks.
- [x] **Asset catalogs from game-dir (2026-08-04):** AGENTS rule 15 + `docs/ASSETS.md`; blocks ids AssignIds-only (no sequential XML); itemToBlock name→frameShapes/cobble; biomes.xml ColorTable; power Class= scan; painting/spawning/buffs/progression loaders; traders full group expand; deco re-enable via idByName; shared `io_fs`/`paths` (DRY).
- [x] **Deferred catalogs (2026-08-04):** vehicles.xml → spawn HP/max_speed; buffs passive_effect; progression attrs/perks + XP curve level-up; storage Closed/Open pairs from DowngradeBlock; TE type named constants; director night/day/animal groups from spawning.xml.
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

Scale track (docs/SCALE.md, research-verified 2026-07-22):
- [x] M1 DEM streamer proven live (GLO-30 COG; world/dem.zig)
- [ ] **PARKED** M2 gateway split (after M11)
- [ ] **PARKED** M3 two static shards + handoff (after M11)
- [ ] **PARKED** M4 thread-per-core N shards (after M11)
- SpacetimeDB: **REJECTED** (SCALE.md); not a dependency

### More shipped detail (2026-07-22..23)

- [x] biomes/blocks id-space review; player save v2; traderAlways + EconomicValue
- [x] Zombie speeds/damage from XML; director class rotation; pop cap + far-despawn
- [x] Workstation TE wire + Recipe parse + 2Hz sim + output materialize
- [x] WindowFull tiering; admin TCP expansion; sleeper authored markers
- [x] Rejoin y-clamp; PPD join name; void rescue; PosAndRot authority
- [x] Playtest driver 11/11; C2S 32/33; docs/wire/PACKAGES.md; BloodmoonMusic (HordeEvent unwired)
- [x] Deco suppress (AssignIds skew); core loop clean-playable pw38
- [x] TTS planes; ServerPassword; AssignIds dump; chunk upper24; land claim options

Open scale/parity items: see **Open now** at top.

---

## P0 (blocks real play) - CLOSED

All items below shipped. Kept as historical checklist.

- [x] **TTS density + damage channels**  
  Load sbyte density + u8 damage planes after block types in `.tts`. Texture/TE
  lists still open. File: `src/world/tts.zig`.

- [x] **TTS name→id remap**  
  `.tts` types are prefab-local ids, not AssignIds: over Navezgane's 750 prefabs
  10.2% of authored cells meant a different block. `prefabs.remapToRuntimeIds`
  translates them by name through `<name>.blocks.nim` (`Prefab::loadIdMapping`).

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
  phase-less defs keep single-kind path. Gaps in GAP_ANALYSIS §6.1:
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
  per-item demand source). Gaps in docs/GAP_ANALYSIS.md: markup drift,
  TierItemGroups, trader wallet economy, restock depth, group refs.

- [x] **SharedQuest quest_code**  
  Monotonic `next_quest_code` on accept; remove matches code (def_id fallback).

---

## P2 (ops / multiplayer polish)

- [x] Party / ally echo (first cut) - full PlatformUserIdentifierAbs deferred
- [x] **Ally persistence (P3)** SHIPPED 2026-08-07: `NetPackageAllyRequest` now
  drives a real `AllyStore` table (`src/server/ally.zig`, ComputeTransition
  per asm.il 885142), and relationships persist to `{world_dir}/allies.zal`
  (magic ZAL1, zdtd-owned like claims.zlc) on the periodic + shutdown saves and
  restore at init.
- [x] **Party state machine (P3)** SHIPPED 2026-08-07: `NetPackagePartyActions`
  (entity-id keyed, no PUID - RE parties-factions.md §2) dispatches to a real
  `Party`/`PartyManager` (`src/ecs/party.zig`): AcceptInvite (creates/joins,
  8-member cap), ChangeLead, LeaveParty, KickFromParty, Disconnected,
  JoinAutoParty (party id 1), SetVoiceLobby; every mutation fans a stock-layout
  `NetPackagePartyData` snapshot out (party id, leader, voice lobby, member ids,
  changed entity, action, disband); party-of-one auto-disbands and disconnect
  removes. **Shared kill XP SHIPPED 2026-08-07** (`Party.GetPartyXP` split by
  in-range members + `NetPackageSharedPartyKill`). **POI lockout exemption
  SHIPPED** (party members inside a quest POI no longer block the rally).
  **Quest sharing SHIPPED** (accept → `NetPackageSharedQuest` to the party,
  disconnect → remove_quest). **Per-objective delta relay SHIPPED**
  (`NetPackagePartyQuestChange` fanned to the members). Open: party
  gamestage/loot max (see docs/GAP_ANALYSIS.md §AUTHGATE).
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
- Encryption* RSA+AES (platform AntiCheat; EAC-off research clone)
- SpacetimeDB or external multiplayer substrate as sim core
- Shipping TFP assets or redistributing game DLLs
- Adopting knoedel (or any Bevy-style archetype ECS) as the sim core
- Loading `7dtd-server-guard` (or any Harmony anti-cheat DLL) into zdtd
  (reimplement authority in-process; see P4)
- Steam browser protocol clone (admin TCP + WebUI are the ops surface)

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

- [x] **Typed resources** - `Res`/`ResMut` over power/director/ledger/commands (`src/ecs/res.zig`)
- [x] **System locals** - `TickLocals` on World; cleared in `beginTick` (`src/ecs/locals.zig`)
- [x] **Query helpers** - SoA mask `forEachAlive` / `forEachWith` / `forEachKind` (`src/ecs/query.zig`)  
- [x] **Explicit schedules** - `Phase` + `schedule.run`; `tickAll` thin wrapper (`src/ecs/schedule.zig`)
- [x] **Jobs helper** - `jobs.forSlotRange` over `util/parallel` (`src/ecs/jobs.zig`)

From **mr_ecs** (high value for dedi):

- [x] **Tick command buffer** - spawn_zombie/despawn/damage deferred; cap 64; drain end of `tickAll` (`src/ecs/command.zig`)  

- [x] **Generation-counted handles** - `EntityHandle` + `slot_gen` / `handleAlive` (net id remains wire key)
  stable for wire; internal slot gen prevents stale AI/target pointers  
- [x] **Fixed capacities + soft warnings** - entity + cmd buffer warn once past ~80%
  (`warn_ratio`); hard cap still fail-closed / drop  
- [x] Soft warnings for stream queues (~80% of max_streamed_chunks per client)
- [x] **Chunk-style parallel for** - `query.forEachParallelKind` via jobs/pool  
- [x] **Cmd profiling zones** - no apm import from ecs (cycle); `applied`/`dropped`
  counters + drain comment; wire apm in Game.step later if needed  

From **ecez**:

- [x] **Storage subset / capability** - `SimView` inv/transform mutators (`src/ecs/sim_view.zig`)
- [x] **Optional Tracy/ztracy markers** - `-Dtracy` maps one Tracy zone onto every
  `src/apm/` `Section` scope plus one frame mark per tick (`src/apm/tracy.zig`);
  zero-sized and unlinked when off. Tracy stays operator-supplied via
  `-Dtracy-src` (not vendored, no zig.zon dep, not in `make check`); only
  zones + frame marks are mapped (no plots/locks/alloc/GPU). See `docs/APM.md`.  
- [x] **Sim snapshot bytes (census)** - `ecs/snapshot.zig` writeCensus (entity counts + net ids); full SoA dump later
  regression tests / replay; not a second save format for ZCH3 `.zch`  

From **zig-ecs (Entt)**:

- [x] **View vs cached Group** - `src/ecs/group.zig`: `World.kind_groups`, one
  slot-ascending dense alive list per `Kind` (7 KB, no heap), inserted in
  `spawnBase` / removed in `destroy` / idempotent `World.reviveSlot`. Ascending
  order = byte-identical to the open View scan, so wiring is a pure speedup.
  `countKind` reads the group (old `kind_count` deleted). Query face in
  `query.zig`: `groupSlice` / `forEachKindGroup` / `copyKindInto`. Wired into
  `snapshotPlayers`, `systemTurrets` zombie list, `systemDespawnFar`,
  `tickZombieBlockDamage`, `broadcastVehiclePositions`. Open: no all-kinds alive
  group, but the replicate pass / motion dirty-clear / `clearDeadKnownEntities`
  now ride `World.alive_bits` / `dirty_bits` instead of O(capacity) slot walks
  (word-packed, still slot-ascending); no mask groups (`mask.zombie_ai`
  is mutated after spawn), so `systemZombieAi` stays an open scan; no owning
  group (rejected, fixed slots); still no spatial hash. View stays the default
  and the documented fallback for loops that spawn/destroy while iterating.  
- [x] **`each` packed args** - `query.each` / `eachKind` with make+packed pointers  

From **Flecs / zflecs** (ideas only, no C dep):

- [x] **Named pipeline phases** - `schedule.Phase` + `run`; `tickAll` → schedule  
- [x] **Observers / hooks** - on_spawn/on_death cap 4 (`src/ecs/observers.zig`)  
- [x] **Prefab/template spawn** - `World.spawnZombieFromClass` / `FromClassId`  
- [x] **Remote monitor** - WebUI `/api/apm.json` + `guardstats` admin; full telnet browser still parked
  do not embed Flecs explorer  

From **zentig**:

- [x] **Frame arena reset** - `World.beginTick` clears locals; drain clears cmds  
- [x] **Module include layout** - systems split; schedule order list (not DSL)  

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

- [x] **Persistent thread pool**  
  Replace spawn/join-per-`forRanges` with a long-lived pool (`util/parallel` or
  sibling). Same range API; lower tail latency on AI/turrets/save.

- [x] **Dirty-bit interest + serialize-once**  
  Entity-outer loop: encode PosAndRot (+ zombie Speeds/AliveFlags) once, frame
  once, `sendFramedDroppable` fan-out. Dirty pos/rot/spawn/flags clear after pass.
  Heartbeat via `interest.needsPosSend` / `pos_heartbeat_period_ticks`.

- [ ] **Chunk stream pipeline**  
  Decode/paint/encode stages with bounded queues: load/TTS on workers, main
  thread only commits store + enqueues S2C. Named caps shipped; **workers
  parked until apm shows need**.

- [ ] **Sharded world store**  
  Per-chunk or per-region mutex / ticket; block edits only on owned shard.
  Parallel pathfind read snapshots or epoch; writers stay tick-ordered for the
  same chunk.

- [ ] **Outbound net fan-out**  
  Build frames on tick thread (or encode workers into peer-local buffers);
  `sendto` batching; optional per-peer send worker only if apm shows send bound
  (careful: ordering and LiteNet state stay consistent).

### Mid-term (density / maps)

- [x] **Entity capacity policy** - soft warn ~80%; spawn fails closed at max; command buffer same
  Raise `max_entities` with pooling; despawn far sleepers; director budget by
  cell. Dense SoA scan stays OK if masks are tight and dead slots sparse.

- [x] **AI LOD** - lodScale + ultra-far wander sleep (4× full_ai); path chew still full
  unloaded cells, path requests as jobs with per-tick solve budget.

- [~] **Path / sleeper / TE loot as job batches**  
  **Done:** sleeper-volume scan is a `jobs.forSlotRange` batch behind
  `[perf] job_batches` (parallel AABB test, serial `vi`-ascending apply so the
  spawn seed is unchanged); `sleeper_scan` section + `sleeper_volumes_scanned`
  counter are always on.  
  **Open (gap):** deferred path-solve phase. A* already runs inside the parallel
  AI batch (`systems.zig` `AiCtx.work`) and writes only its own slot, so a
  separate phase buys a per-tick solve budget, not parallelism, and that budget
  delays some replans by a tick, i.e. changes sim outcomes. Needs `path_replans`
  + `sim_entities` p99 evidence *and* an accepted determinism baseline change.  
  **Open (gap):** TE loot batch. `loot.rollContainer` is pure and parallelisable
  but costs microseconds; the measurable cost is the up-to-65536-cell scan in
  `Game.ensurePrefabStorageInChunk`, whose `found >= 32` early return makes an
  exactly-equivalent parallel version fiddly. `te_scan` section +
  `te_scan_cells` counter ship now; refactor only if they show it.

- [x] **Parallel chunk save (first cut)** - `store.saveChunkSlice` + `parallel.forRanges`
- [x] **Async chunk flush** - `world/chunk_flush.zig` behind `[perf] async_chunk_flush`
  (default off). Encode on the tick thread, write on one joined background
  thread; the queued payloads are the double buffer (`Chunk.dirty` clears at
  encode time). `waitKey` gates `loadChunk` / `evictOneChunk` (stock
  `IsChunkSavedAndDormant`, asm.il:1182993); `World.deinit` drains and joins.
  Off under forced-serial so DST write-fault injection keeps seeing the error
  return. **Gap:** encode itself stays on the tick (`save_encode` section);
  incremental / region-file encode is a separate item.

- [x] **Read-mostly snapshots**  
  `world/terrain_snapshot.zig` behind `[perf] terrain_snapshot` (default off):
  one blocked bit per column for chunks around each player, rebuilt on the tick
  thread before the AI phase, so the A* inner-loop predicate no longer takes the
  process-global `Game.terrain_mu`. Built with `chunks.getPtr` only, so hits are
  byte-identical and misses take today's locked path (including its on-demand
  chunk generation). **Gap:** window caps at `max_chunks = 256` at radius 2;
  widely separated players truncate the tail (`terrain_snap_misses` measures it).

### Far-term / only with evidence

- [ ] **Multi-world or region shards** (separate processes or large regions)
  only if single-process 128-256 peers still fail budgets after serialize-once.
  Cross-shard entity migrate is a product decision, not a default.
- [ ] **Lock-free queues** at net edges (C2S parsed packets in, S2C frames out)
  if contention shows; keep sim apply single-threaded.
- [x] **SIMD packing** - `stock_chunk.zig` `@Vector` uniform/pack helpers
- [ ] **SIMD distance/mask scans** on SoA AI/interest after profiles
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
1. apm sections on tick + replicate + chunk stream (baseline)     [shipped]
2. persistent pool (cheap win on current parallel systems)        [shipped]
3. dirty bits + serialize-once interest (biggest multiplayer win) [shipped]
4. chunk stream named caps [shipped]; workers parked until apm need
5. sharded store / path jobs as maps and entity counts grow
6. only then consider process sharding (planet M2+ after M11)
```

Detail and status for interest/pool also live in
[docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) M11 and
[docs/ECS_SYSTEMS.md](docs/ECS_SYSTEMS.md). Update those when an item ships.

---

## P4 - Native authority / anti-exploit (server-guard ideas in-process)

**Source:** sibling [`7dtd-server-guard`](../7dtd-server-guard/) docs
(`THREAT_MODEL`, `ARCHITECTURE`, `SIGNALS`, `POLICY`). That project is a
Harmony mod for **stock** dedi. **zdtd does not load it.** We implement the
same *authority outcomes* inside the Zig apply path (AGENTS rule 17: server
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

- [x] **Policy + mode config** - `ZdtdAuthorityMode` observe|correct (default
  **correct**); `docs/AUTHORITY.md` formalizes existing gates  

- [x] **Protocol allow matrix** - `phase_gate.zig` name × phase (connecting|
  joined|playing); illegal → drop + `phase_rejects`; reconnect still handshake
  allowlist (resume paths later)
- [x] **Entity ownership** - C2S entity id must belong to connection (PosAndRot,
  RelPos, Speeds, AliveFlags, Teleport, Holding, Explosion, Bag player write);
  vehicle/turret delegated set still open  
- [x] **Decode validation** - NaN/Inf + coord range on PosAndRot/Speeds; RelPos
  finite check; `decode_rejects` counter (string/enum lengths still partial)  
- [x] **Cost-class token buckets** - inv/block refill tokens + chat gap; `c2s_throttle` apm
  setblock, damage, chunk req; `throttle` under pressure; never counts as “cheat
  score”  
- [x] **apm counters** - phase/ownership/bounds/movement/decode + `c2s_throttle`; guard_observe_drop when Observe mode expands

**P4.1 - Hard invariants (Correct mode)**

- [x] **Movement envelope (first cut)** - last accepted xz + soft 20 m/s over
  server dt; Correct clamp + soft PosAndRot snap; Observe count only; reset on
  spawn/teleport. Still open: accel, latency slack, debt/credit, vehicle enter
- [x] **Block / TE reach** - withinEditReach + land claim; TE/explosion/setblock reach gates
- [x] **Inventory conservation** - inv_ledger causes on InvTx/craft/loot/give; full trade/drop path audit still incremental
- [x] **Stack bounds** - clamp oversize on PlayerInventory/Bag apply via items
  table max_stack (quality bounds still open)  
- [x] **Craft** - InvTx craft + workstation TE type 12 queue apply + tick craft/burn + dirty S2C
- [x] **Damage** - attacker/target alive; interest reach; strength cap; PvP mode; combat rate burst; ammo check still open  
- [x] **Explosion** - ownership + reach + radius cap 6; initiator alive; inventory consume still shallow
- [x] **Privileged ops** - give/tele/kick/spawnentity only admin TCP + webui admin_fn; no C2S self-grant

**P4.2 - Ledgers and evidence**

- [x] **Per-peer movement ledger** - last accepted pos + tick + envelope rejects (full sample ring still optional)  
- [x] **Combat ledger** - last_damage_ns + damage_burst rate gate
- [x] **Inv ledger** - cause-tagged ring (`ecs/inv_ledger.zig`; InvTx/craft/loot/give)
- [x] **Evidence ring + JSONL lines** - `server/evidence.zig` ring; admin `evidence` dump; phase/movement record; file append optional later
- [x] **Admin visibility** - `guardstats` dumps phase/ownership/bounds/movement/
  decode rejects plus a second policy line (rungs, gate outcomes, per-slot
  quarantine bits); webui Errors panel; webui policy mirror still open  

**P4.3 - Soft / availability (Observe, then throttle)**

- [x] Flood / churn signals (first cut) - `reconnects`, `c2s_malformed`, evidence flood det
- [x] Weak farming signal: per-peer block-destroy rate → `Detector.farming` at
  `.soft`; `guard_policy.evaluate` returns `.none` for info/soft *before* any
  counter moves, so a weak signal is structurally unable to kick (unit-tested).
  Efficiency/aimbot/ESP signals stay a documented non-goal (wire too coarse)
- [x] Global load shed: `Game.shed_until_tick` armed by the `run()` overrun
  branch (2 s hold); drops info/soft evidence (`load_shed_drops`) and defers
  weather + vehicle-position broadcasts. Chunk stream, motion replicate,
  WorldTime and every Hard gate are never shed. Open: only the real-time loop
  arms it, so `--ticks`/scenario runs never exercise it end to end

**P4.4 - Enforce (only after dry-run)**

- [x] Quarantine flags: `guard_policy.Quarantine{no_damage,no_container,no_setblock}`
  attributed via the new `evidence.Surface`; enforced at DamageEntity, SetBlock,
  ExplosionInitiate, TileEntity (storage + workstation) and locking LockRequest;
  `quarantine_rejects` apm + admin `guardclear <slot>`. Session-scoped (a slot
  reset on disconnect clears them); persistence is an honest gap
- [x] Kick after policy gates: 2 distinct Strong detectors or N repeated Hard in
  a tick window → stock `NetPackagePlayerDenied` (ModDecision 0x10) + a 10-tick
  delayed drop matching `GameUtils.disconnectLater(0.5f)`. Requires
  `guard_enforce=true`, `guard_dry_run=false` and Correct mode. No ban ladder,
  `banUntil` always 0
- [x] Dry-run mode: default. Gate trips log `guard would kick` + `guard_would_kicks`
  until the operator opts in (zdtd.toml `[authority] guard_*`)
- [x] Scenario tests: speedhack PosAndRot → `movement_rejects` + clamp; guard
  policy log-only default and quarantine surface isolation
  (`scenarios.zig`); dupe inv / wrong entity id / phase violation still open  

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
