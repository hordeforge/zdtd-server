//! Game server: join SM, tick, interest, combat, persistence.
//! Simulation is an SoA ECS (`ecs.World` + systems).

const std = @import("std");
const version = @import("../version.zig");
const apm = @import("../apm/root.zig");
const clock = @import("../util/clock.zig");
const ln_server = @import("../litenet/server.zig");
const ln_peer = @import("../litenet/peer.zig");
const wire_frame = @import("../wire/frame.zig");
const packages = @import("../wire/packages.zig");
const world_store = @import("../world/store.zig");
const subbiome_noise = @import("../world/subbiome_noise.zig");
const deco_mirror = @import("../world/deco_mirror.zig");
const ecs = @import("../ecs/root.zig");
const systems = @import("../ecs/systems.zig");
const parallel_util = @import("../util/parallel.zig");
const protocol = @import("../protocol.zig");
const game_net = @import("game/net.zig");
const game_tick = @import("game/tick.zig");
const game_buff_events = @import("game/buff_events.zig");
const game_world_tick = @import("game/world_tick.zig");
const game_map = @import("game/map.zig");
const game_bot = @import("game/bot.zig");
const game_world = @import("game/world.zig");
const game_player = @import("game/player.zig");
const game_join = @import("game/join.zig");
const game_quest = @import("game/quest.zig");
const game_social = @import("game/social.zig");
const game_trader = @import("game/trader.zig");
const game_stability = @import("game/stability.zig");
const game_replicate = @import("game/replicate.zig");
const game_sleeper = @import("game/sleeper.zig");
const game_hooks = @import("game/hooks.zig");
const game_deco = @import("game/deco.zig");
const game_loot = @import("game/loot.zig");
const game_craft = @import("game/craft.zig");
const game_chunk_stream = @import("game/chunk_stream.zig");
const game_game_events = @import("game/game_events.zig");
const game_chunk_fill = @import("game/chunk_fill.zig");
const game_weather = @import("game/weather.zig");
const game_vehicle = @import("game/vehicle.zig");
const game_config_files = @import("game/config_files.zig");
const game_movement_helpers = @import("game/movement_helpers.zig");
const game_net_handlers = @import("game/net_handlers.zig");
const game_rate_limits = @import("game/rate_limits.zig");
const game_blockmeta = @import("game/blockmeta.zig");
const game_clock_persist = @import("game/clock_persist.zig");
const game_locks = @import("game/locks.zig");
const game_trader_wire = @import("game/trader_wire.zig");
const game_send_extra = @import("game/send_extra.zig");
const game_rescue = @import("game/rescue.zig");
const game_guard = @import("game/guard.zig");
const game_session_drop = @import("game/session_drop.zig");
const game_init_assets = @import("game/init_assets.zig");
const game_init_world = @import("game/init_world.zig");
const game_lifecycle = @import("game/lifecycle.zig");
const persist = @import("persist.zig");
const admin_console = @import("admin_console.zig");
const game_types = @import("game/types.zig");
const ConsoleOut = admin_console.ConsoleOut;
const TargetResult = admin_console.TargetResult;
const assets_blocks = @import("../assets/blocks.zig");
const assets_items = @import("../assets/items.zig");
const assets_item_modifiers = @import("../assets/item_modifiers.zig");
const assets_signs = @import("../assets/signs.zig");
const assets_gameevents = @import("../assets/gameevents.zig");
const assets_placeholders = @import("../assets/blockplaceholders.zig");
const assets_localization = @import("../assets/localization.zig");
const world_tts = @import("../world/tts.zig");
const assets_entities = @import("../assets/entities.zig");
const assets_recipes = @import("../assets/recipes.zig");
const assets_loot = @import("../assets/loot.zig");
const assets_entitygroups = @import("../assets/entitygroups.zig");
const assets_gamestages = @import("../assets/gamestages.zig");
const assets_maxdamage = @import("../assets/maxdamage.zig");
const assets_noise = @import("../assets/noise.zig");
const assets_traders = @import("../assets/traders.zig");
const assets_npc = @import("../assets/npc.zig");
const assets_block_textures = @import("../assets/block_textures.zig");
const assets_painting = @import("../assets/painting.zig");
const assets_spawning = @import("../assets/spawning.zig");
const assets_worldglobal = @import("../assets/worldglobal.zig");
const assets_buffs = @import("../assets/buffs.zig");
const assets_progression = @import("../assets/progression.zig");
const assets_vehicles = @import("../assets/vehicles.zig");
const assets_storage_pairs = @import("../assets/storage_pairs.zig");
const biomes_mod = @import("../world/biomes.zig");
const terrain_snapshot = @import("../world/terrain_snapshot.zig");
const interest = @import("../ecs/interest.zig");
const party = @import("../ecs/party.zig");
const admin_mod = @import("admin.zig");
const admin_cmds = @import("admin_cmds.zig");
const webui_mod = @import("webui.zig");
const mcp_mod = @import("mcp_transport.zig");
const serverinfo_tcp = @import("serverinfo_tcp.zig");
const containers_mod = @import("../world/containers.zig");
const signs_mod = @import("../world/signs.zig");
const vending_mod = @import("../world/vending.zig");
const light_te_mod = @import("../world/light_te.zig");
const workstations_mod = @import("../world/workstations.zig");
const sleepers_mod = @import("../world/sleepers.zig");
const server_config = @import("config.zig");
const assets_paths = @import("../assets/paths.zig");
const modlets = @import("../assets/modlets.zig");
const movement = @import("movement.zig");
const evidence_mod = @import("evidence.zig");
const guard_policy = @import("guard_policy.zig");
const ally_mod = @import("ally.zig");
const plugin_mod = @import("../plugin/root.zig");

// Stock body modules via packages facade (leaf files stay importable elsewhere).
const stock_sign = packages.stock_sign;
const stock_te = packages.stock_te;
const te_types = packages.te_types;
const platform_user = packages.platform_user;

pub const max_clients = game_types.max_clients;
pub const ObsMask = game_types.ObsMask;
pub const bitOf = game_types.bitOf;
pub const bitOfPeerSlot = game_types.bitOfPeerSlot;

pub const max_land_claims = game_types.max_land_claims;
/// How many of a player's land-protection blocks ride the PersistentPlayerState
/// overlay; the body writer owns the cap and the buffer size derived from it. A
/// player with more claims keeps every one of them server-side (enforcement
/// reads `land_claims`, not this list); only the overlay tail is dropped.
pub const max_lp_blocks_on_wire = packages.stock_inv.max_lp_blocks_on_wire;
pub const max_quest_position_data = @import("game/constants.zig").max_quest_position_data;
pub const max_player_coord = @import("game/constants.zig").max_player_coord;
pub const coordInRange = @import("game/constants.zig").coordInRange;
pub const admin_help_index = @import("game/constants.zig").admin_help_index;
pub const logPersistErr = @import("game/constants.zig").logPersistErr;
pub const Zpv2Drop = @import("game/constants.zig").Zpv2Drop;
pub const zpvRecordLen = @import("game/constants.zig").zpvRecordLen;
pub const zpv2DropName = @import("game/constants.zig").zpv2DropName;

pub const AuthorityMode = server_config.AuthorityMode;

/// Default trader AvailableMoney display value. Stock AvailableMoney is a
/// per-day dukes pool that regenerates and is spent on player sells; zdtd has
/// no trader economy, so trade() credits the player wallet directly. Bucket B:
/// overridable via zdtd.toml [sim] trader_wallet_dukes (default matches the
/// prior fixed value).
pub const default_trader_wallet_dukes = game_types.default_trader_wallet_dukes;

pub const InitOptions = game_types.InitOptions;

pub const max_streamed_chunks_cap = game_types.max_streamed_chunks_cap;
pub const default_max_streamed_chunks = game_types.default_max_streamed_chunks;
pub const default_chunk_stream_radius_min = game_types.default_chunk_stream_radius_min;
pub const default_chunk_stream_radius_max = game_types.default_chunk_stream_radius_max;
pub const default_chunk_adds_per_stream_tick = game_types.default_chunk_adds_per_stream_tick;
pub const default_chunk_stream_period_ticks = game_types.default_chunk_stream_period_ticks;
pub const default_motion_replicate_period_ticks = game_types.default_motion_replicate_period_ticks;
pub const default_pos_heartbeat_period_ticks = game_types.default_pos_heartbeat_period_ticks;
pub const default_world_time_send_ticks = game_types.default_world_time_send_ticks;
pub const default_vehicle_pos_send_ticks = game_types.default_vehicle_pos_send_ticks;
pub const default_sleeper_tick_ticks = game_types.default_sleeper_tick_ticks;
pub const default_turret_sync_ticks = game_types.default_turret_sync_ticks;
pub const default_save_interval_ticks = game_types.default_save_interval_ticks;
pub const default_spawn_area_radius_max = game_types.default_spawn_area_radius_max;
pub const default_max_claimed_damage = game_types.default_max_claimed_damage;
pub const default_max_edit_range = game_types.default_max_edit_range;
pub const default_interest_range = game_types.default_interest_range;
pub const max_block_raw_entries = game_types.max_block_raw_entries;
pub const max_chat_msg_len = game_types.max_chat_msg_len;
pub const default_min_chat_gap_ns = game_types.default_min_chat_gap_ns;
pub const default_inv_bucket_cap = game_types.default_inv_bucket_cap;
pub const default_inv_refill_ns = game_types.default_inv_refill_ns;
pub const default_block_bucket_cap = game_types.default_block_bucket_cap;
pub const default_block_refill_ns = game_types.default_block_refill_ns;
pub const default_min_damage_gap_ns = game_types.default_min_damage_gap_ns;
pub const default_damage_burst_max = game_types.default_damage_burst_max;
pub const default_trader_restock_cap = game_types.default_trader_restock_cap;
pub const default_trader_restock_refill = game_types.default_trader_restock_refill;
pub const default_storm_frequency = game_types.default_storm_frequency;
pub const default_peer_stale_ms = game_types.default_peer_stale_ms;
pub const default_auth_state_ms = game_types.default_auth_state_ms;
pub const default_lock_stale_ns = game_types.default_lock_stale_ns;
pub const default_join_rate_limit_ms = game_types.default_join_rate_limit_ms;
pub const default_craft_max_times = game_types.default_craft_max_times;
pub const default_deco_objects_per_join = game_types.default_deco_objects_per_join;
pub const window_fast_attempts = game_types.window_fast_attempts;
pub const window_retry_sleep_ns = game_types.window_retry_sleep_ns;
pub const window_retry_budget_ns = game_types.window_retry_budget_ns;
pub const map_window_radius = game_types.map_window_radius;
pub const map_window_n = game_types.map_window_n;
pub const critical_retry_budget_ns = game_types.critical_retry_budget_ns;
pub const default_view_radius = game_types.default_view_radius;

pub const max_spawn_ground_scan = game_types.max_spawn_ground_scan;
pub const default_max_players = game_types.default_max_players;
pub const replicate_frame_cap = game_types.replicate_frame_cap;
pub const speeds_body_off = game_types.speeds_body_off;
pub const flags_body_off = game_types.flags_body_off;

pub const LandClaim = game_types.LandClaim;
pub const Client = game_types.Client;

const game_wasm_host = @import("game/wasm_host.zig");
const game_plugin_compose = @import("game/plugin_compose.zig");

pub const playerDamageVerdictAmount = game_hooks.playerDamageVerdictAmount;

pub const stabilityAfterSetBlock = game_stability.stabilityAfterSetBlock;

pub const EntityLookSent = game_types.EntityLookSent;
pub const AttackTargetSent = game_types.AttackTargetSent;
pub const TurretSyncSent = game_types.TurretSyncSent;
pub const VelYSent = game_types.VelYSent;

