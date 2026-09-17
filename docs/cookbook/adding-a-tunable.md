# Adding a tunable

> **Use when:** a new operator knob or sim parameter is needed.
> **Owning reference:** [config.md](../subsystems/config.md) for the
> configuration subsystem, [RULES_CONFIG.md](../RULES_CONFIG.md) for what moved
> onto config and what stayed in code, and
> [ADR 0021](../adr/0021-config-driven-game-modes.md) for the decision.
> **Standing orders:** [AGENTS.md](../../AGENTS.md) rule 11 (a new tunable is a
> struct field, not a parse arm), rule 25 (`make check` stays green). The rules
> for this folder are in [docs/AGENTS.md](../AGENTS.md).

A tunable is a struct field. `src/util/toml_bind.zig` walks the destination
struct at comptime, so adding the field *is* the parser change: binding,
unknown-key rejection, range clamps and aliases all follow from the field's name
and type (`src/util/toml_bind.zig:33`). A hand-written
`std.mem.eql(u8, key, ...)` chain is the defect ADR 0021 exists to delete.

Two surfaces exist, and picking the wrong one is the usual mistake:

| The value is | Lives in | Set by |
|---|---|---|
| A sim rule (damage, speed, cadence, cap that the tick reads) | `Rules` group in `src/ecs/rules.zig` | preset pack and `zdtd.toml` under `[rules.<group>]` |
| Server policy read at startup (bucket caps, scan caps, reach) | an optional field in `src/server/zdtd_config.zig` | `zdtd.toml` section |
| A preset-only gameplay scalar (stock serverconfig shaped) | `src/server/preset.zig` | the preset pack |

When in doubt, use `Rules`: [RULES_CONFIG.md](../RULES_CONFIG.md) records the
review that moved every sim number there, and lists the keeps with a reason.

## 1. Read the owners

Read these before editing anything. Each owns a different part of the change.

| File | What it owns |
|---|---|
| `src/util/toml_bind.zig` | the reflected binder; the contract every surface obeys |
| `src/ecs/rules.zig` | the `Rules` struct, the `RulesOverlay` mirror, the group a sim rule goes in |
| `src/server/zdtd_config.zig` | the operator `zdtd.toml` surface and `applyToInitOptions` |
| `src/server/preset.zig` | the preset pack surface, its clamps, and the two gates `Rules` fields must pass |
| `src/main.zig` | the one place precedence is realized |
| `docs/GAME_OPTIONS.md` | the generated-from-struct reference the docs test greps |

## 2. Add the field to the group

`Rules` groups by the system that reads the field (`src/ecs/rules.zig:796`). Add
the field to the existing group, with a doc comment that states the default and
whether the value is a floor or policy. The `Power` group shows the convention
(`src/ecs/rules.zig:768`):

```zig
pub const Power = struct {
    /// Battery capacity fallback scale (×MaxPower) when a battery block only
    /// exposes MaxPower.
    battery_capacity_scale: f32 = 10.0,
    /// Initial battery charge as a fraction of capacity on fresh placement.
    battery_initial_charge_frac: f32 = 0.5,
    /// Trigger-plate / tripwire pulse duration (s) when the block sets
    /// duration=Triggered.
    trigger_pulse_s: f32 = 0.5,
};
```

For a new group the same edit is four pieces: the group struct, the group's
`?T` overlay next to the others, the field on `Rules`
(`src/ecs/rules.zig:796`), and the field on `RulesOverlay`
(`src/ecs/rules.zig:1084`). Step 3 is what keeps the last two honest.

Defaults must equal the value the code used before the move. ADR 0021 decision
2 makes the move a refactor, not a retune, and the defaults test pins the
literals (`src/ecs/rules.zig:1177`).

## 3. Mirror the field in the overlay

The overlay is an all-optional mirror, hand-written because Zig 0.16's `@Struct`
cannot lay out a recursive anonymous type. Add the same-named field with the
same type, wrapped in `?` and defaulted to `null`
(`src/ecs/rules.zig:1068`):

```zig
pub const PowerOverlay = struct {
    battery_capacity_scale: ?f32 = null,
    battery_initial_charge_frac: ?f32 = null,
    trigger_pulse_s: ?f32 = null,
};
```

`mergeOverlay` copies only non-null fields, which is how precedence works
(`src/ecs/rules.zig:1105`):

```zig
pub fn mergeOverlay(dst: *Rules, o: *const RulesOverlay) void {
    toml_bind.mergeOverlay(Rules, dst, o);
}
```

## 4. Let the parity test catch a missed mirror

Do not add a test for this. One already exists and it is comptime-exact:
`fieldsParity` walks both types recursively and compares field names and struct
shape in order (`src/ecs/rules.zig:1111`), and the test that calls it is at
`src/ecs/rules.zig:1127`. Add the group struct but forget the overlay and
`zig build test` fails there, by name. A forgotten field on `RulesOverlay`
itself fails the same test.

## 5. Document the field

`Rules` documentation is not maintained by hand in two places: the field's doc
comment is the source, and the `[rules]` tables in
[docs/GAME_OPTIONS.md](../GAME_OPTIONS.md) are what the docs test greps. Add one
row to the matching `[rules.<group>]` table (the group's table starts at
`docs/GAME_OPTIONS.md:192` for the main block, and the later groups have their
own tables) with the key, the default and a `Floor` or `Policy` clause.

