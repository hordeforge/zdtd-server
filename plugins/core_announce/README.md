# core_announce

Day + blood-moon announcements

## What it is

Broadcasts day changes and blood-moon rise/fade announcements over chat (`say`) on the `on_tick` observer.

## Hooks / surface

`on_tick`, `on_enable`, `on_shutdown`.

## Config

`config.toml`: `day_prefix`, `blood_moon_rise`, `blood_moon_fade`, `join_message`, `leave_message`. Edit the file, no rebuild.

## Enable

Ships `enabled = false` (demo gate). Load explicitly via `[plugin] modules`.

## Layout (self-contained)

- `manifest.toml` - module manifest (name, tier, hooks)
- `core_announce.wasm` - committed build of `core_announce.zig`
- `core_announce.zig` + `main.zig` - Zig source (rebuild: `scripts/build-plugins.sh`)
- `config.toml` - default config, served to the module via the `zdtd.config` import
- `README.md` - this file

All policy lives in this folder: no behavior is hardcoded in the host.
