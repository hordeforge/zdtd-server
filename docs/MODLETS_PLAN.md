# Pure XML / Assetbundle Modlet Compatibility - Implementation Plan

**Source:** [`docs/MODLETS_PRD.md`](MODLETS_PRD.md) (requirements R1-R12, wire
contract §7, RE gaps G1-G8). **Status:** to review. Plan phases gate on
acceptance checks; `make check` must stay green at every commit.

## Phase 0 - Close the RE gaps that block design

Small, timeboxed. Everything else proceeds with documented fallbacks.

| Gap | Action | Fallback if blocked |
|---|---|---|
| G1 stock dedi mod assetbundle load | `Mod` / `AssetBundles` IL in `../7dtd-research` (`Mod.LoadBundles` if present, failure handling) | Document: zdtd never reads `Bundles/`; bundle content is client rendering (R11) |
| G2 mods-folder roots + folder order | `ModManager.loadModsFromFolder` call sites / `GameIO.GetModsPath` IL | Default `game-dir/Mods`, sorted folder order, documented |
| G3 patch file order + target selection (filename vs `file=` vs xpath root) | `ModManager.LoadPatchStuff` MoveNext (IL=6) in `il/` if dumped | Implement filename-match + `file=` + root-tag inference (superset, deterministic), document; covers all real modlets |
| G7 envelope compress layering for ConfigFile | `NetConnectionAbs::Compress` (already cited in `frame.zig`); confirm ConfigFile rides the same deflate envelope | Use existing `DeflateFramer` (proven by `sendBlockIdMapping`); pin bytes in a wire golden |
| G4/G5/G6 csvoperations / conditional / include grammar | `XmlPatchMethods` IL dumps in `../7dtd-research/tools` | Implement documented common forms, unit-test, mark unverified; stock-client smoke as witness |

Verification per gap: `../7dtd-research` doc or `il/` line cited in the
implementation comment; else the fallback note lands in `MODLETS_PRD.md` §8.

## Phase 1 - Modlet discovery + full patch ops (R1-R6, R7)

1. **`src/assets/modlets.zig` (new)** - stock ModManager subset for XML-only
   mods, per `mod-loading.md` §1-2:
   - scan `game-dir/Mods` (plus `--mods-dir` override if given), sorted folder
     order (G2);
   - parse `ModInfo.xml` V2: `Name` non-empty (stock validation regex),
     `Version` `System.Version.TryParse`, `DisplayName` non-empty; V1 rejected;
     malformed = skip mod + stock warning text;
   - expose `patch_dirs: []const []const u8` (each mod's `Config/` dir, mod
     order), `mod_count`, `bundle_mod_count` (mods with `Bundles/`, logged once,
     never read), `code_mod_warnings` (DLLs present: loud warn, XML still
     applies);
   - returns owned arrays (init-time allocation).
2. **`src/assets/xml_patch.zig`** - extend the op set to the full verified
   catalog (`mod-loading.md` §5.3):
   - `prepend` / `prependbyxpath` (insert body at start of matched element);
   - `insertafter` / `insertbefore` (sibling insert, `/byxpath` forms);
   - `removeattribute` / `removeattributebyxpath` (drop an attribute);
   - `csvoperations` (G4 grammar: `op` add/remove/set on a comma-separated
     attribute value, `value` element/attribute);
   - `conditional` (G5: condition attr forms, nested patch container);
   - `include` (G5/G6: `xpath="@modfolder:/..."` and `@modfolder(Name):`
     rewritten to the issuing mod's path, then the included file applied as a
     patch doc);
   - unknown op name: load-time error naming mod + file + element; the mod's
     patches are rejected and the server refuses to start (R6, deliberate
     divergence from stock log-and-continue, documented in PRD §6 R6).
   - `applyOverrideDirs` stays the driver: pass mod `Config/` dirs first, then
     `--config-overrides` dirs (R6 order: base -> mods -> operator).
3. **`src/assets/paths.zig`** - `setOverrideDirs` called from `init_assets` with
   `mods.patch_dirs ++ opts.config_overrides`; keep the `.zdtd_cfg_cache` merge
   path (R7). All 49 loaders inherit patched bytes with no per-loader change;
   `quests.zig` and the `override_dirs.len > 0` fast-paths in `blocks.zig` /
   `biome_layers.zig` / `maxdamage.zig` / `block_textures.zig` already route
   through the same merge.

Acceptance: unit tests per new op (fixture XML in-file); a fixture modlet
(`assets/fixtures/modlet_minimal/`, see Phase 4) applied to a scratch base
produces the patched catalog; unknown-op modlet refuses start with the mod/file/
element named; `zig build test` green.

## Phase 2 - Patched-config S2C (R8, R9, R12)

1. **`src/wire/packages.zig`** - `buildConfigFileBody(buf, name, data: ?[]const u8) ![]u8`:
   write order per RE IL=25: `name` (7-bit string), `dataLen` i32 = `-1` when
   null else `data.len`, then `data` bytes. Golden unit test pins the layout
   (name-only and with blob).
