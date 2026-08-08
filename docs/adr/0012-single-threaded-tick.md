# ADR 0012: Single-threaded game tick (20 TPS) with bounded parallel helpers

- **Status:** accepted
- **Date:** 2026-08-04

## Context

Stock V3.x dedi and client expect a ~20 Hz sim cadence. zdtd targets **20 TPS
(50 ms)** as the hard budget for net + sim + interest + chunk stream on one
process. Multi-threaded apply of shared world state (blocks, join SM, entity
spawn) races authority and makes seed-stable tests and RE-aligned ordering hard.

Some work (zombie AI, turrets, dirty chunk disk flush) is data-parallel over
dense slots or chunk lists and can use workers **without** moving ownership of
world authority off the tick thread.

## Decision

1. **Main game rules are single-threaded:** join SM, C2S apply, interest
   serialize-once, chunk stream encode, block store mutation, package send
   scheduling. One owner of sim + world store per tick.
2. **Budget:** design and validate for **50 ms** wall time per tick; named caps
   on stream queues; no unbounded work per peer.
3. **Hot path: no heap allocation** (reuse body/recv/send buffers, fixed client
   slots, SoA columns, pools). Cap → drop/omit, never realloc on tick.
4. **Parallelism only via `util/parallel`** range-split for known safe domains
   (AI, turrets, chunk **save** I/O temps). Workers write private slots or use
   deferred atomic damage apply; they do not own join or package ids.
5. **Do not** introduce a second tick thread, actor-per-chunk world, or
   lock-free block store until scale gates prove the single-threaded owner is
   the bottleneck (see SCALE / M11).

## Consequences

- Reasoning about authority and phase order stays simple (ADR 0004, 0008).
- Scale path is interest + caps + optional workers at the edges, not a full
  multi-threaded ECS rewrite (ADR 0002).
- Long map load / XML parse stay off tick (init/cache only).

## Alternatives considered

| Option | Notes |
|---|---|
| Fully multi-threaded sim apply | High race/complexity cost; stock fidelity harder |
| Async event-loop only (no fixed TPS) | Breaks client expectation and loadgen TPS gates |
| Per-chunk actors | Premature; wrong for shared interest and join SM |
