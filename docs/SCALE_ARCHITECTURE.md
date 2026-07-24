# Scale architecture: Earth-size world, 1000 players, 10k AI

**Date:** 2026-07-22. Research verified via adversarial deep-research pass
(104 agents, 3-vote refutation per claim; sources cited inline).

> **This doc is the substrate analysis and verified research.** For the
> concrete positive build plan (shard topology, handoff protocol, interest at
> scale, terrain serving, persistence tiering, staged milestones M1..M7) see
> **[PLANET_SCALE.md](PLANET_SCALE.md)**. SpacetimeDB below is one rejected
> substrate option among that analysis, not the whole story.

## Goals

- 1:1 Earth voxel world (~510M km²) streamed from real DEM data
- ~1000 concurrent players, ~10000 active AI entities
- Stock, unmodified 7DTD clients (LiteNet UDP + TFP package wire)

## Substrate option A (rejected): SpacetimeDB as the sim substrate

One candidate substrate, evaluated and rejected. The positive plan
([PLANET_SCALE.md](PLANET_SCALE.md)) uses in-process SoA regions instead; the
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

## Verified design lessons

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

## Target topology

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

## XML catalog vs dynamic state (applies to any store)

- XML stays source of truth for definitions; clients derive ids from the same
  XML (AssignIds), so the DB can never diverge from it.
- Store instances reference catalog by **name** (or name-hash) + a config
  fingerprint (sha256 of canonical XML set). Numeric ids are per-version
  projections, rebuilt at boot in one transaction.
- Config change ⇒ world restart with a migration pass; live XML reload is a
  non-goal (clients load config once at connect).

## Staged path (each stage independently shippable)

1. **DEM streamer** (`world/dem.zig`): GLO-30 COG range-read → heightmap
   chunks behind the existing `--map` seam (`dtm.zig` interface). Earth
   terrain in today's single process. Storage math: only touched tiles cached;
   RAM→disk LRU already exists (`max_resident_chunks`).
2. **Gateway split:** move LiteNet termination + interest into its own Zig
   process; sim keeps a local IPC/UDS link. Protocol seam proven before any
   sharding.
3. **Two static shards** + handoff + id remap; gate = loadgen bots walking the
   boundary while a stock client watches.
4. **Thread-per-core shards** (`util/parallel.zig` → pinned workers), then N
   shards, then multi-gateway.

## Reuse vs build

| Reuse (all of it) | Build |
|---|---|
| `wire/` stock encoders, LiteNet stack, join SM | DEM streamer + voxelizer |
| SoA ECS + systems (per-shard sim unchanged) | gateway process + IPC |
| interest/known_entities (becomes gateway view) | handoff + id-remap protocol |
| persistence formats (per-shard) | shard directory/config, boundary defs |
