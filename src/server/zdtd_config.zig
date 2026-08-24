//! zdtd.toml: operator tunables (Bucket B), not stock serverconfig.
//! Precedence (applied by caller): CLI > env (webui secret) > world/zdtd.toml >
//! CWD zdtd.toml > --serverconfig keys > code defaults.
//! Minimal TOML subset: [section] + key = int|float|bool|string. No arrays/tables-in-tables.
//! Parsing is the comptime binder (src/util/toml_bind.zig, ADR 0021 decision 1);
//! this file declares the shape and the merge/sanitize behaviour.
//! Design: docs/reviews/HARDCODE_AUDIT.md, docs/adr/0010-data-config-zig-plugins.md

const std = @import("std");
const io_fs = @import("../util/io_fs.zig");
const util_log = @import("../util/log.zig");
const guard_policy = @import("guard_policy.zig");
const toml_bind = @import("../util/toml_bind.zig");
const rules_mod = @import("../ecs/rules.zig");

pub const Stream = struct {
    max_streamed_chunks: ?usize = null,
    chunk_adds_per_stream_tick: ?u32 = null,
    stream_radius_min: ?i32 = null,
    stream_radius_max: ?i32 = null,
    chunk_stream_period_ticks: ?u64 = null,
    motion_replicate_period_ticks: ?u64 = null,
    /// WorldTime broadcast cadence (game.zig default_world_time_send_ticks).
    world_time_send_ticks: ?u64 = null,
    /// Vehicle position broadcast cadence (game.zig default_vehicle_pos_send_ticks).
    vehicle_pos_send_ticks: ?u64 = null,
    spawn_area_radius_max: ?i32 = null,
    /// 2 Hz sim side-work cadence (sleeper volumes, airdrops, workstations).
    sleeper_tick_ticks: ?u64 = null,
    /// Turret state broadcast cadence.
    turret_sync_ticks: ?u64 = null,
    /// Periodic world flush cadence (crash-survival save).
    save_interval_ticks: ?u64 = null,
};

pub const Authority = struct {
    interest_range_blocks: ?f32 = null,
    max_edit_range_blocks: ?f32 = null,
    /// Movement anti-cheat envelope: max accepted horizontal speed in m/s.
    max_horizontal_speed_mps: ?f32 = null,
    max_claimed_damage: ?i32 = null,
    peer_stale_ms: ?u64 = null,
    lock_stale_ms: ?u64 = null,
    join_rate_limit_ms: ?u64 = null,
    mode: ?[]const u8 = null,
    /// P4 guard policy (src/server/guard_policy.zig). Defaults are log-only:
    /// enforce/quarantine off, dry_run on. See docs/AUTHORITY.md.
    guard_enforce: ?bool = null,
    guard_dry_run: ?bool = null,
    guard_quarantine: ?bool = null,
    guard_load_shed: ?bool = null,
    guard_window_ticks: ?u64 = null,
    guard_strong_distinct: ?u32 = null,
    guard_hard_repeat: ?u32 = null,
    /// Policy kick delay (ticks between the deny send and the peer drop; stock
    /// disconnectLater(0.5f) = 10 at 20 TPS), load-shed hold (ticks the valve
    /// stays open after an overrun) and the weak farming signal threshold
    /// (block destroys per window).
    guard_kick_delay_ticks: ?u64 = null,
    guard_shed_hold_ticks: ?u64 = null,
    guard_weak_break_rate: ?u32 = null,
};

pub const Feature = struct {
    wire_chunks: ?bool = null,
    /// Join-time deco tree objects. Off falls back to the empty firstPackage
    /// (bald world) for clients whose block AssignIds differ from our dump.
    deco_trees: ?bool = null,
    /// Write the join deco burst into the server block store. Off leaves deco
    /// render-only, so server collision and harvest do not see the trees.
    deco_mirror: ?bool = null,
    /// Send the full "blocks" NameIdMapping before the config files. Off falls
    /// back to the client assigning block ids from its own local blocks.xml.
    block_id_mapping: ?bool = null,
    deco_objects_per_join: ?usize = null,
};

/// Performance switches (docs/SCALE.md). All default off: each one
/// trades a documented behaviour property (write timing, lock removal, worker
/// fan-out) and is gated until apm shows the cost it removes.
pub const Perf = struct {
    /// Hand chunk writes to a background writer thread (encode stays on tick).
    async_chunk_flush: ?bool = null,
    /// Per-tick read-only terrain blocked snapshot for the A* inner loop.
    terrain_snapshot: ?bool = null,
    /// Run the sleeper-volume player test as a parallel job batch.
    job_batches: ?bool = null,
};

/// Sim policy that is not stock serverconfig and not stock game data.
pub const Sim = struct {
    /// Trader AvailableMoney display pool (no stock key: stock Traders.xml has
    /// no wallet property; AvailableMoney is engine-managed per-day).
    trader_wallet_dukes: ?i32 = null,
    /// Anti-abuse rate limits (per-peer flood gates). Mono-ns values; token
    /// buckets shape the inv/block accept path, gaps pace chat and damage.
    min_chat_gap_ns: ?u64 = null,
    inv_bucket_cap: ?u8 = null,
    inv_refill_ns: ?u64 = null,
    block_bucket_cap: ?u8 = null,
    block_refill_ns: ?u64 = null,
    min_damage_gap_ns: ?u64 = null,
    damage_burst_max: ?u8 = null,
    /// Trader restock refill policy: stackable entries grow toward the cap by
    /// at most the refill each restock.
    trader_restock_cap: ?u16 = null,
    trader_restock_refill: ?u16 = null,
    /// Max craft batch per InvTx request.
    craft_max_times: ?u16 = null,
    /// Sleeper wake/stage radius (m): the `CalcGameStageAround` radius used to
    /// stage sleeper-volume spawns (asm.il ~1093363). Stock uses the volume
    /// box + party stage; zdtd's fixed-radius approximation is this knob.
    sleeper_party_radius: ?f32 = null,
    /// Storm frequency percent (World::StormFrequency, stock GamePrefs default
    /// 100 = 1.0x; 0 disables storms). No V3.1.0 serverconfig key (world state,
    /// GameStats blob); this is the zdtd.toml surface.
    storm_frequency: ?i32 = null,
    /// Per-chunk storage/prefab TE scan caps (block-store walk + prefab TE
    /// list). Engineering budgets: bound one peer's chunk fill so a single
    /// chunk cannot stall the tick.
    te_scan_block_cap: ?u32 = null,
    te_scan_te_cap: ?u32 = null,
    /// Trader/vending open-and-echo reach gate (blocks). Authority-adjacent:
    /// closes the "rewrite a trader from anywhere" vector (trader_wire.zig).
    trader_use_range: ?f32 = null,
    /// Party shared-kill XP credit range (blocks). No V3.1.0 serverconfig key
    /// (GameStats[54] default 100); same precedent as trader_wallet_dukes.
    party_shared_kill_range: ?f32 = null,
    /// Storms are pushed this many world ticks past a horde night
    /// (weather.zig blood_moon_storm_push; 5000 = ~5 in-game hours).
    storm_bm_push_ticks: ?i64 = null,
    /// Workstation craft budgets (zdtd.toml [sim]): max crafts advanced per
    /// tick per station and the largest client-written CraftingTimeLeft backlog
    /// (seconds) accepted before it is reset. Anti-abuse caps.
    workstation_crafts_per_tick: ?u16 = null,
    workstation_craft_backlog: ?f32 = null,
    /// Restore the stock sleeper global spawn gate: when true, a sleeper
    /// volume only restores while EnemyCount < MaxSpawnedZombies * 2.1 (stock
    /// CanSpawn(2.1f), spawning.md). Default false = the documented zdtd
    /// divergence (spawn regardless of the global cap).
    sleeper_cap_gate_enabled: ?bool = null,
    /// Airdrop policy (`[sim] airdrop_*`; the stock server has no key for
    /// these — AirDropFrequency is the interval). `airdrop_schedule` is
    /// "interval" (default: every `AirDropFrequency` game-hours, the
    /// pre-config behavior) or "days" (stock-like day-count + TOD: every
    /// `airdrop_day_min..airdrop_day_max` days at `airdrop_drop_hour`).
    /// `airdrop_loot_list` is the loot.xml container for the crate.
    airdrop_schedule: ?[]const u8 = null,
    airdrop_day_min: ?u32 = null,
    airdrop_day_max: ?u32 = null,
    airdrop_drop_hour: ?u32 = null,
    airdrop_loot_list: ?[]const u8 = null,
};

