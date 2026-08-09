//! Stock subbiome noise for deco placement (GAP_ANALYSIS 18): a clean-room
//! port of `PerlinNoise` + `WorldBiomeProviderFromImage::GetSubBiomeIdxAt`, so
//! `decoSpeciesAt` resolves each cell the way stock's `decorateChunkRandom`
//! does instead of sampling only the biome's top-level `<decorations>` list.
//!
//! IL anchors (V3.1.0 b14, `../7dtd-research`):
//! - `PerlinNoise.ctor` (asm.il 2198696-2198801): 256 Box-Muller gradient
//!   triples from a `.NET Random` seeded with the ctor seed.
//! - `PerlinNoise.Noise` 2198860-2198966, `FBM` 2199260-2199321,
//!   `Lattice` 2199330-2199430, `Lerp` 2199447, `Smooth` ~2199450.
//! - `Extensions::GetStableHashCode` 2089124-2089211 (djb2 variant,
//!   hash2 * 0x5d588b65 combine).
//! - `WorldBiomeProviderFromImage::GetSubBiomeIdxAt` 1303381-1303482: per
//!   subbiome, `FBM(x+offset, z+offset, freq)` normalised `*0.5+0.5`, first
//!   subbiome whose `[min, max)` window contains the value wins; the noise is
//!   cached while `noiseFreq` and `noiseOffset` are unchanged. The `noiseGen`
//!   is seeded `GetStableHashCode(worldName)` (1301189).
//!
//! Fidelity note: stock embeds a fixed 256-byte `_perm` literal
//! (`<PrivateImplementationDetails> 04715D0F...`). zdtd uses the classic Ken
//! Perlin permutation table instead, so the banding is stock-shaped (same FBM
//! structure, same per-subbiome frequency/offset/min/max from biomes.xml) but
//! not byte-identical to the stock boundaries. Extracting the stock literal is
//! a `../7dtd-research` task; the residual is recorded in GAP_ANALYSIS 18.

const std = @import("std");

/// Unity `Extensions::GetStableHashCode` (djb2 variant). Operates on UTF-16
/// chars in stock; world names are ASCII, so bytes == chars.
pub fn stableHash(s: []const u8) i32 {
    var h1: i32 = 0x1505;
    var h2: i32 = 0x1505;
    var i: usize = 0;
    while (i < s.len and s[i] != 0) : (i += 2) {
        h1 = (h1 << 5) +% h1 ^ @as(i32, s[i]);
        if (i == s.len - 1) break;
        if (s[i + 1] == 0) break;
        h2 = (h2 << 5) +% h2 ^ @as(i32, s[i + 1]);
    }
    return h1 +% (h2 *% 0x5d588b65);
}

/// `.NET Framework Random` (GameRandom uses exactly this: MBIG=0x7FFFFFFF,
/// MSEED=0x09A4EC86, 56-entry SeedArray, Knuth subtraction shuffle; the
/// constants match the GameRandom class dump at asm.il 1010929).
pub const DotNetRandom = struct {
    const mbig: i32 = std.math.maxInt(i32);
    const mseed: i32 = 0x09A4EC86;
    seed_array: [56]i32 = undefined,
    inext: u8 = 0,
    inextp: u8 = 21,

    pub fn init(seed: i32) DotNetRandom {
        var r: DotNetRandom = .{};
        r.internalSetSeed(seed);
        return r;
    }

    fn internalSetSeed(self: *DotNetRandom, seed: i32) void {
        // The .NET Framework implementation is `unchecked`: the intermediate
        // values intentionally wrap (e.g. mj can go far below i32 min before
        // the +MBIG correction). Wrapping ops below match that exactly.
        const subtraction: i32 = if (seed == std.math.minInt(i32)) std.math.maxInt(i32) else @intCast(@abs(@as(i64, seed)));
        var mj: i32 = mseed -% subtraction;
        self.seed_array[55] = mj;
        var mk: i32 = 1;
        var i: usize = 1;
        while (i < 55) : (i += 1) {
            const ii: usize = (21 * i) % 55;
            self.seed_array[ii] = mk;
            mk = mj -% mk;
            if (mk < 0) mk +%= mbig;
            mj = self.seed_array[ii];
        }
        var k: usize = 1;
        while (k < 5) : (k += 1) {
            i = 1;
            while (i < 56) : (i += 1) {
                self.seed_array[i] -%= self.seed_array[1 + (i + 30) % 55];
                if (self.seed_array[i] < 0) self.seed_array[i] +%= mbig;
            }
        }
        self.inext = 0;
        self.inextp = 21;
    }

    fn internalSample(self: *DotNetRandom) i32 {
        var inext: usize = self.inext + 1;
        if (inext >= 56) inext = 1;
        var inextp: usize = self.inextp + 1;
        if (inextp >= 56) inextp = 1;
        var ret = self.seed_array[inext] -% self.seed_array[inextp];
        if (ret == mbig) ret -%= 1;
        if (ret < 0) ret +%= mbig;
        self.seed_array[inext] = ret;
        self.inext = @intCast(inext);
        self.inextp = @intCast(inextp);
        return ret;
    }

    pub fn nextDouble(self: *DotNetRandom) f64 {
        return @as(f64, @floatFromInt(self.internalSample())) * (1.0 / @as(f64, @floatFromInt(mbig)));
    }
};

