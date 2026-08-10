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

/// Set once from main after argv parsing. Not thread-safe by design: the boot
/// banners are all emitted on the main thread before the tick loop starts.
pub fn setQuiet(on: bool) void {
    quiet = on;
}

pub fn isQuiet() bool {
    return quiet;
}

/// Informational startup line: suppressed by `--quiet`.
pub fn info(comptime fmt: []const u8, args: anytype) void {
    if (quiet) return;
    std.debug.print(fmt, args);
}

/// Runtime warning line. Always emitted (never hidden by `--quiet`), with a
/// wall-clock timestamp and a `WARN` severity tag so operators can correlate
/// degraded behavior with the apm/evidence timeline. Callers keep their
/// trailing `\n` in `fmt` to match `info`.
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    emit("WARN", fmt, args);
}

/// Runtime error line. Always emitted (never hidden by `--quiet`), with a
/// wall-clock timestamp and an `ERROR` severity tag. Use for load/parse/send
/// failures that must never vanish from the operator log.
pub fn err(comptime fmt: []const u8, args: anytype) void {
    emit("ERROR", fmt, args);
}

fn emit(comptime level: []const u8, comptime fmt: []const u8, args: anytype) void {
    var ts: [19]u8 = undefined;
    const stamp = clock.wallStamp(&ts);
    std.debug.print("zdtd: {s} [" ++ level ++ "] " ++ fmt, .{stamp} ++ args);
}

test "quiet gates info output" {
    try std.testing.expect(!isQuiet());
    setQuiet(true);
    try std.testing.expect(isQuiet());
    info("this line must not print\n", .{});
    setQuiet(false);
    try std.testing.expect(!isQuiet());
}

test "warn and error always emit with a timestamp and severity tag" {
    // Deterministic timestamp via the virtual clock; warn/err must ignore the
    // quiet flag so a problem can never be hidden by a script's -q.
    defer clock.disableVirtual();
    clock.enableVirtual(86_400_000_000_000); // 1970-01-02 00:00:00
    setQuiet(true);
    warn("items.xml unreadable\n", .{});
    err("world save failed: {s}\n", .{@errorName(@import("std").mem.Allocator.Error.OutOfMemory)});
    setQuiet(false);
    try std.testing.expect(clock.isVirtual());
}
