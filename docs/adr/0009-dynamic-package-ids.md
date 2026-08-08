# ADR 0009: Dynamic package name → id maps

- **Status:** accepted
- **Date:** 2026-08-04

## Context

Stock clients negotiate package ids via `NetPackagePackageIds` (name → u16).
Numeric package ids are **not** stable across game builds. Hard-coding ids in
server code causes silent mis-dispatch or join failure when the client map
shifts. Fixtures may pin maps for tests only.

## Decision

1. Resolve all runtime package traffic through a **negotiated name→id map**
   (`PackageIds` / `default_mappings` + peer resolve). Send by **name**; look up
   id at send/receive.
2. **Never** treat a bare numeric id as permanent outside test fixtures.
3. Catalog documentation ([PACKAGES.md](../wire/PACKAGES.md)) lists names and
   directions; ids are illustrative only.
4. Unknown or unmapped names: omit send or drop receive (fail closed), do not
   invent parallel id spaces.

## Consequences

- Wire code is slightly more indirect (string/name tables) but version-resilient.
- New packages require a name entry in the mapping table and a stock-shaped
  body builder, not a guessed constant id.
- Cross-version join still needs RE when **names** or body layouts change.

## Alternatives considered

| Option | Notes |
|---|---|
| Hard-code V3.0.1 numeric ids | Breaks on client rebuilds; forbidden by AGENTS |
| Custom protocol (no PackageIds) | Goal B only; abandons stock client |
| Full reflection dump every connect | Heavier than stock map exchange |
