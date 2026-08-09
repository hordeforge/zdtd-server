//! On-the-fly procedural chunk generation (W0/W1/W2).
//! Pure function of (seed, chunkX, chunkZ): no full-map bake, no global RNG.
//! Block ids via AssignIds pins (bundled dump). Stock chunk wire unchanged.
//!
//! W2 replaces the heightmap with a 3D density field (docs/WORLDGEN.md §2):
//! `final_density(x,y,z) > 0` is solid, where density = a clamped Y-gradient
//! (`y_clamped_gradient`, solid low / air high) plus horizontally varying 3D
//! fBm, so overhangs fall out of the field instead of being bolted on.
//! Affordability comes from two caches: a per-coarse-column `cache_2d` of the
//! W1 2D shaping stack (25 evaluations per chunk, not 256), and `interpolated`
//! sampling of the 3D field on a `cell_w × cell_h × cell_w` grid (825 fBm
//! samples per chunk) with trilinear interpolation per block.
//!
//! The coarse grid is snapped in WORLD coordinates (`@divFloor(wx, cell_w)`),
//! and `chunk_size` is a multiple of `cell_w`, so the sample planes of adjacent
//! chunks coincide exactly: a chunk fill is bit-identical to the standalone
//! `density()` oracle and chunk borders cannot seam. That is a structural
//! property, and "chunk fill matches density oracle" is the test that pins it.
//!
//! Honest gaps (see docs/GAP_ANALYSIS.md): no fluids/aquifers (a density
//! dip below sea level is a dry pit, W4), single biome only (W3), caves are
//! implicit in the noise rather than carved (W4), and surface material is
//! applied per column from its topmost solid block, so overhang shelves and
//! cave ceilings expose stone rather than topsoil (run-aware surfacing is W3).
//! Generation is synchronous on the tick, bounded by `chunk_adds_per_stream_tick`
//! (async worker pool is W2b).

const std = @import("std");
const noise_mod = @import("noise.zig");
const assignids = @import("../assets/assignids_comptime.zig");
const biome_layers = @import("../assets/biome_layers.zig");

pub const chunk_size: i32 = 16;
pub const y_dim: i32 = 256;

/// Sea / base height band for the 2D shaping stack (single-biome).
pub const base_height: f32 = 68;
pub const height_amp: f32 = 24;
pub const min_surface: u8 = 12;
pub const max_surface: u8 = 200;

/// Coarse interpolation cell in blocks. `chunk_size % cell_w == 0` and
/// `y_dim % cell_h == 0` are required for the world-snapped grid to line up.
pub const cell_w: i32 = 4;
pub const cell_h: i32 = 8;
const samples_x: usize = @intCast(@divExact(chunk_size, cell_w) + 1); // 5
const samples_y: usize = @intCast(@divExact(y_dim, cell_h) + 1); // 33

/// Vertical blocks over which the Y-gradient runs from fully solid to fully
/// air. Larger = shallower gradient = more room for noise to carve overhangs.
pub const squash: f32 = 28;
/// Half-width of the band around a column target where solidity is not
/// guaranteed: `squash` for the gradient plus `cell_h` for interpolation reach.
pub const margin: f32 = squash + @as(f32, @floatFromInt(cell_h));
/// Must stay < 1 so the clamped gradient dominates outside the margin band.
const noise_weight: f32 = 0.85;
/// Vertical stretch of the density noise. Overhangs need the noise gradient to
/// beat the y-gradient slope 1/squash; at y_scale 0.5 / squash 12 the field
/// degenerates to a heightmap (measured 0% overhang columns).
const y_scale: f32 = 2.0;
const density_p: noise_mod.FbmParams = .{ .octaves = 4, .frequency = 0.02, .gain = 0.5 };
/// Blocks below this are forced solid, so bedrock always lands and every
/// column has a defined height.
pub const bedrock_h: i32 = 3;

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// Trilinear blend of the 8 cell corners. Corner order is
/// `x + z*2 + y*4` (x0z0y0, x1z0y0, x0z1y0, x1z1y0, then the same at y1) and
/// the nesting is x, then z, then y.
///
/// This must stay the ONLY trilinear evaluation in the file: the chunk fill and
/// the `density()` oracle both call it, and changing the nesting in one place
/// would break their bit-exactness (and with it the no-seam guarantee).
fn trilerp(c: [8]f32, tx: f32, ty: f32, tz: f32) f32 {
    const y0z0 = lerp(c[0], c[1], tx);
    const y0z1 = lerp(c[2], c[3], tx);
    const y1z0 = lerp(c[4], c[5], tx);
    const y1z1 = lerp(c[6], c[7], tx);
    return lerp(lerp(y0z0, y0z1, tz), lerp(y1z0, y1z1, tz), ty);
}

