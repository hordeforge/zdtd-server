//! `GameRandom`: the generator stock draws every deterministic roll from, and
//! a faithful port of it. `GameRandom` (il/full-v3.2.0/_global/GameRandom.il.txt)
//! is the .NET Framework `System.Random` algorithm verbatim - the 56-entry
//! `SeedArray`, `MBIG` 2147483647, `MSEED` 161803398, `inext`/`inextp`
//! subtractive step, `Sample()` as `InternalSample() * 4.6566128752458E-10`
//! (IL=360) - which is what makes a per-position stream reproducible across the
//! dedicated server and a client with the same seed.
//!
//! Used by the blockplaceholders per-cell roll (`Utils::RandomFromSeedOnPos`
//! seeds one per cell, IL=2666) and available to any other path that has to
//! match a stock draw. The goldens in the test below come from Mono's
//! `System.Random`, i.e. the same algorithm, not from a re-derivation.

const std = @import("std");

pub const GameRandom = struct {
    /// `SeedArray` (ctor allocates 56, IL=5); index 0 is unused by the
    /// algorithm, which works 1..55.
    seed_array: [56]i32 = [_]i32{0} ** 56,
    inext: i32 = 0,
    inextp: i32 = 0,

    /// `GameRandom::MBIG` (2147483647) and `MSEED` (161803398).
    pub const mbig: i32 = 2147483647;
    pub const mseed: i32 = 161803398;
    /// `Sample()`'s `1.0 / MBIG` as the IL literal (4.6566128752458E-10).
    pub const sample_scale: f64 = 4.6566128752458e-10;

    pub fn init(seed: i32) GameRandom {
        var r: GameRandom = .{};
        r.setSeed(seed);
        return r;
    }

    /// `SetSeed` -> `InternalSetSeed` (IL=240).
    pub fn setSeed(self: *GameRandom, seed_in: i32) void {
        var seed = seed_in;
        const subtraction: i32 = if (seed == std.math.minInt(i32))
            mbig
        else
            @intCast(@abs(seed));
        var mj: i32 = mseed - subtraction;
        self.seed_array[55] = mj;
        var mk: i32 = 1;
        var i: i32 = 1;
        while (i < 55) : (i += 1) {
            const ii: usize = @intCast(@mod(21 * i, 55));
            self.seed_array[ii] = mk;
            mk = mj - mk;
            if (mk < 0) mk += mbig;
            mj = self.seed_array[ii];
        }
        var k: i32 = 1;
        while (k < 5) : (k += 1) {
            i = 1;
            while (i < 56) : (i += 1) {
                const j: usize = @intCast(1 + @mod(i + 30, 55));
                self.seed_array[@intCast(i)] -%= self.seed_array[j];
                if (self.seed_array[@intCast(i)] < 0) self.seed_array[@intCast(i)] += mbig;
            }
        }
        self.inext = 0;
        self.inextp = 21;
        seed = 1;
    }

    /// `InternalSample` (IL=362): the subtractive step, with the `== MBIG`
    /// decrement and the negative wrap stock carries over from `System.Random`.
    pub fn internalSample(self: *GameRandom) i32 {
        var loc_inext = self.inext;
        var loc_inextp = self.inextp;
        loc_inext += 1;
        if (loc_inext >= 56) loc_inext = 1;
        loc_inextp += 1;
        if (loc_inextp >= 56) loc_inextp = 1;
        var ret: i32 = self.seed_array[@intCast(loc_inext)] -% self.seed_array[@intCast(loc_inextp)];
        if (ret == mbig) ret -= 1;
        if (ret < 0) ret += mbig;
        self.seed_array[@intCast(loc_inext)] = ret;
        self.inext = loc_inext;
        self.inextp = loc_inextp;
        return ret;
    }

    /// `Sample()` (IL=360), `NextDouble`/`get_RandomDouble` (IL=29).
    pub fn sample(self: *GameRandom) f64 {
        return @as(f64, @floatFromInt(self.internalSample())) * sample_scale;
    }

    pub fn nextDouble(self: *GameRandom) f64 {
        return self.sample();
    }

    /// `get_RandomFloat` (IL=34): the double narrowed to f32.
    pub fn nextFloat(self: *GameRandom) f32 {
        return @floatCast(self.sample());
    }

    /// `Next()` (IL=483): the raw sample.
    pub fn next(self: *GameRandom) i32 {
        return self.internalSample();
    }

    /// `Next(Int32 maxValue)` (IL=551): `(int)(Sample() * maxValue)`.
    pub fn nextBelow(self: *GameRandom, max_value: i32) i32 {
        return @intFromFloat(self.sample() * @as(f64, @floatFromInt(max_value)));
    }

    /// `Next(Int32 minValue, Int32 maxValue)` (IL=512), including the
    /// large-range path for a span above int.MaxValue.
    pub fn nextRange(self: *GameRandom, min_value: i32, max_value: i32) i32 {
        const span: i64 = @as(i64, max_value) - @as(i64, min_value);
        if (span <= mbig) {
            return @as(i32, @intFromFloat(self.sample() * @as(f64, @floatFromInt(span)))) + min_value;
        }
        return @as(i32, @intFromFloat(self.getSampleForLargeRange() * @as(f64, @floatFromInt(span)))) + min_value;
    }

    /// `GetSampleForLargeRange` (IL=489).
    pub fn getSampleForLargeRange(self: *GameRandom) f64 {
        var s = self.internalSample();
        if (@mod(self.internalSample(), 2) == 0) s = -s;
        return (@as(f64, @floatFromInt(s)) + 2147483646.0) / 4294967293.0;
    }

    /// `RandomRange(Single _maxExclusive)` (IL=190).
    pub fn rangeFloat(self: *GameRandom, max_exclusive: f32) f32 {
        return @floatCast(self.nextDouble() * @as(f64, @floatFromInt(max_exclusive)));
    }

    /// `RandomRange(Single _min, Single _maxExclusive)` (IL=199).
    pub fn rangeFloatBetween(self: *GameRandom, min_value: f32, max_exclusive: f32) f32 {
        return @floatCast(self.nextDouble() * @as(f64, @floatFromInt(max_exclusive - min_value)) +
            @as(f64, @floatFromInt(min_value)));
    }

    /// `RandomRange(Int32 _maxExclusive)` / `(Int32 _min, Int32 _maxExclusive)`
    /// (IL=213/219).
    pub fn rangeInt(self: *GameRandom, max_exclusive: i32) i32 {
        return self.nextBelow(max_exclusive);
    }

    pub fn rangeIntBetween(self: *GameRandom, min_value: i32, max_exclusive: i32) i32 {
        return self.nextBelow(max_exclusive - min_value) + min_value;
    }
};

