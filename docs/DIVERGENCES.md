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
| 1.4 | `NetPackageEntityPhysics` (ToServer) mirrors the physics master's reported pos/rot/velocity (`ProcessPackage` IL=87) | Body validated (exactly 58 bytes: Flags u16, EntityId i32, 13xf32; `GetLength` IL=2 = 58), dropped | zdtd's movement, falling-block and vehicle sims are authoritative, so the report is a redundant echo; accepting it would let a client teleport or fling entities |
| 1.5 | `NetPackageEntityAddExpServer` / `AddScoreServer` add client-reported XP | Accepted, dropped; XP is server-awarded on the kill/quest path | A client could mint XP |
| 1.6 | `NetPackageEntityAddVelocity` adds the reported vector to the entity's motion and sets AirBorne (`Entity.AddVelocity` IL=10, Process IL=11) | Ownership-checked, then dropped: the handler only marks the entity dirty so the next replicate carries the server's own position | Same reason as 1.4. Accepting it would let a client launch any entity it owns, and the server already applies knockback itself on the damage path |
| 1.7 | `NetPackageDropItemsContainer` creates a loot container from the client's item list (`DropContentInLootContainerServer`, Process IL=19) | Accepted, dropped | The bag is server-owned: `spawnDeathBag` builds it from the victim's real inventory on the authoritative death path. Accepting a client list is item duplication by construction |
| 1.8 | `NetPackageQuestGotoPoint` reports objective progress the client evaluated (read IL=43) | Accepted, dropped | The RE says outright that a server completing goto objectives by proximity "can treat the report as a redundant echo" (`protocol-packages.md` 5.13), and zdtd does exactly that: the radius check runs per tick in `ecs/systems.zig` against the quest target. `ObjectiveGoto::GetPosition` is also satisfied by the journal PositionData types 2/3 zdtd already sends, so a stock client does not ask |
| 1.8b | `NetPackageQuestTreasurePoint` (read IL=54) | **Answered since 2026-09-08** (was wrongly grouped with 1.8 as a progress echo) | Not an echo: it is a *request*. `ObjectiveTreasureChest::GetPosition` (`ObjectiveTreasureChest.il.txt:232`) asks the server whenever the quest carries neither PositionData TreasurePoint(4) nor TreasureOffset(8), and zdtd fills only 0..3, so a stock client always asks. Stock's server resolves a dig site and sends the package back to that player (`NetPackageQuestTreasurePoint.il.txt:242`, `SendPackage` at `:322`); dropping it left a treasure quest with no marker and no way to finish. zdtd now answers with a site anchored on the quest's POI (or the player), at the terrain surface. Actions 2/3 (UpdateTreasurePoint / UpdateBlocksPerReduction) remain accept-and-drop: those really are client reports |

| 1.9 | `NetPackageCloseAllWindows` carries a `_playerIdToClose` the receiving client uses to close its own modal windows | Accepted, dropped | Stock never handles it server-side: it is `ToClient` (`get_PackageDirection` IL=2 returns 2) and its `ProcessPackage` returns immediately when `ConnectionManager.IsServer`. zdtd relayed it to every other peer until 2026-09-04, which let any client close every other player's open UI |
| 1.10 | `NetPackageRequestToSpawnEntity` spawns the client's `EntityCreationData` through `GameManager.SpawnEntityServer` and answers with `NetPackageConfirmSpawnEntity` (V3.2.0 addition: `createdEntityId:i64` + `key:bytes[16]`, RE `changelog-3.2.0.md` §3.3, client Process IL=24) | Accepted, dropped; no confirm is sent | The generic ECD is a whole entity the client authored, and it proves neither item ownership nor a legal spawn class. The paths that need it are server-owned instead: `spawnDeathBag` builds the death bag from the victim's real inventory, and drop/throw validate and consume the server-side stack first. `buildConfirmSpawnEntityBody` exists and matches the stock layout so the answer can be wired the day a request path earns it; nothing calls it today |
| 1.11 | `NetPackagePartyData` is the leader/member snapshot the server fans to a party (party id, leader index, voice lobby, member ids, changed entity, action, disband) | Accepted, counted as an ownership reject, dropped | `ToClient` (`get_PackageDirection` IL=2 returns 2), so stock never reads one server-side. Party state is owned by `src/ecs/party.zig` and mutated only through `NetPackagePartyActions`; honouring a client-authored snapshot would let any client rewrite another party's membership and leadership |
| 1.12 | `NetPackageEntityAwardKillServer` reports a kill the client's local player scored (`killerEntityId:i32`, `killedEntityId:i32`) so the server runs `QuestEventManager.EntityKilled` | Body length-validated, dropped | `ToClient` per the IL, and zdtd already credits the kill authoritatively at the death path (`questOnZombieKilled` plus the XP award, covering melee, ranged, turret and trap kills). Applying the report as well would double-credit both the objective and the XP |
| 1.13 | `NetPackageAllyResponse` carries the resolved ally relationship back to a client | Accepted, dropped | `ToClient` (asm.il 886358). The relationship table is server-owned (`AllyStore::ComputeTransition`, `src/server/ally.zig`) and driven by `NetPackageAllyRequest`; a client-sent response would let one peer declare its own standing with another |
| 1.14 | `NetPackageEntityStealth` (read IL=9: `id:i32`, `data:u16`) carries the client's own stealth state - crouch, smell, eating, sheltered and alert packed into the u16 - and stock feeds it to the AI detection model | Body length-validated, dropped | zdtd derives stealth server-side: the crouch flag rides the movement frames, and the AI senses row takes smell from buffs. Trusting the reported word would let a client claim to be unsmellable while standing in the open. zdtd still *sends* the stock body S2C on change |
| 1.15 | `NetPackageEntityStatChanged` (read IL=24, `GetLength` 21: `entityId:i32`, `instigatorId:i32`, `enumStat:u8`, `value:f32`, `max:f32`, `maxModifier:f32`) is sent by a remote client from `EntityStats.SendStatChangePacket` (IL=65, the `world.IsRemote()` branch), and stock's `ProcessPackage` writes the reported numbers onto the entity's `Stat` and re-fans them to tracked players | Body length-validated, dropped | Health, stamina, food and water are sim state zdtd owns and replicates out through this same package (`replicate_health`, join). Applying the client's value would let a peer set its own health |
| 1.16 | `NetPackageGameEventResponse` (`GetLength` 30 head plus the event-name / target / extra strings) is switched on `responseType` by stock's `ProcessPackage` (IL=135). The one arm a stock client sends is `responseType` 11, from `BlockGameEvent.OnBlockDamaged`'s `!IsServer` branch, which makes the server run `GameEventManager.SendBlockDamageUpdate(pos)` and bump the sequence's `Damaged` event variable | Head length-validated, dropped | zdtd implements the request/approve half of game events (`NetPackageGameEventRequest` to `gameEventVerdict` to the response this server sends) and keeps no `GameEventActionSequence` state, so there is no `Damaged` variable for a client-reported hit to bump. Every other `responseType` is a client-side handler. Half-applying one arm would be worse than the documented gap |
| 1.17 | `NetPackageSharedPartyKill` (read IL=17: `entityTypeID:i32`, `xp:i32`, `entityID:i32`, `killerID:i32`) reaches the server from `GameManager.SharedKillServer`'s `!IsServer` branch (IL=162), forwarding a kill the sender's client scored so the server runs the party split | Body-validated, dropped | zdtd computes the split server-side in `killXpAward` (`Party.GetPartyXP` over `GameStats[54] party_shared_kill_range`) and fans the result out itself. Accepting the report would award the same kill twice |

