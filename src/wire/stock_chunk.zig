//! Stock `Chunk.write(PooledBinaryWriter, bNetwork=true)` encoder.
//! Derived on V3.0.1, verified against the V3.1.0 b14 client: the live join
//! streams these chunks and the client meshes them.
//! Used as NetPackageChunk payload so the stock client can Chunk.read without
//! client-side generation. See ../../../7dtd-engine-research/docs/world/save-region.md and Chunk IL dumps.

const std = @import("std");
const binary = @import("binary.zig");

/// MarchingCubes cctor values (unchanged through V3.1.0 b14).
pub const density_air: u8 = 127; // sbyte 127
pub const density_terrain: u8 = 0x80; // sbyte -128
/// Non-terrain solid: stock RepairDensities writes +1 (not terrain density).
pub const density_nonterrain: u8 = 1;

/// Stock terrain type ids from bundled AssignIds dump (not XML ordinals).
const assignids = @import("../assets/assignids_comptime.zig");
pub const stock_air: u16 = assignids.air;
pub const stock_terr_stone: u16 = assignids.terr_stone;
pub const stock_terr_bedrock: u16 = assignids.terr_bedrock;
pub const stock_terr_dirt: u16 = assignids.terr_dirt;
pub const stock_terr_topsoil: u16 = assignids.terr_topsoil;

/// Stock BlockValue.isTerrain: unsigned (type - 1) < 239 → type 1..239.
pub fn isTerrainType(id: u16) bool {
    return id >= 1 and id <= 239;
}

pub fn densityForBlock(id: u16) u8 {
    if (id == stock_air) return density_air;
    if (isTerrainType(id)) return density_terrain;
    // Non-terrain solid: +1 (RepairDensities uses 1, not 0; MC2 maps 0→1 anyway).
    return 1;
}

const stock_layers: usize = 64;

/// Full static water mass. WaterUtils.GetWaterLevel gates visible water at
/// mass > 195 and GetStableMassBelow clamps at 19500, so static lake cells
/// carry the full value (light-mesh-water.md section 4).
pub const water_mass_full: u16 = 19500;
pub const cells_per_layer: usize = 1024; // 16*16*4
/// Dense plane cell count for the stock 16x16x256 chunk (x + z*16 + y*256).
pub const stock_plane_cells: usize = stock_layers * cells_per_layer;
/// Density-override bitset covering `stock_plane_cells`, one bit per cell.
pub const stock_dens_set_bytes: usize = stock_plane_cells / 8;

/// Block rawData provider: (lx, y, lz) -> full BlockValue.rawData (type + rot + meta).
pub const BlockAtFn = *const fn (ctx: ?*anyopaque, lx: i32, y: i32, lz: i32) u32;

/// Texture provider: (lx, y, lz) -> stock int64 textureFull (0 = unpainted).
/// Only the low 48 bits (6 bytes) are wired (chunk textures channel bpv=6).
pub const TexAtFn = *const fn (ctx: ?*anyopaque, lx: i32, y: i32, lz: i32) u64;
/// Optional density override (TTS sbyte as u8). Null return → densityForBlock.
pub const DensAtFn = *const fn (ctx: ?*anyopaque, lx: i32, y: i32, lz: i32) ?u8;
/// Per-cell block damage (u16, bpv=2). Null → all-zero (no damage).
pub const DmgAtFn = *const fn (ctx: ?*anyopaque, lx: i32, y: i32, lz: i32) u16;

pub const EncodeOpts = struct {
    cx: i32,
    cy: i32 = 0,
    cz: i32,
    heights: *const [256]u8,
    ticks: u64 = 1,
    /// When null, fill dirt/stone/bedrock columns from heights using stock type ids.
    block_at: ?BlockAtFn = null,
    block_ctx: ?*anyopaque = null,
    /// Per-block textureFull provider (paint). Null → defaults only.
    /// Shares block_ctx (same chunk pointer).
    tex_at: ?TexAtFn = null,
    /// Optional default textureFull by block type (blocks.xml Texture). Used when
    /// paint is 0 so shape faces are not grey. Never for terrain (client catalog).
    default_tex: ?*const fn (ctx: ?*anyopaque, type_id: u16) u64 = null,
    default_tex_ctx: ?*anyopaque = null,
    /// Optional density override (TTS). Null → densityForBlock(type).
    dens_at: ?DensAtFn = null,
    biome: u8 = 3, // pine forest-ish placeholder
    /// Optional per-cell biome provider (world XZ -> wire biome id): fills the
    /// 256 biome cells + intensities so transitions follow the biome map
    /// instead of snapping to the chunk dominant. Null -> uniform `biome`.
    biome_at: ?*const fn (ctx: ?*anyopaque, wx: i32, wz: i32) u8 = null,
    biome_ctx: ?*anyopaque = null,
    /// AssignIds water block id; 0 disables the water channel (all-zero).
    /// When set, cells whose block type is water carry water_mass_full.
    water_block_id: u16 = 0,
    /// Optional per-cell damage (u16). Null → no damage channel data.
    dmg_at: ?DmgAtFn = null,
    dmg_ctx: ?*anyopaque = null,
    /// Stock m_bTopSoilBroken bitfield (32 bytes, 1 bit per XZ column):
    /// clear = intact topsoil (client splat-renders), set = disturbed (block
    /// textures). Null → all-clear (fresh-world state, stock default).
    topsoil: ?*const [32]u8 = null,
    /// Wire geometry profile (ADR geometry/wire-profiles): the block-layer
    /// band count (64 stock, y_dim/4 expanded) and the column height used for
    /// the callback-path bounds and the stock-memo guard. XZ planes
    /// (heights/biomes/intensities) and the plane index stride (ChunkAreaDim
    /// 256) never change. Defaults are stock; a non-stock dialect requires a
    /// paired client mod.
    layers: usize = stock_layers,
    y_dim: usize = 256,
    /// Dense precomputed raw plane (`stock_plane_cells` BlockValue cells, x + z*16 + y*256).
    /// When set, the block-layer loop and density/water SIMD packs read it
    /// directly. When null, `raws_scratch` is filled once (height-band SIMD or
    /// block_at) and then used the same way.
    /// Stock-only: the plane type is the 256-tall layout, so non-stock
    /// profiles must pass null here and rely on the per-layer block_at
    /// callback path.
    raws: ?*const [stock_plane_cells]u32 = null,
    /// Caller-owned scratch for `raws` (pre-allocated; no hot-path heap). Used
    /// only when `raws` is null. Null disables the memoization: channels fall
    /// back to the block_at callback.
    raws_scratch: ?*[stock_plane_cells]u32 = null,
    /// TTS density paint plane (stock sbyte as u8) + bitset of painted cells.
    /// Both null, or both stock-length (`stock_plane_cells` dens bytes /
    /// `stock_dens_set_bytes` set bytes). When set with `raws`,
    /// writeDensityChannel SIMD-packs from raws then overlays painted cells
    /// so POI chunks keep the fast path instead of dens_at.
    dens_plane: ?*const [stock_plane_cells]u8 = null,
    dens_set: ?*const [stock_dens_set_bytes]u8 = null,
};

