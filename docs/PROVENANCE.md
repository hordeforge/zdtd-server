# Provenance ledger: every zdtd behavior and value -> stock source

**Owns:** the proof that every behavior, perk and constant in zdtd comes from a
documented stock-game source (or is explicitly marked zdtd-owned). For each
src/ file: which stock behavior it implements, and for each behavioral
constant: the stock XML element or IL-verified RE doc it comes from.
**Hub:** [`INDEX.md`](INDEX.md). **Complementary:** [`RE_GAP_CLOSURE.md`](RE_GAP_CLOSURE.md)
(gap -> RE spec), [`ASSETS.md`](ASSETS.md) (data-loading policy),
[`GAP_ANALYSIS.md`](GAP_ANALYSIS.md) (gap inventory), the archived
[`HARDCODE_AUDIT_2026-08-08.md`](archive/HARDCODE_AUDIT_2026-08-08.md) (finding-by-finding hardcode audit).

## 1. Method and scope

What counts: **every `src/**/*.zig` file** (file-level provenance) and **every
behavioral constant** in the sim/server/world code (value-level provenance).
Pure structural constants (array sizes, loop bounds, protocol widths, index
arithmetic) are covered by their file's provenance row and are not separately
ledgered. Wire codec constants are covered by the R rows + `wire/PACKAGES.md`.

Three buckets (from AGENTS.md rule 15 + the hardcode-audit method):

| Bucket | Meaning | Rule |
|---|---|---|
| **A** | Stock game **data** | Must be read from the operator install (XML / assets / AssignIds), never hand-copied; the row names the stock file |
| **R** | Stock behavior/wire reproduced from **RE** | The row cites the `../7dtd-research/docs` narrative (IL-verified) or bundled dump that specifies it; fix code to match RE, never the reverse |
| **Z** | zdtd-owned policy / engineering | No stock counterpart; explicitly not a provenance claim; operator-tunable where it changes behavior (zdtd.toml / serverconfig) |

Citation forms: `Data/Config/<file>.xml <element>` (stock data), `../7dtd-research/docs/<doc>.md §N` (RE narrative), `asm.il <offset>` (dump line). The stock pin is **V3.1.0 (b14)**; see `src/version.zig`.

## 2. Coverage accounting

Regenerate the file map and re-check coverage:

```bash
python3 tools/provenance_scan.py      # file coverage + ledger well-formedness gate
```

File coverage target: **187/187 (100%)**. Every row below carries a bucket and a
source; a file without a row, or a row without a bucket/source, fails the gate.

| Bucket | Meaning | Count |
|---|---|---|
| **A** stock data | Loaded from the operator install (`Data/Config` / world assets / AssignIds); provenance = the stock file | 27 |
| **R** RE-cited | Stock behavior/wire reproduced from `../7dtd-research/docs` IL-verified narratives (or the bundled AssignIds dump); citation in the row | 105 |
| **Z** zdtd-owned | Engineering/policy/instrumentation with no stock counterpart; not a provenance claim | 55 |

### File provenance map

