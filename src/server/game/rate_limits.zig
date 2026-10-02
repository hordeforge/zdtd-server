//! C2S rate limits extracted from game.zig.
//! Inv/block token buckets, damage burst, chat gap.

const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const clock = @import("../../util/clock.zig");

/// The bucket itself, with the clock passed in so the refill arithmetic is
/// testable without waiting on wall time.
fn takeTokenAt(now: u64, tokens: *u8, refill_ns: *u64, cap: u8, refill_period_ns: u64) bool {
    if (refill_ns.* == 0) {
        refill_ns.* = now;
        tokens.* = cap;
    }
    while (tokens.* < cap and now -% refill_ns.* >= refill_period_ns) {
        tokens.* += 1;
        refill_ns.* +%= refill_period_ns;
    }
    if (tokens.* == 0) return false;
    tokens.* -= 1;
    return true;
}

fn takeToken(tokens: *u8, refill_ns: *u64, cap: u8, refill_period_ns: u64) bool {
    return takeTokenAt(clock.monoNs(), tokens, refill_ns, cap, refill_period_ns);
}

pub fn takeInvToken(self: *Game, c: *Client) bool {
    return takeToken(&c.inv_tokens, &c.inv_refill_ns, self.inv_bucket_cap, self.inv_refill_ns);
}

pub fn takeBlockToken(self: *Game, c: *Client) bool {
    return takeToken(&c.block_tokens, &c.block_refill_ns, self.block_bucket_cap, self.block_refill_ns);
}

/// Pure burst rule behind `takeDamageToken`: claims closer together than
/// `gap_ns` may spend at most `burst_max` in a row, so a client cannot flood the
/// hottest untrusted input (rule 20). Split out so the rule is testable without
/// a Game.
pub fn damageBurstAllows(now: u64, last_ns: *u64, burst: *u8, gap_ns: u64, burst_max: u8) bool {
    if (last_ns.* != 0 and now < last_ns.*) {
        // A backwards clock (or a wrapped counter) spends the burst instead of
        // handing out a fresh one, and the high-water mark stays: overwriting it
        // with the older time would make the next legitimate claim look far in
        // the future and reopen the gap. Fail closed on the hottest untrusted
        // input.
        if (burst.* >= burst_max) return false;
        burst.* += 1;
        return true;
    }
    if (last_ns.* != 0 and now -% last_ns.* < gap_ns) {
        if (burst.* >= burst_max) return false;
        burst.* += 1;
    } else {
        burst.* = 1;
    }
    last_ns.* = now;
    return true;
}

pub fn takeDamageToken(self: *Game, c: *Client) bool {
    return damageBurstAllows(clock.monoNs(), &c.last_damage_ns, &c.damage_burst, self.min_damage_gap_ns, self.damage_burst_max);
}

pub fn acceptChatRate(self: *const Game, c: *Client) bool {
    const now = clock.monoNs();
    // A backwards or wrapped clock counts as inside the gap (same rule as the
    // damage burst): fail closed on a flood guard.
    if (c.last_chat_ns != 0 and (now < c.last_chat_ns or now -% c.last_chat_ns < self.min_chat_gap_ns)) return false;
    c.last_chat_ns = now;
    return true;
}

const std = @import("std");

test "a fresh bucket starts full and drains one token per call" {
    var tokens: u8 = 0;
    var refill: u64 = 0;
    const cap: u8 = 3;
    const period: u64 = 50_000_000;
    // First call seeds the bucket at cap, then spends one.
    try std.testing.expect(takeTokenAt(1_000, &tokens, &refill, cap, period));
    try std.testing.expectEqual(@as(u8, cap - 1), tokens);
    // Same instant: the rest of the cap is spendable, then it is empty.
    try std.testing.expect(takeTokenAt(1_000, &tokens, &refill, cap, period));
    try std.testing.expect(takeTokenAt(1_000, &tokens, &refill, cap, period));
    try std.testing.expectEqual(@as(u8, 0), tokens);
    try std.testing.expect(!takeTokenAt(1_000, &tokens, &refill, cap, period));
}

