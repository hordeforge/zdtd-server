//! Per-endpoint reliable-ordered channel (LiteNetLib-compatible subset).
//! Matches game Managed LiteNetLib PacketProperty ordinals and ack sizing.

const std = @import("std");
const linux = std.os.linux;
const packet = @import("packet.zig");
const udp = @import("linux_udp.zig");
const clock = @import("../util/clock.zig");

/// Max assembled user message. Mixed-surface stock chunks + texture planes can exceed 128 KiB.
pub const max_payload: usize = 524288;
/// Pending retransmit slots. allocPending caps in-flight at window_size, so
/// more slots than the window can never be used (fragments beyond it retry
/// via the WindowFull pump loop). max_sequence % window_size == 0 keeps
/// consecutive in-window seqs on distinct slots across wrap.
const pending_cap: usize = packet.window_size;
comptime {
    std.debug.assert(packet.max_sequence % pending_cap == 0);
}
/// One pending slot holds one MTU-sized channeled/fragment datagram.
const pending_bytes: usize = packet.max_packet_size;
const max_frag_parts: usize = 512;
const assemble_cap: usize = max_payload;
/// Game: (windowSize-1)/8 + 2 = 9 bitmap payload bytes on Ack.
const ack_bitmap_bytes: usize = (packet.window_size - 1) / 8 + 2;
const resend_ns: u64 = 80_000_000; // 80ms, similar ballpark to LiteNet resend

const Pending = struct {
    used: bool = false,
    seq: u16 = 0,
    len: u16 = 0,
    last_sent_ns: u64 = 0,
    data: [pending_bytes]u8 = undefined,
};

/// Optional outbound capture for integration tests (records game payloads, not LiteNet headers).
pub const Capture = struct {
    /// Test-only reach into wire/ for package parse (see root.zig dependency note).
    const frame = @import("../wire/frame.zig");

    /// Per-message cap must fit stock inventory frames and medium packages.
    /// Slot count covers join floods (stream r≤8 → 100+ chunks) + multi-step sim.
    /// Full stock chunks may exceed per-slot size; tests assert via counters too.
    slots: [256]struct { len: u16 = 0, data: [8192]u8 = undefined } = undefined,
    n: usize = 0,

    pub fn push(self: *Capture, user: []const u8) void {
        if (self.n >= self.slots.len) {
            // drop oldest
            var i: usize = 1;
            while (i < self.slots.len) : (i += 1) self.slots[i - 1] = self.slots[i];
            self.n = self.slots.len - 1;
        }
        const s = &self.slots[self.n];
        const n = @min(user.len, s.data.len);
        @memcpy(s.data[0..n], user[0..n]);
        s.len = @intCast(n);
        self.n += 1;
    }

    pub fn clear(self: *Capture) void {
        self.n = 0;
    }

    pub fn findPkgId(self: *const Capture, pkg_id: u16) ?[]const u8 {
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            const msg = self.slots[i].data[0..self.slots[i].len];
            var pkgs: [8]frame.Package = undefined;
            const pn = frame.parseChannelPayload(msg, &pkgs);
            var j: usize = 0;
            while (j < pn) : (j += 1) {
                if (pkgs[j].id == pkg_id) return pkgs[j].body;
            }
        }
        return null;
    }

    /// Find PosAndRot/etc body whose first i32 is entity_id (common package layout).
    pub fn findPkgIdEntity(self: *const Capture, pkg_id: u16, entity_id: i32) ?[]const u8 {
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            const msg = self.slots[i].data[0..self.slots[i].len];
            var pkgs: [8]frame.Package = undefined;
            const pn = frame.parseChannelPayload(msg, &pkgs);
            var j: usize = 0;
            while (j < pn) : (j += 1) {
                if (pkgs[j].id != pkg_id) continue;
                if (pkgs[j].body.len < 4) continue;
                const eid = std.mem.readInt(i32, pkgs[j].body[0..4], .little);
                if (eid == entity_id) return pkgs[j].body;
            }
        }
        return null;
    }

    /// Find EntitySpawn-style body with matching class hash at body[5..9] (after id+ver).
    pub fn findPkgIdClass(self: *const Capture, pkg_id: u16, class_hash: i32) ?[]const u8 {
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            const msg = self.slots[i].data[0..self.slots[i].len];
            var pkgs: [8]frame.Package = undefined;
            const pn = frame.parseChannelPayload(msg, &pkgs);
            var j: usize = 0;
            while (j < pn) : (j += 1) {
                if (pkgs[j].id != pkg_id) continue;
                if (pkgs[j].body.len < 9) continue;
                const h = std.mem.readInt(i32, pkgs[j].body[5..9], .little);
                if (h == class_hash) return pkgs[j].body;
            }
        }
        return null;
    }
};

