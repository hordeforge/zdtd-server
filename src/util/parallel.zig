//! Lightweight parallel-for over dense slot ranges (no pool heap; spawn/join per call).
//! Used by ECS systems when work is large enough to amortize thread costs.

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

/// Run `work(ctx, begin, end)` over `[0, total)` in parallel when beneficial.
/// `work` must be thread-safe for disjoint ranges.
pub fn forRanges(
    total: usize,
    ctx: anytype,
    comptime work: *const fn (@TypeOf(ctx), begin: usize, end: usize) void,
) void {
    if (total == 0) return;
    const workers = cpuWorkers();
    if (builtin.single_threaded or workers <= 1 or total < min_parallel_items) {
        work(ctx, 0, total);
        return;
    }

    var ranges: [max_workers]Range = undefined;
    const n = splitRanges(total, workers, &ranges);
    if (n <= 1) {
        work(ctx, 0, total);
        return;
    }

    const Worker = struct {
        ctx: @TypeOf(ctx),
        begin: usize,
        end: usize,
        fn entry(self: *@This()) void {
            work(self.ctx, self.begin, self.end);
        }
    };

    var jobs: [max_workers]Worker = undefined;
    var threads: [max_workers]std.Thread = undefined;
    var spawned: usize = 0;
    // Main thread runs range 0; others on workers.
    var i: usize = 1;
    while (i < n) : (i += 1) {
        jobs[i] = .{ .ctx = ctx, .begin = ranges[i].begin, .end = ranges[i].end };
        threads[i] = std.Thread.spawn(.{}, Worker.entry, .{&jobs[i]}) catch {
            // Fallback: run remaining serially on this thread.
            var j = i;
            while (j < n) : (j += 1) {
                work(ctx, ranges[j].begin, ranges[j].end);
            }
            break;
        };
        spawned += 1;
    }
    work(ctx, ranges[0].begin, ranges[0].end);
    i = 1;
    while (i <= spawned) : (i += 1) {
        threads[i].join();
    }
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
