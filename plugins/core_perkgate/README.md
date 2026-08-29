# core_perkgate

Perk spend gate

## What it is

Denies perk purchases for perks named `forbidden_*` via the `on_perk_spend` verdict (ADR 0033).

## Hooks / surface

`on_perk_spend` (verdict: <0 deny), `on_enable`, `on_shutdown`.

## Config

None shipped; the deny prefix is the module's policy.

## Enable

Ships `enabled = false` (demo gate). Load explicitly via `[plugin] modules`.

## Layout (self-contained)

- `manifest.toml` - module manifest (name, tier, hooks)
- `core_perkgate.wasm` - committed build of `core_perkgate.zig`
- `core_perkgate.zig` + `main.zig` - Zig source (rebuild: `scripts/build-plugins.sh`)
- `config.toml` - default config, served to the module via the `zdtd.config` import
- `README.md` - this file

All policy lives in this folder: no behavior is hardcoded in the host.
