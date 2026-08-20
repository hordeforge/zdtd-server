//! Game-owned types extracted from game.zig: InitOptions, defaults, LandClaim, Client.
//! Canonical definitions live here; game.zig re-exports them so existing
//! `game.X` call sites keep working. The two exceptions are noted inline: the
//! streamed-chunk cap comes from zdtd_config and the chat length from c2s_text,
//! because the module that enforces the limit owns the value.

const std = @import("std");
const ln_peer = @import("../../litenet/peer.zig");
const ecs = @import("../../ecs/root.zig");
const bot_mod = @import("bot.zig");
const guard_policy = @import("../guard_policy.zig");
const server_config = @import("../config.zig");
const zdtd_config = @import("../zdtd_config.zig");
const c2s_text = @import("../c2s_text.zig");
const movement = @import("../movement.zig");
const plugin_mod = @import("../../plugin/root.zig");
const packages = @import("../../wire/packages.zig");
const platform_user = packages.platform_user;

pub const AuthorityMode = server_config.AuthorityMode;

/// Game embeds the claim table on the heap; 1024 covers a long-lived server
/// (GAP 12: 256 silently dropped the 257th claim on register).
pub const max_land_claims: usize = 1024;

/// Default trader AvailableMoney display value. Stock AvailableMoney is a
/// per-day dukes pool that regenerates and is spent on player sells; zdtd has
/// no trader economy, so trade() credits the player wallet directly. Bucket B:
/// overridable via zdtd.toml [sim] trader_wallet_dukes (default matches the
/// prior fixed value).
pub const default_trader_wallet_dukes: i32 = 5000;

/// Per-chunk storage/prefab TE scan caps (zdtd.toml [sim] te_scan_*). Bucket B
/// engineering budgets: a 65536-cell block walk and the prefab TE list are
/// bounded so one chunk fill cannot stall the 50 ms tick.
pub const default_te_scan_block_cap: u32 = 32;
pub const default_te_scan_te_cap: u32 = 48;

/// Workstation craft budgets (zdtd.toml [sim] workstation_*). Bucket B
/// anti-abuse caps: a client TE write must not burst a whole queue or a huge
/// CraftingTimeLeft backlog in one tick.
pub const default_workstation_crafts_per_tick: u16 = 64;
pub const default_workstation_craft_backlog: f32 = 60;

/// Periodic apm snapshot dump period in ticks (zdtd.toml [apm] dump_every_s,
/// default 60 s at 20 TPS). Bucket B: docs/APM.md documents the dump.
pub const default_apm_report_period_ticks: u64 = @import("../../protocol.zig").ticks_per_second * 60;

// Compile-time array bound for Client.streamed. The cap is the config clamp
// (zdtd_config sanitizes max_streamed_chunks against it), so there is one
// definition and the bound cannot drift from what config accepts.
pub const max_streamed_chunks_cap: usize = zdtd_config.max_streamed_chunks_cap;

/// Default stream/authority values (also InitOptions / Game field defaults).
pub const default_max_streamed_chunks: usize = max_streamed_chunks_cap;
pub const default_chunk_stream_radius_min: i32 = 7;
pub const default_chunk_stream_radius_max: i32 = 9;
pub const default_chunk_adds_per_stream_tick: u32 = 8;

/// Decorations this client has received, tracked per 128-block deco chunk so a
/// streamed 16-block chunk ships its deco chunk's objects once (the client's
/// loadedDecos HashSet dedupes, but tracking avoids regenerating + resending
/// the same objects for each of the 64 member chunks).
pub const max_deco_chunks_cap: usize = 256;
pub const default_chunk_stream_period_ticks: u64 = 5;
pub const default_motion_replicate_period_ticks: u64 = 2;

/// WorldTime (and weather) broadcast cadence, and vehicle position cadence
/// (zdtd.toml [stream] world_time_send_ticks / vehicle_pos_send_ticks).
pub const default_world_time_send_ticks: u64 = 20;
pub const default_vehicle_pos_send_ticks: u64 = 5;
pub const default_sleeper_tick_ticks: u64 = 10;
pub const default_turret_sync_ticks: u64 = 10;
pub const default_save_interval_ticks: u64 = 100;
pub const default_spawn_area_radius_max: i32 = 8;
pub const default_max_claimed_damage: i32 = 200;
pub const default_max_edit_range: f32 = 96;
pub const default_interest_range: f32 = 160;

/// Movement anti-cheat envelope (zdtd.toml [authority] max_horizontal_speed_mps).
/// zdtd policy, not stock data: no serverconfig property covers it, and the
/// right cap depends on which vehicles/buffs a server runs.
pub const default_max_horizontal_speed_mps: f32 = movement.max_horizontal_speed_mps;

