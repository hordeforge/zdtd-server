# Shared utilities

The `util` package is the leaf layer of the source tree: it owns process primitives that carry no game domain, namely the mono and virtual clock, the seeded PRNGs, one filesystem helper set, an optional range-parallel dispatcher, scratch arenas, process logging, constant-time secret comparison, deterministic sim mode with filesystem fault injection, non-blocking TCP listen, host metrics, and the comptime-reflected TOML binder. The boundary is stated in the package comment (`src/util/root.zig:3`): the package "must not import server, ecs, wire, world, assets, litenet, or apm". Every other package may import it, and the direction is machine-enforced by `check_edges util 'server|wire|world|ecs|assets|litenet|apm'` (`scripts/lint-architecture.sh:30`), so util is the contract surface every subsystem is allowed to build on and none is allowed to reach into. The twelve modules are re-exported by the facade (`src/util/root.zig:8`); leaf files stay importable directly, which is what most callers do.

Nothing in util encodes or decodes a package, owns a save format, or persists state of its own. Its outputs are timestamps, RNG draws, byte ranges, booleans and bytes that callers write. The two places a util value reaches the wire are derived results: a connect-key comparison (`src/litenet/packet.zig:149`) and the challenge comparison (`src/server/game/net_handlers.zig:50`).

Sources: [`src/util/root.zig`](../../src/util/root.zig), [`src/util/clock.zig`](../../src/util/clock.zig), [`src/util/sim.zig`](../../src/util/sim.zig), [`src/util/rng.zig`](../../src/util/rng.zig), [`src/util/game_random.zig`](../../src/util/game_random.zig), [`src/util/io_fs.zig`](../../src/util/io_fs.zig), [`src/util/parallel.zig`](../../src/util/parallel.zig), [`src/util/arena.zig`](../../src/util/arena.zig), [`src/util/log.zig`](../../src/util/log.zig), [`src/util/secret.zig`](../../src/util/secret.zig), [`src/util/tcp_listen.zig`](../../src/util/tcp_listen.zig), [`src/util/sys_metrics.zig`](../../src/util/sys_metrics.zig), [`src/util/toml_bind.zig`](../../src/util/toml_bind.zig).

## Mono clock, wall time, and virtual time

`clock.zig` is an `std.Io`-free leaf, deliberately: `monoNs` is on the per-packet hot path and constructing an `Io.Threaded` installs SIGIO/SIGPIPE handlers, so the module reads `posix.system.clock_gettime(CLOCK_MONOTONIC)` directly through the vDSO (`src/util/clock.zig:51`; rationale at `docs/STD_ABSTRACTIONS.md:57`). The virtual-clock switch holds two process-wide atomics so a harness can enable it race-free against readers (`src/util/clock.zig:15`):

```zig
var virtual_active: std.atomic.Value(bool) = .init(false);
var virtual_ns: std.atomic.Value(u64) = .init(0);
```

Four readers, each with one job. `monoNs` measures elapsed time and drives resend deadlines and stale windows (`src/util/clock.zig:48`; callers at `src/litenet/peer.zig:364`, `src/litenet/server.zig:39`, `src/apm/profiler.zig:76`). `wallSeconds` exists only for values that must survive a restart, such as ban expiry (`src/util/clock.zig:62`). `wallNs` is for externally correlated events such as APM snapshots (`src/util/clock.zig:73`). `wallStamp` formats a 19-byte `YYYY-MM-DD HH:MM:SS` string for log and audit lines (`src/util/clock.zig:84`), and is the reason logging takes no clock dependency of its own. All four derive from the virtual clock when it is active, so offline runs stay seed-stable. `sleepNs` advances virtual time and returns instead of sleeping (`src/util/clock.zig:97`).

## Deterministic sim mode and filesystem fault injection

`sim.zig` is the single coupling point for the three globals that must move together: the virtual clock, forced-serial ranges, and outstanding I/O faults. Spreading them across call sites is the partial-enable failure the module comment names (`src/util/sim.zig:5`). `disable` shows all three (`src/util/sim.zig:53`):

