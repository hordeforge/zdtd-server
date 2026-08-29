# core_adminverbs

Admin verb addon

## What it is

Extends the admin console: `wave <n>` verb via the `on_admin_command` request/reply hook.

## Hooks / surface

`on_admin_command` (request/reply), `on_enable`, `on_shutdown`.

## Config

`config.toml`: `spawn_x/spawn_y/spawn_z` (256/70/256) and `spawn_entity` (100) - what the `wave <n>` verb spawns and where. Edit the file, no rebuild.

## Enable

Ships `enabled = false` (demo gate). Load explicitly via `[plugin] modules = "plugins/core_adminverbs/core_adminverbs.wasm"` in zdtd.toml.

## Layout (self-contained)

- `manifest.toml` - module manifest (name, tier, hooks)
- `core_adminverbs.wasm` - committed build of `core_adminverbs.zig`
- `core_adminverbs.zig` + `main.zig` - Zig source (rebuild: `scripts/build-plugins.sh`)
- `config.toml` - default config, served to the module via the `zdtd.config` import
- `README.md` - this file

All policy lives in this folder: no behavior is hardcoded in the host.
