# Agent prompt: ECS ownership and SoA discipline review (zdtd)

Copy everything below the line into a fresh agent session (or `@` this file).

---

## Role

You are reviewing **simulation ownership and data layout** in **zdtd**
(`/home/maci/Desktop/7dtd/zdtd`): a clean-room Zig 0.16 dedicated server for the
stock 7DTD client wire.

Your job is to decide, for each piece of game state and each mutation path:

1. **Does this belong in the ECS SoA world?** (entity columns vs resource vs
   world-store vs peer/session)
2. **If it is entity-ish, is it actually SoA?** (parallel arrays + Mask, not
   AoS bags or parallel HashMaps of the same entities)
3. **Are mutations systems (or explicit Game orchestration of systems)?** Or is
   logic stranded in wire handlers / package builders?
4. **Does the tick path stay SoA-friendly?** (dense scans, named caps, no heap,
   serialize-once interest)

This is complementary to:

| Prompt | Focus |
|---|---|
| `review-zig-idiomatic.md` | Language, comptime, `std.Io`, hot-path no-alloc |
| `review-abstractions.md` | Whether a helper/layer should exist |
| `review-simd.md` | Dense-loop vectorization after SoA is correct |
| `audit-hardcoded-data.md` | Stock XML vs config hardcodes |

**Do not** adopt a third-party ECS core (Bevy-style archetypes, flecs, etc.).
zdtd keeps **dense Slot + SoA columns + Mask + systems as functions**. Steal
ergonomics (`query`, `command`) only when they preserve that shape
([docs/ECS.md](../ECS.md), TODO P3).

## Read first

| Doc | Why |
|---|---|
| `AGENTS.md` | Layers table, SoA + serialize-once, tick rules, anti-patterns |
| `docs/ECS.md` | Canonical ecs layout, columns, resources, query/cmd |
| `docs/SYSTEMS.md` | What runs each tick and order |
| `docs/AUTHORITY.md` | C2S gates; server applies results into sim |
| `docs/SCALE_ARCHITECTURE.md` | Why SoA + interest (not Mono shapes) |
| Code under review | Actual ownership and call sites |

## Non-negotiable

- **No em dashes. No AI attribution.**
- **SoA for entities.** Components live as parallel arrays indexed by `Slot`
  (`0..max_entities-1`), gated by `alive[]` + `Mask`. Not
  `ArrayList(EntityStruct)`, not `HashMap(NetId, FatEntity)`.
- **Stable network id is not the storage key.** `NetId` → slot via
  `net_to_slot` (O(1)); columns never keyed by NetId.
- **Systems are functions** `fn(*World, …)` (or Game methods that only
  orchestrate). Package builders do not mutate sim.
- **Resources are shared, not entities:** `catalog`, `power` (PowerGrid),
  `director`, quest catalog, optional `commands` buffer on `World`.
- **World blocks / chunks are not ECS entities.** `world/*` owns terrain, TE
  stores, prefabs, DTM. Link by world pos or net id when needed.
- **Peer / join SM is not ECS.** `Game.clients[]`, LiteNet peers, package maps
  stay in `server/` + `litenet/`. ECS holds the **player entity** once spawned
  (`player.peer_slot`).
- **Hot path:** no heap in tick / per-packet interest / stream encode; fixed
  caps; `query.forEach*` and command buffer preferred over ad-hoc alloc lists.
- **Interest:** serialize-once per entity per tick where the path already does;
  no self-echo of movement unless stock does.
- **`make check` / `zig build test` green** if you change code.
- **Missing beats fake.** Do not invent component blobs to "look ECS-complete."

## Scope modes (user may pick one)

| Mode | Do |
|---|---|
| **Review only** | Findings tables + optional `docs/ECS_REVIEW.md`. No code. |
| **Review + fix P0** | Fix mis-owned state and AoS regressions that break tick or authority. |
| **Deep pass** | Full inventory of `src/server/game.zig` C2S paths vs ecs systems; propose moves. |

Default: **Review only** unless the user asks for patches.

---

## Ownership map (ground truth)

Use this as the scorecard. Flag anything that lives in the wrong column.