/// `[apm]` config section: operator-facing metrics cadence (docs/APM.md).
pub const Apm = struct {
    /// Periodic apm snapshot dump period, in seconds (0 disables the periodic
    /// dump). Default 60 matches the pre-config `apm_report_period_ticks`.
    dump_every_s: ?u64 = null,
};

/// Select a gamemode pack under modes/<name>.toml (ADR 0010). Not the pack body.
pub const Mode = struct {
    name: ?[]const u8 = null,
};

/// Wasm plugin runtime (ADR 0020). `modules` is a comma-separated list of
/// .wasm file paths; main.zig splits it into InitOptions.plugin_modules.
pub const Plugin = struct {
    modules: ?[]const u8 = null,
    /// Wasm fuel budget per module instance (default 100_000_000). The fuel
    /// is armed once at instantiate and never re-armed, so a module that
    /// spends ~10k fuel per tick silently disables after minutes; raise this
    /// for heavier hooks or lower it to bound a hostile guest.
    fuel: ?u64 = null,
    /// Max linear-memory pages per module instance (default 1024).
    max_pages: ?u64 = null,
};

/// `[mods]` config section (PRD 0005): module tiers and override.
/// `disabled` and `blacklist` are comma-separated mod-name lists (manifest
/// name or mods/ dir name), like `[plugin] modules`. The comptime binder
/// handles scalars only, so lists ride as strings; main.zig splits them.
pub const Mods = struct {
    /// Skip loading these discovered mods (one info log per mod).
    disabled: ?[]const u8 = null,
    /// Refuse these mods: never loaded, and any mod overriding or requiring
    /// a blacklisted name is a load failure. Naming a core component here is
    /// a config error.
    blacklist: ?[]const u8 = null,
};

/// Authority.mode is a constrained string: observe | permissive | correct.
/// The binder validates it by name and canonicalises the spelling.
pub const AuthorityModeName = enum {
    observe,
    permissive,
    correct,
};

/// `[quests]` config section (binder-native scalar fields only). The
/// objective-type mapping rides as a comma-separated `Type=PhaseKind` string
/// because the binder is scalar-only; assets/quests.zig parses it. Optional
/// numerics so main.zig can merge mode pack < zdtd.toml per field.
pub const Quests = struct {
    objective_kinds: []const u8 = "",
    default_kill_count: ?u8 = null,
    kill_per_tier: ?u8 = null,
    goto_radius: ?f32 = null,
    stay_radius: ?f32 = null,
    /// POI selection distance band (blocks) for random-POI-goto objectives and
    /// the max candidates/attempts searched (RE ObjectiveRandomPOIGoto).
    poi_min_dist: ?f32 = null,
    poi_max_dist: ?f32 = null,
    max_poi_attempts: ?u32 = null,
    /// Quest-POI bed lockout radius (blocks): a respawn bed within this of the
    /// POI center counts as inside the footprint (hooks.zig homeLockout).
    poi_bed_lockout_radius: ?f32 = null,
    /// GetRandomPOINearTrader distance bands (blocks): band 0 = within
    /// `trader_band_1`, band 1 = within `trader_band_2`, else band 2.
    trader_band_1: ?f32 = null,
    trader_band_2: ?f32 = null,
};

/// `[bots]` config section: host-side FPS bot policy (ADR 0026 / ADR 0021).
/// Binder-scalar optional fields; main.zig merges mode pack < zdtd.toml into
/// the BotManager's BotHostConfig.
pub const Bots = struct {
    shoot_damage: ?f32 = null,
    headshot_multiplier: ?f32 = null,
    spawn_spread: ?f32 = null,
    spawn_y: ?f32 = null,
    max_step_up: ?f32 = null,
    arrival_dist: ?f32 = null,
    shot_range_slop: ?f32 = null,
    /// Host loadout pool as `tag:damage:range:pellets,tag:...` (up to 8 guns;
    /// empty = the builtin pool). Binder string (table shape), like
    /// `[quests] objective_kinds`.
    weapon_profiles: []const u8 = "",
};

