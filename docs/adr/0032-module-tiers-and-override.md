# ADR 0032: Module tiers and override - core / official mod / user mod

- **Status:** accepted
- **Date:** 2026-08-23
- **Related:** [ADR 0020](0020-wasm-only-plugin-api.md) (Wasm is the only
  plugin format), [ADR 0030](0030-plugin-spatiotemporal-composability.md)
  (plugin lifecycle, withdrawal, `_zdtd_requires`), [ADR 0026](0026-fps-bot-wasm-module.md)
  (bot module), [ADR 0031](0031-mcp-wasm-module.md) (MCP module).
  Product context: [PRD 0005](../prd/0005-mod-tiers-and-override.md), design
  in [RFC 0005](../rfc/0005-mod-tiers-and-override.md).

## Context

Every loadable module used to ride the same flat list: an operator hand-lists
`.wasm` paths in zdtd.toml `[plugin] modules`. That gave no tiers (official
addons like `bot` and `mcp` were indistinguishable from a user's
one-off filter), no discovery (a dropped-in folder did nothing), and no
override (core decisions in native Zig had no mod-reachable seam). PRD 0005
requires tiers, auto-discovery, disable/blacklist, and mods that can wholly
or partially replace core components and other mods.

## Decision

Adopt RFC 0005 option 3.3: a tiered manifest model with exclusive override
claims, resolved once at boot.

1. **Tiers.** `core` (native Zig, registered host-side, always on, cannot be
   disabled or blacklisted), `official` (shipped in-repo, auto-discovered),
   `user` (anything else). Tier is declared in the module's manifest and
   validated; a `mods/` manifest claiming `tier = "core"` is a load error.
2. **Manifests.** Every loadable mod ships `mod.toml` (name, version, wasm,
   optional tier, override, points, claim_mode, requires, description,
   enabled). Parsed at boot by the ADR 0021 comptime binder (`toml_bind`),
   so unknown keys fail loudly. Core components declare their override
   points in the comptime registry in `src/plugin/manifest.zig`
   (`OverridePoint` + `core_components`) rather than per-directory
   `component.toml`; a second declarative copy would drift from the compiled
   registry that routes the tick path (deliberate deviation from RFC 0005's
   "component.toml in-tree" wording).
3. **Discovery.** Boot scans `mods/*/mod.toml` (`plugin/manifest.discover`,
   sorted by dir name for determinism), resolves to a `ResolvedResult`
   (`plugin/resolver.zig`): disabled mods are skipped with an info log,
   blacklisted mods are refused and also veto any mod overriding/requiring
   them, explicit `[plugin] modules` paths are folded in as synthetic user
   mods (legacy path still works), and the final load order is logged by
   tier at boot. `[mods] disabled` / `[mods] blacklist` are comma-separated
   lists in zdtd.toml, bound through `toml_bind` like `[plugin] modules`.
4. **Core override points.** Five named points, one per existing verdict
   hook with a core decision site: `loot.roll` (on_loot_roll),
   `quest.payout` (on_quest_complete), `damage.player_scale`
   (on_player_damage), `craft.request` (on_craft_request), `trade.price`
   (on_trade_price). A mod claims points in `mod.toml` `points = "a,b"`.
   Claims are exclusive and checked at load: a duplicate claim is a boot
   error naming both contenders. A claimed point routes that verdict to the
   claimant only and skips the native default; an unclaimed point keeps
   today's first-non-zero fan-out. Routing is a branch on a load-fixed
   `claims[point] -> slot` table, so there is no new per-tick cost (rule 7).
5. **Mod replaces mod.** `override = "<mod-name>"` in `mod.toml`: the target
   is dropped from the load list, the replacer takes its slot, and cycles or
   a second replacer for the same target are load errors. `bot` and
   `mcp` are official mods (PRD 0005 tier model), not core, and are
   replaceable this way.
6. **enabled flag.** `enabled = false` keeps a discovered mod from
   auto-loading (the demo gates/feeds ship off by default so a fresh boot
   stays stock); explicit `[plugin] modules` paths still load it. This is the
   same opt-in the old hand-list gave, without the hand-listing.
7. **Semantics of a claim.** "Skips the native default" is realized over the
   existing verdict convention: the claimant returns `<0` deny, `0` keep
   stock, `>0` adjust. There is no second verdict protocol in the MVP, and
   `claim_mode = "chain"` (call-next) is rejected at load as reserved.
8. **No privilege from provenance.** Tier grants no extra host capabilities;
   official and user mods share the same fuel/memory budgets and effect
   attribution (ADR 0030). ADR 0020's invariants are untouched: no native
   dynlib, no guest sockets/fs, no raw `*Game`; overrides change which module
   decides, not what a module can reach.

## Consequences

- Fresh boots auto-discover the in-repo official mods (`bot`,
  `mcp`); the demo gates/feeds load only when explicitly listed. A user
  mod dropped under `mods/` with a `mod.toml` loads on next boot with zero
  config.
- Operators disable or blacklist any non-core mod by name; naming a core
  component is a config error (fail-closed).
- Core policy decisions (loot, quest payout, damage scale, craft, trade
  price) are replaceable whole or partially by a mod without forking the
  server, and two mods fighting over one decision stop the boot loudly.
- Negative: the override-point registry is a new permanent surface that must
  stay in sync with the verdict hooks; a future decision site that should be
  overridable but is not declared is a documented gap (per "missing beats
  fake"), and extending it is an ADR-worthy decision.
- Negative: the `enabled = false` default on shipped demo gates is a
  convention operators must learn; it is loud in the manifest and the docs.

Not decided here: call-next/chained claims (reserved), per-world mod sets,
signed packages, and version ranges on `override` targets (name-based only in
the MVP).
