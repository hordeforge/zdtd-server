//! C2S admin arms: console command, editor volume drop.
//!
//! Split out of c2s/misc.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");

/// True when `name` is an admin package and was handled.
pub fn handleAdmin(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (std.mem.eql(u8, name, "NetPackageConsoleCmdServer")) {
        self.handleConsoleCmd(peer, c, body) catch |err| {
            std.debug.print(
                "zdtd: console cmd failed slot={d}: {s}\n",
                .{ c.slot, @errorName(err) },
            );
        };
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageEditorAddVolumeFromClient")) {
        return true;
    }
    return false;
}
