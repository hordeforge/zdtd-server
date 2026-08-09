//! Framed send helpers extracted from game.zig.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const wire_frame = @import("../../wire/frame.zig");
const clock = @import("../../util/clock.zig");
const window_fast_attempts = game_mod.window_fast_attempts;
const window_retry_sleep_ns = game_mod.window_retry_sleep_ns;

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
    var retry_budget = budget_ns;
    if (critical) {
        const now = clock.monoNs();
        if (peer.critical_budget_deadline_ns < now) peer.critical_budget_deadline_ns = now + budget_ns;
        retry_budget = @min(budget_ns, peer.critical_budget_deadline_ns -% now);
    }
    const retry_deadline = clock.monoNs() + retry_budget;
    var attempts: u32 = 0;
    while (attempts < 960) : (attempts += 1) {
        peer.sendReliable(&self.net.sock, framed) catch |err| switch (err) {
            error.WindowFull => {
                peer.resendPending(&self.net.sock) catch {
                    self.harness.counters.inc(.net_send_errors);
                };
                self.pollNetOnce();
                if (clock.monoNs() >= retry_deadline) break;
                if (attempts >= window_fast_attempts and attempts % 4 == 3) clock.sleepNs(window_retry_sleep_ns);
                continue;
            },
            else => {
                self.harness.counters.inc(.net_send_errors);
                return err;
            },
        };
        self.harness.counters.add(.net_packets_out, 1);
        self.harness.counters.add(.net_bytes_out, framed.len);
        self.pollNetAfterSend();
        if (critical) peer.critical_budget_deadline_ns = clock.monoNs() + budget_ns;
        return;
    }
    self.harness.counters.inc(.reliable_window_drops);
    std.debug.print("zdtd: reliable window drop pkg={s} (framed)\n", .{pkg_name});
    return error.WindowFull;
}
