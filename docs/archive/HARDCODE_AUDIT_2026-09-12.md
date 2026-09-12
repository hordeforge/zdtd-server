# Hardcode audit (Bucket A / B / OK) 2026-09-12

Date: 2026-09-12. HEAD: `3d408904` (working tree clean for source; two
sibling review snapshots and one review doc are dirty, not touched here).
Mode: **audit only** per the session override - no source file was modified.
Method: the `docs/prompts/hardcoded-data-review.md` rubric, a fresh `rg` sweep
of the sim/net/config hot paths (`server/game/*`, `c2s/*`, `ecs/*`, `world/*`,
`assets/*`, `litenet/*`, `protocol.zig`), cross-checked against
`docs/XML_DATA_AUDIT.md` (the maintained per-XML audit + its
`tools/check_xml_audit.py` gate), `docs/PROVENANCE.md`, `docs/DIVERGENCES.md`,
`docs/GAME_OPTIONS.md`, and the recent commit log since the 2026-08-29 pass.

Scope note: the repo-wide gates (`make check`, `check-xml-audit`, `zig build
test`) were deliberately not run (session override; parallel reviews). All
findings below are hand-traced, not search-hit-only.

## Executive summary

| Bucket | New P0 | New P1 | New P2 | New P3 | Notes |
|---|---:|---:|---:|---:|---|
| **A** (stock data) | 0 | 1 | 0 | 1 | weather count; forge offline fuel fallback |
| **B** (zdtd policy) | 0 | 0 | 2 | 1 | starter kit, demo-seed switch, heartbeat period |
| **OK** | - | - | - | - | 12 false-positive classes re-confirmed with cites |
| Carried open | 0 | 0 | 0 | 0 | none; prior 08-25 dispositions still hold |

Two documentation divergences found: `docs/XML_DATA_AUDIT.md:97` claims the
starter kit was moved to `zdtd.toml spawn_starter_kit` (no such key exists
anywhere in `src/` or `zdtd.toml.example`, and `ecs/world.zig` still hardcodes
it), and the "Known gaps" loot row claims `loot.zig rollContainer` fabricates
`resourceScrapIron x 5` (the code now fails closed, `assets/loot.zig:398-401`).

---

## Bucket A findings (stock game data)

