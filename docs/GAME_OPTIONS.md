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
| `<world>/zdtd.toml` then CWD `zdtd.toml` | stream/authority/feature + optional `[mode] name`; first existing file wins; **fatal** if present but unreadable |
| Mode pack `modes/<name>.toml` | When `--mode` or `[mode] name` is set: data-only InitOptions overrides (after serverconfig, before stream keys) |
| `--serverconfig path` | Stock-like XML; **fatal** if the path cannot be read |
| Code defaults | Used when neither CLI nor file sets a value |

Startup prints a one-line effective summary (`password=set|open`, never secrets).
`AdminPort` binds **127.0.0.1 only** (no auth on the console).
`ServerMaxPlayerCount` is applied to GSI ads and soft join capacity (capped at 64).
Out-of-range serverconfig values are clamped with a stderr warning (not silent).
Unknown stock properties are ignored (stock configs have many keys zdtd does not
apply). Near-miss typos of applied keys (edit distance ≤2) print a stderr hint.
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
| `ZombieMove` / `Night` / `Feral` / `BMMove` | 0/3/3/3 | 0..4 | zombie speed per day/night/feral/blood-moon → `World.zombie_speed_scale` |
| `EnemyDifficulty` | 0 | 0..1 | 1 = feral (always feral speed) |
| `LootAbundance` | 100 | 1..1000 | percent multiplier on rolled loot stack counts (`LootTable.scaleCount`) |
| `XPMultiplier` | 100 | 1..1000 | scales server XP awarded per kill (`Game.awardXp`, `Client.xp`) |
| `BlockDamagePlayer` | 100 | 1..1000 | scales player dig damage in `NetPackageSetBlock` |
| `BlockDamageAI` | 100 | 0..1000 | zombies chew through cover blocks (`tickZombieBlockDamage`) |
| `BlockDamageAIBM` | 100 | 0..1000 | as above during a blood moon |
| `AirDropFrequency` | 72 | 0..8760 | game-hours between supply-crate drops; 0 off (`tickAirDrop`) |
| `DropOnDeath` | 1 | 0..4 | 0 nothing / 1 all / 2 toolbelt / 3 backpack / 4 delete → loot bag on death |
| `LandClaimSize` | 41 | 1..255 (odd) | keystone protection area; even values forced odd |
| `LandClaimOnlineDurabilityModifier` | 4 | 0..64 | own-claim block hp ×N while owner online |
| `LandClaimOfflineDurabilityModifier` | 4 | 0..64 | own-claim block hp ×N while owner offline |
| `ServerPort` | 26902 | u16 | TCP GameServerInfo; LiteNet = port+2 (CLI `--port` wins) |
| `ServerMaxPlayerCount` | 8 | 1..64 | GSI max + soft join cap |
| `ServerPassword` | empty | string | LiteNet Connect key; empty = open |
| `ViewRadius` | 7 | 1..16 | stream / interest seed radius |
| `GameName` / `GameWorld` | zdtd / empty | string | world identity / stock map folder under `--game-dir` |
| `AdminPort` | 0 | u16 | unauthenticated admin TCP on 127.0.0.1; 0 = off |
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
| `[stream]` | `max_streamed_chunks`, `stream_radius_min/max`, period ticks, … | Chunk stream caps (clamped to compile cap 169) |
| `[authority]` | `interest_range_blocks`, `max_edit_range_blocks`, `max_claimed_damage`, `peer_stale_ms`, `mode` | C2S range / interest / mode |
| `[feature]` | `wire_chunks`, `deco_trees`, `deco_mirror`, `block_id_mapping` | `wire_chunks`: stream NetPackageChunk (default true). `deco_trees`: join-time deco burst (default true); false sends the empty firstPackage only. `deco_mirror`: write placed deco into the block store so collision and harvest match the client (default true). `block_id_mapping`: send the full `blocks` NameIdMapping before the config files so block ids are negotiated instead of trusted (default true); false for a modded client whose block set differs from ours |
| `[perf]` | `async_chunk_flush`, `terrain_snapshot`, `job_batches` | Performance switches, all default false. Each ships with an always-on apm section/counter that must show the cost before it is worth enabling; see `docs/SCALE_ARCHITECTURE.md` |
| `[mode]` | `name` | Select gamemode pack `modes/<name>.toml` (CLI `--mode` wins) |

### Gamemode packs (`modes/`)

ADR 0010: a **mode** is a data-only config pack plus optional static plugin flag.
No script VM. Sample: [`modes/default.toml`](../modes/default.toml). Loader:
`src/server/mode.zig`.

| Key | Effect on `InitOptions` |
|---|---|
| `max_spawned_zombies` | Director alive-zombie cap |
| `blood_moon_frequency` (alias `bloodmoon_frequency`) | Blood moon every N days |
| `enable_sample_plugin` | Register in-tree `sample_hello` static plugin (host already exists) |

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
| `<world>/players.zsv` | Login name, last position, coins, inventory stacks, quest journal | Kept until `wipeplayer <name>` or the operator deletes the file/world |
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
