# Server game options (serverconfig.xml)

`src/server/config.zig` parses the stock `serverconfig.xml` `<property>` list.
Every gameplay option below is read with the same name/default as the stock
dedicated server and **applied to the sim** (`game.initWithOptions` + runtime
systems). Out-of-range values are clamped (see `clampU8` / `clampRange` and the
config tests).

Example template: [`serverconfig.example.xml`](../serverconfig.example.xml).

## Loading and precedence

| Source | Role |
|---|---|
| CLI (`--port`, `--mode`, `--admin-port`, `--webui-port`, `--world-name`, …) | Highest; overrides matching file keys |
| Env `ZDTD_WEBUI_SECRET` | Web UI secret when `--webui-secret` is unset (prefer env: not in `ps`) |
| `<world>/zdtd.toml` then CWD `zdtd.toml` | stream/authority/feature/sim/plugin + optional `[mode] name`; first existing file wins; **fatal** if present but unreadable |
| Mode pack `modes/<name>.toml` | When `--mode` or `[mode] name` is set: data-only InitOptions + `[rules.*]` sim-rule overrides (after serverconfig, before stream keys; `zdtd.toml` wins on a rules key) |
| `--serverconfig path` | Stock-like XML; **fatal** if the path cannot be read |
| Code defaults | Used when neither CLI nor file sets a value |

Startup prints a one-line effective summary (`password=set|open`, never secrets).
The console binds **127.0.0.1 only** unless `TelnetPassword` is set, matching
stock `TelnetConsole::.ctor`; a password is the only way it leaves loopback.
`ServerMaxPlayerCount` is applied to GSI ads and soft join capacity (capped at 64).
Out-of-range serverconfig values are clamped with a stderr warning (not silent).
Non-numeric values for applied integer keys keep the previous default and print
a named stderr warning (same shape as invalid `ServerPort`). Unknown stock
properties are ignored (stock configs have many keys zdtd does not apply).
Near-miss typos of applied keys (edit distance ≤2) print a stderr hint.
TCP listen collisions among ServerPort, AdminPort/TelnetPort, and webui port
abort startup (LiteNet uses UDP port+2 and is not checked against TCP).
`zdtd.toml` / mode-pack stream knobs are sanitized after merge even when no
toml file is present. Invalid authority modes and mode-file name mismatches
abort startup. Operator config reads are size-bounded (1 MiB serverconfig,
256 KiB zdtd.toml, 64 KiB mode pack). Webui listen failures abort startup.

## Applied to the sim

