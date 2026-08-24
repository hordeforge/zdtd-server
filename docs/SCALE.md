# Scale: M11 single-node scale and planet-scale shard plan

> **What this is:** the parked scale plan, M11 single-node switches plus the planet-scale sharding design gated on M11 numbers.

> **Related:** [ARCHITECTURE §8](ARCHITECTURE.md#8-interest-and-replication-serialize-once) · [ARCHITECTURE §6](ARCHITECTURE.md#6-ecs-simulation-and-schedule) · [STATUS](STATUS.md) · [APM](APM.md) · [AUTHORITY](AUTHORITY.md) · [WORLDGEN](WORLDGEN.md) · [STD_ABSTRACTIONS](STD_ABSTRACTIONS.md)

**Dates:** 2026-07-22 (substrate analysis), 2026-07-23 (build plan). Research
verified via adversarial deep-research pass (104 agents, 3-vote refutation per
claim; sources cited inline).

**Status: parked.** Execution is gated on the M11 in-process interest work (see
[STATUS.md](STATUS.md) / [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md)).
Part 1 is the research substrate and the M11 single-node scale switches;
Part 2 is the planet-scale build plan and is parked until M11 numbers exist.

## Goals (overall target)

- 1:1 Earth voxel world (~510M km²) streamed from real DEM data
- ~1000 concurrent players, ~10000 active AI entities
- Stock, unmodified 7DTD clients (LiteNet UDP + TFP package wire)

## Part 1: M11 single-node scale (substrate analysis and verified research)

> This part is the substrate analysis and verified research. The concrete 
> positive build plan (shard topology, handoff protocol, interest at scale, 
> terrain serving, persistence tiering, staged milestones M1..M7) is Part 2. 
> SpacetimeDB below is one rejected substrate option among that analysis, not 
> the whole story.

### Substrate option A (rejected): SpacetimeDB as the sim substrate

One candidate substrate, evaluated and rejected. The positive plan
(Part 2) uses in-process SoA regions instead; the
detailed reasoning for not building the authoritative sim on SpacetimeDB
follows.

All claims verified 3-0 by adversarial voters against live primary sources
(vendor docs, license text, Clockwork's own blog) on 2026-07-22.

1. **No path to our clients** (docs/clients/connection, key-architecture).
   Only transport is a persistent WebSocket (subprotocols
   `v1.bsatn.spacetimedb` / `v1.json.spacetimedb`) via its own SDKs
   (TypeScript, C#/Unity, Rust, Unreal). Wire-protocol docs and
   `crates/client-api-messages/src/websocket.rs` define no UDP, no raw
   sockets, no pluggable transports. Reducers run in a WASM sandbox and
   cannot open sockets. LiteNetLib is a reliability layer over raw UDP;
   WebSocket is TCP-framed. A Zig gateway doing full protocol translation is
   mandatory in any design.
2. **Wrong compute model for the hot loop** (key-architecture,
   language-support). Server logic must be "a WebAssembly module or
   JavaScript bundle that imports a specific low-level WebAssembly ABI."
   "Reducers are run in their own separate and atomic database transactions";
   game ticks are prescribed as scheduled reducers, one transaction each. A
   20Hz SoA loop mutating arrays in place for 10k AI has no equivalent.
   Softener noted: newer "procedures" are non-transactional but are for
   external calls, not the game-logic path.

   **On "no Zig", be precise.** Zig *does* compile to wasm32 (verified:
   `zig build-exe -target wasm32-freestanding -fno-entry --export=... `
   produces a valid module). The target is not the blocker. The blocker is
   the **module ABI**: a SpacetimeDB module must import the host functions
   in SpacetimeDB's `spacetime_*` namespace (table iter/insert/delete, log,
   scheduling, BSATN codec) and export the reducer dispatch entry points
   (`__call_reducer__`, `__describe_module__`, etc.). Those bindings ship as
   maintained `bindings-sys` crates only for **C#, C++, Rust, TypeScript**.
   A Zig module needs that ABI surface. Not hypothetical: the community
   `ookami125/SpacetimeDB-Zig` example already implements a Zig reducer
   module, and `phiat/spacetimedb-zig` is a Zig *client* SDK. So "no Zig"
   was overstated, it means "no *official* Zig bindings," not "Zig can't do
   it." The residual cost is depending on unofficial, version-chasing glue,
   and it lives in the ABI layer, not the compiler. See point 5 for the full
   binding picture.
3. **No horizontal scale inside the product** (Clockwork blog, admission
   against interest): "Each SpacetimeDB database is currently limited in
   size to fitting in-memory on a single machine." BitCraft is "a set of
   many SpacetimeDB databases which handle a spatial partition in the
   world," implemented "on top of SpacetimeDB and not within it." FAQ (July
   2026) confirms no native clustering. The sharding layer is the hard part
   you build either way.
4. **License blocks a sharded deployment** (LICENSE.txt master, verified):
   BSL 1.1, Clockwork Laboratories, Change Date 2031-06-18 → AGPLv3 with
   linking exception. Additional Use Grant: "no more than one SpacetimeDB
   instance in production and ... you do not use the Licensed Work for a
   Database Service." N shard nodes = N instances = commercial license.
5. **Zig bindings: community, not official, both sides already exist.**
   No *official* Clockwork Zig SDK, but the community has built both halves:
   - **Client/gateway side:** `phiat/spacetimedb-zig`, a Zig client SDK
     (real-time subscriptions, local cache, reducer calls, HTTP REST, BSATN
     codegen). Demonstrated by `phiat/click-arena-zig` (Zig + raylib
     multiplayer game against a live SpacetimeDB). This is the piece our
     gateway would use to subscribe to world state and re-encode it into
     stock LiteNet frames, so the gateway→DB link is *not* from scratch.
   - **Module side:** `ookami125/SpacetimeDB-Zig`, an example Zig reducer
     module, i.e. someone already wrote the `spacetime_*` host-ABI glue for
     Zig-to-wasm modules. Proves it's feasible, though it's a single
     community example, not a maintained `bindings-sys` we'd want to depend
     on for a production sim.
   Net: the earlier "no Zig path" is too strong. Zig *can* be both the
   gateway client and (with community ABI glue) the reducer module. What
   remains true: these are unofficial, version-chasing dependencies, and the
   deeper rejection reasons (transaction-per-tick vs SoA hot loop,
   single-node RAM ceiling, BSL one-instance cap, mandatory gateway anyway)
   are unaffected by binding availability.

### What adopting it would take anyway (theoretical cost)

- Keep 100% of `wire/` + LiteNet stack in a Zig gateway (translation layer);
  add a BSATN/WebSocket client in Zig (hand-rolled or Rust-FFI).
- Rewrite all of `ecs/` (AI, director, craft, damage, quests, vehicles) as
  reducers. Two sub-options for the module language:
  - **Rust/C#** (supported bindings): least glue, but the sim rewrites out of
    Zig entirely, two languages in the project.
  - **Zig-to-wasm module** (hand-written `bindings-sys`): keeps the sim in
    Zig, but you author + maintain the full SpacetimeDB host ABI yourself and
    chase every version bump. Only sane if the sim staying in Zig is worth
    owning an unstable ABI port.
  Either way per-tick simulation becomes scheduled-reducer transactions with
  commit/rollback semantics per tick, the transaction-per-tick model, not
  in-place SoA mutation, is the deeper mismatch regardless of language.
- Accept double serialization per tick per client window (reducer →
  subscription diff → BSATN → gateway → LiteNet frame) at 20Hz.
- Build the spatial partitioning layer above it (as BitCraft did) once one
  node's RAM or throughput is exceeded, and negotiate a commercial license
  for >1 instance.
- Gains: transactions, subscription queries, persistence, multi-gateway
  fan-in "for free" on ONE node. Everything else remains our work.

**Bounded use that would be legal and sane:** a single out-of-band instance
for meta/ops (leaderboards, analytics mirror, account data), never the
authoritative 20Hz sim.


### Verified design lessons

| Lesson | Source | Vote |
|---|---|---|
| Static region assignment beats dynamic entity balancing (users abandoned SpatialOS auto-LB for predictability) | Improbable runtime-rebuild retrospective | 3-0 |
| Interest management must be subscription views over state, not message routing (SpatialOS v1 could not retrofit QBI) | same | 3-0 |
| Thread-per-core, shared-nothing, io_uring for single-node tails (Iggy: −81% P9999 leaving tokio work-stealing; ScyllaDB/Seastar precedent) | Apache Iggy migration report | 2-0 |
| Virtual actors (Orleans) linear-scale for backend services (Halo 4 presence), but cross-actor RPC ~6.5–15ms, never on a 50ms tick path | Orleans papers/case studies | 3-0 |
| 1:1 Earth on-demand voxel gen from public geodata is proven (Terra++/Build The Earth; no pre-generated planet) | BuildTheEarth/terraplusplus | 3-0 |
| Copernicus GLO-30: free, anonymous S3 (`copernicus-dem-30m`, eu-central-1), 1°×1° COG tiles, deterministic keys, HTTP range reads verified (206), 1024² internal tiles + overviews, DEFLATE PREDICTOR=3 | AWS Open Data registry + live probes | 3-0 |

Caveats surfaced by the refutation pass (worth honoring):

- Terra++ needs client-side CubicChunks for tall terrain. 7DTD clients have
  fixed world height (0–255), so we clamp/rescale DEM elevation into that
  band (`dem.elevToBlockY`: sea 60, 12m/block); no client mod possible or
  needed. A companion claim that this makes the approach non-transferable was
  itself refuted 1-2, no verified blocker either way.
- GLO-30 is a **DSM** (surface model: includes tree canopy and buildings),
  not bare-earth. Fine for gameplay terrain; do not treat as ground truth.
- A small set of country tiles was historically withheld at 30m; the claim
  "GLO-90 covers the fallback" was REFUTED 0-3 (2023_1 release opened
  Armenia/Azerbaijan/Moldova, but verify coverage empirically, not by
  assumption). `tileList.txt` in-bucket is the authoritative index.
- Iggy's io_uring numbers are single-source self-reported benchmarks
  (medium confidence); treat as directional, benchmark our own shard.
- Orleans "single activation" is only eventual under churn (duplicate grains
  possible); another reason to keep actors off the authoritative sim path.
- A claim describing SpatialOS v2's three-component topology was refuted 1-2
  and is excluded; only the v1-failure lessons above are load-bearing.


### Target topology

```
stock clients ──LiteNet UDP──► gateway tier (Zig)
                                 │  session pinned to ONE gateway
                                 │  interest views (known_entities today)
                                 │  entity-id remap at shard boundaries
                                 ▼
                     static region shards (Zig, one process each)
                       lat/lon cells; today's zdtd = one shard
                       thread-per-core + io_uring inside a shard
                                 │
              ┌──────────────────┴──────────────┐
              ▼                                 ▼
      terrain service (Zig)              persistence tier
      GLO-30 COG range reads             per-shard files now;
      → heightmap → voxel chunks         KV/SQL later; Orleans-style
      tiered cache (RAM→disk→S3)         actors allowed HERE only
```

- **Shard boundaries are static and designer-visible** (Improbable lesson).
- **Handoff protocol:** gateway checkpoints entity on shard A, spawns on
  shard B, remaps net ids; client sees one continuous session because its
  whole view (≤12 chunks) always flows through the same gateway socket.
- **Why the seam works:** per-client view is tiny relative to the world, so
  the gateway can fully own what each client knows (we already track
  `known_entities` per client, that set becomes the remap table).


### XML catalog vs dynamic state (applies to any store)

- XML stays source of truth for definitions; clients derive ids from the same
  XML (AssignIds), so the DB can never diverge from it.
- Store instances reference catalog by **name** (or name-hash) + a config
  fingerprint (sha256 of canonical XML set). Numeric ids are per-version
  projections, rebuilt at boot in one transaction.
- Config change ⇒ world restart with a migration pass; live XML reload is a
  non-goal (clients load config once at connect).


### `[perf]` switches (zdtd.toml, all default off)

Each switch trades a documented property, so each ships with an always-on apm
section/counter that must show the cost before the switch is worth flipping.
Status here; operator surface in `zdtd.toml.example`, metric names in
docs/APM.md.

| Switch | What it changes | Evidence to check first | Known gap |
|---|---|---|---|
| `async_chunk_flush` | `store.saveChunk` hands the encoded payload to one joined background writer (`world/chunk_flush.zig`) instead of writing inline. Encode stays on the tick thread. | `save_encode` vs `save_io` histograms; `chunk_flush_sync` (queue-full fallbacks) | Encode is still on the tick (~850 KiB memcpy per fully populated chunk). `io_fs.injectWriteFailures` cannot observe async writes, so the switch is force-disabled under `parallel.isForceSerial()` (DST, offline `Game`, scenarios). |
| `terrain_snapshot` | `Game.pathStepAt` answers from a per-tick per-column surface table (`world/terrain_snapshot.zig`) instead of taking the process-global `terrain_mu` for every A* neighbour probe. | `sim_entities` p99; `terrain_snap` rebuild cost; `terrain_snap_misses` | Answers only the surface footing case: a wall or a building interior is outside the body's step/drop band and falls back to the locked hook, as does anything outside the window (`max_chunks = 256` chunks, radius 2 per player). A worker `getOrCreate` miss can still evict a chunk the snapshot answers for; the snapshot is a copy so nothing dangles, but the regenerated chunk is not *provably* identical in every eviction order. |
| `job_batches` | Sleeper-volume player test runs as a `jobs.forSlotRange` batch. Spawns still apply serially in ascending volume index (the spawn seed is derived from `vi`). | `sleeper_scan` histogram; `sleeper_volumes_scanned` | Only the sleeper scan. See below for the two batches that stayed unimplemented. |

#### Deliberately not built (and why)

- **Deferred path-solve phase** (gather requests → parallel solve → apply next
  phase). A* already runs inside the parallel AI batch and writes only its own
  slot, so a separate phase would add a per-tick *solve budget*, not parallelism.
  That budget now exists without the phase: `World.pathBudgetAdmits` gates
  replans by a stride derived from last tick's demand, and a refused body follows
  the waypoint buffer its last solve produced instead of straightening its chase.
  Admission is a pure function of slot and tick number rather than a shared
  atomic countdown, so the outcome does not depend on which worker ran first. The
  contention win the phase was supposed to deliver is what `terrain_snapshot`
  delivers. `path_replans` and `path_replans_denied` (TickResult → counters) are
  the numbers that would have to justify building it anyway.
- **TE loot as a job batch.** `assets/loot.zig` `rollContainer` is pure and
  parallelisable but costs microseconds. The real cost in that path is the
  up-to-65536-cell scan in `Game.ensurePrefabStorageInChunk`, and an
  exactly-equivalent parallel version must gather candidates from block ids only
  (never `containers.get`, which the serial apply mutates), apply in scan order,
  stop at `found >= 32`, and fall back to the serial scan on gather overflow, or
  the early return that skips the prefab TE list diverges. `te_scan` /
  `te_scan_cells` ship now; the refactor waits on them.

## Part 2: Planet-scale shard plan (parked until M11 numbers exist)

Positive companion to the Part 1 substrate analysis (which records the 
SpacetimeDB rejection). This part is the concrete plan: what to build, in 
what order, on top of the components that already exist in this repo. 
M1 (DEM streamer) is done; M2+ are not started.

### Two axes, equal weight

"Planet scale" is **two** independent scaling problems, and this doc gives them
equal weight:

- **World size**: 1:1 Earth voxel world (~510M km2 surface, ~149M km2 land)
  streamed from real DEM, not pre-generated. Sections 1, 4, 5.
- **Player + entity count**: thousands of concurrent stock clients (target
  ~1000 now, headroom for more) and ~10000+ active AI entities. Sections 1, 2,
  3.

They are coupled by one mechanism: **spatial sharding**. Cells partition the
world (world-size axis) *and* bound how many players + AI any one sim process
carries (player-count axis). A region is sized by load, so a dense spawn city
and an empty ocean cell are both just cell ranges with different region
budgets. Neither axis dominates: a giant empty planet is easy, a small map with
5000 players is hard, and the target is both hard at once.


### The one fact the whole design hinges on

A stock client's world view is tiny. `ViewRadius` defaults to 4 and zdtd caps
its chunk-GO stream ring (meshable core after neighbor halo; STATUS / wire/WIRE_CHUNK:
  fixedSizeCC=false needs CGO ≥ viewDist²−10, stream r≥6);
even a maxed client at
`viewDist` ~12 sees a 25x25 chunk ring. At `chunk_size = 16`
(`world/store.zig:31`) that is a **~400m x 400m** window into a 40,000km
circumference planet. The client never knows how the world is partitioned
behind the socket. That gap is the whole opportunity: the server can shard the
world arbitrarily and remap ids at the seam, and a client cannot tell.

Two hard limits in today's code define the shard sizing:

- `max_entities = 512` (`ecs/entity.zig:3`), fixed-size SoA columns
  (`ecs/world.zig`). Systems scan `0..max_entities` every tick
  (`ecs/systems.zig:1451`, `ecs/world.zig`), so cost is O(capacity), not
  O(alive). Raising the cap to hold 10k entities on one node linearly slows
  every tick. **Conclusion: bound entities per shard (~512..2048), scale out by
  adding shards, do not grow one array to 10k.**
- `max_resident_chunks = 4096` (`world/store.zig:524`) with LRU eviction. That
  is the per-shard hot chunk working set, not the world.

So a shard is sized by *load*, not by *area*: it owns however much contiguous
cell space its bounded entity + chunk budget can carry.


### 1. Shard topology

### Spatial cells

Partition the world by a fixed geographic grid, designer-visible and static
(the Improbable lesson in Part 1: static assignment beat dynamic
entity balancing 3-0). Two coordinate layers:

- **World meters (XZ)**: what the sim and wire already use. Origin anchored at a
  real lat/lon (`dem.Anchor`), meters-per-pixel varying with `cos(lat)`
  (`dem.zig:150`).
- **Cell id**: a quantized tile over the world. Reuse the DEM's natural tiling.
  GLO-30 is 1x1 degree COGs; an S2/H3 cell or a simple `floor(lat), floor(lon)`
  pair is a stable, hashable **region key**. One region server owns a
  **contiguous range of cells** (e.g. a rectangle of degree tiles, or one S2
  cell at a chosen level).

A region owns: the authoritative sim (its `ecs.World`), its resident chunk
store slice, and persistence for its cells. Regions share nothing at runtime
except the handoff protocol.

### Assignment

- **Static by default.** A region-to-node map (a small config file: cell range
  → node address) is loaded at boot. Boundaries are stable and visible, so ops
  can reason about load and colocate hot areas (spawn cities) deliberately.
- **Dynamic split/merge as an operation, not a per-tick balancer.** When a
  region's entity or chunk budget saturates, a coordinator splits its cell
  range and spins a new region for half. This is a rare control-plane event
  (seconds), never the 50ms tick path. This is exactly how BitCraft runs "many
  SpacetimeDB databases, each a spatial partition" above the DB, not inside it
  (Part 1 point 3): the partition layer is yours to build
  regardless of substrate.

### Gateway pinning

A client session is pinned to **one gateway** for its whole life. The gateway
terminates LiteNet, owns the client's interest view, and re-homes the *backing
region* underneath the client as the player moves. The socket never moves; the
region behind it does. This is the seam: interest management + per-shard
entity-id remapping live in the gateway, so the region topology is invisible to
the client.

```
stock clients ──LiteNet UDP──► gateway tier (Zig)
                                 session pinned to ONE gateway
                                 per-client interest view (known_entities)
                                 net-id translation table (client id ↔ region id)
                                 │
                    subscribes to 1..k regions overlapping the client window
                                 │
              ┌──────────────────┼──────────────────┐
              ▼                   ▼                   ▼
         region shard A     region shard B     region shard N
         cells [a..b)       cells [b..c)       cells [n..)
         ecs.World ≤2k ent  thread-per-core    per-region store slice
              │                                        │
              └──────────── terrain service ───────────┘
                    DEM streamer (world/dem.zig)
                    GLO-30 COG range reads → voxel chunks
                    tiered cache RAM → local disk → object store
```


### 2. Cross-shard handoff protocol

An entity (player or AI) at world position P moving from region A's cells into
region B's cells must migrate. The client stays connected to its gateway
throughout.

Identity layers (this is the "per-shard entity-id remapping" seam):

- **Region-local slot** `0..max_entities` and region-local `NetId` (i32,
  `ecs/entity.zig`). Only unique *within* a region.
- **Gateway session id namespace**: the gateway assigns the net-ids the client
  actually sees. It keeps, per pinned client, a translation table
  `client_net_id ↔ (region, region_net_id)`. This table is small because the
  view is small (a few hundred entities max). It is a natural extension of the
  per-client `known_entities` bitset that already exists
  (`ecs/interest.zig`, STATUS "Entity spawn-on-approach").

Handoff steps (source A → dest B), coordinated by the gateway that has the
entity in view (for a player, its own pinned gateway; for AI, the region owner
tells the relevant gateways):

1. **Enter drain zone.** Each region cell range has a border apron (one
   interest radius wide, ~400m). When an entity enters A's apron toward B, A
   marks it `migrating` and stops accepting new authoritative mutations for it
   from clients (C2S for that entity is buffered, not applied).
2. **Snapshot.** A serializes the entity's component blob: transform, health,
   AI/journal/inventory/wallet SoA rows (`ecs/world.zig` columns), plus any
   owned TE references. Reuse the persistence encoders (player v2, `.zch2`
   style) rather than a second format.
3. **Transfer + spawn.** B deserializes into a free slot, assigns a fresh
   region-local `NetId`, replays A's buffered C2S, and becomes authoritative.
4. **Remap, not respawn.** The gateway swaps the translation entry
   `(A, id_A) → (B, id_B)` for the *same* `client_net_id`. To every client in
   view, the entity's client-facing id is unchanged: no EntityRemove +
   EntitySpawn churn, just continued transform updates from a new backing
   region. For a **player**, the gateway additionally re-points which region it
   subscribes to for that client's window.
5. **Retire.** A destroys its slot after B acks authority. A short overlap
   window (both regions know the entity, only B mutates) keeps updates flowing
   during the swap.

Consistency: authority is single-writer at all times (A until the ack, then B).
The drain-buffer of C2S plus the single overlap window means no lost or
double-applied client input. If B rejects (full, error), A resumes authority
and the entity bounces off the seam. This is why boundaries are static and
aproned: a predictable seam is debuggable, a floating one is not.


### 3. Interest management at scale

Interest is a **subscription over state**, never message routing (Improbable
v1 failed because it could not retrofit query-based interest,
Part 1, 3-0). The existing pieces are already the right shape:

- **Grid interest** (`ecs/interest.zig`): 32m cells, `inRange` cell-radius
  test, `observerMask` (one bit per client slot). This becomes the region's
  "who observes what" index.
- **Per-client `known_entities` bitset** (STATUS): the client's subscription
  set. Diffed each tick → spawn-on-approach, despawn-on-leave.
- **Dirty flags** (`ecs/world.zig` `dirty` column): only changed entities
  serialize.

Scale rules to add:

- **Serialize-once shared buffers.** Encode each dirty entity delta *one time*
  per tick into a shared body buffer, then fan the same bytes to every
  subscribed client (AGENTS rule 8/17: SoA + serialize-once interest). At 1000
  clients this is the difference between 1 and 1000 encodes per entity.
- **Per-client byte budget.** Each client has a downstream budget per tick
  (already partly present: tiered `WindowFull` soft-drop of streaming packages
  vs retry of critical ones, STATUS "LiteNet WindowFull"). Under pressure,
  drop/decimate distant entity updates and chunk stream before critical join
  and state packages.
- **LOD on the sim side too.** Zombie AI already throttles decision rate by
  distance (full/mid/far `1.0/0.3/0.1`, `docs/ECS_SYSTEMS.md`). Extend the same
  tiers to replication cadence: near entities every tick, mid every few, far
  event-only.

Back-of-envelope: a client sees at most a few hundred entities in a 400m
window. A transform delta is ~20..40 bytes. Say 150 entities * 30 bytes * 20
TPS ≈ 90 KB/s downstream per client for entities, plus chunk stream on
movement. 1000 clients ≈ 90 MB/s aggregate entity replication across the
gateway tier (estimate, budget to benchmark), which is why serialize-once and
per-client budgets are mandatory, not optional.

Prior art the plan leans on (all in Part 1's verified table or
below; external claims cited):

- **SpatialOS/Improbable**: static assignment > dynamic entity LB;
  subscription-view interest, not routing. (Improbable runtime-rebuild
  retrospective, 3-0.)
- **EVE Online single-shard time dilation**: when one node's load spikes, EVE
  slows the simulation clock (TiDi) rather than dropping players or sharding
  live (CCP dev blogs on Time Dilation). Our equivalent: a saturated region can
  degrade tick rate locally (20→lower TPS) as a last resort before an emergency
  split, so a hot event bends instead of dropping. Estimate/design intent, not
  a shipped feature.
- **Star Citizen server meshing + replication layer**: separates the
  authoritative simulation (per-region servers) from a persistent replication
  layer that clients subscribe to and that survives server handoff (CIG server
  meshing dev communications). Our gateway tier plays the replication-layer
  role: it holds the client subscription and re-homes the backing region under
  it, mirroring that split.
- **Minecraft-scale attempts (Mammoth / WorldQL)**: demonstrated many players
  in one Minecraft world by sharding the world across servers behind a proxy
  and reconciling at boundaries (WorldQL/Mammoth public writeups). Confirms the
  proxy-plus-spatial-shard shape and that boundary reconciliation is the hard
  part, which is why handoff (section 2) gets a real protocol here.


### 4. Earth-scale terrain serving

The complementary terrain source is the procedural generator (see
[WORLDGEN.md](WORLDGEN.md)): DEM supplies the real macro heightfield where
Copernicus coverage exists, procedural noise supplies sub-30m detail, caves,
overhangs, and out-of-coverage/fictional regions. Both are pure functions of
`(seed, position)`, so both shard the same way.

**Never materialize the planet.** Voxels are a pure function of DEM + seed +
recorded edits, regenerated on demand. The math is decisive:

- Land ~149e12 m2. Full 1m voxelization over a 256-high band ≈ 3.8e16 blocks.
  At 1 byte/block naive that is ~38 PB. Even heightmaps-only at 1m (~2 bytes per
  16x16-averaged column is still 149e12/256 * ... ) is hundreds of TB. Infeasible
  to store or pre-generate. (Order-of-magnitude estimate.)
- The **source DEM** is already bounded and already hosted: Copernicus GLO-30,
  1x1 degree COGs in `copernicus-dem-30m` (eu-central-1), free and anonymous
  (Part 1 verified table, 3-0). At 30m sampling the whole planet is
  ~900x fewer samples than 1m. The full bucket is order **a few hundred GB to
  ~1 TB** compressed (estimate; `tileList.txt` in-bucket / bucket size is
  authoritative, do not assume). We pay nothing to store it: it lives in AWS
  Open Data.

So the terrain store is: (a) the DEM in S3 (read-only, free), plus (b) only the
chunks players actually edited (a small delta). Everything else is a cache.

### Pipeline (built on the real component)

`src/world/dem.zig` already does the hard part, proven live to Mont Blanc
4365m: range-read the first 64KiB COG header (`parseCogHeader`), read exactly
the one 1024x1024 inner tile covering a request (`innerTile`), DEFLATE +
float-predictor-3 decode (`decodeTile`, `undoFloatPredictorRow`), bilinear map
world XZ meters → 30m grid, clamp elevation to the 0..255 band
(`elevToBlockY`: sea 60, 12m/block). It already has a disk-cached header path.

The plan wires this behind the existing `--map` / DTM seam
(`world/dtm.zig`, STATUS "World / terrain"), so a region streams heightmap
chunks for its cells with zero pre-generation, then the existing column filler
(`world/store.zig` "full columns lazy dirt/stone/bedrock") turns heights into
voxels and the stock chunk encoder (`wire/stock_chunk.zig`) ships them.

### World-height cap (server serves tall, stock client clamps)

The stock client caps the vertical world at **Y=256** (64 layers x 4 blocks per
layer). Real elevations exceed that: Mont Blanc 4365m, Everest ~8849m. zdtd can
already *serve* tall columns: `dem.elevToBlockY` today rescales elevation into
the 0..255 band (sea 60, 12m/block) precisely because the stock client cannot
render higher. The 12m/block compression is a workaround for a **client-side**
rendering limit, not a server limit. The server can emit true 1m columns the
moment a client can receive them.

Lifting the cap is an **opt-in client mod**, kept strictly outside the
stock-client-wire-only core (AGENTS.md clean-room policy: zdtd ships no client
mod for the base loop). The sister project **RealEarth** at `../7dtd-realearth`
(v0.2.1) is the existing MVP:

- `tools/engine_patcher/Program.cs` uses **Mono.Cecil** to patch
  `Assembly-CSharp.dll`, expanding vertical `YDim` past 256 (default target
  16384 = 2^14, override 512..16384 for lighter machines; `LayerHeight = 4`, so
  layers = YDim/4).
- **Critical subtlety it documents and honors:** stock reuses `256` for *both*
  `ChunkBlockYDim` (vertical) *and* `ChunkAreaDim` (the 16x16 XZ heightmap /
  biome / normal maps). A blind `256 -> N` rewrite corrupts XZ indexing and
  packing strides and makes chunk load ~64x slower. The patcher only rewrites
  *true vertical / layer* sites: types that allocate 64-layer vertical arrays
  (`Chunk`, `ChunkBlockLayer`, `UnsafeChunkData` and kin) and `ldc 256/255`
  operands that are vertical bounds inside `ResetStability`,
  `GetTerrainHeightAt`, `GenerateTerrain`, etc. Alloc and free layer counts must
  move together or `Unity.Collections` `Free` crashes.
- It is a **Harmony + Mono.Cecil client-side patch** and requires
  `Mods/0_TFP_Harmony/` (vanilla). Steam verify restores the stock DLL.

Design stance for zdtd: **the server side is cap-agnostic.** With tall clients
present, replace the 12m/block compression path in `elevToBlockY` with a true
1m mapping into the expanded band; with stock clients, keep the clamp. Same DEM
pipeline, one branch on the negotiated client height. Tall terrain is therefore
a *rendering* dependency on the optional mod, never a server rewrite, and the
world-size axis does not block on it: stock clients get a playable clamped
Earth today, YDim-expanded clients get true elevation.

### Tiling

Use the DEM's own 1-degree COG tiling as the coarse index and its 16 inner
1024px tiles (`tiles_per_side = 4`, `dem.zig:16`) as the fetch unit. A quadtree
/ S2 / H3 overlay is only needed for LOD and cell-to-region assignment (section
1); the fetch granularity is fixed by the COG layout and is already correct.

### Cache hierarchy

Three tiers, matching the persistence tiering below:

| Tier | Holds | Bound | Exists |
|---|---|---|---|
| RAM | decoded voxel chunks (hot) | `max_resident_chunks = 4096`/shard, LRU | yes (`store.zig`) |
| RAM | decoded DEM inner tiles (4 MB each, 1024x1024 f32) | small LRU per region | header cache exists; extend to tiles |
| Local disk | COG headers, decoded tiles, edited `.zch2` chunks | region-local dir, never tmpfs | header path exists (`tileHeader`) |
| Object store | full DEM (S3, read-only) + cold edited chunks | unbounded, external | DEM live; edited-chunk cold tier is new |

A decoded inner tile is 1024*1024*4 = **4 MB**. A full degree tile fully
resident is 16 tiles ≈ 64 MB, but we only ever hold touched inner tiles. A
region covering a handful of degree cells with clustered players holds tens of
MB of DEM plus its 4096-chunk voxel LRU. This fits a commodity node with room
to spare.


### 5. Persistence tiering

Voxels are derived, so persistence stores only *state that is not a function of
the DEM*: player profiles and edited chunks / TE / block meta.

| Tier | Content | Backing | Today |
|---|---|---|---|
| Hot | live `ecs.World` SoA, resident chunks | region RAM | `ecs/world.zig`, `store.zig` |
| Warm | edited `.zch2` chunks, containers `.zct`, block meta `.zbm`, players `.zsv` v2 | region-local disk | all exist (STATUS "TE/block persist", "Player persist v2") |
| Cold | edited chunks + player profiles for cells no region currently owns | object store (S3-compatible) | new |

Cross-shard moves of persisted data:

- **Player profile**: keyed by stable account id, not region. On handoff the
  player's `.zsv` record travels with the entity snapshot (section 2 step 2) or
  is re-loaded by dest region from the cold tier keyed by account. The gateway
  pin means the client never re-authenticates.
- **Edited chunks**: keyed by global chunk coord (cell + local), not by region.
  When a region's cell range changes (split/merge/reassignment), ownership of
  those keys moves; the warm files move or are re-fetched from cold. Because
  the key is global and the DEM is the base layer, a chunk with no recorded
  edit needs no storage at all: regenerate from DEM.
- **Catalog vs state** stays as Part 1 already specifies: XML is the
  source of truth for definitions, instances reference catalog by name/hash +
  config fingerprint, numeric ids are per-version projections rebuilt at boot.


### 6. Substrate options, kept honest

| Option | Verdict | Why |
|---|---|---|
| **Single big server** (io_uring, thread-per-core, 128-core box) | **Near-term target** | Thread-per-core shared-nothing wins single-node tails (Iggy -81% P9999, ScyllaDB/Seastar precedent; single-source, benchmark ours). We already have `util/parallel.zig` range-split workers and a tick-owned store. One fat node runs many regions as pinned threads before any network sharding. |
| **Actor systems** (Erlang/OTP, Orleans grains) | **Scale-out for backend only** | Virtual actors linear-scale for presence/leaderboards/matchmaking (Halo 4), but cross-actor RPC ~6.5..15ms and single-activation is only eventual under churn. Never on the 50ms authoritative tick. Allowed for the persistence/meta tier, as Part 1 already scopes. |
| **Distributed ECS** | **Watch, do not adopt yet** | A distributed-entity ECS (Bevy-style relations across nodes, or a bespoke one) is the theoretical fit for 10k entities across shards, but it reintroduces the cross-node-per-tick RPC cost the actor row rules out. Our handoff-at-static-seam design gets the same result without per-tick cross-node reads. |
| **SpacetimeDB** | **Rejected as substrate** | Full analysis in Part 1: no path to LiteNet clients (WebSocket-only), transaction-per-tick vs in-place SoA hot loop, single-node RAM ceiling (BitCraft shards *above* it), BSL one-instance cap. Bounded sane use: one out-of-band instance for meta/ops, never the authoritative 20Hz sim. |

The through-line: **keep the authoritative sim as in-process SoA on one core
per region; make every cross-node interaction a rare control-plane or
apron-handoff event, never a per-tick RPC.** That is the single principle every
row above agrees on.


### 7. Staged migration path

Each stage is independently shippable and testable with the existing evidence
loop (loadgen bots + a live stock client + `src/apm` dumps, AGENTS "Validation").

Each milestone is tagged by axis: **[T]** world-size/terrain, **[P]**
player+entity count, **[T+P]** both.

- **M1. DEM streamer** *(done)* **[T]** `world/dem.zig`: GLO-30 COG range-read →
  decode → heightmap. Proven live to Mont Blanc 4365m. Unit tests green.
- **M2. DEM-fed terrain at continental scale, single node.** **[T]** Wire
  `dem.zig` behind the `--map`/DTM seam so a real anchor lat/lon streams voxel
  chunks on demand through the existing column filler + `stock_chunk.zig`. Add
  the DEM inner-tile RAM LRU (header cache already exists). Ships with the
  stock **Y=255 clamp** (`elevToBlockY`). Gate: a stock client walks from sea
  level up a real mountain, chunks stream, `apm` shows bounded resident chunks
  and no tick stall.
  - **M2a. Tall terrain (optional, client-mod dependency).** **[T]** Add a true
    1m elevation branch in the DEM mapping, gated on a client that ran the
    RealEarth `engine_patcher` YDim expand (`../7dtd-realearth`, section 4).
    Depends on the opt-in client mod; stock clients keep the M2 clamp. Gate:
    a YDim-expanded client renders Mont Blanc at true height; a stock client
    on the same server still joins with the clamped band.
- **M3. Gateway split.** **[P]** Move LiteNet termination + interest +
  `known_entities` into a separate Zig process; sim keeps a local
  UDS/shared-mem link. Introduce the gateway net-id translation table against a
  *single* region (no sharding yet). Gate: stock client + loadgen bots play
  through the split with zero wire regressions; the id-translation seam is
  proven before it carries a boundary.
- **M4. Read-only shard split.** **[T+P]** Two region processes own disjoint
  cell ranges; gateway subscribes to both and fans in. Entities do not cross
  yet. A client standing near the seam sees entities from both regions
  correctly through one socket. Gate: loadgen bots on each side, one stock
  client at the seam, no duplicate or missing entities.
- **M5. Live handoff.** **[P]** Implement section 2: apron drain, snapshot,
  transfer, remap, retire, overlap window. Gate: loadgen bots walk back and
  forth across the boundary while a stock client watches; net-ids stay stable
  client-side, no EntitySpawn/Remove churn, C2S never lost or doubled.
- **M6. Thread-per-core + N regions + multi-gateway.** **[P]** Pin regions to
  cores via `util/parallel.zig`, run many regions per node, then many nodes;
  add a second gateway. Static region map file. Gate: 1000+ loadgen bots + real
  clients across N regions and 2 gateways, `apm` P99 tick under 50ms per region.
- **M7. Dynamic split/merge + cold tier.** **[T+P]** Control-plane coordinator
  splits a saturated region's cell range and reassigns; edited chunks + player
  profiles page to the object-store cold tier and back on ownership change.
  EVE-style local TPS degradation as the pre-split safety valve. Gate: drive a
  hot spot until it auto-splits with no client disconnects.


### Reuse vs build

| Reuse as-is | Build |
|---|---|
| `wire/` stock encoders, LiteNet stack, join SM | DEM → voxel wiring behind `--map` (M2) |
| SoA ECS + systems, per-region sim unchanged | gateway process + net-id translation (M3) |
| `ecs/interest.zig` + `known_entities` (become gateway subscription) | static region map + cell→region assignment |
| persistence formats `.zch2`/`.zct`/`.zbm`/`.zsv` (per-region) | handoff protocol: apron, snapshot, remap (M5) |
| `world/dem.zig` streamer + disk header cache | DEM inner-tile LRU + edited-chunk cold tier |
| RealEarth `engine_patcher` YDim expand (`../7dtd-realearth`, opt-in client mod) | true-1m DEM branch gated on client height (M2a) |
| `util/parallel.zig` range-split workers | control-plane split/merge coordinator (M7) |
