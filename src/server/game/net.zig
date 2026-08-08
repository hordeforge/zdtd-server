//! Net send path for Game: reliable-window pump, framed fan-out,
//! and the broadcast helpers.
//!
//! Extracted from game.zig (the last god file) following the replicate_te /
//! chunk_stream precedent: helpers take `*Game` as first param and are called as
//! `game_net.sendGame(g, peer, name, body)`. game.zig keeps one-line forwarders
//! so existing callers/tests stay unchanged.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const ln_packet = @import("../../litenet/packet.zig");
const wire_frame = @import("../../wire/frame.zig");
const packages = @import("../../wire/packages.zig");
const clock = @import("../../util/clock.zig");

const window_fast_attempts = game_mod.window_fast_attempts;
const window_retry_sleep_ns = game_mod.window_retry_sleep_ns;

/// Stock EntityPlayer/NetConnectionAbs `get_ReliableDelivery` overrides
/// (asm.il 816202-816208, 793041-793050): these five S2C packages ride the
/// Unreliable delivery method, not the 64-slot reliable window.
pub fn isUnreliablePackage(pkg_name: []const u8) bool {
    const names = [_][]const u8{
        "NetPackageEntityPosAndRot",
        "NetPackageEntityRelPosAndRot",
        "NetPackageEntityRotation",
        "NetPackageEntitySpeeds",
        "NetPackageEntityStatsBuff",
    };
    for (names) |n| {
        if (std.mem.eql(u8, pkg_name, n)) return true;
    }
    return false;
}

pub fn isDroppablePackage(pkg_name: []const u8) bool {
    const names = [_][]const u8{
        "NetPackageChunk",
        "NetPackageChunkRemove",
        "NetPackageDecoResetWorldChunk",
        "NetPackageEntityPosAndRot",
        "NetPackageEntitySpeeds",
        "NetPackageVehiclePositions",
        "NetPackageWorldTime",
    };
    for (names) |n| {
        if (std.mem.eql(u8, pkg_name, n)) return true;
    }
    return false;
}

pub fn sendGame(self: *Game, peer: *ln_peer.Peer, pkg_name: []const u8, body: []const u8) anyerror!void {
    return sendGameBudget(self, peer, pkg_name, body, game_mod.window_retry_budget_ns, false);
}

/// Join-critical variant of sendGame: the enter bundle has no client retry,
/// so a transiently busy peer must not lose WorldInfo/IdMapping.
pub fn sendGameCritical(self: *Game, peer: *ln_peer.Peer, pkg_name: []const u8, body: []const u8) anyerror!void {
    return sendGameBudget(self, peer, pkg_name, body, game_mod.critical_retry_budget_ns, true);
}

pub fn sendGameBudget(self: *Game, peer: *ln_peer.Peer, pkg_name: []const u8, body: []const u8, budget_ns: u64, critical: bool) anyerror!void {
    if (std.mem.eql(u8, pkg_name, "NetPackageChunk") or std.mem.eql(u8, pkg_name, "NetPackageSignDataResponse")) {
        if (self.trySendCompressed(peer, pkg_name, body)) return;
    }
    const framed = packages.framed(&self.send_buf, pkg_name, body) catch |err| {
        self.harness.counters.inc(.encode_errors);
        const n = self.harness.counters.get(.encode_errors);
        if (n == 1 or n % 100 == 0) {
            std.debug.print("zdtd: encode failed pkg={s} body_len={d} local_id={d} n={d}: {s}\n", .{ pkg_name, body.len, peer.local_id, n, @errorName(err) });
        }
        return err;
    };
    if (isUnreliablePackage(pkg_name)) {
        if (framed.len <= ln_packet.max_single_user) {
            peer.sendUnreliable(&self.net.sock, framed) catch |err| {
                self.harness.counters.inc(.net_send_errors);
                return err;
            };
            self.harness.counters.add(.net_packets_out, 1);
            self.harness.counters.add(.net_bytes_out, framed.len);
            return;
        }
    }
    const droppable = isDroppablePackage(pkg_name);
    const max_attempts: u32 = if (std.mem.eql(u8, pkg_name, "NetPackageChunk"))
        4000
    else if (droppable)
        64
    else
        960;
    var retry_budget = budget_ns;
    if (critical) {
        const now = clock.monoNs();
        if (peer.critical_budget_deadline_ns < now) peer.critical_budget_deadline_ns = now + budget_ns;
        retry_budget = @min(budget_ns, peer.critical_budget_deadline_ns -% now);
    }
    sendReliablePumped(self, peer, pkg_name, framed, retry_budget, max_attempts, false) catch |err| switch (err) {
        error.WindowFull => {
            self.harness.counters.inc(.reliable_window_drops);
            const drops = self.harness.counters.get(.reliable_window_drops);
            if (drops == 1 or drops % 100 == 0) {
                std.debug.print("zdtd: reliable window drop pkg={s} droppable={} n={d}\n", .{ pkg_name, droppable, drops });
            }
            if (critical) return error.WindowFull;
        },
        else => return err,
    };
}

