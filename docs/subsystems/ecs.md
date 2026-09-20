# ECS simulation: SoA world, components, systems

The `src/ecs` package owns the game simulation plane: the structure-of-arrays entity store (`World`), entity identity (a dense slot plus a monotonic network id and a per-slot generation), the component types and their presence mask, the cached per-kind entity groups, the ordered tick systems, and the `Rules` parameter surface those systems read. It also owns the game state that lives on an entity rather than in a session: inventory, quest journal and wallet, buffs, trader stock, sleepers, vehicles, turrets, power, and the AI director. It does not own the wire (no package layout, no framing), the block and chunk store, or the network peer table; it reaches those only through optional function-pointer hooks that `Game` installs. Boundary: the package comment at `src/ecs/root.zig:1` permits an import of `util` only, forbids `wire`, `server`, `world`, `assets`, `litenet` and `apm`, and records one documented comptime-only exception - `rules.zig` reads `assets/sandbox_presets.zig` for default values (`src/ecs/root.zig:10`). The reverse edge is one-way and allowed for pure shapes: `wire`, `world` and `assets` may import component types from here. The production consumer is `server`, which holds the single sim store as `Game.sim` (`src/server/game.zig:955`).

Sources: [`src/ecs/root.zig`](../../src/ecs/root.zig), [`src/ecs/world.zig`](../../src/ecs/world.zig), [`src/ecs/components.zig`](../../src/ecs/components.zig), [`src/ecs/entity.zig`](../../src/ecs/entity.zig), [`src/ecs/systems.zig`](../../src/ecs/systems.zig), [`src/ecs/schedule.zig`](../../src/ecs/schedule.zig), [`src/ecs/query.zig`](../../src/ecs/query.zig), [`src/ecs/group.zig`](../../src/ecs/group.zig), [`src/ecs/rules.zig`](../../src/ecs/rules.zig), [`src/ecs/command.zig`](../../src/ecs/command.zig), [`src/ecs/locals.zig`](../../src/ecs/locals.zig)

## Entity identity and the world record

Capacity is fixed at comptime. `max_entities` is 512 and every column on `World` is a `[max_entities]T` array, so the store never allocates per entity and never grows (`src/ecs/entity.zig:3`, `src/ecs/world.zig:265`). A slot is a `u16` dense index; `invalid_slot` is the all-ones sentinel. The network id is a separate `i32` handed out monotonically from `next_net_id`, which starts at 100 (`src/ecs/world.zig:364`); `allocNetId` fails closed at `maxInt(i32)` rather than wrapping into a collision (`src/ecs/world.zig:1110`). Slots are recycled, network ids are not.

The handle types (src/ecs/entity.zig:3):

```zig
pub const max_entities: usize = 512;

/// Dense slot index 0..max_entities-1 when alive; never 0 as a live id (ids start at 100 historically).
/// We keep public network entity ids as i32 (spawned monotically) separate from ECS slots.
pub const Slot = u16;

pub const invalid_slot: Slot = std.math.maxInt(Slot);

/// Network-facing entity id (stable for wire packages).
pub const NetId = i32;

/// Slot + generation for internal handles that must not alias after recycle.
pub const EntityHandle = struct {
    slot: Slot = invalid_slot,
    gen: u32 = 0,

    pub fn invalid() EntityHandle {
        return .{};
    }
};
```

The generation is not a separate counter: `spawnBase` bumps `slot_gen[s]` and copies it into `network_id[s].gen` (`src/ecs/world.zig:1147`), and `handleAlive` compares that field against the handle's `gen` (`src/ecs/world.zig:1062`). As of this reading `EntityHandle` has no production caller; `handleOfSlot` and `handleAlive` appear only in a test (`src/ecs/world.zig:1068`, `src/ecs/world.zig:2438`). Production lookups use `net_to_slot`, an `AutoHashMapUnmanaged(i32, Slot)` pre-sized at init (`src/ecs/world.zig:393`, `src/ecs/world.zig:734`). `slotOfNetId` treats a healthy map as authoritative on miss and only falls back to the `0..max_entities` scan when an insert failed and set `net_map_degraded` (`src/ecs/world.zig:1074`).

