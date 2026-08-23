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
// Build (clang, committed as mods/zdtd_pricegate/zdtd_pricegate.wasm):
//   clang --target=wasm32 -nostdlib -O2 -Wl,--no-entry -Wl,--export-all \
//     -o mods/zdtd_pricegate/zdtd_pricegate.wasm mods/zdtd_pricegate/zdtd_pricegate.c
// Enable via zdtd.toml: [plugin] modules = "mods/zdtd_pricegate/zdtd_pricegate.wasm"

__attribute__((import_module("zdtd"), import_name("log")))
extern void zdtd_log(int level, int ptr, int len);

#define OUT_CAP 160
static char out[OUT_CAP];
static int out_n;

static void log_msg(const char *s) {
  out_n = 0;
  const char *p = s;
  while (*p && out_n < OUT_CAP - 1) out[out_n++] = *p++;
  zdtd_log(0, (int)(long)out, out_n);
}

__attribute__((export_name("on_enable")))
void on_enable(void) {
  log_msg("zdtd_pricegate v1.0 enabled (1.5x trader prices)");
}

__attribute__((export_name("on_shutdown")))
void on_shutdown(void) {
  log_msg("zdtd_pricegate shutdown");
}

__attribute__((export_name("on_trade_price")))
int on_trade_price(int player, int item, int unit_price) {
  (void)player;
  (void)item;
  (void)unit_price;
  return 150; // 1.5x on every buy
}