| # | Location | Value / shape | Stock source | Sev | Fix shape | Default after fix | Test plan |
|---|---|---|---|---|---|---|---|
| A1 | `src/server/game/weather.zig:26`, pad/trim block `:39-62` (params at `:50`) | `const stock_count: usize = 5;` pins the `NetPackageWeather` body to 5 biome entries; `n < 5` pads by duplicating the last state, `n > 5` trims. The no-XML branch fabricates `.params = .{70, 0, 20, 10, 5}` for biome ids 1..5 | `biomes.xml` `biomeWeather.Count` = the loaded `biome_layers.Table.weather_n` (`assets/biome_layers.zig:206` states this count is what sizes the body on both ends) | **P1** | derive `wire_n` from `bl.weather_n`; keep the fabricated 5-entry block only when `bl.weather_n == 0` (offline) | Navezgane still 115 B (5 biomes); a 6-weather-biome install sends 6 x 23 | scenario in `server/scenarios.zig:4538` extended with a 6-biome fixture; loadgen join on a modlet biome set |
| A2 | `src/world/workstations.zig:326` (const at `:116`) | `default_fuel_burn_seconds: f32 = 10.0` is added whenever `caps.fuel_resolve` returns `<= 0`. With `--game-dir` the resolver IS wired (`hooks.itemFuelValue`), so a fuel item whose `FuelValue` is absent/0 burns an invented 10 s | `items.xml` `FuelValue` (coal 100 s, wood 1-5 s per the code's own cite) | **P3** | gate the fallback on `caps.fuel_resolve == null`; a wired resolver returning 0 consumes the item with no burn credit | offline tests unchanged; game-dir forge burns only real FuelValue | unit in `world/workstations.zig` with a resolver returning 0 |

Not a finding (verified): the demo generator's `100 W` floor is gated on
`!stock_catalogs_requested` (`init_world.zig:330-338`); turret watts resolve
`maxdamage.wattsByName("autoTurret")` (`hooks.zig:450`); the generatorbank
`MaxFuel`/`OutputPerFuel`/`OutputPerCharge` path is fully XML-driven
(`maxdamage.zig:765-810` -> `powerblocks.Resolved` -> `electric.PowerNode`).

## Bucket B findings (zdtd-owned config)

| # | Location | Value / shape | Destination | Sev | Fix shape | Default after fix | Test plan |
|---|---|---|---|---|---|---|---|
| B1 | `src/ecs/world.zig:1339-1349` | `spawnPlayer` hardcodes the 4-item starter kit and counts: stone axe x1, foodCanBeef x5, resourceWood x20, casinoCoin x50. Names resolve via `item_id_fn`, but the set and the quantities are zdtd policy | **new** `[sim] spawn_starter_kit` (or the existing `[sim]` surface) | **P2** | parse `"name:count,..."` once at init into a Game field; apply at fresh join, fail closed on unknown names. Also correct `docs/XML_DATA_AUDIT.md:97`, which already claims this was moved | identical kit when the key is unset | `zdtd_config.zig` parse+merge/clamp test; scenario asserts the default kit and a 1-item override |
| B2 | `src/server/game/init_world.zig:266` (hostiles, gated), `:281` (Trader Jen), `:287-297` (minibike), `:305-323` (seed chest), `:330-345` (virtual generator + turret) | `[sim] starter_zombies` gates only z1/z2/z3 + the animal. Trader Jen, the minibike, the seed chest (10 wood, 3 food) and the virtual generator+turret seed on every fresh world unconditionally | `[sim]` (extend the existing demo surface), or narrow the PROVENANCE 554 / DIVERGENCES 6.2 claim | **P2** | either one `[sim] demo_seed` switch covering all four, or split keys; at minimum fix the doc claim that "the demo seeds are switchable ... one key away" | `starter_zombies=true` unchanged (all demo seeds present) | scenario: `starter_zombies=false` then assert no trader/vehicle/chest/power node |
| B3 | `src/ecs/interest.zig:13` | `pos_heartbeat_period_ticks: u64 = 5` is the paired heartbeat of the tunable `[stream] motion_replicate_period_ticks`; the heartbeat itself is not operator-tunable (`game/replicate.zig:95,359`) | `[stream] pos_heartbeat_period_ticks` | **P3** | add the field on `Stream`/opts, default 5, clamp `>= 1` | 5 | config parse test + `needsPosSend` boundary test |
| B4 | `src/server/game/types.zig:26` | `max_land_claims: usize = 1024` sizes a fixed array (`game.zig:465`, `persist.zig:1902`); cannot become a runtime field without a layout change | leave (structural cap) | **P3** | not a config fix; keep named + documented | 1024 | n/a |

## OK false positives re-confirmed (with cites)

- `src/protocol.zig:152 damage_type_names` / `:171 max_physical_damage_type` -
  `EnumDamageTypes` ordinals + `Equipment::.cctor` IL=11 physical set. RE wire.
- `src/ecs/inventory.zig:68-69 place_wood_block_id / place_cobble_block_id` and
  `:72 offlineStockName` - live path is `itemToBlockResolved` via
  `items.place_block_name` + AssignIds (`hooks.zig:422-426`); the pins fire only
  when `items.source == .builtin and !stock_catalogs_requested`.
- `src/server/game.zig:3085,3100` storage/chest pins - both `return` on
  `stock_catalogs_requested` (offline-only).
- `src/world/store.zig:49 block_stone = assignids.terr_stone, :51 block_dirt` -
  alias only; production resolves through `TerrainIds.resolve` at world init
  (`test "resolveTerrainIds seeds default stack from live dump ids"` proves the
  live idByName path). All other `block_*` uses are test blocks.
- `src/assets/biome_layers.zig:849-858 testId` and `:989 testDecoId` - the
  `assignids.*` returns live inside test helpers / fixtures only; live paths
  call `stackFromLookup`/`loadFromPath` with `id_by_name`.
- `src/ecs/systems.zig` AI/combat floors (`attack_damage`, `chase_speed`,
  `full_dist_sq`, ...) - all `w.rules.ai.*` / `w.rules.combat.*` fields with
  mode-pack overlays (`ecs/rules.zig:56-395`); the literals at `:1599-1601`,
  `:3805`, `:4507` are test mocks.
- `src/ecs/world.zig:1757 dwell /= 3.0` - RE literal
  (`AIDirectorBloodMoonParty::SpawnZombie`); cited inline. Would be nicer as a
  named const but not a bucket violation.
- `src/assets/buffs.zig:947 tracked_names` - stock `passive_effect` property
  names (HealthChangeOT, ElementalDamageResist, ...), not a content enum.
- `src/server/game.zig:3186-3194 isBedrollId` - stock bedroll names resolved
  through `maxdamage.idByName`; no numeric ids.
- `src/world/biomes.zig:48-54 fallback_colors` - RGB->id table, offline only
  (`colorToId`); the live path loads `biomes.xml` `biomemapcolor` via
  `loadColorTable`.
- Absolute Steam paths in `src/assets/*` (`items.zig:2106,2218,2254..`,
  `buffs.zig`, `entities.zig`, `progression.zig`, `traders.zig`, `recipes.zig`,
  `spawning.zig`, `signs.zig`, `item_modifiers.zig`) and
  `src/world/sleepers.zig:612..` - inside `test` blocks with
  missing-install skips. Production never embeds them.
- `src/litenet/packet.zig` header sizes / `protocol_id` / `window_size`,
  `src/server/game/types.zig` body offsets (`speeds_body_off`, `flags_body_off`)
  - RE wire layout.
- `src/ecs/aidirector.zig:53 timeOfDayIncPerSec` - `24000/(DayNightLength*60)`
  integer arithmetic, RE server-lifecycle.md:168, live-verified.
- `src/ecs/rules.zig power.battery_capacity_scale/initial_charge_frac` -
  documented zdtd battery proxy, synced from `[rules.power]`
  (`init_assets.zig:659-660`).

## Bucket A loader-gap list (spot-check)

The maintained inventory is `docs/XML_DATA_AUDIT.md` "Per-file coverage"; I
re-checked the files this pass touched and found no new zero-loader file that
the server behaves as if it had:

| Stock file | Module | Call site | Status |
|---|---|---|---|
| biomes.xml | `assets/biome_layers.zig` (+ `world/biomes.zig`) | weather + layers + biomemap | **PARTIAL - A1 is the gap** (weather count hardcoded downstream in `game/weather.zig`) |
| blocks.xml | `assets/maxdamage.zig`, `blocks.zig`, `storage_pairs.zig`, `block_textures.zig` | power, HP, storage, tex | HAVE |
| items.xml | `assets/items.zig` | stack/fuel/econ/DamageEntity/Blockname | HAVE; A2 is a downstream fallback, not a missing parse |
| entityclasses.xml | `assets/entities.zig` | HP/speeds/damage/loot/dismember | HAVE (A34-A38 closed) |
| recipes/loot/quests/traders/vehicles/gamestages | `assets/*` | join/craft/loot/director | HAVE |
| archetypes/blockplaceholders/challenges/dialogs/music/physicsbodies/qualityinfo/rwgmixer/shapes/utilityai/weathersurvival/worldglobal/XUi_* | - | not consumed | NONE / client-only OK (out of scope, documented) |

## Bucket B final config schema (delta for the findings above)

```toml
[sim]
# spawn_starter_kit = "meleeToolRepairT0StoneAxe:1,foodCanBeef:5,resourceWood:20,casinoCoin:50"
#   names resolve through items.xml; unknown name -> omitted (fail closed).
# demo_seed = true        # trader + minibike + seed chest + demo power grid (hostiles stay starter_zombies)

[stream]
# pos_heartbeat_period_ticks = 5   # paired with motion_replicate_period_ticks (clamp >= 1)
```

Types / defaults / clamps: `spawn_starter_kit: ?[]const u8 = null` (parsed once
at Game.create, clamps entry count and count values to the item stack cap);
`demo_seed: ?bool = null` (null defaults to today's unconditional seeding);
`pos_heartbeat_period_ticks: ?u64 = null` clamped `1..=1000`. Precedence is the
existing documented chain (CLI > env > world zdtd.toml > CWD zdtd.toml > preset >
serverconfig > code defaults); no new parser, no new file.

## Ordered implementation plan

1. **A1** (P1): `game/weather.zig` body count from `biome_layers.Table.weather_n`.
   Smallest change that removes a client `Read` risk on any non-5-biome install.
2. **B1** (P2): `[sim] spawn_starter_kit` + fix the stale `XML_DATA_AUDIT.md:97`
   row (doc currently claims a fix that is not in the tree).
3. **B2** (P2): one `[sim] demo_seed` switch (or narrow the PROVENANCE 554 /
   DIVERGENCES 6.2 wording) so `starter_zombies=false` really is stock-lazy.
4. **A2** (P3): gate `default_fuel_burn_seconds` on `caps.fuel_resolve == null`.
5. **B3** (P3): `[stream] pos_heartbeat_period_ticks`.
6. Docs after 1-5: `ASSETS.md`/`GAME_OPTIONS.md` rows for the new keys,
   `XML_DATA_AUDIT.md` starter-kit + loot-fallback corrections,
   `PROVENANCE.md` demo-seed row. Then `make check` (the xml-audit gate will
   require `spawn_starter_kit`'s names be added to its allowlist or resolved
   through the items table, which is the intended shape).

## Could not verify / needs RE

- That the stock client sizes `NetPackageWeather` from `biomeWeather.Count`:
  cited from `assets/biome_layers.zig:206` + `game/weather.zig:21-23`, not
  re-derived from IL this pass. Confirming it in
  `../7dtd-engine-research` would let A1 be a P0 call rather than P1.
- Whether every stock forge-fuel item carries `FuelValue` (A2 reachability):
  grep `$GAME/Data/Config/items.xml` for `FuelValue` on the fuel tags. If all
  do, A2 is an unreachable-in-stock hygiene fix.
- `max_land_claims=1024` and `litenet max_peers=64` as operator limits: both
  are fixed-array sizes, so any config surface is cosmetic without a storage
  redesign (kept as P3 leave).
