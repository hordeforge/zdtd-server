// zdtd_tradefeed — a trader-event observer plugin (AGENTS.md rule 29,
// Wasm-first). Reference module for trader/vehicle announcements: observes
// on_trader_event (kind 0 open / 1 buy / 2 sell) and logs every trade window
// event, always keeping the stock outcome.
//
// Build (zig): see mods/BUILDING.md. Committed as zdtd_tradefeed.wasm.

const common = @import("plugin_common");

var out: common.Buf = .{};

export fn on_enable() void {
    out.reset();
    out.put("zdtd_tradefeed v1.0 enabled (trader events)");
    out.logLine(1);
}

export fn on_shutdown() void {
    out.reset();
    out.put("zdtd_tradefeed shutdown");
    out.logLine(1);
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
    out.logLine(1);
}

comptime {
    // Declarative dependency check (paper: reactive coeffects): the host
    // rejects the module at load if any listed capability is missing.
    common.exportRequires("on_trader_event,log");
}