```zig
pub fn disable() void {
    parallel.setForceSerial(false);
    clock.disableVirtual();
    run_seed.store(0, .release);
    io_fs.injectWriteFailures(0);
    io_fs.injectReadFailures(0);
}
```

`enable` sets virtual time plus forced serial, and `enableSeeded` also records the process-wide run seed (`src/util/sim.zig:39`, `:45`); `getSeed`/`formatSeed` let a failure log name the value that reproduces the run (`src/util/sim.zig:67`, `:73`). Two constants matter to callers: the default virtual epoch is 1 s so age math that subtracts from `monoNs` cannot underflow (`src/util/sim.zig:23`), and `tick_ns` repeats the 20 TPS formula locally because util cannot import `protocol` (`src/util/sim.zig:31`). `advanceTick`/`advanceTicks` step the virtual clock by whole ticks (`src/util/sim.zig:85`, `:90`); the game step calls `advanceTick` after a completed tick (`src/server/game/step.zig:38`) and uses `isEnabled` to attach the seed to a failure line (`src/server/game/step.zig:51`).

The fault hooks live in `io_fs` but are part of this lifecycle, because `sim.disable` clears them (`src/util/io_fs.zig:23`):

```zig
pub fn injectWriteFailures(n: u32) void {
    write_fail_remaining.store(n, .release);
}
```

Each injected fault is consumed once through a CAS loop, so concurrent callers cannot double-spend it (`src/util/io_fs.zig:44`); a write fault returns `error.DiskQuota` before any syscall (`src/util/io_fs.zig:79`) and a read fault returns `error.InputOutput` (`src/util/io_fs.zig:161`). Production never enables sim mode. The one automatic entry point is world construction with `port == 0`, which calls `enableSeeded` with the worldgen seed or `default_seed` and installs an `errdefer` that disables again on a later init failure (`src/server/game/init_world.zig:109`, `:123`); the module comment states the same contract (`src/util/sim.zig:9`).

## Deterministic streams: XorShift32 and GameRandom

Two generators, two jobs. `rng.zig` is the zdtd-owned generator for sim paths that only need to be reproducible across zdtd runs, such as AI wander and director picks, and its rule is absolute: never OS entropy or `std.crypto.random` on the sim path (`src/util/rng.zig:3`). The whole state is one word (`src/util/rng.zig:10`):

```zig
pub const XorShift32 = struct {
    state: u32 = 0,
```

`init` rewrites a zero seed to 1 so no stream is dead (`src/util/rng.zig:14`), `initFromU64` folds a run seed through a SplitMix64 finalizer (`src/util/rng.zig:19`), and `initFromNetId` gives each entity its own wander stream (`src/util/rng.zig:29`). `nextBounded` is documented as biased modulo reduction and explicitly not for fair draws (`src/util/rng.zig:41`). `xorshift32Step` is the stateless form for call sites that store state in a component field (`src/util/rng.zig:55`).

`game_random.zig` is the stock-matching generator, and it exists to reproduce draws the client also makes. `GameRandom` is the .NET `System.Random` algorithm verbatim, including the 56-entry `SeedArray`, `MBIG` 2147483647, `MSEED` 161803398 and the `4.6566128752458E-10` sample scale (`src/util/game_random.zig:1`). Its state is the whole structure (`src/util/game_random.zig:16`):

```zig
pub const GameRandom = struct {
    /// `SeedArray` (ctor allocates 56, IL=5); index 0 is unused by the
    /// algorithm, which works 1..55.
    seed_array: [56]i32 = [_]i32{0} ** 56,
    inext: i32 = 0,
    inextp: i32 = 0,
```

The API mirrors the IL it ports: `setSeed` (`src/util/game_random.zig:36`), `internalSample` with the `== MBIG` decrement (`:69`), `sample`/`nextDouble`, `nextFloat`, `next` (`:86`, `:90`, `:95`, `:100`), `nextBelow` and `nextRange` including the large-range path (`:105`, `:111`), and `getSampleForLargeRange` (`:120`). Per-position streams come from the stock fold (`src/util/game_random.zig:151`):

