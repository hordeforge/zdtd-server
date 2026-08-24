# Requests for Comments — Technical Specifications and Designs (RFC)

RFC = request for comments, in the industry sense: the technical proposal
that answers a PRD's "what" (the "how"), circulated for review before the
decision is locked. It fixes the concrete contract the requirement needs
(boundary, layout, flow, caps, acceptance). Format varies per addon (spec,
design, implementation plan). Once the design is agreed, the decisions it
forced are recorded in ADRs of the same addon, and the RFC stays as the
record of what was proposed.

Status is one of: **draft**, **in review**, **decided**, **withdrawn**,
**superseded** (see each doc's `**Status:**` line). New RFCs start from
[TEMPLATE.md](TEMPLATE.md).

| RFC | Title | Status |
|---|---|---|
| [0001](0001-fps-bot-spec.md) | FPS Bot technical specification | decided (shipped; implements PRD 0001) |
| [0002](0002-mcp-server-design.md) | MCP server addon design | decided (implements PRD 0002) |
| [0003](0003-modlets-plan.md) | Modlet compatibility implementation plan | decided (shipped, localization phase descoped; implements PRD 0003) |
| [0005](0005-mod-tiers-and-override.md) | Module tiers and mod override: manifest model, discovery, override claims | decided (implements PRD 0005; ADR 0032) |

Numbering: 4-digit, zero-padded, never reused — next is **RFC 0006**. RFC NNNN
is the design counterpart of [PRD NNNN](../prd/README.md) for the same addon.

Adding an RFC: start from [TEMPLATE.md](TEMPLATE.md), take the next free
number, name the file `NNNN-kebab-slug.md`, put `**Number:** RFC NNNN` in the
header block, add a row to this registry and
to [INDEX.md](../INDEX.md), and keep cross-references (`RFC NNNN §N`, links) in
the paired PRD and the ADRs in sync.

Sibling series: [PRD](../prd/README.md) (product requirements) ·
[ADR](../adr/README.md) (architecture decisions).
