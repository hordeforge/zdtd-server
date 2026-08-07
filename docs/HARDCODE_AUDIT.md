# Hardcode audit (Bucket A / B / OK)

Date: 2026-08-07 (update re-audit of the 2026-08-06 pass; prior pass
2026-08-04). Method: `docs/prompts/hardcoded-data-review.md` + systematic
`rg` / file reads against `src/`, stock `Data/Config`,
`docs/ASSETS.md`, `docs/GAME_OPTIONS.md`, `../7dtd-research/docs/loot-economy.md`.

## Executive summary

| Bucket | Open actionable | P0 open | P1 open | Notes |
|---|---:|---:|---:|---|
| **A** (stock data) | ~12 | 0 | 0 | A12 vehicle fallback + **A29 trader pricing** + A22 deco skew + A20 dukes fixed |
| **B** (zdtd policy) | ~14 | 0 | 0 | Stream/authority/feature/perf/sim/mode/plugin via `zdtd.toml`; A19 wallet configurable; open consts: AI bands, caps |
| **OK** | 30+ | - | - | Wire / RE / physics / offline pins / new T1-T6 stock constants / litenet + quest-wave OKs |

| Spot-check | Result |
|---|---|
| `default_gen_fuel` / `default_battery_cap` | **Gone** (power via maxdamage → `powerblocks.Resolved`) |
| `coin_item_id_default = 6` | **Fixed**: trade requires non-zero `ecsIdByName("casinoCoin")` |
| `max_streamed_chunks` / interest / edit caps | **On Game/InitOptions** + loaded from `zdtd.toml` (`src/server/zdtd_config.zig`) |
| `trader_wallet_dukes` | **Configurable** (`[sim] trader_wallet_dukes`); Game field used in ECD spawn / lock / snapshot paths |
| `water_mass_full = 19500` | **OK**: RE constant (WaterUtils GetStableMassBelow clamp; light-mesh-water.md §4) |
| `stock_default_stack = 0x1f4` | **OK**: ItemClass default when no property (asm.il:749089); XML per-item Stacknumber overrides |
| `class_npc_trader_jen` | **OK**: Unity hash computed from the stock name `npcTraderJen` |
| `loot_drop_prob` | **A OK**: loaded from entityclasses.xml `LootDropProb`; default 1.0 only when absent |
| `ObjectiveWireKind` | **OK**: Quest.Write subclass shapes (base/treasure_chest/empty); quests.zig classifiers read `type=` strings |
| `players.zsv` ZPV3 | **OK**: zdtd-owned save format (ADR 0011); not stock data, not operator config |
| trader stock list / hours / sell gate | **A clean**: per-trader `<trader_items>` refs via `npc.xml` trader_id; `open_time`/`close_time` gate (`worldTime%24000`), `allow_sell` gate, `is_vending` always-open; fallback `traderAlways` |
| **trader price/sell** (`econ/10`, `econ/50`) | **A29 P1**: invented ratios vs stock `EconomicValue × BuyMarkup` / `× EconomicSellScale`; client displays one price, server charges another (GAP_ANALYSIS "roughly 30x low buy, 10x low sell") |
| quest rewards (coin / exp / items) | **A clean**: coin = sum of `<reward type="Item" id="casinoCoin">`, exp/item from parsed `RewardSpec`; payout fail-closed on `ecsIdByName` miss |
| quest offer list / tier gate | **A clean**: `quest_list` from npc.xml, tier filter on parsed `difficulty_tier`; class-hash fallback only when npc.xml absent |
| blood moon + loot respawn | **B clean**: `BloodMoonFrequency/EnemyCount/Range`, `LootRespawnDays` via stock serverconfig keys (config.zig), applied to director / container re-roll; horde rows from gamestages.xml + spawning.xml |
| claims persistence | **OK**: `claims.zlc` zdtd-owned format (like ZPV3); keystone id resolved by AssignIds name |
| litenet fragments / ordered / dual-stack | **OK**: protocol RE constants; `IPV6_V6ONLY=0` kernel option (not stock data / not config) |
| bare `assignids.*` on production paths | **Reduced**: IdCtx pins only if dump empty; place fails closed when dump loaded |
| builtin production leakage | **Loud warn** for items/recipes/entities/loot/entitygroups/blocks/quests |
| Absolute Steam paths | **Removed** production `defaultGameDir`; tests may still skip-if-missing |

