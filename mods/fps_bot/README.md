# fps_bot

Official FPS bot brain (ADR 0026): sense -> decide -> `bot <verb>` commands.
The Wasm guest owns all decision logic; the host `BotManager` is a servant
(spawn/replicate/move/LOS gate/sense fill).

## What it is

The bot brain shipped as a Wasm plugin (C by design, ADR 0026). It reads the
host's sense snapshot and issues movement/aim/combat commands.

## Hooks / surface

- `on_tick` (sense + decide + `bot` commands), `on_enable`, `on_shutdown`
- Host verbs: `zdtd.sense`, `zdtd.queue`

## Config

Host-side bot policy (damage, spawn spread, weapon profiles) is
`[bots]` in zdtd.toml / a preset pack (`docs/GAME_OPTIONS.md`).

## Enable

Auto-discovered (`tier = "official"`); disable via `[mods] disabled = "fps_bot"`.

## Layout (self-contained)

- `manifest.toml`, `fps_bot.wasm`, `fps_bot.c` (source), `README.md`
