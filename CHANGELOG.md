# Changelog

Consumer-visible changes are recorded here. The project follows the release
and compatibility rules in [docs/RELEASES.md](docs/RELEASES.md).

## [Unreleased]

### Added

- **Looted items roll their gamestage stats.** Stock's `ItemClass::AddGSStats` (IL=100) rolls one entry per distinct `<stats>` effect when an item value is created at a loot stage: a quality-0 base roll and, at the item's own quality, a chance-gated boosted roll, each a `RandomRange(min, max+1)` over the row's i16 range, summed and split by `isBoosted = added > 0`. The parse and the wire blob landed already; the roll itself did not exist, so a looted axe's `EntityDamage` varied on the client only, never on this server's items. `rollGsStats` implements it (with stock's exact draw order, its `chance` gate, its highest-stage-row rule and its "drop a zero sum" step) and both loot fills - container and death/airdrop bag - apply it through `Game.rollItemStats`, seeded per stack from the same deterministic stream the rest of the roll uses.

- **An item's `ItemValue` stats survive the server.** Stock writes a per-item stat block into the `ItemValue` blob (flag bit 2, a `u8` count, then `type u8 | slotA i16 | slotB i16` per entry) - the passive deltas a rolled or modded item carries, which the client reads back through `StatModifyValue`. zdtd skipped the block on read and never wrote one, so any echo of a client-created item (an inventory move, a relog, a trade) silently stripped its bonuses and the weapon's numbers changed under the player. The wire slot now parses the entries, the ECS slot carries them, and the writer reproduces the exact block, byte-for-byte round-trip pinned by a test (including the no-stats form, which is unchanged).

- **The stock `PassiveEffects` ordinal table exists as generated data.** An `ItemValue` stat entry on the wire carries the enum's numeric value (`ItemValue::Write` IL=323 writes `(byte)Stat.type`), and zdtd keyed passive effects by name everywhere with no ordinal anywhere, so an item's gamestage stat roll could be computed but never sent. `src/assets/passive_effects.zig` is now generated from the enum's declaration order in the RE dump (204 members, `None` = 0 … `HeadshotDamageModifier` = 202, `Count` = 203) by `tools/gen_passive_effects.py`, with the ordinals the RE docs pin by number (`EconomicValue` 76, `LootProb` 79, `StaminaLoss` 112, `HarvestCount` 141, `TargetArmor` 163) asserted in its test. Not consumed yet: it is the prerequisite for shipping the `<stats>` roll.

- **Leftover damage carries into the next block stage.** `blocks.xml` `PassThroughDamage` (102 stock rows, all true: the door/gate/hatch chains and the wood, steel and vehicle masters) makes stock's `Block.OnBlockDamaged` hand the surplus (`incoming - MaxDamage`) to the block that replaced the destroyed one, so a hit big enough to kill a car wreck or a gate also dents the next stage instead of discarding the excess. The property was unparsed, so every overkill stopped at the first stage. `BlockDef.pass_through` now parses it through the Extends walk, and the C2S break path walks the downgrade chain handing the surplus on, bounded at depth 8 (stock's recursion is unbounded). The walk covers the swap chain only; stock re-runs the whole damage handler, so its intermediate stages also roll harvest drops and XP, which this arm does not.

- **A trader prices an item by the item's own quality pair.** `items.xml` `TraderQualityMod="min,max"` (4 stock rows: the cooking pot and grill variants, `1,20`) overrides the trader's `quality_mod` in stock's `XUiM_Trader.GetBuyPrice`/`GetSellPrice` quality lerp, so those items climb to 20x at quality 6 instead of the trader's 2x. zdtd kept the trader's pair everywhere, which made the server charge one price while the client displayed another (no price is on the wire - the client computes its own from the same XML). `ItemDef` now carries the pair (comma form or the separate `TraderQualityMinMod`/`MaxMod` keys, inherited through Extends) and both price paths use it when declared, falling back to the trader's pair otherwise.

- **A spawn needs ground the data allows.** Stock's `Chunk::CanMobsSpawnAtPos` (`IL_0043`/`IL_004E`) requires the block under the spawn cell to carry `CanMobsSpawnOn` *and* to be movement-solid, so a player-built floor - which declares neither - hosts no spawns while terrain keeps them. The director asked nothing, so a walled concrete base spawned just like the forest. `CanMobsSpawnOn` now gates every director spawn (per-player ring, party/blood-moon waves, wandering packs, scouts, ambient drip) through a hook the game wires to the blocks table; a block the table does not know keeps the pre-parse "allowed" answer, so a builtin or offline world is untouched.

- **The `Collide` mask now decides movement and sight.** `blocks.xml` `Collide` is stock's `Block.BlockingType`: a per-verb bit set that `IsCollideMovement` and `IsSeeThrough` read. 66 of the 418 stock rows clear the movement bit (grass, plants, cobwebs, campfires, trash piles, spikes, barbed wire, quest markers, water) and 365 clear the sight bit (containers, most glass), so a server that treats every non-air block as solid both stops zombies at grass and hides them behind glass that stock sees through. The parsed mask is now consumed: `World.isSolidWorld` reads the movement bit and a new `World.sightBlockedWorld` reads the sight bit (water always blocks sight, a stock quirk `IsSeeThrough` spells out), the AI LOS and the bot LOS gate use the sight predicate, and a block with no `Collide` property keeps the all-bits default, which is the previous behaviour.

- **The trader refuses items the data marks unsellable.** 48 stock items carry `SellableToTrader="false"` (the quest masters, the bone knife, the biome badges); stock parses it into `ItemClass` with ParseBool and its sell path refuses them, so the client greys the Sell button and nothing reaches the server. The flag was unparsed, so a peer could sell them anyway. `ItemDef.sellable_to_trader` now parses it (default true, inherited through Extends) and the sell request is rejected before the trade runs.

- **A joining player spawns on ground the data allows, not on a tree.** `blocks.xml` `CanPlayersSpawnOn` defaults true and 24 stock rows declare false (`treeMaster`, every vehicle master), which is what stock's `Chunk::CanPlayersSpawnAtPos` checks on the block under the feet. The spawn-surface finder took the topmost solid block, so a forest column could put the player on a canopy. It now walks down over blocks that forbid player spawn (bounded descent) until it reaches one that allows it. `CanMobsSpawnOn` (default false) parses too and is available to the AI spawn gate.