pub const File = struct {
    pub const toml_label = "zdtd.toml";
    /// Accepted alternate spellings (kept from the pre-binder chains).
    pub const aliases = .{
        .stream = [_][2][]const u8{
            .{ "chunk_stream_radius_min", "stream_radius_min" },
            .{ "chunk_stream_radius_max", "stream_radius_max" },
        },
        .authority = [_][2][]const u8{
            .{ "interest_range", "interest_range_blocks" },
            .{ "max_edit_range", "max_edit_range_blocks" },
        },
    };
    pub const enum_by_name = .{ .mode = AuthorityModeName };

    stream: Stream = .{},
    authority: Authority = .{},
    feature: Feature = .{},
    perf: Perf = .{},
    sim: Sim = .{},
    mode: Mode = .{},
    plugin: Plugin = .{},
    /// Mod tiers and override (PRD 0005).
    mods: Mods = .{},
    /// Quest data policy: the objective `type=` -> phase-kind mapping is
    /// config, not code (ADR 0021) — a new stock objective type is a row here,
    /// `"Type=PhaseKind, ..."` (see assets/quests.zig parseObjectiveKinds).
    quests: Quests = .{},
    /// Host-side bot policy (ADR 0026): damage floor, headshot multiplier,
    /// spawn spread/y and the move step-up cap.
    bots: Bots = .{},
    /// Operator metrics cadence (docs/APM.md): `[apm] dump_every_s`.
    apm: Apm = .{},
    /// Sim rule overlay (ADR 0021): `[rules.combat]` etc. bound here, merged
    /// over the mode pack by main.zig so zdtd.toml wins the precedence order.
    rules: rules_mod.RulesOverlay = .{},
    /// Arena owning any string slices from parse.
    arena_ptr: ?*std.heap.ArenaAllocator = null,

    pub fn deinit(self: *File) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
    }
};

/// Max size for operator zdtd.toml (keeps mispointed paths from loading multi-MB files).
const max_toml_bytes: usize = 256 * 1024;

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !File {
    const read_buf = try allocator.alloc(u8, max_toml_bytes + 1);
    defer allocator.free(read_buf);
    const data = try io_fs.readFileInto(path, read_buf);
    if (data.len > max_toml_bytes) return error.TomlTooLarge;
    return try parse(allocator, data);
}

pub fn parse(allocator: std.mem.Allocator, src: []const u8) !File {
    var arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var f: File = .{ .arena_ptr = arena };
    toml_bind.bind(File, &f, src, a) catch |err| switch (err) {
        // The binder's enum-name error surfaces as the pre-binder contract for
        // an invalid [authority] mode.
        error.InvalidTomlEnum => return error.InvalidAuthorityMode,
        else => return err,
    };
    return f;
}

/// Merge File into InitOptions-like fields. Only non-null keys override.
/// Does not apply authority.mode (caller parses with AuthorityMode); does not
/// apply `rules` (main.zig merges it over the mode pack in precedence order).
pub fn applyToInitOptions(f: *const File, opts: anytype) void {
    if (f.stream.max_streamed_chunks) |v| opts.max_streamed_chunks = v;
    if (f.stream.chunk_adds_per_stream_tick) |v| opts.chunk_adds_per_stream_tick = v;
    if (f.stream.stream_radius_min) |v| opts.chunk_stream_radius_min = v;
    if (f.stream.stream_radius_max) |v| opts.chunk_stream_radius_max = v;
    if (f.stream.chunk_stream_period_ticks) |v| opts.chunk_stream_period_ticks = v;
    if (f.stream.motion_replicate_period_ticks) |v| opts.motion_replicate_period_ticks = v;
    if (f.stream.world_time_send_ticks) |v| opts.world_time_send_ticks = v;
    if (f.stream.vehicle_pos_send_ticks) |v| opts.vehicle_pos_send_ticks = v;
    if (f.stream.spawn_area_radius_max) |v| opts.spawn_area_radius_max = v;
    if (f.stream.sleeper_tick_ticks) |v| opts.sleeper_tick_ticks = v;
    if (f.stream.turret_sync_ticks) |v| opts.turret_sync_ticks = v;
    if (f.stream.save_interval_ticks) |v| opts.save_interval_ticks = v;
    if (f.authority.interest_range_blocks) |v| opts.interest_range = v;
    if (f.authority.max_edit_range_blocks) |v| opts.max_edit_range = v;
    if (f.authority.max_horizontal_speed_mps) |v| {
        if (@hasField(@TypeOf(opts.*), "max_horizontal_speed_mps")) opts.max_horizontal_speed_mps = v;
    }
    if (f.authority.max_claimed_damage) |v| opts.max_claimed_damage = v;
    if (f.authority.peer_stale_ms) |v| opts.peer_stale_ms = v;
    if (f.authority.lock_stale_ms) |v| {
        if (@hasField(@TypeOf(opts.*), "lock_stale_ns")) opts.lock_stale_ns = v *| 1_000_000;
    }
    if (f.authority.join_rate_limit_ms) |v| {
        if (@hasField(@TypeOf(opts.*), "join_rate_limit_ms")) opts.join_rate_limit_ms = v;
    }
    if (f.sim.craft_max_times) |v| {
        if (@hasField(@TypeOf(opts.*), "craft_max_times")) opts.craft_max_times = v;
    }
    if (f.authority.guard_enforce) |v| opts.guard.enforce = v;
    if (f.authority.guard_dry_run) |v| opts.guard.dry_run = v;
    if (f.authority.guard_quarantine) |v| opts.guard.quarantine = v;
    if (f.authority.guard_load_shed) |v| opts.guard.load_shed = v;
    if (f.authority.guard_window_ticks) |v| opts.guard.window_ticks = v;
    // Saturate the width here; guard.clamp() logs and repairs the range.
    if (f.authority.guard_strong_distinct) |v|
        opts.guard.strong_distinct = @intCast(@min(v, @as(u32, std.math.maxInt(u8))));
    if (f.authority.guard_hard_repeat) |v|
        opts.guard.hard_repeat = @intCast(@min(v, @as(u32, std.math.maxInt(u16))));
    if (f.authority.guard_kick_delay_ticks) |v| opts.guard.kick_delay_ticks = v;
    if (f.authority.guard_shed_hold_ticks) |v| opts.guard.shed_hold_ticks = v;
    if (f.authority.guard_weak_break_rate) |v|
        opts.guard.weak_break_rate_per_window = @intCast(@min(v, @as(u32, std.math.maxInt(u16))));
    if (f.feature.wire_chunks) |v| opts.wire_chunks = v;
    if (f.feature.deco_trees) |v| opts.deco_trees = v;
    if (f.feature.deco_mirror) |v| opts.deco_mirror = v;
    if (f.feature.block_id_mapping) |v| opts.block_id_mapping = v;
    if (f.feature.deco_objects_per_join) |v| {
        if (@hasField(@TypeOf(opts.*), "deco_objects_per_join")) opts.deco_objects_per_join = v;
    }
    if (f.perf.async_chunk_flush) |v| opts.async_chunk_flush = v;
    if (f.perf.terrain_snapshot) |v| opts.terrain_snapshot = v;
    if (f.perf.job_batches) |v| opts.job_batches = v;
    if (f.sim.trader_wallet_dukes) |v| opts.trader_wallet_dukes = v;
    if (f.sim.min_chat_gap_ns) |v| opts.min_chat_gap_ns = v;
    if (f.sim.inv_bucket_cap) |v| opts.inv_bucket_cap = v;
    if (f.sim.inv_refill_ns) |v| opts.inv_refill_ns = v;
    if (f.sim.block_bucket_cap) |v| opts.block_bucket_cap = v;
    if (f.sim.block_refill_ns) |v| opts.block_refill_ns = v;
    if (f.sim.min_damage_gap_ns) |v| opts.min_damage_gap_ns = v;
    if (f.sim.damage_burst_max) |v| opts.damage_burst_max = v;
    if (f.sim.trader_restock_cap) |v| opts.trader_restock_cap = v;
    if (f.sim.trader_restock_refill) |v| opts.trader_restock_refill = v;
    if (f.sim.sleeper_party_radius) |v| opts.sleeper_party_radius = v;
    if (f.sim.storm_frequency) |v| opts.storm_frequency = v;
    if (f.sim.te_scan_block_cap) |v| opts.te_scan_block_cap = v;
    if (f.sim.te_scan_te_cap) |v| opts.te_scan_te_cap = v;
    if (f.sim.trader_use_range) |v| opts.trade_use_range = v;
    if (f.sim.party_shared_kill_range) |v| opts.party_shared_kill_range = v;
    if (f.sim.storm_bm_push_ticks) |v| opts.storm_bm_push_ticks = v;
    if (f.sim.workstation_crafts_per_tick) |v| opts.workstation_crafts_per_tick = v;
    if (f.sim.workstation_craft_backlog) |v| opts.workstation_craft_backlog = v;
    if (f.sim.sleeper_cap_gate_enabled) |v| opts.sleeper_cap_gate_enabled = v;
    if (f.sim.airdrop_schedule) |v| opts.airdrop_schedule = v;
    if (f.sim.airdrop_day_min) |v| opts.airdrop_day_min = v;
    if (f.sim.airdrop_day_max) |v| opts.airdrop_day_max = v;
    if (f.sim.airdrop_drop_hour) |v| opts.airdrop_drop_hour = v;
    if (f.sim.airdrop_loot_list) |v| opts.airdrop_loot_list = v;
    if (f.apm.dump_every_s) |v| {
        if (@hasField(@TypeOf(opts.*), "apm_dump_every_s")) opts.apm_dump_every_s = v;
    }
}

