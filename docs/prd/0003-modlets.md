# Pure XML / Assetbundle Modlet Compatibility - Product Requirements (PRD)

> **Purpose:** product requirements for pure XML/assetbundle modlet compatibility - discovery, XML patching, and join-phase config sync.

**Number:** PRD 0003
**Status:** shipped (Mods/ discovery + patch pipeline + `NetPackageConfigFile`
join sync live: `src/assets/modlets.zig`, `src/wire/packages.zig`
`buildConfigFileBody`, `src/server/game/config_files.zig`). Exception: R10's
`NetPackageLocalization` send is descoped per §8 G8 and stays in the backlog.
**Owner:** zdtd server core (modlet support is a stock-data loading path, not a
mod host).
**Ships as:** zdtd native (Zig) modlet discovery + XML patch pipeline + join-phase
config sync, extending the existing `src/assets/xml_patch.zig` / `paths.zig`
machinery.
**Behavioural reference:** stock dedicated V3.1.0, per
`../../../7dtd-engine-research/docs/mod-loading.md` (ModManager / XmlPatcher / SendXmlsToClient),
`../../../7dtd-engine-research/docs/inventories/xmlsToLoad.md` (49-row config table),
`../../../7dtd-engine-research/docs/protocol-packages.md` (NetPackageConfigFile IL=25,
NetPackageLocalization IL=30).
**Related:** [RFC 0003](../rfc/0003-modlets-plan.md) (implementation plan) · [ASSETS.md](../ASSETS.md) · [AUTHORITY.md](../AUTHORITY.md) (join gate)

---

## 1. Background and problem

zdtd is a clean-room Zig dedicated server for stock 7 Days to Die. Operators of
stock dedicated servers routinely install **modlets**: folders under `Mods/` that
ship only data, no code. A pure XML modlet is `Mods/<name>/ModInfo.xml` (V2) plus
`Config/*.xml` XPath patch files that edit the stock `Data/Config` tables (add
blocks, items, recipes, loot, quests, ...), optionally `Localization.csv` and a
`Bundles/` folder of Unity assetbundles (custom meshes/textures).

Stock makes these work server-side: the dedicated server applies the patches at
boot, then **ships the patched config XML to joining clients** (Deflate-compressed
`NetPackageConfigFile`), so clients pick up modded blocks/items and matching
AssignIds without installing anything. Asset bundles are the one client-side
requirement (rendering); XML patches are not.

zdtd today:
- applies a **subset** of the stock `XmlPatcher` ops (`set`, `setattribute`,
  `setbyxpath`, `remove`, `removebyxpath`, `append`, `appendbyxpath`) but only to
  `--config-overrides` dirs, not stock `Mods/` folders;
- does **not** scan `Mods/`, so a stock modlet folder is ignored: the server runs
  unpatched data while the client runs patched data, AssignIds diverge, and the
  game desyncs;
- does **not** implement `NetPackageConfigFile` / `NetPackageLocalization`
  (registered names only in `src/wire/packages.zig`), so even a manually-patched
  server would not sync configs to clients.

Outcome: any server with XML modlets installed is silently incompatible today.
This PRD defines the compatibility surface for **pure XML/assetbundle modlets**
and nothing else.

## 2. Personas

- **Operator** - runs a stock-style `Mods/` folder on the server (Vortex installs,
  hand-copied modlets, modlet packs). Expects the stock contract: install into
  `Mods/`, restart, clients join without client-side install for XML content.
- **Mod author** - writes XML patches against the stock XPath framework
  (append/set/remove/insert/csv/conditional/include), tests against a stock dedi.
- **Player** - joins with a vanilla client (EAC off) and sees modded content
  (new blocks/items, changed recipes) with working names and ids.
- **Developer/QA** - needs deterministic unit + loadgen coverage of the patch
  pipeline and the S2C wire so regressions fail CI, not live play.

## 3. Goals

1. Stock-equivalent modlet discovery and loading for XML-only mods:
   `game-dir/Mods/<name>/ModInfo.xml` (V2) + `Config/*.xml` patches applied in
   stock order, feeding the same patched bytes zdtd already serves to its
   catalogs.
2. Full coverage of the **verified stock `XmlPatchMethods` catalog**
   (`../../../7dtd-engine-research/docs/mod-loading.md` §5.3): set/setattribute
   (byxpath), append/prepend (byxpath), insertafter/insertbefore (byxpath),
   remove/removeattribute (byxpath), csvoperations, conditional, include with
   `@modfolder:` / `@modfolder(Name):` token rewrite.
