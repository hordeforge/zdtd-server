# Changelog

Consumer-visible changes are recorded here. The project follows the release
and compatibility rules in [docs/RELEASES.md](docs/RELEASES.md).

## [Unreleased]

### Fixed

- Stealth crouch and light rode one `NetPackageEntityStealth`. Stock's three
  `Setup` overloads are mutually exclusive: the crouch form sets `data` to
  exactly 0 or 1, while the light form packs
  `(byte)lightLevel | ((noise & 127) << 8)` plus bit 15 for alert. zdtd ORed
  the crouch flag into the light form, and the client reads the light level as
  `(byte)data`, so a crouching player reported light+1 and even light values
  could not be expressed. The two forms now ship as separate packages.
- `readTraderDataBody` parsed the `TierItemGroups` block as a name string plus
  a u8 count plus u16 ids. Stock reads each group through
  `GameUtils::ReadItemStack` (u16 count + `ItemStack` per entry). Stock
  traders.xml ships no `<tier_items>`, so a stock client always sends 0 groups
  and the wrong shape was unreachable, but a non-zero count would have
  desynced the trailing `AvailableMoney`.
- `TileEntityLight` network body was 9 bytes short: `LightState` u8, `Rate`
  f32 and `Delay` f32 were missing. Stock gates those three on payload
  version, but the network path pins the version to 18, so the client always
  reads all nine fields. Nothing brackets this body with a size marker and the
  reader holds only the package payload, so the client was filling the three
  fields from stale bytes in the pooled buffer. The prefab `.tts` parser read
  the fields and discarded them; they now reach the wire. The same body also
  carried a placeholder `teBlockId` of 0, which makes the client drop the
  package outright ("Block type changed"); it now sends the real world block.
- Quest objective wire shape for `StayWithin` and `Time`. Stock has exactly
  four `BaseObjective` subclasses that override `Write`; the mapping covered
  only two, so `StayWithin` emitted the 2-byte base pair where the client reads
  nothing, and `Time` emitted that pair instead of its `UInt16`. Either
  mismatch fails the client's `ValidateSizeMarker` and clears the entire
  objective list for that quest, so a journal containing stock
  `intro_buried_supplies` lost its objectives.
- Trader stock quality. Stock parses a `<item>` ref with no `quality`
  attribute as min = max = -1 and `TraderInfo::SpawnItem` substitutes 1..6 for
  it, then clamps to `TraderMaxTier` (static, default 6) and drops the item
  when the clamped max falls below the min. zdtd defaulted those refs to
  quality 1 and only rolled when the XML carried an explicit range, so 653 of
  the ~780 stock refs sold at quality 1: every trader window was tier-1 gear.
  Whether an item can carry quality at all now comes from
  `ItemClass.HasQuality` (any owner-tiered `effect_group` in items.xml,
  inherited through `Extends`), so stackables still have none. The ceiling and
  the fallback range are `[rules.trader]` (`max_tier`,
  `default_quality_min` / `default_quality_max`).

### Changed

- Backpack scrap: stock `GetScrapableRecipe` (RE crafting-recipes.md IL=77)
  resolves forge scrap by MadeOfMaterial forge_category, NoScrapping reject,
  and the first `wildcard_forge_category` recipe whose output material matches
  and whose output weight is `<= itemWeight * count`. InvTx `Op.scrap = 12`
  (bag slot + qty) consumes the slot and deposits `recipe.count` of that scrap
  output. General craft still rejects scrap stubs.
- Death/kill counters scored WORKS: `killedZombies` / `killedPlayers` already
  ride `NetPackagePlayerStats`. The five client-accrued accumulator fields stay
  0 by design (DIVERGENCES §2), not as an open gap.
- Forge melt: items.xml `Weight` / `MeltTimePerUnit` / `Material` (Extends),
  materials.xml `forge_category`, blocks.xml `Modules`/`InputMaterials`, and a
  bounded `HandleMaterialInput` tick (scrap → unit_* via Caps resolvers).
  Tools PassiveEffects 95 (`CraftingSmeltTime`, e.g. toolBellows) scale melt
  duration.
- Entityclasses `AITask` lists now select which native EAI tasks a class
  actually runs. Pipe lists on `zombieTemplateMale` (and class overrides such
  as `zombieRancher` dropping Territorial) and numbered `AITask-N` on animals
  both resolve through Extends. Classes with no list keep the shared table.
  Leap and RangedAttackTarget stay unmapped (no native task).
- Magazines raise crafting skills on eat (`AddProgressionLevel`) and grant
  the stock `GiveExp` (50, `_xpOther`) through the server ledger. Almanacs
  and journals with `SetProgressionLevel` `level="-1"` set each named
  perk/attribute/crafting_skill to catalog MaxLevel (RE minevents.md
  IL=104). Gated recipes unlock when the skill meets the `unlock_entry`
  tier; the join PDF and server craft path honour that list.
  `always_unlocked` recipes stay available from the start.
- Harvest, quest, craft, and magazine XP now push
  `NetPackageEntityAddExpClient` as `_xpOther` so the owning client shows
  the icon. Kill XP still uses the typed Kill packet.
- Auth-state timeout (`MaxDurationInAuthState` 10 s) and player/party
  gamestage spawn lookups were already in code; the GAP rows that still
  called them waived are now scored WORKS. Blood-moon `SetScaling`
  (`FastLerp(1, 2.5, (scaling-1)/3)`) is log-only (`GetStage` uses the
  unscaled argument).
- `NetPackageTraderData` is no longer emitted ToClient. Stock drops an
  inbound copy before `Read`; trader stock already rides spawn ECD and
  `NetPackageLockResponse`. Quest requirement rows and trader dialog
  chrome are scored WORKS against stock (zero requirement XML; dialog
  is client-local).
- Workstation TE queues honour recipes.xml: magazine `unlock_entry`
  gates, plus per-craft count, duration, and `craft_exp_gain` from the
  catalog rather than the client blob. Material-based recipes stay
  rejected (no scrap yield table).
- Workstation `RepairItem` / `AmountToRepair` is scored WORKS against
  stock: `TileEntityWorkstation` never reads those fields; repair queues
  are client UI only. zdtd already emits `has_repair=false` and skips the
  optional payload on read.

## [0.4.0] - 2026-09-06

### Fixed

- Damaging and explosive hits are now fanned out to the victim's tracking
  clients. Stock plays the hit reaction off `EntityAlive.ProcessDamageResponse`
  (IL=86), which ships the applied damage via `SendPacketToTrackedPlayers`;
  zdtd computed the damage but only the killer-route damage body reached a
  client, so remote observers saw no hit reaction and never read the
  dismember/cripple/crawler bits. Blast victims get the same fan-out
  (stock `Explosion.AttackEntites`, source External, Heat damage type).
- `NetPackageQuestEntitySpawn` now summons one entity per packet, for the
  sender only. The body's third field is `entityIDQuestHolder` (RE
  `protocol-packages.md` 6.17, read IL_0002-001F), but it was read as a spawn
  count, so a single packet summoned that many zombies (bounded only by
  `quest_summon_per_request`) with the client choosing the number. Stock
  `ProcessPackage` (IL=37) calls `SpawnQuestEntity` exactly once. The holder is
  now also checked against the sender's own entity.
- Wrench pickup now removes the block on the server. `NetPackagePickupBlock`
  broadcast the replacement `NetPackageSetBlock` but never wrote it, so the
  block disappeared for clients while still standing in the world: it came
  back on the next chunk load and kept blocking placement and pathing in the
  meantime. Stock replicates the pickup rather than simulating it client-side
  (RE `blocks.md` "Server authority").
- Multi-stage blocks now downgrade instead of clearing to air on destroy.
  Stock `DamageBlock` downgrades via `Stage2Health` (`Block.OnBlockDamaged`
  into base `OnBlockDestroyedBy` returning the downgrade); zdtd always
  cleared to air, visibly wrong on the small multi-stage set. `DowngradeBlock`
  resolves from `blocks.xml` through Extends on all four destroy paths
  (player dig, zombie chew, explosion, Demolition tick) with a SetBlock echo,
  and the wire damage display caps at the Stage2Health threshold.
