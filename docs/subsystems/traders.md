# Traders, vending and prices

This subsystem owns the trader entity and everything a trade window needs: the per-trader stock rows, wallet, open/close hours and restock interval on the sim side; the XML roll that produces those rows and the price math applied to them; the vending machine tile entities keyed by world position; and the wire that opens a window, echoes a trade and applies the client's post-trade copy. It does not own the quest list a trader offers (`c2s/quest.zig` builds it from the quest catalog), the lock channel itself (`c2s/misc.zig`), or the generic inventory primitives (`ecs/inventory.zig`).

The boundary is layered by package. `server` sits at the top of the stack and may import all other packages (src/server/root.zig:3). `world` owns vending domain state and may import `util`, `assets` and pure `ecs` types, but must not import `wire`, `server` or `litenet` (src/world/root.zig:3-6): that is why `Vending` stores ownership as fixed byte buffers and the wire identity conversion happens in `replicate_te.zig`. `assets` may import `util` and pure `ecs` types, and must not import `world`, `server` or `wire` (src/assets/root.zig:3-6). Sim authority is the `TraderStock` column in `ecs`; `wire` re-exports the domain types rather than the reverse.

Sources: [`src/server/game/trader.zig`](../../src/server/game/trader.zig), [`src/server/game/trader_wire.zig`](../../src/server/game/trader_wire.zig), [`src/world/vending.zig`](../../src/world/vending.zig), [`src/assets/traders.zig`](../../src/assets/traders.zig), [`src/server/game/replicate_te.zig`](../../src/server/game/replicate_te.zig), [`src/wire/stock_entity.zig`](../../src/wire/stock_entity.zig), [`src/ecs/systems.zig`](../../src/ecs/systems.zig), [`src/ecs/components.zig`](../../src/ecs/components.zig).

## Sim state for a trader

One `TraderStock` component instance per trader slot holds the live window. `name` must point at static data because the component outlives any arena, and `trader_info_id` is the `traders.xml` `<trader_info>` id that selects stock, hours and pricing. The per-row price and sell fields are computed once at fill time, not per trade.

The trader stock record (src/ecs/components.zig:978):

```zig
pub const TraderStock = struct {
    /// Trader display name. Must point to static/indefinite-lifetime data
    /// (comptime literal or binary-embedded table). Never assign an
    /// arena/allocator-owned slice.
    name: []const u8 = "Trader",
    /// traders.xml `<trader_info>` id for this trader (0 = generic/default).
    trader_info_id: u16 = 0,
    /// Live AvailableMoney (stock debits it when buying from the player and
    /// credits it when selling to them; the wire TraderData shows this).
    wallet: i32 = 0,
    /// Restock target the wallet regrows toward (initial spawn amount).
    wallet_default: i32 = 0,
    /// traders.xml `<trader_info>` ResetInterval: -1 = never restock, 0 =
    /// daily (spawn default), >0 = days between restocks. The timer row
    /// (systems.traderRestock) owns the math.
    reset_interval: i32 = 0,
    /// Game day of the last restock; traderRestock skips a trader until
    /// day >= last_restock_day + reset_interval (0 interval always restocks).
    last_restock_day: u32 = 0,
    /// Edge latch for the open/close cycle (EntityTrader::OnUpdateLive):
    /// true = the area currently shows closed (gates locked, window denied).
    is_closed: bool = false,
    entries: [max_stock]StockEntry = defaultStock(),
    n: usize = 5,
};
```

One stock row (src/ecs/components.zig:946), the sim-side owner of the wire entry:

```zig
pub const StockEntry = struct {
    item: u16 = 0,
    count: u16 = 0,
    /// Rolled ItemValue quality (traders.xml quality="lo,hi"); 1 for
    /// stackables without a quality range.
    quality: u8 = 1,
    price: u16 = 0,
    sell: u16 = 0,
    /// TraderData.Entry.Markup (sbyte demand delta). Stock raises it to +100 on
    /// a buy and steps it down by 4 on a sell (asm.il 856828-856866); the wire
    /// TraderData carries it so the client shows the demand arrows and (for
    /// player-owned/rentable machines) prices from 1 + Markup*0.2. Fresh stock
    /// and restocks reset it to 0.
    markup: i8 = 0,
```

