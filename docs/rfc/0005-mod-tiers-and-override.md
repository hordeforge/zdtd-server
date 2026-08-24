# Module Tiers and Mod Override — Technical Proposal (RFC 0005)

> **Purpose:** technical proposal for the mod tier and override model — manifest shape, discovery, override claims, and conflict rules.

**Number:** RFC 0005
**Status:** decided (shipped; implements PRD 0005, recorded in ADR 0032)
**Source:** [PRD 0005](../prd/0005-mod-tiers-and-override.md) — the requirements this answers
**Related:** [PRD 0005](../prd/0005-mod-tiers-and-override.md) · [ADR 0032](../adr/0032-module-tiers-and-override.md) · [PLUGIN_API.md](../PLUGIN_API.md) · [PLUGIN_STANDARDS.md](../PLUGIN_STANDARDS.md)

## 1. Decision to make

Which mechanism do we adopt so that (a) modules carry a tier (core vs
official mod vs user mod), (b) mods are auto-discovered and individually
disable-able/blacklist-able, and (c) mods can wholly or partially replace
core components and other mods, with conflicts failing loudly at load?

## 2. Current state

- Loading: `src/main.zig` splits zdtd.toml `[plugin] modules` (comma/space
  string) into paths; `src/plugin/wasm.zig` `WasmHost.loadAll` instantiates
  each. No discovery, no tier, no order, no priority, no override.
- Manifests: optional and decorative. Five mods under `mods/` carry a
  `mod.toml` (`name`, `version`, `wasm`, `description`); the rest
  (`bot`, `mcp`, gates, feeds) have none. Nothing parses them at
  runtime.
- Official addons: `mods/fps_bot` (ADR 0026) and `mods/mcp` (ADR 0031)
  are shipped in-tree but load through the same flat list as user mods.
- Modlets (PRD 0003/RFC 0003): auto-discovery precedent exists —
  `Mods/<name>/Config` XPath patches under the game dir, joined into patched
  catalogs; `src/assets/modlets.zig`. This is data-only, but it is the
  discovery pattern to mirror.
- Composition today: verdict hooks (on_player_damage, on_loot_roll,
  on_quest_complete, on_craft_request, on_trade_price …) compose as
  multiply-verbs over all subscribers in deterministic load order
  (`src/plugin/wasm.zig` Hook enum, order = slot order). There is no
  exclusive claim, no call-next, no way to skip another mod's verdict.
- Composability: ADR 0030 gives reload, effect withdrawal, and declarative
  `_zdtd_requires` (hooks + host verbs). `_zdtd_requires` validates at load
  fail-closed. This RFC extends that manifest surface.
- Core decisions live in native Zig (e.g. `src/server/game/loot.zig`,
  quest payout, damage application). Core is always on and not
  mod-reachable at decision sites today.

## 3. Options considered

### 3.1 Status quo + conventions (no tier, no discovery, no override)

Nothing to build. Official addons stay hand-listed; users fork the server to
change core behaviour. Fails PRD G2/G4/G5 outright, and the flat list is
already an operator trap (a typo silently loads nothing).

### 3.2 Config-only tiers (zdtd.toml lists tiers, no manifests)

Tier as a config key per entry (e.g. `[mods] official = [...]`). Adds
discovery + disable/blacklist without a manifest format. But: no `override`
story, modders cannot self-declare anything, and tier becomes operator
assertion rather than provenance — exactly the confusion PRD §9 flags.

### 3.3 Tiered manifest model with exclusive override claims (recommended)

Every loadable module gets a TOML manifest; tier comes from the manifest and
where it lives; override is a first-class claim checked at load.

- **Core components**: native Zig, in-tree, registered host-side in the
  comptime registry in `src/plugin/manifest.zig` (`OverridePoint` +
  `core_components`), always on. As built, there are no per-directory
  `component.toml` files: a second declarative copy would drift from the
  compiled registry that routes the tick path (deviation recorded in
  [ADR 0032](../adr/0032-module-tiers-and-override.md) decision 2).
- **Official mods and user mods**: Wasm guests in `mods/<name>/` with
  `mod.toml`. Official = shipped in the repo's `mods/` tree; user = anything
  else the operator points at. Tier is declared in the manifest and
  validated (a `mods/` dir claiming `tier = "core"` is a load error).