/// Classic Ken Perlin permutation table (public domain). See the file-level
/// fidelity note for why this replaces the stock literal.
const ken_perlin_perm = [256]u8{
    151, 160, 137, 91,  90,  15,  131, 13,  201, 95,  96,  53,  194, 233, 7,   225,
    140, 36,  103, 30,  69,  142, 8,   99,  37,  240, 21,  10,  23,  190, 6,   148,
    247, 120, 234, 75,  0,   26,  197, 62,  94,  252, 219, 203, 117, 35,  11,  32,
    57,  177, 33,  88,  237, 149, 56,  87,  174, 20,  125, 136, 171, 168, 68,  175,
    74,  165, 71,  134, 139, 48,  27,  166, 77,  146, 158, 231, 83,  111, 229, 122,
    60,  211, 133, 230, 220, 105, 92,  41,  55,  46,  245, 40,  244, 102, 143, 54,
    65,  25,  63,  161, 1,   216, 80,  73,  209, 76,  132, 187, 208, 89,  18,  169,
    200, 196, 135, 130, 116, 188, 159, 86,  164, 100, 109, 198, 173, 186, 3,   64,
    52,  217, 226, 250, 124, 123, 5,   202, 38,  147, 118, 126, 255, 82,  85,  212,
    207, 206, 59,  227, 47,  16,  58,  17,  182, 189, 28,  42,  223, 183, 170, 213,
    119, 248, 152, 2,   44,  154, 163, 70,  221, 153, 101, 155, 167, 43,  172, 9,
    129, 22,  39,  253, 19,  98,  108, 110, 79,  113, 224, 232, 178, 185, 112, 104,
    218, 246, 97,  228, 251, 34,  242, 193, 238, 210, 144, 12,  191, 179, 162, 241,
    81,  51,  145, 235, 249, 14,  239, 107, 49,  192, 214, 31,  181, 199, 106, 157,
    184, 84,  204, 176, 115, 121, 50,  45,  127, 4,   150, 254, 138, 236, 205, 93,
    222, 114, 67,  29,  24,  72,  243, 141, 128, 195, 78,  66,  215, 61,  156, 180,
};

