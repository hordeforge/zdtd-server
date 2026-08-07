//! Stock `Chunk.write(PooledBinaryWriter, bNetwork=true)` encoder.
//! Derived on V3.0.1, verified against the V3.1.0 b14 client: the live join
//! streams these chunks and the client meshes them.
//! Used as NetPackageChunk payload so the stock client can Chunk.read without
//! client-side generation. See ../../../7dtd-research/docs/save-region.md and Chunk IL dumps.

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

const layers_n: usize = 64;

/// Full static water mass. WaterUtils.GetWaterLevel gates visible water at
/// mass > 195 and GetStableMassBelow clamps at 19500, so static lake cells
/// carry the full value (light-mesh-water.md section 4).
pub const water_mass_full: u16 = 19500;
const cells_per_layer: usize = 1024; // 16*16*4

/// Block rawData provider: (lx, y, lz) -> full BlockValue.rawData (type + rot + meta).
pub const BlockAtFn = *const fn (ctx: ?*anyopaque, lx: i32, y: i32, lz: i32) u32;

/// Texture provider: (lx, y, lz) -> stock int64 textureFull (0 = unpainted).
/// Only the low 48 bits (6 bytes) are wired (chunk textures channel bpv=6).
pub const TexAtFn = *const fn (ctx: ?*anyopaque, lx: i32, y: i32, lz: i32) u64;
/// Optional density override (TTS sbyte as u8). Null return → densityForBlock.
pub const DensAtFn = *const fn (ctx: ?*anyopaque, lx: i32, y: i32, lz: i32) ?u8;

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
    /// AssignIds water block id; 0 disables the water channel (all-zero).
    /// When set, cells whose block type is water carry water_mass_full.
    water_block_id: u16 = 0,
    /// Dense precomputed raw plane (65536 BlockValue cells, x + z*16 + y*256).
    /// encodeNetworkChunk fills it once and shares it with the block-layer loop
    /// and the density/water channels so blockAt is not re-invoked per channel.
    raws: ?*const [65536]u32 = null,
    /// Caller-owned scratch for `raws` (pre-allocated; no hot-path heap). Null
    /// disables the memoization: channels fall back to the block_at callback.
    raws_scratch: ?*[65536]u32 = null,
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

fn defaultBlockAt(heights: *const [256]u8, lx: i32, y: i32, lz: i32) u32 {
    if (y < 0 or y >= 256) return stock_air;
    const h = heights[@intCast(lx + lz * 16)];
    if (y > h) return stock_air;
    if (y == 0) return stock_terr_bedrock;
    if (y + 3 < h) return stock_terr_stone;
    if (y == h) return stock_terr_topsoil;
    if (y + 1 == h) return stock_terr_dirt;
    return stock_terr_dirt;
}

fn blockAt(opts: EncodeOpts, lx: i32, y: i32, lz: i32) u32 {
    if (opts.block_at) |f| return f(opts.block_ctx, lx, y, lz);
    return defaultBlockAt(opts.heights, lx, y, lz);
}

/// BlockValue at a cell: the precomputed dense plane when present (encodeNetworkChunk
/// fills it once per chunk), else the block_at callback. Hot stream path: the
/// density and water channels read the plane instead of re-invoking blockAt.
fn rawAt(opts: EncodeOpts, lx: i32, y: i32, lz: i32) u32 {
    if (opts.raws) |r| return r[@intCast(lx + lz * 16 + y * 256)];
    return blockAt(opts, lx, y, lz);
}

fn blockType(raw: u32) u16 {
    return @truncate(raw);
}

/// Layer cell index matching stock: x + z*16 + (y&3)*256 within a 4-high band.
fn layerCell(lx: i32, y_in_layer: i32, lz: i32) usize {
    return @intCast(lx + lz * 16 + y_in_layer * 256);
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
        if (@as(u16, @truncate(raws[i])) != stock_air) return true;
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
pub fn packUpper24(raws: []const u32, upper: []u8) void {
    std.debug.assert(upper.len >= raws.len * 3);
    // Strided store: scalar is clear and matches stock layout; N=1024 is fine.
    var cell: usize = 0;
    while (cell < raws.len) : (cell += 1) {
        const raw = raws[cell];
        upper[cell * 3 + 0] = @truncate(raw >> 8);
        upper[cell * 3 + 1] = @truncate(raw >> 16);
        upper[cell * 3 + 2] = @truncate(raw >> 24);
    }
}

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
/// Scalar equivalent: dens[i] = densityForBlock(@truncate(raws[i])).
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
        dens[i] = densityForBlock(@truncate(raws[i]));
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
        if (@as(u16, @truncate(raws[i])) == water_id) {
            vals[i] = water_mass_full;
            has_water = true;
        } else {
            vals[i] = 0;
        }
    }
    return has_water;
}

