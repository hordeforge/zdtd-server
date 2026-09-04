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
| 1.4 | `NetPackageEntityPhysics` (ToServer) mirrors the physics master's reported pos/rot/velocity (`ProcessPackage` IL=87) | Body validated, dropped | zdtd's movement, falling-block and vehicle sims are authoritative, so the report is a redundant echo; accepting it would let a client teleport or fling entities |
| 1.5 | `NetPackageEntityAddExpServer` / `AddScoreServer` add client-reported XP | Accepted, dropped; XP is server-awarded on the kill/quest path | A client could mint XP |
| 1.6 | `NetPackageEntityAddVelocity` adds the reported vector to the entity's motion and sets AirBorne (`Entity.AddVelocity` IL=10, Process IL=11) | Ownership-checked, then dropped: the handler only marks the entity dirty so the next replicate carries the server's own position | Same reason as 1.4. Accepting it would let a client launch any entity it owns, and the server already applies knockback itself on the damage path |

**Correction 2026-09-02.** Row 1.4 previously also named
`NetPackageEntityVelocity` and `EntitySpeeds` as client-driven motion zdtd
refuses. That was wrong in both directions. RE `protocol-packages.md` 5.5.5 has
`EntityVelocity` sent by `NetEntityDistributionEntry` to tracking players, so it
is S2C, and zdtd already emits it (scenario "replicate sends EntityVelocity for
a falling zombie"). `EntitySpeeds` likewise has a builder and a parser. Neither
was a divergence; listing them overstated the gap. The same RE section says an
authoritative server "can treat the report as a redundant echo", so the
remaining `EntityPhysics` drop is what stock's own design anticipates rather
than a departure from it.

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

The second, found 2026-09-02 while reconciling this page against
[GAP_ANALYSIS](GAP_ANALYSIS.md): **player saves are keyed by login name alone**
(`persist.zig` matches `cl.name` against the record name; ADR 0017). Stock keys
the player data file on `PrimaryId.CombinedString` (asm.il 1884842), a platform
identity the client cannot choose. On zdtd a client that picks another player's
name loads that player's save: inventory, level, XP, bedroll. `ServerPassword`
gates entry to the server, not identity between players already on it, so this
is live on any open or shared-password world.

This is a security divergence, not the naming inconvenience ADR 0017's
consequences describe ("two players cannot safely share one login name"). The
severity was recorded in GAP_ANALYSIS and not here, which is precisely the kind
of split this page exists to prevent. Closing it needs a save migration to a
platform-keyed identity (ZPV4-style bump or flagged extension), tracked in
GAP_ANALYSIS §10; ADR 0017 should be superseded rather than edited when it
lands.

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
handler and 105 are S2C-only**, so having no C2S handler is correct for those.
The 29-package figure above was an artefact of comparing against the RE
`ProcessPackage` table rather than measuring; the per-package reasoning in it
still holds.

**Corrected again 2026-09-04.** That paragraph used to say the server "builds
and sends" the S2C-only set. It does not: **55 of the 191 registered names are
never referenced anywhere in `src/server/`**, so they are registered for id
mapping only. Most are the categories already listed above (editor, Twitch,
EAC/encryption, client-side FX, mod API). Registration without a sender is the
right call for those - the negotiated name-to-id map has to match stock whether
or not we ever emit the package - but the claim that we emit all 105 was
wrong, and the distinction matters: "no C2S handler needed" and "we send this"
are different properties, and only the first was measured.

Of those 55, **39 are named somewhere in GAP_ANALYSIS or on this page** (the
never-sent non-goals list, the waived categories, the accept-and-drop rows).
The remaining **16 carried no note at all** before 2026-09-04:
`BlockLimitTracking`, `DecoResetWorldRect`, `DeleteChunkData`,
`EditorPrefabInstance`, `EncryptionRequest`, `EncryptionSharedKey`,
`EntityMapMarkerRemove`, `EntityPrimeDetonator`, `EntitySetPartActive`,
`EventPrefab`, `MinEventFire`, `OwnedEntitySync`, `POIWaypoint`,
`RegionMetaData`, `TeleportPlayer`, `WallVolumeRemove`. Each was checked
against the RE package table; none is a live gap, for these reasons:

- **Superseded by the package we do send.** `TeleportPlayer` (client
  `TeleportToPosition`) is covered by `NetPackageEntityTeleport`, which RE
  §5.5.2 gives as the encoded-jump path the client snaps to; the admin `tele`
  verb uses it (`admin_console.zig`). `WallVolumeRemove` pairs with
  `WallVolume`, already a documented non-goal. `EncryptionRequest` /
  `EncryptionSharedKey` belong to the encryption residual already waived as
  non-client-visible.
- **Needs a subsystem zdtd does not have.** `EditorPrefabInstance` and
  `EventPrefab` are editor/creative; `RegionMetaData`, `DeleteChunkData` and
  `DecoResetWorldRect` are chunk-authoring paths; `POIWaypoint` and
  `EntityMapMarkerRemove` are map-marker upkeep for markers we never set;
  `BlockLimitTracking` logs a discard server-side even in stock (Process
  IL=11); `OwnedEntitySync` tracks owned-entity lists (drones/turrets) zdtd
  does not keep; `EntitySetPartActive` is per-part vehicle damage state.
- **Effect not recorded in the RE.** `EntityPrimeDetonator` (Process IL=23:
  `PrimeDetonator()` on `EntityZombieCop`) and `MinEventFire` have no RE entry
  for what the client-side call actually does. zdtd already sends
  `NetPackageExplosionClient` for every cop blast, which is the visible
  outcome; whether the prime signal adds a wind-up cue is unknown. Same
  posture as `VehicleCount` below: not emitted on a guess.

### Two zdtd-shaped bodies under stock package names (2026-09-04)

Found while citing the body builders against the RE. Both are C2S-inbound only,
never sent to a client, and both are distinguished from the stock body by shape
before anything is applied, so a stock client is unaffected. Recorded because a
non-stock body riding a stock package name is exactly the thing that looks like
a wire divergence later.

- **`NetPackageVehicleSpawn`** also accepts a zdtd control body (`entityId` i32 |
  `op` u8 | `throttle` f32 | `steer` f32, fixed 13 bytes) for seat / unseat /
  drive. Stock's body is `entityType` i32 | pos Vector3 | rot Vector3 |
  ItemValue | `entityThatPlaced` i32 (write IL=24), a different shape for a
  different purpose. The handler gates on the exact 13-byte length
  (`c2s/misc.zig`), so a stock spawn body cannot be read as a control command;
  it falls through unhandled instead, which is the honest outcome given zdtd
  does not implement client-requested vehicle spawning.
- **`NetPackageInventoryTransactionRequest`** accepts a compact form beside the
  stock `InventoryTransaction.Write` op list. The stock layout is tried first
  (`parseStockInvTx`), so a real client always takes the stock path; the compact
  body exists for scenarios driving the same handler.

One of the 55 is not in a waived category and is recorded here rather than
buried in that list: **`NetPackageVehicleCount`** (body `vehicleCount i32 |
turretCount i32 | droneCount i32`, RE `netpackage-bodies.md` write IL=16). Stock
broadcasts it on channel 192 whenever a drone or turret unloads
(`DroneManager.RemoveTrackedDrone` IL=47, `TurretTracker.RemoveTrackedTurret`
IL=29), and the client mirrors the three values into its `serverVehicleCount` /
`serverDroneCount` / `serverTurretCount` statics (`SetServer*Count` IL=7 each).
zdtd tracks vehicles as ECS entities with their own mask, so the counts are
derivable; we simply never emit the package.

Not closed here because the RE does not record what the client *does* with those
mirrored statics: there is no documented `ProcessPackage` consumer, and no entry
in the coverage or closed-gaps notes. Emitting a packet on a guess about its
effect would be inventing behaviour. What is needed first is the consumer side
in `../7dtd-engine-research` (who reads `serverVehicleCount`, and whether an
unset value changes anything the player sees); if it drives a spawn cap or a UI
count, this becomes a real gap with a known cost rather than an unsent packet.

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

Continuing the sweep turned up a second defect of the same family.
`sendVendingTe` never passed `.allowed`, which defaults to an empty slice, so
every vending TE went out declaring zero allowed users. The C2S side stores the
list (`c2s/inv.zig`) and the save format persists it (`vending.zig`), but the
owner's client saw it empty on every reopen. The list is part of the stock
composite (`TileEntityVendingMachine::write`, asm.il ~440486: `i32 n | n x
ToStream`). Fixed, with the owner-gated vending scenario now parsing the echo
back and asserting the round trip.

The related cap pair is pinned too: the C2S handler sizes its parse scratch with
the store's `max_allowed_users` while `parseVendingTeBody` indexes that scratch
with the wire layer's `max_vending_allowed`. Both are 8 and nothing required
them to match, so raising one alone would have written past the other's buffer.
Since `world` must not import `wire`, the equality is asserted at the one place
both are in scope, verified to be a compile error when they diverge.

### TE composite field audit (2026-09-02)

The vending defect was a *builder* omission, not a parser one, so every
build/parse pair in `stock_te.zig` was checked the same way: which fields does
the format carry that the sender fills with a constant. Workstation and light
pass (the workstation sender populates all eight lists; storage takes the whole
container struct, so no field can be dropped by a caller).

One more real defect: `writeStorageFeature` hardcoded `worldTimeTouched` to 0.
The server tracks the touch day authoritatively (`containers.touched_day`, the
base `maybeRespawnContainer` uses for LootRespawnDays), and the receiving client
runs `TEFeatureStorage.UpdateTick` over the same field (RE `loot-economy.md`:
`daysElapsed = (WorldTimeToTotalHours(now) -
WorldTimeToTotalHours(worldTimeTouched)) / 24`). A constant 0 told every client
the loot was as old as the world. Now derived with the stock encoding, matching
`WorldClock.worldTimeBits` so both sides share an epoch.

Remaining constant in that feature, deliberate: `owner` is written as null
because zdtd containers store no owner ref, so there is nothing truthful to put
there. Missing beats fake.

### Spawn-package field audit (2026-09-02)

Same question put to the non-TE builders that take a field struct, where a
caller can omit a field and the default passes silently. `PlayerSpawnInfo` had
two: both `sendPlayerSpawns` sites passed `holding_item = null` while the server
tracks the held stack in `inventory[ps].holding`. An item switch is already
rebroadcast as `NetPackageHoldingItem`, so the effect was bounded but real: a
joiner saw everyone already present bare-handed until each next switched, and an
armed joiner looked bare-handed to everyone else. Fixed at both sites, with the
inbound and outbound halves separately pinned (each assertion verified to fail
with its own call site reverted).

`profile` stays null: zdtd stores no player appearance data (archetype, race,
hair, colors), and `PlayerProfile.Write` has no partial form. Inventing one
would put fabricated appearance on the wire, so the null flag is the honest
answer. `team_number` is 0 because zdtd has no team system.

One more from the same pass: `NetPackageEntityAddScoreClient` carries both kill
counters in one body (RE `protocol-packages.md` 27), and two of its three call
sites filled only `zombie_kills`, defaulting `player_kills` to 0. A trap or
explosion kill therefore told the client its PvP count had reset. Both sites now
pass the counter the server already tracks. The struct field lost its default, so
the compiler rejects a future site that fills only one, verified to be a compile
error rather than a convention.

That is the durable lesson from this whole sweep: a defaulted field in a builder
struct is a silent-omission hazard whenever the server has a truthful value for
it. Where the value always exists, drop the default and let the compiler enforce
it; where it genuinely may not (`profile`, container `owner`), keep the default
and say why here.

**Sweep closed 2026-09-04.** The remaining builder-input structs carrying
defaulted fields were enumerated and each sender checked against them:
`LightTeInfo`, `ActionsArgs`, `PartyDataArgs`, `SharedKillArgs`,
`BuffValueWire`, `SoundAtPosition`, `SetBlockTexture`. All fill every field for
which a truthful value exists. Two constants are deliberate and RE-backed:
`SetBlockTexture.player_id = -1` is what a dedicated server writes (IL=41,
IL_0018-0027), and `PartyDataArgs` has exactly one sender
(`social.zig:broadcastPartySnapshot`) which passes all seven. Five defects came
out of this sweep in total; it is now closed, so a future gap of this shape
needs a new mechanism rather than another pass.

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