**Validation (this audit pass):** unit suite ~**800** (`zig build test`; STATUS.md
and changelog report 796-807 while a parallel wave is landing; prior pass 771).
Count drifts; see [STATUS.md](STATUS.md).

---

## Fixes landed this pass

| ID | Change |
|---|---|
| A01 | `systems.trade`: no `coin_item_id_default`; coin id 0 → fail closed. `handleTrade` passes `items.ecsIdByName("casinoCoin")`. |
| A02 | Production place via `place_fn` → `itemToBlockResolved`; offline `itemToBlock` only when AssignIds map empty. |
| A03 | `maxStackFor` uses `World.stack_fn` → `ItemTable.stackFor`; builtin only when id missing. |
| A04 | Armor via name prefix `armor*` (`isArmorOffline` + `is_armor_fn`); not bare `item_id == 11`. |
| A06 | Biome IdCtx: comptime assignids pins only when `id_by_name.count() == 0`. |
| A08/A22 | Deco species come from biomes.xml `<decorations>` resolved through `maxdamage.idByName` + `IsDistantDecoration`; an unresolvable row is dropped and an empty table falls back to the empty firstPackage. Ids are negotiated with a `blocks` NameIdMapping (`[feature] block_id_mapping`); coverage guard test asserts every placeable blocks.xml name (shape groups and the no-id rows excluded) resolves in the bundled dump, so client `assignLeftOverBlocks` never sees server data. Pins remain in `stock_deco` for offline labels only. |
| A09 | `maxDamageForBlock`: drop deco pin HP table when maxdamage loaded; generic 100 / offline bands offline only. |
| A15 | game-dir + still-builtin **warn** for loot, entitygroups, blocks, quests (plus existing items/recipes/entities). |
| A17 | `ecsIdFromItemName` 6/7 aliases only when `items.source == .builtin`. |
| A19 | `trader_wallet_dukes` const → `InitOptions`/`Game` field + `[sim] trader_wallet_dukes` in `zdtd.toml` (Bucket B; no stock key in traders.xml). All 4 call sites read `self.trader_wallet_dukes`; sanitize clamps negatives to 0. |
| A20 | `quests.zig`: `reward_coin` = sum of `<reward type="Item" id="casinoCoin" value="N">` in the quest body (stock grants dukes as casinoCoin Item rewards; no Coin reward type). Fail closed: no such reward → 0. Removed the exp-derived heuristic; fixture starter quest + scenario test now exercise the sum path. |
| A23 | Removed production Steam `defaultGameDir`; `--world-name` requires `--game-dir` or `--map`. |
| A12 | Vehicle speed: `vehicleControl` falls back to `vehicleKindDefaultSpeed(kind)` when vehicles.xml `velocityMax` is absent/0 (the XML row owns the real value). |
| A22 | Block id coverage guard test: every placeable blocks.xml name resolves in the bundled AssignIds dump, so client `assignLeftOverBlocks` never sees server data. |
| A30 | Trader restock cadence from `<trader_info>` `reset_interval` (-1 never, 0 daily, N every N days) instead of a flat daily policy. |
| A31 | Loot respawn fail closed: storage blocks with no `LootList` stay empty (no `woodenChest` fallback) on both initial fill and respawn paths. |
| B01–B07 | Stream/interest/edit/claimed-damage/peer_stale as `InitOptions` + `Game` fields (`default_*` consts). Hot path reads `self.*`. Array bound = `max_streamed_chunks_cap`. |
| - | Compile fixes incidental: dem test `got`→`head`, `@floatFromInt` result types on respawn. |

---

## 2026-08-07 wave re-audit (traders / quests / loot / blood moon / litenet)

Trader and quest waves are **mostly clean**: stock list, hours, sell gate,
reward payout, tier gate, loot respawn, blood moon and claims persistence all
load from `traders.xml` / `npc.xml` / `quests.xml` / prefab XML /
`gamestages.xml` / `spawning.xml` / stock serverconfig keys, and fail closed on
name-resolution misses. New actionable findings this pass: **A29 P1** (trader
price/sell ratios, the one real wrong-value risk), A30-A31 P3, B25-B28 P3
(quest heuristics + doc gap). A22 (deco id skew) is now closed by the
coverage guard test; A12 vehicle fallback and A30 restock cadence are fixed
in the follow-up pass. Litenet constants and the dual-stack `IPV6_V6ONLY=0`
socket option are protocol/kernel pins (OK).

