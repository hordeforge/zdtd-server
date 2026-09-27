//! Logging for the zdtd process: boot banners, warnings and errors.
//!
//! `info` carries the boot banners (asset counts, seeds, listen lines) that an
//! operator wants once and a script never wants; it is suppressed by
//! `--quiet`. `warn`/`err` are for runtime failures the operator must always
//! see, so they are never gated by `--quiet` and always carry a wall-clock
//! timestamp plus a `[WARN]`/`[ERROR]` severity tag.
//!
//! Process-wide because the banners are emitted deep inside Game.init, far from
//! the argv parse; the flag is set once in main before any of them run.
//!
//! Both gates are atomics, not plain globals: `setLevel` runs on the tick
//! thread (the `loglevel` admin verb) while the async chunk-flush writer thread
//! and the parallel worker pool emit through the same functions. A plain u8
//! store racing those loads is a data race, not a stale-value curiosity.

const std = @import("std");
const clock = @import("clock.zig");

var quiet: std.atomic.Value(bool) = .init(false);

/// When non-null, log lines go to this buffer instead of stderr and the write
/// is bounded: overflow is dropped, never grown. A log line is unobservable
/// from a test otherwise, so the severity and quiet gates could only be
/// asserted by reading the runner's output. Cleared by `stopCapture`.
var capture: ?[]u8 = null;
var capture_len: usize = 0;

/// Stock Log.Level (ConsoleCmdLoglevel): 0 = Info (everything), 1 = Warning,
/// 2 = Error, 3 = Exception, 4 = Off. `info`/`warn`/`err` map to 0/1/2 and
/// are suppressed when below `min_level`. Set by the `loglevel` admin verb.
var min_level: std.atomic.Value(u8) = .init(0);

/// Set once from main after argv parsing. Atomic because the writer thread and
/// pool workers read it for the lines they emit.
pub fn setQuiet(on: bool) void {
    quiet.store(on, .release);
}

/// Stock Log.Level backing the `loglevel` admin verb (0..4, 4 = off).
pub fn level() u8 {
    return min_level.load(.acquire);
}

pub fn setLevel(l: u8) void {
    min_level.store(@min(l, 4), .release);
}

/// Informational startup line: suppressed by `--quiet` or `loglevel >= 1`.
pub fn info(comptime fmt: []const u8, args: anytype) void {
    if (quiet.load(.acquire)) return;
    if (min_level.load(.acquire) >= 1) return;
    var w: std.Io.Writer = .fixed(&line_buf);
    w.print(fmt, args) catch {};
    write(w.buffered());
}

/// Runtime warning line. Suppressed by `loglevel >= 2` (never hidden by
/// `--quiet`), with a wall-clock timestamp and a `WARN` severity tag so
/// operators can correlate degraded behavior with the apm/evidence timeline.
/// Callers keep their trailing `\n` in `fmt` to match `info`.
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    if (min_level.load(.acquire) >= 2) return;
    emit("WARN", fmt, args);
}

/// Runtime error line. Suppressed by `loglevel >= 3` (never hidden by
/// `--quiet`), with a wall-clock timestamp and an `ERROR` severity tag. Use
/// for load/parse/send failures that must never vanish from the operator log.
pub fn err(comptime fmt: []const u8, args: anytype) void {
    if (min_level.load(.acquire) >= 3) return;
    emit("ERROR", fmt, args);
}

/// Repeat cap for a runtime failure that can fire on every packet or tick:
/// the 1st occurrence and every `warn_throttle_every`-th after it. One flood
/// still names itself once, immediately, without filling the operator log.
pub const warn_throttle_every: u64 = 100;

/// Whether occurrence `n` (1-based running count, normally an apm counter
/// read) is one of the ones `warn_throttle_every` lets through. Use directly
/// only when the line needs local setup (a hex dump, a sanitized name);
/// otherwise call `warnEvery` or `errEvery`.
pub fn throttled(n: u64) bool {
    return n == 1 or n % warn_throttle_every == 0;
}

/// `warn` for occurrence `n`, gated by `throttled`. Callers pass the count
/// they also print as `n={d}` so the line says how many were suppressed.
pub fn warnEvery(n: u64, comptime fmt: []const u8, args: anytype) void {
    if (!throttled(n)) return;
    warn(fmt, args);
}

/// `err` for occurrence `n`, gated by `throttled`. Callers pass the count
/// they also print as `n={d}` so the line says how many were suppressed.
pub fn errEvery(n: u64, comptime fmt: []const u8, args: anytype) void {
    if (!throttled(n)) return;
    err(fmt, args);
}

/// Runtime informational event line with timestamp and `INFO` severity tag.
/// Suppressed by `--quiet` or `loglevel >= 1`.
pub fn infoTagged(comptime fmt: []const u8, args: anytype) void {
    if (quiet.load(.acquire)) return;
    if (min_level.load(.acquire) >= 1) return;
    emit("INFO", fmt, args);
}

fn emit(comptime tag: []const u8, comptime fmt: []const u8, args: anytype) void {
    var ts: [19]u8 = undefined;
    const stamp = clock.wallStamp(&ts);
    var w: std.Io.Writer = .fixed(&line_buf);
    w.print("zdtd: {s} [" ++ tag ++ "] " ++ fmt, .{stamp} ++ args) catch {};
    write(w.buffered());
}

/// Scratch a line is formatted into before it reaches the sink. A log line
/// past this size is truncated at a line boundary, never silently dropped.
var line_buf: [line_cap]u8 = undefined;
const line_cap = 1024;

