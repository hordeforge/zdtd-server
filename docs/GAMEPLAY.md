# Gameplay behavior flows

The core gameplay behaviors as flows (what happens when a player crafts,
trades, rolls loot, survives or moves). Lifecycle state machines (join, quest,
weather, blood moon window, power, sleepers, trader hours, party, vending
rent, buffs, guard policy) live in [STATE_MACHINES.md](STATE_MACHINES.md); this
file covers the flow shapes that are not state lifecycles. The `src/` anchors
are the authority when a diagram and a comment disagree.

## 1. Craft (player inventory)

`NetPackageInventoryTransactionRequest` with `op = craft` (c2s/inv.zig:480)
calls `tryCraft` → `tryCraftRecipe`. Ingredients are aggregated by ECS item id
so duplicate or alias ingredient lines are not double-counted; the whole
transaction is atomic over a snapshot of the bag. On success the output goes
to the inventory, the ledger records a `.craft` cause, and quest craft
progress bumps.

```mermaid
flowchart TD
    A[InvTx op=craft, recipe_index, times] --> B{recipe_index < defs.len}
    B -- no --> X[reject, no change]
    B -- yes --> C[aggregate ingredients by ECS id, scale by times]
    C --> D{inventory holds the need? countItem >= need}
    D -- no --> X
    D -- yes --> E[snapshot inventory_before]
    E --> F[removeItem each ingredient]
    F --> G{depositItem output ok?}
    G -- no --> H[restore snapshot]
    H --> X
    G -- yes --> I[markDirty inv, ledger record .craft]
    I --> J[questOnCraft: bump craft phase or legacy craft quest]
    J --> K[InventoryTransactionResponse]
```

Anchors: `src/server/c2s/inv.zig:480` (craft op dispatch),
`src/server/game.zig:3779` (`tryCraft`), `:3784` (`tryCraftRecipe`),
`src/ecs/systems.zig:443` (`questOnCraft`). `times` is clamped to
`craft_max_times`; zero means one. Any missing ingredient name or an output
that fails to deposit restores the exact pre-craft bag.

## 2. Workstation queue craft

The client sends the workstation `TileEntity` (type 12) and the server applies
it to the workstation store, then the per-tick `handleRecipeQueue` advances
the queue. With stock recipes.xml loaded, queued outputs are validated: the
output type must resolve to a recipe and that recipe's `craft_area` must match
the station's `CraftingAreaRecipes`, so a modified client cannot queue a forge
output on a campfire.

```mermaid
flowchart TD
    A[NetPackageTileEntity workstation TE] --> B{within max_edit_range?}
    B -- no --> Z[reject, bounds evidence]
    B -- yes --> C[getOrCreate workstation store]
    C --> D[apply fuel / input / tools / output groups, last_input blob]
    D --> E{recipes.source == xml?}
    E -- yes --> F[validate each queue entry: output type resolves to a recipe and craft_area matches]
    E -- no --> G[copy queue verbatim]
    F --> H[copy validated queue, clear dropped slots]
    G --> I[melt, setCraftComplete ack, lengths, is_burning]
    H --> I
    I --> J[has_fuel_module from block, echo TE broadcastNear]
    J --> K[per tick: tickWorkstations -> handleRecipeQueue]
    K --> L{queue empty?}
    L -- yes --> M[idle]
    L -- no --> N{fuel station burning?}
    N -- no --> M
    N -- yes --> O[active = last queue entry, clamp non-finite craft_time_left]
    O --> P{craft_time_left < 0 and recipe in queue?}
    P -- no --> M
    P -- yes --> Q{multiplier > 0 and steps < max_crafts_per_tick?}
    Q -- no --> R[cycleRecipeQueue: shift next entry, carry time]
    R --> P
    Q -- yes --> S[completeOneCraft]
    S -- output full --> T[stall: return, queue holds]
    S -- ok --> U[multiplier -= 1, craft_time_left += one_item_craft_time, addCraftComplete]
    U --> Q
```

