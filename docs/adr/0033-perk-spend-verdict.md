# ADR 0033: on_perk_spend verdict hook

- **Status:** accepted
- **Date:** 2026-08-25
- **Related:** ADR 0023 (perk/attribute progression), ADR 0024 (passive-effect
  stack layers), ADR 0030 (plugin spatiotemporal composability)

## Context

Perk spending is server-authoritative: `NetPackageEntitySetSkillLevelServer`
validates the purchase against the catalog (known skill, one level at a time,
max level, parent attribute, skill-point balance) and applies it. The
remaining open surface is **policy**: operators may want to gate specific
perks (a PvP server blocking combat perks), scale costs (economy servers), or
observe spends. Per AGENTS rule 29, discretionary gameplay behavior belongs in
a plugin, not native code. The verdict-hook pattern already exists
(`on_player_damage`, `on_craft_request`, `on_trade_price`, ...): a native
choke consults plugin hooks; `<0` denies, `0` keeps, `>0` scales by percent.
Spending has no such hook yet.

## Decision

Add a `on_perk_spend(player, skill, level, cost)` verdict hook to the plugin
boundary, consulted by the C2S spend handler after the catalog validation:

- `<0` denies the spend (no skill points spent, no level granted, no echo);
- `0` keeps the catalog cost;
- `>0` scales the skill-point cost by percent (`cost x v / 100`, floor 1).

The stat deltas stay native (the passive-effects VM, ADR 0024); the hook only
gates/customizes the spending itself. A module that does not export the hook
costs nothing (missing export -> keep). The hook is a plain slot hook like
`on_player_damage` (first non-keep verdict wins, slot order); it is not an
exclusive override point, so several modules may gate concurrently.

## Consequences

- Makes: per-perk gating, cost scaling, and spend observation expressible in
  plugins (reference module: `plugins/core_perkgate`, deny `forbidden_*`).
- Makes harder: nothing on the native side; the catalog validation and the
  VM deltas remain the single authority for what a purchase *is*.
- Costs: one more hook on the boundary to maintain; the first-non-keep
  semantics means a deny from one module cannot be overridden by a later
  module (same as the other verdicts).
