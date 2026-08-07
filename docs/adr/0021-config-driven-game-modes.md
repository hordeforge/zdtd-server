# 0021. Config-driven game modes

- **Status:** accepted (extends [0010](0010-data-config-zig-plugins.md)).
  Implemented 2026-08-07 (WORK_PLAN T11-T15): the reflected binder, the
  `Rules` struct, the mode-pack overlay, the floor audit, and the four event
  hooks all ship.
- **Date:** 2026-08-07

## Context

[ADR 0010](0010-data-config-zig-plugins.md) split "hardcoded" into three
layers and ruled that sim rules stay Zig systems with **data-driven
parameters**. Layers 1 and 2 were built out; the parameter half of layer 3 was
not. The result is that zdtd can be configured as *a 7 Days to Die server*, but
not reshaped into a different game mode.

Four concrete obstacles, measured at head `40f4790`:

1. **Mode packs exist but are shallow.** `modes/<name>.toml` and
   `src/server/mode.zig` (432 lines) ship, and `--mode` / `[mode] name` select a
   pack, but the pack only understands **28 stock serverconfig scalars**
   (`max_spawned_zombies`, `blood_moon_frequency`, `xp_multiplier`, and so on).
   A pack cannot touch a single sim rule.
2. **Sim rules are file-scope constants.** `src/ecs/systems.zig` holds
   `full_ai_dist_sq`, `mid_ai_dist_sq`, `sense_dist_sq`, `attack_range_sq`,
   `attack_damage`, `chase_speed`, `wander_speed`, `attack_cooldown_s`,
   `despawn_dist_sq`; `src/ecs/aidirector.zig` holds the blood-moon party
   constants. None is reachable from any config surface.
3. **Config binding is hand-written, so coverage stalls.**
   `src/server/zdtd_config.zig` (985 lines) and `src/server/mode.zig` (432) are
   mostly `else if (std.mem.eql(u8, key, "..."))` chains. Every new tunable costs
   a parse arm, a validation arm, a docs row and a test, and each is a place to
   typo a key name that no compiler checks. This cost, not any architectural
   objection, is why the mode pack stopped at 28 keys.
4. **`InitOptions` is a flat 129-field struct.** It works as an internal
   argument bag and does not survive being exposed as a user-authored file:
   there is no grouping, no way to tell a stock-derived value from a zdtd policy
   value, and no natural section structure for a TOML surface.

Layer 3's other half, the hook surface, is also too thin to carry a mode: the
Wasm host exposes four observe-only hooks (`on_enable`, `on_tick`,
`on_player_join`, `on_shutdown`) and three imports.

## Decision

### 1. Config binding is derived from the struct, not written by hand

A single comptime-reflected binder walks `std.meta.fields` of the destination
struct: nested structs are `[section]`s, field names are keys, `?T` means
unset, and the field's type drives parsing and range checking. The existing
rules (unknown key aborts startup, `0` sentinels rejected, precedence order)
are enforced once in the binder instead of per key.

Adding a configurable value becomes exactly one edit: add the field. It is then
parseable, validated, documented by its doc comment, and covered by the binder's
own tests. This is the enabler for everything below, and it is a large net
deletion.

### 2. Sim rule parameters live in one `Rules` struct

Rule constants move to a nested struct, grouped by the system that reads them
(`combat`, `ai`, `bloodmoon`, `progression`, `world`), with **defaults equal to
today's constant values** so behaviour is unchanged by the move. `Rules` is
carried on `World` (which already holds `trader_restock_cap`,
`trader_restock_refill` and `zombie_speed_scale`, so the precedent and the
access path exist) and hangs off `Game` for the server-side rules.

`Rules` is the config surface for sim behaviour. `InitOptions` stays what it is,
an internal argument bag, and is not exposed as a user file.

### 3. A mode pack is a full overlay, not a key subset

