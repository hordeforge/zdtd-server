# Postmortems

Dated incident records for zdtd. A postmortem is written once, when the
incident is understood, and frozen afterwards. It records what was known and
observed at the time, so a later change never rewrites the narrative: it fixes
the code, adds a new record, or edits only the "what now catches it" section
once the catching gate actually exists.

This is the only documentation tier where narrative is allowed. Every other
tier states what is. The tier map and the writing rules live in
[docs/AGENTS.md](../AGENTS.md); the rule that history belongs in git, an ADR or
a postmortem is one of them.

## What belongs here

A dated record of one defect or gate miss that reached a shipped state or a
real client. Both halves matter:

- It shipped. The failure was reachable from a release binary, a committed
  document or an operator's running server.
- A gate missed it. `make check` was green, the loadgen smoke passed, or no
  gate covered the path at all.

A defect stopped by an existing gate before it shipped is a fixed bug, not a
postmortem. Record that in the commit message and move on.

## What does not belong here

| Not here | Home |
|---|---|
| review snapshots and audit findings | [archive/](../archive/), [prompts/](../prompts/) |
| current behavior, wire layouts, type definitions | [subsystems/](../subsystems/README.md) |
| status: what works now, with the current gates | [STATUS.md](../STATUS.md) |
| decisions, with their rationale and consequences | [adr/](../adr/README.md) |
| deliberate departures from stock, with their cost | [DIVERGENCES.md](../DIVERGENCES.md) |

A finding that a review or an audit produced is a snapshot, not an incident:
it goes under [archive/](../archive/) even when it turns out to be real. Once
that finding reached a client, the incident it caused is a postmortem, and the
postmortem links the snapshot as its evidence.

## Naming and numbering

`NNNN-kebab-slug.md`, four digits, zero-padded. Take the next free number from
the table at the end of this page. Numbers are never reused, never reordered and
never renumbered: a withdrawn record keeps its number and says so in its
header.

The slug names the failure, not the fix or the ticket. Write
`0007-chunk-stream-stall-on-rejoin`, not `0007-fix-rejoin-crash`.

This README is the registry for the series, the way
[adr/README.md](../adr/README.md) registers the ADRs. Add the row in the same
change that lands the record.

## Header block

Every record opens with the same five fields.

| Field | Meaning |
|---|---|
| `Number` | the file's number, written `PM NNNN` |
| `Date` | the date of the incident, UTC, `YYYY-MM-DD` |
| `Severity` | `P0`, `P1` or `P2`, the priority vocabulary [STATUS.md](../STATUS.md) uses |
| `Gates that missed it` | the gate that should have caught this and did not, named exactly (`make check`, loadgen smoke, `make release`) |
| `Fix` | commit or PR reference once known; `pending` until then |

## Record structure

Sections in this order. [TEMPLATE.md](TEMPLATE.md) is the copy-paste skeleton.

1. **What happened.** The timeline, in order: what was run, what was observed,
   what was expected instead. Past tense, no diagnosis yet.
2. **Effect.** What a player, a stock client or an operator saw. User visible
   or client visible, not internal state, and with the frame in which it
   appears (`chunk stream`, `join`, `lobby`).
3. **Root cause.** The defect itself, with `file.zig:LINE` citations and the
   declaration quoted verbatim where the layout or the value matters. One root
   cause per record; a second cause is a second record.
4. **Why the gates passed.** The honest part. Name the gate that was green, the
   assumption it encoded, and why the failure sat outside it. A record that
   blames a person instead of a gate is unfinished.
5. **What now catches it.** The gate, test or assertion added or changed, and
   the evidence that it fails on the old code. If nothing catches it yet, say
   so plainly: an uncatchable failure is a deferred gate, not a closed record.
6. **Links.** The code and the tests, by `file.zig:LINE` and relative link.

## Evidence rule

A postmortem is written against evidence. A record without evidence is a
rumor.

Acceptable evidence, one or more per record:

- quotes from server, client or launcher logs, with the surrounding lines;
- an APM dump ([APM.md](../APM.md)), as a counter table or a section timer;
- a loadgen run: the command, the peer count and the output;
- an observation from the real stock client with EAC off;
- gate output, including the failing command and its exit status.

State which form the evidence takes and where it came from. A recollection
without an artifact does not qualify. A green round trip inside zdtd proves
self-consistency, never stock compatibility, so it cannot stand alone as
evidence for a stock behavior claim.

## Gates

`tools/check_docs.py` checks this tree for dead relative links, out-of-range
citations, drifted quoted blocks and the word ceiling in
[budgets.json](../budgets.json). The local run is:

```bash
python3 tools/check_docs.py --only docs/postmortem --all
```

Every page under this tree needs a budget row, the same way every `src/` file
needs a provenance row.

## Records

| PM | Date | Severity | Gates that missed it | Title |
|---|---|---|---|---|
| (none yet) | | | | |

The table starts empty. The first record takes 0001.
