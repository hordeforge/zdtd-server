//! Deterministic simulation mode: virtual clock + serial parallel ranges.
//!
//! Enable at the start of a DST harness so monoNs/sleepNs and forRanges are
//! fully controlled by the test. Production never calls this; the default is
//! wall clock + optional OS threads.

const clock = @import("clock.zig");
const parallel = @import("parallel.zig");

/// Enter deterministic sim: virtual mono clock at `start_ns`, force serial work.
pub fn enable(start_ns: u64) void {
    clock.enableVirtual(start_ns);
    parallel.setForceSerial(true);
}

/// Leave sim mode (real clock, parallel ranges allowed again).
pub fn disable() void {
    parallel.setForceSerial(false);
    clock.disableVirtual();
}

/// True when both virtual clock and force-serial are active.
pub fn isEnabled() bool {
    return clock.isVirtual() and parallel.isForceSerial();
}

const std = @import("std");

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
