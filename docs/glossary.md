# Glossary

This page is the canonical term list for zdtd-server: one concept, one name.
Each entry fixes the meaning used here and points at the owner of the detail.
[subsystems/](subsystems/README.md) carries type and layout facts,
[ARCHITECTURE.md](ARCHITECTURE.md) the behavior map, [ASSETS.md](ASSETS.md) the
data-loading policy, [AUTHORITY.md](AUTHORITY.md) state ownership, and
[adr/](adr/README.md) the decisions.

## Wire and packages

- **package**: One stock `NetPackage`: a `u16` id plus a body
  (`src/wire/frame.zig:28`, [wire.md](subsystems/wire.md)).
- **package name, package id**: A package's stock name string
  (`NetPackagePlayerId`) is the stable identity, held in one ordered list
  (`src/wire/packages.zig:27`); its numeric id is that name's index in the list
  the server advertises at join, and is dynamic across game versions
  (`src/wire/packages.zig:76`).
- **C2S, S2C**: Package direction. A decoded C2S package passes the phase gate
  and trust-boundary validation, then applies or is dropped; S2C goes only to
  observing peers ([c2s.md](subsystems/c2s.md)).

## Interest and replication

- **interest**: The spatial-grid test deciding which peers may see an entity in
  a tick: a uniform 32-block cell grid ([interest.md](subsystems/interest.md)).
- **observer set**: The per-entity result: one bit per client slot, built by
  vector comparison (`src/ecs/interest.zig:55`).
- **serialize-once**: Encode a body once per tick, then copy the bytes to each
  observing peer instead of encoding per peer
  ([adr/0008-serialize-once-interest.md](adr/0008-serialize-once-interest.md)).
- **dirty bits**: The per-entity mask of components changed since the last
  replication pass ([interest.md](subsystems/interest.md)).

## Join and session

- **join phase**: The peer session state derived from `Client.joined` and
  `Client.entered`: connecting, joined, playing
  (`src/server/phase_gate.zig:7`).
- **phase gate**: The per-phase allowlist of C2S package names; an illegal
  package is dropped and counted (`src/server/phase_gate.zig:58`).
- **spawn area**: The join-time chunk burst sent while a client enters, clamped
  and paced so the join ack keeps flowing
  ([chunk-stream.md](subsystems/chunk-stream.md)).

## World and content data

- **chunk**: The resident world unit, 16 blocks on X and Z and 256 on Y
  (`src/world/store.zig:37`), with lazily allocated planes.
- **streamed chunk**: A chunk key a peer is known to hold, tracked so the
  streamer does not resend it (`src/server/game/types.zig:632`).
- **chunk body**: The body of `NetPackageChunk`: `overwrite=false | dataLen |
  stock Chunk.write payload` (`src/wire/stock_chunk.zig:852`). The
  `cx | cz | ydim | 256 heights` shape is a test helper
  (`src/wire/packages.zig:1768`).
- **TTS**: A prefab's `.tts` block paint file: block values, density, damage,
  texture and water per flat index (`src/world/tts.zig:1`).
- **DTM**: The baked map height plane (`dtm.raw`, `dtm_processed.raw`) the flat
  and prefab paths read (`src/world/dtm.zig:1`).
- **DEM**: The Copernicus GLO-30 elevation codec used as an alternative terrain
  source; its streaming layer is parked (`src/world/dem.zig:1`,
  [SCALE.md](SCALE.md)).
- **prefab**: A stock structure from `prefabs.xml`, with a footprint, a `.tts`
  paint and a `<name>.blocks.nim` id map (`src/world/prefabs.zig:1`).
- **POI**: A placed prefab carrying quest data; stock `part_*` city pieces are
  never quest POIs (`src/world/prefabs.zig:60`).
- **biome map**: `biomes.png` decoded to biome ids; `BiomeMap` supplies a chunk's
  dominant id and per-cell ids through `atWorld` (`src/world/biomes.zig:219`).
- **tile entity (TE)**: A world-position-keyed interactive block state such as a
  container, sign or workstation, carrying a stock `TileEntityType`
  discriminant (`src/wire/te_types.zig:1`,
  [world-store.md](subsystems/world-store.md)).

## Save and store formats

- **ZCH3**: The per-chunk `.zch` file: magic, position, flags, heights, then
  optional planes ([world-store.md](subsystems/world-store.md)).
- **ZCH4**: The non-stock wire-profile variant of ZCH3 that carries the column
  height in the header; a stock loader rejects it (`src/world/store.zig:1385`).
- **ZPV16**: The player record format, widened in v16 with per-slot `ItemValue`
  stat entries (`src/server/persist.zig:115`).
- **ZCT2, ZSG1, ZVNM, ZWS1**: The container, sign, vending machine and
  workstation store formats (`src/world/containers.zig:186`,
  `src/world/signs.zig:122`, `src/world/vending.zig:159`,
  `src/world/workstations.zig:708`).

## Catalogs and content loading

- **AssignIds**: The stock dump assigning block and item wire ids by name; XML
  row order is never an id source ([assets.md](subsystems/assets.md)).
- **name-to-id map**: The merged `idByName` and `name_by_id` tables resolved from
  AssignIds plus loaded XML; a miss fails closed
  ([assets.md](subsystems/assets.md)).
