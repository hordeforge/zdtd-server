# Adding a core plugin

A core plugin is a first-party Wasm module that ships in the repository under
`plugins/core_<topic>/`, written in Zig, compiled to `wasm32-freestanding`, and
committed as a `.wasm` build output. This recipe covers the layout, the manifest,
the hook and host-verb surface, the declarative dependency export, the budgets,
the rebuild and freshness gates, and one verify step.

Read first: [`docs/PLUGIN_STANDARDS.md`](../PLUGIN_STANDARDS.md) (naming and
manifest), [`docs/PLUGIN_DEV.md`](../PLUGIN_DEV.md) (hooks, imports, budgets,
building), [`docs/PLUGIN_API.md`](../PLUGIN_API.md) (the host/guest contract),
[`mods/BUILDING.md`](../../mods/BUILDING.md) (the build recipe),
[`plugins/core_killfeed/core_killfeed.zig`](../../plugins/core_killfeed/core_killfeed.zig)
(the observer template) and
[`docs/adr/0020-wasm-only-plugin-api.md`](../adr/0020-wasm-only-plugin-api.md).

## 1. Confirm the behavior belongs in a plugin

A feature that decides something (a verdict, a filter, an announcement, a
command) ships as a Wasm plugin; a feature that emits wire or mutates sim state
directly is native by construction (AGENTS.md rule 29, ADR 0020). First-party
status does not change that: a core plugin is a Wasm module with a `core_` name
prefix, not a native hook (`docs/PLUGIN_STANDARDS.md:34-39`).

First-party modules live under `plugins/` with the `core_<topic>` name; addons
and user drop-ins live under `mods/` (`docs/PLUGIN_STANDARDS.md:26-32`). Reserve
a plain topic word for what the module does: `core_pvp`, `core_lootgate`,
`core_tradefeed`. The `*gate` suffix marks deny/adjust verdicts; `feed` and
`announce` mark observers (`docs/PLUGIN_STANDARDS.md:22-25`).

## 2. Create the directory

Copy `plugins/core_killfeed/` as the starting point and rename it. The layout is
fixed (`docs/PLUGIN_STANDARDS.md:41-51`, `mods/BUILDING.md`):

| File | Required | Name |
|---|---|---|
| `manifest.toml` | yes | fixed name, discovered automatically |
| `<module>.wasm` | yes | the directory name plus `.wasm` |
| `<module>.zig` | yes | the directory name, the plugin root |
| `main.zig` | yes | build wrapper |
| `config.toml` | no | the module's own default config |
| `README.md` | recommended | what it does, its config keys, how to enable |
| `icon.png` | no | metadata only |

The directory name is the module name, and the manifest `name` must equal it
(`docs/PLUGIN_STANDARDS.md:20-21`). Naming is review-enforced, not
mechanically; the mechanical gates are the build list in step 8 and the binary
freshness check in step 9.

## 3. Write the root module

The root is pure Zig: hook exports, static buffers, and the declarative
dependency export. It imports only the shared guest helper,
`mods/plugin_common.zig`, built as the `plugin_common` module.

Declare the capabilities at comptime (the shape is
`plugins/core_killfeed/core_killfeed.zig:29-31`):

```zig
comptime {
    common.exportRequires("log,config,on_enable,on_shutdown,on_player_join,on_player_leave,on_entity_killed,on_player_death,on_quest_complete");
}
```

`_zdtd_requires` is a comma-separated list of hook names plus the host verbs
(`log`, `tick`, `queue`, `sense`, `query`, `json_parse`, `json_str`, `json_raw`,
`json_obj`, `config`). The host validates it at load and rejects the module
loudly when a capability is unknown or a declared hook is not exported. A
module discovered through `manifest.toml` that exports at least one hook and
declares nothing is refused with `error.RequiresUnmet`
(`docs/PLUGIN_DEV.md:120-141`).

