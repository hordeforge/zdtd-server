//! Monotonic counters and latency histograms for zdtd (not 7dtd-apm).

const std = @import("std");

/// Named counters owned by the single-threaded game loop. These are plain u64
/// values, so callers must synchronize any access from other threads.
pub const CounterId = enum(u16) {
    ticks,
    net_packets_in,
    net_packets_out,
    net_bytes_in,
    net_bytes_out,
    entities_ticked,
    packages_encoded,
    packages_broadcast,
    join_ok,
    join_fail,
    net_poll_errors,
    net_payload_errors,
    net_send_errors,
    reliable_window_drops,
    persistence_errors,
    stale_peers_reaped,
    stream_errors,
    /// Main loop fell behind the 50 ms tick budget (run path only).
    tick_overruns,
    /// Package body encode failed (omit/skip path; not a send error).
    encode_errors,
    /// C2S dropped by join-phase gate (unjoined peer, non-handshake package).
    phase_rejects,
    /// C2S dropped by ownership / bag / entity id mismatch.
    ownership_rejects,
    /// C2S dropped by reach / range / damage-cap bounds.
    bounds_rejects,
    _,
};

pub const counters_len: usize = @typeInfo(CounterId).@"enum".fields.len;

pub const Counters = struct {
    values: [counters_len]u64 = .{0} ** counters_len,

    pub fn add(self: *Counters, id: CounterId, n: u64) void {
        const i: usize = @intFromEnum(id);
        if (i < counters_len) self.values[i] +%= n;
    }

    pub fn inc(self: *Counters, id: CounterId) void {
        self.add(id, 1);
    }

    pub fn get(self: *const Counters, id: CounterId) u64 {
        const i: usize = @intFromEnum(id);
        return if (i < counters_len) self.values[i] else 0;
    }

    pub fn reset(self: *Counters) void {
        @memset(&self.values, 0);
    }
};

/// Fixed log2 histogram for latency in nanoseconds (power-of-two buckets).
/// Bucket k covers [2^k, 2^(k+1)) ns for k in 0..63.
pub const LatencyHist = struct {
    buckets: [64]u64 = .{0} ** 64,
    count: u64 = 0,
    sum_ns: u64 = 0,
    max_ns: u64 = 0,

    pub fn observe(self: *LatencyHist, ns: u64) void {
        self.count +%= 1;
        self.sum_ns +%= ns;
        if (ns > self.max_ns) self.max_ns = ns;
        const b: u6 = if (ns == 0) 0 else @intCast(@min(63, 63 - @clz(ns)));
        self.buckets[b] +%= 1;
    }

    pub fn meanNs(self: *const LatencyHist) u64 {
        if (self.count == 0) return 0;
        return self.sum_ns / self.count;
    }

    /// Approximate percentile: walk buckets until cumulative count >= target.
    pub fn percentileNs(self: *const LatencyHist, p: f64) u64 {
        if (self.count == 0) return 0;
        const target: u64 = @intFromFloat(@ceil(@as(f64, @floatFromInt(self.count)) * p / 100.0));
        var acc: u64 = 0;
        for (self.buckets, 0..) |c, i| {
            acc +%= c;
            if (acc >= target) {
                // bucket mid estimate
                const lo: u64 = if (i == 0) 0 else (@as(u64, 1) << @intCast(i));
                const hi: u64 = if (i >= 63) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(i + 1));
                return lo + (hi -% lo) / 2;
            }
        }
        return self.max_ns;
    }

    pub fn reset(self: *LatencyHist) void {
        @memset(&self.buckets, 0);
        self.count = 0;
        self.sum_ns = 0;
        self.max_ns = 0;
    }
};

test "counter inc" {
    var c: Counters = .{};
    c.inc(.ticks);
    c.add(.net_bytes_out, 100);
    try std.testing.expectEqual(@as(u64, 1), c.get(.ticks));
    try std.testing.expectEqual(@as(u64, 100), c.get(.net_bytes_out));
}

test "hist percentile" {
    var h: LatencyHist = .{};
    var i: u64 = 0;
    while (i < 100) : (i += 1) h.observe(1_000_000); // 1 ms each
    try std.testing.expectEqual(@as(u64, 100), h.count);
    try std.testing.expect(h.meanNs() == 1_000_000);
    const p50 = h.percentileNs(50);
    try std.testing.expect(p50 >= 500_000 and p50 <= 2_000_000);
}