2. **`src/server/game/config_files.zig`** (extends existing shard file) - two
   parts:
   - **cache build** (init, alloc allowed): for each of the 42 S2C names
     (`xmlsToLoad.md` S2C set, already hardcoded in this file), read patched
     bytes via `assets/paths.readConfigXml` (same pipeline the loaders use, R7),
     raw-deflate them (`std.compress.flate.Compress`, `.raw`, mirroring stock
     `cacheSingleXml` DeflateOutputStream; reuse the `DeflateFramer` writer or a
     plain compress into an owned buffer) and store the blob in a fixed 42-slot
     array. `archetypes` stays name-only (RE: `LoadClientFile`). Missing base
     file: no blob (send `-1`, see divergence note). Cap per blob (named const,
     e.g. 384 KiB, fits the 512 KiB `body_buf` frame with margin); over cap =
     refuse to start, loud error (R12, never truncate).
   - **send** (join): replace the `-1`-only loop with: per name, body =
     `buildConfigFileBody` (null when no blob, `archetypes` always null); frame
     via `DeflateFramer` into `body_buf` like `sendBlockIdMapping`
     (game.zig:1772): `begin` with `body_len = name + 4 + blob.len`, stream
     name/len/blob, `finish`, `sendFramedReliable(peer, "NetPackageConfigFile",
     framed, critical_retry_budget_ns, true)`.
   - Divergence (document in code comment): stock skips rows with a null cache;
     zdtd sends `-1` instead so a vanilla client's `WaitForConfigsFromServer`
     always completes (proven today), falling back to local files.
3. Join order is already correct: `c2s/join.zig:236` sends config files after
   `sendBlockIdMapping` and before `WorldInfo` / `ChunkClusterInfo` / spawn
   points, matching `RequestToEnterGame` (RE §5.6). No ordering change.

Acceptance: wire golden test for the body; cache test (patched bytes deflate ->
inflate round-trip equals patched bytes); loadgen join with the fixture modlet:
new item id present in negotiated maps, no frame desync; `make check` green.

## Phase 3 - Asset bundles + localization (R10, R11)

1. **Bundles (R11)** - Phase 1 already tolerates `Bundles/`; Phase 3 closes G1
   and writes the operator-facing note (bundle content is client-side
   rendering; a vanilla client needs the bundle mod installed). No bundle bytes
   are ever read.
2. **Localization (R10, gated on G8)** - merge each mod's `Localization.csv`
   into the localization payload only if G8 RE (payload source, `seqNr`/
   `totalParts` scheme, `prepareDataPackets` IL=107) is closed in `../7dtd-research`.
   If G8 stays open: ship a documented limitation (mod localization not synced;
   item names resolve from the client's files) and keep the task in the backlog.
   zdtd never parses Localization.csv otherwise; presence never breaks loading.

Acceptance: bundle-only modlet server boots clean (smoke); G8 status written to
`MODLETS_PRD.md` §8 either way.

## Phase 4 - Fixture + verification (PRD §9)

1. **`assets/fixtures/modlet_minimal/`** - `ModInfo.xml` (V2), `Config/blocks.xml`
   (append one block with `MaxDamage` property), `Config/items.xml` (append one
   item), `Config/recipes.xml` (recipe for the item), `Localization.csv` (one
   key), `Bundles/` with a dummy `.unity3d` (tolerance). Offline unit fixture.
2. **World overlay `worlds/zdtd_modlet_smoke/`** - minimal `Data/Config` base
   files + the modlet installed as `Mods/modlet_minimal/`, so the server can
   boot without a full stock install (pattern per existing smoke worlds).
3. **Loadgen smoke** - start the server on the overlay, run the existing loadgen
   join (see `scripts/auto_join.sh` / Makefile smoke targets): join, spawn,
   patched item id in negotiated name maps, clean disconnect. Add a scenario
   entry if the harness has a registry (check `src/server/scenarios.zig`).
4. **Stock client (EAC off)** smoke when practical: join with the modlet server,
   place the new block, verify name and id match; otherwise document in PRD §9
   (AGENTS rule: when practical).
5. `make check` green (build, unit + scenario tests, lint, provenance scan).

## Phase 5 - Docs and process (PRD §10)

- `docs/INDEX.md`: add MODLETS_PRD + MODLETS_PLAN rows.
- `docs/PROVENANCE.md`: file rows - `src/assets/modlets.zig` (bucket R,
  `mod-loading.md` §1-2), `src/server/game/config_files.zig` (already under the
  game.zig shard convention, extend its row with the S2C cache: R,
  `mod-loading.md` §5.6 + `protocol-packages.md`); xml_patch.zig/packages.zig
  rows updated for the new ops/builder.
- `AGENTS.md`: adjust the "Owns / does not own" wording so stock modlet data
  loading is clearly stock-data loading, distinct from mod hosting (no
  IModApi/Harmony/`Mods/` code loading stays true).
- `CHANGELOG.md` entry. Commits: no em dashes, no AI attribution.

## Order and dependencies

Phase 0 (gaps) -> Phase 1 (patch pipeline, unblocks everything) -> Phase 2
(S2C) -> Phase 3 (bundles + localization) -> Phase 4 (fixture + smokes,
interleaves with 1-2) -> Phase 5 (docs). Phases 1 and 2 each keep `make check`
green; Phase 4 smoke validates the whole path; Phase 5 closes the provenance
gate so the final `make check` passes end-to-end.

## Explicit divergences from stock (documented in code + PRD)

1. R6: unknown patch op = refuse to start (stock logs and continues).
2. Phase 2: null cache = send `-1` (stock skips the package).
3. `--config-overrides` apply after mod patches (zdtd extension, last wins).
4. Bundle tolerance with zero reads (pending G1).
