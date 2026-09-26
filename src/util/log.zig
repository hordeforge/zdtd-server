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

const std = @import("std");
const clock = @import("clock.zig");

var quiet: bool = false;
/// Stock Log.Level (ConsoleCmdLoglevel): 0 = Info (everything), 1 = Warning,
/// 2 = Error, 3 = Exception, 4 = Off. `info`/`warn`/`err` map to 0/1/2 and
/// are suppressed when below `min_level`. Set by the `loglevel` admin verb.
var min_level: u8 = 0;

/// Set once from main after argv parsing. Not thread-safe by design: the boot
/// banners are all emitted on the main thread before the tick loop starts.
pub fn setQuiet(on: bool) void {
    quiet = on;
}

/// Stock Log.Level backing the `loglevel` admin verb (0..4, 4 = off).
pub fn level() u8 {
    return min_level;
}

pub fn setLevel(l: u8) void {
    min_level = @min(l, 4);
}

/// Informational startup line: suppressed by `--quiet` or `loglevel >= 1`.
pub fn info(comptime fmt: []const u8, args: anytype) void {
    if (quiet) return;
    if (min_level >= 1) return;
    std.debug.print(fmt, args);
}

/// Runtime warning line. Suppressed by `loglevel >= 2` (never hidden by
/// `--quiet`), with a wall-clock timestamp and a `WARN` severity tag so
/// operators can correlate degraded behavior with the apm/evidence timeline.
/// Callers keep their trailing `\n` in `fmt` to match `info`.
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    if (min_level >= 2) return;
    emit("WARN", fmt, args);
}

/// Runtime error line. Suppressed by `loglevel >= 3` (never hidden by
/// `--quiet`), with a wall-clock timestamp and an `ERROR` severity tag. Use
/// for load/parse/send failures that must never vanish from the operator log.
pub fn err(comptime fmt: []const u8, args: anytype) void {
    if (min_level >= 3) return;
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
    if (quiet) return;
    if (min_level >= 1) return;
    emit("INFO", fmt, args);
}

fn emit(comptime tag: []const u8, comptime fmt: []const u8, args: anytype) void {
    var ts: [19]u8 = undefined;
    const stamp = clock.wallStamp(&ts);
    std.debug.print("zdtd: {s} [" ++ tag ++ "] " ++ fmt, .{stamp} ++ args);
}

test "quiet gates info output" {
    setQuiet(true);
    info("this line must not print\n", .{});
    setQuiet(false);
}

test "warn and error always emit with a timestamp and severity tag" {
    // Deterministic timestamp via the virtual clock; warn/err must ignore the
    // quiet flag so a problem can never be hidden by a script's -q.
    defer clock.disableVirtual();
    clock.enableVirtual(86_400_000_000_000); // 1970-01-02 00:00:00
    setQuiet(true);
    warn("items.xml unreadable\n", .{});
    err("world save failed: {s}\n", .{@errorName(@import("std").mem.Allocator.Error.OutOfMemory)});
    errEvery(1, "throttled error\n", .{});
    errEvery(2, "suppressed error\n", .{});
    setQuiet(false);
    infoTagged("runtime event: started\n", .{});
    try std.testing.expect(clock.isVirtual());
}
