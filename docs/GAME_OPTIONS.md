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
| CLI (`--port`, `--admin-port`, `--world-name`, …) | Highest; overrides matching file keys |
| `--serverconfig path` | Stock-like XML; **fatal** if the path cannot be read |
| Code defaults | Used when neither CLI nor file sets a value |

Startup prints a one-line effective summary (`password=set|open`, never the secret).
`AdminPort` binds **127.0.0.1 only** (no auth on the console).
`ServerMaxPlayerCount` is applied to GSI ads and soft join capacity (capped at 64).

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

Notes:
- Land claims register on keystone (`keystoneBlock`) placement, owned by the
  placing player. Non-owners' `SetBlock` edits inside the area are denied; the
  owner's own claimed blocks take the durability multiplier.
- Air drops spawn a loot bag (supply crate) above a joined player on schedule.
- XP is a server-side ledger (the stock client also tracks its own XP locally
  under EAC-off); the multiplier governs the server total used for gamestage-type
  logic.

## Missing world folder

A serverconfig `GameName`/`GameWorld` that resolves to a non-existent world dir
does not abort startup: `io_fs.dirExistsSimple` detects the missing directory and
the server falls back to a flat world with a warning.