fn write(bytes: []const u8) void {
    const dest = capture orelse {
        std.debug.print("{s}", .{bytes});
        return;
    };
    const room = dest.len -| capture_len;
    const n = @min(room, bytes.len);
    @memcpy(dest[capture_len..][0..n], bytes[0..n]);
    capture_len += n;
}

/// Route log output into `buf` instead of stderr. The buffer is filled from
/// index 0 and overflow is dropped; `captured` returns what was written so far.
/// Test seam only: nothing in the process path calls it.
pub fn startCapture(buf: []u8) void {
    capture = buf;
    capture_len = 0;
}

/// Everything written since `startCapture`, truncated at the buffer end if it
/// overflowed. Empty when no capture is active.
pub fn captured() []const u8 {
    const buf = capture orelse return "";
    return buf[0..capture_len];
}

pub fn stopCapture() void {
    capture = null;
    capture_len = 0;
}

test "quiet and loglevel gate info, never warn or err" {
    // warn/err must ignore --quiet so a problem can never be hidden by a
    // script's -q. Deterministic stamp via the virtual clock.
    defer clock.disableVirtual();
    clock.enableVirtual(86_400_000_000_000); // 1970-01-02 00:00:00

    var buf: [512]u8 = undefined;
    defer stopCapture();
    startCapture(&buf);

    setQuiet(true);
    info("boot banner\n", .{});
    infoTagged("runtime event\n", .{});
    try std.testing.expectEqualStrings("", captured());

    setQuiet(false);
    setLevel(1); // ConsoleCmdLoglevel Warning
    info("boot banner\n", .{});
    try std.testing.expectEqualStrings("", captured());

    setLevel(0);
    info("boot banner\n", .{});
    try std.testing.expectEqualStrings("boot banner\n", captured());
}

test "warn and error always emit with a timestamp and severity tag" {
    defer clock.disableVirtual();
    clock.enableVirtual(86_400_000_000_000); // 1970-01-02 00:00:00

    var buf: [512]u8 = undefined;
    defer stopCapture();
    startCapture(&buf);

    setQuiet(true);
    warn("items.xml unreadable\n", .{});
    try std.testing.expectEqualStrings(
        "zdtd: 1970-01-02 00:00:00 [WARN] items.xml unreadable\n",
        captured(),
    );

    err("world save failed: OutOfMemory\n", .{});
    try std.testing.expectEqualStrings(
        "zdtd: 1970-01-02 00:00:00 [WARN] items.xml unreadable\n" ++
            "zdtd: 1970-01-02 00:00:00 [ERROR] world save failed: OutOfMemory\n",
        captured(),
    );

    setQuiet(false);
    infoTagged("runtime event: started\n", .{});
    try std.testing.expect(std.mem.endsWith(u8, captured(), "[INFO] runtime event: started\n"));
}

test "errEvery lets the first occurrence through and throttles the rest" {
    defer setLevel(0);
    var buf: [1024]u8 = undefined;
    defer stopCapture();
    startCapture(&buf);

    setLevel(0);
    errEvery(1, "first\n", .{});
    errEvery(2, "suppressed\n", .{});
    errEvery(warn_throttle_every, "hundredth\n", .{});
    const out = captured();
    try std.testing.expect(std.mem.indexOf(u8, out, "[ERROR] first\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "suppressed") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[ERROR] hundredth\n") != null);
}

test "loglevel clamps to the stock Off value and gates by severity" {
    defer setLevel(0);
    var buf: [512]u8 = undefined;
    defer stopCapture();
    startCapture(&buf);

    setLevel(9);
    try std.testing.expectEqual(@as(u8, 4), level());
    warn("off\n", .{});
    err("off\n", .{});
    try std.testing.expectEqualStrings("", captured());

    setLevel(2); // Error
    warn("below level\n", .{});
    err("at level\n", .{});
    const out = captured();
    try std.testing.expect(std.mem.indexOf(u8, out, "below level") == null);
    try std.testing.expect(std.mem.endsWith(u8, out, "[ERROR] at level\n"));
}

test "level gates are race-free against a concurrent setLevel" {
    // The `loglevel` admin verb writes the gate on the tick thread while the
    // async chunk-flush writer thread and the pool workers read it. Both gates
    // stay atomic: this drives one writer and one reader so a plain global
    // would be a data race here, not just a stale value.
    defer {
        setQuiet(false);
        setLevel(0);
    }
    try std.testing.expectEqual(@as(u8, 0), level());
    setLevel(9); // clamps to Off
    try std.testing.expectEqual(@as(u8, 4), level());

    var stop = std.atomic.Value(bool).init(false);
    const Flips = struct {
        fn run(stop_: *std.atomic.Value(bool)) void {
            var n: u8 = 0;
            // 3 and 4 keep every gate closed, so the reader below exercises the
            // loads without spraying the test log. Wrapping add: the writer
            // outruns the reader, and a saturating u8 increment panics in Debug.
            while (!stop_.load(.acquire)) : (n +%= 1) setLevel(if (n % 2 == 0) 4 else 3);
        }
    };
    const writer = try std.Thread.spawn(.{}, Flips.run, .{&stop});
    setQuiet(true);
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        _ = level();
        info("suppressed\n", .{});
        warn("suppressed\n", .{});
        err("suppressed\n", .{});
        infoTagged("suppressed\n", .{});
    }
    stop.store(true, .release);
    writer.join();
}