3. Join-phase config sync matching stock: Deflate-cached patched XML shipped via
   `NetPackageConfigFile` for the 42 S2C-eligible rows of `xmlsToLoad`
   (`archetypes` name-only), and merged mod localization shipped via
   `NetPackageLocalization`, at the stock point in the join sequence.
4. Assetbundle modlets tolerated: `Bundles/` folders and `.unity3d` files never
   crash or corrupt the server; rendering is client-side; the stock server-side
   bundle behavior is resolved by RE (see §8 G1) or explicitly documented.
5. Safe and observable: patch + compress run at init/load time only, serialize
   once, no tick cost; unsupported/unverifiable patch content fails loudly at
   boot (not silent desync); every op and the wire are unit- and golden-tested.
6. House rules held: clean-room (no TFP DLLs/IL), provenance rows for new files,
   `make check` green, no em dashes, no AI attribution.

## 4. Scope

### In scope (MVP)

- `Mods/` discovery: scan operator `game-dir/Mods`, parse `ModInfo.xml` V2,
  deterministic folder order, per-mod `Config/*.xml` patch files, `Localization.csv`,
  tolerate `Bundles/`.
- Full XmlPatcher op catalog (goal 2) on top of the existing text-level subset,
  including `file=`/root-xpath file routing and `@modfolder:` rewrite.
- Patched catalogs: every zdtd-loaded table (blocks, items, recipes, loot,
  quests, traders, buffs, entities, entitygroups, spawning, gamestages,
  progression, vehicles, npc, biomes, painting, signs, ...) loads from merged
  bytes (base -> mod patches -> operator `--config-overrides`, last wins).
- S2C config sync: `NetPackageConfigFile` body + Deflate cache + join send for
  the S2C rows, including XUi/`XUi_*` rows as opaque pass-through (zdtd never
  parses XUi).
- Localization: merge mod `Localization.csv` into the localization payload
  `NetPackageLocalization` sends at join **(gated on RE gap G8; see plan
  Phase 3)**.
- Fixture modlet under `assets/fixtures/` (adds one block, one item, one recipe,
  one localization key) used by unit tests, loadgen smoke, and stock-client
  smoke.
- Docs: this PRD, [RFC 0003](../rfc/0003-modlets-plan.md), `docs/INDEX.md` row, provenance rows,
  AGENTS.md wording update (modlet data loading is not mod hosting).

### Out of scope (explicitly)

- **Code mods**: DLLs, Harmony, `IModApi`/`ModEvents`, any C#. A mixed mod's DLL
  is never loaded; its XML patches still apply (stock-like for the XML part) and
  a loud warning names the skipped code part.
- Mod compatibility beyond pure XML/assetbundle: mod APIs, server-side modded
  game logic, custom wire packages beyond ConfigFile/Localization.
- POI/prefab modlets (`Prefabs/` + `.tts` + rwgmixer additions) - noted as a
  possible follow-up; out of scope here.
- XUi behavior, DMS content behavior, subtitles/videos/loadingscreen UI rows:
  XML passes through S2C when stock says S2C; nothing is parsed or executed.
- Mod managers/tools (Vortex, ...): they only lay files down; no integration.
- UI atlas bundles (`LoadUiAtlases`), localization *generation*, save/quest
  formats from mods.

## 5. Stock behavior (RE evidence)

All from `../../../7dtd-engine-research/docs`; not re-derived here.

### 5.1 Modlet discovery and load

`ModManager.LoadMods` scans mods folders; each mod needs `ModInfo.xml` **V2**
(`Name`, `Version`, `DisplayName`, optional `Description`/`Author`/`Website`,
`SkipWithAntiCheat` bool). V1 is rejected. XML-only mods (no DLL) skip the
assembly/init stages and only patch content; they load even under EAC.
`DetectContents` marks `GameConfigMod` when `Config/` holds anything other than
`XUi_Menu`, `loadingscreen.xml`, `Localization.csv`. Mod load-state enum and EAC
gate details: `mod-loading.md` §1-2.

### 5.2 XML patch pipeline

