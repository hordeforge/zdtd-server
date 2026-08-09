//! C2S dispatch extracted verbatim from game.zig handlePackage.
//! Phase gate + c2s/* fanout; game.zig keeps a one-line forwarder.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const phase_gate = @import("../phase_gate.zig");
const c2s_join = @import("join.zig");
const c2s_move = @import("move.zig");
const c2s_inv = @import("inv.zig");
const c2s_blocks = @import("blocks.zig");
const c2s_quest = @import("quest.zig");
const c2s_misc = @import("misc.zig");

pub fn handlePackage(self: *Game, c: *Client, peer: *ln_peer.Peer, id: u16, body: []const u8) !void {
    if (id >= packages.default_mappings.len) {
        std.debug.print("zdtd: unmapped package local_id={d} package_id={d} body_len={d}\n", .{ peer.local_id, id, body.len });
        return;
    }
    const name = packages.default_mappings[id];
    {
        const phase = phase_gate.phaseOf(c.joined, c.entered);
        if (!phase_gate.allowed(phase, name)) {
            self.harness.counters.inc(.phase_rejects);
            self.noteEvidence(c, peer.local_id, c.entity_id, .phase, .hard, .none, 1, 0);
            const n = self.harness.counters.get(.phase_rejects);
            if (n == 1 or n % 100 == 0) {
                std.debug.print("zdtd: phase reject n={d} pkg={s} joined={} entered={} local_id={d}\n", .{ n, name, c.joined, c.entered, peer.local_id });
            }
            return;
        }
    }
    if (try c2s_join.handle(self, c, peer, name, body)) return;
    if (try c2s_move.handle(self, c, peer, name, body)) return;
    if (try c2s_inv.handle(self, c, peer, name, body)) return;
    if (try c2s_blocks.handle(self, c, peer, name, body)) return;
    if (try c2s_quest.handle(self, c, peer, name, body)) return;
    if (try c2s_misc.handle(self, c, peer, name, body)) return;
    self.harness.counters.inc(.c2s_unhandled);
    const un = self.harness.counters.get(.c2s_unhandled);
    if (un == 1 or un % 100 == 0) {
        std.debug.print("zdtd: unhandled C2S pkg={s} local_id={d} n={d}\n", .{ name, peer.local_id, un });
    }
}