| File | B | Stock source (header-cited; R rows cite the RE doc) |
|---|---|---|
| `src/apm/metrics.zig` | Z | Monotonic counters and latency histograms for zdtd (not 7dtd-apm) |
| `src/apm/profiler.zig` | Z | Scoped wall-clock sections for tick phases (zdtd-native; not 7dtd-apm) |
| `src/apm/report.zig` | Z | Snapshot dump: human text or JSON lines for loadgen-side compare |
| `src/apm/root.zig` | Z | zdtd-native metrics + profiling harness. Not 7dtd-apm (stock Mono). This is first-class instrumentation inside the Zig process |
| `src/apm/tracy.zig` | Z | Optional Tracy client bindings, off by default. |
| `src/assets/assignids_comptime.zig` | A | Named AssignIds pins for V3.1.x (bundled dump). Values are the stock client Block.blockID after AssignIds Postfix, not XML declaration order |
| `src/assets/biome_layers.zig` | A | Stock biomes.xml → per-biomemap-id terrain column layers (top → bottom), weather groups, distant decorations and per-subbiome deco sets + noise |
| `src/assets/block_textures.zig` | A | Default Block.Texture → textureFull (i64) from stock blocks.xml. Face paint is 6×u8 packed little-endian (matches TTS paint samples like |
| `src/assets/blocks.zig` | A | blocks.xml solid/name table. Wire ids come only from AssignIds (idByName), never sequential XML declaration order |
| `src/assets/blocks_nim.zig` | A | Prefab `.blocks.nim` local-id → block name table (Prefab name mapping). Catalog/asset parse (not world store). Use when TTS types are local indices |
| `src/assets/buffs.zig` | A | buffs.xml: metadata + passive_effect rows. Full triggered_effect VM is later |
| `src/assets/entities.zig` | A | entityclasses.xml loader: name → Unity Mono hash, kind, HP, death loot list |
| `src/assets/entitygroups.zig` | A | entitygroups.xml: named weighted spawn lists (`<e n="…" p="…"/>`) |
| `src/assets/gamestages.zig` | A | gamestages.xml: per-spawner stage ladders plus the player/party stage math. |
| `src/assets/items.zig` | A | items.xml loader + builtin sim ids with stock name/type resolution for client UI |
| `src/assets/loot.zig` | A | loot.xml loader: groups + containers, simple deterministic rolls |
| `src/assets/maxdamage.zig` | A | MaxDamage lookup: blocks.xml name→hp + optional AssignIds map from .blocks.nim or a version-matched id\tname dump. Without a full id map, callers fall |
| `src/assets/npc.zig` | A | npc.xml: npc_info entries map a trader entity class (localization_id) and display name to a traders.xml `<trader_info>` id plus its quest_list |
| `src/assets/painting.zig` | A | painting.xml: paint id (0–255) ↔ TextureId for chunk face paint |
| `src/assets/paths.zig` | A | Resolve Data/Config XML paths, optional override patch dirs, generic tryLoad |
| `src/assets/progression.zig` | A | progression.xml: level curve + attribute/perk catalog (names, max levels, costs). Full perk requirement graphs / effect application is progressive; ca |
| `src/assets/quests.zig` | A | Load stock `Data/Config/quests.xml` into a playable Quest catalog. |
| `src/assets/recipes.zig` | A | recipes.xml loader: craft outputs + ingredients for server craft queue |
| `src/assets/root.zig` | A | Stock game config asset loaders (quests, blocks, items, …). |
| `src/assets/signs.zig` | A | Prefab sign libraries (*_signs.xml under Data/Prefabs) for NetPackageSignDataResponse. Catalog data only; the wire encode lives in wire/stock_sign.zig |
| `src/assets/spawning.zig` | A | spawning.xml biome spawn rules → director / animal pop |
| `src/assets/storage_pairs.zig` | A | Closed↔Open storage block pairs from blocks.xml DowngradeBlock |
| `src/assets/traders.zig` | A | traders.xml: trader_item_groups, trader_info blocks, and the stock inventory roll (TraderInfo::Spawn, asm.il 862758-863520) |
| `src/assets/unity_hash.zig` | A | Unity Mono / .NET stable string hash (Extensions.GetStableHashCode). |
| `src/assets/vehicles.zig` | A | vehicles.xml physical attributes → sim VehicleKind defaults |
| `src/assets/xml_patch.zig` | A | Clean-room config XML patches (stock XmlPatcher subset). Override files under --config-overrides dirs, applied in filename order |
| `src/assets/xml_util.zig` | A | Tiny helpers for scanning stock 7DTD XML configs (no full DOM) |
| `src/ecs/aidirector.zig` | R | Lightweight AIDirector as ECS resource (world clock, horde, blood moon) |
| `src/ecs/buff.zig` | R | Buff runtime rules: stacking, duration ticks, expiry. Pure over BuffSet, no World and no wire. Every rule mirrors stock EntityBuffs/BuffClass/BuffValu |
| `src/ecs/command.zig` | Z | Fixed tick command buffer: systems/plugins enqueue, drain once per tick. Cap 64; drop when full (no heap, no grow). Soft warn once past ~80% |
| `src/ecs/components.zig` | Z | All sim component types (plain data; no behavior). SoA columns live on World |
| `src/ecs/electric.zig` | R | Electricity / power graph: generators, wires, consumers (turrets, lights, …). Simplified from stock PowerManager concepts (not full wiring UI parity) |
| `src/ecs/entity.zig` | Z | Entity handles for the sim ECS |
| `src/ecs/group.zig` | Z | Cached per-Kind dense slot lists (entt-style non-owning groups). |
| `src/ecs/interest.zig` | Z | Spatial interest: grid cells → nearby players for replication. M11: dirty gating helpers for serialize-once fan-out (encode once, memcpy per peer) |
| `src/ecs/inv_ledger.zig` | Z | P4 inv cause ledger: fixed ring of recent inventory mutations (no heap) |
| `src/ecs/inventory.zig` | R | Inventory systems: move/drop/hold/use/open-container transactions |
| `src/ecs/jobs.zig` | Z | Thin jobs helper: run work over a slot range and wait. Wraps util/parallel (persistent pool). No heap; serial when pool unavailable |
| `src/ecs/locals.zig` | Z | Named tick scratch on World. No file-static mutables for sim. Cleared once per tick via World.beginTick / schedule.run |
| `src/ecs/observers.zig` | Z | Fixed on_spawn / on_death listener table. Cap 4. No heap. World fires via fireSpawn / fireDeath; listeners must not spawn/destroy |
| `src/ecs/party.zig` | R | Party engine (RE ../7dtd-research/docs/parties-factions.md §2). |
| `src/ecs/path.zig` | R | Lightweight grid path helpers for zombie chase (greedy, BFS, A*). |
| `src/ecs/poi_lock.zig` | R | Quest POI lockout table: the server half of QuestEventManager's PrefabInstance.lockInstance (QuestLockInstance, asm.il 1001892-1002045) |
| `src/ecs/powerblocks.zig` | R | Stock electrical block registry from blocks.xml Class + AssignIds. NodeKind mapping is RE (PowerItemTypes); names/ids/watts/fuel come from game data |
| `src/ecs/query.zig` | Z | Dense SoA iteration helpers. No allocation; O(capacity) scans |
| `src/ecs/quest.zig` | R | Quest catalog (shared resource) + definition types. Runtime journal/wallet live as SoA components; mutations are in systems.zig |
| `src/ecs/root.zig` | Z | ECS package root: SoA world, components, systems, resources. |
| `src/ecs/rules.zig` | R | Sim rule parameters (ADR 0021 decision 2): a game mode is mostly these numbers. Carried on `World.rules` (read as `w.rules.<group>.<field>`), set |
| `src/ecs/schedule.zig` | Z | Explicit sim pipeline phases. Ordered only; parallel stays inside a phase (systemZombieAi / systemTurrets via util/parallel). No access-set scheduler |
| `src/ecs/sim_view.zig` | Z | Narrow mut surface over World for inv/transform (plugin / handler boundary). No heap. Prefer this over raw *World when only these mutators are needed |
| `src/ecs/snapshot.zig` | Z | Deterministic sim snapshot bytes for tests/debug (not a full save format). Fixed buffer, no heap. Covers live entity census + director clock |
| `src/ecs/systems.zig` | R | ECS systems: pure functions over World SoA columns + resources. Hot loops (zombie AI, turrets) run multi-threaded over disjoint slots |
| `src/ecs/world.zig` | R | ECS world: dense SoA columns, resources, O(1) net id map, spawn helpers |
| `src/fuzz.zig` | Z | Coverage-guided fuzz targets for remote wire parsing boundaries and other untrusted-input surfaces (admin lines, map XML, COG headers, |
| `src/litenet/packet.zig` | R | LiteNetLib wire packet property helpers. Property ordinals match the **game** Managed LiteNetLib (7DTD V3.1.0 b14), |
| `src/litenet/peer.zig` | R | Per-endpoint reliable-ordered channel (LiteNetLib-compatible subset). Matches game Managed LiteNetLib PacketProperty ordinals and ack sizing |
| `src/litenet/root.zig` | R | LiteNetLib-compatible UDP transport (peers, packets, std.Io.net UDP). |
| `src/litenet/server.zig` | R | UDP LiteNetLib-compatible server (accept + reliable user data) |
| `src/litenet/udp_socket.zig` | R | UDP socket via Zig 0.16 `std.Io.net` (no raw `std.os.linux` syscalls). Non-blocking poll: zero-duration Timeout → WouldBlock/Timeout |
| `src/main.zig` | Z | zdtd: Zig dedicated server for 7 Days to Die (client wire). Run `zdtd --help` for CLI options and precedence |
| `src/plugin/api.zig` | Z | Static plugin hook types for in-tree test scaffolding only (ADR 0020). Product plugins are Wasm modules (`wasm.zig`); this table is not a shipping |
| `src/plugin/host.zig` | Z | Static plugin host: fixed table, ordered enable/tick/join/shutdown. No dynlib, no Wasm, no heap on the tick path |
| `src/plugin/root.zig` | Z | Plugin package: Wasm guest runtime (ADR 0020) plus in-tree static host as test scaffolding only (`api` / `host` / `sample_hello`). Shipping plugins |
| `src/plugin/sample_hello.zig` | Z | In-tree sample static plugin: logs once on enable |
| `src/plugin/wasm.zig` | Z | Wasm plugin runtime (ADR 0020, zwasm v2): load a .wasm module, instantiate it under fuel and memory budgets, register the minimal host import table, |
| `src/protocol.zig` | R | Wire constants from ../../7dtd-research/docs/protocol.md (V3.x loadgen golden; wire pin V3.1.0). Package IDs are dynamic (PackageIds map); never hard- |
| `src/server/admin.zig` | R | Minimal TCP admin console (telnet-like): one command line per connection. Listen/accept via `util/tcp_listen` (std.Io.net); no std.os.linux |
| `src/server/admin_cmds.zig` | R | Stock telnet console output shapes and the persistent operator lists. |
| `src/server/admin_console.zig` | R | Operator console surface: admin TCP + webui command handling, the stock telnet reply shapes, persistent operator lists, and the guard/gamestage |
| `src/server/ally.zig` | R | Ally relationships keyed on PlatformUserIdentifierAbs (stock `AllyStore`). |
| `src/server/c2s/blocks.zig` | R | Block editing: SetBlock, BlockTrigger, Explosions. Extracted from the old c2s/inv.zig tail (643-991) verbatim |
| `src/server/c2s/dispatch.zig` | R | C2S dispatch extracted verbatim from game.zig handlePackage. Phase gate + c2s/* fanout; game.zig keeps a one-line forwarder |
| `src/server/c2s/inv.zig` | R | C2S inventory and block editing: player inventory snapshots, holding/item drop/bag, tile-entity edits, inventory transactions, block trigger/setblock |
| `src/server/c2s/join.zig` | R | Join state machine — extracted from game.zig handlePackage (stock SM). Owns the 7 join packages that must stay coherent: PlayerLogin → |
| `src/server/c2s/misc.zig` | R | C2S misc domain: chat, player data / disconnect, dropped packages, game events, quest entity spawns, console commands, damage, lock requests, |
| `src/server/c2s/move.zig` | R | C2S movement and entity-state handling: absolute/relative position, the animation no-op, loot-bag collect, alive flags, motion speeds (sprint |
| `src/server/c2s/quest.zig` | R | C2S quest/social/trade domain: shared quests, party and ally actions, buff add/remove, quest events and objective updates, the NPC quest list, |
| `src/server/c2s_text.zig` | R | C2S text trust boundary: player names, chat bodies, player console verbs. Pure helpers (no Game / net types). Extracted from game.zig for navigability |
| `src/server/config.zig` | Z | Minimal serverconfig.xml subset (port, max players, world name, password) |
| `src/server/evidence.zig` | Z | P4 observe evidence: fixed ring of detector events (no secrets, no IP, no packets). Admin `evidence dump [path]` flushes the ring as JSONL via |
| `src/server/game.zig` | R | Game server: join SM, tick, interest, combat, persistence. Simulation is an SoA ECS (`ecs.World` + systems) |
| `src/server/game/bans.zig` | Z | Ban / rate-limit helpers extracted from game.zig |
| `src/server/game/blockmeta.zig` | R | Sparse block meta + damage persist extracted from game.zig |
| `src/server/game/chunk_fill.zig` | R | Chunk materialization and loot-fill senders, extracted verbatim from game.zig: sendSpawnChunk (resident-miss load + stock Chunk.write encode), |
| `src/server/game/chunk_stream.zig` | R | Chunk streaming senders, extracted verbatim from game.zig: the join spawn area burst (sendSpawnArea), the per-tick view-square stream with |
| `src/server/game/clock_persist.zig` | R | World-clock persist extracted from game.zig (ZCL1: worldTime u64) |
| `src/server/game/config_files.zig` | R | Config-file advertisement extracted from game.zig sendLocalConfigFiles |
| `src/server/game/constants.zig` | R | Game-wide constants re-exported by game.zig. Keeps the 40-line help table and a few caps out of the main file. Behavior-identical: re-exported as |
| `src/server/game/craft.zig` | R | Crafting and workstation helpers, extracted verbatim from game.zig: tryCraft/tryCraftRecipe (InvTx craft op), tickWorkstations (burn/craft + |
| `src/server/game/deco.zig` | R | Deco helpers extracted verbatim from game.zig (purest game.zig shard). Species resolution, multiblock dim cache, mirror into block store |
| `src/server/game/guard.zig` | Z | Guard/evidence helpers extracted from game.zig |
| `src/server/game/harness.zig` | R | In-process test and scenario helpers for joined clients, packet injection, replication, and direct world setup. Production networking does not use |
| `src/server/game/hooks.zig` | R | ECS hooks: sim callbacks that read Game / World state. Verbatim move from game.zig — thin wrappers remain there as `ctx: ?*anyopaque` adapters |
| `src/server/game/init_assets.zig` | R | Asset loading for Game.init — extracted verbatim from game.zig. Takes *Game and InitOptions, mirrors the original inline sequence so the |
| `src/server/game/init_world.zig` | R | Post-asset init: sleeper volumes, network listen, seed entities, power demo. World-store initialization and persisted-world restoration for `Game.init |
| `src/server/game/join.zig` | R | Join-bundle encoders and senders. Helpers take `*Game`; `game.zig` exposes forwarding methods where the main state machine needs method syntax |
| `src/server/game/lifecycle.zig` | R | Shutdown ordering for Game: flush every store, then tear down subsystems. Player persistence lives in server/persist.zig; callers go there directly |
| `src/server/game/locks.zig` | R | Lock helpers extracted from game.zig — pack/unpack + slot bookkeeping |
| `src/server/game/loot.zig` | R | Loot / item-table helpers — extracted verbatim from game.zig. ecsIdFromItemName, loot bags, and loot-spawn broadcasts |
| `src/server/game/movement_helpers.zig` | R | Movement envelope helpers extracted from game.zig. Power-grid trigger activation and horizontal speed envelope |
| `src/server/game/net.zig` | R | Net send path for Game: reliable-window pump, framed fan-out, and the broadcast helpers |
| `src/server/game/net_handlers.zig` | R | Net ingress extracted from game.zig — onConnected / onData / dispatchGamePayload. Verbatim bodies; game.zig keeps one-line forwarders |
| `src/server/game/player.zig` | R | Player progression / gamestage / XP — extracted from game.zig; helpers take *Game. |
| `src/server/game/quest.zig` | R | Quest helpers — journal snapshots + trader offers + POI quest events. Extracted from game.zig; helpers take *Game (called as game_quest.foo(g, …)) |
| `src/server/game/rate_limits.zig` | Z | C2S rate limits extracted from game.zig. Inv/block token buckets, damage burst, chat gap |
| `src/server/game/replicate.zig` | R | Serialize-once replicate fan-out extracted from game.zig. Verbatim move — called via forwarder in game.zig |
| `src/server/game/replicate_health.zig` | R | Health replicate path — extracted verbatim from game.zig. Thin forwarder keeps callers unchanged |
| `src/server/game/rescue.zig` | R | Deep-void rescue extracted from game.zig |
| `src/server/game/send_extra.zig` | R | Framed send helpers extracted from game.zig |
| `src/server/game/session_drop.zig` | R | Client slot teardown extracted from game.zig |
| `src/server/game/sleeper.zig` | R | Sleeper-volume scan + spawn extracted from game.zig |
| `src/server/game/social.zig` | R | Buff + party/ally helpers extracted from game.zig (verbatim bodies) |
| `src/server/game/stability.zig` | R | Stability helpers extracted verbatim from game.zig |
| `src/server/game/step.zig` | R | Main tick step — extracted verbatim from game.zig. `Game.step` and helpers that are only called from the step |
| `src/server/game/tests.zig` | R | Game integration tests: peerIpKey, player persist, claims, evidence, etc. Bodies are verbatim copies from src/server/game.zig (kept as integration tes |
| `src/server/game/tick.zig` | R | Tick orchestration — extracted from game.zig; helpers take *Game. Bodies are verbatim copies from src/server/game.zig (stock asm.il comments kept) |
| `src/server/game/trader.zig` | R | Trader helpers extracted verbatim from game.zig |
| `src/server/game/trader_wire.zig` | R | Trader wire helpers extracted from game.zig. stockEntries + sendTraderSnapshot + handleTrade + applyTraderDataCopyFrom |
| `src/server/game/types.zig` | R | Game-owned types extracted from game.zig: InitOptions, defaults, LandClaim, Client. Canonical definitions live here; game.zig re-exports them so exist |
| `src/server/game/vehicle.zig` | R | Vehicle seat + positions S2C helpers — extracted verbatim from game.zig. seatRider / unseatRider (NetPackageEntityAttach) and the periodic |
| `src/server/game/wasm_host.zig` | R | Wasm host shims for Game — callbacks the plugin layer calls back into. Extracted verbatim so game.zig keeps only a re-export |
| `src/server/game/weather.zig` | R | Weather S2C helpers — extracted verbatim from game.zig. anyEnteredClient, the NetPackageWeather body builder and its send paths |
| `src/server/game/world.zig` | R | Domain — extracted from game.zig; helpers take *Game World / claims / block meta / locks. Bodies copied verbatim from game.zig |
| `src/server/guard_policy.zig` | Z | P4 guard policy: what the server *does* with detector evidence. |
| `src/server/mode.zig` | Z | Gamemode = config pack (+ optional static plugin flag). ADR 0010 step 3. Data-only TOML under modes/<name>.toml. No script VM |
| `src/server/movement.zig` | R | Horizontal movement envelope: max speed over server dt, clamp to last good. No heap; pure math for PosAndRot / RelPosAndRot C2S |
| `src/server/persist.zig` | Z | Save/restore for zdtd-owned persistence: players.zsv (ZPV4), entities.zen (ZENT1), claims.zlc (ZCL1), clock.zcl, weather.zwt (ZWTH1) and the chunk |
| `src/server/phase_gate.zig` | R | Per-package C2S phase allowlist (join SM × package name). Hot path: string compares against static tables; no heap |
| `src/server/replicate_te.zig` | R | Tile-entity replication: the S2C wire out for workstations, storage containers, vending machines and powered blocks |
| `src/server/root.zig` | Z | Server process layer: Game orchestration, config, admin/GSI TCP, scenarios. |
| `src/server/scenarios.zig` | Z | Integration scenarios: two-peer motion, damage wire kill, setblock replicate, persist restart. These call shipped Game handlers (onData/handlePackage/ |
| `src/server/serverinfo_tcp.zig` | R | Stock ServerInformationTcpProvider: TCP on ServerPort serves GameServerInfo text. |
| `src/server/webui.zig` | Z | Operator web UI HTTP listener (WU0–WU2: dashboard + console cmds). Loopback by default; shared secret required when enabled |
| `src/server/zdtd_config.zig` | Z | zdtd.toml: operator tunables (Bucket B), not stock serverconfig. Precedence (applied by caller): CLI > env (webui secret) > world/zdtd.toml > |
| `src/util/clock.zig` | Z | Monotonic nanoseconds and best-effort sleep. |
| `src/util/io_fs.zig` | Z | Thin wrappers around Zig 0.16 `std.Io` for one-shot FS ops. Ordinary file/dir work goes through here or `std.Io` directly, never |
| `src/util/log.zig` | Z | Logging for the zdtd process: boot banners, warnings and errors. |
| `src/util/parallel.zig` | Z | Parallel-for over dense slot ranges with a persistent worker pool. Uses Zig 0.16 `std.Io` mutex/condition (no raw syscalls, no spawn-per-call) |
| `src/util/rng.zig` | Z | Seeded deterministic PRNG for sim paths (loot, AI wander, director picks). |
| `src/util/root.zig` | Z | Shared process utilities (no game domain). |
| `src/util/secret.zig` | Z | Secret comparison helpers shared by every credential check (LiteNet connect key, webui secret, telnet admin password) |
| `src/util/sim.zig` | Z | Deterministic simulation mode: virtual clock + serial parallel ranges + DST fault injection lifecycle. Enable at the start of a DST harness so |
| `src/util/tcp_listen.zig` | Z | Non-blocking TCP listen helper via Zig 0.16 `std.Io.net` listen + thin posix accept/read/write. No `std.os.linux` in callers (admin, GSI, webui) |
| `src/util/toml_bind.zig` | Z | toml_bind.zig: comptime-reflected TOML-subset binder (ADR 0021 decision 1). |
| `src/version.zig` | Z | Product and compatibility versions reported to operators |
| `src/wire/binary.zig` | R | Little-endian readers/writers matching .NET BinaryReader/Writer (7-bit strings) |
| `src/wire/frame.zig` | R | Game channel envelope + inner packages (stock NetConnectionSimple layout) |
| `src/wire/packages.zig` | R | Golden package body builders/parsers for join, motion, damage, spawn, TE. Prefer this facade for all wire/stock_* body modules (and te_types); leaf |
| `src/wire/platform_user.zig` | R | PlatformUserIdentifierAbs wire codec (stock V3.1.0 b14). |
| `src/wire/root.zig` | R | Wire package layer: binary LE helpers, frames, stock body builders. |
| `src/wire/stock_buff.zig` | R | Stock buff wire (V3.1.0 b14): NetPackageAddRemoveBuff body and the EntityBuffs blob carried by NetPackageEntityStatsBuff and PlayerDataFile.buffData |
| `src/wire/stock_chunk.zig` | R | Stock `Chunk.write(PooledBinaryWriter, bNetwork=true)` encoder. Derived on V3.0.1, verified against the V3.1.0 b14 client: the live join |
| `src/wire/stock_deco.zig` | R | Stock NetPackageDecoUpdate + DecoObject wire (derived V3.0.1, live on V3.1.0 b14). Client fixed-size worlds only show grass/trees from server deco pac |
| `src/wire/stock_entity.zig` | R | Stock EntityCreationData + NetPackageEntitySpawn (networkWrite=true). |
| `src/wire/stock_inv.zig` | R | Stock inventory wire (ItemValue/ItemStack/Bag/Equipment/NetPackagePlayerInventory). Derived on V3.0.1, carried to V3.1.0 b14; version-specific fields  |
| `src/wire/stock_nameid.zig` | R | Stock `NameIdMapping` blob (the `data` payload of NetPackageIdMapping). |
| `src/wire/stock_party.zig` | R | NetPackagePartyActions (ToServer) + NetPackagePartyData (ToClient) bodies (RE ../7dtd-research/docs/parties-factions.md §3) |
| `src/wire/stock_quest.zig` | R | Stock quest journal + NPCQuestList QuestPacketEntry wire (V3.x). Matches QuestJournal.Write v5, Quest.Write (FileVersion 8), and |
| `src/wire/stock_sign.zig` | R | Stock NetPackageSignDataResponse body builder (prefab sign libraries). Entry data (`SignEntry`, catalog load) lives in assets/signs.zig; only the |
| `src/wire/stock_te.zig` | R | Stock V3.1.0 NetPackageTileEntity payload for composite storage (network modes). |
| `src/wire/stock_xp.zig` | R | NetPackageEntityAddExpClient body (ToClient XP grant; RE ../7dtd-research/il/netpackages-v3.1.0/NetPackageEntityAddExpClient_il.txt) |
| `src/wire/te_types.zig` | R | Stock TileEntityType enum values (RE: TileEntityType / network TE discriminant). Named constants only; not loaded from XML (engine enum, not game data |
| `src/world/biomes.zig` | R | Load stock `biomes.png` (RGBA8 non-interlaced) for chunk biome ids. PNG pixels = biomemapcolor RGB keys (biomes.xml), NOT biome ids |
| `src/world/chunk_flush.zig` | Z | Async chunk flush: encode on the tick thread, write on one background thread. |
| `src/world/containers.zig` | Z | World-position keyed loot containers (block TE storage) |
| `src/world/deco_mirror.zig` | R | Mirror placed decorations into the server block store, so collision, harvest and chunk streaming agree with what the client renders |
| `src/world/dem.zig` | R | Copernicus GLO-30 DEM codec: COG header parse, tile decode, S3 object key and elevation-to-block mapping (fuzz-covered in src/fuzz.zig). The S3 |
| `src/world/dtm.zig` | R | Stock 7DTD baked heightmap loader (Navezgane / Pregen*). |
| `src/world/noise.zig` | Z | OpenSimplex2-family gradient noise (clean-room) + fBm / ridged / domain warp. Pure functions of (seed, coords): no global RNG. Same seed+coords always |
| `src/world/prefabs.zig` | R | Stock world prefabs.xml index + footprint stamping on heightmaps. Block paint: stock `.tts` via `tts.zig` (Prefab.readBlockData raw types), |
| `src/world/root.zig` | Z | World store layer: chunks, map data (DTM/prefabs/TTS), containers, TE state. |
| `src/world/sleepers.zig` | R | Prefab sleeper volumes: parse XML + wake/spawn on player enter |
| `src/world/stability.zig` | R | Stock block stability plane and falling-block trigger (RE: `../7dtd-research/docs/stability.md`, dumps 2026-08-06) |
| `src/world/store.zig` | R | Authoritative block world: 16×256×16 columns, DTM heights, ZCH3 disk (.zch). v3 magic ZCH3: heights + optional u32 rawData + optional texture/density |
| `src/world/subbiome_noise.zig` | R | Stock subbiome noise for deco placement (GAP_ANALYSIS 18): a clean-room port of `PerlinNoise` + `WorldBiomeProviderFromImage::GetSubBiomeIdxAt`, so |
| `src/world/terrain_snapshot.zig` | R | Read-mostly terrain footing snapshot for the A* inner loop. |
| `src/world/tts.zig` | R | Stock prefab `.tts` block paint (Prefab.readBlockData, V3.x file version 19). |
| `src/world/vending.zig` | Z | World-position keyed vending machine tile entities (TileEntityVendingMachine). |
| `src/world/water.zig` | R | Stock water_info.xml point sources (used as local water-table hints) |
| `src/world/weather.zig` | R | Stock WeatherManager storm / bloodMoon state machine, server side. |
| `src/world/workstations.zig` | Z | World-position keyed workstation state (forge/campfire/workbench TE 12). Slots mirror TileEntityWorkstation arrays; craft tick advances the queue |
| `src/world/worldgen.zig` | R | On-the-fly procedural chunk generation (W0/W1/W2). Pure function of (seed, chunkX, chunkZ): no full-map bake, no global RNG |
## 3. Constants ledger (behavioral values)

Every constant below changes game behavior. Source is the stock XML element or
the IL-verified RE doc that specifies it. Where zdtd diverges from stock, the
row says so and names the tracking item. Constants that only size arrays or
pace the wire are covered by their file's row in §2 and are not repeated here.

### 3.1 Sim rules (`src/ecs/rules.zig`)

| Constant | Value | B | Stock source |
|---|--:|:-:|---|
| `Combat.attack_damage` | 8.0 | A | **Floor**: `entityclasses.xml` HandItem → `items.xml` DamageEntity wins when non-zero |
| `Combat.attack_cooldown_s` | 1.2 | R | Policy: stock melee interval approx, no entityclasses field |
| `Ai.sense_dist_sq` | 48² | A | **Floor**: `entityclasses.xml` SightRange (stock 27/30/40 m per class) |
| `Ai.chase_speed` | 2.2 | A | **Floor**: `entityclasses.xml` MoveSpeedAggro ×1.6 when non-zero |
| `Ai.wander_speed` | 0.8 | A | **Floor**: `entityclasses.xml` MoveSpeed ×10 when non-zero |
| `Ai.full_dist_sq` / `mid_dist_sq` | 64² / 225 | R | LOD steps (RE: entity-ai.md AI LOD) |
| `Ai.execute_delay_scale` | 0.85 | R | `EAITaskList.executeDelayScale` base (asm.il:437541) |
| `Ai.look_turn_speed_deg` | 250.0 | A | Per-class MaxTurnSpeed, zombieTemplateMale (`entityclasses.xml`) |
| `Ai.revenge_window_s` | 20.0 | R | Revenge target window, 400 ticks @ 20 Hz (RE: entity-ai.md) |
| `Bloodmoon.party_*` | 80/150/40/30 | R | `AIDirectorBloodMoonParty` (asm.il 413090-413140) |
| `Progression.*` | see fields | Z | **Invented placeholders** (WORK_PLAN T16); stock ships survival from buffs.xml `buffStatusHungry01-03` / `Thirsty01-03` damage + `FoodChangeOT`/`WaterChangeOT`/`HealthChangeOT`/`StaminaChangeOT` + items.xml `StaminaLoss` |

### 3.2 AIDirector (`src/ecs/aidirector.zig`)

| Constant | Value | B | Stock source |
|---|--:|:-:|---|
| `bm_parties_cap` | 8 | R | Blood-moon party array cap (RE: aidirector.md) |
| `wandering_horde_size` | 6 | R | Stock wandering horde size (RE: aidirector.md) |
| `wandering_spawn_dist` | 92.0 | R | Wandering horde spawn radius (RE: aidirector.md) |
| `wander_min_gap` / `wander_max_gap` | 12 s / 24 s | R | Wandering-horde scheduling window (RE: aidirector.md) |
| `heat_cooldown_seconds` | 120 | Z | **Diverges**: stock `AIDirectorChunkData.FindBestEventAndReset` region cooldown is **240 s** (aidirector.md 2026-08-07; audit A41) |
| `heat_neighbor_cooldown_seconds` | 60 | Z | **Diverges**: stock `StartCooldownOnNeighbors` 180 s / 720 s (aidirector.md; audit A41) |
| `heat_spawn_threshold` | 25.0 | R | Heat threshold for spawner events (RE: aidirector.md chunk-data cooldowns) |
| `default_max_alive_zombies` | 24 | A | Stock MaxSpawnedZombies default (serverconfig) |

### 3.3 Entity HP (`src/assets/entities.zig`)

| Constant | Value | B | Stock source |
|---|--:|:-:|---|
| `EntityDef.max_hp` default | 40 | Z | **Diverges**: stock HP ships as `entityclasses.xml` `<passive_effect name="HealthMax" operation="base_set">` + `<replace_passive_effect>` variables (`healthSlim=125` … `healthSlimInfernal=1600`); not parsed yet (audit A34, P1). zombieBoe falls to 40 instead of 125±15% |

### 3.4 Class table (`src/ecs/world.zig` 16-row `class_table`)

| Constant | Value | B | Stock source |
|---|--:|:-:|---|
| `class_table` rows | 16 | A | `entityclasses.xml` per-class defs + `entitygroups.xml` ZombiesAll (29 members); only ~6 classes reachable today, rest spawn with zombieBoe stats (audit A35, P2; GAP_ANALYSIS 1828-1838) |

### 3.5 Movement envelope (`src/server/movement.zig`)

| Constant | Value | B | Stock source |
|---|--:|:-:|---|
| `max_horizontal_speed_mps` | 20.0 | R | Soft cap above sprint (~6 m/s) + vehicle margin; no stock key (audit B29; `[authority]` tunable planned) |

### 3.6 Guard policy (`src/server/guard_policy.zig`)

| Constant | Value | B | Stock source |
|---|--:|:-:|---|
| `kick_delay_ticks` / `shed_hold_ticks` / `weak_break_rate_per_window` | 10 / 40 / 900 | Z | zdtd-owned P4 policy (audit B30; no stock counterpart) |

### 3.7 Survival / weather / power / quest (tracked divergences)

| Location | Value | R | Stock source |
|---|--:|:-:|---|
| `ecs/electric.zig` power tick | ~6.25 Hz | R | RE: tile-entities-power.md (PowerManager ~6.25 Hz root forest tick) |
| `world/weather.zig` storm/blood-moon | — | R | RE: weather-environment.md (server-authoritative storm state machine) |
| `ecs/poi_lock.zig` `unlock_grace` | 2000 | R | QuestEventManager `PrefabInstance.lockInstance` (QuestLockInstance, asm.il 1001892+) |
| `ecs/party.zig` | max 8, shared XP | R | RE: parties-factions.md §2 (party max 8, `startingXP*(1-0.1*inRange)`) |
| `world/stability.zig` | — | R | RE: stability.md (StabilityInitializer spread/clear, GetBlockStability BFS) |
| `server/game/constants.zig` | caps | R | Game-wide caps; behavioral subset tracked in GAP_ANALYSIS (B31-B37) |

## 4. Coverage and maintenance

- `python3 tools/provenance_scan.py` gates **file coverage 187/187** and ledger
  well-formedness (every row: bucket + non-empty source; every constant anchor
  file exists). Wire it into `make check` after the first green run.
- After a game update: re-run `../../7dtd-research/tools/parity/drift-check.sh`,
  then re-verify the R rows against the new pin (see RE_GAP_CLOSURE §4).
- Divergences are tracked in GAP_ANALYSIS / WORK_PLAN; the audit's per-finding
  table lives in `archive/HARDCODE_AUDIT_2026-08-08.md` (re-verify on change).