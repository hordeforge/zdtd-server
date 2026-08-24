# XML data audit: no stock `Data/Config` values hardcoded in server code

Audit of every `.xml` file in the stock game's `Data/Config` (target **V3.1.0 b14**,
operator install at `--game-dir`) against the Zig server source (`src/`), so that
no value the stock XML defines is hardcoded in the server implementation.

Load-order priority for any value the server needs (ADR 0010 / AGENTS rule 15):

1. **XML first** — `src/assets/*` loaders parse the stock file at init
   (`--game-dir` / `--config-dir`).
2. **Config** — server policy (no stock XML source) lives in `zdtd.toml`
   (`util/toml_bind.zig` walks the `Config`/`Rules` struct; adding a field
   auto-configures it).
3. **Mode packs** — `modes/*.toml` overlay the sim `Rules` floor.
4. **Source code — last resort only** — documented offline fallbacks when no
   game-dir is present, and wire RE constants. Everything in this bucket is
   gated on `--game-dir` absence (builtin tables) or is a wire/protocol fact.

Re-run the audit: `make check-xml-audit` (or `python3 tools/check_xml_audit.py`)
— the deterministic gate re-extracts stock names from the operator's
`Data/Config/*.xml` and fails on any stock-name literal in non-loader, non-wire,
non-test server code that is not in its allowlist, and on any un-audited XML
file. The manual pass below (per-file table + findings) is the written record;
the script is the machine check.

## Per-file coverage

`F` = forwarded verbatim to clients via `NetPackageConfigFile` (LoadLocal; the
client parses it — server never reads values from it). `-` = not consumed by the
server (client-side or unimplemented surface).

| Data/Config file | Loader (`src/assets/`) | Server consumes |
|---|---|---|
| archetypes.xml | — | `-` (client-side quest objective templates) |
| biomes.xml | `biome_layers.zig` (weather groups, layers), `world/biomes.zig` (biomemap colors) | yes |
| blockplaceholders.xml | — | `-` |
| blocks.xml | `blocks.zig`, `maxdamage.zig` (HP/watts/Class/id↔name), `storage_pairs.zig`, `block_textures.zig` | yes |
| buffs.xml | `buffs.zig` | yes |
| challenges.xml | — | `-` (no challenge wire; client-side) |
| dialogs.xml | — | `F`/`-` |
| dmscontent.xml | — | `F`/`-` |
| entityclasses.xml | `entities.zig` (HP, loot, speeds, explosion, XP) | yes |
| entitygroups.xml | `entitygroups.zig` | yes |
| events.xml | — | `-` |
| gameevents.xml | — | `-` |
| gamestages.xml | `gamestages.zig` | yes |
| item_modifiers.xml | — | `F`/`-` (set/quality bonuses are client-side) |
| items.xml | `items.zig` (stack, econ, fuel, eat, distraction, **Blockname**) | yes |
| loadingscreen.xml | — | `-` (client UI) |
| loot.xml | `loot.zig` | yes |
| materials.xml | `maxdamage.zig` (material props) | yes |
| misc.xml | — | `-` |
| music.xml | — | `-` (client) |
| nav_objects.xml | — | class names passed through as strings (client resolves; quests.xml `nav_object` passthrough) |
| npc.xml | `npc.zig` | yes |
| painting.xml | `painting.zig` (paint id ↔ TextureId) | yes |
| physicsbodies.xml | — | `-` (client physics) |
| progression.xml | `progression.zig` | yes |
| qualityinfo.xml | — | `F`/`-` (quality rolls come from loot.xml `loot_quality_template` bands) |
| quests.xml | `quests.zig` | yes |
| recipes.xml | `recipes.zig` | yes |
| rwgmixer.xml | — | `-` (procedural worldgen is zdtd-owned; RWG maps load as DTM) |
| sandbox_overrides.xml | `sandbox_data.zig` / `sandbox.zig` | yes |
| shapes.xml | — | `-` (client) |
| signs.xml | `signs.zig` (prefab `*_signs.xml`) | yes |
| sounds.xml | — | `-` (client) |
| spawning.xml | `spawning.zig` | yes |
| subtitles.xml | — | `-` (client) |
| traders.xml | `traders.zig` | yes |
| twitch.xml | — | `F`/`-` |
| twitch_events.xml | — | `F`/`-` |
| ui_display.xml | — | `-` (client) |
| utilityai.xml | — | `F`/`-` (AI is RE-derived) |
| vehicles.xml | `vehicles.zig` | yes |
| videos.xml | — | `-` (client) |
| weathersurvival.xml | — | `F`; server weather params driven by `biomes.xml` `<weather>` groups; TemperatureSurvival gate echoed via sandbox code |
| worldglobal.xml | — | `-` (day length etc. from serverconfig) |
| XUi_* / XML.txt / .csv / .txt | — | `-` (client UI / metadata) |

