//! Framed send helpers extracted from game.zig.
//! Delivery classifiers live in delivery_policy.zig (no import of net.zig).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const wire_frame = @import("../../wire/frame.zig");
const clock = @import("../../util/clock.zig");
const delivery_policy = @import("delivery_policy.zig");

pub fn trySendCompressed(self: *Game, peer: *ln_peer.Peer, pkg_name: []const u8, body: []const u8) bool {
    return sendCompressed(self, peer, pkg_name, body, game_mod.window_retry_budget_ns, false) catch false;
}

/// Returns false only when compression cannot produce a complete stock frame,
/// allowing sendGameBudget to fall through to the uncompressed encoder. Send
/// errors propagate so a partially transmitted fragmented frame is never
/// followed by a second encoding of the same package.
pub fn sendCompressed(self: *Game, peer: *ln_peer.Peer, pkg_name: []const u8, body: []const u8, budget_ns: u64, critical: bool) !bool {
    const pkg_id = packages.idOf(pkg_name) orelse return false;
    var fr: wire_frame.DeflateFramer = undefined;
    fr.begin(&self.send_buf, &self.deflate_window, packages.channelFor(pkg_name), pkg_id, body.len) catch return false;
    const w = fr.writer();
    w.writeAll(body) catch return false;
    const framed = fr.finish() catch return false;
    try self.sendFramedReliable(peer, pkg_name, framed, budget_ns, critical);
    return true;
}

pub fn sendFramedReliable(self: *Game, peer: *ln_peer.Peer, pkg_name: []const u8, framed: []const u8, budget_ns: u64, critical: bool) anyerror!void {
    // One retry shape: the shared sendReliablePumped pump owns the
    // budget/deadline/sleep/resend rules. Only the join-critical deadline
    // arm differs and is shared across the whole enter bundle.
    const owns_critical_budget = critical and peer.armCriticalBudget(budget_ns);
    defer peer.releaseCriticalBudget(owns_critical_budget);
    const retry_budget = if (critical) peer.criticalBudgetRemaining(budget_ns) else budget_ns;
    // Same attempt ladder as sendGameBudget: one table in delivery_policy.
    const droppable = !critical and delivery_policy.isDroppablePackage(pkg_name);
    const max_attempts = delivery_policy.maxAttemptsFor(pkg_name, droppable);
    self.sendReliablePumped(peer, pkg_name, framed, retry_budget, max_attempts, false) catch |err| switch (err) {
        error.WindowFull => {
            self.harness.counters.inc(.reliable_window_drops);
            const n = self.harness.counters.get(.reliable_window_drops);
            if (n == 1 or n % 100 == 0) {
                var ts: [19]u8 = undefined;
                std.debug.print("zdtd: {s} reliable window drop pkg={s} (framed) droppable={} n={d}\n", .{ clock.wallStamp(&ts), pkg_name, droppable, n });
            }
            // Same droppable rule as sendGameBudget: a droppable package
            // (NetPackageChunk/SignDataResponse ride this compressed path)
            // must not turn WindowFull into a hard error, or a single full
            // window aborts the caller mid-join before the critical bundle sends.
            if (droppable) return;
            return error.WindowFull;
        },
        else => return err,
    };
}
