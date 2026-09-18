# Plugin composability review against the Cordis paper

**Run:** 2026-09-12 (round 24 review; re-traces F1-F6 and adds F7-F11)
**Paper:** *A Programming Paradigm for Spatiotemporal Composability*,
Shi / Zhang / Cui (Peking University, DeepSeek-AI), arXiv:2608.25512v1,
submitted 2026-08-26, 92 pages. The `cordiverse/paper` repository's
`paper.pdf` path named in the objective no longer exists: the repo now holds a
README that points at arXiv (commit "read the paper on arxiv", 2026-08-26), so
this review is pinned to the arXiv v1 PDF.
**Prompt:** [prompts/plugin-composability-review.md](../prompts/plugin-composability-review.md).
**Verdict:** the three properties zdtd adopted (ADR 0030) are realized for the
paths F1-F6 fixed. This round re-traced those and found five further gaps in
the load/reload/claim paths (F7-F11): one P1 (a boot-time exclusive point
claim is indexed by plan slot, so any module the loader skips shifts the
binding onto a different live module or silently voids it), three P2
(reloads bypass the fail-closed declaration probe and can silently drop a
module's own queued-verb deny, and a manifest that fails validation is
accepted on reload where boot would refuse), and one P3 (deny granularity
between the ECS `spawn` verb and the `bot spawn` family). No fix applied:
this run was read-only, so these are findings with sketches.

## Mechanism map

| Paper mechanism | zdtd realization | Status |
|---|---|---|
| 3.1 revertible effects (`track`, `recover`, LIFO inverse accumulator) | `zdtd.queue` verbs carry a 1-based plugin src; `CommandBuffer.dropFrom` + `Game.withdrawPluginSrc` drop pending ops, despawn applied spawns, clear applied glide, drop bots; `inverseOfOp` classifies every verb and the refusal residue is counted | **Realized** for the revertible verbs, with the non-invertible remainder classified and reported (F3 fixed) |
| 3.1.2-3 effect functions / iterators, step-boundary interruption | Each hook call is a unit; a trap or fuel exhaustion disables the module mid-turn and the withdrawal pass runs before the drain | **Realized** for the host-driven unit granularity |
| 3.2.1-2 coeffect context, satisfaction, `notify` | `_zdtd_requires` is the specification; load rejects a module that cannot satisfy it (fail-closed), so a loaded module never reads an absent binding | **Realized** as a load-time check; no runtime `notify` (no host capability changes at runtime) |
| 3.2.2 provider ordering / withdrawal before dependents | `WasmHost.claimSlot` (this run) resolves an exclusive point claim against the claimant's liveness; a disabled or hook-less claimant stops providing | **Fixed here** (F1); the general provider-drain ordering has no analogue because dependencies are host-only (F5), and the boot claim *table* can still name the wrong slot when the loader skips a module (F7) |
| 3.2.3 isolation (`ctx.isolate`) | each module has its own instance, memory and config bytes; no realm table for shared keys | **N/A today**: no two modules share a dependency key with different bindings |
| 3.2.3 interception (`ctx.intercept`, right-biased metadata) | `manifest.toml deny` (module declaration) merged with `zdtd.toml [plugin] deny`/`allow` (operator context, applied last), enforced at the `zdtd.queue` boundary | **Realized** (F4 fixed, ADR 0039) |
| 5.1.1 `ctx.effect` single mutation primitive | every plugin affordance that mutates the world is a queued command; direct ECS/wire mutation is absent | **Realized** (boundary), with the witness unverified exactly as the paper says a host may leave it |
| 5.1.2 coeffect operations / 5.1.4 context access | `zdtd.config` (per-module bytes), `zdtd.sense`/`zdtd.query` read-only views; no `ctx[key]` reflection | **Realized in spirit**: capabilities are imports, not a reflective table |
| 5.1.3 component lifecycle (inertial load/unload, reload chaining) | `Plugin.load` -> `on_enable`; `on_shutdown` -> withdraw -> deinit -> `loadInto` -> `on_enable`; a failed reload drops the slot and re-points backlinks and claims | **Realized** for the single-instance case |
| 5.2.1 declarative configuration reconciliation | `manifest.toml` + resolver plan (tiers, `override`, point claims) builds the composition at boot; `[mods] enabled/disabled` is boot-time; `plugin reload` now re-reads the module's manifest and reconciles its point claims (F2), while the zdtd.toml/mode-pack chain stays a restart-time read | **Realized** for the per-module declaration (F2 fixed); the config chain remains boot-time, and the reload re-read is more permissive than boot when the declaration disappears or the manifest is invalid (F8/F9) |
| 5.2.2 hot module replacement | `plugin reload <name>`: dispose and reinstantiate in place, budget re-armed, config/display/tier preserved | **Realized** |
| 6.5 mutual dependencies / granularity | dependencies name host capabilities only, so a cycle cannot form; the resolver already reports duplicate point claims at load | **N/A today**; cycle reporting from declarations is the check to add if plugins ever provide keys |
| 6.6 dependency typing/versioning | an optional `_zdtd_api() -> i32` export carries the guest's contract version: newer than the host is refused fail-closed, older is accepted and logged, absent keeps the permissive legacy path; the shipped Zig guests export it and a host test gates the two constants against each other | **Realized** (F6 fixed) |