/// `Utils::RandomFromSeedOnPos(Int32 _x, Int32 _y, Int32 _z, Int32 _seed)`
/// (il/full-v3.2.0/_global/Utils.il.txt IL=2666): every per-position stream in
/// stock folds the coordinates into the seed this way.
pub fn seededOnPos(x: i32, y: i32, z: i32, seed: i32) GameRandom {
    const s: i32 = seed +% x +% (z << 14) +% (y << 24);
    return GameRandom.init(s);
}

test "GameRandom matches System.Random goldens" {
    // Generated from Mono's System.Random (the algorithm GameRandom ports):
    // five draws off one stream per seed, in this order.
    const Case = struct { seed: i32, next1: i32, next2: i32, below100: i32, range5_10: i32, dbl1: f64 };
    const cases = [_]Case{
        .{ .seed = 0, .next1 = 1559595546, .next2 = 1755192844, .below100 = 76, .range5_10 = 7, .dbl1 = 0.2060331540210327 },
        .{ .seed = 1, .next1 = 534011718, .next2 = 237820880, .below100 = 46, .range5_10 = 8, .dbl1 = 0.657518893786482 },
        .{ .seed = 42, .next1 = 1434747710, .next2 = 302596119, .below100 = 12, .range5_10 = 7, .dbl1 = 0.16843422416990353 },
        .{ .seed = -1, .next1 = 534011718, .next2 = 237820880, .below100 = 46, .range5_10 = 8, .dbl1 = 0.657518893786482 },
        .{ .seed = 1234, .next1 = 857019877, .next2 = 1923929452, .below100 = 31, .range5_10 = 9, .dbl1 = 0.33943602458547617 },
        .{ .seed = std.math.maxInt(i32), .next1 = 1559595546, .next2 = 1755192844, .below100 = 76, .range5_10 = 7, .dbl1 = 0.2060331540210327 },
        .{ .seed = std.math.minInt(i32), .next1 = 1559595546, .next2 = 1755192844, .below100 = 76, .range5_10 = 7, .dbl1 = 0.2060331540210327 },
        .{ .seed = 161803398, .next1 = 1639093931, .next2 = 386245568, .below100 = 78, .range5_10 = 5, .dbl1 = 0.048626574710303253 },
    };
    for (cases) |c| {
        var r = GameRandom.init(c.seed);
        try std.testing.expectEqual(c.next1, r.next());
        try std.testing.expectEqual(c.next2, r.next());
        try std.testing.expectEqual(c.below100, r.nextBelow(100));
        try std.testing.expectEqual(c.range5_10, r.nextRange(5, 10));
        try std.testing.expectApproxEqAbs(c.dbl1, r.nextDouble(), 1e-12);
    }
}

test "seededOnPos folds position and seed the way Utils does" {
    // The same cell and seed always give the same stream; a neighbour differs.
    var a = seededOnPos(10, 70, -3, 1234);
    var b = seededOnPos(10, 70, -3, 1234);
    var c = seededOnPos(11, 70, -3, 1234);
    try std.testing.expectEqual(a.next(), b.next());
    try std.testing.expect(a.next() != c.next());
    // The shift weights are stock's (z << 14, y << 24): seeding the same
    // number by hand gives the same stream.
    var a2 = seededOnPos(10, 70, -3, 1234);
    var direct = GameRandom.init(1234 + 10 + (-3 << 14) + (70 << 24));
    try std.testing.expectEqual(direct.next(), a2.next());
}
