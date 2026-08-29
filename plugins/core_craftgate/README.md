# core_craftgate

Craft deny gate

## What it is

Denies craft requests for recipes named `forbidden_*` via the `on_craft_request` verdict.

## Hooks / surface

`on_craft_request` (verdict: <0 deny), `on_enable`, `on_shutdown`.

## Config

`config.toml`: `deny_prefix = "forbidden_"` (recipes whose name starts with this prefix are denied). Edit the file, no rebuild.

## Enable

Ships `enabled = false` (demo gate). Load explicitly via `[plugin] modules`.

## Layout (self-contained)

- `manifest.toml` - module manifest (name, tier, hooks)
- `core_craftgate.wasm` - committed build of `core_craftgate.zig`
- `core_craftgate.zig` + `main.zig` - Zig source (rebuild: `scripts/build-plugins.sh`)
- `config.toml` - default config, served to the module via the `zdtd.config` import
- `README.md` - this file

All policy lives in this folder: no behavior is hardcoded in the host.