/// Compile cap for Client.streamed[]: config owns the clamp, `server/game/types.zig`
/// sizes the array from this constant. 625 = a 25x25 square, covering the
/// stock client's view-distance-12 request (GAP "Chunk streaming"): the old
/// 169 cap truncated the default view-7 stream to a 13x13 hole-free disk,
/// leaving no server terrain beyond ~104 blocks.
pub const max_streamed_chunks_cap: usize = 625;

/// Clamp / repair InitOptions after config merge. Logs adjustments; never panics.
/// Safe to call even when no zdtd.toml was loaded (no-op on already-valid defaults).
pub fn sanitizeInitOptions(opts: anytype) void {
    if (opts.max_streamed_chunks == 0) {
        util_log.warn("zdtd: max_streamed_chunks=0 invalid; using 1\n", .{});
        opts.max_streamed_chunks = 1;
    }
    if (opts.max_streamed_chunks > max_streamed_chunks_cap) {
        util_log.warn(
            "zdtd: max_streamed_chunks={d} exceeds compile cap {d}; clamping\n",
            .{ opts.max_streamed_chunks, max_streamed_chunks_cap },
        );
        opts.max_streamed_chunks = max_streamed_chunks_cap;
    }
    var max_radius_for_budget: i32 = 1;
    while (true) {
        const next = max_radius_for_budget + 1;
        const side: usize = @intCast(2 * next + 1);
        if (side * side > opts.max_streamed_chunks) break;
        max_radius_for_budget = next;
    }
    if (opts.chunk_stream_radius_min < 1) {
        util_log.warn("zdtd: stream_radius_min={d} invalid; using 1\n", .{opts.chunk_stream_radius_min});
        opts.chunk_stream_radius_min = 1;
    }
    if (opts.chunk_stream_radius_min > max_radius_for_budget) {
        util_log.warn(
            "zdtd: stream_radius_min={d} exceeds stream budget radius {d}; clamping\n",
            .{ opts.chunk_stream_radius_min, max_radius_for_budget },
        );
        opts.chunk_stream_radius_min = max_radius_for_budget;
    }
    if (opts.chunk_stream_radius_max > max_radius_for_budget) {
        util_log.warn(
            "zdtd: stream_radius_max={d} exceeds stream budget radius {d}; clamping\n",
            .{ opts.chunk_stream_radius_max, max_radius_for_budget },
        );
        opts.chunk_stream_radius_max = max_radius_for_budget;
    }
    if (opts.chunk_stream_radius_max < opts.chunk_stream_radius_min) {
        util_log.warn(
            "zdtd: stream_radius_max={d} < min={d}; raising max to min\n",
            .{ opts.chunk_stream_radius_max, opts.chunk_stream_radius_min },
        );
        opts.chunk_stream_radius_max = opts.chunk_stream_radius_min;
    }
    if (opts.chunk_adds_per_stream_tick == 0) {
        util_log.warn("zdtd: chunk_adds_per_stream_tick=0 invalid; using 1\n", .{});
        opts.chunk_adds_per_stream_tick = 1;
    }
    if (opts.chunk_stream_period_ticks == 0) {
        util_log.warn("zdtd: chunk_stream_period_ticks=0 invalid; using 1\n", .{});
        opts.chunk_stream_period_ticks = 1;
    }
    if (opts.motion_replicate_period_ticks == 0) {
        util_log.warn("zdtd: motion_replicate_period_ticks=0 invalid; using 1\n", .{});
        opts.motion_replicate_period_ticks = 1;
    }
    if (opts.world_time_send_ticks == 0) {
        util_log.warn("zdtd: world_time_send_ticks=0 invalid; using 1\n", .{});
        opts.world_time_send_ticks = 1;
    }
    if (opts.vehicle_pos_send_ticks == 0) {
        util_log.warn("zdtd: vehicle_pos_send_ticks=0 invalid; using 1\n", .{});
        opts.vehicle_pos_send_ticks = 1;
    }
    if (opts.sleeper_tick_ticks == 0) {
        util_log.warn("zdtd: sleeper_tick_ticks=0 invalid; using 1\n", .{});
        opts.sleeper_tick_ticks = 1;
    }
    if (opts.turret_sync_ticks == 0) {
        util_log.warn("zdtd: turret_sync_ticks=0 invalid; using 1\n", .{});
        opts.turret_sync_ticks = 1;
    }
    if (opts.save_interval_ticks == 0) {
        util_log.warn("zdtd: save_interval_ticks=0 invalid; using 1\n", .{});
        opts.save_interval_ticks = 1;
    }
    if (opts.spawn_area_radius_max < 1) {
        util_log.warn("zdtd: spawn_area_radius_max={d} invalid; using 1\n", .{opts.spawn_area_radius_max});
        opts.spawn_area_radius_max = 1;
    }
    if (opts.max_claimed_damage < 1) {
        util_log.warn("zdtd: max_claimed_damage={d} invalid; using 1\n", .{opts.max_claimed_damage});
        opts.max_claimed_damage = 1;
    }
    if (!std.math.isFinite(opts.max_edit_range) or opts.max_edit_range <= 0) {
        util_log.warn("zdtd: max_edit_range={d} invalid; using 1\n", .{opts.max_edit_range});
        opts.max_edit_range = 1;
    }
    if (!std.math.isFinite(opts.interest_range) or opts.interest_range <= 0) {
        util_log.warn("zdtd: interest_range={d} invalid; using 1\n", .{opts.interest_range});
        opts.interest_range = 1;
    }
    if (@hasField(@TypeOf(opts.*), "max_horizontal_speed_mps") and
        (!std.math.isFinite(opts.max_horizontal_speed_mps) or opts.max_horizontal_speed_mps <= 0))
    {
        util_log.warn(
            "zdtd: max_horizontal_speed_mps={d} invalid; using 1\n",
            .{opts.max_horizontal_speed_mps},
        );
        opts.max_horizontal_speed_mps = 1;
    }
    if (opts.peer_stale_ms == 0) {
        util_log.warn("zdtd: peer_stale_ms=0 invalid; using 1\n", .{});
        opts.peer_stale_ms = 1;
    }
    if (@hasField(@TypeOf(opts.*), "lock_stale_ns") and opts.lock_stale_ns == 0) {
        util_log.warn("zdtd: lock_stale_ns=0 invalid; using 1\n", .{});
        opts.lock_stale_ns = 1;
    }
    if (@hasField(@TypeOf(opts.*), "deco_objects_per_join") and opts.deco_objects_per_join == 0) {
        util_log.warn("zdtd: deco_objects_per_join=0 invalid; using 1\n", .{});
        opts.deco_objects_per_join = 1;
    }
    // Anti-abuse rate limits: caps and bursts must stay >= 1 (a 0 cap would
    // permanently starve the bucket; a 0 burst would reject every combo).
    if (opts.inv_bucket_cap == 0) {
        util_log.warn("zdtd: inv_bucket_cap=0 invalid; using 1\n", .{});
        opts.inv_bucket_cap = 1;
    }
    if (opts.inv_refill_ns == 0) {
        util_log.warn("zdtd: inv_refill_ns=0 invalid; using 1\n", .{});
        opts.inv_refill_ns = 1;
    }
    if (opts.block_bucket_cap == 0) {
        util_log.warn("zdtd: block_bucket_cap=0 invalid; using 1\n", .{});
        opts.block_bucket_cap = 1;
    }
    if (opts.block_refill_ns == 0) {
        util_log.warn("zdtd: block_refill_ns=0 invalid; using 1\n", .{});
        opts.block_refill_ns = 1;
    }
    if (opts.damage_burst_max == 0) {
        util_log.warn("zdtd: damage_burst_max=0 invalid; using 1\n", .{});
        opts.damage_burst_max = 1;
    }
    if (opts.trader_restock_cap == 0) {
        util_log.warn("zdtd: trader_restock_cap=0 invalid; using 1\n", .{});
        opts.trader_restock_cap = 1;
    }
    if (opts.trader_restock_refill == 0) {
        util_log.warn("zdtd: trader_restock_refill=0 invalid; using 1\n", .{});
        opts.trader_restock_refill = 1;
    }
    if (opts.trader_wallet_dukes < 0) {
        util_log.warn("zdtd: trader_wallet_dukes={d} invalid; using 0\n", .{opts.trader_wallet_dukes});
        opts.trader_wallet_dukes = 0;
    }
    if (@hasField(@TypeOf(opts.*), "craft_max_times") and opts.craft_max_times == 0) {
        util_log.warn("zdtd: craft_max_times=0 invalid; using 1\n", .{});
        opts.craft_max_times = 1;
    }
    // A keystone claim area is centered on the block, so the side must be odd.
    // serverconfig forces it at parse; a mode pack sets the same field, so the
    // merged value is normalized here too (docs/GAME_OPTIONS.md LandClaimSize).
    if (@hasField(@TypeOf(opts.*), "land_claim_size") and opts.land_claim_size % 2 == 0) {
        const odd = if (opts.land_claim_size > 1) opts.land_claim_size - 1 else 1;
        util_log.warn(
            "zdtd: land_claim_size={d} must be odd; using {d}\n",
            .{ opts.land_claim_size, odd },
        );
        opts.land_claim_size = odd;
    }
    if (opts.storm_frequency < 0) {
        util_log.warn("zdtd: storm_frequency={d} invalid; using 0\n", .{opts.storm_frequency});
        opts.storm_frequency = 0;
    }
    if (@hasField(@TypeOf(opts.*), "plugin_budget")) {
        if (opts.plugin_budget.fuel == 0) {
            util_log.warn("zdtd: plugin fuel=0 invalid; using 1\n", .{});
            opts.plugin_budget.fuel = 1;
        }
        if (opts.plugin_budget.max_memory_pages == 0) {
            util_log.warn("zdtd: plugin max_pages=0 invalid; using 1\n", .{});
            opts.plugin_budget.max_memory_pages = 1;
        }
    }
    opts.guard.clamp();
}