## Violations fixed in this audit

All six were production paths bypassing a loader (or wrong stock data) with a
hardcoded literal. Verified against the b14 install before changing.

| # | Was (hardcoded) | Stock source | Fix |
|---|---|---|---|
| 1 | Player spawn/respawn HP `100` (`ecs/world.zig` spawnPlayer/respawnPlayer) | `entityclasses.xml` playerMale `HealthMax` (base_set 100) | `entities.defaultPlayer()` + class_table[0] filled from XML; spawn/respawn read `class_table[player_class_id].max_hp` |
| 2 | Turret power draw `25` W (`ecs/world.zig` spawnTurret) | `blocks.xml` autoTurret `RequiredPower=15` | `World.turret_watts_fn` wired to `maxdamage.wattsByName("autoTurret")`; the ECS `spawnTurret` draws the resolved 15 W |
| 3 | Saved vehicle restore HP `200` (`server/persist.zig`) | `vehicles.xml` per-kind `max_hp` (gyro 250, 4x4 300) | restore passes `vehicles.byKind(kind).max_hp` |
| 4 | Airdrop loot container `"supplyCrate"` (`server/game/tick.zig`) — no such stock name, crates rolled empty | `loot.xml` `airDrop` (+ `entityclasses.xml` `LootList`) | renamed to `"airDrop"` |
| 5 | Item→block place map `resourceWood→frameShapes:cube`, `resourceCobblestones→cobblestoneShapes:cube` (`ecs/inventory.zig`, `server/game/hooks.zig`) — invented; b14 defines no `Placeable` for them | `items.xml` `Blockname` (torch → `wallTorchLightPlayer`, candle → `candleWallLightPlayer`) | `items.zig` parses `Blockname` into `ItemDef.place_block_name`; `placeBlockId` resolves only that name via AssignIds and drops the invented wood/cobble map (frameShapes:cube is not an item in b14) |
| 6 | Starter kit (4 items + counts) hardcoded in `ecs/world.zig` spawnPlayer | none — stock defines the kit in code, so it is server policy | moved to `zdtd.toml` `spawn_starter_kit` (config level, per ADR 0010); Game parses once, applies at fresh join, resolves names through items.xml, fail-closed on unknown names |

## Offline fallbacks (allowed last resort, code bucket)

All gated on `--game-dir` absence or RE/wire facts; none of these ship XML-mode
values to a connected stock client:

- `assets/assignids_comptime.zig` — bundled AssignIds dump pins (tests / no-game-dir).
- builtin tables in `assets/` (`items.zig`, `entities.zig`, `loot.zig`, `buffs.zig`,
  `quests.zig`, `traders.zig`, `maxdamage.zig`, `biome_layers.zig`) and the ECS
  `class_table` defaults (`ecs/world.zig`) — offline sim only; XML tables replace
  them when a game-dir loads. Offline values that stock XML defines were aligned
  to stock in this audit: the `entities.zig` builtin defs ship stock HP
  (zombie 200 = `^healthNormal`); the ECS offline `class_table` rows keep the
  documented 40 fail-closed floor, and live spawns resolve classes through the
  builtin defs, so the effective offline value is stock.
