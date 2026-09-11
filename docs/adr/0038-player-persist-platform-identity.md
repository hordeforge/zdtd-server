# ADR 0038: Player persist identity is the platform account, not the login name

- **Status:** accepted
- **Date:** 2026-09-11
- **Related:** supersedes [0017](0017-player-identity-login-name.md) · [DIVERGENCES](../DIVERGENCES.md) 1.6 · [GAP_ANALYSIS](../GAP_ANALYSIS.md) §10

## Context

ADR 0017 keyed `players.zsv` on the login display name because platform ids
were "optional, version-sensitive, and not fully wired on the EAC-off research
path". That was true when it was written; the identity path has since landed.
`Client.puid_primary` / `puid_native` are parsed from
`NetPackagePlayerLogin` (`PlatformUserIdentifierAbs.FromStream`, asm.il 30604),
persisted, used for the PersistentPlayerState snapshot, and are what the
admin/whitelist/ban gates already key on. The client does not choose them.

Leaving the save keyed on the name made identity theft trivial and live: any
client can type another player's display name and the server loads that
player's inventory, level, XP and bedroll. `ServerPassword` gates entry to the
server, not identity between players already on it, so this was reachable on
any open or shared-password world. DIVERGENCES 1.6 recorded the severity, and
stock's own key is `PrimaryId.CombinedString` (asm.il 1884842).

The competing option - keep the name key and rely on operators to police names
- is what ADR 0017 chose, and it is not a mitigation: the theft needs no
operator mistake, only a client that lies about its name.

## Decision

`players.zsv` rows are keyed on the owner's **platform identity**
(`puid_primary`), carried in the record as a ZPV15 tail (magic byte 'F'). The
login name is a **legacy fallback only**: a row that carries no identity (a
pre-ZPV15 record) matches by name once, gains the identity on the next save,
and is identity-only after that. A row that carries an identity is restored and
merge-written by identity alone - a matching name is not enough, and an absent
or different identity never inherits it (fail closed).

## Consequences

- Snatch-by-name is closed for any row that has been saved since ZPV15.
- A rename no longer splits a player into two rows: the identity is the key, so
  the display name follows the account. ADR 0017's "rename creates a new row"
  consequence is reversed.
- The pre-ZPV15 window is a one-time migration: the first login of an existing
  world still matches by name, so the operator should bring accounts online
  before opening the world if the legacy names are not trusted.
- A client that presents **no** platform identity cannot load an
  identity-bearing row. The loadgen bots present none, so they never persist a
  row and never collide with one. A future bot identity would need a configured
  `puid`.
- `wipeplayer <name>` stays a name operation (an operator may not know the
  account), and `zpv2DropName` carries the identity section through so a wipe
  does not corrupt the rows it keeps.
- Adding a further identity field (for example custom data) is another tail
  extension on the ZPV15 section, not a reuse of an existing byte.
