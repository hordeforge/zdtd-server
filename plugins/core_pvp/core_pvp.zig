// core_pvp - player-vs-player damage gate via the on_player_damage verdict.
//
// Verdict convention (docs/PLUGIN_DEV.md "Hooks"):
//   on_player_damage(attacker, victim, amount) -> i32
//     <0  deny the hit
//      0  keep it
//     >0  apply that percent
//
// Policy comes from this mod's own config.toml (zdtd.config import):
// `deny` defaults to true - all player-vs-player damage is denied. Set
// deny = false to keep stock PvP.

const std = @import("std");
const common = @import("plugin_common");

var out: common.Buf = .{};
var cfg: common.Config = .{};
var deny: bool = true;

export fn on_enable() void {
    cfg.load();
    if (cfg.get("deny")) |v| {
        if (std.mem.eql(u8, std.mem.trim(u8, v, " \"'"), "false")) deny = false;
    }
    out.reset();
    out.put("core_pvp v1.0 enabled (deny=");
    out.put(if (deny) "true" else "false");
    out.put(")");
    out.logLine(0);
}

export fn on_shutdown() void {
    out.reset();
    out.put("core_pvp shutdown");
    out.logLine(0);
}

export fn on_player_damage(attacker: i32, victim: i32, amount: i32) i32 {
    _ = amount;
    if (!deny) return 0;
    // Deny only player-vs-player damage: ask the host what the attacker is
    // (zdtd.query "kind <net_id>" -> "0" player, "1" zombie). A non-player
    // attacker (zombie, animal) keeps the hit.
    var req_buf: [32]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "kind {d}", .{attacker}) catch return 0;
    var resp: [8]u8 = undefined;
    const n = common.query(@intCast(@intFromPtr(req.ptr)), @intCast(req.len), @intCast(@intFromPtr(&resp)), @intCast(resp.len));
    if (n < 1) return 0;
    if (resp[0] != '0') return 0; // attacker is not a player
    out.reset();
    out.put("pvp deny: ");
    out.putInt(attacker);
    out.put(" -> ");
    out.putInt(victim);
    out.logLine(1);
    return -1; // deny player-vs-player damage
}

comptime {
    common.exportRequires("on_player_damage,query,config,log");
}