Export only the hooks you need; a missing export means that hook is not
registered and costs nothing at runtime, while a wrong signature fails the call
and disables the module (`docs/PLUGIN_DEV.md:35-38`). The lifecycle hooks take
no arguments and return `void`; the verdict hooks return `i32` with the
convention below 0 denies, 0 keeps, above 0 adjusts as a percent
(`docs/PLUGIN_DEV.md:380-394`, `docs/PLUGIN_DEV.md:420-425`). The full hook
catalog, including the request/reply hooks `on_admin_command`, `on_chat` and
`on_player_login`, is in `docs/PLUGIN_DEV.md:396-442`.

Build guest state from the shared helpers, not from hand-rolled readers: `Buf`
is a bounded append buffer with `put`, `putInt`, `logLine` and `send`
(`mods/plugin_common.zig:45-83`), and `Config` parses the `key = value` subset
of the module's own `config.toml` (`mods/plugin_common.zig:116-160`). Every Zig
guest built on this module also declares its contract version through
`_zdtd_api` (`mods/plugin_common.zig:21-27`).

## 4. Add the build wrapper

`main.zig` is a two-line wrapper: `zig build-exe` needs an entry point even for
a freestanding target, and zwasm runs a start section only when the module
declares one, which these never do. Copy
`plugins/core_killfeed/main.zig:5-8` verbatim:

```zig
comptime {
    _ = @import("plugin_root");
}
export fn _start() void {}
```

A hook declared directly in the wrapper, or a `pub` symbol outside the root
module, does not land in the wasm.

## 5. Write the manifest

`manifest.toml` is bound by the comptime binder; only declared keys bind, and an
unknown key aborts the load (`docs/PLUGIN_STANDARDS.md:87-93`). The shipped
observe-only modules use this minimal shape:

```toml
name = "core_killfeed"
version = "0.1.0"
icon = "icon.png"
wasm = "core_killfeed.wasm"
enabled = false
description = "In-tree zdtd module: demo/feed, enabled = false, load via [plugin] modules."
```

Rules that bite (`docs/PLUGIN_STANDARDS.md:94-144`):

- Scalars only. Lists are comma-separated strings, not TOML arrays.
- `name` equals the directory name; `wasm` equals `<name>.wasm`.
- `enabled = false` keeps a fresh boot stock; a discovered module still loads
  when `[mods] enabled` names it or `[plugin] modules` points at it.
- `tier` is `"official"` or `"user"`; `"core"` is a load error.
- `points = "loot.roll"` claims one of the five exclusive override points
  (`loot.roll`, `quest.payout`, `damage.player_scale`, `craft.request`,
  `trade.price`); an unclaimed point keeps the ordinary first-non-zero
  composition.
- `requires = "<other-mod-name>"` is a load-order requirement between modules,
  a different thing from `_zdtd_requires`, which names hooks and verbs inside
  the module.

A module that ships off by default, as every shipped core plugin does, passes
`enabled = false` and is turned on by the operator or by a scenario.

## 6. Config, if the module needs it

A plugin folder may ship `config.toml`. The host loads it, caps it at 4 KiB, and
serves the raw text through the `zdtd.config` import; the host never parses it,
so each plugin owns its format (`docs/PLUGIN_DEV.md:452-462`). Declare `config`
in `_zdtd_requires`, load it once in `on_enable`, and fail closed on an
out-of-range value; the reference is `core_pricegate`, which reads
`price_percent` and keeps its default when the value is outside the accepted
range (`plugins/core_pricegate/core_pricegate.zig:29-33`). Policy belongs in
`config.toml`, not in compiled constants, so it changes without a rebuild.

## 7. Budgets and fuel

Every guest call runs under a per-instance fuel budget and a linear-memory cap
(`src/plugin/wasm.zig:77-80`):

```zig
pub const Budget = struct {
    fuel: u64 = 100_000_000,
    max_memory_pages: u64 = 1024,
};
```

Fuel is armed once at instantiate and never re-armed per call, so it is a
lifetime budget for the instance. At 20 Hz a module spending 10 000 fuel per
tick exhausts the default in roughly eight minutes
(`docs/PLUGIN_DEV.md:239-247`). Keep `on_tick` genuinely small, or do the work
on an event hook. The operator raises `fuel` or `max_pages` under `[plugin]` in
`zdtd.toml` (`src/server/zdtd_config.zig:210-216`).

