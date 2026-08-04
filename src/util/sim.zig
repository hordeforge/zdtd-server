//! Deterministic simulation mode: virtual clock + serial parallel ranges.
//!
//! Enable at the start of a DST harness so monoNs/sleepNs and forRanges are
//! fully controlled by the test. Production never calls this; the default is
//! wall clock + optional OS threads.
//!
//! Offline Game paths (port == 0) call enable/disable automatically so
//! scenarios and unit tests share one seed-stable mono clock without each
//! test wiring sim mode by hand.
//!
//! A process-wide run seed is stored so harnesses and failure logs can name
//! the single value that should reproduce a run (pair with virtual clock).

const clock = @import("clock.zig");
const parallel = @import("parallel.zig");
const std = @import("std");

/// Default virtual epoch for harnesses (1 s). Avoid 0 so age/stale math that
/// subtracts from monoNs stays well-defined without underflow edge cases.
pub const default_start_ns: u64 = 1_000_000_000;

/// Default offline / DST run seed when the caller does not supply one.
pub const default_seed: u64 = 1;

/// Stock main-loop tick length (20 TPS). Formula matches `protocol.tick_ns`
/// (util is a leaf package and cannot import protocol). Use with advanceTick
/// for lock/peer stale windows and resend deadlines under the virtual clock.
pub const tick_ns: u64 = 1_000_000_000 / 20;

/// Process-wide run seed for DST replay. Atomic so a harness can read it from
/// a failure path without races against enable/disable on another thread.
var run_seed: std.atomic.Value(u64) = .init(0);

/// Enter deterministic sim: virtual mono clock at `start_ns`, force serial work.
/// Does not change the stored run seed (use setSeed / enableSeeded).
pub fn enable(start_ns: u64) void {
    clock.enableVirtual(start_ns);
    parallel.setForceSerial(true);
}

/// Enter sim mode and record `seed` as the process-wide run seed for replay.
pub fn enableSeeded(start_ns: u64, seed: u64) void {
    setSeed(seed);
    enable(start_ns);
}

/// Leave sim mode (real clock, parallel ranges allowed again). Clears the run
/// seed so a later production path does not inherit a harness seed.
pub fn disable() void {
    parallel.setForceSerial(false);
    clock.disableVirtual();
    run_seed.store(0, .release);
}

/// Record the seed that should fully determine a simulated run.
pub fn setSeed(seed: u64) void {
    run_seed.store(seed, .release);
}

/// Current run seed (0 when unset / after disable).
pub fn getSeed() u64 {
    return run_seed.load(.acquire);
}

/// True when both virtual clock and force-serial are active.
pub fn isEnabled() bool {
    return clock.isVirtual() and parallel.isForceSerial();
}

/// Advance the virtual clock by one main-loop tick (no-op when not virtual).
pub fn advanceTick() void {
    clock.advanceNs(tick_ns);
}

/// Advance by `n` main-loop ticks (no-op when not virtual).
pub fn advanceTicks(n: u32) void {
    if (n == 0) return;
    clock.advanceNs(tick_ns *% @as(u64, n));
}

test "sim enable couples clock and serial" {
    defer disable();
    enable(1_000);
    try std.testing.expect(isEnabled());
    try std.testing.expectEqual(@as(u64, 1_000), clock.monoNs());
    clock.sleepNs(50);
    try std.testing.expectEqual(@as(u64, 1_050), clock.monoNs());
    disable();
    try std.testing.expect(!isEnabled());
}

test "sim advanceTick steps 50ms" {
    defer disable();
    enable(default_start_ns);
    advanceTick();
    try std.testing.expectEqual(default_start_ns + tick_ns, clock.monoNs());
    advanceTicks(3);
    try std.testing.expectEqual(default_start_ns + tick_ns * 4, clock.monoNs());
}

test "sim seed is stored and cleared on disable" {
    defer disable();
    enableSeeded(default_start_ns, 0xC0FFEE);
    try std.testing.expect(isEnabled());
    try std.testing.expectEqual(@as(u64, 0xC0FFEE), getSeed());
    setSeed(42);
    try std.testing.expectEqual(@as(u64, 42), getSeed());
    disable();
    try std.testing.expectEqual(@as(u64, 0), getSeed());
}