test "parse stream and authority" {
    const src =
        \\# comment
        \\[stream]
        \\max_streamed_chunks = 100
        \\stream_radius_min = 5
        \\world_time_send_ticks = 40
        \\vehicle_pos_send_ticks = 7
        \\[authority]
        \\interest_range_blocks = 120.5
        \\peer_stale_ms = 4000
        \\mode = "observe"
        \\guard_enforce = true
        \\guard_dry_run = false
        \\guard_quarantine = yes
        \\guard_window_ticks = 600
        \\guard_strong_distinct = 3
        \\guard_hard_repeat = 40
        \\guard_kick_delay_ticks = 20
        \\guard_shed_hold_ticks = 80
        \\guard_weak_break_rate = 1200
        \\[feature]
        \\wire_chunks = false
        \\deco_trees = no
        \\deco_mirror = no
        \\block_id_mapping = false
        \\[sim]
        \\te_scan_block_cap = 16
        \\te_scan_te_cap = 24
        \\workstation_crafts_per_tick = 8
        \\workstation_craft_backlog = 30.0
        \\[apm]
        \\dump_every_s = 120
        \\[mode]
        \\name = "default"
        \\[plugin]
        \\modules = "assets/fixtures/plugin_hello.wasm, assets/fixtures/plugin_looper.wasm"
        \\fuel = 25000000
        \\max_pages = 128
    ;
    var f = try parse(std.testing.allocator, src);
    defer f.deinit();
    try std.testing.expectEqual(@as(usize, 100), f.stream.max_streamed_chunks.?);
    try std.testing.expectEqual(@as(i32, 5), f.stream.stream_radius_min.?);
    try std.testing.expectEqual(@as(u64, 40), f.stream.world_time_send_ticks.?);
    try std.testing.expectEqual(@as(u64, 7), f.stream.vehicle_pos_send_ticks.?);
    try std.testing.expectApproxEqAbs(@as(f32, 120.5), f.authority.interest_range_blocks.?, 0.01);
    try std.testing.expectEqual(@as(u64, 4000), f.authority.peer_stale_ms.?);
    try std.testing.expectEqualStrings("observe", f.authority.mode.?);
    try std.testing.expectEqual(true, f.authority.guard_enforce.?);
    try std.testing.expectEqual(false, f.authority.guard_dry_run.?);
    try std.testing.expectEqual(true, f.authority.guard_quarantine.?);
    try std.testing.expectEqual(@as(u64, 600), f.authority.guard_window_ticks.?);
    try std.testing.expectEqual(@as(u32, 3), f.authority.guard_strong_distinct.?);
    try std.testing.expectEqual(@as(u32, 40), f.authority.guard_hard_repeat.?);
    try std.testing.expectEqual(@as(u64, 20), f.authority.guard_kick_delay_ticks.?);
    try std.testing.expectEqual(@as(u64, 80), f.authority.guard_shed_hold_ticks.?);
    try std.testing.expectEqual(@as(u32, 1200), f.authority.guard_weak_break_rate.?);
    try std.testing.expectEqual(@as(u32, 16), f.sim.te_scan_block_cap.?);
    try std.testing.expectEqual(@as(u32, 24), f.sim.te_scan_te_cap.?);
    try std.testing.expectEqual(@as(u16, 8), f.sim.workstation_crafts_per_tick.?);
    try std.testing.expectApproxEqAbs(@as(f32, 30.0), f.sim.workstation_craft_backlog.?, 0.01);
    try std.testing.expectEqual(@as(u64, 120), f.apm.dump_every_s.?);
    try std.testing.expectEqual(false, f.feature.wire_chunks.?);
    try std.testing.expectEqual(false, f.feature.deco_trees.?);
    try std.testing.expectEqual(false, f.feature.deco_mirror.?);
    try std.testing.expectEqual(false, f.feature.block_id_mapping.?);
    try std.testing.expectEqualStrings("default", f.mode.name.?);
    try std.testing.expectEqualStrings(
        "assets/fixtures/plugin_hello.wasm, assets/fixtures/plugin_looper.wasm",
        f.plugin.modules.?,
    );
    try std.testing.expectEqual(@as(u64, 25_000_000), f.plugin.fuel.?);
    try std.testing.expectEqual(@as(u64, 128), f.plugin.max_pages.?);
}

