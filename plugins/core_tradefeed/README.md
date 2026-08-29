# core_tradefeed

Trader event observer

## What it is

Observes trade open / sell / buy events via the `on_trader_event` hook.

## Hooks / surface

`on_trader_event` (observer), `on_enable`, `on_shutdown`.

## Config

`config.toml`: `log_level = "debug"` (observer verbosity: off | info | debug). Edit the file, no rebuild.

## Enable

Ships `enabled = false` (demo gate). Load explicitly via `[plugin] modules`.

## Layout (self-contained)

- `manifest.toml` - module manifest (name, tier, hooks)
- `core_tradefeed.wasm` - committed build of `core_tradefeed.zig`
- `core_tradefeed.zig` + `main.zig` - Zig source (rebuild: `scripts/build-plugins.sh`)
- `config.toml` - default config, served to the module via the `zdtd.config` import
- `README.md` - this file

All policy lives in this folder: no behavior is hardcoded in the host.
