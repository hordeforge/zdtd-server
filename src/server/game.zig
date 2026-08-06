//! Game server: join SM, tick, interest, combat, persistence.
//! Simulation is an SoA ECS (`ecs.World` + systems).

const std = @import("std");
const version = @import("../version.zig");
const apm = @import("../apm/root.zig");
const clock = @import("../util/clock.zig");
const ln_server = @import("../litenet/server.zig");
const ln_peer = @import("../litenet/peer.zig");
const wire_frame = @import("../wire/frame.zig");
const wire_binary = @import("../wire/binary.zig");
const packages = @import("../wire/packages.zig");
const world_store = @import("../world/store.zig");
const deco_mirror = @import("../world/deco_mirror.zig");
const ecs = @import("../ecs/root.zig");
const systems = @import("../ecs/systems.zig");
const parallel_util = @import("../util/parallel.zig");
const rng_util = @import("../util/rng.zig");
const protocol = @import("../protocol.zig");
const assets_quests = @import("../assets/quests.zig");
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
const assets_biome_layers = @import("../assets/biome_layers.zig");
const assets_block_textures = @import("../assets/block_textures.zig");
const assets_painting = @import("../assets/painting.zig");
const assets_spawning = @import("../assets/spawning.zig");
const assets_buffs = @import("../assets/buffs.zig");
const assets_progression = @import("../assets/progression.zig");
const assets_vehicles = @import("../assets/vehicles.zig");
const assets_storage_pairs = @import("../assets/storage_pairs.zig");
const biomes_mod = @import("../world/biomes.zig");
const world_weather = @import("../world/weather.zig");
const terrain_snapshot = @import("../world/terrain_snapshot.zig");
const jobs = @import("../ecs/jobs.zig");
const interest = @import("../ecs/interest.zig");
const invsys = @import("../ecs/inventory.zig");
const admin_mod = @import("admin.zig");
const admin_cmds = @import("admin_cmds.zig");
const webui_mod = @import("webui.zig");
const serverinfo_tcp = @import("serverinfo_tcp.zig");
const containers_mod = @import("../world/containers.zig");
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

const max_clients = ln_server.max_peers;
const max_land_claims: usize = 256;
/// Quest.PositionData entries the server ever writes: Location + POIPosition + POISize.
const max_quest_position_data: usize = 3;
const apm_report_period_ticks: u64 = protocol.ticks_per_second * 60;

/// `help` index. Stock names and descriptions where the verb exists in stock
/// (ConsoleCmdHelp, asm.il 226623); zdtd-only verbs are marked so an operator can
/// tell parity from extension at a glance.
const admin_help_index = [_]admin_cmds.HelpEntry{
    .{ .names = "admin", .description = "Manage user permission levels" },
    .{ .names = "apm, metrics", .description = "zdtd: server APM counters and section latency" },
    .{ .names = "ban", .description = "Manage ban entries" },
    .{ .names = "chunkcache, cc", .description = "Display cached chunks" },
    .{ .names = "evidence, ev", .description = "zdtd: recent authority reject evidence ring" },
    .{ .names = "getgamepref, gg", .description = "Gets game preferences" },
    .{ .names = "gettime, gt", .description = "Get the current game time" },
    .{ .names = "give", .description = "zdtd: drop an item stack at a player's feet" },
    .{ .names = "guardclear, gc", .description = "zdtd: clear guard quarantine on a peer slot" },
    .{ .names = "guardstats, gs", .description = "zdtd: C2S authority reject counters" },
    .{ .names = "help", .description = "Help on console and specific commands" },
    .{ .names = "inv", .description = "zdtd: dump a joined peer's inventory slots" },
    .{ .names = "kick", .description = "Kicks user with optional reason" },
    .{ .names = "kickall", .description = "Kicks all users with optional reason" },
    .{ .names = "kill", .description = "Kill an entity by id" },
    .{ .names = "killall, ka", .description = "Kill all AI entities" },
    .{ .names = "listents, le", .description = "lists all entities" },
    .{ .names = "listplayerids, lpi", .description = "Lists all players with their IDs for ingame commands" },
    .{ .names = "listplayers, lp", .description = "lists all players" },
    .{ .names = "mem", .description = "Prints memory information" },
    .{ .names = "save", .description = "zdtd: save player records" },
    .{ .names = "saveworld, sa", .description = "Saves the world manually" },
    .{ .names = "say", .description = "Sends a message to all connected clients" },
    .{ .names = "setgamepref, sg", .description = "Sets a game pref" },
    .{ .names = "settime, st", .description = "Set the current game time" },
    .{ .names = "shutdown", .description = "shuts down the game server" },
    .{ .names = "spawnentity, se", .description = "spawns an entity" },
    .{ .names = "status", .description = "zdtd: one-line load and error counters" },
    .{ .names = "tele, tp", .description = "zdtd: teleport a player (stock tp is client-only)" },
    .{ .names = "unban", .description = "zdtd: drop a raw IPv4 ban" },
    .{ .names = "version", .description = "Get the currently running version" },
    .{ .names = "whitelist", .description = "Manage whitelist entries" },
    .{ .names = "wipeplayer", .description = "zdtd: erase a player record by login name" },
};

/// Persist failures are non-fatal but never silent: lost world/player/container
/// state must show up in the server log. Counter always increments; log is
/// rate-limited (first + every 100th) so a full disk does not flood stderr
/// every save period while still leaving an audit trail.
fn logPersistErr(self: *Game, what: []const u8, err: anyerror) void {
    self.harness.counters.inc(.persistence_errors);
    const n = self.harness.counters.get(.persistence_errors);
    if (n == 1 or n % 100 == 0) {
        std.debug.print("zdtd: {s} failed: {s} n={d}\n", .{ what, @errorName(err), n });
    }
}

/// Result of dropping named records from a ZPV2 players.zsv blob.
/// `blob` is null when nothing was removed (caller keeps the original file).
const Zpv2Drop = struct {
    blob: ?[]u8 = null,
    removed: u32 = 0,
};

/// Pure ZPV2 rewrite: omit records whose name equals `name`. Allocates only when
/// at least one record is dropped. Caller owns `blob` when non-null.
fn zpv2DropName(allocator: std.mem.Allocator, data: []const u8, name: []const u8) !Zpv2Drop {
    if (name.len == 0 or name.len > 32) return .{};
    if (data.len < 8 or !std.mem.eql(u8, data[0..4], "ZPV2")) return error.CorruptPlayersFile;
    const n = std.mem.readInt(u32, data[4..8], .little);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, &[_]u8{ 'Z', 'P', 'V', '2', 0, 0, 0, 0 });
    var written: u32 = 0;
    var removed: u32 = 0;
    var off: usize = 8;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const rec_start = off;
        if (off >= data.len) return error.CorruptPlayersFile;
        const nl: usize = data[off];
        if (nl > 32 or off + 1 + nl + 16 + 1 > data.len) return error.CorruptPlayersFile;
        const rec_name = data[off + 1 ..][0..nl];
        off += 1 + nl + 16;
        const inv_n: usize = data[off];
        off += 1 + inv_n * 7;
        if (off >= data.len) return error.CorruptPlayersFile;
        const jn: usize = data[off];
        off += 1 + jn * 10;
        if (off > data.len) return error.CorruptPlayersFile;
        if (nl == name.len and std.mem.eql(u8, rec_name, name)) {
            removed += 1;
            continue;
        }
        try out.appendSlice(allocator, data[rec_start..off]);
        written += 1;
    }
    if (removed == 0) {
        out.deinit(allocator);
        return .{};
    }
    std.mem.writeInt(u32, out.items[4..][0..4], written, .little);
    return .{ .blob = try out.toOwnedSlice(allocator), .removed = removed };
}

pub const AuthorityMode = server_config.AuthorityMode;

/// Placeholder trader wallet (stock AvailableMoney is a per-day dukes pool that
/// regenerates and is spent on player sells). zdtd has no trader economy: trade()
/// credits the player wallet directly, so this is a fixed non-derived display value.
const trader_wallet_dukes: i32 = 5000;

pub const InitOptions = struct {
    map_dir: ?[]const u8 = null,
    game_dir: ?[]const u8 = null,
    config_dir: ?[]const u8 = null,
    /// Xpath patch dirs (filename order). Applied after base Data/Config load.
    config_overrides: []const []const u8 = &.{},
    quests_path: ?[]const u8 = null,
    view_radius: i32 = default_view_radius,
    admin_port: u16 = 0,
    /// TelnetPassword. Empty keeps the console on loopback with no login prompt;
    /// non-empty enables the stock login and the INADDR_ANY bind.
    telnet_password: []const u8 = "",
    telnet_failed_login_limit: u8 = 10,
    /// GameWorld, shown in the telnet greeting block.
    game_world: []const u8 = "Navezgane",
    /// Operator web UI (docs/WEBUI.md). 0 = disabled. Requires webui_secret.
    webui_port: u16 = 0,
    webui_bind: []const u8 = "127.0.0.1",
    webui_secret: []const u8 = "",
    world_name: ?[]const u8 = null,
    /// ServerMaxPlayerCount from serverconfig (capped at LiteNet max_peers).
    max_players: u16 = default_max_players,
    /// ServerPassword from serverconfig. Used as the LiteNet Connect key: non-empty
    /// rejects Connect requests whose key does not match.
    password: []const u8 = "",
    /// Stream NetPackageChunk on join/tick. Default on: stock clients need server chunks
    /// (no client-side generation workarounds). Loadgen can still parse stock bodies.
    wire_chunks: bool = true,
    /// Send deco tree objects in the join DecoUpdate burst. Off = stock-safe empty
    /// firstPackage (bald world). Kill switch for a modded / other-version client
    /// whose AssignIds ids differ from our bundled dump: a mismatched block id
    /// throws inside the client world-load coroutine, not just missing trees.
    deco_trees: bool = true,
    /// Mirror the join deco burst into the server block store, so collision and
    /// harvest agree with what the client renders. Off = deco is render-only.
    deco_mirror: bool = true,
    /// Negotiate block ids with the client by sending a "blocks" NameIdMapping
    /// before the config files, instead of trusting the client's local
    /// blocks.xml to assign the same ids as our bundled AssignIds dump.
    /// Off = today's behaviour (client assigns locally, server hopes it matches).
    block_id_mapping: bool = true,

    // Gameplay options (stock serverconfig.xml defaults). Applied to the sim below.
    game_difficulty: u8 = 2,
    blood_moon_frequency: u8 = 7,
    blood_moon_enemy_count: u8 = 8,
    blood_moon_range: u8 = 0,
    player_killing_mode: u8 = 3,
    day_night_length: u16 = 60,
    day_light_length: u8 = 18,
    max_spawned_zombies: u16 = 64,
    zombie_move: u8 = 0,
    zombie_move_night: u8 = 3,
    zombie_feral_move: u8 = 3,
    zombie_bm_move: u8 = 3,
    enemy_difficulty: u8 = 0,
    loot_abundance: u16 = 100,
    xp_multiplier: u16 = 100,
    block_damage_player: u16 = 100,
    block_damage_ai: u16 = 100,
    block_damage_ai_bm: u16 = 100,
    max_spawned_animals: u16 = 50,
    air_drop_frequency: u16 = 72,
    drop_on_death: u8 = 1,
    land_claim_size: u16 = 41,
    land_claim_online_durability_modifier: u16 = 4,
    land_claim_offline_durability_modifier: u16 = 4,
    /// When set, enables procedural terrain (terrain_source=proc). Ignored if map_dir loads.
    worldgen_seed: ?u64 = null,
    /// Authority mode. Default correct (hard rejects on). See docs/AUTHORITY.md.
    authority_mode: AuthorityMode = .correct,
    /// P4 guard policy switches (zdtd.toml [authority] guard_*). Log-only default.
    guard: guard_policy.Policy = .{},

    // zdtd stream/authority tunables (Bucket B). Single source: default_* below.
    // Full file surface (zdtd.toml) still open; fields are the single source for hot path.
    max_streamed_chunks: usize = default_max_streamed_chunks,
    chunk_stream_radius_min: i32 = default_chunk_stream_radius_min,
    chunk_stream_radius_max: i32 = default_chunk_stream_radius_max,
    chunk_adds_per_stream_tick: u32 = default_chunk_adds_per_stream_tick,
    chunk_stream_period_ticks: u64 = default_chunk_stream_period_ticks,
    motion_replicate_period_ticks: u64 = default_motion_replicate_period_ticks,
    spawn_area_radius_max: i32 = default_spawn_area_radius_max,
    max_claimed_damage: i32 = default_max_claimed_damage,
    max_edit_range: f32 = default_max_edit_range,
    interest_range: f32 = default_interest_range,
    peer_stale_ms: u64 = default_peer_stale_ms,
    /// Register in-tree sample_hello static plugin (logs once on enable).
    enable_sample_plugin: bool = true,

    // [perf] switches (zdtd.toml). All default off; each is gated on apm
    // evidence from the always-on sections/counters that ship with them.
    /// Write chunk saves from a background thread (encode stays on the tick).
    async_chunk_flush: bool = false,
    /// Per-tick read-only terrain blocked snapshot for the A* inner loop.
    terrain_snapshot: bool = false,
    /// Run the sleeper-volume player test as a parallel job batch.
    job_batches: bool = false,
};

// Compile-time array bound for Client.streamed (must cover max config).
const max_streamed_chunks_cap: usize = 169;
/// Default stream/authority values (also InitOptions / Game field defaults).
pub const default_max_streamed_chunks: usize = max_streamed_chunks_cap;
pub const default_chunk_stream_radius_min: i32 = 7;
pub const default_chunk_stream_radius_max: i32 = 9;
pub const default_chunk_adds_per_stream_tick: u32 = 8;
pub const default_chunk_stream_period_ticks: u64 = 5;
pub const default_motion_replicate_period_ticks: u64 = 2;
pub const default_spawn_area_radius_max: i32 = 8;
pub const default_max_claimed_damage: i32 = 200;
pub const default_max_edit_range: f32 = 96;
pub const default_interest_range: f32 = 160;
/// Max UTF-8 bytes in a player Global chat message (canonical: c2s_text).
pub const max_chat_msg_len: usize = c2s_text.max_chat_msg_len;
/// Minimum gap between accepted chat broadcasts from one peer (mono ns).
pub const min_chat_gap_ns: u64 = 200_000_000;
/// Inv/block token buckets: capacity and refill period (mono ns).
pub const inv_bucket_cap: u8 = 40;
pub const inv_refill_ns: u64 = 50_000_000; // +1 token / 50 ms
pub const block_bucket_cap: u8 = 30;
pub const block_refill_ns: u64 = 33_000_000; // +1 / ~33 ms
/// Min gap between DamageEntity accepts (mono ns); burst allows short combos.
pub const min_damage_gap_ns: u64 = 80_000_000;
pub const damage_burst_max: u8 = 4;
pub const default_peer_stale_ms: u64 = 3000;
pub const default_view_radius: i32 = 7;
pub const default_max_players: u16 = 8;
/// Scratch for serialize-once framed packets (PosAndRot ~40 B body + frame hdr).
const replicate_frame_cap: usize = 256;
/// Speeds body offset inside body_buf during zombie motion encode.
const speeds_body_off: usize = 64;
/// AliveFlags body offset (after speeds).
const flags_body_off: usize = 96;

const eqAny = c2s_text.eqAny;
const sanitizePlayerName = c2s_text.sanitizePlayerName;
const chatMsgOk = c2s_text.chatMsgOk;
const isPlayerConsoleCommand = c2s_text.isPlayerConsoleCommand;

/// Ceiling on DecoObjects one join burst may place. The count is data driven now
/// (biomes.xml probabilities), so a modded biome file with dense distant-deco
/// entries must not turn the join into hundreds of packages.
const deco_objects_per_join: usize = 8192;

/// A placed land-claim block: protects blocks within land_claim_size around the
/// keystone for its owner. Owner is the player entity id that placed it.
const LandClaim = struct {
    x: i32,
    y: i32,
    z: i32,
    owner_entity: i32,
    owner_online: bool = true,
};

const Client = struct {
    peer: ?*ln_peer.Peer = null,
    entity_id: i32 = -1,
    /// Server-side XP ledger (XPMultiplier applied on award).
    xp: u64 = 0,
    /// Player level derived from progression curve (1-based).
    level: u16 = 1,
    /// EntityPlayer::gameStageBornAtWorldTime: world time the current survival
    /// streak started. Seeded to "now" on join and pushed forward on death
    /// (asm.il SetAlive ~503838). Client state is per-session, so days survived
    /// restarts at zero on reconnect until player persistence lands.
    game_stage_born_world_time: u64 = 0,
    authed_challenge: bool = false,
    joined: bool = false,
    /// True after sendJoinBundle (WorldInfo/PlayerId). Gate tick broadcasts until then.
    entered: bool = false,
    /// Client's ChunkCache exists (it sent WorldInitInfoRequest, which
    /// worldInfoCo only does after createWorld). Chunks sent from here on
    /// are kept, so the tick streamer can start well before the spawn.
    world_ready: bool = false,
    challenge: [16]u8 = .{0} ** 16,
    slot: usize = 0,
    view_radius: i32 = default_view_radius,
    name: [32]u8 = .{0} ** 32,
    name_len: usize = 0,
    /// Chunk keys currently known streamed to this client (WorldChunkCache keys).
    streamed: [max_streamed_chunks_cap]i64 = undefined,
    streamed_n: usize = 0,
    /// Entity slots this client has received an ECD EntitySpawn for
    /// (spawn-on-approach; cleared when the entity dies or slot recycles).
    known_entities: std.StaticBitSet(ecs.max_entities) = std.StaticBitSet(ecs.max_entities).initEmpty(),
    /// Game payload arrived before challenge echo (stock/loadgen can race). Replay after auth.
    preauth_buf: [512]u8 = undefined,
    preauth_len: usize = 0,
    /// Last movement-envelope sample (horizontal speed gate).
    move_valid: bool = false,
    move_x: f32 = 0,
    move_y: f32 = 0,
    move_z: f32 = 0,
    move_tick: u64 = 0,
    /// Running total of eatable units last seen (cross-package stack-loss).
    last_eatable_units: u32 = 0,
    /// Once: soft warn when streamed_n crosses ~80% of max_streamed_chunks.
    stream_cap_warned: bool = false,
    /// Last accepted chat broadcast (mono ns); flood throttle for Global chat.
    last_chat_ns: u64 = 0,
    /// Cost-class token buckets (refill on accept path).
    inv_tokens: u8 = inv_bucket_cap,
    inv_refill_ns: u64 = 0,
    block_tokens: u8 = block_bucket_cap,
    block_refill_ns: u64 = 0,
    /// Combat ledger: last DamageEntity mono ns + short burst count.
    last_damage_ns: u64 = 0,
    damage_burst: u8 = 0,
    /// P4 guard policy state (windowed detector counts, quarantine bits, kick
    /// arm tick). Cleared for free by `clients[slot] = .{}` on kick/disconnect.
    guard: guard_policy.PeerState = .{},
    /// Weak block-destroy-rate signal: window start tick + destroys in window.
    farm_window_tick: u64 = 0,
    farm_breaks: u16 = 0,
    /// Platform identities from NetPackagePlayerLogin. `primary` is stock's
    /// ClientInfo.InternalId (crossplatform when present, else native, asm.il
    /// 783909) and is what PersistentPlayerData and the ally store key on.
    /// Absent on both is a legitimate state, not an error: a client with no
    /// platform session, and zdtd's own loadgen bots, send null identifiers.
    /// Cleared for free by `clients[slot] = .{}` on kick/disconnect.
    puid_primary: platform_user.Stored = .{},
    puid_native: platform_user.Stored = .{},
};

pub const Game = struct {
    allocator: std.mem.Allocator,
    net: ln_server.Server = .{},
    world: world_store.World,
    /// Entity-component-system sim world.
    sim: ecs.World = .{},
    /// Static native plugin host (ADR 0005 skeleton; no dynlib).
    plugins: plugin_mod.PluginHost = .{},
    clients: [max_clients]Client = [_]Client{.{}} ** max_clients,
    harness: apm.Harness = .{},
    /// P4 observe ring (admin `evidence` dumps JSONL lines).
    evidence: evidence_mod.Ring = .{},
    /// P4 guard policy switches (zdtd.toml [authority]). Default log-only.
    guard: guard_policy.Policy = .{},
    /// Ally relationships keyed on platform identity (stock AllyStore).
    /// In-memory only: stock persists these, zdtd does not yet.
    allies: ally_mod.Store = .{},
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
    /// Active land claims: owner peer-persistent id keyed by claim block position.
    land_claims: [max_land_claims]LandClaim = undefined,
    land_claims_n: usize = 0,
    /// Air drop scheduling: next drop at this world-hour (0 disables).
    air_drop_interval_hours: u16 = 72,
    next_air_drop_hour: u64 = 0,
    /// Authority mode (observe = counters only; correct = hard reject). docs/AUTHORITY.md.
    authority_mode: AuthorityMode = .correct,
    blocks: assets_blocks.BlockTable = assets_blocks.BlockTable.builtin(),
    items: assets_items.ItemTable = assets_items.ItemTable.builtin(),
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
    sleepers: sleepers_mod.Store = sleepers_mod.Store.empty(),
    containers: containers_mod.ContainerStore = .{},
    workstations: workstations_mod.WorkstationStore = .{},
    /// Lock table: channel → holder peer slot (-1 free).
    lock_channel: [16]i32 = .{-1} ** 16,
    lock_holder_entity: [16]i32 = .{-1} ** 16,
    /// When the lock was granted (mono ns); 0 = free. Stale holders auto-release.
    lock_granted_ns: [16]u64 = .{0} ** 16,
    /// Position key for the locked TE (packed xyz); 0 = channel-only lock.
    lock_pos_key: [16]u64 = .{0} ** 16,
    /// Per-IP join throttle (ms since epoch-ish via monoNs/1e6).
    join_ip: [16]u32 = .{0} ** 16,
    join_ip_ms: [16]u64 = .{0} ** 16,
    join_ip_n: usize = 0,
    ban_ip: [32]u32 = .{0} ** 32,
    ban_n: usize = 0,
    /// Sparse block durability: absolute BlockValue.damage at (x,y,z).
    block_hp_key: [64]u64 = .{0} ** 64,
    block_hp: [64]u16 = .{0} ** 64,
    block_hp_n: usize = 0,
    /// Sparse BlockValue.rawData (rotation/meta bits) for door/shape fidelity.
    block_raw_key: [128]u64 = .{0} ** 128,
    block_raw: [128]u32 = .{0} ** 128,
    block_raw_n: usize = 0,
    view_radius: i32 = default_view_radius,
    /// Advertised + soft join cap (ServerMaxPlayerCount); ≤ max_clients.
    max_players: u16 = default_max_players,
    world_name: []const u8 = "zdtd",
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
    spawn_area_radius_max: i32 = default_spawn_area_radius_max,
    max_claimed_damage: i32 = default_max_claimed_damage,
    max_edit_range: f32 = default_max_edit_range,
    interest_range: f32 = default_interest_range,
    peer_stale_ms: u64 = default_peer_stale_ms,

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
            .spawn_area_radius_max = opts.spawn_area_radius_max,
            .max_claimed_damage = opts.max_claimed_damage,
            .max_edit_range = opts.max_edit_range,
            .interest_range = opts.interest_range,
            .peer_stale_ms = opts.peer_stale_ms,
            .plugins = .{ .sample_enabled = opts.enable_sample_plugin },
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
        errdefer {
            // Network half first so fail-closed webui (after net/admin listen)
            // does not leak FDs in tests/library createWithOptions paths.
            self.webui.deinit();
            self.admin.deinit();
            self.info_tcp.stop();
            self.net.deinit();
            self.sim.deinit();
            self.blocks.deinit();
            self.items.deinit();
            self.signs.deinit();
            self.entities.deinit();
            self.recipes.deinit();
            self.loot.deinit();
            self.entitygroups.deinit();
            self.gamestages.deinit();
            self.maxdamage.deinit();
            self.block_textures.deinit();
            self.painting.deinit();
            self.spawning.deinit();
            self.buffs.deinit();
            self.progression_table.deinit();
            self.vehicles.deinit();
            self.storage_pairs.deinit();
            self.biome_colors.deinit();
            self.traders.deinit();
            self.sleepers.deinit();
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
        }

        const assets_paths = @import("../assets/paths.zig");
        assets_paths.setOverrideDirs(opts.config_overrides);
        if (opts.config_overrides.len > 0) {
            std.debug.print("zdtd: config overrides dirs={d}\n", .{opts.config_overrides.len});
        }
        if (assets_quests.tryLoad(allocator, opts.game_dir, opts.map_dir, opts.config_dir, opts.quests_path) catch null) |cat| {
            self.sim.setCatalog(cat);
        }
        // AssignIds + blocks.xml properties first so later catalogs can resolve ids.
        if (assets_maxdamage.tryLoad(allocator, opts.game_dir, opts.config_dir) catch null) |md| {
            self.maxdamage.deinit();
            self.maxdamage = md;
            self.maxdamage.tryMergeBundledAssignIds(allocator);
            self.maxdamage.resolveMaterialMaxDamage(allocator) catch |err| {
                std.debug.print("zdtd: resolveMaterialMaxDamage failed: {s}\n", .{@errorName(err)});
            };
            if (self.world.prefabs) |*pf| {
                if (pf.prefabs_root.len > 0) {
                    var nim_path: [2048]u8 = undefined;
                    if (std.fmt.bufPrint(&nim_path, "{s}/POIs/abandoned_house_01.blocks.nim", .{pf.prefabs_root})) |p| {
                        self.maxdamage.mergeNim(allocator, p) catch |err| {
                            std.debug.print("zdtd: mergeNim {s} failed: {s}\n", .{ p, @errorName(err) });
                        };
                    } else |_| {}
                }
            }
            std.debug.print("zdtd: maxdamage names={d} ids={d} assignids={d} storage={d}\n", .{
                self.maxdamage.by_name.count(),
                self.maxdamage.by_id.count(),
                self.maxdamage.id_by_name.count(),
                self.maxdamage.storage_ids.count(),
            });
        } else {
            self.maxdamage.tryMergeBundledAssignIds(allocator);
            std.debug.print("zdtd: assignids-only names={d}\n", .{self.maxdamage.id_by_name.count()});
        }
        // A05: live terrain type ids from AssignIds (World.terrain_ids; pins remain offline defaults).
        {
            const TerrCtx = struct {
                t: *const assets_maxdamage.Table,
                fn lookup(ctx: ?*anyopaque, name: []const u8) ?u16 {
                    const self_t: *const @This() = @ptrCast(@alignCast(ctx.?));
                    return self_t.t.idByName(name);
                }
            };
            var terr_ctx: TerrCtx = .{ .t = &self.maxdamage };
            self.world.resolveTerrainIds(TerrCtx.lookup, &terr_ctx);
        }
        // Prefab `.tts` type ids are indices into each POI's own
        // `<name>.blocks.nim`, not runtime block ids; remap them by name the way
        // stock does at Prefab::loadIdMapping (asm.il:928850). Installed before
        // the first chunk is generated so no POI is stamped with local ids.
        if (self.world.prefabs) |*pf| {
            const NimCtx = struct {
                fn lookup(ctx: ?*anyopaque, name: []const u8) ?u16 {
                    const t: *const assets_maxdamage.Table = @ptrCast(@alignCast(ctx.?));
                    return t.idByName(name);
                }
            };
            if (self.maxdamage.id_by_name.count() > 0) {
                pf.setIdLookup(.{ .ctx = &self.maxdamage, .lookup = NimCtx.lookup });
            } else {
                std.debug.print("zdtd: warn: no AssignIds table, POI block ids stay prefab-local\n", .{});
            }
        }
        {
            const IdCtx = struct {
                t: *const assets_maxdamage.Table,
                fn lookup(ctx: ?*anyopaque, name: []const u8) ?u16 {
                    const self_t: *const @This() = @ptrCast(@alignCast(ctx.?));
                    return self_t.t.idByName(name);
                }
            };
            var id_ctx: IdCtx = .{ .t = &self.maxdamage };
            if (assets_blocks.tryLoad(allocator, opts.game_dir, opts.config_dir, IdCtx.lookup, &id_ctx) catch null) |bt| {
                self.blocks.deinit();
                self.blocks = bt;
                std.debug.print("zdtd: blocks defs={d}\n", .{self.blocks.defs.len});
            }
        }
        if (assets_items.tryLoad(allocator, opts.game_dir, opts.config_dir) catch null) |it| {
            self.items.deinit();
            self.items = it;
            std.debug.print("zdtd: items source={s} defs={d} stock_names={d}\n", .{
                @tagName(self.items.source), self.items.defs.len, self.items.stock_names.len,
            });
            if (self.items.byStockName("foodCanChili")) |st| {
                const eid = self.items.ecsIdFromStockType(st);
                std.debug.print("zdtd: foodCanChili stock={d} ecs={d} isEat={}\n", .{
                    st, eid, self.items.isEat(eid),
                });
            }
        }
        if (assets_signs.tryLoad(allocator, opts.game_dir) catch null) |sc| {
            self.signs.deinit();
            self.signs = sc;
            std.debug.print("zdtd: sign libraries entries={d}\n", .{self.signs.entries.len});
        }
        if (assets_entities.tryLoad(allocator, opts.game_dir, opts.config_dir) catch null) |et| {
            self.entities.deinit();
            self.entities = et;
            // Push defaults into class_table for spawn helpers.
            const zdef = self.entities.defaultZombie();
            self.sim.setClassDef(1, .{
                .name = zdef.name,
                .max_hp = zdef.max_hp,
                .kind = .zombie,
                .hash = zdef.hash,
                .loot_list = zdef.loot_list,
                .chase_speed = zdef.chase_speed,
                .wander_speed = zdef.wander_speed,
                .attack_damage = self.handItemDamage(zdef.hand_item),
            });
            const adef = self.entities.defaultAnimal();
            self.sim.setClassDef(7, .{
                .name = adef.name,
                .max_hp = adef.max_hp,
                .kind = .animal,
                .hash = adef.hash,
                .loot_list = adef.loot_list,
                .chase_speed = adef.chase_speed,
                .wander_speed = adef.wander_speed,
                .attack_damage = self.handItemDamage(adef.hand_item),
            });
            std.debug.print("zdtd: entityclasses defs={d} zombie={s} hash={d}\n", .{
                self.entities.defs.len, zdef.name, zdef.hash,
            });
        }
        if (assets_recipes.tryLoad(allocator, opts.game_dir, opts.config_dir) catch null) |rt| {
            self.recipes.deinit();
            self.recipes = rt;
            std.debug.print("zdtd: recipes defs={d}\n", .{self.recipes.defs.len});
        }
        if (assets_loot.tryLoad(allocator, opts.game_dir, opts.config_dir) catch null) |lt| {
            self.loot.deinit();
            self.loot = lt;
            std.debug.print("zdtd: loot groups={d} containers={d}\n", .{ self.loot.groups.len, self.loot.containers.len });
        }
        self.loot.abundance_pct = opts.loot_abundance; // LootAbundance applies to builtin or xml table

        if (assets_entitygroups.tryLoad(allocator, opts.game_dir, opts.config_dir) catch null) |gt| {
            self.entitygroups.deinit();
            self.entitygroups = gt;
            std.debug.print("zdtd: entitygroups n={d}\n", .{self.entitygroups.groups.len});
            // Fill zombie class slots 1 + 8..11 from weighted group picks so the
            // director can rotate varied classes (not always class_table[1]).
            var zslot: usize = 1;
            var pick_seed: u32 = 1;
            while (zslot < 12) : (pick_seed += 1) {
                const cname = self.entitygroups.pick("ZombiesAll", pick_seed) orelse break;
                const def = self.entities.byName(cname) orelse continue;
                self.sim.setClassDef(@intCast(zslot), .{
                    .name = def.name,
                    .max_hp = def.max_hp,
                    .kind = .zombie,
                    .hash = def.hash,
                    .loot_list = def.loot_list,
                    .chase_speed = def.chase_speed,
                    .wander_speed = def.wander_speed,
                    .attack_damage = self.handItemDamage(def.hand_item),
                });
                zslot = if (zslot == 1) 8 else zslot + 1;
                if (pick_seed > 32) break;
            }
        }
        // After entitygroups: every <spawn group=…> must name a real entity
        // group. Stock throws XmlLoadException there (ParseSpawn, asm.il
        // ~1379646); zdtd warns and keeps the ladder so one bad row cannot
        // take the server down.
        if (assets_gamestages.tryLoad(allocator, opts.game_dir, opts.config_dir) catch null) |gst| {
            self.gamestages.deinit();
            self.gamestages = gst;
            var stage_n: usize = 0;
            var missing: usize = 0;
            for (self.gamestages.spawners) |sp| {
                stage_n += sp.stages.len;
                for (sp.stages) |st| {
                    for (st.spawns) |sg| {
                        if (self.entitygroups.byName(sg.group) == null) missing += 1;
                    }
                }
            }
            std.debug.print(
                "zdtd: gamestages spawners={d} stages={d} groups={d} unknown_entitygroups={d}\n",
                .{ self.gamestages.spawners.len, stage_n, self.gamestages.groups.len, missing },
            );
        }
        if (assets_traders.tryLoad(allocator, opts.game_dir, opts.config_dir)) |tt| {
            self.traders.deinit();
            self.traders = tt;
        }
        if (assets_painting.tryLoad(allocator, opts.game_dir, opts.config_dir) catch null) |pt| {
            self.painting.deinit();
            self.painting = pt;
            std.debug.print("zdtd: painting entries={d}\n", .{self.painting.n});
        }
        if (assets_spawning.tryLoad(allocator, opts.game_dir, opts.config_dir) catch null) |st| {
            self.spawning.deinit();
            self.spawning = st;
            std.debug.print("zdtd: spawning rules={d}\n", .{self.spawning.rules.len});
        }
        if (assets_buffs.tryLoad(allocator, opts.game_dir, opts.config_dir) catch null) |bt| {
            self.buffs.deinit();
            self.buffs = bt;
            std.debug.print("zdtd: buffs defs={d}\n", .{self.buffs.defs.len});
        }
        if (assets_progression.tryLoadTable(allocator, opts.game_dir, opts.config_dir) catch null) |pt| {
            self.progression_table.deinit();
            self.progression_table = pt;
            self.progression = pt.curve;
            if (pt.curve.loaded) {
                std.debug.print("zdtd: progression max_level={d} exp_to_level={d} attrs={d} perks={d}\n", .{
                    pt.curve.max_level,
                    pt.curve.exp_to_level,
                    pt.attributes.len,
                    pt.perks.len,
                });
            }
        } else if (assets_progression.tryLoad(allocator, opts.game_dir, opts.config_dir) catch null) |pc| {
            self.progression = pc;
            if (pc.loaded) {
                std.debug.print("zdtd: progression max_level={d} exp_to_level={d}\n", .{ pc.max_level, pc.exp_to_level });
            }
        }
        if (assets_vehicles.tryLoad(allocator, opts.game_dir, opts.config_dir) catch null) |vt| {
            self.vehicles.deinit();
            self.vehicles = vt;
            std.debug.print("zdtd: vehicles defs={d}\n", .{self.vehicles.defs.len});
        }
        if (assets_storage_pairs.tryLoad(allocator, opts.game_dir, opts.config_dir) catch null) |sp| {
            self.storage_pairs.deinit();
            self.storage_pairs = sp;
            const IdCtx = struct {
                t: *const assets_maxdamage.Table,
                fn lookup(ctx: ?*anyopaque, name: []const u8) ?u16 {
                    const s: *const @This() = @ptrCast(@alignCast(ctx.?));
                    return s.t.idByName(name);
                }
            };
            var id_ctx: IdCtx = .{ .t = &self.maxdamage };
            self.storage_pairs.resolveIds(IdCtx.lookup, &id_ctx);
            std.debug.print("zdtd: storage pairs={d}\n", .{self.storage_pairs.pairs.len});
        }
        // Wire spawning.xml groups into director (first matching biome rule).
        {
            var night_g: []const u8 = "";
            var day_g: []const u8 = "";
            var animal_g: []const u8 = "";
            var buf: [16]assets_spawning.Rule = undefined;
            for ([_][]const u8{ "pine_forest", "burnt_forest", "desert", "snow", "wasteland" }) |bn| {
                const n = self.spawning.rulesForBiome(bn, &buf);
                var ri: usize = 0;
                while (ri < n) : (ri += 1) {
                    const r = buf[ri];
                    if (r.kind == .animal and animal_g.len == 0) animal_g = r.entitygroup;
                    if (r.kind == .zombie) {
                        if (r.time == .night and night_g.len == 0) night_g = r.entitygroup;
                        if (r.time == .any or r.time == .day) {
                            if (day_g.len == 0) day_g = r.entitygroup;
                        }
                    }
                }
                if (night_g.len > 0 and day_g.len > 0) break;
            }
            self.sim.director.night_group = night_g;
            self.sim.director.day_group = day_g;
            self.sim.director.animal_group = animal_g;
            self.sim.director.group_pick_ctx = self;
            self.sim.director.group_pick_fn = &Game.pickEntityGroup;
            self.sim.director.stage_group_ctx = self;
            self.sim.director.stage_group_fn = &Game.pickStageGroup;
            self.sim.director.spawner_group_ctx = self;
            self.sim.director.spawner_group_fn = &Game.pickSpawnerGroup;
            if (night_g.len > 0 or day_g.len > 0) {
                std.debug.print("zdtd: director groups night={s} day={s} animal={s}\n", .{ night_g, day_g, animal_g });
            }
        }
        if (biomes_mod.tryLoadColorTable(allocator, opts.game_dir, opts.config_dir) catch null) |ct| {
            self.biome_colors.deinit();
            self.biome_colors = ct;
            // Reload biomes.png with XML colors if map already loaded.
            if (opts.map_dir) |md| {
                if (self.world.biomes) |*old| old.deinit();
                self.world.biomes = biomes_mod.tryLoadWithColors(allocator, md, &self.biome_colors) catch null;
            }
            std.debug.print("zdtd: biome colors n={d}\n", .{self.biome_colors.colors.len});
        }
        // biomes.xml layer stacks → terrain columns (AssignIds names).
        {
            const IdCtx = struct {
                t: *const assets_maxdamage.Table,
                fn lookup(ctx: ?*anyopaque, name: []const u8) ?u16 {
                    const self_t: *const @This() = @ptrCast(@alignCast(ctx.?));
                    if (self_t.t.idByName(name)) |id| return id;
                    // Comptime pins only when AssignIds map empty (offline / no dump).
                    if (self_t.t.id_by_name.count() > 0) return null;
                    const a = @import("../assets/assignids_comptime.zig");
                    if (std.mem.eql(u8, name, "terrStone")) return a.terr_stone;
                    if (std.mem.eql(u8, name, "terrBedrock")) return a.terr_bedrock;
                    if (std.mem.eql(u8, name, "terrDirt")) return a.terr_dirt;
                    if (std.mem.eql(u8, name, "terrForestGround")) return a.terr_forest_ground;
                    if (std.mem.eql(u8, name, "terrBurntForestGround")) return a.terr_burnt_forest_ground;
                    if (std.mem.eql(u8, name, "terrDesertGround")) return a.terr_desert_ground;
                    if (std.mem.eql(u8, name, "terrSand")) return a.terr_sand;
                    if (std.mem.eql(u8, name, "terrSandStone")) return a.terr_sand_stone;
                    if (std.mem.eql(u8, name, "terrSnow")) return a.terr_snow;
                    if (std.mem.eql(u8, name, "terrTopSoil")) return a.terr_topsoil;
                    if (std.mem.eql(u8, name, "terrDestroyedStone")) return a.terr_destroyed_stone;
                    if (std.mem.eql(u8, name, "terrDestroyedGrass")) return a.terr_destroyed_grass;
                    if (std.mem.eql(u8, name, "water")) return a.water;
                    return null;
                }
                /// blocks.xml IsDistantDecoration, the filter that decides which
                /// `<decoration>` rows can become DecoObjects at all.
                fn distantDeco(ctx: ?*anyopaque, name: []const u8) bool {
                    const self_t: *const @This() = @ptrCast(@alignCast(ctx.?));
                    return self_t.t.isDistantDeco(name);
                }
            };
            var id_ctx: IdCtx = .{ .t = &self.maxdamage };
            if (assets_biome_layers.tryLoad(allocator, opts.game_dir, opts.config_dir, IdCtx.lookup, IdCtx.distantDeco, &id_ctx) catch null) |bl| {
                self.world.biome_layers_table = bl;
                // Weather groups must come from the same effective biomes.xml we
                // serve, since groupIndex is a document ordinal in that file.
                // Frequency and countdown divisor read the very GameStats values
                // the client is told, so server sim and client display agree.
                const gs_defaults: packages.GameStatsValues = .{};
                self.world.weather.initFrom(&self.world.biome_layers_table, .{
                    .seed = opts.worldgen_seed orelse util_sim.default_seed,
                    .day_night_length = opts.day_night_length,
                    .storm_frequency = @as(f32, @floatFromInt(gs_defaults.storm_freq)) / 100.0,
                    .time_of_day_inc_per_sec = @intCast(@max(gs_defaults.time_of_day_inc_per_sec, 0)),
                });
                const burnt = bl.stackFor(9);
                std.debug.print("zdtd: biome layers default_n={d} burnt_n={d} burnt0={d} decos={s}\n", .{
                    bl.default_stack.n,
                    burnt.n,
                    if (burnt.n > 0) burnt.layers[0].block_id else 0,
                    if (bl.hasDecos()) "yes" else "no",
                });
            }
            if (assets_block_textures.tryLoad(allocator, opts.game_dir, opts.config_dir, IdCtx.lookup, &id_ctx) catch null) |bt| {
                self.block_textures.deinit();
                self.block_textures = bt;
                std.debug.print("zdtd: block textures defaults={d}\n", .{self.block_textures.by_id.count()});
            }
        }
        self.power_registry = ecs.powerblocks.Registry.build(&self.maxdamage);
        std.debug.print("zdtd: power blocks registered={d}\n", .{self.power_registry.n});
        if (opts.game_dir != null or opts.config_dir != null) {
            if (self.maxdamage.power_class_by_name.count() == 0)
                std.debug.print("zdtd: warn: blocks.xml Class map empty (power props missing)\n", .{});
            if (self.items.source != .xml)
                std.debug.print("zdtd: warn: items table builtin despite game-dir (items.xml not loaded)\n", .{});
            if (self.recipes.source != .xml)
                std.debug.print("zdtd: warn: recipes table builtin despite game-dir\n", .{});
            if (self.entities.source != .xml)
                std.debug.print("zdtd: warn: entities table builtin despite game-dir\n", .{});
            if (self.loot.source != .xml)
                std.debug.print("zdtd: warn: loot table builtin despite game-dir\n", .{});
            if (self.entitygroups.source != .xml)
                std.debug.print("zdtd: warn: entitygroups table builtin despite game-dir\n", .{});
            if (self.blocks.source != .xml)
                std.debug.print("zdtd: warn: blocks table builtin despite game-dir\n", .{});
            if (self.sim.catalog.source != .stock_xml)
                std.debug.print("zdtd: warn: quests catalog builtin despite game-dir\n", .{});
        }
        if (self.maxdamage.idByName("generatorbank")) |gid| {
            if (self.power_registry.lookup(gid)) |pr| {
                std.debug.print("zdtd: power generatorbank watts={d} max_fuel={d} out_per_fuel={d}\n", .{
                    pr.watts, pr.max_fuel, pr.output_per_fuel,
                });
            }
        }
        // Prefab sleeper volumes (stock map only). Prefer POIs near primary spawn first
        // so max_volumes budget covers playable area; remainder skipped (honest cap).
        if (self.world.prefabs) |*pf| {
            if (pf.prefabs_root.len > 0) {
                const sp0 = self.world.primarySpawn();
                var refs: std.ArrayList(sleepers_mod.PrefabRef) = .empty;
                defer refs.deinit(allocator);
                // Pass 1: within ~512m of spawn
                for (pf.items) |d| {
                    if (std.mem.startsWith(u8, d.name, "part_")) continue;
                    const dx = d.x - sp0.x;
                    const dz = d.z - sp0.z;
                    if (dx * dx + dz * dz > 512 * 512) continue;
                    try refs.append(allocator, .{
                        .name = d.name,
                        .x = d.x,
                        // Sleeper volume starts are prefab-local, so they follow
                        // the stamped body down through YOffset.
                        .y = d.stampY(),
                        .z = d.z,
                        .rot = d.rot,
                        .size_x = d.size_x,
                        .size_y = d.size_y,
                        .size_z = d.size_z,
                    });
                }
                // Pass 2: fill remaining budget with farther POIs
                if (refs.items.len < 800) {
                    for (pf.items) |d| {
                        if (std.mem.startsWith(u8, d.name, "part_")) continue;
                        const dx = d.x - sp0.x;
                        const dz = d.z - sp0.z;
                        if (dx * dx + dz * dz <= 512 * 512) continue;
                        try refs.append(allocator, .{
                            .name = d.name,
                            .x = d.x,
                            .y = d.stampY(),
                            .z = d.z,
                            .rot = d.rot,
                            .size_x = d.size_x,
                            .size_y = d.size_y,
                            .size_z = d.size_z,
                        });
                        if (refs.items.len >= 1200) break;
                    }
                }
                if (sleepers_mod.loadFromPrefabs(allocator, pf.prefabs_root, refs.items) catch |err| blk: {
                    std.debug.print("zdtd: sleeper load failed: {s}\n", .{@errorName(err)});
                    break :blk null;
                }) |sv| {
                    self.sleepers.deinit();
                    self.sleepers = sv;
                    // Stock POI volumes name gamestage groups, not entitygroups
                    // (SleeperVolume::Spawn, asm.il ~1199169). Probe at stage 1,
                    // the lowest rung any stock ladder has, so a regression back
                    // to defaultZombie for most of the map is visible at boot.
                    var gs_ok: usize = 0;
                    for (self.sleepers.volumes) |vol| {
                        if (vol.group_n == 0) continue;
                        if (self.gamestages.sleeperEntityGroup(vol.groups[0].class_name, 1) != null) gs_ok += 1;
                    }
                    std.debug.print("zdtd: sleeper volumes={d} (prefabs_near={d}) gamestage_resolved={d}\n", .{ self.sleepers.volumes.len, refs.items.len, gs_ok });
                }
            }
        }

        // Stock: ServerPort = TCP info; LiteNet UDP = ServerPort+2 (NetworkServerLiteNetLib.GetServerPorts).
        // port==0: ephemeral UDP only (tests), no TCP info listener.
        const lite_port: u16 = if (port == 0) 0 else port +% 2;
        try self.net.listen(lite_port);
        // ServerPassword is LiteNet Connect key (not Encryption* / not PlayerLogin).
        self.net.server_password = self.password;
        self.info_port = port;
        // Offline harness (port 0): virtual mono clock + serial forRanges so
        // lock/stale/resend and parallel systems are seed-stable under DST.
        // Run seed is worldgen when set, else default_seed (logged via getSeed).
        // Production always passes a real ServerPort and leaves wall clock.
        if (port == 0) {
            const seed = opts.worldgen_seed orelse util_sim.default_seed;
            util_sim.enableSeeded(util_sim.default_start_ns, seed);
        }
        // A later init error (for example invalid WebUI configuration) must not
        // leak process-wide virtual time or forced-serial scheduling into the
        // next test. Successful construction transfers cleanup to deinit().
        errdefer if (port == 0) util_sim.disable();
        if (port != 0) {
            const level = if (opts.world_name) |wn| wn else self.world_name;
            // Advertise ServerPort in GSI.Port; stock client dials LiteNet at Port+2.
            self.info_tcp.start(.{
                .game_name = "zdtd",
                .game_host = "zdtd",
                .level_name = level,
                .ip = "127.0.0.1",
                .info_port = port,
                .max_players = self.max_players,
                .current_players = 0,
                .server_version = version.stock_wire_announce,
                .world_size = 6144,
                .eac_enabled = false,
                .password_protected = self.password.len > 0,
            }) catch |err| {
                std.debug.print("zdtd: warning: TCP server-info on {d} failed: {}\n", .{ port, err });
            };
        }
        self.loadAdminLists();
        if (opts.admin_port != 0) {
            // Stock TelnetConsole::.ctor (asm.il ~270735): a password is what moves
            // the console off loopback, so `auth` must be set before `listen`.
            self.admin.auth = .{
                .password = opts.telnet_password,
                .fail_limit = opts.telnet_failed_login_limit,
            };
            self.admin.greeting = .{
                .version = version.stock_wire_announce,
                .compat_version = version.stock_wire,
                .server_ip = if (self.admin.public()) "Any" else "127.0.0.1",
                .server_port = port,
                .max_players = self.max_players,
                .game_mode = "GameModeSurvival",
                .world = opts.game_world,
                .game_name = self.world_name,
                .difficulty = opts.game_difficulty,
            };
            self.admin.listen(opts.admin_port) catch |err| {
                std.debug.print("zdtd: warning: admin TCP on 127.0.0.1:{d} failed: {}\n", .{ opts.admin_port, err });
            };
            if (self.admin.port != 0) {
                std.debug.print(
                    "zdtd: admin console {s}:{d} ({s})\n",
                    .{
                        if (self.admin.public()) "0.0.0.0" else "127.0.0.1",
                        self.admin.port,
                        if (self.admin.public()) "password required" else "unauthenticated; loopback only",
                    },
                );
            }
        }
        if (opts.webui_port != 0) {
            // Fail closed: operator requested webui; a silent disabled UI is a misconfig incident.
            self.webui.listen(.{
                .port = opts.webui_port,
                .bind_host = opts.webui_bind,
                .secret = opts.webui_secret,
            }) catch |err| {
                std.debug.print("zdtd: webui on {s}:{d} failed: {s}\n", .{
                    opts.webui_bind,
                    opts.webui_port,
                    @errorName(err),
                });
                return err;
            };
            self.webui.setAdminHandler(self, Game.webuiAdminThunk);
            std.debug.print("zdtd: webui http://{s}:{d}/ (auth: Bearer / X-Zdtd-Secret)\n", .{
                opts.webui_bind,
                self.webui.port,
            });
        }
        if (opts.world_name) |wn| self.world_name = wn;

        const sp = self.world.primarySpawn();
        const sy: f32 = @floatFromInt(sp.y);
        const sx: f32 = @floatFromInt(sp.x);
        const sz: f32 = @floatFromInt(sp.z);

        // Keep starter zombies outside default turret range (~24) so they survive until join.
        const zdef = self.entities.defaultZombie();
        const z1 = self.sim.spawnZombieClass(sx + 40, sy, sz + 8, zdef.max_hp, zdef.hash, zdef.loot_list);
        const z2 = self.sim.spawnZombieClass(sx - 35, sy, sz + 12, zdef.max_hp, zdef.hash, zdef.loot_list);
        const z3 = self.sim.spawnSleeperClass(sx + 30, sy, sz - 40, zdef.max_hp + 10, zdef.hash, zdef.loot_list);
        const adef = self.entities.defaultAnimal();
        _ = self.sim.spawnAnimal(sx - 20, sy, sz - 25, adef.max_hp, adef.hash, adef.loot_list);
        if (self.sim.spawnTrader("Trader Jen", sx + 12, sy, sz + 8)) |trader_id| {
            self.fillTraderFromXml(trader_id);
        }
        {
            const vk: ecs.components.VehicleKind = .minibike;
            if (self.vehicles.byKind(vk)) |vd| {
                _ = self.sim.spawnVehicleEx(vk, sx + 6, sy, sz - 4, vd.max_hp, vd.velocity_max);
            } else {
                _ = self.sim.spawnVehicle(vk, sx + 6, sy, sz - 4);
            }
        }
        // Near-spawn storage TE (stock TileEntity on chunk stream).
        // Prefer runtime AssignIds id for cntWoodenChestClosed when known; else placeholder.
        {
            const cx: i32 = sp.x + 2;
            const cy: i32 = sp.y;
            const cz: i32 = sp.z + 2;
            const chest_block: u16 = self.seedChestBlockId();
            if (self.world.setBlockWorld(cx, cy, cz, chest_block)) |_| {
                if (self.containers.getOrCreate(.{ .x = cx, .y = cy, .z = cz }, 8, chest_block)) |cont| {
                    cont.setSlot(0, .{ .item_id = 7, .count = 10, .quality = 1 }); // wood
                    cont.setSlot(1, .{ .item_id = 2, .count = 3, .quality = 1 }); // food
                }
            } else |err| {
                std.debug.print("zdtd: seed chest block ({d},{d},{d}) failed: {s}\n", .{ cx, cy, cz, @errorName(err) });
            }
        }
        std.debug.print("zdtd: sim seed zombies z1={?} z2={?} sleeper={?} count={d} spawn=({d},{d},{d})\n", .{
            z1, z2, z3, self.sim.countKind(.zombie), sp.x, sp.y, sp.z,
        });

        // Demo power grid off the spawn pad (do not auto-wire a live turret onto seed zombies).
        const gen = self.sim.power.addNode(.generator, @intFromFloat(sx + 50), @intFromFloat(sy), @intFromFloat(sz + 50), 100);
        if (self.sim.spawnTurret(sx + 52, sy, sz + 52)) |tid| {
            if (gen) |gid| {
                if (self.sim.slotOfNetId(tid)) |ts| {
                    _ = self.sim.power.connect(gid, self.sim.turret[ts].power_node);
                }
            }
        }
        self.sim.power.resolve();

        // Static plugins after world/assets are ready (sample_hello logs once).
        self.plugins.enableStaticDefaults();
    }

    /// True when Hard C2S rejects should apply (Correct mode). Observe keeps
    /// join-phase Hard drops but is the flag for future soft-only paths.
    fn authorityCorrects(self: *const Game) bool {
        return self.authority_mode == .correct;
    }

    fn noteAcceptedMove(self: *Game, c: *Client, x: f32, y: f32, z: f32) void {
        c.move_valid = true;
        c.move_x = x;
        c.move_y = y;
        c.move_z = z;
        c.move_tick = self.tick_n;
        // Pressure plate / tripwire: step on foot cell or body cell.
        self.tryActivateTriggerAtPlayer(x, y, z);
    }

    /// Actuate power-grid trigger nodes under the player (foot + body). Fail closed
    /// inside electric.activateTriggerAt (must be is_trigger + powered).
    fn tryActivateTriggerAtPlayer(self: *Game, x: f32, y: f32, z: f32) void {
        const bx: i32 = @intFromFloat(@floor(x));
        const by: i32 = @intFromFloat(@floor(y));
        const bz: i32 = @intFromFloat(@floor(z));
        // Foot cell (block under feet) then body cell (plate at standing height).
        _ = self.sim.power.activateTriggerAt(bx, by - 1, bz);
        _ = self.sim.power.activateTriggerAt(bx, by, bz);
    }

    fn resetMoveEnvelopePeer(self: *Game, peer_slot: usize, x: f32, y: f32, z: f32) void {
        if (peer_slot >= max_clients) return;
        const c = &self.clients[peer_slot];
        c.move_valid = false;
        c.move_x = x;
        c.move_y = y;
        c.move_z = z;
        c.move_tick = self.tick_n;
    }

    /// Horizontal speed envelope. Observe: count only, still apply client pos.
    /// Correct: clamp to last good + max delta; soft snap S2C when clamped.
    fn applyMovementEnvelope(
        self: *Game,
        c: *Client,
        peer: *ln_peer.Peer,
        entity_id: i32,
        x: f32,
        y: f32,
        z: f32,
    ) struct { x: f32, y: f32, z: f32, applied: bool } {
        if (!c.move_valid) {
            return .{ .x = x, .y = y, .z = z, .applied = true };
        }
        const tick_s: f32 = @as(f32, @floatFromInt(protocol.tick_ns)) / 1_000_000_000.0;
        const dt = movement.dtFromTicks(c.move_tick, self.tick_n, tick_s);
        const clamp = movement.clampHorizontal(
            c.move_x,
            c.move_z,
            x,
            z,
            dt,
            movement.max_horizontal_speed_mps,
        );
        if (!clamp.clamped) {
            return .{ .x = x, .y = y, .z = z, .applied = true };
        }
        self.harness.counters.inc(.movement_rejects);
        self.noteEvidence(c, peer.local_id, entity_id, .movement, .strong, .none, movement.max_horizontal_speed_mps, movement.max_horizontal_speed_mps);
        // Rubber-band / speed-hack signal: counter always; log rate-limited so a
        // sticky client does not flood stderr while first/100th stay visible.
        const n = self.harness.counters.get(.movement_rejects);
        if (n == 1 or n % 100 == 0) {
            std.debug.print(
                "zdtd: movement envelope reject n={d} local_id={d} entity={d}\n",
                .{ n, peer.local_id, entity_id },
            );
        }
        if (!self.authorityCorrects()) {
            return .{ .x = x, .y = y, .z = z, .applied = true };
        }
        if (packages.buildPosAndRotBody(
            self.body_buf[0..64],
            entity_id,
            clamp.x,
            y,
            clamp.z,
            0,
            0,
            0,
            true,
        )) |sb| {
            self.sendGame(peer, "NetPackageEntityPosAndRot", sb) catch {};
        } else |_| {}
        return .{ .x = clamp.x, .y = y, .z = clamp.z, .applied = true };
    }

    /// Terrain resting height for vehicle physics: top solid block + 1 (an
    /// entity on the surface sits one block above the topmost solid). Backs
    /// World.ground_fn; signature matches ecs World.ground_fn.
    fn heightAtWorld(ctx: ?*anyopaque, wx: i32, wz: i32) f32 {
        const g: *Game = @ptrCast(@alignCast(ctx.?));
        const t = world_store.World.worldToChunk(wx, wz);
        g.terrain_mu.lock();
        defer g.terrain_mu.unlock();
        const ch = g.world.getOrCreate(t.pos) catch return 61;
        return @as(f32, @floatFromInt(ch.heightAt(t.lx, t.lz))) + 1.0;
    }

    /// ECS POI hook: prefab footprint covering world (x,z), or null outside
    /// every prefab (also when no prefabs.xml was loaded). Backs World.poi_fn.
    fn poiRectAtWorld(ctx: ?*anyopaque, x: f32, z: f32) ?ecs.components.PoiRect {
        const g: *Game = @ptrCast(@alignCast(ctx.?));
        const pf = if (g.world.prefabs) |*p| p else return null;
        const wx: i32 = @intFromFloat(@floor(x));
        const wz: i32 = @intFromFloat(@floor(z));
        for (pf.items, 0..) |d, i| {
            const b = pf.boundsXZ(i);
            if (wx < b.x0 or wx >= b.x1 or wz < b.z0 or wz >= b.z1) continue;
            return .{
                .x = @floatFromInt(b.x0),
                .y = @floatFromInt(d.y),
                .z = @floatFromInt(b.z0),
                .size_x = @floatFromInt(b.x1 - b.x0),
                .size_y = @floatFromInt(d.size_y),
                .size_z = @floatFromInt(b.z1 - b.z0),
            };
        }
        return null;
    }

    /// ECS path step hook: feet Y the body would stand at after moving one cell,
    /// or null when the move is blocked. Models step-up, drop and headroom, so a
    /// wall, a POI roof and a crawlspace are all impassable while a slope is not.
    ///
    /// The old bool form asked `isSolid(heightAt + 1)`, which is false for every
    /// column by construction: `heights` is maintained as the topmost non-air
    /// block, so the cell above it is always air and the pathfinder saw an open
    /// world everywhere.
    fn pathStepAt(ctx: ?*anyopaque, _: i32, _: i32, from_y: i32, tx: i32, tz: i32) ?i32 {
        const g: *Game = @ptrCast(@alignCast(ctx.?));
        // Snapshot hit: same answer the locked path below would compute, without
        // taking the process-global terrain lock from an AI worker. A miss
        // falls through so the on-demand chunk generation side effect is kept.
        if (g.terrain_snapshot_on) {
            if (g.terrain_snap.standable(tx, tz, from_y)) |y| return y;
        }
        g.terrain_mu.lock();
        defer g.terrain_mu.unlock();
        return g.world.standableWorld(tx, tz, from_y) catch null;
    }

    /// ECS place hook: item_id → AssignIds block id (fail closed → 0).
    /// Offline pin map only when AssignIds table is empty (no dump/game-dir).
    fn placeBlockId(ctx: ?*anyopaque, item_id: u16) u16 {
        const g: *Game = @ptrCast(@alignCast(ctx.?));
        const iname: ?[]const u8 = if (g.items.byId(item_id)) |d| d.name else invsys.builtinStockNameFallback(item_id);
        const IdCtx = struct {
            t: *const assets_maxdamage.Table,
            fn lookup(c: ?*anyopaque, n: []const u8) ?u16 {
                const s: *const @This() = @ptrCast(@alignCast(c.?));
                return s.t.idByName(n);
            }
        };
        var id_ctx: IdCtx = .{ .t = &g.maxdamage };
        const resolved = invsys.itemToBlockResolved(item_id, iname, IdCtx.lookup, &id_ctx);
        if (resolved != 0) return resolved;
        // Offline map for known placeables when dump misses the shape name.
        const offline = invsys.itemToBlock(item_id);
        if (offline != 0) return offline;
        return 0;
    }

    /// ECS fuel hook: items.xml FuelValue (0 = not a fuel item).
    fn itemFuelValue(ctx: ?*anyopaque, item_id: u16) f32 {
        const g: *Game = @ptrCast(@alignCast(ctx.?));
        return g.items.fuelValueFor(item_id);
    }

    /// ECS stack hook: items.xml Stacknumber via ItemTable (builtin table when no XML).
    fn itemStackFor(ctx: ?*anyopaque, item_id: u16) u16 {
        const g: *Game = @ptrCast(@alignCast(ctx.?));
        if (g.items.byId(item_id)) |_| return g.items.stackFor(item_id);
        return invsys.maxStackBuiltin(item_id);
    }

    /// Fail closed on oversize C2S stacks: clamp count to items table max_stack.
    fn clampInventoryStacks(self: *Game, inv: *ecs.components.Inventory) void {
        for (&inv.slots) |*s| {
            if (s.count == 0 or s.item_id == 0) continue;
            const max = itemStackFor(self, s.item_id);
            if (max > 0 and s.count > max) s.count = max;
        }
    }

    /// ECS armor hook: stock/builtin name starts with "armor".
    fn itemIsArmor(ctx: ?*anyopaque, item_id: u16) bool {
        const g: *Game = @ptrCast(@alignCast(ctx.?));
        if (g.items.byId(item_id)) |d| {
            if (std.mem.startsWith(u8, d.name, "armor")) return true;
        }
        if (invsys.builtinStockNameFallback(item_id)) |n| {
            if (std.mem.startsWith(u8, n, "armor")) return true;
        }
        return invsys.isArmorOffline(item_id);
    }

    /// Refuel generator at world pos if peer is in range. amount = items.xml FuelValue.
    fn tryRefuelGenerator(self: *Game, c: *const Client, x: i32, y: i32, z: i32, amount: f32) bool {
        if (amount <= 0) return false;
        if (c.entity_id <= 0) return false;
        const ps = self.sim.slotOfNetId(c.entity_id) orelse return false;
        if (!self.sim.mask[ps].transform) return false;
        const t = self.sim.transform[ps];
        const dx = t.x - @as(f32, @floatFromInt(x));
        const dy = t.y - @as(f32, @floatFromInt(y));
        const dz = t.z - @as(f32, @floatFromInt(z));
        if (dx * dx + dy * dy + dz * dz > self.max_edit_range * self.max_edit_range) return false;
        return self.sim.power.refuelAt(x, y, z, amount);
    }

    /// items.xml ItemActionEat props for InvTx use (ItemActionEat.consume).
    fn eatProps(ctx: ?*anyopaque, item_id: u16) invsys.EatProps {
        const g: *Game = @ptrCast(@alignCast(ctx.?));
        return .{
            .is_eat = g.items.isEat(item_id),
            .food_amount = g.items.foodAmountFor(item_id),
            .food_health = g.items.foodHealthFor(item_id),
            .water_amount = g.items.waterAmountFor(item_id),
        };
    }

    fn sendSurvivalStats(
        self: *Game,
        peer: *ln_peer.Peer,
        entity_id: i32,
        hp: f32,
        max_hp: f32,
        food: f32,
        food_max: f32,
        water: f32,
        water_max: f32,
    ) !void {
        const stats = [_]struct { packages.EntityStatKind, f32, f32 }{
            .{ .health, hp, max_hp },
            .{ .food, food, food_max },
            .{ .water, water, water_max },
        };
        for (stats) |s| {
            if (packages.buildEntityStatChangedBody(
                self.body_buf[0..32],
                entity_id,
                -1,
                s[0],
                s[1],
                s[2],
                0,
            )) |body| {
                try self.sendGame(peer, "NetPackageEntityStatChanged", body);
            } else |_| {}
        }
    }

    /// `stock_deco` height callback over the live chunk store. Unreadable columns
    /// return 0, which the sampler skips (fail closed, no fabricated deco).
    fn decoHeightAt(ctx: ?*anyopaque, wx: i32, wz: i32) u16 {
        const g: *Game = @ptrCast(@alignCast(ctx orelse return 0));
        return g.world.heightWorld(wx, wz) catch 0;
    }

    /// `stock_deco` species callback: the biome under (wx,wz), then that biome's
    /// distant-decoration list from biomes.xml. Fail closed at every step, since
    /// a block id the client cannot resolve does not degrade, it throws inside the
    /// client world-load coroutine: `DecoManager.addLoadedDecoration` →
    /// `TryAddToOccupiedMap` derefs `Block::isMultiBlock` with no null check
    /// (asm.il 1262497), and `DecoChunk.UpdateModels` looks the model up by name,
    /// which is null for a null Block. Both leave the player stuck loading, which
    /// is worse than no trees.
    fn decoSpeciesAt(ctx: ?*anyopaque, wx: i32, wz: i32) packages.stock_deco.SpeciesList {
        const g: *Game = @ptrCast(@alignCast(ctx orelse return .{}));
        const bm = g.world.biomes orelse return .{};
        const biome_id = bm.atWorld(wx, wz) orelse return .{};
        const set = g.world.biome_layers_table.decosFor(biome_id);
        var out: packages.stock_deco.SpeciesList = .{};
        for (set.slice()) |d| {
            if (out.n >= packages.stock_deco.max_species) break;
            out.items[out.n] = .{ .block_id = d.block_id, .prob = d.prob };
            out.n += 1;
        }
        return out;
    }

    /// Cell offsets per deco block id for one join burst. The AssignIds map is
    /// name-keyed, so resolving a block id back to its `MultiBlockDim` costs a
    /// scan of the whole dump; a burst places thousands of objects but draws them
    /// from a handful of species, so one scan per distinct id is enough.
    const DecoDimCache = struct {
        /// Distinct deco species a burst can encounter across the covered biomes.
        const cap: usize = 32;
        ids: [cap]u16 = @splat(0),
        offsets: [cap]deco_mirror.Offsets = undefined,
        n: usize = 0,

        fn offsetsFor(self: *DecoDimCache, g: *const Game, id: u16) deco_mirror.Offsets {
            for (self.ids[0..self.n], self.offsets[0..self.n]) |cached_id, offs| {
                if (cached_id == id) return offs;
            }
            const offs = g.decoOffsetsFor(id);
            if (self.n < cap) {
                self.ids[self.n] = id;
                self.offsets[self.n] = offs;
                self.n += 1;
            }
            return offs;
        }
    };

    /// Cell offsets a decoration block occupies, from its blocks.xml
    /// `MultiBlockDim`. An id with no name in the dump places nothing: without the
    /// name there is no way to know whether it is a multiblock, and writing a
    /// bare parent where the client expects children leaves orphan cells.
    fn decoOffsetsFor(self: *const Game, id: u16) deco_mirror.Offsets {
        var it = self.maxdamage.idNameIterator();
        while (it.next()) |e| {
            if (e.id != id) continue;
            const dim = self.maxdamage.multiBlockDim(e.name);
            return deco_mirror.offsetsFor(dim.x, dim.y, dim.z);
        }
        return .{};
    }

    /// Write one placed decoration into the block store so collision, harvest and
    /// the streamed chunk payload agree with what the client renders. The client
    /// runs the same write itself (`ChunkCluster::addDistantDecorationBlocks`,
    /// asm.il 1126815) and skips any position that is already a multiblock, so
    /// doing it first is convergent, not conflicting.
    fn mirrorDeco(self: *Game, cache: *DecoDimCache, o: packages.stock_deco.DecoObj) bool {
        const offsets = cache.offsetsFor(self, @truncate(o.block_raw));
        if (offsets.n == 0) return false;
        const written = deco_mirror.apply(&self.world, .{
            .x = o.x,
            .y = o.y,
            .z = o.z,
            .raw = o.block_raw,
            .offsets = offsets,
        }) catch |err| {
            // A failed mirror is cosmetic drift, never a reason to drop the join.
            self.harness.counters.inc(.encode_errors);
            std.debug.print("zdtd: deco mirror failed at {d},{d},{d}: {s}\n", .{ o.x, o.y, o.z, @errorName(err) });
            return false;
        };
        return written > 0;
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
    fn sendDecoAroundSpawn(self: *Game, c: *const Client, peer: *ln_peer.Peer, wx: i32, wz: i32) !void {
        const deco = packages.stock_deco;
        const has_species = self.deco_trees and
            self.world.biomes != null and
            self.world.biome_layers_table.hasDecos();
        if (!has_species) {
            // Empty firstPackage is still required: the `isDecorated` marking loop
            // sits inside the `loadedDecos != null` branch, so without it the
            // client keeps retrying local generation it cannot do.
            const body = try deco.buildDecoUpdate(&self.body_buf, true, &.{});
            try self.sendGame(peer, "NetPackageDecoUpdate", body);
            std.debug.print(
                "zdtd: DecoUpdate first=true objs=0 (deco_trees={s} biomemap={s} biome_decos={s})\n",
                .{
                    if (self.deco_trees) "on" else "off",
                    if (self.world.biomes != null) "yes" else "no",
                    if (self.world.biome_layers_table.hasDecos()) "yes" else "no",
                },
            );
            return;
        }

        const t = world_store.World.worldToChunk(wx, wz);
        const r = self.decoRadiusFor(c);
        // Same window `streamChunksForClient` covers: heightWorld getOrCreate must
        // not become an unbounded world-gen burst outside the streamed chunks.
        const window: deco.Window = .{
            .x0 = (t.pos.x - r) * deco.chunk_side,
            .z0 = (t.pos.z - r) * deco.chunk_side,
            .x1 = (t.pos.x + r + 1) * deco.chunk_side,
            .z1 = (t.pos.z + r + 1) * deco.chunk_side,
        };
        const sampler: deco.Sampler = .{
            .height_at = decoHeightAt,
            .species_at = decoSpeciesAt,
            .ctx = self,
        };

        const seed = self.worldSeed();
        var chunk_objs: [deco.attempts_per_deco_chunk]deco.DecoObj = undefined;
        var pw = try deco.PackageWriter.init(&self.body_buf, deco.zdtd_decos_per_package);
        var dim_cache: DecoDimCache = .{};
        var total: usize = 0;
        var mirrored: usize = 0;
        var capped = false;
        var dcz = deco.worldToDecoChunk(window.z0);
        const dcz_end = deco.worldToDecoChunk(window.z1 - 1);
        const dcx_end = deco.worldToDecoChunk(window.x1 - 1);
        while (dcz <= dcz_end and !capped) : (dcz += 1) {
            var dcx = deco.worldToDecoChunk(window.x0);
            while (dcx <= dcx_end and !capped) : (dcx += 1) {
                const n = deco.generateForDecoChunk(&chunk_objs, dcx, dcz, seed, window, sampler);
                for (chunk_objs[0..n]) |o| {
                    if (total >= deco_objects_per_join) {
                        capped = true;
                        break;
                    }
                    // Mirror before streaming: the chunk payload the client gets
                    // must already contain the blocks it is about to be told to
                    // render, or the two disagree until the next edit.
                    if (self.deco_mirror and self.mirrorDeco(&dim_cache, o)) mirrored += 1;
                    if (pw.full()) {
                        try self.sendGame(peer, "NetPackageDecoUpdate", try pw.take());
                        self.pollNetOnce();
                    }
                    try pw.push(o);
                    total += 1;
                }
            }
        }
        // Always send a final package, even with 0 objects: the client needs at
        // least one firstPackage=true to allocate + drain + mark decorated.
        try self.sendGame(peer, "NetPackageDecoUpdate", try pw.take());
        std.debug.print(
            "zdtd: DecoUpdate objs={d} pkgs={d} r={d} mirrored={d} capped={}\n",
            .{ total, pw.sent, r, mirrored, capped },
        );
    }

    /// Seed the deco sampler keys off, so a chunk decorates identically across
    /// joins and restarts. The worldgen seed when there is one, else the world
    /// name hash: either way it is stable for the life of the save.
    fn worldSeed(self: *const Game) u64 {
        if (self.world.worldgen) |wg| return wg.seed;
        return std.hash.Wyhash.hash(0, self.world_name);
    }

    /// Chunk radius covered by the join deco burst. Same clamp as
    /// `streamChunksForClient` so we only touch chunks the join streams anyway
    /// (heightWorld getOrCreate must not become an unbounded world-gen burst).
    fn decoRadiusFor(self: *const Game, c: *const Client) i32 {
        var r: i32 = if (c.view_radius < 1) self.chunk_stream_radius_min else c.view_radius;
        if (r < self.chunk_stream_radius_min) r = self.chunk_stream_radius_min;
        if (r > self.chunk_stream_radius_max) r = self.chunk_stream_radius_max;
        while (r > 1 and @as(usize, @intCast((2 * r + 1) * (2 * r + 1))) > self.max_streamed_chunks) r -= 1;
        return r;
    }

    fn sendSignDataBatches(self: *Game, peer: *ln_peer.Peer) !void {
        if (self.signs.entries.len == 0) {
            const resp = try packages.buildSignDataResponseEmptyLast(self.body_buf[0..16]);
            try self.sendGame(peer, "NetPackageSignDataResponse", resp);
            std.debug.print("zdtd: SignDataRequest -> empty last batch entity peer\n", .{});
            return;
        }
        var start: usize = 0;
        var batches: usize = 0;
        while (start < self.signs.entries.len) {
            const last_chance = start;
            // Probe how many fit, then send with correct is_last.
            const probe = try stock_sign.buildSignDataResponseBatch(
                &self.body_buf,
                self.signs.entries,
                start,
                false,
            );
            const is_last = probe.next >= self.signs.entries.len;
            const batch = try stock_sign.buildSignDataResponseBatch(
                &self.body_buf,
                self.signs.entries,
                start,
                is_last,
            );
            try self.sendGame(peer, "NetPackageSignDataResponse", batch.body);
            batches += 1;
            start = batch.next;
            if (start == last_chance) {
                const resp = try packages.buildSignDataResponseEmptyLast(self.body_buf[0..16]);
                try self.sendGame(peer, "NetPackageSignDataResponse", resp);
                break;
            }
            self.pollNetOnce();
        }
        std.debug.print("zdtd: SignDataRequest -> batches={d} signs={d}\n", .{ batches, self.signs.entries.len });
    }

    pub fn deinit(self: *Game) void {
        // Offline harness left sim mode on; restore wall clock before return so
        // later tests that expect real monoNs are not stuck in virtual time.
        const leave_sim = self.info_port == 0;
        // Shutdown persist is best-effort; do not fail deinit on disk errors.
        self.savePlayers() catch |e| logPersistErr(self, "save players", e);
        self.world.saveAll() catch |e| logPersistErr(self, "save world", e);
        {
            // Land the shutdown save before anything else tears down. World.deinit
            // would also drain, but doing it here keeps the wait in the histogram
            // and surfaces any async write errors through sampleFlushCounters.
            const fs = apm.profiler.scope(&self.harness.prof, .save_flush_wait);
            defer fs.end();
            self.world.flushWait();
        }
        self.sampleFlushCounters();
        self.containers.save(self.world.world_dir) catch |e| logPersistErr(self, "save containers", e);
        self.saveBlockMeta() catch |e| logPersistErr(self, "save block meta", e);
        self.land_claims_n = 0;
        self.plugins.shutdown();
        self.sim.deinit();
        self.blocks.deinit();
        self.items.deinit();
        self.signs.deinit();
        self.entities.deinit();
        self.recipes.deinit();
        self.loot.deinit();
        self.entitygroups.deinit();
        self.gamestages.deinit();
        self.maxdamage.deinit();
        self.block_textures.deinit();
        self.painting.deinit();
        self.spawning.deinit();
        self.buffs.deinit();
        self.progression_table.deinit();
        self.vehicles.deinit();
        self.storage_pairs.deinit();
        self.biome_colors.deinit();
        self.traders.deinit();
        self.sleepers.deinit();
        self.admin.deinit();
        self.webui.deinit();
        self.info_tcp.stop();
        self.world.deinit();
        self.net.deinit();
        if (leave_sim) util_sim.disable();
    }

    pub fn infoPort(self: *const Game) u16 {
        return self.info_port;
    }

    fn refreshInfoPlayers(self: *Game) void {
        self.info_tcp.setPlayers(@intCast(self.countJoined()));
    }

    fn playersPath(self: *const Game, buf: []u8) ![]const u8 {
        return try std.fmt.bufPrint(buf, "{s}/players.zsv", .{self.world.world_dir});
    }

    /// Record layout (v2): magic ZPV2 | n:u32 | records…
    /// each: name_len:u8 | name | x,y,z:f32 | coins:u32 |
    ///   inv_n:u8 | inv_n×(item:u16, count:u16, quality:u8, meta:u16) |
    ///   jn:u8 | jn×(def_id:u16, quest_code:i32, flags:u8, progress:u16, phase:u8)
    /// Merge-write: offline players' existing records are carried over, not erased.
    /// ADR 0011 sibling stores; item_id = ECS handle (ADR 0015).
    fn savePlayers(self: *Game) !void {
        var path_buf: [512]u8 = undefined;
        const path = try self.playersPath(&path_buf);

        // Carry the on-disk records by slice: a fixed scratch buffer silently
        // dropped every offline player past its size on each autosave.
        var old_file: []u8 = &.{};
        defer self.allocator.free(old_file);
        var old_recs: []const u8 = &.{};
        var old_count: u32 = 0;
        if (io_fs.readFileAll(self.allocator, path)) |old_data| {
            old_file = old_data;
            if (old_data.len < 8 or !std.mem.eql(u8, old_data[0..4], "ZPV2"))
                return error.CorruptPlayersFile;
            old_count = std.mem.readInt(u32, old_data[4..8], .little);
            old_recs = old_data[8..];
            // Unreadable existing file: abort save so offline player records in
            // the on-disk file are not clobbered by a save missing them.
        } else |e| if (e != error.FileNotFound) return e;

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);

        // Header count is patched in last, from records actually appended. A
        // count predicted up front drifts whenever a joined client has no ECS
        // player slot, and the loader then walks past the last record.
        try out.appendSlice(self.allocator, &[_]u8{ 'Z', 'P', 'V', '2', 0, 0, 0, 0 });
        var written: u32 = 0;
        {
            var ri: u32 = 0;
            var off: usize = 0;
            while (ri < old_count) : (ri += 1) {
                const rec_start = off;
                if (off >= old_recs.len) return error.CorruptPlayersFile;
                const nl: usize = old_recs[off];
                if (nl > 32 or off + 1 + nl + 17 > old_recs.len)
                    return error.CorruptPlayersFile;
                const rec_name = old_recs[off + 1 ..][0..nl];
                off += 1 + nl + 16;
                const inv_n: usize = old_recs[off];
                off += 1 + inv_n * 7;
                if (off >= old_recs.len) return error.CorruptPlayersFile;
                const jn: usize = old_recs[off];
                off += 1 + jn * 10;
                if (off > old_recs.len) return error.CorruptPlayersFile;
                var online = false;
                for (&self.clients) |*cl| {
                    if (cl.joined and cl.name_len == nl and std.mem.eql(u8, cl.name[0..nl], rec_name)) {
                        online = true;
                        break;
                    }
                }
                if (online) continue;
                try out.appendSlice(self.allocator, old_recs[rec_start..off]);
                written += 1;
            }
        }
        for (&self.clients) |*cl| {
            if (!cl.joined or cl.entity_id <= 0 or cl.name_len == 0) continue;
            const ps = self.sim.playerByPeer(cl.slot) orelse continue;
            var rec: [512]u8 = undefined;
            var o: usize = 0;
            rec[o] = @intCast(cl.name_len);
            o += 1;
            @memcpy(rec[o..][0..cl.name_len], cl.name[0..cl.name_len]);
            o += cl.name_len;
            const save_y: f32 = if (self.sim.transform[ps].y < 2)
                @floatFromInt(self.world.primarySpawn().y)
            else
                self.sim.transform[ps].y;
            inline for (.{ self.sim.transform[ps].x, save_y, self.sim.transform[ps].z }) |f| {
                std.mem.writeInt(u32, rec[o..][0..4], @as(u32, @bitCast(f)), .little);
                o += 4;
            }
            std.mem.writeInt(u32, rec[o..][0..4], if (self.sim.mask[ps].wallet) self.sim.wallet[ps].coins else 0, .little);
            o += 4;
            const inv_start = o;
            o += 1;
            var inv_n: u8 = 0;
            if (self.sim.mask[ps].inventory) {
                for (self.sim.inventory[ps].slots) |s| {
                    if (o + 7 > rec.len) break;
                    std.mem.writeInt(u16, rec[o..][0..2], s.item_id, .little);
                    std.mem.writeInt(u16, rec[o + 2 ..][0..2], s.count, .little);
                    rec[o + 4] = s.quality;
                    std.mem.writeInt(u16, rec[o + 5 ..][0..2], s.meta, .little);
                    o += 7;
                    inv_n += 1;
                }
            }
            rec[inv_start] = inv_n;
            const j_start = o;
            o += 1;
            var jn: u8 = 0;
            if (self.sim.mask[ps].journal) {
                for (self.sim.journal[ps].slots) |q| {
                    if (!q.active and !q.completed) continue;
                    if (o + 10 > rec.len) break;
                    std.mem.writeInt(u16, rec[o..][0..2], q.def_id, .little);
                    std.mem.writeInt(i32, rec[o + 2 ..][0..4], q.quest_code, .little);
                    rec[o + 6] = (@as(u8, @intFromBool(q.active))) | (@as(u8, @intFromBool(q.completed)) << 1) | (@as(u8, @intFromBool(q.ready_turn_in)) << 2) | (@as(u8, @intFromBool(q.rally_activated)) << 3);
                    std.mem.writeInt(u16, rec[o + 7 ..][0..2], q.progress, .little);
                    rec[o + 9] = q.phase;
                    o += 10;
                    jn += 1;
                }
            }
            rec[j_start] = jn;
            try out.appendSlice(self.allocator, rec[0..o]);
            written += 1;
        }
        std.mem.writeInt(u32, out.items[4..][0..4], written, .little);
        try io_fs.writeFile(self.allocator, path, out.items);
    }

    /// Remove all players.zsv records whose login name equals `name`.
    /// Returns how many records were dropped. FileNotFound → 0 (no-op).
    /// Does not log the name (operator reply only).
    fn wipePlayerRecordsByName(self: *Game, name: []const u8) !u32 {
        if (name.len == 0 or name.len > 32) return 0;
        var path_buf: [512]u8 = undefined;
        const path = try self.playersPath(&path_buf);
        const data = io_fs.readFileAll(self.allocator, path) catch |e| {
            if (e == error.FileNotFound) return 0;
            return e;
        };
        defer self.allocator.free(data);
        const filtered = try zpv2DropName(self.allocator, data, name);
        defer if (filtered.blob) |b| self.allocator.free(b);
        if (filtered.removed == 0) return 0;
        try io_fs.writeFile(self.allocator, path, filtered.blob.?);
        return filtered.removed;
    }

    fn tryRestorePlayer(self: *Game, c: *Client) void {
        if (c.name_len == 0) return;
        var path_buf: [512]u8 = undefined;
        const path = self.playersPath(&path_buf) catch |err| {
            std.debug.print("zdtd: restore player: path failed: {s}\n", .{@errorName(err)});
            return;
        };
        const data = io_fs.readFileAll(self.allocator, path) catch |e| {
            if (e != error.FileNotFound) logPersistErr(self, "restore player", e);
            return;
        };
        defer self.allocator.free(data);
        if (data.len < 8) {
            std.debug.print("zdtd: restore player: file too short ({d} bytes)\n", .{data.len});
            return;
        }
        if (data[0] != 'Z' or data[1] != 'P' or data[3] != '2') {
            std.debug.print("zdtd: restore player: bad players file header\n", .{});
            return;
        }
        const n = std.mem.readInt(u32, data[4..8], .little);
        var off: usize = 8;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            if (off >= data.len) {
                std.debug.print("zdtd: restore player: truncated at record {d}/{d}\n", .{ i, n });
                return;
            }
            const nl: usize = data[off];
            off += 1;
            if (nl > 32 or off + nl + 16 + 1 > data.len) {
                std.debug.print("zdtd: restore player: corrupt record {d}/{d} (name_len={d})\n", .{ i, n, nl });
                return;
            }
            const name_slice = data[off..][0..nl];
            off += nl;
            const rest = data[off..][0..16];
            off += 16;
            const inv_n: usize = data[off];
            off += 1;
            if (off + inv_n * 7 + 1 > data.len) {
                std.debug.print("zdtd: restore player: truncated inventory at record {d}/{d}\n", .{ i, n });
                return;
            }
            var inv: [32]ecs.components.InvSlot = undefined;
            var k: usize = 0;
            while (k < inv_n) : (k += 1) {
                const ib = data[off..][0..7];
                off += 7;
                if (k < inv.len) inv[k] = .{
                    .item_id = std.mem.readInt(u16, ib[0..2], .little),
                    .count = std.mem.readInt(u16, ib[2..4], .little),
                    .quality = ib[4],
                    .meta = std.mem.readInt(u16, ib[5..7], .little),
                };
            }
            const jn: usize = data[off];
            off += 1;
            if (off + jn * 10 > data.len) {
                std.debug.print("zdtd: restore player: truncated journal at record {d}/{d}\n", .{ i, n });
                return;
            }
            var quests: [ecs.components.max_journal]ecs.components.QuestProgress = undefined;
            var qi: usize = 0;
            while (qi < jn) : (qi += 1) {
                const qb = data[off..][0..10];
                off += 10;
                if (qi < quests.len) quests[qi] = .{
                    .def_id = std.mem.readInt(u16, qb[0..2], .little),
                    .quest_code = std.mem.readInt(i32, qb[2..6], .little),
                    .active = (qb[6] & 1) != 0,
                    .completed = (qb[6] & 2) != 0,
                    .ready_turn_in = (qb[6] & 4) != 0,
                    .progress = std.mem.readInt(u16, qb[7..9], .little),
                    .phase = qb[9],
                    // Bit 3 was always zero before rally markers existed, so old
                    // saves read back as "marker not yet used" without a bump.
                    .rally_activated = (qb[6] & 8) != 0,
                };
            }
            if (!(c.name_len == nl and std.mem.eql(u8, c.name[0..nl], name_slice))) continue;
            const x: f32 = @bitCast(std.mem.readInt(u32, rest[0..4], .little));
            var y: f32 = @bitCast(std.mem.readInt(u32, rest[4..8], .little));
            const z: f32 = @bitCast(std.mem.readInt(u32, rest[8..12], .little));
            const coins = std.mem.readInt(u32, rest[12..16], .little);
            const ps = self.sim.playerByPeer(c.slot) orelse return;
            if (y < 2) {
                const sp2 = self.world.primarySpawn();
                y = @floatFromInt(sp2.y);
            }
            self.sim.transform[ps] = .{ .x = x, .y = y, .z = z, .yaw = 0 };
            if (self.sim.mask[ps].wallet) self.sim.wallet[ps].coins = coins;
            if (self.sim.mask[ps].inventory) {
                self.sim.inventory[ps] = .{};
                var fi: usize = 0;
                while (fi < inv_n and fi < inv.len) : (fi += 1) {
                    if (fi < self.sim.inventory[ps].slots.len) self.sim.inventory[ps].slots[fi] = inv[fi];
                }
            }
            if (self.sim.mask[ps].journal) {
                self.sim.journal[ps] = .{};
                var fq: usize = 0;
                while (fq < jn and fq < quests.len) : (fq += 1) {
                    self.sim.journal[ps].slots[fq] = quests[fq];
                    // The POI rect is derived from the world, not persisted:
                    // re-resolve it so a restored quest keeps its rally rect.
                    const qd = self.sim.catalog.byId(quests[fq].def_id) orelse continue;
                    if (self.sim.poiAt(qd.tx, qd.tz)) |rect| {
                        self.sim.journal[ps].slots[fq].poi = rect;
                    }
                }
            }
            return;
        }
    }

    fn pollAdmin(self: *Game) void {
        const chunk = self.admin.pollLine(&self.admin_line) orelse return;
        // One read may carry several newline-separated commands (piped input).
        var it = std.mem.tokenizeAny(u8, chunk, "\r\n");
        while (it.next()) |line| {
            // TCP-session-only: closing a session makes no sense on the webui path.
            if (std.mem.eql(u8, line, "quit") or std.mem.eql(u8, line, "exit")) {
                self.admin.reply("bye\n");
                self.admin.closeActive();
                return;
            }
            self.runAdminLine(line, "admin_tcp");
        }
    }

    /// Admin TCP + optional webui sink (same text both paths).
    fn adminReply(self: *Game, text: []const u8) void {
        self.admin.reply(text);
        if (self.admin_reply_sink) |sink| {
            const room = sink.len -% self.admin_reply_len;
            if (room == 0) return;
            const n = @min(text.len, room);
            @memcpy(sink[self.admin_reply_len..][0..n], text[0..n]);
            self.admin_reply_len += n;
        }
    }

    fn pollWebui(self: *Game) void {
        // Drain up to 4 queued console lines (same path as admin TCP).
        var drain_i: u32 = 0;
        while (drain_i < 4) : (drain_i += 1) {
            var line_buf: [webui_mod.max_cmd_line]u8 = undefined;
            const line = self.webui.takeCmd(&line_buf) orelse break;
            self.admin_reply_len = 0;
            self.admin_reply_sink = self.webui.cmd_out_buf[0..];
            self.runAdminLine(line, "webui");
            self.admin_reply_sink = null;
            self.webui.finishCmd(self.webui.cmd_out_buf[0..self.admin_reply_len]);
        }
        // Non-blocking HTTP; at most one request per poll call.
        self.webui.poll();
    }

    /// Copy live ops gauges into webui snapshot (call after step returns).
    /// Writes in-place into webui.snap (no large stack frame).
    pub fn fillWebuiSnap(self: *Game) void {
        if (!self.webui.enabled()) return;
        // Browser partials poll at >= 2s; rebuilding the snapshot (7 entity
        // scans + histogram percentiles) every tick is 10x wasted work.
        if (self.tick_n % 10 != 0) return;
        const s = &self.webui.snap;
        // Zero in place (avoid stack temp Snapshot which overflows step's frame).
        @memset(std.mem.asBytes(s), 0);
        s.tick_n = self.tick_n;
        const clk = self.sim.director.clock;
        s.day = clk.day;
        s.hours = clk.hours;
        s.bloodmoon_active = self.sim.director.bloodmoon_active;
        s.joined = self.countJoined();
        s.max_players = self.max_players;
        var entered_n: u16 = 0;
        var peers_alive: u16 = 0;
        for (&self.clients) |cl| {
            if (cl.entered) entered_n += 1;
        }
        for (&self.net.peers) |p| {
            if (p.alive) peers_alive += 1;
        }
        s.entered = entered_n;
        s.peers_alive = peers_alive;
        s.zombies = @intCast(@min(self.sim.countKind(.zombie), 65535));
        s.animals = @intCast(@min(self.sim.countKind(.animal), 65535));
        s.traders = @intCast(@min(self.sim.countKind(.trader), 65535));
        s.vehicles = @intCast(@min(self.sim.countKind(.vehicle), 65535));
        s.turrets = @intCast(@min(self.sim.countKind(.turret), 65535));
        s.loot_bags = @intCast(@min(self.sim.countKind(.loot_bag), 65535));
        s.players_ent = @intCast(@min(self.sim.countKind(.player), 65535));
        s.chunks = @intCast(@min(self.world.chunks.count(), 0xffff_ffff));
        s.bloodmoon_frequency = self.sim.director.clock.bloodmoon_frequency;
        s.net_packets_in = self.harness.counters.get(.net_packets_in);
        s.net_packets_out = self.harness.counters.get(.net_packets_out);
        s.net_bytes_in = self.harness.counters.get(.net_bytes_in);
        s.net_bytes_out = self.harness.counters.get(.net_bytes_out);
        s.entities_ticked = self.harness.counters.get(.entities_ticked);
        s.tick_overruns = self.harness.counters.get(.tick_overruns);
        s.encode_errors = self.harness.counters.get(.encode_errors);
        s.stream_errors = self.harness.counters.get(.stream_errors);
        s.join_ok = self.harness.counters.get(.join_ok);
        s.join_fail = self.harness.counters.get(.join_fail);
        s.packages_encoded = self.harness.counters.get(.packages_encoded);
        s.packages_broadcast = self.harness.counters.get(.packages_broadcast);
        s.net_poll_errors = self.harness.counters.get(.net_poll_errors);
        s.net_payload_errors = self.harness.counters.get(.net_payload_errors);
        s.net_send_errors = self.harness.counters.get(.net_send_errors);
        s.reliable_window_drops = self.harness.counters.get(.reliable_window_drops);
        s.persistence_errors = self.harness.counters.get(.persistence_errors);
        s.stale_peers_reaped = self.harness.counters.get(.stale_peers_reaped);
        s.phase_rejects = self.harness.counters.get(.phase_rejects);
        s.ownership_rejects = self.harness.counters.get(.ownership_rejects);
        s.bounds_rejects = self.harness.counters.get(.bounds_rejects);
        s.movement_rejects = self.harness.counters.get(.movement_rejects);
        s.decode_rejects = self.harness.counters.get(.decode_rejects);
        const th = self.harness.prof.histOf(.tick_total);
        s.tick_mean_ns = th.meanNs();
        s.tick_p50_ns = th.percentileNs(50);
        s.tick_p99_ns = th.percentileNs(99);
        s.tick_max_ns = th.max_ns;
        const nh = self.harness.prof.histOf(.net_poll);
        s.net_mean_ns = nh.meanNs();
        s.net_p99_ns = nh.percentileNs(99);
        const sh = self.harness.prof.histOf(.sim_entities);
        s.sim_mean_ns = sh.meanNs();
        s.sim_p99_ns = sh.percentileNs(99);
        const rh = self.harness.prof.histOf(.replicate);
        s.repl_mean_ns = rh.meanNs();
        s.repl_p99_ns = rh.percentileNs(99);
        const ch = self.harness.prof.histOf(.chunk_stream);
        s.stream_mean_ns = ch.meanNs();
        s.stream_p99_ns = ch.percentileNs(99);
        s.save_mean_ns = self.harness.prof.histOf(.save_io).meanNs();
        s.view_radius = self.view_radius;
        s.max_streamed_chunks = @intCast(@min(self.max_streamed_chunks, 65535));
        s.interest_range = self.interest_range;
        s.max_edit_range = self.max_edit_range;
        s.max_spawned_zombies = @intCast(@min(self.sim.director.max_alive, 65535));
        s.info_port = self.info_port;
        s.webui_port = self.webui.port;
        s.authority_correct = self.authority_mode == .correct;
        s.password_set = self.password.len > 0;
        s.wire_chunks = self.wire_chunks;
        const wn = self.world_name;
        const ncopy = @min(wn.len, s.world_name.len);
        @memcpy(s.world_name[0..ncopy], wn[0..ncopy]);
        s.world_name_len = @intCast(ncopy);
        var pi: usize = 0;
        for (&self.clients, 0..) |cl, slot| {
            if (!cl.joined and cl.peer == null) continue;
            if (pi >= webui_mod.max_players_snap) break;
            var row: webui_mod.PlayerRow = .{
                .used = true,
                .slot = @intCast(slot),
                .entity_id = cl.entity_id,
                .joined = cl.joined,
                .entered = cl.entered,
            };
            const nl = @min(cl.name_len, webui_mod.max_name);
            @memcpy(row.name[0..nl], cl.name[0..nl]);
            row.name_len = @intCast(nl);
            if (cl.entity_id > 0) {
                if (self.sim.slotOfNetId(cl.entity_id)) |es| {
                    if (self.sim.mask[es].transform) {
                        const t = self.sim.transform[es];
                        row.x = t.x;
                        row.y = t.y;
                        row.z = t.z;
                    }
                }
            }
            s.players[pi] = row;
            pi += 1;
        }
    }

    /// Collects console output lines into a scratch buffer for one reply.
    const ConsoleOut = struct {
        buf: [4096]u8 = undefined,
        used: usize = 0,
        lines: [64][]const u8 = undefined,
        n: usize = 0,
        fn line(self: *ConsoleOut, s: []const u8) void {
            if (self.n >= self.lines.len) return;
            const w = @min(s.len, self.buf.len - self.used);
            @memcpy(self.buf[self.used..][0..w], s[0..w]);
            self.lines[self.n] = self.buf[self.used..][0..w];
            self.used += w;
            self.n += 1;
        }
        fn linef(self: *ConsoleOut, comptime fmt: []const u8, args: anytype) void {
            var tmp: [256]u8 = undefined;
            self.line(std.fmt.bufPrint(&tmp, fmt, args) catch return);
        }
    };

    /// In-game console (F1) command set, executed for the sending player.
    /// Reply is NetPackageConsoleCmdClient (output lines, bExecute=false).
    fn handleConsoleCmd(self: *Game, peer: *ln_peer.Peer, c: *Client, body: []const u8) !void {
        var cmdbuf: [512]u8 = undefined;
        const cmd = packages.parseConsoleCmd(body, &cmdbuf);
        if (cmd.len == 0) return;
        // Log verb only: args may include player names, chat text, or coords.
        const verb_end = std.mem.indexOfScalar(u8, cmd, ' ') orelse cmd.len;
        self.harness.counters.inc(.player_console_commands);
        std.debug.print("zdtd: audit source=player_console slot={d} command={s}\n", .{ c.slot, cmd[0..verb_end] });

        var out: ConsoleOut = .{};
        var it = std.mem.tokenizeAny(u8, cmd, " ");
        const verb = it.next() orelse return;

        if (!isPlayerConsoleCommand(verb)) {
            var denied: ConsoleOut = .{};
            denied.line("permission denied");
            const resp = try packages.buildConsoleCmdClient(self.body_buf[0..8192], denied.lines[0..denied.n], false);
            try self.sendGame(peer, "NetPackageConsoleCmdClient", resp);
            return;
        }

        const player = self.sim.playerByPeer(c.slot);

        if (eqAny(verb, &.{ "help", "commands", "?" })) {
            // Keep in sync with c2s_text.isPlayerConsoleCommand allowlist.
            out.line("zdtd console commands:");
            out.line(" gettime|gt  listplayers|lp  listents|le  version");
            out.line(" say|s <msg>");
            out.line(" dm|cm|settempunit|debugmenu (client-side)");
        } else if (eqAny(verb, &.{ "gettime", "gt" })) {
            const clk = &self.sim.director.clock;
            const hh: u32 = @intFromFloat(clk.hours);
            const mm: u32 = @intFromFloat((clk.hours - @floor(clk.hours)) * 60.0);
            out.linef("Day {d}, {d:0>2}:{d:0>2}  (bloodmoon in {d} days)", .{
                clk.day, hh, mm, self.daysToBloodMoon(),
            });
        } else if (eqAny(verb, &.{ "settime", "st" })) {
            self.consoleSetTime(&it, &out);
        } else if (eqAny(verb, &.{ "teleportplayer", "tp", "goto" })) {
            self.consoleTeleport(player, &it, &out);
        } else if (eqAny(verb, &.{ "spawnentity", "se" })) {
            self.consoleSpawnEntity(player, &it, &out);
        } else if (eqAny(verb, &.{"spawnairdrop"})) {
            if (self.forceAirDrop()) out.line("air drop spawned") else out.line("no player to drop near");
        } else if (eqAny(verb, &.{ "killall", "ka" })) {
            out.linef("killed {d} zombies", .{self.consoleKillAll()});
        } else if (eqAny(verb, &.{ "giveself", "give", "gi" })) {
            self.consoleGiveSelf(player, &it, &out);
        } else if (eqAny(verb, &.{ "listplayers", "lp" })) {
            var i: usize = 0;
            for (&self.clients) |*cl| {
                if (!cl.joined) continue;
                out.linef("{d}. {s} (entity {d})", .{ i, cl.name[0..cl.name_len], cl.entity_id });
                i += 1;
            }
            if (i == 0) out.line("no players");
        } else if (eqAny(verb, &.{ "listents", "le" })) {
            out.linef("zombies={d} animals={d} players={d}", .{
                self.sim.countKind(.zombie), self.sim.countKind(.animal), self.countJoined(),
            });
        } else if (eqAny(verb, &.{ "say", "s" })) {
            const msg = it.rest();
            if (!chatMsgOk(msg)) {
                out.line("message too long or has control characters");
            } else if (!self.acceptChatRate(c)) {
                out.line("slow down");
            } else {
                const chat = try packages.buildStockChat(&self.body_buf, c.entity_id, msg);
                try self.broadcast("NetPackageChat", chat);
                out.line("sent");
            }
        } else if (eqAny(verb, &.{"kick"})) {
            self.consoleKickBan(it.next(), &out, false);
        } else if (eqAny(verb, &.{"ban"})) {
            self.consoleKickBan(it.next(), &out, true);
        } else if (eqAny(verb, &.{"version"})) {
            out.line("zdtd " ++ version.product ++ " (" ++ version.stock_wire ++ " wire)");
        } else if (eqAny(verb, &.{ "dm", "cm", "settempunit", "debugmenu" })) {
            out.line("ok (client-side toggle)");
        } else {
            out.linef("unknown command '{s}'; try 'help'", .{verb});
        }

        const resp = try packages.buildConsoleCmdClient(self.body_buf[0..8192], out.lines[0..out.n], false);
        try self.sendGame(peer, "NetPackageConsoleCmdClient", resp);
    }

    fn consoleSetTime(self: *Game, it: *std.mem.TokenIterator(u8, .any), out: *ConsoleOut) void {
        const clk = &self.sim.director.clock;
        const a = it.next() orelse {
            out.line("usage: settime <day|night|D H M>");
            return;
        };
        if (std.mem.eql(u8, a, "day")) {
            clk.hours = 12.0;
        } else if (std.mem.eql(u8, a, "night")) {
            clk.hours = 22.0;
        } else {
            const d = std.fmt.parseInt(u32, a, 10) catch {
                out.line("bad day");
                return;
            };
            if (d > 0) clk.day = d;
            if (it.next()) |hs| clk.hours = @floatFromInt(std.fmt.parseInt(u32, hs, 10) catch 0);
            if (it.next()) |ms| clk.hours += @as(f32, @floatFromInt(std.fmt.parseInt(u32, ms, 10) catch 0)) / 60.0;
        }
        const wt = packages.buildWorldTimeBody(self.body_buf[0..16], clk.worldTimeBits()) catch return;
        self.broadcast("NetPackageWorldTime", wt) catch {};
        out.linef("time set: day {d} {d:0>2}:00", .{ clk.day, @as(u32, @intFromFloat(clk.hours)) });
    }

    fn consoleTeleport(self: *Game, player: ?ecs.Slot, it: *std.mem.TokenIterator(u8, .any), out: *ConsoleOut) void {
        const ps = player orelse {
            out.line("no player entity");
            return;
        };
        const xs = it.next();
        const ys = it.next();
        const zs = it.next();
        if (xs == null or ys == null or zs == null) {
            out.line("usage: tp <x> <y> <z>");
            return;
        }
        const x = std.fmt.parseFloat(f32, xs.?) catch return;
        const y = std.fmt.parseFloat(f32, ys.?) catch return;
        const z = std.fmt.parseFloat(f32, zs.?) catch return;
        if (!std.math.isFinite(x) or !std.math.isFinite(y) or !std.math.isFinite(z)) {
            out.line("coordinates must be finite");
            return;
        }
        self.sim.transform[ps] = .{ .x = x, .y = y, .z = z, .yaw = 0 };
        if (self.sim.mask[ps].player) {
            self.resetMoveEnvelopePeer(@intCast(self.sim.player[ps].peer_slot), x, y, z);
        }
        const entity_id = self.sim.netId(ps);
        const body = packages.buildEntityTeleportBody(&self.body_buf, entity_id, x, y, z, 0, 0, 0, true) catch return;
        self.broadcast("NetPackageEntityTeleport", body) catch {};
        out.linef("teleported to {d:.0} {d:.0} {d:.0}", .{ x, y, z });
    }

    fn consoleSpawnEntity(self: *Game, player: ?ecs.Slot, it: *std.mem.TokenIterator(u8, .any), out: *ConsoleOut) void {
        const ps = player orelse {
            out.line("no player entity");
            return;
        };
        const nm = it.next() orelse {
            out.line("usage: spawnentity <class>");
            return;
        };
        const def = self.entities.byName(nm) orelse {
            out.linef("unknown class '{s}'", .{nm});
            return;
        };
        const t = self.sim.transform[ps];
        const sy = self.spawnYNearPlayer(t.x, t.y, t.z);
        const nid = if (def.kind == .animal)
            self.sim.spawnAnimal(t.x + 3, sy, t.z + 3, def.max_hp, def.hash, def.loot_list)
        else
            self.sim.spawnZombieClass(t.x + 3, sy, t.z + 3, def.max_hp, def.hash, def.loot_list);
        if (nid) |eid| {
            if (self.sim.slotOfNetId(eid)) |es| {
                for (&self.clients) |*cl| {
                    if (!cl.joined) continue;
                    cl.known_entities.unset(es);
                }
            }
            out.linef("spawned {s}", .{nm});
        } else out.line("spawn failed (capacity)");
    }

    fn consoleGiveSelf(self: *Game, player: ?ecs.Slot, it: *std.mem.TokenIterator(u8, .any), out: *ConsoleOut) void {
        const ps = player orelse {
            out.line("no player entity");
            return;
        };
        const nm = it.next() orelse {
            out.line("usage: giveself <item> [count]");
            return;
        };
        const def = self.items.byName(nm) orelse {
            out.linef("unknown item '{s}'", .{nm});
            return;
        };
        const count: u16 = if (it.next()) |cs| (std.fmt.parseInt(u16, cs, 10) catch 1) else 1;
        const t = self.sim.transform[ps];
        if (self.sim.spawnLootBag(t.x + 1, t.y, t.z + 1, def.id, count)) |nid| {
            self.broadcastLootSpawn(nid) catch {};
            out.linef("dropped {d}x {s} at your feet", .{ count, nm });
        } else out.line("give failed");
    }

    fn consoleKickBan(self: *Game, name: ?[]const u8, out: *ConsoleOut, do_ban: bool) void {
        const nm = name orelse {
            out.line("usage: kick|ban <name>");
            return;
        };
        for (&self.clients, 0..) |*cl, i| {
            if (!cl.joined or !std.mem.eql(u8, cl.name[0..cl.name_len], nm)) continue;
            if (cl.peer) |p| {
                if (do_ban) self.banIp(peerIpKey(p));
                p.alive = false;
            }
            self.clearLocksForPeer(i);
            self.clients[i] = .{};
            out.linef("{s} {s}", .{ if (do_ban) "banned" else "kicked", nm });
            return;
        }
        out.linef("no player named '{s}'", .{nm});
    }

    fn consoleKillAll(self: *Game) u32 {
        var n: u32 = 0;
        var s: ecs.Slot = 0;
        while (s < ecs.max_entities) : (s += 1) {
            if (!self.sim.alive[s] or self.sim.kind[s] != .zombie) continue;
            const eid = self.sim.network_id[s].id;
            const dmg = self.sim.damage(eid, 99999);
            if (dmg.killed) {
                if (packages.buildRemoveBody(&self.body_buf, eid)) |rm| {
                    self.broadcast("NetPackageEntityRemove", rm) catch {};
                } else |_| {}
                // Drop loot bags silently (caller may sweep). Avoid flooding bag.
                if (dmg.loot_bag_id > 0) {
                    if (self.sim.slotOfNetId(dmg.loot_bag_id)) |ls| {
                        if (self.sim.alive[ls]) self.sim.destroy(ls);
                    }
                }
                n += 1;
            }
        }
        return n;
    }

    /// Trigger an air drop immediately (console spawnairdrop). Returns false if
    /// no joined player to drop near.
    fn forceAirDrop(self: *Game) bool {
        for (&self.clients) |*cl| {
            if (!cl.joined) continue;
            const ps = self.sim.playerByPeer(cl.slot) orelse continue;
            const t = self.sim.transform[ps];
            if (self.sim.spawnLootBag(t.x, t.y + 2, t.z, 1, 1)) |bag| {
                self.fillLootBagFromTable(bag, "supplyCrate", @intCast(bag));
                self.broadcastLootSpawn(bag) catch {};
                return true;
            }
        }
        return false;
    }

    fn daysToBloodMoon(self: *const Game) u32 {
        const clk = self.sim.director.clock;
        if (clk.bloodmoon_frequency == 0) return 999;
        if (clk.day % clk.bloodmoon_frequency == 0) return 0;
        const next = ((clk.day / clk.bloodmoon_frequency) + 1) * clk.bloodmoon_frequency;
        return next - clk.day;
    }

    fn webuiAdminThunk(ctx: *anyopaque, line: []const u8, out: []u8) usize {
        const self: *Game = @ptrCast(@alignCast(ctx));
        self.admin_reply_len = 0;
        self.admin_reply_sink = out;
        self.runAdminLine(line, "webui");
        self.admin_reply_sink = null;
        return self.admin_reply_len;
    }

    /// Stock `ban add|remove|list` (ConsoleCmdBan, asm.il 209578-210270). The list
    /// is by identity and survives restart; the IP ban table still does the
    /// immediate enforcement for the connection that is being dropped.
    fn runBanCommand(self: *Game, sub: admin_mod.BanSub) void {
        switch (sub) {
            .list => {
                self.ban_list.expire(clock.wallSeconds());
                self.adminWrite(admin_cmds.writeBanList, .{&self.ban_list});
            },
            .remove => |t| {
                var idb: [96]u8 = undefined;
                const id = self.adminTargetId(t, &idb);
                _ = self.ban_list.remove(id);
                self.saveAdminLists();
                var b: [160]u8 = undefined;
                const s = std.fmt.bufPrint(&b, "{s} removed from ban list.\n", .{id}) catch return;
                self.adminReply(s);
            },
            .add => |a| {
                var idb: [96]u8 = undefined;
                const id = self.adminTargetId(a.target, &idb);
                const now = clock.wallSeconds();
                const until = std.math.add(i64, now, a.seconds) catch std.math.maxInt(i64);
                if (!self.ban_list.add(id, until, a.reason)) {
                    self.adminReply("ban list full\n");
                    return;
                }
                self.saveAdminLists();
                // Online target: drop the session and hold its address too, so a
                // reconnect before the next join check cannot slip through.
                switch (self.resolveAdminTarget(a.target)) {
                    .slot => |slot| {
                        if (self.clients[slot].peer) |p| self.banIp(peerIpKey(p));
                        self.dropClientSlot(slot);
                    },
                    else => {},
                }
                var tb: [24]u8 = undefined;
                var b: [256]u8 = undefined;
                const s = std.fmt.bufPrint(&b, "{s} banned until {s}, reason: {s}.\n", .{
                    id, admin_cmds.formatUnix(&tb, until), a.reason,
                }) catch return;
                self.adminReply(s);
            },
        }
    }

    fn adminListsPath(self: *const Game, buf: []u8, name: []const u8) ![]const u8 {
        return try std.fmt.bufPrint(buf, "{s}/{s}", .{ self.world.world_dir, name });
    }

    /// All three lists are rewritten together: they are small, and a single call
    /// site means no command can mutate one and forget to persist it.
    fn saveAdminLists(self: *Game) void {
        self.saveAdminListFile("admins.zsv", admin_cmds.serializePermissions, &self.admin_list);
        self.saveAdminListFile("whitelist.zsv", admin_cmds.serializePermissions, &self.whitelist);
        self.saveAdminListFile("bans.zsv", admin_cmds.serializeBans, &self.ban_list);
    }

    fn saveAdminListFile(self: *Game, name: []const u8, comptime ser: anytype, list: anytype) void {
        var path_buf: [512]u8 = undefined;
        const path = self.adminListsPath(&path_buf, name) catch return;
        var buf: [16 * 1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        ser(&w, list) catch |e| return logPersistErr(self, "serialize admin list", e);
        io_fs.writeFile(self.allocator, path, w.buffered()) catch |e|
            logPersistErr(self, "save admin list", e);
    }

    /// Reads the three lists at startup. A missing file is normal; a corrupt line
    /// is skipped and reported, never applied, so a damaged file cannot grant
    /// permissions or silently drop a live ban without a warning.
    fn loadAdminLists(self: *Game) void {
        const now = clock.wallSeconds();
        self.readAdminList("admins.zsv", "admin", struct {
            fn f(g: *Game, text: []const u8, _: i64) admin_cmds.LoadResult {
                return admin_cmds.deserializePermissions(&g.admin_list, text);
            }
        }.f, now);
        self.readAdminList("whitelist.zsv", "whitelist", struct {
            fn f(g: *Game, text: []const u8, _: i64) admin_cmds.LoadResult {
                return admin_cmds.deserializePermissions(&g.whitelist, text);
            }
        }.f, now);
        self.readAdminList("bans.zsv", "ban", struct {
            fn f(g: *Game, text: []const u8, t: i64) admin_cmds.LoadResult {
                return admin_cmds.deserializeBans(&g.ban_list, text, t);
            }
        }.f, now);
    }

    fn readAdminList(
        self: *Game,
        name: []const u8,
        label: []const u8,
        load: *const fn (*Game, []const u8, i64) admin_cmds.LoadResult,
        now: i64,
    ) void {
        var path_buf: [512]u8 = undefined;
        const path = self.adminListsPath(&path_buf, name) catch return;
        const text = io_fs.readFileAll(self.allocator, path) catch |e| {
            if (e != error.FileNotFound) logPersistErr(self, "load admin list", e);
            return;
        };
        defer self.allocator.free(text);
        const res = load(self, text, now);
        if (res.skipped != 0) {
            std.debug.print(
                "zdtd: warning: {d} corrupt {s} list entries skipped (not applied)\n",
                .{ res.skipped, label },
            );
        }
    }

    /// Stock `getgamepref` (asm.il 220877): "GamePref.{0} = {1}" per pref, filtered
    /// by substring. Only prefs zdtd actually applies are listed; printing a stock
    /// name zdtd ignores would tell an operator a lie.
    fn replyGamePrefs(self: *Game, filter: []const u8) void {
        self.gamePref(filter, "ServerPort", "{d}", .{self.info_port});
        self.gamePref(filter, "ServerMaxPlayerCount", "{d}", .{self.max_players});
        self.gamePref(filter, "GameName", "{s}", .{self.world_name});
        self.gamePref(filter, "ViewRadius", "{d}", .{self.view_radius});
        self.gamePref(filter, "GameDifficulty", "{d}", .{self.sim.director.difficulty});
        self.gamePref(filter, "DayNightLength", "{d}", .{
            @as(u32, @intFromFloat(@round(self.sim.director.clock.seconds_per_hour * 24.0 / 60.0))),
        });
        self.gamePref(filter, "TelnetPort", "{d}", .{self.admin.port});
    }

    fn gamePref(self: *Game, filter: []const u8, name: []const u8, comptime fmt: []const u8, args: anytype) void {
        if (filter.len != 0 and std.ascii.indexOfIgnoreCase(name, filter) == null) return;
        var vb: [96]u8 = undefined;
        const v = std.fmt.bufPrint(&vb, fmt, args) catch return;
        self.adminWrite(admin_cmds.writeGamePref, .{ name, v });
    }

    /// Stock `mem` (asm.il 235864). zdtd has no Unity heap, so the Unity-only
    /// fields report 0 rather than a made-up number; the separators are stock's
    /// so a scraper still finds the counts it can use.
    fn replyMem(self: *Game) void {
        var players: usize = 0;
        var zombies: usize = 0;
        var entities: usize = 0;
        var s: ecs.Slot = 0;
        while (s < ecs.max_entities) : (s += 1) {
            if (!self.sim.alive[s]) continue;
            entities += 1;
            switch (self.sim.kind[s]) {
                .player => players += 1,
                .zombie => zombies += 1,
                else => {},
            }
        }
        self.adminWrite(admin_cmds.writeMem, .{admin_cmds.MemStats{
            .minutes = clock.monoNs() / std.time.ns_per_min,
            .fps = protocol.ticks_per_second,
            .heap_mb = 0,
            .max_mb = 0,
            .chunks = self.world.chunks.count(),
            .chunk_game_objects = 0,
            .players = players,
            .zombies = zombies,
            .entities = entities,
            .entities_of_type = entities,
            .items = 0,
            .collision_objects = 0,
            .rss_mb = 0,
        }});
    }

    /// Render one `admin_cmds` formatter straight into the admin reply stream.
    /// Sized for the largest single formatter output, a full `ban list`
    /// (admin_cmds.max_entries rows of id + reason + timestamp).
    fn adminWrite(self: *Game, comptime f: anytype, args: anytype) void {
        var buf: [16 * 1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        @call(.auto, f, .{&w} ++ args) catch return;
        self.adminReply(w.buffered());
    }

    /// Stock console target resolution (ConsoleHelper::ParseParamPartialNameOrId,
    /// asm.il:268297): entity id, peer slot or (partial) player name.
    const TargetResult = union(enum) { slot: usize, none, ambiguous };

    fn resolveAdminTarget(self: *const Game, t: admin_mod.Target) TargetResult {
        switch (t) {
            .id => |n| {
                if (n < 0) return .none;
                const u: usize = @intCast(n);
                if (u < max_clients and self.clients[u].joined) return .{ .slot = u };
                for (&self.clients, 0..) |*cl, i| {
                    if (cl.joined and cl.entity_id == n) return .{ .slot = i };
                }
                return .none;
            },
            .name => |nm| {
                if (nm.len == 0) return .none;
                for (&self.clients, 0..) |*cl, i| {
                    if (cl.joined and std.ascii.eqlIgnoreCase(cl.name[0..cl.name_len], nm)) return .{ .slot = i };
                }
                var hit: ?usize = null;
                for (&self.clients, 0..) |*cl, i| {
                    if (!cl.joined) continue;
                    if (std.ascii.indexOfIgnoreCase(cl.name[0..cl.name_len], nm) == null) continue;
                    if (hit != null) return .ambiguous;
                    hit = i;
                }
                return if (hit) |h| .{ .slot = h } else .none;
            },
        }
    }

    /// The stock error lines a miss produces, so tooling can branch on them.
    fn adminTargetError(self: *Game, t: admin_mod.Target, res: TargetResult) void {
        var tb: [96]u8 = undefined;
        const tok = switch (t) {
            .id => |n| std.fmt.bufPrint(&tb, "{d}", .{n}) catch "?",
            .name => |nm| nm,
        };
        var b: [256]u8 = undefined;
        const s = switch (res) {
            .ambiguous => std.fmt.bufPrint(&b, "\"{s}\" matches multiple player names.\n", .{tok}),
            else => std.fmt.bufPrint(&b, "\"{s}\" is not a valid entity id, player name or user id.\n", .{tok}),
        } catch return;
        self.adminReply(s);
    }

    /// Identity a ban/permission entry is stored under: the login name when the
    /// target is online, otherwise the operator's own token. zdtd has no stock
    /// platform user id to key on, and inventing one would be a lie on the wire.
    /// Always copied into `buf`: callers kick the client afterwards, which clears
    /// the name the slice would otherwise point at.
    fn adminTargetId(self: *const Game, t: admin_mod.Target, buf: []u8) []const u8 {
        const src: []const u8 = switch (self.resolveAdminTarget(t)) {
            .slot => |i| self.clients[i].name[0..self.clients[i].name_len],
            else => switch (t) {
                .id => |n| return std.fmt.bufPrint(buf, "{d}", .{n}) catch "?",
                .name => |nm| nm,
            },
        };
        const n = @min(src.len, buf.len);
        @memcpy(buf[0..n], src[0..n]);
        return buf[0..n];
    }

    fn runAdminLine(self: *Game, line: []const u8, source: []const u8) void {
        const trimmed = std.mem.trim(u8, line, " \t");
        const verb_end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
        self.harness.counters.inc(.admin_commands);
        std.debug.print("zdtd: audit source={s} command={s}\n", .{ source, trimmed[0..verb_end] });
        const cmd = admin_mod.parseCommand(line);
        switch (cmd) {
            .help => {
                var buf: [4096]u8 = undefined;
                var w: std.Io.Writer = .fixed(&buf);
                admin_cmds.writeHelp(&w, &admin_help_index) catch return;
                self.adminReply(w.buffered());
            },
            .unknown => {
                // Surface the first token so typos are obvious (matches player console).
                const bad_verb = if (verb_end > 0) trimmed[0..verb_end] else trimmed;
                self.adminWrite(admin_cmds.writeUnknownCommand, .{bad_verb});
            },
            .err_text => |e| {
                var eb: [320]u8 = undefined;
                const s = std.fmt.bufPrint(&eb, "{s}{s}{s}\n", .{ e.prefix, e.token, e.suffix }) catch return;
                self.adminReply(s);
            },
            .wrong_args => |a| {
                var eb: [96]u8 = undefined;
                const s = std.fmt.bufPrint(
                    &eb,
                    "Wrong number of arguments, expected {s}, found {d}.\n",
                    .{ a.expected, a.found },
                ) catch return;
                self.adminReply(s);
            },
            .bad_args => |verb| {
                var eb: [128]u8 = undefined;
                const s = if (admin_mod.usageFor(verb)) |u|
                    std.fmt.bufPrint(&eb, "bad arguments to '{s}'. usage: {s}\n", .{ verb, u }) catch
                        "bad arguments. 'help' for usage.\n"
                else
                    std.fmt.bufPrint(&eb, "bad arguments to '{s}'. 'help' for usage.\n", .{verb}) catch
                        "bad arguments. 'help' for usage.\n";
                self.adminReply(s);
            },
            .status => {
                // One-line ops glance: load + key error counters for incident triage.
                var sb: [320]u8 = undefined;
                const s = std.fmt.bufPrint(
                    &sb,
                    "tick={d} players={d} zombies={d} chunks={d} overruns={d} encode_err={d} send_err={d} window_drop={d} persist_err={d}\n",
                    .{
                        self.tick_n,
                        self.countJoined(),
                        self.sim.countKind(.zombie),
                        self.world.chunks.count(),
                        self.harness.counters.get(.tick_overruns),
                        self.harness.counters.get(.encode_errors),
                        self.harness.counters.get(.net_send_errors),
                        self.harness.counters.get(.reliable_window_drops),
                        self.harness.counters.get(.persistence_errors),
                    },
                ) catch return;
                self.adminReply(s);
            },
            .guardstats => {
                var sb: [384]u8 = undefined;
                const s = std.fmt.bufPrint(&sb, "phase={d} ownership={d} bounds={d} movement={d} decode={d} throttle={d} malformed={d} reconnects={d} evidence={d}\n", .{
                    self.harness.counters.get(.phase_rejects),
                    self.harness.counters.get(.ownership_rejects),
                    self.harness.counters.get(.bounds_rejects),
                    self.harness.counters.get(.movement_rejects),
                    self.harness.counters.get(.decode_rejects),
                    self.harness.counters.get(.c2s_throttle),
                    self.harness.counters.get(.c2s_malformed),
                    self.harness.counters.get(.reconnects),
                    self.evidence.total,
                }) catch return;
                self.adminReply(s);
                self.adminReplyGuardPolicy();
            },
            .guardclear => |peer| {
                if (peer >= max_clients or self.clients[peer].peer == null) {
                    self.adminReply("no player in slot\n");
                    return;
                }
                self.clients[peer].guard.quarantine = .{};
                self.clients[peer].guard.kick_at_tick = 0;
                self.adminReply("guard cleared\n");
            },
            .evidence => {
                var dump: [8192]u8 = undefined;
                const n = self.evidence.dumpText(&dump);
                if (n == 0) self.adminReply("evidence empty\n") else self.adminReply(dump[0..n]);
            },
            .gamestage => |maybe_slot| self.adminReplyGameStage(maybe_slot),
            .apm => {
                // Full harness dump without waiting for the minute JSON line or --ticks exit.
                const snap = self.harness.snapshot();
                var ab: [apm.report.max_text_bytes]u8 = undefined;
                var w: std.Io.Writer = .fixed(&ab);
                apm.report.writeText(&snap, &w) catch |err| {
                    std.debug.print("zdtd: admin apm dump failed: {s}\n", .{@errorName(err)});
                };
                if (w.buffered().len > 0) self.adminReply(w.buffered()) else self.adminReply("apm dump empty\n");
            },
            .save => {
                // Same honesty as saveworld: never claim success when disk I/O failed.
                var save_failed = false;
                self.savePlayers() catch |e| {
                    save_failed = true;
                    logPersistErr(self, "save players", e);
                };
                self.world.saveAll() catch |e| {
                    save_failed = true;
                    logPersistErr(self, "save world", e);
                };
                self.containers.save(self.world.world_dir) catch |e| {
                    save_failed = true;
                    logPersistErr(self, "save containers", e);
                };
                self.saveBlockMeta() catch |e| {
                    save_failed = true;
                    logPersistErr(self, "save block meta", e);
                };
                self.adminReply(if (save_failed) "save failed; see server log\n" else "saved\n");
            },
            .kick => |k| {
                const res = self.resolveAdminTarget(k.target);
                const slot = switch (res) {
                    .slot => |i| i,
                    else => return self.adminTargetError(k.target, res),
                };
                var kb: [192]u8 = undefined;
                const s = std.fmt.bufPrint(&kb, "Kicking Player {s}: {s}\n", .{
                    self.clients[slot].name[0..self.clients[slot].name_len], k.reason,
                }) catch "Kicking Player\n";
                self.adminReply(s);
                self.dropClientSlot(slot);
            },
            .kickall => |reason| {
                for (&self.clients, 0..) |*cl, i| {
                    if (!cl.joined) continue;
                    var kb: [192]u8 = undefined;
                    const s = std.fmt.bufPrint(&kb, "Kicking Player {s}: {s}\n", .{
                        cl.name[0..cl.name_len], reason,
                    }) catch "Kicking Player\n";
                    self.adminReply(s);
                    self.dropClientSlot(i);
                }
            },
            .ban => |sub| self.runBanCommand(sub),
            .unban => |ip| {
                self.unbanIp(ip);
                self.adminReply("unbanned\n");
            },
            .admin => |sub| switch (sub) {
                .list => self.adminWrite(admin_cmds.writeAdminList, .{&self.admin_list}),
                .add => |a| {
                    var idb: [96]u8 = undefined;
                    const id = self.adminTargetId(a.target, &idb);
                    if (!self.admin_list.add(id, a.level)) {
                        self.adminReply("permissions list full\n");
                        return;
                    }
                    self.saveAdminLists();
                    var b: [160]u8 = undefined;
                    const s = std.fmt.bufPrint(&b, "{s} added with permission level of {d}.\n", .{ id, a.level }) catch return;
                    self.adminReply(s);
                },
                .remove => |t| {
                    var idb: [96]u8 = undefined;
                    const id = self.adminTargetId(t, &idb);
                    const removed = self.admin_list.remove(id);
                    if (removed) self.saveAdminLists();
                    var b: [160]u8 = undefined;
                    const s = if (removed)
                        std.fmt.bufPrint(&b, "{s} removed from permissions list.\n", .{id}) catch return
                    else
                        std.fmt.bufPrint(&b, "{s} was not on permissions list.\n", .{id}) catch return;
                    self.adminReply(s);
                },
            },
            .whitelist => |sub| switch (sub) {
                .list => self.adminWrite(admin_cmds.writeWhitelist, .{&self.whitelist}),
                .add => |t| {
                    var idb: [96]u8 = undefined;
                    const id = self.adminTargetId(t, &idb);
                    if (!self.whitelist.add(id, 0)) {
                        self.adminReply("whitelist full\n");
                        return;
                    }
                    self.saveAdminLists();
                    var b: [160]u8 = undefined;
                    const s = std.fmt.bufPrint(&b, "{s} added to whitelist.\n", .{id}) catch return;
                    self.adminReply(s);
                },
                .remove => |t| {
                    var idb: [96]u8 = undefined;
                    const id = self.adminTargetId(t, &idb);
                    const removed = self.whitelist.remove(id);
                    if (removed) self.saveAdminLists();
                    var b: [160]u8 = undefined;
                    const s = std.fmt.bufPrint(&b, "{s} {s} the whitelist.\n", .{
                        id, if (removed) "removed from" else "was not on",
                    }) catch return;
                    self.adminReply(s);
                },
            },
            .wipeplayer => |nm| {
                // Drop any online session with this login name first so the next
                // autosave cannot re-write the wiped players.zsv record.
                var kicked: u32 = 0;
                for (&self.clients, 0..) |*cl, i| {
                    if (!cl.joined or cl.name_len != nm.len) continue;
                    if (!std.mem.eql(u8, cl.name[0..cl.name_len], nm)) continue;
                    self.dropClientSlot(i);
                    kicked += 1;
                }
                const removed = self.wipePlayerRecordsByName(nm) catch |e| {
                    logPersistErr(self, "wipe player", e);
                    self.adminReply("wipe failed; see server log\n");
                    return;
                };
                var lb: [72]u8 = undefined;
                const s = std.fmt.bufPrint(&lb, "wiped records={d} kicked={d}\n", .{ removed, kicked }) catch "wiped\n";
                self.adminReply(s);
                // Count only; never print the login name to process logs.
                std.debug.print("zdtd: wipeplayer records={d} kicked={d}\n", .{ removed, kicked });
            },
            .list, .listplayers => {
                // ConsoleCmdListPlayers::Execute (asm.il 231241) field order.
                // Names stay on admin/webui replies only (never process stdout; PlayerLogin logs name_len).
                var n: usize = 0;
                for (&self.clients, 0..) |*cl, i| {
                    if (!cl.joined) continue;
                    const ps = self.sim.playerByPeer(i);
                    const t = if (ps) |p| self.sim.transform[p] else ecs.components.Transform{};
                    const hp: i32 = if (ps) |p| @intFromFloat(self.sim.health[p].hp) else 0;
                    self.adminWrite(admin_cmds.writePlayerRow, .{ n, admin_cmds.PlayerRow{
                        .entity_id = cl.entity_id,
                        .name = cl.name[0..cl.name_len],
                        .x = t.x,
                        .y = t.y,
                        .z = t.z,
                        .rot_y = t.yaw,
                        .health = hp,
                    } });
                    n += 1;
                }
                self.adminWrite(admin_cmds.writeTotal, .{n});
            },
            .listplayerids => {
                var n: usize = 0;
                for (&self.clients) |*cl| {
                    if (!cl.joined) continue;
                    self.adminWrite(admin_cmds.writePlayerIdRow, .{ n, cl.entity_id, cl.name[0..cl.name_len] });
                    n += 1;
                }
                self.adminWrite(admin_cmds.writeTotal, .{n});
            },
            .getgamepref => |filter| self.replyGamePrefs(filter),
            .setgamepref => |sp| {
                // zdtd applies serverconfig at startup only; a runtime write would
                // report success while the sim kept the old value.
                var b: [160]u8 = undefined;
                const s = std.fmt.bufPrint(
                    &b,
                    "GamePref.{s} is read-only on zdtd (set {s} in serverconfig.xml and restart).\n",
                    .{ sp.name, sp.name },
                ) catch return;
                self.adminReply(s);
            },
            .chunkcache => self.adminWrite(admin_cmds.writeChunkCache, .{
                self.world.chunks.count(),
                @as(u64, self.world.chunks.count()) * @sizeOf(world_store.Chunk),
            }),
            .mem => self.replyMem(),
            .killall => {
                const n = self.consoleKillAll();
                // Also animals (consoleKillAll is zombies-only). No loot bags:
                // playtest clear_ai between combat and economy; loot floods the
                // client bag and fails bag_add_item / trader free-slot paths.
                var extra: u32 = 0;
                var s: ecs.Slot = 0;
                while (s < ecs.max_entities) : (s += 1) {
                    if (!self.sim.alive[s] or self.sim.kind[s] != .animal) continue;
                    const eid = self.sim.network_id[s].id;
                    const dmg = self.sim.damage(eid, 99999);
                    if (dmg.killed) {
                        if (packages.buildRemoveBody(&self.body_buf, eid)) |rm| {
                            self.broadcast("NetPackageEntityRemove", rm) catch {};
                        } else |_| {}
                        // Destroy any loot bag created by damage() without S2C spawn.
                        if (dmg.loot_bag_id > 0) {
                            if (self.sim.slotOfNetId(dmg.loot_bag_id)) |ls| {
                                if (self.sim.alive[ls]) self.sim.destroy(ls);
                            }
                        }
                        extra += 1;
                    }
                }
                // Sweep existing ground loot so clear_ai leaves a clean field.
                var swept: u32 = 0;
                s = 0;
                while (s < ecs.max_entities) : (s += 1) {
                    if (!self.sim.alive[s]) continue;
                    if (self.sim.kind[s] != .loot_bag and !self.sim.mask[s].loot_bag) continue;
                    const lid = self.sim.network_id[s].id;
                    if (packages.buildRemoveBodyReason(&self.body_buf, lid, .despawned)) |rm| {
                        self.broadcast("NetPackageEntityRemove", rm) catch {};
                    } else |_| {}
                    self.sim.destroy(s);
                    swept += 1;
                }
                var lb: [64]u8 = undefined;
                const msg = std.fmt.bufPrint(&lb, "killed {d}\n", .{n + extra + swept}) catch "killed\n";
                self.adminReply(msg);
            },
            .give => |g| {
                // Server-side inv writes get clobbered by the client's next C2S
                // PlayerInventory push. Stock-legal: drop a loot bag at the
                // player's feet; pickup runs the client-authoritative flow.
                const ps = self.sim.playerByPeer(g.peer) orelse {
                    self.adminReply("no player in slot\n");
                    return;
                };
                const t = self.sim.transform[ps];
                if (self.sim.spawnLootBag(t.x + 1, t.y, t.z + 1, g.item, g.count)) |nid| {
                    self.broadcastLootSpawn(nid) catch {};
                    self.adminReply("dropped at player\n");
                } else self.adminReply("give failed\n");
            },
            .tele => |t| {
                if (self.sim.playerByPeer(t.peer)) |ps| {
                    self.sim.transform[ps] = .{ .x = t.x, .y = t.y, .z = t.z, .yaw = 0 };
                    self.resetMoveEnvelopePeer(t.peer, t.x, t.y, t.z);
                    const entity_id = self.sim.netId(ps);
                    const body = packages.buildEntityTeleportBody(&self.body_buf, entity_id, t.x, t.y, t.z, 0, 0, 0, true) catch {
                        self.adminReply("teleport encode failed\n");
                        return;
                    };
                    self.broadcast("NetPackageEntityTeleport", body) catch {
                        self.adminReply("teleport send failed\n");
                        return;
                    };
                    self.adminReply("teleported\n");
                } else self.adminReply("no player in slot\n");
            },
            .say => |msg| {
                const body = packages.buildStockChat(&self.body_buf, 0, msg) catch return;
                self.broadcast("NetPackageChat", body) catch {};
                self.adminReply("sent\n");
            },
            .gettime => {
                const clk = &self.sim.director.clock;
                var tb2: [64]u8 = undefined;
                const hh: u32 = @intFromFloat(clk.hours);
                const mm: u32 = @intFromFloat((clk.hours - @floor(clk.hours)) * 60.0);
                const s = std.fmt.bufPrint(&tb2, "Day {d}, {d:0>2}:{d:0>2}\n", .{ clk.day, hh, mm }) catch return;
                self.adminReply(s);
            },
            .settime => |world_time| {
                // Stock world time: 24000 ticks/day, 1000/hour (asm.il 1926175).
                const clk = &self.sim.director.clock;
                clk.day = @intCast(world_time / 24000 + 1);
                const in_day = world_time % 24000;
                clk.hours = @as(f32, @floatFromInt(in_day)) / 1000.0;
                const wt = packages.buildWorldTimeBody(self.body_buf[0..16], clk.worldTimeBits()) catch return;
                self.broadcast("NetPackageWorldTime", wt) catch {};
                var b: [64]u8 = undefined;
                const s = std.fmt.bufPrint(&b, "Set time to {d}\n", .{world_time}) catch return;
                self.adminReply(s);
            },
            .spawnentity => |sp2| {
                const nm = line[sp2.name_off..][0..sp2.name_len];
                const def = self.entities.byName(nm) orelse {
                    self.adminReply("unknown entity class\n");
                    return;
                };
                // Accept peer slot (small) or stock player entity id (>= ~100).
                const ps: ?ecs.Slot = blk: {
                    if (sp2.peer < max_clients) {
                        if (self.sim.playerByPeer(sp2.peer)) |s| break :blk s;
                    }
                    if (self.sim.slotOfNetId(@intCast(sp2.peer))) |s| {
                        if (self.sim.mask[s].player) break :blk s;
                    }
                    // First joined player fallback (playtest often only has one).
                    for (&self.clients, 0..) |*cl, i| {
                        if (!cl.joined) continue;
                        if (self.sim.playerByPeer(i)) |s| break :blk s;
                    }
                    break :blk null;
                };
                const pslot = ps orelse {
                    self.adminReply("no player in slot\n");
                    return;
                };
                const tr = self.sim.transform[pslot];
                const sy = self.spawnYNearPlayer(tr.x, tr.y, tr.z);
                const sx = tr.x + 3;
                const sz = tr.z + 3;
                // Name-based vehicle/trader shortcuts (entityclasses often tags them as zombie).
                const low_vehicle = std.mem.indexOf(u8, nm, "vehicle") != null or std.mem.indexOf(u8, nm, "Bicycle") != null or std.mem.indexOf(u8, nm, "Minibike") != null or std.mem.indexOf(u8, nm, "Motorcycle") != null or std.mem.indexOf(u8, nm, "4x4") != null or std.mem.indexOf(u8, nm, "Truck") != null or std.mem.indexOf(u8, nm, "Gyrocopter") != null;
                const nid = blk: {
                    if (low_vehicle or def.kind == .vehicle) {
                        const vk: ecs.components.VehicleKind = if (std.mem.indexOf(u8, nm, "Bicycle") != null or std.mem.indexOf(u8, nm, "bicycle") != null)
                            .bicycle
                        else if (std.mem.indexOf(u8, nm, "Minibike") != null or std.mem.indexOf(u8, nm, "minibike") != null)
                            .minibike
                        else if (std.mem.indexOf(u8, nm, "Motorcycle") != null or std.mem.indexOf(u8, nm, "motorcycle") != null)
                            .motorcycle
                        else if (std.mem.indexOf(u8, nm, "Gyro") != null or std.mem.indexOf(u8, nm, "gyro") != null)
                            .gyrocopter
                        else
                            .four_by_four;
                        break :blk self.sim.spawnVehicle(vk, sx, sy, sz);
                    }
                    if (def.kind == .trader or std.mem.startsWith(u8, nm, "npcTrader")) {
                        break :blk self.sim.spawnTrader(nm, sx, sy, sz);
                    }
                    if (def.kind == .animal) {
                        break :blk self.sim.spawnAnimal(sx, sy, sz, def.max_hp, def.hash, def.loot_list);
                    }
                    break :blk self.sim.spawnZombieClass(sx, sy, sz, def.max_hp, def.hash, def.loot_list);
                };
                if (nid) |eid| {
                    // Force clients to treat entity as unknown so next interest pass
                    // sends ECD (playtest combat flake: spawn without client EntityAlive).
                    if (self.sim.slotOfNetId(eid)) |es| {
                        for (&self.clients) |*cl| {
                            if (!cl.joined) continue;
                            cl.known_entities.unset(es);
                        }
                    }
                    self.adminReply("spawned\n");
                    std.debug.print("zdtd: admin spawnentity {s} eid={d} y={d:.1} near peerArg={d}\n", .{ nm, eid, sy, sp2.peer });
                } else self.adminReply("spawn failed (capacity)\n");
            },
            .listents => {
                // ConsoleCmdListEntities (asm.il 230715) field order + total line.
                var n: usize = 0;
                var ei: ecs.Slot = 0;
                while (ei < ecs.max_entities) : (ei += 1) {
                    if (!self.sim.alive[ei] or !self.sim.mask[ei].network_id) continue;
                    const t = self.sim.transform[ei];
                    self.adminWrite(admin_cmds.writeEntityRow, .{ n, admin_cmds.EntityRow{
                        .entity_id = self.sim.network_id[ei].id,
                        .name = @tagName(self.sim.kind[ei]),
                        .x = t.x,
                        .y = t.y,
                        .z = t.z,
                        .rot_y = t.yaw,
                        .dead = self.sim.mask[ei].health and self.sim.health[ei].hp <= 0,
                        .health = if (self.sim.mask[ei].health)
                            @intFromFloat(self.sim.health[ei].hp)
                        else
                            null,
                    } });
                    n += 1;
                }
                self.adminWrite(admin_cmds.writeTotal, .{n});
            },
            .saveworld => {
                var save_failed = false;
                self.world.saveAll() catch |e| {
                    save_failed = true;
                    logPersistErr(self, "save world", e);
                };
                self.containers.save(self.world.world_dir) catch |e| {
                    save_failed = true;
                    logPersistErr(self, "save containers", e);
                };
                self.saveBlockMeta() catch |e| {
                    save_failed = true;
                    logPersistErr(self, "save block meta", e);
                };
                self.savePlayers() catch |e| {
                    save_failed = true;
                    logPersistErr(self, "save players", e);
                };
                self.adminReply(if (save_failed) "world save failed; see server log\n" else "world saved\n");
            },
            .shutdown => {
                self.adminReply("shutting down\n");
                self.running = false;
            },
            .version => self.adminReply("zdtd " ++ version.product ++ " (" ++ version.stock_wire ++ " wire)\n"),
            .inv => |peer_slot| {
                const ps = self.sim.playerByPeer(peer_slot) orelse {
                    self.adminReply("no player in slot\n");
                    return;
                };
                if (!self.sim.mask[ps].inventory) {
                    self.adminReply("no inventory\n");
                    return;
                }
                for (self.sim.inventory[ps].slots, 0..) |s, si| {
                    if (s.count == 0) continue;
                    var lb: [96]u8 = undefined;
                    const out = std.fmt.bufPrint(&lb, "slot={d} item={d} count={d} q={d} meta={d}\n", .{
                        si, s.item_id, s.count, s.quality, s.meta,
                    }) catch continue;
                    self.adminReply(out);
                }
                self.adminReply("end\n");
            },
            .kill => |eid| {
                const was_zombie = blk: {
                    if (self.sim.slotOfNetId(eid)) |ei|
                        break :blk self.sim.kind[ei] == .zombie or self.sim.kind[ei] == .animal;
                    break :blk false;
                };
                const dmg = self.sim.damage(eid, 99999);
                if (!dmg.killed) {
                    std.debug.print("zdtd: admin kill {d} missed (alive or unknown)\n", .{eid});
                    self.adminReply("kill missed\n");
                    return;
                }
                const is_player = blk: {
                    if (self.sim.slotOfNetId(eid)) |ti| break :blk self.sim.mask[ti].player;
                    break :blk false;
                };
                if (is_player) {
                    // Push hp=0 stat so the client death flow triggers.
                    if (packages.buildEntityStatBody(self.body_buf[512..640], eid, 0, 100)) |hb| {
                        self.broadcast("NetPackageEntityStatChanged", hb) catch {};
                    } else |_| {}
                    std.debug.print("zdtd: admin kill player entity={d} hp=0 sent\n", .{eid});
                    self.adminReply("player killed\n");
                    return;
                }
                const rm = packages.buildRemoveBody(&self.body_buf, eid) catch return;
                self.broadcast("NetPackageEntityRemove", rm) catch {};
                self.adminReply("killed\n");
                std.debug.print("zdtd: admin kill entity={d} remove sent\n", .{eid});
                if (was_zombie) {
                    // quest credit to first joined peer if any
                    for (&self.clients, 0..) |*cl, i| {
                        if (!cl.joined) continue;
                        systems.questOnZombieKilled(&self.sim, i);
                        systems.questOnFetchItem(&self.sim, i, 1);
                        break;
                    }
                }
                if (dmg.loot_bag_id > 0) {
                    self.fillLootBagFromTable(dmg.loot_bag_id, dmg.loot_list, @intCast(eid));
                    self.broadcastLootSpawn(dmg.loot_bag_id) catch {};
                }
            },
        }
    }

    pub fn bindPort(self: *const Game) u16 {
        return self.net.port;
    }

    fn clientFor(self: *Game, peer: *ln_peer.Peer) ?*Client {
        // Fast path: known live peer. This runs per inbound datagram, so the
        // reap sweep below only pays off on the miss (new-peer) path;
        // reapStalePeers covers dead peers once per tick regardless.
        if (peer.alive) {
            for (&self.clients) |*c| {
                if (c.peer == peer) return c;
            }
        }
        // Drop clients whose LiteNet peer died (disconnect / timeout).
        // Same log/counter as reapStalePeers: whichever sweep wins the race,
        // the disconnect still shows up in the server log.
        for (&self.clients) |*c| {
            if (c.peer) |p| {
                if (!p.alive) {
                    self.harness.counters.inc(.stale_peers_reaped);
                    std.debug.print(
                        "zdtd: peer reaped dead local_id={d} slot={d} entity={d}\n",
                        .{ p.local_id, c.slot, c.entity_id },
                    );
                    self.clearLocksForPeer(c.slot);
                    c.* = .{};
                    self.refreshInfoPlayers();
                }
            }
        }
        for (&self.clients) |*c| {
            if (c.peer == peer) return c;
        }
        // Soft capacity: ServerMaxPlayerCount (slots still sized to max_clients).
        var occupied: u16 = 0;
        for (&self.clients) |*c| {
            if (c.peer != null) occupied += 1;
        }
        if (occupied >= self.max_players) return null;
        for (&self.clients, 0..) |*c, i| {
            if (c.peer == null) {
                c.* = .{ .peer = peer, .slot = i };
                self.challenge_counter += 1;
                // Both halves from the join counter (golden-ratio mix on the high
                // half). No wall-clock: challenge bytes are seed-stable for DST
                // replay of the join path. Still unique per accept order.
                std.mem.writeInt(u64, c.challenge[0..8], self.challenge_counter, .little);
                std.mem.writeInt(u64, c.challenge[8..16], self.challenge_counter *% 0x9E3779B97F4A7C15, .little);
                return c;
            }
        }
        return null;
    }

    /// Streaming packages may be soft-dropped on WindowFull (client re-requests
    /// or the next stream tick resends). Everything else is join/state-critical:
    /// dropping e.g. SignDataResponse leaves the client stuck on "Starting Game"
    /// (worldInfoCo blocks until isLastBatch=true).
    fn isDroppablePackage(pkg_name: []const u8) bool {
        // NOT droppable: NetPackageDecoUpdate. DecoManager.Read only allocates
        // loadedDecos on firstPackage=true; dropping that one NREs every
        // continuation package, and deco is sent exactly once per session.
        const names = [_][]const u8{
            "NetPackageChunk",
            "NetPackageChunkRemove",
            "NetPackageDecoResetWorldChunk",
            "NetPackageEntityPosAndRot",
            "NetPackageEntitySpeeds",
            "NetPackageVehiclePositions",
            "NetPackageWorldTime",
        };
        for (names) |n| {
            if (std.mem.eql(u8, pkg_name, n)) return true;
        }
        return false;
    }

    fn sendGame(self: *Game, peer: *ln_peer.Peer, pkg_name: []const u8, body: []const u8) anyerror!void {
        // Count encode failures here: many callers swallow the error (`catch {}`),
        // so this is the only place they stay visible in apm. Rate-limit the log
        // so a bad package does not flood stdout while still showing first/100th.
        const framed = packages.framed(&self.send_buf, pkg_name, body) catch |err| {
            self.harness.counters.inc(.encode_errors);
            const n = self.harness.counters.get(.encode_errors);
            if (n == 1 or n % 100 == 0) {
                std.debug.print(
                    "zdtd: encode failed pkg={s} body_len={d} n={d}: {s}\n",
                    .{ pkg_name, body.len, n, @errorName(err) },
                );
            }
            return err;
        };
        // Poll mid-send so client ACKs free the reliable window (explicit anyerror avoids
        // inferred error-set cycles with onData).
        // Streaming: ~8ms budget then soft-drop. Critical: keep pumping ACKs up
        // to ~120ms; one long send beats a client wedged on "Starting Game".
        const droppable = isDroppablePackage(pkg_name);
        // Chunks are large multi-fragment; allow longer window drain than chat/etc.
        const max_attempts: u32 = if (std.mem.eql(u8, pkg_name, "NetPackageChunk"))
            4000
        else if (droppable)
            64
        else
            960;
        var attempts: u32 = 0;
        while (attempts < max_attempts) : (attempts += 1) {
            peer.sendReliable(&self.net.sock, framed) catch |err| switch (err) {
                error.WindowFull => {
                    peer.resendPending(&self.net.sock) catch {
                        self.harness.counters.inc(.net_send_errors);
                    };
                    self.pollNetOnce();
                    if (attempts % 4 == 3) clock.sleepNs(500_000);
                    continue;
                },
                else => {
                    self.harness.counters.inc(.net_send_errors);
                    const n = self.harness.counters.get(.net_send_errors);
                    if (n == 1 or n % 100 == 0) {
                        std.debug.print(
                            "zdtd: send failed pkg={s} local_id={d} n={d}: {s}\n",
                            .{ pkg_name, peer.local_id, n, @errorName(err) },
                        );
                    }
                    return err;
                },
            };
            self.harness.counters.add(.net_packets_out, 1);
            self.harness.counters.add(.net_bytes_out, framed.len);
            // Drain a few ACKs so the next package does not immediately fill the window.
            self.pollNetAfterSend();
            return;
        }
        // Drop rather than fail the tick: WindowFull must not kill the dedi.
        self.harness.counters.inc(.reliable_window_drops);
        const drops = self.harness.counters.get(.reliable_window_drops);
        if (drops == 1 or drops % 100 == 0) {
            std.debug.print(
                "zdtd: reliable window drop pkg={s} droppable={} n={d}\n",
                .{ pkg_name, droppable, drops },
            );
        }
    }

    /// Award XP to a client's server-side ledger, scaled by XPMultiplier.
    /// Levels up using progression.xml exp curve when loaded.
    fn awardXp(self: *Game, slot: usize, base: u64) void {
        if (slot >= self.clients.len) return;
        const c = &self.clients[slot];
        c.xp += base * self.xp_multiplier / 100;
        // Compute the current cumulative threshold once, then advance it as
        // levels are crossed. Re-summing from level one on every iteration is
        // quadratic for large XP awards.
        var next_threshold: u64 = 0;
        var level: u16 = 1;
        while (level <= c.level) : (level += 1) {
            next_threshold += self.progression.expForLevel(level);
        }
        while (c.level < self.progression.max_level) {
            if (c.xp < next_threshold) break;
            c.level += 1;
            next_threshold += self.progression.expForLevel(c.level);
        }
    }

    /// EntityPlayer::get_gameStage for one client (asm.il ~503972). Biome and
    /// quest modifiers are zero: biomes.xml GameStageMod/Bonus and quests.xml
    /// GameStageMod/Bonus are not parsed yet (docs/MISSING_FEATURES.md).
    fn gameStageOf(self: *const Game, slot: usize) i32 {
        if (slot >= self.clients.len) return 1;
        const c = &self.clients[slot];
        const now = self.sim.director.clock.worldTimeBits();
        return assets_gamestages.playerStage(self.gamestages.config, .{
            .level = c.level,
            .days_alive = assets_gamestages.daysAlive(now, c.game_stage_born_world_time, c.level),
        });
    }

    /// EntityPlayer::GetLootStage for one client (asm.il ~504215): level driven,
    /// with no POI tier or biome terms until those tables are parsed.
    fn lootStageOf(self: *const Game, slot: usize) i32 {
        if (slot >= self.clients.len) return 1;
        return assets_gamestages.lootStage(.{ .level = self.clients[slot].level });
    }

    /// GameStageDefinition::CalcGameStageAround (asm.il ~1093351): party stage
    /// over joined players within `radius` of (wx,wz). Stock also requires the
    /// same PrefabInstance; zdtd has no per-player POI tracking, so distance
    /// alone decides. Pass a negative radius for "every joined player".
    fn partyStageAround(self: *const Game, wx: f32, wz: f32, radius: f32) i32 {
        var stages: [max_clients]i32 = undefined;
        var n: usize = 0;
        for (&self.clients, 0..) |*c, i| {
            if (!c.joined) continue;
            if (radius >= 0) {
                const ps = self.sim.playerByPeer(c.slot) orelse continue;
                const dx = self.sim.transform[ps].x - wx;
                const dz = self.sim.transform[ps].z - wz;
                if (dx * dx + dz * dz > radius * radius) continue;
            }
            stages[n] = self.gameStageOf(i);
            n += 1;
        }
        if (n == 0) return 0;
        return assets_gamestages.partyLevel(self.gamestages.config, stages[0..n]);
    }

    /// EntityPlayer::GetHighestPartyLootStage (asm.il ~504467) over all joined
    /// clients. Container contents are shared world state, so a per-viewer
    /// stage would make the same chest differ between clients; the party high
    /// water mark is both stock-shaped and viewer independent.
    fn partyLootStage(self: *const Game) i32 {
        var best: i32 = 1;
        for (&self.clients, 0..) |*c, i| {
            if (!c.joined) continue;
            best = @max(best, self.lootStageOf(i));
        }
        return best;
    }

    /// Current whole world-hour (day*24 + hour), for time-based scheduling.
    fn worldHour(self: *const Game) u64 {
        const clk = self.sim.director.clock;
        return @as(u64, clk.day) * 24 + @as(u64, @intFromFloat(clk.hours));
    }

    /// AirDropFrequency: spawn a supply crate near a player every N game-hours.
    fn tickAirDrop(self: *Game) void {
        if (self.air_drop_interval_hours == 0) return;
        const now = self.worldHour();
        if (self.next_air_drop_hour == 0) {
            self.next_air_drop_hour = now + self.air_drop_interval_hours;
            return;
        }
        if (now < self.next_air_drop_hour) return;
        self.next_air_drop_hour = now + self.air_drop_interval_hours;
        // Drop above the first joined player.
        for (&self.clients) |*cl| {
            if (!cl.joined) continue;
            const ps = self.sim.playerByPeer(cl.slot) orelse continue;
            const t = self.sim.transform[ps];
            if (self.sim.spawnLootBag(t.x, t.y + 2, t.z, 1, 1)) |bag_nid| {
                self.fillLootBagFromTable(bag_nid, "supplyCrate", @intCast(bag_nid));
                self.broadcastLootSpawn(bag_nid) catch {};
                std.debug.print("zdtd: air drop supply crate at ({d:.0},{d:.0}) hour={d}\n", .{ t.x, t.z, now });
            }
            return;
        }
    }

    /// BlockDamageAI / AIBM: attacking zombies chew through a solid block between
    /// them and their target. Scaled by BlockDamageAI (BlockDamageAIBM on blood moon).
    fn tickZombieBlockDamage(self: *Game) void {
        const mult: u32 = if (self.sim.director.bloodmoon_active) self.block_damage_ai_bm else self.block_damage_ai;
        if (mult == 0) return;
        // Damage per bite before scaling (2Hz cadence).
        const base_bite: u32 = 10;
        // Cached zombie group: this pass only damages blocks, never spawns or
        // destroys entities, so the slice stays valid for the whole loop.
        for (ecs.groupSlice(&self.sim, .zombie)) |s| {
            const ai = self.sim.zombie_ai[s];
            if (ai.state != .attack and ai.state != .chase) continue;
            const tgt = self.sim.slotOfNetId(ai.target_id) orelse continue;
            const zt = self.sim.transform[s];
            const tt = self.sim.transform[tgt];
            var dx = tt.x - zt.x;
            var dz = tt.z - zt.z;
            const len = @sqrt(dx * dx + dz * dz);
            if (len < 0.1 or len > 3.0) continue; // only when pressed against cover
            dx /= len;
            dz /= len;
            const bx: i32 = @intFromFloat(@floor(zt.x + dx));
            const bz: i32 = @intFromFloat(@floor(zt.z + dz));
            const by: i32 = @intFromFloat(@floor(zt.y + 1)); // head height
            const solid = self.world.isSolidWorld(bx, by, bz) catch continue;
            if (!solid) continue;
            const id = self.blockIdAtWorld(bx, by, bz);
            if (id == 0) continue;
            const dmg: u16 = @intCast(@min(base_bite * mult / 100, 65535));
            const max_hp = self.maxDamageForBlock(id);
            const total = self.addBlockDamage(bx, by, bz, dmg);
            if (total >= max_hp) {
                self.world.setBlockWorld(bx, by, bz, 0) catch continue;
                self.clearBlockHp(bx, by, bz);
                self.clearBlockRaw(bx, by, bz);
                if (packages.buildSetBlockBody(&self.body_buf, bx, by, bz, 0)) |sb| {
                    self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(bx), @floatFromInt(bz), self.interest_range) catch {};
                } else |_| {}
            }
        }
    }

    /// Block id at world coords (0 = air / unloaded).
    fn blockIdAtWorld(self: *Game, x: i32, y: i32, z: i32) u16 {
        const t = world_store.World.worldToChunk(x, z);
        const ch = self.world.getOrCreate(t.pos) catch return 0;
        return ch.blockAt(t.lx, y, t.lz);
    }

    /// Runtime id of the land-claim keystone block (AssignIds "keystoneBlock").
    fn landClaimBlockId(self: *const Game) ?u16 {
        return self.maxdamage.idByName("keystoneBlock");
    }

    /// The land claim whose protection area covers (x,z), if any.
    fn claimCovering(self: *Game, x: i32, z: i32) ?*LandClaim {
        const half: i32 = @intCast(self.land_claim_size / 2);
        for (self.land_claims[0..self.land_claims_n]) |*claim| {
            if (@abs(x - claim.x) <= half and @abs(z - claim.z) <= half) return claim;
        }
        return null;
    }

    /// Register (or replace) a land claim owned by `owner_entity` at a keystone.
    fn registerClaim(self: *Game, x: i32, y: i32, z: i32, owner_entity: i32) void {
        for (self.land_claims[0..self.land_claims_n]) |*claim| {
            if (claim.x == x and claim.y == y and claim.z == z) {
                claim.owner_entity = owner_entity;
                claim.owner_online = true;
                return;
            }
        }
        // Cap: drop new claim rather than grow heap on place path.
        if (self.land_claims_n >= max_land_claims) return;
        self.land_claims[self.land_claims_n] = .{ .x = x, .y = y, .z = z, .owner_entity = owner_entity };
        self.land_claims_n += 1;
    }

    /// Process pending UDP events (acks free window; data delivered to onData).
    /// Reentrant calls (sendGame / pump_fn mid-onData) only drain control so the
    /// reliable window can free without nested onData corrupting join SM state.
    /// Mid-onData drain uses a private buffer: never `recv_buf`, which still holds
    /// the in-flight uncompressed C2S payload (Package.body aliases).
    /// Post-send ACK drain, every 8th send: pollNetOnce costs a recvfrom
    /// syscall + peer scan per call, and the 64-deep reliable window has ample
    /// headroom between drains. WindowFull retry paths still pump directly.
    fn pollNetAfterSend(self: *Game) void {
        self.sends_since_poll += 1;
        if (self.sends_since_poll >= 8) {
            self.sends_since_poll = 0;
            self.pollNetOnce();
        }
    }

    fn pollNetOnce(self: *Game) void {
        if (self.pumping) {
            // Oversized uncopied payload: any handlePacket that completes a
            // fragment would rewrite peer.deliver_buf under the live bodies.
            if (self.drain_suppressed > 0) return;
            // LiteNet MTU is 1327; 2 KiB covers one datagram with headroom.
            var ctl: [2048]u8 = undefined;
            self.net.drainControl(&ctl, 24);
            return;
        }
        self.pumping = true;
        defer self.pumping = false;
        var n: u32 = 0;
        while (n < 24) : (n += 1) {
            const ev = self.net.poll(&self.recv_buf) catch |err| {
                self.harness.counters.inc(.net_poll_errors);
                const errors = self.harness.counters.get(.net_poll_errors);
                if (errors == 1 or errors % 100 == 0) {
                    std.debug.print("zdtd: net poll error={s} n={d}\n", .{ @errorName(err), errors });
                }
                break;
            };
            switch (ev) {
                // Best-effort: one bad peer must not stop the poll loop.
                .none => break,
                .connected => |p| self.onConnected(p) catch |e| {
                    self.harness.counters.inc(.join_fail);
                    std.debug.print(
                        "zdtd: onConnected failed local_id={d}: {s}\n",
                        .{ p.local_id, @errorName(e) },
                    );
                },
                .data => |d| self.onData(d.peer, d.payload) catch |err| {
                    self.harness.counters.inc(.net_payload_errors);
                    const errors = self.harness.counters.get(.net_payload_errors);
                    if (errors == 1 or errors % 100 == 0) {
                        std.debug.print(
                            "zdtd: payload failed local_id={d} error={s} n={d}\n",
                            .{ d.peer.local_id, @errorName(err), errors },
                        );
                    }
                },
            }
        }
    }

    /// MaxDamage from blocks.xml+materials via maxdamage table. Generic floor when unknown.
    fn maxDamageForBlock(self: *const Game, block_id: u16) u16 {
        if (block_id == 0) return 1;
        if (self.maxdamage.maxDamage(block_id)) |hp| return hp;
        // Table loaded (by_id or name map): fail closed to soft generic, no pin id HP table.
        if (self.maxdamage.by_id.count() > 0 or self.maxdamage.id_by_name.count() > 0) return 100;
        // Offline / empty catalog only: soft defaults by id band (not stock truth).
        if (block_id < 256) return 100;
        if (block_id >= 18000 and block_id < 20000) return 500;
        if (block_id >= 24000) return 50;
        return 500;
    }

    fn packBlockKey(x: i32, y: i32, z: i32) u64 {
        const xu: u64 = @as(u32, @bitCast(x));
        const yu: u64 = @as(u16, @truncate(@as(u32, @bitCast(y))));
        const zu: u64 = @as(u32, @bitCast(z));
        return (xu << 32) | (yu << 16) | (zu & 0xffff);
    }

    fn getBlockHp(self: *const Game, x: i32, y: i32, z: i32) u16 {
        const key = packBlockKey(x, y, z);
        var i: usize = 0;
        while (i < self.block_hp_n) : (i += 1) {
            if (self.block_hp_key[i] == key) return self.block_hp[i];
        }
        return 0;
    }

    /// Store absolute BlockValue.damage (stock DamageBlock number line).
    fn setBlockHp(self: *Game, x: i32, y: i32, z: i32, abs: u16) void {
        const key = packBlockKey(x, y, z);
        var i: usize = 0;
        while (i < self.block_hp_n) : (i += 1) {
            if (self.block_hp_key[i] != key) continue;
            self.block_hp[i] = abs;
            return;
        }
        if (self.block_hp_n >= self.block_hp_key.len) {
            var j: usize = 1;
            while (j < self.block_hp_n) : (j += 1) {
                self.block_hp_key[j - 1] = self.block_hp_key[j];
                self.block_hp[j - 1] = self.block_hp[j];
            }
            self.block_hp_n -= 1;
        }
        self.block_hp_key[self.block_hp_n] = key;
        self.block_hp[self.block_hp_n] = abs;
        self.block_hp_n += 1;
    }

    fn addBlockDamage(self: *Game, x: i32, y: i32, z: i32, dmg: u16) u16 {
        const cur = self.getBlockHp(x, y, z);
        const sum: u32 = @as(u32, cur) + dmg;
        const abs: u16 = @intCast(@min(sum, 65535));
        self.setBlockHp(x, y, z, abs);
        return abs;
    }

    fn clearBlockHp(self: *Game, x: i32, y: i32, z: i32) void {
        const key = packBlockKey(x, y, z);
        var i: usize = 0;
        while (i < self.block_hp_n) : (i += 1) {
            if (self.block_hp_key[i] != key) continue;
            self.block_hp_n -= 1;
            self.block_hp_key[i] = self.block_hp_key[self.block_hp_n];
            self.block_hp[i] = self.block_hp[self.block_hp_n];
            return;
        }
    }

    fn setBlockRaw(self: *Game, x: i32, y: i32, z: i32, raw: u32) void {
        const key = packBlockKey(x, y, z);
        var i: usize = 0;
        while (i < self.block_raw_n) : (i += 1) {
            if (self.block_raw_key[i] == key) {
                self.block_raw[i] = raw;
                return;
            }
        }
        if (self.block_raw_n >= self.block_raw_key.len) {
            var j: usize = 1;
            while (j < self.block_raw_n) : (j += 1) {
                self.block_raw_key[j - 1] = self.block_raw_key[j];
                self.block_raw[j - 1] = self.block_raw[j];
            }
            self.block_raw_n -= 1;
        }
        self.block_raw_key[self.block_raw_n] = key;
        self.block_raw[self.block_raw_n] = raw;
        self.block_raw_n += 1;
    }

    /// Stored BlockValue.rawData for a cell, or 0 when the block was placed
    /// without meta (the sparse store only holds cells that carry it).
    fn blockRawAt(self: *const Game, x: i32, y: i32, z: i32) u32 {
        const key = packBlockKey(x, y, z);
        var i: usize = 0;
        while (i < self.block_raw_n) : (i += 1) {
            if (self.block_raw_key[i] == key) return self.block_raw[i];
        }
        return 0;
    }

    fn clearBlockRaw(self: *Game, x: i32, y: i32, z: i32) void {
        const key = packBlockKey(x, y, z);
        var i: usize = 0;
        while (i < self.block_raw_n) : (i += 1) {
            if (self.block_raw_key[i] != key) continue;
            self.block_raw_n -= 1;
            self.block_raw_key[i] = self.block_raw_key[self.block_raw_n];
            self.block_raw[i] = self.block_raw[self.block_raw_n];
            return;
        }
    }

    /// Persist sparse block meta (rotation raw + accumulated damage) so doors/
    /// shapes and partial block damage survive restart. File: "ZBM1" | u16 raw_n |
    /// (key u64 + raw u32)* | u16 hp_n | (key u64 + hp u16)*.
    /// Keys are sorted so bytes do not depend on insert/remove history (DST).
    fn saveBlockMeta(self: *const Game) !void {
        var path: [512]u8 = undefined;
        const p = try std.fmt.bufPrint(&path, "{s}/blockmeta.zbm", .{self.world.world_dir});
        var buf: [4096]u8 = undefined;
        var o: usize = 0;
        @memcpy(buf[0..4], "ZBM1");
        o = 4;

        // Sort raw keys (pairs) by key for stable disk order.
        var raw_ord: [self.block_raw_key.len]u16 = undefined;
        const raw_n = self.block_raw_n;
        var ri: usize = 0;
        while (ri < raw_n) : (ri += 1) raw_ord[ri] = @intCast(ri);
        std.mem.sort(u16, raw_ord[0..raw_n], self, struct {
            fn less(g: *const Game, a: u16, b: u16) bool {
                return g.block_raw_key[a] < g.block_raw_key[b];
            }
        }.less);

        std.mem.writeInt(u16, buf[o..][0..2], @intCast(raw_n), .little);
        o += 2;
        for (raw_ord[0..raw_n]) |idx| {
            if (o + 12 > buf.len) break;
            std.mem.writeInt(u64, buf[o..][0..8], self.block_raw_key[idx], .little);
            std.mem.writeInt(u32, buf[o + 8 ..][0..4], self.block_raw[idx], .little);
            o += 12;
        }
        if (o + 2 > buf.len) return error.WriteFailed;

        var hp_ord: [self.block_hp_key.len]u16 = undefined;
        const hp_n = self.block_hp_n;
        var hi: usize = 0;
        while (hi < hp_n) : (hi += 1) hp_ord[hi] = @intCast(hi);
        std.mem.sort(u16, hp_ord[0..hp_n], self, struct {
            fn less(g: *const Game, a: u16, b: u16) bool {
                return g.block_hp_key[a] < g.block_hp_key[b];
            }
        }.less);

        std.mem.writeInt(u16, buf[o..][0..2], @intCast(hp_n), .little);
        o += 2;
        for (hp_ord[0..hp_n]) |idx| {
            if (o + 10 > buf.len) break;
            std.mem.writeInt(u64, buf[o..][0..8], self.block_hp_key[idx], .little);
            std.mem.writeInt(u16, buf[o + 8 ..][0..2], self.block_hp[idx], .little);
            o += 10;
        }
        try io_fs.writeFile(self.allocator, p, buf[0..o]);
    }

    fn loadBlockMeta(self: *Game) !void {
        var path: [512]u8 = undefined;
        const p = try std.fmt.bufPrint(&path, "{s}/blockmeta.zbm", .{self.world.world_dir});
        const data = io_fs.readFileAll(self.allocator, p) catch |err| switch (err) {
            error.FileNotFound => return error.OpenFailed,
            else => return err,
        };
        defer self.allocator.free(data);
        if (data.len < 6 or !std.mem.eql(u8, data[0..4], "ZBM1")) return error.ReadFailed;
        var o: usize = 4;
        const rn = std.mem.readInt(u16, data[o..][0..2], .little);
        o += 2;
        if (o + @as(usize, rn) * 12 > data.len) return error.ReadFailed;
        self.block_raw_n = @min(@as(usize, rn), self.block_raw_key.len);
        for (0..self.block_raw_n) |i| {
            self.block_raw_key[i] = std.mem.readInt(u64, data[o..][0..8], .little);
            self.block_raw[i] = std.mem.readInt(u32, data[o + 8 ..][0..4], .little);
            o += 12;
        }
        if (o + 2 > data.len) return error.ReadFailed;
        const hn = std.mem.readInt(u16, data[o..][0..2], .little);
        o += 2;
        if (o + @as(usize, hn) * 10 > data.len) return error.ReadFailed;
        self.block_hp_n = @min(@as(usize, hn), self.block_hp_key.len);
        for (0..self.block_hp_n) |i| {
            self.block_hp_key[i] = std.mem.readInt(u64, data[o..][0..8], .little);
            self.block_hp[i] = std.mem.readInt(u16, data[o + 8 ..][0..2], .little);
            o += 10;
        }
    }

    /// Lock stale after this many ns without unlock (holder disconnect still clears immediately).
    const lock_stale_ns: u64 = 120_000_000_000; // 120s

    fn packLockPos(x: i32, y: i32, z: i32) u64 {
        // 21 bits each axis signed into 63 bits (enough for world coords).
        const ux: u64 = @as(u32, @bitCast(x));
        const uy: u64 = @as(u32, @bitCast(y));
        const uz: u64 = @as(u32, @bitCast(z));
        return (ux & 0x1fffff) | ((uy & 0x1fffff) << 21) | ((uz & 0x1fffff) << 42);
    }

    fn firstLockTargetPos(targets_blob: []const u8) ?struct { x: i32, y: i32, z: i32 } {
        if (targets_blob.len < 4) return null;
        var tr: wire_binary.Reader = .{ .data = targets_blob };
        const n = tr.readI32() catch return null;
        var ti: i32 = 0;
        while (ti < n) : (ti += 1) {
            const present = tr.readByte() catch return null;
            if (present == 0) continue;
            const ty = tr.readByte() catch return null;
            if (ty == 0 or ty == 1) {
                const x = tr.readI32() catch return null;
                const y = tr.readI32() catch return null;
                const z = tr.readI32() catch return null;
                return .{ .x = x, .y = y, .z = z };
            } else if (ty == 2) {
                _ = tr.readI32() catch return null;
            } else if (ty == 3) {
                if (tr.remaining() < 16) return null;
                tr.pos += 16;
            } else return null;
        }
        return null;
    }

    fn clearLockSlot(self: *Game, ch: usize) void {
        if (ch >= self.lock_channel.len) return;
        self.lock_channel[ch] = -1;
        self.lock_holder_entity[ch] = -1;
        self.lock_granted_ns[ch] = 0;
        self.lock_pos_key[ch] = 0;
    }

    fn clearLocksForPeer(self: *Game, peer_slot: usize) void {
        const ps: i32 = @intCast(peer_slot);
        for (&self.lock_channel, 0..) |*h, i| {
            if (h.* == ps) self.clearLockSlot(i);
        }
    }

    /// Drop locks held longer than lock_stale_ns (tick path).
    fn reapStaleLocks(self: *Game) void {
        const now = clock.monoNs();
        for (&self.lock_channel, 0..) |h, i| {
            if (h < 0) continue;
            const g = self.lock_granted_ns[i];
            if (g == 0) continue;
            if (now -% g >= lock_stale_ns) self.clearLockSlot(i);
        }
    }

    fn reapStalePeers(self: *Game) void {
        const now = clock.monoNs();
        const stale_ns: u64 = self.peer_stale_ms *% 1_000_000;
        for (&self.clients) |*c| {
            const p = c.peer orelse continue;
            if (!p.alive) {
                self.harness.counters.inc(.stale_peers_reaped);
                std.debug.print(
                    "zdtd: peer reaped dead local_id={d} slot={d} entity={d}\n",
                    .{ p.local_id, c.slot, c.entity_id },
                );
                self.clearLocksForPeer(c.slot);
                c.* = .{};
                self.refreshInfoPlayers();
                continue;
            }
            if (p.last_recv_ns == 0) continue;
            if (now -% p.last_recv_ns > stale_ns) {
                self.harness.counters.inc(.stale_peers_reaped);
                std.debug.print(
                    "zdtd: peer reaped stale local_id={d} slot={d} entity={d} idle_ms={d}\n",
                    .{ p.local_id, c.slot, c.entity_id, (now -% p.last_recv_ns) / 1_000_000 },
                );
                p.alive = false;
                p.authenticated = false;
                for (&p.pending) |*slot| slot.used = false;
                p.local_window_start = p.local_seq;
                self.clearLocksForPeer(c.slot);
                c.* = .{};
                self.refreshInfoPlayers();
            }
        }
    }

    fn peerIpKey(peer: *const ln_peer.Peer) u32 {
        // Host-order key for ban/rate tables (IPv4 loopback = 0x7f000001). Port is
        // excluded so ban/rate apply per host. IPv4-mapped IPv6 shares the IPv4 key.
        return switch (peer.addr) {
            .ip4 => |a| std.mem.readInt(u32, &a.bytes, .big),
            .ip6 => |a| blk: {
                // ::ffff:a.b.c.d → same key as native IPv4 a.b.c.d (ban dual-stack bypass).
                if (std.mem.eql(u8, a.bytes[0..12], &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff })) {
                    break :blk std.mem.readInt(u32, a.bytes[12..16], .big);
                }
                // Stable FNV-1a of the 16-byte address; never 0 (skip sentinel).
                var h: u32 = 2166136261;
                for (a.bytes) |b| {
                    h ^= b;
                    h *%= 16777619;
                }
                if (h == 0 or h == 0x7f000001) h ^= 0x80000000;
                break :blk h;
            },
        };
    }

    /// Stock ~500ms/IP; return true if join should be rejected.
    fn joinRateLimited(self: *Game, ip: u32) bool {
        if (ip == 0) return false;
        // Loopback multi-bot / unit tests share 127.0.0.1: do not throttle.
        if (ip == 0x7f000001) return false;
        const now_ms: u64 = clock.monoNs() / 1_000_000;
        const gap_ms: u64 = 500;
        var i: usize = 0;
        while (i < self.join_ip_n) : (i += 1) {
            if (self.join_ip[i] != ip) continue;
            if (now_ms -% self.join_ip_ms[i] < gap_ms) return true;
            self.join_ip_ms[i] = now_ms;
            return false;
        }
        if (self.join_ip_n < self.join_ip.len) {
            self.join_ip[self.join_ip_n] = ip;
            self.join_ip_ms[self.join_ip_n] = now_ms;
            self.join_ip_n += 1;
        }
        return false;
    }

    fn isBanned(self: *const Game, ip: u32) bool {
        if (ip == 0) return false;
        var i: usize = 0;
        while (i < self.ban_n) : (i += 1) {
            if (self.ban_ip[i] == ip) return true;
        }
        return false;
    }

    fn banIp(self: *Game, ip: u32) void {
        if (ip == 0 or self.isBanned(ip)) return;
        if (self.ban_n >= self.ban_ip.len) return;
        self.ban_ip[self.ban_n] = ip;
        self.ban_n += 1;
    }

    fn unbanIp(self: *Game, ip: u32) void {
        var i: usize = 0;
        while (i < self.ban_n) : (i += 1) {
            if (self.ban_ip[i] != ip) continue;
            self.ban_n -= 1;
            self.ban_ip[i] = self.ban_ip[self.ban_n];
            self.ban_ip[self.ban_n] = 0;
            return;
        }
    }

    fn pumpAcks(ctx: ?*anyopaque) void {
        const self: *Game = @ptrCast(@alignCast(ctx.?));
        // pollNetOnce reentrancy: control-only drain when already pumping.
        self.pollNetOnce();
    }

    fn onConnected(self: *Game, peer: *ln_peer.Peer) !void {
        const c = self.clientFor(peer) orelse {
            // Full or no free slot: reject without taking down the tick loop.
            self.harness.counters.inc(.join_fail);
            std.debug.print(
                "zdtd: join rejected (no client slot) local_id={d} max_players={d}\n",
                .{ peer.local_id, self.max_players },
            );
            peer.alive = false;
            return;
        };
        peer.pump_fn = &pumpAcks;
        peer.pump_ctx = self;
        const ip = peerIpKey(peer);
        if (self.isBanned(ip)) {
            std.debug.print("zdtd: ban reject local_id={d}\n", .{peer.local_id});
            self.harness.counters.inc(.join_fail);
            peer.alive = false;
            c.* = .{};
            return;
        }
        if (self.joinRateLimited(ip)) {
            std.debug.print("zdtd: join rate-limit local_id={d}\n", .{peer.local_id});
            self.harness.counters.inc(.join_fail);
            peer.alive = false;
            c.* = .{};
            return;
        }
        var ch: [17]u8 = undefined;
        wire_frame.buildChallenge(&ch, c.challenge);
        peer.sendReliable(&self.net.sock, &ch) catch |err| {
            self.harness.counters.inc(.net_send_errors);
            self.harness.counters.inc(.join_fail);
            std.debug.print("zdtd: challenge send failed local_id={d} error={s}\n", .{ peer.local_id, @errorName(err) });
            return;
        };
        std.debug.print("zdtd: peer connected local_id={d} → challenge sent\n", .{peer.local_id});
    }

    fn onData(self: *Game, peer: *ln_peer.Peer, payload: []const u8) anyerror!void {
        // Hold pumping for the whole handler so sendGame / pump_fn only
        // drainControl (no nested onData, no second parse into inflate_storage).
        const was_pumping = self.pumping;
        self.pumping = true;
        defer self.pumping = was_pumping;

        const c = self.clientFor(peer) orelse return;
        self.harness.counters.add(.net_packets_in, 1);
        self.harness.counters.add(.net_bytes_in, payload.len);

        if (!c.authed_challenge) {
            if (wire_frame.isChallenge(payload) and std.mem.eql(u8, payload[1..17], &c.challenge)) {
                c.authed_challenge = true;
                peer.authenticated = true;
                const body = try packages.buildPackageIdsBody(&self.body_buf, .{}, &packages.default_mappings);
                try self.sendGame(peer, "NetPackagePackageIds", body);
                // Immediate resend once so PackageIds is not lost before first ack.
                peer.resendPending(&self.net.sock) catch self.harness.counters.inc(.net_send_errors);
                std.debug.print("zdtd: challenge ok local_id={d} package_maps={d}\n", .{ peer.local_id, packages.default_mappings.len });
                // Replay any game payload that raced ahead of the challenge echo.
                if (c.preauth_len > 0) {
                    const saved = c.preauth_buf[0..c.preauth_len];
                    c.preauth_len = 0;
                    try self.dispatchGamePayload(c, peer, saved);
                }
            } else if (wire_frame.isChallenge(payload)) {
                std.debug.print("zdtd: challenge mismatch local_id={d} payload_len={d}\n", .{ peer.local_id, payload.len });
            } else if (payload.len > 0 and payload.len <= c.preauth_buf.len) {
                @memcpy(c.preauth_buf[0..payload.len], payload);
                c.preauth_len = payload.len;
            }
            return;
        }
        if (wire_frame.isChallenge(payload)) return;
        try self.dispatchGamePayload(c, peer, payload);
    }

    fn dispatchGamePayload(self: *Game, c: *Client, peer: *ln_peer.Peer, payload: []const u8) !void {
        // Package.body slices alias the payload for the whole handle loop.
        // Uncompressed C2S aliases recv_buf; fragmented aliases peer.deliver_buf.
        // Copy into payload_hold so mid-handler ACK drains cannot clobber bodies.
        const stable: []const u8 = blk: {
            if (payload.len <= self.payload_hold.len) {
                @memcpy(self.payload_hold[0..payload.len], payload);
                break :blk self.payload_hold[0..payload.len];
            }
            // Rare oversized multi-fragment C2S: keep original pointer and
            // suppress reentrant drain for the duration (see drain_suppressed).
            self.drain_suppressed +%= 1;
            break :blk payload;
        };
        defer if (payload.len > self.payload_hold.len) {
            self.drain_suppressed -%= 1;
        };

        var pkgs: [16]wire_frame.Package = undefined;
        const n = wire_frame.parseChannelPayload(stable, &pkgs);
        if (n == 0 and stable.len > 0) {
            // Frame header only (8 bytes): avoid dumping string fields (names, etc.).
            var hex: [24]u8 = undefined;
            const show = @min(stable.len, 8);
            var hi: usize = 0;
            var bi: usize = 0;
            while (bi < show and hi + 2 <= hex.len) : (bi += 1) {
                const s = std.fmt.bufPrint(hex[hi..], "{x:0>2}", .{stable[bi]}) catch break;
                hi += s.len;
            }
            if (stable.len >= 9) {
                const psz = std.mem.readInt(i32, stable[1..5], .little);
                std.debug.print("zdtd: unparsed game payload len={d} head={s} ch={d} psz={d} comp={d} enc={d} cnt={d}\n", .{
                    stable.len,
                    hex[0..hi],
                    stable[0],
                    psz,
                    stable[5],
                    stable[6],
                    std.mem.readInt(u16, stable[7..9], .little),
                });
            } else {
                std.debug.print("zdtd: unparsed game payload len={d} head={s}\n", .{ stable.len, hex[0..hi] });
            }
            // Retry if payload omitted leading channel byte.
            if (stable.len >= 10) {
                var alt: [16]wire_frame.Package = undefined;
                var tmp: [8192]u8 = undefined;
                if (stable.len + 1 <= tmp.len) {
                    tmp[0] = 0;
                    @memcpy(tmp[1..][0..stable.len], stable);
                    const n2 = wire_frame.parseChannelPayload(tmp[0 .. stable.len + 1], &alt);
                    if (n2 > 0) {
                        std.debug.print("zdtd: alt-parse got {d} pkgs id0={d}\n", .{ n2, alt[0].id });
                        var j: usize = 0;
                        while (j < n2) : (j += 1) {
                            try self.handlePackage(c, peer, alt[j].id, alt[j].body);
                        }
                        return;
                    }
                }
            }
        }
        var i: usize = 0;
        while (i < n) : (i += 1) {
            try self.handlePackage(c, peer, pkgs[i].id, pkgs[i].body);
        }
    }

    /// Stock GameServerInfo.ToString(true) body used as NetPackagePlayerLoginAnswer.data.
    fn buildLoginGsiText(self: *Game, buf: []u8) ![]const u8 {
        const info = serverinfo_tcp.ServerInfo{
            .game_name = "zdtd",
            .game_host = "zdtd",
            .level_name = self.world_name,
            .ip = "127.0.0.1",
            .info_port = self.info_port,
            .max_players = self.max_players,
            .current_players = @intCast(self.countJoined()),
            .server_version = version.stock_wire_announce,
            .world_size = 6144,
            .eac_enabled = false,
            .password_protected = self.password.len > 0,
        };
        return try serverinfo_tcp.buildInfoText(buf, info);
    }

    fn handlePackage(self: *Game, c: *Client, peer: *ln_peer.Peer, id: u16, body: []const u8) !void {
        if (id >= packages.default_mappings.len) {
            std.debug.print("zdtd: unmapped package local_id={d} package_id={d} body_len={d}\n", .{ peer.local_id, id, body.len });
            return;
        }
        const name = packages.default_mappings[id];
        const sp = self.world.primarySpawn();

        // Phase gate: connecting/joined (pre-enter) only join-SM packages.
        // Playing (entered) allows all names; typed handlers still validate.
        // Phase is always Hard (never apply play C2S pre-enter).
        {
            const phase = phase_gate.phaseOf(c.joined, c.entered);
            if (!phase_gate.allowed(phase, name)) {
                self.harness.counters.inc(.phase_rejects);
                self.noteEvidence(c, peer.local_id, c.entity_id, .phase, .hard, .none, 1, 0);
                // First + every 100th: join-SM bugs show as phase spikes with no log.
                const n = self.harness.counters.get(.phase_rejects);
                if (n == 1 or n % 100 == 0) {
                    std.debug.print(
                        "zdtd: phase reject n={d} pkg={s} joined={} entered={} local_id={d}\n",
                        .{ n, name, c.joined, c.entered, peer.local_id },
                    );
                }
                return;
            }
        }

        if (std.mem.eql(u8, name, "NetPackagePlayerLogin")) {
            // ServerPassword already enforced at LiteNet ConnectRequest (net.server_password).
            // Stock PlayerAllowed replaces LastGameServerInfo with GameServerInfo(loginAnswer.data).
            // data must be full GSI ToString text (not "ok") so worldInfoCo can parse ServerVersion.
            const gsi = try self.buildLoginGsiText(self.body_buf[4096..8192]);
            if (c.joined and c.entity_id > 0) {
                const ans = try packages.buildLoginAnswerBody(self.body_buf[0..2048], true, gsi);
                try self.sendGame(peer, "NetPackagePlayerLoginAnswer", ans);
                const spawned = try packages.buildSpawnedBody(
                    self.body_buf[256..384],
                    @intFromEnum(packages.RespawnType.join_multiplayer),
                    sp.x,
                    sp.y,
                    sp.z,
                    c.entity_id,
                );
                try self.sendGame(peer, "NetPackagePlayerSpawnedInWorld", spawned);
                return;
            }
            // Name (save key) plus both platform identities, per asm.il 832140.
            if (body.len > 1) {
                if (packages.parsePlayerLogin(body, c.name[0..])) |login| {
                    // Strip C0/DEL so login names cannot inject CR/LF into admin
                    // replies, audit lines, or GSI-adjacent operator surfaces.
                    c.name_len = sanitizePlayerName(c.name[0..], login.name);
                    c.puid_primary = login.internalId();
                    c.puid_native = login.native;
                } else |_| {
                    // A login body zdtd cannot fully decode still gets its name
                    // read, because refusing the join would lock the player out
                    // over a field the server never trusts anyway. The identity
                    // stays null and the deterministic fallback below applies.
                    self.harness.counters.inc(.c2s_malformed);
                    var r: wire_binary.Reader = .{ .data = body };
                    if (r.readString(c.name[0..])) |nm| {
                        c.name_len = sanitizePlayerName(c.name[0..], nm);
                    } else |_| {}
                }
            }
            // Identity ban (`ban add`) outlives the connection an IP ban catches,
            // so it is checked once the login name is known.
            if (c.name_len != 0 and self.ban_list.banned(c.name[0..c.name_len], clock.wallSeconds())) {
                self.harness.counters.inc(.join_fail);
                self.dropClientSlot(c.slot);
                return;
            }
            const ans = try packages.buildLoginAnswerBody(self.body_buf[0..2048], true, gsi);
            try self.sendGame(peer, "NetPackagePlayerLoginAnswer", ans);
            const surf0 = self.spawnSurface(sp.x, sp.z);
            const was_joined = c.joined;
            const eid = self.sim.spawnPlayer(@floatFromInt(surf0.x), @floatFromInt(surf0.y), @floatFromInt(surf0.z), @intCast(c.slot)) orelse return;
            c.entity_id = eid;
            c.joined = true;
            c.view_radius = self.view_radius;
            // PlayerDataFile::CopyTo clamps a not-yet-set bornAt down to the
            // current world time (asm.il ~1975949), so a fresh session starts
            // at zero days survived rather than at the -1 sentinel.
            if (!was_joined) c.game_stage_born_world_time = self.sim.director.clock.worldTimeBits();
            self.tryRestorePlayer(c);
            // Stock: LoginAnswer only. Configs must arrive after StartAsClient starts
            // WaitForConfigsFromServer (which resets WasReceivedFromServer). That is
            // after RequestToEnterGame is sent from the client.
            self.refreshInfoPlayers();
            self.harness.counters.inc(.join_ok);
            if (was_joined) {
                self.harness.counters.inc(.reconnects);
                self.noteEvidence(c, peer.local_id, eid, .flood, .info, .none, 1, 0);
            }
            // Name length only in logs (name stays on admin listplayers / webui).
            std.debug.print("zdtd: PlayerLogin name_len={d} entity={d} body={d}\n", .{ c.name_len, eid, body.len });
            return;
        }
        // Stock: StartAsClient starts config-wait coroutine, then RequestToEnterGame.
        // Send local ConfigFiles now so the wait can finish; then WorldInfo.
        if (std.mem.eql(u8, name, "NetPackageRequestToEnterGame")) {
            std.debug.print("zdtd: RequestToEnterGame entity={d}\n", .{c.entity_id});
            if (c.entity_id <= 0) {
                const surf_e = self.spawnSurface(sp.x, sp.z);
                c.entity_id = self.sim.spawnPlayer(@floatFromInt(surf_e.x), @floatFromInt(surf_e.y), @floatFromInt(surf_e.z), @intCast(c.slot)) orelse return;
                c.joined = true;
                self.tryRestorePlayer(c);
            }
            // Before the configs: the client only runs Block::AssignIds after the
            // ConfigFile package (WorldStaticData LoadBlocks IL_0058, asm.il
            // 2014542), and stock sends the mapping at this same point.
            self.sendBlockIdMapping(peer);
            try self.sendLocalConfigFiles(peer);
            const wi = try packages.buildWorldInfoBody(self.body_buf[0..256], self.world_name, 6144, 6144, sp.x, sp.y, sp.z, 0);
            try self.sendGame(peer, "NetPackageWorldInfo", wi);
            try self.sendWorldSpawnPoints(peer);
            const wt = try packages.buildWorldTimeBody(self.body_buf[1024..1040], self.sim.director.clock.worldTimeBits());
            try self.sendGame(peer, "NetPackageWorldTime", wt);
            try self.sendGameStats(peer);
            // NetPackageWeather: only after client WeatherManager.InitPackages (post-enter).
            // Early send → NCSimple "parsed 2 vs expected 117" and disconnect.
            // Fixed-size clients only apply trees from S2C deco (no local random gen),
            // and this is the client's only deco window (see sendDecoAroundSpawn).
            try self.sendDecoAroundSpawn(c, peer, sp.x, sp.z);
            return;
        }
        if (std.mem.eql(u8, name, "NetPackageAuthConfirmation")) {
            // Client echoes empty AuthConfirmation; stock AuthFinalizer expects the round-trip.
            // Nothing to apply; acknowledge by no-op so the session stays live.
            std.debug.print("zdtd: AuthConfirmation body={d}\n", .{body.len});
            return;
        }
        // worldInfoCo: after configs, client RequestWorldSignDataFromServer and blocks until
        // SignDataResponse(isLastBatch=true). Send prefab library shells (guid+name, 0 layers).
        if (std.mem.eql(u8, name, "NetPackageSignDataRequest")) {
            try self.sendSignDataBatches(peer);
            return;
        }
        // worldInfoCo: after createWorld, client sends WorldInitInfoRequest and waits for
        // worldInitInfoReceived (set by ProcessPackage of WorldInitInfo).
        if (std.mem.eql(u8, name, "NetPackageWorldInitInfoRequest")) {
            // Same hang class as DynamicClientArrive: WorldInitInfo after enter can
            // restart createWorld and leave the client on Creating player.
            if (c.entered) return;
            const wi = try packages.buildWorldInitInfoEmpty(self.body_buf[0..16]);
            try self.sendGame(peer, "NetPackageWorldInitInfo", wi);
            std.debug.print("zdtd: WorldInitInfoRequest -> empty entity={d}\n", .{c.entity_id});
            // Stream from here, not at spawn. The client needs collision meshes
            // for the spawn chunk and its 8 neighbours before
            // World.IsPositionAvailable succeeds; until then updateRespawn parks
            // in ClampingToValidWorldPos. OnAddedToWorld meanwhile sets
            // EntityAlive.bSpawned, and updateRespawn short-circuits to Done on
            // that, abandoning the sequence before it closes the loading screen.
            c.world_ready = true;
            return;
        }
        // createWorld posts DynamicClientArrive. Prefer RequestToSpawnPlayer for the
        // join bundle. Re-sending WorldInitInfo after PlayerId restarts createWorld
        // mid-session and leaves the stock client on "Creating player".
        if (std.mem.eql(u8, name, "NetPackageDynamicClientArrive")) {
            if (c.entered) {
                // Already in-world. Stock DynamicClientArrive is dynamic-mesh
                // inventory reconcile (not implemented); join SM must not re-answer.
                return;
            }
            // Fallback spawn path when RequestToSpawnPlayer never arrives / fails parse.
            if (c.entity_id > 0) {
                c.view_radius = if (c.view_radius < 1) self.view_radius else c.view_radius;
                try self.sendJoinBundle(c, peer, sp.x, sp.y, sp.z, c.entity_id);
                std.debug.print("zdtd: DynamicClientArrive -> join bundle (spawn fallback) entity={d}\n", .{c.entity_id});
            } else {
                const wi = try packages.buildWorldInitInfoEmpty(self.body_buf[0..16]);
                try self.sendGame(peer, "NetPackageWorldInitInfo", wi);
                std.debug.print("zdtd: DynamicClientArrive -> WorldInitInfo empty (pre-spawn) entity={d}\n", .{c.entity_id});
                // Head start on the spawn area. createWorld posts this package, so
                // the client's ChunkCache exists and will keep these. The client
                // needs collision meshes (Chunk.GetAvailable == IsCollisionMeshGenerated)
                // for the spawn chunk and its 8 neighbours before
                // World.IsPositionAvailable succeeds; until then updateRespawn parks
                // in ClampingToValidWorldPos. Meanwhile OnAddedToWorld sets
                // EntityAlive.bSpawned, and updateRespawn's first line short-circuits
                // to Done on that, abandoning the sequence before it closes the
                // loading screen. Streaming only at spawn time loses that race by
                // ~40s; stock has the area meshed well before the player appears.
                if (self.wire_chunks) {
                    const r0: i32 = if (c.view_radius < 1) self.chunk_stream_radius_min else @min(c.view_radius, self.chunk_stream_radius_max);
                    try self.sendSpawnArea(peer, sp.x, sp.z, r0);
                }
            }
            return;
        }
        if (std.mem.eql(u8, name, "NetPackageRequestToSpawnPlayer")) {
            if (packages.parseRequestToSpawnPlayer(body)) |req| {
                // chunkViewDim is in chunks; clamp for reliable window (join uses ≤2).
                var dim: i32 = req.chunk_view_dim;
                if (dim < 1) dim = self.view_radius;
                if (dim > 8) dim = 8;
                c.view_radius = dim;
            } else |_| {
                c.view_radius = self.view_radius;
            }
            const surf = self.spawnSurface(sp.x, sp.z);
            if (c.entity_id <= 0) {
                c.entity_id = self.sim.spawnPlayer(@floatFromInt(surf.x), @floatFromInt(surf.y), @floatFromInt(surf.z), @intCast(c.slot)) orelse return;
            } else if (self.sim.slotOfNetId(c.entity_id)) |si| {
                // Respawn heal/teleport only when actually dead; a live player
                // resending RequestToSpawn must not get a free heal + escape.
                if (!self.sim.alive[si] or self.sim.health[si].hp <= 0) {
                    // Only sanctioned un-kill: a raw alive[] write would leave
                    // the cached kind group out of sync.
                    // EntityPlayer::SetAlive (asm.il ~503838): a death costs
                    // daysAliveChangeWhenKilled days off the survival streak.
                    c.game_stage_born_world_time = assets_gamestages.bornAtAfterDeath(
                        self.gamestages.config,
                        self.sim.director.clock.worldTimeBits(),
                        c.game_stage_born_world_time,
                    );
                    self.sim.reviveSlot(si);
                    // The client drops its own remove_on_death buffs when it
                    // dies (BuffClass::RemoveOnDeath, asm.il 1371585), so drop
                    // ours silently rather than broadcasting removals it made.
                    if (self.sim.mask[si].buffs) _ = ecs.buff.clearOnDeath(&self.sim.buffs[si]);
                    self.sim.health[si] = .{ .hp = 100, .max_hp = 100 };
                    self.sim.transform[si] = .{
                        .x = @as(f32, @floatFromInt(surf.x)),
                        .y = @as(f32, @floatFromInt(surf.y)) + 0.08,
                        .z = @as(f32, @floatFromInt(surf.z)),
                        .yaw = 0,
                    };
                    if (packages.buildEntityStatBody(self.body_buf[512..640], c.entity_id, 100, 100)) |hb| {
                        try self.sendGame(peer, "NetPackageEntityStatChanged", hb);
                    } else |_| {}
                    if (packages.buildEntityTeleportBody(&self.body_buf, c.entity_id, @floatFromInt(sp.x), @floatFromInt(sp.y), @floatFromInt(sp.z), 0, 0, 0, true)) |tb| {
                        try self.sendGame(peer, "NetPackageEntityTeleport", tb);
                    } else |_| {}
                    if (packages.buildEntityTeleportBody(&self.body_buf, c.entity_id, @as(f32, @floatFromInt(surf.x)), @as(f32, @floatFromInt(surf.y)) + 0.08, @as(f32, @floatFromInt(surf.z)), 0, 0, 0, true)) |tb| {
                        try self.sendGame(peer, "NetPackageEntityTeleport", tb);
                    } else |_| {}
                    const spawned = try packages.buildSpawnedBody(
                        self.body_buf[256..384],
                        @intFromEnum(packages.RespawnType.died),
                        surf.x,
                        surf.y,
                        surf.z,
                        c.entity_id,
                    );
                    try self.sendGame(peer, "NetPackagePlayerSpawnedInWorld", spawned);
                    std.debug.print("zdtd: respawn heal entity={d}\n", .{c.entity_id});
                }
            } else {
                c.entity_id = self.sim.spawnPlayer(@floatFromInt(surf.x), @floatFromInt(surf.y), @floatFromInt(surf.z), @intCast(c.slot)) orelse return;
            }
            c.joined = true;
            // Stream the spawn area before the bundle, while the client is still
            // waiting on its spawn request. NetPackagePlayerId creates the local
            // player, which opens the spawn-selection window; that window's
            // updateLoadState returns on `cgo >= viewDist^2 - 10` and stops being
            // ticked once the loading screen covers it, so a client that spawns
            // with no displayed chunks stays in WaitingForSpawnWindowToClose
            // behind the loading screen. Sending here (not inside sendJoinBundle)
            // keeps the pre-world DynamicClientArrive fallback untouched: chunks
            // sent before the client's world exists are dropped and wedge the join.
            if (self.wire_chunks and !c.entered) {
                const r0: i32 = if (c.view_radius < 1) self.chunk_stream_radius_min else @min(c.view_radius, self.chunk_stream_radius_max);
                try self.sendSpawnArea(peer, surf.x, surf.z, r0);
            }
            // Death-respawn already sent Spawned+stats; still re-send join bundle so the
            // client re-enters IsSpawned (playtest saw hp=100 but IsSpawned=false without it).
            try self.sendJoinBundle(c, peer, surf.x, surf.y, surf.z, c.entity_id);
            return;
        }
        if (std.mem.eql(u8, name, "NetPackageEntityPosAndRot")) {
            const p = packages.parsePosAndRotBody(body) catch {
                self.harness.counters.inc(.decode_rejects);
                return;
            };
            if (p.entity_id != c.entity_id) {
                self.harness.counters.inc(.ownership_rejects);
                return;
            }
            const env = self.applyMovementEnvelope(c, peer, p.entity_id, p.x, p.y, p.z);
            if (!env.applied) return;
            // Void rescue only (surface-2 snap desynced mesh; see rescueDeepVoid).
            if (try self.rescueDeepVoid(peer, p.entity_id, env.x, env.y, env.z, true)) |ny| {
                self.noteAcceptedMove(c, env.x, ny, env.z);
                systems.questTickGoto(&self.sim, c.slot, env.x, ny, env.z);
                systems.questTickStayWithin(&self.sim, c.slot, env.x, env.z);
                return;
            }
            self.sim.setPos(p.entity_id, env.x, env.y, env.z, 0);
            self.noteAcceptedMove(c, env.x, env.y, env.z);
            systems.questTickGoto(&self.sim, c.slot, env.x, env.y, env.z);
            systems.questTickStayWithin(&self.sim, c.slot, env.x, env.z);
            return;
        }
        // Client animation spam is noisy and fills the reliable window if we log/reply.
        if (std.mem.eql(u8, name, "NetPackageEntityAnimationData")) {
            return;
        }
        if (std.mem.eql(u8, name, "NetPackageEntityCollect")) {
            const bag = packages.parseCollectBody(body) catch return;
            // Transfer contents into server inv, then destroy. Wire order matches
            // stock: Collect (client OnCollect) then EntityRemove(Despawned).
            if (self.sim.slotOfNetId(bag)) |bs| {
                const is_loot = self.sim.kind[bs] == .loot_bag or self.sim.mask[bs].loot_bag;
                if (is_loot) {
                    if (self.sim.playerByPeer(c.slot)) |ps| {
                        const pp = self.sim.transform[ps];
                        const bp = self.sim.transform[bs];
                        const dx = bp.x - pp.x;
                        const dy = bp.y - pp.y;
                        const dz = bp.z - pp.z;
                        if (dx * dx + dy * dy + dz * dz > self.max_edit_range * self.max_edit_range) {
                            self.harness.counters.inc(.bounds_rejects);
                            return;
                        }
                        if (self.sim.mask[ps].inventory and self.sim.mask[bs].inventory) {
                            for (self.sim.inventory[bs].slots) |slot| {
                                if (slot.count == 0 or slot.item_id == 0) continue;
                                _ = self.sim.depositItem(ps, slot.item_id, slot.count);
                            }
                        }
                    }
                    if (self.sim.alive[bs]) self.sim.destroy(bs);
                    if (packages.buildEntityCollectBody(self.body_buf[0..16], bag, c.entity_id)) |cb| {
                        try self.broadcast("NetPackageEntityCollect", cb);
                    } else |_| {}
                    if (packages.buildRemoveBodyReason(&self.body_buf, bag, .despawned)) |rm| {
                        try self.broadcast("NetPackageEntityRemove", rm);
                    } else |_| {}
                }
            }
            return;
        }
        // Stock chat: rebroadcast Global messages to all peers.
        if (std.mem.eql(u8, name, "NetPackageChat") or std.mem.eql(u8, name, "NetPackageSimpleChat")) {
            if (!self.acceptChatRate(c)) return;
            if (std.mem.eql(u8, name, "NetPackageChat")) {
                // Re-encode with the authenticated sender: echoing the client body
                // lets any peer put words in another player's name (clients render
                // the name from the sender entity id).
                const ch = packages.parseStockChat(body) catch return;
                if (!chatMsgOk(ch.msg)) return;
                const stock = packages.buildStockChat(self.body_buf[0..512], c.entity_id, ch.msg) catch return;
                try self.broadcastExcept("NetPackageChat", stock, c.slot);
            } else {
                // Upgrade simple chat to stock Chat when possible
                var r: wire_binary.Reader = .{ .data = body };
                var from_buf: [64]u8 = undefined;
                var msg_buf: [max_chat_msg_len]u8 = undefined;
                const from = r.readString(&from_buf) catch "";
                const msg = r.readString(&msg_buf) catch return;
                _ = from;
                if (!chatMsgOk(msg)) return;
                const stock = try packages.buildStockChat(self.body_buf[0..512], c.entity_id, msg);
                try self.broadcast("NetPackageChat", stock);
            }
            return;
        }
        // Stock vanilla C→S: client pushes inventory sections (toolbelt/bag/equip).
        // Interim client-trust (ADR 0007): overwrite local player ECS; no S2C echo.
        // ItemActionEat: stock clients DecHoldingItem locally then push PlayerInventory;
        // detect eatable stack loss and apply Food/Water/HP (same as InvTx use).
        if (std.mem.eql(u8, name, "NetPackagePlayerInventory")) {
            if (!self.takeInvToken(c)) {
                self.harness.counters.inc(.c2s_throttle);
                return;
            }
            const ps = self.sim.playerByPeer(c.slot) orelse return;
            if (!self.sim.mask[ps].inventory) return;
            var before: [64]struct { id: u16, n: u32 } = undefined;
            var bn: usize = 0;
            var before_total: u32 = 0;
            for (self.sim.inventory[ps].slots) |sl| {
                if (sl.count == 0 or sl.item_id == 0) continue;
                if (!self.items.isEat(sl.item_id)) continue;
                before_total += sl.count;
                var found = false;
                for (before[0..bn]) |*e| {
                    if (e.id == sl.item_id) {
                        e.n += sl.count;
                        found = true;
                        break;
                    }
                }
                if (!found and bn < before.len) {
                    before[bn] = .{ .id = sl.item_id, .n = sl.count };
                    bn += 1;
                }
            }
            const baseline_total = if (before_total > 0) before_total else c.last_eatable_units;
            // Apply may partially mutate toolbelt then fail on bag/equip/prefs.
            // Keep stack-loss detect even on error (toolbelt is first on the wire).
            packages.stock_inv.applyPlayerInventoryBody(body, &self.sim.inventory[ps], reverseItemType, self) catch |err| {
                std.debug.print("zdtd: PlayerInventory apply err={s} body={d} peer={d}\n", .{ @errorName(err), body.len, c.slot });
            };
            self.clampInventoryStacks(&self.sim.inventory[ps]);
            var after_total: u32 = 0;
            var first_eat_id: u16 = 0;
            for (self.sim.inventory[ps].slots) |sl| {
                if (sl.count == 0 or sl.item_id == 0) continue;
                if (!self.items.isEat(sl.item_id)) continue;
                after_total += sl.count;
                if (first_eat_id == 0) first_eat_id = sl.item_id;
            }
            // Body-side eatable count by stock type (reverse-independent).
            const body_eat = packages.stock_inv.countEatableInPlayerInventoryBody(
                body,
                reverseItemType,
                self,
                struct {
                    fn isEatStock(ctx: ?*anyopaque, stock_type: i32) bool {
                        const g: *Game = @ptrCast(@alignCast(ctx.?));
                        return g.items.isEatStockType(stock_type);
                    }
                }.isEatStock,
            );
            if (first_eat_id == 0 and body_eat.first_ecs != 0) first_eat_id = body_eat.first_ecs;

            if (self.sim.mask[ps].health and c.entity_id > 0) {
                var ate_any = false;
                var units_left: u32 = 4;
                // Path A: per-id loss within this package (ECS before → after).
                for (before[0..bn]) |e| {
                    if (units_left == 0) break;
                    var after_n: u32 = 0;
                    for (self.sim.inventory[ps].slots) |sl| {
                        if (sl.item_id == e.id) after_n += sl.count;
                    }
                    if (after_n >= e.n) continue;
                    var lost = e.n - after_n;
                    if (lost > units_left) lost = units_left;
                    var u: u32 = 0;
                    while (u < lost) : (u += 1) {
                        const props = eatProps(@ptrCast(self), e.id);
                        const r = invsys.applyEatProps(&self.sim, ps, props);
                        if (!r.ate) break;
                        ate_any = true;
                        units_left -= 1;
                    }
                }
                // Path B: ECS aggregate drop vs baseline (only with known eat id).
                if (!ate_any and baseline_total > after_total and units_left > 0) {
                    var lost = baseline_total - after_total;
                    if (lost > units_left) lost = units_left;
                    var eid: u16 = first_eat_id;
                    if (eid == 0 and bn > 0) eid = before[0].id;
                    if (eid == 0 and body_eat.first_ecs != 0) eid = body_eat.first_ecs;
                    if (eid != 0 and self.items.isEat(eid)) {
                        var u: u32 = 0;
                        while (u < lost) : (u += 1) {
                            const props = eatProps(@ptrCast(self), eid);
                            const r = invsys.applyEatProps(&self.sim, ps, props);
                            if (!r.ate) break;
                            ate_any = true;
                            units_left -= 1;
                        }
                    }
                }
                // Path C: body stock-type count dropped vs last_eatable (primary live path).
                // Require a resolved eatable ecs id. Do not invent chili/beef/id=2 props
                // for unknown multi-unit losses (drop/trade false-eat under ADR 0007).
                if (!ate_any and c.last_eatable_units > body_eat.total and units_left > 0) {
                    var lost = c.last_eatable_units - body_eat.total;
                    if (lost > units_left) lost = units_left;
                    var eid: u16 = body_eat.first_ecs;
                    if (eid == 0 and first_eat_id != 0) eid = first_eat_id;
                    if (eid == 0 and bn > 0) eid = before[0].id;
                    if (eid != 0 and self.items.isEat(eid)) {
                        var u: u32 = 0;
                        while (u < lost) : (u += 1) {
                            const props = eatProps(@ptrCast(self), eid);
                            const r = invsys.applyEatProps(&self.sim, ps, props);
                            if (!r.ate) break;
                            ate_any = true;
                            units_left -= 1;
                        }
                    } else if (lost > 0) {
                        std.debug.print("zdtd: PI eatable drop skipped (no eat eid) lost={d} last={d} body_eat={d} stock0={d}\n", .{
                            lost, c.last_eatable_units, body_eat.total, body_eat.first_stock,
                        });
                    }
                }
                if (ate_any) {
                    const h = self.sim.health[ps];
                    std.debug.print("zdtd: ItemActionEat stack-loss food={d:.1} before={d} after={d} last={d} body_eat={d} stock0={d}\n", .{
                        h.food, before_total, after_total, c.last_eatable_units, body_eat.total, body_eat.first_stock,
                    });
                    try self.sendSurvivalStats(peer, c.entity_id, h.hp, h.max_hp, h.food, h.food_max, h.water, h.water_max);
                } else if (body_eat.total != c.last_eatable_units or before_total != after_total) {
                    std.debug.print("zdtd: PI eatable before={d} after={d} last={d} body={d} body_eat={d} stock0={d}\n", .{
                        before_total, after_total, c.last_eatable_units, body.len, body_eat.total, body_eat.first_stock,
                    });
                }
            }
            // Body-driven baseline so seed→eat works even when reverse leaves ECS empty.
            c.last_eatable_units = body_eat.total;
            return;
        }
        if (std.mem.eql(u8, name, "NetPackageHoldingItem")) {
            const h = packages.stock_inv.readHoldingItem(body) catch return;
            if (h.entity_id != 0 and h.entity_id != c.entity_id) {
                self.harness.counters.inc(.ownership_rejects);
                return;
            }
            const ps = self.sim.playerByPeer(c.slot) orelse return;
            if (!self.sim.mask[ps].inventory) return;
            if (h.holding_index < ecs.components.inv_toolbelt) {
                _ = self.sim.inventory[ps].setHolding(h.holding_index);
            }
            // Rebroadcast to other peers (stock server behavior).
            const hb = try packages.buildHoldingBodyResolved(
                &self.body_buf,
                c.entity_id,
                &self.sim.inventory[ps],
                resolveItemType,
                self,
            );
            try self.broadcastExcept("NetPackageHoldingItem", hb, c.slot);
            return;
        }
        if (std.mem.eql(u8, name, "NetPackageItemDrop")) {
            const d = packages.stock_inv.readItemDrop(body) catch return;
            const item_id = reverseItemType(self, d.stack.type_id);
            if (item_id == 0 or d.stack.count == 0) return;
            // Prefer drop from matching player stack; else spawn at drop pos.
            var dropped: i32 = -1;
            const ps = self.sim.playerByPeer(c.slot) orelse return;
            if (self.sim.mask[ps].inventory) {
                var slot_i: u16 = 0;
                while (slot_i < ecs.components.max_inv_slots) : (slot_i += 1) {
                    const s = self.sim.inventory[ps].slots[slot_i];
                    if (s.item_id == item_id and s.count > 0) {
                        const qty = @min(s.count, d.stack.count);
                        const r = invsys.applyTransaction(&self.sim, c.slot, .drop, slot_i, 0, qty, -1);
                        dropped = r.dropped_entity;
                        break;
                    }
                }
            }
            // The server inventory is authoritative. A claimed stack that was
            // not actually present must not materialize a new item entity.
            if (dropped > 0) {
                // Stock ItemDropServer → EntityItem (class "item"), not death bag.
                try self.broadcastItemDropSpawn(dropped, d.stack, c.entity_id, d.client_instance_id);
                try self.sendHoldingEcho(peer, c);
                // Rebaseline eatable units so Path C does not treat drop as eat.
                if (self.sim.mask[ps].inventory) {
                    var eat_n: u32 = 0;
                    for (self.sim.inventory[ps].slots) |sl| {
                        if (sl.count == 0 or sl.item_id == 0) continue;
                        if (self.items.isEat(sl.item_id)) eat_n += sl.count;
                    }
                    c.last_eatable_units = eat_n;
                }
            }
            return;
        }
        // Stock bag push (player backpack or entity bag).
        if (std.mem.eql(u8, name, "NetPackageBag")) {
            const entity_id = packages.stock_inv.peekBagEntityId(body) catch return;
            if (entity_id == c.entity_id or entity_id == 0) {
                const ps = self.sim.playerByPeer(c.slot) orelse return;
                if (!self.sim.mask[ps].inventory) return;
                _ = packages.stock_inv.applyBagPackage(body, &self.sim.inventory[ps], reverseItemType, self, true) catch return;
                self.clampInventoryStacks(&self.sim.inventory[ps]);
            } else if (self.sim.slotOfNetId(entity_id)) |si| {
                // Ownership: never let a peer write another player's inventory.
                if (self.sim.mask[si].player) {
                    self.harness.counters.inc(.ownership_rejects);
                    return;
                }
                // Reach: same as Collect/TE. Without this, any peer can rewrite
                // distant loot-bag (or other non-player inv) contents by id.
                const ps = self.sim.playerByPeer(c.slot) orelse return;
                const pp = self.sim.transform[ps];
                const bp = self.sim.transform[si];
                if (!self.withinEditReach(pp.x, pp.y, pp.z, bp.x, bp.y, bp.z)) {
                    self.harness.counters.inc(.bounds_rejects);
                    return;
                }
                if (self.sim.mask[si].inventory) {
                    _ = packages.stock_inv.applyBagPackage(body, &self.sim.inventory[si], reverseItemType, self, false) catch return;
                    self.clampInventoryStacks(&self.sim.inventory[si]);
                }
            } else return;
            try self.sendHoldingEcho(peer, c);
            return;
        }
        if (std.mem.eql(u8, name, "NetPackageDropItemsContainer")) {
            // Death/drop containers are created from server-owned inventory by
            // the death path. Never accept a client-supplied item list.
            return;
        }
        // Stock composite storage TE and/or zdtd ZTE1 bridge.
        if (std.mem.eql(u8, name, "NetPackageTileEntity")) {
            if (self.quarantineDenies(c, .container)) return;
            if (stock_te.parseStorageTeBody(body)) |parsed| {
                // Reach: TE writes must be near the acting player (cross-map chest
                // overwrite + container-store fill guard).
                const owner = self.sim.playerByPeer(c.slot) orelse return;
                const op = self.sim.transform[owner];
                const tdx = @as(f32, @floatFromInt(parsed.world_x)) - op.x;
                const tdy = @as(f32, @floatFromInt(parsed.world_y)) - op.y;
                const tdz = @as(f32, @floatFromInt(parsed.world_z)) - op.z;
                const te_d2 = tdx * tdx + tdy * tdy + tdz * tdz;
                if (te_d2 > self.max_edit_range * self.max_edit_range) {
                    self.harness.counters.inc(.bounds_rejects);
                    self.noteEvidence(c, peer.local_id, c.entity_id, .bounds, .strong, .container, @sqrt(te_d2), self.max_edit_range);
                    return;
                }
                const pos: containers_mod.PosKey = .{ .x = parsed.world_x, .y = parsed.world_y, .z = parsed.world_z };
                const sc: u16 = if (parsed.size_x > 0 and parsed.size_y > 0)
                    @intCast(@min(@as(usize, parsed.size_x) * @as(usize, parsed.size_y), containers_mod.max_container_slots))
                else
                    @intCast(@min(@max(parsed.item_count, 8), containers_mod.max_container_slots));
                const cont = self.containers.getOrCreate(pos, sc, parsed.block_id) orelse return;
                stock_te.applyParsedToContainer(&parsed, cont, reverseItemType, self);
                // Echo stock TE to nearby clients.
                try self.broadcastStorageTe(cont);
                return;
            } else |_| {}
            // Workstation TE (type 12 classic): apply arrays + queue into the
            // workstation store (craft tick advances it) and echo to nearby peers.
            if (stock_te.parseWorkstationTeBody(body)) |ws| {
                const wsp = self.sim.playerByPeer(c.slot) orelse return;
                const wp = self.sim.transform[wsp];
                const wdx = @as(f32, @floatFromInt(ws.world_x)) - wp.x;
                const wdy = @as(f32, @floatFromInt(ws.world_y)) - wp.y;
                const wdz = @as(f32, @floatFromInt(ws.world_z)) - wp.z;
                const ws_d2 = wdx * wdx + wdy * wdy + wdz * wdz;
                if (ws_d2 > self.max_edit_range * self.max_edit_range) {
                    self.harness.counters.inc(.bounds_rejects);
                    self.noteEvidence(c, peer.local_id, c.entity_id, .bounds, .strong, .container, @sqrt(ws_d2), self.max_edit_range);
                    return;
                }
                if (self.workstations.getOrCreate(ws.world_x, ws.world_y, ws.world_z)) |st| {
                    applyWsGroup(self, st.fuel[0..], ws.fuel[0..ws.fuel_n]);
                    applyWsGroup(self, st.input[0..], ws.input[0..ws.input_n]);
                    applyWsGroup(self, st.tools[0..], ws.tools[0..ws.tools_n]);
                    applyWsGroup(self, st.output[0..], ws.output[0..ws.output_n]);
                    @memcpy(st.last_input[0..ws.last_input_blob_len], ws.last_input[0..ws.last_input_blob_len]);
                    st.last_input_blob_len = ws.last_input_blob_len;
                    @memcpy(st.queue[0..ws.queue_n], ws.queue[0..ws.queue_n]);
                    @memcpy(st.melt[0..ws.melt_n], ws.melt[0..ws.melt_n]);
                    // The client returns the craft-complete entries its
                    // CheckForCraftComplete has not consumed: that list is the
                    // acknowledgement, so it replaces ours wholesale.
                    st.setCraftComplete(ws.craft_complete[0..ws.craft_complete_n]);
                    // Array lengths are the client's, never a used prefix: the
                    // echo must send them back unchanged or its grids resize.
                    st.fuel_len = ws.fuel_n;
                    st.input_len = ws.input_n;
                    st.tools_len = ws.tools_n;
                    st.output_len = ws.output_n;
                    st.last_input_len = ws.last_input_n;
                    st.queue_len = ws.queue_n;
                    st.melt_len = ws.melt_n;
                    st.is_burning = ws.is_burning;
                    st.burn_time_left = ws.burn_time_left;
                    st.is_player_placed = ws.is_player_placed;
                    st.block_id = ws.block_id;
                    st.geometry_known = true;
                    st.dirty = false;
                }
                try self.broadcastNear(
                    "NetPackageTileEntity",
                    body,
                    @floatFromInt(ws.world_x),
                    @floatFromInt(ws.world_z),
                    self.interest_range,
                );
                return;
            } else |_| {}
            // TileEntityPoweredTrigger (TileEntityType.Trigger = 19): delay /
            // duration / reset from the trigger's own UI. Tried last and gated on
            // the outer teBlockId resolving to a registered power block, so this
            // reader can never swallow a storage or workstation payload.
            if (stock_te.parsePoweredTriggerTeBody(body)) |trig| {
                const bid: u16 = if (trig.block_id > 0 and trig.block_id <= 65535)
                    @intCast(trig.block_id)
                else
                    return;
                const props = self.power_registry.lookup(bid) orelse return;
                if (props.trigger_type == null) return;
                // Stock only ever writes TriggerTypes 0..4 (asm.il:900244).
                if (trig.trigger_type > stock_te.trigger_type_trip_wire) return;
                const tp = self.sim.playerByPeer(c.slot) orelse return;
                const tpos = self.sim.transform[tp];
                const gdx = @as(f32, @floatFromInt(trig.world_x)) - tpos.x;
                const gdy = @as(f32, @floatFromInt(trig.world_y)) - tpos.y;
                const gdz = @as(f32, @floatFromInt(trig.world_z)) - tpos.z;
                const g_d2 = gdx * gdx + gdy * gdy + gdz * gdz;
                if (g_d2 > self.max_edit_range * self.max_edit_range) {
                    self.harness.counters.inc(.bounds_rejects);
                    self.noteEvidence(c, peer.local_id, c.entity_id, .bounds, .strong, .container, @sqrt(g_d2), self.max_edit_range);
                    return;
                }
                // A Switch carries no delay/duration on the wire; its state is the
                // block meta, which arrives on the SetBlock path instead.
                if (trig.trigger_type != stock_te.trigger_type_switch and
                    trig.trigger_type != stock_te.trigger_type_timer_relay)
                {
                    _ = self.sim.power.setTriggerConfigAt(
                        trig.world_x,
                        trig.world_y,
                        trig.world_z,
                        trig.property1,
                        trig.property2,
                    );
                    if (trig.reset_trigger) _ = self.sim.power.resetTriggerAt(trig.world_x, trig.world_y, trig.world_z);
                }
                self.sim.power.resolve();
                try self.broadcastPoweredTriggerTe(trig.world_x, trig.world_y, trig.world_z);
                return;
            } else |_| {}
            // Unparsed TE payload: drop (stock formats only).
            return;
        }
        if (std.mem.eql(u8, name, "NetPackageInventoryTransactionRequest")) {
            if (!self.takeInvToken(c)) {
                self.harness.counters.inc(.c2s_throttle);
                return;
            }
            const tx = packages.parseInvTxRequest(body) catch return;
            var r: invsys.Result = .{};
            // Captured before apply: a rejected place must refund what it consumed.
            const place_item_id: u16 = blk: {
                if (tx.op != @intFromEnum(invsys.Op.place) or tx.a >= ecs.components.max_inv_slots) break :blk 0;
                const ps = self.sim.playerByPeer(c.slot) orelse break :blk 0;
                if (!self.sim.mask[ps].inventory) break :blk 0;
                break :blk self.sim.inventory[ps].slots[tx.a].item_id;
            };
            const ledger_before = self.sim.inv_ledger.total;
            if (tx.op == @intFromEnum(invsys.Op.craft)) {
                r = .{ .ok = self.tryCraft(c.slot, tx.a, if (tx.qty == 0) 1 else tx.qty) };
            } else {
                const op: invsys.Op = if (tx.op <= @intFromEnum(invsys.Op.equip))
                    @enumFromInt(tx.op)
                else
                    .list;
                // ItemActionEat: resolve food/water/hp from items.xml via eatProps.
                r = invsys.applyTransactionEx(&self.sim, c.slot, op, tx.a, tx.b, tx.qty, tx.entity_id, eatProps, self);
            }
            if (r.ok and r.place_block != 0) {
                // Land claim is authoritative on every apply path (ADR 0004); the
                // InvTx place route must not be a way around it. Refund the unit the
                // transaction already consumed (mirrors the refuel path).
                if (self.claimCovering(r.place_x, r.place_z)) |claim| {
                    if (claim.owner_entity != c.entity_id) {
                        if (place_item_id != 0) _ = invsys.give(&self.sim, c.slot, place_item_id, 1);
                        r.ok = false;
                    }
                }
            }
            if (r.ok and r.place_block != 0) {
                try self.world.setBlockWorld(r.place_x, r.place_y, r.place_z, r.place_block);
                const sb = try packages.buildSetBlockBody(&self.body_buf, r.place_x, r.place_y, r.place_z, r.place_block);
                try self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(r.place_x), @floatFromInt(r.place_z), self.interest_range);
                // Power nodes from placeable generators (same path as SetBlock).
                if (self.power_registry.lookup(r.place_block)) |pn| {
                    if (self.sim.power.addNodeAt(pn.kind, r.place_x, r.place_y, r.place_z, pn.watts)) |nid| {
                        if (self.sim.power.indexOfId(nid)) |ni| pn.applyToNode(&self.sim.power.nodes[ni]);
                    }
                    self.sim.power.resolve();
                }
            } else if (r.ok and r.refuel_amount > 0) {
                // Gas can / FuelValue item used at generator coords (InvTx place).
                if (!self.tryRefuelGenerator(c, r.place_x, r.place_y, r.place_z, r.refuel_amount)) {
                    // Refund the consumed fuel unit (inventory already took one).
                    if (r.refuel_item_id != 0) _ = invsys.give(&self.sim, c.slot, r.refuel_item_id, 1);
                    r.ok = false;
                }
            }
            // Refunds via give() also append; count all ledger appends for this C2S.
            const ledger_delta = self.sim.inv_ledger.total -% ledger_before;
            if (ledger_delta != 0) self.harness.counters.add(.inv_ledger_events, ledger_delta);
            var head_buf: [16]u8 = undefined;
            const head = try packages.buildInvTxResponseHead(&head_buf, r.ok, r.dropped_entity);
            // Stock inventory (toolbelt 10 + bag 45 + equip) needs ~0.5–3 KiB.
            var snap: [4096]u8 = undefined;
            const inv_body = try self.buildInventorySnap(c, &snap);
            if (head.len + inv_body.len <= self.body_buf.len) {
                @memcpy(self.body_buf[0..head.len], head);
                @memcpy(self.body_buf[head.len..][0..inv_body.len], inv_body);
                try self.sendGame(peer, "NetPackageInventoryTransactionResponse", self.body_buf[0 .. head.len + inv_body.len]);
            }
            if (r.dropped_entity > 0) {
                try self.broadcastLootSpawn(r.dropped_entity);
            }
            // ItemActionEat.consume → EntityStatChanged food/water/health (stock path).
            if (r.ok and r.ate and c.entity_id > 0) {
                try self.sendSurvivalStats(peer, c.entity_id, r.hp, r.max_hp, r.food, r.food_max, r.water, r.water_max);
            }
            return;
        }
        if (std.mem.eql(u8, name, "NetPackageInventoryDataRequest")) {
            // Stock: KeyHashPair (Guid+hash) + managerToken Guid.
            // Serve TE container slots when Guid matches our deterministic pos-key.
            if (packages.parseInvDataRequestStock(body)) |req| {
                if (self.containers.getByGuid(&req.inventory_key)) |cont| {
                    var slots: [containers_mod.max_container_slots]packages.stock_inv.StockSlot =
                        [_]packages.stock_inv.StockSlot{.{}} ** containers_mod.max_container_slots;
                    var si: usize = 0;
                    const n: usize = cont.slot_count;
                    while (si < n) : (si += 1) {
                        const s = cont.slots[si];
                        if (s.count > 0 and s.item_id != 0) {
                            slots[si] = .{
                                .type_id = self.items.stockTypeFor(s.item_id),
                                .count = s.count,
                                .quality = s.quality,
                                .meta = s.meta,
                            };
                        }
                    }
                    const resp = try packages.buildInvDataResponseItems(
                        &self.body_buf,
                        req.inventory_key,
                        req.manager_token,
                        slots[0..n],
                    );
                    try self.sendGame(peer, "NetPackageInventoryDataResponse", resp);
                } else {
                    const resp = try packages.buildInvDataResponseNotFound(
                        &self.body_buf,
                        req.inventory_key,
                        req.manager_token,
                    );
                    try self.sendGame(peer, "NetPackageInventoryDataResponse", resp);
                }
            } else |_| if (packages.parseInvDataRequest(body)) |eid| {
                if (self.sim.slotOfNetId(eid)) |si| {
                    // Loot containers only: another player's slots are not a
                    // lootable inventory, and echoing them leaks their bag.
                    if (self.sim.mask[si].inventory and !self.sim.mask[si].player) {
                        const body_out = try packages.buildInventoryBodyStockResolved(
                            &self.body_buf,
                            &self.sim.inventory[si],
                            resolveItemType,
                            self,
                        );
                        try self.sendGame(peer, "NetPackageInventoryDataResponse", body_out);
                        _ = invsys.openContainer(&self.sim, c.slot, eid);
                    }
                }
            } else |_| {}
            return;
        }
        if (std.mem.eql(u8, name, "NetPackageEntityRelPosAndRot")) {
            if (body.len < 20 or c.entity_id <= 0) {
                if (body.len < 20) self.harness.counters.inc(.decode_rejects);
                return;
            }
            const eid = std.mem.readInt(i32, body[0..4], .little);
            if (eid != c.entity_id) {
                self.harness.counters.inc(.ownership_rejects);
                return;
            }
            const dx = std.mem.readInt(i16, body[11..13], .little);
            const dy = std.mem.readInt(i16, body[13..15], .little);
            const dz = std.mem.readInt(i16, body[15..17], .little);
            if (self.sim.slotOfNetId(eid)) |idx| {
                const scale: f32 = 0.03125;
                const nx = self.sim.transform[idx].x + @as(f32, @floatFromInt(dx)) * scale;
                const ny = self.sim.transform[idx].y + @as(f32, @floatFromInt(dy)) * scale;
                const nz = self.sim.transform[idx].z + @as(f32, @floatFromInt(dz)) * scale;
                if (!std.math.isFinite(nx) or !std.math.isFinite(ny) or !std.math.isFinite(nz)) {
                    self.harness.counters.inc(.decode_rejects);
                    return;
                }
                const env = self.applyMovementEnvelope(c, peer, eid, nx, ny, nz);
                if (!env.applied) return;
                self.sim.transform[idx].x = env.x;
                self.sim.transform[idx].y = env.y;
                self.sim.transform[idx].z = env.z;
                // RelPos can walk Y into void without absolute PosAndRot; re-snap.
                if (try self.rescueDeepVoid(peer, eid, env.x, env.y, env.z, true)) |ry| {
                    self.noteAcceptedMove(c, env.x, ry, env.z);
                } else {
                    self.noteAcceptedMove(c, env.x, env.y, env.z);
                }
            }
            return;
        }
        if (std.mem.eql(u8, name, "NetPackageEntityAliveFlags")) {
            const f = packages.parseAliveFlagsBody(body) catch {
                self.harness.counters.inc(.decode_rejects);
                return;
            };
            if (f.entity_id != c.entity_id) {
                self.harness.counters.inc(.ownership_rejects);
                return;
            }
            if (self.sim.slotOfNetId(f.entity_id)) |idx| self.sim.flags[idx].bits = f.flags;
            // Fan-out to other peers (stock tracked-players path).
            try self.broadcastExcept("NetPackageEntityAliveFlags", body, c.slot);
            return;
        }
        // Stock C2S player motion speeds; rebroadcast to other clients.
        if (std.mem.eql(u8, name, "NetPackageEntitySpeeds")) {
            const s = packages.parseEntitySpeedsBody(body) catch {
                self.harness.counters.inc(.decode_rejects);
                return;
            };
            if (s.entity_id != c.entity_id) {
                self.harness.counters.inc(.ownership_rejects);
                return;
            }
            try self.broadcastExcept("NetPackageEntitySpeeds", body, c.slot);
            return;
        }
        // Stock hard teleport (same wire as PosAndRot). Apply + fan-out.
        if (std.mem.eql(u8, name, "NetPackageEntityTeleport")) {
            const p = packages.parsePosAndRotBody(body) catch {
                self.harness.counters.inc(.decode_rejects);
                return;
            };
            if (p.entity_id != c.entity_id) {
                self.harness.counters.inc(.ownership_rejects);
                return;
            }
            // Same speed envelope as PosAndRot: without it a client teleports
            // anywhere and noteAcceptedMove rebaselines the gate to that spot.
            const env = self.applyMovementEnvelope(c, peer, p.entity_id, p.x, p.y, p.z);
            if (try self.rescueDeepVoid(peer, p.entity_id, env.x, env.y, env.z, false)) |ny| {
                // Snapped; do not fan-out void coords.
                self.noteAcceptedMove(c, env.x, ny, env.z);
                return;
            }
            self.sim.setPos(p.entity_id, env.x, env.y, env.z, 0);
            self.noteAcceptedMove(c, env.x, env.y, env.z);
            // Clamped: the owner already got a correction; peers pick the true
            // position up on the next motion pass rather than the raw claim.
            if (env.x == p.x and env.z == p.z) {
                try self.broadcastExcept("NetPackageEntityTeleport", body, c.slot);
            }
            return;
        }
        // Land claim repair ping: acknowledge by echo (client drives repair FX).
        if (std.mem.eql(u8, name, "NetPackageLandClaimRepair")) {
            _ = packages.parseLandClaimRepair(body) catch return;
            try self.broadcast("NetPackageLandClaimRepair", body);
            return;
        }
        // Party / force-add quest on client via SharedQuest echo.
        if (std.mem.eql(u8, name, "NetPackageSharedQuest")) {
            const head = packages.stock_quest.parseSharedQuestHead(body) catch return;
            // Stock GameManager.QuestShareServer: if sharedWith is local, handle; else
            // forward package to sharedWithEntityID. We forward the body unchanged and
            // update server journal only when quest_id maps to a known catalog def.
            if (head.event == .share_quest) {
                if (head.quest_id_len > 0) {
                    if (self.sim.catalog.byName(head.questId())) |d| {
                        _ = systems.questAccept(&self.sim, c.slot, d.id);
                    }
                }
                const with = if (head.shared_with_entity_id > 0) head.shared_with_entity_id else c.entity_id;
                if (with == c.entity_id) {
                    try self.sendGame(peer, "NetPackageSharedQuest", body);
                } else {
                    // Forward to target peer if present; otherwise broadcast (party).
                    var sent = false;
                    for (&self.clients) |*cl| {
                        if (!cl.joined or cl.entity_id != with) continue;
                        if (cl.peer) |tp| {
                            try self.sendGame(tp, "NetPackageSharedQuest", body);
                            sent = true;
                        }
                        break;
                    }
                    if (!sent) try self.broadcast("NetPackageSharedQuest", body);
                }
            } else if (head.event == .remove_quest) {
                // Prefer stock Quest.QuestCode; fall back to catalog def_id for old clients.
                if (head.quest_code != 0) {
                    if (systems.questFindByCode(&self.sim, c.slot, head.quest_code)) |s| {
                        s.active = false;
                        s.completed = false;
                    } else if (head.quest_code > 0 and head.quest_code <= 65535) {
                        if (systems.questFindActive(&self.sim, c.slot, @intCast(head.quest_code))) |s| {
                            s.active = false;
                            s.completed = false;
                        }
                    }
                }
                try self.sendGame(peer, "NetPackageSharedQuest", body);
            } else {
                try self.broadcast("NetPackageSharedQuest", body);
            }
            return;
        }
        // Party: echoed to the sender so the client UI unblocks. Neither
        // NetPackagePartyActions (asm.il 829049) nor NetPackagePartyData
        // (asm.il 829470) carries a platform identity (both are entity-id
        // keyed), and zdtd holds no party membership, so there is nothing to
        // route them to yet.
        if (std.mem.eql(u8, name, "NetPackagePartyActions") or std.mem.eql(u8, name, "NetPackagePartyData")) {
            try self.sendGame(peer, name, body);
            return;
        }
        if (std.mem.eql(u8, name, "NetPackageAllyRequest")) {
            try self.handleAllyRequest(c, body);
            return;
        }
        // NetPackageAllyResponse is ToClient (asm.il 886358): the server decides
        // relationships, so a client sending one is claiming state it does not own.
        if (std.mem.eql(u8, name, "NetPackageAllyResponse")) {
            self.harness.counters.inc(.ownership_rejects);
            return;
        }
        // Stock SavePlayerData: PDF WriteNetwork (ECD + toolbelt/bag + meta tail).
        if (std.mem.eql(u8, name, "NetPackagePlayerData")) {
            const ps = self.sim.playerByPeer(c.slot);
            if (ps) |slot| {
                if (self.sim.mask[slot].inventory) {
                    if (packages.stock_inv.applyPlayerDataNetwork(body, &self.sim.inventory[slot], reverseItemType, self)) |h| {
                        self.clampInventoryStacks(&self.sim.inventory[slot]);
                        // Entity ids are minted by sim.spawnPlayer; a mismatch is
                        // a client claiming someone else's body, never adoption.
                        // Do NOT apply ECD pos either: client PDF pos is
                        // Unity-origin relative after Origin Reposition (y=0
                        // artifacts); PosAndRot is the world-space source of truth.
                        // Success path is silent (periodic PDF is normal). Mismatch
                        // is the operator-visible signal: counter + rate-limited log.
                        if (h.entity_id != c.entity_id) {
                            self.harness.counters.inc(.ownership_rejects);
                            const n = self.harness.counters.get(.ownership_rejects);
                            if (n == 1 or n % 100 == 0) {
                                std.debug.print(
                                    "zdtd: PlayerData ownership reject n={d} claimed={d} expected={d} local_id={d}\n",
                                    .{ n, h.entity_id, c.entity_id, peer.local_id },
                                );
                            }
                        }
                    } else |_| {
                        // Fall back to ECD head only. Parse-skip is rare; log once per 100
                        // decode rejects so a broken client is visible without per-packet noise.
                        if (packages.parsePlayerDataEcdHead(body)) |h| {
                            _ = h; // pos unreliable (origin-relative); ignore
                        } else |_| {
                            self.harness.counters.inc(.decode_rejects);
                            const n = self.harness.counters.get(.decode_rejects);
                            if (n == 1 or n % 100 == 0) {
                                std.debug.print(
                                    "zdtd: PlayerData parse skip n={d} body_len={d} local_id={d}\n",
                                    .{ n, body.len, peer.local_id },
                                );
                            }
                        }
                    }
                }
            } else if (packages.parsePlayerDataEcdHead(body)) |h| {
                _ = h; // pos unreliable (origin-relative); ignore
            } else |_| {}
            // Defer file write to the periodic save tick (no open/rewrite per packet).
            self.players_dirty = true;
            return;
        }
        if (std.mem.eql(u8, name, "NetPackageAddRemoveBuff")) {
            try self.handleAddRemoveBuff(c, body);
            return;
        }
        // Client audio noise / client-side stat mirrors: accept, no sim state.
        if (std.mem.eql(u8, name, "NetPackageAudio") or std.mem.eql(u8, name, "NetPackagePlayerStats") or std.mem.eql(u8, name, "NetPackageDiscordIdMappings")) {
            return;
        }
        // C2S that need no server state change but must not warn/drop as
        // unmapped (parity: real clients send these during normal play).
        if (std.mem.eql(u8, name, "NetPackageBossEvent") or std.mem.eql(u8, name, "NetPackageEntityStatsBuff") or std.mem.eql(u8, name, "NetPackagePlayerEquipment") or std.mem.eql(u8, name, "NetPackageInventoryKeepOpen") or std.mem.eql(u8, name, "NetPackagePlayerInventoryForAI") or std.mem.eql(u8, name, "NetPackageLobbyRegisterClient") or std.mem.eql(u8, name, "NetPackageMapPosition") or std.mem.eql(u8, name, "NetPackagePlayerQuestPositions")) {
            return;
        }
        // Kill/score credit to the acting player (challenges + XP).
        if (std.mem.eql(u8, name, "NetPackageEntityAddScoreServer") or std.mem.eql(u8, name, "NetPackageEntityAddExpServer") or std.mem.eql(u8, name, "NetPackageEntitySetSkillLevelServer")) {
            // No server-side skill sim yet; the client tracks its own progress.
            // Ack silently (dir=1, client-authoritative XP under EAC-off).
            return;
        }
        // Client physics push (fall, explosion knockback): apply to the entity
        // if it is ours, so far-clients see the resulting motion.
        if (std.mem.eql(u8, name, "NetPackageEntityAddVelocity")) {
            if (body.len >= 4) {
                const eid = std.mem.readInt(i32, body[0..4], .little);
                if (eid != c.entity_id) return;
                if (self.sim.slotOfNetId(eid)) |si| {
                    if (self.sim.mask[si].dirty) self.sim.dirty[si].pos = true;
                }
            }
            return;
        }
        // Server-side game events (challenge/quest actions): stock replies with
        // NetPackageGameEventResponse. We ack with an empty response so the
        // client's action completes instead of hanging.
        if (std.mem.eql(u8, name, "NetPackageGameEventRequest")) {
            if (packages.buildGameEventResponse(&self.body_buf, body)) |resp| {
                self.sendGame(peer, "NetPackageGameEventResponse", resp) catch |err| {
                    self.harness.counters.inc(.net_send_errors);
                    std.debug.print(
                        "zdtd: GameEventResponse send failed slot={d}: {s}\n",
                        .{ c.slot, @errorName(err) },
                    );
                };
            } else |err| {
                self.harness.counters.inc(.encode_errors);
                std.debug.print(
                    "zdtd: GameEventResponse encode failed slot={d}: {s}\n",
                    .{ c.slot, @errorName(err) },
                );
            }
            return;
        }
        // Quest-spawned enemy: client asks server to spawn from a quest group.
        // Body: playerEntityId i32 | groupName str | count i32. Spawn `count`
        // default zombies near the player (full gamestage group roll deferred).
        if (std.mem.eql(u8, name, "NetPackageQuestEntitySpawn")) {
            var r: wire_binary.Reader = .{ .data = body };
            _ = r.readI32() catch return; // player entity id
            var gname: [64]u8 = undefined;
            _ = r.readString(&gname) catch return;
            const cnt = r.readI32() catch 1;
            const ps = self.sim.playerByPeer(c.slot) orelse return;
            const t = self.sim.transform[ps];
            const zdef = self.entities.defaultZombie();
            var k: i32 = 0;
            while (k < cnt and k < 8) : (k += 1) {
                const ang = @as(f32, @floatFromInt(k)) * 1.4;
                _ = self.sim.spawnZombieClass(t.x + @cos(ang) * 6, t.y, t.z + @sin(ang) * 6, zdef.max_hp, zdef.hash, zdef.loot_list);
            }
            return;
        }
        // Block trigger (pressure plate, tripwire, switch): acknowledge; no
        // trap sim yet. Rebroadcast so nearby clients see the triggered state.
        if (std.mem.eql(u8, name, "NetPackageBlockTrigger")) {
            const ps = self.sim.playerByPeer(c.slot) orelse return;
            try self.broadcastNear("NetPackageBlockTrigger", body, self.sim.transform[ps].x, self.sim.transform[ps].z, self.interest_range);
            return;
        }
        // Generic client-requested entity spawn is not authoritative enough to
        // create an entity. Typed item paths handle legal drops separately.
        if (std.mem.eql(u8, name, "NetPackageRequestToSpawnEntity")) {
            // The generic ECD request does not prove item ownership or a legal
            // spawn class. Typed drop/throw paths must validate and consume the
            // corresponding server-side inventory first.
            return;
        }
        // In-game console (F1): execute a set of server commands for the sender.
        if (std.mem.eql(u8, name, "NetPackageConsoleCmdServer")) {
            self.handleConsoleCmd(peer, c, body) catch |err| {
                std.debug.print(
                    "zdtd: console cmd failed slot={d}: {s}\n",
                    .{ c.slot, @errorName(err) },
                );
            };
            return;
        }
        // Prefab editor volume: not part of the play path under EAC-off; drop.
        if (std.mem.eql(u8, name, "NetPackageEditorAddVolumeFromClient")) {
            return;
        }
        if (std.mem.eql(u8, name, "NetPackageDamageEntity")) {
            const d = packages.parseDamageHead(body) catch return;
            if (self.quarantineDenies(c, .damage)) return;
            if (!self.takeDamageToken(c)) {
                self.harness.counters.inc(.c2s_throttle);
                return;
            }
            // Damage is a client claim, so require both actor and target to be
            // in the server's current interest range. This blocks forged net
            // ids from damaging players or AI elsewhere in the world.
            const actor_slot = self.sim.playerByPeer(c.slot) orelse return;
            if (!self.sim.alive[actor_slot] or self.sim.health[actor_slot].hp <= 0) {
                self.harness.counters.inc(.bounds_rejects);
                self.noteEvidence(c, peer.local_id, d.entity_id, .bounds, .strong, .damage, 0, 1);
                return;
            }
            const target_slot = self.sim.slotOfNetId(d.entity_id) orelse return;
            if (!self.sim.alive[target_slot]) {
                self.harness.counters.inc(.bounds_rejects);
                self.noteEvidence(c, peer.local_id, d.entity_id, .bounds, .strong, .damage, 0, 1);
                return;
            }
            if (!self.sim.mask[actor_slot].transform or !self.sim.mask[target_slot].transform) return;
            const actor_pos = self.sim.transform[actor_slot];
            const target_pos = self.sim.transform[target_slot];
            const damage_dx = target_pos.x - actor_pos.x;
            const damage_dy = target_pos.y - actor_pos.y;
            const damage_dz = target_pos.z - actor_pos.z;
            const damage_d2 = damage_dx * damage_dx + damage_dy * damage_dy + damage_dz * damage_dz;
            if (damage_d2 > self.interest_range * self.interest_range) {
                self.harness.counters.inc(.bounds_rejects);
                self.noteEvidence(c, peer.local_id, d.entity_id, .bounds, .strong, .damage, @sqrt(damage_d2), self.interest_range);
                return;
            }
            const was_zombie = blk: {
                break :blk self.sim.kind[target_slot] == .zombie or self.sim.kind[target_slot] == .animal;
            };
            // Client strength is a claim: cap it, and honor `fatal` only against
            // NPC kinds (a spoofed fatal must not one-shot another player).
            var amount: f32 = @floatFromInt(@min(d.strength, self.max_claimed_damage));
            if (d.fatal and was_zombie) amount = 9999;
            // PvP gate + armor mitigation when damaging a player.
            if (self.sim.slotOfNetId(d.entity_id)) |ei| {
                if (self.sim.mask[ei].player and self.sim.player[ei].peer_slot >= 0) {
                    // PlayerKillingMode 0 = no PvP: drop player-to-player damage.
                    if (self.pvp_mode == 0 and self.sim.player[ei].peer_slot != @as(i32, @intCast(c.slot)))
                        return;
                    const mit = invsys.armorMitigation(&self.sim, @intCast(self.sim.player[ei].peer_slot));
                    amount *= (1.0 - mit);
                }
            }
            // Attribute the hit: stock's NetPackageDamageEntity carries
            // attackerEntityId (::read, asm.il:810693) and EAISetAsTargetIfHurt
            // turns it into the victim's attack target. The actor is already
            // validated above, so use its net id rather than the claimed field.
            const dmg = self.sim.damageFrom(d.entity_id, amount, self.sim.network_id[actor_slot].id);
            if (dmg.killed) {
                // Dead players keep the entity (client runs its own death →
                // respawn flow); EntityRemove would delete the local player.
                const target_is_player = blk: {
                    if (self.sim.slotOfNetId(d.entity_id)) |ti|
                        break :blk self.sim.mask[ti].player;
                    break :blk false;
                };
                if (!target_is_player) {
                    const rm = try packages.buildRemoveBody(&self.body_buf, d.entity_id);
                    try self.broadcast("NetPackageEntityRemove", rm);
                } else {
                    // DropOnDeath: 0 nothing, 1 all, 2 toolbelt, 3 backpack, 4 delete.
                    // Modes 1..3 drop a loot bag at the death position; 0/4 drop nothing.
                    if (self.drop_on_death >= 1 and self.drop_on_death <= 3) {
                        if (self.sim.slotOfNetId(d.entity_id)) |ti| {
                            const t = self.sim.transform[ti];
                            if (self.sim.spawnLootBag(t.x, t.y, t.z, 1, 1)) |bag_nid| {
                                self.broadcastLootSpawn(bag_nid) catch {};
                            }
                        }
                    }
                }
                if (was_zombie) {
                    systems.questOnZombieKilled(&self.sim, c.slot);
                    systems.questOnFetchItem(&self.sim, c.slot, 1);
                    // XPMultiplier: award scaled server-side XP for the kill.
                    self.awardXp(c.slot, 100);
                }
                // Stock DroppedLootContainer ECD + bag; refill from loot.xml when known.
                if (dmg.loot_bag_id > 0) {
                    self.fillLootBagFromTable(dmg.loot_bag_id, dmg.loot_list, @intCast(d.entity_id));
                    try self.broadcastLootSpawn(dmg.loot_bag_id);
                }
            }
            return;
        }
        // Stock loot UI lock: channel + optional TE pos; stale auto-release.
        if (std.mem.eql(u8, name, "NetPackageLockRequest")) {
            if (packages.parseLockRequest(body)) |req| {
                // Deny acquiring a container lock while quarantined; always let
                // an unlock through so a quarantined peer cannot pin a channel.
                if (req.locking and self.quarantineDenies(c, .container)) return;
                const ch: usize = @min(@as(usize, req.channel), self.lock_channel.len - 1);
                // Stale holder on this channel before grant check.
                if (self.lock_channel[ch] >= 0 and self.lock_granted_ns[ch] != 0) {
                    const now = clock.monoNs();
                    if (now -% self.lock_granted_ns[ch] >= lock_stale_ns) self.clearLockSlot(ch);
                }
                const pos_key: u64 = if (firstLockTargetPos(req.targets_blob)) |p|
                    packLockPos(p.x, p.y, p.z)
                else
                    0;
                // Same TE already locked on another channel by someone else → deny.
                if (req.locking and pos_key != 0) {
                    for (self.lock_pos_key, 0..) |pk, oi| {
                        if (oi == ch) continue;
                        if (pk != pos_key) continue;
                        const oh = self.lock_channel[oi];
                        if (oh >= 0 and oh != @as(i32, @intCast(c.slot))) {
                            const resp = try packages.buildLockResponseDeny(&self.body_buf, req, "locked");
                            try self.sendGame(peer, "NetPackageLockResponse", resp);
                            return;
                        }
                    }
                }
                if (req.locking) {
                    const holder = self.lock_channel[ch];
                    if (holder >= 0 and holder != @as(i32, @intCast(c.slot))) {
                        const resp = try packages.buildLockResponseDeny(&self.body_buf, req, "locked");
                        try self.sendGame(peer, "NetPackageLockResponse", resp);
                        return;
                    }
                    self.lock_channel[ch] = @intCast(c.slot);
                    self.lock_holder_entity[ch] = c.entity_id;
                    self.lock_granted_ns[ch] = clock.monoNs();
                    self.lock_pos_key[ch] = pos_key;
                    const resp = try packages.buildLockResponseGrant(&self.body_buf, req);
                    try self.sendGame(peer, "NetPackageLockResponse", resp);
                    // Re-push TE for any storage container near the first TEFeature target.
                    // Target blob: i32 count | (present, type, …)*
                    if (req.targets_blob.len >= 4) {
                        var tr: wire_binary.Reader = .{ .data = req.targets_blob };
                        const n = tr.readI32() catch 0;
                        var ti: i32 = 0;
                        while (ti < n) : (ti += 1) {
                            const present = tr.readByte() catch break;
                            if (present == 0) continue;
                            const ty = tr.readByte() catch break;
                            if (ty == 0 or ty == 1) {
                                const x = tr.readI32() catch break;
                                const y = tr.readI32() catch break;
                                const z = tr.readI32() catch break;
                                if (ty == 1) tr.skipString() catch {};
                                try self.sendStorageTe(peer, x, y, z);
                                try self.sendWorkstationTe(peer, x, y, z);
                            } else if (ty == 2) {
                                _ = tr.readI32() catch break;
                            } else if (ty == 3) {
                                if (tr.remaining() < 16) break;
                                tr.pos += 16;
                            } else break;
                        }
                    }
                } else {
                    // Unlock only if we hold the channel (or free).
                    if (self.lock_channel[ch] == @as(i32, @intCast(c.slot)) or self.lock_channel[ch] < 0) {
                        self.clearLockSlot(ch);
                        const resp = try packages.buildLockResponseUnlock(&self.body_buf, true);
                        try self.sendGame(peer, "NetPackageLockResponse", resp);
                    } else {
                        const resp = try packages.buildLockResponseUnlock(&self.body_buf, false);
                        try self.sendGame(peer, "NetPackageLockResponse", resp);
                    }
                }
            } else |_| {
                std.debug.print("zdtd: LockRequest parse fail body={d}\n", .{body.len});
            }
            return;
        }
        if (std.mem.eql(u8, name, "NetPackageSetBlock")) {
            // Stock: C2S is a request. Apply, then S2C authoritative result bodies
            // (absolute BlockValue.damage or air). Never rely on raw C2S echo alone
            // when the server mutates damage/break (RE blocks.md §4-5).
            if (self.quarantineDenies(c, .block)) return;
            if (!self.takeBlockToken(c)) {
                self.harness.counters.inc(.c2s_throttle);
                return;
            }
            var changes: [32]packages.BlockChange = undefined;
            const n = packages.parseSetBlockChanges(body, changes[0..]) catch {
                std.debug.print("zdtd: SetBlock parse fail body={d}\n", .{body.len});
                return;
            };
            if (n == 0) return;
            const editor = self.sim.playerByPeer(c.slot) orelse return;
            const editor_ent = self.sim.network_id[editor].id;
            // If RelPos walked us into void, snap before reach so seed places work.
            {
                const tr0 = self.sim.transform[editor];
                _ = try self.rescueDeepVoid(peer, editor_ent, tr0.x, tr0.y, tr0.z, true);
            }
            const ep = self.sim.transform[editor];
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const b = changes[i];
                // Reach is always Hard (reject in both Correct and Observe).
                // Vertical clamp: mesh float must not fail power/dig suite (type=0).
                if (!self.withinEditReach(ep.x, ep.y, ep.z, @floatFromInt(b.x), @floatFromInt(b.y), @floatFromInt(b.z))) {
                    self.harness.counters.inc(.bounds_rejects);
                    self.noteEvidence(c, peer.local_id, editor_ent, .bounds, .strong, .block, 0, self.max_edit_range);
                    // Observe and Correct both count; rate-limit log so reach spam
                    // (float mesh, lag) does not flood, first/100th stay actionable.
                    const rejects = self.harness.counters.get(.bounds_rejects);
                    if (rejects == 1 or rejects % 100 == 0) {
                        std.debug.print(
                            "zdtd: SetBlock out of reach n={d} ({d},{d},{d}) player=({d:.0},{d:.0},{d:.0})\n",
                            .{ rejects, b.x, b.y, b.z, ep.x, ep.y, ep.z },
                        );
                    }
                    continue;
                }
                if (self.claimCovering(b.x, b.z)) |claim| {
                    if (claim.owner_entity != editor_ent) continue;
                }
                const cur_id = self.world.blockWorld(b.x, b.y, b.z) catch 0;
                const cur_dmg = self.getBlockHp(b.x, b.y, b.z);
                const cur_raw = self.blockRawAt(b.x, b.y, b.z);
                // Meta-only edit: same block, same damage, different BlockValue meta.
                // BlockSwitch::updateState flips meta bit 0x2 and SetBlockRPCs the
                // whole value (asm.il:136663), so this must not run through the
                // place/dig chain that clears HP, re-registers claims and rebuilds
                // containers. Apply the raw, drive the power gate, echo it back.
                if (cur_id != 0 and b.block_id == cur_id and b.damage == cur_dmg and b.raw != 0 and b.raw != cur_raw) {
                    self.setBlockRaw(b.x, b.y, b.z, b.raw);
                    const on = (packages.blockMeta(b.raw) & packages.block_meta_on) != 0;
                    if (self.sim.power.setSwitchAt(b.x, b.y, b.z, on)) {
                        self.sim.power.resolve();
                    }
                    if (packages.buildSetBlockBodyRaw(
                        self.body_buf[0..96],
                        b.x,
                        b.y,
                        b.z,
                        b.raw,
                        cur_dmg,
                        editor_ent,
                        editor_ent,
                    )) |sb| {
                        try self.broadcastNear("NetPackageSetBlock", sb, ep.x, ep.z, self.interest_range);
                    } else |_| {}
                    continue;
                }
                var place_id: u16 = b.block_id;
                var out_dmg: u16 = 0;
                var mutated = false;

                if (b.block_id == 0) {
                    place_id = 0;
                    out_dmg = 0;
                    self.clearBlockHp(b.x, b.y, b.z);
                    mutated = true;
                    if (cur_id != 0) self.noteBlockBreak(c);
                } else if (b.damage > 0 or (cur_id != 0 and b.block_id == cur_id and b.damage != cur_dmg)) {
                    // Stock DamageBlock: wire damage is absolute BlockValue.damage
                    // (d = old + points). Client may send absolute after local apply
                    // or a progressive value; take max(wire, cur) then scale delta.
                    const wire_abs = b.damage;
                    const base_cur = if (cur_id != 0) cur_id else b.block_id;
                    var abs = if (wire_abs > cur_dmg) wire_abs else cur_dmg;
                    if (wire_abs > cur_dmg and self.block_damage_player != 100) {
                        const delta: u32 = @as(u32, wire_abs - cur_dmg) * self.block_damage_player / 100;
                        abs = @intCast(@min(@as(u32, cur_dmg) + delta, 65535));
                    } else if (wire_abs <= cur_dmg and wire_abs > 0) {
                        // Treat as delta add when wire did not advance absolute.
                        const scaled: u32 = @as(u32, wire_abs) * self.block_damage_player / 100;
                        abs = @intCast(@min(@as(u32, cur_dmg) + @max(scaled, 1), 65535));
                    }
                    var max_hp = self.maxDamageForBlock(base_cur);
                    if (self.claimCovering(b.x, b.z)) |claim| {
                        if (claim.owner_entity == editor_ent) {
                            const dur = if (claim.owner_online) self.land_claim_online_dur else self.land_claim_offline_dur;
                            if (dur > 0) max_hp = @intCast(@min(@as(u32, max_hp) * dur, 65535));
                        }
                    }
                    if (abs >= max_hp) {
                        self.noteBlockBreak(c);
                        place_id = 0;
                        out_dmg = 0;
                        self.clearBlockHp(b.x, b.y, b.z);
                    } else {
                        place_id = if (cur_id != 0) cur_id else b.block_id;
                        out_dmg = abs;
                        self.setBlockHp(b.x, b.y, b.z, abs);
                    }
                    mutated = true;
                } else {
                    // Fresh place.
                    place_id = b.block_id;
                    out_dmg = 0;
                    self.clearBlockHp(b.x, b.y, b.z);
                    mutated = true;
                }

                if (place_id != 0 and self.landClaimBlockId() == place_id) {
                    self.registerClaim(b.x, b.y, b.z, editor_ent);
                }
                try self.world.setBlockWorld(b.x, b.y, b.z, place_id);
                if (place_id != 0) {
                    if (self.power_registry.lookup(place_id)) |pn| {
                        if (self.sim.power.addNodeAt(pn.kind, b.x, b.y, b.z, pn.watts)) |nid| {
                            if (self.sim.power.indexOfId(nid)) |ni| pn.applyToNode(&self.sim.power.nodes[ni]);
                        }
                        self.sim.power.resolve();
                    }
                } else if (self.sim.power.removeAt(b.x, b.y, b.z)) {
                    self.sim.power.resolve();
                }
                if (place_id != 0 and b.raw != 0) {
                    self.setBlockRaw(b.x, b.y, b.z, b.raw);
                } else if (place_id == 0) {
                    self.clearBlockRaw(b.x, b.y, b.z);
                }
                if (self.isStorageBlockId(place_id)) {
                    if (self.containers.get(.{ .x = b.x, .y = b.y, .z = b.z })) |cont| {
                        cont.block_id = place_id;
                        try self.broadcastStorageTe(cont);
                    } else if (self.containers.getOrCreate(.{ .x = b.x, .y = b.y, .z = b.z }, 8, @intCast(place_id))) |cont| {
                        try self.broadcastStorageTe(cont);
                    }
                } else if (self.storagePairId(place_id) == null) {
                    self.containers.remove(.{ .x = b.x, .y = b.y, .z = b.z });
                }

                if (mutated) {
                    // Echo the stored rawData when it still describes this block, so
                    // rotation and meta survive the authoritative reply instead of
                    // being rebuilt from the bare id.
                    const stored_raw = self.blockRawAt(b.x, b.y, b.z);
                    const echo_raw: u32 = if (place_id != 0 and (stored_raw & 0xffff) == place_id)
                        stored_raw
                    else
                        @as(u32, place_id);
                    if (packages.buildSetBlockBodyRaw(
                        self.body_buf[0..96],
                        b.x,
                        b.y,
                        b.z,
                        echo_raw,
                        out_dmg,
                        editor_ent,
                        editor_ent,
                    )) |sb| {
                        try self.broadcastNear("NetPackageSetBlock", sb, ep.x, ep.z, self.interest_range);
                    } else |_| {}
                }
            }
            // SetBlockResponse Success so client request path completes.
            if (packages.idOf("NetPackageSetBlockResponse") != null) {
                var rb: [4]u8 = undefined;
                std.mem.writeInt(u16, rb[0..2], 0, .little); // Success
                try self.sendGame(peer, "NetPackageSetBlockResponse", rb[0..2]);
            }
            return;
        }
        // C2S explosion: apply sphere dig + ExplosionClient to peers.
        if (std.mem.eql(u8, name, "NetPackageExplosionInitiate")) {
            const ex = packages.parseExplosionInitiate(body) catch return;
            if (self.quarantineDenies(c, .block)) return;
            // Only accept from joined players; ignore entity_id spoof if mismatch.
            if (ex.entity_id > 0 and c.entity_id > 0 and ex.entity_id != c.entity_id) {
                self.harness.counters.inc(.ownership_rejects);
                self.noteEvidence(c, peer.local_id, ex.entity_id, .ownership, .strong, .block, @floatFromInt(ex.entity_id), @floatFromInt(c.entity_id));
                return;
            }
            if (!self.takeBlockToken(c)) {
                self.harness.counters.inc(.c2s_throttle);
                return;
            }
            const rad: i32 = @intFromFloat(@max(1, @min(ex.radius, 6)));
            // Reach: explosion center must be near the acting player.
            if (self.sim.playerByPeer(c.slot)) |bi| {
                if (!self.sim.alive[bi] or self.sim.health[bi].hp <= 0) {
                    self.harness.counters.inc(.bounds_rejects);
                    return;
                }
                const bp = self.sim.transform[bi];
                const dx = ex.wx - bp.x;
                const dy = ex.wy - bp.y;
                const dz = ex.wz - bp.z;
                const ex_d2 = dx * dx + dy * dy + dz * dz;
                if (ex_d2 > self.max_edit_range * self.max_edit_range) {
                    self.harness.counters.inc(.bounds_rejects);
                    self.noteEvidence(c, peer.local_id, ex.entity_id, .bounds, .strong, .block, @sqrt(ex_d2), self.max_edit_range);
                    return;
                }
            } else return;
            const cx = if (ex.bx != 0 or ex.by != 0 or ex.bz != 0) ex.bx else @as(i32, @intFromFloat(@floor(ex.wx)));
            const cy = if (ex.bx != 0 or ex.by != 0 or ex.bz != 0) ex.by else @as(i32, @intFromFloat(@floor(ex.wy)));
            const cz = if (ex.bx != 0 or ex.by != 0 or ex.bz != 0) ex.bz else @as(i32, @intFromFloat(@floor(ex.wz)));
            var dy: i32 = -rad;
            while (dy <= rad) : (dy += 1) {
                var dz: i32 = -rad;
                while (dz <= rad) : (dz += 1) {
                    var dx: i32 = -rad;
                    while (dx <= rad) : (dx += 1) {
                        if (dx * dx + dy * dy + dz * dz > rad * rad) continue;
                        const wx = cx + dx;
                        const wy = cy + dy;
                        const wz = cz + dz;
                        if (wy <= 0) continue; // keep bedrock plane
                        const cur = self.world.blockWorld(wx, wy, wz) catch continue;
                        if (cur == 0 or cur == world_store.block_bedrock) continue;
                        self.world.setBlockWorld(wx, wy, wz, 0) catch continue;
                        const sb = packages.buildSetBlockBody(self.body_buf[0..64], wx, wy, wz, 0) catch continue;
                        self.broadcastNear("NetPackageSetBlock", sb, ex.wx, ex.wz, self.interest_range) catch {};
                    }
                }
            }
            const client_body = try packages.buildExplosionClient(
                self.body_buf[64..256],
                ex.wx,
                ex.wy,
                ex.wz,
                0,
                ex.block_damage,
                @intCast(@max(1, rad)),
                ex.block_damage,
                if (c.entity_id > 0) c.entity_id else ex.entity_id,
            );
            try self.broadcastNear("NetPackageExplosionClient", client_body, ex.wx, ex.wz, self.interest_range);
            return;
        }
        if (std.mem.eql(u8, name, "NetPackageQuestEvent")) {
            try self.handleQuestEvent(peer, c, body);
            return;
        }
        if (std.mem.eql(u8, name, "NetPackageQuestObjectiveUpdate")) {
            // Stock wire: treasure/block objective events. Keep ECS sim for loadgen.
            // Also accept legacy zdtd-native {def_id u16, op u8} for unit fixtures.
            if (packages.parseQuestObjectiveUpdate(body)) |u| {
                _ = u;
            } else |_| {
                if (packages.parseQuestOp(body)) |op| {
                    if (op.op == 1) _ = systems.questAccept(&self.sim, c.slot, op.def_id);
                } else |_| {}
            }
            return;
        }
        if (std.mem.eql(u8, name, "NetPackageNPCQuestList")) {
            // Stock trader quest-list exchange: FetchList with QuestPacketEntry offers.
            const head = packages.parseNpcQuestList(body) catch packages.NpcQuestListHead{
                .npc_entity_id = 0,
                .player_entity_id = c.entity_id,
                .event_type = .fetch_list,
            };
            if (head.event_type == .fetch_list or head.event_type == .reset_quests) {
                var offers: [8]packages.stock_quest.QuestPacketEntry = undefined;
                var tx: f32 = 0;
                var ty: f32 = 70;
                var tz: f32 = 0;
                if (self.sim.slotOfNetId(head.npc_entity_id)) |ni| {
                    if (self.sim.mask[ni].transform) {
                        tx = self.sim.transform[ni].x;
                        ty = self.sim.transform[ni].y;
                        tz = self.sim.transform[ni].z;
                    }
                }
                const on = self.buildTraderQuestOffers("trader_jen_quests", tx, ty, tz, &offers);
                const body_out = try packages.buildNpcQuestListFetch(
                    self.body_buf[0..2048],
                    head.npc_entity_id,
                    if (head.player_entity_id != 0) head.player_entity_id else c.entity_id,
                    head.tier_level,
                    offers[0..on],
                );
                try self.sendGame(peer, "NetPackageNPCQuestList", body_out);
            }
            return;
        }
        if (std.mem.eql(u8, name, "NetPackageTraderData")) {
            if (body.len >= 9 and (body[8] == 0 or body[8] == 1)) {
                try self.handleTrade(c, body);
                return;
            }
            systems.questOnTraderOpen(&self.sim, c.slot);
            // Server-side catalog accept for loadgen/sim; stock UI uses NPCQuestList.
            if (self.sim.catalog.listById("trader_jen_quests")) |list| {
                for (list.entries) |qid| {
                    if (systems.questAccept(&self.sim, c.slot, qid)) break;
                }
            }
            try self.sendTraderSnapshot(peer, null);
            // Stock trader quest offers (npc from open body when present).
            const npc_id: i32 = if (body.len >= 4) std.mem.readInt(i32, body[0..4], .little) else 0;
            var offers: [8]packages.stock_quest.QuestPacketEntry = undefined;
            var tx: f32 = 0;
            var ty: f32 = 70;
            var tz: f32 = 0;
            if (self.sim.slotOfNetId(npc_id)) |ni| {
                if (self.sim.mask[ni].transform) {
                    tx = self.sim.transform[ni].x;
                    ty = self.sim.transform[ni].y;
                    tz = self.sim.transform[ni].z;
                }
            }
            const on = self.buildTraderQuestOffers("trader_jen_quests", tx, ty, tz, &offers);
            const qbody = try packages.buildNpcQuestListFetch(
                self.body_buf[512..2560],
                npc_id,
                c.entity_id,
                0,
                offers[0..on],
            );
            try self.sendGame(peer, "NetPackageNPCQuestList", qbody);
            return;
        }
        if (std.mem.eql(u8, name, "NetPackageVehicleDataSync") or std.mem.eql(u8, name, "NetPackageVehicleSpawn")) {
            const vc = packages.parseVehicleControl(body) catch return;
            if (self.sim.slotOfNetId(vc.entity_id)) |vi| {
                if (!self.sim.mask[vi].vehicle) return;
                if (vc.op == 0) {
                    if (!systems.vehicleEnter(&self.sim, vi, c.entity_id)) return;
                    if (packages.buildEntityAttach(self.body_buf[0..16], .attach_server, c.entity_id, vc.entity_id, 0)) |ab| {
                        try self.broadcast("NetPackageEntityAttach", ab);
                    } else |_| {}
                } else if (vc.op == 1) {
                    if (self.sim.vehicle[vi].driver_net_id != c.entity_id) return;
                    if (!systems.vehicleExit(&self.sim, c.entity_id)) return;
                    if (packages.buildEntityAttach(self.body_buf[0..16], .detach_server, c.entity_id, vc.entity_id, 0)) |ab| {
                        try self.broadcast("NetPackageEntityAttach", ab);
                    } else |_| {}
                } else if (vc.op == 2) {
                    if (self.sim.vehicle[vi].driver_net_id != c.entity_id) return;
                    systems.vehicleControl(&self.sim, vi, vc.throttle, vc.steer, 1.0 / @as(f32, @floatFromInt(protocol.ticks_per_second)));
                }
            }
            return;
        }
        if (std.mem.eql(u8, name, "NetPackageEntityAttach")) {
            const a = packages.parseEntityAttach(body) catch return;
            if (a.rider_id != c.entity_id) return;
            if (self.sim.slotOfNetId(a.vehicle_id)) |vi| {
                if (!self.sim.mask[vi].vehicle) return;
                if (packages.attachTypeIsDetach(a.attach_type)) {
                    if (self.sim.vehicle[vi].driver_net_id != c.entity_id) return;
                    if (!systems.vehicleExit(&self.sim, c.entity_id)) return;
                } else {
                    if (!systems.vehicleEnter(&self.sim, vi, c.entity_id)) return;
                }
            }
            try self.broadcastExcept("NetPackageEntityAttach", body, c.slot);
            return;
        }
        // Gun/tool FX: rebroadcast so other clients see muzzle/swing.
        if (std.mem.eql(u8, name, "NetPackageItemActionEffects")) {
            try self.broadcastExcept("NetPackageItemActionEffects", body, c.slot);
            return;
        }
        if (std.mem.eql(u8, name, "NetPackageCloseAllWindows")) {
            // Echo to other peers for multiplayer UI close.
            try self.broadcastExcept("NetPackageCloseAllWindows", body, c.slot);
            return;
        }
        if (std.mem.eql(u8, name, "NetPackageWireActions")) {
            // Stock parent/child wiring (SetParent/RemoveParent) drives powered state.
            _ = self.sim.power.applyWireActionsStock(body);
            // Rebroadcast raw package so peers get the client-side wire visual.
            try self.broadcastExcept("NetPackageWireActions", body, c.slot);
            return;
        }
        if (std.mem.eql(u8, name, "NetPackageWireToolActions")) {
            // Tool handshake carries one endpoint + player: visual only, no graph
            // mutation (mirrors stock ProcessPackage re-Setup+SendPackage to peers).
            try self.broadcastExcept("NetPackageWireToolActions", body, c.slot);
            return;
        }
        if (std.mem.eql(u8, name, "NetPackageTurretSpawn")) {
            if (body.len < 12) return;
            const x = std.mem.readInt(i32, body[0..4], .little);
            const y = std.mem.readInt(i32, body[4..8], .little);
            const z = std.mem.readInt(i32, body[8..12], .little);
            // Client-chosen coordinates: same reach + claim gate as SetBlock, so a
            // spam loop cannot plant turrets map-wide and drain the entity table.
            if (!self.placeAllowed(c, x, y, z)) return;
            if (self.sim.spawnTurret(@floatFromInt(x), @floatFromInt(y), @floatFromInt(z))) |tid| {
                var gi: ?u16 = null;
                var i: usize = 0;
                while (i < self.sim.power.node_n) : (i += 1) {
                    if (self.sim.power.nodes[i].kind == .generator) {
                        gi = self.sim.power.nodes[i].id;
                        break;
                    }
                }
                if (gi) |gid| {
                    if (self.sim.slotOfNetId(tid)) |ts| {
                        _ = self.sim.power.connect(gid, self.sim.turret[ts].power_node);
                        self.sim.power.resolve();
                    }
                }
            }
            return;
        }
    }

    fn sendTraderSnapshot(self: *Game, peer: *ln_peer.Peer, prefer_slot: ?ecs.Slot) !void {
        var ti: ?ecs.Slot = prefer_slot;
        if (ti == null) {
            var i: ecs.Slot = 0;
            while (i < ecs.max_entities) : (i += 1) {
                if (self.sim.alive[i] and self.sim.mask[i].trader and self.sim.mask[i].trader_stock) {
                    ti = i;
                    break;
                }
            }
        }
        const s = ti orelse return;
        if (!self.sim.mask[s].trader_stock) return;
        const stock = self.sim.trader_stock[s];
        const eid = self.sim.network_id[s].id;
        // Stock TraderData with primary inventory from SoA stock table.
        var entries: [16]packages.TraderStockEntry = undefined;
        var n: usize = 0;
        var e: usize = 0;
        while (e < stock.n and n < entries.len) : (e += 1) {
            const ent = stock.entries[e];
            if (ent.count == 0) continue;
            const type_id: i32 = resolveItemType(@ptrCast(self), ent.item);
            entries[n] = .{
                .item = .{
                    .type_id = type_id,
                    .count = if (ent.count > 0) ent.count else 1,
                    .quality = 1,
                },
                // Stock Entry.Markup is a runtime int8 demand delta (Increase +100 /
                // Decrease -4, asm.il 856828-856866). We have no per-item markup source,
                // so 0 is the honest neutral: the client shows the base econ price we model.
                .markup = 0,
            };
            n += 1;
        }
        const body = try packages.buildTraderDataStock(
            self.body_buf[0..4096],
            eid,
            eid, // trader id (stock TraderID is a traders.xml index; entity id is a safe placeholder)
            trader_wallet_dukes,
            entries[0..n],
        );
        try self.sendGame(peer, "NetPackageTraderData", body);
    }

    pub fn handleTrade(self: *Game, c: *Client, body: []const u8) !void {
        const t = packages.parseTraderTrade(body) catch return;
        const coin = self.items.ecsIdByName("casinoCoin");
        _ = systems.trade(&self.sim, c.slot, t.trader_entity, t.item, t.qty, t.side, coin);
        if (c.peer) |p| {
            const ts = self.sim.slotOfNetId(t.trader_entity);
            try self.sendTraderSnapshot(p, ts);
        }
    }

    /// Stock multiplayer waits for NetPackageConfigFile for each SendToClients XML
    /// (WorldStaticData.xmlsToLoad where sendToClients=true). Length -1 => load local.
    fn sendWorldSpawnPoints(self: *Game, peer: *ln_peer.Peer) !void {
        var pts: [32]packages.SpawnPointXYZ = undefined;
        var n: usize = 0;
        if (self.world.spawn_count > 0) {
            while (n < self.world.spawn_count and n < pts.len) : (n += 1) {
                pts[n] = .{
                    .x = self.world.spawns[n].x,
                    .y = self.world.spawns[n].y,
                    .z = self.world.spawns[n].z,
                };
            }
        } else {
            const sp = self.world.primarySpawn();
            pts[0] = .{ .x = sp.x, .y = sp.y, .z = sp.z };
            n = 1;
        }
        const body = try packages.buildWorldSpawnPoints(self.body_buf[0..512], pts[0..n]);
        try self.sendGame(peer, "NetPackageWorldSpawnPoints", body);
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
    fn sendBlockIdMapping(self: *Game, peer: *ln_peer.Peer) void {
        if (!self.block_id_mapping) return;
        const nameid = packages.stock_nameid;
        if (self.maxdamage.idNameCount() == 0) {
            std.debug.print("zdtd: blocks IdMapping skipped (no AssignIds dump loaded)\n", .{});
            return;
        }
        const summary = nameid.measure(self.maxdamage.idNameIterator(), &self.nameid_seen) catch |err| {
            std.debug.print("zdtd: blocks IdMapping skipped ({s}); client keeps local ids\n", .{@errorName(err)});
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
            std.debug.print("zdtd: blocks IdMapping frame init failed: {s}\n", .{@errorName(err)});
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
            std.debug.print(
                "zdtd: blocks IdMapping does not fit body_buf ({d} raw bytes); client keeps local ids\n",
                .{summary.bytes},
            );
            return;
        }
        const framed = fr.finish() catch |err| {
            std.debug.print("zdtd: blocks IdMapping deflate failed: {s}\n", .{@errorName(err)});
            return;
        };
        self.sendFramedReliable(peer, "NetPackageIdMapping", framed) catch |err| {
            std.debug.print("zdtd: blocks IdMapping send failed: {s}\n", .{@errorName(err)});
            return;
        };
        std.debug.print(
            "zdtd: blocks IdMapping objs={d} raw={d} wire={d}\n",
            .{ summary.count, summary.bytes, framed.len },
        );
    }

    /// Send an already-framed envelope on the reliable channel, pumping the window
    /// the same way `sendGame` does. Separate from `sendGame` because the compressed
    /// mapping frame is built by the streaming framer, not from a body buffer.
    fn sendFramedReliable(self: *Game, peer: *ln_peer.Peer, pkg_name: []const u8, framed: []const u8) anyerror!void {
        var attempts: u32 = 0;
        while (attempts < 960) : (attempts += 1) {
            peer.sendReliable(&self.net.sock, framed) catch |err| switch (err) {
                error.WindowFull => {
                    peer.resendPending(&self.net.sock) catch {
                        self.harness.counters.inc(.net_send_errors);
                    };
                    self.pollNetOnce();
                    if (attempts % 4 == 3) clock.sleepNs(500_000);
                    continue;
                },
                else => {
                    self.harness.counters.inc(.net_send_errors);
                    return err;
                },
            };
            self.harness.counters.add(.net_packets_out, 1);
            self.harness.counters.add(.net_bytes_out, framed.len);
            self.pollNetAfterSend();
            return;
        }
        self.harness.counters.inc(.reliable_window_drops);
        std.debug.print("zdtd: reliable window drop pkg={s} (framed)\n", .{pkg_name});
        return error.WindowFull;
    }

    fn sendLocalConfigFiles(self: *Game, peer: *ln_peer.Peer) !void {
        // Exact SendToClients=true names from stock WorldStaticData .cctor (49 total, 42 sent).
        const names = [_][]const u8{
            "events",               "materials",          "physicsbodies",   "painting",          "shapes",               "blocks",
            "progression",          "buffs",              "misc",            "items",             "item_modifiers",       "entityclasses",
            "qualityinfo",          "sounds",             "recipes",         "blockplaceholders", "loot",                 "entitygroups",
            "utilityai",            "vehicles",           "weathersurvival", "archetypes",        "challenges",           "quests",
            "traders",              "npc",                "dialogs",         "ui_display",        "nav_objects",          "gameevents",
            "twitch",               "twitch_events",      "dmscontent",      "XUi_Common/styles", "XUi_Common/templates", "XUi_InGame/styles",
            "XUi_InGame/templates", "XUi_InGame/windows", "XUi_InGame/xui",  "biomes",            "worldglobal",          "sandbox_overrides",
        };
        for (names) |name| {
            var w: wire_binary.Writer = .{ .buf = self.body_buf[0..] };
            try w.writeString(name);
            try w.writeI32(-1); // null payload => EClientFileState.LoadLocal
            try self.sendGame(peer, "NetPackageConfigFile", w.written());
            peer.resendPending(&self.net.sock) catch self.harness.counters.inc(.net_send_errors);
            self.pollNetOnce();
        }
    }

    /// If feet Y is deep void / far below DTM surface, snap to surface+0.9 and
    /// optionally teleport the peer. Returns new Y when snapped, else null.
    /// Threshold surface-8 (was -24): late-suite mesh float still placeable after
    /// SetBlock pre-snap; deeper than -8 without snap caused type=0 power fails.
    fn rescueDeepVoid(self: *Game, peer: *ln_peer.Peer, entity_id: i32, x: f32, y: f32, z: f32, do_teleport: bool) !?f32 {
        // lossyCast: transforms accumulate client RelPos deltas, so a drifted
        // (or non-finite) value must not trap the checked @intFromFloat.
        const gx: i32 = std.math.lossyCast(i32, @floor(x));
        const gz: i32 = std.math.lossyCast(i32, @floor(z));
        const h_u16: u16 = self.world.heightWorld(gx, gz) catch @intCast(@max(1, self.world.primarySpawn().y));
        const surface: f32 = @floatFromInt(h_u16);
        const min_y = surface + 0.9;
        // ONLY true void (below the world floor). A surface-relative trigger is
        // wrong: being far under the column surface is normal play (mining, POI
        // basements, ravines, caves). The old `y < surface - 8` yanked a
        // sprinting player 9 blocks into the air on Navezgane terrain
        // (playtest core/sprint_motor: hopMax 38.86 m between samples) and would
        // have made digging down impossible.
        if (!(y < -1.0)) return null;
        self.sim.setPos(entity_id, x, min_y, z, 0);
        if (do_teleport) {
            if (packages.buildEntityTeleportBody(&self.body_buf, entity_id, x, min_y, z, 0, 0, 0, true)) |tb| {
                try self.sendGame(peer, "NetPackageEntityTeleport", tb);
            } else |_| {}
        }
        std.debug.print("zdtd: void rescue entity={d} y={d:.1} surf={d:.0} -> {d:.1}\n", .{ entity_id, y, surface, min_y });
        return min_y;
    }

    /// SetBlock/edit reach: full 3D, but clamp vertical delta so client mesh float
    /// (player Y vs block Y) does not reject valid horizontal places.
    fn withinEditReach(self: *const Game, px: f32, py: f32, pz: f32, bx: f32, by: f32, bz: f32) bool {
        const dx = bx - px;
        const dz = bz - pz;
        var dy = by - py;
        const max_v: f32 = 12.0;
        if (dy > max_v) dy = max_v;
        if (dy < -max_v) dy = -max_v;
        const r = self.max_edit_range;
        return dx * dx + dy * dy + dz * dz <= r * r;
    }

    /// Single choke point for detector evidence: records into the ring and runs
    /// the P4 guard policy (docs/AUTHORITY.md). `surf` attributes the signal to a
    /// C2S surface so quarantine can deny only what was abused.
    fn noteEvidence(
        self: *Game,
        c: *Client,
        peer_local: i32,
        entity_id: i32,
        det: evidence_mod.Detector,
        sev: evidence_mod.Severity,
        surf: evidence_mod.Surface,
        observed: f32,
        bound: f32,
    ) void {
        // Load shed drops weak records first; Strong/Hard always reach the gates.
        if (self.loadShedding() and (sev == .info or sev == .soft)) {
            self.harness.counters.inc(.load_shed_drops);
            return;
        }
        const out = guard_policy.evaluate(
            &c.guard,
            self.guard,
            self.tick_n,
            det,
            sev,
            surf,
            self.authorityCorrects(),
        );
        if (out.record) {
            self.evidence.record(.{
                .tick = self.tick_n,
                .peer_local = peer_local,
                .entity_id = entity_id,
                .detector = det,
                .severity = sev,
                .surface = surf,
                .observed = observed,
                .bound = bound,
            });
            self.harness.counters.inc(.evidence_events);
        }
        switch (out.action) {
            .none => {},
            .quarantine => self.applyQuarantine(c, out.bits, det),
            .would_kick => {
                self.harness.counters.inc(.guard_would_kicks);
                std.debug.print(
                    "zdtd: guard would kick slot={d} det={s} surf={s} strong={d} hard={d}\n",
                    .{ c.slot, @tagName(det), @tagName(surf), @popCount(c.guard.strong_mask), c.guard.hard_n },
                );
            },
            .kick => self.armPolicyKick(c, det),
        }
    }

    /// Second `guardstats` line: policy rungs, gate outcomes, and the slots that
    /// currently hold quarantine bits. Bounded by max_clients (64).
    /// ConsoleCmdGameStage::Execute (asm.il ~220775) prints the whole formula so
    /// a live client's own `gamestage` output can be diffed against the server.
    /// Biome/quest terms are printed as the zeros zdtd actually feeds in.
    fn adminReplyGameStage(self: *Game, maybe_slot: ?usize) void {
        if (maybe_slot) |slot| {
            if (slot >= max_clients or !self.clients[slot].joined) {
                self.adminReply("no player in slot\n");
                return;
            }
        }
        var sb: [512]u8 = undefined;
        const now = self.sim.director.clock.worldTimeBits();
        var any = false;
        for (&self.clients, 0..) |*c, i| {
            if (!c.joined) continue;
            if (maybe_slot) |slot| if (i != slot) continue;
            any = true;
            const days = assets_gamestages.daysAlive(now, c.game_stage_born_world_time, c.level);
            const s = std.fmt.bufPrint(
                &sb,
                "slot={d} gamestage={d} lootstage={d} level={d} biome_mod=0 quest_mod=0 days_alive={d} " ++
                    "biome_bonus=0 quest_bonus=0 difficulty_bonus={d:.3} global_modifier=1.000 born_at={d}\n",
                .{
                    i,
                    self.gameStageOf(i),
                    self.lootStageOf(i),
                    c.level,
                    days,
                    self.gamestages.config.difficulty_bonus,
                    c.game_stage_born_world_time,
                },
            ) catch return;
            self.adminReply(s);
        }
        if (!any) {
            self.adminReply("no players joined\n");
            return;
        }
        const p = std.fmt.bufPrint(&sb, "party_stage={d} party_lootstage={d} world_time={d}\n", .{
            self.partyStageAround(0, 0, -1),
            self.partyLootStage(),
            now,
        }) catch return;
        self.adminReply(p);
    }

    fn adminReplyGuardPolicy(self: *Game) void {
        var sb: [512]u8 = undefined;
        const s = std.fmt.bufPrint(
            &sb,
            "policy enforce={d} dry_run={d} quarantine={d} load_shed={d} mode={s} window={d} strong_distinct={d} hard_repeat={d} quarantines={d} kicks={d} would_kicks={d} q_rejects={d} shed_drops={d} shed={d}\n",
            .{
                @intFromBool(self.guard.enforce),
                @intFromBool(self.guard.dry_run),
                @intFromBool(self.guard.quarantine),
                @intFromBool(self.guard.load_shed),
                @tagName(self.authority_mode),
                self.guard.window_ticks,
                self.guard.strong_distinct,
                self.guard.hard_repeat,
                self.harness.counters.get(.guard_quarantines),
                self.harness.counters.get(.guard_kicks),
                self.harness.counters.get(.guard_would_kicks),
                self.harness.counters.get(.quarantine_rejects),
                self.harness.counters.get(.load_shed_drops),
                @intFromBool(self.loadShedding()),
            },
        ) catch return;
        self.adminReply(s);

        var qb: [512]u8 = undefined;
        var pos: usize = 0;
        for (&self.clients, 0..) |*cl, i| {
            const q = cl.guard.quarantine;
            if (!q.any() and cl.guard.kick_at_tick == 0) continue;
            const line = std.fmt.bufPrint(qb[pos..], "  slot={d} no_damage={d} no_container={d} no_setblock={d} kick_at={d}\n", .{
                i,
                @intFromBool(q.no_damage),
                @intFromBool(q.no_container),
                @intFromBool(q.no_setblock),
                cl.guard.kick_at_tick,
            }) catch break;
            pos += line.len;
        }
        if (pos > 0) self.adminReply(qb[0..pos]);
    }

    /// True while the tick-budget valve is open (set by the run() overrun branch).
    fn loadShedding(self: *const Game) bool {
        return self.tick_n < self.shed_until_tick;
    }

    fn applyQuarantine(self: *Game, c: *Client, bits: guard_policy.Quarantine, det: evidence_mod.Detector) void {
        var changed = false;
        if (bits.no_damage and !c.guard.quarantine.no_damage) {
            c.guard.quarantine.no_damage = true;
            changed = true;
        }
        if (bits.no_container and !c.guard.quarantine.no_container) {
            c.guard.quarantine.no_container = true;
            changed = true;
        }
        if (bits.no_setblock and !c.guard.quarantine.no_setblock) {
            c.guard.quarantine.no_setblock = true;
            changed = true;
        }
        if (!changed) return;
        self.harness.counters.inc(.guard_quarantines);
        std.debug.print(
            "zdtd: guard quarantine slot={d} det={s} damage={} container={} setblock={}\n",
            .{
                c.slot,
                @tagName(det),
                c.guard.quarantine.no_damage,
                c.guard.quarantine.no_container,
                c.guard.quarantine.no_setblock,
            },
        );
    }

    /// Stock kick wire: PlayerDenied then a delayed drop (GameUtils
    /// ::KickPlayerForClientInfo + disconnectLater(0.5f), asm.il:1918548-1918583).
    fn armPolicyKick(self: *Game, c: *Client, det: evidence_mod.Detector) void {
        if (c.guard.kick_at_tick != 0) return;
        c.guard.kick_at_tick = self.tick_n + guard_policy.kick_delay_ticks;
        self.harness.counters.inc(.guard_kicks);
        if (c.peer) |p| {
            var denied: [64]u8 = undefined;
            if (packages.buildPlayerDeniedBody(&denied, .mod_decision, 0, 0, "zdtd guard policy")) |body| {
                self.sendGame(p, "NetPackagePlayerDenied", body) catch
                    self.harness.counters.inc(.net_send_errors);
            } else |_| self.harness.counters.inc(.encode_errors);
        }
        std.debug.print(
            "zdtd: guard kick armed slot={d} det={s} strong={d} hard={d} drop_tick={d}\n",
            .{ c.slot, @tagName(det), @popCount(c.guard.strong_mask), c.guard.hard_n, c.guard.kick_at_tick },
        );
    }

    /// Drop armed policy kicks once the stock 0.5 s grace has elapsed.
    /// Bounded by max_clients per tick.
    fn reapPolicyKicks(self: *Game) void {
        for (&self.clients, 0..) |*cl, i| {
            if (cl.guard.kick_at_tick == 0) continue;
            if (self.tick_n < cl.guard.kick_at_tick) continue;
            if (cl.peer == null) {
                cl.guard.kick_at_tick = 0;
                continue;
            }
            self.dropClientSlot(i);
        }
    }

    /// Shared peer teardown for admin kick/ban/wipeplayer and the guard policy.
    /// Resetting the slot to `.{}` also clears guard/quarantine state.
    fn dropClientSlot(self: *Game, slot: usize) void {
        if (self.clients[slot].peer) |p| p.alive = false;
        self.clearLocksForPeer(slot);
        self.clients[slot] = .{};
        self.refreshInfoPlayers();
    }

    /// Quarantine check at a C2S trust boundary. Observe mode records the flag
    /// but never denies (docs/AUTHORITY.md mode table).
    fn quarantineDenies(self: *Game, c: *Client, surf: evidence_mod.Surface) bool {
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
    fn noteBlockBreak(self: *Game, c: *Client) void {
        if (c.farm_window_tick == 0 or self.tick_n -% c.farm_window_tick >= self.guard.window_ticks) {
            c.farm_window_tick = self.tick_n;
            c.farm_breaks = 0;
        }
        c.farm_breaks +|= 1;
        if (c.farm_breaks != guard_policy.weak_break_rate_per_window) return;
        const peer_local: i32 = if (c.peer) |p| p.local_id else -1;
        self.noteEvidence(
            c,
            peer_local,
            c.entity_id,
            .farming,
            .soft,
            .block,
            @floatFromInt(c.farm_breaks),
            @floatFromInt(guard_policy.weak_break_rate_per_window),
        );
    }

    /// Refill + spend one inv token. False → caller should drop and count throttle.
    fn takeInvToken(self: *Game, c: *Client) bool {
        _ = self;
        const now = clock.monoNs();
        if (c.inv_refill_ns == 0) c.inv_refill_ns = now;
        while (c.inv_tokens < inv_bucket_cap and now -% c.inv_refill_ns >= inv_refill_ns) {
            c.inv_tokens += 1;
            c.inv_refill_ns +%= inv_refill_ns;
        }
        if (c.inv_tokens == 0) return false;
        c.inv_tokens -= 1;
        return true;
    }

    fn takeBlockToken(self: *Game, c: *Client) bool {
        _ = self;
        const now = clock.monoNs();
        if (c.block_refill_ns == 0) c.block_refill_ns = now;
        while (c.block_tokens < block_bucket_cap and now -% c.block_refill_ns >= block_refill_ns) {
            c.block_tokens += 1;
            c.block_refill_ns +%= block_refill_ns;
        }
        if (c.block_tokens == 0) return false;
        c.block_tokens -= 1;
        return true;
    }

    /// Combat rate gate: allow burst of damage_burst_max within min_damage_gap.
    fn takeDamageToken(self: *Game, c: *Client) bool {
        _ = self;
        const now = clock.monoNs();
        if (c.last_damage_ns != 0 and now -% c.last_damage_ns < min_damage_gap_ns) {
            if (c.damage_burst >= damage_burst_max) return false;
            c.damage_burst += 1;
        } else {
            c.damage_burst = 1;
        }
        c.last_damage_ns = now;
        return true;
    }

    /// Per-peer chat flood gate. Returns true and stamps `last_chat_ns` when allowed.
    fn acceptChatRate(self: *const Game, c: *Client) bool {
        _ = self;
        const now = clock.monoNs();
        if (c.last_chat_ns != 0 and now -% c.last_chat_ns < min_chat_gap_ns) return false;
        c.last_chat_ns = now;
        return true;
    }

    /// Reach + land-claim gate for a block edit requested by `c` (ADR 0004).
    /// Shared by every C2S path that mutates world blocks or plants entities.
    fn placeAllowed(self: *Game, c: *const Client, x: i32, y: i32, z: i32) bool {
        const ps = self.sim.playerByPeer(c.slot) orelse return false;
        const p = self.sim.transform[ps];
        if (!self.withinEditReach(p.x, p.y, p.z, @floatFromInt(x), @floatFromInt(y), @floatFromInt(z))) return false;
        if (self.claimCovering(x, z)) |claim| {
            if (claim.owner_entity != self.sim.network_id[ps].id) return false;
        }
        return true;
    }

    /// World Y for spawning mobs next to a player (surface band, not void/float).
    fn spawnYNearPlayer(self: *Game, tr_x: f32, tr_y: f32, tr_z: f32) f32 {
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

    /// Align spawn to DTM height and ensure a solid under the feet block so
    /// dig/place sample rings (BlockUnderFeet) see terrain, not air.
    fn spawnSurface(self: *Game, sx: i32, sz: i32) struct { x: i32, y: i32, z: i32 } {
        const fallback: u16 = @intCast(@max(1, self.world.primarySpawn().y));
        const h_u16: u16 = self.world.heightWorld(sx, sz) catch fallback;
        const h: i32 = @intCast(h_u16);
        // heightWorld = top solid; PDF/entity feet use that block Y; entity float y = h+1.
        const feet_y = if (h > 1) h else 1;
        const dirt = world_store.block_dirt;
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

    fn sendJoinBundle(self: *Game, c: *Client, peer: *ln_peer.Peer, sx: i32, sy: i32, sz: i32, eid: i32) !void {
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
        // Spawn/respawn resets movement envelope (teleport budget).
        c.move_valid = false;
        c.move_x = @floatFromInt(sx2);
        c.move_y = @as(f32, @floatFromInt(sy2)) + 0.08;
        c.move_z = @floatFromInt(sz2);
        c.move_tick = self.tick_n;
        if (first_join) {
            self.plugins.playerJoin(@intCast(c.slot), eid);
        }
        const dim: i32 = if (c.view_radius < 1) self.view_radius else c.view_radius;
        // Server journal + stock PDF Quest.Write (RewardItem includes ItemStack).
        _ = systems.questAcceptStarter(&self.sim, c.slot);
        var qbuf: [2]packages.stock_quest.StockQuestWrite = undefined;
        var reward_store: [2][ecs.quest.max_reward_flags]packages.stock_quest.RewardWire = undefined;
        var obj_val_store: [2][ecs.quest.max_phases]u8 = undefined;
        var pos_store: [2][max_quest_position_data]packages.stock_quest.PositionEntry = undefined;
        const qn = self.fillStockJournalWrites(c.slot, &qbuf, &reward_store, &obj_val_store, &pos_store);
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
            try self.sendGame(peer, "NetPackagePlayerId", pid);
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
            // Buffs already on the other players (their AddRemoveBuff relays
            // predate this peer).
            try self.sendBuffSync(peer, c);
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
        // Weather only once the client has already completed first join (re-bundle /
        // respawn). First join: client InitPackages may still be null → underrun kick.
        if (!first_join) try self.sendWeather(peer);
    }

    /// Stock NetPackageGameStats: full bPersistent propertyList blob (RE).
    /// HUD day still comes from WorldTime; BloodMoonDay is the scheduled BM day.
    fn sendGameStats(self: *Game, peer: *ln_peer.Peer) !void {
        const clk = self.sim.director.clock;
        const bm_day: i32 = if (clk.bloodmoon_frequency == 0)
            0
        else if (clk.day % clk.bloodmoon_frequency == 0)
            @intCast(clk.day)
        else
            @intCast(((clk.day / clk.bloodmoon_frequency) + 1) * clk.bloodmoon_frequency);
        const vals: packages.GameStatsValues = .{
            .game_difficulty = self.sim.director.difficulty,
            .blood_moon_enemy_count = self.sim.director.bloodmoon_enemy_count,
            .enemy_difficulty = self.sim.director.enemy_difficulty,
            .day_light_length = @intFromFloat(clk.dusk - clk.dawn),
            .day_night_length = @intFromFloat(clk.seconds_per_hour * 24.0 / 60.0),
            .blood_moon_day = bm_day,
            .block_damage_player = self.block_damage_player,
            .block_damage_ai = self.block_damage_ai,
            .block_damage_ai_bm = self.block_damage_ai_bm,
            .xp_multiplier = self.xp_multiplier,
            .player_killing_mode = self.pvp_mode,
            .drop_on_death = self.drop_on_death,
            .land_claim_size = self.land_claim_size,
            .land_claim_online_dur = self.land_claim_online_dur,
            .land_claim_offline_dur = self.land_claim_offline_dur,
            .air_drop_frequency = self.air_drop_interval_hours,
        };
        const gs = try packages.buildGameStatsBodyValues(self.body_buf[1040..2048], vals);
        try self.sendGame(peer, "NetPackageGameStats", gs);
    }

    /// Map markers for active journal quests (stock class names only).
    fn sendQuestNavObjects(self: *Game, peer: *ln_peer.Peer, peer_slot: usize, player_eid: i32) !void {
        const ps = self.sim.playerByPeer(peer_slot) orelse return;
        if (!self.sim.mask[ps].journal) return;
        for (self.sim.journal[ps].slots) |s| {
            if (!s.active or s.completed) continue;
            const d = self.sim.catalog.byId(s.def_id) orelse continue;
            if (d.name.len == 0 or !isStockClientQuestName(d.name)) continue;
            // nav_objects.xml: quest | go_to_trader | return_to_trader
            const nav_class: []const u8 = switch (d.kind) {
                .fetch_trader => if (s.ready_turn_in) "return_to_trader" else "go_to_trader",
                .goto_point, .kill_zombies, .fetch_item, .craft, .stay_within => "quest",
            };
            const use_def_pos = d.kind == .goto_point or d.kind == .stay_within or d.kind == .craft;
            const lx: f32 = if (use_def_pos) d.tx else @floatFromInt(self.world.primarySpawn().x);
            const ly: f32 = if (use_def_pos) d.ty else @floatFromInt(self.world.primarySpawn().y);
            const lz: f32 = if (use_def_pos) d.tz else @floatFromInt(self.world.primarySpawn().z);
            // entityId tags marker to player for client cleanup.
            const body = try packages.buildNavObjectAdd(
                self.body_buf[8192..8704],
                nav_class,
                d.name,
                lx,
                ly,
                lz,
                player_eid,
            );
            try self.sendGame(peer, "NetPackageNavObject", body);
        }
    }

    /// True when quest id is likely present in stock client QuestClass.
    fn isStockClientQuestName(name: []const u8) bool {
        if (name.len == 0) return false;
        if (std.mem.startsWith(u8, name, "quest_")) return true;
        if (std.mem.startsWith(u8, name, "tier")) return true;
        return false;
    }

    /// Fill stock Quest.Write snapshots for active journal slots (client-known ids only).
    /// `reward_store` holds RewardWire arrays for each quest (Item/LootItem need ItemStack).
    /// C2S NetPackageQuestEvent. Only the rally marker and the POI lock/unlock
    /// events have a server side (NetPackageQuestEvent.ProcessPackage,
    /// asm.il 835696-835943); the rest are client-local and are dropped.
    fn handleQuestEvent(self: *Game, peer: *ln_peer.Peer, c: *Client, body: []const u8) !void {
        const head = packages.stock_quest.parseQuestEventHead(body) catch return;
        // Trust boundary: a peer may only raise quest events for its own entity.
        if (head.entity_id != c.entity_id) return;
        switch (head.event) {
            .try_rally_marker => {
                const lockout = systems.questCheckPoiLockout(&self.sim, c.entity_id, head.px, head.pz);
                var reply = head;
                reply.extra_data = lockout.extra_data;
                // Reason → reply event, from the switch at asm.il 835696 IL_009d.
                reply.event = switch (lockout.reason) {
                    .none => .rally_marker_activated,
                    .player_inside => .rally_marker_player_locked,
                    .bedroll => .rally_marker_bedroll_locked,
                    .land_claim => .rally_marker_land_claim_locked,
                    .quest_lock => .rally_marker_locked,
                };
                if (lockout.reason == .none) {
                    // An unknown or already spent quest code gets no reply: the
                    // marker must not report activated for a quest we cannot track.
                    if (!systems.questOnRallyActivated(&self.sim, c.slot, head.quest_code)) return;
                    systems.questPoiLock(&self.sim, c.entity_id, head.px, head.pz);
                }
                const out = try packages.stock_quest.buildQuestEvent(self.body_buf[0..64], reply);
                if (lockout.reason == .none) {
                    // Activation is shared state (shared-quest party members see
                    // the same marker); a refusal only concerns the requester.
                    try self.broadcast("NetPackageQuestEvent", out);
                } else {
                    try self.sendGame(peer, "NetPackageQuestEvent", out);
                }
            },
            .lock_poi => systems.questPoiLock(&self.sim, c.entity_id, head.px, head.pz),
            .unlock_poi => systems.questPoiUnlock(&self.sim, c.entity_id, head.px, head.pz),
            else => return,
        }
    }

    fn fillStockJournalWrites(
        self: *Game,
        peer_slot: usize,
        out: []packages.stock_quest.StockQuestWrite,
        reward_store: *[2][ecs.quest.max_reward_flags]packages.stock_quest.RewardWire,
        obj_val_store: *[2][ecs.quest.max_phases]u8,
        pos_store: *[2][max_quest_position_data]packages.stock_quest.PositionEntry,
    ) usize {
        const ps = self.sim.playerByPeer(peer_slot) orelse return 0;
        if (!self.sim.mask[ps].journal) return 0;
        var n: usize = 0;
        for (self.sim.journal[ps].slots) |s| {
            if (!s.active and !s.completed) continue;
            if (n >= out.len or n >= reward_store.len) break;
            const d = self.sim.catalog.byId(s.def_id) orelse continue;
            if (d.name.len == 0 or !isStockClientQuestName(d.name)) continue;
            const state: packages.stock_quest.QuestState = if (s.completed)
                .completed
            else if (s.ready_turn_in)
                .ready_turn_in
            else
                .in_progress;
            var prog: u8 = 0;
            if (s.progress > 0) prog = @intCast(@min(s.progress, 255));
            const rc: usize = @min(@as(usize, d.reward_count), ecs.quest.max_reward_flags);
            var ri: usize = 0;
            while (ri < rc) : (ri += 1) {
                reward_store[n][ri] = .{
                    .has_item_stack = d.reward_has_item[ri],
                    // Empty ItemStack (count 0) is valid stock Empty path for Item/LootItem.
                    .item = .{},
                };
            }
            const phase: u8 = if (s.completed)
                255
            else if (s.phase > 0)
                s.phase
            else if (s.ready_turn_in)
                2
            else
                1;
            const qcode: i32 = if (s.quest_code != 0) s.quest_code else @intCast(d.id);
            // Per-objective CurrentValue from the phase graph: completed phases
            // report 255 (>= client required), the active phase reports clamped
            // progress, future phases 0. Legacy defs fall back to first_objective_value.
            var obj_vals: []const u8 = &.{};
            if (d.objective_phases.len > 0) {
                const req: u16 = if (s.phase > 0 and s.phase <= d.phases.len)
                    d.phases[s.phase - 1].required
                else
                    s.progress;
                var oi: usize = 0;
                const lim = @min(d.objective_phases.len, obj_val_store[n].len);
                while (oi < lim) : (oi += 1) {
                    const op = d.objective_phases[oi];
                    obj_val_store[n][oi] = if (s.completed or op < s.phase)
                        255
                    else if (op == s.phase)
                        @intCast(@min(@min(s.progress, req), @as(u16, 255)))
                    else
                        0;
                }
                obj_vals = obj_val_store[n][0..lim];
            }
            // PositionData: the Location marker plus, when the quest was placed
            // in a POI, the rect ObjectiveRallyPoint scans for its rally block.
            var pn: usize = 0;
            if (d.kind == .goto_point or d.kind == .kill_zombies or d.kind == .fetch_item) {
                pos_store[n][pn] = .{
                    .kind = packages.stock_quest.position_data_location,
                    .x = if (d.kind == .goto_point) d.tx else self.sim.transform[ps].x,
                    .y = if (d.kind == .goto_point) d.ty else self.sim.transform[ps].y,
                    .z = if (d.kind == .goto_point) d.tz else self.sim.transform[ps].z,
                };
                pn += 1;
            }
            if (s.poi.valid()) {
                pos_store[n][pn] = .{
                    .kind = packages.stock_quest.position_data_poi_position,
                    .x = s.poi.x,
                    .y = s.poi.y,
                    .z = s.poi.z,
                };
                pos_store[n][pn + 1] = .{
                    .kind = packages.stock_quest.position_data_poi_size,
                    .x = s.poi.size_x,
                    .y = s.poi.size_y,
                    .z = s.poi.size_z,
                };
                pn += 2;
            }
            out[n] = .{
                .id = d.name,
                .state = state,
                .quest_code = qcode,
                .current_phase = phase,
                .objective_count = d.objective_count,
                .first_objective_value = prog,
                .objective_values = obj_vals,
                .rewards = reward_store[n][0..rc],
                .position_data = pos_store[n][0..pn],
                .rally_marker_activated = s.rally_activated,
            };
            n += 1;
        }
        return n;
    }

    /// Build trader FetchList offers from a quest_list id (stock quest names only).
    fn buildTraderQuestOffers(
        self: *Game,
        list_id: []const u8,
        trader_x: f32,
        trader_y: f32,
        trader_z: f32,
        out: []packages.stock_quest.QuestPacketEntry,
    ) usize {
        const list = self.sim.catalog.listById(list_id) orelse return 0;
        var n: usize = 0;
        for (list.entries) |qid| {
            if (n >= out.len) break;
            const d = self.sim.catalog.byId(qid) orelse continue;
            if (d.name.len == 0 or !isStockClientQuestName(d.name)) continue;
            out[n] = .{
                .quest_id = d.name,
                .loc_x = d.tx,
                .loc_y = d.ty,
                .loc_z = d.tz,
                .poi_name = d.name,
                .trader_x = trader_x,
                .trader_y = trader_y,
                .trader_z = trader_z,
            };
            n += 1;
        }
        return n;
    }

    /// Nearby non-player entities using stock NetPackageEntitySpawn + ECD networkWrite.
    /// Interest radius matches tick-path spawn-on-approach (`interest.inRange` + view_radius).
    fn sendStockEntitySpawns(self: *Game, peer: *ln_peer.Peer, c: *Client, px: i32, pz: i32) !void {
        const radius: i32 = if (c.view_radius < 1) self.view_radius else c.view_radius;
        const pfx: f32 = @floatFromInt(px);
        const pfz: f32 = @floatFromInt(pz);
        var i: ecs.Slot = 0;
        var sent: u32 = 0;
        var alive_z: u32 = 0;
        while (i < ecs.max_entities) : (i += 1) {
            if (!self.sim.alive[i]) continue;
            if (!self.sim.mask[i].kind) continue;
            const k = self.sim.kind[i];
            if (k != .zombie and k != .animal) continue;
            if (k == .zombie) alive_z += 1;
            if (!self.sim.mask[i].transform or !self.sim.mask[i].network_id) continue;
            if (self.sim.mask[i].player) continue;
            const nid = self.sim.network_id[i].id;
            if (nid == c.entity_id or nid <= 0) continue;
            if (!interest.inRange(pfx, pfz, self.sim.transform[i].x, self.sim.transform[i].z, radius)) continue;
            const sleeper = self.sim.mask[i].sleeper and !self.sim.sleeper[i].awake;
            const eclass: i32 = if (self.sim.mask[i].class_id and self.sim.class_id[i].hash != 0)
                self.sim.class_id[i].hash
            else
                packages.stock_entity.class_zombie_default;
            const body = try packages.stock_entity.buildEntitySpawnStock(&self.body_buf, .{
                .entity_id = nid,
                .entity_class = eclass,
                .x = self.sim.transform[i].x,
                .y = self.sim.transform[i].y,
                .z = self.sim.transform[i].z,
                .yaw = self.sim.transform[i].yaw,
                .is_sleeper = sleeper,
            });
            try self.sendGame(peer, "NetPackageEntitySpawn", body);
            c.known_entities.set(i);
            sent += 1;
            self.pollNetOnce();
            if (sent >= 16) break;
        }
        std.debug.print("zdtd: stock EntitySpawn mobs sent={d} alive_z={d} around=({d},{d})\n", .{ sent, alive_z, px, pz });
    }

    /// Stock EntityStatChanged for core vitals (Health/Stamina/Food/Water).
    fn sendPlayerVitals(self: *Game, peer: *ln_peer.Peer, c: *Client) !void {
        const eid = c.entity_id;
        if (eid <= 0) return;
        var hp: f32 = 100;
        var max_hp: f32 = 100;
        var food: f32 = 100;
        var food_max: f32 = 100;
        var water: f32 = 100;
        var water_max: f32 = 100;
        if (self.sim.slotOfNetId(eid)) |si| {
            if (self.sim.mask[si].health) {
                hp = self.sim.health[si].hp;
                max_hp = self.sim.health[si].max_hp;
                food = self.sim.health[si].food;
                food_max = self.sim.health[si].food_max;
                water = self.sim.health[si].water;
                water_max = self.sim.health[si].water_max;
            }
        }
        const stats = [_]struct { packages.EntityStatKind, f32, f32 }{
            .{ .health, hp, max_hp },
            .{ .stamina, 100, 100 },
            .{ .food, food, food_max },
            .{ .water, water, water_max },
        };
        for (stats) |s| {
            const body = try packages.buildEntityStatChangedBody(
                self.body_buf[0..32],
                eid,
                -1,
                s[0],
                s[1],
                s[2],
                0,
            );
            try self.sendGame(peer, "NetPackageEntityStatChanged", body);
        }
    }

    fn countJoined(self: *const Game) u16 {
        var n: u16 = 0;
        for (self.clients) |cl| {
            if (cl.joined) n += 1;
        }
        return n;
    }

    fn resolveItemType(ctx: ?*anyopaque, item_id: u16) i32 {
        const g: *Game = @ptrCast(@alignCast(ctx.?));
        return g.items.stockTypeFor(item_id);
    }

    fn reverseItemType(ctx: ?*anyopaque, stock_type: i32) u16 {
        const g: *Game = @ptrCast(@alignCast(ctx.?));
        return g.items.ecsIdFromStockType(stock_type);
    }

    /// Workstation craft output: sim item plus the name the client derives from
    /// `Recipe::GetName()`, i.e. the output ItemClass name (asm.il ~274245).
    /// The name only feeds the client's `_craftCount_` XP scaling, so an unknown
    /// type still crafts, just without a per-recipe counter.
    fn resolveWorkstationOutput(ctx: ?*anyopaque, stock_type: i32) workstations_mod.ResolvedOutput {
        const g: *Game = @ptrCast(@alignCast(ctx.?));
        var out: workstations_mod.ResolvedOutput = .{ .item_id = g.items.ecsIdFromStockType(stock_type) };
        for (g.items.stock_types, 0..) |st, i| {
            if (st != stock_type or i >= g.items.stock_names.len) continue;
            out.stock_name = g.items.stock_names[i];
            return out;
        }
        if (out.item_id != 0) {
            if (assets_items.builtinStockName(out.item_id)) |sn| out.stock_name = sn;
        }
        return out;
    }

    fn buildInventorySnap(self: *Game, c: *Client, buf: []u8) ![]u8 {
        const ps = self.sim.playerByPeer(c.slot) orelse return error.NoPlayer;
        if (!self.sim.mask[ps].inventory) return error.NoInv;
        // Stock V3.0.1 body with ItemTable stock types when items.xml is loaded.
        return packages.buildInventoryBodyStockResolved(buf, &self.sim.inventory[ps], resolveItemType, self);
    }

    fn sendItemIdMapping(self: *Game, peer: *ln_peer.Peer) !void {
        // Compact NameIdMapping: only ECS builtins that resolved to stock types (fits 8 KiB body).
        // Full items.xml map is ~30–50 KiB uncompressed; stock client already has matching AssignIds
        // from the same Config when game-dir is shared.
        var map_buf: [2048]u8 = undefined;
        var w: wire_binary.Writer = .{ .buf = &map_buf };
        try w.writeI32(1);
        const count_pos = w.pos;
        try w.writeI32(0);
        var n: i32 = 0;
        var id: u16 = 1;
        while (id <= 12) : (id += 1) {
            const st = self.items.stockTypeFor(id);
            if (st == 0) continue;
            const name = assets_items.builtinStockName(id) orelse continue;
            try w.writeI32(st);
            try w.writeString(name);
            n += 1;
        }
        std.mem.writeInt(i32, map_buf[count_pos..][0..4], n, .little);
        if (n == 0) return;
        const body = packages.buildIdMappingBody(&self.body_buf, "items", w.written()) catch return;
        try self.sendGame(peer, "NetPackageIdMapping", body);
    }

    /// Holding-only S2C (valid direction for stock clients).
    /// Join: send empty held stack (entityId + count=0 + index). Full ItemValue held
    /// stacks have underrun'd stock HoldingItem.read mid-join when framing/window is tight;
    /// PDF already carries toolbelt. Echo path after InvTx still sends resolved hold.
    fn sendHoldingOnly(self: *Game, peer: *ln_peer.Peer, c: *Client) !void {
        try self.sendHoldingOnlyEx(peer, c, false);
    }

    fn sendHoldingOnlyEx(self: *Game, peer: *ln_peer.Peer, c: *Client, full_stack: bool) !void {
        const ps = self.sim.playerByPeer(c.slot) orelse return;
        if (!self.sim.mask[ps].inventory) return;
        // Dedicated slice after PlayerId region; keep short fixed body.
        var hb: []const u8 = undefined;
        if (full_stack) {
            hb = try packages.buildHoldingBodyResolved(
                self.body_buf[6144..6400],
                c.entity_id,
                &self.sim.inventory[ps],
                resolveItemType,
                self,
            );
        } else {
            // Empty ItemStack: entityId + u16 count=0 + holding index.
            var w: wire_binary.Writer = .{ .buf = self.body_buf[6144..6160] };
            try w.writeI32(c.entity_id);
            try w.writeU16(0);
            const idx: u8 = if (self.sim.inventory[ps].holding < ecs.components.inv_toolbelt)
                @intCast(self.sim.inventory[ps].holding)
            else
                0;
            try w.writeByte(idx);
            hb = w.written();
        }
        try self.sendGame(peer, "NetPackageHoldingItem", hb);
    }

    /// Post-change inv echo. PlayerInventory/Bag are ToServer-only for stock
    /// clients; only HoldingItem is a valid S2C echo.
    fn sendHoldingEcho(self: *Game, peer: *ln_peer.Peer, c: *Client) !void {
        try self.sendHoldingOnlyEx(peer, c, true);
    }

    fn isStorageBlockId(self: *const Game, block_id: u16) bool {
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
    fn storagePairId(self: *const Game, block_id: u16) ?u16 {
        if (self.storage_pairs.toggleId(block_id)) |id| return id;
        // Offline fallback: wooden chest pins.
        const d = packages.stock_deco;
        const closed: u16 = @intCast(d.cnt_wooden_chest_closed);
        const open: u16 = @intCast(d.cnt_wooden_chest_open);
        if (block_id == closed) return open;
        if (block_id == open) return closed;
        return null;
    }

    fn pickEntityGroup(ctx: ?*anyopaque, group: []const u8, seed: u32) ?[]const u8 {
        const g: *Game = @ptrCast(@alignCast(ctx.?));
        return g.entitygroups.pick(group, seed);
    }

    /// gamestages.xml spawner ladder → the stage's first <spawn> row.
    fn pickStageGroup(ctx: ?*anyopaque, spawner: []const u8, stage: i32) ?ecs.aidirector.StageGroup {
        const g: *Game = @ptrCast(@alignCast(ctx.?));
        const sp = g.gamestages.spawnerByName(spawner) orelse return null;
        const st = sp.getStage(stage) orelse return null;
        const sg = st.spawnGroup(0) orelse return null;
        return .{ .group = sg.group, .num = sg.num, .max_alive = sg.max_alive };
    }

    /// spawning.xml <entityspawner name=…> → its EntityGroupName property.
    fn pickSpawnerGroup(ctx: ?*anyopaque, spawner: []const u8) ?[]const u8 {
        const g: *Game = @ptrCast(@alignCast(ctx.?));
        const s = g.spawning.spawnerByName(spawner) orelse return null;
        return s.entitygroup;
    }

    /// Craft recipe by index into recipes.defs (InvTx craft op). Consumes ingredients, grants output.
    fn tryCraft(self: *Game, peer_slot: usize, recipe_index: u16, times: u16) bool {
        if (recipe_index >= self.recipes.defs.len) return false;
        return self.tryCraftRecipe(peer_slot, self.recipes.defs[recipe_index], times);
    }

    fn tryCraftRecipe(self: *Game, peer_slot: usize, recipe: assets_recipes.RecipeDef, times: u16) bool {
        const ps = self.sim.playerByPeer(peer_slot) orelse return false;
        if (!self.sim.mask[ps].inventory) return false;
        const n: u16 = if (times == 0) 1 else @min(times, 20);
        // Aggregate by ECS id so duplicate ingredient lines (or aliases that
        // resolve to the same id) do not double-count inventory room.
        var need: [assets_recipes.max_ingredients]struct { id: u16, count: u32 } = undefined;
        var nn: usize = 0;
        var i: u8 = 0;
        while (i < recipe.ingredient_n) : (i += 1) {
            const ing = recipe.ingredients[i];
            const id = self.ecsIdFromItemName(ing.name);
            if (id == 0) return false;
            const add: u32 = @as(u32, ing.count) * n;
            var merged = false;
            var k: usize = 0;
            while (k < nn) : (k += 1) {
                if (need[k].id == id) {
                    need[k].count += add;
                    merged = true;
                    break;
                }
            }
            if (!merged) {
                if (nn >= need.len) return false;
                need[nn] = .{ .id = id, .count = add };
                nn += 1;
            }
        }
        var j: usize = 0;
        while (j < nn) : (j += 1) {
            if (need[j].count > std.math.maxInt(u16)) return false;
            if (self.sim.inventory[ps].countItem(need[j].id) < need[j].count) return false;
        }
        const out_id = self.ecsIdFromItemName(recipe.name);
        if (out_id == 0) return false;
        const out_u32: u32 = @as(u32, recipe.count) * n;
        if (out_u32 == 0 or out_u32 > std.math.maxInt(u16)) return false;
        const out_count: u16 = @intCast(out_u32);
        // Snapshot so any remove/add failure restores the exact pre-craft bag.
        const inventory_before = self.sim.inventory[ps];
        j = 0;
        while (j < nn) : (j += 1) {
            if (!self.sim.inventory[ps].removeItem(need[j].id, @intCast(need[j].count))) {
                self.sim.inventory[ps] = inventory_before;
                return false;
            }
        }
        if (!self.sim.depositItem(ps, out_id, out_count)) {
            self.sim.inventory[ps] = inventory_before;
            return false;
        }
        if (self.sim.mask[ps].dirty) self.sim.dirty[ps].inv = true;
        const p: u16 = if (peer_slot > std.math.maxInt(u16)) std.math.maxInt(u16) else @intCast(peer_slot);
        const d: i16 = @intCast(@min(out_count, std.math.maxInt(i16)));
        self.sim.inv_ledger.record(p, out_id, d, .craft);
        // Quest craft progress when objective matches recipe name.
        systems.questOnCraft(&self.sim, peer_slot, recipe.name);
        return true;
    }

    /// Map stock item name → ECS id (0 unknown).
    /// Replace builtin trader stock with traders.xml traderAlways entries when
    /// resolvable to ECS items. Price from items.xml EconomicValue when known.
    fn fillTraderFromXml(self: *Game, trader_net_id: i32) void {
        const tt = self.traders;
        if (tt.entries.len == 0) return;
        const s = self.sim.slotOfNetId(trader_net_id) orelse return;
        if (!self.sim.mask[s].trader_stock) return;
        var n: usize = 0;
        for (tt.entries) |e| {
            if (n >= ecs.components.max_stock) break;
            const iid = self.ecsIdFromItemName(e.name);
            if (iid == 0) continue;
            const econ: u16 = if (self.items.byId(iid)) |d| d.econ else 0;
            self.sim.trader_stock[s].entries[n] = .{
                .item = iid,
                .count = e.count,
                .price = if (econ > 0) @min(econ / 10, 65535) else 5,
                .sell = if (econ > 0) @max(econ / 50, 1) else 1,
            };
            n += 1;
        }
        if (n > 0) self.sim.trader_stock[s].n = @intCast(n);
    }

    fn handItemDamage(self: *Game, hand_item: []const u8) f32 {
        if (hand_item.len == 0) return 0;
        if (self.items.byName(hand_item)) |d| return d.entity_damage;
        return 0;
    }

    fn wsGroupToStock(self: *Game, dst: []packages.stock_inv.StockSlot, src: []const ecs.components.InvSlot) void {
        for (dst, src) |*d, s| {
            d.* = if (s.count > 0 and s.item_id != 0) .{
                .type_id = resolveItemType(@ptrCast(self), s.item_id),
                .count = s.count,
                .quality = s.quality,
                .meta = s.meta,
            } else .{};
        }
    }

    /// Encode one workstation's authoritative state at its client-declared array
    /// lengths. `te_block_id` comes from the client's own write: ProcessPackage
    /// drops the package when it disagrees with the block it finds (asm.il ~842882).
    fn buildWorkstationBody(self: *Game, w: *const workstations_mod.Workstation, buf: []u8) ![]u8 {
        var fuel: [workstations_mod.slots_per_group]packages.stock_inv.StockSlot = undefined;
        var input: [workstations_mod.slots_per_group]packages.stock_inv.StockSlot = undefined;
        var tools: [workstations_mod.slots_per_group]packages.stock_inv.StockSlot = undefined;
        var output: [workstations_mod.slots_per_group]packages.stock_inv.StockSlot = undefined;
        self.wsGroupToStock(fuel[0..w.fuel_len], w.fuel[0..w.fuel_len]);
        self.wsGroupToStock(input[0..w.input_len], w.input[0..w.input_len]);
        self.wsGroupToStock(tools[0..w.tools_len], w.tools[0..w.tools_len]);
        self.wsGroupToStock(output[0..w.output_len], w.output[0..w.output_len]);
        return stock_te.buildWorkstationTeBody(buf, 255, w.x, w.y, w.z, w.block_id, .{
            .fuel = fuel[0..w.fuel_len],
            .input = input[0..w.input_len],
            .tools = tools[0..w.tools_len],
            .output = output[0..w.output_len],
            .last_input_count = w.last_input_len,
            .last_input = w.last_input[0..w.last_input_blob_len],
            .queue = w.queue[0..w.queue_len],
            .craft_complete = w.craft_complete[0..w.craft_complete_n],
            .melt = w.melt[0..w.melt_len],
            .is_burning = w.is_burning,
            .burn_time_left = w.burn_time_left,
            .is_player_placed = w.is_player_placed,
        });
    }

    /// One workstation step: burn/craft, then re-broadcast the stations it changed.
    pub fn tickWorkstations(self: *Game, dt: f32) !void {
        self.workstations.tickAllResolved(dt, resolveWorkstationOutput, self);
        try self.broadcastDirtyWorkstations();
    }

    fn broadcastDirtyWorkstations(self: *Game) !void {
        for (self.workstations.items[0..], self.workstations.used[0..]) |*w, u| {
            if (!u or !w.dirty) continue;
            // Nothing is sent before a client write has told us the real array
            // lengths: a guessed count resizes the client's grids.
            if (!w.geometry_known) {
                w.dirty = false;
                continue;
            }
            // Keep dirty until encode+broadcast succeed so a failed send retries next tick.
            const body = self.buildWorkstationBody(w, self.body_buf[8192..16384]) catch |err| {
                self.harness.counters.inc(.encode_errors);
                std.debug.print(
                    "zdtd: workstation TE encode failed at ({d},{d},{d}): {s}\n",
                    .{ w.x, w.y, w.z, @errorName(err) },
                );
                continue;
            };
            self.broadcastNear(
                "NetPackageTileEntity",
                body,
                @floatFromInt(w.x),
                @floatFromInt(w.z),
                self.interest_range,
            ) catch |err| {
                self.harness.counters.inc(.net_send_errors);
                std.debug.print(
                    "zdtd: workstation TE broadcast failed at ({d},{d},{d}): {s}\n",
                    .{ w.x, w.y, w.z, @errorName(err) },
                );
                continue;
            };
            w.dirty = false;
        }
    }

    /// Push a workstation's authoritative state to one peer (lock/open path).
    pub fn sendWorkstationTe(self: *Game, peer: *ln_peer.Peer, x: i32, y: i32, z: i32) !void {
        const w = self.workstations.get(x, y, z) orelse return;
        if (!w.geometry_known) return;
        const body = try self.buildWorkstationBody(w, self.body_buf[8192..16384]);
        try self.sendGame(peer, "NetPackageTileEntity", body);
    }

    fn applyWsGroup(self: *Game, dst: []ecs.components.InvSlot, src: []const packages.stock_inv.StockSlot) void {
        for (dst, 0..) |*d, i| {
            if (i < src.len and src[i].count > 0 and src[i].type_id != 0) {
                d.* = .{
                    .item_id = reverseItemType(self, src[i].type_id),
                    .count = src[i].count,
                    .quality = @min(src[i].quality, 255),
                    .meta = src[i].meta,
                };
            } else {
                d.* = .{};
            }
        }
    }

    fn ecsIdFromItemName(self: *Game, name: []const u8) u16 {
        const id = self.items.ecsIdByName(name);
        if (id != 0) return id;
        if (self.items.byStockName(name)) |st| {
            const sid = self.items.ecsIdFromStockType(st);
            if (sid != 0) return sid;
        }
        // Offline-only aliases when items table is builtin (no game-dir).
        if (self.items.source == .builtin) {
            if (std.mem.eql(u8, name, "resourceScrapIron") or std.mem.eql(u8, name, "resourceScrapLead")) return 1;
            if (std.mem.eql(u8, name, "foodCanBeef")) return 2;
            if (std.mem.eql(u8, name, "resourceWood")) return 7;
            if (std.mem.eql(u8, name, "casinoCoin")) return 6;
        }
        return 0;
    }

    fn fillLootBagFromTable(self: *Game, bag_net_id: i32, loot_list: []const u8, seed: u32) void {
        const list_name = if (loot_list.len > 0) loot_list else "EntityLootContainerRegular";
        var stacks: [assets_loot.max_roll_stacks]assets_loot.Stack = undefined;
        const n = self.loot.rollContainer(list_name, self.partyLootStage(), seed, &stacks);
        if (n == 0) return;
        const slot = self.sim.slotOfNetId(bag_net_id) orelse return;
        if (!self.sim.mask[slot].inventory) return;
        self.sim.inventory[slot].clear();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const eid = self.ecsIdFromItemName(stacks[i].item_name);
            if (eid == 0) continue;
            _ = self.sim.depositItem(slot, eid, stacks[i].count);
        }
        // Ensure bag not empty.
        if (self.sim.inventory[slot].countItem(1) == 0 and self.sim.inventory[slot].slots[0].count == 0) {
            _ = self.sim.depositItem(slot, 1, 5);
        }
    }

    /// Wake prefab sleeper volumes near players; spawn class groups once.
    /// Push the background flusher's atomic totals into apm counters as
    /// per-tick deltas. `world` cannot import `apm` (src/world/root.zig), so the
    /// tick thread samples instead.
    fn sampleFlushCounters(self: *Game) void {
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

    /// Joined players with a transform, in client-slot order. Returns the count.
    fn gatherPlayerPositions(
        self: *Game,
        px: *[max_clients]f32,
        py: *[max_clients]f32,
        pz: *[max_clients]f32,
    ) usize {
        var pn: usize = 0;
        for (&self.clients) |*cl| {
            if (!cl.joined or cl.entity_id <= 0) continue;
            const si = self.sim.slotOfNetId(cl.entity_id) orelse continue;
            if (!self.sim.mask[si].transform) continue;
            if (pn >= px.len) break;
            px[pn] = self.sim.transform[si].x;
            py[pn] = self.sim.transform[si].y;
            pz[pn] = self.sim.transform[si].z;
            pn += 1;
        }
        return pn;
    }

    /// Pure AABB test of every untriggered volume against every player.
    /// Writes one byte per volume so worker ranges never share a byte, and only
    /// reads `*const Store` plus the const player arrays. Serial and parallel
    /// passes produce the identical `hit` array.
    const SleeperScanCtx = struct {
        sl: *const sleepers_mod.Store,
        px: []const f32,
        py: []const f32,
        pz: []const f32,
        hit: []u8,

        fn work(ctx: SleeperScanCtx, begin: usize, end: usize) void {
            var vi = begin;
            while (vi < end) : (vi += 1) {
                if (ctx.sl.volumes[vi].triggered) continue;
                var p: usize = 0;
                while (p < ctx.px.len) : (p += 1) {
                    if (ctx.sl.contains(vi, ctx.px[p], ctx.py[p], ctx.pz[p])) {
                        ctx.hit[vi] = 1;
                        break;
                    }
                }
            }
        }
    };

    fn tickSleeperVolumes(self: *Game) void {
        if (self.sleepers.volumes.len == 0) return;
        var px: [max_clients]f32 = undefined;
        var py: [max_clients]f32 = undefined;
        var pz: [max_clients]f32 = undefined;
        const pn = self.gatherPlayerPositions(&px, &py, &pz);
        if (pn == 0) return;

        // Parallel test, serial apply in volume-index order: the spawn seed is
        // derived from `vi`, so the apply loop must stay serial and ascending.
        var hit: [sleepers_mod.max_volumes]u8 = undefined;
        const vn = @min(self.sleepers.volumes.len, hit.len);
        @memset(hit[0..vn], 0);
        {
            const sc = apm.profiler.scope(&self.harness.prof, .sleeper_scan);
            defer sc.end();
            const ctx = SleeperScanCtx{
                .sl = &self.sleepers,
                .px = px[0..pn],
                .py = py[0..pn],
                .pz = pz[0..pn],
                .hit = hit[0..vn],
            };
            if (self.job_batches and vn >= parallel_util.min_parallel_items) {
                jobs.forSlotRange(vn, ctx, SleeperScanCtx.work);
            } else {
                SleeperScanCtx.work(ctx, 0, vn);
            }
        }
        self.harness.counters.add(.sleeper_volumes_scanned, vn);

        var vi: usize = 0;
        while (vi < vn) : (vi += 1) {
            if (hit[vi] == 0) continue;
            var vol = &self.sleepers.volumes[vi];
            vol.triggered = true;
            self.sleepers.trigger_count += 1;

            const grp = vol.groups[0];
            const seed: u32 = @intCast((vi + 1) *% 2654435761 % 0xffffffff);
            // SleeperVolume::Spawn (asm.il ~1197380): gameStage = Max(0, party
            // stage of the players around the volume). Stock adds a per-volume
            // adjust byte that zdtd's .tts reader does not carry yet.
            const cx: f32 = @floatFromInt(@divTrunc(vol.x0 + vol.x1, 2));
            const cz: f32 = @floatFromInt(@divTrunc(vol.z0 + vol.z1, 2));
            const vol_stage: i32 = @max(0, self.partyStageAround(cx, cz, sleeper_party_radius));
            const stage_spawn = self.gamestages.sleeperEntityGroup(grp.class_name, vol_stage);
            const def = self.resolveSleeperClass(grp.class_name, stage_spawn, seed);
            // Stock draws the per-stage <spawn num=…> for the wave size; the
            // prefab's own min/max is the fallback when no ladder resolved.
            const count: u8 = if (stage_spawn) |sg|
                @intCast(@max(1, @min(sg.num, @as(u16, 255))))
            else if (grp.max_count <= grp.min_count) grp.min_count else blk: {
                const span = grp.max_count - grp.min_count + 1;
                break :blk grp.min_count + @as(u8, @intCast((vi) % span));
            };
            // maxAlive is a per-player ceiling on the wave; without a live
            // sleeper population counter it only caps this burst.
            const alive_cap: u8 = if (stage_spawn) |sg|
                @intCast(@max(1, @min(sg.max_alive, @as(u16, 255))))
            else
                255;

            if (vol.spawns.len > 0) {
                // Stock spawns at authored Class=Sleeper marker cells. Spawn one
                // zombie per marker, capped at the requested count, the marker
                // count and the stage's maxAlive.
                const cap: usize = @min(@as(usize, @min(count, alive_cap)), vol.spawns.len);
                var n: usize = 0;
                while (n < cap) : (n += 1) {
                    const sp = vol.spawns[n];
                    _ = self.sim.spawnSleeperClass(
                        @floatFromInt(sp.x),
                        @floatFromInt(sp.y),
                        @floatFromInt(sp.z),
                        def.max_hp,
                        def.hash,
                        def.loot_list,
                    );
                }
                continue;
            }

            // Fallback (no .tts / no sleeper marker blocks): deterministic scatter
            // across the AABB, better than a center clump. Honest degrade path.
            const spanx: i32 = @max(1, vol.x1 - vol.x0);
            const spanz: i32 = @max(1, vol.z1 - vol.z0);
            const cy: f32 = @floatFromInt(vol.y0 + 1);
            var prng = rng_util.XorShift32.init(seed);
            var n: u8 = 0;
            while (n < count and n < alive_cap and n < 8) : (n += 1) {
                const ox: f32 = @floatFromInt(vol.x0 + @as(i32, @intCast(prng.nextBounded(@intCast(spanx)))));
                const oz: f32 = @floatFromInt(vol.z0 + @as(i32, @intCast(prng.nextBounded(@intCast(spanz)))));
                _ = self.sim.spawnSleeperClass(ox, cy, oz, def.max_hp, def.hash, def.loot_list);
            }
        }
    }

    /// Resolve a SleeperVolumeGroup name to an entity def, stock order first
    /// (SleeperVolume::Spawn, asm.il ~1199169): the already-resolved gamestage
    /// SpawnGroup names an entitygroup, and only its class pick counts. Across
    /// stock Data/Prefabs the volume names are overwhelmingly gamestage group
    /// names (GroupGenericZombie and friends) that entitygroups.xml does not
    /// contain, so without this the fallbacks below hit defaultZombie for
    /// nearly every POI. The entityclass / entitygroup fallbacks stay for
    /// prefabs that do name one directly.
    fn resolveSleeperClass(
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

    /// GameStageDefinition::CalcGameStageAround radius (asm.il ~1093363).
    const sleeper_party_radius: f32 = 100.0;

    /// Runtime AssignIds id for seed chest. Preference order: AssignIds dump
    /// (id_by_name), then optional world-dir override file, then V3.1.4 pin.
    fn seedChestBlockId(self: *Game) u16 {
        const captured: u16 = self.maxdamage.idByName("cntWoodenChestClosed") orelse
            @intCast(packages.stock_deco.cnt_wooden_chest_closed);
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/seed_chest_block_id", .{self.world.world_dir}) catch return captured;
        var buf: [32]u8 = undefined;
        const slice = io_fs.readFileInto(self.allocator, path, &buf) catch return captured;
        const trimmed = std.mem.trim(u8, slice, " \t\r\n");
        const v = std.fmt.parseInt(u16, trimmed, 10) catch return captured;
        return if (v >= 20) v else captured;
    }

    fn broadcastStorageTe(self: *Game, cont: *const containers_mod.Container) !void {
        const body = stock_te.buildStorageTeBody(
            &self.body_buf,
            255,
            cont.pos.x,
            cont.pos.y,
            cont.pos.z,
            cont.block_id,
            cont,
            resolveItemType,
            self,
        ) catch return;
        try self.broadcast("NetPackageTileEntity", body);
    }

    /// zdtd's Block::ActivateBlock (asm.il:127088 / 137044): rewrite meta bit 0x1
    /// (isPowered) and bit 0x2 (isOn) into the stored BlockValue and SetBlockRPC it,
    /// so lights, traps and switches visibly react to the grid. Strictly edge
    /// triggered: a node that did not flip costs one comparison and no packet.
    fn broadcastPowerVisuals(self: *Game) void {
        var i: usize = 0;
        while (i < self.sim.power.node_n) : (i += 1) {
            const n = &self.sim.power.nodes[i];
            const on = ecs.electric.nodeIsOn(n.*);
            if (n.net_synced and n.net_on == on and n.net_powered == n.powered) continue;
            n.net_synced = true;
            n.net_on = on;
            n.net_powered = n.powered;
            const block_id = self.world.blockWorld(n.x, n.y, n.z) catch continue;
            if (block_id == 0) continue;
            const stored = self.blockRawAt(n.x, n.y, n.z);
            const base: u32 = if ((stored & 0xffff) == block_id) stored else @as(u32, block_id);
            var meta = packages.blockMeta(base) &
                ~(packages.block_meta_on | packages.block_meta_powered);
            if (on) meta |= packages.block_meta_on;
            if (n.powered) meta |= packages.block_meta_powered;
            const raw = packages.withBlockMeta(base, meta);
            self.setBlockRaw(n.x, n.y, n.z, raw);
            const dmg = self.getBlockHp(n.x, n.y, n.z);
            const sb = packages.buildSetBlockBodyRaw(self.body_buf[0..96], n.x, n.y, n.z, raw, dmg, -1, -1) catch continue;
            self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(n.x), @floatFromInt(n.z), self.interest_range) catch {
                self.harness.counters.inc(.net_send_errors);
            };
        }
    }

    /// Echo a powered trigger's authoritative state to nearby clients
    /// (StreamModeWrite.ToClient). Silently does nothing when the cell holds no
    /// registered trigger: nothing to describe, and the stock client drops a TE
    /// update for a position where it holds no TileEntity anyway.
    fn broadcastPoweredTriggerTe(self: *Game, x: i32, y: i32, z: i32) !void {
        const ni = self.sim.power.indexOfPosition(x, y, z) orelse return;
        const node = self.sim.power.nodes[ni];
        const block_id = self.world.blockWorld(x, y, z) catch return;
        const props = self.power_registry.lookup(block_id) orelse return;
        const tt = props.trigger_type orelse return;
        // Wire list is the child edges zdtd tracks; the parent link is undirected
        // here, so parentPos stays zero rather than inventing a direction.
        var wires: [stock_te.max_te_wires]stock_te.Vec3i = undefined;
        var wire_n: usize = 0;
        var w: usize = 0;
        while (w < self.sim.power.wire_n and wire_n < wires.len) : (w += 1) {
            const wire = self.sim.power.wires[w];
            const other: u16 = if (wire.a == node.id) wire.b else if (wire.b == node.id) wire.a else continue;
            const oi = self.sim.power.indexOfId(other) orelse continue;
            const on = self.sim.power.nodes[oi];
            wires[wire_n] = .{ .x = on.x, .y = on.y, .z = on.z };
            wire_n += 1;
        }
        const body = stock_te.buildPoweredTriggerTeBody(&self.body_buf, 255, x, y, z, block_id, .{
            .power_item_type = ecs.powerblocks.powerItemTypeOf(tt),
            .wires = wires[0..wire_n],
            .is_powered = node.powered,
            .trigger_type = @intFromEnum(tt),
            .property1 = node.delay_idx,
            .property2 = node.duration_idx,
        }) catch return;
        try self.broadcastNear("NetPackageTileEntity", body, @floatFromInt(x), @floatFromInt(z), self.interest_range);
    }

    /// Open/sync a world container to one peer (stock TE body).
    pub fn sendStorageTe(self: *Game, peer: *ln_peer.Peer, x: i32, y: i32, z: i32) !void {
        const cont = self.containers.get(.{ .x = x, .y = y, .z = z }) orelse return;
        const body = try stock_te.buildStorageTeBody(
            &self.body_buf,
            255,
            cont.pos.x,
            cont.pos.y,
            cont.pos.z,
            cont.block_id,
            cont,
            resolveItemType,
            self,
        );
        try self.sendGame(peer, "NetPackageTileEntity", body);
    }

    fn broadcastLootSpawn(self: *Game, net_id: i32) !void {
        const bi = self.sim.slotOfNetId(net_id) orelse return;
        // Death / multi-stack bags: DroppedLootContainer + ECD bag field.
        var bag_slots: [ecs.components.max_inv_slots]packages.stock_inv.StockSlot = undefined;
        var bag_n: usize = 0;
        if (self.sim.mask[bi].inventory) {
            for (self.sim.inventory[bi].slots) |s| {
                if (s.count > 0 and s.item_id != 0) {
                    bag_slots[bag_n] = packages.stock_inv.slotFromEcs(s, resolveItemType, self);
                    bag_n += 1;
                }
            }
        }
        const spb = try packages.stock_entity.buildEntitySpawnStock(&self.body_buf, .{
            .entity_id = net_id,
            .entity_class = packages.stock_entity.class_dropped_loot_container,
            .x = self.sim.transform[bi].x,
            .y = self.sim.transform[bi].y,
            .z = self.sim.transform[bi].z,
            .yaw = self.sim.transform[bi].yaw,
            .on_ground = true,
            .bag = if (bag_n > 0) bag_slots[0..bag_n] else null,
        });
        try self.broadcastNear(
            "NetPackageEntitySpawn",
            spb,
            self.sim.transform[bi].x,
            self.sim.transform[bi].z,
            self.interest_range,
        );
    }

    /// Stock ItemDropServer path: EntityItem (class "item") with itemClass ECD.
    fn broadcastItemDropSpawn(
        self: *Game,
        net_id: i32,
        stack: packages.stock_inv.StockSlot,
        belongs_player_id: i32,
        client_entity_id: i32,
    ) !void {
        const bi = self.sim.slotOfNetId(net_id) orelse return;
        const slot = if (stack.type_id != 0) stack else blk: {
            // Rebuild from sim inventory first stack.
            if (self.sim.mask[bi].inventory) {
                for (self.sim.inventory[bi].slots) |s| {
                    if (s.count > 0 and s.item_id != 0) {
                        break :blk packages.stock_inv.slotFromEcs(s, resolveItemType, self);
                    }
                }
            }
            break :blk stack;
        };
        if (slot.type_id == 0 or slot.count == 0) {
            try self.broadcastLootSpawn(net_id);
            return;
        }
        const spb = try packages.stock_entity.buildEntitySpawnStock(&self.body_buf, .{
            .entity_id = net_id,
            .entity_class = packages.stock_entity.class_item,
            .x = self.sim.transform[bi].x,
            .y = self.sim.transform[bi].y,
            .z = self.sim.transform[bi].z,
            .yaw = self.sim.transform[bi].yaw,
            .on_ground = true,
            .item_drop = slot,
            .belongs_player_id = belongs_player_id,
            .client_entity_id = client_entity_id,
        });
        try self.broadcastNear(
            "NetPackageEntitySpawn",
            spb,
            self.sim.transform[bi].x,
            self.sim.transform[bi].z,
            self.interest_range,
        );
    }

    /// Returns false when the chunk was soft-dropped on a full reliable window.
    /// The caller must then leave the key out of `c.streamed`: the stream tick
    /// only sends keys it does not already hold, so recording a dropped chunk
    /// leaves a permanent hole. A hole anywhere in the player's 2-chunk mesh
    /// halo pins that chunk at NeedsRegeneration, so the client never builds a
    /// collision mesh under the player. It then free-falls, Origin's downward
    /// ray fails every frame, and RespawnProgress.WaitingForCollider never
    /// clears: the join hangs on "Creating player".
    fn sendSpawnChunk(self: *Game, peer: *ln_peer.Peer, cx: i32, cz: i32) !bool {
        // Resident miss = disk load or procedural gen (worldgen W2 runs here,
        // on the tick, bounded by chunk_adds_per_stream_tick). world/ may not
        // import apm, so the scope lives at this call site.
        const ch = blk: {
            const gs = apm.profiler.scope(&self.harness.prof, .chunk_gen);
            defer gs.end();
            break :blk try self.world.getOrCreate(.{ .x = cx, .z = cz });
        };
        // After TTS paint, create storage TEs for known chest block ids (loot fill once).
        self.ensurePrefabStorageInChunk(ch, cx, cz);
        // Prefer biomes.png color→id mode; fallback height band. Cached on the
        // chunk so re-sends to other clients skip the 256-lookup dominant scan.
        const biome_id: u8 = ch.biome_id orelse blk: {
            const b: u8 = if (self.world.biomes) |*bm|
                bm.chunkDominant(cx, cz)
            else hb: {
                var hsum: u32 = 0;
                for (ch.heights) |h| hsum += h;
                const havg: u8 = @intCast(hsum / 256);
                break :hb if (havg < 40) @as(u8, 5) else if (havg > 90) @as(u8, 1) else 3;
            };
            ch.biome_id = b;
            break :blk b;
        };
        // Feed store columns (TTS-painted) into stock encoder.
        const BlockCtx = struct {
            fn at(ctx: ?*anyopaque, lx: i32, y: i32, lz: i32) u32 {
                const c: *const world_store.Chunk = @ptrCast(@alignCast(ctx.?));
                return c.rawAt(lx, y, lz);
            }
            fn tex(ctx: ?*anyopaque, lx: i32, y: i32, lz: i32) u64 {
                const c: *const world_store.Chunk = @ptrCast(@alignCast(ctx.?));
                return c.texAt(lx, y, lz);
            }
            fn dens(ctx: ?*anyopaque, lx: i32, y: i32, lz: i32) ?u8 {
                const c: *const world_store.Chunk = @ptrCast(@alignCast(ctx.?));
                return c.densAt(lx, y, lz);
            }
        };
        const TexCtx = struct {
            t: *const assets_block_textures.Table,
            fn def(ctx: ?*anyopaque, type_id: u16) u64 {
                const self_t: *const @This() = @ptrCast(@alignCast(ctx.?));
                return self_t.t.get(type_id);
            }
        };
        var tex_ctx: TexCtx = .{ .t = &self.block_textures };
        // Stock Chunk.write payload inside NetPackageChunk (overwrite=false first delivery).
        const body = try packages.stock_chunk.buildNetPackageChunkNew(&self.body_buf, .{
            .cx = cx,
            .cz = cz,
            .heights = &ch.heights,
            .ticks = self.sim.director.clock.worldTimeBits(),
            .biome = biome_id,
            .block_at = BlockCtx.at,
            .block_ctx = ch,
            .tex_at = BlockCtx.tex,
            .default_tex = TexCtx.def,
            .default_tex_ctx = &tex_ctx,
            .dens_at = BlockCtx.dens,
        });
        const before_out = self.harness.counters.get(.net_packets_out);
        try self.sendGame(peer, "NetPackageChunk", body);
        const after_out = self.harness.counters.get(.net_packets_out);
        const delivered = after_out != before_out;
        if (!delivered) {
            std.debug.print("zdtd: FAILED NetPackageChunk cx={d} cz={d} body={d}\n", .{ cx, cz, body.len });
            return false;
        }
        // Storage TEs in this column (placed chests, loot containers).
        try self.sendContainersInChunk(peer, cx, cz);
        return true;
    }

    /// Scan painted columns for known storage AssignIds; create + roll loot once.
    /// Deterministic loot seed from world block position (stable across chunk scans).
    fn lootSeedAt(wx: i32, wy: i32, wz: i32) u32 {
        return @as(u32, @bitCast(wx *% 73856093 ^ wz *% 19349663 ^ wy));
    }

    /// Also honor prefab TTS TE list (Loot/SecureLoot/Composite types).
    fn ensurePrefabStorageInChunk(self: *Game, ch: *world_store.Chunk, cx: i32, cz: i32) void {
        if (ch.te_scanned) return;
        const blocks = ch.blocks orelse return;
        // Always-on evidence for the "TE loot as a job batch" gap: the loot roll
        // is microseconds, this up-to-65536-cell walk is where the time goes.
        const ts = apm.profiler.scope(&self.harness.prof, .te_scan);
        var cells: u64 = 0;
        defer {
            ts.end();
            self.harness.counters.add(.te_scan_cells, cells);
        }
        const base_x = cx * 16;
        const base_z = cz * 16;
        var found: u32 = 0;
        // Block ids repeat in long runs (terrain), so memo the last id's verdict
        // to skip the hash probe in isStorageBlockId for nearly every cell.
        var last_id: u16 = 0;
        var last_is_storage = false;
        // y outermost so idx advances contiguously (y stride is 1 KiB; the old
        // y-inner order made all 65k reads cache misses across a 256 KiB array).
        var y: i32 = 0;
        while (y < world_store.y_dim) : (y += 1) {
            var lz: i32 = 0;
            while (lz < 16) : (lz += 1) {
                var lx: i32 = 0;
                while (lx < 16) : (lx += 1) {
                    cells += 1;
                    const idx = @as(usize, @intCast(lx + lz * 16 + y * 256));
                    const id: u16 = @truncate(blocks[idx]);
                    if (id == 0) continue;
                    if (id != last_id) {
                        last_id = id;
                        last_is_storage = self.isStorageBlockId(id);
                    }
                    if (!last_is_storage) continue;
                    const wx = base_x + lx;
                    const wz = base_z + lz;
                    const pos = containers_mod.PosKey{ .x = wx, .y = y, .z = wz };
                    if (self.containers.get(pos) != null) continue;
                    const cont = self.containers.getOrCreate(pos, 8, id) orelse continue;
                    if (cont.slots[0].count == 0 and cont.slots[1].count == 0) {
                        self.fillContainerFromLoot(cont, "woodenChest", lootSeedAt(wx, y, wz));
                    }
                    found += 1;
                    if (found >= 32) return;
                }
            }
        }
        // Prefab TE list (TileEntityType Loot=5, SecureLoot=10, Composite=25).
        if (self.world.prefabs) |*pf| {
            const TeCtx = struct {
                g: *Game,
                found: *u32,
                fn onTe(ctx: ?*anyopaque, wx: i32, wy: i32, wz: i32, te_type: u8) void {
                    const tc: *@This() = @ptrCast(@alignCast(ctx.?));
                    if (tc.found.* >= 48) return;
                    // Loot-like types only.
                    if (!(te_types.isStorageLike(te_type) or te_type == te_types.powered or te_types.isSignLike(te_type) or te_type == te_types.light)) return;
                    const pos = containers_mod.PosKey{ .x = wx, .y = wy, .z = wz };
                    if (tc.g.containers.get(pos) != null) return;
                    const block_id: u16 = tc.g.world.blockWorld(wx, wy, wz) catch 0;
                    const id: u16 = if (block_id != 0) block_id else tc.g.seedChestBlockId();
                    const cont = tc.g.containers.getOrCreate(pos, 8, id) orelse return;
                    if (cont.slots[0].count == 0 and cont.slots[1].count == 0) {
                        tc.g.fillContainerFromLoot(cont, "woodenChest", lootSeedAt(wx, wy, wz));
                    }
                    tc.found.* += 1;
                }
            };
            var te_found: u32 = found;
            var tc: TeCtx = .{ .g = self, .found = &te_found };
            pf.foreachTeInChunk(cx, cz, TeCtx.onTe, &tc);
            // Scan complete unless the TE cap truncated it; then retry next send.
            if (te_found < 48) ch.te_scanned = true;
        } else {
            ch.te_scanned = true;
        }
    }

    fn fillContainerFromLoot(self: *Game, cont: *containers_mod.Container, loot_name: []const u8, seed: u32) void {
        var stacks: [assets_loot.max_roll_stacks]assets_loot.Stack = undefined;
        const n = self.loot.rollContainer(loot_name, self.partyLootStage(), seed, &stacks);
        var si: usize = 0;
        var i: usize = 0;
        while (i < n and si < cont.slot_count) : (i += 1) {
            const eid = self.ecsIdFromItemName(stacks[i].item_name);
            if (eid == 0) continue;
            cont.setSlot(si, .{ .item_id = eid, .count = stacks[i].count, .quality = 1 });
            si += 1;
        }
    }

    fn sendContainersInChunk(self: *Game, peer: *ln_peer.Peer, cx: i32, cz: i32) !void {
        const x0 = cx * 16;
        const z0 = cz * 16;
        const x1 = x0 + 16;
        const z1 = z0 + 16;
        var i: usize = 0;
        while (i < containers_mod.max_containers) : (i += 1) {
            if (!self.containers.used[i]) continue;
            const cont = &self.containers.items[i];
            if (cont.pos.x < x0 or cont.pos.x >= x1 or cont.pos.z < z0 or cont.pos.z >= z1) continue;
            try self.sendStorageTe(peer, cont.pos.x, cont.pos.y, cont.pos.z);
        }
    }

    fn clientHasStreamed(c: *const Client, key: i64) bool {
        var i: usize = 0;
        while (i < c.streamed_n) : (i += 1) {
            if (c.streamed[i] == key) return true;
        }
        return false;
    }

    fn clientAddStreamed(self: *Game, c: *Client, key: i64) void {
        if (clientHasStreamed(c, key)) return;
        if (c.streamed_n >= max_streamed_chunks_cap) {
            // drop oldest (FIFO shift; order only matters for this policy)
            var i: usize = 1;
            while (i < c.streamed_n) : (i += 1) c.streamed[i - 1] = c.streamed[i];
            c.streamed_n -= 1;
        }
        c.streamed[c.streamed_n] = key;
        c.streamed_n += 1;
        const warn_at = @max(@as(usize, 1), (self.max_streamed_chunks * 4) / 5);
        if (!c.stream_cap_warned and c.streamed_n >= warn_at) {
            c.stream_cap_warned = true;
            std.debug.print(
                "zdtd: peer {d} stream queue near capacity n={d}/{d} (warn>={d})\n",
                .{ c.slot, c.streamed_n, self.max_streamed_chunks, warn_at },
            );
        }
    }

    fn clientRemoveStreamed(c: *Client, key: i64) void {
        var i: usize = 0;
        while (i < c.streamed_n) : (i += 1) {
            if (c.streamed[i] != key) continue;
            // Membership only; swap-remove avoids O(n) memmove.
            c.streamed_n -= 1;
            c.streamed[i] = c.streamed[c.streamed_n];
            return;
        }
    }

    fn sendSpawnArea(self: *Game, peer: *ln_peer.Peer, wx: i32, wz: i32, radius: i32) !void {
        const t = world_store.World.worldToChunk(wx, wz);
        // Honor radius 0 (single spawn chunk). Cap 17×17 for viewDist 8 mesh core.
        var r: i32 = if (radius < 0) 0 else radius;
        if (r > self.spawn_area_radius_max) r = self.spawn_area_radius_max;
        var client_ptr: ?*Client = null;
        for (&self.clients) |*cl| {
            if (cl.peer == peer) {
                client_ptr = cl;
                break;
            }
        }
        var dz: i32 = -r;
        while (dz <= r) : (dz += 1) {
            var dx: i32 = -r;
            while (dx <= r) : (dx += 1) {
                const cx = t.pos.x + dx;
                const cz = t.pos.z + dz;
                // Re-sending a chunk the client already holds costs reliable
                // window the missing chunks need, and the client logs
                // "chunk already loaded" for every one.
                if (client_ptr) |cl| {
                    if (clientHasStreamed(cl, packages.makeChunkKey(cx, cz))) continue;
                }
                const delivered = try self.sendSpawnChunk(peer, cx, cz);
                if (delivered) {
                    if (client_ptr) |cl| self.clientAddStreamed(cl, packages.makeChunkKey(cx, cz));
                }
                // Let ACKs land between multi-chunk sends.
                self.pollNetOnce();
            }
        }
    }

    /// Stream chunks around player and remove far ones (stock ChunkRemove key).
    /// Caps: `self.max_streamed_chunks`, `chunk_stream_radius_{min,max}`,
    /// `self.chunk_adds_per_stream_tick` (named; no magic pacing numbers).
    fn streamChunksForClient(self: *Game, c: *Client) !void {
        const cs = apm.profiler.scope(&self.harness.prof, .chunk_stream);
        defer cs.end();
        const peer = c.peer orelse return;
        if (self.sim.slotOfNetId(c.entity_id)) |si| {
            const t = world_store.World.worldToChunk(@intFromFloat(self.sim.transform[si].x), @intFromFloat(self.sim.transform[si].z));
            // Keep a hole-free disk so light/mesh neighbor rings stay valid.
            // Client mesh needs ~2-chunk halo: with r=4 only the inner 5×5 (25)
            // become CGO; spawn overlay needs viewDist^2-10 (viewDist 7 → 39).
            // Stream up to view_radius (max self.chunk_stream_radius_max) so the meshable core clears the bar.
            var r: i32 = if (c.view_radius < 1) self.chunk_stream_radius_min else c.view_radius;
            if (r < self.chunk_stream_radius_min) r = self.chunk_stream_radius_min;
            if (r > self.chunk_stream_radius_max) r = self.chunk_stream_radius_max;
            // Shrink to a square that fits the budget: truncating the raster scan
            // instead would leave a southern band, not the centered hole-free disk
            // the comment above requires (radius 7 wants 225 vs a 169 cap).
            while (r > 1 and @as(usize, @intCast((2 * r + 1) * (2 * r + 1))) > self.max_streamed_chunks) r -= 1;
            const tcx = t.pos.x;
            const tcz = t.pos.z;
            const side: i32 = 2 * r + 1;
            // Relative membership of currently streamed keys inside the view
            // square: O(streamed_n) build, O(1) probe. Replaces O(n²) desired[]
            // linear scans (up to 169×169 per client per stream period).
            var in_view = std.StaticBitSet(256).initEmpty();
            {
                var si_i: usize = 0;
                while (si_i < c.streamed_n) : (si_i += 1) {
                    const key = c.streamed[si_i];
                    const cx = packages.extractChunkKeyX(key);
                    const cz = packages.extractChunkKeyZ(key);
                    const dx = cx - tcx;
                    const dz = cz - tcz;
                    if (@abs(dx) > r or @abs(dz) > r) continue;
                    const bit: usize = @intCast((dx + r) + (dz + r) * side);
                    if (bit < 256) in_view.set(bit);
                }
            }
            // removes: keys outside the current square
            var i: usize = 0;
            while (i < c.streamed_n) {
                const key = c.streamed[i];
                const cx = packages.extractChunkKeyX(key);
                const cz = packages.extractChunkKeyZ(key);
                const dx = cx - tcx;
                const dz = cz - tcz;
                const keep = @abs(dx) <= r and @abs(dz) <= r;
                if (!keep) {
                    const rb = try packages.buildChunkRemoveBody(self.body_buf[0..16], cx, cz);
                    try self.sendGame(peer, "NetPackageChunkRemove", rb);
                    // Stock never sends this on view unload: DecoManager.ResetDecosForWorldChunk
                    // is only broadcast from RegionFileManager chunk deletion and the C2S
                    // reset handler (asm.il 1186504 / 807955). With join-time deco objects
                    // live it would run RestoreGeneratedDecos over our trees on every walk-away,
                    // and they can never be resent (single window). Only send when we sent none.
                    if (!self.deco_trees) {
                        if (packages.stock_deco.buildDecoResetWorldChunk(self.body_buf[16..32], cx, cz)) |db| {
                            self.sendGame(peer, "NetPackageDecoResetWorldChunk", db) catch {};
                        } else |_| {}
                    }
                    clientRemoveStreamed(c, key);
                    // do not advance i: swap-remove put a new key at i
                } else {
                    i += 1;
                }
            }
            // adds: enough per pass to fill 13×13 before overlay timeout; still
            // paced so LiteNet reliable window can drain.
            var added: u32 = 0;
            var dz: i32 = -r;
            outer: while (dz <= r) : (dz += 1) {
                var dx: i32 = -r;
                while (dx <= r) : (dx += 1) {
                    if (added >= self.chunk_adds_per_stream_tick) break :outer;
                    const bit: usize = @intCast((dx + r) + (dz + r) * side);
                    if (bit < 256 and in_view.isSet(bit)) continue;
                    const cx = tcx + dx;
                    const cz = tcz + dz;
                    const key = packages.makeChunkKey(cx, cz);
                    // Cap path / race: bitset miss but list still holds key.
                    if (clientHasStreamed(c, key)) continue;
                    if (!try self.sendSpawnChunk(peer, cx, cz)) continue;
                    self.clientAddStreamed(c, key);
                    in_view.set(bit);
                    // No per-chunk deco: the client drains and nulls DecoManager.loadedDecos
                    // at the end of OnWorldLoaded, so a post-join DecoUpdate either NREs
                    // (firstPackage=false) or is silently discarded (firstPackage=true).
                    // Deco ships once, at RequestToEnterGame (sendDecoAroundSpawn).
                    added += 1;
                }
            }
        }
    }

    /// Fan-out already-framed user payload to one peer (no re-encode). Soft-drops
    /// WindowFull the same way as droppable streaming packages.
    fn sendFramedDroppable(self: *Game, peer: *ln_peer.Peer, framed: []const u8) void {
        const max_attempts: u32 = 64;
        var attempts: u32 = 0;
        while (attempts < max_attempts) : (attempts += 1) {
            peer.sendReliable(&self.net.sock, framed) catch |err| switch (err) {
                error.WindowFull => {
                    peer.resendPending(&self.net.sock) catch {
                        self.harness.counters.inc(.net_send_errors);
                    };
                    self.pollNetOnce();
                    if (attempts % 4 == 3) clock.sleepNs(500_000);
                    continue;
                },
                else => {
                    // Hard send failure (not window pressure): count + rate-limit log.
                    self.harness.counters.inc(.net_send_errors);
                    const n = self.harness.counters.get(.net_send_errors);
                    if (n == 1 or n % 100 == 0) {
                        std.debug.print(
                            "zdtd: framed stream send failed local_id={d} n={d}: {s}\n",
                            .{ peer.local_id, n, @errorName(err) },
                        );
                    }
                    return;
                },
            };
            self.harness.counters.add(.net_packets_out, 1);
            self.harness.counters.add(.net_bytes_out, framed.len);
            self.harness.counters.inc(.packages_broadcast);
            self.pollNetAfterSend();
            return;
        }
        // Same signal as sendGame drops: counter always, log rate-limited.
        self.harness.counters.inc(.reliable_window_drops);
        const n = self.harness.counters.get(.reliable_window_drops);
        if (n == 1 or n % 100 == 0) {
            std.debug.print(
                "zdtd: drop framed stream (reliable window full) n={d} local_id={d}\n",
                .{ n, peer.local_id },
            );
        }
    }

    fn broadcast(self: *Game, name: []const u8, body: []const u8) !void {
        try self.broadcastExcept(name, body, null);
    }

    /// World-position broadcast: only clients whose player is within
    /// `range_blocks` of (wx,wz). Chat/time stay global via broadcast().
    fn broadcastNear(self: *Game, name: []const u8, body: []const u8, wx: f32, wz: f32, range_blocks: f32) !void {
        // Encode failures were counter-only (no log). Match sendGame: counter +
        // rate-limited log. Successful fan-out must also tick net_packets/bytes
        // so apm RED rates reflect broadcast traffic (chat, setblock, time, …).
        const framed = packages.framed(&self.send_buf, name, body) catch |err| {
            self.harness.counters.inc(.encode_errors);
            const n = self.harness.counters.get(.encode_errors);
            if (n == 1 or n % 100 == 0) {
                std.debug.print(
                    "zdtd: encode failed pkg={s} body_len={d} n={d}: {s}\n",
                    .{ name, body.len, n, @errorName(err) },
                );
            }
            return err;
        };
        for (&self.clients) |*c| {
            const p = c.peer orelse continue;
            if (!c.joined) continue;
            // No sim player yet (join in progress): deliver rather than drop.
            if (self.sim.playerByPeer(c.slot)) |ps| {
                const dx = self.sim.transform[ps].x - wx;
                const dz = self.sim.transform[ps].z - wz;
                if (dx * dx + dz * dz > range_blocks * range_blocks) continue;
            }
            p.sendReliable(&self.net.sock, framed) catch |err| {
                self.harness.counters.inc(.net_send_errors);
                const n = self.harness.counters.get(.net_send_errors);
                if (n == 1 or n % 100 == 0) {
                    std.debug.print(
                        "zdtd: broadcast send failed pkg={s} local_id={d} n={d}: {s}\n",
                        .{ name, p.local_id, n, @errorName(err) },
                    );
                }
                continue;
            };
            self.harness.counters.add(.net_packets_out, 1);
            self.harness.counters.add(.net_bytes_out, framed.len);
            self.harness.counters.inc(.packages_broadcast);
        }
    }

    fn broadcastExcept(self: *Game, name: []const u8, body: []const u8, except_slot: ?usize) !void {
        const framed = packages.framed(&self.send_buf, name, body) catch |err| {
            self.harness.counters.inc(.encode_errors);
            const n = self.harness.counters.get(.encode_errors);
            if (n == 1 or n % 100 == 0) {
                std.debug.print(
                    "zdtd: encode failed pkg={s} body_len={d} n={d}: {s}\n",
                    .{ name, body.len, n, @errorName(err) },
                );
            }
            return err;
        };
        for (&self.clients) |*c| {
            const p = c.peer orelse continue;
            if (!c.joined) continue;
            if (except_slot) |ex| if (c.slot == ex) continue;
            p.sendReliable(&self.net.sock, framed) catch |err| {
                self.harness.counters.inc(.net_send_errors);
                const n = self.harness.counters.get(.net_send_errors);
                if (n == 1 or n % 100 == 0) {
                    std.debug.print(
                        "zdtd: broadcast send failed pkg={s} local_id={d} n={d}: {s}\n",
                        .{ name, p.local_id, n, @errorName(err) },
                    );
                }
                continue;
            };
            self.harness.counters.add(.net_packets_out, 1);
            self.harness.counters.add(.net_bytes_out, framed.len);
            self.harness.counters.inc(.packages_broadcast);
        }
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
    fn replicatePlayerHealth(self: *Game) void {
        var i: ecs.Slot = 0;
        while (i < ecs.max_entities) : (i += 1) {
            if (!self.sim.alive[i] or !self.sim.mask[i].dirty or !self.sim.dirty[i].hp) continue;
            // Cleared even when nothing goes out (no observers, not a player):
            // stock clears Stat.Changed right after the poll, and a bit left set
            // would re-send the same value on every later tick.
            self.sim.dirty[i].hp = false;
            // Player vitals only. Stock also runs EntityStats::TickWait for NPCs;
            // zdtd still keeps zombie hp server-side, so nothing consumes the bit
            // for them (docs/MISSING_FEATURES.md, entity lifecycle).
            if (!self.sim.mask[i].player or !self.sim.mask[i].health) continue;
            if (!self.sim.mask[i].network_id or !self.sim.mask[i].transform) continue;
            const nid = self.sim.network_id[i].id;
            if (nid <= 0) continue;
            const body = packages.buildEntityStatChangedBody(
                self.body_buf[0..32],
                nid,
                -1,
                .health,
                self.sim.health[i].hp,
                self.sim.health[i].max_hp,
                0,
            ) catch {
                self.harness.counters.inc(.encode_errors);
                continue;
            };
            self.harness.counters.inc(.packages_encoded);
            const tp = self.sim.transform[i];
            for (&self.clients) |*cl| {
                if (!cl.joined or !cl.entered) continue;
                const peer = cl.peer orelse continue;
                // No owner skip here (motion has one): the victim's own client is
                // exactly who needs this, it drives the flinch and the death screen.
                const owner = self.sim.player[i].peer_slot == @as(i32, @intCast(cl.slot));
                if (!owner and !self.clientObserves(cl, tp.x, tp.z)) continue;
                // Reliable: a dropped hp=0 leaves the player alive on their own
                // screen but dead to the server, unable to fight back.
                self.sendGame(peer, "NetPackageEntityStatChanged", body) catch {
                    self.harness.counters.inc(.net_send_errors);
                };
            }
        }
    }

    /// True when (wx,wz) is inside this client's interest box.
    fn clientObserves(self: *const Game, cl: *const Client, wx: f32, wz: f32) bool {
        if (cl.entity_id <= 0) return false;
        const oi = self.sim.slotOfNetId(cl.entity_id) orelse return false;
        if (!self.sim.mask[oi].transform) return false;
        const op = self.sim.transform[oi];
        return interest.inRange(op.x, op.z, wx, wz, cl.view_radius);
    }

    /// C2S NetPackageAddRemoveBuff (asm.il 202415). Stock's server branch re-Setups
    /// the package and fans it out to the clients attached to the entity
    /// (ProcessPackage, asm.il 202531); we validate first, because the body is
    /// entirely client-chosen: a peer may only drive its own player entity, and
    /// only with a buff name the catalog resolves.
    fn handleAddRemoveBuff(self: *Game, c: *Client, body: []const u8) !void {
        var name_buf: [packages.stock_buff.max_buff_name]u8 = undefined;
        const req = packages.stock_buff.parseAddRemoveBuff(body, &name_buf) catch {
            self.harness.counters.inc(.buff_rejects);
            self.harness.counters.inc(.c2s_malformed);
            return;
        };
        if (req.entity_id != c.entity_id) {
            self.harness.counters.inc(.buff_rejects);
            self.harness.counters.inc(.ownership_rejects);
            return;
        }
        const def_id = self.buffs.indexOfName(req.name) orelse {
            // Unknown names are the loud case: a client-side mod, a catalog
            // mismatch, or probing. Rate-limit so it cannot flood the log.
            self.harness.counters.inc(.buff_rejects);
            const n = self.harness.counters.get(.buff_rejects);
            if (n == 1 or n % 100 == 0) {
                std.debug.print("zdtd: buff name not in catalog slot={d} n={d}\n", .{ c.slot, n });
            }
            return;
        };
        const ps = self.sim.playerByPeer(c.slot) orelse return;
        const set = self.sim.buffsMut(ps);
        if (!req.adding) {
            // Flag only: the tick removes and broadcasts, so client-requested and
            // expiry removals leave the world through one path.
            _ = ecs.buff.remove(set, def_id);
            return;
        }
        const def = self.buffs.byId(def_id) orelse return;
        const res = ecs.buff.add(set, .{
            .def_id = def_id,
            .duration = def.duration,
            .stack_type = def.stack_type,
            .update_rate_ticks = def.update_rate_ticks,
            .remove_on_death = def.remove_on_death,
            // The client's requested duration is deliberately dropped: any value
            // >= 0 on the wire calls BuffClass::set_DurationMax on every receiving
            // client and retunes that buff class for the whole session
            // (asm.il 736259 IL_00cf, set_DurationMax asm.il 732658).
        }, ecs.buff.duration_from_class, req.instigator_id, req.instigator_x, req.instigator_y, req.instigator_z);
        if (res == .no_slot) {
            self.harness.counters.inc(.buff_rejects);
            return;
        }
        try self.relayBuff(c.entity_id, def.name, true, req.instigator_id, c.slot);
    }

    /// Full buff list of every OTHER joined player, as NetPackageEntityStatsBuff.
    /// A relayed AddRemoveBuff only reaches the peers connected at the time, so a
    /// late joiner needs the whole list once. The client applies this package to
    /// remote entities only (asm.il 202268), which is exactly the set we send.
    fn sendBuffSync(self: *Game, peer: *ln_peer.Peer, c: *const Client) !void {
        var blob_buf: [1024]u8 = undefined;
        for (&self.clients) |*other| {
            if (!other.joined or other.slot == c.slot) continue;
            const blob = self.playerBuffBlob(other.slot, &blob_buf);
            if (blob.len == 0) continue;
            const body = packages.stock_buff.buildEntityStatsBuffBody(&self.body_buf, other.entity_id, blob) catch {
                self.harness.counters.inc(.encode_errors);
                continue;
            };
            try self.sendGame(peer, "NetPackageEntityStatsBuff", body);
        }
    }

    /// EntityBuffs blob for a peer's player. Empty (not even a header) when the
    /// player carries no buffs, so callers can skip the send entirely.
    fn playerBuffBlob(self: *Game, peer_slot: usize, buf: []u8) []const u8 {
        const ps = self.sim.playerByPeer(peer_slot) orelse return &.{};
        if (!self.sim.mask[ps].buffs) return &.{};
        var values: [ecs.components.max_buffs_per_entity]packages.stock_buff.BuffValueWire = undefined;
        var n: usize = 0;
        for (self.sim.buffs[ps].slots) |b| {
            if (!b.active) continue;
            const def = self.buffs.byId(b.def_id) orelse continue;
            values[n] = .{
                .name = def.name,
                .stack_mult = b.stack_mult,
                .duration_ticks = b.duration_ticks,
                .instigator_id = b.instigator_id,
                .flags = @bitCast(b.flags),
                .update_ticks = b.update_ticks,
                .instigator_x = b.instigator_x,
                .instigator_y = b.instigator_y,
                .instigator_z = b.instigator_z,
            };
            n += 1;
        }
        if (n == 0) return &.{};
        return packages.stock_buff.writeEntityBuffs(buf, values[0..n]) catch &.{};
    }

    /// Fan an add/remove out to the observers of `entity_id`. duration is always
    /// -1 so the receiving client uses its own buffs.xml BuffClass duration.
    fn relayBuff(self: *Game, entity_id: i32, buff_name: []const u8, adding: bool, instigator_id: i32, except_slot: ?usize) !void {
        const b = packages.stock_buff.buildAddRemoveBuffBody(&self.body_buf, .{
            .entity_id = entity_id,
            .name = buff_name,
            .duration = ecs.buff.duration_from_class,
            .adding = adding,
            .instigator_id = instigator_id,
            .instigator_x = 0,
            .instigator_y = 0,
            .instigator_z = 0,
        }) catch {
            self.harness.counters.inc(.encode_errors);
            return;
        };
        try self.broadcastExcept("NetPackageAddRemoveBuff", b, except_slot);
    }

    /// Drain the tick's buff removals. Everyone gets them, the owner included:
    /// ProcessPackage applies to any EntityAlive, so this is what clears the
    /// local HUD icon as well as the observers' (asm.il 202531).
    fn broadcastBuffExpiries(self: *Game, r: *const ecs.TickResult) !void {
        var i: u8 = 0;
        while (i < r.buff_expired_n) : (i += 1) {
            const ex = r.buff_expired[i];
            const def = self.buffs.byId(ex.def_id) orelse continue;
            try self.relayBuff(ex.entity_id, def.name, false, -1, null);
        }
    }

    /// M11 serialize-once interest: for each entity that needs a motion send,
    /// encode PosAndRot (and zombie Speeds/AliveFlags) once, frame once, then
    /// fan-out framed bytes to interested peers. Cost ~ O(dirty × interest), not
    /// O(players × entities × encode). Dirty pos/rot/spawn/flags clear after pass.
    fn replicate(self: *Game) !void {
        const sc = apm.profiler.scope(&self.harness.prof, .replicate);
        defer sc.end();
        for (&self.clients) |*c| {
            // Persistent socket failure here is the "player times out silently"
            // path; keep it visible via the send-error counter.
            if (c.peer) |p| p.resendPending(&self.net.sock) catch self.harness.counters.inc(.net_send_errors);
        }
        // Continuous stock chunk stream around each player (ChunkRemove far keys).
        if (self.wire_chunks and self.tick_n % self.chunk_stream_period_ticks == 0) {
            for (&self.clients) |*cl| {
                if (cl.peer == null or !(cl.entered or cl.world_ready)) continue;
                self.streamChunksForClient(cl) catch |err| {
                    self.harness.counters.inc(.stream_errors);
                    const n = self.harness.counters.get(.stream_errors);
                    if (n == 1 or n % 100 == 0) {
                        std.debug.print(
                            "zdtd: chunk stream failed slot={d} entity={d} n={d}: {s}\n",
                            .{ cl.slot, cl.entity_id, n, @errorName(err) },
                        );
                    }
                };
            }
        }
        // Health before the motion gate: a hit must reach the victim on the tick
        // it lands, and the gate's early returns would swallow it every other tick.
        self.replicatePlayerHealth();
        // Motion every other tick so join/control packages keep window room.
        if (self.tick_n % self.motion_replicate_period_ticks != 0) {
            self.clearDeadKnownEntities();
            return;
        }
        // Empty world: still reconcile known bits if anything died this tick.
        if (self.sim.entity_count == 0) {
            self.clearDeadKnownEntities();
            return;
        }

        var pos_frame_buf: [replicate_frame_cap]u8 = undefined;
        var speeds_frame_buf: [replicate_frame_cap]u8 = undefined;
        var flags_frame_buf: [replicate_frame_cap]u8 = undefined;

        // Observer interest cells resolved once per pass (sim is not mutated
        // below), not per entity × client in each interest loop.
        var obs_cx: [max_clients]i32 = .{0} ** max_clients;
        var obs_cz: [max_clients]i32 = .{0} ** max_clients;
        // Whether the cell above is real. An unresolved observer keeps (0,0),
        // which the unload pass below must not read as "everything is far away":
        // that would evict the client's whole known set from the origin cell.
        var obs_ok: [max_clients]bool = .{false} ** max_clients;
        for (&self.clients, 0..) |*cl, ci| {
            // Empty/joining slots have no entity; skip before the net-id lookup.
            if (!cl.joined or cl.peer == null or cl.entity_id <= 0) continue;
            if (self.sim.slotOfNetId(cl.entity_id)) |si| {
                const oc = interest.cellOf(self.sim.transform[si].x, self.sim.transform[si].z);
                obs_cx[ci] = oc.cx;
                obs_cz[ci] = oc.cz;
                obs_ok[ci] = true;
            }
        }

        var i: ecs.Slot = 0;
        while (i < ecs.max_entities) : (i += 1) {
            if (!self.sim.alive[i] or !self.sim.mask[i].transform or !self.sim.mask[i].network_id) continue;
            const ecell = interest.cellOf(self.sim.transform[i].x, self.sim.transform[i].z);

            // Spawn-on-approach is per-observer (known_entities); still entity-outer
            // so we only build EntitySpawn once when multiple clients need it.
            const is_mob = self.sim.mask[i].kind and (self.sim.kind[i] == .zombie or self.sim.kind[i] == .animal);
            var need_spawn_any = false;
            if (is_mob) {
                for (&self.clients, 0..) |*cl, ci| {
                    if (!cl.joined or !cl.entered or cl.peer == null) continue;
                    if (cl.known_entities.isSet(i)) continue;
                    if (!interest.cellsInRange(obs_cx[ci], obs_cz[ci], ecell.cx, ecell.cz, cl.view_radius)) continue;
                    need_spawn_any = true;
                    break;
                }
            }
            if (need_spawn_any) {
                const eclass: i32 = if (self.sim.mask[i].class_id and self.sim.class_id[i].hash != 0)
                    self.sim.class_id[i].hash
                else
                    packages.stock_entity.class_zombie_default;
                const sleeper = self.sim.mask[i].sleeper and !self.sim.sleeper[i].awake;
                if (packages.stock_entity.buildEntitySpawnStock(&self.body_buf, .{
                    .entity_id = self.sim.network_id[i].id,
                    .entity_class = eclass,
                    .x = self.sim.transform[i].x,
                    .y = self.sim.transform[i].y,
                    .z = self.sim.transform[i].z,
                    .yaw = self.sim.transform[i].yaw,
                    .is_sleeper = sleeper,
                })) |spb| {
                    // EntitySpawn is join-critical for first sight; use sendGame.
                    for (&self.clients, 0..) |*cl, ci| {
                        if (!cl.joined or !cl.entered) continue;
                        const peer = cl.peer orelse continue;
                        if (cl.known_entities.isSet(i)) continue;
                        if (!interest.cellsInRange(obs_cx[ci], obs_cz[ci], ecell.cx, ecell.cz, cl.view_radius)) continue;
                        try self.sendGame(peer, "NetPackageEntitySpawn", spb);
                        cl.known_entities.set(i);
                    }
                    self.harness.counters.inc(.packages_encoded);
                } else |_| {
                    self.harness.counters.inc(.encode_errors);
                }
            }

            // Mirror of spawn-on-approach. Stock NetEntityDistributionEntry::
            // updatePlayerEntity drops a player that has left the tracking box
            // from trackedPlayers and sends that one player
            // NetPackageEntityRemove(entityId, Unloaded) (asm.il:801228-801276;
            // EnumRemoveEntityReason.Unloaded = 1 at asm.il:1227761). Without it
            // the mob keeps a client-side ghost that never gets another
            // PosAndRot and stands frozen in the world forever.
            if (is_mob) {
                for (&self.clients, 0..) |*cl, ci| {
                    if (!cl.known_entities.isSet(i)) continue;
                    if (!cl.joined or !cl.entered or !obs_ok[ci]) continue;
                    const peer = cl.peer orelse continue;
                    if (interest.cellsInRange(obs_cx[ci], obs_cz[ci], ecell.cx, ecell.cz, cl.view_radius)) continue;
                    const rb = packages.buildRemoveBodyReason(
                        &self.body_buf,
                        self.sim.network_id[i].id,
                        .unloaded,
                    ) catch {
                        self.harness.counters.inc(.encode_errors);
                        continue;
                    };
                    // Reliable: a dropped removal is a permanent ghost, and the
                    // bit only clears once the peer has actually been told.
                    try self.sendGame(peer, "NetPackageEntityRemove", rb);
                    cl.known_entities.unset(i);
                    self.harness.counters.inc(.packages_encoded);
                }
            }

            const d = if (self.sim.mask[i].dirty) self.sim.dirty[i] else @as(ecs.components.Dirty, .{});
            if (!interest.needsPosSend(d, self.tick_n)) continue;

            // Owner skip is per-peer; still encode once if any other peer wants it.
            var any_observer = false;
            for (&self.clients, 0..) |*cl, ci| {
                if (!cl.joined or !cl.entered or cl.peer == null) continue;
                if (self.sim.mask[i].player and self.sim.player[i].peer_slot == @as(i32, @intCast(cl.slot))) continue;
                if (!interest.cellsInRange(obs_cx[ci], obs_cz[ci], ecell.cx, ecell.cz, cl.view_radius)) continue;
                any_observer = true;
                break;
            }
            if (!any_observer) continue;

            const nid = self.sim.network_id[i].id;
            const body = packages.buildPosAndRotBody(
                self.body_buf[0..speeds_body_off],
                nid,
                self.sim.transform[i].x,
                self.sim.transform[i].y,
                self.sim.transform[i].z,
                0,
                self.sim.transform[i].yaw,
                0,
                true,
            ) catch continue;
            const pos_framed = packages.framed(&pos_frame_buf, "NetPackageEntityPosAndRot", body) catch continue;
            self.harness.counters.inc(.packages_encoded);

            var speeds_framed: ?[]const u8 = null;
            var flags_framed: ?[]const u8 = null;
            if (self.sim.mask[i].kind and self.sim.kind[i] == .zombie) {
                var fwd: f32 = 0.2;
                var state: u8 = 1; // walking-ish
                var flags: u16 = packages.cF_spawned;
                if (self.sim.mask[i].zombie_ai) {
                    const st = self.sim.zombie_ai[i].state;
                    if (st == .chase or st == .attack) {
                        fwd = 1.0;
                        state = 2;
                        flags |= packages.cF_is_alert | packages.cF_approaching_player;
                    } else if (st == .sleep) {
                        fwd = 0;
                        state = 0;
                    }
                }
                if (packages.buildEntitySpeedsBody(self.body_buf[speeds_body_off..flags_body_off], nid, state, fwd, 0)) |sb| {
                    if (packages.framed(&speeds_frame_buf, "NetPackageEntitySpeeds", sb)) |sf| {
                        speeds_framed = sf;
                        self.harness.counters.inc(.packages_encoded);
                    } else |_| {}
                } else |_| {}
                if (packages.buildAliveFlagsBody(self.body_buf[flags_body_off .. flags_body_off + 16], nid, flags)) |fb| {
                    if (packages.framed(&flags_frame_buf, "NetPackageEntityAliveFlags", fb)) |ff| {
                        flags_framed = ff;
                        self.harness.counters.inc(.packages_encoded);
                    } else |_| {}
                } else |_| {}
            }

            for (&self.clients, 0..) |*cl, ci| {
                if (!cl.joined or !cl.entered) continue;
                const peer = cl.peer orelse continue;
                if (self.sim.mask[i].player and self.sim.player[i].peer_slot == @as(i32, @intCast(cl.slot))) continue;
                if (!interest.cellsInRange(obs_cx[ci], obs_cz[ci], ecell.cx, ecell.cz, cl.view_radius)) continue;
                self.sendFramedDroppable(peer, pos_framed);
                if (speeds_framed) |sf| self.sendFramedDroppable(peer, sf);
                if (flags_framed) |ff| self.sendFramedDroppable(peer, ff);
            }
        }

        // Clear motion dirty after full fan-out (even if no observers this tick).
        var j: ecs.Slot = 0;
        while (j < ecs.max_entities) : (j += 1) {
            if (self.sim.alive[j] and self.sim.mask[j].dirty) {
                interest.clearAfterReplicate(&self.sim.dirty[j]);
            }
        }
        self.clearDeadKnownEntities();
    }

    fn clearDeadKnownEntities(self: *Game) void {
        // Most ticks free no slots; skip the 512-wide alive bitset rebuild.
        if (!self.sim.any_freed_this_tick) return;
        // One alive-bitset build + word-wise AND per client, instead of a
        // per-slot × per-client unset sweep (512×64 every tick).
        var alive_bits = std.StaticBitSet(ecs.max_entities).initEmpty();
        var j: ecs.Slot = 0;
        while (j < ecs.max_entities) : (j += 1) {
            if (self.sim.alive[j]) alive_bits.set(j);
        }
        for (&self.clients) |*kc| kc.known_entities.setIntersection(alive_bits);
        self.sim.any_freed_this_tick = false;
    }

    pub fn step(self: *Game) !void {
        const sc = apm.profiler.scope(&self.harness.prof, .tick_total);
        var completed = false;
        defer {
            // End profiling before advancing logical time: a deterministic
            // step has no host-runtime latency, but it still consumes one
            // stock tick for deadlines, retries, and stale-state checks.
            sc.end();
            // One server tick = one Tracy frame (no-op unless -Dtracy=true).
            apm.tracy.frameMark();
            if (completed and clock.isVirtual()) util_sim.advanceTick();
        }
        self.tick_n += 1;
        self.harness.counters.inc(.ticks);
        self.plugins.setTick(self.tick_n);

        {
            const sn = apm.profiler.scope(&self.harness.prof, .net_poll);
            defer sn.end();
            var polls: u32 = 0;
            while (polls < 64) : (polls += 1) {
                // Socket-level poll failures are process-fatal (bound UDP is dead).
                // Per-peer connect/payload failures must not take down the dedi.
                const ev = self.net.poll(&self.recv_buf) catch |err| {
                    self.harness.counters.inc(.net_poll_errors);
                    std.debug.print("zdtd: net poll error: {s}\n", .{@errorName(err)});
                    return err;
                };
                switch (ev) {
                    .none => break,
                    .connected => |p| self.onConnected(p) catch |e| {
                        self.harness.counters.inc(.join_fail);
                        std.debug.print(
                            "zdtd: onConnected failed local_id={d}: {s}\n",
                            .{ p.local_id, @errorName(e) },
                        );
                    },
                    .data => |d| self.onData(d.peer, d.payload) catch |err| {
                        self.harness.counters.inc(.net_payload_errors);
                        std.debug.print(
                            "zdtd: payload failed local_id={d} error={s}\n",
                            .{ d.peer.local_id, @errorName(err) },
                        );
                    },
                }
            }
            // Drop silent peers (client quit) so we stop flooding a stuck window.
            self.reapStalePeers();
            // Guard-policy kicks land 0.5 s after PlayerDenied (stock parity).
            self.reapPolicyKicks();
            // Drain several TCP info queries per tick (browser / connect dialog).
            var info_n: u32 = 0;
            while (info_n < 8) : (info_n += 1) self.info_tcp.poll();
            self.pollAdmin();
            // A few webui polls per tick (accept + serve); work stays off sim sections.
            var web_n: u32 = 0;
            while (web_n < 4) : (web_n += 1) self.pollWebui();
        }

        const dt: f32 = 1.0 / @as(f32, @floatFromInt(protocol.ticks_per_second));
        {
            const se = apm.profiler.scope(&self.harness.prof, .sim_entities);
            defer se.end();
            // Rebuild before tickAll: AI workers read it lock-free, and nothing
            // mutates blocks between here and the end of the AI phase.
            if (self.terrain_snapshot_on) {
                const ts = apm.profiler.scope(&self.harness.prof, .terrain_snap);
                var px: [max_clients]f32 = undefined;
                var py: [max_clients]f32 = undefined;
                var pz: [max_clients]f32 = undefined;
                const pn = self.gatherPlayerPositions(&px, &py, &pz);
                const covered = self.terrain_snap.rebuild(&self.world, px[0..pn], pz[0..pn]);
                ts.end();
                self.harness.counters.add(.terrain_snap_chunks, covered);
            }
            // The director's spawn branches read the party stage; stock
            // recomputes it when the event fires (CalcGameStageAround), and the
            // director's own cooldowns are what gate the events here.
            self.sim.director.party_stage = self.partyStageAround(0, 0, -1);
            const r = systems.tickAll(&self.sim, dt);
            self.harness.counters.add(.path_replans, r.path_replans);
            self.harness.counters.add(.path_replans_denied, r.path_replans_denied);
            if (self.terrain_snapshot_on) {
                const now = self.terrain_snap.misses.load(.monotonic);
                self.harness.counters.add(.terrain_snap_misses, now -| self.snap_misses_seen);
                self.snap_misses_seen = now;
            }
            // Prefab sleeper volumes (every ~0.5s).
            if (self.tick_n % 10 == 0) self.tickSleeperVolumes();
            // Air drops + zombie block damage at 2Hz.
            if (self.tick_n % 10 == 0) {
                self.tickAirDrop();
                self.tickZombieBlockDamage();
            }
            // Workstation burn/craft at 2Hz; dirty stations re-broadcast state.
            if (self.tick_n % 10 == 0) {
                self.tickWorkstations(0.5) catch |err| {
                    self.harness.counters.inc(.net_send_errors);
                    std.debug.print("zdtd: broadcastDirtyWorkstations failed: {s}\n", .{@errorName(err)});
                };
            }
            // Power fuel/SoC/timers every tick (props from blocks.xml via registry).
            const daylight = !self.sim.director.clock.isNight();
            _ = self.sim.power.tick(dt, daylight);
            self.broadcastPowerVisuals();
            self.reapStaleLocks();
            if (r.turret_kills > 0) {
                for (&self.clients) |*cl| {
                    if (!cl.joined) continue;
                    var n: u32 = 0;
                    while (n < r.turret_kills) : (n += 1) systems.questOnZombieKilled(&self.sim, cl.slot);
                }
            }
            // Turret kills: remove corpses on stock clients, then scrap ECD+Bag.
            var ki: u8 = 0;
            while (ki < r.killed_n) : (ki += 1) {
                const kid = r.killed_ids[ki];
                if (kid <= 0) continue;
                const rm = try packages.buildRemoveBody(&self.body_buf, kid);
                try self.broadcast("NetPackageEntityRemove", rm);
            }
            var di: u8 = 0;
            while (di < r.despawned_n) : (di += 1) {
                const did = r.despawned_ids[di];
                if (did <= 0) continue;
                const rm = try packages.buildRemoveBodyReason(&self.body_buf, did, .despawned);
                try self.broadcast("NetPackageEntityRemove", rm);
            }
            // Expired buffs: tell every client so HUD icons and remote-entity
            // effects end at the same tick the server ended them.
            if (r.buff_expired_n > 0) try self.broadcastBuffExpiries(&r);
            var li: u8 = 0;
            while (li < r.loot_n) : (li += 1) {
                const lid = r.loot_bag_ids[li];
                if (lid > 0) {
                    // Refill from loot.xml (turret/AI kills otherwise keep the seed scrap).
                    self.fillLootBagFromTable(lid, "", @bitCast(lid));
                    try self.broadcastLootSpawn(lid);
                }
            }
            self.harness.counters.add(.entities_ticked, self.sim.countKind(.zombie));

            if (self.tick_n % 20 == 0) {
                const tb = try packages.buildWorldTimeBody(self.body_buf[0..16], r.world_time);
                try self.broadcast("NetPackageWorldTime", tb);
                // Storm scheduling is driven by world time, so it advances even
                // while shedding; only the broadcast below is deferrable.
                self.world.weather.tick(
                    &self.world.biome_layers_table,
                    @intCast(@min(r.world_time, std.math.maxInt(i64))),
                    self.sim.director.bloodmoon_active,
                );
                // Weather is cosmetic and safe to defer under load; WorldTime is not
                // (clients drive day/night and blood-moon state off it).
                if (!self.loadShedding()) try self.broadcastWeather();
                // Blood-moon horde music trigger (single bool; drives client
                // audio + tension on day-7 nights).
                const bm = self.sim.director.bloodmoon_active;
                if (bm != self.bloodmoon_sent) {
                    self.bloodmoon_sent = bm;
                    const bm_body = try packages.buildBloodmoonMusicBody(self.body_buf[0..1], bm);
                    try self.broadcast("NetPackageBloodmoonMusic", bm_body);
                }
            }
            if (self.tick_n % 5 == 0 and !self.loadShedding()) try self.broadcastVehiclePositions();
            if (self.tick_n % 10 == 0) try self.broadcastTurretSync();
            // Null on_tick hooks are a branch only (sample_hello is enable-only).
            self.plugins.onTick();
        }

        try self.replicate();
        // Periodic world flush so dig/build survives crash without explicit admin save.
        if (self.tick_n % 100 == 0) {
            const ss = apm.profiler.scope(&self.harness.prof, .save_io);
            defer ss.end();
            {
                // saveAll = encode (+ inline write when sync). Split out so the
                // async-flush decision has an encode-vs-write histogram.
                const es = apm.profiler.scope(&self.harness.prof, .save_encode);
                defer es.end();
                self.world.saveAll() catch |e| logPersistErr(self, "save world", e);
            }
            self.containers.save(self.world.world_dir) catch |e| logPersistErr(self, "save containers", e);
            self.saveBlockMeta() catch |e| logPersistErr(self, "save block meta", e);
            if (self.players_dirty) {
                self.players_dirty = false;
                self.savePlayers() catch |e| logPersistErr(self, "save players", e);
            }
        }
        self.sampleFlushCounters();

        // One parseable line per minute gives unbounded production runs a
        // bounded-cost health signal without per-packet label cardinality.
        if (self.tick_n % apm_report_period_ticks == 0) {
            var snap = self.harness.snapshot();
            // Instantaneous gauges ride the same JSON line as counters so log
            // scrapers get load + error rates in one event (not a free-text tail).
            var entered_n: u32 = 0;
            var peers_alive: u32 = 0;
            for (&self.clients) |cl| {
                if (cl.entered) entered_n += 1;
            }
            for (&self.net.peers) |p| {
                if (p.alive) peers_alive += 1;
            }
            snap.ops = .{
                .tick = self.tick_n,
                .joined = self.countJoined(),
                .entered = entered_n,
                .peers_alive = peers_alive,
                .zombies = @intCast(@min(self.sim.countKind(.zombie), std.math.maxInt(u32))),
                .chunks = @intCast(@min(self.world.chunks.count(), std.math.maxInt(u32))),
            };
            var report_buf: [apm.report.max_json_bytes]u8 = undefined;
            var report_writer: std.Io.Writer = .fixed(&report_buf);
            var report_ok = true;
            apm.report.writeJsonLine(&snap, &report_writer) catch |err| {
                report_ok = false;
                std.debug.print("zdtd: apm report failed: {s}\n", .{@errorName(err)});
            };
            if (report_ok) std.debug.print("{s}", .{report_writer.buffered()});
        }
        completed = true;
    }

    fn anyEnteredClient(self: *const Game) bool {
        for (self.clients) |cl| {
            if (cl.entered) return true;
        }
        return false;
    }

    /// Build NetPackageWeather from the live weather state machine (omit if none).
    pub fn buildWeatherBodyFromBiomes(self: *Game) ?[]const u8 {
        const bl = &self.world.biome_layers_table;
        const wm = &self.world.weather;
        // Stock client InitPackages sizes from biomeWeather.Count (Navezgane / stock
        // biomes with weather groups → 5). Wire has no count prefix, so body length
        // must be exactly Count * 23 (3 u8 + 5 f32).
        const stock_count: usize = 5;
        var wb: [assets_biome_layers.max_weather_biomes]packages.WeatherBiome = undefined;
        var n: usize = 0;
        while (n < wm.n) : (n += 1) {
            const st = &wm.states[n];
            wb[n] = .{
                .biome_id = st.biome_id,
                .group_index = st.group_index,
                .group_count = world_weather.Manager.groupsFor(bl, st).n,
                .remaining_seconds = st.remaining_seconds,
                .params = st.params,
            };
        }
        // Pad or trim to stock_count so content_len matches client expected size.
        if (n == 0) {
            // No biomes.xml: mild pine-ish defaults on the raw 0..100 XML scale,
            // group 0 so an unmodded client still resolves a real group.
            var i: usize = 0;
            while (i < stock_count) : (i += 1) {
                wb[i] = .{
                    .biome_id = @intCast(i + 1),
                    .group_index = 0,
                    .group_count = 1,
                    .remaining_seconds = 0,
                    .params = .{ 70, 0, 20, 10, 5 },
                };
            }
            n = stock_count;
        } else if (n < stock_count) {
            var i = n;
            while (i < stock_count) : (i += 1) {
                wb[i] = wb[n - 1];
                wb[i].biome_id = @intCast(i + 1);
            }
            n = stock_count;
        } else if (n > stock_count) {
            n = stock_count;
        }
        return packages.buildWeatherBody(&self.body_buf, wb[0..n]) catch null;
    }

    fn sendWeather(self: *Game, peer: *ln_peer.Peer) !void {
        const body = self.buildWeatherBodyFromBiomes() orelse return;
        // Stock client sizes read from biomeWeather.Count (usually 5 → 115 body / 117 content).
        if (body.len != 115 and body.len != 0) {
            std.debug.print("zdtd: weather body len={d} (stock often 115 for 5 biomes)\n", .{body.len});
        }
        try self.sendGame(peer, "NetPackageWeather", body);
    }

    /// Stock: same throttle as WorldTime → NetPackageWeather from biomes.xml defaults.
    fn broadcastWeather(self: *Game) !void {
        if (!self.anyEnteredClient()) return;
        const body = self.buildWeatherBodyFromBiomes() orelse return;
        try self.broadcast("NetPackageWeather", body);
    }

    fn broadcastVehiclePositions(self: *Game) !void {
        // Do not flood pre-enter stock clients (World still null / reader dies on short bodies).
        if (!self.anyEnteredClient()) return;
        // Stock NetPackageVehiclePositions: count:i32, then (entityId:i32 + Vector3:f32*3)*count
        var o: usize = 4;
        var n: i32 = 0;
        for (ecs.groupSlice(&self.sim, .vehicle)) |i| {
            if (!self.sim.mask[i].vehicle) continue;
            if (o + 16 > 1024) break;
            std.mem.writeInt(i32, self.body_buf[o..][0..4], self.sim.network_id[i].id, .little);
            o += 4;
            inline for (.{ self.sim.transform[i].x, self.sim.transform[i].y, self.sim.transform[i].z }) |f| {
                std.mem.writeInt(u32, self.body_buf[o..][0..4], @as(u32, @bitCast(f)), .little);
                o += 4;
            }
            n += 1;
        }
        if (n == 0) return;
        std.mem.writeInt(i32, self.body_buf[0..4], n, .little);
        try self.broadcast("NetPackageVehiclePositions", self.body_buf[0..o]);
    }

    fn broadcastTurretSync(self: *Game) !void {
        // Disabled: stock NetPackageTurretSync is per-entity (id, target, isOn, ItemValue).
        // Our multi-entity blob breaks ItemValue.Read and kills the client reader thread.
        _ = self;
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
            } else {
                // Fell behind the 50 ms budget: count for apm; rate-limit log.
                self.harness.counters.inc(.tick_overruns);
                // Availability valve: hold weak evidence + deferrable broadcasts
                // for 2 s. Chunk streaming, motion replicate, WorldTime and every
                // Hard gate keep running.
                if (self.guard.load_shed) self.shed_until_tick = self.tick_n + guard_policy.shed_hold_ticks;
                const overruns = self.harness.counters.get(.tick_overruns);
                if (overruns == 1 or overruns % 100 == 0) {
                    const late_us = (now -% next_t) / 1000;
                    std.debug.print(
                        "zdtd: tick overrun n={d} late_us={d} (budget={d}us)\n",
                        .{ overruns, late_us, tick_ns / 1000 },
                    );
                }
            }
            next_t += tick_ns;
            if (next_t < clock.monoNs()) next_t = clock.monoNs() + tick_ns;
        }
        try self.world.saveAll();
    }

    pub fn applyDamage(self: *Game, entity_id: i32, amount: f32) bool {
        return self.sim.damage(entity_id, amount).killed;
    }

    pub fn setBlock(self: *Game, x: i32, y: i32, z: i32, id: u16) !void {
        try self.world.setBlockWorld(x, y, z, id);
        if (self.isStorageBlockId(id)) {
            _ = self.containers.getOrCreate(.{ .x = x, .y = y, .z = z }, 8, @intCast(id));
        } else {
            self.containers.remove(.{ .x = x, .y = y, .z = z });
        }
    }

    /// Loadgen / scenario join with a null platform identity, which is what a
    /// client running without a platform session sends.
    pub fn attachJoinedClient(self: *Game, capture: ?*ln_peer.Capture) !*Client {
        return self.attachJoinedClientAs(capture, null);
    }

    /// Same join, but the synthetic login carries `puid` as both the native and
    /// the crossplatform identity, so the real PlayerLogin decode runs.
    pub fn attachJoinedClientAs(self: *Game, capture: ?*ln_peer.Capture, puid: ?platform_user.Id) !*Client {
        var peer_ptr: ?*ln_peer.Peer = null;
        for (&self.net.peers) |*p| {
            if (p.alive) continue;
            p.* = .{};
            p.alive = true;
            p.local_id = self.net.next_local_id;
            self.net.next_local_id += 1;
            p.authenticated = false;
            p.capture = capture;
            const fake_port: u16 = @intCast(10000 + @as(u16, @intCast(p.local_id)));
            const addr: @import("../litenet/udp_socket.zig").IpAddress = .{
                .ip4 = .{
                    .bytes = .{ 127, 0, 0, 1 },
                    .port = fake_port,
                },
            };
            p.setAddr(&addr);
            peer_ptr = p;
            break;
        }
        const peer = peer_ptr orelse return error.TooManyPeers;
        try self.onConnected(peer);
        const c = self.clientFor(peer) orelse return error.NoClient;
        var ch: [17]u8 = undefined;
        wire_frame.buildChallenge(&ch, c.challenge);
        try self.onData(peer, &ch);
        var login_body: [256]u8 = undefined;
        var w: wire_binary.Writer = .{ .buf = &login_body };
        try w.writeString("Bot");
        try platform_user.write(&w, puid);
        try w.writeString("");
        try platform_user.write(&w, puid);
        try w.writeString("");
        try w.writeString(version.stock_wire_announce);
        try w.writeString(version.stock_wire_announce);
        try w.writeU64(0);
        var frame_buf: [512]u8 = undefined;
        const framed = try packages.framed(&frame_buf, "NetPackagePlayerLogin", w.written());
        try self.onData(peer, framed);
        // Match stock/loadgen: enter → spawn so WorldInfo then PlayerId/chunks are sent.
        if (packages.idOf("NetPackageRequestToEnterGame")) |enter_id| {
            var enter_frame: [64]u8 = undefined;
            const ef = try wire_frame.framePackage(&enter_frame, 0, enter_id, &[_]u8{});
            try self.onData(peer, ef);
        }
        if (packages.idOf("NetPackageRequestToSpawnPlayer")) |spawn_id| {
            var spawn_body: [4]u8 = undefined;
            std.mem.writeInt(i16, spawn_body[0..2], 4, .little);
            // nearEntityId i32 after profile is optional; empty body uses defaults in handler
            var spawn_frame: [64]u8 = undefined;
            const sf = try wire_frame.framePackage(&spawn_frame, 0, spawn_id, spawn_body[0..2]);
            try self.onData(peer, sf);
        }
        if (!c.joined or c.entity_id <= 0) return error.JoinFailed;
        return c;
    }

    pub fn injectFramed(self: *Game, c: *Client, framed: []const u8) !void {
        const peer = c.peer orelse return error.NoPeer;
        try self.onData(peer, framed);
    }

    pub fn replicateNow(self: *Game) !void {
        try self.replicate();
    }

    /// Stock `AllyStore::ProcessAllyRequest` (asm.il 885024): take the pair's
    /// current status, compute the transition, apply it, and tell the clients
    /// with `NetPackageAllyResponse` (asm.il 886390). Stock sends that to every
    /// client, so both sides of the pair see the change wherever they are.
    fn handleAllyRequest(self: *Game, c: *Client, body: []const u8) !void {
        const req = packages.parseAllyRequest(body) catch {
            self.harness.counters.inc(.c2s_malformed);
            return;
        };
        // Stock returns before touching the store when either identity is null,
        // and a client with no identity of its own never sends one at all
        // (AllyStore::AllyUpdateRequest, asm.il 884977).
        const source = req.source.get() orelse return;
        const target = req.target.get() orelse return;
        const own = c.puid_primary.get() orelse return;
        if (!own.eql(source)) {
            // Speaking for another account would let anyone accept, decline or
            // cancel invites they were never part of.
            self.harness.counters.inc(.ownership_rejects);
            return;
        }
        const t = self.allies.processRequest(source, target, req.add_ally) catch {
            // Relationship table full: refuse the new pair rather than evict
            // someone else's. Existing pairs keep updating.
            self.harness.counters.inc(.c2s_throttle);
            return;
        };
        if (t.isNoop()) return;
        const resp = try packages.buildAllyResponseBody(
            self.body_buf[9216..9728],
            source,
            target,
            @intFromEnum(t.new_status),
            @intFromEnum(t.event_source),
            @intFromEnum(t.event_target),
        );
        try self.broadcast("NetPackageAllyResponse", resp);
    }
};

test "peerIpKey covers ipv4 mapped ipv6 and pure ipv6" {
    var p: ln_peer.Peer = .{};
    p.addr = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 1 } };
    try std.testing.expectEqual(@as(u32, 0x7f000001), Game.peerIpKey(&p));

    p.addr = .{ .ip6 = .{
        .bytes = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 192, 168, 1, 2 },
        .port = 1,
    } };
    try std.testing.expectEqual(@as(u32, 0xc0a80102), Game.peerIpKey(&p));

    p.addr = .{ .ip6 = .{
        .bytes = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
        .port = 1,
    } };
    const k = Game.peerIpKey(&p);
    try std.testing.expect(k != 0);
    try std.testing.expect(k != 0x7f000001);
}

test "zpv2DropName removes matching player record only" {
    // Two minimal records: Alice (inv=0,j=0), Bob (inv=0,j=0).
    // each: name_len|name|x,y,z,coins (16 bytes)|inv_n|jn
    var buf: [128]u8 = undefined;
    var o: usize = 0;
    @memcpy(buf[0..4], "ZPV2");
    o = 8;
    // Alice
    buf[o] = 5;
    o += 1;
    @memcpy(buf[o..][0..5], "Alice");
    o += 5;
    @memset(buf[o..][0..16], 0);
    o += 16;
    buf[o] = 0; // inv_n
    o += 1;
    buf[o] = 0; // jn
    o += 1;
    // Bob
    buf[o] = 3;
    o += 1;
    @memcpy(buf[o..][0..3], "Bob");
    o += 3;
    @memset(buf[o..][0..16], 0);
    o += 16;
    buf[o] = 0;
    o += 1;
    buf[o] = 0;
    o += 1;
    std.mem.writeInt(u32, buf[4..8], 2, .little);

    const dropped = try zpv2DropName(std.testing.allocator, buf[0..o], "Alice");
    defer if (dropped.blob) |b| std.testing.allocator.free(b);
    try std.testing.expectEqual(@as(u32, 1), dropped.removed);
    try std.testing.expect(dropped.blob != null);
    const out = dropped.blob.?;
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, out[4..8], .little));
    try std.testing.expect(std.mem.indexOf(u8, out, "Alice") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Bob") != null);

    const none = try zpv2DropName(std.testing.allocator, buf[0..o], "Carol");
    try std.testing.expectEqual(@as(u32, 0), none.removed);
    try std.testing.expect(none.blob == null);
}

test "players zpv2 preserves inventory slot gaps across restart" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    {
        const g = try Game.create(std.testing.allocator, world_dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        var capture: ln_peer.Capture = .{};
        const cl = try g.attachJoinedClient(&capture);
        const ps = g.sim.playerByPeer(cl.slot).?;
        g.sim.inventory[ps] = .{};
        g.sim.inventory[ps].slots[7] = .{ .item_id = 2, .count = 3, .quality = 4, .meta = 5 };
        try g.savePlayers();
    }

    {
        const g = try Game.create(std.testing.allocator, world_dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        var capture: ln_peer.Capture = .{};
        const cl = try g.attachJoinedClient(&capture);
        const ps = g.sim.playerByPeer(cl.slot).?;
        try std.testing.expectEqual(@as(u16, 0), g.sim.inventory[ps].slots[0].count);
        try std.testing.expectEqual(@as(u16, 2), g.sim.inventory[ps].slots[7].item_id);
        try std.testing.expectEqual(@as(u16, 3), g.sim.inventory[ps].slots[7].count);
        try std.testing.expectEqual(@as(u8, 4), g.sim.inventory[ps].slots[7].quality);
        try std.testing.expectEqual(@as(u16, 5), g.sim.inventory[ps].slots[7].meta);
    }
}

test "offline init failure restores deterministic sim globals" {
    util_sim.disable();
    try std.testing.expectError(error.SecretRequired, Game.createWithOptions(
        std.testing.allocator,
        ".zdtd_cfg_cache/dst_init_failure",
        0,
        .{ .webui_port = 1, .enable_sample_plugin = false },
    ));
    try std.testing.expect(!util_sim.isEnabled());
}

test "offline successful step advances exactly one virtual tick" {
    io_fs.mkdirPathSimple(".zdtd_cfg_cache");
    const g = try Game.create(std.testing.allocator, ".zdtd_cfg_cache/dst_step_clock", 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }

    const before = clock.monoNs();
    try g.step();
    try std.testing.expectEqual(before + util_sim.tick_ns, clock.monoNs());
}

test "offline init records default DST run seed" {
    io_fs.mkdirPathSimple(".zdtd_cfg_cache");
    const g = try Game.create(std.testing.allocator, ".zdtd_cfg_cache/dst_run_seed", 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    try std.testing.expectEqual(util_sim.default_seed, util_sim.getSeed());
}

test "offline steps replay same world_time for same seed" {
    io_fs.mkdirPathSimple(".zdtd_cfg_cache");
    var t_a: u64 = 0;
    var t_b: u64 = 0;
    {
        const g = try Game.createWithOptions(std.testing.allocator, ".zdtd_cfg_cache/dst_replay_a", 0, .{
            .worldgen_seed = 99,
            .enable_sample_plugin = false,
        });
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        try std.testing.expectEqual(@as(u64, 99), util_sim.getSeed());
        var i: u32 = 0;
        while (i < 20) : (i += 1) try g.step();
        t_a = g.sim.director.clock.worldTimeBits();
    }
    {
        const g = try Game.createWithOptions(std.testing.allocator, ".zdtd_cfg_cache/dst_replay_b", 0, .{
            .worldgen_seed = 99,
            .enable_sample_plugin = false,
        });
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        var i: u32 = 0;
        while (i < 20) : (i += 1) try g.step();
        t_b = g.sim.director.clock.worldTimeBits();
    }
    try std.testing.expectEqual(t_a, t_b);
}

test "sleeper scan job batch matches the serial pass" {
    var vols: [64]sleepers_mod.Volume = undefined;
    for (&vols, 0..) |*v, i| {
        const x: i32 = @intCast(i * 10);
        v.* = .{ .x0 = x, .y0 = 0, .z0 = 0, .x1 = x + 4, .y1 = 8, .z1 = 4 };
    }
    vols[3].triggered = true;
    var st: sleepers_mod.Store = .{ .volumes = vols[0..] };
    const px = [_]f32{ 1, 31, 101 };
    const py = [_]f32{ 1, 1, 1 };
    const pz = [_]f32{ 1, 1, 1 };
    var serial: [vols.len]u8 = .{0} ** vols.len;
    var batched: [vols.len]u8 = .{0} ** vols.len;

    const base = Game.SleeperScanCtx{ .sl = &st, .px = &px, .py = &py, .pz = &pz, .hit = serial[0..] };
    Game.SleeperScanCtx.work(base, 0, vols.len);
    var par = base;
    par.hit = batched[0..];
    // 64 >= parallel.min_parallel_items, so this really fans out.
    jobs.forSlotRange(vols.len, par, Game.SleeperScanCtx.work);

    try std.testing.expectEqualSlices(u8, serial[0..], batched[0..]);
    try std.testing.expectEqual(@as(u8, 1), serial[0]);
    // Already triggered: never re-tested, never re-spawned.
    try std.testing.expectEqual(@as(u8, 0), serial[3]);
    try std.testing.expectEqual(@as(u8, 1), serial[10]);
}

test "path step hook sees walls and terrain, and the snapshot agrees" {
    const g = try Game.createWithOptions(std.testing.allocator, ".zdtd_cfg_cache/terrain_snap", 0, .{
        .enable_sample_plugin = false,
    });
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    const ch = try g.world.getOrCreate(.{ .x = 0, .z = 0 });
    const surface: i32 = ch.heightAt(2, 3);
    const from_y: i32 = surface + 1;
    // Two-course wall built through the public API: too tall to step onto and
    // no headroom on the first course.
    try g.world.setBlockWorld(2, surface + 1, 3, world_store.block_stone);
    try g.world.setBlockWorld(2, surface + 2, 3, world_store.block_stone);

    // Baseline: snapshot off, the locked hook answers.
    g.terrain_snapshot_on = false;
    const open_y: i32 = @as(i32, ch.heightAt(5, 5)) + 1;
    try std.testing.expectEqual(@as(?i32, null), Game.pathStepAt(g, 1, 3, from_y, 2, 3));
    try std.testing.expectEqual(@as(?i32, open_y), Game.pathStepAt(g, 4, 5, open_y, 5, 5));

    const px = [_]f32{0};
    const pz = [_]f32{0};
    try std.testing.expectEqual(@as(usize, 1), g.terrain_snap.rebuild(&g.world, &px, &pz));
    g.terrain_snapshot_on = true;
    // The wall column is out of the step band: the snapshot misses and the
    // locked hook still reports it blocked.
    try std.testing.expectEqual(@as(?i32, null), Game.pathStepAt(g, 1, 3, from_y, 2, 3));
    try std.testing.expect(g.terrain_snap.misses.load(.monotonic) > 0);
    // Open terrain is answered lock-free.
    const before_misses = g.terrain_snap.misses.load(.monotonic);
    try std.testing.expectEqual(@as(?i32, open_y), Game.pathStepAt(g, 4, 5, open_y, 5, 5));
    try std.testing.expectEqual(before_misses, g.terrain_snap.misses.load(.monotonic));

    // Outside the window: falls through to the locked hook, which still
    // generates the chunk on demand exactly as before.
    const before = g.world.chunks.count();
    _ = Game.pathStepAt(g, 4000, 4000, from_y, 4001, 4000);
    try std.testing.expectEqual(before + 1, g.world.chunks.count());
}

test "deco burst is biome driven and mirrors into the block store" {
    const g = try Game.createWithOptions(std.testing.allocator, ".zdtd_cfg_cache/deco_biome", 0, .{
        .enable_sample_plugin = false,
    });
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    // Without a biome map there is nothing to drive density: fail closed.
    try std.testing.expect(g.world.biomes == null);
    try std.testing.expectEqual(@as(usize, 0), Game.decoSpeciesAt(g, 0, 0).n);

    // One-biome map covering the join window, and one distant-deco species that
    // always passes the roll so the placement path is actually exercised.
    const biome_id: u8 = 3;
    const side: i32 = 64;
    const cells = try std.testing.allocator.alloc(u8, @intCast(side * side));
    @memset(cells, biome_id);
    g.world.biomes = .{
        .width = side,
        .height = side,
        .r = cells,
        .allocator = std.testing.allocator,
        .half_w = @divTrunc(side, 2),
        .half_h = @divTrunc(side, 2),
        .scale = 16,
    };
    const tree_id: u16 = 24629; // treeOakSml01 in the bundled dump
    var set: assets_biome_layers.DecoSet = .{};
    set.blocks[0] = .{ .block_id = tree_id, .prob = 1.0 };
    set.n = 1;
    g.world.biome_layers_table.decos[biome_id] = set;
    try std.testing.expect(g.world.biome_layers_table.hasDecos());
    try std.testing.expectEqual(@as(usize, 1), Game.decoSpeciesAt(g, 0, 0).n);
    try std.testing.expectEqual(tree_id, Game.decoSpeciesAt(g, 0, 0).items[0].block_id);

    // The mirror needs the dump to resolve the id back to a MultiBlockDim.
    g.maxdamage.tryMergeBundledAssignIds(std.testing.allocator);
    if (g.maxdamage.idNameCount() == 0) return error.SkipZigTest;

    var cache: Game.DecoDimCache = .{};
    const h = try g.world.heightWorld(3, 5);
    const o: packages.stock_deco.DecoObj = .{
        .x = 3,
        .y = @intCast(h + 1),
        .z = 5,
        .real_y = @floatFromInt(h + 1),
        .block_raw = tree_id,
    };
    // The world dir survives between runs (deinit saves chunks), so clear the
    // target cell rather than assume a pristine column.
    try g.world.setBlockDecoWorld(3, @intCast(h + 1), 5, g.world.terrain_ids.air);
    try std.testing.expect(g.mirrorDeco(&cache, o));
    try std.testing.expectEqual(tree_id, try g.world.blockWorld(3, @intCast(h + 1), 5));
    // Terrain surface must not follow the tree up.
    try std.testing.expectEqual(h, try g.world.heightWorld(3, 5));
    // Cached: a second object of the same species must not rescan the dump, and
    // must still be skipped because the anchor is now a decoration.
    try std.testing.expectEqual(@as(usize, 1), cache.n);
    try std.testing.expect(!g.mirrorDeco(&cache, o));

    // An id with no name in the dump places nothing rather than a bare parent.
    const unknown: packages.stock_deco.DecoObj = .{ .x = 9, .y = 60, .z = 9, .real_y = 60, .block_raw = 0xfffe };
    try std.testing.expect(!g.mirrorDeco(&cache, unknown));
    try std.testing.expect(try g.world.blockWorld(9, 60, 9) != 0xfffe);
}

test "zombie chases over real terrain and stays on the surface" {
    const g = try Game.createWithOptions(std.testing.allocator, ".zdtd_cfg_cache/path_terrain", 0, .{
        .enable_sample_plugin = false,
    });
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    const sp = g.world.primarySpawn();
    const sx: f32 = @floatFromInt(sp.x);
    const sy: f32 = @floatFromInt(sp.y);
    const sz: f32 = @floatFromInt(sp.z);
    const zid = g.sim.spawnZombie(sx + 8, sy, sz, 40).?;
    const zs = g.sim.slotOfNetId(zid).?;
    _ = g.sim.spawnPlayer(sx, sy, sz, 0).?;
    const x0 = g.sim.transform[zs].x;
    var i: usize = 0;
    while (i < 40) : (i += 1) try g.step();
    // Closed on the player: the real step predicate must not read as a sealed
    // world (the old height+1 probe made every column open, this one must make
    // open ground passable).
    try std.testing.expect(g.sim.transform[zs].x < x0 - 1.0);
    // Feet sit on the column the body is standing over, not at spawn height.
    const wx: i32 = @intFromFloat(@floor(g.sim.transform[zs].x));
    const wz: i32 = @intFromFloat(@floor(g.sim.transform[zs].z));
    const h: i32 = try g.world.heightWorld(wx, wz);
    try std.testing.expectEqual(@as(f32, @floatFromInt(h + 1)), g.sim.transform[zs].y);
}

test "[perf] switches run on the live step path" {
    const g = try Game.createWithOptions(std.testing.allocator, ".zdtd_cfg_cache/perf_switches", 0, .{
        .enable_sample_plugin = false,
        .async_chunk_flush = true,
        .terrain_snapshot = true,
        .job_batches = true,
    });
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    try std.testing.expect(g.terrain_snapshot_on);
    try std.testing.expect(g.job_batches);
    try std.testing.expect(g.world.async_flush);
    // Offline Game runs force-serial, so the flush must stay inline there.
    try std.testing.expect(!g.world.asyncEnabled());

    try g.world.setBlockWorld(4, 70, 4, world_store.block_stone);
    var i: u32 = 0;
    while (i < 3) : (i += 1) try g.step();
    // Snapshot rebuild is on the live path, not dead code.
    try std.testing.expect(g.harness.prof.histOf(.terrain_snap).count >= 3);
}

test "power visuals rewrite block meta once per state change" {
    io_fs.mkdirPathSimple(".zdtd_cfg_cache");
    const g = try Game.createWithOptions(std.testing.allocator, ".zdtd_cfg_cache/power_visuals", 0, .{
        .enable_sample_plugin = false,
    });
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    try g.world.setBlockWorld(8, 70, 8, world_store.block_stone);
    const id = g.sim.power.addNodeAt(.consumer, 8, 70, 8, 10).?;
    const ni = g.sim.power.indexOfId(id).?;
    g.sim.power.nodes[ni].powered = true;

    g.broadcastPowerVisuals();
    const raw = g.blockRawAt(8, 70, 8);
    try std.testing.expectEqual(world_store.block_stone, @as(u16, @truncate(raw & 0xffff)));
    try std.testing.expectEqual(
        packages.block_meta_on | packages.block_meta_powered,
        packages.blockMeta(raw),
    );

    // Nothing flipped: the second pass must not touch the block or emit a packet.
    g.clearBlockRaw(8, 70, 8);
    g.broadcastPowerVisuals();
    try std.testing.expectEqual(@as(u32, 0), g.blockRawAt(8, 70, 8));

    // Losing power is an edge, so it writes meta 0 again.
    g.sim.power.nodes[ni].powered = false;
    g.broadcastPowerVisuals();
    try std.testing.expectEqual(@as(u8, 0), packages.blockMeta(g.blockRawAt(8, 70, 8)));
}

test "player game stage tracks level, days survived and deaths" {
    const g = try Game.create(std.testing.allocator, ".zdtd_cfg_cache/gamestage", 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    // Stock config defaults when gamestages.xml is absent (asm.il .cctor ~1093405).
    g.gamestages.config = .{ .difficulty_bonus = 1.2, .days_alive_change_when_killed = 2 };
    const c = &g.clients[0];
    c.joined = true;
    c.level = 10;
    g.sim.director.clock.day = 0;
    g.sim.director.clock.hours = 0;
    c.game_stage_born_world_time = g.sim.director.clock.worldTimeBits();
    // Day zero: level only, floored after the difficulty bonus (10 * 1.2 = 12).
    try std.testing.expectEqual(@as(i32, 12), g.gameStageOf(0));
    // Four days survived: (10 + 4) * 1.2 = 16.8 → 16, the header's example.
    g.sim.director.clock.day = 4;
    try std.testing.expectEqual(@as(i32, 16), g.gameStageOf(0));
    // Days alive caps at the player level: 25 days at level 10 is 10.
    g.sim.director.clock.day = 25;
    try std.testing.expectEqual(@as(i32, 24), g.gameStageOf(0));
    // A death costs daysAliveChangeWhenKilled days off the streak.
    const before = c.game_stage_born_world_time;
    c.game_stage_born_world_time = assets_gamestages.bornAtAfterDeath(
        g.gamestages.config,
        g.sim.director.clock.worldTimeBits(),
        before,
    );
    try std.testing.expectEqual(before + 2 * assets_gamestages.ticks_per_day, c.game_stage_born_world_time);
    // Still capped to level, so the stage is unchanged at 25 days.
    try std.testing.expectEqual(@as(i32, 24), g.gameStageOf(0));
    // Loot stage is level driven and independent of days survived.
    try std.testing.expectEqual(@as(i32, 10), g.lootStageOf(0));
    try std.testing.expectEqual(@as(i32, 10), g.partyLootStage());
    // A single player's party stage is just their own stage.
    try std.testing.expectEqual(@as(i32, 24), g.partyStageAround(0, 0, -1));
}

test "party stage weights the second player by diminishing returns" {
    const g = try Game.create(std.testing.allocator, ".zdtd_cfg_cache/partystage", 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    g.gamestages.config = .{ .difficulty_bonus = 1, .starting_weight = 1, .diminishing_returns = 0.5 };
    g.sim.director.clock.day = 0;
    g.sim.director.clock.hours = 0;
    const now = g.sim.director.clock.worldTimeBits();
    for ([_]struct { slot: usize, level: u16 }{ .{ .slot = 0, .level = 40 }, .{ .slot = 1, .level = 20 } }) |p| {
        const c = &g.clients[p.slot];
        c.joined = true;
        c.level = p.level;
        c.game_stage_born_world_time = now;
    }
    try std.testing.expectEqual(@as(i32, 40), g.gameStageOf(0));
    try std.testing.expectEqual(@as(i32, 20), g.gameStageOf(1));
    // 40 * 1 + 20 * 0.5 = 50 (CalcPartyLevel, asm.il ~1093305).
    try std.testing.expectEqual(@as(i32, 50), g.partyStageAround(0, 0, -1));
    // Highest party loot stage, not the sum.
    try std.testing.expectEqual(@as(i32, 40), g.partyLootStage());
    // No joined players is stage 0, and the loot floor stays at 1.
    g.clients[0].joined = false;
    g.clients[1].joined = false;
    try std.testing.expectEqual(@as(i32, 0), g.partyStageAround(0, 0, -1));
    try std.testing.expectEqual(@as(i32, 1), g.partyLootStage());
}

test "sleeper volume groups resolve through the gamestage ladder" {
    const g = try Game.create(std.testing.allocator, ".zdtd_cfg_cache/sleepergs", 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    // Synthetic tables: the stock POI group name is a gamestage group, never an
    // entitygroup, so the pre-gamestage lookup could only reach defaultZombie.
    var gs = try assets_gamestages.loadFromSlice(std.testing.allocator,
        \\<gamestages>
        \\  <group name="1GroupGenericZombie" spawner="SleeperGSList"/>
        \\  <spawner name="SleeperGSList">
        \\    <gamestage stage="0"><spawn group="ZombiesAll" num="3" maxAlive="2"/></gamestage>
        \\  </spawner>
        \\</gamestages>
    );
    g.gamestages.deinit();
    g.gamestages = gs;
    gs = undefined;

    // A one-entry entity group so the pick is deterministic and distinguishable
    // from defaultZombie (which is zombieBoe in the builtin table).
    const stag_entries = [_]assets_entitygroups.Entry{.{ .name = "animalStag", .weight = 1 }};
    const stage_groups = [_]assets_entitygroups.Group{
        .{ .name = "ZombiesAll", .entries = &stag_entries, .weight_sum = 1 },
    };
    g.entitygroups.deinit();
    g.entitygroups = .{ .groups = &stage_groups };

    const walker = g.entities.defaultZombie();
    // Both stock spellings clean to the same key and reach a real class.
    for ([_][]const u8{ "GroupGenericZombie", "S_-Group_Generic_Zombie" }) |name| {
        const sg = g.gamestages.sleeperEntityGroup(name, 0) orelse return error.GroupUnresolved;
        try std.testing.expectEqualStrings("ZombiesAll", sg.group);
        try std.testing.expectEqual(@as(u16, 3), sg.num);
        try std.testing.expectEqual(@as(u16, 2), sg.max_alive);
        // The class comes from the stage's entitygroup, not the default walker.
        const def = g.resolveSleeperClass(name, sg, 11);
        try std.testing.expectEqualStrings("animalStag", def.name);
        try std.testing.expect(!std.mem.eql(u8, walker.name, def.name));
    }
    // A stage below the ladder's first entry resolves to nothing (stock returns
    // null from GetStage), so the old entityclass/entitygroup path still runs.
    try std.testing.expect(g.gamestages.sleeperEntityGroup("GroupGenericZombie", -1) == null);
    try std.testing.expectEqualStrings(walker.name, g.resolveSleeperClass("NoSuchThing", null, 3).name);
}

test "console replies use the stock error and listing shapes" {
    io_fs.mkdirPathSimple(".zdtd_cfg_cache");
    const g = try Game.create(std.testing.allocator, ".zdtd_cfg_cache/admin_stock_shapes", 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var sink: [8192]u8 = undefined;

    try std.testing.expectEqualStrings(
        "*** ERROR: unknown command 'frobnicate'\n",
        adminRun(g, &sink, "frobnicate 1"),
    );
    try std.testing.expectEqualStrings(
        "Wrong number of arguments, expected 1 or 3, found 2.\n",
        adminRun(g, &sink, "settime 1 2"),
    );
    try std.testing.expectEqualStrings("Day must be >= 1\n", adminRun(g, &sink, "settime 0 1 1"));
    try std.testing.expectEqualStrings(
        "\"noon\" is not a valid integer.\n",
        adminRun(g, &sink, "settime 1 noon 0"),
    );
    // No players joined: both listings are just the stock total line.
    try std.testing.expectEqualStrings("Total of 0 in the game\n", adminRun(g, &sink, "listplayers"));
    try std.testing.expectEqualStrings("Total of 0 in the game\n", adminRun(g, &sink, "listplayerids"));
    // A miss on a player target reports the stock resolution error.
    try std.testing.expectEqualStrings(
        "\"Alice\" is not a valid entity id, player name or user id.\n",
        adminRun(g, &sink, "kick Alice"),
    );

    const help = adminRun(g, &sink, "help");
    try std.testing.expect(std.mem.startsWith(u8, help, "*** Generic Console Help ***\n"));
    try std.testing.expect(std.mem.indexOf(u8, help, "*** List of Commands ***\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, " => lists all players\n") != null);

    // settime takes stock world time and reports it back verbatim.
    try std.testing.expectEqualStrings("Set time to 12000\n", adminRun(g, &sink, "settime day"));
    try std.testing.expectEqual(@as(u32, 1), g.sim.director.clock.day);
    try std.testing.expectEqual(@as(f32, 12), g.sim.director.clock.hours);
    try std.testing.expectEqualStrings("Set time to 24000\n", adminRun(g, &sink, "settime night"));
    try std.testing.expectEqual(@as(u32, 2), g.sim.director.clock.day);
    try std.testing.expectEqual(@as(f32, 0), g.sim.director.clock.hours);

    // listents rows carry the stock field order for the seeded zombies.
    const ents = adminRun(g, &sink, "listents");
    try std.testing.expect(std.mem.indexOf(u8, ents, ", pos=(") != null);
    try std.testing.expect(std.mem.indexOf(u8, ents, ", rot=(") != null);
    try std.testing.expect(std.mem.indexOf(u8, ents, ", lifetime=float.Max, remote=False, dead=False, health=") != null);
    try std.testing.expect(std.mem.indexOf(u8, ents, "in the game\n") != null);

    try std.testing.expect(std.mem.startsWith(u8, adminRun(g, &sink, "chunkcache"), "Chunks: "));
    try std.testing.expect(std.mem.startsWith(u8, adminRun(g, &sink, "mem"), "Time: "));
    try std.testing.expect(std.mem.indexOf(u8, adminRun(g, &sink, "gg ServerPort"), "GamePref.ServerPort = ") != null);
}

test "admin, whitelist and ban lists persist across a restart" {
    io_fs.mkdirPathSimple(".zdtd_cfg_cache");
    const dir = ".zdtd_cfg_cache/admin_lists_persist";
    var sink: [8192]u8 = undefined;
    {
        const g = try Game.create(std.testing.allocator, dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        try std.testing.expectEqualStrings(
            "Alice added with permission level of 0.\n",
            adminRun(g, &sink, "admin add Alice 0"),
        );
        try std.testing.expectEqualStrings(
            "Bob added to whitelist.\n",
            adminRun(g, &sink, "whitelist add Bob"),
        );
        try std.testing.expect(std.mem.startsWith(u8, adminRun(g, &sink, "ban add Carol 1 day rude"), "Carol banned until "));
        // An expired ban must not survive the round-trip.
        _ = g.ban_list.add("Dave", clock.wallSeconds() - 1, "old");
        g.saveAdminLists();
    }
    {
        const g = try Game.create(std.testing.allocator, dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        const admins = adminRun(g, &sink, "admin list");
        try std.testing.expect(std.mem.indexOf(u8, admins, "0: Alice (stored name: Alice)\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, adminRun(g, &sink, "whitelist list"), "  Bob (stored name: Bob)\n") != null);
        const bans = adminRun(g, &sink, "ban list");
        try std.testing.expect(std.mem.indexOf(u8, bans, "Carol) - rude\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, bans, "Dave") == null);

        try std.testing.expectEqualStrings(
            "Carol removed from ban list.\n",
            adminRun(g, &sink, "ban remove Carol"),
        );
        try std.testing.expectEqualStrings(
            "Alice removed from permissions list.\n",
            adminRun(g, &sink, "admin remove Alice"),
        );
        try std.testing.expectEqualStrings(
            "Alice was not on permissions list.\n",
            adminRun(g, &sink, "admin remove Alice"),
        );
        try std.testing.expectEqualStrings(
            "Bob removed from the whitelist.\n",
            adminRun(g, &sink, "whitelist remove Bob"),
        );
    }
}

/// Run one console line against a Game and capture the reply the way the webui
/// path does, so a test asserts the exact bytes an operator tool would read.
fn adminRun(g: *Game, sink: []u8, line: []const u8) []const u8 {
    g.admin_reply_len = 0;
    g.admin_reply_sink = sink;
    g.runAdminLine(line, "test");
    g.admin_reply_sink = null;
    return sink[0..g.admin_reply_len];
}