/// Shared reliable-window retry pump: one place for the budget/deadline/sleep
/// rules so broadcast and sendGameBudget share the same behaviour.
/// `budget_ns==null` means no deadline (stream/broadcast). Returns
/// error.WindowFull on exhaustion; callers own drop counters/logs and the
/// packages_broadcast count (via count_broadcast).
pub fn sendReliablePumped(self: *Game, peer: *ln_peer.Peer, _: []const u8, framed: []const u8, budget_ns: ?u64, max_attempts: u32, count_broadcast: bool) !void {
    const retry_deadline: u64 = if (budget_ns) |b| clock.monoNs() + b else 0;
    var attempts: u32 = 0;
    while (attempts < max_attempts) : (attempts += 1) {
        peer.sendReliable(&self.net.sock, framed) catch |err| switch (err) {
            error.WindowFull => {
                peer.resendPending(&self.net.sock) catch {
                    self.harness.counters.inc(.net_send_errors);
                };
                self.pollNetOnce();
                if (budget_ns != null and clock.monoNs() >= retry_deadline) break;
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
        if (count_broadcast) self.harness.counters.inc(.packages_broadcast);
        self.pollNetAfterSend();
        return;
    }
    return error.WindowFull;
}

pub fn sendFramedUnreliable(self: *Game, peer: *ln_peer.Peer, framed: []const u8) void {
    if (framed.len > ln_packet.max_single_user) {
        sendFramedDroppable(self, peer, framed);
        return;
    }
    peer.sendUnreliable(&self.net.sock, framed) catch {
        self.harness.counters.inc(.net_send_errors);
    };
    self.harness.counters.add(.net_packets_out, 1);
    self.harness.counters.add(.net_bytes_out, framed.len);
}

pub fn sendFramedDroppable(self: *Game, peer: *ln_peer.Peer, framed: []const u8) void {
    sendReliablePumped(self, peer, "framed-stream", framed, null, 64, true) catch |err| switch (err) {
        error.WindowFull => {
            self.harness.counters.inc(.reliable_window_drops);
            const n = self.harness.counters.get(.reliable_window_drops);
            if (n == 1 or n % 100 == 0) {
                std.debug.print("zdtd: drop framed stream (reliable window full) n={d} local_id={d}\n", .{ n, peer.local_id });
            }
        },
        else => {},
    };
}

pub fn broadcast(self: *Game, name: []const u8, body: []const u8) !void {
    try broadcastExcept(self, name, body, null);
}

/// World-position broadcast: only clients whose player is within
/// `range_blocks` of (wx,wz).
pub fn broadcastNear(self: *Game, name: []const u8, body: []const u8, wx: f32, wz: f32, range_blocks: f32) !void {
    const framed = packages.framed(&self.send_buf, name, body) catch |err| {
        self.harness.counters.inc(.encode_errors);
        const n = self.harness.counters.get(.encode_errors);
        if (n == 1 or n % 100 == 0) {
            std.debug.print("zdtd: encode failed pkg={s} body_len={d} n={d}: {s}\n", .{ name, body.len, n, @errorName(err) });
        }
        return err;
    };
    for (&self.clients) |*c| {
        const p = c.peer orelse continue;
        if (!c.joined) continue;
        if (self.sim.playerByPeer(c.slot)) |ps| {
            const dx = self.sim.transform[ps].x - wx;
            const dz = self.sim.transform[ps].z - wz;
            if (dx * dx + dz * dz > range_blocks * range_blocks) continue;
        }
        sendReliablePumped(self, p, name, framed, null, 64, true) catch |err| switch (err) {
            error.WindowFull => {
                self.harness.counters.inc(.reliable_window_drops);
                const d = self.harness.counters.get(.reliable_window_drops);
                if (d == 1 or d % 100 == 0) std.debug.print("zdtd: reliable window drop pkg={s} broadcastNear local_id={d} n={d}\n", .{ name, p.local_id, d });
            },
            else => {
                self.harness.counters.inc(.net_send_errors);
                const n2 = self.harness.counters.get(.net_send_errors);
                if (n2 == 1 or n2 % 100 == 0) std.debug.print("zdtd: broadcast send failed pkg={s} local_id={d} n={d}: {s}\n", .{ name, p.local_id, n2, @errorName(err) });
            },
        };
    }
}

pub fn broadcastExcept(self: *Game, name: []const u8, body: []const u8, except_slot: ?usize) !void {
    const framed = packages.framed(&self.send_buf, name, body) catch |err| {
        self.harness.counters.inc(.encode_errors);
        const n = self.harness.counters.get(.encode_errors);
        if (n == 1 or n % 100 == 0) {
            std.debug.print("zdtd: encode failed pkg={s} body_len={d} n={d}: {s}\n", .{ name, body.len, n, @errorName(err) });
        }
        return err;
    };
    for (&self.clients) |*c| {
        const p = c.peer orelse continue;
        if (!c.joined) continue;
        if (except_slot) |ex| if (c.slot == ex) continue;
        if (isUnreliablePackage(name) and framed.len <= ln_packet.max_single_user) {
            p.sendUnreliable(&self.net.sock, framed) catch {
                self.harness.counters.inc(.net_send_errors);
                continue;
            };
            self.harness.counters.add(.net_packets_out, 1);
            self.harness.counters.add(.net_bytes_out, framed.len);
            self.harness.counters.inc(.packages_broadcast);
        } else {
            sendReliablePumped(self, p, name, framed, null, 64, true) catch |err| switch (err) {
                error.WindowFull => {
                    self.harness.counters.inc(.reliable_window_drops);
                    const d = self.harness.counters.get(.reliable_window_drops);
                    if (d == 1 or d % 100 == 0) std.debug.print("zdtd: reliable window drop pkg={s} broadcast local_id={d} n={d}\n", .{ name, p.local_id, d });
                },
                else => {
                    self.harness.counters.inc(.net_send_errors);
                    const n2 = self.harness.counters.get(.net_send_errors);
                    if (n2 == 1 or n2 % 100 == 0) std.debug.print("zdtd: broadcast send failed pkg={s} local_id={d} n={d}: {s}\n", .{ name, p.local_id, n2, @errorName(err) });
                },
            };
        }
        self.harness.counters.inc(.packages_broadcast);
    }
}

/// Process pending UDP events (acks free window; data delivered to onData).
pub fn pollNetAfterSend(self: *Game) void {
    if (self.sends_since_poll < 8) {
        self.sends_since_poll += 1;
        return;
    }
    self.sends_since_poll = 0;
    self.pollNetOnce();
}

pub fn pollNetOnce(self: *Game) void {
    if (self.pumping) {
        var ctl: [2048]u8 = undefined;
        self.net.drainControl(&ctl, 24);
        return;
    }
    if (self.drain_suppressed > 0) return;
    const ev = self.net.poll(&self.recv_buf) catch {
        self.harness.counters.inc(.net_poll_errors);
        return;
    };
    switch (ev) {
        .none => {},
        .connected => |p| self.onConnected(p) catch |e| {
            self.harness.counters.inc(.join_fail);
            std.debug.print("zdtd: onConnected failed local_id={d}: {s}\n", .{ p.local_id, @errorName(e) });
        },
        .data => |d| self.onData(d.peer, d.payload) catch |err| {
            self.harness.counters.inc(.net_payload_errors);
            std.debug.print("zdtd: payload failed local_id={d} error={s}\n", .{ d.peer.local_id, @errorName(err) });
        },
    }
}

pub fn clientFor(self: *Game, peer: *ln_peer.Peer) ?*Client {
    if (peer.alive) {
        for (&self.clients) |*c| {
            if (c.peer == peer) return c;
        }
    }
    for (&self.clients) |*c| {
        if (c.peer) |p| {
            if (!p.alive) {
                self.harness.counters.inc(.stale_peers_reaped);
                std.debug.print("zdtd: peer reaped dead local_id={d} slot={d} entity={d}\n", .{ p.local_id, c.slot, c.entity_id });
                _ = @import("../../ecs/systems.zig").vehicleDetach(&self.sim, c.entity_id);
                self.clearLocksForPeer(c.slot);
                c.* = .{};
                self.refreshInfoPlayers();
            }
        }
    }
    for (&self.clients) |*c| {
        if (c.peer == peer) return c;
    }
    var occupied: u16 = 0;
    for (&self.clients) |*c| {
        if (c.peer != null) occupied += 1;
    }
    if (occupied >= self.max_players) return null;
    for (&self.clients, 0..) |*c, i| {
        if (c.peer == null) {
            c.* = .{ .peer = peer, .slot = i };
            self.challenge_counter += 1;
            std.mem.writeInt(u64, c.challenge[0..8], self.challenge_counter, .little);
            std.mem.writeInt(u64, c.challenge[8..16], self.challenge_counter *% 0x9E3779B97F4A7C15, .little);
            return c;
        }
    }
    return null;
}

pub fn peerIpKey(peer: *const ln_peer.Peer) u32 {
    return switch (peer.addr) {
        .ip4 => |a| std.mem.readInt(u32, &a.bytes, .big),
        .ip6 => |a| blk: {
            if (std.mem.eql(u8, a.bytes[0..12], &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff })) {
                break :blk std.mem.readInt(u32, a.bytes[12..16], .big);
            }
            var h: u32 = 2166136261;
            for (a.bytes) |b| {
                h ^= b;
                h *%= 16777619;
            }
            if (h == 0 or h == 0x7f000001) h ^= 0x80000000;
            break :blk h;
        },
    };
}

pub fn banIp(self: *Game, ip: u32) void {
    if (ip == 0 or ip == 0x7f000001) return;
    for (self.ban_ip[0..self.ban_n]) |banned| if (banned == ip) return;
    if (self.ban_n < self.ban_ip.len) {
        self.ban_ip[self.ban_n] = ip;
        self.ban_n += 1;
    }
}

pub fn unbanIp(self: *Game, ip: u32) void {
    var i: usize = 0;
    while (i < self.ban_n) {
        if (self.ban_ip[i] == ip) {
            self.ban_ip[i] = self.ban_ip[self.ban_n - 1];
            self.ban_n -= 1;
            return;
        }
        i += 1;
    }
}
