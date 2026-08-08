//! Game server: join SM, tick, interest, combat, persistence.
//! Simulation is an SoA ECS (`ecs.World` + systems).

const std = @import("std");
const version = @import("../version.zig");
const apm = @import("../apm/root.zig");
const clock = @import("../util/clock.zig");
const ln_server = @import("../litenet/server.zig");
const ln_peer = @import("../litenet/peer.zig");
const ln_packet = @import("../litenet/packet.zig");
const wire_frame = @import("../wire/frame.zig");
const wire_binary = @import("../wire/binary.zig");
const packages = @import("../wire/packages.zig");
const world_store = @import("../world/store.zig");
const subbiome_noise = @import("../world/subbiome_noise.zig");
const world_tts = @import("../world/tts.zig");
const deco_mirror = @import("../world/deco_mirror.zig");
const ecs = @import("../ecs/root.zig");
const systems = @import("../ecs/systems.zig");
const parallel_util = @import("../util/parallel.zig");
const rng_util = @import("../util/rng.zig");
const protocol = @import("../protocol.zig");
const replicate_te = @import("replicate_te.zig");
const game_net = @import("game/net.zig");
const game_tick = @import("game/tick.zig");
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
const game_weather = @import("game/weather.zig");
const game_vehicle = @import("game/vehicle.zig");
const persist = @import("persist.zig");
const c2s_move = @import("c2s/move.zig");
const c2s_inv = @import("c2s/inv.zig");
const c2s_quest = @import("c2s/quest.zig");
const c2s_misc = @import("c2s/misc.zig");
const c2s_join = @import("c2s/join.zig");
const admin_console = @import("admin_console.zig");
const game_types = @import("game/types.zig");
const ConsoleOut = admin_console.ConsoleOut;
const TargetResult = admin_console.TargetResult;
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
const assets_npc = @import("../assets/npc.zig");
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
const stability_mod = @import("../world/stability.zig");
const terrain_snapshot = @import("../world/terrain_snapshot.zig");
const jobs = @import("../ecs/jobs.zig");
const interest = @import("../ecs/interest.zig");
const invsys = @import("../ecs/inventory.zig");
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

/// Game embeds the claim table on the heap; 1024 covers a long-lived server
/// (GAP 12: 256 silently dropped the 257th claim on register).
pub const max_land_claims: usize = 1024;
/// Quest.PositionData entries the server ever writes: Location + POIPosition + POISize.
pub const max_quest_position_data: usize = 3;
const apm_report_period_ticks: u64 = protocol.ticks_per_second * 60;

