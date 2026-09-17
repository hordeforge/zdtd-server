# APM: counters, section timers, reports

APM owns the in-process instrumentation of the `zdtd` dedicated server: monotonic counters, fixed latency histograms, scoped wall-clock section timers, the text and JSON snapshot formats, and the optional Tracy zone markers. Its boundary is the process. It encodes no package, mutates no world state, and persists nothing to disk; the only things that leave it are a JSON line on stdout, a text reply on the admin TCP socket, an HTTP JSON document for the WebUI, and Tracy zone records in a `-Dtracy` build. Dependency direction is enforced in both directions: the package may import only `std`, `util/clock` and `build_options` (`src/apm/root.zig:4`), and `scripts/lint-architecture.sh:31` forbids `apm` from importing `server`, `wire`, `world`, `ecs`, `assets` or `litenet`. Nothing in the other packages may import it either: `util`, `litenet`, `plugin`, `assets`, `ecs`, `world` and `wire` all list `apm` as forbidden (`scripts/lint-architecture.sh:30-51`). The actual importers are `src/server/game.zig`, the files under `src/server/game/` and `src/server/c2s/` that instrument a path, `src/server/admin_console.zig`, and `src/main.zig`. Note one naming collision: `src/server/game/harness.zig` is unrelated scenario and join helper code, not instrumentation. `docs/ARCHITECTURE.md:91` files that file under the APM plane; as read here it imports no `apm` module and instruments nothing.

Sources: [`src/apm/root.zig`](../../src/apm/root.zig), [`src/apm/metrics.zig`](../../src/apm/metrics.zig), [`src/apm/profiler.zig`](../../src/apm/profiler.zig), [`src/apm/report.zig`](../../src/apm/report.zig), [`src/apm/tracy.zig`](../../src/apm/tracy.zig)

## The Harness

`Harness` is the only aggregate. It holds one `Counters` and one `Profiler`, both by value, and has no allocator and no initialization step. The single instance lives on `Game` as a field (`src/server/game.zig:432`), so every tick path reaches it as `self.harness`.

The harness handle (src/apm/root.zig:21-34):

```zig
/// Process-wide handle used by tick/net once the server loop exists.
pub const Harness = struct {
    counters: Counters = .{},
    prof: Profiler = .{},

    pub fn snapshot(self: *const Harness) Snapshot {
        var s: Snapshot = .{
            .counters = self.counters,
            .profiler = self.prof,
        };
        s.captureWall();
        return s;
    }
};
```

`snapshot` copies both arrays by value, so a report is a consistent point-in-time sample taken while the tick thread is between steps, not a live view. `src/apm/root.zig:13-19` re-exports `Counters`, `CounterId`, `LatencyHist`, `Profiler`, `Section`, `Snapshot` and `OpsGauges`; call sites import `../../apm/root.zig` and use those names.

## What runs per tick

The tick step is the primary writer. `Game.step` opens a `.tick_total` scope as its first statement and closes it in a `defer` that also emits one Tracy frame mark (`src/server/game/step.zig:33`, `src/server/game/step.zig:35-39`), then increments `.ticks` (`src/server/game/step.zig:41`). Inside the step, `.net_poll` wraps the datagram poll loop plus stale-peer reap, admin poll, WebUI poll and MCP poll (`src/server/game/step.zig:44-89`), and `.sim_entities` wraps the simulation phase with `.terrain_snap` nested at the top of it (`src/server/game/step.zig:93-104`). The periodic save is wrapped in `.save_io` with `.save_encode` nested around `world.saveAll()` (`src/server/game/step.zig:523-530`).

Two periodic duties ride the same step. `sampleFlushCounters` converts the background chunk writer's atomic totals into counter deltas once per tick (`src/server/game/step.zig:546`, body at `src/server/game.zig:3785-3800`); the writer runs off-thread, so the tick thread samples and subtracts the previously seen values with saturating subtraction, and adds the error delta to both `.chunk_flush_errors` and `.persistence_errors` (`src/server/game.zig:3799`). Then, when `tick_n % apm_report_period_ticks == 0`, the step builds a snapshot, fills the ops gauges, serializes one JSON line and writes it to stdout (`src/server/game/step.zig:548-582`). The period defaults to `protocol.ticks_per_second * 60` (`src/server/game/types.zig:56`) and is overridable from configuration through `zdtd.toml [apm] dump_every_s` (`src/server/game.zig:774`, `src/server/game.zig:907`).

