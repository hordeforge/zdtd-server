//! Monotonic nanoseconds for section timing (Linux M0).

const std = @import("std");
const linux = std.os.linux;

/// CLOCK_MONOTONIC wall time in nanoseconds since an arbitrary epoch.
pub fn monoNs() u64 {
    var ts: linux.timespec = undefined;
    const rc = linux.clock_gettime(.MONOTONIC, &ts);
    if (linux.errno(rc) != .SUCCESS) return 0;
    const sec: u64 = @intCast(ts.sec);
    const nsec: u64 = @intCast(ts.nsec);
    return sec *% 1_000_000_000 +% nsec;
}

/// Best-effort sleep for `ns` nanoseconds (Linux nanosleep).
pub fn sleepNs(ns: u64) void {
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
    const a = monoNs();
    var i: u32 = 0;
    while (i < 10000) : (i += 1) {}
    const b = monoNs();
    try std.testing.expect(b >= a);
}
