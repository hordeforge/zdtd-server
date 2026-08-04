//! Thin jobs helper: run work over a slot range and wait.
//! Wraps util/parallel (persistent pool). No heap; serial when pool unavailable.

const parallel = @import("../util/parallel.zig");

/// Run `work(ctx, begin, end)` over `[0, total)` (parallel when beneficial).
pub fn forSlotRange(
    total: usize,
    ctx: anytype,
    comptime work: *const fn (@TypeOf(ctx), begin: usize, end: usize) void,
) void {
    parallel.forRanges(total, ctx, work);
}

const std = @import("std");

test "jobs forSlotRange noop empty" {
    var calls: usize = 0;
    const Ctx = struct {
        calls: *usize,
        fn work(ctx: @This(), _: usize, _: usize) void {
            ctx.calls.* += 1;
        }
    };
    forSlotRange(0, Ctx{ .calls = &calls }, Ctx.work);
    try std.testing.expectEqual(@as(usize, 0), calls);
}

test "jobs forSlotRange covers total" {
    // Atomic so the test stays correct if total ever exceeds min_parallel_items.
    var hits: std.atomic.Value(usize) = .init(0);
    const Ctx = struct {
        hits: *std.atomic.Value(usize),
        fn work(ctx: @This(), begin: usize, end: usize) void {
            _ = ctx.hits.fetchAdd(end - begin, .monotonic);
        }
    };
    forSlotRange(17, Ctx{ .hits = &hits }, Ctx.work);
    try std.testing.expectEqual(@as(usize, 17), hits.load(.monotonic));
}
