# Scenarios, harness and evidence

This subsystem owns the automated proof layer of `zdtd`: the integration scenario suite, the in-process harness that lets a test drive the shipped join and tick paths, the evidence ring that the guard writes to, the coverage-guided fuzz targets, and the wire-order mutation audit tool. Its boundary is mostly test-only code: `src/server/scenarios.zig`, `src/server/game/harness.zig`, `src/server/game/tests.zig`, `src/litenet/peer.zig`'s `Capture`, `src/fuzz.zig` and `tools/wire_order_mutants.py` never run in a production tick, while `src/server/evidence.zig` is production and is written from the guard on C2S rejection paths. The three files under `src/server/` sit in the top package of the stack, which may import all other `src` packages (`src/server/root.zig:3`); the one test-only import that reaches downward into `litenet` is documented as an exception, where `peer.Capture` imports `wire/frame.zig` so a test can decode package ids by name (`src/litenet/root.zig:4-6`).

Sources: [`src/server/scenarios.zig`](../../src/server/scenarios.zig), [`src/server/game/harness.zig`](../../src/server/game/harness.zig), [`src/server/evidence.zig`](../../src/server/evidence.zig), [`src/server/game/tests.zig`](../../src/server/game/tests.zig), [`src/litenet/peer.zig`](../../src/litenet/peer.zig), [`src/fuzz.zig`](../../src/fuzz.zig), [`tools/wire_order_mutants.py`](../../tools/wire_order_mutants.py)

## Scenario tests

`src/server/scenarios.zig` is the multi-system integration suite: 279 `test` blocks in an 18,772-line file. The file states its own rule, that the scenarios call the shipped `Game` handlers (`onData`, `handlePackage`, `replicate`, `broadcast`) rather than mocks (`src/server/scenarios.zig:1-2`). It is aggregated into the server package by `pub const scenarios = @import("scenarios.zig")` (`src/server/root.zig:20`) and referenced from that package's test block (`src/server/root.zig:99`), which is what makes `zig build test` see it. `src/server/game/tests.zig` is the sibling suite for `Game` helpers - persistence migrations, block damage, evidence dumping - and is aggregated the same way (`src/server/root.zig:73`).

Scenarios construct the server offline. `Game.create(allocator, world_dir, 0)` with port 0 is the harness entry point (`src/server/game.zig:782`), and port 0 makes init enter deterministic sim mode: virtual mono clock plus forced-serial `forRanges`, with an `errdefer` that undoes it if construction fails (`src/server/game/init_world.zig:109-111`, `src/server/game/init_world.zig:123`). That is deliberate, so a scenario does not have to wire the clock by hand (`src/util/sim.zig:9-11`).

Scenarios that need the chunk or streaming path own a world directory and wipe it first, because persisted state from a previous run otherwise leaks into the next one (`src/server/scenarios.zig:73-76`):

```zig
fn freshScenarioDir(dir: []const u8) void {
    io_fs.removeDirTree(dir);
    io_fs.mkdirPath(dir);
}
```

Those directories are named `worlds/zdtd_sc_*`, and `worlds/` is gitignored. Scenarios that only exercise package bodies and sim columns use `std.testing.tmpDir` instead, so nothing is left behind (`src/server/scenarios.zig:123-126`). `zig build test` carries a `-Dtest-filter` substring option used by the mutation audit and never by `make check`, so the gate always runs the whole suite (`build.zig:97-101`).

## The in-process harness

`src/server/game/harness.zig` is the seam injection layer. Its header states the scope and the limit: in-process test and scenario helpers for joined clients, packet injection, replication and direct world setup, and production networking does not use these shortcuts (`src/server/game/harness.zig:1-3`). `Game` re-exports the whole surface so a scenario holds one type, for example `attachJoinedClient`, `injectFramed` and `replicateNow` (`src/server/game.zig:4183-4197`).

The joined-client entry point (`src/server/game/harness.zig:32-34`):

