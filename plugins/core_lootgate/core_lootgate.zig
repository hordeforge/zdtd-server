// core_lootgate - loot roll scaling via the on_loot_roll verdict.
//
// Verdict convention (docs/PLUGIN_DEV.md "Hooks"):
//   on_loot_roll(list_ptr, list_len, rolled: i32) -> i32
//     <0  deny the roll (empty result)
//      0  keep the roll
//     >0  scale the rolled stack count by percent (50 = half)
//
// Policy comes from this mod's own config.toml (zdtd.config import):
// `percent` defaults to 50.

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
    out.put("core_lootgate v1.0 enabled (percent=");
    out.putInt(percent);
    out.put(")");
    out.logLine(1);
}

export fn on_shutdown() void {
    out.reset();
    out.put("core_lootgate shutdown");
    out.logLine(1);
}

export fn on_loot_roll(list_ptr: i32, list_len: i32, rolled: i32) i32 {
    const list: [*]const u8 = @ptrFromInt(@as(usize, @intCast(list_ptr)));
    const n: usize = @intCast(@max(0, list_len));
    out.reset();
    out.put("loot roll: list=");
    out.put(list[0..@min(n, common.out_cap)]);
    out.put(" rolled=");
    out.putInt(rolled);
    out.put(" -> ");
    out.putInt(percent);
    out.put("%");
    out.logLine(1);
    return percent;
}

comptime {
    common.exportRequires("on_loot_roll,config,log");
}
