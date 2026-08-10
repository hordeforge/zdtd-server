# Workstation TE wire (RE notes, V3.1.0 b14 IL)

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

## Network body (identical in both directions)

`TileEntityWorkstation::write` (asm.il ~1332990) writes the same bytes for
`StreamModeWrite.ToServer = 1` (IL_00cc) and `ToClient = 2` (IL_018d).
`TileEntityWorkstation::read` reads that layout for `StreamModeRead.FromServer = 1`
(IL_01c2) and `FromClient = 2` (IL_00f8); `NetPackageTileEntity::ProcessPackage`
picks the mode from `IsRemote` (asm.il ~842942), so the server always reads 2.

After `TileEntity.write` network mode (chunkPos Vector3i only, asm.il ~1312528)
and `version:u8` (50):

```
fuel      : u8 count + ItemStack.Write * count
input     : u8 count + ItemStack.Write * count
tools     : u8 count + ItemStack.Write * count
output    : u8 count + ItemStack.Write * count
queue     : u8 count + RecipeQueueItem.Write * count
craftDone : i16 count + CraftCompleteData.Write * count   (version > 45)
isBurning : bool
burnLeft  : f32
melt      : u8 count + f32 * count
placed    : bool  (isPlayerPlaced)
tickDelta : u64   (GameTimer.ticks - lastTickTime; reader subtracts it back)
lastInput : u8 count + ItemStack.Write * count
```

Persistency mode (0) is the same set with `lastTickTime:u64` written first and
no delta at the end.

## Counts are array lengths, never used prefixes

`writeItemStackArray` always emits `array.Length` (asm.il ~1333440) and
`writeRecipeStackArray` always emits `queue.Length` (asm.il ~1333708). Both
readers reallocate the target array to the received count **before** the discard
gate (`readItemStackArray` IL_0012 asm.il ~1333365, `readRecipeStackArray`
IL_0012 asm.il ~1333602), so a short count permanently shrinks the receiver's
grid. `currentMeltTimesLeft` is indexed at the received count with no bounds
check (`read` IL_016e asm.il ~1332790).

Stock ctor lengths (asm.il ~1330158): fuel 3, tools 3, output 6, input 3,
lastInput 3, queue 4, `currentMeltTimesLeft = input.Length` (3, never regrown).
`OnSetLocalChunkPosition` grows **input only**, to `3 + InputMaterials` for a
forge (asm.il ~1330219), and it runs again at the end of every `read`, so a
short input count self-heals while the other arrays do not.

zdtd therefore echoes the exact counts the client last sent and refuses to
broadcast a station whose geometry it has never been told (`geometry_known`).

## RecipeQueueItem (Write, version const 2 as u16 first)

```
u16 version(=2) | i16 Multiplier | bool IsCrafting | f32 CraftingTimeLeft |
bool hasRepairItem { ItemValue RepairItem | u16 AmountToRepair } |
u8 Quality | i32 StartingEntityId | f32 OneItemCraftTime |
bool hasRecipe { Recipe.Write }
```

At version 2, `Read` leaves `Recipe` untouched when `hasRecipe` is false
(asm.il ~272880 IL_0084). That is lossless only for a peer that already had the
object, and only while the array was not reallocated. A peer that never queued
the recipe would end up with `Multiplier > 0` and `Recipe == null`, which
`HandleRecipeQueue` dereferences (asm.il ~1331756 IL_006c). zdtd captures the
`Recipe.Write` bytes verbatim per queue slot and re-emits them with
`hasRecipe = true`.

## Recipe.Write / Read (asm.il ~274817 / ~274879)

```
u16 Version | i32 itemValueType (output) | i32 count | bool IsScrap |
f32 craftingTime | i32 craftExpGain | string craftingArea |
i32 ingredientCount + ItemStack.Write * n
```

Read pops Version unread; itemValueType is the absolute output ItemValue.type.
`Recipe::GetName()` is `ItemClass.GetForId(itemValueType).GetItemName()`
(asm.il ~274245), i.e. the recipe name is derivable from the output type; it is
not on the wire.

## CraftCompleteData (asm.il ~272530 Write / ~272566 Read)

