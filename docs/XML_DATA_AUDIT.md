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
| 2 | Turret power draw `25` W (`ecs/world.zig` spawnTurret) | `blocks.xml` autoTurret `RequiredPower=15` | `spawnTurretEx(x,y,z,watts)`; Game `turretWatts()` = `maxdamage.wattsByName("autoTurret")`; player C2S + save restore pass it |
| 3 | Saved vehicle restore HP `200` (`server/persist.zig`) | `vehicles.xml` per-kind `max_hp` (gyro 250, 4x4 300) | restore passes `vehicles.byKind(kind).max_hp` |
| 4 | Airdrop loot container `"supplyCrate"` (`server/game/tick.zig`) — no such stock name, crates rolled empty | `loot.xml` `airDrop` (+ `entityclasses.xml` `LootList`) | renamed to `"airDrop"` |
| 5 | Item→block place map `resourceWood→frameShapes:cube`, `resourceCobblestones→cobblestoneShapes:cube` (`ecs/inventory.zig`, `server/game/hooks.zig`) — invented; b14 defines no `Placeable` for them | `items.xml` `Blockname` (torch → `wallTorchLightPlayer` etc.) | `items.zig` parses `Blockname` into `ItemDef.place_block_name`; `hooks.placeBlockId` places only items with a `Blockname`, resolved via AssignIds; removed dead `itemToBlockResolved` |
| 6 | Starter kit (4 items + counts) hardcoded in `ecs/world.zig` spawnPlayer | none — stock defines the kit in code, so it is server policy | moved to `zdtd.toml` `spawn_starter_kit` (config level, per ADR 0010); Game parses once, applies at fresh join, resolves names through items.xml, fail-closed on unknown names |

## Offline fallbacks (allowed last resort, code bucket)

All gated on `--game-dir` absence or RE/wire facts; none of these ship XML-mode
values to a connected stock client:

- `assets/assignids_comptime.zig` — bundled AssignIds dump pins (tests / no-game-dir).
- builtin tables in `assets/` (`items.zig`, `entities.zig`, `loot.zig`, `buffs.zig`,
  `quests.zig`, `traders.zig`, `maxdamage.zig`, `biome_layers.zig`) and the ECS
  `class_table` defaults (`ecs/world.zig`) — offline sim only; XML tables replace
  them when a game-dir loads. Offline values that stock XML defines were aligned
  to stock in this audit (e.g. builtin zombie HP 40 → 200 = `^healthNormal`).
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

- `ecs/rules.zig` survival `Progression` defaults are documented placeholder
  numbers (WORK_PLAN T16) — the real values ship as data in `buffs.xml` but are
  not yet wired to the sim. They are a config floor, not stock-value claims.
- `loot.zig` `rollContainer` falls back to fabricated `resourceScrapIron × 5`
  when a container rolls empty; stock yields an empty container (fail-closed
  change is a separate behavioural decision).
