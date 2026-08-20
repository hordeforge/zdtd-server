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

**CLOSED 2026-08-20** (landed after the audit; this pass added the stock-file proof): `entities.zig` parses `<passive_effect name="HealthMax" operation="base_set">` alongside `<property>` rows (both feed the same props map), resolves `^name` values through the parsed `<replace_passive_effect>` map, and walks the Extends chain via `resolveProp`; `defaultHp` remains the fail-closed floor only. `perc_add` rolls are pinned to the base value for deterministic sims (documented; AGENTS rule 22). The stock-file test ("load stock entityclasses when present") now asserts HP: **zombieBoe = 200** (`^healthNormal`), **animalStag = 100** (own `base_set`; the 10 row in the file is inside an XML comment), **zombieBoeFeral = 550** (overrides zombieBoe with `^healthNormalFeral`, proving Extends-chain override + variable lookup). Ground truth = the V3.1.0 b14 file; the audit's 125/500/50 guesses were stale for this pin.
| **A35** | `ecs/world.zig:223-233` (16-row class_table), `game.zig:1003-1016` (only rows 1,8-11 seeded from ZombiesAll picks), `ecs/aidirector.zig:596-626` (spawnOneZombie name match, else `class_table[1]`) | At most 6 classes (5 seeded zombies + zombieBoe) can spawn; every other ZombiesAll member (24+ classes incl. all feral variants) spawns with zombieBoe stats. `spawnZombieClass` keeps `class_id.id = 1`, so AI speeds/sight/damage read zombieBoe for sleeper and director spawns | `entityclasses.xml` per-class defs (parsed) + `entitygroups.xml` ZombiesAll (29 members) | **P2** (documented GAP_ANALYSIS 1828-1838; P1-arguable: feral variants at non-feral stats) | Carry the full spawnable class table into the sim (expand class_table or a Game hook on the director), or fill all reachable classes at load. Not small | Same classes as today until A34-style fix lands |

**CLOSED 2026-08-20** (landed after the audit): the director's `class_resolve_fn` hook (ecs/aidirector.zig, wired by Game to the entities table) resolves any picked class that was not preloaded into the fixed class_table to its full entityclasses stats (HP/speeds/damage/hash/loot), so non-preloaded ZombiesAll members no longer fall back to zombieBoe stats.
| **A36** | `game.zig:3307` (`spawnSurface` spawn pad) | `world_store.block_dirt` module pin written on the join path | AssignIds `terrDirt` (live `World.terrain_ids.dirt` after merge, A05) | **P2** | Use `self.world.terrain_ids.dirt` | Identical (pin == dump value); removes the version-skew pin use |

**CLOSED 2026-08-20** (A36 verified landed; A37/A38 fixed in the terrain-id pass): `spawnSurface` already reads `World.terrain_ids.dirt` (game.zig `spawnSurface`); the TTS filler skip now takes the resolved `terrain_ids.terrain_filler(_adaptive)` ids instead of comptime pins, and `Chunk.rawAt`/`isSolid` fall back to `World.terrain_ids` (via a `terrain` pointer set in `World.getOrCreate`; offline chunks keep the pins).
| **A41** | `ecs/aidirector.zig:163-164` (`heat_cooldown_seconds=120`, `heat_neighbor_cooldown_seconds=60`) | Region cooldown 120 s, neighbor 60 s | Stock `AIDirectorChunkData`: `FindBestEventAndReset` region cooldown **240 s**; `StartCooldownOnNeighbors` neighbor table **180 s / 720 s** (aidirector.md 2026-08-07, asm.il 414504-415200) | **P2** (AI pacing divergence, semi-documented GAP_ANALYSIS 2037) | Align to 240 / 180-720 after IL re-verify, or expose as `[rules.ai]` tunables | Changes scout cadence (2x-3x slower); not default-preserving |

**CLOSED 2026-08-20**: defaults aligned to the RE-verified stock literals — `[rules.director] heat_cooldown_seconds` 240.0 (was 120), `heat_neighbor_cooldown_seconds` 180.0 (was 60), both still operator-tunable (ADR 0021). The stock long forms (1320/720) are modelled as the feral 2x roll (documented approximation); the pin test now asserts 240/180. Scout cadence roughly halves; GAME_OPTIONS.md updated.
| **A37** | `world/tts.zig:418` | Filler skip compares comptime pins `assignids.terrain_filler(_adaptive)` | AssignIds names `terrainFiller` / `terrainFillerAdaptive` (dump-verified values 2/3) | **P3** | Resolve both names via idByName once at world init (alongside `terrain_ids`) | Identical |