| Kind of state | Belongs in | Does **not** belong in |
|---|---|---|
| Transform, HP, flags, kind | ECS SoA columns | Wire package, LiteNet peer |
| Player inv, journal, wallet | ECS (player mask) | Ad-hoc Game arrays parallel to clients |
| Zombie AI, vehicle, turret | ECS columns + systems | Open-coded loops only in game.zig without system fn |
| Director clock, horde pressure | ECS resource (`director`) | Static globals |
| Power graph nodes/wires | ECS resource (`power` / electric) | Per-block only in world without grid link |
| Quest defs (XML) | Catalog resource | Duplicated tables in game.zig |
| Quest progress per player | ECS journal / quest components | Client-only |
| Chunks, blocks, density | `world/*` | ECS entity-per-block (forbidden) |
| Container TE slots | `world/containers` (pos key) | Player inv columns |
| Signs, locks, land claims | world/server stores by pos | Entity spam |
| Join phase, package map, stream radius | `Game` / `Client` | ECS |
| Reliable window, UDP | `litenet/*` | ECS |
| Metrics | `apm/*` | Sim columns |

### Entity vs resource vs world vs session

```text
                    ┌──────────── session (Game.clients, peers) ────────────┐
                    │ join SM, interest bitsets, streamed chunks, known_ent │
                    └───────────────────────┬───────────────────────────────┘
                                            │ peer_slot / NetId
                                            v
┌─ ECS World (SoA) ──────────────────────────────────────────────────────────┐
│ Slot columns: transform health mask kind ai vehicle turret inv …           │
│ Resources: director power catalog commands                                 │
│ systems.tickAll + query.forEach* + command.drain                           │
└───────────────────────┬────────────────────────────────────────────────────┘
                        │ block/TE queries, ground_fn, solid_fn
                        v
┌─ world/* ──────────────────────────────────────────────────────────────────┐
│ chunks ZCH3, DTM, prefabs, containers, biomes, sleepers, blockmeta         │
└────────────────────────────────────────────────────────────────────────────┘
```

---

## What "properly managed by ECS" means here

### Must be ECS (if it exists at all)

- Anything with a **networked entity id** the client tracks (player, zombie,
  animal, trader, vehicle, turret, loot bag, item drop).
- Per-entity combat/AI/motion that other systems must see the same tick.
- Per-player inventory, wallet, journal progress that C2S mutates under authority.

### Must NOT be forced into ECS

- Voxel terrain and "every block is an entity."
- Pure wire DTOs and BinaryReader layouts (`wire/*`).
- Connection lifetime and package id negotiation.
- XML catalogs (load once into tables/resources; do not spawn one entity per recipe).

### Borderline (judge by call sites)

| Topic | Prefer | Acceptable exception |
|---|---|---|
| Workstation TE | world TE store + thin system tick | Game method if it only calls store + broadcast |
| Sleeper volumes | world markers + system wake → ECS spawn | Game.tickSleeperVolumes orchestration |
| Land claim | pos-keyed store on Game/world | Check from SetBlock handler (authority) |
| Loot roll | system or inv helper using loot table resource | One-shot in kill path if no alloc |
| Weather | resource or Game field from biomes table | S2C builder only |

---

## SoA checklist (layout)

For each entity component type you touch:

- [ ] Stored as `component: [max_entities]T` (or equivalent dense column), not
      `ArrayList(T)` grown per spawn on tick
- [ ] Presence via `Mask` bit (or kind enum), not "optional pointer per slot"
- [ ] Writes go through spawn helpers / systems that set mask + columns together
- [ ] Destroy clears mask + `alive` + net map; no dangling NetId
- [ ] Iteration uses `alive` + mask (or `query.forEachWith`), not sparse lists that
      desync from columns
- [ ] No second shadow structure that duplicates the same entity set (except
      ephemeral tick scratch with named cap)
- [ ] Hot reads are column-friendly (same field across many slots) where AI/interest need it

**AoS smell (fail):**

```text
const Ent = struct { id: i32, x: f32, y: f32, z: f32, hp: f32, ai: Ai };
ents: ArrayList(Ent)
```

**SoA shape (pass):**

```text
transform: [N]Transform
health: [N]Health
zombie_ai: [N]ZombieAi
mask: [N]Mask
alive: [N]bool
```

---

## Systems and mutation checklist

- [ ] C2S handler validates (phase, ownership, bounds) then calls **system or
      World method**, then broadcasts **resulting** state
- [ ] Handler does not open-code a full AI/combat loop that belongs in `systems.zig`
- [ ] Package `build*` functions are pure encoders (buf in, bytes out); no World mut
- [ ] Tick order is stable and documented (`tickAll` / Game.step sections)
- [ ] Deferred spawns/despawns/damage use `command` buffer when cross-system
      (cap 64; drop if full; no heap)
- [ ] Parallelism only via `util/parallel` on disjoint slot ranges; no ad-hoc
      threads inside systems
- [ ] RNG on sim paths is seeded/stateful on director or entity, not ad-hoc time

**Stranded logic smell:** multi-dozen lines of combat or inv rules only inside
`handlePackage` with no `systems.*` or `inventory.*` entry point and no test
hook except full Game.

