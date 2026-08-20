# Hardcode audit (Bucket A / B / OK) 2026-08-08

Date: 2026-08-08. HEAD: 3b06680 (main, clean tree). Method:
`docs/prompts/hardcoded-data-review.md` + systematic `rg` / file reads against
`src/`, stock `Data/Config` (V3.1.0 b14 dedicated install),
`docs/ASSETS.md`, `docs/GAME_OPTIONS.md`, `docs/GAP_ANALYSIS.md`,
`../7dtd-research/docs` (aidirector.md, loot-economy.md, weather-environment.md,
tile-entities-power.md). Re-verification of the 2026-08-08 pass in
`HARDCODE_AUDIT.md` plus new findings.

## Executive summary

| Bucket | New P0 | New P1 | New P2 | New P3 | Notes |
|---|---:|---:|---:|---:|---|
| **A** (stock data) | 0 | 1 | 3 | 4 | **A34**: entityclasses.xml HP (HealthMax passive_effect + replace_passive_effect variables) is never parsed; every zombie spawns at 40 HP and every animal at 30 HP even when the XML loads. This is the one real wrong-value risk left |
| **B** (zdtd policy) | 0 | 0 | 1 | 11 | Movement anti-cheat envelope caps not operator-tunable (P2); the rest are per-tick / array-size engineering caps, mostly already documented as fixed-size architecture |
| **OK** | - | - | - | - | 40+ cited false positives, unchanged from prior pass (wire/RE, dump pins, loaders) |
| Carried open (prior passes) | 0 | 0 | 8 | 2 | A07/A13/A14/A18/A21/A24/A33, B08-B12 residuals, B23-B24 |

No P0/P1 was both new and small-and-default-preserving this pass, so no code
changes were made; the deliverable is the audit. A34 and A35 are P1-class
"invented balance while game-dir XML is loaded" but their fixes change combat
defaults and are loader/sim changes, not drive-by edits.

Spot-check summary vs the prior audit claims:

| Claim in prior audit | Result |
|---|---|
| "Zombie HP from XML" (STATUS.md:547 `entityclasses.xml → HP`) | **Wrong.** `assets/entities.zig` parses only `<property>` elements; stock ships HP as `<passive_effect name="HealthMax">` (185 uses) + `<replace_passive_effect>` variables. All classes fall to `defaultHp` floors (zombie 40, animal 30, trader 9999) |
| "class_table speeds/damage from XML; Rules floors only when field 0" (A11) | Correct for speeds/damage/sight on the rows that are filled; see A35 for which rows are reachable |
| "trader pricing fixed (A29)" | Buy side correct (econ × BuyMarkup, root 3 from traders.xml). Sell side still missing the stock `EconomicSellScale` factor (GAP_ANALYSIS 957), P3 |
| "builtin leakage loud warns" | Present and gated on game-dir (game.zig:1241-1254) for blocks/items/recipes/entities/loot/entitygroups/quests; secondary catalogs log load failure via `paths.logCatalogLoadFail` |
| "terrain ids live via terrain_ids (A05)" | True for `isSolidWorld`/`deco_mirror`; two residual pin uses remain (A36 spawn pad, A38 rawAt/isSolid), P2/P3 |

## Bucket A findings (new this pass)