- Dismember chance now starts from the region multiplier, not 1.0. Stock
  `GetDismemberChance` (IL=128) multiplies the weapon/armor/attacker/perk
  chain by the `DismemberMultiplierHead/Arms/Legs` of the hit region; zdtd
  started every region at full chance, so headshots on feral/radiated
  zombies (stock 0.7/0.4 multipliers) dismembered far too often. The three
  multipliers plus `LegCrippleScale`/`LegCrawlerThreshold` now load from
  `entityclasses.xml` (stock cctor/Init defaults when unset), the attacker
  `DismemberSelfChance-143` perks and buffs fold in, and the killing blow
  prescales by the victim's remaining-health fraction before the roll. Rolled
  outcomes ride the S2C damage body so clients see them.
- Trap and turret kill XP now scales by the owner's `ElectricalTrapXP` perk.
  Stock `EntityAlive.AwardKillXPServer` multiplies `KillXPScale` by the
  killer's perk value on trap kills (research `docs/changelog-3.2.0.md` §4.3);
  zdtd passed the wire scale through but never applied the perk.
- Trader buy/sell prices now fold in the buyer's `BarteringBuying` and the
  seller's `BarteringSelling` perk scales (stock `GetBuyPrice`/`GetSellPrice`),
  ceiled like stock. The verdict hook still sees the pre-barter price.
- Land-claim repair requests now run the repair server-side instead of being
  rebroadcast. Stock `ProcessPackage` (IL=33) resolves the TE at the block
  position and runs `RepairAll` (healing damaged blocks to full HP across the
  claim square, replicated per block through SetBlock), emitting nothing; zdtd
  fanned the request to every peer. Requests outside any claim, or for
  someone else's claim, are dropped; the requester gets the stock
  `Setup(blockPos, false)` completion. Conscious simplification, recorded in
  DIVERGENCES: the repair is free (stock consumes `RepairItems` from TE
  storage, which zdtd has no inventory for) and air stays air.
- The join handshake now sends the empty `AuthConfirmation` the client
  echoes. Stock `AuthFinalizer.Authorize` (IL=10) sends it as the last
  authorizer step and the client answers back; without the send the
  round-trip never started.

### Added

- The killer's client is now told about its kill so kill challenges advance.
  Stock `GameManager.AwardKill` (IL=27) ships
  `NetPackageEntityAwardKillServer` to a remote killer and the client fires
  its local `EntityKill` event, which `ChallengeObjectiveKill`/`KillByTag`
  subscribe to. Server-side credit (quests, XP, score) already ran on the
  death path; this send only feeds the client-tracked challenges. The inbound
  direction stays accept-and-drop (DIVERGENCES 1.12).
- Zombie attack targets are now published to tracking clients. Stock fans
  `NetPackageSetAttackTarget` out of every server-side attack-target change
  (`EntityAlive.SetAttackTarget`, plus the expiry send in `OnUpdateLive`);
  zdtd picked targets in the sim but never published them, so every zombie
  read as untargeted on remote clients (drone beam, DynamicMusic threat).
  A per-tick diff against the last published value produces the same traffic
  without mirroring stock's call sites.
- Player laser sights now relay to the other clients. Stock re-sends the
  `NetPackagePlayerLaserSight` body to every client except the sender's own
  entity (IL=70); zdtd dropped it, so a mate's laser dot never showed. Relay
  is gated on the sender speaking for its own entity plus the cosmetic-relay
  rate cap.
- Owned vehicles now reach the owner's map as a waypoint list. Stock
  `VehicleManager.UpdateVehicleWaypointsForPlayer` ships the owner's parked
  vehicles as `NetPackageEntityWaypointList` (listType Vehicle); zdtd kept
  the data but never sent it.
- Three client-sent reports that had no C2S arm are now validated and
  dropped instead of falling through: `NetPackageEntityStatChanged`
  (accepting the number would let a peer set its own health; the server owns
  stats and replicates them out), `NetPackageGameEventResponse` (zdtd keeps
  no `GameEventActionSequence` state for a reported hit to bump), and
  `NetPackageSharedPartyKill` (zdtd computes the party split server-side, so
  accepting the forward would award the kill twice).
- Deaths under an XP-penalty `DeathPenalty` now send the deficit sequence
  action. Stock `EntityPlayer.HandleClientDeath` (IL=71) runs the matching
  `game_on_death_*` sequence and the `AddXPDeficit` action reaches the dead
  player's client as a `ClientSequenceAction` response; zdtd ran the server
  side but never sent it.

### Changed

- `NetPackageWorldFolder` rides channel 1. The RE names five channel-1
  overrides (`network.md`, `NetPackageWorldFolder` read IL_0000
  `ldc.i4.1`); the table listed four, so the first WorldFolder send would
  have gone out on the wrong stream. The compressed-package set is now
  pinned the same way: exactly the five stock `get_Compress` overrides zdtd
  emits, with the three never-sent names asserted out.
- Trader demand drift is gone. zdtd decayed a per-entry demand scalar toward
  1.0 on every restock tick; stock has no such model (per-entry markup is
  vending-UI state, `GetBuyPrice` has no demand term), so prices moved in a
  way no stock client or server reproduces. Markup docs corrected with it.

## [0.3.0] - 2026-09-06

### Removed

