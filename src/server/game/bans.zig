//! Ban / rate-limit helpers extracted from game.zig.

const game_mod = @import("../game.zig");
const Game = game_mod.Game;

pub fn isBanned(self: *const Game, ip: u32) bool {
    if (ip == 0) return false;
    var i: usize = 0;
    while (i < self.ban_n) : (i += 1) {
        if (self.ban_ip[i] == ip) return true;
    }
    return false;
}
