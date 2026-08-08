# Implementation plan (close the gaps)

**Companion:** [GAP_ANALYSIS.md](GAP_ANALYSIS.md) (what is missing).  
**Living hub:** [STATUS.md](STATUS.md) (wins on conflict) · open work: [TODO.md](../TODO.md) · [INDEX.md](INDEX.md).  
**Architecture:** SoA ECS only (`src/ecs/`), stock client wire (EAC off), no mods.  
**Validate with:** unit/scenarios, `7dtd-loadgen`, stock client (EAC off), `src/apm/` dumps.

This plan turns the gap inventory into **ordered phases**. Detail sections below are
historical work packages (keep for RE touch lists). **Status banner is authoritative.**

Milestones **M0–M6** (bot wire) and **core M7–M10 / M12–M15 first cuts** are done.
**1.0 playable exit criteria are met** except the multiplayer scale gate (M11).

```text
Post-playable (2026-08-06)

M7  Stock-client terrain stand          [DONE core]
M8  Entity spawn + stats + damage       [DONE core / PARTIAL depth]
M9  Inventory + items + blocks          [DONE core]
M10 Persistence (columns + player v2)   [DONE]
M11 Interest + scale (32–128 bots)      [PARTIAL]  ← primary open scale track
M12 World depth (path, sleepers, loot)  [PARTIAL]  sleepers/loot/A* in; navmesh fidelity PARTIAL
M13 Economy (quests/traders stock wire) [PARTIAL]  multi-phase + TraderData; obj types open
M14 Vehicles / electricity placeables   [PARTIAL]  place+wire+gravity; fuel/actuation open
M15 Content breadth + admin/ops         [PARTIAL]  admin TCP + serverconfig; Steam browser open
M16 Hardening / multi-version / RWG     [OPEN]

Next stack (not the old week-1 chunk RE):
  1. Traders/quests: trader NPC replication (WORK_PLAN T1); quest accept + template inheritance
  2. Water; player-persistence depth; GameStats sandbox day sync
  3. M11 128-bot loadgen gate (serialize-once + pool + P4.0 first cut shipped)
  4. Planet-scale M2+ only after M11 numbers (parked)
```

Dependencies: do not start planet shards before M11 in-process interest wins.

---

## Principles (non-negotiable)

1. **ECS-native only.** New state = components / resources / systems. No AoS dual path.  
2. **Package IDs are dynamic.** Advertise names; never hard-code permanent u16 ids.  
3. **Wire first for client features.** Sim can be simplified if packages are correct.  
4. **Golden sizes from loadgen / captures** before claiming package done.  
5. **Serialize-once + spatial interest** before throwing cores at net encode.  
6. **Custom disk OK** until stock `.ttc` codec exists; wire must still be client-legal.  
7. **No TFP asset shipping.** Load from user `game-dir` at runtime.  
8. **Tests with each package:** unit parse/build + scenario smoke + apm counters.  
9. **Parallelism** only with disjoint writes or deferred apply (see ECS_SYSTEMS.md).  
10. **Honest docs:** update GAP_ANALYSIS when a gap closes.

---

## Phase M7: Stock client terrain stand

**Goal:** EAC-off stock client connects, receives world, stands on terrain, looks around without hard error spam.

### Work packages

#### M7.1 RE: stock NetPackageChunk body
- Capture live dedi join chunk packets (loadgen or Wireshark).  
- Annotate write/read order vs `../7dtd-research/docs/world-chunks.md` + IL.  
- Produce golden hex fixtures under `tests/fixtures/wire/chunk_*.bin` (no game DLL).  

**Exit:** documented layout in `docs/wire/WIRE_CHUNK.md` + fixture tests.

#### M7.2 Chunk encode path (stock layout)
- Implement `packages.buildStockChunkBody` (or replace intermediate).  
- Server may still store heights + simple columns; **encode** stock shape.  
- Keep intermediate format behind feature flag for loadgen bots if needed.  

