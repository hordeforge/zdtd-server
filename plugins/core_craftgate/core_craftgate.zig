// core_craftgate - craft request gate via the on_craft_request verdict.
//
// Verdict convention (docs/PLUGIN_DEV.md "Hooks"):
//   on_craft_request(player, name_ptr, name_len, times) -> i32
//     <0  deny the batch
//      0  keep it
//     >0  scale by percent
//
// Policy comes from this mod's own config.toml (zdtd.config import):
// `deny_prefix` defaults to "forbidden_" - requests for recipes whose name
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
    out.put("core_craftgate v1.0 enabled (deny prefix: ");
    out.put(deny_prefix[0..deny_len]);
    out.put(")");
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
    const forb = deny_len > 0 and std.mem.startsWith(u8, name[0..n], deny_prefix[0..deny_len]);
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
        return -1; // deny the batch
    }
    out.logLine(1);
    return 0; // keep everything else
}

comptime {
    common.exportRequires("on_craft_request,config,log");
}
