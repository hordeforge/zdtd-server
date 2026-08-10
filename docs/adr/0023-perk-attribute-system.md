# 0023. Perk and attribute progression system

- **Status:** accepted
- **Date:** 2026-08-10
- **Related:** [ADR 0021](0021-config-driven-game-modes.md) (`Rules` floors over
  stock data), [GAP_ANALYSIS.md](../GAP_ANALYSIS.md) (Server-side XP ledger,
  Skill points granted per level), [docs/reviews/HARDCODE_AUDIT.md](../reviews/HARDCODE_AUDIT.md)
  A34.

## Context

`assets/progression.zig` parses the level curve and the attribute/perk
**catalog** from `progression.xml`: names, max levels, costs. That is as far as
it goes. Confirmed by grep across the whole tree: no per-player attribute
level, no per-player perk level, no spent-skill-point balance, and no evaluator
for `<level_requirements>` exists anywhere in `src/`. `GAP_ANALYSIS.md` already
carries this as an open, explicitly waived gap ("Skill points granted per
level": *parsed but no server-side balance exists yet*).

The gap stopped being purely cosmetic when A34 (this pass) found a kill-XP path
that depends on it. Stock's `ItemActionAttack.Hit` and
`ProjectileMoveScript.checkCollision` scale a turret or trap kill's XP by the
passive effect `PassiveEffects.ElectricalTrapXP`, whose stock default is **0**
(`buffs.xml:17001`: *"% of trap kill XP that the player gets"*) and which is
only raised by `perkAdvancedEngineering` (an Intellect-gated perk,
`progression.xml:3214`) at levels 1 through 5: .15 / .3 / .45 / .6 / .75.
Without a perk system, zdtd cannot compute that fraction per player, so it can
only apply a **flat floor** (`Rules.progression.trap_kill_xp_frac`, ADR 0021
decision 5), not the value stock would actually pay a given player. That is
this ADR's concrete forcing function, and it will not be the last one: 59 perks
in the shipped catalog reference 517 `ProgressionLevel` requirements, and any
of them can gate a passive effect a future system wants to read.

`progression.xml` scope, measured against the shipped file: 59 `<perk>` blocks,
324 `<level_requirements>` blocks, and a `<passive_effect>` catalog with
dozens of named effects (`ElectricalTrapXP` is one of many, not a special
case).

## Decision

### 1. Store attribute and perk levels per player, not compute them on demand

Each player gets an attribute-level array (one entry per `AttrDef` in the
catalog) and a perk-level array (one per `PerkDef`), plus a spent and available
skill-point balance. This lives on the same player state that already survives
a restart (`players.zsv`, ZPV3), not recomputed from XP on each read: recompute
would require replaying the level-requirement graph on every query, and the
graph has forward and backward dependencies (perks gated on attribute level,
some attributes gated on perk prerequisites).

### 2. A minimal requirement evaluator, scoped to what gates a level-up, not a full expression DSL

Stock's `<requirement>` vocabulary is large (`HasBuff`, `RandomRoll`,
`CVarCompare`, `EntityTagCompare`, and more, used across buffs, quests and
perks alike). Implementing all of it to unlock progression is the wrong slice.

**v1 scope:** `<level_requirements>` blocks are evaluated **only** for their
`ProgressionLevel` requirements (attribute-level and perk-level comparisons),
since that covers gating a perk level-up or an attribute level-up, which is
the only decision this system has to make. A requirement type the evaluator
does not recognize inside a `<level_requirements>` block **fails closed**: the
level-up is refused rather than guessed at. This mirrors the "prefer missing
over fake" rule (AGENTS) and the fail-closed default the codebase already uses
for unresolved XML references (T16's `Survival.ok()` guard is the same shape).

### 3. A generic passive-effect resolver, not a second one-off `Rules` floor per gap

A34 fixed one call site with a flat `Rules` floor because no per-player
resolver existed. That pattern does not scale: `EffectManager.GetValue` is
called from dozens of stock sites for dozens of named effects, and porting
each as its own `Rules` field would mean rediscovering this ADR's problem once
per effect.

Once per-player perk levels exist, add one function,
`resolvePassiveEffect(player, effect_name, tags) f32`, that walks the loaded
perks' passive-effect rows for the player's current levels and aggregates them
the way `buffs.zig`'s `passiveValue` already aggregates buff passives
(`base_set`/`perc_set` overwrite, `base_add`/`perc_add` sum, adopted verbatim
since it is the same operation vocabulary). Every future "does a perk change
this number" gap becomes a call to this function, not a new `Rules` field.

**The `Rules` floor stays**, per ADR 0021 decision 5: it becomes the value used
when no perk system has assigned levels yet (a fresh player, an offline test,
a mode that turns progression off), and the resolver overrides it once a level
exists. This is not a contradiction of the A34 fix; it is decision 5 applied
exactly as written, with the resolver arriving later than the floor.

### 4. Wire: land the S2C push before the C2S spend request

`buildPlayerStatsBody` already exists (`wire/stock_xp.zig`) and is the
mechanism to tell a client its level state changed. Building the C2S
perk-point-spend path before the server can echo the result back correctly
would let a client believe it spent a point the server silently dropped.
Sequence: server-authoritative level-up on XP threshold (already exists via
`awardXp`) pushes attribute/perk state → **then** accept a C2S spend request
against that pushed state.

### 5. No stock formula invented for anything `progression.xml` does not state

The level curve's parity bug (`GAP_ANALYSIS.md`, exponent off by 2) stays
separately tracked and is not folded into this program; fixing a wrong formula
and building a missing system are different tasks with different risk.

## Consequences

### Positive

- A34's fix upgrades cleanly from a flat floor to the real per-player value
  without touching its call site again: the call becomes
  `resolvePassiveEffect(player, "ElectricalTrapXP", .{})`, floor unchanged.
- One resolver, not N `Rules` fields, for every future perk-gated number.
- Fail-closed unknown requirements mean an unimplemented requirement type is
  visible as "cannot level" rather than a silently wrong unlock.

### Negative / costs

- 324 `<level_requirements>` blocks and 59 perks is real parsing and testing
  surface, even with the scoped v1 evaluator.
- Per-player state that persists means another persistence format (or an
  extension of ZPV3) with its own empty/corrupt/version handling, per the
  house rule that every non-trivial format gets that treatment.
- The resolver's aggregation must exactly match `buffs.zig`'s operation
  semantics or the two systems compute the same class of number two different
  ways, which is its own audit finding waiting to happen.

## Alternatives considered

| Option | Why not |
|---|---|
| Keep patching one `Rules` floor per discovered gap | Already the status quo that produced A34; does not close the underlying gap, just adds fields |
| Implement the full stock requirement DSL up front | Most of it (buffs, quests) is out of scope for what gates a perk level-up; large surface for no immediate consumer |
| Compute attribute/perk level from XP on every read | The requirement graph has cross-dependencies; recomputing it per query is both slower and harder to reason about than storing the result |
| Trust client-reported perk levels | Same authority failure ADR 0007 already rejected for inventory; a perk level gates gameplay numbers (damage, XP) and must be server-owned |

## Follow-up

Implementation is [WORK_PLAN.md](../WORK_PLAN.md) T24 through T27, in order:
persist per-player levels, the scoped requirement evaluator, the generic
passive-effect resolver (which upgrades A34's floor), then the C2S spend path
behind the S2C push.
