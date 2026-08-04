//! In-tree sample static plugin: logs once on enable.

const api = @import("api.zig");

var enabled_once: bool = false;

fn onEnable(host: *const api.Host) void {
    if (enabled_once) return;
    enabled_once = true;
    host.log(.info, "sample_hello enabled");
}

pub const vtable: api.PluginVTable = .{
    .name = "sample_hello",
    .on_enable = &onEnable,
    // on_tick / on_player_join left null: host skips them.
};

/// Test helper: reset one-shot flag between unit tests.
pub fn resetForTest() void {
    enabled_once = false;
}

test "sample_hello enable logs once" {
    resetForTest();
    var host: api.Host = .{};
    vtable.on_enable.?(&host);
    vtable.on_enable.?(&host);
    // second call is a no-op; no assert on print
}
