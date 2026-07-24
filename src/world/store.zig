//! Authoritative block world: 16×256×16 columns, DTM heights, .zch2 disk.

const std = @import("std");
const linux = std.os.linux;
const dtm = @import("dtm.zig");
const prefabs_mod = @import("prefabs.zig");
const water_mod = @import("water.zig");
const biomes_mod = @import("biomes.zig");
const parallel = @import("../util/parallel.zig");

pub const chunk_size: i32 = 16;
pub const y_dim: i32 = 256;
pub const sea_level: u8 = 64;
pub const block_air: u16 = 0;
pub const block_dirt: u16 = 1;
pub const block_stone: u16 = 2;
pub const block_bedrock: u16 = 3;
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
    heights: [256]u8 = .{sea_level} ** 256,
    /// Full columns when allocated (lazy).
    blocks: ?[]u16 = null,
    /// Per-block textureFull paint (parallel to blocks), lazy. 0 = unpainted.
    /// Only allocated when a painted block is set (POIs); low 48 bits wired.
    textures: ?[]u64 = null,
    dirty: bool = false,
    allocator: ?std.mem.Allocator = null,

    pub fn generateFlat(pos: ChunkPos) Chunk {
        return .{ .pos = pos };
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
    }

    pub fn texAt(self: *const Chunk, lx: i32, y: i32, lz: i32) u64 {
        if (y < 0 or y >= y_dim) return 0;
        if (self.textures) |t| return t[blockIndex(lx, y, lz)];
        return 0;
    }

    /// Set a block plus its paint texture (allocates the texture plane lazily).
    pub fn setBlockTex(self: *Chunk, allocator: std.mem.Allocator, lx: i32, y: i32, lz: i32, id: u16, tex: u64) !void {
        try self.setBlock(allocator, lx, y, lz, id);
        if (tex == 0 and self.textures == null) return; // no paint plane needed yet
        if (self.textures == null) {
            const t = try allocator.alloc(u64, blocks_per_chunk);
            @memset(t, 0);
            self.textures = t;
        }
        self.textures.?[blockIndex(lx, y, lz)] = tex;
    }

    pub fn heightAt(self: *const Chunk, lx: i32, lz: i32) u8 {
        return self.heights[@intCast(lx + lz * chunk_size)];
    }

    pub fn setHeight(self: *Chunk, lx: i32, lz: i32, h: u8) void {
        self.heights[@intCast(lx + lz * chunk_size)] = h;
        self.dirty = true;
    }

    fn ensureBlocks(self: *Chunk, allocator: std.mem.Allocator) !void {
        if (self.blocks != null) return;
        self.allocator = allocator;
        const b = try allocator.alloc(u16, blocks_per_chunk);
        @memset(b, block_air);
        var lz: i32 = 0;
        while (lz < 16) : (lz += 1) {
            var lx: i32 = 0;
            while (lx < 16) : (lx += 1) {
                const h = self.heightAt(lx, lz);
                var y: i32 = 0;
                while (y <= h and y < y_dim) : (y += 1) {
                    const id: u16 = if (y == 0) block_bedrock else if (y + 3 < h) block_stone else block_dirt;
                    b[blockIndex(lx, y, lz)] = id;
                }
            }
        }
        self.blocks = b;
    }

    pub fn blockAt(self: *const Chunk, lx: i32, y: i32, lz: i32) u16 {
        if (y < 0 or y >= y_dim) return block_air;
        if (self.blocks) |b| return b[blockIndex(lx, y, lz)];
        const h = self.heightAt(lx, lz);
        if (y > h) return block_air;
        if (y == 0) return block_bedrock;
        if (y + 3 < h) return block_stone;
        return block_dirt;
    }

    pub fn setBlock(self: *Chunk, allocator: std.mem.Allocator, lx: i32, y: i32, lz: i32, id: u16) !void {
        if (y < 0 or y >= y_dim) return;
        try self.ensureBlocks(allocator);
        const b = self.blocks.?;
        b[blockIndex(lx, y, lz)] = id;
        // recompute height
        var top: i32 = y_dim - 1;
        while (top >= 0) : (top -= 1) {
            if (b[blockIndex(lx, top, lz)] != block_air) break;
        }
        self.setHeight(lx, lz, if (top < 0) 0 else @intCast(top));
        self.dirty = true;
    }

    pub fn isSolid(self: *const Chunk, lx: i32, y: i32, lz: i32) bool {
        const id = self.blockAt(lx, y, lz);
        return id != block_air and id != 6; // water
    }
};

fn mkdirP(path: []const u8) void {
    var buf: [512]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    var i: usize = 1;
    while (i < path.len) : (i += 1) {
        if (buf[i] != '/') continue;
        buf[i] = 0;
        _ = linux.mkdir(buf[0..i :0].ptr, 0o755);
        buf[i] = '/';
    }
    var zbuf: [513]u8 = undefined;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    _ = linux.mkdir(zbuf[0..path.len :0].ptr, 0o755);
}

