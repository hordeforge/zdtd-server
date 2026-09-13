# Provenance ledger: every zdtd behavior and value -> stock source

> **What this is:** the ledger that proves every behavior and value in `src/` comes from a documented stock source or is explicitly zdtd-owned, file by file and constant by constant (machine-gated by `tools/provenance_scan.py`).
> **Related:** [ARCHITECTURE.md](ARCHITECTURE.md) · [ASSETS.md](ASSETS.md) · [ZIG_CLONE.md](ZIG_CLONE.md) · [STATUS.md](STATUS.md) · [INDEX.md](INDEX.md)

**Owns:** the proof that every behavior, perk and constant in zdtd comes from a
documented stock-game source (or is explicitly marked zdtd-owned). For each
src/ file: which stock behavior it implements, and for each behavioral
constant: the stock XML element or IL-verified RE doc it comes from.
**Hub:** [`INDEX.md`](INDEX.md). **Complementary:** [`RE_GAP_CLOSURE.md`](RE_GAP_CLOSURE.md)
(gap -> RE spec), [`ASSETS.md`](ASSETS.md) (data-loading policy),
[`GAP_ANALYSIS.md`](GAP_ANALYSIS.md) (gap inventory), the archived
[`HARDCODE_AUDIT_2026-08-08.md`](archive/HARDCODE_AUDIT_2026-08-08.md) (finding-by-finding hardcode audit).

## 1. Method and scope

What counts: **every `src/**/*.zig` file** (file-level provenance) and **every
file-scope typed constant** in every src file (value-level provenance). The
value-coverage gate scans the whole tree (test/fuzz/harness scaffolding
excluded): each constant carries an inline provenance comment (stock source,
RE cite, or explicit zdtd-owned marker). The 27 highlighted rows below are the
behavioral values that diverge or carry the system's load; the gate covers
everything else. Struct-field defaults carry block-level inline provenance
(rules.zig per-field; LevelCurve/PerkDef/WorldClock/QuestDef/Turret blocks
annotated); layout/position/id fields are structural and covered by the file row.

Three buckets (from AGENTS.md rule 15 + the hardcode-audit method):

| Bucket | Meaning | Rule |
|---|---|---|
| **A** | Stock game **data** | Must be read from the operator install (XML / assets / AssignIds), never hand-copied; the row names the stock file |
| **R** | Stock behavior/wire reproduced from **RE** | The row cites the `../7dtd-engine-research/docs` narrative (IL-verified) or bundled dump that specifies it; fix code to match RE, never the reverse |
| **Z** | zdtd-owned policy / engineering | No stock counterpart; explicitly not a provenance claim; operator-tunable where it changes behavior (zdtd.toml / serverconfig) |

Citation forms: `Data/Config/<file>.xml <element>` (stock data), `../7dtd-engine-research/docs/<doc>.md §N` (RE narrative), `asm.il <offset>` (dump line). The stock pin is **V3.1.0 (b14)**; see `src/version.zig`.

**Shard convention:** `src/server/game/*` files marked "extracted verbatim from
game.zig" inherit the provenance of `src/server/game.zig` (the RE-built game
server: join SM, tick, interest, combat, persistence). Their behavioral
constants are ledgered in §3; the file row's stock source is `game.zig` itself
plus the RE docs it implements. `src/server/c2s/*` and `src/server/game/*`
rows without an explicit research citation follow the same rule.

## 2. Coverage accounting

Regenerate the file map and re-check coverage:

```bash
python3 tools/provenance_scan.py      # file coverage + ledger well-formedness gate
```

Audit the positional builders (not in `make check`: one `zig build test` per
mutant, hours for a full run). A stock body carries no field names, so field
order is the contract, and a test that asserts only a length or a version int
cannot see a reordering:

```bash
python3 tools/wire_order_mutants.py --list                 # count the pairs
python3 tools/wire_order_mutants.py --file src/wire/stock_party.zig \
  --test-filter party --test-filter "shared kill"
```

It swaps each adjacent pair of same-width writes and reports the ones no test
distinguishes. Run it when a positional builder gains fields. `--test-filter`
is repeatable and cuts a mutant from 4 min to 2.6 s; the tool probes the set
first and refuses to run when it selects nothing, and re-checks each survivor
against the unfiltered suite so a too-narrow filter cannot invent one.

It mutates the decode side the same way (2026-09-04): the parsers are struct
literals (`.field = try r.readI32(),`), Zig evaluates them in source order, and
a parser that reads a body in the wrong order is a wire break exactly like a
mis-ordered builder. The first decode run paid for itself - the `setblock`
filter was refused as not-live, which turned out to be correct: no test read
the parsed coordinates back, and behind that gap sat a length-keyed legacy
branch that decoded an empty change list from an identified client as a block
edit (fixed, see the CHANGELOG).

The mutant tool only reaches builders some test executes, so the complementary
question is which builders no test runs at all. Counting the `pub fn build*` /
`write*` in `src/wire/` and checking each name against the text inside every
Zig `test` block found 24 of 128 with no direct call (2026-09-04). Most are
reached through a wrapper the tests do call; tracing the remaining ones to
their caller left `buildIdMappingBody`, whose only caller is
`sendItemIdMapping` on the join path. Swapping its name string with the length
i32 left the whole suite green, so it had no coverage at all. HEAD was correct
(`NetPackageIdMapping::read` IL=13) and now has a test.

The same count on the read side (`pub fn parse*` / `read*`) found 12 of 60
with no direct call, and tracing those to their callers left two.
`readTraderDataBody` had no coverage: swapping its `TraderID` with
`lastInventoryUpdate` left the suite green against `TraderData::Write` (IL=15).
HEAD was right and the trader ECD test now reads the body back through the
parser. `parseInventoryBodyNative` had no caller but the fuzzer - no builder
emitted that shape and no handler read it - so it was deleted. Redo both
counts when `src/wire/` gains builders or parsers; a name with no direct call
is not a finding on its own, only a pointer at the caller to check.

Both counts share a blind spot: they name functions *defined* in `src/wire/`,
and the mutant tool only walks that directory, so wire bytes written anywhere
else are invisible to both. `rg -l 'binary.Writer' src/ | rg -v '^src/wire/'`
finds them - six files, of which `persist.zig` writes to disk and
`harness.zig`/`tests.zig`/`scenarios.zig` are test code. The two on live wire
paths were mutated by hand: the SharedQuest remove body in `session_drop.zig`
is caught by a party scenario, but neither body in `game/join.zig` was. A
swapped entityId/count in the empty `NetPackageHoldingItem`, and a swapped
id/name in the NameIdMapping payload, each left the suite green on bytes every
client receives at join. Both now go through builders (`writeHoldingItem`,
`buildNameIdMappingPayload`, AGENTS rule 14), which puts them back inside the
audits and gave each one a test.

That `rg` is no longer a manual step: `provenance_scan` 7h holds the allowed
set and fails on any `binary.Writer` outside `src/wire/` not listed with its
reason, so the next one is a build failure rather than a survivor found by
hand three audits later.

The read side has the same shape - a handler calling `std.mem.readInt` on a
body decodes a stock layout where no audit reaches - and it came out clean
(2026-09-04). Every multi-field direct read was mutated by hand and a scenario
caught each one: the `NetPackageEntityRelPosAndRot` dPos offset with its
euler/quaternion branch (`c2s/move.zig`), `NetPackageMapPosition`'s map middle
(`c2s/misc.zig`), and the stock `NetPackageTurretSpawn` float position. The
remaining direct reads take a leading `entityId` only, which has no ordering
to get wrong, and `game/net_handlers.zig` reads only to print diagnostics.
No 7h-style gate for these: unlike a writer, a bare `readInt` is not a
reliable marker of a decoded layout, and a check that fired on every bounds
read would be noise.

**Audit state (2026-09-04).** Every file in `src/wire/` that has swappable
pairs has now been measured, encode and decode; the three remaining survivors
are unobservable by construction and documented at their code sites. Mutant
counts below are the encode pass; the decode pass added 18 pairs (13 in
`packages.zig`, 3 in `stock_party.zig`, 2 in `stock_buff.zig`) and all of them
are killed after the `setblock` fix:

| File | Mutants | Result |
|---|---:|---|
| `stock_xp.zig` | 7 | clean |
| `stock_te.zig` | 13 | clean |
| `stock_party.zig` | 6 | clean |
| `stock_buff.zig` | 7 | clean |
| `stock_chunk.zig` | 4 | 1 survivor, documented at the code site (an all-air layer writes a `false` bool then `stock_air` = 0, so both bytes are 0 and no chunk can tell them apart; `ChunkBlockLayer.Read` holds the order) |
| `stock_sign.zig` | 4 | clean, after the batch test was given distinct counter values and made to read the SignData body back |
| `stock_quest.zig` | 30 | clean, re-run over the whole file after closing 4 survivors. Every gap had the same shape - a positional run of floats or header bytes with nothing reading it back |
| `stock_inv.zig` | 15 | clean, re-run after closing 7 survivors (`ItemValue.Write` flags/ammo/cosmetics run, the nested mod value, `Bag.Write`'s three trailing bools, the bedroll marker, drop-container y/z) |
| `packages.zig` | 155 | verified end to end by `--lines` section (no small filter set covers the whole file): 480-2500, 2501-3400, 3401-4200 and 4201-end all reach 0 survivors. Around 30 real gaps closed along the way, every one a positional run with nothing reading it back or a fixture whose values matched their neighbours |
| `stock_entity.zig` | 28 | clean, re-run: 8 survivors found and closed over two passes (the ECD lifetime/pos/rot run, homePosition, the falling-tree direction vector). The one remaining survivor is documented at the code site: `spawnByAllowShare` and `headState` are both a zero byte, so no test can pin their order |
| `stock_deco.zig` | 1 | clean |
| `platform_user.zig` | 1 | 1 survivor, documented at the code site: the present bool and `user_identifier_version` are both the byte 1, so no test can pin their order; `PlatformUserIdentifierAbs.ToStream` holds it |

Mutant counts are after the test-block filter added 2026-09-04: writes inside
`test` blocks build fixture bytes for the test itself, so swapping two of them
survives by construction. That was a third of the tree (356 pairs down to 270)
and it was hiding real findings behind noise.

Coverage targets, all enforced by the scan:
- **File coverage: 201/201 (100%).** Every row below carries a bucket and a
  source; a file without a row, or a row without a bucket/source, fails.
- **Value coverage: 100%.** Every file-scope typed constant in **every** src
  file (whole tree, test/fuzz/harness excluded) carries an inline provenance
  comment or a ledger entry.
- **Audit linkage: 100%.** Every A##/B## finding the hardcode audit names
  appears in this ledger.

| Bucket | Meaning | Count |
|---|---|---|
| **A** stock data | Loaded from the operator install (`Data/Config` / world assets / AssignIds); provenance = the stock file | 27 |
| **R** RE-cited | Stock behavior/wire reproduced from `../7dtd-engine-research/docs` IL-verified narratives (or the bundled AssignIds dump); citation in the row | 103 |
| **Z** zdtd-owned | Engineering/policy/instrumentation with no stock counterpart; not a provenance claim | 58 |

### File provenance map

| File | B | Stock source (header-cited; R rows cite the RE doc) |
|---|---|---|
| `src/apm/metrics.zig` | Z | Monotonic counters and latency histograms for zdtd (not 7dtd-server-apm) |
| `src/apm/profiler.zig` | Z | Scoped wall-clock sections for tick phases (zdtd-native; not 7dtd-server-apm) |
| `src/apm/report.zig` | Z | Snapshot dump: human text or JSON lines for loadgen-side compare |
| `src/apm/root.zig` | Z | zdtd-native metrics + profiling harness. Not 7dtd-server-apm (stock Mono). This is first-class instrumentation inside the Zig process |
| `src/apm/tracy.zig` | Z | Optional Tracy client bindings, off by default. |
| `src/assets/assignids_comptime.zig` | A | Named AssignIds pins for V3.1.x (bundled dump). Values are the stock client Block.blockID after AssignIds Postfix, not XML declaration order |
| `src/assets/biome_layers.zig` | A | Stock biomes.xml → per-biomemap-id terrain column layers (top → bottom), weather groups, distant decorations and per-subbiome deco sets + noise |
| `src/assets/block_textures.zig` | A | Default Block.Texture → textureFull (i64) from stock blocks.xml. Face paint is 6×u8 packed little-endian (matches TTS paint samples like |
| `src/assets/blocks.zig` | A | blocks.xml solid/name table. Wire ids come only from AssignIds (idByName), never sequential XML declaration order. `pickup_source` reads the PickupSource property (XML.txt:908 declares it; V3.1.0 b14 sets it on no block, so stock pickups leave Air). `harvest_drops` parses the block's `<drop event="Harvest">` rows (count via ParseMinMaxCount, prob × ResourceScale property, stick_chance/tool_category/tag stored as the item-side bonus legs) and inherits through Extends per CopyDroppedFrom IL=89 (own wins per item name), roll semantics per Block.DropItemsOnEvent IL=246 + GameUtils.HarvestOnAttack IL=623 (RE blocks.md, items.md)  `<dropextendsoff />` (226 stock rows) stops the parent drop rows from merging (2026-09-13).|
| `src/assets/blocks_nim.zig` | A | Prefab `.blocks.nim` local-id → block name table (Prefab name mapping). Catalog/asset parse (not world store). Use when TTS types are local indices |
| `src/assets/buffs.zig` | A | buffs.xml: metadata + passive_effect rows, plus the bounded passive-effects VM (`trackedDeltasAt`/`effectTotals`, revertible by recompute-from-set, requirement- and tag-gated, curves on the purchased level for perks and the elapsed duration for buffs per `BuffClass::ModifyValue` IL=105) and the triggered-effect engine (`evaluateTriggered`). Full triggered_effect action set is later; `tagsMatch` is PassiveEffect::hasMatchingTag IL=53 with the stock ctor defaults; passives carry their effect_group + nested row requirements (`scanEffectGroup`) |
| `src/assets/entities.zig` | A | entityclasses.xml loader: name → Unity Mono hash, kind, HP, death loot list, day/night speeds (MoveSpeed/MoveSpeedNight shamble, MoveSpeedAggro "min,max" = day/night chase + MoveSpeedRand "min,max" per-entity roll, entity-ai.md GetMoveSpeed/GetMoveSpeedAggro + the stock XML comment "min/max (like day or night)"), the SightLightThreshold "min,max" pair (stock "-2,150", CanSeeStealth IL=21) and the SleeperSightToWakeMin/Max wake-threshold roll ranges (stock "-40,5" / "340,480", GetSleeperDisturbedLevel IL=38). Resolves the inherited AITask list (pipe `AITask` on zombieTemplateMale plus numbered `AITask-N` on animals) into `ai_tasks` bits and `ai_attack` (timid animals carry no attack task and never pick approach_attack)  `PhysicalDamageResist` (passive 41) parses per class (untagged base_set rows, Extends-resolved) into `EntityDef.phys_resist`; the tag-gated swarm rows are skipped rather than guessed (2026-09-14).|
| `src/assets/entitygroups.zig` | A | entitygroups.xml: named weighted spawn lists (`<e n="…" p="…"/>`) |
| `src/assets/gamestages.zig` | A | gamestages.xml: per-spawner stage ladders plus the player/party stage math. |
| `src/assets/items.zig` | A | items.xml loader + builtin sim ids with stock name/type resolution for client UI (incl. the `ArmorGroup` property for ArmorGroupLowestQuality). `harvest_rows` parses the HarvestCount passive (141) rows on each item (op/value/curve/tags; RE GameUtils.HarvestOnAttack IL=623: count = trunc(rolled x GetValue(141, tool, 1, holder, null, dropTag)); ops base_add/base_set/perc_add fold over base 1, quality curves at the tool quality, tag-gated by the drop row). `harvestMultiplier` resolves the held-tool multiplier. `tags` + `mod_slots_curve` parse the item's `Tags` property and the `ModSlots` quality passive (RE items.md CalcModSlotCount IL=29) for the mod-attachment scrub. `addItemClasses` registers the sibling catalog's `item_modifier` rows as item classes in the same id space (stock runs `XmlLoadInfo` 9 `items` then 10 `item_modifiers` and assigns the leftover ids in that order, RE items.md load-time id assignment), so an installed mod's ItemValue resolves both ways and the join IdMapping carries it. Magazines parse `AddProgressionLevel` (`progression_name` / `progression_add`) and `GiveExp` (`eat_exp`) so eat grants the matching crafting_skill and awards `_xpOther` (RE minevents.md IL=143 / IL=63)  Prop inheritance covers Action0 `Range` / `DamageBlock` and the `Tags` list through the same Extends pass (a meleeHandZombieFeral takes its parent's range; 286 items declare no own Tags); `addItemClasses` registers sibling-catalog item classes with their econ/stack/quality (2026-09-13).|
| `src/assets/item_modifiers.zig` | A | item_modifiers.xml loader (RE items.md ItemModificationsFromXml ParseModifier IL=63): per-mod `installable_tags` / `blocked_tags` / `modifier_tags` gates for mod attachment validation; `isSuitable` implements the ItemClassModifier tag intersection/disjoint check. Since 2026-09-12 each mod's `<passive_effect>` rows (layer 13) are parsed through the shared buffs scanner into `ModDef.passives`, folded by the item fold and the tagged EDR fold; a worn item's mod `PhysicalDamageResist` reaches `armorMitigation` via the tick's `World.item_mod_phys_resist` column (stock `GetTotalPhysicalArmorRating` sums the worn items' effect layers), while a held item's mod does not (the holding slot is not armour). Stock's server-relevant modifier rows are flat, so no per-mod quality is needed for them. The rows are also registered as item classes by `ItemTable.addItemClasses` (the caller passes the modifier names in file order) so a mod id resolves through the ECS table  `econ` / `stack` / `has_quality` parse the row's `EconomicValue` / `Stacknumber` / owner-tiered effect groups, inherited through `Extends` (modGeneralMaster econ 400), and are handed to `items.addItemClasses` (2026-09-13).|
| `src/assets/loot.zig` | A | loot.xml loader: groups + containers, simple deterministic rolls. Group picks prob-weighted like stock (2026-08-21): the entry's stage-resolved prob is its weight relative to the group sum, zero-prob never picked; lootstage templates resolve per stage, force_prob gates independently  `lootcontainer count` parses into min/max picks (`ParseMinMaxCount`, default 1,1) and `rollContainer` makes exactly that many prob-weighted picks (`count="0"` is empty; 302 stock containers carry count) (2026-09-13).|
| `src/assets/map_atlas.zig` | R | Stock texture-atlas minimap colors: the `uvmapping` XMLs (MeshDescription.MetaData TextAssets) from the `meshdescriptions_assets_all.bundle`, extracted + regenerated by `../7dtd-engine-research/tools/sandbox/{extract_mesh_atlas,gen_atlas_zig}.py` (docs/texture-atlas.md). Colors packed with the stock Utils.ToColor5 RGB555 formula |
| `src/assets/maxdamage.zig` | A | MaxDamage lookup: blocks.xml name→hp + optional AssignIds map from .blocks.nim or a version-matched id\tname dump. Without a full id map, callers fall  `MaxDamage` / `Material` / `Stage2Health` / power / turret props resolve through `Extends` with each child's `param1` exclusion list; `explosionresistance`, material `StabilitySupport` (block default), `collidable`, `movement_factor` and `lightopacity` parse from materials.xml (2026-09-13).|
| `src/assets/modlets.zig` | R | Stock `ModManager` subset for XML-only modlets (../7dtd-engine-research/docs/admin/mod-loading.md §1-2): Mods/ root scan, ModInfo.xml V2 parse (Name/DisplayName/Version rules), Config dir collection in mod order, Bundles/ tolerance (never read, PRD R11), code-mod warning (DLLs never hosted). PRD 0003 / RFC 0003  Each mod's `Version` is kept and `isLoaded`/`versionByName` answer `<conditional>` tests (2026-09-13). `state_file_name` `modlets_disabled.txt`: the operator enable/disable list, loaded at scan time (a disabled mod stays on the roster but its Config/ dir is left out of the patch list) and written back by `setDisabled` (2026-09-13).|
| `src/assets/npc.zig` | A | npc.xml: npc_info entries map a trader entity class (localization_id) and display name to a traders.xml `<trader_info>` id plus its quest_list |
| `src/assets/painting.zig` | A | painting.xml: paint id (0–255) ↔ TextureId for chunk face paint |
| `src/assets/noise.zig` | A | sounds.xml `<Noise>` rows keyed by SoundDataNode name (volume/time/muffled_when_crouched/heat_map_*) for the movement-noise model; stock Data/Config/sounds.xml (1312 rows V3.1.4), fold applied via RE entity-ai.md PlayerStealth |
| `src/assets/paths.zig` | A | Resolve Data/Config XML paths, modlet + override patch dirs (base → mods → overrides, PRD 0003 R6/R7), generic tryLoad |
| `src/assets/progression.zig` | A | progression.xml: level curve + attribute/perk/book catalog (names, max levels, costs) + the passive_effect rows with the `<requirement>` gates stock applies to each (group-level direct children plus the row's own, MinEffectGroup::ParseXml IL=103 / PassiveEffect::ParsePassiveEffect IL=423), plus the `triggered_effect` rows (same gate shape). The `onSelfProgressionUpdate` rows fire from `Game.fireProgressionUpdate` on every level change (addProgressionLevel / purchaseSkillAtCost, the stock SetProgressionLevel and purchase paths): `perkIntellectMastery` sets `$perkBookwormChance` to 25 at level >= 2 and 0 at <= 1 as data, which the loot RandomRoll gates read. The rows' stat/buff actions are parsed but not applied yet (the perk runtime is open), the same limit the perk passives carry. `<book>` blocks join the catalog because a book is a progression value items.xml grants via SetProgressionLevel(-1). Requirement evaluation is `src/assets/requirements.zig` (incl. HoldingItemHasTags IL=37 against the held item's Tags, SandboxOptionBool IL=18 against the decoded SandboxCode, and ArmorGroupLowestQuality IL=34 against the worn armor groups' lowest quality). `<level_requirements>` blocks (301 stock: 250 ProgressionLevel + 51 PlayerLevel), the per-level `override_cost` tables (7 stock rows) and the `<perks>` container cost/max defaults parse into the catalog for the purchase gate (`Table.calculatedMaxLevel`, ProgressionClass::GetCalculatedMaxLevel IL=343)  `<crafting_skill>` effect_group passives (`CraftingTier` 91, `RecipeTagUnlocked` 73) parse into the skill catalog (2026-09-13).|
| `src/assets/cvars.zig` | R | Per-entity custom variables (CVars): the value store behind the EffectManager's `ModifyCVar`/`RemoveCVar` rows and the `CVarCompare` / `value="@name"` readers. Semantics from `EntityBuffs::SetCustomVar` IL=130 (set/setvalue/add/subtract/multiply/divide with the IL_008A zero-divisor guard, percentadd/percentsubtract on the current value, `changed` false only for an equal `set`), `GetCustomVar` IL=10 (a missing name reads 0), `RemoveCustomVar` IL=21, `CVarOperation.il.txt` for the operation order, and the IL_0106-IL_0139 name-prefix networking rule (`.`/`_` never networked, `%` always). Not a stock data file: the store is a fixed array sized for one entity's CVars |
| `src/assets/requirements.zig` | R | Stock `<requirement>` gates: one parser + evaluator over the EffectManager vocabulary (RequirementBase::ParseRequirementGroup IL=148 direct children, RequirementGroup::EvalAnd IL=66, compareValues IL=37, HasBuff IL=38, InBiome IL=30, ProgressionLevel IL=50, TargetedCompareRequirementBase IL=51). Fail-closed on any kind/target/operand it cannot resolve; `Counts.unsupported` measures the remaining gap (ADR 0023 §2) |
| `src/assets/quests.zig` | A | Load stock `Data/Config/quests.xml` into a playable Quest catalog. Reward `ischosen`/`isfixed` parse generically (any reward kind): the stock CloseQuest payout gates chosen rewards on a rewardChoice list every dedi caller passes as null (RE quests-challenges.md, 2026-08-26), so the server skips them; the player's pick rides the client inventory sync. Also parses the `[quests]` objective-kind spec + policy defaults (ADR 0021) into the catalog's `objective_kinds` / `policy`, and `<event>` blocks (stock: TreasureRadiusReduction → `chance` + nested SpawnGSEnemy gamestage list / count range; unknown event types skipped, so new stock events need no code)  `POIStayWithin`/`StayWithin` radius reads the nested `radius` property, and `biome_filter_type`/`biome_filter` honour `param1` `<variable>` substitution (2026-09-13).|
| `src/assets/recipes.zig` | A | recipes.xml loader: craft outputs + ingredients for server craft queue  `tags` (declared tags plus the recipe name, stock RecipesFromXml IL_0180-0191), `use_ingredient_modifier` and the `<effect_group>` passives parse; `ingredientCount` folds CraftingIngredientCount (198) per ingredient at the crafting tier (2026-09-13).|
| `src/assets/root.zig` | A | Stock game config asset loaders (quests, blocks, items, …). |
| `src/assets/sandbox.zig` | R | Sandbox code codec + option/value-set lookup. Codec (version char + base-26 triples) and decode semantics (unknown ids skipped, invalid index -> default) from `../7dtd-engine-research/docs/admin/sandbox-options.md §3`; value-set and option tables are generated stock data (see sandbox_data.zig). Values: `../7dtd-engine-research/tools/sandbox/sandbox_tables.json` (extracted from `SandboxOptionManager.SetupOptions` IL of V3.1.0 b14) |
| `src/assets/sandbox_presets.zig` | A | GameDifficulty preset ladder, comptime-parsed from the embedded stock `sandbox_presets` TextAsset (`src/assets/sandbox_presets.xml`; the six Difficulty presets' SandboxCodes decode via the sandbox codec to the per-difficulty IncomingDamage/EntityIncomingDamage/RangedDamage/MeleeDamage multipliers, RE sandbox-options.md §3). Source of the XML: the stock client's `7DaysToDie_Data/data.unity3d` (UnityPy extraction, research `tools/sandbox/{sandbox_presets.xml,extract_preset_codes.py}`); the dedi ships no copy, so zdtd embeds the extracted file at comptime rather than hardcoding the ladder (rule 15) |
| `src/assets/sandbox_presets.xml` | A | Stock `Data/Sandbox/sandbox_presets` TextAsset content (client bundle `data.unity3d`, UnityPy extraction; research `tools/sandbox/sandbox_presets.xml`). Comptime-embedded and parsed by sandbox_presets.zig; never hand-edit - re-extract on game update |
| `src/assets/sandbox_data.zig` | R | Generated stock tables: 65 value sets (numeric arrays from `<PrivateImplementationDetails>` FieldRVA) + 165 options (id/name/value-set/default) from the IL census. Regenerate with `../7dtd-engine-research/tools/sandbox/gen_zig_tables.py`; do not hand-edit  Boolean options carry the census default (25 of 32 stock bools default true); the generator no longer forces 0 (2026-09-13).|
| `src/assets/signs.zig` | A | Prefab sign libraries (*_signs.xml under Data/Prefabs) for NetPackageSignDataResponse. Catalog data only; the wire encode lives in wire/stock_sign.zig |
| `src/assets/gameevents.zig` | A | gameevents.xml `<action_sequence>` loader for the server-executable subset (ModifyEntityStat, RemoveDeathBuffs, AddBuff + its CVar gate, ModifyCVar, AddXPDeficit). A sequence holding an action class or a `<decision>`/sequence-level `<requirement>` this server does not evaluate is marked unsupported and refused whole (`missing beats fake`) |
| `src/assets/blockplaceholders.zig` | A | blockplaceholders.xml `<placeholder>` lists (466 stock placeholders) with their weighted `<block>` targets, parsed once: target names resolve to runtime block ids, the `sandboxoption` gate is evaluated against the decoded server code (the value is fixed per run), and the per-cell pick (biome filter, `RandomFromSeedOnPos` seeding, weighted walk, `randomrotation`) is left to the prefab paint pass, which has the world position and the biome |
| `src/assets/spawning.zig` | A | spawning.xml biome spawn rules → director / animal pop |
| `src/assets/storage_pairs.zig` | A | Closed↔Open storage block pairs from blocks.xml DowngradeBlock |
| `src/assets/traders.zig` | A | traders.xml: trader_item_groups, trader_info blocks, and the stock inventory roll (TraderInfo::Spawn, asm.il 862758-863520) |
| `src/assets/unity_hash.zig` | A | Unity Mono / .NET stable string hash (Extensions.GetStableHashCode). |
| `src/assets/vehicles.zig` | A | vehicles.xml physical attributes → sim VehicleKind defaults |
| `src/assets/xml_patch.zig` | A | Clean-room config XML patches (stock XmlPatcher subset; mod-loading.md §5.3). Full verified op catalog: set/setattribute(/byxpath), remove(/byxpath), removeattribute(/byxpath), append/prepend(/byxpath), insertafter/insertbefore(/byxpath), csvoperations, include (@modfolder: tokens); conditional fails closed (RE gap G5). Applies modlet Config dirs (mod order) + --config-overrides (file order)  Patch op vocabulary matches stock's registered names (`csv` too); `setattribute` reads `name=`, `set` handles `/@attr` and element ReplaceNodes, append/prepend target attribute text, remove refuses an attribute path, ops apply to every XPath match, predicates cover contains/starts-with/and/or/existence/position, `<conditional>` evaluates `mod_loaded`/`mod_version` (unknown expressions skip with a warning), and a patch resolves as `<mod>/Config/<configName>` (subdirectory configs included) (2026-09-13). `csv` honours the `delim` attribute (one character or the literal `\n`, default comma) with per-entry add/remove (2026-09-13). |
| `src/assets/xml_util.zig` | A | Tiny helpers for scanning stock 7DTD XML configs (no full DOM) |
| `src/ecs/aidirector.zig` | R | Lightweight AIDirector as ECS resource (world clock, horde, blood moon) |
| `src/ecs/buff.zig` | R | Buff runtime rules: stacking, duration ticks, expiry. Pure over BuffSet, no World and no wire. Every rule mirrors stock EntityBuffs/BuffClass/BuffValu |
| `src/ecs/command.zig` | Z | Fixed tick command buffer: systems/plugins enqueue, drain once per tick. Cap 64; drop when full (no heap, no grow). Soft warn once past ~80% |
| `src/ecs/components.zig` | Z | All sim component types (plain data; no behavior). SoA columns live on World. `Sleeper.groan_sent` + the `SleeperWakeRequest.groan` flag back the SetSleeperActive stir (RE entity-ai.md) |
| `src/ecs/electric.zig` | R | Electricity / power graph: generators, wires, consumers (turrets, lights, …). Simplified from stock PowerManager concepts (not full wiring UI parity). `net_powered` per-node flip drives the Game's powered-door actuation (RE tile-entities-power.md PowerConsumer.HandlePowerUpdate → Block.ActivateBlock isPowered) |
| `src/ecs/entity.zig` | Z | Entity handles for the sim ECS |
| `src/ecs/group.zig` | Z | Cached per-Kind dense slot lists (entt-style non-owning groups). |
| `src/ecs/interest.zig` | Z | Spatial interest: grid cells → nearby players for replication. M11: dirty gating helpers for serialize-once fan-out (encode once, memcpy per peer) |
| `src/ecs/inv_ledger.zig` | Z | P4 inv cause ledger: fixed ring of recent inventory mutations (no heap) |
| `src/ecs/inventory.zig` | R | Inventory systems: move/drop/hold/use/open-container transactions (RE: items.md inventory + protocol-packages.md InventoryTransaction wire; c2s/inv.zig handler) |
| `src/ecs/locals.zig` | Z | Named tick scratch on World. No file-static mutables for sim. Cleared once per tick via World.beginTick / schedule.run |
| `src/ecs/party.zig` | R | Party engine (RE ../7dtd-engine-research/docs/social/parties-factions.md §2). |
| `src/ecs/path.zig` | R | Lightweight grid path helpers for zombie chase (greedy, BFS, A*). |
| `src/ecs/poi_lock.zig` | R | Quest POI lockout table: the server half of QuestEventManager's PrefabInstance.lockInstance (QuestLockInstance, asm.il 1001892-1002045) |
| `src/ecs/powerblocks.zig` | R | Stock electrical block registry from blocks.xml Class + AssignIds. NodeKind mapping is RE (PowerItemTypes); names/ids/watts/fuel come from game data |
| `src/ecs/query.zig` | Z | Kind-group iteration: groupSlice / copyKindInto. No allocation; View scans are file-private tests |
| `src/ecs/quest.zig` | R | Quest catalog (shared resource) + definition types. Runtime journal/wallet live as SoA components; mutations are in systems.zig. Carries `builtin_objective_kinds` (stock objective-type mapping, §3.7), `QuestPolicy` (zdtd-owned kill/radius defaults, §3.7) and `FlatObjective` (per-objective phase completion - stock refreshQuestCompletion requires all non-optional objectives of a phase; arrival objectives carry required 1 since their `value` is a distance) |
| `src/ecs/root.zig` | Z | ECS package root: SoA world, components, systems, resources. |
| `src/ecs/rules.zig` | R | Sim rule parameters (ADR 0021 decision 2): a game mode is mostly these numbers. Carried on `World.rules` (read as `w.rules.<group>.<field>`), set |
| `src/ecs/schedule.zig` | Z | Explicit sim pipeline phases. Ordered only; parallel stays inside a phase (systemZombieAi / systemTurrets via util/parallel). No access-set scheduler |
| `src/ecs/systems.zig` | R | ECS systems: pure functions over World SoA columns + resources. Hot loops (zombie AI, turrets) run multi-threaded over disjoint slots  `classPhysResist` (per-entity class stat, else the class_table row) scales server-computed damage at the deferred accumulator and the turret apply loop (2026-09-14).|
| `src/ecs/world.zig` | R | ECS world: dense SoA columns, resources, O(1) net id map, spawn helpers |
| `src/fuzz.zig` | Z | Coverage-guided fuzz targets for remote wire parsing boundaries and other untrusted-input surfaces (admin lines, map XML, COG headers, |
| `src/litenet/packet.zig` | R | LiteNetLib wire packet property helpers. Property ordinals match the **game** Managed LiteNetLib (7DTD V3.1.0 b14), |
| `src/litenet/peer.zig` | R | Per-endpoint reliable-ordered channel (LiteNetLib-compatible subset). Matches game Managed LiteNetLib PacketProperty ordinals and ack sizing | fragment per-part loop pumps to the outer send deadline (no outer stream restart for live peers) per-peer negotiated MTU from MtuCheck probes caps S2C sizes (low-MTU joins)
| `src/litenet/root.zig` | R | LiteNetLib-compatible UDP transport (peers, packets, std.Io.net UDP). |
| `src/litenet/server.zig` | R | UDP LiteNetLib-compatible server (accept + reliable user data) | ConnectRequest-level rate limit (stock ConnectionRequestCheck, reject_rate_limit Disconnect; 64-entry table with oldest eviction)
| `src/litenet/udp_socket.zig` | Z | UDP socket via Zig 0.16 `std.Io.net` (no raw `std.os.linux` syscalls). Non-blocking poll: zero-duration Timeout → WouldBlock/Timeout |
| `src/main.zig` | Z | zdtd: Zig dedicated server for 7 Days to Die (client wire). Run `zdtd --help` for CLI options and precedence |
| `src/plugin/api.zig` | Z | Static plugin hook types for in-tree test scaffolding only (ADR 0020). Product plugins are Wasm modules (`wasm.zig`); this table is not a shipping |
| `src/plugin/host.zig` | Z | Static plugin host: fixed table, ordered enable/tick/join/shutdown. No dynlib, no Wasm, no heap on the tick path |
| `src/plugin/manifest.zig` | Z | Mod manifests (PRD 0005/ADR 0032): `manifest.toml` parse via toml_bind, tier + override-point vocabulary, `mods/*/manifest.toml` discovery |
| `src/plugin/resolver.zig` | Z | Mod resolution (PRD 0005/ADR 0032): tiers, disabled/blacklist (core protected), exclusive override-point claims, mod-replaces-mod, load-time conflict detection |
| `src/plugin/root.zig` | Z | Plugin package: Wasm guest runtime (ADR 0020) plus in-tree static host as test scaffolding only (`api` / `host` / `sample_hello`). Shipping plugins |
| `src/plugin/sample_hello.zig` | Z | In-tree sample static plugin: logs once on enable |
| `src/plugin/wasm.zig` | Z | Wasm plugin runtime (ADR 0020, zwasm v2): load a .wasm module, instantiate it under fuel and memory budgets, register the minimal host import table, |
| `src/protocol.zig` | R | Wire constants from ../../7dtd-engine-research/docs/network/protocol.md (V3.2.0 pin; V3.1.0/V3.0.1-era goldens still cited). Package IDs are dynamic (PackageIds map); never hard- |
| `src/server/admin.zig` | Z | Minimal TCP admin console transport (telnet-like): one command line per connection. Listen/accept via `util/tcp_listen` (std.Io.net); no std.os.linux. Admin verb surface (2026-08-21): `getoptions` dumps the known serverconfig names with values preferring the GameStats-backed prefs (config.zig `effective` is the loaded-config source); `exportcurrentconfigs` writes `<world_dir>/exported_config.txt`; `loglevel` gates util/log.zig info/warn/err (stock Log.Level 0..4); `listthreads`/`lt` summarizes the logical threads; `commandpermission`/`cp` keeps a per-command required level enforced at the in-game console boundary (stock levels run 0 = highest) |
| `src/server/admin_cmds.zig` | R | Stock telnet console output shapes and the persistent operator lists. |
| `src/server/admin_xml.zig` | R | Stock serveradmin.xml loader (AdminTools state): admins/whitelist/blacklist sections, platform+userid attrs with legacy steamID fallback, permission_level, unbandate DateTime; merged into the operator lists at startup (no stock file-watcher hot-reload; see GAP_ANALYSIS bans row). RE: 7dtd-engine-research dedicated-misc-systems.md. |
| `src/server/admin_console.zig` | R | Operator console surface: admin TCP + webui command handling, the stock telnet reply shapes, persistent operator lists, and the guard/gamestage |
| `src/server/ally.zig` | R | Ally relationships keyed on PlatformUserIdentifierAbs (stock `AllyStore`). |
| `src/server/c2s/blocks.zig` | R | Block editing: SetBlock, BlockTrigger, Explosions. Extracted from the old c2s/inv.zig tail (643-991) verbatim. NetPackagePickupBlock: stock PickupBlockServer IL=77 (type-match + echo + PickupSource/Air replace) with zdtd reach/claim bounds. NetPackageSetBlockTexture: Chunk.SetBlockFaceTexture IL=48 idx-in-face-byte paint into the textureFull plane + dedi rebroadcast (SetBlockTextureServer IL=41) |
| `src/server/c2s/dispatch.zig` | R | C2S dispatch extracted verbatim from game.zig handlePackage. Phase gate + c2s/* fanout; game.zig keeps a one-line forwarder |
| `src/server/c2s/inv.zig` | R | C2S inventory and block editing: player inventory snapshots, holding/item drop/bag, tile-entity edits, inventory transactions, block trigger/setblock. NetPackageItemReload: entity-gated relay to every peer but the sender (ItemReloadServer IL=32) |
| `src/server/c2s/join.zig` | R | Join state machine - extracted from game.zig handlePackage (stock SM). Owns the 7 join packages that must stay coherent: PlayerLogin → | Login VersionAuthorizer gate (LongStringNoBuild compVersion compare, EKickReason.VersionMismatch) player-cap gate (PlayerLimitExceeded) at login
| `src/server/c2s/misc.zig` | R | C2S misc domain: chat, player data / disconnect, dropped packages, game events, quest entity spawns, console commands, damage, lock requests, the NetPackageEntityAnimationData relay (client-originated avatar anim params, stock ProcessPackage IL=64),  The C2S damage claim applies the non-player victim's class PhysicalDamageResist (victim-side state) to the claimed strength (2026-09-14).|
| `src/server/c2s/move.zig` | R | C2S movement and entity-state handling: absolute/relative position, the animation no-op, loot-bag collect, alive flags, motion speeds (sprint |
| `src/server/c2s/quest.zig` | R | C2S quest/social/trade domain: shared quests, party and ally actions, buff add/remove, quest events and objective updates, the NPC quest list, |
| `src/server/c2s_text.zig` | R | C2S text trust boundary: player names, chat bodies, player console verbs. Pure helpers (no Game / net types). Extracted from game.zig for navigability |
| `src/server/config.zig` | Z | Minimal serverconfig.xml subset (port, max players, world name, password) |
| `src/server/evidence.zig` | Z | P4 observe evidence: fixed ring of detector events (no secrets, no IP, no packets). Admin `evidence dump [path]` flushes the ring as JSONL via |
| `src/server/game.zig` | R | Game server: join SM, tick, interest, combat, persistence. RE-derived: server-lifecycle.md (join SM), loop.md (tick), network.md (interest), combat-damage.md, save-persistence.md; simulation is an SoA ECS (`ecs.World` + systems) |
| `src/server/game/bans.zig` | Z | Ban / rate-limit helpers extracted from game.zig |
| `src/server/game/bot.zig` | Z | Host-side FPS BotManager (ADR 0026): fixed 16-slot bot table, move/look/shoot/spawn/remove/count verbs, move integration, sense fill. Bots are deliberately NOT ECS entities (zdtd architecture, 2026-08-12); the flat `bot_shoot_damage`/`bot_max_hp` values moved verbatim from the old `ecs/command.zig` host floor. The operator-facing defaults are now `BotHostConfig` (`[bots]` config, ADR 0021; §3.7); `bot_max_hp` 100 stays a wasm guest contract |
| `src/server/game/blockmeta.zig` | R | Sparse block meta + damage persist extracted from game.zig |
| `src/server/game/chunk_fill.zig` | R | Chunk materialization and loot-fill senders, extracted verbatim from game.zig: sendSpawnChunk (resident-miss load + stock Chunk.write encode), the per-chunk storage/prefab TE scan with deterministic loot roll, the container spill (tryContainerSpill) and the harvest-drop roll (tryBlockHarvestDrop: Block.DropItemsOnEvent IL=246 count/prob roll → breaker inventory via invsys.give, overflow → ground bag, position+tick-seeded; GameUtils.HarvestOnAttack IL=623 count = trunc(rolled x tool HarvestCount multiplier, items.harvestMultiplier)), |
| `src/server/game/chunk_stream.zig` | R | Chunk streaming senders, extracted verbatim from game.zig: the join spawn area burst (sendSpawnArea), the per-tick view-square stream with |
| `src/server/game/clock_persist.zig` | R | World-clock persist extracted from game.zig (ZCL2: worldTime u64 plus persisted blood-moon schedule; reads legacy ZCL1) |
| `src/server/game/config_files.zig` | R | Config-file S2C: stock `SendXmlsToClient` / `NetPackageConfigFile` (mod-loading.md §5.6, protocol-packages.md IL=25). Deflate cache of the patched 42 S2C rows built once at init (PRD R8); join send streams name + i32 len + blob per row (archetypes name-only), framed with the stock compressed envelope (G7, `frame.zig` DeflateFramer). Divergence: null cache sends -1 instead of stock's skip so a vanilla client's config wait completes (PRD R9) |
| `src/server/game/constants.zig` | R | Game-wide constants re-exported by game.zig. Keeps the 40-line help table and a few caps out of the main file. Behavior-identical: re-exported as |
| `src/server/game/craft.zig` | R | Crafting and workstation helpers, extracted verbatim from game.zig: tryCraft/tryCraftRecipe (InvTx craft op), tickWorkstations (burn/craft +  `craftingTierFor` folds the player's crafting-skill and perk CraftingTier rows (stock Recipe.GetCraftingTier IL=22; flat 6 when the CraftingProgression sandbox option is off), ingredients scale through `assets_recipes.ingredientCount`, and a crafted HasQuality item is deposited at that tier (2026-09-13).|
| `src/server/game/deco.zig` | R | Deco helpers extracted verbatim from game.zig (purest game.zig shard). Species resolution, multiblock dim cache, mirror into block store |
| `src/server/game/guard.zig` | Z | Guard/evidence helpers extracted from game.zig |
| `src/server/game/harness.zig` | R | In-process test and scenario helpers for joined clients, packet injection, replication, and direct world setup. Production networking does not use |
| `src/server/game/hooks.zig` | R | ECS hooks: sim callbacks that read Game / World state. Verbatim move from game.zig - thin wrappers remain there as `ctx: ?*anyopaque` adapters |
| `src/server/game/init_assets.zig` | R | Asset loading for Game.init - extracted verbatim from game.zig. Takes *Game and InitOptions, mirrors the original inline sequence so the |
| `src/server/game/init_world.zig` | R | Post-asset init: sleeper volumes, network listen, seed entities, power demo. World-store initialization and persisted-world restoration for `Game.init |
| `src/server/game/join.zig` | R | Join-bundle encoders and senders. Helpers take `*Game`; `game.zig` exposes forwarding methods where the main state machine needs method syntax |
| `src/server/game/lifecycle.zig` | R | Shutdown ordering for Game: flush every store, then tear down subsystems. Player persistence lives in server/persist.zig; callers go there directly |
| `src/server/game/locks.zig` | R | Lock helpers extracted from game.zig - pack/unpack + slot bookkeeping |
| `src/server/game/loot.zig` | R | Loot / item-table helpers - extracted verbatim from game.zig. ecsIdFromItemName, loot bags, and loot-spawn broadcasts |
| `src/server/game/movement_helpers.zig` | R | Movement envelope helpers extracted from game.zig. Power-grid trigger activation and horizontal speed envelope |
| `src/server/game/net.zig` | R | Net send path for Game: reliable-window pump, framed fan-out, and the broadcast helpers | Pre-auth challenge is CSPRNG-derived (stock Guid.NewGuid, asm.il 852999); per-connection accept-path init only sendGameBudget deflates the stock get_Compress()=true set (Chunk/ConfigFile/IdMapping/SignDataResponse)
| `src/server/game/net_handlers.zig` | R | Net ingress extracted from game.zig - onConnected / onData / dispatchGamePayload. Verbatim bodies; game.zig keeps one-line forwarders | PlayerDenied after PackageIds for deferred join rejects (banned)
| `src/server/game/player.zig` | R | Player progression / gamestage / XP - extracted from game.zig; helpers take *Game. `awardXp` notifies the owner with `NetPackageEntityAddExpClient` `_xpOther`; kill XP uses `awardXpSilent` plus a typed Kill packet. **Loot stage partial (2026-08-12):** `lootStageOf` is level-driven only - the stock `EntityPlayer.GetLootStage` (loot-economy.md 8, IL=184) POI-tier and biome terms (`POITierMod` x `POITierLootStageModifier`, biome `LootStageMod/Bonus` x `BiomeLootStageModifier`, passive **159** scale, GameStats **66** clamp) are pending the loot/POI tables; `partyLootStage` = `GetHighestPartyLootStage` high-water mark (implemented, stock-shaped). |
| `src/server/game/quest.zig` | R | Quest helpers - journal snapshots + trader offers + POI quest events. Extracted from game.zig; helpers take *Game (called as game_quest.foo(g, …)) |
| `src/server/game/rate_limits.zig` | Z | C2S rate limits extracted from game.zig. Inv/block token buckets, damage burst, chat gap |
| `src/server/game/replicate.zig` | R | Serialize-once replicate fan-out extracted from game.zig. Verbatim move - called via forwarder in game.zig |
| `src/server/game/replicate_health.zig` | R | Health replicate path - extracted verbatim from game.zig. Thin forwarder keeps callers unchanged |
| `src/server/game/rescue.zig` | R | Deep-void rescue extracted from game.zig |
| `src/server/game/send_extra.zig` | R | Framed send helpers extracted from game.zig |
| `src/server/game/session_drop.zig` | R | Client slot teardown extracted from game.zig |
| `src/server/game/sleeper.zig` | R | Sleeper-volume scan + spawn extracted from game.zig |
| `src/server/game/social.zig` | R | Buff + party/ally helpers extracted from game.zig (verbatim bodies) |
| `src/server/game/stability.zig` | R | Stability helpers extracted verbatim from game.zig |
| `src/server/game/step.zig` | R | Main tick step - extracted verbatim from game.zig. `Game.step` and helpers that are only called from the step. The quest reward payout skips ischosen rewards (stock CloseQuest null rewardChoice; the pick rides the client inventory sync, RE quests-challenges.md 2026-08-26) |
| `src/server/game/tests.zig` | R | Game integration tests: peerIpKey, player persist, claims, evidence, etc. Bodies are verbatim copies from src/server/game.zig (kept as integration tes |
| `src/server/game/map.zig` | R | In-game minimap: MapChunks window send + per-chunk 256 RGB555 colors (CalcChunkColors -> Block.GetMapColor -> atlas color -> ToColor5; water = BlockLiquidv2.Color) and the 6 s PersistentPlayerPositions player-marker broadcast. RE: `../7dtd-engine-research/docs/world/texture-atlas.md`, `protocol-packages.md §3.3` + PersistentPlayerPositions |
| `src/server/game/tick.zig` | R | Tick orchestration - extracted from game.zig; helpers take *Game. Bodies are verbatim copies from src/server/game.zig (stock asm.il comments kept) |
| `src/server/game/trader.zig` | R | Trader helpers extracted verbatim from game.zig  The traderAlways fallback applies only when no `<trader_info>` row resolved; a resolved row with no `<trader_items>` stays empty (2026-09-13).|
| `src/server/game/trader_wire.zig` | R | Trader wire helpers extracted from game.zig. stockEntries + sendTraderSnapshot + handleTrade + applyTraderDataCopyFrom |
| `src/server/game/types.zig` | R | Game-owned types extracted from game.zig: InitOptions, defaults, LandClaim, Client. Canonical definitions live here; game.zig re-exports them so exist |
| `src/server/game/vehicle.zig` | R | Vehicle seat + positions S2C helpers - extracted verbatim from game.zig. seatRider / unseatRider (NetPackageEntityAttach) and the periodic |
| `src/server/game/wasm_host.zig` | R | Wasm host shims for Game - callbacks the plugin layer calls back into. Extracted verbatim so game.zig keeps only a re-export |
| `src/server/game/weather.zig` | R | Weather S2C helpers - extracted verbatim from game.zig. anyEnteredClient, the NetPackageWeather body builder and its send paths |
| `src/server/game/world.zig` | R | Domain - extracted from game.zig; helpers take *Game World / claims / block meta / locks. Bodies copied verbatim from game.zig |
| `src/server/guard_policy.zig` | Z | P4 guard policy: what the server *does* with detector evidence. |
| `src/server/mcp_transport.zig` | Z | MCP transport bridge (ADR 0031): HTTP listener + token auth + frame/response copy for the MCP plugin guest. Protocol from the public MCP spec (modelcontextprotocol.io, JSON-RPC 2.0), no stock code |
| `src/server/preset.zig` | Z | Preset = config pack (+ optional static plugin flag). ADR 0010 step 3. Data-only TOML under presets/<name>.toml (a config-only mod ships its own preset inside the mod folder; renamed from mode.zig 2026-08-29). No script VM |
| `src/server/movement.zig` | R | Horizontal movement envelope: max speed over server dt, clamp to last good. No heap; pure math for PosAndRot / RelPosAndRot C2S |
| `src/server/persist.zig` | Z | Save/restore for zdtd-owned persistence: players.zsv (ZPV15), entities.zen (ZENT), claims.zlc (ZCLC), clock.zcl, weather.zwt (ZWTH1), traders.zst (ZTR1: per-trader stock keyed by trader name, entries by item name so AssignIds version drift fails closed) and the chunk. **ZPV6 (2026-08-21):** journal entries persist the quest name (the stock Quest.Write identity - RE: quests-challenges.md; the saved quest resolves by name on restore, so a quests.xml edit cannot reshuffle it), the accepted POI rect (stock PositionData[2/3]) and per-objective progress (stock BaseObjective.Write per-objective CurrentValue). **ZPV7 (2026-08-22):** the inventory slot record widens 7 -> 11 bytes by appending `use_times` (stock ItemValue.UseTimes, f32) so tool durability survives a relog; v2-6 files still read and upgrade in place (slots widened with zero use_times, journals re-encoded as before). **ZPV8 (2026-08-22):** the progression tail adds the player's current `hp` (0..max, restored on the post-spawn pass) so a relog keeps wounds instead of a free full heal; v2-7 tails migrate with a -1 sentinel (spawn full health stands). **ZPV9 (2026-08-22):** the tail adds the game-stage born world time (u64) so days-alive survives a restart; v2-8 tails migrate with a zero born time (pre-ZPV9 behavior). **ZPV10 (2026-08-23):** each inventory slot's ItemValue seed persists (magic byte 'A' after "ZPV") so stack/quality RNG is stable across a relog. **ZPV11 (2026-08-25):** the tail appends skill_points + purchased attribute/perk levels (magic byte 'B') so the spend ledger and the level-scaled VM effects restore (row below). **ZPV12 (2026-08-26):** the slot record widens 13 -> 17 bytes by appending the 4 item mod ids (magic byte 'C'), closing the mods round-trip. **ZPV13 (2026-09-10):** the dropped-bag marker list (`n:u8 | n x (x,y,z i32)`) appends after the skill tail (magic byte 'D') so a bag restored from entities.zen still shows on its owner's map. **ZPV15 (2026-09-11):** the record appends its owner's platform identity (`id_present:u8 | present:u8 | plat_len:u8 | id_len:u8 | strings` for the primary and native ids, magic byte 'F') so restore and merge-write key on the account, not the login display name: stock keys PlayerDataFile on `PrimaryId.CombinedString` (asm.il 1884842), and a name key let any client load another player's save by typing their name (DIVERGENCES 1.6). A row that carries an identity is owned by that account whatever the name; a legacy row with no identity matches by name once and gains one on the next save. **ZPV14 (2026-09-11):** the character-sheet kill/death counters (`deaths:i32 | zombieKills:u32 | playerKills:u32`) append after the bag list (magic byte 'E') so a restart or relog keeps what stock stores in PlayerDataFile and the join PDF carries the restored totals; ZPV13 and older records upgrade in place with zero counters. **ZWTH1 divergence (2026-08-12):** the stock WeatherManager blob (weather-environment.md 6, byte-exact-verified: version u16 4 + gate byte + per biome 40 B = id u8 + weather group u8 + stormWorldTime i32 + stormDuration i16 + nextRandWorldTime i32 + 5 params [T,P,C,W,F] + rain f32 + snow f32) is NOT the format ZWTH1 writes - zdtd's own 49 B/state layout omits the rain/snow floats and uses i64 times + an explicit storm_state/has_storm, and it lacks the stock version u16 + GamePrefs-60 gate. Behavioral fields map 1:1 (stormWorldTime/Duration/nextRand, group index, 5 params). |
| `src/server/phase_gate.zig` | R | Per-package C2S phase allowlist (join SM × package name). Hot path: string compares against static tables; no heap |
| `src/server/replicate_te.zig` | R | Tile-entity replication: the S2C wire out for workstations, storage containers, vending machines and powered blocks  Vending fill stocks from traderAlways only when the `trader_info` row is unresolved (2026-09-13).|
| `src/server/root.zig` | Z | Server process layer: Game orchestration, config, admin/GSI TCP, scenarios. |
| `src/server/scenarios.zig` | Z | Integration scenarios: two-peer motion, damage wire kill, setblock replicate, persist restart. These call shipped Game handlers (onData/handlePackage/ |
| `src/server/serverinfo_tcp.zig` | R | Stock ServerInformationTcpProvider: TCP on ServerPort serves GameServerInfo text. |
| `src/server/webui.zig` | Z | Operator web UI HTTP listener (WU0–WU2: dashboard + console cmds). Loopback by default; shared secret required when enabled  The Modules partial lists the scanned modlets with per-mod enable/disable forms posting to the CSRF-gated `/api/modlet`, which persists the state and re-renders the partial (2026-09-13).|
| `src/server/zdtd_config.zig` | Z | zdtd.toml: operator tunables (Bucket B), not stock serverconfig. Precedence (applied by caller): CLI > env (webui secret) > world/zdtd.toml > |
| `src/util/arena.zig` | Z | Lazy/eager scratch-arena helpers shared by asset table loaders. |
| `src/util/clock.zig` | Z | Monotonic nanoseconds and best-effort sleep. |
| `src/util/io_fs.zig` | Z | Thin wrappers around Zig 0.16 `std.Io` for one-shot FS ops. Ordinary file/dir work goes through here or `std.Io` directly, never |
| `src/util/log.zig` | Z | Leveled logging (debug/info/warn/err/crit on the stock Log.Level 0..4 ladder). |
| `src/util/parallel.zig` | Z | Parallel-for over dense slot ranges with a persistent worker pool. Uses Zig 0.16 `std.Io` mutex/condition (no raw syscalls, no spawn-per-call) |
| `src/util/rng.zig` | Z | Seeded deterministic PRNG for sim paths (loot, AI wander, director picks). |
| `src/util/root.zig` | Z | Shared process utilities (no game domain). |
| `src/util/secret.zig` | Z | Secret comparison helpers shared by every credential check (LiteNet connect key, webui secret, telnet admin password) |
| `src/util/sim.zig` | Z | Deterministic simulation mode: virtual clock + serial parallel ranges + DST fault injection lifecycle. Enable at the start of a DST harness so |
| `src/util/sys_metrics.zig` | Z | Host OS gauges for the ops dashboard (sysinfo + getrusage, no /proc reads): load 1/5/15, RAM free+buf/total, proc CPU/RSS/uptime |
| `src/util/tcp_listen.zig` | Z | Non-blocking TCP listen helper via Zig 0.16 `std.Io.net` listen + thin posix accept/read/write. No `std.os.linux` in callers (admin, GSI, webui) |
| `src/util/toml_bind.zig` | Z | toml_bind.zig: comptime-reflected TOML-subset binder (ADR 0021 decision 1). |
| `src/version.zig` | Z | Product and compatibility versions reported to operators |
| `src/wire/binary.zig` | R | Little-endian readers/writers matching .NET BinaryReader/Writer (7-bit strings) |
| `src/wire/frame.zig` | R | Game channel envelope + inner packages (stock NetConnectionSimple layout) |
| `src/wire/packages.zig` | R | Golden package body builders/parsers for join, motion, damage, spawn, TE. Prefer this facade for all wire/stock_* body modules (and te_types); leaf. parse/buildPickupBlockBody = NetPackagePickupBlock layout (inventories/netpackage-bodies.md); parse/buildSetBlockTexture = NetPackageSetBlockTexture layout; parseItemReload = NetPackageItemReload layout | parsePlayerLogin reads version/compVersion (LongStringNoBuild form) + KickReason.version_mismatch channelFor picks the envelope channel by package name (stock get_Channel set)
| `src/wire/platform_user.zig` | R | PlatformUserIdentifierAbs wire codec (stock V3.1.0 b14). |
| `src/wire/root.zig` | R | Wire package layer: binary LE helpers, frames, stock body builders. |
| `src/wire/stock_buff.zig` | R | Stock buff wire (V3.1.0 b14): NetPackageAddRemoveBuff body and the EntityBuffs blob carried by NetPackageEntityStatsBuff and PlayerDataFile.buffData |
| `src/wire/stock_chunk.zig` | R | Stock `Chunk.write(PooledBinaryWriter, bNetwork=true)` encoder. Derived on V3.0.1, verified against the V3.1.0 b14 client: the live join. Network-mode specifics re-confirmed 2026-08-12 against the byte-exact-verified `Chunk.write` IL=601 (save-region.md 2): stability channel skipped, topsoil 32 B raw, custom-data count network-filtered, sleeper/trigger skipped while wall volumes are ALWAYS written, trailing network flag false. TEs/entities count 0 (not yet implemented). |
| `src/wire/stock_deco.zig` | R | Stock NetPackageDecoUpdate + DecoObject wire (derived V3.0.1, live on V3.1.0 b14). Client fixed-size worlds only show grass/trees from server deco pac |
| `src/wire/stock_entity.zig` | R | Stock EntityCreationData + NetPackageEntitySpawn (networkWrite=true). |
| `src/wire/stock_inv.zig` | R | Stock inventory wire (ItemValue/ItemStack/Bag/Equipment/NetPackagePlayerInventory). Derived on V3.0.1, carried to V3.1.0 b14; version-specific fields. `applyEquipmentBody` parses the standalone NetPackagePlayerEquipment body (Equipment.Read IL=93, pinned in netpackage-bodies.md 2026-08-26) for the C2S equip-sync |
| `src/wire/stock_nameid.zig` | R | Stock `NameIdMapping` blob (the `data` payload of NetPackageIdMapping). |
| `src/wire/stock_party.zig` | R | NetPackagePartyActions (ToServer) + NetPackagePartyData (ToClient) bodies (RE ../7dtd-engine-research/docs/social/parties-factions.md §3) |
| `src/wire/stock_quest.zig` | R | Stock quest journal + NPCQuestList QuestPacketEntry wire (V3.x). Matches QuestJournal.Write v5, Quest.Write (FileVersion 8), and |
| `src/wire/stock_sign.zig` | R | Stock NetPackageSignDataResponse body builder (prefab sign libraries). Entry data (`SignEntry`, catalog load) lives in assets/signs.zig; only the |
| `src/server/game/game_events.zig` | R | Runs a parsed gameevents.xml sequence for a player (`GameEventManager` death/respawn semantics: the client's HandleActionClient IL=416 only forwards NetPackageGameEventRequest, the server branch IL_006B executes). Owns the `game_on_death_*`/`game_on_respawn_*` name selection by DeathPenalty (PlayerMoveController IL_0E38, EntityPlayer IL=71), stat writes, death-buff removal with the injured tag exclusion, the AddBuff CVar gate and cvar writes. No stock numbers: the effects come from the parsed table |
| `src/wire/stock_te.zig` | R | Stock V3.1.0 NetPackageTileEntity payload for composite storage (network modes). |
| `src/wire/stock_xp.zig` | R | NetPackageEntityAddExpClient body (ToClient XP grant; RE ../7dtd-engine-research/il/netpackages-v3.1.0/NetPackageEntityAddExpClient_il.txt) |
| `src/wire/te_types.zig` | R | Stock TileEntityType enum values (RE: TileEntityType / network TE discriminant). Named constants only; not loaded from XML (engine enum, not game data |
| `src/world/biomes.zig` | R | Load stock `biomes.png` (RGBA8 non-interlaced) for chunk biome ids. PNG pixels = biomemapcolor RGB keys (biomes.xml), NOT biome ids |
| `src/world/chunk_flush.zig` | Z | Async chunk flush: encode on the tick thread, write on one background thread. |
| `src/world/containers.zig` | Z | World-position keyed loot containers (block TE storage). `max_containers` 4096 + world-container eviction (2026-08-21): Navezgane-scale maps have thousands of loot containers; when the table is full, getOrCreate reuses a non-player-placed container (regenerated deterministically from the next chunk scan) and never evicts a player-placed chest |
| `src/world/signs.zig` | Z | **zdtd-owned** sign-text store (Rule 21 persistence). Keyed by world pos; holds the applied composite `NetPackageTileEntity` body verbatim, because stock's server applies the client's composite to its own `TileEntitySignable` and reserializes the same bytes (`NetPackageTileEntity::ProcessPackage` IL=103), so a second encoder could only drift from the module order the client sent. The chunk stream replays a stored body (handle patched to stock's unsolicited `255`) so a client that streams the area later sees the authored text, and the C2S leg drops the entry when the block goes away. Format `ZSG1` (magic, count, records) is zdtd-owned; stock keeps TE data inside its region files |
| `src/world/deco_mirror.zig` | R | Mirror placed decorations into the server block store, so collision, harvest and chunk streaming agree with what the client renders |
| `src/world/dem.zig` | R | Copernicus GLO-30 DEM codec: COG header parse, tile decode, S3 object key and elevation-to-block mapping (fuzz-covered in src/fuzz.zig). The S3 |
| `src/world/dtm.zig` | R | Stock 7DTD baked heightmap loader (Navezgane / Pregen*). |
| `src/world/noise.zig` | Z | OpenSimplex2-family gradient noise (clean-room) + fBm / ridged / domain warp. Pure functions of (seed, coords): no global RNG. Same seed+coords always |
| `src/world/prefabs.zig` | R | Stock world prefabs.xml index + footprint stamping on heightmaps. Block paint: stock `.tts` via `tts.zig` (Prefab.readBlockData raw types), |
| `src/world/root.zig` | Z | World store layer: chunks, map data (DTM/prefabs/TTS), containers, TE state. |
| `src/world/nav.zig` | Z | Coarse walkability grid + BFS pathfinding for bots. Borrowed in spirit from the Recast/Detour navmesh used by Unvanquished bots (see `../7dtd-fps-bots/docs/oss-fps-bot-survey.md`): host owns geometry, wasm guest owns decisions. |
| `src/world/sleepers.zig` | R | Prefab sleeper volumes: parse XML + wake/spawn on player enter. **Re-arm (2026-08-26):** `respawn_time`/`spawned_alive` per volume, the ZSTG1 v2 respawn_time tail (backward-compatible load), and the ClearedUpdate-equivalent (stock ClearedUpdate IL=33 + CheckTrigger IL=136: respawnTime = worldTime + LootRespawnDays x 24000 ticks after the group dies; a later player entry re-arms). **ZSCL1 (2026-08-21):** quest-cleared volume rects persist in `sleepers_cleared.zsc` (a completed ClearSleepers quest suppresses its POI's volumes, stock QuestEvent_SleepersCleared removes the POI's sleeper data; the marker stops re-arm on re-trigger and restart) |
| `src/world/stability.zig` | R | Stock block stability plane and falling-block trigger (RE: `../7dtd-engine-research/docs/world/stability.md`, dumps 2026-08-06) |
| `src/world/sky.zig` | R | Stock SkyManager day/night model (RE `../7dtd-engine-research/docs/entities/entity-ai.md` SkyManager pin 2026-08-26): TimeOfDay, UpdateSunMoonAngles sun target, CalcDayPercent curve, GetLightLevel ambient term. Slice 1 of the clone-side world-light model; the moon term SHIPS 2026-08-27 (moonAmbientScale in step.zig), block light / moving lights / shade stay recorded later slices |
| `src/world/store.zig` | R | Authoritative block world: 16×256×16 columns, DTM heights, ZCH3 disk (.zch). v3 magic ZCH3: heights + optional u32 rawData + optional texture/density |
| `src/world/subbiome_noise.zig` | R | Stock subbiome noise for deco placement (GAP_ANALYSIS 18): a clean-room port of `PerlinNoise` + `WorldBiomeProviderFromImage::GetSubBiomeIdxAt`, so |
| `src/world/terrain_snapshot.zig` | R | Read-mostly terrain footing snapshot for the A* inner loop. |
| `src/world/tts.zig` | R | Stock prefab `.tts` block paint (Prefab.readBlockData, V3.x file version 19). |
| `src/world/vending.zig` | Z | World-position keyed vending machine tile entities (TileEntityVendingMachine). |
| `src/world/light_te.zig` | R | Prefab `.tts` Light (18) TE persistency payloads (RE TileEntityLight.read IL=68 + TileEntity.il base read): parsed intensity/range/Color32/type/angle/shadows plus the version-gated state/rate/delay tail into a world store; the network body lives in `wire/stock_te.zig` (TileEntityLight.write IL=48). |
| `src/world/water.zig` | R | Stock water_info.xml point sources (used as local water-table hints); the leveling queue backing the dig-leveling pour (zdtd-owned, GAP water flow PARTIAL) |
| `src/world/weather.zig` | R | Stock WeatherManager storm / bloodMoon state machine, server side. Live-verified 2026-08-12: stock `weather` telnet dump shows the 5-slot param vector (Temperature/Precipitation/CloudThickness/Wind/Fog) per biome, `default` group, no storms in the day-1 grace (worldTime < 22000), and `weather clouds N` drives forceClouds (value/100) -> GetCloudThickness. |
| `src/world/weather.zig` storm schedule | R | `update_interval_ticks = 5` matches stock `BiomeWeather.ServerTimeUpdate` cadence; storm_state 0/1/2 (clear/stormbuild/storm) matches stock `BiomeWeather.stormState`. |
| `src/world/workstations.zig` | Z | World-position keyed workstation state (forge/campfire/workbench TE 12). Slots mirror TileEntityWorkstation arrays; craft tick advances the queue  The craft output keeps the queue item's quality, so two crafts at different tiers never merge (stock TileEntityWorkstation builds the output ItemValue from RecipeQueueItem.Quality) (2026-09-13).|
| `src/world/worldgen.zig` | R | On-the-fly procedural chunk generation (W0/W1/W2). Pure function of (seed, chunkX, chunkZ): no full-map bake, no global RNG |
## 3. Constants ledger (behavioral values)

Every constant below changes game behavior. Source is the stock XML element or
the IL-verified RE doc that specifies it. Where zdtd diverges from stock, the
row says so and names the tracking item. Constants that only size arrays or
pace the wire are covered by their file's row in §2 and are not repeated here.

### 3.1 Sim rules (`src/ecs/rules.zig`)

The complete rule surface (`Combat` / `Ai` / `Bloodmoon` / `Progression` /
`WorldGroup`) carries **inline provenance on every field** in
`src/ecs/rules.zig` (each field's comment names its stock source or marks it
policy). The rows below highlight the fields that diverge from stock or are
the system's load-bearing values; the inline comments are the authoritative
field-by-field provenance.
| Constant | Value | B | Stock source |
|---|--:|:-:|---|
| `Combat.attack_damage` | 8.0 | A | **Floor**: `entityclasses.xml` HandItem → `items.xml` DamageEntity wins when non-zero |
| `Combat.attack_cooldown_s` | 1.2 | R | Policy: stock melee interval approx, no entityclasses field |
| `Ai.sense_dist_sq` | 48² | A | **Floor**: `entityclasses.xml` SightRange (stock 27/30/40 m per class) |
| `Ai.chase_speed` | 2.2 | A | **Floor** (night): `entityclasses.xml` MoveSpeedAggro max ×1.6 when non-zero; the day branch uses MoveSpeedAggro min (`chase_speed_day`, plus the MoveSpeedRand per-entity roll, clamp 0.1 / cap at max, RE 3318-3320), same floor. RE entity-ai.md GetMoveSpeedAggro (dark → passive 134 max, day → passive 133 min; the stock XML comment "min/max (like day or night)" pins the split) |
| `Ai.wander_speed` | 0.8 | A | **Floor** (day): `entityclasses.xml` MoveSpeed ×10 when non-zero; the night branch uses MoveSpeedNight (`wander_speed_night`, seeded from MoveSpeed when absent). RE entity-ai.md GetMoveSpeed |
| `wanderUpdate` routing | chaseAlongPath | R | Wander paths on the A* navmesh like the chase (stock EAIWander walks to the spot via the navmesh, asm.il:438366); step_fn-gated, direct-line fallback without a step hook |
| `Ai.full_dist_sq` / `mid_dist_sq` | 64² / 225 | R | LOD steps (RE: entity-ai.md AI LOD) |
| `Ai.execute_delay_scale` | 0.85 | R | `EAITaskList.executeDelayScale` base (asm.il:437541) |
| `Ai.look_turn_speed_deg` | 250.0 | A | Per-class MaxTurnSpeed, zombieTemplateMale (`entityclasses.xml`) |
| `Ai.revenge_window_s` | 20.0 | R | Revenge target window, 400 ticks @ 20 Hz (RE: entity-ai.md) |
| `Ai.gravity` | -1.6 | R | Stock `World::Gravity` **0.08** blocks/tick (World cctor, World.il.txt:96) integrated `(motion.y - Gravity) * 0.98` per tick (entity-movement.md) -> ~1.6 blocks/s², self-capping ~ -3.9 |
| `Bloodmoon.party_*` | 80/150/40/30 | R | `AIDirectorBloodMoonParty` (asm.il 413090-413140) |
| `Difficulty.*` | 0.5/0.75/1.0/1.5/2.0/2.5 (Scavenger..Insane) | R | `ItemActionAttack.difficultyModifier` mixed-control PvE scalers (combat-damage.md): server/AI→client × `IncomingDamage`, client→server × `EntityIncomingDamage` (client-side in stock; server trusts the claimed strength, ProcessPackage IL=172). Full 0..5 ladder SHIPS 2026-08-26: the six Difficulty presets were extracted from the stock client bundle's `Data/Sandbox/sandbox_presets` TextAsset (UnityPy, research tools/sandbox) and are comptime-parsed from the embedded XML into `[rules.difficulty] incoming_damage_0..5` defaults, applied at the AI→player deferred-damage choke (damageScale, systems.zig); EntityIncomingDamage stays 1.0 on every tier; an operator SandboxCode option-17 flat override wins over the ladder exactly like stock |
| `Progression.*` | see fields | Z | **zdtd-owned offline/policy floor** (WORK_PLAN T16 shipped 2026-08-27): with stock data the survival pass consumes buffs.xml `buffStatusHungry01-03` / `Thirsty01-03` conditional stages + `FoodChangeOT`/`WaterChangeOT`/`HealthChangeOT`/`StaminaChangeOT` (passive-effects VM) + items.xml `StaminaLoss`; the Rules rates apply only to offline/test worlds (Rules-as-floor doctrine) |
| `Sky` day boundary (`clock.dawn`/`clock.dusk`) | 4 / 22 | R | `GameUtils::CalcDuskDawnHours(DayLightLength)` via the world clock (IL=45, weather-environment.md; the stock DayLightLength 18 → dawn 4 / dusk 22); bounds of the `UpdateSunMoonAngles` day window (RE: entity-ai.md SkyManager pin 2026-08-26) |
| `Ai.crouch_sleeper_detect_min/max` | 3 / 15 | R | `PlayerStealth.CanSleeperAttackDetect` FastLerp bounds (IL=20; entity-ai.md); t = `lightAttackPercent` = passive-89 when selfLight (held-item light) < 0.1 (TickServer IL_010B) |
| `Ai.sight_light_threshold_min/max` | 30 / 100 | R | `CanSeeStealth` threshold floor pair (IL=21; the stock `EntityClass` cctor default; `zombieTemplateMale` overrides to -2,150 in entityclasses.xml, parsed per class) |
| `Ai.stealth_light_passive` | 0.89 | R | `PlayerStealth.TickServer` passive-89 fold for `lightAttackPercent` when the player's selfLight (held-item light) < 0.1 (IL_010B; entity-ai.md) |
| `world/sky.zig` day curve / ambient | 0.6 / 0.68, `^0.6 × 0.5` | R | `SkyManager.CalcDayPercent` (IL=54) + `LightManager.GetLightLevel` ambient term (IL=117); slice 1 collapses `AmbientTotal` to the day curve; the moon term SHIPS 2026-08-27 (moonAmbientScale), block light / moving lights / shade stay recorded later slices |

### 3.2 AIDirector (`src/ecs/aidirector.zig`)

| Constant | Value | B | Stock source |
|---|--:|:-:|---|
| `bm_parties_cap` | 8 | R | Blood-moon party array cap (RE: aidirector.md) |
| `game.zig playerBloodMoonMusic` | party_join_dist | R | Per-player horde-music eligibility: true while the horde is active and the player's own blood-moon party focus (within party_join_dist) has alive horde zombies (stock EntityPlayer.bloodMoonParty; the old global bool was the multi-party approximation) |
| `wandering_horde_size` | 6 | R | **Approximation**: stock per-horde size is gamestage-group driven (live-observed 2026-08-11: `Party of 1, GS 1 ... enemy max 5`); fixed 6 here (aidirector.md wandering section) |
| `wandering_spawn_dist` | 92.0 | R | `AIDirectorHordeComponent.FindTargets` inline start offset `RandomOnUnitCircle * 92f` (IL_018B; aidirector.md placement constants) |
| `wander_min_gap` / `wander_max_gap` | 12-24 in-game hours | R | `ChooseNextTime` `Random(12000, 24000)` world-time units (12-24 in-game hours; aidirector.md wandering schedule; live-verified 2026-08-11) |
| `heat_cooldown_seconds` | 120 | Z | **Diverges**: stock `AIDirectorChunkData.FindBestEventAndReset` region cooldown is **240 s** (aidirector.md 2026-08-07; audit A41) |
| `heat_neighbor_cooldown_seconds` | 60 | Z | **Diverges**: stock `StartCooldownOnNeighbors` 180 s / 720 s (aidirector.md; audit A41) |
| `heat_spawn_threshold` | 25.0 | R | Heat threshold for spawner events (RE: aidirector.md chunk-data cooldowns) |
| `default_max_alive_zombies` | 24 | A | Stock MaxSpawnedZombies default (serverconfig). NOTE: stock applies CanSpawn priority multipliers (blood moon ×1.9, sleeper ×2.1, biome ×1.0; `AIDirector.CanSpawn` IL=10, aidirector.md/spawning.md, live-verified 2026-08-11); zdtd uses the flat cap - a simplification |
| `WorldClock.hours` boot | 07:00 | R | Stock dedicated boot time, live-observed 2026-08-11 (`gettime` reads "Day 1, 07:00" on a fresh paused server) |
| `WorldClock.isNight` dusk bound | `> dusk` | R | Stock `World.IsDark` IL=31: dark iff `hour < DawnHour \|\| hour > DuskHour` - the dusk hour itself is light (weather-environment.md) |
| `WorldClock.bloodmoon_frequency` 0 | 0 = off | Z | **Diverges**: stock 0 config does NOT disable - the sandbox option default (7) applies (live-observed 2026-08-11; aidirector.md SetDay/CalcNextDay). zdtd 0-disables is deliberate policy |
| `WorldClock.tick` | unconditional | Z | **Diverges**: stock dedicated pauses world time with zero players (live-observed 2026-08-11; server-lifecycle.md 5); zdtd advances always |

### 3.3 Entity HP (`src/assets/entities.zig`)

| Constant | Value | B | Stock source |
|---|--:|:-:|---|
| `EntityDef.max_hp` fallback | 40 | Z | **Fallback only** (audit A34 closed 2026-08-27): stock HP ships as `entityclasses.xml` `<passive_effect name="HealthMax" operation="base_set">` + `<replace_passive_effect>` variables (the healthSlim...healthBruteInfernal ladder, 125..3100) and IS parsed - property/passive rows share the class map, `^` vars resolve, bounds 1..1e6; 40 applies only to a class with no HP source. `perc_add` +-15% spawn rolls are deliberately pinned to base for deterministic sims |

### 3.4 Class table (`src/ecs/world.zig` 16-row `class_table`)

| Constant | Value | B | Stock source |
|---|--:|:-:|---|
| `class_table` rows | 16 | A | `entityclasses.xml` per-class defs + `entitygroups.xml` ZombiesAll (29 members); the 16-row table holds only the per-kind defaults now - spawns carry the full resolved class stats on the entity (`spawnZombieDef`, audit A35 closed 2026-08-27), so every class reaches the AI with its own HP/speeds/damage |

### 3.5 Movement envelope (`src/server/movement.zig`)

| Constant | Value | B | Stock source |
|---|--:|:-:|---|
| `max_horizontal_speed_mps` | 20.0 | R | Soft cap above sprint (~6 m/s) + vehicle margin; no stock key (audit B29); `[authority]` tunable (2026-08-27) |
| `max_vertical_speed_mps` | 25.0 | R | Vertical envelope cap: rejects Y-only teleports (fly hacking) the horizontal clamp cannot see; above stock jump/fall (~7.5/9.8 m/s); `[authority]` tunable (2026-08-27) |

### 3.6 Guard policy (`src/server/guard_policy.zig`)

| Constant | Value | B | Stock source |
|---|--:|:-:|---|
| `kick_delay_ticks` / `shed_hold_ticks` / `weak_break_rate_per_window` | 10 / 40 / 900 | Z | zdtd-owned P4 policy (audit B30; no stock counterpart) |

### 3.7 Survival / weather / power / quest (tracked divergences)

| Location | Value | R | Stock source |
|---|--:|:-:|---|
| `ecs/electric.zig` power tick | 20 Hz (every step) | R | **Diverges**: zdtd resolves the grid every tick (step.zig `power.tick`) vs stock `PowerManager` ~6.25 Hz Unity Update (tile-entities-power.md); faster, deterministic switching, not wire-visible |
| `world/weather.zig` storm/blood-moon | - | R | RE: weather-environment.md (server-authoritative storm state machine) |
| `ecs/poi_lock.zig` `unlock_grace` | 2000 | R | QuestEventManager `PrefabInstance.lockInstance` (QuestLockInstance, asm.il 1001892+) |
| `ecs/party.zig` | max 8, flat XP | R | Party max 8 per parties-factions.md §2; NOTE the stock shared-XP reduction `startingXP*(1-0.1*inRange)` is NOT yet implemented - zdtd grants flat XP with the XPMultiplier only (partial) |
| `world/stability.zig` | - | R | RE: stability.md (StabilityInitializer spread/clear, GetBlockStability BFS) |
| `server/game/constants.zig` | caps | R | Game-wide caps; behavioral subset tracked in GAP_ANALYSIS (B31-B37) |

### 3.8 Additional behavioral constants

| Constant | Value | B | Stock source |
|---|---|:-:|---|
| `assets/gamestages.zig ticks_per_day` | 24000 | A | Stock sim day length (24000 ticks @ 20 TPS); gamestages.xml stage math uses it |
| `ecs/electric.zig default_trigger_pulse_s` | 0.5 | R | Trigger pulse width (RE: PowerItemTypes; tile-entities-power.md) |
| `ecs/party.zig max_party_members` | 8 | R | Stock party cap (RE: parties-factions.md §2) |
| `world/weather.zig blood_moon_storm_push` | 5000 | R | Blood-moon storm push ticks (RE: weather-environment.md storm state machine) |
| `world/weather.zig update_interval_ticks` | 5 | R | Weather update cadence (RE: weather-environment.md) |
| `ecs/components.zig ai_task_list_set` | `1 << 15` | Z | Marker bit: XML parsed an AITask list. Unset mask 0 keeps the shared native table; a set list only runs its TaskId bits. Stock names map in `assets/entities.zig taskNameToId` (entityclasses.xml `AITask` / `AITask-N`; Leap and RangedAttackTarget stay unmapped, no native task) |
| `ecs/quest.zig max_phases` / `max_reward_flags` / `max_actions` / `max_quest_events` | 32 / 16 / 8 / 4 | Z | Quest array caps (audit B34; stock quests.xml data is loaded, these bound the sim tables; the stock file carries one `<event>` block) |
| `ecs/quest.zig builtin_objective_kinds` | 23 rows | A | The stock objective `type=` family (RallyPoint, ClearSleepers, EntityKill, AnimalKill, Fetch\*, TreasureChest, InteractWithNPC, ReturnToNPC, RandomGotoNPC, Craft\*, StayWithin\*, POIStayWithin, \*BlockActivate, Goto\*) -> executable PhaseKind, mirrored from stock BaseObjective; overridable/extendable via `[quests] objective_kinds` (assets/quests.zig parseObjectiveKinds) so a new stock type is config, not code (ADR 0021). `Goto id="trader"` special case is a hardcoded game fact |
| `ecs/quest.zig QuestPolicy` default_kill_count / kill_per_tier | 3 / 2 | Z | **zdtd-owned** approximation for kill objectives with no explicit count (stock ClearSleepers counts the POI sleeper volume at runtime, audit B25); phase target = `default + tier*kill_per_tier`. Config: `[quests]` |
| `ecs/quest.zig QuestPolicy` goto_radius / stay_radius | 4.0 / 8.0 | Z | **zdtd-owned** fallbacks when an objective omits its distance (stock ObjectiveGoto::distance parsed from `value` wins when present). Config: `[quests]` |
| `ecs/quest.zig` QuestTag bits + tagsMask / objectiveTag / prefabMatches | 10 tags | R | Stock tag strings (QuestEventManager statics IL_0024-0088 + ObjectiveFetchFromContainer hidden_cache) and the BaseObjective.SetupQuestTag objective map; Prefab.GetQuestTag = questTags.Test_AllSet. RE: 7dtd-engine-research quests-challenges.md "Quest POI selection" |
| `server/game/hooks.zig` questPoiSelectAt constants | 1000 / 4e6 / 50 / 500 / 1500 / 4096 | R | Stock selector bounds: min/max squared distance (ObjectiveRandomPOIGoto.GetPosition IL_019C-01A1), 50-attempt loop (GetRandomPOINearWorldPos IL_0202), trader bands 500/1500 (SetupTraderPrefabList IL_0085/009E); 4096 = zdtd tier-pool stack cap |
| `server/game/hooks.zig` questSpawnGsEnemy placement | 12 m + 12 m | R | QuestActionSpawnGSEnemy.SpawnQuestEntity: player position + random unit direction × (12 + RandomFloat*12); count range from the action's `count` property; entity from the gamestage list's stage-0 spawn group (QuestActionSpawnGSEnemy.il.txt) |
| `game/bot.zig BotHostConfig` shoot_damage / headshot_multiplier / spawn_spread / spawn_y / max_step_up | 12 / 2 / 2 / 70 / 1.5 | Z | Host-side bot policy (ADR 0026): damage floor (from old `ecs/command.zig` host), headshot multiplier (clanker `HeadshotMultiplier` parity), spawn spread + default Y, move step-up cap. Config: `[bots]` (ADR 0021). `bot_max_hp` 100 is the wasm guest contract, not config |
| `world/worldgen.zig` `cont_amp_base` / `cont_amp_mountain` / `ridge_amp_base` / `ridge_amp_mountain` / `detail_amp_share` | 8/24 / 16/24 / 4/24 / 22/24 / 6/24 | Z | **zdtd-owned** shaping shares: how `[rules.worldgen] height_amp` splits across the continental, ridged and detail octaves. Written as the pre-rules inline amplitudes over the default height_amp (24), so a default config is byte-identical while a raised knob now actually raises the relief (it was stored and never read before 2026-09-08) |
| `world/worldgen.zig` base_height / height_amp / min_surface / max_surface / squash / noise_weight / y_scale / bedrock_h | 68 / 24 / 12 / 200 / 28 / 0.85 / 2.0 / 3 | Z | **zdtd-owned** procedural flat-world shaping params (the DTM-backed stock maps override them). Lifted to `[rules.worldgen]` (2026-08-29, ADR 0021): the module consts are the pre-lift defaults; `WorldGen.applyParams` overlays the effective rules, byte-identical at defaults. Grid cells (`cell_w`/`cell_h`), the noise recipe and the RWG water table stay code (structural / RE-derived) |
| `game/craft.zig vehicle_fuel_max` / `vehicle_refuel_reach` | 100 / 3.0 | Z | **zdtd-owned** vehicle tank cap + refuel reach (no vehicle.xml loader yet; stock fuel capacity is per-vehicle entity data). Documented, not config until the stock data loader lands |
| `ecs/systems.zig dmg_scale` | 100 | Z | Fixed-point damage accumulator scale (atomic-friendly); structural, not policy |
| `ecs/systems.zig` TickServer light consts (`stealth_crouch_light_scale` 0.6, `stealth_light_passive_blend_a` 0.32, `stealth_light_passive_blend_b` 0.68, `stealth_light_level_max` 200, `stealth_self_light_dark` 0.1, `stealth_speed_visibility_scale` 0.15) | 0.6 / 0.32 / 0.68 / 200 / 0.1 / 0.15 | R | `PlayerStealth.TickServer` IL=432 exact chain (crouch x0.6 IL_00A6; the (0.32 + 0.68 x passive89) x 100 fold IL_0121-013F; FastClamp 0..200 IL_0140-014A; selfLight < 0.1 IL_010A; speedAverage x 0.15 IL_00CD) |
| `wire/stock_te.zig` `feature_hash_signable` | 924617576 | R | `Extensions.GetStableHashCode("TEFeatureSignable")`, the composite module that carries a block's authored sign text (`TEFeatureSignable::Write`; `TileEntityComposite::write` writes the per-module hash over `featureData.Name`, which comes from the blocks.xml `<property class="TEFeatureSignable">` row). Same formula as `feature_hash_storage` |
| `wire/stock_te.zig` `max_storage_feature_bytes` | 8192 | A | zdtd bound on one re-encoded TEFeatureStorage module (54 slots x a fixed-shape item value plus the grid/touch/lock fields) for the in-place echo splice; it is a scratch bound, not a wire limit |
| `wire/stock_te.zig` `max_sign_text_bytes` | 1024 | A | zdtd bound on one C2S sign text. Stock puts no limit on the wire (the XUI input caps the typed text); the parser fails closed past this instead of truncating mid-string, and the echo relays the client's own bytes |
| `server/c2s/inv.zig` `sign_echo_range` | 192 | R | `NetPackageTileEntity::ProcessPackage` rebroadcasts the applied composite TE with `SendPackage(..., pos = te.ToWorldCenterPos(), range = 192, exclude = false)` (NetPackageTileEntity.il.txt IL_00B4). The sender is included: that echo is what clears its `lockHandleWaitingFor` |
| `ecs/systems.zig` `stealth_heat_window_s` | 240 | R | `AIDirector::NotifyNoise` passes the literal 240 to `NotifyActivity` for a noise row with `heatMapStrength > 0` (AIDirector.il.txt IL_00D9; `AIDirectorChunkData::DecayEvents` subtracts elapsed seconds, so the window is seconds and `Director.notifyActivity` takes ticks). The row's own `heat_map_time` only reaches `AIDirectorData/Noise::heatMapTime`, a field stock writes at `Audio.Manager::AddAudioData` (IL=85) and never reads |
| `world.zig` sleeper wake roll defaults (`sleeper_wake_near_min_default` -40, `sleeper_wake_near_max_default` 5, `sleeper_wake_far_min_default` 340, `sleeper_wake_far_max_default` 480) | -40 / 5 / 340 / 480 | R | Stock zombieTemplateMale `SleeperSightToWakeMin/Max` (entityclasses.xml); the fallback roll ranges for a sleeping class with no sleeper wake props (RE entity-ai.md D8.6 step 5) |
| `ecs/aidirector.zig` wander_start_after / min_gap / max_gap, wandering_horde_size / spawn_dist, heat threshold / check / chance / cooldowns / scout_dist | 28000 / 12000 / 24000 / 6 / 92 / 25 / 5 / 0.2 / 240 / 1320 / 180 / 720 / 10 | R | AIDirector policy (RE: aidirector.md - horde spawn offset `RandomOnUnitCircle * 92f` IL_018B; horde schedule 12000-24000 world ticks; chunk-heat map asm.il 414504-415200; horde size is a fixed approximation of the gamestage-group-driven stock). Config: `[rules.director]` (ADR 0021). `heat_region_world`, `max_heat_regions`, `heat_scout_count` stay structural; the heat rules are the verified stock literals: threshold 25, check 5 s, `cSpawnChance` 0.2, `cCooldownDelay` 240 / `cCooldownLongDelay` 1320 (SetLongDelay) on the region and `cCooldownNeighborDelay` 180 / `cCooldownNeighborLongDelay` 720 (StartCooldownOnNeighbors) on the neighbours (2026-09-12; the previous `heat_feral_chance`/`heat_feral_cd_mult` pair modelled the long delay as a 2x feral roll and is gone) |
| `game.zig isStockClientQuestName` prefix gate | quest_/tier/intro_/test_/challengegroup_reward_/treasure_ | A | Stock client quest-name families (client catalog proxy; a stock_xml catalog passes by construction, audit B28) - code gate, not tunable |
| `max_spawn_chunk_view_dim` | 8 | A | `server/c2s/join.zig:29`: upper bound on C2S RequestToSpawnPlayer.chunkViewDim (viewDist 8 mesh core; B41) - authority cap, not tunable |
| `max_drop_count` | 65535 | Z | `server/game/chunk_fill.zig:32`: **cap** - harvest/destroy XML counts parse as unbounded u32 but the stack store is u16; a dropped roll beyond the store clamps here (audit B37); bound, not policy |
| `falling_mass_hmm_cap` / `falling_mass_scale` | 10 / 8 | R | `assets/maxdamage.zig:40-41`: EntityFallingBlock crush mass `FastMin(Hardness * Mass, 10) * 8` (RE IL=232-250, entity-ai.md) - RE formula, not tunable |
| `join_ack_yield_ns` | 500000 | Z | `server/game/chunk_stream.zig:30`: join-burst ACK yield (loopback RTT ~100 µs) so the reliable window drains between spawn-area chunk sends; a concurrent second client's critical packages no longer starve behind the flood (GAP "Join-burst tick budget under concurrent load") - zdtd-owned timing mitigation, not stock data |
| `assets/quests.zig objectiveScore` | 10..100 | Z | Phase "meat" pick heuristic for shared phases (ClearSleepers 100 .. unknown 10) - not a stock table; only affects which objective drives a phase when several share it |
| `game/tick.zig tickAirDrop` | every N game-hours | Z | **Diverges**: stock schedules by day-count + fixed time-of-day (`SetupAirDropTimeRanges` IL=124 maps options 52/54 -> day-counts + TOD, `calcNextAirdrop` IL=39; default 3/3 days at 12:00; aidirector.md airdrop schedule, live-verified 2026-08-11). Also stock AirDropFrequency=0 does NOT disable (option default overrides the 0 pref) |
| `game/sleeper.zig` sleeper spawn | no global cap | Z | **Diverges**: stock `SleeperVolume.UpdateSpawn` gates every restore on `AIDirector.CanSpawn(2.1f)` = `EnemyCount < MaxSpawnedZombies * 2.1` (spawning.md, live-verified 2026-08-11); zdtd's sleeper spawn bypasses the cap (the volume count is group/255-capped only). Wake/stage radius is `[sim] sleeper_party_radius` (default 100 m, `CalcGameStageAround` asm.il ~1093363) vs stock volume-box + party stage |
| `ecs/systems.zig traderRestock` | day-based | Z | **Simplifies**: stock `TraderManager` restocks on a tick-based `ResetIntervalInTicks` with a boundary snap (loot-economy.md 3); zdtd restocks on a day counter (-1 never, 0 daily, N>0 every N days) |
| `world/worldgen.zig water_surface_cell` | 62 | R | RE `Block.cWaterLevel` = **62.88** (Block cctor `ldc.r4 62.88`, stock_facts `world_water_level`); the RWG water table fills cells 0..62 and the surface cell is world-constant so chunks cannot seam |
| `world/store.zig` leveler pending_cap / pour budgets | 256 / 4 / 128 | Z | **zdtd-owned** dig-leveling queue cap + per-tick drain/spread budgets (stock is the jobified mass-flow sim, light-mesh-water.md §4 - not ported). Config: `[rules.water]` (ADR 0021) |
| `ecs/aidirector.zig` `world_time_units_per_hour` | 1000 | R | Stock `AIDirectorGameStagePartySpawner::SetupGroup` IL_0044-0062: `nextStageTime = world.worldTime + duration * 1000`. World time is 24000 units per day / 1000 per game hour (`DayTimeToWorldTime`, the scale `WorldClock.worldTimeBits` returns); the old `duration * 20` armed every blood-moon row deadline 50x early (2026-09-13) |
| `world/biomes.zig` `offline_default_biome_id` | 3 | R | Offline biomemap pin for pine_forest (stock V3.1 AssignIds biomemap id 03). Used only when the loaded `<biomemap>` table did not resolve the name (`ColorTable.idForName`/`biomeIdForName`); the snow 1 / desert 5 band pins live in `offlineBandId` with the same offline-only contract (2026-09-13) |
| `ecs/aidirector.zig bloodmoon_budget_scale` | 1.9 | R | `AIDirector::CanSpawn(1.9f)` (asm.il:413528) - the 1.9x blood-moon ceiling over MaxSpawnedZombies |
| `ecs/aidirector.zig` `initial_population_batch` | 4 | Z | Starter-population fill batch per tick (GAP "population is still thin"): caps the one-time fill toward `[rules.director] initial_population_frac` at ~4 spawns/tick so a cold boot cannot spawn the whole population in one tick |
| `ecs/aidirector.zig` WorldClock bm schedule (bm_cycle / bm_day_last / next_bm / bm_freq / bm_range) | persisted | R | Stock `CalcNextDay` (asm.il 412880): `nextBM = bmDayLast + frequency + RandomRange(0, range+1)`, persisted with the clock (ZCL2) so the red moon stays on the horde night across restarts and day jumps |
| `wire/packages.zig cF_crouching` | 0x0200 | R | Stock EntityFlags `IsCrouching` bit 512 (protocol-packages.md 5.5.6); the sim reads it for the stealth sense gates |
| `ecs/components.zig flag_*` | 0x0001..0x0200 | R | Canonical stock EntityAliveFlags bit table (protocol-frames.md 9, protocol-packages.md 5.5.6): the sim flags word mirrors the stock wire word and `wire/packages.zig` cF_* aliases these, one source of truth for the bit numbers (2026-08-28) |
| `wire/packages.zig dmg_*` | 0x001..0x400 | R | V3.2.0 `NetPackageDamageEntity` packed flag bits (changelog-3.2.0 §3.1, protocol.md §6.5): the ten 3.1.0 booleans folded into one u32, bit 10 TrapKillXP new (2026-08-28) |
| `assets/buffs.zig tracked_delta_max` | 1e6 | Z | **zdtd-owned** sanity ceiling for the passive-effects VM fold (stock stat values and deltas are < 1e4): a pathological modded curve value (1e38 / inf / nan) saturates instead of reaching the tick's `@intFromFloat` casts on the max stats (2026-08-28) |
| `ecs/components.zig falling_group_cap` | 32 | Z | **zdtd-owned** falling-block group cap (stock `GroupBounds.IsWithinSize` clamps groups but the bound is not IL-pinned); larger collapses keep the first 32 cells - the rest still air out |
| `max_claimed_explosion_radius` | 6.0 | R | `server/c2s/blocks.zig` cap on C2S-claimed explosion radii (block + entity): largest stock ExplosionData.EntityRadius is 6 (entities.xml `explosion` on cop/feral: radius_blocks 5, radius_entities 6); a forged blob must not carve the whole map or damage every loaded entity (2026-08-27) |
| `fatal_kill_amount` | 9999 | Z | `server/c2s/misc.zig` **zdtd-owned** honored-`fatal` kill amount vs NPC kinds: stock fatal damage is client-computed; the server honors the flag only against zombies/animals with an amount far above any sim NPC class HP (max class hp 1600; the 9999-HP trader class is excluded by the zombie/animal gate) (2026-08-27) |
| `wire_tool_max_op` | 1 | R | `server/c2s/misc.zig` highest `WireActions` value `NetPackageWireToolActions::ProcessPackage` acts on: the switch takes 0 (SetParent) and 1 (RemoveParent) and returns for anything else, so a higher op never reaches its rebroadcast (`il/netpackages-v3.2.0/NetPackageWireToolActions_il.txt:56`, IL=254 IL_001B-IL_0025) (2026-09-09) |
| `entity_physics_body_len` | 58 | R | `server/c2s/misc.zig` exact stock `NetPackageEntityPhysics` body size: Flags u16, EntityId i32, 13xf32 (pos 3, quat 4, velocity 3, angular 3) (`il/full-v3.2.0/_global/NetPackageEntityPhysics.il.txt` read IL=74, `GetLength` IL=2 returns 58). The malformed gate was 62, so every valid report was counted `c2s_malformed` (2026-09-10) |
| `assets/traders.zig default_buy_markup` / `default_sell_markdown` | 1.0 / 0.02 | A | Price multipliers used only when neither a `<trader_info>` override nor the `<traders>` root row supplies one, which happens only with no game-dir (offline builtin catalog). Stock `traders.xml` ships both attributes, so a real install always overrides them. Named and moved beside the loader that owns the fields on 2026-09-09; they were previously inline literals in `server/game/trader.zig` and `server/game/hooks.zig`, where they doubled as "unset" sentinels and discarded a per-trader override that happened to equal the fallback |
| `wire/stock_quest.zig default_quest_size_x` / `_y` / `_z` | 50 / 20 / 50 | Z | **zdtd-owned** quest-area bbox sent when no POI selector answered, so no real prefab bbox exists to report. A selector hit overwrites all three with the POI's own size (`server/game/quest.zig`). Wire-only: sim containment reads `ecs/components.PoiRect`, which is filled from a real POI rect or left unset, so this fallback cannot widen a StayWithin zone. Named once and shared on 2026-09-09; the triple was previously repeated in three places (2026-09-09) |
| `server/game/world.zig` offline block-HP bands (`offline_terrain_hp` / `offline_container_hp` / `offline_vegetation_hp` / `offline_default_hp`, bounds `offline_terrain_max_id` / `offline_container_min_id` / `offline_container_max_id` / `offline_vegetation_min_id`) | 100 / 500 / 50 / 500, bounds 256 / 18000 / 20000 / 24000 | Z | **zdtd-owned** block HP for the no-`--game-dir` mode only (README documents it), where no `blocks.xml` MaxDamage exists to read. Reached from the authoritative break decision (`c2s/blocks.zig`, explosion AoE, tick paths), so it is live sim state rather than a wire default. The bands lean on AssignIds grouping by content (terrain and low pins < 256, `cnt_*` around 18000, `tree_*`/`plant_*` from 24000). Approximations, not stock truth: with a game-dir the XML value wins before the bands are reached, and a loaded-but-incomplete catalog fails closed to `loaded_catalog_generic_hp` 100 instead of guessing from the id. Named 2026-09-09; previously bare literals |
| `quest_giver_fallback_y` | 70 | Z | `server/c2s/quest.zig` **zdtd-owned** fallback quest-giver marker Y when the trader NPC is not yet in the sim (the marker snaps to the real transform once the entity loads); plausible ground height, not stock data - the giver marker is client-side (2026-08-27) |
| `assets/vehicles.zig max_seat_scan` | 99 | R | `Vehicle::SetSeats` walks seat0..seat98 (asm.il:1344168 IL_0085): the seat-scan bound is RE-pinned, not a tunable |
| `assets/quests.zig max_quest_vars` | 8 | Z | **zdtd-owned** parse buffer cap for quest `<variable name= value=>` overrides (fixed array; the last occurrence wins across template/body merge; stock QuestVariables is an unbounded dictionary) |
| `server/game/map.zig map_batch` | 8 | Z | **zdtd-owned** minimap pieces per send (8 = 4128 bytes raw); the stock producer sends the whole window at once, zdtd batches to bound the per-frame cost (2026-08-29 sweep) |
| `server/game/map.zig map_walk_above` | 64 | Z | **zdtd-owned** perf floor for the top-block minimap walk (stock walks the whole 256 column; a cell above a 64+-block structure stays invisible) (2026-08-29 sweep) |
| `litenet/peer.zig` resend_ns / ack_yield_ns | 80 ms / 2 ms | Z | **zdtd-owned** LiteNet-compatible transport timings: resend gate in the same ballpark as LiteNet, and the WindowFull pump sleep (far below the resend gate, above loopback RTT) so the reliable window drains between join-burst sends; same class as `join_ack_yield_ns` (2026-08-29 sweep) |
| `server/game/types.zig` window_retry_budget_ns / window_fast_attempts / window_retry_sleep_ns | 16 ms / 16 / 1 ms | Z | **zdtd-owned** per-package reliable-send retry pump: 16 ms budget (critical 1 s), 16 fast attempts before the 1 ms sleep cadence (every 4th); the pump bounds a wedged window per package instead of spinning (2026-08-29 transport review) |
| `quality_unset` | -1 | R | `assets/traders.zig`: `TradersFromXml::parseItemList` is called with minQualityBase = maxQualityBase = -1 (`TradersFromXml.il:558-563` and `:790-792`, the `ldc.i4.m1` pair), so a trader `<item>` ref with no `quality` attribute carries -1/-1 and `TraderInfo::SpawnItem` substitutes the `[rules.trader]` default range for it |
| `no_quality_wire` | 1 | R | `assets/traders.zig`: wire quality for an item `ItemClass.HasQuality` (IL=9) says has no quality: `SpawnItem` skips the whole quality block for those (`TraderInfo.il:014B-0151`), leaving the ItemValue at its default tier |
| `quality_parse_max` | 255 | Z | `assets/traders.zig`: **zdtd-owned** trust-boundary clamp on a `quality="lo,hi"` bound. Stock quality is an ItemValue byte and stock XML only writes 1..6; a modlet writing a larger bound is clamped at parse so the roll stays inside the wire type when `[rules.trader] max_tier` disables the ceiling |
| `server/game/tick.zig base_consumable_stat_max` | 100 | R | `EntityStats::Init` IL=40 passes `ldc.r4 100` as the default value into `EffectManager.GetValue` for the stat maxes (the `ldc.i4.s 104` FoodMax passive first), so Food/Water/Stamina start at 100 and the passive VM folds its `*Max` deltas onto that base. The tick's max recompute (`@max(1, 100 + delta)`) and the new `requirements.Ctx.*_base_max` (`Stat::Max`) now share one name, `base_consumable_stat_max`, so `StatCompareMax` / `StatComparePercModMaxToMax` cannot drift from the arithmetic they gate. Named 2026-09-12; previously two bare 100 literals in `tickSurvival` |
| `server/game/weather.zig no_biomes_weather_count` | 5 | Z | **zdtd-owned** `NetPackageWeather` entry count used only when no `biomes.xml` is loaded at all (offline / no `--game-dir`): the stock 5-biome layout, so an unmodded client still reads a well-formed body. With a game dir the count is the loaded table's `weather_n` (biomes whose `weatherGroups.Count > 0`, what `InitBiomeWeather` asm.il ~2050437 sizes the read from); the hardcoded 5 this replaces broke modded counts (hardcode audit 2026-09-12 A1). Named 2026-09-12; the fallback constant is `no_biomes_weather_count` |

### 3.9 Divergence register (provenance for the differences)

Places zdtd does **not** reproduce stock values today. Each row states the
stock source and the tracking item. Finding ids refer to the hardcode audit
(the live `docs/reviews/HARDCODE_AUDIT.md` copy was removed from the repo on
2026-08-23; the archived snapshot `archive/HARDCODE_AUDIT_2026-08-08.md`
survives, see §3.10 for its caveats) unless noted.

| Location | zdtd value | Stock value (source) | Sev | Tracking |
|---|---|---|---:|---|
| `ecs/aidirector.zig` heat spawner | `cSpawnChance` 20% gates the spawn, region 240 s / 1320 s and neighbours 180 s / 720 s | `AIDirectorChunkData` verified literals (aidirector.md: `CheckToSpawn` IL=46 picks the max event, stamps 240, rolls 20%, then `SetLongDelay` 1320 + neighbours 720, else neighbours 180) | P2 | **Fixed 2026-09-12**: the spawner spawned on every crossing (5x stock) and approximated the long delay as a feral 2x cooldown. Rules now carry `heat_spawn_chance`, `heat_long_cooldown_seconds`, `heat_neighbor_long_cooldown_seconds`; the deterministic roll is `Director.heatSpawnRolls` and the chance-split test asserts the 240/180 vs 1320/720 table |
| `server/game/trader.zig` sell | econ × EconomicSellScale × SellMarkdown × qmod / bundle | stock `XUiM_Trader.GetSellPrice` = econ × EconomicSellScale × SellMarkdown (loot-economy.md §5) | P1 | **Fixed 2026-08-27** (live A29 closed): `items.xml` EconomicSellScale + EconomicBundleSize parsed (`trader.zig:180-206`), quality mod + bundle divide applied |
| `ecs/world.zig` class_table row `zombieFeral` | builtin removed; the row is the real `zombieBoeFeral` (stock Unity hash, max_hp 550) | stock `zombieBoeFeral` in entityclasses.xml | - | **Fixed (A40)**: the invented `zombieFeral` builtin row had 0 hits in entityclasses.xml and no stock group named it; it was repointed to the real feral variant (offline fallback only, live spawns resolve per class via the director hook) |
| `ecs/inventory.zig` armorMitigation | quality-curve PhysicalDamageResist/ElementalDamageResist sum | `items.xml` PhysicalDamageResist/ElementalDamageResist tier ranges + quality jitter | P1 | **Fixed 2026-08-27** (live A35 closed): `items.xml` passive 41/42 quality curves parsed (`items.zig:855-861`, e.g. armorPrimitiveHelmet "8,12.3"), summed at quality through the passive VM; TargetArmor penetration applies |
| `ecs/rules.zig Progression.*` base depletion | policy tunables | stock survival damage from buffs.xml `buffStatusHungry/Thirsty*` + `FoodChangeOT`/`WaterChangeOT`/`HealthChangeOT` | P3 | live A31 fixed (T16); base rates stay policy |
| `world/tts.zig:418` filler skip | comptime pins | AssignIds `terrainFiller`/`terrainFillerAdaptive` (dump 2/3) | P3 | live A05/A06 class (Fixed); pin uses tracked |
| `world/store.zig:310-313,370` no-blocks fallback | module pins | AssignIds terrain names | P3 | live A05 (Fixed); fallback pins tracked |
| `ecs/inventory.zig` ElementalDamageResist (passive 43) | tag-matched EDR fold at the damage choke, reached only for External (0) damage: the C2S path picks PDR or EDR by wire damage type when `source` is External, the External explosion blast (Heat 6) mitigates for every victim including the blaster, and the Internal-modelled drowning (16) / radiated-biome (8) legs take GDR only | `Equipment::CalcDamage` IL=83 non-physical branch (`FastMax(0, entityDamage * (1 - GetValue(43, ..., tags=damageTypeTag)/100))`), gated by `DamageSource::AffectedByArmor()` IL=5 (`source == External`); `Equipment.physicalDamageTypes = piercing,bashing,slashing,crushing,none,corrosive` (`.cctor` IL=11); `EnumDamageTypes` ordinals (`EnumDamageTypes.il.txt`), wire bytes `NetPackageDamageEntity.damageType`/`source` (protocol.md 6.5) | - | **Fixed 2026-09-12**: passive 43 had no consumer, so elemental hits took the *physical* armor rating and armor's `tags="heat,electrical"` rows never applied. `protocol.damageTypeIsPhysical`/`damageTypeName` + `Game.elementalDamageResist` (event-tagged fold of equipped items/buffs/perks) now wire it; a row whose requirements the event ctx cannot answer is counted unsupported rather than answered from a partial ctx. Pinned by `scenario ElementalDamageResist` on stock items.xml (bare heat 40, Q6 helmet heat 35, cold 39.9, bashing 35.1, and source=1 Internal heat/bashing hits taking the full claimed strength), plus the `protocol` `damageSourceAffectedByArmor` test |
| `assets/loot.zig` loot-entry `<requirement>` children | gated entries carry `LootEntry.gate`: `Biome` resolves against the container's biome (`LootGateCtx.biome_name`); `Progression` / `CVar` evaluate through the shared `requirements.Ctx` built from the **opener's** ledger (levels, cvars) by the container fill; `RandomRoll` evaluates `Lerp(min_max, roll)` against `value` / `value="@$cvar"` with the deterministic per-entry stream value; `SandboxOption` compares the option's value under the server's decoded sandbox code (`Game.sandbox_code` -> `sandbox.decode`), so stock's `HarvestingOutput EQ 0` means what it says instead of a boolean truthiness test. Ungated entries roll as before, and with no opener ctx every player-state gate refuses (the pre-evaluator behaviour) | `loot.xml` `LootEntryRequirement*` leaves, counted from the live file excluding the commented header examples: 63 `RandomRoll` (all `min_max="0,100" operation="LTE" value="@$perkBookwormChance"`), 14 `Progression` (10x `perkTreasureHunter GTE 4`, 4x `Equals 5`), 5 `Biome`, 3 `SandboxOption`; `class="CVar"` / `class="QuestTags"` appear only inside `<!-- -->` in the shipped file (RE loot-economy.md:569 for `LootEntryRequirementRandomRoll`: `LeftSide = Lerp(minMax.x, minMax.y, RandomFloat)`, `RightSide = GetFloatValue(player, value, 0)`) | P2 | **Fixed 2026-09-12**: the loader ignored the child element, so a gated entry rolled at its base prob - `groupWorkingStiffsBooks` (no `prob`, i.e. 1.0, gated on `RandomRoll @$perkBookwormChance`) filled every Working Stiffs crate. Biome gates resolve from the container's own biome; Progression/CVar/RandomRoll resolve from the opener (`groupBuriedTreasure`'s `perkTreasureHunter GTE 4` rows roll only for a level-4 opener, pinned by a fill-path test). The `$perkBookwormChance` writer landed the same day: progression.xml's `perkIntellectMastery` `onSelfProgressionUpdate` rows now fire on level changes, so the 63 RandomRoll rows roll at 25% for an Intellect Mastery 2+ opener and refuse below it. **`abundance_type` applied since 2026-09-12**: the 67 stock groups that carry it (all on `<lootgroup>`, none on a container, which is where the field used to sit) scale their counts by the category's `*LootCount` sandbox option read from the decoded code (`FoodLootCount` ... `BookLootCount`; a category at 0 spawns none). `loot_stage_count_mod` applied the same day (84 stock ammo rows, all 0.01): the sandbox-scaled count grows by `RoundToInt(count * mod * lootStage)` (LootContainer IL_017F), so a stage-50 6..8 ammo roll spawns about 9..12. `buffs` applied the same day: a spawned entry's comma list is reported through a `LootBuffSink` and added to the opener by the fill path, which is stock's collect-then-`ExecuteBuffActions` shape (62 stock rows carry `buffPerkBookwormSuccess`; the one typo'd `buffbuffPerkBookwormSuccess` fails closed like any unknown name). `random_durability` handled the same day (123 stock rows, all explicitly `false`, so engine/modlet support): the roll marks the stack and the fill path starts the item at `(int)(MaxUseTimes * RandomRange(0.2, 0.8))` (LootContainer IL_032D), deterministic per container. **entry `tags` since 2026-09-12**: the 431 tagged entries use their comma list as the `getProbability` query set for the player's `LootProb` passives (passive 79); `buffs.lootProbFold` applies the matching rows in order with the GetValue ops, and the fill path folds the opener's perk/attribute rows at their level plus the active buffs' rows at their duration. A Dead Eye 5 player (`perc_add 10 tags="rifleSkill,ammo762mm"`) therefore sees rifle-tagged loot at +10%. Equipped and held item rows fold too (the same day), at their own quality tier: a Q6 `armorFarmerHelmet` (`LootProb perc_add 2,4,6,8,10,20 tier=1..6 tags="seedSkill"`) adds its tier value, so all stock LootProb sources (128 progression rows, 2 item rows) are live. The fill paths also stop guessing quality from stack size: they gate on `ItemClass.HasQuality` (`items.has_quality`, parsed from the owner-tiered effect groups), because a tool like `meleeToolRepairT0StoneAxe` has quality with Stacknumber 500 and the old `stack == 1` test silently dropped its rolled quality in containers and loot bags (found while wiring the bag path, 2026-09-12). Loot bags (`fillLootBagFromTable`) now deposit the rolled quality and random-durability wear too, since a death bag is a stock LootContainer roll. **entry `mods` since 2026-09-12**: the 5 stock gun entries carrying `mods=` (`barrelAttachments,sideAttachments,smallTopAttachments,trigger` at `mod_chance=".50"`, one `scope` at `1`) install a fitting modifier per tag (`ItemValue.createDefaultModItems` IL=759: exact name first, else any modifier whose `installable_tags`/`modifier_tags` list carries the tag, `isSuitable`-gated, `RandomFloat() <= chance`, chance halved after each install, capped at the item's ModSlots curve), writing the mod's ECS id into the slot so the wire's nested ItemValue re-renders the attachment. Residual: stock's item-`ItemTags` query fallback and `GetSandboxProb` (treasure-map chance, whose static default is 1.0) |
| `litenet/packet.zig` max_packet_size | 1432 | game `NetConstants.MaxPacketSize` = 1432 (PossibleMtu last entry, RVA-decoded; network.md §4) | P2 | **Fixed 2026-09-12**: was 1327, matching no stock MTU entry, which clamped `peer_mtu` below the client's final probe; the part/pending/hold buffers derive from the constant so they grew with it. Pinned by `litenet/peer.zig`'s MTU test (1432 probe negotiates 1432, 1500-byte probe clamped) |
| `world/store.zig` sea_level | 64 (u8), the flat empty-world fill height and the baked-DTM out-of-bounds fallback | no stock analog: the flat world is zdtd-generated. Stock's `WorldConstants.WaterLevel` = `Block.cWaterLevel` = **62.88** is implemented where it applies, the RWG water table (`world/worldgen.zig water_surface_cell = 62`; `stock_facts.json behaviour.world_water_level`; pinned by the water-table test) | - | **Closed 2026-09-12 (framing)**: the row compared two different quantities. The flat-world fill height is zdtd-owned and operator-tunable via `[rules.geometry] sea_level` (f32, ADR 0036); the stock water surface lives in the water table, not in this constant |
| `server/game/init_world.zig` ambient seeds | the near-spawn demo set (hostiles + Trader Jen + minibike + seed chest + demo turret/generator) is seeded at world init by default: `[sim] starter_zombies = false` drops the hostiles, `[sim] demo_seed = false` drops the rest, and both false is a stock-lazy fresh world | stock spawns lazily: `listents` = players only (1-3) at join, animals/zombies later via AIDirector near players, traders on POI load | P3 | **Configurable 2026-09-12**: the demo set is a documented, switchable divergence (docs/DIVERGENCES.md 6.2); `demo_seed` was added after the hardcode audit 2026-09-12 (B2) found that only the hostiles were gated. First recorded from the SUT join-probe 2026-08-12 (7dtd-loadgen compare-sut) |
| `ecs/aidirector.zig` WorldClock rate | stock integer `24000 / (DayNightLength * 60)` world ticks per real second (6 at the default 60-minute day -> 0.36 game-min/s), stored on the clock and read by the tick, the GameStats blob and the weather countdown | stock measured 0.33-0.37 game-min/s, Day 1 07:00-07:07 across 3 runs (DayNightLength 60 live stat; `getgamestat TimeOfDayIncPerSec` = 6); RE formula server-lifecycle.md:168 | P2 | **Fixed 2026-09-12**: was a flat `DayNightLength*60/24` seconds per in-game hour (0.39-0.44 game-min/s), i.e. the untruncated 6.667 ticks/s. `WorldClock` now stores `day_night_length` + `time_of_day_inc_per_sec` from `timeOfDayIncPerSec()`, `tick` advances `hoursFor(dt)`, and `gameStatsValues` reports both fields verbatim instead of deriving them back out of a float |
| `server/game/chunk_fill.zig` container loot timing | the chunk/prefab scan only **sizes** the grid (`setContainerSizeFromLoot`); the roll runs on the open path (`ensureContainerLoot` from `NetPackageInventoryDataRequest`) with `lootStageForPlayer(opener)` and the container's biome, sets `touched`/`touched_day` even on an empty roll, and the LootRespawnDays re-roll uses the same opener stage; the table resolves by the TE's `loot_list` then the block's LootList | stock rolls a placed container **on first open** (`LootManager.LootContainerOpened`: return if `bTouched`; set `bTouched`, stamp `worldTimeTouched = world.GetWorldTime()`, resolve the `LootContainer` by `lootListName`, roll **only if the container is empty**, fire MinEvent 101/100 on the opening player) with the **opener's** loot stage (`LootContainer.Spawn` -> `RandomSpawnCount(min,max,abundance)` clamped to slots -> `SpawnLootItemsFromList`); loot-economy.md "Generation gate"/"The roll" | P2 | **Fixed 2026-09-12**: the roll moved to first open (stock `LootManager.LootContainerOpened`), so the opener's loot stage is the input, `bTouched`/`worldTimeTouched` are stamped at open even when the roll is empty (stock stamps before the roll), player-placed storage still never auto-rolls, and a block without a LootList stays empty. Pinned by `scenario world container loot rolls on first open, not at load`. Residual: `worldTimeTouched` is stored per day (ZCT2 `touched_day`) rather than exact world time, which only coarsens the respawn interval |
| C2S payload decode (litenet/net.zig) | every C2S payload decodes on the current build: **0** `net_payload_errors` / `decode_rejects` across the pregen matrix | stock joins all pregen worlds cleanly (0 overflows) | - | **Resolved 2026-09-12 (matrix re-run)**: the 2026-08-12 report (`payload failed error=Overflow n=1` per join, join FAILS on Pregen06k01) no longer reproduces. Pregen06k01: 2 wander bots x 11 lives, 1200 ticks, `join_fail=0`, `net_payload_errors=0`, `decode_rejects=0`, every enter PASS. Pregen08k02: 3 bots, 25 PASS joins, same zeros. The Pregen06k01 join failure the row recorded was the S2C `WorldSpawnPoints` 512-byte builder overflow, fixed 2026-08-29 (buffer 1024 + regression test); the decode path the row cites is still instrumented (`server/game/net.zig` `logPayloadErr`) and stays at 0. The residual in both runs is a transient `stream_errors` WindowFull on the chunk stream, which leaves the unsent chunk pending and retries it next period rather than dropping it  Also re-confirmed on Navezgane (round-37 smoke, 2026-09-12, ReleaseSafe build): 12 `join_ok` with `join_fail=0`, `net_payload_errors=0`, `decode_rejects=0`, `encode_errors=0`, `stream_errors=0`, `net_send_errors=0`; the loadgen's telnet pressure was disabled (`--no-spawn-zombies --no-kill-fallback`). The same run measured `reliable_window_drops=383` and `tick_overruns=13` (the join burst, the known budget PARTIAL), 17119 requirement gates with 30 unsupported, and 17.8M TE scan cells over Navezgane's 1559 prefabs. |
| gameplay: `zombie_death_loot`, `item_drop_entity`, `loot_bag_pickup` (playtest demo) | zdtd FAIL | stock PASS | P2 | superseded 2026-08-22 recount: zombie_death_loot PASS (GAP_ANALYSIS entity-removal row); death bags carry the real inventory; the ItemDrop arm spawns the item entity and the Collect arm transfers + destroys the bag (2026-08-27 c2s/inv audit) |
| persistence: `persist_setup_blockmeta`, `persist_setup_te` (playtest persist) | zdtd FAIL | stock PASS | P2 | superseded 2026-08-22 recount: placed-block rotation/meta rides the chunk raw plane + ZCH3 and TE state persists (GAP_ANALYSIS world-systems row); blockmeta/TE survive restart (2026-08-27) |
| soak: seeded ambient zombies near spawn | zdtd player dies ~12s into the 15-min soak | stock player survives the full soak (900s) | P2 | ambient-seed divergence manifest (see ambient-seeds row); open from playtest-compare soak 2026-08-12 |

**Resolved since the stale archive snapshot** (do not re-flag):
- zombie HP: `assets/entities.zig` now parses `entityclasses.xml` `<replace_passive_effect>` (healthSlim 125 ... healthBruteInfernal 3100) and resolves `^variable` HP; `max_hp = 40` is only the floor default when the XML has no HP.
- movement envelope: `server/movement.zig` cap is now the `[authority] max_horizontal_speed_mps` config key (zdtd.toml), not a bare constant.
- class_table speeds/damage/sight from XML: live A10/A11/A30 marked **Fixed**.
- terrain ids: live A05/A06/A08 marked **Fixed** (`World.terrain_ids` + bundled-dump coverage guard).

### 3.10 Live hardcode audit linkage (audit removed from repo 2026-08-23; ids as of the last live pass, 2026-08-10)

Every finding id the live audit named, its status there, and where this ledger
covers it. The live `docs/reviews/HARDCODE_AUDIT.md` was deleted on
2026-08-23 ("rm old reviews"); only the stale archived snapshot
`archive/HARDCODE_AUDIT_2026-08-08.md` survives, and that snapshot is NOT
authoritative (different numbering; archived as stale 2026-08-09). The table
below is therefore the surviving record of the final live statuses.

| Id | Topic | Live status | Ledger coverage |
|---|---|---|---|
| A01-A12 | trade coin, place path, inv stacks, armor id, pins, biome defaults, class_table, AI floors, vehicle, maxdamage | A01-A06/A08-A12 Fixed; A07 P1 | file rows (§2) + §3.9 |
| A13/A14/A16/A18/A21/A24 | recipe unlock, quest builtins, dual ids, chunk pins, director/gamestages, NONE loaders | P2 open | file rows (§2); GAP_ANALYSIS |
| A15/A17/A19/A20/A22/A23 | builtin leakage, name builtins, trader wallet, reward coin, deco skew, gameDir | Fixed | file rows (§2) |
| A25-A28 | sleeper 5, weather, power OKs | OK | file rows (§2: sleepers/weather/powerblocks) |
| A29 | trader price/sell ratios | **Fixed 2026-08-27** | §3.9 divergence |
| A30 | trader reset_interval unused | P3 | §3.9 divergence (restock cadence) |
| A31 | loot respawn fallback | Fixed | §3.9 (resolved) |
| A32 | Rules floors vs stock data | documented policy | §3.1 |
| A33 | subbiome noise `_perm` literal | Residual | file row `world/subbiome_noise.zig` |
| A34 | trap-kill XP (ElectricalTrapXP) | Fixed with floor | §3.1 `trap_kill_xp_frac` |
| A35 | armor mitigation | **Fixed 2026-08-27** | §3.9 divergence |
| A36 | ActiveRadiusEffects | Fixed (workstation-backed); residual T38 | file row `world/weather.zig` + WORK_PLAN T38 |
| B01-B12 | zdtd policy caps | see live audit | file rows (§2) + GAME_OPTIONS.md |
| B13 | tick throttles % N | Done | file rows (§2) |
| B14-B21 | AI bands, caps, buffers | mostly done | `[rules.ai]` 30 tunables (§3.1) |
| B22 | CLI + file for caps | Done | `zdtd_config` (file row §2) |
| B23-B28 | quest/offer gates, LootRespawnDays | B25 P3, B26-B28 Fixed | file rows (§2) |

### 3.11 Perks and attributes (progression)

| Item | Provenance |
|---|---|
| Level curve, attribute/perk catalog (names, max levels, costs) | `progression.xml` via `src/assets/progression.zig` (A: stock file loaded at runtime) |
| XP/level/gamestage math | RE: `../7dtd-engine-research/docs/gameplay/progression.md` (AddLevelExp → recursive level-up → skill points → RefreshPerks); `src/server/game/player.zig` |
| Perk requirement graphs / effect application | **Not built yet**: planned as `docs/adr/0023-perk-attribute-system.md`; zdtd has no perk system, so no provenance claim is made until the ADR lands (rules.zig `Progression.*` are placeholders, WORK_PLAN T16) |

| B38 | `world/sleepers.zig:10` (8192), `litenet/server.zig:8` (64), `util/parallel.zig:7-9` (8/24) | Fixed-size architecture caps | zdtd engineering (Z), documented as fixed-size architecture |
| B39 | `game.zig:352` | `sleeper_party_radius` (default 100.0), now a single `[sim]`-bound field (deduped; was duplicated at game.zig:3969 + game/sleeper.zig:13) | R: CalcGameStageAround radius (asm.il ~1093363) |
| B40 | `ecs/inventory.zig:67-83` | `offlineStockName` mirrors `assets/items.zig` `builtinStockName` | zdtd mirror; divergence caught by existing id tests |

## 4. Coverage and maintenance

- **Gate:** `python3 tools/provenance_scan.py` runs in `make check` (CI-enforced).
  File coverage must stay **201/201 (100%)**; a new src file without a ledger
  row, or a row without a bucket/source, fails the gate (AGENTS.md rule 15).
- **Constants:** the ledger covers the behavioral values; the authoritative
  field-by-field provenance for the rules surface lives inline in
  `src/ecs/rules.zig`.
- **After a game update:** re-run `../../7dtd-engine-research/tools/parity/drift-check.sh`,
  then re-verify the R rows and the divergence register against the new pin
  (see RE_GAP_CLOSURE §4).
- **Divergences:** tracked in GAP_ANALYSIS / WORK_PLAN / the audit's per-finding
  table (`archive/HARDCODE_AUDIT_2026-08-08.md`); re-verify on change.

- `python3 tools/provenance_scan.py` gates **file coverage 201/201** and ledger
  well-formedness (every row: bucket + non-empty source; every constant anchor
  file exists). Wire it into `make check` after the first green run.
- After a game update: re-run `../../7dtd-engine-research/tools/parity/drift-check.sh`,
  then re-verify the R rows against the new pin (see RE_GAP_CLOSURE §4).
- Divergences are tracked in GAP_ANALYSIS / WORK_PLAN; the audit's per-finding
  table lives in `archive/HARDCODE_AUDIT_2026-08-08.md` (re-verify on change).
### 3.7 Recent additions (2026-08-25 lift + gap sweeps)

| Constant | Value | B | Stock source |
|---|--:|:-:|---|
| `workstations.default_fuel_burn_seconds` | 10.0 | A | **Offline fallback** for `items.xml` FuelValue (production wires the XML via `craft.zig`; RULES_CONFIG "STOCK fallbacks") |
| `workstations.melt_idle_sentinel` | -2.147484e9 | R | Stock `currentMeltTimesLeft` idle marker; `ldc.r4 -2.147484E+09` throughout `TileEntityWorkstation::HandleMaterialInput` (IL=531, `il/full-v3.2.0/_global/TileEntityWorkstation.il.txt:892`) and the read/write paths |
| `bot.bot_spawn_spread` / `bot_spawn_y` | 2.0 / 70 | Z | zdtd-owned `[bots]` config defaults (ADR 0026 host policy knobs; `spawn_spread`/`spawn_y` binder keys) |
| `bot.sense_kind_bot` | 2 | R | Sense contract kind tag for bots (RFC 0001 §3: 0 player, 1 zombie, 2 bot; the guest reads it in the ZBS3 records) |
| `bot.sense_kind_bot_info` | 4 | R | Sense record kind for the host-assigned weapon info row (RFC 0001 §3) |
| `systems.dmg_scale` | 100 | R | Fixed-point damage unit (1.0 hp = 100); the sim's internal damage integer |
| `worldgen.noise_weight` / `y_scale` | 0.85 / 2.0 | Z | zdtd-owned procedural worldgen shaping (non-goal #8; the demo fallback density field) |
| `sys_metrics.load_scale` | 65536 | Z | sysinfo load-average fixed-point fraction (16-bit); zdtd-owned metrics |
| `buffs.zig TrackedDeltas` / `effectTotals` | tracked surface | R | Revertible passive-effects VM: folds the tracked buffs.xml effect rows (Health/Food/Water/Stamina ChangeOT + max, resist percents) into additive deltas, recompute-from-set on the active BuffSet (stock EffectManager.GetValue fold; bounded: `max_buffs_per_entity`, no allocation). `perc_*` keep the raw XML fraction; `base_set` on tracked names is omitted (no per-entity base - recorded) |
| `buffs.zig survivalStages` / `stageBuffName` | 0.5 / 0.25 / 0.02 | R | buffStatusCheck01 StatComparePercCurrentToMax gates -> the conditional survival stage buffs (buffStatusHungry/Thirsty01..03); tickSurvival applies/removes them as state (relayed, HUD-visible) |
| `World.buff_phys_resist` | per-entity f32 | R | Buff-side PhysicalDamageResist percent cached by the survival tick (VM total); joins armorMitigation like stock GetTotalPhysicalArmorRating sums passive 41 |
| `World.buff_general_resist` | per-entity f32 | R | Buff/perk-side GeneralDamageResist total cached by the survival tick's untagged VM fold; `EntityAlive::DamageEntity` (IL=236, PassiveEffects 40) reads it with an empty tag set and applies `min(1, value)` to every damage type, so it joins every player-damage choke (AI melee, C2S claims, explosions, falling blocks, environmental DoT). Negative totals are kept (stock does not clamp at 0). Added 2026-09-12; the fold produced this field with no consumer before that |
| `Client.move_tag` / `Client.MoveTag` | idle / walking / running | R | The `EntityAlive.CurrentMovementTag` set stock's `OnUpdateLive` assigns from the move direction plus `bMovementRunning` (running/walking/idle), which `EntityHasMovementTag` IL=47 tests (`Test_AnySet`/`Test_AllSet`, invert-aware). zdtd latches the client's `NetPackageEntitySpeeds` `MovementState` (itself derived from the reported speeds by `EntityAlive::SetMovementState` IL=45: 0 stopped, 1 moving, 2 above walk speed, 3 above aggro speed) and folds state 3 to running. Shape fixed (`enum(u8)` on the client, no allocation); the tag lapses with the sprint stale timer, since a client that stops reporting stops claiming to move. Tag names are the stock `FastTags` spellings (idle/walking/running), which is the entire vocabulary the shipped `EntityHasMovementTag` rows use |
| `progression.zig PerkDef/AttrDef.passives` | 648-row surface | A | progression.xml perk/attribute passive_effect rows parsed as data (self-closing attBooks/attCrafting bodies handled); the VM's tracked fold applies to them (trackedDeltasFrom) but application waits on the perk runtime (open, scorecard "Player progression") |
| `buffs.zig curveAt` / `max_curve_len` | 8 segments | R | passive_effect curve values (`value="v1,v2,..."`): segment i applies at level i+1, clamped past the end; stock perk/armor per-level curve semantics (`curve[0]` = the legacy flat value) |
| `progression.zig perkTotals` / `trackedDeltasAtLevel` | ledger fold | R | Level-scaled tracked deltas over purchased attribute/perk levels, same revertible VM surface as buffs (armor resist + HealthChangeOT wired; perk max-stat and stamina-OT consumers recorded) |
| `buffs.zig` triggered-effect engine | onSelf* rows | R | Full triggered surface parsed (trigger/action/stat/buff + nested StatComparePercCurrentToMax LT/GT gate); `evaluateTriggered` dispatches the bounded actions (ModifyStats/AddBuff/RemoveBuff) requirement-gated, no allocation; the survival stage selection runs through it (buffStatusCheck01 update rows). ModifyCVar/PlaySound/other actions recorded, not guessed |
| `apm` survival section / counters | per tick | Z | The survival/effects pass runs under the `survival` profiler section with `survival_players` / `vm_recomputes` counters (P4b): the per-player VM fold stays observable against the 50 ms budget |
| `items.zig` StaminaLoss | per item | A | items.xml StaminaLoss (base_set, first value) = the per-attack stamina cost; the landed-hit choke drains it x `[rules.combat] stamina_usage_multiplier` (RE ItemActionMelee IL). 2-value rows = normal/power pair (first used); negative quality-curve rows recorded |
| `buffs.zig` curve_levels / `curveValueAtLevels` | explicit anchors | R | The XML `level="a,b,..."` anchor pairs (progression.xml's dominant form, 617/648 rows): value[i] sits at level[i], piecewise-linear between, out-of-range applies nothing (stock PassiveEffect.ModValue IL=796); `curveAt` prefers the anchors over the implicit scaled-index fallback |
| `weather.zig` NetPackageWeather | per-biome params | R | The server's temperature input leg: per-biome weather groups (temperature ranges from biomes.xml) roll into the slot-0 param and ship on join + broadcast; the felt temperature and cold/hot buffs are client-computed in stock (weather-environment.md §4) - client-owned by design, not a server gap |
| `Health.base_max_hp` + the survival max-stat recompute | per player | R | The passive-effects VM's max-stat deltas apply revertibly: `max_hp = base_max_hp + deltas` recomputed every survival tick (base captured at spawn), hp clamps down on reduction; food/water/stamina maxes recompute from the 100 base. perkFortitudeMastery HealthMax level 5 = 200, revert to 100 |
| survival stamina-OT consumer | perc fraction of max/s | R | The VM's StaminaChangeOT total joins the idle regen (`value x max / 100` per second, the same conversion as the stage-3 penalty): perkRuleOneCardio level 5 adds 0.45/s on a 150 cap; the sprint branch keeps the stage-3 penalty |
| `chunk_fill.tryContainerSpill` | per break | R | A broken container spills its pre-filled contents into a loot bag at the block (all 449 blocks.xml LootList blocks are CompositeTileEntity containers; the eviction path already spilled, the break path dropped nothing). maxdamage.lootListFor resolves the LootList for the pre-fill |
| `persist.zig` ZPV11 skill tail | u32 + n×(len,name,lvl) | Z | players.zsv v11 (magic 'B'): skill_points + purchased attribute/perk levels survive a restart so the spend ledger and the level-scaled VM effects restore; v10 and older records carry with the empty tail, names re-resolve against the progression catalog |
| `buffs.zig curveValueAt` | Q1..Q6 | R | Stock passive value-curve evaluation (PassiveEffect.ModValue IL=796): piecewise-linear interpolation over Levels scaled so value[0] = Q1 and value[n-1] = Q6; the item effect level is the raw ItemValue.Quality (EffectManager.GetValue IL_0393); 6-value curves are per-quality (armorPreacherOutfit .02..15), 2-value curves interpolate (primitive/leather/iron/steel 8..12.3) |
| `items.zig` armor PDR/EDR parse | per-item curves | A | items.xml PhysicalDamageResist/ElementalDamageResist (passives 41/42) quality curves parsed per item and resolved through the Extends chain; `armorPdr` (server hook) feeds armorMitigation like stock GetTotalPhysicalArmorRating sums passive 41 |
| `items.zig` DegradationPerUse / TargetArmor | flat per item | A | items.xml DegradationPerUse (base_set, per-use durability wear; wired into degradeUse) and TargetArmor (perc_add, armor penetration; wired into armorMitigationVs at the damage chokes, RE GetTotalPhysicalArmorRating IL=47). The perk-tag-gated rows (perkJavelinMaster etc.) apply when the attacker owns the tagged perk - the tag is the perk name, checked at the choke. BlockDamage/StaminaLoss/HarvestCount/LootProb recorded with their exact choke reasons |
| `ItemDef.passives` | per-item row list | A | items.xml `<passive_effect>` rows parsed with their `effect_group` + row gates through the shared `buffs.scanPassives` scanner (3030 rows over 272 items in V3.2.0; only the tracked names are consumed), resolved through `Extends` like every other item property, and folded by the survival tick for the equipped slots and the holding item (stock `EffectManager.GetValue` layers 7/8). Evaluated on `buffs.Axis.quality` (`itemQualityValue`, RE PassiveEffect.ModValue IL=796: explicit anchors interpolate, a single segment is level-independent, a multi-segment curve spreads across the tier range). The `IsEquipped` gate (IL=97) reads `Ctx.item_equipped`. PhysicalDamageResist/ElementalDamageResist stay on the dedicated curve fields above |