`World` also carries the resources that are not entities: `catalog` (quest definitions), `power` (`electric.PowerGrid`), `director` (`aidirector.Director`), the deferred `commands` buffer, the `locals` tick scratch, and `rules` (`src/ecs/world.zig:326`, `src/ecs/world.zig:400`). `peer_to_player` is a reverse index from client peer slot to player entity slot, so the per-packet inventory, quest and movement paths do not rescan the table (`src/ecs/world.zig:362`).

## Component columns and the mask

Components are plain data with no behaviour (`src/ecs/components.zig:1`). Presence is a packed 32-bit word, `Mask`, one bool per column (`src/ecs/components.zig:1341`):

```zig
pub const Mask = packed struct(u32) {
    transform: bool = false,
    health: bool = false,
    network_id: bool = false,
    kind: bool = false,
    player: bool = false,
    zombie_ai: bool = false,
    vehicle: bool = false,
    turret: bool = false,
    trader: bool = false,
    flags: bool = false,
    journal: bool = false,
    wallet: bool = false,
    trader_stock: bool = false,
    inventory: bool = false,
    class_id: bool = false,
    loot_bag: bool = false,
    sleeper: bool = false,
    bot: bool = false,
    dirty: bool = false,
    buffs: bool = false,
    cvars: bool = false,
    falling: bool = false,
    _pad: u10 = 0,
};
```

`Kind` is the entity archetype and is immutable for a lifetime; it is the key of the group caches below (`src/ecs/components.zig:5`):

```zig
pub const Kind = enum(u8) {
    player,
    zombie,
    trader,
    vehicle,
    turret,
    loot_bag,
    animal,
    /// Stability-collapse group entity (RE entity-ai.md LetBlocksFall):
    /// carries the fallen cells as one EntityFallingBlock, falls under
    /// gravity, dies on landing (no re-placement).
    falling_block,
};
```

The core positional and vitals columns (src/ecs/components.zig:19):

```zig
pub const Transform = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    yaw: f32 = 0,
};

/// Stock item quality tiers: 1..6 (ItemValue.Quality; items.md). Armor
/// resist curves scale their first/last value to Q1/Q6.
pub const max_quality_tiers: u8 = 6;

pub const Health = struct {
    hp: f32 = 0,
    max_hp: f32 = 0,
    /// The spawn max (players 100, class-resolved otherwise): the passive-
    /// effects VM recomputes `max_hp = base_max_hp + deltas` revertibly
    /// every survival tick, so removing a perk/buff restores the base.
    base_max_hp: f32 = 0,
    /// PlayerEntityStats Food/Water (0..max). Zombies leave at 0.
    food: f32 = 0,
    food_max: f32 = 100,
    water: f32 = 0,
    water_max: f32 = 100,
    /// PlayerEntityStats Stamina (0..max); drained by sprinting, regens idle.
    stamina: f32 = 100,
    stamina_max: f32 = 100,
    /// Corpse dwell seconds left (TimeStayAfterDeath: 30 zombies, 300 animals).
    /// > 0 means dead-but-in-world: the corpse stays replicated until the sweep
    /// destroys it, so the client's ragdoll is not yanked mid-animation.
    corpse_seconds: f32 = 0,
};
```

The columns `World` declares, with the component that holds their state:

