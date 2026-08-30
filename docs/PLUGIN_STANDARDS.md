# Plugin standards: naming and manifest format

> **Purpose:** binding naming and `manifest.toml` rules for every plugin under `mods/` and `plugins/` - enforced fail-closed at load.

Binding rules for every plugin under `mods/` (addons) and `plugins/`
(first-party core). The host enforces the manifest format at load
(fail-closed); naming is enforced by review and `scripts/lint-architecture.sh`
where mechanical.
**Related:** [PLUGIN_API.md](PLUGIN_API.md) (host/guest contract) · [PLUGIN_DEV.md](PLUGIN_DEV.md) (authoring guide) · [mods/BUILDING.md](../mods/BUILDING.md) (build layout) · [GAME_OPTIONS.md](GAME_OPTIONS.md) (config) · [STATE_MACHINES.md](STATE_MACHINES.md) (system overview)

## Naming standards

### Directory / module name

- First-party core plugins live under **`plugins/`** with pattern
  **`core_<topic>`**, all lowercase snake_case, one word after the `core_`
  prefix whenever possible (`core_announce`, not `core_chat_announcements`).
- Addons (third-party-ecosystem-shaped, e.g. `mcp`, `fps_bot`) live under
  **`mods/`**.
- The directory name IS the module name: `manifest.toml` `name` must equal the
  directory name. A mismatch is a load-time defect.
- Reserve plain topic words for what the module does, not how: `core_pvp`,
  `core_lootgate`, `core_tradefeed`. Gate suffix (`*gate`) marks modules whose
  primary job is deny/adjust verdicts; feed/announce suffixes mark observers.

### Tier

| Tier | Who ships it | Naming |
|---|---|---|
| official core plugin | ships with zdtd under `plugins/` | `core_<topic>` |
| official addon | ships with zdtd under `mods/` (`fps_bot`, `mcp`, `parachute`, `moon_gravity`, `infinite_world`, `example_chat_filter`) | any; no `core_`/`zdtd_` prefix |
| user | operator/third-party drop-in under `mods/` | any name; must NOT start with `core_` or `zdtd_` unless replacing an official mod via `override` |

`tier = "core"` in a manifest.toml is a load error by design: "core" components are
native host-side systems (`loot`, `quests`, `damage`, `craft`, `trading`,
PRD 0005 R4) and can never be claimed by a `.wasm`. The `core_*` *name prefix*
on a plugin directory marks a first-party Wasm plugin, which is a different
sense of "core" (shipped in-tree, Zig source, built by
`scripts/build-plugins.sh`).

### Files inside a plugin directory

