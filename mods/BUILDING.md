# Building the plugins

First-party core plugins live under `plugins/core_<topic>/` and addons under
`mods/`. All core plugins are **written in Zig** and compiled to freestanding
`wasm32` modules. The addon exceptions stay in `mods/`: `fps_bot` is C by
design (ADR 0026) and `example_chat_filter/` is a drop-in C example left
as-is.

## One command

```sh
make plugins                     # or: scripts/build-plugins.sh
```

This rebuilds every `plugins/<name>/<name>.wasm` from
`plugins/<name>/<name>.zig` (plus the Zig addons in `mods/`, currently `mcp`)
and leaves nothing else to do by hand. The committed `.wasm` files are build
outputs checked in so operators do not need a Zig toolchain; after changing a
plugin, run the script and commit both source and binary.

## Layout per plugin

| File | Role |
|---|---|
| `<name>.zig` | plugin root: hook exports (`on_*`), optional `_zdtd_requires` |
| `main.zig` | build wrapper: comptime-imports the root, exports `_start` |
| `<name>.wasm` | committed build output (do not edit) |
| `manifest.toml` | manifest (naming/format standards in PLUGIN_STANDARDS.md) |

## Why the wrapper

`zig build-exe` requires an entry point even for freestanding targets, but the
plugin ABI has none - zwasm runs the start section only when the module
declares one, which ours never do. So each plugin has a two-line wrapper that
comptime-references the real module graph and exports an `_start` that is
never invoked.

## Build recipe (what the script does per plugin)

```sh
zig build-exe -OReleaseSmall -target wasm32-freestanding -rdynamic \
  --name <name> \
  --dep plugin_common --dep plugin_root \
  -Mroot=plugins/<name>/main.zig \
  --dep plugin_common -Mplugin_root=plugins/<name>/<name>.zig \
  -Mplugin_common=mods/plugin_common.zig
mv <name>.wasm plugins/<name>/<name>.wasm
```