The comment above `markup` describes stock behavior that the zdtd trade path deliberately does not reproduce: `systems.trade` changes no markup on either side (src/ecs/systems.zig:1533-1538 and :1628-1629). `docs/GAMEPLAY.md:98` still states the +100 / -4 rule, so the doc and the code disagree here as of this reading.

Trader money resolves through one helper: a trader with a nonzero `wallet_default` reports its live wallet, anything else falls back to the `[sim] trader_wallet_dukes` default (src/server/game/trader.zig:17). Hours come from `open_time` / `close_time` as `"H:MM"`, converted to minutes and compared against a 24000-tick world clock rescaled to a day (src/server/game/trader.zig:36-46). A trader whose `trader_info` is missing or vending is always open (src/server/game/trader.zig:38-40).

## The traders.xml roll

`TraderTable` is the parsed catalog: groups, per-trader `trader_info` rows, the `traderAlways` fallback refs, and the root economy attributes (`buy_markup`, `sell_markdown`, `quality_mod`, `quest_tier_mod`, `currency_item`) (src/assets/traders.zig:137-158). `loadFromPath` parses it from a comment-stripped file and fails with `OpenFailed` when there are no groups or no `trader_info` rows (src/assets/traders.zig:439, :478, :564).

The per-trader row and one item reference (src/assets/traders.zig:30 and :114):

```zig
pub const ItemRef = struct {
    name: []const u8 = "",
    count_min: u16 = 1,
    count_max: u16 = 1,
    /// prob attr (default 1). Group-internal picks are weighted by prob share
    /// (stock TraderInfo::SpawnLootItemsFromList: acc += prob / sum), so 120
    /// is a heavier weight, 0.5 is half weight, 0 never picks.
    prob: f32 = 1,
    /// quality="lo,hi" roll bounds. -1/-1 = the attribute is absent, which is
    /// what stock `TradersFromXml::parseItemList` passes for minQualityBase /
    /// maxQualityBase (the `ldc.i4.m1` pair, TradersFromXml.il:558-563 and
    /// :790-792); `SpawnItem` substitutes the default range for those.
    quality_lo: i16 = -1,
    quality_hi: i16 = -1,
    unique_only: bool = false,
    group: bool = false,
};
```

```zig
pub const TraderInfo = struct {
    id: u16 = 0,
    /// "4:05" stock format; "" = no hours gate (always open).
    open_time: []const u8 = "",
    close_time: []const u8 = "",
    is_vending: bool = false,
    /// false → the trader does not buy from players (vending, player-owned).
    allow_sell: bool = true,
    /// 0 = unset (root economy / pricing row owns the price math).
    override_buy_markup: f32 = 0,
    override_sell_markup: f32 = 0,
    /// -1 = never; >0 = days between restock (restock row owns the timer).
    reset_interval: i32 = 0,
    player_owned: bool = false,
    rentable: bool = false,
    rent_cost: i32 = 0,
    /// Stock default when `rent_time` is omitted (traders.xml rentable rows
    /// write 30; Match stock `TraderInfo` ctor default).
    rent_time: i32 = 30,
    /// Union of every `<trader_items>` block, in XML order (SPECIALTY first).
    refs: []const ItemRef = &.{},
};
```

The roll is a port of stock `TraderInfo::Spawn` with a caller-seeded RNG, so the same world seed, trader and day reproduce the same window. `rollAllRefs` rolls each top-level ref's count, scales it by the sandbox abundance and floors at 1; a group ref expands through `spawnItemsFromGroup`, which rolls a pick count per round and hands it to `spawnLootItemsFromList`, where one `RandomFloat` walks the refs accumulating prob share and the first ref past the roll spawns (src/assets/traders.zig:194-245, :263-280). `spawnItem` then applies the quality rules in stock order, including the `TraderMaxTier` clamp and the drop when the clamped maximum falls below the minimum (src/assets/traders.zig:297-316). `QualityPolicy` carries `max_tier`, the fallback pair and the `HasQuality` callback; the defaults live in `[rules.trader]` (`max_tier = 6`, `default_quality_min = 1`, `default_quality_max = 6` at src/ecs/rules.zig:779-792) and `Game.qualityPolicy` binds them plus the items table (src/server/game/trader.zig:135-144).