fn texAt(opts: EncodeOpts, lx: i32, y: i32, lz: i32) u64 {
    // Only TTS/world paint. Terrain mesh uses client Block.GetSideTextureId from
    // blocks.xml (ids can be >255). Chunk channel is 6×u8 faces; emitting truncated
    // defaults (e.g. 288→32) overrides client catalog and greys the ground.
    // Shape paint from TTS stays ≤255 (painting.xml) and must be wired.
    if (opts.tex_at) |f| {
        const painted = f(opts.block_ctx, lx, y, lz);
        if (painted != 0) return painted;
    }
    // Optional defaults only when every face byte is a valid paint id (0..255 already).
    if (opts.default_tex) |df| {
        const tid = blockType(rawAt(opts, lx, y, lz));
        if (tid == stock_air or isTerrainType(tid)) return 0;
        return df(opts.default_tex_ctx, tid);
    }
    return 0;
}

pub fn defaultBlockAt(heights: *const [256]u8, lx: i32, y: i32, lz: i32) u32 {
    if (y < 0 or y >= 256) return stock_air;
    const h = heights[@intCast(lx + lz * 16)];
    if (y > h) return stock_air;
    if (y == 0) return stock_terr_bedrock;
    if (y + 3 < h) return stock_terr_stone;
    if (y == h) return stock_terr_topsoil;
    if (y + 1 == h) return stock_terr_dirt;
    return stock_terr_dirt;
}

/// Fill a dense 16×256×16 raw plane from the height map (`defaultBlockAt`).
/// Vectorized over 16-wide XZ runs per Y. Scalar equivalent: `out[i] =
/// defaultBlockAt(heights, i%16, i/256, (i/16)%16)`.
pub fn fillDefaultRawsFromHeights(heights: *const [256]u8, out: *[stock_plane_cells]u32) void {
    const lanes = 16;
    const V = @Vector(lanes, u32);
    const Vu = @Vector(lanes, u16);
    const Vb = @Vector(lanes, u8);
    const air_v: V = @splat(@as(u32, stock_air));
    const bedrock_v: V = @splat(@as(u32, stock_terr_bedrock));
    const stone_v: V = @splat(@as(u32, stock_terr_stone));
    const topsoil_v: V = @splat(@as(u32, stock_terr_topsoil));
    const dirt_v: V = @splat(@as(u32, stock_terr_dirt));
    const zero_u8: Vb = @splat(0);
    var y: u16 = 0;
    while (y < 256) : (y += 1) {
        const yb: Vb = @splat(@truncate(y));
        const yu: Vu = @splat(y);
        const y_plus_3 = yu + @as(Vu, @splat(3));
        var col: usize = 0;
        while (col < 256) : (col += lanes) {
            const h: Vb = heights[col..][0..lanes].*;
            const hu: Vu = h;
            var raw: V = dirt_v;
            raw = @select(u32, yb == h, topsoil_v, raw);
            raw = @select(u32, y_plus_3 < hu, stone_v, raw);
            raw = @select(u32, yb == zero_u8, bedrock_v, raw);
            raw = @select(u32, yb > h, air_v, raw);
            out[col + @as(usize, y) * 256 ..][0..lanes].* = raw;
        }
    }
}

fn blockAt(opts: EncodeOpts, lx: i32, y: i32, lz: i32) u32 {
    if (opts.block_at) |f| return f(opts.block_ctx, lx, y, lz);
    return defaultBlockAt(opts.heights, lx, y, lz);
}

/// BlockValue at a cell: the precomputed dense plane when present (encodeNetworkChunk
/// fills it once per chunk), else the block_at callback. Hot stream path: the
/// density and water channels read the plane instead of re-invoking blockAt.
fn rawAt(opts: EncodeOpts, lx: i32, y: i32, lz: i32) u32 {
    if (y < 0 or y >= @as(i32, @intCast(opts.y_dim))) return stock_air;
    if (opts.raws) |r| return r[@intCast(lx + lz * 16 + y * 256)];
    return blockAt(opts, lx, y, lz);
}