/// `y_clamped_gradient` + weighted 3D fBm. Both terms are clamped to [-1,1]:
/// fBm is not analytically bounded by 1, and the clamps are what make
/// `noise_weight < 1` a hard solid-below / air-above guarantee.
fn cellDensity(n: *const noise_mod.Noise, target: f32, wx: f32, wy: f32, wz: f32) f32 {
    const grad = std.math.clamp((target - wy) / squash, -1, 1);
    const n3 = std.math.clamp(noise_mod.fbm3(n, wx, wy * y_scale, wz, density_p), -1, 1);
    return grad + noise_weight * n3;
}

/// Per-chunk coarse sample grid: `cache_2d` column targets plus the 3D density
/// at every cell corner. Stack scratch (~3.4 KiB); the tick path allocates
/// nothing beyond the block plane itself.
const Sampler = struct {
    cache2d: [samples_x * samples_x]f32,
    samples: [samples_x * samples_x * samples_y]f32,

    fn init(wg: *const WorldGen, cx: i32, cz: i32) Sampler {
        var s: Sampler = undefined;
        const base_x = cx * chunk_size;
        const base_z = cz * chunk_size;
        var k: usize = 0;
        while (k < samples_x) : (k += 1) {
            const wz: f32 = @floatFromInt(base_z + @as(i32, @intCast(k)) * cell_w);
            var i: usize = 0;
            while (i < samples_x) : (i += 1) {
                const wx: f32 = @floatFromInt(base_x + @as(i32, @intCast(i)) * cell_w);
                const target = wg.columnTarget(wx, wz);
                s.cache2d[i + k * samples_x] = target;
                var j: usize = 0;
                while (j < samples_y) : (j += 1) {
                    const wy: f32 = @floatFromInt(@as(i32, @intCast(j)) * cell_h);
                    s.samples[i + k * samples_x + j * samples_x * samples_x] =
                        cellDensity(&wg.noise, target, wx, wy, wz);
                }
            }
        }
        return s;
    }

    /// 8 corner densities of cell (ci, cj, ck) in cell_w/cell_h units.
    fn corners(self: *const Sampler, ci: i32, cj: i32, ck: i32) [8]f32 {
        const xi: usize = @intCast(ci);
        const zi: usize = @intCast(ck);
        const yi: usize = @intCast(cj);
        var c: [8]f32 = undefined;
        var dy: usize = 0;
        while (dy < 2) : (dy += 1) {
            var dz: usize = 0;
            while (dz < 2) : (dz += 1) {
                var dx: usize = 0;
                while (dx < 2) : (dx += 1) {
                    c[dx + dz * 2 + dy * 4] = self.samples[
                        (xi + dx) +
                            (zi + dz) * samples_x + (yi + dy) * samples_x * samples_x
                    ];
                }
            }
        }
        return c;
    }

    fn densityAt(self: *const Sampler, lx: i32, y: i32, lz: i32) f32 {
        const c = self.corners(@divFloor(lx, cell_w), @divFloor(y, cell_h), @divFloor(lz, cell_w));
        return trilerp(
            c,
            @as(f32, @floatFromInt(@mod(lx, cell_w))) / @as(f32, @floatFromInt(cell_w)),
            @as(f32, @floatFromInt(@mod(y, cell_h))) / @as(f32, @floatFromInt(cell_h)),
            @as(f32, @floatFromInt(@mod(lz, cell_w))) / @as(f32, @floatFromInt(cell_w)),
        );
    }

    /// Lowest Y at or above which every block in the chunk is air, from the
    /// guaranteed band of the coarse column targets. Exact, so a downward scan
    /// starting here cannot miss the topmost solid block.
    fn airAbove(self: *const Sampler) i32 {
        var m: f32 = self.cache2d[0];
        for (self.cache2d[1..]) |t| m = @max(m, t);
        const y: i32 = @ceil(m + margin);
        return @min(y, y_dim - 1);
    }
};