## Filling a window and resolving prices

`rollStockRefs` picks the ref list (own `trader_items`, else `traderAlways` only when the `trader_info` row did not resolve), copies `reset_interval` onto the sim stock and rolls with `XorShift32` seeded by `traderRollSeed` = (world seed, trader net id, day) (src/server/game/trader.zig:149-190). `fillTraderFromXml` then turns each rolled item into a priced row.

The price assignment (src/server/game/trader.zig:253-260):

```zig
        self.sim.trader_stock[s].entries[n] = .{
            .item = iid,
            .count = r.count,
            .quality = r.quality,
            .price = if (econ > 0) ecs.systems.clampDukesUnitPrice(@as(f64, econ) * @as(f64, buy_markup) * @as(f64, qmod) / bundle, 5) else 5,
            .sell = if (econ > 0) @max(1, ecs.systems.clampDukesUnitPrice(@as(f64, econ) * @as(f64, sell_scale) * @as(f64, sell_markup) * @as(f64, qmod) / bundle, 1)) else 1,
            .stats = srolled.stats,
            .stats_n = srolled.n,
        };
```

`econ` is `items.xml EconomicValue`, `bundle` is `EconomicBundleSize` with a floor of 1, and `sell_scale` is `EconomicSellScale` (src/assets/items.zig:224, :235, :239). The quality lerp `qmod` is `qualityPriceMod(iqmin, iqmax, quality)`, a lerp from the minimum multiplier at quality 1 to the maximum at quality 6 (src/ecs/systems.zig:1441-1445). The per-item `TraderQualityMod` pair wins over the trader's root `quality_mod` when the item declares one (src/server/game/trader.zig:245-248; item fields at src/assets/items.zig:230-231). The buy side multiplies `econ` by the resolved buy markup and the sell side by `sell_scale * sell_markup`. When no `trader_info` override and no root row exist (the offline builtin catalog), the defaults are `default_buy_markup = 1.0` and `default_sell_markdown = 0.02` (src/assets/traders.zig:108-109, used at src/server/game/trader.zig:214-217).

Stock quality rules are shared by both roll sites: `Game.qualityPolicy` is built from `[rules.trader]` plus the items table so neither the trader stock nor the vending store carries private defaults (src/server/game/trader.zig:131-144).

## Trade requests and validation

zdtd's trade body is not a stock package. It is exactly 9 bytes (trader entity i32, item u16, qty u16, side u8) and rides under the `NetPackageTraderData` name for loadgen, while a real client's trade arrives as its post-trade `TraderData` copy (src/wire/packages.zig:5864-5877). The router therefore discriminates on length: bodies longer than 9 bytes parse as the stock ToServer header, exactly 9 with `body[8]` 0 or 1 goes to `handleTrade`, and anything else is treated as a window open (src/server/c2s/quest.zig:539-568).

`handleTrade` validates in this order (src/server/game/trader_wire.zig:52-99): parse the body, resolve the trader entity and require the sender within `trade_use_range` of it, reject a sell of an item whose `SellableToTrader` is false, reject a sell when the `trader_info` `allow_sell` is false, then call `systems.trade` with the coin item id. Every rejection that carries a distance or item verdict increments `bounds_rejects`. A successful trade fires the plugin trader event (kind 1 buy, 2 sell) and re-sends a snapshot.

The reach gate is shared by the trade, the `TraderData` echo and the window open, so one config key governs all three (src/server/game/trader_wire.zig:224-235). `systems.trade` is the money and goods owner: it requires a nonzero quantity and a resolved coin item, syncs the wallet from inventory coins, prices a buy from the entry (with an optional price verdict and barter hook), spends coins from the inventory first, deposits the bought stack with its stat roll, and credits the trader's wallet; the sell path prices from the sold stack's quality and `PercentUsesLeft`, refuses once the trader's money pool runs out, and moves goods and coins atomically (src/ecs/systems.zig:1447-1636).

