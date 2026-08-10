//! Net ingress extracted from game.zig — onConnected / onData / dispatchGamePayload.
//! Verbatim bodies; game.zig keeps one-line forwarders.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const wire_frame = @import("../../wire/frame.zig");
const packages = @import("../../wire/packages.zig");

pub fn onConnected(self: *Game, peer: *ln_peer.Peer) !void {
    const c = self.clientFor(peer) orelse {
        self.harness.counters.inc(.join_fail);
        std.debug.print("zdtd: join rejected (no client slot) local_id={d} max_players={d}\n", .{ peer.local_id, self.max_players });
        peer.alive = false;
        return;
    };
    peer.pump_fn = &Game.pumpAcks;
    peer.pump_ctx = self;
    const ip = Game.peerIpKey(peer);
    if (self.isBanned(ip)) {
        std.debug.print("zdtd: ban reject local_id={d}\n", .{peer.local_id});
        self.harness.counters.inc(.join_fail);
        peer.alive = false;
        c.* = .{};
        return;
    }
    if (self.joinRateLimited(ip)) {
        std.debug.print("zdtd: join rate-limit local_id={d}\n", .{peer.local_id});
        self.harness.counters.inc(.join_fail);
        peer.alive = false;
        c.* = .{};
        return;
    }
    var ch: [17]u8 = undefined;
    wire_frame.buildChallenge(&ch, c.challenge);
    peer.sendReliable(&self.net.sock, &ch) catch |err| {
        self.harness.counters.inc(.net_send_errors);
        self.harness.counters.inc(.join_fail);
        std.debug.print("zdtd: challenge send failed local_id={d} error={s}\n", .{ peer.local_id, @errorName(err) });
        return;
    };
    std.debug.print("zdtd: peer connected local_id={d} → challenge sent\n", .{peer.local_id});
}

pub fn onData(self: *Game, peer: *ln_peer.Peer, payload: []const u8) anyerror!void {
    const was_pumping = self.pumping;
    self.pumping = true;
    defer self.pumping = was_pumping;
    const c = self.clientFor(peer) orelse return;
    self.harness.counters.add(.net_packets_in, 1);
    self.harness.counters.add(.net_bytes_in, payload.len);
    if (!c.authed_challenge) {
        if (wire_frame.isChallenge(payload) and std.mem.eql(u8, payload[1..17], &c.challenge)) {
            c.authed_challenge = true;
            peer.authenticated = true;
            const body = try packages.buildPackageIdsBody(&self.body_buf, .{}, &packages.default_mappings);
            try self.sendGame(peer, "NetPackagePackageIds", body);
            peer.resendPending(&self.net.sock) catch self.harness.counters.inc(.net_send_errors);
            std.debug.print("zdtd: challenge ok local_id={d} package_maps={d}\n", .{ peer.local_id, packages.default_mappings.len });
            if (c.preauth_len > 0) {
                const saved = c.preauth_buf[0..c.preauth_len];
                c.preauth_len = 0;
                try dispatchGamePayload(self, c, peer, saved);
            }
        } else if (wire_frame.isChallenge(payload)) {
            std.debug.print("zdtd: challenge mismatch local_id={d} payload_len={d}\n", .{ peer.local_id, payload.len });
        } else if (payload.len > 0 and payload.len <= c.preauth_buf.len) {
            @memcpy(c.preauth_buf[0..payload.len], payload);
            c.preauth_len = payload.len;
        }
        return;
    }
    if (wire_frame.isChallenge(payload)) return;
    try dispatchGamePayload(self, c, peer, payload);
}

pub fn dispatchGamePayload(self: *Game, c: *Client, peer: *ln_peer.Peer, payload: []const u8) !void {
    const stable: []const u8 = blk: {
        if (payload.len <= self.payload_hold.len) {
            @memcpy(self.payload_hold[0..payload.len], payload);
            break :blk self.payload_hold[0..payload.len];
        }
        self.drain_suppressed +%= 1;
        break :blk payload;
    };
    defer if (payload.len > self.payload_hold.len) {
        self.drain_suppressed -%= 1;
    };
    var pkgs: [16]wire_frame.Package = undefined;
    const n = wire_frame.parseChannelPayload(stable, &pkgs);
    if (n == 0 and stable.len > 0) {
        // Same hostile-input sampling as logPayloadErr (game/net.zig): an
        // unparseable payload is cheap to spray from any connected peer, and
        // one blocking stderr write per packet would stall the tick thread.
        self.harness.counters.inc(.c2s_malformed);
        const malformed = self.harness.counters.get(.c2s_malformed);
        if (malformed == 1 or malformed % 100 == 0) {
            var hex: [24]u8 = undefined;
            const show = @min(stable.len, 8);
            var hi: usize = 0;
            var bi: usize = 0;
            while (bi < show and hi + 2 <= hex.len) : (bi += 1) {
                const s = std.fmt.bufPrint(hex[hi..], "{x:0>2}", .{stable[bi]}) catch break;
                hi += s.len;
            }
            if (stable.len >= 9) {
                const psz = std.mem.readInt(i32, stable[1..5], .little);
                std.debug.print("zdtd: unparsed game payload len={d} head={s} ch={d} psz={d} comp={d} enc={d} cnt={d}\n", .{ stable.len, hex[0..hi], stable[0], psz, stable[5], stable[6], std.mem.readInt(u16, stable[7..9], .little) });
            } else {
                std.debug.print("zdtd: unparsed game payload len={d} head={s}\n", .{ stable.len, hex[0..hi] });
            }
        }
        if (stable.len >= 10) {
            var alt: [16]wire_frame.Package = undefined;
            var tmp: [8192]u8 = undefined;
            if (stable.len + 1 <= tmp.len) {
                tmp[0] = 0;
                @memcpy(tmp[1..][0..stable.len], stable);
                const n2 = wire_frame.parseChannelPayload(tmp[0 .. stable.len + 1], &alt);
                if (n2 > 0) {
                    std.debug.print("zdtd: alt-parse got {d} pkgs id0={d}\n", .{ n2, alt[0].id });
                    var j: usize = 0;
                    while (j < n2) : (j += 1) {
                        try self.handlePackage(c, peer, alt[j].id, alt[j].body);
                    }
                    return;
                }
            }
        }
    }
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try self.handlePackage(c, peer, pkgs[i].id, pkgs[i].body);
    }
}
