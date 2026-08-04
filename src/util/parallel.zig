//! Parallel-for over dense slot ranges with a persistent worker pool.
//! Uses Zig 0.16 `std.Io` mutex/condition (no raw syscalls, no spawn-per-call).

const std = @import("std");
const builtin = @import("builtin");

pub const max_workers: usize = 8;
/// Skip threading below this many items (join cost > gain).
pub const min_parallel_items: usize = 24;

pub fn cpuWorkers() usize {
    if (builtin.single_threaded) return 1;
    const n = std.Thread.getCpuCount() catch 1;
    if (n < 1) return 1;
    return @min(n, max_workers);
}

pub const Range = struct {
    begin: usize,
    end: usize,
};

/// Split `[0, total)` into up to `workers` contiguous ranges (empty tails omitted).
pub fn splitRanges(total: usize, workers: usize, out: *[max_workers]Range) usize {
    if (total == 0 or workers == 0) return 0;
    const w = @min(workers, max_workers);
    const base = total / w;
    const rem = total % w;
    var i: usize = 0;
    var at: usize = 0;
    var produced: usize = 0;
    while (i < w) : (i += 1) {
        const len = base + @as(usize, if (i < rem) 1 else 0);
        if (len == 0) continue;
        out[produced] = .{ .begin = at, .end = at + len };
        at += len;
        produced += 1;
    }
    return produced;
}

const WorkFn = *const fn (*anyopaque, usize, usize) void;

const Job = struct {
    work: WorkFn = undefined,
    ctx: *anyopaque = undefined,
    begin: usize = 0,
    end: usize = 0,
};

const StartState = enum(u8) { unstarted, starting, started };