| Column (`World.<name>`) | Component | Declared at |
|---|---|---|
| `transform` | `Transform` | `src/ecs/components.zig:19` |
| `health` | `Health` | `src/ecs/components.zig:30` |
| `network_id` | `NetworkId` | `src/ecs/components.zig:51` |
| `kind` | `Kind` | `src/ecs/components.zig:5` |
| `player` | `Player` | `src/ecs/components.zig:57` |
| `class_id` | `ClassId` | `src/ecs/components.zig:76` |
| `zombie_ai` | `ZombieAi` | `src/ecs/components.zig:261` |
| `vehicle` | `Vehicle` | `src/ecs/components.zig:495` |
| `turret` | `Turret` | `src/ecs/components.zig:551` |
| `journal` | `Journal` | `src/ecs/components.zig:667` |
| `wallet` | `Wallet` | `src/ecs/components.zig:712` |
| `inventory` | `Inventory` | `src/ecs/components.zig:784` |
| `trader_stock` | `TraderStock` | `src/ecs/components.zig:978` |
| `loot_bag` | `LootBag` | `src/ecs/components.zig:1004` |
| `sleeper` | `Sleeper` | `src/ecs/components.zig:1037` |
| `falling` | `FallingBlocks` | `src/ecs/components.zig:1185` |
| `flags` | `Flags` | `src/ecs/components.zig:1230` |
| `dirty` | `Dirty` | `src/ecs/components.zig:1235` |
| `buffs` | `BuffSet` | `src/ecs/components.zig:1315` |

`Dirty` is the replication request set, and only four bits are read by the net pass: `pos`, `rot`, `flags`, `hp` (`src/ecs/components.zig:1235`). `spawnBase` sets a minimal mask for every entity (`transform`, `health`, `network_id`, `kind`, `flags`, `dirty`, `class_id`) and each spawn helper adds its own bits: `spawnPlayer` sets `player`, `journal`, `wallet`, `inventory` (`src/ecs/world.zig:1389`), `spawnZombie` and `spawnAnimalDef` set `zombie_ai` (`src/ecs/world.zig:1440`, `src/ecs/world.zig:1292`), loot bags set `loot_bag` plus `inventory` (`src/ecs/world.zig:1591`), and traders, vehicles and turrets set `trader_stock`, `vehicle` and `turret` respectively (`src/ecs/world.zig:1687`, `src/ecs/world.zig:1703`, `src/ecs/world.zig:1739`). `buffs` is the exception: it is attached lazily by `buffsMut`, which zeroes the column on first use so a recycled slot cannot inherit the previous entity's buffs (`src/ecs/world.zig:758`). The `stealth` and the various request-ring columns (noise, stealth noise, sleeper volume noise, explode, dig, sleeper wake) are `World`-level fixed rings rather than components, and parallel AI workers push into them atomically (`src/ecs/world.zig:276`, `src/ecs/world.zig:933`).

Per-domain state that lives in these columns has its own page or doc section: inventory and equipment (`Inventory`/`InvSlot`), quests (`Journal`/`Wallet` plus the quest catalog), buffs (`BuffSet` plus `ecs/buff.zig`), and power (`electric.zig` `PowerGrid`).

## Spawn, despawn, and slot reuse

There is no free list. `allocSlot` linearly scans for the lowest slot that is neither alive nor freed this tick, and only falls back to a just-freed slot when the table is full (`src/ecs/world.zig:792`):

```zig
    fn allocSlot(self: *World) ?Slot {
        var i: Slot = 0;
        while (i < max_entities) : (i += 1) {
            if (!self.alive[i] and !self.freed_this_tick[i]) return i;
        }
        // At capacity: fall back to just-freed slots rather than failing the spawn.
        i = 0;
        while (i < max_entities) : (i += 1) {
            if (!self.alive[i]) return i;
        }
        return null;
    }
```

`freed_this_tick` is the reason a slot is never recycled within one tick (`src/ecs/world.zig:379`). Per-client `known_entities` is keyed by slot and reconciled against `alive[]` once per tick, so a destroy-then-spawn in the same tick would suppress an `EntitySpawn` the client still needs. `beginTick` clears the flag array (`src/ecs/world.zig:914`), and `destroy` sets `any_freed_this_tick` so replicate knows whether it must reconcile at all (`src/ecs/world.zig:382`). A soft warning fires once when `entity_count` crosses 80 percent of capacity (`src/ecs/entity.zig:3`, `src/ecs/world.zig:1129`).