- C2S game payloads that fail the channel-envelope parse are now dropped, with
  no second attempt. `dispatchGamePayload` used to retry an unparseable payload
  by prepending a zero channel byte and re-parsing; whatever packages that
  produced went to `handlePackage` as if the peer had sent them. Every stock
  game envelope carries the channel byte (GAP_ANALYSIS "Game envelope channel
  byte"), so the retry only ever accepted payloads stock rejects, and a 10-byte
  body reaches it. It was a framing-bug workaround from early RE, untested and
  unreferenced, widening the C2S trust boundary on unauthenticated input.

### Changed

- Wire pin retargeted to stock **V3.2.0 b10** (`src/version.zig`,
  `VersionInfo` in `src/wire/packages.zig`): `Constants.cVersionBuild` 9 → 10,
  so the GSI `ServerVersion` four-field string is now `V.3.20.10` and the
  `PackageIds` body carries build 10. The login gate compares
  `VersionInformation.LongStringNoBuild` (`V 3.2.0`), which the build number
  does not enter, so a b9 client still joins. b10 changed no wire surface:
  research `docs/changelog-3.2.0.md` §8 records an unchanged census (4426
  types / 44277 methods / 195 NetPackage / `gmUpdate` IL=631 /
  `WorldState.SaveLoad` IL=926), byte-identical XML pins, and a managed-code
  delta confined to the client-side EOS Title Storage cancel path
  (`Platform.EOS.RemoteFileStorage`), which the dedicated server never runs.

### Added

- Stock client wire V3.2.0 b9 (Mono, EAC off): packed `NetPackageDamageEntity`
  flags + `KillXPScale` (breaking), POI metadata packages
  (`NetPackagePOIMetadataRequest`/`Response` replace `NetPackagePOIAround`),
  `NetPackageConfirmSpawnEntity`, `EntityCreationData` requestedBy/requestKey
  tail, `ItemValue.Activated` → Flags bitfield (wire-compatible). Grounded in
  7dtd-engine-research `docs/changelog-3.2.0.md`; the 3.2.0 login gate is
  live-verified. Caveat: the bundled AssignIds dump is still 3.1.0-era
  (refresh item in GAP_ANALYSIS §1a).
- Malleable world geometry (ADR 0036): `[rules.geometry]` elevation projection
  (`sea_level`/`height_scale`/`height_offset`/`height_ceiling`; identity at
  stock defaults) and `[wire] profile` column-height dialects: a world can
  ship compressed mountains, a sea-level model, or a custom ceiling with a
  stock client; non-stock dialects need a paired client mod. Proc shaping
  params lifted to `[rules.worldgen]` (byte-identical defaults; fail-closed
  validate).
- Infinite procedural world: `--mode infinite` (or `mods/infinite_world`, a
  config-only mod via the new `[mods] enabled` mechanism) streams chunks on
  first touch as players explore; deterministic per seed; proc deco resolves
  from the W3 biome field; clean chunks never persist (save dir grows with
  edits, not visits).
- Server-authoritative progression: perk/attribute spend
  (`NetPackageEntitySetSkillLevelServer` C2S validated against the catalog +
  the `on_perk_spend` Wasm verdict), per-player levels + skill points persist
  (players.zsv ZPV11 skill tail), `NetPackagePlayerStats` snapshots to every
  peer (join + level-up), armor `PhysicalDamageResist`/`ElementalDamageResist`
  quality curves fold through the passive-effects VM, difficulty presets
  decode from the embedded stock `sandbox_presets.xml`.
- New serverconfig properties: `DeathPenalty`, `LandClaimCount`/
  `LandClaimDeadZone`/`LandClaimOfflineDelay`/`LandClaimDecayMode`,
  `ServerReservedSlots(+Permission)`/`ServerAdminSlots(+Permission)`, and the
  GSI browser fields (`ServerDescription`/`ServerWebsiteURL`/`Region`/
  `Language`/`ServerMatchmakingGroup`); all documented in GAME_OPTIONS.md and
  shipped in serverconfig.example.xml.
- Pure XML/assetbundle modlet support (docs/prd/0003-modlets.md,
  docs/rfc/0003-modlets-plan.md): stock `Mods/` scan with `ModInfo.xml` V2, the full
  `XmlPatcher` op catalog (append/prepend/insert/remove/set/csv/include,
  `@modfolder:` tokens; `conditional` fails closed until RE pins the grammar),
  patched catalogs feeding every XML loader (`--mods-dir` override), and the
  stock join-phase config sync (`NetPackageConfigFile`, 42 S2C rows,
  Deflate-cached patched XML, `archetypes` name-only). DLL mods are never
  hosted; `Bundles/` is tolerated, never read.
- WebUI: the operator dashboard gains a Guard policy panel (kicks,
  would-kicks, quarantines, quarantine rejects, load-shed drops) and the page
  header wordmark is a level-1 heading (screen-reader landmark).
- Dependency bump: zwasm 2.4.1 → 2.5.0 (build.zig.zon URL + hash,
  THIRD_PARTY.md). Picks up the upstream pre-tag cleanliness sweep (file org,
  build flags, audit fixes) and full WASI 0.3 coverage; no zdtd-facing API
  change.
- New sim tunables: `[rules.c2s]` per-request caps on untrusted C2S push
  paths (`eat_units_per_push`, `quest_summon_per_request`) and
  `[rules.ai] stealth_alert_radius` (S2C stealth alert flag radius; the
  16-tick broadcast cadence stays the RE-pinned stock value). All bind via
  `zdtd.toml`/preset packs like the rest of `[rules.*]`.
- Admin `give` resolves stock item names (e.g. `give 0 resourceWood 5`) in
  addition to numeric ids, fail-closed on unknown names; `admin help` now
  lists `loglevel`, `commandpermission`/`cp` and `plugin`.
- Parachute mod (`mods/parachute/`, ADR 0037): a fully self-contained mod
  adding a wearable parachute item (items.xml modlet patch) that deploys
  when falling fast. The plugin boundary grew sense **v4** (server-derived
  `vy` + `wearing_glider` per player), a `glide` queue verb (server-side
  vertical sink while gliding, attributed/withdrawn per plugin), and
  `[rules.glide] sink_vy_mps` / `item_tag`. Deceleration is
  server-side (C2S vertical clamp + position broadcast, no client mod
  needed); fall-damage stays client-owned (stock wire). Sense v4 is a
  breaking layout change: all shipped guests (fps_bot, mcp, core_announce)
  were rebuilt for it.
- Pointer-stable chunk store: `World.chunks` maps keys to `*Chunk` (one
  allocation per chunk, freed on eviction/deinit, residency bounded by
  `max_resident_chunks`) instead of inline `Chunk` values, so a `*Chunk`
  held across a re-entrant `getOrCreate`/`blockWorld` stays valid across map
  resizes - closing the GAP "Chunk pointer stability" hazard class (bait-soak
  segfault 5/5) at the store, with a regression test forcing 40+ resizes
  while a pointer is held. The same hazard class in the prefab TTS cache
  (`tts_cache` in `world/prefabs.zig`) was closed the same way: the map now
  holds `*TtsBlocks` (per-entry allocations, freed on deinit/setIdLookup)
  with a regression test holding a pointer across 11 cache puts.
- Join-burst pacing (GAP "Join-burst tick budget"): `sendSpawnArea` sends
  only the collision-mesh core (spawn chunk + 8 neighbours) synchronously
  and arms a per-client pending area; `drainSpawnArea` delivers the outer
  rings against a shared `chunk_adds_per_stream_tick` per tick (concurrent
  joins split it), with per-chunk ACK-yields (a bursted batch overflowed the
  reliable window; 257 drops measured without them). A sustained loadgen
  double-join cycle (62 joins) shows join_fail=0 (concurrent-client
  starvation gone) with the chunk stream bounded at 50 ms; ReleaseFast
  re-measures max tick 140 ms / p99 50 ms vs the pre-pacing 262 ms. The
  join path is instrumented with `.join` (C2S join handler) and `.join_drain`
  (paced drain pass) apm sections.
- Starter population fill (GAP "population is still thin"): the director
  spawns toward `[rules.director] initial_population_frac` (default 0.25) of
  the alive cap once at boot, batched at 4/tick, so a fresh world is
  populated near players instead of staying near-empty until the first night
  drip. Stock fills loaded regions toward their spawning.xml maxcounts as
  they load; the caps stay stock-faithful (MaxSpawnedZombies/Animals).
- Observe-mode honesty (T19): `movement_rejects` now counts ENFORCED
  rejections only (correct mode); observe stays permissive (applies the
  client position, never denies - documented) and records observed movement
  violations in the evidence ring instead, so the dashboard no longer claims
  protection observe does not provide.
- Hard-authority ceiling (T20): `evidence.decisionInputs` classifies every
  detector by decision-input authority (server_only vs client_informed), and
  `noteEvidence` fails closed - a `.hard` event from a client-informed
  detector (bounds/movement weigh client-reported values) is downgraded to
  `.strong` and counted (`hard_ceiling_downgrades`), so no client-informed
  signal can trip the kick ladder. Coverage test + scenario pin it.
- `on_evidence` plugin observer (T21): the guard streams every recorded
  evidence event to guests on both plugin hosts (detector/severity/surface
  enums, observed/bound as f32 bits); `severity` is the post-ceiling value
  and the return is discarded - read-only, never a gate. Host unit test +
  the T20 scenario cover the wiring.
- Anti-cheat suppression audit (T22): the void rescue (a player who fell out
  of the mesh - y < -1 - corrected to the surface) now resets the movement
  envelope instead of rebaselining, so the interim packets (the client still
  falling before it processes the EntityTeleport) no longer count as
  movement rejects against a legit player. Spawn/respawn/death and admin
  teleports already reset the envelope; stalls/packet loss are rate-covered
  by design. Scenario "void rescue suppresses the movement reject".
- Dry-run reviewable diff (T23): the guard records the gate-trip cause
  (detector + tick) per peer, and the new `guardreport` admin verb dumps the
  anti-cheat diff - per peer, which strong detectors are in the window,
  whether the kick ladder tripped (by which detector, at which tick), the
  kick/denial state, and the enforcement rung configuration - so an operator
  reviews exactly who WOULD be kicked before enabling a rung. Scenario
  "guardreport shows the would-kick diff".
- Inventory C2S hardening (T18 slice): the stock InventoryTransaction path
  now REJECTS a non-empty stack that does not resolve to a server catalog
  item (fail-closed, honest success bit + `c2s_rejects`) instead of silently
  applying an empty slot with a success ack, and SetAll applies atomically
  (only when every op resolves). Scenario "stock InvTx rejects unresolvable
  item stacks".
- Whitelist gate fail-open fix (admin audit): the "platform:id" composite
  key buffer was sized to `max_id` (64) while a max-length identity composite
  is up to 81 chars; the `bufPrint` overflow at the join whitelist gate used
  to `catch return true` - SKIPPING the gate on a whitelist-only server. The
  buffer now covers the composite (`max_composite_id`, derived from the wire
  lengths) and an un-keyable identity is simply not on the whitelist
  (denied), never a gate skip; the admin.xml composite keys and the
  admin-level lookup use the same capacity. Scenario "whitelist gate fails
  closed on an un-keyable identity".
- Player-console per-command permission fix (admin audit): the check was
  inverted vs stock (`req > caller` instead of stock's `req >= caller` with
  levels 0 = highest), so a level-5 admin could run owner-only commands and
  the owner was locked out of delegated commands. Now deny = `req < caller`
  (stock IsAllowed, console-commands.md IL). The player-console scenario
  covers the matrix: owner (0) allowed a req-5 command, level-5 admin denied
  a req-0 command.
- Plugin binary freshness gate (`scripts/lint-plugins.sh`, part of
  `make lint`): every committed `.wasm` is rebuilt into a scratch mirror and
  byte-compared against what is in the tree, so a plugin source edit that was
  never rebuilt fails the gate instead of shipping a stale binary.
  `scripts/build-plugins.sh --dest DIR` produces that mirror without touching
  the working tree. `mods/BUILDING.md` said "commit both" but nothing enforced
  it.
- `lint-architecture.sh` now checks that every `@import` in a package barrel
  also appears in its `test {}` block, not just that the file is referenced -
  the exact thing the check's own comment claimed to enforce, since importing
  a module is not enough to pull its tests into `zig build test`.
- `zig build test` now also builds `mods/plugin_common.zig` as its own
  host-target test binary. The shared guest helper (`Buf`, `Config`) backs the
  12 core plugins and the Zig addons but is outside the server's import graph,
  so its two tests had never run. Its `Config` tests now also parse the real shipped
  `plugins/core_*/config.toml` files rather than a synthetic string, which is
  what catches a quote or trailing-comment regression reaching a guest.
- `make check` no longer fails on a transient registry blip: `lint-webui.sh`
  ran `bun add` against the network on every invocation, so a momentary
  DNS/registry failure failed the gate (surfacing as `make check` exit 2, since
  a failing sub-make reports 2). It now retries once and then falls back to the
  already-populated pinned cache; a genuinely cold cache still fails loudly.
- `mods/parachute/preset.toml` is now bound against the rules schema in the
  suite. It was the one shipped preset pack no test parsed (the resolver test
  pins only its path), so a stale `[rules.glide]` key would have surfaced at
  runtime load rather than in `zig build test`, unlike every `presets/*.toml`
  pack and the other two mod presets.

### Fixed

- A legacy ZCT1 container save with more than one record lost every container
  after the first. ZCT2 appends `touched_day` plus the grid size after a
  record's slots; the loader decided whether to read that tail from the bytes
  remaining rather than from the file's magic, so in a multi-record ZCT1 file
  it consumed the next record's position as the previous one's `touched_day`
  and every following record shifted out of alignment. The tail is now keyed
  on the magic. A single-record fixture cannot see this, which is why no test
  did.
- Every pre-ZPV12 player save carrying inventory was corrupted on the first
  save after upgrade, not just v10/v11: each migration branch widened slots
  only to its own era's width (7 to 13, or 11 to 13) while the header became
  `ZPVC`, so the reader walked them with the v12 21-byte stride. All branches
  now widen to the current width through one helper. A second fault in the
  same path: `tailStartOf` assumed a 7-byte slot but runs for v6 through v8,
  and v7 widened slots to 11 when they gained `use_times`, so a v7/v8 record
  with inventory was walked 4 bytes short per slot.
- A pre-ZPV12 player save carrying inventory was corrupted on the first save
  after upgrade. The save path rewrites the header to `ZPVC` (v12) but carried
  v10/v11 records byte-for-byte, leaving 13-byte inventory slots in a file the
  reader walks with the v12 21-byte stride: every field after the slots read
  from the wrong offset and the next load failed with `CorruptPlayersFile`,
  losing the player's inventory, progression and bedroll. Carried records now
  widen each slot with four zero mod ids, the same way the v7 and v9 carries
  already widened theirs.
- GSI values now use stock's separator encoding, so a server or level name
  containing `:` or `;` reaches the client intact. `GameServerInfo::SetValue`
  (IL=70) stores values with `:` replaced by `^` and `;` by `*`, and
  `GetValue` (IL=16) reverses both; zdtd replaced `;` with `_` and passed `:`
  through, so such a name arrived mangled and a `:` could split a value into a
  key the client did not expect.
- `NetPackagePOIMetadataResponse` went out on LiteNet channel 1 instead of 0.
  Its 3.1.0 predecessor `NetPackagePOIAround` overrides `get_Channel` to 1, but
  the 3.2.0 replacement declares no override and inherits `NetPackage`'s 0; the
  channel was carried across when the package was swapped. Stock overrides the
  channel for exactly four packages (`NetPackageChunk`, `ChunkRemove`,
  `DynamicMesh`, `MapChunks`), and a test now pins the whole table rather than
  a sample.
- `NetPackageSetBlock` with an empty change list decoded as a block change the
  client never sent. `parseSetBlockChanges` keyed a legacy 14-byte layout off
  the body length, and 14 is a length a stock body reaches on its own: an
  identity plus a zero count is `6 + platform.len + id.len`, so any pair
  summing to 8 (`"Steam"` with a 3-character id) matched, and x/y/z/id came out
  of the identity bytes. The reach check rejected the result every time (the
  leading identity bytes put the decoded `x` near 1.4 billion), so the cost was
  a bogus rejection and a bounds counter rather than a world edit. The legacy
  branch is removed; no builder had emitted that form since the stock encoder
  landed.
- `NetPackageTurretSpawn` from a real client never placed a turret. The handler
  read zdtd's compact three-i32 body unconditionally, so the stock body's float
  position (`entityType` i32 | pos Vector3, RE write IL=24) decoded as
  coordinates in the billions and the reach gate dropped the placement. A body
  of 16 bytes or more is now read as the stock float layout.
- `NetPackageEntityRelPosAndRot` read its movement delta at a fixed byte 11,
  which is only correct when `bUseQRotation` is clear. The Rotation base this
  package extends carries 3 x i16 euler in that case but a 4 x f32 quaternion
  when the flag is set (RE `protocol-packages.md` 5.5.3), putting `dPos` at byte
  21. A client setting the flag had quaternion bytes decoded as its movement.
- `NetPackageEntityCollect` read only the first of its two i32 fields, so the
  `playerId` naming the collector was never checked. Stock gates the collect on
  `ValidEntityIdForSender(playerId)` (ProcessPackage IL=51); without it a client
  could collect a loot bag in another player's name. The parser now returns both
  fields and the handler rejects a mismatched claim.
- Explosions barely touched entities. `ExplosionData.EntityRadius` is a raw i16
  in blocks, but the parser divided it by 20 like `BlockRadius`, turning the
  stock value 6 into 0.3, which the caller then clamped up to its 1 m floor.
  Block damage was unaffected, so a blast cratered terrain while leaving zombies
  a metre away untouched.
- A stock `NetPackageTraderData` body for a tile entity with no trader data
  attached (14 bytes) was decoded as a zdtd trade: the arm tested `body.len >= 9`
  and the byte it disambiguated on is the high byte of `te_y`, zero for any real
  coordinate. The trade decoded a quantity from two position bytes and the
  trader-open path (quest interact objectives) never ran. The arm now requires
  exactly the 9 bytes the zdtd trade body has.
- Remote crash from one C2S packet: `NetPackageSoundAtPosition` with a
  256-byte clip name reached `@intCast` into a `u8` length and trapped
  (ReleaseSafe ships with safety on, so this killed a release server). The
  cap guard used `>` where the stored length cannot hold the cap itself; the
  identical off-by-one in the waypoint icon/name path
  (`NetPackageWaypointInvite`) and on the server's own sound emit path
  (`playSoundAt`, latent: its only caller passes a short literal) is fixed too.
- `mods/parachute`: the guest kept `announce_text` / `item_tag` as slices into
  `on_enable`'s stack buffer, so a later tick's deploy announcement read a dead
  frame (the shipped `config.toml` sets `announce_text`, so this was the
  default path). Both are now copied into static buffers, matching how every
  other guest handles config strings. Its hand-rolled config parser (the only
  one in any guest; the rest use `plugin_common.Config`) also handled neither
  the quotes nor the trailing comments its own doc comment claimed, so the
  shipped quoted `announce_text` was broadcast with the quote marks still in
  it. It now matches `Config.value` exactly, and the plugin test feeds the real
  `mods/parachute/config.toml` rather than a synthetic string.
- `serveradmin.xml` path leaked on startup: `main` duped it and `Game` duped
  its own copy, but only `Game`'s was freed. Reproduced and fixed under the
  DebugAllocator leak check.
- Client-reachable memory disclosure: the workstation save loader took
  `recipe_name_len` / `scrapped_len` verbatim off disk into 64-byte arrays,
  and `recipeName()`/`scrappedName()` slice by them straight onto the wire, so
  a corrupt `workstations.zws` shipped adjacent struct memory to clients.
  Both lengths are now range-checked like every other length in that loader.
- Modlet XML `removeattribute` hung the server: an unquoted attribute value in
  an element's opening tag left the attribute scan's cursor parked, looping
  forever on operator-supplied XML.
- Save/load desyncs where a skipped record left the read cursor mid-record, so
  every following record decoded from a shifted offset: traders (`traders.zst`,
  reachable today because an admin-spawned trader is saved but not respawned by
  `initWorld`), containers (`containers.zct`, at the 4096 player-chest cap) and
  vending machines (`vending.zvn`). `saveTraders` had the mirror-image bug: it
  wrote a header count and could then emit fewer entries.
- Out-of-bounds writes on save load: the ZPV12 mod-id block indexed the
  inventory array with an unbounded on-disk `u8` count (the slot write one line
  above was correctly clamped), and the ZWS1 group/queue/melt lengths were
  stored unchecked despite indexing fixed arrays on the replicate path.
- `allies.zal` panicked on a corrupt status byte: the range check ran *after*
  `@enumFromInt`, which traps on an exhaustive enum, so it could never fire.
  Same shape fixed for three unguarded `@intCast` of a `peer_slot` that
  defaults to -1, and for a `sleepers_cleared.zsc` header guard that was one
  byte short of the field it then sliced.
- Tall wire profile (`[wire] profile = "tall-512"`) silently lost world edits:
  `encodeChunk` writes the block plane for ZCH4, but `loadChunk` and
  `validateChunkBytes` gated reading it on ZCH3, so the plane was written and
  discarded on every reload and the topsoil tail was then read out of the
  middle of it.
- Multi-level `Extends` chains in `blocks.xml` truncated after one hop: the
  cycle guard recorded the block the walk started from instead of the chain
  step, so the second hop always tripped the duplicate check. Grandparent
  `Class`, `TraderID`, textures and merged drop rows were silently lost.
- `distraction_replan_min` / `distraction_replan_rand` / `flee_distance` were
  parsed, validated and documented as operator knobs but read by nothing; the
  distraction task now uses its own RE cadence instead of inheriting the
  generic chase throttle, and the flee goal distance is separated from the
  give-up radius (defaults unchanged).
- 3.2.0 login gate P0: the advertised version was the raw 3.1.0 form, so
  every real V3.2.0 client was kicked with VersionMismatch=4; the advertised
  `Minor` now matches the 3.2.0 display form (live-verified join).
- Concurrent-join starvation: the join spawn-area burst now yields ACKs
  between chunks so a second client's critical packages are not starved
  behind the flood; full-stock config bundles no longer wedge the reliable
  window (critical retry budget 250 ms → 1 s).
- Join cost: the storage-TE scan on clean proc chunks dropped 19.7 M → 262 K
  cells; a fresh boot's starter chest is no longer clobbered by a reboot
  with no saved entities; placed deco no longer marks chunks dirty.
- WorldSpawnPoints buffer: the join-time builder used a 512-byte slice but
  32 spawn points need 837 bytes, so maps with many spawn points (Pregen06k01
  has >= 20; Navezgane has 1) overflowed on every enter and the client
  silently got no spawn points (2026-08-29 Pregen soak find; buffer now
  1024 with a regression test).
- POI metadata response buffer: the 3.2.0 `POIMetadataResponse` built into a
  64 KiB slice, which 512 dense records can exceed - latent overflow on maps
  with long prefab names; hardened to 256 KiB with a regression test.
- Admin harden: `settime` clamps to a sane day ceiling (a max-u64 world time
  previously overflowed the blood-moon math and crashed the server); admin
  `tele`/`tp` and plugin spawn/move coordinates are bounded to
  `max_player_coord` (±1e6 blocks) and out-of-range C2S movement is rejected,
  so a huge-but-finite coordinate can no longer trap the tick-path casts.
- Admin `wipeplayer` accepts the current ZPV12 player-save format (a wipe on a
  v12 save previously failed to clear the record).
- Knockback impulse (C2S hit shove) now goes through the single
  NetPackageEntityVelocity builder and inherits the stock [-8, 8] per-axis
  clamp, so a knockback beyond the stock band no longer ships non-stock motion
  to peers.
- Plugin verdict scaling is bounded: the loot-roll count re-caps to the
  roll array (a large on_loot_roll verdict could read out of bounds) and the
  block-damage verdict products widen to u64 (u32 overflowed for a large
  verdict times a u16 damage).
- Plugin spawn reversion: a module's applied `zdtd.queue` spawns are recorded
  per source and despawned when the module disables (trap/fuel) or reloads,
  so its entities never outlive it (ADR 0030 amended).
- The trader quest-list tier (raw wire i32) is clamped to 255 before its u8
  cast; a hostile value above 255 trapped.
- The inventory-ledger give delta is clamped to i16 (admin give with a
  count above 32767 previously trapped the cast; the other ledger callers
  already clamped).
- Blood-moon spawn ceiling and wave-size casts clamp the config-scaled
  products in f64 (an unranged [rules.bloodmoon] budget_scale/wave_frac could
  trap the u32 cast).
- Harvest drop rolls and the HarvestCount held-tool multiplier are clamped
  to 65535 before their casts (modded drop/HarvestCount rows could exceed the
  target type; the stack store is u16 anyway).
- Explosion block damage is clamped to u16 per block (the loader allows
  BlockDamage up to 1e6; a modded blast times a DamageBonus multiplier could
  exceed 65535 and trap the cast - the chew path already clamped).
- Disconnect cleanup: a dropped or transport-reaped player's sim entity is
  now destroyed immediately (previously it lingered as a ghost until the slot
  was reused - a phantom in listents/mem counts and a spawn-on-approach
  candidate for late joiners), and the reap path shares the one drop path.
- Join-crash P0 (2026-08-29 bait soak, 5/5 ReleaseFast): the spawn-area
  send held a `*Chunk` while the storage-TE scan read a prefab TE's column
  via `world.blockWorld`, which re-enters `getOrCreate`; the inline-value
  chunk map (AutoHashMap) can resize mid-scan and move every chunk, so the
  held pointer dangled and the `te_scanned` write segfaulted (stack canary
  trip). The callback now reads the block from the chunk being scanned
  (identical value: the TE is confined to that chunk), which removes the
  re-entrancy; the post-scan `te_scanned`/`power_scanned` writes re-fetch
  the chunk by position as defense in depth. 10/10 live double-join bait
  soaks now pass (was 5/5 crashes). Hazard class + pointer-stable store
  follow-on tracked in GAP_ANALYSIS.
- Admin `listplayers` printed `<unknown>` for platform id and ip, so
  telnet-driven tooling (loadgen zombie pressure matching on
  `pltfmid=Local_` / `ip=127.`) silently spawned nothing. It now emits
  `pltfmid=Local_<id>` and the peer's v4 address; a kite soak and a
  wandering-horde soak both show live pressure (112 `spawnentity` calls,
  0 errors).
- Admin `getoptions` read the config base values, not the effective sim
  values, so mode-pack overrides (horde_lite: BloodMoonFrequency=10,
  MaxSpawnedZombies=32) never showed. All pack-overridable keys now read
  the live sim surface.
- Entity kind from stock data: entityclasses `Tags` now classify vehicles
  (`Tags="vehicle"`) and junk turrets (`Tags="turret,..."`) instead of the
  name falling through to zombie, so the admin `spawnentity` verb drops its
  hardcoded name-sniff list and takes vehicle physicals (kind, HP, velocity,
  seats) from vehicles.xml (unknown classes such as vehicleHelicopter fall
  back to the 4x4 def).
- Game modes renamed to **presets**; mods are self-contained. The stock
  preset folder is now `presets/` (was `modes/`), the CLI flag is
  `--preset NAME` (was `--mode`, kept as a deprecated alias), and the
  `zdtd.toml` selector is `[preset] name` (was `[mode] name`, no alias). A
  config-only mod carries its own preset inside the mod folder
  (`mods/<name>/preset.toml` via the `preset` manifest.toml key, replacing the
  old `mode = "<pack>"` that referenced the shared folder), so a mod is
  fully self-contained: config, wasm and assets travel together. The
  infinite world now ships that way (`mods/infinite_world/`); it is no
  longer a stock preset. Renames: `src/server/mode.zig` -> `preset.zig`,
  `Pack` -> `Preset`, `error.DuplicateMode` -> `error.DuplicatePreset`.
- Plugins are self-contained: every mod folder may ship `config.toml`
  (default config, served to the guest verbatim via the new `zdtd.config`
  host import; the host never parses it, each plugin owns its format - the
  shared `mods/plugin_common.zig` `Config` helper parses the minimal
  `key = value` subset) and a `README.md`. The channel works for both load
  paths: discovered mods (manifest dir) and explicit `[plugin] modules`
  (config.toml is read from the wasm's own folder). Reference plugin
  `core_pricegate` now reads its `price_percent` from its own config.toml
  instead of hardcoding 150 - edit the file, no rebuild. Declared via
  `_zdtd_requires "config"`.
- All 12 core plugins migrated to config-driven policy (same channel):
  `core_damagegate` (`percent`), `core_lootgate` (`percent`),
  `core_rewardgate` (`percent`), `core_craftgate` + `core_perkgate` +
  `core_questgate` (`deny_prefix`), `core_pvp` (`deny`), `core_announce`
  (announce strings: `day_prefix`, `blood_moon_rise/fade`,
  `join/leave_message`), `core_adminverbs` (`spawn_x/y/z`, `spawn_entity`),
  `core_killfeed` + `core_tradefeed` (`log_level`: off | info | debug).
  Live-verified (damagegate percent=25, questgate deny_prefix); all 13 core
  wasms rebuilt.
- The plugin/mod manifest file is `manifest.toml` (was `mod.toml`; the parsed
  shape was already called `Manifest`). The folder keeps its self-contained
  layout: manifest + optional `preset.toml` + optional `.wasm`.

## [0.2.0] - 2026-08-22

### Added

- MCP server addon (docs/prd/0002-mcp-server.md, docs/rfc/0002-mcp-server-design.md, ADR 0031): a Model
  Context Protocol server shipped as a Wasm plugin (`mods/mcp`). Protocol
  logic lives in the guest; the host provides a streamable-HTTP endpoint
  (`--mcp-port`, loopback + optional `--mcp-token`) and std.json parsing
  (`json_*` imports). Tools: `server_status`, `player_list`, and an
  `admin_command` tool gated by `--mcp-allowlist` verb prefixes.
- Player save format ZPV10: per-player seed persistence.
- World topsoil bitfield rides the wire (stock m_bTopSoilBroken, splat
  terrain).
- POI light tile entities from prefab .tts markers; ambient spawn rules
  enforce a POI-tag gate, maxcount and respawn delay; sleeper triggered state
  persists across restart.
- Trader: sell price prices the sold stack (PercentUsesLeft, worn items);
  real-client TraderData echo is stock-faithful; quest tier mod feeds the
  quest reward loot stage; POI difficulty tier scales the loot stage.

### Fixed

- WebUI: stray line-number prefixes removed from shell.html; shared-token
  restyle with a tabbed shell (logs and settings); test response capture sized
  for rendered pages.
- main: exit 141 on a broken stdout pipe; flag hints skipped under 3 chars.
- game: terrain_mu held in solid/water sense probes.

## [0.1.0] - 2026-08-22

### Breaking changes

- The writable chunk format is now ZCH3. ZCH1 heights remain readable. ZCH2
  heights remain readable, but its type-only block edits are intentionally
  regenerated because ZCH2 cannot preserve rotation and metadata. Back up a
  world before upgrading.
- The supported stock client wire is pinned to V3.1.0 b14. Earlier stock clients
  can be rejected or fail to decode changed package layouts.

### Added

- Quest turn-in and trader-interact phases advance on the stock client's
  trader open: the NetPackageLockRequest trade-window open (channel 1,
  EntityTraderLockContext) fires the quest interact/turn-in event, so a
  stock client's trader visit completes ready quests with the reward (no
  zdtd-only package needed).
- Trader stock persists across restart (traders.zst): a saved window
  overrides the fresh XML fill by trader name, so a reboot does not re-roll
  what a player was looking at (stock TraderManager saves its inventory).
  Entries ride item names (AssignIds ids are version-dependent); unknown
  names fail closed to a skipped entry.
- Timid animals no longer attack: `approach_attack` is gated by the class's
  inherited AITask-* list parsed from `entityclasses.xml` (stock timid
  templates carry RunawayWhenHurt/RunawayFromEntity/Look/Wander, no attack
  task), so a stag or rabbit near a player flees or wanders instead of
  sprinting at it and meleeing, while wolves, bears, boars and zombies keep
  hunting. New attack task names land in one RE constant, not per-class data.
- Treasure-dig ambushes now fire like stock: each `treasure_radius_break`
  objective update rolls the quest's TreasureRadiusReduction event `chance`
  (quests.xml: 0.25) and spawns the nested SpawnGSEnemy ambush (1-3
  SleeperGSList) around the player. The event block is parsed from the quest
  data (not hardcoded), the roll is deterministic per (world time, quest
  code), and the spawn reuses the phase-entry gamestage spawn hook.
- Loot container group rolls are prob-weighted like stock: an entry's
  stage-resolved prob is its weight relative to the group sum (a 0.9 item
  drops ~9x as often as a 0.1 one, zero-prob entries never drop), replacing
  the uniform pick that made every item in a group equally likely.
- Wandering zombies now path on the A* navmesh like the chase: `wanderUpdate`
  routes the same replan + waypoint machinery as `chaseAlongPath`, so a
  wanderer detours around obstacles instead of sliding straight into them
  (stock EAIWander walks to its spot via the navmesh).
- Loot-container discovery covers Navezgane-scale maps: the container store is
  now 4096 entries with world-container eviction (a full table reuses a
  non-player-placed container, which regenerates deterministically from the
  next chunk scan; player-placed chests are never evicted), so no chest past
  the old 256/512 cap silently comes back empty.
- Blood-moon horde music is per player like stock (`EntityPlayer.bloodMoonParty`):
  a player hears it only while the horde is active and their own party's horde
  is alive; the old global bool made every player on a multi-party server hear
  any party's horde music.
- The admin console verb set is complete for the stock surface:
  `getoptions` dumps every known serverconfig option with its current value,
  `exportcurrentconfigs` writes them to `<world_dir>/exported_config.txt`,
  `loglevel` sets the runtime log level (gating info/warn/err like stock
  Log.Level), `listthreads`/`lt` summarizes the server's threads, and
  `commandpermission`/`cp` sets a per-command required permission level
  enforced at the in-game console boundary. The Steam-group verbs
  (`admin addgroup` / `whitelist addgroup`) stay a documented gap (zdtd has
  no Steam group concept).
- Quest `<action>` elements are complete on the stock surface: SpawnGSEnemy
  now spawns its gamestage-scaled enemies around the player on phase entry
  (stock SpawnQuestEntity placement, 12-24 m), alongside the existing
  UnlockPOI; SetCVar / ShowMessageWindow stay client-side as stock runs them
  on the owning player, and GameEvent actions have no stock quest uses.
- Quest phases now advance only when **all** their objectives complete (stock
  refreshQuestCompletion): the shared `tier1_clear` phase 3 (ClearSleepers +
  POIStayWithin) and always-active phase-0 objectives are enforced, per-objective
  progress rides the journal wire and the ZPV6 save, and a ForcePhaseFinish
  objective can fail a quest. The 99-def sweep over the real quests.xml
  completes 99/99.
- ClearSleepers quests are real now: kills only count inside the quest's
  bound POI (victim position rides the kill event), and completing the phase
  permanently suppresses the POI's sleeper volumes (persisted across restart),
  so a cleared POI does not re-spawn its zombies on re-entry.
- Quest journal persistence is now ZPV5: every saved quest stores its name
  (the stock Quest.Write identity) and the accepted POI rect, so a restart  -
  even after a quests.xml edit - restores the same quest bound to the same
  prefab instead of a reshuffled def or a re-resolved POI. Older ZPV2/3/4
  player saves still read and upgrade in place.
- Quest POI placement now mirrors stock: RandomPOIGoto/Goto/ClosestPOIGoto
  objectives select the POI by prefab quest tags, difficulty tier, biome
  filter and distance (with bedroll/land-claim/quest lockouts), and trader
  offers carry the real QuestLocation / QuestSize / POIName instead of a
  fabricated catalog spot (RE: 7dtd-engine-research docs/quests-challenges.md).
- Core stock-client play now covers join, terrain streaming, inventory, combat,
  death and respawn, loot, crafting, trading, and persistence with EAC off.
- `--version` reports the zdtd product version and the supported stock client
  wire version.
- Procedural worlds (`--worldgen-seed`) now generate terrain from a 3D density
  field instead of a heightmap, so cliffs and overhangs appear naturally.
  Chunks are still generated on demand at stream time from the seed and chunk
  coordinates alone, so the same seed always yields the same world and chunk
  borders never seam. Water, biomes, caves, and points of interest are not
  generated yet.
- Stock-like `serverconfig.xml`, config override directories, and procedural
  terrain seed options are available. Run `zdtd --help` for precedence.
- Operator tunables can be set in `zdtd.toml` (world directory or CWD; see
  `zdtd.toml.example`). Run `zdtd --help` for the full precedence order.
- A Wasm plugin runtime (zwasm v2, ADR 0020) loads `.wasm` modules listed in
  `zdtd.toml` `[plugin] modules`. Plugins export `on_enable`, `on_tick`,
  `on_player_join`, `on_shutdown` and import `zdtd_log`, `zdtd_tick`,
  `zdtd_queue`; every call runs under a fuel and linear-memory budget, and a
  module that loops is disabled at its budget instead of stalling the server.
  Plugins may also handle extra admin verbs via `on_admin_command` and
  act as a chat filter via `on_chat` (deny or rewrite; first responder wins;
  bad UTF-8 rewrite treated as deny). See `docs/PLUGIN_DEV.md`.
- An operator web UI is available via `--webui-port`, `--webui-bind`, and
  `--webui-secret` (or env `ZDTD_WEBUI_SECRET`). It is off by default, binds
  to loopback, and refuses to start without a secret. It exposes the same
  command surface as the `--admin-port` TCP console. See `docs/WEBUI.md`.
- Server-side guard policy for detector evidence. It is log-only by default: a
  tripped gate records `guard would kick` and a counter, and nothing is denied
  or dropped. Operators can opt in to per-surface quarantine (no damage, no
  container use, no block edits) and, separately, to kicking, via zdtd.toml
  `[authority] guard_*`. Both enforcement rungs also require authority mode
  `correct`. Weak signals can never trigger either rung. The admin `guardstats`
  command reports the policy state, and `guardclear <slot>` releases a peer.
  See `docs/AUTHORITY.md`.
- An experimental, statically linked native plugin host skeleton is included.
- Weather and storm state now survives a server restart: the per-biome storm
  machine (`weather.zwt`) resumes the storm cycle instead of re-rolling the
  opening weather groups.
- Spawned vehicles and turrets survive a restart via `entities.zen`, and the
  power grid graph is rebuilt from the chunk block grid on first chunk load
  (`scanChunkPower`), so a generator/consumer/battery layout keeps working
  after a restart without saving the graph. Wire links between power nodes and
  trader quest-offer state remain runtime-only.
- Prefab `.tts` water planes now paint: POI pools, flooded basements and water
  tanks render wet through the chunk water-mass channel (the v>=17 sparse water
  channel in the prefab is decoded per-cell and the resolved water block is
  stamped at mass>0 cells). The flowing-water sim remains open.
- The scheduled blood-moon day is re-sent to connected clients when it rolls,
  so a client that joined mid-cycle no longer keeps a stale red-moon HUD day
  after its first horde.
- Quest rewards are real: the journal writes the actual reward ItemStacks
  (stock item ids and counts) instead of empty stacks, and turning a quest in
  grants the items into the inventory, the exp into the level ledger, and the
  wallet dukes on top of the existing coin credit.
- Quest `<action>` elements are parsed (type, phase, properties) and the
  phase-gated UnlockPOI action fires server-side, releasing the quest's POI
  lock on the phase it names (the phase-4 turn-in release no longer leaves the
  POI reserved). SetCVar / ShowMessageWindow are client-owned and recorded;
  SpawnGSEnemy / GameEvent remain recorded-unfired until the spawn/event
  subsystems land.
- The in-tree `sample_hello` plugin is enabled by default and can be disabled
  with the gamemode `enable_sample_plugin` setting. Out-of-tree packaging and
  a stable dynamic ABI are not supported yet. See `docs/PLUGIN_API.md`.
- An optional Tracy profiling build emits one zone per apm profiler section plus
  one frame mark per server tick. It is off by default with no overhead and no
  dependency; the Tracy client stays operator-supplied via
  `-Dtracy=true -Dtracy-src=PATH`. See `docs/APM.md`.

- Optional performance switches in `zdtd.toml` under a new `[perf]` section, all
  off by default: `async_chunk_flush` (chunk saves are written by a background
  thread instead of on the tick), `terrain_snapshot` (pathfinding reads a
  per-tick terrain snapshot instead of taking the world lock for every probe),
  and `job_batches` (the sleeper-volume proximity test runs in parallel; spawns
  still happen in the same order). Each switch ships with always-on metrics
  (`save_encode`, `save_flush_wait`, `terrain_snap`, `sleeper_scan`, `te_scan`
  sections and the matching counters) so operators can see whether it is worth
  turning on. See `zdtd.toml.example` and `docs/SCALE.md`.
- Block stability and structural collapse: `src/world/stability.zig` ports the
  stock per-block byte plane (15 full support, 1 cap on non-support blocks, 0
  is the only value that falls). A chunk computes the plane once on first touch
  (reset + distribute, matching stock seed semantics); a C2S SetBlock that
  removes a support block fells the recursed dependency chain and the server
  removes and broadcasts the fallen blocks, while a placement takes support
  from its neighbours and re-spreads. Support and ignore membership resolve
  from the block tables, not a hardcoded list. See
  `../7dtd-engine-research/docs/stability.md` for the RE ground.
- Land claims persist across restarts: keystone claims write to `claims.zlc`
  and re-map to the owner on login (entity ids are per-session), and the
  preserved seen-day keeps offline expiry past `LandClaimExpiryDays` honest.
  Removing the keystone takes the claim with it (`removeClaimAt`).
- Trader stock is per class: each trader resolves its own traders.xml
  `<trader_info>` id from npc.xml and fills its window from its own
  `<trader_items>` list instead of the shared `traderAlways` fallback. The
  lock-open path denies trading outside the trader's open hours (vending stays
  always open) and `allow_sell=false` blocks selling to that trader.
