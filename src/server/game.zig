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
const world_tts = @import("../world/tts.zig");
const deco_mirror = @import("../world/deco_mirror.zig");
const ecs = @import("../ecs/root.zig");
const systems = @import("../ecs/systems.zig");
const parallel_util = @import("../util/parallel.zig");
const protocol = @import("../protocol.zig");
const replicate_te = @import("replicate_te.zig");
const game_net = @import("game/net.zig");
const game_tick = @import("game/tick.zig");
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
const game_bans = @import("game/bans.zig");
const game_trader_wire = @import("game/trader_wire.zig");
const game_send_extra = @import("game/send_extra.zig");
const game_rescue = @import("game/rescue.zig");
const game_guard = @import("game/guard.zig");
const game_session_drop = @import("game/session_drop.zig");
const game_init_assets = @import("game/init_assets.zig");
const persist = @import("persist.zig");
const admin_console = @import("admin_console.zig");
const game_types = @import("game/types.zig");
const ConsoleOut = admin_console.ConsoleOut;
const TargetResult = admin_console.TargetResult;
const assets_blocks = @import("../assets/blocks.zig");
const assets_items = @import("../assets/items.zig");
const assets_signs = @import("../assets/signs.zig");
const assets_entities = @import("../assets/entities.zig");
const assets_recipes = @import("../assets/recipes.zig");
const assets_loot = @import("../assets/loot.zig");
const assets_entitygroups = @import("../assets/entitygroups.zig");
const assets_gamestages = @import("../assets/gamestages.zig");
const assets_maxdamage = @import("../assets/maxdamage.zig");
const assets_traders = @import("../assets/traders.zig");
const assets_npc = @import("../assets/npc.zig");
const assets_block_textures = @import("../assets/block_textures.zig");
const assets_painting = @import("../assets/painting.zig");
const assets_spawning = @import("../assets/spawning.zig");
const assets_buffs = @import("../assets/buffs.zig");
const assets_progression = @import("../assets/progression.zig");
const assets_vehicles = @import("../assets/vehicles.zig");
const assets_storage_pairs = @import("../assets/storage_pairs.zig");
const biomes_mod = @import("../world/biomes.zig");
const world_weather = @import("../world/weather.zig");
const stability_mod = @import("../world/stability.zig");
const terrain_snapshot = @import("../world/terrain_snapshot.zig");
const jobs = @import("../ecs/jobs.zig");
const interest = @import("../ecs/interest.zig");
const invsys = @import("../ecs/inventory.zig");
const party = @import("../ecs/party.zig");
const admin_mod = @import("admin.zig");
const admin_cmds = @import("admin_cmds.zig");
const webui_mod = @import("webui.zig");
const serverinfo_tcp = @import("serverinfo_tcp.zig");
const containers_mod = @import("../world/containers.zig");
const vending_mod = @import("../world/vending.zig");
const workstations_mod = @import("../world/workstations.zig");
const sleepers_mod = @import("../world/sleepers.zig");
const server_config = @import("config.zig");
const phase_gate = @import("phase_gate.zig");
const movement = @import("movement.zig");
const c2s_text = @import("c2s_text.zig");
const evidence_mod = @import("evidence.zig");
const guard_policy = @import("guard_policy.zig");
const ally_mod = @import("ally.zig");
const io_fs = @import("../util/io_fs.zig");
const util_sim = @import("../util/sim.zig");
const plugin_mod = @import("../plugin/root.zig");

// Stock body modules via packages facade (leaf files stay importable elsewhere).
const stock_sign = packages.stock_sign;
const stock_te = packages.stock_te;
const te_types = packages.te_types;
const platform_user = packages.platform_user;

pub const max_clients = ln_server.max_peers;
/// Per-entity observer set: one bit per client slot, so replication interest is
/// a single word instead of a sweep over the whole client table.
pub const ObsMask = interest.ObserverMask(max_clients);

pub fn bitOf(ci: usize) ObsMask {
    return @as(ObsMask, 1) << @intCast(ci);
}

/// Owner bit for a sim player's peer slot; 0 when the entity has no live peer
/// (`Client.slot` equals its index, so peer slot and bit index are the same).
pub fn bitOfPeerSlot(peer_slot: i32) ObsMask {
    if (peer_slot < 0 or peer_slot >= max_clients) return 0;
    return bitOf(@intCast(peer_slot));
}

pub const max_land_claims = game_types.max_land_claims;
pub const max_quest_position_data = @import("game/constants.zig").max_quest_position_data;
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
pub const default_world_time_send_ticks = game_types.default_world_time_send_ticks;
pub const default_vehicle_pos_send_ticks = game_types.default_vehicle_pos_send_ticks;
pub const default_sleeper_tick_ticks = game_types.default_sleeper_tick_ticks;
pub const default_turret_sync_ticks = game_types.default_turret_sync_ticks;
pub const default_save_interval_ticks = game_types.default_save_interval_ticks;
pub const default_spawn_area_radius_max = game_types.default_spawn_area_radius_max;
pub const default_max_claimed_damage = game_types.default_max_claimed_damage;
pub const default_max_edit_range = game_types.default_max_edit_range;
pub const default_interest_range = game_types.default_interest_range;
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
pub const default_lock_stale_ns = game_types.default_lock_stale_ns;
pub const default_join_rate_limit_ms = game_types.default_join_rate_limit_ms;
pub const default_craft_max_times = game_types.default_craft_max_times;
pub const default_deco_objects_per_join = game_types.default_deco_objects_per_join;
pub const window_fast_attempts = game_types.window_fast_attempts;
pub const window_retry_sleep_ns = game_types.window_retry_sleep_ns;
pub const window_retry_budget_ns = game_types.window_retry_budget_ns;
pub const critical_retry_budget_ns = game_types.critical_retry_budget_ns;
pub const default_view_radius = game_types.default_view_radius;
pub const default_max_players = game_types.default_max_players;
pub const replicate_frame_cap = game_types.replicate_frame_cap;
pub const speeds_body_off = game_types.speeds_body_off;
pub const flags_body_off = game_types.flags_body_off;

pub const LandClaim = game_types.LandClaim;
pub const Client = game_types.Client;

const game_wasm_host = @import("game/wasm_host.zig");
pub const killVerdict = game_wasm_host.killVerdict;
const wasmLog = game_wasm_host.wasmLog;
const wasmTick = game_wasm_host.wasmTick;
const wasmQueue = game_wasm_host.wasmQueue;
const wasmSense = game_wasm_host.wasmSense;
const wasmQuery = game_wasm_host.wasmQuery;
const max_plugin_cmd_len = game_wasm_host.max_plugin_cmd_len;

fn stabilityFacts(ctx: ?*anyopaque, id: u16) stability_mod.Facts {
    return game_stability.stabilityFacts(ctx, id);
}

fn bloodMoonDayFor(clk: ecs.aidirector.WorldClock) i32 {
    return game_stability.bloodMoonDayFor(clk);
}

