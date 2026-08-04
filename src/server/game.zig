//! Game server: join SM, tick, interest, combat, persistence.
//! Simulation is an SoA ECS (`ecs.World` + systems).

const std = @import("std");
const apm = @import("../apm/root.zig");
const clock = @import("../apm/clock.zig");
const ln_server = @import("../litenet/server.zig");
const ln_peer = @import("../litenet/peer.zig");
const wire_frame = @import("../wire/frame.zig");
const packages = @import("../wire/packages.zig");
const world_store = @import("../world/store.zig");
const ecs = @import("../ecs/root.zig");
const systems = @import("../ecs/systems.zig");
const protocol = @import("../protocol.zig");
const assets_quests = @import("../assets/quests.zig");
const assets_blocks = @import("../assets/blocks.zig");
const assets_items = @import("../assets/items.zig");
const assets_signs = @import("../assets/signs.zig");
const assets_entities = @import("../assets/entities.zig");
const assets_recipes = @import("../assets/recipes.zig");
const assets_loot = @import("../assets/loot.zig");
const assets_entitygroups = @import("../assets/entitygroups.zig");
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
const te_types = @import("../wire/te_types.zig");
const biomes_mod = @import("../world/biomes.zig");
const interest = @import("../ecs/interest.zig");
const invsys = @import("../ecs/inventory.zig");
const admin_mod = @import("admin.zig");
const serverinfo_tcp = @import("serverinfo_tcp.zig");
const containers_mod = @import("../world/containers.zig");
const workstations_mod = @import("../world/workstations.zig");
const stock_te = @import("../wire/stock_te.zig");
const sleepers_mod = @import("../world/sleepers.zig");
const server_config = @import("config.zig");
const io_fs = @import("../util/io_fs.zig");

const max_clients = ln_server.max_peers;
const max_land_claims: usize = 256;

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
    view_radius: i32 = 7,
    admin_port: u16 = 0,
    world_name: ?[]const u8 = null,
    /// ServerMaxPlayerCount from serverconfig (capped at LiteNet max_peers).
    max_players: u16 = 8,
    /// ServerPassword from serverconfig. Non-empty rejects join until Encryption* path lands.
    password: []const u8 = "",
    /// Stream NetPackageChunk on join/tick. Default on: stock clients need server chunks
    /// (no client-side generation workarounds). Loadgen can still parse stock bodies.
    wire_chunks: bool = true,

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

    // zdtd stream/authority tunables (Bucket B). Defaults == historical consts.
    // Full file surface (zdtd.toml) still open; fields are the single source for hot path.
    max_streamed_chunks: usize = 169,
    chunk_stream_radius_min: i32 = 7,
    chunk_stream_radius_max: i32 = 9,
    chunk_adds_per_stream_tick: u32 = 8,
    chunk_stream_period_ticks: u64 = 5,
    motion_replicate_period_ticks: u64 = 2,
    spawn_area_radius_max: i32 = 8,
    max_claimed_damage: i32 = 200,
    max_edit_range: f32 = 96,
    interest_range: f32 = 160,
    peer_stale_ms: u64 = 3000,
};

// Compile-time array bound for Client.streamed / deco_streamed (must cover max config).
const max_streamed_chunks_cap: usize = 169;
/// Default stream/authority values (also InitOptions / Game field defaults).
pub const default_max_streamed_chunks: usize = 169;
pub const default_chunk_stream_radius_min: i32 = 7;
pub const default_chunk_stream_radius_max: i32 = 9;
pub const default_chunk_adds_per_stream_tick: u32 = 8;
pub const default_chunk_stream_period_ticks: u64 = 5;
pub const default_motion_replicate_period_ticks: u64 = 2;
pub const default_spawn_area_radius_max: i32 = 8;
pub const default_max_claimed_damage: i32 = 200;
pub const default_max_edit_range: f32 = 96;
pub const default_interest_range: f32 = 160;
pub const default_peer_stale_ms: u64 = 3000;
/// Scratch for serialize-once framed packets (PosAndRot ~40 B body + frame hdr).
const replicate_frame_cap: usize = 256;
/// Speeds body offset inside body_buf during zombie motion encode.
const speeds_body_off: usize = 64;
/// AliveFlags body offset (after speeds).
const flags_body_off: usize = 96;

/// True when `s` equals any of the given alternatives (console verb aliases).
fn eqAny(s: []const u8, alts: []const []const u8) bool {
    for (alts) |a| if (std.mem.eql(u8, s, a)) return true;
    return false;
}

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
    authed_challenge: bool = false,
    joined: bool = false,
    /// True after sendJoinBundle (WorldInfo/PlayerId). Gate tick broadcasts until then.
    entered: bool = false,
    challenge: [16]u8 = .{0} ** 16,
    slot: usize = 0,
    view_radius: i32 = 7,
    name: [32]u8 = .{0} ** 32,
    name_len: usize = 0,
    /// Chunk keys currently known streamed to this client (WorldChunkCache keys).
    streamed: [max_streamed_chunks_cap]i64 = undefined,
    streamed_n: usize = 0,
    /// Terrain chunks for which we already sent incremental DecoUpdate objects.
    deco_streamed: [max_streamed_chunks_cap]i64 = undefined,
    deco_streamed_n: usize = 0,
    /// Entity slots this client has received an ECD EntitySpawn for
    /// (spawn-on-approach; cleared when the entity dies or slot recycles).
    known_entities: std.StaticBitSet(ecs.max_entities) = std.StaticBitSet(ecs.max_entities).initEmpty(),
    /// True after firstPackage DecoUpdate (client OnWorldLoaded needs this once).
    deco_first_sent: bool = false,
    /// Game payload arrived before challenge echo (stock/loadgen can race). Replay after auth.
    preauth_buf: [512]u8 = undefined,
    preauth_len: usize = 0,
};

