# ADR 0001: Record architecture decisions

- **Status:** accepted
- **Date:** 2026-07-22

## Context

zdtd has many irreversible choices (wire fidelity, ECS shape, no mod host,
authority model). Chat and scattered docs lose the *why*. New contributors
re-litigate settled tradeoffs.

## Decision

Use lightweight ADRs under `docs/adr/`:

- Numbered `NNNN-kebab-title.md`
- Sections: Status, Context, Decision, Consequences (and Alternatives when useful)
- Index in `docs/adr/README.md`
- Supersede by new ADR; do not silently rewrite history

## Consequences

- Stable place for “why not Flecs / Harmony / client fakes”
- Slight doc overhead; keep each ADR short (one decision)
