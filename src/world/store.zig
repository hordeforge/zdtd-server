//! Authoritative block world: 16×256×16 columns, DTM heights, ZCH3 disk (.zch).
//! v3 magic ZCH3: heights + optional u32 rawData + optional texture/density
//! channels (flags in header). ZCH2 u16 type-only is accepted on load for
//! heights only (blocks regenerate from DTM+TTS). See ADR 0011.

const std = @import("std");
const dtm = @import("dtm.zig");
const prefabs_mod = @import("prefabs.zig");
const water_mod = @import("water.zig");
const biomes_mod = @import("biomes.zig");
const worldgen_mod = @import("worldgen.zig");
const parallel = @import("../util/parallel.zig");
const assignids = @import("../assets/assignids_comptime.zig");
const biome_layers = @import("../assets/biome_layers.zig");
const weather_mod = @import("weather.zig");
const io_fs = @import("../util/io_fs.zig");
const chunk_flush = @import("chunk_flush.zig");

/// How missing chunks are filled on first touch (on-the-fly, not full-map bake).
pub const TerrainSource = enum {
    /// Constant sea_level columns (default empty world).
    flat,
    /// Stock DTM / prefabs / water from loadStockMap.
    baked,
    /// Copernicus DEM streamer (future seam; heights via heightmap when set).
    dem,
    /// Procedural noise from worldgen seed.
    proc,
};

pub const chunk_size: i32 = 16;
pub const y_dim: i32 = 256;
pub const sea_level: u8 = 64;
// Stock AssignIds via bundled dump (never terrainFiller=2 as painted surface).
// Module pins = offline/test defaults. Live server prefers World.terrain_ids
// resolved once via maxdamage.idByName (HARDCODE A05).
pub const block_air: u16 = assignids.air;
pub const block_stone: u16 = assignids.terr_stone;
pub const block_bedrock: u16 = assignids.terr_bedrock;
pub const block_dirt: u16 = assignids.terr_dirt;
pub const block_water: u16 = assignids.water;
pub const blocks_per_chunk: usize = 16 * 256 * 16; // 65536

/// Runtime terrain type ids (AssignIds names). Defaults match module pins.
pub const TerrainIds = struct {
    air: u16 = block_air,
    stone: u16 = block_stone,
    bedrock: u16 = block_bedrock,
    dirt: u16 = block_dirt,
    water: u16 = block_water,
    forest_ground: u16 = assignids.terr_forest_ground,

    /// Resolve from live idByName dump. Missing names keep pin defaults (fail closed).
    pub fn resolve(self: *TerrainIds, lookup: *const fn (ctx: ?*anyopaque, name: []const u8) ?u16, ctx: ?*anyopaque) void {
        if (lookup(ctx, "air")) |id| self.air = id;
        if (lookup(ctx, "terrStone")) |id| self.stone = id;
        if (lookup(ctx, "terrBedrock")) |id| self.bedrock = id;
        if (lookup(ctx, "terrDirt")) |id| self.dirt = id;
        if (lookup(ctx, "water")) |id| self.water = id;
        if (lookup(ctx, "terrForestGround")) |id| self.forest_ground = id;
    }
};

pub const ChunkPos = struct {
    x: i32,
    z: i32,

    pub fn hash(self: ChunkPos) u64 {
        return (@as(u64, @bitCast(@as(i64, self.x))) << 32) ^ @as(u64, @bitCast(@as(i64, self.z)));
    }
};

fn blockIndex(lx: i32, y: i32, lz: i32) usize {
    // stock-ish: x + z*16 + y*256
    return @intCast(lx + lz * 16 + y * 256);
}

