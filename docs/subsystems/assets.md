# Stock asset and XML loading

This subsystem owns everything between the operator's install and the catalogs the
sim and wire builders read: locating `Data/Config/*.xml` and the bundled AssignIds
dump, stripping comments, applying modlet and operator XPath patches, parsing each
config into a typed table, resolving stock names to wire ids, and deciding what
happens when a name is not found. It also owns the Unity stable string hash used for
entity-class keys and the offline `builtin_*` tables used when no `--game-dir` is
present. It does not own the wire encoders or the world store, and it does not run on
the tick path: every catalog is built once during `Game.init` and only read
afterwards (src/server/game/init_assets.zig:1).

The package boundary is one-way and enforced: loaders may import `util` and pure
`ecs` types for catalog-to-sim mapping, and must not import `world`, `server`,
`wire`, `litenet` or `apm`; `ecs` must not import `assets` except for the one
comptime path, `ecs/rules.zig` reading the embedded `sandbox_presets.zig` ladder
(src/assets/root.zig:1-9).

Sources: [`src/assets/root.zig`](../../src/assets/root.zig),
[`src/assets/paths.zig`](../../src/assets/paths.zig),
[`src/assets/xml_patch.zig`](../../src/assets/xml_patch.zig),
[`src/assets/modlets.zig`](../../src/assets/modlets.zig),
[`src/assets/maxdamage.zig`](../../src/assets/maxdamage.zig),
[`src/assets/blocks.zig`](../../src/assets/blocks.zig),
[`src/assets/items.zig`](../../src/assets/items.zig),
[`src/assets/assignids_comptime.zig`](../../src/assets/assignids_comptime.zig),
[`src/server/game/init_assets.zig`](../../src/server/game/init_assets.zig).

## Path resolution and patch sources

`resolveConfigXml` prefers an explicit `--config-dir` over `<game_dir>/Data/Config`
and returns null when neither is set or the path does not fit the caller's buffer
(src/assets/paths.zig:11-24). Patch sources are two globals: enabled modlet `Config/`
dirs in stock mod order, then operator override dirs in filename order
(src/assets/paths.zig:30-34); `hasPatches` is the guard every loader checks before
paying for a merge (src/assets/paths.zig:80-82).

`readConfigXml` reads the base file, applies modlet patches, then operator overrides.
The asymmetry is deliberate: a modlet patch that fails to apply is fatal because it
would change AssignIds relative to the client, while a failed override keeps the
mod-patched bytes (src/assets/paths.zig:108-134). A missing base file means "catalog
absent"; permission, corruption and OOM errors are logged instead
(src/assets/paths.zig:95-105). `tryLoadConfigPatched` parses the merged bytes in
memory through the loader's `loadFromBytes`, or writes them to `.zdtd_cfg_cache/<file>`
under the working directory and calls the path-based loader
(src/assets/paths.zig:155-192).

## Load order from game-dir to catalog

`loadAssets` runs inside `Game.init` after the world directory is known and before
`initWorld`, so the world store can consume resolved terrain ids
(src/server/game/init_assets.zig:68, src/server/game/init_assets.zig:223). The order
is load-bearing:

1. Mods: root is `--mods-dir` when given, else `<game_dir>/Mods`, with the disabled
   list next to the world save; `modlets.install` returns the enabled `Config/` dirs,
   manifest mod dirs are appended, then `setModDirs` / `setOverrideDirs` fix base,
   stock, manifest, override order (src/server/game/init_assets.zig:90-142,
   src/assets/modlets.zig:484-489).
2. `config_files.buildCache` deflates the same merged bytes once for the join-phase
   `NetPackageConfigFile` sync (src/server/game/init_assets.zig:146-148,
   src/server/game/config_files.zig:71-74).
3. `traders.xml` before `quests.xml`, because quest reward rows resolve the currency
   item from the traders table (src/server/game/init_assets.zig:149-164).
4. `maxdamage.zig`: blocks.xml properties plus the AssignIds dump, with the bundled
   dump merged when the game-dir load fails; live terrain ids reach the world store
   from `idByName`, and prefab `.blocks.nim` local ids are remapped only when the id
   map is non-empty (src/server/game/init_assets.zig:166-245).
