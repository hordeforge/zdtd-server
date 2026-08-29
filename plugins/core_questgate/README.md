# core_questgate

Quest accept gate

## What it is

Gates quest acceptance via the `on_quest_accept` verdict (queries the quest def before deciding).

## Hooks / surface

`on_quest_accept` (verdict: <0 deny), `zdtd.query`, `on_enable`, `on_shutdown`.

## Config

None shipped.

## Enable

Ships `enabled = false` (demo gate). Load explicitly via `[plugin] modules`.

## Layout (self-contained)

- `manifest.toml` - module manifest (name, tier, hooks)
- `core_questgate.wasm` - committed build of `core_questgate.zig`
- `core_questgate.zig` + `main.zig` - Zig source (rebuild: `scripts/build-plugins.sh`)
- `config.toml` - default config, served to the module via the `zdtd.config` import
- `README.md` - this file

All policy lives in this folder: no behavior is hardcoded in the host.
