# Deliberate divergences from the stock server

Every place zdtd knowingly behaves differently from the stock dedicated server,
with the stock behaviour, the reason, the cost, and what closing it would take.

This is the honest counterweight to the
[GAP_ANALYSIS](GAP_ANALYSIS.md) scorecard: a feature can be scored `WORKS`
against the wire and still not match stock's *behaviour*, because zdtd
deliberately refuses to reproduce it. Those cases live here so "100% compatible"
is never claimed without the asterisks.

Scope: behaviour, not internals. zdtd is a clean-room reimplementation and does
not copy stock's Mono architecture (AGENTS rule 8) - that is by design and is
not a divergence in the sense used here.

**Wire compatibility is not affected by anything on this page.** Every package
listed below is parsed and answered in the stock body shape; the divergence is
in what the server *does* with it, never in the bytes.

## 1. Client-authored state the server refuses to trust

These share one root cause: stock trusts the client for data zdtd's authority
model (AGENTS rule 17, [AUTHORITY.md](AUTHORITY.md)) says the server must own.
Reproducing stock here means accepting a documented cheat vector.

| # | Stock behaviour | zdtd behaviour | Why |
|---|---|---|---|
| 1.1 | `NetPackageEntityStatsBuff` applies the client's whole buff blob (`EntityBuffs.Read` IL=76) | Accepted, dropped; the server owns the buff set | A client could grant itself any buff |
| 1.2 | `NetPackagePlayerStats` relays the owning client's stats blob onto the entity (`EntityNetworkStats::ToEntity`, RE `progression.md` 441560ff) | Accepted, dropped; the server keeps its own XP/level ledger and sends that | A client could author its own level, XP and kill totals |
| 1.3 | `NetPackagePlayerInventoryForAI` feeds the AIDirector smell/threat model from a client-reported bag (RE `protocol-packages.md`, Process IL=23) | Accepted, dropped; AI reads sim state | A client could steer zombie targeting by declaring an inventory it does not have |
| 1.4 | `NetPackageEntityVelocity` / `EntitySpeeds` / `EntityPhysics` drive entity motion from the client | Server-authoritative knockback ships; client-driven physics does not | A client could teleport or fling entities |
| 1.5 | `NetPackageEntityAddExpServer` / `AddScoreServer` add client-reported XP | Accepted, dropped; XP is server-awarded on the kill/quest path | A client could mint XP |

**Known cost of 1.1**, stated rather than hidden: client-local consume buffs
(`onSelfPrimaryActionEnd` AddBuff, e.g. `buffProcessConsumables` and the disease
roll) never sync server-side, so dysentery-dependent behaviour such as smell
extension does not fire.

**Closing any of these** is an ADR-level decision that supersedes
[ADR 0007](adr/0007-player-inventory-c2s-trust.md) and amends AGENTS rule 17. It
is a real option - stock parity is a legitimate goal for a private server - but
it trades a security property and must be recorded as such, not slipped in.

### 1.6 The residual client-trust that already exists

