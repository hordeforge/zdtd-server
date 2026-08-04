//! Monotonic nanoseconds and best-effort sleep (Linux).
//!
//! Leaf timing primitive: used by net resend, tick pacing, and APM sections.
//! Lives in util so litenet/server do not depend on the metrics package (apm).
//!
//! Production uses CLOCK_MONOTONIC. Deterministic simulation enables a virtual
//! clock so monoNs/sleepNs are fully seed-driven (no wall-clock reads).

const std = @import("std");
const linux = std.os.linux;

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

/// Restore real CLOCK_MONOTONIC / nanosleep.
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

/// CLOCK_MONOTONIC wall time in nanoseconds since an arbitrary epoch,
/// or the virtual clock value when enableVirtual is active.
pub fn monoNs() u64 {
    if (virtual_active.load(.acquire)) return virtual_ns.load(.acquire);
    var ts: linux.timespec = undefined;
    const rc = linux.clock_gettime(.MONOTONIC, &ts);
    if (linux.errno(rc) != .SUCCESS) return 0;
    const sec: u64 = @intCast(ts.sec);
    const nsec: u64 = @intCast(ts.nsec);
    return sec *% 1_000_000_000 +% nsec;
}

/// Best-effort sleep for `ns` nanoseconds. Under virtual clock, advances time
/// by `ns` and returns immediately (no real sleep).
pub fn sleepNs(ns: u64) void {
    if (virtual_active.load(.acquire)) {
        _ = virtual_ns.fetchAdd(ns, .acq_rel);
        return;
    }
    var req = linux.timespec{
        .sec = @intCast(ns / 1_000_000_000),
        .nsec = @intCast(ns % 1_000_000_000),
    };
    var rem: linux.timespec = undefined;
    while (true) {
        const rc = linux.nanosleep(&req, &rem);
        if (linux.errno(rc) != .INTR) return;
        req = rem;
    }
}

test "monoNs advances" {
    // Real clock path (virtual may be left on by a prior test; force real).
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
    // Real mono is typically far above 0 after boot; just ensure it runs.
    _ = monoNs();
}
