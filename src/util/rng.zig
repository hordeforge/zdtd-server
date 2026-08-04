//! Seeded deterministic PRNG for sim paths (loot, AI wander, director picks).
//!
//! Single algorithm (xorshift32) so every call site that needs a stream shares
//! one well-tested step. Never use OS entropy or std.crypto.random on the sim
//! path: same seed + same call sequence → same outcomes (DST / replay).

const std = @import("std");

/// xorshift32 state. Zero is invalid as a stream; initFromNetId forces non-zero.
pub const XorShift32 = struct {
    state: u32 = 0,

    /// Seed from an explicit u32 (0 is rewritten to 1 so the stream is live).
    pub fn init(seed: u32) XorShift32 {
        return .{ .state = if (seed == 0) 1 else seed };
    }

    /// Fold a 64-bit run seed into the stream (DST harness / worldgen seed).
    pub fn initFromU64(seed: u64) XorShift32 {
        // SplitMix64 finalizer so high and low halves both affect the state.
        var z = seed +% 0x9E3779B97F4A7C15;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        z = z ^ (z >> 31);
        return init(@truncate(z));
    }

    /// Seed from a net entity id (wander streams differ per entity).
    pub fn initFromNetId(net_id: i32) XorShift32 {
        return init(if (net_id == 0) 1 else @bitCast(net_id));
    }

    /// Advance and return the new state (classic xorshift32).
    pub fn next(self: *XorShift32) u32 {
        self.state = xorshift32Step(self.state);
        return self.state;
    }

    /// Value in [0, bound) when bound > 0; else 0. Modulo reduction is biased
    /// unless `bound` divides the u32 range, so this is not for fair draws.
    pub fn nextBounded(self: *XorShift32, bound: u32) u32 {
        if (bound == 0) return 0;
        return self.next() % bound;
    }
};

/// Stateless one-shot step (call sites that store state in a component field).
pub fn xorshift32Step(state: u32) u32 {
    var r = if (state == 0) @as(u32, 1) else state;
    r ^= r << 13;
    r ^= r >> 17;
    r ^= r << 5;
    return r;
}

test "xorshift32 same seed same stream" {
    var a = XorShift32.init(42);
    var b = XorShift32.init(42);
    var i: u32 = 0;
    while (i < 32) : (i += 1) {
        try std.testing.expectEqual(a.next(), b.next());
    }
}

test "xorshift32 different seeds diverge" {
    var a = XorShift32.init(1);
    var b = XorShift32.init(2);
    try std.testing.expect(a.next() != b.next());
}

test "xorshift32Step matches struct next" {
    var r = XorShift32.init(99);
    const s1 = xorshift32Step(99);
    try std.testing.expectEqual(s1, r.next());
    const s2 = xorshift32Step(s1);
    try std.testing.expectEqual(s2, r.next());
}

test "zero seed is rewritten" {
    var r = XorShift32.init(0);
    try std.testing.expect(r.state != 0);
    _ = r.next();
}

test "initFromU64 same seed same stream" {
    var a = XorShift32.initFromU64(0xDEAD_BEEF_CAFE_BABE);
    var b = XorShift32.initFromU64(0xDEAD_BEEF_CAFE_BABE);
    try std.testing.expectEqual(a.next(), b.next());
    var c = XorShift32.initFromU64(1);
    var d = XorShift32.initFromU64(2);
    try std.testing.expect(c.next() != d.next());
}
