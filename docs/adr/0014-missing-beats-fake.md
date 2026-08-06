# ADR 0014: Missing beats fake (stock wire and content fidelity)

- **Status:** accepted
- **Date:** 2026-08-04

## Context

A clean-room dedi is constantly tempted to "make the client stop erroring" by
sending incomplete package bodies, invented terrain shells, empty-but-wrong
journal blobs, or client-side Harmony that invents S2C data. Stock
`BinaryReader` paths fail hard on truncated or misordered fields; silent pad
zeros and dual almost-stock encoders create desyncs that look like random
client bugs.

zdtd's product bar is **stock client join and play** (EAC off) with honest
gaps, not a visually busy fake world.

## Decision

1. **Prefer missing over fake.** If a stock package cannot be built correctly
   (unknown TE, missing catalog, buffer too small), **omit** or send the stock
   empty/error form. Never truncate mid-field, zero-pad to a guessed size, or
   ship a second "almost stock" encoder for the same package shape.
2. **One stock shape → one builder** (`wire/stock_*.zig` / packages). Fix RE
   when evidence shows divergence; do not paper over with client mods that
   invent world data (server owns playability gaps).
3. **Stock content from install data** (XML, AssignIds, DTM, TTS), not
   hand-copied tables. Fail closed on unknown names (ADR 0010, ASSETS.md).
4. **Document gaps** in STATUS / GAP_ANALYSIS / TODO rather than faking
   completion in wire or UI.

## Consequences

- Join/play may lack features (deco trees, full journal, some TEs) while still
  remaining readable by stock `Read`.
- Implementers spend RE time instead of inventing bytes; loadgen goldens stay
  trustworthy.
- Client tooling (`7dtd-connect`, playtest) stays join/automation only.

## Alternatives considered

| Option | Notes |
|---|---|
| Fake shells to silence client errors | Desyncs and false STATUS; hard to unwind |
| Client Harmony inventing S2C | Moves authority off server; not a product path |
| Dual bot-only package layouts that diverge from stock | Violates "one shape → one builder" for production packages |
