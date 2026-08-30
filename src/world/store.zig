//! Authoritative block world: 16×256×16 columns, DTM heights, ZCH3 disk (.zch).
//! v3 magic ZCH3: heights + optional u32 rawData + optional texture/density/
//! damage channels (flags in header). ZCH2 u16 type-only is accepted on load
//! for heights only (blocks regenerate from DTM+TTS). See ADR 0011.

const std = @import("std");
const dtm = @import("dtm.zig");
const prefabs_mod = @import("prefabs.zig");
pub const prefabs = prefabs_mod;
const water_mod = @import("water.zig");
const biomes_mod = @import("biomes.zig");
const worldgen_mod = @import("worldgen.zig");
const parallel = @import("../util/parallel.zig");
const assignids = @import("../assets/assignids_comptime.zig");
const biome_layers = @import("../assets/biome_layers.zig");
const weather_mod = @import("weather.zig");
const io_fs = @import("../util/io_fs.zig");
const chunk_flush = @import("chunk_flush.zig");
const tts = @import("tts.zig");
const rules_mod = @import("../ecs/rules.zig");
const protocol = @import("../protocol.zig");
pub const typeId = tts.typeId;

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

/// Stock chunk X/Z span, 16 blocks (WorldConstants; stock_facts block_x/z_dim).
pub const chunk_size: i32 = 16;
/// Stock chunk Y dim 256 (WorldConstants ChunkBlockYDim; stock_facts block_y_dim).
pub const y_dim: i32 = 256;
/// Default empty-world height (zdtd constant). Stock WorldConstants.WaterLevel =
/// Block.cWaterLevel = **62.88** (IL: Block.cctor ldc.r4 62.88; WorldConstants cctor
/// reads it). zdtd's u8 64 diverges by +1.12 and cannot hold the fraction - tracked
/// in the divergence register.
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

/// Offline/test terrain id set: the module pins verbatim. Chunks created
/// outside a World (unit fixtures) fall back to this in rawAt/isSolid (A38);
/// live chunks point at `World.terrain_ids` after resolveTerrainIds runs.
const terrain_pins = TerrainIds{};

