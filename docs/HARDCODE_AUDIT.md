# Hardcode audit (Bucket A / B / OK)

Date: 2026-08-06 (re-audit; prior pass 2026-08-04). Method:
`docs/prompts/hardcoded-data-review.md` + systematic `rg` / file reads against
`src/`, stock `Data/Config`, `docs/ASSETS.md`, `docs/GAME_OPTIONS.md`.

## Executive summary

| Bucket | Open actionable | P0 open | P1 open | Notes |
|---|---:|---:|---:|---|
| **A** (stock data) | ~12 | 0 | ~6 | A22 residual closed as P0 (block_id_mapping pins every shipped id); P1s: A07/A12/A13 open |
| **B** (zdtd policy) | ~11 | 0 | ~2 | Stream/authority/feature/perf/sim via `zdtd.toml`; A19 wallet now configurable; residual open consts (AI bands, tick throttles, caps) |
| **OK** | 24+ | - | - | Wire / RE / physics / offline pins / new T1-T6 stock constants |

| Spot-check | Result |
|---|---|
| `default_gen_fuel` / `default_battery_cap` | **Gone** (power via maxdamage → `powerblocks.Resolved`) |
| `coin_item_id_default = 6` | **Fixed**: trade requires non-zero `ecsIdByName("casinoCoin")` |
| `max_streamed_chunks` / interest / edit caps | **On Game/InitOptions** + loaded from `zdtd.toml` (`src/server/zdtd_config.zig`) |
| `trader_wallet_dukes` | **Configurable** (`[sim] trader_wallet_dukes`); Game field used in ECD spawn / lock / snapshot paths |
| bare `assignids.*` on production paths | **Reduced**: IdCtx pins only if dump empty; place fails closed when dump loaded |
| builtin production leakage | **Loud warn** for items/recipes/entities/loot/entitygroups/blocks/quests |
| Absolute Steam paths | **Removed** production `defaultGameDir`; tests may still skip-if-missing |

**Validation (this audit pass):** unit suite is **769** tests (`zig build test`, 2026-08-06). Count drifts; see [STATUS.md](STATUS.md).

---

## Fixes landed this pass

| ID | Change |
|---|---|
| A01 | `systems.trade`: no `coin_item_id_default`; coin id 0 → fail closed. `handleTrade` passes `items.ecsIdByName("casinoCoin")`. |
| A02 | Production place via `place_fn` → `itemToBlockResolved`; offline `itemToBlock` only when AssignIds map empty. |
| A03 | `maxStackFor` uses `World.stack_fn` → `ItemTable.stackFor`; builtin only when id missing. |
| A04 | Armor via name prefix `armor*` (`isArmorOffline` + `is_armor_fn`); not bare `item_id == 11`. |
| A06 | Biome IdCtx: comptime assignids pins only when `id_by_name.count() == 0`. |
| A08/A22 | Deco species come from biomes.xml `<decorations>` resolved through `maxdamage.idByName` + `IsDistantDecoration`; an unresolvable row is dropped and an empty table falls back to the empty firstPackage. Ids are negotiated with a `blocks` NameIdMapping (`[feature] block_id_mapping`). Pins remain in `stock_deco` for offline labels only. |
| A09 | `maxDamageForBlock`: drop deco pin HP table when maxdamage loaded; generic 100 / offline bands offline only. |
| A15 | game-dir + still-builtin **warn** for loot, entitygroups, blocks, quests (plus existing items/recipes/entities). |
| A17 | `ecsIdFromItemName` 6/7 aliases only when `items.source == .builtin`. |
| A23 | Removed production Steam `defaultGameDir`; `--world-name` requires `--game-dir` or `--map`. |
| B01–B07 | Stream/interest/edit/claimed-damage/peer_stale as `InitOptions` + `Game` fields (`default_*` consts). Hot path reads `self.*`. Array bound = `max_streamed_chunks_cap`. |
| - | Compile fixes incidental: dem test `got`→`head`, `@floatFromInt` result types on respawn. |

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
| A12 | vehicle speed switch | P1 | Open | Fallback when max_speed 0 |
| A13 | recipe unlock extras | P2 | Open | |
| A14 | quest builtins | P2 | Warn if game-dir | |
| A15 | builtin leakage | P1 | **Fixed** (warn) | |
| A16 | dual ECS/stock ids | P2 | **ADR 0015** | ECS handle + stock map; not parallel production catalog |
| A17 | name→6/7 builtin | P3 | **Fixed** gated | |
| A18 | stock_chunk pins | P2 | Open | |
| A19 | trader_wallet 5000 | P2 | **Fixed → B** | `default_trader_wallet_dukes` const → Game field from `[sim] trader_wallet_dukes`; ECD spawn / LockResponse / snapshot all read `self.trader_wallet_dukes` |
| A20 | quest reward_coin | P2 | **In progress** | `sumExpReward` (Exp rewards) drives `reward_coin`; stock quest dukes are casinoCoin **Item** rewards (uncommitted `sumCoinReward` rework in tree) |
| A21 | director / gamestages | P2 | **Partial** | gamestages.xml loaded; scout tier, blood-moon stage, sleeper groups and loot prob bands are data driven. Biome/quest/POI-tier stage inputs still zero (GAP_ANALYSIS P3 gamestage list) |
| A22 | deco version skew | P0 | **Partial** | Server now dictates block ids with a full `blocks` NameIdMapping before the config files, so a client cannot compute a different id for a name we ship. Still partial: names only the client has fall through to `assignLeftOverBlocks`, and the mapping has had no live V3.1.x run. Kill switches `[feature] block_id_mapping` and `deco_trees`; see archive/DECO_NRE.md gap 2 |
| A23 | defaultGameDir Steam | P1 | **Fixed** | |
| A24 | NONE loaders | P2 | Open | When feature lands |
| A25–A28 | sleeper 5 / weather / power | OK | OK | |

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
| B13 | tick throttles % N | P1 | Partial: stream/motion periods on Game; save/worldtime still bare |
| B14–B21 | AI bands, caps, buffers | P2–P3 | Open (`[net]`/`[ai]`/`[caps]` draft sections still unknown-key) |
| B22 | CLI + file for caps | P1 | **Done:** file via `zdtd_config`; no per-cap CLI flags (InitOptions from toml) |
| B23–B24 | port offset, APM | P3 | Open |

