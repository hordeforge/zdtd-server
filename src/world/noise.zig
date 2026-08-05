//! OpenSimplex2-family gradient noise (clean-room) + fBm / ridged / domain warp.
//! Pure functions of (seed, coords): no global RNG. Same seed+coords always match.

const std = @import("std");

/// Seeded noise state: perm table derived once from seed via splitmix64.
pub const Noise = struct {
    perm: [256]u8,
    seed: u64,

    pub fn init(seed: u64) Noise {
        var n: Noise = .{ .perm = undefined, .seed = seed };
        var i: usize = 0;
        while (i < 256) : (i += 1) n.perm[i] = @truncate(i);
        // Fisher-Yates with splitmix stream (deterministic).
        var s = seed;
        i = 255;
        while (i > 0) : (i -= 1) {
            s = splitmix64(s);
            const j: usize = @intCast(s % (i + 1));
            const tmp = n.perm[i];
            n.perm[i] = n.perm[j];
            n.perm[j] = tmp;
        }
        return n;
    }

    fn grad2(self: *const Noise, ix: i32, iy: i32) [2]f32 {
        // 8 gradients on the unit circle (OpenSimplex-style discrete set).
        const h = self.hash2(ix, iy) & 7;
        const grads = [_][2]f32{
            .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 },  .{ 0, -1 },
            .{ 1, 1 }, .{ -1, 1 }, .{ 1, -1 }, .{ -1, -1 },
        };
        const g = grads[h];
        // Normalize diagonals roughly.
        if (h >= 4) {
            const inv: f32 = 0.70710678118;
            return .{ g[0] * inv, g[1] * inv };
        }
        return g;
    }

    fn grad3(self: *const Noise, ix: i32, iy: i32, iz: i32) [3]f32 {
        const h = self.hash3(ix, iy, iz) & 15;
        // 12 mid-edge cube gradients + 4 extras (classic gradient noise set).
        const gx: f32 = switch (h & 3) {
            0 => 1,
            1 => -1,
            2 => 0,
            else => 0,
        };
        const gy: f32 = switch (h & 3) {
            0, 1 => 0,
            2 => 1,
            else => -1,
        };
        const gz: f32 = if ((h & 8) == 0)
            (if ((h & 4) == 0) @as(f32, 1) else -1)
        else
            0;
        // When gz==0, use remaining axis from high bits.
        if (gz == 0) {
            const alt: f32 = if ((h & 4) == 0) 1 else -1;
            if ((h & 3) < 2) return .{ gx, alt, 0 };
            return .{ alt, gy, 0 };
        }
        return .{ gx, gy, gz };
    }

    fn hash2(self: *const Noise, x: i32, y: i32) u8 {
        const xi: u8 = @truncate(@as(u32, @bitCast(x)));
        const yi: u8 = @truncate(@as(u32, @bitCast(y)));
        return self.perm[@as(u8, @truncate(self.perm[xi] +% yi))];
    }

    fn hash3(self: *const Noise, x: i32, y: i32, z: i32) u8 {
        const xi: u8 = @truncate(@as(u32, @bitCast(x)));
        const yi: u8 = @truncate(@as(u32, @bitCast(y)));
        const zi: u8 = @truncate(@as(u32, @bitCast(z)));
        return self.perm[@as(u8, @truncate(self.perm[@as(u8, @truncate(self.perm[xi] +% yi))] +% zi))];
    }

    /// 2D OpenSimplex2-style gradient noise in roughly [-1, 1].
    pub fn noise2(self: *const Noise, x: f32, y: f32) f32 {
        // Simplex skew (2D).
        const f2: f32 = 0.5 * (std.math.sqrt(3.0) - 1.0);
        const g2: f32 = (3.0 - std.math.sqrt(3.0)) / 6.0;
        const s = (x + y) * f2;
        const i = @floor(x + s);
        const j = @floor(y + s);
        const t = (i + j) * g2;
        const x0 = x - (i - t);
        const y0 = y - (j - t);

        const i_off: f32, const j_off: f32 = if (x0 > y0) .{ 1, 0 } else .{ 0, 1 };
        const x1 = x0 - i_off + g2;
        const y1 = y0 - j_off + g2;
        const x2 = x0 - 1 + 2 * g2;
        const y2 = y0 - 1 + 2 * g2;

        const ii: i32 = @intFromFloat(i);
        const jj: i32 = @intFromFloat(j);

        var n: f32 = 0;
        n += contrib2(self, x0, y0, ii, jj);
        n += contrib2(self, x1, y1, ii + @as(i32, @intFromFloat(i_off)), jj + @as(i32, @intFromFloat(j_off)));
        n += contrib2(self, x2, y2, ii + 1, jj + 1);
        // Scale into ~[-1,1] (empirical for this kernel).
        return n * 70.0;
    }

    fn contrib2(self: *const Noise, dx: f32, dy: f32, ix: i32, iy: i32) f32 {
        var t = 0.5 - dx * dx - dy * dy;
        if (t < 0) return 0;
        t *= t;
        const g = self.grad2(ix, iy);
        return t * t * (g[0] * dx + g[1] * dy);
    }

    /// 3D gradient noise in roughly [-1, 1] (simplex lattice).
    pub fn noise3(self: *const Noise, x: f32, y: f32, z: f32) f32 {
        const f3: f32 = 1.0 / 3.0;
        const g3: f32 = 1.0 / 6.0;
        const s = (x + y + z) * f3;
        const i = @floor(x + s);
        const j = @floor(y + s);
        const k = @floor(z + s);
        const t = (i + j + k) * g3;
        const x0 = x - (i - t);
        const y0 = y - (j - t);
        const z0 = z - (k - t);

        var i_a: f32 = 0;
        var j_a: f32 = 0;
        var k_a: f32 = 0;
        var i_b: f32 = 0;
        var j_b: f32 = 0;
        var k_b: f32 = 0;
        if (x0 >= y0) {
            if (y0 >= z0) {
                i_a = 1;
                j_a = 0;
                k_a = 0;
                i_b = 1;
                j_b = 1;
                k_b = 0;
            } else if (x0 >= z0) {
                i_a = 1;
                j_a = 0;
                k_a = 0;
                i_b = 1;
                j_b = 0;
                k_b = 1;
            } else {
                i_a = 0;
                j_a = 0;
                k_a = 1;
                i_b = 1;
                j_b = 0;
                k_b = 1;
            }
        } else {
            if (y0 < z0) {
                i_a = 0;
                j_a = 0;
                k_a = 1;
                i_b = 0;
                j_b = 1;
                k_b = 1;
            } else if (x0 < z0) {
                i_a = 0;
                j_a = 1;
                k_a = 0;
                i_b = 0;
                j_b = 1;
                k_b = 1;
            } else {
                i_a = 0;
                j_a = 1;
                k_a = 0;
                i_b = 1;
                j_b = 1;
                k_b = 0;
            }
        }

        const x1 = x0 - i_a + g3;
        const y1 = y0 - j_a + g3;
        const z1 = z0 - k_a + g3;
        const x2 = x0 - i_b + 2 * g3;
        const y2 = y0 - j_b + 2 * g3;
        const z2 = z0 - k_b + 2 * g3;
        const x3 = x0 - 1 + 3 * g3;
        const y3 = y0 - 1 + 3 * g3;
        const z3 = z0 - 1 + 3 * g3;

        const ii: i32 = @intFromFloat(i);
        const jj: i32 = @intFromFloat(j);
        const kk: i32 = @intFromFloat(k);

        var n: f32 = 0;
        n += contrib3(self, x0, y0, z0, ii, jj, kk);
        n += contrib3(self, x1, y1, z1, ii + @as(i32, @intFromFloat(i_a)), jj + @as(i32, @intFromFloat(j_a)), kk + @as(i32, @intFromFloat(k_a)));
        n += contrib3(self, x2, y2, z2, ii + @as(i32, @intFromFloat(i_b)), jj + @as(i32, @intFromFloat(j_b)), kk + @as(i32, @intFromFloat(k_b)));
        n += contrib3(self, x3, y3, z3, ii + 1, jj + 1, kk + 1);
        return n * 32.0;
    }

    fn contrib3(self: *const Noise, dx: f32, dy: f32, dz: f32, ix: i32, iy: i32, iz: i32) f32 {
        var t = 0.6 - dx * dx - dy * dy - dz * dz;
        if (t < 0) return 0;
        t *= t;
        const g = self.grad3(ix, iy, iz);
        return t * t * (g[0] * dx + g[1] * dy + g[2] * dz);
    }
};