- Trader quest offers come from each class's npc.xml `quest_list` instead of a
  hardcoded map, accept the stock quest-name families (`intro_`, `test_`,
  `challengegroup_reward_`) alongside tiered `quest_` names, and are filtered
  by the requested tier with active quests excluded.
- Campfires and burning barrels grant the stock insulation warmth buff
  (`buffCampfireAOE`) to a player within radius (blocks.xml
  `ActiveRadiusEffects`). Torches, candles and the radiated barrel have no
  fuel-gated workstation record yet, so they remain unimplemented.
- Air drops push a `supply_drop` NavObject marker when the crate spawns, so a
  stock client gets a compass ping (`nav_object_classes.xml`). The marker has
  no removal companion package yet when the crate is looted or expires.
- Kill XP scales by entity class instead of a flat 100 per kill: the loader
  resolves entityclasses.xml `ExperienceGain` through its `replace_properties`
  chain, bounded to 2500 XP; an unresolved or missing value keeps the old flat
  100.
- Bedroll ownership persists across a restart. `players.zsv` bumps
  ZPV3 -> ZPV4 (the progression tail's buff list is followed by a
  `bed_present` byte and, when present, `bed_x`/`y`/`z`); ZPV2 and ZPV3 saves
  still load.

### Fixed

- A gamemode pack (`modes/<name>.toml`) now accepts the same value ranges as
  `serverconfig.xml` for the keys both can set. Land-claim durability, claim
  expiry days and claim size no longer take pack-only values the documented
  range forbids, and `BlockDamageAI`/`BlockDamageAIBM` accept 0 from a pack.
  `MaxSpawnedZombies` (and `max_spawned_zombies`) now accept 0 as "no zombie
  spawns", which `modes/builder.toml` asks for; it used to clamp to 1.
