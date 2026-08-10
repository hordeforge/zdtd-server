//! Framed send helpers extracted from game.zig.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const wire_frame = @import("../../wire/frame.zig");
const clock = @import("../../util/clock.zig");

pub fn trySendCompressed(self: *Game, peer: *ln_peer.Peer, pkg_name: []const u8, body: []const u8) bool {
    const pkg_id = packages.idOf(pkg_name) orelse return false;
    var fr: wire_frame.DeflateFramer = undefined;
    fr.begin(&self.send_buf, &self.deflate_window, 0, pkg_id, body.len) catch return false;
    const w = fr.writer();
    w.writeAll(body) catch return false;
    const framed = fr.finish() catch return false;
    self.sendFramedReliable(peer, pkg_name, framed, game_mod.window_retry_budget_ns, false) catch return false;
    return true;
}

pub fn sendFramedReliable(self: *Game, peer: *ln_peer.Peer, pkg_name: []const u8, framed: []const u8, budget_ns: u64, critical: bool) anyerror!void {
    // One retry shape: the shared sendReliablePumped pump owns the
    // budget/deadline/sleep/resend rules. Only the join-critical deadline
    // arm differs and is shared across the whole enter bundle.
    var retry_budget = budget_ns;
    if (critical) {
        const now = clock.monoNs();
        if (peer.critical_budget_deadline_ns < now) peer.critical_budget_deadline_ns = now + budget_ns;
        retry_budget = @min(budget_ns, peer.critical_budget_deadline_ns -% now);
    }
    self.sendReliablePumped(peer, pkg_name, framed, retry_budget, 960, false) catch |err| switch (err) {
        error.WindowFull => {
            self.harness.counters.inc(.reliable_window_drops);
            const n = self.harness.counters.get(.reliable_window_drops);
            if (n == 1 or n % 100 == 0) {
                var ts: [19]u8 = undefined;
                std.debug.print("zdtd: {s} reliable window drop pkg={s} (framed) n={d}\n", .{ clock.wallStamp(&ts), pkg_name, n });
            }
            return error.WindowFull;
        },
        else => return err,
    };
}