pub const Peer = struct {
    addr: linux.sockaddr.storage = undefined,
    addr_len: linux.socklen_t = 0,
    /// Cached hashAddr(addr) (set in setAddr); key for per-datagram peer lookup.
    addr_key: u64 = 0,
    remote_id: i32 = 0,
    local_id: i32 = 0,
    connect_time: i64 = 0,
    conn_num: u8 = 0,
    alive: bool = false,
    authenticated: bool = false,
    /// Test-only: when non-null, sendReliable also records user payloads.
    capture: ?*Capture = null,
    /// Optional ACK pump: called while a large reliable message stalls on a full
    /// window so incoming ACKs advance local_window_start and free slots. Without
    /// it, multi-fragment chunks (POI ids ≥ 256 add a 3072 B/layer upper24 array)
    /// can never drain the 64-slot window and the send fails, holing the chunk disk.
    pump_fn: ?*const fn (?*anyopaque) void = null,
    pump_ctx: ?*anyopaque = null,

    local_seq: u16 = 0,
    local_window_start: u16 = 0,
    remote_window_start: u16 = 0,
    remote_seq_next: u16 = 0,
    /// Bits for remote sequences currently in window (for duplicate detect + acks).
    ack_bits: [ack_bitmap_bytes]u8 = .{0} ** ack_bitmap_bytes,
    must_ack: bool = false,
    pending: [pending_cap]Pending = [_]Pending{.{}} ** pending_cap,
    last_recv_ns: u64 = 0,
    next_frag_id: u16 = 1,
    /// Inbound fragment reassembly (one message at a time).
    asm_active: bool = false,
    asm_frag_id: u16 = 0,
    asm_total: u16 = 0,
    asm_got: u16 = 0,
    asm_have: [max_frag_parts]bool = .{false} ** max_frag_parts,
    asm_part_len: [max_frag_parts]u16 = .{0} ** max_frag_parts,
    /// Part payload storage (part i starts at i * max_fragment_user).
    asm_parts: [max_frag_parts][packet.max_fragment_user]u8 = undefined,
    /// Delivered reassembled user payload (valid until next handlePacket).
    deliver_buf: [assemble_cap]u8 = undefined,
    deliver_len: usize = 0,
    /// Extra user payloads from LiteNet Merged packets (multiple game msgs per UDP).
    extra_buf: [assemble_cap]u8 = undefined,
    extra_used: usize = 0,
    extra_q: [8]struct { off: u32, len: u32 } = undefined,
    extra_n: u8 = 0,

    pub fn setAddr(self: *Peer, addr: *const linux.sockaddr.storage, addr_len: linux.socklen_t) void {
        const src: [*]const u8 = @ptrCast(addr);
        const dst: [*]u8 = @ptrCast(&self.addr);
        @memcpy(dst[0..addr_len], src[0..addr_len]);
        self.addr_len = addr_len;
        self.addr_key = hashAddr(addr, addr_len);
    }

    /// FNV-1a over the first ≤28 sockaddr bytes; cached in `addr_key` so the
    /// per-datagram peer lookup compares one u64 instead of re-hashing.
    pub fn hashAddr(addr: *const linux.sockaddr.storage, len: linux.socklen_t) u64 {
        const bytes: [*]const u8 = @ptrCast(addr);
        var h: u64 = 1469598103934665603;
        var i: linux.socklen_t = 0;
        while (i < len and i < 28) : (i += 1) {
            h ^= bytes[i];
            h *%= 1099511628211;
        }
        return h;
    }

    pub fn sendRaw(self: *Peer, sock: *udp.Socket, raw: []const u8) !void {
        try sock.sendTo(raw, &self.addr, self.addr_len);
    }

    fn allocPending(self: *Peer, sock: *udp.Socket) !*Pending {
        const in_flight = relSeq(@as(i32, self.local_seq) - @as(i32, self.local_window_start));
        if (in_flight >= packet.window_size) {
            try self.resendPending(sock);
            return error.WindowFull;
        }
        const p = &self.pending[self.local_seq % pending_cap];
        if (p.used) {
            try self.resendPending(sock);
            return error.WindowFull;
        }
        return p;
    }

    /// Fire-and-forget unreliable (LiteNet property Unreliable). No retransmit.
    /// Use for high-rate cosmetic motion; game-critical still sendReliable.
    pub fn sendUnreliable(self: *Peer, sock: *udp.Socket, user: []const u8) !void {
        if (user.len > packet.max_single_user) return error.Overflow;
        if (self.capture) |cap| cap.push(user);
        var buf: [packet.max_packet_size]u8 = undefined;
        // Unreliable header: property byte 0 + user
        if (user.len + 1 > buf.len) return error.Overflow;
        buf[0] = @intFromEnum(packet.Property.unreliable);
        @memcpy(buf[1..][0..user.len], user);
        try self.sendRaw(sock, buf[0 .. 1 + user.len]);
    }

    /// ReliableSequenced channel (channel_id=1). Same window as ordered; stock uses
    /// separate channel for some motion. Full per-channel seq still deferred.
    pub fn sendSequenced(self: *Peer, sock: *udp.Socket, user: []const u8) !void {
        // ponytail: reuse reliable window with channel 1; dedicated seq when needed.
        if (user.len > packet.max_single_user) return error.Overflow;
        if (self.capture) |cap| cap.push(user);
        try self.sendOneReliableOnChannel(sock, user, null, 1);
    }

    pub fn sendReliable(self: *Peer, sock: *udp.Socket, user: []const u8) !void {
        if (self.capture) |cap| {
            // Record full user message for scenarios, then exercise real send path.
            cap.push(user);
        }
        if (user.len > max_payload) return error.Overflow;

        // Single datagram when it fits MTU (matches stock non-fragment path).
        if (user.len <= packet.max_single_user) {
            try self.sendOneReliable(sock, user, null);
            return;
        }

        // Fragment large messages (PackageIds, stock PlayerLogin tickets, …).
        const part_max = packet.max_fragment_user;
        const total_parts: u16 = @intCast((user.len + part_max - 1) / part_max);
        if (total_parts > max_frag_parts) return error.Overflow;
        const frag_id = self.next_frag_id;
        self.next_frag_id +%= 1;
        var part: u16 = 0;
        var off: usize = 0;
        while (part < total_parts) : (part += 1) {
            const n = @min(part_max, user.len - off);
            // Retry this part on WindowFull, resuming the SAME fragment stream
            // (stable frag_id, no restart) and pumping ACKs so the window drains.
            // Restarting the whole message here would burn a fresh 29-slot run per
            // retry and thrash the 64-slot window for large chunks.
            var attempts: u32 = 0;
            while (true) : (attempts += 1) {
                self.sendOneReliable(sock, user[off .. off + n], .{
                    .frag_id = frag_id,
                    .frag_part = part,
                    .frag_total = total_parts,
                }) catch |err| switch (err) {
                    error.WindowFull => {
                        if (attempts >= 4000) return error.WindowFull;
                        try self.resendPending(sock);
                        if (self.pump_fn) |pf| pf(self.pump_ctx);
                        continue;
                    },
                    else => return err,
                };
                break;
            }
            off += n;
        }
    }

    const FragMeta = struct { frag_id: u16, frag_part: u16, frag_total: u16 };

    fn sendOneReliable(self: *Peer, sock: *udp.Socket, user_part: []const u8, frag: ?FragMeta) !void {
        try self.sendOneReliableOnChannel(sock, user_part, frag, 2);
    }

    fn sendOneReliableOnChannel(self: *Peer, sock: *udp.Socket, user_part: []const u8, frag: ?FragMeta, channel_id: u8) !void {
        const p = try self.allocPending(sock);
        const seq = self.local_seq;
        const framed = if (frag) |f|
            try packet.writeChanneledFragment(p.data[0..], seq, channel_id, self.conn_num, f.frag_id, f.frag_part, f.frag_total, user_part)
        else
            try packet.writeChanneled(p.data[0..], seq, channel_id, self.conn_num, user_part);
        p.used = true;
        p.seq = seq;
        p.len = @intCast(framed.len);
        p.last_sent_ns = clock.monoNs();
        self.local_seq = @intCast((@as(u32, seq) + 1) % packet.max_sequence);
        // Capture-only peers: free slot immediately so suite does not WindowFull.
        if (self.capture != null) {
            p.used = false;
            self.local_window_start = self.local_seq;
            return;
        }
        try self.sendRaw(sock, p.data[0..p.len]);
    }

    pub fn resendPending(self: *Peer, sock: *udp.Socket) !void {
        const now = clock.monoNs();
        var seq = self.local_window_start;
        while (seq != self.local_seq) : (seq = @intCast((@as(u32, seq) + 1) % packet.max_sequence)) {
            const p = &self.pending[seq % pending_cap];
            if (!p.used) continue;
            if (now -% p.last_sent_ns < resend_ns) continue;
            try self.sendRaw(sock, p.data[0..p.len]);
            p.last_sent_ns = now;
        }
        if (self.must_ack) try self.flushAcks(sock);
    }

    fn clearAssembly(self: *Peer) void {
        self.asm_active = false;
        self.asm_got = 0;
        self.asm_have = .{false} ** max_frag_parts;
        self.asm_part_len = .{0} ** max_frag_parts;
    }

    /// Collect fragment parts; return full user payload when complete.
    fn takeFragment(self: *Peer, info: packet.ChanneledInfo) ?[]const u8 {
        if (info.frag_total == 0 or info.frag_total > max_frag_parts) return null;
        if (info.frag_part >= info.frag_total) return null;
        if (info.user.len > packet.max_fragment_user) return null;
        if (!self.asm_active or self.asm_frag_id != info.frag_id) {
            self.clearAssembly();
            self.asm_active = true;
            self.asm_frag_id = info.frag_id;
            self.asm_total = info.frag_total;
        } else if (self.asm_total != info.frag_total) {
            return null;
        }
        const part: usize = info.frag_part;
        if (self.asm_have[part]) return null; // duplicate part
        @memcpy(self.asm_parts[part][0..info.user.len], info.user);
        self.asm_have[part] = true;
        self.asm_part_len[part] = @intCast(info.user.len);
        self.asm_got += 1;
        if (self.asm_got < self.asm_total) return null;
        // Reassemble in part order into deliver_buf.
        var out: usize = 0;
        var i: u16 = 0;
        while (i < self.asm_total) : (i += 1) {
            if (!self.asm_have[i]) {
                self.clearAssembly();
                return null;
            }
            const pl = self.asm_part_len[i];
            if (out + pl > assemble_cap) {
                self.clearAssembly();
                return null;
            }
            @memcpy(self.deliver_buf[out .. out + pl], self.asm_parts[i][0..pl]);
            out += pl;
        }
        self.deliver_len = out;
        self.clearAssembly();
        return self.deliver_buf[0..self.deliver_len];
    }

    pub fn inFlight(self: *const Peer) u16 {
        return @intCast(relSeq(@as(i32, self.local_seq) - @as(i32, self.local_window_start)));
    }

    fn pushExtra(self: *Peer, user: []const u8) void {
        if (self.extra_n >= self.extra_q.len) return;
        if (self.extra_used + user.len > self.extra_buf.len) return;
        const off: u32 = @intCast(self.extra_used);
        @memcpy(self.extra_buf[self.extra_used..][0..user.len], user);
        self.extra_used += user.len;
        self.extra_q[self.extra_n] = .{ .off = off, .len = @intCast(user.len) };
        self.extra_n += 1;
    }

    /// Pop next queued user payload from a prior Merged datagram (FIFO).
    pub fn popExtra(self: *Peer) ?[]const u8 {
        if (self.extra_n == 0) return null;
        const e = self.extra_q[0];
        var i: u8 = 1;
        while (i < self.extra_n) : (i += 1) self.extra_q[i - 1] = self.extra_q[i];
        self.extra_n -= 1;
        if (self.extra_n == 0) self.extra_used = 0;
        return self.extra_buf[e.off..][0..e.len];
    }

    pub fn handlePacket(self: *Peer, sock: *udp.Socket, raw: []const u8) !?[]const u8 {
        if (raw.len < 1) return null;
        self.last_recv_ns = clock.monoNs();
        const prop = packet.propertyOf(raw[0]);
        switch (prop) {
            // LiteNet Merged: [prop][u16 size][subpacket]*: NOT a channeled header.
            .merged => {
                var off: usize = 1;
                while (off + 2 <= raw.len) {
                    const slen = std.mem.readInt(u16, raw[off..][0..2], .little);
                    off += 2;
                    if (slen == 0) break;
                    if (off + slen > raw.len) break;
                    const sub = raw[off .. off + slen];
                    off += slen;
                    // Stock LiteNet never nests Merged; refusing it bounds recursion
                    // depth at 1 so a self-nested datagram cannot blow the stack.
                    if (packet.propertyOf(sub[0]) == .merged) continue;
                    if (try self.handlePacket(sock, sub)) |user| {
                        self.pushExtra(user);
                    }
                }
                return self.popExtra();
            },
            .channeled => {
                const info = packet.parseChanneled(raw) orelse return null;
                // Stock rejects seq >= MaxSequence; relSeq would alias it into the window.
                if (info.seq >= packet.max_sequence) return null;
                const relate = relSeq(@as(i32, info.seq) - @as(i32, self.remote_window_start));
                if (relate < 0 or relate >= @as(i32, @intCast(packet.window_size * 2))) {
                    self.must_ack = true;
                    try self.flushAcks(sock);
                    return null;
                }
                // Slide window for very new packets (LiteNet-style).
                if (relate >= @as(i32, @intCast(packet.window_size))) {
                    const new_start: u16 = @intCast((@as(u32, info.seq) + 1 - packet.window_size + packet.max_sequence) % packet.max_sequence);
                    while (self.remote_window_start != new_start) {
                        const wi: usize = self.remote_window_start % packet.window_size;
                        self.ack_bits[wi / 8] &= ~(@as(u8, 1) << @intCast(wi % 8));
                        self.remote_window_start = @intCast((@as(u32, self.remote_window_start) + 1) % packet.max_sequence);
                    }
                }
                const idx: usize = info.seq % packet.window_size;
                const already = (self.ack_bits[idx / 8] & (@as(u8, 1) << @intCast(idx % 8))) != 0;
                self.ack_bits[idx / 8] |= @as(u8, 1) << @intCast(idx % 8);
                self.must_ack = true;
                try self.flushAcks(sock);
                if (already) return null;
                // Deliver on first sight (ordered hold buffer deferred; retransmits deduped).
                if (info.seq == self.remote_seq_next) {
                    self.remote_seq_next = @intCast((@as(u32, self.remote_seq_next) + 1) % packet.max_sequence);
                } else if (relSeq(@as(i32, info.seq) - @as(i32, self.remote_seq_next)) > 0) {
                    // Gap: still deliver so login/motion is not dropped if a prior control pkt was skipped.
                }
                if (!info.fragmented) return info.user;
                return self.takeFragment(info);
            },
            .ack => {
                self.processAck(raw);
                return null;
            },
            .disconnect => {
                self.alive = false;
                self.authenticated = false;
                // Free all pending so the peer slot can be reused without a stuck window.
                for (&self.pending) |*p| p.used = false;
                self.local_window_start = self.local_seq;
                return null;
            },
            .ping => {
                // Stock Ping header size=3: [prop][seq:u16]. Pong header size=11:
                // [prop][seq:u16][utc_ticks:i64]. Wrong pong size fails client NetPacket.Verify
                // → "[NM] DataReceived: bad!" and DisconnectReason.Timeout.
                if (raw.len >= 3) {
                    var pong: [11]u8 = undefined;
                    pong[0] = packet.makeByte0(.pong, self.conn_num);
                    pong[1] = raw[1];
                    pong[2] = raw[2];
                    // Ticks not used for our RTT; client only needs a valid 11-byte pong.
                    const ticks: i64 = @intCast(clock.monoNs() / 100); // 100ns units ≈ DateTime ticks scale
                    std.mem.writeInt(i64, pong[3..][0..8], ticks, .little);
                    try self.sendRaw(sock, &pong);
                }
                return null;
            },
            .mtu_check => {
                // Echo as MtuOk so client MTU discovery completes (same size payload).
                if (raw.len >= 1) {
                    var ok_buf: [1500]u8 = undefined;
                    const n = @min(raw.len, ok_buf.len);
                    @memcpy(ok_buf[0..n], raw[0..n]);
                    ok_buf[0] = packet.makeByte0(.mtu_ok, self.conn_num);
                    try self.sendRaw(sock, ok_buf[0..n]);
                }
                return null;
            },
            .mtu_ok, .pong, .shutdown_ok, .empty => return null,
            else => return null,
        }
    }

    fn processAck(self: *Peer, raw: []const u8) void {
        // Stock ReliableChannel.ProcessAck: Size must match header + (windowSize-1)/8+2.
        const expect = packet.channeled_header_size + ack_bitmap_bytes;
        if (raw.len < packet.channeled_header_size + 1) return;
        _ = expect; // accept ≥ header; loadgen/stock both send full 13-byte acks
        const ack_seq = std.mem.readInt(u16, raw[1..][0..2], .little);
        if (ack_seq >= packet.max_sequence) return;
        // Stock: RelativeSequenceNumber(localWindowStart, ackSeq) = local - ack ∈ [0, window).
        const rel_base = relSeq(@as(i32, self.local_window_start) - @as(i32, ack_seq));
        if (rel_base < 0 or rel_base >= @as(i32, @intCast(packet.window_size))) return;

        // Walk seq from localWindowStart → localSequence; bit at (seq % windowSize).
        var seq = self.local_window_start;
        while (seq != self.local_seq) : (seq = @intCast((@as(u32, seq) + 1) % packet.max_sequence)) {
            // Stop if this seq is outside the ack's reported window span.
            if (relSeq(@as(i32, seq) - @as(i32, ack_seq)) >= @as(i32, @intCast(packet.window_size))) break;
            const pending_idx: usize = @intCast(seq % packet.window_size);
            const byte_i = packet.channeled_header_size + pending_idx / 8;
            const bit_i: u3 = @intCast(pending_idx % 8);
            if (byte_i >= raw.len) break;
            if ((raw[byte_i] & (@as(u8, 1) << bit_i)) == 0) continue;
            const p = &self.pending[seq % pending_cap];
            if (p.used and p.seq == seq) {
                p.used = false;
            }
            if (seq == self.local_window_start) {
                self.local_window_start = @intCast((@as(u32, self.local_window_start) + 1) % packet.max_sequence);
            }
        }
        // Slide window start past contiguous free seqs.
        while (self.local_window_start != self.local_seq) {
            const p = &self.pending[self.local_window_start % pending_cap];
            if (p.used and p.seq == self.local_window_start) break;
            self.local_window_start = @intCast((@as(u32, self.local_window_start) + 1) % packet.max_sequence);
        }
    }

    pub fn flushAcks(self: *Peer, sock: *udp.Socket) !void {
        if (!self.must_ack) return;
        self.must_ack = false;
        var buf: [64]u8 = undefined;
        const total = packet.channeled_header_size + ack_bitmap_bytes;
        if (buf.len < total) return error.Overflow;
        buf[0] = packet.makeByte0(.ack, self.conn_num);
        std.mem.writeInt(u16, buf[1..][0..2], self.remote_window_start, .little);
        buf[3] = 2; // ReliableOrdered channel id
        // Expand window-size bits into ack_bitmap_bytes (extra trailing zeros ok)
        @memset(buf[packet.channeled_header_size..][0..ack_bitmap_bytes], 0);
        const copy_n = @min(self.ack_bits.len, ack_bitmap_bytes);
        @memcpy(buf[packet.channeled_header_size..][0..copy_n], self.ack_bits[0..copy_n]);
        try self.sendRaw(sock, buf[0..total]);
    }
};

