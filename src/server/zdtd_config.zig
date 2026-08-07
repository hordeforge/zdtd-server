//! zdtd.toml: operator tunables (Bucket B), not stock serverconfig.
//! Precedence (applied by caller): CLI > env (webui secret) > world/zdtd.toml >
//! CWD zdtd.toml > --serverconfig keys > code defaults.
//! Minimal TOML subset: [section] + key = int|float|bool|string. No arrays/tables-in-tables.
//! Parsing is the comptime binder (src/util/toml_bind.zig, ADR 0021 decision 1);
//! this file declares the shape and the merge/sanitize behaviour.
//! Design: docs/reviews/HARDCODE_AUDIT.md, docs/adr/0010-data-config-zig-plugins.md

const std = @import("std");
const io_fs = @import("../util/io_fs.zig");
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
    max_claimed_damage: ?i32 = null,
    peer_stale_ms: ?u64 = null,
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
};

/// Performance switches (docs/SCALE_ARCHITECTURE.md). All default off: each one
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
    /// Storm frequency percent (World::StormFrequency, stock GamePrefs default
    /// 100 = 1.0x; 0 disables storms). No V3.1.0 serverconfig key (world state,
    /// GameStats blob); this is the zdtd.toml surface.
    storm_frequency: ?i32 = null,
};

/// Select a gamemode pack under modes/<name>.toml (ADR 0010). Not the pack body.
pub const Mode = struct {
    name: ?[]const u8 = null,
};

/// Wasm plugin runtime (ADR 0020). `modules` is a comma-separated list of
/// .wasm file paths; main.zig splits it into InitOptions.plugin_modules.
pub const Plugin = struct {
    modules: ?[]const u8 = null,
};

/// Authority.mode is a constrained string: observe | permissive | correct.
/// The binder validates it by name and canonicalises the spelling.
pub const AuthorityModeName = enum {
    observe,
    permissive,
    correct,
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
    const data = try io_fs.readFileInto(allocator, path, read_buf);
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
    if (f.authority.max_claimed_damage) |v| opts.max_claimed_damage = v;
    if (f.authority.peer_stale_ms) |v| opts.peer_stale_ms = v;
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
    if (f.feature.wire_chunks) |v| opts.wire_chunks = v;
    if (f.feature.deco_trees) |v| opts.deco_trees = v;
    if (f.feature.deco_mirror) |v| opts.deco_mirror = v;
    if (f.feature.block_id_mapping) |v| opts.block_id_mapping = v;
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
    if (f.sim.storm_frequency) |v| opts.storm_frequency = v;
}

/// Compile cap for Client.streamed[] (must match game.zig max_streamed_chunks_cap).
pub const max_streamed_chunks_cap: usize = 169;

