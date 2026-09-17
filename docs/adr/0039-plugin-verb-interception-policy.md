# ADR 0039: Plugin queued-verb interception policy (operator over module manifest)

- **Status:** accepted
- **Date:** 2026-09-12
- **Related:** ADR 0020 (Wasm-only plugin API), ADR 0021 (config-driven rules),
  ADR 0030 (plugin composability; review findings F3/F4), ADR 0032 (mod
  manifests), Cordis paper 3.2.3 (`ctx.intercept`), AGENTS rule 29/30

## Context

The Cordis paper's interception mechanism (3.2.3) lets a component read
metadata that its enclosing context has merged with its own declaration,
right-biased so the enclosing context wins. zdtd had no counterpart: the plugin
boundary's queued verbs (`spawn`, `despawn`, `damage`, `say`, `glide`, and the
host-handled `bot` family) were all-or-nothing. A module either loaded and could
issue every verb, or was not loaded at all. Operators could pick which modules
load (`[mods] enabled/disabled`, `[plugin] modules`) but could not say "this
module may not broadcast chat" while another module may, which is exactly the
paper's example of context-carried policy. The composability review recorded
this as F4 (P2, ADR-worthy) and it is the objective's "everything configurable,
nothing hardcoded" gap.

Options considered:

1. **Native allow-list per verb in code.** Rejected: hardcodes policy, the
   thing the objective forbids, and gives the operator no say.
2. **Per-module keys in zdtd.toml** (`[plugin.policy.<name>]`). Rejected by the
   ADR 0021 binder: it walks flat `section`/`key = value` pairs with a
   fixed destination struct, so a dynamic key (a module name) cannot bind.
3. **Module manifest declares a deny list; the operator config merges over
   it.** Chosen. The declaration lives with the module (it is a statement
   about what the module does), the operator's lists live in the config the
   operator already owns, and the merge direction matches the paper.

## Decision

1. **One vocabulary, one mask.** `src/plugin/manifest.zig` owns `QueueVerb`
   (`spawn`, `despawn`, `damage`, `say`, `glide`, `bot`) and a u16 mask. The
   manifest's optional `deny = "say,damage"` declares verbs the module will not
   queue; `Manifest.validate` rejects an unknown verb loudly, so a typo cannot
   silently weaken the declaration.
2. **The operator is right-biased.** `zdtd.toml [plugin] deny` and `allow` are
   `module=verb,verb; module2=verb` lists parsed once at boot in `main.zig`
   (a bad entry or unknown verb is a fatal startup error). The effective mask
   is `(module_deny | operator_deny) & ~operator_allow`: the operator can both
   tighten and relax a module's own declaration, and the operator side is
   applied last.
3. **Enforced at the `zdtd.queue` boundary, before anything runs.**
   `wasm_host.pluginVerbDenied` gates `wasmQueue` ahead of the ECS command
   parse and the host `bot` family, so a denied verb cannot land in the buffer,
   spawn an entity, or reach `BotManager`. Drops increment
   `plugin_verbs_denied` in the APM dump and are logged rate-limited. Native
   sources (`src <= 0`) are not policy subjects: the policy is about module
   composition, not about the server's own behavior.
4. **Reload re-reads the declaration, keeps the operator.** `plugin reload`
   already re-reads `manifest.toml` (ADR 0030 F2); it now also recomputes
   `module_deny` from it and recombines with the stored operator masks, so HMR
   cannot wash the operator's policy away or freeze a stale module deny.

The policy table is fixed-size (`max_policy_entries` = 32, no allocation) and
matched by manifest name, wasm file stem, or mod directory name, so a legacy
`[plugin] modules` path can be named either way. The running policy is logged
once per module at boot (`mod '<name>' verb policy: denied=[...]`) so an
operator can audit what the server actually enforced.

## Consequences

- A module can be admitted for one behavior and refused another, per operator
  policy, without a code change: the first concrete interception surface on the
  plugin boundary.
- The boundary now has a verb vocabulary that both the module declaration and
  the operator config must agree on. Adding a queued verb means adding it to
  `QueueVerb` (one place) and classifying its inverse in `ecs/command.zig`
  (already a compile error if missed).
- Denying `say`/`spawn`/`bot` costs the module that affordance entirely, with
  no mid-verb parameter rewriting or rate limiting: the paper's model is
  allow/deny metadata, and a scaled/parameterized policy would need a richer
  merge than a bitmask. If that is wanted later, the mask generalizes to a
  per-verb value without changing the enforcement point.
- The operator lists are boot-time (the binder and resolver are boot-time
  today); changing policy takes a restart. Live policy reload would be a
  follow-up on top of this enforcement point, not a redesign of it.
- The C fixtures and any module without a `deny` key are unaffected
  (`module_deny = 0`); a module that never queued a verb pays one bitmask test
  per queued command.

---
Register the ADR in [README.md](README.md). Statuses are **accepted**,
**superseded**, **deprecated**. A decision still being made is an RFC, not a
proposed ADR; a later reversal supersedes this record - never edit the
decision out of it.
