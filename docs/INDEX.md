# zdtd docs index

**RE gap closure (open items -> research spec):** [RE_GAP_CLOSURE.md](RE_GAP_CLOSURE.md)

**Conflict rule:** [STATUS.md](STATUS.md) is the living hub. If STATUS and
MISSING / IMPLEMENTATION_PLAN disagree on whether something shipped, **STATUS
wins**. Refresh inventory docs when closing work.

## Start here

| Doc | Role |
|---|---|
| [STATUS.md](STATUS.md) | What works now (gates + shipped surface) |
| [RELEASES.md](RELEASES.md) | Version, compatibility, support, and release policy |
| [../CHANGELOG.md](../CHANGELOG.md) | Consumer-visible changes and migrations |
| [../TODO.md](../TODO.md) | Open backlog first; shipped log below the fold |
| [MISSING_FEATURES.md](MISSING_FEATURES.md) | Gap inventory (honest PARTIAL sections) |
| [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) | M7–M16 phases (post-playable stack) |
| [../AGENTS.md](../AGENTS.md) | Project rules for agents and humans |

## Wire and play path

| Doc | Role |
|---|---|
| [PACKAGES.md](PACKAGES.md) | Full 190-package catalog |
| [PARITY_TOOLING.md](PARITY_TOOLING.md) | Version-diff + C2S coverage tooling |
| [CLIENT_PLAYTEST.md](CLIENT_PLAYTEST.md) | Stock-client automated play suite (design) |
| [WIRE_CHUNK.md](WIRE_CHUNK.md) | Chunk wire path |
| [WIRE_WORKSTATION.md](WIRE_WORKSTATION.md) | Workstation TE wire |
| [INVENTORY.md](INVENTORY.md) | Inventory wire |
| [MAPS.md](MAPS.md) | DTM / prefabs / TTS |
| [ASSETS.md](ASSETS.md) | XML load paths |
| [GAME_OPTIONS.md](GAME_OPTIONS.md) | serverconfig.xml → sim |
| [AUTHORITY.md](AUTHORITY.md) | Server-authoritative C2S gates + mode |
| [HARDCODE_AUDIT.md](HARDCODE_AUDIT.md) | Hardcoded data audit (Bucket A/B/OK) + zdtd.toml draft |
| [SIMD_REVIEW.md](SIMD_REVIEW.md) | SIMD/`@Vector` candidates (chunk density, worldgen, SoA) |
| [ZIG_REVIEW.md](ZIG_REVIEW.md) | Idiomatic Zig review findings |
| [ABSTRACTION_REVIEW.md](ABSTRACTION_REVIEW.md) | Abstraction keep/merge/delete verdicts |

## Architecture

| Doc | Role |
|---|---|
| [zig-clone.md](zig-clone.md) | M0–M6 architecture from RE |
| [ECS.md](ECS.md) | SoA sim |
| [SYSTEMS.md](SYSTEMS.md) | Systems overview |
| [AUTHORITY.md](AUTHORITY.md) | Join phase, C2S validation, interest, mode |
| [APM.md](APM.md) | Native metrics (`src/apm/`) |
| [PLUGIN_API.md](PLUGIN_API.md) | Native plugin design (proposed) |
| [adr/README.md](adr/README.md) | Architecture decision records |

## Ops / UI

| Doc | Role |
|---|---|
| [APM.md](APM.md) | Native metrics harness |
| [WEBUI.md](WEBUI.md) | Operator web UI design (HTMX + Alpine; design only) |
| [AUTHORITY.md](AUTHORITY.md) | C2S gates (admin/webui must not bypass) |

## Agent prompts

| Doc | Role |
|---|---|
| [PROMPTS/audit-hardcoded-data.md](PROMPTS/audit-hardcoded-data.md) | Stock XML vs zdtd config hardcode audit |
| [PROMPTS/review-zig-idiomatic.md](PROMPTS/review-zig-idiomatic.md) | Zig 0.16 idioms, comptime, hot-path no-alloc, std.Io, Zig Zen |
| [PROMPTS/review-abstractions.md](PROMPTS/review-abstractions.md) | When to build/keep/delete abstractions; layer fit; YAGNI scorecard |
| [PROMPTS/review-simd.md](PROMPTS/review-simd.md) | SIMD/`@Vector` candidates on dense hot loops; golden vs scalar |

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

## Milestone snapshot (2026-08-04)

```text
Core playable loop     DONE (playtest 83/83, 0 NRE; soft residuals in STATUS)
M7–M10 core            DONE
M11 interest/scale     PARTIAL (open 1.0 scale gate)
M12–M15 depth/ops      PARTIAL (honest gaps in MISSING)
M16 / planet M2+       OPEN / parked
```