```zig
pub fn attachJoinedClient(self: *Game, capture: ?*@import("../../litenet/peer.zig").Capture) !*Client {
    return attachJoinedClientAs(self, capture, null);
}
```

`attachJoinedClientAs` takes the first dead peer slot, marks it alive, assigns the next local id, gives it a loopback address on a synthetic port, and then drives the real join state machine through that peer: `onConnected`, the challenge echo built by `wire_frame.buildChallenge`, a `NetPackagePlayerLogin` body with the name `Bot` and an optional platform id, `NetPackageRequestToEnterGame`, and `NetPackageRequestToSpawnPlayer` (`src/server/game/harness.zig:36-84`). It returns `error.JoinFailed` unless the client ends up joined with a positive entity id (`src/server/game/harness.zig:85`). Every step goes through `self.onData`, so the phase gates and C2S handlers on the production path are the ones under test.

Two helpers carry the rest of a scenario (`src/server/game/harness.zig:89-96`):

```zig
pub fn injectFramed(self: *Game, c: *Client, framed: []const u8) !void {
    const peer = c.peer orelse return error.NoPeer;
    try self.onData(peer, framed);
}

pub fn replicateNow(self: *Game) !void {
    try self.replicate();
}
```

`applyDamage` and `setBlock` are the direct-world helpers; `setBlock` writes the block store and mirrors the container and sign-text side effects of the real break/place path so a test that overwrites a sign sees the same state (`src/server/game/harness.zig:19-30`). The fake clock is not in this file: it is `util/clock.enableVirtual`, which points `monoNs` and `sleepNs` at a counter instead of the OS.

## The capture peer

Assertions on outbound wire read a `Capture` hung off the peer. The record is a fixed ring of decoded user messages, plus a count (src/litenet/peer.zig:48-56, comments elided):

```zig
pub const Capture = struct {
    slots: [256]struct { len: u16 = 0, data: [8192]u8 = undefined } = undefined,
    n: usize = 0,
```

`push` drops the oldest slot when full (`src/litenet/peer.zig:58-70`), and the read side offers `findPkgId`, `findPkgIdEntity` (match the first `i32` against an entity id) and `findPkgIdClass` (match a class hash at body offset 5) (`src/litenet/peer.zig:76-124`). `sendReliable` pushes the user payload before exercising the real send path, so the capture sees exactly what a peer would have been sent (`src/litenet/peer.zig:282-285`).

A capture peer deliberately does not behave like a real one on the reliable path: `sendOneReliableOnChannel` frees the pending slot immediately and slides `local_window_start` to `local_seq` when `capture != null`, with the comment that capture-only peers must not `WindowFull` the suite (`src/litenet/peer.zig:366-371`). A scenario therefore proves what the server encoded, not that the retransmit window, fragment reassembly or ACK pacing would have delivered it to a live client. Tests for those live in `peer.zig` itself, driven through `handlePacket` with a null or loopback socket (`src/litenet/peer.zig:941`, `src/litenet/peer.zig:1008`).

## Evidence

`src/server/evidence.zig` is the one production piece here. It keeps a fixed ring of detector events with no secrets, no IP addresses and no packets, and an admin `evidence dump [path]` flushes it as JSONL through `Game.dumpEvidenceFile` (`src/server/evidence.zig:1-3`). The ring holds 64 events, newest overwriting oldest (`src/server/evidence.zig:7`, `src/server/evidence.zig:82-87`).

The record and the ring (src/server/evidence.zig:65-80):

```zig
pub const Event = struct {
    tick: u64 = 0,
    peer_local: i32 = -1,
    entity_id: i32 = -1,
    detector: Detector = .other,
    severity: Severity = .info,
    surface: Surface = .none,
    observed: f32 = 0,
    bound: f32 = 0,
};

pub const Ring = struct {
    events: [max_ring]Event = [_]Event{.{}} ** max_ring,
    head: usize = 0,
    n: usize = 0,
    total: u64 = 0,
```

