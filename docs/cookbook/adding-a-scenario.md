# Adding a scenario

A scenario is an integration test in `src/server/scenarios.zig` that drives the
shipped `Game` handlers (`onData`, `handlePackage`, `replicate`, `broadcast`)
instead of mocks, so the phase gates, C2S handlers and replication path under
test are the production ones. This recipe covers when a scenario is the right
proof, the shape to copy, the gates, and one verify step.

Read first: [`src/server/scenarios.zig`](../../src/server/scenarios.zig),
[`src/server/game/harness.zig`](../../src/server/game/harness.zig),
[`src/server/evidence.zig`](../../src/server/evidence.zig), the subsystem
reference [`docs/subsystems/scenarios.md`](../subsystems/scenarios.md), and the
"Testing and evidence" section of [`AGENTS.md`](../../AGENTS.md). There is no
`docs/testing.md` in the tree at this reading; the tier map in
[`docs/AGENTS.md`](../AGENTS.md) names it, so link the subsystem page instead.

## 1. Confirm a scenario is the right tier

Use the smallest proof that fails when the behavior breaks.

| Change | Proof |
|---|---|
| one function, one file | a `test` block at the bottom of the owning file |
| a `Game` helper or the persistence path | `src/server/game/tests.zig` |
| join, spawn, chunk, inventory, replication, a wire round trip | a scenario |

Multi-system join/inv/chunk paths extend `src/server/scenarios.zig` rather than
starting a second harness (AGENTS.md, "Testing and evidence"). The file states
its own rule: the scenarios call shipped handlers, not mocks
(`src/server/scenarios.zig:1-2`). Name the test `"scenario <what it proves>"`;
that prefix is the convention in the file, and it makes a filtered run easy to
type.

The file is aggregated into the server package by
`pub const scenarios = @import("scenarios.zig")` (`src/server/root.zig:20`) and
referenced from that package's test block (`src/server/root.zig:99`), which is
what makes `zig build test` see it. A new file under `src/server/` needs its own
line there, or its tests are silently dropped.

A scenario is in-process only. It proves what zdtd encoded and its own parser
accepted; a stock behavior claim still needs an IL anchor or an observation from
the real client with EAC off.

## 2. Give the test a world it owns

A scenario that touches the chunk, deco, save or streaming path owns a world
directory and wipes it first, because persisted state from an earlier run leaks
into the next one (`src/server/scenarios.zig:73-76`):

```zig
fn freshScenarioDir(dir: []const u8) void {
    io_fs.removeDirTree(dir);
    io_fs.mkdirPath(dir);
}
```

Call `io_fs.mkdirPath("worlds")` first, then wipe a `worlds/zdtd_sc_<topic>`
directory (`src/server/scenarios.zig:239-240`). `worlds/` is gitignored
(`.gitignore:13`); the helper wraps `io_fs.removeDirTree`
(`src/util/io_fs.zig:224`) and `io_fs.mkdirPath` (`src/util/io_fs.zig:66`).

A package-only scenario uses `std.testing.tmpDir` and passes the path in, so it
leaves nothing behind (`src/server/scenarios.zig:123-126`).

Tests never write into the repository (AGENTS.md, "Testing and evidence").
`.zdtd_test_*` is gitignored as a backstop (`.gitignore:39`), not as a licence,
and a scenario that leaves state behind fails the second `make check`.

## 3. Create the server offline

Port 0 is the offline switch: it enters deterministic sim mode with a virtual
mono clock and forced-serial range parallelism, and an `errdefer` undoes that if
construction fails (`src/server/game/init_world.zig:109-111`,
`src/server/game/init_world.zig:123`). A scenario therefore never wires the clock
by hand. Copy the construction shape from
`src/server/scenarios.zig:241-249`:

```zig
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_motion", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
```

`Game.create(allocator, world_dir, port)` heap-allocates and inits, and the
caller must `deinit` then `allocator.destroy` (`src/server/game.zig:781-782`).
Use `std.testing.allocator` or a `DebugAllocator` so a leak fails the run.

## 4. Attach clients and a capture

One `Capture` per participating peer is the outbound assertion surface
(`src/litenet/peer.zig:47-48`). The joined-client entry point
(`src/server/game/harness.zig:32-34`):

```zig
pub fn attachJoinedClient(self: *Game, capture: ?*@import("../../litenet/peer.zig").Capture) !*Client {
    return attachJoinedClientAs(self, capture, null);
}
```

`attachJoinedClientAs` takes a dead peer slot, gives it a synthetic loopback
port, and drives the real join state machine through that peer: `onConnected`,
the challenge echo, `NetPackagePlayerLogin`, `NetPackageRequestToEnterGame` and
`NetPackageRequestToSpawnPlayer` (`src/server/game/harness.zig:36-84`). It
returns `error.JoinFailed` unless the client ends up joined with a positive
entity id (`src/server/game/harness.zig:85`), so assert `ca.entity_id > 0` (two
clients also assert the ids differ, `src/server/scenarios.zig:253-257`).

