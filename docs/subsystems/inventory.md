# Inventory and item ledger

This subsystem owns player and container inventory: the fixed 67-slot array and its stack and durability semantics, the item ledger that records why an inventory delta happened, the stock inventory wire bodies (`ItemValue`, `ItemStack`, `Bag`, `Equipment`, `PlayerInventory`, `HoldingItem`), and the C2S handlers that apply or reject client inventory operations. The boundary runs along three seams. `ecs` owns the slot record and the transaction algebra and knows nothing about the wire. `wire/stock_inv.zig` owns every byte layout and knows nothing about `Client` or interest. `server/c2s/inv.zig` owns the trust decisions, the rate gate, and the broadcast of resulting state. Where a container sits in the world, and how a placed block lands, belongs to `world`; recipe and item catalog data belongs to `assets`; quest and trader coupling is delegated out through `ecs/systems.zig` and the trader store. Import rules come from each package root: `ecs` "may import util only. Must not import wire, server, world, assets, litenet, or apm" (src/ecs/root.zig:3), `wire` "may import util, assets (id pins, unity hash), ecs component shapes, and world container/workstation domain types for TE apply. It must not import server or litenet" (src/wire/root.zig:3), and `server` is "top of the stack. May import all other src packages" (src/server/root.zig:3). The slot is therefore split in two, `components.InvSlot` for the sim and `stock_inv.StockSlot` for the wire, and the edge is crossed by copying fields in `slotFromEcs` and `toEcs` (src/wire/stock_inv.zig:335, 1004).

Sources: [`src/ecs/inventory.zig`](../../src/ecs/inventory.zig), [`src/ecs/inv_ledger.zig`](../../src/ecs/inv_ledger.zig), [`src/ecs/components.zig`](../../src/ecs/components.zig), [`src/ecs/world.zig`](../../src/ecs/world.zig), [`src/wire/stock_inv.zig`](../../src/wire/stock_inv.zig), [`src/wire/packages.zig`](../../src/wire/packages.zig), [`src/server/c2s/inv.zig`](../../src/server/c2s/inv.zig), [`src/server/game/craft.zig`](../../src/server/game/craft.zig), [`src/server/game/loot.zig`](../../src/server/game/loot.zig), [`src/server/persist.zig`](../../src/server/persist.zig).

## Slot model

One `Inventory` component covers toolbelt, bag, and equipment; the split is pure indexing. The layout constants and their comptime invariants (src/ecs/components.zig:584):

```zig
/// Toolbelt 0..9, bag 10..54, equipment 55..66 (armor slots), total 67 -
/// the full stock wire layout (toolbelt 10, bag 45, equip 12). The earlier
/// 32-bag subset (ADR 0007) dropped client bag slots 33..45 and equipment
/// 5..11 on the C2S apply, losing items on relog; resolved 2026-08-22.
pub const inv_toolbelt: usize = 10;
pub const inv_bag_start: usize = 10;
pub const inv_bag_count: usize = 45;
pub const inv_equip_start: usize = 55;
pub const inv_equip_count: usize = 12;
pub const max_inv_slots: usize = inv_equip_start + inv_equip_count; // 67
pub const inv_no_holding: u16 = 0xFFFF;
```

A comptime block below those constants fails the build if the bag stops being contiguous with the toolbelt or if `max_inv_slots` diverges from the equip end (src/ecs/components.zig:598). The slot record itself (src/ecs/components.zig:716):

```zig
pub const InvSlot = struct {
    item_id: u16 = 0,
    count: u16 = 0,
    quality: u8 = 0,
    meta: u16 = 0, // durability / flags
    /// Stock ItemValue.UseTimes (remaining uses; f32 on the wire). Tools wear
    /// down to 0 and stay present (broken) until repaired; persisted since
    /// players.zsv ZPV7.
    use_times: f32 = 0,
    /// Stock ItemValue.Seed (u16): the per-item random seed seed-items carry
    /// so the same planted seed grows the same way (meta is durability/flags,
    /// not the seed).
    seed: u16 = 0,
```

The remaining fields are `flags: u8`, `mods: [4]u16`, `mod_n: u8`, `mod_qualities: [4]u8`, `stats: [max_item_stats]ItemStat`, `stats_n: u8` (src/ecs/components.zig:732). The component adds only the held index and the open container (src/ecs/components.zig:784):

```zig
pub const Inventory = struct {
    slots: [max_inv_slots]InvSlot = [_]InvSlot{.{}} ** max_inv_slots,
    /// Held toolbelt index 0..inv_toolbelt-1, or inv_no_holding.
    holding: u16 = 0,
    /// Open container entity net id (-1 = none).
    open_container: i32 = -1,
```

