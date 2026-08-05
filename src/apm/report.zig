//! Snapshot dump: human text or JSON lines for loadgen-side compare.

const std = @import("std");
const metrics = @import("metrics.zig");
const profiler = @import("profiler.zig");
const clock = @import("../util/clock.zig");

/// Instantaneous load gauges (not cumulative). Filled by the game before dump.
pub const OpsGauges = struct {
    tick: u64 = 0,
    joined: u32 = 0,
    entered: u32 = 0,
    peers_alive: u32 = 0,
    zombies: u32 = 0,
    chunks: u32 = 0,
};

pub const Snapshot = struct {
    counters: metrics.Counters = .{},
    profiler: profiler.Profiler = .{},
    wall_ns: u64 = 0,
    /// When set, writeJsonLine embeds an `"ops"` object for scrapers.
    ops: ?OpsGauges = null,

    pub fn captureWall(self: *Snapshot) void {
        self.wall_ns = clock.monoNs();
    }
};

/// Widest decimal rendering of a u64 (no separators).
const u64_digits: usize = 20;

/// Worst-case bytes `writeText` / `writeJsonLine` can emit, derived from the
/// enum field names. Call sites size their fixed buffers from these so adding a
/// counter or section can never silently truncate a dump.
fn textBound() usize {
    var n: usize = "zdtd-apm snapshot wall_ns=\n".len + u64_digits + "counters:\n".len +
        "sections (count mean_ns p50_ns p99_ns max_ns):\n".len;
    for (@typeInfo(metrics.CounterId).@"enum".fields) |f| {
        if (f.name[0] == '_') continue;
        n += 2 + f.name.len + 1 + u64_digits + 1;
    }
    for (@typeInfo(profiler.Section).@"enum".fields) |f| {
        if (f.name[0] == '_') continue;
        n += 2 + f.name.len + 5 * (1 + u64_digits) + 1;
    }
    return n;
}

fn jsonBound() usize {
    var n: usize = "{\"type\":\"zdtd_apm\",\"wall_ns\":,\"counters\":{},\"sections\":{}}\n".len + u64_digits +
        ",\"ops\":{\"tick\":,\"joined\":,\"entered\":,\"peers_alive\":,\"zombies\":,\"chunks\":}".len + 6 * u64_digits;
    for (@typeInfo(metrics.CounterId).@"enum".fields) |f| {
        if (f.name[0] == '_') continue;
        n += 1 + 2 + f.name.len + 1 + u64_digits;
    }
    for (@typeInfo(profiler.Section).@"enum".fields) |f| {
        if (f.name[0] == '_') continue;
        n += 1 + 2 + f.name.len + 1 +
            "{\"count\":,\"mean_ns\":,\"p50_ns\":,\"p99_ns\":,\"max_ns\":}".len + 5 * u64_digits;
    }
    return n;
}

pub const max_text_bytes: usize = textBound();
pub const max_json_bytes: usize = jsonBound();

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
    try w.print("}}", .{});
    // Ops gauges live in the same line so log scrapers get one parseable event
    // (cumulative counters alone cannot answer "how many players are online now?").
    if (s.ops) |ops| {
        try w.print(
            ",\"ops\":{{\"tick\":{d},\"joined\":{d},\"entered\":{d},\"peers_alive\":{d},\"zombies\":{d},\"chunks\":{d}}}",
            .{ ops.tick, ops.joined, ops.entered, ops.peers_alive, ops.zombies, ops.chunks },
        );
    }
    try w.print("}}\n", .{});
}

test "report text non-empty" {
    var s: Snapshot = .{};
    s.counters.inc(.ticks);
    s.profiler.begin(.tick_total);
    s.profiler.end(.tick_total);
    s.captureWall();
    var buf: [max_text_bytes]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeText(&s, &w);
    const text = w.buffered();
    try std.testing.expect(text.len > 20);
    // Structure: header, counters with ticks=1, and a tick_total section row.
    try std.testing.expect(std.mem.indexOf(u8, text, "zdtd-apm snapshot") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ticks=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "tick_total") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sections") != null);
}

test "report json includes ops when set" {
    var s: Snapshot = .{};
    s.counters.inc(.ticks);
    s.ops = .{ .tick = 42, .joined = 2, .entered = 1, .peers_alive = 2, .zombies = 5, .chunks = 16 };
    s.captureWall();
    var buf: [max_json_bytes]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeJsonLine(&s, &w);
    const line = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, line, "\"type\":\"zdtd_apm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"ops\":{\"tick\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"joined\":2") != null);
}

test "text and json dumps fit their comptime bounds at max values" {
    // Saturate every counter and section so the bound is exercised, not the
    // typical short output. Adding a counter/section must keep this passing.
    var s: Snapshot = .{};
    s.wall_ns = std.math.maxInt(u64);
    s.ops = .{
        .tick = std.math.maxInt(u64),
        .joined = std.math.maxInt(u32),
        .entered = std.math.maxInt(u32),
        .peers_alive = std.math.maxInt(u32),
        .zombies = std.math.maxInt(u32),
        .chunks = std.math.maxInt(u32),
    };
    inline for (@typeInfo(metrics.CounterId).@"enum".fields) |f| {
        if (comptime f.name[0] != '_') s.counters.add(@enumFromInt(f.value), std.math.maxInt(u64));
    }
    inline for (@typeInfo(profiler.Section).@"enum".fields) |f| {
        if (comptime f.name[0] != '_') {
            s.profiler.hist[f.value].observe(std.math.maxInt(u32));
        }
    }
    var tbuf: [max_text_bytes]u8 = undefined;
    var tw: std.Io.Writer = .fixed(&tbuf);
    try writeText(&s, &tw);
    var jbuf: [max_json_bytes]u8 = undefined;
    var jw: std.Io.Writer = .fixed(&jbuf);
    try writeJsonLine(&s, &jw);
    // Every named section must appear (none skipped for count==0).
    inline for (@typeInfo(profiler.Section).@"enum".fields) |f| {
        if (comptime f.name[0] != '_') {
            try std.testing.expect(std.mem.indexOf(u8, jw.buffered(), "\"" ++ f.name ++ "\"") != null);
        }
    }
}