pub fn stabilityAfterSetBlock(self: *Game, x: i32, y: i32, z: i32, old_id: u16, new_id: u16) usize {
    return game_stability.stabilityAfterSetBlock(self, x, y, z, old_id, new_id);
}

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
    /// In-memory only: stock persists these, zdtd does not yet.
    allies: ally_mod.Store = .{},
    /// Per-session party groups keyed on runtime entity id (stock PartyManager;
    /// RE parties-factions.md §2). Session only, thrown away on disband.
    parties: ecs.party.Manager = .{},
    /// Load-shed valve: weak evidence + deferrable broadcasts are dropped while
    /// `tick_n < shed_until_tick`. Armed only by the real-time run() overrun branch.
    shed_until_tick: u64 = 0,
    tick_n: u64 = 0,
    running: bool = true,
    challenge_counter: u64 = 1,
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
    block_damage_player: u16 = 100,
    block_damage_ai: u16 = 100,
    block_damage_ai_bm: u16 = 100,
    drop_on_death: u8 = 1,
    land_claim_size: u16 = 41,
    land_claim_online_dur: u16 = 4,
    land_claim_offline_dur: u16 = 4,
    land_claim_expiry_days: u16 = 3,
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
    /// blocks.xml Texture → textureFull defaults (unpainted cells).
    block_textures: assets_block_textures.Table = assets_block_textures.Table.empty(),
    painting: assets_painting.Table = assets_painting.Table.empty(),
    spawning: assets_spawning.Table = assets_spawning.Table.empty(),
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
    workstations: workstations_mod.WorkstationStore = .{},
    /// Vending machines (TileEntityVendingMachine, type 7): per-block TraderData
    /// store keyed by world pos. Created on place, cleared on removal.
    vending: vending_mod.VendingStore = .{},
    /// Lock table: channel → holder peer slot (-1 free).
    lock_channel: [16]i32 = .{-1} ** 16,
    lock_holder_entity: [16]i32 = .{-1} ** 16,
    /// When the lock was granted (mono ns); 0 = free. Stale holders auto-release.
    lock_granted_ns: [16]u64 = .{0} ** 16,
    /// Position key for the locked TE (packed xyz); 0 = channel-only lock.
    lock_pos_key: [16]u64 = .{0} ** 16,
    /// Per-IP join throttle (ms since epoch-ish via monoNs/1e6). GAP 12: was 16,
    /// so a busy subnet's extra sources were unthrottled rather than dropped.
    join_ip: [64]u32 = .{0} ** 64,
    join_ip_ms: [64]u64 = .{0} ** 64,
    join_ip_n: usize = 0,
    /// GAP 12: was 32; a long-lived server can ban more than a handful of
    /// players without silently forgetting the tail.
    ban_ip: [128]u32 = .{0} ** 128,
    ban_n: usize = 0,
    /// Sparse block durability: absolute BlockValue.damage at (x,y,z).
    /// GAP 12: was 64, so the 65th damaged block silently lost its damage.
    block_hp_key: [256]u64 = .{0} ** 256,
    block_hp: [256]u16 = .{0} ** 256,
    block_hp_n: usize = 0,
    /// Sparse BlockValue.rawData (rotation/meta bits) for door/shape fidelity.
    /// The chunk plane is the source of truth (GAP 13); this cache mirrors the
    /// hot path and its eviction is a cache miss, not content loss.
    block_raw_key: [256]u64 = .{0} ** 256,
    block_raw: [256]u32 = .{0} ** 256,
    block_raw_n: usize = 0,
    view_radius: i32 = default_view_radius,
    /// Advertised + soft join cap (ServerMaxPlayerCount); ≤ max_clients.
    max_players: u16 = default_max_players,
    world_name: []const u8 = "zdtd",
    /// Sandbox code echoed in the GameStats blob (GameStatsValues.sandbox_code);
    /// the client decodes TemperatureSurvival / StormFreq / blood-moon gates
    /// from it (RE sandbox-options §8).
    sandbox_code: []const u8 = "",
    sandbox_preset: []const u8 = "",
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
    webui: webui_mod.Server = .{},
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
    /// Last blood-moon-music state broadcast (edge-triggered).
    bloodmoon_sent: bool = false,
    /// Empty = open. Non-empty = LiteNet Connect key; mismatched keys are rejected.
    password: []const u8 = "",
    /// Stream / authority tunables (InitOptions; filled from zdtd.toml via `zdtd_config.applyToInitOptions`).
    max_streamed_chunks: usize = default_max_streamed_chunks,
    chunk_stream_radius_min: i32 = default_chunk_stream_radius_min,
    chunk_stream_radius_max: i32 = default_chunk_stream_radius_max,
    chunk_adds_per_stream_tick: u32 = default_chunk_adds_per_stream_tick,
    chunk_stream_period_ticks: u64 = default_chunk_stream_period_ticks,
    motion_replicate_period_ticks: u64 = default_motion_replicate_period_ticks,
    world_time_send_ticks: u64 = default_world_time_send_ticks,
    vehicle_pos_send_ticks: u64 = default_vehicle_pos_send_ticks,
    sleeper_tick_ticks: u64 = default_sleeper_tick_ticks,
    turret_sync_ticks: u64 = default_turret_sync_ticks,
    save_interval_ticks: u64 = default_save_interval_ticks,
    spawn_area_radius_max: i32 = default_spawn_area_radius_max,
    max_claimed_damage: i32 = default_max_claimed_damage,
    max_edit_range: f32 = default_max_edit_range,
    interest_range: f32 = default_interest_range,
    max_horizontal_speed_mps: f32 = game_types.default_max_horizontal_speed_mps,
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
    /// Per-chunk storage/prefab TE scan caps (zdtd.toml [sim] te_scan_*).
    te_scan_block_cap: u32 = game_types.default_te_scan_block_cap,
    te_scan_te_cap: u32 = game_types.default_te_scan_te_cap,
    /// Workstation craft budgets (zdtd.toml [sim] workstation_*).
    workstation_crafts_per_tick: u16 = game_types.default_workstation_crafts_per_tick,
    workstation_craft_backlog: f32 = game_types.default_workstation_craft_backlog,
    /// Periodic apm snapshot dump period in ticks (zdtd.toml [apm] dump_every_s).
    apm_report_period_ticks: u64 = game_types.default_apm_report_period_ticks,

    /// Heap-allocate and init (tests and helpers). Caller must `deinit` then `allocator.destroy`.
    pub fn create(allocator: std.mem.Allocator, world_dir: []const u8, port: u16) !*Game {
        return createWithOptions(allocator, world_dir, port, .{});
    }

    pub fn createWithMap(allocator: std.mem.Allocator, world_dir: []const u8, map_dir: ?[]const u8, port: u16) !*Game {
        return createWithOptions(allocator, world_dir, port, .{ .map_dir = map_dir });
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
            .max_players = max_pl,
            .wire_chunks = opts.wire_chunks,
            .deco_trees = opts.deco_trees,
            .deco_mirror = opts.deco_mirror,
            .block_id_mapping = opts.block_id_mapping,
            .terrain_snapshot_on = opts.terrain_snapshot,
            .job_batches = opts.job_batches,
            .password = opts.password,
            .pvp_mode = opts.player_killing_mode,
            .xp_multiplier = opts.xp_multiplier,
            .block_damage_player = opts.block_damage_player,
            .block_damage_ai = opts.block_damage_ai,
            .block_damage_ai_bm = opts.block_damage_ai_bm,
            .drop_on_death = opts.drop_on_death,
            .land_claim_size = opts.land_claim_size,
            .land_claim_online_dur = opts.land_claim_online_durability_modifier,
            .land_claim_offline_dur = opts.land_claim_offline_durability_modifier,
            .land_claim_expiry_days = opts.land_claim_expiry_days,
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
            .world_time_send_ticks = opts.world_time_send_ticks,
            .vehicle_pos_send_ticks = opts.vehicle_pos_send_ticks,
            .sleeper_tick_ticks = opts.sleeper_tick_ticks,
            .turret_sync_ticks = opts.turret_sync_ticks,
            .save_interval_ticks = opts.save_interval_ticks,
            .spawn_area_radius_max = opts.spawn_area_radius_max,
            .max_claimed_damage = opts.max_claimed_damage,
            .max_edit_range = opts.max_edit_range,
            .interest_range = opts.interest_range,
            .max_horizontal_speed_mps = opts.max_horizontal_speed_mps,
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
            .te_scan_block_cap = opts.te_scan_block_cap,
            .te_scan_te_cap = opts.te_scan_te_cap,
            .workstation_crafts_per_tick = opts.workstation_crafts_per_tick,
            .workstation_craft_backlog = opts.workstation_craft_backlog,
            .apm_report_period_ticks = if (opts.apm_dump_every_s) |s|
                // 0 disables the periodic dump (mod-by-zero guard; maxInt never fires).
                if (s == 0) std.math.maxInt(u64) else s * protocol.ticks_per_second
            else
                game_types.default_apm_report_period_ticks,
            .deco_objects_per_join = opts.deco_objects_per_join,
            .sandbox_code = opts.sandbox_code,
            .sandbox_preset = opts.sandbox_preset,
            .plugins = .{ .sample_enabled = opts.enable_sample_plugin },
            .wasm_ctx = .{
                .data = self,
                .log_fn = &wasmLog,
                .tick_fn = &wasmTick,
                .queue_fn = &wasmQueue,
                .sense_fn = &wasmSense,
                .query_fn = &wasmQuery,
            },
        };
        // Apply serverconfig gameplay options to the sim director/clock.
        self.sim.director.difficulty = opts.game_difficulty;
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
        // Bot host policy (ADR 0026 / ADR 0021): `[bots]` from mode/toml.
        self.bots.cfg = opts.bot_config;
        // Sleeper wake/stage radius (`[sim] sleeper_party_radius`).
        self.sleeper_party_radius = opts.sleeper_party_radius;
        errdefer {
            // Network half first so fail-closed webui (after net/admin listen)
            // does not leak FDs in tests/library createWithOptions paths.
            self.webui.deinit();
            self.admin.deinit();
            self.info_tcp.stop();
            self.net.deinit();
            @import("game/lifecycle.zig").deinitStores(self);
            self.world.deinit();
        }
        // [perf] async_chunk_flush. Offline Game (port 0) runs force-serial, so
        // World.asyncEnabled() keeps writes inline there regardless.
        self.world.async_flush = opts.async_chunk_flush;
        try self.sim.ensureNetMap(allocator);
        // Back the ECS vehicle-physics ground hook with the real block store.
        self.sim.ground_ctx = self;
        self.sim.ground_fn = &heightAtWorld;
        // AI path move probe: destination footing, or blocked.
        self.sim.step_ctx = self;
        self.sim.step_fn = &pathStepAt;
        // AI sense LOS probe: block-solid ray cast (stock CanSee Voxel.Raycast).
        self.sim.solid_ctx = self;
        self.sim.solid_fn = &blockSolidAt;
        // Door-id oracle for the solid probe: an open door is passable.
        self.world.door_id_ctx = self;
        self.world.door_id_fn = &blockIsDoor;
        // AI sense smell probe: effective radius (stock cSmellRadiusMin / Bleed,
        // the latter bound to buffInjuryBleeding via the buff catalog).
        self.sim.smell_ctx = self;
        self.sim.smell_fn = &smellRadiusFor;
        // Zombie AI bot targets (ADR 0026): bots are not ECS entities, so the
        // AI reaches them through these Game-side hooks (snap + melee damage).
        self.sim.bot_snap_ctx = self;
        self.sim.bot_snap_fn = &botSnapAt;
        self.sim.bot_damage_ctx = self;
        self.sim.bot_damage_fn = &botDamageAt;
        self.sim.place_ctx = self;
        self.sim.place_fn = &placeBlockId;
        self.sim.fuel_value_ctx = self;
        self.sim.fuel_value_fn = &itemFuelValue;
        self.sim.stack_ctx = self;
        self.sim.stack_fn = &itemStackFor;
        self.sim.is_armor_ctx = self;
        self.sim.is_armor_fn = &itemIsArmor;
        // Quest POI placement: rally objectives need a real prefab footprint.
        self.sim.poi_ctx = self;
        self.sim.poi_fn = &poiRectAtWorld;
        self.sim.nearest_poi_ctx = self;
        self.sim.nearest_poi_fn = &nearestPoiAtWorld;
        // Quest POI lockout exempts party members (stock CheckForPOILockouts).
        self.sim.party_same_ctx = self;
        self.sim.party_same_fn = &partySame;
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
            self.world_name = "stock";
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
        try @import("game/init_world.zig").initWorld(self, allocator, port, opts, had_saved_entities);
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

    fn heightAtWorld(ctx: ?*anyopaque, wx: i32, wz: i32) f32 {
        return game_hooks.heightAtWorld(ctx, wx, wz);
    }

    fn blockSolidAt(ctx: ?*anyopaque, x: i32, y: i32, z: i32) bool {
        return game_hooks.blockSolidAt(ctx, x, y, z);
    }

    fn blockIsDoor(ctx: ?*anyopaque, id: u16) bool {
        return game_hooks.blockIsDoor(ctx, id);
    }

    fn smellRadiusFor(ctx: ?*anyopaque, slot: ecs.Slot) f32 {
        return game_hooks.smellRadiusFor(ctx, slot);
    }

    pub fn spawnPoiTraders(self: *Game) void {
        return game_hooks.spawnPoiTraders(self);
    }

    fn poiRectAtWorld(ctx: ?*anyopaque, x: f32, z: f32) ?ecs.components.PoiRect {
        return game_hooks.poiRectAtWorld(ctx, x, z);
    }

    fn partySame(ctx: ?*anyopaque, a: i32, b: i32) bool {
        return game_hooks.partySame(ctx, a, b);
    }

    fn nearestPoiAtWorld(ctx: ?*anyopaque, x: f32, z: f32) ?ecs.components.PoiRect {
        return game_hooks.nearestPoiAtWorld(ctx, x, z);
    }

    pub fn pathStepAt(ctx: ?*anyopaque, _: i32, _: i32, from_y: i32, tx: i32, tz: i32) ?i32 {
        return game_hooks.pathStepAt(ctx, 0, 0, from_y, tx, tz);
    }

    /// Zombie AI bot snap (ADR 0026): exact bot by net id, or nearest within
    /// `range_sq` of (zx, zz). See game/hooks.zig for the BotManager scan.
    pub fn botSnapAt(ctx: ?*anyopaque, zx: f32, zz: f32, range_sq: f32, exact: i32) ecs.BotSnap {
        return game_hooks.botSnapAt(ctx, zx, zz, range_sq, exact);
    }

    /// Zombie melee on a host-side bot (ADR 0026); attributed via BotManager.
    pub fn botDamageAt(ctx: ?*anyopaque, bot_net: i32, attacker_net: i32, amount: f32) bool {
        return game_hooks.botDamageAt(ctx, bot_net, attacker_net, amount);
    }

    fn placeBlockId(ctx: ?*anyopaque, item_id: u16) u16 {
        return game_hooks.placeBlockId(ctx, item_id);
    }

    fn itemFuelValue(ctx: ?*anyopaque, item_id: u16) f32 {
        return game_hooks.itemFuelValue(ctx, item_id);
    }

    fn itemStackFor(ctx: ?*anyopaque, item_id: u16) u16 {
        return game_hooks.itemStackFor(ctx, item_id);
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
            const max = itemStackFor(self, s.item_id);
            if (max > 0 and s.count > max) s.count = max;
        }
    }

    /// ECS armor hook: stock/builtin name starts with "armor" (game/craft.zig).
    pub const itemIsArmor = game_craft.itemIsArmor;

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
    pub fn sendDecoAroundSpawn(self: *Game, c: *const Client, peer: *ln_peer.Peer, wx: i32, wz: i32) !void {
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
        var r: i32 = if (c.view_radius < 1) self.chunk_stream_radius_min else c.view_radius;
        if (r < self.chunk_stream_radius_min) r = self.chunk_stream_radius_min;
        if (r > self.chunk_stream_radius_max) r = self.chunk_stream_radius_max;
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

    pub fn killXpAward(self: *Game, killer_slot: usize, base: u64) void {
        return game_player.killXpAward(self, killer_slot, base);
    }

    pub fn xpGainFor(self: *Game, victim_nid: i32) u64 {
        return game_player.xpGainFor(self, victim_nid);
    }

    /// Shared reliable-window retry pump: one place for the budget/deadline/sleep
    /// rules so broadcast and sendGameBudget share the same behaviour.
    /// `budget_ns==null` means no deadline (stream/broadcast). Returns
    /// error.WindowFull on exhaustion; callers own drop counters/logs and the
    /// packages_broadcast count (via count_broadcast).
    pub fn sendReliablePumped(self: *Game, peer: *ln_peer.Peer, tag: []const u8, framed: []const u8, budget_ns: ?u64, max_attempts: u32, count_broadcast: bool) !void {
        return game_net.sendReliablePumped(self, peer, tag, framed, budget_ns, max_attempts, count_broadcast);
    }

    pub fn gameStageOf(self: *const Game, slot: usize) i32 {
        return game_player.gameStageOf(self, slot);
    }

    pub fn lootStageOf(self: *const Game, slot: usize) i32 {
        return game_player.lootStageOf(self, slot);
    }

    pub fn partyStageAround(self: *const Game, wx: f32, wz: f32, radius: f32) i32 {
        return game_player.partyStageAround(self, wx, wz, radius);
    }

    pub fn partyHighestGameStage(self: *Game) i32 {
        return game_player.partyHighestGameStage(self);
    }

    pub fn partyLootStage(self: *const Game) i32 {
        return game_player.partyLootStage(self);
    }

    pub fn lootStageForPlayer(self: *Game, peer_slot: usize) i32 {
        return game_player.lootStageForPlayer(self, peer_slot);
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

    /// Integrate host-commanded bot move intents (ADR 0026). Bots are not ECS
    /// entities; the BotManager owns them and integrates their move intents
    /// here. Replication streams their positions via the non-ECS path.
    pub fn tickBots(self: *Game, dt: f32) void {
        self.bots.tick(self, dt);
    }

    /// Allocate a globally-unique net id for a host-side bot. Drawn from the
    /// same sim counter as ECS spawns (World.spawnBase increments next_net_id),
    /// so bot ids never collide with player/zombie/... ids.
    pub fn allocBotNetId(self: *Game) i32 {
        const id = self.sim.next_net_id;
        self.sim.next_net_id +%= 1;
        return id;
    }

    pub fn worldHour(self: *const Game) u64 {
        return game_tick.worldHour(self);
    }

    pub fn tickAirDrop(self: *Game) void {
        return game_tick.tickAirDrop(self);
    }

    pub fn tickZombieBlockDamage(self: *Game) void {
        return game_tick.tickZombieBlockDamage(self);
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

    pub fn removeClaimAt(self: *Game, x: i32, y: i32, z: i32) void {
        return game_world.removeClaimAt(self, x, y, z);
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

    pub fn saveClaims(self: *Game) !void {
        return persist.saveClaims(self);
    }

    fn loadClaims(self: *Game) !void {
        return persist.loadClaims(self);
    }

    /// Re-map restored claims to the entity id a player got at login, and mark
    /// the owner online. Called once per login; no-op for unknown names.
    pub fn reclaimForName(self: *Game, name: []const u8, entity_id: i32) void {
        if (entity_id <= 0) return;
        for (self.land_claims[0..self.land_claims_n]) |*claim| {
            if (claim.owner_name_len != name.len) continue;
            if (!std.mem.eql(u8, claim.owner_name[0..claim.owner_name_len], name)) continue;
            claim.owner_entity = entity_id;
            claim.owner_online = true;
            claim.owner_seen_day = self.sim.director.clock.day;
        }
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

    pub fn getBlockHp(self: *const Game, x: i32, y: i32, z: i32) u16 {
        return game_world.getBlockHp(self, x, y, z);
    }

    /// Voxel line-of-sight gate for `bot shoot` (BOTS_SPEC §4 host-LOS).
    pub fn botLosClear(self: *Game, from: [3]f32, to: [3]f32) bool {
        return game_world.botLosClear(self, from, to);
    }

    /// Cover point not visible from `threat` (BOTS_SPEC §3 `zdtd.query`
    /// "cover"); Doom 3 idAASFindCover / clanker `BotBrain.FindCover` port.
    pub fn findCover(self: *Game, from: [3]f32, threat: [3]f32, dist: f32) ?[3]f32 {
        return game_world.findCover(self, from, threat, dist);
    }

    /// Ground/surface Y at world (x, z); bots stand here (spawn + move).
    pub fn groundHeight(self: *Game, x: i32, z: i32) f32 {
        return game_world.groundHeight(self, x, z);
    }

    pub fn setBlockHp(self: *Game, x: i32, y: i32, z: i32, abs: u16) void {
        return game_world.setBlockHp(self, x, y, z, abs);
    }

    pub fn addBlockDamage(self: *Game, x: i32, y: i32, z: i32, dmg: u16) u16 {
        return game_world.addBlockDamage(self, x, y, z, dmg);
    }

    pub fn clearBlockHp(self: *Game, x: i32, y: i32, z: i32) void {
        return game_world.clearBlockHp(self, x, y, z);
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
    pub fn clearLocksForPeer(self: *Game, peer_slot: usize) void {
        return game_locks.clearLocksForPeer(self, peer_slot);
    }

    /// Drop locks held longer than the lock stale window (tick path).
    pub fn reapStaleLocks(self: *Game) void {
        return game_tick.reapStaleLocks(self);
    }

    pub fn reapStalePeers(self: *Game) void {
        return game_tick.reapStalePeers(self);
    }

    pub fn peerIpKey(peer: *const ln_peer.Peer) u32 {
        return game_net.peerIpKey(peer);
    }

    pub fn joinRateLimited(self: *Game, ip: u32) bool {
        return game_bans.joinRateLimited(self, ip);
    }
    pub fn isBanned(self: *const Game, ip: u32) bool {
        return game_bans.isBanned(self, ip);
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
        const info = serverinfo_tcp.ServerInfo{
            .game_name = "zdtd",
            .game_host = "zdtd",
            .level_name = self.world_name,
            .ip = "127.0.0.1",
            .info_port = self.info_port,
            .max_players = self.max_players,
            .current_players = @intCast(self.countJoined()),
            .server_version = version.stock_wire_gsi_version,
            .world_size = self.worldSize(),
            .eac_enabled = false,
            .password_protected = self.password.len > 0,
            .sandbox_preset = self.sandbox_preset,
            .sandbox_code = self.sandbox_code,
        };
        return try serverinfo_tcp.buildInfoText(buf, info);
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
        const pf = if (self.world.prefabs) |*p| p else return;
        var di: ?usize = null;
        for (pf.items, 0..) |d, i| {
            if (world_store.prefabs.isPart(d.name)) continue;
            if (wx < d.x or wx >= d.x + d.size_x or wz < d.z or wz >= d.z + d.size_z) continue;
            di = i;
            break;
        }
        const idx = di orelse return;
        const d = pf.items[idx];
        const tb = pf.getTtsBlocks(d.name) orelse return;
        const Ctx = struct {
            g: *Game,
            fn put(ctx: ?*anyopaque, bx: i32, by: i32, bz: i32, raw: u32, tex: u64, dens: ?u8) void {
                const g: *Game = @ptrCast(@alignCast(ctx.?));
                g.world.setBlockTexDensWorld(bx, by, bz, raw, tex, dens) catch return;
                g.clearBlockHp(bx, by, bz);
                if (packages.buildSetBlockBodyRaw(g.body_buf[0..96], bx, by, bz, raw, 0, -1, -1)) |sb| {
                    // Best-effort visual broadcast: the world store is already
                    // authoritative; a dropped SetBlock only delays the paint.
                    g.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(bx), @floatFromInt(bz), g.interest_range) catch {};
                } else |_| {}
            }
        };
        world_tts.paintDecoration(tb, d.x, d.stampY(), d.z, d.rot, self.world.terrain_ids.water, self.world.terrain_ids.terrain_filler, self.world.terrain_ids.terrain_filler_adaptive, Ctx.put, self);
        std.debug.print("zdtd: reset POI {s} at ({d},{d})\n", .{ d.name, d.x, d.z });
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
    /// renumber every block the blob failed to name. So any validation failure,
    /// an empty dump, or a compressed size that does not fit `send_buf` all skip
    /// the package entirely and leave today's LoadLocal behaviour in place.
    pub fn sendBlockIdMapping(self: *Game, peer: *ln_peer.Peer) !void {
        if (!self.block_id_mapping) return;
        const nameid = packages.stock_nameid;
        if (self.maxdamage.idNameCount() == 0) {
            var ts: [19]u8 = undefined;
            std.debug.print("zdtd: {s} blocks IdMapping skipped (no AssignIds dump loaded)\n", .{clock.wallStamp(&ts)});
            return;
        }
        const summary = nameid.measure(self.maxdamage.idNameIterator(), &self.nameid_seen) catch |err| {
            var ts: [19]u8 = undefined;
            std.debug.print("zdtd: {s} blocks IdMapping skipped ({s}); client keeps local ids\n", .{ clock.wallStamp(&ts), @errorName(err) });
            return;
        };

        // NetPackageIdMapping body: name | i32 dataLen | data (asm.il 822416-822438).
        const map_name = "blocks";
        // One-byte 7-bit length prefix; the writer below emits exactly one byte.
        comptime std.debug.assert(map_name.len < 0x80);
        const body_len = 1 + map_name.len + 4 + summary.bytes;
        // Framed into body_buf, not send_buf: the deflated mapping lands around
        // 255 KiB, which leaves no headroom in the 256 KiB send_buf if the dump
        // grows. body_buf is 512 KiB and idle here (the config files that use it
        // are sent after this returns).
        var fr: wire_frame.DeflateFramer = undefined;
        fr.begin(&self.body_buf, &self.deflate_window, 0, packages.idOf("NetPackageIdMapping").?, body_len) catch |err| {
            var ts: [19]u8 = undefined;
            std.debug.print("zdtd: {s} blocks IdMapping frame init failed: {s}\n", .{ clock.wallStamp(&ts), @errorName(err) });
            return;
        };
        const w = fr.writer();
        const ok = blk: {
            w.writeByte(@intCast(map_name.len)) catch break :blk false;
            w.writeAll(map_name) catch break :blk false;
            w.writeInt(i32, @intCast(summary.bytes), .little) catch break :blk false;
            nameid.write(w, self.maxdamage.idNameIterator(), summary) catch break :blk false;
            break :blk true;
        };
        if (!ok) {
            var ts: [19]u8 = undefined;
            std.debug.print(
                "zdtd: {s} blocks IdMapping does not fit body_buf ({d} raw bytes); client keeps local ids\n",
                .{ clock.wallStamp(&ts), summary.bytes },
            );
            return;
        }
        const framed = fr.finish() catch |err| {
            var ts: [19]u8 = undefined;
            std.debug.print("zdtd: {s} blocks IdMapping deflate failed: {s}\n", .{ clock.wallStamp(&ts), @errorName(err) });
            return;
        };
        self.sendFramedReliable(peer, "NetPackageIdMapping", framed, critical_retry_budget_ns, true) catch |err| {
            var ts: [19]u8 = undefined;
            std.debug.print("zdtd: {s} blocks IdMapping send failed: {s}\n", .{ clock.wallStamp(&ts), @errorName(err) });
            return err;
        };
        std.debug.print(
            "zdtd: blocks IdMapping objs={d} raw={d} wire={d}\n",
            .{ summary.count, summary.bytes, framed.len },
        );
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

    /// If feet Y is deep void / far below DTM surface, snap to surface+0.9 and
    /// optionally teleport the peer. Returns new Y when snapped, else null.
    /// Threshold surface-8 (was -24): late-suite mesh float still placeable after
    /// SetBlock pre-snap; deeper than -8 without snap caused type=0 power fails.
    pub fn rescueDeepVoid(self: *Game, peer: *ln_peer.Peer, entity_id: i32, x: f32, y: f32, z: f32, do_teleport: bool) !?f32 {
        return game_rescue.rescueDeepVoid(self, peer, entity_id, x, y, z, do_teleport);
    }
    pub fn withinEditReach(self: *const Game, px: f32, py: f32, pz: f32, bx: f32, by: f32, bz: f32) bool {
        return game_rescue.withinEditReach(self, px, py, pz, bx, by, bz);
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
        return game_tick.reapPolicyKicks(self);
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
        if (!self.authorityCorrects()) return false;
        const q = c.guard.quarantine;
        const denied = switch (surf) {
            .none => false,
            .damage => q.no_damage,
            .container => q.no_container,
            .block => q.no_setblock,
        };
        if (!denied) return false;
        self.harness.counters.inc(.quarantine_rejects);
        const n = self.harness.counters.get(.quarantine_rejects);
        if (n == 1 or n % 100 == 0) {
            std.debug.print(
                "zdtd: quarantine deny n={d} slot={d} surface={s}\n",
                .{ n, c.slot, @tagName(surf) },
            );
        }
        return true;
    }

    /// Weak (record-only) block-destroy rate. Soft by construction, so
    /// `guard_policy.evaluate` can never turn it into a quarantine or a kick.
    pub fn noteBlockBreak(self: *Game, c: *Client) void {
        if (c.farm_window_tick == 0 or self.tick_n -% c.farm_window_tick >= self.guard.window_ticks) {
            c.farm_window_tick = self.tick_n;
            c.farm_breaks = 0;
        }
        c.farm_breaks +|= 1;
        if (c.farm_breaks != self.guard.weak_break_rate_per_window) return;
        const peer_local: i32 = if (c.peer) |p| p.local_id else -1;
        self.noteEvidence(
            c,
            peer_local,
            c.entity_id,
            .farming,
            .soft,
            .block,
            @floatFromInt(c.farm_breaks),
            @floatFromInt(self.guard.weak_break_rate_per_window),
        );
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
        const ps = self.sim.playerByPeer(c.slot) orelse return false;
        const p = self.sim.transform[ps];
        if (!self.withinEditReach(p.x, p.y, p.z, @floatFromInt(x), @floatFromInt(y), @floatFromInt(z))) return false;
        if (self.claimCovering(x, z)) |claim| {
            if (claim.owner_entity != self.sim.network_id[ps].id) return false;
        }
        return true;
    }

    /// World Y for spawning mobs next to a player (surface band, not void/float).
    pub fn spawnYNearPlayer(self: *Game, tr_x: f32, tr_y: f32, tr_z: f32) f32 {
        const gx: i32 = std.math.lossyCast(i32, @floor(tr_x));
        const gz: i32 = std.math.lossyCast(i32, @floor(tr_z));
        const h_u16: u16 = self.world.heightWorld(gx, gz) catch {
            return if (tr_y > 2) tr_y else @as(f32, @floatFromInt(self.world.primarySpawn().y)) + 1;
        };
        const surface: f32 = @floatFromInt(h_u16);
        // Prefer surface+1; if player is already near surface, keep their y band.
        if (tr_y > surface - 2 and tr_y < surface + 8) return tr_y;
        return surface + 1.0;
    }

    /// Advertised map size (GSI world_size). Stock reports the loaded map's
    /// HeightMapSize; offline/flat worlds fall back to the Navezgane default
    /// 6144 (B1, value-level sweep).
    pub fn worldSize(self: *const Game) i32 {
        return if (self.world.heightmap) |hm| hm.width else 6144;
    }

    /// Align spawn to DTM height and ensure a solid under the feet block so
    /// dig/place sample rings (BlockUnderFeet) see terrain, not air.
    pub fn spawnSurface(self: *Game, sx: i32, sz: i32) struct { x: i32, y: i32, z: i32 } {
        const fallback: u16 = @intCast(@max(1, self.world.primarySpawn().y));
        const h_u16: u16 = self.world.heightWorld(sx, sz) catch fallback;
        const h: i32 = @intCast(h_u16);
        // heightWorld = top solid; PDF/entity feet use that block Y; entity float y = h+1.
        const feet_y = @max(h, 1);
        // Live AssignIds resolved at init (A05); the module pin is the offline
        // default until resolveTerrainIds runs, so modded dumps stay correct.
        const dirt = self.world.terrain_ids.dirt;
        // 3x3 pad of solid at surface so client mesh + BlockUnderFeet see ground.
        var dz: i32 = -1;
        while (dz <= 1) : (dz += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                const px = sx + dx;
                const pz = sz + dz;
                // Ensure surface cell solid.
                const cur = self.world.blockWorld(px, feet_y, pz) catch 0;
                if (cur == 0) self.world.setBlockWorld(px, feet_y, pz, dirt) catch |err| {
                    std.debug.print(
                        "zdtd: spawn pad setBlock ({d},{d},{d}) failed: {s}\n",
                        .{ px, feet_y, pz, @errorName(err) },
                    );
                };
                // One block below if empty (stairs / overhang).
                if (feet_y > 0) {
                    const below = self.world.blockWorld(px, feet_y - 1, pz) catch 0;
                    if (below == 0) self.world.setBlockWorld(px, feet_y - 1, pz, dirt) catch |err| {
                        std.debug.print(
                            "zdtd: spawn pad setBlock ({d},{d},{d}) failed: {s}\n",
                            .{ px, feet_y - 1, pz, @errorName(err) },
                        );
                    };
                }
            }
        }
        return .{ .x = sx, .y = feet_y, .z = sz };
    }

    pub fn sendJoinBundle(self: *Game, c: *Client, peer: *ln_peer.Peer, sx: i32, sy: i32, sz: i32, eid: i32) !void {
        // Snap to solid surface (callers may pass raw primarySpawn Y that floats above DTM).
        // sy is intentionally ignored: DTM surface is authoritative for join/respawn.
        _ = sy;
        const surf = self.spawnSurface(sx, sz);
        const sx2 = surf.x;
        const sy2 = surf.y;
        const sz2 = surf.z;
        // Do NOT re-send WorldInfo: second WorldInfo restarts createWorld mid-session → NRE flood.
        // Order: PlayerId (spawn pos in PDF) → id map → optional join chunk → Spawned → time.
        // First join: bLoaded=true so ToPlayer applies bag. Death re-bundle: false.
        const first_join = !c.entered;
        c.entered = true;
        self.markClaimsForEntity(eid, true);
        // Spawn/respawn resets movement envelope (teleport budget).
        c.move_valid = false;
        c.move_x = @floatFromInt(sx2);
        c.move_y = @as(f32, @floatFromInt(sy2)) + 0.08;
        c.move_z = @floatFromInt(sz2);
        c.move_tick = self.tick_n;
        if (first_join) {
            self.plugins.playerJoin(@intCast(c.slot), eid);
            self.wasm_plugins.playerJoin(@intCast(c.slot), eid);
        }
        const dim: i32 = if (c.view_radius < 1) self.view_radius else c.view_radius;
        // Server journal + stock PDF Quest.Write (RewardItem includes ItemStack).
        // questAcceptStarter refuses a starter already active or completed in an
        // earlier session; a fresh grant is shared with the (post-join) party.
        if (systems.questAcceptStarter(&self.sim, c.slot)) {
            self.shareQuestWithParty(c, self.sim.catalog.starter_id);
        }
        // GAP 12: the join PDF journal was capped at 2 quests while the sim
        // journal holds max_journal (8); a third active quest silently vanished
        // from the client. All stores now size to the sim journal.
        var qbuf: [ecs.components.max_journal]packages.stock_quest.StockQuestWrite = undefined;
        var reward_store: [ecs.components.max_journal][ecs.quest.max_reward_flags]packages.stock_quest.RewardWire = undefined;
        var obj_val_store: [ecs.components.max_journal][ecs.quest.max_phases]u8 = undefined;
        // Caller-frame storage for every slice StockQuestWrite points into:
        // the journal writer reads them after this frame's callees return, so
        // a callee-local store would dangle (kind_store used to live inside
        // fillStockJournalWrites and the body writer could read garbage).
        var kind_store: [ecs.components.max_journal][ecs.quest.max_phases]packages.stock_quest.ObjectiveWriteKind = undefined;
        var pos_store: [ecs.components.max_journal][max_quest_position_data]packages.stock_quest.PositionEntry = undefined;
        const qn = self.fillStockJournalWrites(c.slot, &qbuf, &reward_store, &obj_val_store, &kind_store, &pos_store);
        // Cap always_unlocked list so PlayerId stays under body_buf slice.
        var unlock_names: [64][]const u8 = undefined;
        const unlock_n = self.recipes.appendAlwaysUnlocked(&unlock_names);
        // Restored inventory (players.zsv v2) rides the join PDF: toolbelt =
        // sim slots 0..9, bag = 10.. (client PDF apply keeps that split).
        var tb_slots: [ecs.components.inv_bag_start]packages.stock_inv.StockSlot = undefined;
        var bag_slots: [ecs.components.inv_bag_count]packages.stock_inv.StockSlot = undefined;
        var tb_n: usize = 0;
        var bag_n: usize = 0;
        if (self.sim.playerByPeer(c.slot)) |ps| {
            if (self.sim.mask[ps].inventory) {
                const inv = &self.sim.inventory[ps];
                var any = false;
                for (inv.slots) |s| {
                    if (s.count > 0 and s.item_id != 0) {
                        any = true;
                        break;
                    }
                }
                if (any) {
                    while (tb_n < tb_slots.len) : (tb_n += 1) {
                        tb_slots[tb_n] = packages.stock_inv.slotFromEcs(inv.slots[tb_n], resolveItemType, self);
                    }
                    while (bag_n < bag_slots.len) : (bag_n += 1) {
                        const src = inv.slots[ecs.components.inv_bag_start + bag_n];
                        bag_slots[bag_n] = packages.stock_inv.slotFromEcs(src, resolveItemType, self);
                    }
                }
            }
        }
        if (first_join) {
            // PDF pads bag to CarryCapacity (45); leave headroom for unlocks/quests.
            const pid = try packages.buildPlayerIdBodyInvLoaded(
                self.body_buf[384..16384],
                eid,
                0,
                dim,
                sx2,
                sy2,
                sz2,
                qbuf[0..qn],
                unlock_names[0..unlock_n],
                tb_slots[0..tb_n],
                bag_slots[0..bag_n],
                true,
                c.game_stage_born_world_time,
            );
            try self.sendGameCritical(peer, "NetPackagePlayerId", pid);
            // PersistentPlayerState(Login): entityId → name mapping. Without it the
            // client shows GMSG "Player '' joined" and party UI has no names.
            {
                // Stock builds PersistentPlayerData with PrimaryId =
                // ClientInfo.InternalId and NativeId = ClientInfo.PlatformId
                // (asm.il 1885235). A client that sent no identity still needs a
                // PPD or its name never reaches other clients, so fall back to a
                // stable per-entity id rather than dropping the package.
                var sid_buf: [24]u8 = undefined;
                const fallback: platform_user.Id = .{
                    .platform = "Steam",
                    .id = std.fmt.bufPrint(&sid_buf, "7656119{d:0>10}", .{@as(u32, @intCast(eid))}) catch "76561190000000000",
                };
                const primary_id = c.puid_primary.get() orelse fallback;
                const native_id = c.puid_native.get() orelse primary_id;
                if (packages.stock_inv.buildPersistentPlayerState(
                    self.body_buf[8704..9216],
                    eid,
                    c.name[0..c.name_len],
                    primary_id,
                    native_id,
                    sx2,
                    sy2,
                    sz2,
                )) |pps| {
                    try self.broadcast("NetPackagePersistentPlayerState", pps);
                } else |_| {}
            }
            try self.sendItemIdMapping(peer);
            try self.sendQuestNavObjects(peer, c.slot, eid);
            try self.sendHoldingOnly(peer, c);
            try self.sendPlayerVitals(peer, c);
            // Latch IsSpawned before heavy chunk/entity stream (playtest saw
            // vitals OK but IsSpawned=false when Spawned arrived late/lost).
            {
                const spawned_early = try packages.buildSpawnedBody(
                    self.body_buf[256..384],
                    @intFromEnum(packages.RespawnType.enter_multiplayer),
                    sx2,
                    sy2,
                    sz2,
                    eid,
                );
                try self.sendGame(peer, "NetPackagePlayerSpawnedInWorld", spawned_early);
            }
            try self.sendStockEntitySpawns(peer, c, sx, sz);
            // Multiplayer bodies: every other player in view spawns to this
            // peer, and this peer's body spawns to every client that sees it.
            try game_join.sendPlayerSpawns(self, peer, c, sx, sz);
            // Buffs already on the other players (their AddRemoveBuff relays
            // predate this peer).
            try self.sendBuffSync(peer, c);
            try self.sendSeatedRiders(peer);
            if (self.wire_chunks) {
                const r: i32 = if (c.view_radius < 1) self.chunk_stream_radius_min else @min(c.view_radius, self.chunk_stream_radius_max);
                try self.sendSpawnArea(peer, sx2, sz2, r);
            }
            // Confirm Spawned after stream (EnterMultiplayer; pos = surface snap).
            const spawned = try packages.buildSpawnedBody(
                self.body_buf[256..384],
                @intFromEnum(packages.RespawnType.enter_multiplayer),
                sx2,
                sy2,
                sz2,
                eid,
            );
            try self.sendGame(peer, "NetPackagePlayerSpawnedInWorld", spawned);
        } else {
            // Death re-bundle: never re-send PlayerId (CreateEntity NREs). Re-send
            // Spawned(died) so client IsSpawned latches; refresh vitals/teleport.
            const spawned = try packages.buildSpawnedBody(
                self.body_buf[256..384],
                @intFromEnum(packages.RespawnType.died),
                sx2,
                sy2,
                sz2,
                eid,
            );
            try self.sendGame(peer, "NetPackagePlayerSpawnedInWorld", spawned);
            if (packages.buildEntityTeleportBody(&self.body_buf, eid, @as(f32, @floatFromInt(sx2)), @as(f32, @floatFromInt(sy2)) + 0.08, @as(f32, @floatFromInt(sz2)), 0, 0, 0, true)) |tb| {
                try self.sendGame(peer, "NetPackageEntityTeleport", tb);
            } else |_| {}
            try self.sendHoldingOnly(peer, c);
            try self.sendPlayerVitals(peer, c);
            try self.sendQuestNavObjects(peer, c.slot, eid);
        }
        const wt = try packages.buildWorldTimeBody(self.body_buf[1024..1040], self.sim.director.clock.worldTimeBits());
        try self.sendGame(peer, "NetPackageWorldTime", wt);
        try self.sendGameStats(peer);
        // Blood-moon music is edge-triggered on the broadcast path (rising /
        // falling edge each tick), so a client joining (or respawning) during
        // an active horde would never hear it; replay the current state here
        // (RE aidirector.md DynamicMusic.Conductor eligibility).
        if (self.sim.director.bloodmoon_active) {
            const bm_body = try packages.buildBloodmoonMusicBody(self.body_buf[0..1], true);
            try self.sendGame(peer, "NetPackageBloodmoonMusic", bm_body);
        }
        // Weather only once the client has already completed first join (re-bundle /
        // respawn). First join: client InitPackages may still be null → underrun kick.
        if (!first_join) try self.sendWeather(peer);
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
        const clk = self.sim.director.clock;
        return .{
            .game_difficulty = self.sim.director.difficulty,
            .blood_moon_enemy_count = self.sim.director.bloodmoon_enemy_count,
            .enemy_difficulty = self.sim.director.enemy_difficulty,
            .day_light_length = @trunc(clk.dusk - clk.dawn),
            .day_night_length = @trunc(clk.seconds_per_hour * 24.0 / 60.0),
            .blood_moon_day = bloodMoonDayFor(clk),
            .block_damage_player = self.block_damage_player,
            .block_damage_ai = self.block_damage_ai,
            .block_damage_ai_bm = self.block_damage_ai_bm,
            .xp_multiplier = self.xp_multiplier,
            .player_killing_mode = self.pvp_mode,
            .drop_on_death = self.drop_on_death,
            .land_claim_size = self.land_claim_size,
            .land_claim_online_dur = self.land_claim_online_dur,
            .land_claim_offline_dur = self.land_claim_offline_dur,
            .loot_respawn_days = self.loot_respawn_days,
            .land_claim_expiry_time = self.land_claim_expiry_days,
            // Stock GameStat.AirDropFrequency is in DAYS (default 3/3 days;
            // aidirector.md airdrop schedule); the config key + sim interval
            // are in game hours (config.zig), so convert for the wire.
            .air_drop_frequency = if (self.air_drop_interval_hours == 0)
                0
            else
                @divTrunc(self.air_drop_interval_hours, 24),
            // Stock TimeOfDayIncPerSec = world-time units per real second
            // (24000-unit day; live-observed 6 at DayLightLength 18). Derive
            // from the clock so the wire matches the sim's own rate.
            .time_of_day_inc_per_sec = @trunc(24000.0 / (clk.seconds_per_hour * 24.0)),
            .storm_freq = self.storm_frequency,
            .sandbox_preset = self.sandbox_preset,
            .sandbox_code = self.sandbox_code,
        };
    }

    /// Re-send the GameStats blob to every entered peer when the scheduled
    /// blood-moon day rolls (a client that joined mid-cycle and sat past its
    /// first horde would otherwise keep the stale red-moon HUD day forever).
    pub fn broadcastGameStats(self: *Game) !void {
        return game_join.broadcastGameStats(self);
    }

    /// Map markers for active journal quests (stock class names only).
    fn sendQuestNavObjects(self: *Game, peer: *ln_peer.Peer, peer_slot: usize, player_eid: i32) !void {
        return game_join.sendQuestNavObjects(self, peer, peer_slot, player_eid);
    }

    /// True when quest id is likely present in stock client QuestClass.
    pub fn isStockClientQuestName(self: *Game, name: []const u8) bool {
        if (name.len == 0) return false;
        // A stock quests.xml catalog is client-known by construction: both the
        // server and the stock client load the same Data/Config/quests.xml, so
        // every def in it has a client QuestClass entry. The prefix gate below
        // only proxies the client catalog for builtin/offline defs (audit B28).
        if (self.sim.catalog.source == .stock_xml) return true;
        if (std.mem.startsWith(u8, name, "quest_")) return true;
        if (std.mem.startsWith(u8, name, "tier")) return true;
        // Other stock quest-name families the client's quests.xml knows
        // (intro_buried_supplies, the test_* fixtures, challengegroup_reward_*,
        // treasure_* — stock ships 7 treasure maps).
        if (std.mem.startsWith(u8, name, "intro_")) return true;
        if (std.mem.startsWith(u8, name, "test_")) return true;
        if (std.mem.startsWith(u8, name, "challengegroup_reward_")) return true;
        if (std.mem.startsWith(u8, name, "treasure_")) return true;
        return false;
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

    // _fillStockJournalWritesImpl removed — body lives in game/quest.zig

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
    fn sendStockEntitySpawns(self: *Game, peer: *ln_peer.Peer, c: *Client, px: i32, pz: i32) !void {
        return game_join.sendStockEntitySpawns(self, peer, c, px, pz);
    }

    /// Stock EntityStatChanged for core vitals (Health/Stamina/Food/Water).
    fn sendPlayerVitals(self: *Game, peer: *ln_peer.Peer, c: *Client) !void {
        return game_join.sendPlayerVitals(self, peer, c);
    }

    pub fn countJoined(self: *const Game) u16 {
        var n: u16 = 0;
        for (self.clients) |cl| {
            if (cl.joined) n += 1;
        }
        return n;
    }

    pub fn resolveItemType(ctx: ?*anyopaque, item_id: u16) i32 {
        const g: *Game = @ptrCast(@alignCast(ctx.?));
        return g.items.stockTypeFor(item_id);
    }

    pub fn reverseItemType(ctx: ?*anyopaque, stock_type: i32) u16 {
        const g: *Game = @ptrCast(@alignCast(ctx.?));
        return g.items.ecsIdFromStockType(stock_type);
    }

    /// Workstation craft output: sim item plus the name the client derives from
    pub fn buildInventorySnap(self: *Game, c: *Client, buf: []u8) ![]u8 {
        const ps = self.sim.playerByPeer(c.slot) orelse return error.NoPlayer;
        if (!self.sim.mask[ps].inventory) return error.NoInv;
        // Stock body with ItemTable stock types when items.xml is loaded.
        return packages.buildInventoryBodyStockResolved(buf, &self.sim.inventory[ps], resolveItemType, self);
    }

    fn sendItemIdMapping(self: *Game, peer: *ln_peer.Peer) !void {
        return game_join.sendItemIdMapping(self, peer);
    }

    /// Holding-only S2C (valid direction for stock clients).
    /// Join: send empty held stack (entityId + count=0 + index). Full ItemValue held
    /// stacks have underrun'd stock HoldingItem.read mid-join when framing/window is tight;
    /// PDF already carries toolbelt. Echo path after InvTx still sends resolved hold.
    fn sendHoldingOnly(self: *Game, peer: *ln_peer.Peer, c: *Client) !void {
        return game_join.sendHoldingOnly(self, peer, c);
    }

    fn sendHoldingOnlyEx(self: *Game, peer: *ln_peer.Peer, c: *Client, full_stack: bool) !void {
        return game_join.sendHoldingOnlyEx(self, peer, c, full_stack);
    }

    /// Post-change inv echo. PlayerInventory/Bag are ToServer-only for stock
    /// clients; only HoldingItem is a valid S2C echo.
    pub fn sendHoldingEcho(self: *Game, peer: *ln_peer.Peer, c: *Client) !void {
        try self.sendHoldingOnlyEx(peer, c, true);
    }

    pub fn isStorageBlockId(self: *const Game, block_id: u16) bool {
        // Prefer blocks.xml LootList/CompositeTileEntity ∩ AssignIds dump.
        if (self.maxdamage.isStorageId(block_id)) return true;
        // stock_deco pins always (dump may be absent offline).
        const d = packages.stock_deco;
        if (block_id == @as(u16, @intCast(d.cnt_wooden_chest_closed))) return true;
        if (block_id == @as(u16, @intCast(d.cnt_wooden_chest_open))) return true;
        if (block_id == @as(u16, @intCast(d.cnt_wood_writable_crate))) return true;
        if (block_id == @as(u16, @intCast(d.cnt_desk_safe))) return true;
        if (block_id == @as(u16, @intCast(d.cnt_hardened_chest_insecure))) return true;
        return false;
    }

    /// Closed↔open pair from blocks.xml DowngradeBlock (AssignIds-resolved).
    pub fn storagePairId(self: *const Game, block_id: u16) ?u16 {
        if (self.storage_pairs.toggleId(block_id)) |id| return id;
        // Offline fallback: wooden chest pins.
        const d = packages.stock_deco;
        const closed: u16 = @intCast(d.cnt_wooden_chest_closed);
        const open: u16 = @intCast(d.cnt_wooden_chest_open);
        if (block_id == closed) return open;
        if (block_id == open) return closed;
        return null;
    }

    /// Resolve a spawn-picked class name to its full entityclasses stats
    /// (HP/speeds/damage/hash/loot). Game-level because it needs the entities
    /// table and the items table for HandItem DamageEntity.
    /// EntityDef → full EntityClass (A35): the resolved stats the sim carries
    /// per entity so a class not preloaded into the fixed class_table still
    /// spawns as itself (HP/speeds/damage/hash/loot/is_enemy).
    pub fn entityClassOf(self: *Game, d: assets_entities.EntityDef) ecs.world.EntityClass {
        return .{
            .name = d.name,
            .max_hp = d.max_hp,
            .kind = d.kind,
            .hash = d.hash,
            .loot_list = d.loot_list,
            .drop_prob = d.loot_drop_prob,
            .chase_speed = d.chase_speed,
            .wander_speed = d.wander_speed,
            .attack_damage = self.handItemDamage(d.hand_item),
            .time_stay = d.time_stay,
            .sight_range = d.sight_range,
            .is_enemy = d.is_enemy,
            .xp_gain = d.xp_gain,
        };
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
    /// True when the block id is a bedroll (stock respawn bed): the classic
    /// bedroll plus the colored variants. Name-based via the runtime AssignIds
    /// dump, never a hardcoded id list.
    pub fn isBedrollId(self: *const Game, block_id: u16) bool {
        const names = [_][]const u8{
            "bedroll",      "bedrollRed",  "bedrollOrange", "bedrollYellow",
            "bedrollGreen", "bedrollBlue", "bedrollPurple", "bedrollPink",
        };
        for (names) |n| {
            if (self.maxdamage.idByName(n)) |id| {
                if (id == block_id) return true;
            }
        }
        return false;
    }

    /// True when the world biome at (wx,wz) is the stock radiated biome
    /// (biomes.xml <biomemap name="radiated"/>), which deals damage over time.
    pub fn isRadiatedAt(self: *const Game, wx: i32, wz: i32) bool {
        const bm = self.world.biomes orelse return false;
        const id = bm.atWorld(wx, wz) orelse return false;
        const name = self.world.biome_layers_table.names[id] orelse return false;
        return std.mem.find(u8, name, "radiat") != null;
    }

    pub fn biomeGroupName(ctx: ?*anyopaque, x: f32, z: f32, kind: ecs.aidirector.Director.SpawnKind, fallback: []const u8) []const u8 {
        const self: *Game = @ptrCast(@alignCast(ctx.?));
        const bm = self.world.biomes orelse return fallback;
        const biome_id = bm.atWorld(@floor(x), @floor(z)) orelse return fallback;
        const bname = self.world.biome_layers_table.nameById(biome_id) orelse return fallback;
        var buf: [16]assets_spawning.Rule = undefined;
        const n = self.spawning.rulesForBiome(bname, &buf);
        var animal_rules: [8][]const u8 = undefined;
        var animal_candidates: usize = 0;
        var ri: usize = 0;
        while (ri < n) : (ri += 1) {
            const r = buf[ri];
            switch (kind) {
                .night => if (r.kind == .zombie and r.time == .night) return r.entitygroup,
                .day => if (r.kind == .zombie and (r.time == .any or r.time == .day)) return r.entitygroup,
                .animal => {
                    // Stock per biome has multiple animal rules: day Any
                    // (WildGameForest), Night wildlife (WildGameForestNight),
                    // and Night enemy (EnemyAnimalsForest: snake, boar, wolf,
                    // bear). Rotate across the matching rules by the spawn
                    // counter so predators actually appear at night instead of
                    // always picking the first Night rule.
                    if (r.kind != .animal) continue;
                    const night = self.sim.director.clock.isNight();
                    const matches_night = r.time == .night and night;
                    const matches_day = (r.time == .any or r.time == .day) and !night;
                    if (!matches_night and !matches_day) continue;
                    if (animal_candidates < animal_rules.len) {
                        animal_rules[animal_candidates] = r.entitygroup;
                        animal_candidates += 1;
                    }
                },
            }
        }
        if (kind == .animal and animal_candidates > 0) {
            // Rotate deterministically by the director spawn counter so the
            // mix of passive and enemy wildlife varies per spawn.
            const pick = self.sim.director.total_spawned % animal_candidates;
            return animal_rules[pick];
        }
        return fallback;
    }

    /// gamestages.xml spawner ladder → the stage's first <spawn> row.
    pub fn pickStageGroup(ctx: ?*anyopaque, spawner: []const u8, stage: i32) ?ecs.aidirector.StageGroup {
        const g: *Game = @ptrCast(@alignCast(ctx.?));
        const sp = g.gamestages.spawnerByName(spawner) orelse return null;
        const st = sp.getStage(stage) orelse return null;
        const sg = st.spawnGroup(0) orelse return null;
        return .{ .group = sg.group, .num = sg.num, .max_alive = sg.max_alive };
    }

    /// spawning.xml <entityspawner name=…> → its EntityGroupName property.
    pub fn pickSpawnerGroup(ctx: ?*anyopaque, spawner: []const u8) ?[]const u8 {
        const g: *Game = @ptrCast(@alignCast(ctx.?));
        const s = g.spawning.spawnerByName(spawner) orelse return null;
        return s.entitygroup;
    }

    /// Craft recipe by index into recipes.defs (InvTx craft op). Consumes ingredients, grants output.
    pub fn tryCraft(self: *Game, peer_slot: usize, recipe_index: u16, times: u16) bool {
        return game_craft.tryCraft(self, peer_slot, recipe_index, times);
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

    /// One workstation step: burn/craft, then re-broadcast the stations it changed.
    pub fn tickWorkstations(self: *Game, dt: f32) !void {
        return game_craft.tickWorkstations(self, dt);
    }

    /// BlockRadiusEffect: burning workstations (campfire, burning barrel)
    /// grant their ActiveRadiusEffects buff to nearby players.
    pub fn tickBlockRadiusEffects(self: *Game) void {
        return game_craft.tickBlockRadiusEffects(self);
    }

    pub fn ecsIdFromItemName(self: *Game, name: []const u8) u16 {
        return game_loot.ecsIdFromItemName(self, name);
    }

    pub fn fillLootBagFromTable(self: *Game, bag_net_id: i32, loot_list: []const u8, seed: u32, loot_stage: i32) void {
        game_loot.fillLootBagFromTable(self, bag_net_id, loot_list, seed, loot_stage);
    }

    /// Wake prefab sleeper volumes near players; spawn class groups once.
    /// Push the background flusher's atomic totals into apm counters as
    /// per-tick deltas. `world` cannot import `apm` (src/world/root.zig), so the
    /// tick thread samples instead.
    pub fn sampleFlushCounters(self: *Game) void {
        const f = &self.world.flush;
        const q = f.queued.load(.monotonic);
        const w = f.written.load(.monotonic);
        const e = f.errors.load(.monotonic);
        const s = self.world.sync_fallbacks.load(.monotonic);
        const wt = f.waits.load(.monotonic);
        self.harness.counters.add(.chunk_flush_queued, q -| self.flush_seen.queued);
        self.harness.counters.add(.chunk_flush_written, w -| self.flush_seen.written);
        self.harness.counters.add(.chunk_flush_errors, e -| self.flush_seen.errors);
        self.harness.counters.add(.chunk_flush_sync, s -| self.flush_seen.sync);
        self.harness.counters.add(.chunk_flush_waits, wt -| self.flush_seen.waits);
        // Async writes fail off-tick, so persistence_errors would otherwise
        // never see them (saveAll returns before the write happens).
        self.harness.counters.add(.persistence_errors, e -| self.flush_seen.errors);
        self.flush_seen = .{ .queued = q, .written = w, .errors = e, .sync = s, .waits = wt };
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
        if (stage_spawn) |sg| {
            if (self.entitygroups.pick(sg.group, seed)) |cname| {
                if (self.entities.byName(cname)) |d| return d;
            }
        }
        if (self.entities.byName(name)) |d| return d;
        if (self.entitygroups.pick(name, seed)) |cname| {
            if (self.entities.byName(cname)) |d| return d;
        }
        return self.entities.defaultZombie();
    }

    pub fn broadcastLootSpawn(self: *Game, net_id: i32) !void {
        try game_loot.broadcastLootSpawn(self, net_id);
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

    pub fn fillContainerFromLoot(self: *Game, cont: *containers_mod.Container, loot_name: []const u8, seed: u32) void {
        game_chunk_fill.fillContainerFromLoot(self, cont, loot_name, seed);
    }

    /// LootRespawnDays (stock TEFeatureStorage.UpdateTick): a looted world
    /// container re-rolls its contents when the interval since the touch day
    /// has elapsed (game/chunk_fill.zig).
    pub fn maybeRespawnContainer(self: *Game, cont: *containers_mod.Container) void {
        game_chunk_fill.maybeRespawnContainer(self, cont);
    }

    pub fn sendContainersInChunk(self: *Game, peer: *ln_peer.Peer, cx: i32, cz: i32) !void {
        return game_chunk_stream.sendContainersInChunk(self, peer, cx, cz);
    }

    pub fn sendSpawnArea(self: *Game, peer: *ln_peer.Peer, wx: i32, wz: i32, radius: i32) !void {
        return game_chunk_stream.sendSpawnArea(self, peer, wx, wz, radius);
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

    fn sendBuffSync(self: *Game, peer: *ln_peer.Peer, c: *const Client) !void {
        return game_social.sendBuffSync(self, peer, c);
    }

    fn playerBuffBlob(self: *Game, peer_slot: usize, buf: []u8) []const u8 {
        return game_social.playerBuffBlob(self, peer_slot, buf);
    }

    fn relayBuff(self: *Game, entity_id: i32, buff_name: []const u8, adding: bool, instigator_id: i32, except_slot: ?usize) !void {
        return game_social.relayBuff(self, entity_id, buff_name, adding, instigator_id, except_slot);
    }

    pub fn broadcastBuffExpiries(self: *Game, r: *const ecs.TickResult) !void {
        return game_social.broadcastBuffExpiries(self, r);
    }

    pub fn replicate(self: *Game) !void {
        return game_replicate.replicate(self);
    }

    pub fn clearDeadKnownEntities(self: *Game) void {
        return game_tick.clearDeadKnownEntities(self);
    }

    pub fn step(self: *Game) !void {
        return @import("game/step.zig").step(self);
    }

    fn anyEnteredClient(self: *const Game) bool {
        return game_weather.anyEnteredClient(self);
    }

    /// Build NetPackageWeather from the live weather state machine (omit if none).
    pub fn buildWeatherBodyFromBiomes(self: *Game) ?[]const u8 {
        return game_weather.buildWeatherBodyFromBiomes(self);
    }

    fn sendWeather(self: *Game, peer: *ln_peer.Peer) !void {
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
    fn sendSeatedRiders(self: *Game, peer: *ln_peer.Peer) !void {
        try game_vehicle.sendSeatedRiders(self, peer);
    }

    pub fn broadcastVehiclePositions(self: *Game) !void {
        try game_vehicle.broadcastVehiclePositions(self);
    }

    pub fn broadcastTurretSync(self: *Game) !void {
        try game_vehicle.broadcastTurretSync(self);
    }

    pub fn run(self: *Game) !void {
        const tick_ns: u64 = protocol.tick_ns;
        var next_t = clock.monoNs() + tick_ns;
        while (self.running) {
            try self.step();
            // Snapshot after step returns (step stack unwound; avoids overflow).
            self.fillWebuiSnap();
            const now = clock.monoNs();
            if (next_t > now) {
                clock.sleepNs(next_t - now);
            } else if (now > next_t) {
                // Fell behind the 50 ms budget: count for apm; rate-limit log.
                self.harness.counters.inc(.tick_overruns);
                // Availability valve: hold weak evidence + deferrable broadcasts
                // for 2 s. Chunk streaming, motion replicate, WorldTime and every
                // Hard gate keep running.
                if (self.guard.load_shed) self.shed_until_tick = self.tick_n + self.guard.shed_hold_ticks;
                const overruns = self.harness.counters.get(.tick_overruns);
                if (overruns == 1 or overruns % 100 == 0) {
                    const late_us = (now -% next_t) / 1000;
                    var ts: [19]u8 = undefined;
                    std.debug.print(
                        "zdtd: {s} tick overrun n={d} late_us={d} (budget={d}us)\n",
                        .{ clock.wallStamp(&ts), overruns, late_us, tick_ns / 1000 },
                    );
                }
            }
            next_t += tick_ns;
            if (next_t < clock.monoNs()) next_t = clock.monoNs() + tick_ns;
        }
        try self.world.saveAll();
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

    pub fn replicateNow(self: *Game) !void {
        return @import("game/harness.zig").replicateNow(self);
    }

    pub fn handlePartyActions(self: *Game, c: *Client, body: []const u8) !void {
        return @import("game/harness.zig").handlePartyActions(self, c, body);
    }

    pub fn acceptQuestFor(self: *Game, c: *Client, def_id: u16) bool {
        return @import("game/harness.zig").acceptQuestFor(self, c, def_id);
    }

    pub fn handleAllyRequest(self: *Game, c: *Client, body: []const u8) !void {
        return @import("game/harness.zig").handleAllyRequest(self, c, body);
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

    fn shareQuestWithParty(self: *Game, c: *Client, def_id: u16) void {
        return @import("game/social.zig").shareQuestWithParty(self, c, def_id);
    }
};
