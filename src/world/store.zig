//! Authoritative block world: 16×256×16 columns, DTM heights, .zch2 disk.

const std = @import("std");
const dtm = @import("dtm.zig");
const prefabs_mod = @import("prefabs.zig");
const water_mod = @import("water.zig");
const biomes_mod = @import("biomes.zig");
const worldgen_mod = @import("worldgen.zig");
const parallel = @import("../util/parallel.zig");
const assignids = @import("../assets/assignids_comptime.zig");
const biome_layers = @import("../assets/biome_layers.zig");
const io_fs = @import("../util/io_fs.zig");

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
pub const block_air: u16 = assignids.air;
pub const block_stone: u16 = assignids.terr_stone;
pub const block_bedrock: u16 = assignids.terr_bedrock;
pub const block_dirt: u16 = assignids.terr_dirt;
pub const block_water: u16 = assignids.water;
pub const blocks_per_chunk: usize = 16 * 256 * 16; // 65536

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
        b[blockIndex(lx, y, lz)] = raw;
        var top: i32 = y_dim - 1;
        while (top >= 0) : (top -= 1) {
            if ((b[blockIndex(lx, top, lz)] & 0xffff) != block_air) break;
        }
        self.setHeight(lx, lz, if (top < 0) 0 else @intCast(top));
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
    map_dir: ?[]u8 = null,
    spawns: [32]dtm.SpawnPoint = undefined,
    spawn_count: usize = 0,
    /// flat | baked | dem | proc. loadStockMap sets baked; --worldgen-seed sets proc.
    terrain_source: TerrainSource = .flat,
    worldgen: ?worldgen_mod.WorldGen = null,

    pub fn init(allocator: std.mem.Allocator, world_dir: []const u8) !World {
        io_fs.mkdirPath(allocator, world_dir);
        return .{
            .chunks = std.AutoHashMap(u64, Chunk).init(allocator),
            .world_dir = try allocator.dupe(u8, world_dir),
            .allocator = allocator,
        };
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
        if (self.heightmap) |*hm| hm.deinit();
        if (self.prefabs) |*p| p.deinit();
        if (self.water) |*w| w.deinit();
        if (self.biomes) |*b| b.deinit();
        if (self.map_dir) |d| self.allocator.free(d);
        self.heightmap = null;
        self.prefabs = null;
        self.water = null;
        self.biomes = null;

        self.heightmap = try dtm.loadFromWorldDir(self.allocator, map_dir);
        self.map_dir = try self.allocator.dupe(u8, map_dir);
        self.spawn_count = try dtm.loadSpawnPoints(self.allocator, map_dir, self.spawns[0..]);
        self.biomes = biomes_mod.tryLoad(self.allocator, map_dir) catch null;
        if (self.biomes) |*bm| {
            if (self.heightmap) |*hm| bm.scale = @max(1, @divTrunc(hm.width, @max(1, bm.width)));
        }
        self.terrain_source = .baked;
        self.worldgen = null;

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

        self.prefabs = prefabs_mod.loadFromWorldDir(self.allocator, map_dir, prefab_root) catch null;
        self.water = water_mod.loadFromWorldDir(self.allocator, map_dir) catch null;
    }

    pub fn deinit(self: *World) void {
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
    /// roaming/malicious peer cannot grow the map without bound. ~65 KiB
    /// per block-allocated chunk → cap ≈ 256 MiB worst case.
    pub const max_resident_chunks: usize = 4096;

    fn evictOneChunk(self: *World, keep_key: u64) void {
        var it = self.chunks.iterator();
        while (it.next()) |e| {
            if (e.key_ptr.* == keep_key) continue;
            self.saveChunk(e.value_ptr) catch |err| std.debug.print(
                "zdtd: chunk ({d},{d}) save on evict failed: {s}; edits lost\n",
                .{ e.value_ptr.pos.x, e.value_ptr.pos.z, @errorName(err) },
            );
            e.value_ptr.deinitBlocks();
            _ = self.chunks.remove(e.key_ptr.*);
            return;
        }
    }

    pub fn getOrCreate(self: *World, pos: ChunkPos) !*Chunk {
        const k = pos.hash();
        if (self.chunks.count() >= max_resident_chunks and self.chunks.get(k) == null) {
            self.evictOneChunk(k);
        }
        const gop = try self.chunks.getOrPut(k);
        if (!gop.found_existing) {
            gop.value_ptr.* = Chunk.generateFlat(pos);
            if (self.terrain_source == .proc) {
                if (self.worldgen) |*wg| {
                    wg.fillHeights(pos.x, pos.z, &gop.value_ptr.heights);
                    // Single-biome dirt/stone/bedrock (AssignIds pins via defaultStack).
                    gop.value_ptr.ensureBlocksWithStack(self.allocator, biome_layers.defaultStack()) catch {};
                }
            } else {
                if (self.heightmap) |*hm| {
                    hm.fillChunkHeights(pos.x, pos.z, &gop.value_ptr.heights, sea_level);
                }
                // Terrain columns from biomes.xml layers (before POI paint / disk load).
                const biome_id: u8 = if (self.biomes) |*bm| bm.chunkDominant(pos.x, pos.z) else 3;
                const stack = self.biome_layers_table.stackFor(biome_id);
                gop.value_ptr.ensureBlocksWithStack(self.allocator, stack) catch {};
                if (self.prefabs) |*pf| {
                    pf.applyToChunkHeights(pos.x, pos.z, &gop.value_ptr.heights);
                    // Stock .tts block paint into this chunk only (no setBlockWorld re-entry).
                    const PaintCtx = struct {
                        c: *Chunk,
                        a: std.mem.Allocator,
                        base_x: i32,
                        base_z: i32,
                        fn put(ctx: ?*anyopaque, wx: i32, wy: i32, wz: i32, raw: u32, tex: u64, dens: ?u8) void {
                            const pc: *@This() = @ptrCast(@alignCast(ctx.?));
                            const lx = wx - pc.base_x;
                            const lz = wz - pc.base_z;
                            if (lx < 0 or lx >= 16 or lz < 0 or lz >= 16) return;
                            if (wy < 0 or wy >= y_dim) return;
                            pc.c.setBlockTexDens(pc.a, lx, wy, lz, raw, tex, dens) catch {};
                        }
                    };
                    var pc: PaintCtx = .{
                        .c = gop.value_ptr,
                        .a = self.allocator,
                        .base_x = pos.x * 16,
                        .base_z = pos.z * 16,
                    };
                    pf.applyTtsPaintToChunk(pos.x, pos.z, PaintCtx.put, &pc);
                }
                if (self.water) |*wt| {
                    wt.applyToChunkHeights(pos.x, pos.z, &gop.value_ptr.heights);
                }
            }
            // Player edits / first-touch cache win over regen.
            self.loadChunk(gop.value_ptr) catch |err| {
                if (err != error.FileNotFound) std.debug.print(
                    "zdtd: chunk ({d},{d}) load failed: {s}; regenerated\n",
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
        const t = worldToChunk(x, z);
        const c = try self.getOrCreate(t.pos);
        return c.isSolid(t.lx, y, t.lz);
    }

    fn chunkPath(self: *World, pos: ChunkPos, buf: []u8) ![]const u8 {
        return try std.fmt.bufPrint(buf, "{s}/c_{d}_{d}.zch", .{ self.world_dir, pos.x, pos.z });
    }

    pub fn saveChunk(self: *World, c: *const Chunk) !void {
        var path_buf: [512]u8 = undefined;
        const path = try self.chunkPath(c.pos, &path_buf);
        // v3: magic ZCH3, pos, heights, has_blocks u8, optional blocks as u32 rawData.
        // (v2 ZCH2 was u16 type-only; discarded on load so rotation/meta is not lost.)
        var hdr: [16]u8 = undefined;
        hdr[0] = 'Z';
        hdr[1] = 'C';
        hdr[2] = 'H';
        hdr[3] = '3';
        std.mem.writeInt(i32, hdr[4..8], c.pos.x, .little);
        std.mem.writeInt(i32, hdr[8..12], c.pos.z, .little);
        hdr[12] = if (c.blocks != null) 1 else 0;
        hdr[13] = 0;
        hdr[14] = 0;
        hdr[15] = 0;
        if (c.blocks) |b| {
            const bytes = std.mem.sliceAsBytes(b);
            var payload = try self.allocator.alloc(u8, hdr.len + c.heights.len + bytes.len);
            defer self.allocator.free(payload);
            @memcpy(payload[0..hdr.len], &hdr);
            @memcpy(payload[hdr.len..][0..c.heights.len], &c.heights);
            @memcpy(payload[hdr.len + c.heights.len ..], bytes);
            try io_fs.writeFile(self.allocator, path, payload);
        } else {
            var payload: [16 + 256]u8 = undefined;
            @memcpy(payload[0..16], &hdr);
            @memcpy(payload[16..], &c.heights);
            try io_fs.writeFile(self.allocator, path, payload[0 .. 16 + c.heights.len]);
        }
    }

    pub fn loadChunk(self: *World, c: *Chunk) !void {
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
            const has_blocks = data[12] == 1;
            if (data.len < 16 + c.heights.len) return error.ReadFailed;
            @memcpy(&c.heights, data[16..][0..c.heights.len]);
            if (has_blocks) {
                if (data[3] == '3') {
                    try c.ensureBlocks(self.allocator);
                    const b = c.blocks.?;
                    const bytes = std.mem.sliceAsBytes(b);
                    const off = 16 + c.heights.len;
                    if (data.len < off + bytes.len) return error.ReadFailed;
                    @memcpy(bytes, data[off..][0..bytes.len]);
                }
                // ZCH2 u16 type-only: keep heights only; blocks regenerate from DTM+TTS.
            }
        } else {
            // v1: 12-byte hdr then heights.
            if (data.len < 12 + c.heights.len) return error.ReadFailed;
            @memcpy(&c.heights, data[12..][0..c.heights.len]);
        }
        c.dirty = false;
    }

    pub fn saveAll(self: *World) !void {
        var list: [512]*Chunk = undefined;
        var n: usize = 0;
        var it = self.chunks.iterator();
        while (it.next()) |e| {
            if (!e.value_ptr.dirty) continue;
            if (n >= list.len) {
                try self.saveChunkSlice(list[0..n]);
                n = 0;
            }
            list[n] = e.value_ptr;
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
                    ctx.world.saveChunk(ctx.chunks[i]) catch {
                        _ = ctx.failed.store(1, .monotonic);
                        continue;
                    };
                    ctx.chunks[i].dirty = false;
                }
            }
        };
        var failed: std.atomic.Value(u8) = .init(0);
        parallel.forRanges(chunks.len, SaveCtx{ .world = self, .chunks = chunks, .failed = &failed }, SaveCtx.work);
        if (failed.load(.monotonic) != 0) return error.SaveFailed;
    }
};

test "proc worldgen getOrCreate heights from seed" {
    io_fs.mkdirPathSimple("worlds");
    io_fs.mkdirPathSimple("worlds/zdtd_proc_test");
    var w = try World.init(std.testing.allocator, "worlds/zdtd_proc_test");
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
    // Same seed regenerates identical heights after cache drop.
    if (w.chunks.fetchRemove(ChunkPos.hash(.{ .x = 2, .z = -1 }))) |kv| {
        var dead = kv.value;
        dead.deinitBlocks();
    }
    const c2 = try w.getOrCreate(.{ .x = 2, .z = -1 });
    try std.testing.expectEqual(h0, c2.heightAt(5, 7));
}

test "flat world set dig persist" {
    const dir = "worlds/zdtd_test_world";
    io_fs.deleteFileSimple("worlds/zdtd_test_world/c_0_0.zch");
    io_fs.mkdirPathSimple("worlds");
    io_fs.mkdirPathSimple(dir);

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