/// BlockValue.type: low 16 of rawData.
const block_type_mask: u32 = 0xffff;

pub fn blockType(raw: u32) u16 {
    return @intCast(raw & block_type_mask);
}

/// Layer cell index matching stock: x + z*16 + (y&3)*256 within a 4-high band.
pub fn layerCell(lx: i32, y_in_layer: i32, lz: i32) usize {
    return @intCast(lx + lz * 16 + y_in_layer * 256);
}

/// Most common biome id across the 256 cells (stock CalcDominantBiome counts
/// by value; ties fall to the first maximum). `fallback` seeds the dominant and
/// wins only when no cell count exceeds zero (an all-0 cell grid is dominant 0).
pub fn dominantOf(biomes: *const [256]u8, fallback: u8) u8 {
    var counts: [256]u16 = .{0} ** 256;
    for (biomes) |b| counts[b] +|= 1;
    var dom = fallback;
    var best: u16 = 0;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        if (counts[i] > best) {
            best = counts[i];
            dom = @intCast(i);
        }
    }
    return dom;
}

// --- SIMD helpers (portable @Vector; scalar tail). Hot path: stack only. ---

const simd_u8_w: usize = 16;
const simd_u32_w: usize = 8;
const simd_u64_w: usize = 4;

/// True if every byte equals slice[0] (empty → true).
pub fn layerIsUniformU8(slice: []const u8) bool {
    if (slice.len <= 1) return true;
    const first = slice[0];
    const splat: @Vector(simd_u8_w, u8) = @splat(first);
    var i: usize = 0;
    while (i + simd_u8_w <= slice.len) : (i += simd_u8_w) {
        const chunk: @Vector(simd_u8_w, u8) = slice[i..][0..simd_u8_w].*;
        if (@reduce(.Or, chunk != splat)) return false;
    }
    while (i < slice.len) : (i += 1) {
        if (slice[i] != first) return false;
    }
    return true;
}

/// True if every u32 equals slice[0].
pub fn layerIsUniformU32(slice: []const u32) bool {
    if (slice.len <= 1) return true;
    const first = slice[0];
    const splat: @Vector(simd_u32_w, u32) = @splat(first);
    var i: usize = 0;
    while (i + simd_u32_w <= slice.len) : (i += simd_u32_w) {
        const chunk: @Vector(simd_u32_w, u32) = slice[i..][0..simd_u32_w].*;
        if (@reduce(.Or, chunk != splat)) return false;
    }
    while (i < slice.len) : (i += 1) {
        if (slice[i] != first) return false;
    }
    return true;
}

/// True if every u64 equals slice[0].
pub fn layerIsUniformU64(slice: []const u64) bool {
    if (slice.len <= 1) return true;
    const first = slice[0];
    const splat: @Vector(simd_u64_w, u64) = @splat(first);
    var i: usize = 0;
    while (i + simd_u64_w <= slice.len) : (i += simd_u64_w) {
        const chunk: @Vector(simd_u64_w, u64) = slice[i..][0..simd_u64_w].*;
        if (@reduce(.Or, chunk != splat)) return false;
    }
    while (i < slice.len) : (i += 1) {
        if (slice[i] != first) return false;
    }
    return true;
}

/// True if any cell has block type != air (low 16 bits of rawData).
pub fn layerAnyNonAirU32(raws: []const u32) bool {
    const zero: @Vector(simd_u32_w, u32) = @splat(0);
    const mask: @Vector(simd_u32_w, u32) = @splat(0xffff);
    var i: usize = 0;
    while (i + simd_u32_w <= raws.len) : (i += simd_u32_w) {
        const chunk: @Vector(simd_u32_w, u32) = raws[i..][0..simd_u32_w].*;
        const types = chunk & mask;
        if (@reduce(.Or, types != zero)) return true;
    }
    while (i < raws.len) : (i += 1) {
        if (blockType(raws[i]) != stock_air) return true;
    }
    return false;
}

/// True if any raw has bits 8..31 set (needs upper24 channel).
pub fn layerNeedsUpperU32(raws: []const u32) bool {
    const zero: @Vector(simd_u32_w, u32) = @splat(0);
    var i: usize = 0;
    while (i + simd_u32_w <= raws.len) : (i += simd_u32_w) {
        const chunk: @Vector(simd_u32_w, u32) = raws[i..][0..simd_u32_w].*;
        if (@reduce(.Or, (chunk >> @as(@Vector(simd_u32_w, u5), @splat(8))) != zero)) return true;
    }
    while (i < raws.len) : (i += 1) {
        if ((raws[i] >> 8) != 0) return true;
    }
    return false;
}

/// Pack low 8 bits of each raw into lower[0..raws.len].
pub fn packLowerU8(raws: []const u32, lower: []u8) void {
    std.debug.assert(lower.len >= raws.len);
    var i: usize = 0;
    while (i + simd_u32_w <= raws.len) : (i += simd_u32_w) {
        const chunk: @Vector(simd_u32_w, u32) = raws[i..][0..simd_u32_w].*;
        const lo: @Vector(simd_u32_w, u8) = @truncate(chunk);
        lower[i..][0..simd_u32_w].* = lo;
    }
    while (i < raws.len) : (i += 1) {
        lower[i] = @truncate(raws[i]);
    }
}

