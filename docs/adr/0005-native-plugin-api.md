# ADR 0005: Native plugin API (not stock mods)

- **Status:** proposed
- **Date:** 2026-07-22

## Context

Operators and in-tree features want extension points: custom admin commands,
loot tables hooks, join gates, analytics, minigame rules, without forking
`game.zig`. Stock IModApi is out (ADR 0003). A careless plugin surface can:

- break stock wire or tick budget,
- bypass authority (ADR 0004),
- allocate on the hot path,
- depend on unstable `Game` internals.

## Decision

1. **Native only:** Zig static plugins first; optional versioned dynamic
   libraries later. No C# / Harmony.
2. **Capability-based hooks:** plugins register for named events; they receive
   **views** (read-only or narrow mut), not raw `*Game`.
3. **Authority preserved:** plugins may *deny* or *adjust* requests the core
   already understands; they may not inject arbitrary package bytes or skip
   join SM. New package types require core wire support.
4. **Determinism default:** sim hooks run on the main tick thread in documented
   order; no hidden plugin threads touching sim.
5. **Fail closed / isolate:** plugin errors are caught at the boundary; one
   plugin fault disables that plugin (or that hook), not the process, when
   practical.
6. **Design doc** [PLUGIN_API.md](../PLUGIN_API.md) is the working spec; this
   ADR accepts the direction. Implementation is gated on playability polish
   (P0 closed) and follows PLUGIN_API.md + TODO open list.

## Consequences

### Positive

- Extension without mono/mod stack
- Clear hook list for guard, admin, events, analytics
- Testable with fake plugins in scenarios

### Negative / costs

- ABI and version discipline if dynlib lands
- Every new hook is an API promise (keep the set small)
- Risk of “mod host creep”; non-goals must stay enforced

## Alternatives considered

| Option | Notes |
|---|---|
| No plugins; fork only | Simple; blocks shared tooling and optional features |
| Stock IModApi shim | Rejected ADR 0003 |
| Scripting (Lua/WASM) | Possible later guest; not v1; still needs same hooks |
| Unrestricted `*Game` dll | Too much surface; authority and tick safety fail |