/// Stock `PerlinNoise`: 256 gradient triples from the seed via `.NET Random`,
/// 2D gradient noise clamped to [-1, 1] after a 1/0.55 scale.
pub const PerlinNoise = struct {
    gradients: [256 * 3]f64 = undefined,
    perm: [256]u8 = ken_perlin_perm,

    pub fn init(seed: i32) PerlinNoise {
        var p: PerlinNoise = .{};
        var rand = DotNetRandom.init(seed);
        var i: usize = 0;
        while (i < 256) : (i += 1) {
            const u = rand.nextDouble();
            const v = rand.nextDouble();
            const r = @sqrt(1.0 - u * u);
            const theta = 2.0 * std.math.pi * v;
            p.gradients[i * 3] = r * @cos(theta);
            p.gradients[i * 3 + 1] = r * @sin(theta);
            p.gradients[i * 3 + 2] = u;
        }
        return p;
    }

    fn smooth(x: f64) f64 {
        return x * x * (3.0 - 2.0 * x);
    }

    fn lerp(t: f64, v0: f64, v1: f64) f64 {
        return v0 + t * (v1 - v0);
    }

    /// 2D Lattice: `perm[(ix + perm[(iy + 0xe1) & 0xff]) & 0xff] * 3`, dotted
    /// with the (fx, fy) gradient. The 0xe1 addend is in the stock IL.
    fn lattice2(self: *const PerlinNoise, ix: i32, iy: i32, fx: f64, fy: f64) f64 {
        const a: usize = @intCast((iy + 0xe1) & 0xff);
        const b: usize = @intCast((ix + @as(i32, self.perm[a])) & 0xff);
        const idx = @as(usize, self.perm[b]) * 3;
        return self.gradients[idx] * fx + self.gradients[idx + 1] * fy;
    }

    /// 2D gradient noise (asm.il 2198860-2198966): four lattice corners,
    /// smoothstep interpolation, `*1.8181818...` clamped to [-1, 1].
    pub fn noise(self: *const PerlinNoise, x: f64, y: f64) f64 {
        const ix: i32 = @floor(x);
        const fx = x - @as(f64, @floatFromInt(ix));
        const iy: i32 = @floor(y);
        const fy = y - @as(f64, @floatFromInt(iy));
        const sx = smooth(fx);
        const sy = smooth(fy);
        const n00 = self.lattice2(ix, iy, fx, fy);
        const n10 = self.lattice2(ix + 1, iy, fx - 1.0, fy);
        const top = lerp(sx, n00, n10);
        const n01 = self.lattice2(ix, iy + 1, fx, fy - 1.0);
        const n11 = self.lattice2(ix + 1, iy + 1, fx - 1.0, fy - 1.0);
        const bot = lerp(sx, n01, n11);
        var out = lerp(sy, top, bot);
        out *= 1.8181818181818181;
        if (out <= -1.0) return -1.0;
        if (out >= 1.0) return 1.0;
        return out;
    }

    /// Two octaves: `Noise(x*f, y*f)` weighted 1.0 then 0.3, `f *= 2.1`.
    pub fn fbm(self: *const PerlinNoise, x: f64, y: f64, freq: f64) f64 {
        var total: f64 = 0;
        var amp: f64 = 1.0;
        var f: f64 = freq;
        var i: usize = 0;
        while (i < 2) : (i += 1) {
            total += self.noise(x * f, y * f) * amp;
            amp *= 0.3;
            f *= 2.1;
        }
        return total;
    }
};

/// One biome subbiome's noise window (from `<subbiome noise="freq, min, max"
/// noiseoffset="x, y">` in biomes.xml).
pub const SubBiome = struct {
    noise_freq: f32 = 0,
    noise_min: f32 = 0,
    noise_max: f32 = 0,
    noise_ox: f32 = 0,
    noise_oz: f32 = 0,
};

/// `WorldBiomeProviderFromImage::GetSubBiomeIdxAt` (asm.il 1303381-1303482):
/// the first subbiome whose `[min, max)` window contains
/// `FBM(x+ox, z+oz, freq)*0.5+0.5` wins; -1 means the biome's own list. The
/// noise value is recomputed only when a subbiome's freq or offset changes, as
/// stock caches it.
pub fn subBiomeIdx(noise: *const PerlinNoise, subs: anytype, x: i32, z: i32) i32 {
    // `subs` is a slice of any element type carrying the four noise fields
    // (biome_layers.SubBiome adds the deco set); comptime-resolved below.
    var last_freq: f64 = -3.4028234663852886e38; // float32 min widened, stock sentinel
    var noise_val: f64 = 0;
    var last_ox: f32 = 0;
    var last_oz: f32 = 0;
    var cached = false;
    for (subs, 0..) |sub, i| {
        const freq64: f64 = @floatCast(sub.noise_freq);
        if (!cached or last_freq != freq64 or last_ox != sub.noise_ox or last_oz != sub.noise_oz) {
            cached = true;
            last_freq = freq64;
            last_ox = sub.noise_ox;
            last_oz = sub.noise_oz;
            // Stock widens x/z + offset at float32 precision before FBM.
            const xf: f32 = @as(f32, @floatFromInt(x)) + sub.noise_ox;
            const zf: f32 = @as(f32, @floatFromInt(z)) + sub.noise_oz;
            noise_val = noise.fbm(@floatCast(xf), @floatCast(zf), freq64) * 0.5 + 0.5;
        }
        const min64: f64 = @floatCast(sub.noise_min);
        const max64: f64 = @floatCast(sub.noise_max);
        if (noise_val >= min64 and noise_val < max64) return @intCast(i);
    }
    return -1;
}