/// Pack upper24 as interleaved (b1,b2,b3) per cell into upper[raws.len*3].
/// Vectorized: bytes 8..31 of 8 raws become one 24-byte interleaved store.
/// Scalar equivalent: upper[c*3+j] = byte j of (raws[c] >> 8).
pub fn packUpper24(raws: []const u32, upper: []u8) void {
    std.debug.assert(upper.len >= raws.len * 3);
    var cell: usize = 0;
    while (cell + 8 <= raws.len) : (cell += 8) {
        const chunk: @Vector(8, u32) = raws[cell..][0..8].*;
        // Byte j (j in 1..3) of each u32: shift then truncate to u8 lanes.
        const b1: @Vector(8, u8) = @truncate(chunk >> @as(@Vector(8, u5), @splat(8)));
        const b2: @Vector(8, u8) = @truncate(chunk >> @as(@Vector(8, u5), @splat(16)));
        const b3: @Vector(8, u8) = @truncate(chunk >> @as(@Vector(8, u5), @splat(24)));
        // Three-way per-cell interleave [b1_c, b2_c, b3_c]. @shuffle needs two
        // equal-length sources: concat b1+b2 into 16 lanes and duplicate b3 into
        // a 16-lane pad whose unused lanes are never selected by the mask.
        const c12: @Vector(16, u8) = @shuffle(u8, b1, b2, upper_concat_mask);
        const pad: @Vector(16, u8) = @shuffle(u8, b3, b3, upper_dup_mask);
        const out: @Vector(24, u8) = @shuffle(u8, c12, pad, upper_interleave_mask);
        upper[cell * 3 ..][0..24].* = out;
    }
    while (cell < raws.len) : (cell += 1) {
        const raw = raws[cell];
        upper[cell * 3 + 0] = @truncate(raw >> 8);
        upper[cell * 3 + 1] = @truncate(raw >> 16);
        upper[cell * 3 + 2] = @truncate(raw >> 24);
    }
}

// @shuffle masks for packUpper24: concat(b1,b2) as c12, then the 24-lane
// interleave [b1_c, b2_c, b3_c] selecting c12 lanes 0..7 / 8..15 and pad -1..-8
// (Zig 0.16: non-negative mask = source a, -1..-N = source b).
const upper_concat_mask: @Vector(16, i32) = @Vector(16, i32){
    0, 1, 2, 3, 4, 5, 6, 7, -1, -2, -3, -4, -5, -6, -7, -8,
};
const upper_dup_mask: @Vector(16, i32) = @Vector(16, i32){
    0, 1, 2, 3, 4, 5, 6, 7, -1, -2, -3, -4, -5, -6, -7, -8,
};
const upper_interleave_mask: @Vector(24, i32) = @Vector(24, i32){
    0, 8,  -1, 1, 9,  -2, 2, 10, -3, 3, 11, -4,
    4, 12, -5, 5, 13, -6, 6, 14, -7, 7, 15, -8,
};

/// Write texture plane j (byte j of each u64) into out[0..vals.len].
pub fn packTexturePlane(vals: []const u64, plane: u3, out: []u8) void {
    std.debug.assert(out.len >= vals.len);
    std.debug.assert(plane < 6);
    const shift_amt: u6 = @as(u6, plane) * 8;
    var i: usize = 0;
    while (i + simd_u64_w <= vals.len) : (i += simd_u64_w) {
        const chunk: @Vector(simd_u64_w, u64) = vals[i..][0..simd_u64_w].*;
        // Shift vector lane type is log2 of element bits (u6 for u64).
        const shifted = chunk >> @as(@Vector(simd_u64_w, u6), @splat(shift_amt));
        const bytes: @Vector(simd_u64_w, u8) = @truncate(shifted);
        out[i..][0..simd_u64_w].* = bytes;
    }
    while (i < vals.len) : (i += 1) {
        out[i] = @truncate(vals[i] >> shift_amt);
    }
}

/// Density bytes from dense rawData: densityForBlock per low-16 type.
/// Scalar equivalent: dens[i] = densityForBlock(blockType(raws[i])).
/// Hot stream path when dens_at is null and a raw plane is memoized.
pub fn packDensityFromRaws(raws: []const u32, dens: []u8) void {
    std.debug.assert(dens.len >= raws.len);
    const mask: @Vector(simd_u32_w, u32) = @splat(0xffff);
    const zero: @Vector(simd_u32_w, u32) = @splat(0);
    const one: @Vector(simd_u32_w, u32) = @splat(1);
    const terr_hi: @Vector(simd_u32_w, u32) = @splat(239);
    const air_d: @Vector(simd_u32_w, u8) = @splat(density_air);
    const terr_d: @Vector(simd_u32_w, u8) = @splat(density_terrain);
    const non_d: @Vector(simd_u32_w, u8) = @splat(density_nonterrain);
    var i: usize = 0;
    while (i + simd_u32_w <= raws.len) : (i += simd_u32_w) {
        const chunk: @Vector(simd_u32_w, u32) = raws[i..][0..simd_u32_w].*;
        const ty = chunk & mask;
        const is_air = ty == zero;
        // isTerrainType: type in 1..239 (air 0 is excluded by the lower bound).
        const is_terrain = (ty >= one) & (ty <= terr_hi);
        const mid = @select(u8, is_terrain, terr_d, non_d);
        dens[i..][0..simd_u32_w].* = @select(u8, is_air, air_d, mid);
    }
    while (i < raws.len) : (i += 1) {
        dens[i] = densityForBlock(blockType(raws[i]));
    }
}

