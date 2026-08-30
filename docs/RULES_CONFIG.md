# Rules/config disposition (ADR 0021 review)

> **What this is:** which server tunables moved onto config and which stayed in code, with the reason for each keep, so adding a new tunable does not regress into ad hoc globals.
> **Related:** [ARCHITECTURE.md](ARCHITECTURE.md) §10 · [GAME_OPTIONS.md](GAME_OPTIONS.md) · [PLUGIN_CONFIG_DISPOSITION.md](PLUGIN_CONFIG_DISPOSITION.md) · [ZIG_CLONE.md](ZIG_CLONE.md) · [STATUS.md](STATUS.md)

Result of the "everything that can be config should be config" review of the
server's rules/logic. For every hardcoded tunable found, this records the
disposition: **move** it onto the established config surface (`src/ecs/rules.zig`
groups, auto-bound via `util/toml_bind.zig` to `zdtd.toml [rules.*]` and overlaid
by `presets/*.toml`, or the `[sim]`/`[quests]`/`[bots]` sections of
`src/server/zdtd_config.zig`), or **keep** it in code with a reason.

Load-order rule (ADR 0010): stock XML data → config → preset packs → source as the
documented last resort. A `Rules` value is a **floor** where per-entity stock
data exists; defaults stay identical (a move is not a retune).

## Moved (rules.zig - new fields, defaults identical)

| Group | Field | Default | Source (pre-move) |
|---|---|---|---|
| `combat` | `knockback_speed` | 8.0 | `components.zig` kb_speed (melee shove) |
| `combat` | `knockback_seconds` | 0.3 | `components.zig` kb_seconds |
| `ai` | `no_target_scale` | 0.1 | `systems.zig` active_scale no-player |
| `ai` | `sleep_dist_mult` | 4.0 | `systems.zig` ultra-far gate (× full_dist_sq) |
| `ai` | `sleep_decision_scale` | 0.05 | `systems.zig` ultra-far decision drain |
| `ai` | `sleep_wander_interval_s` | 1.0 | `systems.zig` ultra-far re-decide |
| `ai` | `sleep_wander_speed_frac` | 0.5 | `systems.zig` ultra-far wander speed |
| `ai` | `fear_scan_cd_s` | 0.5 | `systems.zig` animal flee-scan cadence |
| `ai` | `move_arrive` | 0.2 | `systems.zig` stepToward arrive (0.04 sq) |
| `ai` | `push_range` | 0.7 | `systems.zig` AttackPush proximity (x/z) |
| `ai` | `push_y_tol` | 1.5 | `systems.zig` AttackPush vertical tolerance |
| `ai` | `push_shove` | 0.15 | `systems.zig` AttackPush shove per step |
| `ai` | `dig_windup_ticks` | 18 | `systems.zig` DigUpdate windup (RE, mode-pace) |
| `ai` | `dig_budget_ticks` | 90 | `systems.zig` DigStop budget |
| `bloodmoon` | `budget_scale` | 1.9 | `aidirector.zig` CanSpawn(1.9f) ceiling (RE) |
| `bloodmoon` | `wave_frac` | 0.5 | `aidirector.zig` BM wave = enemy_count/2 |
| `director` | `heat_scout_count` | 2 | `aidirector.zig` scouts per heat event |
| `director` | `heat_feral_chance` | 0.2 | `aidirector.zig` feral roll (`% 5`, was doc-only) |
| `director` | `heat_feral_cd_mult` | 2.0 | `aidirector.zig` feral cooldown doubling |
| `director` | `heat_event_ticks` | 720.0 | `aidirector.zig` const, actually used by `craft.zig` |
| `vehicle` | `fuel_cap` | 100 | `world.zig` spawn fill + `craft.zig` tank cap |
| `vehicle` | `refuel_reach` | 3.0 | `craft.zig` InvTx refuel reach |
| `vehicle` | `gravity` | -9.81 | `systems.zig` EntityVehicle cGravity (RE) |
| `world` | `poi_unlock_grace_ticks` | 2000 | `poi_lock.zig` SetUnlocked grace |
| `power` (new) | `battery_capacity_scale` | 10.0 | `powerblocks.zig` battery fallback |
| `power` (new) | `battery_initial_charge_frac` | 0.5 | `powerblocks.zig` initial charge |
| `power` (new) | `trigger_pulse_s` | 0.5 | `electric.zig` plate/tripwire pulse |

## Moved (zdtd.toml sections)

| Section | Key | Default | Source (pre-move) |
|---|---|---|---|
| `[sim]` | `trader_use_range` | 32 | `trader_wire.zig` trade echo reach gate |
| `[sim]` | `party_shared_kill_range` | 100 | `player.zig` GameStats[54] default |
| `[sim]` | `storm_bm_push_ticks` | 5000 | `weather.zig` blood_moon_storm_push |
| `[quests]` | `poi_min_dist` | 32 | `hooks.zig` POI selector min (1000 sq) |
| `[quests]` | `poi_max_dist` | 2000 | `hooks.zig` POI selector max (4e6 sq) |
| `[quests]` | `max_poi_attempts` | 50 | `hooks.zig` search loop bound |

