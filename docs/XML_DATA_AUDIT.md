# XML data audit: no stock `Data/Config` values hardcoded in server code

> **What this is:** the audit that no stock `Data/Config` value ships hardcoded in `src/` (per-file coverage plus the `make check-xml-audit` machine gate).
> **Related:** [PROVENANCE.md](PROVENANCE.md) · [ASSETS.md](ASSETS.md) · [GAME_OPTIONS.md](GAME_OPTIONS.md) · [STATUS.md](STATUS.md)

Audit of every `.xml` file in the stock game's `Data/Config` (target **V3.1.0 b14**,
operator install at `--game-dir`) against the Zig server source (`src/`), so that
no value the stock XML defines is hardcoded in the server implementation.

Load-order priority for any value the server needs (ADR 0010 / AGENTS rule 15):

1. **XML first** — `src/assets/*` loaders parse the stock file at init
   (`--game-dir` / `--config-dir`).
2. **Config** — server policy (no stock XML source) lives in `zdtd.toml`
   (`util/toml_bind.zig` walks the `Config`/`Rules` struct; adding a field
   auto-configures it).
3. **Preset packs** — `presets/*.toml` overlay the sim `Rules` floor.
4. **Source code — last resort only** — documented offline fallbacks when no
   game-dir is present, and wire RE constants. Everything in this bucket is
   gated on `--game-dir` absence (builtin tables) or is a wire/protocol fact.

Re-run the audit: `make check-xml-audit` (or `python3 tools/check_xml_audit.py`)
— the deterministic gate re-extracts stock names from the operator's
`Data/Config/*.xml` and fails on any stock-name literal in non-loader, non-wire,
non-test server code that is not in its allowlist, on any un-audited XML file,
and (value-level scan, 2026-08-25) on any pinned stock numeric literal
(`VALUE_ITEMS` in the script) appearing in a production file outside its
documented allowlist. The manual pass below (per-file table + findings) is the
written record; the script is the machine check.

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
| item_modifiers.xml | `item_modifiers.zig` (mod attachment tag gates, RE items.md ItemModificationsFromXml) | yes |
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
| sounds.xml | `noise.zig` (AI noise volume/time/muffle/heat per SoundDataNode) | yes |
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
  currency `casinoCoin` (offline builtin map), `forge` (`craft.zig`
  onStationCraftDone — the stock TileEntityForge ding gate; other
  workstations are silent, RE tile-entities-power.md), and the
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
- **Modlet-added items** (e.g. `mods/parachute/Config/items.xml` adds the
  `parachute` item, ADR 0037): these are operator-installed game data patched
  into the catalog before loading (PRD 0003), never hardcoded in `src/`; the
  item's wire presence needs the same patched items.xml on the client (the
  mod README documents the pairing).

## Deferred XML-data items (recorded with reason)

From the value-level audit ([archive/HARDCODE_AUDIT_2026-08-25.md](archive/HARDCODE_AUDIT_2026-08-25.md)); each is either unreachable in stock
play or needs a boundary/plumbing change before it can carry stock data. None
ships a wrong value to a connected client.

| Item | Status |
|---|---|
| Melee reach per hand item (`Range` 1.6 / `MaxRange` 2.4 in items.xml) | **FIXED (2026-08-25)** — parsed into `ItemDef.melee_range`; the AI gates read the per-class range (`systems.meleeRangeSq`) with the Rules floor as fallback. |
| loot.xml `ignore_loot_abundance` / `unique_item` / `abundance_type` / `unmodified_lootstage` / `open_time` | **FIXED (2026-08-25)** — all five parsed into `LootContainer`; `ignore_loot_abundance` skips the abundance scale and `unique_item` dedups per fill (questRewardSkillMagazines). `abundance_type` multipliers and the `unmodified_lootstage` stage chain stay Game-side/RE-tracked; `open_time` is client display. |
| signs.xml default library `[D]` | **FIXED (2026-08-25)** — `Data/Config/signs.xml` loads as the `[D]` library (mandatory zero-guid Default Sign) alongside the prefab libraries. |
| quests.xml `max_quest_tier` / `quests_per_tier` | **FIXED (2026-08-25)** — the trader offer path clamps to `max_quest_tier` and caps the per-window offers at `quests_per_tier`. |
| traders.xml `rent_cost` / `rent_time` / `player_owned` | **CLOSED (2026-08-25)** — the rent mechanic already ships: `NetPackagePlayerVendingMachine` (c2s/quest.zig) implements the stock state machine (rent/extend/expire/clear, one machine per player, wallet sync, term from `rent_time`, cost from `rent_cost`), scenario-tested. `player_owned` is parsed; the owner-priced markup (`1 + Entry.Markup × 0.2`, RE loot-economy §5.2) is stock client-side pricing (XUiM_Trader; the wire carries base + owner markup, the server owns base price/sell). Server-side re-pricing would collide with the shared demand-spike markup (IncreaseMarkup), so it stays client-priced with the server owning the base — close-with-reason. |
| progression.xml `skill_points_per_level`, attribute/perk costs | **FIXED (2026-08-25)** — ADR 0023 ledger core: level-up awards `skill_points_per_level` (RE progression.md GrantPoints); `NetPackageEntitySetSkillLevelServer` purchases are server-validated (known skill, one level per request, max level, geometric `base × mult^(level-1)` cost from the parsed attr/perk tables, parent-attribute prereq) and echo `NetPackageEntitySetSkillLevelClient`; PlayerStats carries the SP balance. Residuals recorded: per-player persistence (runtime state), `unlock_entry` prereq chain (99 rows unparsed), 7 perk `override_cost`s unparsed, and the exact IL rounding of CalculatedCostForLevel is RE-tracked. |
| materials.xml `Experience` | **FIXED (2026-08-25)** — parsed into `maxdamage.material_exp`; player block breaks award `material.Experience` (harvest XP, RE items.md `AddLevelExp(material.Experience × count)`; dirt 2, hay 0) at both C2S destroy points. Repair/upgrade XP closed-with-reason: repair is client-applied (a damage-reduction set-block) with the `RepairExpMultiplier` item property unparsed, and no RE-pinned upgrade-XP amount exists — recording rather than guessing. |
| painting.xml id ↔ TextureId table | **CLOSED (2026-08-25)** — Loaded, zero readers: the chunk paint channel carries the raw texture; the client resolves paint ids. (close-with-reason). |
| vehicles.xml `motorTorque_turbo` | **CLOSED (2026-08-25)** — Parsed but unused: accel is the documented zdtd-owned `[rules.vehicle] accel_mps2` proxy (stock dedi has no physics sim). (close-with-reason). |
| npc.xml `<factions>` / `quest_faction` | **CLOSED (2026-08-25)** — Server has no NPC AI; `quest_faction` is also missing from the quest wire field. Close-with-reason (no NPC AI feature in scope). |
| biomes.xml biome `difficulty` / `buff` attrs | **CLOSED (2026-08-25)** — Not consumed by worldgen or spawn scaling. (close-with-reason). |
