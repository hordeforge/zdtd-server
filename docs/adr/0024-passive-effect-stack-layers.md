# 0024. Passive-effect stack: name the layers, stop reinventing them per gap

- **Status:** accepted
- **Date:** 2026-08-10
- **Related:** [ADR 0023](0023-perk-attribute-system.md) (`resolvePassiveEffect`,
  T26), [docs/reviews/HARDCODE_AUDIT.md](../reviews/HARDCODE_AUDIT.md) A34
  (trap kill XP) and A35 (armor mitigation), `src/assets/buffs.zig` (T16
  survival rates).

## Context

Four things landed or were planned in the same few days, each reading one
slice of what turns out to be a single stock mechanism:

| Gap | Reads | Where |
|---|---|---|
| A34 (trap kill XP) | perk-level fraction (`ElectricalTrapXP`) | `Rules` floor, `step.zig` |
| T16 (survival rates) | buff-driven thresholds and damage | `buffs.zig` `survival()` |
| A35 (armor mitigation, open) | equipped-item passives (`PhysicalDamageResist`) | not yet built |
| T26 (planned) | perk-level passives, generically | `resolvePassiveEffect` |

`../../../7dtd-research/docs/minevents.md` section 7.0 documents the stock
function all four are slices of: `EffectManager.GetValue(PassiveEffects,
ItemValue, float originalValue, EntityAlive, Recipe, FastTags, calcEquipment,
calcHoldingItem, calcProgression, calcBuffs, calcChallenges, craftingTier,
useMods, useDurability)`. It accumulates a named passive value through an
**ordered stack of layers** (recipe, item, entity class, second item pass,
vehicle item, holding item, equipment, progression, buffs, quality mods, and
more; workstation tool cache and challenge journal are two more that do not
apply server-side). The research doc states outright which layers matter
here: *"Dedicated combat/loot paths typically set equipment + holding +
progression + buffs; workstation tools do not affect dedicated."*

Without naming this, the codebase's own good instinct (T26: "one resolver,
not N `Rules` fields") stops one layer short of covering itself. A34 and T16
already each independently reimplemented one layer by hand. A35, still open,
would be a third. `resolvePassiveEffect` as scoped in ADR 0023 T26 reads only
the progression layer, so a value that stock computes from equipment **and**
perks (which is not hypothetical: `PhysicalDamageResist` from an item is the
same accumulation A35 needs) would still need a second reimplementation next
to the "generic" resolver, defeating the point ADR 0023 T26 set out to fix.

## Decision

### 1. The four server-relevant layers, named once

zdtd implements the layers the research doc names as server-relevant, no
others:

- **Item** (the acted-on `ItemValue`'s own passive rows)
- **Equipment** (each equipped item's passive rows)
- **Progression** (perk and attribute passive rows, once ADR 0023 lands)
- **Buffs** (active buff passive rows, `buffs.zig` already does this one)

Not implemented, and not planned, because they are client-only or do not
apply to a headless server: the workstation tool-grid slot cache (explicitly
`EntityPlayerLocal` only, i.e. client-side), the challenge journal
(`calcChallenges`), and the display-only twins (`GetDisplayValues`,
`GetValuesAndSources`'s source-tracking, tooltip math). If a future gap turns
out to need one of these, that is a deliberate scope change to this ADR, not
a silent addition.

### 2. One function, one accumulation order, every caller goes through it

`resolveEffect(entity, effect_name, tags, opts: struct { item: bool = false,
equipment: bool = false, progression: bool = false, buffs: bool = false })
f32` walks only the requested layers, in the stock order (item, equipment,
progression, buffs, matching the research doc's ordering with the
non-applicable layers dropped), aggregating each layer's rows the way
`buffs.zig`'s `passiveValue` already does (`base_set`/`perc_set` overwrite,
`base_add`/`perc_add` sum). Callers pass which layers apply to their read, not
which stock function name they are porting: A34's trap-kill fraction wants
`progression` only (equipment does not modify `ElectricalTrapXP` in stock),
A35's armor mitigation wants `equipment` only, a future combined read (say,
total headshot damage modifier, which stock's `HeadshotDamageModifier` reads
from both attribute passives and equipped optics) wants both.

### 3. `buffs.zig`'s existing buff-layer code is the reference implementation, not a rewrite target

`passiveValue`'s aggregation rule is already correct and already proven
against the shipped `buffs.xml` (T16's test). `resolveEffect`'s buff layer
calls into it rather than reimplementing the aggregation a second time. The
same applies going forward: each layer gets one aggregation implementation,
called by `resolveEffect`, not copied per consumer.

### 4. `Rules` floors stay, now scoped explicitly to "no layer contributed"

ADR 0021 decision 5 and ADR 0023 decision 3 already established that a `Rules`
value is the floor when stock data does not resolve. That is unchanged. What
changes is that "stock data does not resolve" is now precise: it means every
requested layer for that entity returned nothing (no item row, no equipped
item row, no perk level assigned, no active buff), not "the one layer this
call site happened to read was empty." A34's floor already matches this
(progression-only read, floor fires when the player has no perk levels); A35
will need a floor **only** if a scenario exists where stock itself has no
armor data to read (none does: unarmored is simply zero mitigation, which is
representable without a floor at all).

## Consequences

### Positive

- A35 (armor mitigation) becomes a second caller of the same function T26
  already needs to build, not a third bespoke formula.
- The layer table is a checklist for the next gap in this family: which
  layers does the value need, in what order, and that question now has a
  written answer instead of a fresh IL read each time.
- `buffs.zig`'s aggregation code stops being buff-specific in practice, even
  though it stays where it is.

### Negative / costs

- `resolveEffect`'s four-layer signature is more surface than a single-layer
  function per gap would have been for any one caller; the cost is paid once,
  by whichever of T26 or T28 lands second, refactoring the first into this
  shape.
- If a future gap genuinely needs a layer this ADR excluded (challenge
  journal, say), extending `resolveEffect` risks becoming exactly the kind of
  "port everything eventually" scope this ADR is trying to avoid at the
  requirement-evaluator layer (see the parallel note in
  [ADR 0023](0023-perk-attribute-system.md)). Extend only when a real gap
  needs it, named and grounded the way A34 and A35 were.

## Alternatives considered

| Option | Why not |
|---|---|
| Keep A34's flat floor, build A35 as its own formula | Exactly the status quo this ADR exists to stop; three reimplementations of the same accumulation shape is the pattern the audit keeps re-finding |
| Port `EffectManager.GetValue` in full, all 13 layers | Workstation tool cache and challenge journal are client-only or unbuilt features with no server consumer; porting them is speculative work with no gap behind it |
| One resolver per XML file (items, buffs, progression each own their reader) | Recreates the N-parsers problem ADR 0023 T26 was written to avoid, one file at a time |

## Follow-up

T26 ([ADR 0023](0023-perk-attribute-system.md)) implements `resolveEffect`'s
progression and buffs layers (buffs layer wraps the existing
`buffs.passiveValue`). [WORK_PLAN T28](../WORK_PLAN.md) (A35, armor
mitigation) becomes the item and equipment layers, and should land through
the same function rather than a parallel one, whichever of the two tasks is
picked up first.