### `zdtd.toml` (core shipped; residual keys still draft)

Shipped loader: `src/server/zdtd_config.zig`. Template: [`zdtd.toml.example`](../zdtd.toml.example).
Operator docs: [GAME_OPTIONS.md](GAME_OPTIONS.md). Precedence:

```text
CLI  >  env (webui secret)  >  <world>/zdtd.toml  >  CWD zdtd.toml
     >  --serverconfig keys  >  code defaults (InitOptions / default_*)
```

Parsed today: `[stream]`, `[authority]`, `[feature]`, `[perf]`, `[sim]`
(`trader_wallet_dukes`). Keys under `[net]`, `[ai]`, `[caps]` in the draft
below are residual (unknown-key warn if present).

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
lock_stale_ms = 120000
lock_channels = 16
join_rate_gap_ms = 500

[sim]
craft_max_times = 20
trader_wallet_dukes = 5000
save_every_ticks = 100

[net]
world_time_send_ticks = 20
vehicle_pos_send_ticks = 5
turret_sync_ticks = 10
sleeper_tick_ticks = 10
entity_interest_half_ticks = 2
deco_stream_ticks = 5
litenet_port_offset = 2

[ai]
full_range_blocks = 64.0
sense_range_blocks = 48.0
mid_range_blocks = 15.0
attack_range_blocks = 2.0
despawn_range_blocks = 200.0

[caps]
max_entities = 512
max_quests = 512
max_phases = 32
max_sleeper_volumes = 8192
max_peers = 64
max_workers = 8
min_parallel_items = 24

[perf]
async_chunk_flush = false
terrain_snapshot = false
job_batches = false

[feature]
deco_trees = false
wire_chunks = true
```

Do **not** put MaxFuel, biome colors, item ids, or EconomicValue here (Bucket A).

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

---

## Remaining open P0 / P1

### P0

1. ~~**A05**~~ **Done:** `World.terrain_ids` + `resolveTerrainIds` after AssignIds merge; module pins remain offline/test defaults; `isSolidWorld` uses live ids.
2. ~~**A08**~~ **Done:** deco species come from biomes.xml resolved via `idByName` and fail closed to the empty firstPackage; module pins are offline labels. **A22 residual:** the `blocks` NameIdMapping now pins every id we ship, but blocks only the client knows still get leftover ids, and the mapping is unvalidated against a live V3.1.x client; mitigated by `[feature] block_id_mapping` and `deco_trees`.

### P1

1. ~~**A10–A11**~~ **Done.** **A12** vehicle speed switch residuals remain.
2. **B13 residual** world-time / save / sleeper `% N` not all Game fields.
3. ~~**B22**~~ **Done:** `src/server/zdtd_config.zig` + `zdtd.toml.example` (stream/authority/feature). AI bands / wallets / tick %N still open.
4. **A07** biome default stack pins before XML (acceptable offline).

---

## Ordered next steps

1. ~~World init terrain ids (A05).~~
2. ~~`zdtd.toml` loader for B01–B07 + feature.~~
3. ~~A19 wallet → `[sim] trader_wallet_dukes` (done).~~
4. Extend toml for AI bands / tick throttles / caps (B08–B14, draft `[net]`/`[ai]`/`[caps]`).
5. ~~A11 AI floors.~~ A12 vehicle speeds from vehicles.xml only.
6. Drop recipe unlock extras when `source==xml` (A13).
7. Land the quest coin-reward rework (`sumCoinReward`, casinoCoin Item rewards) when it is committed (A20).

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