---

## Bucket A findings (status)

| ID | Location | Sev | Status | Notes |
|---|---|---|---|---|
| A01 | `ecs/systems.zig` trade coin | P1 | **Fixed** | Fail closed if coin unresolved |
| A02 | place path / `itemToBlock` | P1 | **Fixed** | Production resolved; offline pin gated |
| A03 | inv stacks | P1 | **Fixed** | ItemTable via stack_fn |
| A04 | armor id 11 | P1 | **Fixed** | name prefix |
| A05 | `world/store.zig` `block_*` pins | P0 | **Fixed** | `World.terrain_ids` + `resolveTerrainIds` after AssignIds merge; module pins remain offline/test defaults; `isSolidWorld` uses live ids |
| A06 | IdCtx terr* fallback | P1 | **Fixed** | Dump non-empty → no pin |
| A07 | biome_layers defaults | P1 | Open P2 | Pre-XML defaults; XML path resolves |
| A08 | stock_deco pins | P0 | **Fixed** | Live deco send resolves ids via biomes.xml + idByName (fail closed); module pins are offline/test labels |
| A09 | maxDamageForBlock | P1 | **Fixed** | |
| A10 | class_table scrap | P1 | **Fixed** | Offline loot_list = EntityLootContainerRegular; spawn uses class loot_list; Game.setClassDef from entityclasses |
| A11 | AI attack/chase floors | P1 | **Fixed** | class_table speeds/damage from XML; module consts only when field 0 |
| A12 | vehicle speed switch | P1 | **Fixed** | `vehicleControl` falls back to `vehicleKindDefaultSpeed(kind)` when vehicles.xml `velocityMax` is 0/absent (`systems.zig:1548`); XML value wins when present |
| A13 | recipe unlock extras | P2 | Open | |
| A14 | quest builtins | P2 | Warn if game-dir | |
| A15 | builtin leakage | P1 | **Fixed** (warn) | |
| A16 | dual ECS/stock ids | P2 | **ADR 0015** | ECS handle + stock map; not parallel production catalog |
| A17 | name→6/7 builtin | P3 | **Fixed** gated | |
| A18 | stock_chunk pins | P2 | Open | |
| A19 | trader_wallet 5000 | P2 | **Fixed → B** | `default_trader_wallet_dukes` const → Game field from `[sim] trader_wallet_dukes`; ECD spawn / LockResponse / snapshot all read `self.trader_wallet_dukes` |
| A20 | quest reward_coin | P2 | **Fixed** | `reward_coin` now sums `<reward type="Item" id="casinoCoin" value="N">` from the quest body (stock has no Coin reward type); fail closed to 0 when absent. Fixture starter quest carries a casinoCoin reward so the scenario asserts the sum path |
| A21 | director / gamestages | P2 | **Partial** | gamestages.xml loaded; scout tier, blood-moon stage, sleeper groups and loot prob bands are data driven. Biome/quest/POI-tier stage inputs still zero (GAP_ANALYSIS P3 gamestage list) |
| A22 | deco version skew | P0 | **Fixed** | Server dictates block ids with a full `blocks` NameIdMapping (24808 rows) before the config files, so a client cannot compute a different id for a name we ship. Coverage guard test: every placeable blocks.xml name (excluding `shapes=` shape groups and the no-id rows `cntChickenCoop`/`terrFertileGrassExample`) resolves in the bundled dump, so server data never trips client `assignLeftOverBlocks`. Remaining: live V3.1.x client run (ops). Kill switches `[feature] block_id_mapping` and `deco_trees`; see archive/DECO_NRE.md gap 2 |
| A23 | defaultGameDir Steam | P1 | **Fixed** | |
| A24 | NONE loaders | P2 | Open | When feature lands |
| A25–A28 | sleeper 5 / weather / power | OK | OK | |
| A29 | trader price/sell ratios `econ/10`, `econ/50` | P1 | **New 08-07** | `game.zig:8454-8455` `fillTraderFromXml`: buy = EconomicValue/10, sell = EconomicValue/50, fallback 5/1 when econ 0. Stock RE (loot-economy.md §5, XUiM_Trader `GetBuyPrice`/`GetSellPrice` 1830470): buy = econ × `TraderInfo.BuyMarkup` (or `OverrideBuyMarkup`), sell = econ × `EconomicSellScale` × `SellMarkdown`; econ 0 = not purchasable. Loader parses `override_buy_markup`/`override_sell_markup` but nothing applies them. Client shows econ × markup while server charges econ/10 → displayed vs charged price desync (GAP_ANALYSIS "30x low buy, 10x low sell"). Fix: apply traders.xml markups + RE statics; econ 0 → fail closed. Do not move ratios to zdtd.toml (A, not B). |
| A30 | trader `reset_interval` parsed-unused | P3 | **New 08-07** | `traders.zig` parses `reset_interval` (stock traders.xml: 1/3 days); `systems.zig:708 traderRestock` ignores it: flat zdtd policy (soft cap 50, +10 per restock, wallet to spawn default). Restock cadence should follow the XML interval; the 50/10 policy itself is Bucket B. |
| A31 | loot respawn fallback `"woodenChest"` | P3 | **Fixed** | `maybeRespawnContainer` + both initial-fill sites now fail closed: a storage block with no resolvable `LootList` stays empty instead of re-rolling `"woodenChest"` ("missing beats fake"). Scenario test covers both branches (LootList present → re-roll, absent → empty and untouched). |