Exhausting either budget ends the call, disables that module and logs which
module and hook, so a runaway guest costs one tick, not the server. Because
effects are attributed, a disabled module's still-queued commands are withdrawn
before the next drain (`docs/PLUGIN_DEV.md:167-174`).

## 8. Register the module in the build

`scripts/build-plugins.sh` carries an explicit list of core modules
(`scripts/build-plugins.sh:45-48`). Add the new directory name to that list. A
module missing from the list is never built into the mirror, so the freshness
gate never compares it.

Then add the module path to the shipped-set list in the host contract test
(`src/plugin/wasm.zig:2452-2464`), which loads every shipped module and asserts
each one declares the host contract version (`src/plugin/wasm.zig:2423`). The
host table holds 32 modules (`src/plugin/wasm.zig:954`), and the test asserts
the shipped set fits.

Discovery scans `mods/` and `plugins/` at boot and merges the manifests
(`src/main.zig:766-770`), so no configuration is needed once the manifest is in
place. A manifest-loaded module logs `zdtd: mod '<name>' [<tier>] loaded` at
boot (`src/plugin/wasm.zig:1085`), and the admin verb `plugin list` prints each
slot with its tier and enabled state (`src/server/game/wasm_host.zig:526-543`).

## 9. Rebuild and gate the committed binary

```bash
make plugins              # scripts/build-plugins.sh, rebuilds in place
bash scripts/lint-plugins.sh
```

`make plugins` rebuilds every `plugins/<name>/<name>.wasm` from its Zig source
(`Makefile:53-54`). The committed `.wasm` is a build output checked in so
operators need no toolchain, so commit source and binary together
(`mods/BUILDING.md`). `make lint` runs the freshness gate
(`Makefile:155`, `scripts/lint-plugins.sh:44-52`): it rebuilds every artifact
into a scratch mirror under `zig-out` and byte-compares it against what is
committed, failing with `is stale (its source changed without a rebuild)`. Use
`scripts/build-plugins.sh --dest DIR` to produce the mirror without touching the
tree (`scripts/build-plugins.sh:14-21`).

Hot reload is available for iteration on a running server:
`plugin reload <name>` disposes the old instance (`on_shutdown`, fuel and memory
reclaimed), reloads the module into the same slot and runs `on_enable`
(`docs/PLUGIN_DEV.md:151-165`).

## 10. Prove the behavior with a scenario

Verdict and observer behavior belongs in an integration scenario that loads the
committed `.wasm` and drives the hook through the production path. Copy the
load shape from `src/server/scenarios.zig:11575`, which loads one module into
`g.wasm_plugins` before driving the event. See
[`adding-a-scenario.md`](adding-a-scenario.md) for the construction and
assertion shape.

## VERIFY

1. Rebuild and confirm the binary changed with the source:

   ```bash
   make plugins
   git status --porcelain plugins/core_<topic>
   ```

   The directory must show both the edited source and the rebuilt `.wasm`.

2. Run the freshness gate, then prove it bites: touch the root `.zig` without
   rebuilding and rerun `bash scripts/lint-plugins.sh`. It must fail with
   `is stale (its source changed without a rebuild)`. Rebuild and confirm it
   passes.

3. Run the scenario that exercises the module, then the full suite:

   ```bash
   zig build test -Dtest-filter="scenario <your name>"
   zig build test
   ```

4. Boot a server with the module enabled and confirm the load line
   `zdtd: mod '<name>' [<tier>] loaded` appears, with no
   `error.RequiresUnmet` and no `disabled` line for the module.

## See also

- [`../subsystems/plugin-host.md`](../subsystems/plugin-host.md) - the runtime
  reference: hooks, host verbs, budgets, manifest validation, reload.
- [`../PLUGIN_DEV.md`](../PLUGIN_DEV.md) - the authoring guide the hook and
  import tables live in.
- [`adding-a-scenario.md`](adding-a-scenario.md) - how to prove the behavior in
  the suite.