test "parse rules overlay sections" {
    var f = try parse(std.testing.allocator,
        \\[rules.combat]
        \\attack_damage = 12.0
        \\[rules.ai]
        \\sense_dist_sq = 2500.0
        \\[rules.bloodmoon]
        \\max_parties = 4
    );
    defer f.deinit();
    try std.testing.expectEqual(@as(?f32, 12.0), f.rules.combat.attack_damage);
    try std.testing.expectEqual(@as(?f32, null), f.rules.combat.attack_range_sq);
    try std.testing.expectEqual(@as(?f32, 2500.0), f.rules.ai.sense_dist_sq);
    try std.testing.expectEqual(@as(?u32, 4), f.rules.bloodmoon.max_parties);
}

test "parse [quests] objective_kinds section" {
    var f = try parse(std.testing.allocator,
        \\[quests]
        \\objective_kinds = "QuestItem=craft, NewKill=kill_zombies"
        \\default_kill_count = 5
        \\kill_per_tier = 1
        \\goto_radius = 10.0
        \\stay_radius = 12.0
    );
    defer f.deinit();
    try std.testing.expectEqualStrings(
        "QuestItem=craft, NewKill=kill_zombies",
        f.quests.objective_kinds,
    );
    try std.testing.expectEqual(@as(?u8, 5), f.quests.default_kill_count);
    try std.testing.expectEqual(@as(?u8, 1), f.quests.kill_per_tier);
    try std.testing.expectEqual(@as(?f32, 10.0), f.quests.goto_radius);
    try std.testing.expectEqual(@as(?f32, 12.0), f.quests.stay_radius);
}

test "parse [bots] section" {
    var f = try parse(std.testing.allocator,
        \\[bots]
        \\shoot_damage = 20.0
        \\headshot_multiplier = 3.0
        \\spawn_spread = 4.0
        \\spawn_y = 80.0
        \\max_step_up = 2.0
    );
    defer f.deinit();
    try std.testing.expectEqual(@as(?f32, 20.0), f.bots.shoot_damage);
    try std.testing.expectEqual(@as(?f32, 3.0), f.bots.headshot_multiplier);
    try std.testing.expectEqual(@as(?f32, 4.0), f.bots.spawn_spread);
    try std.testing.expectEqual(@as(?f32, 80.0), f.bots.spawn_y);
    try std.testing.expectEqual(@as(?f32, 2.0), f.bots.max_step_up);
}