| ID | Location | Value / shape | Stock source | Sev | Fix shape | Default after fix |
|---|---|---|---|---|---|---|
| **A34** | `assets/entities.zig:262-266` (parse keys), `:170` (`defaultHp` floors), `:224-235` (property-only body scan); call sites `game.zig:944` (setClassDef max_hp), `game.zig:3958` (resolveSleeperClass), `admin_console.zig:383` | `MaxHealth`/`HandHealthMax` property lookup; both are absent from stock entityclasses (2 / 0 occurrences). Fallback `defaultHp`: zombie 40, animal 30, trader 9999 | `Data/Config/entityclasses.xml` `<passive_effect name="HealthMax" operation="base_set">` + `<replace_passive_effect>` (`healthSlim=125`, `healthSlimFeral=500`, `healthSlimRadiated=800`, `healthSlimCharged=1000`, `healthSlimInfernal=1600`, `healthNormal*`, `healthScreamer`, ...) + `perc_add -.15,.15` | **P1** | Extend `entities.zig`: parse passive_effect `HealthMax` base_set through the Extends chain, resolve `^variable` names from `<replace_passive_effect>`, pick deterministically inside the perc_add range (seeded stream, stock RNG-per-spawn). Trader 100000 also comes from this path | 40 → 125±15% (zombieBoe), feral 500, stag 50, rabbit 10, bear 2500. **Not default-preserving, intentionally; changes combat pacing** |
| **A35** | `ecs/world.zig:223-233` (16-row class_table), `game.zig:1003-1016` (only rows 1,8-11 seeded from ZombiesAll picks), `ecs/aidirector.zig:596-626` (spawnOneZombie name match, else `class_table[1]`) | At most 6 classes (5 seeded zombies + zombieBoe) can spawn; every other ZombiesAll member (24+ classes incl. all feral variants) spawns with zombieBoe stats. `spawnZombieClass` keeps `class_id.id = 1`, so AI speeds/sight/damage read zombieBoe for sleeper and director spawns | `entityclasses.xml` per-class defs (parsed) + `entitygroups.xml` ZombiesAll (29 members) | **P2** (documented GAP_ANALYSIS 1828-1838; P1-arguable: feral variants at non-feral stats) | Carry the full spawnable class table into the sim (expand class_table or a Game hook on the director), or fill all reachable classes at load. Not small | Same classes as today until A34-style fix lands |
| **A36** | `game.zig:3307` (`spawnSurface` spawn pad) | `world_store.block_dirt` module pin written on the join path | AssignIds `terrDirt` (live `World.terrain_ids.dirt` after merge, A05) | **P2** | Use `self.world.terrain_ids.dirt` | Identical (pin == dump value); removes the version-skew pin use |

**CLOSED 2026-08-20** (A36 verified landed; A37/A38 fixed in the terrain-id pass): `spawnSurface` already reads `World.terrain_ids.dirt` (game.zig `spawnSurface`); the TTS filler skip now takes the resolved `terrain_ids.terrain_filler(_adaptive)` ids instead of comptime pins, and `Chunk.rawAt`/`isSolid` fall back to `World.terrain_ids` (via a `terrain` pointer set in `World.getOrCreate`; offline chunks keep the pins).
| **A41** | `ecs/aidirector.zig:163-164` (`heat_cooldown_seconds=120`, `heat_neighbor_cooldown_seconds=60`) | Region cooldown 120 s, neighbor 60 s | Stock `AIDirectorChunkData`: `FindBestEventAndReset` region cooldown **240 s**; `StartCooldownOnNeighbors` neighbor table **180 s / 720 s** (aidirector.md 2026-08-07, asm.il 414504-415200) | **P2** (AI pacing divergence, semi-documented GAP_ANALYSIS 2037) | Align to 240 / 180-720 after IL re-verify, or expose as `[rules.ai]` tunables | Changes scout cadence (2x-3x slower); not default-preserving |
| **A37** | `world/tts.zig:418` | Filler skip compares comptime pins `assignids.terrain_filler(_adaptive)` | AssignIds names `terrainFiller` / `terrainFillerAdaptive` (dump-verified values 2/3) | **P3** | Resolve both names via idByName once at world init (alongside `terrain_ids`) | Identical |

**CLOSED 2026-08-20** (see A36 note): filler ids are fields of `TerrainIds`, resolved by `resolveTerrainIds`, and threaded into `tts.paintDecoration` / `Index.applyTtsPaintToChunk`.
| **A38** | `world/store.zig:310-313` (`Chunk.rawAt` heightmap fallback), `:370` (`Chunk.isSolid`) | Module pins `block_stone`/`block_dirt`/`block_air`/`block_water` on the no-blocks fallback path; `isSolidWorld` already uses live ids | AssignIds terrain names | **P3** | Route through `World.terrain_ids` when the chunk belongs to a World | Identical |

**CLOSED 2026-08-20** (see A36 note): `Chunk.terrain` points at `World.terrain_ids`; `rawAt`/`isSolid` use it when set and the pins otherwise.
| **A39** | `server/game/trader.zig:190-191` (`fillTraderFromXml`) | Sell = `econ × sell_markdown`; stock is `econ × EconomicSellScale × SellMarkdown`; the scale constant is missing (buy side is correct) | `XUiM_Trader.GetSellPrice` (asm.il 1830470-1830700, loot-economy.md §5) | **P3** | Add the `EconomicSellScale` constant after RE pin | Sell prices shift toward stock; documented residual |
| **A40** | `ecs/world.zig:225` | Builtin class_table row 2 `"zombieFeral"` (hash = zombie hash); no such class exists in stock entityclasses.xml (0 hits), no stock group names it | None (builtin invention) | **P3** | Delete or repoint to a real stock class; verify no reachable group picks it first | No behavioral change (unreachable today) |

