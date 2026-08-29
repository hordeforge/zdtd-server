# infinite_world

Procedural infinite world: chunks generate on first touch as players explore.

## What it is

A config-only mod (no wasm): its own `preset.toml` carries the seed +
`[rules.worldgen]` shaping that override the built-in defaults, exactly like
`--preset infinite`. Removing the mod later restores the default terrain (a
clean session writes no world files; see `docs/WORLDGEN.md`).

## Config

`preset.toml` (self-contained): `worldgen_seed = 7` + `[rules.worldgen]`
shaping defaults. Seed precedence: CLI `--worldgen-seed` > zdtd.toml
`[worldgen] seed` > the preset.

## Enable

Ships `enabled = false` (opt-in). Enable via
`[mods] enabled = "infinite_world"` in zdtd.toml (or flip `enabled = true`
in `manifest.toml`).

## Layout (self-contained)

- `manifest.toml`, `preset.toml` (the mod's config + rules), `README.md`
