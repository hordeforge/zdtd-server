//! C2S rate limits extracted from game.zig.
//! Inv/block token buckets, damage burst, chat gap.

const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const clock = @import("../../util/clock.zig");

fn takeToken(tokens: *u8, refill_ns: *u64, cap: u8, refill_period_ns: u64) bool {
    const now = clock.monoNs();
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