```zig
pub fn seededOnPos(x: i32, y: i32, z: i32, seed: i32) GameRandom {
    const s: i32 = seed +% x +% (z << 14) +% (y << 24);
    return GameRandom.init(s);
}
```

Callers pass a `*GameRandom` into asset-table rolls (`src/assets/items.zig:118`) and construct one per roll from an explicit seed (`src/server/game.zig:3764`); the blockplaceholder per-cell roll is the stock-fidelity path (`src/assets/blockplaceholders.zig:131`). The fidelity limit is worth stating plainly: the unit goldens are five draws per seed against Mono's `System.Random`, which proves the algorithm port (`src/util/game_random.zig:11`), not that every stock draw site in the server has been routed through it.

## Filesystem and scratch arenas

`io_fs.zig` is the one filesystem surface for application code: ordinary file and directory work goes through it or through `std.Io` directly, never through `std.os.linux` or raw posix (`src/util/io_fs.zig:1`). That is the application half of the stdlib policy in `docs/STD_ABSTRACTIONS.md:19`, which lists `sys_metrics.zig` as the only `std.os.linux` exception. Each helper constructs a short-lived `Io.Threaded` on `page_allocator`, so concurrent callers (a parallel chunk save, overlapping helpers) never share a `DebugAllocator` with `Threaded.init` and a helper can nest inside a bound socket `Threaded` (`src/util/io_fs.zig:57`, implementation at `:62`).

The write path is the durability property every caller relies on (`src/util/io_fs.zig:78`):

```zig
pub fn writeFile(rel_path: []const u8, data: []const u8) !void {
    if (consumeFault(&write_fail_remaining)) return error.DiskQuota;
    var threaded = ioThreaded();
    defer threaded.deinit();
    const io = threaded.io();
```

The materialize step is atomic, so a crash or full disk mid-write cannot corrupt the previous contents (`src/util/io_fs.zig:83`):

```zig
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(io, rel_path, .{
        .make_path = true,
        .replace = true,
    });
```

The rest of the surface is deliberate and narrow: `mkdirPath` (`:66`), `listFileNames` and `listDirNames`, both sorted so filesystem readdir order cannot leak into deterministic behaviour (`:101`, `:120`, `:132`), `readFileAll`/`readFileInto` (`:160`, `:169`), `fileExists`, `fileMtimeNanos`, `dirExists` (`:178`, `:190`, `:201`), `deleteFile`, `removeDirTree`, `readLinkAbsolute` (`:211`, `:224`, `:236`). The one tick-path call is the stock `serveradmin.xml` hot reload, which polls `fileMtimeNanos` every 100 ticks and re-applies the XML only when the stamp moves (`src/server/game/tick.zig:1805`, `:1810`, `:1812`). Nothing else opens a file per tick.

`arena.zig` is the matching allocation helper for init and load work: a lazy per-table scratch arena created on first use and reused after (`src/util/arena.zig:1`). `newArenaHolder` heap-allocates and initializes one, and the caller still owns `errdefer { deinit; destroy }` (`src/util/arena.zig:6`); `ensureLazyArena` returns the existing allocator or creates one behind an optional pointer (`src/util/arena.zig:12`). This is the escape hatch that keeps hot paths free of the arena pattern: allocation is fine at init and load, and forbidden on the tick, packet, interest and chunk-stream paths (`AGENTS.md`, Memory).

## Optional range parallelism

`parallel.zig` is the only sanctioned way to split work across threads: the tick-path rules allow parallelism through this module, not through ad-hoc `std.Thread.spawn` in builders or the join state machine. The public shape is a comptime-work parallel-for (`src/util/parallel.zig:239`):

```zig
pub fn forRanges(
    total: usize,
    ctx: anytype,
    comptime work: *const fn (@TypeOf(ctx), begin: usize, end: usize) void,
) void {
```

