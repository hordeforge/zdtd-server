# Hardcode audit (Bucket A / B / OK) 2026-08-25

Date: 2026-08-25. HEAD: dc9ded7 (main, clean tree). Method: the
`docs/prompts/hardcoded-data-review.md` rubric + a fresh `rg` sweep of the
behavior-heavy sim paths (tick.zig, c2s/*, ecs/aidirector.zig, ecs/systems.zig,
server/game/*) against stock `Data/Config` (V3.1.0 b14 dedicated install),
`docs/GAME_OPTIONS.md`, `docs/PROVENANCE.md` §3 (the behavioral-constants
ledger, gate-enforced at 41 rows), and `../7dtd-engine-research/docs`.
Re-verification of the 2026-08-08 pass + everything that landed since.

## Executive summary

| Bucket | New P0 | New P1 | New P2 | New P3 | Notes |
|---|---:|---:|---:|---:|---|
| **A** (stock data) | 0 | 0 | 0 | 0 | All prior A-items CLOSED (see dispositions) |
| **B** (zdtd policy) | 0 | 0 | 0 | 0 | Remaining B-items are documented engineering caps (lock array size, LiteNet port+2, APM cadence) |
| **OK** | - | - | - | - | 40+ cited false positives carried; no new ones this pass |
| Carried open | 0 | 0 | 0 | 0 | Nothing new |

**No new hardcodes.** The fresh sweep found no inline behavior constant that
should be config/data/plugin: every match was a struct field, a test literal,
or an RE-pinned value. The remaining residuals are **missing behaviour, not
hardcoded values** (each recorded in GAP_ANALYSIS with its exact unblock):
`BlockDamage` (client-computed, double-apply - RE-informed not-a-fix), the
terrain-resource harvest path (absent system), the difficulty presets asset
(RE-blocked external), and `LootProb` (missing item-Tags substrate + the
roll's application point needs RE).

## Dispositions since the 2026-08-08 pass

- **A34 CLOSED** (entityclasses.xml `HealthMax`): `assets/entities.zig`
  parses the `HealthMax` passive_effect `base_set` rows and resolves `^var`
  names through `<replace_passive_effect>` (the zombie HP ladder), so classes
  spawn at their stock HP instead of the 40/30 floors. Verified in code
  (entities.zig `loadFromPath`, HealthMax branch) and by the class-table HP
  tests.
- **A35 CLOSED** (class_table reachability): the director's
  `class_resolve_fn` hook resolves any picked ZombiesAll class to its full
  entityclasses stats; row 2 repointed to `zombieBoeFeral`.
- **A36/A37/A38 CLOSED** (terrain id pins): `spawnSurface` reads
  `World.terrain_ids.dirt`; filler ids are `TerrainIds` fields; `Chunk.rawAt`
  / `isSolid` route through `World.terrain_ids` when set.
- **A39 CLOSED** (EconomicSellScale): parsed per item (`econ_sell_scale`),
  sell = `econ x scale x sell_markup`; stock test asserts the .5 grill row.
- **A41 CLOSED** (heat cooldowns): `[rules.director]` 240/180 aligned to the
  RE literals, still operator-tunable.
- **A29/A07/A13/A14/A18/A21/A24/A33 CLOSED** in the intervening passes
  (documented in their rows).

## New wiring audited (since the last pass) - all data/config/RE-shaped

- Per-attack stamina: items.xml `StaminaLoss` x `[rules.combat]
  stamina_usage_multiplier` (RE ItemActionMelee IL) - data + config, no
  hardcode.
- Explicit `level=` curve anchors (progression.xml dominant form): parsed
  data, stock PassiveEffect.ModValue interpolation - no hardcode.
- Perk/buff max-stat deltas: `Health.base_max_hp` + the rules/computed fold -
  XML data + config.
- Perk/buff stamina-OT: the VM's `StaminaChangeOT` fold - data.
- Perk-tag-gated TargetArmor: items.xml tag rows, the attacker's perk level
  gates - data.
- Block-loot drop: the container store's contents spill on break; the 449
  LootList blocks are all containers (maxdamage.lootListFor resolves the
  list for the pre-fill) - data, no invented table.
- The `fatal` honor (`amount = 9999` on a fatal zombie claim) is a kill
  sentinel, not a tunable: stock honors the client's `bFatal` flag by killing
  the NPC. Kept inline (named by its comment), not config.

## Plugin/config layering spot-check

The Wasm-first boundary holds: announcements/killfeeds/chat/quest/loot/craft/
perk gates are plugins (10+ core modules); every operator tunable is a
`[rules.*]`/serverconfig/zdtd.toml field via the ADR 0021 binder; the
survival stage machine, damage application, and stat mutation stay native
sim authority (the boundary cannot express them). No native behavior was
found that the boundary could carry.

---

## Re-verification 2026-08-29 (HEAD b723eb6, clean tree)

Fresh run of the section-3 hunts (abs paths, Bucket A hotspots, power/AI/
terrain/placeables, content enums, stock XML loader coverage) against the
tree after the 3.2.0 + plugin/config passes:

- **No new Bucket A hits.** `inventory.zig` place_*_block_id pins and
  `offlineStockName` stay offline/test-gated (`hooks.zig` fires the builtin
  path only when `items.source == .builtin and !stock_catalogs_requested`);
  `store.zig` terrain pins resolve live via `TerrainIds.resolve` at
  `init_assets.zig:135`; `block_stone` uses are test-only.
- **No new Bucket B hits.** AI bands all read `w.rules.ai.*`; power
  `battery_capacity_scale` syncs from `[rules.power]` (rules.zig:719); the
  only bare `chase_speed = 1.1`-style literals are test mocks.
- **Doc-to-src references:** every `src/...zig` path cited by current-state
  docs resolves; the four "missing" files (`ecs/challenge|drone|game_event|
  stealth.zig`) are forward-looking WORK_PLAN / historical ZIG_CLONE refs.
- **Stock XML coverage:** the 9 unreferenced Config files
  (blockplaceholders, dmscontent, music, physicsbodies, sandbox_overrides,
  subtitles, twitch_events, ui_display, videos) are the documented
  client-side/out-of-scope set; 3.2.0 added no server-side dependency on
  them.
- **New since 08-25:** entity kind now classifies `vehicle`/`turret` from
  stock Tags (b723eb6), removing the admin spawnentity name-sniff list.
