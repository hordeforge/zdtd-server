// zdtd_pricegate — trader price scaling via the on_trade_price pre-trade
// verdict (ADR-worthy boundary extension; on_trader_event fires only AFTER a
// trade, so this hook is the pre-execution price slot).
//
// Verdict convention (docs/PLUGIN_DEV.md "Hooks"):
//   on_trade_price(player: i32, item: i32, unit_price: i32) -> i32
//     <0  deny the trade entirely
//      0  keep the stock price
//     >0  scale the unit price by percent (150 = 1.5x)
//
// The host consults the verdict in the sim buy path (ecs/systems.zig trade)
// before any wallet/stock mutation, so a module shapes the price without
// touching inventory directly.
//
// Default policy: 150 (1.5x) on every buy. Specialize per item for per-item
// rules, e.g.:
//   if (item == 2) return 0;      // food stays at stock price
//   if (item == 6) return 250;    // dukes cost 2.5x
//
// Build (zig): see mods/BUILDING.md. Committed as zdtd_pricegate.wasm.

const common = @import("plugin_common");

var out: common.Buf = .{};

export fn on_enable() void {
    out.reset();
    out.put("zdtd_pricegate v1.0 enabled (1.5x trader prices)");
    out.logLine(0);
}

export fn on_shutdown() void {
    out.reset();
    out.put("zdtd_pricegate shutdown");
    out.logLine(0);
}

export fn on_trade_price(player: i32, item: i32, unit_price: i32) i32 {
    _ = player;
    _ = item;
    _ = unit_price;
    return 150; // 1.5x on every buy
}