The dispatcher degrades to serial whenever parallelism cannot pay: `total` below `min_parallel_items` of 24 (`src/util/parallel.zig:9`, `:147`), no started workers (`:147`), or a nested or concurrent call, which is detected by swapping an `in_run` flag and running `work(ctx, 0, total)` on the caller thread rather than clobbering the shared job slots (`:140`). `splitRanges` produces up to `max_workers` (8) contiguous ranges with empty tails omitted (`:7`, `:24`), the pool keeps `cpuWorkers() - 1` detached workers for the process lifetime (`:11`, `:87`), and the calling thread executes range 0 itself (`:177`). `force_serial` makes every call serial on the calling thread; `sim.enable` sets it and `sim.disable` clears it (`src/util/parallel.zig:192`, `:195`), which is what keeps DST independent of the OS scheduler.

Two auxiliary exports exist because Zig 0.16 has no `std.Thread.Mutex` and an `std.Io.Mutex` needs an `Io`: `poolIo` hands out the pool's `Threaded` for callers that need a `Condition` (`src/util/parallel.zig:206`), and `IoMutex` wraps a mutex that resolves the pool's `Io` internally so callers need not thread one through (`:218`). Current consumers are the AI and turret system splits (`src/ecs/systems.zig:3018`, `:3542`), the parallel chunk save (`src/world/store.zig:1704`), and the open ECS view scan that is also `groupSlice`'s test oracle (`src/ecs/query.zig:105`).

## Logging, secrets, TCP listen, and host metrics

`log.zig` is process-wide because the boot banners are emitted deep inside `Game.init`, far from argv parsing; the quiet flag is set once before any of them run (`src/util/log.zig:9`, set at `src/main.zig:441`). `info` is suppressed by `--quiet` or `loglevel >= 1`, while `warn` and `err` are never hidden by `--quiet` and always carry a wall-clock stamp plus a `[WARN]`/`[ERROR]` tag (`src/util/log.zig:41`, `:51`, `:59`), the stamp coming from `clock.wallStamp` (`:64`). `min_level` mirrors stock `Log.Level` 0..4 and is set by the `loglevel` admin verb (`src/util/log.zig:16`).

`secret.zig` exists because `std.crypto.timing_safe.eql` only compares equal-length arrays of comptime-known length, which variable-length wire input is not (`src/util/secret.zig:4`). `constantTimeEql` always walks `max(a.len, b.len)` so a remote observer learns payload size rather than a length branch (`src/util/secret.zig:14`). The connect-key check is the canonical caller (`src/litenet/packet.zig:149`); the webui session token and the telnet admin password use the same comparator (`src/server/webui.zig:570`, `src/server/admin.zig:34`).

`tcp_listen.zig` is the TCP counterpart of the UDP socket module: `Listener.listen` binds IPv4 through `std.Io.net` with `reuse_address`, and `accept` gates `posix.system.accept4` behind a zero-timeout `poll` because `Io.net.Server.accept` treats EAGAIN as a programmer bug (`src/util/tcp_listen.zig:21`, `:65`, `:81`; rationale at `docs/STD_ABSTRACTIONS.md:70`). `writeAll` retries short writes but caps total wait at 200 ms in 25 ms poll slices, so a paused peer cannot pin the tick thread (`src/util/tcp_listen.zig:104`, `:119`). Admin, GSI info, webui and the MCP transport are the consumers (`docs/STD_ABSTRACTIONS.md:35`).

`sys_metrics.zig` is the documented exception to the no-`std.os.linux` rule: two syscalls (`sysinfo`, `getrusage`), no `/proc` reads, so sampling stays off the filesystem path (`src/util/sys_metrics.zig:1`, `:49`, `:61`). The struct is the whole dashboard contract (`src/util/sys_metrics.zig:12`):

```zig
pub const Metrics = struct {
    /// 1 / 5 / 15 minute load averages (fractional).
    load_1: f32 = 0,
    load_5: f32 = 0,
    load_15: f32 = 0,
    /// Total usable RAM in MiB.
    mem_total_mb: u32 = 0,
    /// Free + buffer RAM in MiB (sysinfo has no MemAvailable; close enough
    /// for a pressure gauge).
    mem_avail_mb: u32 = 0,
    /// Process CPU (utime + stime) as a percentage of host uptime.
    proc_cpu_pct: f32 = 0,
    /// Process peak RSS in MiB (getrusage maxrss is KiB on Linux).
    proc_rss_mb: u32 = 0,
    /// Live process count.
    procs: u32 = 0,
    /// Host uptime in whole seconds.
    uptime_s: u64 = 0,
};
```