**CLOSED 2026-08-20** (see A36 note): filler ids are fields of `TerrainIds`, resolved by `resolveTerrainIds`, and threaded into `tts.paintDecoration` / `Index.applyTtsPaintToChunk`.
| **A38** | `world/store.zig:310-313` (`Chunk.rawAt` heightmap fallback), `:370` (`Chunk.isSolid`) | Module pins `block_stone`/`block_dirt`/`block_air`/`block_water` on the no-blocks fallback path; `isSolidWorld` already uses live ids | AssignIds terrain names | **P3** | Route through `World.terrain_ids` when the chunk belongs to a World | Identical |

**CLOSED 2026-08-20** (see A36 note): `Chunk.terrain` points at `World.terrain_ids`; `rawAt`/`isSolid` use it when set and the pins otherwise.
| **A39** | `server/game/trader.zig:190-191` (`fillTraderFromXml`) | Sell = `econ × sell_markdown`; stock is `econ × EconomicSellScale × SellMarkdown`; the scale constant is missing (buy side is correct) | `XUiM_Trader.GetSellPrice` (asm.il 1830470-1830700, loot-economy.md §5) | **P3** | Add the `EconomicSellScale` constant after RE pin | Sell prices shift toward stock; documented residual |

**CLOSED 2026-08-20**: `EconomicSellScale` is a per-item stock **data** property (`ItemClass.EconomicSellScale`, IL ctor default 1.0; `PropEconomicSellScale`), not a constant. `assets/items.zig` now parses it per item (`econ_sell_scale`, default 1.0) and `fillTraderFromXml` computes sell = `econ × scale × sell_markup` (trader + vending share the fill). Stock V3.1.0 b14 items.xml sets `.5` on `toolCookingGrill` (2 rows); the stock test asserts 0.5 for it and 1.0 defaults.
| **A40** | `ecs/world.zig:225` | Builtin class_table row 2 `"zombieFeral"` (hash = zombie hash); no such class exists in stock entityclasses.xml (0 hits), no stock group names it | None (builtin invention) | **P3** | Delete or repoint to a real stock class; verify no reachable group picks it first | No behavioral change (unreachable today) |

**CLOSED 2026-08-20**: row 2 repointed to the real feral variant `zombieBoeFeral` (stock class, Unity hash -272178566, max_hp 550 = its HealthMax `^healthNormalFeral`). No reachable group referenced the old name (live spawns resolve per-class via the A35 hook); offline-fallback only.

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

**CLOSED 2026-08-20**: `sleeper_party_radius` is now the single `[sim] sleeper_party_radius` config field (commit fe7729d).
| **B40** | `ecs/inventory.zig:67-83` | `offlineStockName` mirrors `assets/items.zig:412-427` `builtinStockName` | **P3** | Cross-check test or share one table | Documented mirror; divergence would be caught by existing id tests |

**PARKED 2026-08-20**: accepted as a documented mirror. A cross-check test cannot import across the ecs->assets lint edge, and the shared builtin ids are already pinned by the stock-type tests (`byId(8)` etc.); divergence would surface there.

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

### Carried rows disposition (2026-08-20, per the layered-policy goal)

Every row above is **PARKED** (not a config/data gap; documented engineering or
feature-blocked) or **RE-BLOCKED** (needs evidence outside this repo), with its
citation:

- **PARKED (feature-blocked)**: A07 (pre-XML defaults only; biomes.xml load
  failure is loud), A13 (builtin-gated; stock XML list exact), A14 (loud warn
  on builtin-with-game-dir), A21 (gamestages.xml loads; stage inputs partial,
  GAP_ANALYSIS 5.x), A24 (no NONE-file loader ships until the feature exists).
- **PARKED (OK-class / protocol / engineering)**: A18 (dump-verified `stock_terr_*`
  pins; the server dictates ids via NameIdMapping), B08-B12 (lock channel array
  size; `lock_stale_ms` is config), B23 (LiteNet port+2 is the stock protocol),
  B24 (APM cadence = B37, closed), B31 (load-time sleeper scan budget, not the
  tick path), B34-B36 (named consts already; array sizes / ops constants),
  B38 (fixed-size architecture caps, documented), B40 (documented mirror, see row).
- **RE-BLOCKED**: A33 (subbiome noise `_perm` literal byte-reproduction is owned
  by `../7dtd-research`; the rest of the subbiome port is exact, GAP_ANALYSIS 18).