`spawnBase` is the single insertion point (`src/ecs/world.zig:1122`). It allocates a network id and then a slot, marks the entity alive in both `alive[]` and `alive_bits`, increments `entity_count`, inserts into the kind group, sets the base mask, writes transform, health, generation and `Flags` with `flag_spawned`, seeds `class_id` from the fixed `class_table` index that its `Kind` selects, and registers the id in `net_to_slot`. Specialised helpers (`spawnPlayer`, `spawnZombieDef`, `spawnAnimalDef`, `spawnSleeperDef`, `spawnLootBag`, `spawnFallingBlocks`, `spawnTrader`, `spawnVehicleEx`, `spawnTurret`) call it and then set their component's fields; `spawnZombieDef` exists so a class resolved from XML carries its stats on the entity even when its index was never preloaded into the fixed class table (`src/ecs/components.zig:99`, `src/ecs/world.zig:1206`).

`destroy` is idempotent and is the only removal path (`src/ecs/world.zig:805`). It marks the slot dead before touching the group so a concurrent kind-group walk sees the same truth as `alive[]`, releases an ambient director spawn-rule budget held by a zombie, removes the slot from the kind group and from `peer_to_player`, removes the network id from the map, drops an owned turret power node by id, then clears the mask, the dirty bits, and `dirty_bits`. It does not clear the component columns themselves; the mask is what makes a stale value unreadable. `reviveSlot` is the single sanctioned way to set `alive[]` back to true for a slot that was never destroyed, and it is idempotent, because a raw write would let the kind group drift (`src/ecs/world.zig:845`). `respawnPlayer` is the sanctioned respawn funnel on top of it: it heals to the slot's own maxima, runs buff death removal, clears `is_blood_moon_dead`, repositions, and marks `pos` and `hp` dirty so observers get the state (`src/ecs/world.zig:872`).

## Queries and kind groups

The public query surface is three functions taking `*World`: `groupSlice` for a borrowed ascending slot slice, `copyKindInto` for a snapshot of one kind, and `copyKindsInto` for a slot-ascending merge of several kinds (`src/ecs/query.zig:118`, `src/ecs/query.zig:141`, `src/ecs/query.zig:152`). The open `0..max_entities` mask scans still exist in the file, but they are file-private and serve only as the oracle the group cache is tested against (`src/ecs/query.zig:20`, `src/ecs/query.zig:182`). `ECS_SYSTEMS.md` shows an `ecs.forEachKindGroup` call; that function is file-private at `src/ecs/query.zig:125` and has no caller outside its own test, so the example as written does not compile against the package root.

The cache is `World.kind_groups`, one dense ascending slot list per `Kind` (`src/ecs/group.zig:36`):

```zig
pub const Groups = struct {
    dense: [n_kinds][max_entities]Slot = .{.{0} ** max_entities} ** n_kinds,
    len: [n_kinds]u16 = .{0} ** n_kinds,
```

8 kinds x 512 slots x u16 is 8 KB on the `World` struct with no heap and no `World` import, which is what keeps `group.zig` below `world.zig` in the dependency graph (`src/ecs/group.zig:21`). Order is a contract, not an optimisation detail: because `dense[0..len]` is strictly ascending, iterating a group visits the same slots in the same order as the open view scan, and the comments name the behaviours that would change otherwise - nearest-player tie-breaks, capped despawn id lists, turret target selection (`src/ecs/group.zig:9`). `insert` and `remove` are both sorted and both no-ops on a duplicate or absent slot (`src/ecs/group.zig:43`, `src/ecs/group.zig:56`). Because `kind[s]` is written only by `spawnBase`, a slot belongs to exactly one group for its lifetime and never migrates (`src/ecs/group.zig:15`). A slice is invalidated by the next spawn or destroy, so a loop body that mutates uses `copyKindInto` (`src/ecs/query.zig:117`).

