//! Ban / rate-limit helpers extracted from game.zig.

const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const clock = @import("../../util/clock.zig");

pub fn joinRateLimited(self: *Game, ip: u32) bool {
    if (ip == 0) return false;
    if (ip == 0x7f000001) return false;
    const now_ms: u64 = clock.monoNs() / 1_000_000;
    const gap_ms: u64 = self.join_rate_limit_ms;
    var i: usize = 0;
    while (i < self.join_ip_n) : (i += 1) {
        if (self.join_ip[i] != ip) continue;
        if (now_ms -% self.join_ip_ms[i] < gap_ms) return true;
        self.join_ip_ms[i] = now_ms;
        return false;
    }
    if (self.join_ip_n < self.join_ip.len) {
        self.join_ip[self.join_ip_n] = ip;
        self.join_ip_ms[self.join_ip_n] = now_ms;
        self.join_ip_n += 1;
    }
    return false;
}

pub fn isBanned(self: *const Game, ip: u32) bool {
    if (ip == 0) return false;
    var i: usize = 0;
    while (i < self.ban_n) : (i += 1) {
        if (self.ban_ip[i] == ip) return true;
    }
    return false;
}