The overrun counter is the one counter written outside `step`: `Game.run` compares the next deadline with the monotonic clock, increments `.tick_overruns`, may arm the load-shed valve, and logs at the first overrun and every hundredth thereafter (`src/server/game.zig:4154-4166`).

## Counters

`CounterId` is a non-exhaustive `enum(u16)`. `Counters` is a flat `u64` array indexed by `@intFromEnum`, which makes `inc`/`add`/`get` branch-light on the tick path. `add` saturates at `maxInt(u64)` instead of wrapping, and `get` returns 0 for an index outside the array, so a stray unknown tag cannot read past the end (`src/apm/metrics.zig:162-174`).

The head of the counter set and the owning note (src/apm/metrics.zig:5-17, later entries elided):

```zig
/// Named counters owned by the single-threaded game loop. These are plain u64
/// values, so callers must synchronize any access from other threads.
pub const CounterId = enum(u16) {
    ticks,
    net_packets_in,
    net_packets_out,
    net_bytes_in,
    net_bytes_out,
    entities_ticked,
    packages_encoded,
    packages_broadcast,
    join_ok,
    join_fail,
```

The array and its operations (src/apm/metrics.zig:159-179):

```zig
pub const Counters = struct {
    values: [counters_len]u64 = .{0} ** counters_len,

    pub fn add(self: *Counters, id: CounterId, n: u64) void {
        const i: usize = @intFromEnum(id);
        if (i < counters_len) self.values[i] = std.math.add(u64, self.values[i], n) catch std.math.maxInt(u64);
    }

    pub fn inc(self: *Counters, id: CounterId) void {
        self.add(id, 1);
    }

    pub fn get(self: *const Counters, id: CounterId) u64 {
        const i: usize = @intFromEnum(id);
        return if (i < counters_len) self.values[i] else 0;
    }

    pub fn reset(self: *Counters) void {
        @memset(&self.values, 0);
    }
};
```

Representative call sites show the shape of an increment: `onData` adds one packet and its payload length before any parsing (`src/server/game/net_handlers.zig:47-48`), the replicate pass counts `replicate_candidates` per pass and `replicate_fanouts` per framed package handed to a peer (`src/server/game/replicate.zig:113`, `src/server/game/replicate.zig:187-189`). The rest of the set is enumerated with one-line meanings in `docs/APM.md:46-63` and, in code, as doc comments on each tag. `docs/APM.md:102` asks for append-only ids for stable JSON keys; that is a convention for future edits, not an invariant any test in `src/apm/` checks.

## Sections and the hot-path instrumentation pattern

`Section` is a non-exhaustive `enum(u8)`; the trailing `_` is deliberate so that an unknown tag has a well-defined index and `Profiler.begin`/`end` can no-op instead of trapping (`src/apm/profiler.zig:40-43`, `src/apm/profiler.zig:73-82`). The named head of the set (src/apm/profiler.zig:8-14, later members elided):

```zig
pub const Section = enum(u8) {
    tick_total,
    net_poll,
    sim_entities,
    replicate,
    chunk_stream,
    save_io,
```

`Profiler` keeps one `LatencyHist` and one optional open timestamp per section index (src/apm/profiler.zig:67-97):

```zig
pub const Profiler = struct {
    hist: [sections_len]metrics.LatencyHist = [_]metrics.LatencyHist{.{}} ** sections_len,
    open: [sections_len]?u64 = [_]?u64{null} ** sections_len,

    /// Raw begin/end are not Tracy-mapped: Tracy validates strict LIFO nesting
    /// per thread, which only `scope`/`Scope.end` guarantees. Use `scope`.
    pub fn begin(self: *Profiler, s: Section) void {
        const i: usize = @intFromEnum(s);
        if (i >= sections_len) return;
        self.open[i] = clock.monoNs();
    }

    pub fn end(self: *Profiler, s: Section) void {
        const i: usize = @intFromEnum(s);
        if (i >= sections_len) return;
        const start = self.open[i] orelse return;
        self.open[i] = null;
        const now = clock.monoNs();
        const dt: u64 = if (now >= start) now - start else 0;
        self.hist[i].observe(dt);
    }

    pub fn histOf(self: *const Profiler, s: Section) *const metrics.LatencyHist {
        return &self.hist[@intFromEnum(s)];
    }

    pub fn reset(self: *Profiler) void {
        for (&self.hist) |*h| h.reset();
        @memset(&self.open, null);
    }
};
```