const simd_u16_w: usize = 8;

/// Write byte plane of each u16 into out (plane 0 = lo, plane 1 = hi).
/// Scalar equivalent: out[i] = @truncate(vals[i] >> (plane * 8)).
pub fn packU16Plane(vals: []const u16, plane: u1, out: []u8) void {
    std.debug.assert(out.len >= vals.len);
    const shift_amt: u4 = @as(u4, plane) * 8;
    var i: usize = 0;
    while (i + simd_u16_w <= vals.len) : (i += simd_u16_w) {
        const chunk: @Vector(simd_u16_w, u16) = vals[i..][0..simd_u16_w].*;
        const shifted = chunk >> @as(@Vector(simd_u16_w, u4), @splat(shift_amt));
        const bytes: @Vector(simd_u16_w, u8) = @truncate(shifted);
        out[i..][0..simd_u16_w].* = bytes;
    }
    while (i < vals.len) : (i += 1) {
        out[i] = @truncate(vals[i] >> shift_amt);
    }
}

/// Fill water mass plane from dense raws. Writes mass_full where type == water_id,
/// else 0. Returns true if any cell is water.
/// Scalar equivalent: per-cell type compare + assign water_mass_full.
pub fn fillWaterMassFromRaws(raws: []const u32, water_id: u16, vals: []u16) bool {
    std.debug.assert(vals.len >= raws.len);
    const mask: @Vector(simd_u32_w, u32) = @splat(0xffff);
    const wid: @Vector(simd_u32_w, u32) = @splat(water_id);
    const mass: @Vector(simd_u32_w, u16) = @splat(water_mass_full);
    const zero: @Vector(simd_u32_w, u16) = @splat(0);
    var has_water = false;
    var i: usize = 0;
    while (i + simd_u32_w <= raws.len) : (i += simd_u32_w) {
        const chunk: @Vector(simd_u32_w, u32) = raws[i..][0..simd_u32_w].*;
        const hit = (chunk & mask) == wid;
        if (@reduce(.Or, hit)) has_water = true;
        vals[i..][0..simd_u32_w].* = @select(u16, hit, mass, zero);
    }
    while (i < raws.len) : (i += 1) {
        if (blockType(raws[i]) == water_id) {
            vals[i] = water_mass_full;
            has_water = true;
        } else {
            vals[i] = 0;
        }
    }
    return has_water;
}

/// Write one same-value ChunkBlockChannel (all layers null, sameValue filled).
fn writeChannelSame(w: *binary.Writer, bytes_per_val: usize, fill: []const u8, layers: usize) !void {
    // fill length must be bytes_per_val (one value repeated into sameValue slots by read path).
    // Encoder: presence bit 1 (null layer) + sameValue bytes per layer.
    var scratch: [256]u8 = undefined;
    var pos: usize = 0;
    var layer: usize = 0;
    while (layer < layers) : (layer += 1) {
        if (pos >= scratch.len) {
            try w.writeBytes(scratch[0..pos]);
            pos = 0;
        }
        scratch[pos] = 1; // layer is null → sameValue path
        pos += 1;
        var j: usize = 0;
        while (j < bytes_per_val) : (j += 1) {
            if (pos >= scratch.len) {
                try w.writeBytes(scratch[0..pos]);
                pos = 0;
            }
            const b = if (j < fill.len) fill[j] else 0;
            scratch[pos] = b;
            pos += 1;
        }
    }
    if (pos > 0) try w.writeBytes(scratch[0..pos]);
}