/// Runtime terrain type ids (AssignIds names). Defaults match module pins.
pub const TerrainIds = struct {
    air: u16 = block_air,
    stone: u16 = block_stone,
    bedrock: u16 = block_bedrock,
    dirt: u16 = block_dirt,
    water: u16 = block_water,
    forest_ground: u16 = assignids.terr_forest_ground,
    /// Prefab TTS paint skips the filler surface types (A37); resolved like the
    /// terrain ids so modded dumps keep the skip correct.
    terrain_filler: u16 = assignids.terrain_filler,
    terrain_filler_adaptive: u16 = assignids.terrain_filler_adaptive,

    /// Resolve from live idByName dump. Missing names keep pin defaults (fail closed).
    pub fn resolve(self: *TerrainIds, lookup: *const fn (ctx: ?*anyopaque, name: []const u8) ?u16, ctx: ?*anyopaque) void {
        if (lookup(ctx, "air")) |id| self.air = id;
        if (lookup(ctx, "terrStone")) |id| self.stone = id;
        if (lookup(ctx, "terrBedrock")) |id| self.bedrock = id;
        if (lookup(ctx, "terrDirt")) |id| self.dirt = id;
        if (lookup(ctx, "water")) |id| self.water = id;
        if (lookup(ctx, "terrForestGround")) |id| self.forest_ground = id;
        if (lookup(ctx, "terrainFiller")) |id| self.terrain_filler = id;
        if (lookup(ctx, "terrainFillerAdaptive")) |id| self.terrain_filler_adaptive = id;
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
    // stock-ish: x + z*16 + y*256 (stock column height)
    return @intCast(lx + lz * 16 + y * 256);
}

pub const Chunk = struct {
    pos: ChunkPos,
    /// Active column height (wire profile; ADR geometry/wire-profiles). Stock
    /// 256; a taller profile (paired client mod) sets a bigger plane. Set by
    /// World.getOrCreate from the World profile at first touch.
    y_dim: u32 = 256,
    /// Live terrain type ids for the heightmap fallback + solid checks (A38).
    /// Set by World.getOrCreate; null in offline/tests, which keep the module
    /// pins. Points at World.terrain_ids (same lifetime as the World).
    terrain: ?*const TerrainIds = null,
    /// On-disk / stock-wire surface Y (0..255). API returns u16 for headroom.
    heights: [256]u8 = .{sea_level} ** 256,
    /// Stock `m_bTopSoilBroken` bitfield (32 bytes, 1 bit per XZ column):
    /// clear = topsoil intact (the client renders the top terrain block via
    /// MicroSplat splat maps), set = disturbed (client uses block textures).
    /// Fresh chunks start clear (stock fresh-world state); dig/upgrade/
    /// explosion paths set the bit via `setTopSoilBroken` (RE
    /// Chunk.SetTopSoilBroken IL=36, world-chunks.md). Persisted in ZCH3
    /// (trailing 32 bytes; old files without them load clear).
    topsoil: [32]u8 = [_]u8{0} ** 32,
    /// Full BlockValue.rawData columns when allocated (lazy). Type = low 16 bits.
    blocks: ?[]u32 = null,
    /// Per-block textureFull paint (parallel to blocks), lazy. 0 = unpainted.
    /// Only allocated when a painted block is set (POIs); low 48 bits wired.
    textures: ?[]u64 = null,
    /// Per-block density (stock sbyte as u8). Lazy; only cells with dens_set bit.
    densities: ?[]u8 = null,
    dens_set: ?[]u8 = null, // bitset: 1 = densities[i] is valid TTS paint
    /// Per-block absolute damage (u16 HP; the chunk wire damage channel and the
    /// C2S SetBlock number line). Lazy; null = no cell damaged. Persisted in
    /// ZCH3 (hdr flag 15) so damage survives chunk eviction and restarts.
    damages: ?[]u16 = null,
    /// Per-block stability byte plane (0..15; see world/stability.zig). Lazy
    /// derived state, never persisted: computed once on first touch with
    /// reset + spread semantics (stock ResetStability + DistributeStability).
    stability: ?[]u8 = null,
    dirty: bool = false,
    /// Runtime-only: server finished its one-time storage-TE scan of this chunk.
    te_scanned: bool = false,
    /// Power nodes re-derived from this chunk's blocks after a restart (GAP
    /// power persistence); the grid is runtime state rebuilt on first touch.
    power_scanned: bool = false,
    /// Runtime-only: dominant biome, computed once per resident chunk (the
    /// biome map is static). Recomputing costs 256 map lookups per chunk send.
    biome_id: ?u8 = null,
    /// `World.touch_seq` value of the last `getOrCreate` for this chunk; the
    /// eviction victim is the smallest one. Runtime-only, never persisted.
    last_touch: u64 = 0,
    allocator: ?std.mem.Allocator = null,

    pub fn generateFlat(pos: ChunkPos) Chunk {
        return .{ .pos = pos };
    }

    /// Block-plane index for (lx, y, lz): x + z*16 + y*256. The y-multiplier
    /// is the fixed ChunkAreaDim (16×16 = 256) in EVERY dialect - the plane
    /// only grows in cell count (256 × y_dim), never in index stride.
    /// `y` must be in bounds (callers check first).
    pub fn blockIndex(self: *const Chunk, lx: i32, y: i32, lz: i32) usize {
        _ = self;
        return @intCast(lx + lz * 16 + y * 256);
    }

    /// Dense block-plane cell count (16 × y_dim × 16; 65536 stock).
    pub fn planeCells(self: *const Chunk) usize {
        return @intCast(16 * self.y_dim * 16);
    }

    /// dens_set bitset bytes for one chunk (planeCells bits).
    pub fn densSetBytes(self: *const Chunk) usize {
        return @intCast((16 * self.y_dim * 16 + 7) / 8);
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
        if (self.damages) |d| {
            if (self.allocator) |a| a.free(d);
            self.damages = null;
        }
        if (self.stability) |s| {
            if (self.allocator) |a| a.free(s);
            self.stability = null;
        }
    }

    pub fn texAt(self: *const Chunk, lx: i32, y: i32, lz: i32) u64 {
        if (y < 0 or y >= self.y_dim) return 0;
        if (self.textures) |t| return t[self.blockIndex(lx, y, lz)];
        return 0;
    }

    pub fn densAt(self: *const Chunk, lx: i32, y: i32, lz: i32) ?u8 {
        if (y < 0 or y >= self.y_dim) return null;
        const dens = self.densities orelse return null;
        const set = self.dens_set orelse return null;
        const idx = self.blockIndex(lx, y, lz);
        const bit: u8 = @as(u8, 1) << @intCast(idx % 8);
        if (set[idx / 8] & bit == 0) return null;
        return dens[idx];
    }

    /// Absolute damage (u16) at a cell; 0 when the plane is absent (no cell in
    /// this chunk is damaged). Read path for the chunk wire damage channel.
    pub fn dmgAt(self: *const Chunk, lx: i32, y: i32, lz: i32) u16 {
        if (y < 0 or y >= self.y_dim) return 0;
        const d = self.damages orelse return 0;
        return d[self.blockIndex(lx, y, lz)];
    }

    /// Write absolute damage (lazy plane alloc, marks the chunk dirty so ZCH3
    /// persists it). Init/load/admin + per-edit paths; the wire encoder only
    /// reads the plane, never allocates.
    pub fn setDmg(self: *Chunk, allocator: std.mem.Allocator, lx: i32, y: i32, lz: i32, abs: u16) !void {
        if (y < 0 or y >= self.y_dim) return;
        const d = self.damages orelse blk: {
            const p = try allocator.alloc(u16, self.planeCells());
            @memset(p, 0);
            self.damages = p;
            if (self.allocator == null) self.allocator = allocator;
            break :blk p;
        };
        d[self.blockIndex(lx, y, lz)] = abs;
        self.dirty = true;
    }

    /// Clear damage at a cell. No-op when the plane is absent.
    pub fn clearDmg(self: *Chunk, lx: i32, y: i32, lz: i32) void {
        if (y < 0 or y >= self.y_dim) return;
        const d = self.damages orelse return;
        d[self.blockIndex(lx, y, lz)] = 0;
        self.dirty = true;
    }

    /// Stability byte plane (see world/stability.zig); 0 when not computed.
    pub fn stabilityAt(self: *const Chunk, lx: i32, y: i32, lz: i32) u8 {
        if (y < 0 or y >= self.y_dim) return 0;
        const s = self.stability orelse return 0;
        return s[self.blockIndex(lx, y, lz)];
    }

    /// Allocate the per-block stability plane if absent (init/load path).
    pub fn ensureStability(self: *Chunk, allocator: std.mem.Allocator) ![]u8 {
        if (self.stability) |s| return s;
        const s = try allocator.alloc(u8, self.planeCells());
        @memset(s, 0);
        self.stability = s;
        if (self.allocator == null) self.allocator = allocator;
        return s;
    }

    /// Write one stability byte (plane must exist; caller ensured it).
    pub fn setStabilityByte(self: *Chunk, lx: i32, y: i32, lz: i32, v: u8) void {
        const s = self.stability orelse return;
        s[self.blockIndex(lx, y, lz)] = v;
    }

    /// Fill lake water from the water_info.xml sources: every column whose
    /// terrain surface sits below a source surface gets water blocks from the
    /// bed up to that surface (the water channel mass is derived from the
    /// block type at encode time). Must run after heights are final, i.e. after
    /// `Sources.applyToChunkHeights` and block materialization.
    pub fn applyWaterSources(self: *Chunk, cx: i32, cz: i32, sources: *const water_mod.Sources, water_id: u16) void {
        const base_x = cx * 16;
        const base_z = cz * 16;
        const radius: i32 = 12;
        const blocks = self.blocks orelse return;
        var lz: i32 = 0;
        while (lz < 16) : (lz += 1) {
            var lx: i32 = 0;
            while (lx < 16) : (lx += 1) {
                const wy = sources.waterYNear(base_x + lx, base_z + lz, radius) orelse continue;
                const idx: usize = @intCast(lx + lz * 16);
                const h = self.heights[idx];
                if (h >= wy) continue; // land or shoreline at/above the surface
                var y: i32 = @as(i32, h) + 1;
                while (y <= wy and y < self.y_dim) : (y += 1) {
                    blocks[self.blockIndex(lx, y, lz)] = water_id;
                }
            }
        }
    }

    /// Mark one column's topsoil disturbed (stock SetTopSoilBroken: bit set,
    /// never cleared). lx/lz are chunk-local 0..15. The client switches the
    /// column from MicroSplat splat rendering to block textures (RE
    /// Chunk.SetTopSoilBroken IL=36, world-chunks.md).
    pub fn setTopSoilBroken(self: *Chunk, lx: i32, lz: i32) void {
        const idx: u32 = @intCast(lz * 16 + lx);
        self.topsoil[idx >> 3] |= @as(u8, 1) << @intCast(idx & 7);
        self.dirty = true;
    }

    pub fn setBlockTexDens(self: *Chunk, allocator: std.mem.Allocator, lx: i32, y: i32, lz: i32, raw: u32, tex: u64, dens: ?u8) !void {
        try self.setBlockRaw(allocator, lx, y, lz, raw);
        if (tex != 0 or self.textures != null) {
            if (self.textures == null) {
                const t = try allocator.alloc(u64, self.planeCells());
                @memset(t, 0);
                self.textures = t;
            }
            self.textures.?[self.blockIndex(lx, y, lz)] = tex;
        }
        if (dens) |d| {
            if (self.densities == null) {
                const p = try allocator.alloc(u8, self.planeCells());
                @memset(p, 0);
                self.densities = p;
            }
            if (self.dens_set == null) {
                const bits = try allocator.alloc(u8, self.densSetBytes());
                @memset(bits, 0);
                self.dens_set = bits;
            }
            const idx = self.blockIndex(lx, y, lz);
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
        const t = self.terrain orelse &terrain_pins;
        try self.ensureBlocksWithStack(
            allocator,
            biome_layers.stackFromIds(t.forest_ground, t.dirt, t.stone, t.bedrock),
        );
    }

    /// Materialize full block plane with a biome stack (called from World.getOrCreate).
    pub fn ensureBlocksWithStack(self: *Chunk, allocator: std.mem.Allocator, stack: biome_layers.Stack) !void {
        if (self.blocks != null) return;
        self.allocator = allocator;
        const b = try allocator.alloc(u32, self.planeCells());
        const air = (self.terrain orelse &terrain_pins).air;
        @memset(b, air);
        var col: [256]u16 = undefined;
        var lz: i32 = 0;
        while (lz < 16) : (lz += 1) {
            var lx: i32 = 0;
            while (lx < 16) : (lx += 1) {
                const h = self.heightAt(lx, lz);
                generateColumnIds(h, stack, &col);
                var y: i32 = 0;
                while (y <= h and y < self.y_dim) : (y += 1) {
                    b[self.blockIndex(lx, y, lz)] = col[@intCast(y)];
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
        const b = try allocator.alloc(u32, self.planeCells());
        self.blocks = b;
        wg.generateChunkBlocks(self.pos.x, self.pos.z, &self.heights, b);
        // RWG water table: basins below the stock water level become lakes
        // (W4); the id comes from the live terrain set so a modded dump keeps
        // the correct water block.
        const t = self.terrain orelse &terrain_pins;
        worldgen_mod.WorldGen.fillWaterTable(&self.heights, b, t.water, t.air);
    }

    /// Block type id (low 16 of rawData).
    pub fn blockAt(self: *const Chunk, lx: i32, y: i32, lz: i32) u16 {
        return tts.typeId(self.rawAt(lx, y, lz));
    }

    /// Full BlockValue.rawData for wire packing. The no-blocks fallback
    /// synthesizes terrain from the height map using the live terrain ids
    /// (A38); offline/test chunks keep the module pins via `terrain_pins`.
    pub fn rawAt(self: *const Chunk, lx: i32, y: i32, lz: i32) u32 {
        const t = self.terrain orelse &terrain_pins;
        if (y < 0 or y >= self.y_dim) return t.air;
        if (self.blocks) |b| return b[self.blockIndex(lx, y, lz)];
        const h = self.heightAt(lx, lz);
        if (y > h) return t.air;
        if (y == 0) return t.bedrock;
        if (y + 3 < h) return t.stone;
        if (y == h) return t.forest_ground;
        return t.dirt;
    }

    pub fn setBlock(self: *Chunk, allocator: std.mem.Allocator, lx: i32, y: i32, lz: i32, id: u16) !void {
        try self.setBlockRaw(allocator, lx, y, lz, id);
    }

    pub fn setBlockRaw(self: *Chunk, allocator: std.mem.Allocator, lx: i32, y: i32, lz: i32, raw: u32) !void {
        if (y < 0 or y >= self.y_dim) return;
        try self.ensureBlocks(allocator);
        const b = self.blocks.?;
        const idx = self.blockIndex(lx, y, lz);
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
                if ((b[self.blockIndex(lx, top, lz)] & 0xffff) != block_air) break;
            }
            self.setHeight(lx, lz, if (top < 0) 0 else @intCast(top));
        }
        self.dirty = true;
    }

    /// Write a decoration cell without moving the terrain surface.
    ///
    /// `setBlockRaw` raises `heights` for any solid block above the surface,
    /// which is right for player edits and wrong for decorations: a 7 tall tree
    /// would push the column's surface to the treetop, and heights feeds spawn
    /// placement, void rescue, movement validation and the deco height callback
    /// itself (trees would then stack on trees). Stock keeps the two apart too:
    /// `ChunkCluster::addDistantDecorationBlocks` writes through `SetBlockRaw`
    /// and never touches the terrain height map (asm.il 1126815-1127012).
    ///
    /// Density and paint are left as they are, mirroring the stock path's
    /// `SetDensityRaw(previous density)`.
    /// Mirror-write for the deco mirror (derived decoration, re-applied on
    /// every stream/reload - stock ChunkCluster.addDistantDecorationBlocks).
    /// Deliberately does NOT mark the chunk dirty: mirrored trees are not the
    /// player's data, so a clean session leaves no files (the deco mirror
    /// re-derives them). Real edits to a deco cell (harvest/place) go through
    /// `setBlockRaw` and persist normally.
    pub fn setBlockDecoRaw(self: *Chunk, allocator: std.mem.Allocator, lx: i32, y: i32, lz: i32, raw: u32) !void {
        if (y < 0 or y >= self.y_dim) return;
        try self.ensureBlocks(allocator);
        self.blocks.?[self.blockIndex(lx, y, lz)] = raw;
    }

    pub fn isSolid(self: *const Chunk, lx: i32, y: i32, lz: i32) bool {
        const t = self.terrain orelse &terrain_pins;
        const id = self.blockAt(lx, y, lz);
        return id != t.air and id != t.water;
    }

    /// Feet Y a walking body can occupy in column (lx,lz) near `from_y`, or null
    /// when the column offers no support with headroom in the band
    /// [from_y - drop, from_y + step_up].
    ///
    /// A feet cell `y` is standable when (y-1) is solid and the `body_height`
    /// cells from y up are clear. Scanning downward from the highest candidate
    /// picks the first surface a body would actually land on, which is what
    /// makes a POI floor win over the roof above it. `heightAt` cannot answer
    /// this: it is by invariant the topmost non-air block of the column, so
    /// `isSolid(heightAt + 1)` is false for every column by construction.
    pub fn standableY(self: *const Chunk, lx: i32, lz: i32, from_y: i32, step_up: i32, drop: i32) ?i32 {
        // Feet at 0 would sit on nothing (y=-1 is outside the world).
        const top = @min(from_y + step_up, self.y_dim - body_height);
        const bottom = @max(from_y - drop, 1);
        var y = top;
        while (y >= bottom) : (y -= 1) {
            if (!self.isSolid(lx, y - 1, lz)) continue;
            var h: i32 = 0;
            const clear = while (h < body_height) : (h += 1) {
                if (self.isSolid(lx, y + h, lz)) break false;
            } else true;
            if (clear) return y;
        }
        return null;
    }
};

/// Cells of vertical clearance a walking body needs (feet + head).
pub const body_height: i32 = 2;
/// Highest single-move step up a body takes without jumping (stock zombies
/// walk up one block).
pub const max_step_up: i32 = 1;
/// Deepest single-move drop a body takes voluntarily.
pub const max_drop: i32 = 3;

pub const World = struct {
    // Pointer-stable chunk store (GAP "Chunk pointer stability", 2026-08-29
    // PARTIAL): the map holds *Chunk (one allocation per chunk) instead of
    // inline Chunk values, so a chunk pointer held across a re-entrant
    // getOrCreate/blockWorld stays valid when the map resizes - a value-map
    // moved every chunk on resize and dangled the held pointer (bait-soak
    // segfault 5/5). Chunks are freed on eviction/deinit; residency is still
    // bounded by `max_resident_chunks`.
    chunks: std.AutoHashMapUnmanaged(u64, *Chunk),
    world_dir: []u8,
    allocator: std.mem.Allocator,
    heightmap: ?dtm.Heightmap = null,
    prefabs: ?prefabs_mod.Index = null,
    water: ?water_mod.Sources = null,
    /// Bounded water-leveling queue: block edits (dig to air / place water)
    /// enqueue here, and `levelWaterTick` pours connected basins on the tick
    /// (GAP "Water flow / physics", PARTIAL).
    leveler: water_mod.Leveler = .{},
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
    /// Active wire geometry profile (ADR geometry/wire-profiles): column height
    /// and derived layer/stride constants. Default stock (256); set by the Game
    /// from config. A non-stock profile requires a paired client mod and a
    /// matching save format; `validate()` is enforced at startup (fail closed).
    profile: protocol.WireProfile = .{},
    /// Elevation projection policy (ADR geometry): how the source's natural
    /// elevation maps onto the column. Set by the Game from `rules.geometry`
    /// (toml_bind); stock defaults are the identity fast path.
    geometry: rules_mod.Geometry = .{},
    /// Procedural terrain shaping params ([rules.worldgen], ADR 0021). Applied
    /// to the WorldGen at `enableProc`; defaults are byte-identical to the
    /// pre-lift generator constants.
    worldgen_params: rules_mod.WorldgenGroup = .{},
    worldgen: ?worldgen_mod.WorldGen = null,
    /// Door-id oracle (Game wires the blocks table): true when the id is a
    /// door block, so `isSolidWorld` treats an open door as passable.
    door_id_ctx: ?*anyopaque = null,
    door_id_fn: ?*const fn (?*anyopaque, u16) bool = null,
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
    /// Monotonic access stamp handed to `Chunk.last_touch` by `getOrCreate`,
    /// so eviction can pick the coldest resident. Driven purely by access
    /// order, which DST replay reproduces exactly.
    touch_seq: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, world_dir: []const u8) !World {
        io_fs.mkdirPath(world_dir);
        return .{
            .chunks = .empty,
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
        // No biomes.xml: the fallback column still has to use live dump ids,
        // not the comptime pins (those are a second authority after merge).
        if (!self.biome_layers_table.loaded) {
            self.biome_layers_table.default_stack = biome_layers.stackFromIds(
                self.terrain_ids.forest_ground,
                self.terrain_ids.dirt,
                self.terrain_ids.stone,
                self.terrain_ids.bedrock,
            );
        }
        self.syncWorldgenBiomes();
    }

    /// Active column height from the wire profile (stock 256). i32 to be a
    /// drop-in for the old `store.y_dim` module const in world-space bounds.
    pub fn yDim(self: *const World) i32 {
        return @intCast(self.profile.y_dim);
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
        var wg = worldgen_mod.WorldGen.init(seed);
        wg.applyParams(self.worldgen_params);
        self.worldgen = wg;
        self.syncWorldgenBiomes();
        // Proc worlds have no DTM spawn points: derive one from the generated
        // surface near the origin (deterministic per seed), so the player
        // never spawns buried or mid-air at the hardcoded (256,70,256).
        const sx: i32 = 256;
        const sz: i32 = 256;
        const h = self.heightWorld(sx, sz) catch 0;
        self.spawns[0] = .{ .x = sx, .y = @as(i32, @intCast(h)) + 2, .z = sz };
        self.spawn_count = 1;
    }

    /// Point the procedural generator at the loaded biome table (W3): more than
    /// one resolved biome turns on the biome field. A loaded table with even
    /// one biome still supplies XML surface stacks; pin defaultStack is only
    /// the no-table offline path.
    pub fn syncWorldgenBiomes(self: *World) void {
        if (self.worldgen) |*wg| {
            const n = self.biome_layers_table.biomeCount();
            wg.biome_n = n;
            wg.air_id = self.terrain_ids.air;
            wg.stone_id = self.terrain_ids.stone;
            wg.dirt_id = self.terrain_ids.dirt;
            wg.bedrock_id = self.terrain_ids.bedrock;
            wg.forest_id = self.terrain_ids.forest_ground;
            // Always attach the table when a default stack exists so the
            // material pass uses live/XML ids, not WorldGen.fillColumn pins.
            wg.biome_table = if (n >= 1 or self.biome_layers_table.default_stack.n > 0)
                &self.biome_layers_table
            else
                null;
        }
    }

    /// Procedural biome id at a chunk's center (W3): the same field that drove
    /// the surface fill, so the client's displayed biome matches the blocks.
    /// Falls back to the single-biome id (0) when the field is off.
    pub fn procBiomeAt(self: *const World, cx: i32, cz: i32) u8 {
        const wg = &self.worldgen.?;
        const wx = @as(f32, @floatFromInt(cx * worldgen_mod.chunk_size + worldgen_mod.chunk_size / 2));
        const wz = @as(f32, @floatFromInt(cz * worldgen_mod.chunk_size + worldgen_mod.chunk_size / 2));
        // Translate the resolved-list index to the real biomemap id (sparse).
        return self.biome_layers_table.biomeIdAt(wg.biomeAt(wx, wz));
    }

    pub fn loadStockMap(self: *World, map_dir: []const u8) !void {
        try self.loadStockMapEx(map_dir, null);
    }

    /// u8 fallback height for baked-DTM out-of-bounds samples (geometry sea).
    fn fallbackSeaU8(geo: rules_mod.Geometry) u8 {
        const s = @max(0.0, @min(geo.sea_level, 255.0));
        return @intFromFloat(s);
    }

    /// Rewrite a filled height plane through the geometry projection. Non-stock
    /// path only (the identity fast path skips it); profile max 255 until the
    /// wire-profile layer lands (ADR geometry/wire-profiles). The plane is u8,
    /// so the result clamps to 255 even if a future caller bypasses the
    /// [rules.geometry] validation.
    fn projectPlane(heights: *[256]u8, geo: rules_mod.Geometry, profile_max: u32) void {
        for (heights) |*h| h.* = @intCast(@min(255, geo.project(@floatFromInt(h.*), profile_max)));
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
            if (std.mem.findScalarLast(u8, map_dir, '/')) |slash| {
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
        while (it.next()) |e| {
            e.value_ptr.*.deinitBlocks();
            self.allocator.destroy(e.value_ptr.*);
        }
        if (self.heightmap) |*hm| hm.deinit();
        if (self.prefabs) |*p| p.deinit();
        if (self.water) |*w| w.deinit();
        if (self.biomes) |*b| b.deinit();
        self.biome_layers_table.deinit();
        if (self.map_dir) |d| self.allocator.free(d);
        self.chunks.deinit(self.allocator);
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
        // Coldest resident by `last_touch`, min key breaking ties (never the
        // HashMap walk order: that would pick different victims for the same
        // resident set, breaking DST replay under cap pressure). Keying on the
        // key alone pins the 4096 lowest keys forever, so every access to a
        // higher-key chunk pays a save + reload; with more in-view chunks than
        // the cap that is disk I/O on the 50 ms tick, per access.
        var best_key: ?u64 = null;
        var best_touch: u64 = 0;
        var it = self.chunks.iterator();
        while (it.next()) |e| {
            const k = e.key_ptr.*;
            if (k == keep_key) continue;
            const t = e.value_ptr.*.last_touch;
            if (best_key == null or t < best_touch or (t == best_touch and k < best_key.?)) {
                best_key = k;
                best_touch = t;
            }
        }
        const victim = best_key orelse return error.NoEvictionCandidate;
        const c = self.chunks.get(victim) orelse return error.NoEvictionCandidate;
        // Never discard a resident chunk unless its latest state reached disk.
        // The caller can reject the new chunk request and retry later.
        // Eviction goes through the same FIFO as every other write (the queue
        // preserves submit order per key), so an older queued payload can never
        // land after this one.
        try self.saveChunk(c);
        c.deinitBlocks();
        _ = self.chunks.remove(victim);
        self.allocator.destroy(c);
    }

    pub fn getOrCreate(self: *World, pos: ChunkPos) !*Chunk {
        const k = pos.hash();
        if (self.chunks.count() >= max_resident_chunks and !self.chunks.contains(k)) {
            try self.evictOneChunk(k);
        }
        const gop = try self.chunks.getOrPut(self.allocator, k);
        self.touch_seq += 1;
        if (!gop.found_existing) {
            // Pointer-stable: the chunk lives in its own allocation, so a
            // caller-held *Chunk survives map resizes (and re-entrant
            // getOrCreate/blockWorld inside this very init, e.g. the
            // prefab-TE scan). Freed on eviction/deinit only.
            const c = try self.allocator.create(Chunk);
            c.* = Chunk.generateFlat(pos);
            // A38: fallback terrain synthesis reads live ids, not module pins.
            c.terrain = &self.terrain_ids;
            // Wire geometry profile: column height + derived plane sizing.
            c.y_dim = self.profile.y_dim;
            // Stamped here, not at the tail: the load_state == .full path below
            // returns early.
            c.last_touch = self.touch_seq;
            gop.value_ptr.* = c;
            errdefer {
                c.deinitBlocks();
                self.allocator.destroy(c);
                _ = self.chunks.remove(k);
            }
            // Disk load first: a v3 save with blocks is authoritative for every
            // channel regen would produce, so skip the full terrain+TTS rebuild.
            // Heights-only / v2 saves still regen, then re-load to keep edits.
            const LoadState = enum { none, heights_only, full };
            var load_state: LoadState = .none;
            if (self.loadChunk(c)) {
                load_state = if (c.blocks != null) .full else .heights_only;
            } else |err| {
                if (err != error.FileNotFound) std.debug.print(
                    "zdtd: chunk ({d},{d}) load failed: {s}; regenerated\n",
                    .{ pos.x, pos.z, @errorName(err) },
                );
            }
            if (load_state == .full) return c;
            const geo = self.geometry;
            const profile_max: u32 = 255; // stock wire profile (Layer B widens)
            if (self.terrain_source == .proc) {
                if (self.worldgen) |*wg| {
                    if (geo.isStock()) {
                        // 3D density field: blocks first, heights derived from the
                        // topmost solid cell (overhangs cannot come from a column
                        // fill). Single-biome materials via defaultStack pins.
                        try c.generateProc(self.allocator, wg);
                    } else {
                        // Projected proc: surface model (height plane -> project ->
                        // column fill). The W2 density overhangs are lost by
                        // design: a projected geometry is an explicit non-stock
                        // elevation model, and the RWG lake table (stock
                        // water_surface_cell) does not apply to it.
                        wg.fillHeights(pos.x, pos.z, &c.heights);
                        projectPlane(&c.heights, geo, profile_max);
                        const biome_id: u8 = if (self.biomes) |*bm| bm.chunkDominant(pos.x, pos.z) else 3;
                        const stack = self.biome_layers_table.stackFor(biome_id);
                        try c.ensureBlocksWithStack(self.allocator, stack);
                    }
                }
            } else {
                if (self.heightmap) |*hm| {
                    hm.fillChunkHeights(pos.x, pos.z, &c.heights, fallbackSeaU8(geo));
                    if (!geo.isStock()) projectPlane(&c.heights, geo, profile_max);
                } else {
                    // Flat: the whole surface is the projected sea level
                    // (identity at stock defaults -> the old sea_level plane).
                    @memset(&c.heights, @intCast(geo.project(geo.sea_level, profile_max)));
                }
                // Terrain columns from biomes.xml layers (before POI paint / disk load).
                const biome_id: u8 = if (self.biomes) |*bm| bm.chunkDominant(pos.x, pos.z) else 3;
                const stack = self.biome_layers_table.stackFor(biome_id);
                try c.ensureBlocksWithStack(self.allocator, stack);
                if (self.prefabs) |*pf| {
                    pf.applyToChunkHeights(pos.x, pos.z, &c.heights);
                    // Stock .tts block paint into this chunk only (no setBlockWorld re-entry).
                    const PaintCtx = struct {
                        c: *Chunk,
                        a: std.mem.Allocator,
                        base_x: i32,
                        base_z: i32,
                        failed: u32 = 0,
                        fn put(ctx: ?*anyopaque, wx: i32, wy: i32, wz: i32, raw: u32, tex: u64, dens: ?u8, dmg: u16) void {
                            const pc: *@This() = @ptrCast(@alignCast(ctx.?));
                            const lx = wx - pc.base_x;
                            const lz = wz - pc.base_z;
                            if (lx < 0 or lx >= 16 or lz < 0 or lz >= 16) return;
                            if (wy < 0 or wy >= pc.c.y_dim) return;
                            pc.c.setBlockTexDens(pc.a, lx, wy, lz, raw, tex, dens) catch {
                                pc.failed +%= 1;
                            };
                            // Authored pre-damage (GAP "Prefab authored block
                            // damage plane"): the TTS damage value lands in the
                            // chunk damage plane, so the wire damage channel and
                            // ZCH3 persist carry the ruined/weak-spot cells.
                            if (dmg != 0) {
                                pc.c.setDmg(pc.a, lx, wy, lz, dmg) catch {
                                    pc.failed +%= 1;
                                };
                            }
                        }
                    };
                    var pc: PaintCtx = .{
                        .c = c,
                        .a = self.allocator,
                        .base_x = pos.x * 16,
                        .base_z = pos.z * 16,
                    };
                    // Filler cells take the surrounding terrain (stock
                    // InitTerrainFillers/CopyIntoLocal): the pre-stamp block at
                    // the cell is the terrain the POI sits on.
                    const TerrainCtx = struct {
                        c: *const Chunk,
                        base_x: i32,
                        base_z: i32,
                        fn at(ctx: ?*anyopaque, wx: i32, wy: i32, wz: i32) u16 {
                            const s: *const @This() = @ptrCast(@alignCast(ctx.?));
                            const lx = wx - s.base_x;
                            const lz = wz - s.base_z;
                            if (lx < 0 or lx >= 16 or lz < 0 or lz >= 16) return 0;
                            return s.c.blockAt(lx, wy, lz);
                        }
                    };
                    var terr_ctx: TerrainCtx = .{ .c = c, .base_x = pos.x * 16, .base_z = pos.z * 16 };
                    pf.applyTtsPaintToChunk(pos.x, pos.z, self.terrain_ids.water, self.terrain_ids.terrain_filler, self.terrain_ids.terrain_filler_adaptive, TerrainCtx.at, &terr_ctx, PaintCtx.put, &pc);
                    if (pc.failed > 0) {
                        std.debug.print(
                            "zdtd: TTS paint dropped {d} blocks at chunk ({d},{d})\n",
                            .{ pc.failed, pos.x, pos.z },
                        );
                    }
                }
                if (self.water) |*wt| {
                    wt.applyToChunkHeights(pos.x, pos.z, &c.heights);
                    c.applyWaterSources(pos.x, pos.z, wt, self.terrain_ids.water);
                }
            }
            // Player edits / first-touch cache win over regen (heights-only or
            // v2 saves restore heights again after regen filled blocks).
            // Note: for a legacy ZCH2/v2 proc save the restored heights can
            // disagree with the density-derived plane (overhangs are not
            // expressible in a heightmap). Pre-existing; v3 saves carry blocks.
            if (load_state == .heights_only) self.loadChunk(c) catch |err| {
                std.debug.print(
                    "zdtd: chunk ({d},{d}) edit re-load failed: {s}\n",
                    .{ pos.x, pos.z, @errorName(err) },
                );
            };
        }
        gop.value_ptr.*.last_touch = self.touch_seq;
        return gop.value_ptr.*;
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

    /// Non-materializing resident-chunk lookup (read/write paths: damage, meta).
    /// Null when the chunk is not resident; callers fall back to defaults.
    pub fn chunkAt(self: *const World, pos: ChunkPos) ?*Chunk {
        return self.chunks.get(pos.hash());
    }

    pub fn setBlockWorld(self: *World, x: i32, y: i32, z: i32, id: u16) !void {
        const t = worldToChunk(x, z);
        const c = try self.getOrCreate(t.pos);
        try c.setBlock(self.allocator, t.lx, y, t.lz, id);
        self.markTopSoilBroken(c, t.lx, y, t.lz);
        self.levelerPushIfWaterEdit(x, y, z, id);
    }

    /// World-space full BlockValue.rawData write (type low 16 + rotation/meta
    /// upper bits), GAP_ANALYSIS 13: player-placed doors/wedges/switch meta
    /// must land in the chunk plane so a second client or a relog re-renders
    /// the rotation, not a bare unrotated id (ZCH3 persists the u32 plane).
    pub fn setBlockRawWorld(self: *World, x: i32, y: i32, z: i32, raw: u32) !void {
        const t = worldToChunk(x, z);
        const c = try self.getOrCreate(t.pos);
        try c.setBlockRaw(self.allocator, t.lx, y, t.lz, raw);
        self.markTopSoilBroken(c, t.lx, y, t.lz);
        self.levelerPushIfWaterEdit(x, y, z, tts.typeId(raw));
    }

    /// Stock SetTopSoilBroken trigger (blocks.md position path): a block
    /// change at or above a column's surface marks that column's topsoil
    /// disturbed, so the client stops splat-rendering it (dig/upgrade/
    /// explosion expose the side textures). Border cells also mark the
    /// 1-wide neighbor chunk's adjacent column (stock SetTopSoilBroken
    /// neighbor pass) when that chunk exists - never created on demand.
    /// Worldgen fills blocks directly and never lands here.
    fn markTopSoilBroken(self: *World, c: *Chunk, lx: i32, y: i32, lz: i32) void {
        const idx = @as(usize, @intCast(lz * 16 + lx));
        if (y >= c.heights[idx]) c.setTopSoilBroken(lx, lz);
        if (lx == 0 or lx == 15 or lz == 0 or lz == 15) {
            const nx: i32 = if (lx == 0) c.pos.x - 1 else if (lx == 15) c.pos.x + 1 else c.pos.x;
            const nz: i32 = if (lz == 0) c.pos.z - 1 else if (lz == 15) c.pos.z + 1 else c.pos.z;
            const nl: i32 = if (lx == 0) 15 else if (lx == 15) 0 else lx;
            const nlz: i32 = if (lz == 0) 15 else if (lz == 15) 0 else lz;
            if (self.chunks.get(ChunkPos.hash(.{ .x = nx, .z = nz }))) |nc| {
                nc.setTopSoilBroken(nl, nlz);
            }
        }
    }

    /// Queue an edit that opened air or placed water for the leveling pass.
    /// Solids never pour (a wall placed next to water holds), so only air and
    /// water enqueue; the pour itself rejects cells with no water nearby.
    fn levelerPushIfWaterEdit(self: *World, x: i32, y: i32, z: i32, id: u16) void {
        const t = &self.terrain_ids;
        if (id == t.air or id == t.water) self.leveler.push(x, y, z);
    }

    /// World-space raw+texture set (POI reset re-paint path): keeps the baked
    /// texture and density like the chunk-load paint.
    pub fn setBlockTexDensWorld(self: *World, x: i32, y: i32, z: i32, raw: u32, tex: u64, dens: ?u8) !void {
        const t = worldToChunk(x, z);
        const c = try self.getOrCreate(t.pos);
        try c.setBlockTexDens(self.allocator, t.lx, y, t.lz, raw, tex, dens);
    }

    /// World-space `Chunk.setBlockDecoRaw` (surface height preserved).
    pub fn setBlockDecoWorld(self: *World, x: i32, y: i32, z: i32, raw: u32) !void {
        const t = worldToChunk(x, z);
        const c = try self.getOrCreate(t.pos);
        try c.setBlockDecoRaw(self.allocator, t.lx, y, t.lz, raw);
    }

    pub fn blockWorld(self: *World, x: i32, y: i32, z: i32) !u16 {
        const t = worldToChunk(x, z);
        const c = try self.getOrCreate(t.pos);
        return c.blockAt(t.lx, y, t.lz);
    }

    /// World-space full BlockValue.rawData (type low 16 + rotation/meta upper
    /// bits), so a falling-block capture keeps the block's rotation/meta like
    /// stock's snapshot (EntityFallingBlock.SetBlockValue stores the BlockValue).
    pub fn rawWorld(self: *World, x: i32, y: i32, z: i32) !u32 {
        const t = worldToChunk(x, z);
        const c = try self.getOrCreate(t.pos);
        return c.rawAt(t.lx, y, t.lz);
    }

    /// Surface block Y at world XZ (u16 API; current maps still 0..255).
    pub fn heightWorld(self: *World, x: i32, z: i32) !u16 {
        const t = worldToChunk(x, z);
        const c = try self.getOrCreate(t.pos);
        return c.heightAt(t.lx, t.lz);
    }

    pub fn isSolidWorld(self: *World, x: i32, y: i32, z: i32) !bool {
        const raw = try self.rawWorld(x, y, z);
        const id: u16 = tts.typeId(raw);
        if (id == self.terrain_ids.air or id == self.terrain_ids.water) return false;
        // An open door is passable (RE TEFeatureDoor.SetOpen): the AI solid
        // probes use this predicate, so a zombie walks through the door it
        // just opened. The meta open bit is bit 1 of the 22..25 nibble (wire
        // `block_meta_on`; duplicated here because world must not import wire).
        if (self.door_id_fn) |f| {
            if (f(self.door_id_ctx, id)) {
                return (@as(u8, @intCast((raw >> 22) & 15)) & 2) == 0;
            }
        }
        return true;
    }

    /// Bounded water leveling (GAP "Water flow / physics", PARTIAL): drain up
    /// to `edits` queued block edits; each pours up to `spread` cells of water
    /// into the connected open basin up to the adjacent water column's surface
    /// (the client-visible "dig beside a lake and the hole fills" behavior),
    /// and a placed water cell cascades down its column and puddles at the
    /// bottom (bounded by `puddle`). The stock sim is a jobified mass-flow
    /// engine (7dtd-engine-research light-mesh-water.md §4); this approximation has
    /// no per-cell levels, flow directions or evaporation, only pours (never
    /// drains). Returns cells filled. Runs after sim edits each tick
    /// (Game.step).
    pub fn levelWaterTick(self: *World, edits: usize, spread: usize, puddle: usize) u32 {
        const water_id = self.terrain_ids.water;
        var filled: u32 = 0;
        var done: usize = 0;
        while (done < edits) : (done += 1) {
            const e = self.leveler.pop() orelse break;
            filled += self.pourAt(e.x, e.y, e.z, water_id, spread, puddle);
        }
        return filled;
    }

    /// Top cell of the contiguous water column containing (x, y, z), or -1
    /// when that cell is not water (walk up through water to its surface).
    fn waterTopAt(self: *World, x: i32, y: i32, z: i32, water_id: u16) i32 {
        if (self.blockWorld(x, y, z) catch 0 != water_id) return -1;
        var top: i32 = y;
        while (top + 1 < self.yDim()) : (top += 1) {
            if (self.blockWorld(x, top + 1, z) catch 0 != water_id) break;
        }
        return top;
    }

    /// One edit: find the water surface from the edit cell and its 5
    /// neighbors, then flood-fill the connected air basin up to that surface.
    fn pourAt(self: *World, ex: i32, ey: i32, ez: i32, water_id: u16, spread: usize, puddle: usize) u32 {
        // Placed water cascades (stock WaterSimulationNative gravity flow,
        // bounded): the column of air below fills down to the first solid,
        // then the landing cell puddles. Dig edits (air at the cell) pour the
        // basin instead.
        if (self.blockWorld(ex, ey, ez) catch 0 == water_id) {
            return self.pourPlacedWater(ex, ey, ez, water_id, spread, puddle);
        }
        // Source columns: the edit cell itself (placed water), its 4 side
        // neighbors, and the cell above (dug under a pool). The surface is
        // the top of any adjacent water column; -1 = no water nearby.
        var surface: i32 = -1;
        surface = @max(surface, self.waterTopAt(ex, ey, ez, water_id));
        inline for ([_][2]i32{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 } }) |d| {
            surface = @max(surface, self.waterTopAt(ex + d[0], ey, ez + d[1], water_id));
        }
        if (ey + 1 < self.yDim()) surface = @max(surface, self.waterTopAt(ex, ey + 1, ez, water_id));
        if (surface < 0) return 0;

        // BFS through air cells at y <= surface. Water cells are already full
        // and terminate the branch; the fill budget doubles as the loop bound
        // (every visited air cell fills), so no visited set is needed.
        const air_id = self.terrain_ids.air;
        var stack: [256]water_mod.Cell = undefined;
        var sp: usize = 0;
        stack[sp] = .{ .x = ex, .y = ey, .z = ez };
        sp = 1;
        var filled: u32 = 0;
        while (sp > 0 and filled < spread) {
            sp -= 1;
            const c = stack[sp];
            if (c.y < 0 or c.y >= self.yDim()) continue;
            if (c.y > surface) continue;
            if (self.blockWorld(c.x, c.y, c.z) catch 0 != air_id) continue; // water or solid: stop
            const t = worldToChunk(c.x, c.z);
            (self.getOrCreate(t.pos) catch continue).setBlockRaw(self.allocator, t.lx, c.y, t.lz, water_id) catch continue;
            filled += 1;
            if (sp + 6 <= stack.len) {
                stack[sp] = .{ .x = c.x + 1, .y = c.y, .z = c.z };
                stack[sp + 1] = .{ .x = c.x - 1, .y = c.y, .z = c.z };
                stack[sp + 2] = .{ .x = c.x, .y = c.y, .z = c.z + 1 };
                stack[sp + 3] = .{ .x = c.x, .y = c.y, .z = c.z - 1 };
                stack[sp + 4] = .{ .x = c.x, .y = c.y + 1, .z = c.z };
                stack[sp + 5] = .{ .x = c.x, .y = c.y - 1, .z = c.z };
                sp += 6;
            }
        }
        return filled;
    }

    /// Placed water falls down its air column and puddles at the landing
    /// level (stock gravity flow; bounded approximation). The column fill
    /// never climbs above the placed level and the puddle only spreads into
    /// cells resting on solid, so a floating puddle cannot form.
    fn pourPlacedWater(self: *World, ex: i32, ey: i32, ez: i32, water_id: u16, spread: usize, puddle: usize) u32 {
        const air_id = self.terrain_ids.air;
        var filled: u32 = 0;
        // 1. Column: fill the air below the placed cell down to the first
        // solid (the falling column).
        var y: i32 = ey - 1;
        while (y >= 0 and filled < spread) : (y -= 1) {
            if (self.blockWorld(ex, y, ez) catch 0 != air_id) break;
            const t = worldToChunk(ex, ez);
            (self.getOrCreate(t.pos) catch break).setBlockRaw(self.allocator, t.lx, y, t.lz, water_id) catch break;
            filled += 1;
        }
        const bottom = y + 1; // lowest filled cell (or ey when the column was blocked)
        // 2. Puddle: 4-neighbor air cells at the landing level whose own
        // below is solid or water, bounded by the puddle cap.
        var stack: [64]water_mod.Cell = undefined;
        var sp: usize = 0;
        const puddle_left: usize = @min(@as(usize, puddle), spread -| filled);
        var pu: usize = 0;
        stack[sp] = .{ .x = ex + 1, .y = bottom, .z = ez };
        sp += 1;
        stack[sp] = .{ .x = ex - 1, .y = bottom, .z = ez };
        sp += 1;
        stack[sp] = .{ .x = ex, .y = bottom, .z = ez + 1 };
        sp += 1;
        stack[sp] = .{ .x = ex, .y = bottom, .z = ez - 1 };
        sp += 1;
        while (sp > 0 and pu < puddle_left) {
            sp -= 1;
            const c = stack[sp];
            if (self.blockWorld(c.x, c.y, c.z) catch 0 != air_id) continue;
            if (self.blockWorld(c.x, c.y - 1, c.z) catch 0 == air_id) continue; // floating: no spread
            const t = worldToChunk(c.x, c.z);
            (self.getOrCreate(t.pos) catch continue).setBlockRaw(self.allocator, t.lx, c.y, t.lz, water_id) catch continue;
            filled += 1;
            pu += 1;
            if (sp + 4 <= stack.len) {
                stack[sp] = .{ .x = c.x + 1, .y = c.y, .z = c.z };
                sp += 1;
                stack[sp] = .{ .x = c.x - 1, .y = c.y, .z = c.z };
                sp += 1;
                stack[sp] = .{ .x = c.x, .y = c.y, .z = c.z + 1 };
                sp += 1;
                stack[sp] = .{ .x = c.x, .y = c.y, .z = c.z - 1 };
                sp += 1;
            }
        }
        return filled;
    }

    /// Feet Y a walking body can occupy at world XZ near `from_y` (module
    /// step/drop limits), or null when the column is impassable from there.
    /// Backs the AI step predicate; materializes the chunk like every other
    /// world probe so on-demand generation stays where it is.
    pub fn standableWorld(self: *World, x: i32, z: i32, from_y: i32) !?i32 {
        const t = worldToChunk(x, z);
        const c = try self.getOrCreate(t.pos);
        return c.standableY(t.lx, t.lz, from_y, max_step_up, max_drop);
    }

    fn chunkPath(self: *World, pos: ChunkPos, buf: []u8) ![]const u8 {
        return try std.fmt.bufPrint(buf, "{s}/c_{d}_{d}.zch", .{ self.world_dir, pos.x, pos.z });
    }

    /// dens_set bitset bytes for one chunk (blocks_per_chunk bits).
    const dens_set_bytes: usize = (blocks_per_chunk + 7) / 8;

    /// Bounds-check a ZCH1/2/3/4 record for `pos` without mutating chunk state.
    /// Used by fuzz harnesses for torn/corrupt save rejection.
    pub fn validateChunkBytes(data: []const u8, pos: ChunkPos) !void {
        if (data.len < 12) return error.ReadFailed;
        if (data.len >= 16 and data[0] == 'Z' and data[1] == 'C' and data[2] == 'H' and (data[3] == '3' or data[3] == '2' or data[3] == '4')) {
            const stored_x = std.mem.readInt(i32, data[4..8], .little);
            const stored_z = std.mem.readInt(i32, data[8..12], .little);
            if (stored_x != pos.x or stored_z != pos.z) return error.ReadFailed;
            if (data[12] > 1 or data[13] > 1 or data[14] > 1) return error.ReadFailed;
            const has_blocks = data[12] == 1;
            const has_textures = data[3] == '3' and data[13] == 1;
            const has_densities = data[3] == '3' and data[14] == 1;
            // ZCH4: column height from the header; channels sized by it. The
            // saved height must be a structurally valid profile (power of two).
            const hdr_len: usize = if (data[3] == '4') 20 else 16;
            var saved_y: u32 = 256;
            if (data[3] == '4') {
                if (data.len < 20) return error.ReadFailed;
                saved_y = std.mem.readInt(u32, data[16..20], .little);
                const p: protocol.WireProfile = .{ .y_dim = saved_y };
                if (!p.validate()) return error.ReadFailed;
            }
            const plane_cells: usize = @intCast(16 * saved_y * 16);
            const dset: usize = (plane_cells + 7) / 8;
            var required: usize = hdr_len + 256; // heights plane
            if (data[3] == '3' and has_blocks) required += plane_cells * @sizeOf(u32);
            if (has_textures) required += plane_cells * @sizeOf(u64);
            if (has_densities) required += plane_cells + dset;
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
    /// flags: [12]=blocks u32, [13]=textures u64, [14]=densities+bitset,
    /// [15]=damages u16 plane (added 2026-08-22; 0 on older v3 files, loaded
    /// with an absent plane = no damage).
    /// (v2 ZCH2 was u16 type-only; discarded on load so rotation/meta is not lost.)
    /// v4 (non-stock wire profile only): magic ZCH4 | pos | flags | y_dim u32
    /// | heights | channels sized by y_dim. Written when the chunk's column
    /// height != 256; a stock loader rejects it and a non-stock loader rejects
    /// any y_dim mismatch (fail closed). Stock chunks stay ZCH3 byte-identical.
    /// Callers pass `std.heap.page_allocator`: this runs from parallel workers
    /// and World.allocator is a DebugAllocator/GPA, which is not thread-safe.
    pub fn encodeChunk(c: *const Chunk, a: std.mem.Allocator) ![]u8 {
        const has_blocks = c.blocks != null;
        const has_textures = c.textures != null;
        const has_densities = c.densities != null and c.dens_set != null;
        const has_damages = c.damages != null;
        const tall = c.y_dim != 256;
        const hdr_len: usize = if (tall) 20 else 16;
        var hdr: [20]u8 = undefined;
        hdr[0] = 'Z';
        hdr[1] = 'C';
        hdr[2] = 'H';
        hdr[3] = if (tall) '4' else '3';
        std.mem.writeInt(i32, hdr[4..8], c.pos.x, .little);
        std.mem.writeInt(i32, hdr[8..12], c.pos.z, .little);
        hdr[12] = @intFromBool(has_blocks);
        hdr[13] = @intFromBool(has_textures);
        hdr[14] = @intFromBool(has_densities);
        hdr[15] = @intFromBool(has_damages);
        if (tall) std.mem.writeInt(u32, hdr[16..20], c.y_dim, .little);
        var total: usize = hdr_len + c.heights.len + c.topsoil.len;
        if (has_blocks) total += c.planeCells() * @sizeOf(u32);
        if (has_textures) total += c.planeCells() * @sizeOf(u64);
        if (has_densities) total += c.planeCells() + c.densSetBytes();
        if (has_damages) total += c.planeCells() * @sizeOf(u16);
        const payload = try a.alloc(u8, total);
        errdefer a.free(payload);
        var o: usize = 0;
        @memcpy(payload[o..][0..hdr_len], hdr[0..hdr_len]);
        o += hdr_len;
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
            @memcpy(payload[o..][0..c.planeCells()], c.densities.?[0..c.planeCells()]);
            o += c.planeCells();
            @memcpy(payload[o..][0..c.densSetBytes()], c.dens_set.?[0..c.densSetBytes()]);
            o += c.densSetBytes();
        }
        if (has_damages) {
            const bytes = std.mem.sliceAsBytes(c.damages.?);
            @memcpy(payload[o..][0..bytes.len], bytes);
            o += bytes.len;
        }
        // Topsoil bitfield tail (32 bytes, optional on read: files saved by
        // pre-topsoil zdtd lack it and load all-clear). Appended last so the
        // pre-topsoil reader's field walk stops at its computed length and
        // ignores the tail.
        @memcpy(payload[o..][0..c.topsoil.len], &c.topsoil);
        o += c.topsoil.len;
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
        // Proc worlds regenerate untouched chunks deterministically from the
        // seed, so a clean chunk needs no file: an infinite world would
        // otherwise grow the save dir with every visited chunk for no
        // benefit. Edited chunks carry `dirty` (setBlockRaw / dmg / topsoil /
        // height) and still persist; `saveAll` already skips clean chunks.
        // Baked worlds keep persisting clean chunks (disk reload beats
        // DTM+prefab regen, and the map is finite).
        if (!c.dirty and self.terrain_source == .proc) return;
        var path_buf: [512]u8 = undefined;
        const path = try self.chunkPath(c.pos, &path_buf);
        const key = c.pos.hash();
        const io_a = std.heap.page_allocator;
        const payload = try encodeChunk(c, io_a);
        if (self.asyncEnabled()) {
            const owned_path = io_a.dupe(u8, path) catch {
                defer io_a.free(payload);
                return io_fs.writeFile(path, payload);
            };
            self.flush.submit(key, owned_path, payload) catch {
                // Queue full or shut down: write inline rather than drop. An
                // older snapshot for this key may still be in flight, so let
                // it finish before publishing the newer image.
                self.flush.waitKey(key);
                defer io_a.free(owned_path);
                defer io_a.free(payload);
                _ = self.sync_fallbacks.fetchAdd(1, .monotonic);
                return io_fs.writeFile(path, payload);
            };
            return;
        }
        defer io_a.free(payload);
        try io_fs.writeFile(path, payload);
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
            // existing save could not be read; keep the specific error so the
            // caller's log tells the operator why (permission, I/O, is-a-dir).
            // Collapsing to OpenFailed here would mislabel those as the same
            // "no persist file" sentinel the other loaders use for fresh worlds.
            error.FileNotFound => return error.FileNotFound,
            else => |e| return e,
        };
        defer self.allocator.free(data);
        if (data.len < 12) return error.ReadFailed;
        if (data.len >= 16 and data[0] == 'Z' and data[1] == 'C' and data[2] == 'H' and (data[3] == '3' or data[3] == '2' or data[3] == '4')) {
            const stored_x = std.mem.readInt(i32, data[4..8], .little);
            const stored_z = std.mem.readInt(i32, data[8..12], .little);
            if (stored_x != c.pos.x or stored_z != c.pos.z) return error.ReadFailed;
            if (data[12] > 1 or data[13] > 1 or data[14] > 1 or data[15] > 1) return error.ReadFailed;
            const has_blocks = data[12] == 1;
            // hdr[13]/[14]/[15] are 0 on pre-paint ZCH3 files (backward compatible).
            const has_textures = data[3] == '3' and data[13] == 1;
            const has_densities = data[3] == '3' and data[14] == 1;
            const has_damages = data[3] == '3' and data[15] == 1;
            // ZCH4 (non-stock wire profile) carries the column height in the
            // header; it must match the chunk's active profile (fail closed).
            const hdr_len: usize = if (data[3] == '4') 20 else 16;
            if (data[3] == '4') {
                if (data.len < 20) return error.ReadFailed;
                const saved_y = std.mem.readInt(u32, data[16..20], .little);
                if (saved_y != c.y_dim) return error.ReadFailed;
            }
            var required: usize = hdr_len + c.heights.len;
            if (data[3] == '3' and has_blocks) required += c.planeCells() * @sizeOf(u32);
            if (has_textures) required += c.planeCells() * @sizeOf(u64);
            if (has_densities) required += c.planeCells() + c.densSetBytes();
            if (has_damages) required += c.planeCells() * @sizeOf(u16);
            // Validate the complete record before mutating the resident chunk.
            // A torn save must regenerate, never leave a half-loaded plane that
            // suppresses terrain materialization.
            if (data.len < required) return error.ReadFailed;
            @memcpy(&c.heights, data[hdr_len..][0..c.heights.len]);
            var o: usize = hdr_len + c.heights.len;
            if (has_blocks) {
                if (data[3] == '3') {
                    // Raw alloc only: the memcpy below fully initializes the
                    // plane, so ensureBlocks' terrain generation would be waste.
                    if (c.blocks == null) {
                        c.allocator = self.allocator;
                        c.blocks = try self.allocator.alloc(u32, c.planeCells());
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
                const tex_bytes = c.planeCells() * @sizeOf(u64);
                if (data.len < o + tex_bytes) return error.ReadFailed;
                if (c.textures == null) {
                    const t = try self.allocator.alloc(u64, c.planeCells());
                    c.textures = t;
                    c.allocator = self.allocator;
                }
                const dest = std.mem.sliceAsBytes(c.textures.?);
                @memcpy(dest, data[o..][0..tex_bytes]);
                o += tex_bytes;
            }
            if (has_densities) {
                if (data.len < o + c.planeCells() + c.densSetBytes()) return error.ReadFailed;
                if (c.densities == null) {
                    const p = try self.allocator.alloc(u8, c.planeCells());
                    c.densities = p;
                    c.allocator = self.allocator;
                }
                if (c.dens_set == null) {
                    const bits = try self.allocator.alloc(u8, c.densSetBytes());
                    c.dens_set = bits;
                }
                @memcpy(c.densities.?[0..c.planeCells()], data[o..][0..c.planeCells()]);
                o += c.planeCells();
                @memcpy(c.dens_set.?[0..c.densSetBytes()], data[o..][0..c.densSetBytes()]);
                o += c.densSetBytes();
            }
            if (has_damages) {
                const dmg_bytes = c.planeCells() * @sizeOf(u16);
                if (data.len < o + dmg_bytes) return error.ReadFailed;
                if (c.damages == null) {
                    const d = try self.allocator.alloc(u16, c.planeCells());
                    c.damages = d;
                    c.allocator = self.allocator;
                }
                const dest = std.mem.sliceAsBytes(c.damages.?);
                @memcpy(dest, data[o..][0..dmg_bytes]);
                o += dmg_bytes;
            }
            // Topsoil bitfield tail: files saved by topsoil-aware zdtd carry
            // the 32 bytes; older files lack them and load all-clear (the
            // fresh-world state; bits re-set on the next dig/upgrade).
            if (data.len >= o + c.topsoil.len) {
                @memcpy(&c.topsoil, data[o..][0..c.topsoil.len]);
            } else {
                @memset(&c.topsoil, 0);
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
            if (e.value_ptr.*.dirty) dirty_n += 1;
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
            if (!e.value_ptr.*.dirty) continue;
            keys[kn] = e.key_ptr.*;
            kn += 1;
        }
        std.debug.assert(kn == dirty_n);
        std.mem.sort(u64, keys[0..kn], {}, std.sort.asc(u64));

        var list: [512]*Chunk = undefined;
        var n: usize = 0;
        for (keys[0..kn]) |k| {
            const c = self.chunks.get(k) orelse continue;
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
        w.allocator.destroy(dead);
    }
    const c2 = try w.getOrCreate(.{ .x = 2, .z = -1 });
    try std.testing.expectEqual(h0, c2.heightAt(5, 7));
    try std.testing.expectEqualSlices(u8, &heights_before, &c2.heights);
    try std.testing.expectEqualSlices(u32, plane, c2.blocks.?);
}

test "proc worlds persist only edited chunks" {
    // Infinite-world save growth: an untouched proc chunk regenerates from
    // the seed, so evicting/saving it must leave no file; an edit marks
    // dirty and persists.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    w.enableProc(1);
    const pos = ChunkPos{ .x = 0, .z = 0 };
    const c = try w.getOrCreate(pos);
    try std.testing.expect(!c.dirty);
    var path_buf: [512]u8 = undefined;
    const path = try w.chunkPath(pos, &path_buf);
    try w.saveChunk(c);
    try std.testing.expect(!io_fs.fileExists(path));
    // An edit marks dirty and persists.
    try w.setBlockWorld(1, 10, 1, block_stone);
    try std.testing.expect(c.dirty);
    try w.saveChunk(c);
    try std.testing.expect(io_fs.fileExists(path));
}

test "proc worlds derive a spawn from the generated surface" {
    // No DTM spawn points on proc worlds: the spawn must sit above the
    // deterministic surface near the origin, not the hardcoded (256,70,256)
    // which can bury the player or leave them mid-air for a random seed.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    w.enableProc(7);
    const sp = w.primarySpawn();
    try std.testing.expectEqual(@as(i32, 256), sp.x);
    try std.testing.expectEqual(@as(i32, 256), sp.z);
    const h = try w.heightWorld(sp.x, sp.z);
    try std.testing.expectEqual(@as(i32, @intCast(h)) + 2, sp.y);
    try std.testing.expect(sp.y > 3);
    // A different seed derives its own surface-relative spawn.
    w.enableProc(999);
    const sp2 = w.primarySpawn();
    const h2 = try w.heightWorld(sp2.x, sp2.z);
    try std.testing.expectEqual(@as(i32, @intCast(h2)) + 2, sp2.y);
}

test "a clean proc session writes no world files (mods leave no trace)" {
    // --preset infinite is an opt-in overlay: exploring materializes chunks but
    // nothing persists until the player edits, so removing the mod later
    // leaves the world dir exactly as it was (default behavior unchanged;
    // edits are the player's data).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    w.enableProc(1);
    // Explore a few chunks as the stream would, then save-all like shutdown.
    _ = try w.getOrCreate(.{ .x = 0, .z = 0 });
    _ = try w.getOrCreate(.{ .x = 1, .z = 0 });
    _ = try w.getOrCreate(.{ .x = -2, .z = 3 });
    try w.saveAll();
    var path_buf: [512]u8 = undefined;
    try std.testing.expect(!io_fs.fileExists(try w.chunkPath(.{ .x = 0, .z = 0 }, &path_buf)));
    try std.testing.expect(!io_fs.fileExists(try w.chunkPath(.{ .x = 1, .z = 0 }, &path_buf)));
    try std.testing.expect(!io_fs.fileExists(try w.chunkPath(.{ .x = -2, .z = 3 }, &path_buf)));
    // Derived decoration (the deco mirror) is re-derived on every stream and
    // reload, so it must not dirty the chunk or write files either - a clean
    // session truly leaves no trace (real edits still persist).
    try w.setBlockDecoWorld(3, 10, 3, block_stone);
    try std.testing.expect(!w.chunks.get(ChunkPos.hash(.{ .x = 0, .z = 0 })).?.dirty);
    try w.saveAll();
    try std.testing.expect(!io_fs.fileExists(try w.chunkPath(.{ .x = 0, .z = 0 }, &path_buf)));
    // An edit is the one thing that persists.
    try w.setBlockWorld(5, 10, 5, block_stone);
    try w.saveAll();
    try std.testing.expect(io_fs.fileExists(try w.chunkPath(.{ .x = 0, .z = 0 }, &path_buf)));
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
    try std.testing.expect(w.chunks.get(ChunkPos.hash(.{ .x = 0, .z = 0 })).?.dirty);
    try w.saveAll();
    try std.testing.expect(!w.chunks.get(ChunkPos.hash(.{ .x = 0, .z = 0 })).?.dirty);

    var w2 = try World.init(std.testing.allocator, dir);
    defer w2.deinit();
    const c = try w2.getOrCreate(.{ .x = 0, .z = 0 });
    try std.testing.expectEqual(@as(u16, 71), c.heightAt(6, 5));
    // Full columns must reload so dig/build is authoritative after restart.
    try std.testing.expectEqual(block_dirt, try w2.blockWorld(5, 70, 5));
    try std.testing.expectEqual(block_stone, try w2.blockWorld(6, 71, 5));
}

test "standableY answers the walk surface, not the column top" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    const ch = try w.getOrCreate(.{ .x = 0, .z = 0 });
    const g: i32 = ch.heightAt(0, 0); // flat sea_level surface

    // Flat ground: feet rest one above the surface block.
    try std.testing.expectEqual(@as(?i32, g + 1), ch.standableY(0, 0, g + 1, max_step_up, max_drop));

    // One-block wall: a body steps up onto it.
    try ch.setBlock(w.allocator, 1, g + 1, 0, block_stone);
    try std.testing.expectEqual(@as(?i32, g + 2), ch.standableY(1, 0, g + 1, max_step_up, max_drop));

    // Two-block wall: too high to step, no headroom on top of the first course.
    try ch.setBlock(w.allocator, 2, g + 1, 0, block_stone);
    try ch.setBlock(w.allocator, 2, g + 2, 0, block_stone);
    try std.testing.expectEqual(@as(?i32, null), ch.standableY(2, 0, g + 1, max_step_up, max_drop));

    // POI interior: floor at g, roof at g+3. The floor wins over the roof even
    // though heightAt now reports the roof.
    try ch.setBlock(w.allocator, 3, g + 3, 0, block_stone);
    try std.testing.expectEqual(@as(u16, @intCast(g + 3)), ch.heightAt(3, 0));
    try std.testing.expectEqual(@as(?i32, g + 1), ch.standableY(3, 0, g + 1, max_step_up, max_drop));

    // Crawlspace: roof one block above the floor leaves no headroom.
    try ch.setBlock(w.allocator, 4, g + 2, 0, block_stone);
    try std.testing.expectEqual(@as(?i32, null), ch.standableY(4, 0, g + 1, max_step_up, max_drop));

    // Drop: dug pit deeper than max_drop is refused, within it is accepted.
    var y: i32 = g;
    while (y > g - 2) : (y -= 1) try ch.setBlock(w.allocator, 5, y, 0, block_air);
    try std.testing.expectEqual(@as(?i32, g - 1), ch.standableY(5, 0, g + 1, max_step_up, max_drop));
    try std.testing.expectEqual(@as(?i32, null), ch.standableY(5, 0, g + 1, max_step_up, 1));
}

test "standableY clamps at world floor and ceiling" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    const ch = try w.getOrCreate(.{ .x = 0, .z = 0 });
    // Bedrock floor: the lowest feet cell is 1, so a candidate never probes
    // support at y = -1 and a zero-height band resolves to nothing.
    try std.testing.expectEqual(@as(?i32, null), ch.standableY(0, 0, 0, 0, 0));
    try ch.setBlock(w.allocator, 0, 1, 0, block_air);
    try ch.setBlock(w.allocator, 0, 2, 0, block_air);
    try std.testing.expectEqual(@as(?i32, 1), ch.standableY(0, 0, 3, 0, 1000));
    // Ceiling: a candidate needs body_height cells below y_dim.
    try std.testing.expectEqual(@as(?i32, null), ch.standableY(0, 0, y_dim - 1, 0, 0));
    // Band entirely in open sky reports impassable, not a crash.
    try std.testing.expectEqual(@as(?i32, null), ch.standableY(0, 0, y_dim - 1, 0, 4));
}

test "standableWorld crosses chunk borders and refuses a sealed column" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    const g: i32 = sea_level;
    try std.testing.expectEqual(@as(?i32, g + 1), try w.standableWorld(-1, -1, g + 1));
    var y: i32 = g + 1;
    while (y <= g + 4) : (y += 1) try w.setBlockWorld(-1, y, -1, block_stone);
    try std.testing.expectEqual(@as(?i32, null), try w.standableWorld(-1, -1, g + 1));
}

test "evictOneChunk picks the coldest chunk, min key on ties (DST)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    // Insert in reverse key order so HashMap walk ≠ sorted order. Chunk 1 is
    // the lowest key but is re-touched, so the untouched chunk 3 loses.
    _ = try w.getOrCreate(.{ .x = 3, .z = 0 });
    _ = try w.getOrCreate(.{ .x = 1, .z = 0 });
    _ = try w.getOrCreate(.{ .x = 2, .z = 0 });
    _ = try w.getOrCreate(.{ .x = 1, .z = 0 });
    const keep = ChunkPos.hash(.{ .x = 2, .z = 0 });
    try w.evictOneChunk(keep);
    try std.testing.expect(w.chunks.get(ChunkPos.hash(.{ .x = 3, .z = 0 })) == null);
    try std.testing.expect(w.chunks.get(ChunkPos.hash(.{ .x = 1, .z = 0 })) != null);
    try std.testing.expect(w.chunks.get(ChunkPos.hash(.{ .x = 2, .z = 0 })) != null);
    // Ties (equal stamps) still resolve by min key, not HashMap walk order.
    var tied = try World.init(std.testing.allocator, dir);
    defer tied.deinit();
    _ = try tied.getOrCreate(.{ .x = 7, .z = 0 });
    _ = try tied.getOrCreate(.{ .x = 6, .z = 0 });
    _ = try tied.getOrCreate(.{ .x = 5, .z = 0 });
    var it = tied.chunks.iterator();
    while (it.next()) |e| e.value_ptr.*.last_touch = 0;
    try tied.evictOneChunk(ChunkPos.hash(.{ .x = 7, .z = 0 }));
    try std.testing.expect(tied.chunks.get(ChunkPos.hash(.{ .x = 5, .z = 0 })) == null);
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

test "ZCH3 damage plane roundtrips and stays per-cell" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    const c = try w.getOrCreate(.{ .x = 0, .z = 0 });
    try c.setDmg(w.allocator, 3, 40, 4, 250);
    try c.setDmg(w.allocator, 1, 10, 2, 7);
    try std.testing.expectEqual(@as(u16, 250), c.dmgAt(3, 40, 4));
    try std.testing.expectEqual(@as(u16, 0), c.dmgAt(5, 5, 5));
    try w.saveAll();

    var w2 = try World.init(std.testing.allocator, dir);
    defer w2.deinit();
    const c2 = try w2.getOrCreate(.{ .x = 0, .z = 0 });
    try std.testing.expectEqual(@as(u16, 250), c2.dmgAt(3, 40, 4));
    try std.testing.expectEqual(@as(u16, 7), c2.dmgAt(1, 10, 2));
    try std.testing.expectEqual(@as(u16, 0), c2.dmgAt(5, 5, 5));
    // Clear persists too: a repaired block must not re-damage after reload.
    c2.clearDmg(3, 40, 4);
    try w2.saveAll();
    var w3 = try World.init(std.testing.allocator, dir);
    defer w3.deinit();
    const c3 = try w3.getOrCreate(.{ .x = 0, .z = 0 });
    try std.testing.expectEqual(@as(u16, 0), c3.dmgAt(3, 40, 4));
    try std.testing.expectEqual(@as(u16, 7), c3.dmgAt(1, 10, 2));
}

test "topsoil bitfield: fresh clear, dig marks, ZCH3 round-trips" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    const c = try w.getOrCreate(.{ .x = 0, .z = 0 });
    const g: i32 = c.heightAt(0, 0); // flat sea_level surface
    try std.testing.expectEqual(@as(u8, 0), c.topsoil[0]); // fresh = clear

    // Dig AT the surface marks the column (stock SetTopSoilBroken trigger:
    // block change at y >= surface). Column (0,0) is bit 0 of byte 0.
    try w.setBlockWorld(0, g, 0, block_air);
    try std.testing.expectEqual(@as(u8, 0x01), c.topsoil[0]);
    // A tunnel BELOW the surface does not disturb the topsoil.
    try w.setBlockWorld(1, g - 3, 0, block_air);
    try std.testing.expectEqual(@as(u8, 0x01), c.topsoil[0]);
    // Column (1,0) is bit 1: a surface edit there sets it too.
    try w.setBlockWorld(1, g, 0, block_air);
    try std.testing.expectEqual(@as(u8, 0x03), c.topsoil[0]);

    // A border cell marks the neighbor chunk's adjacent column (only when the
    // neighbor exists; never created on demand).
    try w.setBlockWorld(15, g, 0, block_air); // lx=15, column bit 15 (byte 1 bit 7)
    try std.testing.expectEqual(@as(u8, 0x80), c.topsoil[1]);
    try std.testing.expect(w.chunks.get(ChunkPos.hash(.{ .x = 1, .z = 0 })) == null);

    // ZCH3 round-trip: the disturbed bits survive a reload; old files without
    // the tail load all-clear.
    try w.saveAll();
    var w2 = try World.init(std.testing.allocator, dir);
    defer w2.deinit();
    const c2 = try w2.getOrCreate(.{ .x = 0, .z = 0 });
    try std.testing.expectEqual(@as(u8, 0x03), c2.topsoil[0]);
    try std.testing.expectEqual(@as(u8, 0x80), c2.topsoil[1]);

    // Pre-topsoil save (16-byte hdr + heights only): loads all-clear.
    var path_buf2: [std.fs.max_path_bytes]u8 = undefined;
    const path2 = try std.fmt.bufPrint(&path_buf2, "{s}/c_0_0.zch", .{dir});
    var old: [16 + 256]u8 = .{0} ** (16 + 256);
    old[0] = 'Z';
    old[1] = 'C';
    old[2] = 'H';
    old[3] = '3';
    std.mem.writeInt(i32, old[4..8], 0, .little);
    std.mem.writeInt(i32, old[8..12], 0, .little);
    try io_fs.writeFile(path2, &old);
    var w3 = try World.init(std.testing.allocator, dir);
    defer w3.deinit();
    const c3 = try w3.getOrCreate(.{ .x = 0, .z = 0 });
    try std.testing.expectEqual(@as(u8, 0), c3.topsoil[0]);
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
    try io_fs.writeFile(path, &torn);

    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    const c = try w.getOrCreate(.{ .x = 0, .z = 0 });
    try std.testing.expectEqual(@as(u16, sea_level), c.heightAt(0, 0));
    try std.testing.expect(c.blocks != null);

    // The filename is not identity: embedded coordinates must agree too.
    std.mem.writeInt(i32, torn[4..8], 7, .little);
    torn[12] = 0;
    try io_fs.writeFile(path, &torn);
    var direct = Chunk.generateFlat(.{ .x = 0, .z = 0 });
    try std.testing.expectError(error.ReadFailed, w.loadChunk(&direct));
    try std.testing.expectEqual(@as(u16, sea_level), direct.heightAt(0, 0));

    @memcpy(torn[0..4], "NOPE");
    std.mem.writeInt(i32, torn[4..8], 0, .little);
    try io_fs.writeFile(path, &torn);
    try std.testing.expectError(error.ReadFailed, w.loadChunk(&direct));
}

test "stock map heights via DTM if Navezgane present" {
    const map = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Worlds/Navezgane";
    if (!io_fs.dirExists(map)) return error.SkipZigTest;

    io_fs.mkdirPath("worlds");
    io_fs.mkdirPath("worlds/zdtd_navezgane_test");
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

test "rotation raw lives in the chunk plane and survives save/reload" {
    // GAP_ANALYSIS 13: a placed block's full BlockValue (type low 16, rotation
    // / meta upper bits) must reach the chunk plane and the ZCH3 save, so a
    // second client or a relog re-renders the rotation instead of a bare id.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    const raw_door: u32 = block_dirt | (@as(u32, 0x0005) << 16); // arbitrary upper meta bits
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    try w.setBlockRawWorld(5, 70, 5, raw_door);
    // The plane carries the full raw; the u16 read still answers the type id.
    const c = try w.getOrCreate(.{ .x = 0, .z = 0 });
    try std.testing.expectEqual(raw_door, c.rawAt(5, 70, 5));
    try std.testing.expectEqual(block_dirt, c.blockAt(5, 70, 5));
    try w.saveAll();

    var w2 = try World.init(std.testing.allocator, dir);
    defer w2.deinit();
    try std.testing.expectEqual(block_dirt, try w2.blockWorld(5, 70, 5));
    const c2 = try w2.getOrCreate(.{ .x = 0, .z = 0 });
    try std.testing.expectEqual(raw_door, c2.rawAt(5, 70, 5));
    // Clearing to air writes a zero raw and drops the meta with the block.
    try w2.setBlockRawWorld(5, 70, 5, 0);
    try std.testing.expectEqual(@as(u32, 0), c2.rawAt(5, 70, 5));
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
    try std.testing.expectError(error.DiskQuota, w.saveChunk(w.chunks.get(ChunkPos.hash(.{ .x = 0, .z = 0 })).?));
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

test "navezgane spawn chunk carries its POI blocks" {
    // The stock client saw only terrain where abandoned_house_07 stands, so the
    // POI must survive the whole store path, not just the prefab index.
    const map_dir = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Worlds/Navezgane";
    if (!io_fs.fileExists(map_dir ++ "/prefabs.xml")) return error.SkipZigTest;

    var w = try World.init(std.testing.allocator, "worlds/zdtd_poi_test");
    defer w.deinit();
    try w.loadStockMapEx(map_dir, null);

    // prefabs.xml lists the prefab's origin CORNER, so probe inside the
    // footprint: abandoned_house_07 is 42x42 at (-262,61,450).
    const t2 = World.worldToChunk(-241, 471);
    const ch = try w.getOrCreate(t2.pos);

    var non_air: usize = 0;
    var y: i32 = 62;
    while (y < 80) : (y += 1) {
        if (ch.blockAt(t2.lx, y, t2.lz) != 0) non_air += 1;
    }
    try std.testing.expect(non_air > 0);
}

test "isSolidWorld: a closed door is solid, an open door is passable" {
    // RE TEFeatureDoor.SetOpen: the open state is a meta bit (bit 1 of the
    // 22..25 nibble). With the door-id hook wired, an open door no longer
    // blocks the AI probes; without the hook it stays solid.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    const Door = struct {
        fn isDoor(_: ?*anyopaque, id: u16) bool {
            return id == 999;
        }
    };
    w.door_id_ctx = null;
    w.door_id_fn = &Door.isDoor;
    try w.setBlockWorld(5, 70, 5, 999);
    try std.testing.expect(try w.isSolidWorld(5, 70, 5)); // closed
    const open_raw: u32 = 999 | (2 << 22); // meta open bit
    try w.setBlockRawWorld(5, 70, 5, open_raw);
    try std.testing.expect(!try w.isSolidWorld(5, 70, 5)); // open
    // Without the hook the table is unknown: the open door stays solid.
    var w2 = try World.init(std.testing.allocator, dir);
    defer w2.deinit();
    try w2.setBlockRawWorld(5, 70, 5, open_raw);
    try std.testing.expect(try w2.isSolidWorld(5, 70, 5));
}

test "navezgane heights agree with the blocks in the same column" {
    // The client stood in mid air with no collider under it while the server
    // held it several blocks above the terrain top, which is what a heights
    // plane that disagrees with the painted blocks looks like.
    const map_dir = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Worlds/Navezgane";
    if (!io_fs.fileExists(map_dir ++ "/prefabs.xml")) return error.SkipZigTest;

    var w = try World.init(std.testing.allocator, "worlds/zdtd_height_test");
    defer w.deinit();
    try w.loadStockMapEx(map_dir, null);

    // Sampled around the first authored spawn point, where the mismatch showed.
    const spots = [_][2]i32{
        .{ -270, 461 }, .{ -269, 459 }, .{ -273, 449 }, .{ -265, 455 }, .{ -280, 452 },
    };
    for (spots) |p2| {
        const h = try w.heightWorld(p2[0], p2[1]);
        const t2 = World.worldToChunk(p2[0], p2[1]);
        const ch = try w.getOrCreate(t2.pos);
        // Topmost non-air cell in the column: what a client collider rests on.
        var top: i32 = -1;
        var y: i32 = 255;
        while (y >= 0) : (y -= 1) {
            if (ch.blockAt(t2.lx, y, t2.lz) != 0) {
                top = y;
                break;
            }
        }
        try std.testing.expect(top >= 0);
        // heights is the surface the server stands entities on, so it must not
        // float above the highest block it actually placed.
        try std.testing.expect(@as(i32, h) <= top);
    }
}

test "water sources fill lake columns with water blocks" {
    // Chunk bed at y=60, water source surface y=70 at column (5,5): water must
    // fill 61..70; air above; far columns outside radius stay dry. A shore cell
    // with bed at 71 (above the surface) keeps terrain, no water.
    var chunk: Chunk = .{ .pos = .{ .x = 0, .z = 0 } };
    chunk.heights = .{60} ** 256;
    chunk.heights[0] = 71; // shore cell at (0,0): bed above the water surface
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try chunk.ensureBlocksWithStack(arena.allocator(), biome_layers.defaultStack());
    var pts = [_]water_mod.WaterPoint{.{ .x = 5, .y = 70, .z = 5 }};
    const sources = water_mod.Sources{ .points = pts[0..], .allocator = undefined };
    chunk.applyWaterSources(0, 0, &sources, block_water);
    try std.testing.expectEqual(@as(u32, block_water), chunk.blocks.?[blockIndex(5, 61, 5)]);
    try std.testing.expectEqual(@as(u32, block_water), chunk.blocks.?[blockIndex(5, 70, 5)]);
    try std.testing.expectEqual(@as(u32, block_air), chunk.blocks.?[blockIndex(5, 71, 5)]);
    // Shore cell (0,0): bed 71 >= surface 70, keeps its terrain block (dirt 5).
    try std.testing.expectEqual(@as(u32, block_dirt), chunk.blocks.?[blockIndex(0, 70, 0)]);
    // Column (15,15) is outside the radius-12 source ring (dx=10,dz=10 → 200 > 144).
    try std.testing.expectEqual(@as(u32, block_air), chunk.blocks.?[blockIndex(15, 65, 15)]);
}

test "procBiomeAt follows the surface fill field deterministically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    w.enableProc(77);
    // Two resolved biomes at sparse stock ids (biomes.xml: 3 pine_forest,
    // 5 desert) turn the field on and translate index -> real id.
    w.biome_layers_table.names[3] = "pine_forest";
    w.biome_layers_table.names[5] = "desert";
    w.syncWorldgenBiomes();
    try std.testing.expectEqual(@as(u8, 2), w.worldgen.?.biome_n);
    try std.testing.expectEqual(@as(u8, 3), w.biome_layers_table.biomeIdAt(0));
    try std.testing.expectEqual(@as(u8, 5), w.biome_layers_table.biomeIdAt(1));
    // Deterministic and translated into the real id set at any chunk.
    for ([_]i32{ -3, 0, 1, 12 }) |cx| {
        for ([_]i32{ -2, 0, 5 }) |cz| {
            const b = w.procBiomeAt(cx, cz);
            try std.testing.expect(b == 3 or b == 5);
            try std.testing.expectEqual(b, w.procBiomeAt(cx, cz));
        }
    }
    // The biome at a chunk's center is the same field the surface fill used
    // (chunk (0,0) center is world (8,8) for a 16-wide chunk), translated to
    // the real sparse id.
    try std.testing.expectEqual(
        w.biome_layers_table.biomeIdAt(w.worldgen.?.biomeAt(8, 8)),
        w.procBiomeAt(0, 0),
    );
}

test "resolveTerrainIds seeds default stack from live dump ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    const Ctx = struct {
        fn lookup(_: ?*anyopaque, name: []const u8) ?u16 {
            if (std.mem.eql(u8, name, "air")) return 50;
            if (std.mem.eql(u8, name, "terrStone")) return 51;
            if (std.mem.eql(u8, name, "terrBedrock")) return 52;
            if (std.mem.eql(u8, name, "terrDirt")) return 53;
            if (std.mem.eql(u8, name, "water")) return 54;
            if (std.mem.eql(u8, name, "terrForestGround")) return 55;
            if (std.mem.eql(u8, name, "terrainFiller")) return 56;
            if (std.mem.eql(u8, name, "terrainFillerAdaptive")) return 57;
            return null;
        }
    };
    w.resolveTerrainIds(Ctx.lookup, null);
    try std.testing.expectEqual(@as(u16, 55), w.biome_layers_table.default_stack.layers[0].block_id);
    try std.testing.expectEqual(@as(u16, 53), w.biome_layers_table.default_stack.layers[1].block_id);
    try std.testing.expectEqual(@as(u16, 51), w.biome_layers_table.default_stack.layers[2].block_id);
    try std.testing.expectEqual(@as(u16, 52), w.biome_layers_table.default_stack.layers[3].block_id);
    const c = try w.getOrCreate(.{ .x = 0, .z = 0 });
    try std.testing.expectEqual(@as(u16, 50), c.blockAt(0, 200, 0));
    try std.testing.expectEqual(@as(u16, 52), c.blockAt(0, 0, 0));
    w.enableProc(1);
    try std.testing.expectEqual(@as(u16, 50), w.worldgen.?.air_id);
    try std.testing.expectEqual(@as(u16, 51), w.worldgen.?.stone_id);
    try std.testing.expectEqual(@as(u16, 53), w.worldgen.?.dirt_id);
    try std.testing.expectEqual(@as(u16, 52), w.worldgen.?.bedrock_id);
    try std.testing.expectEqual(@as(u16, 55), w.worldgen.?.forest_id);
}

test "syncWorldgenBiomes keeps XML stacks for a single biome" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    w.enableProc(1);
    w.biome_layers_table.names[3] = "pine_forest";
    w.syncWorldgenBiomes();
    try std.testing.expectEqual(@as(u8, 1), w.worldgen.?.biome_n);
    try std.testing.expect(w.worldgen.?.biome_table != null);
}

