# Adding a doc page

Every fact in `docs/` has exactly one home, and every page is reachable from a
registry. This recipe covers picking the tier, taking a number where the tier
numbers things, adding the registry and budget rows, writing under the citation
and quoting rules, and the gates that check all of it.

Read first: [`docs/AGENTS.md`](../AGENTS.md) (tier map, writing rules, gates),
[`docs/INDEX.md`](../INDEX.md) (the doc map), [`docs/budgets.json`](../budgets.json)
(word ceilings), [`docs/subsystems/README.md`](../subsystems/README.md) (the
reference registry) and [`tools/check_docs.py`](../../tools/check_docs.py) (the
gate itself).

## 1. Pick the tier

The tier table lives in [docs/AGENTS.md](../AGENTS.md), under "One home per
fact". Decide what the page is before naming it:

| The page carries | Tier |
|---|---|
| a type definition, wire layout, or how a subsystem is wired | `docs/subsystems/<topic>.md` |
| a decision already made, with its consequences | `docs/adr/NNNN-slug.md` |
| requirements for a feature | `docs/prd/NNNN-slug.md` |
| a design answering a PRD | `docs/rfc/NNNN-slug.md` |
| the reference for one subject | a subject file listed in `docs/INDEX.md` |
| a procedure a contributor follows | `docs/cookbook/<verb>-a-<thing>.md` |
| a dated incident record | `docs/postmortem/NNNN-slug.md` |

A behavior map belongs in `docs/ARCHITECTURE.md`; status belongs in
`docs/STATUS.md`; generated exhaustive tables belong under `docs/catalogs/` and
are never hand-edited (`docs/AGENTS.md:29`).

## 2. Take the number and the filename