**Files:** `src/wire/packages.zig`, `src/world/store.zig`, `src/server/game.zig`.

#### M7.3 WorldInfo / session packages
- Identify minimum set client requires after login (WorldInfo, GameStats, ConfigFile/IdMapping stubs).  
- Implement minimal bodies; prefer empty/safe defaults over wrong data.  

#### M7.4 Join polish
- Send spawn height from DTM.  
- Chunk streaming radius from `RequestToSpawnPlayer.chunkViewDim` (default 4–8).  
- `ChunkRemove` on leave area (optional same phase).  

#### M7.5 Stock client acceptance test (manual + scripted)
- Runbook: EAC off, connect to zdtd, screenshot/log.  
- Optional: semi-auto “client alive N seconds” probe if available.  

### Acceptance
- [ ] Stock client reaches “in world” without disconnect.  
- [ ] Terrain visible or at least non-void; player not permanently falling.  
- [ ] Existing loadgen join scenarios still green (compat flag OK).  

### Risks
- Chunk format incomplete → client crash. Mitigate with progressive field fill + capture diffs.  
- PackageIds missing required names → client never requests chunks. Map names from live 189 list.

---

## Phase M8: Entity spawn, stats, combat fidelity

**Goal:** Client sees other players and zombies as real entities; HP/damage behave.

### Work packages

#### M8.1 EntitySpawn + SpawnResponse stock bodies
- Class name / id, position, rotation, entity id.  
- Map ECS `Kind` + later `class_id` component to spawn payload.  
- On join: spawn self + nearby entities.  

#### M8.2 EntityStatChanged / AliveFlags semantics
- Document flag bits used by client.  
- Emit on spawn and HP change.  

#### M8.3 DamageEntity full round-trip
- Expand builder/parser to all fields client cares about.  
- Server authority: apply damage in ECS, broadcast remove/stat.  

#### M8.4 O(1) NetId map
- `std.AutoHashMap(i32, Slot)` or dense sparse map on World.  
- Replace linear `slotOfNetId` scans.  

#### M8.5 Entity class table (minimal)
- Load tiny subset of `entityclasses.xml` (player + 1–3 zombies).  
- Component `class_id`, `max_hp` from table.  

**Files:** `src/assets/entities.zig`, `src/ecs/components.zig`, `src/ecs/world.zig`, wire packages, game join path.

### Acceptance
- [ ] Second client sees first move (already partial; must use spawn packages).  
- [ ] Zombie visible; kill updates HP/remove on both clients.  
- [ ] Unit tests for spawn/stat golden sizes.  

---

## Phase M9: Inventory, items, blocks

**Goal:** Player can hold an item, open inventory, place/break mapped blocks.

### Work packages

#### M9.1 blocks.xml + items.xml loaders
- Parse id/name; build name→u16 and u16→name.  
- Fixture XML for CI without game install.  
- Hot path: array by numeric id.  

#### M9.2 Inventory components
```text
Inventory: slots[N] { item_id, count, quality, meta }
Holding: item_id / slot index
```
- Systems: pickup, drop, move, equip (minimal).  

#### M9.3 Inventory packages
- RE priority: inventory net family (see `inventory-netpackages.md`).  
- HoldingItem package.  
- On join: send empty or starter kit.  

#### M9.4 SetBlock uses real block ids
- Client place → server set → broadcast.  
- Persist full columns (see M10) or at least surface + top block id.  

#### M9.5 Drop bags / EntityCollect
- Death or drop creates bag entity; collect transfers items.  

### Acceptance
- [ ] Stock client inventory opens without error.  
- [ ] Place dirt/frame/wood from hotbar if ids match.  
- [ ] Restart keeps placed blocks (with M10) or same session keeps them.  

### Risks
- Id mapping mismatch with client Config → wrong blocks. Mitigate: send `IdMapping` / ConfigFile packages or force matching game build Config.

---

## Phase M10: Persistence

**Goal:** World and players survive restart.