## Systems and the tick

A system is a `pub fn(*World, ...)` in `systems.zig` with no state of its own; `tickAll` is a one-line delegation to `schedule.run` (`src/ecs/systems.zig:3685`). The schedule is the registry: an ordered list of names, and a `Phase` enum whose document order is the run order (`src/ecs/schedule.zig:10`, `src/ecs/schedule.zig:76`):

```zig
pub const order = [_][]const u8{
    "buffs", "director", "animals", "stealth", "ai", "vehicles", "falling", "turrets", "despawn", "commands",
};
```

`run` gates each phase on `w.rules.systems`, so the default table is the stock pipeline and a mode pack can switch a system off but never reorder one (`src/ecs/schedule.zig:87`). A disabled system is skipped rather than stubbed, and its slice of `TickResult` stays zero. The order encodes real dependencies: buffs run before the AI so movement and damage read this tick's buff state, and the stealth phase consumes the movement-noise ring before AI hears it (`src/ecs/schedule.zig:14`, `src/ecs/schedule.zig:19`). `director` is documented as always running, with the toggle applied to spawning inside it, because it owns the world clock and the trader restock (`src/ecs/schedule.zig:94`).

`TickResult` is the sim's outbound fact list (`src/ecs/schedule.zig:30`): AI hit count, director spawn count, world time, turret kills with owner slots, loot bag ids, despawned ids with their pre-destroy slots, buff expiries, applied command count, and the path replan counters. It carries no wire types. `Game.step` calls `systems.tickAll(&self.sim, dt)` once per tick after computing ambient light and before the net-facing passes that turn the result into packages (`src/server/game/step.zig:141`, `src/server/game/step.zig:146`). The reported despawned slots exist precisely because the slot no longer resolves once the sweep has destroyed the entity (`src/ecs/schedule.zig:42`).

Two phases parallelise through `util/parallel`: the AI pass runs over a `copyKindsInto` snapshot of zombie and animal slots, and the turret pass dispatches its workers over a filtered `groupSlice(w, .zombie)` copy after resolving the powered node set once per tick (`src/ecs/systems.zig:2992`, `src/ecs/systems.zig:3018`, `src/ecs/systems.zig:3516`). Workers write only their own slots, cross-slot reads come from a position snapshot taken at phase start, and shared HP writes go through fixed-point accumulators that a serial pass applies after the join (`src/ecs/systems.zig:3004`, `src/ecs/systems.zig:3020`). Because the AI phase is range-split, path admission cannot be a shared atomic budget: `beginTick` derives a stride and phase from last tick's demand so a zombie's replan schedule does not depend on which worker reached it first (`src/ecs/world.zig:917`, `src/ecs/world.zig:1056`).

Systems and plugins do not mutate the world out of phase. They enqueue into the fixed 64-entry command buffer, which the last phase drains serially (`src/ecs/command.zig:8`, `src/ecs/schedule.zig:119`). The op set is `spawn_zombie { x, y, z, hp }`, `despawn { net_id }`, `damage { net_id, amount }`, `say { text: [64]u8, len: u8 }` and `glide { net_id, on }` (`src/ecs/command.zig:17`); every op is classified at compile time as revertible or irrevocable so a plugin withdrawal has a defined story (`src/ecs/command.zig:38`).

A full buffer drops new ops and counts the drop rather than growing (`src/ecs/command.zig:111`). Every op carries a source field, and the drain runs a pre-drain hook so a disabled plugin's pending effects are withdrawn before any of them execute (`src/ecs/command.zig:83`, `src/ecs/world.zig:2007`). `TickLocals` in `locals.zig` is the other piece of tick scratch: five `u8` counters cleared by `beginTick`, with the id lists moved out into `TickResult` (`src/ecs/locals.zig:8`, `src/ecs/locals.zig:15`).

## Rules: the sim parameter surface