```
u16 Version(=1) | i32 CrafterEntityID | ItemStack CraftedItemStack |
string RecipeName | i32 CraftExpGain | u16 RecipeUsedCount | string ItemScrapped
```

The list rides as `i16 count` + entries and is only present when version > 45
(`readCraftCompleteData` asm.il ~1333490); at version 50 entries use `Read`, not
`ReadLegacy`. The receiving client's `CheckForCraftComplete` (asm.il ~1333883)
matches `CrafterEntityID` against the local player, unlocks `ItemScrapped` as a
cosmetic, calls `GiveExp`, removes the entry and calls `setModified()`. The
trimmed list therefore comes back on the next client write: that is the
acknowledgement, and zdtd replaces its stored list with whatever arrives.

`GiveExp` divides `CraftExpGain` by `(craftCount + RecipeUsedCount)`
(asm.il ~528534), so `RecipeUsedCount` must never be written as 0. Stock always
passes 1 and merges repeats by growing `CraftedItemStack.count`
(`AddCraftComplete` asm.il ~1333793); zdtd mirrors both.

## Queue orientation and craft semantics

`HandleRecipeQueue` (asm.il ~1331686):

- returns immediately when `bUserAccessing` is set (client-local only; never on
  the wire, so a dedicated server always simulates),
- returns when `isModuleUsed[3] && !isBurning`,
- the **active entry is `queue[queue.Length - 1]`**,
- decrements `CraftingTimeLeft` only when it is not already negative,
- while it is negative and `hasRecipeInQueue()`: add the output first and
  **return without crafting** when `ItemStack::AddToItemStackArray` returns -1
  (output full, IL_00e3), then `AddCraftComplete`, then `Multiplier -= 1` and
  `CraftingTimeLeft += OneItemCraftTime`,
- when `Multiplier <= 0`: remember the leftover, `cycleRecipeQueue()`, re-read
  the active entry and add `min(leftover, 0)` to its `CraftingTimeLeft`.

`cycleRecipeQueue` (asm.il ~1331491) shifts each entry from `j-1` into `j`
walking down from the end and clears the vacated slot, so **index 0 is the
newest** and the last index is the one being crafted. It then sets
`IsCrafting = true` on the new active entry when it has a recipe and a non-zero
multiplier (IL_0182).

## Package framing

`NetPackageTileEntity::ProcessPackage` (asm.il ~842861) drops the whole package
when `GetBlock(teWorldPos).type != teBlockId`, so the echo reuses the block id
the client sent rather than re-reading the world. `TileEntity::setModified`
(asm.il ~1312790) uses handle 255 on the server path and an incrementing handle
on the client path; zdtd keeps 255 on every broadcast.

## Implemented (zdtd)

- `wire/stock_te.zig`: full body build/parse at version 50 including the
  trailing `isPlayerPlaced`, tick delta and `lastInput`; per-slot `Recipe`
  blobs; `CraftCompleteData` list; melt values. The parser rejects a payload it
  cannot drain exactly and any array count wider than the store.
- `world/workstations.zig`: stock queue orientation, output-full stall,
  `cycleRecipeQueue` shape with leftover carry and `IsCrafting`, and a bounded
  craft-complete record list with an acknowledge-by-replace drain.
- `server/c2s/inv.zig`: C2S apply stores geometry, blobs, melt, `lastInput`,
  `block_id` and the acknowledged record list; the 2 Hz dirty broadcast and the
  lock-grant push both re-emit at the stored lengths.

## Open

- The server trusts the client's `Recipe` blob for output type/count/time. It is
  not validated against `recipes.xml`, so a modified client can queue a recipe
  the game does not define.
- `isModuleUsed` is not on the wire, so zdtd uses `isBurning` as the gate for
  every station: a workbench (no fuel module) does not advance server-side.
- `lastInput` and the melt timers pass through untouched; the server never
  drives the forge melt simulation itself.
- No live-client playtest yet. zdtd's encode/decode tests agree with each other
  by construction; only a real client proves the layout.

Dumps: scratch `dump_ws2.txt` (RecipeQueueItem), `dump_ws3.txt`
(TileEntityWorkstation.read + enum).
