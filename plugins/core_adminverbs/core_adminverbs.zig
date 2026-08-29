// core_adminverbs — custom operator verbs via the on_admin_command hook
// (AGENTS.md rule 29, Wasm-first; the hook is otherwise only used by
// bot). Demonstrates shipping operator tooling as a module instead of a
// native console arm.
//
// Verb: `wave <n>` — queues <n> zombie spawns at the seed pad (256,70,256)
// via zdtd.queue and replies "wave: spawning <n>".
//
// Convention (docs/PLUGIN_DEV.md "Hooks"):
//   on_admin_command(cmd_ptr, cmd_len, out_ptr, out_cap) -> i32
//     write the reply at out_ptr, return its length (0 = not handled; the
//     next plugin / core console handles it).
//
// Build (zig): see mods/BUILDING.md. Committed as core_adminverbs.wasm.

const std = @import("std");
const common = @import("plugin_common");

var out: common.Buf = .{};
var cfg: common.Config = .{};
var spawn_x: i32 = 256;
var spawn_y: i32 = 70;
var spawn_z: i32 = 256;
var spawn_entity: i32 = 100;

export fn on_enable() void {
    cfg.load();
    if (cfg.getInt("spawn_x")) |v| spawn_x = @intCast(v);
    if (cfg.getInt("spawn_y")) |v| spawn_y = @intCast(v);
    if (cfg.getInt("spawn_z")) |v| spawn_z = @intCast(v);
    if (cfg.getInt("spawn_entity")) |v| spawn_entity = @intCast(v);
    out.reset();
    out.put("core_adminverbs v1.0 enabled (verb: wave <n> @ ");
    out.putInt(spawn_x);
    out.put(",");
    out.putInt(spawn_y);
    out.put(",");
    out.putInt(spawn_z);
    out.put(")");
    out.logLine(0);
}

export fn on_shutdown() void {
    out.reset();
    out.put("core_adminverbs shutdown");
    out.logLine(0);
}

// Queue `count` zombies at the seed pad; replies "wave: spawning N".
fn queueWave(count_in: i32, reply: []u8) usize {
    var count = @max(count_in, 1);
    while (count > 0) : (count -= 1) {
        out.reset();
        out.put("spawn ");
        out.putInt(spawn_x);
        out.put(" ");
        out.putInt(spawn_y);
        out.put(" ");
        out.putInt(spawn_z);
        out.put(" ");
        out.putInt(spawn_entity);
        _ = out.send();
    }
    const s = std.fmt.bufPrint(reply, "wave: spawning {d}", .{@max(count_in, 1)}) catch return 0;
    return s.len;
}

// Parse "wave <n>"; anything else falls through (return 0 = not handled).
export fn on_admin_command(cmd_ptr: i32, cmd_len: i32, out_ptr: i32, out_cap: i32) i32 {
    const cmd: [*]const u8 = @ptrFromInt(@as(usize, @intCast(cmd_ptr)));
    const n: usize = @intCast(@max(0, cmd_len));
    const text = cmd[0..@min(n, 159)];

    var it = std.mem.tokenizeAny(u8, text, " \t");
    const first = it.next() orelse return 0;
    if (!std.mem.eql(u8, first, "wave")) return 0;

    var count: i32 = 1;
    if (it.next()) |arg| count = std.fmt.parseInt(i32, arg, 10) catch 1;

    const reply: [*]u8 = @ptrFromInt(@as(usize, @intCast(out_ptr)));
    const cap: usize = @intCast(@max(0, out_cap));
    return @intCast(queueWave(count, reply[0..cap]));
}

comptime {
    common.exportRequires("on_admin_command,queue,config,log");
}