- An even `LandClaimSize` from a mode pack is forced odd like the
  `serverconfig.xml` value, so the claim area the client draws matches the one
  the server enforces.
- `nan` and `inf` in `zdtd.toml` or a mode pack are rejected at startup instead
  of being bound as a tunable that makes every comparison against it false.
- Package and entity layouts were updated for the V3.1.0 b14 client wire.
- Chunk resends now carry per-cell block damage in the wire damage channel
  (u16 per cell, same sparse shape as the water channel), so a wall chewed by
  zombies or a block mined by a player re-renders damaged instead of pristine
  the next time the chunk is streamed.
- Chunk persistence now retains full `BlockValue.rawData` in ZCH3.
- POIs are built from the blocks they were authored with. Prefab block ids are
  prefab-local and are now translated by name through each prefab's
  `<name>.blocks.nim`; roughly one in ten placed blocks used to be a different
  block. Prefab files older than format 18 are converted from the old
  `BlockValueV3` bit layout first, which covers 568 of Navezgane's 1559
  placements.
- The ecs-soa review follow-up fixes are in: relative motion raises the dirty
  bit so the replicate pass relays it at the motion period instead of the
  5-tick heartbeat; respawn heal marks hp/pos dirty; the loot-bag Collect arm
  restores the player inventory on a partial deposit and records ledger causes
  instead of deleting the remainder; `QuestEntitySpawn` is gated on an active
  quest and the shared block token, and `TurretSpawn` on the block token, so
  neither can drain the entity table; the absolute PosAndRot arm preserves the
  stored yaw instead of fabricating north; turret kills roll `LootDropProb`
  like player kills (`World.rollLootDrop`).