`setHolding` accepts only `0..inv_toolbelt-1` and folds an empty slot to `inv_no_holding` (src/ecs/components.zig:800); `takeFromSlot` does the same when the held slot empties (src/ecs/components.zig:895). Stack caps come from the catalog through `World.maxStack`, which calls the `stack_fn` hook and falls back to the offline builtin table only when no catalog is wired (src/ecs/world.zig:711; src/ecs/components.zig:765). `addSlotStacked` is all-or-nothing: it sums room across `slots[0..inv_equip_start]` first and returns false without mutating when the whole deposit will not fit, because callers refund on failure and a partial deposit would duplicate items (src/ecs/components.zig:825). Merging requires `item_id`, `quality`, and `meta` to match, so tool tiers and worn durability never blend (src/ecs/components.zig:831); a fresh slot takes the whole value, keeping stats, mods, and `use_times` (src/ecs/components.zig:857). `moveSlot` has three outcomes: place into an empty slot, merge when quality and meta match and there is room, otherwise swap whole stacks only, and it keeps `holding` pointing at the moved stack (src/ecs/components.zig:915). `World.depositItem` is the preferred production deposit because it honors the catalog cap (src/ecs/world.zig:729); `Inventory.addItem` is the catalog-free variant (src/ecs/components.zig:813).

Durability is `use_times`, counting uses consumed upward from 0. `degradeUse` adds the item's `items.xml` `DegradationPerUse` through the `item_degradation_fn` hook, or the caller's amount when no row exists, and stops once the percent-uses-left resolver reads 0 so a broken tool does not run the counter up forever (src/ecs/inventory.zig:302). The comment on that function records that a previous subtract-toward-zero version was a permanent no-op, because every item enters the world at 0 and the clamp branch always won (src/ecs/inventory.zig:288). Stock keeps the broken stack present and repairable, and so does this path.

## Item ledger

The ledger is a fixed overwrite ring on `World`, no allocation, sized for evidence rather than audit (src/ecs/inv_ledger.zig:19):

```zig
pub const Event = struct {
    peer: u16 = 0,
    item_id: u16 = 0,
    /// Signed delta: positive = gained, negative = lost (magnitude in low bits).
    delta: i16 = 0,
    cause: Cause = .unknown,
};

/// Overwrite ring of the last `capacity` successful inv mutations.
pub const Ledger = struct {
    events: [capacity]Event = [_]Event{.{}} ** capacity,
    /// Next write index (mod capacity).
    head: u8 = 0,
    /// How many slots hold a real event (0..capacity).
    len: u8 = 0,
    /// Lifetime record count (wraps with +%).
    total: u64 = 0,
```

`capacity` is 32 (src/ecs/inv_ledger.zig:17) and the cause set is eight values, `loot`, `craft`, `give`, `place`, `eat`, `drop`, `tx`, `unknown` (src/ecs/inv_ledger.zig:6). Deltas are clamped into `i16`, not truncated, at every call site (src/ecs/inventory.zig:180, 234, 259). All ECS-side writes funnel through `recordInv`, which narrows the peer slot to `u16` and calls `Ledger.record` (src/ecs/inventory.zig:609). The cause mapping is one per operation: `move` records `.tx` (src/ecs/inventory.zig:235), `drop` records `.drop` (src/ecs/inventory.zig:260), `useEx` records `.eat` (src/ecs/inventory.zig:407), `placeBlock` records `.place` (src/ecs/inventory.zig:557), `takeFromContainer` records `.loot` (src/ecs/inventory.zig:487), `putIntoContainer` records `.tx` (src/ecs/inventory.zig:508), and `give` records `.give` (src/ecs/inventory.zig:180). Craft bypasses `recordInv` and appends directly (src/server/game/craft.zig:479), and admin give does the same (src/server/game/step.zig:629). `collectBagFull` records only after the whole bag transferred, so a refused collect leaves no loot credit (src/ecs/inventory.zig:204).

The only read side wired today is the apm counter: the C2S transaction arm samples `total` before and after the apply and adds the difference to `inv_ledger_events` (src/server/c2s/inv.zig:979; src/apm/metrics.zig:46). `Ledger.recent` and `Ledger.last` exist and are covered by unit tests (src/ecs/inv_ledger.zig:50, 63) but have no production caller in this reading, so the ring is written and not yet dumped or persisted; a restart starts it empty.

## Stock inventory wire bodies