/// Max UTF-8 bytes in a player Global chat message. Canonical value lives with
/// the text trust boundary that enforces it (c2s_text).
pub const max_chat_msg_len: usize = c2s_text.max_chat_msg_len;

/// Anti-abuse rate limits (zdtd.toml [sim]): chat gap and inv/block token
/// bucket shape, plus the damage-accept gap and burst cap.
pub const default_min_chat_gap_ns: u64 = 200_000_000;
pub const default_inv_bucket_cap: u8 = 40;
pub const default_inv_refill_ns: u64 = 50_000_000; // +1 token / 50 ms
pub const default_block_bucket_cap: u8 = 30;
pub const default_block_refill_ns: u64 = 33_000_000; // +1 / ~33 ms
pub const default_min_damage_gap_ns: u64 = 80_000_000;
pub const default_damage_burst_max: u8 = 4;

/// Trader restock refill policy (zdtd.toml [sim] trader_restock_*): stackable
/// entries grow toward the cap by at most the refill per restock.
pub const default_trader_restock_cap: u16 = 50;
pub const default_trader_restock_refill: u16 = 10;

/// World::StormFrequency percent (stock GamePrefs.StormFreq default 100;
/// packages.GameStatsValues.storm_freq). 0 disables storms.
pub const default_storm_frequency: i32 = 100;
pub const default_peer_stale_ms: u64 = 3000;

/// Join rate-limit gap per IP (zdtd.toml [authority] join_rate_limit_ms).
/// Stock paces connection attempts at ~500 ms/IP (asm.il ConnectionManager
/// flood gate); loopback is exempt so bots/tests share 127.0.0.1.
pub const default_join_rate_limit_ms: u64 = 500;

/// Max craft batch a client can request in one InvTx craft (zdtd.toml
/// [sim] craft_max_times). Stock RecipeQueueItem multipliers are server
/// governed; 20 bounds a single burst.
pub const default_craft_max_times: u16 = 20;

/// Container lock auto-release after this many ns (zdtd.toml [authority] lock_stale_ms).
pub const default_lock_stale_ns: u64 = 120_000_000_000; // 120s
pub const default_deco_objects_per_join: usize = 8192;

/// Reliable-window retry pacing — see game_net.zig for the policy comment.
/// Kept here so InitOptions / Game defaults and the tuning docs cite one place.
pub const window_fast_attempts: u32 = 16;
pub const window_retry_sleep_ns: u64 = 1_000_000;
pub const window_retry_budget_ns: u64 = 16_000_000;
/// Bounded well under ADR 0012's 50ms tick budget headroom: sendGameCritical
/// runs on the single tick thread (join SM), so this is a worst-case
/// server-wide freeze, not just a slow join. Previously 3s (60 ticks) — a
/// stuck peer's join could stall every other player for seconds.
pub const critical_retry_budget_ns: u64 = 250_000_000;
pub const default_view_radius: i32 = 7;
pub const default_max_players: u16 = 8;

/// Scratch for serialize-once framed packets (PosAndRot ~40 B body + frame hdr).
pub const replicate_frame_cap: usize = 256;

/// Speeds body offset inside body_buf during zombie motion encode.
pub const speeds_body_off: usize = 64;

/// AliveFlags body offset (after speeds).
pub const flags_body_off: usize = 96;

pub const LandClaim = struct {
    x: i32,
    y: i32,
    z: i32,
    owner_entity: i32,
    owner_online: bool = true,
    /// In-game day the owner was last seen online (expiry base when offline).
    owner_seen_day: u32 = 0,
    /// Stable owner key for persistence: the login name (entity ids are
    /// reassigned across restarts). Empty when the claim predates the field.
    owner_name: [32]u8 = .{0} ** 32,
    owner_name_len: u8 = 0,
};