`ModManager.LoadPatchStuff` (game-startup path) drives `XmlPatcher.PatchXml`:
per patch file, each child element's **local name** selects a registered
`XmlPatchMethods` op invoked with the target `XmlFile`, the `xpath` attribute,
the patch element, and the mod. Failures log `XML.Patch (...)` lines; a patch
element failure does not abort the batch. Verified op catalog (§5.3 of
mod-loading.md): setbyxpath/setattributebyxpath, appendbyxpath/prependbyxpath,
insertafterbyxpath/insertbeforebyxpath, removebyxpath/removeattributebyxpath,
csvoperationsbyxpath, conditional, include (`@modfolder:` / `@modfolder(Name):`
tokens rewritten by `ReadPatchXmlWithFixedModFolders`).

### 5.3 Config load table and S2C

`WorldStaticData.xmlsToLoad` has **49** rows (`inventories/xmlsToLoad.md`);
**42** carry `SendToClients`. `rwgmixer` is boot-only; `gamestages`, `spawning`,
`signs` are server-only; `loadingscreen`, `subtitles`, `videos` are boot-only UI;
`archetypes` is boot+S2C+`LoadClientFile` (client loads its own file, server
sends name only).

### 5.4 Config S2C wire

`mod-loading.md` §5.6 + `protocol-packages.md`:

- Server keeps a **Deflate-compressed** byte cache per S2C row
  (`cacheSingleXml`, minified serialize).
- Join (`RequestToEnterGame`), **after** `NetPackageLocalization` start, **before**
  `NetPackageWorldInfo` / chunk cluster / spawn points: `SendXmlsToClient`
  walks the table; skips non-S2C rows; `archetypes` sends name-only (null data).
- `NetPackageConfigFile` (IL=25): `PackageDirection`=ToClient, package-level
  `Compress`=true, write order: `name` string, `dataLen` i32 (-1 = null), `data`
  bytes when present. Client `ReceivedConfigFile` stores it; `handleReceivedConfigs`
  applies once the join batch is complete.
- `NetPackageLocalization` (IL=30): `seqNr`, `totalParts`, `dataLen` i32
  (-1 = null), `data`; `prepareDataPackets` IL=107 chunks the download; sent at
  join before config files.

### 5.5 Frame compression

The game-channel envelope carries a `compressed` byte (`0` = raw, golden path;
`protocol-frames.md` §2). Whether ConfigFile's already-deflated payload is
double-wrapped by the package-level `Compress` flag, and how zdtd's frame writer
must set the bit, is **not yet resolved from RE** (G7). Until verified, wire
goldens pin the exact bytes.

## 6. Requirements

Acceptance is per requirement; the whole feature is done only when §9 passes.

### Discovery and ordering

- **R1** Scan `game-dir/Mods` (operator install). Missing dir = no-op, like
  stock. Subfolders are mods in **folder scan order** (stock scan order; G2
  resolves the exact rule; deterministic sort fallback documented).
- **R2** Per mod: parse `ModInfo.xml` V2 (`Name` non-empty matching the stock
  validation regex, valid `Version`, `DisplayName` non-empty; missing/invalid =
  skip mod with the stock warning text). V1 = reject. No DLL ever loaded: if the
  folder contains DLLs, log a loud "code part not hosted" warning and continue
  with XML patches only. Malformed/absent ModInfo.xml = skip mod, warn (stock
  behavior).

### Patching

- **R3** Apply each mod's `Config/*.xml` files in stock order (G3) with the full
  verified op catalog: set/setattribute(/byxpath), append/prepend(/byxpath),
  insertafter/insertbefore(/byxpath), remove/removeattribute(/byxpath),
  csvoperations, conditional, include. Ops are selected by element local name,
  case-insensitive, like stock's registry lookup.
- **R4** XPath subset stays text-level but must cover the ops' target forms,
  including trailing `/@attr` (already supported) and the `[@name='x']` filter
  form. `file=` root attribute and root-xpath file inference (existing
  `fileFromXPath`) route a patch to the right config file.
- **R5** `@modfolder:` and `@modfolder(Name):` tokens in `include` xpaths are
  rewritten to the issuing mod's path before load (stock
  `ReadPatchXmlWithFixedModFolders`).
- **R6** Fail closed: an **unknown or unimplemented** stock op name in a patch
  file is a load-time error naming mod + file + element, and the server refuses
  to start (deliberate divergence from stock's log-and-continue: a skipped patch
  silently desyncs AssignIds). Patch syntax errors within a known op are logged
  per stock and the element skipped, but an error counter must reach zero before
  the server accepts the mod. `--config-overrides` keep their existing
  last-wins semantics and apply after mod patches.

