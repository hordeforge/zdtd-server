# ADR 0019: Validation triad (loadgen + stock client + zdtd apm)

- **Status:** accepted
- **Date:** 2026-08-05
- **Related:** [STATUS.md](../STATUS.md), [APM.md](../APM.md), [CLIENT_PLAYTEST.md](../CLIENT_PLAYTEST.md)

## Context

zdtd is a clean-room stock-client wire server. Unit tests catch layout and
logic regressions but cannot prove join/mesh/CGO, interest under multi-peer
load, or 50 ms tick budget. Sibling tooling (loadgen, stock client EAC off,
playtest harness) and native `src/apm/` exist for that. **7dtd-apm** targets
the stock Mono dedi process and is the wrong probe for this binary.

## Decision

1. **Three validation legs** for join/spawn/chunk/inv/play surface changes when
   practical:
   - **Unit / scenario:** `zig build test` (and `make check` for release gates).
   - **Loadgen:** multi-bot join/walk/actions against a live zdtd port.
   - **Stock client (EAC off):** mesh/CGO/terrain/UI evidence (manual or
     `7dtd-playtest` automation).
2. **Metrics:** instrument and judge regressions with **zdtd `src/apm/`** dumps
   (and WebUI snapshot when enabled). **Do not** require or wire 7dtd-apm.
3. **Unit green alone is not enough** for playability claims; STATUS gates list
   which leg closed the claim.
4. **Server owns gaps:** playtest/client harness must not invent S2C world data
   or skip server-driven steps to paper over missing wire/sim.

## Consequences

- CI stays unit-centric; soak/playtest may be operator/manual or sibling CI.
- Feature PRs that only add unit tests for join/chunk paths are incomplete
  evidence until loadgen/client smoke when practical.
- APM surface grows with hot paths; no Mono bridge in-process.

## Alternatives considered

| Option | Notes |
|---|---|
| Unit tests only | Misses CGO, LiteNet timing, multi-peer interest |
| 7dtd-apm on zdtd | Wrong process model; stock Mono bridge |
| Client-only golden without loadgen | Weak multi-peer and automated soak |
| Invent client fakes for missing S2C | Violates missing-beats-fake / server-owns-gaps |
