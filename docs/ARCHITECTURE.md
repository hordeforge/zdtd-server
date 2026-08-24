# Architecture — zdtd

> **What this is:** the map of how the Zig dedicated server is built, how it runs at 20 TPS, and how the pieces fit together. For the canonical RE behind the wire see [protocol.md](../../7dtd-engine-research/docs/protocol.md) and for the founding design [ZIG_CLONE.md](ZIG_CLONE.md). For what actually works today see [STATUS.md](STATUS.md).

> **How to read it:** start at the overview, then follow the runtime loop (tick), then the three planes that ride it — net, sim, and storage — plus the plugin and observability planes that cross-cut them. Every major section has a Mermaid diagram. When a diagram and code disagree, code wins.

**Contents**

- [1. System overview](#1-system-overview)
- [2. Source layout and dependency edges](#2-source-layout-and-dependency-edges)
- [3. Process lifecycle and the 50 ms tick](#3-process-lifecycle-and-the-50-ms-tick)
- [4. Net stack: LiteNet, framing, packages](#4-net-stack-litenet-framing-packages)
- [5. Join flow](#5-join-flow)
- [6. ECS simulation and schedule](#6-ecs-simulation-and-schedule)
- [7. World and chunks](#7-world-and-chunks)
- [8. Interest and replication: serialize-once](#8-interest-and-replication-serialize-once)
- [9. Plugin host: Wasm guests](#9-plugin-host-wasm-guests)
- [10. Config, assets, and persistence](#10-config-assets-and-persistence)
- [11. Observability: APM](#11-observability-apm)
- [12. Invariants](#12-invariants)

---

## 1. System overview

zdtd is a **single-process, single-authority, fixed-step** dedicated server. Stock Unity clients (EAC off, V3.1.0 b14) join over LiteNetLib; the server owns blocks, inventory, HP, quests, time, and every byte it sends. There is no Mono, no GC pause, and no `Mods/` code loading — behavioral extension is Wasm plugins over a typed host boundary.

The three planes are deliberately split even though the tick thread is single-owner for game rules:

- **Net plane** accepts, decodes, and fans out bytes.
- **Sim plane** steps the SoA ECS deterministically at 20 Hz.
- **Store plane** persists chunks, player files, and tile entities off the hot path.

Plugins and APM are cross-cutting: plugins observe or veto at narrow hooks, APM measures every hot section.

```mermaid
flowchart TB
    subgraph clients["Stock clients (EAC off)"]
        C1[Client]
        C2[Loadgen bot]
    end

    subgraph zdtd["zdtd process — single authority"]
        direction TB
        LN[LiteNet UDP<br/>litenet/udp_socket.zig<br/>litenet/server.zig]
        WIRE[Wire framing<br/>wire/frame.zig<br/>wire/packages.zig]
        GATE[Phase gate<br/>server/phase_gate.zig]
        GAME[Game<br/>server/game.zig<br/>façade — owns tick, clients, world]

        subgraph tick["Tick thread — 50 ms budget"]
            POLL[net poll]
            SIM[ECS sim<br/>ecs/schedule.zig]
            REPL[replicate + interest<br/>server/game/replicate.zig]
            STREAM[chunk stream<br/>server/game/chunk_stream.zig]
        end

        ECS[SoA World<br/>ecs/world.zig<br/>components, groups, commands]
        WORLD[World store<br/>world/store.zig<br/>chunks, TTS, prefabs, DTM]
        PLUG[Plugin hosts<br/>plugin/host.zig + plugin/wasm.zig<br/>zwasm v2]
        APM[APM<br/>apm/metrics + profiler]
        PERSIST[Persistence<br/>server/persist.zig<br/>.zch / .ttp / .zbf / .zwt]
    end

    C1 <--> LN
    C2 <--> LN
    LN --> WIRE --> GATE --> GAME
    GAME --> tick
    tick --> ECS
    ECS <--> WORLD
    GAME <--> PLUG
    tick --> APM
    WORLD --> PERSIST
    GAME --> PERSIST

    classDef plane fill:#1a2a44,stroke:#5b8def,color:#dbe6ff
    classDef store fill:#25361f,stroke:#6fbf6a,color:#dff5dc
    classDef cross fill:#3a2a1a,stroke:#d9a441,color:#fff2cc
    class LN,WIRE,GATE,GAME,ECS plane
    class WORLD,PERSIST store
    class PLUG,APM cross
```

**Key files by plane**

| Plane | Owns | Hot path budget |
|---|---|---|
| Net | `src/litenet/*`, `src/wire/*`, `src/server/phase_gate.zig`, `src/server/c2s/*` | `net_poll` ≤ 5 ms |
| Sim | `src/ecs/*`, `src/server/game/tick.zig`, `src/server/game/step.zig` | `sim_entities` ≤ 30 ms |
| Store | `src/world/*`, `src/server/persist.zig`, `src/server/game/chunk_fill.zig` | async where possible |
| Plugin | `src/plugin/*`, `src/server/game/hooks.zig` | `plugin` section, fuel capped |
| APM | `src/apm/*`, `src/server/game/harness.zig` | always on for listed sections |

---

## 2. Source layout and dependency edges

The layout mirrors the dependency rule enforced by `scripts/lint-architecture.sh`. The rule is simple: **leaf packages never import application or domain layers**, and `world` never imports `wire` (tile-entity domain types live in `world`, wire re-exports them).

```
src/
  main.zig              CLI, allocator, Game construction, run loop
  protocol.zig          tick rate + challenge constants
  version.zig           product + stock wire version
  apm/                  native counters + section profiler + reports
  assets/               stock XML tables (blocks/items/quests/biomes/…)
  ecs/                  SoA World, components, systems, schedule, groups
  world/                chunk store, TTS, prefabs, DTM, sleepers, weather, deco
  wire/                 framing + stock package bodies (one builder per shape)
  litenet/              LiteNet framing, peers, UDP socket (std.Io.net)
  server/               Game façade + c2s handlers + persistence + webui + admin
    c2s/                C2S handlers by domain (join/move/blocks/inv/quest/misc)
    game/               per-domain Game helpers (tick/step/replicate/chunk_stream/…)
  plugin/               Wasm host, hook table, budgets, manifests
  util/                 parallel, toml_bind, io_fs, clock, log, sim
```

Facades: import `*/root.zig` per package and `wire/packages.zig` for stock bodies. Leaf files stay importable. Every `src/*/root.zig` re-exports its package files so `zig build test` aggregates them.

```mermaid
flowchart LR
    subgraph leaf["Leaf / infra — never import app/domain"]
        UTIL[util]
        APM2[apm]
        LN2[litenet]
        PLUG2[plugin]
    end
    subgraph domain["Domain / encoding"]
        ASSETS[assets]
        ECS[ecs]
        WORLD[world]
        WIRE[wire]
    end
    subgraph app["Application"]
        SERVER[server]
        MAIN[main]
    end

    MAIN --> SERVER
    MAIN --> WIRE
    MAIN --> WORLD
    MAIN --> ECS
    SERVER --> ECS
    SERVER --> WORLD
    SERVER --> WIRE
    SERVER --> APM2
    SERVER --> UTIL
    SERVER -.-> PLUG2
    WIRE --> UTIL
    WORLD --> UTIL
    ECS --> UTIL
    ASSETS --> UTIL
    WORLD -.-> ASSETS

    classDef forbidden stroke-dasharray: 6 4,stroke:#c0392b
    UTIL -.-> SERVER
    APM2 -.-> SERVER
    LN2 -.-> SERVER
    PLUG2 -.-> SERVER
    ECS -.-> ASSETS
    WORLD -.-> WIRE

    class UTIL,APM2,LN2,PLUG2 forbidden
```

**Enforced forbidden edges** (`lint-architecture.sh`):

- `util` → `server|wire|world|ecs|assets|litenet|apm`
- `apm` → `server|wire|world|ecs|assets|litenet`
- `litenet` → `server|world|ecs|assets|apm`
- `plugin` → `server|wire|world|ecs|assets|litenet|apm`
- `assets` → `server|wire|world|litenet|apm` (ecs shapes ok)
- `ecs` → `server|wire|world|assets|litenet|apm`
- `world` → `server|wire|litenet|apm`
- `wire` → `server|litenet|apm`

`server/game.zig` is the **delegating façade** — it owns `Game` and fans out to `server/game/*.zig` and `server/c2s/*.zig` helpers that each take `*Game`. Wire bodies live in `wire/stock_*.zig` behind `wire/packages.zig`.

---

## 3. Process lifecycle and the 50 ms tick

`src/main.zig` parses CLI + env + `zdtd.toml` + mode pack into `server/config.zig` and `ecs/rules.zig`, constructs `Game`, and runs the fixed-step loop. The loop is **effectively single-threaded for game rules**; parallelism lives inside a phase via `util/parallel`.

```mermaid
stateDiagram-v2
    [*] --> ParseArgs: main()
    ParseArgs --> LoadConfig: config.zig + toml_bind + mode pack
    LoadConfig --> InitAssets: init_assets.zig — XML tables, biomes, buffs
    InitAssets --> InitWorld: init_world.zig — store, TTS, prefabs, DTM
    InitWorld --> Listen: litenet/server.zig — bind UDP, LiteNet accept
    Listen --> TickLoop: running
    TickLoop --> TickLoop: step() every 50 ms — 20 TPS
    TickLoop --> SaveAndExit: --ticks / --once / signal
    SaveAndExit --> [*]: persist + deinit

    note right of TickLoop
      tick_total section
      50 ms hard budget
      virtual clock in --once
    end note
```

One iteration of the loop (`src/server/game/step.zig:step`) — the hot path that must not allocate:

```mermaid
flowchart TB
    START([step — tick_n++]) --> POLL

    subgraph poll["net_poll — ≤ 64 events"]
        POLL[poll LiteNet + recv_buf]
        POLL --> REAP[reapStalePeers + reapPolicyKicks]
        REAP --> ADMIN[poll admin TCP + webui + mcp]
    end

    ADMIN --> SNAP{terrain snapshot?}
    SNAP -- on --> TERR[terrain_snap rebuild]
    SNAP -- off --> DIR
    TERR --> DIR

    subgraph sim["sim_entities — schedule.run + Game extras"]
        DIR[systemDirector — clock + blood moon + restocks]
        DIR --> AI[systemZombieAi + systemDigUpdate<br/>parallel over slots]
        AI --> VEH[systemVehicles]
        VEH --> TUR[systemTurrets — parallel]
        TUR --> DESP[systemDespawnFar]
        DESP --> CMD[drainCommands — spawn/despawn/damage  cap 64]
        CMD --> WATER[world.levelWaterTick — budgeted fills]
        WATER --> FALL[systemFallingBlocks — gravity + landing]
        FALL --> EXPL[drainExplosions — EntityZombieCop AoE]
        EXPL --> DIG[drainDigRequests — MoveHelper]
        DIG --> WAKE[drainSleeperWakeups + tickEntityLookAt]
        WAKE --> MAPS[tickMapChunks + tickPlayerPositions + tickClientInfo]
        MAPS --> SURV[tickSurvival + tickBots + loot bags + claims + blood-moon music]
    end

    SURV --> SLEEP[periodic — every sleeper_tick_ticks:<br/>tickSleeperVolumes, tickWorkstations, tickBlockRadiusEffects]
    SLEEP --> POWER[power.tick<br/>replicate_te.broadcastPowerVisuals]
    POWER --> CORPSE[sweepCorpses — EntityRemove + loot spawns]
    CORPSE --> WORLD_TICK{world_time tick?}
    WORLD_TICK -- yes --> WT[WorldTime + weather.tick + weather broadcast<br/>blood-moon music per player]
    WORLD_TICK -- no --> VEH_POS
    WT --> VEH_POS[broadcastVehiclePositions<br/>broadcastTurretSync<br/>plugins onTick + withdraw trap queue]
    VEH_POS --> REWARDS[drain completed_quests ring — plugin verdict then give/loot/exp/quest]
    REWARDS --> REPLICATE[replicate — interest + encode + fan-out]
    REPLICATE --> SAVE{save interval?}
    SAVE -- yes --> IO[saveAll + containers + vending + claims + allies + weather + clock]
    SAVE -- no --> APM
    IO --> APM[sampleFlushCounters — per apm_report_period_ticks: JSON line to stdout]
    APM --> DONE([tracy.frameMark + virtual clock advance])

    classDef hot fill:#1a3a5c,stroke:#5b8def,color:#dbe6ff
    class POLL,DIR,AI,TUR,REPLICATE hot
```

**No-heap invariant:** tick, per-packet C2S/S2C, interest/replicate, chunk stream, and ECS systems must not `alloc`/`create`/`dupe`/`allocPrint` or grow `ArrayList`/`HashMap`. They reuse `recv_buf`/`send_buf`/`body_buf`, fixed client slots, SoA columns, pools, and stack `bufPrint`. At cap: drop or omit, never realloc.

---

## 4. Net stack: LiteNet, framing, packages

Stock clients never speak raw TCP for gameplay. Everything rides **LiteNetLib reliable ordered (delivery 2)** over a single UDP socket (`src/litenet/udp_socket.zig` via `std.Io.net`). The address the operator passes as `--port` is the TCP info port; **LiteNet is `port + 2`** — that is why loadgen uses `zdtd_port + 2`.

### 4.1 Framing

Every datagram the client `Read`s is one LiteNet payload that contains one or more packages:

```mermaid
flowchart LR
    subgraph udp["UDP datagram — LiteNet reliable ordered ch=0"]
        direction TB
        H1["LiteNet header<br/>delivery 2, channel 0"]
        ENV["payloadSize i32 + compressed u8 + encrypted u8 + pkgCount u16"]
        subgraph pkgs["pkgCount ×"]
            P["contentLen i32<br/>(pkgId u16 + body)<br/>pkgId u16 — negotiated<br/>body … stock BinaryWriter LE"]
        end
        H1 --> ENV --> pkgs
    end
    CHAL["Pre-auth 17 bytes<br/>0xCA + Guid16 — echoed back"]
    CHAL -. challenge .-> udp
```

Details in `src/wire/frame.zig` (framing helpers) and `src/litenet/*` (peers, window, reaps). Reliable-window retry pumps ACKs for the fast window before pacing at 1 ms so a dead peer is reclaimed by the stale sweep instead of wedging the tick (`src/server/game/net.zig:sendReliablePumped`).

### 4.2 Packages

Package ids are **negotiated at join**, not fixed. The server advertises an ordered name list as `NetPackagePackageIds` (`src/wire/packages.zig:default_mappings`); the client maps name to `u16`. Every stock shape has **one builder** in `src/wire/stock_*.zig` writing into a caller buffer (`buildXxxBody(buf, …) ![]u8`) using `src/wire/binary.zig` (LE ints, 7-bit string lengths). The facade `src/wire/packages.zig` re-exports all of them.

```mermaid
flowchart LR
    subgraph catalog["Package catalog — dynamic ids"]
        NAMES["ordered type names<br/>default_mappings<br/>≈ 190 types, live capture 189"]
        MAP["peer PackageIds<br/>name → u16"]
        NAMES --> MAP
    end
    subgraph hot["Hot bodies — builder into caller buf"]
        POS["EntityPosAndRot — 30 B"]
        REL["EntityRelPosAndRot — 20 B<br/>rot deg/360×256, dPos i16"]
        FLAG["EntityAliveFlags — 6 B"]
        DMG["DamageEntity — fixed layout"]
        CHUNK["Chunk — stock write order"]
        OTHER["… 190 total"]
    end
    MAP --> hot

    classDef single fill:#25361f,stroke:#6fbf6a,color:#dff5dc
    class POS,REL,FLAG,DMG,CHUNK single
```

One shape → one builder (AGENTS rule 14). If a body cannot be built correctly (missing catalog entry, buffer too small, unknown TE) the sender **omits** or sends the stock empty form — never truncates mid-field.

---

## 5. Join flow

A stock client (or loadgen bot) walks a phase-gated session. `Client.joined`/`Client.entered` map to `server/phase_gate.zig:Phase` (`connecting → joined → playing`); the gate drops C2S packages that are not legal for the current phase. The UDP challenge echo races the first payload, which is buffered and replayed after auth (`Client.preauth_buf`).

```mermaid
sequenceDiagram
    participant Client as Stock client
    participant LiteNet as LiteNet UDP
    participant Game as Game join SM<br/>server/c2s/join.zig
    participant Gate as Phase gate<br/>server/phase_gate.zig
    participant World as World + ECS

    Client->>LiteNet: Connect
    LiteNet->>Game: onConnected — peer slot
    Game->>Client: ServerChallenge — 17 B 0xCA+Guid16
    Client->>Game: echo challenge + NetPackagePackageIds
    Game->>Game: store peer PackageIds map
    Client->>Game: NetPackagePlayerLogin — name, versions, auth
    Gate->>Gate: phaseOf = connecting — only login legal
    Game->>Client: NetPackagePlayerLoginAnswer
    Game->>Client: NetPackagePlayerId bundle — id map, chunks, Spawned, time, stats
    Client->>Game: NetPackageRequestToEnterGame
    Gate->>Gate: joined → entering
    Game->>Client: NetPackageWorldInfo — once, never in spawn bundle
    Game->>Client: configs + areas + stats
    Client->>Game: NetPackageWorldInitInfoRequest
    Game->>Game: world_ready — start chunk streamer
    Client->>Game: NetPackageRequestToSpawnPlayer — chunkViewDim + PlayerProfile v5
    Gate->>Gate: entering → spawning
    Game->>World: spawnBase or reviveSlot — SoA alloc, NetId, Journal
    Game->>Client: NetPackageEntitySpawn + NetPackageWorldTime + PlayerDataFile
    Gate->>Gate: spawning → playing
    loop every tick — net poll + sim + replicate
        Client->>Game: RelPos / PosAndRot / SetBlock / InvTx …
        Gate->>Gate: allow only playing-legal C2S — else drop/disconnect
        Game->>World: validate → apply → broadcast result — never blind-apply
    end
    Client->>Game: disconnect / stale reap — dropClientSlot
```

State view (same machine, compact):

```mermaid
stateDiagram-v2
    [*] --> Connecting: LiteNet Connect
    Connecting --> Challenged: challenge sent
    Challenged --> Joined: echo + PackageIds + PlayerLogin
    Joined --> Entering: RequestToEnterGame
    Entering --> Spawning: RequestToSpawnPlayer
    Spawning --> Playing: PlayerId bundle + Spawned
    Playing --> Playing: movement + C2S + replicate
    Playing --> Spawning: death → RequestToSpawnPlayer — revive + Spawned(died)
    Joined --> Joined: re-login while joined — LoginAnswer + SpawnedInWorld
    Entering --> Spawning: DynamicClientArrive fallback
    Playing --> [*]: PlayerDisconnect / stale reap
    Entering --> [*]: illegal phase C2S — gate drop
```

Owners: `src/server/c2s/join.zig` (7-package SM), `src/server/c2s/dispatch.zig` (dispatch table), `src/server/game/join.zig` (sendJoinBundle, sets `Client.entered`), `src/server/phase_gate.zig` (allowed table). For all 20 state machines see [STATE_MACHINES.md](STATE_MACHINES.md).

---

## 6. ECS simulation and schedule

The sim is a **single SoA ECS** (`src/ecs/`). An entity is a dense `Slot` `0..511` plus a stable network `NetId` (i32). Components are parallel arrays gated by a `Mask`; resources are shared singletons on `World`. Systems are plain `fn(*World, …)` and tick via `schedule.run`.

```mermaid
flowchart TB
    subgraph world["World — ecs/world.zig"]
        direction TB
        SLOTS["slots 0..511<br/>alive: [512]bool<br/>alive_bits / dirty_bits — word-packed"]
        MASK["mask: player, zombie_ai, buffs, vehicle, turret, …"]
        COLS["SoA columns<br/>transform, health, network_id, kind, flags<br/>player, journal, wallet<br/>zombie_ai, buffs, vehicle, turret"]
        RES["resources<br/>catalog, power.PowerGrid, director.Director<br/>rules.Rules + locals.TickLocals"]
        GROUPS["group.zig — per-Kind dense lists<br/>7 × 512 × u16 = 7 KB, slot-ascending"]
        CMD["command.zig — fixed ring cap 64<br/>spawn / despawn / damage"]
        SLOTS --> MASK --> COLS
        RES -. shared .-> COLS
        GROUPS -. index .-> SLOTS
        CMD -. deferred .-> SLOTS
    end

    QUERY["query.zig<br/>forEachKind / forEachWith / forEachAlive<br/>forEachParallelKind via util/parallel"]
    QUERY --> world
```

### 6.1 Schedule

Document order is run order. A mode pack may **disable** a phase (`Rules.systems.<name>`) but never reorder one — the order encodes a real dependency (buffs before AI so movement and damage read this tick's buff state).

```mermaid
flowchart LR
    BEGIN([beginTick<br/>clear TickLocals<br/>clear dirty bits]) --> BUFFS
    BUFFS[buffs<br/>systemBuffs — 20 Hz<br/>stack + duration + expiry] --> DIR
    DIR[director<br/>systemDirector — clock<br/>blood moon + horde spawns] --> AI
    AI[ai<br/>systemZombieAi — parallel<br/>+ systemDigUpdate] --> VEH
    VEH[vehicles<br/>systemVehicles — driver stick] --> TUR
    TUR[turrets<br/>systemTurrets — parallel<br/>target + fire] --> DESP
    DESP[despawn<br/>systemDespawnFar — cull far zombies] --> CMDS
    CMDS[commands<br/>drainCommands — apply deferred ops<br/>from systems + plugins]

    classDef phase fill:#1a3a5c,stroke:#5b8def,color:#dbe6ff
    class BUFFS,DIR,AI,VEH,TUR,DESP,CMDS phase
```

Pinned in `src/ecs/schedule.zig:order`:

```
buffs → director → animals → ai → vehicles → turrets → despawn → commands
```

Power (`ecs/electric.zig:PowerGrid`) resolves once per tick in `Game.step` with real daylight, not inside `schedule.run` — a second resolve doubled the BFS and forced daylight at night. Turrets read last tick's resolve. Command-style systems (`questAccept*`, `questOn*`, `trade`, `vehicleAttach`) run on demand, not every tick.

### 6.2 Queries and groups

```zig
ecs.forEachKind(w, .zombie, ctx, f);
ecs.forEachWith(w, .{ .player = true, .inventory = true }, ctx, f);
for (ecs.groupSlice(w, .zombie)) |s| { ... }   // O(live), ascending
```

`World.kind_groups` is maintained only at `spawnBase`/`destroy`/`reviveSlot`; a slot never migrates between groups. Iteration that mutates the world snapshots via `copyKindInto`. The replicate pass walks `alive_bits`/`dirty_bits` word-packed sets, not kind groups, to keep slot order.

### 6.3 Threading

| Path | Mode | Safety |
|---|---|---|
| AI + turrets | `util/parallel` range-split | workers write only their own slots; HP via fixed-point atomics + serial apply |
| Chunk save | parallel when many dirty | `World.saveAll` batch |
| Net poll / replicate | single-threaded owner | serialize-once framed fan-out |
| Block store | tick-owned | not lock-free |

---

## 7. World and chunks

Chunks are the unit of terrain, storage, and streaming. Stock constants are fixed:

| Constant | Value | Where |
|---|---|---|
| Chunk XZ | 16 × 16 | `world/store.zig` |
| YDim | 256 | columns |
| Layer height | 4 | `y >> 2` |
| Layers | 64 | save loop |
| Region | 8 × 8 = 64 chunks | `RegionFileRaw` header 779 |
| File ext | `.ttc` (plus zdtd `.zch` overlay) | `world/store.zig` |

Block index: `layer = y >> 2`, `idx = x + z*16 + (y & 3)*256`.

### 7.1 Chunk lifecycle

```mermaid
flowchart TB
    REQ([player needs chunk<br/>view radius or streamer raster]) --> HIT{in RAM?}
    HIT -- yes --> ENC[encode stock wire order<br/>wire/stock_chunk.zig<br/>heightmap + density + blocks]
    HIT -- no --> LOAD{on disk?}
    LOAD -- yes --> DECODE[decode .ttc / .zch<br/>world/store.zig]
    LOAD -- no --> GEN[materialize — DTM + prefab stamp<br/>world/dtm.zig + world/prefabs.zig]
    DECODE --> FILL[chunk_fill — TTS deco,<br/>containers, workstations<br/>server/game/chunk_fill.zig]
    GEN --> FILL
    FILL --> ENC
    ENC --> SEND[NetPackageChunk — framed once<br/>sendReliablePumped to peer]

    EDIT[SetBlock / explosion / stability collapse] --> MUTATE[world.setBlock — mark dirty<br/>stability graph — falling blocks]
    MUTATE --> DIRTY[chunk dirty — queued for saveAll<br/>and for next streamer broadcast]

    SAVE_TICK{save interval?} -- yes --> FLUSH[saveAll — parallel encode<br/>background writer — chunk_flush_* counters]
    FLUSH --> DISK[(.zch / .ttp / .zbf)]

    classDef io fill:#25361f,stroke:#6fbf6a,color:#dff5dc
    class ENC,SEND,DECODE,FLUSH io
```

Storage details: `src/world/store.zig` (chunk columns, heightmap `byte[256]`, density bands), `src/world/tts.zig` (terrain texturing), `src/world/prefabs.zig` + `src/world/dtm.zig` (Navezgane / Pregen + procedural), `src/world/biomes.zig`, `src/world/weather.zig` (storm + blood-moon groups, `weather.zwt`), `src/world/sleepers.zig` + `src/server/game/sleeper.zig` (volume wakes, one-way), `src/world/deco_mirror.zig` (optional deco, `[feature] deco_mirror`).

The stream itself (`src/server/game/chunk_stream.zig:streamChunksForClient`) rasters inside a budget square derived from `chunk_stream_radius` and `max_streamed_chunks`, delivering at most `chunk_adds_per_stream_tick` per pass so the reliable window can drain. See the backpressure SM below.

```mermaid
stateDiagram-v2
    [*] --> StreamPass: period gate — chunk_stream_period_ticks
    StreamPass --> Remove: keys outside radius — ChunkRemove + deco reset
    Remove --> Add: raster scan inside square
    Add --> Add: delivered — clientAddStreamed — at cap drop oldest
    Add --> PacedRetry: WindowFull — resendPending + pollNetOnce
    PacedRetry --> Add: retry ok — fast window then 1 ms pacing — ≤ 64 tries
    PacedRetry --> SoftDrop: attempts exhausted — reliable_window_drops
    Add --> StreamPass: chunk_adds_per_stream_tick reached
    SoftDrop --> StreamPass: retried next pass
    StreamPass --> [*]: peer disconnect
```

---

## 8. Interest and replication: serialize-once

Stock's measured wall is not entity AI but **net**: per-entity × per-player rebuild with no spatial index and per-connection re-serialization of the same bytes. zdtd collapses it:

- **Spatial interest** via a chunk or 16-block grid hash — an entity evaluates only players in nearby cells, and interest rebuilds only when a cell changes.
- **Dirty bitsets** per entity: `POS | ROT | FLAGS | HP | SPAWN | REMOVE`.
- **Serialize once** per dirty package kind per tick, then `memcpy` fan-out.

```mermaid
flowchart TB
    DIRTY{entity dirty or heartbeat?}
    DIRTY -- no --> SKIP[skip — replicate_encodes_skipped++]
    DIRTY -- yes --> GATE{any observer in range?}
    GATE -- no --> SKIP
    GATE -- yes --> ENC2[encode PosAndRot once<br/>zombies also Speeds + AliveFlags once<br/>framed via wire/packages.framed<br/>into stack scratch]

    ENC2 --> FANOUT[for each interested peer in cell range<br/>no self-echo for owning player<br/>sendFramedDroppable — framed bytes memcpy<br/>replicate_fanouts++]
    FANOUT --> CLEAR[interest.clearAfterReplicate — pos/rot/spawn/flags<br/>hp/inv/remove stay dirty]
    SKIP --> NEXT([next entity])

    classDef once fill:#1a3a5c,stroke:#5b8def,color:#dbe6ff
    class ENC2 once
```

Spawn-on-approach still builds `NetPackageEntitySpawn` (ECD) once when any peer needs it. Motion frames (`RelPos`) are genuinely per-player and are the only per-peer encode. The trio `replicate_candidates / replicate_fanouts / replicate_encodes_skipped` plus `packages_encoded` is the acceptance check:

- `candidates / ticks` follows world change, not slot table size.
- `fanouts / packages_encoded` is the fan-out ratio — adding a viewer raises fan-outs and leaves encodes flat.
- `encodes_skipped` is pure interest savings.

Wired in `src/server/game/replicate.zig` (candidates + dirty gating + `needsPosSend`), `src/ecs/interest.zig` (range + dirty helpers), `src/server/game/net.zig` (framed fan-out + `sendReliablePumped` soft-drop). Guarded by the scenario in `src/server/scenarios.zig`.

---

## 9. Plugin host: Wasm guests

Behavioral extension is **Wasm only** (ADR 0020). A plugin is a `.wasm` module named in `zdtd.toml:[plugin] modules`; the host is `plugin/wasm.zig` over `zwasm` v2 (Zig-native, no C, `use_llvm = true`). The static host (`plugin/host.zig`) stays for scenario scaffolding.

### 9.1 Lifecycle

```mermaid
stateDiagram-v2
    [*] --> Registered: loadAll — instantiate + check _zdtd_requires
    Registered --> Enabled: on_enable
    Enabled --> Enabled: on_tick every tick — on_player_join on join
    Enabled --> Enabled: event hooks — playerDeath, entityKilled, blockDamage, questComplete
    Enabled --> Enabled: admin/chat/login hooks
    Enabled --> Disabled: trap or OutOfFuel — that module only
    Enabled --> [*]: on_shutdown
    Disabled --> [*]: on_shutdown — hooks skipped
    Registered --> [*]: manifest conflict — duplicate point or override — boot fails loud
```

Modules declare what they need via `_zdtd_requires` (hook + host verb names); a typo is a **load rejection**, not a silent never-fire. Every `zdtd.queue` command is attributed to its 1-based issuing slot; if the module disables itself, its still-pending commands are withdrawn before the drain (revertible effects). See `docs/prompts/plugin-composability-review.md` and ADR 0030.

### 9.2 Host boundary

```mermaid
flowchart LR
    subgraph guest["Guest .wasm — linear memory only"]
        EXP["exports — on_enable, on_tick, on_player_join, on_shutdown<br/>on_player_death, on_entity_killed, on_block_damage, on_quest_complete<br/>on_admin_command, on_chat, on_player_login"]
        MEM["linear memory — flat bytes in/out"]
    end
    subgraph host["Host — capability gated"]
        IMP["imports — zdtd.log, zdtd.tick, zdtd.queue<br/>+ sense/query views as added"]
        BUDGET["Budget — fuel 100M + max_pages 1024<br/>lifetime, never re-armed per call"]
        QUEUE["SimCommand queue — drain once per tick<br/>in schedule.commands"]
    end
    guest -->|declare _zdtd_requires| host
    host -->|Linker.defineFunc| guest
    guest -- "queue(ptr,len) — bytes copied" --> QUEUE
    host -- "tick + log — copied out" --> guest
    BUDGET -. limits .-> guest
```

Verdict semantics (first non-zero across plugins wins; a trap is keep):

| Hook family | Return | Meaning |
|---|---|---|
| `on_player_login` | `< 0` deny with reason bytes in out | first deny wins |
| `on_chat` | `< 0` deny, `0` keep, `> 0` filtered bytes | bad UTF-8 is deny |
| `on_admin_command` | `> 0` handled bytes | first handler wins, else core |
| `on_player_death` / `on_entity_killed` / `on_block_damage` / `on_quest_complete` | `< 0` deny, `0` keep, `> 0` adjust as percent | first non-zero wins |
| Core override points `loot.roll` etc. | exclusive claimant | native default skipped |

Five exclusive core override points (`loot.roll`, `quest.payout`, `damage.player_scale`, `craft.request`, `trade.price`) become single-owner when a `mod.toml` claims `points = "…"`. Duplicate claims fail the boot (`src/plugin/manifest.zig`, `src/plugin/resolver.zig`).

Core plugins under `plugins/core_*/` ship Zig sources built to `.wasm` by `scripts/build-plugins.sh` (shared `mods/plugin_common.zig`). Addons (`mods/fps_bot`, `mods/mcp`, `mods/example_chat_filter`) live under `mods/`. Bot brains are **Wasm only** — `BotManager` is a servant (spawn/replicate/move/LOS/sense/`bot` verbs) and never grows native decision logic (ADR 0026).

---

## 10. Config, assets, and persistence

### 10.1 Config precedence

Tuning is data, not parse arms (`util/toml_bind.zig` walks the dest struct — a new field auto-binds). Sim params are `ecs/rules.zig:Rules`, a floor that per-entity stock data overrides where present.

```mermaid
flowchart LR
    CODE["code defaults<br/>ecs/rules.zig<br/>server/config.zig"] --> SC
    SC["--serverconfig XML<br/>ServerSettings"] --> MODE
    MODE["mode pack<br/>modes/*.toml — --mode NAME"] --> CWD
    CWD["CWD zdtd.toml"] --> WORLD_TOML
    WORLD_TOML["world/zdtd.toml"] --> ENV
    ENV["env — ZDTD_WEBUI_SECRET etc."] --> CLI
    CLI["CLI flags — --port --world --game-dir …"] --> EFFECTIVE

    EFFECTIVE["effective config<br/>Game + Rules + world store"]

    classDef winner fill:#25361f,stroke:#6fbf6a,color:#dff5dc
    class EFFECTIVE winner
```

See `docs/GAME_OPTIONS.md`, `docs/RULES_CONFIG.md`, `docs/PLUGIN_CONFIG_DISPOSITION.md`.

### 10.2 Asset pipeline

Stock content is **data loaded from the operator install** (`--game-dir` / `--map` / `--config-dir`), never shipped or hardcoded per ADR 0010. Every `src/` file carries a provenance row in `docs/PROVENANCE.md` (bucket A stock-data / R RE-cited / Z zdtd-owned).

```mermaid
flowchart TB
    GAME_DIR["--game-dir — Data/Config *.xml<br/>Data/Worlds/<Name> — DTM + prefabs + biomes"] --> ASSETS
    ASSETS["assets/* — blocks, items, recipes, loot,<br/>quests, biomes, buffs, traders, vehicles,<br/>entitygroups, spawning, progression"] --> CATALOGS
    CATALOGS["catalogs in RAM<br/>AssignIds idByName, maxdamage, loot tables,<br/>quest defs, trader rolls"] --> ECS2[ECS catalog resource<br/>+ entity prefabs]
    ECS2 --> WIRE2[wire builders use resolved ids<br/>never sequential XML order]
    MODS["Mods/<name>/Config — XPath patches<br/>+ Bundles/ + Localization.csv<br/>pure XML modlets only — PRD 0003"] --> PATCH
    PATCH["assets/modlets — patched catalogs<br/>join-phase NetPackageConfigFile sync"] --> CATALOGS
```

Fail-closed rules: missing name → omit / not placeable / skip deco (wrong id is worse than missing). `xml_patch` applies XPath; `NetPackageConfigFile` syncs the patched view at join.

### 10.3 Persistence

Mutations surviving a restart go through `world/*` / `server/persist.zig`, not just interest caches.

```mermaid
flowchart TB
    subgraph save["On save interval — saveAll"]
        CHUNKS["world/store.zig — .zch ZCH3 chunks"]
        CONTAINERS["world/containers.zig — containers.zch"]
        TTS["world/tts.zig — TTS deco"]
        WS["workstations — .zbf"]
        VEND["world/vending.zig — vending.zch"]
        CLAIMS["claims — .zcl"]
        ENTITIES["entities — .zent"]
        WEATHER["world/weather.zig — weather.zwt ZWTH1"]
        CLOCK["world clock — clock.zwt"]
        PLAYERS["PlayerDataFile — .ttp per player"]
        ALLIES["allies — .zal"]
        META["block meta — .zbm"]
    end
    WORLD_DIR[("world/ — flat overlay dir")] --- save
    TICK2["Game.step — tick_n % save_interval_ticks == 0"] --> save
```

Green join does not mean persisted. Deterministic sim uses explicit seeded RNG, not time noise.

---

## 11. Observability: APM

Native metrics live in `src/apm/` (`metrics.zig:CounterId`, `profiler.zig:Section`, `report.zig`). They ship **inside** the `zdtd` binary, not via `7dtd-server-apm` (Mono bridge, different process).

```mermaid
flowchart LR
    TICK_LOOP["tick loop"] --> INC["counters.inc / add<br/>ticks, net_packets_in/out,<br/>join_ok/fail, stale_peers_reaped,<br/>chunk_flush_*, path_replans, replicate_* …"]
    TICK_LOOP --> PROF["profiler.scope(&prof, .tick_total)"]
    PROF --> HIST["per-section histograms<br/>tick_total, net_poll, sim_entities,<br/>replicate, chunk_stream, save_io, terrain_snap …<br/>mean / p50 / p99 / max — power-of-two ns buckets"]
    INC --> SNAP["harness.snapshot()"]
    HIST --> SNAP
    SNAP --> TEXT["text dump — --ticks/--once exit<br/>+ admin apm command"]
    SNAP --> JSON["JSON line — {type:zdtd_apm, ops:{tick,joined,entered,peers_alive,zombies,chunks}}<br/>once per minute to stdout — scrapable"]

    TRACY["Optional Tracy zones<br/>-Dtracy -Dtracy-src — one zone per Section<br/>+ frame mark per tick"] -. viewer .-> PROF

    classDef live fill:#1a3a5c,stroke:#5b8def,color:#dbe6ff
    class INC,PROF live
```

Text and JSON max sizes are derived at comptime from the enums so a new counter can never silently truncate a report. The replication trio (`replicate_candidates / replicate_fanouts / replicate_encodes_skipped` over `packages_encoded`) is the M11 serialize-once acceptance check — see section 8.

Optional Tracy markers are zero-sized when off and link no libc. See [APM.md](APM.md).

---

## 12. Invariants

These are the non-negotiables the architecture exists to enforce. When in doubt, these decide.

| # | Invariant | Where it is enforced |
|---|---|---|
| 1 | **Clean-room, stock wire only** — no TFP DLLs, no decompiled C#, no invented terrain/packages/FX | `docs/PROVENANCE.md`, `tools/provenance_scan.py` |
| 2 | **Single shape → single builder** — one stock package shape is one `wire/stock_*.zig` builder the client `Read`s | `src/wire/packages.zig` facade |
| 3 | **Server authoritative** — C2S is a request validated at trust boundaries, sim owns the result | `src/server/c2s/*`, `server/phase_gate.zig`, `server/guard_policy.zig` |
| 4 | **Phase gates** — only packages legal for the peer's SM state are accepted | `server/phase_gate.zig:allowed` |
| 5 | **No self-echo, serialize-once** — per-entity encode once, fan-out to observers | `server/game/replicate.zig`, `ecs/interest.zig` |
| 6 | **Bounds and caps on every untrusted input** — coords, slot indices, counts, string lengths, fragments | C2S handlers + `chunk_stream` caps + `command` cap 64 |
| 7 | **Fail closed on encode** — omit or send stock empty form, never truncate mid-field | wire builders |
| 8 | **Hot path never allocates** — reuse `recv_buf`/`send_buf`/`body_buf`, SoA columns, pools | `server/game/step.zig`, `ecs/*`, `world/*` |
| 9 | **Deterministic sim** — same seed and inputs produce same outcomes where claimed | seeded RNG in loot/AI/director |
| 10 | **20 TPS budget** — 50 ms tick validated by loadgen + stock client + zdtd APM dumps | `src/protocol.zig:ticks_per_second = 20`, `src/apm/*` |

---

## Related docs

| Doc | Role |
|---|---|
| [STATUS.md](STATUS.md) | What works now — the hub |
| [GAP_ANALYSIS.md](GAP_ANALYSIS.md) | Full 291-feature inventory — WORKS/PARTIAL/MISSING |
| [WORK_PLAN.md](WORK_PLAN.md) | Ranked next tasks |
| [STATE_MACHINES.md](STATE_MACHINES.md) | 20 state machines with diagrams and `src/` anchors |
| [ECS_SYSTEMS.md](ECS_SYSTEMS.md) | SoA columns, queries, groups, tick order |
| [PLUGIN_API.md](PLUGIN_API.md) | Wasm plugin design — host boundary and budgets |
| [PLUGIN_DEV.md](PLUGIN_DEV.md) | Writing a plugin: hooks, limits, building a `.wasm` |
| [wire/PACKAGES.md](wire/PACKAGES.md) | 190-package catalog |
| [AUTHORITY.md](AUTHORITY.md) | Join phases, C2S validation, interest, mode |
| [APM.md](APM.md) | Native metrics — counters, sections, Tracy |
| [SCALE.md](SCALE.md) | Scale switches and shard plan |
| [ZIG_CLONE.md](ZIG_CLONE.md) | Founding architecture from the RE (history) |
| [MAPS.md](MAPS.md) | DTM, prefabs, TTS |
| [GAMEPLAY.md](GAMEPLAY.md) | Gameplay flows — craft, trade, loot, survival |
| [WEBUI.md](WEBUI.md) | Operator web UI and security model |

## Keeping this document honest

- This doc is the map; `src/` is the territory. When they disagree, fix code to RE, then fix the map.
- State machines added or removed in code: update the table in `STATE_MACHINES.md` and the matching diagram here in the same commit.
- New wire or sim surface: add a row to `PROVENANCE.md` and a builder in `wire/stock_*.zig` — never invent wire.
- New hot-path cost: add an `apm` section and counter and judge regressions from zdtd dumps, not Mono APM.