### Catalogs

- **R7** Every zdtd catalog load goes through the merged pipeline
  (base -> mod patches -> operator overrides), exactly once at init; the
  existing `.zdtd_cfg_cache` merge path is reused/extended so loaders do not
  change shape. No catalog re-read mid-tick.

### S2C sync

- **R8** At init, after patch merge, Deflate-compress the patched bytes of each
  of the 42 S2C rows once (serialize-once cache, fixed storage, no per-join
  work). XUi/XUi_* rows and any other row zdtd does not parse are still merged
  and cached (opaque pass-through); do not fabricate content for rows zdtd never
  loads (missing base file = stock skip rule).
- **R9** `NetPackageConfigFile` builder (RE IL=25): `name`, `dataLen` i32 (-1
  for null), `data`. Join phase sends the 42 rows after localization starts,
  before WorldInfo/chunks; `archetypes` sends name-only. Package-level
  `Compress` handling per G7 with a pinned wire golden.
- **R10** Localization: merge each mod's `Localization.csv` (stock merge order,
  G3) and send via `NetPackageLocalization` (RE IL=30, `prepareDataPackets`
  chunking) at the stock join point. zdtd currently has no localization send;
  RE for the payload source (stock ships the server-merged csv set) is in G8.

### Asset bundles

- **R11** `Bundles/` folders and `.unity3d` files in mods are never read,
  parsed, or executed by zdtd; presence is tolerated (no error), logged once per
  mod at debug level. Document in the operator-facing text that bundle content
  is client-side rendering (client must have the bundle mod installed), per G1.
  A bundle-only mod that carries no XML patches is a valid install (no-op server
  side).

### Process and budget

- **R12** All patch/compress/merge work is init/load-time (alloc allowed,
  cached); join sends reuse cached blobs and the existing send buffers; tick and
  hot packet paths gain no allocation or work (AGENTS memory rules hold). Bounds:
  cap each patched config blob (generous, named const) and refuse to start with
  a clear error if exceeded (never silently truncate a config the client `Read`s,
  AGENTS rule 24). New src files get provenance rows; docs updated; `make check`
  green.

## 7. Wire contract (for the plan)

| Package | Direction | Write order | Notes |
|---|---|---|---|
| `NetPackageConfigFile` | ToClient | `name` (string, 7-bit len), `dataLen` i32 (-1 = null), `data` bytes | payload = Deflate(patched xml, minified); package `Compress`=true (G7) |
| `NetPackageLocalization` | ToClient | `seqNr`, `totalParts`, `dataLen` i32 (-1 = null), `data` | chunked via `prepareDataPackets`; join-phase first |

S2C row list (42) is the `SendToClients=true` set of `inventories/xmlsToLoad.md`;
`archetypes` = name-only (-1). Server-only (never sent): `rwgmixer`,
`gamestages`, `spawning`, `signs`, `loadingscreen`, `subtitles`, `videos`.

## 8. RE gaps to close during implementation

Resolved from RE or explicitly documented before the "compatible" claim:

- **G1** Does the stock dedi load mod `Bundles/` assetbundles at all (load
  points, failure behavior)? Target: `Mod`/`AssetBundles` IL or behavior notes
  in 7dtd-engine-research.
- **G2** "For each mods folder" in `ModManager.LoadMods`: which roots (game-dir
  only? user-data too?) and the folder iteration order.
- **G3** Per-mod patch-file order and per-file op order inside
  `LoadPatchStuff`/`PatchXml`; Localization.csv merge order.
- **G4** `CsvOperationsByXPath` exact element/attribute grammar (`op` values,
  `value` semantics, separator handling).
- **G5** `Conditional` and `Include` exact element grammar (condition attribute
  forms, nested container names).
- **G6** `@modfolder:`/`@modfolder(Name):` token rewrite edge cases (quotes,
  subpaths).
- **G7** Frame `compressed` bit vs package `Compress` flag layering for
  ConfigFile (single vs double deflate), and zdtd's frame-writer requirements.
  Pin with a loadgen/golden byte test.
- **G8** `NetPackageLocalization` payload source: what exactly stock serializes
  (merged csv table? per-language dict?) and the send sequencing/`seqNr` scheme.