/// `help` index. Stock names and descriptions where the verb exists in stock
/// (ConsoleCmdHelp, asm.il 226623); zdtd-only verbs are marked so an operator can
/// tell parity from extension at a glance.
pub const admin_help_index = [_]admin_cmds.HelpEntry{
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
pub const logPersistErr = persist.logPersistErr;
pub const Zpv2Drop = persist.Zpv2Drop;
pub const zpvRecordLen = persist.zpvRecordLen;
pub const zpv2DropName = persist.zpv2DropName;

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

const eqAny = c2s_text.eqAny;
const sanitizePlayerName = c2s_text.sanitizePlayerName;
const chatMsgOk = c2s_text.chatMsgOk;
const isPlayerConsoleCommand = c2s_text.isPlayerConsoleCommand;

// --- Wasm plugin host callbacks (ADR 0020) ---------------------------------
// The plugin layer hands these back the HostCtx; `data` is this Game. All run
// on the main tick/net thread. queue only appends to the fixed sim command
// buffer (drained once per tick by the ecs schedule); it never touches the sim
// directly, so plugin calls cannot race or reenter the tick.

const wasm_log_level_tags = [_][]const u8{ "debug", "info", "warn", "err" };

fn wasmLog(ctx: *plugin_mod.wasm.HostCtx, level: u8, msg: []const u8) void {
    _ = ctx;
    const tag = wasm_log_level_tags[@min(@as(usize, level), wasm_log_level_tags.len - 1)];
    std.debug.print("zdtd wasm: {s}: {s}\n", .{ tag, msg });
}

fn wasmTick(ctx: *plugin_mod.wasm.HostCtx) u64 {
    const g: *Game = @ptrCast(@alignCast(ctx.data orelse return 0));
    return g.tick_n;
}

/// Kill verdict routed from the sim (World.kill_verdict_fn, T15): players go
/// to on_player_death, everything else to on_entity_killed. The static host
/// votes first, then the Wasm host; the first non-zero verdict wins. A
/// negative return denies the death; the sim keeps the victim at 1 hp.
fn killVerdict(ctx: ?*anyopaque, kind: ecs.Kind, victim: i32, attacker: i32) i32 {
    const g: *Game = @ptrCast(@alignCast(ctx orelse return 0));
    return switch (kind) {
        .player => blk: {
            const sv = g.plugins.playerDeath(victim);
            break :blk if (sv != 0) sv else g.wasm_plugins.playerDeath(victim);
        },
        else => blk: {
            const sv = g.plugins.entityKilled(victim, attacker);
            break :blk if (sv != 0) sv else g.wasm_plugins.entityKilled(victim, attacker);
        },
    };
}

/// Combined block-damage verdict: static host first, then Wasm (first non-zero
/// wins; 0 = no plugin vetoes/scales, keep today's behaviour).
fn blockDamageVerdict(self: *Game, x: i32, y: i32, z: i32, dmg: i32) i32 {
    const sv = self.plugins.blockDamage(x, y, z, dmg);
    return if (sv != 0) sv else self.wasm_plugins.blockDamage(x, y, z, dmg);
}

/// Max bytes of one queued command string from a guest (bounds the tokenizer).
const max_plugin_cmd_len: usize = 128;

fn wasmQueue(ctx: *plugin_mod.wasm.HostCtx, cmd: []const u8) void {
    const g: *Game = @ptrCast(@alignCast(ctx.data orelse return));
    if (cmd.len > max_plugin_cmd_len) {
        std.debug.print("zdtd wasm: queued command too long ({d} bytes); dropped\n", .{cmd.len});
        return;
    }
    const op = parsePluginCommand(cmd) orelse {
        // Log verb only: args may include player names, chat text, or coords.
        const verb_end = std.mem.indexOfScalar(u8, cmd, ' ') orelse cmd.len;
        std.debug.print("zdtd wasm: unknown queued command '{s}'\n", .{cmd[0..verb_end]});
        return;
    };
    // Fixed 64-slot buffer (ecs/command.zig); drops when full, by named cap.
    _ = g.sim.commands.push(op);
}

/// Text SimCommand grammar (PLUGIN_API.md): `spawn x y z hp`, `despawn id`,
/// `damage id amount`. Allocation-free; unknown or malformed input returns null
/// and the caller drops it. Extra trailing tokens are malformed, not ignored.
fn parsePluginCommand(cmd: []const u8) ?ecs.command.Op {
    var it = std.mem.tokenizeScalar(u8, cmd, ' ');
    const verb = it.next() orelse return null;
    if (std.mem.eql(u8, verb, "spawn")) {
        const x = it.next() orelse return null;
        const y = it.next() orelse return null;
        const z = it.next() orelse return null;
        const hp = it.next() orelse return null;
        if (it.next() != null) return null;
        return .{ .spawn_zombie = .{
            .x = std.fmt.parseFloat(f32, x) catch return null,
            .y = std.fmt.parseFloat(f32, y) catch return null,
            .z = std.fmt.parseFloat(f32, z) catch return null,
            .hp = std.fmt.parseFloat(f32, hp) catch return null,
        } };
    }
    if (std.mem.eql(u8, verb, "despawn")) {
        const id = it.next() orelse return null;
        if (it.next() != null) return null;
        return .{ .despawn = .{ .net_id = std.fmt.parseInt(i32, id, 10) catch return null } };
    }
    if (std.mem.eql(u8, verb, "damage")) {
        const id = it.next() orelse return null;
        const amt = it.next() orelse return null;
        if (it.next() != null) return null;
        return .{ .damage = .{
            .net_id = std.fmt.parseInt(i32, id, 10) catch return null,
            .amount = std.fmt.parseFloat(f32, amt) catch return null,
        } };
    }
    return null;
}

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
            .deco_objects_per_join = opts.deco_objects_per_join,
            .sandbox_code = opts.sandbox_code,
            .sandbox_preset = opts.sandbox_preset,
            .plugins = .{ .sample_enabled = opts.enable_sample_plugin },
            .wasm_ctx = .{
                .data = @ptrCast(self),
                .log_fn = &wasmLog,
                .tick_fn = &wasmTick,
                .queue_fn = &wasmQueue,
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
            self.npc.deinit();
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
                fn multiblock(ctx: ?*anyopaque, name: []const u8) assets_maxdamage.Dim {
                    const t: *const assets_maxdamage.Table = @ptrCast(@alignCast(ctx.?));
                    return t.multiBlockDim(name);
                }
            };
            if (self.maxdamage.id_by_name.count() > 0) {
                pf.setIdLookup(.{ .ctx = &self.maxdamage, .lookup = NimCtx.lookup, .multiblock = NimCtx.multiblock });
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
                .drop_prob = zdef.loot_drop_prob,
                .chase_speed = zdef.chase_speed,
                .wander_speed = zdef.wander_speed,
                .attack_damage = self.handItemDamage(zdef.hand_item),
                .time_stay = zdef.time_stay,
                .sight_range = zdef.sight_range,
            });
            const adef = self.entities.defaultAnimal();
            self.sim.setClassDef(7, .{
                .name = adef.name,
                .max_hp = adef.max_hp,
                .kind = .animal,
                .hash = adef.hash,
                .loot_list = adef.loot_list,
                .drop_prob = adef.loot_drop_prob,
                .chase_speed = adef.chase_speed,
                .wander_speed = adef.wander_speed,
                .attack_damage = self.handItemDamage(adef.hand_item),
                .time_stay = adef.time_stay,
                .sight_range = adef.sight_range,
            });
            std.debug.print("zdtd: entityclasses defs={d} zombie={s} hash={d}\n", .{
                self.entities.defs.len, zdef.name, zdef.hash,
            });
        }
        // Trader NPC: real class hash so the client renders EntityTrader. Runs
        // for the builtin table too (no game-dir), where the offline demo trader
        // still needs a renderable class; the XML def wins when a game-dir loads.
        if (self.entities.defaultTrader()) |tdef| {
            self.sim.setClassDef(3, .{
                .name = tdef.name,
                .max_hp = tdef.max_hp,
                .kind = .trader,
                .hash = tdef.hash,
                .loot_list = tdef.loot_list,
                .drop_prob = tdef.loot_drop_prob,
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
                    .drop_prob = def.loot_drop_prob,
                    .chase_speed = def.chase_speed,
                    .wander_speed = def.wander_speed,
                    .attack_damage = self.handItemDamage(def.hand_item),
                    .time_stay = def.time_stay,
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
        if (assets_npc.tryLoad(allocator, opts.game_dir, opts.config_dir)) |nt| {
            self.npc.deinit();
            self.npc = nt;
        }
        // Trader POIs on a stock map: spawn each POI's trader NPC at its
        // IndexedBlockOffsets "Trader" cell so a player walking to a compound
        // finds the trader, not an empty building (needs prefabs + entities +
        // npc tables, hence after the loads above).
        self.spawnPoiTraders();
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
            // Biome-aware group override: resolve per spawn-point biome so e.g.
            // wasteland at midnight spawns wasteland walkers, not pine_forest's.
            self.sim.director.biome_group_ctx = self;
            self.sim.director.biome_group_fn = &Game.biomeGroupName;
            self.sim.director.group_pick_ctx = self;
            self.sim.director.group_pick_fn = &Game.pickEntityGroup;
            // Full class resolution: any entityclasses.xml class a spawn group
            // picks reaches the sim with its own HP/speeds/damage, even when it
            // is not preloaded into the fixed class_table (A35).
            self.sim.director.class_resolve_ctx = self;
            self.sim.director.class_resolve_fn = &Game.resolveSpawnClass;
            self.sim.director.stage_group_ctx = self;
            self.sim.director.stage_group_fn = &Game.pickStageGroup;
            self.sim.director.spawner_group_ctx = self;
            self.sim.director.spawner_group_fn = &Game.pickSpawnerGroup;
            // Plugin kill verdict (T15): routes the sim's death decision to the
            // Wasm host (on_player_death for players, on_entity_killed for the
            // rest). Unset hook = no plugins = today's behaviour.
            self.sim.kill_verdict_ctx = self;
            self.sim.kill_verdict_fn = &killVerdict;
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
                // The procedural generator picks up the loaded biome stacks (W3).
                self.world.syncWorldgenBiomes();
                // Weather groups must come from the same effective biomes.xml we
                // serve, since groupIndex is a document ordinal in that file.
                // Frequency and countdown divisor read the very GameStats values
                // the client is told, so server sim and client display agree.
                const gs_defaults: packages.GameStatsValues = .{};
                self.world.weather.initFrom(&self.world.biome_layers_table, .{
                    .seed = opts.worldgen_seed orelse util_sim.default_seed,
                    .day_night_length = opts.day_night_length,
                    // [sim] storm_frequency percent -> the 1.0x divisor the
                    // scheduler divides by (0 disables storms). Mirrors the
                    // GameStats wire value so client and server agree.
                    .storm_frequency = @as(f32, @floatFromInt(self.storm_frequency)) / 100.0,
                    .time_of_day_inc_per_sec = @intCast(@max(gs_defaults.time_of_day_inc_per_sec, 0)),
                });
                self.restoreWeather();
                const burnt = bl.stackFor(9);
                std.debug.print("zdtd: biome layers default_n={d} burnt_n={d} burnt0={d} decos={s}\n", .{
                    bl.default_stack.n,
                    burnt.n,
                    if (burnt.n > 0) burnt.layers[0].block_id else 0,
                    if (bl.hasDecos()) "yes" else "no",
                });
            }
            // Clock restore is independent of the biome-layers load: a world
            // without stock biome data must still resume its saved day/time.
            self.restoreClock();
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
                    if (world_store.prefabs.isPart(d.name)) continue;
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
                        if (world_store.prefabs.isPart(d.name)) continue;
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
            // DST replay key: the single value that reproduces this run.
            std.debug.print("zdtd: DST run seed={d}\n", .{seed});
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
                .server_version = version.stock_wire_gsi_version,
                .world_size = 6144,
                .eac_enabled = false,
                .password_protected = self.password.len > 0,
                .sandbox_preset = self.sandbox_preset,
                .sandbox_code = self.sandbox_code,
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
                .fail_block_minutes = opts.telnet_failed_logins_blocktime,
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
        if (self.sim.spawnTrader("Trader Jen", sx + 12, sy, sz + 8, self.npc.traderIdForClass("Trader Jen"), self.trader_wallet_dukes)) |trader_id| {
            self.fillTraderFromXml(trader_id);
        }
        // Persistable kinds seed only on a fresh world; entities.zen owns
        // them across restarts (see had_saved_entities above).
        if (!had_saved_entities) {
            const vk: ecs.components.VehicleKind = .minibike;
            if (self.vehicles.byKind(vk)) |vd| {
                _ = self.sim.spawnVehicleEx(vk, sx + 6, sy, sz - 4, vd.max_hp, vd.velocity_max, vd.seat_count);
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
            const chest_block: u16 = replicate_te.seedChestBlockId(self);
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
        // The turret is persistable and only seeds fresh; the generator is a
        // virtual node (no block) and re-seeds every boot so a restored turret
        // still finds a source after a restart.
        const gen = self.sim.power.addNode(.generator, @intFromFloat(sx + 50), @intFromFloat(sy), @intFromFloat(sz + 50), 100);
        if (!had_saved_entities) {
            if (self.sim.spawnTurret(sx + 52, sy, sz + 52)) |tid| {
                if (gen) |gid| {
                    if (self.sim.slotOfNetId(tid)) |ts| {
                        _ = self.sim.power.connect(gid, self.sim.turret[ts].power_node);
                    }
                }
            }
        }
        self.sim.power.resolve();

        // Static plugins after world/assets are ready (sample_hello logs once).
        self.plugins.enableStaticDefaults();
        // Wasm plugins from config ([plugin] modules, ADR 0020): load once at
        // init (allocation allowed here), then enable. loadAll logs and skips
        // a missing or unloadable module, so one bad file does not kill boot.
        self.wasm_plugins.loadAll(self.allocator, opts.plugin_modules, &self.wasm_ctx, opts.plugin_budget);
        self.wasm_plugins.enable();
    }

    /// True when Hard C2S rejects should apply (Correct mode). Observe keeps
    /// join-phase Hard drops but is the flag for future soft-only paths.
    fn authorityCorrects(self: *const Game) bool {
        return self.authority_mode == .correct;
    }

    pub fn noteAcceptedMove(self: *Game, c: *Client, x: f32, y: f32, z: f32) void {
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

    pub fn resetMoveEnvelopePeer(self: *Game, peer_slot: usize, x: f32, y: f32, z: f32) void {
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
    pub fn applyMovementEnvelope(
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

    fn heightAtWorld(ctx: ?*anyopaque, wx: i32, wz: i32) f32 {
        return game_hooks.heightAtWorld(ctx, wx, wz);
    }

    fn spawnPoiTraders(self: *Game) void {
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
    pub fn tryRefuelGenerator(self: *Game, c: *const Client, x: i32, y: i32, z: i32, amount: f32) bool {
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
    pub fn eatProps(ctx: ?*anyopaque, item_id: u16) invsys.EatProps {
        const g: *Game = @ptrCast(@alignCast(ctx.?));
        return .{
            .is_eat = g.items.isEat(item_id),
            .food_amount = g.items.foodAmountFor(item_id),
            .food_health = g.items.foodHealthFor(item_id),
            .water_amount = g.items.waterAmountFor(item_id),
        };
    }

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
        self.containers.save(self.world.world_dir, self.allocator) catch |e| logPersistErr(self, "save containers", e);
        self.workstations.save(self.world.world_dir, self.allocator) catch |e| logPersistErr(self, "save workstations", e);
        self.vending.save(self.world.world_dir) catch |e| logPersistErr(self, "save vending", e);
        self.saveClaims() catch |e| logPersistErr(self, "save claims", e);
        self.saveEntities() catch |e| logPersistErr(self, "save entities", e);
        self.allies.save(self.world.world_dir, self.allocator) catch |e| logPersistErr(self, "save allies", e);
        self.saveBlockMeta() catch |e| logPersistErr(self, "save block meta", e);
        self.saveWeather() catch |e| logPersistErr(self, "save weather", e);
        self.saveClock() catch |e| logPersistErr(self, "save clock", e);
        self.land_claims_n = 0;
        self.plugins.shutdown();
        self.wasm_plugins.shutdown();
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
        self.npc.deinit();
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

    pub fn refreshInfoPlayers(self: *Game) void {
        self.info_tcp.setPlayers(@intCast(self.countJoined()));
    }

    pub fn playersPath(self: *const Game, buf: []u8) ![]const u8 {
        return persist.playersPath(self, buf);
    }

    pub fn savePlayers(self: *Game) !void {
        return persist.savePlayers(self);
    }

    /// Remove all players.zsv records whose login name equals `name`.
    /// Returns how many records were dropped. FileNotFound → 0 (no-op).
    /// Does not log the name (operator reply only).
    pub fn wipePlayerRecordsByName(self: *Game, name: []const u8) !u32 {
        return persist.wipePlayerRecordsByName(self, name);
    }

    pub fn tryRestorePlayer(self: *Game, c: *Client) void {
        return persist.tryRestorePlayer(self, c);
    }

    fn pollAdmin(self: *Game) void {
        admin_console.pollAdmin(self);
    }

    pub fn adminReply(self: *Game, text: []const u8) void {
        admin_console.adminReply(self, text);
    }

    fn pollWebui(self: *Game) void {
        admin_console.pollWebui(self);
    }

    pub fn fillWebuiSnap(self: *Game) void {
        admin_console.fillWebuiSnap(self);
    }

    pub fn handleConsoleCmd(self: *Game, peer: *ln_peer.Peer, c: *Client, body: []const u8) !void {
        return admin_console.handleConsoleCmd(self, peer, c, body);
    }

    pub fn consoleSetTime(self: *Game, it: *std.mem.TokenIterator(u8, .any), out: *ConsoleOut) void {
        admin_console.consoleSetTime(self, it, out);
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

    pub fn daysToBloodMoon(self: *const Game) u32 {
        return admin_console.daysToBloodMoon(self);
    }

    fn webuiAdminThunk(ctx: *anyopaque, line: []const u8, out: []u8) usize {
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

    fn loadAdminLists(self: *Game) void {
        admin_console.loadAdminLists(self);
    }

    pub fn readAdminList(self: *Game, name: []const u8, label: []const u8, load: *const fn (*Game, []const u8, i64) admin_cmds.LoadResult, now: i64) void {
        admin_console.readAdminList(self, name, label, load, now);
    }

    pub fn replyGamePrefs(self: *Game, filter: []const u8) void {
        admin_console.replyGamePrefs(self, filter);
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

    pub fn worldHour(self: *const Game) u64 {
        return game_tick.worldHour(self);
    }

    fn tickAirDrop(self: *Game) void {
        return game_tick.tickAirDrop(self);
    }

    fn tickZombieBlockDamage(self: *Game) void {
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

    pub fn setBlockHp(self: *Game, x: i32, y: i32, z: i32, abs: u16) void {
        return game_world.setBlockHp(self, x, y, z, abs);
    }

    pub fn addBlockDamage(self: *Game, x: i32, y: i32, z: i32, dmg: u16) u16 {
        return game_world.addBlockDamage(self, x, y, z, dmg);
    }

    pub fn clearBlockHp(self: *Game, x: i32, y: i32, z: i32) void {
        return game_world.clearBlockHp(self, x, y, z);
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

    /// Persist the world clock (day + hours as stock worldTime) so a restart
    /// keeps the calendar — the blood-moon schedule derives from the day, so a
    /// save used to reset to day 1 and never be more than 7 days from its
    /// first horde. File: `clock.zcl` ("ZCL1" | u64 worldTime), the same
    /// encoding stock persists (GamePrefs worldTime / WorldClock Read+Write).
    /// Saved on the periodic save path and at deinit; restored right after the
    /// fresh clock in initWithOptions.
    pub fn saveClock(self: *const Game) !void {
        var path: [512]u8 = undefined;
        const p = try std.fmt.bufPrint(&path, "{s}/clock.zcl", .{self.world.world_dir});
        var buf: [16]u8 = undefined;
        @memcpy(buf[0..4], "ZCL1");
        std.mem.writeInt(u64, buf[4..12], self.sim.director.clock.worldTimeBits(), .little);
        try io_fs.writeFile(self.allocator, p, buf[0..12]);
    }

    /// Restore `clock.zcl` over the freshly seeded clock. A missing file is a
    /// fresh world (keep day 1); a corrupt or unreadable file is dropped with a
    /// log line (never silent: the next save would otherwise clobber day 1).
    fn restoreClock(self: *Game) void {
        var path: [512]u8 = undefined;
        const p = std.fmt.bufPrint(&path, "{s}/clock.zcl", .{self.world.world_dir}) catch {
            std.debug.print("zdtd: clock.zcl path too long; keeping fresh clock\n", .{});
            return;
        };
        if (!io_fs.fileExistsSimple(p)) return;
        var buf: [16]u8 = undefined;
        const bytes = io_fs.readFileInto(self.allocator, p, &buf) catch |err| {
            // File exists but could not be read: operator must know the calendar
            // reset is involuntary, not a fresh world.
            logPersistErr(self, "restore clock", err);
            return;
        };
        if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "ZCL1")) {
            std.debug.print("zdtd: clock.zcl unreadable or mismatched; keeping fresh clock\n", .{});
            return;
        }
        const wt = std.mem.readInt(u64, bytes[4..12], .little);
        self.sim.director.clock.day = @intCast(wt / 24000 + 1);
        self.sim.director.clock.hours = @as(f32, @floatFromInt(wt % 24000)) / 1000.0;
        std.debug.print("zdtd: clock restored day={d} hours={d:.2}\n", .{ self.sim.director.clock.day, self.sim.director.clock.hours });
    }

    /// Persist the storm state machine so a restart resumes the storm cycle
    /// instead of re-rolling the opening groups. File: `weather.zwt` (ZWTH1).
    /// Saved on the periodic save path and at deinit; restored right after
    /// initFrom in initWithOptions.
    pub fn saveWeather(self: *const Game) !void {
        var path: [512]u8 = undefined;
        const p = try std.fmt.bufPrint(&path, "{s}/weather.zwt", .{self.world.world_dir});
        var buf: [1024]u8 = undefined;
        const enc = try self.world.weather.encode(&buf);
        try io_fs.writeFile(self.allocator, p, enc);
    }

    /// Restore `weather.zwt` over the freshly seeded manager. A missing file is
    /// a fresh world (keep the roll); a corrupt, unreadable, or table-mismatched
    /// file is dropped with a log line (fail closed: weather.zig decode never
    /// half-applies; I/O errors must not look like "no weather file yet").
    fn restoreWeather(self: *Game) void {
        var path: [512]u8 = undefined;
        const p = std.fmt.bufPrint(&path, "{s}/weather.zwt", .{self.world.world_dir}) catch {
            std.debug.print("zdtd: weather.zwt path too long; keeping fresh roll\n", .{});
            return;
        };
        if (!io_fs.fileExistsSimple(p)) return;
        var buf: [1024]u8 = undefined;
        const bytes = io_fs.readFileInto(self.allocator, p, &buf) catch |err| {
            logPersistErr(self, "restore weather", err);
            return;
        };
        if (self.world.weather.decode(bytes, &self.world.biome_layers_table)) {
            std.debug.print("zdtd: weather state restored ({d} biomes)\n", .{self.world.weather.n});
        } else {
            std.debug.print("zdtd: weather.zwt unreadable or mismatched; keeping fresh roll\n", .{});
        }
    }

    /// Persist sparse block meta (rotation raw + accumulated damage) so doors/
    /// shapes and partial block damage survive restart. File: "ZBM1" | u16 raw_n |
    /// (key u64 + raw u32)* | u16 hp_n | (key u64 + hp u16)*.
    /// Keys are sorted so bytes do not depend on insert/remove history (DST).
    pub fn saveBlockMeta(self: *const Game) !void {
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

    /// Lock stale after this many ns without unlock (holder disconnect still clears
    /// immediately). Tuned via zdtd.toml [authority] lock_stale_ms; default 120s.
    pub fn packLockPos(x: i32, y: i32, z: i32) u64 {
        // 21 bits each axis signed into 63 bits (enough for world coords).
        const ux: u64 = @as(u32, @bitCast(x));
        const uy: u64 = @as(u32, @bitCast(y));
        const uz: u64 = @as(u32, @bitCast(z));
        return (ux & 0x1fffff) | ((uy & 0x1fffff) << 21) | ((uz & 0x1fffff) << 42);
    }

    pub fn firstLockTargetPos(targets_blob: []const u8) ?struct { x: i32, y: i32, z: i32 } {
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

    pub fn clearLockSlot(self: *Game, ch: usize) void {
        if (ch >= self.lock_channel.len) return;
        self.lock_channel[ch] = -1;
        self.lock_holder_entity[ch] = -1;
        self.lock_granted_ns[ch] = 0;
        self.lock_pos_key[ch] = 0;
    }

    pub fn clearLocksForPeer(self: *Game, peer_slot: usize) void {
        const ps: i32 = @intCast(peer_slot);
        for (&self.lock_channel, 0..) |*h, i| {
            if (h.* == ps) self.clearLockSlot(i);
        }
    }

    /// Drop locks held longer than the lock stale window (tick path).
    fn reapStaleLocks(self: *Game) void {
        return game_tick.reapStaleLocks(self);
    }

    fn reapStalePeers(self: *Game) void {
        return game_tick.reapStalePeers(self);
    }

    pub fn peerIpKey(peer: *const ln_peer.Peer) u32 {
        return game_net.peerIpKey(peer);
    }

    /// Stock ~500ms/IP; return true if join should be rejected.
    fn joinRateLimited(self: *Game, ip: u32) bool {
        if (ip == 0) return false;
        // Loopback multi-bot / unit tests share 127.0.0.1: do not throttle.
        if (ip == 0x7f000001) return false;
        const now_ms: u64 = clock.monoNs() / 1_000_000;
        const gap_ms: u64 = self.join_rate_limit_ms;
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

    pub fn banIp(self: *Game, ip: u32) void {
        return game_net.banIp(self, ip);
    }

    pub fn unbanIp(self: *Game, ip: u32) void {
        return game_net.unbanIp(self, ip);
    }

    fn pumpAcks(ctx: ?*anyopaque) void {
        const self: *Game = @ptrCast(@alignCast(ctx.?));
        // pollNetOnce reentrancy: control-only drain when already pumping.
        self.pollNetOnce();
    }

    pub fn onConnected(self: *Game, peer: *ln_peer.Peer) !void {
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

    pub fn onData(self: *Game, peer: *ln_peer.Peer, payload: []const u8) anyerror!void {
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
            .world_size = 6144,
            .eac_enabled = false,
            .password_protected = self.password.len > 0,
            .sandbox_preset = self.sandbox_preset,
            .sandbox_code = self.sandbox_code,
        };
        return try serverinfo_tcp.buildInfoText(buf, info);
    }

    fn handlePackage(self: *Game, c: *Client, peer: *ln_peer.Peer, id: u16, body: []const u8) !void {
        if (id >= packages.default_mappings.len) {
            std.debug.print("zdtd: unmapped package local_id={d} package_id={d} body_len={d}\n", .{ peer.local_id, id, body.len });
            return;
        }
        const name = packages.default_mappings[id];

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

        if (try c2s_join.handle(self, c, peer, name, body)) return;
        if (try c2s_move.handle(self, c, peer, name, body)) return;
        if (try c2s_inv.handle(self, c, peer, name, body)) return;
        if (try c2s_quest.handle(self, c, peer, name, body)) return;
        if (try c2s_misc.handle(self, c, peer, name, body)) return;
        self.harness.counters.inc(.c2s_unhandled);
        const un = self.harness.counters.get(.c2s_unhandled);
        if (un == 1 or un % 100 == 0) {
            std.debug.print(
                "zdtd: unhandled C2S pkg={s} local_id={d} n={d}\n",
                .{ name, peer.local_id, un },
            );
        }
    }

    /// Convert sim trader_stock into wire TraderStockEntry list (shared by the
    /// spawn ECD and the trader snapshot). Resolves ecs item ids to stock type
    /// ids via the negotiated items IdMapping; zero-count rows are skipped.
    pub fn stockEntries(self: *Game, s: ecs.Slot, out: []packages.TraderStockEntry) usize {
        const stock = self.sim.trader_stock[s];
        var n: usize = 0;
        var e: usize = 0;
        while (e < stock.n and n < out.len) : (e += 1) {
            const ent = stock.entries[e];
            if (ent.count == 0) continue;
            const type_id: i32 = resolveItemType(@ptrCast(self), ent.item);
            out[n] = .{
                .item = .{
                    .type_id = type_id,
                    .count = if (ent.count > 0) ent.count else 1,
                    .quality = ent.quality,
                },
                // Entry.Markup demand delta: +100 after a buy, -4 after a sell
                // (asm.il 856828-856866), reset on restock. The client shows the
                // demand arrows and, for player-owned/rentable machines, prices
                // from 1 + Markup*0.2 (loot-economy.md section 5).
                .markup = ent.markup,
            };
            n += 1;
        }
        return n;
    }

    pub fn sendTraderSnapshot(self: *Game, peer: *ln_peer.Peer, prefer_slot: ?ecs.Slot) !void {
        return game_join.sendTraderSnapshot(self, peer, prefer_slot);
    }

    pub fn handleTrade(self: *Game, c: *Client, body: []const u8) !void {
        const t = packages.parseTraderTrade(body) catch return;
        // allow_sell=false traders (vending machines, player-owned booths) never
        // buy from the player; stock disables the Sell tab entirely.
        if (t.side == 1) {
            if (self.sim.slotOfNetId(t.trader_entity)) |ts| {
                const info_id = self.sim.trader_stock[ts].trader_info_id;
                if (info_id != 0) {
                    if (self.traders.traderInfo(info_id)) |info| {
                        if (!info.allow_sell) return;
                    }
                }
            }
        }
        const coin = self.coinItemId();
        _ = systems.trade(&self.sim, c.slot, t.trader_entity, t.item, t.qty, t.side, coin);
        if (c.peer) |p| {
            const ts = self.sim.slotOfNetId(t.trader_entity);
            try self.sendTraderSnapshot(p, ts);
        }
    }

    /// Stock NetPackageTraderData::ProcessPackage (asm.il 843218): mirror the
    /// client's post-trade TraderData onto the server's trader / vending stock
    /// (TraderData.CopyFrom). The client computes prices and moves inventory
    /// locally; the server accepts the resulting stock deltas and rebroadcasts
    /// the now-authoritative copy to observers. Price/sell stay server-owned
    /// (the wire TraderData carries no price; the client derives it from econ x
    /// markup).
    pub fn applyTraderDataCopyFrom(self: *Game, c: *Client, td: packages.TraderDataToServer) !void {
        var entries_buf: [ecs.components.max_stock]packages.stock_entity.TraderDataReadEntry = undefined;
        var tr: wire_binary.Reader = .{ .data = td.trader_data };
        const read = packages.stock_entity.readTraderDataBody(&tr, &entries_buf) catch return;
        if (td.is_entity) {
            const ts = self.sim.slotOfNetId(td.entity_id) orelse return;
            if (!self.sim.mask[ts].trader_stock) return;
            const st = &self.sim.trader_stock[ts];
            var i: usize = 0;
            while (i < read.n) : (i += 1) {
                const src = entries_buf[i];
                if (src.item.type_id == 0) {
                    st.entries[i] = .{};
                    continue;
                }
                const iname = self.items.nameByStockType(src.item.type_id) orelse continue;
                const eid = self.items.ecsIdByName(iname);
                if (eid == 0) continue;
                st.entries[i] = .{
                    .item = eid,
                    .count = src.item.count,
                    .markup = src.markup,
                    .price = st.entries[i].price,
                    .sell = st.entries[i].sell,
                };
            }
            // Drop the entries the client did not send back.
            while (i < st.entries.len) : (i += 1) st.entries[i] = .{};
            if (read.money >= 0) st.wallet = read.money;
            if (c.peer) |p| try self.sendTraderSnapshot(p, ts);
            return;
        }
        const vm = self.vending.get(.{ .x = td.te_x, .y = td.te_y, .z = td.te_z }) orelse return;
        var i: usize = 0;
        while (i < read.n and i < vending_mod.max_vending_stock) : (i += 1) {
            const src = entries_buf[i];
            if (src.item.type_id == 0) {
                vm.stock[i] = .{};
                continue;
            }
            // The vending store is wire-oriented (type_id is the stock type).
            vm.stock[i] = .{ .type_id = src.item.type_id, .count = src.item.count, .markup = src.markup };
        }
        while (i < vending_mod.max_vending_stock) : (i += 1) vm.stock[i] = .{};
        if (read.money >= 0) vm.available_money = read.money;
        try replicate_te.sendVendingTe(self, c.peer.?, td.te_x, td.te_y, td.te_z);
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
                    g.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(bx), @floatFromInt(bz), g.interest_range) catch {};
                } else |_| {}
            }
        };
        world_tts.paintDecoration(tb, d.x, d.stampY(), d.z, d.rot, self.world.terrain_ids.water, Ctx.put, self);
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
        self.sendFramedReliable(peer, "NetPackageIdMapping", framed, critical_retry_budget_ns, true) catch |err| {
            std.debug.print("zdtd: blocks IdMapping send failed: {s}\n", .{@errorName(err)});
            return err;
        };
        std.debug.print(
            "zdtd: blocks IdMapping objs={d} raw={d} wire={d}\n",
            .{ summary.count, summary.bytes, framed.len },
        );
    }

    /// Deflate a compressible package body (stock `get_Compress()` set:
    /// NetPackageChunk / NetPackageSignDataResponse) into send_buf and send it
    /// on the reliable channel. The body must live outside send_buf (chunks
    /// and sign batches are built in body_buf); false on any overflow/encode
    /// failure so the caller falls through to the uncompressed path.
    pub fn trySendCompressed(self: *Game, peer: *ln_peer.Peer, pkg_name: []const u8, body: []const u8) bool {
        const pkg_id = packages.idOf(pkg_name) orelse return false;
        var fr: wire_frame.DeflateFramer = undefined;
        fr.begin(&self.send_buf, &self.deflate_window, 0, pkg_id, body.len) catch return false;
        const w = fr.writer();
        w.writeAll(body) catch return false;
        const framed = fr.finish() catch return false;
        self.sendFramedReliable(peer, pkg_name, framed, window_retry_budget_ns, false) catch return false;
        return true;
    }

    /// Send an already-framed envelope on the reliable channel, pumping the window
    /// the same way `sendGame` does. Separate from `sendGame` because the compressed
    /// mapping frame is built by the streaming framer, not from a body buffer.
    pub fn sendFramedReliable(self: *Game, peer: *ln_peer.Peer, pkg_name: []const u8, framed: []const u8, budget_ns: u64, critical: bool) anyerror!void {
        // A live peer drains a small mapping inside a few outer attempts once
        // the 1 ms pacing lets its ACK cycle run; a large one (Navezgane,
        // ~200 fragments) drains inside one sendReliable via the inner per-part
        // pump. The outer budget also escapes a stuck window: it stays bounded
        // (paced attempts up to the deadline) so the stale-peer sweep reclaims
        // a dead peer instead of the tick holding for minutes.
        var retry_budget = budget_ns;
        if (critical) {
            const now = clock.monoNs();
            if (peer.critical_budget_deadline_ns < now) peer.critical_budget_deadline_ns = now + budget_ns;
            retry_budget = @min(budget_ns, peer.critical_budget_deadline_ns -% now);
        }
        const retry_deadline = clock.monoNs() + retry_budget;
        var attempts: u32 = 0;
        while (attempts < 960) : (attempts += 1) {
            peer.sendReliable(&self.net.sock, framed) catch |err| switch (err) {
                error.WindowFull => {
                    peer.resendPending(&self.net.sock) catch {
                        self.harness.counters.inc(.net_send_errors);
                    };
                    self.pollNetOnce();
                    if (clock.monoNs() >= retry_deadline) break;
                    if (attempts >= window_fast_attempts and attempts % 4 == 3) clock.sleepNs(window_retry_sleep_ns);
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
            // A successful critical send means the window is draining; re-arm
            // the shared budget so the rest of the bundle gets a fair window.
            if (critical) peer.critical_budget_deadline_ns = clock.monoNs() + budget_ns;
            return;
        }
        self.harness.counters.inc(.reliable_window_drops);
        std.debug.print("zdtd: reliable window drop pkg={s} (framed)\n", .{pkg_name});
        return error.WindowFull;
    }

    pub fn sendLocalConfigFiles(self: *Game, peer: *ln_peer.Peer) !void {
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
    pub fn rescueDeepVoid(self: *Game, peer: *ln_peer.Peer, entity_id: i32, x: f32, y: f32, z: f32, do_teleport: bool) !?f32 {
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
    pub fn withinEditReach(self: *const Game, px: f32, py: f32, pz: f32, bx: f32, by: f32, bz: f32) bool {
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
    pub fn noteEvidence(
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
    pub fn adminReplyGameStage(self: *Game, maybe_slot: ?usize) void {
        admin_console.adminReplyGameStage(self, maybe_slot);
    }

    pub fn adminReplyGuardPolicy(self: *Game) void {
        admin_console.adminReplyGuardPolicy(self);
    }
    pub fn loadShedding(self: *const Game) bool {
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
        return game_tick.reapPolicyKicks(self);
    }

    /// Shared peer teardown for admin kick/ban/wipeplayer and the guard policy.
    /// Resetting the slot to `.{}` also clears guard/quarantine state. `reason`
    /// names the dropping path so the server log keeps a complete join/leave
    /// trail: joins are logged, so drops (quit, kick, ban, guard) must be too.
    pub fn dropClientSlot(self: *Game, slot: usize, reason: []const u8) void {
        std.debug.print(
            "zdtd: player dropped slot={d} entity={d} reason={s}\n",
            .{ slot, self.clients[slot].entity_id, reason },
        );
        if (self.clients[slot].peer) |p| p.alive = false;
        // Free the seat a dropping rider held, or the vehicle stays occupied
        // (and, for seat 0, undriveable) for the rest of the session. Sim
        // detach still runs inside unseatRider even when the S2C attach encode
        // or broadcast fails; log the network side so other clients stuck
        // drawing a seated ghost are explainable.
        self.unseatRider(self.clients[slot].entity_id) catch |err| {
            std.debug.print(
                "zdtd: unseat on drop failed entity={d}: {s}\n",
                .{ self.clients[slot].entity_id, @errorName(err) },
            );
        };
        self.clearLocksForPeer(slot);
        // Offline claims start their expiry clock and lose the online HP bonus.
        self.markClaimsForEntity(self.clients[slot].entity_id, false);
        // Stock ServerHandleDisconnectParty (parties-factions.md §2.2): a
        // disconnect removes the player from any party and notifies the rest.
        if (self.parties.removePlayer(self.clients[slot].entity_id)) |r| {
            self.broadcastPartyRemoval(r, @intFromEnum(packages.stock_party.PartyActions.disconnected)) catch |err| {
                std.debug.print("zdtd: party disconnect broadcast failed: {s}\n", .{@errorName(err)});
            };
        }
        // Stock PartyQuests.RemovePlayerFromSharedWiths (parties-factions.md
        // §2.3): a disconnect drops the owner's shared quests; the party gets
        // remove_quest events so their mirrors clear.
        if (self.sim.playerByPeer(slot)) |ps| {
            if (self.sim.mask[ps].journal) {
                var rb: [16]u8 = undefined;
                for (self.sim.journal[ps].slots) |s| {
                    if (!s.active or !s.is_shared) continue;
                    var w = wire_binary.Writer{ .buf = &rb };
                    w.writeI32(self.clients[slot].entity_id) catch continue;
                    w.writeByte(@intFromEnum(packages.stock_quest.SharedQuestEvent.remove_quest)) catch continue;
                    w.writeI32(s.quest_code) catch continue;
                    const rbody = w.written();
                    for (&self.clients) |*cl| {
                        if (!cl.joined or cl.entity_id == self.clients[slot].entity_id) continue;
                        if (cl.peer) |mp| {
                            self.sendGame(mp, "NetPackageSharedQuest", rbody) catch {};
                        }
                    }
                }
            }
        }
        self.clients[slot] = .{};
        self.refreshInfoPlayers();
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
    pub fn takeInvToken(self: *Game, c: *Client) bool {
        const now = clock.monoNs();
        // A fresh bucket starts full (tokens default 0 on the struct so the
        // cap stays a config value; the first call seeds the configured cap).
        if (c.inv_refill_ns == 0) {
            c.inv_refill_ns = now;
            c.inv_tokens = self.inv_bucket_cap;
        }
        while (c.inv_tokens < self.inv_bucket_cap and now -% c.inv_refill_ns >= self.inv_refill_ns) {
            c.inv_tokens += 1;
            c.inv_refill_ns +%= self.inv_refill_ns;
        }
        if (c.inv_tokens == 0) return false;
        c.inv_tokens -= 1;
        return true;
    }

    pub fn takeBlockToken(self: *Game, c: *Client) bool {
        const now = clock.monoNs();
        if (c.block_refill_ns == 0) {
            c.block_refill_ns = now;
            c.block_tokens = self.block_bucket_cap;
        }
        while (c.block_tokens < self.block_bucket_cap and now -% c.block_refill_ns >= self.block_refill_ns) {
            c.block_tokens += 1;
            c.block_refill_ns +%= self.block_refill_ns;
        }
        if (c.block_tokens == 0) return false;
        c.block_tokens -= 1;
        return true;
    }

    /// Combat rate gate: allow burst of damage_burst_max within min_damage_gap.
    pub fn takeDamageToken(self: *Game, c: *Client) bool {
        const now = clock.monoNs();
        if (c.last_damage_ns != 0 and now -% c.last_damage_ns < self.min_damage_gap_ns) {
            if (c.damage_burst >= self.damage_burst_max) return false;
            c.damage_burst += 1;
        } else {
            c.damage_burst = 1;
        }
        c.last_damage_ns = now;
        return true;
    }

    /// Per-peer chat flood gate. Returns true and stamps `last_chat_ns` when allowed.
    pub fn acceptChatRate(self: *const Game, c: *Client) bool {
        const now = clock.monoNs();
        if (c.last_chat_ns != 0 and now -% c.last_chat_ns < self.min_chat_gap_ns) return false;
        c.last_chat_ns = now;
        return true;
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

    /// Align spawn to DTM height and ensure a solid under the feet block so
    /// dig/place sample rings (BlockUnderFeet) see terrain, not air.
    pub fn spawnSurface(self: *Game, sx: i32, sz: i32) struct { x: i32, y: i32, z: i32 } {
        const fallback: u16 = @intCast(@max(1, self.world.primarySpawn().y));
        const h_u16: u16 = self.world.heightWorld(sx, sz) catch fallback;
        const h: i32 = @intCast(h_u16);
        // heightWorld = top solid; PDF/entity feet use that block Y; entity float y = h+1.
        const feet_y = if (h > 1) h else 1;
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
            .day_light_length = @intFromFloat(clk.dusk - clk.dawn),
            .day_night_length = @intFromFloat(clk.seconds_per_hour * 24.0 / 60.0),
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
            .air_drop_frequency = self.air_drop_interval_hours,
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
    fn resolveSpawnClass(ctx: ?*anyopaque, class_name: []const u8) ?ecs.world.EntityClass {
        const self: *Game = @ptrCast(@alignCast(ctx.?));
        const d = self.entities.byName(class_name) orelse return null;
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
        };
    }

    fn pickEntityGroup(ctx: ?*anyopaque, group: []const u8, seed: u32) ?[]const u8 {
        const g: *Game = @ptrCast(@alignCast(ctx.?));
        return g.entitygroups.pick(group, seed);
    }

    /// Per-player biome spawn group (spawning.xml rule for the biome under the
    /// spawn point): night/day zombie or animal group NAME, or the fallback
    /// when the biome map, the biome name, or the biome's rule is unknown.
    /// Fixes the wasteland-at-midnight-getting-forest-walkers gap: stock
    /// resolves per ChunkAreaBiomeSpawnData from the actual biome.
    pub fn biomeGroupName(ctx: ?*anyopaque, x: f32, z: f32, kind: ecs.aidirector.Director.SpawnKind, fallback: []const u8) []const u8 {
        const self: *Game = @ptrCast(@alignCast(ctx.?));
        const bm = self.world.biomes orelse return fallback;
        const biome_id = bm.atWorld(@intFromFloat(@floor(x)), @intFromFloat(@floor(z))) orelse return fallback;
        const bname = self.world.biome_layers_table.nameById(biome_id) orelse return fallback;
        var buf: [16]assets_spawning.Rule = undefined;
        const n = self.spawning.rulesForBiome(bname, &buf);
        var ri: usize = 0;
        while (ri < n) : (ri += 1) {
            const r = buf[ri];
            switch (kind) {
                .night => if (r.kind == .zombie and r.time == .night) return r.entitygroup,
                .day => if (r.kind == .zombie and (r.time == .any or r.time == .day)) return r.entitygroup,
                .animal => if (r.kind == .animal) {
                    // Stock per biome: Any (day wildlife) plus Night (night
                    // wildlife incl. EnemyAnimals). Prefer the Night rule when
                    // it is dark so predators actually spawn.
                    const night = self.sim.director.clock.isNight();
                    if (r.time == .night) {
                        if (night) return r.entitygroup;
                    } else if (r.time == .any or r.time == .day) {
                        if (!night) return r.entitygroup;
                    }
                },
            }
        }
        return fallback;
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
    pub fn tryCraft(self: *Game, peer_slot: usize, recipe_index: u16, times: u16) bool {
        if (recipe_index >= self.recipes.defs.len) return false;
        return self.tryCraftRecipe(peer_slot, self.recipes.defs[recipe_index], times);
    }

    fn tryCraftRecipe(self: *Game, peer_slot: usize, recipe: assets_recipes.RecipeDef, times: u16) bool {
        const ps = self.sim.playerByPeer(peer_slot) orelse return false;
        if (!self.sim.mask[ps].inventory) return false;
        const n: u16 = if (times == 0) 1 else @min(times, self.craft_max_times);
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
        self.sim.markDirty(ps, .{ .inv = true });
        const p: u16 = if (peer_slot > std.math.maxInt(u16)) std.math.maxInt(u16) else @intCast(peer_slot);
        const d: i16 = @intCast(@min(out_count, std.math.maxInt(i16)));
        self.sim.inv_ledger.record(p, out_id, d, .craft);
        // Quest craft progress when objective matches recipe name.
        systems.questOnCraft(&self.sim, peer_slot, recipe.name);
        return true;
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

    fn tickTraderAreas(self: *Game) void {
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

    fn handItemDamage(self: *Game, hand_item: []const u8) f32 {
        if (hand_item.len == 0) return 0;
        if (self.items.byName(hand_item)) |d| return d.entity_damage;
        return 0;
    }

    /// One workstation step: burn/craft, then re-broadcast the stations it changed.
    pub fn tickWorkstations(self: *Game, dt: f32) !void {
        self.workstations.tickAllResolved(dt, resolveWorkstationOutput, self);
        // Heat map feed (AIDirectorChunkData): burning workstations with a
        // blocks.xml HeatMapStrength (forge 6, campfire 5, workbench 5, ...)
        // raise the region's activity like stock TileEntity.heatMapLastTime.
        for (self.workstations.items[0..], self.workstations.used[0..]) |*w, u| {
            if (!u or !w.is_burning) continue;
            const strength = self.blocks.heatStrength(@intCast(w.block_id));
            if (strength > 0) {
                self.sim.director.notifyActivity(@floatFromInt(w.x), @floatFromInt(w.z), strength, 720.0);
            }
        }
        try replicate_te.broadcastDirtyWorkstations(self);
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

    fn gatherPlayerPositions(
        self: *Game,
        px: *[max_clients]f32,
        py: *[max_clients]f32,
        pz: *[max_clients]f32,
    ) usize {
        return game_sleeper.gatherPlayerPositions(self, px, py, pz);
    }

    pub const SleeperScanCtx = game_sleeper.SleeperScanCtx;

    fn tickSleeperVolumes(self: *Game) void {
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

    /// GameStageDefinition::CalcGameStageAround radius (asm.il ~1093363).
    const sleeper_party_radius: f32 = 100.0;

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
        // Rebuild power nodes from this chunk's blocks (grid is runtime state).
        self.scanChunkPower(ch, cx, cz);
        // Prefer biomes.png color→id mode; fallback height band. Cached on the
        // chunk so re-sends to other clients skip the 256-lookup dominant scan.
        // Procedural worlds use the same biome field that drove the surface
        // fill, so the client's displayed biome matches the blocks (W3).
        const biome_id: u8 = ch.biome_id orelse blk: {
            const b: u8 = if (self.world.terrain_source == .proc)
                self.world.procBiomeAt(cx, cz)
            else if (self.world.biomes) |*bm|
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
            .water_block_id = self.world.terrain_ids.water,
            .raws_scratch = &self.chunk_raws,
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
    /// Rebuild power nodes from a chunk's blocks (GAP power persistence): the
    /// grid is runtime state (addNodeAt on place/remove), so after a restart
    /// each chunk re-derives its generators/consumers/wires from the block
    /// plane on first touch. `applyToNode` carries the per-block fuel/capacity
    /// properties; wires are re-added from the block plane the same way.
    pub fn scanChunkPower(self: *Game, ch: *world_store.Chunk, cx: i32, cz: i32) void {
        if (ch.power_scanned) return;
        const blocks = ch.blocks orelse return;
        ch.power_scanned = true;
        const base_x = cx * 16;
        const base_z = cz * 16;
        var last_id: u16 = 0;
        var last_power: ?ecs.powerblocks.Resolved = null;
        var y: i32 = 0;
        while (y < world_store.y_dim) : (y += 1) {
            var lz: i32 = 0;
            while (lz < 16) : (lz += 1) {
                var lx: i32 = 0;
                while (lx < 16) : (lx += 1) {
                    const id: u16 = @truncate(blocks[@intCast(lx + lz * 16 + y * 256)]);
                    if (id != last_id) {
                        last_id = id;
                        last_power = self.power_registry.lookup(id);
                    }
                    const pn = last_power orelse continue;
                    const wx = base_x + lx;
                    const wz = base_z + lz;
                    if (self.sim.power.addNodeAt(pn.kind, wx, y, wz, pn.watts)) |nid| {
                        if (self.sim.power.indexOfId(nid)) |ni| pn.applyToNode(&self.sim.power.nodes[ni]);
                    }
                }
            }
        }
        self.sim.power.resolve();
    }

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
                    // World container (not player-placed): eligible for loot respawn.
                    cont.player_storage = false;
                    if (cont.slots[0].count == 0 and cont.slots[1].count == 0) {
                        // Fail closed (audit A31): a storage block with no
                        // LootList stays empty instead of inventing woodenChest.
                        if (self.maxdamage.lootListFor(id)) |ll| {
                            self.fillContainerFromLoot(cont, ll, lootSeedAt(wx, y, wz));
                        }
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
                    const id: u16 = if (block_id != 0) block_id else replicate_te.seedChestBlockId(tc.g);
                    const cont = tc.g.containers.getOrCreate(pos, 8, id) orelse return;
                    // World container (prefab TE, not player-placed).
                    cont.player_storage = false;
                    if (cont.slots[0].count == 0 and cont.slots[1].count == 0) {
                        // Fail closed (audit A31): no LootList, no invented loot.
                        if (tc.g.maxdamage.lootListFor(id)) |ll| {
                            tc.g.fillContainerFromLoot(cont, ll, lootSeedAt(wx, wy, wz));
                        }
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
        // Stock LootContainer.size (loot.xml <lootcontainer size="x,y">) sizes
        // the storage grid; the client reads the cell count from the TE body,
        // so a gun safe (4x3) shows 12 cells instead of the flat 8. The size
        // derives per fill and the save round-trips slot_count, so a restored
        // container keeps its capacity and a re-rolled one re-derives it.
        if (self.loot.containerByName(loot_name)) |lc| {
            const want = @min(@as(usize, lc.size_x) * @as(usize, lc.size_y), containers_mod.max_container_slots);
            if (want >= 1) cont.slot_count = @intCast(want);
        }
        // Roll up to the container's own capacity (the roll is capped by the
        // buffer, so a bigger container actually fills more stacks).
        var stacks: [containers_mod.max_container_slots]assets_loot.Stack = undefined;
        const n = self.loot.rollContainer(loot_name, self.partyLootStage(), seed, stacks[0..cont.slot_count]);
        var si: usize = 0;
        var i: usize = 0;
        while (i < n and si < cont.slot_count) : (i += 1) {
            const eid = self.ecsIdFromItemName(stacks[i].item_name);
            if (eid == 0) continue;
            // The template rolls quality for every stack; only quality items
            // (stock ItemClass.HasQuality = tiered effect controller, which
            // zdtd approximates as stack==1; quality items never stack) carry
            // it, so stackables keep quality 1 and merge normally.
            const q = if (self.items.byId(eid)) |d|
                (if (d.stack == 1) stacks[i].quality else 1)
            else
                stacks[i].quality;
            cont.setSlot(si, .{ .item_id = eid, .count = stacks[i].count, .quality = q });
            si += 1;
        }
        // LootRespawnDays base: the day this loot was generated.
        cont.touched_day = self.sim.director.clock.day;
    }

    /// LootRespawnDays (stock TEFeatureStorage.UpdateTick): a looted world
    /// container re-rolls its contents when the interval since the touch day
    /// has elapsed. Player-placed storage never respawns. The next open
    /// regenerates fresh loot; the cycle-varying seed makes each respawn
    /// differ while staying deterministic per (pos, cycle). A block without a
    /// LootList stays empty (fail closed, audit A31), never woodenChest.
    pub fn maybeRespawnContainer(self: *Game, cont: *containers_mod.Container) void {
        if (self.loot_respawn_days == 0) return;
        if (cont.player_storage) return;
        if (!cont.touched) return;
        var empty = true;
        for (cont.slots[0..cont.slot_count]) |s| {
            if (s.count > 0 and s.item_id != 0) {
                empty = false;
                break;
            }
        }
        if (!empty) return;
        const day = self.sim.director.clock.day;
        if (day <= cont.touched_day) return;
        // Wrapping subtraction: a touched_day in the future (or pre-save 0 with
        // a day wrap) must not panic the tick; the <= guard above already
        // rejected the future case.
        const elapsed = day -% cont.touched_day;
        if (elapsed < self.loot_respawn_days) return;
        const id: u16 = @truncate(@as(u32, @bitCast(cont.block_id)));
        const cycle: u32 = day / self.loot_respawn_days;
        const pos = cont.pos;
        // Fail closed (audit A31): no LootList, the container stays empty.
        const ll = self.maxdamage.lootListFor(id) orelse return;
        self.fillContainerFromLoot(
            cont,
            ll,
            lootSeedAt(pos.x, pos.y, pos.z) +% cycle *% 2654435761,
        );
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
            try replicate_te.sendStorageTe(self, peer, cont.pos.x, cont.pos.y, cont.pos.z);
        }
        var vi: usize = 0;
        while (vi < vending_mod.max_vending) : (vi += 1) {
            if (!self.vending.used[vi]) continue;
            const v = &self.vending.items[vi];
            if (v.pos.x < x0 or v.pos.x >= x1 or v.pos.z < z0 or v.pos.z >= z1) continue;
            try replicate_te.sendVendingTe(self, peer, v.pos.x, v.pos.y, v.pos.z);
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

    pub fn sendSpawnArea(self: *Game, peer: *ln_peer.Peer, wx: i32, wz: i32, radius: i32) !void {
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
    pub fn streamChunksForClient(self: *Game, c: *Client) !void {
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
    /// Unreliable fan-out for the motion frames (PosAndRot / Speeds): fire and
    /// forget, never touches the reliable window. Oversized or failed sends are
    /// dropped (motion is replaced by the next tick's frame anyway).
    pub fn sendFramedUnreliable(self: *Game, peer: *ln_peer.Peer, framed: []const u8) void {
        return game_net.sendFramedUnreliable(self, peer, framed);
    }

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
        var i: ecs.Slot = 0;
        while (i < ecs.max_entities) : (i += 1) {
            if (!self.sim.alive[i] or !self.sim.mask[i].dirty or !self.sim.dirty[i].hp) continue;
            // Cleared even when nothing goes out (no observers, not a player):
            // stock clears Stat.Changed right after the poll, and a bit left set
            // would re-send the same value on every later tick.
            self.sim.dirty[i].hp = false;
            const is_player = self.sim.mask[i].player;
            const is_mob = self.sim.kind[i] == .zombie or self.sim.kind[i] == .animal;
            // Player vitals plus mob health (EntityStats::TickWait + SendStat
            // ChangePacket cover NPCs too; the corpse-dwell hp=0 must reach the
            // client so the death shows instead of a full-health body).
            if ((!is_player and !is_mob) or !self.sim.mask[i].health) continue;
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
                const owner = is_player and self.sim.player[i].peer_slot == @as(i32, @intCast(cl.slot));
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
    pub fn clientObserves(self: *const Game, cl: *const Client, wx: f32, wz: f32) bool {
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

    fn broadcastBuffExpiries(self: *Game, r: *const ecs.TickResult) !void {
        return game_social.broadcastBuffExpiries(self, r);
    }

    fn replicate(self: *Game) !void {
        return game_replicate.replicate(self);
    }

    pub fn clearDeadKnownEntities(self: *Game) void {
        return game_tick.clearDeadKnownEntities(self);
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
                    if (util_sim.isEnabled()) {
                        var seed_buf: [32]u8 = undefined;
                        std.debug.print("zdtd: net poll error: {s} ({s})\n", .{
                            @errorName(err),
                            util_sim.formatSeed(&seed_buf),
                        });
                    } else {
                        std.debug.print("zdtd: net poll error: {s}\n", .{@errorName(err)});
                    }
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
            self.sim.director.party_stage = self.partyHighestGameStage();
            const r = systems.tickAll(&self.sim, dt);
            self.harness.counters.add(.path_replans, r.path_replans);
            self.harness.counters.add(.path_replans_denied, r.path_replans_denied);
            // PlayerEntityStats survival loop after the world clock advanced.
            self.tickSurvival(dt);
            // A chewed-up eat distraction (EntityItem.OnUpdateEntity SetDead,
            // asm.il EntityItem:0100-0113) is removed like a collected drop:
            // EntityRemove(Despawned) so every observer drops the local item.
            {
                var bs: ecs.Slot = 0;
                while (bs < ecs.max_entities) : (bs += 1) {
                    if (!self.sim.alive[bs] or !self.sim.mask[bs].loot_bag) continue;
                    const b = self.sim.loot_bag[bs];
                    if ((b.distraction_tags & 1) == 0 or b.distraction_eat_ticks > 0) continue;
                    const lid = self.sim.network_id[bs].id;
                    if (packages.buildRemoveBodyReason(&self.body_buf, lid, .despawned)) |rm| {
                        self.broadcast("NetPackageEntityRemove", rm) catch {};
                    } else |_| {}
                    self.sim.destroy(bs);
                }
            }
            // Land-claim expiry on the in-game day roll (owner offline too long).
            if (self.claims_last_day != self.sim.director.clock.day) {
                self.claims_last_day = self.sim.director.clock.day;
                // Expired vending rentals return to unowned (loot-economy §6:
                // currentDay > rentalEndDay -> ClearVendingMachine).
                for (self.vending.items[0..], self.vending.used[0..]) |*v, u| {
                    if (!u) continue;
                    if (v.rental_end_day > 0 and self.sim.director.clock.day > v.rental_end_day) v.clear();
                }
                self.expireClaims();
            }
            // BloodMoonDay re-send on the day roll (GAP §6): a client that
            // joined mid-cycle keeps the stale red-moon HUD day otherwise.
            {
                const bm = bloodMoonDayFor(self.sim.director.clock);
                if (self.last_bm_day != bm) {
                    if (self.last_bm_day >= 0) self.broadcastGameStats() catch |err| {
                        self.harness.counters.inc(.net_send_errors);
                        std.debug.print("zdtd: broadcastGameStats failed: {s}\n", .{@errorName(err)});
                    };
                    self.last_bm_day = bm;
                }
            }
            if (self.terrain_snapshot_on) {
                const now = self.terrain_snap.misses.load(.monotonic);
                self.harness.counters.add(.terrain_snap_misses, now -| self.snap_misses_seen);
                self.snap_misses_seen = now;
            }
            // Prefab sleeper volumes (zdtd.toml [stream] sleeper_tick_ticks).
            if (self.tick_n % self.sleeper_tick_ticks == 0) self.tickSleeperVolumes();
            // Air drops + zombie block damage at the same cadence.
            if (self.tick_n % self.sleeper_tick_ticks == 0) {
                self.tickAirDrop();
                self.tickZombieBlockDamage();
            }
            // Workstation burn/craft; dirty stations re-broadcast state.
            if (self.tick_n % self.sleeper_tick_ticks == 0) {
                // dt follows the configured cadence (0.05 s per tick) so burn
                // speed stays wall-clock correct when sleeper_tick_ticks != 10.
                self.tickWorkstations(@as(f32, @floatFromInt(self.sleeper_tick_ticks)) * 0.05) catch |err| {
                    self.harness.counters.inc(.net_send_errors);
                    std.debug.print("zdtd: broadcastDirtyWorkstations failed: {s}\n", .{@errorName(err)});
                };
            }
            // Power fuel/SoC/timers every tick (props from blocks.xml via registry).
            const daylight = !self.sim.director.clock.isNight();
            _ = self.sim.power.tick(dt, daylight);
            replicate_te.broadcastPowerVisuals(self);
            self.reapStaleLocks();
            // Corpse dwell sweep (TimeStayAfterDeath): expired bodies get the
            // EntityRemove broadcast, so the client's ragdoll lasts its dwell.
            {
                var corpses: [16]ecs.entity.NetId = undefined;
                const nc = self.sim.sweepCorpses(dt, &corpses);
                var ci: usize = 0;
                while (ci < nc) : (ci += 1) {
                    const rm = packages.buildRemoveBody(&self.body_buf, corpses[ci]) catch continue;
                    self.broadcast("NetPackageEntityRemove", rm) catch continue;
                }
            }
            // Trader open/close cycle (edge-latched per trader).
            self.tickTraderAreas();
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
                    self.fillLootBagFromTable(lid, "", @bitCast(lid), self.partyLootStage());
                    try self.broadcastLootSpawn(lid);
                }
            }
            self.harness.counters.add(.entities_ticked, self.sim.countKind(.zombie));

            if (self.tick_n % self.world_time_send_ticks == 0) {
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
            if (self.tick_n % self.vehicle_pos_send_ticks == 0 and !self.loadShedding()) try self.broadcastVehiclePositions();
            if (self.tick_n % self.turret_sync_ticks == 0) try self.broadcastTurretSync();
            // Null on_tick hooks are a branch only (sample_hello is enable-only).
            self.plugins.onTick();
            // Wasm plugin hooks run late in the tick, after the sim settles;
            // their queued commands are drained by the next tick's schedule.
            self.wasm_plugins.onTick();
        }
        // Quest rewards payout at tick end: the sim credits the wallet coins on
        // completion and stashes the def; items and exp need the assets table
        // and the client xp ledger, so the Game drains here (one place covers
        // every completion site, C2S handlers and tickAll alike).
        {
            const cn = self.sim.completed_quests_n;
            var ci: usize = 0;
            while (ci < cn) : (ci += 1) {
                const cq = self.sim.completed_quests_ring[ci];
                if (cq.slot >= self.sim.player.len) continue;
                const peer: usize = @intCast(self.sim.player[cq.slot].peer_slot);
                if (peer >= self.clients.len) continue;
                const d = self.sim.catalog.byId(cq.def_id) orelse continue;
                // on_quest_complete verdict (T15): <0 withholds the payout,
                // >0 scales it (200 = double). 0 keeps today's behaviour. The
                // wallet coins were credited in the sim at completion; this
                // gates the item/exp half (and can be extended to coins when
                // the sim gains a verdict path of its own).
                const sv = self.plugins.questComplete(self.sim.network_id[cq.slot].id, cq.def_id);
                const v = if (sv != 0) sv else self.wasm_plugins.questComplete(self.sim.network_id[cq.slot].id, cq.def_id);
                if (v < 0) continue;
                const pct: u32 = if (v > 0) @intCast(v) else 100;
                var ri: usize = 0;
                while (ri < @min(@as(usize, d.reward_n), ecs.quest.max_reward_flags)) : (ri += 1) {
                    const spec = d.rewards[ri];
                    const scaled: u32 = @as(u32, spec.value) * pct / 100;
                    switch (spec.kind) {
                        .item, .loot_item => {
                            const eid = self.items.ecsIdByName(spec.item_name);
                            if (eid != 0) _ = invsys.give(&self.sim, peer, eid, @intCast(@min(scaled, 65535)));
                        },
                        .exp => self.awardXp(peer, scaled),
                        else => {},
                    }
                }
            }
            self.sim.completed_quests_n = 0;
        }

        try self.replicate();
        // Periodic world flush so dig/build survives crash without explicit admin save.
        if (self.tick_n % self.save_interval_ticks == 0) {
            const ss = apm.profiler.scope(&self.harness.prof, .save_io);
            defer ss.end();
            {
                // saveAll = encode (+ inline write when sync). Split out so the
                // async-flush decision has an encode-vs-write histogram.
                const es = apm.profiler.scope(&self.harness.prof, .save_encode);
                defer es.end();
                self.world.saveAll() catch |e| logPersistErr(self, "save world", e);
            }
            self.containers.save(self.world.world_dir, self.allocator) catch |e| logPersistErr(self, "save containers", e);
            self.vending.save(self.world.world_dir) catch |e| logPersistErr(self, "save vending", e);
            self.saveClaims() catch |e| logPersistErr(self, "save claims", e);
            self.saveEntities() catch |e| logPersistErr(self, "save entities", e);
            self.allies.save(self.world.world_dir, self.allocator) catch |e| logPersistErr(self, "save allies", e);
            self.saveBlockMeta() catch |e| logPersistErr(self, "save block meta", e);
            self.saveWeather() catch |e| logPersistErr(self, "save weather", e);
            self.saveClock() catch |e| logPersistErr(self, "save clock", e);
            if (self.players_dirty) {
                self.players_dirty = false;
                self.savePlayers() catch |e| logPersistErr(self, "save players", e);
            }
        }
        self.sampleFlushCounters();

        // One parseable line per minute gives unbounded production runs a
        // bounded-cost health signal without per-packet label cardinality.
        // Machine metrics go to stdout, human diagnostics to stderr: keeping
        // the JSONL on its own stream lets log scrapers (jq/fluentd) parse
        // every line instead of choking on interleaved `zdtd:` free text.
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
            if (report_ok) {
                // Per-minute cadence; not the tick hot path, so a transient
                // Io.Threaded init is fine (same pattern as main.printStdout).
                var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
                defer threaded.deinit();
                std.Io.File.stdout().writeStreamingAll(threaded.io(), report_writer.buffered()) catch |e| {
                    std.debug.print("zdtd: apm report write failed: {s}\n", .{@errorName(e)});
                };
            }
        }
        completed = true;
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
    fn broadcastWeather(self: *Game) !void {
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

    fn broadcastVehiclePositions(self: *Game) !void {
        try game_vehicle.broadcastVehiclePositions(self);
    }

    fn broadcastTurretSync(self: *Game) !void {
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

    /// Stock `NetPackagePartyActions.ProcessPackage` (parties-factions.md §2.2):
    /// the client never mutates the authoritative `Party`; each
    /// `currentOperation` selects a server handler, and every mutation fans a
    /// `NetPackagePartyData` snapshot out to the party-relevant peers. Entity
    /// ids are validated against live joined clients at the trust boundary.
    pub fn handlePartyActions(self: *Game, c: *Client, body: []const u8) !void {
        return game_social.handlePartyActions(self, c, body);
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
        return game_social.broadcastPartySnapshot(self, party_id, leader_index, voice, members, changed, action, disband);
    }

    fn broadcastPartyRemoval(self: *Game, r: ecs.party.Removal, action: u8) !void {
        return game_social.broadcastPartyRemoval(self, r, action);
    }

    pub fn clientByEntityId(self: *Game, entity_id: i32) ?*Client {
        return game_social.clientByEntityId(self, entity_id);
    }

    pub fn acceptQuestFor(self: *Game, c: *Client, def_id: u16) bool {
        return game_social.acceptQuestFor(self, c, def_id);
    }

    fn shareQuestWithParty(self: *Game, c: *Client, def_id: u16) void {
        return game_social.shareQuestWithParty(self, c, def_id);
    }

    pub fn handleAllyRequest(self: *Game, c: *Client, body: []const u8) !void {
        return game_social.handleAllyRequest(self, c, body);
    }
};