**`AllowedBeforeAuth` checked, no divergence (2026-09-04).** Stock's third
per-package property gates *sending*, not receiving: `ClientInfo::SendPackage`
(IL=28) drops a package with a "not logged in yet" warning unless
`get_AllowedBeforeAuth` or `ClientInfo.loginDone` is set. Ten of the advertised
packages override it to true, and the eight zdtd does not handle are the
encryption and EAC handshake it deliberately omits (EAC-off); the two it does,
`PlayerLogin` and `AuthConfirmation`, are exactly its own `connecting_allow`
list. On the send side every fan-out path (`broadcastExcept`, `broadcastNear`,
and `broadcast` which delegates) skips a client whose `joined` is false, which
is the same gate under a different name. The six names in `joined_allow`
inherit `AllowedBeforeAuth = false`, which is correct: that phase is reached
only after a login is accepted. Nothing to change, recorded so the sweep is
not repeated.

**Datagram cap now matches stock (closed 2026-09-12).** The game's LiteNetLib
pins `MaxPacketSize` = 1432 and `PossibleMtu` = [1024, 1164, 1392, 1404, 1424,
1432] (`network.md`). From 2026-09-04 until 2026-09-12 `packet.max_packet_size`
was 1327, a value matching no stock MTU entry (an older LiteNetLib default
carried in), so `peer_mtu` was clamped below the client's final probe and large
S2C bodies fragmented into more parts than a stock server would send. The
constant is now stock's 1432, and the per-peer part/pending/hold buffers derive
from it (`max_single_user` / `max_fragment_user` / `pending_bytes`), so they
grew with it (about 21 KiB per peer across the three). Discovery was already
correct and is unchanged: `handlePacket` echoes every `MtuCheck` at the probe's
own size, so a stock client walks its full list and the last probe is the
negotiated size. `litenet/peer.zig`'s MTU test now pins the stock cap in both
directions (a 1432 probe negotiates 1432, a 1024 probe stays 1024, a 1500-byte
probe is clamped to 1432).

**`FlushQueue` is moot here (2026-09-04).** The last `NetPackage` property
that could carry a wire contract turns on a send queue zdtd does not have.
Stock's `ClientInfo::SendPackage` calls `INetConnection::AddToSendQueue` and
then `FlushSendQueue` only when `get_FlushQueue` is true (IL=28, IL_002E-004E);
eight packages override the base false, all of them handshake or bulk-metadata
sends that must not wait behind a batch. zdtd's `Peer.sendReliable` writes the
datagram straight to the socket, so every package is effectively flushed on
send and the property has nothing to select. It becomes relevant only if a
send queue is ever introduced - at which point these eight names are the set
that must bypass it, so they are written down rather than left to be
re-derived (each `get_FlushQueue() IL=2` returning `ldc.i4.1` in
`il/full-v3.2.0/_global/`): `NetPackageAuthConfirmation`,
`NetPackageAuthState`, `NetPackageDynamicMesh`, `NetPackagePackageIds`,
`NetPackagePersistentPlayerPositions`, `NetPackagePlayerDenied`,
`NetPackagePlayerLoginAnswer`, `NetPackageRegionMetaData`. With this, all eight `NetPackage` properties are
accounted for, though not all by the same mechanism. Channel, Compress and
ReliableDelivery are pinned by unit tests that walk the whole advertised table
against the IL-derived override sets. `PackageDirection` is not: it is
enforced at build time instead, by `provenance_scan` check 7i (below), which
reads the property out of the 3.2.0 IL and fails a C2S handler that claims a
`ToClient` name. `PackageId` is not a per-package constant at
all - `NetPackage::get_PackageId` (IL=4) looks the runtime type up in
`NetPackageManager`, which is the negotiated table zdtd advertises as
`default_mappings`; its invariants (no duplicate name, and `framed` stamping
the id `idOf` returns) are covered by a compile-time check and a test.
AllowedBeforeAuth and FlushQueue are recorded here as no-ops, and `Sender` is
server-set state rather than a wire field.

**Gated since 2026-09-04.** `provenance_scan` 7i reads
`get_PackageDirection` out of the 3.2.0 IL for every advertised package and
fails when a C2S handler claims a `ToClient` name that no row here mentions.
The phase gate cannot catch these on its own: it passes everything once a peer
reaches `.playing`. Row 1.9 is the case that motivated it, and the check was
verified against exactly that shape - with the old relaying handler restored,
7i fires where the accept-and-drop check (7d) stays silent, because a handler
that forwards the package is not dropping it.