pub const World = struct {
    chunks: std.AutoHashMap(u64, Chunk),
    world_dir: []u8,
    allocator: std.mem.Allocator,
    heightmap: ?dtm.Heightmap = null,
    prefabs: ?prefabs_mod.Index = null,
    water: ?water_mod.Sources = null,
    biomes: ?biomes_mod.BiomeMap = null,
    map_dir: ?[]u8 = null,
    spawns: [32]dtm.SpawnPoint = undefined,
    spawn_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, world_dir: []const u8) !World {
        mkdirP(world_dir);
        return .{
            .chunks = std.AutoHashMap(u64, Chunk).init(allocator),
            .world_dir = try allocator.dupe(u8, world_dir),
            .allocator = allocator,
        };
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
            self.saveChunk(e.value_ptr) catch {};
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
            if (self.heightmap) |*hm| {
                hm.fillChunkHeights(pos.x, pos.z, &gop.value_ptr.heights, sea_level);
            }
            if (self.prefabs) |*pf| {
                pf.applyToChunkHeights(pos.x, pos.z, &gop.value_ptr.heights);
                // Stock .tts block paint into this chunk only (no setBlockWorld re-entry).
                const PaintCtx = struct {
                    c: *Chunk,
                    a: std.mem.Allocator,
                    base_x: i32,
                    base_z: i32,
                    fn put(ctx: ?*anyopaque, wx: i32, wy: i32, wz: i32, block_id: u16, tex: u64) void {
                        const pc: *@This() = @ptrCast(@alignCast(ctx.?));
                        const lx = wx - pc.base_x;
                        const lz = wz - pc.base_z;
                        if (lx < 0 or lx >= 16 or lz < 0 or lz >= 16) return;
                        if (wy < 0 or wy >= y_dim) return;
                        pc.c.setBlockTex(pc.a, lx, wy, lz, block_id, tex) catch {};
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
            self.loadChunk(gop.value_ptr) catch {};
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

    pub fn heightWorld(self: *World, x: i32, z: i32) !u8 {
        const t = worldToChunk(x, z);
        const c = try self.getOrCreate(t.pos);
        return c.heightAt(t.lx, t.lz);
    }

    pub fn isSolidWorld(self: *World, x: i32, y: i32, z: i32) !bool {
        const t = worldToChunk(x, z);
        const c = try self.getOrCreate(t.pos);
        return c.isSolid(t.lx, y, t.lz);
    }

    fn chunkPathZ(self: *World, pos: ChunkPos, buf: []u8) ![:0]const u8 {
        const s = try std.fmt.bufPrint(buf[0 .. buf.len - 1], "{s}/c_{d}_{d}.zch", .{ self.world_dir, pos.x, pos.z });
        buf[s.len] = 0;
        return buf[0..s.len :0];
    }

    pub fn saveChunk(self: *World, c: *const Chunk) !void {
        var path_buf: [512]u8 = undefined;
        const path = try self.chunkPathZ(c.pos, &path_buf);
        const rc = linux.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
        if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
        const fd: i32 = @intCast(rc);
        defer _ = linux.close(fd);
        // v2: magic ZCH2, pos, heights, has_blocks u8, optional blocks
        var hdr: [16]u8 = undefined;
        hdr[0] = 'Z';
        hdr[1] = 'C';
        hdr[2] = 'H';
        hdr[3] = '2';
        std.mem.writeInt(i32, hdr[4..8], c.pos.x, .little);
        std.mem.writeInt(i32, hdr[8..12], c.pos.z, .little);
        hdr[12] = if (c.blocks != null) 1 else 0;
        hdr[13] = 0;
        hdr[14] = 0;
        hdr[15] = 0;
        try writeAll(fd, &hdr, hdr.len);
        try writeAll(fd, &c.heights, c.heights.len);
        if (c.blocks) |b| {
            const bytes = std.mem.sliceAsBytes(b);
            try writeAll(fd, bytes.ptr, bytes.len);
        }
    }

    /// Full write or error: a short chunk write corrupts the persist path.
    fn writeAll(fd: i32, ptr: [*]const u8, len: usize) !void {
        var off: usize = 0;
        while (off < len) {
            const n = linux.write(fd, ptr + off, len - off);
            if (linux.errno(n) != .SUCCESS or n == 0) return error.WriteFailed;
            off += @intCast(n);
        }
    }

    /// Full read or error (EOF before len is an error).
    fn readAll(fd: i32, ptr: [*]u8, len: usize) !void {
        var off: usize = 0;
        while (off < len) {
            const n = linux.read(fd, ptr + off, len - off);
            if (linux.errno(n) != .SUCCESS or n == 0) return error.ReadFailed;
            off += @intCast(n);
        }
    }

    pub fn loadChunk(self: *World, c: *Chunk) !void {
        var path_buf: [512]u8 = undefined;
        const path = try self.chunkPathZ(c.pos, &path_buf);
        const rc = linux.open(path.ptr, .{ .ACCMODE = .RDONLY }, 0);
        if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
        const fd: i32 = @intCast(rc);
        defer _ = linux.close(fd);
        var hdr: [16]u8 = undefined;
        const nr = linux.read(fd, &hdr, 12);
        if (linux.errno(nr) != .SUCCESS) return error.ReadFailed;
        if (nr >= 4 and hdr[0] == 'Z' and hdr[1] == 'C' and hdr[2] == 'H' and hdr[3] == '2') {
            // need rest of header
            if (nr < 16) try readAll(fd, hdr[@intCast(nr)..].ptr, 16 - @as(usize, @intCast(nr)));
            try readAll(fd, &c.heights, c.heights.len);
            if (hdr[12] == 1) {
                try c.ensureBlocks(self.allocator);
                const b = c.blocks.?;
                const bytes = std.mem.sliceAsBytes(b);
                try readAll(fd, bytes.ptr, bytes.len);
            }
        } else {
            // v1: 12-byte hdr (cx,cz,ver) already partially in hdr: re-open style
            // If first 4 bytes were i32 cx, we misread. Detect v1: not ZCH2.
            // Rewind and read v1.
            _ = linux.lseek(fd, 0, linux.SEEK.SET);
            var h12: [12]u8 = undefined;
            try readAll(fd, &h12, h12.len);
            try readAll(fd, &c.heights, c.heights.len);
        }
        c.dirty = false;
    }

    pub fn saveAll(self: *World) !void {
        var list: [512]*const Chunk = undefined;
        var n: usize = 0;
        var it = self.chunks.iterator();
        while (it.next()) |e| {
            if (!e.value_ptr.dirty and e.value_ptr.blocks == null) {
                // still save heights-only chunks once? save dirty only for perf
                // save all that exist to keep simple
            }
            if (n >= list.len) {
                try self.saveChunkSlice(list[0..n]);
                n = 0;
            }
            list[n] = e.value_ptr;
            n += 1;
        }
        try self.saveChunkSlice(list[0..n]);
    }

    fn saveChunkSlice(self: *World, chunks: []const *const Chunk) !void {
        if (chunks.len == 0) return;
        if (chunks.len < parallel.min_parallel_items) {
            for (chunks) |c| try self.saveChunk(c);
            return;
        }
        const SaveCtx = struct {
            world: *World,
            chunks: []const *const Chunk,
            failed: *std.atomic.Value(u8),
            fn work(ctx: @This(), begin: usize, end: usize) void {
                var i = begin;
                while (i < end) : (i += 1) {
                    ctx.world.saveChunk(ctx.chunks[i]) catch {
                        _ = ctx.failed.store(1, .monotonic);
                    };
                }
            }
        };
        var failed: std.atomic.Value(u8) = .init(0);
        parallel.forRanges(chunks.len, SaveCtx{ .world = self, .chunks = chunks, .failed = &failed }, SaveCtx.work);
        if (failed.load(.monotonic) != 0) return error.SaveFailed;
    }
};

test "flat world set dig persist" {
    const dir = "worlds/zdtd_test_world";
    _ = std.os.linux.unlink(@as([*:0]const u8, @ptrCast("worlds/zdtd_test_world/c_0_0.zch")));
    mkdirP("worlds");
    mkdirP(dir);

    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    try w.setBlockWorld(5, 70, 5, block_dirt);
    try w.setBlockWorld(6, 71, 5, block_stone);
    try std.testing.expectEqual(block_dirt, try w.blockWorld(5, 70, 5));
    try std.testing.expectEqual(block_stone, try w.blockWorld(6, 71, 5));
    try w.saveAll();

    var w2 = try World.init(std.testing.allocator, dir);
    defer w2.deinit();
    const c = try w2.getOrCreate(.{ .x = 0, .z = 0 });
    try std.testing.expectEqual(@as(u8, 71), c.heightAt(6, 5));
    // Full columns must reload so dig/build is authoritative after restart.
    try std.testing.expectEqual(block_dirt, try w2.blockWorld(5, 70, 5));
    try std.testing.expectEqual(block_stone, try w2.blockWorld(6, 71, 5));
}

test "stock map heights via DTM if Navezgane present" {
    const map = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Worlds/Navezgane";
    var path_z: [512]u8 = undefined;
    @memcpy(path_z[0..map.len], map);
    path_z[map.len] = 0;
    const rc = linux.open((path_z[0..map.len :0]).ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.SkipZigTest;
    _ = linux.close(@intCast(rc));

    mkdirP("worlds");
    mkdirP("worlds/zdtd_navezgane_test");
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
