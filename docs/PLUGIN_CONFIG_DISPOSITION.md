# Plugin/config disposition (ADR 0020/0026 review)

> **Purpose:** audit of every behavioral rule against the plugin boundary - which decisions belong in Wasm, in config, or stay native.

Classification of every behavioral rule/decision point in the server's
rules/logic against the plugin boundary. The rule (ADR 0020/0026, AGENTS 28/29):
**Related:** [PLUGIN_API.md](PLUGIN_API.md) · [PLUGIN_DEV.md](PLUGIN_DEV.md) · [PLUGIN_STANDARDS.md](PLUGIN_STANDARDS.md) · [RULES_CONFIG.md](RULES_CONFIG.md) · [STATE_MACHINES.md](STATE_MACHINES.md) · [GAMEPLAY.md](GAMEPLAY.md)

1. **Wasm module** - anything the boundary can express: `zdtd.sense` /
   `zdtd.queue` / `zdtd.query` plus the event hooks and verdict convention
   (`<0` deny, `0` keep, `>0` percent-adjust). Modules live in `mods/`
   (addons) or `plugins/` (first-party core, AGENTS rule 31).
2. **Config** - operator policy that is data, not plugin logic: `rules.zig`
   groups (`zdtd.toml [rules.*]`, mode-pack overlaid), `[sim]`, `[quests]`,
   `[bots]`, serverconfig.
3. **Native** - only what the boundary *cannot* express: wire encode/emit,
   LiteNet, interest/replication, chunk stream, direct sim mutation, world
   store/persistence, config loading, plugin runtime, APM, and
   determinism-critical stock-fidelity sim.

## The boundary today

`src/plugin/wasm.zig` Hook enum (23): `on_enable, on_tick, on_player_join,
on_shutdown, on_player_death, on_entity_killed, on_block_damage,
on_quest_complete, on_admin_command, on_chat, on_player_login, on_player_leave,
on_player_damage, on_quest_accept, on_craft_request, on_loot_roll,
on_trader_event, on_mcp_frame, on_trade_price, on_perk_spend, on_stat_changed,
on_game_event, on_evidence`. Host: `src/server/game/wasm_host.zig`
(wasmTick / killVerdict / wasmQueue / wasmSense / wasmQuery / adminPlugin).

Existing modules (`plugins/`): core_craftgate (craft verdict), core_killfeed
(kill feed observer), core_lootgate (loot scaling), core_pvp (player-damage
verdicts), core_questgate (quest-accept verdict), core_tradefeed (trader
feed), core_damagegate (incoming damage ×N), core_pricegate (trade price
×N), core_rewardgate (quest reward ×N), core_announce (join/clock feed),
core_adminverbs (custom admin verbs). Addons (`mods/`): example_chat_filter
(chat), fps_bot (bot brains, ADR 0026), mcp (MCP protocol).

## Already correctly placed (no action)

- **Config-driven sim** (tunables goal, `docs/RULES_CONFIG.md`): director spawn
  rings/cadences, bloodmoon rules, heat map, despawn, survival, water/power
  budgets, trap XP fraction, chat gap, restock cap/refill, the 27 new
  `rules.*` fields (knockback, sleep-LOD, dig, push, heat feral, vehicle fuel,
  power battery/pulse, POI grace).
- **Wasm-carried add-ons**: chat filter, PvP, quest-accept, craft, loot, kill
  feed, trader feed, MCP, bot brains.
- **Native (boundary cannot express)**: wire/`stock_*` builders, LiteNet,
  interest/replication, chunk/deco/map stream, direct sim mutation (inventory,
  blocks, journal, trading, vehicles, power, POI locks, buffs, party),
  persistence, config loading, plugin runtime, APM, ECS ordering + seeded RNG
  (determinism), join SM/phase gates/anti-abuse, zombie EAITaskList (stock RE
  fidelity), weather state machine (RE + wire + persistence), trader price math
  (RE formulas over data), XP/gamestage/lootstage derivation (progression.xml
  formulas), quest POI filter chain (DynamicPrefabDecorator fidelity), bot host
  servant (brain already wasm).

## WASM-eligible gaps (verdict exists but a path bypasses it, or boundary lacks an affordance)

