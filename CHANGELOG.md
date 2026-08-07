# Changelog

Consumer-visible changes are recorded here. The project follows the release
and compatibility rules in [docs/RELEASES.md](docs/RELEASES.md).

## [Unreleased]

### Breaking changes

- The writable chunk format is now ZCH3. ZCH1 heights remain readable. ZCH2
  heights remain readable, but its type-only block edits are intentionally
  regenerated because ZCH2 cannot preserve rotation and metadata. Back up a
  world before upgrading.
- The supported stock client wire is pinned to V3.1.0 b14. Earlier stock clients
  can be rejected or fail to decode changed package layouts.

### Added

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
  See `docs/PLUGIN_DEV.md`.
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
  The in-tree `sample_hello` plugin is enabled by default and can be disabled
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
  turning on. See `zdtd.toml.example` and `docs/SCALE_ARCHITECTURE.md`.
- Block stability and structural collapse: `src/world/stability.zig` ports the
  stock per-block byte plane (15 full support, 1 cap on non-support blocks, 0
  is the only value that falls). A chunk computes the plane once on first touch
  (reset + distribute, matching stock seed semantics); a C2S SetBlock that
  removes a support block fells the recursed dependency chain and the server
  removes and broadcasts the fallen blocks, while a placement takes support
  from its neighbours and re-spreads. Support and ignore membership resolve
  from the block tables, not a hardcoded list. See
  `../7dtd-research/docs/stability.md` for the RE ground.
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

### Fixed

- Package and entity layouts were updated for the V3.1.0 b14 client wire.
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

No zdtd version has been tagged or published yet. These entries describe the
upcoming 0.1.0 development release.