- **Unity name hash**: The stable string hash (`GetStableHashCode`) used for
  entity class keys and TE feature names (`src/assets/unity_hash.zig:1`).
- **catalog**: A typed table built once from stock XML at `Game.init`, then read
  only ([assets.md](subsystems/assets.md)).
- **modlet**: An XML-only stock mod under `Mods/<name>/Config` whose XPath
  patches apply as data; DLLs and bundles are never hosted
  ([prd/0003-modlets.md](prd/0003-modlets.md)).
- **XPath patch**: A stock `XmlPatcher`-style document that appends, sets or
  removes elements in a target config; an unparseable XPath is skipped
  ([assets.md](subsystems/assets.md)).
- **provenance bucket**: The A, R or Z classification every `src/` file row
  carries: stock data, RE-cited behavior, or zdtd-owned policy
  ([PROVENANCE.md](PROVENANCE.md)).

## Simulation

- **SoA (structure of arrays)**: The ECS storage shape: parallel component arrays
  gated by a presence mask
  ([adr/0002-native-soa-not-third-party-ecs.md](adr/0002-native-soa-not-third-party-ecs.md)).
- **EntityHandle (slot and generation)**: A dense slot index plus a generation
  counter bumped on recycle, so a stale handle fails `handleAlive`
  (`src/ecs/entity.zig:17`).
- **Rules, rule parameter**: The sim parameter struct carried on `World.rules`
  and overlaid by a preset pack or `zdtd.toml` (`src/ecs/rules.zig:796`). A
  field of it is a floor, because per-entity stock data wins where present
  ([adr/0021-config-driven-game-modes.md](adr/0021-config-driven-game-modes.md)).
- **preset pack, mode pack**: A data-only `presets/<name>.toml` file selected by
  `--preset`, carrying InitOptions values and `[rules.*]` overrides
  (`src/server/preset.zig:1`); `mode pack` is the earlier name and `--mode` a
  deprecated alias.

## Plugins and bots

- **bot host servant vs guest brain**: The host `BotManager` owns every bot body
  (spawn, movement, collision, damage, replication) while the Wasm guest owns
  every decision ([bots.md](subsystems/bots.md)).
- **hook**: One tag in the closed plugin hook table that a guest module exports,
  such as `on_tick` or `on_entity_killed` (`src/plugin/wasm.zig:20`).
- **host verb**: A function the host exposes to a guest module, such as `log`,
  `tick`, `queue`, `sense` or `query` ([plugin-host.md](subsystems/plugin-host.md)).
- **fuel budget**: The lifetime instruction budget armed at instantiation;
  exhausting it disables that module alone
  ([plugin-host.md](subsystems/plugin-host.md)).
- **plugin reload**: Disposing and reinstantiate a module in place, running
  `on_shutdown` then `on_enable`, without a server restart
  (`src/plugin/wasm.zig:1177`).
- **withdrawal of queued effects**: Dropping the still-pending `zdtd.queue`
  commands attributed to a disabled or reloaded module before the drain
  (`src/plugin/wasm.zig:1414`).
- **core plugin vs addon**: A core plugin ships under `plugins/` with Zig source
  rebuilt by `scripts/build-plugins.sh`; an addon lives under `mods/`
  ([PLUGIN_STANDARDS.md](PLUGIN_STANDARDS.md)).

## Operations, metrics and evidence

- **harness**: Two distinct things. The test seam `src/server/game/harness.zig`
  drives joined clients and packet injection in scenarios; the APM `Harness`
  (`src/apm/root.zig:22`) is the process-wide counter and profiler handle.
- **APM**: zdtd's native instrumentation: counters, section timers, text or JSON
  dumps; not the Mono `7dtd-server-apm` bridge ([APM.md](APM.md)).
- **GSI**: The stock `GameServerInfo` TCP service serving the server browser's
  key and value text ([admin.md](subsystems/admin.md)).
- **admin console**: The telnet-style admin TCP endpoint plus the webui drain
  and in-game F1 path, all funnelling through one `runAdminLine` parser
  ([admin.md](subsystems/admin.md)).
- **guard policy**: The pure decision layer over detector evidence: log-only by
  default, with opt-in quarantine and kick rungs
  (`src/server/guard_policy.zig:1`).
- **evidence**: The fixed 64-entry in-memory ring of detector events (severity,
  detector, surface), dumped as JSONL by `evidence dump`
  (`src/server/evidence.zig:7`).
- **IL anchor, loadgen golden**: The two accepted forms of stock evidence: a
  cited method plus line in the decompiled assembly, or a byte-level wire
  expectation pinned with the sibling `7dtd-loadgen` bots ([INDEX.md](INDEX.md)).
- **self-consistency vs stock compatibility**: A green zdtd encode and decode
  round trip proves only that zdtd agrees with itself; a stock claim needs an IL
  anchor or a real client observation ([INDEX.md](INDEX.md)).
- **missing beats fake**: The fidelity rule: a documented gap beats an invented
  body a stock `Read` may reject
  ([adr/0014-missing-beats-fake.md](adr/0014-missing-beats-fake.md)).

## See also

- [ARCHITECTURE.md](ARCHITECTURE.md)
- [subsystems/README.md](subsystems/README.md)
- [ASSETS.md](ASSETS.md)
- [AUTHORITY.md](AUTHORITY.md)
- [INDEX.md](INDEX.md)
