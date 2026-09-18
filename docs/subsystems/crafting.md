# Crafting, scrapping and loot

This subsystem owns the item-production paths: a player craft, a scrap into forge material, a loot
table rolled into a bag or a world container, and the quality and durability stamped on whatever
comes out. `src/server/game/craft.zig` holds the craft and scrap execution plus the workstation
tick, `src/server/game/loot.zig` holds the loot-bag fill and the loot-spawn broadcasts, and the two
catalogs (`src/assets/recipes.zig`, `src/assets/loot.zig`) parse the stock XML into tables.
`src/wire/stock_inv.zig` carries the item and bag bodies that put a produced stack on the client
wire. Per [`src/assets/root.zig:1-6`](../../src/assets/root.zig) the assets package may import util
and pure ECS types only and must not import world, server or wire, so a catalog depends on nothing
above it; the server package composes the catalog with the sim. Inventory slot mechanics, the item
table and the container store belong to their own pages.

Sources: [`src/server/game/craft.zig`](../../src/server/game/craft.zig),
[`src/server/game/loot.zig`](../../src/server/game/loot.zig),
[`src/assets/recipes.zig`](../../src/assets/recipes.zig),
[`src/assets/loot.zig`](../../src/assets/loot.zig),
[`src/wire/stock_inv.zig`](../../src/wire/stock_inv.zig),
[`src/server/c2s/inv.zig`](../../src/server/c2s/inv.zig),
[`src/assets/progression.zig`](../../src/assets/progression.zig)

## Recipe catalog and unlock

The recipe catalog is a flat arena-backed array with a fixed ingredient budget of 8 and a zdtd cap
of 1024 recipes, both well above the stock file (`src/assets/recipes.zig:12-19`). One recipe is
(`src/assets/recipes.zig:26`):

```zig
pub const RecipeDef = struct {
    name: []const u8 = "",
    count: u16 = 1,
```

The name is the output item name, `count` is how many items one craft yields, and the row also
carries `craft_area`, `craft_tool`, `material_based`, `wildcard_forge_category`, `always_unlocked`,
`craft_time` and `craft_exp_gain` (`src/assets/recipes.zig:29-72`). A recipe left at `craft_time =
-1` has its time derived instead of guessed: the sum of its ingredients'
`CraftComponentTime * count`, resolved through the live item table so a modlet row changes the
result with no code change (`src/server/game/craft.zig:326-337`). `RecipeTable.byName` is a linear
scan over that array; there is no name index (`src/assets/recipes.zig:145-150`).

Unlock is a progression gate, not a recipe flag. `unlockRequirement` resolves an item name to
(crafting skill, level) from the `progression.xml` crafting-skill entries, or null when no magazine
entry gates it (`src/assets/progression.zig:872-887`). The join path sends the client the list it
already qualifies for: `always_unlocked` rows plus every recipe whose gate the player's skill level
already meets (`src/assets/recipes.zig:196-221`). The offline builtin catalog seeds two demo names
so a craft works without a progression table; with stock XML loaded those extra names are omitted
so the wire list matches the catalog (`src/assets/recipes.zig:161-188`).

## The inventory craft path

The C2S `InvTx` route dispatches op `craft` to `tryCraft` with the bag slot and count
(`src/server/c2s/inv.zig:886-887`, `src/server/game/craft.zig:381-384`). Only recipes with no
workstation, tool or material requirement are accepted on this path, because the stock inventory
never offers the others and accepting them would bypass the station gate or mint items from a
zero-ingredient scrap stub (`src/server/game/craft.zig:386-395`):

```zig
pub fn generalCraftAllowed(recipe: assets_recipes.RecipeDef) bool {
    return recipe.craft_area.len == 0 and recipe.craft_tool.len == 0 and !recipe.material_based and !recipe.wildcard_forge_category;
}
```

```zig
fn tryCraftRecipe(self: *Game, peer_slot: usize, recipe: assets_recipes.RecipeDef, times: u16) bool {
```

The execution order is: resolve the player slot and its inventory, reject a non-general recipe,
check the unlock gate, resolve the crafting tier, cap the batch at `craft_max_times`, then pass the
`on_craft_request` plugin verdict which can deny or lower the batch
(`src/server/game/craft.zig:397-417`). Ingredients are folded by ECS id first, so duplicate or alias
lines cannot double-count inventory room, and a modifier count of zero skips the ingredient entirely
(`src/server/game/craft.zig:419-450`, `src/assets/recipes.zig:74-94`). Every folded need is checked
against the bag before anything is removed (`src/server/game/craft.zig:451-455`).

Removal is transactional. The whole bag is snapshotted, each need is removed, and any failure or a
failed deposit restores that snapshot byte for byte (`src/server/game/craft.zig:461-477`). A
successful craft records the delta in the inventory ledger with cause `.craft`, advances quest craft
objectives by recipe name, and grants XP only when the recipe declares a positive
`craft_exp_gain` (`src/server/game/craft.zig:480-495`). The stock diminishing-return divisor has no
observable effect while every declared value is zero, and no code path derives it
(`src/server/game/craft.zig:483-491`).

## Scrapping

Scrap is one craft of a forge stub. `getScrapableRecipe` mirrors stock `GetScrapableRecipe`: the item
must not be `NoScrapping`, must carry a material with a forge category, and must have weight, after
which the first `wildcard_forge_category` recipe wins whose output material shares that category,
whose output item differs from the input, and whose output weight fits inside `item weight * count`
(`src/server/game/craft.zig:498-534`):

```zig
pub fn getScrapableRecipe(
    self: *Game,
    item_id: u16,
    count: u16,
) ?assets_recipes.RecipeDef {
```

