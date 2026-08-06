//! Monotonic nanoseconds and best-effort sleep.
//!
//! Leaf timing primitive: used by net resend, tick pacing, and APM sections.
//! Lives in util so litenet/server do not depend on the metrics package (apm).
//!
//! Production reads CLOCK_MONOTONIC via `std.posix.system` (vDSO on Linux).
//! monoNs is on the per-packet hot path: do not construct `Io.Threaded` here.
//! Deterministic simulation enables a virtual clock (seed-driven, no wall time).

const std = @import("std");
const posix = std.posix;

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

/// Restore real CLOCK_MONOTONIC.
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

/// Monotonic nanoseconds since an arbitrary epoch, or virtual clock value.
pub fn monoNs() u64 {
    if (virtual_active.load(.acquire)) return virtual_ns.load(.acquire);
    var ts: posix.timespec = undefined;
    if (posix.system.clock_gettime(posix.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
}

/// Unix seconds. Only for values that must survive a restart (ban expiry); the
/// monotonic clock is the right one for anything measuring elapsed time.
pub fn wallSeconds() i64 {
    var ts: posix.timespec = undefined;
    if (posix.system.clock_gettime(posix.CLOCK.REALTIME, &ts) != 0) return 0;
    return @intCast(ts.sec);
}

/// Best-effort sleep for `ns` nanoseconds. Under virtual clock, advances time
/// by `ns` and returns immediately (no real sleep).
pub fn sleepNs(ns: u64) void {
    if (virtual_active.load(.acquire)) {
        _ = virtual_ns.fetchAdd(ns, .acq_rel);
        return;
    }
    if (ns == 0) return;
    var req = posix.timespec{
        .sec = @intCast(ns / 1_000_000_000),
        .nsec = @intCast(ns % 1_000_000_000),
    };
    var rem: posix.timespec = undefined;
    while (true) {
        const rc = posix.system.nanosleep(&req, &rem);
        if (posix.errno(rc) != .INTR) return;
        req = rem;
    }
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
