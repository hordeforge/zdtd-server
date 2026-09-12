# Net / send-path review snapshot - 2026-09-12

## Scope

| | |
|---|---|
| Repo | `zdtd-server` (working tree root, clean-room Zig dedi) |
| Mode | **Review only** (no source edits; one file written: this snapshot) |
| Date | 2026-09-12 |
| Prompt | `docs/prompts/net-send-review.md` |
| Paths reviewed | `src/server/game/net.zig`, `src/server/game/send_extra.zig`, `src/server/game/chunk_stream.zig`, `src/server/game/chunk_fill.zig`, `src/server/game/map.zig`, `src/server/game/config_files.zig`, `src/server/game/join.zig`, `src/server/c2s/join.zig`, `src/server/game.zig` (IdMapping / `sendJoinBundle`), `src/litenet/peer.zig`, `src/litenet/server.zig`, `src/wire/frame.zig`, `src/server/scenarios.zig` (join-bundle scenario) |
| Method | read + ripgrep only; no `make check`, no `zig build`, no test suite (per session overrides). Every finding traced to the send call site; a grep hit alone was not accepted. |

Rule tags: **C1** join-critical is not droppable; **C2** one retry shape; **C3** a dead peer
must not stall the tick; **C4** capture peers never WindowFull; **C5** no second encoder /
no fabricated fallback; **C6** hot path, bounded. AGENTS critical rules 18-20 where noted.

## Findings