| Property | Default | Range | Effect + where |
|---|---|---|---|
| `GameDifficulty` | 2 | 0..5 | zombie hp scale 0.5×–2.0× (`Director.hpScale`) |
| `BloodMoonFrequency` | 7 | 0..255 | blood moon every N days; 0 disables (`WorldClock.isBloodMoonNight`) |
| `BloodMoonRange` | 0 | 0..15 | deterministic ±day jitter of the blood-moon day per cycle |
| `BloodMoonEnemyCount` | 8 | 0..60 | zombies per blood-moon spawn burst |
| `PlayerKillingMode` | 3 | 0..3 | 0 drops player→player `DamageEntity` (PvP off) |
| `DayNightLength` | 60 | 10..1200 | real minutes per full day → `WorldClock.seconds_per_hour` |
| `DayLightLength` | 18 | 1..23 | daylight window; dawn 04:00, dusk = 4 + value |
| `MaxSpawnedZombies` | 64 | 1..2048 | server-wide alive-zombie cap (`Director.max_alive`) |
| `MaxSpawnedAnimals` | 50 | 0..2048 | daytime wildlife cap + spawner (`Director.spawnAnimalsNearPlayers`) |
| `ZombieMove` / `ZombieMoveNight` / `ZombieFeralMove` / `ZombieBMMove` | 0/3/3/3 | 0..4 | zombie speed per day/night/feral/blood-moon → `World.zombie_speed_scale` |
| `EnemyDifficulty` | 0 | 0..1 | 1 = feral (always feral speed) |
| `LootAbundance` | 100 | 1..1000 | percent multiplier on rolled loot stack counts (`LootTable.scaleCount`) |
| `LootRespawnDays` | 7 | 0..365 | days after a world container is touched until it re-rolls loot on its next open (0 = never respawn; `Game.loot_respawn_days`, `maybeRespawnContainer`) |
| `XPMultiplier` | 100 | 1..1000 | scales server XP awarded per kill (`Game.awardXp`, `Client.xp`) |
| `BlockDamagePlayer` | 100 | 1..1000 | scales player dig damage in `NetPackageSetBlock` |
| `BlockDamageAI` | 100 | 0..1000 | zombies chew through cover blocks (`tickZombieBlockDamage`) |
| `BlockDamageAIBM` | 100 | 0..1000 | as above during a blood moon |
| `AirDropFrequency` | 72 | 0..8760 | game-hours between supply-crate drops; 0 off (`tickAirDrop`) |
| `DropOnDeath` | 1 | 0..4 | 0 nothing / 1 all / 2 toolbelt / 3 backpack / 4 delete → loot bag on death |
| `LandClaimSize` | 41 | 1..255 (odd) | keystone protection area; even values forced odd |
| `LandClaimOnlineDurabilityModifier` | 4 | 0..64 | own-claim block hp ×N while owner online |
| `LandClaimOfflineDurabilityModifier` | 4 | 0..64 | own-claim block hp ×N while owner offline |
| `LandClaimExpiryDays` | 3 | 0..365 | offline days without owner online before claim is released (0 = never; `Game.land_claim_expiry_days`) |
| `ServerPort` | 26902 | 0..65533 | TCP GameServerInfo; LiteNet = port+2 (CLI `--port` wins); values above 65533 abort startup |

| `ServerMaxPlayerCount` | 8 | 1..64 | GSI max + soft join cap |
| `ServerPassword` | empty | string | LiteNet Connect key; empty = open |
| `ViewRadius` | 7 | 1..16 | stream / interest seed radius |
| `GameName` / `GameWorld` | zdtd / empty | string | world identity / stock map folder under `--game-dir` |
| `AdminPort` | 0 | u16 | zdtd alias for the console port; 0 = off |
| `TelnetEnabled` | false | bool | enable the stock telnet console (`TelnetPort` then wins over `AdminPort`) |
| `TelnetPort` | 0 | u16 | stock telnet port; 0 = off |
| `TelnetPassword` | empty | string | empty = no login and loopback bind; set = stock login prompt and INADDR_ANY bind |
| `TelnetFailedLoginLimit` | 10 | 1..255 | failed logins before the session is dropped |
| `TelnetFailedLoginsBlocktime` | 10 | 0..1440 | minutes a source address stays blocked (parsed; enforcement pending) |
| `ZdtdAuthorityMode` | correct | observe\|permissive\|correct | C2S Hard reject ladder; see [AUTHORITY.md](AUTHORITY.md) |

### Web UI (CLI / env; WU0–WU2 shipped)

| Flag / env | Default | Notes |
|---|---|---|
| `--webui-port` | 0 | HTTP ops UI; 0 = off. Requires a secret. Design: [WEBUI.md](WEBUI.md) |
| `--webui-bind` | `127.0.0.1` | IPv4 loopback only; use a TLS reverse proxy for remote access |
| `--webui-secret` | empty | Bearer / `X-Zdtd-Secret` / login form; min 8 chars; visible in `ps` (prefer env) |
| `ZDTD_WEBUI_SECRET` | unset | Used when CLI secret is empty; refuse start if port≠0 and both empty; min 8 chars |

`GET`/`HEAD` `/healthz` is unauthenticated liveness. `GET`/`HEAD` `/readyz` is unauthenticated readiness and returns 503 until the first live tick snapshot. Dashboard + `POST /api/cmd` (admin verbs) need secret; CSRF field required for cookie-only sessions. `Accept: text/plain` on `/api/cmd` returns a plain body instead of an HTML fragment.