Anchors: `src/server/c2s/inv.zig:337` (workstation TE apply), `:350`
(`getOrCreate`), `src/world/workstations.zig:236` (`handleRecipeQueue`), `:274`
(`completeOneCraft`), `:285` (`addCraftComplete`), `:339`
(`cycleRecipeQueue`), `:361` (`addOutput`), `src/server/game.zig:3884`
(`tickWorkstations`, also feeds the heat map).

Notes: `max_crafts_per_tick = 64` bounds one tick; a non-finite or huge
client-written `CraftingTimeLeft` is clamped to `max_craft_backlog`.
`addCraftComplete` merges by crafted item and drops the oldest entry at cap;
`setCraftComplete` replaces the record list with what the client acknowledged.

## 3. Trade buy / sell

`handleTrade` parses `NetPackageTraderTrade` and delegates to
`systems.trade`. The server owns the prices (from `fillTraderFromXml`), the
coin wallet and the trader money pool; the client's post-trade `TraderData`
copy is mirrored back (`applyTraderDataCopyFrom`) and re-broadcast. A sell is
refused once the trader's money pool runs out; a buy demand spike sets the
entry markup to +100, a sell eases it by 4.

```mermaid
flowchart TD
    A[NetPackageTraderTrade side, item, qty] --> B{side == sell?}
    B -- no --> D[sysTrade side=0 buy]
    B -- yes --> C{trader allow_sell?}
    C -- no --> Z[reject]
    C -- yes --> D
    D --> E[resolve player slot, trader slot, coin item id]
    E --> F[sync wallet from inventory coins when inv has more]
    F --> G{stock entry found?}
    G -- no --> Z
    G -- yes --> H{buy or sell}
    H -- buy --> I{stock count >= qty and wallet >= price x qty}
    I -- no --> Z
    I -- yes --> J[spend coins from inv first, deposit item, stock -= qty, wallet -= cost, trader wallet += cost, markup = 100]
    H -- sell --> K{trader wallet >= gain and inv holds item?}
    K -- no --> Z
    K -- yes --> L[remove item, deposit coins, stock += qty, wallet += gain, trader wallet -= gain, markup -= 4]
    J --> M[TraderData snapshot to peer]
    L --> M
```

Anchors: `src/server/trade.zig:78` (`handleTrade`), `src/ecs/systems.zig:664`
(`trade`), `src/server/trade.zig:117` (`applyTraderDataCopyFrom`),
`src/server/game/trader.zig:167` (`fillTraderFromXml` prices),
`src/server/trade.zig:26` (`stockEntries`, markup on the wire).

## 4. Trader inventory roll

Stock `TraderInfo::Spawn` port. Restock is lazy: opening the trader window
(`LockRequest`) calls `maybeRestockTrader`, which rolls fresh stock only when
the `ResetInterval` has elapsed (never / daily / every N days). The roll is
deterministic: `XorShift32` seeded from world seed, trader id and day. Every
top-level ref always spawns; group refs expand with prob-weighted picks and
unique-only removal; each item rolls a count and (when the XML set one) a
uniform quality.

```mermaid
flowchart TD
    A[open: LockRequest -> maybeRestockTrader] --> B{reset_interval elapsed?}
    B -- no --> C[serve existing stock]
    B -- yes --> D[rollStockRefs: seeded rng world seed x trader id x day]
    D --> E[rollAllRefs over top-level refs]
    E --> F{ref is group?}
    F -- no --> G[count roll in min..max, quality roll uniform, emit one stack]
    F -- yes --> H[spawnItemsFromGroup]
    H --> I{group count_all?}
    I -- yes --> J[spawnAllRefs: every ref, count roll only]
    I -- no --> K[count roll for picks -> spawnLootItemsFromList]
    K --> L[prob-weighted: walk refs accumulating prob share, first past the roll spawns, unique removed from pool]
    J --> M[fillTraderFromXml: price = econ x buy_markup, sell = econ x sell_markdown]
    L --> M
    G --> M
    M --> N[wallet regrown to wallet_default, last_restock_day pinned]
```

