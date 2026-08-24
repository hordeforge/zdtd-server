# Plugin standards: naming and manifest format

Binding rules for every plugin under `mods/` (addons) and `plugins/`
(first-party core). The host enforces the manifest format at load
(fail-closed); naming is enforced by review and `scripts/lint-architecture.sh`
where mechanical.

## Naming standards

### Directory / module name

- First-party core plugins live under **`plugins/`** with pattern
  **`core_<topic>`**, all lowercase snake_case, one word after the `core_`
  prefix whenever possible (`core_announce`, not `core_chat_announcements`).
- Addons (third-party-ecosystem-shaped, e.g. `mcp`, `fps_bot`) live under
  **`mods/`**.
- The directory name IS the module name: `mod.toml` `name` must equal the
  directory name. A mismatch is a load-time defect.
- Reserve plain topic words for what the module does, not how: `core_pvp`,
  `core_lootgate`, `core_tradefeed`. Gate suffix (`*gate`) marks modules whose
  primary job is deny/adjust verdicts; feed/announce suffixes mark observers.

### Tier

| Tier | Who ships it | Naming |
|---|---|---|
| official core plugin | ships with zdtd under `plugins/` | `core_<topic>` |
| official addon | ships with zdtd under `mods/` (`fps_bot`, `mcp`) | any; no `core_`/`zdtd_` prefix |
| user | operator/third-party drop-in under `mods/` | any name; must NOT start with `core_` or `zdtd_` unless replacing an official mod via `override` |

`tier = "core"` in a mod.toml is a load error by design: "core" components are
native host-side systems (`loot`, `quests`, `damage`, `craft`, `trading`,
PRD 0005 R4) and can never be claimed by a `.wasm`. The `core_*` *name prefix*
on a plugin directory marks a first-party Wasm plugin, which is a different
sense of "core" (shipped in-tree, Zig source, built by
`scripts/build-plugins.sh`).

### Files inside a plugin directory

| File | Required | Name |
|---|---|---|
| root source | yes (core plugins are Zig) | `<module>.zig` — exactly the directory name |
| build wrapper | yes (Zig plugins) | `main.zig` |
| committed binary | yes | `<module>.wasm` — exactly the directory name + `.wasm` |
| manifest | yes | `mod.toml` (fixed name, discovered automatically) |

The `wasm` key in mod.toml must be `<module>.wasm` (a path relative to the
plugin directory). No other files are read by the host.

### Exports and capabilities

- Hook exports use the fixed hook names from docs/PLUGIN_DEV.md ("Hooks"):
  `on_enable`, `on_tick`, `on_shutdown`, `on_player_join`, ... Never invent a
  new `on_*` export without adding the hook to the host first.
- `_zdtd_requires` lists hooks + host verbs, comma-separated, matching what
  the module actually imports/exports; validated fail-closed at load (ADR
  0030). A typo'd capability is a loud load rejection.
- Log lines start with the module name: `"core_announce v2.0 enabled ..."`.

## mod.toml format

TOML, bound by `src/plugin/manifest.zig` through the comptime binder
(ADR 0021): only declared keys bind; **unknown keys abort the load**
(`UnknownTomlKey`, fail-closed RFC 0005 N2).

### Keys

```toml
name = "core_announce"            # required; MUST equal the directory name
version = "0.1.0"                 # semver string; informational
wasm = "core_announce.wasm"       # required; relative to this directory
description = "..."               # one line, says what + which hook(s)
enabled = true                    # optional; false = skip auto-discovery (demo gates ship off); explicit [plugin] modules paths still load
tier = "official"                 # optional; "official" | "user" ("core" is an error)
override = "<other-mod-name>"     # optional; full replacement of that module (PRD 0005 R7)
points = "damage.player_scale"    # optional; comma-separated core override points (PRD 0005 R5)
claim_mode = "chain"              # reserved; rejected at load (RFC 0005 3.3) — omit it
requires = "<other-mod-name>"     # optional; comma-separated mods that must load first
```

### Rules

1. Scalars only — no TOML arrays (the binder binds scalars; lists are
   comma-separated strings).
2. `name` == directory name; `wasm` == `<name>.wasm`.
3. `enabled = false` skips auto-discovery (`manifest.discover`); the module is
   still loadable via an explicit `[plugin] modules` path. Demo gates/feeds
   ship off by default so a fresh boot stays stock.
3. Known override points (values for `points`), each mapping to one verdict
   hook: `loot.roll`, `quest.payout`, `damage.player_scale`, `craft.request`,
   `trade.price`. Anything else is rejected at bind time.
4. Two mods claiming the same point resolve by tier then dir order; a user mod
   may take over an official slot only via `override` (DuplicateClaim
   otherwise).
5. `[mods] disabled = "a,b"` skips mods by name; entries naming a native core
   component are config errors.

### Example (minimal)

```toml
name = "core_killfeed"
version = "1.0.0"
wasm = "core_killfeed.wasm"
description = "Logs join/leave/kill/death/quest events via the observer hooks."
```