- **Modlet localizations reach the client.** Stock merges every mod's `Config/Localization.csv` in load order and ships the patched cells to a joining client as `NetPackageLocalization` (`Localization.WriteCsv` -> raw-Deflate -> 128 KiB parts), which is why a modded server shows the mod's item and buff names instead of raw keys. zdtd never read those files and sent no such package at all. The base header row now becomes the column index, each modlet file contributes its cells (a later mod wins), the CSV is built and deflated the way stock's writer does, and the package is sent at stock's point in the enter-game sequence - between the id mapping and the config files. Verified with the loadgen against the same six-modlet set: zdtd sends `NetPackageLocalization` with a valid deflated CSV (19010 bytes against stock's 19554, both at deflate level 3, over the same 459 patched keys) and the join still completes.

- **The client-visible game stats follow the operator's config instead of constants.** Six entries in the join `GameStats` blob were hardcoded in the writer: `IsCreativeMenuEnabled` and `IsFlyingEnabled` (stock seeds both from the serverconfig `BuildCreate` pref, so a server running with cheat mode on could not give its client the creative menu or flight), `CameraRestrictionMode` (`CameraRestrictionMode` is a real serverconfig key), and the sandbox-managed `DropOnQuit` (GameStats[34]), `AirDropMarker` ([53]) and `BiomeProgression` ([66]). All six now come from `serverconfig.xml` or the decoded sandbox code. `ScorePlayerKillMultiplier` was also wrong: `GameModeSurvival::Init` (IL_0035-0038) sets it to 0, not 1, while the zombie multiplier stays 1 and the died multiplier -5. The admin console's `getgamestat` reports the new values.

- **The block collision mask is parsed.** `blocks.xml` `Collide` (418 stock rows) is stock's `Block.BlockingType`: a comma list whose verbs OR into six bits (sight 1, movement 2, bullets 4, rockets 8, arrows 32, melee 16), matched as case-insensitive substrings, absent meaning "collidable material" (255). The value now parses into the block table and resolves through Extends, including the `param1="Mesh,Collide"` opt-out the business-glass rows use. Nothing consumes it yet - the recorded value lands first, and the movement/sight consumers follow - so runtime solidity is unchanged.

- **A patch op that matches nothing is logged, like stock.** Stock's `XmlPatcher` warns `XML patch for "x.xml" from mod "y" did not apply` and carries on; zdtd skipped in silence, so a modlet whose target moved looked like a modlet that worked. An A/B against the stock dedicated server on the installed SphereII/0-SCore set shows both sides flagging the same two data mismatches (Blooms Family Farming's `cropsGrowingMaster` growth-rate row and Item Mod Degradation's `toolAnvil` effect group); zdtd reports extra rows where the mod's own DLL-registered op (`ref_file`) was not applied and where the same catalog is loaded more than once.

- **The patch XPath subset covers the forms real modlets use.** Two gaps made popular patch files apply partially: an element-existence predicate with a nested clause (`block[property[@name='Tags' and @value='treasureHunter']]`, used by Winter Project and 0-SCore) was split on the wrong ` and ` and rejected, and `[last()]` (`/entitygroups/entitygroup[last()]`, A Better Life) was not modelled at all. Element-existence and `last()` now resolve, and the match collector walks the path segment by segment, so a path whose repeated element is not the root (`/root/child[...]`) no longer stops after its first match - which is also what made `[last()]` pick the wrong node. The three corpus xpaths are pinned by a test.

- **XML-only modlets load instead of stopping the boot.** Three fatal paths are gone, all of them hit by the popular server-side modlets: `<include>` now reads stock's `filename=` attribute and resolves it against the *including file's* directory (all 126 `<include>` rows in the installed SphereII/0-SCore/OCB corpus resolve that way, and a CWD-relative miss used to abort startup); a patch whose root is not `<configs>` is treated as a container rather than an unknown op (0-SCore ships `<SCore name="...">`); and an unknown op warns and skips its element the way stock's local-name lookup does (a code modlet that registers its own op no longer takes the config load with it). A known op with no `xpath` drops that one patch file, matching stock's `XmlPatchException` handling, and an xpath this engine's subset cannot parse is now logged with a per-file count instead of being skipped in silence.

- **Bedrock cannot be destroyed, even by a forged block edit.** `materials.xml` `CanDestroy=false` (only `Mbedrock`) zeroes the block-damage scalar in stock's `ItemActionAttack::Hit`, and the dedicated server applies a client's `NetPackageSetBlock` verbatim, so a modified or bot peer could delete bedrock. The material value is parsed into the block table and both block-damage funnels fail closed on it: the `addBlockDamage` choke point (zombie chew, traps, blasts) and the C2S break decision. A stock client never notices, since it never sends damage for such a block in the first place.

- **Placeholder random rotations take stock's 45 degree band.** `Has45DegreeRotations` lives on the block shape: only `BlockShapeDistantDecoTree`'s constructor sets it (`IL=6`), and stock's `treeMaster` declares `Shape="DistantDecoTree"`, so every tree inherits it (50 stock blocks). `BlockPlaceholderMap` (`IL_027D-02AD`) rerolls a `randomrotation` target with `RandomRange(8)` and maps rolls above 3 to `+20` (24..27) on such a shape, and `RandomRange(4)` otherwise; zdtd always took the four-way band, so 168 stock `randomrotation="true"` targets (trees among them) landed on a rotation the client would not have received. The block table now resolves the shape through Extends, the placeholder loader stores it per target, and the per-cell reroll follows the same branch. The kind of shape matters, not the kind of block: `treeCactus01` carries the plain `DistantDeco` shape and keeps the four-way band.

- **`EconomicValue` is a float, so a big or fractional price survives.** Stock declares `ItemClass.EconomicValue` as `Single` and parses it with `ParseFloat` (IL_0666); zdtd typed it `u16`, so any modlet price above 65535 (or with a decimal) parsed to 0 - the trader's "econ == 0" marker - and the item was stocked at the buy-5 / sell-1 fallback instead of its authored price. The item and item_modifier loaders now keep the parsed float and every price formula (`fillTraderFromXml`, `traderSellPrice`) consumes it as one.

- **The item quality bound comes from `items.xml`.** Stock reads the `<items max_quality_tier="N">` root attribute into the static `ItemClass.MaxQualityTier` (`ItemClassesFromXml.CreateItems`, fallback 6) and every quality axis spreads over it; zdtd had 6 compiled into `components.max_quality_tiers` and never looked at the attribute, so an XML-only modlet that raises the tier was silently clamped back down on the server while the client kept the higher tier. The loader now keeps the parsed bound on the item table and the passive folds, armour PDR curves, crafting-tier clamp and harvest multiplier all use it (an absent or degenerate `0` keeps stock's 6).

- **Game-event sequences run from the parsed table, client legs included.** Stock splits a sequence's actions by C# base class: the `ActionBaseClientAction` descendants (`ModifyEntityStat`, `ModifyCVar`, `AddXPDeficit`, `RemoveItems`, `AddStartingItems`) do nothing server side except hand the leg back to the target player as a `NetPackageGameEventResponse` `ClientSequenceAction` (12) keyed by `BaseAction.actionKey` (`SetActionKeyData` IL=23), while the `ActionBaseTargetAction` legs (`RemoveDeathBuffs`, `AddBuff`) are the ones the server performs itself. The runner now classifies every leg and emits one response per client leg at its parsed index, so `game_on_respawn_permanent` (`RemoveItems` + five `ModifyCVar` + `RemoveDeathBuffs` + `ModifyEntityStat`) runs instead of being refused for an unknown item action, and the death family's `AddXPDeficit` no longer needs the hardcoded `game_on_death_default0` index. The key is the concatenated root form stock builds (`<sequenceName><index>`, nested `<parentKey>:<index>`), and a stat operation other than `Set`/`SetMax` refuses the sequence: stock performs a client leg on the server as well, so an `Add` would otherwise land twice.

- **Loot entries install their `mods=` list on the spawned item.** The 5 stock gun entries carry `mods=` (`barrelAttachments,sideAttachments,smallTopAttachments,trigger` at `mod_chance=".50"`, one `scope` at `1`); the loader kept the attribute but nothing installed it. `installLootMods` now resolves each tag to a fitting modifier the way stock's `ItemValue.createDefaultModItems` (IL=759) does: exact item name first, otherwise any modifier whose `installable_tags`/`modifier_tags` list carries the tag, gated by `isSuitable`, installed when `RandomFloat() <= chance` with the chance halved after every install and the count capped by the item's `ModSlots` quality curve. Two supporting pieces landed with it: `item_modifiers.xml` rows are now registered as item classes in the same id space as `items.xml` (`ItemTable.addItemClasses`, matching stock's `items` -> `item_modifiers` load order and leftover-id assignment), because the wire carries an installed mod as a nested `ItemValue` referring to that id; and the ECS <-> wire mod ids now convert through the item-type resolver in both directions instead of assuming the ECS id is the wire's relative item index, which only held for builtin ids.

- **Loot bags carry the rolled item values, and quality stops being guessed from stack size.** `fillLootBagFromTable` deposited every rolled stack through the plain stack-merge path, dropping the rolled quality and random-durability wear; a death/airdrop bag is a stock `LootContainer` roll, so it now deposits through a value-carrying path. While wiring it, the quality gate turned out to be `stack == 1`, which is wrong for any `ItemClass.HasQuality` item with a larger Stacknumber: a Q6 stone axe (Stacknumber 500) lost its quality in containers *and* bags. Both paths gate on the parsed `HasQuality` flag now, and stackables still keep quality 1.

- **Equipped and held items join the loot `LootProb` fold.** The fold covered purchased perk/attribute rows and active buffs; it now also walks the held item and every equipment slot at that item's own quality tier, which is what item-side rows need: a Q6 `armorFarmerHelmet` (`LootProb perc_add 2,4,6,8,10,20 tier=1..6 tags="seedSkill"`) adds its tier value (+20% at Q6, +2% at Q1) to `seedSkill`-tagged loot. With the 128 progression rows this makes every stock `LootProb` source live.

- **Tagged loot entries fold the player's `LootProb` passives.** 431 stock entries carry `tags=`; stock uses that list as the query tag set for `EffectManager.GetValue` of passive 79 (`LootProb`) and folds the result onto the entry's probability, which is what perks like `perkDeadEye` (`perc_add 2..10 tags="rifleSkill,ammo762mm"`, 128 stock rows in progression.xml) are for. The roll now applies a `ProbScale` callback for tagged entries, and the fill path answers it from the opener's purchased perk/attribute rows at their level plus the active buffs' rows at their duration, with the GetValue op semantics (`base_set`/`base_add`/`perc_add`…). A Dead Eye 5 player sees rifle-tagged loot at +10%.

- **Loot entries can spawn a random-durability item.** `random_durability="true"` (123 stock rows, all explicitly `false` today) now marks the rolled stack, and the container fill starts the item at `(int)(MaxUseTimes * RandomRange(0.2, 0.8))` — stock `LootContainer` IL_032D — using the container's deterministic roll seed, so a worn tool is reproducible. An item with no durability stays pristine.

- **Loot entries apply their `buffs` to the opener.** 63 stock entries carry a `buffs=` list (62 `buffPerkBookwormSuccess`, the bookworm success chime). Stock collects a spawned entry's list during the roll and applies it to the opener after it (`LootContainer.ExecuteBuffActions` → `Buffs.AddBuff`); the roll now reports each spawned entry's list through a `LootBuffSink` and the container fill adds them through the catalog path that also relays the buff to the client. An unknown name fails closed, which is what stock's own typo'd `buffbuffPerkBookwormSuccess` row needs.

- **`loot_stage_count_mod` grows loot counts with the loot stage.** The 84 stock entries that carry it (all `0.01` on ammo rows) now add `RoundToInt(count * mod * lootStage)` to the sandbox-scaled count, matching `LootContainer` IL_017F, so a stage-50 roll of 6..8 rounds spawns roughly 9..12 while a stage-0 roll is unchanged.

- **Per-entry loot `quality` override.** `loot.xml`'s `ParseItemList` lets an item entry pin its quality with a `quality="N"` attribute, overriding the loot quality template; the loader ignored it. Entries now keep the attribute and the roll uses it instead of the template value. Stock's own file writes `quality` only on the `<loot>` rows inside `<lootqualitytemplate>`, so this is engine/modlet support rather than a stock-behaviour change (a test pins both facts).

- **`abundance_type` scales loot group counts.** The 67 stock groups that carry `abundance_type` (Armor/Books/Magazines/Melee/Ranged) now scale their counts by that category's sandbox count option, read from the decoded server code (`FoodLootCount` ... `BookLootCount`, `LootAbundanceValues`), matching RE `RandomCountFromSandbox`. A category whose option is 0 disables it and spawns none of it, so the entry is dropped rather than written as an empty stack. The field was parsed onto `LootContainer`; stock puts it on `<lootgroup>` (67 groups, 0 containers), so it moved to `LootGroup` where the roll reads it.

- **`SandboxOption` loot gates compare numerically.** The last unanswerable loot requirement class (3 stock rows) marked its entry omitted. `LootEntryRequirementSandboxOption` now reads the option's value under the server's decoded sandbox code and compares it with the requirement's operation and value, so stock's `HarvestingOutput EQ 0` ("output disabled") means what it says instead of being dropped; the fill path decodes `Game.sandbox_code` into the opener's requirement context.

- **Progression `triggered_effect` rows fire on level changes.** `progression.xml` carries `onSelfProgressionUpdate` rows (they were parsed as passives and dropped). The perk/attribute bodies now keep their `triggered_effect` rows with effect-group and row gates, and `Game.fireProgressionUpdate` runs them from every level change (`addProgressionLevel`, `purchaseSkillAtCost`, the stock SetProgressionLevel and purchase paths). The payoff is data-driven: `perkIntellectMastery` sets `$perkBookwormChance` to 25 at level >= 2 and 0 at <= 1, so the 63 loot `RandomRoll` gates below roll at 25% for that opener instead of never. The rows' stat/buff actions are parsed but not applied yet (the perk runtime is open), the same limit the perk passives carry.

- **Loot `<requirement>` gates evaluate player state.** Container loot carried `LootEntryRequirement*` children that the loader ignored, so a gated entry rolled at its base `prob`: `groupWorkingStiffsBooks` (no `prob`, i.e. 1.0, gated on `RandomRoll @$perkBookwormChance`) filled every Working Stiffs crate. The gates now parse and resolve per class: `Biome` against the container's biome, `Progression` / `CVar` through the shared `requirements.Ctx` built from the **opening player's** ledger (perk levels, cvars), and `RandomRoll` as `Lerp(min_max, roll)` against a literal `value` or a `value="@$cvar"` operand, using the roll path's deterministic per-entry stream so a re-roll stays reproducible. With no opener (scan-time or an anonymous re-roll) those gates refuse, keeping the entry omitted rather than rolling it for nobody. Stock counts, excluding the commented header examples: 63 `RandomRoll`, 14 `Progression`, 5 `Biome`, 3 `SandboxOption`; the `SandboxOption` rows stay omitted (numeric sandbox-option compare not wired), and the 63 `RandomRoll` rows read chance 0 until the `onSelfProgressionUpdate` row that writes `$perkBookwormChance` exists, which is stock's own answer for a player without the perk.

### Added

- **Enable/disable each modlet from the webui.** The Modules panel now lists the scanned XML modlets (name, version, state) with an enable/disable control; the choice is saved to `modlets_disabled.txt` next to the world save (one mod name per line, hand-editable) and applies on the next start, since the patched catalogs and item ids are resolved once at init. A disabled mod is still listed, so the selection is visible and reversible, and its `Config/` patches are simply left out of the merge. PRD 0003 R13.

### Added

- **The stock random generator is ported, and placeholders draw from it.** `GameRandom` (`GameRandom.il.txt`) is the .NET Framework `System.Random` algorithm - the 56-entry `SeedArray`, `MBIG` 2147483647, `MSEED` 161803398, the `inext`/`inextp` subtractive step, `Sample() = InternalSample() * 4.6566128752458E-10` - and `src/util/game_random.zig` implements it together with `Utils::RandomFromSeedOnPos`'s coordinate fold (`seed + x + (z << 14) + (y << 24)`). Its test pins eight seeds against goldens generated from Mono's `System.Random`, the same algorithm. The blockplaceholders per-cell roll now uses it instead of zdtd's xorshift stream, so a placeholder cell resolves to the target stock would pick, and the `randomrotation` reroll uses stock's `RandomRange(4)`.

### Added

- **Prefab placeholder blocks resolve to their real targets.** A prefab's block map names cells like `terrStoneHelper` or `carWrecksRandomHelper`, which are not blocks: stock keeps a `blockplaceholders.xml` list per name and picks a target for every cell it stamps (`BlockPlaceholderMap::Replace` IL=185) using a per-position stream (`Utils::RandomFromSeedOnPos` IL=2666 seeds it with `seed + x + (z << 14) + (y << 24)`), skipping targets whose `biome` does not match the cell and whose `sandboxoption` gate fails, then walking the survivors in document order against `RandomFloat() * sum(prob)`. `randomrotation="true"` re-rolls the rotation off the same stream. zdtd had no placeholder support at all, so those cells became air (the remap reported them as unknown blocks). `assets/blockplaceholders.zig` now loads the catalog (targets resolved to block ids, sandbox gate precomputed), the prefab remap records the placeholder index per cell, and the paint pass resolves each cell at its world position with the biome name and the map seed - so a POI's terrain-helper and random-helper cells become the blocks stock would place.

### Added

- **A modlet's added block gets a block id (PRD 0003 G9).** The block loader skipped any name the stock AssignIds dump does not carry, so a modlet that adds a block was inert. It now keeps those rows and assigns them the way `Block.assignLeftOverBlocks` (IL=7528) does: the dump's names mark their ids used, then the leftovers take the first free id - terrain-shaped blocks (`Shape="Terrain"`) scanning from 0, everything else from `0xff` - in document order. A modded client runs the same algorithm on the same document, so both sides agree. The assignment is not a no-op on a stock install either: 11 `blocks.xml` names sit outside the dump (the nine `*Shapes` shape masters plus `cntChickenCoop` and `oldWoodDoorNoHonk`) and take ids 255..268, which a test pins against the real file. Block ids come from the u16 space and exhaustion drops the block rather than stamping a wrong id.

### Fixed

- **Client-evaluated loot conditionals stay out of the server's tables.** Stock's `XmlPatcher::ApplyConditionalXmlBlocks` takes an evaluator, so a `<conditional evaluator="client">` block belongs to the client build only. The seven stock rows are all `event('christmas')` holiday-gear entries inside `count="all"` groups (`groupZpackBoss`, the reinforced and hardened chest groups, `groupHiddenStash`), and the loot loader scanned every `<item` in the body, so a dedicated server put a christmas item in every one of those containers all year long. The loader now strips client-evaluated conditionals from a group/container body before scanning it (bodies without one are left untouched), and both a fixture and the real `loot.xml` are pinned by a test.

- **Blasts respect land claims.** Stock divides an explosion's block damage by `World::GetLandProtectionHardnessModifier` (IL=8823), so a stranger's blast meets `Max(1, claim owner's durability modifier) x LPHardnessScale` inside somebody else's claim: the owner's own explosives are exempt, a zombie's blast ignores claims entirely (`EntityEnemy` returns early), and a block whose `LPHardnessScale` is 0 (stock ships `cntGasPumpRandomLootHelper` that way) is never protected. The value defaults to 1 when a block does not declare it — the property loader sets 1 *before* reading the row — so claims protect all normal blocks; only the 7 stock rows that override it change the baseline (terrain is 2). zdtd's blast path had no claim leg at all: a player could flatten another player's base with explosives while the dig path refused the same edit. `blocks.xml LPHardnessScale` is parsed (inherited through `Extends`, declared-vs-default tracked) and the blast choke applies the divisor for both the cop blast and the client explosion path.

- **The sandbox `MaxStackSize` option scales item stacks.** Stock pushes the decoded `StackSizeMultiplier` (option 163) into `ItemClass.MaxStackSizeModifier`, and `ItemClass.get_MaxCount()` (IL=10) multiplies it into every stackable, non-quality `Stacknumber`, clamped at 30000; quality items (weapons, tools) and non-stacking items keep their raw value. zdtd returned the raw XML `Stacknumber` and nothing read the option, so a server configured for bigger stacks still enforced the stock ones. `ItemTable.stackFor` now implements the stock getter (with `Utils::FastRoundToInt`, which is .NET's midpoint-to-even rounding), the decoded option is applied at init, and the two clamps that read the raw field directly - the C2S inventory clamp and the player-data load clamp - go through it, so a legitimately scaled stack is no longer crushed back on load.

- **Respawn stats come from gameevents.xml, not from the code.** `respawnPlayer` hardcoded `hp = 100; max_hp = 100; base_max_hp = 100` and left Food/Water alone; stock's respawn flow asks the *server* to run a data sequence (`game_on_respawn_injured` sets Food/Water to half their max and adds `buffInfectionCatch` behind an infection CVar gate, `game_on_respawn_none`/`_default` do `ModifyEntityStat ... SetMax` on Food, Water, Health and Stamina), because the client's `GameEventManager::HandleActionClient` only forwards `NetPackageGameEventRequest`. zdtd now parses `gameevents.xml` in a new `assets/gameevents.zig` and runs the sequences in `game/game_events.zig`: at the respawn funnel, from the death path (where `game_on_death_*` also does the death-buff removal, honouring the injured sequence's `exclude_tags="deathpenalty_injured"`), and from a client request that names a sequence. The respawn funnel itself now restores each stat to its own current maximum, so a player's earned HealthMax bonus survives death instead of being reset to 100. A sequence holding an action or gate this server cannot evaluate (`RemoveItems`, `AddStartingItems`, a `<decision>`, a sequence-level requirement) is refused whole rather than half-run, and the offline death-deficit response keeps stock's action index 0 as its floor; with the stock file present both the sequence name and the `Name:index` root action key come from the data.

- **Blasts use the block's material instead of deleting everything in the radius.** A client's `NetPackageExplosionInitiate` used to clear every block inside the claimed radius; the cop blast applied a flat `BlockDamage x falloff` against the block's MaxDamage. Stock's `Explosion::AttackBlocks` (IL=553) computes `round((1 - resistance) * power * falloff / (hardness * land_mod) * categoryMultiplier)`, destroys the block outright when its material declares no `Hardness` (58 of 166 stock materials, dirt among them: stock builds a default `DataItem<float>()` there and takes the `MaxDamage` branch), and only then runs the MaxDamage accumulation, downgrade swap and destroy broadcasts. Both blast paths now route one block at a time through one shared `Game.blastBlock`, so steel (0.5 resistance, 7000 HP) survives a blast that breaks stone and reinforced concrete takes 0.2 less, the earth/stone DamageBonus rows still keep terrain intact, and a block that is only cracked is echoed to clients as a damage-only SetBlock the way the stock explosion batch does. The falloff now follows stock too: `1 - max(0, |blockCentre - blastPosition| - 0.5) / radius` measured from the real blast position, where the old cell-index distance overstated the range on the diagonals. `materialHardness` is tri-state so the offline catalog keeps its old raw-damage behaviour rather than inventing the destroy branch.

- **A writable crate's label reaches the other players.** The container TE echo replaced the client's whole composite with a storage-only body, so the sign module (and the lockable module) a writable crate declares never left the editing client: stock applies the client's composite to its own `TileEntitySignable`/`TEFeatureStorage` set and reserializes all of it. The echo now splices the server's clamped storage module into the client's own body - markers and every other module byte-identical, so the crate's text and lock state ride along - and falls back to the storage-only body when the re-encoded module cannot keep the received span (a module whose slot payload changes length). `TileEntityComposite::read` at version >= 17 reads exactly the modules a body declares and warns only about hashes the block no longer defines; the "Skipping TE payload" path is the legacy version < 17 branch (IL_016C-IL_01FC), which is what an earlier note here mis-attributed to modern bodies.

- **Sign text reaches the other players.** Stock carries a sign's authored text in the composite TileEntity stream, not in a sign package: the client's `TileEntity::setModified` sends `NetPackageTileEntity` with a fresh handle, and the dedicated `ProcessPackage` applies the body to its own `TileEntitySignable` and rebroadcasts it within 192 m to every spawned client including the sender, keeping the handle so the sender's `lockHandleWaitingFor` clears and the sign UI closes. zdtd had no sign handling at all, so every edit was dropped and no player ever saw another player's sign. The body is now parsed (module table walked by `GetStableHashCode` name hash, each module bounded by its own inclusive size marker), accepted only when the block at the addressed position is still the claimed type and is one whose blocks.xml composite declares `TEFeatureSignable` (the player signs, the metal sign letters, the writable crates), and echoed byte-identically to everyone in range. The applied body is also kept (`signs.zsg`, beside the world save) and replayed when a client's chunk streams in, so a player who joins or reloads the area later still sees the text instead of a blank sign, and the entry is dropped when the block goes away. Two supporting fixes came with it: `parseStorageTeBody` now requires a `TEFeatureStorage` module (a composite without one used to parse as an "empty container", so a sign body created a phantom 8-slot container at the sign), and text longer than the server's buffer fails closed instead of truncating mid-string.

- **A client's own sound now feeds the AI noise model.** `sounds.xml` holds 1312 `<Noise>` rows (footstep 3-11, gunfire 60+, each with `muffled_when_crouched` and an optional `heat_map_strength`), and the loader built the table but nothing ever read it: the C2S `NetPackageAudio` handler relayed the sound to the other players and threw the packet's other half away. Stock's dedicated branch routes the play through `Audio.Server::Play`, whose first act is `Audio.Manager::SignalAI` (`Manager.il.txt` IL=4696) -> `AIDirector::NotifyNoise`, which resolves the clip name in that table and folds `volume x volumeScale` into the instigator player's stealth noise, sleeper-volume wake and heat map. SignalAI returns unless the instigator is an `EntityPlayer` and only the entity-form packet reaches it, so the leg now runs exactly there; `signalOnly` - the "AI stimulus, do not play" flag - suppresses the client relay and no longer suppresses the AI noise. The row's `heat_map_time` is parsed by stock into `AIDirectorData/Noise::heatMapTime` but never read: the live heat window is the constant 240 s `NotifyNoise` passes (`AIDirector.il.txt` IL_00D9), which is what the fold uses now. `SoundDataNode` scanning matches element names case-insensitively the way stock's `Extensions::EqualsCaseInsensitive` does (`<noise>` is `<Noise>`), keys the table by the lowercased basename the client's `SignalAI` name is normalized to, and no longer ends the whole scan at a self-closing node.

- **Armoured entity classes take their `PhysicalDamageResist`.** `entityclasses.xml` ships 8 untagged `PhysicalDamageResist` (passive 41) rows (zombieSoldier 50, zombieDemolition 60, zombieBiker and zombieUtilityWorker 20); the loader kept only the `HealthMax` row, so those classes took full damage. The percent now parses through the class `Extends` chain into the class table and every spawned entity, and is applied wherever the **server** computes the damage. Immediate hits (the C2S damage claim, cop blasts and the client-reported explosion path, bot fire, traps) resolve it inside `World.damageFrom`, which is where the victim's own `EntityAlive.DamageEntity` legs live, and that call now reports the post-resist value on the wire so the hit reaction matches the hp drop; the tick's deferred accumulator (AI melee) and the parallel turret tick apply their own copy because neither reaches `damageFrom`. Two tag-gated swarm rows (`tags="ranged"` 99 / inverted 75) are deliberately skipped rather than folded into one number, since applying either to every source would over-resist.

### Fixed

- **XML-only modlets from the modding sites load like stock.** The patch engine now accepts the operation vocabulary stock registers (`csv` in addition to the internal `csvoperations` name), splits `setattribute` from `set` the way stock does (the attribute name comes from the patch element's `name=`, while `set` handles a trailing `/@attr` or replaces an element's children), appends/prepends to an `/@attr` target's text, refuses to remove an element through an attribute path, honours the `csv` `delim` attribute (one character or the literal `\n`, default `,`) with per-entry add/remove, and applies an operation to **every** XPath match instead of the first (a `contains()`/`or` wildcard patch hits all of them). The XPath subset grows the predicates real modlets use: `contains()`, `starts-with()`, `and`/`or` groups, `[@attr]` existence and `[N]` position. `<conditional>` blocks evaluate `mod_loaded(...)` and `mod_version(...)` against the scanned mods and skip an expression this server cannot evaluate (NCalc's `game_version`) with a warning instead of refusing to boot. A mod's patch for one config is now resolved exactly like stock (`<mod>/Config/<configName>`, ".xml" appended when missing), so a config that lives in a subdirectory (`Config/XUi_InGame/windows.xml`) is patched too, with the per-file scan kept for mods whose patch file is named differently.

### Fixed

- **Crafting follows the stock skill/tier rules.** `recipes.xml` `effect_group` rows and the `tags` attribute now parse (stock appends the recipe name to the tag set, which is how item-name-tagged rows match), and `crafting_skill` passives in `progression.xml` join the catalog. `Recipe.GetCraftingTier` (base 1, folded over the player's crafting-skill and perk `CraftingTier` rows at their purchased level, flat 6 when the `CraftingProgression` sandbox option is off) now drives two things it did not before: the crafted output's quality tier (a HasQuality item is deposited with it instead of always quality 1) and, for `use_ingredient_modifier` recipes, each ingredient's required count (`CraftingIngredientCount` = passive 198 folded at the crafting tier, clamped to at least 1). A workstation output now keeps the queue item's quality as stock `TileEntityWorkstation` does, so two crafts at different tiers no longer merge.

### Fixed

- Stock XML config fidelity (audit snapshot `docs/archive/XML_FIDELITY_AUDIT_2026-09-13.md`). Every `Data/Config` file was reviewed against its zdtd loader; these are the P1 fixes from that pass.
  - **`blocks.xml` / `materials.xml` property inheritance.** `MaxDamage` (318 own rows, 1449 inherited, the rest defaulting to the material's value), `Material`, `Stage2Health`, the power props and the turret combat stats now resolve through `Extends`, and a child's `Extends param1` list excludes the named properties exactly like stock `CreateProperties` (925 stock rows; `Class` 107 times, `DowngradeBlock` 72, `MultiBlockDim` 33, `MaxDamage` 12). `<dropextendsoff />` (226 rows) now stops the parent drop rows from merging, and material-level `StabilitySupport` (23 rows, 19 false) is the block default when the block does not declare it. `explosionresistance` (24 material rows) parses and is exposed per block for the blast path.
  - **Sandbox boolean defaults.** The generated table forced `default_i = 0` for every boolean option, so 25 of the 32 stock options read false when the server code omitted them (including `CraftingProgression`, `NewbieCoat`, `EnemySpawnMode`). The generator now emits the census default; `sandbox_data.zig` is regenerated.
  - **Blood-moon row duration.** `AIDirectorGameStagePartySpawner::SetupGroup` arms `nextStageTime = worldTime + duration * 1000` (world time is 1000 units per game hour); zdtd multiplied by 20, so every `gamestages.xml` row deadline fired 50x early and the horde advanced through its rows almost immediately.
  - **Biomemap ids resolve by name.** The height-band fallback and the no-biomemap fill used literal ids 1/3/5; they now resolve `snow`/`pine_forest`/`desert` through the loaded `<biomemap id name>` table (`ColorTable.idForName`), keeping the numeric pins only for the no-game-dir case.
  - **Quest objectives read their real radius and variables.** `POIStayWithin`/`StayWithin` carry the radius as a nested `<property name="radius" value="25"/>` (15 stock rows), which the loader ignored; `biome_filter_type` and `biome_filter` now honour `param1` variable substitution against the quest's `<variable>` overrides (18 stock rows).
  - **`lootcontainer count` drives the pick count, and a pick's prob is its weight.** The roll made one independent prob roll per entry, so a `count="1"` container (268 stock rows) could spawn several stacks; it now takes `count` min/max picks (default 1,1) with the same prob-weighted pick the group path uses, and `count="0"` (33 rows) spawns nothing. The picked entry no longer passes a second absolute prob gate: stock `SpawnLootItemsFromList` normalizes `getProbability` into the pick weight (only `force_prob` entries gate independently), so the extra gate double-counted the loot-stage band and the `LootProb` fold. The player's `LootProb` rows now fold into the weight (a tagged entry's folded prob is its share), which is what makes the 128 progression rows shift which item a pick lands on.
  - **`traderAlways` only when the row is unresolved.** A resolved `<trader_info>` with no `<trader_items>` is intentionally empty (traders.xml id 3 player-owned, id 5 rentable vending); the vending/stock fill no longer stocks those from `traderAlways`.
  - **Modifier rows are full item classes.** `item_modifiers.xml` rows now carry `EconomicValue` (400 on modGeneralMaster, inherited by every live row), `Stacknumber` and the owner-tiered quality flag, so a mod registers with real econ (it priced at the 5-duke unknown fallback) and quality. `ItemTable.addItemClasses` takes those fields.

### Changed

- **Health replication walks the dirty set.** `replicatePlayerHealth` scanned all `max_entities` slots every tick; it now iterates a snapshot of `dirty_bits`, which every hp writer maintains (through `markDirty` or the explicit `syncDirtyBit` on the WindowFull retry). No wire or behaviour change.
- **Plugin logs use the manifest vocabulary.** `OverridePoint.wire()` returned `@tagName` (underscored), so a refused `damage.player_scale` claim logged `damage_player_scale` while mods write the dotted name. It now returns the manifest name from the point table.
- **Idiom cleanups (Zig 0.16).** `QueueVerb`'s parallel `names` table is gone (its tags already are the operator vocabulary, parsed through `@tagName`); `parse` on the two policy enums is `parseVerb` / `parsePoint`; `std.meta.tags` is `@typeInfo(...).@"enum".fields`; the 10 `std.mem.indexOf` call sites use `find` (0.16 makes `indexOf` an alias); `WireProfile.plane_cells` / `c_max_height` / `y_pow` are `planeCells` / `cMaxHeight` / `yPow`.
- **The static plugin host is off in the shipped configuration.** `enable_sample_plugin` defaulted to true, so every product build registered the native vtable `sample_hello` host and composed its verdicts before Wasm on 28 hook names across 18 files, while ADR 0020 decision 2 calls that host test scaffolding rather than a product surface. The `InitOption` default and both shipped presets are now false; tests and a deliberate `enable_sample_plugin = true` still exercise the native path. One plugin mechanism is live by default.

### Fixed

- Review follow-ups (round 6).
  - **`world/store.zig` `sea_level` divergence row closed as a framing error.** The row compared zdtd's flat empty-world fill height (64, zdtd-owned, operator-tunable via `[rules.geometry] sea_level`) with stock's `Block.cWaterLevel` water surface (62.88). The stock constant is implemented where it applies, the RWG water table (`world/worldgen.zig water_surface_cell = 62`, pinned by its test), so the two are different quantities and there is no divergence to track.

### Fixed

- Review follow-ups (round 5).
  - **Dead `Dirty` bits removed.** `Dirty.spawn`, `.remove` and `.inv` were written in 13 places (including a `markInv` helper called from every inventory mutation) and read by nothing, and `.inv`/`.remove` were never cleared, so any entity that ever set one stayed in `dirty_bits` forever and was re-considered by every replicate pass. The bits, their writers and the `markInv` helper are gone; `dirty_bits` now releases a slot once its motion/health bits are consumed.

### Fixed

- Review follow-ups (round 4).
  - **Plugin HMR re-reads `config.toml` (F11).** A manifest-backed reload
    re-read `/manifest.toml` but kept the pre-reload `config_bytes`, so an
    edited `config.toml` was never seen until a restart. The config is now
    re-read with the declaration; a missing or oversized file fails closed to
    no config, the same rule `loadResolved` applies.
  - **Unreliable sends use the peer's MTU, not the compile cap.** LiteNet
    negotiates an MTU per peer, and `sendUnreliable` rejects anything above
    `min(max_single_user, peer_mtu - header)`, so a frame between that limit
    and the compile cap returned Overflow and was dropped with no fallback on
    the unreliable broadcast paths. The three guards now ask
    `Peer.singleUserLimit()`, so an in-between frame routes to the reliable
    path instead.
  - **Trader stock is read by pointer.** `traderMoney` and `stockEntries`
    copied the whole ~540 B `TraderStock` (entries `[50]StockEntry`) per call,
    the first per trader per replicate pass.

### Fixed

- Review follow-ups (round 3).
  - **`[stream] pos_heartbeat_period_ticks`.** The PosAndRot heartbeat for an
    entity with no dirty motion bit was a module constant paired with the
    tunable `motion_replicate_period_ticks`. It is now an operator knob
    (default 5, clamped to >= 1) threaded through
    `interest.needsPosSend`.
  - **Workstation fuel fails closed when a FuelValue resolver is wired.**
    `handleFuel` consumed a fuel item and, when the resolver answered 0 (item
    has no `FuelValue`), added the offline flat 10 s fallback, inventing burn
    time from nothing. A wired resolver answering 0 now stops the burn and
    leaves the item in the slot; the 10 s fallback survives only for the
    no-resolver offline path.
  - **Plugin reload holds the boot declaration rule (F8).** `loadResolved`
    requires `_zdtd_requires` from a manifest-backed module, but `reload`
    loaded without that flag, so a module swapped on disk to drop its
    declaration loaded on HMR and was refused on the next restart. The reload
    path now sets the same flag.
  - **A failed manifest re-read no longer rewrites plugin state (F9).**
    `reconcileClaims` released the module's point claims and zeroed its
    queued-verb deny mask *before* `bindManifest`, so an unreadable or invalid
    manifest silently dropped exclusivity and lifted the module's own deny
    list. The manifest is read first and state changes only on success; a
    failure logs and keeps the previous claims and mask.
  - **`spawn`/`despawn` deny covers the bot family (F10).** `pluginVerbDenied`
    matched only the first token, so `deny = "spawn"` did not stop `bot spawn`
    (which creates an entity) and `deny = "despawn"` did not stop `bot
    remove`. The bot sub-verbs now fold into the tested mask; the other
    sub-verbs (move/look/shoot/count) stay behind the `bot` verb.

### Fixed

- Config surfaces and review follow-ups (round 2 of the 2026-09-12 batch).
  - **`[sim] spawn_starter_kit`.** The fresh-player kit was hardcoded in
    `World.spawnPlayer` (stone axe 1, foodCanBeef 5, resourceWood 20,
    casinoCoin 50). It is now config: comma-separated `name` or `name:count`
    rows, parsed once at `Game.create` after the item catalog loads, resolved
    through items.xml. An unknown name is omitted rather than silently falling
    back to the default kit, a count above the item's Stacknumber is clamped,
    and an unset key keeps the built-in default.
  - **`[sim] demo_seed`.** `starter_zombies = false` only dropped the demo
    hostiles; Trader Jen, the minibike, the seed chest and the demo
    generator/turret still placed unconditionally, so the documented
    "stock-lazy fresh world one key away" was not true. `demo_seed = false` now
    drops the rest, and the two switches together leave a fresh world to the
    lazy stock systems (docs/DIVERGENCES.md 6.2).
  - **Chunk damage channel is skipped when the chunk has no damage plane.**
    `NetPackageChunk` always passed `dmg_at`, so `writeDamageChannel` ran
    65536 indirect `dmgAt`/`blockAt`/`wireBlockDamage` calls per chunk even
    when every cell reads 0; the null branch writes the same bytes
    (sameValue 0 per layer), so the gate is byte-identical and mirrors the
    existing `dens_at` gate.
  - **Plugin override-point claims bind to the loaded slot.** A module the
    loader skips (missing file, plugin cap) shifts every later module down,
    while the resolver's `point_claims` stays keyed by plan slot. The claim
    was installed on whichever module landed in that slot (whose
    `hook_present` may pass) or on a slot past `self.n` that was voided
    forever. `loadResolved` now maps plan slot to loaded slot.
  - **Minimap pieces are marked sent only on a real send.** `tickMapChunks`
    set `map_chunks_sent` before `trySendCompressed` and ignored the result,
    so a full window or a compression failure left a permanent hole until the
    map middle moved.
  - **`sendReliablePumped` always has a deadline.** `budget_ns` was optional
    and a null armed `reliable_send_deadline_ns = 0`, disabling the only cap
    the fragment retry checks (leaving `max_attempts`, about 200 s). No caller
    passed null; the parameter is now a plain `u64`.

### Fixed

- Fixes from the 2026-09-12 review passes (snapshots under `docs/archive/`).
  - **Chunk pacing budget charged per attempt.** `drainSpawnArea` and
    `streamChunksForClient` decremented the shared per-tick budget only after a
    chunk was delivered, and skipped to the next cell on a refused send. A peer
    with a full reliable window still paid worldgen plus encode (and the retry
    pump) for every cell, so one tick walked the whole spawn ring (288 cells) or
    view square (up to 625) and stalled the sim for seconds. The budget is now
    consumed by the attempt and the pass stops on refusal, so the rest retries
    next tick.
  - **Sign batches no longer wedge the join.** Middle
    `NetPackageSignDataResponse` batches are sent through plain `sendGame`, and
    a full window there hard-errored out of `sendSignDataBatches`, so the loop
    never reached the final batch and the client sat on "Starting Game"
    (`worldInfoCo` blocks until `isLastBatch=true`). The package is now in
    `isDroppablePackage`: a middle batch may be dropped, the final batch stays
    critical and must deliver.
  - **One critical deadline per join bundle.** `sendJoinBundle` at the
    `RequestToSpawnPlayer` and `DynamicClientArrive` fallback sites is now
    wrapped in the shared critical deadline like the `RequestToEnterGame`
    bundle, so a peer that stops ACKing no longer re-arms the full budget for
    every critical package in the bundle.
  - **Weather body count comes from the loaded table.** `NetPackageWeather` was
    pinned to 5 biome entries and padded by duplicating the last state. The
    stock client sizes its read from `biomeWeather.Count`, which is the number
    of biomes with weather groups (the loaded `biome_layers.weather_n`), so a
    modded `biomes.xml` with a different count produced a wrong-length body.
    The builder now uses that count (and names real biome ids when padding),
    keeping the 5-entry fallback only when no `biomes.xml` is loaded.
  - **Zero survival decay no longer disables the whole survival pass.**
    `tickSurvival` returned early when both `food_depletion_per_hour` and
    `water_depletion_per_hour` were 0 (as `presets/builder.toml` sets), which
    also skipped drowning, radiation, the stamina and well-fed folds and the
    buff lifecycle, including the player class buffs fired by
    `onSelfEnteredGame`. Only the two decay writes are gated now.
  - **Block meta reads fall back to the chunk raw plane.** `blockRawAt` returned
    0 when the sparse mirror missed (it evicts oldest entries), so a resend or
    TE replicate could report a bare block id for a rotated block. A miss now
    reads the resident chunk's raw plane (no `getOrCreate`, so a read cannot
    generate a chunk).
  - **Container lookup by guid decodes the position.** `getByGuid` scanned the
    ~500 B AoS; `inv_guid` is only ever `guidFromPos(pos)`, so it now decodes the
    position (`posFromGuid`, tag-checked) and reuses the key-mirror scan.
  - **Zig 0.16 conformance.** `@intFromFloat` is a deprecated alias of `@trunc`
    in 0.16; the 58 non-vendored call sites in `src/` and `mods/` now use
    `@trunc` (nested `@trunc(@ceil(x))` forms collapse to `@ceil(x)`).

### Fixed

- Container loot is now rolled when a player first opens the container, not
  when the chunk loads. Stock's `LootManager.LootContainerOpened` rolls a placed
  container on first open with the **opening player's** loot stage, sets
  `bTouched` and stamps `worldTimeTouched` (before the roll, so an empty roll
  still stops the container re-rolling until `LootRespawnDays` elapse), and
  rolls only if the container is empty; zdtd rolled at chunk/prefab scan time
  with a party-wide stage. A chest therefore held the loot (and the loot stage)
  it had when its chunk happened to load, and the opener's progression could
  never reach the entry gates. The scan now only sizes the grid from loot.xml
  (`setContainerSizeFromLoot`), and `ensureContainerLoot` on the
  `InventoryDataRequest` open path does the roll with `lootStageForPlayer`, the
  container's biome, and the TE's own loot-list name (falling back to the
  block's LootList). The `LootRespawnDays` re-roll uses the same opener stage,
  player-placed storage still never auto-rolls, and a block without a LootList
  stays empty. `worldTimeTouched` is kept per day (ZCT2 `touched_day`) rather
  than exact world time, which only coarsens the respawn interval.

### Fixed

- Loot entries gated by a `<requirement>` were rolled as if ungated. `loot.xml`
  carries 87 such rows (63 `RandomRoll`, 14 `Progression`, 5 `Biome`, 3
  `SandboxOption`, 1 `QuestTags`, 1 `CVar`), and zdtd's loader ignored the child
  element entirely, so a gated entry dropped at its base `prob` - a book entry
  with no `prob` (1.0) gated on `RandomRoll ... value="@$perkBookwormChance"`
  put a book in **every** Working Stiffs crate, where stock's gate refuses for a
  player without the perk. The parser now keeps each entry's gate (`EntryGate`)
  and the roll paths honour it: a `Biome` gate resolves against the container's
  own biome (so the wasteland-only rows roll in the wasteland and nowhere
  else), and every class whose state the roll path does not carry is omitted
  rather than faked. The rows stay in the table for the evaluator they still
  need.

### Fixed

- Armour applied to damage that stock says bypasses it. `DamageSource::
  AffectedByArmor()` (IL=5) is `damageSource == EnumDamageSource.External`, so
  the whole armour branch of `Equipment.CalcDamage` - the physical rating and
  passive 43 ElementalDamageResist alike - runs for External (0) damage only;
  an Internal (1) claim keeps its GeneralDamageResist but takes no armour.
  The C2S damage path now honours the wire `source` byte, so a starvation,
  dehydration or blood-loss report no longer gets mitigated by armour. The
  explosion blast is External (`Explosion.AttackEntites` IL_0499), so it now
  mitigates for every player victim including the blaster instead of exempting
  self-damage. The server's own drowning and radiated-biome legs model stock's
  Internal self-damage (`DamageSource(Internal, ...)`, the vehicle-inside
  hazard is the RE-recorded example), so they apply GeneralDamageResist only
  and no longer take the EDR term added earlier.

### Fixed

- Item mods now apply their stats on the server. `item_modifiers.xml` was
  parsed only for the attachment tag gates, so a modded armour piece defended
  no better than a bare one: `modArmorInsulatedLiner`/`modArmorCoolingMesh`'s
  heat/electrical `ElementalDamageResist`, `modRadiationReady`'s +50% radiation
  resist, the fittings' stamina rows and the admin shirt's `HealthMax` all did
  nothing server-side. `ModDef` now carries each modifier's
  `<passive_effect>` rows (through the shared buffs scanner, so their
  `effect_group` gates come along), the per-tick item fold adds an item's
  installed mods' rows alongside its own, and the tagged
  `ElementalDamageResist` query folds them too. A plating mod's
  `PhysicalDamageResist` joins the armour rating through the survival tick
  (`modArmorPlatingBasic` +1 / Reinforced +2); a mod on the *held* item
  contributes stats but not armour, because stock's armour rating walks the
  worn equipment slots only. Stock's server-relevant modifier rows are flat, so
  they apply without needing the mod's own quality; tiered modifier rows and the
  `params.ItemValue`-scoped gates remain recorded residuals (the client's damage
  packet already carries attacker-side numbers, so those rows stay
  client-computed by design).

### Changed

- The near-spawn demo hostiles are now configurable. A fresh zdtd world seeds
  two zombies, a sleeper and an animal next to the spawn so a lone joiner has
  something to fight and the demo turret has targets; stock instead leaves the
  world empty at join and lets the AIDirector spawn lazily near players. The
  seeds are now `[sim] starter_zombies` (default true, the existing behaviour);
  set it to `false` for stock-lazy spawning. The divergence and the switch are
  recorded in docs/DIVERGENCES.md 6.2.

### Fixed

- Elemental damage ignored armor's elemental resistance (and physical armor
  wrongly reduced it). Stock `Equipment.CalcDamage` (IL=83) splits on
  `Equipment.physicalDamageTypes` (`piercing,bashing,slashing,crushing,none,
  corrosive`): physical damage takes the armor rating, every other
  `EnumDamageTypes` member is scaled by passive 43 `ElementalDamageResist`
  queried with the **damage type tag**. Passive 43 was parsed but had no
  consumer, so a heat hit took the physical armor rating while the armor's
  `tags="heat,electrical"` rows never applied, and the server-computed
  environmental legs (drowning, radiated biome) had no elemental leg at all.
  The wire `damageType` byte now classifies physical vs elemental
  (`protocol.damageTypeIsPhysical`, `damageTypeName`), and
  `Game.elementalDamageResist` folds the victim's equipped item rows, buffs and
  perks on the damage event with the damage type as the query tag, so
  `heat,electrical` armor resists heat and electric but not cold, and the
  untagged jitter rows apply to every elemental type. Wired at the C2S player
  damage path, the explosion blast (stock Heat default), drowning (Suffocation)
  and the radiated biome (Radiation). A row whose own requirements the
  event-time context cannot answer is counted unsupported and skipped rather
  than answered from a partial context; every stock passive-43 row is
  requirement-free. Verified on stock `items.xml`: bare heat 100, Q6 helmet
  heat 87.5, cold 99.8, bashing 87.7.

- Two crash paths read the toolbelt index without the no-holding sentinel
  (`0xFFFF`, a legal state once the held slot empties): a damage packet from a
  player who had never selected a slot panicked in the armor-penetration read,
  and a harvest packet panicked in the held-tool read. Both now go through
  `Inventory.heldItem()`, which returns an empty slot for the sentinel.

- Heat-map scout parties spawned five times too often and re-armed almost
  immediately. Stock `AIDirectorChunkData.CheckToSpawn` (aidirector.md verified
  literals) resets the region with a 240 s cooldown and then rolls
  `cSpawnChance` = 20% to actually spawn: on a spawn it hard-sets 1320 s
  (`SetLongDelay`) and gives the eight neighbours 720 s
  (`StartCooldownOnNeighbors(true)`), otherwise the region keeps 240 and the
  neighbours get 180. The sim spawned on every threshold crossing and modelled
  the long delay as a `heat_feral_chance`/`heat_feral_cd_mult` 2x roll, so a
  forge could summon a screamer every couple of minutes instead of roughly once
  per 22. The roll is now a rules value (`heat_spawn_chance`, deterministic and
  seeded off the crossing ordinal) and the long/short cooldown table is four
  stock-sourced rules (`heat_cooldown_seconds` 240, `heat_long_cooldown_seconds`
  1320, `heat_neighbor_cooldown_seconds` 180,
  `heat_neighbor_long_cooldown_seconds` 720). The scout *type* was never a roll:
  it is the gamestage bracket (Scouts1/2/Feral/Radiated), as before.
  **Config break:** the zdtd-only `[rules.director] heat_feral_chance` and
  `heat_feral_cd_mult` keys are gone; a toml still setting them fails the
  unknown-key check at startup (delete the keys).

- `plugin reload` kept a stale exclusive override claim. The claim table is
  built once at boot from the discovered `manifest.toml` files, and reload only
  re-read the `.wasm`, so a module replaced on disk that dropped its `points`
  claim held that verdict hook exclusively forever (its hook was still
  exported, so nothing else noticed), while one that added a claim never got it.
  Reload now re-reads the module's manifest and reconciles its claims with the
  same rule the boot install uses: a claim whose hook the module does not export,
  or whose point another live module already holds, is refused with a log. A
  legacy `[plugin] modules` path carries no manifest and is never reconciled, so
  a `manifest.toml` sitting beside it can neither mint nor drop a claim
  (ADR 0030 §5.2.1, review F2).

- World time ran faster than stock. The server advanced one in-game hour every
  `DayNightLength*60/24` real seconds (0.4 game-minutes per second at the default
  60-minute day), while stock advances `GameStats.TimeOfDayIncPerSec` =
  `24000 / (DayNightLength * 60)` in integer arithmetic: 6 world ticks per second
  at the default, which is 0.36 game-minutes per second and makes a nominal
  "60 minute" day take 4000 real seconds. The client draws its day counter and
  sky from the world time the server sends, so every server ran about 11 percent
  ahead of what it told the client. `WorldClock` now stores the configured
  `DayNightLength` and the stock integer rate, advances by that rate, and reports
  both numbers verbatim in the GameStats blob instead of deriving them back out
  of a float scale. The same rate is what the weather scheduler divides its storm
  countdown by, so the client's storm warning now matches the sim; and
  `clearweather` pushes the next storm one real in-game day (24000 ticks) out
  rather than the three days the stale rate produced. An operator who sets
  `DayNightLength` above 400 real minutes gets the stock expression's own
  answer, 0 ticks per second, which freezes world time rather than a rate zdtd
  invented.

- World decorations grew inside POIs. `AllowDecorations` was parsed but never
  consulted, so the biome deco sampler placed trees and rocks inside every POI
  footprint, including through buildings. The sampler now gates each cell on the
  prefab footprint: within a 128-block deco chunk it tests the footprints of the
  POIs that did not set `AllowDecorations="true"` (the stock default), so an
  opted-in POI still gets its world deco while every other POI is left clean
  (V3.2.0 changelog 4.5, RFC/PRD 0007). The footprint list is built lazily per
  deco chunk from the shipped decoration list, which keeps ~1487 prefab XMLs
  from being read at boot; an entry that hits the per-chunk rect cap is counted
  instead of silently truncating. Both deco paths (join burst and streamed
  chunk) go through the one resolver, and the stale duplicate resolver in
  `server/game/join.zig` is gone.

### Added

- Operators can now refuse individual queued plugin verbs per module. The
  plugin boundary was all-or-nothing: a module either loaded with every queued
  verb or did not load, so an operator could not admit a module for one
  behavior and refuse another. A module may declare its own limits with
  `manifest.toml deny = "say,damage"` (unknown verbs fail the manifest), and
  `zdtd.toml [plugin] deny` / `allow` take `module=verb,verb` lists applied
  over that declaration, right-biased: operator denies add and operator allows
  clear, so the operator can both tighten and relax a module's own rule. The
  check runs at the `zdtd.queue` boundary before the ECS command buffer and the
  host `bot` family, so a refused verb cannot spawn an entity, broadcast chat
  or reach the bot manager; drops are counted in the `plugin_verbs_denied` APM
  counter and logged rate-limited, and the running policy is logged once per
  module at boot. A bad config entry or unknown verb fails startup rather than
  silently enforcing a different policy than the file says. `plugin reload`
  re-reads the module declaration and keeps the operator's masks (ADR 0039,
  composability review F4).

- Plugins can declare the contract version they were built against. Name-set
  linking (`_zdtd_requires`) cannot see a semantic change between two contract
  versions that still share the hook vocabulary, so a guest may now export
  `_zdtd_api() -> i32`; the host reads it once at load and refuses a version
  newer than its own (`api.plugin_api_version`) with a log naming both, accepts
  an older one, and keeps the permissive path when the export is absent (the C
  fixtures and any pre-versioning module). Every Zig guest built on
  `mods/plugin_common.zig` exports it. The host test "shipped core plugins
  declare the host contract version" loads the shipped set and asserts the
  guest and host constants match, so the two cannot drift silently. That test
  also showed the host's 8-slot plugin table was smaller than the shipped set
  (14 modules), so a full `[plugin] modules` list lost modules at the cap; the
  ceiling is now 32 and the test fails if the shipped set stops fitting.

- Plugin effects that cannot be reverted are now classified and reported. The
  Cordis paper's revertible effects require every effect to carry an inverse,
  and the runtime cannot verify that witness, so the queued verbs are now
  classified in one exhaustive table (`ecs/command.zig` `inverseOfOp`):
  `spawn_zombie` and `glide` are reverted on withdrawal, while `damage`, `say`
  and `despawn` are already in the world or on the wire and are counted per
  plugin source instead of being forgotten. `plugin_effects_not_reverted` in
  the APM dump reports what a withdrawn module left behind. Adding a queued
  verb without classifying it is now a compile error.

### Fixed

- Server-to-client datagrams were capped below stock's MTU. The game's
  LiteNetLib pins `MaxPacketSize` = 1432 with `PossibleMtu` = [1024, 1164,
  1392, 1404, 1424, 1432], but zdtd carried 1327, a value matching no stock
  entry, so the negotiated peer MTU was clamped below the client's final probe
  and every large body (block id mapping, chunk payloads) fragmented into more
  parts than a stock server would send. The cap is now 1432, the per-peer part,
  pending and hold buffers that derive from it grew with it (about 21 KiB per
  peer), and a 1500-byte probe is still clamped. Discovery is unchanged: probes
  are echoed at their own size, so the client's list walk still completes and
  its last probe is the negotiated size.

- Movement-gated perks never applied. `EntityHasMovementTag` was not
  implemented, so every row behind it failed closed: `perkHardTarget`'s
  `GeneralDamageResist` (its only gate is `tags="walking,running"`) folded
  nothing, and the running-tagged stamina rows were unreachable. The client's
  `NetPackageEntitySpeeds` movement state (which the game itself derives from
  the reported speeds, `EntityAlive::SetMovementState`) now latches onto the
  client as idle/walking/running, the survival tick feeds it to the requirement
  context, and `EntityHasMovementTag` evaluates any-of / `has_all_tags` /
  inverted against it. The tag lapses with the same stale timer as the sprint
  report, so a silent client stops claiming to be moving rather than holding a
  walking/running gate open. That three-tag set is the whole vocabulary stock
  ships in those rows (idle 3, running 24, walking+running 1); a modlet asking
  for swimming, jumping or falling asks for a state the server does not model
  for a remote body and still fails closed.

- An exclusive plugin override point stayed routed to a claimant that had
  stopped providing. `damage.player_scale`, `craft.request`, `loot.roll`,
  `trade.price` and `quest.payout` sent every call to the slot named in the
  claim table; when that module trapped or ran out of fuel the call returned
  "keep" for the point, so a user-tier gate claimant that crashed silently
  lifted the core restriction it had overridden and no other provider was
  consulted. The dispatch now resolves the claim against the claimant's
  liveness and its export of the point's hook, then falls through to the
  ordinary composition loop (Cordis paper 5.1.2: a binding is available only
  while the fiber that installed it is active). The claim table itself is
  unchanged, so reloading the module re-arms its claim with no bookkeeping.

- Equipped armor and clothing granted none of their stats. `items.xml` carries
  the same `<passive_effect>` rows buffs do (3030 rows across 272 items), but
  the loader kept only the PhysicalDamageResist/ElementalDamageResist quality
  curves, so an athletic outfit's `HealthMax 2..20`, ranger boots'
  `StaminaMax 10..60` and the enforcer outfit's `GeneralDamageResist` never
  applied. The loader now parses every row with its `effect_group` and row
  gates (shared scanner with `buffs.xml`), resolves the list through `Extends`
  like the other item properties, and the survival tick folds the equipped
  items and the holding item into the same buff/perk VM at each item's own
  quality tier, which is stock's `EffectManager.GetValue` layers 7 and 8.
  `IsEquipped` (IL=97) evaluates against that item context, so the admin
  clothing rows resolve too. Item rows the tick folds include gated ones: the
  enforcer outfit's row is gated `ProgressionLevel perkEnforcerApparel
  Equals 1` and only applies once the perk is owned. PhysicalDamageResist and
  ElementalDamageResist stay owned by the item quality-curve path
  (`armorMitigation`), so equipping a piece does not count its armour twice.

- Worn armor did nothing against zombie melee. The deferred AI damage choke
  (`applyDeferredDamage`) applied the difficulty scale and the plugin verdict
  but neither resist leg, so a player in a full set took exactly the naked
  damage from a zombie while the same armor did reduce PvP hits, explosions and
  falling blocks. The choke now applies the physical armor rating as stock
  `Equipment::CalcDamage` does (`GetTotalPhysicalArmorRating` over the equipped
  pieces plus the buff-side `PhysicalDamageResist`).
- `GeneralDamageResist` (passive 40) folded into the passive-effects VM but
  nothing read it, so every perk and buff that grants it (`perkPainTolerance`,
  `perkHardTarget`, `buffPerkCharismaticNature`, the armor-set rows) was inert.
  Stock's `EntityAlive::DamageEntity` reads it with an empty tag set and applies
  `min(1, value)` to every damage type, so the survival tick now caches the
  buff+perk total per entity and every player-damage choke consumes it: AI
  melee, client-claimed damage, explosions, falling blocks and the
  environmental damage-over-time legs (drowning, radiation, starvation).
  Negative totals are kept, since stock does not clamp at 0 and a vulnerability
  row is meant to raise the damage taken.

- Burning and shock damage-over-time never applied to players.
  `buffs.xml`'s player half of a damage pair is gated
  `<requirement name="EntityTagCompare" tags="player"/>` (and the non-player
  half by the `!` twin), which the requirement evaluator did not implement, so
  every one of those rows failed closed and `buffBurningFlamingArrow`,
  `buffBurningMolotov`, `buffHazardBurningElement`, `buffRadiationPool` and the
  `buffTwitch*` buffs dealt no health damage at all. `EntityTagCompare` now
  reads the entity's own class `Tags` (`entityclasses.xml`, resolved through
  `extends` the way `EntityClass::CopyFrom` does), fed per tick from the slot's
  class, with `has_all_tags` all-of support and the stock inversion. A foreign
  target (`other` / `instigator`) still refuses rather than reading self.
- `StatComparePercCurrentToMax` divided by `Stat::ModifiedMax` instead of
  `Stat::Max` (`m_baseMax`), so a perk or buff that raised the max moved every
  hunger, thirst and stage threshold with it. The ctx now carries both the base
  and the modified max, and the modifier-aware gates that were missing landed
  with it: `StatComparePercCurrentToModMax` (which gates `buffNearDeathRegen`,
  so the near-death regeneration floor now works), `StatCompareMax`,
  `StatCompareModMax` and `StatComparePercModMaxToMax` (the health-stage ladder).
  `IsNight` reads the sim clock so night-gated rows resolve instead of being
  refused. Measured on the stock 3.2.0 files, `buffs.xml`'s gated tracked
  passive rows move from 31 resolve / 12 refuse to 43 / 0.

- Powered-block prefab markers were turned into loot containers. The chunk TE
  scan classified `TileEntityType.Powered` (0x0F) alongside the storage types,
  so a powered marker got an invented 8-slot grid and the storage TE sender
  would push a composite-storage body for it. The client builds its tile
  entity from the block, so those bytes would reach `TileEntityPowered::read`.
  Powered blocks replicate through the power-registry path instead.
- Opening a vending machine sent the wrong lock-context shape. Stock has two
  trader lock contexts and they do not share a layout:
  `EntityTraderLockContext` carries `Command` + a `hasTraderData` bool before
  the `TraderData`, while `VendingMachineLockContext` carries the `TraderData`
  directly. zdtd emitted the entity shape for both, so a vending machine
  handed the client two extra bytes that it read as the first half of
  `TraderID`, desyncing the rest of the body. The scenario test asserted those
  two fields, which is what kept the wrong shape in place.
- `NetPackageEntityAnimationData` is now parsed rather than relayed blind, so
  no relay forwards a raw client body any more. Its parameter entries are a
  hash, a type byte and a type-sized value; an unrecognised type is rejected,
  as stock does. A malformed or spoofed body is now counted and dropped
  instead of being fanned out to the other players.
- `NetPackagePlayerEquipment` was parsed with the wrong body shape. It carries
  `Equipment::Write` (version byte, then one `ItemValue` per slot where a null
  slot is a bare `0`), but zdtd read a presence bool before each slot, which is
  the shape of the *other* equipment encoding used inside
  `NetPackagePlayerInventory`. The spurious bool consumed the next slot's
  version byte, so an armor swap desynced the rest of the body: at best the
  equipment applied wrong, at worst the whole package failed to parse. The
  version-gated cosmetic tail is now gated too, and the relay trims to the
  parsed length instead of forwarding the raw body.
- Three more cosmetic relays forwarded the raw client body.
  `NetPackageEntityRagdoll`, `NetPackageSoundAtPosition` and
  `NetPackageParticleEffect` all have variable-length bodies (flag-gated tails
  and client-sized strings), so `body.len` is not the stock length and
  anything a peer appended was fanned out to every other player. Each parser
  now reports where the stock body ends and the relay trims to it, matching
  the fix already applied to the movement and laser-sight relays.
- A player never saw their own chat. The server excluded the sender from both
  the global broadcast and the targeted recipient loop, but stock excludes
  them from neither: the broadcast passes `allBut = -1`, the targeted loop
  sends to every listed `ClientInfo`, and the client does not add its own line
  locally. It even puts its own entity id first in the party recipient list,
  expecting the echo. zdtd's own `NetPackageSimpleChat` path already
  broadcast to everyone, so the two disagreed.
- Other players heard nothing. `NetPackageAudio` was dropped as a
  "client-local sound cue", but a client sends it to the server, and stock's
  dedicated server relays it to every in-range player. Doors, storage,
  switches and locks all raise it. The server now re-encodes and relays it
  within interest range, excluding the sender, who already played it locally.
  `signalOnly` bodies are the AI-stimulus form and stay unrelayed, matching
  stock.
- Treasure quests could never be completed. `NetPackageQuestTreasurePoint` was
  accepted and dropped as a "redundant progress echo", but it is a request:
  `ObjectiveTreasureChest::GetPosition` asks the server whenever the quest
  carries no `TreasurePoint`/`TreasureOffset` position data, and zdtd fills
  neither, so a stock client always asks. Stock's server resolves a dig site
  and sends the package back to the asking player. With no answer the quest
  showed no dig marker and the objective could not finish. The server now
  replies with a site anchored on the quest's POI (or the player), at the
  terrain surface. The two client-report actions stay accept-and-drop.
- `NetPackageWaterSet` was dropped as unhandled. It is the client-originated
  water edit (filling or emptying a jar, the water-cube tool), and stock's
  server relays it to every other peer and then applies it. zdtd ignored it,
  so the change lived only on the acting client and vanished on relog. Now
  parsed and validated (sender ownership, edit reach, land claims), applied
  through the normal block path so it persists, and relayed to the other
  peers. The prior audit folded this in with the mass-flow sim packages and
  scored it N/A; only `NetPackageWaterSimChunkUpdate` is genuinely N/A.
- Water leveling never reached joined clients. A pour (digging beside a lake,
  placing water) wrote through the chunk store and marked the chunk dirty, but
  that flag only drives persistence, not replication: the fill was saved and
  never sent, so a player kept seeing the dry basin until the chunk happened
  to be re-streamed. Each filled cell now goes out as a `NetPackageSetBlock`,
  which the client turns back into water through its own `Chunk::SetBlockRaw`
  path, so no native water-sim modelling is needed.
- Scout wave size ignored `spawning.xml`. `TotalPerWave` was parsed onto the
  spawner and dropped, so the daytime drip spawned a hardcoded 1 and the
  chunk-heat wave used a zdtd rule, while stock sizes each tier from the
  spawner (Scouts1 1, Scouts2 2, ScoutsFeral and ScoutsRadiated "1,2"). The
  director now reads the tier's own value and falls back to the previous
  numbers when no table is loaded. `TotalPerWave` is a min/max pair and stock
  rolls `RandomRange(min, max + 1)` per wave, so the loader keeps both ends
  and the director rolls in the range rather than pinning the low bound.

- `[rules.worldgen] height_amp` did nothing. It was stored on the generator
  and never read: `columnTarget` used inline amplitudes, so an operator could
  set the documented knob and the terrain would not move. The three shaping
  octaves now take their amplitude as shares of it, written so the default
  (24) reproduces the previous numbers exactly. The old params test moved
  `base_height` at the same time, which is why it never caught this.
- Turret magazines ignored `BurstRoundCount`. The value was parsed off
  blocks.xml and dropped, so every placed turret used the 200-round component
  fallback instead of the block's own count (rule 15: stock data comes from
  the assets, never a hardcoded sim default).
- Perk and attribute purchases were parsed from the wrong offset.
  `NetPackageEntitySetSkillLevelServer` derives from
  `...SetSkillLevelClient` and overrides neither `read` nor `write`, so it
  inherits that body verbatim: `entityId` i32 first, then the skill name and
  level. zdtd started at the name, so every purchase from the skill window
  read a garbled skill and silently failed. The id is now consumed and
  ownership-checked.
- `NetPackagePlayerLaserSight` reads its `Vector3` only when the active flag
  is set; zdtd read it unconditionally, so every laser-off packet failed as
  malformed and the off transition never reached other players.
- `NetPackageParticleEffect` skipped the two fields that end
  `ParticleEffect::Write` (`parentEntityId` i32, `attachment` u8), taking
  `parentEntityId` as the causing entity and deriving both trailing bools from
  the wrong bytes. Combat and block-hit effects relayed to the wrong peers.
- A player name longer than 32 bytes aborted the whole login parse, and the
  compatibility-version check and player-slot cap both run only on a
  successful parse, so such a client joined ungated. The name field now keeps
  what fits and consumes the rest, leaving the reader aligned.
- Movement relays forwarded the raw C2S body.
  `NetPackageEntityAliveFlags` and `NetPackageEntitySpeeds` are re-encoded
  from their parsed fields, and `NetPackageEntityTeleport` is trimmed to the
  parsed length, so trailing bytes a peer appends are no longer fanned out to
  everyone.
- Stealth crouch and light rode one `NetPackageEntityStealth`. Stock's three
  `Setup` overloads are mutually exclusive: the crouch form sets `data` to
  exactly 0 or 1, while the light form packs
  `(byte)lightLevel | ((noise & 127) << 8)` plus bit 15 for alert. zdtd ORed
  the crouch flag into the light form, and the client reads the light level as
  `(byte)data`, so a crouching player reported light+1 and even light values
  could not be expressed. The two forms now ship as separate packages.
- `readTraderDataBody` parsed the `TierItemGroups` block as a name string plus
  a u8 count plus u16 ids. Stock reads each group through
  `GameUtils::ReadItemStack` (u16 count + `ItemStack` per entry). Stock
  traders.xml ships no `<tier_items>`, so a stock client always sends 0 groups
  and the wrong shape was unreachable, but a non-zero count would have
  desynced the trailing `AvailableMoney`.
- `TileEntityLight` network body was 9 bytes short: `LightState` u8, `Rate`
  f32 and `Delay` f32 were missing. Stock gates those three on payload
  version, but the network path pins the version to 18, so the client always
  reads all nine fields. Nothing brackets this body with a size marker and the
  reader holds only the package payload, so the client was filling the three
  fields from stale bytes in the pooled buffer. The prefab `.tts` parser read
  the fields and discarded them; they now reach the wire. The same body also
  carried a placeholder `teBlockId` of 0, which makes the client drop the
  package outright ("Block type changed"); it now sends the real world block.
- Quest objective wire shape for `StayWithin` and `Time`. Stock has exactly
  four `BaseObjective` subclasses that override `Write`; the mapping covered
  only two, so `StayWithin` emitted the 2-byte base pair where the client reads
  nothing, and `Time` emitted that pair instead of its `UInt16`. Either
  mismatch fails the client's `ValidateSizeMarker` and clears the entire
  objective list for that quest, so a journal containing stock
  `intro_buried_supplies` lost its objectives.
- Trader stock quality. Stock parses a `<item>` ref with no `quality`
  attribute as min = max = -1 and `TraderInfo::SpawnItem` substitutes 1..6 for
  it, then clamps to `TraderMaxTier` (static, default 6) and drops the item
  when the clamped max falls below the min. zdtd defaulted those refs to
  quality 1 and only rolled when the XML carried an explicit range, so 653 of
  the ~780 stock refs sold at quality 1: every trader window was tier-1 gear.
  Whether an item can carry quality at all now comes from
  `ItemClass.HasQuality` (any owner-tiered `effect_group` in items.xml,
  inherited through `Extends`), so stackables still have none. The ceiling and
  the fallback range are `[rules.trader]` (`max_tier`,
  `default_quality_min` / `default_quality_max`).

### Removed

- `[rules.c2s] quest_summon_per_request`. It was documented as bounding a
  hostile multi-spawn push, but nothing read it: the handler was corrected
  earlier to spawn exactly once, matching stock `ProcessPackage`, so the
  count is not client-chosen and there is nothing to cap.

### Changed

- Backpack scrap: stock `GetScrapableRecipe` (RE crafting-recipes.md IL=77)
  resolves forge scrap by MadeOfMaterial forge_category, NoScrapping reject,
  and the first `wildcard_forge_category` recipe whose output material matches
  and whose output weight is `<= itemWeight * count`. InvTx `Op.scrap = 12`
  (bag slot + qty) consumes the slot and deposits `recipe.count` of that scrap
  output. General craft still rejects scrap stubs.
- Death/kill counters scored WORKS: `killedZombies` / `killedPlayers` already
  ride `NetPackagePlayerStats`. The five client-accrued accumulator fields stay
  0 by design (DIVERGENCES §2), not as an open gap.
- Forge melt: items.xml `Weight` / `MeltTimePerUnit` / `Material` (Extends),
  materials.xml `forge_category`, blocks.xml `Modules`/`InputMaterials`, and a
  bounded `HandleMaterialInput` tick (scrap → unit_* via Caps resolvers).
  Tools PassiveEffects 95 (`CraftingSmeltTime`, e.g. toolBellows) scale melt
  duration.
- Entityclasses `AITask` lists now select which native EAI tasks a class
  actually runs. Pipe lists on `zombieTemplateMale` (and class overrides such
  as `zombieRancher` dropping Territorial) and numbered `AITask-N` on animals
  both resolve through Extends. Classes with no list keep the shared table.
  Leap and RangedAttackTarget stay unmapped (no native task).
- Magazines raise crafting skills on eat (`AddProgressionLevel`) and grant
  the stock `GiveExp` (50, `_xpOther`) through the server ledger. Almanacs
  and journals with `SetProgressionLevel` `level="-1"` set each named
  perk/attribute/crafting_skill to catalog MaxLevel (RE minevents.md
  IL=104). Gated recipes unlock when the skill meets the `unlock_entry`
  tier; the join PDF and server craft path honour that list.
  `always_unlocked` recipes stay available from the start.
- Harvest, quest, craft, and magazine XP now push
  `NetPackageEntityAddExpClient` as `_xpOther` so the owning client shows
  the icon. Kill XP still uses the typed Kill packet.
- Auth-state timeout (`MaxDurationInAuthState` 10 s) and player/party
  gamestage spawn lookups were already in code; the GAP rows that still
  called them waived are now scored WORKS. Blood-moon `SetScaling`
  (`FastLerp(1, 2.5, (scaling-1)/3)`) is log-only (`GetStage` uses the
  unscaled argument).
- `NetPackageTraderData` is no longer emitted ToClient. Stock drops an
  inbound copy before `Read`; trader stock already rides spawn ECD and
  `NetPackageLockResponse`. Quest requirement rows and trader dialog
  chrome are scored WORKS against stock (zero requirement XML; dialog
  is client-local).
- Workstation TE queues honour recipes.xml: magazine `unlock_entry`
  gates, plus per-craft count, duration, and `craft_exp_gain` from the
  catalog rather than the client blob. Material-based recipes stay
  rejected (no scrap yield table).
- Workstation `RepairItem` / `AmountToRepair` is scored WORKS against
  stock: `TileEntityWorkstation` never reads those fields; repair queues
  are client UI only. zdtd already emits `has_repair=false` and skips the
  optional payload on read.

## [0.4.0] - 2026-09-06

### Fixed

- Damaging and explosive hits are now fanned out to the victim's tracking
  clients. Stock plays the hit reaction off `EntityAlive.ProcessDamageResponse`
  (IL=86), which ships the applied damage via `SendPacketToTrackedPlayers`;
  zdtd computed the damage but only the killer-route damage body reached a
  client, so remote observers saw no hit reaction and never read the
  dismember/cripple/crawler bits. Blast victims get the same fan-out
  (stock `Explosion.AttackEntites`, source External, Heat damage type).
- `NetPackageQuestEntitySpawn` now summons one entity per packet, for the
  sender only. The body's third field is `entityIDQuestHolder` (RE
  `protocol-packages.md` 6.17, read IL_0002-001F), but it was read as a spawn
  count, so a single packet summoned that many zombies (bounded only by
  `quest_summon_per_request`) with the client choosing the number. Stock
  `ProcessPackage` (IL=37) calls `SpawnQuestEntity` exactly once. The holder is
  now also checked against the sender's own entity.
- Wrench pickup now removes the block on the server. `NetPackagePickupBlock`
  broadcast the replacement `NetPackageSetBlock` but never wrote it, so the
  block disappeared for clients while still standing in the world: it came
  back on the next chunk load and kept blocking placement and pathing in the
  meantime. Stock replicates the pickup rather than simulating it client-side
  (RE `blocks.md` "Server authority").
- Multi-stage blocks now downgrade instead of clearing to air on destroy.
  Stock `DamageBlock` downgrades via `Stage2Health` (`Block.OnBlockDamaged`
  into base `OnBlockDestroyedBy` returning the downgrade); zdtd always
  cleared to air, visibly wrong on the small multi-stage set. `DowngradeBlock`
  resolves from `blocks.xml` through Extends on all four destroy paths
  (player dig, zombie chew, explosion, Demolition tick) with a SetBlock echo,
  and the wire damage display caps at the Stage2Health threshold.
- Dismember chance now starts from the region multiplier, not 1.0. Stock
  `GetDismemberChance` (IL=128) multiplies the weapon/armor/attacker/perk
  chain by the `DismemberMultiplierHead/Arms/Legs` of the hit region; zdtd
  started every region at full chance, so headshots on feral/radiated
  zombies (stock 0.7/0.4 multipliers) dismembered far too often. The three
  multipliers plus `LegCrippleScale`/`LegCrawlerThreshold` now load from
  `entityclasses.xml` (stock cctor/Init defaults when unset), the attacker
  `DismemberSelfChance-143` perks and buffs fold in, and the killing blow
  prescales by the victim's remaining-health fraction before the roll. Rolled
  outcomes ride the S2C damage body so clients see them.
- Trap and turret kill XP now scales by the owner's `ElectricalTrapXP` perk.
  Stock `EntityAlive.AwardKillXPServer` multiplies `KillXPScale` by the
  killer's perk value on trap kills (research `docs/changelog-3.2.0.md` §4.3);
  zdtd passed the wire scale through but never applied the perk.
- Trader buy/sell prices now fold in the buyer's `BarteringBuying` and the
  seller's `BarteringSelling` perk scales (stock `GetBuyPrice`/`GetSellPrice`),
  ceiled like stock. The verdict hook still sees the pre-barter price.
- Land-claim repair requests now run the repair server-side instead of being
  rebroadcast. Stock `ProcessPackage` (IL=33) resolves the TE at the block
  position and runs `RepairAll` (healing damaged blocks to full HP across the
  claim square, replicated per block through SetBlock), emitting nothing; zdtd
  fanned the request to every peer. Requests outside any claim, or for
  someone else's claim, are dropped; the requester gets the stock
  `Setup(blockPos, false)` completion. Conscious simplification, recorded in
  DIVERGENCES: the repair is free (stock consumes `RepairItems` from TE
  storage, which zdtd has no inventory for) and air stays air.
- The join handshake now sends the empty `AuthConfirmation` the client
  echoes. Stock `AuthFinalizer.Authorize` (IL=10) sends it as the last
  authorizer step and the client answers back; without the send the
  round-trip never started.

### Added

- The killer's client is now told about its kill so kill challenges advance.
  Stock `GameManager.AwardKill` (IL=27) ships
  `NetPackageEntityAwardKillServer` to a remote killer and the client fires
  its local `EntityKill` event, which `ChallengeObjectiveKill`/`KillByTag`
  subscribe to. Server-side credit (quests, XP, score) already ran on the
  death path; this send only feeds the client-tracked challenges. The inbound
  direction stays accept-and-drop (DIVERGENCES 1.12).
- Zombie attack targets are now published to tracking clients. Stock fans
  `NetPackageSetAttackTarget` out of every server-side attack-target change
  (`EntityAlive.SetAttackTarget`, plus the expiry send in `OnUpdateLive`);
  zdtd picked targets in the sim but never published them, so every zombie
  read as untargeted on remote clients (drone beam, DynamicMusic threat).
  A per-tick diff against the last published value produces the same traffic
  without mirroring stock's call sites.
- Player laser sights now relay to the other clients. Stock re-sends the
  `NetPackagePlayerLaserSight` body to every client except the sender's own
  entity (IL=70); zdtd dropped it, so a mate's laser dot never showed. Relay
  is gated on the sender speaking for its own entity plus the cosmetic-relay
  rate cap.
- Owned vehicles now reach the owner's map as a waypoint list. Stock
  `VehicleManager.UpdateVehicleWaypointsForPlayer` ships the owner's parked
  vehicles as `NetPackageEntityWaypointList` (listType Vehicle); zdtd kept
  the data but never sent it.
- Three client-sent reports that had no C2S arm are now validated and
  dropped instead of falling through: `NetPackageEntityStatChanged`
  (accepting the number would let a peer set its own health; the server owns
  stats and replicates them out), `NetPackageGameEventResponse` (zdtd keeps
  no `GameEventActionSequence` state for a reported hit to bump), and
  `NetPackageSharedPartyKill` (zdtd computes the party split server-side, so
  accepting the forward would award the kill twice).
- Deaths under an XP-penalty `DeathPenalty` now send the deficit sequence
  action. Stock `EntityPlayer.HandleClientDeath` (IL=71) runs the matching
  `game_on_death_*` sequence and the `AddXPDeficit` action reaches the dead
  player's client as a `ClientSequenceAction` response; zdtd ran the server
  side but never sent it.

### Changed

- `NetPackageWorldFolder` rides channel 1. The RE names five channel-1
  overrides (`network.md`, `NetPackageWorldFolder` read IL_0000
  `ldc.i4.1`); the table listed four, so the first WorldFolder send would
  have gone out on the wrong stream. The compressed-package set is now
  pinned the same way: exactly the five stock `get_Compress` overrides zdtd
  emits, with the three never-sent names asserted out.
- Trader demand drift is gone. zdtd decayed a per-entry demand scalar toward
  1.0 on every restock tick; stock has no such model (per-entry markup is
  vending-UI state, `GetBuyPrice` has no demand term), so prices moved in a
  way no stock client or server reproduces. Markup docs corrected with it.

## [0.3.0] - 2026-09-06

### Removed

- C2S game payloads that fail the channel-envelope parse are now dropped, with
  no second attempt. `dispatchGamePayload` used to retry an unparseable payload
  by prepending a zero channel byte and re-parsing; whatever packages that
  produced went to `handlePackage` as if the peer had sent them. Every stock
  game envelope carries the channel byte (GAP_ANALYSIS "Game envelope channel
  byte"), so the retry only ever accepted payloads stock rejects, and a 10-byte
  body reaches it. It was a framing-bug workaround from early RE, untested and
  unreferenced, widening the C2S trust boundary on unauthenticated input.

### Changed

- Wire pin retargeted to stock **V3.2.0 b10** (`src/version.zig`,
  `VersionInfo` in `src/wire/packages.zig`): `Constants.cVersionBuild` 9 → 10,
  so the GSI `ServerVersion` four-field string is now `V.3.20.10` and the
  `PackageIds` body carries build 10. The login gate compares
  `VersionInformation.LongStringNoBuild` (`V 3.2.0`), which the build number
  does not enter, so a b9 client still joins. b10 changed no wire surface:
  research `docs/changelog-3.2.0.md` §8 records an unchanged census (4426
  types / 44277 methods / 195 NetPackage / `gmUpdate` IL=631 /
  `WorldState.SaveLoad` IL=926), byte-identical XML pins, and a managed-code
  delta confined to the client-side EOS Title Storage cancel path
  (`Platform.EOS.RemoteFileStorage`), which the dedicated server never runs.

### Added

- Stock client wire V3.2.0 b9 (Mono, EAC off): packed `NetPackageDamageEntity`
  flags + `KillXPScale` (breaking), POI metadata packages
  (`NetPackagePOIMetadataRequest`/`Response` replace `NetPackagePOIAround`),
  `NetPackageConfirmSpawnEntity`, `EntityCreationData` requestedBy/requestKey
  tail, `ItemValue.Activated` → Flags bitfield (wire-compatible). Grounded in
  7dtd-engine-research `docs/changelog-3.2.0.md`; the 3.2.0 login gate is
  live-verified. Caveat: the bundled AssignIds dump is still 3.1.0-era
  (refresh item in GAP_ANALYSIS §1a).
- Malleable world geometry (ADR 0036): `[rules.geometry]` elevation projection
  (`sea_level`/`height_scale`/`height_offset`/`height_ceiling`; identity at
  stock defaults) and `[wire] profile` column-height dialects: a world can
  ship compressed mountains, a sea-level model, or a custom ceiling with a
  stock client; non-stock dialects need a paired client mod. Proc shaping
  params lifted to `[rules.worldgen]` (byte-identical defaults; fail-closed
  validate).
- Infinite procedural world: `--mode infinite` (or `mods/infinite_world`, a
  config-only mod via the new `[mods] enabled` mechanism) streams chunks on
  first touch as players explore; deterministic per seed; proc deco resolves
  from the W3 biome field; clean chunks never persist (save dir grows with
  edits, not visits).
- Server-authoritative progression: perk/attribute spend
  (`NetPackageEntitySetSkillLevelServer` C2S validated against the catalog +
  the `on_perk_spend` Wasm verdict), per-player levels + skill points persist
  (players.zsv ZPV11 skill tail), `NetPackagePlayerStats` snapshots to every
  peer (join + level-up), armor `PhysicalDamageResist`/`ElementalDamageResist`
  quality curves fold through the passive-effects VM, difficulty presets
  decode from the embedded stock `sandbox_presets.xml`.
- New serverconfig properties: `DeathPenalty`, `LandClaimCount`/
  `LandClaimDeadZone`/`LandClaimOfflineDelay`/`LandClaimDecayMode`,
  `ServerReservedSlots(+Permission)`/`ServerAdminSlots(+Permission)`, and the
  GSI browser fields (`ServerDescription`/`ServerWebsiteURL`/`Region`/
  `Language`/`ServerMatchmakingGroup`); all documented in GAME_OPTIONS.md and
  shipped in serverconfig.example.xml.
- Pure XML/assetbundle modlet support (docs/prd/0003-modlets.md,
  docs/rfc/0003-modlets-plan.md): stock `Mods/` scan with `ModInfo.xml` V2, the full
  `XmlPatcher` op catalog (append/prepend/insert/remove/set/csv/include,
  `@modfolder:` tokens; `conditional` fails closed until RE pins the grammar),
  patched catalogs feeding every XML loader (`--mods-dir` override), and the
  stock join-phase config sync (`NetPackageConfigFile`, 42 S2C rows,
  Deflate-cached patched XML, `archetypes` name-only). DLL mods are never
  hosted; `Bundles/` is tolerated, never read.
- WebUI: the operator dashboard gains a Guard policy panel (kicks,
  would-kicks, quarantines, quarantine rejects, load-shed drops) and the page
  header wordmark is a level-1 heading (screen-reader landmark).
- Dependency bump: zwasm 2.4.1 → 2.5.0 (build.zig.zon URL + hash,
  THIRD_PARTY.md). Picks up the upstream pre-tag cleanliness sweep (file org,
  build flags, audit fixes) and full WASI 0.3 coverage; no zdtd-facing API
  change.
- New sim tunables: `[rules.c2s]` per-request caps on untrusted C2S push
  paths (`eat_units_per_push`, `quest_summon_per_request`) and
  `[rules.ai] stealth_alert_radius` (S2C stealth alert flag radius; the
  16-tick broadcast cadence stays the RE-pinned stock value). All bind via
  `zdtd.toml`/preset packs like the rest of `[rules.*]`.
- Admin `give` resolves stock item names (e.g. `give 0 resourceWood 5`) in
  addition to numeric ids, fail-closed on unknown names; `admin help` now
  lists `loglevel`, `commandpermission`/`cp` and `plugin`.
- Parachute mod (`mods/parachute/`, ADR 0037): a fully self-contained mod
  adding a wearable parachute item (items.xml modlet patch) that deploys
  when falling fast. The plugin boundary grew sense **v4** (server-derived
  `vy` + `wearing_glider` per player), a `glide` queue verb (server-side
  vertical sink while gliding, attributed/withdrawn per plugin), and
  `[rules.glide] sink_vy_mps` / `item_tag`. Deceleration is
  server-side (C2S vertical clamp + position broadcast, no client mod
  needed); fall-damage stays client-owned (stock wire). Sense v4 is a
  breaking layout change: all shipped guests (fps_bot, mcp, core_announce)
  were rebuilt for it.
- Pointer-stable chunk store: `World.chunks` maps keys to `*Chunk` (one
  allocation per chunk, freed on eviction/deinit, residency bounded by
  `max_resident_chunks`) instead of inline `Chunk` values, so a `*Chunk`
  held across a re-entrant `getOrCreate`/`blockWorld` stays valid across map
  resizes - closing the GAP "Chunk pointer stability" hazard class (bait-soak
  segfault 5/5) at the store, with a regression test forcing 40+ resizes
  while a pointer is held. The same hazard class in the prefab TTS cache
  (`tts_cache` in `world/prefabs.zig`) was closed the same way: the map now
  holds `*TtsBlocks` (per-entry allocations, freed on deinit/setIdLookup)
  with a regression test holding a pointer across 11 cache puts.
- Join-burst pacing (GAP "Join-burst tick budget"): `sendSpawnArea` sends
  only the collision-mesh core (spawn chunk + 8 neighbours) synchronously
  and arms a per-client pending area; `drainSpawnArea` delivers the outer
  rings against a shared `chunk_adds_per_stream_tick` per tick (concurrent
  joins split it), with per-chunk ACK-yields (a bursted batch overflowed the
  reliable window; 257 drops measured without them). A sustained loadgen
  double-join cycle (62 joins) shows join_fail=0 (concurrent-client
  starvation gone) with the chunk stream bounded at 50 ms; ReleaseFast
  re-measures max tick 140 ms / p99 50 ms vs the pre-pacing 262 ms. The
  join path is instrumented with `.join` (C2S join handler) and `.join_drain`
  (paced drain pass) apm sections.
- Starter population fill (GAP "population is still thin"): the director
  spawns toward `[rules.director] initial_population_frac` (default 0.25) of
  the alive cap once at boot, batched at 4/tick, so a fresh world is
  populated near players instead of staying near-empty until the first night
  drip. Stock fills loaded regions toward their spawning.xml maxcounts as
  they load; the caps stay stock-faithful (MaxSpawnedZombies/Animals).
- Observe-mode honesty (T19): `movement_rejects` now counts ENFORCED
  rejections only (correct mode); observe stays permissive (applies the
  client position, never denies - documented) and records observed movement
  violations in the evidence ring instead, so the dashboard no longer claims
  protection observe does not provide.
- Hard-authority ceiling (T20): `evidence.decisionInputs` classifies every
  detector by decision-input authority (server_only vs client_informed), and
  `noteEvidence` fails closed - a `.hard` event from a client-informed
  detector (bounds/movement weigh client-reported values) is downgraded to
  `.strong` and counted (`hard_ceiling_downgrades`), so no client-informed
  signal can trip the kick ladder. Coverage test + scenario pin it.
- `on_evidence` plugin observer (T21): the guard streams every recorded
  evidence event to guests on both plugin hosts (detector/severity/surface
  enums, observed/bound as f32 bits); `severity` is the post-ceiling value
  and the return is discarded - read-only, never a gate. Host unit test +
  the T20 scenario cover the wiring.
- Anti-cheat suppression audit (T22): the void rescue (a player who fell out
  of the mesh - y < -1 - corrected to the surface) now resets the movement
  envelope instead of rebaselining, so the interim packets (the client still
  falling before it processes the EntityTeleport) no longer count as
  movement rejects against a legit player. Spawn/respawn/death and admin
  teleports already reset the envelope; stalls/packet loss are rate-covered
  by design. Scenario "void rescue suppresses the movement reject".
- Dry-run reviewable diff (T23): the guard records the gate-trip cause
  (detector + tick) per peer, and the new `guardreport` admin verb dumps the
  anti-cheat diff - per peer, which strong detectors are in the window,
  whether the kick ladder tripped (by which detector, at which tick), the
  kick/denial state, and the enforcement rung configuration - so an operator
  reviews exactly who WOULD be kicked before enabling a rung. Scenario
  "guardreport shows the would-kick diff".
- Inventory C2S hardening (T18 slice): the stock InventoryTransaction path
  now REJECTS a non-empty stack that does not resolve to a server catalog
  item (fail-closed, honest success bit + `c2s_rejects`) instead of silently
  applying an empty slot with a success ack, and SetAll applies atomically
  (only when every op resolves). Scenario "stock InvTx rejects unresolvable
  item stacks".
- Whitelist gate fail-open fix (admin audit): the "platform:id" composite
  key buffer was sized to `max_id` (64) while a max-length identity composite
  is up to 81 chars; the `bufPrint` overflow at the join whitelist gate used
  to `catch return true` - SKIPPING the gate on a whitelist-only server. The
  buffer now covers the composite (`max_composite_id`, derived from the wire
  lengths) and an un-keyable identity is simply not on the whitelist
  (denied), never a gate skip; the admin.xml composite keys and the
  admin-level lookup use the same capacity. Scenario "whitelist gate fails
  closed on an un-keyable identity".
- Player-console per-command permission fix (admin audit): the check was
  inverted vs stock (`req > caller` instead of stock's `req >= caller` with
  levels 0 = highest), so a level-5 admin could run owner-only commands and
  the owner was locked out of delegated commands. Now deny = `req < caller`
  (stock IsAllowed, console-commands.md IL). The player-console scenario
  covers the matrix: owner (0) allowed a req-5 command, level-5 admin denied
  a req-0 command.
- Plugin binary freshness gate (`scripts/lint-plugins.sh`, part of
  `make lint`): every committed `.wasm` is rebuilt into a scratch mirror and
  byte-compared against what is in the tree, so a plugin source edit that was
  never rebuilt fails the gate instead of shipping a stale binary.
  `scripts/build-plugins.sh --dest DIR` produces that mirror without touching
  the working tree. `mods/BUILDING.md` said "commit both" but nothing enforced
  it.
- `lint-architecture.sh` now checks that every `@import` in a package barrel
  also appears in its `test {}` block, not just that the file is referenced -
  the exact thing the check's own comment claimed to enforce, since importing
  a module is not enough to pull its tests into `zig build test`.
- `zig build test` now also builds `mods/plugin_common.zig` as its own
  host-target test binary. The shared guest helper (`Buf`, `Config`) backs the
  12 core plugins and the Zig addons but is outside the server's import graph,
  so its two tests had never run. Its `Config` tests now also parse the real shipped
  `plugins/core_*/config.toml` files rather than a synthetic string, which is
  what catches a quote or trailing-comment regression reaching a guest.
- `make check` no longer fails on a transient registry blip: `lint-webui.sh`
  ran `bun add` against the network on every invocation, so a momentary
  DNS/registry failure failed the gate (surfacing as `make check` exit 2, since
  a failing sub-make reports 2). It now retries once and then falls back to the
  already-populated pinned cache; a genuinely cold cache still fails loudly.
- `mods/parachute/preset.toml` is now bound against the rules schema in the
  suite. It was the one shipped preset pack no test parsed (the resolver test
  pins only its path), so a stale `[rules.glide]` key would have surfaced at
  runtime load rather than in `zig build test`, unlike every `presets/*.toml`
  pack and the other two mod presets.

### Fixed

- A legacy ZCT1 container save with more than one record lost every container
  after the first. ZCT2 appends `touched_day` plus the grid size after a
  record's slots; the loader decided whether to read that tail from the bytes
  remaining rather than from the file's magic, so in a multi-record ZCT1 file
  it consumed the next record's position as the previous one's `touched_day`
  and every following record shifted out of alignment. The tail is now keyed
  on the magic. A single-record fixture cannot see this, which is why no test
  did.
- Every pre-ZPV12 player save carrying inventory was corrupted on the first
  save after upgrade, not just v10/v11: each migration branch widened slots
  only to its own era's width (7 to 13, or 11 to 13) while the header became
  `ZPVC`, so the reader walked them with the v12 21-byte stride. All branches
  now widen to the current width through one helper. A second fault in the
  same path: `tailStartOf` assumed a 7-byte slot but runs for v6 through v8,
  and v7 widened slots to 11 when they gained `use_times`, so a v7/v8 record
  with inventory was walked 4 bytes short per slot.
- A pre-ZPV12 player save carrying inventory was corrupted on the first save
  after upgrade. The save path rewrites the header to `ZPVC` (v12) but carried
  v10/v11 records byte-for-byte, leaving 13-byte inventory slots in a file the
  reader walks with the v12 21-byte stride: every field after the slots read
  from the wrong offset and the next load failed with `CorruptPlayersFile`,
  losing the player's inventory, progression and bedroll. Carried records now
  widen each slot with four zero mod ids, the same way the v7 and v9 carries
  already widened theirs.
- GSI values now use stock's separator encoding, so a server or level name
  containing `:` or `;` reaches the client intact. `GameServerInfo::SetValue`
  (IL=70) stores values with `:` replaced by `^` and `;` by `*`, and
  `GetValue` (IL=16) reverses both; zdtd replaced `;` with `_` and passed `:`
  through, so such a name arrived mangled and a `:` could split a value into a
  key the client did not expect.
- `NetPackagePOIMetadataResponse` went out on LiteNet channel 1 instead of 0.
  Its 3.1.0 predecessor `NetPackagePOIAround` overrides `get_Channel` to 1, but
  the 3.2.0 replacement declares no override and inherits `NetPackage`'s 0; the
  channel was carried across when the package was swapped. Stock overrides the
  channel for exactly four packages (`NetPackageChunk`, `ChunkRemove`,
  `DynamicMesh`, `MapChunks`), and a test now pins the whole table rather than
  a sample.
- `NetPackageSetBlock` with an empty change list decoded as a block change the
  client never sent. `parseSetBlockChanges` keyed a legacy 14-byte layout off
  the body length, and 14 is a length a stock body reaches on its own: an
  identity plus a zero count is `6 + platform.len + id.len`, so any pair
  summing to 8 (`"Steam"` with a 3-character id) matched, and x/y/z/id came out
  of the identity bytes. The reach check rejected the result every time (the
  leading identity bytes put the decoded `x` near 1.4 billion), so the cost was
  a bogus rejection and a bounds counter rather than a world edit. The legacy
  branch is removed; no builder had emitted that form since the stock encoder
  landed.
- `NetPackageTurretSpawn` from a real client never placed a turret. The handler
  read zdtd's compact three-i32 body unconditionally, so the stock body's float
  position (`entityType` i32 | pos Vector3, RE write IL=24) decoded as
  coordinates in the billions and the reach gate dropped the placement. A body
  of 16 bytes or more is now read as the stock float layout.
- `NetPackageEntityRelPosAndRot` read its movement delta at a fixed byte 11,
  which is only correct when `bUseQRotation` is clear. The Rotation base this
  package extends carries 3 x i16 euler in that case but a 4 x f32 quaternion
  when the flag is set (RE `protocol-packages.md` 5.5.3), putting `dPos` at byte
  21. A client setting the flag had quaternion bytes decoded as its movement.
- `NetPackageEntityCollect` read only the first of its two i32 fields, so the
  `playerId` naming the collector was never checked. Stock gates the collect on
  `ValidEntityIdForSender(playerId)` (ProcessPackage IL=51); without it a client
  could collect a loot bag in another player's name. The parser now returns both
  fields and the handler rejects a mismatched claim.
- Explosions barely touched entities. `ExplosionData.EntityRadius` is a raw i16
  in blocks, but the parser divided it by 20 like `BlockRadius`, turning the
  stock value 6 into 0.3, which the caller then clamped up to its 1 m floor.
  Block damage was unaffected, so a blast cratered terrain while leaving zombies
  a metre away untouched.
- A stock `NetPackageTraderData` body for a tile entity with no trader data
  attached (14 bytes) was decoded as a zdtd trade: the arm tested `body.len >= 9`
  and the byte it disambiguated on is the high byte of `te_y`, zero for any real
  coordinate. The trade decoded a quantity from two position bytes and the
  trader-open path (quest interact objectives) never ran. The arm now requires
  exactly the 9 bytes the zdtd trade body has.
- Remote crash from one C2S packet: `NetPackageSoundAtPosition` with a
  256-byte clip name reached `@intCast` into a `u8` length and trapped
  (ReleaseSafe ships with safety on, so this killed a release server). The
  cap guard used `>` where the stored length cannot hold the cap itself; the
  identical off-by-one in the waypoint icon/name path
  (`NetPackageWaypointInvite`) and on the server's own sound emit path
  (`playSoundAt`, latent: its only caller passes a short literal) is fixed too.
- `mods/parachute`: the guest kept `announce_text` / `item_tag` as slices into
  `on_enable`'s stack buffer, so a later tick's deploy announcement read a dead
  frame (the shipped `config.toml` sets `announce_text`, so this was the
  default path). Both are now copied into static buffers, matching how every
  other guest handles config strings. Its hand-rolled config parser (the only
  one in any guest; the rest use `plugin_common.Config`) also handled neither
  the quotes nor the trailing comments its own doc comment claimed, so the
  shipped quoted `announce_text` was broadcast with the quote marks still in
  it. It now matches `Config.value` exactly, and the plugin test feeds the real
  `mods/parachute/config.toml` rather than a synthetic string.
- `serveradmin.xml` path leaked on startup: `main` duped it and `Game` duped
  its own copy, but only `Game`'s was freed. Reproduced and fixed under the
  DebugAllocator leak check.
- Client-reachable memory disclosure: the workstation save loader took
  `recipe_name_len` / `scrapped_len` verbatim off disk into 64-byte arrays,
  and `recipeName()`/`scrappedName()` slice by them straight onto the wire, so
  a corrupt `workstations.zws` shipped adjacent struct memory to clients.
  Both lengths are now range-checked like every other length in that loader.
- Modlet XML `removeattribute` hung the server: an unquoted attribute value in
  an element's opening tag left the attribute scan's cursor parked, looping
  forever on operator-supplied XML.
- Save/load desyncs where a skipped record left the read cursor mid-record, so
  every following record decoded from a shifted offset: traders (`traders.zst`,
  reachable today because an admin-spawned trader is saved but not respawned by
  `initWorld`), containers (`containers.zct`, at the 4096 player-chest cap) and
  vending machines (`vending.zvn`). `saveTraders` had the mirror-image bug: it
  wrote a header count and could then emit fewer entries.
- Out-of-bounds writes on save load: the ZPV12 mod-id block indexed the
  inventory array with an unbounded on-disk `u8` count (the slot write one line
  above was correctly clamped), and the ZWS1 group/queue/melt lengths were
  stored unchecked despite indexing fixed arrays on the replicate path.
- `allies.zal` panicked on a corrupt status byte: the range check ran *after*
  `@enumFromInt`, which traps on an exhaustive enum, so it could never fire.
  Same shape fixed for three unguarded `@intCast` of a `peer_slot` that
  defaults to -1, and for a `sleepers_cleared.zsc` header guard that was one
  byte short of the field it then sliced.
- Tall wire profile (`[wire] profile = "tall-512"`) silently lost world edits:
  `encodeChunk` writes the block plane for ZCH4, but `loadChunk` and
  `validateChunkBytes` gated reading it on ZCH3, so the plane was written and
  discarded on every reload and the topsoil tail was then read out of the
  middle of it.
- Multi-level `Extends` chains in `blocks.xml` truncated after one hop: the
  cycle guard recorded the block the walk started from instead of the chain
  step, so the second hop always tripped the duplicate check. Grandparent
  `Class`, `TraderID`, textures and merged drop rows were silently lost.
- `distraction_replan_min` / `distraction_replan_rand` / `flee_distance` were
  parsed, validated and documented as operator knobs but read by nothing; the
  distraction task now uses its own RE cadence instead of inheriting the
  generic chase throttle, and the flee goal distance is separated from the
  give-up radius (defaults unchanged).
- 3.2.0 login gate P0: the advertised version was the raw 3.1.0 form, so
  every real V3.2.0 client was kicked with VersionMismatch=4; the advertised
  `Minor` now matches the 3.2.0 display form (live-verified join).
- Concurrent-join starvation: the join spawn-area burst now yields ACKs
  between chunks so a second client's critical packages are not starved
  behind the flood; full-stock config bundles no longer wedge the reliable
  window (critical retry budget 250 ms → 1 s).
- Join cost: the storage-TE scan on clean proc chunks dropped 19.7 M → 262 K
  cells; a fresh boot's starter chest is no longer clobbered by a reboot
  with no saved entities; placed deco no longer marks chunks dirty.
- WorldSpawnPoints buffer: the join-time builder used a 512-byte slice but
  32 spawn points need 837 bytes, so maps with many spawn points (Pregen06k01
  has >= 20; Navezgane has 1) overflowed on every enter and the client
  silently got no spawn points (2026-08-29 Pregen soak find; buffer now
  1024 with a regression test).
- POI metadata response buffer: the 3.2.0 `POIMetadataResponse` built into a
  64 KiB slice, which 512 dense records can exceed - latent overflow on maps
  with long prefab names; hardened to 256 KiB with a regression test.
- Admin harden: `settime` clamps to a sane day ceiling (a max-u64 world time
  previously overflowed the blood-moon math and crashed the server); admin
  `tele`/`tp` and plugin spawn/move coordinates are bounded to
  `max_player_coord` (±1e6 blocks) and out-of-range C2S movement is rejected,
  so a huge-but-finite coordinate can no longer trap the tick-path casts.
- Admin `wipeplayer` accepts the current ZPV12 player-save format (a wipe on a
  v12 save previously failed to clear the record).
- Knockback impulse (C2S hit shove) now goes through the single
  NetPackageEntityVelocity builder and inherits the stock [-8, 8] per-axis
  clamp, so a knockback beyond the stock band no longer ships non-stock motion
  to peers.
- Plugin verdict scaling is bounded: the loot-roll count re-caps to the
  roll array (a large on_loot_roll verdict could read out of bounds) and the
  block-damage verdict products widen to u64 (u32 overflowed for a large
  verdict times a u16 damage).
- Plugin spawn reversion: a module's applied `zdtd.queue` spawns are recorded
  per source and despawned when the module disables (trap/fuel) or reloads,
  so its entities never outlive it (ADR 0030 amended).
- The trader quest-list tier (raw wire i32) is clamped to 255 before its u8
  cast; a hostile value above 255 trapped.
- The inventory-ledger give delta is clamped to i16 (admin give with a
  count above 32767 previously trapped the cast; the other ledger callers
  already clamped).
- Blood-moon spawn ceiling and wave-size casts clamp the config-scaled
  products in f64 (an unranged [rules.bloodmoon] budget_scale/wave_frac could
  trap the u32 cast).
- Harvest drop rolls and the HarvestCount held-tool multiplier are clamped
  to 65535 before their casts (modded drop/HarvestCount rows could exceed the
  target type; the stack store is u16 anyway).
- Explosion block damage is clamped to u16 per block (the loader allows
  BlockDamage up to 1e6; a modded blast times a DamageBonus multiplier could
  exceed 65535 and trap the cast - the chew path already clamped).
- Disconnect cleanup: a dropped or transport-reaped player's sim entity is
  now destroyed immediately (previously it lingered as a ghost until the slot
  was reused - a phantom in listents/mem counts and a spawn-on-approach
  candidate for late joiners), and the reap path shares the one drop path.
- Join-crash P0 (2026-08-29 bait soak, 5/5 ReleaseFast): the spawn-area
  send held a `*Chunk` while the storage-TE scan read a prefab TE's column
  via `world.blockWorld`, which re-enters `getOrCreate`; the inline-value
  chunk map (AutoHashMap) can resize mid-scan and move every chunk, so the
  held pointer dangled and the `te_scanned` write segfaulted (stack canary
  trip). The callback now reads the block from the chunk being scanned
  (identical value: the TE is confined to that chunk), which removes the
  re-entrancy; the post-scan `te_scanned`/`power_scanned` writes re-fetch
  the chunk by position as defense in depth. 10/10 live double-join bait
  soaks now pass (was 5/5 crashes). Hazard class + pointer-stable store
  follow-on tracked in GAP_ANALYSIS.
- Admin `listplayers` printed `<unknown>` for platform id and ip, so
  telnet-driven tooling (loadgen zombie pressure matching on
  `pltfmid=Local_` / `ip=127.`) silently spawned nothing. It now emits
  `pltfmid=Local_<id>` and the peer's v4 address; a kite soak and a
  wandering-horde soak both show live pressure (112 `spawnentity` calls,
  0 errors).
- Admin `getoptions` read the config base values, not the effective sim
  values, so mode-pack overrides (horde_lite: BloodMoonFrequency=10,
  MaxSpawnedZombies=32) never showed. All pack-overridable keys now read
  the live sim surface.
- Entity kind from stock data: entityclasses `Tags` now classify vehicles
  (`Tags="vehicle"`) and junk turrets (`Tags="turret,..."`) instead of the
  name falling through to zombie, so the admin `spawnentity` verb drops its
  hardcoded name-sniff list and takes vehicle physicals (kind, HP, velocity,
  seats) from vehicles.xml (unknown classes such as vehicleHelicopter fall
  back to the 4x4 def).
- Game modes renamed to **presets**; mods are self-contained. The stock
  preset folder is now `presets/` (was `modes/`), the CLI flag is
  `--preset NAME` (was `--mode`, kept as a deprecated alias), and the
  `zdtd.toml` selector is `[preset] name` (was `[mode] name`, no alias). A
  config-only mod carries its own preset inside the mod folder
  (`mods/<name>/preset.toml` via the `preset` manifest.toml key, replacing the
  old `mode = "<pack>"` that referenced the shared folder), so a mod is
  fully self-contained: config, wasm and assets travel together. The
  infinite world now ships that way (`mods/infinite_world/`); it is no
  longer a stock preset. Renames: `src/server/mode.zig` -> `preset.zig`,
  `Pack` -> `Preset`, `error.DuplicateMode` -> `error.DuplicatePreset`.
- Plugins are self-contained: every mod folder may ship `config.toml`
  (default config, served to the guest verbatim via the new `zdtd.config`
  host import; the host never parses it, each plugin owns its format - the
  shared `mods/plugin_common.zig` `Config` helper parses the minimal
  `key = value` subset) and a `README.md`. The channel works for both load
  paths: discovered mods (manifest dir) and explicit `[plugin] modules`
  (config.toml is read from the wasm's own folder). Reference plugin
  `core_pricegate` now reads its `price_percent` from its own config.toml
  instead of hardcoding 150 - edit the file, no rebuild. Declared via
  `_zdtd_requires "config"`.
- All 12 core plugins migrated to config-driven policy (same channel):
  `core_damagegate` (`percent`), `core_lootgate` (`percent`),
  `core_rewardgate` (`percent`), `core_craftgate` + `core_perkgate` +
  `core_questgate` (`deny_prefix`), `core_pvp` (`deny`), `core_announce`
  (announce strings: `day_prefix`, `blood_moon_rise/fade`,
  `join/leave_message`), `core_adminverbs` (`spawn_x/y/z`, `spawn_entity`),
  `core_killfeed` + `core_tradefeed` (`log_level`: off | info | debug).
  Live-verified (damagegate percent=25, questgate deny_prefix); all 13 core
  wasms rebuilt.
- The plugin/mod manifest file is `manifest.toml` (was `mod.toml`; the parsed
  shape was already called `Manifest`). The folder keeps its self-contained
  layout: manifest + optional `preset.toml` + optional `.wasm`.

## [0.2.0] - 2026-08-22

### Added

- MCP server addon (docs/prd/0002-mcp-server.md, docs/rfc/0002-mcp-server-design.md, ADR 0031): a Model
  Context Protocol server shipped as a Wasm plugin (`mods/mcp`). Protocol
  logic lives in the guest; the host provides a streamable-HTTP endpoint
  (`--mcp-port`, loopback + optional `--mcp-token`) and std.json parsing
  (`json_*` imports). Tools: `server_status`, `player_list`, and an
  `admin_command` tool gated by `--mcp-allowlist` verb prefixes.
- Player save format ZPV10: per-player seed persistence.
- World topsoil bitfield rides the wire (stock m_bTopSoilBroken, splat
  terrain).
- POI light tile entities from prefab .tts markers; ambient spawn rules
  enforce a POI-tag gate, maxcount and respawn delay; sleeper triggered state
  persists across restart.
- Trader: sell price prices the sold stack (PercentUsesLeft, worn items);
  real-client TraderData echo is stock-faithful; quest tier mod feeds the
  quest reward loot stage; POI difficulty tier scales the loot stage.

### Fixed

- WebUI: stray line-number prefixes removed from shell.html; shared-token
  restyle with a tabbed shell (logs and settings); test response capture sized
  for rendered pages.
- main: exit 141 on a broken stdout pipe; flag hints skipped under 3 chars.
- game: terrain_mu held in solid/water sense probes.

## [0.1.0] - 2026-08-22

### Breaking changes

- The writable chunk format is now ZCH3. ZCH1 heights remain readable. ZCH2
  heights remain readable, but its type-only block edits are intentionally
  regenerated because ZCH2 cannot preserve rotation and metadata. Back up a
  world before upgrading.
- The supported stock client wire is pinned to V3.1.0 b14. Earlier stock clients
  can be rejected or fail to decode changed package layouts.

### Added

- Quest turn-in and trader-interact phases advance on the stock client's
  trader open: the NetPackageLockRequest trade-window open (channel 1,
  EntityTraderLockContext) fires the quest interact/turn-in event, so a
  stock client's trader visit completes ready quests with the reward (no
  zdtd-only package needed).
- Trader stock persists across restart (traders.zst): a saved window
  overrides the fresh XML fill by trader name, so a reboot does not re-roll
  what a player was looking at (stock TraderManager saves its inventory).
  Entries ride item names (AssignIds ids are version-dependent); unknown
  names fail closed to a skipped entry.
- Timid animals no longer attack: `approach_attack` is gated by the class's
  inherited AITask-* list parsed from `entityclasses.xml` (stock timid
  templates carry RunawayWhenHurt/RunawayFromEntity/Look/Wander, no attack
  task), so a stag or rabbit near a player flees or wanders instead of
  sprinting at it and meleeing, while wolves, bears, boars and zombies keep
  hunting. New attack task names land in one RE constant, not per-class data.
- Treasure-dig ambushes now fire like stock: each `treasure_radius_break`
  objective update rolls the quest's TreasureRadiusReduction event `chance`
  (quests.xml: 0.25) and spawns the nested SpawnGSEnemy ambush (1-3
  SleeperGSList) around the player. The event block is parsed from the quest
  data (not hardcoded), the roll is deterministic per (world time, quest
  code), and the spawn reuses the phase-entry gamestage spawn hook.
- Loot container group rolls are prob-weighted like stock: an entry's
  stage-resolved prob is its weight relative to the group sum (a 0.9 item
  drops ~9x as often as a 0.1 one, zero-prob entries never drop), replacing
  the uniform pick that made every item in a group equally likely.
- Wandering zombies now path on the A* navmesh like the chase: `wanderUpdate`
  routes the same replan + waypoint machinery as `chaseAlongPath`, so a
  wanderer detours around obstacles instead of sliding straight into them
  (stock EAIWander walks to its spot via the navmesh).
- Loot-container discovery covers Navezgane-scale maps: the container store is
  now 4096 entries with world-container eviction (a full table reuses a
  non-player-placed container, which regenerates deterministically from the
  next chunk scan; player-placed chests are never evicted), so no chest past
  the old 256/512 cap silently comes back empty.
- Blood-moon horde music is per player like stock (`EntityPlayer.bloodMoonParty`):
  a player hears it only while the horde is active and their own party's horde
  is alive; the old global bool made every player on a multi-party server hear
  any party's horde music.
- The admin console verb set is complete for the stock surface:
  `getoptions` dumps every known serverconfig option with its current value,
  `exportcurrentconfigs` writes them to `<world_dir>/exported_config.txt`,
  `loglevel` sets the runtime log level (gating info/warn/err like stock
  Log.Level), `listthreads`/`lt` summarizes the server's threads, and
  `commandpermission`/`cp` sets a per-command required permission level
  enforced at the in-game console boundary. The Steam-group verbs
  (`admin addgroup` / `whitelist addgroup`) stay a documented gap (zdtd has
  no Steam group concept).
- Quest `<action>` elements are complete on the stock surface: SpawnGSEnemy
  now spawns its gamestage-scaled enemies around the player on phase entry
  (stock SpawnQuestEntity placement, 12-24 m), alongside the existing
  UnlockPOI; SetCVar / ShowMessageWindow stay client-side as stock runs them
  on the owning player, and GameEvent actions have no stock quest uses.
- Quest phases now advance only when **all** their objectives complete (stock
  refreshQuestCompletion): the shared `tier1_clear` phase 3 (ClearSleepers +
  POIStayWithin) and always-active phase-0 objectives are enforced, per-objective
  progress rides the journal wire and the ZPV6 save, and a ForcePhaseFinish
  objective can fail a quest. The 99-def sweep over the real quests.xml
  completes 99/99.
- ClearSleepers quests are real now: kills only count inside the quest's
  bound POI (victim position rides the kill event), and completing the phase
  permanently suppresses the POI's sleeper volumes (persisted across restart),
  so a cleared POI does not re-spawn its zombies on re-entry.
- Quest journal persistence is now ZPV5: every saved quest stores its name
  (the stock Quest.Write identity) and the accepted POI rect, so a restart  -
  even after a quests.xml edit - restores the same quest bound to the same
  prefab instead of a reshuffled def or a re-resolved POI. Older ZPV2/3/4
  player saves still read and upgrade in place.
- Quest POI placement now mirrors stock: RandomPOIGoto/Goto/ClosestPOIGoto
  objectives select the POI by prefab quest tags, difficulty tier, biome
  filter and distance (with bedroll/land-claim/quest lockouts), and trader
  offers carry the real QuestLocation / QuestSize / POIName instead of a
  fabricated catalog spot (RE: 7dtd-engine-research docs/quests-challenges.md).
- Core stock-client play now covers join, terrain streaming, inventory, combat,
  death and respawn, loot, crafting, trading, and persistence with EAC off.
- `--version` reports the zdtd product version and the supported stock client
  wire version.
- Procedural worlds (`--worldgen-seed`) now generate terrain from a 3D density
  field instead of a heightmap, so cliffs and overhangs appear naturally.
  Chunks are still generated on demand at stream time from the seed and chunk
  coordinates alone, so the same seed always yields the same world and chunk
  borders never seam. Water, biomes, caves, and points of interest are not
  generated yet.
- Stock-like `serverconfig.xml`, config override directories, and procedural
  terrain seed options are available. Run `zdtd --help` for precedence.
- Operator tunables can be set in `zdtd.toml` (world directory or CWD; see
  `zdtd.toml.example`). Run `zdtd --help` for the full precedence order.
- A Wasm plugin runtime (zwasm v2, ADR 0020) loads `.wasm` modules listed in
  `zdtd.toml` `[plugin] modules`. Plugins export `on_enable`, `on_tick`,
  `on_player_join`, `on_shutdown` and import `zdtd_log`, `zdtd_tick`,
  `zdtd_queue`; every call runs under a fuel and linear-memory budget, and a
  module that loops is disabled at its budget instead of stalling the server.
  Plugins may also handle extra admin verbs via `on_admin_command` and
  act as a chat filter via `on_chat` (deny or rewrite; first responder wins;
  bad UTF-8 rewrite treated as deny). See `docs/PLUGIN_DEV.md`.
- An operator web UI is available via `--webui-port`, `--webui-bind`, and
  `--webui-secret` (or env `ZDTD_WEBUI_SECRET`). It is off by default, binds
  to loopback, and refuses to start without a secret. It exposes the same
  command surface as the `--admin-port` TCP console. See `docs/WEBUI.md`.
- Server-side guard policy for detector evidence. It is log-only by default: a
  tripped gate records `guard would kick` and a counter, and nothing is denied
  or dropped. Operators can opt in to per-surface quarantine (no damage, no
  container use, no block edits) and, separately, to kicking, via zdtd.toml
  `[authority] guard_*`. Both enforcement rungs also require authority mode
  `correct`. Weak signals can never trigger either rung. The admin `guardstats`
  command reports the policy state, and `guardclear <slot>` releases a peer.
  See `docs/AUTHORITY.md`.
- An experimental, statically linked native plugin host skeleton is included.
- Weather and storm state now survives a server restart: the per-biome storm
  machine (`weather.zwt`) resumes the storm cycle instead of re-rolling the
  opening weather groups.
- Spawned vehicles and turrets survive a restart via `entities.zen`, and the
  power grid graph is rebuilt from the chunk block grid on first chunk load
  (`scanChunkPower`), so a generator/consumer/battery layout keeps working
  after a restart without saving the graph. Wire links between power nodes and
  trader quest-offer state remain runtime-only.
- Prefab `.tts` water planes now paint: POI pools, flooded basements and water
  tanks render wet through the chunk water-mass channel (the v>=17 sparse water
  channel in the prefab is decoded per-cell and the resolved water block is
  stamped at mass>0 cells). The flowing-water sim remains open.
- The scheduled blood-moon day is re-sent to connected clients when it rolls,
  so a client that joined mid-cycle no longer keeps a stale red-moon HUD day
  after its first horde.
- Quest rewards are real: the journal writes the actual reward ItemStacks
  (stock item ids and counts) instead of empty stacks, and turning a quest in
  grants the items into the inventory, the exp into the level ledger, and the
  wallet dukes on top of the existing coin credit.
- Quest `<action>` elements are parsed (type, phase, properties) and the
  phase-gated UnlockPOI action fires server-side, releasing the quest's POI
  lock on the phase it names (the phase-4 turn-in release no longer leaves the
  POI reserved). SetCVar / ShowMessageWindow are client-owned and recorded;
  SpawnGSEnemy / GameEvent remain recorded-unfired until the spawn/event
  subsystems land.
- The in-tree `sample_hello` plugin is enabled by default and can be disabled
  with the gamemode `enable_sample_plugin` setting. Out-of-tree packaging and
  a stable dynamic ABI are not supported yet. See `docs/PLUGIN_API.md`.
- An optional Tracy profiling build emits one zone per apm profiler section plus
  one frame mark per server tick. It is off by default with no overhead and no
  dependency; the Tracy client stays operator-supplied via
  `-Dtracy=true -Dtracy-src=PATH`. See `docs/APM.md`.

- Optional performance switches in `zdtd.toml` under a new `[perf]` section, all
  off by default: `async_chunk_flush` (chunk saves are written by a background
  thread instead of on the tick), `terrain_snapshot` (pathfinding reads a
  per-tick terrain snapshot instead of taking the world lock for every probe),
  and `job_batches` (the sleeper-volume proximity test runs in parallel; spawns
  still happen in the same order). Each switch ships with always-on metrics
  (`save_encode`, `save_flush_wait`, `terrain_snap`, `sleeper_scan`, `te_scan`
  sections and the matching counters) so operators can see whether it is worth
  turning on. See `zdtd.toml.example` and `docs/SCALE.md`.
- Block stability and structural collapse: `src/world/stability.zig` ports the
  stock per-block byte plane (15 full support, 1 cap on non-support blocks, 0
  is the only value that falls). A chunk computes the plane once on first touch
  (reset + distribute, matching stock seed semantics); a C2S SetBlock that
  removes a support block fells the recursed dependency chain and the server
  removes and broadcasts the fallen blocks, while a placement takes support
  from its neighbours and re-spreads. Support and ignore membership resolve
  from the block tables, not a hardcoded list. See
  `../7dtd-engine-research/docs/world/stability.md` for the RE ground.
- Land claims persist across restarts: keystone claims write to `claims.zlc`
  and re-map to the owner on login (entity ids are per-session), and the
  preserved seen-day keeps offline expiry past `LandClaimExpiryDays` honest.
  Removing the keystone takes the claim with it (`removeClaimAt`).
- Trader stock is per class: each trader resolves its own traders.xml
  `<trader_info>` id from npc.xml and fills its window from its own
  `<trader_items>` list instead of the shared `traderAlways` fallback. The
  lock-open path denies trading outside the trader's open hours (vending stays
  always open) and `allow_sell=false` blocks selling to that trader.
- Trader quest offers come from each class's npc.xml `quest_list` instead of a
  hardcoded map, accept the stock quest-name families (`intro_`, `test_`,
  `challengegroup_reward_`) alongside tiered `quest_` names, and are filtered
  by the requested tier with active quests excluded.
- Campfires and burning barrels grant the stock insulation warmth buff
  (`buffCampfireAOE`) to a player within radius (blocks.xml
  `ActiveRadiusEffects`). Torches, candles and the radiated barrel have no
  fuel-gated workstation record yet, so they remain unimplemented.
- Air drops push a `supply_drop` NavObject marker when the crate spawns, so a
  stock client gets a compass ping (`nav_object_classes.xml`). The marker has
  no removal companion package yet when the crate is looted or expires.
- Kill XP scales by entity class instead of a flat 100 per kill: the loader
  resolves entityclasses.xml `ExperienceGain` through its `replace_properties`
  chain, bounded to 2500 XP; an unresolved or missing value keeps the old flat
  100.
- Bedroll ownership persists across a restart. `players.zsv` bumps
  ZPV3 -> ZPV4 (the progression tail's buff list is followed by a
  `bed_present` byte and, when present, `bed_x`/`y`/`z`); ZPV2 and ZPV3 saves
  still load.

### Fixed

- A gamemode pack (`modes/<name>.toml`) now accepts the same value ranges as
  `serverconfig.xml` for the keys both can set. Land-claim durability, claim
  expiry days and claim size no longer take pack-only values the documented
  range forbids, and `BlockDamageAI`/`BlockDamageAIBM` accept 0 from a pack.
  `MaxSpawnedZombies` (and `max_spawned_zombies`) now accept 0 as "no zombie
  spawns", which `modes/builder.toml` asks for; it used to clamp to 1.
- An even `LandClaimSize` from a mode pack is forced odd like the
  `serverconfig.xml` value, so the claim area the client draws matches the one
  the server enforces.
- `nan` and `inf` in `zdtd.toml` or a mode pack are rejected at startup instead
  of being bound as a tunable that makes every comparison against it false.
- Package and entity layouts were updated for the V3.1.0 b14 client wire.
- Chunk resends now carry per-cell block damage in the wire damage channel
  (u16 per cell, same sparse shape as the water channel), so a wall chewed by
  zombies or a block mined by a player re-renders damaged instead of pristine
  the next time the chunk is streamed.
- Chunk persistence now retains full `BlockValue.rawData` in ZCH3.
- POIs are built from the blocks they were authored with. Prefab block ids are
  prefab-local and are now translated by name through each prefab's
  `<name>.blocks.nim`; roughly one in ten placed blocks used to be a different
  block. Prefab files older than format 18 are converted from the old
  `BlockValueV3` bit layout first, which covers 568 of Navezgane's 1559
  placements.
- The ecs-soa review follow-up fixes are in: relative motion raises the dirty
  bit so the replicate pass relays it at the motion period instead of the
  5-tick heartbeat; respawn heal marks hp/pos dirty; the loot-bag Collect arm
  restores the player inventory on a partial deposit and records ledger causes
  instead of deleting the remainder; `QuestEntitySpawn` is gated on an active
  quest and the shared block token, and `TurretSpawn` on the block token, so
  neither can drain the entity table; the absolute PosAndRot arm preserves the
  stored yaw instead of fabricating north; turret kills roll `LootDropProb`
  like player kills (`World.rollLootDrop`).
- Respawn no longer zeroes food and water: `respawnPlayer` mutates only the
  hp fields and keeps food, water and stamina across death (seeding their
  maxima when 0), matching stock behavior instead of landing on `food=0`,
  `water=0`.
- A stability removal now reports the recursed dependency chain as fallen
  (digging out a support column drops the structure above it), and the
  stability tests build their world with explicit air above the surface so
  biome-layer regen cannot smuggle extra blocks into the fixture.
- Reliable-window retry pacing: the WindowFull retry loops no longer sleep
  0.5 s every fourth attempt, which wedged the single-threaded tick for up to
  two minutes per stuck peer and starved the stale-peer sweep. They pump ACKs
  free for the first 16 attempts, then pace at 1 ms every fourth so a client's
  ~15 ms LiteNetLib ACK cycle can drain the window; a dead peer is reclaimed
  within the 3 s sweep instead of holding the tick, and the block-IdMapping
  WindowFull drops seen under loadgen reconnect floods no longer stall the
  server.
- Per-package delivery method: the five S2C motion packages (EntityPosAndRot,
  EntityRelPosAndRot, EntityRotation, EntitySpeeds, EntityStatsBuff) that stock
  sends with `get_ReliableDelivery=false` now ride `Peer.sendUnreliable` from
  `sendGame`, `broadcastExcept` and the replicate fan-out, so 20 Hz position
  spam no longer occupies or retransmits inside the 64-slot reliable window
  shared with chunks and join-critical control traffic.
- IPv6 hosting: the UDP socket binds IPv6 unspecified with IPV6_V6ONLY cleared,
  so both IPv4-mapped and native IPv6 clients reach the server (stock
  LiteNetLib's dual-stack flag); hosts without IPv6 fall back to IPv4-only.
- Loot respawn: `LootRespawnDays` (serverconfig, default 7, 0 disables) re-rolls
  a looted world container on its next open when the interval since its touch
  day has elapsed; the cycle-varying seed makes each respawn differ while
  staying deterministic per position and cycle. `touched_day` persists in
  containers.zct (older saves read 0 and do not respawn immediately), world
  containers are marked non-player-placed at materialization, and player-placed
  storage never respawns (stock bPlayerStorage).
- Inbound fragment reassembly: the peer now holds two assembly slots keyed by
  frag_id instead of one, so a second large C2S message (a Bag plus a
  PlayerInventory during a loot transfer) no longer clears the first assembly
  and silently loses a message that was already ACKed. A third concurrent
  message drops with an `asm_drops` counter; a regression test interleaves two
  messages and reassembles both whole.
- POIBlockActivate quest objectives now wait for and advance on the client's
  block-activated objective update (parsed but previously discarded) instead
  of auto-scaffolding past the phase; unrelated objective events such as
  zombie kills no longer advance it.
- Trader restock follows each traders.xml `<trader_info>` `reset_interval`
  (-1 never, 0 daily, N every N days) instead of a flat daily refill, and
  buy/sell pricing uses the root `buy_markup` / `sell_markdown` (per-trader
  overrides win) so the server charge matches the price the client displays.
- Goto-point quests without a static position (stock RandomPOIGoto /
  ClosestPOIGoto) bind the nearest real POI at accept; the NavObject marker,
  PositionData location and the goto check all use the bound POI center, so
  markers point at reachable prefabs instead of an invented FNV spot.
- Container loot fails closed: storage blocks with no resolvable `LootList`
  stay empty on both initial fill and the LootRespawnDays re-roll instead of
  falling back to a woodenChest roll.
- The block-id coverage guard test asserts every placeable blocks.xml name
  resolves in the bundled AssignIds dump, so the negotiated `blocks` mapping
  never leaves server data to the client's `assignLeftOverBlocks`.
- The last bare tick throttles became `[stream]` keys in zdtd.toml
  (`sleeper_tick_ticks`, `turret_sync_ticks`, `save_interval_ticks`), and the
  workstation burn dt follows the configured cadence.
- DecoUpdate objects carry stock `GetRandomRotation` rolls (rawData bits
  16..20, keyed to the placement cell) instead of a flat 0, so trees and rocks
  no longer all face north; the world mirror reads the same rotation bits.
- `setgamepref` writes the GameStats-backed prefs at runtime (difficulty,
  blood-moon cadence, day length, block damage, xp, pvp, drop, loot respawn,
  air drops), clamping to the config ranges and broadcasting the fresh stats
  blob; startup-only prefs keep the read-only reply.
- Vending machines persist their full store (stock rows, owner, password,
  rental) to `vending.zvn`, so a placed machine keeps opening after a restart;
  the trader-markup dead code in its stock seeding is gone (vending is
  owner-priced).
- `ItemValue.UseTimes` rides the ECS slot and both wire conversions, and
  `inventory.degradeUse` wears a tool toward 0 (clamped, stack stays present).
- Hammer upgrades work: `blocks.xml` `UpgradeBlock.ToBlock` resolves through
  the Extends chain into a data-driven ladder, and SetBlock only accepts a
  block swap onto an occupied cell when the new id is the current block's
  upgrade target, so a forged SetBlock cannot swap in arbitrary block ids.
- The join challenge comparison runs in constant time instead of
  `std.mem.eql`'s early-out, closing a timing side-channel that could leak
  challenge bytes one at a time.
- The server no longer trusts a client's `NetPackageTraderData` copy-back for
  trader stock or money; only the typed trade path may mutate an entity
  trader, and the vending path re-sends the stored tile entity instead of
  taking the client's item list or available-money field.
- `serverconfig.xml` attribute values are XML-decoded before use, so a
  `GameName` or `SandboxCode` containing an entity like `&amp;b` reaches the
  wire as `&b` instead of the literal `&amp;b`.
- Builtin item pins (fixture eat/drink amounts, stock-type fallback) are
  gated on the builtin catalog and no longer leak into XML mode: a real
  items.xml catalog no longer inherits a fixture's food value or an
  unresolved type naming the wrong stock item.
- `PlayerInventory` applies atomically: a body that fails partway (a short
  bag section, a bad equipment write) leaves the inventory exactly as it was
  instead of a half-applied mix of old and new fields.
- Sprint stamina now drains on backward and strafing movement, not just
  forward, so sprinting in those directions is no longer free.
- Six broadcast-fanout C2S packages (BlockTrigger, WireActions,
  WireToolActions, LandClaimRepair, ItemActionEffects, CloseAllWindows) are
  now rate-gated on the same block/inventory tokens as SetBlock, closing an
  unmetered bandwidth-amplification path where one client packet fanned out
  to every nearby or connected peer.