### Work packages

#### M10.1 Full chunk store
- Store block ids (and later density) per column or sections.  
- Heightmap derived or stored.  
- Writable overlay is ZCH3 (`.zch`: heights + u32 rawData + optional paint/density). ZCH2 u16 blocks load heights-only.  

#### M10.2 Parallel save (already started)
- Dirty bit per chunk; save only dirty.  
- Atomic replace (write temp + rename).  

#### M10.3 Player save
- Per-player file: pos, inventory, journal, wallet, peer platform id.  
- Load on login match.  

#### M10.4 Optional stock `.ttc` writer (stretch)
- Only after sector codec RE closed.  
- Not blocking if custom disk + stock wire works.  

### Acceptance
- [ ] Dig/build → restart → same blocks.  
- [ ] Inventory and position restore.  
- [ ] Corruption-safe save (kill -9 mid-write → previous good).  

---

## Phase M11: Interest, replication, scale

**Goal:** 64–128 loadgen bots with stable TPS; net not O(N²).

### Work packages

#### M11.1 Spatial hash interest
- Grid cell = chunk or 16–32 m.  
- Per-client set of entity ids in radius (view dim).  
- Rebuild on cell change only.  

#### M11.2 Dirty bitsets + encode once **[shipped]**
```text
dirty: POS | ROT | FLAGS | HP | SPAWN | REMOVE
candidates = heartbeat ? alive_bits : dirty_bits ∪ mobs   (slot-ascending)
for each candidate:
  mask = observerMask(client cells, radii, active)         (one word)
  encode shared buffer once; frame once
  for each set bit in mask: sendFramedDroppable (no re-encode)
clear pos/rot/spawn/flags over dirty_bits after fan-out
```
`src/server/game.zig` `replicate`, `World.alive_bits` / `dirty_bits`
(`markDirty` is the single write funnel), `interest.observerMask`.
Mob motion deliberately stays on the heartbeat: marking `stepToward` dirty
would move mob PosAndRot from tick%10 to tick%2 and change packet volume.
apm evidence: `replicate_candidates`, `replicate_fanouts`,
`replicate_encodes_skipped` (docs/APM.md).

#### M11.3 Connection map **[shipped]**
- `World.net_to_slot` O(1) NetId → Slot.

#### M11.4 Persistent thread pool **[shipped]**
- `util/parallel.zig` long-lived Io mutex/cond workers.

#### M11.5 Loadgen 128-bot bench
- Scenario + apm snapshot thresholds documented.  

Chunk stream: named caps shipped; async workers still open.

### Acceptance
- [ ] 128 bots join and move 5 minutes without death spiral.  
- [x] apm: replicate time scales ~O(entities_dirty × interest) not O(players²).
      Pinned by the two replicate scenarios in `src/server/scenarios.zig`.  
- [ ] Compare shape to stock measured-scaling (design input only).  

---

## Phase M12: World depth (path, sleepers, loot)

**Goal:** POIs feel occupied; zombies navigate; loot exists.

### Work packages

#### M12.1 Walkability grid
- From block solid flags (blocks.xml materials).  
- Per-chunk bitset; invalidate on SetBlock.  

#### M12.2 Pathfinding workers
- Grid A* (own impl).  
- Queue + drain ≤N paths/tick; results applied in sim.  

#### M12.3 Prefab `.tts` block paint
- **PARTIAL (2026-07):** type plane painted on chunk create (`src/world/tts.zig`).  
- Remaining: density/texture, TE lists, name→id remap, `part_*` policy.  
- See [STATUS.md](STATUS.md), [MAPS.md](MAPS.md).

#### M12.4 Sleeper volumes
- From prefab metadata / sleeper XML if available.  
- Component `SleeperVolume`; wake on player enter.  

#### M12.5 Loot containers
- `loot.xml` groups; container entity/block with inventory.  
- Open/close packages.  

