# ADR 0034: on_stat_changed observer

- **Status:** accepted
- **Date:** 2026-08-25
- **Related:** ADR 0033 (on_perk_spend verdict), ADR 0030 (plugin
  spatiotemporal composability)

## Context

Plugins can gate (verdicts) and react to discrete events (trader events,
player join/leave, deaths), but nothing observes a player's **stats** -
the survival/effects pass mutates hp/food/water/stamina and the XP ledger
advances without a plugin-visible signal. Servers that want to announce
starvation, track health thresholds, or feed a stats dashboard have no
boundary surface; per AGENTS rule 29, that behavioral surface belongs in a
plugin, not native code.

## Decision

Add an `on_stat_changed(player, hp, food, water, stamina, level, xp)`
**observer** hook (void, pure observer like `on_trader_event`) to the
plugin boundary, fired:

- once per player per tick by the survival/effects pass when any tracked
  stat changed (the pass's existing change flags), and
- on XP awards (the `awardXp` leg).

The sim stays the single authority: the hook cannot mutate, deny, or scale -
it observes the resulting state. A module that does not export the hook
costs nothing. Bounded: one call per changed player per tick (the
survival/effects pass is APM-instrumented, ADR 0034 companion P4b).

## Consequences

- Makes: starvation/health/stamina announcements, threshold tracking, and
  stats dashboards expressible in plugins.
- Makes harder: nothing native; the observer is additive and cannot bypass
  authority (no mutation path).
- Costs: one more boundary hook to maintain; per-tick calls for changed
  players are O(plugins) with a null-check per slot (zero when no module
  exports the hook).
