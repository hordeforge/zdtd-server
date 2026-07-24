//! Scoped wall-clock sections for tick phases (zdtd-native; not 7dtd-apm).

const std = @import("std");
const metrics = @import("metrics.zig");
const clock = @import("clock.zig");

pub const Section = enum(u8) {
    tick_total,
    net_poll,
    sim_entities,
    replicate,
    chunk_stream,
    save_io,
    _,
};

pub const sections_len: usize = @typeInfo(Section).@"enum".fields.len;

pub const Profiler = struct {
    hist: [sections_len]metrics.LatencyHist = [_]metrics.LatencyHist{.{}} ** sections_len,
    open: [sections_len]?u64 = [_]?u64{null} ** sections_len,

    pub fn begin(self: *Profiler, s: Section) void {
        const i: usize = @intFromEnum(s);
        if (i >= sections_len) return;
        self.open[i] = clock.monoNs();
    }

    pub fn end(self: *Profiler, s: Section) void {
        const i: usize = @intFromEnum(s);
        if (i >= sections_len) return;
        const start = self.open[i] orelse return;
        self.open[i] = null;
        const now = clock.monoNs();
        const dt: u64 = if (now >= start) now - start else 0;
        self.hist[i].observe(dt);
    }

    pub fn histOf(self: *const Profiler, s: Section) *const metrics.LatencyHist {
        return &self.hist[@intFromEnum(s)];
    }

    pub fn reset(self: *Profiler) void {
        for (&self.hist) |*h| h.reset();
        @memset(&self.open, null);
    }
};

pub const Scope = struct {
    p: *Profiler,
    s: Section,

    pub fn end(self: Scope) void {
        self.p.end(self.s);
    }
};

pub fn scope(p: *Profiler, s: Section) Scope {
    p.begin(s);
    return .{ .p = p, .s = s };
}

test "profiler records" {
    var p: Profiler = .{};
    const sc = scope(&p, .tick_total);
    var x: u64 = 0;
    var i: u32 = 0;
    while (i < 1000) : (i += 1) x +%= i;
    sc.end();
    try std.testing.expect(p.histOf(.tick_total).count == 1);
    try std.testing.expect(x > 0);
}
