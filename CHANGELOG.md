# Changelog

Consumer-visible changes are recorded here. The project follows the release
and compatibility rules in [docs/RELEASES.md](docs/RELEASES.md).

## [Unreleased]

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
  resizes — closing the GAP "Chunk pointer stability" hazard class (bait-soak
  segfault 5/5) at the store, with a regression test forcing 40+ resizes
  while a pointer is held.
- Join-burst pacing (GAP "Join-burst tick budget"): `sendSpawnArea` sends
  only the collision-mesh core (spawn chunk + 8 neighbours) synchronously
  and arms a per-client pending area; `drainSpawnArea` delivers the outer
  rings at `chunk_adds_per_stream_tick` per tick, center-out, so one join
  cannot stall the 50 ms tick with a 289-chunk synchronous burst. A sustained
  loadgen double-join cycle (62 joins) shows join_fail=0 (concurrent-client
  starvation gone) with the chunk stream bounded at 50 ms.

### Fixed

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
  (the stock Quest.Write identity) and the accepted POI rect, so a restart —
  even after a quests.xml edit — restores the same quest bound to the same
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

