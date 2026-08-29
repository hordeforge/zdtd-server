// core_pricegate — trader price scaling via the on_trade_price pre-trade
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
// Policy comes from this mod's own config.toml (the host serves it via the
// zdtd.config import): `price_percent` defaults to 150 (1.5x) on every buy.
// Nothing is hardcoded here; edit config.toml to change the policy without
// rebuilding the wasm.
//
// Build (zig): see mods/BUILDING.md. Committed as core_pricegate.wasm.

const common = @import("plugin_common");

var out: common.Buf = .{};
var cfg: common.Config = .{};
var price_percent: i32 = 150;

export fn on_enable() void {
    cfg.load();
    if (cfg.getInt("price_percent")) |v| {
        // Fail closed: an out-of-range value keeps the default instead of
        // shipping a negative or absurd multiplier.
        if (v >= 0 and v <= 10000) price_percent = @intCast(v);
    }
    out.reset();
    out.put("core_pricegate v1.0 enabled (price_percent=");
    out.putInt(price_percent);
    out.put(")");
    out.logLine(0);
}

export fn on_shutdown() void {
    out.reset();
    out.put("core_pricegate shutdown");
    out.logLine(0);
}

export fn on_trade_price(player: i32, item: i32, unit_price: i32) i32 {
    _ = player;
    _ = item;
    _ = unit_price;
    return price_percent;
}

comptime {
    common.exportRequires("on_trade_price,config,log");
}
