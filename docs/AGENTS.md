# AGENTS.md - the documentation standard

This file defines where each fact lives in `docs/`, the writing rules, and the
gates that keep the documents honest. The root [AGENTS.md](../AGENTS.md) carries
standing orders (including: no em dashes, no AI attribution, evidence needs an
IL anchor or a client observation); this file carries the subtree rules.

## One home per fact

Each fact has exactly one home. Everywhere else, link to it.

| Tier | Job | Does not belong there |
|---|---|---|
| Root [AGENTS.md](../AGENTS.md) | standing orders an agent needs every session | stories, worked examples, procedures |
| This file | tier map, writing rules, gate list | subsystem details, status, decisions |
| [ARCHITECTURE.md](ARCHITECTURE.md) | ordered behavior map: composition, the tick, the seams; read before changing `src/` | type definitions (to `subsystems/`), decision rationale (to ADR), status |
| [subsystems/](subsystems/README.md) | one reference page per subsystem: type definitions, wire layouts, and the wiring around them | behavior narration (to ARCHITECTURE.md), stock departures (to DIVERGENCES.md) |
| [STATUS.md](STATUS.md) | what works now, with the current gates; the living hub | design, plans, feature scoring |
| [GAP_ANALYSIS.md](GAP_ANALYSIS.md) | feature scoring WORKS / PARTIAL / MISSING with anchors | task breakdowns (to WORK_PLAN.md) |
| [WORK_PLAN.md](WORK_PLAN.md) | self-contained tasks for what to build next | shipped status (to STATUS.md) |
| [DIVERGENCES.md](DIVERGENCES.md) | every deliberate departure from stock behavior, with its cost | stock-fidelity claims that are not departures |
| [adr/](adr/README.md), [prd/](prd/README.md), [rfc/](rfc/README.md) | decisions that were made, requirements, designs under review | current behavior (link the subsystem page) |
| [wire/](wire/PACKAGES.md) | the package catalog and per-path wire notes | generic codec detail (to subsystems/wire.md) |
| [PROVENANCE.md](PROVENANCE.md) | where each behavior, perk and value comes from in the stock game; generated and gated | prose explanations |
| Subject references: [ASSETS.md](ASSETS.md), [GAME_OPTIONS.md](GAME_OPTIONS.md), [RULES_CONFIG.md](RULES_CONFIG.md), [MAPS.md](MAPS.md), [WORLDGEN.md](WORLDGEN.md), [GAMEPLAY.md](GAMEPLAY.md), [STATE_MACHINES.md](STATE_MACHINES.md), [AUTHORITY.md](AUTHORITY.md), [APM.md](APM.md), [WEBUI.md](WEBUI.md), [SCALE.md](SCALE.md), [RE_GAP_CLOSURE.md](RE_GAP_CLOSURE.md) | the reference for that one subject | restating another subject's reference |
| [glossary.md](glossary.md) | one canonical term per concept | implementation detail (link the owner) |
| [testing.md](testing.md) | what each gate proves, and the rules that keep a green suite meaningful | command lists (root AGENTS.md owns them) |
| [cookbook/](cookbook/) | numbered how-tos with a verify step | design rationale (to the ADR or RFC) |
| [catalogs/](catalogs/) | generated exhaustive tables: config keys, admin verbs, save formats, module graph; never hand-edited | hand-written reference (to `subsystems/`) |
| [postmortem/](postmortem/) | dated incident records: what happened, what the gate missed | the only tier where narrative belongs |
| [prompts/](prompts/) | review prompts and their findings | live inventories (findings rot; STATUS wins) |
| [archive/](archive/) | frozen snapshots, never current authority | anything current |
| [INDEX.md](INDEX.md) | the doc map and the conflict rule | duplicated content |

Placement: a bug goes to a postmortem; rationale to an ADR; a procedure to the
cookbook; a type to `subsystems/`; behavior to ARCHITECTURE.md; status to
STATUS.md.

## Writing rules

- Document current state. History lives in git, an ADR, or a postmortem.
- One home per fact. If you are about to restate a rule or a table, link it.
- Cite `file.zig:LINE` for every non-obvious claim about code. Stock claims
  need an IL anchor (`../7dtd-engine-research/il/`), a loadgen golden, or an
  observation from the real client. A green zdtd round trip proves
  self-consistency, never stock compatibility.
- Quote declarations verbatim in fenced blocks and name the file and line above
  the block. `tools/check_docs.py` fails a block that no longer matches source.
- Relative links only for repository files. Dead links fail the same gate.
- No em dashes. No AI attribution. Prose is either one paragraph per physical
  line (what the subsystem pages do) or hard-wrapped at 80 columns (what the
  older references do); pick one per page and leave tables and lists as they
  are. No wrap gate exists, deliberately: adding one would force a reflow of
  every standing reference to catch no defect.
- No status annotations in reference prose ("implemented", "future work").
  STATUS.md owns status; a reference states what is.
- Mark anything you could not verify as unverified in one clause. Missing beats
  fake in documents too.

## Gates

| Gate | Checks | Runs in |
|---|---|---|
| `tools/check_docs.py` | dead relative links, `file:LINE` out of range, quoted `zig` block drift, registry rows, the subsystem page contract, word budgets | `make lint` |
| `tools/gen_docs_catalogs.py --check` | `docs/catalogs/` is fresh from source | `make check` |
| `tools/provenance_scan.py` | every `src/` file has a PROVENANCE row | `make check` |
| `scripts/gen_provenance.py` | `docs/provenance.html` is fresh | `make check` |
| `scripts/lint-architecture.sh` | package edges and `root.zig` barrel coverage | `make lint` |
| `scripts/lint-webui.sh` | webui TypeScript and page freshness | `make lint` |

## Slop checklist

Run this list over any doc change.

- Duplicated rules: grep a distinctive phrase; keep one home, link the rest.
- Hand-restated catalogs, tables or inventories where a generator exists or
  should exist.
- Status annotations and roadmaps inside reference prose.
- Reasoning transcripts: step-by-step narration of how the code was derived,
  test walkthroughs, rejected local alternatives.
- Paragraph walls carrying several rules at once.
- Emphasis inflation: bold and CAPS everywhere means nothing stands out.
- Spec-speak in an implemented reference ("should", "will eventually").
- A quoted block that drifted from source, or a line number that moved.
- A stock-fidelity claim with no anchor.

## Adding a document

1. Pick the tier from the table above; a reference goes to its owning subject.
2. Take the next number from the series README for a numbered series.
3. Add the row to the owning registry ([INDEX.md](INDEX.md), the series README,
   or [subsystems/README.md](subsystems/README.md)) and to
   [budgets.json](budgets.json).
4. Write it under the rules above, then run `make lint`.