`StockSlot` mirrors the ECS slot with an absolute stock type instead of a catalog handle (src/wire/stock_inv.zig:45):

```zig
pub const StockSlot = struct {
    /// Absolute ItemValue.type (block id < items_start_here, or items_start_here + item index).
    /// Prefer encodeItemType() helpers for item classes.
    type_id: i32 = 0,
    count: u16 = 0,
    quality: u16 = 0,
    meta: u16 = 0,
    use_times: f32 = 0,
    seed: u16 = 0,
    /// ItemValue.Flags byte (V3.2.0, changelog-3.2.0 §3.4): bit 0 =
    /// Activated (the old byte field), bit 1 = WasCombined. Same wire
    /// position/width, so the byte plumbing is unchanged.
    flags: u8 = 0,
    ammo_index: u8 = 0,
```

The rest of the wire slot carries the mod id array, per-mod qualities, and the stat array (src/wire/stock_inv.zig:59). Emptiness is `type_id == 0` and encodes as the single byte `0` (src/wire/stock_inv.zig:105); a non-empty value writes save version 9, then a flags byte whose bit 0 means "type is relative to `ItemsStartHere`" and whose bit 2 means a stats array follows, then `UseTimes`, `Quality`, `Meta`, an empty metadata count, the stats, and the mod arrays (src/wire/stock_inv.zig:111). Item ids above `items_start_here` are re-based to relative form on write (src/wire/stock_inv.zig:120) and the installed mods are converted through the same resolver, writing 0 for an unresolvable mod rather than naming the wrong attachment (src/wire/stock_inv.zig:354). `ItemStack` is `count u16` plus the value when the count is non-zero (src/wire/stock_inv.zig:188), `Bag.Write` is version 1, slot count, stacks, a false locked flag, the touched flag, and a false preference flag (src/wire/stock_inv.zig:210), and the equipment section is a `WriteItemValueArray` plus one cosmetic id per slot and an unlocked count (src/wire/stock_inv.zig:220). The player inventory body is the stock section list in write order (src/wire/stock_inv.zig:228):

```zig
pub fn writePlayerInventory(
    w: *binary.Writer,
    toolbelt: []const StockSlot,
    bag: []const StockSlot,
    equipment: []const StockSlot,
    drag: ?StockSlot,
) !void {
    const has_tb = toolbelt.len > 0;
    try w.writeBool(has_tb);
    if (has_tb) try writeItemStackList(w, toolbelt);

    const has_bag = bag.len > 0;
    try w.writeBool(has_bag);
    if (has_bag) try writeBag(w, bag, true);

    const has_eq = equipment.len > 0;
    try w.writeBool(has_eq);
    if (has_eq) try writeEquipment(w, equipment);
```

`buildFromEcsResolved` pads the toolbelt to 10 and the bag to 45 wire slots, taking the bag from `inv_bag_start` and the equipment from `inv_equip_start` (src/wire/stock_inv.zig:273). Stock treats player `NetPackagePlayerInventory` as C2S only (docs/wire/INVENTORY.md:72), so zdtd never sends it unsolicited: the encoder is reached only through `buildInventorySnap` for a transaction response (src/server/game.zig:3311) and through the container response for a non-player inventory by entity id (src/server/c2s/inv.zig:1052). The drag stack is parsed for stream correctness and dropped, because the ECS has no drag slot (src/wire/stock_inv.zig:869, 874). Holding is the one S2C-valid inventory package, built by `writeHoldingItem` as entity id, item stack, and a one-byte holding index (src/wire/stock_inv.zig:256); at join it is sent with an empty stack and only the index, since the PDF already carries the toolbelt (src/server/game/join.zig:728, 751).

## C2S operations and validation

`handle` claims nine names on the shared contract (src/server/c2s/inv.zig:79): `ItemReload`, `PlayerInventory`, `HoldingItem`, `ItemDrop`, `Bag`, `DropItemsContainer`, `TileEntity`, `InventoryTransactionRequest`, `InventoryDataRequest`. Every arm that mutates inventory or fans a relay out to peers takes the per-client inventory token bucket first and counts `c2s_throttle` when it is empty (src/server/game/rate_limits.zig:29). Container writes are additionally refused for a peer its guard policy quarantined off the container surface (src/server/c2s/inv.zig:324, 902). Ownership is enforced per target kind (src/server/c2s/inv.zig:338):

```zig
        } else if (self.sim.slotOfNetId(entity_id)) |si| {
            // Ownership: never let a peer write another player's inventory.
            if (self.sim.mask[si].player) {
                self.harness.counters.inc(.ownership_rejects);
                return true;
            }
```