No remaining row is an un-cited hardcode in game behavior: every Bucket A value
either reads stock data, is an OK-class dump/RE pin, or carries its blocker
citation above.

## Loader inventory vs stock Config

Complete cross-reference, **all 44 `Data/Config/*.xml` files** (re-verified
2026-08-20 against the V3.1.0 b14 dedicated install). The LoadLocal name list
(`config_files.zig`, protocol) and `xml_patch.zig` (operator override patches,
not data loaders) are excluded from "loader"; every sim-affecting value reads
through the listed loader or is documented NONE with no code dependency.

| Stock file | Loader | State |
|---|---|---|
| archetypes.xml | none | NONE, no dependency (wire "archetype" is the PlayerProfile field, not this file) |
| biomes.xml | biome_layers.zig + world/biomes.zig | HAVE (layers, weather groups, deco, biomemapcolor, subbiome sets) |
| blockplaceholders.xml | none | NONE, no dependency |
| blocks.xml (+ materials.xml) | blocks.zig / maxdamage.zig / storage_pairs | HAVE (solid/name, MaxDamage, power watts/Class/Fuel, CraftingAreaRecipes, HeatMapStrength, DowngradeBlock pairs) |
| buffs.xml | buffs.zig | HAVE (stack/duration/update_rate, passive_effect rows; triggered_effect VM is later) |
| challenges.xml | none | NONE, no dependency (challengegroup_reward_* quest names are name-keys, quests.xml side) |
| dialogs.xml | none | NONE, no dependency (trader dialog is client-side XUiM; server sends TraderData) |
| dmscontent.xml | none | NONE, no dependency |
| entityclasses.xml | entities.zig | **HAVE** (hash, kind, loot, speeds, sight, HandItem; HP via `HealthMax` passive_effect + variables — A34 closed 2026-08-20) |
| entitygroups.xml | entitygroups.zig | HAVE (weighted picks; parse cap 512 of 1892, GAP_ANALYSIS 1820) |
| events.xml | none | NONE, no dependency |
| gameevents.xml | none | NONE, no dependency |
| gamestages.xml | gamestages.zig | HAVE (stage ladders + player/party stage math) |
| item_modifiers.xml | none | NONE, no dependency |
| items.xml | items.zig | HAVE (Stacknumber via Extends, EconomicValue, **EconomicSellScale — A39 closed 2026-08-20**, DamageEntity, FuelValue, Eat cvars, stock type assign) |
| loadingscreen.xml | none | NONE, no dependency (client UI) |
| loot.xml | loot.zig | HAVE (groups/containers, count=all, force_prob, quality template) |
| materials.xml | via blocks/maxdamage | HAVE (block Material props ride blocks.xml rows) |
| misc.xml | none | NONE, no dependency |
| music.xml | none | NONE, no dependency (blood-moon music is the wire package, not this file) |
| nav_objects.xml | names verified (join.zig test) | OK (the three marker class names are wire identifiers from stock names; test asserts they exist in the stock file; sprite settings are client-side) |
| npc.xml | npc.zig | HAVE (trader class → traders.xml id + quest_list) |
| painting.xml | painting.zig | HAVE (paint id ↔ TextureId) |
| physicsbodies.xml | none | NONE, no dependency |
| progression.xml | progression.zig | HAVE (level curve, attribute/perk catalog) |
| qualityinfo.xml | none | NONE, no dependency (quality rolls ride loot/trader tables) |
| quests.xml | quests.zig | HAVE (defs, template inheritance, objective/reward/action kinds) |
| recipes.xml | recipes.zig | HAVE (craft outputs + ingredients; Workstation recipe blobs) |
| rwgmixer.xml | none | NONE, no dependency (worldgen is DTM/proc, not RWG mixer) |
| sandbox_overrides.xml | none | NONE, no dependency (SandboxCode passes through as config) |
| shapes.xml | none | NONE, no dependency (block shapes resolve via AssignIds ids) |
| signs.xml | none | NONE, no dependency (server ships sign shells; sign content is client-owned; prefab `*_signs.xml` libraries load via signs.zig) |
| sounds.xml | none | NONE, no dependency (FX are client-side) |
| spawning.xml | spawning.zig | HAVE (biome night/day/animal rules) |
| subtitles.xml | none | NONE, no dependency (client UI) |
| traders.xml | traders.zig | HAVE (trader_info, trader_item_groups, economy attrs, inventory roll) |
| twitch.xml / twitch_events.xml | none | NONE, no dependency (explicit non-goal, GAP_ANALYSIS 2a.6) |
| ui_display.xml | none | NONE, no dependency (client UI) |
| utilityai.xml | none | NONE, no dependency (EAI table is hand-ported, GAP_ANALYSIS 5.x) |
| vehicles.xml | vehicles.zig | HAVE (physical attributes → sim VehicleKind) |
| videos.xml | none | NONE, no dependency (client UI) |
| weathersurvival.xml | none | NONE, no dependency by design: the stock dedicated server stubs felt temperature, so wet/cold buffs stay client-computed (STATUS weather-env §4) |
| worldglobal.xml | none | NONE, no dependency |

