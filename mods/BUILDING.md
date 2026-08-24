# Building the core plugins

All core plugins under `mods/` are **written in Zig** and compiled to
freestanding `wasm32` modules. The single exception is `bot` (C by
design, ADR 0026); `example_chat_filter/` is a drop-in example left as-is.
`bot/bot.c` remains the only C source in this tree.

## One command

```sh
scripts/build-plugins.sh        # or ZIG=/path/to/zig scripts/build-plugins.sh
```

This rebuilds every `mods/<name>/<name>.wasm` from `mods/<name>/<name>.zig`
and leaves nothing else to do by hand. The committed `.wasm` files are build
outputs checked in so operators do not need a Zig toolchain; after changing a
plugin, run the script and commit both source and binary.

## Layout per plugin

| File | Role |
|---|---|
| `<name>.zig` | plugin root: hook exports (`on_*`), optional `_zdtd_requires` |
| `main.zig` | build wrapper: comptime-imports the root, exports `_start` |
| `<name>.wasm` | committed build output (do not edit) |
| `mod.toml` | manifest (naming/format standards in PLUGIN_STANDARDS.md) |

## Why the wrapper

`zig build-exe` requires an entry point even for freestanding targets, but the
plugin ABI has none — zwasm runs the start section only when the module
declares one, which ours never do. So each plugin has a two-line wrapper that
comptime-references the real module graph and exports an `_start` that is
never invoked.

## Build recipe (what the script does per plugin)

```sh
zig build-exe -OReleaseSmall -target wasm32-freestanding -rdynamic \
  --name <name> \
  --dep plugin_common --dep plugin_root \
  -Mroot=mods/<name>/main.zig \
  --dep plugin_common -Mplugin_root=mods/<name>/<name>.zig \
  -Mplugin_common=mods/plugin_common.zig
mv <name>.wasm mods/<name>/<name>.wasm
```

- `-OReleaseSmall`: fuel is instruction-counted; small code burns less.
- `-target wasm32-freestanding`: no WASI. A module importing
  `wasi_snapshot_preview1` fails to instantiate.
- `-rdynamic`: keeps the `on_*` exports visible.
- `plugin_common` is the shared helper module (`mods/plugin_common.zig`):
  host imports, bounded log/queue buffer, `exportRequires`.

## Shared helpers (`mods/plugin_common.zig`)

- Host imports: `log`, `tick`, `queue`, `sense`, `query`, `json_parse`,
  `json_str`, `json_raw`, `json_obj`.
- `Buf`: fixed 160-byte append buffer for log lines / queued commands;
  truncates instead of overrunning.
- `exportRequires(spec)`: emits the `_zdtd_requires` export (ADR 0030) from a
  comptime capability list.

## Verifying before shipping

Load it through the host test suite (`zig build test` exercises every core
plugin from its committed `.wasm`), and check the surface:

```sh
wasm-objdump -x mods/<name>/<name>.wasm | grep -A20 "Export\[\|Import\["
```

Exports must be exactly the hooks you meant plus `_start`; imports only
`zdtd.*` functions you were granted. No start section (id 8) should appear.