**Widened 2026-09-06.** 7i read GAP_ANALYSIS as well as this file, so any
passing mention satisfied it - true for 41 of the 68 advertised `ToClient`
names, which made the check nearly inert. It now reads this file only, matching
what the paragraph above always claimed, and three handlers that had been
accepted on a bare GAP_ANALYSIS mention gained real rows: 1.11 `PartyData`,
1.12 `EntityAwardKillServer`, 1.13 `AllyResponse`.

The sibling accept-and-drop check (7d) had both weaknesses and one of its own:
it accepted a bare short-name word match (`Stealth`) anywhere in either doc,
and its "does this handler mutate anything" test was a fixed list of subsystem
prefixes, which read four real mutators (`PlayerDisconnect`, `MapPosition`,
`ConsoleCmdServer`, `QuestEvent`) as silent drops and would have accepted a doc
row for each. Both are fixed: 7d reads this file only and detects mutation by
`self.<name>` call or `c.<field> =` write. That leaves eleven true
accept-and-drops, one of which had no row - 1.14 `EntityStealth`.

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

## 1a2. Two relays still forward the raw client body

Most cosmetic relays now parse the body and forward `body[0..wire_len]`, so a
peer cannot append bytes and have the server fan them out
(`EntityRagdoll`, `SoundAtPosition`, `ParticleEffect`, `PlayerLaserSight`,
`EntityAliveFlags`, `EntitySpeeds`, `EntityTeleport`).

`NetPackagePlayerEquipment` and `NetPackageEntityAnimationData` joined them on
2026-09-09, once their bodies were modelled. **No relay forwards a raw client
body any more.**

`EntityAnimationData` is `entityId` i32 + a count i32 + that many
`AnimParamData` (`NetPackageEntityAnimationData.il.txt:58`), each a `hash` i32
+ a `type` u8 + a value the type sizes: Bool/Trigger a bool, Float/DataFloat an
f32, Int an i32 (`AnimParamData.il.txt:54`, enum at
`AnimParamData_ValueTypes.il.txt:3`). An unrecognised type throws in stock, so
zdtd rejects it too. The parameters stay opaque to the server; only the length
is used, to trim the relay.

