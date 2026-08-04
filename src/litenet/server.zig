//! UDP LiteNetLib-compatible server (accept + reliable user data).

const std = @import("std");
const packet = @import("packet.zig");
const peer_mod = @import("peer.zig");
const udp = @import("udp_socket.zig");

pub const max_peers = 64;

pub const Server = struct {
    sock: udp.Socket = .{},
    port: u16 = 0,
    peers: [max_peers]peer_mod.Peer = [_]peer_mod.Peer{.{}} ** max_peers,
    next_local_id: i32 = 1,
    /// Stock ServerPassword: compared to LiteNet Connect key (NetDataWriter string in request Data).
    server_password: []const u8 = "",

    pub fn listen(self: *Server, port: u16) !void {
        self.port = try self.sock.openAndBind(port);
    }

    pub fn deinit(self: *Server) void {
        self.sock.close();
    }

    pub const Event = union(enum) {
        none,
        connected: *peer_mod.Peer,
        data: struct { peer: *peer_mod.Peer, payload: []const u8 },
    };

    pub fn poll(self: *Server, buf: []u8) !Event {
        // Drain extras from a prior Merged datagram before reading the socket.
        for (&self.peers) |*p| {
            if (!p.alive) continue;
            if (p.popExtra()) |u| return .{ .data = .{ .peer = p, .payload = u } };
        }

        var src: udp.IpAddress = undefined;
        const n = self.sock.recvFrom(buf, &src) catch |err| switch (err) {
            error.WouldBlock => return .none,
            else => return err,
        };
        if (n == 0) return .none;
        const raw = buf[0..n];

        const prop = packet.propertyOf(raw[0]);
        if (prop == .connect_request) {
            const req = packet.parseConnectRequest(raw) orelse return .none;
            // Stock ConnectionRequestCheck always: retransmits from an existing peer
            // must still present the ServerPassword (do not skip auth on retransmit).
            if (!packet.connectKeyMatches(req.data, self.server_password)) {
                var rej_buf: [32]u8 = undefined;
                const rej = try packet.writeDisconnect(
                    &rej_buf,
                    req.connection_time,
                    req.connection_number,
                    &packet.reject_invalid_password,
                );
                self.sock.sendTo(rej, &src) catch {};
                std.debug.print("zdtd: connect rejected (bad password) remote_peer_id={d}\n", .{req.peer_id});
                return .none;
            }
            // Retransmitted ConnectRequest from an already-accepted peer: only re-send Accept.
            if (self.findPeer(&src)) |existing| {
                existing.connect_time = req.connection_time;
                existing.conn_num = req.connection_number;
                existing.remote_id = req.peer_id;
                var accept_buf: [32]u8 = undefined;
                const accept = try packet.writeConnectAccept(&accept_buf, req.connection_time, req.connection_number, existing.local_id);
                try existing.sendRaw(&self.sock, accept);
                return .none;
            }
            const p = try self.allocPeer(&src, req);
            var accept_buf: [32]u8 = undefined;
            const accept = try packet.writeConnectAccept(&accept_buf, req.connection_time, req.connection_number, p.local_id);
            try p.sendRaw(&self.sock, accept);
            return .{ .connected = p };
        }

        const p = self.findPeer(&src) orelse {
            // Unknown source (should not happen after accept).
            return .none;
        };
        const user = try p.handlePacket(&self.sock, raw);
        if (user) |u| return .{ .data = .{ .peer = p, .payload = u } };
        // Merged may have queued extras without a first payload.
        if (p.popExtra()) |u| return .{ .data = .{ .peer = p, .payload = u } };
        return .none;
    }

    /// Drain inbound acks/pings without delivering game payloads (used mid-send).
    /// Game user payloads are copied into the peer extra queue so a later
    /// poll() delivers them; never drop login/challenge bytes while joining.
    pub fn drainControl(self: *Server, buf: []u8, max_n: u32) void {
        var i: u32 = 0;
        while (i < max_n) : (i += 1) {
            var src: udp.IpAddress = undefined;
            const n = self.sock.recvFrom(buf, &src) catch break;
            if (n == 0) break;
            const raw = buf[0..n];
            const prop = packet.propertyOf(raw[0]);
            if (prop == .connect_request) continue;
            const p = self.findPeer(&src) orelse continue;
            // handlePacket applies ACKs (frees reliable window) and may return a
            // user slice into `buf`; copy it before the next recv overwrites.
            if (p.handlePacket(&self.sock, raw) catch null) |user| {
                p.pushExtra(user);
            }
        }
    }

    fn findPeer(self: *Server, addr: *const udp.IpAddress) ?*peer_mod.Peer {
        const key = udp.hashIp(addr);
        for (&self.peers) |*p| {
            if (p.alive and p.addr_key == key) return p;
        }
        return null;
    }

    fn allocPeer(self: *Server, addr: *const udp.IpAddress, req: packet.ConnectRequest) !*peer_mod.Peer {
        // Prefer a free slot; always fully reset reliable state on new accept.
        for (&self.peers) |*p| {
            if (p.alive) continue;
            p.* = .{};
            p.setAddr(addr);
            p.remote_id = req.peer_id;
            p.local_id = self.next_local_id;
            self.next_local_id += 1;
            p.connect_time = req.connection_time;
            p.conn_num = req.connection_number;
            p.alive = true;
            return p;
        }
        // Evict oldest idle unauthenticated peer if full (simple reclaim).
        for (&self.peers) |*p| {
            if (!p.authenticated) {
                p.* = .{};
                p.setAddr(addr);
                p.remote_id = req.peer_id;
                p.local_id = self.next_local_id;
                self.next_local_id += 1;
                p.connect_time = req.connection_time;
                p.conn_num = req.connection_number;
                p.alive = true;
                return p;
            }
        }
        return error.TooManyPeers;
    }
};