pub const Chunk = struct {
    pos: ChunkPos,
    /// On-disk / stock-wire surface Y (0..255). API returns u16 for headroom.
    heights: [256]u8 = .{sea_level} ** 256,
    /// Full BlockValue.rawData columns when allocated (lazy). Type = low 16 bits.
    blocks: ?[]u32 = null,
    /// Per-block textureFull paint (parallel to blocks), lazy. 0 = unpainted.
    /// Only allocated when a painted block is set (POIs); low 48 bits wired.
    textures: ?[]u64 = null,
    /// Per-block density (stock sbyte as u8). Lazy; only cells with dens_set bit.
    densities: ?[]u8 = null,
    dens_set: ?[]u8 = null, // bitset: 1 = densities[i] is valid TTS paint
    dirty: bool = false,
    /// Runtime-only: server finished its one-time storage-TE scan of this chunk.
    te_scanned: bool = false,
    /// Runtime-only: dominant biome, computed once per resident chunk (the
    /// biome map is static). Recomputing costs 256 map lookups per chunk send.
    biome_id: ?u8 = null,
    allocator: ?std.mem.Allocator = null,

    pub fn generateFlat(pos: ChunkPos) Chunk {
        return .{ .pos = pos };
    }

    /// Biome-aware column fill when layers are set on the owning World.
    pub fn generateColumnIds(h: u16, stack: biome_layers.Stack, out: *[256]u16) void {
        const hc: u8 = if (h > 255) 255 else @intCast(h);
        biome_layers.Table.fillColumn(stack, hc, out);
    }

    pub fn deinitBlocks(self: *Chunk) void {
        if (self.blocks) |b| {
            if (self.allocator) |a| a.free(b);
            self.blocks = null;
        }
        if (self.textures) |t| {
            if (self.allocator) |a| a.free(t);
            self.textures = null;
        }
        if (self.densities) |d| {
            if (self.allocator) |a| a.free(d);
            self.densities = null;
        }
        if (self.dens_set) |d| {
            if (self.allocator) |a| a.free(d);
            self.dens_set = null;
        }
    }

    pub fn texAt(self: *const Chunk, lx: i32, y: i32, lz: i32) u64 {
        if (y < 0 or y >= y_dim) return 0;
        if (self.textures) |t| return t[blockIndex(lx, y, lz)];
        return 0;
    }

    pub fn densAt(self: *const Chunk, lx: i32, y: i32, lz: i32) ?u8 {
        if (y < 0 or y >= y_dim) return null;
        const dens = self.densities orelse return null;
        const set = self.dens_set orelse return null;
        const idx = blockIndex(lx, y, lz);
        const bit: u8 = @as(u8, 1) << @intCast(idx % 8);
        if (set[idx / 8] & bit == 0) return null;
        return dens[idx];
    }

    /// Set a block (full rawData) plus paint texture and optional TTS density.
    pub fn setBlockTex(self: *Chunk, allocator: std.mem.Allocator, lx: i32, y: i32, lz: i32, raw: u32, tex: u64) !void {
        try self.setBlockTexDens(allocator, lx, y, lz, raw, tex, null);
    }

    pub fn setBlockTexDens(self: *Chunk, allocator: std.mem.Allocator, lx: i32, y: i32, lz: i32, raw: u32, tex: u64, dens: ?u8) !void {
        try self.setBlockRaw(allocator, lx, y, lz, raw);
        if (tex != 0 or self.textures != null) {
            if (self.textures == null) {
                const t = try allocator.alloc(u64, blocks_per_chunk);
                @memset(t, 0);
                self.textures = t;
            }
            self.textures.?[blockIndex(lx, y, lz)] = tex;
        }
        if (dens) |d| {
            if (self.densities == null) {
                const p = try allocator.alloc(u8, blocks_per_chunk);
                @memset(p, 0);
                self.densities = p;
            }
            if (self.dens_set == null) {
                const bits = try allocator.alloc(u8, (blocks_per_chunk + 7) / 8);
                @memset(bits, 0);
                self.dens_set = bits;
            }
            const idx = blockIndex(lx, y, lz);
            self.densities.?[idx] = d;
            self.dens_set.?[idx / 8] |= @as(u8, 1) << @intCast(idx % 8);
        }
    }

    /// Surface block Y as u16 (storage is u8; values >255 clamp on write).
    pub fn heightAt(self: *const Chunk, lx: i32, lz: i32) u16 {
        return self.heights[@intCast(lx + lz * chunk_size)];
    }

    pub fn setHeight(self: *Chunk, lx: i32, lz: i32, h: u16) void {
        const stored: u8 = if (h > 255) 255 else @intCast(h);
        self.heights[@intCast(lx + lz * chunk_size)] = stored;
        self.dirty = true;
    }

    fn ensureBlocks(self: *Chunk, allocator: std.mem.Allocator) !void {
        if (self.blocks != null) return;
        self.allocator = allocator;
        const b = try allocator.alloc(u32, blocks_per_chunk);
        @memset(b, block_air);
        const st = biome_layers.defaultStack();
        var col: [256]u16 = undefined;
        var lz: i32 = 0;
        while (lz < 16) : (lz += 1) {
            var lx: i32 = 0;
            while (lx < 16) : (lx += 1) {
                const h = self.heightAt(lx, lz);
                generateColumnIds(h, st, &col);
                var y: i32 = 0;
                while (y <= h and y < y_dim) : (y += 1) {
                    b[blockIndex(lx, y, lz)] = col[@intCast(y)];
                }
            }
        }
        self.blocks = b;
    }

    /// Materialize full block plane with a biome stack (called from World.getOrCreate).
    pub fn ensureBlocksWithStack(self: *Chunk, allocator: std.mem.Allocator, stack: biome_layers.Stack) !void {
        if (self.blocks != null) return;
        self.allocator = allocator;
        const b = try allocator.alloc(u32, blocks_per_chunk);
        @memset(b, block_air);
        var col: [256]u16 = undefined;
        var lz: i32 = 0;
        while (lz < 16) : (lz += 1) {
            var lx: i32 = 0;
            while (lx < 16) : (lx += 1) {
                const h = self.heightAt(lx, lz);
                generateColumnIds(h, stack, &col);
                var y: i32 = 0;
                while (y <= h and y < y_dim) : (y += 1) {
                    b[blockIndex(lx, y, lz)] = col[@intCast(y)];
                }
            }
        }
        self.blocks = b;
    }

    /// Materialize blocks AND heights from the procedural 3D density field
    /// (worldgen W2). Unlike `ensureBlocksWithStack` this cannot derive blocks
    /// from heights: the field has overhangs, so heights fall out of the fill.
    /// `generateChunkBlocks` writes all 65536 cells, so the plane is never
    /// cleared here (one memset owner, not two).
    pub fn generateProc(self: *Chunk, allocator: std.mem.Allocator, wg: *const worldgen_mod.WorldGen) !void {
        if (self.blocks != null) return;
        self.allocator = allocator;
        const b = try allocator.alloc(u32, blocks_per_chunk);
        self.blocks = b;
        wg.generateChunkBlocks(self.pos.x, self.pos.z, &self.heights, b);
    }

    /// Block type id (low 16 of rawData).
    pub fn blockAt(self: *const Chunk, lx: i32, y: i32, lz: i32) u16 {
        return @truncate(self.rawAt(lx, y, lz));
    }

    /// Full BlockValue.rawData for wire packing.
    pub fn rawAt(self: *const Chunk, lx: i32, y: i32, lz: i32) u32 {
        if (y < 0 or y >= y_dim) return block_air;
        if (self.blocks) |b| return b[blockIndex(lx, y, lz)];
        const h = self.heightAt(lx, lz);
        if (y > h) return block_air;
        if (y == 0) return block_bedrock;
        if (y + 3 < h) return block_stone;
        if (y == h) return assignids.terr_forest_ground;
        return block_dirt;
    }

    pub fn setBlock(self: *Chunk, allocator: std.mem.Allocator, lx: i32, y: i32, lz: i32, id: u16) !void {
        try self.setBlockRaw(allocator, lx, y, lz, id);
    }

    pub fn setBlockRaw(self: *Chunk, allocator: std.mem.Allocator, lx: i32, y: i32, lz: i32, raw: u32) !void {
        if (y < 0 or y >= y_dim) return;
        try self.ensureBlocks(allocator);
        const b = self.blocks.?;
        const idx = blockIndex(lx, y, lz);
        b[idx] = raw;
        // Paint/density are co-owned with the cell: a plain type/raw write must
        // drop stale TTS or prior paint so dig/place cannot leave orphan texture.
        // setBlockTexDens re-applies paint after this call.
        if (self.textures) |t| t[idx] = 0;
        if (self.dens_set) |set| {
            set[idx / 8] &= ~(@as(u8, 1) << @intCast(idx % 8));
        }
        // Incremental surface height: heights and blocks stay consistent (both
        // writers are ensureBlocks and this), so a full column rescan is only
        // needed when the surface block itself is cleared to air.
        const h: i32 = self.heightAt(lx, lz);
        if ((raw & 0xffff) != block_air) {
            if (y > h) self.setHeight(lx, lz, @intCast(y));
        } else if (y == h) {
            var top: i32 = y - 1;
            while (top >= 0) : (top -= 1) {
                if ((b[blockIndex(lx, top, lz)] & 0xffff) != block_air) break;
            }
            self.setHeight(lx, lz, if (top < 0) 0 else @intCast(top));
        }
        self.dirty = true;
    }

    pub fn isSolid(self: *const Chunk, lx: i32, y: i32, lz: i32) bool {
        const id = self.blockAt(lx, y, lz);
        return id != block_air and id != block_water;
    }
};