## Bucket B findings (new this pass)

| ID | Location | Value / shape | Sev | Fix shape | Notes |
|---|---|---|---|---|---|
| **B29** | `server/movement.zig:7-11` | `max_horizontal_speed_mps=20.0`, `min_dt_s=1/40`, `max_dt_s=1.0` anti-cheat envelope, named + cited but not tunable | **P2** | `[authority] move_max_speed_mps` (+ dt clamps as engineering consts) | Soft cap; sprint ~6 m/s + vehicle margin. Prefer Rules/authority surface over serverconfig (no stock key) |

**CLOSED 2026-08-20** (landed before this pass): `[authority] max_horizontal_speed_mps` (game/types.zig + Game field + zdtd_config wiring).
| **B30** | `server/guard_policy.zig:21-33` | `kick_delay_ticks=10`, `shed_hold_ticks=40`, `weak_break_rate_per_window=900`, `detector_slots=9` | **P3** | `[authority] guard_*` keys | The other guard keys (window_ticks, strong_distinct, hard_repeat, load_shed) already parse |

**CLOSED 2026-08-20**: `kick_delay_ticks`, `shed_hold_ticks`, `weak_break_rate_per_window` are `Policy` fields (zdtd.toml `guard_kick_delay_ticks` / `guard_shed_hold_ticks` / `guard_weak_break_rate`), clamped in `Policy.clamp`; `detector_slots` stays a fixed-width engineering const.
| **B31** | `game.zig:1295,1305` | Sleeper POI scan budget: 512-block spawn radius, 800/1200 prefab ref caps | **P3** | `[stream] sleeper_prefab_radius_blocks` / caps | Load-time budget, not tick path |
| **B32** | `game.zig:4170,4181` | Per-tick loot container scan caps 32 / 48 | **P3** | `[sim]` caps or named consts | Tick budget |

**CLOSED 2026-08-20**: `te_scan_block_cap` / `te_scan_te_cap` (zdtd.toml `[sim]`) bound `ensurePrefabStorageInChunk` (chunk_fill.zig).
| **B33** | `world/workstations.zig:58-60` | `max_crafts_per_tick=64`, `max_craft_backlog=60` | **P3** | `[sim]` caps | Engineering |

**CLOSED 2026-08-20**: `workstation_crafts_per_tick` / `workstation_craft_backlog` (zdtd.toml `[sim]`), carried by `workstations.Caps` into the tick.
| **B34** | `ecs/quest.zig:20,98,101` | `max_phases=32`, `max_reward_flags=16`, `max_actions=8` | **P3** | named consts (already) | Array sizes |
| **B35** | `ecs/poi_lock.zig:19,23,26` | `unlock_grace=2000`, `max_locks=64`, `max_questers=8` | **P3** | named consts | Engineering |
| **B36** | `server/webui.zig:918` | `readiness_stale_ns=30 s` | **P3** | named const | Ops |
| **B37** | `game.zig:123` | `apm_report_period_ticks = ticks_per_second * 60` (60 s dump) | **P3** | `[apm] dump_every_s` | APM.md documents the periodic dump; no key |

**CLOSED 2026-08-20**: `[apm] dump_every_s` (seconds; 0 disables) drives `Game.apm_report_period_ticks`.
| **B38** | `world/sleepers.zig:10` (8192), `litenet/server.zig:8` (64), `util/parallel.zig:7-9` (8/24) | Fixed-size architecture caps | **P3** | Document only | Already documented as fixed-size architecture in prior audit |
| **B39** | `game.zig:3969` and `game/sleeper.zig:13` | `sleeper_party_radius=100.0` duplicated (same RE cite) | **P3** | Dedupe to one shared const | RE: CalcGameStageAround radius (asm.il ~1093363) |
| **B40** | `ecs/inventory.zig:67-83` | `offlineStockName` mirrors `assets/items.zig:412-427` `builtinStockName` | **P3** | Cross-check test or share one table | Documented mirror; divergence would be caught by existing id tests |

## Carried-forward open findings (unchanged, re-verified)