| Sev | path:line | Rule | Evidence / failure mode | Suggested fix |
|---|---|---|---|---|
| **P0** | `src/server/game/chunk_stream.zig:232-241` (`drainSpawnArea`), `:326-338` (`streamChunksForClient`), `src/server/game/chunk_fill.zig:167-174` | C3, C6, AGENTS 20 | The pacing budget is consumed only on a **successful** chunk send: `budget.* -= 1` (234) and `added += 1` (337) sit after the send. A send that fails (window full) still paid the full worldgen+encode (`chunk_fill.zig:39-166`) and the full 16 ms `window_retry_budget_ns` retry, then `continue`s with the budget untouched. A wedged peer therefore makes one tick attempt every remaining cell of the pending ring: `spawn_area_radius_max` 8 -> 288 cells, view stream r=12 -> up to 625 cells, at ~16 ms each: **multi-second tick stall** (sleepNs is a real nanosleep, `util/clock.zig:97-109`), not the "8 chunks per tick" the comments claim (`chunk_stream.zig:144-150`, `203-208`). | Consume the budget on the attempt, not on success; and/or have `sendSpawnChunk` report "window full" so the pass breaks instead of walking the ring. |
| **P1** | `src/server/game/send_extra.zig:59-63` vs `src/server/game/net.zig:71-80`; `src/server/game/join.zig:260` | C1, C5 | The comment promises "a droppable package (`NetPackageChunk`/**`SignDataResponse`** ride this compressed path) must not turn WindowFull into a hard error", but `isDroppablePackage` does not contain `NetPackageSignDataResponse`, so the guard is false and `error.WindowFull` propagates. Every non-last sign batch is sent with `sendGame` (`join.zig:260`), so one full window aborts `sendSignDataBatches` before `is_last=true`; the client's `worldInfoCo` then waits on `isLastBatch` **forever** ("Starting Game"). | Add `NetPackageSignDataResponse` to `isDroppablePackage` (it is replaceable: the final batch carries the flag), or drop a middle batch explicitly and keep the loop alive. |
| **P1** | only arm site `src/server/c2s/join.zig:251-252`; `src/server/game.zig:2625` (PlayerId), `:2775` -> `src/server/game/join.zig:402` (GameStats) | C3, AGENTS 18 | `sendJoinBundle` (the RequestToSpawnPlayer / respawn bundle, `c2s/join.zig:537` and fallback `:408`) is **not** wrapped in a shared `critical_budget_deadline_ns`, so each `sendGameCritical` in it re-arms its own 1 s (`net.zig:98-99`). A peer that stops ACKing stalls the tick ~1 s per critical package (~2 s per spawn bundle, more on client retries) instead of "at most once per join" as `peer.zig:159-163` documents. | Arm/clear the deadline around the spawn-bundle call sites exactly like `c2s/join.zig:251-252`. |
| **P1** | `src/server/game.zig:2277-2281`, `:2290-2297`, `:2298-2302` | C1, C5 | `sendBlockIdMapping` logs and `return`s (void) on frame-init, body-overflow and deflate failure, so `c2s/join.zig:262` continues the enter bundle without IdMapping; the client keeps its local block ids and every placed block is the wrong type for the session. This is the "enter bundle continues past a critical failure" pattern; the `!void` signature already exists but the build failures do not use it. | `return error.Overflow` / propagate the frame error instead of bare `return`, so the bundle aborts and is counted. |
| **P2** | `src/server/game/net.zig:171-175` -> `src/litenet/peer.zig:312-335` | C3 | `budget_ns == null` sets `peer.reliable_send_deadline_ns = 0`, which **disables** the only deadline the LiteNet fragment retry loop checks (`peer.zig:321`). The remaining cap is 400 000 attempts with a 2 ms sleep every 4 (`ack_yield_ns`, `peer.zig:37,329`) = ~200 s of tick stall. The doc says null is "for callers that already impose an outer deadline", but the outer deadline is invisible to `peer.zig`. No live caller passes null today. | Make null mean "single attempt" (or have the fragment loop take an explicit deadline), and assert non-zero in `sendReliablePumped`. |
| **P2** | `src/server/game/map.zig:99` then `:103-108` | C5 | `c.map_chunks_sent[idx] = 1` is set **before** the send, and MapChunks has no uncompressed fallback (`trySendCompressed`, `send_extra.zig:12-14`). A deflate failure or a WindowFull drop is swallowed (`_ =`, `catch false`) and the piece is never retried until the map middle moves: a permanent hole in the minimap. | Mark the piece sent only when the send succeeded; retry on the next tick otherwise. |
| **P2** | `src/server/game/net.zig:124`, `:203`, `:332` vs `src/litenet/peer.zig:255-256` | C5 | The unreliable/oversized guards compare to `ln_packet.max_single_user` (1428) while `sendUnreliable` enforces `min(max_single_user, peer_mtu - 4)`. On a peer that negotiated a lower MTU (`peer_mtu` is learned from MtuCheck, `peer.zig:186-190`) a framed message in between returns `error.Overflow`, is only counted in `net_send_errors`, and is dropped with no fallback to the reliable path (motion / stats-buff loss on low-MTU links). | Give `Peer` a `singleDatagramMax()` and use it at the three guards, falling through to the reliable path on Overflow. |
| **P2** | `src/server/game/net.zig:215-223`, `:297-305`, `:341-349` | C1, C2 | `broadcast*` soft-drops **every** WindowFull without consulting `isDroppablePackage` (counter + rate-limited log only). Today no must-deliver package is routed through `broadcast`, but the canonical list is not the gate it is documented to be, so the next one added there is silently droppable. | Route the decision through `isDroppablePackage` (or a `must_deliver` tag) instead of the unconditional drop. |
| **P3** | `src/litenet/peer.zig:274-277`, `:58-70` | C4 | Capture mode records the message before the send and truncates at 8192 B, so a send that then fails still appears "delivered" and any >8 KiB package (IdMapping, full chunk) is stored short. Scenario parses of truncated bodies can pass on invented bytes. | Record after a successful send; count/label truncation in `Capture.push`. |
| **P3** | `src/server/scenarios.zig:5832-5837` | C1 | The comment claims IdMapping's arrival is "enforced by the critical send abort semantics", but that aborts only if a WindowFull happens, and capture mode cannot produce one (`peer.zig:358-363`). The test asserts 6 packages and never IdMapping, so a genuine IdMapping regression with a free window is invisible. | Add a counter (`critical_sends_failed` / `id_mapping_sends`) and assert it in the scenario, or record large packages by reference. |
| **P3** | `src/server/game/net.zig:98-102`, `:144-151` vs `src/server/game/send_extra.zig:35-47` | C2 | The budget-arm + `retry_budget` computation (8 lines) is copied verbatim into both reliable senders; the "one retry shape" invariant is maintained by hand and can drift (the two differ only in the attempt ladder: 960 vs 4000/64). | Extract `armCriticalBudget` / `criticalRetryBudget` and call from both. |
| **P3** | `src/server/game/net_handlers.zig:33` | C2 | The challenge is sent with a raw `peer.sendReliable` outside `sendReliablePumped`, so a WindowFull is unretried and counted as `join_fail`. Benign in practice (empty window at connect, 17 B single datagram), but it is the one reliable send with no pump. | Send it through `sendGameBudget`/`sendReliablePumped`, or document why the raw path is safe. |
| **P3** | `src/server/game/types.zig:169`; `src/server/game/net.zig:138-139`; `src/server/c2s/join.zig:282` | C3, C1 | Drift notes: the shared critical budget is **1 s** (reduced from the 3 s the prompt still cites); the `NetPackageChunk` 4000-attempt arm is unreachable unless deflate fails (Chunk always takes the compressed path); `NetPackageDecoUpdate` (the bulk of the join burst) is not droppable, so a full window on the post-GameStats deco send hard-errors the whole enter handler. | Refresh the prompt/doc numbers; decide whether deco belongs in `isDroppablePackage`. |

