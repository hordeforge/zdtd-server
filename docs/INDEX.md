# zdtd docs index

**RE gap closure (open items -> research spec):** [RE_GAP_CLOSURE.md](RE_GAP_CLOSURE.md)

**Conflict rule:** [STATUS.md](STATUS.md) is the living hub. If STATUS and
MISSING / IMPLEMENTATION_PLAN disagree on whether something shipped, **STATUS
wins**. Refresh inventory docs when closing work.

## Start here

| Doc | Role |
|---|---|
| [STATUS.md](STATUS.md) | What works now (gates + shipped surface) |
| [../TODO.md](../TODO.md) | Open backlog first; shipped log below the fold |
| [MISSING_FEATURES.md](MISSING_FEATURES.md) | Gap inventory (honest PARTIAL sections) |
| [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) | M7–M16 phases (post-playable stack) |
| [../AGENTS.md](../AGENTS.md) | Project rules for agents and humans |

## Wire and play path

| Doc | Role |
|---|---|
| [PACKAGES.md](PACKAGES.md) | Full 190-package catalog |
| [PARITY_TOOLING.md](PARITY_TOOLING.md) | Version-diff + C2S coverage tooling |
| [WIRE_CHUNK.md](WIRE_CHUNK.md) | Chunk wire path |
| [WIRE_WORKSTATION.md](WIRE_WORKSTATION.md) | Workstation TE wire |
| [INVENTORY.md](INVENTORY.md) | Inventory wire |
| [MAPS.md](MAPS.md) | DTM / prefabs / TTS |
| [ASSETS.md](ASSETS.md) | XML load paths |
| [GAME_OPTIONS.md](GAME_OPTIONS.md) | serverconfig.xml → sim |

## Architecture

| Doc | Role |
|---|---|
| [zig-clone.md](zig-clone.md) | M0–M6 architecture from RE |
| [ECS.md](ECS.md) | SoA sim |
| [SYSTEMS.md](SYSTEMS.md) | Systems overview |
| [APM.md](APM.md) | Native metrics (`src/apm/`) |
| [PLUGIN_API.md](PLUGIN_API.md) | Native plugin design (proposed) |
| [adr/README.md](adr/README.md) | Architecture decision records |

## Scale (parked until M11)

| Doc | Role |
|---|---|
| [SCALE_ARCHITECTURE.md](SCALE_ARCHITECTURE.md) | Substrate research; SpacetimeDB rejected |
| [PLANET_SCALE.md](PLANET_SCALE.md) | Shard / gateway / DEM positive plan |
| [WORLDGEN.md](WORLDGEN.md) | Procedural world-gen design |

## External RE (sibling repo)

| Doc | Role |
|---|---|
| [../../7dtd-research/docs/protocol.md](../../7dtd-research/docs/protocol.md) | Envelope, join, goldens |
| [../../7dtd-research/docs/protocol-frames.md](../../7dtd-research/docs/protocol-frames.md) | Byte frames per package |
| [../../7dtd-research/docs/INDEX.md](../../7dtd-research/docs/INDEX.md) | Research hub |

## Milestone snapshot (2026-07-23)

```text
Core playable loop     DONE (11/11 playtest, 0 NRE)
M7–M10 core            DONE
M11 interest/scale     PARTIAL (open 1.0 scale gate)
M12–M15 depth/ops      PARTIAL (honest gaps in MISSING)
M16 / planet M2+       OPEN / parked
```
