# ADR 0004: Server-authoritative C2S apply

- **Status:** accepted
- **Date:** 2026-07-22

## Context

Clients send positions, damage, inventory, and block edits. Trusting blobs
enables dupes, speed hacks, and desync. Stock wire still requires correct S2C
shapes; authority is about *who decides state*, not inventing packages.

## Decision

- Sim owns world, inv, TE, HP, quests, locks, time.
- C2S is validate → apply or reject → broadcast **result**.
- Phase gates, bounds, ownership, and rate limits sit on the apply path.
- Prefer missing feature over fake S2C; never teach clients to invent world data.

## Consequences

- Join/play bugs are fixed in zdtd, not client mods (workspace rule 10).
- Plugin hooks (ADR 0005) observe or vote on requests; they do not bypass
  validation or write raw wire without builders.
- Aligns with native guard work (TODO P4).