| Gap | Today | Fix | Unlocks |
|---|---|---|---|
| Zombie-melee player damage bypasses `on_player_damage` | verdict only in player-melee C2S (`c2s/misc.zig:464`) + bot shots; the ECS zombie attack path (`applyDeferredDamage`) called only `killVerdict` on death | **SHIPPED** - `player_damage_verdict_fn` on `World` (like `kill_verdict_fn`), consulted in `applyDeferredDamage` for player victims; Game routes to plugin + wasm host with attacker unknown; **`plugins/core_damagegate`** (incoming damage ×N) + scenario test | "incoming damage ×N", "deny fall/drowning", zombie friendly-fire policy |
| Announcements / event feed | `on_tick` + `zdtd.tick` can watch the clock, but `zdtd.queue` has no `say`/announce verb and there is no chat-broadcast host import | **SHIPPED** - `say` queue verb routed through the stock chat broadcast + `zdtd.sense` header v3 exposes world time + blood-moon day flag; **`plugins/core_announce`** v2 announces horde night, blood-moon countdown and airdrops from `on_tick` + scenario test | horde-night / blood-moon / airdrop / first-join announcements |
| Pre-trade price verdict | `on_trader_event` fires after a trade | **SHIPPED** - pre-trade price verdict hook (`on_trade_price`: `<0` deny, `>0` percent-adjust buy price); **`plugins/core_pricegate`** (1.5x trader prices per player) + scenario test | "trader prices ×N per player" module (reward/tax policy) |

> Correction: the `on_block_damage` gap was investigated and does NOT exist  -
> zombie chew (`tick.zig:275,383`) and explosions (`world.zig:313`) already
> route through the `addBlockDamage` choke point (`world.zig:190`) which applies
> the verdict. A "zombies can't break blocks" module works today.

## Wasm-eligible candidates (no boundary work needed; module + hook)

| Candidate | Hook | Module shape |
|---|---|---|
| Quest-reward scaling | `on_quest_complete` (>0 = percent) - already wired at `game/step.zig:315`, today only observed by core_killfeed | `core_rewardgate`: scale items/exp/coins per quest def |
| Immortal horde / no-death gates | `on_entity_killed` / `on_player_death` deny (killVerdict <0 → victim survives at 1 HP) - works today | `peaceful` / per-entity kill gates (user mod; no `core_`/`zdtd_` prefix) |
| Custom admin verbs | `on_admin_command` (only bot uses it) | `givequest`, `spawnwave`, `setdifficulty` as module verbs instead of native console arms |

## Config-eligible logic (non-scalar policy, not yet config-driven)

| Area | Today | Config surface |
|---|---|---|
| Airdrop policy (`game/tick.zig:177`) | interval-since-last-drop simplification, drop above first joined player, `0 = off` divergence from stock day-count+TOD | `[sim] airdrop`: `schedule_mode` (interval vs day/TOD), `day_min/day_max`, `drop_hour`, `target`, `loot_list` |
| Director scale tables (`ecs/aidirector.zig:218,221`) | hardcoded `[N]f32` `hp_scale_by_difficulty` / `move_scale_by_mode`, marked zdtd-tuned R9 (no RE pin) | `[rules.director] difficulty_hp_scale` / `move_scale_by_mode` (per-tier scalars; toml_bind is scalar-only) |
| Sleeper spawn-cap divergence (`game/sleeper.zig:100`) | documented divergence (spawns ignore the stock global gate) | `[sim] sleeper_cap_gate_enabled` toggle |
| Bot loadout pool (`game/bot.zig:61`) | per-weapon damage/range/pellets host constants | `[bots] weapon_table` (per-weapon fields) |
| Quest-POI constants (`game/hooks.zig:559,310`) | bed lockout 32 m, trader distance bands 500/1500 m hardcoded where neighbours are `[quests]` | `[quests] poi_bed_lockout_radius`, `trader_band_distances` |

## Implementation status

- `docs/RULES_CONFIG.md` - tunables disposition (moves re-applied; `zig build`
  compiles; suite verification subject to the pre-existing baseline OOM at
  commit `ff17497` - the concurrent session's committed regression, reproduced
  with no local changes).
- This doc - the plugin/config classification.
- **Shipped:** `[quests] poi_bed_lockout_radius` + `trader_band_1/2` (was
  hardcoded in hooks.zig); `on_player_damage` verdict in the ECS zombie-melee
  path (`player_damage_verdict_fn` on World + Game adapter); the `say` queue
  verb (`ecs/command.zig Op.say` + `Game.announceChat` through the stock chat
  broadcast) with the **`plugins/core_announce`** module (join/leave
  announcements) and a scenario test; **`plugins/core_rewardgate`** module
  (1.5x quest rewards via the already-wired `on_quest_complete` verdict) and a
  scenario test.
- **Shipped (plugin-boundary extensions):** `zdtd.sense` header **v3**
  (`src/server/game/wasm_host.zig`: 24-byte header, magic `ZBS3`, exposing
  tick, self entity, world time and blood-moon day flag; `mods/fps_bot` and
  `mods/mcp` migrated); **`plugins/core_announce` v2** announces horde
  night, blood-moon countdown and airdrops from `on_tick` (sense-driven) +
  scenario test; pre-trade price verdict hook **`on_trade_price`** (host
  `WasmHost.tradePrice` → `World.trade_price_verdict_fn`, consulted in
  `ecs/systems.zig` buy-price path) + **`plugins/core_pricegate`** (1.5x) +
  scenario test; **`plugins/core_damagegate`** (0.5x incoming damage via
  `on_player_damage`) + scenario test; **`plugins/core_adminverbs`** (`wave <n>`
  queue verb via `on_admin_command`, guest writes the reply) + scenario test.
  All five module scenario tests green.
