// core_craftgate — a craft-request policy plugin (AGENTS.md rule 29,
// Wasm-first). Reference module for recipe blacklists and batch caps: uses
// the on_craft_request verdict to deny recipes named `forbidden_*` and log
// every request.
//
// Build (zig): see mods/BUILDING.md. Committed as core_craftgate.wasm.

const std = @import("std");
const common = @import("plugin_common");

var out: common.Buf = .{};

export fn on_enable() void {
    out.reset();
    out.put("core_craftgate v1.0 enabled (deny recipes named forbidden_*)");
    out.logLine(1);
}

export fn on_shutdown() void {
    out.reset();
    out.put("core_craftgate shutdown");
    out.logLine(1);
}

export fn on_craft_request(player: i32, name_ptr: i32, name_len: i32, times: i32) i32 {
    const name: [*]const u8 = @ptrFromInt(@as(usize, @intCast(name_ptr)));
    const n: usize = @intCast(@max(0, name_len));
    const forb = std.mem.startsWith(u8, name[0..n], "forbidden_");
    out.reset();
    out.put("craft request: player=");
    out.putInt(player);
    out.put(" times=");
    out.putInt(times);
    out.put(" recipe=");
    out.put(name[0..@min(n, common.out_cap)]);
    if (forb) {
        out.put(" DENIED");
        out.logLine(1);
        return -1; // deny the craft
    }
    out.logLine(1);
    return 0; // keep everything else
}