### Acceptance
- [ ] Zombie paths around a wall (not through).  
- [ ] Enter POI → sleepers wake.  
- [ ] Open chest → items appear in client.  

---

## Phase M13: Economy loop (stock quests / traders)

**Goal:** Accept trader quest, complete clear/fetch-ish, turn in, spend dukes.

### Work packages

#### M13.1 Stock quest wire packages
- **PARTIAL (2026-07):** Quest.Write + NPCQuestList FetchList + SharedQuest +
  stock TraderData v2 (`stock_quest.zig`). Phases/rally still shallow.

#### M13.2 Objective runners
- Per-kind systems: ClearSleepers (volume empty), FetchFromContainer, Goto POI, ReturnToNPC.  
- Keep Catalog from quests.xml; stop collapsing all phases.  

#### M13.3 traders.xml + currency
- Stock trader inventory generation.  
- Duke token item id.  

#### M13.4 Quest markers / nav_objects
- Minimal marker packages for client compass.  

### Acceptance
- [ ] Stock client quest UI tracks an active trader quest.  
- [ ] Turn-in grants reward visible in inventory.  

---

## Phase M14: Vehicles and electricity placeables

**Goal:** Craft/place minibike and generator; wire turret; drive.

### Work packages

#### M14.1 vehicles.xml + attach packages  
#### M14.2 Vehicle physics pass (ground clamp, collision AABB)  
#### M14.3 Electrical blocks as world blocks + PowerNode components  
#### M14.4 Stock wire tool package fidelity  
#### M14.5 Turret as placeable + ammo items  

### Acceptance
- [ ] Client places generator, wires consumer, powers turret, kills zombie.  
- [ ] Drive vehicle across 100 m without falling through terrain.  

---

## Phase M15: Content breadth and ops

**Goal:** Runnable dedicated for a small community.

### Work packages

#### M15.1 Asset loaders: biomes, gamestages, spawning, buffs, recipes  
#### M15.2 serverconfig.xml subset (port, max players, world, password)  
#### M15.3 Telnet or simple admin TCP (kick, give, tele, savetime)  
#### M15.4 Logging levels + rotation  
#### M15.5 Packaging (Makefile release, example unit file)  
#### M15.6 Password / basic auth packages  

### Acceptance
- [ ] Cold start from config only (no long CLI).  
- [ ] Admin can kick and give item.  

---

## Phase M16: Hardening and optional stretch

| Item | Notes |
|---|---|
| Multi-version client matrix | Pin tested game build in docs |
| Encryption path | If password requires |
| Stock `.ttc` read/write | After sector codec RE |
| RWG / procedural | Optional; prefer baked maps; design [WORLDGEN.md](WORLDGEN.md) (density + WFC tiles) |
| Steam browser | Steamworks server API |
| Sparse Y sections | Memory for large maps |
| io_uring net | Linux perf stretch |
| Full EAI parity | Never required; good enough chase/sleeper |

---

## Cross-cutting work (every phase)

### C1. Package factory pattern
```text
src/wire/packages/
  join.zig, entity.zig, chunk.zig, inventory.zig, ...
packages.zig re-exports + default_mappings assembly
```
Avoid one 2k-line packages.zig.

### C2. Capture-driven RE loop
1. Stock dedi + loadgen/client → pcap / package dump.  
2. Annotate body.  
3. Golden fixture.  
4. Zig encode/decode.  
5. Diff against capture.  

### C3. ECS extension checklist
1. Component + Mask bit.  
2. SoA column on World.  
3. Spawn helper.  
4. system or command in systems.zig.  
5. Package handlers only call systems.  
6. Tests.  

### C4. APM budgets (design)
| Section | Soft budget @ 20 TPS |
|---|---|
| net_poll | ≤ 5 ms |
| sim (tickAll) | ≤ 30 ms |
| replicate | ≤ 10 ms |
| save (amortized) | ≤ 5 ms avg |

Fail CI scenario if idle step p99 > 2 ms (regression guard).

