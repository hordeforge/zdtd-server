//! In-tree sample static plugin: logs on enable.
//! Stateless by construction: static vtables carry no per-instance state, so
//! the enable log fires every time the host enables this slot (including
//! after a shutdown + re-enable cycle). No module-level flag.

const std = @import("std");
const api = @import("api.zig");

fn onEnable(host: *const api.Host) void {
    host.log(.info, "sample_hello enabled");
}

pub const vtable: api.PluginVTable = .{
    .name = "sample_hello",
    .on_enable = &onEnable,
    // on_tick / on_player_join left null: host skips them.
};

test "sample_hello enable logs" {
    var host: api.Host = .{};
    vtable.on_enable.?(&host);
    vtable.on_enable.?(&host);
}