- Respawn no longer zeroes food and water: `respawnPlayer` mutates only the
  hp fields and keeps food, water and stamina across death (seeding their
  maxima when 0), matching stock behavior instead of landing on `food=0`,
  `water=0`.
- A stability removal now reports the recursed dependency chain as fallen
  (digging out a support column drops the structure above it), and the
  stability tests build their world with explicit air above the surface so
  biome-layer regen cannot smuggle extra blocks into the fixture.
- Reliable-window retry pacing: the WindowFull retry loops no longer sleep
  0.5 s every fourth attempt, which wedged the single-threaded tick for up to
  two minutes per stuck peer and starved the stale-peer sweep. They pump ACKs
  free for the first 16 attempts, then pace at 1 ms every fourth so a client's
  ~15 ms LiteNetLib ACK cycle can drain the window; a dead peer is reclaimed
  within the 3 s sweep instead of holding the tick, and the block-IdMapping
  WindowFull drops seen under loadgen reconnect floods no longer stall the
  server.
- Per-package delivery method: the five S2C motion packages (EntityPosAndRot,
  EntityRelPosAndRot, EntityRotation, EntitySpeeds, EntityStatsBuff) that stock
  sends with `get_ReliableDelivery=false` now ride `Peer.sendUnreliable` from
  `sendGame`, `broadcastExcept` and the replicate fan-out, so 20 Hz position
  spam no longer occupies or retransmits inside the 64-slot reliable window
  shared with chunks and join-critical control traffic.
