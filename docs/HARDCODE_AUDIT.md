# Hardcode audit (Bucket A / B / OK)

Date: 2026-08-04 (re-audit + P0/P1 fixes). Method:
`docs/PROMPTS/audit-hardcoded-data.md` + systematic `rg` / file reads against
`src/`, stock `Data/Config`, `docs/ASSETS.md`, `docs/GAME_OPTIONS.md`.

## Executive summary

| Bucket | Open actionable | P0 open | P1 open | Notes |
|---|---:|---:|---:|---|
| **A** (stock data) | ~12 | 2 | ~6 | P0 deco version pin + terrain module pins residual |
| **B** (zdtd policy) | ~16 | 0 | ~4 | Caps on Game fields; full `zdtd.toml` not implemented |
| **OK** | 22+ | — | — | Wire / RE / physics / offline pins |

| Spot-check | Result |
|---|---|
| `default_gen_fuel` / `default_battery_cap` | **Gone** (power via maxdamage → `powerblocks.Resolved`) |
| `coin_item_id_default = 6` | **Fixed**: trade requires non-zero `ecsIdByName("casinoCoin")` |
| `max_streamed_chunks` / interest / edit caps | **On Game/InitOptions fields** (defaults preserved); no file loader yet |
| bare `assignids.*` on production paths | **Reduced**: IdCtx pins only if dump empty; place fails closed when dump loaded |
| builtin production leakage | **Loud warn** for items/recipes/entities/loot/entitygroups/blocks/quests |
| Absolute Steam paths | **Removed** production `defaultGameDir`; tests may still skip-if-missing |

**Validation:** `zig build test` → **All 239 tests passed.**

---

## Fixes landed this pass

| ID | Change |
|---|---|
| A01 | `systems.trade`: no `coin_item_id_default`; coin id 0 → fail closed. `handleTrade` passes `items.ecsIdByName("casinoCoin")`. |
| A02 | Production place via `place_fn` → `itemToBlockResolved`; offline `itemToBlock` only when AssignIds map empty. |
| A03 | `maxStackFor` uses `World.stack_fn` → `ItemTable.stackFor`; builtin only when id missing. |
| A04 | Armor via name prefix `armor*` (`isArmorOffline` + `is_armor_fn`); not bare `item_id == 11`. |
| A06 | Biome IdCtx: comptime assignids pins only when `id_by_name.count() == 0`. |
| A08/A22 | Deco trees already resolve via `idByName` (`decoTreeIds`); fail closed if miss. Pins remain in `stock_deco` for offline labels. |
| A09 | `maxDamageForBlock`: drop deco pin HP table when maxdamage loaded; generic 100 / offline bands offline only. |
| A15 | game-dir + still-builtin **warn** for loot, entitygroups, blocks, quests (plus existing items/recipes/entities). |
| A17 | `ecsIdFromItemName` 6/7 aliases only when `items.source == .builtin`. |
| A23 | Removed production Steam `defaultGameDir`; `--world-name` requires `--game-dir` or `--map`. |
| B01–B07 | Stream/interest/edit/claimed-damage/peer_stale as `InitOptions` + `Game` fields (`default_*` consts). Hot path reads `self.*`. Array bound = `max_streamed_chunks_cap`. |
| — | Compile fixes incidental: dem test `got`→`head`, `@floatFromInt` result types on respawn. |

---

## Bucket A findings (status)

