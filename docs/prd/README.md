# Product Requirements Documents (PRD)

> **Purpose:** registry and guide for PRDs — product requirements for each addon, paired with the RFC of the same number.

Numbered product-requirements documents for zdtd. Format: background →
scope → requirements (R1…) → acceptance. Status is one of: **draft**,
**in review**, **shipped** (see each doc's `**Status:**` line). New PRDs
start from [TEMPLATE.md](TEMPLATE.md).
**Related:** [RFC](../rfc/README.md) (design) · [ADR](../adr/README.md) (decisions) · [INDEX.md](../INDEX.md) (doc map)

| PRD | Title | Status |
|---|---|---|
| [0001](0001-fps-bot.md) | FPS Bot addon requirements | shipped |
| [0002](0002-mcp-server.md) | MCP server addon requirements | shipped |
| [0003](0003-modlets.md) | Pure XML/assetbundle modlet compatibility | shipped (localization send descoped, §8 G8) |
| [0004](0004-hot-restart.md) | Server hot restart: persistence + operator-session continuity | shipped (v1) |
| [0005](0005-mod-tiers-and-override.md) | Module tiers and mod override (core vs official vs user mods) | shipped (ADR 0032) |
| [0006](0006-honk-doors.md) | Vehicle horn opens trader doors | draft (design: RFC 0006) |
| [0007](0007-deco-suppression.md) | Decoration suppression (AllowDecorations) | draft (design: RFC 0007) |

Numbering: 4-digit, zero-padded, never reused — next is **PRD 0008**. PRD and
RFC numbers pair by addon: the design answering PRD NNNN lives in
[RFC NNNN](../rfc/README.md).

Adding a PRD: start from [TEMPLATE.md](TEMPLATE.md), take the next free
number, name the file `NNNN-kebab-slug.md`, put `**Number:** PRD NNNN` in the
header block, add a row to this registry and
to [INDEX.md](../INDEX.md), and keep cross-references (`PRD NNNN`, links) in
the addon's RFC and ADRs in sync.

Sibling series: [RFC](../rfc/README.md) (technical spec/design) ·
[ADR](../adr/README.md) (architecture decisions).