The instrumentation pattern at a hot path is a stack scope whose `end` runs on every exit path: `const sc = apm.profiler.scope(&self.harness.prof, .join); defer sc.end();` at the top of the C2S join handler (`src/server/c2s/join.zig:39-40`). Nesting is per section index, not a stack: an unmatched `end` returns silently because `open[i]` is null, and a `begin` for a tag already open overwrites its start timestamp, so one tag cannot be open twice at once. Sequential reuse of the same tag within a tick is fine; use distinct tags for nested work, as `.save_encode` inside `.save_io` does.

Latency buckets are a fixed log2 histogram in nanoseconds, one `u64` per power of two, with count, sum and max (src/apm/metrics.zig:181-195):

```zig
/// Fixed log2 histogram for latency in nanoseconds (power-of-two buckets).
/// Bucket k covers [2^k, 2^(k+1)) ns for k in 0..63.
pub const LatencyHist = struct {
    buckets: [64]u64 = .{0} ** 64,
    count: u64 = 0,
    sum_ns: u64 = 0,
    max_ns: u64 = 0,

    pub fn observe(self: *LatencyHist, ns: u64) void {
        self.count = std.math.add(u64, self.count, 1) catch std.math.maxInt(u64);
        self.sum_ns = std.math.add(u64, self.sum_ns, ns) catch std.math.maxInt(u64);
        self.max_ns = @max(self.max_ns, ns);
        const b: u6 = if (ns == 0) 0 else @intCast(@min(63, 63 - @clz(ns)));
        self.buckets[b] = std.math.add(u64, self.buckets[b], 1) catch std.math.maxInt(u64);
    }
```

`meanNs` divides the exact sum by the count; `percentileNs` is an estimate that walks buckets to the target count and returns the bucket midpoint, so p99 is only as precise as one power-of-two band (`src/apm/metrics.zig:197-217`). Any reading that depends on sub-band precision needs a finer histogram, which does not exist here.

## Snapshot formats, bounds and output surfaces

`Snapshot` is the report value: copied counters, copied profiler, a wall-clock stamp, and optional instantaneous gauges (src/apm/report.zig:8-31):

```zig
/// Instantaneous load gauges (not cumulative). Filled by the game before dump.
pub const OpsGauges = struct {
    tick: u64 = 0,
    joined: u32 = 0,
    entered: u32 = 0,
    peers_alive: u32 = 0,
    zombies: u32 = 0,
    chunks: u32 = 0,
};

pub const Snapshot = struct {
    counters: metrics.Counters = .{},
    profiler: profiler.Profiler = .{},
    wall_ns: u64 = 0,
    /// When set, writeJsonLine embeds an `"ops"` object for scrapers.
    ops: ?OpsGauges = null,

    pub fn captureWall(self: *Snapshot) void {
        // This value crosses the process boundary in text/JSON reports and
        // must align with server logs and collector clocks. Profiling uses the
        // monotonic clock separately in profiler.zig.
        self.wall_ns = clock.wallNs();
    }
};
```

`wall_ns` is wall clock so reports correlate with logs; duration measurement stays on `clock.monoNs()`. Both writers walk the enums at comptime and skip any field whose name starts with `_` (`src/apm/report.zig:43`, `src/apm/report.zig:75`). Text prints every counter and only those sections whose histogram has a non-zero count (`src/apm/report.zig:85`); JSON omits zero-count sections the same way and adds the `"ops"` object when set (`src/apm/report.zig:112-130`). `max_text_bytes` and `max_json_bytes` are computed from the enum field names and the widest `u64` rendering, so a new counter or section cannot silently truncate a dump; call sites size fixed stack buffers from them (`src/apm/report.zig:39-69`, test at `src/apm/report.zig:174-206`).