5. `blockplaceholders.xml`, `Localization.csv`, blocks.xml with the material
   `Collide` default applied after the parse, then items.xml and item_modifiers.xml as
   extra item classes in the same id space (src/server/game/init_assets.zig:265-345).
6. entities.xml, signs, recipes.xml, loot.xml, then entitygroups.xml before
   gamestages.xml, because every gamestage `<spawn group=…>` is checked against the
   entitygroup table and an unknown group is counted and logged, not fatal
   (src/server/game/init_assets.zig:368-552).
7. npc, painting, worldglobal, spawning, buffs, progression, vehicles, storage pair
   ids, biome colors and layers, block textures, then the power registry built from
   the blocks table, and a final sweep warning for every table still builtin or empty
   when a game-dir was given (src/server/game/init_assets.zig:553-868).

## Id assignment: AssignIds, never XML order

Block wire ids come only from the stock AssignIds result, never from the order rows
appear in blocks.xml (src/assets/blocks.zig:1-2). The resolver is injected as the
`IdByNameFn` callback so the loader never imports the dump table itself
(src/assets/blocks.zig:10-13, src/assets/blocks.zig:226).

The loader entry point (src/assets/blocks.zig:516-523):

```zig
/// Load blocks.xml names; resolve ids only via AssignIds (`id_by_name`).
/// Names missing from the dump are omitted (fail closed).
pub fn loadFromPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    id_by_name: IdByNameFn,
    ctx: ?*anyopaque,
) !BlockTable {
```

A name the dump does not carry is not omitted in practice: it is marked unassigned
and later given the first free id, terrain-shaped blocks scanning from 0 and the rest
from 0xff, in document order, the `assignLeftOverBlocks` algorithm a modded client
runs on the same document (src/assets/blocks.zig:625-626,
src/assets/blocks.zig:1039-1045, src/assets/blocks.zig:1061-1075,
src/assets/blocks.zig:34). The doc comment above `loadFromPath` still says such names
are omitted; the leftover pass contradicts it as of this reading
(src/assets/blocks.zig:1063-1069).

Items are the opposite case and that is stock behaviour: item types are sequential
from `ItemsStartHere + 1` in document order, matching `ItemClass.assignLeftOverItems`,
with `item_modifiers.xml` rows joining the same space after items.xml
(src/assets/items.zig:42-47, src/assets/items.zig:1109-1110,
src/assets/items.zig:556-562, src/assets/items.zig:1786-1788). Blocks and items share
no id space, so no catalog invents a parallel space that diverges from the client
(src/server/game/init_assets.zig:322-341).

`assignids_comptime.zig` holds named pins for offline and test use, validated at test
time against the bundled `src/assets/assignids_v314.embed.txt` dump, so a dump
refresh fails CI instead of silently moving a pin
(src/assets/assignids_comptime.zig:1-4, src/assets/assignids_comptime.zig:77-98).
That proves the pins agree with the bundled dump, not stock-client compatibility.

## The name to id map and fail-closed resolution

The runtime map lives on the maxdamage table: `id_by_name` holds every dump row and
`name_by_id` is its reverse, both filled by the same merge, and `idByName` / `idName`
are plain lookups returning null on a miss (src/assets/maxdamage.zig:66-71,
src/assets/maxdamage.zig:265-273).

`mergeAssignIdsDump` accepts `id<tab>name`, `id name` and `name=id` lines, skips
comments, and on duplicate ids keeps the first row (src/assets/maxdamage.zig:499-500,
src/assets/maxdamage.zig:516-533, src/assets/maxdamage.zig:544-549). A missing dump
file is optional and silent; any other IO error is printed
(src/assets/maxdamage.zig:501-513). `idNameCount` guards callers that negotiate ids
with the client: zero means no dump, so they must refuse to send rather than guess
(src/assets/maxdamage.zig:275-279).

Fail-closed behaviour is the rule, not an error path: an AssignIds miss for a deco
tree skips that DecoObject; a placeable item with no `Blockname` yields
`itemToBlock` 0, not placeable; an item name unknown after items.xml returns null
rather than aliasing a builtin id (src/assets/items.zig:491-493); an empty biome
layer stack fills as air, never an AssignIds pin; and an unknown block id returns the
safe default rather than a neighbouring row (src/assets/blocks.zig:259-280,
docs/ASSETS.md:95-102). Every cap here is a zdtd bound that logs once at the ceiling:
8192 block defs against stock's 6643 (src/assets/blocks.zig:15-26) and 8192 item defs
against stock's 1413 (src/assets/items.zig:11-15).

