# core_killfeed

Kill/death/quest observer

## What it is

Logs kill, death and quest events via the observer hooks.

## Hooks / surface

`on_entity_killed`, `on_player_death`, `on_quest_complete`, `on_enable`, `on_shutdown`.

## Config

`config.toml`: `log_level = "debug"` (observer verbosity: off | info | debug). Edit the file, no rebuild.

## Enable

Ships `enabled = false` (demo gate). Load explicitly via `[plugin] modules`.

## Layout (self-contained)

- `manifest.toml` - module manifest (name, tier, hooks)
- `core_killfeed.wasm` - committed build of `core_killfeed.zig`
- `core_killfeed.zig` + `main.zig` - Zig source (rebuild: `scripts/build-plugins.sh`)
- `config.toml` - default config, served to the module via the `zdtd.config` import
- `README.md` - this file

All policy lives in this folder: no behavior is hardcoded in the host.