Four output surfaces exist. A bounded run (`--ticks N`, `--once`) saves the world and then writes the text form to stdout (`src/main.zig:1158-1165`). An unbounded run writes one `{"type":"zdtd_apm",...}` line to stdout per period (`src/server/game/step.zig:569`), deliberately on stdout so `1>metrics.jsonl 2>server.log` separates machine output from the `zdtd:` diagnostics on stderr. The admin TCP verb `apm`, with `metrics` as an alias, replies with the same text form (`src/server/admin.zig:569`, `src/server/admin.zig:619`, `src/server/admin_console.zig:1299-1307`). The WebUI serves `/api/apm.json` (`src/server/webui.zig:716`) from `renderApmJson`, a different schema tagged `zdtd_webui_apm` (`src/server/webui.zig:2015-2020`) that carries a selected subset of counters, section means and p99 values (`src/server/webui.zig:2043-2082`) and a compact player roster (`src/server/webui.zig:2132-2133`). That WebUI snapshot is a separate display structure filled at most every tenth tick by `fillWebuiSnap` (`src/server/admin_console.zig:107-111`), reading the harness directly (`src/server/admin_console.zig:143-190`). No APM value crosses the game wire, and no APM file writes exist in `src/apm/`, so all of this state is lost on restart.

## Tracy zones

Tracy is an opt-in viewer over the section tags, never a second instrumentation source. `-Dtracy=true` is a build option (`build.zig:14-18`) and without `-Dtracy-src=PATH` it fails the build with one named message rather than linking a no-op shim (`build.zig:33-40`); the compiled-in flag is `tracy_enabled = tracy and tracy_src != null` (`build.zig:29`). With the flag off, `Zone` is zero-sized and no `___tracy_*` symbol is referenced (`src/apm/tracy.zig:21`, test at `src/apm/tracy.zig:60-69`). Every `apm.profiler.scope` call site emits one zone named after its `Section`; there is nothing to annotate per call site.

The zone handle (src/apm/tracy.zig:39-53):

```zig
/// Open zone handle. Zero-sized when Tracy is off.
pub const Zone = struct {
    ctx: if (enabled) ZoneCtx else void,

    pub inline fn end(self: Zone) void {
        if (enabled) ___tracy_emit_zone_end(self.ctx);
    }
};

/// Begin a zone. `active = false` emits an inactive (allocation-free no-op)
/// zone: the Tracy client returns early on both begin and end, so the pair
/// still nests correctly without fabricating a name.
pub inline fn zone(loc: *const SourceLocation, active: bool) Zone {
    return .{ .ctx = if (enabled) ___tracy_emit_zone_begin(loc, @intFromBool(active)) else {} };
}
```

`scope` passes `active = false` for a tag with no name, so an unknown section produces an inert zone instead of a fabricated name (`src/apm/profiler.zig:111-118`). Source locations come from a rodata table built once at container scope, because Tracy requires the location to outlive every zone that points at it (`src/apm/profiler.zig:48-65`). `apm.tracy.frameMark()` closes one frame per server tick (`src/server/game/step.zig:37`). Only zone begin/end and the frame mark are mapped: no plots for counters, no lock, allocation, message or callstack zones, and worker threads started by `ecs` jobs emit nothing because `ecs` may not import `apm`. The Tracy path is not built by `make check` or CI and no checkout exists on this host, so it is untested here rather than verified - `docs/APM.md:233-237` records the same limit.

## Evidence rule and known gaps

The counter and section set is the evidence of record for tick-budget and scaling claims: judge regressions from `zdtd` dumps, and never require the sibling `7dtd-server-apm` Mono bridge (`docs/APM.md:13-22`). A dump proves what the instrumented code did; a green round trip between zdtd encode and zdtd decode proves self-consistency, not stock compatibility. The replication counter shapes are pinned by scenario assertions rather than eyeballed: `src/server/scenarios.zig:7820-7907` reads `replicate_fanouts` and `replicate_candidates` deltas around controlled world changes, which is the `docs/APM.md:99-100` claim that both shapes regress in `make check`. Gaps to know before extending: there is no signal-triggered dump and no JSON CLI switch (`docs/APM.md:156`, `docs/APM.md:260`), per-player and per-interest byte budgets are roadmap rather than code (`docs/APM.md:251`), and nothing here persists or resets on its own - `Counters.reset` and `Profiler.reset` exist, but no file under `src/` calls either outside their own tests.

## See also

- [tick.md](tick.md) - the 50 ms loop whose sections this page names
- [admin.md](admin.md) - the admin TCP transport that carries the `apm` verb
- [scenarios.md](scenarios.md) - in-process scenarios that assert the counter shapes
- [../APM.md](../APM.md) - full counter and section inventory, Tracy build recipe, roadmap
- [../SCALE.md](../SCALE.md) - the acceptance checks these counters are read for