The stock echo path is `applyTraderDataCopyFrom`, which reads the `TraderData::Write` blob, resolves every entry by item type rather than by index, validates quality into 1..6 and aborts the whole batch on a bad entry before mutating anything (src/server/game/trader_wire.zig:101-161). For a trader entity it applies count, quality and markup to matched rows, clears rows the echo no longer carries, adopts `money` when present, and re-sends the snapshot.

The server-side trader payload is one shared encoder: `writeTraderDataBody` writes trader id, a zero `lastInventoryUpdate`, `FileVersion = 2`, the entry count, each `ItemStack` plus markup byte and an `AddedByPlayer` false, a zero tier-group count, then `availableMoney` (src/wire/stock_entity.zig:262-282). Both S2C paths embed that block; a server-sent `NetPackageTraderData` is not a delivery path (src/wire/stock_entity.zig:198-201). `Game.sendTraderSnapshot` is a documented no-op for the same reason: stock never emits the ToClient form, and stock reaches the client through the spawn `EntityCreationData` and the `EntityTraderLockContext` on `NetPackageLockResponse` (src/server/game/join.zig:273-280).

## Opening a window

A trader window opens on `NetPackageLockRequest`, not on a trade body. On grant, the lock path calls `maybeRestockTrader` for the resolved trader slot, fires `questOnTraderOpen` so quest turn-ins advance, builds the entries with `stockEntries`, and sends `buildLockResponseTrader` carrying `trader_info_id`, the live money and the entry list (src/server/c2s/misc.zig:1119-1141). Restock is lazy and lives on that open path: `maybeRestockTrader` returns immediately for `reset_interval < 0`, waits out the interval otherwise, re-runs `fillTraderFromXml`, pins `last_restock_day` and raises the wallet back to its default when it has fallen below (src/server/game/trader.zig:263-284).

`stockEntries` converts sim rows to wire entries, skipping zero-count rows, resolving the stock wire type per item and copying the stocked stat roll into the entry's stat triple (src/server/game/trader_wire.zig:20-50). Two independent restock mechanisms exist and both are real: the open path above rebuilds the whole window, while the daily `systems.traderRestock` grows counts toward `[sim] trader_restock_cap`, resets markup to 0 and raises the wallet to the default without re-rolling names (src/ecs/systems.zig:1642-1666). GAMEPLAY's flow diagram names only the lazy open path.

## Vending machines

Vending machines are position-keyed domain records, deliberately free of wire types. `noteBlockAdded` creates one when a block whose type `isVending` appears at a cell, taking the trader id from the block's `blocks.xml TraderID` (src/server/game/world.zig:383-387). Removal clears the slot (src/server/game/world.zig:364).

The record and its store (src/world/vending.zig:64 and :104):

```zig
pub const Vending = struct {
    pos: PosKey = .{ .x = 0, .y = 0, .z = 0 },
    block_id: i32 = 0,
    /// TraderID from blocks.xml (TraderData.TraderID; resolves trader_info).
    trader_id: i32 = 0,
    available_money: i32 = 0,
    stock: [max_vending_stock]StockEntry = [_]StockEntry{.{}} ** max_vending_stock,
    stock_n: u8 = 0,
    is_locked: bool = false,
    owner: UserRef = .{},
    password_hash: [max_password_hash]u8 = .{0} ** max_password_hash,
    password_len: u8 = 0,
    allowed: [max_allowed_users]UserRef = [_]UserRef{.{}} ** max_allowed_users,
    allowed_n: u8 = 0,
    /// In-game day the rental expires (0 = not rented; ClearVendingMachine on
    /// currentDay > rental_end_day).
    rental_end_day: i32 = 0,
    /// trader_info Rentable drives the optional nextAutoBuy u64 on the wire.
    rentable: bool = false,
    next_auto_buy: u64 = 0,
```

