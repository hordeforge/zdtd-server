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

pub fn takeDamageToken(self: *Game, c: *Client) bool {
    const now = clock.monoNs();
    if (c.last_damage_ns != 0 and now -% c.last_damage_ns < self.min_damage_gap_ns) {
        if (c.damage_burst >= self.damage_burst_max) return false;
        c.damage_burst += 1;
    } else {
        c.damage_burst = 1;
    }
    c.last_damage_ns = now;
    return true;
}

pub fn acceptChatRate(self: *const Game, c: *Client) bool {
    const now = clock.monoNs();
    if (c.last_chat_ns != 0 and now -% c.last_chat_ns < self.min_chat_gap_ns) return false;
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
    // Drain it.
    var i: usize = 0;
    while (i < cap) : (i += 1) try std.testing.expect(takeTokenAt(t0, &tokens, &refill, cap, period));
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