| ID | Area | Sev | Note |
|---|---|---|---|
| A07 | biome_layers defaults | P2 | Pre-XML defaults only; `tryLoad` resolves biomes.xml with loud failure log (verified) |
| A13 | recipe unlock extras | P2 | Gated on `source == .builtin`; stock XML list stays exact (verified) |
| A14 | quest builtins | P2 | Loud warn when game-dir set and catalog builtin (game.zig:1254, verified) |
| A18 | stock_chunk terrain pins | P2 | Dump-verified pins (stock_terr_*); server dictates ids via NameIdMapping (A22) |
| A21 | director / gamestages | P2 | gamestages.xml loads; stage inputs partial (GAP_ANALYSIS 5.x) |
| A24 | NONE loaders | P2 | Until feature lands |
| A33 | subbiome noise perm literal | P2 | `../7dtd-research` task; rest of the port exact |
| B08-B12 | lock_channel[16] array, lock stale | P2/P3 | `lock_stale_ms` config; array size engineering |
| B23-B24 | LiteNet port offset, APM cadence | P3 | Port+2 documented; APM cadence = B37 |

## Loader inventory vs stock Config

| Stock file | Loader | State |
|---|---|---|
| blocks.xml, materials.xml, AssignIds dump | maxdamage.zig / blocks.zig / blocks_nim.zig | HAVE (power watts/Class/MaxFuel/OutputPerFuel/Charge/Stack; CraftingAreaRecipes added at HEAD 3b06680; HeatMapStrength) |
| items.xml | items.zig | HAVE (Stacknumber via Extends, EconomicValue, DamageEntity, FuelValue, Eat cvars, stock type assign) |
| entityclasses.xml | entities.zig | **PARTIAL: A34** (hash, kind, loot, speeds, sight, HandItem parse; HP does not) |
| entitygroups.xml | entitygroups.zig | HAVE (cap 512 of 1892 groups, GAP_ANALYSIS 1820) |
| recipes.xml / loot.xml / quests.xml / traders.xml / npc.xml / gamestages.xml | recipes/loot/quests/traders/npc/gamestages | HAVE |
| biomes.xml | biome_layers.zig + world/biomes.zig | HAVE (layers, weather groups, deco, biomemapcolor) |
| painting.xml / spawning.xml / buffs.xml / progression.xml / vehicles.xml / storage_pairs (blocks DowngradeBlock) / signs (Prefabs) | matching loaders | HAVE |
| archetypes, blockplaceholders, challenges, dialogs, dmscontent, events, gameevents, item_modifiers, misc, music, nav_objects, physicsbodies, qualityinfo, rwgmixer, sandbox_overrides, shapes, sounds, twitch, twitch_events, ui_display, utilityai, weathersurvival, worldglobal, Localization, loadingscreen, XUi_* | none | NONE until feature (A24); LoadLocal name list is protocol (OK). A NONE file becomes a finding only when code behaves as if the data exists; the one such case is A34 (entityclasses HP), not a missing file |

## Builtin production leakage check

- Loud warns when game-dir/config-dir set and core catalog still builtin:
  `game.zig:1241-1254` (blocks, items, recipes, entities, loot, entitygroups,
  quests) plus `power_class_by_name` empty. Gated on `opts.game_dir != null or
  opts.config_dir != null`. Verified present.
- Secondary catalogs (vehicles, traders, npc, gamestages, spawning, buffs,
  progression, signs, painting, storage_pairs): parse failures log through
  `paths.logCatalogLoadFail`; a missing file logs too. No per-catalog
  "still builtin" summary line, but not silent.
- `biome_layers.tryLoad` logs `load biomes.xml failed` with the path (verified).
- A34 is the real leakage case: `entities.source == .xml` is true, so no warn
  fires, yet HP is the builtin floor. Fixing A34 removes the last silent
  builtin-balance-on-XML case.

## OK hardcodes (false positives, with cites)

Same list as the prior audit (wire/RE constants, dump pins, hashes from names,
offline test fixtures) plus re-verified:

- `aidirector.zig:161` `heat_event_ticks=720` (TileEntity.emitHeatMapEvent
  NotifyActivity duration 720, tile-entities-power.md 2026-08-08; not the
  cooldowns, which are A41).
- `weather.zig:21` `update_interval_ticks=5` (GenerateWeatherServerFrameUpdate
  IL_008a); `:25` `blood_moon_storm_push=5000` (weather-environment.md
  2026-08-07).
- `game/player.zig:20` `party_shared_kill_range_sq=100^2` (GameStats[54] stock
  default 100; no V3.1.0 serverconfig key).
- `game.zig:3969` / `game/sleeper.zig:13` `sleeper_party_radius=100`
  (GameStageDefinition::CalcGameStageAround, asm.il ~1093363); duplication is
  B39 but the value is RE.
