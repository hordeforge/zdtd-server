# PM NNNN: <the failure in one line>

Replace every placeholder. Write `pending` in a field you cannot fill yet.

- **Number:** PM NNNN
- **Date:** YYYY-MM-DD
- **Severity:** P0 | P1 | P2
- **Gates that missed it:** <gate name, exactly as run>
- **Fix:** pending | <commit or PR reference>

## What happened

The timeline in order: what was run, what was seen, what was expected.

## Effect

What a player, stock client or operator saw, in the frame it appeared.

## Root cause

The one defect, with `file.zig:LINE` and the declaration quoted verbatim.

## Why the gates passed

The gate that was green, the assumption it encoded, why this sat outside.

## What now catches it

The gate, test or assertion added, and the evidence it fails on old code.

## Links

The code, the tests, and the evidence artifact named in the record.

---

Register the record in [README.md](README.md): next free number, one row in the
records table, and a budget row in [budgets.json](../budgets.json). The frozen
record is never edited afterwards; only "what now catches it" gains the gate
once that gate exists.
