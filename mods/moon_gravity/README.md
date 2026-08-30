# moon_gravity

Config-only mod: overrides the sim's gravity to moon gravity (1.62 blocks/s^2)
for AI entities, falling blocks and vehicles.

## What it is

Gravity is a sim rule (`[rules.ai] gravity` / `[rules.vehicle] gravity`,
ADR 0021), so the mod is a preset overlay - no wasm, no native changes. Set
`preset.toml` to any gravity you want:

| World | `[rules.vehicle] gravity` |
|---|---|
| earth | -9.81 (stock) |
| mars | -3.71 |
| moon | -1.62 (this mod) |
| zero-g | 0 |
| upside down | positive value |

Note: the player has no server vertical physics (the client simulates its own
fall), so this mod changes zombies, falling blocks and vehicles via
`[rules.ai]`/`[rules.vehicle]` gravity, and the player's fall through the
C2S vertical clamp (`[rules.glide] fall_sink_vy_mps = 1.5`, a lunar terminal
velocity) - server-side, no client mod needed. Jump height stays client-side
(the client's own physics), and fall damage stays client-owned (stock wire).

## Enable

Ships `enabled = false` (opt-in). Enable via
`[mods] enabled = "moon_gravity"` in zdtd.toml (or flip `enabled = true`
in `manifest.toml`). An operator's zdtd.toml `[rules.ai]` / `[rules.vehicle]`
wins over the mod.

## Layout (self-contained)

- `manifest.toml` - module manifest (config-only mod)
- `preset.toml` - the mod's config + rules (gravity values)
- `README.md` - this file