Anchors: `src/assets/traders.zig:134` (`rollAllRefs`), `:176`
(`spawnLootItemsFromList`), `:205` (`spawnItemsFromGroup`), `:228`
(`spawnItem`), `:243` (`randomSpawnCount`), `src/server/game/trader.zig:141`
(`rollStockRefs`), `:167` (`fillTraderFromXml`), `:204`
(`maybeRestockTrader`), `src/ecs/systems.zig:751` (`traderRestock` daily
timer).

## 5. Loot roll pipeline

`rollContainer` fills a world container (or loot-bag table) from loot.xml.
The container's entries iterate in document order; the first entry always
rolls unless it carries a loot-stage template (a template's prob is the stage
gate itself). Group entries recurse into `rollGroup`: `pick_all` groups emit
every entry, others roll a pick count then pick entries prob-weighted. Every
picked entry still clears its loot-stage band. Quality comes from the
container's quality template: first band matching `loot_stage`, then
prob-weighted quality picks.

```mermaid
flowchart TD
    A[rollContainer name, loot_stage, seed] --> B{containerByName found?}
    B -- no --> C[try as group name, rollGroup]
    B -- yes --> D[per entry: hash seed advance]
    D --> E{force_prob?}
    E -- yes --> F[gate on own prob]
    E -- no --> G[first entry always unless prob_template; template gates on stage band]
    F --> H{prob gate passed?}
    G --> H
    H -- no --> I[skip entry]
    H -- yes --> J{is_group?}
    J -- yes --> K[rollGroup: pick_all or pick count, recurse depth <= 6]
    J -- no --> L[count roll in cmin..cmax, scaleCount by abundance, resolveQuality from template bands]
    K --> M[next entry]
    L --> M
    I --> M
    M --> N{all entries done}
    N -- no --> D
    N -- yes --> O{anything rolled?}
    O -- no --> P[fallback scrap: resourceScrapIron x 5]
    O -- yes --> Q[return stacks]
```

