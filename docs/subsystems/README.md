# Subsystems

One reference page per subsystem of zdtd-server: what it owns, the data
structures it moves, and how it is wired. These pages carry the type and layout
detail; [ARCHITECTURE.md](../ARCHITECTURE.md) carries the behavior map across
subsystems (composition, the 50 ms tick, the seams). See
[docs/AGENTS.md](../AGENTS.md) for which tier owns which fact.

Pages cite `file.zig:LINE` and quote declarations verbatim. `tools/check_docs.py`
(`make lint`) fails when a relative link is dead, a cited line is out of range,
or a quoted Zig block no longer matches its source.

## Transport and encoding

| Page | Owns |
|---|---|
| [litenet.md](litenet.md) | the UDP carrier: socket loop, peer slots, LiteNet packet framing, the connect handshake and disconnect paths |
| [wire.md](wire.md) | the byte-level contract: LE binary codec, frame wrappers, the package-name registry, and every stock body builder |

## Join and play path

| Page | Owns |
|---|---|
| [join.md](join.md) | challenge to playing: the join state machine, phase-gated package legality, peer lifecycle, drop and reap paths |
| [c2s.md](c2s.md) | the C2S dispatch table, the per-domain handler contract, trust-boundary validation and rate limits |
| [movement.md](movement.md) | position and rotation intake, bounds and speed checks, teleport, respawn, vehicle and attachment placement |
| [tick.md](tick.md) | the process loop: startup order, the ordered per-tick schedule, pacing and load shedding, APM scope placement |
| [interest.md](interest.md) | observer sets, serialize-once replication, and the entity, tile-entity and health fan-out paths |
| [chunk-stream.md](chunk-stream.md) | per-peer chunk queues, the per-tick send budget, chunk fill and the streamer handshake |
| [scenarios.md](scenarios.md) | the automated proof layer: scenario tests, the in-process harness, evidence capture and fuzzing |

## Simulation and world

| Page | Owns |
|---|---|
| [ecs.md](ecs.md) | the structure-of-arrays world, entity identity, component columns, the system registry and sim rule parameters |
| [inventory.md](inventory.md) | the slot model, the item ledger, stock inventory bodies and the C2S inventory operations |
| [quests.md](quests.md) | quest state, objective progress, the quest packages and C2S quest operations |
| [traders.md](traders.md) | trader tile entities, the trade window wire, vending machines and price resolution |
| [weather.md](weather.md) | the weather state machine, sky and ambient light, world time and their persistence |
| [world-store.md](world-store.md) | the chunk and tile-entity store, dirty tracking, the ZCH3 file format and the flush path |
| [map.md](map.md) | reading stock map data: DTM, prefabs, TTS, biomes, water, navigation and sky tables |
| [worldgen.md](worldgen.md) | procedural terrain synthesis, the biome field and decoration-only subbiome noise |
| [persistence.md](persistence.md) | what survives a restart: chunk files, player records, the world clock and the save triggers |
| [sleepers.md](sleepers.md) | sleeper volumes from prefab XML, the authored spawn cells TTS carries, and the wake and re-arm paths |
| [stability.md](stability.md) | structural support, removal relaxation and collapse for block edits, and what the client is told |
| [deco.md](deco.md) | the decoration object, the mirror that keeps repeated props coherent, POI suppression and the chunk send path |

## Gameplay systems

| Page | Owns |
|---|---|
| [buffs.md](buffs.md) | buff state, stacking and expiry, the buffs XML catalog, the buff wire, and the perk/attribute passive-effects path |
| [power.md](power.md) | the electric grid, power blocks, and the light and turret tile entities |
| [director.md](director.md) | the director clock, the blood-moon ladder, gamestage and entitygroup rolls, and sleeper spawn |
| [crafting.md](crafting.md) | recipe resolve and unlock, ingredient folding with snapshot rollback, scrapping, and loot rolls into bags |
| [vehicles.md](vehicles.md) | vehicle columns, seats and riders, drive input validation, attach gating and entity persistence |
| [party.md](party.md) | party membership wire, invite and accept flows, and the ally identity record |
| [locks.md](locks.md) | POI and claim lock ownership, open and pick validation, and the sleeping-bag interaction |

## Content and configuration

| Page | Owns |
|---|---|
| [assets.md](assets.md) | stock XML and bundled data into catalogs: id assignment, unifying hashes, XPath modlets, fail-closed name resolution |
| [config.md](config.md) | serverconfig.xml, zdtd.toml, preset packs, the reflected TOML binder and the sim Rules overlay |
| [plugin-host.md](plugin-host.md) | the Wasm runtime: hooks, host verbs, budgets and fuel, manifest validation, reload and effect withdrawal |
| [bots.md](bots.md) | the bot boundary: the native BotManager servant and the fps_bot Wasm guest that decides |

## Operations and tooling

| Page | Owns |
|---|---|
| [admin.md](admin.md) | the admin TCP endpoint and verbs, the console registry, GSI/serverinfo, bans, guard policy and the MCP transport |
| [webui.md](webui.md) | the embedded operator pages, login and lockout, JSON feeds, and the TypeScript build and lint gates |
| [apm.md](apm.md) | native instrumentation: counters, latency histograms, section timers, tracy zones and the snapshot formats |
| [util.md](util.md) | the leaf utility layer: mono clock, seeded RNG, filesystem helpers, range parallelism, arenas and the TOML binder |

## Coverage

Every subsystem with source in `src/` has a page here. [ASSETS.md](../ASSETS.md)
carries the XML loader map they depend on, [GAMEPLAY.md](../GAMEPLAY.md) the
player-visible flows, and [STATE_MACHINES.md](../STATE_MACHINES.md) their
lifecycles.