/// Carve one column (world x, z=0) to air from `lo`..`hi` and return the chunk
/// plane write for the water tests (the flat default world pre-fills terrain
/// up to its surface, so basins must be carved before pouring).
fn carveAirColumn(w: *World, x: i32, lo: i32, hi: i32) !void {
    const ch = try w.getOrCreate(.{ .x = 0, .z = 0 });
    var y: i32 = lo;
    while (y <= hi) : (y += 1) {
        try ch.setBlockRaw(w.allocator, x, y, 0, block_air);
    }
}

test "water leveling: digging beside a lake pours the connected basin to its surface" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    // Flat default world (terrain to its surface ~63). Carve a lake column at
    // x=0 (water 51..62, surface 62) and a basin x=1..7 (air 51..62); x=8
    // stays terrain as the wall. The carve bypasses the edit wrapper, so only
    // the dig below enqueues.
    carveAirColumn(&w, 0, 51, 62) catch return;
    const ch = try w.getOrCreate(.{ .x = 0, .z = 0 });
    var y: i32 = 51;
    while (y <= 62) : (y += 1) {
        try ch.setBlockRaw(w.allocator, 0, y, 0, block_water);
    }
    for (1..8) |x| try carveAirColumn(&w, @intCast(x), 51, 62);
    // Dig the cell right beside the lake (x=1, y=51): its neighbor (0,51) is
    // water with surface 62, so the basin x=1..7, y=51..62 pours (7 x 12).
    try w.setBlockWorld(1, 51, 0, block_air);
    try std.testing.expectEqual(@as(u32, 84), w.levelWaterTick(4, 128, 8));
    try std.testing.expectEqual(block_water, try w.blockWorld(1, 51, 0));
    try std.testing.expectEqual(block_water, try w.blockWorld(3, 55, 0));
    try std.testing.expectEqual(block_water, try w.blockWorld(7, 62, 0));
    // Above the surface cell (63) the flat terrain holds; never water.
    try std.testing.expect((try w.blockWorld(7, 63, 0)) != block_water);
    try std.testing.expect((try w.blockWorld(4, 63, 0)) != block_water);
}

