# Module Tiers and Mod Override — Product Requirements (PRD)

> **Purpose:** product requirements for the mod tier and override model — which modules are the server, which are replaceable, and how conflicts fail closed.

**Number:** PRD 0005
**Status:** shipped (ADR 0032; AC1-AC8 covered by `scenarios.zig` mods tests + resolver unit tests)
**Owner:** zdtd core (mod ecosystem is a server feature, not an addon onto stock).
**Answers the question:** which modules are the server, and which are
replaceable by the operator or by other mods?
**Related:** [RFC 0005](../rfc/0005-mod-tiers-and-override.md) (technical proposal) · [ADR 0032](../adr/0032-module-tiers-and-override.md) (decision) · [PLUGIN_API.md](../PLUGIN_API.md) · [PLUGIN_STANDARDS.md](../PLUGIN_STANDARDS.md) (manifest and naming)

---

## 1. Background and problem

zdtd extends itself through Wasm modules (ADR 0020): the FPS bot
(`mods/fps_bot`), the MCP server (`mods/mcp`), and a dozen gates and
feeds. Today all of them load the same way: an operator hand-lists `.wasm`
paths in zdtd.toml `[plugin] modules`. That flat list creates three problems.

1. **No tiers.** `fps_bot` and `mcp` are official, shipped-with-the-server
   addons, but the config treats them identically to a user's one-off chat
   filter. Nothing records that distinction, so nothing can reason about it
   (defaults, docs, who owns a bug).
2. **No discovery.** A modder drops a folder under `mods/` and nothing happens
   until the operator edits a comma-separated string. Modlets (PRD 0003) got
   auto-discovery; Wasm mods did not.
3. **No override.** Core server behaviour (damage scaling, loot rolls, quest
   rewards) lives in native Zig with no way for a mod to replace it. A user
   who wants "Navezgane but double zombies and my own loot tables" cannot get
   there from the plugin boundary, because the boundary can only observe and
   nudge, not take over a decision.

The missing concept is a **tier model**: some modules are the server and some
are replaceable, and replaceable includes replacing parts of the server
itself.

## 2. Personas

- **Operator** — runs a zdtd server, wants bots and MCP on by default, wants
  to turn a feed off with one line, wants a loud error when two mods fight
  over the same behaviour instead of silent nondeterminism.
- **Modder** — wants to drop a folder under `mods/` and have it load, declare
  "I replace X", and have the whole thing work without forking the server.
- **Core developer** — wants the boundary between core and mods explicit and
  enforced, so gameplay policy keeps flowing through Wasm (ADR 0020 rule 29)
  and core stays authoritative and fast.

## 3. Goals

1. Define three module tiers: **core** (native Zig, compiled in, always on),
   **official mods** (shipped Wasm modules, on by default), **user mods**
   (dropped in `mods/`, on by default).
2. Auto-discover every mod under `mods/` by manifest; no hand-listed paths
   required to run the shipped addons.
3. Let the operator disable or blacklist any non-core mod from zdtd.toml;
   core components cannot be disabled or blacklisted (revisit later).
4. Let any mod override the behaviour of a core component, wholly or
   partially, through declared override points.
5. Let any mod override an official mod completely (e.g. replace `fps_bot`
   with a total conversion of behaviour, rules, or assets).
6. When mods conflict (two claim the same override), fail loudly at load with
   a named, deterministic outcome.

## 4. Scope

### In scope (MVP)

- Tier model and tier manifests (`manifest.toml` for official and user mods;
  core override points declared in the comptime registry in
  `src/plugin/manifest.zig` — the RFC's per-directory `component.toml`
  wording was deliberately not built, see ADR 0032 decision 2).
- Auto-discovery of `mods/*/manifest.toml` at boot.
- `[mods] disabled` / `[mods] blacklist` in zdtd.toml.
- Override points on core components: exclusive claims on named decision
  points; unclaimed points keep native default behaviour.