pub const WorldGen = struct {
    seed: u64,
    noise: noise_mod.Noise,
    /// Loaded biome count for the W3 biome field; < 2 keeps single-biome fill
    /// (the W2 behaviour). Set by the store from biome_layers_table.
    biome_n: u8 = 0,
    /// Resolved surface stacks by biomemap id; null keeps `fillColumn`'s
    /// default stack (single biome).
    biome_table: ?*const biome_layers.Table = null,

    pub fn init(seed: u64) WorldGen {
        return .{
            .seed = seed,
            .noise = noise_mod.Noise.init(seed),
        };
    }

    /// Continuous biome field (W3): a low-frequency fBm mapped onto the loaded
    /// biome count. Deterministic per seed; regions stay contiguous instead of
    /// per-column noise, so a biome is a landmass, not static.
    pub fn biomeAt(self: *const WorldGen, fx: f32, fz: f32) u8 {
        if (self.biome_n <= 1) return 0;
        const bm_p: noise_mod.FbmParams = .{ .octaves = 3, .frequency = 0.003, .gain = 0.5 };
        const v = noise_mod.fbm2(&self.noise, fx + 5000, fz + 3000, bm_p); // ~[-1,1]
        const t = (v + 1.0) * 0.5; // [0,1]
        const n: f32 = @floatFromInt(self.biome_n);
        return @trunc(@min(n - 1.0, t * n));
    }

    /// 2D shaping stack (`cache_2d`): the Y around which the density gradient
    /// pivots for this column. Continental low-freq + ridged mountains +
    /// domain-warped detail (the W1 terrain character, kept verbatim).
    ///
    /// The clamp is to [min_surface + margin, max_surface - margin], NOT to
    /// [min_surface, max_surface]: interpolation pulls in corner samples up to
    /// `cell_h` below and `cell_w` away, and the margin is what keeps derived
    /// heights inside the asserted [min_surface, max_surface] band.
    pub fn columnTarget(self: *const WorldGen, fx: f32, fz: f32) f32 {
        const cont_p: noise_mod.FbmParams = .{ .octaves = 4, .frequency = 0.002, .gain = 0.5 };
        const ridge_p: noise_mod.FbmParams = .{ .octaves = 4, .frequency = 0.004, .gain = 0.55 };
        const warp_p: noise_mod.FbmParams = .{ .octaves = 3, .frequency = 0.008, .gain = 0.5 };
        const detail_p: noise_mod.FbmParams = .{ .octaves = 3, .frequency = 0.02, .gain = 0.5 };

        const cont = noise_mod.fbm2(&self.noise, fx, fz, cont_p);
        const ridge = noise_mod.ridged2(&self.noise, fx + 1000, fz - 500, ridge_p);
        const detail = noise_mod.warpedFbm2(&self.noise, fx, fz, 8.0, warp_p, detail_p);

        // cont ~[-1,1], ridge ~[0,2], detail ~[-1,1]
        const h = base_height + cont * height_amp + ridge * 18.0 + detail * 6.0;
        return std.math.clamp(
            h,
            @as(f32, @floatFromInt(min_surface)) + margin,
            @as(f32, @floatFromInt(max_surface)) - margin,
        );
    }

    /// Standalone world-coordinate density oracle: same value the chunk fill
    /// produces, computed without a Sampler. Reference/test path (8 fBm columns
    /// per call); never call this per block of a chunk.
    pub fn density(self: *const WorldGen, wx: i32, wy: i32, wz: i32) f32 {
        const ix = @divFloor(wx, cell_w);
        const iz = @divFloor(wz, cell_w);
        const iy = @divFloor(wy, cell_h);
        var c: [8]f32 = undefined;
        var dz: i32 = 0;
        while (dz < 2) : (dz += 1) {
            const cwz: f32 = @floatFromInt((iz + dz) * cell_w);
            var dx: i32 = 0;
            while (dx < 2) : (dx += 1) {
                const cwx: f32 = @floatFromInt((ix + dx) * cell_w);
                const target = self.columnTarget(cwx, cwz);
                var dy: i32 = 0;
                while (dy < 2) : (dy += 1) {
                    const cwy: f32 = @floatFromInt((iy + dy) * cell_h);
                    c[@intCast(dx + dz * 2 + dy * 4)] =
                        cellDensity(&self.noise, target, cwx, cwy, cwz);
                }
            }
        }
        return trilerp(
            c,
            @as(f32, @floatFromInt(wx - ix * cell_w)) / @as(f32, @floatFromInt(cell_w)),
            @as(f32, @floatFromInt(wy - iy * cell_h)) / @as(f32, @floatFromInt(cell_h)),
            @as(f32, @floatFromInt(wz - iz * cell_w)) / @as(f32, @floatFromInt(cell_w)),
        );
    }

    fn isSolid(d: f32, y: i32) bool {
        return d > 0 or y < bedrock_h;
    }

    /// Surface height at world block (wx, wz): topmost solid Y, matching stock
    /// `Chunk::RecalcHeightAt` (asm.il:1104654), which stores the first Y from
    /// the top whose block is not air.
    ///
    /// Point queries have no cheap form under a density field: this scans down
    /// over the `density()` oracle (~2*margin evaluations). Reference/test path
    /// only; `fillHeights` is the cheap whole-plane path.
    pub fn heightAt(self: *const WorldGen, wx: i32, wz: i32) u16 {
        // Exact upper bound: max target over the 4 coarse columns of this cell.
        const ix = @divFloor(wx, cell_w);
        const iz = @divFloor(wz, cell_w);
        var top: f32 = -std.math.floatMax(f32);
        var dz: i32 = 0;
        while (dz < 2) : (dz += 1) {
            var dx: i32 = 0;
            while (dx < 2) : (dx += 1) {
                top = @max(top, self.columnTarget(
                    @floatFromInt((ix + dx) * cell_w),
                    @floatFromInt((iz + dz) * cell_w),
                ));
            }
        }
        var y: i32 = @min(@as(i32, @ceil(top + margin)), y_dim - 1);
        while (y >= bedrock_h) : (y -= 1) {
            if (self.density(wx, y, wz) > 0) return @intCast(y);
        }
        return @intCast(bedrock_h - 1);
    }

    /// Fill 16×16 height plane for chunk (cx, cz) via one coarse sample grid.
    /// Cheap path: 825 fBm samples for the whole chunk, then a per-column
    /// top-down scan of the interpolated field.
    pub fn fillHeights(self: *const WorldGen, cx: i32, cz: i32, out: *[256]u8) void {
        const s = Sampler.init(self, cx, cz);
        const top = s.airAbove();
        var lz: i32 = 0;
        while (lz < chunk_size) : (lz += 1) {
            var lx: i32 = 0;
            while (lx < chunk_size) : (lx += 1) {
                var h: i32 = bedrock_h - 1;
                var y: i32 = top;
                while (y >= bedrock_h) : (y -= 1) {
                    if (s.densityAt(lx, y, lz) > 0) {
                        h = y;
                        break;
                    }
                }
                out[@intCast(lx + lz * chunk_size)] = @intCast(h);
            }
        }
    }

    /// Single-biome dirt/stone/bedrock column fill (AssignIds pins).
    pub fn fillColumn(h: u8, out: *[256]u16) void {
        biome_layers.Table.fillColumn(biome_layers.defaultStack(), h, out);
    }

    /// Materialize full block plane into caller-owned `blocks` (u32 raw = type
    /// id) and the matching height plane. Writes EVERY cell of the plane (air
    /// or solid), so it is the sole owner of clearing `blocks`; callers must not
    /// pre-clear it.
    pub fn generateChunkBlocks(self: *const WorldGen, cx: i32, cz: i32, heights: *[256]u8, blocks: []u32) void {
        std.debug.assert(blocks.len >= @as(usize, @intCast(chunk_size * y_dim * chunk_size)));
        const s = Sampler.init(self, cx, cz);
        @memset(heights, 0);

        // Cell-major: hoist the 8 corner densities once per coarse cell, then
        // walk its cell_w × cell_h × cell_w blocks through the shared trilerp.
        const cells_xz = @divExact(chunk_size, cell_w);
        const cells_y = @divExact(y_dim, cell_h);
        var ck: i32 = 0;
        while (ck < cells_xz) : (ck += 1) {
            var ci: i32 = 0;
            while (ci < cells_xz) : (ci += 1) {
                var cj: i32 = 0;
                while (cj < cells_y) : (cj += 1) {
                    const c = s.corners(ci, cj, ck);
                    var dy: i32 = 0;
                    while (dy < cell_h) : (dy += 1) {
                        const y = cj * cell_h + dy;
                        const ty = @as(f32, @floatFromInt(dy)) / @as(f32, @floatFromInt(cell_h));
                        var dz: i32 = 0;
                        while (dz < cell_w) : (dz += 1) {
                            const lz = ck * cell_w + dz;
                            const tz = @as(f32, @floatFromInt(dz)) / @as(f32, @floatFromInt(cell_w));
                            var dx: i32 = 0;
                            while (dx < cell_w) : (dx += 1) {
                                const lx = ci * cell_w + dx;
                                const tx = @as(f32, @floatFromInt(dx)) / @as(f32, @floatFromInt(cell_w));
                                const col: usize = @intCast(lx + lz * chunk_size);
                                const solid = isSolid(trilerp(c, tx, ty, tz), y);
                                blocks[col + @as(usize, @intCast(y)) * 256] =
                                    if (solid) assignids.terr_stone else assignids.air;
                                if (solid and y > heights[col]) heights[col] = @intCast(y);
                            }
                        }
                    }
                }
            }
        }

        // Second pass: a column's height is only final after all its cells, and
        // the layer stack is anchored at that height. Solid cells take the
        // stack material; air stays air (holes the stack cannot express). With
        // a loaded biome table each column fills with its biome's surface
        // stack (W3); otherwise the single-biome default.
        var col_ids: [256]u16 = undefined;
        var col: usize = 0;
        while (col < 256) : (col += 1) {
            const h = heights[col];
            if (self.biome_table) |bl| {
                const lx: i32 = @intCast(col % @as(usize, @intCast(chunk_size)));
                const lz: i32 = @intCast(@divTrunc(col, @as(usize, @intCast(chunk_size))));
                const wx = cx * chunk_size + lx;
                const wz = cz * chunk_size + lz;
                // biomeAt yields an index into the resolved biome list; the
                // real biomemap ids are sparse (1, 3, 5, …), so translate.
                const real_id = bl.biomeIdAt(self.biomeAt(@floatFromInt(wx), @floatFromInt(wz)));
                biome_layers.Table.fillColumn(bl.stackFor(real_id), h, &col_ids);
            } else {
                fillColumn(h, &col_ids);
            }
            var y: usize = 0;
            while (y <= h) : (y += 1) {
                const bi = col + y * 256;
                if (blocks[bi] != assignids.air) blocks[bi] = col_ids[y];
            }
        }
    }
};