`modes/<name>.toml` may set any `Rules` field plus the stock serverconfig keys
it already supports. Precedence is unchanged and stays operator-wins:

```
CLI > env > world/zdtd.toml > CWD zdtd.toml > mode pack > serverconfig > defaults
```

A mode ships a coherent set of defaults; an operator can still override any
single value without editing the pack.

### 4. Behaviour that is not a parameter goes to Wasm, not to config

A number, a rate, a range or a table is config. A rule with control flow (a win
condition, a scoring system, "every 7th day is a boss wave", a custom event
chain) is a plugin. Config files that grow conditionals become a bad scripting
language with no debugger, and **ADR 0010's ban on a script VM in the core
stands**: a VM on the 20 TPS tick would fight the no-alloc hot path,
deterministic tests and stock wire fidelity.

The consequence is that the hook surface must grow to where a mode can be
written against it: hooks that fire on the events a mode cares about
(death, kill, block damage, quest completion), and hooks that can **deny or
adjust** a proposed outcome rather than only observe it.

### 5. A `Rules` field is a floor, never a replacement for stock data

Where stock ships per-entity or per-item data, that data wins. The AI speed and
damage constants are already written this way: `systems.zig:1344` reads
`if (ct.attack_damage > 0) ct.attack_damage else attack_damage`, so the constant
is an offline floor for when `entityclasses.xml` is absent or the field is 0.
Moving such a constant into `Rules` must preserve that ordering. A mode that
wants every zombie to hit harder gets a multiplier applied to the resolved
per-entity value, not a global that silently discards `entityclasses.xml`.

This keeps the layer 1 / layer 2 boundary from eroding, which is the failure
mode the hardcode audit exists to catch.

## Consequences

### Positive

- Custom game modes become a file, not a fork.
- One binder means one place where parsing, validation and precedence are
  correct, instead of ~1400 lines where each key can be individually wrong.
- Net deletion: two hand-written key chains collapse.
- A new tunable is one field, so the surface can grow with the sim instead of
  lagging it.
- Documentation can be generated from the struct, so it cannot drift from the
  parser.

### Negative / costs

- Field names become a compatibility surface: renaming a `Rules` field breaks
  existing packs. Renames need the same care as a wire change.
- Comptime reflection is harder to read than an explicit chain, and its errors
  land at instantiation. The binder needs its own thorough tests, since
  everything else now depends on it being right.
- A wide config surface is a wide test surface: values that were compile-time
  constants become runtime inputs, and each needs its empty / zero / max /
  malformed case.
- More reachable knobs means more ways for an operator to configure a world that
  is technically valid and unplayable.

## Alternatives considered

| Option | Why not |
|---|---|
| Lua or another script VM for game rules | ADR 0010 rejected this and the reasons hold: 20 TPS budget, no-alloc hot path, deterministic tests, and it duplicates the Wasm plugin surface that already exists |
| Keep hand-writing key chains, just add more keys | This is the status quo that stalled at 28 keys; the cost per key is the actual defect |
| Expose `InitOptions` directly as the config file | 129 flat fields with no grouping and no separation of stock-derived from policy values; it is an internal argument bag |
| Put game rules in stock-shaped XML | Stock has no schema for them, so it would be an invented parallel format in a file that looks stock, which is exactly what the hardcode audit flags |
| Ship modes as Wasm plugins only | Most of a mode is numbers; forcing a tuning change through a compile-and-load cycle is worse for the author and worse for the operator |

## Follow-up

Implementation is [WORK_PLAN.md](../WORK_PLAN.md) T11 through T15, in that
order: T11 the binder, T12 the `Rules` struct, T13 the mode pack overlay, T14
the layer-1 precedence audit, T15 the hook surface. T11 and T12 are mechanical
and unblock the rest.

The mode pack format reference belongs in
[GAME_OPTIONS.md](../GAME_OPTIONS.md) and is written when T13 lands, generated
from `Rules` rather than maintained by hand.