fn relSeq(a: i32) i32 {
    // Relative sequence in [-half, half) with modular wrap (LiteNet-style).
    const max: i32 = @intCast(packet.max_sequence);
    const half: i32 = @intCast(packet.max_sequence / 2);
    var r = @rem(a, max);
    if (r < 0) r += max;
    if (r >= half) r -= max;
    return r;
}

test "processAck advances local window when bits set" {
    // Drive real Peer.handlePacket ack path (not a reimplementation).
    var peer: Peer = .{};
    peer.alive = true;
    peer.conn_num = 0;
    // Simulate three outstanding reliable packets seq 0,1,2.
    peer.local_window_start = 0;
    peer.local_seq = 3;
    peer.pending[0] = .{ .used = true, .seq = 0, .len = 8 };
    peer.pending[1] = .{ .used = true, .seq = 1, .len = 8 };
    peer.pending[2] = .{ .used = true, .seq = 2, .len = 8 };

    var ack: [13]u8 = .{0} ** 13;
    ack[0] = packet.makeByte0(.ack, 0);
    std.mem.writeInt(u16, ack[1..3], 0, .little); // window start
    ack[3] = 2; // ReliableOrdered channel id
    // bits for seq 0,1,2 at indices 0,1,2
    ack[4] = 0b0000_0111;

    var sock: udp.Socket = .{}; // unused for ack path
    const user = try peer.handlePacket(&sock, &ack);
    try std.testing.expect(user == null);
    try std.testing.expectEqual(@as(u16, 3), peer.local_window_start);
    try std.testing.expect(!peer.pending[0].used);
    try std.testing.expect(!peer.pending[1].used);
    try std.testing.expect(!peer.pending[2].used);
}