Every NONE row was re-checked 2026-08-20 for code that behaves as if the file's
data exists; none does (the prior A34 case is closed). The LoadLocal name list
is protocol (OK).

### Beyond Data/Config (whole Data tree, re-verified 2026-08-20)

| Location | Files | State |
|---|---|---|
| `Data/Config/XUi_*` (styles/templates/windows/xui) | 10 | NONE, no dependency: client UI only; appears in the LoadLocal protocol list (the server tells the client which files to load, never parses them) |
| `Data/Worlds/<world>/map_info.xml` | 1/world | HAVE: `world/dtm.zig` (HeightMapSize) |
| `Data/Worlds/<world>/spawnpoints.xml` | 1/world | HAVE: `world/dtm.zig` (spawn points) |
| `Data/Worlds/<world>/water_info.xml` | 1/world | HAVE: `world/water.zig` (lake/river point sources) |
| `Data/Worlds/<world>/prefabs.xml` | 1/world | HAVE: `world/prefabs.zig` (POI decoration list) |
| `Data/Prefabs/*_signs.xml` | 515 | HAVE: `assets/signs.zig` (sign libraries for NetPackageSignDataResponse) |
| `Data/Prefabs/<name>.xml` (poi_/part_/rwgtile_ descriptors) | 1866 | HAVE: `world/prefabs.zig` reads YOffset, QuestTags, DifficultyTier, ThemeTags, TraderArea(/Protect), TeleportVolume*; footprint size comes from the `.tts` header. No descriptor value is hardcoded (the 8/4/8 size defaults are offline fallbacks) |

The whole game XML surface is therefore covered: 44 Data/Config + 10 XUi +
4 per-world kinds + 2381 Data/Prefabs XMLs, every one either loaded from the
operator install or verified NONE with a documented reason. No game XML data
is hardcoded anywhere in the codebase.

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
  builtin-balance-on-XML case. **CLOSED 2026-08-20**: HP now parses from the
  XML (see the A34 row); no silent builtin-balance-on-XML case remains.

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
   design; do it as its own PR with STATUS/TODO update. **LANDED** (the
   passive_effect + variable parsing and the `class_resolve_fn` hook shipped
   after the audit; this pass added the stock-file HP assertions — see the
   CLOSED notes on A34/A35).
2. **A35 (P2, after A34)**: expand reachable classes in the sim (class_table or
   director hook). Separate PR. **LANDED** (director `class_resolve_fn`).
3. **A36 + A37 + A38 (P2/P3, default-preserving)**: swap module pins for
   `World.terrain_ids` / idByName on the three residual sites. Small PR.
