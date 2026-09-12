# Plugin composability review against the Cordis paper

**Run:** 2026-09-12 (round 23 review)
**Paper:** *A Programming Paradigm for Spatiotemporal Composability*,
Shi / Zhang / Cui (Peking University, DeepSeek-AI), arXiv:2608.25512v1,
submitted 2026-08-26, 92 pages. The `cordiverse/paper` repository's
`paper.pdf` path named in the objective no longer exists: the repo now holds a
README that points at arXiv (commit "read the paper on arxiv", 2026-08-26), so
this review is pinned to the arXiv v1 PDF.
**Prompt:** [prompts/plugin-composability-review.md](../prompts/plugin-composability-review.md).
**Verdict:** the three properties zdtd adopted (ADR 0030) are realized; one
P1 gap found in how a coeffect binding is released, fixed here; three P2/P3
gaps recorded with realization sketches.

## Mechanism map

| Paper mechanism | zdtd realization | Status |
|---|---|---|
| 3.1 revertible effects (`track`, `recover`, LIFO inverse accumulator) | `zdtd.queue` verbs carry a 1-based plugin src; `CommandBuffer.dropFrom` + `Game.withdrawPluginSrc` drop pending ops, despawn applied spawns, clear applied glide, drop bots | **Partial**: the inverse exists per verb class, but is classified only in prose (F3) |
| 3.1.2-3 effect functions / iterators, step-boundary interruption | Each hook call is a unit; a trap or fuel exhaustion disables the module mid-turn and the withdrawal pass runs before the drain | **Realized** for the host-driven unit granularity |
| 3.2.1-2 coeffect context, satisfaction, `notify` | `_zdtd_requires` is the specification; load rejects a module that cannot satisfy it (fail-closed), so a loaded module never reads an absent binding | **Realized** as a load-time check; no runtime `notify` (no host capability changes at runtime) |
| 3.2.2 provider ordering / withdrawal before dependents | `WasmHost.claimSlot` (this run) resolves an exclusive point claim against the claimant's liveness; a disabled or hook-less claimant stops providing | **Fixed here** (F1); the general provider-drain ordering has no analogue because dependencies are host-only (F5) |
| 3.2.3 isolation (`ctx.isolate`) | each module has its own instance, memory and config bytes; no realm table for shared keys | **N/A today**: no two modules share a dependency key with different bindings |
| 3.2.3 interception (`ctx.intercept`, right-biased metadata) | none: host budget and MCP allowlist are host-fixed, not context-carried metadata a component's own declaration merges with | **Missing** (F4, ADR-worthy) |
| 5.1.1 `ctx.effect` single mutation primitive | every plugin affordance that mutates the world is a queued command; direct ECS/wire mutation is absent | **Realized** (boundary), with the witness unverified exactly as the paper says a host may leave it |
| 5.1.2 coeffect operations / 5.1.4 context access | `zdtd.config` (per-module bytes), `zdtd.sense`/`zdtd.query` read-only views; no `ctx[key]` reflection | **Realized in spirit**: capabilities are imports, not a reflective table |
| 5.1.3 component lifecycle (inertial load/unload, reload chaining) | `Plugin.load` -> `on_enable`; `on_shutdown` -> withdraw -> deinit -> `loadInto` -> `on_enable`; a failed reload drops the slot and re-points backlinks and claims | **Realized** for the single-instance case |
| 5.2.1 declarative configuration reconciliation | `manifest.toml` + resolver plan (tiers, `override`, point claims) builds the composition at boot; `[mods] enabled/disabled` is boot-time | **Partial**: no reconcile pass; reload re-reads the wasm but not the manifest (F2) |
| 5.2.2 hot module replacement | `plugin reload <name>`: dispose and reinstantiate in place, budget re-armed, config/display/tier preserved | **Realized** |
| 6.5 mutual dependencies / granularity | dependencies name host capabilities only, so a cycle cannot form; the resolver already reports duplicate point claims at load | **N/A today**; cycle reporting from declarations is the check to add if plugins ever provide keys |
| 6.6 dependency typing/versioning | `_zdtd_requires` links by hook/verb *name* only; the host never negotiates a contract version with the guest | **Partial** (F6) |

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