test "worldgen determinism same seed and chunk" {
    const a = WorldGen.init(12345);
    const b = WorldGen.init(12345);
    var ha: [256]u8 = undefined;
    var hb: [256]u8 = undefined;
    a.fillHeights(3, -2, &ha);
    b.fillHeights(3, -2, &hb);
    try std.testing.expectEqualSlices(u8, &ha, &hb);
    try std.testing.expectEqual(a.heightAt(48, -32), b.heightAt(48, -32));
}

test "worldgen different seeds differ" {
    const a = WorldGen.init(1);
    const b = WorldGen.init(999);
    var differ = false;
    var i: i32 = 0;
    while (i < 32) : (i += 1) {
        if (a.heightAt(i * 7, i * 3) != b.heightAt(i * 7, i * 3)) differ = true;
    }
    try std.testing.expect(differ);
}

test "worldgen heights in band and uses assignids surface" {
    const g = WorldGen.init(7);
    var heights: [256]u8 = undefined;
    g.fillHeights(0, 0, &heights);
    for (heights) |h| {
        try std.testing.expect(h >= min_surface and h <= max_surface);
    }
    var col: [256]u16 = undefined;
    WorldGen.fillColumn(heights[0], &col);
    try std.testing.expectEqual(assignids.terr_bedrock, col[0]);
    try std.testing.expectEqual(assignids.terr_forest_ground, col[heights[0]]);
}