### Loader inventory vs stock Config

Unchanged HAVE list: blocks, materials (HP), items, entities, entitygroups,
recipes, loot, quests, traders, biomes, painting, spawning, buffs, progression,
vehicles, storage_pairs, signs, AssignIds, gamestages. NONE until feature:
nav_objects, qualityinfo, weathersurvival, worldglobal, utilityai, …

---

## Bucket B findings (status)

| ID | Concern | Sev | Status |
|---|---|---|---|
| B01–B07 | stream/interest/edit/claimed/stale | P1 | **Done:** Game fields + `[stream]` / `[authority]` in `zdtd.toml` |
| B08–B12 | lock stale/channels, join gap, craft cap | P2 | Open consts; A19 wallet done via `[sim]` |
| B13 | tick throttles % N | P1 | **Done** | All four remaining cadences are Game fields fed from `zdtd.toml [stream]`: `sleeper_tick_ticks` (10, sleeper volumes + airdrops + workstations), `turret_sync_ticks` (10), `save_interval_ticks` (100, world flush). Keys parse, merge, sanitize (0 → 1) and are listed in GAME_OPTIONS + the example file. |
| B14–B21 | AI bands, caps, buffers | P2–P3 | Open: draft `[net]`/`[ai]`/`[caps]` sections removed from example; unknown toml keys now **abort** (`error.UnknownTomlKey`), so the draft keys are unusable until parsed |
| B22 | CLI + file for caps | P1 | **Done:** file via `zdtd_config`; no per-cap CLI flags (InitOptions from toml) |
| B23–B24 | port offset, APM | P3 | Open |
| B25 | quest kill-count boost `3 + tier*2` | P3 | **RE basis added** | `assets/quests.zig:342` now cites the RE fact: stock ClearSleepers objectives always omit `count` (11/11 in stock quests.xml) because the target is the POI's sleeper volume, counted at runtime via `QuestEvent_SleepersCleared` / `SleeperVolumePosition*` (ObjectiveClearSleepers IL). The tier-scaled floor stays as a documented approximation until the kill objective is driven by the bound POI's sleeper volume (which the B26 POI binding now makes possible). |
| B26 | quest goto fallback position (FNV `%200 -100`) | P3 | **Fixed** | goto_point / stay_within / craft quests without a static def position now bind the nearest real POI at accept (`World.nearestPoi` hook wired to the prefab index; stock RandomPOIGoto picks the POI at hand-out). The goto check, NavObject marker and save-restore re-resolve all use the bound POI center; the FNV offset survives only as the no-POI-data fallback for offline/test worlds. |
| B27 | `LootRespawnDays` undocumented | P3 | **Done:** `docs/GAME_OPTIONS.md` "Applied to the sim" lists `LootRespawnDays` (default 7, range 0..365, `Game.loot_respawn_days` / `maybeRespawnContainer`). |
| B28 | quest offer name gate `isStockClientQuestName` | P3 | **Fixed** | The gate now short-circuits to true when the catalog loaded from stock `quests.xml` (server and client read the same file, so every def is client-known by construction); the prefix filter remains only as the builtin/offline-catalog proxy. |

