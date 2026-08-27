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
| `src/assets/blocks.zig` | A | blocks.xml solid/name table. Wire ids come only from AssignIds (idByName), never sequential XML declaration order. `pickup_source` reads the PickupSource property (XML.txt:908 declares it; V3.1.0 b14 sets it on no block, so stock pickups leave Air). `harvest_drops` parses the block's `<drop event="Harvest">` rows (count via ParseMinMaxCount, prob × ResourceScale property, stick_chance/tool_category/tag stored as the item-side bonus legs) and inherits through Extends per CopyDroppedFrom IL=89 (own wins per item name), roll semantics per Block.DropItemsOnEvent IL=246 + GameUtils.HarvestOnAttack IL=623 (RE blocks.md, items.md) |
| `src/assets/blocks_nim.zig` | A | Prefab `.blocks.nim` local-id → block name table (Prefab name mapping). Catalog/asset parse (not world store). Use when TTS types are local indices |
| `src/assets/buffs.zig` | A | buffs.xml: metadata + passive_effect rows. Full triggered_effect VM is later |
| `src/assets/entities.zig` | A | entityclasses.xml loader: name → Unity Mono hash, kind, HP, death loot list, day/night speeds (MoveSpeed/MoveSpeedNight shamble, MoveSpeedAggro "min,max" = day/night chase + MoveSpeedRand "min,max" per-entity roll, entity-ai.md GetMoveSpeed/GetMoveSpeedAggro + the stock XML comment "min/max (like day or night)"), the SightLightThreshold "min,max" pair (stock "-2,150", CanSeeStealth IL=21) and the SleeperSightToWakeMin/Max wake-threshold roll ranges (stock "-40,5" / "340,480", GetSleeperDisturbedLevel IL=38). Also resolves the inherited AITask-* list into `ai_attack` (timid animals carry no attack task and never pick approach_attack; the attack-task name set is a stock-AI RE constant) |
| `src/assets/entitygroups.zig` | A | entitygroups.xml: named weighted spawn lists (`<e n="…" p="…"/>`) |
| `src/assets/gamestages.zig` | A | gamestages.xml: per-spawner stage ladders plus the player/party stage math. |
| `src/assets/items.zig` | A | items.xml loader + builtin sim ids with stock name/type resolution for client UI. `harvest_rows` parses the HarvestCount passive (141) rows on each item (op/value/curve/tags; RE GameUtils.HarvestOnAttack IL=623: count = trunc(rolled x GetValue(141, tool, 1, holder, null, dropTag)); ops base_add/base_set/perc_add fold over base 1, quality curves at the tool quality, tag-gated by the drop row). `harvestMultiplier` resolves the held-tool multiplier. `tags` + `mod_slots_curve` parse the item's `Tags` property and the `ModSlots` quality passive (RE items.md CalcModSlotCount IL=29) for the mod-attachment scrub |
| `src/assets/item_modifiers.zig` | A | item_modifiers.xml loader (RE items.md ItemModificationsFromXml ParseModifier IL=63): per-mod `installable_tags` / `blocked_tags` / `modifier_tags` gates for mod attachment validation; `isSuitable` implements the ItemClassModifier tag intersection/disjoint check |
| `src/assets/loot.zig` | A | loot.xml loader: groups + containers, simple deterministic rolls. Group picks prob-weighted like stock (2026-08-21): the entry's stage-resolved prob is its weight relative to the group sum, zero-prob never picked; lootstage templates resolve per stage, force_prob gates independently |
| `src/assets/map_atlas.zig` | R | Stock texture-atlas minimap colors: the `uvmapping` XMLs (MeshDescription.MetaData TextAssets) from the `meshdescriptions_assets_all.bundle`, extracted + regenerated by `../7dtd-engine-research/tools/sandbox/{extract_mesh_atlas,gen_atlas_zig}.py` (docs/texture-atlas.md). Colors packed with the stock Utils.ToColor5 RGB555 formula |
| `src/assets/maxdamage.zig` | A | MaxDamage lookup: blocks.xml name→hp + optional AssignIds map from .blocks.nim or a version-matched id\tname dump. Without a full id map, callers fall |
| `src/assets/modlets.zig` | R | Stock `ModManager` subset for XML-only modlets (../7dtd-engine-research/docs/mod-loading.md §1-2): Mods/ root scan, ModInfo.xml V2 parse (Name/DisplayName/Version rules), Config dir collection in mod order, Bundles/ tolerance (never read, PRD R11), code-mod warning (DLLs never hosted). PRD 0003 / RFC 0003 |
| `src/assets/npc.zig` | A | npc.xml: npc_info entries map a trader entity class (localization_id) and display name to a traders.xml `<trader_info>` id plus its quest_list |
| `src/assets/painting.zig` | A | painting.xml: paint id (0–255) ↔ TextureId for chunk face paint |
| `src/assets/noise.zig` | A | sounds.xml `<Noise>` rows keyed by SoundDataNode name (volume/time/muffled_when_crouched/heat_map_*) for the movement-noise model; stock Data/Config/sounds.xml (1312 rows V3.1.4), fold applied via RE entity-ai.md PlayerStealth |
| `src/assets/paths.zig` | A | Resolve Data/Config XML paths, modlet + override patch dirs (base → mods → overrides, PRD 0003 R6/R7), generic tryLoad |
| `src/assets/progression.zig` | A | progression.xml: level curve + attribute/perk catalog (names, max levels, costs). Full perk requirement graphs / effect application is progressive; ca |
| `src/assets/quests.zig` | A | Load stock `Data/Config/quests.xml` into a playable Quest catalog. Reward `ischosen`/`isfixed` parse generically (any reward kind): the stock CloseQuest payout gates chosen rewards on a rewardChoice list every dedi caller passes as null (RE quests-challenges.md, 2026-08-26), so the server skips them; the player's pick rides the client inventory sync. Also parses the `[quests]` objective-kind spec + policy defaults (ADR 0021) into the catalog's `objective_kinds` / `policy`, and `<event>` blocks (stock: TreasureRadiusReduction → `chance` + nested SpawnGSEnemy gamestage list / count range; unknown event types skipped, so new stock events need no code) |
| `src/assets/recipes.zig` | A | recipes.xml loader: craft outputs + ingredients for server craft queue |
| `src/assets/root.zig` | A | Stock game config asset loaders (quests, blocks, items, …). |
| `src/assets/sandbox.zig` | R | Sandbox code codec + option/value-set lookup. Codec (version char + base-26 triples) and decode semantics (unknown ids skipped, invalid index -> default) from `../7dtd-engine-research/docs/sandbox-options.md §3`; value-set and option tables are generated stock data (see sandbox_data.zig). Values: `../7dtd-engine-research/tools/sandbox/sandbox_tables.json` (extracted from `SandboxOptionManager.SetupOptions` IL of V3.1.0 b14) |
| `src/assets/sandbox_presets.zig` | A | GameDifficulty preset ladder, comptime-parsed from the embedded stock `sandbox_presets` TextAsset (`src/assets/sandbox_presets.xml`; the six Difficulty presets' SandboxCodes decode via the sandbox codec to the per-difficulty IncomingDamage/EntityIncomingDamage/RangedDamage/MeleeDamage multipliers, RE sandbox-options.md §3). Source of the XML: the stock client's `7DaysToDie_Data/data.unity3d` (UnityPy extraction, research `tools/sandbox/{sandbox_presets.xml,extract_preset_codes.py}`); the dedi ships no copy, so zdtd embeds the extracted file at comptime rather than hardcoding the ladder (rule 15) |
| `src/assets/sandbox_presets.xml` | A | Stock `Data/Sandbox/sandbox_presets` TextAsset content (client bundle `data.unity3d`, UnityPy extraction; research `tools/sandbox/sandbox_presets.xml`). Comptime-embedded and parsed by sandbox_presets.zig; never hand-edit — re-extract on game update |
| `src/assets/sandbox_data.zig` | R | Generated stock tables: 65 value sets (numeric arrays from `<PrivateImplementationDetails>` FieldRVA) + 165 options (id/name/value-set/default) from the IL census. Regenerate with `../7dtd-engine-research/tools/sandbox/gen_zig_tables.py`; do not hand-edit |
| `src/assets/signs.zig` | A | Prefab sign libraries (*_signs.xml under Data/Prefabs) for NetPackageSignDataResponse. Catalog data only; the wire encode lives in wire/stock_sign.zig |
| `src/assets/spawning.zig` | A | spawning.xml biome spawn rules → director / animal pop |
| `src/assets/storage_pairs.zig` | A | Closed↔Open storage block pairs from blocks.xml DowngradeBlock |
| `src/assets/traders.zig` | A | traders.xml: trader_item_groups, trader_info blocks, and the stock inventory roll (TraderInfo::Spawn, asm.il 862758-863520) |
| `src/assets/unity_hash.zig` | A | Unity Mono / .NET stable string hash (Extensions.GetStableHashCode). |
| `src/assets/vehicles.zig` | A | vehicles.xml physical attributes → sim VehicleKind defaults |
| `src/assets/xml_patch.zig` | A | Clean-room config XML patches (stock XmlPatcher subset; mod-loading.md §5.3). Full verified op catalog: set/setattribute(/byxpath), remove(/byxpath), removeattribute(/byxpath), append/prepend(/byxpath), insertafter/insertbefore(/byxpath), csvoperations, include (@modfolder: tokens); conditional fails closed (RE gap G5). Applies modlet Config dirs (mod order) + --config-overrides (file order) |
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
| `src/ecs/jobs.zig` | Z | Thin jobs helper: run work over a slot range and wait. Wraps util/parallel (persistent pool). No heap; serial when pool unavailable |
| `src/ecs/locals.zig` | Z | Named tick scratch on World. No file-static mutables for sim. Cleared once per tick via World.beginTick / schedule.run |
| `src/ecs/observers.zig` | Z | Fixed on_spawn / on_death listener table. Cap 4. No heap. World fires via fireSpawn / fireDeath; listeners must not spawn/destroy |
| `src/ecs/party.zig` | R | Party engine (RE ../7dtd-engine-research/docs/parties-factions.md §2). |
| `src/ecs/path.zig` | R | Lightweight grid path helpers for zombie chase (greedy, BFS, A*). |
| `src/ecs/poi_lock.zig` | R | Quest POI lockout table: the server half of QuestEventManager's PrefabInstance.lockInstance (QuestLockInstance, asm.il 1001892-1002045) |
| `src/ecs/powerblocks.zig` | R | Stock electrical block registry from blocks.xml Class + AssignIds. NodeKind mapping is RE (PowerItemTypes); names/ids/watts/fuel come from game data |
| `src/ecs/query.zig` | Z | Dense SoA iteration helpers. No allocation; O(capacity) scans |
| `src/ecs/quest.zig` | R | Quest catalog (shared resource) + definition types. Runtime journal/wallet live as SoA components; mutations are in systems.zig. Carries `builtin_objective_kinds` (stock objective-type mapping, §3.7), `QuestPolicy` (zdtd-owned kill/radius defaults, §3.7) and `FlatObjective` (per-objective phase completion — stock refreshQuestCompletion requires all non-optional objectives of a phase; arrival objectives carry required 1 since their `value` is a distance) |
| `src/ecs/root.zig` | Z | ECS package root: SoA world, components, systems, resources. |
| `src/ecs/rules.zig` | R | Sim rule parameters (ADR 0021 decision 2): a game mode is mostly these numbers. Carried on `World.rules` (read as `w.rules.<group>.<field>`), set |
| `src/ecs/schedule.zig` | Z | Explicit sim pipeline phases. Ordered only; parallel stays inside a phase (systemZombieAi / systemTurrets via util/parallel). No access-set scheduler |
| `src/ecs/sim_view.zig` | Z | Narrow mut surface over World for inv/transform (plugin / handler boundary). No heap. Prefer this over raw *World when only these mutators are needed |
| `src/ecs/snapshot.zig` | Z | Deterministic sim snapshot bytes for tests/debug (not a full save format). Fixed buffer, no heap. Covers live entity census + director clock |
| `src/ecs/systems.zig` | R | ECS systems: pure functions over World SoA columns + resources. Hot loops (zombie AI, turrets) run multi-threaded over disjoint slots |
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
| `src/plugin/manifest.zig` | Z | Mod manifests (PRD 0005/ADR 0032): `mod.toml` parse via toml_bind, tier + override-point vocabulary, `mods/*/mod.toml` discovery |
| `src/plugin/resolver.zig` | Z | Mod resolution (PRD 0005/ADR 0032): tiers, disabled/blacklist (core protected), exclusive override-point claims, mod-replaces-mod, load-time conflict detection |
| `src/plugin/root.zig` | Z | Plugin package: Wasm guest runtime (ADR 0020) plus in-tree static host as test scaffolding only (`api` / `host` / `sample_hello`). Shipping plugins |
| `src/plugin/sample_hello.zig` | Z | In-tree sample static plugin: logs once on enable |
| `src/plugin/wasm.zig` | Z | Wasm plugin runtime (ADR 0020, zwasm v2): load a .wasm module, instantiate it under fuel and memory budgets, register the minimal host import table, |
| `src/protocol.zig` | R | Wire constants from ../../7dtd-engine-research/docs/protocol.md (V3.x loadgen golden; wire pin V3.1.0). Package IDs are dynamic (PackageIds map); never hard- |
| `src/server/admin.zig` | Z | Minimal TCP admin console transport (telnet-like): one command line per connection. Listen/accept via `util/tcp_listen` (std.Io.net); no std.os.linux. Admin verb surface (2026-08-21): `getoptions` dumps the known serverconfig names with values preferring the GameStats-backed prefs (config.zig `effective` is the loaded-config source); `exportcurrentconfigs` writes `<world_dir>/exported_config.txt`; `loglevel` gates util/log.zig info/warn/err (stock Log.Level 0..4); `listthreads`/`lt` summarizes the logical threads; `commandpermission`/`cp` keeps a per-command required level enforced at the in-game console boundary (stock levels run 0 = highest) |
| `src/server/admin_cmds.zig` | R | Stock telnet console output shapes and the persistent operator lists. |
| `src/server/admin_xml.zig` | R | Stock serveradmin.xml loader (AdminTools state): admins/whitelist/blacklist sections, platform+userid attrs with legacy steamID fallback, permission_level, unbandate DateTime; merged into the operator lists at startup (no stock file-watcher hot-reload; see GAP_ANALYSIS bans row). RE: 7dtd-engine-research dedicated-misc-systems.md. |
| `src/server/admin_console.zig` | R | Operator console surface: admin TCP + webui command handling, the stock telnet reply shapes, persistent operator lists, and the guard/gamestage |
| `src/server/ally.zig` | R | Ally relationships keyed on PlatformUserIdentifierAbs (stock `AllyStore`). |
| `src/server/c2s/blocks.zig` | R | Block editing: SetBlock, BlockTrigger, Explosions. Extracted from the old c2s/inv.zig tail (643-991) verbatim. NetPackagePickupBlock: stock PickupBlockServer IL=77 (type-match + echo + PickupSource/Air replace) with zdtd reach/claim bounds. NetPackageSetBlockTexture: Chunk.SetBlockFaceTexture IL=48 idx-in-face-byte paint into the textureFull plane + dedi rebroadcast (SetBlockTextureServer IL=41) |
| `src/server/c2s/dispatch.zig` | R | C2S dispatch extracted verbatim from game.zig handlePackage. Phase gate + c2s/* fanout; game.zig keeps a one-line forwarder |
| `src/server/c2s/inv.zig` | R | C2S inventory and block editing: player inventory snapshots, holding/item drop/bag, tile-entity edits, inventory transactions, block trigger/setblock. NetPackageItemReload: entity-gated relay to every peer but the sender (ItemReloadServer IL=32) |
| `src/server/c2s/join.zig` | R | Join state machine — extracted from game.zig handlePackage (stock SM). Owns the 7 join packages that must stay coherent: PlayerLogin → | Login VersionAuthorizer gate (LongStringNoBuild compVersion compare, EKickReason.VersionMismatch) player-cap gate (PlayerLimitExceeded) at login
| `src/server/c2s/misc.zig` | R | C2S misc domain: chat, player data / disconnect, dropped packages, game events, quest entity spawns, console commands, damage, lock requests, the NetPackageEntityAnimationData relay (client-originated avatar anim params, stock ProcessPackage IL=64), |
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
| `src/server/game/clock_persist.zig` | R | World-clock persist extracted from game.zig (ZCL1: worldTime u64) |
| `src/server/game/config_files.zig` | R | Config-file S2C: stock `SendXmlsToClient` / `NetPackageConfigFile` (mod-loading.md §5.6, protocol-packages.md IL=25). Deflate cache of the patched 42 S2C rows built once at init (PRD R8); join send streams name + i32 len + blob per row (archetypes name-only), framed with the stock compressed envelope (G7, `frame.zig` DeflateFramer). Divergence: null cache sends -1 instead of stock's skip so a vanilla client's config wait completes (PRD R9) |
| `src/server/game/constants.zig` | R | Game-wide constants re-exported by game.zig. Keeps the 40-line help table and a few caps out of the main file. Behavior-identical: re-exported as |
| `src/server/game/craft.zig` | R | Crafting and workstation helpers, extracted verbatim from game.zig: tryCraft/tryCraftRecipe (InvTx craft op), tickWorkstations (burn/craft + |
| `src/server/game/deco.zig` | R | Deco helpers extracted verbatim from game.zig (purest game.zig shard). Species resolution, multiblock dim cache, mirror into block store |
| `src/server/game/guard.zig` | Z | Guard/evidence helpers extracted from game.zig |
| `src/server/game/harness.zig` | R | In-process test and scenario helpers for joined clients, packet injection, replication, and direct world setup. Production networking does not use |
| `src/server/game/hooks.zig` | R | ECS hooks: sim callbacks that read Game / World state. Verbatim move from game.zig — thin wrappers remain there as `ctx: ?*anyopaque` adapters |
| `src/server/game/init_assets.zig` | R | Asset loading for Game.init — extracted verbatim from game.zig. Takes *Game and InitOptions, mirrors the original inline sequence so the |
| `src/server/game/init_world.zig` | R | Post-asset init: sleeper volumes, network listen, seed entities, power demo. World-store initialization and persisted-world restoration for `Game.init |
| `src/server/game/join.zig` | R | Join-bundle encoders and senders. Helpers take `*Game`; `game.zig` exposes forwarding methods where the main state machine needs method syntax |
| `src/server/game/lifecycle.zig` | R | Shutdown ordering for Game: flush every store, then tear down subsystems. Player persistence lives in server/persist.zig; callers go there directly |
| `src/server/game/locks.zig` | R | Lock helpers extracted from game.zig — pack/unpack + slot bookkeeping |
| `src/server/game/loot.zig` | R | Loot / item-table helpers — extracted verbatim from game.zig. ecsIdFromItemName, loot bags, and loot-spawn broadcasts |
| `src/server/game/movement_helpers.zig` | R | Movement envelope helpers extracted from game.zig. Power-grid trigger activation and horizontal speed envelope |
| `src/server/game/net.zig` | R | Net send path for Game: reliable-window pump, framed fan-out, and the broadcast helpers | Pre-auth challenge is CSPRNG-derived (stock Guid.NewGuid, asm.il 852999); per-connection accept-path init only sendGameBudget deflates the stock get_Compress()=true set (Chunk/ConfigFile/IdMapping/SignDataResponse)
| `src/server/game/net_handlers.zig` | R | Net ingress extracted from game.zig — onConnected / onData / dispatchGamePayload. Verbatim bodies; game.zig keeps one-line forwarders | PlayerDenied after PackageIds for deferred join rejects (banned)
| `src/server/game/player.zig` | R | Player progression / gamestage / XP — extracted from game.zig; helpers take *Game. **Loot stage partial (2026-08-12):** `lootStageOf` is level-driven only — the stock `EntityPlayer.GetLootStage` (loot-economy.md 8, IL=184) POI-tier and biome terms (`POITierMod` x `POITierLootStageModifier`, biome `LootStageMod/Bonus` x `BiomeLootStageModifier`, passive **159** scale, GameStats **66** clamp) are pending the loot/POI tables; `partyLootStage` = `GetHighestPartyLootStage` high-water mark (implemented, stock-shaped). |
| `src/server/game/quest.zig` | R | Quest helpers — journal snapshots + trader offers + POI quest events. Extracted from game.zig; helpers take *Game (called as game_quest.foo(g, …)) |
| `src/server/game/rate_limits.zig` | Z | C2S rate limits extracted from game.zig. Inv/block token buckets, damage burst, chat gap |
| `src/server/game/replicate.zig` | R | Serialize-once replicate fan-out extracted from game.zig. Verbatim move — called via forwarder in game.zig |
| `src/server/game/replicate_health.zig` | R | Health replicate path — extracted verbatim from game.zig. Thin forwarder keeps callers unchanged |
| `src/server/game/rescue.zig` | R | Deep-void rescue extracted from game.zig |
| `src/server/game/send_extra.zig` | R | Framed send helpers extracted from game.zig |
| `src/server/game/session_drop.zig` | R | Client slot teardown extracted from game.zig |
| `src/server/game/sleeper.zig` | R | Sleeper-volume scan + spawn extracted from game.zig |
| `src/server/game/social.zig` | R | Buff + party/ally helpers extracted from game.zig (verbatim bodies) |
| `src/server/game/stability.zig` | R | Stability helpers extracted verbatim from game.zig |
| `src/server/game/step.zig` | R | Main tick step — extracted verbatim from game.zig. `Game.step` and helpers that are only called from the step. The quest reward payout skips ischosen rewards (stock CloseQuest null rewardChoice; the pick rides the client inventory sync, RE quests-challenges.md 2026-08-26) |
| `src/server/game/tests.zig` | R | Game integration tests: peerIpKey, player persist, claims, evidence, etc. Bodies are verbatim copies from src/server/game.zig (kept as integration tes |
| `src/server/game/map.zig` | R | In-game minimap: MapChunks window send + per-chunk 256 RGB555 colors (CalcChunkColors -> Block.GetMapColor -> atlas color -> ToColor5; water = BlockLiquidv2.Color) and the 6 s PersistentPlayerPositions player-marker broadcast. RE: `../7dtd-engine-research/docs/texture-atlas.md`, `protocol-packages.md §3.3` + PersistentPlayerPositions |
| `src/server/game/tick.zig` | R | Tick orchestration — extracted from game.zig; helpers take *Game. Bodies are verbatim copies from src/server/game.zig (stock asm.il comments kept) |
| `src/server/game/trader.zig` | R | Trader helpers extracted verbatim from game.zig |
| `src/server/game/trader_wire.zig` | R | Trader wire helpers extracted from game.zig. stockEntries + sendTraderSnapshot + handleTrade + applyTraderDataCopyFrom |
| `src/server/game/types.zig` | R | Game-owned types extracted from game.zig: InitOptions, defaults, LandClaim, Client. Canonical definitions live here; game.zig re-exports them so exist |
| `src/server/game/vehicle.zig` | R | Vehicle seat + positions S2C helpers — extracted verbatim from game.zig. seatRider / unseatRider (NetPackageEntityAttach) and the periodic |
| `src/server/game/wasm_host.zig` | R | Wasm host shims for Game — callbacks the plugin layer calls back into. Extracted verbatim so game.zig keeps only a re-export |
| `src/server/game/weather.zig` | R | Weather S2C helpers — extracted verbatim from game.zig. anyEnteredClient, the NetPackageWeather body builder and its send paths |
| `src/server/game/world.zig` | R | Domain — extracted from game.zig; helpers take *Game World / claims / block meta / locks. Bodies copied verbatim from game.zig |
| `src/server/guard_policy.zig` | Z | P4 guard policy: what the server *does* with detector evidence. |
| `src/server/mcp_transport.zig` | Z | MCP transport bridge (ADR 0031): HTTP listener + token auth + frame/response copy for the MCP plugin guest. Protocol from the public MCP spec (modelcontextprotocol.io, JSON-RPC 2.0), no stock code |
| `src/server/mode.zig` | Z | Gamemode = config pack (+ optional static plugin flag). ADR 0010 step 3. Data-only TOML under modes/<name>.toml. No script VM |
| `src/server/movement.zig` | R | Horizontal movement envelope: max speed over server dt, clamp to last good. No heap; pure math for PosAndRot / RelPosAndRot C2S |
| `src/server/persist.zig` | Z | Save/restore for zdtd-owned persistence: players.zsv (ZPV9), entities.zen (ZENT1), claims.zlc (ZCL1), clock.zcl, weather.zwt (ZWTH1), traders.zst (ZTR1: per-trader stock keyed by trader name, entries by item name so AssignIds version drift fails closed) and the chunk. **ZPV6 (2026-08-21):** journal entries persist the quest name (the stock Quest.Write identity - RE: quests-challenges.md; the saved quest resolves by name on restore, so a quests.xml edit cannot reshuffle it), the accepted POI rect (stock PositionData[2/3]) and per-objective progress (stock BaseObjective.Write per-objective CurrentValue). **ZPV7 (2026-08-22):** the inventory slot record widens 7 -> 11 bytes by appending `use_times` (stock ItemValue.UseTimes, f32) so tool durability survives a relog; v2-6 files still read and upgrade in place (slots widened with zero use_times, journals re-encoded as before). **ZPV8 (2026-08-22):** the progression tail adds the player's current `hp` (0..max, restored on the post-spawn pass) so a relog keeps wounds instead of a free full heal; v2-7 tails migrate with a -1 sentinel (spawn full health stands). **ZPV9 (2026-08-22):** the tail adds the game-stage born world time (u64) so days-alive survives a restart; v2-8 tails migrate with a zero born time (pre-ZPV9 behavior). **ZWTH1 divergence (2026-08-12):** the stock WeatherManager blob (weather-environment.md 6, byte-exact-verified: version u16 4 + gate byte + per biome 40 B = id u8 + weather group u8 + stormWorldTime i32 + stormDuration i16 + nextRandWorldTime i32 + 5 params [T,P,C,W,F] + rain f32 + snow f32) is NOT the format ZWTH1 writes - zdtd's own 49 B/state layout omits the rain/snow floats and uses i64 times + an explicit storm_state/has_storm, and it lacks the stock version u16 + GamePrefs-60 gate. Behavioral fields map 1:1 (stormWorldTime/Duration/nextRand, group index, 5 params). |
| `src/server/phase_gate.zig` | R | Per-package C2S phase allowlist (join SM × package name). Hot path: string compares against static tables; no heap |
| `src/server/replicate_te.zig` | R | Tile-entity replication: the S2C wire out for workstations, storage containers, vending machines and powered blocks |
| `src/server/root.zig` | Z | Server process layer: Game orchestration, config, admin/GSI TCP, scenarios. |
| `src/server/scenarios.zig` | Z | Integration scenarios: two-peer motion, damage wire kill, setblock replicate, persist restart. These call shipped Game handlers (onData/handlePackage/ |
| `src/server/serverinfo_tcp.zig` | R | Stock ServerInformationTcpProvider: TCP on ServerPort serves GameServerInfo text. |
| `src/server/webui.zig` | Z | Operator web UI HTTP listener (WU0–WU2: dashboard + console cmds + /api/logs.json log console). Loopback by default; shared secret required when enabled |
| `src/server/zdtd_config.zig` | Z | zdtd.toml: operator tunables (Bucket B), not stock serverconfig. Precedence (applied by caller): CLI > env (webui secret) > world/zdtd.toml > |
| `src/util/arena.zig` | Z | Lazy/eager scratch-arena helpers shared by asset table loaders. |
| `src/util/clock.zig` | Z | Monotonic nanoseconds and best-effort sleep. |
| `src/util/io_fs.zig` | Z | Thin wrappers around Zig 0.16 `std.Io` for one-shot FS ops. Ordinary file/dir work goes through here or `std.Io` directly, never |
| `src/util/log.zig` | Z | Leveled logging (debug/info/warn/err/crit on the stock Log.Level 0..4 ladder) plus a fixed ring of recent lines served to the webui log console (/api/logs.json). |
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
| `src/wire/stock_party.zig` | R | NetPackagePartyActions (ToServer) + NetPackagePartyData (ToClient) bodies (RE ../7dtd-engine-research/docs/parties-factions.md §3) |
| `src/wire/stock_quest.zig` | R | Stock quest journal + NPCQuestList QuestPacketEntry wire (V3.x). Matches QuestJournal.Write v5, Quest.Write (FileVersion 8), and |
| `src/wire/stock_sign.zig` | R | Stock NetPackageSignDataResponse body builder (prefab sign libraries). Entry data (`SignEntry`, catalog load) lives in assets/signs.zig; only the |
| `src/wire/stock_te.zig` | R | Stock V3.1.0 NetPackageTileEntity payload for composite storage (network modes). |
| `src/wire/stock_xp.zig` | R | NetPackageEntityAddExpClient body (ToClient XP grant; RE ../7dtd-engine-research/il/netpackages-v3.1.0/NetPackageEntityAddExpClient_il.txt) |
| `src/wire/te_types.zig` | R | Stock TileEntityType enum values (RE: TileEntityType / network TE discriminant). Named constants only; not loaded from XML (engine enum, not game data |
| `src/world/biomes.zig` | R | Load stock `biomes.png` (RGBA8 non-interlaced) for chunk biome ids. PNG pixels = biomemapcolor RGB keys (biomes.xml), NOT biome ids |
| `src/world/chunk_flush.zig` | Z | Async chunk flush: encode on the tick thread, write on one background thread. |
| `src/world/containers.zig` | Z | World-position keyed loot containers (block TE storage). `max_containers` 4096 + world-container eviction (2026-08-21): Navezgane-scale maps have thousands of loot containers; when the table is full, getOrCreate reuses a non-player-placed container (regenerated deterministically from the next chunk scan) and never evicts a player-placed chest |
| `src/world/deco_mirror.zig` | R | Mirror placed decorations into the server block store, so collision, harvest and chunk streaming agree with what the client renders |
| `src/world/dem.zig` | R | Copernicus GLO-30 DEM codec: COG header parse, tile decode, S3 object key and elevation-to-block mapping (fuzz-covered in src/fuzz.zig). The S3 |
| `src/world/dtm.zig` | R | Stock 7DTD baked heightmap loader (Navezgane / Pregen*). |
| `src/world/noise.zig` | Z | OpenSimplex2-family gradient noise (clean-room) + fBm / ridged / domain warp. Pure functions of (seed, coords): no global RNG. Same seed+coords always |
| `src/world/prefabs.zig` | R | Stock world prefabs.xml index + footprint stamping on heightmaps. Block paint: stock `.tts` via `tts.zig` (Prefab.readBlockData raw types), |
| `src/world/root.zig` | Z | World store layer: chunks, map data (DTM/prefabs/TTS), containers, TE state. |
| `src/world/nav.zig` | Z | Coarse walkability grid + BFS pathfinding for bots. Borrowed in spirit from the Recast/Detour navmesh used by Unvanquished bots (see `../7dtd-fps-bots/docs/oss-fps-bot-survey.md`): host owns geometry, wasm guest owns decisions. |
| `src/world/sleepers.zig` | R | Prefab sleeper volumes: parse XML + wake/spawn on player enter. **Re-arm (2026-08-26):** `respawn_time`/`spawned_alive` per volume, the ZSTG1 v2 respawn_time tail (backward-compatible load), and the ClearedUpdate-equivalent (stock ClearedUpdate IL=33 + CheckTrigger IL=136: respawnTime = worldTime + LootRespawnDays x 24000 ticks after the group dies; a later player entry re-arms). **ZSCL1 (2026-08-21):** quest-cleared volume rects persist in `sleepers_cleared.zsc` (a completed ClearSleepers quest suppresses its POI's volumes, stock QuestEvent_SleepersCleared removes the POI's sleeper data; the marker stops re-arm on re-trigger and restart) |
| `src/world/stability.zig` | R | Stock block stability plane and falling-block trigger (RE: `../7dtd-engine-research/docs/stability.md`, dumps 2026-08-06) |
| `src/world/sky.zig` | R | Stock SkyManager day/night model (RE `../7dtd-engine-research/docs/entity-ai.md` SkyManager pin 2026-08-26): TimeOfDay, UpdateSunMoonAngles sun target, CalcDayPercent curve, GetLightLevel ambient term. Slice 1 of the clone-side world-light model (block light / moving lights / moon / shade recorded as later slices) |
| `src/world/store.zig` | R | Authoritative block world: 16×256×16 columns, DTM heights, ZCH3 disk (.zch). v3 magic ZCH3: heights + optional u32 rawData + optional texture/density |
| `src/world/subbiome_noise.zig` | R | Stock subbiome noise for deco placement (GAP_ANALYSIS 18): a clean-room port of `PerlinNoise` + `WorldBiomeProviderFromImage::GetSubBiomeIdxAt`, so |
| `src/world/terrain_snapshot.zig` | R | Read-mostly terrain footing snapshot for the A* inner loop. |
| `src/world/tts.zig` | R | Stock prefab `.tts` block paint (Prefab.readBlockData, V3.x file version 19). |
| `src/world/vending.zig` | Z | World-position keyed vending machine tile entities (TileEntityVendingMachine). |
| `src/world/light_te.zig` | R | Prefab `.tts` Light (18) TE persistency payloads (RE TileEntityLight.read IL=68 + TileEntity.il base read): parsed intensity/range/Color32/type/angle/shadows into a world store; the network body lives in `wire/stock_te.zig` (tile-entities-power.md TileEntityLight.write). |
| `src/world/water.zig` | R | Stock water_info.xml point sources (used as local water-table hints); the leveling queue backing the dig-leveling pour (zdtd-owned, GAP water flow PARTIAL) |
| `src/world/weather.zig` | R | Stock WeatherManager storm / bloodMoon state machine, server side. Live-verified 2026-08-12: stock `weather` telnet dump shows the 5-slot param vector (Temperature/Precipitation/CloudThickness/Wind/Fog) per biome, `default` group, no storms in the day-1 grace (worldTime < 22000), and `weather clouds N` drives forceClouds (value/100) -> GetCloudThickness. |
| `src/world/weather.zig` storm schedule | R | `update_interval_ticks = 5` matches stock `BiomeWeather.ServerTimeUpdate` cadence; storm_state 0/1/2 (clear/stormbuild/storm) matches stock `BiomeWeather.stormState`. |
| `src/world/workstations.zig` | Z | World-position keyed workstation state (forge/campfire/workbench TE 12). Slots mirror TileEntityWorkstation arrays; craft tick advances the queue |
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
| `Difficulty.*` | 1.0 (all), `incoming_damage_2` 0.75 | R | `ItemActionAttack.difficultyModifier` mixed-control PvE scalers (combat-damage.md): server/AI→client × `IncomingDamage`, client→server × `EntityIncomingDamage` (client-side in stock; server trusts the claimed strength, ProcessPackage IL=172). Adventurer 0.75 pinned to the shipped serverconfig sandbox-code decode (sandbox-options.md 246-258); full 0..5 ladder awaits the SetupOptions Cecil extraction (research-repo 2026-08-25) |
| `Progression.*` | see fields | Z | **Invented placeholders** (WORK_PLAN T16); stock ships survival from buffs.xml `buffStatusHungry01-03` / `Thirsty01-03` damage + `FoodChangeOT`/`WaterChangeOT`/`HealthChangeOT`/`StaminaChangeOT` + items.xml `StaminaLoss` |
| `Sky` day boundary (`clock.dawn`/`clock.dusk`) | 4 / 22 | R | `GameUtils::CalcDuskDawnHours(DayLightLength)` via the world clock (IL=45, weather-environment.md; the stock DayLightLength 18 → dawn 4 / dusk 22); bounds of the `UpdateSunMoonAngles` day window (RE: entity-ai.md SkyManager pin 2026-08-26) |
| `Ai.crouch_sleeper_detect_min/max` | 3 / 15 | R | `PlayerStealth.CanSleeperAttackDetect` FastLerp bounds (IL=20; entity-ai.md); t = `lightAttackPercent` = passive-89 when selfLight (held-item light) < 0.1 (TickServer IL_010B) |
| `Ai.sight_light_threshold_min/max` | 30 / 100 | R | `CanSeeStealth` threshold floor pair (IL=21; the stock `EntityClass` cctor default; `zombieTemplateMale` overrides to -2,150 in entityclasses.xml, parsed per class) |
| `Ai.stealth_light_passive` | 0.89 | R | `PlayerStealth.TickServer` passive-89 fold for `lightAttackPercent` when the player's selfLight (held-item light) < 0.1 (IL_010B; entity-ai.md) |
| `world/sky.zig` day curve / ambient | 0.6 / 0.68, `^0.6 × 0.5` | R | `SkyManager.CalcDayPercent` (IL=54) + `LightManager.GetLightLevel` ambient term (IL=117); slice 1 collapses `AmbientTotal` to the day curve (block light / moving lights / moon / shade recorded as later slices) |

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
| `world/weather.zig` storm/blood-moon | — | R | RE: weather-environment.md (server-authoritative storm state machine) |
| `ecs/poi_lock.zig` `unlock_grace` | 2000 | R | QuestEventManager `PrefabInstance.lockInstance` (QuestLockInstance, asm.il 1001892+) |
| `ecs/party.zig` | max 8, flat XP | R | Party max 8 per parties-factions.md §2; NOTE the stock shared-XP reduction `startingXP*(1-0.1*inRange)` is NOT yet implemented - zdtd grants flat XP with the XPMultiplier only (partial) |
| `world/stability.zig` | — | R | RE: stability.md (StabilityInitializer spread/clear, GetBlockStability BFS) |
| `server/game/constants.zig` | caps | R | Game-wide caps; behavioral subset tracked in GAP_ANALYSIS (B31-B37) |

### 3.8 Additional behavioral constants

| Constant | Value | B | Stock source |
|---|---|:-:|---|
| `assets/gamestages.zig ticks_per_day` | 24000 | A | Stock sim day length (24000 ticks @ 20 TPS); gamestages.xml stage math uses it |
| `ecs/electric.zig default_trigger_pulse_s` | 0.5 | R | Trigger pulse width (RE: PowerItemTypes; tile-entities-power.md) |
| `ecs/party.zig max_party_members` | 8 | R | Stock party cap (RE: parties-factions.md §2) |
| `world/weather.zig blood_moon_storm_push` | 5000 | R | Blood-moon storm push ticks (RE: weather-environment.md storm state machine) |
| `world/weather.zig update_interval_ticks` | 5 | R | Weather update cadence (RE: weather-environment.md) |
| `assets/entities.zig attack_task_names` | 1 name | A | Stock AI task enum attack-capable tasks (V3.1.0 b14 entityclasses.xml ships only ApproachAndAttackTarget; timid animals carry no attack task, so ai_attack gates approach_attack off for them) |
| `ecs/quest.zig max_phases` / `max_reward_flags` / `max_actions` / `max_quest_events` | 32 / 16 / 8 / 4 | Z | Quest array caps (audit B34; stock quests.xml data is loaded, these bound the sim tables; the stock file carries one `<event>` block) |
| `ecs/quest.zig builtin_objective_kinds` | 23 rows | A | The stock objective `type=` family (RallyPoint, ClearSleepers, EntityKill, AnimalKill, Fetch\*, TreasureChest, InteractWithNPC, ReturnToNPC, RandomGotoNPC, Craft\*, StayWithin\*, POIStayWithin, \*BlockActivate, Goto\*) -> executable PhaseKind, mirrored from stock BaseObjective; overridable/extendable via `[quests] objective_kinds` (assets/quests.zig parseObjectiveKinds) so a new stock type is config, not code (ADR 0021). `Goto id="trader"` special case is a hardcoded game fact |
| `ecs/quest.zig QuestPolicy` default_kill_count / kill_per_tier | 3 / 2 | Z | **zdtd-owned** approximation for kill objectives with no explicit count (stock ClearSleepers counts the POI sleeper volume at runtime, audit B25); phase target = `default + tier*kill_per_tier`. Config: `[quests]` |
| `ecs/quest.zig QuestPolicy` goto_radius / stay_radius | 4.0 / 8.0 | Z | **zdtd-owned** fallbacks when an objective omits its distance (stock ObjectiveGoto::distance parsed from `value` wins when present). Config: `[quests]` |
| `ecs/quest.zig` QuestTag bits + tagsMask / objectiveTag / prefabMatches | 10 tags | R | Stock tag strings (QuestEventManager statics IL_0024-0088 + ObjectiveFetchFromContainer hidden_cache) and the BaseObjective.SetupQuestTag objective map; Prefab.GetQuestTag = questTags.Test_AllSet. RE: 7dtd-engine-research quests-challenges.md "Quest POI selection" |
| `server/game/hooks.zig` questPoiSelectAt constants | 1000 / 4e6 / 50 / 500 / 1500 / 4096 | R | Stock selector bounds: min/max squared distance (ObjectiveRandomPOIGoto.GetPosition IL_019C-01A1), 50-attempt loop (GetRandomPOINearWorldPos IL_0202), trader bands 500/1500 (SetupTraderPrefabList IL_0085/009E); 4096 = zdtd tier-pool stack cap |
| `server/game/hooks.zig` questSpawnGsEnemy placement | 12 m + 12 m | R | QuestActionSpawnGSEnemy.SpawnQuestEntity: player position + random unit direction × (12 + RandomFloat*12); count range from the action's `count` property; entity from the gamestage list's stage-0 spawn group (QuestActionSpawnGSEnemy.il.txt) |
| `game/bot.zig BotHostConfig` shoot_damage / headshot_multiplier / spawn_spread / spawn_y / max_step_up | 12 / 2 / 2 / 70 / 1.5 | Z | Host-side bot policy (ADR 0026): damage floor (from old `ecs/command.zig` host), headshot multiplier (clanker `HeadshotMultiplier` parity), spawn spread + default Y, move step-up cap. Config: `[bots]` (ADR 0021). `bot_max_hp` 100 is the wasm guest contract, not config |
| `world/worldgen.zig` base_height / height_amp / squash / noise_weight / y_scale / bedrock_h | 68 / 24 / 28 / 0.85 / 2.0 / 3 | Z | **zdtd-owned** procedural flat-world shaping params (the DTM-backed stock maps override them). Kept as algorithm constants: the values are coupled to the density-field invariants (e.g. overhang %, bedrock), not operator policy — documented, not config |
| `game/craft.zig vehicle_fuel_max` / `vehicle_refuel_reach` | 100 / 3.0 | Z | **zdtd-owned** vehicle tank cap + refuel reach (no vehicle.xml loader yet; stock fuel capacity is per-vehicle entity data). Documented, not config until the stock data loader lands |
| `ecs/systems.zig dmg_scale` | 100 | Z | Fixed-point damage accumulator scale (atomic-friendly); structural, not policy |
| `ecs/systems.zig` TickServer light consts (`stealth_crouch_light_scale` 0.6, `stealth_light_passive_blend_a` 0.32, `stealth_light_passive_blend_b` 0.68, `stealth_light_level_max` 200, `stealth_self_light_dark` 0.1, `stealth_speed_visibility_scale` 0.15) | 0.6 / 0.32 / 0.68 / 200 / 0.1 / 0.15 | R | `PlayerStealth.TickServer` IL=432 exact chain (crouch x0.6 IL_00A6; the (0.32 + 0.68 x passive89) x 100 fold IL_0121-013F; FastClamp 0..200 IL_0140-014A; selfLight < 0.1 IL_010A; speedAverage x 0.15 IL_00CD) |
| `world.zig` sleeper wake roll defaults (`sleeper_wake_near_min_default` -40, `sleeper_wake_near_max_default` 5, `sleeper_wake_far_min_default` 340, `sleeper_wake_far_max_default` 480) | -40 / 5 / 340 / 480 | R | Stock zombieTemplateMale `SleeperSightToWakeMin/Max` (entityclasses.xml); the fallback roll ranges for a sleeping class with no sleeper wake props (RE entity-ai.md D8.6 step 5) |
| `ecs/aidirector.zig` wander_start_after / min_gap / max_gap, wandering_horde_size / spawn_dist, heat threshold / check / cooldowns / scout_dist | 28000 / 12000 / 24000 / 6 / 92 / 25 / 5 / 120 / 60 / 10 | R | AIDirector policy (RE: aidirector.md - horde spawn offset `RandomOnUnitCircle * 92f` IL_018B; horde schedule 12000-24000 world ticks; chunk-heat map asm.il 414504-415200; horde size is a fixed approximation of the gamestage-group-driven stock). Config: `[rules.director]` (ADR 0021). `heat_region_world`, `max_heat_regions`, `heat_scout_count` stay structural; `heat_event_ticks` (720) and `heat_feral_chance` (0.2) are live rules (2026-08-27): the heat-event duration stamps craft.zig notifyActivity and the feral roll doubles the cooldown (aidirector.zig, `heat_feral_cd_mult`) |
| `game.zig isStockClientQuestName` prefix gate | quest_/tier/intro_/test_/challengegroup_reward_/treasure_ | A | Stock client quest-name families (client catalog proxy; a stock_xml catalog passes by construction, audit B28) — code gate, not tunable |
| `assets/quests.zig objectiveScore` | 10..100 | Z | Phase "meat" pick heuristic for shared phases (ClearSleepers 100 .. unknown 10) — not a stock table; only affects which objective drives a phase when several share it |
| `game/tick.zig tickAirDrop` | every N game-hours | Z | **Diverges**: stock schedules by day-count + fixed time-of-day (`SetupAirDropTimeRanges` IL=124 maps options 52/54 -> day-counts + TOD, `calcNextAirdrop` IL=39; default 3/3 days at 12:00; aidirector.md airdrop schedule, live-verified 2026-08-11). Also stock AirDropFrequency=0 does NOT disable (option default overrides the 0 pref) |
| `game/sleeper.zig` sleeper spawn | no global cap | Z | **Diverges**: stock `SleeperVolume.UpdateSpawn` gates every restore on `AIDirector.CanSpawn(2.1f)` = `EnemyCount < MaxSpawnedZombies * 2.1` (spawning.md, live-verified 2026-08-11); zdtd's sleeper spawn bypasses the cap (the volume count is group/255-capped only). Wake/stage radius is `[sim] sleeper_party_radius` (default 100 m, `CalcGameStageAround` asm.il ~1093363) vs stock volume-box + party stage |
| `ecs/systems.zig traderRestock` | day-based | Z | **Simplifies**: stock `TraderManager` restocks on a tick-based `ResetIntervalInTicks` with a boundary snap (loot-economy.md 3); zdtd restocks on a day counter (-1 never, 0 daily, N>0 every N days) |
| `world/worldgen.zig water_surface_cell` | 62 | R | RE `Block.cWaterLevel` = **62.88** (Block cctor `ldc.r4 62.88`, stock_facts `world_water_level`); the RWG water table fills cells 0..62 and the surface cell is world-constant so chunks cannot seam |
| `world/store.zig` leveler pending_cap / pour budgets | 256 / 4 / 128 | Z | **zdtd-owned** dig-leveling queue cap + per-tick drain/spread budgets (stock is the jobified mass-flow sim, light-mesh-water.md §4 - not ported). Config: `[rules.water]` (ADR 0021) |
| `ecs/aidirector.zig bloodmoon_budget_scale` | 1.9 | R | `AIDirector::CanSpawn(1.9f)` (asm.il:413528) - the 1.9x blood-moon ceiling over MaxSpawnedZombies |
| `ecs/aidirector.zig` WorldClock bm schedule (bm_cycle / bm_day_last / next_bm / bm_freq / bm_range) | persisted | R | Stock `CalcNextDay` (asm.il 412880): `nextBM = bmDayLast + frequency + RandomRange(0, range+1)`, persisted with the clock (ZCL2) so the red moon stays on the horde night across restarts and day jumps |
| `wire/packages.zig cF_crouching` | 0x0200 | R | Stock EntityFlags `IsCrouching` bit 512 (protocol-packages.md 5.5.6); the sim reads it for the stealth sense gates |
| `ecs/components.zig falling_group_cap` | 32 | Z | **zdtd-owned** falling-block group cap (stock `GroupBounds.IsWithinSize` clamps groups but the bound is not IL-pinned); larger collapses keep the first 32 cells - the rest still air out |
| `max_claimed_explosion_radius` | 6.0 | R | `server/c2s/blocks.zig` cap on C2S-claimed explosion radii (block + entity): largest stock ExplosionData.EntityRadius is 6 (entities.xml `explosion` on cop/feral: radius_blocks 5, radius_entities 6); a forged blob must not carve the whole map or damage every loaded entity (2026-08-27) |
| `fatal_kill_amount` | 9999 | Z | `server/c2s/misc.zig` **zdtd-owned** honored-`fatal` kill amount vs NPC kinds: stock fatal damage is client-computed; the server honors the flag only against zombies/animals with an amount far above any sim NPC class HP (max class hp 1600; the 9999-HP trader class is excluded by the zombie/animal gate) (2026-08-27) |

### 3.9 Divergence register (provenance for the differences)

Places zdtd does **not** reproduce stock values today. Each row states the
stock source and the tracking item. Finding ids refer to the hardcode audit
(the live `docs/reviews/HARDCODE_AUDIT.md` copy was removed from the repo on
2026-08-23; the archived snapshot `archive/HARDCODE_AUDIT_2026-08-08.md`
survives, see §3.10 for its caveats) unless noted.

| Location | zdtd value | Stock value (source) | Sev | Tracking |
|---|---|---|---:|---|
| `ecs/aidirector.zig` heat cooldown | 120 s / 60 s | `AIDirectorChunkData` 240 s / 180-720 s (aidirector.md) | P2 | GAP_ANALYSIS (not in live audit) |
| `server/game/trader.zig` sell | econ × EconomicSellScale × SellMarkdown × qmod / bundle | stock `XUiM_Trader.GetSellPrice` = econ × EconomicSellScale × SellMarkdown (loot-economy.md §5) | P1 | **Fixed 2026-08-27** (live A29 closed): `items.xml` EconomicSellScale + EconomicBundleSize parsed (`trader.zig:180-206`), quality mod + bundle divide applied |
| `ecs/world.zig` class_table row `zombieFeral` | builtin (hash = zombie hash) | no stock class (0 hits entityclasses.xml) | P3 | not in live audit; tracked in GAP_ANALYSIS |
| `ecs/inventory.zig` armorMitigation | quality-curve PhysicalDamageResist/ElementalDamageResist sum | `items.xml` PhysicalDamageResist/ElementalDamageResist tier ranges + quality jitter | P1 | **Fixed 2026-08-27** (live A35 closed): `items.xml` passive 41/42 quality curves parsed (`items.zig:855-861`, e.g. armorPrimitiveHelmet "8,12.3"), summed at quality through the passive VM; TargetArmor penetration applies |
| `ecs/rules.zig Progression.*` base depletion | policy tunables | stock survival damage from buffs.xml `buffStatusHungry/Thirsty*` + `FoodChangeOT`/`WaterChangeOT`/`HealthChangeOT` | P3 | live A31 fixed (T16); base rates stay policy |
| `world/tts.zig:418` filler skip | comptime pins | AssignIds `terrainFiller`/`terrainFillerAdaptive` (dump 2/3) | P3 | live A05/A06 class (Fixed); pin uses tracked |
| `world/store.zig:310-313,370` no-blocks fallback | module pins | AssignIds terrain names | P3 | live A05 (Fixed); fallback pins tracked |
| `litenet/packet.zig` max_packet_size | 1327 | game `NetConstants.MaxPacketSize` = 1432 (PossibleMtu last entry, RVA-decoded; network.md §4) | P2 | divergence: matches no stock MTU entry; conservative but breaks stock MTU negotiation shape |
| `world/store.zig` sea_level | 64 (u8) | stock `WorldConstants.WaterLevel` = `Block.cWaterLevel` = **62.88** (IL: Block.cctor ldc.r4 62.88; pinned as `stock_facts.json behaviour.world_water_level`, machine-checked) | P3 | divergence: +1.12 and u8 cannot hold the fraction |
| `server/game/init_world.zig` ambient seeds | 11-12 entities at join (`listents`): 6 POI traders + 3 seed zombies/sleeper + 1 animal + 1 vehicle + 1 turret | stock spawns lazily: `listents` = players only (1-3) at join, animals/zombies later via AIDirector near players, traders on POI load | P3 | known divergence from SUT join-probe 2026-08-12 (7dtd-loadgen compare-sut); not in live audit |
| `ecs/aidirector.zig` WorldClock rate | flat 0.39-0.44 game-min/s (DayNightLength 60 -> `seconds_per_hour` 150) | stock measured 0.33-0.37 game-min/s, Day 1 07:00-07:07 across 3 runs (DayNightLength 60 live stat; clock scaling differs from flat) | P2 | known divergence from SUT join-probe 2026-08-12 (7dtd-loadgen compare-sut, 3 runs); not in live audit |
| C2S payload decode (litenet/net.zig) | `payload failed error=Overflow n=1` on EVERY pregen world (1/join); join FAILS on Pregen06k01, recovers on Pregen06k02/08k01/08k02 | stock joins all pregen worlds cleanly (0 overflows) | P1 | open bug from SUT world matrix 2026-08-12 (7dtd-loadgen compare-worlds, 5 worlds); not a deliberate divergence |
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
| XP/level/gamestage math | RE: `../7dtd-engine-research/docs/progression.md` (AddLevelExp → recursive level-up → skill points → RefreshPerks); `src/server/game/player.zig` |
| Perk requirement graphs / effect application | **Not built yet**: planned as `docs/adr/0023-perk-attribute-system.md`; zdtd has no perk system, so no provenance claim is made until the ADR lands (rules.zig `Progression.*` are placeholders, WORK_PLAN T16) |

| B38 | `world/sleepers.zig:10` (8192), `litenet/server.zig:8` (64), `util/parallel.zig:7-9` (8/24) | Fixed-size architecture caps | zdtd engineering (Z), documented as fixed-size architecture |
| B39 | `game.zig:3969` + `game/sleeper.zig:13` | `sleeper_party_radius=100.0` duplicated | R: CalcGameStageAround radius (asm.il ~1093363); dedupe tracked P3 |
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
| `bot.bot_spawn_spread` / `bot_spawn_y` | 2.0 / 70 | Z | zdtd-owned `[bots]` config defaults (ADR 0026 host policy knobs; `spawn_spread`/`spawn_y` binder keys) |
| `bot.sense_kind_bot` | 2 | R | Sense contract kind tag for bots (RFC 0001 §3: 0 player, 1 zombie, 2 bot; the guest reads it in the ZBS3 records) |
| `bot.sense_kind_bot_info` | 4 | R | Sense record kind for the host-assigned weapon info row (RFC 0001 §3) |
| `systems.dmg_scale` | 100 | R | Fixed-point damage unit (1.0 hp = 100); the sim's internal damage integer |
| `worldgen.noise_weight` / `y_scale` | 0.85 / 2.0 | Z | zdtd-owned procedural worldgen shaping (non-goal #8; the demo fallback density field) |
| `sys_metrics.load_scale` | 65536 | Z | sysinfo load-average fixed-point fraction (16-bit); zdtd-owned metrics |
| `buffs.zig TrackedDeltas` / `effectTotals` | tracked surface | R | Revertible passive-effects VM: folds the tracked buffs.xml effect rows (Health/Food/Water/Stamina ChangeOT + max, resist percents) into additive deltas, recompute-from-set on the active BuffSet (stock EffectManager.GetValue fold; bounded: `max_buffs_per_entity`, no allocation). `perc_*` keep the raw XML fraction; `base_set` on tracked names is omitted (no per-entity base - recorded) |
| `buffs.zig survivalStages` / `stageBuffName` | 0.5 / 0.25 / 0.02 | R | buffStatusCheck01 StatComparePercCurrentToMax gates -> the conditional survival stage buffs (buffStatusHungry/Thirsty01..03); tickSurvival applies/removes them as state (relayed, HUD-visible) |
| `World.buff_phys_resist` | per-entity f32 | R | Buff-side PhysicalDamageResist percent cached by the survival tick (VM total); joins armorMitigation like stock GetTotalPhysicalArmorRating sums passive 41 |
| `progression.zig PerkDef/AttrDef.passives` | 649-row surface | A | progression.xml perk/attribute passive_effect rows parsed as data (self-closing attBooks/attCrafting bodies handled); the VM's tracked fold applies to them (trackedDeltasFrom) but application waits on the perk runtime (open, scorecard "Player progression") |
| `buffs.zig curveAt` / `max_curve_len` | 8 segments | R | passive_effect curve values (`value="v1,v2,..."`): segment i applies at level i+1, clamped past the end; stock perk/armor per-level curve semantics (`curve[0]` = the legacy flat value) |
| `progression.zig perkTotals` / `trackedDeltasAtLevel` | ledger fold | R | Level-scaled tracked deltas over purchased attribute/perk levels, same revertible VM surface as buffs (armor resist + HealthChangeOT wired; perk max-stat and stamina-OT consumers recorded) |
| `buffs.zig` triggered-effect engine | onSelf* rows | R | Full triggered surface parsed (trigger/action/stat/buff + nested StatComparePercCurrentToMax LT/GT gate); `evaluateTriggered` dispatches the bounded actions (ModifyStats/AddBuff/RemoveBuff) requirement-gated, no allocation; the survival stage selection runs through it (buffStatusCheck01 update rows). ModifyCVar/PlaySound/other actions recorded, not guessed |
| `apm` survival section / counters | per tick | Z | The survival/effects pass runs under the `survival` profiler section with `survival_players` / `vm_recomputes` counters (P4b): the per-player VM fold stays observable against the 50 ms budget |
| `items.zig` StaminaLoss | per item | A | items.xml StaminaLoss (base_set, first value) = the per-attack stamina cost; the landed-hit choke drains it x `[rules.combat] stamina_usage_multiplier` (RE ItemActionMelee IL). 2-value rows = normal/power pair (first used); negative quality-curve rows recorded |
| `buffs.zig` curve_levels / `curveValueAtLevels` | explicit anchors | R | The XML `level="a,b,..."` anchor pairs (progression.xml's dominant form, 640/649 rows): value[i] sits at level[i], piecewise-linear between, out-of-range applies nothing (stock PassiveEffect.ModValue IL=796); `curveAt` prefers the anchors over the implicit scaled-index fallback |
| `weather.zig` NetPackageWeather | per-biome params | R | The server's temperature input leg: per-biome weather groups (temperature ranges from biomes.xml) roll into the slot-0 param and ship on join + broadcast; the felt temperature and cold/hot buffs are client-computed in stock (weather-environment.md §4) - client-owned by design, not a server gap |
| `Health.base_max_hp` + the survival max-stat recompute | per player | R | The passive-effects VM's max-stat deltas apply revertibly: `max_hp = base_max_hp + deltas` recomputed every survival tick (base captured at spawn), hp clamps down on reduction; food/water/stamina maxes recompute from the 100 base. perkFortitudeMastery HealthMax level 5 = 200, revert to 100 |
| survival stamina-OT consumer | perc fraction of max/s | R | The VM's StaminaChangeOT total joins the idle regen (`value x max / 100` per second, the same conversion as the stage-3 penalty): perkRuleOneCardio level 5 adds 0.45/s on a 150 cap; the sprint branch keeps the stage-3 penalty |
| `chunk_fill.tryContainerSpill` | per break | R | A broken container spills its pre-filled contents into a loot bag at the block (all 449 blocks.xml LootList blocks are CompositeTileEntity containers; the eviction path already spilled, the break path dropped nothing). maxdamage.lootListFor resolves the LootList for the pre-fill |
| `persist.zig` ZPV11 skill tail | u32 + n×(len,name,lvl) | Z | players.zsv v11 (magic 'B'): skill_points + purchased attribute/perk levels survive a restart so the spend ledger and the level-scaled VM effects restore; v10 and older records carry with the empty tail, names re-resolve against the progression catalog |
| `buffs.zig curveValueAt` | Q1..Q6 | R | Stock passive value-curve evaluation (PassiveEffect.ModValue IL=796): piecewise-linear interpolation over Levels scaled so value[0] = Q1 and value[n-1] = Q6; the item effect level is the raw ItemValue.Quality (EffectManager.GetValue IL_0393); 6-value curves are per-quality (armorPreacherOutfit .02..15), 2-value curves interpolate (primitive/leather/iron/steel 8..12.3) |
| `items.zig` armor PDR/EDR parse | per-item curves | A | items.xml PhysicalDamageResist/ElementalDamageResist (passives 41/42) quality curves parsed per item and resolved through the Extends chain; `armorPdr` (server hook) feeds armorMitigation like stock GetTotalPhysicalArmorRating sums passive 41 |
| `items.zig` DegradationPerUse / TargetArmor | flat per item | A | items.xml DegradationPerUse (base_set, per-use durability wear; wired into degradeUse) and TargetArmor (perc_add, armor penetration; wired into armorMitigationVs at the damage chokes, RE GetTotalPhysicalArmorRating IL=47). The perk-tag-gated rows (perkJavelinMaster etc.) apply when the attacker owns the tagged perk - the tag is the perk name, checked at the choke. BlockDamage/StaminaLoss/HarvestCount/LootProb recorded with their exact choke reasons |