pub const World = struct {
    chunks: std.AutoHashMap(u64, Chunk),
    world_dir: []u8,
    allocator: std.mem.Allocator,
    heightmap: ?dtm.Heightmap = null,
    prefabs: ?prefabs_mod.Index = null,
    water: ?water_mod.Sources = null,
    biomes: ?biomes_mod.BiomeMap = null,
    /// biomes.xml layer stacks (AssignIds-resolved). Empty until Game loads config.
    biome_layers_table: biome_layers.Table = .{},
    /// Storm / bloodMoon weather groups, seeded from biome_layers_table. Inert
    /// (n == 0) until Game loads biomes.xml.
    weather: weather_mod.Manager = .{},
    map_dir: ?[]u8 = null,
    spawns: [32]dtm.SpawnPoint = undefined,
    spawn_count: usize = 0,
    /// flat | baked | dem | proc. loadStockMap sets baked; --worldgen-seed sets proc.
    terrain_source: TerrainSource = .flat,
    worldgen: ?worldgen_mod.WorldGen = null,
    /// Live AssignIds for air/stone/dirt/water/bedrock (A05). Pins until resolve.
    terrain_ids: TerrainIds = .{},
    /// Hand chunk writes to the background flusher ([perf] async_chunk_flush).
    /// Default off: every existing save-then-reload path stays synchronous.
    async_flush: bool = false,
    /// Background writer. Idle (no thread) until the first async submit.
    flush: chunk_flush.Flusher = .{},
    /// Async submits that fell back to an inline write (queue full / shutdown).
    /// Atomic: saveChunk runs on parallel workers.
    sync_fallbacks: std.atomic.Value(u64) = .init(0),

    pub fn init(allocator: std.mem.Allocator, world_dir: []const u8) !World {
        io_fs.mkdirPath(allocator, world_dir);
        return .{
            .chunks = std.AutoHashMap(u64, Chunk).init(allocator),
            .world_dir = try allocator.dupe(u8, world_dir),
            .allocator = allocator,
        };
    }

    /// Prefer dump ids over module pins. Call after AssignIds merge.
    pub fn resolveTerrainIds(self: *World, lookup: *const fn (ctx: ?*anyopaque, name: []const u8) ?u16, ctx: ?*anyopaque) void {
        const before = self.terrain_ids;
        self.terrain_ids.resolve(lookup, ctx);
        if (before.air != self.terrain_ids.air or
            before.stone != self.terrain_ids.stone or
            before.dirt != self.terrain_ids.dirt or
            before.water != self.terrain_ids.water or
            before.bedrock != self.terrain_ids.bedrock)
        {
            std.debug.print(
                "zdtd: terrain ids resolved air={d} stone={d} bedrock={d} dirt={d} water={d} (pins were {d}/{d}/{d}/{d}/{d})\n",
                .{
                    self.terrain_ids.air,
                    self.terrain_ids.stone,
                    self.terrain_ids.bedrock,
                    self.terrain_ids.dirt,
                    self.terrain_ids.water,
                    before.air,
                    before.stone,
                    before.bedrock,
                    before.dirt,
                    before.water,
                },
            );
        }
    }

    pub fn isAirId(self: *const World, id: u16) bool {
        return id == self.terrain_ids.air;
    }

    pub fn isWaterId(self: *const World, id: u16) bool {
        return id == self.terrain_ids.water;
    }

    /// Enable on-the-fly procedural terrain (W0). Clears baked map backends.
    pub fn enableProc(self: *World, seed: u64) void {
        if (self.heightmap) |*hm| hm.deinit();
        if (self.prefabs) |*p| p.deinit();
        if (self.water) |*w| w.deinit();
        if (self.biomes) |*b| b.deinit();
        if (self.map_dir) |d| self.allocator.free(d);
        self.heightmap = null;
        self.prefabs = null;
        self.water = null;
        self.biomes = null;
        self.map_dir = null;
        self.spawn_count = 0;
        self.terrain_source = .proc;
        self.worldgen = worldgen_mod.WorldGen.init(seed);
    }

    pub fn loadStockMap(self: *World, map_dir: []const u8) !void {
        try self.loadStockMapEx(map_dir, null);
    }

    pub fn loadStockMapEx(self: *World, map_dir: []const u8, prefabs_data_dir: ?[]const u8) !void {
        var new_heightmap = try dtm.loadFromWorldDir(self.allocator, map_dir);
        errdefer new_heightmap.deinit();
        const new_map_dir = try self.allocator.dupe(u8, map_dir);
        errdefer self.allocator.free(new_map_dir);
        var new_spawns: [32]dtm.SpawnPoint = undefined;
        const new_spawn_count = try dtm.loadSpawnPoints(self.allocator, map_dir, new_spawns[0..]);
        var new_biomes = try biomes_mod.tryLoad(self.allocator, map_dir);
        errdefer if (new_biomes) |*bm| bm.deinit();

        var owned_prefab_root: ?[]u8 = null;
        defer if (owned_prefab_root) |r| self.allocator.free(r);
        const prefab_root: ?[]const u8 = blk: {
            if (prefabs_data_dir) |p| break :blk p;
            if (std.mem.lastIndexOfScalar(u8, map_dir, '/')) |slash| {
                const worlds = map_dir[0..slash];
                if (std.mem.endsWith(u8, worlds, "/Worlds") or std.mem.endsWith(u8, worlds, "\\Worlds")) {
                    const data = worlds[0 .. worlds.len - "/Worlds".len];
                    owned_prefab_root = try std.fmt.allocPrint(self.allocator, "{s}/Prefabs", .{data});
                    break :blk owned_prefab_root;
                }
            }
            break :blk null;
        };

        var new_prefabs: ?prefabs_mod.Index = prefabs_mod.loadFromWorldDir(self.allocator, map_dir, prefab_root) catch |err| blk: {
            if (err != error.FileNotFound and err != error.OpenFailed) {
                std.debug.print("zdtd: load prefabs.xml failed: {s} ({s})\n", .{ @errorName(err), map_dir });
            }
            break :blk null;
        };
        errdefer if (new_prefabs) |*p| p.deinit();
        var new_water: ?water_mod.Sources = try water_mod.loadFromWorldDir(self.allocator, map_dir);
        errdefer if (new_water) |*w| w.deinit();

        if (new_biomes) |*bm| bm.scale = @max(1, @divTrunc(new_heightmap.width, @max(1, bm.width)));

        if (self.heightmap) |*hm| hm.deinit();
        if (self.prefabs) |*p| p.deinit();
        if (self.water) |*w| w.deinit();
        if (self.biomes) |*b| b.deinit();
        if (self.map_dir) |d| self.allocator.free(d);
        self.heightmap = new_heightmap;
        self.map_dir = new_map_dir;
        self.spawns = new_spawns;
        self.spawn_count = new_spawn_count;
        self.biomes = new_biomes;
        self.prefabs = new_prefabs;
        self.water = new_water;
        self.terrain_source = .baked;
        self.worldgen = null;
    }

    pub fn deinit(self: *World) void {
        // Drain and join the writer *before* freeing chunks / world_dir: a
        // detached or still-running writer would lose queued saves at exit.
        self.flush.deinit();
        var it = self.chunks.iterator();
        while (it.next()) |e| e.value_ptr.deinitBlocks();
        if (self.heightmap) |*hm| hm.deinit();
        if (self.prefabs) |*p| p.deinit();
        if (self.water) |*w| w.deinit();
        if (self.biomes) |*b| b.deinit();
        if (self.map_dir) |d| self.allocator.free(d);
        self.chunks.deinit();
        self.allocator.free(self.world_dir);
    }

    pub fn primarySpawn(self: *const World) dtm.SpawnPoint {
        if (self.spawn_count > 0) return self.spawns[0];
        return .{ .x = 256, .y = 70, .z = 256 };
    }

    /// Resident chunk cap: beyond this, evict (save + free) before insert so a
    /// roaming/malicious peer cannot grow the map without bound. ~256 KiB
    /// per block-allocated chunk → cap ≈ 1 GiB worst case.
    pub const max_resident_chunks: usize = 4096;

    fn evictOneChunk(self: *World, keep_key: u64) !void {
        // Min key among residents (not HashMap walk order). Insert history
        // would otherwise pick different victims for the same resident set,
        // breaking DST replay under cap pressure.
        var best_key: ?u64 = null;
        var it = self.chunks.iterator();
        while (it.next()) |e| {
            const k = e.key_ptr.*;
            if (k == keep_key) continue;
            if (best_key == null or k < best_key.?) best_key = k;
        }
        const victim = best_key orelse return error.NoEvictionCandidate;
        const c = self.chunks.getPtr(victim) orelse return error.NoEvictionCandidate;
        // Never discard a resident chunk unless its latest state reached disk.
        // The caller can reject the new chunk request and retry later.
        // Eviction goes through the same FIFO as every other write (the queue
        // preserves submit order per key), so an older queued payload can never
        // land after this one.
        try self.saveChunk(c);
        c.deinitBlocks();
        _ = self.chunks.remove(victim);
    }

    pub fn getOrCreate(self: *World, pos: ChunkPos) !*Chunk {
        const k = pos.hash();
        if (self.chunks.count() >= max_resident_chunks and !self.chunks.contains(k)) {
            try self.evictOneChunk(k);
        }
        const gop = try self.chunks.getOrPut(k);
        if (!gop.found_existing) {
            gop.value_ptr.* = Chunk.generateFlat(pos);
            errdefer {
                gop.value_ptr.deinitBlocks();
                _ = self.chunks.remove(k);
            }
            // Disk load first: a v3 save with blocks is authoritative for every
            // channel regen would produce, so skip the full terrain+TTS rebuild.
            // Heights-only / v2 saves still regen, then re-load to keep edits.
            const LoadState = enum { none, heights_only, full };
            var load_state: LoadState = .none;
            if (self.loadChunk(gop.value_ptr)) {
                load_state = if (gop.value_ptr.blocks != null) .full else .heights_only;
            } else |err| {
                if (err != error.FileNotFound) std.debug.print(
                    "zdtd: chunk ({d},{d}) load failed: {s}; regenerated\n",
                    .{ pos.x, pos.z, @errorName(err) },
                );
            }
            if (load_state == .full) return gop.value_ptr;
            if (self.terrain_source == .proc) {
                if (self.worldgen) |*wg| {
                    // 3D density field: blocks first, heights derived from the
                    // topmost solid cell (overhangs cannot come from a column
                    // fill). Single-biome materials via defaultStack pins.
                    try gop.value_ptr.generateProc(self.allocator, wg);
                }
            } else {
                if (self.heightmap) |*hm| {
                    hm.fillChunkHeights(pos.x, pos.z, &gop.value_ptr.heights, sea_level);
                }
                // Terrain columns from biomes.xml layers (before POI paint / disk load).
                const biome_id: u8 = if (self.biomes) |*bm| bm.chunkDominant(pos.x, pos.z) else 3;
                const stack = self.biome_layers_table.stackFor(biome_id);
                try gop.value_ptr.ensureBlocksWithStack(self.allocator, stack);
                if (self.prefabs) |*pf| {
                    pf.applyToChunkHeights(pos.x, pos.z, &gop.value_ptr.heights);
                    // Stock .tts block paint into this chunk only (no setBlockWorld re-entry).
                    const PaintCtx = struct {
                        c: *Chunk,
                        a: std.mem.Allocator,
                        base_x: i32,
                        base_z: i32,
                        failed: u32 = 0,
                        fn put(ctx: ?*anyopaque, wx: i32, wy: i32, wz: i32, raw: u32, tex: u64, dens: ?u8) void {
                            const pc: *@This() = @ptrCast(@alignCast(ctx.?));
                            const lx = wx - pc.base_x;
                            const lz = wz - pc.base_z;
                            if (lx < 0 or lx >= 16 or lz < 0 or lz >= 16) return;
                            if (wy < 0 or wy >= y_dim) return;
                            pc.c.setBlockTexDens(pc.a, lx, wy, lz, raw, tex, dens) catch {
                                pc.failed +%= 1;
                            };
                        }
                    };
                    var pc: PaintCtx = .{
                        .c = gop.value_ptr,
                        .a = self.allocator,
                        .base_x = pos.x * 16,
                        .base_z = pos.z * 16,
                    };
                    pf.applyTtsPaintToChunk(pos.x, pos.z, PaintCtx.put, &pc);
                    if (pc.failed > 0) {
                        std.debug.print(
                            "zdtd: TTS paint dropped {d} blocks at chunk ({d},{d})\n",
                            .{ pc.failed, pos.x, pos.z },
                        );
                    }
                }
                if (self.water) |*wt| {
                    wt.applyToChunkHeights(pos.x, pos.z, &gop.value_ptr.heights);
                }
            }
            // Player edits / first-touch cache win over regen (heights-only or
            // v2 saves restore heights again after regen filled blocks).
            // Note: for a legacy ZCH2/v2 proc save the restored heights can
            // disagree with the density-derived plane (overhangs are not
            // expressible in a heightmap). Pre-existing; v3 saves carry blocks.
            if (load_state == .heights_only) self.loadChunk(gop.value_ptr) catch |err| {
                std.debug.print(
                    "zdtd: chunk ({d},{d}) edit re-load failed: {s}\n",
                    .{ pos.x, pos.z, @errorName(err) },
                );
            };
        }
        return gop.value_ptr;
    }

    pub fn worldToChunk(wx: i32, wz: i32) struct { pos: ChunkPos, lx: i32, lz: i32 } {
        const cx = @divFloor(wx, chunk_size);
        const cz = @divFloor(wz, chunk_size);
        var lx = wx - cx * chunk_size;
        var lz = wz - cz * chunk_size;
        if (lx < 0) lx += chunk_size;
        if (lz < 0) lz += chunk_size;
        return .{ .pos = .{ .x = cx, .z = cz }, .lx = lx, .lz = lz };
    }

    pub fn setBlockWorld(self: *World, x: i32, y: i32, z: i32, id: u16) !void {
        const t = worldToChunk(x, z);
        const c = try self.getOrCreate(t.pos);
        try c.setBlock(self.allocator, t.lx, y, t.lz, id);
    }

    pub fn blockWorld(self: *World, x: i32, y: i32, z: i32) !u16 {
        const t = worldToChunk(x, z);
        const c = try self.getOrCreate(t.pos);
        return c.blockAt(t.lx, y, t.lz);
    }

    /// Surface block Y at world XZ (u16 API; current maps still 0..255).
    pub fn heightWorld(self: *World, x: i32, z: i32) !u16 {
        const t = worldToChunk(x, z);
        const c = try self.getOrCreate(t.pos);
        return c.heightAt(t.lx, t.lz);
    }

    pub fn isSolidWorld(self: *World, x: i32, y: i32, z: i32) !bool {
        const id = try self.blockWorld(x, y, z);
        return id != self.terrain_ids.air and id != self.terrain_ids.water;
    }

    fn chunkPath(self: *World, pos: ChunkPos, buf: []u8) ![]const u8 {
        return try std.fmt.bufPrint(buf, "{s}/c_{d}_{d}.zch", .{ self.world_dir, pos.x, pos.z });
    }

    /// dens_set bitset bytes for one chunk (blocks_per_chunk bits).
    const dens_set_bytes: usize = (blocks_per_chunk + 7) / 8;

    /// Bounds-check a ZCH1/2/3 record for `pos` without mutating chunk state.
    /// Used by loadChunk and fuzz harnesses for torn/corrupt save rejection.
    pub fn validateChunkBytes(data: []const u8, pos: ChunkPos) !void {
        if (data.len < 12) return error.ReadFailed;
        if (data.len >= 16 and data[0] == 'Z' and data[1] == 'C' and data[2] == 'H' and (data[3] == '3' or data[3] == '2')) {
            const stored_x = std.mem.readInt(i32, data[4..8], .little);
            const stored_z = std.mem.readInt(i32, data[8..12], .little);
            if (stored_x != pos.x or stored_z != pos.z) return error.ReadFailed;
            if (data[12] > 1 or data[13] > 1 or data[14] > 1) return error.ReadFailed;
            const has_blocks = data[12] == 1;
            const has_textures = data[3] == '3' and data[13] == 1;
            const has_densities = data[3] == '3' and data[14] == 1;
            var required: usize = 16 + 256; // heights plane
            if (data[3] == '3' and has_blocks) required += blocks_per_chunk * @sizeOf(u32);
            if (has_textures) required += blocks_per_chunk * @sizeOf(u64);
            if (has_densities) required += blocks_per_chunk + dens_set_bytes;
            if (data.len < required) return error.ReadFailed;
            return;
        }
        if (data[0] == 'Z' and data[1] == 'C' and data[2] == 'H' and data[3] == '1') {
            if (data.len < 12 + 256) return error.ReadFailed;
            const stored_x = std.mem.readInt(i32, data[4..8], .little);
            const stored_z = std.mem.readInt(i32, data[8..12], .little);
            if (stored_x != pos.x or stored_z != pos.z) return error.ReadFailed;
            return;
        }
        return error.ReadFailed;
    }

    /// Serialize one chunk into a fresh `a`-owned buffer (the whole file image).
    /// v3: magic ZCH3 | pos | flags | heights | optional channels.
    /// flags: [12]=blocks u32, [13]=textures u64, [14]=densities+bitset.
    /// (v2 ZCH2 was u16 type-only; discarded on load so rotation/meta is not lost.)
    /// Callers pass `std.heap.page_allocator`: this runs from parallel workers
    /// and World.allocator is a DebugAllocator/GPA, which is not thread-safe.
    pub fn encodeChunk(c: *const Chunk, a: std.mem.Allocator) ![]u8 {
        const has_blocks = c.blocks != null;
        const has_textures = c.textures != null;
        const has_densities = c.densities != null and c.dens_set != null;
        var hdr: [16]u8 = undefined;
        hdr[0] = 'Z';
        hdr[1] = 'C';
        hdr[2] = 'H';
        hdr[3] = '3';
        std.mem.writeInt(i32, hdr[4..8], c.pos.x, .little);
        std.mem.writeInt(i32, hdr[8..12], c.pos.z, .little);
        hdr[12] = if (has_blocks) 1 else 0;
        hdr[13] = if (has_textures) 1 else 0;
        hdr[14] = if (has_densities) 1 else 0;
        hdr[15] = 0;
        var total: usize = hdr.len + c.heights.len;
        if (has_blocks) total += blocks_per_chunk * @sizeOf(u32);
        if (has_textures) total += blocks_per_chunk * @sizeOf(u64);
        if (has_densities) total += blocks_per_chunk + dens_set_bytes;
        const payload = try a.alloc(u8, total);
        errdefer a.free(payload);
        var o: usize = 0;
        @memcpy(payload[o..][0..hdr.len], &hdr);
        o += hdr.len;
        @memcpy(payload[o..][0..c.heights.len], &c.heights);
        o += c.heights.len;
        if (c.blocks) |b| {
            const bytes = std.mem.sliceAsBytes(b);
            @memcpy(payload[o..][0..bytes.len], bytes);
            o += bytes.len;
        }
        if (c.textures) |t| {
            const bytes = std.mem.sliceAsBytes(t);
            @memcpy(payload[o..][0..bytes.len], bytes);
            o += bytes.len;
        }
        if (has_densities) {
            @memcpy(payload[o..][0..blocks_per_chunk], c.densities.?[0..blocks_per_chunk]);
            o += blocks_per_chunk;
            @memcpy(payload[o..][0..dens_set_bytes], c.dens_set.?[0..dens_set_bytes]);
            o += dens_set_bytes;
        }
        std.debug.assert(o == total);
        return payload;
    }

    /// True when chunk writes may be handed to the background flusher.
    /// Force-serial (DST, offline `Game`, scenarios) always writes inline so
    /// `io_fs.injectWriteFailures` replay keeps observing the error return.
    pub fn asyncEnabled(self: *const World) bool {
        return self.async_flush and chunk_flush.Flusher.available() and !parallel.isForceSerial();
    }

    pub fn saveChunk(self: *World, c: *const Chunk) !void {
        var path_buf: [512]u8 = undefined;
        const path = try self.chunkPath(c.pos, &path_buf);
        const io_a = std.heap.page_allocator;
        const payload = try encodeChunk(c, io_a);
        if (self.asyncEnabled()) {
            const owned_path = io_a.dupe(u8, path) catch {
                defer io_a.free(payload);
                return io_fs.writeFile(io_a, path, payload);
            };
            self.flush.submit(c.pos.hash(), owned_path, payload) catch {
                // Queue full or shut down: write inline rather than drop.
                defer io_a.free(owned_path);
                defer io_a.free(payload);
                _ = self.sync_fallbacks.fetchAdd(1, .monotonic);
                return io_fs.writeFile(io_a, path, payload);
            };
            return;
        }
        defer io_a.free(payload);
        try io_fs.writeFile(io_a, path, payload);
    }

    /// Block until nothing is queued or in flight for this world's chunks.
    pub fn flushWait(self: *World) void {
        self.flush.waitAll();
    }

    pub fn loadChunk(self: *World, c: *Chunk) !void {
        // An evict-then-reload of a key whose payload is still queued would read
        // stale bytes. Stock guards the same case: RegionFileManager
        // ::IsChunkSavedAndDormant (asm.il:1182993) returns false while the key
        // is in chunksToSave or equals chunkKeyCurrentlySaved.
        self.flush.waitKey(c.pos.hash());
        var path_buf: [512]u8 = undefined;
        const path = try self.chunkPath(c.pos, &path_buf);
        const data = io_fs.readFileAll(self.allocator, path) catch |err| switch (err) {
            // No file = never saved; caller regenerates. Other errors mean an
            // existing save could not be read.
            error.FileNotFound => return error.FileNotFound,
            else => return error.OpenFailed,
        };
        defer self.allocator.free(data);
        if (data.len < 12) return error.ReadFailed;
        if (data.len >= 16 and data[0] == 'Z' and data[1] == 'C' and data[2] == 'H' and (data[3] == '3' or data[3] == '2')) {
            const stored_x = std.mem.readInt(i32, data[4..8], .little);
            const stored_z = std.mem.readInt(i32, data[8..12], .little);
            if (stored_x != c.pos.x or stored_z != c.pos.z) return error.ReadFailed;
            if (data[12] > 1 or data[13] > 1 or data[14] > 1) return error.ReadFailed;
            const has_blocks = data[12] == 1;
            // hdr[13]/[14] are 0 on pre-paint ZCH3 files (backward compatible).
            const has_textures = data[3] == '3' and data[13] == 1;
            const has_densities = data[3] == '3' and data[14] == 1;
            var required: usize = 16 + c.heights.len;
            if (data[3] == '3' and has_blocks) required += blocks_per_chunk * @sizeOf(u32);
            if (has_textures) required += blocks_per_chunk * @sizeOf(u64);
            if (has_densities) required += blocks_per_chunk + dens_set_bytes;
            // Validate the complete record before mutating the resident chunk.
            // A torn save must regenerate, never leave a half-loaded plane that
            // suppresses terrain materialization.
            if (data.len < required) return error.ReadFailed;
            @memcpy(&c.heights, data[16..][0..c.heights.len]);
            var o: usize = 16 + c.heights.len;
            if (has_blocks) {
                if (data[3] == '3') {
                    // Raw alloc only: the memcpy below fully initializes the
                    // plane, so ensureBlocks' terrain generation would be waste.
                    if (c.blocks == null) {
                        c.allocator = self.allocator;
                        c.blocks = try self.allocator.alloc(u32, blocks_per_chunk);
                    }
                    const b = c.blocks.?;
                    const bytes = std.mem.sliceAsBytes(b);
                    if (data.len < o + bytes.len) return error.ReadFailed;
                    @memcpy(bytes, data[o..][0..bytes.len]);
                    o += bytes.len;
                }
                // ZCH2 u16 type-only: keep heights only; blocks regenerate from DTM+TTS.
            }
            if (has_textures) {
                const tex_bytes = blocks_per_chunk * @sizeOf(u64);
                if (data.len < o + tex_bytes) return error.ReadFailed;
                if (c.textures == null) {
                    const t = try self.allocator.alloc(u64, blocks_per_chunk);
                    c.textures = t;
                    c.allocator = self.allocator;
                }
                const dest = std.mem.sliceAsBytes(c.textures.?);
                @memcpy(dest, data[o..][0..tex_bytes]);
                o += tex_bytes;
            }
            if (has_densities) {
                if (data.len < o + blocks_per_chunk + dens_set_bytes) return error.ReadFailed;
                if (c.densities == null) {
                    const p = try self.allocator.alloc(u8, blocks_per_chunk);
                    c.densities = p;
                    c.allocator = self.allocator;
                }
                if (c.dens_set == null) {
                    const bits = try self.allocator.alloc(u8, dens_set_bytes);
                    c.dens_set = bits;
                }
                @memcpy(c.densities.?[0..blocks_per_chunk], data[o..][0..blocks_per_chunk]);
                o += blocks_per_chunk;
                @memcpy(c.dens_set.?[0..dens_set_bytes], data[o..][0..dens_set_bytes]);
            }
        } else if (data[0] == 'Z' and data[1] == 'C' and data[2] == 'H' and data[3] == '1') {
            // v1: 12-byte hdr then heights.
            if (data.len < 12 + c.heights.len) return error.ReadFailed;
            const stored_x = std.mem.readInt(i32, data[4..8], .little);
            const stored_z = std.mem.readInt(i32, data[8..12], .little);
            if (stored_x != c.pos.x or stored_z != c.pos.z) return error.ReadFailed;
            @memcpy(&c.heights, data[12..][0..c.heights.len]);
        } else return error.ReadFailed;
        c.dirty = false;
    }

    pub fn saveAll(self: *World) !void {
        // Sort dirty keys so disk write order is independent of HashMap walk
        // (insert history / capacity). Needed for deterministic fault injection
        // and mid-save crash replay.
        if (self.chunks.count() == 0) return;
        var dirty_n: usize = 0;
        var count_it = self.chunks.iterator();
        while (count_it.next()) |e| {
            if (e.value_ptr.dirty) dirty_n += 1;
        }
        if (dirty_n == 0) return;

        // Loaded terrain can be much larger than the mutation set. Size this
        // temporary to the dirty set so autosave cost follows pending writes,
        // not resident-world size.
        var keys = try self.allocator.alloc(u64, dirty_n);
        defer self.allocator.free(keys);
        var kn: usize = 0;
        var it = self.chunks.iterator();
        while (it.next()) |e| {
            if (!e.value_ptr.dirty) continue;
            keys[kn] = e.key_ptr.*;
            kn += 1;
        }
        std.debug.assert(kn == dirty_n);
        std.mem.sort(u64, keys[0..kn], {}, std.sort.asc(u64));

        var list: [512]*Chunk = undefined;
        var n: usize = 0;
        for (keys[0..kn]) |k| {
            const c = self.chunks.getPtr(k) orelse continue;
            if (!c.dirty) continue;
            if (n >= list.len) {
                try self.saveChunkSlice(list[0..n]);
                n = 0;
            }
            list[n] = c;
            n += 1;
        }
        try self.saveChunkSlice(list[0..n]);
    }

    fn saveChunkSlice(self: *World, chunks: []const *Chunk) !void {
        if (chunks.len == 0) return;
        if (chunks.len < parallel.min_parallel_items) {
            for (chunks) |c| {
                try self.saveChunk(c);
                c.dirty = false;
            }
            return;
        }
        const SaveCtx = struct {
            world: *World,
            chunks: []const *Chunk,
            failed: *std.atomic.Value(u8),
            fn work(ctx: @This(), begin: usize, end: usize) void {
                var i = begin;
                while (i < end) : (i += 1) {
                    ctx.world.saveChunk(ctx.chunks[i]) catch |err| {
                        std.debug.print(
                            "zdtd: chunk ({d},{d}) save failed: {s}\n",
                            .{ ctx.chunks[i].pos.x, ctx.chunks[i].pos.z, @errorName(err) },
                        );
                        // release pairs with post-join acquire load below.
                        _ = ctx.failed.store(1, .release);
                        continue;
                    };
                    ctx.chunks[i].dirty = false;
                }
            }
        };
        var failed: std.atomic.Value(u8) = .init(0);
        parallel.forRanges(chunks.len, SaveCtx{ .world = self, .chunks = chunks, .failed = &failed }, SaveCtx.work);
        // forRanges join already synchronizes workers; acquire still documents
        // the happens-before for the failed flag itself.
        if (failed.load(.acquire) != 0) return error.SaveFailed;
    }
};