## Findings

**F1 (P1, fixed) - an exclusive claim stayed bound to a provider that stopped
providing.** `playerDamage`, `craftRequest`, `lootRoll`, `tradePrice` and
`questComplete` read `claims[point]` and routed straight to that slot. When the
claimant trapped or ran out of fuel, `Plugin.call*` returned `verdict_keep`, so
the point answered keep for every caller: a user-tier gate claimant that
crashed silently lifted the core restriction it overrode, and no other provider
was consulted. Paper 5.1.2: "a binding counts as available to a dependent only
while the fiber that installed it is ACTIVE". Fix: `WasmHost.claimSlot`
returns the claimant only while it is active *and* still exports the point's
hook; the five dispatches fall through to the ordinary composition loop
otherwise. The table itself is left alone, so a reload of the same module
re-arms the claim with no bookkeeping. Proven by the new scenario
`scenario mods: a disabled claimant releases its exclusive point`
(`assets/fixtures/plugin_claim_trap.c`: a claimant that traps on its first
`on_loot_roll`), which asserts the fallback module's 300% answers the second
call instead of the dead slot's keep.

**F2 (P2, fixed 2026-09-12) - reload now re-reads the module's declaration.**
`reload` used to call `loadInto` with the slot's path and preserve
tier/display/config, but the claim table is only built by `loadResolved` at
boot, so a module replaced on disk that dropped its `points` claim kept
exclusivity while it was active (F1's hook check only catches a dropped hook)
and one that added a claim never got it. `WasmHost.reconcileClaims` now runs
after a manifest-loaded slot is reinstantiated: it releases every claim the slot
held, re-reads `<mod dir>/manifest.toml` with the same binder the boot resolver
uses, and re-installs the declared points under the boot rule - a claim whose
hook the module does not export, or whose point another live module already
holds, is refused with a log. A legacy `[plugin] modules` path carries
`manifest_loaded = false` and is never reconciled, so a `manifest.toml` that
happens to sit beside it can neither mint nor drop a claim. Gated by the
`plugin.wasm` test "reload reconciles the module's manifest point claims"
(claim install, second-claimant refusal, drop-on-reload release, install after
release, missing-hook refusal, legacy-path no-op), which uses temp dirs and
hand-built modules and so writes nothing into the repo.

**F3 (P2, fixed 2026-09-12) - the inverse classification is now a checked
table.** `Op` has five verbs: `spawn_zombie` and `glide` are revertible
(despawn, clear flag); `damage`, `say` and `despawn` are applied effects with no
inverse, which is a legitimate boundary decision (paper 6.1 delimits the author
obligation; 5.1.1 notes the runtime never verifies the witness) but was recorded
only in comments, so the review prompt's rule ("no new side-effect verb without
a withdrawal story") was unenforced. `ecs/command.zig` now carries
`Inverse { revertible, irrevocable }` and `inverseOfOp(Op)` with an exhaustive
`switch` (no `else`), so a new verb fails the build until it is classified. The
classification has a live consumer: `drainWith` counts applied irrevocable
effects per source, `withdrawPluginSrc` takes that count and adds it to the
`plugin_effects_not_reverted` apm counter, and slot compaction moves a source's
residue with it. A spawn-only withdrawal leaves the counter at 0; a withdrawn
plugin that broadcast a chat message reports 1. Gate: the `ecs.command` unit
tests (classification table, per-source residue, compaction) plus the
`scenario plugin withdrawal despawns applied spawns` assertions.

**F4 (P2, fixed 2026-09-12) - queued-verb interception is now a real policy.**
The paper's 3.2.3 `intercept` (context-carried metadata merged with the
component's declaration, right-biased so the enclosing context wins) had no
counterpart: a module either loaded with every queued verb or did not load. ADR
0039 adds the missing surface. `manifest.toml deny = "say,damage"` declares
verbs the module will not queue (validated at load, unknown verb fails the
manifest); `zdtd.toml [plugin] deny`/`allow` are `module=verb,verb` lists parsed
at boot (a bad entry or unknown verb is a fatal startup error); the effective
mask is `(module_deny | operator_deny) & ~operator_allow`, so the operator is
applied last and can both tighten and relax the module's own declaration.
Enforcement is at the `zdtd.queue` boundary (`wasm_host.pluginVerbDenied`)
ahead of the ECS command parse *and* the host `bot` family, so a denied verb
cannot land in the buffer, spawn an entity, or reach `BotManager`; drops are
counted in `plugin_verbs_denied` and logged rate-limited. Reload re-reads the
manifest deny (ADR 0030 F2 path) and keeps the operator masks, so HMR cannot
wash the policy away. Gated by the `plugin.manifest` grammar test, the
`plugin.wasm` "queued-verb policy" test (module deny, operator right-bias,
reload, legacy path) and the `server.game.tests` boundary test (denied verb
dropped and counted, allowed verb queued, native src exempt, operator allow
clears a module deny). What is *not* adopted: per-verb scaling or parameter
rewriting, and live policy reload - both would need a richer merge than a
bitmask and a runtime config path, and neither is required by the paper's model.

**F5 (P3, open, recorded difference) - no inertial provider ordering.** The
paper drains a provider's dependents before running its inverses; zdtd has no
plugin-to-plugin bindings (requirements name host capabilities only), so the
case cannot arise. Recorded so a future plugin-provided key is designed with
the ordering from the start.

**F6 (P2, fixed 2026-09-12) - the guest declares its contract version.**
Paper 6.6 names the two failure modes of name-only linking: interface drift and
key collision. zdtd linked by hook/verb name and validated the *set*
(`_zdtd_requires`), but no guest export carried the contract version, so a
module built against an older or newer hook surface was accepted whenever its
names still matched; an arity change failed closed (the wasm call type check
traps) but a same-signature semantic change was silent, and `PLUGIN_API.md`
claimed `plugin_api_version` named the guest contract with nothing reading it.
`Plugin.probeApiVersion` now reads the optional `_zdtd_api() -> i32` export: a
version newer than `api.plugin_api_version` fails closed through the
`_zdtd_requires` channel (the reason names both versions), an older one is
accepted with a log, and a module without the export keeps the permissive path
(the shipped C fixtures and any pre-versioning module). `mods/plugin_common.zig`
exports `_zdtd_api` for every Zig guest, and the host test "shipped core plugins
declare the host contract version" loads all 14 shipped modules and asserts each
declares the host version, so the two constants cannot drift silently. Key
collision does not arise: the vocabulary is a fixed host table, not an open key
space.

That test also caught the second half of the composition bound: the host table
was `max_wasm_plugins = 8` while the shipped tree already had 14 modules, so a
full `[plugin] modules` list silently lost modules at the cap. The ceiling is
now 32, and the test asserts the shipped set still fits it.

**F7 (P1, open) - a boot-time exclusive point claim is indexed by plan slot,
not by loaded slot.** The resolver records each module's claim against its
position in the final *plan* (`resolver.zig:236`; plan slots are stamped
`= load.items.len` at `resolver.zig:183/199/294`), and `loadResolved` installs
the claim by that same number (`wasm.zig:1083` `const slot = entry.value_ptr.*`).
But `loadResolved` increments `self.n` only for a module that actually loads:
a bad wasm path (`wasm.zig:1009-1012`), a corrupt/failed load (`1025-1028`), or
the cap (`1002-1004`) `continue`s or returns without advancing the slot. Every
module after the skipped one therefore lands one slot lower than its plan
index. The install loop then either (a) checks `hook_present` on, and binds the
claim to, the *wrong* live module when the plan slot still happens to be
`< self.n`, or (b) binds a claim to a slot `>= self.n`, which `claimSlot`
(`wasm.zig:1394`) rejects forever, silently voiding the claim (the point then
falls through to the ordinary loop, so a gate the operator installed stops
gating). Both are spatial-composability violations: the binding names a
provider that never declared it. Reachable whenever one discovered mod fails
to load before a later claimant; no test covers a skipped load plus a claim
(the claim tests at `wasm.zig:2541-2657` poke the table directly, and
`loadResolved` scenario tests load every module). Fix: map plan slot to
loaded slot and translate at install.

**F8 (P2, open) - a reload bypasses the fail-closed declaration probe.** At
boot, `loadResolved` sets `ctx.require_declaration = true` before each
`loadInto` (`wasm.zig:1021-1024`), so a discovered mod that exports hooks but
has no `_zdtd_requires` is refused (`probeRequires`, `wasm.zig:328-335`).
`reload` calls `loadInto` directly (`wasm.zig:1196`) without setting the flag;
after boot the flag is restored to false (`wasm.zig:1024`), so a manifest-backed
slot (`manifest_loaded`, which the reload path otherwise trusts) is reinstantiated
through the permissive raw path. A module replaced on disk with one that dropped
its declaration loads on `plugin reload` where a restart would reject it: the
declarative-dependency check is a boot-only gate, and HMR is a documented way to
swap the module. Fix: force `ctx.require_declaration` (or pass the flag into
`loadInto`) for `manifest_loaded` slots.

**F9 (P2, open) - `reconcileClaims` accepts a manifest that failed validation
and drops the module's own deny.** `reconcileClaims` zeroes `module_deny`
before it binds the on-disk manifest (`wasm.zig:1238`), then returns early
when `manifest.bindManifest` fails (`1241`, which includes a failed
`validate()`, `manifest.zig:315-317`). The reload still succeeds and
`on_enable` runs, with `module_deny` left at 0: the module's declared queued-verb
restriction is silently lifted (fail-open) and the invalid manifest is tolerated
until the next restart, where `loadResolved`/discovery would refuse it. Fix:
capture the old mask, only reset it after a successful bind, and refuse the
reload (or keep the prior declaration) on a bind failure.

**F10 (P3, open) - `deny = "spawn"` does not deny `bot spawn`.** Interception
matches only the first token against `QueueVerb` (`wasm_host.zig:127-129`),
whose vocabulary has a single coarse `bot` entry (`manifest.zig:38-44`).
`bot spawn` therefore parses as `bot`: a module or operator mask denying
`spawn` leaves `g.bots.handleCommand` (`wasm_host.zig:104`) free to create a
host bot and reach `BotManager`. The F4 note above ("a denied verb cannot ...
spawn an entity") holds per verb *name*, not per effect; conversely
`deny = "bot"` does not deny ECS `spawn`. Fix: when the first token is `bot`,
map the sub-verb onto the corresponding top-level bit (`bot spawn` honors the
`spawn` bit, `bot remove` the `despawn` bit), or add explicit `bot.*` verbs to
the declared vocabulary.

**F11 (P3, open) - reload re-reads the manifest but not `config.toml`.**
`reload` preserves `config_bytes` by copying the old slot value
(`wasm.zig:1174-1177`, reassigned `1207`), while the sibling declaration in
`manifest.toml` is re-read from disk (F2). A module whose `config.toml` changed
on disk keeps serving the stale bytes through `zdtd.config` after
`plugin reload`, which is the HMR case the reload exists for. Fix: when
`manifest_loaded`, re-read the config alongside `reconcileClaims` (the binder
already returns `m.config`, `manifest.zig:323-328`).

## OK-verified

Re-traced 2026-09-12 against the current tree (read-only, no gates run).

- Vocabulary sync (prompt check 3): `host_verbs` (10 entries) and the
  `defineFuncCtx` import list (10) are the same set; `Hook` (24 variants) and
  `Hook.names` (24) agree. No host import is undeclarable, no hook is
  unnameable. A new import missing from `host_verbs` would be undeclarable;
  the two lists are single-sourced by the `wasm.zig:2758` test.
- Reload (prompt check 1): `on_shutdown` -> withdraw -> deinit -> `loadInto` ->
  `on_enable`; the module name is duped before `deinit` (`wasm.zig:1154`);
  `rt_slot`/`plugin_slot` re-pointed; display/config/tier copied before
  `deinit` frees them and freed on the failure path; a failed reload drops the
  disposed slot and re-points the moved modules' backlinks and claims. The two
  caveats are F8 (declaration probe) and F11 (config bytes).
- Withdrawal (prompt check 2): `World.pre_drain_fn` runs `takeWithdrawn`
  immediately before the drain (`src/ecs/world.zig:2033`), once per disable;
  `CommandBuffer.dropFrom` drops pending ops and hands back applied spawns,
  `withdrawPluginSrc` despawns them with `NetPackageEntityRemove`, clears
  `glide_src` matches, reports irreversible residue once
  (`plugin_effects_not_reverted`), and calls `bots.dropFrom`; the per-op
  `SrcGate` (`command.zig:230-239`, `drainWith`) covers mid-drain traps. Slot
  compaction remaps pending-op, spawn-ring and residue srcs
  (`shiftSrcsAfter`).
- Boundary (prompt check 4): the plugin path cannot emit wire or mutate the
  ECS directly; mutation is a queued command the owner drains, and discretionary
  outcomes are verdict hooks. `zdtd.queue` fails closed (returns 1) when the
  caller's runtime is not in `rt_slot`, so an unattributable op is dropped
  rather than run as native (`wasm.zig:1641-1643`).

## Follow-ups

Open: F5 (provider ordering, moot until plugins provide keys), F7 (P1, boot
claim slot mapping), F8/F9 (P2, reload fail-closed), F10/F11 (P3, deny
granularity and config re-read). F1, F2, F3, F4 and F6 are fixed and gated by
the scenarios and unit tests named above.