The test that enforces this is "GAME_OPTIONS.md documents every Rules field"
(`src/server/preset.zig:437`): it reads the doc and requires every leaf field
name of every `Rules` group to appear in it. Skip the row and `zig build test`
fails on your field name.

If the field moved out of a code constant, add a row to the `Moved` table in
[RULES_CONFIG.md](../RULES_CONFIG.md) and delete the constant, so the audit of
"what is still hardcoded" stays true.

## 6. Consume it, as a floor where stock data exists

A `Rules` value is a floor, never a replacement for stock data (ADR 0021
decision 5). The pattern at the read site checks the per-entity value first and
falls back to the rule (`src/ecs/systems.zig:2528`):

```zig
        const adm: f32 = if (pad > 0) pad else if (ct.attack_damage > 0) ct.attack_damage else ctx.w.rules.combat.attack_damage;
```

Read the rule as `w.rules.<group>.<field>`. Do not allocate, do not re-read
config, and keep the check on the tick path branch-free in the common case.
Where stock has no equivalent (a cadence, a policy cap), say so in the doc
comment and mark the row `Policy` in [docs/GAME_OPTIONS.md](../GAME_OPTIONS.md).

## 7. How the tiers override it

Precedence is call order, not binder logic. `main.zig` merges the preset pack
first and `zdtd.toml` second, so the operator wins
(`src/main.zig:936`):

```zig
    var rules_eff: ecs_mod.rules.Rules = .{};
    if (preset_owned) |*ppk| ecs_mod.rules.mergeOverlay(&rules_eff, &ppk.rules);
    if (toml_owned) |*tf| ecs_mod.rules.mergeOverlay(&rules_eff, &tf.rules);
```

A preset pack sets the field through the `rules` overlay it already carries
(`src/server/preset.zig:98`), with no code change. `presets/horde_lite.toml` is
the smallest working example:

```toml
[rules.combat]
attack_damage = 5.0
attack_cooldown_s = 1.5
```

An operator does the same in `<world_dir>/zdtd.toml` or `zdtd.toml` in the
working directory. Nothing else is needed: the operator file's `rules` field is
the same overlay type (`src/server/zdtd_config.zig:337`), and the binder accepts
the dotted `[rules.combat]` section recursively.

Committed packs are bound against the current schema by a test that fails on a
stale key (`src/server/preset.zig:292`), so a new rule needs no pack edit unless
a shipped pack should set it.

## 8. If the value is server policy, use the operator surface instead

For a value the tick does not read as a sim rule, add an optional field to the
owning section struct in `src/server/zdtd_config.zig` (for example `Sim` at
`src/server/zdtd_config.zig:100`), then one line in `applyToInitOptions`
(`src/server/zdtd_config.zig:382`), following an existing copy
(`src/server/zdtd_config.zig:459`):

```zig
    if (f.sim.storm_frequency) |v| opts.storm_frequency = v;
```

That function copies only non-null fields into the init options bag, which is
where the startup precedence is realized. If the value needs a repair rather
than a rejection, `sanitizeInitOptions` is the place that logs and fixes it
(`src/server/zdtd_config.zig:490`). Field-size and bucket caps belong to a
section that already has one; do not invent a fourth surface.

## 9. Gates

Run these in order.

1. `zig build test`. The binder tests
   (`src/server/zdtd_config.zig:772`), the parity test
   (`src/ecs/rules.zig:1127`), the defaults pin (`src/ecs/rules.zig:1177`) and
   the docs test (`src/server/preset.zig:437`) all run here.
2. `make lint`. `tools/check_docs.py` checks links, citations and quoted blocks
   in the page you edited.
3. `make check`. The full gate: release pin, lint, build, test, fuzz.

## 10. VERIFY

Substitute the group and field you added. Two runs, one positive and one
negative, prove the key is bound and that the binder is really reading the
section rather than ignoring the file.

```bash
zig build
mkdir -p worlds/verify_tunable
printf '[rules.combat]\nattack_damage = 20.0\n' > worlds/verify_tunable/zdtd.toml
zig-out/bin/zdtd --world worlds/verify_tunable --port 0 --once
```

Expect `zdtd: loaded worlds/verify_tunable/zdtd.toml`, then
`zdtd --once complete`, and exit status 0. Now the negative half:

```bash
printf '[rules.combat]\nattack_damag = 20.0\n' > worlds/verify_tunable/zdtd.toml
zig-out/bin/zdtd --world worlds/verify_tunable --port 0 --once; echo "exit=$?"
rm -rf worlds/verify_tunable
```

Expect `unknown key [combat].attack_damag`, then
`cannot load zdtd.toml 'worlds/verify_tunable/zdtd.toml': UnknownTomlKey`, and
exit status 1. The first run proves the key binds; the second proves the file is
parsed at all, which is what fails when a surface was added in the wrong layer.

This probe proves binding and startup precedence, not the read site. The tick
half is proven by the unit test that covers the system that reads the field, or
by an existing scenario in `src/server/scenarios.zig`. If the value changes what
the client sees, also run the join smoke named in
[testing.md](../testing.md).

## See also

- [config.md](../subsystems/config.md): the surfaces, load order and precedence.
- [RULES_CONFIG.md](../RULES_CONFIG.md): what moved onto config, what stayed in
  code, and why.
- [ADR 0021](../adr/0021-config-driven-game-modes.md): the decision this recipe
  implements.
- [GAME_OPTIONS.md](../GAME_OPTIONS.md): the reference table every `Rules` field
  must appear in.