Anchors: `src/assets/loot.zig:196` (`rollContainer`), `:262` (`rollGroup`),
`:142` (`probGate`), `:123` (`resolveQuality`), `:154` (`scaleCount`),
`src/server/chunk_stream.zig:247` (`fillContainerFromLoot` feeds the stacks
into a container and stamps `touched_day`). The loot stage is the party loot
stage (`game.zig:4225`); the seed is deterministic per position and respawn
cycle (see [STATE_MACHINES.md#17-loot-respawn](STATE_MACHINES.md#17-loot-respawn)).

## 6. Survival and stamina

Per tick, per joined client. Food and water deplete by in-game hours; the
stage thresholds come from `buffs.xml` (`buffStatusCheck01` hungry/thirsty
fractions of max) when the table is loaded, else `Rules.progression`
absolutes. Starvation/dehydration drains HP, well-fed regens it. Stamina
drains only while `sprint_speed > 0` (set by `NetPackageEntitySpeeds`
movement state 3, lapsed by `sprint_stale_seconds`) and regens otherwise.
Changed stats sync at `survival_sync_seconds` cadence.

```mermaid
flowchart TD
    A[per tick: tickSurvival dt] --> B[food -= depletion_per_hour x game_hours, water -= depletion_per_hour x game_hours]
    B --> C{starving or dehydrated? frac thresholds or absolute}
    C -- yes --> D[hp -= starve or dehydrate per second]
    C -- no --> E{well-fed? food and water above threshold}
    E -- yes --> F[hp += well_fed_regen_per_hour x game_hours]
    E -- no --> G[no hp change]
    D --> H[hp clamped 0..max, markDirty hp]
    F --> H
    G --> H
    H --> I{sprint_speed > 0?}
    I -- yes --> J{starving and buffs.xml present?}
    J -- yes --> K[stamina -= starve_stamina_perc x max per second]
    J -- no --> L[stamina -= stamina_drain_per_second x dt]
    I -- no --> M[stamina += stamina_regen_per_second x dt, clamp max]
    K --> N{survival_sync_cd elapsed?}
    L --> N
    M --> N
    N -- yes --> O[send SurvivalStats / StaminaStats to peer]
    N -- no --> P[cd -= dt]
```

Anchors: `src/server/game/tick.zig:23` (`tickSurvival`), `src/assets/buffs.zig:396`
(`survival()` resolves thresholds and per-second HP loss), `src/ecs/rules.zig:169`
(`progression` defaults: depletion, starvation, well-fed, stamina drain/regen,
sync cadence), `src/server/c2s/move.zig:156` (sprint state from
`NetPackageEntitySpeeds`).

## 7. Blood moon schedule

The blood moon window (scheduled day, dusk start, party stage freeze, dawn
end) is a state lifecycle and is covered in STATE_MACHINES section 6 with the
`WorldClock` transitions. Gameplay-relevant notes that belong to flows:
`Director.bm_stage_frozen` latches the party gamestage at dusk and clears at
dawn (`src/ecs/aidirector.zig:333`); one horde wave spawns per party every 6 s
(`:344`); horde zombies teleport back to their party focus past 150 m. See
[STATE_MACHINES.md#6-blood-moon-window](STATE_MACHINES.md#6-blood-moon-window).

## 8. Movement authority

C2S movement (`PosAndRot`, `RelPosAndRot`, `Teleport`) goes through
`applyMovementEnvelope`. The envelope is a horizontal speed gate over the
server's dt: within budget the move is accepted and rebaselines the gate;
over budget it is rejected, counted as strong evidence, and in Correct mode
the client gets a soft snap back to the clamped position. A Y below -1.0
(void) is rescued to the DTM surface.

```mermaid
flowchart TD
    A[PosAndRot / RelPosAndRot / Teleport] --> B{entity_id == own?}
    B -- no --> Z[ownership reject]
    B -- yes --> C[compute candidate pos; RelPos adds delta to server pos]
    C --> D{finite?}
    D -- no --> Z2[decode reject]
    D -- yes --> E{move_valid baseline?}
    E -- no --> F[accept raw, noteAcceptedMove rebaselines]
    E -- yes --> G[clampHorizontal: distance <= max_horizontal_speed_mps x dt]
    G -- within --> F
    G -- clamped --> H[movement_rejects + strong evidence]
    H --> I{authorityCorrects?}
    I -- no --> F
    I -- yes --> J[apply clamped pos, soft snap S2C PosAndRot]
    J --> K[noteAcceptedMove]
    F --> L{feet y < -1.0?}
    L -- yes --> M[rescueDeepVoid: snap to surface + 0.9, teleport]
    L -- no --> N[sim.setPos]
    M --> N
    N --> O[questTickGoto + questTickStayWithin]
```

Anchors: `src/server/c2s/move.zig:20` (PosAndRot handler), `:107` (RelPos
handler), `:172` (Teleport handler), `src/server/game.zig:1536`
(`applyMovementEnvelope`), `src/server/movement.zig:39` (`clampHorizontal`),
`src/server/game.zig:1503` (`noteAcceptedMove`, rebaselines and fires
pressure plates), `:2956` (`rescueDeepVoid`), `src/server/c2s/move.zig:156`
(`NetPackageEntitySpeeds` sprint state).

Notes: the gate is `move_valid` false after spawn/teleport (`resetMoveEnvelopePeer`,
`game.zig:1524`), so the first move after a sanctioned teleport always
rebaselines; dt is floored at 1/40 s and capped at 1 s so a single packet
cannot jump the whole map. Observe mode counts the violation but still applies
the client position.