/// Clamp / repair InitOptions after config merge. Logs adjustments; never panics.
/// Safe to call even when no zdtd.toml was loaded (no-op on already-valid defaults).
pub fn sanitizeInitOptions(opts: anytype) void {
    if (opts.max_streamed_chunks == 0) {
        std.debug.print("zdtd: max_streamed_chunks=0 invalid; using 1\n", .{});
        opts.max_streamed_chunks = 1;
    }
    if (opts.max_streamed_chunks > max_streamed_chunks_cap) {
        std.debug.print(
            "zdtd: max_streamed_chunks={d} exceeds compile cap {d}; clamping\n",
            .{ opts.max_streamed_chunks, max_streamed_chunks_cap },
        );
        opts.max_streamed_chunks = max_streamed_chunks_cap;
    }
    if (opts.chunk_stream_radius_min < 1) {
        std.debug.print("zdtd: stream_radius_min={d} invalid; using 1\n", .{opts.chunk_stream_radius_min});
        opts.chunk_stream_radius_min = 1;
    }
    if (opts.chunk_stream_radius_max < opts.chunk_stream_radius_min) {
        std.debug.print(
            "zdtd: stream_radius_max={d} < min={d}; raising max to min\n",
            .{ opts.chunk_stream_radius_max, opts.chunk_stream_radius_min },
        );
        opts.chunk_stream_radius_max = opts.chunk_stream_radius_min;
    }
    if (opts.chunk_adds_per_stream_tick == 0) {
        std.debug.print("zdtd: chunk_adds_per_stream_tick=0 invalid; using 1\n", .{});
        opts.chunk_adds_per_stream_tick = 1;
    }
    if (opts.chunk_stream_period_ticks == 0) {
        std.debug.print("zdtd: chunk_stream_period_ticks=0 invalid; using 1\n", .{});
        opts.chunk_stream_period_ticks = 1;
    }
    if (opts.motion_replicate_period_ticks == 0) {
        std.debug.print("zdtd: motion_replicate_period_ticks=0 invalid; using 1\n", .{});
        opts.motion_replicate_period_ticks = 1;
    }
    if (opts.world_time_send_ticks == 0) {
        std.debug.print("zdtd: world_time_send_ticks=0 invalid; using 1\n", .{});
        opts.world_time_send_ticks = 1;
    }
    if (opts.vehicle_pos_send_ticks == 0) {
        std.debug.print("zdtd: vehicle_pos_send_ticks=0 invalid; using 1\n", .{});
        opts.vehicle_pos_send_ticks = 1;
    }
    if (opts.sleeper_tick_ticks == 0) {
        std.debug.print("zdtd: sleeper_tick_ticks=0 invalid; using 1\n", .{});
        opts.sleeper_tick_ticks = 1;
    }
    if (opts.turret_sync_ticks == 0) {
        std.debug.print("zdtd: turret_sync_ticks=0 invalid; using 1\n", .{});
        opts.turret_sync_ticks = 1;
    }
    if (opts.save_interval_ticks == 0) {
        std.debug.print("zdtd: save_interval_ticks=0 invalid; using 1\n", .{});
        opts.save_interval_ticks = 1;
    }
    if (opts.spawn_area_radius_max < 1) {
        std.debug.print("zdtd: spawn_area_radius_max={d} invalid; using 1\n", .{opts.spawn_area_radius_max});
        opts.spawn_area_radius_max = 1;
    }
    if (opts.max_claimed_damage < 1) {
        std.debug.print("zdtd: max_claimed_damage={d} invalid; using 1\n", .{opts.max_claimed_damage});
        opts.max_claimed_damage = 1;
    }
    if (!std.math.isFinite(opts.max_edit_range) or opts.max_edit_range <= 0) {
        std.debug.print("zdtd: max_edit_range={d} invalid; using 1\n", .{opts.max_edit_range});
        opts.max_edit_range = 1;
    }
    if (!std.math.isFinite(opts.interest_range) or opts.interest_range <= 0) {
        std.debug.print("zdtd: interest_range={d} invalid; using 1\n", .{opts.interest_range});
        opts.interest_range = 1;
    }
    if (opts.peer_stale_ms == 0) {
        std.debug.print("zdtd: peer_stale_ms=0 invalid; using 1\n", .{});
        opts.peer_stale_ms = 1;
    }
    // Anti-abuse rate limits: caps and bursts must stay >= 1 (a 0 cap would
    // permanently starve the bucket; a 0 burst would reject every combo).
    if (opts.inv_bucket_cap == 0) {
        std.debug.print("zdtd: inv_bucket_cap=0 invalid; using 1\n", .{});
        opts.inv_bucket_cap = 1;
    }
    if (opts.inv_refill_ns == 0) {
        std.debug.print("zdtd: inv_refill_ns=0 invalid; using 1\n", .{});
        opts.inv_refill_ns = 1;
    }
    if (opts.block_bucket_cap == 0) {
        std.debug.print("zdtd: block_bucket_cap=0 invalid; using 1\n", .{});
        opts.block_bucket_cap = 1;
    }
    if (opts.block_refill_ns == 0) {
        std.debug.print("zdtd: block_refill_ns=0 invalid; using 1\n", .{});
        opts.block_refill_ns = 1;
    }
    if (opts.damage_burst_max == 0) {
        std.debug.print("zdtd: damage_burst_max=0 invalid; using 1\n", .{});
        opts.damage_burst_max = 1;
    }
    if (opts.trader_restock_cap == 0) {
        std.debug.print("zdtd: trader_restock_cap=0 invalid; using 1\n", .{});
        opts.trader_restock_cap = 1;
    }
    if (opts.trader_restock_refill == 0) {
        std.debug.print("zdtd: trader_restock_refill=0 invalid; using 1\n", .{});
        opts.trader_restock_refill = 1;
    }
    if (opts.trader_wallet_dukes < 0) {
        std.debug.print("zdtd: trader_wallet_dukes={d} invalid; using 0\n", .{opts.trader_wallet_dukes});
        opts.trader_wallet_dukes = 0;
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
        \\[feature]
        \\wire_chunks = false
        \\deco_trees = no
        \\deco_mirror = no
        \\block_id_mapping = false
        \\[mode]
        \\name = "default"
        \\[plugin]
        \\modules = "assets/fixtures/plugin_hello.wasm, assets/fixtures/plugin_looper.wasm"
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
    try std.testing.expectEqual(false, f.feature.wire_chunks.?);
    try std.testing.expectEqual(false, f.feature.deco_trees.?);
    try std.testing.expectEqual(false, f.feature.deco_mirror.?);
    try std.testing.expectEqual(false, f.feature.block_id_mapping.?);
    try std.testing.expectEqualStrings("default", f.mode.name.?);
    try std.testing.expectEqualStrings(
        "assets/fixtures/plugin_hello.wasm, assets/fixtures/plugin_looper.wasm",
        f.plugin.modules.?,
    );
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

test "applyToInitOptions deco_trees only when set" {
    const Opts = struct {
        max_streamed_chunks: usize = 169,
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
        max_claimed_damage: i32 = 200,
        peer_stale_ms: u64 = 3000,
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
        storm_frequency: i32 = 100,
        wire_chunks: bool = true,
        deco_trees: bool = true,
        deco_mirror: bool = true,
        block_id_mapping: bool = true,
        async_chunk_flush: bool = false,
        terrain_snapshot: bool = false,
        job_batches: bool = false,
        guard: guard_policy.Policy = .{},
    };
    var o: Opts = .{};
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
    io_fs.mkdirPathSimple("worlds");
    io_fs.mkdirPathSimple(dir);
    const path = dir ++ "/zdtd.toml";
    const big = try std.testing.allocator.alloc(u8, max_toml_bytes + 1);
    defer std.testing.allocator.free(big);
    @memset(big, '#');
    try io_fs.writeFileSimple(path, big);
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
    const Opts = struct {
        max_streamed_chunks: usize = 169,
        chunk_stream_radius_min: i32 = 7,
        chunk_stream_radius_max: i32 = 9,
        chunk_adds_per_stream_tick: u32 = 8,
        chunk_stream_period_ticks: u64 = 5,
        motion_replicate_period_ticks: u64 = 2,
        world_time_send_ticks: u64 = 20,
        vehicle_pos_send_ticks: u64 = 5,
        sleeper_tick_ticks: u64 = 10,
        turret_sync_ticks: u64 = 10,
        save_interval_ticks: u64 = 100,
        spawn_area_radius_max: i32 = 8,
        max_claimed_damage: i32 = 200,
        max_edit_range: f32 = 96,
        interest_range: f32 = 160,
        peer_stale_ms: u64 = 3000,
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
        storm_frequency: i32 = 100,
        guard: guard_policy.Policy = .{},
    };
    var o: Opts = .{
        .max_streamed_chunks = 0,
        .chunk_stream_radius_min = 8,
        .chunk_stream_radius_max = 3,
        .interest_range = -1,
    };
    sanitizeInitOptions(&o);
    try std.testing.expectEqual(@as(usize, 1), o.max_streamed_chunks);
    try std.testing.expectEqual(@as(i32, 8), o.chunk_stream_radius_min);
    try std.testing.expectEqual(@as(i32, 8), o.chunk_stream_radius_max);
    try std.testing.expectEqual(@as(f32, 1), o.interest_range);
}

test "sanitizeInitOptions rejects non-finite ranges" {
    const Opts = struct {
        max_streamed_chunks: usize = 169,
        chunk_stream_radius_min: i32 = 7,
        chunk_stream_radius_max: i32 = 9,
        chunk_adds_per_stream_tick: u32 = 8,
        chunk_stream_period_ticks: u64 = 5,
        motion_replicate_period_ticks: u64 = 2,
        world_time_send_ticks: u64 = 20,
        vehicle_pos_send_ticks: u64 = 5,
        sleeper_tick_ticks: u64 = 10,
        turret_sync_ticks: u64 = 10,
        save_interval_ticks: u64 = 100,
        spawn_area_radius_max: i32 = 8,
        max_claimed_damage: i32 = 200,
        max_edit_range: f32 = std.math.nan(f32),
        interest_range: f32 = std.math.inf(f32),
        peer_stale_ms: u64 = 3000,
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
        storm_frequency: i32 = 100,
        guard: guard_policy.Policy = .{},
    };
    var o: Opts = .{};
    sanitizeInitOptions(&o);
    try std.testing.expectEqual(@as(f32, 1), o.max_edit_range);
    try std.testing.expectEqual(@as(f32, 1), o.interest_range);
}

test "sanitizeInitOptions clamps max_streamed_chunks to cap" {
    const Opts = struct {
        max_streamed_chunks: usize = 169,
        chunk_stream_radius_min: i32 = 7,
        chunk_stream_radius_max: i32 = 9,
        chunk_adds_per_stream_tick: u32 = 8,
        chunk_stream_period_ticks: u64 = 5,
        motion_replicate_period_ticks: u64 = 2,
        world_time_send_ticks: u64 = 20,
        vehicle_pos_send_ticks: u64 = 5,
        sleeper_tick_ticks: u64 = 10,
        turret_sync_ticks: u64 = 10,
        save_interval_ticks: u64 = 100,
        spawn_area_radius_max: i32 = 8,
        max_claimed_damage: i32 = 200,
        max_edit_range: f32 = 96,
        interest_range: f32 = 160,
        peer_stale_ms: u64 = 3000,
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
        storm_frequency: i32 = 100,
        guard: guard_policy.Policy = .{},
    };
    var o: Opts = .{ .max_streamed_chunks = 999 };
    sanitizeInitOptions(&o);
    try std.testing.expectEqual(max_streamed_chunks_cap, o.max_streamed_chunks);
}

test "guard policy merges from [authority] and clamps" {
    const Opts = struct {
        max_streamed_chunks: usize = 169,
        chunk_stream_radius_min: i32 = 7,
        chunk_stream_radius_max: i32 = 9,
        chunk_adds_per_stream_tick: u32 = 8,
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
        max_claimed_damage: i32 = 200,
        peer_stale_ms: u64 = 3000,
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
        storm_frequency: i32 = 100,
        wire_chunks: bool = true,
        deco_trees: bool = true,
        deco_mirror: bool = true,
        block_id_mapping: bool = true,
        async_chunk_flush: bool = false,
        terrain_snapshot: bool = false,
        job_batches: bool = false,
        guard: guard_policy.Policy = .{},
    };
    var o: Opts = .{};
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
    const Opts = struct {
        max_streamed_chunks: usize = 169,
        chunk_stream_radius_min: i32 = 7,
        chunk_stream_radius_max: i32 = 9,
        chunk_adds_per_stream_tick: u32 = 8,
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
        max_claimed_damage: i32 = 200,
        peer_stale_ms: u64 = 3000,
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
        storm_frequency: i32 = 100,
        wire_chunks: bool = true,
        deco_trees: bool = true,
        deco_mirror: bool = true,
        block_id_mapping: bool = true,
        async_chunk_flush: bool = false,
        terrain_snapshot: bool = false,
        job_batches: bool = false,
        guard: guard_policy.Policy = .{},
    };
    var o: Opts = .{};
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
    const Opts = struct {
        max_streamed_chunks: usize = 169,
        chunk_stream_radius_min: i32 = 7,
        chunk_stream_radius_max: i32 = 9,
        chunk_adds_per_stream_tick: u32 = 8,
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
        max_claimed_damage: i32 = 200,
        peer_stale_ms: u64 = 3000,
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
        storm_frequency: i32 = 100,
        wire_chunks: bool = true,
        deco_trees: bool = true,
        deco_mirror: bool = true,
        block_id_mapping: bool = true,
        async_chunk_flush: bool = false,
        terrain_snapshot: bool = false,
        job_batches: bool = false,
        guard: guard_policy.Policy = .{},
    };
    var o: Opts = .{};
    var f = try parse(std.testing.allocator,
        \\[sim]
        \\trader_wallet_dukes = 2500
    );
    defer f.deinit();
    applyToInitOptions(&f, &o);
    try std.testing.expectEqual(@as(i32, 2500), o.trader_wallet_dukes);

    var neg = try parse(std.testing.allocator, "[sim]\ntrader_wallet_dukes = -5\n");
    defer neg.deinit();
    applyToInitOptions(&neg, &o);
    sanitizeInitOptions(&o);
    try std.testing.expectEqual(@as(i32, 0), o.trader_wallet_dukes);

    try std.testing.expectError(error.UnknownTomlKey, parse(std.testing.allocator, "[sim]\nnope = 1\n"));
}

test "[sim] storm_frequency parses and merges" {
    const Opts = struct {
        max_streamed_chunks: usize = 169,
        chunk_stream_radius_min: i32 = 7,
        chunk_stream_radius_max: i32 = 9,
        chunk_adds_per_stream_tick: u32 = 8,
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
        max_claimed_damage: i32 = 200,
        peer_stale_ms: u64 = 3000,
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
        storm_frequency: i32 = 100,
        wire_chunks: bool = true,
        deco_trees: bool = true,
        deco_mirror: bool = true,
        block_id_mapping: bool = true,
        async_chunk_flush: bool = false,
        terrain_snapshot: bool = false,
        job_batches: bool = false,
        guard: guard_policy.Policy = .{},
    };
    var o: Opts = .{};
    var f = try parse(std.testing.allocator, "[sim]\nstorm_frequency = 250\n");
    defer f.deinit();
    applyToInitOptions(&f, &o);
    try std.testing.expectEqual(@as(i32, 250), o.storm_frequency);
    // Default untouched when the key is absent.
    var empty = try parse(std.testing.allocator, "[sim]\ntrader_wallet_dukes = 5\n");
    defer empty.deinit();
    var o2: Opts = .{};
    applyToInitOptions(&empty, &o2);
    try std.testing.expectEqual(@as(i32, 100), o2.storm_frequency);
}
