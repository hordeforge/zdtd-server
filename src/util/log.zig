//! Startup log verbosity for the `--quiet` / `-q` CLI flag.
//!
//! `info` carries the boot banners (asset counts, seeds, listen lines) that an
//! operator wants once and a script never wants. Warnings and errors keep using
//! `std.debug.print` directly so `--quiet` can never hide a problem.
//!
//! Process-wide because the banners are emitted deep inside Game.init, far from
//! the argv parse; the flag is set once in main before any of them run.

const std = @import("std");

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

test "quiet gates info output" {
    try std.testing.expect(!isQuiet());
    setQuiet(true);
    try std.testing.expect(isQuiet());
    info("this line must not print\n", .{});
    setQuiet(false);
    try std.testing.expect(!isQuiet());
}