pub const Game = struct {
    allocator: std.mem.Allocator,
    net: ln_server.Server = .{},
    world: world_store.World,
    /// Entity-component-system sim world.
    sim: ecs.World = .{},
    clients: [max_clients]Client = [_]Client{.{}} ** max_clients,
    harness: apm.Harness = .{},
    tick_n: u64 = 0,
    running: bool = true,
    challenge_counter: u64 = 1,
    /// Stock PlayerLogin carries Steam/EOS tickets (multi-KiB). Truncating here
    /// drops login silently and the client hangs at "Connecting…".
    recv_buf: [65536]u8 = undefined,
    // Mixed-surface stock chunks (per-cell density) exceed 64KiB easily.
    send_buf: [262144]u8 = undefined,
    body_buf: [524288]u8 = undefined,
    /// Guards pumpAcks reentrancy while draining ACKs mid-send.
    pumping: bool = false,
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
    maxdamage: assets_maxdamage.Table = assets_maxdamage.Table.empty(),
    /// blocks.xml Texture → textureFull defaults (unpainted cells).
    block_textures: assets_block_textures.Table = assets_block_textures.Table.empty(),
    painting: assets_painting.Table = assets_painting.Table.empty(),
    spawning: assets_spawning.Table = assets_spawning.Table.empty(),
    buffs: assets_buffs.Table = assets_buffs.Table.empty(),
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
    view_radius: i32 = 7,
    /// Advertised + soft join cap (ServerMaxPlayerCount); ≤ max_clients.
    max_players: u16 = 8,
    world_name: []const u8 = "zdtd",
    admin: admin_mod.Server = .{},
    admin_line: [admin_mod.max_cmd]u8 = undefined,
    /// Stock ServerPort: TCP GameServerInfo. LiteNet listens on info_port+2.
    info_port: u16 = 0,
    info_tcp: serverinfo_tcp.Provider = .{},
    wire_chunks: bool = true,
    /// Set on PlayerData receipt; flushed on the periodic save tick (not per packet).
    players_dirty: bool = false,
    /// Last blood-moon-music state broadcast (edge-triggered).
    bloodmoon_sent: bool = false,
    /// Empty = open. Non-empty = reject login (crypto path TODO).
    password: []const u8 = "",
    /// Stream / authority tunables (InitOptions; future zdtd.toml). Defaults match historical consts.
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
        const g = try allocator.create(Game);
        errdefer allocator.destroy(g);
        try g.initWithOptions(allocator, world_dir, port, opts);
        return g;
    }

    /// Initialize into an existing allocation (must be heap for live server size).
    pub fn initWithOptions(self: *Game, allocator: std.mem.Allocator, world_dir: []const u8, port: u16, opts: InitOptions) !void {
        const max_pl: u16 = blk: {
            const n = if (opts.max_players == 0) @as(u16, 8) else opts.max_players;
            break :blk @min(n, @as(u16, max_clients));
        };
        self.* = .{
            .allocator = allocator,
            .world = try world_store.World.init(allocator, world_dir),
            .view_radius = opts.view_radius,
            .max_players = max_pl,
            .wire_chunks = opts.wire_chunks,
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
            .max_streamed_chunks = @min(opts.max_streamed_chunks, max_streamed_chunks_cap),
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
            self.info_tcp.stop();
            self.sim.deinit();
            self.blocks.deinit();
            self.items.deinit();
            self.signs.deinit();
            self.entities.deinit();
            self.recipes.deinit();
            self.loot.deinit();
            self.entitygroups.deinit();
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
        try self.sim.ensureNetMap(allocator);
        // Back the ECS vehicle-physics ground hook with the real block store.
        self.sim.ground_ctx = self;
        self.sim.ground_fn = &heightAtWorld;
        // AI path solid probe: blocked if body-height cell is solid.
        self.sim.solid_ctx = self;
        self.sim.solid_fn = &pathSolidAt;
        self.sim.place_ctx = self;
        self.sim.place_fn = &placeBlockId;
        self.sim.fuel_value_ctx = self;
        self.sim.fuel_value_fn = &itemFuelValue;
        self.sim.stack_ctx = self;
        self.sim.stack_fn = &itemStackFor;
        self.sim.is_armor_ctx = self;
        self.sim.is_armor_fn = &itemIsArmor;
        // Chest/TE contents + door/shape meta survive restart (best-effort: absent on fresh world).
        // Missing persist files are fine on first boot.
        self.containers.load(self.world.world_dir) catch {};
        self.loadBlockMeta() catch {};
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
            self.maxdamage.resolveMaterialMaxDamage(allocator) catch {};
            if (self.world.prefabs) |*pf| {
                if (pf.prefabs_root.len > 0) {
                    var nim_path: [2048]u8 = undefined;
                    if (std.fmt.bufPrint(&nim_path, "{s}/POIs/abandoned_house_01.blocks.nim", .{pf.prefabs_root})) |p| {
                        self.maxdamage.mergeNim(allocator, p) catch {};
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
            };
            var id_ctx: IdCtx = .{ .t = &self.maxdamage };
            if (assets_biome_layers.tryLoad(allocator, opts.game_dir, opts.config_dir, IdCtx.lookup, &id_ctx) catch null) |bl| {
                self.world.biome_layers_table = bl;
                const burnt = bl.stackFor(9);
                std.debug.print("zdtd: biome layers default_n={d} burnt_n={d} burnt0={d}\n", .{
                    bl.default_stack.n,
                    burnt.n,
                    if (burnt.n > 0) burnt.layers[0].block_id else 0,
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
                        .y = d.y,
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
                            .y = d.y,
                            .z = d.z,
                            .rot = d.rot,
                            .size_x = d.size_x,
                            .size_y = d.size_y,
                            .size_z = d.size_z,
                        });
                        if (refs.items.len >= 1200) break;
                    }
                }
                if (sleepers_mod.loadFromPrefabs(allocator, pf.prefabs_root, refs.items) catch null) |sv| {
                    self.sleepers.deinit();
                    self.sleepers = sv;
                    std.debug.print("zdtd: sleeper volumes={d} (prefabs_near={d})\n", .{ self.sleepers.volumes.len, refs.items.len });
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
                .server_version = "V 3.1.0",
                .world_size = 6144,
                .eac_enabled = false,
            }) catch |err| {
                std.debug.print("zdtd: warning: TCP server-info on {d} failed: {}\n", .{ port, err });
            };
        }
        if (opts.admin_port != 0) {
            self.admin.listen(opts.admin_port) catch |err| {
                std.debug.print("zdtd: warning: admin TCP on 127.0.0.1:{d} failed: {}\n", .{ opts.admin_port, err });
            };
            if (self.admin.port != 0) {
                std.debug.print("zdtd: admin console 127.0.0.1:{d}\n", .{self.admin.port});
            }
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
            self.world.setBlockWorld(cx, cy, cz, chest_block) catch {};
            if (self.containers.getOrCreate(.{ .x = cx, .y = cy, .z = cz }, 8, chest_block)) |cont| {
                cont.setSlot(0, .{ .item_id = 7, .count = 10, .quality = 1 }); // wood
                cont.setSlot(1, .{ .item_id = 2, .count = 3, .quality = 1 }); // food
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
    }

    /// True when Hard C2S rejects should apply (Correct mode). Observe keeps
    /// join-phase Hard drops but is the flag for future soft-only paths.
    fn authorityCorrects(self: *const Game) bool {
        return self.authority_mode == .correct;
    }

    /// Terrain resting height for vehicle physics: top solid block + 1 (an
    /// entity on the surface sits one block above the topmost solid). Backs
    /// World.ground_fn; signature matches ecs World.ground_fn.
    fn heightAtWorld(ctx: ?*anyopaque, wx: i32, wz: i32) f32 {
        const g: *Game = @ptrCast(@alignCast(ctx.?));
        const t = world_store.World.worldToChunk(wx, wz);
        const ch = g.world.getOrCreate(t.pos) catch return 61;
        return @as(f32, @floatFromInt(ch.heightAt(t.lx, t.lz))) + 1.0;
    }

    /// ECS path solid hook: true if body-height cell blocks horizontal move.
    /// Uses heightmap top + 1 as body y (same surface band as heightAtWorld).
    fn pathSolidAt(ctx: ?*anyopaque, wx: i32, wz: i32) bool {
        const g: *Game = @ptrCast(@alignCast(ctx.?));
        const t = world_store.World.worldToChunk(wx, wz);
        const ch = g.world.getOrCreate(t.pos) catch return false;
        const h: i32 = ch.heightAt(t.lx, t.lz);
        // Foot cell is air/walkable on surface; block if something solid at body.
        return ch.isSolid(t.lx, h + 1, t.lz);
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
        if (g.maxdamage.id_by_name.count() > 0) return 0;
        return invsys.itemToBlock(item_id);
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

    fn decoHeightAt(ctx: ?*anyopaque, wx: i32, wz: i32) u8 {
        const g: *Game = @ptrCast(@alignCast(ctx.?));
        const t = world_store.World.worldToChunk(wx, wz);
        const ch = g.world.getOrCreate(t.pos) catch return 64;
        return ch.heightAt(t.lx, t.lz);
    }

    fn decoTreeIds(self: *Game) struct { oak: u32, dead: u32, ok: bool } {
        const oak = self.maxdamage.idByName("treeOakSml01") orelse 0;
        const dead = self.maxdamage.idByName("treeDeadTree02") orelse 0;
        if (oak == 0 or dead == 0) return .{ .oak = 0, .dead = 0, .ok = false };
        return .{ .oak = oak, .dead = dead, .ok = true };
    }

    fn clientHasDeco(c: *const Client, key: i64) bool {
        var i: usize = 0;
        while (i < c.deco_streamed_n) : (i += 1) {
            if (c.deco_streamed[i] == key) return true;
        }
        return false;
    }

    fn clientAddDeco(c: *Client, key: i64) void {
        if (clientHasDeco(c, key)) return;
        if (c.deco_streamed_n >= max_streamed_chunks_cap) {
            var i: usize = 1;
            while (i < c.deco_streamed_n) : (i += 1) c.deco_streamed[i - 1] = c.deco_streamed[i];
            c.deco_streamed_n -= 1;
        }
        c.deco_streamed[c.deco_streamed_n] = key;
        c.deco_streamed_n += 1;
    }

    /// Stream DecoObjects (plants/trees) around spawn. Uses AssignIds idByName;
    /// if dump lacks tree names, send empty firstPackage only (fail closed).
    fn sendDecoAroundSpawn(self: *Game, peer: *ln_peer.Peer, wx: i32, wz: i32, first: bool) !void {
        const ids = self.decoTreeIds();
        var objs: [48]packages.stock_deco.DecoObj = undefined;
        var n: usize = 0;
        if (ids.ok) {
            n = packages.stock_deco.generateAroundIds(
                &objs,
                wx - 48,
                wz - 48,
                wx + 48,
                wz + 48,
                decoHeightAt,
                self,
                29,
                ids.oak,
                ids.dead,
            );
        }
        if (first) {
            const body = try packages.stock_deco.buildDecoUpdate(&self.body_buf, true, objs[0..n]);
            try self.sendGame(peer, "NetPackageDecoUpdate", body);
        } else if (n > 0) {
            const body = try packages.stock_deco.buildDecoUpdate(&self.body_buf, false, objs[0..n]);
            try self.sendGame(peer, "NetPackageDecoUpdate", body);
        }
        for (&self.clients) |*cl| {
            if (cl.peer != peer) continue;
            cl.deco_first_sent = cl.deco_first_sent or first;
            const t = world_store.World.worldToChunk(wx, wz);
            var dz: i32 = -3;
            while (dz <= 3) : (dz += 1) {
                var dx: i32 = -3;
                while (dx <= 3) : (dx += 1) {
                    clientAddDeco(cl, packages.makeChunkKey(t.pos.x + dx, t.pos.z + dz));
                }
            }
            break;
        }
        std.debug.print("zdtd: DecoUpdate first={} objs={d} oak={d}\n", .{ first, n, ids.oak });
    }

    /// Incremental deco for one newly streamed terrain chunk (never firstPackage).
    fn sendDecoForTerrainChunk(self: *Game, c: *Client, peer: *ln_peer.Peer, cx: i32, cz: i32) !void {
        if (clientHasDeco(c, packages.makeChunkKey(cx, cz))) return;
        const ids = self.decoTreeIds();
        if (ids.ok) {
            var objs: [16]packages.stock_deco.DecoObj = undefined;
            const n = packages.stock_deco.generateAroundIds(
                &objs,
                cx * 16,
                cz * 16,
                cx * 16 + 16,
                cz * 16 + 16,
                decoHeightAt,
                self,
                31,
                ids.oak,
                ids.dead,
            );
            if (n > 0) {
                const body = try packages.stock_deco.buildDecoUpdate(&self.body_buf, false, objs[0..n]);
                try self.sendGame(peer, "NetPackageDecoUpdate", body);
            }
        }
        clientAddDeco(c, packages.makeChunkKey(cx, cz));
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
            const probe = try assets_signs.buildSignDataResponseBatch(
                &self.body_buf,
                self.signs.entries,
                start,
                false,
            );
            const is_last = probe.next >= self.signs.entries.len;
            const batch = try assets_signs.buildSignDataResponseBatch(
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
        // Shutdown persist is best-effort; do not fail deinit on disk errors.
        self.savePlayers() catch {};
        self.world.saveAll() catch {};
        self.containers.save(self.world.world_dir) catch {};
        self.saveBlockMeta() catch {};
        self.land_claims_n = 0;
        self.sim.deinit();
        self.blocks.deinit();
        self.items.deinit();
        self.signs.deinit();
        self.entities.deinit();
        self.recipes.deinit();
        self.loot.deinit();
        self.entitygroups.deinit();
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
        self.info_tcp.stop();
        self.world.deinit();
        self.net.deinit();
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

    /// Record layout (v1): magic ZPV1 | n:u32 | records…
    /// each: name_len:u8 | name | x,y,z f32 | coins u32 | inv_n u8 | (item u16, count u16)*inv_n
    /// Merge-write: offline players' existing records are carried over, not erased.
    fn savePlayers(self: *Game) !void {
        var path_buf: [512]u8 = undefined;
        const path = try self.playersPath(&path_buf);

        var old_recs: [4096]u8 = undefined;
        var old_len: usize = 0;
        var old_count: u32 = 0;
        if (io_fs.readFileAll(self.allocator, path)) |old_data| {
            defer self.allocator.free(old_data);
            if (old_data.len >= 8 and old_data[0] == 'Z' and old_data[1] == 'P' and old_data[3] == '2') {
                old_count = std.mem.readInt(u32, old_data[4..8], .little);
                old_len = @min(old_data.len - 8, old_recs.len);
                @memcpy(old_recs[0..old_len], old_data[8..][0..old_len]);
            }
        } else |_| {}

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);

        var hdr: [8]u8 = .{ 'Z', 'P', 'V', '2', 0, 0, 0, 0 };
        var count: u32 = 0;
        for (&self.clients) |*cl| {
            if (cl.joined and cl.entity_id > 0 and cl.name_len > 0) count += 1;
        }
        var kept_old: u32 = 0;
        var old_off: usize = 0;
        var keep_flags: [64]bool = .{false} ** 64;
        {
            var ri: u32 = 0;
            while (ri < old_count and ri < keep_flags.len) : (ri += 1) {
                if (old_off >= old_len) break;
                const nl: usize = old_recs[old_off];
                if (old_off + 1 + nl + 17 > old_len) break;
                const rec_name = old_recs[old_off + 1 ..][0..nl];
                old_off += 1 + nl + 16;
                const inv_n: usize = old_recs[old_off];
                old_off += 1 + inv_n * 7;
                if (old_off >= old_len) break;
                const jn: usize = old_recs[old_off];
                old_off += 1 + jn * 10;
                if (old_off > old_len) break;
                var online = false;
                for (&self.clients) |*cl| {
                    if (cl.joined and cl.name_len == nl and std.mem.eql(u8, cl.name[0..nl], rec_name)) {
                        online = true;
                        break;
                    }
                }
                if (!online) {
                    keep_flags[ri] = true;
                    kept_old += 1;
                }
            }
        }
        std.mem.writeInt(u32, hdr[4..8], count + kept_old, .little);
        try out.appendSlice(self.allocator, &hdr);
        {
            var ri: u32 = 0;
            var off: usize = 0;
            while (ri < old_count and ri < keep_flags.len) : (ri += 1) {
                const rec_start = off;
                if (off >= old_len) break;
                const nl: usize = old_recs[off];
                if (off + 1 + nl + 17 > old_len) break;
                off += 1 + nl + 16;
                const inv_n: usize = old_recs[off];
                off += 1 + inv_n * 7;
                if (off >= old_len) break;
                const jn2: usize = old_recs[off];
                off += 1 + jn2 * 10;
                if (off > old_len) break;
                if (keep_flags[ri]) {
                    try out.appendSlice(self.allocator, old_recs[rec_start..off]);
                }
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
                    if (s.count == 0) continue;
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
                    rec[o + 6] = (@as(u8, @intFromBool(q.active))) | (@as(u8, @intFromBool(q.completed)) << 1) | (@as(u8, @intFromBool(q.ready_turn_in)) << 2);
                    std.mem.writeInt(u16, rec[o + 7 ..][0..2], q.progress, .little);
                    rec[o + 9] = q.phase;
                    o += 10;
                    jn += 1;
                }
            }
            rec[j_start] = jn;
            try out.appendSlice(self.allocator, rec[0..o]);
        }
        try io_fs.writeFile(self.allocator, path, out.items);
    }

    fn tryRestorePlayer(self: *Game, c: *Client) void {
        if (c.name_len == 0) return;
        var path_buf: [512]u8 = undefined;
        const path = self.playersPath(&path_buf) catch return;
        const data = io_fs.readFileAll(self.allocator, path) catch return;
        defer self.allocator.free(data);
        if (data.len < 8) return;
        if (data[0] != 'Z' or data[1] != 'P' or data[3] != '2') return;
        const n = std.mem.readInt(u32, data[4..8], .little);
        var off: usize = 8;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            if (off >= data.len) return;
            const nl: usize = data[off];
            off += 1;
            if (nl > 32 or off + nl + 16 + 1 > data.len) return;
            const name_slice = data[off..][0..nl];
            off += nl;
            const rest = data[off..][0..16];
            off += 16;
            const inv_n: usize = data[off];
            off += 1;
            if (off + inv_n * 7 + 1 > data.len) return;
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
            if (off + jn * 10 > data.len) return;
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
                }
            }
            return;
        }
    }

    fn pollAdmin(self: *Game) void {
        const chunk = self.admin.pollLine(&self.admin_line) orelse return;
        // One read may carry several newline-separated commands (piped input).
        var it = std.mem.tokenizeAny(u8, chunk, "\r\n");
        while (it.next()) |line| self.runAdminLine(line);
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
        std.debug.print("zdtd: console cmd from slot={d}: {s}\n", .{ c.slot, cmd });

        var out: ConsoleOut = .{};
        var it = std.mem.tokenizeAny(u8, cmd, " ");
        const verb = it.next() orelse return;

        const player = self.sim.playerByPeer(c.slot);

        if (eqAny(verb, &.{ "help", "commands", "?" })) {
            out.line("zdtd console commands:");
            out.line(" gettime | settime <day|night|D H M>");
            out.line(" teleportplayer|tp <x> <y> <z>");
            out.line(" spawnentity|se <class> | spawnairdrop | killall");
            out.line(" giveself <item> [count]");
            out.line(" listplayers|lp | listents|le | say <msg>");
            out.line(" kick <name> | ban <name> | version");
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
            const chat = try packages.buildStockChat(&self.body_buf, c.entity_id, msg);
            try self.broadcast("NetPackageChat", chat);
            out.line("sent");
        } else if (eqAny(verb, &.{"kick"})) {
            self.consoleKickBan(it.next(), &out, false);
        } else if (eqAny(verb, &.{"ban"})) {
            self.consoleKickBan(it.next(), &out, true);
        } else if (eqAny(verb, &.{"version"})) {
            out.line("zdtd 0.1.0 (V3.1.0 wire)");
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
        self.sim.transform[ps] = .{ .x = x, .y = y, .z = z, .yaw = 0 };
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
        const nid = if (def.kind == .animal)
            self.sim.spawnAnimal(t.x + 3, t.y, t.z + 3, def.max_hp, def.hash, def.loot_list)
        else
            self.sim.spawnZombieClass(t.x + 3, t.y, t.z + 3, def.max_hp, def.hash, def.loot_list);
        if (nid) |_| out.linef("spawned {s}", .{nm}) else out.line("spawn failed (capacity)");
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
        const next = ((clk.day / clk.bloodmoon_frequency) + 1) * clk.bloodmoon_frequency;
        return next - clk.day;
    }

    fn runAdminLine(self: *Game, line: []const u8) void {
        const cmd = admin_mod.parseCommand(line);
        switch (cmd) {
            .help => self.admin.reply("commands: help status save saveworld list listplayers|lp listents inv <slot> kick <slot> ban <slot> unban <iphex> give <slot> <item> [n] tele <slot> <x> <y> <z> say <msg> kill <id> killall spawnentity <slot|entityId> <class> gettime settime <day|night|ticks|D H M> version shutdown\n"),
            .unknown => self.admin.reply("unknown command. 'help' for list.\n"),
            .status => {
                var sb: [256]u8 = undefined;
                const s = std.fmt.bufPrint(&sb, "tick={d} players={d} zombies={d} chunks={d}\n", .{
                    self.tick_n,
                    self.countJoined(),
                    self.sim.countKind(.zombie),
                    self.world.chunks.count(),
                }) catch return;
                self.admin.reply(s);
            },
            .save => {
                self.savePlayers() catch {};
                self.world.saveAll() catch {};
                self.containers.save(self.world.world_dir) catch {};
                self.saveBlockMeta() catch {};
                self.admin.reply("saved\n");
            },
            .kick => |peer| {
                if (peer >= max_clients or self.clients[peer].peer == null) {
                    self.admin.reply("no player in slot\n");
                    return;
                }
                self.clients[peer].peer.?.alive = false;
                self.clearLocksForPeer(peer);
                self.clients[peer] = .{};
                self.admin.reply("kicked\n");
            },
            .ban => |peer| {
                if (peer >= max_clients or self.clients[peer].peer == null) {
                    self.admin.reply("no player in slot\n");
                    return;
                }
                const p = self.clients[peer].peer.?;
                self.banIp(peerIpKey(p));
                p.alive = false;
                self.clearLocksForPeer(peer);
                self.clients[peer] = .{};
                self.admin.reply("banned\n");
            },
            .unban => |ip| {
                self.unbanIp(ip);
                self.admin.reply("unbanned\n");
            },
            .list, .listplayers => {
                // Stock-ish: include id= so playtest orch re.findall(r"id\s*=\s*(\d+)") works.
                var n: usize = 0;
                for (&self.clients, 0..) |*cl, i| {
                    if (!cl.joined) continue;
                    var lb: [160]u8 = undefined;
                    const s = std.fmt.bufPrint(&lb, "{d}. id={d}, {s}, pos=(?, ?, ?), remote=False, health=100, slot={d}\n", .{
                        n, cl.entity_id, cl.name[0..cl.name_len], i,
                    }) catch continue;
                    self.admin.reply(s);
                    std.debug.print("zdtd: player {s}", .{s});
                    n += 1;
                }
                if (n == 0) self.admin.reply("Total of 0 in the game\n") else {
                    var tb: [48]u8 = undefined;
                    const s = std.fmt.bufPrint(&tb, "Total of {d} in the game\n", .{n}) catch "end\n";
                    self.admin.reply(s);
                }
            },
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
                self.admin.reply(msg);
            },
            .give => |g| {
                // Server-side inv writes get clobbered by the client's next C2S
                // PlayerInventory push. Stock-legal: drop a loot bag at the
                // player's feet; pickup runs the client-authoritative flow.
                const ps = self.sim.playerByPeer(g.peer) orelse {
                    self.admin.reply("no player in slot\n");
                    return;
                };
                const t = self.sim.transform[ps];
                if (self.sim.spawnLootBag(t.x + 1, t.y, t.z + 1, g.item, g.count)) |nid| {
                    self.broadcastLootSpawn(nid) catch {};
                    self.admin.reply("dropped at player\n");
                } else self.admin.reply("give failed\n");
            },
            .tele => |t| {
                if (self.sim.playerByPeer(t.peer)) |ps| {
                    self.sim.transform[ps] = .{ .x = t.x, .y = t.y, .z = t.z, .yaw = 0 };
                    self.admin.reply("teleported\n");
                } else self.admin.reply("no player in slot\n");
            },
            .say => |msg| {
                const body = packages.buildStockChat(&self.body_buf, 0, msg) catch return;
                self.broadcast("NetPackageChat", body) catch {};
                self.admin.reply("sent\n");
            },
            .gettime => {
                const clk = &self.sim.director.clock;
                var tb2: [64]u8 = undefined;
                const hh: u32 = @intFromFloat(clk.hours);
                const mm: u32 = @intFromFloat((clk.hours - @floor(clk.hours)) * 60.0);
                const s = std.fmt.bufPrint(&tb2, "Day {d}, {d:0>2}:{d:0>2}\n", .{ clk.day, hh, mm }) catch return;
                self.admin.reply(s);
            },
            .settime => |ti| {
                const clk = &self.sim.director.clock;
                if (ti.day > 0) clk.day = ti.day;
                clk.hours = @as(f32, @floatFromInt(ti.hour)) + @as(f32, @floatFromInt(ti.minute)) / 60.0;
                const wt = packages.buildWorldTimeBody(self.body_buf[0..16], clk.worldTimeBits()) catch return;
                self.broadcast("NetPackageWorldTime", wt) catch {};
                self.admin.reply("time set\n");
            },
            .spawnentity => |sp2| {
                const nm = self.admin_line[sp2.name_off..][0..sp2.name_len];
                const def = self.entities.byName(nm) orelse {
                    self.admin.reply("unknown entity class\n");
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
                    self.admin.reply("no player in slot\n");
                    return;
                };
                const tr = self.sim.transform[pslot];
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
                        break :blk self.sim.spawnVehicle(vk, tr.x + 5, tr.y, tr.z + 5);
                    }
                    if (def.kind == .trader or std.mem.startsWith(u8, nm, "npcTrader")) {
                        break :blk self.sim.spawnTrader(nm, tr.x + 5, tr.y, tr.z + 5);
                    }
                    if (def.kind == .animal) {
                        break :blk self.sim.spawnAnimal(tr.x + 5, tr.y, tr.z + 5, def.max_hp, def.hash, def.loot_list);
                    }
                    break :blk self.sim.spawnZombieClass(tr.x + 5, tr.y, tr.z + 5, def.max_hp, def.hash, def.loot_list);
                };
                if (nid != null) {
                    self.admin.reply("spawned\n");
                    std.debug.print("zdtd: admin spawnentity {s} near peerArg={d}\n", .{ nm, sp2.peer });
                } else self.admin.reply("spawn failed (capacity)\n");
            },
            .listents => {
                var ei: ecs.Slot = 0;
                while (ei < ecs.max_entities) : (ei += 1) {
                    if (!self.sim.alive[ei] or !self.sim.mask[ei].network_id) continue;
                    var lb2: [128]u8 = undefined;
                    const hp: f32 = if (self.sim.mask[ei].health) self.sim.health[ei].hp else 0;
                    const s = std.fmt.bufPrint(&lb2, "id={d} kind={s} hp={d:.0} pos=({d:.0},{d:.0},{d:.0})\n", .{
                        self.sim.network_id[ei].id,
                        @tagName(self.sim.kind[ei]),
                        hp,
                        self.sim.transform[ei].x,
                        self.sim.transform[ei].y,
                        self.sim.transform[ei].z,
                    }) catch continue;
                    self.admin.reply(s);
                }
                self.admin.reply("end\n");
            },
            .saveworld => {
                self.world.saveAll() catch {};
                self.containers.save(self.world.world_dir) catch {};
                self.saveBlockMeta() catch {};
                self.savePlayers() catch {};
                self.admin.reply("world saved\n");
            },
            .shutdown => {
                self.admin.reply("shutting down\n");
                self.running = false;
            },
            .version => self.admin.reply("zdtd 0.1.0 (V3.1.0 wire)\n"),
            .inv => |peer_slot| {
                const ps = self.sim.playerByPeer(peer_slot) orelse {
                    self.admin.reply("no player in slot\n");
                    return;
                };
                if (!self.sim.mask[ps].inventory) {
                    self.admin.reply("no inventory\n");
                    return;
                }
                for (self.sim.inventory[ps].slots, 0..) |s, si| {
                    if (s.count == 0) continue;
                    var lb: [96]u8 = undefined;
                    const out = std.fmt.bufPrint(&lb, "slot={d} item={d} count={d} q={d} meta={d}\n", .{
                        si, s.item_id, s.count, s.quality, s.meta,
                    }) catch continue;
                    self.admin.reply(out);
                }
                self.admin.reply("end\n");
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
                    self.admin.reply("kill missed\n");
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
                    self.admin.reply("player killed\n");
                    return;
                }
                const rm = packages.buildRemoveBody(&self.body_buf, eid) catch return;
                self.broadcast("NetPackageEntityRemove", rm) catch {};
                self.admin.reply("killed\n");
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
        // Drop clients whose LiteNet peer died (disconnect / timeout).
        for (&self.clients) |*c| {
            if (c.peer) |p| {
                if (!p.alive) c.* = .{};
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
                std.mem.writeInt(u64, c.challenge[0..8], self.challenge_counter, .little);
                std.mem.writeInt(u64, c.challenge[8..16], clock.monoNs(), .little);
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
        // loadedDecos on firstPackage=true; dropping that one NREs every later
        // incremental deco on the client.
        return std.mem.eql(u8, pkg_name, "NetPackageChunk") or std.mem.eql(u8, pkg_name, "NetPackageChunkRemove") or std.mem.eql(u8, pkg_name, "NetPackageDecoResetWorldChunk") or std.mem.eql(u8, pkg_name, "NetPackageEntityPosAndRot") or std.mem.eql(u8, pkg_name, "NetPackageEntitySpeeds") or std.mem.eql(u8, pkg_name, "NetPackageVehiclePositions") or std.mem.eql(u8, pkg_name, "NetPackageWorldTime");
    }

    fn sendGame(self: *Game, peer: *ln_peer.Peer, pkg_name: []const u8, body: []const u8) anyerror!void {
        const framed = try packages.framed(&self.send_buf, pkg_name, body);
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
                    peer.resendPending(&self.net.sock) catch {};
                    self.pollNetOnce();
                    if (attempts % 4 == 3) clock.sleepNs(500_000);
                    continue;
                },
                else => return err,
            };
            self.harness.counters.add(.net_packets_out, 1);
            self.harness.counters.add(.net_bytes_out, framed.len);
            // Drain a few ACKs so the next package does not immediately fill the window.
            self.pollNetOnce();
            return;
        }
        // Drop rather than fail the tick: WindowFull must not kill the dedi.
        std.debug.print("zdtd: drop {s} (reliable window full, droppable={})\n", .{ pkg_name, droppable });
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
        var s: ecs.Slot = 0;
        while (s < ecs.max_entities) : (s += 1) {
            if (!self.sim.alive[s] or self.sim.kind[s] != .zombie) continue;
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
                self.clearBlockHp(bx, by, bz);
                self.clearBlockRaw(bx, by, bz);
                self.world.setBlockWorld(bx, by, bz, 0) catch {};
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

    /// Mark an owner's claims online/offline (durability modifier switches).
    fn setClaimsOnline(self: *Game, owner_entity: i32, online: bool) void {
        for (self.land_claims[0..self.land_claims_n]) |*claim| {
            if (claim.owner_entity == owner_entity) claim.owner_online = online;
        }
    }

    /// Process pending UDP events (acks free window; data delivered to onData).
    fn pollNetOnce(self: *Game) void {
        var n: u32 = 0;
        while (n < 24) : (n += 1) {
            const ev = self.net.poll(&self.recv_buf) catch break;
            switch (ev) {
                // Best-effort: one bad peer must not stop the poll loop.
                .none => break,
                .connected => |p| self.onConnected(p) catch {},
                .data => |d| self.onData(d.peer, d.payload) catch {},
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
    fn saveBlockMeta(self: *const Game) !void {
        var path: [512]u8 = undefined;
        const p = try std.fmt.bufPrint(&path, "{s}/blockmeta.zbm", .{self.world.world_dir});
        var buf: [4096]u8 = undefined;
        var o: usize = 0;
        @memcpy(buf[0..4], "ZBM1");
        o = 4;
        std.mem.writeInt(u16, buf[o..][0..2], @intCast(self.block_raw_n), .little);
        o += 2;
        for (self.block_raw_key[0..self.block_raw_n], self.block_raw[0..self.block_raw_n]) |k, v| {
            if (o + 12 > buf.len) break;
            std.mem.writeInt(u64, buf[o..][0..8], k, .little);
            std.mem.writeInt(u32, buf[o + 8 ..][0..4], v, .little);
            o += 12;
        }
        if (o + 2 > buf.len) return error.WriteFailed;
        std.mem.writeInt(u16, buf[o..][0..2], @intCast(self.block_hp_n), .little);
        o += 2;
        for (self.block_hp_key[0..self.block_hp_n], self.block_hp[0..self.block_hp_n]) |k, v| {
            if (o + 10 > buf.len) break;
            std.mem.writeInt(u64, buf[o..][0..8], k, .little);
            std.mem.writeInt(u16, buf[o + 8 ..][0..2], v, .little);
            o += 10;
        }
        try io_fs.writeFile(self.allocator, p, buf[0..o]);
    }

    fn loadBlockMeta(self: *Game) !void {
        var path: [512]u8 = undefined;
        const p = try std.fmt.bufPrint(&path, "{s}/blockmeta.zbm", .{self.world.world_dir});
        const data = io_fs.readFileAll(self.allocator, p) catch return error.OpenFailed;
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
        var tr: @import("../wire/binary.zig").Reader = .{ .data = targets_blob };
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
                self.clearLocksForPeer(c.slot);
                c.* = .{};
                continue;
            }
            if (p.last_recv_ns == 0) continue;
            if (now -% p.last_recv_ns > stale_ns) {
                p.alive = false;
                p.authenticated = false;
                for (&p.pending) |*slot| slot.used = false;
                p.local_window_start = p.local_seq;
                self.clearLocksForPeer(c.slot);
                c.* = .{};
            }
        }
    }

    fn peerIpKey(peer: *const ln_peer.Peer) u32 {
        // sockaddr_in: family u16, port u16, addr u32 at offset 4 (linux).
        const bytes: *const [16]u8 = @ptrCast(&peer.addr);
        return std.mem.readInt(u32, bytes[4..8], .big);
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
        if (self.pumping) return; // no reentrant flood when onData sends mid-pump
        self.pumping = true;
        defer self.pumping = false;
        self.pollNetOnce();
    }

    fn onConnected(self: *Game, peer: *ln_peer.Peer) !void {
        const c = self.clientFor(peer) orelse return;
        peer.pump_fn = &pumpAcks;
        peer.pump_ctx = self;
        const ip = peerIpKey(peer);
        if (self.isBanned(ip)) {
            std.debug.print("zdtd: ban reject ip={x} local_id={d}\n", .{ ip, peer.local_id });
            peer.alive = false;
            c.* = .{};
            return;
        }
        if (self.joinRateLimited(ip)) {
            std.debug.print("zdtd: join rate-limit ip={x} local_id={d}\n", .{ ip, peer.local_id });
            self.harness.counters.inc(.join_fail);
            peer.alive = false;
            c.* = .{};
            return;
        }
        var ch: [17]u8 = undefined;
        wire_frame.buildChallenge(&ch, c.challenge);
        peer.sendReliable(&self.net.sock, &ch) catch |err| {
            std.debug.print("zdtd: challenge send failed: {}\n", .{err});
            return;
        };
        std.debug.print("zdtd: peer connected local_id={d} → challenge sent\n", .{peer.local_id});
    }

    fn onData(self: *Game, peer: *ln_peer.Peer, payload: []const u8) anyerror!void {
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
                peer.resendPending(&self.net.sock) catch {};
                std.debug.print("zdtd: challenge ok → PackageIds maps={d}\n", .{packages.default_mappings.len});
                // Replay any game payload that raced ahead of the challenge echo.
                if (c.preauth_len > 0) {
                    const saved = c.preauth_buf[0..c.preauth_len];
                    c.preauth_len = 0;
                    try self.dispatchGamePayload(c, peer, saved);
                }
            } else if (wire_frame.isChallenge(payload)) {
                std.debug.print("zdtd: challenge mismatch (len={d})\n", .{payload.len});
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
        var pkgs: [16]wire_frame.Package = undefined;
        const n = wire_frame.parseChannelPayload(payload, &pkgs);
        if (n == 0 and payload.len > 0) {
            var hex: [40]u8 = undefined;
            const show = @min(payload.len, 16);
            var hi: usize = 0;
            var bi: usize = 0;
            while (bi < show and hi + 2 <= hex.len) : (bi += 1) {
                const s = std.fmt.bufPrint(hex[hi..], "{x:0>2}", .{payload[bi]}) catch break;
                hi += s.len;
            }
            if (payload.len >= 9) {
                const psz = std.mem.readInt(i32, payload[1..5], .little);
                std.debug.print("zdtd: unparsed game payload len={d} head={s} ch={d} psz={d} comp={d} enc={d} cnt={d}\n", .{
                    payload.len,
                    hex[0..hi],
                    payload[0],
                    psz,
                    payload[5],
                    payload[6],
                    std.mem.readInt(u16, payload[7..9], .little),
                });
            } else {
                std.debug.print("zdtd: unparsed game payload len={d} head={s}\n", .{ payload.len, hex[0..hi] });
            }
            // Retry if payload omitted leading channel byte.
            if (payload.len >= 10) {
                var alt: [16]wire_frame.Package = undefined;
                var tmp: [8192]u8 = undefined;
                if (payload.len + 1 <= tmp.len) {
                    tmp[0] = 0;
                    @memcpy(tmp[1..][0..payload.len], payload);
                    const n2 = wire_frame.parseChannelPayload(tmp[0 .. payload.len + 1], &alt);
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
            .server_version = "V 3.1.0",
            .world_size = 6144,
            .eac_enabled = false,
        };
        return try serverinfo_tcp.buildInfoText(buf, info);
    }

    fn handlePackage(self: *Game, c: *Client, peer: *ln_peer.Peer, id: u16, body: []const u8) !void {
        if (id >= packages.default_mappings.len) {
            std.debug.print("zdtd: unmapped pkg id={d} body={d}\n", .{ id, body.len });
            return;
        }
        const name = packages.default_mappings[id];
        // Quiet high-frequency packages (animation floods the log + reliable window).
        const quiet = std.mem.eql(u8, name, "NetPackageEntityAnimationData") or std.mem.eql(u8, name, "NetPackageEntityPosAndRot") or std.mem.eql(u8, name, "NetPackageEntityRelPosAndRot") or std.mem.eql(u8, name, "NetPackageHoldingItem") or std.mem.eql(u8, name, "NetPackageEntitySpeeds") or std.mem.eql(u8, name, "NetPackageEntityAliveFlags") or std.mem.eql(u8, name, "NetPackageAudio") or std.mem.eql(u8, name, "NetPackageAddRemoveBuff") or std.mem.eql(u8, name, "NetPackagePlayerStats") or std.mem.eql(u8, name, "NetPackageDiscordIdMappings");
        if (!quiet) {
            std.debug.print("zdtd: pkg {s} body={d} entity={d} joined={}\n", .{ name, body.len, c.entity_id, c.joined });
        }
        const sp = self.world.primarySpawn();

        // Join-phase gate: pre-login peers may only speak the login/config
        // handshake. World/entity/inv mutations from an unjoined peer are dropped
        // in Correct mode (default). Observe logs and still drops (phase is Hard).
        if (!c.joined) {
            const pre_login_ok = std.mem.eql(u8, name, "NetPackagePlayerLogin") or std.mem.eql(u8, name, "NetPackageRequestToEnterGame") or std.mem.eql(u8, name, "NetPackageRequestToSpawnPlayer") or std.mem.eql(u8, name, "NetPackageAuthConfirmation") or std.mem.eql(u8, name, "NetPackageSignDataRequest") or std.mem.eql(u8, name, "NetPackageWorldInitInfoRequest") or std.mem.eql(u8, name, "NetPackageDynamicClientArrive") or std.mem.eql(u8, name, "NetPackagePlayerDisconnect");
            if (!pre_login_ok) {
                // Phase gate is always Hard (never apply play C2S pre-join).
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
            // parse name for save key (first string in login body)
            if (body.len > 1) {
                var r: @import("../wire/binary.zig").Reader = .{ .data = body };
                if (r.readString(c.name[0..])) |nm| {
                    c.name_len = @min(nm.len, c.name.len);
                    if (nm.ptr != &c.name) @memcpy(c.name[0..c.name_len], nm[0..c.name_len]);
                } else |_| {}
            }
            const ans = try packages.buildLoginAnswerBody(self.body_buf[0..2048], true, gsi);
            try self.sendGame(peer, "NetPackagePlayerLoginAnswer", ans);
            const surf0 = self.spawnSurface(sp.x, sp.z);
            const eid = self.sim.spawnPlayer(@floatFromInt(surf0.x), @floatFromInt(surf0.y), @floatFromInt(surf0.z), @intCast(c.slot)) orelse return;
            c.entity_id = eid;
            c.joined = true;
            c.view_radius = self.view_radius;
            self.tryRestorePlayer(c);
            // Stock: LoginAnswer only. Configs must arrive after StartAsClient starts
            // WaitForConfigsFromServer (which resets WasReceivedFromServer). That is
            // after RequestToEnterGame is sent from the client.
            self.refreshInfoPlayers();
            self.harness.counters.inc(.join_ok);
            std.debug.print("zdtd: PlayerLogin name={s} entity={d} body={d}\n", .{ c.name[0..c.name_len], eid, body.len });
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
            try self.sendLocalConfigFiles(peer);
            const wi = try packages.buildWorldInfoBody(self.body_buf[0..256], self.world_name, 6144, 6144, sp.x, sp.y, sp.z, 0);
            try self.sendGame(peer, "NetPackageWorldInfo", wi);
            try self.sendWorldSpawnPoints(peer);
            const wt = try packages.buildWorldTimeBody(self.body_buf[1024..1040], self.sim.director.clock.worldTimeBits());
            try self.sendGame(peer, "NetPackageWorldTime", wt);
            try self.sendGameStats(peer);
            // NetPackageWeather: only after client WeatherManager.InitPackages (post-enter).
            // Early send → NCSimple "parsed 2 vs expected 117" and disconnect.
            // Fixed-size clients only apply grass/trees from S2C deco (no local random gen).
            // firstPackage=true before/during OnWorldLoaded marks deco chunks decorated.
            try self.sendDecoAroundSpawn(peer, sp.x, sp.z, true);
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
            const wi = try packages.buildWorldInitInfoEmpty(self.body_buf[0..16]);
            try self.sendGame(peer, "NetPackageWorldInitInfo", wi);
            std.debug.print("zdtd: WorldInitInfoRequest -> empty entity={d}\n", .{c.entity_id});
            return;
        }
        // createWorld posts DynamicClientArrive. Stock then DoSpawn → RequestToSpawnPlayer;
        // that package often fails our envelope parse (seen as unparsed ~102B). Treat
        // DynamicClientArrive as the spawn trigger and send the join bundle (PlayerId…).
        if (std.mem.eql(u8, name, "NetPackageDynamicClientArrive")) {
            const wi = try packages.buildWorldInitInfoEmpty(self.body_buf[0..16]);
            try self.sendGame(peer, "NetPackageWorldInitInfo", wi);
            std.debug.print("zdtd: DynamicClientArrive -> WorldInitInfo empty entity={d}\n", .{c.entity_id});
            if (!c.entered and c.entity_id > 0) {
                c.view_radius = if (c.view_radius < 1) self.view_radius else c.view_radius;
                try self.sendJoinBundle(c, peer, sp.x, sp.y, sp.z, c.entity_id);
                std.debug.print("zdtd: DynamicClientArrive -> join bundle (spawn) entity={d}\n", .{c.entity_id});
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
                    self.sim.alive[si] = true;
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
            // Death-respawn already sent Spawned+stats; still re-send join bundle so the
            // client re-enters IsSpawned (playtest saw hp=100 but IsSpawned=false without it).
            try self.sendJoinBundle(c, peer, surf.x, surf.y, surf.z, c.entity_id);
            return;
        }
        if (std.mem.eql(u8, name, "NetPackageEntityPosAndRot")) {
            const p = packages.parsePosAndRotBody(body) catch return;
            if (p.entity_id == c.entity_id) {
                // Void rescue only (aggressive float snap desynced client mesh vs
                // server height and broke dig/sample rings). Dig pad is fixed by
                // authoritative SetBlock echo instead.
                if (p.y < -4) {
                    const gx: i32 = @intFromFloat(p.x);
                    const gz: i32 = @intFromFloat(p.z);
                    const h: f32 = @floatFromInt(self.world.heightWorld(gx, gz) catch @as(u8, @intCast(self.world.primarySpawn().y)));
                    const ny = h + 1.08;
                    self.sim.setPos(p.entity_id, p.x, ny, p.z, 0);
                    if (packages.buildEntityTeleportBody(&self.body_buf, p.entity_id, p.x, ny, p.z, 0, 0, 0, true)) |tb| {
                        try self.sendGame(peer, "NetPackageEntityTeleport", tb);
                    } else |_| {}
                    std.debug.print("zdtd: void rescue entity={d} y={d:.0} -> {d:.0}\n", .{ p.entity_id, p.y, ny });
                    return;
                }
                self.sim.setPos(p.entity_id, p.x, p.y, p.z, 0);
                systems.questTickGoto(&self.sim, c.slot, p.x, p.y, p.z);
                systems.questTickStayWithin(&self.sim, c.slot, p.x, p.z);
                // Proximity vacuum without wire leaves ghost EntityItems on clients.
                // Collect only on explicit NetPackageEntityCollect (stock path).
            }
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
                        if (self.sim.mask[ps].inventory and self.sim.mask[bs].inventory) {
                            for (self.sim.inventory[bs].slots) |slot| {
                                if (slot.count == 0 or slot.item_id == 0) continue;
                                _ = self.sim.inventory[ps].addItem(slot.item_id, slot.count);
                            }
                        }
                    }
                    if (self.sim.alive[bs]) self.sim.destroy(bs);
                }
            }
            if (packages.buildEntityCollectBody(self.body_buf[0..16], bag, c.entity_id)) |cb| {
                try self.broadcast("NetPackageEntityCollect", cb);
            } else |_| {}
            if (packages.buildRemoveBodyReason(&self.body_buf, bag, .despawned)) |rm| {
                try self.broadcast("NetPackageEntityRemove", rm);
            } else |_| {}
            return;
        }
        // Stock chat: rebroadcast Global messages to all peers.
        if (std.mem.eql(u8, name, "NetPackageChat") or std.mem.eql(u8, name, "NetPackageSimpleChat")) {
            if (std.mem.eql(u8, name, "NetPackageChat")) {
                const ch = packages.parseStockChat(body) catch {
                    try self.broadcastExcept("NetPackageChat", body, c.slot);
                    return;
                };
                _ = ch;
                try self.broadcastExcept("NetPackageChat", body, c.slot);
            } else {
                // Upgrade simple chat to stock Chat when possible
                var r: @import("../wire/binary.zig").Reader = .{ .data = body };
                var from_buf: [64]u8 = undefined;
                var msg_buf: [256]u8 = undefined;
                const from = r.readString(&from_buf) catch "";
                const msg = r.readString(&msg_buf) catch return;
                _ = from;
                const stock = try packages.buildStockChat(self.body_buf[0..512], c.entity_id, msg);
                try self.broadcast("NetPackageChat", stock);
            }
            return;
        }
        // Stock vanilla C→S: client pushes inventory sections (toolbelt/bag/equip).
        if (std.mem.eql(u8, name, "NetPackagePlayerInventory")) {
            const ps = self.sim.playerByPeer(c.slot) orelse return;
            if (!self.sim.mask[ps].inventory) return;
            packages.stock_inv.applyPlayerInventoryBody(body, &self.sim.inventory[ps], reverseItemType, self) catch return;
            // Apply only; do not echo PlayerInventory S2C (stock rejects that direction).
            return;
        }
        if (std.mem.eql(u8, name, "NetPackageHoldingItem")) {
            const h = packages.stock_inv.readHoldingItem(body) catch return;
            if (h.entity_id != 0 and h.entity_id != c.entity_id) return;
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
            if (dropped <= 0) {
                if (self.sim.spawnLootBag(d.x, d.y, d.z, item_id, d.stack.count)) |nid| {
                    dropped = nid;
                }
            }
            if (dropped > 0) {
                // Stock ItemDropServer → EntityItem (class "item"), not death bag.
                try self.broadcastItemDropSpawn(dropped, d.stack, c.entity_id, d.client_instance_id);
                try self.sendHoldingEcho(peer, c);
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
            } else if (self.sim.slotOfNetId(entity_id)) |si| {
                // Ownership: never let a peer write another player's inventory.
                if (self.sim.mask[si].player) return;
                if (self.sim.mask[si].inventory) {
                    _ = packages.stock_inv.applyBagPackage(body, &self.sim.inventory[si], reverseItemType, self, false) catch return;
                }
            } else return;
            try self.sendHoldingEcho(peer, c);
            return;
        }
        if (std.mem.eql(u8, name, "NetPackageDropItemsContainer")) {
            const d = packages.stock_inv.readDropItemsContainer(body) catch return;
            if (d.item_count == 0) return;
            // Spawn one loot bag with first stack; fold remaining into same bag if possible.
            const first_id = reverseItemType(self, d.items[0].type_id);
            if (first_id == 0) return;
            const nid = self.sim.spawnLootBag(d.x, d.y, d.z, first_id, d.items[0].count) orelse return;
            if (self.sim.slotOfNetId(nid)) |si| {
                var i: usize = 1;
                while (i < d.item_count) : (i += 1) {
                    const iid = reverseItemType(self, d.items[i].type_id);
                    if (iid == 0 or d.items[i].count == 0) continue;
                    _ = self.sim.inventory[si].addItem(iid, d.items[i].count);
                }
            }
            try self.broadcastLootSpawn(nid);
            try self.sendHoldingEcho(peer, c);
            return;
        }
        // Stock composite storage TE and/or zdtd ZTE1 bridge.
        if (std.mem.eql(u8, name, "NetPackageTileEntity")) {
            if (stock_te.parseStorageTeBody(body)) |parsed| {
                // Reach: TE writes must be near the acting player (cross-map chest
                // overwrite + container-store fill guard).
                const owner = self.sim.playerByPeer(c.slot) orelse return;
                const op = self.sim.transform[owner];
                const tdx = @as(f32, @floatFromInt(parsed.world_x)) - op.x;
                const tdy = @as(f32, @floatFromInt(parsed.world_y)) - op.y;
                const tdz = @as(f32, @floatFromInt(parsed.world_z)) - op.z;
                if (tdx * tdx + tdy * tdy + tdz * tdz > self.max_edit_range * self.max_edit_range) return;
                const pos: containers_mod.PosKey = .{ .x = parsed.world_x, .y = parsed.world_y, .z = parsed.world_z };
                const sc: u16 = if (parsed.size_x > 0 and parsed.size_y > 0)
                    @intCast(@min(@as(usize, parsed.size_x) * @as(usize, parsed.size_y), containers_mod.max_container_slots))
                else
                    @intCast(@max(parsed.item_count, 8));
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
                if (wdx * wdx + wdy * wdy + wdz * wdz > self.max_edit_range * self.max_edit_range) return;
                if (self.workstations.getOrCreate(ws.world_x, ws.world_y, ws.world_z)) |st| {
                    applyWsGroup(self, st.fuel[0..], ws.fuel[0..ws.fuel_n]);
                    applyWsGroup(self, st.input[0..], ws.input[0..ws.input_n]);
                    applyWsGroup(self, st.tools[0..], ws.tools[0..ws.tools_n]);
                    applyWsGroup(self, st.output[0..], ws.output[0..ws.output_n]);
                    st.queue_n = ws.queue_n;
                    @memcpy(st.queue[0..ws.queue_n], ws.queue[0..ws.queue_n]);
                    st.is_burning = ws.is_burning;
                    st.burn_time_left = ws.burn_time_left;
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
            // Unparsed TE payload: drop (stock formats only).
            return;
        }
        if (std.mem.eql(u8, name, "NetPackageInventoryTransactionRequest")) {
            const tx = packages.parseInvTxRequest(body) catch return;
            var r: invsys.Result = .{};
            if (tx.op == @intFromEnum(invsys.Op.craft)) {
                r = .{ .ok = self.tryCraft(c.slot, tx.a, if (tx.qty == 0) 1 else tx.qty) };
            } else {
                const op: invsys.Op = if (tx.op <= @intFromEnum(invsys.Op.equip))
                    @enumFromInt(tx.op)
                else
                    .list;
                r = invsys.applyTransaction(&self.sim, c.slot, op, tx.a, tx.b, tx.qty, tx.entity_id);
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
                    if (self.sim.mask[si].inventory) {
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
            if (body.len < 20 or c.entity_id <= 0) return;
            const eid = std.mem.readInt(i32, body[0..4], .little);
            if (eid != c.entity_id) return;
            const dx = std.mem.readInt(i16, body[11..13], .little);
            const dy = std.mem.readInt(i16, body[13..15], .little);
            const dz = std.mem.readInt(i16, body[15..17], .little);
            if (self.sim.slotOfNetId(eid)) |idx| {
                self.sim.transform[idx].x += @as(f32, @floatFromInt(dx)) * 0.03125;
                self.sim.transform[idx].y += @as(f32, @floatFromInt(dy)) * 0.03125;
                self.sim.transform[idx].z += @as(f32, @floatFromInt(dz)) * 0.03125;
            }
            return;
        }
        if (std.mem.eql(u8, name, "NetPackageEntityAliveFlags")) {
            const f = packages.parseAliveFlagsBody(body) catch return;
            if (f.entity_id != c.entity_id) return;
            if (self.sim.slotOfNetId(f.entity_id)) |idx| self.sim.flags[idx].bits = f.flags;
            // Fan-out to other peers (stock tracked-players path).
            try self.broadcastExcept("NetPackageEntityAliveFlags", body, c.slot);
            return;
        }
        // Stock C2S player motion speeds; rebroadcast to other clients.
        if (std.mem.eql(u8, name, "NetPackageEntitySpeeds")) {
            const s = packages.parseEntitySpeedsBody(body) catch return;
            if (s.entity_id != c.entity_id) return;
            try self.broadcastExcept("NetPackageEntitySpeeds", body, c.slot);
            return;
        }
        // Stock hard teleport (same wire as PosAndRot). Apply + fan-out.
        if (std.mem.eql(u8, name, "NetPackageEntityTeleport")) {
            const p = packages.parsePosAndRotBody(body) catch return;
            if (p.entity_id != c.entity_id) return;
            self.sim.setPos(p.entity_id, p.x, p.y, p.z, 0);
            try self.broadcastExcept("NetPackageEntityTeleport", body, c.slot);
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
                if (head.quest_id.len > 0) {
                    if (self.sim.catalog.byName(head.quest_id)) |d| {
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
        // Party / ally: echo C2S so client UI unblocks (full PlatformUser wire deferred).
        if (std.mem.eql(u8, name, "NetPackagePartyActions") or std.mem.eql(u8, name, "NetPackagePartyData") or std.mem.eql(u8, name, "NetPackageAllyRequest") or std.mem.eql(u8, name, "NetPackageAllyResponse")) {
            try self.sendGame(peer, name, body);
            return;
        }
        // Stock SavePlayerData: PDF WriteNetwork (ECD + toolbelt/bag + meta tail).
        if (std.mem.eql(u8, name, "NetPackagePlayerData")) {
            const ps = self.sim.playerByPeer(c.slot);
            if (ps) |slot| {
                if (self.sim.mask[slot].inventory) {
                    if (packages.stock_inv.applyPlayerDataNetwork(body, &self.sim.inventory[slot], reverseItemType, self)) |h| {
                        if (h.entity_id == c.entity_id or c.entity_id <= 0) {
                            if (c.entity_id <= 0) c.entity_id = h.entity_id;
                            // Do NOT apply ECD pos: client PDF pos is Unity-origin
                            // relative after Origin Reposition (y=0 artifacts);
                            // PosAndRot is the world-space source of truth.
                        }
                        std.debug.print("zdtd: PlayerData save entity={d} pos=({d:.1},{d:.1},{d:.1}) inv_slots={d} body={d}\n", .{
                            h.entity_id, h.x, h.y, h.z, h.inv_slots, body.len,
                        });
                    } else |_| {
                        // Fall back to ECD head only.
                        if (packages.parsePlayerDataEcdHead(body)) |h| {
                            _ = h; // pos unreliable (origin-relative); ignore
                            std.debug.print("zdtd: PlayerData ecd-only body={d}\n", .{body.len});
                        } else |_| {
                            std.debug.print("zdtd: PlayerData body={d} (parse skip)\n", .{body.len});
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
        // Client local buff apply / audio noise: accept, no sim yet.
        if (std.mem.eql(u8, name, "NetPackageAddRemoveBuff") or std.mem.eql(u8, name, "NetPackageAudio") or std.mem.eql(u8, name, "NetPackagePlayerStats") or std.mem.eql(u8, name, "NetPackageDiscordIdMappings")) {
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
                self.sendGame(peer, "NetPackageGameEventResponse", resp) catch {};
            } else |_| {}
            return;
        }
        // Quest-spawned enemy: client asks server to spawn from a quest group.
        // Body: playerEntityId i32 | groupName str | count i32. Spawn `count`
        // default zombies near the player (full gamestage group roll deferred).
        if (std.mem.eql(u8, name, "NetPackageQuestEntitySpawn")) {
            var r: @import("../wire/binary.zig").Reader = .{ .data = body };
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
        // Client-requested entity spawn (RequestToSpawnEntity, thrown items /
        // dropped bags): parse the ECD and spawn a loot bag at its pos so peers
        // see it. Full ECD entity fidelity deferred.
        if (std.mem.eql(u8, name, "NetPackageRequestToSpawnEntity")) {
            if (packages.parsePlayerDataEcdHead(body)) |h| {
                if (self.sim.spawnLootBag(h.x, h.y, h.z, 1, 1)) |nid|
                    self.broadcastLootSpawn(nid) catch {};
            } else |_| {}
            return;
        }
        // In-game console (F1): execute a set of server commands for the sender.
        if (std.mem.eql(u8, name, "NetPackageConsoleCmdServer")) {
            self.handleConsoleCmd(peer, c, body) catch {};
            return;
        }
        // Prefab editor volume: not part of the play path under EAC-off; drop.
        if (std.mem.eql(u8, name, "NetPackageEditorAddVolumeFromClient")) {
            return;
        }
        if (std.mem.eql(u8, name, "NetPackageDamageEntity")) {
            const d = packages.parseDamageHead(body) catch return;
            const was_zombie = blk: {
                if (self.sim.slotOfNetId(d.entity_id)) |ei|
                    break :blk self.sim.kind[ei] == .zombie or self.sim.kind[ei] == .animal;
                break :blk false;
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
            const dmg = self.sim.damage(d.entity_id, amount);
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
                        var tr: @import("../wire/binary.zig").Reader = .{ .data = req.targets_blob };
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
            var changes: [32]packages.BlockChange = undefined;
            const n = packages.parseSetBlockChanges(body, changes[0..]) catch {
                std.debug.print("zdtd: SetBlock parse fail body={d}\n", .{body.len});
                return;
            };
            if (n == 0) return;
            const editor = self.sim.playerByPeer(c.slot) orelse return;
            const ep = self.sim.transform[editor];
            const editor_ent = self.sim.network_id[editor].id;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const b = changes[i];
                const dx = @as(f32, @floatFromInt(b.x)) - ep.x;
                const dy = @as(f32, @floatFromInt(b.y)) - ep.y;
                const dz = @as(f32, @floatFromInt(b.z)) - ep.z;
                if (dx * dx + dy * dy + dz * dz > self.max_edit_range * self.max_edit_range) {
                    if (self.authorityCorrects()) {
                        std.debug.print("zdtd: SetBlock out of reach ({d},{d},{d}) player=({d:.0},{d:.0},{d:.0})\n", .{ b.x, b.y, b.z, ep.x, ep.y, ep.z });
                        continue;
                    }
                    // Observe: still reject reach (Hard invariant); log only difference later.
                    continue;
                }
                if (self.claimCovering(b.x, b.z)) |claim| {
                    if (claim.owner_entity != editor_ent) continue;
                }
                const cur_id = self.world.blockWorld(b.x, b.y, b.z) catch 0;
                const cur_dmg = self.getBlockHp(b.x, b.y, b.z);
                var place_id: u16 = b.block_id;
                var out_dmg: u16 = 0;
                var mutated = false;

                if (b.block_id == 0) {
                    place_id = 0;
                    out_dmg = 0;
                    self.clearBlockHp(b.x, b.y, b.z);
                    mutated = true;
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
                    if (packages.buildSetBlockBodyDamage(
                        self.body_buf[0..96],
                        b.x,
                        b.y,
                        b.z,
                        place_id,
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
            // Only accept from joined players; ignore entity_id spoof if mismatch.
            if (ex.entity_id > 0 and c.entity_id > 0 and ex.entity_id != c.entity_id) return;
            const rad: i32 = @intFromFloat(@max(1, @min(ex.radius, 6)));
            // Reach: explosion center must be near the acting player.
            if (self.sim.playerByPeer(c.slot)) |bi| {
                const bp = self.sim.transform[bi];
                const dx = ex.wx - bp.x;
                const dy = ex.wy - bp.y;
                const dz = ex.wz - bp.z;
                if (dx * dx + dy * dy + dz * dz > self.max_edit_range * self.max_edit_range) return;
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
                        self.world.setBlockWorld(wx, wy, wz, 0) catch {};
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
                    _ = systems.vehicleEnter(&self.sim, vi, c.entity_id);
                    if (packages.buildEntityAttach(self.body_buf[0..16], .attach_server, c.entity_id, vc.entity_id, 0)) |ab| {
                        try self.broadcast("NetPackageEntityAttach", ab);
                    } else |_| {}
                } else if (vc.op == 1) {
                    _ = systems.vehicleExit(&self.sim, c.entity_id);
                    if (packages.buildEntityAttach(self.body_buf[0..16], .detach_server, c.entity_id, vc.entity_id, 0)) |ab| {
                        try self.broadcast("NetPackageEntityAttach", ab);
                    } else |_| {}
                } else if (vc.op == 2) {
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
                    _ = systems.vehicleExit(&self.sim, c.entity_id);
                } else {
                    _ = systems.vehicleEnter(&self.sim, vi, c.entity_id);
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

    fn sendVehicleAndTurretJoin(self: *Game, peer: *ln_peer.Peer) !void {
        var i: ecs.Slot = 0;
        while (i < ecs.max_entities) : (i += 1) {
            if (self.sim.alive[i] and self.sim.mask[i].vehicle) {
                var o: usize = 0;
                std.mem.writeInt(i32, self.body_buf[o..][0..4], self.sim.network_id[i].id, .little);
                o += 4;
                self.body_buf[o] = @intFromEnum(self.sim.vehicle[i].kind);
                o += 1;
                inline for (.{ self.sim.transform[i].x, self.sim.transform[i].y, self.sim.transform[i].z, self.sim.transform[i].yaw, self.sim.vehicle[i].speed, self.sim.vehicle[i].fuel }) |f| {
                    std.mem.writeInt(u32, self.body_buf[o..][0..4], @as(u32, @bitCast(f)), .little);
                    o += 4;
                }
                std.mem.writeInt(i32, self.body_buf[o..][0..4], self.sim.vehicle[i].driver_net_id, .little);
                o += 4;
                try self.sendGame(peer, "NetPackageVehicleSpawn", self.body_buf[0..o]);
                break;
            }
        }
        // TurretSync stock layout is entityId+targetId+isOn+ItemValue: not our SoA blob.
        // Do not send a non-stock body (crashes NCSimple_Deserializer on client).
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
            var w: @import("../wire/binary.zig").Writer = .{ .buf = self.body_buf[0..] };
            try w.writeString(name);
            try w.writeI32(-1); // null payload => EClientFileState.LoadLocal
            try self.sendGame(peer, "NetPackageConfigFile", w.written());
            peer.resendPending(&self.net.sock) catch {};
            self.pollNetOnce();
        }
    }

    /// Align spawn to DTM height and ensure a solid under the feet block so
    /// dig/place sample rings (BlockUnderFeet) see terrain, not air.
    fn spawnSurface(self: *Game, sx: i32, sz: i32) struct { x: i32, y: i32, z: i32 } {
        const fallback: u8 = @intCast(@max(1, self.world.primarySpawn().y));
        const h_u8: u8 = self.world.heightWorld(sx, sz) catch fallback;
        const h: i32 = @intCast(h_u8);
        // heightWorld is surface top; feet stand on that block, player PDF Y = surface.
        const feet_y = if (h > 1) h else 1;
        const under = self.world.blockWorld(sx, feet_y, sz) catch 0;
        if (under == 0) {
            const dirt = world_store.block_dirt;
            self.world.setBlockWorld(sx, feet_y, sz, dirt) catch {};
        }
        // Standing Y for entity is surface + small offset; PDF uses block Y of feet surface.
        return .{ .x = sx, .y = feet_y, .z = sz };
    }

    fn sendJoinBundle(self: *Game, c: *Client, peer: *ln_peer.Peer, sx: i32, sy: i32, sz: i32, eid: i32) !void {
        // Snap to solid surface (callers may pass raw primarySpawn Y that floats above DTM).
        const surf = self.spawnSurface(sx, sz);
        const sx2 = surf.x;
        const sy2 = surf.y;
        const sz2 = surf.z;
        // Do NOT re-send WorldInfo: second WorldInfo restarts createWorld mid-session → NRE flood.
        // Order: PlayerId (spawn pos in PDF) → id map → optional join chunk → Spawned → time.
        // First join: bLoaded=true so ToPlayer applies bag. Death re-bundle: false.
        const first_join = !c.entered;
        c.entered = true;
        const dim: i32 = if (c.view_radius < 1) self.view_radius else c.view_radius;
        // Server journal + stock PDF Quest.Write (RewardItem includes ItemStack).
        _ = systems.questAcceptStarter(&self.sim, c.slot);
        var qbuf: [2]packages.stock_quest.StockQuestWrite = undefined;
        var reward_store: [2][ecs.quest.max_reward_flags]packages.stock_quest.RewardWire = undefined;
        var obj_val_store: [2][ecs.quest.max_phases]u8 = undefined;
        const qn = self.fillStockJournalWrites(c.slot, &qbuf, &reward_store, &obj_val_store);
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
            );
            try self.sendGame(peer, "NetPackagePlayerId", pid);
            // PersistentPlayerState(Login): entityId → name mapping. Without it the
            // client shows GMSG "Player '' joined" and party UI has no names.
            {
                var sid_buf: [24]u8 = undefined;
                const sid = std.fmt.bufPrint(&sid_buf, "7656119{d:0>10}", .{@as(u32, @intCast(eid))}) catch "76561190000000000";
                if (packages.stock_inv.buildPersistentPlayerState(
                    self.body_buf[8704..9216],
                    eid,
                    c.name[0..c.name_len],
                    sid,
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
            try self.sendStockEntitySpawns(peer, c, sx, sz);
            if (self.wire_chunks) {
                const r: i32 = if (c.view_radius < 1) self.chunk_stream_radius_min else @min(c.view_radius, self.chunk_stream_radius_max);
                try self.sendSpawnArea(peer, sx2, sz2, r);
            }
            // Stock multiplayer join uses EnterMultiplayer (4), not NewGame (0).
            const spawned = try packages.buildSpawnedBody(
                self.body_buf[256..384],
                @intFromEnum(packages.RespawnType.enter_multiplayer),
                sx,
                sy,
                sz,
                eid,
            );
            try self.sendGame(peer, "NetPackagePlayerSpawnedInWorld", spawned);
        } else {
            // Death re-bundle: never re-send PlayerId (CreateEntity NREs). Re-send
            // Spawned(died) so client IsSpawned latches; refresh vitals/teleport.
            const spawned = try packages.buildSpawnedBody(
                self.body_buf[256..384],
                @intFromEnum(packages.RespawnType.died),
                sx,
                sy,
                sz,
                eid,
            );
            try self.sendGame(peer, "NetPackagePlayerSpawnedInWorld", spawned);
            if (packages.buildEntityTeleportBody(&self.body_buf, eid, @floatFromInt(sx), @floatFromInt(sy), @floatFromInt(sz), 0, 0, 0, true)) |tb| {
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
    fn fillStockJournalWrites(
        self: *Game,
        peer_slot: usize,
        out: []packages.stock_quest.StockQuestWrite,
        reward_store: *[2][ecs.quest.max_reward_flags]packages.stock_quest.RewardWire,
        obj_val_store: *[2][ecs.quest.max_phases]u8,
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
            out[n] = .{
                .id = d.name,
                .state = state,
                .quest_code = qcode,
                .current_phase = phase,
                .objective_count = d.objective_count,
                .first_objective_value = prog,
                .objective_values = obj_vals,
                .rewards = reward_store[n][0..rc],
                .has_location = d.kind == .goto_point or d.kind == .kill_zombies or d.kind == .fetch_item,
                .loc_x = if (d.kind == .goto_point) d.tx else self.sim.transform[ps].x,
                .loc_y = if (d.kind == .goto_point) d.ty else self.sim.transform[ps].y,
                .loc_z = if (d.kind == .goto_point) d.tz else self.sim.transform[ps].z,
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
    fn sendStockEntitySpawns(self: *Game, peer: *ln_peer.Peer, c: *Client, px: i32, pz: i32) !void {
        const range: f32 = 96;
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
            const dx = self.sim.transform[i].x - pfx;
            const dz = self.sim.transform[i].z - pfz;
            if (dx * dx + dz * dz > range * range) continue;
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
        if (self.sim.slotOfNetId(eid)) |si| {
            if (self.sim.mask[si].health) {
                hp = self.sim.health[si].hp;
                max_hp = self.sim.health[si].max_hp;
            }
        }
        const stats = [_]struct { packages.EntityStatKind, f32, f32 }{
            .{ .health, hp, max_hp },
            .{ .stamina, 100, 100 },
            .{ .food, 100, 100 },
            .{ .water, 100, 100 },
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
        var w: @import("../wire/binary.zig").Writer = .{ .buf = &map_buf };
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
    fn sendHoldingOnly(self: *Game, peer: *ln_peer.Peer, c: *Client) !void {
        const ps = self.sim.playerByPeer(c.slot) orelse return;
        if (!self.sim.mask[ps].inventory) return;
        const hb = try packages.buildHoldingBodyResolved(
            self.body_buf[6144..6272],
            c.entity_id,
            &self.sim.inventory[ps],
            resolveItemType,
            self,
        );
        try self.sendGame(peer, "NetPackageHoldingItem", hb);
    }

    /// Post-change inv echo. PlayerInventory/Bag are ToServer-only for stock
    /// clients; only HoldingItem is a valid S2C echo.
    fn sendHoldingEcho(self: *Game, peer: *ln_peer.Peer, c: *Client) !void {
        try self.sendHoldingOnly(peer, c);
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

    /// Craft recipe by index into recipes.defs (InvTx craft op). Consumes ingredients, grants output.
    fn tryCraft(self: *Game, peer_slot: usize, recipe_index: u16, times: u16) bool {
        if (recipe_index >= self.recipes.defs.len) return false;
        return self.tryCraftRecipe(peer_slot, self.recipes.defs[recipe_index], times);
    }

    /// Craft by stock recipe name (e.g. meleeWpnClubT0WoodenClub).
    fn tryCraftByName(self: *Game, peer_slot: usize, recipe_name: []const u8, times: u16) bool {
        const recipe = self.recipes.byName(recipe_name) orelse return false;
        return self.tryCraftRecipe(peer_slot, recipe, times);
    }

    fn tryCraftRecipe(self: *Game, peer_slot: usize, recipe: assets_recipes.RecipeDef, times: u16) bool {
        const ps = self.sim.playerByPeer(peer_slot) orelse return false;
        if (!self.sim.mask[ps].inventory) return false;
        const n: u16 = if (times == 0) 1 else @min(times, 20);
        var need: [assets_recipes.max_ingredients]struct { id: u16, count: u32 } = undefined;
        var nn: usize = 0;
        var i: u8 = 0;
        while (i < recipe.ingredient_n) : (i += 1) {
            const ing = recipe.ingredients[i];
            const id = self.ecsIdFromItemName(ing.name);
            if (id == 0) return false;
            need[nn] = .{ .id = id, .count = @as(u32, ing.count) * n };
            nn += 1;
        }
        var j: usize = 0;
        while (j < nn) : (j += 1) {
            if (self.sim.inventory[ps].countItem(need[j].id) < need[j].count) return false;
        }
        j = 0;
        while (j < nn) : (j += 1) {
            if (!self.sim.inventory[ps].removeItem(need[j].id, @intCast(need[j].count))) return false;
        }
        const out_id = self.ecsIdFromItemName(recipe.name);
        if (out_id == 0) {
            j = 0;
            while (j < nn) : (j += 1) _ = self.sim.inventory[ps].addItem(need[j].id, @intCast(need[j].count));
            return false;
        }
        const out_count: u16 = @intCast(@as(u32, recipe.count) * n);
        if (!self.sim.inventory[ps].addItem(out_id, out_count)) {
            j = 0;
            while (j < nn) : (j += 1) _ = self.sim.inventory[ps].addItem(need[j].id, @intCast(need[j].count));
            return false;
        }
        if (self.sim.mask[ps].dirty) self.sim.dirty[ps].inv = true;
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

    fn wsGroupToStock(self: *Game, dst: []packages.stock_inv.StockSlot, src: []const ecs.components.InvSlot) usize {
        var n: usize = 0;
        for (src, 0..) |s, i| {
            dst[i] = if (s.count > 0 and s.item_id != 0) .{
                .type_id = resolveItemType(@ptrCast(self), s.item_id),
                .count = s.count,
                .quality = s.quality,
                .meta = s.meta,
            } else .{};
            if (s.count > 0) n = i + 1;
        }
        return n;
    }

    fn broadcastDirtyWorkstations(self: *Game) !void {
        for (self.workstations.items[0..], self.workstations.used[0..]) |*w, u| {
            if (!u or !w.dirty) continue;
            w.dirty = false;
            var fuel: [workstations_mod.slots_per_group]packages.stock_inv.StockSlot = undefined;
            var input: [workstations_mod.slots_per_group]packages.stock_inv.StockSlot = undefined;
            var tools: [workstations_mod.slots_per_group]packages.stock_inv.StockSlot = undefined;
            var output: [workstations_mod.slots_per_group]packages.stock_inv.StockSlot = undefined;
            const fn_ = self.wsGroupToStock(fuel[0..], w.fuel[0..]);
            const in_ = self.wsGroupToStock(input[0..], w.input[0..]);
            const tn_ = self.wsGroupToStock(tools[0..], w.tools[0..]);
            const on_ = self.wsGroupToStock(output[0..], w.output[0..]);
            const te_block_id: i32 = @intCast(self.blockIdAtWorld(w.x, w.y, w.z));
            const body = stock_te.buildWorkstationTeBody(
                self.body_buf[8192..16384],
                255,
                w.x,
                w.y,
                w.z,
                te_block_id,
                .{
                    .fuel = fuel[0..fn_],
                    .input = input[0..in_],
                    .tools = tools[0..tn_],
                    .output = output[0..on_],
                    .queue = w.queue[0..w.queue_n],
                    .is_burning = w.is_burning,
                    .burn_time_left = w.burn_time_left,
                },
            ) catch continue;
            self.broadcastNear(
                "NetPackageTileEntity",
                body,
                @floatFromInt(w.x),
                @floatFromInt(w.z),
                self.interest_range,
            ) catch {};
        }
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
        const n = self.loot.rollContainer(list_name, seed, &stacks);
        if (n == 0) return;
        const slot = self.sim.slotOfNetId(bag_net_id) orelse return;
        if (!self.sim.mask[slot].inventory) return;
        self.sim.inventory[slot].clear();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const eid = self.ecsIdFromItemName(stacks[i].item_name);
            if (eid == 0) continue;
            _ = self.sim.inventory[slot].addItem(eid, stacks[i].count);
        }
        // Ensure bag not empty.
        if (self.sim.inventory[slot].countItem(1) == 0 and self.sim.inventory[slot].slots[0].count == 0) {
            _ = self.sim.inventory[slot].addItem(1, 5);
        }
    }

    /// Wake prefab sleeper volumes near players; spawn class groups once.
    fn tickSleeperVolumes(self: *Game) void {
        if (self.sleepers.volumes.len == 0) return;
        // Collect player positions.
        var px: [max_clients]f32 = undefined;
        var py: [max_clients]f32 = undefined;
        var pz: [max_clients]f32 = undefined;
        var pn: usize = 0;
        for (&self.clients) |*cl| {
            if (!cl.joined or cl.entity_id <= 0) continue;
            if (self.sim.slotOfNetId(cl.entity_id)) |si| {
                if (!self.sim.mask[si].transform) continue;
                if (pn >= px.len) break;
                px[pn] = self.sim.transform[si].x;
                py[pn] = self.sim.transform[si].y;
                pz[pn] = self.sim.transform[si].z;
                pn += 1;
            }
        }
        if (pn == 0) return;

        var vi: usize = 0;
        while (vi < self.sleepers.volumes.len) : (vi += 1) {
            var vol = &self.sleepers.volumes[vi];
            if (vol.triggered) continue;
            var hit = false;
            var p: usize = 0;
            while (p < pn) : (p += 1) {
                if (self.sleepers.contains(vi, px[p], py[p], pz[p])) {
                    hit = true;
                    break;
                }
            }
            if (!hit) continue;
            vol.triggered = true;
            self.sleepers.trigger_count += 1;

            const grp = vol.groups[0];
            const seed: u32 = @intCast((vi + 1) *% 2654435761 % 0xffffffff);
            const def = self.resolveSleeperClass(grp.class_name, seed);
            const count: u8 = if (grp.max_count <= grp.min_count) grp.min_count else blk: {
                const span = grp.max_count - grp.min_count + 1;
                break :blk grp.min_count + @as(u8, @intCast((vi) % span));
            };

            if (vol.spawns.len > 0) {
                // Stock spawns at authored Class=Sleeper marker cells. Spawn one
                // zombie per marker, capped at the requested count and the marker
                // count (no gamestage scaling: zdtd has no gamestage, gsScale=1).
                const cap: usize = @min(@as(usize, count), vol.spawns.len);
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
            var rng: u32 = seed;
            var n: u8 = 0;
            while (n < count and n < 8) : (n += 1) {
                rng ^= rng << 13;
                rng ^= rng >> 17;
                rng ^= rng << 5;
                const ox: f32 = @floatFromInt(vol.x0 + @as(i32, @intCast(rng % @as(u32, @intCast(spanx)))));
                rng ^= rng << 13;
                rng ^= rng >> 17;
                rng ^= rng << 5;
                const oz: f32 = @floatFromInt(vol.z0 + @as(i32, @intCast(rng % @as(u32, @intCast(spanz)))));
                _ = self.sim.spawnSleeperClass(ox, cy, oz, def.max_hp, def.hash, def.loot_list);
            }
        }
    }

    /// Resolve a SleeperVolumeGroup name to an entity def. Stock names are either
    /// an entityclass or a gamestage entitygroup (EntityGroups::GetRandomFromGroup,
    /// asm.il 1085857): try the class table first, then the group table, else the
    /// default walker.
    fn resolveSleeperClass(self: *Game, name: []const u8, seed: u32) assets_entities.EntityDef {
        if (self.entities.byName(name)) |d| return d;
        if (self.entitygroups.pick(name, seed)) |cname| {
            if (self.entities.byName(cname)) |d| return d;
        }
        return self.entities.defaultZombie();
    }

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

    fn sendSpawnChunk(self: *Game, peer: *ln_peer.Peer, cx: i32, cz: i32) !void {
        const ch = try self.world.getOrCreate(.{ .x = cx, .z = cz });
        // After TTS paint, create storage TEs for known chest block ids (loot fill once).
        self.ensurePrefabStorageInChunk(ch, cx, cz);
        // Prefer biomes.png color→id mode; fallback height band.
        const biome_id: u8 = if (self.world.biomes) |*bm|
            bm.chunkDominant(cx, cz)
        else blk: {
            var hsum: u32 = 0;
            for (ch.heights) |h| hsum += h;
            const havg: u8 = @intCast(hsum / 256);
            break :blk if (havg < 40) @as(u8, 5) else if (havg > 90) @as(u8, 1) else 3;
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
        if (after_out > before_out) {
            std.debug.print("zdtd: sent NetPackageChunk stock cx={d} cz={d} body={d}\n", .{ cx, cz, body.len });
        } else {
            std.debug.print("zdtd: FAILED NetPackageChunk cx={d} cz={d} body={d}\n", .{ cx, cz, body.len });
        }
        // Storage TEs in this column (placed chests, loot containers).
        try self.sendContainersInChunk(peer, cx, cz);
    }

    /// Scan painted columns for known storage AssignIds; create + roll loot once.
    /// Also honor prefab TTS TE list (Loot/SecureLoot/Composite types).
    fn ensurePrefabStorageInChunk(self: *Game, ch: *world_store.Chunk, cx: i32, cz: i32) void {
        const blocks = ch.blocks orelse return;
        const base_x = cx * 16;
        const base_z = cz * 16;
        var found: u32 = 0;
        var lz: i32 = 0;
        while (lz < 16) : (lz += 1) {
            var lx: i32 = 0;
            while (lx < 16) : (lx += 1) {
                var y: i32 = 0;
                while (y < world_store.y_dim) : (y += 1) {
                    const idx = @as(usize, @intCast(lx + lz * 16 + y * 256));
                    const id: u16 = @truncate(blocks[idx]);
                    if (id == 0 or !self.isStorageBlockId(id)) continue;
                    const wx = base_x + lx;
                    const wz = base_z + lz;
                    const pos = containers_mod.PosKey{ .x = wx, .y = y, .z = wz };
                    if (self.containers.get(pos) != null) continue;
                    const cont = self.containers.getOrCreate(pos, 8, id) orelse continue;
                    if (cont.slots[0].count == 0 and cont.slots[1].count == 0) {
                        self.fillContainerFromLoot(cont, "woodenChest", @as(u32, @bitCast(wx *% 73856093 ^ wz *% 19349663 ^ y)));
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
                        tc.g.fillContainerFromLoot(cont, "woodenChest", @as(u32, @bitCast(wx *% 73856093 ^ wz *% 19349663 ^ wy)));
                    }
                    tc.found.* += 1;
                }
            };
            var te_found: u32 = found;
            var tc: TeCtx = .{ .g = self, .found = &te_found };
            pf.foreachTeInChunk(cx, cz, TeCtx.onTe, &tc);
        }
    }

    fn fillContainerFromLoot(self: *Game, cont: *containers_mod.Container, loot_name: []const u8, seed: u32) void {
        var stacks: [assets_loot.max_roll_stacks]assets_loot.Stack = undefined;
        const n = self.loot.rollContainer(loot_name, seed, &stacks);
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

    fn clientAddStreamed(c: *Client, key: i64) void {
        if (clientHasStreamed(c, key)) return;
        if (c.streamed_n >= max_streamed_chunks_cap) {
            // drop oldest
            var i: usize = 1;
            while (i < c.streamed_n) : (i += 1) c.streamed[i - 1] = c.streamed[i];
            c.streamed_n -= 1;
        }
        c.streamed[c.streamed_n] = key;
        c.streamed_n += 1;
    }

    fn clientRemoveStreamed(c: *Client, key: i64) void {
        var i: usize = 0;
        while (i < c.streamed_n) : (i += 1) {
            if (c.streamed[i] != key) continue;
            var j = i + 1;
            while (j < c.streamed_n) : (j += 1) c.streamed[j - 1] = c.streamed[j];
            c.streamed_n -= 1;
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
                cl.streamed_n = 0;
                cl.deco_streamed_n = 0;
                // keep deco_first_sent if already sent on enter
                break;
            }
        }
        var dz: i32 = -r;
        while (dz <= r) : (dz += 1) {
            var dx: i32 = -r;
            while (dx <= r) : (dx += 1) {
                const cx = t.pos.x + dx;
                const cz = t.pos.z + dz;
                try self.sendSpawnChunk(peer, cx, cz);
                if (client_ptr) |cl| clientAddStreamed(cl, packages.makeChunkKey(cx, cz));
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
            // desired set
            var desired: [max_streamed_chunks_cap]i64 = undefined;
            var dn: usize = 0;
            var dz: i32 = -r;
            while (dz <= r) : (dz += 1) {
                var dx: i32 = -r;
                while (dx <= r) : (dx += 1) {
                    if (dn >= self.max_streamed_chunks) break;
                    desired[dn] = packages.makeChunkKey(t.pos.x + dx, t.pos.z + dz);
                    dn += 1;
                }
            }
            // removes
            var i: usize = 0;
            while (i < c.streamed_n) {
                const key = c.streamed[i];
                var keep = false;
                var j: usize = 0;
                while (j < dn) : (j += 1) {
                    if (desired[j] == key) {
                        keep = true;
                        break;
                    }
                }
                if (!keep) {
                    const cx = packages.extractChunkKeyX(key);
                    const cz = packages.extractChunkKeyZ(key);
                    const rb = try packages.buildChunkRemoveBody(self.body_buf[0..16], cx, cz);
                    try self.sendGame(peer, "NetPackageChunkRemove", rb);
                    // Stock also clears deco for unloaded world chunks.
                    if (packages.stock_deco.buildDecoResetWorldChunk(self.body_buf[16..32], cx, cz)) |db| {
                        self.sendGame(peer, "NetPackageDecoResetWorldChunk", db) catch {};
                    } else |_| {}
                    clientRemoveStreamed(c, key);
                    // do not advance i: remove shifted
                } else {
                    i += 1;
                }
            }
            // adds: enough per pass to fill 13×13 before overlay timeout; still
            // paced so LiteNet reliable window can drain.
            var aj: usize = 0;
            var added: u32 = 0;
            while (aj < dn and added < self.chunk_adds_per_stream_tick) : (aj += 1) {
                const key = desired[aj];
                if (clientHasStreamed(c, key)) continue;
                const cx = packages.extractChunkKeyX(key);
                const cz = packages.extractChunkKeyZ(key);
                try self.sendSpawnChunk(peer, cx, cz);
                clientAddStreamed(c, key);
                // Plants/trees for the newly visible terrain chunk (fixed-size clients need S2C).
                self.sendDecoForTerrainChunk(c, peer, cx, cz) catch {};
                added += 1;
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
                    peer.resendPending(&self.net.sock) catch {};
                    self.pollNetOnce();
                    if (attempts % 4 == 3) clock.sleepNs(500_000);
                    continue;
                },
                else => return,
            };
            self.harness.counters.add(.net_packets_out, 1);
            self.harness.counters.add(.net_bytes_out, framed.len);
            self.harness.counters.inc(.packages_broadcast);
            self.pollNetOnce();
            return;
        }
    }

    fn broadcast(self: *Game, name: []const u8, body: []const u8) !void {
        try self.broadcastExcept(name, body, null);
    }

    /// World-position broadcast: only clients whose player is within
    /// `range_blocks` of (wx,wz). Chat/time stay global via broadcast().
    fn broadcastNear(self: *Game, name: []const u8, body: []const u8, wx: f32, wz: f32, range_blocks: f32) !void {
        const framed = try packages.framed(&self.send_buf, name, body);
        for (&self.clients) |*c| {
            const p = c.peer orelse continue;
            if (!c.joined) continue;
            // No sim player yet (join in progress): deliver rather than drop.
            if (self.sim.playerByPeer(c.slot)) |ps| {
                const dx = self.sim.transform[ps].x - wx;
                const dz = self.sim.transform[ps].z - wz;
                if (dx * dx + dz * dz > range_blocks * range_blocks) {
                    std.debug.print("zdtd: near-skip {s} d=({d:.0},{d:.0}) player=({d:.0},{d:.0})\n", .{ name, wx, wz, self.sim.transform[ps].x, self.sim.transform[ps].z });
                    continue;
                }
            }
            p.sendReliable(&self.net.sock, framed) catch continue;
            self.harness.counters.inc(.packages_broadcast);
        }
    }

    fn broadcastExcept(self: *Game, name: []const u8, body: []const u8, except_slot: ?usize) !void {
        const framed = try packages.framed(&self.send_buf, name, body);
        for (&self.clients) |*c| {
            const p = c.peer orelse continue;
            if (!c.joined) continue;
            if (except_slot) |ex| if (c.slot == ex) continue;
            p.sendReliable(&self.net.sock, framed) catch continue;
            self.harness.counters.inc(.packages_broadcast);
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
            if (c.peer) |p| p.resendPending(&self.net.sock) catch {};
        }
        // Continuous stock chunk stream around each player (ChunkRemove far keys).
        if (self.wire_chunks and self.tick_n % self.chunk_stream_period_ticks == 0) {
            for (&self.clients) |*cl| {
                if (!cl.joined or !cl.entered or cl.peer == null) continue;
                self.streamChunksForClient(cl) catch {};
            }
        }
        // Motion every other tick so join/control packages keep window room.
        if (self.tick_n % self.motion_replicate_period_ticks != 0) {
            self.clearDeadKnownEntities();
            return;
        }

        var pos_frame_buf: [replicate_frame_cap]u8 = undefined;
        var speeds_frame_buf: [replicate_frame_cap]u8 = undefined;
        var flags_frame_buf: [replicate_frame_cap]u8 = undefined;

        var i: ecs.Slot = 0;
        while (i < ecs.max_entities) : (i += 1) {
            if (!self.sim.alive[i] or !self.sim.mask[i].transform or !self.sim.mask[i].network_id) continue;

            // Spawn-on-approach is per-observer (known_entities); still entity-outer
            // so we only build EntitySpawn once when multiple clients need it.
            const is_mob = self.sim.mask[i].kind and (self.sim.kind[i] == .zombie or self.sim.kind[i] == .animal);
            var need_spawn_any = false;
            if (is_mob) {
                for (&self.clients) |*cl| {
                    if (!cl.joined or !cl.entered or cl.peer == null) continue;
                    if (cl.known_entities.isSet(i)) continue;
                    var px: f32 = 0;
                    var pz: f32 = 0;
                    if (self.sim.slotOfNetId(cl.entity_id)) |si| {
                        px = self.sim.transform[si].x;
                        pz = self.sim.transform[si].z;
                    }
                    if (!interest.inRange(px, pz, self.sim.transform[i].x, self.sim.transform[i].z, cl.view_radius)) continue;
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
                    for (&self.clients) |*cl| {
                        if (!cl.joined or !cl.entered) continue;
                        const peer = cl.peer orelse continue;
                        if (cl.known_entities.isSet(i)) continue;
                        var px: f32 = 0;
                        var pz: f32 = 0;
                        if (self.sim.slotOfNetId(cl.entity_id)) |si| {
                            px = self.sim.transform[si].x;
                            pz = self.sim.transform[si].z;
                        }
                        if (!interest.inRange(px, pz, self.sim.transform[i].x, self.sim.transform[i].z, cl.view_radius)) continue;
                        try self.sendGame(peer, "NetPackageEntitySpawn", spb);
                        cl.known_entities.set(i);
                    }
                    self.harness.counters.inc(.packages_encoded);
                } else |_| {}
            }

            const d = if (self.sim.mask[i].dirty) self.sim.dirty[i] else @as(ecs.components.Dirty, .{});
            if (!interest.needsPosSend(d, self.tick_n)) continue;

            // Owner skip is per-peer; still encode once if any other peer wants it.
            var any_observer = false;
            for (&self.clients) |*cl| {
                if (!cl.joined or !cl.entered or cl.peer == null) continue;
                if (self.sim.mask[i].player and self.sim.player[i].peer_slot == @as(i32, @intCast(cl.slot))) continue;
                var px: f32 = 0;
                var pz: f32 = 0;
                if (self.sim.slotOfNetId(cl.entity_id)) |si| {
                    px = self.sim.transform[si].x;
                    pz = self.sim.transform[si].z;
                }
                if (!interest.inRange(px, pz, self.sim.transform[i].x, self.sim.transform[i].z, cl.view_radius)) continue;
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

            for (&self.clients) |*cl| {
                if (!cl.joined or !cl.entered) continue;
                const peer = cl.peer orelse continue;
                if (self.sim.mask[i].player and self.sim.player[i].peer_slot == @as(i32, @intCast(cl.slot))) continue;
                var px: f32 = 0;
                var pz: f32 = 0;
                if (self.sim.slotOfNetId(cl.entity_id)) |si| {
                    px = self.sim.transform[si].x;
                    pz = self.sim.transform[si].z;
                }
                if (!interest.inRange(px, pz, self.sim.transform[i].x, self.sim.transform[i].z, cl.view_radius)) continue;
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
        var j: ecs.Slot = 0;
        while (j < ecs.max_entities) : (j += 1) {
            if (!self.sim.alive[j]) {
                for (&self.clients) |*kc| kc.known_entities.unset(j);
            }
        }
    }

    pub fn step(self: *Game) !void {
        const sc = apm.profiler.scope(&self.harness.prof, .tick_total);
        defer sc.end();
        self.tick_n += 1;
        self.harness.counters.inc(.ticks);

        {
            const sn = apm.profiler.scope(&self.harness.prof, .net_poll);
            defer sn.end();
            var polls: u32 = 0;
            while (polls < 64) : (polls += 1) {
                const ev = try self.net.poll(&self.recv_buf);
                switch (ev) {
                    .none => break,
                    .connected => |p| try self.onConnected(p),
                    .data => |d| try self.onData(d.peer, d.payload),
                }
            }
            // Drop silent peers (client quit) so we stop flooding a stuck window.
            self.reapStalePeers();
            // Drain several TCP info queries per tick (browser / connect dialog).
            var info_n: u32 = 0;
            while (info_n < 8) : (info_n += 1) self.info_tcp.poll();
            self.pollAdmin();
        }

        const dt: f32 = 1.0 / @as(f32, @floatFromInt(protocol.ticks_per_second));
        {
            const se = apm.profiler.scope(&self.harness.prof, .sim_entities);
            defer se.end();
            const r = systems.tickAll(&self.sim, dt);
            // Prefab sleeper volumes (every ~0.5s).
            if (self.tick_n % 10 == 0) self.tickSleeperVolumes();
            // Air drops + zombie block damage at 2Hz.
            if (self.tick_n % 10 == 0) {
                self.tickAirDrop();
                self.tickZombieBlockDamage();
            }
            // Workstation burn/craft at 2Hz; dirty stations re-broadcast state.
            if (self.tick_n % 10 == 0) {
                self.workstations.tickAllResolved(0.5, reverseItemType, self);
                self.broadcastDirtyWorkstations() catch {};
            }
            // Power fuel/SoC/timers every tick (props from blocks.xml via registry).
            const daylight = !self.sim.director.clock.isNight();
            _ = self.sim.power.tick(dt, daylight);
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
                try self.broadcastWeather();
                // Blood-moon horde music trigger (single bool; drives client
                // audio + tension on day-7 nights).
                const bm = self.sim.director.bloodmoon_active;
                if (bm != self.bloodmoon_sent) {
                    self.bloodmoon_sent = bm;
                    const bm_body = try packages.buildBloodmoonMusicBody(self.body_buf[0..1], bm);
                    try self.broadcast("NetPackageBloodmoonMusic", bm_body);
                }
            }
            if (self.tick_n % 5 == 0) try self.broadcastVehiclePositions();
            if (self.tick_n % 10 == 0) try self.broadcastTurretSync();
        }

        try self.replicate();
        // Periodic world flush so dig/build survives crash without explicit admin save.
        if (self.tick_n % 100 == 0) {
            const ss = apm.profiler.scope(&self.harness.prof, .save_io);
            defer ss.end();
            self.world.saveAll() catch {};
            self.containers.save(self.world.world_dir) catch {};
            self.saveBlockMeta() catch {};
            if (self.players_dirty) {
                self.players_dirty = false;
                self.savePlayers() catch {};
            }
        }
    }

    fn anyEnteredClient(self: *const Game) bool {
        for (self.clients) |cl| {
            if (cl.entered) return true;
        }
        return false;
    }

    /// Build NetPackageWeather from biomes.xml default groups (omit if none loaded).
    fn buildWeatherBodyFromBiomes(self: *Game) ?[]const u8 {
        const bl = &self.world.biome_layers_table;
        // Stock client InitPackages sizes from biomeWeather.Count (Navezgane / stock
        // biomes with weather groups → 5). Wire has no count prefix, so body length
        // must be exactly Count * 23 (3 u8 + 5 f32).
        const stock_count: usize = 5;
        var wb: [assets_biome_layers.max_weather_biomes]packages.WeatherBiome = undefined;
        var n: usize = 0;
        if (bl.weather_n > 0) {
            var defs: [assets_biome_layers.max_weather_biomes]assets_biome_layers.WeatherDefaults = undefined;
            n = bl.weatherPackages(&defs);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                wb[i] = .{
                    .biome_id = defs[i].biome_id,
                    .group_index = 0,
                    .remaining_seconds = 0,
                    .params = defs[i].params,
                };
            }
        }
        // Pad or trim to stock_count so content_len matches client expected size.
        if (n == 0) {
            // Fallback mild defaults (pine-ish) for biomap ids 1..5.
            var i: usize = 0;
            while (i < stock_count) : (i += 1) {
                wb[i] = .{
                    .biome_id = @intCast(i + 1),
                    .group_index = 0,
                    .remaining_seconds = 0,
                    .params = .{ 70, 0, 0.2, 0.1, 0.05 },
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
        var i: ecs.Slot = 0;
        while (i < ecs.max_entities) : (i += 1) {
            if (!self.sim.alive[i] or !self.sim.mask[i].vehicle) continue;
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
            const now = clock.monoNs();
            if (next_t > now) clock.sleepNs(next_t - now);
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

    pub fn attachJoinedClient(self: *Game, capture: ?*ln_peer.Capture) !*Client {
        var peer_ptr: ?*ln_peer.Peer = null;
        for (&self.net.peers) |*p| {
            if (p.alive) continue;
            p.* = .{};
            p.alive = true;
            p.local_id = self.net.next_local_id;
            self.net.next_local_id += 1;
            p.authenticated = false;
            p.capture = capture;
            var storage: std.os.linux.sockaddr.storage = undefined;
            const in_ptr: *std.os.linux.sockaddr.in = @ptrCast(@alignCast(&storage));
            in_ptr.* = .{
                .family = std.os.linux.AF.INET,
                .port = std.mem.nativeToBig(u16, @intCast(10000 + @as(i32, p.local_id))),
                .addr = std.mem.nativeToBig(u32, 0x7f000001),
            };
            p.setAddr(&storage, @sizeOf(std.os.linux.sockaddr.in));
            peer_ptr = p;
            break;
        }
        const peer = peer_ptr orelse return error.TooManyPeers;
        try self.onConnected(peer);
        const c = self.clientFor(peer) orelse return error.NoClient;
        var ch: [17]u8 = undefined;
        wire_frame.buildChallenge(&ch, c.challenge);
        try self.onData(peer, &ch);
        var login_body: [64]u8 = undefined;
        var w: @import("../wire/binary.zig").Writer = .{ .buf = &login_body };
        try w.writeString("Bot");
        try w.writeByte(0);
        try w.writeString("");
        try w.writeByte(0);
        try w.writeString("");
        try w.writeString("V 3.1.0");
        try w.writeString("V 3.1.0");
        try w.writeU64(0);
        var frame_buf: [256]u8 = undefined;
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
};
