# ECS simulation architecture

zdtd’s game sim is a single **SoA entity-component-system**.

```text
src/ecs/
  entity.zig       Slot / max_entities / NetId
  components.zig   plain data types + Mask
  world.zig        SoA columns + shared resources + spawn helpers
  systems.zig      all mutations and tickAll (AI/turrets threaded)
  interest.zig     per-client interest / known-entity tracking
  inventory.zig    armor mitigation + inventory helpers
  path.zig         greedy path helper (no navmesh yet)
  quest.zig        Catalog resource types (defs from stock XML or builtin)
  electric.zig     PowerGrid resource
  powerblocks.zig  placeable electrical block registry (id -> kind/watts)
  aidirector.zig   Director resource (clock / hordes / animals)
  root.zig         package exports
src/util/parallel.zig   range-split thread helper
```

## Model

| Concept | Implementation |
|---|---|
| **Entity** | Dense `Slot` `0..511` + stable network `NetId` (i32) |
| **Components** | Parallel SoA arrays + `Mask` presence flags |
| **Resources** | `catalog`, `power`, `director` on `World` (shared, not entities) |
| **Systems** | Pure `fn(*World, …)` in `systems.zig`; tick via `tickAll` |
| **Threads** | AI + turrets + chunk save via `util/parallel` |

### SoA columns

```text
alive, mask
transform, health, network_id, kind, flags
player, journal, wallet          // players
zombie_ai                        // zombies
vehicle                          // vehicles
turret                           // turrets
trader_stock                     // traders (inventory on the entity)
```

### Tick order (`systems.tickAll`)

1. `systemDirector`: clock, horde/blood-moon spawns (serial; spawns entities)  
2. `systemZombieAi`: multi-threaded over slots; deferred player damage  
3. `systemVehicles`: driver transform stick  
4. `systemPower`: resolve electricity graph  
5. `systemTurrets`: multi-threaded targeting; deferred zombie damage  

Command-style systems (not every tick): `questAccept*`, `questOn*`, `trade`,
`vehicleEnter` / `vehicleControl` / `vehicleExit`.

### Threading notes

- Workers only write **their own** entity slots (transform / AI / turret state).  
- Shared HP writes go through fixed-point **atomic accumulators**, then a serial
  apply pass (safe destroys).  
- Player positions are snapshotted before AI.  
- `World.saveAll` saves chunks in parallel when many are loaded.

### Queries (component matching)

No separate query DSL. Systems filter dense slots with `alive[s] && mask[s].*`.
That is the archetype/mask match path: O(capacity) scan, branch-predictable, no
LINQ-style value predicates. Interest uses spatial range on top of that.

### Concurrency path (current)

| Path | Mode |
|---|---|
| AI / turrets | range-split threads + atomic damage FP |
| Chunk save | parallel when many dirty |
| Net poll / replicate | single-threaded owner |
| World block store | not lock-free; tick-owned |

Not a third-party ECS port. Keep Zig SoA + explicit `tickAll` phases +
`util/parallel`. Zig ECS survey + steal checklist + scale brainstorm:
[../TODO.md](../TODO.md) (P3 + scale). Priority path: apm baseline → persistent
pool → dirty/serialize-once interest → chunk stream workers → sharded store.

## Game wiring

`Game.sim: ecs.World` is the only sim store. Network handlers call `systems.*` and
spawn helpers; `step()` runs `tickAll` then replicates transforms.

Quest **definitions** load from stock `Data/Config/quests.xml` into `catalog`;
see [ASSETS.md](ASSETS.md). Journals and coins are **player components**.

## Adding a system

1. Component data in `components.zig` + `Mask` bit + SoA field on `World`.  
2. Spawn helper sets mask bits.  
3. `systemFoo` / command fn in `systems.zig`; call from `tickAll` if needed.  
4. Package handlers in `server/game.zig` call systems only.