`sample` fails closed: a failing `sysinfo` or `getrusage` leaves the derived fields at zero rather than reporting a guess (`src/util/sys_metrics.zig:46`, `:60`). The admin console status snapshot is the caller (`src/server/admin_console.zig:201`). The module is Linux-only by design and owns no per-container or disk statistics (`src/util/sys_metrics.zig:6`).

## Comptime TOML binder

`toml_bind.zig` is what makes a new operator tunable one struct field instead of a parse arm (ADR 0021 decision 1, `docs/adr/0021-config-driven-game-modes.md:46`). It walks `std.meta.fields` of the destination type: a struct field is a `[section]`, dotted names recurse, a non-struct field is a root key when `allow_root`, and the field's type drives parsing (`src/util/toml_bind.zig:3`). An `?T` field means unset, which is what the precedence merge keys on. The entry point (`src/util/toml_bind.zig:33`):

```zig
pub fn bind(comptime T: type, dst: *T, src: []const u8, a: std.mem.Allocator) !void {
    var section: []const u8 = "";
    var lines = std.mem.splitScalar(u8, src, '\n');
```

Unknown sections and keys abort with `error.UnknownTomlKey` and a warning line instead of silently defaulting (`src/util/toml_bind.zig:120`). Optional per-struct comptime declarations carry the rest: `toml_label`, `allow_root`, `root_sections`, `aliases`, `ranges` clamps applied at parse (`:208`), and `enum_by_name`, which validates a string against enum variant names case-insensitively and stores the canonical `@tagName` spelling (`:224`). Floats reject `nan`/`inf` because a NaN makes every later comparison false (`:194`); integer overflow propagates rather than wrapping (`:193`). The supported subset is `[section]` plus scalar `key = value`: no arrays and no tables-in-tables (`src/util/toml_bind.zig:23`), which is why list-shaped policy rides as a caller-split string (see [config.md](config.md)).

Precedence is not encoded in the binder, it is encoded in call order, because the merge copies only non-null overlay fields (`src/util/toml_bind.zig:244`):

```zig
pub fn mergeOverlay(comptime T: type, dst: *T, o: anytype) void {
    inline for (std.meta.fields(T)) |f| {
        if (comptime isStruct(f.type)) {
            mergeOverlay(f.type, &@field(dst, f.name), &@field(o, f.name));
        } else if (@field(o, f.name)) |v| {
            @field(dst, f.name) = v;
        }
    }
}
```

The overlay type is hand-written next to its destination rather than produced by a generic `Overlay(T)`, because Zig 0.16 `@Struct` cannot lay out the recursive anonymous type that would need (`src/util/toml_bind.zig:238`); `src/ecs/rules.zig` holds the `Rules`/`RulesOverlay` pair and a comptime parity test that fails when the two drift. `bind` dupes string values through the caller allocator, and callers own the result through their own arena (`src/util/toml_bind.zig:30`). Where a bound value is a sim floor rather than an override, stock per-entity data still wins (ADR 0021 decision 5, `docs/adr/0021-config-driven-game-modes.md:97`); the binder itself carries no opinion on that ordering.

## See also

- [config.md](config.md) - the surfaces that call `bind`/`mergeOverlay`, and the load order.
- [ecs.md](ecs.md) - `Rules` consumption and the systems that run under `forRanges`.
- [apm.md](apm.md) - the sections timed by `clock.monoNs`.
- [`docs/STD_ABSTRACTIONS.md`](../STD_ABSTRACTIONS.md) - where high-level `std.Io` is used versus the remaining thin posix.
- [`ADR 0021`](../adr/0021-config-driven-game-modes.md) - why the reflected binder replaced hand-written key chains.