`Severity` runs info, soft, strong, hard (`src/server/evidence.zig:9-14`); `Detector` names the phase, ownership, bounds, movement, decode, throttle, flood and farming surfaces plus `other` (`src/server/evidence.zig:16-27`); `Surface` narrows a signal to a C2S surface so a quarantine can deny only that surface (`src/server/evidence.zig:58-63`). Each detector is classified by what decides it, and the ceiling below is what keeps a client-reported value from reaching the hard ladder (src/server/evidence.zig:46-52):

```zig
pub fn decisionInputs(det: Detector) DecisionInput {
    return switch (det) {
        // Client-reported positions/coords/deltas weighed against server caps.
        .bounds, .movement => .client_informed,
        // Everything else decides purely on server state.
        .phase, .ownership, .decode, .throttle, .flood, .farming, .other => .server_only,
    };
}
```

`noteEvidence` is the single writer, and it does the ceiling before the record: a `.hard` event from a `client_informed` detector is downgraded to `.strong`, the downgrade is counted, the policy decides whether to record, and a recorded event increments `.evidence_events` and is streamed to plugin guests with the post-ceiling severity (`src/server/game/guard.zig:74-99`). The scenario for this pins both directions at once - a `.hard` bounds event is downgraded and never increments `c.guard.hard_n`, a `.hard` phase event passes untouched, and a registered observer sees severity 2 for the downgraded case (`src/server/scenarios.zig:6129-6158`). A test with a forged entity id asserts the ring itself, not only a counter, because surviving the packet does not show the range gate ran (`src/server/scenarios.zig:16819-16858`). The JSONL line format is one `formatEvent` call per event, dumped newest-last (`src/server/evidence.zig:90-119`), and the file flush is covered by an in-suite test that records two events and reads `evidence.jsonl` back (`src/server/game/tests.zig:1459-1481`).

## Fuzzing and the wire-order mutant tool

`src/fuzz.zig` is the fuzz entry point: a separate test module whose targets cover remote wire parsing and the other untrusted-input surfaces, including admin lines, map XML, COG headers, config XML patches, quest catalogs, GSI text builders and the save formats (`src/fuzz.zig:1-3`). It declares 36 targets; two more live outside it for private-fn access and are pulled in by a reference test, the stateful peer targets in `litenet/peer.zig` (fragment reassembly and the ACK window) and the WebUI HTTP parser in `server/webui.zig` (`src/fuzz.zig:706-715`).

Each target hands a fixed seed corpus to `std.testing.fuzz`, for example (src/fuzz.zig:59-61):

```zig
test "fuzz LiteNet packet decoders" {
    try std.testing.fuzz({}, fuzzPacketDecoders, .{ .corpus = &packet_corpus });
}
```

The build wires that module as its own test binary behind the `fuzz` step (`build.zig:135-141`), and `make fuzz` invokes it (`Makefile:91-92`). As read here, neither passes an argument that switches `std.testing.fuzz` into coverage-guided growth, so the gate replays the declared corpora; growing them is a separate run. Targets assert invariants on whatever the parser accepted rather than fixed outputs: claimed lengths never exceed the input, counts never exceed the caller's array, and `cont.slot_count` never shrinks (`src/fuzz.zig:69-79`, `src/fuzz.zig:322-331`).

`tools/wire_order_mutants.py` attacks the blind spot the unit tests cannot see: a stock body is read by position, so two adjacent same-width writes that share a value can be swapped and emit identical bytes, leaving the suite green while a test proves nothing. The tool swaps each such pair, rebuilds the suite and reports the survivors. Width is taken from the writer method name (tools/wire_order_mutants.py:64-74):

```python
WIDTH = {
    "writeByte": 1,
    "writeBool": 1,
    "writeU16": 2,
    "writeI16": 2,
    "writeU32": 4,
    "writeI32": 4,
    "writeF32": 4,
    "writeI64": 8,
    "writeU64": 8,
}
```