Numbered series read the next free number from their own README, the registry
for that series. For example `docs/adr/README.md:45` states the next free ADR
number. Numbers are 4-digit zero-padded and never reused, and PRD and RFC
numbers pair by addon (root [`AGENTS.md`](../../AGENTS.md), "Docs: PRD / RFC /
ADR series").

1. Start from the series `TEMPLATE.md` and fill the header block.
2. Name the file `NNNN-kebab-slug.md`, where the slug names the thing, not the
   ticket.
3. Put `**Number:** <SERIES> NNNN` in the header block.

The other tiers are named, not numbered:

- A subsystem page is `docs/subsystems/<topic>.md`, one page per subsystem, and
  the name matches the subsystem, not the branch.
- A cookbook recipe is `docs/cookbook/adding-a-<thing>.md` or another verb
  phrase, one recipe per repeatable change.
- A postmortem takes its number from `docs/postmortem/README.md` and keeps it
  forever.

## 3. Add the registry row

A page that no registry links is invisible to a reader starting at the map, and
`tools/check_docs.py` fails it (`tools/check_docs.py:324-346`). Add the row in
the same change that lands the page.

| Page | Registry |
|---|---|
| subsystem page | a row in [`docs/subsystems/README.md`](../subsystems/README.md), alongside the `scenarios.md` row |
| cookbook recipe | a row in the table in [`docs/cookbook/README.md`](README.md), alongside the `adding-a-scenario.md` row |
| ADR / PRD / RFC | the series README table plus the document series section of [`docs/INDEX.md`](../INDEX.md) |
| subject reference | the owning section of [`docs/INDEX.md`](../INDEX.md), for example the Architecture table |
| postmortem | the records table in `docs/postmortem/README.md` |

The registry check is literal: the tree README must contain a link of the form
`(<page>.md)` (`tools/check_docs.py:341`).

## 4. Add the budgets.json row

Every page under `subsystems/`, `catalogs/`, `cookbook/` and `postmortem/` needs
a row in [`docs/budgets.json`](../budgets.json); a page without one is a config
error, the same way a new `src/` file without a provenance row is
(`tools/check_docs.py:286-291`). The gate counts words as
`len(text.split())`, so measure the page the same way:

```bash
python3 -c "import pathlib,sys; print(len(pathlib.Path(sys.argv[1]).read_text().split()))" docs/subsystems/<topic>.md
```

Set the ceiling slightly above the measured count. Ceilings are guardrails, not
reduction targets: a page at its ceiling relocates or condenses before it grows,
and raising a ceiling is part of the change that needs the room
(`docs/budgets.json:2`).

## 5. Write the page under the rules

The rules are in [docs/AGENTS.md](../AGENTS.md), under "Writing rules", with a
pre-flight list under "Slop checklist". The ones that change what you write:

- Document current state. History belongs in git, an ADR or a postmortem.
- One home per fact. If you are about to restate a rule or a table, link it.
- No em dashes and no AI attribution.
- No status annotations in reference prose ("implemented", "future work").
- Cite `file.zig:LINE` for every non-obvious claim about code, and mark
  anything you could not verify as unverified in one clause.
- Pick one wrap style for the page and keep it; tables and lists stay as they
  are.

A subsystem page carries a second contract: a `Sources:` line and a
`## See also` section, both enforced (`tools/check_docs.py:295-321`). Follow the
shape of a page already in the tree, for example
[`docs/subsystems/scenarios.md`](../subsystems/scenarios.md).

## 6. Cite file:LINE so the gate can resolve it

Use a repository-relative path in every citation. A bare filename resolves only
when exactly one file under `src/` ends with it; an ambiguous name is a failure,
not a warning (`tools/check_docs.py:100-117`). The cited line must exist:
a number past the end of the file fails the gate (`tools/check_docs.py:138-144`).

```text
src/server/evidence.zig:9-14     resolves, range checked
evidence.zig:9-14                resolves only while that basename is unique
```

Cite the range when a declaration spans lines, and re-check the numbers after
any edit that shifts the file.

## 7. Quote declarations verbatim

A fenced `zig` block is matched against the source named by the nearest
`file.zig:LINE` citation above it (`tools/check_docs.py:199-251`). Each non-blank
line must appear, in order, from the cited line onward; blank lines are skipped,
and a line that is only `// ...` or `// (something omitted)` is an allowed
elision. A `zig` block with no citation above it fails
(`tools/check_docs.py:223-225`).

Name the file and line above the block (docs/AGENTS.md, "Writing rules"), for
example
`src/server/evidence.zig:9-14`:

```zig
pub const Severity = enum(u8) {
    info = 0,
    soft = 1,
    strong = 2,
    hard = 3,
};
```

Only `zig` fences are checked. A `toml`, `bash` or `text` block is not compared
to source, so it still has to be true by hand.

## 8. Make every relative link resolve

Relative links only for repository files; a dead link fails the gate
(`tools/check_docs.py:84-97`). From a page under `docs/cookbook/`:

| Target | Link form |
|---|---|
| another `docs/` page | `../subsystems/scenarios.md` |
| a source file | `../../src/server/scenarios.zig` |
| a plugin directory | `../../plugins/core_killfeed/` |
| a sibling recipe | `adding-a-tunable.md` |

Absolute paths, `http(s)` links and in-page `#anchor` links are skipped by the
gate, so an in-page anchor is not verified either.

## 9. Run the gates

```bash
python3 tools/check_docs.py --only docs/<tree> --all
python3 tools/check_docs.py
make lint
```

The tree-scoped run is the fast loop: `--only` skips the budgets, registry and
page-contract checks (`tools/check_docs.py:372-375`), so a green scoped run is
not the gate. The full run adds those, and `make lint` runs it alongside the
architecture, wire, plugin-freshness and webui gates (`Makefile:158`).

## VERIFY

1. Run the scoped check while writing, then the full one from the repository
   root:

   ```bash
   python3 tools/check_docs.py --only docs/<tree> --all
   python3 tools/check_docs.py
   make lint
   ```

   The full run is the one that proves the registry row and the budget row are
   present.

2. Prove the citation check is load-bearing: add 1 to one cited line number on
   the new page, rerun `python3 tools/check_docs.py`, and confirm it reports the
   citation. If a quoted block was cited there, the same edit must also report
   the drifted block. Restore the number.

3. Prove the registry check is load-bearing: temporarily remove the page's row
   from its tree README and rerun the full check. It must report
   `has no registry row in the tree README`. Restore the row.

## See also

- [`../AGENTS.md`](../AGENTS.md) - the tier map, the writing rules and the gate
  list this recipe follows.
- [`../subsystems/README.md`](../subsystems/README.md) - the reference tier and
  the page contract its pages carry.
- [`../postmortem/README.md`](../postmortem/README.md) - the sibling tier with
  the same registry, budget and gate pattern.