### `zdtd.toml` (shipped surface)

Shipped loader: `src/server/zdtd_config.zig`. Template: [`zdtd.toml.example`](../zdtd.toml.example).
Operator docs: [GAME_OPTIONS.md](GAME_OPTIONS.md). Precedence:

```text
CLI  >  env (webui secret)  >  <world>/zdtd.toml  >  CWD zdtd.toml
     >  mode pack  >  --serverconfig keys  >  code defaults (InitOptions / default_*)
```

Parsed today: `[stream]`, `[authority]` (incl. `guard_*`), `[feature]`,
`[perf]`, `[sim]` (`trader_wallet_dukes`), `[mode]`, `[plugin]`. Unknown
sections/keys now **abort** startup (`error.UnknownTomlKey`); the draft
`[net]` / `[ai]` / `[caps]` sections and `[sim] craft_max_times` /
`save_every_ticks` from the 08-06 draft were dropped from the example and are
rejected if present (B13/B14-B21 residuals remain code consts).

```toml
[stream]
max_streamed_chunks = 169
chunk_adds_per_stream_tick = 8
stream_radius_min = 7
stream_radius_max = 9

[authority]
interest_range_blocks = 160.0
max_edit_range_blocks = 96.0
max_claimed_damage = 200
peer_stale_ms = 3000
guard_enforce = false
guard_window_ticks = 1200
guard_hard_repeat = 25

[feature]
wire_chunks = true
deco_trees = true
deco_mirror = true
block_id_mapping = true

[perf]
async_chunk_flush = false
terrain_snapshot = false
job_batches = false

[sim]
# trader_wallet_dukes = 5000

[mode]
# name = "default"

[plugin]
# modules = "path/to/x.wasm"
```

Stock-named serverconfig keys parse in `config.zig` (gameplay options,
B6): the new-wave tunables already ride them, e.g. `BloodMoonFrequency` /
`BloodMoonEnemyCount` / `BloodMoonRange` (director), `LootRespawnDays`
(container re-roll), `LandClaim*` (claims durability/expiry), `AirDropFrequency`.

Do **not** put MaxFuel, biome colors, item ids, EconomicValue, or the trader
markup ratios (A29) here (Bucket A).

---

## OK hardcodes (false positives)

| Item | Why OK |
|---|---|
| LiteNet MTU / window / fragment sizes | Protocol RE |
| `wire/stock_inv.items_start_here = 65536` | Stock Block.ItemsStartHere |
| Package body field sizes, `protocol.ticks_per_second=20` | Wire / project invariant |
| `PackageName` + negotiated id map; `default_mappings` fixtures | Protocol |
| Unity class hashes from **names** | Algorithm + stock names |
| ConfigFile LoadLocal name list | Protocol |
| `assignids_comptime` + embed dump | Dump pin; subset when merged |
| TE type enums, NodeKind, inv Op, QuestKind | RE / sim shapes |
| OpenSimplex / pure math | No stock file |
| `gravity_accel = -9.81` | Physics |
| Sleeper parseCount default 5 | Stock ParseList |
| Test-only Steam paths + scenarios | Skip if missing |
| chunk_size 16 | World constant |
| `items.stock_default_stack = 0x1f4` | Stock ItemClass default (asm.il:749089) |
| `stock_chunk.water_mass_full = 19500` | WaterUtils GetStableMassBelow clamp; visible-water gate mass > 195 |
| `unity_hash.class_npc_trader_jen` | Unity hash computed from the stock name |
| LootDropProb default 1.0 | XML path resolves `LootDropProb` from entityclasses; fallback only for entities without it / offline |
| `ecs/quest.zig ObjectiveWireKind` | Quest.Write CreateQuest subclass shapes (base / treasure_chest / empty); classifiers read quests.xml `type=` strings |
| `players.zsv` ZPV3 layout | zdtd-owned persistence format (ADR 0011), like ZCH3; not stock data |
| litenet fragment / ordered / MTU consts (`max_payload` 512K, `window_size` 64, `max_packet_size` 1327, `protocol_id` 13) | LiteNet protocol RE |
| `IPV6_V6ONLY = 0` dual-stack bind (`litenet/udp_socket.zig`) | Kernel socket option (stock LiteNetLib sets dual-stack); not stock data, not config |
| `quests.zig` `objectiveScore` priorities | zdtd sim-collapse ranking of stock objective `type=` strings (QuestKind allowed); relative weights, no stock source to load |
| `traderQuestList` class-hash fallback (`game.zig:8032`) | Unity hash from stock names + stock quest_list names; offline fallback only when npc.xml absent |
| `quests.zig` max_tier 6 / quests_per_tier 10 fallbacks | Match stock `quests.xml` root attrs (`max_quest_tier="6" quests_per_tier="10"`); XML path loads them |
| `claims.zlc` layout | zdtd-owned persistence format like ZPV3; keystone id resolved via AssignIds name, not numeric |

