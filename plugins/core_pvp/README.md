# core_pvp

PvP damage gate

## What it is

Denies player-vs-player damage via the `on_player_damage` verdict.

## Hooks / surface

`on_player_damage` (verdict: <0 deny), `on_enable`, `on_shutdown`.

## Config

None shipped; the deny-everything policy is the module's.

## Enable

Ships `enabled = false` (demo gate). Load explicitly via `[plugin] modules`.

## Layout (self-contained)

- `manifest.toml` - module manifest (name, tier, hooks)
- `core_pvp.wasm` - committed build of `core_pvp.zig`
- `core_pvp.zig` + `main.zig` - Zig source (rebuild: `scripts/build-plugins.sh`)
- `config.toml` - default config, served to the module via the `zdtd.config` import
- `README.md` - this file

All policy lives in this folder: no behavior is hardcoded in the host.
