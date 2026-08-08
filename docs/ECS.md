# ECS simulation architecture

zdtd’s game sim is a single **SoA entity-component-system**.

```text
src/ecs/
  entity.zig       Slot / max_entities / NetId
  components.zig   plain data types + Mask
  world.zig        SoA columns + resources + spawn + locals + observers
  systems.zig      mutations; tickAll → schedule.run
  schedule.zig     Phase enum + ordered run (buffs…commands)
  locals.zig       TickLocals scratch (cleared beginTick)
  jobs.zig         thin forSlotRange over util/parallel
  query.zig        forEach* / each packed / forEachParallelKind / group face
  group.zig        cached per-Kind dense alive lists (ascending, no heap)
  command.zig      fixed tick command buffer (cap 64; drain in schedule)
  observers.zig    on_spawn / on_death listeners (cap 4)
  sim_view.zig     narrow inv/transform mut surface
  res.zig          Res/ResMut resource accessors
  snapshot.zig     deterministic sim census/director bytes for tests
  interest.zig     spatial range + dirty/serialize-once helpers
  inventory.zig    armor mitigation + inventory helpers
  inv_ledger.zig   P4 inv cause ledger (fixed ring, no heap)
  party.zig        Party/PartyManager (membership, leader, voice lobby, shared kill XP)
  quest_systems.zig  quest phase-advance systems (questAccept*, questOn*)
  rules.zig        Rules struct + overlay (ADR 0021 sim-rule surface)
  path.zig         greedy path helper (no navmesh yet)
  poi_lock.zig     quest POI lockout table (locked until unlock grace)
  quest.zig        Catalog resource types (defs from stock XML or builtin)
  buff.zig         buff stack/duration/expiry rules over the BuffSet component
  electric.zig     PowerGrid resource
  powerblocks.zig  placeable electrical block registry (id -> kind/watts)
  aidirector.zig   Director resource (clock / hordes / animals)
  root.zig         package exports
src/util/parallel.zig   range-split thread helper
```

## Review