/// Mirror of the server init-options shape the merge helpers write into.
/// One superset covers every test below; helpers ignore fields they do not know.
const TestOpts = struct {
    max_streamed_chunks: usize = 625,
    chunk_adds_per_stream_tick: u32 = 8,
    chunk_stream_radius_min: i32 = 7,
    chunk_stream_radius_max: i32 = 9,
    chunk_stream_period_ticks: u64 = 5,
    motion_replicate_period_ticks: u64 = 2,
    world_time_send_ticks: u64 = 20,
    vehicle_pos_send_ticks: u64 = 5,
    sleeper_tick_ticks: u64 = 10,
    turret_sync_ticks: u64 = 10,
    save_interval_ticks: u64 = 100,
    spawn_area_radius_max: i32 = 8,
    interest_range: f32 = 160,
    max_edit_range: f32 = 96,
    max_horizontal_speed_mps: f32 = 20,
    max_claimed_damage: i32 = 200,
    peer_stale_ms: u64 = 3000,
    lock_stale_ns: u64 = 30_000_000_000,
    trader_wallet_dukes: i32 = 5000,
    min_chat_gap_ns: u64 = 200_000_000,
    inv_bucket_cap: u8 = 40,
    inv_refill_ns: u64 = 50_000_000,
    block_bucket_cap: u8 = 30,
    block_refill_ns: u64 = 33_000_000,
    min_damage_gap_ns: u64 = 80_000_000,
    damage_burst_max: u8 = 4,
    trader_restock_cap: u16 = 50,
    trader_restock_refill: u16 = 10,
    craft_max_times: u16 = 20,
    sleeper_party_radius: f32 = 100.0,
    storm_frequency: i32 = 100,
    te_scan_block_cap: u32 = 32,
    te_scan_te_cap: u32 = 48,
    trade_use_range: f32 = 32,
    party_shared_kill_range: f32 = 100,
    storm_bm_push_ticks: i64 = 5000,
    sleeper_cap_gate_enabled: bool = false,
    airdrop_schedule: []const u8 = "interval",
    airdrop_day_min: u32 = 3,
    airdrop_day_max: u32 = 3,
    airdrop_drop_hour: u32 = 12,
    airdrop_loot_list: []const u8 = "airDrop",
    workstation_crafts_per_tick: u16 = 64,
    workstation_craft_backlog: f32 = 60,
    apm_dump_every_s: ?u64 = null,
    land_claim_size: u16 = 41,
    plugin_budget: struct {
        fuel: u64 = 100_000_000,
        max_memory_pages: u64 = 1024,
    } = .{},
    wire_chunks: bool = true,
    deco_trees: bool = true,
    deco_mirror: bool = true,
    block_id_mapping: bool = true,
    async_chunk_flush: bool = false,
    terrain_snapshot: bool = false,
    job_batches: bool = false,
    guard: guard_policy.Policy = .{},
};

test "applyToInitOptions deco_trees only when set" {
    var o: TestOpts = .{};
    var none = try parse(std.testing.allocator, "[feature]\nwire_chunks = false\n");
    defer none.deinit();
    applyToInitOptions(&none, &o);
    try std.testing.expectEqual(true, o.deco_trees);
    var off = try parse(std.testing.allocator, "[feature]\ndeco_trees = false\n");
    defer off.deinit();
    applyToInitOptions(&off, &o);
    try std.testing.expectEqual(false, o.deco_trees);
    // The deco mirror and the blocks mapping are independent kill switches: one
    // regressing must not force the other off.
    try std.testing.expectEqual(true, o.deco_mirror);
    try std.testing.expectEqual(true, o.block_id_mapping);
    var no_map = try parse(std.testing.allocator, "[feature]\nblock_id_mapping = no\n");
    defer no_map.deinit();
    applyToInitOptions(&no_map, &o);
    try std.testing.expectEqual(false, o.block_id_mapping);
    try std.testing.expectEqual(true, o.deco_mirror);
    var no_mirror = try parse(std.testing.allocator, "[feature]\ndeco_mirror = no\n");
    defer no_mirror.deinit();
    applyToInitOptions(&no_mirror, &o);
    try std.testing.expectEqual(false, o.deco_mirror);
}

test "loadFromPath rejects oversized file" {
    const dir = "worlds/zdtd_toml_big";
    io_fs.mkdirPath("worlds");
    io_fs.mkdirPath(dir);
    const path = dir ++ "/zdtd.toml";
    const big = try std.testing.allocator.alloc(u8, max_toml_bytes + 1);
    defer std.testing.allocator.free(big);
    @memset(big, '#');
    try io_fs.writeFile(path, big);
    try std.testing.expectError(error.TomlTooLarge, loadFromPath(std.testing.allocator, path));
}

test "parse rejects unknown keys" {
    const src =
        \\[stream]
        \\nope = 1
        \\max_streamed_chunks = 10
    ;
    try std.testing.expectError(error.UnknownTomlKey, parse(std.testing.allocator, src));
}

test "parse rejects malformed assignments" {
    const src =
        \\[stream]
        \\max_streamed_chunks 10
    ;
    try std.testing.expectError(error.BadToml, parse(std.testing.allocator, src));
}

test "parse rejects invalid authority mode" {
    try std.testing.expectError(
        error.InvalidAuthorityMode,
        parse(std.testing.allocator, "[authority]\nmode = \"corect\"\n"),
    );
}

test "parse preserves hashes in quoted values and rejects malformed sections" {
    var f = try parse(std.testing.allocator,
        \\[mode]
        \\name = "pve#night" # trailing comment
    );
    defer f.deinit();
    try std.testing.expectEqualStrings("pve#night", f.mode.name.?);

    try std.testing.expectError(error.BadToml, parse(std.testing.allocator, "[stream] trailing\n"));
    try std.testing.expectError(error.BadToml, parse(std.testing.allocator, "[]\n"));
    try std.testing.expectError(error.BadToml, parse(std.testing.allocator, "[mode]\nname = \"unterminated\n"));
}

test "sanitizeInitOptions repairs bad radii" {
    var o: TestOpts = .{
        .max_streamed_chunks = 0,
        .chunk_stream_radius_min = 8,
        .chunk_stream_radius_max = 3,
        .interest_range = -1,
    };
    sanitizeInitOptions(&o);
    try std.testing.expectEqual(@as(usize, 1), o.max_streamed_chunks);
    try std.testing.expectEqual(@as(i32, 1), o.chunk_stream_radius_min);
    try std.testing.expectEqual(@as(i32, 1), o.chunk_stream_radius_max);
    try std.testing.expectEqual(@as(f32, 1), o.interest_range);
}

test "sanitizeInitOptions rejects non-finite ranges" {
    var o: TestOpts = .{ .max_edit_range = std.math.nan(f32), .interest_range = std.math.inf(f32) };
    sanitizeInitOptions(&o);
    try std.testing.expectEqual(@as(f32, 1), o.max_edit_range);
    try std.testing.expectEqual(@as(f32, 1), o.interest_range);
}

test "sanitizeInitOptions clamps max_streamed_chunks to cap" {
    var o: TestOpts = .{ .max_streamed_chunks = 999 };
    sanitizeInitOptions(&o);
    try std.testing.expectEqual(max_streamed_chunks_cap, o.max_streamed_chunks);
}

test "guard policy merges from [authority] and clamps" {
    var o: TestOpts = .{};
    // Default: log-only ladder, nothing denies.
    try std.testing.expectEqual(false, o.guard.enforce);
    try std.testing.expectEqual(true, o.guard.dry_run);

    var f = try parse(std.testing.allocator,
        \\[authority]
        \\guard_enforce = true
        \\guard_dry_run = false
        \\guard_load_shed = false
        \\guard_window_ticks = 0
        \\guard_strong_distinct = 99999
        \\guard_hard_repeat = 0
    );
    defer f.deinit();
    applyToInitOptions(&f, &o);
    try std.testing.expectEqual(true, o.guard.enforce);
    try std.testing.expectEqual(false, o.guard.dry_run);
    try std.testing.expectEqual(false, o.guard.load_shed);
    // Untouched key keeps its default.
    try std.testing.expectEqual(false, o.guard.quarantine);
    sanitizeInitOptions(&o);
    try std.testing.expectEqual(@as(u64, 1), o.guard.window_ticks);
    try std.testing.expectEqual(guard_policy.detector_slots, o.guard.strong_distinct);
    try std.testing.expectEqual(@as(u16, 1), o.guard.hard_repeat);
}

