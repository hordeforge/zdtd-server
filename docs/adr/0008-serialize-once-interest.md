# ADR 0008: Serialize-once interest fan-out

- **Status:** accepted
- **Date:** 2026-08-04

## Context

Stock V3.x measured walls show ConnectionManager / entity distribution scaling
roughly O(N²) with players: rebuild or re-serialize the same entity state per
connection. zdtd's scale goal (64–256 players, loadgen) cannot copy that shape.
Dirty-gated motion already exists on stock for some packages; the remaining tax
is per-connection re-encode of identical bytes.

## Decision

1. **Encode entity/package bodies once per tick (or dirty pass)** into a shared
   buffer, then **frame/scatter** the same payload to each interested peer
   (memcpy / LiteNet send), not re-run builders per connection.
2. **Interest is spatial** (`ecs/interest.zig` cell grid + radius) plus per-client
   known-entity sets for first-entry spawn.
3. **Dirty bits** (`components.Dirty`) gate pos/rot/spawn/flags; clear after the
   serialize-once pass. Heartbeat PosAndRot when clean (named period).
4. **No self-echo** of a player's own movement packages unless stock requires it.
5. Stream queues (chunks, deco) use **named caps** so one peer cannot stall the
   50 ms tick.

## Consequences

- Hot path stays single-threaded for game rules; workers only feed ops/results
  into tick-owned state (see ADR 0002, 0006).
- Interest bugs show up as missing entities for some peers, not wrong wire shapes.
- Further scale (chunk stream workers, larger caps) plugs into the same model;
  do not introduce per-peer entity rebuild loops.

## Alternatives considered

| Option | Notes |
|---|---|
| Per-peer full entity rebuild (stock-like) | Hits measured O(N²) wall |
| Event-sourced net log | Over-design for Goal A wire fidelity |
| Continuous full-state snapshot | Bandwidth waste; stock is delta-oriented |
