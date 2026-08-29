// core_perkgate — perk spend gate via the on_perk_spend verdict (ADR 0033).
//
// Verdict convention (docs/PLUGIN_DEV.md "Hooks"):
//   on_perk_spend(player, name_ptr, name_len, level, cost) -> i32
//     <0  deny the purchase
//      0  keep it
//     >0  scale the skill-point cost by percent
//
// Policy comes from this mod's own config.toml (zdtd.config import):
// `deny_prefix` defaults to "forbidden_" - purchases of perks whose name
// starts with the prefix are denied.

const std = @import("std");
const common = @import("plugin_common");

var out: common.Buf = .{};
var cfg: common.Config = .{};
var deny_prefix: [32]u8 = undefined;
var deny_len: usize = 0;

export fn on_enable() void {
    cfg.load();
    const dflt = "forbidden_";
    deny_len = dflt.len;
    @memcpy(deny_prefix[0..deny_len], dflt);
    if (cfg.get("deny_prefix")) |p| {
        const t = std.mem.trim(u8, p, " \"'");
        if (t.len > 0 and t.len <= deny_prefix.len) {
            deny_len = t.len;
            @memcpy(deny_prefix[0..deny_len], t);
        }
    }
    out.reset();
    out.put("core_perkgate v1.0 enabled (deny prefix: ");
    out.put(deny_prefix[0..deny_len]);
    out.put(")");
    out.logLine(1);
}

export fn on_shutdown() void {
    out.reset();
    out.put("core_perkgate shutdown");
    out.logLine(1);
}

export fn on_perk_spend(player: i32, name_ptr: i32, name_len: i32, level: i32, cost: i32) i32 {
    const name: [*]const u8 = @ptrFromInt(@as(usize, @intCast(name_ptr)));
    const n: usize = @intCast(@max(0, name_len));
    const forb = deny_len > 0 and std.mem.startsWith(u8, name[0..n], deny_prefix[0..deny_len]);
    out.reset();
    out.put("perk spend: player=");
    out.putInt(player);
    out.put(" level=");
    out.putInt(level);
    out.put(" cost=");
    out.putInt(cost);
    out.put(" perk=");
    out.put(name[0..@min(n, common.out_cap)]);
    if (forb) {
        out.put(" DENIED");
        out.logLine(1);
        return -1; // deny the spend
    }
    out.logLine(1);
    return 0; // keep everything else
}

comptime {
    common.exportRequires("on_perk_spend,config,log");
}
