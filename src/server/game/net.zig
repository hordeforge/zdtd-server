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
const packages = @import("../../wire/packages.zig");
const clock = @import("../../util/clock.zig");
const systems = @import("../../ecs/systems.zig");

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
    const owns_critical_budget = critical and peer.critical_budget_deadline_ns == 0;
    if (owns_critical_budget) peer.critical_budget_deadline_ns = clock.monoNs() + budget_ns;
    defer if (owns_critical_budget) {
        peer.critical_budget_deadline_ns = 0;
    };
    if (std.mem.eql(u8, pkg_name, "NetPackageChunk") or std.mem.eql(u8, pkg_name, "NetPackageSignDataResponse")) {
        if (try @import("send_extra.zig").sendCompressed(self, peer, pkg_name, body, budget_ns, critical)) return;
    }
    const framed = packages.framed(&self.send_buf, pkg_name, body) catch |err| {
        self.harness.counters.inc(.encode_errors);
        const n = self.harness.counters.get(.encode_errors);
        if (n == 1 or n % 100 == 0) {
            var ts: [19]u8 = undefined;
            std.debug.print("zdtd: {s} encode failed pkg={s} body_len={d} local_id={d} n={d}: {s}\n", .{ clock.wallStamp(&ts), pkg_name, body.len, peer.local_id, n, @errorName(err) });
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
    // A package may be replaceable during normal play but must-deliver in a
    // join bundle. In particular, periodic WorldTime is droppable while the
    // enter-bundle WorldTime has no client retry.
    const droppable = !critical and isDroppablePackage(pkg_name);
    const max_attempts: u32 = if (std.mem.eql(u8, pkg_name, "NetPackageChunk"))
        4000
    else if (droppable)
        64
    else
        960;
    var retry_budget = budget_ns;
    if (critical) {
        const now = clock.monoNs();
        retry_budget = if (now >= peer.critical_budget_deadline_ns)
            0
        else
            @min(budget_ns, peer.critical_budget_deadline_ns - now);
    }
    sendReliablePumped(self, peer, pkg_name, framed, retry_budget, max_attempts, false) catch |err| switch (err) {
        error.WindowFull => {
            self.harness.counters.inc(.reliable_window_drops);
            const drops = self.harness.counters.get(.reliable_window_drops);
            if (drops == 1 or drops % 100 == 0) {
                var ts: [19]u8 = undefined;
                std.debug.print("zdtd: {s} reliable window drop pkg={s} droppable={} n={d}\n", .{ clock.wallStamp(&ts), pkg_name, droppable, drops });
            }
            if (!droppable) return error.WindowFull;
        },
        else => return err,
    };
}

/// Shared reliable-window retry pump: one place for the budget/deadline/sleep
/// rules so broadcast and sendGameBudget share the same behaviour.
/// `budget_ns==null` is reserved for callers that already impose an outer
/// deadline. Returns error.WindowFull on exhaustion; callers own drop counters/logs and the
/// packages_broadcast count (via count_broadcast).
pub fn sendReliablePumped(self: *Game, peer: *ln_peer.Peer, _: []const u8, framed: []const u8, budget_ns: ?u64, max_attempts: u32, count_broadcast: bool) !void {
    const retry_deadline: u64 = if (budget_ns) |b| clock.monoNs() + b else 0;
    const previous_send_deadline = peer.reliable_send_deadline_ns;
    peer.reliable_send_deadline_ns = retry_deadline;
    defer peer.reliable_send_deadline_ns = previous_send_deadline;
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
    sendReliablePumped(self, peer, "framed-stream", framed, game_mod.window_retry_budget_ns, 64, true) catch |err| switch (err) {
        error.WindowFull => {
            self.harness.counters.inc(.reliable_window_drops);
            const n = self.harness.counters.get(.reliable_window_drops);
            if (n == 1 or n % 100 == 0) {
                var ts: [19]u8 = undefined;
                std.debug.print("zdtd: {s} drop framed stream (reliable window full) n={d} local_id={d}\n", .{ clock.wallStamp(&ts), n, peer.local_id });
            }
        },
        else => {
            // sendReliablePumped already counted this in net_send_errors; log
            // the error name like the other send paths or a socket fault on the
            // stream is only visible as an unexplained counter.
            const n = self.harness.counters.get(.net_send_errors);
            if (n == 1 or n % 100 == 0) {
                var ts: [19]u8 = undefined;
                std.debug.print("zdtd: {s} framed stream send failed local_id={d} n={d}: {s}\n", .{ clock.wallStamp(&ts), peer.local_id, n, @errorName(err) });
            }
        },
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
            var ts: [19]u8 = undefined;
            std.debug.print("zdtd: {s} encode failed pkg={s} body_len={d} n={d}: {s}\n", .{ clock.wallStamp(&ts), name, body.len, n, @errorName(err) });
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
        sendReliablePumped(self, p, name, framed, game_mod.window_retry_budget_ns, 64, true) catch |err| switch (err) {
            error.WindowFull => {
                self.harness.counters.inc(.reliable_window_drops);
                const d = self.harness.counters.get(.reliable_window_drops);
                if (d == 1 or d % 100 == 0) {
                    var ts: [19]u8 = undefined;
                    std.debug.print("zdtd: {s} reliable window drop pkg={s} broadcastNear local_id={d} n={d}\n", .{ clock.wallStamp(&ts), name, p.local_id, d });
                }
            },
            else => {
                self.harness.counters.inc(.net_send_errors);
                const n2 = self.harness.counters.get(.net_send_errors);
                if (n2 == 1 or n2 % 100 == 0) {
                    var ts: [19]u8 = undefined;
                    std.debug.print("zdtd: {s} broadcast send failed pkg={s} local_id={d} n={d}: {s}\n", .{ clock.wallStamp(&ts), name, p.local_id, n2, @errorName(err) });
                }
            },
        };
    }
}

pub fn broadcastExcept(self: *Game, name: []const u8, body: []const u8, except_slot: ?usize) !void {
    const framed = packages.framed(&self.send_buf, name, body) catch |err| {
        self.harness.counters.inc(.encode_errors);
        const n = self.harness.counters.get(.encode_errors);
        if (n == 1 or n % 100 == 0) {
            var ts: [19]u8 = undefined;
            std.debug.print("zdtd: {s} encode failed pkg={s} body_len={d} n={d}: {s}\n", .{ clock.wallStamp(&ts), name, body.len, n, @errorName(err) });
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
            sendReliablePumped(self, p, name, framed, game_mod.window_retry_budget_ns, 64, true) catch |err| switch (err) {
                error.WindowFull => {
                    self.harness.counters.inc(.reliable_window_drops);
                    const d = self.harness.counters.get(.reliable_window_drops);
                    if (d == 1 or d % 100 == 0) {
                        var ts: [19]u8 = undefined;
                        std.debug.print("zdtd: {s} reliable window drop pkg={s} broadcast local_id={d} n={d}\n", .{ clock.wallStamp(&ts), name, p.local_id, d });
                    }
                },
                else => {
                    self.harness.counters.inc(.net_send_errors);
                    const n2 = self.harness.counters.get(.net_send_errors);
                    if (n2 == 1 or n2 % 100 == 0) {
                        var ts: [19]u8 = undefined;
                        std.debug.print("zdtd: {s} broadcast send failed pkg={s} local_id={d} n={d}: {s}\n", .{ clock.wallStamp(&ts), name, p.local_id, n2, @errorName(err) });
                    }
                },
            };
        }
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

/// Rate-limited log for a failed C2S payload, shared by both poll sites.
/// A peer spraying malformed packets would otherwise emit one blocking stderr
/// write per packet on the tick thread, turning a decode fault into a stall and
/// burying the first (diagnostic) line. The counter stays exact.
pub fn logPayloadErr(self: *Game, local_id: i32, err: anyerror) void {
    const n = self.harness.counters.get(.net_payload_errors);
    if (n == 1 or n % 100 == 0) {
        var ts: [19]u8 = undefined;
        std.debug.print(
            "zdtd: {s} payload failed local_id={d} error={s} n={d}\n",
            .{ clock.wallStamp(&ts), local_id, @errorName(err), n },
        );
    }
}

pub fn pollNetOnce(self: *Game) void {
    if (self.pumping) {
        var ctl: [2048]u8 = undefined;
        self.net.drainControl(&ctl, 24);
        return;
    }
    if (self.drain_suppressed > 0) return;
    const ev = self.net.poll(&self.recv_buf) catch |err| {
        // Unlike step's poll loop this one cannot propagate, so the error name
        // only survives if it is logged here: otherwise net_poll_errors climbs
        // with no way to tell a socket fault from a decode fault.
        self.harness.counters.inc(.net_poll_errors);
        const n = self.harness.counters.get(.net_poll_errors);
        if (n == 1 or n % 100 == 0) {
            var ts: [19]u8 = undefined;
            std.debug.print("zdtd: {s} net poll error (drain): {s} n={d}\n", .{ clock.wallStamp(&ts), @errorName(err), n });
        }
        return;
    };
    switch (ev) {
        .none => {},
        .connected => |p| self.onConnected(p) catch |e| {
            self.harness.counters.inc(.join_fail);
            var ts: [19]u8 = undefined;
            std.debug.print("zdtd: {s} onConnected failed local_id={d}: {s}\n", .{ clock.wallStamp(&ts), p.local_id, @errorName(e) });
        },
        .data => |d| self.onData(d.peer, d.payload) catch |err| {
            self.harness.counters.inc(.net_payload_errors);
            logPayloadErr(self, d.peer.local_id, err);
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
                var ts: [19]u8 = undefined;
                std.debug.print("zdtd: {s} peer reaped dead local_id={d} slot={d} entity={d}\n", .{ clock.wallStamp(&ts), p.local_id, c.slot, c.entity_id });
                _ = systems.vehicleDetach(&self.sim, c.entity_id);
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
            // Pre-auth challenge: stock derives the 16 bytes from
            // Guid.NewGuid() (asm.il 852999, 853010-853025); a monotonic
            // counter would make the echo predictable, so use the Io CSPRNG
            // (same idiom as the webui session nonce). Per-connection init is
            // allowed (accept path, not the tick).
            var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
            defer threaded.deinit();
            threaded.io().random(&c.challenge);
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