test "water leveling: a deep dig not connected to water stays dry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    carveAirColumn(&w, 0, 51, 62) catch return;
    const ch = try w.getOrCreate(.{ .x = 0, .z = 0 });
    var y: i32 = 51;
    while (y <= 62) : (y += 1) {
        try ch.setBlockRaw(w.allocator, 0, y, 0, block_water);
    }
    // One cell dug at y=45, sealed above by the flat terrain: no water
    // adjacent at the edit, so nothing pours.
    try w.setBlockWorld(1, 45, 0, block_air);
    try std.testing.expectEqual(@as(u32, 0), w.levelWaterTick(4, 128, 8));
    try std.testing.expectEqual(block_air, try w.blockWorld(1, 45, 0));
}

test "water leveling: placed water cascades down its column and puddles" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    // A 1-wide shaft at x=5 carved 51..62; x=4 and x=6 stay terrain walls.
    try carveAirColumn(&w, 5, 51, 62);
    // Placing water (bucket) cascades down the air column to the shaft
    // bottom (stock gravity flow, bounded: 11 cells 51..61; the puddle has
    // no air neighbors - the walls are terrain - so it adds 0).
    try w.setBlockWorld(5, 62, 0, block_water);
    try std.testing.expectEqual(@as(u32, 11), w.levelWaterTick(4, 128, 8));
    try std.testing.expectEqual(block_water, try w.blockWorld(5, 62, 0));
    try std.testing.expectEqual(block_water, try w.blockWorld(5, 61, 0));
    try std.testing.expectEqual(block_water, try w.blockWorld(5, 51, 0));
    try std.testing.expect((try w.blockWorld(5, 50, 0)) != block_water);
}