Wiring changes that accompany the moves (non-field fixes, same behavior):
- `world.zig` revenge window read `components.revenge_window_s` → `rules.ai.revenge_window_s` (the rule was already surfaced but inert - real bug fixed).
- `systems.zig` falling-block terminal velocity reuses `rules.ai.fall_max_vy` (-30) instead of a duplicate literal.
- Removed the now-dead module consts: `components.kb_speed/kb_seconds/revenge_window_s`, `systems.dig_*`, `aidirector.heat_*`, `electric.default_trigger_pulse_s`, `powerblocks.battery_*`, `poi_lock.unlock_grace`, `craft.vehicle_fuel_max/refuel_reach`, `trader_wire.trade_use_range`, `player.party_shared_kill_range_sq`, `hooks.poi_*`, `weather.blood_moon_storm_push`.

## Kept in code (documented reason)

| Candidate | Reason |
|---|---|
| `store.zig` sea_level 64 | Used in comptime default literals (`.{sea_level} ** 256`); runtime config would be a structural refactor. (The projection surface around it - `[rules.geometry]` sea_level/height_scale/height_offset/height_ceiling, ADR 0036 - IS config.) |
| `store.zig`/`water.zig` water-source radius 12 | Worldgen-only carve; low value. |
| `dem.zig` elevation mapping, `prefabs.zig` paint cap, trader gate scan margins, `join.zig` mob burst cap 16 | Operator feel is not worth the surface today (YAGNI); each is named + commented in code. |
| RE wire/protocol facts | `tts.zig` blockvalue_version 18, `components.buff_ticks_per_second 20`, `c2s/move.zig` 1/32 scale, trigger-duration enum table - not tunables. |
| PERF compile-time budgets | Table/array caps (bm_parties, path replans/stride, max_poi_candidates, noise/dig/sleeper wake rings, max_workstations/containers/vending/lights/nodes/wires, max_resident_chunks, flush queues, terrain-snapshot window, `dmg_scale`) - compile-time bounds by design. |
| FAIL safety guards | `electric.max_node_watts` 100k, movement dt envelope, explosion-radius clamp 6, `max_poi_candidates` - fail-closed bounds. |
| STOCK fallbacks (offline/no-XML) | `world.zig` class-table zombie max_hp 40 (generic) / 550 (zombieBoeFeral), `stock_turret_watts 15` (`powerblocks.zig` autoTurret), eat props, maxStackOffline, trader price/markup fallbacks, weather default params, sleepers 5,5 - XML/offline data, covered by the XML audit. |

Moved since this table was written:
- **`[bots] weapon_profiles`** (2026-08-25, was `bot.zig` weapon profiles above):
  the per-weapon loadout pool (tag:damage:range:pellets, up to 8 guns; empty =
  builtin) is config via `[bots] weapon_profiles`, parsed at init.
- **`[rules.worldgen]`** (2026-08-29, was line 70 above): the procedural shaping
  params (base_height 68, height_amp 24, min/max_surface 12/200, squash 28,
  noise_weight 0.85, y_scale 2.0, bedrock_h 3) are config via
  `WorldGen.applyParams` (defaults byte-identical; fail-closed validate).
  Grid cells, the noise recipe and the RWG water table stay code.
- **`[rules.geometry]`** (2026-08-28, ADR 0036): elevation projection
  (sea_level 64, height_scale 1.0, height_offset 0.0, height_ceiling 0) on
  the block store; identity at stock defaults; fail-closed validate.
- **`[rules.director]` tier ladders** (was line 69 above): the per-tier
  scalars exist - `difficulty_hp_0..5` (0.5–2.0) and `move_scale_0..4`
  (0.5–1.7) - read by `aidirector.zig` from the rules (the 11-field scalar
  expansion the old row said was needed already happened).

## Verification

- `zig build test` exits 0.
- `make check-xml-audit` exits 0 (independent gate).

## 2026-08-25 additions (lift sweep)

- `[rules.progression] kill_xp_fallback` (100) - kill-XP floor when
  entityclasses ExperienceGain did not resolve (was a flat literal in
  `xpGainFor`); binder + overlay + GAME_OPTIONS row ship with the field.
- `[bots] arrival_dist` (0.05) / `[bots] shot_range_slop` (2.0) - bot host
  move-arrival tolerance and fire-range slop (were module constants in
  `bot.zig`); binder + main merge + GAME_OPTIONS row ship with the fields.
- Re-audit found no dead `Rules` fields and no unconsumed config keys; the
  kept-with-reason items are recorded in `docs/PLUGIN_CONFIG_DISPOSITION.md`
  ("2026-08-25 lift sweep").