pub const InitOptions = struct {
    map_dir: ?[]const u8 = null,
    game_dir: ?[]const u8 = null,
    config_dir: ?[]const u8 = null,
    /// Xpath patch dirs (filename order). Applied after base Data/Config load.
    config_overrides: []const []const u8 = &.{},
    quests_path: ?[]const u8 = null,
    /// `[quests]` policy (ADR 0021): objective-kind spec + kill-count / goto /
    /// stay defaults, merged from mode pack < zdtd.toml by main.zig. Loaded
    /// into the quest catalog at init; `{}` = builtin stock values.
    quest_policy: @import("../../ecs/quest.zig").QuestPolicy = .{},
    /// `[bots]` host policy (ADR 0026), merged from mode pack < zdtd.toml;
    /// `{}` = historic defaults.
    bot_config: @import("bot.zig").BotHostConfig = .{},
    view_radius: i32 = default_view_radius,
    admin_port: u16 = 0,
    /// TelnetPassword. Empty keeps the console on loopback with no login prompt;
    /// non-empty enables the stock login and the INADDR_ANY bind.
    telnet_password: []const u8 = "",
    telnet_failed_login_limit: u8 = 10,
    /// TelnetFailedLoginsBlocktime (minutes). 0 = close session only, no lockout window.
    telnet_failed_logins_blocktime: u16 = 10,
    /// GameWorld, shown in the telnet greeting block.
    game_world: []const u8 = "Navezgane",
    /// Stock sandbox code echoed into GameStats(71) so clients decode the
    /// server's sandbox gates (TemperatureSurvival, StormFreq, ...) instead of
    /// their own defaults (RE sandbox-options §8). Empty = client default.
    sandbox_code: []const u8 = "",
    sandbox_preset: []const u8 = "",
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
    land_claim_expiry_days: u16 = 3,
    loot_respawn_days: u16 = 7,
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
    world_time_send_ticks: u64 = default_world_time_send_ticks,
    vehicle_pos_send_ticks: u64 = default_vehicle_pos_send_ticks,
    /// 2 Hz class of sim side-work (zdtd.toml [stream] sleeper_tick_ticks):
    /// prefab sleeper volumes, airdrops + zombie block damage, workstations.
    sleeper_tick_ticks: u64 = default_sleeper_tick_ticks,
    /// Turret state broadcast cadence (zdtd.toml [stream] turret_sync_ticks).
    turret_sync_ticks: u64 = default_turret_sync_ticks,
    /// Periodic world flush so dig/build survives a crash (zdtd.toml
    /// [stream] save_interval_ticks).
    save_interval_ticks: u64 = default_save_interval_ticks,
    spawn_area_radius_max: i32 = default_spawn_area_radius_max,
    max_claimed_damage: i32 = default_max_claimed_damage,
    max_edit_range: f32 = default_max_edit_range,
    interest_range: f32 = default_interest_range,
    /// Movement envelope cap (zdtd.toml [authority] max_horizontal_speed_mps).
    max_horizontal_speed_mps: f32 = default_max_horizontal_speed_mps,
    peer_stale_ms: u64 = default_peer_stale_ms,
    /// Container lock auto-release (zdtd.toml [authority] lock_stale_ms).
    lock_stale_ns: u64 = default_lock_stale_ns,
    /// Join rate-limit gap per IP (zdtd.toml [authority] join_rate_limit_ms).
    join_rate_limit_ms: u64 = default_join_rate_limit_ms,
    /// Max craft batch per InvTx request (zdtd.toml [sim] craft_max_times).
    craft_max_times: u16 = default_craft_max_times,
    /// Sleeper wake/stage radius in m (zdtd.toml [sim] sleeper_party_radius).
    sleeper_party_radius: f32 = 100.0,
    /// Anti-abuse rate limits (zdtd.toml [sim]): chat gap and inv/block token
    /// bucket shape, plus the damage-accept gap and burst cap.
    min_chat_gap_ns: u64 = default_min_chat_gap_ns,
    inv_bucket_cap: u8 = default_inv_bucket_cap,
    inv_refill_ns: u64 = default_inv_refill_ns,
    block_bucket_cap: u8 = default_block_bucket_cap,
    block_refill_ns: u64 = default_block_refill_ns,
    min_damage_gap_ns: u64 = default_min_damage_gap_ns,
    damage_burst_max: u8 = default_damage_burst_max,
    /// Trader restock refill policy (zdtd.toml [sim] trader_restock_*).
    trader_restock_cap: u16 = default_trader_restock_cap,
    trader_restock_refill: u16 = default_trader_restock_refill,
    /// Storm frequency percent (zdtd.toml [sim] storm_frequency): the
    /// GameStats wire value and the weather scheduler divisor. Stock default
    /// 100 (GamePrefs.StormFreq); 0 disables storms.
    storm_frequency: i32 = default_storm_frequency,
    /// Per-chunk storage/prefab TE scan caps (zdtd.toml [sim] te_scan_*).
    te_scan_block_cap: u32 = default_te_scan_block_cap,
    te_scan_te_cap: u32 = default_te_scan_te_cap,
    /// Workstation craft budgets (zdtd.toml [sim] workstation_*).
    workstation_crafts_per_tick: u16 = default_workstation_crafts_per_tick,
    workstation_craft_backlog: f32 = default_workstation_craft_backlog,
    /// Periodic apm snapshot dump period in seconds (zdtd.toml [apm]
    /// dump_every_s; null = the 60 s default). Converted to ticks at create.
    apm_dump_every_s: ?u64 = null,
    /// Trader AvailableMoney display pool (zdtd.toml [sim] trader_wallet_dukes).
    trader_wallet_dukes: i32 = default_trader_wallet_dukes,
    /// Sim rule parameters (ADR 0021): the effective Rules after the
    /// mode pack and zdtd.toml overlays (main.zig builds it). Installed on
    /// World.rules at init; the sim reads w.rules.<group>.<field>.
    rules: ecs.rules.Rules = .{},
    /// Register in-tree sample_hello static plugin (logs once on enable).
    enable_sample_plugin: bool = true,
    /// .wasm modules loaded by the Wasm plugin runtime (zdtd.toml [plugin]
    /// modules; ADR 0020). Empty = no Wasm plugins.
    plugin_modules: []const []const u8 = &.{},
    /// Per-instance budget for Wasm plugins (fuel + max linear-memory pages;
    /// fuel is lifetime, never re-armed).
    plugin_budget: plugin_mod.wasm.Budget = .{},

    deco_objects_per_join: usize = default_deco_objects_per_join,

    // [perf] switches (zdtd.toml). All default off; each is gated on apm
    // evidence from the always-on sections/counters that ship with them.
    /// Write chunk saves from a background thread (encode stays on the tick).
    async_chunk_flush: bool = false,
    /// Per-tick read-only terrain blocked snapshot for the A* inner loop.
    terrain_snapshot: bool = false,
    /// Run the sleeper-volume player test as a parallel job batch.
    job_batches: bool = false,
};