test "water leveling: the puddle cap bounds sideways spread on a flat floor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    // Flat floor at y=51 (terrain below), open air 51..60 across x=1..8.
    for (1..9) |x| try carveAirColumn(&w, @intCast(x), 51, 60);
    try w.setBlockWorld(4, 51, 0, block_water);
    // Column has no air below (floor at 51 rests on terrain 50); the pour is
    // the puddle only: at most puddle_cap 3 cells spread at the floor level,
    // never climbing (52 stays air).
    try std.testing.expectEqual(@as(u32, 3), w.levelWaterTick(4, 128, 3));
    // 3 puddle cells + the placed cell at the floor level; nothing above.
    var wet: u32 = 0;
    for (1..9) |x| {
        if ((try w.blockWorld(@intCast(x), 51, 0)) == block_water) wet += 1;
    }
    try std.testing.expectEqual(@as(u32, 4), wet);
    try std.testing.expect((try w.blockWorld(4, 52, 0)) != block_water);
}

test "water leveling: the spread cap bounds one pour" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    carveAirColumn(&w, 0, 51, 62) catch return;
    const ch = try w.getOrCreate(.{ .x = 0, .z = 0 });
    var y: i32 = 51;
    while (y <= 62) : (y += 1) {
        try ch.setBlockRaw(w.allocator, 0, y, 0, block_water);
    }
    for (1..8) |x| try carveAirColumn(&w, @intCast(x), 51, 62);
    try w.setBlockWorld(1, 51, 0, block_air);
    // Cap 2: only two cells pour this tick; the rest stay air (a further edit
    // would re-seed, but the queue is drained here).
    try std.testing.expectEqual(@as(u32, 2), w.levelWaterTick(4, 2, 8));
    try std.testing.expectEqual(block_water, try w.blockWorld(1, 51, 0));
    try std.testing.expectEqual(block_air, try w.blockWorld(1, 53, 0));
}