---

## Remaining open P0 / P1

### P0

1. ~~**A05**~~ **Done:** `World.terrain_ids` + `resolveTerrainIds` after AssignIds merge; module pins remain offline/test defaults; `isSolidWorld` uses live ids.
2. ~~**A08**~~ **Done:** deco species come from biomes.xml resolved via `idByName` and fail closed to the empty firstPackage; module pins are offline labels. **A22 residual:** the `blocks` NameIdMapping now pins every id we ship, but blocks only the client knows still get leftover ids, and the mapping is unvalidated against a live V3.1.x client; mitigated by `[feature] block_id_mapping` and `deco_trees`.

### P1

1. ~~**A10–A11**~~ **Done.** **A12** vehicle speed switch residuals remain.
2. ~~**B13**~~ **Done:** sleeper/turret/save cadences are `[stream]` keys.
3. ~~**B22**~~ **Done:** `src/server/zdtd_config.zig` + `zdtd.toml.example` (stream/authority/feature/sim). AI bands still open.
4. **A07** biome default stack pins before XML (acceptable offline).
5. **A29 (new 08-07)** trader price/sell ratios `econ/10` `econ/50` do not match stock `EconomicValue × markup`; client display vs server charge desync. Known gap (GAP_ANALYSIS), not yet fixed.

---

## Ordered next steps

1. ~~World init terrain ids (A05).~~
2. ~~`zdtd.toml` loader for B01–B07 + feature.~~
3. ~~A19 wallet → `[sim] trader_wallet_dukes` (done).~~
4. Extend toml for AI bands / tick throttles / caps (B08–B14, draft `[net]`/`[ai]`/`[caps]`; unknown-key abort means the drafts need parser support first).
5. ~~A11 AI floors.~~ A12 vehicle speeds from vehicles.xml only.
6. Drop recipe unlock extras when `source==xml` (A13).
7. ~~Quest coin-reward rework (`sumCoinReward`, casinoCoin Item rewards) landed (A20).~~
8. ~~**A29/A30:** price from `EconomicValue × BuyMarkup`/`OverrideBuyMarkup`; `reset_interval` wired into `traderRestock`.~~ Residual A29: `EconomicSellScale` and the quality-lerp terms still absent (sell prices approximate).
9. ~~**B27:** `LootRespawnDays` row added to GAME_OPTIONS.md.~~
10. ~~**B26:** goto quests bind the nearest real POI at accept.~~ ~~**B25:** kill-count floor RE-cited.~~ ~~**B28:** stock quests.xml catalog skips the prefix gate.~~

---

## Doc cross-links

| Doc | Role |
|---|---|
| [ASSETS.md](ASSETS.md) | Loader contracts |
| [GAME_OPTIONS.md](GAME_OPTIONS.md) | serverconfig + zdtd.toml |
| [STATUS.md](STATUS.md) | Play surface |
| [../TODO.md](../TODO.md) | Backlog |
| [prompts/hardcoded-data-review.md](prompts/hardcoded-data-review.md) | Audit prompt |

End of audit.