- `movement.zig` caps are named and cited but they are policy, not physics
  (B29); the vehicle `gravity_accel=-9.81` remains the only standalone OK
  physics literal (EntityVehicle::cGravity, Unity Physics.gravity.y).
- `systems.zig:32` `dmg_scale=100` (fixed-point damage unit).
- `stock_chunk.zig` densities / `stock_terr_*` dump pins (A18).
- `items.zig:9-14` `items_start_here=65536` (Block.ItemsStartHere).
- litenet packet/peer constants (protocol RE); `max_peers=64` is architecture
  (B38).
- `worldgen.zig` `y_scale`/`squash`/`noise_weight` (zdtd worldgen, documented
  WORLDGEN.md; Bucket B by method but named + documented).
- `sleepers.zig:136-141` parseCount default 5 (stock ParseList IL).
- LoadLocal name list `game.zig:2936-2937` (protocol).

## Final Bucket B config surface

Unchanged from the shipped surface: `[stream]` (max_streamed_chunks,
chunk_adds_per_stream_tick, stream_radius_min/max, chunk_stream_period_ticks,
motion_replicate_period_ticks, world_time_send_ticks, vehicle_pos_send_ticks,
sleeper_tick_ticks, turret_sync_ticks, save_interval_ticks,
spawn_area_radius_max), `[authority]` (interest_range_blocks,
max_edit_range_blocks, max_claimed_damage, peer_stale_ms, lock_stale_ms,
join_rate_limit_ms, mode, guard_*), `[feature]` (wire_chunks, deco_trees,
deco_mirror, block_id_mapping, deco_objects_per_join), `[perf]`
(async_chunk_flush, terrain_snapshot, job_batches), `[sim]`
(trader_wallet_dukes, min_chat_gap_ns, inv/block bucket+refill, min_damage_gap_ns,
damage_burst_max, trader_restock_cap/refill, craft_max_times, storm_frequency),
`[mode]`, `[plugin]`, `[rules]` overlay (30 AI tunables + combat/progression/
bloodmoon). Stock serverconfig keys via `config.zig` (ViewRadius, ServerPort,
ServerMaxPlayerCount, GameDifficulty, BloodMoon*, MaxSpawned*, DayNightLength,
DayLightLength, ZombieMove*, LootAbundance, XPMultiplier, BlockDamage*,
AirDropFrequency, DropOnDeath, LandClaim*, PlayerKillingMode, GameName,
GameWorld, Telnet*, ServerPassword, ZdtdAuthorityMode, ...).

Proposed new keys from this pass (B, all optional, commented in
zdtd.toml.example): `[authority] move_max_speed_mps`, `[apm] dump_every_s`,
`[sim] sleeper_prefab_radius_blocks`, guard kick/shed/rate keys. A34/A35/A41
values are Bucket A (stock data), never zdtd.toml.

## Ordered fix plan (small PRs; A P0/P1 first)

1. **A34 (P1)**: parse `HealthMax` passive_effect + `^variable` resolution +
   perc_add seeded pick in `assets/entities.zig`; unit test on the stock file
   (SkipZigTest when install missing) asserting zombieBoe ~125, feral ~500,
   stag ~50. Loadgen soak to confirm zombie TTK. Not default-preserving by
   design; do it as its own PR with STATUS/TODO update.
2. **A35 (P2, after A34)**: expand reachable classes in the sim (class_table or
   director hook). Separate PR.
3. **A36 + A37 + A38 (P2/P3, default-preserving)**: swap module pins for
   `World.terrain_ids` / idByName on the three residual sites. Small PR.
4. **A41 (P2)**: re-verify IL, align heat cooldowns or expose as `[rules.ai]`
   tunables (default-preserving route: config key with today's defaults).
5. **B29 + B30 + B32 + B33 + B37 (P2/P3)**: add the proposed zdtd.toml keys
   with current defaults as field initializers; delete the consts.
6. **Cleanup (P3)**: B39 dedupe sleeper_party_radius, B40 offlineStockName
   cross-check, A39 EconomicSellScale, A40 zombieFeral row, B31/B34-B36/B38
   named-const notes.

## Validation

`git status` clean at HEAD 3b06680 before this file. Docs-only change this
pass; `zig build` and `zig build test` unaffected. No code fixes landed (no
small safe default-preserving P0/P1 existed). Loader/balance changes from the
plan above must keep `zig build test` green and get a loadgen smoke when they
touch spawn paths.
