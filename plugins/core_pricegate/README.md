# core_pricegate

Trader price scaling via the `on_trade_price` pre-trade verdict.

## What it is

Scales the unit price of every buy from a trader by a configurable percent
(150 = 1.5x) before the sim applies wallet/stock mutations. The first
self-contained plugin: its policy lives in this folder's `config.toml`, not
in the wasm.

## Hooks

- `on_trade_price(player, item, unit_price) -> i32` (<0 deny the trade, 0 keep
  the stock price, >0 scale by percent)

## Config

`config.toml` (served via the `zdtd.config` import):

```toml
price_percent = 150   # 150 = 1.5x on every buy; 0 keeps the stock price
```

Edit the file to change the policy; no rebuild needed.

## Enable

Ships `enabled = false` (demo gate). Load explicitly via
`[plugin] modules = "plugins/core_pricegate/core_pricegate.wasm"` in zdtd.toml.

## Layout (self-contained)

- `manifest.toml` - module manifest
- `core_pricegate.wasm` - committed build of `core_pricegate.zig`
- `core_pricegate.zig` + `main.zig` - Zig source (rebuild: `scripts/build-plugins.sh`)
- `config.toml` - default config, served to the module via the `zdtd.config` import
- `README.md` - this file
