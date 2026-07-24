# Inventory system (ECS)

zdtd inventory is **SoA component data** on player (and loot bag) entities, driven by
`src/ecs/inventory.zig` systems. **S→C player inventory** uses stock V3.0.1 wire
(`src/wire/stock_inv.zig`) so a vanilla client can parse toolbelt/bag/equipment for UI.

## Slot layout

| Range | Role |
|---|---|
| 0–9 | Toolbelt (holding index must be here) |
| 10–41 | Bag |
| 42–46 | Equipment (armor / accessories; reserved) |

`holding = 0xFFFF` means empty hands.

## Component

```text
Inventory {
  slots[47] { item_id, count, quality, meta }
  holding: u16
  open_container: i32   // net id of open loot bag / TE, or -1
}
```

Stack limits: tools/weapons 1, ammo 150, food/med 50, default 60000.

## Ops (`inventory.Op`)

| Op | a | b | qty | entity_id |
|---|---|---|---|---|
| list |: |: |: |: |
| move | from | to | qty (0=all) |: |
| drop | slot |: | qty |: |
| set_hold | toolbelt slot |: |: |: |
| use | slot |: |: |: |
| open |: |: |: | container net id |
| close |: |: |: |: |
| take | container slot |: | qty |: |
| put | player slot |: | qty |: |
| place | slot | y (i16 bits) | z (i16 bits) | x (i32) |
| equip | from slot | equip index 0–4 |: |: |

`use` on food (2) / medicine (4) removes 1 and heals.  
`place` maps wood(7)→block 4, cobblePlaceable(10)→block 5.  
`equip` moves armor(11) into equipment slots; each piece grants 10% damage mitigation (cap 50%).

## Wire packages

| Package | Direction | Body |
|---|---|---|
| `NetPackagePlayerInventory` | **both** | **stock**: bool toolbelt + `WriteItemStack`; bool bag + `Bag.Write`; bool equip + `WriteItemValueArray` + cosmetics; bool drag. Client→server applies sections into ECS and echoes snap. |
| `NetPackageHoldingItem` | **both** | **stock**: entity_id i32, `ItemStack.Write`, holding index u8. C→S updates hold; rebroadcast except sender. |
| `NetPackageItemDrop` | C→S | **stock**: ItemStack + drop/motion vectors + lifetime + entityId + clientInstanceId + relative bool → loot bag |
| `NetPackageBag` | **both** | entityId i32, u16 blob_len, `Bag.Write`. C→S applies bag; S→C on inv sync and loot spawn. |
| `NetPackageDropItemsContainer` | C→S | droppedBy i32, entity class string, Vector3, item stacks → multi-item loot bag |
| `NetPackageTileEntity` | **both** | Stock **composite + TEFeatureStorage** payload (network mode) for world chests; ZTE1 still accepted as bridge. |

| `NetPackageInventoryTransactionRequest` | C→S | zdtd: op u8, a u16, b u16, qty u16, entity_id i32 |
| `NetPackageInventoryTransactionResponse` | S→C | zdtd head: ok u8, dropped_entity i32 + stock inventory body |
| `NetPackageInventoryDataRequest` | C→S | entity_id i32 (open container) |
| `NetPackageInventoryDataResponse` | S→C | stock inventory body for container entity |
| `NetPackageEntityCollect` | C→S | bag entity_id i32 (open+take+vacuum) |

### Stock ItemValue (v9, minimal)

Empty → `0`. Else: version `9`, flags (bit0 = type ≥ `ItemsStartHere` 65536), type u16,
UseTimes f32, Quality u16, Meta u16, metadata count 0, mods count 0, cosmetics 0,
Activated, SelectedAmmo, Seed u16, texture bool false.

Builtin ECS `item_id` is mapped to stock names (e.g. `8` → `meleeToolRepairT0StoneAxe`),
then to absolute type via `items.xml` order (`ItemsStartHere+1` … sequential). Without
XML, fallback is `65536 + item_id` (structure still parseable).

On join, when XML is loaded, `NetPackageIdMapping` (`name="items"`) carries the
NameIdMapping blob (version 1 + id/name pairs) for client remapping.

### Bag.Write

version 1, slot count u16 (99 padded), stacks, locked=false, touched=true, prefs=false.

### Equipment

12 slots via `WriteItemValueArray`, 12 cosmetic i32 zeros, unlocked count 0.

## Join

Starter kit: stone axe (8), food×5 (2), wood×20 (7). Full inventory + holding sent in join bundle.
`players.zsv` restores inventory by player name.

## Admin

```text
give <peer_slot> <item_id> <count>
```

## Items (builtin)

| id | name | notes |
|---:|---|---|
| 1 | scrap | loot |
| 2 | food | use → heal 10 |
| 3 | ammo | |
| 4 | medicine | use → heal 25 |
| 7 | wood | place → wood block |
| 8 | stoneAxe | starter |
| 10 | cobblePlaceable | place → cobble |
| 11 | armorScrap | equip mitigation |
| 12 | questToken | fetch quests |

## World containers

`src/world/containers.zig` stores chests by world `(x,y,z)`. `src/wire/stock_te.zig` encodes
`NetPackageTileEntity` as composite + single `TEFeatureStorage` module (stable hash
`TEFeatureStorage`). Placing block id ≥ 20 creates an empty 8-slot container.

## Remaining gaps

- Multi-feature composite TEs (lockable, sign) and persistency stream mode.
- Matching stock **block ids** so the client already has a composite TE at that cell (needs stock chunks + blocks.xml).
- Full ItemValue mods/stats on write; full items.xml IdMapping blob.
- Our `Op` txs remain for bots; vanilla UI uses PlayerInventory / Bag / ItemDrop / HoldingItem / TE.

## Code

```text
src/ecs/components.zig   Inventory / InvSlot layout
src/ecs/inventory.zig    systems + unit tests
src/wire/stock_inv.zig   stock ItemValue/ItemStack/Bag/equip encode
src/assets/items.zig     items.xml + stock type ids + builtin aliases
src/wire/packages.zig    builders/parsers (+ native helpers)
src/server/game.zig      package handlers + IdMapping join
```