const Pool = struct {
    threaded: std.Io.Threaded = undefined,
    mutex: std.Io.Mutex = .init,
    work_cv: std.Io.Condition = .init,
    done_cv: std.Io.Condition = .init,
    jobs: [max_workers]Job = [_]Job{.{}} ** max_workers,
    job_n: usize = 0,
    outstanding: usize = 0,
    shutdown: bool = false,
    start_state: std.atomic.Value(StartState) = .init(.unstarted),
    /// True while a parallel dispatch owns `jobs`/`outstanding`; a nested or
    /// concurrent `run` degrades to serial instead of clobbering that state.
    in_run: std.atomic.Value(bool) = .init(false),
    threads: [max_workers]std.Thread = undefined,
    worker_n: usize = 0,

    fn io(self: *Pool) std.Io {
        return self.threaded.io();
    }

    fn ensureStarted(self: *Pool) void {
        if (builtin.single_threaded) return;
        if (self.start_state.load(.acquire) == .started) return;
        if (self.start_state.cmpxchgStrong(.unstarted, .starting, .acquire, .acquire) != null) {
            // Lost the init race: wait for the winner's .release publish.
            // Workers never reach here before their first job, and jobs only
            // dispatch after init completes, so this cannot self-deadlock.
            while (self.start_state.load(.acquire) != .started) std.Thread.yield() catch {};
            return;
        }
        // Once: Threaded for mutex/cond; workers = cpu-1. Workers observe a
        // fully initialized pool: everything written before Thread.spawn
        // happens-before the worker's first read.
        self.threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        const n = cpuWorkers();
        if (n > 1) {
            const want = n - 1;
            var i: usize = 0;
            while (i < want) : (i += 1) {
                self.threads[i] = std.Thread.spawn(.{}, workerMain, .{self}) catch |err| {
                    std.debug.print(
                        "zdtd: worker spawn failed: {s}; running with {d} of {d} workers\n",
                        .{ @errorName(err), self.worker_n, want },
                    );
                    break;
                };
                // Detach so process/test exit is not blocked waiting for idle
                // workers parked on work_cv (pool is process-lifetime).
                self.threads[i].detach();
                self.worker_n += 1;
            }
        }
        // Publishes threaded/worker_n to fast-path readers on other threads.
        self.start_state.store(.started, .release);
    }

    fn workerMain(self: *Pool) void {
        const iop = self.io();
        while (true) {
            self.mutex.lockUncancelable(iop);
            while (self.job_n == 0 and !self.shutdown) {
                self.work_cv.waitUncancelable(iop, &self.mutex);
            }
            if (self.shutdown and self.job_n == 0) {
                self.mutex.unlock(iop);
                return;
            }
            self.job_n -= 1;
            const job = self.jobs[self.job_n];
            self.mutex.unlock(iop);
            job.work(job.ctx, job.begin, job.end);
            self.mutex.lockUncancelable(iop);
            self.outstanding -= 1;
            if (self.outstanding == 0) self.done_cv.signal(iop);
            self.mutex.unlock(iop);
        }
    }

    fn run(self: *Pool, total: usize, work: WorkFn, ctx: *anyopaque) void {
        if (total == 0) return;
        self.ensureStarted();

        // Own the dispatch slot for the whole call (serial or parallel). Nested
        // forRanges from a worker, or a second thread, must not touch
        // jobs/outstanding or start a second parallel wave.
        // acq_rel: publish prior writes to the serial nested path; acquire the
        // outer wave's ownership when winning the swap.
        if (self.in_run.swap(true, .acq_rel)) {
            work(ctx, 0, total);
            return;
        }
        defer self.in_run.store(false, .release);

        const workers = if (self.worker_n == 0) 1 else self.worker_n + 1;
        if (builtin.single_threaded or workers <= 1 or total < min_parallel_items or self.worker_n == 0) {
            work(ctx, 0, total);
            return;
        }

        var ranges: [max_workers]Range = undefined;
        const n = splitRanges(total, workers, &ranges);
        if (n <= 1) {
            work(ctx, 0, total);
            return;
        }

        const iop = self.io();
        self.mutex.lockUncancelable(iop);
        self.job_n = 0;
        self.outstanding = 0;
        var i: usize = 1;
        while (i < n) : (i += 1) {
            self.jobs[self.job_n] = .{
                .work = work,
                .ctx = ctx,
                .begin = ranges[i].begin,
                .end = ranges[i].end,
            };
            self.job_n += 1;
            self.outstanding += 1;
        }
        self.work_cv.broadcast(iop);
        self.mutex.unlock(iop);

        work(ctx, ranges[0].begin, ranges[0].end);

        self.mutex.lockUncancelable(iop);
        while (self.outstanding > 0) {
            self.done_cv.waitUncancelable(iop, &self.mutex);
        }
        self.mutex.unlock(iop);
    }
};

var global_pool: Pool = .{};

/// When true, forRanges always runs serially on the calling thread.
/// Use under deterministic simulation so interleaving cannot depend on the OS
/// scheduler. Production leaves this false (default).
var force_serial: std.atomic.Value(bool) = .init(false);

/// Force serial forRanges (deterministic sim / DST). Pair with clock.enableVirtual.
pub fn setForceSerial(on: bool) void {
    force_serial.store(on, .release);
}

pub fn isForceSerial() bool {
    return force_serial.load(.acquire);
}

/// Process-wide mutex usable without threading an `std.Io` through callers
/// (Zig 0.16 dropped `std.Thread.Mutex`; `std.Io.Mutex` needs an io for the
/// contended futex path, which the pool's `Threaded` provides). No-op in
/// single-threaded builds where the pool never runs workers.
pub const IoMutex = struct {
    inner: std.Io.Mutex = .init,

    pub fn lock(self: *IoMutex) void {
        if (builtin.single_threaded) return;
        global_pool.ensureStarted();
        self.inner.lockUncancelable(global_pool.io());
    }

    pub fn unlock(self: *IoMutex) void {
        if (builtin.single_threaded) return;
        // Same ensureStarted as lock: unlock must not touch undefined Threaded.io
        // if a caller mismatched the pair (or raced first lock init).
        global_pool.ensureStarted();
        self.inner.unlock(global_pool.io());
    }
};