`VendingStore` is a fixed array of 128 records with a `used` bitmap and no heap on the tick path; `getOrCreate` returns null at cap rather than growing, and a freed slot is fully reset before reuse (src/world/vending.zig:104-140). Opening a machine on `LockRequest` fills the store from `trader_info` when `stock_n == 0`, sends the `TraderData` entries under the vending lock context and then pushes the full TE (src/server/c2s/misc.zig:1142-1157). `fillVendingStore` seeds rows at markup 0 because vending is owner-priced: the `trader_info` buy and sell multipliers do not apply (src/server/game/replicate_te.zig:314-359). The TE body carries the lock flag, owner identity, password string, allowed-user list, rental end day, the same `TraderData` block and, when rentable, `nextAutoBuy` (src/wire/stock_te.zig:1228-1277).

Two C2S paths write machine state. Owner edits (lock, password, allowed users) arrive as a full vending TE, are range-gated and owner-gated, and are re-sent to the sender (src/server/c2s/inv.zig:411-467). Rent and clear arrive as `NetPackagePlayerVendingMachine`: only the sender's own platform identity may act, rent costs `trader_info.rent_cost` in the coin item, one machine per player is enforced, and the term is `rent_time` or 30 days when unset; clear requires ownership and calls `clear`, which returns the machine to unowned while keeping the block identity and stock (src/server/c2s/quest.zig:619-689; `clear` at src/world/vending.zig:88-100). A purchase or owner edit reaches nearby clients through `broadcastVendingTe`, which approximates stock's listener set with the interest range (src/server/game/replicate_te.zig:428-441).

The stock rows of a machine are not server-rolled after seeding: the vendor branch of `applyTraderDataCopyFrom` validates only that each echo entry has a resolvable name and a quality in 1..6, then rewrites the machine's rows from the echo and recounts `stock_n` to the last non-empty row (src/server/game/trader_wire.zig:164-221). Treat the vending stock contents as client-authored and the pricing as server-owned; the reach gate is the only distance check on that write.

## Wiring, persistence and config

Per tick, `tickTraderAreas` walks every trader slot, recomputes the open/closed edge from the clock, and on a change releases a held trader lock channel with an unlock response before toggling the area gates (src/server/game/trader.zig:48-71, called from src/server/game/step.zig:282). Gate toggling finds the trader-area decoration the trader stands in (an 8-block pad around the prefab bounds), scans the block column and rewrites the `isOn` meta bit on every `isTraderOnOff` block, broadcasting `NetPackageSetBlock` to nearby peers (src/server/game/trader.zig:73-124).

Traders are spawned from POI prefab metadata: `spawnPoiTraders` builds `npcTrader<tag>` from the prefab's trader tag, spawns the entity and immediately calls `fillTraderFromXml` (src/server/game/hooks.zig:33-54). The offline demo seed spawns one `Trader Jen` and fills it the same way (src/server/game/init_world.zig:279-287).

Two files persist this subsystem in the world directory. Trader stock goes to `traders.zst` (magic `ZTR1`, version 2 with the stat blob per entry), keyed by trader stock name rather than slot so a map change cannot bind a record to the wrong trader; a missing live trader's record is still fully consumed (src/server/persist.zig:2059, :2146-2204). Vending machines go to `vending.zvn` (magic `ZVNM1`, magic, count, then full records with stock, ownership, password, allowed users and rental term); the loader is fail-closed on an over-long password length or a declared allowed-user count past the fixed array, and it consumes a dropped record whole so following machines do not desync (src/world/vending.zig:152-164, :252-329).

Configuration is TOML over struct fields, not per-key parse arms: `[sim] trader_use_range`, `trader_wallet_dukes`, `trader_restock_cap` and `trader_restock_refill` (src/server/zdtd_config.zig:117, :129, :130, :148). The two abundance multipliers are not zdtd.toml keys: `TraderItemAbundance` and `VendingItemAbundance` come from the sandbox block of the stock server config (src/server/config.zig:98-101, parsed at :373-376). `[rules.trader]` owns `max_tier` and the fallback quality range (src/ecs/rules.zig:779-792).

## See also

- [World store and tile entities](world-store.md)
- [Stock asset and XML loading](assets.md)
- [Configuration and tunables](config.md)
- [C2S handling](c2s.md)
- [Gameplay behavior flows](../GAMEPLAY.md)