fn splitmix64(x: u64) u64 {
    var z = x +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

pub const FbmParams = struct {
    octaves: u32 = 5,
    lacunarity: f32 = 2.0,
    gain: f32 = 0.5,
    frequency: f32 = 1.0,
};

/// Fractal Brownian motion (sum of octaves). Output roughly in [-1, 1] when gain=0.5.
pub fn fbm2(n: *const Noise, x: f32, y: f32, p: FbmParams) f32 {
    var amp: f32 = 1;
    var freq = p.frequency;
    var sum: f32 = 0;
    var norm: f32 = 0;
    var o: u32 = 0;
    while (o < p.octaves) : (o += 1) {
        sum += n.noise2(x * freq, y * freq) * amp;
        norm += amp;
        amp *= p.gain;
        freq *= p.lacunarity;
    }
    if (norm == 0) return 0;
    return sum / norm;
}

/// 3D fBm. Exact mirror of `fbm2` (same octave loop, same `sum/norm`), so a
/// density field built on it stays a pure function of (seed, x, y, z).
pub fn fbm3(n: *const Noise, x: f32, y: f32, z: f32, p: FbmParams) f32 {
    var amp: f32 = 1;
    var freq = p.frequency;
    var sum: f32 = 0;
    var norm: f32 = 0;
    var o: u32 = 0;
    while (o < p.octaves) : (o += 1) {
        sum += n.noise3(x * freq, y * freq, z * freq) * amp;
        norm += amp;
        amp *= p.gain;
        freq *= p.lacunarity;
    }
    if (norm == 0) return 0;
    return sum / norm;
}

/// Ridged multifractal: `1 - abs(noise)` per octave (mountains). Output ~[0, 1].
pub fn ridged2(n: *const Noise, x: f32, y: f32, p: FbmParams) f32 {
    var amp: f32 = 1;
    var freq = p.frequency;
    var sum: f32 = 0;
    var weight: f32 = 1;
    var o: u32 = 0;
    while (o < p.octaves) : (o += 1) {
        var signal = 1.0 - @abs(n.noise2(x * freq, y * freq));
        signal *= signal;
        signal *= weight;
        weight = std.math.clamp(signal * 2.0, 0, 1);
        sum += signal * amp;
        amp *= p.gain;
        freq *= p.lacunarity;
    }
    return sum;
}

/// Domain warp: evaluate `f(p + amp * h(p))` where h is fBm displacement (Quilez-style).
pub fn domainWarp2(n: *const Noise, x: f32, y: f32, warp_amp: f32, warp_p: FbmParams) struct { x: f32, y: f32 } {
    // Offset the warp field so qx/qy are uncorrelated.
    const qx = fbm2(n, x, y, warp_p);
    const qy = fbm2(n, x + 5.2, y + 1.3, warp_p);
    return .{ .x = x + warp_amp * qx, .y = y + warp_amp * qy };
}

/// fBm after one domain-warp pass.
pub fn warpedFbm2(n: *const Noise, x: f32, y: f32, warp_amp: f32, warp_p: FbmParams, value_p: FbmParams) f32 {
    const w = domainWarp2(n, x, y, warp_amp, warp_p);
    return fbm2(n, w.x, w.y, value_p);
}

test "noise determinism same seed and coords" {
    const a = Noise.init(0xC0FFEE);
    const b = Noise.init(0xC0FFEE);
    try std.testing.expectEqual(a.noise2(1.25, -3.5), b.noise2(1.25, -3.5));
    try std.testing.expectEqual(a.noise3(0.1, 2.2, -4.4), b.noise3(0.1, 2.2, -4.4));
    const p: FbmParams = .{ .octaves = 4, .frequency = 0.01 };
    try std.testing.expectEqual(fbm2(&a, 100, 200, p), fbm2(&b, 100, 200, p));
    try std.testing.expectEqual(ridged2(&a, 50, 75, p), ridged2(&b, 50, 75, p));
    try std.testing.expectEqual(
        warpedFbm2(&a, 10, 20, 4.0, p, p),
        warpedFbm2(&b, 10, 20, 4.0, p, p),
    );
}

test "fbm3 determinism and finiteness" {
    const a = Noise.init(0xBEEF);
    const b = Noise.init(0xBEEF);
    const p: FbmParams = .{ .octaves = 4, .frequency = 0.02, .gain = 0.5 };
    var x: f32 = -40;
    while (x <= 40) : (x += 11.3) {
        var y: f32 = 0;
        while (y <= 256) : (y += 37) {
            const v = fbm3(&a, x, y, x * 0.5 - 7, p);
            try std.testing.expectEqual(v, fbm3(&b, x, y, x * 0.5 - 7, p));
            try std.testing.expect(std.math.isFinite(v));
            try std.testing.expect(@abs(v) < 2.5);
        }
    }
    // Zero octaves is defined (no NaN from an empty normalization).
    try std.testing.expectEqual(@as(f32, 0), fbm3(&a, 1, 2, 3, .{ .octaves = 0 }));
}

test "noise different seeds differ" {
    const a = Noise.init(1);
    const b = Noise.init(2);
    // Extremely unlikely equality across a few samples.
    var differ = false;
    const pts = [_][2]f32{ .{ 0, 0 }, .{ 1.5, 2.5 }, .{ -10, 30 }, .{ 100.25, -0.5 } };
    for (pts) |pt| {
        if (a.noise2(pt[0], pt[1]) != b.noise2(pt[0], pt[1])) differ = true;
    }
    try std.testing.expect(differ);
}

test "noise output finite and bounded" {
    const n = Noise.init(42);
    var x: f32 = -20;
    while (x <= 20) : (x += 3.7) {
        var y: f32 = -20;
        while (y <= 20) : (y += 4.1) {
            const v = n.noise2(x, y);
            try std.testing.expect(std.math.isFinite(v));
            try std.testing.expect(@abs(v) < 2.5);
            const f = fbm2(&n, x * 0.05, y * 0.05, .{});
            try std.testing.expect(std.math.isFinite(f));
            try std.testing.expect(@abs(f) <= 1.01);
            const r = ridged2(&n, x * 0.05, y * 0.05, .{});
            try std.testing.expect(std.math.isFinite(r));
            try std.testing.expect(r >= -0.01 and r < 3.0);
        }
    }
}

test "fbm no global state across instances" {
    const n1 = Noise.init(99);
    const n2 = Noise.init(99);
    // Interleave calls; results must match independent evaluation order.
    const v1a = n1.noise2(3, 4);
    const v2a = n2.noise2(7, 8);
    const v1b = n1.noise2(3, 4);
    const v2b = n2.noise2(7, 8);
    try std.testing.expectEqual(v1a, v1b);
    try std.testing.expectEqual(v2a, v2b);
    try std.testing.expectEqual(v1a, Noise.init(99).noise2(3, 4));
}