/// Write one same-value ChunkBlockChannel (all 64 layers null, sameValue filled).
fn writeChannelSame(w: *binary.Writer, bytes_per_val: usize, fill: []const u8) !void {
    // fill length must be bytes_per_val (one value repeated into sameValue slots by read path).
    // Encoder: presence bit 1 (null layer) + sameValue bytes per layer.
    var scratch: [256]u8 = undefined;
    var pos: usize = 0;
    var layer: usize = 0;
    while (layer < layers_n) : (layer += 1) {
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

    // Dense raw plane, filled once when the caller supplies scratch: the 64
    // block-layer bands, the density channel and the water channel all read the
    // same per-cell BlockValue, and re-invoking the block_at callback per
    // channel triples the lookup cost on the stream path. Without scratch the
    // channels fall back to the callback (tests and cold paths).
    var opts_memo = opts;
    if (opts.raws_scratch) |scratch| {
        var i: usize = 0;
        while (i < scratch.len) : (i += 1) {
            const lx: i32 = @intCast(i % 16);
            const lz: i32 = @intCast((i / 16) % 16);
            const y: i32 = @intCast(i / 256);
            scratch[i] = blockAt(opts, lx, y, lz);
        }
        opts_memo.raws = scratch;
    }

    // 64 block layers
    var layer_i: usize = 0;
    while (layer_i < layers_n) : (layer_i += 1) {
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

    // m_bTopSoilBroken: 32-byte bitfield (1 bit per XZ). IsTopSoil = bit clear.
    // Unbroken topsoil + MicroSplat uses cColSplatMap (0,0,0,0) and needs live splat
    // sampling; when that path is incomplete the whole floor renders black/grey clay.
    // Mark all broken so VoxelMeshTerrain uses Block.GetSideTextureId colors (288→dirt
    // etc from blocks.xml) instead of the empty splat sentinel.
    var topsoil: [32]u8 = .{0xFF} ** 32;
    try w.writeBytes(&topsoil);

    // biomes 256
    var biomes: [256]u8 = .{opts.biome} ** 256;
    try w.writeBytes(&biomes);

    // biome intensities: 1536 bytes = BiomeIntensity[256], 6 bytes each interleaved:
    // biomeId0..3, intensity0and1 (lo nibble=i0), intensity2and3
    // Default stock full single-biome: id0=biome, intensity0and1=0x0F (i0=1).
    var intensities: [1536]u8 = .{0} ** 1536;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const o = i * 6;
        intensities[o] = opts.biome;
        intensities[o + 4] = 0x0F;
    }
    try w.writeBytes(&intensities);

    try w.writeByte(opts.biome); // DominantBiome
    try w.writeByte(opts.biome); // AreaMasterDominantBiome

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
    try writeChannelSame(&w, 1, &[_]u8{0xFF});
    // damage bpv=2 same 0
    try writeChannelSame(&w, 2, &[_]u8{ 0, 0 });
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

    // bNetwork: write false instead of building insideDevices list? IL:
    // if (!bNetwork) write sleeper...; if (!bNetwork) write trigger...
    // wall volumes always
    // then if (bNetwork) Write(false) else new List... for something at IL_042B
    // IL_042B: ldarg.2 brfalse.s IL_0435
    // IL_042E: Write(false)  -- when bNetwork, write false then fall into insideDevices path?
    // Actually when bNetwork true: Write(false) then still builds insideDevices from list.
    // Looking again IL_042B-0435:
    //   if (bNetwork) Write(false);
    //   new List... (always)
    // insideDevices count as i16 then entries
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

fn writeDensityChannel(w: *binary.Writer, opts: EncodeOpts) !void {
    // ChunkBlockChannel bpv=1: per layer presence(1=null/sameValue, 0=full 1024).
    // Fast path: dense raw plane + no TTS dens_at → SIMD packDensityFromRaws.
    // dens_at or missing raws falls back to per-cell densityAt (scalar).
    var layer_i: usize = 0;
    while (layer_i < layers_n) : (layer_i += 1) {
        const y0: i32 = @intCast(layer_i * 4);
        var dens: [cells_per_layer]u8 = undefined;
        if (opts.dens_at == null and opts.raws != null) {
            const plane = opts.raws.?;
            const base: usize = @intCast(y0 * 256);
            packDensityFromRaws(plane[base..][0..cells_per_layer], &dens);
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
    while (band < layers_n) : (band += 1) {
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
    while (band < layers_n) : (band += 1) {
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
                            if (@as(u16, @truncate(raw)) == opts.water_block_id) {
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
        var j: u1 = 0;
        while (true) {
            packU16Plane(&vals, j, &plane_buf);
            try w.writeBytes(&plane_buf);
            if (j == 1) break;
            j = 1;
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

test "stock chunk encodes non-empty terrain" {
    var heights: [256]u8 = .{60} ** 256;
    var buf: [65536]u8 = undefined;
    const body = try buildNetPackageChunkNew(&buf, .{
        .cx = -18,
        .cz = 28,
        .heights = &heights,
    });
    try std.testing.expect(body.len > 100);
    try std.testing.expectEqual(@as(u8, 0), body[0]); // not overwrite
    const plen = std.mem.readInt(i32, body[1..5], .little);
    try std.testing.expectEqual(@as(i32, @intCast(body.len - 5)), plen);
    // payload starts with cx,cy,cz
    const cx = std.mem.readInt(i32, body[5..9], .little);
    try std.testing.expectEqual(@as(i32, -18), cx);
}

test "stock chunk empty sky is smaller" {
    var heights: [256]u8 = .{0} ** 256;
    var buf: [65536]u8 = undefined;
    const body = try buildNetPackageChunkNew(&buf, .{
        .cx = 0,
        .cz = 0,
        .heights = &heights,
    });
    // Only bedrock at y=0 so one layer present.
    try std.testing.expect(body.len < 8000);
}

test "stock chunk emits per-block textureFull for painted blocks" {
    // A painted woodShapes block (id 259, textureFull 0x61) must appear in the
    // texture channel as bytes 0x61,0,0,0,0,0 (low 6 bytes LE), not zero.
    const Ctx = struct {
        fn at(_: ?*anyopaque, _: i32, y: i32, _: i32) u32 {
            return if (y == 0) stock_terr_bedrock else if (y <= 60) 259 else stock_air;
        }
        fn tex(_: ?*anyopaque, _: i32, y: i32, _: i32) u64 {
            return if (y >= 1 and y <= 60) 0x61 else 0;
        }
    };
    var heights: [256]u8 = .{60} ** 256;
    var raw: [524288]u8 = undefined;
    const payload = try encodeNetworkChunk(&raw, .{
        .cx = 0,
        .cz = 0,
        .heights = &heights,
        .block_at = Ctx.at,
        .tex_at = Ctx.tex,
        .block_ctx = null,
    });
    // The wood value 0x61 must appear in the payload (texture channel), and a
    // chunk with no paint must not contain a spurious 0x61 texture band.
    var has_paint = false;
    for (payload) |b| {
        if (b == 0x61) has_paint = true;
    }
    try std.testing.expect(has_paint);

    const unpainted = try encodeNetworkChunk(&raw, .{
        .cx = 0,
        .cz = 0,
        .heights = &heights,
        .block_at = Ctx.at, // same blocks, no tex_at
        .block_ctx = null,
    });
    // Texture channel is all-zero: same-value bands write 6 zero bytes each.
    // (Can't assert 0x61 absent globally since block ids may coincide; assert the
    // painted encoding is strictly larger due to a non-uniform texture band.)
    try std.testing.expect(payload.len > unpainted.len);
}

test "stock chunk water channel carries full mass for water cells" {
    // A water block at (1,66,3) (band 16) must switch that band from the
    // same-value 3 bytes to presence 0 + two u16 byte-planes, with the full
    // static mass (19500 = 0x4C2C) at the water cell.
    const Ctx = struct {
        fn at(_: ?*anyopaque, lx: i32, y: i32, lz: i32) u32 {
            if (lx == 1 and y == 66 and lz == 3) return 240; // water
            if (y == 0) return stock_terr_bedrock;
            if (y <= 60) return 1; // stone
            return stock_air;
        }
    };
    var heights: [256]u8 = .{60} ** 256;
    var raw_w: [524288]u8 = undefined;
    var raw_d: [524288]u8 = undefined;
    const water = try encodeNetworkChunk(&raw_w, .{
        .cx = 0,
        .cz = 0,
        .heights = &heights,
        .block_at = Ctx.at,
        .block_ctx = null,
        .water_block_id = 240,
    });
    const dry = try encodeNetworkChunk(&raw_d, .{
        .cx = 0,
        .cz = 0,
        .heights = &heights,
        .block_at = Ctx.at,
        .block_ctx = null,
    });
    // One band (16) switches from 3 same-value bytes to 1 + 2*1024 full bytes
    // (a layer has cells_per_layer = 1024 cells; planes are 1024 bytes each).
    try std.testing.expectEqual(dry.len + 2046, water.len);
    // The dry water channel is 64 same-value layers of 3 bytes, preceded by the
    // identical prefix and followed by the 15-byte const tail.
    const wch = dry.len - 64 * 3 - 15;
    const band16 = wch + 16 * 3;
    try std.testing.expectEqual(@as(u8, 0), water[band16]); // presence: full
    const cell = layerCell(1, 2, 3);
    try std.testing.expectEqual(@as(u8, 0x2C), water[band16 + 1 + cell]); // lo plane
    try std.testing.expectEqual(@as(u8, 0x4C), water[band16 + 1 + 1024 + cell]); // hi plane
    // Bands 0..15 stay same-value 0.
    try std.testing.expectEqual(@as(u8, 1), water[wch + 15 * 3]);
}

test "stock chunk emits upper24 for construction ids >= 256" {
    // A block_at that returns a construction id (1000) at the surface must produce
    // the upper24 array so the client reconstructs id 1000, not 1000 & 0xFF = 232.
    const Ctx = struct {
        fn at(_: ?*anyopaque, _: i32, y: i32, _: i32) u32 {
            return if (y == 0) stock_terr_bedrock else if (y <= 60) 1000 else stock_air;
        }
    };
    var heights: [256]u8 = .{60} ** 256;
    var raw: [262144]u8 = undefined;
    const payload = try encodeNetworkChunk(&raw, .{
        .cx = 0,
        .cz = 0,
        .heights = &heights,
        .block_at = Ctx.at,
        .block_ctx = null,
    });
    // Reconstruct layer containing y=60 (layer 15): find lower byte 232 (=1000&0xFF)
    // paired with upper byte 3 (=1000>>8) somewhere. Simplest: the byte 0xE8 (232)
    // and 0x03 must both appear in the block-layer region.
    var has_low = false;
    var has_up = false;
    for (payload) |b| {
        if (b == 0xE8) has_low = true; // 1000 & 0xFF
        if (b == 0x03) has_up = true; //  1000 >> 8
    }
    try std.testing.expect(has_low and has_up);
}

test "stock chunk surface density mixed band has both values" {
    // Height 60 → layer 15 (y 60..63) is mixed solid/air; payload must exceed all-same path.
    var heights: [256]u8 = .{60} ** 256;
    var buf: [131072]u8 = undefined;
    const body = try buildNetPackageChunkNew(&buf, .{
        .cx = 0,
        .cz = 0,
        .heights = &heights,
        .biome = 3,
    });
    // All-same density path = 64*(1+1)=128 density bytes; mixed surface adds ~1024.
    try std.testing.expect(body.len > 1000);
    // BiomeIntensity interleaved: first column biomeId0=3, intensity0and1=0x0F
    // Find intensities after maps is brittle; spot-check encodeNetworkChunk maps instead.
    var raw: [131072]u8 = undefined;
    const payload = try encodeNetworkChunk(&raw, .{
        .cx = 1,
        .cz = 2,
        .heights = &heights,
        .biome = 7,
    });
    // Scan for intensity plane: after biomes (256 of biome) comes 1536 intensities.
    // Search 6-byte pattern 07 00 00 00 0F 00 repeated near mid-payload.
    var hits: usize = 0;
    var off: usize = 0;
    while (off + 6 <= payload.len) : (off += 1) {
        if (payload[off] == 7 and payload[off + 1] == 0 and payload[off + 2] == 0 and
            payload[off + 3] == 0 and payload[off + 4] == 0x0F and payload[off + 5] == 0)
        {
            hits += 1;
            off += 5;
        }
    }
    try std.testing.expect(hits >= 200); // ~256 columns
    // Density bytes: both terrain 0x80 and air 127 must appear (mixed surface).
    var has_t = false;
    var has_a = false;
    for (payload) |b| {
        if (b == density_terrain) has_t = true;
        if (b == density_air) has_a = true;
    }
    try std.testing.expect(has_t and has_a);
}

test "simd layerIsUniform and anyNonAir" {
    var u8s: [1024]u8 = .{7} ** 1024;
    try std.testing.expect(layerIsUniformU8(&u8s));
    u8s[1000] = 8;
    try std.testing.expect(!layerIsUniformU8(&u8s));

    var raws: [1024]u32 = .{stock_air} ** 1024;
    try std.testing.expect(!layerAnyNonAirU32(&raws));
    try std.testing.expect(layerIsUniformU32(&raws));
    raws[17] = stock_terr_dirt;
    try std.testing.expect(layerAnyNonAirU32(&raws));
    try std.testing.expect(!layerIsUniformU32(&raws));
    try std.testing.expect(!layerNeedsUpperU32(&raws));
    raws[17] = 1000;
    try std.testing.expect(layerNeedsUpperU32(&raws));
}

test "simd packLower and packTexturePlane match scalar" {
    var raws: [32]u32 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) raws[i] = @as(u32, @intCast(i * 17 + 0x01020300));
    var lower: [32]u8 = undefined;
    packLowerU8(&raws, &lower);
    i = 0;
    while (i < 32) : (i += 1) {
        try std.testing.expectEqual(@as(u8, @truncate(raws[i])), lower[i]);
    }
    var vals: [32]u64 = undefined;
    i = 0;
    while (i < 32) : (i += 1) vals[i] = @as(u64, i) * 0x010203040506 + 0x99;
    var plane: [32]u8 = undefined;
    packTexturePlane(&vals, 2, &plane);
    i = 0;
    while (i < 32) : (i += 1) {
        try std.testing.expectEqual(@as(u8, @truncate(vals[i] >> 16)), plane[i]);
    }
}

test "simd packDensityFromRaws matches densityForBlock" {
    // Mix: air, terrain band (1..239), construction id, high raw with rot bits.
    var raws: [1024]u32 = undefined;
    var i: usize = 0;
    while (i < 1024) : (i += 1) {
        raws[i] = switch (i % 7) {
            0 => @as(u32, stock_air),
            1 => @as(u32, stock_terr_dirt),
            2 => @as(u32, stock_terr_stone),
            3 => 259, // non-terrain shape
            4 => 1000, // construction
            5 => @as(u32, stock_terr_bedrock) | (@as(u32, 3) << 16), // terrain + meta
            else => @as(u32, 500) | (@as(u32, 1) << 24),
        };
    }
    var dens: [1024]u8 = undefined;
    packDensityFromRaws(&raws, &dens);
    i = 0;
    while (i < 1024) : (i += 1) {
        try std.testing.expectEqual(densityForBlock(@truncate(raws[i])), dens[i]);
    }
    // Tail length not a multiple of vector width.
    var short_raws: [11]u32 = .{ 0, 1, 100, 239, 240, 259, 1000, 0, 5, 300, 42 };
    var short_dens: [11]u8 = undefined;
    packDensityFromRaws(&short_raws, &short_dens);
    i = 0;
    while (i < 11) : (i += 1) {
        try std.testing.expectEqual(densityForBlock(@truncate(short_raws[i])), short_dens[i]);
    }
}

test "simd packU16Plane and fillWaterMassFromRaws match scalar" {
    var vals: [1024]u16 = undefined;
    var i: usize = 0;
    while (i < 1024) : (i += 1) vals[i] = @as(u16, @intCast((i * 37 + 0x4C2C) & 0xffff));
    var lo: [1024]u8 = undefined;
    var hi: [1024]u8 = undefined;
    packU16Plane(&vals, 0, &lo);
    packU16Plane(&vals, 1, &hi);
    i = 0;
    while (i < 1024) : (i += 1) {
        try std.testing.expectEqual(@as(u8, @truncate(vals[i])), lo[i]);
        try std.testing.expectEqual(@as(u8, @truncate(vals[i] >> 8)), hi[i]);
    }

    const water_id: u16 = 240;
    var raws: [1024]u32 = .{0} ** 1024;
    raws[0] = water_id;
    raws[17] = @as(u32, water_id) | (@as(u32, 2) << 16);
    raws[1000] = 1; // stone
    var mass: [1024]u16 = undefined;
    const has = fillWaterMassFromRaws(&raws, water_id, &mass);
    try std.testing.expect(has);
    try std.testing.expectEqual(water_mass_full, mass[0]);
    try std.testing.expectEqual(water_mass_full, mass[17]);
    try std.testing.expectEqual(@as(u16, 0), mass[1000]);
    try std.testing.expectEqual(@as(u16, 0), mass[1]);
    // No water cells.
    @memset(&raws, 1);
    try std.testing.expect(!fillWaterMassFromRaws(&raws, water_id, &mass));
    try std.testing.expectEqual(@as(u16, 0), mass[0]);
}

test "simd density channel with raws plane matches dens_at-less scalar encode" {
    // Full memoized raw plane: SIMD density path must match callback-only encode.
    var heights: [256]u8 = .{60} ** 256;
    var plane: [65536]u32 = undefined;
    var i: usize = 0;
    while (i < plane.len) : (i += 1) {
        const lx: i32 = @intCast(i % 16);
        const lz: i32 = @intCast((i / 16) % 16);
        const y: i32 = @intCast(i / 256);
        plane[i] = defaultBlockAt(&heights, lx, y, lz);
        // One non-terrain solid so density mix is not only terrain/air.
        if (y == 30 and lx == 2 and lz == 3) plane[i] = 259;
    }
    var buf_a: [131072]u8 = undefined;
    var buf_b: [131072]u8 = undefined;
    const with_plane = try encodeNetworkChunk(&buf_a, .{
        .cx = 0,
        .cz = 0,
        .heights = &heights,
        .raws = &plane,
    });
    const Ctx = struct {
        plane: *const [65536]u32,
        fn at(ctx: ?*anyopaque, lx: i32, y: i32, lz: i32) u32 {
            const self: *const @This() = @ptrCast(@alignCast(ctx.?));
            return self.plane[@intCast(lx + lz * 16 + y * 256)];
        }
    };
    var ctx: Ctx = .{ .plane = &plane };
    const via_cb = try encodeNetworkChunk(&buf_b, .{
        .cx = 0,
        .cz = 0,
        .heights = &heights,
        .block_at = Ctx.at,
        .block_ctx = &ctx,
    });
    try std.testing.expectEqualSlices(u8, via_cb, with_plane);
}

test "raws_scratch memo reaches density channel (SIMD path)" {
    // raws_scratch alone must fill opts_memo.raws so density/water see the plane.
    var heights: [256]u8 = .{55} ** 256;
    var scratch: [65536]u32 = undefined;
    var buf_scratch: [131072]u8 = undefined;
    var buf_raws: [131072]u8 = undefined;
    const via_scratch = try encodeNetworkChunk(&buf_scratch, .{
        .cx = 1,
        .cz = -2,
        .heights = &heights,
        .raws_scratch = &scratch,
    });
    // Same content as an explicit plane fill with defaultBlockAt.
    var plane: [65536]u32 = undefined;
    var i: usize = 0;
    while (i < plane.len) : (i += 1) {
        const lx: i32 = @intCast(i % 16);
        const lz: i32 = @intCast((i / 16) % 16);
        const y: i32 = @intCast(i / 256);
        plane[i] = defaultBlockAt(&heights, lx, y, lz);
    }
    const via_raws = try encodeNetworkChunk(&buf_raws, .{
        .cx = 1,
        .cz = -2,
        .heights = &heights,
        .raws = &plane,
    });
    try std.testing.expectEqualSlices(u8, via_raws, via_scratch);
    // Scratch must have been filled (not left untouched).
    try std.testing.expect(scratch[0] == stock_terr_bedrock);
    try std.testing.expect(scratch[55 * 256] != stock_air);
}

test "simd encode matches mixed height chunk length class" {
    // Regression: SIMD pack path still produces valid mixed density payload.
    var heights: [256]u8 = .{60} ** 256;
    var raw: [131072]u8 = undefined;
    const payload = try encodeNetworkChunk(&raw, .{
        .cx = 0,
        .cz = 0,
        .heights = &heights,
        .biome = 3,
    });
    try std.testing.expect(payload.len > 1000);
    var has_t = false;
    var has_a = false;
    for (payload) |b| {
        if (b == density_terrain) has_t = true;
        if (b == density_air) has_a = true;
    }
    try std.testing.expect(has_t and has_a);
}