| File | Required | Name |
|---|---|---|
| manifest | yes | `manifest.toml` (fixed name, discovered automatically; the manifest, not a "mod file") |
| committed binary | yes (wasm plugins) | `<module>.wasm` - exactly the directory name + `.wasm` |
| root source | yes (core plugins are Zig) | `<module>.zig` - exactly the directory name |
| build wrapper | yes (Zig plugins) | `main.zig` |
| config | no | `config.toml` (fixed name; the module's own default config, served raw via the `zdtd.config` import) |
| readme | recommended | `README.md` (what it does, its config keys, how to enable) |
| icon | no | `icon.png` (fixed name; metadata only - the host never loads or renders it). `manifest.toml` `icon = "icon.png"` (relative path, same validation as `preset`) |

The `wasm` key in manifest.toml must be `<module>.wasm` (a path relative to the
plugin directory). A plugin folder is **self-contained**: manifest + wasm +
source + optional `config.toml` + optional `preset.toml` (rules for a
config-only mod) + `README.md` travel together; no behavior is hardcoded in
the host.

### Config-only vs wasm plugins

- A **wasm plugin** ships `<module>.wasm` (with `<module>.zig` source for
  core plugins) and may ship `config.toml`, served to the guest verbatim via
  the `zdtd.config` host import. The host never parses it - each plugin owns
  its format (the shared `mods/plugin_common.zig` `Config` helper parses the
  minimal `key = value` subset). A wasm plugin may also carry a `preset.toml`
  (resolver: "a mod with BOTH a wasm and a preset (ADR 0037 parachute) loads
  its module AND applies its preset").
- A **config-only mod** ships `preset.toml` (rules + gameplay keys) and no
  `wasm` (only `preset` in the manifest). Example: `mods/infinite_world`.

### Exports and capabilities

- Hook exports use the fixed hook names from docs/PLUGIN_DEV.md ("Hooks"):
  `on_enable`, `on_tick`, `on_shutdown`, `on_player_join`, ... Never invent a
  new `on_*` export without adding the hook to the host first.
- `_zdtd_requires` lists hooks + host verbs, comma-separated, matching what
  the module actually imports/exports; validated fail-closed at load (ADR
  0030). A typo'd capability is a loud load rejection.
- Log lines start with the module name: `"core_announce v2.0 enabled ..."`.

## manifest.toml format

TOML, bound by `src/plugin/manifest.zig` through the comptime binder
(ADR 0021): only declared keys bind; **unknown keys abort the load**
(`UnknownTomlKey`, fail-closed RFC 0005 N2).

### Keys

```toml
name = "core_announce"            # required; MUST equal the directory name
version = "0.1.0"                 # semver string; informational
wasm = "core_announce.wasm"       # required (or `preset`, see below); relative to this directory
preset = "preset.toml"            # optional preset inside this folder; loads with the wasm module (parachute) or alone (config-only mod, no wasm)
description = "..."               # one line, says what + which hook(s)
enabled = true                    # optional; false = skip auto-discovery (demo gates ship off); explicit [plugin] modules paths still load; [mods] enabled forces on
tier = "official"                 # optional; "official" | "user" ("core" is an error)
override = "<other-mod-name>"     # optional; full replacement of that module (PRD 0005 R7)
points = "damage.player_scale"    # optional; comma-separated core override points (PRD 0005 R5)
claim_mode = "chain"              # reserved; rejected at load (RFC 0005 3.3) - omit it
requires = "<other-mod-name>"     # optional; comma-separated mods that must load first
```

### Rules

1. Scalars only - no TOML arrays (the binder binds scalars; lists are
   comma-separated strings).
2. `name` == directory name; `wasm` == `<name>.wasm`.
3. `enabled = false` skips auto-discovery (`manifest.discover`); the module is
   still loadable via an explicit `[plugin] modules` path. Demo gates/feeds
   ship off by default so a fresh boot stays stock.
4. Known override points (values for `points`), each mapping to one verdict
   hook: `loot.roll`, `quest.payout`, `damage.player_scale`, `craft.request`,
   `trade.price`. Anything else is rejected at bind time.
5. Two mods claiming the same point resolve by tier then dir order; a user mod
   may take over an official slot only via `override` (`DuplicateClaim`
   otherwise).
6. `[mods] disabled = "a,b"` skips mods by name; entries naming a native core
   component are config errors.
7. **Config-only mods** (PRD 0005 style, no wasm): `preset = "<path>"` points
   at a preset file **inside the mod folder** (e.g. `preset.toml`) - its
   gameplay keys and `[rules.*]` override the built-in defaults exactly like
   `--preset <name>` (explicit `--preset` / `[preset] name` still wins). A
   mod is fully self-contained: config, wasm and assets travel together.
   `preset` is not exclusive with `wasm`: a wasm plugin may carry both (ADR
   0037 parachute loads its module AND applies its preset); a mod with only
   `preset` is config-only and never enters the Wasm load list. Such mods ship
   `enabled = false` so a fresh boot stays stock; the operator opts in via
   `[mods] enabled = "a,b"` (or flips `enabled`). At most one loaded mod may
   carry a `preset` (`DuplicatePreset` otherwise).

### Example (minimal)

```toml
name = "core_killfeed"
version = "1.0.0"
wasm = "core_killfeed.wasm"
description = "Logs join/leave/kill/death/quest events via the observer hooks."
```