Read the capture with `findPkgId` (`src/litenet/peer.zig:76`),
`findPkgIdEntity` (`src/litenet/peer.zig:91`) or `findPkgIdClass`
(`src/litenet/peer.zig:109`), and `clear()` it before the interesting step. A
capture peer is deliberately not a live peer on the reliable path: it frees the
pending slot immediately so the suite cannot `WindowFull`
(`src/litenet/peer.zig:366-371`). A capture assertion therefore proves what the
server encoded, not that ACK pacing or fragment reassembly would have delivered
it.

## 5. Drive the production path only

Build the body with the `packages` builder, frame it with `packages.framed`,
and inject it with `injectFramed`, which routes through `onData`
(`src/server/game/harness.zig:89-92`). Copy the shape from
`src/server/scenarios.zig:259-264`:

```zig
    // A reports a new position through the real package path.
    var pos_body: [64]u8 = undefined;
    const body = try packages.buildPosAndRotBody(&pos_body, ca.entity_id, 300, 71, 310, 0, 45, 0, true);
    var frame_buf: [128]u8 = undefined;
    const framed = try packages.framed(&frame_buf, "NetPackageEntityPosAndRot", body);
    try g.injectFramed(ca, framed);
```

Bodies go into a caller-owned stack buffer, never a per-send allocation. Advance
the sim with `g.step()` (`src/server/game.zig:4089`) and push interest with
`replicateNow` (`src/server/game/harness.zig:94-96`). Do not re-implement a
parser or call a sim system directly when a client package reaches that code.

Direct-world helpers exist for setup, not for the path under test:
`applyDamage` and `setBlock` (`src/server/game/harness.zig:15-30`). `setBlock`
mirrors the container and sign-text side effects of the real break/place path so
a test that overwrites a sign sees the same state.

## 6. Assert what changed, not that it survived

Parse the captured body back with the matching `packages.parse*` helper and
assert on the resulting state. Copy the shape from
`src/server/scenarios.zig:271-277`:

```zig
    const pos_id = packages.idOf("NetPackageEntityPosAndRot").?;
    const b_body = cap_b.findPkgIdEntity(pos_id, ca.entity_id);
    try std.testing.expect(b_body != null);
    const parsed = try packages.parsePosAndRotBody(b_body.?);
    try std.testing.expectEqual(ca.entity_id, parsed.entity_id);
    try std.testing.expect(@abs(parsed.x - 300.0) < 0.01);
    try std.testing.expect(@abs(parsed.z - 310.0) < 0.01);
```

Then assert the negative and an independent observable. The same scenario
asserts that A receives no self-echo of its own position
(`src/server/scenarios.zig:279-280`), and a gate scenario asserts the counter
and the untouched world rather than only that the packet was handled
(`src/server/scenarios.zig:234-235`). A test that only proves survival passes
while the gate mutates the wrong thing.

## 7. The guard and evidence path

If the scenario covers a rejection path, the evidence ring is the second
assertion. `noteEvidence` is the single writer, and it applies the T20 ceiling
before recording: a `.hard` event from a `client_informed` detector is downgraded
to `.strong` (`src/server/game/guard.zig:74`). The record and ring live in
`src/server/evidence.zig:65-87`:

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
```

A new `Detector` needs a classification in `decisionInputs`
(`src/server/evidence.zig:46-53`); the coverage test in the same file forces
that decision at compile time. Assert the ring itself, not only a counter, when
a range gate is the claim: a forged entity id that survives the packet still
proves nothing (`src/server/scenarios.zig:16819`). The observer wiring has its
own scenario at `src/server/scenarios.zig:6129`.

## 8. Keep it deterministic

Port 0 already gives the virtual clock, and `clock.enableVirtual`
(`src/util/clock.zig:25`) makes ages exact when a boundary is under test: the
auth-reap scenario ages a challenge past the cap instead of sleeping
(`src/server/scenarios.zig:194-199`). Vtable callbacks cannot close over locals,
so the observable is a module-scope variable, as in the evidence and buff
captures (`src/server/scenarios.zig:60-71`). Keep RNG seeded through sim mode.

## 9. Format, then run the gates

```bash
zig fmt src/server/scenarios.zig
zig build test
make check
```

`zig build test` runs the suite (`build.zig:102-109`), and `make check` adds the
lint, build and fuzz stages. While iterating, one test can be run alone with the
repeatable substring filter (`build.zig:97-101`):

```bash
zig build test -Dtest-filter="scenario a peer that never echoes"
```

`make check` never passes a filter, so the gate always runs everything.

## VERIFY

1. Run the filtered command for the whole test name, then the full suite:

   ```bash
   zig build test -Dtest-filter="scenario <your name>"
   zig build test
   ```

2. Prove the test is load-bearing: revert the production change the scenario
   covers, rerun the filtered command, and confirm it fails. Restore the change
   and rerun it green. A scenario that never fails on the broken code proves
   nothing.
3. Run `git status --porcelain` after the suite. It must not list a new file or
   a modified world path: the scenario wrote nothing into the repository.

## See also

- [`../subsystems/scenarios.md`](../subsystems/scenarios.md) - the reference for
  the harness, the capture peer and the evidence ring.
- [`adding-a-c2s-handler.md`](adding-a-c2s-handler.md) - the handler a scenario
  usually drives.
- [`adding-a-stock-package-body.md`](adding-a-stock-package-body.md) - the wire
  builder a scenario round-trips.