**F2 (P2, open) - reload re-reads the module, not its declaration.** `reload`
calls `loadInto` with the slot's path and preserves tier/display/config, but
the claim table is only built by `loadResolved` at boot. A module replaced on
disk that drops its `points` claim keeps exclusivity while it is active (F1's
hook check only catches a dropped hook), and one that adds a claim never gets
it. Paper 5.2.1/5.2.2 reconciles the declarative configuration, not just the
code. Realization sketch: store the claimed points on `Plugin` at install and
re-install them in `reload` (refusing a claim whose hook the new module does
not export), or route reload through the resolver for the module's directory.

**F3 (P2, open) - the inverse classification is prose, not a checked table.**
`Op` has five verbs: `spawn_zombie` and `glide` are revertible (despawn, clear
flag); `damage`, `say` and `despawn` are applied effects with no inverse, which
is a legitimate boundary decision (paper 6.1 delimits the author obligation;
5.1.1 notes the runtime never verifies the witness) but is recorded only in
comments. The review prompt's rule ("no new side-effect verb without a
withdrawal story") is therefore unenforced. Realization sketch: a
comptime-exhaustive `verbInverse(Op) Inverse` classification used by the
withdrawal path and an apm counter for effects a withdrawal could not revert,
so a new verb cannot land without a decision and operators can see the residue.

**F4 (P2, ADR-worthy) - no interception or isolation.** The paper's 3.2.3
`intercept` (context-carried metadata merged with the component's declaration,
right-biased so the enclosing context wins) has no counterpart: plugin
affordances are constrained by host constants (budget) and a fixed MCP
allowlist, not by an operator-declared policy a module's own manifest merges
with. This is also the objective's "everything configurable, nothing
hardcoded" gap. Realization sketch: a per-plugin policy table in `zdtd.toml`
(deny/scale per verb) applied at the `zdtd.queue` boundary as context metadata,
with the operator side right-biased over the module's `manifest.toml`
declaration; extend the boundary deliberately per AGENTS rule 30 rather than
growing native behavior.

**F5 (P3, open, recorded difference) - no inertial provider ordering.** The
paper drains a provider's dependents before running its inverses; zdtd has no
plugin-to-plugin bindings (requirements name host capabilities only), so the
case cannot arise. Recorded so a future plugin-provided key is designed with
the ordering from the start.

**F6 (P2, open) - the dependency link is nominal with no contract version.**
Paper 6.6 names the two failure modes of name-only linking: interface drift and
key collision. zdtd links by hook/verb name and validates the *set*
(`_zdtd_requires`), but no guest export carries the contract version, so a
module built against an older or newer hook surface is accepted whenever its
names still match. An arity change fails closed today (the wasm call type
check traps and the module is disabled), but a same-signature semantic change
is silent, and `docs/PLUGIN_API.md` already claims `plugin_api_version` "names
the guest contract" without anything reading it. Realization sketch: accept an
optional `_zdtd_api` export returning the contract version; reject a module
newer than the host's (fail-closed, like an unmet `_zdtd_requires`), accept and
log an older one, and leave modules without the export on the current
permissive path. Key collision does not arise: the vocabulary is a fixed host
table, not an open key space.

## OK-verified

- Vocabulary sync (prompt check 3): `host_verbs` (10 entries) and the
  `defineFuncCtx` import list (10) are the same set; `Hook` (24 variants) and
  `Hook.names` (24) agree. No host import is undeclarable, no hook is
  unnameable.
- Reload (prompt check 1): `on_shutdown` -> withdraw -> deinit -> `loadInto` ->
  `on_enable`; `rt_slot`/`plugin_slot` re-pointed; display/config/tier copied
  before `deinit` frees them and freed on the failure path; a failed reload
  drops the disposed slot and re-points the moved modules' backlinks and
  claims.
- Withdrawal (prompt check 2): `World.pre_drain_fn` runs `takeWithdrawn`
  immediately before the drain, once per disable; pending ops are dropped,
  applied spawns despawned with `NetPackageEntityRemove`, glide cleared, bots
  dropped; slot compaction remaps srcs.
- Boundary (prompt check 4): the plugin path cannot emit wire or mutate the
  ECS directly; mutation is a queued command the owner drains, and discretionary
  outcomes are verdict hooks.

## Follow-ups

F2 (claim re-resolution on reload), F3 (checked inverse table), F4
(interception policy, needs an ADR), F5 (provider ordering, moot until plugins
provide keys) and F6 (contract version export) are the next slices. F1 is fixed
and gated by the scenario above.