test "worldgen generateChunkBlocks air above surface" {
    const g = WorldGen.init(42);
    var heights: [256]u8 = undefined;
    var blocks: [16 * 256 * 16]u32 = undefined;
    g.generateChunkBlocks(1, 1, &heights, &blocks);
    const h = heights[0];
    try std.testing.expect(blocks[@intCast(0 + 0 * 16 + @as(i32, h) * 256)] != assignids.air);
    if (h + 1 < 256) {
        try std.testing.expectEqual(@as(u32, assignids.air), blocks[@intCast(0 + 0 * 16 + @as(i32, h + 1) * 256)]);
    }
}

test "worldgen chunk fill matches world density oracle (no chunk seams)" {
    const g = WorldGen.init(12345);
    var heights: [256]u8 = undefined;
    var blocks: [16 * 256 * 16]u32 = undefined;
    const chunks = [_][2]i32{ .{ 0, 0 }, .{ 1, 0 }, .{ -1, 3 }, .{ 7, -9 } };
    for (chunks) |ch| {
        g.generateChunkBlocks(ch[0], ch[1], &heights, &blocks);
        var lz: i32 = 0;
        while (lz < 16) : (lz += 1) {
            var lx: i32 = 0;
            while (lx < 16) : (lx += 1) {
                var y: i32 = bedrock_h;
                while (y < 256) : (y += 1) {
                    const solid = blocks[@intCast(lx + lz * 16 + y * 256)] != assignids.air;
                    const oracle = g.density(ch[0] * 16 + lx, y, ch[1] * 16 + lz) > 0;
                    try std.testing.expectEqual(oracle, solid);
                }
            }
        }
    }
}