pub const Client = struct {
    peer: ?*ln_peer.Peer = null,
    entity_id: i32 = -1,
    /// Server-side XP ledger (XPMultiplier applied on award).
    xp: u64 = 0,
    /// Player level derived from progression curve (1-based).
    level: u16 = 1,
    /// Zombie kills this session, for the AddScoreClient character-sheet
    /// counter (stock EntityAlive.AddScore on kill).
    zombie_kills: u16 = 0,
    /// Seconds spent with the head block underwater, for the drowning damage
    /// accumulator (damage ticks once per second while submerged).
    drown_accum: f32 = 0,
    /// Seconds spent inside a radiated biome (damage ticks once per second).
    radiation_accum: f32 = 0,
    /// Respawn bed: the last bedroll this player placed (stock bedroll =
    /// respawn point). 0 = none; the death screen lists it and respawn uses it.
    bed_x: i32 = 0,
    bed_y: i32 = 0,
    bed_z: i32 = 0,
    has_bed: bool = false,
    /// Player kills this session (PvP, PlayerKillingMode != 0).
    player_kills: u16 = 0,
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
    /// Deco chunks (packed makeChunkKey of the 128-grid) already sent (join
    /// burst + streamed chunks); full = stop tracking (the client dedupes).
    deco_sent: [max_deco_chunks_cap]i64 = undefined,
    deco_sent_n: usize = 0,
    /// Entity slots this client has received an ECD EntitySpawn for
    /// (spawn-on-approach; cleared when the entity dies or slot recycles).
    known_entities: std.StaticBitSet(ecs.max_entities) = std.StaticBitSet(ecs.max_entities).initEmpty(),
    /// Host-side bot slots this client has received an EntitySpawn for. Bots
    /// are not ECS entities, so they are tracked separately (bit index = bot
    /// slot) and cleaned by the non-ECS bot replication path, never by the ECS
    /// dead-entity reconcile in tick.clearDeadKnownEntities.
    known_bots: std.StaticBitSet(bot_mod.max_bots) = std.StaticBitSet(bot_mod.max_bots).initEmpty(),
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
    /// Survival S2C throttle (tickSurvival): seconds until the next
    /// sendSurvivalStats for this client.
    survival_sync_cd: f32 = 0,
    /// Last reported sprint speed (NetPackageEntitySpeeds MovementState 3);
    /// lapses after sprint_stale_seconds without an update. Drives stamina
    /// drain (UpdatePlayerStaminaOT).
    sprint_speed: f32 = 0,
    sprint_stale_cd: f32 = 0,
    /// Cost-class token buckets (refill on accept path).
    inv_tokens: u8 = 0,
    inv_refill_ns: u64 = 0,
    block_tokens: u8 = 0,
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
