// core_rewardgate — quest reward scaling via the on_quest_complete verdict.
//
// Verdict convention (docs/PLUGIN_DEV.md "Hooks"):
//   on_quest_complete(player, quest_def_id) -> i32
//     <0  withhold the payout
//      0  keep the payout
//     >0  pay that percent of items/exp (150 = 1.5x)
//
// Policy comes from this mod's own config.toml (zdtd.config import):
// `percent` defaults to 150 (1.5x rewards on every quest).

const common = @import("plugin_common");

var out: common.Buf = .{};
var cfg: common.Config = .{};
var percent: i32 = 150;

export fn on_enable() void {
    cfg.load();
    if (cfg.getInt("percent")) |v| {
        if (v >= 0 and v <= 10000) percent = @intCast(v);
    }
    out.reset();
    out.put("core_rewardgate v1.0 enabled (percent=");
    out.putInt(percent);
    out.put(")");
    out.logLine(0);
}

export fn on_shutdown() void {
    out.reset();
    out.put("core_rewardgate shutdown");
    out.logLine(0);
}

export fn on_quest_complete(player: i32, quest_def: i32) i32 {
    _ = player;
    _ = quest_def;
    return percent;
}

comptime {
    common.exportRequires("on_quest_complete,config,log");
}