test "stableHash matches the Unity djb2 structure" {
    // Empty string: hash1 = hash2 = 0x1505.
    const empty: i32 = @as(i32, 0x1505) +% @as(i32, 0x1505) *% @as(i32, 0x5d588b65);
    try std.testing.expectEqual(empty, stableHash(""));
    // Deterministic and char-order sensitive.
    try std.testing.expect(stableHash("Navezgane") == stableHash("Navezgane"));
    try std.testing.expect(stableHash("Navezgane") != stableHash("NaveZgane"));
    // The 0xe1 lattice quirk must not crash on negative world coords.
    var p = PerlinNoise.init(1234);
    _ = p.noise(-100.5, -50.25);
}

test "DotNetRandom is deterministic and stable across instances" {
    var a = DotNetRandom.init(42);
    var b = DotNetRandom.init(42);
    var c = DotNetRandom.init(43);
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const da = a.nextDouble();
        try std.testing.expectEqual(da, b.nextDouble());
        try std.testing.expect(da >= 0 and da < 1);
        if (i == 0) try std.testing.expect(da != c.nextDouble());
    }
}

test "PerlinNoise is smooth, bounded and seed-dependent" {
    var p = PerlinNoise.init(7);
    // Value range [-1, 1] at a few sample points.
    var x: f64 = -50;
    while (x < 50) : (x += 7.3) {
        const v = p.noise(x, x * 0.5);
        try std.testing.expect(v >= -1.0 and v <= 1.0);
    }
    // Adjacent cells differ smoothly (not random noise per cell).
    const v1 = p.noise(10.0, 10.0);
    const v2 = p.noise(10.1, 10.0);
    try std.testing.expect(@abs(v1 - v2) < 0.5);
    // Different seed -> different field (compare several points; a single
    // cell could coincide by chance).
    var q = PerlinNoise.init(8);
    var differs = false;
    var sx: f64 = -20;
    while (sx < 20 and !differs) : (sx += 3.7) {
        if (p.noise(sx, sx * 0.3) != q.noise(sx, sx * 0.3)) differs = true;
    }
    try std.testing.expect(differs);
}

test "subBiomeIdx resolves the stock noise windows" {
    // pine_forest's actual subbiome windows (stock biomes.xml).
    const subs = [_]SubBiome{
        .{ .noise_freq = 0.0095, .noise_min = 0, .noise_max = 0.21 },
        .{ .noise_freq = 0.072, .noise_min = 0, .noise_max = 0.29 },
        .{ .noise_freq = 0.041, .noise_min = 0, .noise_max = 0.18, .noise_ox = 1000, .noise_oz = 111 },
    };
    var p = PerlinNoise.init(stableHash("Navezgane"));
    // Deterministic per cell.
    var x: i32 = 0;
    var hits: [4]u32 = .{0} ** 4;
    while (x < 500) : (x += 1) {
        const idx = subBiomeIdx(&p, &subs, x, @divTrunc(x, 2));
        try std.testing.expect(idx >= -1 and idx < 3);
        hits[@intCast(idx + 1)] += 1;
    }
    // The noise windows cover a large share of cells (pine_forest subs are the
    // dense tree bands; GAP 18's whole point).
    const sub_share = @as(f64, @floatFromInt(hits[1] + hits[2] + hits[3])) /
        @as(f64, @floatFromInt(hits[0] + hits[1] + hits[2] + hits[3]));
    try std.testing.expect(sub_share > 0.2);
    // Determinism across instances with the same seed.
    var p2 = PerlinNoise.init(stableHash("Navezgane"));
    try std.testing.expectEqual(subBiomeIdx(&p, &subs, 123, 456), subBiomeIdx(&p2, &subs, 123, 456));
    // Empty list -> -1.
    try std.testing.expectEqual(@as(i32, -1), subBiomeIdx(&p, &.{}, 1, 1));
}