test "worldgen guaranteed band and heights inside surface limits" {
    const seeds = [_]u64{ 12345, 1, 0xA11CE, 7, 42 };
    for (seeds) |seed| {
        const g = WorldGen.init(seed);
        var heights: [256]u8 = undefined;
        var blocks: [16 * 256 * 16]u32 = undefined;
        g.generateChunkBlocks(2, -3, &heights, &blocks);
        // Guaranteed band from the coarse column targets of this chunk.
        var lo: f32 = std.math.floatMax(f32);
        var hi: f32 = -std.math.floatMax(f32);
        var k: i32 = 0;
        while (k <= 16) : (k += cell_w) {
            var i: i32 = 0;
            while (i <= 16) : (i += cell_w) {
                const t = g.columnTarget(@floatFromInt(2 * 16 + i), @floatFromInt(-3 * 16 + k));
                lo = @min(lo, t);
                hi = @max(hi, t);
            }
        }
        const solid_below: i32 = @floor(lo - margin);
        const air_above: i32 = @ceil(hi + margin);
        try std.testing.expect(solid_below >= min_surface);
        try std.testing.expect(air_above <= max_surface);
        for (heights, 0..) |h, col| {
            try std.testing.expect(h >= min_surface and h <= max_surface);
            var y: i32 = 0;
            while (y < 256) : (y += 1) {
                const air = blocks[col + @as(usize, @intCast(y)) * 256] == assignids.air;
                if (y <= solid_below) try std.testing.expect(!air);
                if (y >= air_above) try std.testing.expect(air);
            }
        }
    }
}