**Equipment body, for the record.** `NetPackagePlayerEquipment` is `entityId` +
`Equipment::Write` (`Equipment.il.txt:1594`): a version byte (stock writes 4),
then one `ItemValue::Write` per slot where a null slot is the bare `0` its own
version field would carry, then from version 2 the cosmetic tail. There is
**no** presence bool. The slot count is the version (5 at <= 2, 8 at 3, else
the ctor's `ldc.i4.s 12`); `EquipmentSlots` lists 14 names but two are the
`Count`/`None` sentinels. This is a *different* shape from the equipment
section of `NetPackagePlayerInventory`, which goes through
`GameUtils::ReadItemValueArray` (u16 count + a bool per entry,
`GameUtils.il.txt:2205`). zdtd read the array shape for both until 2026-09-09,
so the standalone package consumed a bool that was really the next slot's
version byte.

## 1a5. Relay audience audit (2026-09-09), five gaps closed

Separate question from the body shapes above: not *what* is forwarded but *to
whom*, and on whose authority. Every `broadcast` / `broadcastExcept` /
`relayBodyExcept` call in `server/c2s/` was checked against its stock
`ProcessPackage` fan-out. Five diverged; all five are fixed.

- **`NetPackageWireToolActions`** was relayed after only a rate check.
  ProcessPackage (IL=254) opens with `ValidEntityIdForSender(entityID, false)`
  and its switch acts only on op 0/1, returning before either `SendPackage`.
  So a client could paint the wire-tool visual onto another player's hands.
  Now sender-gated, op-gated, and length-checked.
- **`NetPackageItemReload`** checked only that the id named *some* live
  entity. `GameManager.ItemReloadServer` (IL=32) rebroadcasts with
  `_allButAttachedToEntityId = entityId`, so stock excludes the *named*
  entity's client while zdtd excluded the *sender's*. Those agree only when
  the id is the sender's own, which the gate now requires.
- **`NetPackageSharedQuest` share, unreachable target.** zdtd fell back to a
  full broadcast when no peer held `sharedWithEntityID`.
  `GameManager.QuestShareServer` (IL=37) sends with
  `_attachedToEntityId = sharedWithEntityID`: exactly one client, and an
  absent target receives nothing. The fallback is gone.
- **`NetPackageItemActionEffects`** was relayed raw after only a rate check.
  `GameManager.ItemActionEffectsServer` (IL=87) rebroadcasts with
  `_allButAttachedToEntityId` = the *firing* entity, the same shape as
  ItemReload, so a foreign id claimed another player's weapon effects. Now
  parsed (read IL=39: entityId, slotIdx, actionIdx, firingState, a bool that
  when set is followed by startPos and direction as Vector3, then userData),
  sender-gated, and trimmed to the consumed length.
- **`NetPackageSharedQuest` member events (2, 3).** Broadcast to every peer.
  ProcessPackage (IL=371) routes both back to `sharedByEntityID` alone
  (`_attachedToEntityId`, IL_028A) and only when that player holds a Party.
  Now sender-gated and party-gated.

Audited clean in the same pass: `HoldingItem`, `Bag`, `EntityAliveFlags`,
`EntitySpeeds`, `EntityTeleport`, `EntityAttach`, `VehicleDataSync` (stricter
than stock: it also requires the sender to be the vehicle's driver),
`GameMessage` (stock passes `_onlyClientsAttachedToAnEntity = true`, which the
`joined` check already matches), and `EntityCollect` / `EntityRemove`, which
are built from sim state rather than relayed.

## 1a4. `NetPackageSimpleChat` is upgraded, stock drops it

A stock server receiving `NetPackageSimpleChat` **with no recipient list does
nothing**: `ProcessPackage` (`NetPackageSimpleChat.il.txt:109`) tests
`recipientEntityIds` at `IL_0015` and branches straight to the terminal `ret`
at `IL_012A` when it is null. Only the per-recipient loop sends anything, via
`ClientInfo::SendPackage` (`:IL_00A2`); the code after `IL_00C3` is the
client-side display path (`XUiC_ChatOutput::AddMessage`).

zdtd instead parses the sender name and message, rebuilds it as a stock
`NetPackageChat` with the server's own entity id, and broadcasts it
(`c2s/misc.zig`, the `SimpleChat` else-branch). So a `SimpleChat` a stock
server would silently discard becomes a visible global chat line here.

Kept deliberately: dropping it would make a bot or tool that speaks the older
package silently unheard, and the rebuild routes it through the same
sanitisation, rate gate and plugin filter as `NetPackageChat`, so it is not a
trust hole. Worth revisiting only if a stock client is observed sending
`SimpleChat` in normal play, which would then produce a line stock does not
show. zdtd's own loadgen resolves `SimpleChat` first
(`7dtd-loadgen ActionLoop.cs:597`), which is why this path gets exercised at
all.

## 1a3. Lock-context shapes, audited

Stock has three concrete `ILockContext` implementations and no two share a
serialized layout:

| Context | `Read` layout | IL |
|---|---|---|
| `EntityLockContext` | `Command` string, `FirstTimeTouched` bool, `hasBag` bool, then `Bag::Read` only when set | `Entity_EntityLockContext.il.txt:93` |
| `EntityTraderLockContext` | `Command` string, `hasTraderData` bool, then `TraderData::Read` only when set | `EntityTrader_EntityTraderLockContext.il.txt:38` |
| `VendingMachineLockContext` | `TraderData::Read` immediately, no command and no bool | `TileEntityVendingMachine_VendingMachineLockContext.il.txt:19` |

zdtd emits a context tail in two places. `buildLockResponse` (grant/deny)
echoes the request's tail verbatim, which is correct for any of the three.
`buildLockResponseTrader` builds one, and until 2026-09-09 it emitted the
entity shape for both trader kinds; it now keys off the type name the client
sent. Re-check this table if a fourth context appears, or if zdtd ever
synthesises a tail instead of echoing the client's.

## 1a6. Reach audit on claimed entity ids (2026-09-09), trader paths closed

The mirror of the relay audit above: not who receives a packet, but what a
packet may reach. Bounds rule 20 already covered claimed *coordinates*;
claimed *entity ids* were less consistent. Every `slotOfNetId` call in
`server/c2s/` was checked for what stops the id naming something across the
map. The four trader paths diverged, all in the same direction, and now
share one rule from `[sim] trader_use_range` via `inTradeReach`.

- **The trade itself.** `systems.trade` verified the id resolved to a trader
  with stock, never where the player stood, so a peer could buy and sell
  against every trader on the map from spawn.
- **The window open** (`NetPackageTraderData`, short body). Not passive:
  `questOnTraderOpen` advances `trader_interact` phases and completes a ready
  quest, paying its rewards. Ungated, that farms every turn-in on the map.
- **The quest-list exchange** (`NetPackageNPCQuestList`). Its `remove_quest`
  arm accepts the chosen offer into the journal and shares it with the party.
- The **TraderData echo** was already gated; it is what made the other three
  visibly inconsistent.

Note for anyone extending these: the leading i32 of a `NetPackageTraderData`
body is an entity id **only** when the header's `isEntity` byte is set.
Otherwise those bytes are a vending machine's tile-entity position. Parse the
header and branch; do not index the body.

Audited clean on this axis: the damage arms (ECS and host-bot branches both
gate on interest range), `EntityCollect` loot bags, `Bag` for non-player
inventories, `tryRefuelGenerator`, `tryRefuelVehicle`, and the `move.zig` id
lookups (all sender-gated before the lookup).

## 1b. Block updates are interest-scoped, stock's are global

`GameManager::SetBlocksOnClients` (`GameManager.il.txt:6841`) hands
`ConnectionManager::SendPackage` an `_allButAttachedToEntityId` of the editing
entity and `_entitiesInRangeOfEntity = -1`, so a stock server fans every block
change to **every logged-in client** and excludes only the editor. zdtd sends
`NetPackageSetBlock` through `broadcastNear` at `interest_range` (default 160
blocks) from 21 call sites, and includes the editor.

Both halves are deliberate, and both are visible at the edges:

- **Interest scoping** is AGENTS rule 19 (updates only to observing peers).
  The cost is a player further than `interest_range` from an edit does not see
  it until the chunk is re-streamed. Stock's own view distance can exceed 160
  blocks, so this is a real difference, not just a bandwidth saving. Raising
  `[authority] interest_range_blocks` narrows the window; setting it beyond the
  furthest view distance reproduces stock exactly at stock's bandwidth.
- **Including the editor** is the safe direction of the two. zdtd validates and
  may clamp or reject an edit, so the echo doubles as the correction that tells
  the client what actually landed. Stock omits it because its client applies
  the edit optimistically and the server agrees; a server that can disagree has
  to answer.

Re-check this row if `interest_range` ever stops being operator-tunable, or if
a block path starts relying on the editor *not* receiving its own echo.

**Entity removes are tracked-player scoped in stock.**
`NetEntityDistributionEntry::SendToPlayers` walks `trackedPlayers`, not every
client, and `NetPackageEntityRemove::ProcessPackage` (IL=24) logs
`NetPackageEntityRemove entity {0} missing` when the client is told to remove
something it never spawned. So a global remove writes an error line into every
distant player's log on every despawn. `broadcastKnown` (2026-09-09) sends
only to peers whose `known_entities` covers the slot, which is zdtd's
`trackedPlayers`. All four sim remove sites now use it:

- the distraction-bag despawn, which still holds a live slot when it sends;
- the turret kill, which sets hp 0 and a corpse timer without destroying, so
  the id still resolves (it falls back to the broadcast if the slot has gone);
- the corpse sweep and the far-mob cull, which destroy *before* reporting.
  Those two now hand back the slot alongside the id (`sweepCorpses` and
  `systemDespawnFar` take an optional parallel `out_slots`), because after
  `destroy` the id no longer resolves and the caller cannot recover it.

The cull was the one that mattered most: it fires continuously on a populated
map, so every distant player's log was taking a steady stream of those error
lines.

**The storage TE went the other way, and was fixed 2026-09-09.**
`NetPackageTileEntity::ProcessPackage` (IL=103,
`il/netpackages-v3.2.0/NetPackageTileEntity_il.txt`) rebroadcasts with
`_entitiesInRangeOfWorldPos = ToWorldCenterPos()` and `_range` 192, so stock
scopes TE updates by position. `broadcastStorageTe` used a plain global
broadcast while its two siblings (`broadcastVendingTe`, the powered-trigger
path) were already scoped, so every chest edit on the map reached every peer.
It now uses `broadcastNear` at `interest_range` like the rest. The receiving
client dropped those packages anyway when its own block at the position
disagreed, so the extra traffic bought nothing.

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
| `NetPackageAudio` | **Relayed since 2026-09-08** (was wrongly listed as a client-local sound cue). A client's `Audio.Manager::BroadcastPlay` falls through to `SendToServer` when it holds no `ServerAudio` (`Audio/Manager.il.txt:758-790`), and the dedicated server's `ProcessPackage` routes into `Audio.Server::Play`, which signals AI and relays a fresh package to every in-range player (`Audio/Server.il.txt:13-83` via `Audio.Client::Play`, `Client.il.txt:16`). 59 `BroadcastPlay` call sites include doors, storage, switches and locks, so dropping it left every other player in silence. zdtd now re-encodes and relays within interest range, excluding the sender; `signalOnly` bodies are the AI-stimulus form and are correctly not relayed (`Server.il.txt:29`) |
| `NetPackageBossEvent` | Client-side boss HUD banner |
| `NetPackageDiscordIdMappings` | Discord rich presence; no sim effect |
| `NetPackageLobbyRegisterClient` | Matchmaking lobby; a self-hosted dedi does not join one |
| `NetPackageInventoryKeepOpen` | Stock's own dedi handler is a thin unused path (RE `protocol-packages.md`) |
| Trader dialog chrome (`XUiC_DialogWindowGroup`, `dialogs.xml`) | Greeting, voice, and radial commands are client-local; a dedicated process has no dialog SM. Trading is lock + `traders.xml` |

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
  `Debug`, the `Editor*` and
  `Wall*` volume packages. Spelled out where a handler exists rather than only
  a registry entry: **`NetPackageEditorAddVolumeFromClient`** is accepted and
  dropped. Stock's world editor pushes authored volumes from a creative-mode
  client; zdtd loads volumes from the prefab data instead and has no editor
  session, so there is no server-side model for a client-authored volume to
  land in.
- **Server-side paths with no zdtd counterpart** (reclassified 2026-09-06;
  these three sat under "client-side or editor features", which the IL does
  not support). `ModifyCVar` is the buff CVar sync: a client reaches
  `SendToServer` through `EntityBuffs.SetCustomVarNetwork` (IL=33) and stock's
  `ProcessPackage` (IL=26) writes the value into the target's `EntityBuffs`.
  zdtd reads CVars out of the XML effect groups and holds no per-entity CVar
  table, so there is nothing for a reported change to land in. `SetProp` is a
  world prop change (`Block.PlaceProp` IL=87 to `WorldBase.SetPropRPC`, beside
  `SetBlockRPC`), sender-validated by user id and entity id, then fanned by
  `GameManager.SetPropsOnClients`; zdtd has no prop layer, so blocks are the
  only placeable world state. `SimpleRPC` (IL=17) carries the holding-item
  hooks - type 0 `ItemClass.OnHoldingItemActivated`, type 1 `OnHoldingReset` -
  which are client-side item callbacks with no server state to change. All
  three are unhandled: the package reaches the dispatch chain, raises the
  unhandled counter and is dropped, which is the correct fail-closed shape for
  a subsystem that does not exist here.
  `PlayerLaserSight` sat in this list too, on the same wrong reasoning, until
  the re-derivation showed it is a plain server relay (`ProcessPackage` IL=70
  re-sends the body to every client but the sender's). It is implemented now
  rather than waived, so it is no longer a divergence: see the GAP_ANALYSIS
  row. The lesson is the one this page keeps relearning - a wrong category is
  how a real gap stays invisible.
- **Platform/matchmaking**: `DiscordLobbySecret`, `LobbyJoin`,
  `PlayerTwitchStats`, `NetMetrics`, `EAC` (EAC is off by design).

Category audit 2026-09-06: the 98 client senders were re-derived from the
v3.2.0 IL independently of the original scan (same 98), and every one of the 16
without a handler had its `ProcessPackage` read to check the bucket it sits in.
Four buckets were wrong and are corrected above; `PlayerLaserSight` turned out
to be a real gap and is implemented. The buckets that held up: EAC/encryption
(off by design), `EditorUpdateVolume` (creative editor), `DynamicMesh` (gated
on `DynamicMeshManager.CONTENT_ENABLED`), `Debug` (no server branch at all),
and Twitch - `PlayerTwitchStats` does set player fields (`TwitchEnabled`,
`TwitchSafe`, `TwitchVoteLock`), but all three are Twitch-integration state,
so the label is accurate.

Gated since 2026-09-06 by `provenance_scan` 7j, the mirror of 7i: it recovers
the client senders from the IL the same way (walk back from each
`SendToServer` to the `GetPackage<T>` that supplies it) and fails on an
advertised name that reaches no C2S handler and has no stated reason. A name
the docs call `SHIPPED` or `WORKS` gets no doc excuse at all, since that claim
is precisely what has to match the code. Verified by mutation in both
directions: dropping the `PlayerLaserSight` handler fires it, and removing a
category entry for an ignored sender fires it too.

And 7k for the other direction: the 124 server senders recovered the same way,
failing on an advertised name no send path in `src/server/` passes to
`sendGame` / `sendGameCritical` / a broadcast / a relay. Matching any quoted
occurrence would not do - a test that looks the id up, or a doc comment naming
the package, would stand in for the emit, which is the confusion the check
exists to catch. Building it surfaced three more stale scorecard rows:
`EntityWaypointList` and `EntityAwardKillServer` were `SHIPPED` on a reading of
their `ProcessPackage` alone (both are client-local to receive and both are
things the *server sends*), and `DamageEntity full field semantics` said "the
builder emits" about a builder no send path calls.

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
and sends" the S2C-only set. It does not: **52 of the 191 registered names are
never referenced anywhere in `src/server/`** (55 when this was written; the
laser-sight relay and `SetAttackTarget` have since been implemented, and
`PlayerLaserSight` moved to the C2S side too), so they are registered for id
mapping only. Most are the categories already listed above (editor, Twitch,
EAC/encryption, client-side FX, mod API). Registration without a sender is the
right call for those - the negotiated name-to-id map has to match stock whether
or not we ever emit the package - but the claim that we emit all 105 was
wrong, and the distinction matters: "no C2S handler needed" and "we send this"
are different properties, and only the first was measured.

Re-derived 2026-09-06 from the IL rather than from this list: walking back from
every `SendPackage` / `SendToPlayers` / `SendPacketToTrackedPlayers*` call to
the `GetPackage<T>` that supplies it recovers **124 types the stock server
sends**, and every one of them is a name zdtd advertises, so the negotiated map
has no hole in this direction either. Cross-checking those 124 against what
`src/server/` emits is what surfaced `SetAttackTarget`: a package stock sends on
every AI target change, which zdtd computed and never published. The spot check
also re-verified three claims below against the IL - `TeleportPlayer` really is
covered by `EntityTeleport` (whose `SetPosAndRotFromNetwork` carries the
rotation the teleport package would), and `EntityPrimeDetonator` really is
client-side only (`PrimeDetonator` IL=23 sets a pulse rate, a red light and a
countdown, nothing else).

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
  `DecoResetWorldRect` are chunk-authoring paths; `POIWaypoint` is map-marker
  upkeep for markers we never set (`EntityMapMarkerRemove` sat here on the same
  grounds until 2026-09-10, when the air-drop crate marker became one we do set;
  it ships now, see GAP_ANALYSIS "Air-drop crate NavObject markers");
  `BlockLimitTracking` logs a discard server-side even in stock (Process
  IL=11); `OwnedEntitySync` tracks owned-entity lists (drones/turrets) zdtd
  does not keep; `EntitySetPartActive` is per-part vehicle damage state.
- **Client-local effect, read out of the IL 2026-09-06.** `EntityPrimeDetonator`
  is settled: `EntityZombieCop.PrimeDetonator` (IL=23) sets the `Detonator`
  component's `PulseRateScale`, turns its light red and starts the countdown
  animation. Purely the wind-up visual, no sim state, and zdtd already sends
  `NetPackageExplosionClient` for the blast itself. Not a gap.
  `MinEventFire` is a different shape: `Explosion` sends it with
  `MinEventTypes 19` when a remote entity dies to a blast (IL_0683), which
  fires the victim's client-side buff/perk event chain. zdtd has no MinEvent
  system at all, so this is one package of a whole absent subsystem rather
  than an unsent packet - closing it means the event model, not a builder.

### Six zdtd-shaped bodies under stock package names (2026-09-04, extended 2026-09-06)

Found while citing the body builders and parsers against the RE, and extended
by the parser audit two days later. All are C2S-inbound only, never sent to a
client, and each is distinguished from the stock body by shape before anything
is applied. Recorded because a non-stock
body riding a stock package name is exactly the thing that looks like a wire
divergence later.

The third one below was not distinguished at all until it was written down
here, which is the argument for keeping this list: the compact form was read
unconditionally and a stock client's turret placement was silently dropped.

**`NetPackageBlockTrigger` is rebroadcast where stock consumes it.** Stock
declares it ToServer (`get_PackageDirection` IL=2 returns 1) and handles it
entirely on the server: `ProcessPackage` resolves `NetPackage.Sender` to the
sending player and calls `Block::HandleTrigger`, whose server branch ends in
`TriggerManager::TriggerBlocks` (`Block.il.txt` IL=41, IL_0025-007C) without
emitting a package. A stock dedi never forwards it.

zdtd has no trigger-volume sim, so `c2s/blocks.zig` rate-gates the package and
broadcasts it to peers in interest range instead. The receiving clients do not
act on it: their `ProcessPackage` reads `Sender.bAttachedToEntity`, and
`Sender` is a `ClientInfo` the server sets, so on a client the branch falls
through. The rebroadcast is therefore inert traffic rather than a behaviour
difference a player can see - kept, and recorded here, until the trigger sim
lands and the broadcast can go.

The same sweep found `NetPackageBag`, also ToServer, echoed to other peers
after a vehicle-basket write (`c2s/inv.zig`). Stock's only sender is
`Entity::OnBagModified` (`Entity.il.txt` IL=15), which returns without sending
when `ConnectionManager.IsServer`, so a stock dedi never emits this package
either. The echo is how zdtd replicates a shared vehicle basket to the players
watching it; stock reaches the same end through its own entity replication.
Kept deliberately: dropping it would leave a passenger's basket view stale.
`NetPackageTraderData` is the third ToServer name zdtd sends, and it is the
same shape: `TraderData::SetModified` (`TraderData.il.txt` IL=11) returns
immediately when `ConnectionManager.IsServer` and only a client sends it
upward, so a stock dedi never emits it either. zdtd sends the trader's stock
on the join path because a joining client would otherwise see an empty
trader until it opened one; stock fills that from the client's own
`TraderData` copy. Kept for the same reason as the basket echo.

**`NetPackageLandClaimRepair` is repaired server-side since 2026-09-06.**
Found 2026-09-06 while auditing handlers with no scenario coverage; closed the
same day. Stock's `ProcessPackage` (**IL=33**, RE `protocol-packages.md` and
`server-lifecycle.md` section 6) resolves `TEFeatureAreaRepair` at the block
position and, on `beginRepair`, calls `RepairAll(world, blockPos,
sender.entityId)` server-side; ending repair clears `IsRepairing` for the
owner. It emits nothing, and since the fix neither does zdtd: the old code
broadcast the package to every peer, and a client receiving it runs the same
`ProcessPackage`, which tests `IsServer` at `IL_0022` and can only reach the
end-repair branch for its *own* claim - so the broadcast could clear another
player's `IsRepairing` by luck of position.

The repair itself (`repairClaimArea`, `server/game/world.zig`) walks the claim
square (`land_claim_size` 41, matching stock's ±22) and clears damage on every
damaged non-air block, fanning each fix as a `SetBlock` with damage 0 to
peers in interest range. The requester gets stock's `Setup(blockPos, false)`
answer. Ownership is enforced: outside any claim, or for someone else's claim,
the request is an ownership reject.

One conscious simplification, stated not glossed: stock's `repairBlock`
(IL=135) consumes `RepairItems` from the TE storage in proportion to the
damage fraction, and zdtd has no TE storage inventory, so the repair is free.
Charging for it means the TE storage subsystem, which is a larger row. Air
stays air on both sides - stock's loop skips it (`get_isair`), so destroyed
blocks are not rebuilt here either.

**A fourth zdtd-shaped body: vehicle control under `NetPackageVehicleSpawn`.**
Found 2026-09-06 auditing the parsers with no golden test. zdtd sends and reads
its own 13-byte body (`entityId i32 | op u8 | throttle f32 | steer f32`,
`buildVehicleControlBody` / `parseVehicleControl`) under the stock package
name, because stock has no C2S drive-input package at all: seat state rides
`NetPackageEntityAttach` and motion rides the physics/position packages that
zdtd refuses (1.4).

The length gate holds. Stock's `NetPackageVehicleSpawn::read`
(`il/netpackages-v3.2.0/NetPackageVehicleSpawn_il.txt` IL_0002-0020) is
`entityType i32`, two `StreamUtils.ReadVector3` (12 bytes each), an
`ItemValue`, then `entityThatPlaced i32` - at least 32 bytes before the item
value, so a stock body can never be 13 and can never be read as a control
body. `c2s/misc.zig` requires the exact length before parsing.

Recorded for the same reason as the three above: a non-stock body riding a
stock package name is what looks like a wire divergence later. It is C2S
inbound only. If a spawn path ever needs the real `VehicleSpawn` shape, the
length gate is what keeps the two apart, so it has to stay exact rather than a
minimum.

**Two more, found in the same audit: trade and quest-op.** Both are C2S
inbound only and both are already length-gated; they are listed so the set is
complete, not because either is newly at risk.

`parseTraderTrade` is a 9-byte `trader_entity i32 | item u16 | qty u16 | side
u8` under `NetPackageTraderData`. Stock has no trade package at all: a real
client's purchase shows up as its post-trade `TraderData` copy, which
`parseTraderDataToServer` handles under the same package name. `c2s/quest.zig`
keys the trade arm on **exactly** 9 bytes, and the comment there records why:
a stock ToServer body with `isEntity=false` and `hasTraderData=false` is 14
bytes whose `body[8]` is the high byte of `te_y`, zero for any real
coordinate, so a `>= 9` gate decoded it as a trade whose quantity came from
two coordinate bytes.

`parseQuestOp` is a 3-byte `def_id u16 | op u8` under
`NetPackageQuestObjectiveUpdate`, for unit and loadgen fixtures. It sits in
the `else` arm of `parseQuestObjectiveUpdate` in `c2s/quest.zig`, so a body
the stock parser accepts never reaches it; this one only sees what that parser
rejected.

**Distinguish by shape, and prove the lengths cannot meet.** A length only
discriminates when no stock body can reach it, and a stock body's length is
rarely fixed: it carries a `PlatformUserIdentifier` whose two strings vary with
the account. `parseSetBlockChanges` keyed a legacy layout off `body.len == 14`,
and 14 is reachable, because identity plus a zero count is
`6 + platform.len + id.len`: a player on `"Steam"` with a 3-character id sent an
empty change list and had it decoded as one block change with x/y/z read out of
the identity bytes. What it actually cost was a false edit attempt, not a world
edit: the first two identity bytes are the present bool and the version, both
1, so the decoded `x` is always around 1.4 billion and `withinEditReach` in
`c2s/blocks.zig` rejected every one of them. The bug was a parser inventing a
change the client never sent, one reach check away from applying it. Removed
2026-09-04.

The three below were re-checked against this rule and all hold with room to
spare: VehicleSpawn gates on exactly 13 against a stock minimum of 32, Turret
splits at 16 against a stock minimum of 28, and the TraderData trade arm takes
exactly 9 where a stock ToServer body is 6 or 14. Any new length gate needs the
same arithmetic written beside it.

**Counts read off the wire drive loops, and two of them have no cap.** The
storage TE slot count (i16) and the inventory bag count (u16) are read from the
client and looped on directly; both are bounded only by the body running out
mid-stack. Neither is a tick-budget problem (an iteration is 2 bytes at
minimum, so the i16 maximum costs under a millisecond of the 50 ms tick, and
the transport's 512 KB inflate cap is the ceiling on the body), and both fail
closed rather than truncating. What they rely on is the index guard inside the
loop: without it the bag loop writes past the ECS bag into the equipment slots.
Both behaviours are now pinned by tests (`stock_te.zig`, `stock_inv.zig`), and
the guard was verified by removing it and watching the test panic.

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
- **`NetPackageTurretSpawn`** accepts a compact 12-byte form of three i32 world
  coordinates beside the stock `entityType` i32 | pos Vector3 (3 x f32) | rot
  Vector3 | ItemValue | `entityThatPlaced` i32 (write IL=24). Until 2026-09-04
  the compact form was read unconditionally: a stock body's float bit patterns
  decoded as coordinates in the billions, the reach gate rejected them, and the
  client's turret never appeared. The handler now reads the stock float
  position for any body of 16 bytes or more; only loadgen and the scenarios
  send the shorter form. The rotation, `ItemValue` and `entityThatPlaced` tail
  is still not applied: zdtd turrets carry no rotation or source item, and the
  placer is taken from the sender rather than the body.

One of the 55 is not in a waived category and is recorded here rather than
buried in that list: **`NetPackageVehicleCount`** (body `vehicleCount i32 |
turretCount i32 | droneCount i32`, RE `netpackage-bodies.md` write IL=16). Stock
broadcasts it on channel 192 whenever a drone or turret unloads
(`DroneManager.RemoveTrackedDrone` IL=47, `TurretTracker.RemoveTrackedTurret`
IL=29), and the client mirrors the three values into its `serverVehicleCount` /
`serverDroneCount` / `serverTurretCount` statics (`SetServer*Count` IL=7 each).
zdtd tracks vehicles as ECS entities with their own mask, so the counts are
derivable; we simply never emit the package.

**Answered 2026-09-06 from the IL.** The consumer question above now has a
concrete answer, and it closes the item rather than promoting it. Each mirrored
static has exactly one reader: `VehicleManager.GetServerVehicleCount` (IL=13)
returns the real list count on the server and the mirrored static on a client,
and its only caller is `CanAddMoreVehicles` (IL=9). `TurretTracker` and
`DroneManager` are identical. So the value does drive a spawn cap - but the cap
is `DeviceFlags.IsCurrent(56)` gated, and 56 is the console flag set
(`XBoxSeriesS | XBoxSeriesX | PS5`), while `IsCurrent` masks against the build's
`Current`. On a standalone Linux dedicated the guard is false and both
`CanAddMoreVehicles` and its server-side counterpart in
`NetPackageVehicleSpawn.ProcessPackage` (IL_0014) return true unconditionally.
There is no UI reader at all: nothing outside those three managers touches the
statics.

The package is therefore console-only bookkeeping on this platform, not a
missing behaviour, and zdtd having no 500-entity spawn cap matches what a stock
Linux dedicated does. Still worth noting as a divergence from *console* stock,
which is why this paragraph stays.

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

**Sweep closed 2026-09-04, reopened once on 2026-09-10.** The remaining
builder-input structs carrying defaulted fields were enumerated and each sender
checked against them: `LightTeInfo`, `ActionsArgs`, `PartyDataArgs`,
`SharedKillArgs`, `BuffValueWire`, `SoundAtPosition`, `SetBlockTexture`. All
fill every field for which a truthful value exists.

`PlayerStatsArgs` was not on that list and had the same defect in the same
field. `EntityNetworkStats.write` carries `holdingItemStack` right after
`killed`, and stock fills the whole struct from the entity; both zdtd senders
(`game/player.zig` broadcastPlayerStats, `game/join.zig` sendPlayerStatsTo)
left `held_item` at its default. Every progression push and every join snapshot
therefore told the other clients the player was empty-handed. Same field, same
cause, and the spawn package's own fix in this section did not reach it because
the enumeration was of structs, not of the field. The default is gone now, so
the compiler rejects a third site that omits it (verified: removing it fails
the build, naming the join site). Two constants are deliberate and RE-backed:
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
  decisions to behave differently. Per-class XML lists now omit them rather
  than mapping them onto ApproachAndAttackTarget.
- **A `DayNightLength` over 400 real minutes freezes world time.** Stock's
  `TimeOfDayIncPerSec` is `24000 / (DayNightLength * 60)` in integer arithmetic,
  so past 400 the result is 0 ticks per second and time does not advance. zdtd
  runs that same expression, so this is stock fidelity, not a policy choice
  (the serverconfig range still allows 10..1200; an operator who wants a slow
  day should stay at or under 400, where the rate is 1 tick/s).

## 6. World-clock sim policy

Behaviour the wire cannot see, but a player can.

| # | Stock behaviour | zdtd behaviour | Why |
|---|---|---|---|
| 6.1 | The dedicated server pauses world time while no players are connected (`server-lifecycle.md` 5, live-observed 2026-08-11) | `WorldClock.tick` advances unconditionally, so a server with nobody on it still runs through days, horde nights and weather | zdtd has no stock "session" to hang the pause on and a running clock keeps the persisted day, blood-moon schedule and loot respawn honest across a wipe; the cost is that an idle server burns through its scheduled events instead of holding them |
| 6.2 | A fresh stock world spawns hostiles lazily: `listents` at join is players only, and zombies/animals appear later through the AIDirector near players | zdtd seeds the near-spawn demo hostiles at world init (2 zombies, a sleeper, an animal; `server/game/init_world.zig`) so a fresh world has something to fight and the demo turret has targets | the demo set exists for the offline/loadgen path and for a lone joiner on an otherwise empty world; the hostiles are switchable (`[sim] starter_zombies = false`), and the worldgen spawner/director rules are unchanged. Scope corrected 2026-09-12 (hardcode audit B2): the switch covers the hostiles only - Trader Jen, the minibike, the seed chest and the virtual generator + turret seed **still place unconditionally**, so `starter_zombies = false` is not a stock-lazy fresh world until one `[sim] demo_seed` switch wraps them. Cost of the default: a player who joins immediately can meet the seeded zombies before the lazy spawner would have produced any |

## Keeping this current

When you add an accepted-and-dropped package or knowingly depart from stock
behaviour, add the row here and cross-reference it from the code site. The
accept-and-drop lists in `src/server/c2s/misc.zig` name this file directly.
