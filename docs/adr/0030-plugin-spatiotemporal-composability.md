# ADR 0030: Plugin spatiotemporal composability: reload, effect withdrawal, declarative dependencies

- **Status:** accepted
- **Date:** 2026-08-20
- **Related:** [ADR 0020](0020-wasm-only-plugin-api.md) (Wasm is the only
  plugin format), [ADR 0026](0026-fps-bot-wasm-module.md) (bot brains are
  Wasm), AGENTS.md rule 30 (the standing rule), `docs/prompts/plugin-composability-review.md`
  (the review gate).

## Context

zdtd hosts sandboxed wasm32 modules behind the `zdtd.sense` / `zdtd.queue` /
`zdtd.query` boundary. The prior model treated plugins as load-once,
die-on-trap components: a module that trapped stayed disabled until the
server restarted, its queued-but-undrained commands still executed, and a
typo'd hook name failed silently (never fired). We adopted three properties
from "A Programming Paradigm for Spatiotemporal Composability" (Shi, Zhang,
Cui — Peking Univ / DeepSeek-AI; the Cordis meta-framework) to make plugins
safe runtime components:

- **Temporal composability** (paper §3.1, revertible effects): every effect a
  component makes carries an inverse; the runtime tracks and reverts them on
  removal.
- **Spatial composability** (paper §3.2, reactive coeffects): components
  declare the context they depend on and fail-closed when it is unavailable.
- **Hot module replacement** (paper §5.2.2): dispose the old fiber and
  reinstantiate from the reloaded module, no acceptance boundaries needed.

## Decision

1. **Reloadable (HMR).** Admin `plugin list` / `plugin reload <name>` disposes
   a slot (`on_shutdown`, deinit, fuel/memory reclaimed), re-reads the module
   from disk, re-arms the budget and re-activates (`on_enable`). `WasmHost`
   stores its load ctx/budget; `reload` copies the module path before `deinit`
   frees it. A failed reload leaves the slot empty and reports loudly.
2. **Revertible effects.** Every `zdtd.queue` command is attributed to its
   plugin: the queue import resolves the caller's runtime against
   `HostCtx.rt_slot` and hands a 1-based src to the owner; `CommandBuffer`
   carries per-op srcs (`pushSrc`/`dropFrom`); the Game withdraws a
   disabled/trapped module's still-pending commands before the drain
   (`WasmHost.takeWithdrawn`, once per disable). No new queued effect verb may
   bypass attribution.
   Amended 2026-08-28 (paper 3.1 held inverse): the buffer also records each
   applied spawn per src, and withdrawal (self-disable and admin reload)
   despawns those entities, so a module's spawned zombies do not outlive it.
   The spawn ring is capped at `max_commands`, dropping the oldest attribution
   when full (the most recent spawns stay revertible).
3. **Declarative dependencies.** Modules export `_zdtd_requires` returning a
   comma-separated capability list (hook names + `log`/`tick`/`queue`/
   `sense`/`query`). Unknown or un-exported capabilities reject the module at
   load with a loud error (fail-closed); the vocabulary stays in sync with
   `Hook.names` and the host import table.
4. **Boundary stays the boundary.** Plugins still mutate the sim only through
   the verbs the server understands; composability is host-side plumbing, not
   a widening of plugin authority. `plugin` remains a leaf package (no ecs
   import); the withdrawal crosses the boundary as srcs the Game applies.

## Consequences

- Operators can iterate on policy modules (bots, gates, feeds) without a
  server restart; a broken module cannot leave side effects behind.
- Modules carry their dependency contract with them; load failures are loud.
- Review gate: `docs/prompts/plugin-composability-review.md`; the invariant
  is also AGENTS.md rule 30.
- Not adopted: the paper's full fiber/provision calculus and dependency
  typing/versioning (§6.6) — overkill for a fixed hook table; revisited only
  if plugins gain mutual provisioning.