### zdtd.toml (operator tunables)

Template: [`zdtd.toml.example`](../zdtd.toml.example). Loaded from
`<world>/zdtd.toml` if present, else CWD `zdtd.toml`. Parser:
`src/server/zdtd_config.zig`. Unknown keys and malformed assignments abort
startup so misspelled operator settings cannot silently use defaults.

| Section | Keys (subset) | Effect |
|---|---|---|
| `[stream]` | `max_streamed_chunks`, `stream_radius_min/max`, `chunk_adds_per_stream_tick`, `chunk_stream_period_ticks`, `motion_replicate_period_ticks`, `world_time_send_ticks`, `vehicle_pos_send_ticks`, `sleeper_tick_ticks`, `turret_sync_ticks`, `save_interval_ticks`, `spawn_area_radius_max` | Chunk stream caps (clamped to compile cap 169) + broadcast/side-work cadences in ticks. `sleeper_tick_ticks` gates prefab sleeper volumes, airdrops and workstations; `turret_sync_ticks` gates turret state broadcasts; `save_interval_ticks` gates the periodic world flush |
| `[authority]` | `interest_range_blocks`, `max_edit_range_blocks`, `max_claimed_damage`, `peer_stale_ms`, `mode` | C2S range / interest / mode |
| `[feature]` | `wire_chunks`, `deco_trees`, `deco_mirror`, `block_id_mapping` | `wire_chunks`: stream NetPackageChunk (default true). `deco_trees`: join-time deco burst (default true); false sends the empty firstPackage only. `deco_mirror`: write placed deco into the block store so collision and harvest match the client (default true). `block_id_mapping`: send the full `blocks` NameIdMapping before the config files so block ids are negotiated instead of trusted (default true); false for a modded client whose block set differs from ours |
| `[perf]` | `async_chunk_flush`, `terrain_snapshot`, `job_batches` | Performance switches, all default false. Each ships with an always-on apm section/counter that must show the cost before it is worth enabling; see `docs/SCALE_ARCHITECTURE.md` |
| `[sim]` | `trader_wallet_dukes`, `min_chat_gap_ns`, `inv_bucket_cap`, `inv_refill_ns`, `block_bucket_cap`, `block_refill_ns`, `min_damage_gap_ns`, `damage_burst_max`, `trader_restock_cap`, `trader_restock_refill`, `storm_frequency` | `trader_wallet_dukes`: Trader `AvailableMoney` display pool (default 5000). Not stock data: `traders.xml` has no wallet key; stock `AvailableMoney` is engine-managed per-day, and zdtd credits the player wallet directly. The rest are per-peer anti-abuse gates: chat broadcast gap, inv/block token bucket shape (mono-ns refill), and the damage-accept gap + burst cap. `trader_restock_cap`/`trader_restock_refill` set the trader restock refill policy (stackables grow toward the cap by at most the refill per restock). `storm_frequency`: `World::StormFrequency` percent (default 100 = 1.0x; 0 disables storms). V3.1.0 ships no serverconfig key for it (world state in the GameStats blob), so this is the zdtd.toml surface; it feeds both the weather scheduler divisor and the wire value the client is told. Defaults match the previous code constants |
| `[mode]` | `name` | Select gamemode pack `modes/<name>.toml` (CLI `--mode` wins) |
| `[rules.combat]` / `[rules.ai]` / `[rules.bloodmoon]` | any `Rules` field | Sim-rule overlay (ADR 0021), merged over the mode pack so `zdtd.toml` wins; see the `[rules]` section below |
| `[plugin]` | `modules` | Comma-separated `.wasm` paths for the Wasm plugin runtime (ADR 0020, [PLUGIN_DEV.md](PLUGIN_DEV.md)); empty default = no Wasm plugins |

### `[rules]` sim rules (mode packs and zdtd.toml)