`Rules` is the whole tunable surface of the sim, carried on `World.rules` and read as `w.rules.<group>.<field>` (`src/ecs/rules.zig:796`):

```zig
pub const Rules = struct {
    systems: Systems = .{},
    combat: Combat = .{},
    c2s: C2s = .{},
    glide: Glide = .{},
    ai: Ai = .{},
    bloodmoon: Bloodmoon = .{},
    progression: Progression = .{},
    world: WorldGroup = .{},
    geometry: Geometry = .{},
    worldgen: WorldgenGroup = .{},
    vehicle: Vehicle = .{},
    director: Director = .{},
    difficulty: Difficulty = .{},
    water: Water = .{},
    power: Power = .{},
    trader: Trader = .{},
};
```

The systems toggles are the same struct the schedule gates on, and every entry defaults on (`src/ecs/rules.zig:24`, `src/ecs/schedule.zig:195`). Overlay is field-for-field mirrored by `RulesOverlay`, whose fields are nullable, and `mergeOverlay` copies only the non-null subset (`src/ecs/rules.zig:1084`, `src/ecs/rules.zig:1105`). A comptime parity test fails if the two structs ever drift (`src/ecs/rules.zig:1127`), and a test asserts every leaf name appears in `GAME_OPTIONS.md` so the preset reference cannot silently rot (`src/server/preset.zig:437`). Precedence is defaults, then mode pack, then operator `zdtd.toml`, applied in that order in `main.zig` (`src/main.zig:934`), and `Game` installs the result once at construction as the single install point (`src/server/game.zig:955`). `[rules.worldgen]` and `[rules.geometry]` are validated fail-closed at startup (`src/main.zig:944`).

The layering rule matters more than the fields: a `Rules` value is a floor where stock ships per-entity data, never a replacement for it (`src/ecs/rules.zig:7`). `Combat.attack_damage` is documented as losing to the class's `entityclasses.xml` hand item when that is non-zero, and the same shape repeats across the AI group (`src/ecs/rules.zig:57`). The per-entity values are the `EntityClass` table plus the `ClassId` component that `spawnBase` seeds from it, where a zero field means "fall back to the class table, then the rules floor" (`src/ecs/components.zig:97`, `src/ecs/world.zig:1163`). `RULES_CONFIG.md` records the disposition of each moved tunable, and the defaults are pinned by tests so a move is never a retune (`docs/RULES_CONFIG.md:13`).

## Persistence and the wire boundary

The ECS world itself is in memory and is not written to disk: a restart rebuilds it, and durable player state is serialized out of the sim columns by `src/server/persist.zig`, which reads `playerByPeer`, `transform`, `wallet`, `inventory`, `journal`, `health` and `buffs` for each joined client (`src/server/persist.zig:831`). Nothing in `src/ecs` writes files, imports the wire package layer, or knows a peer slot's address; `Game` converts `TickResult` and dirty bits into packages after the tick, and pushes hooks back in the other direction, assigning the block-store and catalog probes (`ground_fn`, `step_fn`, `solid_fn`, `place_fn`, `item_id_fn`, `stack_fn` and the rest) onto `self.sim` at construction (`src/server/game.zig:987`). A green ECS round trip in `zig build test` therefore proves sim self-consistency only; it says nothing about stock compatibility, which rests on the wire goldens and the stock client.

## See also

- [`tick.md`](tick.md): the server tick loop that calls `systems.tickAll` and consumes `TickResult`.
- [`interest.md`](interest.md): spatial range and the dirty/serialize-once helpers that read the columns described here.
- [`docs/ECS_SYSTEMS.md`](../ECS_SYSTEMS.md): the broader per-system inventory and the tick diagram.
- [`docs/RULES_CONFIG.md`](../RULES_CONFIG.md): which tunables moved onto config and which stayed in code.
- [`docs/GAME_OPTIONS.md`](../GAME_OPTIONS.md): the generated reference for every `Rules` field.