Unresolvable gaps (no RE evidence, no stock probe available) must be written up
in the PRD/plan as documented limitations, not silently implemented.

**Resolution status (2026-08-23):**

- **G1** (stock dedi mod assetbundle load): no `Mod`/`AssetBundles` IL dump is
  available in `7dtd-engine-research/il/` (protocol/wire-focused dump set). Fallback
  taken: zdtd never reads `Bundles/` (PRD R11); operator note says bundle
  content is client-side rendering and a vanilla client needs the bundle mod
  installed. RE follow-up stays in the backlog.
- **G2** (mods-folder roots + folder order): fallback taken - `game-dir/Mods`
  (plus `--mods-dir`), sorted folder order, documented in `src/assets/modlets.zig`.
- **G3** (patch target selection): fallback taken - `file=` attribute wins, then
  patch file name (modlet convention), then xpath root inference (superset,
  covers real modlets), documented in `src/assets/xml_patch.zig`.
- **G4/G5** (csvoperations / conditional grammar): csvoperations implemented for
  the common `op` add/remove/set forms (unit-tested, not IL-pinned);
  `conditional` **fails closed** (load error, PRD R6) until RE pins the grammar.
- **G6** (`@modfolder:` edge cases): `@modfolder:` and `@modfolder(Name):`
  implemented, path remainder appended verbatim; documented.
- **G7** (ConfigFile compress layering): the stock `compressed` envelope is the
  existing `DeflateFramer` (already proven by `sendBlockIdMapping`); the data
  field is raw-Deflate(patched xml) per stock `cacheSingleXml`. Wire golden
  tests pin the body; a loadgen byte-level golden is a follow-up.
- **G8** (localization payload source): no IL evidence available. The
  `NetPackageLocalization` join send stays **out of scope** (plan Phase 3
  gate); mod `Localization.csv` is never parsed and never breaks loading.
  Follow-up task in the backlog.

## 9. Test strategy

- Unit: new ops (prepend, insertbefore/after, removeattribute, csv, conditional,
  include, `@modfolder`) in `xml_patch.zig`; merge order (base -> mods ->
  overrides); ModInfo parsing; fail-closed paths.
- Wire: golden byte tests for `NetPackageConfigFile` (name + -1 and name + blob)
  and `NetPackageLocalization` framing per §7, pinned against RE/loadgen.
- Fixture modlet (`assets/fixtures/modlet_minimal/`): ModInfo V2 + patches adding
  one block (with property), one item, one recipe, one localization key; used by
  unit tests and by a loadgen scenario (join + item id present in negotiated
  maps).
- Loadgen smoke: server started with the fixture modlet in a scratch `Mods/`
  dir; `--join --count 2`; patched ids visible on the wire; no frame desync.
- Stock client (EAC off) smoke when practical: join, confirm new block/ item
  render and ids match; otherwise documented (AGENTS rule: "when practical").
  **Status:** not practical in this environment - no client-join automation
  harness exists (7dtd-playtest ships analysis tooling, not a driver); the
  automated client stand-in (loadgen) is additionally blocked by the sibling
  handshake drift (V 3.1.0 vs V 3.10, see smoke-modlet.sh). Follow-up: run the
  stock-client smoke once loadgen or a client driver is available.
- `make check` green (build, unit+scenario tests, lint incl. provenance scan).

## 10. Documentation and process

- [RFC 0003](../rfc/0003-modlets-plan.md): task breakdown, order, verify points (this PRD's §8).
- `docs/INDEX.md`: add PRD 0003 + RFC 0003 rows.
- `docs/PROVENANCE.md`: rows for every new/changed src file.
- `AGENTS.md`: clarify that modlet data loading (`Mods/` XML patches) is stock
  data loading, distinct from the "not a mod host" rule (no IModApi/Harmony/Mods
  code loading stays true).
- `CHANGELOG.md` entry; commit text: no em dashes, no AI attribution.

## 11. Open questions for the operator

1. Mods folder root: only `game-dir/Mods`, or also a `--mods-dir` override?
   (Default: `game-dir/Mods`; override is a one-line config knob.)
2. Unknown-op strictness: refuse to start (R6) vs refuse only the offending mod.
   This PRD picks refuse to start; a mod-scoped refusal is the fallback if
   operators report breakage on real modlet packs.