- Mod-replaces-mod: one mod fully replaces an official or user mod.
- Default chaining for verdict hooks that are not exclusively claimed
  (today's deny/adjust composition, unchanged).

### Out of scope (later, only with demand)

- **call-next / middleware chains** (a mod invoking the next claimant in a
  chain). The design reserves room for it; it is not built now.
- Disabling or overriding-away core components entirely ("no inventory
  system"). Core stays always-on.
- A mod SDK, marketplace, signing, or hot-reload of overrides beyond what
  ADR 0030 already provides.
- Per-world mod sets (one server, one mod set).

## 5. User stories

- As an operator, I run the server with zero config and get the official
  addons (bots, MCP) active, so a fresh install is useful immediately.
- As an operator, I add `core_killfeed` to `[mods] disabled` and it stops
  loading, with one log line saying so.
- As an operator, I blacklist a broken user mod and the server refuses to
  load it even if another mod names it as an override target or dependency.
- As a modder, I drop `mods/my_rules/` with a `manifest.toml` and a `.wasm`, and
  it loads on next boot without touching zdtd.toml.
- As a modder, I declare `override = "fps_bot"` and my module runs instead
  of the official bot module; the official one is not instantiated.
- As a modder, I claim one core override point (say quest reward payout) and
  only that decision routes to my module; every other core behaviour is
  untouched.
- As a modder who claimed a point someone else also claimed, I get a load
  error naming both modules and the server refuses to start rather than
  picking a silent winner.

## 6. Functional requirements

- **R1 (tiers).** The server distinguishes core components, official mods,
  and user mods. Tier is declared in the module manifest. Core components
  are native and registered host-side; official and user mods are Wasm.
- **R2 (manifests).** Every loadable module has a manifest. Mods use
  `manifest.toml` in their `mods/<name>/` directory, carrying at least `name`,
  `version`, `wasm`, and optional `tier`, `override`, `requires`. Core
  components declare their override points host-side in the comptime
  registry (`OverridePoint` + `core_components`,
  `src/plugin/manifest.zig`); a second declarative copy (`component.toml`)
  was rejected as drift-prone (ADR 0032 decision 2).
- **R3 (discovery).** At boot the server scans `mods/*/manifest.toml` and loads
  each mod not disabled or blacklisted. Explicit `[plugin] modules` paths
  keep working as an additional load source.
- **R4 (disable/blacklist).** `[mods] disabled` skips a mod with an info
  log. `[mods] blacklist` is fail-closed: a discovered mod whose name is
  blacklisted refuses the boot with a named error (pinned by the resolver
  unit test and mods AC2 scenario), as does any mod overriding it. Entries
  naming a core component are rejected as config errors: core cannot be
  disabled or blacklisted.
- **R5 (core override points).** Core components expose named override
  points at their decision sites (a point id plus the verdict hook it maps
  to). A mod claims points in its manifest. A claimed point routes the
  decision to the claiming mod and skips the native default; an unclaimed
  point runs the native default. Claims are exclusive.
- **R6 (whole or partial).** A mod may claim any subset of a component's
  points, up to all of them. Claiming all points of a component is the
  supported way to "override a whole core component".
- **R7 (mod replaces mod).** A mod whose `override` names another mod
  replaces it: the target is not instantiated and its hooks do not fire;
  the replacer takes its slot.
- **R8 (conflicts).** Two mods claiming the same override point, or the
  same override target, is a load-time failure naming every contender. The
  server does not start with silently dropped claimants.
- **R9 (chaining default).** Verdict hooks that are not exclusively claimed
  behave exactly as today: all subscriber mods run in deterministic order
  and their verdicts compose. The MVP adds no new composition semantics.
- **R10 (lifecycle).** Discovery, tier resolution, override resolution, and
  conflict detection all happen at load, before any guest is instantiated.
  ADR 0030 reload/withdraw/`_zdtd_requires` semantics apply unchanged to
  discovered mods.

## 7. Non-functional requirements

- **N1.** No new cost on the 50 ms tick: override checks resolve to a
  branch on data fixed at load; no allocation, no scanning, per tick.
- **N2.** Load-time validation is fail-closed: unknown override point,
  unknown/blacklisted target, duplicate claim, malformed manifest, each is
  a loud boot error, not a silent skip.
- **R3-style budgets unchanged:** fuel, memory caps, and effect attribution
  (ADR 0030) apply identically to official and user mods; tier grants no
  extra host capabilities.
- **N4.** ADR 0020 is untouched: no native dynlib mods, no guest sockets or
  filesystem, no raw `*Game`. Overrides change which module decides, not
  what a module can reach.

## 8. Acceptance criteria (product)

- [x] AC1 (G1, G2): fresh world, no zdtd.toml, server boots with official
  addons loaded and logged by tier; `plugin list` shows tiers.
- [x] AC2 (G3): `[mods] disabled = ["fps_bot"]` boots without the bot
  module and one info log; `[mods] blacklist` refuses to boot with a named
  error and also rejects a mod overriding the blacklisted name.
- [x] AC3 (G3): `[mods] disabled` naming a core component fails config
  validation with a clear error.
- [x] AC4 (G4): a test mod claiming one core override point changes only
  that decision; all other behaviour is byte-identical (scenario test).
- [x] AC5 (G4): a test mod claiming every point of a component changes all
  of that component's decisions.
- [x] AC6 (G5): a test mod with `override = "fps_bot"` runs in its place;
  `fps_bot.wasm` is not instantiated.
- [x] AC7 (G6): two test mods claiming the same point produce a boot error
  naming both; server refuses to start.
- [x] AC8 (G1): official and user mods run under the same fuel/memory
  budget and queued-effect attribution as today.

## 9. Risks and mitigations

- **Override points ossify the core.** Every new decision site must be
  declared to be overridable, and a forgotten point is a silent gap.
  Mitigation: the core override-point registry is reviewed in the
  plugin-composability pass (docs/prompts/plugin-composability-review.md);
  gaps are documented in STATUS, per "missing beats fake".
- **Ecosystem confusion between "official" and "endorsed".** Mitigation:
  tier is provenance ("shipped with zdtd"), not a privilege; official mods
  get no extra capabilities (N3).
- **Replace-whole-mod chains** (A replaces B, C replaces A). Mitigation:
  R8 conflict rules plus a resolved-order log at boot; cycles are load
  errors.

## 10. Milestones

See the paired [RFC 0005](../rfc/0005-mod-tiers-and-override.md) for the
build order (tier registry, manifests and discovery, config keys, override
claims, conflict detection, scenario coverage).

## 11. Out-of-scope signpost

call-next middleware, per-world mod sets, disabling core, signed mod
packages: all deliberate MVP omissions. Do not "fix" them into the first
cut; each needs its own demand signal first.
