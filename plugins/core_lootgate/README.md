# core_lootgate

Loot scaling gate

## What it is

Scales loot rolls to 50% via the `on_loot_roll` verdict.

## Hooks / surface

`on_loot_roll` (verdict: <0 deny, >0 percent), `on_enable`, `on_shutdown`.

## Config

`config.toml`: `percent = 50` (percent of the rolled stack count to apply; 0 keeps, <0 denies). Edit the file, no rebuild.

## Enable

Ships `enabled = false` (demo gate). Load explicitly via `[plugin] modules`.

## Layout (self-contained)

- `manifest.toml` - module manifest (name, tier, hooks)
- `core_lootgate.wasm` - committed build of `core_lootgate.zig`
- `core_lootgate.zig` + `main.zig` - Zig source (rebuild: `scripts/build-plugins.sh`)
- `config.toml` - default config, served to the module via the `zdtd.config` import
- `README.md` - this file

All policy lives in this folder: no behavior is hardcoded in the host.