---

## Interest, net id, and replication

- [ ] Replication reads ECS columns + dirty bits; does not keep a parallel
      "replicate me" AoS list as source of truth
- [ ] `known_entities` / streamed chunk sets are **per-client session** (correct),
      not ECS components
- [ ] Entity spawn/remove S2C follows ECS create/destroy (or command drain)
- [ ] Self-echo policy matches AUTHORITY (no bogus own PosAndRot echo)

---

## Capacity, determinism, fail-closed

- [ ] `max_entities` and stream caps are named consts; at cap, drop/omit with
      counter, do not realloc
- [ ] Soft warn path optional (~80% full) without heap spam
- [ ] Same seed + inputs → same director/AI outcomes where claimed
- [ ] Missing catalog row → omit entity feature or refuse spawn; no fabricated
      class id space

---

## Review procedure

1. **Inventory** touched files into buckets: ecs / world / server / wire / assets.
2. For each **mutable game fact** in those files, fill:

   | State | Current home | Correct home | SoA? | Mutator | Severity |
   |---|---|---|---|---|---|

3. Scan `game.zig` handlePackage arms for **stranded sim** (logic that should be
   `systems.*` / `inventory.*` / world store).
4. Scan for **AoS / dual index** regressions (lists of entities beside columns).
5. Check **tickAll** and Game.step order vs SYSTEMS.md; note races or double mut.
6. Check **query/command** usage: new loops should prefer `forEach*` / commands
   when they replace error-prone hand scans.
7. Produce findings (below). Fix only if mode allows; keep diffs minimal.

### Severity

| Sev | Meaning |
|---|---|
| **P0** | Wrong authority home (client blob applied), entity table corruption, tick heap, dual source of truth causing desync |
| **P1** | Clear SoA/ECS violation with real cost or bug risk (AoS entity list, sim in wire builder) |
| **P2** | Stranded logic, missing system boundary, weak query use; cleanup |
| **P3** | Doc drift, naming, optional ergonomics (packed `each`, observers) |

---

## Output format

### Summary

2-5 sentences: overall ECS health, worst ownership bugs, whether tick stays SoA-safe.

### Findings

| ID | Sev | Location | Issue | Correct home / shape | Suggested fix |
|---|---|---|---|---|---|

### Ownership scorecard (touched areas)

| Area | ECS SoA | Resource | world/* | session | Grade (A-F) |
|---|---|---|---|---|---|
| … | | | | | |

### Tick / systems notes

- Order issues
- Missing drain of command buffer
- Interest/serialize-once gaps

### Explicit non-actions

List parked items you will **not** do (archetype ECS, entity-per-block, Wasm
script components, etc.).

### Optional patches

If mode includes fixes: file list + test commands (`zig build test`, targeted
filters). Update `docs/ECS.md` / STATUS only if ownership surface changed.

---

## Anti-patterns (instant findings)

- Entity-per-block or entity-per-item-stack in the world
- `HashMap(NetId, struct { all components })` as primary store
- Mutating sim inside `wire/stock_*.zig` builders
- Growing `ArrayList` of AI targets every tick without cap
- Second "players[]" sim array that duplicates ECS player columns
- Spawning threads in systems except `util/parallel`
- Treating join phase as an ECS component instead of Client flags
- Inventing components to mirror Unity MonoBehaviour graphs 1:1

## Good patterns (reinforce)

- `World.spawn*` sets columns + mask + net map together
- `systems.tickAll` owns AI/vehicles/turrets/director; Game broadcasts results
- C2S: validate → system → encode S2C from ECS/world result
- `query.forEachKind(.zombie, …)` for dense scans
- `pushCommand` / `drainCommands` for mid-tick spawn/despawn
- PowerGrid as resource; block place registers node by pos
- Containers by `PosKey` in world store; open bag uses net id only for loot entities

---

## Quick command cheatsheet

```bash
# layout + system entrypoints
rg -n "pub fn tickAll|forEach|pushCommand|spawnZombie|mask\\[" src/ecs/

# stranded mutation in wire (should be empty for sim)
rg -n "sim\\.|world\\.|health\\[|inventory\\[" src/wire/ --glob '*.zig'

# C2S arms that might own too much logic
rg -n "if \\(std.mem.eql\\(u8, name" src/server/game.zig | wc -l

zig build test
```

## Done when

- [ ] Ownership table filled for scope
- [ ] P0/P1 findings listed with correct home
- [ ] No recommendation to import a foreign ECS
- [ ] If code changed: tests green; ECS.md updated if public shape changed