test "the bucket refills one token per period and never past the cap" {
    var tokens: u8 = 0;
    var refill: u64 = 0;
    const cap: u8 = 3;
    const period: u64 = 50_000_000;
    const t0: u64 = 1_000_000;
    for (0..cap) |_| try std.testing.expect(takeTokenAt(t0, &tokens, &refill, cap, period));
    try std.testing.expect(!takeTokenAt(t0, &tokens, &refill, cap, period));

    // Just short of a period: still empty.
    try std.testing.expect(!takeTokenAt(t0 + period - 1, &tokens, &refill, cap, period));
    // One period on: exactly one token, spent by this call, so the next fails.
    try std.testing.expect(takeTokenAt(t0 + period, &tokens, &refill, cap, period));
    try std.testing.expect(!takeTokenAt(t0 + period, &tokens, &refill, cap, period));

    // A long idle gap does not bank more than the cap: an idle client cannot
    // save up a burst larger than the bucket.
    try std.testing.expect(takeTokenAt(t0 + period * 1000, &tokens, &refill, cap, period));
    try std.testing.expectEqual(@as(u8, cap - 1), tokens);
}

test "a monotonic clock wrap does not hand out free tokens" {
    // monoNs is u64 and the refill arithmetic is wrapping (-%, +%), so the
    // bucket has to stay bounded across the wrap rather than refilling as if
    // an enormous interval had passed.
    var tokens: u8 = 0;
    var refill: u64 = 0;
    const cap: u8 = 2;
    const period: u64 = 50_000_000;
    const near_max: u64 = std.math.maxInt(u64) - period / 2;
    try std.testing.expect(takeTokenAt(near_max, &tokens, &refill, cap, period));
    try std.testing.expect(takeTokenAt(near_max, &tokens, &refill, cap, period));
    try std.testing.expect(!takeTokenAt(near_max, &tokens, &refill, cap, period));
    // Wrapped past zero by one period: one token back, not a full bucket.
    const wrapped: u64 = near_max +% period;
    try std.testing.expect(takeTokenAt(wrapped, &tokens, &refill, cap, period));
    try std.testing.expectEqual(@as(u8, 0), tokens);
}

test "the damage claim limiter allows a burst and then throttles" {
    // Rule 20 on the hottest untrusted input. Inside the minimum gap the client
    // may spend a small burst, then every further claim is refused; a claim after
    // the gap starts a fresh burst.
    var last: u64 = 0;
    var burst: u8 = 0;
    const gap: u64 = 100;
    const max: u8 = 3;
    try std.testing.expect(damageBurstAllows(1000, &last, &burst, gap, max)); // first, burst = 1
    try std.testing.expect(damageBurstAllows(1050, &last, &burst, gap, max)); // burst = 2
    try std.testing.expect(damageBurstAllows(1060, &last, &burst, gap, max)); // burst = 3, the cap
    try std.testing.expect(!damageBurstAllows(1070, &last, &burst, gap, max));
    try std.testing.expect(!damageBurstAllows(1080, &last, &burst, gap, max));
    try std.testing.expect(!damageBurstAllows(1090, &last, &burst, gap, max));
    // Past the gap: fresh burst, allowed again.
    try std.testing.expect(damageBurstAllows(2000, &last, &burst, gap, max));
    try std.testing.expectEqual(@as(u8, 1), burst);
    // A clock running backwards must not hand out a free burst.
    last = 5000;
    burst = 3;
    try std.testing.expect(!damageBurstAllows(10, &last, &burst, gap, max));
}

test "a backwards clock does not reopen the damage gap" {
    // The guard is a "has enough time passed?" check. `now -% last` alone reads a
    // backwards jump as a huge elapsed time, so the guard would allow the very
    // flood it exists to stop. The comparison is `now < last` first, which is why
    // the second claim here is refused even though the burst is not spent.
    var last: u64 = 0;
    var burst: u8 = 0;
    try std.testing.expect(damageBurstAllows(1000, &last, &burst, 500, 4));
    try std.testing.expectEqual(@as(u8, 1), burst);
    // Backwards: allowed once (it spends the burst) but the high-water mark is
    // not moved back, so the next claim still has to pay.
    try std.testing.expect(damageBurstAllows(400, &last, &burst, 500, 4));
    try std.testing.expectEqual(@as(u8, 2), burst);
    try std.testing.expectEqual(@as(u64, 1000), last);
    try std.testing.expect(damageBurstAllows(300, &last, &burst, 500, 4));
    try std.testing.expect(damageBurstAllows(200, &last, &burst, 500, 4));
    try std.testing.expect(!damageBurstAllows(100, &last, &burst, 500, 4));
    // A forward claim past the gap starts fresh again.
    try std.testing.expect(damageBurstAllows(1000 + 501, &last, &burst, 500, 4));
    try std.testing.expectEqual(@as(u8, 1), burst);
}