test "proc worldgen getOrCreate heights from seed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    w.enableProc(0xA11CE);
    try std.testing.expect(w.terrain_source == .proc);
    const c = try w.getOrCreate(.{ .x = 2, .z = -1 });
    try std.testing.expect(c.heightAt(0, 0) >= worldgen_mod.min_surface);
    try std.testing.expect(c.heightAt(0, 0) <= worldgen_mod.max_surface);
    const h0 = c.heightAt(5, 7);
    const h_surf = c.heightAt(0, 0);
    try std.testing.expect(c.blockAt(0, h_surf, 0) != block_air);
    if (h_surf + 1 < y_dim) {
        try std.testing.expectEqual(block_air, c.blockAt(0, @intCast(h_surf + 1), 0));
    }
    // Same seed regenerates an identical heights AND block plane after a drop.
    const plane = try std.testing.allocator.dupe(u32, c.blocks.?);
    defer std.testing.allocator.free(plane);
    const heights_before = c.heights;
    if (w.chunks.fetchRemove(ChunkPos.hash(.{ .x = 2, .z = -1 }))) |kv| {
        var dead = kv.value;
        dead.deinitBlocks();
    }
    const c2 = try w.getOrCreate(.{ .x = 2, .z = -1 });
    try std.testing.expectEqual(h0, c2.heightAt(5, 7));
    try std.testing.expectEqualSlices(u8, &heights_before, &c2.heights);
    try std.testing.expectEqualSlices(u32, plane, c2.blocks.?);
}

