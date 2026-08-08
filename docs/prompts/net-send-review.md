# Agent prompt: net / send-path review (zdtd)

Your goal is to find code that fights the reliable-send rules: WindowFull retry
semantics, join-critical delivery, the shared retry shape, LiteNet capture
mode, compression fallthrough and send-phase gating.

Copy everything below the line into a fresh agent session (or `@` this file).

---

## Role

You are reviewing and optionally fixing **the network send path** in **zdtd**
(`/home/maci/Desktop/7dtd/zdtd`): a clean-room Zig 0.16 dedicated server for
the stock 7DTD client wire.

Your job is a **correctness / robustness review of every reliable send**, then
a **prioritized fix list** (and optional patches).

This is **not** the wire-layout review (golden tests own those bytes), **not**
the join-SM phase review, **not** the idiomatic-Zig review
(`zig-idiomatic-review.md`). Focus on: which packages are droppable vs
must-deliver, how WindowFull is retried, how the enter bundle is sequenced, and
whether a wedged peer can stall the 50 ms tick.

## Read first

| Doc | Why |
|---|---|
| `AGENTS.md` — "Gotchas (hard-won)" first block | The join-critical / retry-shape rules |
| `src/server/game.zig` — `sendGame`, `sendGameBudget`, `sendGameCritical`, `sendReliablePumped`, `sendFramedReliable`, `isDroppablePackage`, `isUnreliablePackage` | The send surface |
| `src/server/chunk_stream.zig` — `sendFramedDroppable`, `sendSpawnChunk`, `streamChunksForClient` | The stream surface |
| `src/litenet/peer.zig` — `sendReliable`, `sendOneReliable`, `allocPending`, `resendPending`, `pump_fn` | The LiteNet window |
| `../7dtd-research/docs/protocol.md` — join sequence | What must arrive in order |

## Non-negotiable constraints

1. **Join-critical sends are not droppable.** IdMapping, WorldInfo,
   WorldSpawnPoints, WorldAreas, GameStats (the enter bundle) have no client
   retry. A silent drop wedges the client on the loading screen. These go
   through `sendGameCritical` / the critical framed path with the peer's shared
   budget; on exhaustion they return `error.WindowFull` — they never log-and-
   continue a bundle the client can never complete.
2. **One retry shape.** Every reliable-window retry goes through
   `sendReliablePumped` (budget/deadline/sleep/pump). A hand-rolled
   `while (attempts < …)` WindowFull loop is a defect — the budget/deadline/
   sleep asymmetry between copies is the drift that caused the join-bundle
   stall. Only the budget, max-attempts and counters differ between callers.
3. **Dead peer must not stall the tick.** The retry budget is bounded
   (16 ms normal, 3 s critical shared); a truly dead peer fails fast and is
   reaped at `peer_stale_ms`. A retry loop that can run unbounded is a defect.
4. **Capture peers never WindowFull.** LiteNet capture mode frees the slot
   immediately (`sendOneReliableOnChannel`), so scenario tests must not see
   window pressure. A capture-mode WindowFull means the send path is broken.
5. **No second encoder / no fabricated fallbacks.** A package that cannot be
   built correctly is omitted or sent in its stock empty form — never
   truncated, zero-padded or replaced with a fake body.
6. **Hot path:** the send path runs on the tick. No heap allocation, no growing
   lists; bodies live in `body_buf` / `send_buf`; a drop is a named-counter
   event, not a stall.

## Review checklist

- [ ] Every send classified: droppable (stream/replaceable) vs must-deliver
      (join-critical). `isDroppablePackage` is the canonical list; anything not
      in it must not be silently dropped.
- [ ] All retry loops route through `sendReliablePumped`; no copy-pasted
      WindowFull loop anywhere (grep `while (attempts`).
- [ ] Critical sends share the peer budget (`critical_budget_deadline_ns`) so
      the whole enter bundle gets one window of retry, not one per package, and
      a dead peer stalls at most once per join.
- [ ] The enter bundle orders correctly (IdMapping → configs → WorldInfo →
      SpawnPoints → Areas → WorldTime → GameStats → deco) and a critical
      failure aborts rather than continuing.
- [ ] The drop path increments `reliable_window_drops` and logs rate-limited;
      critical drops return `error.WindowFull`.
- [ ] Compression (`trySendCompressed` for Chunk / SignDataResponse) falls
      through to the uncompressed frame on any overflow — never truncates.
- [ ] Motion packages use the unreliable fast path (single datagram) and never
      enter the reliable window.
- [ ] Capture-mode peers (scenarios) never hit WindowFull; a capture send
      succeeds on attempt 1.
- [ ] Poll/ACK pumping inside retry is reentrancy-safe (`pumpAcks` /
      `pollNetOnce` control-only drain mid-onData).
- [ ] A stuck window cannot stall the tick: every retry path has a deadline or
      a hard attempt cap; the reap clears the peer.
- [ ] apm counters exist for new send costs (net_packets_out, net_bytes_out,
      net_send_errors, reliable_window_drops).
- [ ] Joining a capture client in a scenario asserts the join bundle arrived
      (IdMapping + WorldInfo), so a regression shows as a test failure, not a
      wedged client.

## Deliverables

1. Findings list, each with: file:line, the violated rule, the concrete
   failure mode (client wedged / tick stalled / counter drift), severity.
2. Prioritized fix list (must-deliver first).
3. Optional patches; re-run `zig build test` and a loadgen join smoke
   (`scripts/smoke-*.sh` or the loadgen instructions in AGENTS.md) for any
   changed send path.
