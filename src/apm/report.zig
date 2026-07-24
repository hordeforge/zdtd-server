//! Snapshot dump: human text or JSON lines for loadgen-side compare.

const std = @import("std");
const metrics = @import("metrics.zig");
const profiler = @import("profiler.zig");
const clock = @import("clock.zig");

pub const Snapshot = struct {
    counters: metrics.Counters = .{},
    profiler: profiler.Profiler = .{},
    wall_ns: u64 = 0,

    pub fn captureWall(self: *Snapshot) void {
        self.wall_ns = clock.monoNs();
    }
};

pub fn writeText(s: *const Snapshot, w: *std.Io.Writer) !void {
    try w.print("zdtd-apm snapshot wall_ns={d}\n", .{s.wall_ns});
    try w.print("counters:\n", .{});
    inline for (@typeInfo(metrics.CounterId).@"enum".fields) |f| {
        if (comptime f.name[0] == '_') {} else {
            const id: metrics.CounterId = @enumFromInt(f.value);
            try w.print("  {s}={d}\n", .{ f.name, s.counters.get(id) });
        }
    }
    try w.print("sections (count mean_ns p50_ns p99_ns max_ns):\n", .{});
    inline for (@typeInfo(profiler.Section).@"enum".fields) |f| {
        if (comptime f.name[0] == '_') {} else {
            const sec: profiler.Section = @enumFromInt(f.value);
            const h = s.profiler.histOf(sec);
            if (h.count != 0) {
                try w.print(
                    "  {s} {d} {d} {d} {d} {d}\n",
                    .{ f.name, h.count, h.meanNs(), h.percentileNs(50), h.percentileNs(99), h.max_ns },
                );
            }
        }
    }
}

pub fn writeJsonLine(s: *const Snapshot, w: *std.Io.Writer) !void {
    try w.print("{{\"type\":\"zdtd_apm\",\"wall_ns\":{d},\"counters\":{{", .{s.wall_ns});
    var first = true;
    inline for (@typeInfo(metrics.CounterId).@"enum".fields) |f| {
        if (comptime f.name[0] == '_') {} else {
            const id: metrics.CounterId = @enumFromInt(f.value);
            if (!first) try w.print(",", .{});
            first = false;
            try w.print("\"{s}\":{d}", .{ f.name, s.counters.get(id) });
        }
    }
    try w.print("}},\"sections\":{{", .{});
    first = true;
    inline for (@typeInfo(profiler.Section).@"enum".fields) |f| {
        if (comptime f.name[0] == '_') {} else {
            const sec: profiler.Section = @enumFromInt(f.value);
            const h = s.profiler.histOf(sec);
            if (h.count != 0) {
                if (!first) try w.print(",", .{});
                first = false;
                try w.print(
                    "\"{s}\":{{\"count\":{d},\"mean_ns\":{d},\"p50_ns\":{d},\"p99_ns\":{d},\"max_ns\":{d}}}",
                    .{ f.name, h.count, h.meanNs(), h.percentileNs(50), h.percentileNs(99), h.max_ns },
                );
            }
        }
    }
    try w.print("}}}}\n", .{});
}

test "report text non-empty" {
    var s: Snapshot = .{};
    s.counters.inc(.ticks);
    s.profiler.begin(.tick_total);
    s.profiler.end(.tick_total);
    s.captureWall();
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeText(&s, &w);
    try std.testing.expect(w.buffered().len > 20);
}