test "flat world set dig persist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    try w.setBlockWorld(5, 70, 5, block_dirt);
    try w.setBlockWorld(6, 71, 5, block_stone);
    try std.testing.expectEqual(block_dirt, try w.blockWorld(5, 70, 5));
    try std.testing.expectEqual(block_stone, try w.blockWorld(6, 71, 5));
    try std.testing.expect(w.chunks.getPtr(ChunkPos.hash(.{ .x = 0, .z = 0 })).?.dirty);
    try w.saveAll();
    try std.testing.expect(!w.chunks.getPtr(ChunkPos.hash(.{ .x = 0, .z = 0 })).?.dirty);

    var w2 = try World.init(std.testing.allocator, dir);
    defer w2.deinit();
    const c = try w2.getOrCreate(.{ .x = 0, .z = 0 });
    try std.testing.expectEqual(@as(u16, 71), c.heightAt(6, 5));
    // Full columns must reload so dig/build is authoritative after restart.
    try std.testing.expectEqual(block_dirt, try w2.blockWorld(5, 70, 5));
    try std.testing.expectEqual(block_stone, try w2.blockWorld(6, 71, 5));
}

test "evictOneChunk picks min key (DST)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    // Insert in reverse key order so HashMap walk ≠ sorted order.
    _ = try w.getOrCreate(.{ .x = 3, .z = 0 });
    _ = try w.getOrCreate(.{ .x = 1, .z = 0 });
    _ = try w.getOrCreate(.{ .x = 2, .z = 0 });
    const keep = ChunkPos.hash(.{ .x = 2, .z = 0 });
    try w.evictOneChunk(keep);
    // Min key among {1,2,3} excluding keep=2 is 1.
    try std.testing.expect(w.chunks.get(ChunkPos.hash(.{ .x = 1, .z = 0 })) == null);
    try std.testing.expect(w.chunks.get(ChunkPos.hash(.{ .x = 2, .z = 0 })) != null);
    try std.testing.expect(w.chunks.get(ChunkPos.hash(.{ .x = 3, .z = 0 })) != null);
}