`PlayerInventory` is the interim client-trusting path: the body is applied over the ECS inventory, then stacks are clamped to the catalog cap and attached mods are scrubbed when they exceed the item's mod-slot curve or fail the installability gate (src/server/c2s/inv.zig:134, 137, 45). The trust decision is ADR 0007 and is recorded as such (docs/AUTHORITY.md:48). Eatable stack loss across the apply is turned back into food, water, and HP through `applyEatProps`, with the per-push cap `rules.c2s.eat_units_per_push` (src/server/c2s/inv.zig:163). `HoldingItem` requires the claimed entity id to be the sender's or zero, writes the held index, and rebroadcasts the re-encoded body to every other peer (src/server/c2s/inv.zig:249, 266). `ItemDrop` reverses the stock type and drops only from a matching player stack; a claimed stack that is not present must not mint an item entity, so a failed drop produces no spawn and no spawn response (src/server/c2s/inv.zig:283, 294). `DropItemsContainer` is accepted and dropped outright: death containers are built from server-owned inventory, never from a client item list (src/server/c2s/inv.zig:397). `Bag` targets either the sender's own inventory or a non-player entity, the latter behind a container reach check (src/server/c2s/inv.zig:333, 349). Vehicle baskets take the parsed slots into a fixed array and are clamped like any client-writable slot group (src/server/c2s/inv.zig:371, 390).

`InventoryTransactionRequest` tries the stock `InventoryTransaction.Write` layout first and falls back to the native eleven-byte form (src/server/c2s/inv.zig:781, 874). The stock arm stages into a copy of the slot array and commits only on success, mirroring stock's apply-then-validate order, and rejects an unresolvable non-empty stack so the success bit stays honest (src/server/c2s/inv.zig:803, 821). On success it clamps, acks with the five-byte response, and on failure counts `c2s_rejects` and releases the peer's other locks (src/server/c2s/inv.zig:852, 868). The native arm dispatches through `invsys.Op` (src/server/c2s/inv.zig:891), guarding `open`/`take`/`put` on the container surface and `place` on the block surface (src/server/c2s/inv.zig:901). A place inside a claim the sender does not own is refunded and reported failed (src/server/c2s/inv.zig:941), a real place goes through `world.setBlockWorld` and is broadcast near (src/server/c2s/inv.zig:949), and a fuel item instead refuels a nearby vehicle or generator, refunding the consumed unit when neither accepts it (src/server/c2s/inv.zig:970). The response body is the native head plus a full inventory snapshot (src/server/c2s/inv.zig:982). `InventoryDataRequest` serves container slots for a GUID keyed world container, rolling its loot on first open, or a non-player entity inventory by id; a player's slots are never echoed (src/server/c2s/inv.zig:1010, 1047).

In `ecs/inventory.zig` the operation algebra is a switch over `Op` (src/ecs/inventory.zig:13) that returns a `Result` carrying not just success but the side effects `Game` must apply: a dropped entity id, a block to place and its coordinates, a fuel amount and item, the post-eat stat values, and the net id of an emptied bag so the Game can clear the owner's backpack marker (src/ecs/inventory.zig:32). `craft` and `scrap` deliberately return false here because they need recipes and the item name map, which live on `Game` (src/ecs/inventory.zig:604). Container take and put check reach on every call, not only on open, with a 3D distance against `rules.world.container_open_range`, so walking away ends the loot session (src/ecs/inventory.zig:432). Both preserve quality and meta through `restoreTaken` when the destination will not accept the stack (src/ecs/inventory.zig:469, 616). `openContainer` refuses an entity that carries the player mask, which stops a peer opening another player's bag and then taking through it (src/ecs/inventory.zig:417).

## Craft, scrap, and loot fill

The general inventory craft path deliberately excludes recipes the player inventory never offers (src/server/game/craft.zig:392):

```zig
pub fn generalCraftAllowed(recipe: assets_recipes.RecipeDef) bool {
    return recipe.craft_area.len == 0 and recipe.craft_tool.len == 0 and !recipe.material_based and !recipe.wildcard_forge_category;
}
```

