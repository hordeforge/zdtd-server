//! Static plugin hook types for in-tree test scaffolding only (ADR 0020).
//! Product plugins are Wasm modules (`wasm.zig`); this table is not a shipping
//! native ABI. No dynlib, no stock IModApi.

const std = @import("std");

pub const PLUGIN_API_VERSION: u32 = 1;

pub const LogLevel = enum(u8) {
    debug,
    info,
    warn,
    err,
};

/// Narrow host view passed into hooks. No raw `*Game`.
pub const Host = struct {
    version: u32 = PLUGIN_API_VERSION,
    tick: u64 = 0,
    log_fn: *const fn (LogLevel, []const u8) void = defaultLog,

    pub fn log(self: Host, level: LogLevel, msg: []const u8) void {
        self.log_fn(level, msg);
    }
};

fn defaultLog(level: LogLevel, msg: []const u8) void {
    const tag: []const u8 = switch (level) {
        .debug => "debug",
        .info => "info",
        .warn => "warn",
        .err => "err",
    };
    std.debug.print("zdtd plugin [{s}]: {s}\n", .{ tag, msg });
}

/// Static plugin vtable. Null hooks are skipped (zero cost beyond a null check).
pub const PluginVTable = struct {
    name: []const u8,
    on_enable: ?*const fn (*const Host) void = null,
    on_tick: ?*const fn (*const Host) void = null,
    on_player_join: ?*const fn (*const Host, peer_slot: u16, entity_id: i32) void = null,
    on_shutdown: ?*const fn (*const Host) void = null,
};

test "host log dispatches level and message to log_fn" {
    const Cap = struct {
        var level: ?LogLevel = null;
        var msg: ?[]const u8 = null;
        fn capture(l: LogLevel, m: []const u8) void {
            level = l;
            msg = m;
        }
    };
    Cap.level = null;
    Cap.msg = null;
    var h: Host = .{ .log_fn = Cap.capture };
    try std.testing.expectEqual(@as(u32, PLUGIN_API_VERSION), h.version);
    h.log(.warn, "ping");
    try std.testing.expectEqual(LogLevel.warn, Cap.level.?);
    try std.testing.expectEqualStrings("ping", Cap.msg.?);
}