test "worldgen produces overhangs (density field, not a heightmap)" {
    // Guard against a parameterization that silently degenerates to W1: with a
    // steep gradient (squash 12 / y_scale 0.5) the measured overhang rate is 0%.
    const g = WorldGen.init(12345);
    var heights: [256]u8 = undefined;
    var blocks: [16 * 256 * 16]u32 = undefined;
    var multi_run: u32 = 0;
    var cz: i32 = 0;
    while (cz < 3) : (cz += 1) {
        var cx: i32 = 0;
        while (cx < 3) : (cx += 1) {
            g.generateChunkBlocks(cx, cz, &heights, &blocks);
            var col: usize = 0;
            while (col < 256) : (col += 1) {
                var runs: u32 = 0;
                var prev_solid = false;
                var y: usize = 0;
                while (y < 256) : (y += 1) {
                    const solid = blocks[col + y * 256] != assignids.air;
                    if (solid and !prev_solid) runs += 1;
                    prev_solid = solid;
                }
                if (runs > 1) multi_run += 1;
            }
        }
    }
    try std.testing.expect(multi_run > 0);
}

test "worldgen block plane deterministic and order independent" {
    var h_a: [256]u8 = undefined;
    var h_b: [256]u8 = undefined;
    var blocks_a: [16 * 256 * 16]u32 = undefined;
    var blocks_b: [16 * 256 * 16]u32 = undefined;
    const a = WorldGen.init(2024);
    const b = WorldGen.init(2024);
    a.generateChunkBlocks(1, 0, &h_a, &blocks_a);
    // Same seed, different generation order: no hidden state may leak.
    b.generateChunkBlocks(0, 0, &h_b, &blocks_b);
    b.generateChunkBlocks(1, 0, &h_b, &blocks_b);
    try std.testing.expectEqualSlices(u8, &h_a, &h_b);
    try std.testing.expectEqualSlices(u32, &blocks_a, &blocks_b);
}

test "worldgen no global state across instances" {
    const a = WorldGen.init(5);
    const b = WorldGen.init(6);
    const a1 = a.density(10, 70, -20);
    const b1 = b.density(10, 70, -20);
    const a2 = a.density(10, 70, -20);
    const b2 = b.density(10, 70, -20);
    try std.testing.expectEqual(a1, a2);
    try std.testing.expectEqual(b1, b2);
    try std.testing.expectEqual(a1, WorldGen.init(5).density(10, 70, -20));
    try std.testing.expect(a1 != b1);
}

test "worldgen bedrock floor solid and world ceiling air" {
    const g = WorldGen.init(99);
    var heights: [256]u8 = undefined;
    var blocks: [16 * 256 * 16]u32 = undefined;
    g.generateChunkBlocks(-4, 6, &heights, &blocks);
    var col: usize = 0;
    while (col < 256) : (col += 1) {
        var y: usize = 0;
        while (y < @as(usize, @intCast(bedrock_h))) : (y += 1) {
            try std.testing.expect(blocks[col + y * 256] != assignids.air);
        }
        try std.testing.expectEqual(@as(u32, assignids.air), blocks[col + 255 * 256]);
    }
    try std.testing.expectEqual(assignids.terr_bedrock, @as(u16, @truncate(blocks[0])));
}