/// Run `work(ctx, begin, end)` over `[0, total)` in parallel when beneficial.
/// `work` must be thread-safe for disjoint ranges.
/// When setForceSerial(true), always serial (slot order 0..total).
pub fn forRanges(
    total: usize,
    ctx: anytype,
    comptime work: *const fn (@TypeOf(ctx), begin: usize, end: usize) void,
) void {
    if (total == 0) return;
    const Ctx = @TypeOf(ctx);
    const Wrapper = struct {
        fn entry(raw: *anyopaque, begin: usize, end: usize) void {
            const c: *const Ctx = @ptrCast(@alignCast(raw));
            work(c.*, begin, end);
        }
    };
    var ctx_local = ctx;
    if (force_serial.load(.acquire)) {
        work(ctx_local, 0, total);
        return;
    }
    global_pool.run(total, Wrapper.entry, @ptrCast(&ctx_local));
}

test "split ranges cover total" {
    var ranges: [max_workers]Range = undefined;
    const n = splitRanges(100, 4, &ranges);
    try std.testing.expect(n >= 1);
    try std.testing.expectEqual(@as(usize, 0), ranges[0].begin);
    try std.testing.expectEqual(@as(usize, 100), ranges[n - 1].end);
    var sum: usize = 0;
    for (ranges[0..n]) |r| sum += r.end - r.begin;
    try std.testing.expectEqual(@as(usize, 100), sum);
}

test "forRanges serial when small" {
    var hits: usize = 0;
    const Ctx = struct {
        hits: *usize,
        fn work(ctx: @This(), begin: usize, end: usize) void {
            ctx.hits.* += end - begin;
        }
    };
    forRanges(10, Ctx{ .hits = &hits }, Ctx.work);
    try std.testing.expectEqual(@as(usize, 10), hits);
}

test "forRanges parallel covers all" {
    if (builtin.single_threaded) return;
    var hits: [64]u8 = .{0} ** 64;
    const Ctx = struct {
        hits: []u8,
        fn work(ctx: @This(), begin: usize, end: usize) void {
            var i = begin;
            while (i < end) : (i += 1) ctx.hits[i] = 1;
        }
    };
    forRanges(64, Ctx{ .hits = hits[0..] }, Ctx.work);
    for (hits) |h| try std.testing.expectEqual(@as(u8, 1), h);
}

test "forRanges force serial covers all" {
    defer setForceSerial(false);
    setForceSerial(true);
    try std.testing.expect(isForceSerial());
    var hits: [64]u8 = .{0} ** 64;
    const Ctx = struct {
        hits: []u8,
        fn work(ctx: @This(), begin: usize, end: usize) void {
            var i = begin;
            while (i < end) : (i += 1) ctx.hits[i] = 1;
        }
    };
    forRanges(64, Ctx{ .hits = hits[0..] }, Ctx.work);
    for (hits) |h| try std.testing.expectEqual(@as(u8, 1), h);
}

test "forRanges nested reentry stays serial and covers all" {
    // Nested forRanges while outer holds in_run must not clobber jobs/outstanding.
    // Separate arrays so outer workers (disjoint ranges) never race nested writes.
    if (builtin.single_threaded) return;
    var outer_hits: [64]u8 = .{0} ** 64;
    var nested_hits: [64]u8 = .{0} ** 64;
    const Outer = struct {
        outer: []u8,
        nested: []u8,
        fn work(ctx: @This(), begin: usize, end: usize) void {
            const Inner = struct {
                nested: []u8,
                fn work(ic: @This(), b: usize, e: usize) void {
                    var i = b;
                    while (i < e) : (i += 1) ic.nested[i] = 1;
                }
            };
            // Only rank-0 range nests (once); serial path covers full nested[].
            if (begin == 0) {
                forRanges(64, Inner{ .nested = ctx.nested }, Inner.work);
            }
            var i = begin;
            while (i < end) : (i += 1) ctx.outer[i] = 1;
        }
    };
    forRanges(64, Outer{ .outer = outer_hits[0..], .nested = nested_hits[0..] }, Outer.work);
    for (outer_hits) |h| try std.testing.expectEqual(@as(u8, 1), h);
    for (nested_hits) |h| try std.testing.expectEqual(@as(u8, 1), h);
}
