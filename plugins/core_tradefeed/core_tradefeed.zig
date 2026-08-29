// core_tradefeed — a trader-event observer plugin (AGENTS.md rule 29,
// Wasm-first). Reference module for trader/vehicle announcements: observes
// on_trader_event (kind 0 open / 1 buy / 2 sell) and logs every trade window
// event, always keeping the stock outcome.
//
// Build (zig): see mods/BUILDING.md. Committed as core_tradefeed.wasm.

const std = @import("std");
const common = @import("plugin_common");

var out: common.Buf = .{};

var cfg: common.Config = .{};
var log_level: i32 = 1;

export fn on_enable() void {
    cfg.load();
    if (cfg.get("log_level")) |v| {
        const t = std.mem.trim(u8, v, " \"'");
        if (std.mem.eql(u8, t, "off")) {
            log_level = -1;
        } else if (std.mem.eql(u8, t, "info")) {
            log_level = 0;
        } else if (std.mem.eql(u8, t, "debug")) {
            log_level = 1;
        }
    }
    out.reset();
    out.put("core_tradefeed v1.0 enabled (log_level=");
    out.putInt(log_level);
    out.put(")");
    out.logLine(0);
}

export fn on_shutdown() void {
    out.reset();
    out.put("core_tradefeed shutdown");
    if (log_level >= 0) out.logLine(log_level);
}

export fn on_trader_event(player: i32, trader: i32, kind: i32) void {
    out.reset();
    out.put("trader event: player=");
    out.putInt(player);
    out.put(" trader=");
    out.putInt(trader);
    out.put(" kind=");
    switch (kind) {
        0 => out.put("open"),
        1 => out.put("buy"),
        2 => out.put("sell"),
        else => out.putInt(kind),
    }
    if (log_level >= 0) out.logLine(log_level);
}

comptime {
    // Declarative dependency check (paper: reactive coeffects): the host
    // rejects the module at load if any listed capability is missing.
    common.exportRequires("on_trader_event,config,log");
}