- IPv6 hosting: the UDP socket binds IPv6 unspecified with IPV6_V6ONLY cleared,
  so both IPv4-mapped and native IPv6 clients reach the server (stock
  LiteNetLib's dual-stack flag); hosts without IPv6 fall back to IPv4-only.
- Loot respawn: `LootRespawnDays` (serverconfig, default 7, 0 disables) re-rolls
  a looted world container on its next open when the interval since its touch
  day has elapsed; the cycle-varying seed makes each respawn differ while
  staying deterministic per position and cycle. `touched_day` persists in
  containers.zct (older saves read 0 and do not respawn immediately), world
  containers are marked non-player-placed at materialization, and player-placed
  storage never respawns (stock bPlayerStorage).
- Inbound fragment reassembly: the peer now holds two assembly slots keyed by
  frag_id instead of one, so a second large C2S message (a Bag plus a
  PlayerInventory during a loot transfer) no longer clears the first assembly
  and silently loses a message that was already ACKed. A third concurrent
  message drops with an `asm_drops` counter; a regression test interleaves two
  messages and reassembles both whole.
- POIBlockActivate quest objectives now wait for and advance on the client's
  block-activated objective update (parsed but previously discarded) instead
  of auto-scaffolding past the phase; unrelated objective events such as
  zombie kills no longer advance it.
- Trader restock follows each traders.xml `<trader_info>` `reset_interval`
  (-1 never, 0 daily, N every N days) instead of a flat daily refill, and
  buy/sell pricing uses the root `buy_markup` / `sell_markdown` (per-trader
  overrides win) so the server charge matches the price the client displays.
- Goto-point quests without a static position (stock RandomPOIGoto /
  ClosestPOIGoto) bind the nearest real POI at accept; the NavObject marker,
  PositionData location and the goto check all use the bound POI center, so
  markers point at reachable prefabs instead of an invented FNV spot.
- Container loot fails closed: storage blocks with no resolvable `LootList`
  stay empty on both initial fill and the LootRespawnDays re-roll instead of
  falling back to a woodenChest roll.
- The block-id coverage guard test asserts every placeable blocks.xml name
  resolves in the bundled AssignIds dump, so the negotiated `blocks` mapping
  never leaves server data to the client's `assignLeftOverBlocks`.
- The last bare tick throttles became `[stream]` keys in zdtd.toml
  (`sleeper_tick_ticks`, `turret_sync_ticks`, `save_interval_ticks`), and the
  workstation burn dt follows the configured cadence.
- DecoUpdate objects carry stock `GetRandomRotation` rolls (rawData bits
  16..20, keyed to the placement cell) instead of a flat 0, so trees and rocks
  no longer all face north; the world mirror reads the same rotation bits.
- `setgamepref` writes the GameStats-backed prefs at runtime (difficulty,
  blood-moon cadence, day length, block damage, xp, pvp, drop, loot respawn,
  air drops), clamping to the config ranges and broadcasting the fresh stats
  blob; startup-only prefs keep the read-only reply.
- Vending machines persist their full store (stock rows, owner, password,
  rental) to `vending.zvn`, so a placed machine keeps opening after a restart;
  the trader-markup dead code in its stock seeding is gone (vending is
  owner-priced).
- `ItemValue.UseTimes` rides the ECS slot and both wire conversions, and
  `inventory.degradeUse` wears a tool toward 0 (clamped, stack stays present).
- Hammer upgrades work: `blocks.xml` `UpgradeBlock.ToBlock` resolves through
  the Extends chain into a data-driven ladder, and SetBlock only accepts a
  block swap onto an occupied cell when the new id is the current block's
  upgrade target, so a forged SetBlock cannot swap in arbitrary block ids.
- The join challenge comparison runs in constant time instead of
  `std.mem.eql`'s early-out, closing a timing side-channel that could leak
  challenge bytes one at a time.
- The server no longer trusts a client's `NetPackageTraderData` copy-back for
  trader stock or money; only the typed trade path may mutate an entity
  trader, and the vending path re-sends the stored tile entity instead of
  taking the client's item list or available-money field.
- `serverconfig.xml` attribute values are XML-decoded before use, so a
  `GameName` or `SandboxCode` containing an entity like `&amp;b` reaches the
  wire as `&b` instead of the literal `&amp;b`.
- Builtin item pins (fixture eat/drink amounts, stock-type fallback) are
  gated on the builtin catalog and no longer leak into XML mode: a real
  items.xml catalog no longer inherits a fixture's food value or an
  unresolved type naming the wrong stock item.
- `PlayerInventory` applies atomically: a body that fails partway (a short
  bag section, a bad equipment write) leaves the inventory exactly as it was
  instead of a half-applied mix of old and new fields.
- Sprint stamina now drains on backward and strafing movement, not just
  forward, so sprinting in those directions is no longer free.
- Six broadcast-fanout C2S packages (BlockTrigger, WireActions,
  WireToolActions, LandClaimRepair, ItemActionEffects, CloseAllWindows) are
  now rate-gated on the same block/inventory tokens as SetBlock, closing an
  unmetered bandwidth-amplification path where one client packet fanned out
  to every nearby or connected peer.