test "paint clear on setBlock and ZCH3 texture density roundtrip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    const c = try w.getOrCreate(.{ .x = 0, .z = 0 });
    // Paint a cell, then plain dig must drop orphan texture/density.
    try c.setBlockTexDens(w.allocator, 3, 40, 4, block_dirt, 0x61, 12);
    try std.testing.expectEqual(@as(u64, 0x61), c.texAt(3, 40, 4));
    try std.testing.expectEqual(@as(?u8, 12), c.densAt(3, 40, 4));
    try c.setBlock(w.allocator, 3, 40, 4, block_air);
    try std.testing.expectEqual(@as(u64, 0), c.texAt(3, 40, 4));
    try std.testing.expectEqual(@as(?u8, null), c.densAt(3, 40, 4));
    // Repaint and persist; reload must restore channels (hdr flags 13/14).
    try c.setBlockTexDens(w.allocator, 3, 40, 4, block_stone, 0x0b0b0b0b0b0b, 7);
    try c.setBlockTexDens(w.allocator, 1, 10, 2, block_dirt, 0x22, 3);
    try w.saveAll();

    var w2 = try World.init(std.testing.allocator, dir);
    defer w2.deinit();
    const c2 = try w2.getOrCreate(.{ .x = 0, .z = 0 });
    try std.testing.expectEqual(block_stone, c2.blockAt(3, 40, 4));
    try std.testing.expectEqual(@as(u64, 0x0b0b0b0b0b0b), c2.texAt(3, 40, 4));
    try std.testing.expectEqual(@as(?u8, 7), c2.densAt(3, 40, 4));
    try std.testing.expectEqual(block_dirt, c2.blockAt(1, 10, 2));
    try std.testing.expectEqual(@as(u64, 0x22), c2.texAt(1, 10, 2));
    try std.testing.expectEqual(@as(?u8, 3), c2.densAt(1, 10, 2));
}