ADR 0021: the sim's rule parameters live in one `Rules` struct
(`src/ecs/rules.zig`) read as `w.rules.<group>.<field>`. Both a mode pack and
`zdtd.toml` can set them under `[rules.<group>]` sections (dotted keys); the
binder reflects the struct, so this table is the struct and the struct is the
parser (adding a tunable is one field + one row). Precedence for a key set in
both: **zdtd.toml wins over the mode pack** (operator wins), matching the
top-level order.

Defaults equal the pre-move code constants (pinned by the `Rules` defaults
test, so a retune cannot land silently).

| Section / key | Default | Floor / policy |
|---|---|---|
| `[rules.combat]` | | |
| `attack_damage` | 8.0 | **Floor**: `entityclasses.xml` `HandItem` → `items.xml` `DamageEntity` wins when non-zero |
| `attack_range_sq` | 4.0 | Policy (no per-entity stock equivalent) |
| `attack_cooldown_s` | 1.2 | Policy (no entityclasses field) |
| `[rules.ai]` | | |
| `full_dist_sq` | 4096.0 | Policy (AI LOD step) |
| `mid_dist_sq` | 225.0 | Policy (AI LOD step) |
| `sense_dist_sq` | 2304.0 | Policy (sense range) |
| `despawn_dist_sq` | 40000.0 | Policy (far-despawn range) |
| `chase_speed` | 2.2 | **Floor**: `entityclasses.xml` `MoveSpeedAggro` wins when non-zero |
| `wander_speed` | 0.8 | **Floor**: `entityclasses.xml` `MoveSpeed` wins when non-zero |
| `[rules.bloodmoon]` | | |
| `party_join_dist` | 80.0 | Policy (AIDirectorBloodMoonParty constant) |
| `party_teleport_dist` | 150.0 | Policy (AIDirectorBloodMoonParty constant) |
| `party_spawn_dist` | 40.0 | Policy (AIDirectorBloodMoonParty constant) |
| `party_enemy_max` | 30 | Policy (cPartyEnemyMax) |
| `max_parties` | 8 | Policy; clamped to the storage array bound at use |
| `[rules.progression]` | | |
| `food_depletion_per_hour` | 2.0 | Policy (GAP 22 survival): Food units lost per in-game hour; stock applies FoodChangeOT through Stat.Tick whose per-effect default is not in the V3.1.0 IL corpus, so the rate is operator-tunable |
| `water_depletion_per_hour` | 2.5 | Policy (GAP 22 survival): Water units lost per in-game hour |
| `starvation_damage_per_hour` | 12.0 | Policy: HP lost per in-game hour while Food or Water is exhausted (UpdatePlayerHealthOT starvation branch) |
| `well_fed_regen_per_hour` | 10.0 | Policy: HP regenerated per in-game hour while fed and hydrated |
| `well_fed_threshold` | 80.0 | Policy: Food/Water above this count as well-fed |
| `stamina_drain_per_second` | 12.0 | Policy (GAP 22): Stamina drained per real second while sprinting (MovementState 3) |
| `stamina_regen_per_second` | 8.0 | Policy (GAP 22): Stamina regenerated per real second while not sprinting |
| `sprint_stale_seconds` | 0.5 | Policy (GAP 22): seconds without an EntitySpeeds update before the sprint latch lapses |
| `survival_sync_seconds` | 2.0 | Policy: per-player survival S2C refresh throttle |
| `[rules.world]` | (empty) | Added as constants move; no fields invented |

A mode that wants every zombie to hit harder gets a multiplier on the resolved
per-entity value (the `zombie_speed_scale` shape), never a global that discards
`entityclasses.xml` (ADR 0021 decision 5, [HARDCODE_AUDIT.md](reviews/HARDCODE_AUDIT.md)).

### Gamemode packs (`modes/`)

ADR 0010: a **mode** is a data-only config pack plus optional static plugin flag.
No script VM. Sample: [`modes/default.toml`](../modes/default.toml). Loader:
`src/server/mode.zig`.

