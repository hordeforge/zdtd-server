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

## Read first

New to the project, or picking up work:

1. [STATUS.md](STATUS.md) what works now, with the current gates.
2. [GAP_ANALYSIS.md](GAP_ANALYSIS.md) what does not, 329 features scored
   WORKS / PARTIAL / MISSING with anchors.
3. [WORK_PLAN.md](WORK_PLAN.md) what to build next, as self-contained tasks.
4. [../AGENTS.md](../AGENTS.md) the rules everyone works under.
5. [../TODO.md](../TODO.md) open backlog first; shipped log below the fold.
6. [RELEASES.md](RELEASES.md) version, compatibility, support, release policy.
7. [../CHANGELOG.md](../CHANGELOG.md) consumer-visible changes and migrations.
8. [RE_GAP_CLOSURE.md](RE_GAP_CLOSURE.md) open items turned into research specs.
9. [PROVENANCE.md](PROVENANCE.md) where every behavior/perk/value comes from in
   the stock game (file map 187/187 + constants ledger; gated by
   `tools/provenance_scan.py` in `make check`). Re-run the review with
   [PROVENANCE_REVIEW_PROMPT.md](PROVENANCE_REVIEW_PROMPT.md) (copy-paste
   agent prompt: method, gates, honesty rules).
10. [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) M7-M16 phases (post-playable
   stack).

## Wire and play path

What goes over the socket, and how it is proven against the stock client.

| Doc | Role |
|---|---|
| [wire/PACKAGES.md](wire/PACKAGES.md) | Full 190-package catalog |
| [wire/WIRE_CHUNK.md](wire/WIRE_CHUNK.md) | Chunk wire path |
| [wire/WIRE_WORKSTATION.md](wire/WIRE_WORKSTATION.md) | Workstation tile-entity wire |
| [wire/INVENTORY.md](wire/INVENTORY.md) | Inventory wire |
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
| [ZIG_CLONE.md](ZIG_CLONE.md) | M0-M6 architecture derived from the RE |
| [STATE_MACHINES.md](STATE_MACHINES.md) | All stateful lifecycles with diagrams (join, AI, quests, weather, plugins, peer) |
| [GAMEPLAY.md](GAMEPLAY.md) | Gameplay behavior flows (craft, trade, loot, survival, movement) |
| [ECS_SYSTEMS.md](ECS_SYSTEMS.md) | SoA simulation architecture and systems overview |
| [APM.md](APM.md) | Native metrics (`src/apm/`) |
| [PLUGIN_API.md](PLUGIN_API.md) | Wasm plugin design (ADR 0020) |
| [PLUGIN_DEV.md](PLUGIN_DEV.md) | Writing a plugin: hooks, limits, and building a .wasm from any language |
| [STD_ABSTRACTIONS.md](STD_ABSTRACTIONS.md) | Zig 0.16 stdlib map: Io/net/http plus posix residuals |
| [adr/README.md](adr/README.md) | Architecture decision records |

## Ops and UI

| Doc | Role |
|---|---|
| [WEBUI.md](WEBUI.md) | Operator web UI, security model, roadmap |

## Scale

| Doc | Role |
|---|---|
| [SCALE.md](SCALE.md) | M11 single-node scale switches + planet-scale shard plan (parked until M11 numbers exist) |

## Review prompts and their findings

The prompts under `prompts/` are named `*-review.md` so the review-loop tool
discovers them as project prompts. Findings live under `reviews/`: each is the
output of one run and is a **snapshot, not a live inventory**. That separation
is the point of the directory. When a review contradicts
[STATUS.md](STATUS.md), STATUS wins.

| Prompt | Findings |
|---|---|
| [prompts/zig-idiomatic-review.md](prompts/zig-idiomatic-review.md) | [ZIG_REVIEW.md](reviews/ZIG_REVIEW.md) |
| [prompts/abstractions-review.md](prompts/abstractions-review.md) | [ABSTRACTION_REVIEW.md](reviews/ABSTRACTION_REVIEW.md) |
| [prompts/simd-review.md](prompts/simd-review.md) | [SIMD_REVIEW.md](reviews/SIMD_REVIEW.md) |
| [prompts/ecs-soa-review.md](prompts/ecs-soa-review.md) | [ECS_REVIEW.md](reviews/ECS_REVIEW.md) |
| [prompts/hardcoded-data-review.md](prompts/hardcoded-data-review.md) | [HARDCODE_AUDIT.md](reviews/HARDCODE_AUDIT.md) |
| [prompts/zig-0.16-changelog-review.md](prompts/zig-0.16-changelog-review.md) | [ZIG_0_16_REVIEW.md](reviews/ZIG_0_16_REVIEW.md) |
| [prompts/zig-best-practices-review.md](prompts/zig-best-practices-review.md) | not yet run |
| [prompts/net-send-review.md](prompts/net-send-review.md) | not yet run |