- Stock-name selection keys resolved through a loaded table (never values):
  `buffInjuryBleeding` (`hooks.zig`), `bloodMoon` (`weather.zig`), `Scouts*`
  (`aidirector.zig`), `autoTurret` (`game.zig`), `airDrop` (`tick.zig`),
  `supply_drop` (nav class), `keystoneBlock` (land claim), `cntWoodenChestClosed`
  (`replicate_te.zig`), the `bedroll*` set (`game.zig` isBedroll — stock defines
  no is-bedroll property, the name list resolves through AssignIds), the
  `*bank`/`switch`/`dartTrap`/`bladeTrap` power-block pins (`powerblocks.zig`),
  `ZombiesAll` (director default group), `foodCanChili` (load probe), trader
  currency `casinoCoin` (offline builtin map), and the
  biome-name/`terr*` resolve keys (`store.zig`, `init_assets.zig`,
  `biomes.zig`).
- **Machine gate:** `tools/check_xml_audit.py` (part of `make check` via
  `check-xml-audit`) re-extracts these names from the game's XMLs and fails on
  any stock-name literal in non-loader, non-wire, non-test code that is not in
  its allowlist. Adding a new selection key to server code requires adding it
  to the script's `ALLOWLIST` (and ideally this list).
- Wire RE constants: tick rate, package ids, hashes from stock names, biome
  `terr*` id pins in `store.zig`/`init_assets.zig` (dump-only), `seedChestBlockId`
  pin fallback (`replicate_te.zig`).

## Known gaps (not hardcodes, tracked elsewhere)

- `ecs/rules.zig` survival `Progression` floors (base food/water depletion,
  well-fed regen, stamina rates): no stock XML row carries the base rates
  (stock decays them engine-side via `Stat.Tick`, activity-scaled), so they
  are operator policy by design. The buffs.xml-derived thresholds and damage
  ARE wired: `tickSurvival` (`game/tick.zig`) consumes `buffs.survival()`
  (hunger/thirst stage fractions, starvation/dehydration HP/s,
  `StaminaChangeOT` penalty) whenever `buffs.xml` is present.
- `loot.zig` `rollContainer` falls back to fabricated `resourceScrapIron × 5`
  when a container rolls empty; stock yields an empty container (fail-closed
  change is a separate behavioural decision).

## Deferred XML-data items (recorded with reason)

From the value-level audit (2026-08-25); each is either unreachable in stock
play or needs a boundary/plumbing change before it can carry stock data. None
ships a wrong value to a connected client.

| Item | Why deferred |
|---|---|
| Melee reach per hand item (`Range` 1.6 / `MaxRange` 2.4 in items.xml) | `attack_range_sq` is the documented floor; the AI break/destroy gates read it and lack per-class slot plumbing. 2.0 m sits between the stock values. |
| loot.xml `ignore_loot_abundance` / `unique_item` / `abundance_type` / `unmodified_lootstage` / `open_time` | Carriers are twitch-only containers (unreachable), except `questRewardSkillMagazines unique_item`; the flag set needs a roll-path change. |
| traders.xml `rent_cost` / `rent_time` / `player_owned` | The rent mechanic is unimplemented; `player_owned` pricing is RE-derived but unapplied. |
| quests.xml `max_quest_tier` / `quests_per_tier` | Parsed but unused: no trader tier-offer loop consumes them yet. |
| progression.xml `skill_points_per_level`, attribute/perk costs | The skill-point/perk ledger is pending (ADR 0023); no purchase path exists. |
| painting.xml id ↔ TextureId table | Loaded, zero readers: the chunk paint channel carries the raw texture; the client resolves paint ids. |
| signs.xml default library `[D]` | Only prefab `*_signs.xml` libraries load; the stock `[D]` library (incl. the mandatory zero-guid sign) is client-side too. |
| materials.xml `Experience` | No block-harvest/repair XP exists (kill XP only); loader gap = missing feature. |
| vehicles.xml `motorTorque_turbo` | Parsed but unused: accel is the documented zdtd-owned `[rules.vehicle] accel_mps2` proxy (stock dedi has no physics sim). |
| npc.xml `<factions>` / `quest_faction` | Server has no NPC AI; `quest_faction` is also missing from the quest wire field. |
| biomes.xml biome `difficulty` / `buff` attrs | Not consumed by worldgen or spawn scaling. |