| Key | Effect on `InitOptions` |
|---|---|
| `max_spawned_zombies` | Director alive-zombie cap (1..2048) |
| `blood_moon_frequency` (alias `bloodmoon_frequency`) | Blood moon every N days |
| `game_difficulty` | 0..5 zombie hp scale |
| `blood_moon_enemy_count` | zombies per blood-moon burst (0..60) |
| `blood_moon_range` | ±day jitter (0..15) |
| `player_killing_mode` | 0..3 PvP gate |
| `day_night_length` / `day_light_length` | real minutes per day (10..1200) / daylight hours (1..23) |
| `zombie_move` / `zombie_move_night` / `zombie_feral_move` / `zombie_bm_move` | 0..4 speed band per state |
| `enemy_difficulty` | 0 normal, 1 feral |
| `loot_abundance` / `xp_multiplier` | percent (1..1000) |
| `block_damage_player` / `block_damage_ai` / `block_damage_ai_bm` | percent (1..1000) |
| `max_spawned_animals` | daytime wildlife cap (0..2048) |
| `air_drop_frequency` | hours (0..168) |
| `drop_on_death` | 0 nothing, 1 all, 2 toolbelt, 3 backpack, 4 delete |
| `land_claim_size` / `land_claim_online_durability_modifier` / `land_claim_offline_durability_modifier` / `land_claim_expiry_days` | claim geometry and decay |
| `loot_respawn_days` | container re-roll interval (0..365) |
| `enable_sample_plugin` | Register in-tree `sample_hello` static plugin (host already exists) |
| `[rules.*]` sections | Any `Rules` field via `[rules.combat]`, `[rules.ai]`, `[rules.bloodmoon]` (see above) |

Only the keys you set override; everything else falls through to
`serverconfig.xml`, `zdtd.toml` and code defaults. A mode is a complete
behavior pack — `hardcore.toml` = `player_killing_mode = 0`,
`drop_on_death = 1`, `game_difficulty = 4`, plus `[rules.combat]`
`attack_damage = 14`, and so on — no code involved.

Shipped examples that exercise the rules surface: [`modes/horde_lite.toml`](../modes/horde_lite.toml)
(softer) and [`modes/survival_crunch.toml`](../modes/survival_crunch.toml) (harsher).

Select with `--mode default` or `zdtd.toml` `[mode] name = "default"`. Name must
be `[A-Za-z0-9_]` only (no path segments). Missing file is fatal when selected.
Unknown keys, unknown sections, and malformed assignments are also fatal so a
misspelled mode setting cannot silently fall back to a default.

Notes:
- Land claims register on keystone (`keystoneBlock`) placement, owned by the
  placing player. Non-owners' `SetBlock` edits inside the area are denied; the
  owner's own claimed blocks take the durability multiplier.
- Air drops spawn a loot bag (supply crate) above a joined player on schedule.
- XP is a server-side ledger (the stock client also tracks its own XP locally
  under EAC-off); the multiplier governs the server total used for gamestage-type
  logic.

## Player data (operators)

Self-hosted only: zdtd does not phone home. Player-related data stays on the
operator host under the world directory and on the wire between client and server.

| Store / surface | Contents | Retention / control |
|---|---|---|
| `<world>/players.zsv` | Login name, last position, coins, inventory stacks, quest journal, progression (level/XP/food/water/buffs); magic ZPV3 (ZPV2 still read) | Kept until `wipeplayer <name>` or the operator deletes the file/world |
| In-memory ban table | IPv4 keys from admin `ban` | Process lifetime only (not written to disk) |
| Admin TCP / WebUI | Player names, slots, inventory dump (`inv`) for ops | Loopback admin (no auth); WebUI requires secret, default off |
| Process logs | Join/slot/entity ids, name **lengths**, reject reasons | Never full login names or WebUI/server passwords |

Admin: `wipeplayer <name>` kicks any online session with that name and removes
matching records from `players.zsv`. Counts are logged; the name is not.

## Missing world folder

A configured `GameName`/`GameWorld` that resolves to a non-existent world dir
aborts startup. This prevents a misspelled or stale map setting from silently
starting a new flat world. Omit the configured stock world to intentionally use
the default flat world.
