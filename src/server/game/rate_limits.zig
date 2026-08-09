//! C2S rate limits extracted from game.zig.
//! Inv/block token buckets, damage burst, chat gap.

const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const clock = @import("../../util/clock.zig");

pub fn takeInvToken(self: *Game, c: *Client) bool {
    const now = clock.monoNs();
    if (c.inv_refill_ns == 0) {
        c.inv_refill_ns = now;
        c.inv_tokens = self.inv_bucket_cap;
    }
    while (c.inv_tokens < self.inv_bucket_cap and now -% c.inv_refill_ns >= self.inv_refill_ns) {
        c.inv_tokens += 1;
        c.inv_refill_ns +%= self.inv_refill_ns;
    }
    if (c.inv_tokens == 0) return false;
    c.inv_tokens -= 1;
    return true;
}

pub fn takeBlockToken(self: *Game, c: *Client) bool {
    const now = clock.monoNs();
    if (c.block_refill_ns == 0) {
        c.block_refill_ns = now;
        c.block_tokens = self.block_bucket_cap;
    }
    while (c.block_tokens < self.block_bucket_cap and now -% c.block_refill_ns >= self.block_refill_ns) {
        c.block_tokens += 1;
        c.block_refill_ns +%= self.block_refill_ns;
    }
    if (c.block_tokens == 0) return false;
    c.block_tokens -= 1;
    return true;
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