### C5. Documentation updates per phase
- Close rows in GAP_ANALYSIS.  
- SYSTEMS / MAPS / ASSETS as behavior changes.  
- README status line.

---

## Suggested PR stacking (post-playable)

Historical week-1..12 chunk/inventory stack is **done** (see STATUS). Current order:

| Band | PRs |
|---|---|
| Now | See [WORK_PLAN.md](WORK_PLAN.md) for the current ranked tasks |
| Next | M11.5 32-bot then 128-bot loadgen gate; power fuel/actuation; lock contention |
| Then | quest objective types + trader group rolls; workstation recipe validation; multi-version matrix |
| Later | P4 guard spine beyond the first cut (policy + ledgers) |
| Parked | SCALE M2 gateway/shards; Encryption*; Steam browser / full telnet; RWG |

If scale pain shows before fidelity, pull M11 ahead of quest/power depth.

---

## Team / skill parallelization

| Track | Owner focus | Unblocks |
|---|---|---|
| **Wire RE** | Captures, golden fixtures | M7–M9, M13 |
| **World store** | Columns, save, tts paint | M7, M10, M12 |
| **ECS systems** | Inventory, path, sleepers | M8–M9, M12–M14 |
| **Assets** | XML loaders | M8–M9, M13–M15 |
| **Net scale** | Interest, pool, maps | M11 |
| **QA** | loadgen scenarios, client runbook | all |

Tracks Wire RE and World store should start day one; ECS inventory waits on package layouts.

---

## Decision log (resolve early)

| Decision | Options | Recommendation |
|---|---|---|
| Chunk wire | Stock-only vs dual intermediate | Dual until loadgen migrated; stock default for client |
| Disk format | Custom vs wait for .ttc | Custom versioned region now |
| PackageIds list | Full 194 names vs subset | Subset + grow; missing names only when handling |
| Currency | Coins vs duke item | Move to real item id in M9/M13 |
| Thread pool | std.Thread.Pool vs custom | Custom fixed pool (Zig 0.16 API churn) |
| Client target version | Pin **V3.1.0 b14** | Yes; documented in STATUS and RELEASES |

---

## Exit criteria for “1.0 playable dedi”

Not feature-complete 7DTD; **playable**. Status vs 2026-07-23 evidence:

| # | Criterion | State |
|---|---|---|
| 1 | Stock client EAC-off joins Navezgane, stands, walks | **MET** (2026-08-06 live gate 23/23, 0 NRE) |
| 2 | Two players / bots see each other; chat | **MET** (loadgen + stock concurrent) |
| 3 | Zombies spawn, damage, die; loot | **MET** (ECD bag; path still greedy) |
| 4 | Dig/build real ids; persists restart | **MET** (ZCH3 `.zch` + blockmeta) |
| 5 | Inventory hotbar use + place | **MET** |
| 6 | Trader quest path (journal + offers + trade) | **MET** first cut (full obj graphs PARTIAL) |
| 7 | 32 bots stable 30 min; apm budgets | **OPEN** (2-bot green; M11) |
| 8 | MISSING P0 empty or waived | **MET** (P0 band closed; residual is P1+) |

**1.0 core playable: YES.** Remaining 1.0 scale gate is criterion 7 (M11).

---

## Related docs

Full map: [INDEX.md](INDEX.md).

| Doc | Role |
|---|---|
| [STATUS.md](STATUS.md) | Living hub (wins on conflict) |
| [GAP_ANALYSIS.md](GAP_ANALYSIS.md) | Exhaustive gap list |
| [../TODO.md](../TODO.md) | Open backlog |
| [ECS_SYSTEMS.md](ECS_SYSTEMS.md) | Sim architecture |
| [ZIG_CLONE.md](ZIG_CLONE.md) | M0–M6 + architecture |
| [SCALE.md](SCALE.md) | Post-M11 planet track |
| [../../7dtd-research/docs/protocol.md](../../7dtd-research/docs/protocol.md) | Wire |