## Prioritized fix list

1. **P0 - make a failed chunk send consume the pacing budget** (`chunk_stream.zig:232-241`, `:313-338`).
   Edit sketch: in `drainSpawnArea` move `budget.* -= 1;` above the `sendSpawnChunk` call (and keep
   `clientAddStreamed` on success only); in `streamChunksForClient` increment `added` for every
   attempted cell. Expected: ~6 changed lines. Optionally also make `sendSpawnChunk` return a
   distinguishable "window full" so the pass can `break` (another ~6 lines).
2. **P1 - classify `NetPackageSignDataResponse` as droppable** (`net.zig:71-80`).
   Edit sketch: add the name to the `names` array + one line to the comment. Expected: 2 lines.
   (Then `send_extra.zig:59-63`'s existing comment becomes true and a middle batch no longer aborts
   the join.)
3. **P1 - share one critical budget across the spawn bundle** (`c2s/join.zig:408` and `:537`).
   Edit sketch: before each `sendJoinBundle` call set
   `peer.critical_budget_deadline_ns = clock.monoNs() + game_mod.critical_retry_budget_ns;` with a
   `defer peer.critical_budget_deadline_ns = 0;`, mirroring `:251-252`. Expected: ~5 lines.
   Consider hoisting into `sendJoinBundle` itself for a single choke point (~4 lines there).
4. **P1 - fail closed on IdMapping build failure** (`game.zig:2277-2281`, `:2290-2297`, `:2298-2302`).
   Edit sketch: replace the three bare `return;` with `return err;` / `return error.Overflow;`
   (the function already returns `!void` and the caller uses `try`). Expected: ~4 lines.
5. **P2 - stop null budgets from disabling the fragment deadline** (`net.zig:171-175`,
   `peer.zig:312-335`). Edit sketch: either `std.debug.assert(budget_ns != null)` in
   `sendReliablePumped` and drop the `?u64`, or when null arm a single 50 ms attempt budget
   (`peer.reliable_send_deadline_ns = clock.monoNs() + window_retry_budget_ns`). Expected: ~6 lines.

Not fixed here (review-only mode): all other P2/P3 rows above, notably the MapChunks sent-marking
(`map.zig:99`), the broadcast classification gap, and the capture truncation.

## Could not verify

- No runtime evidence was produced: the session forbade `zig build`, `zig test`, `make check` and
  loadgen smoke, so the P0 stall magnitude (~16 ms per failed chunk x up to 288/625 cells) is a
  static timing derivation from `window_retry_budget_ns`, `sleepNs` and the ring sizes, not a
  measured tick stall.
- Whether the stock client re-sends `NetPackageSignDataRequest` after a partial batch set (which
  would downgrade P1 row 2 from a permanent wedge to a retry) is a client behaviour I could not
  confirm from this repo; `../7dtd-engine-research` was not read for it.
- Whether any modlet-heavy configuration can actually overflow `body_buf` in `sendBlockIdMapping`
  (P1 row 4). The failure paths are unreachable-by-design only if the 512 KiB buffer is always
  enough; the code's own log lines assume it is not.
- Scene coverage: no test drives a capture peer with a full window, so "capture never WindowFull"
  (C4) is inferred from `peer.zig:358-363`, not asserted anywhere.