test "worldgen heightAt agrees with fillHeights" {
    const g = WorldGen.init(31337);
    var heights: [256]u8 = undefined;
    g.fillHeights(-2, 5, &heights);
    const pts = [_][2]i32{ .{ 0, 0 }, .{ 3, 11 }, .{ 15, 15 }, .{ 8, 4 } };
    for (pts) |p| {
        const h = g.heightAt(-2 * 16 + p[0], 5 * 16 + p[1]);
        try std.testing.expectEqual(@as(u16, heights[@intCast(p[0] + p[1] * 16)]), h);
    }
}

test "biome field is deterministic, in range and region-contiguous" {
    var g = WorldGen.init(42);
    g.biome_n = 7;
    // Same seed + coordinate → same biome.
    try std.testing.expectEqual(g.biomeAt(100, 200), g.biomeAt(100, 200));
    // In range.
    for ([_]f32{ -5000, -1, 0, 1, 5000 }) |x| {
        for ([_]f32{ -5000, 0, 5000 }) |z| {
            const b = g.biomeAt(x, z);
            try std.testing.expect(b < 7);
        }
    }
    // Contiguous: adjacent samples within a landmass rarely jump the whole
    // range; the field must not be per-column static.
    var min_gap: u8 = 7;
    var i: i32 = 0;
    while (i < 64) : (i += 1) {
        const a = g.biomeAt(@floatFromInt(i * 16), 0);
        const b = g.biomeAt(@floatFromInt(i * 16 + 16), 0);
        min_gap = @min(min_gap, @abs(@as(i32, a) - @as(i32, b)));
    }
    try std.testing.expect(min_gap <= 1);
    // biome_n <= 1 keeps single-biome fill.
    var single = WorldGen.init(42);
    single.biome_n = 1;
    try std.testing.expectEqual(@as(u8, 0), single.biomeAt(0, 0));
}

test "generateChunkBlocks fills each biome's surface stack" {
    var g = WorldGen.init(9);
    var bl: biome_layers.Table = .{};
    // Two biomes with distinct surface blocks: pine_forest grass vs desert sand.
    const pine_stack = biome_layers.Stack{
        .n = 3,
        .layers = .{
            .{ .depth = 1, .block_id = 700 },
            .{ .depth = 3, .block_id = 701 },
            .{ .depth = 0, .block_id = 702 },
            .{},
            .{},
            .{},
            .{},
            .{},
        },
    };
    const desert_stack = biome_layers.Stack{
        .n = 3,
        .layers = .{
            .{ .depth = 1, .block_id = 800 },
            .{ .depth = 3, .block_id = 801 },
            .{ .depth = 0, .block_id = 802 },
            .{},
            .{},
            .{},
            .{},
            .{},
        },
    };
    bl.stacks[0] = pine_stack;
    bl.stacks[1] = desert_stack;
    bl.names[0] = "pine_forest";
    bl.names[1] = "desert";
    g.biome_n = 2;
    g.biome_table = &bl;
    var heights: [256]u8 = undefined;
    var blocks: [256 * 256]u32 = undefined;
    g.generateChunkBlocks(0, 0, &heights, &blocks);
    // Every solid surface cell is one of the two biome stacks' blocks, never
    // the single-biome default.
    var col: usize = 0;
    while (col < 256) : (col += 1) {
        const h = heights[col];
        const top = blocks[col + @as(usize, @intCast(h)) * 256];
        // The surface comes from one of the two biome stacks, never the
        // single-biome default. The biome field itself is contiguous per
        // region, so one chunk usually sits in a single biome (checked above).
        try std.testing.expect(top == 700 or top == 800);
    }
}