## Modlets and XPath patches

`modlets.zig` is a ModManager subset for XML-only modlets: it scans a mods root,
parses `ModInfo.xml` V2 (`Name`, `DisplayName`, `Version`, optional `Icon`), and
records whether the mod ships `Bundles/` or a top-level `.dll`. DLLs are never
loaded, bundles never read, and a code mod is logged as not hosted while its XML
patches apply (src/assets/modlets.zig:1-10, src/assets/modlets.zig:450-455).
Directory scan order is sorted lexicographically as a deterministic fallback;
stock's own scan order is unverified (src/assets/modlets.zig:132-134).

The patch source and persisted state (src/assets/modlets.zig:49-60):

```zig
/// One mod's patch source: `Config/` dir plus the issuing mod's absolute path
/// (the latter for `@modfolder:` include tokens, stock
/// `ReadPatchXmlWithFixedModFolders`).
pub const ModDir = struct {
    config_dir: []const u8,
    mod_path: []const u8,
};

/// File name of the persisted enable/disable state, next to the world save.
/// One disabled mod `Name` per line; `#` starts a comment; blank lines are
/// ignored; a name that is not installed is harmless (the mod may come back).
pub const state_file_name = "modlets_disabled.txt";
```

`isLoaded`, `versionByName` and `modPathByName` answer `<conditional>` `mod_loaded` /
`mod_version` tests and `@modfolder:` includes (src/assets/modlets.zig:493-518). A
disabled mod stays on the roster but its `Config/` dir is left out of the patch list,
and disabling persists through `setDisabled` into the state file
(src/assets/modlets.zig:290-331, src/assets/modlets.zig:442-449).

`xml_patch.zig` implements the stock XmlPatcher subset. Its module header lists the
supported ops and states that `<conditional>` is not implemented and fails closed
(src/assets/xml_patch.zig:5-18); that header is stale as of this reading, because
`applyPatchDoc` picks an `<if cond>` / `<else>` branch and skips a branch whose
expression the server cannot evaluate, continuing the boot rather than aborting it
(src/assets/xml_patch.zig:1224-1247, src/assets/xml_patch.zig:991). Target selection
order is an explicit `<configs file="x.xml">` (src/assets/xml_patch.zig:1144-1154),
then a patch file name matching the target config
(src/assets/xml_patch.zig:1155-1160), then the config inferred from the first XPath
tag through the root-name map (src/assets/xml_patch.zig:103-153,
src/assets/xml_patch.zig:1248-1264). The patch context carries the patch basename,
the issuing mod path for `@modfolder:` tokens, and the patch file's directory for
relative `<include>` resolution (src/assets/xml_patch.zig:621-633). An XPath the
subset cannot parse is counted and logged with its element skipped, so a partial
patch is visible instead of silent (src/assets/xml_patch.zig:1137-1142,
src/assets/xml_patch.zig:1307-1317).

`applyModDirs` tries `<mod>/Config/<configName>` first, `.xml` appended when the name
carries no extension, then every other XML in that mod's `Config/` in filename order
(src/assets/xml_patch.zig:1543-1593). `applyOverrideDirs` applies all override dirs in
dir order then filename order, and skips a file that fails rather than losing the
whole catalog (src/assets/xml_patch.zig:1472-1499, src/assets/xml_patch.zig:1504-1536).

## Loader modules, catalogs, provenance, persistence

Every loader follows the same shape: `loadFromPath` parses one file into an
arena-backed table, `tryLoad` resolves the path through `paths` and applies patches,
and the facade re-exports them all (src/assets/root.zig:11-50).

| Loader | Stock input | Catalog built |
|---|---|---|
| `maxdamage.zig` | blocks.xml, materials.xml, AssignIds dump | `Table`: HP, watts, power class, loot list, id to name (src/assets/maxdamage.zig:45-130) |
| `blocks.zig` | blocks.xml | `BlockTable` of `BlockDef` with drops, collide mask, TE features (src/assets/blocks.zig:104-232) |
| `items.zig` | items.xml | `ItemTable` of `ItemDef` plus the stock name/type lists (src/assets/items.zig:216, src/assets/items.zig:433-457) |
| `loot.zig` | loot.xml | `LootTable`: groups, containers, prob and quality templates (src/assets/loot.zig:435-448) |
| `quests.zig` | quests.xml | `quest.Catalog` via `parseCatalog` (src/assets/quests.zig:797, src/assets/quests.zig:1051-1060) |
| `entities.zig` | entityclasses.xml | `EntityTable` keyed by Unity hash and name (src/assets/entities.zig:182-216) |
| `entitygroups.zig` | entitygroups.xml | `GroupTable` of weighted `Group` lists (src/assets/entitygroups.zig:8-32) |
| `gamestages.zig` | gamestages.xml | spawner `Table` of `Spawner`, `Stage` and POI `Group` (src/assets/gamestages.zig:52-98, src/assets/gamestages.zig:218) |
| `spawning.zig` | spawning.xml | biome `Rule` rows and named `<entityspawner>` entries (src/assets/spawning.zig:15-60) |
| `localization.zig` | Localization.csv plus mod cells | `Table` of patched cells, deflated for the wire (src/assets/localization.zig:36-46) |
| `progression.zig` | progression.xml | `LevelCurve` and `Table` of attributes, perks, skills (src/assets/progression.zig:153-162) |
| `modlets.zig` | `Mods/<name>/ModInfo.xml` | mod roster plus enabled patch dirs (src/assets/modlets.zig:115-130, src/assets/modlets.zig:350) |
| `xml_patch.zig` | modlet `Config/`, override dirs | patched XML bytes, not a table (src/assets/xml_patch.zig:1132) |
| `assignids_comptime.zig` | bundled `assignids_v314.embed.txt` | offline pins, test-validated (src/assets/assignids_comptime.zig:9-46) |
| `unity_hash.zig` | stock entity class names, hashed not transcribed | `getStableHashCode` plus common `EntityClass.list` keys (src/assets/unity_hash.zig:10, src/assets/unity_hash.zig:32-33) |

Two provenance rules bind this package. Every `src/assets/*.zig` file needs a row in
`docs/PROVENANCE.md` as stock data (bucket A), RE-derived (bucket R) or zdtd-owned
(bucket Z), and `tools/provenance_scan.py` fails the build for a file without one;
stock XML values are audited against the operator install by
`tools/check_xml_audit.py` (docs/PROVENANCE.md:17-33, docs/PROVENANCE.md:55-59,
docs/XML_DATA_AUDIT.md:22-29). The only comptime embed in the package is the sandbox
preset ladder (src/assets/sandbox_presets.zig:1, src/assets/sandbox_presets.zig:18).
Without a game-dir the loaders keep their small `builtin_*` tables, offline-only and
replaced whenever XML loads (docs/XML_DATA_AUDIT.md:104-112).

Nothing in the catalogs persists. The two disk artifacts this subsystem writes are
the mod enable/disable list next to the world save (src/assets/modlets.zig:57-60) and
the merged patched XML under `.zdtd_cfg_cache/` when patching is active
(src/assets/paths.zig:180-187). The modlet wire side is the join-phase config sync:
42 named rows are Deflate-cached at init and streamed as
`NetPackageConfigFile` rows, with a documented divergence where zdtd sends `-1` for
an absent cache so a client's `WaitForConfigsFromServer` completes
(src/server/game/config_files.zig:1-8, src/server/game/config_files.zig:26-46). The
localization table is written back as stock's CSV shape and deflated in 128 KiB parts
(src/assets/localization.zig:32-33, src/assets/localization.zig:72-83); a green zdtd
encode/decode round trip over these rows proves self-consistency, not stock
compatibility, which needs a stock client read or a loadgen golden.

## See also

- [ASSETS.md](../ASSETS.md) - loader map, id-space table and the fail-closed policy.
- [XML_DATA_AUDIT.md](../XML_DATA_AUDIT.md) - per-config coverage and the machine gate.
- [PROVENANCE.md](../PROVENANCE.md) - the A/R/Z ledger every loader row must have.
- [ARCHITECTURE.md §10](../ARCHITECTURE.md#10-config-assets-and-persistence) - config
  precedence and the persistence plane.
- Sibling pages: [config.md](config.md), [map.md](map.md), [inventory.md](inventory.md),
  [quests.md](quests.md).
