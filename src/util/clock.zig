//! Monotonic nanoseconds and best-effort sleep via Zig 0.16 `std.Io`.
//!
//! Leaf timing primitive: used by net resend, tick pacing, and APM sections.
//! Lives in util so litenet/server do not depend on the metrics package (apm).
//!
//! Production uses `Io.Clock.awake` (Linux CLOCK_MONOTONIC). Deterministic
//! simulation enables a virtual clock so monoNs/sleepNs are fully seed-driven.

const std = @import("std");
const Io = std.Io;

/// Virtual clock state. When `active`, monoNs/sleepNs never touch the OS.
/// Atomic so enable/disable from a test harness is race-free vs readers.
var virtual_active: std.atomic.Value(bool) = .init(false);
var virtual_ns: std.atomic.Value(u64) = .init(0);

/// True when monoNs/sleepNs are driven by the virtual clock (sim mode).
pub fn isVirtual() bool {
    return virtual_active.load(.acquire);
}

/// Switch to a virtual clock starting at `start_ns`. Subsequent monoNs/sleepNs
/// ignore wall time until disableVirtual().
pub fn enableVirtual(start_ns: u64) void {
    virtual_ns.store(start_ns, .release);
    virtual_active.store(true, .release);
}

/// Restore real Io.Clock.awake.
pub fn disableVirtual() void {
    virtual_active.store(false, .release);
}

/// Set absolute virtual time (no-op when not virtual).
pub fn setVirtualNs(ns: u64) void {
    if (!virtual_active.load(.acquire)) return;
    virtual_ns.store(ns, .release);
}

/// Advance virtual time by `delta_ns` (no-op when not virtual).
pub fn advanceNs(delta_ns: u64) void {
    if (!virtual_active.load(.acquire)) return;
    _ = virtual_ns.fetchAdd(delta_ns, .acq_rel);
}

fn threadedIo() Io.Threaded {
    return Io.Threaded.init(std.heap.page_allocator, .{});
}

/// Monotonic nanoseconds since an arbitrary epoch (Io.Clock.awake),
/// or the virtual clock value when enableVirtual is active.
pub fn monoNs() u64 {
    if (virtual_active.load(.acquire)) return virtual_ns.load(.acquire);
    var threaded = threadedIo();
    defer threaded.deinit();
    const ts = Io.Clock.awake.now(threaded.io());
    if (ts.nanoseconds <= 0) return 0;
    return @intCast(ts.nanoseconds);
}

/// Best-effort sleep for `ns` nanoseconds. Under virtual clock, advances time
/// by `ns` and returns immediately (no real sleep).
pub fn sleepNs(ns: u64) void {
    if (virtual_active.load(.acquire)) {
        _ = virtual_ns.fetchAdd(ns, .acq_rel);
        return;
    }
    if (ns == 0) return;
    var threaded = threadedIo();
    defer threaded.deinit();
    const dur: Io.Clock.Duration = .{
        .raw = .{ .nanoseconds = @intCast(ns) },
        .clock = .awake,
    };
    dur.sleep(threaded.io()) catch {};
}

test "monoNs advances" {
    disableVirtual();
    const a = monoNs();
    var i: u32 = 0;
    while (i < 10000) : (i += 1) {}
    const b = monoNs();
    try std.testing.expect(b >= a);
}

test "virtual clock is deterministic and sleep advances" {
    defer disableVirtual();
    enableVirtual(1_000_000_000);
    try std.testing.expect(isVirtual());
    try std.testing.expectEqual(@as(u64, 1_000_000_000), monoNs());
    sleepNs(50_000_000);
    try std.testing.expectEqual(@as(u64, 1_050_000_000), monoNs());
    advanceNs(10);
    try std.testing.expectEqual(@as(u64, 1_050_000_010), monoNs());
    setVirtualNs(42);
    try std.testing.expectEqual(@as(u64, 42), monoNs());
}

test "virtual then disable restores real clock" {
    defer disableVirtual();
    enableVirtual(0);
    try std.testing.expect(isVirtual());
    disableVirtual();
    try std.testing.expect(!isVirtual());
    _ = monoNs();
}