/// Encode network-mode Chunk.write body (no NetPackageChunk envelope).
pub fn encodeNetworkChunk(buf: []u8, opts: EncodeOpts) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };

    try w.writeI32(opts.cx);
    try w.writeI32(opts.cy);
    try w.writeI32(opts.cz);
    try w.writeU64(opts.ticks);

    // Dense raw plane, filled once when the caller supplies scratch: the
    // layer bands, the density channel and the water channel all read the same
    // per-cell BlockValue, and re-invoking the block_at callback per channel
    // triples the lookup cost on the stream path. Without scratch the channels
    // fall back to the callback (tests and cold paths).
    // The plane type is the 256-tall layout, so the memo path is stock-only; a
    // non-stock dialect (taller column) always uses the per-layer callback.
    var opts_memo = opts;
    if (opts.raws == null and opts.y_dim == 256) {
        if (opts.raws_scratch) |scratch| {
            if (opts.block_at == null) {
                fillDefaultRawsFromHeights(opts.heights, scratch);
            } else {
                var i: usize = 0;
                while (i < scratch.len) : (i += 1) {
                    const lx: i32 = @intCast(i % 16);
                    const lz: i32 = @intCast((i / 16) % 16);
                    const y: i32 = @intCast(i / 256);
                    scratch[i] = blockAt(opts, lx, y, lz);
                }
            }
            opts_memo.raws = scratch;
        }
    }

    // block layers (64 stock, y_dim/4 for a taller dialect)
    var layer_i: usize = 0;
    while (layer_i < opts.layers) : (layer_i += 1) {
        const y0: i32 = @intCast(layer_i * 4);
        // Fill dense raw plane (layer cell order), then SIMD any/uniform/pack.
        var raws: [cells_per_layer]u32 = undefined;
        if (opts_memo.raws) |plane| {
            @memcpy(raws[0..], plane[@as(usize, @intCast(y0)) * 256 ..][0..cells_per_layer]);
        } else {
            var ly: i32 = 0;
            while (ly < 4) : (ly += 1) {
                var lz: i32 = 0;
                while (lz < 16) : (lz += 1) {
                    var lx: i32 = 0;
                    while (lx < 16) : (lx += 1) {
                        raws[layerCell(lx, ly, lz)] = blockAt(opts, lx, y0 + ly, lz);
                    }
                }
            }
        }
        const any_solid = layerAnyNonAirU32(&raws);
        try w.writeBool(any_solid);
        if (!any_solid) continue;

        // Block ids are the full 32-bit BlockValue.rawData split lower8 + upper24
        // (ChunkBlockLayer.Read: lower8 same-value byte or 1024 array, then upper24
        // null or 3072 interleaved bytes = (id>>8, id>>16, id>>24) per cell).
        const first = raws[0];
        const uniform = layerIsUniformU32(&raws);
        const need_upper = layerNeedsUpperU32(&raws);
        var lower: [cells_per_layer]u8 = undefined;
        var upper: [cells_per_layer * 3]u8 = undefined;
        if (uniform) {
            // These two bytes coincide only for an all-air layer, where
            // `first` is stock_air = 0 and both are 0 - and this branch is not
            // even reached then (the `any_solid` check continues above). A
            // uniform solid layer makes them differ, and the order is what
            // ChunkBlockLayer.Read expects (presence bool, then the shared
            // value): swapping them tells the client a 1024-byte lower array
            // follows. Pinned by "a uniform non-air layer writes the presence
            // bool before the shared value".
            try w.writeBool(false); // no lower array → same value
            try w.writeByte(@truncate(first));
            if (need_upper) {
                packUpper24(&raws, &upper);
                try w.writeBool(true);
                try w.writeBytes(&upper);
            } else {
                try w.writeBool(false);
            }
        } else {
            packLowerU8(&raws, &lower);
            try w.writeBool(true);
            try w.writeBytes(&lower);
            if (need_upper) {
                packUpper24(&raws, &upper);
                try w.writeBool(true);
                try w.writeBytes(&upper);
            } else {
                try w.writeBool(false);
            }
        }
    }

    // bNetwork=true: skip stability channel

    // heightmap 256
    try w.writeBytes(opts.heights);

    // terrain height 256 (same as surface for flat columns)
    try w.writeBytes(opts.heights);

    // m_bTopSoilBroken: 32-byte bitfield (1 bit per XZ column). Clear =
    // topsoil intact, the client splat-renders the top terrain block via
    // MicroSplat; set = disturbed (dig/upgrade/explosion), block textures.
    // The chunk's real state rides the wire; null opts fall back to the
    // fresh-world all-clear (stock default). RE Chunk.SetTopSoilBroken
    // IL=36 (world-chunks.md); the all-0xFF workaround is gone (it made
    // every column render block textures, never the stock splat look).
    const topsoil = opts.topsoil orelse &[_]u8{0} ** 32;
    try w.writeBytes(topsoil);

    // biomes 256
    var biomes: [256]u8 = .{opts.biome} ** 256;
    // Per-cell biome provider (biomes.png / proc): smooths biome transitions
    // to the cell instead of snapping to the chunk dominant. Fallback keeps
    // the uniform dominant value.
    if (opts.biome_at) |bf| {
        var lz: i32 = 0;
        while (lz < 16) : (lz += 1) {
            var lx: i32 = 0;
            while (lx < 16) : (lx += 1) {
                const wx = opts.cx * 16 + lx;
                const wz = opts.cz * 16 + lz;
                biomes[@as(usize, @intCast(lz * 16 + lx))] = bf(opts.biome_ctx, wx, wz);
            }
        }
    }
    try w.writeBytes(&biomes);

    // biome intensities: 1536 bytes = BiomeIntensity[256], 6 bytes each interleaved:
    // biomeId0..3, intensity0and1 (lo nibble=i0), intensity2and3
    // Default stock full single-biome: id0=biome, intensity0and1=0x0F (i0=1).
    var intensities: [1536]u8 = .{0} ** 1536;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const o = i * 6;
        intensities[o] = biomes[i];
        intensities[o + 4] = 0x0F;
    }
    try w.writeBytes(&intensities);

    // DominantBiome / AreaMasterDominantBiome: most common cell (stock
    // CalcDominantBiome picks by count; ties fall to the first maximum).
    const dom = if (opts.biome_at != null) dominantOf(&biomes, opts.biome) else opts.biome;
    try w.writeByte(dom); // DominantBiome
    try w.writeByte(dom); // AreaMasterDominantBiome

    // custom data count (network filter): u16
    try w.writeU16(0);

    // Terrain normals as sbyte * 127 (Chunk.SetTerrainNormal). Flat = (0,1,0).
    var nx: [256]u8 = .{0} ** 256;
    var ny: [256]u8 = .{127} ** 256;
    var nz: [256]u8 = .{0} ** 256;
    try w.writeBytes(&nx);
    try w.writeBytes(&ny);
    try w.writeBytes(&nz);

    // density: solid below surface, air above (per-cell via full layers is heavy;
    // use same-value air for empty sky layers is handled by block presence).
    // Emit density channel as full per-layer data for bands that have solids, else same air.
    // Density/texture/water share the memoized raw plane when raws_scratch filled
    // opts_memo.raws (stream path). Passing plain opts would drop the plane and
    // re-invoke blockAt per cell (and skip SIMD density/water packs).
    try writeDensityChannel(&w, opts_memo);

    // light bpv=1: full sun+block (0xFF). Zero light makes the whole mesh black/grey
    // until client LightChunk runs; seed bright so first mesh is readable.
    try writeChannelSame(&w, 1, &[_]u8{0xFF}, opts.layers);
    try writeDamageChannel(&w, opts_memo);
    // textures[0] bpv=6: TTS paint, else blocks.xml default Texture packing.
    try writeTextureChannel(&w, opts_memo);
    // water bpv=2: per-cell WaterValue mass. Static lake cells carry the full
    // mass; air/other cells 0. Same-value 0 layers stay tiny.
    try writeWaterChannel(&w, opts_memo);

    // true → client runs light rebuild; false + bright seed still meshes immediately.
    try w.writeBool(true); // NeedsLightCalculation

    // entity count 0
    try w.writeI32(0);
    // tile entity count 0
    try w.writeI32(0);

    // bHasSleeperVolume false (always written)
    try w.writeBool(false);

    // bNetwork skips sleeper/trigger volume lists; wall volumes always written
    // wall volume count as byte 0
    try w.writeByte(0);

    // Network mode writes the branch flag, followed by the always-present
    // insideDevices list. This terrain-only chunk has no inside devices.
    try w.writeBool(false); // the network branch bool before insideDevices
    try w.writeI16(0); // insideDevices count

    try w.writeBool(false); // IsInternalBlocksCulled

    // bNetwork skips BlockTrigger list

    return w.written();
}