The decode side has the same defect and the same transformation, so struct-literal reads are swapped too (`tools/wire_order_mutants.py:77-99`). The tool is an audit, not a gate: it is not part of `make check`, a full run costs one `zig build test` per mutant, and it refuses to start on a dirty tree because a leftover swap is indistinguishable from a real edit (`tools/wire_order_mutants.py:20-29`, `tools/wire_order_mutants.py:359-370`). It edits `src/wire/` in place, restores on the way out including on signals, and must be run alone (`tools/wire_order_mutants.py:135-136`). Filtered runs are much cheaper but a mistyped filter would report every mutant as killed by a suite that ran nothing, so the filter set is proved live against the first candidate pairs before any result is trusted (`tools/wire_order_mutants.py:236-237`, `tools/wire_order_mutants.py:254-290`).

## What a green test proves

The repo's evidence rule is explicit: zdtd encodes and decodes with the same code, so a green round-trip test proves self-consistency, not stock compatibility, and a claim about stock behaviour needs an IL anchor or an observation from the real client (`docs/INDEX.md:7-10`). Everything in this subsystem is on the zdtd side of that line. A capture assertion shows what zdtd's own encoder produced and its own parser accepted; the outside oracles are the loadgen bots and the stock client with EAC off, which is the layer that proves a package survives a client `Read` (`docs/CLIENT_PLAYTEST.md:20-25`). The stock-client playtest suite in `docs/CLIENT_PLAYTEST.md` is designed there, not implemented in this repo as of this reading.

One claim category does land here: APM counter shapes are pinned by scenario assertions rather than eyeballed, so the `replicate_candidates`, `replicate_fanouts` and `replicate_encodes_skipped` relationships regress in `make check` (`docs/APM.md:90-100`). Gaps to know before extending: no test in this suite compares against a stock dedicated capture bit for bit, and the `evidence` ring is in-memory only - it survives no restart, since only the admin dump writes it out (`src/server/evidence.zig:1-3`).

## Adding a scenario

1. Decide what the test must observe. If it needs the chunk, deco or streaming path, give it a directory and wipe it with `freshScenarioDir` (`src/server/scenarios.zig:77`); otherwise use `std.testing.tmpDir` and pass the path in.
2. Create the server offline with port 0 so the virtual clock and serial ranges are already on (`src/server/game/init_world.zig:109-111`), and use `std.testing.allocator` or a `DebugAllocator` so a leak fails the run.
3. Attach one `Capture` per participating peer with `attachJoinedClient` (`src/server/game/harness.zig:32`) and assert the returned client is joined.
4. Drive the behaviour through production handlers: build the body with the `packages` builder, frame it with `packages.framed`, and inject it with `injectFramed`; advance the sim with `g.step()`; push interest with `replicateNow` (`src/server/scenarios.zig:259-269`). Do not re-implement a parser or call a sim system directly when a client package exists that reaches it.
5. Assert on the observable state, not survival. Parse the captured body back with the matching `packages.parse*` helper, and assert on the sim column (`g.sim.health[slot].hp`, `g.world.blockWorld`) or the counter (`g.harness.counters.get(.ownership_rejects)`) as well. A gate that lets a packet through while mutating the wrong thing passes a survival-only test (`src/server/scenarios.zig:587-597`).
6. Keep the scenario in `src/server/scenarios.zig` rather than starting a new harness, name it with the `scenario ` prefix, and leave no state behind: the directory it used is either a self-cleaning `tmpDir` or one it wipes on the next run.

## See also

- [`docs/subsystems/tick.md`](tick.md) - the loop a scenario steps by hand.
- [`docs/subsystems/apm.md`](apm.md) - the counters these scenarios assert on, including the unrelated `game/harness.zig` naming collision.
- [`docs/subsystems/join.md`](join.md) - the state machine `attachJoinedClient` drives.
- [`docs/subsystems/litenet.md`](litenet.md) - the transport `Capture` hangs off.
- [`docs/APM.md`](../APM.md) - counter semantics and the shapes scenario tests pin.
- [`docs/CLIENT_PLAYTEST.md`](../CLIENT_PLAYTEST.md) - the stock-client oracle this layer cannot replace.