test "torn or misplaced chunk save cannot partially replace generated state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/c_0_0.zch", .{dir});

    var torn: [16 + 256]u8 = .{0} ** (16 + 256);
    @memcpy(torn[0..4], "ZCH3");
    torn[12] = 1; // Claims a block plane that is not present.
    @memset(torn[16..], 200);
    try io_fs.writeFileSimple(path, &torn);

    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    const c = try w.getOrCreate(.{ .x = 0, .z = 0 });
    try std.testing.expectEqual(@as(u16, sea_level), c.heightAt(0, 0));
    try std.testing.expect(c.blocks != null);

    // The filename is not identity: embedded coordinates must agree too.
    std.mem.writeInt(i32, torn[4..8], 7, .little);
    torn[12] = 0;
    try io_fs.writeFileSimple(path, &torn);
    var direct = Chunk.generateFlat(.{ .x = 0, .z = 0 });
    try std.testing.expectError(error.ReadFailed, w.loadChunk(&direct));
    try std.testing.expectEqual(@as(u16, sea_level), direct.heightAt(0, 0));

    @memcpy(torn[0..4], "NOPE");
    std.mem.writeInt(i32, torn[4..8], 0, .little);
    try io_fs.writeFileSimple(path, &torn);
    try std.testing.expectError(error.ReadFailed, w.loadChunk(&direct));
}

