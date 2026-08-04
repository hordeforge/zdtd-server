//! On-the-fly procedural chunk generation (W0/W1 foundation).
//! Pure function of (seed, chunkX, chunkZ): no full-map bake, no global RNG.
//! Block ids via AssignIds pins (bundled dump). Stock chunk wire unchanged.

const std = @import("std");
const noise_mod = @import("noise.zig");
const assignids = @import("../assets/assignids_comptime.zig");
const biome_layers = @import("../assets/biome_layers.zig");

pub const chunk_size: i32 = 16;
pub const y_dim: i32 = 256;

/// Sea / base height band for simple heightmap gen (W0 single-biome).
pub const base_height: f32 = 68;
pub const height_amp: f32 = 24;
pub const min_surface: u8 = 12;
pub const max_surface: u8 = 200;

pub const WorldGen = struct {
    seed: u64,
    noise: noise_mod.Noise,

    pub fn init(seed: u64) WorldGen {
        return .{
            .seed = seed,
            .noise = noise_mod.Noise.init(seed),
        };
    }

    /// Surface height at world block (wx, wz). Deterministic.
    pub fn heightAt(self: *const WorldGen, wx: i32, wz: i32) u16 {
        const fx: f32 = @floatFromInt(wx);
        const fz: f32 = @floatFromInt(wz);
        // Continental low-freq + ridged mountains + domain-warped detail.
        const cont_p: noise_mod.FbmParams = .{ .octaves = 4, .frequency = 0.002, .gain = 0.5 };
        const ridge_p: noise_mod.FbmParams = .{ .octaves = 4, .frequency = 0.004, .gain = 0.55 };
        const warp_p: noise_mod.FbmParams = .{ .octaves = 3, .frequency = 0.008, .gain = 0.5 };
        const detail_p: noise_mod.FbmParams = .{ .octaves = 3, .frequency = 0.02, .gain = 0.5 };

        const cont = noise_mod.fbm2(&self.noise, fx, fz, cont_p);
        const ridge = noise_mod.ridged2(&self.noise, fx + 1000, fz - 500, ridge_p);
        const detail = noise_mod.warpedFbm2(&self.noise, fx, fz, 8.0, warp_p, detail_p);

        // cont ~[-1,1], ridge ~[0,2], detail ~[-1,1]
        const h = base_height + cont * height_amp + ridge * 18.0 + detail * 6.0;
        const hi: i32 = @intFromFloat(@round(h));
        if (hi < min_surface) return min_surface;
        if (hi > max_surface) return max_surface;
        return @intCast(hi);
    }

    /// Fill 16×16 height plane for chunk (cx, cz).
    /// Cells are independent; each heightAt keeps scalar fBm reduction order
    /// (seed-stable). Batching SIMD inside noise is deferred (docs/SIMD_REVIEW.md S04).
    pub fn fillHeights(self: *const WorldGen, cx: i32, cz: i32, out: *[256]u8) void {
        const base_x = cx * chunk_size;
        const base_z = cz * chunk_size;
        // Row-major fill; 256 samples. Noise is branchy (not lane-SIMD-safe yet).
        var i: usize = 0;
        while (i < 256) : (i += 1) {
            const lx: i32 = @intCast(i % 16);
            const lz: i32 = @intCast(i / 16);
            const h = self.heightAt(base_x + lx, base_z + lz);
            out[i] = if (h > 255) 255 else @intCast(h);
        }
    }

    /// Single-biome dirt/stone/bedrock column fill (AssignIds pins).
    pub fn fillColumn(h: u8, out: *[256]u16) void {
        biome_layers.Table.fillColumn(biome_layers.defaultStack(), h, out);
    }

    /// Materialize full block plane into caller-owned `blocks` (u32 raw = type id).
    pub fn generateChunkBlocks(self: *const WorldGen, cx: i32, cz: i32, heights: *[256]u8, blocks: []u32) void {
        std.debug.assert(blocks.len >= 16 * 256 * 16);
        self.fillHeights(cx, cz, heights);
        @memset(blocks, assignids.air);
        var col: [256]u16 = undefined;
        var lz: i32 = 0;
        while (lz < 16) : (lz += 1) {
            var lx: i32 = 0;
            while (lx < 16) : (lx += 1) {
                const h = heights[@intCast(lx + lz * 16)];
                WorldGen.fillColumn(h, &col);
                var y: i32 = 0;
                while (y <= h and y < y_dim) : (y += 1) {
                    blocks[@intCast(lx + lz * 16 + y * 256)] = col[@intCast(y)];
                }
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
