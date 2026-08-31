# Stock config assets

> **What this is:** policy and loader map for stock XML, AssignIds and patched catalogs - how `src/assets/*` turns `--game-dir` into the ids and tables the sim and wire builders consume.

> **Related:** [ARCHITECTURE §10](ARCHITECTURE.md#10-config-assets-and-persistence) · [MAPS](MAPS.md) · [WORLDGEN](WORLDGEN.md) · [PROVENANCE](PROVENANCE.md) · [ZIG_CLONE](ZIG_CLONE.md) · [STATUS](STATUS.md) · [wire/PACKAGES](wire/PACKAGES.md) · [AUTHORITY](AUTHORITY.md)

Policy hub for loading game data from the operator's install (`--game-dir`). Stock content is data loaded at init and never hardcoded; see [ARCHITECTURE §10](ARCHITECTURE.md#10-config-assets-and-persistence) for the config precedence and persistence plane.

## Config XML + overrides

| Flag | Role |
|---|---|
| `--game-dir` | Install root → `$game/Data/Config/*` |
| `--config-dir` | Replace Config root (full files) |
| enabled manifest mod `Config/` | Each enabled self-contained `mods/<name>/Config/` XPath patch dir is applied after stock `GAME_DIR/Mods/*/Config` dirs (and before operator overrides). A mod without `Config/` is a no-op; disabled/blacklisted/replaced manifests contribute nothing. |
| `--config-overrides DIR` | **Repeatable.** Dir of xpath patch XMLs; files applied after stock + enabled manifest mod dirs, in **filename order** (then dir order). Clean-room subset of stock XmlPatcher: `set`/`setattribute`, `remove`, `append` with simple `/tag[@attr='v']/.../@attr` paths. |

Optional root: `<configs file="blocks.xml">…</configs>`. If `file=` omitted, target is inferred from the first xpath tag (`/blocks/…` → blocks.xml). Loader: `src/assets/xml_patch.zig`.

Patched bytes are written under `.zdtd_cfg_cache/` (cwd, gitignored) then parsed by existing loaders. Not a Harmony/ModAPI host.
Implements AGENTS.md rule 15: **no hand-copied catalogs** when a loader exists
or should.

## Paths

| Flag | Role |
|---|---|
| `--game-dir` | Install root → `$game/Data/Config/*` |
| `--map` | Stock world; may probe sibling Config |
| `--config-dir` | Explicit `Data/Config` |
| `--quests` | Explicit quests.xml (fixture or stock) |

Offline without game-dir: tiny `builtin_*` tables + bundled AssignIds dump for
tests only. Production play always uses `--game-dir`.

```bash
GAME="$HOME/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server"
zdtd --game-dir "$GAME" --world-name Navezgane --world worlds/nav_save
```

## Id spaces (critical)

| Space | Source | Never |
|---|---|---|
| Block.blockID | Client AssignIds Postfix dump | XML order, sequential counters |
| Item type id | AssignIds ItemsStartHere + leftover | Invented ECS-only ids on the wire |
| Paint id (0–255) | `painting.xml` | Truncating TextureId >255 onto channel |
| Biomemap id | `biomes.xml` `<biomemap id>` | Raw PNG R channel |
| TE type enum | RE / IL | Guessed numbers without cite |

Resolve: **name → id** via `maxdamage.idByName` (AssignIds merge) after XML
property load. Dump must match the **connected client** version (STATUS pin).

## Loaders (`src/assets/`)

| Module | Stock file | Notes |
|---|---|---|
| `maxdamage.zig` | blocks.xml, materials.xml + AssignIds dump | HP, storage, power watts/Class, MaxFuel, OutputPerFuel/Charge/Stack, turret combat stats (MaxDistance/EntityDamage/BurstFireRate/BurstRoundCount), id↔name |
| `blocks.zig` | blocks.xml + AssignIds | solid flags; **ids from dump only** |
| `block_textures.zig` | blocks.xml Texture | defaults; terrain >255 not on chunk channel |
| `painting.zig` | painting.xml | paint id ↔ TextureId |
| `noise.zig` | sounds.xml | `<Noise>` rows keyed by SoundDataNode name: AI noise volume/time/muffle/heat per sound group (movement-noise model, RE entity-ai.md PlayerStealth) |
| `biome_layers.zig` | biomes.xml layers + weather groups | column fill (leftover cells reuse the stack's own ids, never AssignIds pins); ordered `<weather>` groups per biome (name/prob/duration/delay/ranges) drive `world/weather.zig`; wire params keep the raw 0..100 XML scale (the client divides) |
| biomap colors | biomes.xml biomemapcolor | `world/biomes.zig` ColorTable |
| `items.zig` | items.xml | stacks, prices, stock type, placeable block |
| `entities.zig` | entityclasses.xml | hash, HP, loot |
| `entitygroups.zig` | entitygroups.xml | director / spawn groups |
| `spawning.zig` | spawning.xml | biome spawn rules + `<entityspawner>` groups (scouts) |
| `gamestages.zig` | gamestages.xml | player/party stage math, spawner stage ladders, POI group aliases |
| `loot.zig` | loot.xml | groups + containers + `lootprobtemplate` stage bands |
| `recipes.zig` | recipes.xml | craft graph |
| `quests.zig` | quests.xml | catalog |
| `traders.zig` | traders.xml | groups + rolls |
| `buffs.zig` | buffs.xml | duration, stack_type, update_rate, remove_on_death + passive_effect rows |
| `progression.zig` | progression.xml | level curve + attributes/perks catalog |
| `vehicles.zig` | vehicles.xml | kind, velocityMax, torque, fuel |
| `storage_pairs.zig` | blocks.xml DowngradeBlock | Closed↔Open storage ids |
| `signs.zig` | Prefabs `*_signs.xml` | world signs |
| `blocks_nim.zig` | Prefab `<name>.blocks.nim` | local-id → block-name remap for `.tts` types that use local indices rather than AssignIds |
| `npc.zig` | npc.xml | npc_info entries: trader entity class / display name → traders.xml `<trader_info>` id + quest_list |
| `item_modifiers.zig` | item_modifiers.xml | mod attachment tag gates (RE items.md ItemModificationsFromXml); a mod's `installable_tags` / `RemoveOnPlace` surface |
| `modlets.zig` | `Mods/<name>/Config` XPath patches | stock ModManager subset for XML-only modlets (PRD 0003): patched catalogs + join-phase config sync; no DLL / IModApi hosting |
| `map_atlas.zig` | generated from `ta_*.xml` | texture-atlas minimap colors (gen_atlas_zig.py; do not hand-edit) |
| `sandbox.zig` + `sandbox_data.zig` | sandbox options (RE sandbox-options §3) | 165-option codec + value-set tables (gen_zig_tables.py) |
| `sandbox_presets.zig` | `Data/Sandbox/sandbox_presets` TextAsset | GameDifficulty preset ladder, comptime from the embedded asset |
| `wire/te_types.zig` | RE enum (not XML) | named TileEntityType constants |

Wire/sim code must not pin numeric block ids except dump-validated offline pins
in `assignids_comptime.zig` (tests / no-game-dir fallback).

## Fail closed

| Situation | Behavior |
|---|---|
| AssignIds miss for deco tree | Skip that DecoObject |
| Unknown placeable item | `itemToBlock` → 0 (not placeable) |
| Encode missing catalog row | Omit package / stock empty form |
| Dump version skew vs client | Prefer suppress deco over NRE |
| Empty biome layer stack | Fail closed (air); never paint AssignIds pins |
| biomes.xml missing pine_forest | Default column via idByName; pins only if lookup misses |
| Unknown item after game-dir | stack 1 / not armor / not placeable (never builtin id aliases) |
| Storage/chest id after game-dir | AssignIds `idByName` only; comptime pins offline |

## WorldInfo and client assets

Terrain MicroSplat needs client-local `Data/Worlds/<level>/splat*.png`. That
requires WorldInfo `fixedSizeCC=false` (FromRaw client provider). See
`wire/WIRE_CHUNK.md` and research `protocol-packages.md` §4.2.

## Shared I/O and load helpers (do not copy-paste)

| Module | Use |
|---|---|
| `src/util/io_fs.zig` | `readFileAll` / `writeFile` / `fileExists` / mkdir / delete (via `std.Io`) |
| `src/assets/paths.zig` | `resolveConfigXml`, `tryLoadConfig(file, T, loadFn, …)` |
| `src/assets/xml_util.zig` | `stripComments`, `attr`, `propertyValue`, `nextElement`, `putDupeKey` |
| `src/assets/xml_patch.zig` | XPath patch application for `--config-overrides` / modlets |
| `src/assets/unity_hash.zig` | Unity string hash (fed by stock names; never hardcode the numeric result) |
| `src/assets/root.zig` | package facade |

New loaders: call these; do not reimplement open/read or config path resolution.

## Extending

1. Add `src/assets/<name>.zig` with `loadFromPath` + `tryLoad` via `paths.tryLoadConfig`.
2. Attach on `Game.init`; never re-parse XML on the tick path.
3. Resolve ids through AssignIds / existing tables.
4. Unit test with install path or `SkipZigTest` if missing.
5. Update this doc + STATUS when surface changes.
