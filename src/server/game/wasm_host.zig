//! Wasm host shims for Game — callbacks the plugin layer calls back into.
//! Extracted verbatim so game.zig keeps only a re-export.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const plugin_mod = @import("../../plugin/root.zig");
const ecs = @import("../../ecs/root.zig");

const wasm_log_level_tags = [_][]const u8{ "debug", "info", "warn", "err" };

pub fn wasmLog(ctx: *plugin_mod.wasm.HostCtx, level: u8, msg: []const u8) void {
    _ = ctx;
    const tag = wasm_log_level_tags[@min(@as(usize, level), wasm_log_level_tags.len - 1)];
    std.debug.print("zdtd wasm: {s}: {s}\n", .{ tag, msg });
}

pub fn wasmTick(ctx: *plugin_mod.wasm.HostCtx) u64 {
    const g: *Game = @ptrCast(@alignCast(ctx.data orelse return 0));
    return g.tick_n;
}

pub fn killVerdict(ctx: ?*anyopaque, kind: ecs.Kind, victim: i32, attacker: i32) i32 {
    const g: *Game = @ptrCast(@alignCast(ctx orelse return 0));
    return switch (kind) {
        .player => blk: {
            const sv = g.plugins.playerDeath(victim);
            break :blk if (sv != 0) sv else g.wasm_plugins.playerDeath(victim);
        },
        else => blk: {
            const sv = g.plugins.entityKilled(victim, attacker);
            break :blk if (sv != 0) sv else g.wasm_plugins.entityKilled(victim, attacker);
        },
    };
}

pub const max_plugin_cmd_len: usize = 128;

pub fn wasmQueue(ctx: *plugin_mod.wasm.HostCtx, cmd: []const u8) void {
    const g: *Game = @ptrCast(@alignCast(ctx.data orelse return));
    if (cmd.len > max_plugin_cmd_len) {
        std.debug.print("zdtd wasm: queued command too long ({d} bytes); dropped\n", .{cmd.len});
        return;
    }
    const op = parsePluginCommand(cmd) orelse {
        const verb_end = std.mem.findScalar(u8, cmd, ' ') orelse cmd.len;
        std.debug.print("zdtd wasm: unknown queued command '{s}'\n", .{cmd[0..verb_end]});
        return;
    };
    _ = g.sim.commands.push(op);
}

fn parsePluginCommand(cmd: []const u8) ?ecs.command.Op {
    var it = std.mem.tokenizeScalar(u8, cmd, ' ');
    const verb = it.next() orelse return null;
    if (std.mem.eql(u8, verb, "spawn")) {
        const x = it.next() orelse return null;
        const y = it.next() orelse return null;
        const z = it.next() orelse return null;
        const hp = it.next() orelse return null;
        if (it.next() != null) return null;
        return .{ .spawn_zombie = .{
            .x = std.fmt.parseFloat(f32, x) catch return null,
            .y = std.fmt.parseFloat(f32, y) catch return null,
            .z = std.fmt.parseFloat(f32, z) catch return null,
            .hp = std.fmt.parseFloat(f32, hp) catch return null,
        } };
    }
    if (std.mem.eql(u8, verb, "despawn")) {
        const id = it.next() orelse return null;
        if (it.next() != null) return null;
        return .{ .despawn = .{ .net_id = std.fmt.parseInt(i32, id, 10) catch return null } };
    }
    if (std.mem.eql(u8, verb, "damage")) {
        const id = it.next() orelse return null;
        const amt = it.next() orelse return null;
        if (it.next() != null) return null;
        return .{ .damage = .{
            .net_id = std.fmt.parseInt(i32, id, 10) catch return null,
            .amount = std.fmt.parseFloat(f32, amt) catch return null,
        } };
    }
    return null;
}