test "parse rejects unknown guard key and bad bool" {
    try std.testing.expectError(
        error.UnknownTomlKey,
        parse(std.testing.allocator, "[authority]\nguard_enfroce = true\n"),
    );
    try std.testing.expectError(
        error.BadTomlBool,
        parse(std.testing.allocator, "[authority]\nguard_enforce = maybe\n"),
    );
}

test "[perf] switches default off and merge only when set" {
    var o: TestOpts = .{};
    var none = try parse(std.testing.allocator, "[perf]\njob_batches = true\n");
    defer none.deinit();
    applyToInitOptions(&none, &o);
    try std.testing.expectEqual(false, o.async_chunk_flush);
    try std.testing.expectEqual(false, o.terrain_snapshot);
    try std.testing.expectEqual(true, o.job_batches);

    var all = try parse(std.testing.allocator,
        \\[perf]
        \\async_chunk_flush = true
        \\terrain_snapshot = yes
        \\
    );
    defer all.deinit();
    applyToInitOptions(&all, &o);
    try std.testing.expectEqual(true, o.async_chunk_flush);
    try std.testing.expectEqual(true, o.terrain_snapshot);

    try std.testing.expectError(
        error.UnknownTomlKey,
        parse(std.testing.allocator, "[perf]\nnope = true\n"),
    );
}

test "[sim] trader_wallet_dukes parses, merges, and clamps" {
    var o: TestOpts = .{};
    var f = try parse(std.testing.allocator,
        \\[sim]
        \\trader_wallet_dukes = 2500
        \\sleeper_party_radius = 50.0
    );
    defer f.deinit();
    applyToInitOptions(&f, &o);
    try std.testing.expectEqual(@as(i32, 2500), o.trader_wallet_dukes);
    try std.testing.expectEqual(@as(f32, 50.0), o.sleeper_party_radius);

    var neg = try parse(std.testing.allocator, "[sim]\ntrader_wallet_dukes = -5\n");
    defer neg.deinit();
    applyToInitOptions(&neg, &o);
    sanitizeInitOptions(&o);
    try std.testing.expectEqual(@as(i32, 0), o.trader_wallet_dukes);

    try std.testing.expectError(error.UnknownTomlKey, parse(std.testing.allocator, "[sim]\nnope = 1\n"));
}

test "[sim] storm_frequency parses and merges" {
    var o: TestOpts = .{};
    var f = try parse(std.testing.allocator, "[sim]\nstorm_frequency = 250\n");
    defer f.deinit();
    applyToInitOptions(&f, &o);
    try std.testing.expectEqual(@as(i32, 250), o.storm_frequency);
    // Default untouched when the key is absent.
    var empty = try parse(std.testing.allocator, "[sim]\ntrader_wallet_dukes = 5\n");
    defer empty.deinit();
    var o2: TestOpts = .{};
    applyToInitOptions(&empty, &o2);
    try std.testing.expectEqual(@as(i32, 100), o2.storm_frequency);
}

test "[authority] max_horizontal_speed_mps parses, merges, and clamps" {
    var f = try parse(
        std.testing.allocator,
        \\[authority]
        \\max_horizontal_speed_mps = 12.5
        \\
        ,
    );
    defer f.deinit();
    try std.testing.expectApproxEqAbs(@as(f32, 12.5), f.authority.max_horizontal_speed_mps.?, 0.01);
    var o: TestOpts = .{};
    applyToInitOptions(&f, &o);
    try std.testing.expectApproxEqAbs(@as(f32, 12.5), o.max_horizontal_speed_mps, 0.01);

    // Non-finite / non-positive caps would let any move through unclamped.
    var bad: TestOpts = .{ .max_horizontal_speed_mps = std.math.nan(f32) };
    sanitizeInitOptions(&bad);
    try std.testing.expectEqual(@as(f32, 1), bad.max_horizontal_speed_mps);
    var zero: TestOpts = .{ .max_horizontal_speed_mps = 0 };
    sanitizeInitOptions(&zero);
    try std.testing.expectEqual(@as(f32, 1), zero.max_horizontal_speed_mps);
}

test "sanitizeInitOptions forces an odd land claim size" {
    var o: TestOpts = .{ .land_claim_size = 40 };
    sanitizeInitOptions(&o);
    try std.testing.expectEqual(@as(u16, 39), o.land_claim_size);
    var one: TestOpts = .{ .land_claim_size = 1 };
    sanitizeInitOptions(&one);
    try std.testing.expectEqual(@as(u16, 1), one.land_claim_size);
}

test "sanitizeInitOptions repairs disabled runtime budgets" {
    var o: TestOpts = .{
        .craft_max_times = 0,
        .storm_frequency = -1,
        .plugin_budget = .{ .fuel = 0, .max_memory_pages = 0 },
    };
    sanitizeInitOptions(&o);
    try std.testing.expectEqual(@as(u16, 1), o.craft_max_times);
    try std.testing.expectEqual(@as(i32, 0), o.storm_frequency);
    try std.testing.expectEqual(@as(u64, 1), o.plugin_budget.fuel);
    try std.testing.expectEqual(@as(u64, 1), o.plugin_budget.max_memory_pages);
}

test "millisecond timeouts saturate instead of wrapping" {
    var f = try parse(
        std.testing.allocator,
        "[authority]\nlock_stale_ms = 18446744073709551615\n",
    );
    defer f.deinit();
    var o: TestOpts = .{};
    applyToInitOptions(&f, &o);
    try std.testing.expectEqual(std.math.maxInt(u64), o.lock_stale_ns);
}

test "stream radii cannot overflow or exceed the streamed chunk budget" {
    var o: TestOpts = .{
        .max_streamed_chunks = 625,
        .chunk_stream_radius_min = std.math.maxInt(i32),
        .chunk_stream_radius_max = std.math.maxInt(i32),
    };
    sanitizeInitOptions(&o);
    // 625 chunks = a 25x25 square: radius 12 is the largest fit.
    try std.testing.expectEqual(@as(i32, 12), o.chunk_stream_radius_min);
    try std.testing.expectEqual(@as(i32, 12), o.chunk_stream_radius_max);
}