/// Density at one cell. Stock CheckDensities / RepairDensities:
///   terrain shape → density must be < 0  (use DensityTerrain = -128)
///   non-terrain   → density must be >= 0 (air 127, solid shape 1)
/// Intermediate gradients are optional; binary extremes match repairchunkdensity.
fn densityAt(opts: EncodeOpts, lx: i32, y: i32, lz: i32) u8 {
    if (opts.dens_at) |f| {
        if (f(opts.block_ctx, lx, y, lz)) |d| return d;
    }
    return densityForBlock(blockType(rawAt(opts, lx, y, lz)));
}

/// Overlay TTS density paint onto a band already filled by packDensityFromRaws.
/// `base` is the absolute plane index of dens[0] (y0*256). dens_set bits are
/// 1 = dens_plane[idx] is a TTS override. Scalar equivalent: per cell, if the
/// set bit is on write dens_plane else keep the raw-derived density.
fn overlayDensPaint(dens: *[cells_per_layer]u8, dens_plane: *const [stock_plane_cells]u8, dens_set: *const [stock_dens_set_bytes]u8, base: usize) void {
    const lanes: usize = 8;
    var c: usize = 0;
    while (c + lanes <= cells_per_layer) : (c += lanes) {
        const abs = base + c;
        const bits = dens_set[abs / 8];
        if (bits == 0) continue;
        var mask: @Vector(lanes, bool) = undefined;
        inline for (0..lanes) |lane| {
            mask[lane] = (bits & (@as(u8, 1) << @intCast(lane))) != 0;
        }
        const painted: @Vector(lanes, u8) = dens_plane[abs..][0..lanes].*;
        const base_d: @Vector(lanes, u8) = dens[c..][0..lanes].*;
        dens[c..][0..lanes].* = @select(u8, mask, painted, base_d);
    }
}

pub fn writeDensityChannel(w: *binary.Writer, opts: EncodeOpts) !void {
    // ChunkBlockChannel bpv=1: per layer presence(1=null/sameValue, 0=full 1024).
    // Fast path: dense raw plane → SIMD packDensityFromRaws, then optional TTS
    // dens_plane/dens_set overlay. dens_at without a paint plane (or missing
    // raws) falls back to per-cell densityAt (scalar).
    const paint = opts.dens_plane != null and opts.dens_set != null;
    const use_simd = opts.raws != null and (opts.dens_at == null or paint);
    var layer_i: usize = 0;
    while (layer_i < opts.layers) : (layer_i += 1) {
        const y0: i32 = @intCast(layer_i * 4);
        var dens: [cells_per_layer]u8 = undefined;
        if (use_simd) {
            const plane = opts.raws.?;
            const base: usize = @intCast(y0 * 256);
            packDensityFromRaws(plane[base..][0..cells_per_layer], &dens);
            if (paint) overlayDensPaint(&dens, opts.dens_plane.?, opts.dens_set.?, base);
        } else {
            var ly: i32 = 0;
            while (ly < 4) : (ly += 1) {
                var lz: i32 = 0;
                while (lz < 16) : (lz += 1) {
                    var lx: i32 = 0;
                    while (lx < 16) : (lx += 1) {
                        dens[layerCell(lx, ly, lz)] = densityAt(opts, lx, y0 + ly, lz);
                    }
                }
            }
        }
        if (layerIsUniformU8(&dens)) {
            try w.writeByte(1);
            try w.writeByte(dens[0]);
        } else {
            try w.writeByte(0);
            try w.writeBytes(&dens);
        }
    }
}