`tryCraftRecipe` resolves the recipe name to an ECS id, checks the recipe unlock requirement, folds the crafting tier from the player's skill and perk rows, and runs the `on_craft_request` plugin verdict, which can deny the craft or cap the batch (src/server/game/craft.zig:396, 400, 405, 412). Ingredient counts are folded through `assets_recipes.ingredientCount` at the crafting tier, aggregated by ECS id so duplicate lines do not double-count room, and checked against `countItem` before anything is removed (src/server/game/craft.zig:429, 453). The apply is bracketed by a whole-inventory snapshot: any failing remove or deposit restores the exact pre-craft bag (src/server/game/craft.zig:461, 464, 474). A quality item carries the crafting tier as its quality and takes a free slot rather than merging across tiers (src/server/game/craft.zig:360, 469). Success appends a `.craft` ledger event, notifies quest craft progress, and grants XP only when the recipe declares a non-zero `craft_exp_gain`, since every shipped declared value in the audited recipes is 0 (src/server/game/craft.zig:479, 481, 491). Scrap is one craft of the stub recipe selected by `GetScrapableRecipe`, which needs a `MadeOfMaterial` with a forge category, an item that is not `NoScrapping`, and an output whose weight fits `weight * count` (src/server/game/craft.zig:502, 540); it snapshots and restores the same way, and reuses the `.craft` cause because there is no scrap-specific cause yet (src/server/game/craft.zig:539, 565).

Loot fill writes the rolled stacks straight into a bag entity's inventory: the bag is cleared first so a denied or empty roll leaves an empty bag rather than stale contents, the stack count is re-capped after the `on_loot_roll` verdict, quality respects `ItemClass.HasQuality`, and random durability becomes `use_times` from the same seeded stream (src/server/game/loot.zig:30). Bag entities are created with both the `loot_bag` and `inventory` masks, and `spawnLootBagFrom` copies a slot range of the dead player's inventory so a death bag holds real items rather than a placeholder (src/ecs/world.zig:1589, 1605). Item-drop spawns carry the bag's own transform, not the vector the client claimed, and the stock item entity class (src/server/game/loot.zig:225).

## Persistence and the tick path

Join carries the restored inventory in the player-id package: toolbelt from sim slots `0..9` and bag from `inv_bag_start` onward are encoded as stock slots, and the packet is only marked loaded on a first join (src/server/game.zig:2818, 2850, 2863). The equipment section of that same PDF is written as twelve empty item values and zero cosmetics (src/wire/packages.zig:622), so equipment slots are not restored from the join PDF as of this reading; that is a gap, not a stock behaviour. Client `NetPackagePlayerData` applies the same PDF layout over the live inventory, clamps it, and sets `players_dirty` so the file write happens on the periodic save rather than per packet (src/server/c2s/misc.zig:314, 353). The slot stride is versioned and the current record is 52 bytes (src/server/persist.zig:126):

```zig
pub fn zpvSlotStride(version: u8) usize {
    if (version >= 16) return 52; // 21 + stats_n u8 + 6 x (effect u8, two i16) (ZPV16)
    if (version >= 12) return 21; // 13 + 4 mod ids (ZPV12)
    if (version >= 10) return 13;
    return if (version >= 7) 11 else 7;
}
```

`savePlayers` writes a full slot record per occupied slot (src/server/persist.zig:867) and `tryRestorePlayer` reads it back into the ECS array (src/server/persist.zig:1067, 1124). The stride comment names what is not yet in it: `flags` and `mod_qualities` persist as their defaults, so a reloaded slot loses the activated flag and per-mod quality (src/ecs/components.zig:730, 753). The ledger is not part of that record.

Per-tick work is minimal by construction. No inventory system runs in the 50 ms tick for its own sake: the only scheduled inventory-adjacent work is the workstation craft step, on the sleeper cadence rather than every tick (src/server/game/step.zig:255; src/server/game/craft.zig:596). Loot bag collection is request-driven and funnels through `inventory.collectBagFull`, the single transfer rule the C2S collect arm calls and `systems.collectLootNear` shares (src/server/c2s/move.zig:93; src/ecs/systems.zig:1413). Tool wear happens on the attack and dig call sites through `degradeUse`, not on a tick (src/ecs/inventory.zig:302). Everything else is request-driven: a C2S arm applies a change, then broadcasts the resulting state or a holding echo.

## See also

- [ecs.md](ecs.md) - the SoA store, component masks, and where `Inventory` sits among the columns
- [c2s.md](c2s.md) - the dispatch order, phase gate, and rate-limit buckets that front these handlers
- [wire.md](wire.md) - package ids, framing, and the body builders this page's encoders sit under
- [../wire/INVENTORY.md](../wire/INVENTORY.md) - the inventory page in the wire series, with the op table and known gaps
- [../AUTHORITY.md](../AUTHORITY.md) - the authority spine and the ADR 0007 inventory exception
