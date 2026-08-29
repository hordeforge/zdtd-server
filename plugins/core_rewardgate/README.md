# core_rewardgate

Quest reward scaling

## What it is

Scales quest rewards to 1.5x via the `on_quest_complete` verdict (specialize per quest_def).

## Hooks / surface

`on_quest_complete` (verdict: <0 withhold, >0 percent), `on_enable`, `on_shutdown`.

## Config

`config.toml`: `percent = 150` (percent of the quest payout to grant; 0 keeps, <0 withholds). Edit the file, no rebuild.

## Enable

Ships `enabled = false` (demo gate). Load explicitly via `[plugin] modules`.

## Layout (self-contained)

- `manifest.toml` - module manifest (name, tier, hooks)
- `core_rewardgate.wasm` - committed build of `core_rewardgate.zig`
- `core_rewardgate.zig` + `main.zig` - Zig source (rebuild: `scripts/build-plugins.sh`)
- `config.toml` - default config, served to the module via the `zdtd.config` import
- `README.md` - this file

All policy lives in this folder: no behavior is hardcoded in the host.