4. **A41 (P2)**: re-verify IL, align heat cooldowns or expose as `[rules.ai]`
   tunables (default-preserving route: config key with today's defaults).
5. **B29 + B30 + B32 + B33 + B37 (P2/P3)**: add the proposed zdtd.toml keys
   with current defaults as field initializers; delete the consts.
6. **Cleanup (P3)**: B39 dedupe sleeper_party_radius, B40 offlineStockName
   cross-check, A39 EconomicSellScale, A40 zombieFeral row, B31/B34-B36/B38
   named-const notes. **LANDED 2026-08-20**: A39 (EconomicSellScale is stock
   data, now parsed), A40 (feral row repointed), B39 (config field), B40
   (parked, documented mirror); B31/B34-B36/B38 parked with citations above.

## Re-scan 2026-08-20 (fresh hardcode pass over game-behavior paths)

Re-ran the hardcoded-data review (docs/prompts/hardcoded-data-review.md) over
src/assets, src/ecs, src/world, src/server/game, src/server/c2s after all
prior rows closed. Findings and dispositions:

| ID | Location | Value | Bucket | Disposition |
|---|---|---|---|---|
| R1 | `world/workstations.zig` handleFuel | flat +10 s per fuel item | A | **FIXED**: burn time now = items.xml `FuelValue` seconds per item (RE items.md GetFuelValue; coal 100 s, wood 1-5 s) via a `FuelResolver` Game wires from the items table; 10 s remains the offline fallback |
| R2 | `ecs/world.zig` + `ecs/systems.zig` corpse dwell | fallback 300/30 s | A | **FIXED**: fallback = stock `EntityAlive.timeStayAfterDeath` default 5 s (RE entity-ai.md 3157); XML values 30/300 flow via `class_id.time_stay` when declared |
| R3 | `ecs/inventory.zig:148` armorMitigation | flat 10 %/piece, 50 % cap | A | **FIXED (config-exposed)**: `[rules.combat] armor_mitigation_per_piece` / `armor_mitigation_cap` make the approximation tunable; the full stock chain (passive-effects ModifyValue, items.md IL=304) stays an RE-blocked engine feature |
| R4 | `ecs/aidirector.zig:361-362,403-404,428-430` director drips | night 18-28 m / day 30-40 m / animal 20-45 m, cds 45/120/60 s | A/B | **FIXED**: rings aligned to stock (animal 48-70 m cAnimalMin/MaxDistance, enemy 28-54 m cEnemyMin/MaxDistance, spawning.md); the periodic drips are zdtd mechanics exposed as `[rules.director]` fields |
| R5 | `ecs/aidirector.zig:378,675-676` | bloodmoon_cd 6 s, bm_mul 1.5 | B | **FIXED**: `[rules.director] bloodmoon_wave_cd` / `bloodmoon_hp_mult` |
| R6 | `ecs/systems.zig:1906-1921` vehicle tuning | throttle 14, steer 100, coast 0.8, fuel 0.02 | B | **FIXED**: `[rules.vehicle]` group (accel_mps2, reverse_frac, coast_decay, steer_deg_per_s, min_turn_speed_frac, fuel_per_m) |
| R7 | `ecs/inventory.zig:348` container open range | 8 blocks / 64.0 | B | **FIXED**: `[rules.world] container_open_range` (ECS-visible reach cap) |
| R8 | `ecs/powerblocks.zig:96,100` battery proxy | watts ×10, cap ×0.5 | B | **FIXED**: named consts `battery_capacity_fallback_scale` / `battery_initial_charge_frac` with provenance (proxy until the power-feature milestone; real battery tuning is a separate track) |
| R9 | `ecs/aidirector.zig:297-313` difficulty tables | GameDifficulty/ZombieMove scales | A | **FIXED**: named consts `hp_scale_by_difficulty` / `move_scale_by_mode` with provenance (stock tier semantic; numbers zdtd-tuned, no pinned RE table) |


tuning, container range, armor mitigation); data fixes: fuel burn, corpse
dwell). All R1-R9 rows are now fixed; nothing remains open from the re-scan.

**Value-level sweep (2026-08-20, paths beyond the game shards):** scanned
src/server (non-game), persist, plugin, util, apm, main for stock-data
hardcodes. Result: no Bucket A hardcode (every name-keyed lookup resolves
through a loader table; config.zig stock serverconfig key spellings verified
against V3.1.0). Follow-ups: **B1** fixed — GSI `world_size` was a hardcoded
6144, now `Game.worldSize()` reads the DTM `HeightMapSize` (fallback 6144);
**B2** fixed — dead `consoleSetTime` ("night" 22.0, disagreeing with the
RE-cited settime parse) deleted; **B3/B4** noted (admin-only vehicle-kind
heuristic with vehicles.xml fallback; `kill` 99999 admin literal), no change.

**PLUGIN_DEV expressibility audit re-run (2026-08-20):** the table in
docs/PLUGIN_DEV.md was re-verified against the current hook surface (16 hooks,
6 reference modules). Every discretionary behavior the boundary can carry is
plugin-covered or a documented boundary-extension candidate (guard policy
ladder and trader/vehicle announcements are the two "Not yet" rows, each with
the correct disposition: extend the boundary, do not add native code). The
native additions of this session were data-driven fixes (A34/A39/R1/R2,
nav_objects gate) and `[rules]` config fields (R1-R7) - none is discretionary
behavior, so no new plugin rows were required. No undocumented native
discretionary behavior exists.

## Validation

`git status` clean at HEAD 3b06680 before this file. Docs-only change this
pass; `zig build` and `zig build test` unaffected. No code fixes landed (no
small safe default-preserving P0/P1 existed). Loader/balance changes from the
plan above must keep `zig build test` green and get a loadgen smoke when they
touch spawn paths.