`tryScrap` takes a bag slot and a quantity, clamps the quantity to the stack, resolves the recipe,
and then takes and deposits under the same snapshot-and-restore rule as a craft
(`src/server/game/craft.zig:541-569`):

```zig
pub fn tryScrap(self: *Game, peer_slot: usize, bag_slot: u16, qty: u16) bool {
```

The ledger cause reuses `.craft`, because there is no scrap-specific cause
(`src/server/game/craft.zig:566`). The C2S route reaches it through the same `InvTx` op table
(`src/server/c2s/inv.zig:888-889`).

## Loot rolls

`LootTable.rollContainer` is the deterministic roll: a loot list name, a loot stage, an explicit seed
and a fixed output buffer (`src/assets/loot.zig:685-691`). Nothing there allocates or reads a clock,
so the same seed and inputs produce the same stacks. Entry probability can be overridden by a
`loot_prob_template` band covering the loot stage, and quality resolves from a quality template by
the same stage window (`src/assets/loot.zig:466-478`, `src/assets/loot.zig:480-494`). Rolled stack
counts are scaled by the `LootAbundance` percentage (`src/assets/loot.zig:463-464`). One rolled
stack carries (`src/assets/loot.zig:366-381`):

```zig
pub const Stack = struct {
    item_name: []const u8 = "",
    count: u16 = 0,
```

`fillLootBagFromTable` clears the bag before rolling, so a denied or empty roll leaves an empty bag
rather than stale contents, then rolls into a fixed 8-stack buffer (`src/server/game/loot.zig:30-47`,
`src/assets/loot.zig:17`). A plugin `on_loot_roll` verdict can empty the result or scale the count,
and the count is re-capped to the buffer after scaling (`src/server/game/loot.zig:39-47`). Plain
stackables deposit normally; anything carrying quality or mods takes a free slot so the mods land on
that same slot (`src/server/game/loot.zig:50-89`).

World containers roll on open, not on chunk load: `ensureContainerLoot` fills an untouched container
from its stored loot list with the opener's loot stage and a seed derived from the block position,
and re-rolls only after `LootRespawnDays` have elapsed, with the cycle mixed into the seed
(`src/server/game/chunk_fill.zig:594-643`). A container with no resolvable loot list stays empty
rather than rolling a guessed table (`src/server/game/chunk_fill.zig:602`, `src/server/game/chunk_fill.zig:632-633`).
The loot XML loader drops `<conditional evaluator="client">` blocks so a dedicated server does not
place client-only holiday gear (`src/assets/loot.zig:405-419`).

## Quality, durability and mods

The crafting tier is the quality a crafted item receives. `craftingTierFor` returns the maximum
quality tier when crafting progression is off, and otherwise folds every `CraftingTier` passive on
the player's crafting skills and perks whose tags intersect the recipe tags, truncates the result,
and clamps it into `1..max_quality_tier` (`src/server/game/craft.zig:314-354`). `depositCrafted`
writes that tier on a quality item and refuses to merge it into a different tier, while a plain
stackable takes the normal merge path (`src/server/game/craft.zig:356-379`). The wire slot that
carries the result is (`src/wire/stock_inv.zig:45`):

```zig
pub const StockSlot = struct {
    /// Absolute ItemValue.type (block id < items_start_here, or items_start_here + item index).
    /// Prefer encodeItemType() helpers for item classes.
    type_id: i32 = 0,
    count: u16 = 0,
    quality: u16 = 0,
    meta: u16 = 0,
    use_times: f32 = 0,
```

A looted quality item keeps the rolled quality only when the item declares `HasQuality`; otherwise
it is quality 1 (`src/server/game/loot.zig:55-60`). Random durability follows the stock
`(int)(max_use * RandomRange(0.2, 0.8))` form, resolved per stack from the roll seed
(`src/assets/loot.zig:383-389`, `src/server/game/loot.zig:61-64`). Loot mods are installed with a
chance that halves after every successful install, capped by the item's mod slots for its quality
(`src/server/game/loot.zig:121-148`).

## Wire, containers and the workstation queue

A filled bag reaches clients through `broadcastLootSpawn`, which picks the stock entity class by bag
kind (`Backpack` for a death drop, `DroppedLootContainer` for a block spill) and sends the slots
inside `NetPackageEntitySpawn` (`src/server/game/loot.zig:151-181`). A container's contents leave
through `NetPackageInventoryDataResponse`, built after `ensureContainerLoot` has rolled the table
(`src/server/c2s/inv.zig:1001-1038`).

The workstation craft is a different trust boundary. The client queue blob is not trusted: when a
stock recipes.xml is loaded, each queued output type is resolved to a name, looked up in the recipe
table, checked against the station's `CraftingAreaRecipes`, rejected when material-based, checked
against the unlock gate, and finally rewritten with the recipe's own output count and craft time
(`src/server/c2s/inv.zig:608-672`). The workstation tick then burns fuel, melts forge input and
re-broadcasts only the stations it changed
(`src/server/game/craft.zig:596-636`). The item ids and stack rules for those bodies are owned by
the inventory and container pages; this page owns only what produced the stack. Container, bag and
vehicle basket persistence is owned by the persistence page.

## See also

- [`docs/subsystems/inventory.md`](inventory.md) - bag slots, the item table and the InvTx op table.
- [`docs/subsystems/world-store.md`](world-store.md) - chunk store, containers and the loot roll trigger.
- [`docs/subsystems/persistence.md`](persistence.md) - what item state survives restart.
- [`docs/subsystems/wire.md`](wire.md) - the ItemValue and bag body layouts.
- [`docs/subsystems/assets.md`](assets.md) - the XML catalog loaders and fail-closed rules.