Agent scorecard for "is this state ECS SoA, a resource, world/*, or session?":
[prompts/ecs-soa-review.md](prompts/ecs-soa-review.md).

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
buffs                            // any EntityAlive (lazily attached)
zombie_ai                        // zombies
vehicle                          // vehicles
turret                           // turrets
trader_stock                     // traders (inventory on the entity)
```

### Tick order (`schedule.run` / `systems.tickAll`)

0. `World.beginTick`: clear `TickLocals`  
1. `systemBuffs`: 20 Hz buff duration/stack tick; reports expiries to the net layer  
2. `systemDirector`: clock, horde/blood-moon spawns (serial; spawns entities)  
3. `systemZombieAi`: multi-threaded over slots; deferred player damage  
4. `systemVehicles`: driver transform stick  
5. Power: resolve stays in `Game.step` (daylight); not doubled here  
6. `systemTurrets`: multi-threaded targeting; deferred zombie damage  
7. `systemDespawnFar`: cull far zombies  
8. `World.drainCommands`: apply deferred spawn/despawn/damage (cap 64)

Command-style systems (not every tick): `questAccept*`, `questOn*`, `trade`,
`vehicleAttach` / `vehicleControl` / `vehicleDetach`.

### Queries (`query.zig`)

```zig
ecs.forEachKind(w, .zombie, ctx, f);           // kind filter
ecs.forEachWith(w, .{ .player = true, .inventory = true }, ctx, f);
ecs.forEachAlive(w, ctx, f);
// f: fn (@TypeOf(ctx), *World, Slot) void
```

No heap; dense `0..max_entities` scan with mask/kind predicates.

#### Groups (cached kind lists, `group.zig`)

`World.kind_groups` keeps one **slot-ascending** dense array of alive slots per
`Kind` (7 x 512 x u16 = 7 KB, no heap), maintained at the only two points that
write `alive[]`/`kind[]`: `spawnBase` inserts, `destroy` removes (plus the
idempotent `World.reviveSlot`, the single sanctioned un-kill). Because `kind[s]`
is written exactly once per entity lifetime, a slot never migrates between
groups. Stock does the same thing: `World` holds the general `Entities` index
plus maintained per-type lists (`Players`, EntityAlive, vehicle/drone/turret
trackers) added in `World::SpawnEntityInWorld` and removed in
`World::unloadEntity` (asm.il:1225261-1225262, :1234230/:1234384,
:1233956/:1234090); `GetPlayers()` just returns the cached list.

```zig
for (ecs.groupSlice(w, .zombie)) |s| { ... }   // O(live), ascending
ecs.forEachKindGroup(w, .zombie, ctx, f);      // safe under removal, order unspecified then
var buf: [ecs.max_entities]ecs.Slot = undefined;
const n = ecs.copyKindInto(w, .zombie, &buf);  // snapshot; for loops that destroy
```

Keeping the list ascending means group iteration visits the same slots in the
same order as the open View scan, so wiring a group into a system is a pure
speedup with byte-identical results (nearest-player tie-breaks, capped despawn
id lists and turret target selection all depend on slot order).

**View is the default.** A group slice is invalidated by the next spawn/destroy;
loops that mutate the world use `copyKindInto` or stay on the View. `countKind`
reads the group length (one mechanism, no parallel counter).

Wired today: `systems.snapshotPlayers` (twice per tick), the `systemTurrets`
zombie-list build, `systemDespawnFar` (via `copyKindInto`, it destroys),
`Game.tickZombieBlockDamage`, `Game.broadcastVehiclePositions`. The replicate
entity pass, motion dirty-clear and `clearDeadKnownEntities` do not use groups
either (iterating 7 kind groups would be kind-major, not slot-ascending); they
walk `World.alive_bits` / `World.dirty_bits`, word-packed sets maintained by
`spawnBase` / `destroy` / `reviveSlot` and the `markDirty` funnel, which keeps
slot order and costs O(live) or O(changed). Still an open scan: `systemZombieAi`
(its predicate is `mask.zombie_ai`, a bit mutated after spawn, so it would need
maintenance points that do not exist).

### Tick command buffer (`command.zig`)

```zig
_ = w.pushCommand(.{ .spawn_zombie = .{ .x, .y, .z, .hp } });
_ = w.pushCommand(.{ .despawn = .{ .net_id } });
_ = w.pushCommand(.{ .damage = .{ .net_id, .amount } });
// drained once at end of tickAll (also World.drainCommands)
```

Full buffer drops new ops (`dropped` counter). Systems and (later) plugins enqueue;
core applies serially so parallel AI never races spawn/destroy.

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
| Net poll / replicate | single-threaded owner; serialize-once framed fan-out |
| World block store | not lock-free; tick-owned |

Not a third-party ECS port. Keep Zig SoA + explicit `tickAll` phases +
`util/parallel`. Zig ECS survey + steal checklist + scale brainstorm:
[../TODO.md](../TODO.md) (P3 + scale). Priority path: apm baseline → persistent
pool → dirty/serialize-once interest **[shipped]** → chunk stream workers →
sharded store.

### Serialize-once interest (M11.2)

`Game.replicate` walks entities outer, clients inner:

1. Gate with `Dirty` + `interest.needsPosSend` (dirty pos/rot or heartbeat).
2. Encode PosAndRot once; for zombies also Speeds + AliveFlags once.
3. `packages.framed` once per package kind into stack scratch.
4. Fan-out framed bytes via `sendFramedDroppable` to peers in cell range
   (no self-echo for the owning player).
5. `interest.clearAfterReplicate` clears pos/rot/spawn/flags; hp/inv/remove stay.

Spawn-on-approach still builds ECD EntitySpawn once when any peer needs it.
Chunk stream caps are named in `game.zig` (`max_streamed_chunks`,
`chunk_stream_radius_*`, `chunk_adds_per_stream_tick`, `chunk_stream_period_ticks`).

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
