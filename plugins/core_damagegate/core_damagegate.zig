// core_damagegate - incoming player damage scaling via the on_player_damage
// verdict (fires after the native PvP/armor gate, before the hit applies).
//
// Verdict convention (docs/PLUGIN_DEV.md "Hooks"):
//   on_player_damage(attacker: i32, victim: i32, amount: i32) -> i32
//     <0  deny the hit entirely
//      0  keep the hit
//     >0  apply that percent (50 = half)
//
// Policy comes from this mod's own config.toml (zdtd.config import):
// `percent` defaults to 50 (half incoming player damage).

const common = @import("plugin_common");

var out: common.Buf = .{};
var cfg: common.Config = .{};
var percent: i32 = 50;

export fn on_enable() void {
    cfg.load();
    if (cfg.getInt("percent")) |v| {
        if (v >= 0 and v <= 10000) percent = @intCast(v);
    }
    out.reset();
    out.put("core_damagegate v1.0 enabled (percent=");
    out.putInt(percent);
    out.put(")");
    out.logLine(0);
}

export fn on_shutdown() void {
    out.reset();
    out.put("core_damagegate shutdown");
    out.logLine(0);
}

export fn on_player_damage(attacker: i32, victim: i32, amount: i32) i32 {
    _ = attacker;
    _ = victim;
    _ = amount;
    return percent;
}

comptime {
    common.exportRequires("on_player_damage,config,log");
}
