# core_damagegate

Incoming player damage scaling

## What it is

Scales incoming player damage via the `on_player_damage` verdict (0.5x default; specialize per attacker).

## Hooks / surface

`on_player_damage` (verdict: <0 deny, >0 percent), `on_enable`, `on_shutdown`.

## Config

None shipped; the 0.5x default is the module's policy.

## Enable

Ships `enabled = false` (demo gate). Load explicitly via `[plugin] modules`.

## Layout (self-contained)

- `manifest.toml` - module manifest (name, tier, hooks)
- `core_damagegate.wasm` - committed build of `core_damagegate.zig`
- `core_damagegate.zig` + `main.zig` - Zig source (rebuild: `scripts/build-plugins.sh`)
- `config.toml` - default config, served to the module via the `zdtd.config` import
- `README.md` - this file

All policy lives in this folder: no behavior is hardcoded in the host.
