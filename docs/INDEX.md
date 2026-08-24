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
[`../../7dtd-engine-research/il/README.md`](../../7dtd-engine-research/il/README.md); those
line numbers are valid only against that exact file. The research repo tracks
the latest release only: its `il/` sets are all V3.1.0 and the V3.0.1 sets were
deleted on 2026-08-06. Mentions of V3.0.1 in these documents are provenance, and
any line number written before that date may be a V3.0.1 number, which drifts by
roughly 3500 lines in the NetPackage region.

## Read first

New to the project, or picking up work:

1. [STATUS.md](STATUS.md) what works now, with the current gates.
2. [GAP_ANALYSIS.md](GAP_ANALYSIS.md) what does not, 291 features scored
   WORKS / PARTIAL / MISSING with anchors (263 / 28 / 0).
3. [WORK_PLAN.md](WORK_PLAN.md) what to build next, as self-contained tasks.
4. [../AGENTS.md](../AGENTS.md) the rules everyone works under.
5. [../TODO.md](../TODO.md) open backlog first; shipped log below the fold.
6. [RELEASES.md](RELEASES.md) version, compatibility, support, release policy.
7. [../CHANGELOG.md](../CHANGELOG.md) consumer-visible changes and migrations.
8. [RE_GAP_CLOSURE.md](RE_GAP_CLOSURE.md) open items turned into research specs.
9. [PROVENANCE.md](PROVENANCE.md) where every behavior/perk/value comes from in
   the stock game (file map 198/198 + constants ledger; gated by
   `tools/provenance_scan.py` in `make check`). Re-run the review with
   [provenance-review.md](provenance-review.md) (copy-paste agent prompt:
   method, gates, honesty rules; picked up by `~/review-prompts`).
10. [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) M7-M16 phases (post-playable
   stack).

## Document series (PRD / RFC / ADR)

Numbered series, one directory per series; each series' README is its
registry. PRD and RFC numbers pair by addon (same number = same addon's
requirements and design). Convention: 4-digit zero-padded, never reused;
next number in each series is in its README.

| Series | Lives in | Registry |
|---|---|---|
| PRD (product requirements) | [prd/](prd/README.md) | [prd/README.md](prd/README.md) |
| RFC (request for comments: proposal / design) | [rfc/](rfc/README.md) | [rfc/README.md](rfc/README.md) |
| ADR (architecture decisions) | [adr/](adr/README.md) | [adr/README.md](adr/README.md) |

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
| [PLUGIN_STANDARDS.md](PLUGIN_STANDARDS.md) | Plugin naming standards + mod.toml format (binding rules for mods/) |
| [mods/BUILDING.md](../mods/BUILDING.md) | Building the core plugins from their Zig sources |
| [PRD 0001](prd/0001-fps-bot.md) | FPS Bot addon requirements (with [RFC 0001](rfc/0001-fps-bot-spec.md); ADR 0026) |
| [PRD 0002](prd/0002-mcp-server.md) | MCP server addon requirements (with [RFC 0002](rfc/0002-mcp-server-design.md); ADR 0031) |
| [PRD 0003](prd/0003-modlets.md) | Pure XML/assetbundle modlet compatibility requirements (with [RFC 0003](rfc/0003-modlets-plan.md)) |
| [PRD 0005](prd/0005-mod-tiers-and-override.md) | Module tiers and mod override requirements (with [RFC 0005](rfc/0005-mod-tiers-and-override.md); ADR 0032) |
| [STD_ABSTRACTIONS.md](STD_ABSTRACTIONS.md) | Zig 0.16 stdlib map: Io/net/http plus posix residuals |
| [IMPLEMENTATION_PLAN_BOTS.md](IMPLEMENTATION_PLAN_BOTS.md) | FPS bot execution plan (ADR 0026) |
| [PLUGIN_CONFIG_DISPOSITION.md](PLUGIN_CONFIG_DISPOSITION.md) | Plugin/config boundary review (ADR 0020/0026) |
| [RULES_CONFIG.md](RULES_CONFIG.md) | Tunables disposition (ADR 0021) |
| [XML_DATA_AUDIT.md](XML_DATA_AUDIT.md) | No-hardcode audit + `make check-xml-audit` gate |
| [q3-inspiration-notes.md](q3-inspiration-notes.md) | Bot brain reference notes (Q3/Doom 3) |
| [adr/README.md](adr/README.md) | Architecture decision records |

## Ops and UI

| Doc | Role |
|---|---|
| [WEBUI.md](WEBUI.md) | Operator web UI, security model, roadmap |
| [PRD 0004](prd/0004-hot-restart.md) | What survives a server restart: persistence inventory + operator webui session continuity |

## Scale

| Doc | Role |
|---|---|
| [SCALE.md](SCALE.md) | M11 single-node scale switches + planet-scale shard plan (parked until M11 numbers exist) |

## Review prompts and their findings

The prompts under `prompts/` are named `*-review.md` so the review-loop tool
discovers them as project prompts. Findings from a run are snapshots, not a
live inventory; the former `reviews/` directory was removed, and surviving
snapshots live under [archive/](archive/) (e.g.
[HARDCODE_AUDIT_2026-08-08.md](archive/HARDCODE_AUDIT_2026-08-08.md)). When a
review contradicts [STATUS.md](STATUS.md), STATUS wins.

| Prompt | Findings |
|---|---|
| [prompts/zig-idiomatic-review.md](prompts/zig-idiomatic-review.md) | archived (see `docs/archive/`) |
| [prompts/abstractions-review.md](prompts/abstractions-review.md) | archived (see `docs/archive/`) |
| [prompts/simd-review.md](prompts/simd-review.md) | archived (see `docs/archive/`) |
| [prompts/ecs-soa-review.md](prompts/ecs-soa-review.md) | archived (see `docs/archive/`) |
| [prompts/hardcoded-data-review.md](prompts/hardcoded-data-review.md) | [archive/HARDCODE_AUDIT_2026-08-08.md](archive/HARDCODE_AUDIT_2026-08-08.md) |
| [prompts/zig-0.16-changelog-review.md](prompts/zig-0.16-changelog-review.md) | archived (see `docs/archive/`) |
| [prompts/zig-best-practices-review.md](prompts/zig-best-practices-review.md) | not yet run |
| [prompts/net-send-review.md](prompts/net-send-review.md) | not yet run |
| [prompts/plugin-composability-review.md](prompts/plugin-composability-review.md) | not yet run |
