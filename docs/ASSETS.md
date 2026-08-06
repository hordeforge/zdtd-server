# Stock config assets

Policy hub for loading game data from the operator's install (`--game-dir`).

## Config XML + overrides

| Flag | Role |
|---|---|
| `--game-dir` | Install root → `$game/Data/Config/*` |
| `--config-dir` | Replace Config root (full files) |
| `--config-overrides DIR` | **Repeatable.** Dir of xpath patch XMLs; files applied in **filename order** (then dir order). Clean-room subset of stock XmlPatcher: `set`/`setattribute`, `remove`, `append` with simple `/tag[@attr='v']/.../@attr` paths. |

Optional root: `<configs file="blocks.xml">…</configs>`. If `file=` omitted, target is inferred from the first xpath tag (`/blocks/…` → blocks.xml).

Patched bytes are written under `.zdtd_cfg_cache/` (cwd, gitignored) then parsed by existing loaders. Not a Harmony/ModAPI host.
Implements AGENTS.md rule 13: **no hand-copied catalogs** when a loader exists
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
| `maxdamage.zig` | blocks.xml, materials.xml + AssignIds dump | HP, storage, power watts/Class, MaxFuel, OutputPerFuel/Charge/Stack, id↔name |
| `blocks.zig` | blocks.xml + AssignIds | solid flags; **ids from dump only** |
| `block_textures.zig` | blocks.xml Texture | defaults; terrain >255 not on chunk channel |
| `painting.zig` | painting.xml | paint id ↔ TextureId |
| `biome_layers.zig` | biomes.xml layers + weather groups | column fill; ordered `<weather>` groups per biome (name/prob/duration/delay/ranges) drive `world/weather.zig`; wire params keep the raw 0..100 XML scale (the client divides) |
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
| `buffs.zig` | buffs.xml | metadata + passive_effect rows |
| `progression.zig` | progression.xml | level curve + attributes/perks catalog |
| `vehicles.zig` | vehicles.xml | kind, velocityMax, torque, fuel |
| `storage_pairs.zig` | blocks.xml DowngradeBlock | Closed↔Open storage ids |
| `signs.zig` | Prefabs `*_signs.xml` | world signs |
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

## WorldInfo and client assets

Terrain MicroSplat needs client-local `Data/Worlds/<level>/splat*.png`. That
requires WorldInfo `fixedSizeCC=false` (FromRaw client provider). See
`WIRE_CHUNK.md` and research `protocol-packages.md` §4.2.

## Shared I/O and load helpers (do not copy-paste)

| Module | Use |
|---|---|
| `src/util/io_fs.zig` | `readFileAll` / `writeFile` / `fileExists` / mkdir / delete (via `std.Io`) |
| `src/assets/paths.zig` | `resolveConfigXml`, `tryLoadConfig(file, T, loadFn, …)` |
| `src/assets/xml_util.zig` | `stripComments`, `attr`, `propertyValue`, `nextElement`, `putDupeKey` |

New loaders: call these; do not reimplement open/read or config path resolution.

## Extending

1. Add `src/assets/<name>.zig` with `loadFromPath` + `tryLoad` via `paths.tryLoadConfig`.
2. Attach on `Game.init`; never re-parse XML on the tick path.
3. Resolve ids through AssignIds / existing tables.
4. Unit test with install path or `SkipZigTest` if missing.
5. Update this doc + STATUS when surface changes.