test "stock map heights via DTM if Navezgane present" {
    const map = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Worlds/Navezgane";
    if (!io_fs.dirExistsSimple(map)) return error.SkipZigTest;

    io_fs.mkdirPathSimple("worlds");
    io_fs.mkdirPathSimple("worlds/zdtd_navezgane_test");
    var w = try World.init(std.testing.allocator, "worlds/zdtd_navezgane_test");
    defer w.deinit();
    try w.loadStockMap(map);
    const h = try w.heightWorld(-273, 449);
    try std.testing.expect(h >= 55 and h <= 65);
    const sp = w.primarySpawn();
    try std.testing.expectEqual(@as(i32, -273), sp.x);
    const t = World.worldToChunk(-273, 449);
    const c = try w.getOrCreate(t.pos);
    try std.testing.expect(c.heightAt(t.lx, t.lz) == h);
    const n_pref = if (w.prefabs) |*p| p.items.len else 0;
    std.debug.print(
        "PASS stock-map: Navezgane dtm={d}x{d} height(-273,449)={d} spawn=({d},{d},{d}) prefabs={d}\n",
        .{ w.heightmap.?.width, w.heightmap.?.height, h, sp.x, sp.y, sp.z, n_pref },
    );
}

test "async flush round-trips a save into a fresh World" {
    if (!chunk_flush.Flusher.available()) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    w.async_flush = true;
    try std.testing.expect(w.asyncEnabled());
    try w.setBlockWorld(5, 70, 5, block_dirt);
    try w.setBlockWorld(6, 71, 5, block_stone);
    try w.saveAll();
    w.flushWait();
    try std.testing.expect(w.flush.written.load(.monotonic) >= 1);
    try std.testing.expectEqual(@as(u64, 0), w.flush.errors.load(.monotonic));

    var w2 = try World.init(std.testing.allocator, dir);
    defer w2.deinit();
    try std.testing.expectEqual(block_dirt, try w2.blockWorld(5, 70, 5));
    try std.testing.expectEqual(block_stone, try w2.blockWorld(6, 71, 5));
}

test "asyncEnabled is false under force-serial (DST keeps the sync path)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    w.async_flush = true;
    parallel.setForceSerial(true);
    defer parallel.setForceSerial(false);
    try std.testing.expect(!w.asyncEnabled());
    // Injected write failures still surface as an error return on this path.
    try w.setBlockWorld(1, 70, 1, block_stone);
    io_fs.injectWriteFailures(1);
    defer io_fs.injectWriteFailures(0);
    try std.testing.expectError(error.DiskQuota, w.saveChunk(w.chunks.getPtr(ChunkPos.hash(.{ .x = 0, .z = 0 })).?));
}

test "evict then reload of a queued key reads the newest bytes" {
    if (!chunk_flush.Flusher.available()) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    w.async_flush = true;

    _ = try w.getOrCreate(.{ .x = 1, .z = 0 });
    _ = try w.getOrCreate(.{ .x = 2, .z = 0 });
    try w.setBlockWorld(16 + 4, 90, 4, block_stone); // chunk (1,0)
    const key1 = ChunkPos.hash(.{ .x = 1, .z = 0 });
    // Evict (1,0): its payload goes on the queue, then the chunk is freed.
    try w.evictOneChunk(ChunkPos.hash(.{ .x = 2, .z = 0 }));
    try std.testing.expect(w.chunks.get(key1) == null);
    // Reload must wait on the queued write, never read a stale/absent file.
    try std.testing.expectEqual(block_stone, try w.blockWorld(16 + 4, 90, 4));
}