pub const Game = struct {
    allocator: std.mem.Allocator,
    net: ln_server.Server = .{},
    world: world_store.World,
    /// Entity-component-system sim world.
    sim: ecs.World = .{},
    /// Static plugin host, in-tree test scaffolding (ADR 0020; no dynlib).
    plugins: plugin_mod.PluginHost = .{},
    /// Wasm plugin runtime (ADR 0020): modules loaded from config at init.
    wasm_plugins: plugin_mod.wasm.WasmHost = .{},
    /// Subbiome noise for per-cell deco resolution (GAP 18): seeded like stock
    /// from the world name hash (or the worldgen seed for proc worlds), so a
    /// save decorates identically across joins and restarts.
    sub_noise: subbiome_noise.PerlinNoise = .{},
    /// Per-deco-chunk cache of POI footprints that suppress world decorations
    /// (V3.2.0 `AllowDecorations`, RFC 0007). Built lazily by the sampler; the
    /// prefab list is load-fixed, so no invalidation.
    deco_suppress: game_deco.SuppressCache = .{},
    /// Host callback context for Wasm guests; callbacks recover *Game from
    /// `data` and live in game.zig, so the plugin layer stays Game-free.
    wasm_ctx: plugin_mod.wasm.HostCtx = undefined,
    /// Host-side FPS bots (ADR 0026). NOT ECS entities: the only boundary to
    /// the sim is the Wasm sense/command surface (zdtd.sense / zdtd.queue).
    /// Bots allocate net ids from the shared sim counter (allocBotNetId) and
    /// replicate to clients through the non-ECS path in game/replicate.zig.
    bots: game_bot.BotManager = .{},
    /// Sleeper wake/stage radius (m) for `partyStageAround` staging
    /// (`[sim] sleeper_party_radius`, default 100; see PROVENANCE.md §3.7).
    sleeper_party_radius: f32 = 100.0,
    clients: [max_clients]Client = [_]Client{.{}} ** max_clients,
    harness: apm.Harness = .{},
    /// P4 observe ring (admin `evidence` dumps JSONL lines).
    evidence: evidence_mod.Ring = .{},
    /// P4 guard policy switches (zdtd.toml [authority]). Default log-only.
    guard: guard_policy.Policy = .{},
    /// Ally relationships keyed on platform identity (stock AllyStore).
    /// Persisted to `{world_dir}/allies.zal` across restarts.
    allies: ally_mod.Store = .{},
    /// Per-session party groups keyed on runtime entity id (stock PartyManager;
    /// RE parties-factions.md §2). Session only, thrown away on disband.
    parties: ecs.party.Manager = .{},
    /// Load-shed valve: weak evidence + deferrable broadcasts are dropped while
    /// `tick_n < shed_until_tick`. Armed only by the real-time run() overrun branch.
    shed_until_tick: u64 = 0,
    tick_n: u64 = 0,
    running: bool = true,
    /// Mono instant of Game init; base for stock `mem` uptime (process elapsed).
    /// CLOCK_MONOTONIC is boot-relative on Linux, so raw monoNs would report
    /// host uptime, not this process's.
    start_mono_ns: u64 = 0,
    /// Stock PlayerLogin carries Steam/EOS tickets (multi-KiB). Truncating here
    /// drops login silently and the client hangs at "Connecting…".
    recv_buf: [65536]u8 = undefined,
    // Mixed-surface stock chunks (per-cell density) exceed 64KiB easily.
    send_buf: [262144]u8 = undefined,
    body_buf: [524288]u8 = undefined,
    /// Chunk-encode raw-plane scratch (memoized per-cell BlockValue, shared by
    /// the block layers and the density/water channels). Pre-allocated; no
    /// hot-path heap. 256 KB of the Game allocation.
    chunk_raws: [65536]u32 = undefined,
    /// Deflate match window for the compressed "blocks" NameIdMapping frame.
    deflate_window: [wire_frame.DeflateFramer.window_len]u8 = undefined,
    /// Duplicate-id bitset for the same mapping (one bit per Block.MAX_BLOCKS id).
    nameid_seen: [packages.stock_nameid.max_blocks / 8]u8 = undefined,
    /// Stable copy of the C2S payload under dispatch. Package.body slices alias
    /// this (or the original when oversized) for the whole handlePackage loop;
    /// mid-handler ACK drains must not overwrite the live body storage.
    payload_hold: [65536]u8 = undefined,
    /// Join-phase NetPackageConfigFile blobs for THIS Game's game_dir /
    /// config_dir (was a module-scope cache: a second Game in one process
    /// reused or skipped a rebuild of another instance's rows).
    config_cache: game_config_files.Cache = .{},
    /// C2S channel-envelope parse scratch: dispatch bodies alias its storage
    /// for the whole handlePackage loop, owned by this Game (the module-scope
    /// scratch this replaced let another parse session clobber them).
    frame_state: wire_frame.ParseState = .{},
    /// Guards pumpAcks reentrancy while draining ACKs mid-send / mid-onData.
    /// When true, pollNetOnce only drainControl (no nested onData).
    pumping: bool = false,
    /// Successful sends since the last post-send ACK drain (see pollNetAfterSend).
    sends_since_poll: u32 = 0,
    /// >0 while dispatching a payload that was not copied into payload_hold
    /// (oversized multi-fragment C2S). Suppresses reentrant drainControl so
    /// peer.deliver_buf cannot be rewritten under the live body slices.
    drain_suppressed: u8 = 0,
    /// Serializes chunk-map access from the terrain hooks: parallel AI workers
    /// call getOrCreate (hashmap insert/rehash/evict) concurrently with the
    /// main thread's rank-0 range. Held across the chunk-pointer use because a
    /// rehash on another thread would invalidate it.
    // ponytail: one global lock; shard per chunk-key if AI pathing contends.
    terrain_mu: parallel_util.IoMutex = .{},
    /// Read-only per-tick terrain surface heights. When on, `pathStepAt`
    /// answers hits without `terrain_mu`; misses fall through to the locked hook.
    terrain_snap: terrain_snapshot.Snapshot = .{},
    /// [perf] terrain_snapshot: rebuild + serve the snapshot.
    terrain_snapshot_on: bool = false,
    /// [perf] job_batches: parallel sleeper-volume test pass.
    job_batches: bool = false,
    /// Last-sampled flusher totals, so counters get per-tick deltas.
    flush_seen: struct { queued: u64 = 0, written: u64 = 0, errors: u64 = 0, sync: u64 = 0, waits: u64 = 0 } = .{},
    /// Last-sampled snapshot miss total (same delta sampling).
    snap_misses_seen: u64 = 0,
    /// PlayerKillingMode from serverconfig (0 = PvP off).
    pvp_mode: u8 = 3,
    /// Gameplay multipliers/settings from serverconfig (percent unless noted).
    xp_multiplier: u16 = 100,
    /// Sandbox stock-count multipliers for trader windows and vending
    /// machines (`TraderItemAbundance` / `VendingItemAbundance`, default 1.0;
    /// stock `TraderInfo::SpawnAllItemsFromList` multiplies each rolled count
    /// by the matching one, then `FastMax(1, ...)` floors). Float, like the
    /// parsed sandbox table - LowDefaultHigh is 0.25..2.0.
    trader_item_abundance: f32 = 1.0,
    vending_item_abundance: f32 = 1.0,
    block_damage_player: u16 = 100,
    block_damage_ai: u16 = 100,
    block_damage_ai_bm: u16 = 100,
    /// SandboxCode option 17 IncomingDamage flat override (0 = unset ->
    /// the [rules.difficulty] ladder drives the AI->player scale).
    incoming_damage_modifier: f32 = 0,
    drop_on_death: u8 = 1,
    /// serverconfig `BuildCreate` (stock seeds GameStats[18]/[20] from it).
    build_create: bool = false,
    /// serverconfig `CameraRestrictionMode` -> GameStats[68].
    camera_restriction_mode: u8 = 0,
    /// Sandbox option `AirDropMarker` -> GameStats[53].
    air_drop_marker: bool = true,
    /// Sandbox option `DropOnQuit` -> GameStats[34].
    drop_on_quit: u8 = 0,
    /// Sandbox option `BiomeProgression` -> GameStats[66].
    biome_progression: bool = true,
    death_penalty: u8 = 1,
    land_claim_size: u16 = 41,
    land_claim_online_dur: u16 = 4,
    land_claim_offline_dur: u16 = 4,
    land_claim_expiry_days: u16 = 3,
    land_claim_count: u16 = 3,
    land_claim_dead_zone: u16 = 60,
    land_claim_offline_delay: u16 = 3,
    land_claim_decay_mode: u8 = 0,
    /// LootRespawnDays: world containers re-roll loot this many in-game days
    /// after being touched (0 disables; echoed in the GameStats blob).
    loot_respawn_days: u16 = 7,
    /// Active land claims: owner peer-persistent id keyed by claim block position.
    land_claims: [max_land_claims]LandClaim = undefined,
    land_claims_n: usize = 0,
    /// Last in-game day the land-claim expiry pass ran (day roll detection).
    claims_last_day: u32 = 0,
    /// Last GameStats.blood_moon_day broadcast (GAP §6: re-send on day roll so a
    /// client that sat through its first horde does not keep a stale HUD day).
    /// -1 = not yet computed (first tick records without broadcasting).
    last_bm_day: i32 = -1,
    /// Air drop scheduling: next drop at this world-hour (0 disables).
    air_drop_interval_hours: u16 = 72,
    next_air_drop_hour: u64 = 0,
    /// Authority mode (observe = counters only; correct = hard reject). docs/AUTHORITY.md.
    authority_mode: AuthorityMode = .correct,
    blocks: assets_blocks.BlockTable = assets_blocks.BlockTable.builtin(),
    items: assets_items.ItemTable = assets_items.ItemTable.builtin(),
    /// item_modifiers.xml catalog (RE items.md ItemClassModifier): the tag
    /// gates for mod attachment validation (assets/item_modifiers.zig).
    item_mods: assets_item_modifiers.ModTable = .{},
    /// A stock/config catalog root was requested. Builtin item aliases remain
    /// available only for explicit offline runs; load failures fail closed.
    stock_catalogs_requested: bool = false,
    signs: assets_signs.Catalog = assets_signs.Catalog.empty(),
    entities: assets_entities.EntityTable = assets_entities.EntityTable.builtin(),
    recipes: assets_recipes.RecipeTable = assets_recipes.RecipeTable.builtin(),
    loot: assets_loot.LootTable = assets_loot.LootTable.builtin(),
    entitygroups: assets_entitygroups.GroupTable = assets_entitygroups.GroupTable.builtin(),
    gamestages: assets_gamestages.Table = assets_gamestages.Table.empty(),
    maxdamage: assets_maxdamage.Table = assets_maxdamage.Table.empty(),
    /// sounds.xml `<Noise>` rows keyed by sound-group name (the movement-noise
    /// model's per-clip volume/time/muffle/heat; empty without a game-dir  -
    /// the relay then passes sound through with no AI noise, matching stock
    /// with no data).
    noise_table: assets_noise.Table = assets_noise.Table.empty(),
    /// gameevents.xml action sequences (death/respawn families). Empty offline:
    /// the runner then refuses every sequence rather than inventing one.
    gameevents: assets_gameevents.Table = assets_gameevents.Table.empty(),
    /// blockplaceholders.xml: the per-cell target lists the prefab paint pass
    /// resolves. Empty when the catalog is absent (cells then keep the remap's
    /// first-target stand-in).
    placeholder_table: assets_placeholders.Table = assets_placeholders.Table.empty(),
    /// Merged `Config/Localization.csv` patch set: the base header plus every
    /// cell the modlets write, shipped as NetPackageLocalization (stock sends
    /// it between the id mapping and the config files).
    localization: assets_localization.Table = .{},
    placeholders_loaded: bool = false,
    /// Scratch the paint call reads the ctx through (it takes a pointer, so a
    /// stack local in the caller would not do).
    placeholder_ctx: world_tts.PlaceholderCtx = undefined,
    /// blocks.xml Texture → textureFull defaults (unpainted cells).
    block_textures: assets_block_textures.Table = assets_block_textures.Table.empty(),
    painting: assets_painting.Table = assets_painting.Table.empty(),
    spawning: assets_spawning.Table = assets_spawning.Table.empty(),
    /// worldglobal.xml `<environment>` ambient scales (the night floor for
    /// the stealth/AI ambient leg). Empty without a game dir = the stock
    /// defaults baked into the table.
    worldglobal: assets_worldglobal.Table = assets_worldglobal.Table.empty(),
    /// buffs.xml when present, else the builtin subset: buff names must resolve
    /// or C2S buff traffic is rejected wholesale.
    buffs: assets_buffs.Table = assets_buffs.builtin(),
    progression: assets_progression.LevelCurve = .{},
    progression_table: assets_progression.Table = assets_progression.Table.empty(),
    vehicles: assets_vehicles.Table = assets_vehicles.Table.empty(),
    storage_pairs: assets_storage_pairs.Table = assets_storage_pairs.Table.empty(),
    biome_colors: biomes_mod.ColorTable = biomes_mod.ColorTable.empty(),
    /// Stock electrical block id → power NodeKind/watts, built from maxdamage.
    power_registry: ecs.powerblocks.Registry = .{},
    traders: assets_traders.TraderTable = assets_traders.TraderTable.empty(),
    npc: assets_npc.NpcTable = assets_npc.NpcTable.empty(),
    sleepers: sleepers_mod.Store = sleepers_mod.Store.empty(),
    containers: containers_mod.ContainerStore = .{},
    /// Applied sign texts (world/signs.zig): replayed when a client's chunk
    /// streams in, so a later joiner sees the authored text. Distinct from
    /// `signs`, the signs.xml catalog.
    sign_texts: signs_mod.SignStore = .{},
    workstations: workstations_mod.WorkstationStore = .{},
    /// Placed heat blocks (torches/candles/barrels with HeatMapStrength):
    /// fed to the AI heat map every tick while placed. Workstations feed
    /// through their own burn-state loop and never enter here.
    heat_blocks: [game_types.max_heat_blocks]game_types.HeatBlock = [_]game_types.HeatBlock{.{}} ** game_types.max_heat_blocks,
    heat_block_n: usize = 0,
    /// Vending machines (TileEntityVendingMachine, type 7): per-block TraderData
    /// store keyed by world pos. Created on place, cleared on removal.
    vending: vending_mod.VendingStore = .{},
    /// POI light TEs (TileEntityLight, type 18): authored intensity/range/
    /// colour from the prefab .tts markers, keyed by world pos. Regenerated
    /// from the prefab scan on chunk fill; no persistence file.
    light_te: light_te_mod.Store = .{},
    /// Lock table: channel → holder peer slot (-1 free).
    lock_channel: [16]i32 = .{-1} ** 16,
    lock_holder_entity: [16]i32 = .{-1} ** 16,
    /// When the lock was granted (mono ns); 0 = free. Stale holders auto-release.
    lock_granted_ns: [16]u64 = .{0} ** 16,
    /// Position key for the locked TE (packed xyz); 0 = channel-only lock.
    lock_pos_key: [16]u64 = .{0} ** 16,
    /// Per-IP join throttle (ms since epoch-ish via monoNs/1e6). GAP 12: was 16,
    /// so a busy subnet's extra sources were unthrottled rather than dropped.
    /// GAP 12: was 32; a long-lived server can ban more than a handful of
    /// players without silently forgetting the tail.
    ban_ip: [128]u32 = .{0} ** 128,
    ban_n: usize = 0,
    /// Sparse BlockValue.rawData (rotation/meta bits) for door/shape fidelity.
    /// The chunk plane is the source of truth (GAP 13); this cache mirrors the
    /// hot path write-through. `blockRawAt` prefers a resident chunk over a
    /// hit so a plane-only writer cannot serve stale meta; eviction is a
    /// cache miss, not content loss.
    block_raw_key: [max_block_raw_entries]u64 = .{0} ** max_block_raw_entries,
    block_raw: [max_block_raw_entries]u32 = .{0} ** max_block_raw_entries,
    block_raw_n: usize = 0,
    /// Last-sent EntityLookAt target per entity slot (RE
    /// EntityAlive.SetLookPosition, protocol-packages.md §5.2.1): the 0.0016
    /// sqr-delta gate skips re-sends until the look moves ~0.04 blocks, so
    /// the per-tick look pass is quiet between meaningful target changes.
    entity_look_sent: [ecs.max_entities]EntityLookSent = [_]EntityLookSent{.{}} ** ecs.max_entities,
    /// Edge detector for NetPackageSetAttackTarget: stock sends on every
    /// change, so the per-tick target value only goes out when it differs
    /// from what this slot last published.
    attack_target_sent: [ecs.max_entities]AttackTargetSent = [_]AttackTargetSent{.{}} ** ecs.max_entities,
    /// Ticks until the next NetPackagePersistentPlayerPositions broadcast
    /// (stock GameManager.playerPositionsCountdownTimer, 6 s cadence).
    player_positions_timer: u16 = 0,
    /// Ticks until the next NetPackageClientInfo broadcast (stock
    /// ConnectionManager.updateClientInfo, 5 s cadence).
    client_info_timer: u16 = 0,
    /// Last-sent EntityVelocity vy per entity slot (RE NetEntityDistributionEntry
    /// motion updates): re-sends only when the vertical velocity moves past
    /// 0.1, so falls/jumps stream while rest stays quiet. Gen-pinned per slot.
    entity_vel_sent: [ecs.max_entities]VelYSent = [_]VelYSent{.{}} ** ecs.max_entities,
    /// Last-sent TurretSync (target, on) per entity slot (RE EntityTurret:
    /// re-broadcasts when the target/on state changes, so turrets aim live).
    turret_sync_sent: [ecs.max_entities]TurretSyncSent = [_]TurretSyncSent{.{}} ** ecs.max_entities,
    view_radius: i32 = default_view_radius,
    /// Advertised + soft join cap (ServerMaxPlayerCount); ≤ max_clients.
    max_players: u16 = default_max_players,
    /// Effective server config (loaded file or struct defaults) for late
    /// readers like the getoptions dump; owned here instead of a process
    /// global (paper: shared mutable state belongs to the context).
    effective_config: server_config.Config = .{},
    /// Patch sources (mod Config dirs + --config-overrides) and the modlet
    /// enable/disable state: per-Game data bound into the assets readers for
    /// the load window only (paper: shared mutable state belongs to the
    /// context; two Games in one process cannot read each other's).
    paths_state: assets_paths.State = .{},
    modlets_state: modlets.State = .{},
    /// PlayerSlotsAuthorizer tiers (IL=174); 0 = disabled.
    reserved_slots: u8 = 0,
    reserved_slots_permission: u8 = 0,
    admin_slots: u8 = 0,
    admin_slots_permission: u8 = 0,
    /// serveradmin.xml path (owned) + the mtime seen at the last apply, for
    /// the tick hot-reload poll (stock InitFileWatcher -> OnFileChanged).
    serveradmin_path: ?[]u8 = null,
    serveradmin_mtime: i64 = 0,
    serveradmin_reload_timer: u8 = 100,
    world_name: []const u8 = "zdtd",
    /// Sandbox code echoed in the GameStats blob (GameStatsValues.sandbox_code);
    /// the client decodes TemperatureSurvival / StormFreq / blood-moon gates
    /// from it (RE sandbox-options §8).
    sandbox_code: []const u8 = "",
    sandbox_preset: []const u8 = "",
    server_description: []const u8 = "",
    server_website_url: []const u8 = "",
    region: []const u8 = "",
    language: []const u8 = "",
    play_group: []const u8 = "",
    admin: admin_mod.Server = .{},
    admin_line: [admin_mod.max_cmd]u8 = undefined,
    /// Stock operator lists (`admin`, `ban`, `whitelist`), persisted beside
    /// players.zsv so a restart keeps permissions and live bans.
    admin_list: admin_cmds.PermissionList = .{},
    whitelist: admin_cmds.PermissionList = .{},
    ban_list: admin_cmds.BanList = .{},
    /// When non-null, adminReply also appends into this buffer (webui cmd responses).
    admin_reply_sink: ?[]u8 = null,
    admin_reply_len: usize = 0,
    /// Set only while `handleConsoleCmd` runs `runAdminLine`: the in-game
    /// caller's permission level. Trusted operator paths (TCP/webui) leave
    /// this null so they keep full grant rights. Used to refuse `admin add`
    /// of a more privileged level than the actor (privilege escalation).
    admin_actor_level: ?u16 = null,
    webui: webui_mod.Server = .{},
    /// MCP transport bridge (ADR 0031); polled from step like webui/admin.
    mcp: mcp_mod.Transport = .{},
    /// Comma-separated admin_command allowlist (from InitOptions.mcp_allowlist).
    mcp_allowlist: []const u8 = "",
    /// Stock ServerPort: TCP GameServerInfo. LiteNet listens on info_port+2.
    info_port: u16 = 0,
    info_tcp: serverinfo_tcp.Provider = .{},
    wire_chunks: bool = true,
    /// See InitOptions.deco_trees.
    deco_trees: bool = true,
    /// See InitOptions.deco_mirror.
    deco_mirror: bool = true,
    /// See InitOptions.block_id_mapping.
    block_id_mapping: bool = true,
    deco_objects_per_join: usize = default_deco_objects_per_join,
    /// Set on PlayerData receipt; flushed on the periodic save tick (not per packet).
    players_dirty: bool = false,
    /// Empty = open. Non-empty = LiteNet Connect key; mismatched keys are rejected.
    password: []const u8 = "",
    /// Stream / authority tunables (InitOptions; filled from zdtd.toml via `zdtd_config.applyToInitOptions`).
    max_streamed_chunks: usize = default_max_streamed_chunks,
    chunk_stream_radius_min: i32 = default_chunk_stream_radius_min,
    chunk_stream_radius_max: i32 = default_chunk_stream_radius_max,
    chunk_adds_per_stream_tick: u32 = default_chunk_adds_per_stream_tick,
    chunk_stream_period_ticks: u64 = default_chunk_stream_period_ticks,
    motion_replicate_period_ticks: u64 = default_motion_replicate_period_ticks,
    /// PosAndRot heartbeat cadence for idle entities (zdtd.toml [stream]
    /// pos_heartbeat_period_ticks).
    pos_heartbeat_period_ticks: u64 = default_pos_heartbeat_period_ticks,
    world_time_send_ticks: u64 = default_world_time_send_ticks,
    vehicle_pos_send_ticks: u64 = default_vehicle_pos_send_ticks,
    sleeper_tick_ticks: u64 = default_sleeper_tick_ticks,
    turret_sync_ticks: u64 = default_turret_sync_ticks,
    save_interval_ticks: u64 = default_save_interval_ticks,
    spawn_area_radius_max: i32 = default_spawn_area_radius_max,
    max_claimed_damage: i32 = default_max_claimed_damage,
    max_claimed_noise_scale: f32 = game_types.default_max_claimed_noise_scale,
    max_edit_range: f32 = default_max_edit_range,
    interest_range: f32 = default_interest_range,
    max_horizontal_speed_mps: f32 = game_types.default_max_horizontal_speed_mps,
    max_vertical_speed_mps: f32 = game_types.default_max_vertical_speed_mps,
    peer_stale_ms: u64 = default_peer_stale_ms,
    lock_stale_ns: u64 = default_lock_stale_ns,
    join_rate_limit_ms: u64 = default_join_rate_limit_ms,
    craft_max_times: u16 = default_craft_max_times,
    min_chat_gap_ns: u64 = default_min_chat_gap_ns,
    inv_bucket_cap: u8 = default_inv_bucket_cap,
    inv_refill_ns: u64 = default_inv_refill_ns,
    block_bucket_cap: u8 = default_block_bucket_cap,
    block_refill_ns: u64 = default_block_refill_ns,
    min_damage_gap_ns: u64 = default_min_damage_gap_ns,
    damage_burst_max: u8 = default_damage_burst_max,
    trader_restock_cap: u16 = default_trader_restock_cap,
    trader_restock_refill: u16 = default_trader_restock_refill,
    trader_wallet_dukes: i32 = default_trader_wallet_dukes,
    storm_frequency: i32 = default_storm_frequency,
    /// `[sim] trader_use_range` (blocks): trader/vending open-and-echo reach.
    trade_use_range: f32 = 32,
    /// `[sim] party_shared_kill_range` (blocks; stock GameStats[54] default).
    party_shared_kill_range: f32 = 100,
    /// `[quests]` policy (mode pack < zdtd.toml): POI selection band etc.
    quest_policy: ecs.quest.QuestPolicy = .{},
    /// Per-chunk storage/prefab TE scan caps (zdtd.toml [sim] te_scan_*).
    te_scan_block_cap: u32 = game_types.default_te_scan_block_cap,
    te_scan_te_cap: u32 = game_types.default_te_scan_te_cap,
    /// Workstation craft budgets (zdtd.toml [sim] workstation_*).
    workstation_crafts_per_tick: u16 = game_types.default_workstation_crafts_per_tick,
    workstation_craft_backlog: f32 = game_types.default_workstation_craft_backlog,
    /// `[sim] sleeper_cap_gate_enabled`: restore the stock sleeper global
    /// spawn gate (default false = the documented zdtd divergence).
    sleeper_cap_gate_enabled: bool = false,
    /// `[sim] airdrop_*`: airdrop schedule policy (parsed at init; "days"
    /// switches tickAirDrop to the stock-like day-count + TOD schedule).
    airdrop_schedule: enum { interval, days } = .interval,
    airdrop_day_min: u32 = 3,
    airdrop_day_max: u32 = 3,
    airdrop_drop_hour: u32 = 12,
    airdrop_loot_list: []const u8 = "airDrop",
    /// Periodic apm snapshot dump period in ticks (zdtd.toml [apm] dump_every_s).
    apm_report_period_ticks: u64 = game_types.default_apm_report_period_ticks,
    /// Stock ConsoleCmdCommandPermission: per-command required permission
    /// level (0 = no extra requirement; lower = more privileged, matching the
    /// stock 0..1000 direction). Enforced at the in-game console boundary.
    command_levels: [32]CommandLevel = [_]CommandLevel{.{}} ** 32,
    command_levels_n: u8 = 0,

    /// Heap-allocate and init (tests and helpers). Caller must `deinit` then `allocator.destroy`.
    pub fn create(allocator: std.mem.Allocator, world_dir: []const u8, port: u16) !*Game {
        return createWithOptions(allocator, world_dir, port, .{});
    }

    pub fn createWithMap(allocator: std.mem.Allocator, world_dir: []const u8, map_dir: ?[]const u8, port: u16) !*Game {
        return createWithOptions(allocator, world_dir, port, .{ .map_dir = map_dir });
    }

    /// The exact opposite of `createWithOptions`: `deinit`, then free the
    /// allocation. One obvious way for the create/destroy pair instead of
    /// every caller repeating the two-step.
    pub fn destroy(self: *Game) void {
        self.deinit();
        self.allocator.destroy(self);
    }

    pub fn createWithOptions(allocator: std.mem.Allocator, world_dir: []const u8, port: u16, opts: InitOptions) !*Game {
        // Reject before allocating Game (large SoA); LiteNet uses ServerPort+2.
        if (port > std.math.maxInt(u16) - 2) return error.InvalidPort;
        const g = try allocator.create(Game);
        errdefer allocator.destroy(g);
        try g.initWithOptions(allocator, world_dir, port, opts);
        return g;
    }

    /// Initialize into an existing allocation (must be heap for live server size).
    pub fn initWithOptions(self: *Game, allocator: std.mem.Allocator, world_dir: []const u8, port: u16, opts: InitOptions) !void {
        // Stock uses ServerPort+2 for LiteNet. Values above this range wrap to
        // an unrelated privileged or ephemeral port.
        if (port > std.math.maxInt(u16) - 2) return error.InvalidPort;
        const max_pl: u16 = blk: {
            const n = if (opts.max_players == 0) default_max_players else opts.max_players;
            break :blk @min(n, @as(u16, max_clients));
        };
        self.* = .{
            .allocator = allocator,
            .world = try world_store.World.init(allocator, world_dir),
            .stock_catalogs_requested = opts.game_dir != null or opts.config_dir != null,
            .view_radius = opts.view_radius,
            .effective_config = opts.effective_config,
            .max_players = max_pl,
            .reserved_slots = opts.reserved_slots,
            .reserved_slots_permission = opts.reserved_slots_permission,
            .admin_slots = opts.admin_slots,
            .admin_slots_permission = opts.admin_slots_permission,
            .wire_chunks = opts.wire_chunks,
            .deco_trees = opts.deco_trees,
            .deco_mirror = opts.deco_mirror,
            .block_id_mapping = opts.block_id_mapping,
            .terrain_snapshot_on = opts.terrain_snapshot,
            .job_batches = opts.job_batches,
            .password = opts.password,
            .pvp_mode = opts.player_killing_mode,
            .xp_multiplier = opts.xp_multiplier,
            .trader_item_abundance = opts.trader_item_abundance,
            .vending_item_abundance = opts.vending_item_abundance,
            .block_damage_player = opts.block_damage_player,
            .block_damage_ai = opts.block_damage_ai,
            .block_damage_ai_bm = opts.block_damage_ai_bm,
            .incoming_damage_modifier = opts.incoming_damage_modifier,
            .death_penalty = opts.death_penalty,
            .drop_on_death = opts.drop_on_death,
            .build_create = opts.build_create,
            .camera_restriction_mode = opts.camera_restriction_mode,
            .air_drop_marker = opts.air_drop_marker,
            .drop_on_quit = opts.drop_on_quit,
            .biome_progression = opts.biome_progression,
            .land_claim_size = opts.land_claim_size,
            .land_claim_online_dur = opts.land_claim_online_durability_modifier,
            .land_claim_offline_dur = opts.land_claim_offline_durability_modifier,
            .land_claim_expiry_days = opts.land_claim_expiry_days,
            .land_claim_count = opts.land_claim_count,
            .land_claim_dead_zone = opts.land_claim_dead_zone,
            .land_claim_offline_delay = opts.land_claim_offline_delay,
            .land_claim_decay_mode = opts.land_claim_decay_mode,
            .loot_respawn_days = opts.loot_respawn_days,
            .air_drop_interval_hours = opts.air_drop_frequency,
            .authority_mode = opts.authority_mode,
            .guard = opts.guard,
            .max_streamed_chunks = blk: {
                if (opts.max_streamed_chunks > max_streamed_chunks_cap) {
                    std.debug.print(
                        "zdtd: max_streamed_chunks={d} exceeds compile cap {d}; clamping\n",
                        .{ opts.max_streamed_chunks, max_streamed_chunks_cap },
                    );
                }
                break :blk @min(opts.max_streamed_chunks, max_streamed_chunks_cap);
            },
            .chunk_stream_radius_min = opts.chunk_stream_radius_min,
            .chunk_stream_radius_max = opts.chunk_stream_radius_max,
            .chunk_adds_per_stream_tick = opts.chunk_adds_per_stream_tick,
            .chunk_stream_period_ticks = opts.chunk_stream_period_ticks,
            .motion_replicate_period_ticks = opts.motion_replicate_period_ticks,
            .pos_heartbeat_period_ticks = opts.pos_heartbeat_period_ticks,
            .world_time_send_ticks = opts.world_time_send_ticks,
            .vehicle_pos_send_ticks = opts.vehicle_pos_send_ticks,
            .sleeper_tick_ticks = opts.sleeper_tick_ticks,
            .turret_sync_ticks = opts.turret_sync_ticks,
            .save_interval_ticks = opts.save_interval_ticks,
            .spawn_area_radius_max = opts.spawn_area_radius_max,
            .max_claimed_damage = opts.max_claimed_damage,
            .max_claimed_noise_scale = opts.max_claimed_noise_scale,
            .max_edit_range = opts.max_edit_range,
            .interest_range = opts.interest_range,
            .max_horizontal_speed_mps = opts.max_horizontal_speed_mps,
            .max_vertical_speed_mps = opts.max_vertical_speed_mps,
            .peer_stale_ms = opts.peer_stale_ms,
            .lock_stale_ns = opts.lock_stale_ns,
            .join_rate_limit_ms = opts.join_rate_limit_ms,
            .craft_max_times = opts.craft_max_times,
            .min_chat_gap_ns = opts.min_chat_gap_ns,
            .inv_bucket_cap = opts.inv_bucket_cap,
            .inv_refill_ns = opts.inv_refill_ns,
            .block_bucket_cap = opts.block_bucket_cap,
            .block_refill_ns = opts.block_refill_ns,
            .min_damage_gap_ns = opts.min_damage_gap_ns,
            .damage_burst_max = opts.damage_burst_max,
            .trader_restock_cap = opts.trader_restock_cap,
            .trader_restock_refill = opts.trader_restock_refill,
            .trader_wallet_dukes = opts.trader_wallet_dukes,
            .storm_frequency = opts.storm_frequency,
            .trade_use_range = opts.trade_use_range,
            .party_shared_kill_range = opts.party_shared_kill_range,
            .quest_policy = opts.quest_policy,
            .te_scan_block_cap = opts.te_scan_block_cap,
            .te_scan_te_cap = opts.te_scan_te_cap,
            .workstation_crafts_per_tick = opts.workstation_crafts_per_tick,
            .workstation_craft_backlog = opts.workstation_craft_backlog,
            .sleeper_cap_gate_enabled = opts.sleeper_cap_gate_enabled,
            .airdrop_schedule = if (std.mem.eql(u8, opts.airdrop_schedule, "days")) .days else .interval,
            .airdrop_day_min = opts.airdrop_day_min,
            .airdrop_day_max = opts.airdrop_day_max,
            .airdrop_drop_hour = opts.airdrop_drop_hour,
            .airdrop_loot_list = opts.airdrop_loot_list,
            .apm_report_period_ticks = if (opts.apm_dump_every_s) |s|
                // 0 disables the periodic dump (mod-by-zero guard; maxInt never fires).
                if (s == 0) std.math.maxInt(u64) else s * protocol.ticks_per_second
            else
                game_types.default_apm_report_period_ticks,
            .deco_objects_per_join = opts.deco_objects_per_join,
            .sandbox_code = opts.sandbox_code,
            .sandbox_preset = opts.sandbox_preset,
            .server_description = opts.server_description,
            .server_website_url = opts.server_website_url,
            .region = opts.region,
            .language = opts.language,
            .play_group = opts.play_group,
            .plugins = .{},
            .wasm_ctx = .{
                .data = self,
                .log_fn = &game_wasm_host.wasmLog,
                .tick_fn = &game_wasm_host.wasmTick,
                .queue_fn = &game_wasm_host.wasmQueue,
                .withdraw_fn = &game_wasm_host.wasmWithdraw,
                .shift_srcs_fn = &game_wasm_host.wasmShiftSrcs,
                .sense_fn = &game_wasm_host.wasmSense,
                .query_fn = &game_wasm_host.wasmQuery,
            },
        };
        // Apply serverconfig gameplay options to the sim director/clock.
        self.sim.director.difficulty = opts.game_difficulty;
        // SandboxCode option 17 IncomingDamage flat override (stock option ->
        // ItemActionAttack.IncomingDamageModifier static; a custom code wins
        // over the per-difficulty ladder).
        self.sim.director.sandbox_incoming = opts.incoming_damage_modifier;
        self.sim.director.max_alive = opts.max_spawned_zombies;
        self.sim.director.max_alive_animals = opts.max_spawned_animals;
        self.sim.director.bloodmoon_enemy_count = opts.blood_moon_enemy_count;
        self.sim.director.bloodmoon_range = opts.blood_moon_range;
        self.sim.director.zombie_move_day = opts.zombie_move;
        self.sim.director.zombie_move_night = opts.zombie_move_night;
        self.sim.director.zombie_move_feral = opts.zombie_feral_move;
        self.sim.director.zombie_move_bm = opts.zombie_bm_move;
        self.sim.director.enemy_difficulty = opts.enemy_difficulty;
        self.sim.director.clock.bloodmoon_frequency = opts.blood_moon_frequency;
        self.sim.director.clock.bloodmoon_range = opts.blood_moon_range;
        self.sim.director.clock.setDayNightLength(opts.day_night_length);
        self.sim.director.clock.setDayLightLength(opts.day_light_length);
        // Trader restock refill policy (zdtd.toml [sim] trader_restock_*).
        self.sim.trader_restock_cap = opts.trader_restock_cap;
        self.sim.trader_restock_refill = opts.trader_restock_refill;
        // Sim rules (ADR 0021): defaults overlaid by the mode pack then
        // zdtd.toml in main.zig; this is the single install point.
        self.sim.rules = opts.rules;
        // [rules.geometry] elevation projection onto the block store (Layer A
        // of the malleable-geometry work; stock defaults are the identity).
        self.world.geometry = opts.rules.geometry;
        // [rules.worldgen] procedural terrain shaping (ADR 0021; defaults are
        // the pre-lift generator constants, so proc output is unchanged).
        self.world.worldgen_params = opts.rules.worldgen;
        // [wire] profile onto the block store (Layer B): column height + plane
        // sizing for chunks, save format and the chunk wire dialect.
        self.world.profile = opts.wire_profile;
        // [rules.world] POI unlock grace onto the lock table (rules install
        // once here; lock() copies it onto new entries).
        self.sim.poi_locks.grace_ticks = opts.rules.world.poi_unlock_grace_ticks;
        // Bot host policy (ADR 0026 / ADR 0021): `[bots]` from mode/toml.
        self.bots.cfg = opts.bot_config;
        // `[bots] weapon_profiles` loadout pool (empty = builtin pool).
        self.bots.parseLoadout();
        // Sleeper wake/stage radius (`[sim] sleeper_party_radius`).
        self.sleeper_party_radius = opts.sleeper_party_radius;
        errdefer {
            // Network half first so fail-closed webui (after net/admin listen)
            // does not leak FDs in tests/library createWithOptions paths.
            // Plugins before stores (same order as successful deinit). Process
            // globals (config S2C cache, mod dirs, modlets, mcp, serveradmin
            // path) share the successful teardown so a mid-create return cannot
            // leave them for the next Game in the process.
            self.webui.deinit();
            self.admin.deinit();
            self.info_tcp.stop();
            self.net.deinit();
            game_plugin_compose.shutdown(self);
            @import("game/lifecycle.zig").deinitStores(self);
            self.world.deinit();
            @import("game/lifecycle.zig").deinitCreateOwned(self);
        }
        // [perf] async_chunk_flush. Offline Game (port 0) runs force-serial, so
        // World.asyncEnabled() keeps writes inline there regardless.
        self.world.async_flush = opts.async_chunk_flush;
        // Arm before any tick/worker can waitKey: otherwise the lock-free
        // `started` early-out races the first submit's spawn-to-enqueue window.
        if (opts.async_chunk_flush) self.world.flush.arm();
        try self.sim.ensureNetMap(allocator);
        // Back the ECS vehicle-physics ground hook with the real block store.
        self.sim.ground_ctx = self;
        self.sim.ground_fn = &game_hooks.heightAtWorld;
        // AI path move probe: destination footing, or blocked.
        self.sim.step_ctx = self;
        self.sim.step_fn = &game_hooks.pathStepAt;
        // AI sense LOS probe: block-solid ray cast (stock CanSee Voxel.Raycast).
        self.sim.solid_ctx = self;
        self.sim.solid_fn = &game_hooks.blockSolidAt;
        self.sim.sight_ctx = self;
        self.sim.sight_fn = &game_hooks.blockSightBlockedAt;
        self.world.movement_solid_ctx = self;
        self.world.movement_solid_fn = &game_hooks.blockMovementSolid;
        self.world.sight_block_ctx = self;
        self.world.sight_block_fn = &game_hooks.blockSightBlocked;
        // Falling-block landing -> Fall-event debris drops (game/chunk_fill).
        self.sim.fall_land_ctx = self;
        self.sim.fall_land_fn = &game_chunk_fill.fallBlocksLanded;
        // Water probe for the AI swim physics (stock inWaterPercent).
        self.sim.water_ctx = self;
        self.sim.water_fn = &game_hooks.blockIsWaterAt;
        // Door-id oracle for the solid probe: an open door is passable.
        self.world.door_id_ctx = self;
        self.world.door_id_fn = &game_hooks.blockIsDoor;
        // Water leveler fills: broadcast each filled cell. The chunk dirty
        // flag is persistence-only, so without this a pour is saved but never
        // sent and a joined client keeps seeing the dry basin.
        self.world.water_fill_ctx = self;
        self.world.water_fill_fn = &game_hooks.broadcastWaterFill;
        // AI sense smell probe: effective radius (stock cSmellRadiusMin / Bleed,
        // the latter bound to buffInjuryBleeding via the buff catalog).
        self.sim.smell_ctx = self;
        self.sim.smell_fn = &game_hooks.smellRadiusFor;
        // Zombie AI bot targets (ADR 0026): bots are not ECS entities, so the
        // AI reaches them through these Game-side hooks (snap + melee damage).
        self.sim.bot_snap_ctx = self;
        self.sim.bot_snap_fn = &game_hooks.botSnapAt;
        self.sim.bot_damage_ctx = self;
        self.sim.bot_damage_fn = &game_hooks.botDamageAt;
        self.sim.place_ctx = self;
        self.sim.place_fn = &game_hooks.placeBlockId;
        self.sim.item_id_ctx = self;
        self.sim.item_id_fn = &game_hooks.itemIdByName;
        self.sim.fuel_value_ctx = self;
        self.sim.fuel_value_fn = &game_hooks.itemFuelValue;
        self.sim.vehicle_tank_ctx = self;
        self.sim.vehicle_tank_fn = &game_hooks.vehicleTankCapacity;
        self.sim.turret_watts_ctx = self;
        self.sim.turret_watts_fn = &game_hooks.turretWatts;
        self.sim.turret_stats_ctx = self;
        self.sim.turret_stats_fn = &game_hooks.turretStats;
        self.sim.stack_ctx = self;
        self.sim.stack_fn = &game_hooks.itemStackFor;
        self.sim.held_light_ctx = self;
        self.sim.held_light_fn = &game_hooks.heldItemLight;
        self.sim.is_armor_ctx = self;
        self.sim.is_armor_fn = &game_craft.itemIsArmor;
        self.sim.armor_pdr_ctx = self;
        self.sim.armor_pdr_fn = &game_craft.armorPdr;
        self.sim.armor_pdr_foreign_ctx = self;
        self.sim.armor_pdr_foreign_fn = &game_craft.armorPdrForeign;
        self.sim.item_degradation_ctx = self;
        self.sim.item_degradation_fn = &game_craft.itemDegradation;
        self.sim.item_penetration_ctx = self;
        self.sim.item_penetration_fn = &game_craft.itemPenetration;
        self.sim.barter_buy_ctx = self;
        self.sim.barter_buy_fn = &game_player.barterBuyScale;
        self.sim.barter_sell_ctx = self;
        self.sim.barter_sell_fn = &game_player.barterSellScale;
        // Quest POI placement: rally objectives need a real prefab footprint.
        self.sim.poi_ctx = self;
        self.sim.poi_fn = &game_hooks.poiRectAtWorld;
        self.sim.poi_tier_ctx = self;
        self.sim.poi_tier_fn = &game_hooks.poiTierAtWorld;
        self.sim.nearest_poi_ctx = self;
        self.sim.nearest_poi_fn = &game_hooks.nearestPoiAtWorld;
        // Stock quest-POI selection (tags/tier/biome/distance + lockouts).
        self.sim.quest_poi_ctx = self;
        self.sim.quest_poi_fn = &game_hooks.questPoiSelectAt;
        // Quest POI lockout exempts party members (stock CheckForPOILockouts).
        self.sim.party_same_ctx = self;
        self.sim.party_same_fn = &game_hooks.partySame;
        // ... and reports bedroll/land-claim home lockouts.
        self.sim.home_ctx = self;
        self.sim.home_fn = &game_hooks.homeLockout;
        // ClearSleepers completion suppresses the POI's sleeper volumes
        // (persistent across restart).
        self.sim.quest_clear_ctx = self;
        self.sim.quest_clear_fn = &game_hooks.questClearSleepers;
        self.sim.quest_sleeper_count_ctx = self;
        self.sim.quest_sleeper_count_fn = &game_hooks.questSleeperCount;
        // QuestActionSpawnGSEnemy spawns gamestage-scaled enemies on phase
        // entry (stock SpawnQuestEntity placement).
        self.sim.quest_spawn_ctx = self;
        self.sim.quest_spawn_fn = &game_hooks.questSpawnGsEnemy;
        // Sell any item, not just stocked ones (stock lets you sell anything):
        // unit price = EconomicValue x EconomicSellScale x SellMarkdown.
        self.sim.sell_price_ctx = self;
        self.sim.sell_price_fn = &game_hooks.traderSellPrice;
        // Root quality_mod lerp bounds for the non-stocked sell path
        // (stock GetSellPrice, asm.il 1830625-1830948).
        self.sim.trader_quality_min_mod = self.traders.quality_min_mod;
        self.sim.trader_quality_max_mod = self.traders.quality_max_mod;
        // ItemValue.PercentUsesLeft for the sell price (worn items sell for
        // less; RE ItemValue IL=17). Same ctx as the sell hook.
        self.sim.percent_uses_left_ctx = self;
        self.sim.percent_uses_left_fn = &game_hooks.percentUsesLeft;
        // Chest/TE contents + door/shape meta survive restart (best-effort: absent on fresh world).
        // Missing persist files are fine on first boot.
        // OpenFailed = no persist file yet (fresh world); anything else is a
        // corrupt/unreadable file whose contents the next save would clobber.
        self.containers.load(self.world.world_dir) catch |e| {
            if (e != error.OpenFailed) {
                logPersistErr(self, "load containers", e);
                return e;
            }
        };
        // Sign texts survive restart (signs.zsg): the store is what the chunk
        // stream replays, so without it every sign comes back blank.
        self.sign_texts.load(self.world.world_dir) catch |e| {
            if (e != error.OpenFailed) {
                logPersistErr(self, "load sign texts", e);
                return e;
            }
        };
        // Vending machines survive restart (vending.zvn); a placed machine that
        // lost its store would silently stop opening.
        self.vending.load(self.world.world_dir) catch |e| {
            if (e != error.OpenFailed) {
                logPersistErr(self, "load vending", e);
                return e;
            }
        };
        // Workstation state survives restart (workstations.zws): a forge's fuel,
        // smelting queue and outputs must not vanish on reboot (rule 21).
        self.workstations.load(self.world.world_dir, self.allocator) catch |e| {
            if (e != error.OpenFailed) {
                logPersistErr(self, "load workstations", e);
                return e;
            }
        };
        // Land claims survive restart (claims.zlc); restored owners re-map on login.
        self.loadClaims() catch |e| {
            if (e != error.OpenFailed) {
                logPersistErr(self, "load claims", e);
                return e;
            }
        };
        // Spawned vehicles / turrets survive restart (entities.zen).
        // Track whether any were restored: the demo pad below must not
        // re-seed persistable kinds (minibike, turret) on top of them, or
        // every restart adds duplicates until the entity table fills.
        var had_saved_entities = false;
        if (self.loadEntities()) |_| {
            had_saved_entities = true;
        } else |e| {
            if (e != error.OpenFailed) {
                logPersistErr(self, "load entities", e);
                return e;
            }
        }
        // Ally relationships survive restart (allies.zal).
        self.allies.load(self.world.world_dir, self.allocator) catch |e| {
            if (e != error.OpenFailed) {
                logPersistErr(self, "load allies", e);
                return e;
            }
        };
        self.parties.init();
        self.loadBlockMeta() catch |e| {
            if (e != error.OpenFailed) {
                logPersistErr(self, "load block meta", e);
                return e;
            }
        };
        if (opts.map_dir) |md| {
            try self.world.loadStockMap(md);
            // WorldInfo.levelName controls the stock client's local raw-world
            // lookup. Keep the selected stock map name (Navezgane/Pregen…)
            // instead of the old generic "stock", which made worldInfoCo
            // request a WorldFolder transfer and then look for a non-existent
            // `World (src: LocalSave, DeviceLocal)` DTM after receipt.
            if (opts.world_name) |name| self.world_name = name else self.world_name = "stock";
        } else if (opts.worldgen_seed) |seed| {
            self.world.enableProc(seed);
            self.world_name = "proc";
            // The single value that regenerates terrain, weather and deco;
            // echo it so a save stays reproducible across restarts and hosts.
            std.debug.print("zdtd: worldgen seed={d} (0x{X})\n", .{ seed, seed });
        }
        // Subbiome noise seed (stock: GetStableHashCode(worldName), asm.il
        // 1301189). The map name is the deterministic identity; a proc world
        // keys off its own seed instead.
        self.sub_noise = subbiome_noise.PerlinNoise.init(if (opts.worldgen_seed) |ws|
            @intCast(ws & 0x7fffffff)
        else
            subbiome_noise.stableHash(opts.game_world));

        try game_init_assets.loadAssets(self, allocator, opts);
        // Operator starter kit (zdtd.toml [sim] spawn_starter_kit): resolve the
        // names once here, where the item catalog is up, into the sim's fixed
        // table. Null/empty leaves the built-in default kit in place.
        game_player.parseStarterKit(self, opts.spawn_starter_kit);
        try @import("game/init_world.zig").initWorld(self, allocator, port, opts, had_saved_entities);
        // Trader stock survives restart (traders.zst): initWorld filled the
        // fresh XML rolls; a saved window overrides them by trader name (stock
        // TraderManager persists its inventory, so a reboot must not re-roll
        // what a player was looking at). Missing file = fresh world.
        self.loadTraders() catch |e| {
            if (e != error.OpenFailed) {
                logPersistErr(self, "load traders", e);
                return e;
            }
        };
        // Saved container and workstation stacks get the same items.xml cap
        // the C2S TE writes apply (c2s/inv.zig clampStackSlots). Both stores
        // load before loadAssets, so this runs here rather than at the load
        // site, where the catalog is not up yet and the clamp would silently
        // no-op. Same rule as the player loader: correct only what the
        // catalog resolves, since an unknown id must keep what was saved
        // rather than fail closed to 1 and destroy a real stack.
        self.clampSavedStoreStacks();
    }

    /// Test hook: scenarios swap the item catalog after construction, so they
    /// need to re-run the pass the constructor already did.
    pub fn clampSavedStoreStacksForTest(self: *Game) void {
        game_init_assets.clampSavedStoreStacks(self);
    }

    /// Bring saved container / workstation stacks down to the current
    /// items.xml cap. See the call site for why it runs after loadAssets.
    fn clampSavedStoreStacks(self: *Game) void {
        return game_init_assets.clampSavedStoreStacks(self);
    }

    /// Clamp only slots whose item the catalog resolves. Unlike
    /// `clampStackSlots` (which fails closed to 1 through itemStackFor), an
    /// unresolved id here keeps its saved count: failing closed is right
    /// against a client claim and destructive against server-written state.
    pub fn clampKnownStacks(self: *const Game, slots: []ecs.components.InvSlot) void {
        return game_init_assets.clampKnownStacks(self, slots);
    }

    /// True when Hard C2S rejects should apply (Correct mode). Observe keeps
    /// join-phase Hard drops but is the flag for future soft-only paths.
    pub fn authorityCorrects(self: *const Game) bool {
        return self.authority_mode == .correct;
    }

    pub fn noteAcceptedMove(self: *Game, c: *Client, x: f32, y: f32, z: f32) void {
        return game_movement_helpers.noteAcceptedMove(self, c, x, y, z);
    }
    pub fn resetMoveEnvelopePeer(self: *Game, peer_slot: usize, x: f32, y: f32, z: f32) void {
        return game_movement_helpers.resetMoveEnvelopePeer(self, peer_slot, x, y, z);
    }
    pub fn applyMovementEnvelope(self: *Game, c: *Client, peer: *ln_peer.Peer, entity_id: i32, x: f32, y: f32, z: f32) game_movement_helpers.ApplyResult {
        return game_movement_helpers.applyMovementEnvelope(self, c, peer, entity_id, x, y, z);
    }

    pub fn spawnPoiTraders(self: *Game) void {
        return game_hooks.spawnPoiTraders(self);
    }

    /// Fail closed on oversize C2S stacks: clamp count to items table max_stack.
    pub fn clampInventoryStacks(self: *Game, inv: *ecs.components.Inventory) void {
        self.clampStackSlots(&inv.slots);
    }

    /// Same clamp as clampInventoryStacks, for any client-writable InvSlot group
    /// (container/workstation TE bodies), not just the player Inventory shape.
    pub fn clampStackSlots(self: *Game, slots: []ecs.components.InvSlot) void {
        for (slots) |*s| {
            if (s.count == 0 or s.item_id == 0) continue;
            const max = game_hooks.itemStackFor(self, s.item_id);
            if (max > 0) s.count = @min(s.count, max);
        }
    }

    /// Refuel generator at world pos if peer is in range. amount = items.xml FuelValue.
    pub fn tryRefuelGenerator(self: *Game, c: *const Client, x: i32, y: i32, z: i32, amount: f32) bool {
        return game_craft.tryRefuelGenerator(self, c, x, y, z, amount);
    }

    /// Refuel the nearest vehicle at the InvTx target coords (tank-capped).
    pub fn tryRefuelVehicle(self: *Game, c: *const Client, x: i32, y: i32, z: i32, amount: f32) bool {
        return game_craft.tryRefuelVehicle(self, c, x, y, z, amount);
    }

    /// items.xml ItemActionEat props for InvTx use (ItemActionEat.consume).
    pub const eatProps = game_craft.eatProps;

    pub fn sendSurvivalStats(self: *Game, peer: *ln_peer.Peer, entity_id: i32, hp: f32, max_hp: f32, food: f32, food_max: f32, water: f32, water_max: f32) !void {
        return game_join.sendSurvivalStats(self, peer, entity_id, hp, max_hp, food, food_max, water, water_max);
    }

    /// PlayerEntityStats.Stamina sync (EntityStatChanged kind 1); the
    /// survival/stamina loop calls it on a throttle like the vitals.
    pub fn sendStaminaStats(self: *Game, peer: *ln_peer.Peer, entity_id: i32, stamina: f32, stamina_max: f32) !void {
        return game_join.sendStaminaStats(self, peer, entity_id, stamina, stamina_max);
    }

    pub const DecoDimCache = game_deco.DecoDimCache;
    pub fn decoSpeciesAt(ctx: ?*anyopaque, wx: i32, wz: i32) packages.stock_deco.SpeciesList {
        return game_deco.decoSpeciesAt(ctx, wx, wz);
    }
    pub fn mirrorDeco(self: *Game, cache: *DecoDimCache, o: packages.stock_deco.DecoObj) bool {
        return game_deco.mirrorDeco(self, cache, o);
    }

    /// Join-time deco burst, mirroring stock `DecoManager.SendDecosToClient`
    /// (asm.il 1263272), which is called from exactly one site in the assembly:
    /// `GameManager.RequestToEnterGame` right after `NetPackageWorldInfo`.
    ///
    /// This is the ONLY window. `DecoManager.Read` (asm.il 1260645) allocates
    /// `loadedDecos` only when `_resetExisting` (= firstPackage) is true and then
    /// unconditionally `loadedDecos.Add(...)`; the client drains that set and sets
    /// it to null at the end of `OnWorldLoaded` (IL_04aa, asm.il 1259485) and never
    /// refills it. So after world load a `firstPackage=false` package with objects
    /// NREs, and a `firstPackage=true` package with objects is silently dropped.
    /// There is no post-join deco path: whatever we do not cover here stays bald
    /// for the session (the same package also marks every client DecoChunk
    /// `isDecorated`, and a fixed-size client generates no deco locally).
    ///
    /// Species and density are biome driven: `decoSpeciesAt` resolves the biome
    /// map, and `generateForDecoChunk` runs stock's 128x128 sampler over it.
    pub fn sendDecoAroundSpawn(self: *Game, c: *Client, peer: *ln_peer.Peer, wx: i32, wz: i32) !void {
        return game_join.sendDecoAroundSpawn(self, c, peer, wx, wz);
    }

    /// Seed the deco sampler keys off, so a chunk decorates identically across
    /// joins and restarts. The worldgen seed when there is one, else the world
    /// name hash: either way it is stable for the life of the save.
    pub fn worldSeed(self: *const Game) u64 {
        if (self.world.worldgen) |wg| return wg.seed;
        return std.hash.Wyhash.hash(0, self.world_name);
    }

    /// Chunk radius covered by the join deco burst. Same clamp as
    /// `streamChunksForClient` so we only touch chunks the join streams anyway
    /// (heightWorld getOrCreate must not become an unbounded world-gen burst).
    pub fn decoRadiusFor(self: *const Game, c: *const Client) i32 {
        var r: i32 = @min(@max(c.view_radius, self.chunk_stream_radius_min), self.chunk_stream_radius_max);
        while (r > 1 and @as(usize, @intCast((2 * r + 1) * (2 * r + 1))) > self.max_streamed_chunks) r -= 1;
        return r;
    }

    pub fn sendSignDataBatches(self: *Game, peer: *ln_peer.Peer) !void {
        return game_join.sendSignDataBatches(self, peer);
    }

    pub fn deinit(self: *Game) void {
        return @import("game/lifecycle.zig").deinit(self);
    }
    pub fn infoPort(self: *const Game) u16 {
        return self.info_port;
    }
    pub fn refreshInfoPlayers(self: *Game) void {
        return @import("game/lifecycle.zig").refreshInfoPlayers(self);
    }
    pub fn playersPath(self: *const Game, buf: []u8) ![]const u8 {
        return persist.playersPath(self, buf);
    }
    pub fn savePlayers(self: *Game) !void {
        return persist.savePlayers(self);
    }
    pub fn wipePlayerRecordsByName(self: *Game, name: []const u8) !u32 {
        return persist.wipePlayerRecordsByName(self, name);
    }
    pub fn tryRestorePlayer(self: *Game, c: *Client) void {
        return persist.tryRestorePlayer(self, c);
    }

    pub fn pollAdmin(self: *Game) void {
        admin_console.pollAdmin(self);
    }

    pub fn adminReply(self: *Game, text: []const u8) void {
        admin_console.adminReply(self, text);
    }

    pub fn pollWebui(self: *Game) void {
        admin_console.pollWebui(self);
    }

    pub fn fillWebuiSnap(self: *Game) void {
        admin_console.fillWebuiSnap(self);
    }

    pub fn handleConsoleCmd(self: *Game, peer: *ln_peer.Peer, c: *Client, body: []const u8) !void {
        return admin_console.handleConsoleCmd(self, peer, c, body);
    }

    pub fn consoleTeleport(self: *Game, player: ?ecs.Slot, it: *std.mem.TokenIterator(u8, .any), out: *ConsoleOut) void {
        admin_console.consoleTeleport(self, player, it, out);
    }

    pub fn consoleSpawnEntity(self: *Game, player: ?ecs.Slot, it: *std.mem.TokenIterator(u8, .any), out: *ConsoleOut) void {
        admin_console.consoleSpawnEntity(self, player, it, out);
    }

    pub fn consoleGiveSelf(self: *Game, player: ?ecs.Slot, it: *std.mem.TokenIterator(u8, .any), out: *ConsoleOut) void {
        admin_console.consoleGiveSelf(self, player, it, out);
    }

    pub fn consoleKickBan(self: *Game, name: ?[]const u8, out: *ConsoleOut, do_ban: bool) void {
        admin_console.consoleKickBan(self, name, out, do_ban);
    }

    pub fn consoleKillAll(self: *Game) u32 {
        return admin_console.consoleKillAll(self);
    }

    pub fn forceAirDrop(self: *Game) bool {
        return admin_console.forceAirDrop(self);
    }

    pub fn forceStorm(self: *Game) bool {
        return admin_console.forceStorm(self);
    }

    pub fn clearStorm(self: *Game) bool {
        return admin_console.clearStorm(self);
    }

    pub fn daysToBloodMoon(self: *const Game) u32 {
        return admin_console.daysToBloodMoon(self);
    }

    pub fn webuiAdminThunk(ctx: *anyopaque, line: []const u8, out: []u8) usize {
        return admin_console.webuiAdminThunk(ctx, line, out);
    }

    pub fn pollMcp(self: *Game) void {
        self.mcp.poll();
    }

    /// MCP frame handler (mcp_transport.FrameFn): route one client JSON-RPC
    /// frame to the plugin that exports on_mcp_frame; returns the guest's
    /// response bytes (0 = nothing to send).
    pub fn mcpFrameThunk(ctx: *anyopaque, frame: []const u8, out: []u8) usize {
        return game_wasm_host.mcpFrameThunk(ctx, frame, out);
    }

    pub fn runBanCommand(self: *Game, sub: admin_mod.BanSub) void {
        admin_console.runBanCommand(self, sub);
    }

    pub fn adminListsPath(self: *const Game, buf: []u8, name: []const u8) ![]const u8 {
        return admin_console.adminListsPath(self, buf, name);
    }

    pub fn saveAdminLists(self: *Game) void {
        admin_console.saveAdminLists(self);
    }

    pub fn saveAdminListFile(self: *Game, name: []const u8, comptime ser: anytype, list: anytype) void {
        admin_console.saveAdminListFile(self, name, ser, list);
    }

    pub fn loadAdminLists(self: *Game) void {
        admin_console.loadAdminLists(self);
    }

    pub fn readAdminList(self: *Game, name: []const u8, label: []const u8, load: *const fn (*Game, []const u8, i64) admin_cmds.LoadResult, now: i64) void {
        admin_console.readAdminList(self, name, label, load, now);
    }

    pub fn replyGamePrefs(self: *Game, filter: []const u8) void {
        admin_console.replyGamePrefs(self, filter);
    }

    pub fn replyGameStats(self: *Game, filter: []const u8) void {
        admin_console.replyGameStats(self, filter);
    }

    pub fn gamePref(self: *Game, filter: []const u8, name: []const u8, comptime fmt: []const u8, args: anytype) void {
        admin_console.gamePref(self, filter, name, fmt, args);
    }

    pub fn applyGamePrefSet(self: *Game, name: []const u8, value: []const u8) bool {
        return admin_console.applyGamePrefSet(self, name, value);
    }

    pub fn replyMem(self: *Game) void {
        admin_console.replyMem(self);
    }

    pub fn adminWrite(self: *Game, comptime f: anytype, args: anytype) void {
        admin_console.adminWrite(self, f, args);
    }

    pub fn resolveAdminTarget(self: *const Game, t: admin_mod.Target) TargetResult {
        return admin_console.resolveAdminTarget(self, t);
    }

    pub fn adminTargetError(self: *Game, t: admin_mod.Target, res: TargetResult) void {
        admin_console.adminTargetError(self, t, res);
    }

    pub fn adminTargetId(self: *const Game, t: admin_mod.Target, buf: []u8) []const u8 {
        return admin_console.adminTargetId(self, t, buf);
    }

    pub fn adminTargetKey(self: *const Game, t: admin_mod.Target, buf: []u8) []const u8 {
        return admin_console.adminTargetKey(self, t, buf);
    }

    pub fn runAdminLine(self: *Game, line: []const u8, source: []const u8) void {
        admin_console.runAdminLine(self, line, source);
    }

    /// `plugin list` / `plugin reload <name>` (wasm plugin ops; wasm_host.zig).
    pub fn adminPlugin(self: *Game, rest: []const u8) void {
        return game_wasm_host.adminPlugin(self, rest);
    }
    pub fn bindPort(self: *const Game) u16 {
        return self.net.port;
    }

    pub fn clientFor(self: *Game, peer: *ln_peer.Peer) ?*Client {
        return game_net.clientFor(self, peer);
    }

    fn isUnreliablePackage(pkg_name: []const u8) bool {
        return game_net.isUnreliablePackage(pkg_name);
    }

    fn isDroppablePackage(pkg_name: []const u8) bool {
        return game_net.isDroppablePackage(pkg_name);
    }

    pub fn sendGame(self: *Game, peer: *ln_peer.Peer, pkg_name: []const u8, body: []const u8) anyerror!void {
        return game_net.sendGame(self, peer, pkg_name, body);
    }

    pub fn sendGameCritical(self: *Game, peer: *ln_peer.Peer, pkg_name: []const u8, body: []const u8) anyerror!void {
        return game_net.sendGameCritical(self, peer, pkg_name, body);
    }

    pub fn awardXp(self: *Game, slot: usize, base: u64) void {
        return game_player.awardXp(self, slot, base);
    }

    pub fn awardXpTagged(self: *Game, slot: usize, base: u64, tags: []const u8) void {
        return game_player.awardXpTagged(self, slot, base, tags);
    }

    pub fn purchaseSkill(self: *Game, slot: usize, skill: []const u8, target_level: u8) bool {
        return game_player.purchaseSkill(self, slot, skill, target_level);
    }

    pub fn purchaseSkillAtCost(self: *Game, slot: usize, skill: []const u8, target_level: u8, cost_override: ?u32) bool {
        return game_player.purchaseSkillAtCost(self, slot, skill, target_level, cost_override);
    }

    /// Fold the opening player's `LootProb` passives onto a tagged loot
    /// entry's probability (stock `getProbability` -> GetValue(79, tags)).
    pub fn lootProbScale(self: *Game, peer_slot: usize, ps: ecs.Slot, tags: []const u8, base: f32) f32 {
        return game_player.lootProbScale(self, peer_slot, ps, tags, base);
    }

    /// Fold the opening player's `LootQuantity` passives onto a spawned
    /// stack's count (stock `SpawnItem` -> GetValue(81, tags), truncated).
    pub fn lootQtyScale(self: *Game, peer_slot: usize, ps: ecs.Slot, item_name: []const u8, entry_tags: []const u8, base: u16) u16 {
        return game_player.lootQtyScale(self, peer_slot, ps, item_name, entry_tags, base);
    }

    pub fn addProgressionLevel(self: *Game, slot: usize, name: []const u8, delta: u8) bool {
        return game_player.addProgressionLevel(self, slot, name, delta);
    }

    /// Respec consumable: refund SkillPoints and clear perk/attribute levels.
    pub fn resetProgression(self: *Game, slot: usize) void {
        game_player.resetProgression(self, slot);
    }

    pub fn setProgressionLevelMax(self: *Game, slot: usize, name: []const u8) bool {
        return game_player.setProgressionLevelMax(self, slot, name);
    }

    pub fn grantMagazineRead(self: *Game, slot: usize, item_id: u16) void {
        game_player.grantMagazineRead(self, slot, item_id);
    }

    pub fn appendUnlockedRecipes(self: *const Game, slot: usize, out: [][]const u8) usize {
        return game_craft.appendUnlockedRecipes(self, slot, out);
    }

    pub fn skillCostOf(self: *const Game, slot: usize, skill: []const u8, target_level: u8) ?u32 {
        return game_player.skillCostOf(self, slot, skill, target_level);
    }

    /// on_perk_spend verdict (ADR 0033): <0 denies the spend, 0 keeps, >0
    /// scales the skill-point cost by percent. Native first, then wasm.
    pub fn perkSpendVerdict(self: *Game, player: i32, skill: []const u8, level: i32, cost: i32) i32 {
        return game_plugin_compose.perkSpend(self, player, skill, level, cost);
    }

    /// on_game_event verdict (ADR 0035): <0 denies the event (no response),
    /// 0 keeps the stock APPROVED ack, >0 keeps it too. Native first, then
    /// wasm; the gameevents.xml phase-machine engine is plugin territory.
    pub fn gameEventVerdict(self: *Game, player: i32, event: []const u8, target: i32, var_count: i32) i32 {
        return game_plugin_compose.gameEvent(self, player, event, target, var_count);
    }

    /// on_stat_changed observer (ADR 0034): fire both plugin hosts. The sim
    /// stays the authority; plugins react/announce. Bounded: one call per
    /// changed player per tick (the survival pass) or per XP award.
    pub fn statChangedObserver(self: *Game, player: i32, hp: i32, food: i32, water: i32, stamina: i32, level: i32, xp: i32) void {
        game_plugin_compose.statChanged(self, player, hp, food, water, stamina, level, xp);
    }

    /// on_evidence observer (T21): fire both plugin hosts with the guard's
    /// evidence event. Read-only - the T20 severity ceiling already ran, and
    /// the guest return is discarded. Bounded: one call per recorded
    /// evidence event.
    pub fn evidenceObserver(self: *Game, tick: i32, peer_local: i32, entity_id: i32, detector: i32, severity: i32, surface: i32, observed_bits: i32, bound_bits: i32) void {
        game_plugin_compose.evidence(self, tick, peer_local, entity_id, detector, severity, surface, observed_bits, bound_bits);
    }

    pub fn skillLevelOf(self: *const Game, slot: usize, skill: []const u8) u8 {
        return game_player.skillLevelOf(self, slot, skill);
    }

    pub fn dismemberSelfChance(self: *const Game, slot: usize, actor_sim_slot: ?ecs.Slot) f32 {
        return game_player.dismemberSelfChance(self, slot, actor_sim_slot);
    }

    pub fn namedPassiveFold(self: *const Game, slot: usize, actor_sim_slot: ?ecs.Slot, name: []const u8) f32 {
        return game_player.namedPassiveFold(self, slot, actor_sim_slot, name);
    }

    pub fn killXpAward(self: *Game, killer_slot: usize, base: u64, scale_pct: u32, trap_kill: bool, killed_entity_id: i32) void {
        return game_player.killXpAward(self, killer_slot, base, scale_pct, trap_kill, killed_entity_id);
    }

    pub fn awardKillNotify(self: *Game, killer_slot: usize, killed_entity_id: i32) void {
        return game_player.awardKillNotify(self, killer_slot, killed_entity_id);
    }

    /// Stock SharedKillServer -> SharedKillClient: an in-range party mate's
    /// EntityKilled quest event fires for the same kill. See game/player.zig.
    pub fn questKillForParty(self: *Game, killer_slot: usize, vx: f32, vz: f32) void {
        return game_player.questKillForParty(self, killer_slot, vx, vz);
    }

    pub fn xpGainFor(self: *Game, victim_nid: i32) u64 {
        return game_player.xpGainFor(self, victim_nid);
    }

    /// Shared reliable-window retry pump: one place for the budget/deadline/sleep
    /// rules so broadcast and sendGameBudget share the same behaviour.
    /// `budget_ns` is always a real deadline (the only cap the fragment retry
    /// checks). Returns error.WindowFull on exhaustion; callers own drop
    /// counters/logs and the packages_broadcast count (via count_broadcast).
    pub fn sendReliablePumped(self: *Game, peer: *ln_peer.Peer, tag: []const u8, framed: []const u8, budget_ns: u64, max_attempts: u32, count_broadcast: bool) !void {
        return game_net.sendReliablePumped(self, peer, tag, framed, budget_ns, max_attempts, count_broadcast);
    }

    pub fn gameStageOf(self: *const Game, slot: usize) i32 {
        return game_player.gameStageOf(self, slot);
    }

    pub fn lootStageOf(self: *const Game, slot: usize) i32 {
        return game_player.lootStageOf(self, slot);
    }

    pub fn lootStageWithContainer(self: *const Game, slot: usize, container_mod: f32, container_bonus: f32) i32 {
        return game_player.lootStageWithContainer(self, slot, container_mod, container_bonus);
    }

    pub fn partyStageAround(self: *const Game, wx: f32, wz: f32, radius: f32) i32 {
        return game_player.partyStageAround(self, wx, wz, radius);
    }

    pub fn partyHighestGameStage(self: *Game) i32 {
        return game_player.partyHighestGameStage(self);
    }

    pub fn partyWeightedGameStage(self: *Game) i32 {
        return game_player.partyWeightedGameStage(self);
    }

    pub fn partyLootStage(self: *const Game) i32 {
        return game_player.partyLootStage(self);
    }

    /// Stock GetRewardItem gameStage = GetTraderStage(quest tier).
    pub fn questRewardStage(self: *const Game, d: ecs.quest.QuestDef, peer: usize) i32 {
        return @import("game/step.zig").questRewardStage(self, d, peer);
    }

    pub fn lootStageForPlayer(self: *Game, peer_slot: usize) i32 {
        return game_player.lootStageForPlayer(self, peer_slot);
    }

    pub fn lootStageForPlayerWithContainer(self: *Game, peer_slot: usize, container_mod: f32, container_bonus: f32) i32 {
        return game_player.lootStageForPlayerWithContainer(self, peer_slot, container_mod, container_bonus);
    }

    /// PlayerEntityStats survival loop (GAP 22; RE entity-stats.md §2):
    /// Food/Water deplete with in-game time (rates from `[sim] rules.progression`,
    /// ADR 0021), starving/dehydrated players take over-time damage and
    /// well-fed ones regen (UpdatePlayerHealthOT branches), and the changed
    /// totals sync to the owner on a throttle. Runs after tickAll so the
    /// world clock already advanced.
    pub fn tickSurvival(self: *Game, dt: f32) void {
        return game_tick.tickSurvival(self, dt);
    }

    /// Passive 43 (`ElementalDamageResist`) for the victim and one damage type,
    /// the non-physical branch of `Equipment.CalcDamage` (IL=83). See
    /// `game/tick.zig` for the fold and its fail-closed ctx rule.
    pub fn elementalDamageResist(self: *Game, ps: ecs.Slot, damage_tag: []const u8) f32 {
        return game_tick.elementalDamageResist(self, ps, damage_tag);
    }

    pub fn foreignGatedResist(self: *Game, victim: ecs.Slot, attacker: ecs.Slot) f32 {
        return game_tick.foreignGatedResist(self, victim, attacker);
    }

    pub fn healthGainLossMult(self: *const Game, peer_slot: usize, comptime passive_name: []const u8) f32 {
        return game_player.healthGainLossMult(self, peer_slot, passive_name);
    }

    pub fn addCatalogBuff(self: *Game, entity_id: i32, ps: ecs.Slot, name: []const u8, instigator_id: i32) bool {
        return game_buff_events.addCatalogBuff(self, entity_id, ps, name, instigator_id);
    }

    pub fn fireBuffFinish(self: *Game, ps: ecs.Slot, def_id: u16) void {
        return game_buff_events.fireBuffFinish(self, ps, def_id);
    }

    pub fn fireBuffEvent(self: *Game, ps: ecs.Slot, def_id: u16, event: assets_buffs.Trigger, other: ?ecs.Slot) void {
        return game_buff_events.fireBuffEvent(self, ps, def_id, event, other);
    }

    pub fn fireBuffStack(self: *Game, ps: ecs.Slot, def_id: u16) void {
        return game_buff_events.fireBuffStack(self, ps, def_id);
    }

    pub fn fireMobBuffEvent(self: *Game, vs: ecs.Slot, def_id: u16, event: assets_buffs.Trigger) void {
        return game_buff_events.fireMobBuffEvent(self, vs, def_id, event);
    }

    pub fn fireLeaveGame(self: *Game, ps: ecs.Slot) void {
        return game_buff_events.fireLeaveGame(self, ps);
    }

    pub fn fireDied(self: *Game, ps: ecs.Slot) void {
        return game_buff_events.fireDied(self, ps);
    }

    pub fn fireAttackedSelf(self: *Game, ps: ecs.Slot, attacker: ecs.Slot, body_part: i16) void {
        return game_buff_events.fireAttackedSelf(self, ps, attacker, body_part);
    }

    pub fn fireAttackedOther(self: *Game, ps: ecs.Slot, victim: ecs.Slot, body_part: i16) void {
        return game_buff_events.fireAttackedOther(self, ps, victim, body_part);
    }

    pub fn fireClassRows(self: *Game, vs: ecs.Slot, event: assets_buffs.Trigger) void {
        return game_buff_events.fireClassRows(self, vs, event);
    }

    pub fn fireRayHit(self: *Game, ps: ecs.Slot, victim: ecs.Slot, body_part: i16) void {
        return game_buff_events.fireRayHit(self, ps, victim, body_part);
    }

    pub fn noteCombat(self: *Game, slot: usize) void {
        game_buff_events.noteCombat(self, slot);
    }

    pub fn fireFallImpact(self: *Game, ps: ecs.Slot, impact_speed: f32) void {
        game_buff_events.fireFallImpact(self, ps, impact_speed);
    }

    pub fn fireJump(self: *Game, ps: ecs.Slot) void {
        game_buff_events.fireJump(self, ps);
    }

    pub fn fireRespawn(self: *Game, ps: ecs.Slot) void {
        game_buff_events.fireRespawn(self, ps);
    }

    pub fn fireAimEdge(self: *Game, ps: ecs.Slot, aiming: bool) void {
        game_buff_events.fireAimEdge(self, ps, aiming);
    }

    pub fn fireCrouchEdge(self: *Game, ps: ecs.Slot, crouching: bool) void {
        game_buff_events.fireCrouchEdge(self, ps, crouching);
    }

    pub fn fireBlockDamaged(self: *Game, ps: ecs.Slot, block_id: u16) void {
        game_buff_events.fireBlockDamaged(self, ps, block_id);
    }

    pub fn fireReloadStart(self: *Game, ps: ecs.Slot) void {
        game_buff_events.fireReloadStart(self, ps);
    }

    pub fn heldWeaponIsRanged(self: *Game, ps: ecs.Slot) bool {
        return game_buff_events.heldWeaponIsRanged(self, ps);
    }

    pub fn fireItemUseBuffs(self: *Game, ps: ecs.Slot, item_id: u16) void {
        return game_buff_events.fireItemUseBuffs(self, ps, item_id);
    }

    pub fn fireKilledOther(self: *Game, ps: ecs.Slot, victim: ecs.Slot) void {
        return game_buff_events.fireKilledOther(self, ps, victim);
    }

    /// Integrate host-commanded bot move intents (ADR 0026). Bots are not ECS
    /// entities; the BotManager owns them and integrates their move intents
    /// here. Replication streams their positions via the non-ECS path.
    pub fn tickBots(self: *Game, dt: f32) void {
        self.bots.tick(self, dt);
    }

    /// Allocate a globally-unique net id for a host-side bot, or null when
    /// the shared sim counter is exhausted. Drawn from the same guarded
    /// counter as ECS spawns (World.allocNetId), so bot ids never collide
    /// with player/zombie/... ids and the wrap policy is one place.
    pub fn allocBotNetId(self: *Game) ?i32 {
        return self.sim.allocNetId();
    }

    pub fn worldHour(self: *const Game) u64 {
        return game_world_tick.worldHour(self);
    }

    pub fn tickAirDrop(self: *Game) void {
        return game_world_tick.tickAirDrop(self);
    }

    pub fn tickZombieBlockDamage(self: *Game) void {
        return game_world_tick.tickZombieBlockDamage(self);
    }
    pub fn actuatePoweredDoors(self: *Game) void {
        return game_world_tick.actuatePoweredDoors(self);
    }

    pub fn drainDigRequests(self: *Game) void {
        return game_world_tick.drainDigRequests(self);
    }

    pub fn drainSleeperWakeups(self: *Game) void {
        return game_world_tick.drainSleeperWakeups(self);
    }

    pub fn tickEntityLookAt(self: *Game) void {
        return game_world_tick.tickEntityLookAt(self);
    }

    pub fn tickAttackTarget(self: *Game) void {
        return game_world_tick.tickAttackTarget(self);
    }

    /// Stock PlayerStealth.TickServer S2C: broadcast NetPackageEntityStealth
    /// every 16 ticks when the packed state changed. See game/player.zig.
    pub fn tickStealthBroadcast(self: *Game) void {
        return game_player.tickStealthBroadcast(self);
    }

    pub fn tickMapChunks(self: *Game) void {
        return game_map.tickMapChunks(self);
    }

    pub fn tickPlayerPositions(self: *Game) void {
        return game_map.tickPlayerPositions(self);
    }

    pub fn tickClientInfo(self: *Game) void {
        return game_world_tick.tickClientInfo(self);
    }
    pub fn tickServerAdminReload(self: *Game) void {
        game_world_tick.tickServerAdminReload(self);
    }

    pub fn broadcastPlayerBackpack(self: *Game, c: *Client) !void {
        return game_map.broadcastPlayerBackpack(self, c);
    }

    pub fn sendOtherPlayerBackpacks(self: *Game, peer: *ln_peer.Peer, joiner: *const Client) !void {
        return game_map.sendOtherPlayerBackpacks(self, peer, joiner);
    }

    /// Block id at world coords (0 = air / unloaded).
    pub fn blockIdAtWorld(self: *Game, x: i32, y: i32, z: i32) u16 {
        const t = world_store.World.worldToChunk(x, z);
        const ch = self.world.getOrCreate(t.pos) catch return 0;
        return ch.blockAt(t.lx, y, t.lz);
    }

    /// Runtime id of the land-claim keystone block (AssignIds "keystoneBlock").
    pub fn landClaimBlockId(self: *const Game) ?u16 {
        return self.maxdamage.idByName("keystoneBlock");
    }

    /// The land claim whose protection area covers (x,z), if any.
    pub fn claimCovering(self: *Game, x: i32, z: i32) ?*LandClaim {
        const half: i32 = @intCast(self.land_claim_size / 2);
        for (self.land_claims[0..self.land_claims_n]) |*claim| {
            if (@abs(x - claim.x) <= half and @abs(z - claim.z) <= half) return claim;
        }
        return null;
    }

    pub fn registerClaim(self: *Game, x: i32, y: i32, z: i32, owner_entity: i32) void {
        return game_world.registerClaim(self, x, y, z, owner_entity);
    }

    pub fn claimAllowed(self: *Game, owner_entity: i32, x: i32, y: i32, z: i32) bool {
        return game_world.claimAllowed(self, owner_entity, x, y, z);
    }

    pub fn removeClaimAt(self: *Game, x: i32, y: i32, z: i32) void {
        return game_world.removeClaimAt(self, x, y, z);
    }

    pub fn repairClaimArea(self: *Game, cx: i32, cz: i32) u32 {
        return game_world.repairClaimArea(self, cx, cz);
    }

    pub fn dropClaimsForName(self: *Game, name: []const u8) u32 {
        return game_world.dropClaimsForName(self, name);
    }

    pub fn markClaimsForEntity(self: *Game, entity: i32, online: bool) void {
        return game_world.markClaimsForEntity(self, entity, online);
    }

    pub fn expireClaims(self: *Game) void {
        return game_world.expireClaims(self);
    }

    /// Persist land claims to {world_dir}/claims.zlc (magic ZCLC | u16 count |
    /// records: x i32, y i32, z i32, name_len u8, name[32], seen_day u32).
    /// Best-effort like the other save paths; owner_entity is not stored (it is
    /// reassigned across restarts and re-mapped on login by name).
    /// Vehicle / turret persistence (GAP "Vehicle, turret, power ... persistence"):
    /// spawned vehicles and turrets survive restart via `entities.zen` (ZENT1,
    /// zdtd-owned like claims.zlc). Power is re-derived from the block grid on
    /// load (spawnTurret re-adds its node); riders are session state and not
    /// persisted (a parked-but-mounted vehicle saves empty).
    pub fn saveEntities(self: *Game) !void {
        return persist.saveEntities(self);
    }

    fn loadEntities(self: *Game) !void {
        return persist.loadEntities(self);
    }

    /// Trader stock persists across restart (traders.zst): a saved window
    /// overrides the fresh XML fill by trader name, so a reboot does not
    /// re-roll what a player was looking at (stock TraderManager saves its
    /// inventory). Entries ride item names (AssignIds ids are version-
    /// dependent); unknown names fail closed to a skipped entry.
    pub fn saveTraders(self: *Game) !void {
        return persist.saveTraders(self);
    }

    fn loadTraders(self: *Game) !void {
        return persist.loadTraders(self);
    }

    pub fn saveClaims(self: *Game) !void {
        return persist.saveClaims(self);
    }

    fn loadClaims(self: *Game) !void {
        return persist.loadClaims(self);
    }

    /// Re-map restored claims to the entity id a player got at login, and mark
    /// the owner online. Called once per login; no-op for unknown names.
    pub fn reclaimForName(self: *Game, name: []const u8, entity_id: i32) void {
        return game_world.reclaimForName(self, name, entity_id);
    }

    /// Re-map restored turrets to the client slot this player just took, so
    /// trap kills pay the player who placed them rather than nobody. Same
    /// shape as `reclaimForName`: the save carries a name because a slot is
    /// per-session, and login is where a name becomes a slot again.
    pub fn reclaimTurretsForName(self: *Game, name: []const u8, slot: usize) void {
        return game_world.reclaimTurretsForName(self, name, slot);
    }

    /// Process pending UDP events (acks free window; data delivered to onData).
    /// Reentrant calls (sendGame / pump_fn mid-onData) only drain control so the
    /// reliable window can free without nested onData corrupting join SM state.
    /// Mid-onData drain uses a private buffer: never `recv_buf`, which still holds
    /// the in-flight uncompressed C2S payload (Package.body aliases).
    /// Post-send ACK drain, every 8th send: pollNetOnce costs a recvfrom
    /// syscall + peer scan per call, and the 64-deep reliable window has ample
    /// headroom between drains. WindowFull retry paths still pump directly.
    pub fn pollNetAfterSend(self: *Game) void {
        return game_net.pollNetAfterSend(self);
    }

    pub fn pollNetOnce(self: *Game) void {
        return game_net.pollNetOnce(self);
    }

    pub fn maxDamageForBlock(self: *const Game, block_id: u16) u16 {
        return game_world.maxDamageForBlock(self, block_id);
    }

    /// Quality-lerped durability cap (`ItemClass.get_MaxUseTimesBase`, passive
    /// 8). 0 = the item has no durability. Used by the loot random-durability
    /// path, which starts a spawned item 20-80% worn.
    pub fn itemMaxUseTimes(self: *const Game, item_id: u16, quality: u8) u32 {
        const d = self.items.byId(item_id) orelse return 0;
        return game_hooks.maxUseTimes(d, quality);
    }

    pub fn wireBlockDamage(self: *const Game, block_id: u16, stored: u16) u16 {
        return game_world.wireBlockDamage(self, block_id, stored);
    }

    pub fn harvestXpForBlock(self: *Game, block_id: u16) u32 {
        return game_world.harvestXpForBlock(self, block_id);
    }

    pub fn getBlockHp(self: *const Game, x: i32, y: i32, z: i32) u16 {
        return game_world.getBlockHp(self, x, y, z);
    }

    /// Voxel line-of-sight gate for `bot shoot` (RFC 0001 §4 host-LOS).
    pub fn botLosClear(self: *Game, from: [3]f32, to: [3]f32) bool {
        return game_world.botLosClear(self, from, to);
    }

    /// Cover point not visible from `threat` (RFC 0001 §3 `zdtd.query`
    /// "cover"); Doom 3 idAASFindCover / clanker `BotBrain.FindCover` port.
    pub fn findCover(self: *Game, from: [3]f32, threat: [3]f32, dist: f32) ?[3]f32 {
        return game_world.findCover(self, from, threat, dist);
    }

    /// Ground/surface Y at world (x, z); bots stand here (spawn + move).
    pub fn groundHeight(self: *Game, x: i32, z: i32) f32 {
        return game_world.groundHeight(self, x, z);
    }

    pub fn setBlockHp(self: *Game, x: i32, y: i32, z: i32, abs: u16) !void {
        return game_world.setBlockHp(self, x, y, z, abs);
    }

    pub fn addBlockDamage(self: *Game, x: i32, y: i32, z: i32, dmg: u16) !u16 {
        return game_world.addBlockDamage(self, x, y, z, dmg);
    }

    /// Run a parsed gameevents.xml sequence for a player (stock runs these
    /// server side: the client's respawn only forwards the request). False
    /// when the table is absent, the name is unknown or the sequence needs an
    /// action this server does not implement.
    pub fn runGameEventSequence(self: *Game, peer_slot: usize, name: []const u8) bool {
        return game_game_events.runGameEventSequence(self, peer_slot, name);
    }

    /// `game_on_respawn_*` for a DeathPenalty stat value (0 none, 1 default,
    /// 2 injured, 3 permanent).
    pub fn respawnSequenceName(penalty: u8) ?[]const u8 {
        return game_game_events.respawnSequenceName(penalty);
    }

    /// `game_on_death_*` for a DeathPenalty stat value.
    pub fn deathSequenceName(penalty: u8) ?[]const u8 {
        return game_game_events.deathSequenceName(penalty);
    }

    /// Stock `World::GetLandProtectionHardnessModifier` for one block: the
    /// divisor a stranger's blast takes inside somebody else's land claim.
    pub fn landProtectionHardnessModifier(self: *Game, wx: i32, wy: i32, wz: i32, instigator_entity: i32) f32 {
        return game_world.landProtectionHardnessModifier(self, wx, wy, wz, instigator_entity);
    }

    /// One block inside a blast (stock Explosion::AttackBlocks damage formula,
    /// destroy/downgrade flow). Both blast paths route through it.
    pub fn blastBlock(
        self: *Game,
        wx: i32,
        wy: i32,
        wz: i32,
        id: u16,
        power: f32,
        falloff: f32,
        category_mult: f32,
        instigator_entity: i32,
    ) bool {
        return game_world.blastBlock(self, wx, wy, wz, id, power, falloff, category_mult, instigator_entity);
    }

    pub fn clearBlockHp(self: *Game, x: i32, y: i32, z: i32) void {
        return game_world.clearBlockHp(self, x, y, z);
    }

    /// Stock Block.OnBlockDamaged downgrade swap raw (0 = no downgrade path;
    /// the caller breaks the block normally). See game/world.zig.
    pub fn downgradeBreakRaw(self: *Game, x: i32, y: i32, z: i32, cur_id: u16) u32 {
        return game_world.downgradeBreakRaw(self, x, y, z, cur_id);
    }

    /// Stock PersistentPlayerList.SpawnPointRemoved: a removed bedroll clears
    /// the owner's respawn point. See game/world.zig.
    pub fn noteBlockRemoved(self: *Game, x: i32, y: i32, z: i32, cur_id: u16) void {
        return game_world.noteBlockRemoved(self, x, y, z, cur_id);
    }

    pub fn noteBlockRemovedEx(self: *Game, x: i32, y: i32, z: i32, cur_id: u16, spill: bool) void {
        return game_world.noteBlockRemovedEx(self, x, y, z, cur_id, spill);
    }

    pub fn noteBlockAdded(self: *Game, x: i32, y: i32, z: i32, new_id: u16) void {
        return game_world.noteBlockAdded(self, x, y, z, new_id);
    }

    pub fn trackHeatBlock(self: *Game, x: i32, y: i32, z: i32, id: u16) void {
        return game_world.trackHeatBlock(self, x, y, z, id);
    }

    pub fn untrackHeatBlock(self: *Game, x: i32, y: i32, z: i32) void {
        return game_world.untrackHeatBlock(self, x, y, z);
    }

    /// Drain Demolition explode requests (entity + block AoE). Runs after the
    /// sim AI pass each tick (Game.step).
    pub fn drainExplosions(self: *Game) void {
        return game_world.drainExplosions(self);
    }

    pub fn setBlockRaw(self: *Game, x: i32, y: i32, z: i32, raw: u32) void {
        return game_world.setBlockRaw(self, x, y, z, raw);
    }

    pub fn blockRawAt(self: *const Game, x: i32, y: i32, z: i32) u32 {
        return game_world.blockRawAt(self, x, y, z);
    }

    pub fn clearBlockRaw(self: *Game, x: i32, y: i32, z: i32) void {
        return game_world.clearBlockRaw(self, x, y, z);
    }

    pub fn saveClock(self: *const Game) !void {
        return game_clock_persist.saveClock(self);
    }
    pub fn restoreClock(self: *Game) void {
        return game_clock_persist.restoreClock(self);
    }

    pub fn saveWeather(self: *const Game) !void {
        return game_blockmeta.saveWeather(self);
    }
    pub fn restoreWeather(self: *Game) void {
        return game_blockmeta.restoreWeather(self);
    }
    pub fn saveBlockMeta(self: *const Game) !void {
        return game_blockmeta.saveBlockMeta(self);
    }
    pub fn saveAllStores(self: *Game) bool {
        return persist.saveAllStores(self);
    }
    fn loadBlockMeta(self: *Game) !void {
        return game_blockmeta.loadBlockMeta(self);
    }

    pub fn packLockPos(x: i32, y: i32, z: i32) u64 {
        return game_locks.packLockPos(x, y, z);
    }
    pub fn firstLockTargetPos(targets_blob: []const u8) ?game_locks.LockPos {
        return game_locks.firstLockTargetPos(targets_blob);
    }
    pub fn clearLockSlot(self: *Game, ch: usize) void {
        return game_locks.clearLockSlot(self, ch);
    }
    /// Force-unlock this peer's other channels before a new grant (game/locks.zig).
    pub fn releaseOtherLocksForPeer(self: *Game, peer_slot: usize, keep_ch: usize) void {
        return game_locks.releaseOtherLocksForPeer(self, peer_slot, keep_ch);
    }
    /// True when this peer holds any lock channel (stock gate 1 validity check).
    pub fn peerHoldsLock(self: *Game, peer_slot: usize) bool {
        return game_locks.peerHoldsLock(self, peer_slot);
    }
    /// Refresh this peer's lock stale window (stock LockManager.ProcessKeepOpen).
    pub fn refreshLocksForPeer(self: *Game, peer_slot: usize) void {
        return game_locks.refreshLocksForPeer(self, peer_slot);
    }
    /// Force-unlock every channel this peer holds, to the peer (stock gate 1 /
    /// ForceUnlockByPlayer). The caller then refuses the new request.
    pub fn releaseAllLocksForPeer(self: *Game, peer_slot: usize) void {
        return game_locks.releaseAllLocksForPeer(self, peer_slot);
    }

    pub fn clearLocksForPeer(self: *Game, peer_slot: usize) void {
        return game_locks.clearLocksForPeer(self, peer_slot);
    }

    /// Drop locks held longer than the lock stale window (tick path).
    pub fn reapStaleLocks(self: *Game) void {
        return game_world_tick.reapStaleLocks(self);
    }

    pub fn reapStalePeers(self: *Game) void {
        return game_world_tick.reapStalePeers(self);
    }

    pub fn peerIpKey(peer: *const ln_peer.Peer) u32 {
        return game_net.peerIpKey(peer);
    }

    pub fn isBanned(self: *const Game, ip: u32) bool {
        return game_net.isBanned(self, ip);
    }

    pub fn banIp(self: *Game, ip: u32) void {
        return game_net.banIp(self, ip);
    }

    pub fn unbanIp(self: *Game, ip: u32) void {
        return game_net.unbanIp(self, ip);
    }

    pub fn pumpAcks(ctx: ?*anyopaque) void {
        const self: *Game = @ptrCast(@alignCast(ctx.?));
        // pollNetOnce reentrancy: control-only drain when already pumping.
        self.pollNetOnce();
    }

    pub fn onConnected(self: *Game, peer: *ln_peer.Peer) !void {
        return game_net_handlers.onConnected(self, peer);
    }
    pub fn onData(self: *Game, peer: *ln_peer.Peer, payload: []const u8) anyerror!void {
        return game_net_handlers.onData(self, peer, payload);
    }
    pub fn dispatchGamePayload(self: *Game, c: *Client, peer: *ln_peer.Peer, payload: []const u8) !void {
        return game_net_handlers.dispatchGamePayload(self, c, peer, payload);
    }

    /// Stock GameServerInfo.ToString(true) body used as NetPackagePlayerLoginAnswer.data.
    pub fn buildLoginGsiText(self: *Game, buf: []u8) ![]const u8 {
        return game_join.buildLoginGsiText(self, buf);
    }

    pub fn handlePackage(self: *Game, c: *Client, peer: *ln_peer.Peer, id: u16, body: []const u8) !void {
        return @import("c2s/dispatch.zig").handlePackage(self, c, peer, id, body);
    }

    pub fn stockEntries(self: *Game, s: ecs.Slot, out: []packages.TraderStockEntry) usize {
        return game_trader_wire.stockEntries(self, s, out);
    }
    pub fn sendTraderSnapshot(self: *Game, peer: *ln_peer.Peer, prefer_slot: ?ecs.Slot) !void {
        return game_join.sendTraderSnapshot(self, peer, prefer_slot);
    }
    pub fn handleTrade(self: *Game, c: *Client, body: []const u8) !void {
        return game_trader_wire.handleTrade(self, c, body);
    }
    pub fn inTradeReach(self: *const Game, c: *const Client, bx: f32, by: f32, bz: f32) bool {
        return game_trader_wire.inTradeReach(self, c, bx, by, bz);
    }
    pub fn applyTraderDataCopyFrom(self: *Game, c: *Client, td: packages.TraderDataToServer) !void {
        return game_trader_wire.applyTraderDataCopyFrom(self, c, td);
    }

    /// Write the P4 evidence ring as JSONL to `path` (admin `evidence dump`).
    /// Returns the number of events written; fails loudly on I/O error so the
    /// operator never mistakes a failed flush for a successful one.
    pub fn dumpEvidenceFile(self: *Game, path: []const u8) !usize {
        return admin_console.dumpEvidenceFile(self, path);
    }
    pub fn sendWorldSpawnPoints(self: *Game, peer: *ln_peer.Peer) !void {
        return game_join.sendWorldSpawnPoints(self, peer);
    }

    /// Build and send NetPackageChunkClusterInfo (protocol.md step 11; client
    /// gates spawn-point application on chunkClusterLoaded).
    pub fn sendChunkClusterInfo(self: *Game, peer: *ln_peer.Peer) !void {
        return game_join.sendChunkClusterInfo(self, peer);
    }

    /// Build and send NetPackageWorldAreas from the trader POIs on the loaded
    /// map (stock: World.TraderAreas, one TraderArea per TraderArea=True
    /// prefab). Position = the decoration origin, size = the prefab size,
    /// protect padding = TraderAreaProtect - 2 (GetProtectPadding), and the
    /// teleport volumes from TeleportVolumeStart/Size (local cells).
    pub fn sendWorldAreas(self: *Game, peer: *ln_peer.Peer) !void {
        return game_join.sendWorldAreas(self, peer);
    }

    /// PrefabInstance.ResetBlocksAndRebuild (asm.il 945360-945387): re-paint a
    /// POI's baked .tts blocks over the area, overwriting player edits, so a
    /// repeatable quest POI can be restored (a cleared or destroyed POI resets
    /// when the next quest dedicates it). The block id is the low 16 bits of
    /// the BlockValue raw (tts.zig:13); each changed block is broadcast as the
    /// authoritative SetBlock. Tag-filter residual: stock resets only
    /// quest-tagged blocks; zdtd re-paints the full prefab footprint.
    pub fn resetPoiBlocks(self: *Game, wx: i32, wz: i32) void {
        return game_quest.resetPoiBlocks(self, wx, wz);
    }

    /// Send the full "blocks" NameIdMapping so the client assigns exactly the ids
    /// our AssignIds dump names, instead of us trusting its local blocks.xml to
    /// land on the same numbers.
    ///
    /// `GameManager::IdMappingReceived` (asm.il 1892715-1892767) turns name
    /// "blocks" into a fresh `NameIdMapping(null, Block.MAX_BLOCKS)` and loads the
    /// blob into it; `Block::AssignIds` then takes the mapping branch
    /// (asm.il 101408-101432). Stock sends this at the same point in the join,
    /// `GameManager/'<RequestToEnterGame>d__195'::MoveNext` IL_01e3
    /// (asm.il 1872978-1873018), before the config files, because the client only
    /// runs `AssignIds` from `WorldStaticData/'<LoadBlocks>d__16'::MoveNext`
    /// IL_0058 (asm.il 2014542) after the ConfigFile package arrives.
    ///
    /// All or nothing. A partial blob is worse than none: `LoadFromArray` swallows
    /// the exception (asm.il 1178553-1178629), leaves `Block.nameIdMapping`
    /// non-null, and `assignIdsFromMapping` + `assignLeftOverBlocks` then silently
    /// renumber every block the blob failed to name. With the feature on and a
    /// dump loaded, measure/frame/deflate/send failures abort the enter bundle
    /// (`error`) so the client does not proceed under local ids. An empty dump
    /// (no AssignIds data) still skips and leaves LoadLocal behaviour.
    pub fn sendBlockIdMapping(self: *Game, peer: *ln_peer.Peer) !void {
        return game_config_files.sendBlockIdMapping(self, peer);
    }

    pub fn trySendCompressed(self: *Game, peer: *ln_peer.Peer, pkg_name: []const u8, body: []const u8) bool {
        return game_send_extra.trySendCompressed(self, peer, pkg_name, body);
    }
    pub fn sendFramedReliable(self: *Game, peer: *ln_peer.Peer, pkg_name: []const u8, framed: []const u8, budget_ns: u64, critical: bool) anyerror!void {
        return game_send_extra.sendFramedReliable(self, peer, pkg_name, framed, budget_ns, critical);
    }

    pub fn sendLocalConfigFiles(self: *Game, peer: *ln_peer.Peer) !void {
        return game_config_files.sendLocalConfigFiles(self, peer);
    }

    /// Stock sends the localization patch blob between the id mapping and the
    /// config files (RequestToEnterGame IL_0222/IL_0242).
    pub fn sendLocalization(self: *Game, peer: *ln_peer.Peer) !void {
        return game_config_files.sendLocalization(self, peer);
    }

    /// If feet Y is deep void / far below DTM surface, snap to surface+0.9 and
    /// optionally teleport the peer. Returns new Y when snapped, else null.
    /// Threshold surface-8 (was -24): late-suite mesh float still placeable after
    /// SetBlock pre-snap; deeper than -8 without snap caused type=0 power fails.
    pub fn rescueDeepVoid(self: *Game, peer: *ln_peer.Peer, entity_id: i32, x: f32, y: f32, z: f32, do_teleport: bool) !?f32 {
        return game_rescue.rescueDeepVoid(self, peer, entity_id, x, y, z, do_teleport);
    }
    pub fn withinEditReach(self: *const Game, px: f32, py: f32, pz: f32, bx: f32, by: f32, bz: f32) bool {
        return game_guard.withinEditReach(self, px, py, pz, bx, by, bz);
    }

    pub fn rejectIfBeyondEditRange(
        self: *Game,
        c: *Client,
        peer_local: i32,
        entity_id: i32,
        surf: evidence_mod.Surface,
        px: f32,
        py: f32,
        pz: f32,
        bx: f32,
        by: f32,
        bz: f32,
    ) bool {
        return game_guard.rejectIfBeyondEditRange(self, c, peer_local, entity_id, surf, px, py, pz, bx, by, bz);
    }

    pub fn rejectIfNotSender(
        self: *Game,
        c: *Client,
        peer_local: i32,
        claimed_entity: i32,
        surf: evidence_mod.Surface,
    ) bool {
        return game_guard.rejectIfNotSender(self, c, peer_local, claimed_entity, surf);
    }

    pub fn noteEvidence(self: *Game, c: *Client, peer_local: i32, entity_id: i32, det: evidence_mod.Detector, sev: evidence_mod.Severity, surf: evidence_mod.Surface, observed: f32, bound: f32) void {
        return game_guard.noteEvidence(self, c, peer_local, entity_id, det, sev, surf, observed, bound);
    }
    pub fn adminReplyGameStage(self: *Game, maybe_slot: ?usize) void {
        admin_console.adminReplyGameStage(self, maybe_slot);
    }
    pub fn adminReplyGuardPolicy(self: *Game) void {
        admin_console.adminReplyGuardPolicy(self);
    }
    pub fn loadShedding(self: *const Game) bool {
        return game_guard.loadShedding(self);
    }
    fn applyQuarantine(self: *Game, c: *Client, bits: guard_policy.Quarantine, det: evidence_mod.Detector) void {
        return game_guard.applyQuarantine(self, c, bits, det);
    }
    fn armPolicyKick(self: *Game, c: *Client, det: evidence_mod.Detector) void {
        return game_guard.armPolicyKick(self, c, det);
    }

    /// Drop armed policy kicks once the stock 0.5 s grace has elapsed.
    /// Bounded by max_clients per tick.
    pub fn reapPolicyKicks(self: *Game) void {
        return game_world_tick.reapPolicyKicks(self);
    }

    /// Shared peer teardown for admin kick/ban/wipeplayer and the guard policy.
    /// Resetting the slot to `.{}` also clears guard/quarantine state. `reason`
    /// names the dropping path so the server log keeps a complete join/leave
    /// trail: joins are logged, so drops (quit, kick, ban, guard) must be too.
    pub fn dropClientSlot(self: *Game, slot: usize, reason: []const u8) void {
        return game_session_drop.dropClientSlot(self, slot, reason);
    }

    /// Quarantine check at a C2S trust boundary. Observe mode records the flag
    /// but never denies (docs/AUTHORITY.md mode table).
    pub fn quarantineDenies(self: *Game, c: *Client, surf: evidence_mod.Surface) bool {
        return game_guard.quarantineDenies(self, c, surf);
    }

    /// Weak (record-only) block-destroy rate. Soft by construction, so
    /// `guard_policy.evaluate` can never turn it into a quarantine or a kick.
    pub fn noteBlockBreak(self: *Game, c: *Client) void {
        return game_guard.noteBlockBreak(self, c);
    }

    pub fn takeInvToken(self: *Game, c: *Client) bool {
        return game_rate_limits.takeInvToken(self, c);
    }
    pub fn takeBlockToken(self: *Game, c: *Client) bool {
        return game_rate_limits.takeBlockToken(self, c);
    }
    pub fn takeDamageToken(self: *Game, c: *Client) bool {
        return game_rate_limits.takeDamageToken(self, c);
    }
    pub fn acceptChatRate(self: *const Game, c: *Client) bool {
        return game_rate_limits.acceptChatRate(self, c);
    }

    /// Reach + land-claim gate for a block edit requested by `c` (ADR 0004).
    /// Shared by every C2S path that mutates world blocks or plants entities.
    pub fn placeAllowed(self: *Game, c: *const Client, x: i32, y: i32, z: i32) bool {
        return game_guard.placeAllowed(self, c, x, y, z);
    }

    /// World Y for spawning mobs next to a player (surface band, not void/float).
    pub fn spawnYNearPlayer(self: *Game, tr_x: f32, tr_y: f32, tr_z: f32) f32 {
        return game_world.spawnYNearPlayer(self, tr_x, tr_y, tr_z);
    }

    /// Advertised map size (GSI world_size). Stock reports the loaded map's
    /// HeightMapSize; offline/flat worlds fall back to the Navezgane default
    /// 6144 (B1, value-level sweep).
    pub fn worldSize(self: *const Game) i32 {
        return if (self.world.heightmap) |hm| hm.width else 6144;
    }

    /// Align spawn to DTM height and ensure a solid under the feet block so
    /// dig/place sample rings (BlockUnderFeet) see terrain, not air.
    pub fn spawnSurface(self: *Game, sx: i32, sz: i32) game_join.SpawnSurface {
        return game_join.spawnSurface(self, sx, sz);
    }

    pub fn sendJoinBundle(self: *Game, c: *Client, peer: *ln_peer.Peer, sx: i32, sy: i32, sz: i32, eid: i32) !void {
        return game_join.sendJoinBundle(self, c, peer, sx, sy, sz, eid);
    }

    /// Stock NetPackageGameStats: full bPersistent propertyList blob (RE).
    /// HUD day still comes from WorldTime; BloodMoonDay is the scheduled BM day.
    pub fn sendGameStats(self: *Game, peer: *ln_peer.Peer) !void {
        return game_join.sendGameStats(self, peer);
    }

    /// The bPersistent GameStats values (stock defaults otherwise).
    /// Effective GameStats blob values (wire NetPackageGameStats). pub so
    /// scenarios can assert configured values (storm_frequency, ...) land.
    pub fn gameStatsValues(self: *const Game) packages.GameStatsValues {
        return game_join.gameStatsValues(self);
    }

    /// Re-send the GameStats blob to every entered peer when the scheduled
    /// blood-moon day rolls (a client that joined mid-cycle and sat past its
    /// first horde would otherwise keep the stale red-moon HUD day forever).
    pub fn broadcastGameStats(self: *Game) !void {
        return game_join.broadcastGameStats(self);
    }

    /// Map markers for active journal quests (stock class names only).
    pub fn sendQuestNavObjects(self: *Game, peer: *ln_peer.Peer, peer_slot: usize, player_eid: i32) !void {
        return game_join.sendQuestNavObjects(self, peer, peer_slot, player_eid);
    }

    /// Markers for the air-drop crates still on the map (game/join.zig).
    pub fn sendAirDropNavObjects(self: *Game, peer: *ln_peer.Peer) !void {
        return game_join.sendAirDropNavObjects(self, peer);
    }

    /// True when quest id is likely present in stock client QuestClass.
    pub fn isStockClientQuestName(self: *Game, name: []const u8) bool {
        return game_quest.isStockClientQuestName(self, name);
    }

    pub fn handleQuestEvent(self: *Game, peer: *ln_peer.Peer, c: *Client, body: []const u8) !void {
        return game_quest.handleQuestEvent(self, peer, c, body);
    }

    pub fn fillStockJournalWrites(
        self: *Game,
        peer_slot: usize,
        out: []packages.stock_quest.StockQuestWrite,
        reward_store: *[ecs.components.max_journal][ecs.quest.max_reward_flags]packages.stock_quest.RewardWire,
        obj_val_store: *[ecs.components.max_journal][ecs.quest.max_phases]u8,
        kind_store: *[ecs.components.max_journal][ecs.quest.max_phases]packages.stock_quest.ObjectiveWriteKind,
        pos_store: *[ecs.components.max_journal][max_quest_position_data]packages.stock_quest.PositionEntry,
    ) usize {
        return game_quest.fillStockJournalWrites(self, peer_slot, out, reward_store, obj_val_store, kind_store, pos_store);
    }

    // _fillStockJournalWritesImpl removed - body lives in game/quest.zig

    /// Build trader FetchList offers from a quest_list id (stock quest names
    /// only). A quest already active in the player's journal is not re-offered:
    /// stock removes it from the NPCQuestList on accept (the accept marker).
    /// The quest list a trader offers resolves from npc.xml (quest_list per
    /// trader_info id; the entity class picked the id at spawn). When npc.xml
    /// is absent (fixtures) the stock class-hash map below is the fallback so
    /// a modded trader still gets offers.
    pub fn traderQuestList(self: *const Game, npc_entity_id: i32) []const u8 {
        return game_quest.traderQuestList(self, npc_entity_id);
    }

    pub fn buildTraderQuestOffers(
        self: *Game,
        list_id: []const u8,
        peer_slot: usize,
        trader_x: f32,
        trader_y: f32,
        trader_z: f32,
        tier: u8,
        out: []packages.stock_quest.QuestPacketEntry,
    ) usize {
        return game_quest.buildTraderQuestOffers(self, list_id, peer_slot, trader_x, trader_y, trader_z, tier, out);
    }

    /// Nearby non-player entities using stock NetPackageEntitySpawn + ECD networkWrite.
    /// Interest radius matches tick-path spawn-on-approach (`interest.inRange` + view_radius).
    pub fn sendStockEntitySpawns(self: *Game, peer: *ln_peer.Peer, c: *Client, px: i32, pz: i32) !void {
        return game_join.sendStockEntitySpawns(self, peer, c, px, pz);
    }

    /// Stock EntityStatChanged for core vitals (Health/Stamina/Food/Water).
    pub fn sendPlayerVitals(self: *Game, peer: *ln_peer.Peer, c: *Client) !void {
        return game_join.sendPlayerVitals(self, peer, c);
    }

    pub fn countJoined(self: *const Game) u16 {
        return game_social.countJoined(self);
    }

    /// `AdminUsers.GetUserPermissionLevel` equivalent (PlayerSlotsAuthorizer
    /// and command gates): the stored level (0 = top admin) when the identity
    /// is in the admin list, else the 1000 default.
    ///
    /// Stock `AdminUsers.HasEntry` (IL=30) keys on PlatformId/CrossplatformId
    /// only. A client-supplied display name must not mint admin rights when
    /// the peer already presented a platform id (same class of hole ADR 0038
    /// closed for player saves). Name-keyed list entries apply only to
    /// no-platform sessions (loadgen / legacy).
    pub fn permLevelOf(self: *const Game, c: *const Client) u16 {
        return game_social.permLevelOf(self, c);
    }

    /// True when `c` hits `list` the way stock AdminUsers/Whitelist do:
    /// platform composite when the client presented one; name only for
    /// no-platform sessions. Used by the whitelist gate and ClientInfo admin
    /// flag so those surfaces cannot drift from `permLevelOf`.
    pub fn permissionListHit(self: *const Game, list: *const admin_cmds.PermissionList, c: *const Client) bool {
        return game_social.permissionListHit(self, list, c);
    }

    pub fn resolveItemType(ctx: ?*anyopaque, item_id: u16) i32 {
        const g: *Game = @ptrCast(@alignCast(ctx.?));
        return g.items.stockTypeFor(item_id);
    }

    /// The held toolbelt stack in stock wire form, or null when the player
    /// holds nothing. Every package carrying `holdingItemStack` reads it from
    /// here so the spawn and stats bodies cannot disagree about what a player
    /// is holding.
    pub fn playerHoldingStock(self: *Game, slot: ecs.Slot) ?packages.stock_inv.StockSlot {
        return game_player.playerHoldingStock(self, slot);
    }

    /// Per-player blood-moon-music eligibility (stock EntityPlayer.bloodMoonParty):
    /// true only while the horde is active AND the player's own blood-moon
    /// party (focus within party_join_dist) still has alive horde zombies. The
    /// old global bool made every player on a multi-party server hear horde
    /// music when any party was horded.
    pub fn playerBloodMoonMusic(self: *const Game, c: *const Client) bool {
        return game_player.playerBloodMoonMusic(self, c);
    }

    pub fn reverseItemType(ctx: ?*anyopaque, stock_type: i32) u16 {
        const g: *Game = @ptrCast(@alignCast(ctx.?));
        return g.items.ecsIdFromStockType(stock_type);
    }

    pub const CommandLevel = admin_console.CommandLevel;

    pub fn commandLevel(self: *const Game, verb: []const u8) u8 {
        return admin_console.commandLevel(self, verb);
    }

    pub fn setCommandLevel(self: *Game, verb: []const u8, level: u8) bool {
        return admin_console.setCommandLevel(self, verb, level);
    }

    /// Workstation craft output: sim item plus the name the client derives from
    pub fn buildInventorySnap(self: *Game, c: *Client, buf: []u8) ![]u8 {
        const ps = self.sim.playerByPeer(c.slot) orelse return error.NoPlayer;
        if (!self.sim.mask[ps].inventory) return error.NoInv;
        // Stock body with ItemTable stock types when items.xml is loaded.
        return packages.buildInventoryBodyStockResolved(buf, &self.sim.inventory[ps], resolveItemType, self);
    }

    pub fn sendItemIdMapping(self: *Game, peer: *ln_peer.Peer) !void {
        return game_join.sendItemIdMapping(self, peer);
    }

    /// Holding-only S2C (valid direction for stock clients).
    /// Join: send empty held stack (entityId + count=0 + index). Full ItemValue held
    /// stacks have underrun'd stock HoldingItem.read mid-join when framing/window is tight;
    /// PDF already carries toolbelt. Echo path after InvTx still sends resolved hold.
    pub fn sendHoldingOnly(self: *Game, peer: *ln_peer.Peer, c: *Client) !void {
        return game_join.sendHoldingOnly(self, peer, c);
    }

    pub fn sendHoldingOnlyEx(self: *Game, peer: *ln_peer.Peer, c: *Client, full_stack: bool) !void {
        return game_join.sendHoldingOnlyEx(self, peer, c, full_stack);
    }

    /// Post-change inv echo. PlayerInventory/Bag are ToServer-only for stock
    /// clients; only HoldingItem is a valid S2C echo.
    pub fn sendHoldingEcho(self: *Game, peer: *ln_peer.Peer, c: *Client) !void {
        try self.sendHoldingOnlyEx(peer, c, true);
    }

    pub fn isStorageBlockId(self: *const Game, block_id: u16) bool {
        return game_loot.isStorageBlockId(self, block_id);
    }

    /// Closed↔open pair from blocks.xml DowngradeBlock (AssignIds-resolved).
    pub fn storagePairId(self: *const Game, block_id: u16) ?u16 {
        return game_loot.storagePairId(self, block_id);
    }

    /// Resolve a spawn-picked class name to its full entityclasses stats
    /// (HP/speeds/damage/hash/loot). Game-level because it needs the entities
    /// table and the items table for HandItem DamageEntity.
    /// EntityDef → full EntityClass (A35): the resolved stats the sim carries
    /// per entity so a class not preloaded into the fixed class_table still
    /// spawns as itself (HP/speeds/damage/hash/loot/is_enemy).
    pub fn biomeGroupName(ctx: ?*anyopaque, x: f32, z: f32, kind: ecs.aidirector.Director.SpawnKind, fallback: []const u8) []const u8 {
        return game_world.biomeGroupName(ctx, x, z, kind, fallback);
    }
    pub fn biomeRuleBudget(ctx: ?*anyopaque, x: f32, z: f32, kind: ecs.aidirector.Director.SpawnKind) ecs.aidirector.RuleBudget {
        return game_world.biomeRuleBudget(ctx, x, z, kind);
    }
    pub fn entityClassOf(self: *Game, d: assets_entities.EntityDef) ecs.world.EntityClass {
        return game_init_world.entityClassOf(self, d);
    }

    pub fn resolveSpawnClass(ctx: ?*anyopaque, class_name: []const u8) ?ecs.world.EntityClass {
        const self: *Game = @ptrCast(@alignCast(ctx.?));
        const d = self.entities.byName(class_name) orelse return null;
        return self.entityClassOf(d);
    }

    pub fn pickEntityGroup(ctx: ?*anyopaque, group: []const u8, seed: u32) ?[]const u8 {
        const g: *Game = @ptrCast(@alignCast(ctx.?));
        return g.entitygroups.pick(group, seed);
    }

    /// Per-player biome spawn group (spawning.xml rule for the biome under the
    /// spawn point): night/day zombie or animal group NAME, or the fallback
    /// when the biome map, the biome name, or the biome's rule is unknown.
    /// Fixes the wasteland-at-midnight-getting-forest-walkers gap: stock
    /// resolves per ChunkAreaBiomeSpawnData from the actual biome.
    /// Class=Sleeper marker test (authored POI sleeper spawn points; RE
    /// world-generation.md: Block.IsSleeperBlock via Extends-resolved Class,
    /// not a name prefix). Wired as the sleepers loadFromPrefabs callback.
    pub fn isSleeperName(ctx: ?*anyopaque, name: []const u8) bool {
        const self: *Game = @ptrCast(@alignCast(ctx.?));
        return self.maxdamage.isSleeperName(name);
    }

    /// True when the block id is a bedroll (stock respawn bed): the classic
    /// bedroll plus the colored variants. Name-based via the runtime AssignIds
    /// dump, never a hardcoded id list.
    pub fn isBedrollId(self: *const Game, block_id: u16) bool {
        return game_world.isBedrollId(self, block_id);
    }

    /// Biome id at (wx,wz) from the world's biome map (`biomes.xml` `<biomemap
    /// id>`), or null when the world has no biome map. The `InBiome`
    /// requirement gate reads exactly this id.
    pub fn biomeIdAt(self: *const Game, wx: i32, wz: i32) ?u8 {
        const bm = self.world.biomes orelse return null;
        return bm.atWorld(wx, wz);
    }

    /// True when the world biome at (wx,wz) is the stock radiated biome
    /// (biomes.xml <biomemap name="radiated"/>), which deals damage over time.
    /// blockplaceholders context for the paint pass: the loaded table, the
    /// world seed stock's per-cell stream folds in, and the biome name at a
    /// position. Null when no placeholder table loaded (the paint path then
    /// keeps whatever id the remap left).
    pub const PlaceholderCtx = struct {
        fn at(ctx: ?*anyopaque, wx: i32, wz: i32) []const u8 {
            const s: *const Game = @ptrCast(@alignCast(ctx.?));
            const id = s.biomeIdAt(wx, wz) orelse return "";
            return s.world.biome_layers_table.names[id] orelse "";
        }
        /// Fill `holder` (caller-owned, outlives the paint call) and return it,
        /// or null when no placeholder catalog loaded. The biome callback is
        /// stock's `WorldBiomes.GetBiome(...).m_sBiomeName` for the cell.
        pub fn slot(self: *Game, holder: *world_tts.PlaceholderCtx) ?*const world_tts.PlaceholderCtx {
            if (!self.placeholders_loaded) return null;
            holder.* = .{
                .table = &self.placeholder_table,
                .world_seed = @truncate(@as(i64, @bitCast(if (self.world.worldgen) |wg| wg.seed else @import("../util/sim.zig").default_seed))),
                .biome_name = @This().at,
                .biome_ctx = self,
            };
            return holder;
        }
    };

    pub fn isRadiatedAt(self: *const Game, wx: i32, wz: i32) bool {
        const id = self.biomeIdAt(wx, wz) orelse return false;
        const name = self.world.biome_layers_table.names[id] orelse return false;
        return std.mem.find(u8, name, "radiat") != null;
    }

    /// spawning.xml rule budget at a world position (maxcount/respawndelay)
    /// for the ambient per-rule spawn cap. Mirrors biomeGroupName's scan but
    /// returns the rule's table index + budget instead of the group name;
    /// 0xffff when no rule matches (ambient spawns stay unbudgeted, the
    /// pre-2026-08-23 behaviour).
    /// POI-tag gate for a spawning.xml rule at a world position (stock
    /// POITags/noPOITags Test_AnySet against the FastTags<Poi> union,
    /// spawning.md §2): no tags = always enabled; any required tag present
    /// = enabled; any forbidden tag present = disabled.
    pub fn ruleTagsAllow(self: *Game, r: *const assets_spawning.Rule, x: f32, z: f32) bool {
        return game_world.ruleTagsAllow(self, r, x, z);
    }

    /// gamestages.xml spawner ladder → the stage's first <spawn> row.
    /// The pacing fields ride along for the nightly group walk (SetupGroup).
    pub fn pickStageGroup(ctx: ?*anyopaque, spawner: []const u8, stage: i32) ?ecs.aidirector.StageGroup {
        const g: *Game = @ptrCast(@alignCast(ctx.?));
        const sp = g.gamestages.spawnerByName(spawner) orelse return null;
        const st = sp.getStage(stage) orelse return null;
        const sg = st.spawnGroup(0) orelse return null;
        return .{ .group = sg.group, .num = sg.num, .max_alive = sg.max_alive, .interval = sg.interval, .duration = sg.duration };
    }

    /// `GameStageDefinition::CalcGameStageAround`: the weighted party level of
    /// the joined players within `radius` of a point, for the wandering-horde
    /// ladder (`partyStageAround` is the same primitive the sleeper volumes
    /// use; stock also filters to the same PrefabInstance, which zdtd cannot
    /// yet).
    pub fn pickStageAround(ctx: ?*anyopaque, wx: f32, wz: f32, radius: f32) i32 {
        const g: *Game = @ptrCast(@alignCast(ctx.?));
        return g.partyStageAround(wx, wz, radius);
    }

    /// gamestages.xml spawner ladder → the stage's `<spawn>` row at `index`
    /// (stock `Stage.GetSpawnGroup`, null past the end - not clamped; the
    /// walk ends when it returns null). Feeds the nightly group walk.
    pub fn pickStageGroupAt(ctx: ?*anyopaque, spawner: []const u8, stage: i32, index: u32) ?ecs.aidirector.StageGroup {
        const g: *Game = @ptrCast(@alignCast(ctx.?));
        const sp = g.gamestages.spawnerByName(spawner) orelse return null;
        const st = sp.getStage(stage) orelse return null;
        if (index >= st.spawns.len) return null;
        const sg = st.spawns[index];
        return .{ .group = sg.group, .num = sg.num, .max_alive = sg.max_alive, .interval = sg.interval, .duration = sg.duration };
    }

    /// Blood-moon bonus-loot cadence for the frozen stage
    /// (`AIDirectorGameStagePartySpawner.SetPartyLevel` IL_0065-007C):
    /// `bonusLootEvery = max(stageSpawnMax / LootBonusMaxCount, LootBonusEvery)`
    /// with `stageSpawnMax` summing every spawn-group `num` in the stage.
    /// Pushes the nightly cadence + `LootBonusScale` into the director.
    /// Falls back to the stock XML defaults when the ladder has no stage
    /// (offline/builtin tables).
    ///
    /// Parameters only: the counter is seeded once at the nightly stage
    /// freeze (stock InitParty IL_0072-0080). This runs every tick of an
    /// active blood moon so a ladder loaded mid-night takes effect, and
    /// re-seeding here reset the progress counter at 20 Hz while it only
    /// advances per horde spawn, so the bonus drop never fired.
    pub fn pushBloodMoonBonus(self: *Game, stage: i32) void {
        return game_world_tick.pushBloodMoonBonus(self, stage);
    }

    /// spawning.xml <entityspawner name=…> → its EntityGroupName property.
    pub fn pickSpawnerGroup(ctx: ?*anyopaque, spawner: []const u8) ?[]const u8 {
        const g: *Game = @ptrCast(@alignCast(ctx.?));
        const s = g.spawning.spawnerByName(spawner) orelse return null;
        return s.entitygroup;
    }

    /// spawning.xml <entityspawner name=…> → its TotalPerWave min/max
    /// (min 0 = unset, caller falls back). Rule 15: the wave size is stock
    /// data, not a sim default.
    pub fn pickSpawnerWave(ctx: ?*anyopaque, spawner: []const u8) ecs.aidirector.WaveRange {
        const g: *Game = @ptrCast(@alignCast(ctx.?));
        const s = g.spawning.spawnerByName(spawner) orelse return .{};
        return .{ .min = s.total_per_wave, .max = s.total_per_wave_max };
    }

    /// Craft recipe by index into recipes.defs (InvTx craft op). Consumes ingredients, grants output.
    pub fn tryCraft(self: *Game, peer_slot: usize, recipe_index: u16, times: u16) bool {
        return game_craft.tryCraft(self, peer_slot, recipe_index, times);
    }

    /// Scrap bag slot via GetScrapableRecipe (InvTx scrap op). Consumes input, grants scrap.
    pub fn tryScrap(self: *Game, peer_slot: usize, bag_slot: u16, qty: u16) bool {
        return game_craft.tryScrap(self, peer_slot, bag_slot, qty);
    }

    /// Repair-by-combine (MergeBest): drag one damaged tool onto another.
    pub fn tryCombineTools(self: *Game, peer_slot: usize, from: u16, to: u16) bool {
        return game_craft.tryCombineTools(self, peer_slot, from, to);
    }

    pub fn coinItemId(self: *const Game) u16 {
        return game_trader.coinItemId(self);
    }

    pub fn traderMoney(self: *const Game, s: ecs.Slot) i32 {
        return game_trader.traderMoney(self, s);
    }

    pub fn traderIsOpen(self: *const Game, ts: ecs.Slot) bool {
        return game_trader.traderIsOpen(self, ts);
    }

    pub fn tickTraderAreas(self: *Game) void {
        return game_trader.tickTraderAreas(self);
    }

    fn toggleTraderGates(self: *Game, s: ecs.Slot, closed: bool) void {
        return game_trader.toggleTraderGates(self, s, closed);
    }

    fn toggleGatesInArea(self: *Game, d: *const world_store.prefabs.Decoration, closed: bool) void {
        return game_trader.toggleGatesInArea(self, d, closed);
    }

    pub fn fillTraderFromXml(self: *Game, trader_net_id: i32) void {
        return game_trader.fillTraderFromXml(self, trader_net_id);
    }

    pub fn maybeRestockTrader(self: *Game, ts: ecs.Slot) void {
        game_trader.maybeRestockTrader(self, ts);
    }

    pub fn handItemDamage(self: *Game, hand_item: []const u8) f32 {
        return game_craft.handItemDamage(self, hand_item);
    }

    pub fn spitConfigFor(self: *Game, hand_item: []const u8) ?game_craft.SpitConfig {
        return game_craft.spitConfigFor(self, hand_item);
    }

    pub fn handItemBlockChew(self: *Game, hand_item: []const u8) f32 {
        return game_craft.handItemBlockChew(self, hand_item);
    }

    pub fn handItemRange(self: *Game, hand_item: []const u8) f32 {
        return game_craft.handItemRange(self, hand_item);
    }

    /// One workstation step: burn/craft, then re-broadcast the stations it changed.
    pub fn tickWorkstations(self: *Game, dt: f32) !void {
        return game_craft.tickWorkstations(self, dt);
    }

    /// BlockRadiusEffect: burning workstations (campfire, burning barrel)
    /// grant their ActiveRadiusEffects buff to nearby players.
    pub fn tickBlockRadiusEffects(self: *Game) void {
        return game_craft.tickBlockRadiusEffects(self);
    }

    pub fn tickAlwaysOnRadiusEffects(self: *Game) void {
        return game_craft.tickAlwaysOnRadiusEffects(self);
    }

    pub fn ecsIdFromItemName(self: *Game, name: []const u8) u16 {
        return game_loot.ecsIdFromItemName(self, name);
    }

    /// Stock `ItemClass::AddGSStats` (IL=100) for a rolled item: the
    /// gamestage stat entries an item value carries, drawn from a per-item
    /// stream (`seed ^ index`, like the rest of the loot roll, so a re-roll is
    /// reproducible). Empty for an item with no `<stats>` rows.
    pub fn rollItemStats(self: *Game, item_id: u16, quality: u8, loot_stage: i32, seed: u32) game_loot.RolledItemStats {
        return game_loot.rollItemStats(self, item_id, quality, loot_stage, seed);
    }

    pub fn fillLootBagFromTable(self: *Game, bag_net_id: i32, loot_list: []const u8, seed: u32, loot_stage: i32) void {
        game_loot.fillLootBagFromTable(self, bag_net_id, loot_list, seed, loot_stage);
    }

    /// Wake prefab sleeper volumes near players; spawn class groups once.
    /// Push the background flusher's atomic totals into apm counters as
    /// per-tick deltas. `world` cannot import `apm` (src/world/root.zig), so the
    /// tick thread samples instead.
    pub fn sampleFlushCounters(self: *Game) void {
        return game_world_tick.sampleFlushCounters(self);
    }

    pub fn gatherPlayerPositions(
        self: *Game,
        px: *[max_clients]f32,
        py: *[max_clients]f32,
        pz: *[max_clients]f32,
    ) usize {
        return game_sleeper.gatherPlayerPositions(self, px, py, pz);
    }

    pub const SleeperScanCtx = game_sleeper.SleeperScanCtx;

    pub fn tickSleeperVolumes(self: *Game) void {
        return game_sleeper.tickSleeperVolumes(self);
    }

    pub fn triggerSleeperVolumesByNoise(self: *Game) void {
        return game_sleeper.triggerSleeperVolumesByNoise(self);
    }

    pub fn triggerSleeperVolumesByStealthNoise(self: *Game) void {
        return game_sleeper.triggerSleeperVolumesByStealthNoise(self);
    }

    pub fn tickSleeperRearm(self: *Game) void {
        return game_sleeper.tickSleeperRearm(self);
    }

    /// Resolve a SleeperVolumeGroup name to an entity def, stock order first
    /// (SleeperVolume::Spawn, asm.il ~1199169): the already-resolved gamestage
    /// SpawnGroup names an entitygroup, and only its class pick counts. Across
    /// stock Data/Prefabs the volume names are overwhelmingly gamestage group
    /// names (GroupGenericZombie and friends) that entitygroups.xml does not
    /// contain, so without this the fallbacks below hit defaultZombie for
    /// nearly every POI. The entityclass / entitygroup fallbacks stay for
    /// prefabs that do name one directly.
    pub fn resolveSleeperClass(
        self: *Game,
        name: []const u8,
        stage_spawn: ?assets_gamestages.SpawnGroup,
        seed: u32,
    ) assets_entities.EntityDef {
        return game_sleeper.resolveSleeperClass(self, name, stage_spawn, seed);
    }

    pub fn broadcastLootSpawn(self: *Game, net_id: i32) !void {
        try game_loot.broadcastLootSpawn(self, net_id);
    }

    /// Take back a dead supply crate's MapObject and NavObject markers.
    pub fn broadcastSupplyCrateMarkerRemove(self: *Game, crate_entity_id: i32) void {
        game_loot.broadcastSupplyCrateMarkerRemove(self, crate_entity_id);
    }

    pub fn spawnDeathBag(self: *Game, victim_slot: ecs.Slot) void {
        return game_player.spawnDeathBag(self, victim_slot);
    }

    /// Stock ItemDropServer path: EntityItem (class "item") with itemClass ECD.
    pub fn broadcastItemDropSpawn(
        self: *Game,
        net_id: i32,
        stack: packages.stock_inv.StockSlot,
        belongs_player_id: i32,
        client_entity_id: i32,
    ) !void {
        try game_loot.broadcastItemDropSpawn(self, net_id, stack, belongs_player_id, client_entity_id);
    }

    /// Returns false when the chunk was soft-dropped on a full reliable window.
    /// The caller must then leave the key out of `c.streamed`: the stream tick
    /// only sends keys it does not already hold, so recording a dropped chunk
    /// leaves a permanent hole. A hole anywhere in the player's 2-chunk mesh
    /// halo pins that chunk at NeedsRegeneration, so the client never builds a
    /// collision mesh under the player. It then free-falls, Origin's downward
    /// ray fails every frame, and RespawnProgress.WaitingForCollider never
    /// clears: the join hangs on "Creating player".
    pub fn sendSpawnChunk(self: *Game, peer: *ln_peer.Peer, cx: i32, cz: i32) !bool {
        return game_chunk_fill.sendSpawnChunk(self, peer, cx, cz);
    }

    /// Rebuild power nodes from a chunk's blocks (game/chunk_fill.zig).
    pub fn scanChunkPower(self: *Game, ch: *world_store.Chunk, cx: i32, cz: i32) void {
        game_chunk_fill.scanChunkPower(self, ch, cx, cz);
    }

    pub fn ensurePrefabStorageInChunk(self: *Game, ch: *world_store.Chunk, cx: i32, cz: i32) void {
        game_chunk_fill.ensurePrefabStorageInChunk(self, ch, cx, cz);
    }

    /// Drop a broken block's stored items on the ground (game/chunk_fill.zig).
    /// Called from `noteBlockRemoved`, which is where every removal path meets.
    pub fn spillStoredItems(self: *Game, x: i32, y: i32, z: i32) void {
        game_chunk_fill.tryContainerSpill(self, x, y, z);
        game_chunk_fill.tryWorkstationSpill(self, x, y, z);
        game_chunk_fill.tryVendingSpill(self, x, y, z);
    }

    pub fn fillContainerFromLoot(self: *Game, cont: *containers_mod.Container, loot_name: []const u8, seed: u32, loot_stage: i32, opener_peer: i32) void {
        game_chunk_fill.fillContainerFromLoot(self, cont, loot_name, seed, loot_stage, opener_peer);
    }

    /// Derive a container's grid from loot.xml without rolling it (the roll
    /// waits for the first open; `game/chunk_fill.zig`).
    pub fn setContainerSizeFromLoot(self: *Game, cont: *containers_mod.Container, loot_name: []const u8) void {
        game_chunk_fill.setContainerSizeFromLoot(self, cont, loot_name);
    }

    /// The roll a container gets when a player opens it (stock
    /// LootManager.LootContainerOpened + the LootRespawnDays re-roll).
    pub fn ensureContainerLoot(self: *Game, cont: *containers_mod.Container, opener_peer: usize) void {
        game_chunk_fill.ensureContainerLoot(self, cont, opener_peer);
    }

    /// Stock CheckDestroyTileEntity on container unlock (close): a loot def
    /// with destroy_on_close drops the contents and breaks the block.
    pub fn maybeDestroyContainerOnClose(self: *Game, x: i32, y: i32, z: i32) void {
        game_chunk_fill.maybeDestroyContainerOnClose(self, x, y, z);
    }

    /// LootRespawnDays (stock TEFeatureStorage.UpdateTick): a looted world
    /// container re-rolls its contents when the interval since the touch day
    /// has elapsed (game/chunk_fill.zig).
    pub fn sendContainersInChunk(self: *Game, peer: *ln_peer.Peer, cx: i32, cz: i32) !void {
        return game_chunk_stream.sendContainersInChunk(self, peer, cx, cz);
    }

    pub fn sendSpawnArea(self: *Game, peer: *ln_peer.Peer, wx: i32, wz: i32, radius: i32) !void {
        return game_chunk_stream.sendSpawnArea(self, peer, wx, wz, radius);
    }

    /// Drain a client's pending spawn-area rings against the shared per-tick
    /// drain budget (join-burst pacing, GAP "Join-burst tick budget under
    /// concurrent load").
    pub fn drainSpawnArea(self: *Game, c: *Client, budget: *u32) !void {
        return game_chunk_stream.drainSpawnArea(self, c, budget);
    }

    /// Stream chunks around player and remove far ones (stock ChunkRemove key).
    /// Caps: `self.max_streamed_chunks`, `chunk_stream_radius_{min,max}`,
    /// `self.chunk_adds_per_stream_tick` (named; no magic pacing numbers).
    pub fn streamChunksForClient(self: *Game, c: *Client) !void {
        return game_chunk_stream.streamChunksForClient(self, c);
    }

    /// Unreliable fan-out for the motion frames (PosAndRot / Speeds): fire and
    /// forget, never touches the reliable window. Oversized or failed sends are
    /// dropped (motion is replaced by the next tick's frame anyway).
    pub fn sendFramedUnreliable(self: *Game, peer: *ln_peer.Peer, framed: []const u8) void {
        return game_net.sendFramedUnreliable(self, peer, framed);
    }

    /// Fan-out already-framed user payload to one peer (no re-encode). Soft-drops
    /// WindowFull the same way as droppable streaming packages.
    pub fn sendFramedDroppable(self: *Game, peer: *ln_peer.Peer, framed: []const u8) void {
        return game_net.sendFramedDroppable(self, peer, framed);
    }

    pub fn broadcast(self: *Game, name: []const u8, body: []const u8) !void {
        return game_net.broadcast(self, name, body);
    }

    pub fn broadcastNear(self: *Game, name: []const u8, body: []const u8, wx: f32, wz: f32, range_blocks: f32) !void {
        return game_net.broadcastNear(self, name, body, wx, wz, range_blocks);
    }

    pub fn broadcastKnown(self: *Game, name: []const u8, body: []const u8, slot: ecs.Slot) !void {
        return game_net.broadcastKnown(self, name, body, slot);
    }

    pub fn broadcastNearExcept(self: *Game, name: []const u8, body: []const u8, wx: f32, wz: f32, range_blocks: f32, skip_slot: usize) !void {
        return game_net.broadcastNearExcept(self, name, body, wx, wz, range_blocks, skip_slot);
    }

    pub fn broadcastExcept(self: *Game, name: []const u8, body: []const u8, except_slot: ?usize) !void {
        return game_net.broadcastExcept(self, name, body, except_slot);
    }

    /// Drain the hp dirty bit into stock EntityStatChanged(Health) packages.
    ///
    /// Stock never sends from the code that changed a stat: the setter raises
    /// Stat.Changed and the entity's own tick polls it, sends, then clears it
    /// (EntityStats::TickWait asm.il:199393, PlayerEntityStats::TickWait
    /// asm.il:200440). dirty.hp is that Changed flag, so AI melee, C2S damage
    /// and admin damage all reach the client through this one pass.
    ///
    /// SendStatChangePacket (asm.il:199650) uses instigator -1 on a dedicated
    /// server and passes `_inRangeOnly = enumStat != 0`, so Health goes to every
    /// player tracking the entity **and** to the entity itself, range regardless.
    pub fn replicatePlayerHealth(self: *Game) void {
        return @import("game/replicate_health.zig").replicatePlayerHealth(self);
    }

    pub fn clientObserves(self: *const Game, cl: *const Client, wx: f32, wz: f32) bool {
        return @import("game/replicate_health.zig").clientObserves(self, cl, wx, wz);
    }

    /// C2S NetPackageAddRemoveBuff (asm.il 202415). Stock's server branch re-Setups
    /// the package and fans it out to the clients attached to the entity
    /// (ProcessPackage, asm.il 202531); we validate first, because the body is
    /// entirely client-chosen: a peer may only drive its own player entity, and
    /// only with a buff name the catalog resolves.
    pub fn handleAddRemoveBuff(self: *Game, c: *Client, body: []const u8) !void {
        return game_social.handleAddRemoveBuff(self, c, body);
    }

    pub fn sendBuffSync(self: *Game, peer: *ln_peer.Peer, c: *const Client) !void {
        return game_social.sendBuffSync(self, peer, c);
    }

    /// The joining player's OWN active buffs (the PDF buff section is empty
    /// in zdtd; the client needs an explicit AddRemoveBuff bundle on rejoin).
    /// See game/social.zig.
    pub fn sendOwnBuffs(self: *Game, peer: *ln_peer.Peer, c: *const Client) !void {
        return game_social.sendOwnBuffs(self, peer, c);
    }

    fn playerBuffBlob(self: *Game, peer_slot: usize, buf: []u8) []const u8 {
        return game_social.playerBuffBlob(self, peer_slot, buf);
    }

    pub fn relayBuff(self: *Game, entity_id: i32, buff_name: []const u8, adding: bool, instigator_id: i32, except_slot: ?usize) !void {
        return game_social.relayBuff(self, entity_id, buff_name, adding, instigator_id, except_slot);
    }

    pub fn broadcastBuffExpiries(self: *Game, r: *const ecs.TickResult) !void {
        return game_social.broadcastBuffExpiries(self, r);
    }

    pub fn replicate(self: *Game) !void {
        return game_replicate.replicate(self);
    }

    pub fn clearDeadKnownEntities(self: *Game) void {
        return game_world_tick.clearDeadKnownEntities(self);
    }

    pub fn step(self: *Game) !void {
        return @import("game/step.zig").step(self);
    }

    /// Build NetPackageWeather from the live weather state machine (omit if none).
    pub fn buildWeatherBodyFromBiomes(self: *Game) ?[]const u8 {
        return game_weather.buildWeatherBodyFromBiomes(self);
    }

    pub fn sendWeather(self: *Game, peer: *ln_peer.Peer) !void {
        try game_weather.sendWeather(self, peer);
    }

    /// Stock: same throttle as WorldTime → NetPackageWeather from biomes.xml defaults.
    pub fn broadcastWeather(self: *Game) !void {
        try game_weather.broadcastWeather(self);
    }

    /// Seat a rider and tell every client which seat it landed in. The stock
    /// server answers a mount request with AttachType 1 carrying the RESOLVED
    /// slot (NetPackageEntityAttach::ProcessPackage, asm.il:844722 IL_008d) and
    /// the client applies that index verbatim, so this number is the whole of
    /// "passengers render in the right seat".
    pub fn seatRider(self: *Game, rider_id: i32, vslot: ecs.Slot, requested: i16) !void {
        try game_vehicle.seatRider(self, rider_id, vslot, requested);
    }

    /// Unseat a rider and broadcast AttachType 3 with vehicleId and slot both
    /// -1, matching the server branch of Entity::SendDetach (asm.il:406816).
    /// Sim seat is freed even if the wire body cannot be built; encode failure
    /// is logged so a silent ghost seat on remotes is not invisible.
    pub fn unseatRider(self: *Game, rider_id: i32) !void {
        try game_vehicle.unseatRider(self, rider_id);
    }

    /// Replay current occupancy to one peer so a late joiner draws riders in
    /// their seats instead of standing on the hull.
    pub fn sendSeatedRiders(self: *Game, peer: *ln_peer.Peer) !void {
        try game_vehicle.sendSeatedRiders(self, peer);
    }

    pub fn sendVehicleWaypoints(self: *Game, peer: *ln_peer.Peer, slot: usize) !void {
        try game_vehicle.sendVehicleWaypoints(self, peer, slot);
    }

    pub fn broadcastVehiclePositions(self: *Game) !void {
        try game_vehicle.broadcastVehiclePositions(self);
    }

    pub fn broadcastTurretSync(self: *Game) !void {
        try game_vehicle.broadcastTurretSync(self);
    }

    pub fn run(self: *Game) !void {
        return game_lifecycle.run(self);
    }

    pub fn applyDamage(self: *Game, entity_id: i32, amount: f32) bool {
        return @import("game/harness.zig").applyDamage(self, entity_id, amount);
    }

    pub fn setBlock(self: *Game, x: i32, y: i32, z: i32, id: u16) !void {
        return @import("game/harness.zig").setBlock(self, x, y, z, id);
    }

    pub fn attachJoinedClient(self: *Game, capture: ?*ln_peer.Capture) !*Client {
        return @import("game/harness.zig").attachJoinedClient(self, capture);
    }

    pub fn attachJoinedClientAs(self: *Game, capture: ?*ln_peer.Capture, puid: ?platform_user.Id) !*Client {
        return @import("game/harness.zig").attachJoinedClientAs(self, capture, puid);
    }

    pub fn injectFramed(self: *Game, c: *Client, framed: []const u8) !void {
        return @import("game/harness.zig").injectFramed(self, c, framed);
    }

    pub fn handlePartyActions(self: *Game, c: *Client, body: []const u8) !void {
        return game_social.handlePartyActions(self, c, body);
    }

    pub fn acceptQuestFor(self: *Game, c: *Client, def_id: u16) bool {
        return game_social.acceptQuestFor(self, c, def_id);
    }

    pub fn handleAllyRequest(self: *Game, c: *Client, body: []const u8) !void {
        return game_social.handleAllyRequest(self, c, body);
    }

    pub fn sendAllySnapshot(self: *Game, peer: *ln_peer.Peer) !void {
        return game_social.sendAllySnapshot(self, peer);
    }

    fn broadcastPartySnapshot(
        self: *Game,
        party_id: i32,
        leader_index: u8,
        voice: []const u8,
        members: []const i32,
        changed: i32,
        action: u8,
        disband: bool,
    ) !void {
        return @import("game/social.zig").broadcastPartySnapshot(self, party_id, leader_index, voice, members, changed, action, disband);
    }

    pub fn broadcastPartyRemoval(self: *Game, r: party.Removal, action: u8) !void {
        return @import("game/social.zig").broadcastPartyRemoval(self, r, action);
    }

    pub fn clientByEntityId(self: *Game, entity_id: i32) ?*Client {
        return @import("game/social.zig").clientByEntityId(self, entity_id);
    }

    pub fn shareQuestWithParty(self: *Game, c: *Client, def_id: u16) void {
        return @import("game/social.zig").shareQuestWithParty(self, c, def_id);
    }
};