- **Shipped:** `[sim] sleeper_cap_gate_enabled` (restores the stock sleeper
  CanSpawn(2.1f) global gate, default off = the documented divergence);
  director difficulty/move tier tables → `[rules.director] difficulty_hp_0..5`
  + `move_scale_0..4` (per-tier scalars, binder is scalar-only);
  `[sim] airdrop_schedule/day_min/day_max/drop_hour/loot_list` (stock-like
  day-count + TOD schedule mode; the default loot list also fixes the stale
  "supplyCrate" name that rolled empty crates - stock is "airDrop");
  `[bots] weapon_profiles` host loadout string table (default = builtin pool).
- The config surface is complete: every config-eligible candidate identified
  by the review is either moved (rules/[sim]/[quests]/[bots]) or kept with a
  reason above. Clock-based announcements (horde night, airdrop) shipped with
  sense v3 + `core_announce` v2 (see above).
- **2026-08-29 sweep: plugins carry their own config.** New host import
  `zdtd.config(out_ptr, out_cap) -> i32` serves each mod's `config.toml`
  (4 KiB cap, raw text; the host never parses it) to the guest, declared via
  `_zdtd_requires "config"`. All 12 core plugins are now config-driven and
  self-contained (manifest + wasm + source + config.toml + README in the
  folder): `core_pricegate`/`core_damagegate`/`core_lootgate`/
  `core_rewardgate` (`percent`), `core_craftgate`/`core_perkgate`/
  `core_questgate` (`deny_prefix`), `core_pvp` (`deny`), `core_announce`
  (announce strings), `core_adminverbs` (`spawn_x/y/z`, `spawn_entity`),
  `core_killfeed`/`core_tradefeed` (`log_level`). Config-only mods keep the
  preset channel (`preset.toml` = rules; e.g. `mods/moon_gravity` overrides
  `[rules.ai]`/`[rules.vehicle]` gravity). The "Bot loadout pool" row above
  shipped as `[bots] weapon_profiles`; `bot_max_hp` stays a fixed guest
  contract (ADR 0026), not config.
- `make check-xml-audit` - green (independent gate).

## Baseline OOM investigation (goal item 5)

The suite was reported to abort mid-run at the clean `ff17497` commit with a
"world save OutOfMemory". Bounded investigation on the current tree (binary
built 16:48 from the working tree, so all plugin/module/scenario edits are
included):

- **The log line is a fixture, not a failure.** `world save failed:
  OutOfMemory` appears in the suite log inside the `util.log.test` unit test
  (`warn and error always emit...`), which feeds fake messages
  (`items.xml unreadable`, `world save failed: OutOfMemory`) through the
  logger. It is test data, not a real persistence failure.
- **Full suite passes on a clean direct run.** `./.zig-cache/o/<hash>/test
  --seed=0x1` → `All 1294 tests passed.` exit 0, including all six plugin
  module scenarios (`announce`, `announce v2`, `rewardgate`, `pricegate`,
  `damagegate`, `adminverbs`) and the Navezgane/persist scenarios. Confirmed a
  second time with `--seed=0xdeadbeef` and a third time with the build-runner
  binary (`--seed=0x4f244d4b`), all `All 1294 tests passed.` exit 0.