/// Textures channel (ChunkBlockChannel bpv=6): per 4-high band, a presence byte
/// then either 6 same-value bytes (uniform band) or 6 byte-planes of 1024 bytes
/// (plane j = byte j of each cell's textureFull). Value = low 6 bytes of the
/// int64 textureFull, little-endian. Matches ChunkBlockChannel.Read.
fn writeTextureChannel(w: *binary.Writer, opts: EncodeOpts) !void {
    const bpv: usize = 6;
    var band: usize = 0;
    while (band < opts.layers) : (band += 1) {
        const y0: i32 = @intCast(band * 4);
        var vals: [cells_per_layer]u64 = undefined;
        var ly: i32 = 0;
        while (ly < 4) : (ly += 1) {
            var lz: i32 = 0;
            while (lz < 16) : (lz += 1) {
                var lx: i32 = 0;
                while (lx < 16) : (lx += 1) {
                    vals[layerCell(lx, ly, lz)] = texAt(opts, lx, y0 + ly, lz);
                }
            }
        }
        if (layerIsUniformU64(&vals)) {
            const first = vals[0];
            try w.writeByte(1); // presence: same-value band
            var j: usize = 0;
            while (j < bpv) : (j += 1) try w.writeByte(@truncate(first >> @intCast(j * 8)));
        } else {
            try w.writeByte(0); // presence: full byte-planes
            var plane_buf: [cells_per_layer]u8 = undefined;
            var j: usize = 0;
            while (j < bpv) : (j += 1) {
                packTexturePlane(&vals, @intCast(@as(u3, @intCast(j))), &plane_buf);
                try w.writeBytes(&plane_buf);
            }
        }
    }
}

/// Water channel (bpv=2): per-cell WaterValue mass, encoded like the texture
/// channel. A layer with no water writes presence 1 + same-value u16 0; a layer
/// with water writes presence 0 + two byte-planes (lo, hi) of u16 masses.
fn writeWaterChannel(w: *binary.Writer, opts: EncodeOpts) !void {
    var band: usize = 0;
    while (band < opts.layers) : (band += 1) {
        const y0: i32 = @intCast(band * 4);
        var vals: [cells_per_layer]u16 = .{0} ** cells_per_layer;
        var has_water = false;
        if (opts.water_block_id != 0) {
            if (opts.raws) |plane| {
                const base: usize = @intCast(y0 * 256);
                has_water = fillWaterMassFromRaws(plane[base..][0..cells_per_layer], opts.water_block_id, &vals);
            } else {
                var ly: i32 = 0;
                while (ly < 4) : (ly += 1) {
                    var lz: i32 = 0;
                    while (lz < 16) : (lz += 1) {
                        var lx: i32 = 0;
                        while (lx < 16) : (lx += 1) {
                            const raw = rawAt(opts, lx, y0 + ly, lz);
                            if (blockType(raw) == opts.water_block_id) {
                                vals[layerCell(lx, ly, lz)] = water_mass_full;
                                has_water = true;
                            }
                        }
                    }
                }
            }
        }
        if (!has_water) {
            try w.writeByte(1); // presence: same-value
            try w.writeU16(0);
            continue;
        }
        try w.writeByte(0); // presence: full byte-planes
        var plane_buf: [cells_per_layer]u8 = undefined;
        for (0..2) |j| {
            packU16Plane(&vals, @intCast(j), &plane_buf);
            try w.writeBytes(&plane_buf);
        }
    }
}

/// Damage channel (bpv=2): per-cell u16 block HP. Null dmg_at → all-zero.
fn writeDamageChannel(w: *binary.Writer, opts: EncodeOpts) !void {
    if (opts.dmg_at == null) {
        try writeChannelSame(w, 2, &[_]u8{ 0, 0 }, opts.layers);
        return;
    }
    const f = opts.dmg_at.?;
    const ctx = opts.dmg_ctx;
    var band: usize = 0;
    while (band < opts.layers) : (band += 1) {
        const y0: i32 = @intCast(band * 4);
        var vals: [cells_per_layer]u16 = .{0} ** cells_per_layer;
        var has_dmg = false;
        var ly: i32 = 0;
        while (ly < 4) : (ly += 1) {
            var lz: i32 = 0;
            while (lz < 16) : (lz += 1) {
                var lx: i32 = 0;
                while (lx < 16) : (lx += 1) {
                    const v = f(ctx, lx, y0 + ly, lz);
                    if (v != 0) has_dmg = true;
                    vals[layerCell(lx, ly, lz)] = v;
                }
            }
        }
        if (!has_dmg) {
            try w.writeByte(1);
            try w.writeU16(0);
            continue;
        }
        try w.writeByte(0);
        var plane_buf: [cells_per_layer]u8 = undefined;
        for (0..2) |j| {
            packU16Plane(&vals, @intCast(j), &plane_buf);
            try w.writeBytes(&plane_buf);
        }
    }
}

/// NetPackageChunk body: overwrite=false + dataLen + stock Chunk.write payload.
/// First delivery must use overwrite=false so client allocates+reads during package.read.
pub fn buildNetPackageChunkNew(buf: []u8, opts: EncodeOpts) ![]u8 {
    // Reserve space: 1 + 4 + payload
    if (buf.len < 16) return error.Overflow;
    const payload = try encodeNetworkChunk(buf[5..], opts);
    var w: binary.Writer = .{ .buf = buf };
    try w.writeBool(false); // bOverwriteExisting = false (initial stream)
    try w.writeI32(@intCast(payload.len));
    // payload already written at buf[5..]; if writer started at 0 we need copy
    // encode wrote into buf[5..], so written starts at 5.
    const total = 5 + payload.len;
    if (total > buf.len) return error.Overflow;
    // Ensure bool/len prefix is at 0..5
    buf[0] = 0;
    std.mem.writeInt(i32, buf[1..5], @intCast(payload.len), .little);
    return buf[0..total];
}

