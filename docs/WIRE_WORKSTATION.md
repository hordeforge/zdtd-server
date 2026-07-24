# Workstation TE wire (RE notes, V3.1.4 IL)

No `NetPackageRecipe*` exists in the 190-package list. Workstation craft state
rides `NetPackageTileEntity` with `TileEntityType.Workstation = 12` (classic TE,
not composite). Queue sync is server-authoritative TE re-send, same as storage.

## TileEntityType enum (client IL)

| Value | Type |
|---|---|
| 3 | Collector |
| 5 | Loot |
| 6 | Trader |
| 7 | VendingMachine |
| 8 | Forge |
| 9 | Campfire |
| 10 | SecureLoot |
| 12 | **Workstation** |
| 13 | Sign |
| 15 | Powered |
| 22 | SecureLootSigned |
| 25 | Composite |

## TileEntityWorkstation.read (StreamModeRead order)

After `TileEntity.read` base + `version:u8`:

Persist mode (0): `lastTickTime:u64 | fuel:ItemStack[] | input:ItemStack[] |
toolsNet:ItemStack[] | output:ItemStack[] | queue:RecipeQueueItem[ver] |
craftComplete[ver] | isBurning:bool | currentBurnTimeLeft:f32 |
meltCount:u8 + f32*n | isPlayerPlaced:bool | lastInput:ItemStack[]`

Network mode (2): same arrays, then `isBurning | burnTimeLeft |
meltCount+f32*n | isPlayerPlaced | lastTickTime as (GameTimer.ticks - u64)`.

`readItemStackArray`: u8 count + ItemStack.Read * n.

## RecipeQueueItem (Write, version const 2 as u16 first)

```
u16 version(=2) | i16 Multiplier | bool IsCrafting | f32 CraftingTimeLeft |
bool hasRepairItem { ItemValue RepairItem | u16 AmountToRepair } |
u8 Quality | i32 StartingEntityId | f32 OneItemCraftTime |
bool hasRecipe { Recipe.Write }
```

Recipe.Write adds output ItemClass into NameIdMapping (client side effect only).

## Recipe.Write / Read (IL)

```
u16 Version | i32 itemValueType (output) | i32 count | bool IsScrap |
f32 craftingTime | i32 craftExpGain | string craftingArea |
i32 ingredientCount + ItemStack.Write * n
```

Read pops Version unread; itemValueType is the absolute output ItemValue.type.

## Implemented (stock_te.zig)

- `buildWorkstationTeBody` / `parseWorkstationTeBody`: type-12 network body,
  version 50; fuel/input/tools/output arrays; queue parsed into `QueueItem`
  (multiplier, is_crafting, craft_time_left, output type/count, crafting_time).
- C2S handler in game.zig: reach check + rebroadcast near.

## Open

- Sim craft tick: burn fuel, advance CraftingTimeLeft, consume input, place
  output; then S2C TE re-send with updated arrays.

Dumps: scratch `dump_ws2.txt` (RecipeQueueItem), `dump_ws3.txt`
(TileEntityWorkstation.read + enum).