test "chunk pointers stay valid across map resizes (pointer-stable store)" {
    // GAP "Chunk pointer stability" (PARTIAL 2026-08-29): the store maps keys
    // to per-chunk allocations instead of inline Chunk values, so a *Chunk
    // held across a re-entrant getOrCreate survives the map resize that a
    // value-map would dangle (bait-soak segfault 5/5, Debug abort at
    // chunk_fill.zig:327). Regression: same identity + same data after many
    // resizes, and the mid-scan create pattern stays readable.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();

    const held = try w.getOrCreate(.{ .x = 0, .z = 0 });
    const h0 = held.heightAt(0, 0);
    // Force several map resizes while the pointer is held.
    var x: i32 = 1;
    while (x < 40) : (x += 1) {
        _ = try w.getOrCreate(.{ .x = x, .z = 0 });
    }
    // Same identity, same data: the held pointer is still the resident chunk.
    try std.testing.expectEqual(held, w.chunks.get(ChunkPos.hash(.{ .x = 0, .z = 0 })).?);
    try std.testing.expectEqual(h0, held.heightAt(0, 0));
    // Re-entrant mid-scan pattern (chunk_fill.zig te_scan): a pointer held
    // while another chunk is created must stay readable.
    const mid = try w.getOrCreate(.{ .x = 41, .z = 0 });
    const mid_h = mid.heightAt(0, 0);
    _ = try w.getOrCreate(.{ .x = 42, .z = 0 });
    try std.testing.expectEqual(mid_h, mid.heightAt(0, 0));
}