Stated for symmetry, because the rule above is not yet universal: the player
*hold* inventory path (`NetPackagePlayerInventory`, player `NetPackageBag`) is
still client-trusting on C2S apply. [ADR 0007](adr/0007-player-inventory-c2s-trust.md)
accepts this with its consequence written down ("dupes / client-invented stacks
are possible on the hold path until full authority lands"). The direction of
travel is toward server authority, not away from it.

## 2. Fields with no truthful server-side value

Stock carries real numbers here only by relaying what the owning client sent
(see 1.2). Because zdtd drops that blob, it has nothing true to put in these
fields and sends `0` rather than inventing a value (AGENTS rule 3, missing beats
fake).

`totalItemsCrafted`, `distanceWalked`, `longestLife`, `currentLife`,
`totalTimePlayed` on `NetPackagePlayerStats`.

RE `loop.md`: the *local* player accrues `currentLife += deltaTime / 60` from
its own frame delta. A headless server has no frame delta and never receives
these. Synthesising server-side accumulators would produce numbers stock never
derived server-side.

Not in this group: `killedZombies` and `killedPlayers` are counted
server-side on the authoritative death path and do ride the wire.

## 3. Packages a headless server has no source for

Parsed and routed, never emitted, because the data does not exist without a
client renderer. Evidence they are not needed: a full `smoke-navezgane` session
(2 clients, 8 join passes, walk/jump/rejoin) logs zero `c2s_unhandled` packages,
so the stock client never sends them to us.

| Package | Why |
|---|---|
| `NetPackageDynamicMesh` | Client-side destroyed-block geometry; no server source |
| `NetPackageEmitSmell` | Client-supplied AI stimulus; accepting it re-opens 1.3 |
| `NetPackageAudio` | Client-local sound cue |
| `NetPackageBossEvent` | Client-side boss HUD banner |
| `NetPackageDiscordIdMappings` | Discord rich presence; no sim effect |
| `NetPackageLobbyRegisterClient` | Matchmaking lobby; a self-hosted dedi does not join one |
| `NetPackageInventoryKeepOpen` | Stock's own dedi handler is a thin unused path (RE `protocol-packages.md`) |

## 3b. Registry coverage audit (2026-09-02)

The section-3 list came from the 37-row wire table in GAP_ANALYSIS. That table
is not the whole registry, so this is the wider check, recorded so the next
reader does not have to redo it.

`src/wire/packages.zig` registers **191** package names. **105** have a C2S
handler in `src/server/c2s/`; of the remainder, **55** are never referenced
anywhere in `src/server/` at all. Cross-referencing those 55 against the stock
`ProcessPackage` tables in RE `protocol-packages.md` leaves **29** that stock
does have a server-side handler for.

None of the 29 is a live gap, for one of three reasons:

- **S2C-only in practice.** The biggest one, `NetPackageRangeCheckDamageEntity`
  (216 B), reads like a missing damage path but is not: RE `combat-damage.md`
  has `ServerNetSendRangeCheckedDamage` (IL=27) *send* it for area damage
  (explosions, traps), fanning to tracked players. zdtd emits the stock
  `NetPackageExplosionClient` on that path instead (`c2s/blocks.zig`), which is
  the same package stock sends from `Explosion` (RE `protocol-packages.md`
  6.15). Different package, correct behaviour.
- **Client-side or editor features** with no headless source: `AnimateBlock`,
  `AudioPlayInHead`, `DynamicMesh`, `Localization`, `ShowToolbeltMessage`,
  `PlayerLaserSight`, `ModifyCVar`, `SetProp`, `Debug`, the `Editor*` and
  `Wall*` volume packages.
- **Platform/matchmaking**: `DiscordLobbySecret`, `LobbyJoin`,
  `PlayerTwitchStats`, `NetMetrics`, `EAC` (EAC is off by design).

Empirical backstop: `dispatch.zig` counts and logs every unhandled C2S package,
and a full `smoke-navezgane` session (2 clients, 8 join passes, walk / jump /
rejoin) logs **zero**. A package the stock client actually sends us would show
up there, so the registry gap is inventory, not behaviour.

Corrected 2026-09-02 by an exhaustive in-process sweep (scenario
"every registered package id survives dispatch with a malformed body"): the
static grep above undercounted S2C-only packages. Dispatching all 191 ids
through the real handler chain as a `.playing` client shows **84 reach a C2S
handler and 105 are S2C-only** - the server builds and sends those, and a stock
client never sends one back, so having no C2S handler is correct. The 29-package
figure above was an artefact of comparing against the RE `ProcessPackage` table
rather than measuring; the per-package reasoning in it still holds.

Caveat, stated rather than glossed: loadgen drives a wide but not exhaustive
action set. It does not fire every stock verb (vehicles, drones, twitch
integration), so "zero unhandled" bounds the common play path, not every
possible client action.

### Enum-cast sweep (2026-09-02)

The save-format audit found a raw disk byte cast onto an exhaustive enum
(`persist.zig:1207`, `VehicleKind`), so the same question was put to every
`@enumFromInt` in `src/`. Result, recorded so it is not redone: no live defect.
Wire parsers all guard the ordinal first; `litenet/packet.zig` keeps `Property`
non-exhaustive by design; the remaining sites cast comptime field values or a
sentinel byte the process itself wrote, never external input.

One latent issue was fixed rather than left: the five wire guards used
hand-synced numeric bounds (`if (et_raw > 3)`). Every bound was correct, but
adding a variant would leave the guard rejecting a legal stock ordinal as
`InvalidEvent` while the enum said otherwise. They now derive the valid set
from the enum via `std.enums.fromInt`, with tests asserting that every declared
variant parses. The accepted range is unchanged.

### Cap symmetry sweep (2026-09-02)

Same question asked of the length and count caps: does the build side agree
with the parse side, and does each cap match the width of the field that
carries it. Most do. `stock_inv.zig:1163` (65535) and `stock_te.zig:383` (255)
guard exactly their prefix widths, and the `@min(len, 255)` in the S2C encoders
is the field range, not an invented limit.

One real defect came out of it, now fixed: `broadcastPoweredTriggerTe` sized
its outbound wire list with `max_te_wires` (8), which is the *parse-side* cap on
wires kept from an inbound body. The sim caps wires globally rather than per
node, so a trigger holding 12 edges was echoed as 8: the client was told the
node had fewer connections than the server believed. The outbound path now uses
`max_te_wires_out` (255, the u8 count field's real range) and the two constants
are documented as inbound and outbound rather than one being reused for both.
Beyond 255 edges on a single node the stock count field cannot describe the
list at all; that residual is a format limit, asserted at the call site.

## 4. Operator surface

Not wire-visible; these are zdtd's own admin console and config.

- `tp` stays a zdtd alias of `tele` (teleport another player by slot / entity
  id). Stock's server-side name is `teleportplayer`; flipping `tp` to stock's
  client-only meaning would break zdtd's WEBUI docs and playtest tooling for no
  operator gain.
- zdtd-only verbs keep their names and are marked `zdtd:` in the `help` index:
  `give`, `inv`, `unban`, `guardstats`, `guardclear`, `evidence`, `apm`,
  `wipeplayer`, `status`. Stock has no `give` (it has `giveself`/`givexp`).
- Ban and permission entries are keyed by login name, not a platform user id:
  zdtd has no stock user id to store, and inventing one would put a fabricated
  identity in an operator-visible list.
- The blood-moon frequency `0` disable is a zdtd policy addition; stock has no
  such value.

## 5. Not divergences

Recorded because they are easy to mistake for one:

- **Clean-room internals.** SoA ECS, serialize-once interest, the plugin host:
  all deliberate design (AGENTS rule 8), not behavioural divergence.
- **Unimplemented EAI tasks** (Dodge, Leap, RangedAttackTarget). These are
  blocked on missing subsystems (client animator state, MoveHelper physics, item
  actions) and are tracked as gaps in [GAP_ANALYSIS](GAP_ANALYSIS.md), not as
  decisions to behave differently.

## Keeping this current

When you add an accepted-and-dropped package or knowingly depart from stock
behaviour, add the row here and cross-reference it from the code site. The
accept-and-drop lists in `src/server/c2s/misc.zig` name this file directly.
