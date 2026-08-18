//! Wasm host shims for Game — callbacks the plugin layer calls back into.
//! Extracted verbatim so game.zig keeps only a re-export.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const plugin_mod = @import("../../plugin/root.zig");
const ecs = @import("../../ecs/root.zig");
const c2s_text = @import("../c2s_text.zig");

const wasm_log_level_tags = [_][]const u8{ "debug", "info", "warn", "err" };

/// Bytes of guest text kept per `zdtd_log` call. Plugin hooks receive player
/// names and chat bodies, so an unbounded guest string could dump payloads of
/// player data into the operator log; the cap bounds one line's exposure.
pub const max_wasm_log_len: usize = 200;

pub fn wasmLog(ctx: *plugin_mod.wasm.HostCtx, level: u8, msg: []const u8) void {
    _ = ctx;
    const tag = wasm_log_level_tags[@min(@as(usize, level), wasm_log_level_tags.len - 1)];
    // Guest-controlled bytes: C0/DEL would let a plugin forge whole log lines
    // (the operator audit trail is line-oriented stderr), so reuse the C2S text
    // sanitizer, which also drops invalid UTF-8 and truncates on a codepoint.
    var line: [max_wasm_log_len]u8 = undefined;
    const n = c2s_text.sanitizePlayerName(&line, msg);
    std.debug.print("zdtd wasm: {s}: {s}\n", .{ tag, line[0..n] });
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
    // `bot <verb>` commands are host-side BotManager calls (ADR 0026), not ECS
    // ops: the BotManager owns spawn/move/look/shoot/remove/count and returns
    // true for any command starting with `bot `. Everything else falls through
    // to the ECS plugin verbs (spawn/despawn/damage).
    if (g.bots.handleCommand(g, cmd)) return;
    const op = parsePluginCommand(cmd) orelse {
        const verb_end = std.mem.findScalar(u8, cmd, ' ') orelse cmd.len;
        // Guest-controlled bytes: same one-line rule as wasmLog above.
        var vb: [64]u8 = undefined;
        const vn = c2s_text.sanitizePlayerName(&vb, cmd[0..verb_end]);
        std.debug.print("zdtd wasm: unknown queued command '{s}'\n", .{vb[0..vn]});
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

/// Build a fixed-layout world snapshot for a `zdtd.sense` call (BOTS_SPEC §3).
/// Header (16 bytes) then fixed 32-byte entity records, then an optional
/// 16-byte event trailer (bot-info records kind 4, then damage events kind 3);
/// all little-endian. Returns bytes written; 0 when `out` cannot fit a header.
/// No heap on the tick path.
pub fn wasmSense(ctx: *plugin_mod.wasm.HostCtx, out: []u8) usize {
    const g: *Game = @ptrCast(@alignCast(ctx.data orelse return 0));
    if (out.len < 16) return 0;
    // Reserve room for the event trailer up front so a full record set still
    // leaves space for it (the guest parses the trailer after the records; a
    // truncated tail would desync its offsets).
    const bot_mod = @import("bot.zig");
    const trailer_cap = (bot_mod.max_sense_info + bot_mod.max_sense_events) * bot_mod.sense_event_len;
    const max_records = if (out.len >= 16 + trailer_cap) (out.len - 16 - trailer_cap) / 32 else (out.len - 16) / 32;
    std.mem.writeInt(u32, out[0..4], 0x3253425a, .little); // 'ZBS2' (v2: event trailer)
    std.mem.writeInt(u32, out[4..8], 0, .little); // count, filled below
    std.mem.writeInt(u32, out[8..12], @truncate(g.tick_n), .little);
    std.mem.writeInt(i32, out[12..16], 0, .little); // self_net_id
    var n: usize = 0;
    var s: ecs.Slot = 0;
    while (s < ecs.max_entities and n < max_records) : (s += 1) {
        if (!g.sim.alive[s] or !g.sim.mask[s].network_id) continue;
        const k: u8 = switch (g.sim.kind[s]) {
            .player => 0,
            // Zombies and animals share the hostile bucket in the guest.
            .zombie, .animal => 1,
            // Non-combat world objects are not combat candidates; omit.
            .trader, .vehicle, .turret, .loot_bag => continue,
        };
        const base = 16 + n * 32;
        const r = out[base .. base + 32];
        std.mem.writeInt(i32, r[0..4], g.sim.network_id[s].id, .little);
        r[4] = k;
        r[5] = 0; // self
        r[6] = if (g.sim.health[s].hp > 0) 1 else 0; // alive
        r[7] = 0; // pad
        const t = &g.sim.transform[s];
        std.mem.writeInt(u32, r[8..12], @bitCast(t.x), .little);
        std.mem.writeInt(u32, r[12..16], @bitCast(t.y), .little);
        std.mem.writeInt(u32, r[16..20], @bitCast(t.z), .little);
        std.mem.writeInt(u32, r[20..24], @bitCast(g.sim.health[s].hp), .little);
        std.mem.writeInt(u32, r[24..28], @bitCast(t.yaw), .little);
        std.mem.writeInt(i32, r[28..32], -1, .little); // target_id
        n += 1;
    }
    // Host-side bots (ADR 0026) are not ECS entities; append them after the
    // ECS actor records as kind==2, sharing the same 32-byte record layout.
    // fillSense offsets by its own running `n` (which already counts the ECS
    // actor records), so base must be the header end (16), NOT 16 + n*32 —
    // the latter double-offsets the bot records past the copied region.
    g.bots.fillSense(out, 16, max_records, &n);
    // Event trailer (BOTS_SPEC §3): kind-4 bot-info records first (the guest's
    // weapon map), then kind-3 damage events (attributed hits since the last
    // sense pass — the guest keys on victim == its own bot net id to
    // retaliate).
    const ev_base = 16 + n * 32;
    const info_n = g.bots.fillSenseBotInfo(out, ev_base, bot_mod.max_sense_info);
    var ev_n: usize = 0;
    const ev_base2 = ev_base + info_n * bot_mod.sense_event_len;
    if (ev_base2 + bot_mod.sense_event_len <= out.len) {
        ev_n = g.bots.drainSenseEvents(out, ev_base2, bot_mod.max_sense_events);
    }
    std.mem.writeInt(u32, out[4..8], @intCast(n), .little);
    return 16 + n * 32 + (info_n + ev_n) * bot_mod.sense_event_len;
}

/// `zdtd.query(req_ptr, req_len, out_ptr, out_cap)` — reverse-direction point
/// query (BOTS_SPEC §3; the sense `token` stays reserved). The guest writes a
/// text request, the host writes a text response into the guest's out buffer
/// and returns bytes written (0 = no answer). Requests are host-budgeted
/// (small, text-parsed) and never mutate the sim.
///
///   "cover <x> <z> <tx> <tz>"  -> "<cx> <cz>" (a point near (x,z) not visible
///                                 from (tx,tz)), or "" when none exists.
pub fn wasmQuery(ctx: *plugin_mod.wasm.HostCtx, req: []const u8, out: []u8) usize {
    const g: *Game = @ptrCast(@alignCast(ctx.data orelse return 0));
    var it = std.mem.tokenizeScalar(u8, req, ' ');
    const verb = it.next() orelse return 0;
    if (!std.mem.eql(u8, verb, "cover")) return 0;
    const sx = it.next() orelse return 0;
    const sz = it.next() orelse return 0;
    const tx = it.next() orelse return 0;
    const tz = it.next() orelse return 0;
    if (it.next() != null) return 0;
    const fx = std.fmt.parseFloat(f32, sx) catch return 0;
    const fz = std.fmt.parseFloat(f32, sz) catch return 0;
    const thx = std.fmt.parseFloat(f32, tx) catch return 0;
    const thz = std.fmt.parseFloat(f32, tz) catch return 0;
    const from: [3]f32 = .{ fx, g.groundHeight(@intFromFloat(@floor(fx)), @intFromFloat(@floor(fz))), fz };
    const threat: [3]f32 = .{ thx, g.groundHeight(@intFromFloat(@floor(thx)), @intFromFloat(@floor(thz))), thz };
    const cv = g.findCover(from, threat, 10.0) orelse return 0;
    const s = std.fmt.bufPrint(out, "{d} {d}", .{ cv[0], cv[2] }) catch return 0;
    return s.len;
}