- **Discovery**: boot scans `mods/*/mod.toml`. Explicit `[plugin] modules`
  paths remain a valid additional load source (bootstrapping, tests).
- **Disable/blacklist**: `[mods] disabled` / `[mods] blacklist` in
  zdtd.toml, matched against discovered mod names.
- **Core override points**: each core decision site that is overridable is
  declared as a named point (`loot.roll`, `quest.payout`,
  `damage.player_scale`, …) backed by an existing verdict hook. A mod claims
  points in `mod.toml`. Claimed → the claiming mod's verdict decides and the
  native default is skipped; unclaimed → native default. Claims are
  exclusive; duplicates fail at load.
- **Mod replaces mod**: `override = "<mod-name>"` in `mod.toml`. Target not
  instantiated; replacer takes its slot. Cycles and conflicts fail loudly.
- **Composition of unclaimed hooks**: unchanged (all subscribers, slot
  order).
- **call-next**: not built. Reserved: claim records carry an optional
  `mode = "exclusive"` (default) with `"chain"` left as a future value; the
  loader rejects `chain` today with a clear "not yet supported" error. This
  keeps the manifest schema stable for the future without shipping
  semantics we cannot test.

### 3.4 Call-next middleware for everything

Every override is a chain where a mod can invoke the next claimant (like
Kestrel/OWIN middleware). Maximal flexibility, but it forces total
re-entrancy into the guest runtime (a guest calling back into the host to
call another guest), re-entrancy we would have to bound with fuel across
nested calls, and a mental model modders must learn before their first
hello-world. The user explicitly triaged this to "good to have
infrastructure, not now" (answer 2). Ship 3.3; reserve the schema slot.

### 3.5 Native reimplementation of all policy (kill Wasm for policy)

Wire everything as native policy in Zig. Fast, but it reverses ADR 0020/29
(wasm-first for behavior) and locks out the mod ecosystem. Not this RFC.

## 4. Recommendation

**Option 3.3.** It satisfies every goal (G1-G6), reuses the existing
verdict-hook plumbing as the transport for override decisions, and keeps
ADR 0020/0030 untouched in their invariants: authority, budgets, fail-closed
loads. Costs: a new manifest parser surface (small; TOML already parsed at
boot), a core override-point registry that must be kept honest (mitigated
by the composability review pass), and the discipline that every new
overridable decision site is declared as a point.

What would change the recommendation: evidence that modders routinely need
call-next chains (move to 3.4), or that operators of single-mod servers find
manifests burdensome (fall back to 3.2 for discovery-only).

## 5. Open questions

1. **Scope of the MVP point set.** Which core decision sites become points
   in the first cut? Candidates from existing verdict hooks: loot roll, quest
   payout, player damage scale, craft, trade price. Answerable by auditing
   `src/plugin/wasm.zig` Hook enum vs core call sites (a small RE pass over
   `src/server/game/`).
2. **Slot accounting under replace.** When mod B replaces mod A, does B
   inherit A's slot index (keeping `_zdtd_requires`-derived order stable) or
   get its own? Lean inherit (stable order), needs a scenario test.
3. **Official-mod identity across versions.** `override = "fps_bot"` names
   a module, not a version. Should the manifest carry a version range
   (e.g. `bot >= 0.1`)? Lean no for MVP; name-based only.
4. **Hook coverage.** Override points need to map cleanly onto existing hook
   signatures; if a core decision site has no hook, does it get a new hook
   or is it out of scope? (This is the audit in Q1.)

## 6. References

- ADR 0020 (Wasm-only plugin API), ADR 0026 (bot module), ADR 0030 (plugin
  composability), ADR 0031 (MCP module)
- PRD 0005 (this addon's requirements), PRD 0003 (modlet discovery precedent)
- `src/plugin/wasm.zig` (runtime, hook table, budgets), `src/main.zig`
  (`[plugin] modules` split), `src/assets/modlets.zig` (discovery pattern)
- `docs/PLUGIN_API.md`, `docs/PLUGIN_DEV.md`, `docs/PLUGIN_CONFIG_DISPOSITION.md`