- **`zig build test` itself exits 0 with the suite complete** (two runs, 17:53
  and 18:01, both exit 0; the captured test stderr shows every module
  scenario including `core_announce`/`pricegate`/`damagegate`/`adminverbs`
  and the final log-emitting test #1288). The trailing `failed command: ...`
  line that appears at the end of a successful `zig build test` log is a
  Zig 0.16 build-runner cosmetic artifact: the run step's success path still
  prints the captured stderr plus the last-command line
  (`std/Build/Step/Run.zig` `runCommand` + `build_runner.zig` "No matter the
  result" printer) whenever a passing run captured non-empty stderr; the exit
  code stays 0 and the summary is suppressed. It is not a failure.
- **No memory leak in the RSS curve.** Sampled the exact test process every
  10 s: RSS oscillates around a ~300 MB baseline with spikes to ~1 GB during
  the Navezgane map-load scenarios (Debug build), then returns to baseline.
  No monotonic growth across the 1294-test run.
- **The one real allocator abort (15:10, `--test-filter webui` invocation) is
  not reproducible** under the same seed in a clean run. That invocation also
  passes `--test-filter`, which the standalone test runner does not accept,
  and ran while several other projects' Debug test suites were executing
  concurrently on the host.
- **Earlier silent mid-suite deaths during this investigation were traced to
  a background-task stop** (process-group signal from the tooling), not to
  the code: the same run completed exit 0 when left alone.

**Conclusion: no leak isolatable; the reported baseline OOM does not
reproduce.** The suite is green end-to-end (`zig build test` exit 0; 3× direct
full-suite runs green). Residuals, each with a reason:

1. **Zig 0.16 runner cosmetic "failed command:" tail on success** (above)  -
   the output looks like a failure but the exit code is 0 and all 1294 tests
   pass; harmless, cosmetic only.
2. **Host cache-lock contention.** This host runs several other projects'
   wedged `zig build test` sessions (zine/modelfs/agave, alive for hours with
   hung 0%-CPU test children) that hold the shared Zig global cache lock for
   long stretches; a fresh `zig build test` issued in those windows blocks
   with no output until the lock frees (observed 330 s block). This is host
   environment, not zdtd code: the same invocation completed exit 0 when the
   lock was free.
3. **Concurrent-session transient webui failure.** One `zig build test` run
   reported 2 failing webui login-lockout tests (`renderLoginLockout ...`,
   `loginHintHtml ...`) while the concurrent session was mid-edit of the webui
   HTML pages (`login_lockout.html` etc., 17:04–17:09); their follow-up HTML
   edit restored the `aria-live="off"` markup the tests assert, and subsequent
   runs pass. Not a code defect in the current tree.

## Open question: `points` on the shipped gate modules

None of the shipped gate manifests declares `points`, so the exclusive
override-point mechanism (resolver DuplicateClaim + WasmHost claims table) is
only exercised by resolver unit tests, not by shipped modules. Two demo gates
(`core_pvp` deny-all, `core_damagegate` scale-all) target the same
`damage.player_scale` hook; declaring `points` on both would make loading both
a loud boot error (RFC 0005 R8 exclusivity) instead of first-non-keep-wins
voting. Resolution is a policy call (declare points on the gates vs keep the
fallback voting), not a defect: the modules behave correctly today either way.

## 2026-08-25 lift sweep (terminal)

Re-audit of the current tree (plugin-eligible behavior + hardcoded tunables;
two parallel passes) plus the lifts it produced. All open items below shipped;
nothing plugin-eligible or config-eligible remains native.

| Item | Lift |
|---|---|
| Quest **coin** rewards bypassed `on_quest_complete` (completeQuest paid `reward_coin` before the tick-end verdict; deny/scaling could not touch coins) | **FIXED** - coins pay at the payout through the same verdict (`step.zig`), deny withholds, >0 scales; ECS/scenario tests drain the completed-quest ring (4-slot, drained every tick in production); rewardgate module doc + fixture `reward_coin=100` prove the scaled coin leg |
| Kill-XP floor `100` in `xpGainFor` | **MOVED** - `[rules.progression] kill_xp_fallback` (binder + overlay + GAME_OPTIONS row) |
| Bot host move-arrival `0.05` + fire-range slop `2.0` | **MOVED** - `[bots] arrival_dist`, `[bots] shot_range_slop` (binder, main merge, Bot carries from cfg) |
| `on_entity_killed` positive verdict (>0 percent) unconsumed - kill plugins could not scale kill XP | **SHIPPED (boundary extension)** - the positive verdict rides `DamageResult.kill_scale_pct` to `killXpAward`; `plugin_rules.wasm` now scales kills 150% and the host test asserts it; trap-kill path passes 100 |

Closed with reason (re-audit): `world/worldgen.zig` terrain/noise constants are
zdtd-owned procedural worldgen; `electric.zig` max-node-watts and the interest/
path/queue caps are structural bounds; `world.zig` cover-score `10.0 - d*0.2`
is a host query heuristic (RE-adjacent, low operator value); offline-only
fallbacks (maxDamageForBlock id bands, rent term 30, POI bbox 50/20/50) are
documented stock-data defaults that XML overrides when present. Every Rules
group/field and every zdtd.toml key has a consumer (the old dead-field class
is gone; the parity + pin tests hold).

## 2026-08-29 sweep (plugin host caps)

Re-audit of the plugin host: the runtime knobs that are behavior are already
config (`[plugin] modules/fuel/max_memory_pages`). The remaining fixed
host bounds are load-time safety ceilings, kept in code with reason:
`wasm.zig max_wasm_plugins` (8-slot fixed table, the ADR 0020 host shape) and
`max_wasm_module_bytes` (16 MiB per-module ceiling at load; real plugins are
KBs, and an oversized operator-supplied `.wasm` fails closed instead of
loading). Both are the "FAIL safety guards" class from RULES_CONFIG, not
tunables. The frame-level C2S deflate bounds (`wire/frame.zig` inflate_cap
512 KiB, max_inflate_ratio 64) are the same class on the transport side.
