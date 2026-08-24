// zdtd_pvp — a player-damage policy plugin (AGENTS.md rule 29, Wasm-first).
// Reference module for the on_player_damage verdict + the "kind" query verb:
// denies all player-vs-player damage while leaving NPC damage untouched.
//
// Build (zig): see mods/BUILDING.md. Committed as zdtd_pvp.wasm.

const std = @import("std");
const common = @import("plugin_common");

var out: common.Buf = .{};
var qbuf: [8]u8 = undefined;

// "kind <net_id>" -> one byte '0' player / '1' zombie, or 0 when unknown.
fn queryKind(net_id: i32) i32 {
    var req: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&req, "kind {d}", .{net_id}) catch return -1;
    const qn = common.query(@intCast(@intFromPtr(&req)), @intCast(s.len), @intCast(@intFromPtr(&qbuf)), qbuf.len);
    if (qn != 1) return -1;
    return @as(i32, qbuf[0]) - '0';
}

export fn on_enable() void {
    out.reset();
    out.put("zdtd_pvp v1.0 enabled (deny player-vs-player damage)");
    out.logLine(1);
}

export fn on_shutdown() void {
    out.reset();
    out.put("zdtd_pvp shutdown");
    out.logLine(1);
}

export fn on_player_damage(attacker: i32, victim: i32, amount: i32) i32 {
    _ = amount;
    const ak = queryKind(attacker);
    const vk = queryKind(victim);
    if (ak == 0 and vk == 0) {
        out.reset();
        out.put("pvp deny: ");
        out.putInt(attacker);
        out.put(" -> ");
        out.putInt(victim);
        out.logLine(1);
        return -1; // deny the hit
    }
    return 0; // keep everything else
}