| ID | Location | Sev | Status | Notes |
|---|---|---|---|---|
| A01 | `ecs/systems.zig` trade coin | P1 | **Fixed** | Fail closed if coin unresolved |
| A02 | place path / `itemToBlock` | P1 | **Fixed** | Production resolved; offline pin gated |
| A03 | inv stacks | P1 | **Fixed** | ItemTable via stack_fn |
| A04 | armor id 11 | P1 | **Fixed** | name prefix |
| A05 | `world/store.zig` `block_*` pins | P0 | **Open** | Module aliases still comptime pins; used by flat gen + tests. Safe while dump matches pin version; full resolve-at-init deferred |
| A06 | IdCtx terr* fallback | P1 | **Fixed** | Dump non-empty → no pin |
| A07 | biome_layers defaults | P1 | Open P2 | Pre-XML defaults; XML path resolves |
| A08 | stock_deco pins | P0 | **Partial** | Live deco uses idByName; module pins for labels/offline |
| A09 | maxDamageForBlock | P1 | **Fixed** | |
| A10 | class_table scrap | P1 | Open | Overwritten on entity load; scrap offline |
| A11 | AI attack/chase floors | P1 | Open | Defaults when class fields 0 |
| A12 | vehicle speed switch | P1 | Open | Fallback when max_speed 0 |
| A13 | recipe unlock extras | P2 | Open | |
| A14 | quest builtins | P2 | Warn if game-dir | |
| A15 | builtin leakage | P1 | **Fixed** (warn) | |
| A16 | dual ECS/stock ids | P2 | Doc only | |
| A17 | name→6/7 builtin | P3 | **Fixed** gated | |
| A18 | stock_chunk pins | P2 | Open | |
| A19 | trader_wallet 5000 | P2 | Open → B | |
| A20 | quest reward_coin | P2 | Open | |
| A21 | director / gamestages | P2 | Open | |
| A22 | deco version skew | P0 | **Partial** | Fail closed + dump pin doc |
| A23 | defaultGameDir Steam | P1 | **Fixed** | |
| A24 | NONE loaders | P2 | Open | When feature lands |
| A25–A28 | sleeper 5 / weather / power | OK | OK | |

### Loader inventory vs stock Config

Unchanged HAVE list: blocks, materials (HP), items, entities, entitygroups,
recipes, loot, quests, traders, biomes, painting, spawning, buffs, progression,
vehicles, storage_pairs, signs, AssignIds. NONE until feature: gamestages,
nav_objects, qualityinfo, weathersurvival, worldglobal, utilityai, …

---

## Bucket B findings (status)

| ID | Concern | Sev | Status |
|---|---|---|---|
| B01–B07 | stream/interest/edit/claimed/stale | P1 | **Fields on Game** (no zdtd.toml file yet) |
| B08–B12 | lock stale/channels, join gap, wallet, craft cap | P2 | Open consts |
| B13 | tick throttles % N | P1 | Partial: stream/motion periods on Game; save/worldtime still bare |
| B14–B21 | AI bands, caps, buffers | P2–P3 | Open |
| B22 | CLI + file for caps | P1 | Open (InitOptions only; no toml) |
| B23–B24 | port offset, APM | P3 | Open |

### Draft `zdtd.toml` (remaining B; not implemented)

Precedence when added:

```text
CLI  >  <world>/zdtd.toml  >  CWD zdtd.toml  >  serverconfig.xml (stock keys)
     >  code defaults (InitOptions / default_* == today's values)
```

```toml
[stream]
max_streamed_chunks = 169
chunk_adds_per_stream_tick = 8
stream_radius_min = 6
stream_radius_max = 8

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

[apm]
dump_every_s = 0
path = ""

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

---

## Remaining open P0 / P1

### P0

1. ~~**A05**~~ **Done:** `World.terrain_ids` + `resolveTerrainIds` after AssignIds merge; module pins remain offline/test defaults; `isSolidWorld` uses live ids.
2. **A08/A22** deco module numeric pins remain for labels; live stream is idByName. Document dump version skew suppress.

### P1

1. **A10–A12** class_table scrap, AI combat floors, vehicle speed switch residuals.
2. **B13 residual** world-time / save / sleeper `% N` not all Game fields.
3. ~~**B22**~~ **Done:** `src/server/zdtd_config.zig` + `zdtd.toml.example` (stream/authority/feature). AI bands / wallets / tick %N still open.
4. **A07** biome default stack pins before XML (acceptable offline).

---

## Ordered next steps

1. ~~World init terrain ids (A05).~~
2. ~~`zdtd.toml` loader for B01–B07 + feature.~~
3. Extend toml for AI bands / wallets / tick throttles (B08–B14).
4. AI floors / vehicle speeds from entityclasses + vehicles.xml only (A11/A12).
5. Drop recipe unlock extras when `source==xml` (A13).

---

## Doc cross-links

| Doc | Role |
|---|---|
| [ASSETS.md](ASSETS.md) | Loader contracts |
| [GAME_OPTIONS.md](GAME_OPTIONS.md) | serverconfig + future zdtd.toml |
| [STATUS.md](STATUS.md) | Play surface |
| [../TODO.md](../TODO.md) | Backlog |
| [PROMPTS/audit-hardcoded-data.md](PROMPTS/audit-hardcoded-data.md) | Audit prompt |

End of audit.
