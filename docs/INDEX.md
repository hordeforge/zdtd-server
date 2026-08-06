# zdtd docs index

**Conflict rule:** [STATUS.md](STATUS.md) is the living hub. If STATUS and
GAP_ANALYSIS / IMPLEMENTATION_PLAN disagree on whether something shipped,
**STATUS wins**. Refresh the inventory docs when closing work.

**Evidence rule:** zdtd encodes and decodes with the same code, so a green
round-trip test proves self-consistency, not stock compatibility. A claim about
stock behaviour needs an IL anchor (method plus line) or an observation from the
real client.

**Version pin:** the target is stock **V3.1.0 b14**, EAC off, and that is what
the live gate runs against. IL citations of the form `asm.il:NNNN` refer to the
V3.1.0 single-file dump whose identity (size, line count, MD5) is recorded in
[`../../7dtd-research/il/README.md`](../../7dtd-research/il/README.md); those
line numbers are valid only against that exact file. The research repo tracks
the latest release only: its `il/` sets are all V3.1.0 and the V3.0.1 sets were
deleted on 2026-08-06. Mentions of V3.0.1 in these documents are provenance, and
any line number written before that date may be a V3.0.1 number, which drifts by
roughly 3500 lines in the NetPackage region.

## Read in this order

New to the project, or picking up work:

1. [STATUS.md](STATUS.md) what works now, with the current gates.
2. [GAP_ANALYSIS.md](GAP_ANALYSIS.md) what does not, 345 features scored
   WORKS / PARTIAL / MISSING with anchors.
3. [WORK_PLAN.md](WORK_PLAN.md) what to build next, as self-contained tasks.
4. [../AGENTS.md](../AGENTS.md) the rules everyone works under.

| Doc | Role |
|---|---|
| [STATUS.md](STATUS.md) | What works now (gates + shipped surface). Wins on conflict |
| [GAP_ANALYSIS.md](GAP_ANALYSIS.md) | The gap document: 345 features scored WORKS/PARTIAL/MISSING with anchors, plus the area narratives and deep dives |
| [WORK_PLAN.md](WORK_PLAN.md) | Handoff-ready tasks: files, grounding, done-when, proof |
| [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) | M7-M16 phases (post-playable stack) |
| [RE_GAP_CLOSURE.md](RE_GAP_CLOSURE.md) | Open items turned into research specs |
| [../TODO.md](../TODO.md) | Open backlog first; shipped log below the fold |
| [RELEASES.md](RELEASES.md) | Version, compatibility, support, release policy |
| [../CHANGELOG.md](../CHANGELOG.md) | Consumer-visible changes and migrations |
| [../AGENTS.md](../AGENTS.md) | Project rules for agents and humans |

## Wire and play path

What goes over the socket, and how it is proven against the stock client.

| Doc | Role |
|---|---|
| [PACKAGES.md](PACKAGES.md) | Full 190-package catalog |
| [WIRE_CHUNK.md](WIRE_CHUNK.md) | Chunk wire path |
| [WIRE_WORKSTATION.md](WIRE_WORKSTATION.md) | Workstation tile-entity wire |
| [INVENTORY.md](INVENTORY.md) | Inventory wire |
| [AUTHORITY.md](AUTHORITY.md) | Join phases, C2S validation, interest, mode |
| [CLIENT_PLAYTEST.md](CLIENT_PLAYTEST.md) | Stock-client automated play suite (design) |
| [PARITY_TOOLING.md](PARITY_TOOLING.md) | Version-diff and C2S coverage tooling |

## World and content

Where the world and its data come from.

| Doc | Role |
|---|---|
| [MAPS.md](MAPS.md) | DTM, prefabs, TTS |
| [WORLDGEN.md](WORLDGEN.md) | Procedural world generation design |
| [ASSETS.md](ASSETS.md) | Stock XML load paths |
| [GAME_OPTIONS.md](GAME_OPTIONS.md) | serverconfig.xml into the sim |

## Architecture

| Doc | Role |
|---|---|
| [zig-clone.md](zig-clone.md) | M0-M6 architecture derived from the RE |
| [ECS.md](ECS.md) | SoA simulation |
| [SYSTEMS.md](SYSTEMS.md) | Systems overview |
| [APM.md](APM.md) | Native metrics (`src/apm/`) |
| [PLUGIN_API.md](PLUGIN_API.md) | Wasm plugin design (ADR 0020) |
| [PLUGIN_DEV.md](PLUGIN_DEV.md) | Writing a plugin: hooks, limits, and building a .wasm from any language |
| [STD_ABSTRACTIONS.md](STD_ABSTRACTIONS.md) | Zig 0.16 stdlib map: Io/net/http plus posix residuals |
| [adr/README.md](adr/README.md) | Architecture decision records |

## Ops and UI

| Doc | Role |
|---|---|
| [WEBUI.md](WEBUI.md) | Operator web UI, security model, roadmap |

## Review prompts and their findings

The prompts under `prompts/` are named `*-review.md` so the review-loop tool
discovers them as project prompts. Each findings document is the output of one
run and is a snapshot, not a live inventory.

| Prompt | Findings |
|---|---|
| [prompts/zig-idiomatic-review.md](prompts/zig-idiomatic-review.md) | [ZIG_REVIEW.md](ZIG_REVIEW.md) |
| [prompts/abstractions-review.md](prompts/abstractions-review.md) | [ABSTRACTION_REVIEW.md](ABSTRACTION_REVIEW.md) |
| [prompts/simd-review.md](prompts/simd-review.md) | [SIMD_REVIEW.md](SIMD_REVIEW.md) |
| [prompts/ecs-soa-review.md](prompts/ecs-soa-review.md) | (folded into [ECS.md](ECS.md)) |
| [prompts/hardcoded-data-review.md](prompts/hardcoded-data-review.md) | [HARDCODE_AUDIT.md](HARDCODE_AUDIT.md) |

## Scale (parked until M11 numbers exist)

| Doc | Role |
|---|---|
| [SCALE_ARCHITECTURE.md](SCALE_ARCHITECTURE.md) | Substrate research; SpacetimeDB rejected |
| [PLANET_SCALE.md](PLANET_SCALE.md) | Shard, gateway and DEM plan |

## External RE (sibling repo)

| Doc | Role |
|---|---|
| [../../7dtd-research/docs/INDEX.md](../../7dtd-research/docs/INDEX.md) | Research hub |
| [../../7dtd-research/docs/protocol.md](../../7dtd-research/docs/protocol.md) | Envelope, join, goldens |
| [../../7dtd-research/docs/protocol-frames.md](../../7dtd-research/docs/protocol-frames.md) | Byte frames per package |

## Archive

Point-in-time reports. Kept for the evidence they carry, not maintained.

| Doc | Role |
|---|---|
| [archive/DECO_NRE.md](archive/DECO_NRE.md) | DecoManager.Read NRE investigation, RESOLVED |
| [archive/PLAYTEST_V310_20260803.md](archive/PLAYTEST_V310_20260803.md) | V3.1.0 stock-client playtest log, 2026-08-03 |

## Milestone snapshot (2026-08-06)

```text
Core playable loop     DONE  stock client joins, renders and plays Navezgane
                             (gate 23/23, combat has stakes, POIs correct)
M7-M10 core            DONE
M11 interest/scale     PARTIAL  dirty bitsets and observer masks shipped;
                                spatial cell hash and the bot gate remain
M12-M15 depth/ops      PARTIAL  see GAP_ANALYSIS: 99 WORKS / 150 PARTIAL / 96 MISSING
M16 / planet M2+       OPEN / parked
```
